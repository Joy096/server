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

echo " Обновление списка пакетов и установка обновлений..."
apt update && apt full-upgrade -y

# Переменные для хранения портов и API URL
declare management_port=""
declare access_key_port=""
declare api_info=""

# Переменная для зеленого цвета и сброса цвета
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Путь к файлу для хранения портов и API URL
CONFIG_FILE="/root/outline_data.txt"

function install_outline {
    echo ""
    echo "🚀 Установка Docker..."
    curl -fsSL https://get.docker.com/ | sh

    echo "🔧 Установка Outline VPN..."
    install_output=$(yes Y | SB_IMAGE=oreoluwa/shadowbox:daily sudo --preserve-env bash -c "$(curl -Ls https://raw.githubusercontent.com/EricQmore/installer/main/install_server.sh)" install_server.sh 2>&1)

    api_info=$(echo "$install_output" | grep -oP '{"apiUrl":"https://.*?","certSha256":"[a-fA-F0-9]{64}"}')
    management_port=$(echo "$install_output" | grep -oP '(?<=Management port )\d+')
    access_key_port=$(echo "$install_output" | grep -oP '(?<=Access key port )\d+')

    echo "💾 Сохранение API URL и портов в файл конфигурации..."
    echo "$api_info" > "$CONFIG_FILE"
    echo "$management_port" >> "$CONFIG_FILE"
    echo "$access_key_port" >> "$CONFIG_FILE"

    echo "🛡 Открытие портов: $management_port (TCP), $access_key_port (TCP и UDP) в ufw..."
    ufw allow "$management_port/tcp"
    ufw allow "$access_key_port/tcp"
    ufw allow "$access_key_port/udp"

    echo ""
    echo "✅ Чтобы управлять сервером Outline, скопируйте следующую строку в интерфейс Outline Manager:"
    echo ""
    echo -e "${GREEN}${api_info}${NC}"
    echo ""
    read -p "🔹 Нажмите Enter для продолжения..."

    echo ""
    echo -e "🎉 Установка Outline VPN завершена!"
}

function show_api_url {
    if [[ -f $CONFIG_FILE ]]; then
        api_info=$(sed -n '1p' "$CONFIG_FILE")
        echo ""
        echo -e "🔗 API URL для вашего Outline сервера:"
        echo ""
        echo -e "${GREEN}${api_info}${NC}"
        echo ""
    else
        echo "❌ API URL недоступен. Сначала установите Outline VPN."
    fi
}

function generate_invite_link {
    read -p "🔑 Введите ключ для генерации ссылки-приглашения: " invite_key

    if [[ -z "$invite_key" ]]; then
        echo "⚠️ Ключ не может быть пустым! Попробуйте снова."
        return
    fi

    invite_link="https://s3.amazonaws.com/outline-vpn/invite.html#/ru/invite/${invite_key}"
    echo ""
    echo "✅ Ссылка-приглашение сгенерирована:"
    echo ""
    echo -e "${GREEN}${invite_link}${NC}"
    echo ""
}

function uninstall_outline {
    if [[ -f $CONFIG_FILE ]]; then
        echo "📂 Чтение портов из файла конфигурации..."
        readarray -t ports < "$CONFIG_FILE"
        api_info=${ports[0]}
        management_port=${ports[1]}
        access_key_port=${ports[2]}
    else
        echo "⚠️ Файл конфигурации с портами не найден."
    fi

    if [[ -n $management_port ]]; then
        echo "🛑 Удаление порта управления $management_port..."
        ufw delete allow "$management_port/tcp"
    fi

    if [[ -n $access_key_port ]]; then
        echo "🛑 Удаление порта доступа $access_key_port..."
        ufw delete allow "$access_key_port/tcp"
        ufw delete allow "$access_key_port/udp"
    fi

    echo "🗑 Удаление Outline VPN..."
    docker ps -a | grep shadowbox | awk '{print $1}' | xargs docker stop
    docker ps -a | grep shadowbox | awk '{print $1}' | xargs docker rm
    docker images | grep oreoluwa/shadowbox | awk '{print $3}' | xargs docker rmi
    rm -rf /opt/outline
    rm -rf /var/lib/outline

    rm -f "$CONFIG_FILE"

    echo "✅ Outline VPN успешно удалён!"
}

function main_menu {
    while true; do
        echo "=============================="
        echo "      🌍 Outline VPN Installer"
        echo "=============================="
        echo "1️⃣  Установка Outline VPN"
        echo "2️⃣  Удаление Outline VPN"
        echo "3️⃣  🔗 Генерация ссылки-приглашения на подключение"
        echo "4️⃣  📜 Отобразить apiUrl"
        echo "5️⃣  🚪 Выход"
        echo "=============================="
        read -p "📌 Выберите опцию [1-5]: " choice

        case $choice in
            1)
                install_outline
                ;;
            2)
                uninstall_outline
                ;;
            3)
                generate_invite_link
                ;;
            4)
                show_api_url
                ;;
            5)
                echo "👋 Выход из программы..."
                exit 0
                ;;
            *)
                echo "⚠️ Неправильный выбор! Попробуйте снова."
                ;;
        esac
        echo ""
    done
}

# Запуск меню
main_menu
