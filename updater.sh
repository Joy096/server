#!/bin/bash

apt-get update
apt-get --yes full-upgrade
yes Y | apt autoremove
/sbin/reboot
