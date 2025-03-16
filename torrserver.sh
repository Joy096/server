#!/bin/bash

# Функция установки TorrServer
install_torrserver() {
  echo "Обновление списка пакетов и установка обновлений..."
  sudo apt update && sudo apt full-upgrade -y

  echo "Настройка брандмауэра UFW..."
  sudo ufw allow 80
  sudo ufw allow 443
  sudo ufw allow 8090

  echo "Установка TorrServer..."
  bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh)

  echo "Создать имя пользователя и пароль для авторизации? (да/нет)"
  read -r create_user

  if [[ "$create_user" == "да" ]]; then
    create_user_auth
  fi
}

# Функция удаления TorrServer
uninstall_torrserver() {
  echo "Удаление TorrServer..."
  bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh) --remove
  rm -rf torr.sh
  rm -rf torr.log
  sudo ufw delete allow 8090
}

# Функция добавления пользователя для авторизации
create_user_auth() {
  local accs_file="/opt/torrserver/accs.db"

  echo "Введите имя пользователя:"
  read -r username

  echo "Введите пароль:"
  read -r password

  # Проверяем, существует ли файл accs.db
  if [[ -f "$accs_file" ]]; then
    # Если файл существует, добавляем нового пользователя к существующим
    local existing_users=$(cat "$accs_file")
    # Удаляем последнюю фигурную скобку '}'
    existing_users="${existing_users%?}"
    # Добавляем нового пользователя и закрывающую скобку
    echo "$existing_users, \"$username\": \"$password\" }" > "$accs_file"
  else
    # Если файл не существует, создаем его с новым пользователем
    echo "{" > "$accs_file"
    echo "\"$username\": \"$password\"" >> "$accs_file"
    echo "}" >> "$accs_file"
  fi

  sudo systemctl daemon-reload
  sudo systemctl restart torrserver

  echo "Пользователь $username добавлен."
}

# Функция очистки кэша
clear_cache() {
  echo "Очистка кэша TorrServer..."
  sudo rm -rf /opt/torrserver/cache/*
  echo "Кэш очищен."
}

# Главное меню
while true; do
  echo "Выберите действие:"
  echo "1. Установка TorrServer"
  echo "2. Удаление TorrServer"
  echo "3. Добавить пользователя для авторизации"
  echo "4. Очистка кэша"
  echo "5. Выход"

  read -r choice

  case "$choice" in
  1)
    install_torrserver
    ;;
  2)
    uninstall_torrserver
    ;;
  3)
    create_user_auth
    ;;
  4)
    clear_cache
    ;;
  5)
    break
    ;;
  *)
    echo "Некорректный выбор."
    ;;
  esac
done

echo "Скрипт завершен."
