#!/bin/bash
# =====================================================================
#  Oracle Cloud: автоматическое создание сервера Ampere / Micro (Always Free), пока не появится место
#  Запуск:  sudo bash oracle_arm_full.sh      (на любом вашем сервере, который работает круглые сутки)
#
#  Что делает:
#    - ставит консольную утилиту Oracle (oci) в отдельную папку /opt/oci-cli;
#    - помогает один раз подключить её к вашему аккаунту (ключ доступа создаёте вы сами);
#    - САМ находит в вашем аккаунте регион, подсети, образы Ubuntu: вам остаётся выбрать из списка;
#    - запускает фоновую службу, которая раз в несколько минут пробует создать сервер
#      (VM.Standard.A1.Flex) и останавливается, как только получилось;
#    - по желанию присылает уведомление в Telegram;
#    - позволяет смотреть, менять и удалять ваши серверы, не заходя на сайт Oracle;
#    - удаляет всё, что поставил, одним пунктом меню.
#
#  Меню:  1. Подключение к Oracle   2. Автопоиск места (настроить / запустить / статус)
#         3. Мои серверы (список, изменить, удалить, создать вручную)   4. Удаление скрипта
#
#  Ключи и пароли в скрипте не хранятся: ключ Oracle лежит в ~/.oci (его создаёт утилита oci).
# =====================================================================

export DEBIAN_FRONTEND=noninteractive
export SUPPRESS_LABEL_WARNING=True   # oci иногда советует дописать строку в файл ключа: это только предупреждение

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запустите от root: sudo bash $0${NC}"
    exit 1
fi

exec 3<&0   # ввод пользователя: нужен внутри функций, где stdin занят списком

OCI_VENV="/opt/oci-cli"
OCI_BIN="${OCI_VENV}/bin/oci"
OCI_LINK="/usr/local/bin/oci"
OCI_CFG="/root/.oci/config"
CONF_FILE="/etc/oracle-arm.conf"
KEY_COPY="/etc/oracle-arm-ssh.pub"
STATE_FILE="/etc/oracle-arm.state"
SVC="oracle-arm-retry"
UNIT="/etc/systemd/system/${SVC}.service"
WORKER="/usr/local/sbin/oracle-arm-worker.sh"
LOG="/var/log/oracle-arm.log"
DONE_FILE="/var/lib/oracle-arm.done"
SHAPE="VM.Standard.A1.Flex"

# --- Учёт того, что создал скрипт ---
PKGS_ADDED=""        # пакеты, которых не было до установки
OCI_INSTALLED=""     # 1, если утилиту oci поставил скрипт

load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"; }
save_state() {
    {
        echo "PKGS_ADDED=$(printf '%q' "$PKGS_ADDED")"
        echo "OCI_INSTALLED=$(printf '%q' "$OCI_INSTALLED")"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}
load_state

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
apt_install_tracked() {
    local p missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    apt-get update -qq
    if ! apt-get install -y "${missing[@]}"; then
        echo -e "${RED}Не удалось установить: ${missing[*]}${NC}"
        return 1
    fi
    PKGS_ADDED="${PKGS_ADDED:+$PKGS_ADDED }${missing[*]}"
    save_state
}

yn() { local a; read -rp "$1 (y/n): " a; [[ "$a" == "y" || "$a" == "Y" ]]; }

# ---------------------------------------------------------------- OCI CLI

oci_cmd() { "$OCI_BIN" "$@"; }

cfg_value() { awk -F= -v k="$1" '$1 ~ "^[[:space:]]*"k"[[:space:]]*$" {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$OCI_CFG" 2>/dev/null; }

install_cli() {
    [[ -x "$OCI_BIN" ]] && return 0   # уже установлена: молча (статус виден в «Статус и журнал»)
    echo -e "\n${YELLOW}=== Установка утилиты Oracle (oci) ===${NC}"
    command -v apt-get &>/dev/null || { echo -e "${RED}Нужна Ubuntu/Debian (apt).${NC}"; return 1; }
    apt_install_tracked python3 python3-venv jq curl || return 1
    echo "Ставлю oci-cli (1-3 минуты)..."
    python3 -m venv "$OCI_VENV" || { echo -e "${RED}Не удалось создать окружение Python.${NC}"; return 1; }
    "$OCI_VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1
    if ! "$OCI_VENV/bin/pip" install --quiet oci-cli; then
        echo -e "${RED}Не удалось установить oci-cli.${NC}"
        return 1
    fi
    ln -sf "$OCI_BIN" "$OCI_LINK"
    OCI_INSTALLED=1
    save_state
    echo -e "${GREEN}✅ oci установлена: $("$OCI_BIN" --version)${NC}"
}

# Проверка доступа к аккаунту. Возвращает 0 при успехе.
oci_check() {
    [[ -x "$OCI_BIN" && -f "$OCI_CFG" ]] || return 1
    local t
    t=$(cfg_value tenancy)
    [[ -n "$t" ]] || return 1
    oci_cmd iam availability-domain list --compartment-id "$t" >/dev/null 2>&1
}

configure_oci() {
    install_cli || return 1
    echo -e "\n${YELLOW}=== Подключение к вашему аккаунту Oracle ===${NC}"
    if oci_check; then
        echo -e "${GREEN}Доступ к аккаунту уже настроен (регион: $(cfg_value region)).${NC}"
        yn "Настроить заново?" || return 0
    fi

    write_oci_config || return 1
    show_public_key
    read -rp "Когда добавите ключ, нажмите Enter..." _
    verify_access
}

# Региональные коды, которые Oracle показывает в консоли (FRA и т.п) -> имя региона для утилиты
region_name() {
    case "${1^^}" in
        FRA) echo "eu-frankfurt-1" ;;
        AMS) echo "eu-amsterdam-1" ;;
        ZRH) echo "eu-zurich-1" ;;
        LHR) echo "uk-london-1" ;;
        CDG) echo "eu-paris-1" ;;
        ARN) echo "eu-stockholm-1" ;;
        MAD) echo "eu-madrid-1" ;;
        MRS) echo "eu-marseille-1" ;;
        *) echo "${1,,}" ;;
    esac
}

# Создаёт ~/.oci/config и новый ключ доступа (вместо интерактивного oci setup config: меньше вопросов)
write_oci_config() {
    command -v openssl &>/dev/null || apt_install_tracked openssl || return 1
    local user tenancy region pw kdir keyname kf pubf fp

    cat <<'TXT'

Нужны три значения из консоли Oracle:
  - User OCID: Профиль (справа вверху) -> Настройки пользователя -> OCID (под именем пользователя) -> Копировать.
    Начинается с ocid1.user.
  - Tenancy OCID: Профиль (справа вверху) -> Область аренды -> OCID (над именем) -> Копировать.
    Начинается с ocid1.tenancy.
  - Регион: Профиль (справа вверху) -> Область аренды -> Домашний регион.
    Можно ввести и короткий код из консоли (например FRA).
Ключ доступа скрипт создаст сам. В консоль нужно будет добавить только его ПУБЛИЧНУЮ часть.
TXT
    while true; do
        read -rp "User OCID: " user || return 1
        user=$(tr -d '[:space:]' <<< "$user")
        [[ "$user" == ocid1.user.* ]] && break
        echo -e "${RED}Не похоже на User OCID (должен начинаться с ocid1.user.). Это не OCID аренды?${NC}"
    done
    while true; do
        read -rp "Tenancy OCID: " tenancy || return 1
        tenancy=$(tr -d '[:space:]' <<< "$tenancy")
        [[ "$tenancy" == ocid1.tenancy.* ]] && break
        echo -e "${RED}Не похоже на Tenancy OCID (должен начинаться с ocid1.tenancy.).${NC}"
    done
    while true; do
        read -rp "Регион [eu-frankfurt-1; можно FRA]: " region || return 1
        region=$(region_name "$(tr -d '[:space:]' <<< "${region:-eu-frankfurt-1}")")
        [[ "$region" =~ ^[a-z]{2}-[a-z0-9]+(-[a-z0-9]+)*-[0-9]+$ ]] && break
        echo -e "${RED}Не похоже на название региона (пример: eu-frankfurt-1).${NC}"
    done
    echo "Регион: ${region}"
    read -rsp "Пароль на ключ (Enter = без пароля): " pw; echo

    kdir=$(dirname "$OCI_CFG")
    mkdir -p "$kdir"; chmod 700 "$kdir"
    keyname="oci_api_key_$(date +%Y%m%d%H%M%S)"
    kf="${kdir}/${keyname}.pem"; pubf="${kdir}/${keyname}_public.pem"

    if [[ -n "$pw" ]]; then
        OCI_PW="$pw" openssl genrsa -aes256 -passout env:OCI_PW -out "$kf" 2048 2>/dev/null || { echo -e "${RED}Не удалось создать ключ.${NC}"; return 1; }
        OCI_PW="$pw" openssl rsa -in "$kf" -passin env:OCI_PW -pubout -out "$pubf" 2>/dev/null
    else
        openssl genrsa -out "$kf" 2048 2>/dev/null || { echo -e "${RED}Не удалось создать ключ.${NC}"; return 1; }
        openssl rsa -in "$kf" -pubout -out "$pubf" 2>/dev/null
    fi
    chmod 600 "$kf"; chmod 644 "$pubf"
    if [[ -n "$pw" ]]; then
        fp=$(OCI_PW="$pw" openssl rsa -in "$kf" -passin env:OCI_PW -pubout -outform DER 2>/dev/null | openssl md5 -c 2>/dev/null | awk '{print $NF}')
    else
        fp=$(openssl rsa -in "$kf" -pubout -outform DER 2>/dev/null | openssl md5 -c 2>/dev/null | awk '{print $NF}')
    fi
    if [[ -z "$fp" ]]; then echo -e "${RED}Не удалось вычислить отпечаток ключа.${NC}"; return 1; fi

    [[ -f "$OCI_CFG" ]] && cp -p "$OCI_CFG" "${OCI_CFG}.bak.$(date +%Y%m%d%H%M%S)"
    ( umask 077
      {
        echo "[DEFAULT]"
        echo "user=${user}"
        echo "fingerprint=${fp}"
        echo "key_file=${kf}"
        echo "tenancy=${tenancy}"
        echo "region=${region}"
        [[ -n "$pw" ]] && echo "pass_phrase=${pw}"
      } > "$OCI_CFG" )
    chmod 600 "$OCI_CFG"
    echo -e "${GREEN}✅ Конфиг записан: ${OCI_CFG}; ключ: ${kf}${NC}"
    return 0
}

