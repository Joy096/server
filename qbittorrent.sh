#!/bin/bash
# qbittorrent_full.sh - qBittorrent-nox + WireGuard VPN + kill-switch для Ubuntu (Oracle Cloud)
#
# Схема та же, что в torrserver_full.sh для TorrServer: через VPN идёт ТОЛЬКО трафик пользователя
# "qbittorrent" (policy routing по UID). SSH, apt и всё остальное ходит напрямую.
#   - ответы веб-интерфейса qBittorrent (порт 8080 по умолчанию) идут напрямую к вам;
#   - kill-switch: если VPN упал, у пользователя qbittorrent нет сети вообще.
#
# Два сценария, скрипт определяет их сам:
#   1) На сервере уже есть WireGuard-конфиг (например, от torrserver_full.sh для TorrServer):
#      qBittorrent подключается к ТОМУ ЖЕ туннелю, второй VPN-ключ не нужен.
#      Конфиг не пересоздаётся, к нему добавляются две строки PostUp/PreDown.
#      TorrServer при этом продолжает работать как раньше.
#   2) Чистый сервер: скрипт спросит провайдера, примет ваш WireGuard-конфиг и настроит всё с нуля.
#
# У qBittorrent свои номера таблицы маршрутизации (101) и правил (91/101/111),
# поэтому он не пересекается с TorrServer (100 и 90/100/110).
#
# Дополнительно: создание .torrent из файла или папки и запуск раздачи (как в qBittorrent.sh).
#
# HTTPS для веб-интерфейса включает скрипт ssl.sh (пункты 1 и 2): он кладёт сертификат в /etc/qbittorrent-cert
# и прописывает его в qBittorrent. Этот скрипт сам определяет, что HTTPS включён, и ходит в веб-интерфейс
# по https://127.0.0.1 (с curl -k). На работу через VPN HTTPS не влияет.

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Этот скрипт должен выполняться с правами root!${NC}"
    exit 1
fi

QB_USER="qbittorrent"
QB_SVC="qbittorrent"
QB_HOME="/home/${QB_USER}"
DL_DIR="${QB_HOME}/Downloads"
TORRENT_DIR="${QB_HOME}/torrent_files"
QB_CONF="${QB_HOME}/.config/qBittorrent/qBittorrent.conf"
QB_UNIT="/etc/systemd/system/${QB_SVC}.service"

TABLE=101
PRIO_SPORT=91
PRIO_ROUTE=101
PRIO_KILL=111
KS_SCRIPT="/usr/local/sbin/qbittorrent-ks.sh"
VPN_SCRIPT="/usr/local/sbin/qbittorrent-vpn.sh"
KS_UNIT="/etc/systemd/system/qbittorrent-killswitch.service"
DROPIN_DIR="/etc/systemd/system/${QB_SVC}.service.d"
DROPIN="${DROPIN_DIR}/vpn.conf"

CRED_FILE="/etc/qbittorrent-credentials"
TRACKERS_FILE="/etc/qbittorrent-trackers.txt"
QB_CERT_DIR="/etc/qbittorrent-cert"      # сертификат для HTTPS веб-интерфейса (создаёт ssl.sh)
SSL_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh"   # пункт 13 меню
STATE_FILE="/etc/qbittorrent-vpn.state"
TS_STATE="/etc/torrserver-vpn.state"     # состояние torrserver_full.sh (чтобы подхватить название провайдера)
DEFAULT_WEB_PORT=8080

# Состояние между запусками
VPN_LABEL=""       # название провайдера (для сообщений)
VPN_NAME=""        # имя WireGuard-интерфейса и конфига
VPN_SHARED=""      # 1, если подключились к уже существующему конфигу (его создали не мы)
WEB_PORT="$DEFAULT_WEB_PORT"
# Что создал скрипт (чтобы удаление вернуло систему к состоянию "до установки"):
PKGS_ADDED=""      # пакеты, которых не было в системе
UFW_RULES=""       # правила UFW, которых не было (через пробел, например "8080/tcp")
USER_CREATED=""    # 1, если пользователя qbittorrent создали мы

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
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    apply_vpn_vars
}

