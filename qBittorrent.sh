#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# Функция установки qBittorrent с веб-интерфейсом
install_qbittorrent() {
    echo "Обновление пакетов..."
    apt update && apt upgrade -y

    echo "Установка qBittorrent-nox..."
    apt install -y qbittorrent-nox

    echo "Создание пользователя qbittorrent..."
    useradd -r -m -d /home/qbittorrent -s /usr/sbin/nologin qbittorrent || echo "Пользователь уже существует"

    echo "Настройка systemd службы..."
    cat <<EOF > /etc/systemd/system/qbittorrent.service
[Unit]
Description=qBittorrent-nox Service
After=network.target

[Service]
User=qbittorrent
Group=qbittorrent
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    echo "Перезапуск systemd и запуск службы..."
    systemctl daemon-reload
    systemctl enable qbittorrent
    systemctl start qbittorrent

    echo "Разрешение порта 8080 в UFW..."
    ufw allow 8080/tcp

    # Получение внешнего IP
    SERVER_IP=$(curl -s ifconfig.me)

    echo "qBittorrent установлен и запущен."
    echo "Веб-интерфейс доступен по адресу: http://$SERVER_IP:8080"
    echo "Логин: admin | Пароль: adminadmin"
}

# Функция удаления qBittorrent
remove_qbittorrent() {
    echo "Остановка службы qBittorrent..."
    systemctl stop qbittorrent
    systemctl disable qbittorrent
    rm -f /etc/systemd/system/qbittorrent.service

    echo "Удаление пакетов..."
    apt remove --purge -y qbittorrent-nox
    apt autoremove -y

    echo "Удаление пользователя qbittorrent..."
    userdel -r qbittorrent || echo "Пользователь не найден"

    echo "Закрытие порта 8080 в UFW..."
    ufw delete allow 8080/tcp || echo "Правило уже удалено"

    echo "qBittorrent успешно удалён."
}

# Главное меню
while true; do
    echo "Выберите действие:"
    echo "1) Установить qBittorrent"
    echo "2) Удалить qBittorrent"
    echo "3) Выйти"
    read -p "Введите номер: " choice

    case $choice in
        1) install_qbittorrent ;;
        2) remove_qbittorrent ;;
        3) exit ;;
        *) echo "Неверный ввод, попробуйте снова." ;;
    esac
done
