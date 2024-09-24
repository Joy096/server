#!/bin/bash

ports_file="current_ports.txt"

if [ ! -f "$ports_file" ]; then
    # Если файл с портами не существует, запрашиваем их у пользователя и сохраняем
    read -p "Введите текущий HTTP порт: " current_http_port
    read -p "Введите текущий HTTPS порт: " current_https_port

    echo "HTTP_PORT=$current_http_port" > "$ports_file"
    echo "HTTPS_PORT=$current_https_port" >> "$ports_file"
fi

# Читаем порты из файла
source "$ports_file"

# Установка портов на 80 и 443
snap set nextcloud ports.http=80 ports.https=443

# Обновление сертификата с автоматизацией ответов
/usr/bin/expect <<EOF
set timeout -1
spawn nextcloud.enable-https lets-encrypt
expect "Have you met these requirements? (y/n)"
send "y\r"
expect "Please enter an email address (for urgent notices or key recovery):"
send "dmx007joy@gmail.com\r"
expect "Please enter your domain name(s) (space-separated):"
send "joy096speed.pp.ua\r"
interact
EOF

# Восстановление исходных портов
snap set nextcloud ports.http=$HTTP_PORT ports.https=$HTTPS_PORT
