#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# Проверяем используется ли порт 53
if lsof -i :53 | grep -q systemd-resolve; then
    echo "Порт 53 занят systemd-resolve, выполняем настройки..."
    
    # Отключаем DNSStubListener и настраиваем systemd-resolved
    sudo mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no" | sudo tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null
    
    # Обновляем resolv.conf
    sudo mv /etc/resolv.conf /etc/resolv.conf.backup
    sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    
    # Перезапускаем systemd-resolved
    sudo systemctl reload-or-restart systemd-resolved
    echo "Настройки systemd-resolved применены."
else
    echo "Порт 53 свободен, настройка systemd-resolved не требуется."
fi

# Устанавливаем AdGuard Home через Snap
echo "Устанавливаем AdGuard Home..."
sudo snap install adguard-home

# Открываем необходимые порты в UFW
echo "Настраиваем брандмауэр..."
sudo ufw allow 3000
sudo ufw allow 53
sudo ufw allow 853
sudo ufw allow 784
echo "Брандмауэр настроен."

echo "Установка завершена. Перейдите в веб-панель для настройки:"
echo "http://$(hostname -I | awk '{print $1}'):3000"
