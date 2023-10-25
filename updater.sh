#!/bin/bash

apt-get update
apt-get --yes full-upgrade
yes Y | apt-get autoremove
/sbin/reboot
