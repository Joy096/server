#!/bin/bash

# Создаем директорию
mkdir -p ~/chrome_os_temporary
mkdir -p ~/chrome_os
cd ~/chrome_os_temporary

# Выводим текст и запрашиваем ссылку
echo "Введите ссылку для загрузки ChromeOS recovery:"
read -r recovery_link

# Загружаем файл ChromeOS recovery по указанной ссылке
wget "$recovery_link" -O chromeos.bin.zip

# Выводим текст и запрашиваем ссылку
echo "Введите ссылку для загрузки brunch:"
read -r brunch_link

# Загружаем файл brunch по указанной ссылке
wget "$brunch_link" -O brunch.tar.gz

# Устанавливаем (обновляем) нужные пакеты
command -v wget pv cgpt tar unzip || sudo apt update && sudo apt -y install pv cgpt tar unzip

# Разархивируем архив brunch
tar zxvf brunch.tar.gz

# Разархивируем ChromeOS recovery
unzip chromeos.bin.zip

# Находим файл chromeos****.bin и переименовываем его в chromeos.bin
bin_file=$(find . -type f -name "*.bin" -print -quit)
if [ -n "$bin_file" ]; then
    mv "$bin_file" chromeos.bin
else
    echo "Не найден файл с расширением .bin"
fi

# Создаем образ для установки
sudo bash chromeos-install.sh -src chromeos.bin -dst chromeos.img

# Перемещаем chromeos.img в папку chrome
mv chromeos.img ~/chrome_os

# Удаляем папку chromeos
rm -rf ~/chrome_os_temporary

cd




