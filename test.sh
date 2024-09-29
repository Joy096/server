#!/bin/bash

# Копирование SSH-ключей и настройка прав доступа
sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
sudo chown -R root. /root/.ssh/

# Обновление системы
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y

# Остановка и отключение netfilter-persistent
sudo systemctl stop netfilter-persistent
sudo systemctl disable netfilter-persistent

# Настройка брандмауэра 
sudo apt install ufw -y
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp # Разрешить SSH
sudo ufw allow 80/tcp  # Разрешить HTTP
sudo ufw allow 443/tcp # Разрешить HTTPS
sudo ufw --force enable

# Настройка сети
echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee --append /etc/sysctl.conf
sudo sysctl -p

# Настройка локали 
sudo locale-gen ru_UA.utf8
sudo update-locale LANG=ru_UA.UTF8
sudo dpkg-reconfigure locales

# Настройка часового пояса
sudo timedatectl set-timezone Europe/Kiev

# Скачивание и настройка скрипта updater.sh 
sudo wget -P /root/ https://raw.githubusercontent.com/Joy096/server/main/updater.sh
sudo chmod +x /root/updater.sh

# Добавление задания в cron для пользователя root
(sudo crontab -u root -l 2>/dev/null; echo "0 4 * * * bash /root/updater.sh > /var/log/updater.log") | sudo crontab -u root -

# Перезапуск службы cron
sudo systemctl restart cron

# Установка aptitude 
sudo apt install aptitude -y

# Обновление пакетов с помощью aptitude 
sudo aptitude upgrade -y

# Перезагрузка сервера
sudo reboot
