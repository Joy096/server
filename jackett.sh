#!/bin/bash
# =====================================================================
#  Jackett: установка, настройка и удаление (Ubuntu, x86_64 и ARM64)
#  Запуск:  sudo bash jackett.sh
#
#  Что делает:
#    - ставит последнюю версию Jackett в /opt/Jackett и службу jackett.service;
#    - служба работает НЕ от root, а от обычного пользователя (ubuntu), конфиг в ~/.config/Jackett;
#    - включает External access и Allow CORS, задаёт API key (свой или случайный) и пароль панели;
#    - открывает порт 9117 в UFW;
#    - HTTPS включает скрипт ssl.sh (пункт 1 или 2): Jackett сам HTTPS не умеет, поэтому ssl.sh ставит перед ним
#      nginx (порт 9118) и закрывает обычный HTTP снаружи; этот скрипт такой режим понимает и не ломает;
#      пункт 8 меню скачивает ssl.sh и запускает его, после выхода из него вы возвращаетесь сюда;
#    - ставит FlareSolverr или Byparr (в Docker, только на localhost) для трекеров с защитой Cloudflare
#      и подключает его к Jackett (лечит ошибку "Challenge detected but FlareSolverr is not configured");
#      при нехватке памяти предлагает создать swap-файл;
#    - сохраняет и восстанавливает папку Indexers;
#    - удаляет всё и возвращает систему к состоянию до установки.
#
#  Логины и пароли трекеров в скрипте НЕ хранятся: их вводят в веб-интерфейсе Jackett
#  (или они приезжают вместе с папкой Indexers при восстановлении).
# =====================================================================

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root: sudo bash $0${NC}"
    exit 1
fi

APP_DIR="/opt/Jackett"
SVC="jackett"
UNIT="/etc/systemd/system/jackett.service"
STATE_FILE="/etc/jackett-setup.state"
DEFAULT_PORT=9117
SSL_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh"   # пункт 8 меню

# --- Учёт того, что создал скрипт (нужен для полного удаления) ---
JK_USER=""          # пользователь, от которого работает Jackett
USER_CREATED=""     # 1, если пользователя создал скрипт
FS_CONTAINER=""     # 1, если контейнер FlareSolverr создал скрипт
FS_IMAGE_NEW=""     # 1, если образ FlareSolverr скачал скрипт (его не было в Docker до этого)
PKGS_ADDED=""       # пакеты, которых не было до установки
UFW_RULE=""         # правило UFW, добавленное скриптом (например "allow 9117/tcp")
FS_ENGINE=""        # flaresolverr | byparr (пусто = flaresolverr)
SWAP_CREATED=""     # путь к swap-файлу, который создал скрипт (пусто, если swap создан не им)

