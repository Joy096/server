# Цвета для сообщений
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[1;33m'
plain='\033[0m'

LOGI() { echo -e "✅ ${green}$* ${plain}"; }
LOGE() { echo -e "❌ ${red}$* ${plain}"; }
LOGD() { echo -e "   ${yellow}$* ${plain}"; }

# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
HOOK_SCRIPT_PATH="/root/renew_hook.sh"
CERT_BASE_DIR="/root/my_cert"

install_acme() {
    echo ""
    LOGI "Обновление системы и установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt update >/dev/null 2>&1 && apt upgrade -y >/dev/null 2>&1 && apt autoremove -y >/dev/null 2>&1 && apt clean >/dev/null 2>&1

    if ! command -v curl &>/dev/null; then
        LOGD "curl не найден. Устанавливаем..."
        apt-get update >/dev/null 2>&1 && apt-get install -y curl >/dev/null 2>&1
        if [[ $? -ne 0 ]]; then LOGE "Ошибка установки curl"; return 1; fi
    fi

    if [ -f ~/.acme.sh/acme.sh ]; then
        LOGI "acme.sh уже установлен."
        return 0
    fi

    LOGI "Устанавливаем acme.sh..."
    curl -s https://get.acme.sh | sh
    if [[ $? -ne 0 ]]; then LOGE "Ошибка установки acme.sh"; return 1; fi
    LOGI "acme.sh успешно установлен."
    return 0
}

# --- Очистка ВСЕХ TXT-записей _acme-challenge в зоне deSEC ---
cleanup_desec_txt() {
    local target_domain=$1
    local token=$2

    local root_domain
    root_domain=$(curl -s \
        -H "Authorization: Token ${token}" \
        "https://desec.io/api/v1/domains/" | \
        grep -o '"name":"[^"]*"' | \
        grep -o '"[^"]*"$' | \
        tr -d '"' | \
        while read -r d; do
            if [[ "$target_domain" == "$d" || "$target_domain" == *".$d" ]]; then
                echo "$d"
                break
            fi
        done)

    if [[ -z "$root_domain" ]]; then
        LOGD "Не удалось определить корневую зону для ${target_domain}, пропускаем очистку."
        return
    fi

    LOGI "Очищаем все TXT-записи _acme-challenge в deSEC для зоны ${root_domain}..."

    local rrsets
    rrsets=$(curl -s \
        -H "Authorization: Token ${token}" \
        "https://desec.io/api/v1/domains/${root_domain}/rrsets/" | \
        grep -o '"subname":"_acme-challenge[^"]*"' | \
        grep -o '_acme-challenge[^"]*')

    if [[ -z "$rrsets" ]]; then
        LOGD "Записей _acme-challenge не найдено, очистка не требуется."
        return
    fi

    while IFS= read -r subname; do
        LOGD "Удаляем TXT запись: ${subname}.${root_domain}"
        curl -s -X DELETE \
            -H "Authorization: Token ${token}" \
            "https://desec.io/api/v1/domains/${root_domain}/rrsets/${subname}/TXT/" \
            >/dev/null 2>&1
    done <<< "$rrsets"

    sleep 2
    LOGI "Очистка завершена."
}

# --- Создание CNAME для challenge-alias если её ещё нет (deSEC) ---
ensure_desec_challenge_cname() {
    local subdomain=$1
    local root_domain=$2
    local token=$3

    local sub_part="${subdomain%.${root_domain}}"
    local cname_subname="_acme-challenge.${sub_part}"
    local cname_value="_acme-challenge.${root_domain}."

    LOGI "Проверяем наличие CNAME записи ${cname_subname}.${root_domain} → ${cname_value}..."

    local response
    response=$(curl -s \
        -H "Authorization: Token ${token}" \
        "https://desec.io/api/v1/domains/${root_domain}/rrsets/${cname_subname}/CNAME/")

    if echo "$response" | grep -q '"records":\["'; then
        LOGI "CNAME запись уже существует, пропускаем."
        return 0
    fi

    LOGI "Создаём CNAME запись: ${cname_subname}.${root_domain} → ${cname_value}"
    local create_response
    create_response=$(curl -s -X POST \
        -H "Authorization: Token ${token}" \
        -H "Content-Type: application/json" \
        -d "[{\"subname\":\"${cname_subname}\", \"type\":\"CNAME\", \"records\":[\"${cname_value}\"], \"ttl\":3600}]" \
        "https://desec.io/api/v1/domains/${root_domain}/rrsets/")

    if echo "$create_response" | grep -q '"subname"'; then
        LOGI "CNAME запись успешно создана."
    else
        LOGE "Ошибка создания CNAME записи. Ответ: ${create_response}"
        LOGE "Создайте запись вручную в панели deSEC:"
        LOGE "  Type: CNAME"
        LOGE "  Subname: ${cname_subname}"
        LOGE "  Value: ${cname_value}"
    fi
}

create_renew_hook() {
    local domain=$1
    LOGI "Создаем/Обновляем универсальный hook-скрипт: ${HOOK_SCRIPT_PATH}"
    
    echo "#!/bin/bash" > "${HOOK_SCRIPT_PATH}"
    echo "DOMAIN=\"${domain}\"" >> "${HOOK_SCRIPT_PATH}"
    
    cat << 'EOF' >> "${HOOK_SCRIPT_PATH}"
LOG_FILE="/root/acme_renew.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"; }

log "====== Начинаем развертывание сертификата для домена: ${DOMAIN} ======"
MY_CERT_DIR="/root/my_cert/${DOMAIN}"
NEXTCLOUD_CERT_DIR="/var/snap/nextcloud/current/certs/custom/"
ADGUARD_CERT_DIR="/var/snap/adguard-home/common/certs/"
XUI_CERT_FILE="${MY_CERT_DIR}/fullchain.pem"
XUI_KEY_FILE="${MY_CERT_DIR}/private.key"

log "1. Установка сертификата в ${MY_CERT_DIR}"
mkdir -p "${MY_CERT_DIR}"
/root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --cert-file "${MY_CERT_DIR}/cert.pem" --key-file "${MY_CERT_DIR}/private.key" --fullchain-file "${MY_CERT_DIR}/fullchain.pem" --ca-file "${MY_CERT_DIR}/ca.pem" >> "${LOG_FILE}" 2>&1

if [ -d "/var/snap/nextcloud/" ]; then
    log "2. Обнаружен Nextcloud. Устанавливаем сертификат..."
    mkdir -p "${NEXTCLOUD_CERT_DIR}"
    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --cert-file "${NEXTCLOUD_CERT_DIR}/cert.pem" --key-file "${NEXTCLOUD_CERT_DIR}/private.key" --fullchain-file "${NEXTCLOUD_CERT_DIR}/fullchain.pem" >> "${LOG_FILE}" 2>&1
    
    log "Добавляем ${DOMAIN} в trusted_domains Nextcloud..."
    /snap/bin/nextcloud.occ config:system:set trusted_domains 1 --value="${DOMAIN}" >> "${LOG_FILE}" 2>&1

    log "Прописываем сертификаты в конфигурацию Apache..."
    /snap/bin/nextcloud.enable-https custom "${NEXTCLOUD_CERT_DIR}/cert.pem" "${NEXTCLOUD_CERT_DIR}/private.key" "${NEXTCLOUD_CERT_DIR}/fullchain.pem" >> "${LOG_FILE}" 2>&1
    
    log "Перезапускаем Nextcloud..."
    snap restart nextcloud >> "${LOG_FILE}" 2>&1
else
    log "2. Nextcloud не найден, пропускаем."
fi

if [ -d "/var/snap/adguard-home/" ]; then
    log "3. Обнаружен AdGuard Home. Устанавливаем сертификат..."
    mkdir -p "${ADGUARD_CERT_DIR}"
    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --key-file "${ADGUARD_CERT_DIR}/private.key" --fullchain-file "${ADGUARD_CERT_DIR}/fullchain.pem" >> "${LOG_FILE}" 2>&1
    
    AGH_CONFIG="/var/snap/adguard-home/current/AdGuardHome.yaml"
    if [ -f "$AGH_CONFIG" ]; then
        log "Прописываем новый домен в конфигурации AdGuard Home..."
        sed -i "s/^[[:space:]]*server_name:.*/  server_name: ${DOMAIN}/" "$AGH_CONFIG"
    fi

    log "Перезапускаем AdGuard Home..."
    snap restart adguard-home >> "${LOG_FILE}" 2>&1
else
    log "3. AdGuard Home не найден, пропускаем."
fi

if [ -f "/usr/local/x-ui/x-ui" ]; then
    log "4. Обнаружен 3X-UI. Устанавливаем сертификат..."
    /usr/local/x-ui/x-ui cert -webCert "${XUI_CERT_FILE}" -webCertKey "${XUI_KEY_FILE}" >> "${LOG_FILE}" 2>&1
    log "Перезапускаем 3X-UI..."
    systemctl restart x-ui >> "${LOG_FILE}" 2>&1
else
    log "4. 3X-UI не найден, пропускаем."
fi

if [ -f "/etc/systemd/system/qbittorrent.service" ] && id -u qbittorrent >/dev/null 2>&1; then
    log "5. Обнаружен qBittorrent. Устанавливаем сертификат и включаем HTTPS..."
    QB_CERT_DIR="/etc/qbittorrent-cert"
    QB_CONF="/home/qbittorrent/.config/qBittorrent/qBittorrent.conf"
    mkdir -p "${QB_CERT_DIR}"
    # Копия сертификата именно для qBittorrent: он работает от своего пользователя, а в /root у него доступа нет
    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --key-file "${QB_CERT_DIR}/private.key" --fullchain-file "${QB_CERT_DIR}/fullchain.pem" >> "${LOG_FILE}" 2>&1
    if [ -s "${QB_CERT_DIR}/fullchain.pem" ] && [ -s "${QB_CERT_DIR}/private.key" ]; then
        echo "${DOMAIN}" > "${QB_CERT_DIR}/domain"
        chown -R qbittorrent:qbittorrent "${QB_CERT_DIR}"
        chmod 700 "${QB_CERT_DIR}"
        chmod 600 "${QB_CERT_DIR}/private.key"
        chmod 644 "${QB_CERT_DIR}/fullchain.pem" "${QB_CERT_DIR}/domain"

        # Ключ в секции [Preferences] (старая строка заменяется). Ключ передаётся как в файле: WebUI\HTTPS\Enabled
        qb_set() {
            KEY="$1" VAL="$2" awk '
                BEGIN { prefix = ENVIRON["KEY"] "=" }
                index($0, prefix) == 1 { next }
                { print }
                /^\[Preferences\]/ { print ENVIRON["KEY"] "=" ENVIRON["VAL"] }
            ' "${QB_CONF}" > "${QB_CONF}.tmp" && cat "${QB_CONF}.tmp" > "${QB_CONF}"
            rm -f "${QB_CONF}.tmp"
        }

        # Конфиг можно менять только при остановленной службе: qBittorrent перезаписывает его при выходе
        QB_WAS_ACTIVE=0
        systemctl is-active --quiet qbittorrent && QB_WAS_ACTIVE=1
        systemctl stop qbittorrent >> "${LOG_FILE}" 2>&1
        mkdir -p "$(dirname "${QB_CONF}")"
        [ -f "${QB_CONF}" ] || : > "${QB_CONF}"
        grep -q '^\[Preferences\]' "${QB_CONF}" || printf '\n[Preferences]\n' >> "${QB_CONF}"
        qb_set 'WebUI\HTTPS\Enabled' 'true'
        qb_set 'WebUI\HTTPS\CertificatePath' "${QB_CERT_DIR}/fullchain.pem"
        qb_set 'WebUI\HTTPS\KeyPath' "${QB_CERT_DIR}/private.key"
        chown qbittorrent:qbittorrent "${QB_CONF}"
        chmod 600 "${QB_CONF}"

        QB_PORT=$(grep -oP '^WebUI\\Port=\K[0-9]+' "${QB_CONF}" | head -n 1)
        QB_PORT="${QB_PORT:-8080}"

        if [ "${QB_WAS_ACTIVE}" = "1" ]; then
            log "Запускаем qBittorrent..."
            systemctl start qbittorrent >> "${LOG_FILE}" 2>&1
            QB_CODE=""
            for i in $(seq 1 30); do
                QB_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${QB_PORT}/" 2>/dev/null)
                [ "${QB_CODE}" = "200" ] && break
                sleep 1
            done
            if [ "${QB_CODE}" = "200" ]; then
                log "qBittorrent: HTTPS включён, адрес: https://${DOMAIN}:${QB_PORT}"
                echo -e "\033[0;32m✅ qBittorrent: HTTPS включён. Заходите по адресу: https://${DOMAIN}:${QB_PORT}\033[0m"
                echo "   (домен должен указывать на IP этого сервера; по IP страница тоже откроется, но браузер покажет предупреждение)"
            else
                log "qBittorrent: HTTPS не ответил за 30 секунд. Смотрите: journalctl -u qbittorrent -n 30"
                echo -e "\033[0;31m❌ qBittorrent запущен, но HTTPS не ответил за 30 секунд. Смотрите: journalctl -u qbittorrent -n 30\033[0m"
            fi
        else
            log "qBittorrent сейчас остановлен: HTTPS применится при его следующем запуске."
            echo "ℹ️ qBittorrent сейчас остановлен. HTTPS применится при следующем запуске, адрес будет: https://${DOMAIN}:${QB_PORT}"
        fi
    else
        log "qBittorrent: сертификат не удалось скопировать в ${QB_CERT_DIR}, HTTPS не включаю."
        echo -e "\033[0;31m❌ qBittorrent: не удалось скопировать сертификат, HTTPS не включён. Подробности: ${LOG_FILE}\033[0m"
    fi
else
    log "5. qBittorrent не найден, пропускаем."
fi

if systemctl cat torrserver.service >/dev/null 2>&1; then
    log "6. Обнаружен TorrServer. Устанавливаем сертификат и включаем HTTPS..."
    TS_CERT_DIR="/etc/torrserver-cert"
    TS_CONF="/opt/torrserver/torrserver.config"
    TS_KS="/usr/local/sbin/torrserver-ks.sh"

    # Правит DAEMON_OPTIONS в torrserver.config: убирает параметры HTTPS, затем (если $2 не пусто) дописывает $2 в конец значения
    ts_set_ssl_opts() {
        local conf="$1"
        ADD="$2" awk -v sq="'" '
            BEGIN { add = ENVIRON["ADD"]; nq = "[^[:space:]\"" sq "]+" }
            /^DAEMON_OPTIONS=/ {
                line = $0
                gsub("[[:space:]]--sslport[ =]" nq, "", line)
                gsub("[[:space:]]--sslcert[ =]" nq, "", line)
                gsub("[[:space:]]--sslkey[ =]" nq, "", line)
                gsub("[[:space:]]--ssl[[:space:]]", " ", line)
                gsub("[[:space:]]--ssl\"", "\"", line)
                gsub("[[:space:]]--ssl" sq, sq, line)
                sub("[[:space:]]--ssl$", "", line)
                if (add == "") gsub("[[:space:]]--force-https", "", line)
                sub(/[[:space:]]+$/, "", line)
                if (add != "") {
                    last = substr(line, length(line), 1)
                    if (last == "\"" || last == sq) line = substr(line, 1, length(line) - 1) add last
                    else line = line add
                }
                print line
                next
            }
            { print }
        ' "${conf}" > "${conf}.tmp" && cat "${conf}.tmp" > "${conf}"
        rm -f "${conf}.tmp"
    }

    mkdir -p "${TS_CERT_DIR}"
    # Копия сертификата именно для TorrServer: он работает от своего пользователя (или от root), а в /root у него доступа нет
    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --key-file "${TS_CERT_DIR}/private.key" --fullchain-file "${TS_CERT_DIR}/fullchain.pem" >> "${LOG_FILE}" 2>&1
    if [ -s "${TS_CERT_DIR}/fullchain.pem" ] && [ -s "${TS_CERT_DIR}/private.key" ]; then
        echo "${DOMAIN}" > "${TS_CERT_DIR}/domain"
        # Читать сертификат должен тот пользователь, от которого сейчас работает служба (после привязки к VPN это torrserver)
        TS_RUN_USER=$(systemctl show -p User --value torrserver 2>/dev/null)
        [ -n "${TS_RUN_USER}" ] && id -u "${TS_RUN_USER}" >/dev/null 2>&1 || TS_RUN_USER=root
        TS_RUN_GROUP=$(id -gn "${TS_RUN_USER}" 2>/dev/null || echo root)
        chown -R "${TS_RUN_USER}:${TS_RUN_GROUP}" "${TS_CERT_DIR}"
        chmod 700 "${TS_CERT_DIR}"
        chmod 600 "${TS_CERT_DIR}/private.key"
        chmod 644 "${TS_CERT_DIR}/fullchain.pem" "${TS_CERT_DIR}/domain"

        if [ -f "${TS_CONF}" ] && grep -q '^DAEMON_OPTIONS=' "${TS_CONF}"; then
            # Порт HTTPS: если уже был задан, оставляем его, иначе 8091
            TS_SSL_PORT=$(grep -oP '(?<=--sslport )\d+' "${TS_CONF}" | head -n 1)
            TS_SSL_PORT="${TS_SSL_PORT:-8091}"
            ts_set_ssl_opts "${TS_CONF}" " --ssl --sslport ${TS_SSL_PORT} --sslcert ${TS_CERT_DIR}/fullchain.pem --sslkey ${TS_CERT_DIR}/private.key"
            log "TorrServer: в ${TS_CONF} включены параметры HTTPS (порт ${TS_SSL_PORT})."

            # Порт в UFW (запоминаем, только если такого правила не было: при удалении закроем именно его)
            if command -v ufw >/dev/null 2>&1; then
                if ! ufw show added 2>/dev/null | grep -qE "allow ${TS_SSL_PORT}/tcp"; then
                    if ufw allow "${TS_SSL_PORT}/tcp" >> "${LOG_FILE}" 2>&1; then
                        echo "${TS_SSL_PORT}" > "${TS_CERT_DIR}/ufw_port"
                        log "TorrServer: порт ${TS_SSL_PORT}/tcp открыт в UFW."
                    fi
                fi
            fi

            # Kill-switch: ответы с порта HTTPS должны идти напрямую (иначе страница не откроется)
            if [ -x "${TS_KS}" ]; then
                if grep -q 'DAEMON_OPTIONS' "${TS_KS}"; then
                    "${TS_KS}" up >> "${LOG_FILE}" 2>&1
                else
                    log "TorrServer: kill-switch старой версии, порт ${TS_SSL_PORT} в нём не учтён."
                    echo -e "\033[1;33m⚠️ TorrServer: kill-switch от старой версии torrserver.sh, ответы с порта ${TS_SSL_PORT} он блокирует. Запустите torrserver.sh, пункт 9 (авто-исправление), затем повторите это действие.\033[0m"
                fi
            fi

            TS_WAS_ACTIVE=0
            systemctl is-active --quiet torrserver && TS_WAS_ACTIVE=1
            if [ "${TS_WAS_ACTIVE}" = "1" ]; then
                log "Перезапускаем TorrServer..."
                systemctl restart torrserver >> "${LOG_FILE}" 2>&1
                TS_CODE=""
                for i in $(seq 1 30); do
                    TS_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${TS_SSL_PORT}/echo" 2>/dev/null)
                    case "${TS_CODE}" in ""|000) ;; *) break ;; esac
                    sleep 1
                done
                case "${TS_CODE}" in
                    ""|000)
                        log "TorrServer: HTTPS не ответил за 30 секунд. Смотрите: journalctl -u torrserver -n 30"
                        echo -e "\033[0;31m❌ TorrServer запущен, но HTTPS не ответил за 30 секунд. Смотрите: journalctl -u torrserver -n 30\033[0m"
                        ;;
                    *)
                        log "TorrServer: HTTPS включён, адрес: https://${DOMAIN}:${TS_SSL_PORT}"
                        echo -e "\033[0;32m✅ TorrServer: HTTPS включён. Заходите по адресу: https://${DOMAIN}:${TS_SSL_PORT}\033[0m"
                        TS_HTTP_PORT=$(grep -oP '(?<=--port )\d+' "${TS_CONF}" | head -n 1)
                        TS_HTTP_PORT="${TS_HTTP_PORT:-8090}"
                        echo "   Обычный HTTP продолжает работать как раньше, без шифрования: http://IP-сервера:${TS_HTTP_PORT}"
                        echo "   Порт ${TS_SSL_PORT}/tcp откройте ещё и в Security List / NSG в консоли Oracle Cloud, если не открывали."
                        ;;
                esac
            else
                log "TorrServer сейчас остановлен: HTTPS применится при его следующем запуске."
                echo "ℹ️ TorrServer сейчас остановлен. HTTPS применится при следующем запуске, адрес будет: https://${DOMAIN}:${TS_SSL_PORT}"
            fi
        else
            log "TorrServer: в ${TS_CONF} нет строки DAEMON_OPTIONS, HTTPS не включаю."
            echo -e "\033[0;31m❌ TorrServer: не нашёл ${TS_CONF} со строкой DAEMON_OPTIONS, HTTPS не включён. Пришлите вывод команды: systemctl cat torrserver\033[0m"
        fi
    else
        log "TorrServer: сертификат не удалось скопировать в ${TS_CERT_DIR}, HTTPS не включаю."
        echo -e "\033[0;31m❌ TorrServer: не удалось скопировать сертификат, HTTPS не включён. Подробности: ${LOG_FILE}\033[0m"
    fi
