#!/bin/bash
# =====================================================================
#  keepalive_full: защита Always Free сервера Oracle от отключения за простой
#  Запуск:  sudo bash keepalive_full.sh      (на самом сервере Oracle)
#
#  Oracle может забрать Always Free сервер, если 7 дней подряд ВСЕ метрики ниже 20%:
#  ЦП (95-й процентиль), сеть и (только для Ampere) память. Достаточно держать выше 20% любую одну.
#
#  Что делает:
#    - сам определяет тип сервера: ARM (Ampere) -> занимает долю оперативной памяти;
#                                  AMD (Micro)  -> раз в несколько минут короткие всплески ЦП;
#    - раз в сутки (и при каждом запуске) анализирует, сколько памяти / ЦП используют ваши программы,
#      и подстраивает размер: ваши программы всегда в приоритете;
#    - если свободной памяти становится мало, сразу отдаёт её обратно;
#    - работает как служба с автозапуском (переживает перезагрузки);
#    - удаляется одним пунктом меню.
# =====================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root: sudo bash $0${NC}"
    exit 1
fi

SVC="keepalive"
CONF="/etc/keepalive.conf"
DAEMON="/usr/local/sbin/keepalive-daemon.py"
UNIT="/etc/systemd/system/${SVC}.service"
STATUS="/var/lib/keepalive/status.json"
STATEDIR="/var/lib/keepalive"
LOG="/var/log/keepalive.log"

ask_number() {  # ask_number "Вопрос" default min max -> ANSWER
    local q="$1" def="$2" min="$3" max="$4" v
    while true; do
        read -rp "${q} [${def}]: " v || return 1
        v="${v:-$def}"
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= min && v <= max )); then ANSWER="$v"; return 0; fi
        echo -e "${RED}Нужно число от ${min} до ${max}.${NC}"
    done
}
yn() { local a; read -rp "$1 (y/n): " a; [[ "$a" == "y" || "$a" == "Y" ]]; }

conf_value() { awk -F= -v k="$1" '$1==k {gsub(/^[ \t"]+|[ \t"]+$/,"",$2); print $2; exit}' "$CONF" 2>/dev/null; }

ensure_python() {
    command -v python3 >/dev/null && return 0
    echo "Ставлю python3..."
    apt-get update -qq >/dev/null 2>&1; apt-get install -y python3 >/dev/null 2>&1
    command -v python3 >/dev/null || { echo -e "${RED}Не удалось поставить python3.${NC}"; return 1; }
}

mem_total_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
mem_avail_mb() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }

oracle_shape() {  # тип сервера из метаданных Oracle (если доступны)
    curl -s -m 3 -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/shape 2>/dev/null | grep -E '^VM\.' | head -n 1
}

detect_mode() {  # печатает mem или cpu
    case "$(uname -m)" in aarch64|arm64) echo mem ;; *) echo cpu ;; esac
}

describe_server() {
    local shape arch
    shape=$(oracle_shape); arch=$(uname -m)
    if [[ "$(detect_mode)" == "mem" ]]; then
        echo "Сервер: ARM (Ampere)${shape:+, $shape}; процессор ${arch}"
    else
        echo "Сервер: AMD (Micro)${shape:+, $shape}; процессор ${arch}"
    fi
}


