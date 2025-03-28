#!/bin/bash

# Проверка на root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен выполняться от root!"
    exit 1
fi

PORT_FILE="/etc/qbittorrent_web_port"
CREDENTIALS_FILE="/etc/qbittorrent-credentials"

# Функция установки qBittorrent с веб-интерфейсом
install_qbittorrent() {
    echo ""
    echo "🔄 Обновление системы..."
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt full-upgrade -y && apt autoremove -y && apt clean

    echo ""
    echo "📦 Установка qBittorrent-nox..."
    apt install -y qbittorrent-nox mktorrent curl jq

    echo ""
    echo "👤 Создание пользователя qbittorrent..."
    useradd -r -m -d /home/qbittorrent -s /usr/sbin/nologin qbittorrent || echo "ℹ️ Пользователь уже существует"

    echo ""
    read -p "🛠  Введите порт для веб-интерфейса (по умолчанию 8080): " WEB_PORT
    WEB_PORT=${WEB_PORT:-8080}
    echo "$WEB_PORT" > "$PORT_FILE"

    read -p "🔑 Введите логин (по умолчанию admin): " QB_LOGIN
    QB_LOGIN=${QB_LOGIN:-admin}

    read -p "🔑 Введите пароль (по умолчанию adminadmin): " QB_PASSWORD
    QB_PASSWORD=${QB_PASSWORD:-adminadmin}
    echo "$QB_LOGIN:$QB_PASSWORD" > "$CREDENTIALS_FILE"

    echo ""
    echo "⚙ Настройка systemd службы..."
    cat <<EOF > /etc/systemd/system/qbittorrent.service
[Unit]
Description=qBittorrent-nox Service
After=network.target

[Service]
User=qbittorrent
Group=qbittorrent
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$(cat /etc/qbittorrent_web_port)
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    echo "🔄 Перезапуск systemd и запуск службы..."
    systemctl daemon-reload
    systemctl enable qbittorrent
    systemctl start qbittorrent

    echo ""
    echo "🌐 Открытие порта $WEB_PORT в UFW..."
    ufw allow $WEB_PORT/tcp

    sleep 5

    SERVER_IP=$(curl -s ifconfig.me)

    echo ""
    echo "🔐 Настройка логина и пароля..."
    
    SESSION_ID=$(curl -s -i -X POST -H "User-Agent: Mozilla/5.0" \
        "http://localhost:$WEB_PORT/api/v2/auth/login" \
        --data "username=admin&password=adminadmin" | grep -Fi "set-cookie" | cut -d ' ' -f2 | tr -d '\r')

    if [[ -n "$SESSION_ID" ]]; then
        curl -s -X POST -H "User-Agent: Mozilla/5.0" -H "Cookie: $SESSION_ID" \
            "http://localhost:$WEB_PORT/api/v2/app/setPreferences" \
            --data-urlencode "json={\"web_ui_username\":\"$QB_LOGIN\",\"web_ui_password\":\"$QB_PASSWORD\"}"
        echo "✅ Логин и пароль успешно изменены."
        
        # Получаем порт для входящих соединений
        INCOMING_PORT=$(curl -s -X GET -H "User-Agent: Mozilla/5.0" -H "Cookie: $SESSION_ID" \
            "http://localhost:$WEB_PORT/api/v2/app/preferences" | jq -r '.listen_port')

        if [[ -n "$INCOMING_PORT" && "$INCOMING_PORT" != "null" ]]; then
            echo "$INCOMING_PORT" > /etc/qbittorrent_incoming_port
            ufw allow "$INCOMING_PORT"/tcp >/dev/null
            ufw allow "$INCOMING_PORT"/udp >/dev/null
            echo ""
            echo "🌐 Открыт порт для входящих соединений: $INCOMING_PORT"
        else
            echo "⚠ Не удалось определить порт для входящих соединений!"
        fi

    else
        echo "❌ Ошибка авторизации в qBittorrent API!"
    fi

    echo ""
    echo "✅ qBittorrent установлен и запущен."
    echo ""
    echo "🌍 Веб-интерфейс qBittorrent доступен по адресу: http://$SERVER_IP:$WEB_PORT"
    echo "🔑 Логин: $QB_LOGIN"
    echo "🔒 Пароль: $QB_PASSWORD"
}