else
    log "6. TorrServer не найден, пропускаем."
fi

log "====== Развертывание для ${DOMAIN} завершено. ======"; echo "" >> "${LOG_FILE}"
EOF
    chmod +x "${HOOK_SCRIPT_PATH}"
    LOGI "Hook-скрипт успешно создан/обновлен."
}

# --- Выбор провайдера и получение credentials ---
select_dns_provider() {
    local mode=$1  # "issue" или "sync"
    
    echo -e "${yellow}================================================================${plain}"
    echo -e "${yellow}       Выберите DNS-провайдера для выпуска сертификата:      ${plain}"
    echo -e "${yellow}================================================================${plain}"
    echo "1) Cloudflare (с поддержкой поддоменов *.domain)"
    echo "2) DuckDNS (только основной домен)"
    echo "3) deSEC (с поддержкой поддоменов *.domain)"
    echo "4) Dynu (с поддержкой поддоменов *.domain)"
    echo -e "${yellow}================================================================${plain}"
    read -p "Ваш выбор (1, 2, 3 или 4): " dns_choice
    echo ""

    CHALLENGE_ALIAS=""

    if [ "$dns_choice" == "1" ]; then
        DNS_PLUGIN="dns_cf"
        read -p "Введите ваш домен (например, domain.pp.ua): " TARGET_DOMAIN
        echo -e "Введите Cloudflare Global API Key:"
        read -r CF_GlobalKey
        read -p "Введите ваш email, привязанный к Cloudflare: " CF_AccountEmail
        export CF_Key="${CF_GlobalKey}"
        export CF_Email="${CF_AccountEmail}"

    elif [ "$dns_choice" == "2" ]; then
        DNS_PLUGIN="dns_duckdns"
        read -p "Введите ваш домен DuckDNS (например, vps.duckdns.org): " TARGET_DOMAIN
        echo -e "Введите ваш DuckDNS Token:"
        read -r DUCK_Token
        export DuckDNS_Token="${DUCK_Token}"

    elif [ "$dns_choice" == "3" ]; then
        DNS_PLUGIN="dns_desec"
        read -p "Введите ваш домен deSEC (например, domain.dedyn.io или subdomain.domain.dedyn.io): " TARGET_DOMAIN
        echo -e "Введите ваш deSEC Token:"
        read -r DEDYN_TOKEN
        export DEDYN_TOKEN="${DEDYN_TOKEN}"

        echo ""
        echo -e "${yellow}================================================================${plain}"
        echo -e "${yellow}   Это корневой домен или поддомен?                            ${plain}"
        echo -e "${yellow}================================================================${plain}"
        echo "1) Корневой домен (например domain.dedyn.io)"
        echo "2) Поддомен (например subdomain.domain.dedyn.io) - использовать challenge-alias"
        echo -e "${yellow}================================================================${plain}"
        read -p "Ваш выбор (1 или 2): " domain_type
        echo ""

        if [ "$domain_type" == "2" ]; then
            read -p "Введите корневой домен для challenge-alias (например domain.dedyn.io): " CHALLENGE_ALIAS
            ensure_desec_challenge_cname "${TARGET_DOMAIN}" "${CHALLENGE_ALIAS}" "${DEDYN_TOKEN}"
        fi

        cleanup_desec_txt "${TARGET_DOMAIN}" "${DEDYN_TOKEN}"

    elif [ "$dns_choice" == "4" ]; then
        DNS_PLUGIN="dns_dynu"
        read -p "Введите ваш домен Dynu (например, vps.dynu.net): " TARGET_DOMAIN
        echo -e "Введите ваш Dynu Client ID (OAuth2):"
        read -r DYNU_CLIENT_ID
        echo -e "Введите ваш Dynu Secret (OAuth2):"
        read -r DYNU_SECRET
        export Dynu_ClientId="${DYNU_CLIENT_ID}"
        export Dynu_Secret="${DYNU_SECRET}"

    else
        LOGE "Неверный выбор. Возврат в главное меню."
        return 1
    fi

    return 0
}