install_daemon() {
    mkdir -p "$STATEDIR"
    cat > "$DAEMON" <<'PYEOF'
#!/usr/bin/env python3
# keepalive: держит загрузку Always Free сервера Oracle выше порога "простоя".
# Ampere (ARM): занимает долю оперативной памяти. Micro (AMD): короткие всплески нагрузки на ЦП.
import os, sys, time, json, math, ctypes, subprocess, platform, signal, random

CONF = os.environ.get("KA_CONF", "/etc/keepalive.conf")
STATUS = os.environ.get("KA_STATUS", "/var/lib/keepalive/status.json")
STATE = os.environ.get("KA_STATE", "/var/lib/keepalive/state.json")
LOG = os.environ.get("KA_LOG", "/var/log/keepalive.log")
TICK = float(os.environ.get("KA_TICK", "60"))          # шаг опроса, сек
CHUNK_MB = int(os.environ.get("KA_CHUNK_MB", "64"))    # размер блока памяти
DAY = int(os.environ.get("KA_DAY_TICKS", "1440"))      # шагов в "сутках"
BLOCK = int(os.environ.get("KA_BLOCK", "3"))           # длина одного всплеска ЦП, шагов
BUCKET = int(os.environ.get("KA_BUCKET_TICKS", "10"))  # шагов в одной записи истории
MB = 1024 * 1024
CHUNK = CHUNK_MB * MB
running = True
burn = None


def log(msg):
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1000000:
            with open(LOG) as f:
                tail = f.readlines()[-300:]
            with open(LOG, "w") as f:
                f.writelines(tail)
        with open(LOG, "a") as f:
            f.write(time.strftime("%F %T ") + msg + "\n")
    except OSError:
        pass


def load_conf():
    c = {"MODE": "auto", "MEM_TARGET_PCT": "30", "MEM_RESERVE_PCT": "10",
         "MEM_RESERVE_MIN_MB": "300", "CPU_TARGET_PCT": "10"}
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    c[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return c


def num(c, k, d):
    try:
        return float(c.get(k, d))
    except ValueError:
        return float(d)


def read_mem():
    d = {}
    with open("/proc/meminfo") as f:
        for line in f:
            p = line.split()
            if p[0] in ("MemTotal:", "MemAvailable:"):
                d[p[0][:-1]] = int(p[1]) * 1024
    return d["MemTotal"], d["MemAvailable"]


def cpu_times():
    with open("/proc/stat") as f:
        p = [int(x) for x in f.readline().split()[1:9]]
    return p[3] + p[4], sum(p)


class Hold:
    def __init__(self):
        self.chunks = []
        self.lock_warned = False
        try:
            self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        except OSError:
            self.libc = None

    @property
    def n(self):
        return len(self.chunks)

    def grow_one(self):
        buf = bytearray(os.urandom(1 << 20)) * (CHUNK_MB)
        if self.libc is not None:
            try:
                addr = ctypes.addressof((ctypes.c_char * len(buf)).from_buffer(buf))
                if self.libc.mlock(ctypes.c_void_p(addr), ctypes.c_size_t(len(buf))) != 0 and not self.lock_warned:
                    log("предупреждение: не удалось закрепить память (mlock); при нехватке RAM система может вытеснить её в swap")
                    self.lock_warned = True
            except (TypeError, ValueError):
                pass
        self.chunks.append(buf)

    def shrink(self, k):
        for _ in range(min(k, len(self.chunks))):
            self.chunks.pop()


def resolve_mode(c):
    m = c.get("MODE", "auto")
    if m in ("mem", "cpu", "both"):
        return m
    return "mem" if platform.machine() in ("aarch64", "arm64") else "cpu"


def load_state():
    try:
        with open(STATE) as f:
            h = json.load(f).get("hist", [])
        return [e for e in h if isinstance(e, dict)]
    except (OSError, ValueError):
        return []


def save(path, obj):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except OSError:
        pass


def recent(hist, now):
    horizon = DAY * TICK * 1.5
    return [e for e in hist if now - e.get("t", 0) <= horizon][-(DAY // BUCKET + 1):]


def stop(*_):
    global running
    running = False


def main():
    global burn
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    conf = load_conf()
    mode = resolve_mode(conf)
    hold = Hold()
    hist = load_state()
    cur = {"m": [], "c_n": 0, "c_a": 0}
    prev = cpu_times()
    burn_flag = False
    tick = 0
    plan = {"blocks": 0, "nat": 0.0, "mean": 0, "peak": 0}
    next_block = 0.0
    interval = 0.0
    last_analysis = 0
    log("запуск: режим=%s, память %d МБ" % (mode, read_mem()[0] // MB))

    while running:
        total, avail = read_mem()
        held = hold.n * CHUNK
        others = total - avail - held
        idle, tot = cpu_times()
        dt = tot - prev[1]
        busy = 1.0 - (idle - prev[0]) / dt if dt > 0 else 0.0
        prev = (idle, tot)
        cur["m"].append(others)
        if not burn_flag:
            cur["c_n"] += 1
            if busy > 0.2:
                cur["c_a"] += 1
        if tick % BUCKET == BUCKET - 1:
            ms = cur["m"] or [others]
            hist.append({"t": time.time(), "m_mean": sum(ms) / len(ms), "m_peak": max(ms),
                         "c_n": cur["c_n"], "c_a": cur["c_a"]})
            hist = hist[-(7 * DAY // BUCKET):]
            save(STATE, {"hist": hist})
            cur = {"m": [], "c_n": 0, "c_a": 0}

        conf = load_conf() if tick % 10 == 0 else conf
        mode = resolve_mode(conf)
        reserve = max(num(conf, "MEM_RESERVE_MIN_MB", 300) * MB, total * num(conf, "MEM_RESERVE_PCT", 10) / 100)

        # защита ваших программ: если свободной памяти мало, сразу отдаём её
        if mode in ("mem", "both") and hold.n and avail < reserve:
            k = int(math.ceil((reserve - avail) / CHUNK)) + 1
            hold.shrink(k)
            log("свободной памяти мало (%d МБ): освободил %d блок(ов), теперь держу %d МБ" % (avail // MB, k, hold.n * CHUNK_MB))

        # ежесуточный анализ
        if tick % DAY == 0:
            now = time.time()
            rh = recent(hist, now)
            last_analysis = now
            if mode in ("mem", "both"):
                if rh:
                    mean = sum(e["m_mean"] for e in rh) / len(rh)
                    peak = max(e["m_peak"] for e in rh)
                else:
                    mean = peak = others
                target = total * num(conf, "MEM_TARGET_PCT", 30) / 100
                want = max(0.0, target - mean)
                cap = max(0.0, total - peak - reserve)
                n = int(min(want, cap) // CHUNK)
                plan.update(mean=mean, peak=peak)
                before = hold.n
                if n < hold.n:
                    hold.shrink(hold.n - n)
                while hold.n < n and read_mem()[1] - CHUNK >= reserve:
                    hold.grow_one()
                log("анализ памяти: другие программы в среднем %d МБ (пик %d МБ), цель %d%% = %d МБ, держу %d МБ (было %d МБ)" % (
                    mean // MB, peak // MB, num(conf, "MEM_TARGET_PCT", 30), target // MB, hold.n * CHUNK_MB, before * CHUNK_MB))
            if mode in ("cpu", "both"):
                cn = sum(e["c_n"] for e in rh) + cur["c_n"]
                ca = sum(e["c_a"] for e in rh) + cur["c_a"]
                nat = (ca / cn) if cn >= 30 else 0.0
                tgt = num(conf, "CPU_TARGET_PCT", 10) / 100
                need_min = max(0.0, tgt - nat) * DAY
                blocks = int(math.ceil(need_min / max(1, BLOCK - 1)))
                plan.update(blocks=blocks, nat=nat)
                interval = (DAY / blocks) if blocks else 0.0
                next_block = tick + (random.random() * interval if blocks else 0)
                log("анализ ЦП: сам по себе выше 20%% бывает %.1f%% времени, цель %.0f%%, всплесков в сутки: %d (по %d мин)" % (
                    nat * 100, tgt * 100, blocks, BLOCK))

        # всплески ЦП
        if mode in ("cpu", "both"):
            if burn is not None and burn.poll() is not None:
                burn = None
            if plan["blocks"] and burn is None and tick >= next_block:
                burn = subprocess.Popen(["nice", "-n", "19", "timeout", str(int(BLOCK * TICK)), "sh", "-c", "while :; do :; done"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                next_block += interval
        burn_flag = burn is not None and burn.poll() is None

        save(STATUS, {"mode": mode, "arch": platform.machine(), "ts": time.time(), "started_tick": tick,
                      "total_mb": total // MB, "held_mb": hold.n * CHUNK_MB, "others_mb": others // MB,
                      "avail_mb": avail // MB, "reserve_mb": int(reserve // MB),
                      "mean_mb": int(plan["mean"] // MB), "peak_mb": int(plan["peak"] // MB),
                      "mem_target_pct": num(conf, "MEM_TARGET_PCT", 30),
                      "cpu_busy_pct": round(busy * 100, 1), "cpu_nat_pct": round(plan["nat"] * 100, 1),
                      "cpu_target_pct": num(conf, "CPU_TARGET_PCT", 10), "blocks": plan["blocks"],
                      "block_min": BLOCK, "burning": burn_flag, "last_analysis": last_analysis})
        tick += 1
        time.sleep(TICK)

    if burn is not None:
        try:
            burn.kill()
        except OSError:
            pass
    log("остановлен")


if __name__ == "__main__":
    main()
PYEOF
    chmod 755 "$DAEMON"
    cat > "$UNIT" <<UEOF
[Unit]
Description=Keepalive: защита Always Free сервера Oracle от отключения за простой
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${DAEMON}
Restart=always
RestartSec=10
Nice=19
OOMScoreAdjust=1000
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UEOF
    systemctl daemon-reload
}

do_install() {
    ensure_python || return 1
    echo -e "\n${YELLOW}=== Установка ===${NC}"
    describe_server
    local mode total avail
    mode=$(detect_mode); total=$(mem_total_mb); avail=$(mem_avail_mb)
    local mem_pct=30 cpu_pct=10
    if [[ "$mode" == "mem" ]]; then
        local used=$((total - avail))
        echo "Режим: ПАМЯТЬ. Всего ${total} МБ, сейчас занято вашими программами около ${used} МБ ($((used * 100 / total))%)."
        echo "Порог Oracle: 20%. Рекомендую держать общую занятость около 30% (запас на неточность замеров)."
        ask_number "Целевая занятость памяти, % (25-60)" 30 25 60 || return 1; mem_pct="$ANSWER"
        local hold=$(( total * mem_pct / 100 - used ))
        (( hold < 0 )) && hold=0
        echo "Сейчас скрипт займёт примерно ${hold} МБ. Если ваши программы вырастут, он сам уменьшит и отдаст память."
    else
        echo "Режим: ЦП (у Micro память Oracle не проверяет, поэтому нагрузка идёт на процессор)."
        echo "Порог Oracle: 95-й процентиль ЦП выше 20%, то есть не менее 5% времени ЦП должен быть выше 20%."
        echo "Скрипт добавит короткие всплески (по 3 минуты, с самым низким приоритетом: ваши программы не замедлятся),"
        echo "ровно столько, чтобы суммарно набралось нужное время. Если ваши программы сами создают нагрузку, всплески будут реже."
        ask_number "Целевая доля времени с ЦП выше 20%, % (7-30, рекомендую 10)" 10 7 30 || return 1; cpu_pct="$ANSWER"
    fi
    systemctl stop "$SVC" >/dev/null 2>&1
    ( umask 022; cat > "$CONF" <<CEOF
# Настройки keepalive. MODE: auto (по типу сервера) | mem | cpu | both
MODE=auto
MEM_TARGET_PCT=${mem_pct}
MEM_RESERVE_PCT=10
MEM_RESERVE_MIN_MB=300
CPU_TARGET_PCT=${cpu_pct}
CEOF
    )
    install_daemon
    systemctl enable --now "$SVC" >/dev/null 2>&1
    sleep 3
    if systemctl is-active --quiet "$SVC"; then
        echo -e "${GREEN}✅ Служба запущена и включена в автозапуск.${NC}"
        echo "Смотреть состояние: пункт 2 меню."
    else
        echo -e "${RED}Служба не запустилась. Смотрите: journalctl -u ${SVC} -n 20${NC}"
    fi
}

show_status() {
    echo -e "\n${YELLOW}📊 [СТАТУС]${NC}"
    describe_server
    echo "Служба: $(systemctl is-active "$SVC" 2>/dev/null) (автозапуск: $(systemctl is-enabled "$SVC" 2>/dev/null))"
    if [[ ! -f "$STATUS" ]]; then
        echo "Данных пока нет (служба не установлена или только что стартовала)."
        return
    fi
    python3 - "$STATUS" <<'PYS'
import json, sys, time
d = json.load(open(sys.argv[1]))
age = int(time.time() - d["ts"])
fresh = "" if age < 180 else "  (ВНИМАНИЕ: данные устарели на %d мин, служба не работает?)" % (age // 60)
print("Режим: %s%s" % ({"mem": "память", "cpu": "ЦП", "both": "память + ЦП"}[d["mode"]], fresh))
if d["mode"] in ("mem", "both"):
    tot = d["total_mb"]; held = d["held_mb"]; oth = d["others_mb"]
    print("Память всего: %d МБ" % tot)
    print("  ваши программы сейчас:   %d МБ (в среднем за сутки %d МБ, пик %d МБ)" % (oth, d["mean_mb"], d["peak_mb"]))
    print("  занято скриптом:         %d МБ" % held)
    print("  общая занятость:         %d%%  (цель %d%%, порог Oracle 20%%)" % (round((oth + held) * 100 / tot), d["mem_target_pct"]))
    print("  свободно сейчас:         %d МБ (резерв, ниже которого скрипт отдаёт память: %d МБ)" % (d["avail_mb"], d["reserve_mb"]))
if d["mode"] in ("cpu", "both"):
    print("ЦП сейчас: %s%%, всплеск идёт: %s" % (d["cpu_busy_pct"], "да" if d["burning"] else "нет"))
    print("  ваши программы сами держат ЦП выше 20%% примерно %s%% времени (цель %d%%)" % (d["cpu_nat_pct"], d["cpu_target_pct"]))
    print("  всплесков в сутки: %d (по %d мин)" % (d["blocks"], d["block_min"]))
if d["last_analysis"]:
    print("Последний анализ: " + time.strftime("%F %T", time.localtime(d["last_analysis"])))
PYS
    if [[ -f "$LOG" ]]; then
        echo "Последние записи журнала:"
        tail -n 6 "$LOG" | sed 's/^/   /'
    fi
}

do_settings() {
    [[ -f "$CONF" ]] || { echo -e "${RED}Сначала установите (пункт 1).${NC}"; return 1; }
    echo -e "\n${YELLOW}=== Настройки ===${NC}"
    local mode cur
    mode=$(detect_mode)
    if [[ "$mode" == "mem" ]]; then
        cur=$(conf_value MEM_TARGET_PCT)
        ask_number "Целевая занятость памяти, % (25-60)" "${cur:-30}" 25 60 || return 1
        sed -i "s/^MEM_TARGET_PCT=.*/MEM_TARGET_PCT=${ANSWER}/" "$CONF"
    else
        cur=$(conf_value CPU_TARGET_PCT)
        ask_number "Целевая доля времени с ЦП выше 20%, % (7-30)" "${cur:-10}" 7 30 || return 1
        sed -i "s/^CPU_TARGET_PCT=.*/CPU_TARGET_PCT=${ANSWER}/" "$CONF"
    fi
    echo "Сохранено. Новые значения подхватятся при следующем анализе; чтобы применить сразу, перезапустите службу (пункты 3 и 4)."
}

do_stop()  { systemctl stop "$SVC" >/dev/null 2>&1; systemctl disable "$SVC" >/dev/null 2>&1; echo -e "${GREEN}Остановлено, память освобождена, автозапуск выключен.${NC}"; }
do_start() {
    [[ -x "$DAEMON" ]] || { echo -e "${RED}Сначала установите (пункт 1).${NC}"; return 1; }
    systemctl enable --now "$SVC" >/dev/null 2>&1; sleep 2
    systemctl is-active --quiet "$SVC" && echo -e "${GREEN}✅ Запущено.${NC}" || echo -e "${RED}Не запустилось: journalctl -u ${SVC} -n 20${NC}"
}

do_uninstall() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ]${NC}"
    if [[ ! -e "$UNIT" && ! -e "$DAEMON" && ! -e "$CONF" && ! -d "$STATEDIR" ]]; then
        echo -e "${GREEN}Удалять нечего.${NC}"; return
    fi
    echo "Будет удалено: служба ${SVC}, ${DAEMON}, ${CONF}, ${STATEDIR}, ${LOG}"
    yn "Продолжить?" || { echo "Отменено."; return; }
    systemctl disable --now "$SVC" >/dev/null 2>&1
    rm -f "$UNIT" "$DAEMON" "$CONF" "$LOG"; rm -rf "$STATEDIR"
    systemctl daemon-reload
    echo -e "${GREEN}✅ Готово. Память освобождена.${NC}"
}

# ---------------------------------------------------------------- МЕНЮ

while true; do
    echo -e "\n${YELLOW}===== Keepalive: защита Always Free сервера Oracle от отключения =====${NC}"
    describe_server
    echo "1. Установить / переустановить (с анализом сервера)"
    echo "2. Статус"
    echo "3. Остановить"
    echo "4. Запустить"
    echo "5. Настройки (целевой процент)"
    echo "6. Удалить"
    echo "0. Выход"
    read -rp "Пункт: " c || exit 0
    case "$c" in
        1) do_install ;;
        2) show_status ;;
        3) do_stop ;;
        4) do_start ;;
        5) do_settings ;;
        6) do_uninstall ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
