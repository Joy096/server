#!/bin/bash

sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
sudo chown -R root. /root/.ssh/
sudo apt update
sudo apt full-upgrade -y
yes Y | sudo apt autoremove
sudo systemctl stop netfilter-persistent
sudo systemctl disable netfilter-persistent
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22
sudo ufw allow 80
sudo ufw allow 443
yes Y | sudo ufw enable
echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" | sudo tee --append /etc/sysctl.conf
sudo sysctl -p
sudo locale-gen ru_UA.utf8
sudo update-locale LANG=ru_UA.UTF8
sudo dpkg-reconfigure locales
sudo timedatectl set-timezone Europe/Kiev
sudo wget -P /root/ https://raw.githubusercontent.com/Joy096/server/main/updater.sh
sudo chmod +x /root/updater.sh
(sudo crontab -u root -l 2>/dev/null; echo "0 4 * * * bash /root/updater.sh > /var/log/updater.log") | sudo crontab -u root -
sudo apt install aptitude -y
sudo aptitude upgrade -y
sudo /etc/init.d/cron restart