# Функция удаления qBittorrent
remove_qbittorrent() {
    echo ""
    echo "🛑 Остановка службы qBittorrent..."
    systemctl stop qbittorrent
    systemctl disable qbittorrent
    rm -f /etc/systemd/system/qbittorrent.service

    echo "🗑 Удаление пакетов..."
    apt remove --purge -y qbittorrent-nox mktorrent
    apt autoremove -y

    echo ""
    echo "🌐 Закрытие портов в UFW..."
    if [ -f "/etc/qbittorrent_web_port" ]; then
        WEB_PORT=$(cat /etc/qbittorrent_web_port)
        ufw delete allow "$WEB_PORT"/tcp >/dev/null 2>&1 || echo "ℹ️ Правило уже удалено"
        rm -f /etc/qbittorrent_web_port
    fi

    if [ -f "/etc/qbittorrent_incoming_port" ]; then
        INCOMING_PORT=$(cat /etc/qbittorrent_incoming_port)
        ufw delete allow "$INCOMING_PORT"/tcp >/dev/null 2>&1 || echo "ℹ️ Правило уже удалено"
        ufw delete allow "$INCOMING_PORT"/udp >/dev/null 2>&1 || echo "ℹ️ Правило уже удалено"
        rm -f /etc/qbittorrent_incoming_port
    fi

    echo "🗑 Удаление сохраненных данных..."
    rm -f "$CREDENTIALS_FILE"
    rm -rf ~/torrents

    echo "👤 Удаление пользователя qbittorrent и его домашней директории..."
    userdel -r qbittorrent 2>/dev/null || echo "ℹ️ Пользователь qbittorrent не найден или уже удалён."

    echo "✅ qBittorrent успешно удалён."
}

# Функция создания торрента и запуска раздачи
create_torrent() {
    echo ""
    read -p "📂 Введите путь к файлу или папке для раздачи: " FILE_PATH

    if [ ! -e "$FILE_PATH" ]; then
        echo "❌ Ошибка: файл или папка не найдены!"
        return
    fi

    # Папка загрузок qBittorrent
    DOWNLOADS_DIR="/home/qbittorrent/Downloads"
    mkdir -p "$DOWNLOADS_DIR"

    # Проверка и изменение имени при совпадении
    FILE_NAME=$(basename "$FILE_PATH")
    DEST_PATH="$DOWNLOADS_DIR/$FILE_NAME"
    COUNTER=1

    while [ -e "$DEST_PATH" ]; do
        EXTENSION=""
        BASE_NAME="$FILE_NAME"

        # Разделяем имя и расширение, если оно есть
        if [[ "$FILE_NAME" == *.* ]]; then
            EXTENSION=".${FILE_NAME##*.}"
            BASE_NAME="${FILE_NAME%.*}"
        fi

        DEST_PATH="$DOWNLOADS_DIR/${BASE_NAME}_$COUNTER$EXTENSION"
        ((COUNTER++))
    done

    # Перемещение файла/папки в DOWNLOADS_DIR
    mv "$FILE_PATH" "$DEST_PATH"
    
    # Проверка успешности перемещения
    if [ $? -ne 0 ]; then
        echo "❌ Ошибка перемещения файла/папки!"
        return
    fi

    FILE_PATH="$DEST_PATH"
    echo "📂 Файл/папка перемещены в: $FILE_PATH"

    # Создание папки для .torrent файлов, если ее нет
    TORRENT_DIR="/home/qbittorrent/torrent_files"
    mkdir -p "$TORRENT_DIR"

    # Генерация уникального имени для .torrent файла
    FILE_NAME=$(basename "$FILE_PATH")
    TORRENT_NAME="$FILE_NAME.torrent"
    TORRENT_PATH="$TORRENT_DIR/$TORRENT_NAME"

    # Проверка на существование файла и изменение имени при необходимости
    COUNTER=1
    while [ -f "$TORRENT_PATH" ]; do
        TORRENT_NAME="$FILE_NAME.$COUNTER.torrent"
        TORRENT_PATH="$TORRENT_DIR/$TORRENT_NAME"
        COUNTER=$((COUNTER + 1))
    done

    # Установка прав доступа для пользователя qbittorrent
    if [ -f "$FILE_PATH" ]; then
        sudo chown qbittorrent:qbittorrent "$FILE_PATH"
        sudo chmod 644 "$FILE_PATH"
    elif [ -d "$FILE_PATH" ]; then
        sudo chown -R qbittorrent:qbittorrent "$FILE_PATH"
        sudo chmod -R 755 "$FILE_PATH"
    fi

    read -p "🔒 Сделать торрент приватным? (y/n): " PRIVATE_TORRENT
    PRIVATE_FLAG=""
    if [[ "$PRIVATE_TORRENT" == "y" ]]; then
        PRIVATE_FLAG="-p"

        # Создание .torrent файла
        TRACKERS="udp://tracker.openbittorrent.com:80/announce,udp://tracker.opentrackr.org:1337/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker.tiny-pears.com:6969/announce,udp://tracker.coppersurfer.tk:6969/announce"
        mktorrent -a "$TRACKERS" $PRIVATE_FLAG -o "$TORRENT_PATH" "$FILE_PATH" >/dev/null 2>&1

        mkdir -p ~/torrents
        cp "$TORRENT_PATH" ~/torrents/"$TORRENT_NAME"

        echo ""
        echo "⚠️  Для работы с приватным торрентом используйте только файл .torrent!"
        echo "⚠️  Magnet-ссылки, хеш и другие методы работать не будут!"
        echo "📂 Файл $TORRENT_NAME скопирован в папку ~/torrents/"
    else
       # Создание .torrent файла
        TRACKERS="udp://tracker.openbittorrent.com:80/announce,udp://tracker.opentrackr.org:1337/announce,udp://tracker.torrent.eu.org:451/announce,udp://tracker.tiny-pears.com:6969/announce,udp://tracker.coppersurfer.tk:6969/announce"
        mktorrent -a "$TRACKERS" $PRIVATE_FLAG -o "$TORRENT_PATH" "$FILE_PATH" >/dev/null 2>&1
    fi

    # Добавление торрента в qBittorrent
    if [ -f "$CREDENTIALS_FILE" ]; then
        QB_LOGIN=$(cut -d':' -f1 "$CREDENTIALS_FILE")
        QB_PASSWORD=$(cut -d':' -f2 "$CREDENTIALS_FILE")
    else
        QB_LOGIN="admin"
        QB_PASSWORD="adminadmin"
    fi

    if [ -f "$PORT_FILE" ]; then
        WEB_PORT=$(cat "$PORT_FILE")
    else
        WEB_PORT=8080
    fi

    SERVER_IP=$(curl -s ifconfig.me)

    SESSION_ID=$(curl -s -i -X POST -H "User-Agent: Mozilla/5.0" \
        "http://localhost:$WEB_PORT/api/v2/auth/login" \
        --data "username=$QB_LOGIN&password=$QB_PASSWORD" | grep -Fi "set-cookie" | cut -d ' ' -f2 | tr -d '\r')

    if [[ -n "$SESSION_ID" ]]; then
        curl -s -X POST -H "User-Agent: Mozilla/5.0" -H "Cookie: $SESSION_ID" \
            "http://localhost:$WEB_PORT/api/v2/torrents/add" \
            --cookie "$SESSION_ID" \
            -F "torrents=@$TORRENT_PATH" \
            -F "savepath=$DOWNLOADS_DIR" >/dev/null 2>&1

        echo ""
        echo "✅ Торрент $TORRENT_NAME создан и добавлен в раздачу!"
    else
        echo "❌ Ошибка авторизации в qBittorrent API!"
    fi
}