# Публичная часть именно того ключа, который записан в ~/.oci/config (имя ключа вы могли задать свои)
show_public_key() {
    local kf pub=""
    kf=$(cfg_value key_file)
    kf="${kf/#\~/$HOME}"
    [[ -f "${kf%.pem}_public.pem" ]] && pub="${kf%.pem}_public.pem"
    echo -e "\n${YELLOW}Теперь добавьте публичный ключ в консоль Oracle:${NC}"
    echo "  Профиль (справа вверху) -> Настройки пользователя -> Ключи API (API keys) -> Добавить ключ API -> Вставить открытый ключ -> вставьте текст ниже -> Добавить."
    echo "(Если консоль покажет окно с конфигом, закрывайте его: он у нас уже есть.)"
    echo "Ключ в конфиге: ${kf:-?}"
    echo "------------------------------------------------------------"
    if [[ -n "$pub" ]]; then
        cat "$pub"
    elif [[ -f "$kf" ]] && command -v openssl &>/dev/null; then
        openssl rsa -in "$kf" -pubout -passin pass: 2>/dev/null
    else
        echo "(публичный ключ не найден; выполните: openssl rsa -in ${kf:-КЛЮЧ.pem} -pubout)"
    fi
    echo "------------------------------------------------------------"
    echo -e "${GREEN}После добавления в консоли у ключа появится Fingerprint. Он должен быть таким же:${NC}"
    echo "   $(cfg_value fingerprint)"
}

# Проверка доступа с понятным объяснением ошибки
verify_access() {
    echo -n "Проверяю доступ... "
    local t err rc
    t=$(cfg_value tenancy)
    err=$(oci_cmd iam availability-domain list --compartment-id "$t" 2>&1 >/dev/null)
    rc=$?
    if (( rc == 0 )); then   # предупреждения в stderr при успехе не считаются ошибкой
        echo -e "${GREEN}✅ доступ к аккаунту работает.${NC}"
        return 0
    fi
    err=$(grep -v 'Warning: To increase security' <<< "$err")
    echo -e "${RED}❌ доступ не получен.${NC}"
    echo "Ответ Oracle: $(tr '\n' ' ' <<< "$err" | cut -c1-400)"
    if grep -qiE 'NotAuthenticated|401' <<< "$err"; then
        echo "Причина: Oracle не принял подпись. Почти всегда это значит, что в консоли добавлен НЕ тот ключ."
        echo "  - Сравните Fingerprint у ключа в консоли с этим: $(cfg_value fingerprint)"
        echo "  - Если не совпадает: удалите лишние ключи и добавьте ключ из рамки выше (пункт 1 покажет его снова)."
    elif grep -qiE 'password|passphrase|encrypted' <<< "$err"; then
        echo "Причина: проблема с паролем ключа. Откройте ~/.oci/config и удалите строку pass_phrase=..., если ключ создан без пароля."
    elif grep -qiE 'key_file|No such file|not found' <<< "$err"; then
        echo "Причина: не найден файл ключа ($(cfg_value key_file))."
    else
        echo "Проверьте OCID пользователя и аренды (user=ocid1.user..., tenancy=ocid1.tenancy...), регион и лишние пробелы."
    fi
    return 1
}

# ---------------------------------------------------------------- НАСТРОЙКА ЗАДАЧИ

