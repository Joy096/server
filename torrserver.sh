#!/bin/bash
# torrserver_full.sh - TorrServer + любой WireGuard VPN для ЧИСТОЙ установки на Ubuntu (Oracle Cloud)
#
# Работает с любым провайдером, который выдаёт конфиг WireGuard (ClearVPN, Mullvad, Proton и т.д.).
# Название провайдера запрашивается один раз, из него получается имя интерфейса и конфига.
# Рассчитан на свежий сервер. Запускайте после базовой настройки сервера (server_new.sh), пункт меню 1.
# Если VPN пока не нужен, пункт 2 ставит только TorrServer (VPN можно подключить позже пунктами 3 и 5).
#
# Схема: через VPN идёт ТОЛЬКО трафик пользователя "torrserver" (policy routing по UID).
#   - SSH, apt и всё остальное ходит напрямую через сеть Oracle (ens3);
#   - ответы TorrServer с порта веб-интерфейса (8090) идут напрямую на ТВ;
#   - HTTPS (порт 8091) включает ssl.sh (пункт 2 его меню; запустить его можно отсюда, пункт 12):
#     kill-switch сам подхватывает порт HTTPS из torrserver.config;
#   - kill-switch: если VPN упал, у пользователя torrserver нет сети вообще,
#     утечки через основной интерфейс не будет.

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Этот скрипт должен выполняться с правами root!${NC}"
    exit 1
fi

TS_USER="torrserver"
TS_SVC="torrserver"
TS_DIR="/opt/torrserver"
SETTINGS_FILE="${TS_DIR}/settings.json"
TABLE=100
KS_SCRIPT="/usr/local/sbin/torrserver-ks.sh"
VPN_SCRIPT="/usr/local/sbin/torrserver-vpn.sh"
KS_UNIT="/etc/systemd/system/torrserver-killswitch.service"
DROPIN_DIR="/etc/systemd/system/${TS_SVC}.service.d"
DROPIN="${DROPIN_DIR}/vpn.conf"
WEB_PORT=8090
SSL_PORT=""      # порт HTTPS (если HTTPS включён через ssl.sh), иначе пусто
HTTPS_REMOVED_PORT=""   # порт HTTPS, правило UFW для которого удалено при удалении TorrServer (для напоминания про Oracle)
TS_CONFIG="${TS_DIR}/torrserver.config"
CERT_DIR="/etc/torrserver-cert"   # копия сертификата для TorrServer (кладёт ssl.sh)
SSL_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh"   # пункт 12 меню

# Состояние, которое запоминается между запусками: провайдер, имя интерфейса, профиль настроек
STATE_FILE="/etc/torrserver-vpn.state"
VPN_LABEL=""     # как назвал провайдера пользователь (для сообщений)
VPN_NAME=""      # имя WireGuard-интерфейса и конфига (из названия провайдера)
VPN_SHARED=""    # 1, если подключились к уже существующему конфигу (его создали не мы: другой скрипт или вы)
PROFILE=""       # weak | strong
# Что именно создал скрипт (нужно, чтобы удаление вернуло систему к состоянию "до установки"):
PKGS_ADDED=""        # пакеты, которых не было в системе до установки
UFW_PORT_ADDED=""    # порт, правило для которого добавил скрипт (если такого правила не было)
USER_CREATED=""      # 1, если пользователя torrserver создали при установке

CONF_NAME="vpn"
CONF=""
WG_SVC=""

apply_vpn_vars() {
    CONF_NAME="${VPN_NAME:-vpn}"
    CONF="/etc/wireguard/${CONF_NAME}.conf"
    WG_SVC="wg-quick@${CONF_NAME}"
}

load_state() {
    # shellcheck disable=SC1090
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
    elif [[ -f "$DROPIN" ]]; then
        # Установка от прежней версии скрипта (файла состояния ещё не было): подхватываем её.
        # Имя туннеля берём из drop-in службы; пакеты, пользователя и порт UFW не учитываем,
        # поэтому при удалении они останутся нетронутыми.
        VPN_NAME=$(grep -oP 'wg-quick@\K[^.[:space:]]+' "$DROPIN" 2>/dev/null | head -n 1)
        VPN_LABEL="$VPN_NAME"
        if [[ -n "$VPN_NAME" ]]; then
            apply_vpn_vars
            save_state
        fi
    fi
    apply_vpn_vars
}

