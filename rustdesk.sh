#!/bin/bash
# =====================================================================
#  RustDesk Server: свой сервер удалённого доступа (hbbs + hbbr)
#  Запуск:  sudo bash rustdesk.sh      (на самом сервере Oracle)
#
#  Что делает:
#    - ставит официальные файлы hbbs и hbbr напрямую (без Docker), как службы systemd;
#      работает и на Micro (AMD), и на Ampere (ARM): тип процессора определяется сам;
#    - режим "только по ключу" (-k _): без вашего ключа никто не подключится;
#    - открывает порты 21115-21117 (TCP) и 21116 (UDP): через ufw, если он включён,
#      иначе через iptables (сохраняет правила);
#    - автообновление раз в неделю с автоматическим откатом, если новая версия не запустилась;
#    - можно забрать ключ из старой установки через Docker (клиентам ничего менять не придётся);
#    - удаляется одним пунктом меню.
# =====================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root: sudo bash $0${NC}"
    exit 1
fi

BIN_DIR="/opt/rustdesk"
DATA_DIR="/var/lib/rustdesk"
CONF="/etc/rustdesk-server.conf"
SELF="/usr/local/sbin/rustdesk-manager.sh"
UPD_LOG="/var/log/rustdesk-update.log"
LOCK="/var/lock/rustdesk-update.lock"
OLD_DIR="/opt/rustdesk-server"            # папка старой установки через Docker
SVC_S="rustdesk-hbbs"
SVC_R="rustdesk-hbbr"
SVC_U="rustdesk-update"
UNIT_DIR="/etc/systemd/system"
REPO="rustdesk/rustdesk-server"

# ---------------------------------------------------------------- вспомогательное

# ask_yn "Вопрос" y|n  -> 0 если "да". Второй параметр: что значит Enter.
ask_yn() {
    local q="$1" def="${2:-n}" a hint
    if [[ "$def" == "y" ]]; then hint="Y/n, Enter = да"; else hint="y/N, Enter = нет"; fi
    while true; do
        read -rp "$q ($hint): " a || return 1
        a="${a:-$def}"
        case "$a" in
            y|Y|д|Д) return 0 ;;
            n|N|н|Н) return 1 ;;
            *) echo -e "${RED}Ответьте y или n.${NC}" ;;
        esac
    done
}

conf_value() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); gsub(/^[ \t"]+|[ \t"]+$/,""); print; exit}' "$CONF" 2>/dev/null; }

conf_set() {  # conf_set ключ значение
    touch "$CONF"; chmod 644 "$CONF"
    if grep -q "^$1=" "$CONF" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$CONF"
    else
        echo "$1=$2" >> "$CONF"
    fi
}

ulog() {  # запись в журнал обновлений и на экран
    echo "$*"
    if [[ -f "$UPD_LOG" && $(stat -c %s "$UPD_LOG" 2>/dev/null || echo 0) -gt 200000 ]]; then
        tail -n 200 "$UPD_LOG" > "$UPD_LOG.tmp" && mv -f "$UPD_LOG.tmp" "$UPD_LOG"
    fi
    echo "$(date '+%F %T') $*" >> "$UPD_LOG"
}

is_installed() { [[ -x "$BIN_DIR/hbbs" && -x "$BIN_DIR/hbbr" && -f "$UNIT_DIR/$SVC_S.service" ]]; }
svc_active()   { systemctl is-active --quiet "$1"; }
autoupdate_on_now() { systemctl is-enabled --quiet "$SVC_U.timer" 2>/dev/null; }

asset_arch() {  # имя архитектуры в названии файла релиза
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64v8" ;;
        *) return 1 ;;
    esac
}

describe_server() {
    case "$(uname -m)" in
        aarch64|arm64) echo "Сервер: ARM (Ampere); процессор $(uname -m)" ;;
        x86_64|amd64)  echo "Сервер: AMD (Micro); процессор $(uname -m)" ;;
        *)             echo "Сервер: процессор $(uname -m) (не поддерживается)" ;;
    esac
}

