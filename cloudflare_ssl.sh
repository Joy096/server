#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# Цвета для сообщений
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[0;33m'
plain='\033[0m'

LOGI() { echo -e "✅ ${green}$* ${plain}"; }
LOGE() { echo -e "❌ ${red}$* ${plain}"; }
LOGD() { echo -e "⚡ ${yellow}$* ${plain}"; }

install_acme() {
    # Проверяем наличие curl
    if ! command -v curl &>/dev/null; then
        LOGD "curl не найден. Устанавливаем curl ..."
        if [[ "$(command -v apt-get)" ]]; then
            sudo apt-get update
            sudo apt-get install -y curl
        elif [[ "$(command -v yum)" ]]; then
            sudo yum install -y curl
        elif [[ "$(command -v dnf)" ]]; then
            sudo dnf install -y curl
        elif [[ "$(command -v pacman)" ]]; then
            sudo pacman -S --noconfirm curl
        else
            LOGE "Не удалось установить curl: не найден менеджер пакетов ❌"
            return 1
        fi
        if [[ $? -ne 0 ]]; then
            LOGE "Ошибка установки curl ❌"
            return 1
        fi
        LOGI "curl успешно установлен ✅"
    fi

    # Проверяем наличие acme.sh
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        LOGI "acme.sh уже установлен 🚀"
        return 0
    fi

    LOGI "Устанавливаем acme.sh 📥..."
    curl -s https://get.acme.sh | sh
    if [[ $? -ne 0 ]]; then
        LOGE "Ошибка установки acme.sh ❌"
        return 1
    fi
    LOGI "acme.sh успешно установлен ✅"
    return 0
}

ssl_cert_issue_CF() {
    install_acme || { LOGE "Не удалось установить acme.sh ❌"; exit 1; }
    echo ""
    read -p "🌍 Введите домен: " CF_Domain
    echo -e "🔑 Введите Cloudflare Global API Key: "
    echo -e "   Его можно найти по ссылке: \e[33mhttps://dash.cloudflare.com/profile/api-tokens\e[0m"
    echo -ne "\033[2A\033[38C"  
    read -r CF_GlobalKey
    echo ""    
    read -p "📧 Введите email: " CF_AccountEmail

    export CF_Key="${CF_GlobalKey}"
    export CF_Email="${CF_AccountEmail}"

    LOGI "Запрашиваем сертификат для ${CF_Domain} 🔄..."
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${CF_Domain}" -d "*.${CF_Domain}" --log || {
        LOGE "Ошибка выпуска сертификата ❌"; exit 1;
    }

    LOGI "Настраиваем автообновление 🔄..."
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade || {
        LOGE "Ошибка настройки автообновления ❌"; exit 1;
    }

    CERT_DIR="/root/my_cert/${CF_Domain}"
    mkdir -p "${CERT_DIR}"

    LOGI "Копируем файлы сертификата в ${CERT_DIR} 📂..."
    ~/.acme.sh/acme.sh --install-cert -d "${CF_Domain}" \
        --cert-file "${CERT_DIR}/cert.pem" \
        --key-file "${CERT_DIR}/private.key" \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --ca-file "${CERT_DIR}/ca.pem"

    echo -e "\n🎉 ${green}Файлы сертификата успешно созданы и сохранены в папку: ${CERT_DIR}${plain}"
    echo "📂 Список файлов сертификата:"
    find "${CERT_DIR}" -type f | while read file; do
        echo -e "   📄 ${file}"
    done
}

remove_acme() {
    LOGI "Начинаем удаление acme.sh..."

    if [ -d "$HOME/.acme.sh" ]; then
        # Удаляем acme.sh с помощью команды --uninstall
        ~/.acme.sh/acme.sh --uninstall
        if [[ $? -eq 0 ]]; then
            LOGI "acme.sh и задача cron успешно удалены ✅"
        else
            LOGE "Ошибка удаления acme.sh ❌"
        fi
    else
        LOGI "acme.sh не найден, ничего удалять не нужно 🟢"
    fi


    if [ -d "/root/my_cert" ]; then
        rm -rf "/root/my_cert"
        LOGI "Удалена папка: /root/my_cert ✅"
    else
        LOGI "Папка /root/my_cert не найдена, пропускаем 🟢"
    fi

    LOGI "Удаление завершено ✅"
}

show_cert_path() {
    if [[ ! -d "/root/my_cert" ]]; then
        echo -e "❌ Ошибка: папка /root/my_cert/ не найдена!"
        return
    fi

    echo -e "📂 Доступные файлы сертификата:"
    find "/root/my_cert" -type f | while read file; do
        echo -e "   📄 ${file}"
    done
}

install_cert_xui() {
    read -p "🌍 Введите домен, для которого установить сертификат в X-UI: " CF_Domain
    CERT_DIR="/root/my_cert/${CF_Domain}"

    if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/private.key" ]]; then
        LOGE "Сертификат и ключ не найдены в ${CERT_DIR}, сначала выпустите их! ❌"
        return
    fi

    LOGI "Устанавливаем сертификат в 3X-UI 🔧..."
    /usr/local/x-ui/x-ui cert -webCert "${CERT_DIR}/fullchain.pem" -webCertKey "${CERT_DIR}/private.key"

    systemctl restart x-ui
    LOGI "Сертификат установлен в 3X-UI и панель перезапущена!"
}