# Выбор из списка строк (TSV). Аргументы: заголовок, затем строки через stdin; результат в PICKED (строка целиком)
PICKED=""; PICKED_IDX=0
pick_from() {
    local title="$1" def="${2:-1}" i=1 line choice
    local rows=()
    while IFS= read -r line; do [[ -n "$line" ]] && rows+=("$line"); done
    if [[ ${#rows[@]} -eq 0 ]]; then PICKED=""; return 1; fi
    echo -e "\n${YELLOW}${title}${NC}"
    for line in "${rows[@]}"; do
        echo "  ${i}. ${line//$'\t'/  |  }"
        i=$((i + 1))
    done
    while true; do
        read -u 3 -rp "Номер [1-${#rows[@]}, Enter = ${def}]: " choice || return 1
        choice="${choice:-$def}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rows[@]} )); then
            PICKED="${rows[$((choice - 1))]}"; PICKED_IDX="$choice"
            return 0
        fi
        echo -e "${RED}Введите число от 1 до ${#rows[@]}.${NC}"
    done
}

ask_number() {  # ask_number "Вопрос" default min max -> ANSWER
    local q="$1" def="$2" min="$3" max="$4" v
    while true; do
        read -u 3 -rp "${q} [${def}]: " v || return 1
        v="${v:-$def}"
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= min && v <= max )); then ANSWER="$v"; return 0; fi
        echo -e "${RED}Нужно число от ${min} до ${max}.${NC}"
    done
}

collect_ssh_keys() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys /root/.ssh/*.pub /home/*/.ssh/*.pub; do
        [[ -f "$f" ]] && grep -hE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null
    done | awk '!seen[$0]++'
}

telegram_send() {  # telegram_send TOKEN CHAT TEXT
    curl -s --max-time 15 -X POST "https://api.telegram.org/bot$1/sendMessage" \
        -d "chat_id=$2" --data-urlencode "text=$3" 2>/dev/null | grep -q '"ok":true'
}

yn_d() {  # yn_d "Вопрос" y|n -> Enter = значение по умолчанию (y = включено)
    local q="$1" def="${2:-y}" a hint="Y/n, Enter = Y (да)"
    [[ "$def" == "n" ]] && hint="y/N, Enter = N (нет)"
    while true; do
        read -u 3 -rp "${q} [${hint}]: " a || return 1
        a="${a:-$def}"
        case "$a" in y|Y|д|Д) return 0 ;; n|N|н|Н) return 2 ;; esac
        echo -e "${RED}Введите y или n.${NC}"
    done
}

# Сколько Always Free уже занято серверами Ampere и дисками (по возможности; ошибки не критичны)
used_resources() {  # -> "ocpu mem boot"
    local comp="$1" ads="$2" ad insts u_cpu u_mem u_boot=0 b u_micro
    insts=$(oci_cmd compute instance list --compartment-id "$comp" --all 2>/dev/null)
    u_cpu=$(jq -r --arg s "VM.Standard.A1.Flex" '[.data[]? | select(.shape==$s and .["lifecycle-state"]!="TERMINATED" and .["lifecycle-state"]!="TERMINATING") | (.["shape-config"].ocpus // 0)] | add // 0 | floor' <<< "$insts" 2>/dev/null)
    u_mem=$(jq -r --arg s "VM.Standard.A1.Flex" '[.data[]? | select(.shape==$s and .["lifecycle-state"]!="TERMINATED" and .["lifecycle-state"]!="TERMINATING") | (.["shape-config"]["memory-in-gbs"] // 0)] | add // 0 | floor' <<< "$insts" 2>/dev/null)
    u_micro=$(jq -r '[.data[]? | select(.shape=="VM.Standard.E2.1.Micro" and .["lifecycle-state"]!="TERMINATED" and .["lifecycle-state"]!="TERMINATING")] | length' <<< "$insts" 2>/dev/null)
    for ad in $ads; do
        b=$(oci_cmd bv boot-volume list --availability-domain "$ad" --compartment-id "$comp" --all 2>/dev/null \
            | jq -r '[.data[]? | select(.["lifecycle-state"]=="AVAILABLE" or .["lifecycle-state"]=="PROVISIONING") | (.["size-in-gbs"] // 0)] | add // 0 | floor' 2>/dev/null)
        u_boot=$((u_boot + ${b:-0}))
    done
    echo "${u_cpu:-0} ${u_mem:-0} ${u_boot:-0} ${u_micro:-0}"
}

setup_telegram() {  # заполняет TG_TOKEN и TG_CHAT (пустые = уведомления выключены)
    TG_TOKEN=""; TG_CHAT=""
    echo -e "\n${GREEN}━━━ Уведомления в Telegram (необязательно) ━━━${NC}"
    echo "Бот напишет вам, когда сервер будет создан или попытки остановятся из-за ошибки."
    local old_tok="" old_chat=""
    if [[ -f "$CONF_FILE" ]]; then
        old_tok=$(bash -c 'source "$1" 2>/dev/null; echo "$TG_TOKEN"' _ "$CONF_FILE")
        old_chat=$(bash -c 'source "$1" 2>/dev/null; echo "$TG_CHAT"' _ "$CONF_FILE")
    fi
    if [[ -n "$old_tok" && -n "$old_chat" ]]; then
        echo "Уже настроен бот, токен ${old_tok:0:10}..."
        if yn_d "Оставить его (повторно вводить ничего не нужно)?" y; then
            TG_TOKEN="$old_tok"; TG_CHAT="$old_chat"
            if telegram_send "$TG_TOKEN" "$TG_CHAT" "✅ Oracle: уведомления работают."; then
                echo -e "${GREEN}✅ Бот сохранён, тестовое сообщение отправлено.${NC}"
            else
                echo -e "${YELLOW}Тестовое сообщение не дошло (проверьте интернет и бота). Настройки сохранены как есть.${NC}"
            fi
            return 0
        fi
    fi
    yn_d "Настроить уведомления в Telegram?" y || return 0

    echo -e "\n${YELLOW}Шаг 1 из 3. Создайте бота и скопируйте токен.${NC}"
    echo "  1) Откройте Telegram (на телефоне или на компьютере)."
    echo "  2) В строке поиска вверху введите  @BotFather  и откройте чат с ним (рядом с названием синяя галочка)."
    echo "  3) Нажмите «Запустить» (Start) и отправьте ему сообщение:  /newbot"
    echo "  4) Он спросит имя бота: напишите любое, например  Oracle сервер"
    echo "  5) Затем username (адрес) бота: уникальный, должен заканчиваться на bot, например  vitalii_oracle_bot"
    echo "     (если занят, добавьте цифры)"
    echo "  6) BotFather пришлёт сообщение «Done! Congratulations...». В нём под строкой"
    echo "     «Use this token to access the HTTP API:» будет токен вида  123456789:AAH-xxxxxxxxxxxx"
    echo "     Нажмите на него (он скопируется) или выделите и скопируйте."
    echo "  Токен никому не показывайте: с ним можно управлять вашим ботом."
    echo
    local info="" attempt
    for attempt in 1 2 3; do
        read -u 3 -rp "Вставьте токен (Enter без текста = пропустить Telegram): " TG_TOKEN || return 1
        TG_TOKEN="${TG_TOKEN// /}"
        [[ -z "$TG_TOKEN" ]] && { echo "Telegram пропущен."; return 0; }
        info=$(curl -s --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null)
        if jq -e '.ok == true' >/dev/null 2>&1 <<< "$info"; then
            echo -e "${GREEN}✅ Токен принят. Бот: @$(jq -r '.result.username' <<< "$info")${NC}"
            break
        fi
        echo -e "${RED}Токен не подошёл (попытка ${attempt}/3). Проверьте, что скопировали его целиком, вместе с двоеточием.${NC}"
        TG_TOKEN=""
    done
    [[ -z "$TG_TOKEN" ]] && { echo -e "${YELLOW}Telegram пропущен.${NC}"; return 0; }
    local bot_user
    bot_user=$(jq -r '.result.username' <<< "$info")

    echo -e "\n${YELLOW}Шаг 2 из 3. Напишите своему боту.${NC}"
    echo "  Бот не может написать вам первым, поэтому сначала вы пишете ему:"
    echo "  1) Откройте вашего бота: нажмите ссылку  t.me/${bot_user}  (или найдите @${bot_user} в поиске Telegram)."
    echo "  2) Нажмите «Запустить» (Start) и отправьте любое сообщение, например:  привет"
    read -u 3 -rp "Готово? Нажмите Enter: " _ || return 1

    echo -e "\n${YELLOW}Шаг 3 из 3. Проверка.${NC}"
    local ups
    for attempt in 1 2 3; do
        ups=$(curl -s --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" 2>/dev/null)
        TG_CHAT=$(jq -r '[.result[]? | (.message.chat.id // empty)] | last // empty' <<< "$ups" 2>/dev/null)
        [[ -n "$TG_CHAT" ]] && break
        echo -e "${YELLOW}Ваше сообщение боту не найдено (попытка ${attempt}/3).${NC}"
        echo "  Убедитесь, что вы написали именно ВАШЕМУ боту (@${bot_user}), а не BotFather."
        read -u 3 -rp "Напишите ему ещё раз, затем нажмите Enter (или введите chat id вручную): " TG_CHAT || return 1
        if [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]]; then break; fi
        TG_CHAT=""
    done
    if [[ -z "$TG_CHAT" ]]; then
        echo -e "${YELLOW}Не удалось определить chat id.${NC}"
        echo "  Узнать его можно так: в Telegram откройте @userinfobot, нажмите Start: он пришлёт число Id."
        read -u 3 -rp "Введите chat id (Enter = пропустить Telegram): " TG_CHAT || return 1
        if [[ ! "$TG_CHAT" =~ ^-?[0-9]+$ ]]; then TG_TOKEN=""; TG_CHAT=""; echo "Telegram пропущен."; return 0; fi
    fi
    echo "  Chat id: ${TG_CHAT}"

    echo "  Отправляю тестовое уведомление..."
    if telegram_send "$TG_TOKEN" "$TG_CHAT" "✅ Oracle: тест уведомлений. Если вы видите это сообщение, всё настроено верно."; then
        echo -e "${GREEN}✅ Тестовое сообщение отправлено.${NC}"
        if yn_d "Оно пришло вам в Telegram?" y; then
            echo -e "${GREEN}Уведомления включены.${NC}"
        else
            echo -e "${YELLOW}Раз не пришло, уведомления выключены. Проверьте, что вы не заблокировали бота, и повторите настройку (пункт 2, «Настройка параметров поиска»).${NC}"
            TG_TOKEN=""; TG_CHAT=""
        fi
    else
        echo -e "${RED}Telegram отклонил отправку.${NC} Чаще всего причина в том, что вы не нажали Start у своего бота. Уведомления выключены, повторите настройку (пункт 2, «Настройка параметров поиска»)."
        TG_TOKEN=""; TG_CHAT=""
    fi
}

# Ручное создание ещё одного сервера: не трогает фоновый поиск и его настройки
manual_launch() {
    local ads="$1" comp="$2" shape="$3" image="$4" subnet="$5" assign="$6" name="$7" keyf="$8" boot="$9" transit="${10}" ocpu="${11}" mem="${12}"
    echo -e "\n${YELLOW}Будет создан:${NC} ${name}, ${shape}$([[ "$shape" == *.Flex ]] && echo ", ${ocpu} ЦП, ${mem} ГБ памяти")"
    yn_d "Пробовать создать сейчас?" y || { echo "Отменено."; return; }
    local loop=0
    echo "Если места нет, можно повторять попытки в этом окне каждые 3 минуты, пока не получится."
    echo "(окно терминала нужно держать открытым; Ctrl+C остановит повторы; фоновый поиск от этого не страдает)"
    yn_d "Повторять в этом окне до успеха?" n && loop=1

    local tg_token="" tg_chat=""
    if [[ -f "$CONF_FILE" ]]; then
        tg_token=$(bash -c 'source "$1" 2>/dev/null; echo "$TG_TOKEN"' _ "$CONF_FILE")
        tg_chat=$(bash -c 'source "$1" 2>/dev/null; echo "$TG_CHAT"' _ "$CONF_FILE")
    fi

    local ad args out rc n=0 id ip i stop=0 lim adn limmsg=""
    trap 'stop=1' INT
    while (( ! stop )); do
        n=$((n + 1)); lim=0; adn=0
        for ad in $ads; do
            adn=$((adn + 1))
            args=(compute instance launch --availability-domain "$ad" --compartment-id "$comp" --shape "$shape"
                  --image-id "$image" --subnet-id "$subnet" --assign-public-ip "${assign:-true}" --display-name "$name")
            [[ "$shape" == *.Flex ]] && args+=(--shape-config "{\"ocpus\":${ocpu},\"memoryInGBs\":${mem}}")
            [[ -n "$keyf" ]] && args+=(--ssh-authorized-keys-file "$keyf")
            [[ -n "$boot" ]] && args+=(--boot-volume-size-in-gbs "$boot")
            [[ "$transit" == "true" ]] && args+=(--is-pv-encryption-in-transit-enabled true)
            out=$(oci_cmd "${args[@]}" 2>&1 </dev/null); rc=$?
            if (( rc == 0 )); then
                id=$(jq -r '.data.id // empty' <<< "$out" 2>/dev/null)
                echo -e "${GREEN}✅ Сервер «${name}» создан (${ad##*:}). Жду внешний IP...${NC}"
                ip=""
                if [[ -n "$id" && "${assign:-true}" == "true" ]]; then
                    for i in $(seq 1 12); do
                        ip=$(oci_cmd compute instance list-vnics --instance-id "$id" 2>/dev/null </dev/null | jq -r '.data[0]["public-ip"] // empty')
                        [[ -n "$ip" ]] && break
                        sleep 10
                    done
                fi
                echo -e "${GREEN}Внешний IP: ${ip:-смотрите в пункте 3}. Вход: ssh ubuntu@${ip:-IP}${NC}"
                [[ -n "$tg_token" && -n "$tg_chat" ]] && telegram_send "$tg_token" "$tg_chat" "Oracle: ✅ вручную создан сервер ${name}. Внешний IP: ${ip:-смотрите в консоли}. Вход: ssh ubuntu@${ip:-IP}" >/dev/null
                trap - INT
                return 0
            fi
            if grep -qiE 'out of (host )?capacity|OutOfHostCapacity' <<< "$out"; then
                echo "$(date '+%T') попытка ${n}, ${ad##*:}: нет места (Out of host capacity)"
            elif grep -qiE 'TooManyRequests|"status": 429|too many requests' <<< "$out"; then
                echo -e "${YELLOW}Oracle просит притормозить (429).${NC}"
                if (( loop )); then echo "Жду 10 минут..."; sleep 600; else trap - INT; return 1; fi
                break
            elif grep -qiE 'LimitExceeded' <<< "$out"; then
                lim=$((lim + 1))
                limmsg=$(tr '\n' ' ' <<< "$out" | grep -oiE '"message": *"[^"]*"' | head -n 1 | cut -c1-250)
                echo "$(date '+%T') ${ad##*:}: в этом домене такой сервер создать нельзя (лимит), пробую следующий"
            elif grep -qiE 'NotAuthenticated|"status": 401' <<< "$out"; then
                echo -e "${RED}Oracle не принял ключ доступа. Проверьте подключение (пункт 1).${NC}"
                trap - INT; return 1
            elif grep -qiE 'NotAuthorizedOrNotFound|"status": 404' <<< "$out"; then
                echo -e "${RED}Ошибка параметров (подсеть, образ или права). Попробуйте создать профиль заново.${NC}"
                trap - INT; return 1
            else
                echo -e "${RED}Неизвестная ошибка:${NC} $(tr '\n' ' ' <<< "$out" | cut -c1-300)"
                trap - INT; return 1
            fi
        done
        if (( adn > 0 && lim == adn )); then
            echo -e "${RED}Ни в одном домене такой сервер создать нельзя: лимит (LimitExceeded).${NC}"
            [[ -n "$limmsg" ]] && echo "Ответ Oracle: ${limmsg}"
            echo "Проверьте список серверов (пункт 3: что уже создано и сколько осталось от лимита)."
            trap - INT; return 1
        fi
        (( loop )) || { echo -e "${YELLOW}Места пока нет. Можно повторить позже (пункт 3, «Создать сервер вручную») или включить повтор в этом окне.${NC}"; break; }
        (( stop )) && break
        echo "Следующий круг через 3 минуты (Ctrl+C: остановить)..."
        sleep 180
    done
    trap - INT
    (( stop )) && echo -e "\n${YELLOW}Остановлено. Фоновый поиск работает как раньше.${NC}"
    return 1
}

setup_task() {
    local mode="${1:-save}"
    install_cli || return 1
    oci_check || { echo -e "${RED}Сначала подключите аккаунт Oracle (пункт 1).${NC}"; return 1; }
    echo -e "\n${YELLOW}=== $([[ "$mode" == "manual" ]] && echo "Создание ещё одного сервера вручную" || echo "Создание сервера") (как мастер «Создать экземпляр» в консоли Oracle) ===${NC}"

    local tenancy region comp
    tenancy=$(cfg_value tenancy); region=$(cfg_value region)
    comp="$tenancy"
    echo "Регион: ${region}"
    echo -e "${YELLOW}Always Free серверы создаются только в ДОМАШНЕМ регионе (его вы выбрали при регистрации).${NC}"

    # Домены доступности
    local ads
    ads=$(oci_cmd iam availability-domain list --compartment-id "$tenancy" 2>/dev/null | jq -r '.data[].name' | tr '\n' ' ')
    ads="${ads% }"
    if [[ -z "$ads" ]]; then echo -e "${RED}Не удалось получить домены доступности.${NC}"; return 1; fi
    echo "Домены доступности: ${ads} (скрипт пробует все по очереди)"

    # ---------- Шаг 1. Базовая информация
    echo -e "\n${GREEN}━━━ 1. Базовая информация ━━━${NC}"
    local NAME def_name
    def_name="instance-$(date +%Y%m%d-%H%M)"
    read -u 3 -rp "Имя [${def_name}]: " NAME || return 1
    NAME="${NAME:-$def_name}"
    NAME=$(tr -cd 'A-Za-z0-9_-' <<< "$NAME"); NAME="${NAME:-$def_name}"
    if [[ "$mode" == "manual" && -f "$CONF_FILE" ]]; then
        local bg_name
        bg_name=$(bash -c 'source "$1" 2>/dev/null; echo "$NAME"' _ "$CONF_FILE")
        if [[ -n "$bg_name" && "$NAME" == "$bg_name" ]]; then
            NAME="${NAME}-2"
            echo -e "  ${YELLOW}Такое имя у сервера фонового поиска: назвал этот «${NAME}», чтобы они не путались.${NC}"
        fi
    fi

    # ---------- Шаг 2. Образ и шаблон конфигурации
    echo -e "\n${GREEN}━━━ 2. Образ и шаблон конфигурации ━━━${NC}"
    echo "Показываются только конфигурации «Всегда бесплатно» и только образы Ubuntu."
    echo "  Проверяю, сколько уже занято в аккаунте..."
    local used u_cpu u_mem u_boot u_micro free_cpu free_mem free_boot free_micro
    used=$(used_resources "$comp" "$ads")
    read -r u_cpu u_mem u_boot u_micro <<< "$used"
    free_cpu=$((4 - u_cpu)); free_mem=$((24 - u_mem)); free_boot=$((200 - u_boot)); free_micro=$((2 - u_micro))
    (( free_cpu < 0 )) && free_cpu=0; (( free_mem < 0 )) && free_mem=0; (( free_boot < 0 )) && free_boot=0; (( free_micro < 0 )) && free_micro=0
    echo "  Ampere уже занято: ${u_cpu} ЦП, ${u_mem} ГБ памяти (свободно ${free_cpu} ЦП, ${free_mem} ГБ). Micro уже создано: ${u_micro} из 2."
    if [[ "$mode" == "manual" && -f "$CONF_FILE" && ! -f "$DONE_FILE" ]] && systemctl is-active --quiet "$SVC"; then
        local bg_shape bg_cpu bg_mem
        read -r bg_shape bg_cpu bg_mem <<< "$(bash -c 'source "$1" 2>/dev/null; echo "${SHAPE:-VM.Standard.A1.Flex} ${OCPU:-0} ${MEM:-0}"' _ "$CONF_FILE")"
        if [[ "$bg_shape" == "VM.Standard.A1.Flex" ]]; then
            free_cpu=$((free_cpu - bg_cpu)); free_mem=$((free_mem - bg_mem))
            (( free_cpu < 0 )) && free_cpu=0; (( free_mem < 0 )) && free_mem=0
            echo -e "  ${YELLOW}Фоновый поиск ждёт место под Ampere ${bg_cpu} ЦП и ${bg_mem} ГБ: я их не трогаю.${NC} Для ручного сервера доступно ${free_cpu} ЦП и ${free_mem} ГБ."
        else
            free_micro=$((free_micro - 1)); (( free_micro < 0 )) && free_micro=0
            echo -e "  ${YELLOW}Фоновый поиск ждёт место под Micro: один слот Micro не трогаю.${NC} Для ручного сервера доступно Micro: ${free_micro}."
        fi
        echo "  (чтобы отдать ручному серверу всё, остановите фоновый поиск: пункт 2)"
    fi

    local shape_rows
    shape_rows="Ampere  VM.Standard.A1.Flex"$'\t'"Always Free: до 4 ЦП и 24 ГБ памяти на все Ampere вместе (ARM)"$'\t'"свободно: ${free_cpu} ЦП, ${free_mem} ГБ"$'\n'
    shape_rows+="Micro  VM.Standard.E2.1.Micro"$'\t'"Always Free: 1 ЦП, 1 ГБ памяти (AMD), до 2 штук в аккаунте"$'\t'"свободно штук: ${free_micro}"
    pick_from "Конфигурация (🏷 Режим «Всегда бесплатно» применим)" 1 <<< "$shape_rows" || return 1
    if [[ "$PICKED_IDX" == "2" ]]; then SHAPE="VM.Standard.E2.1.Micro"; else SHAPE="VM.Standard.A1.Flex"; fi

    local OCPU MEM
    if [[ "$SHAPE" == "VM.Standard.A1.Flex" ]]; then
        if (( free_cpu < 1 || free_mem < 1 )); then
            echo -e "${RED}Лимит Always Free по Ampere исчерпан существующими серверами.${NC}"
            echo "Удалите лишний сервер Ampere в консоли или выберите Micro."
            return 1
        fi
        echo
        ask_number "Количество ЦП (1-${free_cpu})" "$free_cpu" 1 "$free_cpu" || return 1; OCPU="$ANSWER"
        local mem_def=$((OCPU * 6)); (( mem_def > free_mem )) && mem_def=$free_mem
        ask_number "Объём памяти, ГБ (${OCPU}-${free_mem})" "$mem_def" "$OCPU" "$free_mem" || return 1; MEM="$ANSWER"
        echo "  Пропускная способность сети: ${OCPU} Гбит/с (1 Гбит/с на каждый ЦП)"
    else
        if (( free_micro < 1 )); then
            echo -e "${RED}Уже есть 2 сервера Micro: это лимит Always Free.${NC}"
            return 1
        fi
        OCPU=1; MEM=1
        echo "  Micro: 1 ЦП и 1 ГБ памяти, менять нельзя (так устроена эта конфигурация). Сеть до 0,48 Гбит/с."
    fi

    local imgs
    imgs=$(oci_cmd compute image list --compartment-id "$comp" --operating-system "Canonical Ubuntu" \
        --shape "$SHAPE" --all 2>/dev/null \
        | jq -r '.data
            | group_by(.["operating-system-version"]) | map(max_by(.["time-created"]))
            | sort_by([ (.["operating-system-version"] | split(" ")[0] | split(".") | map((tonumber? // 0) * -1)), .["operating-system-version"] ])
            | .[] | [.["operating-system"], .["operating-system-version"], .["display-name"], .id] | @tsv')
    if [[ -z "$imgs" ]]; then echo -e "${RED}Образы Ubuntu для ${SHAPE} не найдены.${NC}"; return 1; fi
    local img_rows="" def_img=1 n2=0 ios iv iname iid mark newest=1
    local img_labels=() img_ids=()
    while IFS=$'\t' read -r ios iv iname iid; do
        [[ -z "$iv" ]] && continue
        n2=$((n2 + 1)); mark=""
        (( newest )) && { mark=" (новейшая)"; newest=0; }
        if [[ "$iv" == "24.04" ]]; then mark="${mark} (рекомендую: на ней проверены мои скрипты)"; def_img=$n2; fi
        img_rows+="${ios} ${iv}${mark}"$'\n'
        img_labels[n2]="${ios} ${iv}"; img_ids[n2]="$iid"
    done <<< "$imgs"
    pick_from "Образ" "$def_img" <<< "${img_rows%$'\n'}" || return 1
    local IMAGE_NAME IMAGE_ID
    IMAGE_NAME="${img_labels[PICKED_IDX]}"; IMAGE_ID="${img_ids[PICKED_IDX]}"

    # ---------- Шаг 3. Безопасность
    echo -e "\n${GREEN}━━━ 3. Безопасность ━━━${NC}"
    echo "  Защищённый экземпляр: для Ampere (A1.Flex) Oracle его не поддерживает, для Micro скрипт его не включает."

    # ---------- Шаг 4. Сети
    echo -e "\n${GREEN}━━━ 4. Сети ━━━${NC}"
    local subs
    subs=$(oci_cmd network subnet list --compartment-id "$comp" --all 2>/dev/null \
        | jq -r '.data[] | [.["display-name"], .["cidr-block"], (if .["prohibit-public-ip-on-vnic"] then "частная" else "публичная" end), .id] | @tsv')
    if [[ -z "$subs" ]]; then
        echo -e "${RED}Подсетей нет. Создайте сеть в консоли: Networking -> Virtual cloud networks -> Start VCN Wizard.${NC}"
        return 1
    fi
    local def_sub=1 n=0 row found=0
    while IFS= read -r row; do
        n=$((n + 1))
        if (( ! found )) && [[ "$row" == *$'\t'публичная$'\t'* ]]; then def_sub=$n; found=1; fi
    done <<< "$subs"
    pick_from "Подсеть (публичная нужна, чтобы у сервера был внешний адрес)" "$def_sub" <<< "$subs" || return 1
    local SUBNET_ID SUBNET_NAME ASSIGN_IP="true" sub_kind
    SUBNET_NAME=$(cut -f1 <<< "$PICKED"); SUBNET_ID=$(cut -f4 <<< "$PICKED"); sub_kind=$(cut -f3 <<< "$PICKED")
    if [[ "$sub_kind" == "частная" ]]; then
        ASSIGN_IP="false"
        echo -e "${YELLOW}Подсеть частная: публичный IPv4 назначить нельзя, войти на сервер из интернета не получится.${NC}"
        yn_d "Всё равно продолжить?" n || return 1
    else
        echo
        if yn_d "Автоматически назначить общедоступный IPv4-адрес?" y; then ASSIGN_IP="true"; else ASSIGN_IP="false"
            echo -e "${YELLOW}Без публичного адреса войти на сервер из интернета не получится.${NC}"
        fi
    fi

    echo -e "\n${YELLOW}Добавить ключи SSH${NC} (по ключу вы будете входить на новый сервер; пароля у Ubuntu нет)"
    local keys key_rows="" k KEY_TEXT="" SSH_MODE="" ssh_choice
    local keyfile_path="$KEY_COPY"
    [[ "$mode" == "manual" ]] && keyfile_path=$(mktemp /tmp/oracle-manual-key.XXXXXX)
    keys=$(collect_ssh_keys)
    pick_from "Способ" 1 <<< $'Создать пару ключей для меня\nЗагрузка файла открытого ключа (.pub)\nВставить открытый ключ\nКлючи SSH отсутствуют' || return 1
    ssh_choice="$PICKED_IDX"
    case "$ssh_choice" in
        1)
            command -v ssh-keygen >/dev/null || apt-get install -y openssh-client >/dev/null 2>&1
            local kpath="/root/oracle-ampere-key"
            [[ -e "$kpath" ]] && kpath="/root/oracle-ampere-key-$(date +%Y%m%d%H%M%S)"
            if ! ssh-keygen -q -t ed25519 -N "" -C "oracle-ampere" -f "$kpath" </dev/null; then
                echo -e "${RED}Не удалось создать ключ (нужен ssh-keygen: apt install openssh-client).${NC}"; return 1
            fi
            chmod 600 "$kpath"
            KEY_TEXT=$(cat "${kpath}.pub")
            SSH_MODE="создана новая пара (закрытый ключ: ${kpath})"
            echo -e "${GREEN}Пара создана.${NC} Закрытый ключ лежит на ЭТОМ сервере: ${kpath}"
            echo "Он нужен вам для входа на новый сервер. Сохраните его себе (иначе вход будет невозможен)."
            if yn_d "Показать закрытый ключ на экране, чтобы скопировать?" y; then
                echo "----- скопируйте всё, включая строки BEGIN и END, в файл на своём компьютере -----"
                cat "$kpath"
                echo "-----------------------------------------------------------------------------"
            fi
            ;;
        2)
            local pf
            read -u 3 -rp "Путь к файлу открытого ключа (.pub) на этом сервере: " pf || return 1
            pf="${pf/#\~/$HOME}"
            if [[ ! -f "$pf" ]]; then echo -e "${RED}Файл не найден: ${pf}${NC}"; return 1; fi
            KEY_TEXT=$(grep -m1 -E '^(ssh-|ecdsa-|sk-)' "$pf")
            SSH_MODE="файл ${pf}"
            ;;
        3)
            while IFS= read -r k; do
                [[ -z "$k" ]] && continue
                key_rows+="$(awk '{print $1 "\t" substr($2,1,12) "..." substr($2,length($2)-5) "\t" $3}' <<< "$k")"$'\n'
            done <<< "$keys"
            if [[ -n "$key_rows" ]]; then
                echo "Найдены публичные ключи на этом сервере (обычно это ключ, которым вы сюда заходите):"
                local with_paste
                with_paste="${key_rows}вставить другой ключ вручную"$'\t\t'
                if pick_from "Какой ключ добавить" 1 <<< "$with_paste"; then
                    if (( PICKED_IDX <= $(grep -c . <<< "${key_rows%$'\n'}") )); then
                        KEY_TEXT=$(grep -v '^$' <<< "$keys" | sed -n "${PICKED_IDX}p")
                        SSH_MODE="ключ с этого сервера"
                    fi
                fi
            fi
            if [[ -z "$KEY_TEXT" ]]; then
                echo "Вставьте открытый ключ одной строкой (начинается с ssh-ed25519 или ssh-rsa):"
                read -u 3 -r KEY_TEXT || return 1
                SSH_MODE="вставлен вручную"
            fi
            ;;
        4)
            echo -e "${RED}Без ключа на сервер Ubuntu нельзя будет войти (пароля нет), только пересоздав сервер.${NC}"
            yn_d "Точно создать без ключей SSH?" n || return 1
            SSH_MODE="ключей нет"
            ;;
    esac
    if [[ "$ssh_choice" != "4" ]]; then
        if [[ ! "$KEY_TEXT" =~ ^(ssh-|ecdsa-|sk-) ]]; then
            echo -e "${RED}Это не похоже на открытый SSH-ключ.${NC}"
            return 1
        fi
        ( umask 022; echo "$KEY_TEXT" > "$keyfile_path" )
    else
        rm -f "$keyfile_path"
    fi

    # ---------- Шаг 5. Хранилище
    echo -e "\n${GREEN}━━━ 5. Хранилище ━━━${NC}"
    echo "  Загрузочный том: по умолчанию около 47 ГБ. В Always Free на ВСЕ диски вместе 200 ГБ."
    echo "  Занято дисками в аккаунте: ${u_boot} ГБ (например, ваш Micro-сервер), свободно примерно ${free_boot} ГБ."
    local BOOT="" boot_note="по умолчанию (около 47 ГБ)"
    if yn_d "Указать размер пользовательского загрузочного тома?" n; then
        local bmax=$free_boot; (( bmax > 200 )) && bmax=200
        if (( bmax < 50 )); then
            echo -e "${YELLOW}Свободного места меньше 50 ГБ, пользовательский размер недоступен: будет по умолчанию.${NC}"
        else
            ask_number "Размер загрузочного тома, ГБ (50-${bmax})" "$bmax" 50 "$bmax" || return 1
            BOOT="$ANSWER"; boot_note="${BOOT} ГБ"
        fi
    fi
    echo "  Производительность тома: сбалансированная (бесплатно; более высокая платная, не предлагается)."
    local IN_TRANSIT="true"
    if yn_d "Использовать шифрование при пересылке?" y; then IN_TRANSIT="true"; else IN_TRANSIT="false"; fi

    if [[ "$mode" == "manual" ]]; then
        manual_launch "$ads" "$comp" "$SHAPE" "$IMAGE_ID" "$SUBNET_ID" "$ASSIGN_IP" "$NAME" "$([[ "$ssh_choice" == "4" ]] && echo '' || echo "$keyfile_path")" "$BOOT" "$IN_TRANSIT" "$OCPU" "$MEM"
        local mrc=$?
        rm -f "$keyfile_path"
        return $mrc
    fi

    # ---------- Параметры скрипта (не из консоли)
    echo -e "\n${GREEN}━━━ Как будут идти попытки ━━━${NC}"
    local INTERVAL=180
    echo "Настраивать ничего не нужно, всё работает автоматически:"
    echo "  • скрипт по очереди пробует создать сервер во ВСЕХ доменах доступности вашего региона;"
    echo "  • каждый запрос к Oracle занимает 1-2 минуты (утилита oci сама несколько раз повторяет запрос);"
    echo "  • после обхода всех доменов пауза около 3 минут, затем новый круг;"
    echo "  • в итоге каждый домен проверяется примерно раз в 8 минут, круглосуточно, в том числе после перезагрузок сервера;"
    echo "  • если Oracle ответит «слишком много запросов», скрипт сам подождёт 10 минут."
    echo "  Темп умеренный: если запросов станет слишком много, Oracle лишь притормаживает ответы, а скрипт сам делает паузу."

    # Telegram
    local TG_TOKEN="" TG_CHAT=""
    setup_telegram

    ( umask 077
      {
        echo "REGION=$(printf '%q' "$region")"
        echo "TENANCY=$(printf '%q' "$tenancy")"
        echo "COMPARTMENT=$(printf '%q' "$comp")"
        echo "ADS=$(printf '%q' "$ads")"
        echo "SHAPE=$SHAPE"
        echo "SUBNET_ID=$(printf '%q' "$SUBNET_ID")"
        echo "SUBNET_NAME=$(printf '%q' "$SUBNET_NAME")"
        echo "ASSIGN_IP=$ASSIGN_IP"
        echo "IMAGE_ID=$(printf '%q' "$IMAGE_ID")"
        echo "IMAGE_NAME=$(printf '%q' "$IMAGE_NAME")"
        echo "OCPU=$OCPU"
        echo "MEM=$MEM"
        echo "BOOT=$BOOT"
        echo "IN_TRANSIT=$IN_TRANSIT"
        echo "NAME=$(printf '%q' "$NAME")"
        echo "KEYFILE=$([[ "$ssh_choice" == "4" ]] && echo '' || printf '%q' "$keyfile_path")"
        echo "SSH_MODE=$(printf '%q' "$SSH_MODE")"
        echo "INTERVAL=$INTERVAL"
        echo "TG_TOKEN=$(printf '%q' "$TG_TOKEN")"
        echo "TG_CHAT=$(printf '%q' "$TG_CHAT")"
      } > "$CONF_FILE" )
    chmod 600 "$CONF_FILE"
    install_worker
    rm -f "$DONE_FILE"
    echo -e "\n${GREEN}✅ Параметры сохранены.${NC}"
    show_plan
    if systemctl is-active --quiet "$SVC"; then
        echo -e "${YELLOW}Фоновый поиск сейчас работает: он будет перезапущен, чтобы применить новые настройки.${NC}"
        systemctl restart "$SVC" &>/dev/null
        sleep 2
        if systemctl is-active --quiet "$SVC"; then
            echo -e "${GREEN}✅ Фоновый поиск перезапущен и работает с новыми настройками.${NC}"
        else
            echo -e "${RED}После перезапуска служба не стартовала. Запустите её в пункте 2 или посмотрите: journalctl -u ${SVC} -n 20${NC}"
        fi
        return 0
    fi
    echo
    if yn_d "Запустить поиск в фоне сейчас?" y; then
        start_retry
    else
        echo "Запустить можно позже: пункт 2, «Запустить поиск»."
    fi
}

show_plan() {
    [[ -f "$CONF_FILE" ]] || { echo -e "${YELLOW}Параметры ещё не заданы (пункт 2).${NC}"; return; }
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    echo -e "\n${YELLOW}Что будет создано:${NC}"
    echo "  Имя:            ${NAME}"
    echo "  Образ:          ${IMAGE_NAME}"
    echo "  Конфигурация:   $([[ "$SHAPE" == *Micro* ]] && echo Micro || echo Ampere) ${SHAPE} (Always Free): ${OCPU} ЦП, ${MEM} ГБ памяти"
    echo "  Безопасность:   защищённый экземпляр не используется"
    echo "  Подсеть:        ${SUBNET_NAME}"
    echo "  Публичный IPv4: $([[ "${ASSIGN_IP:-true}" == "true" ]] && echo назначить || echo 'не назначать')"
    echo "  Ключи SSH:      ${SSH_MODE:-$([[ -n "$KEYFILE" ]] && echo 'есть' || echo 'нет')}"
    echo "  Загрузочный том: $([[ -n "$BOOT" ]] && echo "${BOOT} ГБ" || echo 'по умолчанию (около 47 ГБ)'), сбалансированный"
    echo "  Шифрование при пересылке: $([[ "${IN_TRANSIT:-}" == "true" ]] && echo включено || echo выключено)"
    echo "  Регион:         ${REGION}, домены: ${ADS}"
    echo "  Попытки:        по кругу по всем доменам, каждый домен примерно раз в 8 минут"
    echo "  Telegram:       $([[ -n "$TG_TOKEN" ]] && echo включён || echo выключен)"
}

# ---------------------------------------------------------------- ФОНОВЫЙ РАБОТНИК

install_worker() {
    cat > "${WORKER}.new" <<'WEOF'
#!/bin/bash
# Повторяет попытки создать сервер Oracle, пока не получится. ONCE=1 - одна попытка и выход.
CONF_FILE="/etc/oracle-arm.conf"
LOG="/var/log/oracle-arm.log"
DONE_FILE="/var/lib/oracle-arm.done"
OCI="/opt/oci-cli/bin/oci"
SHAPE="VM.Standard.A1.Flex"
export SUPPRESS_LABEL_WARNING=True
source "$CONF_FILE" || exit 2

log() {
    echo "$(date '+%F %T') $*" | tee -a "$LOG"
    [[ -f "$LOG" && $(stat -c %s "$LOG") -gt 2000000 ]] && tail -n 500 "$LOG" > "${LOG}.tmp" && cat "${LOG}.tmp" > "$LOG" && rm -f "${LOG}.tmp"
}
notify() {
    [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]] || return 0
    curl -s --max-time 15 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" --data-urlencode "text=$1" >/dev/null 2>&1
}
finish() {  # finish код "сообщение": останавливает службу, чтобы она не стартовала после перезагрузки
    log "$2"
    notify "Oracle: $2"
    systemctl disable "oracle-arm-retry" >/dev/null 2>&1
    [[ "$1" == "0" ]] && date > "$DONE_FILE"
    exit "$1"
}

exists_already() {
    "$OCI" compute instance list --compartment-id "$COMPARTMENT" --all 2>/dev/null \
        | jq -e --arg n "$NAME" '[.data[] | select(.["display-name"]==$n and .["lifecycle-state"]!="TERMINATED" and .["lifecycle-state"]!="TERMINATING")] | length > 0' >/dev/null 2>&1
}

public_ip() {  # public_ip ID: ждём до 5 минут, пока появится адрес
    local id="$1" i ip
    for i in $(seq 1 30); do
        ip=$("$OCI" compute instance list-vnics --instance-id "$id" 2>/dev/null | jq -r '.data[0]["public-ip"] // empty')
        [[ -n "$ip" ]] && { echo "$ip"; return; }
        sleep 10
    done
}

attempt=0; unknown=0
while true; do
    attempt=$((attempt + 1))
    if exists_already; then
        finish 0 "Сервер ${NAME} уже существует в аккаунте. Повторные попытки остановлены."
    fi

    lim=0; adn=0
    for ad in $ADS; do
        adn=$((adn + 1))
        args=(compute instance launch
            --availability-domain "$ad" --compartment-id "$COMPARTMENT"
            --shape "$SHAPE"
            --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID"
            --assign-public-ip "${ASSIGN_IP:-true}" --display-name "$NAME")
        [[ "$SHAPE" == *.Flex ]] && args+=(--shape-config "{\"ocpus\":${OCPU},\"memoryInGBs\":${MEM}}")
        [[ -n "$KEYFILE" ]] && args+=(--ssh-authorized-keys-file "$KEYFILE")
        [[ -n "$BOOT" ]] && args+=(--boot-volume-size-in-gbs "$BOOT")
        [[ "$IN_TRANSIT" == "true" ]] && args+=(--is-pv-encryption-in-transit-enabled true)
        out=$("$OCI" "${args[@]}" 2>&1)
        rc=$?
        if (( rc == 0 )); then
            id=$(jq -r '.data.id // empty' <<< "$out" 2>/dev/null)
            log "Сервер создан (попытка ${attempt}, ${ad}). Жду внешний IP..."
            ip=""
            [[ -n "$id" && "${ASSIGN_IP:-true}" == "true" ]] && ip=$(public_ip "$id")
            finish 0 "✅ Сервер ${NAME} создан! Внешний IP: ${ip:-смотрите в консоли}. Вход: ssh ubuntu@${ip:-IP} (ключ тот, что выбрали). Попыток: ${attempt}."
        fi

        if grep -qiE 'out of (host )?capacity|OutOfHostCapacity' <<< "$out"; then
            log "попытка ${attempt}, ${ad}: нет места (Out of host capacity)"
            unknown=0
        elif grep -qiE 'TooManyRequests|"status": 429|too many requests' <<< "$out"; then
            log "попытка ${attempt}: Oracle просит притормозить (429), жду 10 минут"
            [[ -n "$ONCE" ]] || sleep 600
            break
        elif grep -qiE 'LimitExceeded' <<< "$out"; then
            lim=$((lim + 1))
            log "попытка ${attempt}, ${ad}: в этом домене лимит не позволяет создать сервер (LimitExceeded): $(tr '\n' ' ' <<< "$out" | grep -oiE '"message": *"[^"]*"' | head -n 1 | cut -c1-200)"
        elif grep -qiE 'NotAuthenticated|"status": 401|NotAuthorizedOrNotFound|"status": 404' <<< "$out"; then
            finish 4 "Ошибка доступа или неверные параметры (ключ не принят, нет прав, неверная подсеть/образ). Проверьте подключение (пункт 1) и настройки поиска (пункт 2). Попытки остановлены."
        else
            unknown=$((unknown + 1))
            log "попытка ${attempt}, ${ad}: неизвестная ошибка (${unknown}/10): $(tr '\n' ' ' <<< "$out" | cut -c1-300)"
            (( unknown >= 10 )) && finish 5 "10 неизвестных ошибок подряд. Попытки остановлены, смотрите журнал: ${LOG}"
        fi
    done

    if (( adn > 0 && lim == adn )); then
        finish 3 "Лимит Always Free не позволяет создать такой сервер ни в одном домене (LimitExceeded): уже созданы серверы этого типа на весь лимит. Попытки остановлены."
    fi
    [[ -n "$ONCE" ]] && exit 1
    sleep $((INTERVAL + RANDOM % 30))
done
WEOF
    chmod 755 "${WORKER}.new"
    mv -f "${WORKER}.new" "$WORKER"

    cat > "$UNIT" <<UEOF
[Unit]
Description=Повторные попытки создать сервер Oracle (Ampere)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WORKER}
Restart=no

[Install]
WantedBy=multi-user.target
UEOF
    systemctl daemon-reload
}

# ---------------------------------------------------------------- УПРАВЛЕНИЕ

start_retry() {
    [[ -f "$CONF_FILE" && -x "$WORKER" ]] || { echo -e "${RED}Сначала задайте параметры поиска (пункт 2).${NC}"; return 1; }
    if systemctl is-active --quiet "$SVC"; then
        echo -e "${GREEN}Уже работает.${NC} (Если вы обновили скрипт и хотите применить новую версию: остановите поиск и запустите снова.)"
        return 0
    fi
    install_worker   # всегда свежая версия рабочего скрипта
    rm -f "$DONE_FILE"
    systemctl enable --now "$SVC" &>/dev/null
    sleep 2
    if systemctl is-active --quiet "$SVC"; then
        echo -e "${GREEN}✅ Фоновые попытки запущены. Можно закрыть терминал и выключить свой компьютер.${NC}"
    else
        echo -e "${RED}Не запустилось. Смотрите: journalctl -u ${SVC} -n 20${NC}"
    fi
}

stop_retry() {
    systemctl disable --now "$SVC" &>/dev/null
    echo -e "${GREEN}Фоновые попытки остановлены.${NC}"
}

show_status() {
    show_plan
    echo -e "\n${YELLOW}📊 [СТАТУС]${NC}"
    echo "Утилита oci:   $([[ -x "$OCI_BIN" ]] && echo установлена || echo 'не установлена')"
    echo "Доступ к Oracle: $(oci_check && echo "работает (регион $(cfg_value region))" || echo 'не настроен')"
    echo "Параметры:     $([[ -f "$CONF_FILE" ]] && echo задан || echo 'не заданы')"
    echo "Фоновые попытки: $(systemctl is-active "$SVC" 2>/dev/null) (автозапуск: $(systemctl is-enabled "$SVC" 2>/dev/null))"
    if [[ -f "$DONE_FILE" ]]; then echo -e "${GREEN}Сервер создан: $(cat "$DONE_FILE")${NC}"; fi
    if [[ -f "$LOG" ]]; then
        echo "Неудачных попыток (нет места): $(grep -c "нет места" "$LOG")"
        echo "Последние записи:"
        tail -n 8 "$LOG" | sed 's/^/   /'
    fi
}

# ---------------------------------------------------------------- СЕРВЕРЫ В ORACLE

SRV_COMP=""; SRV_ADS=""
SRV_N=0
SRV_ID=(); SRV_NAME=(); SRV_SHAPE=(); SRV_STATE=(); SRV_CPU=(); SRV_MEM=(); SRV_AD=(); SRV_CREATED=(); SRV_BVID=(); SRV_BVSIZE=()

load_servers() {  # читает серверы аккаунта в массивы SRV_*
    install_cli || return 1
    oci_check || { echo -e "${RED}Сначала подключите аккаунт Oracle (пункт 1).${NC}"; return 1; }
    local insts ad bv_tsv="" rows id name shape state cpu mem ad2 created bvid
    SRV_COMP=$(cfg_value tenancy)
    SRV_ADS=$(oci_cmd iam availability-domain list --compartment-id "$SRV_COMP" 2>/dev/null | jq -r '.data[].name' | tr '\n' ' ')
    insts=$(oci_cmd compute instance list --compartment-id "$SRV_COMP" --all 2>/dev/null)
    if ! jq -e '.data' >/dev/null 2>&1 <<< "$insts"; then
        echo -e "${RED}Не удалось получить список серверов. Проверьте доступ (пункт 1).${NC}"
        return 1
    fi
    for ad in $SRV_ADS; do
        bv_tsv+=$(oci_cmd bv boot-volume list --availability-domain "$ad" --compartment-id "$SRV_COMP" --all 2>/dev/null \
            | jq -r '.data[]? | [.id, (.["size-in-gbs"] // 0 | tostring)] | @tsv')$'\n'
    done
    SRV_N=0; SRV_ID=(); SRV_NAME=(); SRV_SHAPE=(); SRV_STATE=(); SRV_CPU=(); SRV_MEM=(); SRV_AD=(); SRV_CREATED=(); SRV_BVID=(); SRV_BVSIZE=()
    rows=$(jq -r '.data[] | select(.["lifecycle-state"]!="TERMINATED") | [.id, .["display-name"], .shape, .["lifecycle-state"], ((.["shape-config"].ocpus // 0) | tostring), ((.["shape-config"]["memory-in-gbs"] // 0) | tostring), .["availability-domain"], ((.["time-created"] // "") | .[0:10])] | @tsv' <<< "$insts")
    while IFS=$'\t' read -r id name shape state cpu mem ad2 created; do
        [[ -z "$id" ]] && continue
        bvid=$(oci_cmd compute boot-volume-attachment list --availability-domain "$ad2" --compartment-id "$SRV_COMP" --instance-id "$id" </dev/null 2>/dev/null \
            | jq -r '[.data[]? | select(.["lifecycle-state"]=="ATTACHED")][0]["boot-volume-id"] // empty')
        SRV_ID+=("$id"); SRV_NAME+=("$name"); SRV_SHAPE+=("$shape"); SRV_STATE+=("$state")
        SRV_CPU+=("${cpu%.0}"); SRV_MEM+=("${mem%.0}"); SRV_AD+=("$ad2"); SRV_CREATED+=("$created")
        SRV_BVID+=("$bvid")
        SRV_BVSIZE+=("$([[ -n "$bvid" ]] && awk -F'\t' -v i="$bvid" '$1==i {print $2; exit}' <<< "$bv_tsv")")
        SRV_N=$((SRV_N + 1))
    done <<< "$rows"
    return 0
}

print_servers() {
    local i ip kind mark
    if (( SRV_N == 0 )); then echo "В аккаунте нет ни одного сервера."; return; fi
    for ((i = 0; i < SRV_N; i++)); do
        case "${SRV_SHAPE[i]}" in
            VM.Standard.A1.Flex) kind="Ampere (ARM)" ;;
            VM.Standard.E2.1.Micro) kind="Micro (AMD)" ;;
            *) kind="${SRV_SHAPE[i]} (не Always Free)" ;;
        esac
        case "${SRV_STATE[i]}" in
            RUNNING) mark="${GREEN}работает ✅${NC}" ;;
            STOPPED) mark="${YELLOW}остановлен ⏸${NC}" ;;
            *) mark="${YELLOW}${SRV_STATE[i]}${NC}" ;;
        esac
        ip="-"
        if [[ "${SRV_STATE[i]}" == "RUNNING" ]]; then
            ip=$(oci_cmd compute instance list-vnics --instance-id "${SRV_ID[i]}" 2>/dev/null | jq -r '.data[0]["public-ip"] // "нет"')
        fi
        echo -e "\n$((i + 1)). ${YELLOW}${SRV_NAME[i]}${NC}  ${kind}  ${mark}"
        echo "   ЦП: ${SRV_CPU[i]}, память: ${SRV_MEM[i]} ГБ, диск: ${SRV_BVSIZE[i]:-?} ГБ"
        echo "   Внешний IP: ${ip},  домен: ${SRV_AD[i]##*:},  создан: ${SRV_CREATED[i]}"
    done
}

print_limits() {
    local used u_cpu u_mem u_boot u_micro
    used=$(used_resources "$SRV_COMP" "$SRV_ADS")
    read -r u_cpu u_mem u_boot u_micro <<< "$used"
    echo -e "\n${YELLOW}Лимит Always Free (занято из доступного):${NC}"
    echo "  Ampere:  ${u_cpu} из 4 ЦП,  ${u_mem} из 24 ГБ памяти"
    echo "  Micro:   ${u_micro} из 2 серверов"
    echo "  Диски:   ${u_boot} из 200 ГБ (все загрузочные тома аккаунта)"
    LIM_BOOT="$u_boot"
}

# Изменение ЦП и памяти Ampere (индекс сервера в $1)
edit_cpu_mem() {
    local i="$1" j oc=0 om=0 maxc maxm ncpu nmem
    if [[ "${SRV_SHAPE[i]}" != "VM.Standard.A1.Flex" ]]; then
        echo -e "${YELLOW}У этого типа сервера (${SRV_SHAPE[i]}) ЦП и память фиксированные, изменить их нельзя.${NC}"
        return
    fi
    for ((j = 0; j < SRV_N; j++)); do
        [[ "$j" == "$i" ]] && continue
        if [[ "${SRV_SHAPE[j]}" == "VM.Standard.A1.Flex" ]]; then oc=$((oc + ${SRV_CPU[j]%.*})); om=$((om + ${SRV_MEM[j]%.*})); fi
    done
    maxc=$((4 - oc)); maxm=$((24 - om))
    (( maxc < 1 || maxm < 1 )) && { echo -e "${RED}Остальные Ampere-серверы занимают весь лимит: увеличить нечего.${NC}"; return; }
    echo -e "\nСейчас: ${SRV_CPU[i]} ЦП, ${SRV_MEM[i]} ГБ. Доступно этому серверу в рамках Always Free: до ${maxc} ЦП и ${maxm} ГБ."
    ask_number "Новое количество ЦП (1-${maxc})" "${SRV_CPU[i]}" 1 "$maxc" || return; ncpu="$ANSWER"
    local mdef="${SRV_MEM[i]}"; (( mdef < ncpu )) && mdef=$ncpu; (( mdef > maxm )) && mdef=$maxm
    ask_number "Новый объём памяти, ГБ (${ncpu}-${maxm})" "$mdef" "$ncpu" "$maxm" || return; nmem="$ANSWER"
    if [[ "$ncpu" == "${SRV_CPU[i]}" && "$nmem" == "${SRV_MEM[i]}" ]]; then echo "Без изменений."; return; fi
    echo -e "${YELLOW}Oracle применит изменение сам. Если нужно, сервер будет перезагружен (простой 1-3 минуты). Данные на диске сохранятся.${NC}"
    yn_d "Изменить «${SRV_NAME[i]}» на ${ncpu} ЦП и ${nmem} ГБ?" y || { echo "Отменено."; return; }
    local out
    if out=$(oci_cmd compute instance update --instance-id "${SRV_ID[i]}" --shape-config "{\"ocpus\":${ncpu},\"memoryInGBs\":${nmem}}" --update-operation-constraint ALLOW_DOWNTIME --force 2>&1); then
        echo -e "${GREEN}✅ Запрос принят: ${ncpu} ЦП, ${nmem} ГБ. Изменение применяется в течение пары минут; новый размер виден в списке серверов.${NC}"
    else
        echo -e "${RED}Не удалось изменить:${NC} $(tr '\n' ' ' <<< "$out" | grep -v 'Warning: To increase' | cut -c1-400)"
    fi
}

# Увеличение загрузочного диска (диск можно только увеличивать)
grow_disk() {
    local i="$1" cur max nsize out
    cur="${SRV_BVSIZE[i]}"
    if [[ -z "${SRV_BVID[i]}" || -z "$cur" ]]; then echo -e "${RED}Не удалось определить загрузочный диск этого сервера.${NC}"; return; fi
    print_limits >/dev/null
    max=$((200 - LIM_BOOT + cur))
    (( max > 200 )) && max=200
    echo -e "\nСейчас диск ${cur} ГБ. В рамках Always Free этому серверу можно довести до ${max} ГБ."
    echo -e "${YELLOW}Диск можно только УВЕЛИЧИВАТЬ: уменьшить размер в Oracle нельзя.${NC}"
    (( max <= cur )) && { echo "Увеличивать некуда: общий лимит дисков исчерпан."; return; }
    ask_number "Новый размер диска, ГБ ($((cur + 1))-${max})" "$max" $((cur + 1)) "$max" || return; nsize="$ANSWER"
    echo "После увеличения перезагрузите сервер: Ubuntu при старте обычно сама расширяет корневой раздел."
    echo "Проверить на самом сервере: df -h /   (если место не прибавилось, напишите мне, подскажу команды)."
    yn_d "Увеличить диск «${SRV_NAME[i]}» с ${cur} до ${nsize} ГБ?" y || { echo "Отменено."; return; }
    if out=$(oci_cmd bv boot-volume update --boot-volume-id "${SRV_BVID[i]}" --size-in-gbs "$nsize" --force 2>&1); then
        echo -e "${GREEN}✅ Запрос принят: диск ${nsize} ГБ. Перезагрузите сервер, чтобы система увидела новый размер.${NC}"
    else
        echo -e "${RED}Не удалось увеличить:${NC} $(tr '\n' ' ' <<< "$out" | cut -c1-400)"
    fi
}

# Удаление сервера
delete_server() {
    local i="$1" typed keep="false" out
    echo -e "\n${RED}⚠️ УДАЛЕНИЕ СЕРВЕРА «${SRV_NAME[i]}» нельзя отменить. Все данные на нём пропадут.${NC}"
    echo "Если там что-то важное, сначала скопируйте это себе."
    if yn_d "Удалить вместе с загрузочным диском? (если оставить диск, он продолжит занимать ваш лимит 200 ГБ)" y; then keep="false"; else keep="true"; fi
    read -rp "Для подтверждения введите имя сервера (${SRV_NAME[i]}) или Enter для отмены: " typed || return
    if [[ "$typed" != "${SRV_NAME[i]}" ]]; then echo "Имя не совпало или пусто: удаление отменено."; return; fi
    if out=$(oci_cmd compute instance terminate --instance-id "${SRV_ID[i]}" --preserve-boot-volume "$keep" --force 2>&1); then
        echo -e "${GREEN}✅ Сервер «${SRV_NAME[i]}» удаляется (займёт около минуты). Лимит освободится после завершения.${NC}"
    else
        echo -e "${RED}Не удалось удалить:${NC} $(tr '\n' ' ' <<< "$out" | cut -c1-400)"
    fi
}

manage_servers() {
    local k c
    while true; do
        load_servers || return 1
        echo -e "\n${YELLOW}🖥️ [СЕРВЕРЫ В ORACLE]${NC}"
        print_servers
        print_limits
        (( SRV_N == 0 )) && return 0
        echo
        read -rp "Номер сервера для управления (Enter = назад): " k || return 0
        [[ -z "$k" ]] && return 0
        if [[ ! "$k" =~ ^[0-9]+$ ]] || (( k < 1 || k > SRV_N )); then echo -e "${RED}Нет такого номера.${NC}"; continue; fi
        k=$((k - 1))
        while true; do
            echo -e "\n${YELLOW}Сервер «${SRV_NAME[k]}»${NC}"
            echo "1. Изменить количество ЦП и память (только Ampere)"
            echo "2. Увеличить размер диска"
            echo "3. Удалить сервер"
            echo "0. Назад к списку"
            read -rp "Выберите [0-3]: " c || return 0
            case "$c" in
                1) edit_cpu_mem "$k"; break ;;
                2) grow_disk "$k"; break ;;
                3) delete_server "$k"; break ;;
                0|"") break ;;
                *) echo -e "${RED}Неверный пункт.${NC}" ;;
            esac
        done
    done
}

# ---------------------------------------------------------------- УДАЛЕНИЕ

uninstall_all() {
    echo -e "\n${YELLOW}🗑️ [УДАЛЕНИЕ]${NC}"
    local has_svc=0 has_files=0 has_cli=0 pkgs="" pkg
    { [[ -f "$UNIT" ]] || [[ -f "$WORKER" ]]; } && has_svc=1
    { [[ -f "$CONF_FILE" ]] || [[ -f "$KEY_COPY" ]] || [[ -f "$LOG" ]] || [[ -f "$DONE_FILE" ]]; } && has_files=1
    [[ -n "$OCI_INSTALLED" && -d "$OCI_VENV" ]] && has_cli=1
    for pkg in $PKGS_ADDED; do pkg_installed "$pkg" && pkgs="${pkgs:+$pkgs }$pkg"; done

    if (( has_svc + has_files + has_cli == 0 )) && [[ -z "$pkgs" ]]; then
        echo -e "${GREEN}Удалять нечего.${NC}"
        rm -f "$STATE_FILE"
        return
    fi
    echo "Найдено:"
    (( has_svc ))   && echo "  • служба и скрипт повторных попыток"
    (( has_files )) && echo "  • настройки, копия SSH-ключа, журнал (${CONF_FILE}, ${KEY_COPY}, ${LOG})"
    (( has_cli ))   && echo "  • утилита oci (${OCI_VENV})"
    [[ -n "$pkgs" ]] && echo "  • пакеты, поставленные скриптом: ${pkgs}"
    echo "Ключ доступа к Oracle (~/.oci) скрипт НЕ удаляет: это ваш ключ. Отзовите его в консоли сами, если он больше не нужен."
    echo
    yn "Удалить всё перечисленное?" || { echo "Отменено."; return; }

    if (( has_svc )); then
        systemctl disable --now "$SVC" &>/dev/null
        rm -f "$UNIT" "$WORKER"
        systemctl daemon-reload
        systemctl reset-failed "$SVC" 2>/dev/null
    fi
    if (( has_files )); then
        rm -f "$CONF_FILE" "$KEY_COPY" "$LOG" "${LOG}.tmp" "$DONE_FILE"
    fi
    if (( has_cli )); then
        rm -f "$OCI_LINK"
        rm -rf "$OCI_VENV"
        OCI_INSTALLED=""
    fi
    if [[ -n "$pkgs" ]]; then
        if yn "Удалить пакеты (${pkgs})?"; then
            # shellcheck disable=SC2086
            apt-get purge -y $pkgs
            PKGS_ADDED=""
        fi
    fi
    rm -f "$STATE_FILE"
    [[ -n "$PKGS_ADDED" ]] && save_state
    echo -e "\n${GREEN}✅ Готово.${NC}"
}

# ---------------------------------------------------------------- МЕНЮ

ACCT_OK=0
refresh_acct() { if oci_check; then ACCT_OK=1; else ACCT_OK=0; fi; }

connect_oracle() { configure_oci; refresh_acct; }

search_summary() {  # "Ampere 1 ЦП / 6 ГБ" по сохранённым параметрам
    [[ -f "$CONF_FILE" ]] || return
    ( source "$CONF_FILE" 2>/dev/null
      if [[ "${SHAPE:-VM.Standard.A1.Flex}" == *Micro* ]]; then echo "Micro"; else echo "Ampere ${OCPU} ЦП / ${MEM} ГБ"; fi )
}

print_home() {
    local acct search hint
    echo -e "\n${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}   Oracle Cloud: автосоздание сервера (Ampere / Micro)${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    if (( ACCT_OK )); then acct="${GREEN}подключён${NC} (регион $(cfg_value region))"; else acct="${RED}не подключён${NC}"; fi
    if [[ -f "$DONE_FILE" ]]; then
        search="${GREEN}сервер создан ✅${NC} ($(search_summary))"
        hint="управлять сервером можно в пункте 3."
    elif systemctl is-active --quiet "$SVC"; then
        search="${GREEN}работает${NC} ($(search_summary))"
        hint="поиск идёт сам, терминал можно закрыть."
    elif [[ -f "$CONF_FILE" ]]; then
        search="${YELLOW}остановлен${NC} ($(search_summary))"
        hint="пункт 2 → «Запустить поиск»."
    else
        search="${YELLOW}не настроен${NC}"
        hint="пункт 2 → «Настройка параметров поиска»."
    fi
    (( ACCT_OK )) || hint="пункт 1 (подключить аккаунт Oracle)."
    echo -e "Аккаунт Oracle: ${acct}"
    echo -e "Автопоиск:      ${search}"
    echo -e "Следующий шаг:  ${hint}"
    echo -e "${YELLOW}==================================================${NC}"
}

search_menu() {
    local c
    while true; do
        echo -e "\n${YELLOW}=== Автопоиск места (в фоне) ===${NC}"
        echo "1. Настройка параметров поиска"
        if systemctl is-active --quiet "$SVC"; then
            echo "2. Остановить поиск"
        else
            echo "2. Запустить поиск"
        fi
        echo "3. Статус и журнал"
        echo "0. Назад"
        read -rp "Выберите [0-3]: " c || return
        case "$c" in
            1) setup_task ;;
            2) if systemctl is-active --quiet "$SVC"; then stop_retry; else start_retry; fi ;;
            3) show_status ;;
            0|"") return ;;
            *) echo -e "${RED}Неверный пункт.${NC}" ;;
        esac
    done
}

servers_menu() {
    local c
    while true; do
        echo -e "\n${YELLOW}=== Серверы в Oracle ===${NC}"
        echo "1. Список и управление (изменить ЦП и память, увеличить диск, удалить)"
        echo "2. Создать сервер вручную (поиск в фоне не затрагивается)"
        echo "0. Назад"
        read -rp "Выберите [0-2]: " c || return
        case "$c" in
            1) manage_servers ;;
            2) setup_task manual ;;
            0|"") return ;;
            *) echo -e "${RED}Неверный пункт.${NC}" ;;
        esac
    done
}

first_run_wizard() {
    echo -e "\n${YELLOW}Похоже, вы запускаете скрипт впервые.${NC}"
    echo "Могу провести по шагам: 1) подключить аккаунт Oracle, 2) выбрать, какой сервер искать, 3) запустить поиск в фоне."
    yn_d "Пройти настройку по шагам?" y || return 0
    echo -e "\n${GREEN}━━━ Шаг 1 из 3: подключение к Oracle ━━━${NC}"
    connect_oracle
    if (( ! ACCT_OK )); then
        echo -e "${YELLOW}Подключение не завершено. Вернёмся в меню: повторить можно в пункте 1.${NC}"
        return 0
    fi
    echo -e "\n${GREEN}━━━ Шаг 2 из 3: что искать (в конце будет шаг 3: запуск) ━━━${NC}"
    setup_task
}

refresh_acct
if (( ! ACCT_OK )) && [[ ! -f "$CONF_FILE" ]]; then first_run_wizard; fi

while true; do
    print_home
    echo "1. Подключение к Oracle (утилита и аккаунт)"
    echo "2. Автопоиск места (настроить, запустить, статус)"
    echo "3. Мои серверы (список, изменить, удалить, создать вручную)"
    echo "4. Удаление скрипта и всего, что он поставил"
    echo "0. Выход"
    read -rp "Выберите действие [0-4]: " choice || exit 0

    case $choice in
        1) connect_oracle ;;
        2) search_menu ;;
        3) servers_menu ;;
        4) uninstall_all ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный пункт меню.${NC}" ;;
    esac
done
