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

# Функция для установки AdGuard Home
install_adguard() {
  echo ""
  echo "Обновление списка пакетов и установка обновлений..."
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt upgrade -y && apt autoremove -y && apt clean

    echo ""
    echo "Проверяем, используется ли порт 53..."
    if lsof -i :53 | grep -q systemd-resolve; then
        echo "⚠️  Порт 53 занят systemd-resolve, выполняем настройки..." # Оставляем предупреждение ⚠️, так как оно несет смысловую нагрузку

        # Отключаем DNSStubListener и настраиваем systemd-resolved
        mkdir -p /etc/systemd/resolved.conf.d
        echo -e "[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no" | tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null

        # Обновляем resolv.conf
        mv /etc/resolv.conf /etc/resolv.conf.backup
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

        # Перезапускаем systemd-resolved
        systemctl reload-or-restart systemd-resolved
        echo "✅ Настройки systemd-resolved применены."
    else
        echo "✅ Порт 53 свободен, настройка systemd-resolved не требуется."
    fi

    # Устанавливаем AdGuard Home через Snap
    echo ""
    echo "Устанавливаем AdGuard Home..."
    snap install adguard-home

    # Открываем необходимые порты в UFW
    echo ""
    echo "Настраиваем брандмауэр..."
    ufw allow 3000
    ufw allow 53
    ufw allow 853
    ufw allow 784
    echo "✅ Брандмауэр настроен."

    # Отображаем внешний IP для доступа к веб-панели
    echo ""
    echo "Установка завершена! Перейдите в веб-панель для настройки:"
    echo "http://$(curl -s ifconfig.me):3000"
}

# Функция для удаления AdGuard Home
uninstall_adguard() {
    echo ""
    echo "Удаляем AdGuard Home..."
    snap remove adguard-home
    echo "✅ AdGuard Home удалён."

    # Закрываем порты в UFW
    echo ""
    echo "Закрываем порты в брандмауэре..."
    ufw delete allow 3000
    ufw delete allow 53
    ufw delete allow 853
    ufw delete allow 784
    echo "✅ Порты закрыты."

    echo ""
    echo "Восстанавливаем настройки systemd-resolved..."
    rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
    mv /etc/resolv.conf.backup /etc/resolv.conf 2>/dev/null
    systemctl reload-or-restart systemd-resolved
    echo "✅ Systemd-resolved восстановлен."
}

# Меню
while true; do
    echo ""
    echo "Выберите действие:"
    echo "1. Установка AdGuard Home"
    echo "2. Удаление AdGuard Home"
    echo "3. Установка сертификата для AdGuard Home"
    echo "0. Выход"
    echo ""
    read -rp "Введите номер пункта и нажмите Enter: " choice

    case $choice in
        1) install_adguard ;;
        2) uninstall_adguard ;;
        3) wget https://raw.githubusercontent.com/Joy096/server/refs/heads/main/cloudflare_ssl.sh && bash cloudflare_ssl.sh ;;
        0) echo "Выход."; echo ""; exit ;;
        *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
    esac
done
