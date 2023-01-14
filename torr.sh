#!/bin/bash

wget https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-arm64
mv TorrServer-linux-arm64 /opt/torrserver
chmod +x /opt/torrserver/TorrServer-linux-arm64
systemctl restart torrserver