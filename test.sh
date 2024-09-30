#!/bin/bash

# Копирование SSH-ключей и настройка прав доступа
sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
sudo chown -R root: /root/.ssh/

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
sudo dpkg-reconfigure -f noninteractive locales

# Настройка часового пояса
sudo timedatectl set-timezone Europe/Kiyv

# Скачивание и настройка скрипта updater.sh 
sudo wget -P /root/ https://raw.githubusercontent.com/Joy096/server/main/updater.sh
sudo chmod +x /root/updater.sh

# Добавление задания в cron для пользователя root
(echo "# Edit this file to introduce tasks to be run by cron.
#
# Each task to run has to be defined through a single line
# indicating with different fields when the task will be run
# and what command to run for the task
#
# To define the time you can provide concrete values for
# minute (m), hour (h), day of month (dom), month (mon),
# and day of week (dow) or use '*' in these fields (for 'any').
#
# Notice that tasks will be started based on the cron's system
# daemon's notion of time and timezones.
#
# Output of the crontab jobs (including errors) is sent through
# email to the user the crontab file belongs to (unless redirected).
#
# For example, you can run a backup of all your user accounts
# at 5 a.m every week with:
# 0 5 * * 1 tar -zcf /var/backups/home.tgz /home/
#
# For more information see the manual pages of crontab(5) and cron(8)
#
# m h  dom mon dow   command"; 
sudo crontab -u root -l 2>/dev/null; 
echo "0 4 * * * bash /root/updater.sh > /var/log/updater.log") | sudo crontab -u root -

# Установка aptitude 
sudo apt install aptitude -y

# Обновление пакетов с помощью aptitude 
sudo aptitude upgrade -y

# Перезагрузка сервера
sudo reboot
