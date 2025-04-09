#!/bin/bash

# Скрипт для установки, настройки и управления Telegram-ботом "Де ліки Bot"
# Автор: Cline
# Для Ubuntu Server 22.04
# Использует Python + python-telegram-bot + парсинг tabletki.ua

# Директория установки бота
INSTALL_DIR="/opt/de_liky_bot"

# Директория для логов
LOG_DIR="/var/log/de_liky_bot"

# Путь к конфигурационному файлу
CONFIG_FILE="$INSTALL_DIR/config.json"

# Имя systemd сервиса
SERVICE_NAME="de_liky_bot.service"

# Проверка запуска от root
if [[ $EUID -ne 0 ]]; then
    echo "❌  Скрипт нужно запускать от root"
    exit 1
fi

# Установка Python, pip, создание виртуального окружения и установка зависимостей
install_dependencies() {
    echo "🔧  Установка Python и необходимых пакетов..."

    apt update
    apt install -y python3 python3-venv python3-pip

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"

    # Создаем виртуальное окружение
    python3 -m venv "$INSTALL_DIR/venv"

    # Устанавливаем библиотеки в venv
    "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install python-telegram-bot requests beautifulsoup4

    # Копируем meds_bot.py из /root/ в папку бота
    cp /root/meds_bot.py "$INSTALL_DIR/"
    
    echo "✅  Зависимости установлены"
}

# Ввод токена Telegram-бота и сохранение в конфиг
configure_token() {
    echo "🔑  Введите токен Telegram-бота:"
    read -r TOKEN

    # Создаем базовый конфиг
    cat > "$CONFIG_FILE" <<EOF
{
    "token": "$TOKEN",
    "cities": [],
    "drugs": [],
    "interval_hours": 12,
    "chat_ids": []
}
EOF

    chmod 640 "$CONFIG_FILE"
    echo "✅  Токен сохранён в $CONFIG_FILE"
}

# Создание systemd unit для автозапуска бота
create_service() {
    echo "⚙️  Создание systemd сервиса..."

    cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=De Liki Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/meds_bot.py
StandardOutput=append:$LOG_DIR/bot.log
StandardError=append:$LOG_DIR/error.log
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    echo "✅  Сервис создан и активирован"
}

# Запуск бота
start_bot() {
    systemctl start $SERVICE_NAME
    echo "▶️  Бот запущен"
}

# Остановка бота
stop_bot() {
    systemctl stop $SERVICE_NAME
    echo "⏹️  Бот остановлен"
}

# Показать логи бота
show_logs() {
    echo "📋  Лог бота:"
    tail -n 50 "$LOG_DIR/bot.log"
    
    echo ""
    echo "❌  Лог ошибок:"
    tail -n 20 "$LOG_DIR/error.log"
}

# Удаление бота и systemd сервиса
uninstall_bot() {
    echo "⚠️  Удаление бота и сервиса..."

    stop_bot
    systemctl disable $SERVICE_NAME
    rm -f /etc/systemd/system/$SERVICE_NAME
    systemctl daemon-reload

    rm -rf "$INSTALL_DIR"
    rm -rf "$LOG_DIR"

    echo "✅  Бот и сервис удалены"
}

# Главное меню
while true; do
    echo ""
    echo "===== Меню управления ботом 'Де ліки Bot' ====="
    echo "1) Установить бота"
    echo "2) Ввести/обновить токен"
    echo "3) Запустить бота"
    echo "4) Остановить бота"
    echo "5) Удалить бота"
    echo "6) Показать статус бота"
    echo "7) Показать логи бота"
    echo "0) Выйти"
    echo "=============================================="
    read -rp "Выберите пункт: " choice

    case $choice in
        1)
            install_dependencies
            configure_token
            create_service
            ;;
        2)
            configure_token
            ;;
        3)
            start_bot
            ;;
        4)
            stop_bot
            ;;
        5)
            uninstall_bot
            ;;
        6)
            systemctl status $SERVICE_NAME
            ;;
        7)
            show_logs
            ;;
        0)
            exit 0
            ;;
        *)
            echo "❌ Невірний вибір"
            ;;
    esac
done