load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"; }
save_state() {
    {
        echo "JK_USER=$(printf '%q' "$JK_USER")"
        echo "USER_CREATED=$(printf '%q' "$USER_CREATED")"
        echo "PKGS_ADDED=$(printf '%q' "$PKGS_ADDED")"
        echo "UFW_RULE=$(printf '%q' "$UFW_RULE")"
        echo "FS_CONTAINER=$(printf '%q' "$FS_CONTAINER")"
        echo "FS_IMAGE_NEW=$(printf '%q' "$FS_IMAGE_NEW")"
        echo "SWAP_CREATED=$(printf '%q' "$SWAP_CREATED")"
        echo "FS_ENGINE=$(printf '%q' "$FS_ENGINE")"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}
load_state

# ---------------------------------------------------------------- ВСПОМОГАТЕЛЬНОЕ

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

apt_install_tracked() {
    local pkg newly=()
    for pkg in "$@"; do pkg_installed "$pkg" || newly+=("$pkg"); done
    apt-get update && apt-get install -y "$@" || return 1
    for pkg in "${newly[@]}"; do
        if pkg_installed "$pkg" && [[ " $PKGS_ADDED " != *" $pkg "* ]]; then
            PKGS_ADDED="${PKGS_ADDED:+$PKGS_ADDED }$pkg"
        fi
    done
    save_state
}

yn() { local a; read -rp "$1 (y/n): " a; [[ "$a" == "y" || "$a" == "Y" ]]; }

installed() { [[ -d "$APP_DIR" || -f "$UNIT" ]]; }

user_home() { getent passwd "$1" | cut -d: -f6; }

cfg_dir() { echo "$(user_home "$JK_USER")/.config/Jackett"; }
cfg_file() { echo "$(cfg_dir)/ServerConfig.json"; }

get_port() {
    local p=""
    [[ -f "$(cfg_file)" ]] && p=$(jq -r '.Port // empty' "$(cfg_file)" 2>/dev/null)
    echo "${p:-$DEFAULT_PORT}"
}

# HTTPS для Jackett включает ssl.sh: Jackett сам HTTPS не умеет, поэтому ssl.sh ставит перед ним nginx
# (HTTPS на порту 9118 -> Jackett на 127.0.0.1:9117) и закрывает обычный HTTP снаружи.
TLS_DIR="/etc/jackett-cert"
TLS_UNIT="/etc/systemd/system/jackett-tls.service"
https_active() { [[ -f "${TLS_DIR}/domain" && -f "$TLS_UNIT" ]]; }
https_url() {
    local tp
    tp=$(awk '$1=="listen"{print $2; exit}' "${TLS_DIR}/nginx.conf" 2>/dev/null)
    [[ -n "$tp" ]] || tp=$(awk '$1=="accept"{print $3; exit}' "${TLS_DIR}/stunnel.conf" 2>/dev/null)   # прежняя версия, до nginx
    echo "https://$(cat "${TLS_DIR}/domain" 2>/dev/null):${tp:-9118}"
}

get_ip() {
    local ip svc
    for svc in https://icanhazip.com https://api.ipify.org https://ifconfig.me; do
        ip=$(curl -4 -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
    done
    echo "IP_СЕРВЕРА"
}

# Правка ServerConfig.json: передаются аргументы jq (фильтр и --arg ...)
edit_config() {
    local cfg tmp
    cfg=$(cfg_file)
    tmp=$(mktemp) || return 1
    if jq "$@" "$cfg" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        cat "$tmp" > "$cfg"      # cat сохраняет владельца и права файла
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    echo -e "${RED}Не удалось изменить ${cfg} (файл повреждён?).${NC}"
    return 1
}

wait_for_config() {
    local i
    echo -n "Жду первого запуска Jackett (создаётся конфиг)"
    for i in $(seq 1 45); do
        [[ -s "$(cfg_file)" ]] && { echo; return 0; }
        echo -n "."; sleep 1
    done
    echo
    return 1
}

gen_api_key() { tr -dc 'a-z0-9' < /dev/urandom | head -c 32; }

# ---------------------------------------------------------------- ПОЛЬЗОВАТЕЛЬ

choose_user() {
    # Уже выбранный при прошлой установке пользователь
    if [[ -n "$JK_USER" ]] && id -u "$JK_USER" &>/dev/null; then return 0; fi

    local candidate=""
    if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
        candidate="$SUDO_USER"
    elif id -u ubuntu &>/dev/null; then
        candidate="ubuntu"
    fi

    # Без вопросов: ubuntu (или тот, кто вызвал sudo); если таких нет, создаётся пользователь jackett
    JK_USER="${candidate:-jackett}"
    echo "Служба Jackett будет работать от пользователя: ${JK_USER}"

    if ! id -u "$JK_USER" &>/dev/null; then
        echo "Пользователя ${JK_USER} нет, создаю (с домашней папкой, без пароля)."
        useradd -m -s /bin/bash "$JK_USER" || { JK_USER=""; return 1; }
        USER_CREATED=1
    fi
    save_state
}

# ---------------------------------------------------------------- UFW

open_port() {
    local port="$1" rule="allow ${port}/tcp"
    command -v ufw &>/dev/null || { echo -e "${YELLOW}ufw не установлен, порт не открываю.${NC}"; return; }
    # Запоминаем правило, только если его раньше не было
    if ! ufw show added 2>/dev/null | grep -qxF "ufw ${rule}"; then
        UFW_RULE="$rule"
        save_state
    fi
    ufw allow "${port}/tcp"
}

# ---------------------------------------------------------------- УСТАНОВКА

latest_tag() {
    local url
    url=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/Jackett/Jackett/releases/latest 2>/dev/null)
    echo "${url##*/}"
}

install_jackett() {
    echo -e "\n${YELLOW}📦 [УСТАНОВКА JACKETT]${NC}"

    local arch file
    case "$(uname -m)" in
        x86_64)  file="Jackett.Binaries.LinuxAMDx64.tar.gz" ;;
        aarch64) file="Jackett.Binaries.LinuxARM64.tar.gz" ;;
        *) echo -e "${RED}Архитектура $(uname -m) не поддерживается этим скриптом.${NC}"; return 1 ;;
    esac

    if installed; then
        echo -e "${YELLOW}Jackett уже установлен.${NC} Переустановка обновит программу, настройки и Indexers сохранятся."
        yn "Продолжить?" || return
    fi

    choose_user || return 1
    apt_install_tracked curl jq tar ufw || return 1

    local tag
    tag=$(latest_tag)
    if [[ -z "$tag" || "$tag" == "latest" ]]; then
        echo -e "${RED}Не удалось узнать последнюю версию на GitHub.${NC}"
        return 1
    fi
    echo "Последняя версия: ${tag}"

    local tmp
    tmp=$(mktemp -d) || return 1
    echo "Скачиваю ${file}..."
    if ! curl -fL --retry 3 -o "${tmp}/${file}" "https://github.com/Jackett/Jackett/releases/download/${tag}/${file}"; then
        echo -e "${RED}Не удалось скачать архив.${NC}"; rm -rf "$tmp"; return 1
    fi
    if ! tar -tzf "${tmp}/${file}" &>/dev/null; then
        echo -e "${RED}Архив повреждён.${NC}"; rm -rf "$tmp"; return 1
    fi

    systemctl stop "$SVC" 2>/dev/null
    rm -rf "$APP_DIR"
    tar -xzf "${tmp}/${file}" -C /opt || { echo -e "${RED}Не удалось распаковать.${NC}"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"

    if [[ ! -x "${APP_DIR}/jackett" ]]; then
        echo -e "${RED}После распаковки нет ${APP_DIR}/jackett.${NC}"
        return 1
    fi

    # Установщик Jackett берёт пользователя службы из владельца файлов
    chown -R "${JK_USER}:${JK_USER}" "$APP_DIR"
    ( cd "$APP_DIR" && ./install_service_systemd.sh ) || { echo -e "${RED}install_service_systemd.sh завершился с ошибкой.${NC}"; return 1; }

    if ! wait_for_config; then
        echo -e "${RED}Конфиг не появился. Смотрите: journalctl -u ${SVC} -n 50${NC}"
        return 1
    fi

    configure_basic || echo -e "${YELLOW}Настройку можно повторить позже: пункт 2 меню.${NC}"
    if https_active; then
        echo -e "${YELLOW}HTTPS уже включён (ssl.sh): обычный порт Jackett снаружи закрыт, в UFW его не открываю.${NC}"
    else
        open_port "$(get_port)"
    fi
    install_flaresolverr auto || echo -e "${YELLOW}FlareSolverr не установлен. Повторить можно позже: пункт 5 меню.${NC}"
    show_summary
}

# ---------------------------------------------------------------- НАСТРОЙКА

# Хеш пароля панели Jackett: SHA-512 от (пароль + API key) в кодировке UTF-16LE, hex в нижнем регистре.
# Поэтому при смене API key пароль нужно задавать заново (скрипт всегда спрашивает оба).
hash_admin_password() {
    printf '%s' "${1}${2}" | iconv -f UTF-8 -t UTF-16LE | sha512sum | cut -d' ' -f1
}