save_state() {
    {
        echo "VPN_LABEL=$(printf '%q' "$VPN_LABEL")"
        echo "VPN_NAME=$(printf '%q' "$VPN_NAME")"
        echo "VPN_SHARED=$(printf '%q' "$VPN_SHARED")"
        echo "WEB_PORT=$(printf '%q' "$WEB_PORT")"
        echo "PKGS_ADDED=$(printf '%q' "$PKGS_ADDED")"
        echo "UFW_RULES=$(printf '%q' "$UFW_RULES")"
        echo "USER_CREATED=$(printf '%q' "$USER_CREATED")"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_state

# ---------------------------------------------------------------- ОБЩИЕ ФУНКЦИИ

yn() { local a; read -rp "$1 (y/n): " a; [[ "$a" == "y" || "$a" == "Y" ]]; }

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# apt install с запоминанием пакетов, которых раньше в системе не было (для удаления)
apt_install_tracked() {
    local pkg
    local watch=("$@")
    local newly=()
    [[ " $* " == *" wireguard "* ]] && watch+=("wireguard-tools")

    for pkg in "${watch[@]}"; do
        pkg_installed "$pkg" || newly+=("$pkg")
    done

    apt-get update && apt-get install -y "$@" || return 1

    for pkg in "${newly[@]}"; do
        if pkg_installed "$pkg" && [[ " $PKGS_ADDED " != *" $pkg "* ]]; then
            PKGS_ADDED="${PKGS_ADDED:+$PKGS_ADDED }$pkg"
        fi
    done
    save_state
}

# Открывает порт в UFW; запоминает правило, только если его раньше не было
ufw_allow_tracked() {
    local rule="$1"
    command -v ufw &>/dev/null || { echo -e "${YELLOW}ufw не установлен, порт ${rule} не открываю.${NC}"; return; }
    if ! ufw show added 2>/dev/null | grep -qxF "ufw allow ${rule}"; then
        [[ " $UFW_RULES " != *" $rule "* ]] && UFW_RULES="${UFW_RULES:+$UFW_RULES }$rule"
        save_state
    fi
    ufw allow "$rule"
}

# Внешний IP. Аргументы (необязательно) - команда-обёртка, например: runuser -u qbittorrent --
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

ensure_user() {
    if ! id -u "$QB_USER" &>/dev/null; then
        useradd -r -m -d "$QB_HOME" -s /usr/sbin/nologin "$QB_USER" && { USER_CREATED=1; save_state; }
    fi
    mkdir -p "$DL_DIR" "$TORRENT_DIR"
    chown "$QB_USER:$QB_USER" "$QB_HOME" "$DL_DIR" "$TORRENT_DIR"
}

# Порт веб-интерфейса: из конфига qBittorrent, потом из состояния, по умолчанию 8080
detect_port() {
    local p
    p=$(grep -oP '^WebUI\\Port=\K[0-9]+' "$QB_CONF" 2>/dev/null | head -n 1)
    [[ -n "$p" ]] && WEB_PORT="$p"
    [[ -z "$WEB_PORT" ]] && WEB_PORT="$DEFAULT_WEB_PORT"
}

# Протокол веб-интерфейса по настройкам: https, если в конфиге qBittorrent включён HTTPS (его включает ssl.sh)
web_scheme() {
    local en
    en=$(grep -oiP '^WebUI\\HTTPS\\Enabled=\K\w+' "$QB_CONF" 2>/dev/null | head -n 1)
    if [[ "${en,,}" == "true" ]]; then echo https; else echo http; fi
}

# Адрес веб-интерфейса для запросов с самого сервера. Запросы к нему делаются с curl -k:
# сертификат выписан на ваш домен, а не на 127.0.0.1, поэтому проверку имени нужно пропускать.
web_base() {
    local s
    detect_port
    s=$(web_scheme)
    if [[ "$s" == "https" ]] \
        && ! curl -sk -o /dev/null --max-time 3 "https://127.0.0.1:${WEB_PORT}/" 2>/dev/null \
        && curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null; then
        s=http   # HTTPS включён в настройках, но не поднялся (например, не прочитался сертификат): отвечает HTTP
    fi
    echo "${s}://127.0.0.1:${WEB_PORT}"
}

vpn_configured() { [[ -n "$VPN_NAME" && -f "$CONF" ]]; }

# Конфиг общий, если его создали не мы или к нему подключён TorrServer
wg_shared() {
    [[ "$VPN_SHARED" == "1" ]] && return 0
    [[ -f "$CONF" ]] && grep -q 'torrserver-vpn\.sh' "$CONF" 2>/dev/null
}

qb_installed() { [[ -f "$QB_UNIT" ]]; }

# Ключ в секции [Preferences] файла qBittorrent.conf (старая строка заменяется).
# Ключ передаётся как в файле, с одним обратным слэшем: set_pref 'WebUI\Port' 8080
set_pref() {
    local key="$1" val="$2" f="${3:-$QB_CONF}"
    mkdir -p "$(dirname "$f")"
    [[ -f "$f" ]] || : > "$f"
    grep -q '^\[Preferences\]' "$f" || printf '\n[Preferences]\n' >> "$f"
    KEY="$key" VAL="$val" awk '
        BEGIN { prefix = ENVIRON["KEY"] "=" }
        index($0, prefix) == 1 { next }
        { print }
        /^\[Preferences\]/ { print ENVIRON["KEY"] "=" ENVIRON["VAL"] }
    ' "$f" > "${f}.tmp" && cat "${f}.tmp" > "$f"
    rm -f "${f}.tmp"
}

# Привязка qBittorrent к интерфейсу VPN (Tools -> Options -> Advanced -> Network interface).
# Менять файл можно только при остановленной службе: qBittorrent перезаписывает его при выходе.
# Эти ключи лежат в секции [BitTorrent], а не в [Preferences].
set_bt_key() {
    local key="$1" val="$2" f="$QB_CONF"
    mkdir -p "$(dirname "$f")"
    [[ -f "$f" ]] || : > "$f"
    grep -q '^\[BitTorrent\]' "$f" || printf '\n[BitTorrent]\n' >> "$f"
    KEY="$key" VAL="$val" awk '
        BEGIN { prefix = ENVIRON["KEY"] "="; insec = 0 }
        /^\[/ { insec = ($0 == "[BitTorrent]") }
        insec && index($0, prefix) == 1 { next }
        { print }
        $0 == "[BitTorrent]" { print ENVIRON["KEY"] "=" ENVIRON["VAL"] }
    ' "$f" > "${f}.tmp" && cat "${f}.tmp" > "$f"
    rm -f "${f}.tmp"
}
set_qb_interface() {
    [[ -n "$1" ]] || return 0
    set_bt_key 'Session\Interface' "$1"
    set_bt_key 'Session\InterfaceName' "$1"
}
clear_qb_interface() {
    [[ -f "$QB_CONF" ]] && sed -i '/^Session\\Interface=/d; /^Session\\InterfaceName=/d' "$QB_CONF"
    return 0
}

# Хеш пароля веб-интерфейса в формате qBittorrent: PBKDF2-HMAC-SHA512, 100000 итераций, соль 16 байт
qb_hash() {
    printf '%s' "$1" | python3 -c '
import sys, os, hashlib, base64
pw = sys.stdin.buffer.read()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
print(base64.b64encode(salt).decode() + ":" + base64.b64encode(dk).decode())
'
}

# Записывает логин и пароль в конфиг qBittorrent (служба в это время должна быть остановлена)
write_webui_credentials() {
    local user="$1" pass="$2" h
    h=$(qb_hash "$pass") || return 1
    set_pref 'WebUI\Username' "$user"
    set_pref 'WebUI\Password_PBKDF2' "\"@ByteArray(${h})\""
    chown -R "$QB_USER:$QB_USER" "${QB_HOME}/.config"
    chmod 600 "$QB_CONF"
}

save_credentials() {
    ( umask 077; printf '%s:%s\n' "$1" "$2" > "$CRED_FILE" )
}

# Вход в API. Печатает путь к файлу cookie или ничего при ошибке.
# Внимание: после 5 неверных входов qBittorrent банит адрес на час, поэтому пароль берём только из файла.
api_login() {
    [[ -f "$CRED_FILE" ]] || return 1
    detect_port
    local user pass jar res
    user=$(cut -d: -f1 "$CRED_FILE")
    pass=$(cut -d: -f2- "$CRED_FILE")
    jar=$(mktemp)
    res=$(curl -sk -c "$jar" --max-time 8 --data-urlencode "username=${user}" --data-urlencode "password=${pass}" \
        "$(web_base)/api/v2/auth/login")
    if [[ "$res" == "Ok." ]]; then
        echo "$jar"
    else
        rm -f "$jar"
        return 1
    fi
}

wait_for_web() {
    local i code
    detect_port
    echo -n "Жду запуска веб-интерфейса"
    for i in $(seq 1 40); do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "$(web_base)/" 2>/dev/null)
        [[ "$code" == "200" ]] && { echo; return 0; }
        echo -n "."; sleep 1
    done
    echo
    return 1
}

# ---------------------------------------------------------------- VPN-ПРОВАЙДЕР

sanitize_iface() {
    local s
    s=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//' | cut -c1-15 | sed -E 's/-+$//')
    echo "${s:-vpn}"
}

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
        echo -e "${YELLOW}⚠️ В AllowedIPs нет 0.0.0.0/0: через такой туннель пойдёт не весь трафик qBittorrent.${NC}"
        echo "   Обычно у VPN-провайдера там должно быть 0.0.0.0/0 (или 0.0.0.0/0, ::/0)."
        yn "Всё равно продолжить?" || return 1
    fi
    return 0
}

# Правка СВОЕГО (только что вставленного) wg-конфига под нашу схему, так же как в torrserver_full.sh.
# Строки, относящиеся к TorrServer (torrserver-vpn.sh), не трогаем.
fix_vpn_config() {
    local conf_file="$1"

    sed -i 's/\r$//' "$conf_file"

    # Бэкап исходного конфига провайдера (один раз, до первой правки)
    if ! grep -q "$VPN_SCRIPT" "$conf_file"; then
        cp -a "$conf_file" "${conf_file}.bak.$(date +%Y%m%d-%H%M%S)"
        chmod 600 "${conf_file}".bak.* 2>/dev/null
    fi

    sed -i -E '/torrserver-vpn\.sh/!{/^[[:space:]]*(Table|PostUp|PreUp|PreDown|PostDown|DNS|SaveConfig)[[:space:]]*=/Id}' "$conf_file"

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

# Подключение к УЖЕ настроенному конфигу (например, от torrserver_full.sh): добавляем только наши строки.
join_wg_conf() {
    local conf_file="$1"

    if ! grep -qiE '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off' "$conf_file"; then
        echo -e "${RED}❌ В ${conf_file} нет строки «Table = off».${NC}"
        echo "   Через такой конфиг wg-quick завернёт ВЕСЬ трафик сервера в VPN, включая SSH. Подключаться к нему нельзя."
        echo "   Выберите «добавить отдельный конфиг» или настройте этот конфиг скриптом torrserver_full.sh."
        return 1
    fi

    if grep -qF "$VPN_SCRIPT" "$conf_file"; then
        return 0
    fi

    cp -a "$conf_file" "${conf_file}.qb-bak.$(date +%Y%m%d-%H%M%S)"
    chmod 600 "${conf_file}".qb-bak.* 2>/dev/null

    local tmp_file
    tmp_file=$(mktemp)
    awk -v up="PostUp = ${VPN_SCRIPT} up %i" -v down="PreDown = ${VPN_SCRIPT} down %i" '
        { print }
        /^\[Interface\]/ && !done { print up; print down; done = 1 }
    ' "$conf_file" > "$tmp_file" && cat "$tmp_file" > "$conf_file"
    rm -f "$tmp_file"
    chmod 600 "$conf_file"
}

# Название провайдера для общего конфига: берём из состояния TorrServer, если оно есть
guess_label() {
    local name="$1" label=""
    if [[ -f "$TS_STATE" ]]; then
        label=$( ( source "$TS_STATE" 2>/dev/null; [[ "$VPN_NAME" == "$name" ]] && echo "$VPN_LABEL" ) )
    fi
    echo "${label:-$name}"
}

ask_vpn_provider() {
    local label iface
    echo -e "\n${YELLOW}=== VPN-провайдер ===${NC}"
    read -rp "Название VPN-провайдера (например: ClearVPN, Mullvad, ProtonVPN): " label
    [[ -z "$label" ]] && label="VPN"

    iface=$(sanitize_iface "$label")
    # Не должно совпадать с существующим интерфейсом или конфигом (в том числе чужим)
    if { ip link show dev "$iface" &>/dev/null && ! wg show "$iface" &>/dev/null; } || [[ -f "/etc/wireguard/${iface}.conf" ]]; then
        iface="$(echo "$iface" | cut -c1-12)-qb"
    fi

    VPN_LABEL="$label"
    VPN_NAME="$iface"
    VPN_SHARED=""
    apply_vpn_vars
    save_state
    echo -e "${GREEN}Провайдер: ${VPN_LABEL}. Интерфейс и конфиг: ${CONF_NAME} (${CONF})${NC}"
}

# ---------------------------------------------------------------- МАРШРУТИЗАЦИЯ И KILL-SWITCH

install_routing_helpers() {
    detect_port

    cat > "$KS_SCRIPT" <<'KSEOF'
#!/bin/bash
# up|down. Ответы веб-интерфейса qBittorrent с порта PORT идут обычным маршрутом,
# любой другой трафик пользователя qbittorrent запрещён, пока нет правила через VPN.
U=$(id -u qbittorrent) || exit 1
PORT=__PORT__
clean() {
    for p in __PSPORT__ __PKILL__; do
        while ip -4 rule del priority $p 2>/dev/null; do :; done
        while ip -6 rule del priority $p 2>/dev/null; do :; done
    done
}
case "$1" in
    up)
        clean
        ip -4 rule add priority __PSPORT__ ipproto tcp sport "$PORT" lookup main || exit 1
        ip -4 rule add priority __PKILL__ uidrange "$U-$U" prohibit || exit 1
        ip -6 rule add priority __PSPORT__ ipproto tcp sport "$PORT" lookup main 2>/dev/null
        ip -6 rule add priority __PKILL__ uidrange "$U-$U" prohibit 2>/dev/null
        ;;
    down) clean ;;
    *) exit 1 ;;