# --- Формирование команды выпуска сертификата ---
issue_certificate() {
    local domain=$1
    local renew_hook=$2
    local force_flag=$3  # "--force" или пусто

    if [ "$dns_choice" == "2" ]; then
        # DuckDNS - без wildcard
        ~/.acme.sh/acme.sh --issue --dns "${DNS_PLUGIN}" \
            -d "${domain}" \
            --ecc --dnssleep 60 \
            ${force_flag} \
            --renew-hook "${renew_hook}" --log
    elif [ -n "$CHALLENGE_ALIAS" ]; then
        # deSEC поддомен - с challenge-alias
        ~/.acme.sh/acme.sh --issue --dns "${DNS_PLUGIN}" \
            -d "${domain}" \
            -d "*.${domain}" \
            --challenge-alias "${CHALLENGE_ALIAS}" \
            --ecc --dnssleep 60 \
            ${force_flag} \
            --renew-hook "${renew_hook}" --log
    else
        # Cloudflare, deSEC корневой, Dynu - с wildcard
        ~/.acme.sh/acme.sh --issue --dns "${DNS_PLUGIN}" \
            -d "${domain}" \
            -d "*.${domain}" \
            --ecc --dnssleep 60 \
            ${force_flag} \
            --renew-hook "${renew_hook}" --log
    fi
}

