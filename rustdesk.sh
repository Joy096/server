#!/bin/bash
# =====================================================================
#  RustDesk Server: свой сервер удалённого доступа (hbbs + hbbr)
#  Запуск:  sudo bash rustdesk.sh      (на самом сервере Oracle)
#  Без Docker, службами systemd; Micro (AMD) и Ampere (ARM) определяются сами; только по ключу (-k _);
#  порты через ufw или iptables; автообновление раз в неделю с откатом; перенос ключа из Docker-установки;
#  пункт 9: API-сервер (lejianwen/rustdesk-api) для входа в аккаунт, адресной книги и Google.
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

# API-сервер (вход в аккаунт и адресная книга)
API_REPO="lejianwen/rustdesk-api"
API_DIR="/opt/rustdesk-api"
API_CONF="/etc/rustdesk-api.conf"
API_ENV="/etc/rustdesk-api.env"
API_NGINX_DIR="/etc/rustdesk-api"
CERT_ROOT="/root/my_cert"                  # сюда ssl.sh кладёт сертификаты: /root/my_cert/<домен>/
SVC_A="rustdesk-api"
SVC_AT="rustdesk-api-tls"
SVC_ATR="rustdesk-api-tls-reload"
API_PORT=21114                             # порт для клиентов (HTTPS или HTTP)
API_LOCAL_PORT=21124                       # внутренний порт за nginx (только при HTTPS)

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
    api_refresh   # если API-сервер уже стоит, он получит актуальные адрес и ключ

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
    api_refresh
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
    api_installed && echo -e "${YELLOW}API-сервер (пункт 9) не затронут: удалите его отдельно, если он больше не нужен.${NC}"
}

# ================================================================ API-сервер: вход в аккаунт и адресная книга
# Сторонняя программа lejianwen/rustdesk-api (не от RustDesk). Работает рядом с hbbs/hbbr,
# ничего в них не меняет. Клиент подключается к ней через поле «Сервер API».

kv_get() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); gsub(/^[ \t"]+|[ \t"]+$/,""); print; exit}' "$1" 2>/dev/null; }

kv_set() {  # kv_set файл ключ значение
    touch "$1"; chmod 644 "$1"
    if grep -q "^$2=" "$1" 2>/dev/null; then
        sed -i "s|^$2=.*|$2=$3|" "$1"
    else
        echo "$2=$3" >> "$1"
    fi
}

api_installed() { [[ -x "$API_DIR/apimain" && -f "$UNIT_DIR/$SVC_A.service" ]]; }
api_tls_on()    { [[ "$(kv_get "$API_CONF" API_TLS)" == "1" ]]; }
api_local_port() { if api_tls_on; then echo "$API_LOCAL_PORT"; else echo "$API_PORT"; fi; }

api_url() {  # адрес, который вписывают в поле «Сервер API»
    local d; d=$(kv_get "$API_CONF" API_DOMAIN)
    if api_tls_on; then echo "https://$d:$API_PORT"; else echo "http://${d:-$(conf_value ADDR)}:$API_PORT"; fi
}

api_up() {  # программа отвечает на внутреннем порту
    local c
    c=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "http://127.0.0.1:$(api_local_port)/_admin/" 2>/dev/null)
    [[ -n "$c" && "$c" != "000" && "$c" != "502" ]]
}

api_wait_up() {
    local i
    for i in $(seq 1 30); do api_up && return 0; sleep 1; done
    return 1
}

api_latest_tag() {
    curl -s -m 15 -o /dev/null -w '%{redirect_url}' "https://github.com/$API_REPO/releases/latest" 2>/dev/null \
        | sed -n 's|.*/tag/||p' | tr -d '[:space:]'
}