ensure_deps() {
    local need=() c
    for c in curl unzip; do command -v "$c" >/dev/null || need+=("$c"); done
    [[ -d /etc/ssl/certs ]] || need+=(ca-certificates)
    ((${#need[@]} == 0)) && return 0
    echo "Ставлю нужные пакеты: ${need[*]} ..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y "${need[@]}" >/dev/null 2>&1
    for c in curl unzip; do
        command -v "$c" >/dev/null || { echo -e "${RED}Не удалось поставить $c.${NC}"; return 1; }
    done
}

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

get_ip() {  # публичный IPv4: метаданные Oracle, затем несколько сайтов
    local ip s
    ip=$(curl -s -m 3 -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/ 2>/dev/null \
         | grep -o '"publicIp" *: *"[0-9.]*"' | head -n 1 | grep -o '[0-9.]\{7,15\}')
    valid_ip "$ip" && { echo "$ip"; return 0; }
    for s in https://ifconfig.me https://api.ipify.org https://icanhazip.com; do
        ip=$(curl -4 -s -m 5 "$s" 2>/dev/null | tr -d '[:space:]')
        valid_ip "$ip" && { echo "$ip"; return 0; }
    done
    return 1
}

ask_address() {  # ask_address "умолчание" -> ADDRESS
    local def="$1" a
    while true; do
        if [[ -n "$def" ]]; then
            read -rp "Адрес сервера для клиентов, IP или домен [Enter = $def]: " a || return 1
            a="${a:-$def}"
        else
            read -rp "Адрес сервера для клиентов, IP или домен: " a || return 1
        fi
        if [[ "$a" =~ ^[A-Za-z0-9.-]+$ ]]; then ADDRESS="$a"; return 0; fi
        echo -e "${RED}Нужен IP или домен (буквы, цифры, точки, дефис).${NC}"
    done
}

# ---------------------------------------------------------------- загрузка версий

latest_tag() {  # номер последней версии на GitHub
    local t
    t=$(curl -s -m 15 -o /dev/null -w '%{redirect_url}' "https://github.com/$REPO/releases/latest" 2>/dev/null | sed -n 's|.*/tag/||p' | tr -d '[:space:]')
    if [[ -z "$t" ]]; then
        t=$(curl -s -m 15 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/')
    fi
    echo "$t"
}

fetch_release() {  # fetch_release версия папка -> в папке лежат готовые hbbs и hbbr
    local tag="$1" dest="$2" a url f
    a=$(asset_arch) || return 1
    url="https://github.com/$REPO/releases/download/$tag/rustdesk-server-linux-$a.zip"
    curl -fL -s -m 180 --retry 2 -o "$dest/rs.zip" "$url" || return 1
    unzip -q -o "$dest/rs.zip" -d "$dest/x" || return 1
    for f in hbbs hbbr; do
        cp "$(find "$dest/x" -type f -name "$f" | head -n 1)" "$dest/$f" 2>/dev/null || return 1
        [[ -s "$dest/$f" ]] || return 1
        chmod 755 "$dest/$f"
    done
    return 0
}

put_bins() {  # put_bins папка_с_файлами : заменяет файлы без ошибки "Text file busy"
    local src="$1" b
    mkdir -p "$BIN_DIR"
    for b in hbbs hbbr; do
        cp "$src/$b" "$BIN_DIR/$b.new" && chmod 755 "$BIN_DIR/$b.new" && mv -f "$BIN_DIR/$b.new" "$BIN_DIR/$b" || return 1
    done
}

# ---------------------------------------------------------------- порты

ufw_active() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }

ipt_add() {  # ipt_add tcp 21115:21117
    local proto="$1" ports="$2" n
    iptables -C INPUT -p "$proto" --dport "$ports" -j ACCEPT 2>/dev/null && return 0
    n=$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk '$2=="REJECT" || $2=="DROP" {print $1; exit}')
    if [[ -n "$n" ]]; then
        iptables -I INPUT "$n" -p "$proto" --dport "$ports" -j ACCEPT
    else
        iptables -A INPUT -p "$proto" --dport "$ports" -j ACCEPT
    fi
}

ipt_del() {
    local proto="$1" ports="$2"
    while iptables -C INPUT -p "$proto" --dport "$ports" -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p "$proto" --dport "$ports" -j ACCEPT || break
    done
}

ipt_save() {
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    elif [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4
    else
        echo -e "${YELLOW}Правила iptables сохранить нечем: после перезагрузки сервера их придётся открыть заново (пункт 1).${NC}"
    fi
}

fw_open() {
    if ufw_active; then
        ufw allow 21115:21117/tcp >/dev/null 2>&1
        ufw allow 21116/udp >/dev/null 2>&1
        echo "Порты открыты через ufw: TCP 21115-21117, UDP 21116."
    elif command -v iptables >/dev/null; then
        ipt_add tcp 21115:21117
        ipt_add udp 21116
        ipt_save
        echo "Порты открыты через iptables: TCP 21115-21117, UDP 21116."
    else
        echo -e "${YELLOW}ufw и iptables не найдены: порты в системе не открывал.${NC}"
    fi
}

fw_close() {
    if ufw_active; then
        ufw --force delete allow 21115:21117/tcp >/dev/null 2>&1
        ufw --force delete allow 21116/udp >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null; then
        ipt_del tcp 21115:21117
        ipt_del udp 21116
        ipt_save
    fi
}

# ---------------------------------------------------------------- службы

write_units() {
    cat > "$UNIT_DIR/$SVC_R.service" <<UEOF
[Unit]
Description=RustDesk relay server (hbbr)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=rustdesk
Group=rustdesk
WorkingDirectory=${DATA_DIR}
ExecStart=${BIN_DIR}/hbbr -k _
Restart=always
RestartSec=5
LimitNOFILE=65535
MemoryMax=300M
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UEOF
    cat > "$UNIT_DIR/$SVC_S.service" <<UEOF
[Unit]
Description=RustDesk ID server (hbbs)
After=network-online.target ${SVC_R}.service
Wants=network-online.target ${SVC_R}.service

[Service]
Type=simple
User=rustdesk
Group=rustdesk
WorkingDirectory=${DATA_DIR}
EnvironmentFile=${CONF}
ExecStart=${BIN_DIR}/hbbs -r \${ADDR}:21117 -k _
Restart=always
RestartSec=5
LimitNOFILE=65535
MemoryMax=300M
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UEOF
    systemctl daemon-reload
}

write_update_units() {
    cat > "$UNIT_DIR/$SVC_U.service" <<UEOF
[Unit]
Description=RustDesk Server: проверка и установка обновления

[Service]
Type=oneshot
ExecStart=${SELF} --auto-update
UEOF
    cat > "$UNIT_DIR/$SVC_U.timer" <<UEOF
[Unit]
Description=RustDesk Server: еженедельная проверка обновлений

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UEOF
    systemctl daemon-reload
}

sync_self() {  # копия этого скрипта нужна службе автообновления
    [[ -f "$0" ]] || return 1
    [[ "$(readlink -f "$0")" == "$SELF" ]] && return 0
    install -m 755 "$0" "$SELF"
}

autoupdate_enable() {
    if ! sync_self && [[ ! -x "$SELF" ]]; then
        echo -e "${YELLOW}Не удалось сохранить копию скрипта для автообновления. Запустите его из файла: sudo bash rustdesk.sh${NC}"
        return 1
    fi
    write_update_units
    systemctl enable --now "$SVC_U.timer" >/dev/null 2>&1
}

autoupdate_disable() { systemctl disable --now "$SVC_U.timer" >/dev/null 2>&1; }

wait_both_active() {  # ждёт несколько секунд, что обе службы живы
    local i
    sleep 6
    for i in 1 2 3 4; do
        svc_active "$SVC_S" && svc_active "$SVC_R" || return 1
        sleep 2
    done
    return 0
}

wait_key() {
    local i
    for i in $(seq 1 30); do
        [[ -s "$DATA_DIR/id_ed25519.pub" ]] && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------- старая установка через Docker

migrate_old() {
    if [[ -s "$OLD_DIR/data/id_ed25519" && -s "$OLD_DIR/data/id_ed25519.pub" && ! -s "$DATA_DIR/id_ed25519" ]]; then
        echo -e "\n${YELLOW}Найдена старая установка через Docker: ${OLD_DIR}${NC}"
        if ask_yn "Забрать её ключ, чтобы клиентам ничего не менять?" y; then
            cp -p "$OLD_DIR/data/id_ed25519" "$OLD_DIR/data/id_ed25519.pub" "$DATA_DIR/" && echo "Ключ перенесён."
        fi
    fi
    if command -v docker >/dev/null && timeout 10 docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(hbbs|hbbr)$'; then
        echo -e "\n${YELLOW}Работают старые контейнеры hbbs/hbbr: они занимают те же порты.${NC}"
        if ask_yn "Остановить их и выключить автозапуск?" y; then
            docker update --restart=no hbbs hbbr >/dev/null 2>&1
            docker stop hbbs hbbr >/dev/null 2>&1
            echo "Старые контейнеры остановлены. Папку ${OLD_DIR} я не трогал: удалите её сами, когда убедитесь, что всё работает."
        else
            echo -e "${RED}Пока они работают, новый сервер не сможет занять порты.${NC}"
        fi
    fi
}

# ---------------------------------------------------------------- действия меню

show_data() {
    if [[ ! -s "$DATA_DIR/id_ed25519.pub" ]]; then
        echo -e "${RED}Ключ не найден. Сервер установлен? (пункт 1)${NC}"
        return 1
    fi
    local key addr
    key=$(cat "$DATA_DIR/id_ed25519.pub"); addr=$(conf_value ADDR)
    echo -e "\n${CYAN}=================================================${NC}"
    echo -e "${GREEN} ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ (вводить в клиентах RustDesk)${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e "Сервер ID            : ${YELLOW}${addr}${NC}"
    echo -e "Сервер ретрансляции  : ${YELLOW}оставить пустым${NC} (подтянется сам)"
    echo -e "Сервер API           : ${YELLOW}оставить пустым${NC}"
    echo -e "Key (ключ)           : ${YELLOW}${key}${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo "Куда вводить: приложение RustDesk -> Настройки -> Сеть (на телефоне: Настройки -> Сервер ID/ретрансляции)"
    echo "-> если поля серые, нажмите «Разблокировать» -> впишите данные выше -> «Применить»."
}

do_install() {
    echo -e "\n${YELLOW}=== Установка RustDesk Server ===${NC}"
    describe_server
    local a tag tmp def ip
    a=$(asset_arch) || { echo -e "${RED}Этот тип процессора не поддерживается (нужен x86_64 или aarch64).${NC}"; return 1; }
    if is_installed; then
        ask_yn "Уже установлено (версия $(conf_value VERSION)). Переустановить? Ключ сервера сохранится" n || { echo "Отменено."; return 0; }
    fi
    ensure_deps || return 1

    def=$(conf_value ADDR)
    if [[ -z "$def" ]]; then
        echo "Определяю публичный IP сервера..."
        ip=$(get_ip) || ip=""
        def="$ip"
        [[ -z "$def" ]] && echo -e "${YELLOW}Автоматически определить IP не удалось, введите его сами.${NC}"
    fi
    ask_address "$def" || return 1

    echo "Узнаю последнюю версию..."
    tag=$(latest_tag)
    [[ -n "$tag" ]] || { echo -e "${RED}Нет связи с GitHub, версию узнать не удалось. Попробуйте позже.${NC}"; return 1; }
    tmp=$(mktemp -d)
    echo "Скачиваю версию $tag ($a)..."
    if ! fetch_release "$tag" "$tmp"; then
        echo -e "${RED}Не удалось скачать или распаковать файлы версии $tag.${NC}"
        rm -rf "$tmp"; return 1
    fi

    systemctl stop "$SVC_S" "$SVC_R" >/dev/null 2>&1
    id rustdesk >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin rustdesk
    mkdir -p "$DATA_DIR" "$BIN_DIR"
    migrate_old
    put_bins "$tmp" || { echo -e "${RED}Не удалось записать файлы в $BIN_DIR.${NC}"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    chown -R rustdesk:rustdesk "$DATA_DIR"; chmod 700 "$DATA_DIR"

    conf_set ADDR "$ADDRESS"
    conf_set VERSION "$tag"
    write_units
    fw_open
    systemctl enable --now "$SVC_R" "$SVC_S" >/dev/null 2>&1

    if [[ ! -s "$DATA_DIR/id_ed25519.pub" ]]; then
        echo "Жду создания ключа (до 30 секунд)..."
        wait_key || { echo -e "${RED}Ключ не появился. Смотрите журнал: пункт 3.${NC}"; return 1; }
    fi
    chown -R rustdesk:rustdesk "$DATA_DIR"

    if autoupdate_enable; then
        echo "Автообновление включено (раз в неделю, ночью с воскресенья)."
    fi
    echo -e "${GREEN}✅ Установка завершена. Версия: $tag${NC}"
    show_data
}

show_status() {
    echo -e "\n${YELLOW}📊 [СТАТУС]${NC}"
    describe_server
    if ! is_installed; then echo "RustDesk Server не установлен (пункт 1)."; return; fi
    local mem p
    echo "Версия: $(conf_value VERSION); адрес для клиентов: $(conf_value ADDR)"
    for s in "$SVC_S" "$SVC_R"; do
        mem=$(systemctl show -p MemoryCurrent --value "$s" 2>/dev/null)
        [[ "$mem" =~ ^[0-9]+$ ]] && mem="$((mem / 1048576)) МБ" || mem="?"
        echo "Служба $s: $(systemctl is-active "$s") (автозапуск: $(systemctl is-enabled "$s" 2>/dev/null)), память $mem"
    done
    local listen=""
    for p in 21115 21116 21117; do ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . && listen+="TCP $p; "; done
    ss -H -lun "sport = :21116" 2>/dev/null | grep -q . && listen+="UDP 21116"
    echo "Слушает порты: ${listen:-нет}"
    if autoupdate_on_now; then
        echo "Автообновление: ВКЛ (следующая проверка: $(systemctl show -p NextElapseUSecRealtime --value "$SVC_U.timer" 2>/dev/null))"
    else
        echo "Автообновление: ВЫКЛ"
    fi
    echo "Журнал служб (последние записи):"
    journalctl -u "$SVC_S" -u "$SVC_R" -n 8 --no-pager -o short 2>/dev/null | sed 's/^/   /'
    if [[ -f "$UPD_LOG" ]]; then
        echo "Журнал обновлений (последние записи):"
        tail -n 5 "$UPD_LOG" | sed 's/^/   /'
    fi
}

do_restart() {
    is_installed || { echo -e "${RED}Сначала установите (пункт 1).${NC}"; return 1; }
    systemctl restart "$SVC_R" "$SVC_S"
    if wait_both_active; then
        echo -e "${GREEN}✅ Перезапущено, обе службы работают.${NC}"
    else
        echo -e "${RED}Служба не поднялась. Смотрите журнал: пункт 3.${NC}"
    fi
}

do_update() {  # do_update auto|manual
    local mode="${1:-manual}" cur latest tmp
    is_installed || { ulog "RustDesk Server не установлен, обновлять нечего"; return 1; }
    exec 9>"$LOCK"
    flock -n 9 || { ulog "обновление уже выполняется"; return 1; }
    cur=$(conf_value VERSION)
    latest=$(latest_tag)
    [[ -n "$latest" ]] || { ulog "[$mode] не удалось узнать последнюю версию (нет связи с GitHub)"; return 1; }
    if [[ "$cur" == "$latest" ]]; then
        ulog "[$mode] проверка: уже последняя версия ($cur)"
        return 0
    fi
    ulog "[$mode] найдена новая версия: ${cur:-?} -> $latest, обновляю"
    tmp=$(mktemp -d)
    if ! fetch_release "$latest" "$tmp"; then
        ulog "[$mode] ошибка загрузки версии $latest, остаюсь на ${cur:-текущей}"
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$BIN_DIR.bak"; cp -a "$BIN_DIR" "$BIN_DIR.bak"
    if put_bins "$tmp"; then
        systemctl restart "$SVC_R" "$SVC_S"
        if wait_both_active; then
            conf_set VERSION "$latest"
            ulog "[$mode] обновлено до $latest, службы работают"
            rm -rf "$tmp"
            return 0
        fi
        ulog "[$mode] версия $latest не запустилась, делаю откат на ${cur:-прежнюю}"
    else
        ulog "[$mode] не удалось записать файлы версии $latest, делаю откат"
    fi
    rm -rf "$tmp"
    systemctl stop "$SVC_S" "$SVC_R" >/dev/null 2>&1
    cp -a "$BIN_DIR.bak/." "$BIN_DIR/"
    systemctl start "$SVC_R" "$SVC_S"
    if wait_both_active; then
        ulog "[$mode] откат выполнен, работает версия ${cur:-прежняя}"
    else
        ulog "[$mode] ВНИМАНИЕ: после отката службы не поднялись, смотрите journalctl -u $SVC_S -u $SVC_R"
    fi
    return 1
}

do_update_now() {
    is_installed || { echo -e "${RED}Сначала установите (пункт 1).${NC}"; return 1; }
    ensure_deps || return 1
    echo "Проверяю обновления..."
    do_update manual && echo -e "${GREEN}Готово.${NC}" || echo -e "${YELLOW}Обновление не выполнено, подробности выше и в журнале (пункт 3).${NC}"
}

do_toggle_autoupdate() {
    is_installed || { echo -e "${RED}Сначала установите (пункт 1).${NC}"; return 1; }
    if autoupdate_on_now; then
        autoupdate_disable
        echo -e "${GREEN}Автообновление выключено.${NC}"
    elif autoupdate_enable; then
        echo -e "${GREEN}Автообновление включено: раз в неделю, ночью с воскресенья. Результат пишется в журнал (пункт 3).${NC}"
    fi
}

do_change_address() {
    is_installed || { echo -e "${RED}Сначала установите (пункт 1).${NC}"; return 1; }
    echo -e "\n${YELLOW}=== Сменить адрес сервера ===${NC}"
    echo "Текущий адрес: $(conf_value ADDR)"
    local ip; ip=$(get_ip) || ip=""
    [[ -n "$ip" ]] && echo "Определённый сейчас публичный IP: $ip"
    ask_address "${ip:-$(conf_value ADDR)}" || return 1
    conf_set ADDR "$ADDRESS"
    systemctl restart "$SVC_R" "$SVC_S"
    wait_both_active || echo -e "${RED}Службы не поднялись, смотрите журнал: пункт 3.${NC}"
    echo -e "${GREEN}✅ Адрес изменён. Ключ прежний.${NC} Не забудьте поменять «Сервер ID» в клиентах."
    show_data
}

do_uninstall() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ]${NC}"
    if ! is_installed && [[ ! -d "$DATA_DIR" && ! -f "$CONF" ]]; then
        echo -e "${GREEN}Удалять нечего.${NC}"; return
    fi
    ask_yn "Удалить RustDesk Server (службы, программу, настройки, правила портов)?" n || { echo "Отменено."; return; }
    local drop_key=0
    if [[ -d "$DATA_DIR" ]]; then
        echo "Ключ сервера лежит в $DATA_DIR. Если его удалить, при новой установке ключ будет другим, и его придётся заново вписывать во всех клиентах."
        ask_yn "Удалить и ключ?" n && drop_key=1
    fi
    systemctl disable --now "$SVC_U.timer" "$SVC_S" "$SVC_R" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$SVC_S.service" "$UNIT_DIR/$SVC_R.service" "$UNIT_DIR/$SVC_U.service" "$UNIT_DIR/$SVC_U.timer"
    systemctl daemon-reload
    fw_close
    rm -rf "$BIN_DIR" "$BIN_DIR.bak" "$UPD_LOG"
    if (( drop_key )); then
        rm -rf "$DATA_DIR" "$CONF"
        id rustdesk >/dev/null 2>&1 && userdel rustdesk >/dev/null 2>&1
    else
        sed -i '/^VERSION=/d' "$CONF" 2>/dev/null
        echo "Ключ и адрес сохранены ($DATA_DIR, $CONF)."
    fi
    rm -f "$SELF"
    echo -e "${GREEN}✅ Готово. RustDesk Server удалён.${NC}"
}

# ---------------------------------------------------------------- запуск без меню (для службы автообновления)

if [[ "$1" == "--auto-update" ]]; then
    do_update auto
    exit $?
fi

# ---------------------------------------------------------------- МЕНЮ

state_line() {
    if is_installed; then
        local au="ВЫКЛ"
        autoupdate_on_now && au="ВКЛ"
        if svc_active "$SVC_S" && svc_active "$SVC_R"; then
            echo -e "Состояние: ${GREEN}установлено, версия $(conf_value VERSION), службы работают${NC}; автообновление: $au"
        else
            echo -e "Состояние: ${RED}установлено, но службы не работают${NC} (смотрите пункт 3); автообновление: $au"
        fi
    else
        echo -e "Состояние: ${YELLOW}не установлено${NC}"
    fi
}

# освежаем копию скрипта для автообновления (если оно включено)
if is_installed && autoupdate_on_now; then sync_self >/dev/null 2>&1; fi

while true; do
    echo -e "\n${YELLOW}===== RustDesk Server: свой сервер удалённого доступа =====${NC}"
    describe_server
    state_line
    echo "1. Установить / переустановить"
    echo "2. Данные для подключения (адрес и ключ)"
    echo "3. Статус и журнал"
    echo "4. Перезапустить"
    echo "5. Обновить сейчас"
    echo "6. Автообновление: включить / выключить"
    echo "7. Сменить адрес (IP или домен)"
    echo "8. Удалить"
    echo "0. Выход"
    read -rp "Пункт: " c || exit 0
    case "$c" in
        1) do_install ;;
        2) show_data ;;
        3) show_status ;;
        4) do_restart ;;
        5) do_update_now ;;
        6) do_toggle_autoupdate ;;
        7) do_change_address ;;
        8) do_uninstall ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
