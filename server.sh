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
wget -N --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh
chmod +x bbr.sh
sudo bash bbr.sh
sudo dpkg-reconfigure tzdata
sudo reboot
