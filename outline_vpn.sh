#!/bin/bash

function install_outline {
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com/ | sh

    echo "Установка Outline VPN..."
    SB_IMAGE=oreoluwa/shadowbox:daily sudo --preserve-env bash -c "$(wget -qO- https://raw.githubusercontent.com/EricQmore/installer/main/install_server.sh)" install_server.sh

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

function main_menu {
    clear
    echo "=============================="
    echo "    Outline VPN Installer"
    echo "=============================="
    echo "1. Установка Outline VPN на Ubuntu ARM"
    echo "2. Удаление Outline и Custom DNS"
    echo "3. Генерация ссылки - приглашения на подключение"
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
            generate_invite_link
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