save_state() {
    {
        echo "VPN_LABEL=$(printf '%q' "$VPN_LABEL")"
        echo "VPN_NAME=$(printf '%q' "$VPN_NAME")"
        echo "VPN_SHARED=$(printf '%q' "$VPN_SHARED")"
        echo "PROFILE=$(printf '%q' "$PROFILE")"
        echo "PKGS_ADDED=$(printf '%q' "$PKGS_ADDED")"
        echo "UFW_PORT_ADDED=$(printf '%q' "$UFW_PORT_ADDED")"
        echo "USER_CREATED=$(printf '%q' "$USER_CREATED")"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_state

# ---------------------------------------------------------------- ОБЩИЕ ФУНКЦИИ

ensure_user() {
    if ! id -u "$TS_USER" &>/dev/null; then
        useradd -r -s /bin/false "$TS_USER" && { USER_CREATED=1; save_state; }
    fi
    [[ -d "$TS_DIR" ]] && chown -R "$TS_USER:$TS_USER" "$TS_DIR"

    local data_dir
    data_dir=$(systemctl cat "$TS_SVC" 2>/dev/null | grep -oP -- '(-d|--path)[ =]\K/\S+' | head -n 1)
    if [[ -n "$data_dir" && -d "$data_dir" ]]; then
        chown -R "$TS_USER:$TS_USER" "$data_dir"
    fi

    # Копия сертификата для HTTPS (её кладёт ssl.sh): читать её должен тот же пользователь, от которого работает служба
    [[ -d "$CERT_DIR" ]] && chown -R "$TS_USER:$TS_USER" "$CERT_DIR"
}

# Порт веб-интерфейса TorrServer: из torrserver.config, потом из юнита, по умолчанию 8090.
# Вызывается заново после установки TorrServer, чтобы kill-switch получил реальный порт.
detect_port() {
    WEB_PORT=$(grep -oP '(?<=--port )\d+' "${TS_DIR}/torrserver.config" 2>/dev/null | head -n 1)
    [[ -z "$WEB_PORT" ]] && WEB_PORT=$(systemctl cat "$TS_SVC" 2>/dev/null | grep -oP -- '(--port|-p)[ =]\K[0-9]+' | head -n 1)
    [[ -z "$WEB_PORT" ]] && WEB_PORT=8090
}

# Порт HTTPS: пусто, если в torrserver.config нет параметра --ssl (включает его ssl.sh, пункт 2 меню).
# Без --sslport TorrServer использует 8091.
detect_ssl_port() {
    SSL_PORT=""
    if grep -qE '^DAEMON_OPTIONS=.*--ssl([[:space:]"'"'"']|$)' "$TS_CONFIG" 2>/dev/null; then
        SSL_PORT=$(grep -oP '(?<=--sslport )\d+' "$TS_CONFIG" 2>/dev/null | head -n 1)
        [[ -z "$SSL_PORT" ]] && SSL_PORT=8091
    fi
}

# Внешний IP. Аргументы (необязательно) - команда-обёртка, например: runuser -u torrserver --
get_ip() {
    local url ip
    for url in https://icanhazip.com https://api.ipify.org https://ifconfig.me; do
        ip=$("$@" curl -4 -s --connect-timeout 10 "$url" 2>/dev/null | tr -d ' \n\r')
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return
        fi
    done
}

# VPN настроен: есть имя провайдера и конфиг
vpn_configured() {
    [[ -n "$VPN_NAME" && -f "$CONF" ]]
}

# --- Совместное использование WireGuard-конфига с qBittorrent (qbittorrent_full.sh) ---
# К конфигу можно подключиться, дописав строки PostUp/PreDown. Метку "vpn-scripts-managed" ставит
# скрипт, создавший конфиг из вставленного текста: по ней конфиг можно удалить, когда он больше никому не нужен.

# К этому же конфигу подключён qBittorrent
qbit_uses_conf() {
    [[ -f "$CONF" ]] && grep -q 'qbittorrent-vpn\.sh' "$CONF" 2>/dev/null
}

# Конфиг общий: мы к нему подключились, или им пользуется qBittorrent
wg_shared() {
    [[ "$VPN_SHARED" == "1" ]] && return 0
    qbit_uses_conf
}

# Убирает из конфига и из маршрутизации только наши строки
strip_own_lines() {
    [[ -x "$VPN_SCRIPT" ]] && "$VPN_SCRIPT" down "$CONF_NAME" 2>/dev/null
    [[ -f "$CONF" ]] && sed -i '\#torrserver-vpn\.sh#d' "$CONF"
}

# Подключение к УЖЕ настроенному конфигу: дописываем только наши строки
join_wg_conf() {
    local conf_file="$1"
    if ! grep -qiE '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off' "$conf_file"; then
        echo -e "${RED}❌ В ${conf_file} нет строки «Table = off».${NC}"
        echo "   Через такой конфиг wg-quick завернёт ВЕСЬ трафик сервера в VPN, включая SSH. Подключаться к нему нельзя."
        echo "   Выберите «добавить отдельный конфиг»."
        return 1
    fi
    grep -qF "$VPN_SCRIPT" "$conf_file" && return 0

    cp -a "$conf_file" "${conf_file}.ts-bak.$(date +%Y%m%d-%H%M%S)"
    chmod 600 "${conf_file}".ts-bak.* 2>/dev/null

    local tmp_file
    tmp_file=$(mktemp)
    awk -v up="PostUp = ${VPN_SCRIPT} up %i" -v down="PreDown = ${VPN_SCRIPT} down %i" '
        { print }
        /^\[Interface\]/ && !done { print up; print down; done = 1 }
    ' "$conf_file" > "$tmp_file" && cat "$tmp_file" > "$conf_file"
    rm -f "$tmp_file"
    chmod 600 "$conf_file"
}

# Название провайдера для чужого конфига: из состояния qBittorrent, если там тот же интерфейс
guess_label() {
    local name="$1" label=""
    if [[ -f /etc/qbittorrent-vpn.state ]]; then
        label=$( ( source /etc/qbittorrent-vpn.state 2>/dev/null; [[ "$VPN_NAME" == "$name" ]] && echo "$VPN_LABEL" ) )
    fi
    echo "${label:-$name}"
}

# Включает маршрут сразу, не перезапуская туннель (им может пользоваться qBittorrent)
activate_shared_tunnel() {
    if wg show "$CONF_NAME" &>/dev/null; then
        "$VPN_SCRIPT" up "$CONF_NAME" && echo -e "${GREEN}✅ TorrServer подключён к туннелю ${CONF_NAME} (${VPN_LABEL}); перезапуск туннеля не потребовался.${NC}"
    else
        systemctl enable --now "$WG_SVC" &>/dev/null
        if wg show "$CONF_NAME" &>/dev/null; then
            echo -e "${GREEN}✅ Туннель ${CONF_NAME} (${VPN_LABEL}) был выключен, я его запустил.${NC}"
        else
            echo -e "${RED}❌ Не удалось поднять туннель. Смотрите: journalctl -u ${WG_SVC} -n 30${NC}"
            return 1
        fi
    fi
    [[ -f "$DROPIN" ]] && fix_systemd_service
    return 0
}

# Повторное применение без замены конфига (для общего конфига: только наши строки)
reapply_conf() {
    if [[ "$VPN_SHARED" == "1" ]]; then
        join_wg_conf "$CONF" || return 1
        activate_shared_tunnel
    else
        fix_vpn_config "$CONF"
        systemctl restart "$WG_SVC"
        systemctl enable "$WG_SVC" &>/dev/null
    fi
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# apt install с запоминанием пакетов, которых раньше в системе не было (для удаления)
apt_install_tracked() {
    local pkg
    local watch=("$@")
    local newly=()
    [[ " $* " == *" wireguard "* ]] && watch+=("wireguard-tools")   # wireguard тянет за собой wireguard-tools

    for pkg in "${watch[@]}"; do
        pkg_installed "$pkg" || newly+=("$pkg")
    done

    apt update && apt install -y "$@" || return 1

    for pkg in "${newly[@]}"; do
        if pkg_installed "$pkg" && [[ " $PKGS_ADDED " != *" $pkg "* ]]; then
            PKGS_ADDED="${PKGS_ADDED:+$PKGS_ADDED }$pkg"
        fi
    done
    save_state
}

# Ядро и iproute2 должны уметь правила по UID, протоколу и порту
check_kernel_support() {
    if ip rule add priority 9999 ipproto tcp sport 65000 lookup main 2>/dev/null; then
        ip rule del priority 9999 2>/dev/null
        if ip rule add priority 9999 uidrange 65000-65000 lookup main 2>/dev/null; then
            ip rule del priority 9999 2>/dev/null
            return 0
        fi
    fi
    echo -e "${RED}❌ Ядро или iproute2 не поддерживает ip rule с ipproto/sport/uidrange. Схема работать не будет.${NC}"
    echo "   Проверьте: uname -r; ip -V"
    return 1
}

# ---------------------------------------------------------------- VPN-ПРОВАЙДЕР

# Название провайдера -> допустимое имя интерфейса Linux (до 15 символов: a-z, 0-9, _ и -)
sanitize_iface() {
    local s
    s=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//' | cut -c1-15 | sed -E 's/-+$//')
    echo "${s:-vpn}"
}

# Запрашивает название VPN-провайдера и сохраняет его вместе с именем интерфейса
ask_vpn_provider() {
    local label iface
    echo -e "\n${YELLOW}=== VPN-провайдер ===${NC}"
    read -p "Название VPN-провайдера (например: ClearVPN, Mullvad, ProtonVPN): " label
    [[ -z "$label" ]] && label="VPN"

    iface=$(sanitize_iface "$label")
    # Имя не должно совпадать с уже существующим не-WireGuard интерфейсом (ens3, lo, docker0...)
    if { ip link show dev "$iface" &>/dev/null && ! wg show "$iface" &>/dev/null; } || [[ -f "/etc/wireguard/${iface}.conf" ]]; then
        iface="$(echo "$iface" | cut -c1-12)-ts"
    fi

    VPN_LABEL="$label"
    VPN_NAME="$iface"
    VPN_SHARED=""
    apply_vpn_vars
    save_state
    echo -e "${GREEN}Провайдер: ${VPN_LABEL}. Интерфейс и конфиг: ${CONF_NAME} (${CONF})${NC}"
}

# Базовая проверка конфига, который выдал провайдер
validate_wg_conf() {
    local f="$1" item label regex answer
    local missing=()
    local checks=(
        "[Interface]|^\[Interface\]"
        "PrivateKey|^[[:space:]]*PrivateKey[[:space:]]*="
        "Address|^[[:space:]]*Address[[:space:]]*="
        "[Peer]|^\[Peer\]"
        "PublicKey|^[[:space:]]*PublicKey[[:space:]]*="
        "Endpoint|^[[:space:]]*Endpoint[[:space:]]*="
        "AllowedIPs|^[[:space:]]*AllowedIPs[[:space:]]*="
    )
    for item in "${checks[@]}"; do
        label="${item%%|*}"
        regex="${item#*|}"
        grep -qiE "$regex" "$f" || missing+=("$label")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}❌ Это не похоже на конфиг WireGuard. Не хватает: ${missing[*]}${NC}"
        return 1
    fi

    if ! grep -iE '^[[:space:]]*AllowedIPs' "$f" | grep -q '0\.0\.0\.0/0'; then
        echo -e "${YELLOW}⚠️ В AllowedIPs нет 0.0.0.0/0: через такой туннель пойдёт не весь трафик TorrServer.${NC}"
        echo "   Обычно у VPN-провайдера там должно быть 0.0.0.0/0 (или 0.0.0.0/0, ::/0)."
        read -p "Всё равно продолжить? (y/n): " answer
        [[ "$answer" == "y" || "$answer" == "Y" ]] || return 1
    fi
    return 0
}

# ---------------------------------------------------------------- МАРШРУТИЗАЦИЯ И KILL-SWITCH

# Скрипты маршрутизации и kill-switch (генерируются заново при каждом вызове)
install_routing_helpers() {
    detect_port

    # Kill-switch: действует всегда, даже пока VPN не поднят
    cat > "$KS_SCRIPT" <<'KSEOF'
#!/bin/bash
# up|down. Ответы TorrServer с порта PORT (и с порта HTTPS, если он включён) идут обычным маршрутом (на ТВ),
# любой другой трафик пользователя torrserver запрещён, пока нет правила через VPN (приоритет 100).
U=$(id -u torrserver) || exit 1
PORT=__PORT__
CONF=__CONF__
# HTTPS включает ssl.sh (параметр --ssl в DAEMON_OPTIONS): порт читаем при каждом запуске, чтобы он всегда был актуальным
SSLPORT=""
if grep -qE '^DAEMON_OPTIONS=.*--ssl([[:space:]"'"'"']|$)' "$CONF" 2>/dev/null; then
    SSLPORT=$(grep -oP '(?<=--sslport )\d+' "$CONF" 2>/dev/null | head -n 1)
    SSLPORT=${SSLPORT:-8091}
fi
clean() {
    for p in 90 110; do
        while ip -4 rule del priority $p 2>/dev/null; do :; done
        while ip -6 rule del priority $p 2>/dev/null; do :; done
    done
}
case "$1" in
    up)
        clean
        ip -4 rule add priority 90  ipproto tcp sport "$PORT" lookup main || exit 1
        ip -4 rule add priority 110 uidrange "$U-$U" prohibit || exit 1
        ip -6 rule add priority 90  ipproto tcp sport "$PORT" lookup main 2>/dev/null
        ip -6 rule add priority 110 uidrange "$U-$U" prohibit 2>/dev/null
        if [ -n "$SSLPORT" ]; then
            ip -4 rule add priority 90 ipproto tcp sport "$SSLPORT" lookup main 2>/dev/null
            ip -6 rule add priority 90 ipproto tcp sport "$SSLPORT" lookup main 2>/dev/null
        fi
        ;;
    down) clean ;;
    *) exit 1 ;;
