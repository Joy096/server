#!/bin/bash

# Переменные для хранения портов и API URL
declare management_port=""
declare access_key_port=""
declare api_info=""

# Переменная для зеленого цвета и сброса цвета
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Путь к файлу для хранения портов и API URL
CONFIG_FILE="/root/outline_data"

function install_outline {
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com/ | sh

    echo "Установка Outline VPN..."
    # Сохраняем весь вывод установки в переменную install_output
    install_output=$(yes Y | SB_IMAGE=oreoluwa/shadowbox:daily sudo --preserve-env bash -c "$(curl -Ls https://raw.githubusercontent.com/EricQmore/installer/main/install_server.sh)" install_server.sh 2>&1)

    # Извлечение строки с API URL и сертификатом
    api_info=$(echo "$install_output" | grep -oP '{"apiUrl":"https://.*?","certSha256":"[a-fA-F0-9]{64}"}')

    # Извлечение портов для управления и ключей доступа
    management_port=$(echo "$install_output" | grep -oP '(?<=Management port )\d+')
    access_key_port=$(echo "$install_output" | grep -oP '(?<=Access key port )\d+')

    # Сохранение API URL и портов в файл конфигурации
    echo "Сохранение API URL и портов в файл конфигурации..."
    echo "$api_info" > "$CONFIG_FILE"
    echo "$management_port" >> "$CONFIG_FILE"
    echo "$access_key_port" >> "$CONFIG_FILE"

    # Вывод информации для пользователя с зелёным цветом для apiUrl
    echo ""
    echo "Чтобы управлять сервером Outline, скопируйте следующую строку в интерфейс Outline Manager:"
    echo -e "${GREEN}${api_info}${NC}"
    read -p "Нажмите Enter для продолжения..."

    # Настройка брандмауэра для указанных портов
    echo "Открытие портов $management_port (TCP) и $access_key_port (TCP и UDP) в ufw..."
    ufw allow "$management_port/tcp"
    ufw allow "$access_key_port/tcp"
    ufw allow "$access_key_port/udp"
}

function show_api_url {
    # Чтение API URL из файла конфигурации
    if [[ -f $CONFIG_FILE ]]; then
        api_info=$(sed -n '1p' "$CONFIG_FILE")
        echo -e "API URL для вашего Outline сервера: ${GREEN}${api_info}${NC}"
    else
        echo "API URL недоступен. Сначала установите Outline VPN."
    fi
}

function uninstall_outline {
    echo "Остановка и удаление Outline Custom DNS..."
    systemctl stop outlinedns
    systemctl disable outlinedns
    rm -rf /etc/systemd/system/outlinedns.service
    rm -rf /root/outlinedns.sh
    systemctl daemon-reload
    apt autoclean

    # Чтение портов из файла конфигурации, если он существует
    if [[ -f $CONFIG_FILE ]]; then
        echo "Чтение портов из файла конфигурации..."
        readarray -t ports < "$CONFIG_FILE"
        api_info=${ports[0]}
        management_port=${ports[1]}
        access_key_port=${ports[2]}
    else
        echo "Файл конфигурации с портами не найден."
    fi

    # Запрос на удаление клиентских портов
    read -p "Введите порты клиентов (через пробел) для удаления: " -a client_ports
    for port in "${client_ports[@]}"; do
        ufw delete allow "$port"
    done

    # Удаление портов Outline
    if [[ -n $management_port ]]; then
        echo "Удаление порта управления $management_port..."
        ufw delete allow "$management_port/tcp"
    fi
    if [[ -n $access_key_port ]]; then
        echo "Удаление порта доступа $access_key_port..."
        ufw delete allow "$access_key_port/tcp"
        ufw delete allow "$access_key_port/udp"
    fi

    echo "Удаление Outline VPN..."
    docker ps -a | grep shadowbox | awk '{print $1}' | xargs docker stop
    docker ps -a | grep shadowbox | awk '{print $1}' | xargs docker rm
    docker images | grep oreoluwa/shadowbox | awk '{print $3}' | xargs docker rmi
    rm -rf /opt/outline
    rm -rf /var/lib/outline

    # Удаление файла конфигурации
    rm -f "$CONFIG_FILE"

    echo "Outline и Custom DNS успешно удалены."
}

function main_menu {
    clear
    echo "=============================="
    echo "      Outline VPN Installer"
    echo "=============================="
    echo "1. Установка Outline VPN на Ubuntu ARM"
    echo "2. Удаление Outline и Custom DNS"
    echo "3. Отобразить apiUrl"
    echo "4. Выход"
    echo "=============================="
    read -p "Выберите опцию [1-4]: " choice

    case $choice in
        1)
            install_outline
            ;;
        2)
            uninstall_outline
            ;;
        3)
            show_api_url
            ;;
        4)
            exit 0
            ;;
        *)
            echo "Неправильный выбор! Попробуйте снова."
            main_menu
            ;;
    esac
}

# Запуск меню
main_menu
