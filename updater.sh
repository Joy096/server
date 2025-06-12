#!/bin/bash

apt update
apt --yes full-upgrade
yes Y | apt autoremove
sleep 120  # Задержка в 120 секунд (2 минуты)
# Removes old revisions of snaps
# CLOSE ALL SNAPS BEFORE RUNNING THIS
set -eu
snap list --all | awk '/disabled/{print $1, $3}' |
    while read snapname revision; do
        snap remove "$snapname" --revision="$revision"
    done
/sbin/reboot