# --- Уже выпущенные сертификаты (папки в /root/my_cert) ---
# Печатает по строке на сертификат: домен|дата окончания|сколько дней осталось (если срок определить не удалось: ?|?).
# Если сертификатов нет, ничего не печатает.
list_issued_certs() {
    local d f end end_ts days diff
    [[ -d "${CERT_BASE_DIR}" ]] || return 0
    for d in "${CERT_BASE_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        f="${d}fullchain.pem"
        [[ -s "$f" ]] || continue
        end=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
        end_ts=$(date -d "$end" +%s 2>/dev/null)
        if [[ -n "$end" && -n "$end_ts" ]]; then
            diff=$(( end_ts - $(date +%s) ))
            if (( diff < 0 )); then days=-1; else days=$(( diff / 86400 )); fi
            echo "$(basename "$d")|$(date -d "@${end_ts}" +%F)|${days}"
        else
            echo "$(basename "$d")|?|?"
        fi
    done
}

# Показывает выпущенные сертификаты (или что их нет)
print_cert_status() {
    local ind="${1:-   }" dom until days found=0
    while IFS='|' read -r dom until days; do
        [[ -z "$dom" ]] && continue
        found=1
        if [[ "$days" == "?" ]]; then
            echo -e "${ind}✅ ${dom}: сертификат есть (срок действия определить не удалось)"
        elif (( days < 0 )); then
            echo -e "${ind}❌ ${red}${dom}: срок действия истёк ${until}${plain}"
        elif (( days <= 14 )); then
            echo -e "${ind}⚠️ ${yellow}${dom}: действует до ${until}, осталось ${days} дн. (скоро истекает)${plain}"
        else
            echo -e "${ind}✅ ${green}${dom}${plain}: действует до ${until} (осталось ${days} дн.)"
        fi
    done < <(list_issued_certs)
    (( found )) || echo "${ind}Сертификат пока не выпущен."
}

