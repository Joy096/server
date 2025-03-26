#!/bin/bash

apt update
apt --yes full-upgrade
yes Y | apt autoremove
sleep 120  # Задержка в 120 секунд (2 минуты)
/sbin/reboot
