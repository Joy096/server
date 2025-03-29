#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# Настройка SSH-ключей
PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQEAiWC+8dirRSGcfd19nbdYVEbS1cIYKhXdJ3hQt3rsLK3HbbPEB178ldqP8nl5wTJr6HaoGX/GST5jyYd1RJTZVGAtR+4kj7Dd/89ROlxKKnCXLFpEGS+X847tRvuf2my/+qZcmj1Vo4A7eIDTcomResInCNYNm0cZTuWX/+8p/J26p/DBKd5NFycVy8ZZBC4PqOIRYzi8YYo7hg3RoefH1A5rXxhAlhiFp3gXHdMtV3fEmD5tXPaVwJjzRfuTzv1+y7iBFqhyuMGMULyV5HogQRVQqHJgYc+PteuhMDzXUic9AUj7N+mObLR9QkSbUwXgScYXFzl6T9Ggk5Pc2Z4mbw== joy096"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

if [ ! -f "$AUTHORIZED_KEYS" ]; then
  mkdir -p "$HOME/.ssh"
  touch "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"
fi

if ! grep -qF "$PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
  echo "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
fi

if [ ! -d /root/.ssh ]; then
  sudo mkdir -p /root/.ssh
fi

sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
sudo chown -R root: /root/.ssh/

# Обновление системы без подтверждений
export DEBIAN_FRONTEND=noninteractive
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y

# Установка некоторых необходимых пакетов
sudo apt install git -y

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
sudo locale-gen ru_UA.UTF-8
sudo update-locale LANG=ru_UA.UTF-8
echo "locales locales/default_environment_locale select ru_UA.UTF-8" | sudo debconf-set-selections # Устанавливаем выбор по умолчанию для локали
sudo dpkg-reconfigure -f noninteractive locales # Переконфигурируем локали

# Настройка часового пояса
sudo timedatectl set-timezone Europe/Kyiv

# Добавление задания в cron для пользователя root если его нет
CRON_USER="root"
CRON_JOB="0 4 * * * bash <(curl -Ls https://raw.githubusercontent.com/Joy096/server/refs/heads/main/updater.sh) > /var/log/updater.log 2>&1"
CRON_HEADER="# Edit this file to introduce tasks to be run by cron.
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
# m h  dom mon dow   command"

CRON_TEMP=$(mktemp)
CURRENT_CRONTAB=$(sudo crontab -u "$CRON_USER" -l 2>/dev/null) 

if ! grep -qF "$CRON_JOB" <<< "$CURRENT_CRONTAB"; then
  printf "%s\n" "$CRON_HEADER" > "$CRON_TEMP"
  if [ -n "$CURRENT_CRONTAB" ]; then
      printf "%s\n" "$CURRENT_CRONTAB" >> "$CRON_TEMP"
  fi
  printf "%s\n" "$CRON_JOB" >> "$CRON_TEMP"
  
  sudo crontab -u "$CRON_USER" "$CRON_TEMP"
fi

rm "$CRON_TEMP"

# Установка aptitude
if apt-cache show aptitude > /dev/null 2>&1; then
    :
else
    yes | sudo add-apt-repository universe
    sudo apt update
fi
    sudo apt install aptitude -y

# Обновление пакетов с помощью aptitude 
sudo aptitude upgrade -y

# Перезагрузкв
sudo reboot
