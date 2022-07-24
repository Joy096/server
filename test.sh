#!/bin/bash

sudo locale-gen ru_UA.utf8
sudo update-locale LANG=ru_UA.UTF8
locale | sudo tee /etc/default/locale