esac
exit 0
KSEOF
    sed -i -e "s/__PORT__/${WEB_PORT}/" -e "s/__PSPORT__/${PRIO_SPORT}/g" -e "s/__PKILL__/${PRIO_KILL}/g" "$KS_SCRIPT"

    cat > "$VPN_SCRIPT" <<'VPNEOF'
#!/bin/bash
# up|down <интерфейс>
U=$(id -u qbittorrent) || exit 1
TABLE=__TABLE__
case "$1" in
    up)
        ip route replace default dev "$2" table "$TABLE" || exit 1
        while ip -4 rule del priority __PROUTE__ 2>/dev/null; do :; done
        ip -4 rule add priority __PROUTE__ uidrange "$U-$U" lookup "$TABLE" || exit 1
        # Туннель поднялся заново (перезапуск VPN): перезапускаем qBittorrent, чтобы он сам переподключился.
        # Если служба не запущена (загрузка системы), команда ничего не делает.
        systemctl try-restart --no-block qbittorrent.service >/dev/null 2>&1
        ;;
    down)
        while ip -4 rule del priority __PROUTE__ 2>/dev/null; do :; done
        ip route flush table "$TABLE" 2>/dev/null
        ;;
    *) exit 1 ;;
esac
exit 0
VPNEOF
    sed -i -e "s/__TABLE__/${TABLE}/" -e "s/__PROUTE__/${PRIO_ROUTE}/g" "$VPN_SCRIPT"
    chmod 755 "$KS_SCRIPT" "$VPN_SCRIPT"

    cat > "$KS_UNIT" <<UNITEOF
[Unit]
Description=qBittorrent kill-switch (запрет трафика мимо VPN)
Before=${QB_SVC}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${KS_SCRIPT} up
ExecStop=${KS_SCRIPT} down

[Install]
WantedBy=multi-user.target
UNITEOF

    systemctl daemon-reload
    systemctl enable qbittorrent-killswitch &>/dev/null
    systemctl restart qbittorrent-killswitch
}

# Зависимость службы qBittorrent от kill-switch и WireGuard (через drop-in)
fix_systemd_dropin() {
    mkdir -p "$DROPIN_DIR"
    cat > "$DROPIN" <<DROPEOF
[Unit]
Requires=qbittorrent-killswitch.service
Wants=${WG_SVC}.service
After=qbittorrent-killswitch.service ${WG_SVC}.service network-online.target
DROPEOF
    systemctl daemon-reload
}

# ---------------------------------------------------------------- VPN: ПОДКЛЮЧЕНИЕ