esac
exit 0
KSEOF
    sed -i "s/__PORT__/${WEB_PORT}/" "$KS_SCRIPT"
    sed -i "s|__CONF__|${TS_CONFIG}|" "$KS_SCRIPT"

    # Маршрут через VPN: добавляется и убирается вместе с туннелем (PostUp/PreDown в wg-конфиге).
    # Имя интерфейса приходит аргументом, поэтому скрипт не зависит от провайдера.
    cat > "$VPN_SCRIPT" <<'VPNEOF'
#!/bin/bash
# up|down <интерфейс>
U=$(id -u torrserver) || exit 1
TABLE=__TABLE__
case "$1" in
    up)
        ip route replace default dev "$2" table "$TABLE" || exit 1
        while ip -4 rule del priority 100 2>/dev/null; do :; done
        ip -4 rule add priority 100 uidrange "$U-$U" lookup "$TABLE" || exit 1
        ;;
    down)
        while ip -4 rule del priority 100 2>/dev/null; do :; done
        ip route flush table "$TABLE" 2>/dev/null
        ;;
    *) exit 1 ;;
esac
exit 0
VPNEOF
    sed -i "s/__TABLE__/${TABLE}/" "$VPN_SCRIPT"
    chmod 755 "$KS_SCRIPT" "$VPN_SCRIPT"

    cat > "$KS_UNIT" <<UNITEOF
[Unit]
Description=TorrServer kill-switch (запрет трафика мимо VPN)
Before=${TS_SVC}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${KS_SCRIPT} up
ExecStop=${KS_SCRIPT} down

[Install]
WantedBy=multi-user.target
UNITEOF

    systemctl daemon-reload
    systemctl enable torrserver-killswitch &>/dev/null
    systemctl restart torrserver-killswitch
}

# Служба TorrServer: отдельный пользователь + зависимость от kill-switch и WireGuard.
# Через drop-in, поэтому установщик и обновления TorrServer этих настроек не затирают.
fix_systemd_service() {
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<DROPEOF
[Unit]
Requires=torrserver-killswitch.service
Wants=${WG_SVC}.service
After=torrserver-killswitch.service ${WG_SVC}.service network-online.target

[Service]
User=${TS_USER}
Group=${TS_USER}
DROPEOF
    systemctl daemon-reload
}

# Правка wg-конфига любого провайдера под нашу схему:
#   - Table = off и PostUp/PreDown: через туннель идёт только трафик torrserver;
#   - убираем DNS (иначе подменит DNS всей системы) и собственные PostUp/PostDown провайдера;
#   - в Address оставляем только IPv4 (IPv6 для TorrServer всё равно закрыт kill-switch,
#     а wg-quick падает, если на сервере IPv6 отключён);
#   - если у провайдера нет PersistentKeepalive, добавляем 25 (иначе туннель может "засыпать").
fix_vpn_config() {
    local conf_file="$1"

    sed -i 's/\r$//' "$conf_file"

    # Бэкап исходного конфига провайдера (один раз, до первой правки)
    if ! grep -q "$VPN_SCRIPT" "$conf_file"; then
        cp -a "$conf_file" "${conf_file}.bak.$(date +%Y%m%d-%H%M%S)"
        chmod 600 "${conf_file}".bak.* 2>/dev/null
    fi

    # Строки qBittorrent (qbittorrent-vpn.sh), если он подключён к этому же туннелю, не трогаем
    sed -i -E '/qbittorrent-vpn\.sh/!{/^[[:space:]]*(Table|PostUp|PreUp|PreDown|PostDown|DNS|SaveConfig)[[:space:]]*=/Id}' "$conf_file"

    local tmp_file
    tmp_file=$(mktemp)
    awk -v up="PostUp = ${VPN_SCRIPT} up %i" -v down="PreDown = ${VPN_SCRIPT} down %i" '
        /^[[:space:]]*Address[[:space:]]*=/ {
            line = $0
            sub(/^[^=]*=/, "", line)
            n = split(line, parts, ",")
            out = ""
            for (i = 1; i <= n; i++) {
                gsub(/^[ \t\r]+|[ \t\r]+$/, "", parts[i])
                if (parts[i] != "" && parts[i] !~ /:/) out = out (out == "" ? "" : ", ") parts[i]
            }
            if (out != "") print "Address = " out; else print $0
            next
        }
        { print }
        /^\[Interface\]/ && !done { print "Table = off"; print up; print down; done = 1 }
    ' "$conf_file" > "$tmp_file" && cat "$tmp_file" > "$conf_file"
    rm -f "$tmp_file"

    if ! grep -qiE '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$conf_file"; then
        sed -i '0,/^\[Peer\]/s//[Peer]\nPersistentKeepalive = 25/' "$conf_file"
    fi

    chmod 600 "$conf_file"
}

# ---------------------------------------------------------------- ПРОФИЛИ НАСТРОЕК TORRSERVER
#
# weak   - слабая VPS (например, Oracle Micro, 1 ГБ RAM): кэш 200 МБ только в оперативной памяти
# strong - мощная VPS: кэш 10 ГБ на диске (папка ${TS_DIR}/cache)
#
# DisableUTP = true в обоих профилях: uTP идёт по UDP, а внутри UDP-туннеля WireGuard (MTU 1420)
# такие пакеты фрагментируются и теряются, из-за чего бывало 0 пиров. Через TCP стабильнее.

choose_profile() {
    local ram_mb cpus rec answer
    ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    cpus=$(nproc 2>/dev/null || echo "?")

    if [[ "$ram_mb" -ge 4000 ]]; then rec=2; else rec=1; fi

    echo -e "\n${YELLOW}=== Профиль настроек TorrServer ===${NC}"
    echo "Обнаружено: RAM ${ram_mb} МБ, ядер CPU: ${cpus}"
    echo "1. Слабая VPS  - кэш 200 МБ в оперативной памяти (для 1 ГБ RAM)"
    echo "2. Мощная VPS  - кэш 10 ГБ на диске (нужно от 4 ГБ RAM и свободное место на диске)"
    read -p "Выберите профиль [1/2] (Enter - рекомендуемый: ${rec}): " answer
    [[ "$answer" != "1" && "$answer" != "2" ]] && answer=$rec

    if [[ "$answer" == "2" ]]; then
        PROFILE="strong"
        local free_gb
        free_gb=$(df -BG --output=avail "$TS_DIR" 2>/dev/null | tail -n 1 | tr -dc '0-9')
        [[ -z "$free_gb" ]] && free_gb=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
        if [[ -n "$free_gb" && "$free_gb" -lt 15 ]]; then
            echo -e "${YELLOW}⚠️ Свободно на диске всего ${free_gb} ГБ, а кэшу нужно 10 ГБ. Лучше выбрать слабый профиль или освободить место.${NC}"
        fi
    else
        PROFILE="weak"
    fi
    save_state
    echo -e "${GREEN}Выбран профиль: ${PROFILE}${NC}"
}

