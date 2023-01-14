#!/bin/bash

wget https://github.com/yumata/lampa/archive/refs/heads/main.zip
unzip main.zip
mv lampa-main/msx/start.json lampa-main/msx/start_backup.json
cp -r lampa-main/* /var/www/html && rm -R lampa-main
rm main.zip
systemctl restart apache2