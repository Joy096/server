#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# Проверка на root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен выполняться от root!"
    exit 1
fi

# Цвета для сообщений
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
plain='\033[0m'

LOGI() { echo -e "✅ ${green}$* ${plain}"; }
LOGE() { echo -e "❌ ${red}$* ${plain}"; }
LOGD() { echo -e "   ${yellow}$* ${plain}"; }

# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
HOOK_SCRIPT_PATH="/root/renew_hook.sh"

install_acme() {
    # ... (код этой функции остается без изменений) ...
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

create_renew_hook() {
    # ... (код этой функции остается без изменений) ...
    local domain=$1
    LOGI "Создаем/Обновляем универсальный hook-скрипт: ${HOOK_SCRIPT_PATH}"
    
    cat << 'EOF' > "${HOOK_SCRIPT_PATH}"
#!/bin/bash
DOMAIN="$1"
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
    log "Перезапускаем Nextcloud..."
    snap restart nextcloud >> "${LOG_FILE}" 2>&1
else
    log "2. Nextcloud не найден, пропускаем."
fi

if [ -d "/var/snap/adguard-home/" ]; then
    log "3. Обнаружен AdGuard Home. Устанавливаем сертификат..."
    mkdir -p "${ADGUARD_CERT_DIR}"
    /root/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --key-file "${ADGUARD_CERT_DIR}/private.key" --fullchain-file "${ADGUARD_CERT_DIR}/fullchain.pem" >> "${LOG_FILE}" 2>&1
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

log "====== Развертывание для ${DOMAIN} завершено. ======"; echo "" >> "${LOG_FILE}"
EOF
    chmod +x "${HOOK_SCRIPT_PATH}"
    LOGI "Hook-скрипт успешно создан/обновлен."
}

ssl_cert_issue_and_deploy() {
    # ... (код этой функции остается без изменений) ...
    install_acme || { LOGE "Прерывание из-за ошибки установки acme.sh"; exit 1; }
    echo ""
    read -p "Введите ваш домен: " CF_Domain
    echo -e "Введите Cloudflare Global API Key:"
    read -r CF_GlobalKey
    echo ""
    read -p "Введите ваш email, привязанный к Cloudflare: " CF_AccountEmail
    export CF_Key="${CF_GlobalKey}"
    export CF_Email="${CF_AccountEmail}"

    create_renew_hook "${CF_Domain}"

    LOGI "Запрашиваем сертификат для ${CF_Domain} и регистрируем hook..."
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${CF_Domain}" -d "*.${CF_Domain}" --renew-hook "${HOOK_SCRIPT_PATH}" --log
    if [[ $? -ne 0 ]]; then LOGE "Ошибка выпуска сертификата"; exit 1; fi
    
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade

    LOGI "Первичная установка сертификата во все обнаруженные службы..."
    "${HOOK_SCRIPT_PATH}" "${CF_Domain}"
    
    echo -e "\n✅ ${green}Готово! Сертификат выпущен и автоматически развернут.${plain}"
}

# --- НОВАЯ ФУНКЦИЯ ---
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
    
    # 1. Пересоздаем hook-скрипт
    create_renew_hook "$domain"
    
    # 2. Принудительно перевыпускаем сертификат, чтобы ГАРАНТИРОВАННО обновить его конфигурацию.
    LOGI "Обновляем конфигурацию acme.sh для домена ${domain} (может занять до минуты)..."
    
    # --- ИЗМЕНЕНИЕ ЗДЕСЬ: добавлен флаг --force ---
    ~/.acme.sh/acme.sh --issue --dns dns_cf \
        -d "${domain}" \
        -d "*.${domain}" \
        --ecc \
        --force \
        --renew-hook "${HOOK_SCRIPT_PATH}" --log
    
    if [[ $? -ne 0 ]]; then
        LOGE "Произошла ошибка при обновлении конфигурации сертификата."
        return
    fi

    # 3. Запускаем hook немедленно, чтобы установить сертификаты
    LOGI "Запускаем развертывание сертификата для ${domain}..."
    "${HOOK_SCRIPT_PATH}" "$domain"
    
    LOGI "Синхронизация завершена. Сертификат установлен во все обнаруженные службы."
}

remove_acme() {
    # ... (код этой функции остается без изменений) ...
    LOGI "Начинаем удаление acme.sh..."
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
    # ... (код этой функции остается без изменений) ...
    CERT_BASE_DIR="/root/my_cert"
    if [[ ! -d "${CERT_BASE_DIR}" || -z "$(ls -A ${CERT_BASE_DIR})" ]]; then
        LOGE "Папка ${CERT_BASE_DIR} не найдена или пуста. Сначала выпустите сертификат (пункт 1)."
        return
    fi

    echo "Доступные файлы сертификата:"
    find "${CERT_BASE_DIR}" -type f -printf "   %p\n"
}


# --- ОБНОВЛЕННОЕ ГЛАВНОЕ МЕНЮ ---
while true; do
    echo "================================================================"
    echo "       Управление SSL сертификатами (метод Renew Hook)      "
    echo "================================================================"
    echo "1. Установить/Перевыпустить сертификат (первый запуск)"
    echo "2. Синхронизировать сертификаты с приложениями (после установки нового ПО)"
    echo "3. Показать путь к файлам сертификата"
    echo "4. Полностью удалить acme.sh, сертификаты и все настройки"
    echo "0. Выйти"
    echo "================================================================"
    read -p "Введите номер действия (0-4): " choice
    case "$choice" in
        1) ssl_cert_issue_and_deploy ;;
        2) sync_certificates ;;
        3) show_cert_path ;;
        4) remove_acme ;;
        0) echo "Выход..."; exit 0 ;;
        *) echo -e "${red}⚠️ Неверный ввод! Пожалуйста, выберите от 0 до 4.${plain}" ;;
    esac
    echo ""
done