# Фильтр jq для профиля. $1 - префикс ключей ("" для плоского settings.json или ".BitTorr"), $2 - профиль
build_jq_filter() {
    local p="$1"
    if [[ "$2" == "strong" ]]; then
        echo "${p}.CacheSize = 10485760000 | ${p}.ReaderReadAHead = 95 | ${p}.PreloadCache = 0 | ${p}.RemoveCacheOnDrop = true | ${p}.UseDisk = true | ${p}.TorrentsSavePath = \$path | ${p}.DisableUTP = true"
    else
        echo "${p}.CacheSize = 209715200 | ${p}.ReaderReadAHead = 95 | ${p}.PreloadCache = 0 | ${p}.RemoveCacheOnDrop = true | ${p}.UseDisk = false | ${p}.ConnectionsLimit = 30 | ${p}.DisableUTP = true"
    fi
}

# Применяет профиль к settings.json (служба TorrServer в это время должна быть остановлена)
apply_profile_settings() {
    local profile="$1" owner
    owner=$(stat -c '%U:%G' "$TS_DIR" 2>/dev/null || echo "root:root")

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo -e "${YELLOW}⚠️ Файл ${SETTINGS_FILE} ещё не создан, настройки профиля не применены. После первого запуска TorrServer выполните пункт 5 (или 4).${NC}"
        return 1
    fi

    if [[ "$profile" == "strong" ]]; then
        mkdir -p "${TS_DIR}/cache"
        chown "$owner" "${TS_DIR}/cache"
    fi

    # В новых версиях TorrServer файл плоский; если встретится секция BitTorr - учитываем и её
    local prefix="" filter tmp_file
    jq -e 'has("BitTorr")' "$SETTINGS_FILE" &>/dev/null && prefix=".BitTorr"
    filter=$(build_jq_filter "$prefix" "$profile")

    tmp_file=$(mktemp)
    if jq --arg path "${TS_DIR}/cache" "$filter" "$SETTINGS_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$SETTINGS_FILE"
        chown "$owner" "$SETTINGS_FILE"
        chmod 644 "$SETTINGS_FILE"
        echo -e "${GREEN}✅ Профиль '${profile}' применён к settings.json.${NC}"
    else
        rm -f "$tmp_file"
        echo -e "${RED}❌ Не удалось изменить settings.json (ошибка jq). Файл не тронут.${NC}"
        return 1
    fi
}

# Привязка TorrServer к VPN: пользователь, kill-switch, drop-in, профиль настроек.
# Служба сначала останавливается, чтобы chown не гонялся с файлами, которые она создаёт от root.
fix_torrserver_binding() {
    if ! vpn_configured; then
        echo -e "${RED}❌ VPN не настроен. Сначала выполните пункт 3: иначе kill-switch оставит TorrServer без сети.${NC}"
        return 1
    fi

    systemctl stop "$TS_SVC" 2>/dev/null

    [[ -z "$PROFILE" ]] && choose_profile

    ensure_user
    install_routing_helpers
    fix_systemd_service
    apply_profile_settings "$PROFILE"

    systemctl start "$TS_SVC"
    echo -e "${GREEN}✅ TorrServer работает от пользователя '${TS_USER}', весь его трафик идёт только через VPN ${VPN_LABEL} (kill-switch активен).${NC}"
}

# Применение профиля без VPN (TorrServer не привязан к туннелю)
apply_profile_standalone() {
    systemctl stop "$TS_SVC" 2>/dev/null
    apply_profile_settings "$PROFILE"
    systemctl start "$TS_SVC"
}

# Смена профиля на лету (пункт 4)
change_profile() {
    choose_profile
    if [[ -f "$DROPIN" ]]; then
        fix_torrserver_binding
    else
        apply_profile_standalone
    fi
}

# ---------------------------------------------------------------- УСТАНОВКА