# Перед повторным выпуском: если сертификат уже есть, говорим об этом и спрашиваем.
# Возвращает 0 (продолжать), если сертификатов нет или вы ответили y; иначе 1.
confirm_reissue_if_cert_exists() {
    local a
    [[ -n "$(list_issued_certs)" ]] || return 0
    echo ""
    echo -e "${yellow}⚠️ На этом сервере уже есть выпущенный сертификат:${plain}"
    print_cert_status
    echo "   Повторный выпуск обычно не нужен: acme.sh сам обновляет сертификат примерно через 60 дней после выпуска"
    echo "   (за ~30 дней до конца срока) и сам раскладывает его по программам."
    echo "   У Let's Encrypt есть лимит на выпуск одинаковых сертификатов (около 5 в неделю)."
    echo "   Если нужно только установить сертификат в новую программу, используйте пункт 2."
    read -p "Всё равно выпустить сертификат заново? [y/N, Enter = N (нет)]: " a
    [[ "$a" == "y" || "$a" == "Y" || "$a" == "д" || "$a" == "Д" ]]
}

ssl_cert_issue_and_deploy() {
    confirm_reissue_if_cert_exists || { echo "Отменено. Ничего не изменено."; return; }
    install_acme || { LOGE "Прерывание из-за ошибки установки acme.sh"; exit 1; }
    echo ""

    select_dns_provider "issue" || return

    create_renew_hook "${TARGET_DOMAIN}"

    LOGI "Запрашиваем сертификат для ${TARGET_DOMAIN} через ${DNS_PLUGIN}..."
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    issue_certificate "${TARGET_DOMAIN}" "${HOOK_SCRIPT_PATH}" ""

    if [[ $? -ne 0 ]]; then 
        LOGE "Ошибка выпуска сертификата"
        exit 1
    fi
    
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade

    LOGI "Первичная установка сертификата во все обнаруженные службы..."
    "${HOOK_SCRIPT_PATH}" "${TARGET_DOMAIN}"
    
    echo -e "\n✅ ${green}Готово! Сертификат выпущен и автоматически развернут.${plain}"
}