api_fetch() {  # api_fetch версия папка -> API_PKG = папка с файлом apimain
    local tag="$1" dest="$2" a bin
    case "$(uname -m)" in
        x86_64|amd64)  a="amd64" ;;
        aarch64|arm64) a="arm64" ;;
        *) return 1 ;;
    esac
    curl -fL -s -m 240 --retry 2 -o "$dest/api.tar.gz" "https://github.com/$API_REPO/releases/download/$tag/linux-$a.tar.gz" || return 1
    mkdir -p "$dest/x"
    tar -xzf "$dest/api.tar.gz" -C "$dest/x" || return 1
    bin=$(find "$dest/x" -type f -name apimain | head -n 1)
    [[ -n "$bin" ]] || return 1
    chmod 755 "$bin"
    API_PKG=$(dirname "$bin")
    return 0
}

api_put_files() {  # api_put_files папка_с_apimain : conf, data и runtime (настройки, база, журнал) не трогает
    local src="$1" it n
    mkdir -p "$API_DIR"
    for it in "$src"/*; do
        n=$(basename "$it")
        case "$n" in conf|data|runtime) continue ;; esac
        rm -rf "${API_DIR:?}/$n"
        cp -a "$it" "$API_DIR/$n" || return 1
    done
    if [[ ! -d "$API_DIR/conf" && -d "$src/conf" ]]; then cp -a "$src/conf" "$API_DIR/conf" || return 1; fi
    [[ -f "$API_DIR/conf/config.yaml" ]] || return 1
    mkdir -p "$API_DIR/data" "$API_DIR/runtime" "$API_DIR/conf/data"
    chown -R rustdesk-api:rustdesk-api "$API_DIR"
    chown root:root "$API_DIR/apimain"
    return 0
}

api_write_env() {  # настройки программы: адреса, ключ, порт
    local addr key la
    addr=$(conf_value ADDR); key=$(cat "$DATA_DIR/id_ed25519.pub" 2>/dev/null)
    if api_tls_on; then la="127.0.0.1:$API_LOCAL_PORT"; else la="0.0.0.0:$API_PORT"; fi
    cat > "$API_ENV" <<EEOF
RUSTDESK_API_LANG="en"
RUSTDESK_API_APP_WEB_CLIENT="0"
RUSTDESK_API_GIN_API_ADDR="${la}"
RUSTDESK_API_RUSTDESK_ID_SERVER="${addr}:21116"
RUSTDESK_API_RUSTDESK_RELAY_SERVER="${addr}:21117"
RUSTDESK_API_RUSTDESK_API_SERVER="$(api_url)"
RUSTDESK_API_RUSTDESK_KEY="${key}"
EEOF
    chown root:rustdesk-api "$API_ENV"; chmod 640 "$API_ENV"
    # публичный ключ ещё и файлом (так его читает сама программа), и адрес прослушивания в конфиге
    mkdir -p "$API_DIR/conf/data"
    printf '%s' "$key" > "$API_DIR/conf/data/id_ed25519.pub"
    chown -R rustdesk-api:rustdesk-api "$API_DIR/conf/data"
    sed -i -E "s|^([[:space:]]*api-addr:).*|\1 \"${la}\"|" "$API_DIR/conf/config.yaml"
}

api_write_units() {
    cat > "$UNIT_DIR/$SVC_A.service" <<UEOF
[Unit]
Description=RustDesk API server (вход и адресная книга)
After=network-online.target ${SVC_S}.service
Wants=network-online.target

[Service]
Type=simple
User=rustdesk-api
Group=rustdesk-api
WorkingDirectory=${API_DIR}
EnvironmentFile=${API_ENV}
ExecStart=${API_DIR}/apimain
Restart=always
RestartSec=5
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

api_write_tls() {  # nginx перед программой: HTTPS на порту 21114, сертификат берётся из ssl.sh
    local d nginx_bin
    d=$(kv_get "$API_CONF" API_DOMAIN); nginx_bin=$(command -v nginx)
    mkdir -p "$API_NGINX_DIR"
    cat > "$API_NGINX_DIR/nginx.conf" <<NEOF
worker_processes 1;
pid /run/${SVC_AT}.pid;
error_log /var/log/${SVC_AT}.log warn;
events { worker_connections 256; }
http {
    access_log off;
    server {
        listen ${API_PORT} ssl;
        server_name ${d};
        ssl_certificate ${CERT_ROOT}/${d}/fullchain.pem;
        ssl_certificate_key ${CERT_ROOT}/${d}/private.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        client_max_body_size 5m;
        location / {
            proxy_pass http://127.0.0.1:${API_LOCAL_PORT};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
NEOF
    cat > "$UNIT_DIR/$SVC_AT.service" <<UEOF
[Unit]
Description=HTTPS для RustDesk API server (nginx)
After=network-online.target ${SVC_A}.service
Wants=${SVC_A}.service

[Service]
Type=simple
ExecStartPre=${nginx_bin} -t -c ${API_NGINX_DIR}/nginx.conf
ExecStart=${nginx_bin} -c ${API_NGINX_DIR}/nginx.conf -g 'daemon off;'
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
MemoryMax=100M

[Install]
WantedBy=multi-user.target
UEOF
    # сертификат продлевается раз в ~2 месяца; раз в сутки nginx перечитывает файлы
    cat > "$UNIT_DIR/$SVC_ATR.service" <<UEOF
[Unit]
Description=Перечитать сертификат для RustDesk API server

[Service]
Type=oneshot
ExecStart=/bin/systemctl reload ${SVC_AT}.service
UEOF
    cat > "$UNIT_DIR/$SVC_ATR.timer" <<UEOF
[Unit]
Description=Ежедневное перечитывание сертификата для RustDesk API server

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
UEOF
    systemctl daemon-reload
}

api_ensure_nginx() {
    command -v nginx >/dev/null && return 0
    echo "Ставлю nginx (нужен для HTTPS)..."
    local made=0
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; made=1
    fi
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y nginx >/dev/null 2>&1
    (( made )) && rm -f /usr/sbin/policy-rc.d
    command -v nginx >/dev/null || { echo -e "${RED}Не удалось поставить nginx.${NC}"; return 1; }
    kv_set "$API_CONF" NGINX_ADDED 1
    systemctl disable --now nginx >/dev/null 2>&1   # стандартная служба nginx не нужна, у нас своя
    return 0
}

api_apply() {  # применяет настройки из $API_CONF: файлы, службы, порт
    api_write_env || return 1
    api_write_units
    if api_tls_on; then
        api_ensure_nginx || return 1
        api_write_tls
    else
        systemctl disable --now "$SVC_AT" "$SVC_ATR.timer" >/dev/null 2>&1
    fi
    if ufw_active; then
        ufw allow "$API_PORT/tcp" >/dev/null 2>&1
    elif command -v iptables >/dev/null; then
        ipt_add tcp "$API_PORT"; ipt_save
    fi
    systemctl enable "$SVC_A" >/dev/null 2>&1
    systemctl restart "$SVC_A"
    if api_tls_on; then
        systemctl enable "$SVC_AT" "$SVC_ATR.timer" >/dev/null 2>&1
        systemctl restart "$SVC_AT"
        systemctl start "$SVC_ATR.timer" >/dev/null 2>&1
    fi
    api_wait_up
}

api_refresh() {  # после смены адреса/ключа сервера: обновить настройки API (если он установлен)
    api_installed || return 0
    api_write_env
    systemctl restart "$SVC_A"
}

api_gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16; }

api_read_password() {  # спрашивает пароль админки -> API_PW_NEW; API_PW_OWN=1, если ввели свой
    local p1 p2
    API_PW_OWN=0; API_PW_NEW=""
    echo "Пароль администратора (логин admin): введите свой, минимум 8 символов, или нажмите Enter, и я придумаю случайный."
    while true; do
        read -rsp "Пароль: " p1 || return 1; echo
        if [[ -z "$p1" ]]; then API_PW_NEW=$(api_gen_password); return 0; fi
        if (( ${#p1} < 8 )); then echo -e "${RED}Слишком короткий, минимум 8 символов. Введите ещё раз.${NC}"; continue; fi
        read -rsp "Повторите пароль: " p2 || return 1; echo
        if [[ "$p1" != "$p2" ]]; then echo -e "${RED}Пароли не совпали. Введите ещё раз.${NC}"; continue; fi
        API_PW_NEW="$p1"; API_PW_OWN=1
        return 0
    done
}

api_set_password() {  # api_set_password пароль
    runuser -u rustdesk-api -- bash -c 'set -a; . "$1"; set +a; cd "$2" && ./apimain reset-admin-pwd "$3"' _ "$API_ENV" "$API_DIR" "$1" >/dev/null 2>&1
}

api_guess_domain() {  # домен по умолчанию: прежний; затем адрес сервера (если это домен с сертификатом); затем самый новый сертификат ssl.sh
    local d a
    d=$(kv_get "$API_CONF" API_DOMAIN)
    if [[ -n "$d" ]]; then echo "$d"; return 0; fi
    a=$(conf_value ADDR)
    if [[ -n "$a" ]] && ! valid_ip "$a" && [[ -s "$CERT_ROOT/$a/fullchain.pem" && -s "$CERT_ROOT/$a/private.key" ]]; then echo "$a"; return 0; fi
    for d in $(ls -1t "$CERT_ROOT" 2>/dev/null); do
        if [[ -s "$CERT_ROOT/$d/fullchain.pem" && -s "$CERT_ROOT/$d/private.key" ]]; then echo "$d"; return 0; fi
    done
    return 1
}

api_choose_mode() {  # спрашивает домен и решает, будет ли HTTPS -> API_DOMAIN_NEW, API_TLS_NEW
    local def d
    def=$(api_guess_domain) || def=""
    echo "Для входа через Google и безопасной передачи пароля нужен домен, который указывает на этот сервер,"
    echo "и сертификат от ssl.sh (папка ${CERT_ROOT}/<домен>/)."
    [[ -d "$CERT_ROOT" ]] && ls -1t "$CERT_ROOT" 2>/dev/null | sed 's/^/   сертификат есть для: /'
    [[ -n "$def" ]] && echo "Домен определён автоматически: $def"
    while true; do
        if [[ -n "$def" ]]; then
            read -rp "Домен для API-сервера [Enter = $def, «-» = без домена]: " d || return 1
            d="${d:-$def}"
        else
            read -rp "Домен для API-сервера [Enter = без домена, только по IP]: " d || return 1
        fi
        [[ "$d" == "-" ]] && d=""
        if [[ -z "$d" || "$d" =~ ^[A-Za-z0-9.-]+$ ]]; then break; fi
        echo -e "${RED}Нужен домен (буквы, цифры, точки, дефис).${NC}"
    done
    API_DOMAIN_NEW="$d"; API_TLS_NEW=0
    if [[ -z "$d" ]]; then
        echo -e "${YELLOW}Без домена HTTPS не будет: пароль пойдёт по сети открытым текстом, вход через Google недоступен.${NC}"
        ask_yn "Всё равно продолжить без HTTPS?" n || return 1
        return 0
    fi
    local ip dip
    ip=$(get_ip) || ip=""
    dip=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z "$dip" ]]; then
        echo -e "${YELLOW}Домен $d пока не находится в DNS. Проверьте запись A (она должна указывать на ${ip:-IP сервера}).${NC}"
    elif [[ -n "$ip" && "$dip" != "$ip" ]]; then
        echo -e "${YELLOW}Домен $d указывает на $dip, а IP этого сервера $ip. Если это не прокси, поправьте запись A.${NC}"
    fi
    if [[ -s "$CERT_ROOT/$d/fullchain.pem" && -s "$CERT_ROOT/$d/private.key" ]]; then
        if command -v openssl >/dev/null && openssl x509 -in "$CERT_ROOT/$d/fullchain.pem" -noout -checkhost "$d" 2>/dev/null | grep -qi "does NOT match"; then
            echo -e "${YELLOW}Сертификат из ssl.sh выпущен не на $d. HTTPS не заработает без сертификата на этот адрес.${NC}"
            ask_yn "Продолжить без HTTPS?" n || return 1
            return 0
        fi
        API_TLS_NEW=1
        return 0
    fi
    echo -e "${YELLOW}Сертификата для $d нет. Выпустите его: sudo bash ssl.sh -> пункт 1, потом вернитесь сюда.${NC}"
    ask_yn "Продолжить без HTTPS сейчас? (HTTPS можно включить позже пунктом 5 этого раздела)" n || return 1
    return 0
}

api_show() {
    if ! api_installed; then echo -e "${RED}API-сервер не установлен (пункт 1 этого раздела).${NC}"; return 1; fi
    local url d
    url=$(api_url); d=$(kv_get "$API_CONF" API_DOMAIN)
    echo -e "\n${CYAN}=================================================${NC}"
    echo -e "${GREEN} API-СЕРВЕР: ВХОД И АДРЕСНАЯ КНИГА${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e "Сервер API для настроек RustDesk : ${YELLOW}${url}${NC}"
    echo -e "Админка                          : ${YELLOW}${url}/_admin/${NC}  (логин admin; пароль вы задали при установке, забыли: пункт 4)"
    echo -e "${CYAN}=================================================${NC}"
    echo "1) Пользователь. Зайдите в админку и создайте обычного пользователя (раздел пользователей). Под admin в клиентах лучше не входить."
    echo "2) Клиент. Приложение RustDesk -> Настройки -> Сеть -> «Разблокировать» -> «Сервер API»: впишите адрес выше -> «Применить»."
    echo "   Затем откройте вкладку адресной книги / кнопку «Войти» и войдите созданным пользователем."
    echo "   После входа адреса ID-сервера, ретранслятора и ключ клиент получит сам."
    if api_tls_on; then
        echo "3) Кнопка Google (по желанию):"
        echo "   a) console.cloud.google.com -> создайте проект -> «API и сервисы» -> «Экран согласия OAuth» -> тип External, имя и почта."
        echo "      Пока приложение в режиме тестирования, добавьте свою почту в «Тестовые пользователи»."
        echo "   b) «Учётные данные» -> «Создать учётные данные» -> «Идентификатор клиента OAuth» -> тип «Веб-приложение»."
        echo "      В «Разрешённые URI перенаправления» впишите: ${url}/api/oidc/callback"
        echo "   c) Скопируйте Client ID и Client Secret. В админке откройте раздел OAuth (название в меню может чуть отличаться),"
        echo "      добавьте провайдера Google, вставьте Client ID и Client Secret, сохраните."
        echo "   d) В клиенте на экране входа появится кнопка Google. Первый вход проверьте сами: как программа сопоставляет Google-аккаунт"
        echo "      с пользователем, зависит от её версии (смотрите разделы пользователей и OAuth в админке)."
    else
        echo -e "${YELLOW}HTTPS выключен: пароль идёт по сети открытым текстом, кнопка Google недоступна. Включить: пункт 5 этого раздела.${NC}"
    fi
    echo "Язык админки: программа поддерживает только английский и китайский, скрипт ставит английский."
}

api_install() {
    echo -e "\n${YELLOW}=== Установка API-сервера (вход и адресная книга) ===${NC}"
    describe_server
    if [[ ! -s "$DATA_DIR/id_ed25519.pub" ]]; then
        echo -e "${RED}Сначала установите сам сервер RustDesk (пункт 1 главного меню).${NC}"; return 1
    fi
    case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ;; *) echo -e "${RED}Этот тип процессора не поддерживается.${NC}"; return 1 ;; esac
    echo "Это сторонняя программа lejianwen/rustdesk-api (не от RustDesk). Она хранит логины и список ваших устройств, поэтому обновляйте её вовремя."
    if api_installed; then
        ask_yn "Уже установлено (версия $(kv_get "$API_CONF" API_VERSION)). Переустановить? Пользователи и адресные книги сохранятся" n || { echo "Отменено."; return 0; }
    fi
    api_choose_mode || { echo "Отменено."; return 0; }
    echo
    api_read_password || { echo "Отменено."; return 0; }
    ensure_deps || return 1
    local tag tmp
    echo "Узнаю последнюю версию..."
    tag=$(api_latest_tag)
    [[ -n "$tag" ]] || { echo -e "${RED}Нет связи с GitHub, версию узнать не удалось. Попробуйте позже.${NC}"; return 1; }
    tmp=$(mktemp -d)
    echo "Скачиваю версию $tag..."
    if ! api_fetch "$tag" "$tmp"; then
        echo -e "${RED}Не удалось скачать или распаковать версию $tag.${NC}"
        rm -rf "$tmp"; return 1
    fi
    systemctl stop "$SVC_A" "$SVC_AT" >/dev/null 2>&1
    id rustdesk-api >/dev/null 2>&1 || useradd --system --home-dir "$API_DIR" --shell /usr/sbin/nologin rustdesk-api
    mkdir -p "$API_DIR"
    if ! api_put_files "$API_PKG"; then
        echo -e "${RED}Не удалось разложить файлы (в архиве нет conf/config.yaml?).${NC}"
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    kv_set "$API_CONF" API_DOMAIN "$API_DOMAIN_NEW"
    kv_set "$API_CONF" API_TLS "$API_TLS_NEW"
    kv_set "$API_CONF" API_VERSION "$tag"
    echo "Настраиваю и запускаю..."
    if ! api_apply; then
        echo -e "${RED}Программа не ответила за 30 секунд. Смотрите журнал: пункт 3 этого раздела.${NC}"
        return 1
    fi
    if [[ -n "$API_PW_NEW" ]] && api_set_password "$API_PW_NEW"; then
        if (( API_PW_OWN )); then
            echo -e "\n${GREEN}Пароль администратора (логин admin) задан: тот, что вы ввели.${NC}"
        else
            echo -e "\n${GREEN}Пароль администратора (логин admin). Он показан только сейчас, сохраните его:${NC}"
            echo -e "   ${YELLOW}${API_PW_NEW}${NC}"
        fi
    else
        echo -e "${YELLOW}Не удалось задать пароль администратора. Первый пароль программа выводит в журнал: journalctl -u ${SVC_A} | head -n 40, или задайте свой: пункт 4 этого раздела.${NC}"
    fi
    echo -e "${GREEN}✅ Установка завершена. Версия: $tag${NC}"
    api_show
}

api_status() {
    echo -e "\n${YELLOW}📊 [СТАТУС API-СЕРВЕРА]${NC}"
    if ! api_installed; then echo "Не установлен (пункт 1 этого раздела)."; return; fi
    local mem s
    echo "Версия: $(kv_get "$API_CONF" API_VERSION); сервер API для настроек RustDesk: $(api_url)"
    local list=("$SVC_A")
    api_tls_on && list+=("$SVC_AT")
    for s in "${list[@]}"; do
        mem=$(systemctl show -p MemoryCurrent --value "$s" 2>/dev/null)
        [[ "$mem" =~ ^[0-9]+$ ]] && mem="$((mem / 1048576)) МБ" || mem="?"
        echo "Служба $s: $(systemctl is-active "$s") (автозапуск: $(systemctl is-enabled "$s" 2>/dev/null)), память $mem"
    done
    if api_up; then echo "Программа отвечает: да"; else echo -e "${RED}Программа отвечает: нет${NC}"; fi
    if api_tls_on; then
        local d end
        d=$(kv_get "$API_CONF" API_DOMAIN)
        if command -v openssl >/dev/null && [[ -s "$CERT_ROOT/$d/fullchain.pem" ]]; then
            end=$(openssl x509 -in "$CERT_ROOT/$d/fullchain.pem" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
            echo "HTTPS: включён, сертификат действует до: ${end:-?}"
        else
            echo -e "${RED}HTTPS: включён, но файл сертификата не найден в ${CERT_ROOT}/${d}/${NC}"
        fi
    else
        echo "HTTPS: выключен"
    fi
    echo "Журнал (последние записи):"
    journalctl -u "$SVC_A" -u "$SVC_AT" -n 8 --no-pager -o short 2>/dev/null | sed 's/^/   /'
}

api_password_change() {
    api_installed || { echo -e "${RED}Сначала установите (пункт 1 этого раздела).${NC}"; return 1; }
    echo -e "\n${YELLOW}=== Сменить пароль администратора ===${NC}"
    api_read_password || { echo "Отменено."; return 0; }
    if api_set_password "$API_PW_NEW"; then
        echo -e "${GREEN}✅ Пароль admin изменён.${NC}"
        (( API_PW_OWN )) || echo -e "Новый пароль: ${YELLOW}${API_PW_NEW}${NC} (сохраните сейчас)"
    else
        echo -e "${RED}Не удалось сменить пароль. Смотрите журнал: пункт 3 этого раздела.${NC}"
    fi
}

api_enable_https() {
    api_installed || { echo -e "${RED}Сначала установите (пункт 1 этого раздела).${NC}"; return 1; }
    echo -e "\n${YELLOW}=== Подключить HTTPS (сертификат из ssl.sh) ===${NC}"
    api_choose_mode || { echo "Отменено."; return 0; }
    kv_set "$API_CONF" API_DOMAIN "$API_DOMAIN_NEW"
    kv_set "$API_CONF" API_TLS "$API_TLS_NEW"
    echo "Применяю..."
    if api_apply; then
        echo -e "${GREEN}✅ Готово.${NC} Не забудьте поменять «Сервер API» в клиентах на новый адрес."
        api_show
    else
        echo -e "${RED}Программа не ответила за 30 секунд. Смотрите журнал: пункт 3 этого раздела.${NC}"
    fi
}

api_update() {
    api_installed || { echo -e "${RED}Сначала установите (пункт 1 этого раздела).${NC}"; return 1; }
    ensure_deps || return 1
    local cur latest tmp
    cur=$(kv_get "$API_CONF" API_VERSION)
    echo "Проверяю обновления..."
    latest=$(api_latest_tag)
    [[ -n "$latest" ]] || { echo -e "${RED}Нет связи с GitHub.${NC}"; return 1; }
    if [[ "$cur" == "$latest" ]]; then echo -e "${GREEN}Уже последняя версия ($cur).${NC}"; return 0; fi
    echo "Найдена новая версия: ${cur:-?} -> $latest"
    tmp=$(mktemp -d)
    if ! api_fetch "$latest" "$tmp"; then
        echo -e "${RED}Не удалось скачать версию $latest, остаюсь на ${cur:-текущей}.${NC}"
        rm -rf "$tmp"; return 1
    fi
    systemctl stop "$SVC_A" >/dev/null 2>&1
    rm -rf "$API_DIR.bak"; mkdir -p "$API_DIR.bak"
    cp -a "$API_DIR/apimain" "$API_DIR.bak/apimain"
    [[ -d "$API_DIR/resources" ]] && cp -a "$API_DIR/resources" "$API_DIR.bak/resources"
    if api_put_files "$API_PKG"; then
        systemctl start "$SVC_A"
        if api_wait_up; then
            kv_set "$API_CONF" API_VERSION "$latest"
            rm -rf "$tmp"
            echo -e "${GREEN}✅ Обновлено до $latest.${NC}"
            return 0
        fi
        echo -e "${RED}Версия $latest не запустилась, откатываю.${NC}"
    else
        echo -e "${RED}Не удалось записать файлы версии $latest, откатываю.${NC}"
    fi
    rm -rf "$tmp"
    systemctl stop "$SVC_A" >/dev/null 2>&1
    cp -a "$API_DIR.bak/apimain" "$API_DIR/apimain"
    if [[ -d "$API_DIR.bak/resources" ]]; then rm -rf "$API_DIR/resources"; cp -a "$API_DIR.bak/resources" "$API_DIR/resources"; fi
    chown -R rustdesk-api:rustdesk-api "$API_DIR"; chown root:root "$API_DIR/apimain"
    systemctl start "$SVC_A"
    if api_wait_up; then echo "Откат выполнен, работает версия ${cur:-прежняя}."; else echo -e "${RED}После отката программа не отвечает, смотрите журнал: пункт 3.${NC}"; fi
    return 1
}

api_remove() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ API-СЕРВЕРА]${NC}"
    if ! api_installed && [[ ! -d "$API_DIR" && ! -f "$API_CONF" ]]; then echo -e "${GREEN}Удалять нечего.${NC}"; return; fi
    ask_yn "Удалить API-сервер (программу, службы, настройки, правило порта $API_PORT)?" n || { echo "Отменено."; return; }
    local drop=0
    if [[ -d "$API_DIR/data" ]]; then
        echo "База с пользователями и адресными книгами лежит в $API_DIR/data."
        ask_yn "Удалить и базу? Восстановить её будет нельзя" n && drop=1
    fi
    systemctl disable --now "$SVC_A" "$SVC_AT" "$SVC_ATR.timer" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$SVC_A.service" "$UNIT_DIR/$SVC_AT.service" "$UNIT_DIR/$SVC_ATR.service" "$UNIT_DIR/$SVC_ATR.timer"
    systemctl daemon-reload
    if ufw_active; then ufw --force delete allow "$API_PORT/tcp" >/dev/null 2>&1; fi
    if command -v iptables >/dev/null; then ipt_del tcp "$API_PORT"; ipt_save; fi
    rm -rf "$API_NGINX_DIR" "$API_ENV" "$API_DIR.bak"
    if [[ "$(kv_get "$API_CONF" NGINX_ADDED)" == "1" && ! -e /etc/jackett-cert/nginx.conf ]]; then
        apt-get remove -y nginx >/dev/null 2>&1
    fi
    if (( drop )); then
        rm -rf "$API_DIR" "$API_CONF"
        id rustdesk-api >/dev/null 2>&1 && userdel rustdesk-api >/dev/null 2>&1
    else
        find "$API_DIR" -mindepth 1 -maxdepth 1 ! -name data ! -name conf -exec rm -rf {} + 2>/dev/null
        echo "База и настройки сохранены в $API_DIR."
    fi
    echo -e "${GREEN}✅ Готово. API-сервер удалён.${NC}"
}

api_menu() {
    local c
    while true; do
        echo -e "\n${YELLOW}===== API-сервер: вход в аккаунт и адресная книга =====${NC}"
        if api_installed; then
            if systemctl is-active --quiet "$SVC_A"; then
                echo -e "Состояние: ${GREEN}установлено, версия $(kv_get "$API_CONF" API_VERSION), работает${NC}; адрес: $(api_url)"
            else
                echo -e "Состояние: ${RED}установлено, но не работает${NC} (пункт 3)"
            fi
        else
            echo -e "Состояние: ${YELLOW}не установлено${NC}"
        fi
        echo "1. Установить / переустановить"
        echo "2. Данные для входа и как включить Google"
        echo "3. Статус и журнал"
        echo "4. Сменить пароль администратора"
        echo "5. Подключить HTTPS / сменить домен"
        echo "6. Обновить сейчас"
        echo "7. Удалить"
        echo "0. Назад"
        read -rp "Пункт: " c || return 0
        case "$c" in
            1) api_install ;;
            2) api_show ;;
            3) api_status ;;
            4) api_password_change ;;
            5) api_enable_https ;;
            6) api_update ;;
            7) api_remove ;;
            0) return 0 ;;
            *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
        esac
    done
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
    if api_installed; then
        if systemctl is-active --quiet "$SVC_A"; then
            echo -e "API-сервер (адресная книга): ${GREEN}работает${NC}, $(api_url)"
        else
            echo -e "API-сервер (адресная книга): ${RED}не работает${NC} (пункт 9 -> 3)"
        fi
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
    echo "9. Адресная книга и вход в аккаунт (API-сервер, по желанию Google)"
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
        9) api_menu ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
