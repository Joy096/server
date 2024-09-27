#!/bin/bash

# Переменные для хранения портов и API URL
declare management_port=""
declare access_key_port=""
declare api_info=""

function install_outline {
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com/ | sh

    echo "Установка Outline VPN..."
    install_output=$(yes Y | SB_IMAGE=oreoluwa/shadowbox:daily sudo --preserve-env bash -c "$(wget -qO- https://raw.githubusercontent.com/EricQmore/installer/main/install_server.sh)" install_server.sh 2>&1)

    # Извлечение строки с API URL и сертификатом
    api_info=$(echo "$install_output" | grep -oP '{"apiUrl":"https://.*?","certSha256":"[a-fA-F0-9]{64}"}')

    # Извлечение портов для управления и ключей доступа
    management_port=$(echo "$install_output" | grep -oP '(?<=Management port )\d+')
    access_key_port=$(echo "$install_output" | grep -oP '(?<=Access key port )\d+')

    # Вывод информации для пользователя
    echo ""
    echo "To manage your Outline server, please copy the following line (including curly brackets) into Step 2 of the Outline Manager interface:"
    echo ""
    echo "$api_info"
    echo ""
    echo "Когда будете готовы продолжить установку, нажмите Enter."
    read -p ""

    # Настройка брандмауэра для указанных портов
    echo "Открытие портов $management_port (TCP) и $access_key_port (TCP и UDP) в ufw..."
    ufw allow "$management_port/tcp"
    ufw allow "$access_key_port/tcp"
    ufw allow "$access_key_port/udp"

    # Запрос Custom DNS
    read -p "Введите адрес Custom DNS (например, 94.140.14.14:53): " custom_dns

    echo "Создание DNS скрипта..."
    cat <<EOT > /root/outlinedns.sh
#!/bin/bash

# НАПРАВИМ OpenDNS, Cloudflare, Quad9 на Custom DNS
iptables -t nat -A OUTPUT -d 208.67.222.222/32 -p tcp --dport 53 -j DNAT --to-destination $custom_dns
iptables -t nat -A OUTPUT -d 208.67.220.220/32 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53
iptables -t nat -A OUTPUT -d 1.1.1.1/32 -p tcp --dport 53 -j DNAT --to-destination $custom_dns
iptables -t nat -A OUTPUT -d 9.9.9.9/32 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53

iptables -t nat -A OUTPUT -d 208.67.222.222/32 -p udp --dport 53 -j DNAT --to-destination $custom_dns
iptables -t nat -A OUTPUT -d 208.67.220.220/32 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
iptables -t nat -A OUTPUT -d 1.1.1.1/32 -p udp --dport 53 -j DNAT --to-destination $custom_dns
iptables -t nat -A OUTPUT -d 9.9.9.9/32 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
EOT

    chmod +x /root/outlinedns.sh

    echo "Создание systemd сервиса для Outline DNS..."
    cat <<EOT > /etc/systemd/system/outlinedns.service
[Unit]
Description=Outline Custom DNS
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/root/outlinedns.sh

[Install]
WantedBy=multi-user.target
EOT

    echo "Запуск и активация Outline DNS..."
    systemctl daemon-reload
    systemctl enable outlinedns
    systemctl start outlinedns

    echo "Outline VPN и Custom DNS установлены и запущены."
}

function uninstall_outline {
    echo "Остановка и удаление Outline Custom DNS..."
    systemctl stop outlinedns
    systemctl disable outlinedns
    rm -rf /etc/systemd/system/outlinedns.service
    rm -rf /root/outlinedns.sh
    systemctl daemon-reload
    apt autoclean

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

    echo "Outline и Custom DNS успешно удалены."
}

function generate_invite_link {
    read -p "Введите ключ для генерации ссылки-приглашения: " invite_key
    echo "Ваша ссылка-приглашение: https://s3.amazonaws.com/outline-vpn/invite.html#/ru/invite/$invite_key"
}

function show_api_url {
    if [[ -z $api_info ]]; then
        echo "API URL недоступен. Сначала установите Outline VPN."
    else
        echo "API URL для вашего Outline сервера: $api_info"
    fi
}

function main_menu {
    clear
    echo "=============================="
    echo "    Outline VPN Installer"
    echo "=============================="
    echo "1. Установка Outline VPN на Ubuntu ARM"
    echo "2. Удаление Outline и Custom DNS"
    echo "3. Генерация ссылки - приглашения на подключение"
    echo "4. Отобразить apiUrl"
    echo "5. Выход"
    echo "=============================="
    read -p "Выберите опцию [1-5]: " choice

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