install_cert_nextcloud() {
    read -p "🌍 Введите домен, для которого установить сертификат в Nextcloud: " CF_Domain
    CERT_DIR="/root/my_cert/${CF_Domain}"
    NEXTCLOUD_CERT_DIR="/var/snap/nextcloud/current/certs/custom/"

    if [[ ! -f "${CERT_DIR}/cert.pem" || ! -f "${CERT_DIR}/private.key" || ! -f "${CERT_DIR}/fullchain.pem" ]]; then
        LOGE "Сертификаты не найдены в ${CERT_DIR}, сначала выпустите их! ❌"
        return
    fi

    LOGI "Копируем сертификаты в Nextcloud 📂..."
    ~/.acme.sh/acme.sh --install-cert -d "${CF_Domain}" \
        --cert-file "${NEXTCLOUD_CERT_DIR}/cert.pem" \
        --key-file "${NEXTCLOUD_CERT_DIR}/private.key" \
        --fullchain-file "${NEXTCLOUD_CERT_DIR}/fullchain.pem"

    LOGI "Активируем кастомный сертификат в Nextcloud 🔧..."
    cd "${NEXTCLOUD_CERT_DIR}" || { LOGE "Ошибка: не удалось перейти в ${NEXTCLOUD_CERT_DIR}"; return; }
    nextcloud.enable-https custom ./cert.pem ./private.key ./fullchain.pem

    LOGI "Перезапускаем Nextcloud 🔧..."
    snap restart nextcloud
    
    LOGI "Сертификат установлен в Nextcloud и панель перезапущена! ✅"
}

install_cert_adguard() {
    read -p "🌍 Введите домен, для которого установить сертификат в AdGuard Home: " CF_Domain
    CERT_DIR="/root/my_cert/${CF_Domain}"
    ADGUARD_CERT_DIR="/var/snap/adguard-home/common/certs/"

    LOGI " Создаем папку, если ее нет 📂..."
    if [[ ! -d "${ADGUARD_CERT_DIR}" ]]; then
        LOGI "Создаем директорию ${ADGUARD_CERT_DIR} ..."
        sudo mkdir -p "${ADGUARD_CERT_DIR}"
        if [[ $? -ne 0 ]]; then
            LOGE "Ошибка создания директории ${ADGUARD_CERT_DIR} ❌"
            return 1
        fi
    else
        LOGI "Директория ${ADGUARD_CERT_DIR} уже существует 🟢"
    fi
    
    if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/private.key" ]]; then
        LOGE "Сертификаты не найдены в ${CERT_DIR}, сначала выпустите их! ❌"
        return
    fi

    LOGI "Копируем сертификат в AdGuard Home 📂..."
    ~/.acme.sh/acme.sh --install-cert -d "${CF_Domain}" \
        --key-file "${ADGUARD_CERT_DIR}/private.key" \
        --fullchain-file "${ADGUARD_CERT_DIR}/fullchain.pem"

    LOGI "Обновляем конфигурацию AdGuard Home 🔧..."
    sed -i "/^tls:/,/^[^ ]/ { s|enabled: false|enabled: true|; }" /var/snap/adguard-home/current/AdGuardHome.yaml
    sed -i "/^tls:/,/^[^ ]/ { s|server_name:.*|server_name: ${CF_Domain}|; }" /var/snap/adguard-home/current/AdGuardHome.yaml
    sed -i "/^tls:/,/^[^ ]/ { s|certificate_path:.*|certificate_path: \"/var/snap/adguard-home/common/certs/fullchain.pem\"|; }" /var/snap/adguard-home/current/AdGuardHome.yaml
    sed -i "/^tls:/,/^[^ ]/ { s|private_key_path:.*|private_key_path: \"/var/snap/adguard-home/common/certs/private.key\"|; }" /var/snap/adguard-home/current/AdGuardHome.yaml

    LOGI "Проверка занятости порта 443🚦..."
    if netstat -tuln | grep -q ":443 "; then
        read -p "Стандартный порт 443 занят. Введите другой порт https для веб-интерфейса AdGuard: " HTTPS_PORT
        if [[ -n "$HTTPS_PORT" ]]; then
            sed -i "/^tls:/,/^[^ ]/ { s|port_https:.*|port_https: ${HTTPS_PORT}|; }" /var/snap/adguard-home/current/AdGuardHome.yaml
            LOGI "Теперь для веб-интерфейса AdGuard используется порт ${HTTPS_PORT} ."
        else
            LOGE "Порт не был введен. Используется стандартный порт 443."
        fi
    fi

    LOGI "Перезапускаем AdGuard Home 🔄..."
    snap restart adguard-home

    LOGI "Сертификат установлен в AdGuard Home и шифрование включено! ✅"
}


# Главное меню
echo "================================"
echo "🛡️  Cloudflare SSL Certificate 🔑"
echo "================================"
echo -e "1️⃣  Установить acme и выпустить сертификат с автообновлением 🔐"
echo -e "2️⃣  Удалить acme.sh, сертификаты и папку my cert 🗑️"
echo -e "3️⃣  Показать путь к файлам сертификата 📄"
echo -e "4️⃣  Установить сертификат в 3X-UI 🔧"
echo -e "5️⃣  Установить сертификат в Nextcloud 🔧"
echo -e "6️⃣  Установить сертификат в AdGuard Home 🔧"
echo -e "0️⃣  Выйти ❌"
echo "================================"
read -p "📌 Введите номер действия (0-5): " choice

case "$choice" in
    1) ssl_cert_issue_CF ;;
    2) remove_acme ;;
    3) show_cert_path ;;
    4) install_cert_xui ;;
    5) install_cert_nextcloud ;;
    6) install_cert_adguard ;;
    0) echo -e "👋 ${green}Выход...${plain}"; exit 0 ;;
    *) echo -e "⚠️ ${red}Неверный ввод! Пожалуйста, выберите 0-5.${plain}" ;;
esac
