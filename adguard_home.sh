#!/bin/bash

# Функция для установки AdGuard Home
install_adguard() {
    echo "🔍 Проверяем, используется ли порт 53..."
    if lsof -i :53 | grep -q systemd-resolve; then
        echo "⚠️ Порт 53 занят systemd-resolve, выполняем настройки..."

        # Отключаем DNSStubListener и настраиваем systemd-resolved
        sudo mkdir -p /etc/systemd/resolved.conf.d
        echo -e "[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no" | sudo tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null

        # Обновляем resolv.conf
        sudo mv /etc/resolv.conf /etc/resolv.conf.backup
        sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

        # Перезапускаем systemd-resolved
        sudo systemctl reload-or-restart systemd-resolved
        echo "✅ Настройки systemd-resolved применены."
    else
        echo "✅ Порт 53 свободен, настройка systemd-resolved не требуется."
    fi

    # Устанавливаем AdGuard Home через Snap
    echo "🚀 Устанавливаем AdGuard Home..."
    sudo snap install adguard-home

    # Открываем необходимые порты в UFW
    echo "🔓 Настраиваем брандмауэр..."
    sudo ufw allow 3000
    sudo ufw allow 53
    sudo ufw allow 853
    sudo ufw allow 784
    echo "✅ Брандмауэр настроен."

    echo "🎉 Установка завершена! Перейдите в веб-панель для настройки:"
    echo "🌍 http://$(hostname -I | awk '{print $1}'):3000"
}

# Функция для удаления AdGuard Home
uninstall_adguard() {
    echo "🗑️ Удаляем AdGuard Home..."
    sudo snap remove adguard-home
    echo "✅ AdGuard Home удалён."

    echo "♻️ Восстанавливаем настройки systemd-resolved..."
    sudo rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
    sudo mv /etc/resolv.conf.backup /etc/resolv.conf 2>/dev/null
    sudo systemctl reload-or-restart systemd-resolved
    echo "✅ Systemd-resolved восстановлен."
}

# Функция для установки сертификата
install_certificate() {
    echo "🔐 Устанавливаем сертификат для AdGuard Home..."
    wget https://raw.githubusercontent.com/Joy096/server/refs/heads/main/cloudflare_ssl.sh && bash cloudflare_ssl.sh
    echo "✅ Сертификат установлен."
}

# Меню
while true; do
    echo ""
    echo "🌟 Выберите действие:"
    echo "1️⃣ Установка AdGuard Home"
    echo "2️⃣ Удаление AdGuard Home"
    echo "3️⃣ Установка сертификата для AdGuard Home"
    echo "0️⃣ Выход"
    read -rp "👉 Введите номер пункта и нажмите Enter: " choice

    case $choice in
        1) install_adguard ;;
        2) uninstall_adguard ;;
        3) install_certificate ;;
        0) echo "👋 Выход."; exit ;;
        *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
    esac
done
