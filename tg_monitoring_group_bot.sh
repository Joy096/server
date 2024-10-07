#!/bin/bash

# БОТ ДЛЯ ОТСЛЕЖИВАНИЯ СООБЩЕНИЙ В ГРУППЕ ПО КЛЮЧЕВЫМ СЛОВАМ
# ЭТО СКРИПТ ДЛЯ УСТАНОВКИ БОТА
# Очистка консоли перед запуском скрипта
clear

# Функция для установки и настройки Telegram-бота
install_and_configure_bot() {
    echo "Установка и настройка Telegram-бота..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install python3 python3-pip -y
    pip install python-telegram-bot telethon requests
    # Обновление aiohttp до последней версии
    pip install --upgrade aiohttp

    get_api_data
    get_phone_number
    get_group_info
    get_keywords
    get_bot_data
    configure_and_run_bot

    echo "Telegram-бот установлен, настроен и запущен."
}

# Функция для удаления Telegram-бота и связанных файлов
uninstall_telegram_bot() {
    echo "Удаление Telegram-бота..."
    sudo systemctl stop telegram_userbot
    sudo systemctl disable telegram_userbot
    sudo systemctl daemon-reload
    rm -rf ~/telegram_userbot

    # Удаление установленных пакетов и зависимостей
    sudo apt remove python3-telegram-bot telethon requests -y
    sudo apt autoremove -y 
    echo "Telegram-бот и связанные зависимости удалены."
}

# Функция для получения API ID и API Hash
get_api_data() {
    echo "ПОЛУЧАЕМ API ID И API Hash"
    echo "1. Открываем my.telegram.org."
    echo "2. Входим по номеру телефона. " 
    echo "3. Переходим в раздел 'API Development Tools'." 
    echo "4. Создаем новое приложение и получаем значения API_ID и API_HASH."
    read -p "Введите API_ID: " api_id
    read -p "Введите API_HASH: " api_hash
}

# Функция для получения номера телефона
get_phone_number() {
    read -p "Введите ваш номер телефона (с кодом страны, например, +380xxxxxxx): " phone_number
}

# Функция для получения ID группы или username
get_group_info() {
    read -p "Группа публичная (имеет юзернейм)? (y/n): " is_public
    if [[ $is_public == "y" ]]; then
        read -p "Введите юзернейм группы (без @): " group_chat_id
    else
        read -p "Введите ID группы (с минусом, например, -1001234567890): " group_chat_id
    fi
}

# Функция для получения ключевых слов
get_keywords() {
    read -p "Введите ключевые слова для отслеживания (через запятую): " keywords
    keywords_array=($(echo $keywords | tr ',' ' '))
}

# Функция для получения данных бота 
get_bot_data() {
    echo "1. В Telegram найдите бота @BotFather." 
    echo "2. Создайте нового бота и получите токен API."
    read -p "Введите токен бота: " bot_token
    read -p "Введите ваш Telegram ID или ID чата для уведомлений: " chat_id
}

# Функция для настройки и запуска Telegram-бота
configure_and_run_bot() {
    # Создание файла userbot.py с подставленными значениями
    cat << EOF > userbot.py
from telethon import TelegramClient, events
import requests

# Данные из Telegram API
api_id = $api_id
api_hash = "$api_hash"
phone_number = "$phone_number"

# ID группы или username для отслеживания
GROUP_CHAT_ID = "$group_chat_id" 

# Ключевые слова для отслеживания
KEYWORDS = ${keywords_array[@]}

# Данные бота для уведомлений
BOT_TOKEN = "$bot_token"
CHAT_ID = $chat_id

# Создание клиента
client = TelegramClient('session_name', api_id, api_hash)

# Вход в аккаунт
async def main():
    await client.start(phone=phone_number)
    print("Userbot запущен и отслеживает сообщения.")

# Обработка новых сообщений из указанной группы/чата
@client.on(events.NewMessage(chats=GROUP_CHAT_ID))
async def handler(event):
    message = event.message.message
    message_id = event.message.id
    sender = await event.get_sender()

    # Проверка на наличие ключевых слов в сообщении
    if any(keyword.lower() in message.lower() for keyword in KEYWORDS):
        print(f"Ключевое слово найдено: {message}")

        # Создаем ссылку на сообщение, учитывая, что группа может быть приватной
        if GROUP_CHAT_ID.startswith("-"):  # Если это chat_id (приватная группа)
            entity = await client.get_entity(int(GROUP_CHAT_ID))
            link = f"https://t.me/c/{entity.id}/{message_id}"
        else:  # Если это username (публичная группа)
            link = f"https://t.me/{GROUP_CHAT_ID}/{message_id}"

        # Отправляем ссылку через бота
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
        data = {
            "chat_id": CHAT_ID,
            "text": f"{link}"
        }
        requests.post(url, data=data)

# Запуск клиента
with client:
    client.loop.run_until_complete(main())
    client.run_until_disconnected()
EOF

    # Создание сервиса для автозапуска
    cat << EOF > /etc/systemd/system/telegram_userbot.service
[Unit]
Description=Telegram Userbot
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/$(whoami)/telegram_userbot/userbot.py
WorkingDirectory=/home/$(whoami)/telegram_userbot
Restart=always
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOF

    # Перезагрузка демона systemd, включение и запуск сервиса
    sudo systemctl daemon-reload
    sudo systemctl enable telegram_userbot
    sudo systemctl start telegram_userbot
    sudo systemctl status telegram_userbot

    echo "Telegram-бот настроен и запущен."
}

# Меню выбора действия
echo "Выберите действие:"
echo "1. Установить и настроить Telegram-бот"
echo "2. Удалить Telegram-бот"
echo "3. Выход"
read -p "Введите номер действия: " choice

case $choice in
    1)
        install_and_configure_bot
        ;;
    2)
        uninstall_telegram_bot
        ;;
    3)
        exit 0  # Выход из скрипта
        ;;
    *)
        echo "Неверный выбор. Выход."
        exit 1
        ;;
esac
