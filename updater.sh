#!/bin/bash

apt update
apt --yes full-upgrade
yes Y | apt autoremove
/sbin/reboot
