#!/bin/bash

# Выводим текст и запрашиваем ссылки
echo "Введите ссылку для загрузки ChromeOS recovery:"
read -r recovery_link
echo "Введите ссылку для загрузки brunch:"
read -r brunch_link

# Загружаем файлы ChromeOS recovery и brunch
wget "$recovery_link" -O chromeos.bin.zip
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