sync_certificates() {
    LOGI "Синхронизация сертификатов с установленными приложениями..."
    CERT_BASE_DIR="/root/my_cert"
    
    if [[ ! -d "${CERT_BASE_DIR}" || -z "$(ls -A ${CERT_BASE_DIR})" ]]; then
        LOGE "Сертификаты еще не были выпущены. Сначала выполните пункт 1."
        return
    fi
    
    local domain
    domain=$(ls -t "${CERT_BASE_DIR}" | head -n 1)

    read -p "Введите домен для синхронизации [${domain}]: " input_domain
    domain=${input_domain:-$domain}

    if [[ -z "$domain" || ! -d "${CERT_BASE_DIR}/${domain}" ]]; then
        LOGE "Домен не найден. Убедитесь, что сертификат для этого домена был выпущен."
        return
    fi

    # Перевыпуск не нужен: сертификат уже выпущен, а acme.sh хранит только путь к hook-скрипту.
    # Достаточно заново создать hook (в нём список программ) и запустить его на существующем сертификате.
    if [[ ! -f ~/.acme.sh/acme.sh || ( ! -d ~/.acme.sh/${domain}_ecc && ! -d ~/.acme.sh/${domain} ) ]]; then
        LOGE "acme.sh не знает домен ${domain} (нет его данных в ~/.acme.sh). Выпустите сертификат заново: пункт 1."
        return
    fi

    echo ""
    create_renew_hook "$domain"

    LOGI "Запускаем развертывание сертификата для ${domain} (без перевыпуска)..."
    "${HOOK_SCRIPT_PATH}" "$domain"

    LOGI "Синхронизация завершена. Сертификат установлен во все обнаруженные службы."
}