setup_vpn() {
    echo -e "\n${YELLOW}=== VPN для qBittorrent ===${NC}"
    apt_install_tracked wireguard curl ufw iproute2 python3 || return 1
    check_kernel_support || return 1

    ensure_user
    install_routing_helpers

    # Уже подключались: просто перенастроить
    if vpn_configured; then
        echo -e "${GREEN}Текущий VPN: ${VPN_LABEL:-?} (интерфейс ${CONF_NAME})$(wg_shared && echo ', общий конфиг')${NC}"
        if ! yn "Заменить VPN-конфиг или сменить провайдера?"; then
            reapply_vpn
            return $?
        fi
        remove_vpn_parts_for_replace
    fi

    # Есть ли уже WireGuard-конфиги на сервере
    local confs=() f n
    for f in /etc/wireguard/*.conf; do
        [[ -f "$f" ]] || continue
        n=$(basename "$f" .conf)
        confs+=("$n")
    done

    local choice="2" pick=""
    if [[ ${#confs[@]} -gt 0 ]]; then
        echo -e "\nНа сервере уже есть WireGuard-конфиг(и):"
        local i=1
        for n in "${confs[@]}"; do
            echo "   ${i}. ${n}  $(grep -q 'torrserver-vpn\.sh' "/etc/wireguard/${n}.conf" 2>/dev/null && echo '(используется TorrServer)')"
            i=$((i + 1))
        done
        echo
        echo "1. Использовать существующий туннель (второй VPN-ключ не нужен)"
        echo "2. Добавить отдельный конфиг для qBittorrent"
        read -rp "Выберите [1-2, Enter = 1]: " choice
        [[ "$choice" != "2" ]] && choice="1"
        if [[ "$choice" == "1" ]]; then
            if [[ ${#confs[@]} -eq 1 ]]; then
                pick="${confs[0]}"
            else
                read -rp "Номер конфига [1-${#confs[@]}]: " i
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
        join_wg_conf "$CONF" || { VPN_NAME=""; VPN_LABEL=""; VPN_SHARED=""; apply_vpn_vars; return 1; }
        save_state
        activate_shared_tunnel
        return $?
    fi

    # Отдельный конфиг (чистый сервер или второй туннель)
    ask_vpn_provider
    echo -e "\n${YELLOW}Вставьте содержимое .conf файла WireGuard от ${VPN_LABEL} и нажмите ENTER, затем Ctrl+D:${NC}"
    mkdir -p /etc/wireguard
    ( umask 077; cat > "$CONF" )

    if [[ ! -s "$CONF" ]]; then
        echo -e "${RED}❌ Файл конфигурации пуст.${NC}"
        rm -f "$CONF"
        VPN_NAME=""; VPN_LABEL=""; apply_vpn_vars; save_state
        return 1
    fi

    sed -i 's/\r$//' "$CONF"
    if ! validate_wg_conf "$CONF"; then
        echo -e "${RED}Конфиг не принят и удалён. Запустите пункт 3 и вставьте конфиг заново.${NC}"
        rm -f "$CONF"
        VPN_NAME=""; VPN_LABEL=""; apply_vpn_vars; save_state
        return 1
    fi

    fix_vpn_config "$CONF"
    # Метка: конфиг создан скриптом, его можно удалить, когда он больше никому не нужен
    grep -q 'vpn-scripts-managed' "$CONF" || sed -i '1i # vpn-scripts-managed' "$CONF"
    [[ -f "$DROPIN" ]] && fix_systemd_dropin

    systemctl restart "$WG_SVC"
    systemctl enable "$WG_SVC" &>/dev/null

    if wg show "$CONF_NAME" &>/dev/null; then
        echo -e "${GREEN}✅ WireGuard (${VPN_LABEL}, интерфейс ${CONF_NAME}) запущен!${NC}"
    else
        echo -e "${RED}❌ Ошибка запуска WireGuard. Смотрите: journalctl -u ${WG_SVC} -n 30${NC}"
        return 1
    fi
}

# Общий туннель: добавленные строки PostUp сработают при следующем старте, поэтому включаем маршрут сразу,
# не перезапуская туннель (TorrServer при этом не страдает).
activate_shared_tunnel() {
    if wg show "$CONF_NAME" &>/dev/null; then
        "$VPN_SCRIPT" up "$CONF_NAME" && echo -e "${GREEN}✅ qBittorrent подключён к туннелю ${CONF_NAME} (${VPN_LABEL}); перезапуск туннеля не потребовался.${NC}"
    else
        systemctl enable --now "$WG_SVC" &>/dev/null
        if wg show "$CONF_NAME" &>/dev/null; then
            echo -e "${GREEN}✅ Туннель ${CONF_NAME} (${VPN_LABEL}) был выключен, я его запустил.${NC}"
        else
            echo -e "${RED}❌ Не удалось поднять туннель. Смотрите: journalctl -u ${WG_SVC} -n 30${NC}"
            return 1
        fi
    fi
    [[ -f "$DROPIN" ]] && fix_systemd_dropin
    return 0
}

# Повторное применение без замены конфига
reapply_vpn() {
    if wg_shared; then
        join_wg_conf "$CONF" || return 1
        activate_shared_tunnel
    else
        fix_vpn_config "$CONF"
        systemctl restart "$WG_SVC"
        systemctl enable "$WG_SVC" &>/dev/null
    fi
}

# Подготовка к замене VPN: старое подключение убираем (общий конфиг остаётся другому скрипту)
remove_vpn_parts_for_replace() {
    if qb_installed && grep -q 'Session\\Interface=' "$QB_CONF" 2>/dev/null; then
        # Имя интерфейса сменится: старую привязку снимаем (новая ставится пунктом 4)
        systemctl stop "$QB_SVC" 2>/dev/null
        clear_qb_interface
        systemctl start "$QB_SVC" 2>/dev/null
    fi
    if wg_shared; then
        [[ -x "$VPN_SCRIPT" ]] && "$VPN_SCRIPT" down "$CONF_NAME" 2>/dev/null
        [[ -f "$CONF" ]] && sed -i '\#qbittorrent-vpn\.sh#d' "$CONF"
    fi
    remove_vpn_parts
    save_state
}

# ---------------------------------------------------------------- УСТАНОВКА QBITTORRENT

ask_web_settings() {
    local in
    WEB_PORT_NEW=""; WEB_USER_NEW=""; WEB_PASS_NEW=""
    while true; do
        read -rp "Порт веб-интерфейса [${DEFAULT_WEB_PORT}]: " in
        in="${in:-$DEFAULT_WEB_PORT}"
        if [[ ! "$in" =~ ^[0-9]+$ ]] || (( in < 1024 || in > 65535 )); then
            echo -e "${RED}Порт должен быть числом от 1024 до 65535. Попробуйте ещё раз.${NC}"
        elif ss -ltn 2>/dev/null | grep -q ":${in} " && ! { qb_installed && [[ "$in" == "$WEB_PORT" ]]; }; then
            echo -e "${RED}Порт ${in} уже занят другой программой. Выберите другой.${NC}"
        else
            WEB_PORT_NEW="$in"
            break
        fi
    done
    read -rp "Логин веб-интерфейса [admin]: " WEB_USER_NEW
    WEB_USER_NEW="${WEB_USER_NEW:-admin}"
    while true; do
        read -rp "Пароль веб-интерфейса (минимум 8 символов): " in
        if (( ${#in} < 8 )); then
            echo -e "${RED}Слишком короткий: ${#in} симв., нужно минимум 8. Попробуйте ещё раз.${NC}"
        else
            WEB_PASS_NEW="$in"
            break
        fi
    done
}

write_qb_unit() {
    cat > "$QB_UNIT" <<UNITEOF
[Unit]
Description=qBittorrent-nox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${QB_USER}
Group=${QB_USER}
ExecStart=/usr/bin/qbittorrent-nox --webui-port=${WEB_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload
}

# Общая часть установки (режимы с VPN и без)
install_qbittorrent_core() {
    apt_install_tracked qbittorrent-nox mktorrent curl ufw python3 || return 1
    ensure_user

    systemctl stop "$QB_SVC" 2>/dev/null

    if [[ -f "$QB_CONF" ]]; then
        echo -e "${YELLOW}Найден прежний конфиг qBittorrent: логин и пароль сохраняются.${NC}"
        detect_port
        read -rp "Порт веб-интерфейса [${WEB_PORT}]: " in
        [[ "$in" =~ ^[0-9]+$ ]] && (( in >= 1024 && in <= 65535 )) && WEB_PORT="$in"
        set_pref 'WebUI\Port' "$WEB_PORT"
        chown -R "$QB_USER:$QB_USER" "${QB_HOME}/.config"
    else
        ask_web_settings
        WEB_PORT="$WEB_PORT_NEW"
        mkdir -p "$(dirname "$QB_CONF")"
        printf '[LegalNotice]\nAccepted=true\n' > "$QB_CONF"
        set_pref 'WebUI\Port' "$WEB_PORT"
        set_pref 'Downloads\SavePath' "$DL_DIR"
        write_webui_credentials "$WEB_USER_NEW" "$WEB_PASS_NEW" || { echo -e "${RED}Не удалось записать пароль.${NC}"; return 1; }
        save_credentials "$WEB_USER_NEW" "$WEB_PASS_NEW"
    fi
    save_state

    write_qb_unit
    systemctl enable "$QB_SVC" &>/dev/null
    systemctl restart "$QB_SVC"

    ufw_allow_tracked "${WEB_PORT}/tcp"

    if wait_for_web; then
        echo -e "${GREEN}✅ qBittorrent запущен.${NC}"
    else
        echo -e "${RED}❌ Веб-интерфейс не ответил. Смотрите: journalctl -u ${QB_SVC} -n 30${NC}"
        return 1
    fi
}

# Привязка qBittorrent к VPN: kill-switch, drop-in, перезапуск службы
fix_qbit_binding() {
    if ! vpn_configured; then
        echo -e "${RED}❌ VPN не настроен. Сначала выполните пункт 3: иначе kill-switch оставит qBittorrent без сети.${NC}"
        return 1
    fi
    if ! qb_installed; then
        echo -e "${RED}❌ qBittorrent не установлен (пункт 1 или 2).${NC}"
        return 1
    fi
    systemctl stop "$QB_SVC" 2>/dev/null
    ensure_user
    install_routing_helpers
    fix_systemd_dropin
    set_qb_interface "$CONF_NAME"
    systemctl start "$QB_SVC"
    echo -e "${GREEN}✅ qBittorrent работает от пользователя '${QB_USER}', весь его трафик идёт только через VPN ${VPN_LABEL:-$CONF_NAME} (kill-switch активен).${NC}"
}

setup_full() {
    echo -e "\n${YELLOW}=== Полная установка: VPN + kill-switch + qBittorrent ===${NC}"
    setup_vpn || return 1
    echo -e "\n${YELLOW}=== Установка qBittorrent ===${NC}"
    install_qbittorrent_core || return 1
    fix_qbit_binding || return 1
    echo -e "${YELLOW}Не забудьте открыть порт ${WEB_PORT}/tcp в Security List / NSG в консоли Oracle Cloud.${NC}"
    show_address
}

setup_qbit_only() {
    echo -e "\n${YELLOW}=== Установка только qBittorrent (без VPN) ===${NC}"
    echo -e "${YELLOW}⚠️ Без VPN весь P2P-трафик идёт с реального IP сервера Oracle.${NC}"
    echo "   Жалобы правообладателей на такой IP могут привести к блокировке аккаунта Oracle."
    echo "   VPN можно подключить позже: пункт 3 (VPN), затем пункт 4 (привязать qBittorrent)."
    yn "Продолжить установку без VPN?" || return

    install_qbittorrent_core || return 1

    # Без VPN входящий порт для пиров нужен: открываем его (как в qBittorrent.sh)
    local jar lp
    if jar=$(api_login); then
        lp=$(curl -sk -b "$jar" "$(web_base)/api/v2/app/preferences" | grep -oP '"listen_port":\K[0-9]+')
        rm -f "$jar"
        if [[ -n "$lp" ]]; then
            ufw_allow_tracked "${lp}/tcp"
            ufw_allow_tracked "${lp}/udp"
        fi
    fi
    echo -e "${YELLOW}Не забудьте открыть порт ${WEB_PORT}/tcp (и порт для пиров) в Security List / NSG в консоли Oracle Cloud.${NC}"
    show_address
}

# ---------------------------------------------------------------- ВЕБ-ИНТЕРФЕЙС

show_address() {
    qb_installed || { echo -e "${RED}qBittorrent не установлен.${NC}"; return; }
    detect_port
    local ip user base scheme dom
    ip=$(get_ip)
    user=$(cut -d: -f1 "$CRED_FILE" 2>/dev/null)
    base=$(web_base); scheme="${base%%://*}"
    echo -e "\n${YELLOW}=== Веб-интерфейс qBittorrent ===${NC}"
    if [[ "$scheme" == "https" ]]; then
        dom=$(cat "${QB_CERT_DIR}/domain" 2>/dev/null)
        echo "Адрес:  https://${dom:-ВАШ_ДОМЕН}:${WEB_PORT}"
        echo "        (заходите по домену из сертификата; по IP https://${ip:-IP_СЕРВЕРА}:${WEB_PORT} тоже откроется, но браузер покажет предупреждение)"
    else
        echo "Адрес:  http://${ip:-IP_СЕРВЕРА}:${WEB_PORT}"
    fi
    echo "Логин:  ${user:-неизвестен}"
    echo "Пароль: хранится в ${CRED_FILE} (смотреть: sudo cat ${CRED_FILE})"
}

change_password() {
    qb_installed || { echo -e "${RED}qBittorrent не установлен.${NC}"; return 1; }
    local user pass in
    user=$(cut -d: -f1 "$CRED_FILE" 2>/dev/null)
    read -rp "Логин [${user:-admin}]: " in
    user="${in:-${user:-admin}}"
    while true; do
        read -rp "Новый пароль (минимум 8 символов): " pass
        (( ${#pass} >= 8 )) && break
        echo -e "${RED}Слишком короткий: ${#pass} симв., нужно минимум 8. Попробуйте ещё раз.${NC}"
    done

    # Служба останавливается: qBittorrent перезаписывает конфиг при выходе, поэтому правим файл без неё
    systemctl stop "$QB_SVC" 2>/dev/null
    write_webui_credentials "$user" "$pass" || { systemctl start "$QB_SVC"; echo -e "${RED}Не удалось изменить пароль.${NC}"; return 1; }
    save_credentials "$user" "$pass"
    systemctl start "$QB_SVC"

    if wait_for_web && jar=$(api_login); then
        rm -f "$jar"
        echo -e "${GREEN}✅ Логин и пароль изменены, вход проверен.${NC}"
    else
        echo -e "${YELLOW}⚠️ Пароль записан, но автопроверка входа не прошла: попробуйте войти в браузере.${NC}"
    fi
}

# ---------------------------------------------------------------- СОЗДАНИЕ ТОРРЕНТА

ensure_trackers_file() {
    if [[ ! -s "$TRACKERS_FILE" ]]; then
        cat > "$TRACKERS_FILE" <<'TREOF'
# Трекеры для новых торрентов (по одному в строке, строки с # игнорируются).
# Файл можно редактировать: /etc/qbittorrent-trackers.txt
udp://tracker.opentrackr.org:1337/announce
udp://open.stealth.si:80/announce
udp://tracker.torrent.eu.org:451/announce
udp://exodus.desync.com:6969/announce
udp://tracker.opentrackers.org:8080/announce
TREOF
    fi
}

create_torrent() {
    qb_installed || { echo -e "${RED}qBittorrent не установлен.${NC}"; return 1; }
    systemctl is-active --quiet "$QB_SVC" || { echo -e "${RED}Служба qBittorrent не запущена.${NC}"; return 1; }
    command -v mktorrent &>/dev/null || apt_install_tracked mktorrent || return 1

    echo -e "\n${YELLOW}=== Создание торрента и раздача ===${NC}"
    echo "Укажите файл или папку на сервере. Она будет ПЕРЕМЕЩЕНА в ${DL_DIR}."
    local src
    read -e -rp "Путь к файлу или папке: " src
    src="${src/#\~/$HOME}"
    src="${src%/}"
    if [[ -z "$src" || ! -e "$src" ]]; then
        echo -e "${RED}Путь не найден.${NC}"
        return 1
    fi

    local base dest n=1
    base=$(basename "$src")
    dest="${DL_DIR}/${base}"
    while [[ -e "$dest" ]]; do
        dest="${DL_DIR}/${base}_${n}"
        n=$((n + 1))
    done
    if [[ "$dest" != "${DL_DIR}/${base}" ]]; then
        echo -e "${YELLOW}Имя занято, использую ${dest}${NC}"
    fi

    ensure_trackers_file
    local trackers=() line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        trackers+=("-a" "$line")
    done < "$TRACKERS_FILE"
    if [[ ${#trackers[@]} -eq 0 ]]; then
        echo -e "${RED}В ${TRACKERS_FILE} нет ни одного трекера.${NC}"
        return 1
    fi

    local priv=""
    yn "Сделать торрент приватным (без DHT/PEX)?" && priv="-p"

    mv -- "$src" "$dest" || { echo -e "${RED}Не удалось переместить.${NC}"; return 1; }
    chown -R "$QB_USER:$QB_USER" "$dest"
    if [[ -d "$dest" ]]; then
        find "$dest" -type d -exec chmod 755 {} +
        find "$dest" -type f -exec chmod 644 {} +
    else
        chmod 644 "$dest"
    fi

    local tfile="${TORRENT_DIR}/$(basename "$dest").torrent"
    # shellcheck disable=SC2086
    if ! mktorrent "${trackers[@]}" $priv -o "$tfile" "$dest" >/dev/null; then
        echo -e "${RED}mktorrent завершился с ошибкой.${NC}"
        return 1
    fi
    chown "$QB_USER:$QB_USER" "$tfile"
    echo -e "${GREEN}✅ Торрент создан: ${tfile}${NC}"

    if [[ -n "$priv" ]]; then
        mkdir -p /root/torrents
        cp "$tfile" /root/torrents/
        echo "   Копия приватного торрента: /root/torrents/$(basename "$tfile")"
    fi

    local jar res
    if ! jar=$(api_login); then
        echo -e "${YELLOW}⚠️ Не удалось войти в qBittorrent (проверьте пункт 7). Добавьте файл ${tfile} в интерфейсе вручную, папка данных: ${DL_DIR}.${NC}"
        return 1
    fi
    local attempt
    for attempt in 1 2 3; do
        res=$(curl -sk -b "$jar" --max-time 60 \
            -F "torrents=@${tfile}" -F "savepath=${DL_DIR}" -F "skip_checking=true" \
            "$(web_base)/api/v2/torrents/add")
        [[ "$res" == "Ok." ]] && break
        sleep 3
    done
    rm -f "$jar"
    if [[ "$res" == "Ok." ]]; then
        echo -e "${GREEN}✅ Торрент добавлен в qBittorrent, раздача началась.${NC}"
        echo "   Файл .torrent для публикации: ${tfile} (скачать: scp)"
    else
        echo -e "${RED}qBittorrent не принял торрент (ответ: ${res:-пусто}).${NC}"
    fi
}

# ---------------------------------------------------------------- ПРОВЕРКИ

check_status() {
    echo -e "\n${YELLOW}=== Статус qBittorrent ===${NC}"
    if ! qb_installed; then
        echo -e "${RED}qBittorrent не установлен.${NC}"
        return
    fi
    detect_port
    echo "Служба:       $(systemctl is-active "$QB_SVC") (автозапуск: $(systemctl is-enabled "$QB_SVC" 2>/dev/null))"
    echo "Веб-порт:     ${WEB_PORT}  $(ss -ltn 2>/dev/null | grep -q ":${WEB_PORT} " && echo '(слушает)' || echo '(НЕ слушает)')"
    local qb_base
    qb_base=$(web_base)
    echo "Веб локально: $(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${qb_base}/") (200 - ок), протокол: ${qb_base%%://*}"
    if [[ "$(web_scheme)" == "https" ]]; then
        echo "HTTPS:        включён (сертификат: ${QB_CERT_DIR})"
    else
        echo "HTTPS:        выключен (включается скриптом ssl.sh)"
    fi
    if [[ -f "$DROPIN" ]]; then
        echo "Привязка к VPN: да (${VPN_LABEL:-$CONF_NAME}, интерфейс ${CONF_NAME})"
    else
        echo -e "Привязка к VPN: ${YELLOW}нет${NC}"
    fi

    if vpn_configured; then
        echo -e "\n--- WireGuard ${CONF_NAME} ---"
        if wg show "$CONF_NAME" &>/dev/null; then
            wg show "$CONF_NAME" | head -n 12
            local main_ip vpn_ip
            main_ip=$(get_ip)
            vpn_ip=$(get_ip runuser -u "$QB_USER" --)
            echo -e "Прямой IP сервера:       ${GREEN}${main_ip:-не доступен}${NC}"
            echo -e "IP qBittorrent (VPN):    ${GREEN}${vpn_ip:-не доступен}${NC}"
        else
            echo -e "${RED}Интерфейс ${CONF_NAME} не активен.${NC}"
        fi
    fi
}

check_safety() {
    echo -e "\n${YELLOW}=== Комплексная проверка безопасности qBittorrent ===${NC}"

    if ! qb_installed; then
        echo -e "${RED}qBittorrent не установлен.${NC}"
        return
    fi
    if ! vpn_configured || [[ ! -f "$DROPIN" ]]; then
        echo -e "${YELLOW}qBittorrent не привязан к VPN: его трафик идёт с реального IP сервера.${NC}"
        echo "Подключить VPN: пункт 3, затем пункт 4."
        return
    fi

    detect_port
    local errors=0 uid
    uid=$(id -u "$QB_USER" 2>/dev/null)

    # 1. WireGuard и рукопожатие
    if wg show "$CONF_NAME" &>/dev/null; then
        echo -e "${GREEN}[OK] WireGuard интерфейс ${CONF_NAME} (${VPN_LABEL:-VPN}) активен.${NC}"
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

    # 2. Служба работает от нужного пользователя
    if systemctl is-active --quiet "$QB_SVC"; then
        local pid owner
        pid=$(systemctl show -p MainPID --value "$QB_SVC")
        owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$owner" == "$QB_USER" ]]; then
            echo -e "${GREEN}[OK] qBittorrent запущен от пользователя ${QB_USER}.${NC}"
        else
            echo -e "${RED}[FAIL] qBittorrent запущен от '${owner:-?}', а не от ${QB_USER}!${NC}"
            errors=$((errors + 1))
        fi
    else
        echo -e "${RED}[FAIL] Служба qBittorrent не запущена.${NC}"
        errors=$((errors + 1))
    fi

    # 3. Правила маршрутизации и kill-switch
    if [[ -n "$uid" ]] && ip -4 rule show | grep -q "uidrange ${uid}-${uid} lookup ${TABLE}"; then
        echo -e "${GREEN}[OK] Трафик пользователя ${QB_USER} направлен в таблицу ${TABLE} (VPN).${NC}"
    else
        echo -e "${RED}[FAIL] Нет правила маршрутизации пользователя ${QB_USER} через VPN!${NC}"
        errors=$((errors + 1))
    fi

    if [[ -n "$uid" ]] && ip -4 rule show | grep -q "uidrange ${uid}-${uid} prohibit"; then
        echo -e "${GREEN}[OK] Kill-switch активен (мимо VPN у qBittorrent нет сети).${NC}"
    else
        echo -e "${RED}[FAIL] Kill-switch не активен!${NC}"
        errors=$((errors + 1))
    fi

    if ip -4 rule show | grep -q "sport ${WEB_PORT} lookup main"; then
        echo -e "${GREEN}[OK] Ответы веб-интерфейса (порт ${WEB_PORT}) идут напрямую.${NC}"
    else
        echo -e "${RED}[FAIL] Нет правила для ответов веб-интерфейса (порт ${WEB_PORT})!${NC}"
        errors=$((errors + 1))
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
    vpn_ip=$(get_ip runuser -u "$QB_USER" --)
    if [[ -n "$main_ip" && -n "$vpn_ip" && "$main_ip" != "$vpn_ip" ]]; then
        echo -e "${GREEN}[OK] Разделение IP работает корректно:${NC}"
        echo -e "     • Основной IP сервера (SSH): $main_ip"
        echo -e "     • IP qBittorrent (VPN):      $vpn_ip"
    else
        echo -e "${RED}[FAIL] Ошибка разделения IP! (сервер: ${main_ip:-нет}, qBittorrent: ${vpn_ip:-нет})${NC}"
        errors=$((errors + 1))
    fi

    # 5. Веб-интерфейс отвечает локально
    local code web
    web=$(web_base)
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${web}/")
    if [[ "$code" == "200" ]]; then
        echo -e "${GREEN}[OK] Веб-интерфейс qBittorrent отвечает (${web%%://*}, порт ${WEB_PORT}).${NC}"
    else
        echo -e "${RED}[FAIL] Веб-интерфейс qBittorrent не отвечает (код: ${code:-нет ответа}).${NC}"
        errors=$((errors + 1))
    fi

    echo -e "\n--------------------------------------------------"
    if [[ $errors -eq 0 ]]; then
        echo -e "${GREEN}РЕЗУЛЬТАТ: Настройка БЕЗОПАСНА.${NC}"
        echo -e "--------------------------------------------------"
    else
        echo -e "${RED}РЕЗУЛЬТАТ: Обнаружено проблем: $errors.${NC}"
        echo -e "--------------------------------------------------"
        if yn "Запустить автоматическое исправление?"; then
            auto_fix
            check_safety
        fi
    fi
}

# ---------------------------------------------------------------- ИСПРАВЛЕНИЕ И ОТКАТ

auto_fix() {
    echo -e "\n${YELLOW}🛠️ [АВТО-ИСПРАВЛЕНИЕ] Пересборка правил маршрутизации и служб...${NC}"
    if ! vpn_configured; then
        echo -e "${RED}⚠️ VPN не настроен (нет конфига ${CONF}). Запустите пункт 3.${NC}"
        return
    fi
    check_kernel_support || return
    ensure_user
    install_routing_helpers
    reapply_vpn
    fix_qbit_binding
    echo -e "${GREEN}✅ Восстановление завершено!${NC}\n"
}

# Убирает привязку к VPN: kill-switch, правила, drop-in, скрипты.
# Общий туннель остаётся работать (им может пользоваться TorrServer), свой собственный выключается.
remove_routing_parts() {
    local p
    systemctl stop "$QB_SVC" 2>/dev/null
    clear_qb_interface   # без VPN привязка к интерфейсу туннеля оставила бы qBittorrent без сети
    if [[ -n "$VPN_NAME" ]]; then
        if wg_shared; then
            [[ -x "$VPN_SCRIPT" ]] && "$VPN_SCRIPT" down "$CONF_NAME" 2>/dev/null
            [[ -f "$CONF" ]] && sed -i '\#qbittorrent-vpn\.sh#d' "$CONF"
        else
            systemctl stop "$WG_SVC" 2>/dev/null
            systemctl disable "$WG_SVC" &>/dev/null
        fi
    fi
    systemctl disable --now qbittorrent-killswitch 2>/dev/null
    rm -f "$KS_UNIT" "$DROPIN" "$KS_SCRIPT" "$VPN_SCRIPT"
    rmdir "$DROPIN_DIR" 2>/dev/null

    # Страховка: убираем только свои правила (91/101/111) и свою таблицу
    for p in "$PRIO_SPORT" "$PRIO_ROUTE" "$PRIO_KILL"; do
        while ip -4 rule del priority "$p" 2>/dev/null; do :; done
        while ip -6 rule del priority "$p" 2>/dev/null; do :; done
    done
    ip route flush table "$TABLE" 2>/dev/null

    systemctl daemon-reload
    systemctl reset-failed qbittorrent-killswitch 2>/dev/null
}

restore_conf_backup() {
    wg_shared && return 0
    local last_bak
    last_bak=$(ls -1t "${CONF}".bak.* 2>/dev/null | head -n 1)
    if [[ -n "$last_bak" ]]; then
        cp -a "$last_bak" "$CONF" && echo -e "${GREEN}Конфиг WireGuard восстановлен из $last_bak${NC}"
    else
        echo -e "${YELLOW}Бэкап конфига не найден, конфиг WireGuard не тронут.${NC}"
    fi
}

revert_routing() {
    echo -e "\n${YELLOW}↩️ Откат: qBittorrent снова ходит через обычный интерфейс (без VPN)${NC}"
    if ! yn "Точно откатить? Трафик qBittorrent пойдёт с IP сервера Oracle."; then
        return
    fi
    remove_routing_parts
    restore_conf_backup
    systemctl start "$QB_SVC" 2>/dev/null
    echo -e "${GREEN}✅ Откат выполнен.${NC}"
}

# ---------------------------------------------------------------- УДАЛЕНИЕ
# Удаляется только то, что создал этот скрипт (учёт ведётся в ${STATE_FILE}):
# чужие пакеты, чужие правила UFW, чужие учётные записи и общий WireGuard-конфиг не трогаются.

routing_present() { [[ -e "$KS_UNIT" || -e "$DROPIN" || -e "$KS_SCRIPT" || -e "$VPN_SCRIPT" ]]; }
user_present()    { [[ -n "$USER_CREATED" ]] && id -u "$QB_USER" &>/dev/null; }
home_present()    { [[ -d "$QB_HOME" ]]; }
vpn_present()     { [[ -n "$VPN_NAME" ]] && { [[ -f "$CONF" ]] || compgen -G "${CONF}.bak.*" >/dev/null; }; }

ufw_rules_present() {
    local r out=""
    command -v ufw &>/dev/null || { echo ""; return; }
    for r in $UFW_RULES; do
        ufw show added 2>/dev/null | grep -qxF "ufw allow ${r}" && out="${out:+$out }$r"
    done
    echo "$out"
}

pkgs_present() {
    local pkg out=""
    for pkg in $PKGS_ADDED; do pkg_installed "$pkg" && out="${out:+$out }$pkg"; done
    echo "$out"
}

# Конфиг WireGuard: общий не трогаем (только наши строки, они уже убраны), свой удаляем
remove_vpn_parts() {
    local other=0 marker=0
    grep -q 'torrserver-vpn\.sh' "$CONF" 2>/dev/null && other=1
    grep -q 'vpn-scripts-managed' "$CONF" 2>/dev/null && marker=1

    if (( other )); then
        # Конфигом пользуется TorrServer: оставляем. Если создали его мы, ставим метку,
        # чтобы TorrServer смог удалить конфиг, когда будет удаляться последним.
        [[ "$VPN_SHARED" != "1" && $marker -eq 0 && -f "$CONF" ]] && sed -i '1i # vpn-scripts-managed' "$CONF"
        echo -e "${YELLOW}Туннель ${CONF_NAME} используется TorrServer: конфиг и туннель оставляю, убираю только свои строки.${NC}"
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
    rm -f "${CONF}".qb-bak.* 2>/dev/null
    VPN_LABEL=""; VPN_NAME=""; VPN_SHARED=""
    apply_vpn_vars
}

remove_qbit_service() {
    systemctl stop "$QB_SVC" 2>/dev/null
    systemctl disable "$QB_SVC" &>/dev/null
    rm -f "$QB_UNIT"
    rm -rf "$DROPIN_DIR"
    systemctl daemon-reload
    systemctl reset-failed "$QB_SVC" 2>/dev/null
    rm -f "$CRED_FILE"
    rm -rf "$QB_CERT_DIR"   # копия сертификата для HTTPS (её создаёт ssl.sh)
}

remove_user_and_home() {
    pkill -u "$QB_USER" 2>/dev/null
    userdel -r "$QB_USER" 2>/dev/null
    getent group "$QB_USER" >/dev/null 2>&1 && groupdel "$QB_USER" 2>/dev/null
    # Если пользователя создали не мы, домашнюю папку не трогаем
    USER_CREATED=""
}

uninstall_menu() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ] Что удалить?${NC}"

    local has_r=0 has_v=0 has_s=0 has_h=0 has_u=0 ufw_now pkgs_now
    routing_present && has_r=1
    vpn_present     && has_v=1
    qb_installed    && has_s=1
    user_present    && has_u=1
    # Домашняя папка имеет смысл как отдельный пункт, только если пользователя создали мы
    (( has_u )) && home_present && has_h=1
    ufw_now=$(ufw_rules_present)
    pkgs_now=$(pkgs_present)
    if [[ -n "$pkgs_now" && -f "$TS_STATE" ]]; then
        # TorrServer (torrserver_full.sh) использует те же системные пакеты: их не трогаем
        local kept="" removable="" pk
        for pk in $pkgs_now; do
            case " wireguard wireguard-tools curl ufw jq iproute2 python3 " in
                *" $pk "*) kept="${kept:+$kept }$pk" ;;
                *) removable="${removable:+$removable }$pk" ;;
            esac
        done
        if [[ -n "$kept" ]]; then
            echo -e "${YELLOW}На сервере установлен TorrServer (torrserver_full.sh): общие пакеты (${kept}) не удаляю, чтобы не сломать его.${NC}"
        fi
        pkgs_now="$removable"
    fi

    if (( has_r + has_v + has_s + has_u == 0 )) && [[ -z "$ufw_now" && -z "$pkgs_now" ]]; then
        echo -e "${GREEN}Скрипт ничего не нашёл: удалять нечего.${NC}"
        rm -f "$STATE_FILE"
        return
    fi

    echo "Найдено то, что создал скрипт:"
    (( has_r )) && echo "  • привязка qBittorrent к VPN (kill-switch, правила маршрутизации, drop-in)"
    (( has_v )) && { wg_shared \
        && echo "  • подключение к общему WireGuard-конфигу ${CONF_NAME} (сам конфиг останется)" \
        || echo "  • WireGuard: ${VPN_LABEL:-$VPN_NAME} (${CONF} и резервные копии)"; }
    (( has_s )) && echo "  • служба qBittorrent (пакет остаётся до удаления пакетов)"
    (( has_u )) && echo "  • пользователь ${QB_USER} и его папка ${QB_HOME} (скачанные файлы, .torrent, настройки)"
    [[ -n "$ufw_now" ]] && echo "  • правила UFW: ${ufw_now}"
    [[ -n "$pkgs_now" ]] && echo "  • пакеты, поставленные скриптом: ${pkgs_now}"
    echo
    echo "1. Всё: вернуть систему к состоянию до установки"
    echo "2. Только VPN (привязка и подключение); qBittorrent останется и будет работать напрямую"
    echo "3. Только qBittorrent (служба, пользователь, данные, правила UFW, пакеты); VPN будет отвязан"
    echo "4. Выбрать по компонентам"
    echo "0. Отмена"
    local sc
    read -rp "Выберите [0-4]: " sc

    local d_r=0 d_v=0 d_s=0 d_u=0 d_f=0 d_p=0
    case "$sc" in
        1) d_r=$has_r; d_v=$has_v; d_s=$has_s; d_u=$has_u; [[ -n "$ufw_now" ]] && d_f=1; [[ -n "$pkgs_now" ]] && d_p=1 ;;
        2) d_r=$has_r; d_v=$has_v ;;
        3) d_r=$has_r; d_s=$has_s; d_u=$has_u; [[ -n "$ufw_now" ]] && d_f=1
           [[ " $pkgs_now " == *" qbittorrent-nox "* || " $pkgs_now " == *" mktorrent "* ]] && d_p=1 ;;
        4)
            (( has_r )) && yn "Убрать привязку к VPN (kill-switch, правила)?" && d_r=1
            (( has_v )) && yn "Убрать VPN (WireGuard-конфиг или подключение к общему)?" && d_v=1
            (( has_s )) && yn "Удалить службу qBittorrent?" && d_s=1
            (( has_u )) && yn "Удалить пользователя ${QB_USER} и ВСЕ его файлы (${QB_HOME}), включая скачанное?" && d_u=1
            [[ -n "$ufw_now" ]] && yn "Удалить правила UFW (${ufw_now})?" && d_f=1
            [[ -n "$pkgs_now" ]] && yn "Удалить пакеты (${pkgs_now})?" && d_p=1
            ;;
        *) echo "Отменено."; return ;;
    esac

    # Зависимости: чтобы ничего не осталось "висеть" в сломанном состоянии
    local extra=()
    if (( d_v && has_r && !d_r )); then d_r=1; extra+=("привязка к VPN (нужна для отключения VPN)"); fi
    if (( d_s && has_r && !d_r )); then d_r=1; extra+=("привязка к VPN (встроена в службу)"); fi
    if (( d_u && has_s && !d_s )); then d_s=1; extra+=("служба qBittorrent (работает от ${QB_USER})"); fi
    if (( d_u && has_r && !d_r )); then d_r=1; extra+=("привязка к VPN (правила завязаны на пользователя ${QB_USER})"); fi
    if (( d_p )) && [[ " $pkgs_now " == *" qbittorrent-nox "* ]] && (( has_s && !d_s )); then
        d_s=1; extra+=("служба qBittorrent (пакет qbittorrent-nox будет удалён)")
        (( has_r && !d_r )) && { d_r=1; extra+=("привязка к VPN"); }
    fi
    if (( d_p )) && [[ " $pkgs_now " == *" wireguard "* || " $pkgs_now " == *" wireguard-tools "* ]]; then
        if (( has_v && !d_v )); then d_v=1; extra+=("VPN (пакеты wireguard будут удалены)"); fi
        if (( has_r && !d_r )); then d_r=1; extra+=("привязка к VPN (пакеты wireguard будут удалены)"); fi
    fi

    if (( d_r + d_v + d_s + d_u + d_f + d_p == 0 )); then echo "Ничего не выбрано."; return; fi

    echo -e "\n${YELLOW}Будет выполнено:${NC}"
    (( d_r )) && echo "  ✗ привязка к VPN: kill-switch, правила, drop-in, скрипты"
    (( d_v )) && { wg_shared && echo "  ✗ подключение к общему туннелю (сам конфиг и туннель остаются)" || echo "  ✗ WireGuard: остановка туннеля, удаление ${CONF}"; }
    (( d_r && !d_v && has_v )) && ! wg_shared && echo "  ↩ конфиг WireGuard вернётся к исходному виду, туннель будет выключен"
    (( d_s )) && echo "  ✗ служба qBittorrent"
    (( d_u )) && echo "  ✗ пользователь ${QB_USER} и папка ${QB_HOME} (скачанное, .torrent, настройки)"
    (( d_f )) && echo "  ✗ правила UFW: ${ufw_now}"
    (( d_p )) && echo "  ✗ пакеты: ${pkgs_now}"
    if (( d_r && !d_s && has_s )); then
        echo -e "  ${YELLOW}⚠ qBittorrent продолжит работать, но с обычного IP сервера Oracle (без VPN)${NC}"
    fi
    if (( ${#extra[@]} )); then
        echo -e "${YELLOW}Дополнительно из-за зависимостей:${NC}"
        printf '  + %s\n' "${extra[@]}"
    fi
    if (( d_u )) && [[ -d "$DL_DIR" ]]; then
        echo -e "\n${YELLOW}В ${DL_DIR} лежат скачанные и раздаваемые файлы ($(du -sh "$DL_DIR" 2>/dev/null | cut -f1)). Они будут удалены.${NC}"
    fi
    echo
    yn "Подтвердите удаление" || { echo "Отменено."; return; }

    local was_shared=0
    wg_shared && was_shared=1

    # Порядок важен: привязка, VPN, служба, UFW, пользователь, пакеты
    if (( d_r )); then echo "→ убираю привязку к VPN..."; remove_routing_parts; fi
    if (( d_v )); then
        echo "→ убираю VPN..."; remove_vpn_parts
    elif (( d_r && has_v )); then
        restore_conf_backup
    fi
    if (( d_s )); then
        echo "→ удаляю службу qBittorrent..."; remove_qbit_service
    elif (( d_r && has_s )); then
        echo "→ запускаю qBittorrent без VPN..."; systemctl start "$QB_SVC" 2>/dev/null
    fi
    if (( d_f )); then
        echo "→ удаляю правила UFW..."
        local r
        for r in $ufw_now; do
            ufw --force delete allow "$r" >/dev/null 2>&1
        done
    fi
    if (( d_u )); then echo "→ удаляю пользователя ${QB_USER} и его папку..."; remove_user_and_home; fi
    if (( d_p )); then
        echo "→ удаляю пакеты..."
        # shellcheck disable=SC2086
        apt-get purge -y $pkgs_now
        echo -e "${YELLOW}autoremove может затронуть и пакеты, не связанные со скриптом. Список:${NC}"
        apt-get -s autoremove --purge 2>/dev/null | grep '^Remove' | sed 's/^Remove /  - /' | head -n 30
        yn "Выполнить autoremove?" && apt-get autoremove --purge -y
    fi

    # Приводим учёт в порядок
    PKGS_ADDED=$(pkgs_present)
    pkg_installed ufw || UFW_RULES=""
    UFW_RULES=$(ufw_rules_present)
    id -u "$QB_USER" &>/dev/null || USER_CREATED=""

    if [[ -z "$VPN_NAME" ]] && ! qb_installed && ! routing_present \
        && [[ -z "$PKGS_ADDED" && -z "$UFW_RULES" && -z "$USER_CREATED" ]]; then
        rm -f "$STATE_FILE"
        echo -e "\n${GREEN}✅ Всё удалено. Система возвращена к состоянию до установки.${NC}"
    else
        save_state
        echo -e "\n${GREEN}✅ Выбранное удалено. Оставшееся можно удалить повторно через этот же пункт.${NC}"
    fi

    echo -e "${YELLOW}Не забудьте вручную:${NC}"
    (( d_f || d_s )) && echo "  • закрыть порт ${WEB_PORT} в Oracle Cloud (Security List / NSG), если открывали"
    (( d_v && !was_shared )) && echo "  • отозвать (удалить) ключ/устройство в кабинете VPN-провайдера"
    [[ -d /root/torrents ]] && echo "  • копии приватных торрентов в /root/torrents скрипт не удаляет"
}

# ---------------------------------------------------------------- ПЕРЕХОД В ssl.sh

# Скачивает ssl.sh (выпуск и установка сертификата) и запускает его. После выхода из него вы вернётесь в это меню.
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
    echo -e "\n${GREEN}Вы вернулись в меню qBittorrent.${NC} Адрес веб-интерфейса и протокол: пункт 6; статус: пункт 8."
}

# ---------------------------------------------------------------- МЕНЮ

while true; do
    if vpn_configured; then
        vpn_info="VPN: ${VPN_LABEL:-$CONF_NAME} (${CONF_NAME})$(wg_shared && echo ', общий')"
    else
        vpn_info="VPN: не настроен"
    fi
    echo -e "\n${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}   Управление qBittorrent + WireGuard VPN (Oracle)   ${NC}"
    echo -e "${YELLOW}   ${vpn_info}   ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo "1.  Полная установка (VPN + Kill-Switch + qBittorrent)"
    echo "2.  Установить только qBittorrent (без VPN)"
    echo "3.  Подключить / настроить VPN (общий туннель или свой конфиг)"
    echo "4.  Привязать qBittorrent к VPN (kill-switch)"
    echo "5.  Создать торрент из файла/папки и начать раздачу"
    echo "6.  Показать адрес и логин веб-интерфейса"
    echo "7.  Сменить логин/пароль веб-интерфейса"
    echo "8.  Статус (qBittorrent и VPN)"
    echo "9.  ПРОВЕРКА БЕЗОПАСНОСТИ (Маршруты, IP, Привязка)"
    echo "10. Запустить АВТО-ИСПРАВЛЕНИЕ вручную"
    echo "11. Откат (убрать привязку к VPN)"
    echo "12. Удаление (вернуть систему к состоянию до установки)"
    echo "13. Сертификат HTTPS: перейти в скрипт ssl.sh (выпуск и установка)"
    echo "0.  Выход"
    echo "=================================================="
    read -rp "Выберите действие [0-13]: " choice

    case $choice in
        1) setup_full && check_safety ;;
        2) setup_qbit_only ;;
        3) setup_vpn ;;
        4) fix_qbit_binding ;;
        5) create_torrent ;;
        6) show_address ;;
        7) change_password ;;
        8) check_status ;;
        9) check_safety ;;
        10) auto_fix ;;
        11) revert_routing ;;
        12) uninstall_menu ;;
        13) run_ssl_script ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