# Функция показа адреса веб-интерфейса
show_server_address() {
    SERVER_IP=$(curl -s ifconfig.me)
    
    if [ -f "$PORT_FILE" ]; then
        WEB_PORT=$(cat "$PORT_FILE")
    else
        WEB_PORT=8080
    fi

    if [ -f "$CREDENTIALS_FILE" ]; then
        QB_LOGIN=$(cut -d':' -f1 "$CREDENTIALS_FILE")
        QB_PASSWORD=$(cut -d':' -f2 "$CREDENTIALS_FILE")
    else
        QB_LOGIN="admin"
        QB_PASSWORD="adminadmin"
    fi

    echo ""
    echo "🌍 Веб-интерфейс qBittorrent доступен по адресу: http://$SERVER_IP:$WEB_PORT"
    echo "🔑 Логин: $QB_LOGIN"
    echo "🔒 Пароль: $QB_PASSWORD"
}

# Главное меню
while true; do
    echo ""
    echo "📌 Выберите действие:"
    echo "1️⃣  Установить qBittorrent"
    echo "2️⃣  Удалить qBittorrent"
    echo "3️⃣  Показать адрес сервера"
    echo "4️⃣  Создать торрент и запустить раздачу"
    echo "0️⃣  Выход"
    echo "=============================="
    read -p "👉 Введите номер действия: " choice

    case $choice in
        1) install_qbittorrent ;;
        2) remove_qbittorrent ;;
        3) show_server_address ;;
        4) create_torrent ;;
        0) echo "👋 Выход..."; echo ""; exit ;;
        *) echo "❌ Неверный ввод, попробуйте снова." ;;
    esac
done