setup_vpn() {
    echo -e "\n${YELLOW}=== [1/2] Установка и настройка WireGuard VPN ===${NC}"
    apt_install_tracked wireguard jq curl ufw iproute2 || return 1

    check_kernel_support || return 1

    ensure_user
    install_routing_helpers

    if vpn_configured; then
        echo -e "${GREEN}Текущий VPN: ${VPN_LABEL:-?} (интерфейс ${CONF_NAME}, файл ${CONF})$(wg_shared && echo ', общий конфиг')${NC}"
        read -p "Заменить конфиг или сменить провайдера? (y/n): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            reapply_conf
            return $?
        fi
        # Старое подключение убираем: свой конфиг удаляется, общий остаётся другому скрипту
        wg_shared && strip_own_lines
        remove_wg_parts
        save_state
    fi

    # Есть ли уже WireGuard-конфиги на сервере (например, от qbittorrent_full.sh)
    local confs=() f n i=1
    for f in /etc/wireguard/*.conf; do
        [[ -f "$f" ]] && confs+=("$(basename "$f" .conf)")
    done

    local choice="2" pick=""
    if [[ ${#confs[@]} -gt 0 ]]; then
        echo -e "\nНа сервере уже есть WireGuard-конфиг(и):"
        for n in "${confs[@]}"; do
            echo "   ${i}. ${n}  $(grep -q 'qbittorrent-vpn\.sh' "/etc/wireguard/${n}.conf" 2>/dev/null && echo '(используется qBittorrent)')"
            i=$((i + 1))
        done
        echo
        echo "1. Использовать существующий туннель (второй VPN-ключ не нужен)"
        echo "2. Добавить отдельный конфиг для TorrServer"
        read -p "Выберите [1-2, Enter = 1]: " choice
        [[ "$choice" != "2" ]] && choice="1"
        if [[ "$choice" == "1" ]]; then
            if [[ ${#confs[@]} -eq 1 ]]; then
                pick="${confs[0]}"
            else
                read -p "Номер конфига [1-${#confs[@]}]: " i
                if [[ ! "$i" =~ ^[0-9]+$ ]] || (( i < 1 || i > ${#confs[@]} )); then
                    echo -e "${RED}Неверный номер.${NC}"
                    return 1
                fi
                pick="${confs[$((i - 1))]}"
            fi
        fi
    fi

    if [[ "$choice" == "1" ]]; then
        VPN_NAME="$pick"
        VPN_LABEL=$(guess_label "$pick")
        VPN_SHARED=1
        apply_vpn_vars
        if ! join_wg_conf "$CONF"; then
            VPN_NAME=""; VPN_LABEL=""; VPN_SHARED=""; apply_vpn_vars
            return 1
        fi
        save_state
        activate_shared_tunnel
        return $?
    fi

    ask_vpn_provider

    echo -e "\n${YELLOW}Вставьте содержимое .conf файла WireGuard от ${VPN_LABEL} и нажмите ENTER, затем Ctrl+D:${NC}"
    mkdir -p /etc/wireguard
    ( umask 077; cat > "$CONF" )

    if [[ ! -s "$CONF" ]]; then
        echo -e "${RED}❌ Файл конфигурации пуст.${NC}"
        rm -f "$CONF"
        return 1
    fi

    sed -i 's/\r$//' "$CONF"
    if ! validate_wg_conf "$CONF"; then
        echo -e "${RED}Конфиг не принят и удалён. Запустите пункт 3 и вставьте конфиг заново.${NC}"
        rm -f "$CONF"
        return 1
    fi

    fix_vpn_config "$CONF"
    # Метка: конфиг создан скриптом, его можно удалить, когда он больше никому не нужен
    grep -q 'vpn-scripts-managed' "$CONF" || sed -i '1i # vpn-scripts-managed' "$CONF"
    [[ -f "$DROPIN" ]] && fix_systemd_service   # обновить зависимость службы TorrServer от имени интерфейса

    systemctl restart "$WG_SVC"
    systemctl enable "$WG_SVC" &>/dev/null

    if wg show "$CONF_NAME" &>/dev/null; then
        echo -e "${GREEN}✅ WireGuard (${VPN_LABEL}, интерфейс ${CONF_NAME}) запущен!${NC}"
    else
        echo -e "${RED}❌ Ошибка запуска WireGuard. Смотрите: journalctl -u ${WG_SVC} -n 30${NC}"
    fi
    return 0
}

# Установка самого TorrServer (общая часть для режимов с VPN и без)
install_torrserver_core() {
    echo "Если установщик спросит про запуск от root, отвечайте «да»: так проверена вся схема."

    # Запоминаем, был ли пользователь torrserver до установщика (он мог создать его сам)
    local had_user=0
    id -u "$TS_USER" &>/dev/null && had_user=1

    bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh)

    if [[ $had_user -eq 0 && -z "$USER_CREATED" ]] && id -u "$TS_USER" &>/dev/null; then
        USER_CREATED=1
        save_state
    fi

    # На чистой системе settings.json появляется не сразу, а после первого запуска службы
    local i
    for i in $(seq 1 20); do
        [[ -f "$SETTINGS_FILE" ]] && break
        sleep 1
    done

    detect_port

    if command -v ufw &>/dev/null; then
        # Запоминаем порт, только если такого правила в UFW ещё не было
        if ! ufw show added 2>/dev/null | grep -qE "allow ${WEB_PORT}/tcp"; then
            UFW_PORT_ADDED="$WEB_PORT"
            save_state
        fi
        ufw allow "${WEB_PORT}"/tcp
    fi
}

setup_torrserver() {
    echo -e "\n${YELLOW}=== [2/2] Установка и настройка TorrServer ===${NC}"
    install_torrserver_core

    choose_profile
    fix_torrserver_binding
    echo -e "${GREEN}✅ TorrServer запущен на порту ${WEB_PORT}!${NC}"
    echo -e "${YELLOW}Не забудьте открыть порт ${WEB_PORT}/tcp в Security List / NSG в консоли Oracle Cloud.${NC}"
}

# Пункт 2: только TorrServer, без VPN и kill-switch
setup_torrserver_only() {
    echo -e "\n${YELLOW}=== Установка только TorrServer (без VPN) ===${NC}"
    echo -e "${YELLOW}⚠️ Без VPN весь P2P-трафик TorrServer идёт с реального IP сервера Oracle.${NC}"
    echo "   Жалобы правообладателей на такой IP могут привести к блокировке аккаунта Oracle."
    echo "   VPN можно подключить позже: пункт 3 (настроить VPN), затем пункт 5 (привязать TorrServer)."
    read -p "Продолжить установку без VPN? (y/n): " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || return

    apt_install_tracked jq curl ufw || return 1
    install_torrserver_core

    choose_profile
    apply_profile_standalone

    echo -e "${GREEN}✅ TorrServer запущен на порту ${WEB_PORT} (без VPN).${NC}"
    echo -e "${YELLOW}Не забудьте открыть порт ${WEB_PORT}/tcp в Security List / NSG в консоли Oracle Cloud.${NC}"
}

# ---------------------------------------------------------------- ПРОВЕРКИ

check_vpn() {
    echo -e "\n${YELLOW}=== Проверка работы WireGuard (${VPN_LABEL:-VPN}) ===${NC}"
    if ! vpn_configured; then
        echo -e "${YELLOW}VPN не настроен (режим без VPN или установка ещё не выполнена). Пункт 3 - настроить VPN.${NC}"
        return
    fi

    if wg show "$CONF_NAME" &>/dev/null; then
        wg show "$CONF_NAME"
        echo -e "\n--- Тест IP-адресов ---"

        local main_ip vpn_ip
        main_ip=$(get_ip)
        vpn_ip=$(get_ip runuser -u "$TS_USER" --)

        echo -e "Прямой IP сервера (Oracle/SSH):         ${GREEN}${main_ip:-Не доступен}${NC}"
        echo -e "IP TorrServer (через ${VPN_LABEL:-VPN}):  ${GREEN}${vpn_ip:-Не доступен}${NC}"
    else
        echo -e "${RED}❌ Интерфейс ${CONF_NAME} не активен!${NC}"
    fi
}

check_torrserver() {
    echo -e "\n${YELLOW}=== Проверка статуса TorrServer ===${NC}"
    systemctl status "$TS_SVC" --no-pager
}

check_safety() {
    echo -e "\n${YELLOW}=== Комплексная проверка безопасности ===${NC}"

    if ! vpn_configured; then
        echo -e "${YELLOW}VPN не настроен: TorrServer работает без VPN (или ещё не установлен). Проверять нечего.${NC}"
        echo "Подключить VPN: пункт 3, затем пункт 5."
        return
    fi

    detect_port
    detect_ssl_port

    local errors=0
    local uid
    uid=$(id -u "$TS_USER" 2>/dev/null)

    # 1. WireGuard и рукопожатие
    if wg show "$CONF_NAME" &>/dev/null; then
        echo -e "${GREEN}[OK] WireGuard интерфейс ${CONF_NAME} (${VPN_LABEL}) активен.${NC}"
        local hs now
        hs=$(wg show "$CONF_NAME" latest-handshakes 2>/dev/null | awk '{print $2}' | head -n 1)
        now=$(date +%s)
        if [[ -n "$hs" && "$hs" -gt 0 && $((now - hs)) -lt 300 ]]; then
            echo -e "${GREEN}[OK] Рукопожатие с VPN-сервером свежее.${NC}"
        else
            echo -e "${RED}[FAIL] Нет свежего рукопожатия с VPN-сервером.${NC}"
            errors=$((errors + 1))
        fi
    else
        echo -e "${RED}[FAIL] WireGuard интерфейс ${CONF_NAME} не активен!${NC}"
        errors=$((errors + 1))
    fi

    # 2. TorrServer работает от нужного пользователя
    if systemctl is-active --quiet "$TS_SVC"; then
        local pid owner
        pid=$(systemctl show -p MainPID --value "$TS_SVC")
        owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$owner" == "$TS_USER" ]]; then
            echo -e "${GREEN}[OK] TorrServer запущен от пользователя ${TS_USER}.${NC}"
        else
            echo -e "${RED}[FAIL] TorrServer запущен от '${owner:-?}', а не от ${TS_USER}! (пункт 5 привязывает его к VPN)${NC}"
            errors=$((errors + 1))
        fi
    else
        echo -e "${RED}[FAIL] Служба TorrServer не запущена.${NC}"
        errors=$((errors + 1))
    fi

    # 3. Правила маршрутизации и kill-switch
    if [[ -n "$uid" ]] && ip -4 rule show | grep -q "uidrange ${uid}-${uid} lookup ${TABLE}"; then
        echo -e "${GREEN}[OK] Трафик пользователя ${TS_USER} направлен в таблицу ${TABLE} (VPN).${NC}"
    else
        echo -e "${RED}[FAIL] Нет правила маршрутизации пользователя ${TS_USER} через VPN!${NC}"
        errors=$((errors + 1))
    fi

    if [[ -n "$uid" ]] && ip -4 rule show | grep -q "uidrange ${uid}-${uid} prohibit"; then
        echo -e "${GREEN}[OK] Kill-switch активен (мимо VPN у TorrServer нет сети).${NC}"
    else
        echo -e "${RED}[FAIL] Kill-switch не активен!${NC}"
        errors=$((errors + 1))
    fi

    if ip -4 rule show | grep -q "sport ${WEB_PORT} lookup main"; then
        echo -e "${GREEN}[OK] Ответы веб-интерфейса (порт ${WEB_PORT}) идут напрямую на ТВ.${NC}"
    else
        echo -e "${RED}[FAIL] Нет правила для ответов веб-интерфейса (порт ${WEB_PORT})!${NC}"
        errors=$((errors + 1))
    fi

    if [[ -n "$SSL_PORT" ]]; then
        if ip -4 rule show | grep -q "sport ${SSL_PORT} lookup main"; then
            echo -e "${GREEN}[OK] Ответы по HTTPS (порт ${SSL_PORT}) идут напрямую на ТВ.${NC}"
        else
            echo -e "${RED}[FAIL] HTTPS включён (порт ${SSL_PORT}), но правила для его ответов нет! (пункт 9 исправит)${NC}"
            errors=$((errors + 1))
        fi
    fi

    if ip route show table "$TABLE" 2>/dev/null | grep -q "default dev ${CONF_NAME}"; then
        echo -e "${GREEN}[OK] Маршрут по умолчанию в таблице ${TABLE} идёт в ${CONF_NAME}.${NC}"
    else
        echo -e "${RED}[FAIL] В таблице ${TABLE} нет маршрута через ${CONF_NAME}!${NC}"
        errors=$((errors + 1))
    fi

    # 4. Разделение IP
    echo -e "\nПроверка внешних IP (до 30 секунд)..."
    local main_ip vpn_ip
    main_ip=$(get_ip)
    vpn_ip=$(get_ip runuser -u "$TS_USER" --)

    if [[ -n "$main_ip" && -n "$vpn_ip" && "$main_ip" != "$vpn_ip" ]]; then
        echo -e "${GREEN}[OK] Разделение IP работает корректно:${NC}"
        echo -e "     • Основной IP сервера (SSH): $main_ip"
        echo -e "     • IP TorrServer (${VPN_LABEL}):  $vpn_ip"
    else
        echo -e "${RED}[FAIL] Ошибка разделения IP! (сервер: ${main_ip:-нет}, TorrServer: ${vpn_ip:-нет})${NC}"
        errors=$((errors + 1))
    fi

    # 5. Веб-интерфейс отвечает локально
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${WEB_PORT}/echo")
    if [[ "$code" == "200" ]]; then
        echo -e "${GREEN}[OK] Веб-интерфейс TorrServer отвечает (порт ${WEB_PORT}).${NC}"
    else
        echo -e "${RED}[FAIL] Веб-интерфейс TorrServer не отвечает (код: ${code:-нет ответа}).${NC}"
        errors=$((errors + 1))
    fi

    if [[ -n "$SSL_PORT" ]]; then
        local scode
        scode=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:${SSL_PORT}/echo")
        if [[ -n "$scode" && "$scode" != "000" ]]; then
            echo -e "${GREEN}[OK] HTTPS TorrServer отвечает (порт ${SSL_PORT}).${NC}"
        else
            echo -e "${RED}[FAIL] HTTPS TorrServer не отвечает (порт ${SSL_PORT}). Смотрите: journalctl -u ${TS_SVC} -n 30${NC}"
            errors=$((errors + 1))
        fi
    fi

    echo -e "\n--------------------------------------------------"
    if [[ $errors -eq 0 ]]; then
        echo -e "${GREEN}РЕЗУЛЬТАТ: Настройка БЕЗОПАСНА.${NC}"
        echo -e "--------------------------------------------------"
    else
        echo -e "${RED}РЕЗУЛЬТАТ: Обнаружено проблем: $errors.${NC}"
        echo -e "--------------------------------------------------"
        read -p "Запустить автоматическое исправление? (y/n): " fix_choice
        if [[ "$fix_choice" == "y" || "$fix_choice" == "Y" ]]; then
            auto_fix
            check_safety
        fi
    fi
}

# ---------------------------------------------------------------- ИСПРАВЛЕНИЕ И ОТКАТ

auto_fix() {
    echo -e "\n${YELLOW}🛠️ [АВТО-ИСПРАВЛЕНИЕ] Пересборка правил маршрутизации и служб...${NC}"

    if ! vpn_configured; then
        echo -e "${RED}⚠️ VPN не настроен (нет имени провайдера или файла ${CONF}). Запустите пункт 1 или 3.${NC}"
        return
    fi

    check_kernel_support || return
    ensure_user
    install_routing_helpers
    reapply_conf

    fix_torrserver_binding
    echo -e "${GREEN}✅ Восстановление завершено!${NC}\n"
}

# Убирает привязку к VPN: kill-switch, правила маршрутизации, drop-in, вспомогательные скрипты.
# Туннель останавливается (иначе PreDown вызвал бы уже удалённый скрипт). TorrServer не запускается.
remove_routing_parts() {
    local p
    systemctl stop "$TS_SVC" 2>/dev/null
    if wg_shared; then
        # Конфиг общий (им пользуется qBittorrent или он не наш): туннель не останавливаем, убираем только свои маршрут и строки
        strip_own_lines
    else
        systemctl stop "$WG_SVC" 2>/dev/null
        systemctl disable "$WG_SVC" &>/dev/null
    fi
    systemctl disable --now torrserver-killswitch 2>/dev/null
    rm -f "$KS_UNIT" "$DROPIN" "$KS_SCRIPT" "$VPN_SCRIPT"
    rmdir "$DROPIN_DIR" 2>/dev/null

    # Страховка: если правила остались (служба упала, скрипты уже были удалены)
    for p in 90 100 110; do
        while ip -4 rule del priority "$p" 2>/dev/null; do :; done
        while ip -6 rule del priority "$p" 2>/dev/null; do :; done
    done
    ip route flush table "$TABLE" 2>/dev/null

    systemctl daemon-reload
    systemctl reset-failed torrserver-killswitch "$WG_SVC" 2>/dev/null
}

revert_routing() {
    echo -e "\n${YELLOW}↩️ Откат: TorrServer снова ходит через обычный интерфейс (без VPN)${NC}"
    read -p "Точно откатить? Трафик TorrServer пойдёт с IP сервера Oracle. (y/n): " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || return

    remove_routing_parts
    restore_conf_backup

    systemctl daemon-reload
    systemctl start "$TS_SVC" 2>/dev/null
    echo -e "${GREEN}✅ Откат выполнен.${NC}"
}

# Возвращает исходный (до правок скрипта) конфиг WireGuard из последнего бэкапа
restore_conf_backup() {
    if wg_shared; then
        echo -e "${YELLOW}Конфиг WireGuard общий (с qBittorrent или не наш): оставляю как есть, из бэкапа не восстанавливаю.${NC}"
        return 0
    fi
    local last_bak
    last_bak=$(ls -1t "${CONF}".bak.* 2>/dev/null | head -n 1)
    if [[ -n "$last_bak" ]]; then
        cp -a "$last_bak" "$CONF" && echo -e "${GREEN}Конфиг WireGuard восстановлен из $last_bak${NC}"
    else
        echo -e "${YELLOW}Бэкап конфига не найден, конфиг WireGuard не тронут.${NC}"
    fi
}

# ---------------------------------------------------------------- УДАЛЕНИЕ
# Удаляется только то, что создал этот скрипт (учёт ведётся в ${STATE_FILE}):
# чужие пакеты, чужие правила UFW и чужие учётные записи не трогаются.

ts_unit_paths() {
    printf '%s\n' "/etc/systemd/system/${TS_SVC}.service" \
                  "/usr/lib/systemd/system/${TS_SVC}.service" \
                  "/lib/systemd/system/${TS_SVC}.service"
}

routing_present() { [[ -e "$KS_UNIT" || -e "$DROPIN" || -e "$KS_SCRIPT" || -e "$VPN_SCRIPT" ]]; }
wg_present()      { [[ -n "$VPN_NAME" ]] && { [[ -f "$CONF" ]] || compgen -G "${CONF}.bak.*" >/dev/null; }; }
ts_present() {
    local f
    [[ -d "$TS_DIR" ]] && return 0
    while read -r f; do [[ -f "$f" ]] && return 0; done < <(ts_unit_paths)
    return 1
}
ufw_rule_present() {
    [[ -n "$UFW_PORT_ADDED" ]] && command -v ufw &>/dev/null \
        && ufw show added 2>/dev/null | grep -qE "allow ${UFW_PORT_ADDED}/tcp"
}
user_present() { [[ -n "$USER_CREATED" ]] && id -u "$TS_USER" &>/dev/null; }
pkgs_present() {
    local pkg out=""
    for pkg in $PKGS_ADDED; do pkg_installed "$pkg" && out="${out:+$out }$pkg"; done
    echo "$out"
}

remove_wg_parts() {
    local other=0 marker=0
    qbit_uses_conf && other=1
    grep -q 'vpn-scripts-managed' "$CONF" 2>/dev/null && marker=1

    if (( other )); then
        # Конфигом пользуется qBittorrent: оставляем. Если создали его мы, ставим метку,
        # чтобы qBittorrent смог удалить конфиг, когда будет удаляться последним.
        [[ "$VPN_SHARED" != "1" && $marker -eq 0 && -f "$CONF" ]] && sed -i '1i # vpn-scripts-managed' "$CONF"
        echo -e "${YELLOW}Туннель ${CONF_NAME} используется qBittorrent: конфиг и туннель оставляю, убираю только свои строки.${NC}"
    elif [[ "$VPN_SHARED" == "1" && $marker -eq 0 ]]; then
        # Конфиг не наш (ваш собственный): трогать его и туннель нельзя
        echo -e "${YELLOW}Конфиг ${CONF_NAME} создан не скриптом: оставляю его и туннель как есть, убираю только свои строки.${NC}"
    else
        systemctl stop "$WG_SVC" 2>/dev/null
        systemctl disable "$WG_SVC" &>/dev/null
        if ip -d link show "$CONF_NAME" 2>/dev/null | grep -q wireguard; then
            ip link del "$CONF_NAME" 2>/dev/null
        fi
        rm -f "$CONF" "${CONF}".bak.*
        systemctl reset-failed "$WG_SVC" 2>/dev/null
    fi
    rm -f "${CONF}".ts-bak.* 2>/dev/null
    VPN_LABEL=""
    VPN_NAME=""
    VPN_SHARED=""
    apply_vpn_vars
}

remove_torrserver_parts() {
    local f
    systemctl stop "$TS_SVC" 2>/dev/null
    systemctl disable "$TS_SVC" &>/dev/null
    while read -r f; do rm -f "$f"; done < <(ts_unit_paths)
    rm -rf "/etc/systemd/system/${TS_SVC}.service.d"
    if [[ -n "$TS_DIR" && "$TS_DIR" != "/" ]]; then
        rm -rf "$TS_DIR"
    fi
    systemctl daemon-reload
    systemctl reset-failed "$TS_SVC" 2>/dev/null
    PROFILE=""

    # HTTPS (его включал ssl.sh): копия сертификата с закрытым ключом и правило UFW, которое открыл ssl.sh
    if [[ -d "$CERT_DIR" ]]; then
        HTTPS_REMOVED_PORT=$(cat "${CERT_DIR}/ufw_port" 2>/dev/null)
        if [[ -n "$HTTPS_REMOVED_PORT" ]] && command -v ufw &>/dev/null; then
            ufw --force delete allow "${HTTPS_REMOVED_PORT}/tcp" >/dev/null 2>&1
            echo "   Удалены копия сертификата для HTTPS (${CERT_DIR}) и правило UFW ${HTTPS_REMOVED_PORT}/tcp."
        else
            echo "   Удалена копия сертификата для HTTPS (${CERT_DIR})."
        fi
        rm -rf "$CERT_DIR"
    fi
}

remove_ufw_rule() {
    ufw --force delete allow "${UFW_PORT_ADDED}/tcp" >/dev/null 2>&1
    UFW_PORT_ADDED=""
}

remove_user() {
    pkill -u "$TS_USER" 2>/dev/null
    userdel "$TS_USER" 2>/dev/null
    getent group "$TS_USER" >/dev/null 2>&1 && groupdel "$TS_USER" 2>/dev/null
    USER_CREATED=""
}

remove_packages() {
    local pkgs="$1" ans
    # shellcheck disable=SC2086
    apt-get purge -y $pkgs
    echo -e "\nПакеты, которые больше никому не нужны, можно убрать командой autoremove."
    echo -e "${YELLOW}Внимание: autoremove может затронуть и пакеты, не связанные с этим скриптом. Проверьте список:${NC}"
    apt-get -s autoremove --purge 2>/dev/null | grep '^Remove' | sed 's/^Remove /  - /' | head -n 30
    read -p "Выполнить autoremove? (y/n, по умолчанию n): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        apt-get autoremove --purge -y
    fi
    # Из учёта убираем всё, чего в системе уже нет
    PKGS_ADDED=$(pkgs_present)
}

uninstall_menu() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ] Что удалить?${NC}"

    local has_r=0 has_w=0 has_t=0 has_f=0 has_u=0 pkgs_now
    routing_present  && has_r=1
    wg_present       && has_w=1
    ts_present       && has_t=1
    ufw_rule_present && has_f=1
    user_present     && has_u=1
    pkgs_now=$(pkgs_present)
    if [[ -n "$pkgs_now" && -f /etc/qbittorrent-vpn.state ]]; then
        # qBittorrent (qbittorrent_full.sh) использует те же системные пакеты: их не трогаем
        local kept="" removable="" pk
        for pk in $pkgs_now; do
            case " wireguard wireguard-tools curl ufw iproute2 python3 " in
                *" $pk "*) kept="${kept:+$kept }$pk" ;;
                *) removable="${removable:+$removable }$pk" ;;
            esac
        done
        if [[ -n "$kept" ]]; then
            echo -e "${YELLOW}На сервере установлен qBittorrent (qbittorrent_full.sh): общие пакеты (${kept}) не удаляю, чтобы не сломать его.${NC}"
        fi
        pkgs_now="$removable"
    fi

    if (( has_r + has_w + has_t + has_f + has_u == 0 )) && [[ -z "$pkgs_now" ]]; then
        echo -e "${GREEN}Скрипт ничего не нашёл: удалять нечего.${NC}"
        [[ -f "$STATE_FILE" ]] && rm -f "$STATE_FILE"
        return
    fi

    echo "Найдено то, что создал скрипт:"
    (( has_r )) && echo "  • привязка TorrServer к VPN (kill-switch, правила маршрутизации, drop-in)"
    (( has_w )) && { wg_shared \
        && echo "  • подключение к общему WireGuard-конфигу ${CONF_NAME} (конфиг удаляется только если он больше никому не нужен и создан скриптом)" \
        || echo "  • WireGuard: ${VPN_LABEL:-$VPN_NAME} (${CONF} и его резервные копии)"; }
    (( has_t )) && echo "  • TorrServer: служба и папка ${TS_DIR} (настройки, база, кэш)"
    (( has_f )) && echo "  • правило UFW для порта ${UFW_PORT_ADDED}/tcp"
    (( has_u )) && echo "  • системный пользователь ${TS_USER}"
    [[ -n "$pkgs_now" ]] && echo "  • пакеты, поставленные скриптом: ${pkgs_now}"
    echo
    echo "1. Всё: вернуть систему к состоянию до установки"
    echo "2. Только VPN (WireGuard + привязка); TorrServer останется и будет работать напрямую"
    echo "3. Только TorrServer (с данными, пользователем и правилом UFW); VPN-конфиг будет отвязан"
    echo "4. Выбрать по компонентам"
    echo "0. Отмена"
    local sc
    read -p "Выберите [0-4]: " sc

    local do_r=0 do_w=0 do_t=0 do_f=0 do_u=0 do_p=0 a
    case "$sc" in
        1) do_r=$has_r; do_w=$has_w; do_t=$has_t; do_f=$has_f; do_u=$has_u; [[ -n "$pkgs_now" ]] && do_p=1 ;;
        2) do_r=$has_r; do_w=$has_w ;;
        3) do_r=$has_r; do_t=$has_t; do_f=$has_f; do_u=$has_u ;;
        4)
            ask_yn() { local r; read -p "$1 (y/n): " r; [[ "$r" == "y" || "$r" == "Y" ]]; }
            (( has_r )) && ask_yn "Убрать привязку к VPN (kill-switch, правила)?" && do_r=1
            (( has_w )) && ask_yn "Удалить конфиг WireGuard ${VPN_LABEL:-$VPN_NAME}?" && do_w=1
            (( has_t )) && ask_yn "Удалить TorrServer вместе с настройками и кэшем (${TS_DIR})?" && do_t=1
            (( has_f )) && ask_yn "Удалить правило UFW для порта ${UFW_PORT_ADDED}/tcp?" && do_f=1
            (( has_u )) && ask_yn "Удалить пользователя ${TS_USER}?" && do_u=1
            [[ -n "$pkgs_now" ]] && ask_yn "Удалить пакеты (${pkgs_now})?" && do_p=1
            unset -f ask_yn
            ;;
        0|"") echo "Отменено."; return ;;
        *) echo -e "${RED}Неверный пункт.${NC}"; return ;;
    esac

    # Зависимости: чтобы после удаления ничего не осталось "висеть" в сломанном состоянии
    local extra=()
    if (( do_w && has_r && !do_r )); then do_r=1; extra+=("привязка к VPN (нужна для удаления WireGuard)"); fi
    if (( do_t && has_r && !do_r )); then do_r=1; extra+=("привязка к VPN (она встроена в службу TorrServer)"); fi
    if (( do_u && has_t && !do_t )); then do_t=1; extra+=("TorrServer (работает от пользователя ${TS_USER})"); fi
    if (( do_u && has_r && !do_r )); then do_r=1; extra+=("привязка к VPN (правила завязаны на пользователя ${TS_USER})"); fi
    if (( do_p )) && [[ " $pkgs_now " == *" wireguard "* || " $pkgs_now " == *" wireguard-tools "* ]]; then
        if (( has_w && !do_w )); then do_w=1; extra+=("конфиг WireGuard (пакеты wireguard будут удалены)"); fi
        if (( has_r && !do_r )); then do_r=1; extra+=("привязка к VPN (пакеты wireguard будут удалены)"); fi
    fi

    if (( do_r + do_w + do_t + do_f + do_u + do_p == 0 )); then
        echo "Ничего не выбрано."
        return
    fi

    echo -e "\n${YELLOW}Будет выполнено:${NC}"
    (( do_r )) && echo "  ✗ привязка к VPN: kill-switch, правила, drop-in, скрипты"
    (( do_w )) && { wg_shared \
        && echo "  ✗ подключение к общему конфигу: убираются только строки TorrServer, конфиг остаётся, если им пользуется qBittorrent или он не создан скриптом" \
        || echo "  ✗ WireGuard: остановка туннеля, удаление ${CONF} и резервных копий"; }
    (( do_r && !do_w && has_w )) && echo "  ↩ конфиг WireGuard вернётся к исходному виду (из резервной копии), служба будет выключена"
    (( do_t )) && echo "  ✗ TorrServer: служба и папка ${TS_DIR} (настройки, база, кэш)"
    (( do_f )) && echo "  ✗ правило UFW ${UFW_PORT_ADDED}/tcp"
    (( do_u )) && echo "  ✗ пользователь ${TS_USER}"
    (( do_p )) && echo "  ✗ пакеты: ${pkgs_now}"
    if (( do_r && !do_t && has_t )); then
        echo -e "  ${YELLOW}⚠ TorrServer продолжит работать, но с обычного IP сервера Oracle (без VPN)${NC}"
    fi
    if (( ${#extra[@]} )); then
        echo -e "${YELLOW}Дополнительно из-за зависимостей:${NC}"
        printf '  + %s\n' "${extra[@]}"
    fi
    echo
    local ok
    read -p "Подтвердите удаление (y/n): " ok
    [[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "Отменено."; return; }

    # Порядок важен: сначала привязка (нужен пользователь), затем VPN, TorrServer, UFW, пользователь, пакеты
    (( do_r )) && { echo "→ убираю привязку к VPN..."; remove_routing_parts; }
    if (( do_w )); then
        echo "→ обрабатываю WireGuard-конфиг..."; remove_wg_parts
    elif (( do_r && has_w )); then
        restore_conf_backup
    fi
    if (( do_t )); then
        echo "→ удаляю TorrServer..."; remove_torrserver_parts
    elif (( do_r && has_t )); then
        echo "→ запускаю TorrServer без VPN..."; systemctl start "$TS_SVC" 2>/dev/null
    fi
    (( do_f )) && { echo "→ удаляю правило UFW..."; remove_ufw_rule; }
    (( do_u )) && { echo "→ удаляю пользователя ${TS_USER}..."; remove_user; }
    (( do_p )) && { echo "→ удаляю пакеты..."; remove_packages "$pkgs_now"; }

    # Если удалён пакет ufw, учёт правила больше не нужен
    pkg_installed ufw || UFW_PORT_ADDED=""
    # Пользователя могли удалить и вручную
    id -u "$TS_USER" &>/dev/null || USER_CREATED=""

    # Учёт: если от установки ничего не осталось, удаляем и файл состояния
    if [[ -z "$VPN_NAME" ]] && ! ts_present && ! routing_present \
        && [[ -z "$(pkgs_present)" && -z "$UFW_PORT_ADDED" && -z "$USER_CREATED" ]]; then
        rm -f "$STATE_FILE"
        echo -e "\n${GREEN}✅ Всё удалено. Система возвращена к состоянию до установки.${NC}"
    else
        save_state
        echo -e "\n${GREEN}✅ Выбранное удалено. Оставшееся можно удалить повторно через этот же пункт.${NC}"
    fi

    echo -e "${YELLOW}Не забудьте вручную:${NC}"
    (( do_f )) || (( do_t )) && echo "  • закрыть порт ${WEB_PORT} в Oracle Cloud (Security List / NSG), если открывали"
    [[ -n "$HTTPS_REMOVED_PORT" ]] && echo "  • закрыть порт HTTPS ${HTTPS_REMOVED_PORT} в Oracle Cloud (Security List / NSG), если открывали"
    (( do_w )) && echo "  • отозвать (удалить) ключ/устройство в кабинете VPN-провайдера"
    echo "  • файлы, которые установщик TorrServer мог создать вне ${TS_DIR}, скрипт не отслеживает"
}

# ---------------------------------------------------------------- ПЕРЕХОД В ssl.sh

# Скачивает ssl.sh (выпуск и установка сертификата, включение HTTPS) и запускает его.
# После выхода из него (пункт 0) вы вернётесь в это меню.
run_ssl_script() {
    echo -e "\n${YELLOW}=== Сертификат для HTTPS: переход в ssl.sh ===${NC}"
    command -v curl &>/dev/null || apt_install_tracked curl || return 1
    local tmp
    tmp=$(mktemp /tmp/ssl.XXXXXX.sh) || { echo -e "${RED}Не удалось создать временный файл.${NC}"; return 1; }
    echo "Скачиваю ssl.sh: ${SSL_SCRIPT_URL}"
    if ! curl -fsSL --max-time 30 "$SSL_SCRIPT_URL" -o "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]] || ! head -n 1 "$tmp" | grep -q '^#!.*bash'; then
        echo -e "${RED}❌ Не удалось скачать ssl.sh (нет интернета, неверная ссылка или файл не скрипт).${NC}"
        rm -f "$tmp"
        return 1
    fi
    echo -e "${GREEN}✅ Скачан. Запускаю (выход из ssl.sh: пункт 0, потом вы вернётесь сюда).${NC}\n"
    bash "$tmp"
    rm -f "$tmp"
    echo -e "\n${GREEN}Вы вернулись в меню TorrServer.${NC} Проверить, что HTTPS работает: пункт 8."
}

# ---------------------------------------------------------------- МЕНЮ

while true; do
    if vpn_configured; then
        vpn_info="VPN: ${VPN_LABEL} (${CONF_NAME})"
    else
        vpn_info="VPN: не настроен"
    fi
    echo -e "\n${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}   Управление TorrServer + WireGuard VPN (Oracle)   ${NC}"
    echo -e "${YELLOW}   ${vpn_info} | профиль: ${PROFILE:-не выбран}   ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo "1.  Полная установка (VPN + Kill-Switch + TorrServer)"
    echo "2.  Установить только TorrServer (без VPN)"
    echo "3.  Настроить / Перезапустить WireGuard (VPN-провайдер)"
    echo "4.  Сменить профиль настроек TorrServer (слабая / мощная VPS)"
    echo "5.  Привязать TorrServer к VPN (и применить профиль настроек)"
    echo "6.  Проверить статус WireGuard (Интерфейс и IP)"
    echo "7.  Проверить статус TorrServer"
    echo "8.  ПРОВЕРКА БЕЗОПАСНОСТИ (Маршруты, IP, Привязка)"
    echo "9.  Запустить АВТО-ИСПРАВЛЕНИЕ вручную"
    echo "10. Откат (убрать привязку к VPN)"
    echo "11. Удаление (вернуть систему к состоянию до установки)"
    echo "12. Сертификат HTTPS: перейти в скрипт ssl.sh (выпуск и установка)"
    echo "0.  Выход"
    echo "=================================================="
    read -p "Выберите действие [0-12]: " choice

    case $choice in
        1) setup_vpn && setup_torrserver; check_safety ;;
        2) setup_torrserver_only ;;
        3) setup_vpn ;;
        4) change_profile ;;
        5) fix_torrserver_binding ;;
        6) check_vpn ;;
        7) check_torrserver ;;
        8) check_safety ;;
        9) auto_fix ;;
        10) revert_routing ;;
        11) uninstall_menu ;;
        12) run_ssl_script ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