# Выключает HTTPS в qBittorrent и удаляет его копию сертификата (иначе qBittorrent остался бы с путями к удалённым файлам)
remove_qbittorrent_https() {
    local qb_conf="/home/qbittorrent/.config/qBittorrent/qBittorrent.conf"
    local qb_cert_dir="/etc/qbittorrent-cert"
    local was=0
    [[ -d "${qb_cert_dir}" ]] || return 0
    LOGD "Отключаем HTTPS в qBittorrent и удаляем его копию сертификата..."
    if [[ -f "${qb_conf}" ]] && grep -q '^WebUI\\HTTPS\\' "${qb_conf}"; then
        systemctl is-active --quiet qbittorrent && was=1
        systemctl stop qbittorrent >/dev/null 2>&1
        sed -i '/^WebUI\\HTTPS\\Enabled=/d; /^WebUI\\HTTPS\\CertificatePath=/d; /^WebUI\\HTTPS\\KeyPath=/d' "${qb_conf}"
        (( was )) && systemctl start qbittorrent >/dev/null 2>&1
        LOGI "HTTPS в qBittorrent выключен, веб-интерфейс снова работает по http://."
    fi
    rm -rf "${qb_cert_dir}"
}

# Правит DAEMON_OPTIONS в torrserver.config: убирает параметры HTTPS, затем (если $2 не пусто) дописывает $2 в конец значения.
# При пустом $2 (отключение HTTPS) убирается и --force-https, иначе TorrServer не запустится без --ssl.
ts_set_ssl_opts() {
    local conf="$1"
    ADD="$2" awk -v sq="'" '
        BEGIN { add = ENVIRON["ADD"]; nq = "[^[:space:]\"" sq "]+" }
        /^DAEMON_OPTIONS=/ {
            line = $0
            gsub("[[:space:]]--sslport[ =]" nq, "", line)
            gsub("[[:space:]]--sslcert[ =]" nq, "", line)
            gsub("[[:space:]]--sslkey[ =]" nq, "", line)
            gsub("[[:space:]]--ssl[[:space:]]", " ", line)
            gsub("[[:space:]]--ssl\"", "\"", line)
            gsub("[[:space:]]--ssl" sq, sq, line)
            sub("[[:space:]]--ssl$", "", line)
            if (add == "") gsub("[[:space:]]--force-https", "", line)
            sub(/[[:space:]]+$/, "", line)
            if (add != "") {
                last = substr(line, length(line), 1)
                if (last == "\"" || last == sq) line = substr(line, 1, length(line) - 1) add last
                else line = line add
            }
            print line
            next
        }
        { print }
    ' "${conf}" > "${conf}.tmp" && cat "${conf}.tmp" > "${conf}"
    rm -f "${conf}.tmp"
}

