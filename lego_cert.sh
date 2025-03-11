#!/bin/bash

LEGO_DIR="/opt/lego"
CERT_DIR="/var/snap/adguard-home/common/certs"
LEGO_SCRIPT="$LEGO_DIR/lego_renew.sh"
CRON_CMD="bash $LEGO_SCRIPT"
CRON_JOB="0 0 1 * * $CRON_CMD > $LEGO_DIR/lego_renew.log"

install_lego() {
    echo "🔹 Устанавливаем LEGO..."
    mkdir -p "$LEGO_DIR" && cd "$LEGO_DIR" || exit
    curl -s https://raw.githubusercontent.com/ameshkov/legoagh/master/lego.sh --output lego.sh
    chmod +x lego.sh
    
    echo "🔹 Создаем папку для сертификатов..."
    mkdir -p "$CERT_DIR"

    read -p "Введите DOMAIN NAME: " DOMAIN_NAME
    read -p "Введите EMAIL: " EMAIL
    read -p "Введите CLOUDFLARE DNS API TOKEN: " CLOUDFLARE_DNS_API_TOKEN

    # Создаем скрипт обновления сертификатов
    cat <<EOF > "$LEGO_SCRIPT"
#!/bin/bash
DOMAIN_NAME="$DOMAIN_NAME" \\
EMAIL="$EMAIL" \\
DNS_PROVIDER="cloudflare" \\
CLOUDFLARE_DNS_API_TOKEN="$CLOUDFLARE_DNS_API_TOKEN" \\
./lego.sh

# Перемещение сертификатов
if mv "/opt/lego/$DOMAIN_NAME.crt" "/var/snap/adguard-home/common/certs/"; then
    echo "✅ Сертификат перемещен!"
else
    echo "❌ Ошибка: не удалось переместить сертификат!"
    exit 1
fi

if mv "/opt/lego/$DOMAIN_NAME.key" "/var/snap/adguard-home/common/certs/"; then
    echo "✅ Ключ перемещен!"
else
    echo "❌ Ошибка: не удалось переместить ключ!"
    exit 1
fi

# Перезапуск AdGuard Home
systemctl restart snap.adguard-home.adguard-home.service
EOF

    chmod +x "$LEGO_SCRIPT"

    # Добавляем задачу в cron (если её нет)
    (crontab -l 2>/dev/null | grep -q "$CRON_CMD") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

    # Запускаем скрипт обновления
    bash "$LEGO_SCRIPT"

    # Проверяем наличие сертификатов перед выводом информации
    if [[ -f "$CERT_DIR/$DOMAIN_NAME.crt" && -f "$CERT_DIR/$DOMAIN_NAME.key" ]]; then
        echo "✅ Установка завершена! Сертификаты находятся в:"
        echo "$CERT_DIR/$DOMAIN_NAME.crt"
        echo "$CERT_DIR/$DOMAIN_NAME.key"
    else
        echo "❌ Ошибка: сертификаты не найдены в $CERT_DIR!"
    fi
}

remove_lego() {
    echo "🔹 Удаляем LEGO..."
    rm -rf "$LEGO_DIR"
    rm -rf "$CERT_DIR"
    crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
    echo "✅ LEGO и сертификаты удалены!"
}

echo "Выберите действие:"
echo "1. Установить LEGO и добавить задачу в cron"
echo "2. Удалить LEGO и удалить задачу cron"
read -p "Введите номер действия (1 или 2): " ACTION

case "$ACTION" in
    1) install_lego ;;
    2) remove_lego ;;
    *) echo "❌ Ошибка: выберите 1 или 2" && exit 1 ;;
esac

# Самоудаление скрипта
trap 'rm -- "$0"' EXIT