ask_api_key() {
    local in
    while true; do
        read -rp "API key: свой (8-64 символа a-z, A-Z, 0-9) или Enter, чтобы сгенерировать: " in
        if [[ -z "$in" ]]; then
            API_KEY=$(gen_api_key)
            return
        elif (( ${#in} < 8 )); then
            echo -e "${RED}Слишком короткий: ${#in} симв., нужно минимум 8. Попробуйте ещё раз.${NC}"
        elif (( ${#in} > 64 )); then
            echo -e "${RED}Слишком длинный: ${#in} симв., максимум 64. Попробуйте ещё раз.${NC}"
        elif [[ ! "$in" =~ ^[A-Za-z0-9]+$ ]]; then
            echo -e "${RED}Допустимы только латинские буквы и цифры (без пробелов и символов). Попробуйте ещё раз.${NC}"
        else
            API_KEY="$in"
            return
        fi
    done
}

ask_admin_password() {
    local p1
    while true; do
        read -rp "Пароль для входа в панель Jackett (минимум 8 символов): " p1
        if (( ${#p1} < 8 )); then
            echo -e "${RED}Слишком короткий: ${#p1} симв., нужно минимум 8. Попробуйте ещё раз.${NC}"
            continue
        fi
        ADMIN_PASSWORD="$p1"
        return
    done
}

# Проверка: после установки пароля без входа панель закрыта, а с паролем открывается.
verify_login() {
    local pw="$1" port jar code_anon code_auth i
    port=$(get_port)
    jar=$(mktemp)
    for i in $(seq 1 30); do
        curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${port}/UI/Dashboard" && break
        sleep 1
    done
    code_anon=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${port}/UI/Dashboard")
    curl -s -o /dev/null --max-time 8 -c "$jar" --data-urlencode "password=${pw}" "http://127.0.0.1:${port}/UI/Dashboard"
    code_auth=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -b "$jar" "http://127.0.0.1:${port}/UI/Dashboard")
    rm -f "$jar"
    if [[ "$code_anon" != "200" && "$code_auth" == "200" ]]; then
        echo -e "${GREEN}✅ Проверка входа: без пароля панель закрыта, с паролем открывается.${NC}"
        return 0
    fi
    echo -e "${YELLOW}⚠️ Автопроверка входа не подтвердилась (без пароля: ${code_anon}, с паролем: ${code_auth}).${NC}"
    echo "   Откройте панель в браузере и войдите. Если пароль не подошёл, запустите пункт 2 меню ещё раз:"
    echo "   он перезапишет API key и пароль, заблокироваться насовсем нельзя."
    return 1
}

# Задаёт API key, пароль панели, External access и CORS одним действием.
configure_basic() {
    local key pw hash ext=true
    https_active && ext=false     # при включённом HTTPS обычный HTTP снаружи остаётся закрытым
    installed || { echo -e "${RED}Jackett не установлен.${NC}"; return 1; }
    [[ -f "$(cfg_file)" ]] || { echo -e "${RED}Нет $(cfg_file). Запустите службу один раз.${NC}"; return 1; }

    echo -e "\n${YELLOW}⚙️ [НАСТРОЙКА] API key, пароль панели, External access, Allow CORS${NC}"
    ask_api_key;        key="$API_KEY"
    ask_admin_password; pw="$ADMIN_PASSWORD"
    hash=$(hash_admin_password "$pw" "$key")

    systemctl stop "$SVC" 2>/dev/null
    edit_config --arg k "$key" --arg h "$hash" --argjson e "$ext" \
        '.APIKey=$k | .AdminPassword=$h | .AllowExternal=$e | .AllowCORS=true' \
        || { systemctl start "$SVC"; return 1; }
    systemctl start "$SVC"

    echo -e "${GREEN}✅ Готово.${NC}"
    echo "   API key:         ${key}"
    echo "   Пароль панели:   задан"
    if [[ "$ext" == "true" ]]; then
        echo "   External access: включён, Allow CORS: включён."
    else
        echo "   External access: выключен (вход снаружи только по HTTPS: $(https_url)), Allow CORS: включён."
    fi
    verify_login "$pw"
    unset ADMIN_PASSWORD pw
}

show_summary() {
    local ip port
    ip=$(get_ip); port=$(get_port)
    sleep 2
    echo
    echo -e "${GREEN}✅ Jackett установлен.${NC} Служба: $(systemctl is-active "$SVC")"
    if https_active; then
        echo "   Адрес:   $(https_url)  (HTTPS включён, обычный HTTP снаружи закрыт)"
    else
        echo "   Адрес:   http://${ip}:${port}"
    fi
    echo "   Конфиг:  $(cfg_file)"
    echo
    echo "   Войдите с паролем, который вы только что задали, и добавьте трекеры (Add indexer)."
    echo "   Логины/пароли трекеров вводятся в панели, либо восстановите папку Indexers (пункт 3 меню)."
    if https_active; then
        echo "   В Oracle Cloud порт HTTPS должен быть открыт в Security List (или в NSG), а порт ${port}/tcp можно закрыть."
    else
        echo "   В Oracle Cloud откройте порт ${port}/tcp в Security List (или в NSG)."
        echo "   HTTPS: пункт 8 меню откроет ssl.sh (там пункт 1 выпускает сертификат, пункт 2 ставит уже выпущенный): Jackett получит адрес https://домен:9118."
    fi
}

# ---------------------------------------------------------------- INDEXERS

backup_indexers() {
    installed || { echo -e "${RED}Jackett не установлен.${NC}"; return 1; }
    local src dest
    src="$(cfg_dir)/Indexers"
    [[ -d "$src" ]] || { echo -e "${RED}Папки ${src} нет: не добавлено ни одного трекера.${NC}"; return 1; }
    dest="/root/jackett-indexers-$(date +%Y%m%d-%H%M%S).tar.gz"
    ( umask 077; tar -czf "$dest" -C "$(cfg_dir)" Indexers ) || { echo -e "${RED}Не удалось создать архив.${NC}"; return 1; }
    chmod 600 "$dest"
    echo -e "${GREEN}✅ Indexers сохранены: ${dest}${NC}"
    echo -e "${YELLOW}В архиве логины и cookie ваших трекеров: храните его как пароль.${NC}"
    BACKUP_PATH="$dest"
}

restore_indexers() {
    installed || { echo -e "${RED}Jackett не установлен.${NC}"; return 1; }
    echo -e "\n${YELLOW}📥 [ВОССТАНОВЛЕНИЕ INDEXERS]${NC}"
    echo "Загрузите папку Indexers (или её архив .tar.gz / .zip) на сервер, например через scp или WinSCP,"
    echo "и укажите путь к ней. Текущая папка Indexers будет заменена."
    local path tmp src
    read -rp "Путь к папке или архиву: " path
    path="${path/#\~/$HOME}"
    [[ -e "$path" ]] || { echo -e "${RED}Путь не найден.${NC}"; return 1; }

    tmp=$(mktemp -d)
    if [[ -d "$path" ]]; then
        src="$path"
    elif [[ "$path" == *.zip ]]; then
        apt_install_tracked unzip || return 1
        unzip -q "$path" -d "$tmp" || { echo -e "${RED}Не удалось распаковать zip.${NC}"; rm -rf "$tmp"; return 1; }
        src="$tmp"
    else
        tar -xzf "$path" -C "$tmp" 2>/dev/null || { echo -e "${RED}Не удалось распаковать архив.${NC}"; rm -rf "$tmp"; return 1; }
        src="$tmp"
    fi

    # Папка может лежать на уровень глубже (Indexers/...)
    [[ -d "${src}/Indexers" ]] && src="${src}/Indexers"
    if ! ls "$src"/*.json &>/dev/null; then
        echo -e "${RED}В ${src} нет файлов *.json: это не папка Indexers.${NC}"
        rm -rf "$tmp"; return 1
    fi

    systemctl stop "$SVC" 2>/dev/null
    mkdir -p "$(cfg_dir)"
    rm -rf "$(cfg_dir)/Indexers"
    cp -a "$src" "$(cfg_dir)/Indexers"
    chown -R "${JK_USER}:${JK_USER}" "$(cfg_dir)"
    chmod -R go-rwx "$(cfg_dir)/Indexers"
    rm -rf "$tmp"
    systemctl start "$SVC"
    echo -e "${GREEN}✅ Indexers восстановлены ($(ls "$(cfg_dir)/Indexers"/*.json | wc -l) шт.), служба перезапущена.${NC}"
}

# ---------------------------------------------------------------- FLARESOLVERR
# FlareSolverr решает защиту Cloudflare для трекеров, с которыми Jackett сам не справляется.
# Работает в Docker, порт открыт только на 127.0.0.1 (наружу не торчит, это небезопасно).

FS_PORT=8191
FS_URL="http://127.0.0.1:${FS_PORT}"
SWAP_NEEDED_MB=2800
# Обход Cloudflare: FlareSolverr (Chrome) или Byparr (замена с тем же API, браузер Camoufox).
# Работает один из них: оба слушают один порт 8191.
set_engine() {
    case "$1" in
        byparr)
            FS_ENGINE="byparr"; FS_LABEL="Byparr"; FS_NAME="byparr"
            FS_IMAGE="ghcr.io/thephaseless/byparr:latest"; SWAP_NEEDED_MB=2000 ;;
        *)
            FS_ENGINE="flaresolverr"; FS_LABEL="FlareSolverr"; FS_NAME="flaresolverr"
            FS_IMAGE="ghcr.io/flaresolverr/flaresolverr:latest"; SWAP_NEEDED_MB=2800 ;;
    esac
}
set_engine "$FS_ENGINE"

# Движок ответил и готов к работе
fs_ready() {
    if [[ "$FS_ENGINE" == "byparr" ]]; then
        [[ "$(curl -s -o /dev/null -L -w '%{http_code}' --max-time 3 "${FS_URL}/docs" 2>/dev/null)" == "200" ]]
    else
        curl -s --max-time 3 "${FS_URL}/" 2>/dev/null | grep -qi 'ready'
    fi
}

fs_container_exists() {
    command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$FS_NAME"
}

# Прописывает (или очищает, если передана пустая строка) адрес FlareSolverr в настройках Jackett
set_jackett_flaresolverr() {
    local url="$1"
    [[ -f "$(cfg_file)" ]] || { echo -e "${YELLOW}Конфиг Jackett не найден, адрес ${FS_LABEL} не прописан.${NC}"; return 1; }
    systemctl stop "$SVC" 2>/dev/null
    edit_config --arg u "$url" '.FlareSolverrUrl=$u'
    local rc=$?
    systemctl start "$SVC" 2>/dev/null
    return $rc
}

ram_mb()  { awk '/MemTotal/  {printf "%d", $2/1024}' /proc/meminfo; }
swap_mb() { awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo; }

# Браузеру нужно около 1.5-2 ГБ: если RAM + swap меньше порога (FlareSolverr ~2.8 ГБ, Byparr ~2 ГБ), предлагаем создать swap-файл.
# Возвращает 0, если памяти достаточно или swap создан; 1, если отказались или не получилось.
ensure_swap() {
    local ram swap total size f free_mb
    ram=$(ram_mb); swap=$(swap_mb); total=$((ram + swap))
    if (( total >= SWAP_NEEDED_MB )); then return 0; fi

    echo -e "${YELLOW}Память: RAM ${ram} МБ + swap ${swap} МБ = ${total} МБ.${NC}"
    echo "Для браузера (${FS_LABEL}) нужно не меньше ~$((SWAP_NEEDED_MB / 1000)) ГБ вместе со swap, иначе браузер падает"
    echo "(ошибки «chrome not reachable», «Connection reset by peer»)."

    if (( ram < 1500 )); then size=2048; else size=1024; fi
    f="/swapfile"
    [[ -e "$f" ]] && f="/swapfile.jackett"
    if [[ -e "$f" ]]; then
        echo -e "${RED}Файлы /swapfile и ${f} уже существуют, но swap мал или выключен. Создайте swap вручную.${NC}"
        return 1
    fi

    free_mb=$(df -m --output=avail / 2>/dev/null | tail -n 1 | tr -d ' ')
    if [[ -n "$free_mb" ]] && (( free_mb < size + 3000 )); then
        echo -e "${RED}На диске свободно ${free_mb} МБ: не хватит на swap ${size} МБ и образ ${FS_LABEL}.${NC}"
        return 1
    fi

    yn "Создать swap-файл ${size} МБ (${f})?" || return 1

    echo "Создаю swap ${size} МБ..."
    if ! fallocate -l "${size}M" "$f" 2>/dev/null; then
        dd if=/dev/zero of="$f" bs=1M count="$size" status=none 2>/dev/null
    fi
    chmod 600 "$f"
    if ! mkswap "$f" >/dev/null 2>&1 || ! swapon "$f" 2>/dev/null; then
        echo -e "${RED}Не удалось включить swap.${NC}"
        swapoff "$f" 2>/dev/null; rm -f "$f"
        return 1
    fi
    grep -qF "$f none swap" /etc/fstab 2>/dev/null || echo "$f none swap sw 0 0" >> /etc/fstab
    SWAP_CREATED="$f"
    save_state
    echo -e "${GREEN}✅ Swap включён и будет подключаться при загрузке: RAM ${ram} МБ + swap $(swap_mb) МБ.${NC}"
    return 0
}

# Убирает swap-файл, который создал скрипт
remove_swap() {
    local f="$SWAP_CREATED"
    [[ -n "$f" ]] || return 0
    if [[ -f "$f" ]]; then
        if ! swapoff "$f" 2>/dev/null; then
            if swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$f"; then
                echo -e "${YELLOW}Не удалось выключить swap (мало свободной памяти): файл ${f} оставляю. Повторите удаление позже.${NC}"
                return 1
            fi
        fi
        rm -f "$f"
    fi
    sed -i "\#^${f} none swap#d" /etc/fstab 2>/dev/null
    SWAP_CREATED=""
    return 0
}

# Анализ сервера: показывает ресурсы и выбирает рекомендуемый движок (решение остаётся за пользователем).
REC_ENGINE="flaresolverr"
analyze_system() {
    local ram swap cpu arch free_mb
    ram=$(ram_mb); swap=$(swap_mb); cpu=$(nproc 2>/dev/null || echo 1); arch=$(uname -m)
    free_mb=$(df -m --output=avail / 2>/dev/null | tail -n 1 | tr -d ' ')

    echo -e "\n${YELLOW}Анализ сервера:${NC}"
    echo "  Процессор: ${cpu} ядр., архитектура ${arch}"
    echo "  Память:    RAM ${ram} МБ + swap ${swap} МБ"
    echo "  Диск:      свободно ${free_mb:-?} МБ"

    local why
    if (( ram < 1500 )); then
        REC_ENGINE="byparr"
        why="RAM меньше 1.5 ГБ: FlareSolverr (Chrome) на такой памяти часто падает, Byparr легче по памяти"
    else
        REC_ENGINE="flaresolverr"
        why="памяти достаточно, FlareSolverr проверен временем и надёжнее совместим с Jackett"
    fi
    echo -e "  ${GREEN}Рекомендую: $([[ "$REC_ENGINE" == "byparr" ]] && echo Byparr || echo FlareSolverr)${NC} (${why})."

    (( ram + swap < 2000 )) && echo -e "  ${YELLOW}⚠ RAM + swap меньше 2 ГБ: без swap браузер будет падать (скрипт предложит создать его).${NC}"
    (( cpu < 2 )) && echo -e "  ${YELLOW}⚠ Слабый процессор (${cpu} ядро): проверка Cloudflare может занимать больше 60 секунд, а это лимит Jackett.${NC}"
    echo "    Если будет таймаут «HttpClient.Timeout of 60 seconds», это ограничение сервера, а не выбранного движка."
    [[ -n "$free_mb" ]] && (( free_mb < 4000 )) && echo -e "  ${YELLOW}⚠ Свободно меньше 4 ГБ: образ (около 1 ГБ) и swap могут не поместиться.${NC}"
    return 0
}

# Выбор движка. При смене старый контейнер (если его создал скрипт) удаляется.
choose_engine() {
    local cur="" c def mark1="" mark2=""
    analyze_system
    fs_container_exists && cur="$FS_LABEL"

    # По умолчанию: уже установленный движок, иначе рекомендованный
    if [[ -n "$cur" ]]; then def="$FS_ENGINE"; else def="$REC_ENGINE"; fi
    [[ "$REC_ENGINE" == "flaresolverr" ]] && mark1=" (рекомендую)" || mark2=" (рекомендую)"

    echo -e "\nЧто использовать для обхода Cloudflare?${cur:+ (сейчас стоит: ${cur})}"
    echo "1. FlareSolverr${mark1}: классический вариант (Chrome), нужно ~1.5-2 ГБ памяти"
    echo "2. Byparr${mark2}: замена FlareSolverr с тем же API (браузер Camoufox), легче по памяти, но проект моложе"
    read -rp "Выберите [1-2, Enter = $([[ "$def" == "byparr" ]] && echo 2 || echo 1)]: " c
    case "$c" in
        1) c="flaresolverr" ;;
        2) c="byparr" ;;
        *) c="$def" ;;
    esac
    [[ "$c" == "$FS_ENGINE" ]] && return 0

    if fs_container_exists; then
        if [[ -z "$FS_CONTAINER" ]]; then
            echo -e "${RED}Контейнер ${FS_NAME} создан не этим скриптом: не буду его удалять. Оставляю ${FS_LABEL}.${NC}"
            return 0
        fi
        echo "→ удаляю ${FS_LABEL} (контейнер${FS_IMAGE_NEW:+ и образ}) перед установкой нового..."
        remove_flaresolverr
    fi
    set_engine "$c"
    save_state
    return 0
}

install_flaresolverr() {
    local mode="$1"
    installed || { echo -e "${RED}Jackett не установлен.${NC}"; return 1; }
    echo -e "\n${YELLOW}🛡️ [CLOUDFLARE] Обход защиты Cloudflare для трекеров${NC}"
    [[ "$mode" == "auto" ]] || choose_engine

    local pre_exists=0 swap_before="$SWAP_CREATED"
    fs_container_exists && pre_exists=1
    if (( $(ram_mb) < 1500 )) && [[ "$mode" == "auto" ]]; then
        echo -e "${YELLOW}Оперативной памяти $(ram_mb) МБ. ${FS_LABEL} запускает браузер, ему нужно от 1.5-2 ГБ.${NC}"
        echo "Пропускаю. Если ошибка «Challenge detected» появится, запустите пункт 5 меню: он предложит добавить swap."
        return 0
    fi
    if (( $(ram_mb) + $(swap_mb) < SWAP_NEEDED_MB )); then
        if ! ensure_swap; then
            yn "Памяти мало. Всё равно установить ${FS_LABEL}?" || return 0
        fi
    fi

    command -v apt-get &>/dev/null || return 1
    if ! command -v docker &>/dev/null; then
        echo "Docker не найден, ставлю docker.io из репозитория Ubuntu..."
        apt_install_tracked docker.io || return 1
    fi
    systemctl enable --now docker &>/dev/null
    if ! docker info &>/dev/null; then
        echo -e "${RED}Docker не отвечает. Смотрите: systemctl status docker${NC}"
        return 1
    fi

    if fs_container_exists && [[ -z "$FS_CONTAINER" ]]; then
        echo -e "${YELLOW}Контейнер ${FS_NAME} уже есть и создан не этим скриптом: использую его как есть.${NC}"
    else
        if ! fs_container_exists && ss -ltn 2>/dev/null | grep -q ":${FS_PORT} "; then
            echo -e "${RED}Порт ${FS_PORT} уже занят другой программой.${NC}"
            return 1
        fi
        # Образ: запоминаем, если его не было до нас
        if ! docker image inspect "$FS_IMAGE" &>/dev/null; then
            FS_IMAGE_NEW=1
            save_state
        fi
        echo "Скачиваю образ ${FS_LABEL} (это может занять пару минут)..."
        if ! docker pull "$FS_IMAGE"; then
            echo -e "${RED}Не удалось скачать образ.${NC}"
            return 1
        fi
        fs_container_exists && docker rm -f "$FS_NAME" &>/dev/null
        local run_extra=(-e LOG_LEVEL=info)
        [[ "$FS_ENGINE" == "byparr" ]] && run_extra=(--shm-size=512m)
        if ! docker run -d --name "$FS_NAME" --restart unless-stopped \
                -p "127.0.0.1:${FS_PORT}:${FS_PORT}" "${run_extra[@]}" "$FS_IMAGE" >/dev/null; then
            echo -e "${RED}Не удалось запустить контейнер.${NC}"
            return 1
        fi
        FS_CONTAINER=1
        save_state
    fi

    # Контейнер уже был (и мог падать из-за нехватки памяти), а swap только что создан: перезапускаем
    if (( pre_exists )) && [[ "$SWAP_CREATED" != "$swap_before" ]]; then
        docker restart "$FS_NAME" &>/dev/null
    fi

    echo -n "Жду запуска ${FS_LABEL}"
    local i ok=0
    for i in $(seq 1 180); do
        if fs_ready; then ok=1; break; fi
        echo -n "."; sleep 1
    done
    echo
    if (( ! ok )); then
        echo -e "${YELLOW}${FS_LABEL} за 3 минуты не ответил (на слабом сервере первый запуск бывает долгим).${NC}"
        echo "   Проверьте позже: docker logs ${FS_NAME}"
    fi

    if set_jackett_flaresolverr "$FS_URL"; then
        if (( ok )); then
            echo -e "${GREEN}✅ ${FS_LABEL} работает (${FS_URL}) и подключён к Jackett.${NC}"
        else
            echo -e "${YELLOW}${FS_LABEL} подключён к Jackett (${FS_URL}), но пока не отвечает: подождите пару минут.${NC}"
        fi
        echo "   Jackett после перезапуска может открыться не сразу (до минуты)."
        echo "   Затем в панели повторите добавление/обновление трекера."
        if [[ "$FS_ENGINE" == "byparr" ]]; then
            echo "   Byparr моложе FlareSolverr: если Jackett пишет «The cookies provided by FlareSolverr are not valid»"
            echo "   или трекер не добавляется, вернитесь на FlareSolverr (пункт 5, выбор 1)."
        fi
    else
        echo -e "${YELLOW}В настройках Jackett (внизу страницы) впишите вручную: FlareSolverr API URL = ${FS_URL} (поле называется так же и для Byparr)${NC}"
    fi
}

remove_flaresolverr() {
    if command -v docker &>/dev/null && fs_container_exists; then
        docker rm -f "$FS_NAME" &>/dev/null
    fi
    if [[ -n "$FS_IMAGE_NEW" ]] && command -v docker &>/dev/null; then
        docker rmi "$FS_IMAGE" &>/dev/null
    fi
    # Если в Jackett прописан наш адрес, очищаем его
    if [[ -f "$(cfg_file 2>/dev/null)" ]] && [[ "$(jq -r '.FlareSolverrUrl // empty' "$(cfg_file)" 2>/dev/null)" == "$FS_URL" ]]; then
        if installed; then set_jackett_flaresolverr ""; else edit_config --arg u "" '.FlareSolverrUrl=$u'; fi
    fi
    FS_CONTAINER=""
    FS_IMAGE_NEW=""
}

# ---------------------------------------------------------------- СТАТУС

show_status() {
    installed || { echo -e "${RED}Jackett не установлен.${NC}"; return; }
    local port cfg
    port=$(get_port); cfg=$(cfg_file)
    echo -e "\n${YELLOW}📊 [СТАТУС JACKETT]${NC}"
    echo "Служба:      $(systemctl is-active "$SVC") (автозапуск: $(systemctl is-enabled "$SVC" 2>/dev/null))"
    echo "Пользователь: ${JK_USER:-неизвестен}"
    echo "Порт:        ${port}  $(ss -ltn 2>/dev/null | grep -q ":${port} " && echo '(слушает)' || echo '(НЕ слушает)')"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/UI/Dashboard")
    echo "HTTP локально: ${code} (200/302 - панель отвечает)"
    if [[ -f "$cfg" ]]; then
        local k
        k=$(jq -r '.APIKey // empty' "$cfg")
        echo "API key:     ${k:0:4}… (длина ${#k})"
        echo "External:    $(jq -r '.AllowExternal' "$cfg"),  CORS: $(jq -r '.AllowCORS' "$cfg")"
        if https_active; then
            echo "HTTPS:       включён, $(https_url) (служба jackett-tls: $(systemctl is-active jackett-tls))"
        else
            echo "HTTPS:       нет (пункт 8 меню откроет ssl.sh: там пункт 1 выпускает сертификат, пункт 2 ставит уже выпущенный)"
        fi
        if [[ -z "$(jq -r '.AdminPassword // empty' "$cfg")" ]]; then
            echo -e "${RED}Пароль панели НЕ задан!${NC}"
        else
            echo "Пароль панели: задан"
        fi
        echo "Indexers:    $(ls "$(cfg_dir)/Indexers"/*.json 2>/dev/null | wc -l) шт."
    fi
    if command -v docker &>/dev/null && fs_container_exists; then
        echo "${FS_LABEL}: $(docker inspect -f '{{.State.Status}}' "$FS_NAME" 2>/dev/null), адрес в Jackett: $(jq -r '.FlareSolverrUrl // "не задан"' "$cfg" 2>/dev/null)"
    else
        echo "FlareSolverr/Byparr: не установлен"
    fi
    echo "Память:      RAM $(ram_mb) МБ, swap $(swap_mb) МБ"
    echo "UFW:         $(ufw status 2>/dev/null | grep -E "${port}" | head -n 3 | tr '\n' ';')"
}

# ---------------------------------------------------------------- УДАЛЕНИЕ

# Убирает HTTPS-прокси Jackett (nginx), который поставил ssl.sh.
# Если Jackett остаётся (keep_app=1), возвращает ему прежние настройки и правило UFW: обычный HTTP снова работает.
remove_https_proxy() {
    local keep_app="$1" prev_ext prev_url uport cport was=0
    systemctl stop jackett-tls 2>/dev/null
    systemctl disable jackett-tls &>/dev/null
    rm -f "$TLS_UNIT"
    systemctl daemon-reload

    if (( keep_app )) && [[ -f "$(cfg_file 2>/dev/null)" && -f "${TLS_DIR}/prev_allow_external" ]]; then
        prev_ext=$(cat "${TLS_DIR}/prev_allow_external" 2>/dev/null)
        [[ "$prev_ext" == "false" ]] || prev_ext=true
        prev_url=$(cat "${TLS_DIR}/prev_base_url" 2>/dev/null)
        systemctl is-active --quiet "$SVC" && was=1
        systemctl stop "$SVC" 2>/dev/null
        edit_config --argjson e "$prev_ext" --arg u "$prev_url" '.AllowExternal=$e | .BaseUrlOverride=$u'
        (( was )) && systemctl start "$SVC" 2>/dev/null
        echo "   Jackett снова работает по обычному HTTP (AllowExternal=${prev_ext})."
    fi

    if command -v ufw &>/dev/null; then
        uport=$(cat "${TLS_DIR}/ufw_port" 2>/dev/null)
        [[ -n "$uport" ]] && ufw --force delete allow "${uport}/tcp" >/dev/null 2>&1
        cport=$(cat "${TLS_DIR}/ufw_closed_port" 2>/dev/null)
        if [[ -n "$cport" ]] && (( keep_app )); then
            ufw allow "${cport}/tcp" >/dev/null 2>&1
            echo "   Правило UFW для порта ${cport}/tcp возвращено. В Oracle Security List откройте его вручную, если нужен доступ по HTTP."
        fi
    fi

    # Пакеты nginx и stunnel4 (его ставила прежняя версия ssl.sh) удаляем только если их поставил ssl.sh (он оставил отметку)
    [[ -f "${TLS_DIR}/pkg_nginx_added" ]] && apt-get purge -y 'nginx*' >/dev/null 2>&1
    [[ -f "${TLS_DIR}/pkg_stunnel_added" ]] && apt-get purge -y stunnel4 >/dev/null 2>&1
    rm -rf "$TLS_DIR"
}

uninstall_jackett() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ JACKETT]${NC}"
    local has_app=0 has_cfg=0 has_ufw=0 has_user=0 has_fs=0 has_swap=0 has_tls=0 pkgs=""
    local pkg
    installed && has_app=1
    [[ -n "$JK_USER" ]] && [[ -d "$(cfg_dir)" ]] && has_cfg=1
    [[ -n "$UFW_RULE" ]] && command -v ufw &>/dev/null && ufw show added 2>/dev/null | grep -qxF "ufw ${UFW_RULE}" && has_ufw=1
    [[ -n "$USER_CREATED" && -n "$JK_USER" ]] && id -u "$JK_USER" &>/dev/null && has_user=1
    [[ -n "$FS_CONTAINER" ]] && fs_container_exists && has_fs=1
    [[ -n "$SWAP_CREATED" && -f "$SWAP_CREATED" ]] && has_swap=1
    [[ -d "$TLS_DIR" || -f "$TLS_UNIT" ]] && has_tls=1
    for pkg in $PKGS_ADDED; do pkg_installed "$pkg" && pkgs="${pkgs:+$pkgs }$pkg"; done

    if (( has_app + has_cfg + has_ufw + has_user + has_fs + has_swap + has_tls == 0 )) && [[ -z "$pkgs" ]]; then
        echo -e "${GREEN}Удалять нечего.${NC}"
        rm -f "$STATE_FILE"
        return
    fi

    echo "Найдено:"
    (( has_app ))  && echo "  • программа и служба: ${APP_DIR}, ${UNIT}"
    (( has_cfg ))  && echo "  • настройки и Indexers: $(cfg_dir)"
    (( has_fs ))   && echo "  • ${FS_LABEL}: контейнер ${FS_NAME}$([[ -n "$FS_IMAGE_NEW" ]] && echo ' и его образ')"
    (( has_ufw ))  && echo "  • правило UFW: ${UFW_RULE}"
    (( has_swap )) && echo "  • swap-файл ${SWAP_CREATED} (создан скриптом)"
    (( has_tls ))  && echo "  • HTTPS-прокси (nginx, служба jackett-tls, сертификат в ${TLS_DIR}; поставлен через ssl.sh)"
    (( has_user )) && echo "  • пользователь ${JK_USER} (создан скриптом) вместе с домашней папкой"
    [[ -n "$pkgs" ]] && echo "  • пакеты, поставленные скриптом: ${pkgs}"
    echo
    echo "1. Всё: вернуть систему к состоянию до установки"
    echo "2. Выбрать по компонентам"
    echo "0. Отмена"
    local sc
    read -rp "Выберите [0-2]: " sc

    local d_app=0 d_cfg=0 d_ufw=0 d_user=0 d_pkg=0 d_fs=0 d_swap=0 d_tls=0
    case "$sc" in
        1) d_app=$has_app; d_cfg=$has_cfg; d_ufw=$has_ufw; d_user=$has_user; d_fs=$has_fs; d_swap=$has_swap; d_tls=$has_tls; [[ -n "$pkgs" ]] && d_pkg=1 ;;
        2)
            (( has_app ))  && yn "Удалить программу и службу Jackett?" && d_app=1
            (( has_cfg ))  && yn "Удалить настройки и Indexers ($(cfg_dir))?" && d_cfg=1
            (( has_fs ))   && yn "Удалить ${FS_LABEL} (контейнер${FS_IMAGE_NEW:+ и образ})?" && d_fs=1
            (( has_ufw ))  && yn "Удалить правило UFW (${UFW_RULE})?" && d_ufw=1
            (( has_swap )) && yn "Удалить swap-файл ${SWAP_CREATED}?" && d_swap=1
            (( has_tls ))  && yn "Удалить HTTPS-прокси Jackett (nginx)? Если Jackett остаётся, он вернётся на обычный HTTP" && d_tls=1
            (( has_user )) && yn "Удалить пользователя ${JK_USER} и его домашнюю папку?" && d_user=1
            [[ -n "$pkgs" ]] && yn "Удалить пакеты (${pkgs})?" && d_pkg=1
            ;;
        *) echo "Отменено."; return ;;
    esac

    # Зависимости
    local extra=()
    if (( d_user && has_app && !d_app )); then d_app=1; extra+=("программа и служба (работают от ${JK_USER})"); fi
    if (( d_user && has_cfg && !d_cfg )); then d_cfg=1; extra+=("настройки (лежат в домашней папке ${JK_USER})"); fi

    if (( d_pkg && has_fs && !d_fs )) && [[ " $pkgs " == *" docker.io "* ]]; then d_fs=1; extra+=("${FS_LABEL} (пакет docker.io будет удалён)"); fi
    if (( d_app && has_tls && !d_tls )); then d_tls=1; extra+=("HTTPS-прокси (он работает только вместе с Jackett)"); fi

    if (( d_app + d_cfg + d_ufw + d_user + d_pkg + d_fs + d_swap + d_tls == 0 )); then echo "Ничего не выбрано."; return; fi

    echo -e "\n${YELLOW}Будет удалено:${NC}"
    (( d_app ))  && echo "  ✗ программа и служба"
    (( d_cfg ))  && echo "  ✗ настройки и Indexers"
    (( d_fs ))   && echo "  ✗ ${FS_LABEL} (контейнер${FS_IMAGE_NEW:+ и образ})"
    (( d_ufw ))  && echo "  ✗ правило UFW"
    (( d_swap )) && echo "  ✗ swap-файл ${SWAP_CREATED}"
    (( d_tls ))  && echo "  ✗ HTTPS-прокси (nginx)"
    (( d_user )) && echo "  ✗ пользователь ${JK_USER}"
    (( d_pkg ))  && echo "  ✗ пакеты: ${pkgs}"
    if (( ${#extra[@]} )); then
        echo -e "${YELLOW}Дополнительно из-за зависимостей:${NC}"
        printf '  + %s\n' "${extra[@]}"
    fi

    if (( d_cfg )) && [[ -d "$(cfg_dir)/Indexers" ]]; then
        echo -e "\n${YELLOW}В Indexers хранятся логины/cookie трекеров.${NC}"
        yn "Сохранить резервную копию в /root перед удалением?" && backup_indexers
    fi

    echo
    yn "Подтвердите удаление" || { echo "Отменено."; return; }

    if (( d_fs )); then
        echo "→ удаляю ${FS_LABEL}..."
        remove_flaresolverr
    fi
    if (( d_tls )); then
        echo "→ удаляю HTTPS-прокси..."
        # Jackett остаётся, только если не удаляются ни программа, ни настройки: тогда ему возвращаем обычный HTTP
        remove_https_proxy $(( (d_app || d_cfg) ? 0 : 1 ))
    fi
    if (( d_app )); then
        echo "→ удаляю программу и службу..."
        systemctl stop "$SVC" 2>/dev/null
        systemctl disable "$SVC" &>/dev/null
        rm -f "$UNIT"
        rm -rf "$APP_DIR"
        systemctl daemon-reload
        systemctl reset-failed "$SVC" 2>/dev/null
    fi
    if (( d_cfg )); then
        echo "→ удаляю настройки..."
        systemctl stop "$SVC" 2>/dev/null
        rm -rf "$(cfg_dir)"
    fi
    if (( d_ufw )); then
        echo "→ удаляю правило UFW..."
        # shellcheck disable=SC2086
        ufw --force delete $UFW_RULE >/dev/null 2>&1
        UFW_RULE=""
    fi
    if (( d_swap )); then
        echo "→ удаляю swap-файл..."
        remove_swap
    fi
    if (( d_user )); then
        echo "→ удаляю пользователя ${JK_USER}..."
        pkill -u "$JK_USER" 2>/dev/null
        userdel -r "$JK_USER" 2>/dev/null
        USER_CREATED=""
        JK_USER=""
    fi
    if (( d_pkg )); then
        echo "→ удаляю пакеты..."
        # shellcheck disable=SC2086
        apt-get purge -y $pkgs
        echo -e "${YELLOW}autoremove может затронуть и пакеты, не связанные со скриптом. Список:${NC}"
        apt-get -s autoremove --purge 2>/dev/null | grep '^Remove' | sed 's/^Remove /  - /' | head -n 30
        yn "Выполнить autoremove?" && apt-get autoremove --purge -y
        local left=""
        for pkg in $PKGS_ADDED; do pkg_installed "$pkg" && left="${left:+$left }$pkg"; done
        PKGS_ADDED="$left"
    fi
    pkg_installed ufw || UFW_RULE=""
    # Правило UFW могли удалить вручную или через ssl.sh (когда HTTPS закрыл обычный порт)
    if [[ -n "$UFW_RULE" ]] && ! { command -v ufw &>/dev/null && ufw show added 2>/dev/null | grep -qxF "ufw ${UFW_RULE}"; }; then UFW_RULE=""; fi
    # Контейнер могли удалить вручную
    fs_container_exists || FS_CONTAINER=""

    if ! installed && [[ -z "$PKGS_ADDED" && -z "$UFW_RULE" && -z "$USER_CREATED" && -z "$FS_CONTAINER" && -z "$SWAP_CREATED" ]] && { [[ -z "$JK_USER" ]] || [[ ! -d "$(cfg_dir)" ]]; }; then
        rm -f "$STATE_FILE"
        echo -e "\n${GREEN}✅ Всё удалено. Система возвращена к состоянию до установки.${NC}"
    else
        save_state
        echo -e "\n${GREEN}✅ Выбранное удалено. Остальное можно удалить повторно через этот же пункт.${NC}"
    fi
    echo -e "${YELLOW}Не забудьте закрыть порт ${DEFAULT_PORT} в Oracle Security List, если открывали.${NC}"
}

# ---------------------------------------------------------------- ПЕРЕХОД В ssl.sh

# Скачивает ssl.sh (выпуск и установка сертификата) и запускает его. После выхода из него вы вернётесь в это меню.
run_ssl_script() {
    echo -e "\n${YELLOW}=== Сертификат для HTTPS: переход в ssl.sh ===${NC}"
    if ! installed; then
        echo -e "${YELLOW}Jackett ещё не установлен (пункт 1): ssl.sh выпустит сертификат, но HTTPS для Jackett включится только после установки.${NC}"
        echo "   После установки Jackett запустите пункт 8 ещё раз и выберите в ssl.sh пункт 2."
    fi
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
    echo -e "\n${GREEN}Вы вернулись в меню Jackett.${NC} Статус и протокол: пункт 6."
    if https_active; then
        echo -e "${GREEN}HTTPS для Jackett включён: $(https_url)${NC}"
        echo "   В Oracle Cloud (Security List / NSG) порт HTTPS должен быть открыт, а порт Jackett ${DEFAULT_PORT}/tcp можно закрыть."
    fi
}

# ---------------------------------------------------------------- МЕНЮ

while true; do
    echo -e "\n${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}   Jackett: установка и управление   ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo "1. Установить / обновить Jackett"
    echo "2. Настроить: API key, пароль панели, External access, CORS"
    echo "3. Восстановить папку Indexers (из папки или архива)"
    echo "4. Сохранить Indexers в архив (резервная копия)"
    echo "5. Обход Cloudflare: установить / сменить FlareSolverr или Byparr (ошибка \"Challenge detected\")"
    echo "6. Статус"
    echo "7. Удаление"
    echo "8. Сертификат HTTPS: перейти в скрипт ssl.sh (выпуск и установка)"
    echo "0. Выход"
    echo "=================================================="
    read -rp "Выберите действие [0-8]: " choice

    case $choice in
        1) install_jackett ;;
        2) configure_basic ;;
        3) restore_indexers ;;
        4) backup_indexers ;;
        5) install_flaresolverr ;;
        6) show_status ;;
        7) uninstall_jackett ;;
        8) run_ssl_script ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