# Выключает HTTPS в TorrServer, закрывает порт в UFW (если его открыл ssl.sh) и удаляет его копию сертификата
remove_torrserver_https() {
    local ts_conf="/opt/torrserver/torrserver.config"
    local ts_cert_dir="/etc/torrserver-cert"
    local ts_ks="/usr/local/sbin/torrserver-ks.sh"
    local was=0 uport
    [[ -d "${ts_cert_dir}" ]] || return 0
    LOGD "Отключаем HTTPS в TorrServer и удаляем его копию сертификата..."
    if [[ -f "${ts_conf}" ]] && grep -qE '^DAEMON_OPTIONS=.*--ssl' "${ts_conf}"; then
        systemctl is-active --quiet torrserver && was=1
        ts_set_ssl_opts "${ts_conf}" ""
        [[ -x "${ts_ks}" ]] && "${ts_ks}" up >/dev/null 2>&1
        (( was )) && systemctl restart torrserver >/dev/null 2>&1
        LOGI "HTTPS в TorrServer выключен, веб-интерфейс снова работает по http://."
    fi
    uport=$(cat "${ts_cert_dir}/ufw_port" 2>/dev/null)
    if [[ -n "${uport}" ]] && command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "${uport}/tcp" >/dev/null 2>&1
        LOGD "Порт ${uport}/tcp в UFW закрыт. В Security List / NSG Oracle Cloud его закройте вручную."
    fi
    rm -rf "${ts_cert_dir}"
}

remove_acme() {
    LOGI "Начинаем удаление acme.sh..."
    remove_qbittorrent_https
    remove_torrserver_https
    if [ -f "$HOME/.acme.sh/acme.sh" ]; then
        ~/.acme.sh/acme.sh --uninstall
        LOGI "acme.sh и задача cron успешно удалены."
    else
        LOGI "acme.sh не найден, пропущено."
    fi

    LOGD "Удаляем оставшиеся файлы и папки..."
    rm -rf "$HOME/.acme.sh"
    rm -rf "/root/my_cert"
    
    if [ -f "${HOOK_SCRIPT_PATH}" ]; then
        rm -f "${HOOK_SCRIPT_PATH}"
        LOGI "Удален hook-скрипт: ${HOOK_SCRIPT_PATH}"
    fi

    LOGI "Удаление завершено."
}

show_cert_path() {
    CERT_BASE_DIR="/root/my_cert"
    if [[ ! -d "${CERT_BASE_DIR}" || -z "$(ls -A ${CERT_BASE_DIR})" ]]; then
        LOGE "Папка ${CERT_BASE_DIR} не найдена или пуста. Сначала выпустите сертификат (пункт 1)."
        return
    fi

    echo "Доступные файлы сертификата:"
    find "${CERT_BASE_DIR}" -type f -printf "   %p\n"
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    echo -e "\n${yellow}================================================================${plain}"
    echo -e "${yellow} Управление SSL сертификатами (Cloudflare, DuckDNS, deSEC, Dynu)${plain}"
    echo -e "${yellow}================================================================${plain}"
    echo " Сертификаты на этом сервере:"
    print_cert_status " "
    echo -e "${yellow}================================================================${plain}"
    echo "1. Установить/Перевыпустить сертификат"
    echo "2. Синхронизировать сертификаты с приложениями (после установки нового ПО)"
    echo "3. Показать путь к файлам сертификата"
    echo "4. Полностью удалить acme.sh, сертификаты и все настройки"
    echo "0. Выйти"
    echo -e "${yellow}================================================================${plain}"
    read -p "Введите номер действия (0-4): " choice
    case "$choice" in
        1) ssl_cert_issue_and_deploy ;;
        2) sync_certificates ;;
        3) show_cert_path ;;
        4) remove_acme ;;
        0) echo "Выход..."; exit 0 ;;
        *) echo -e "${red}⚠️ Неверный ввод! Пожалуйста, выберите от 0 до 4.${plain}" ;;
    esac
done
