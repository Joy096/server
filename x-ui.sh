#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен выполняться от root!"
    exit 1
fi

# 🛠 Функция установки x-ui
install_x-ui() {
  echo ""
  echo "🔄 Обновление списка пакетов и установка обновлений..."
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt full-upgrade -y && apt autoremove -y && apt clean

  # 🔍 Проверка и установка jq
  if ! command -v jq &>/dev/null; then
    echo "📦 Устанавливаем jq..."
    apt install -y jq
  fi

		 # 🔍 Проверка наличия curl
      if ! command -v curl &>/dev/null; then
        echo "⚠️ Утилита curl не найдена. Устанавливаем..."
        apt update && apt install -y curl
        if ! command -v curl &>/dev/null; then
          echo "❌ Не удалось установить curl. Проверьте соединение."
          exit 1
        fi
      fi

  echo ""
  echo "🚀 Установка 3x-ui..."
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || { 
      echo "❌ Ошибка установки 3x-ui!";
      exit 1;
  }

  # 🔎 Получаем порт x-ui
  local info=$(/usr/local/x-ui/x-ui setting -show true)
  XUI_PORT=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')

  if [[ -n "$XUI_PORT" ]]; then
    echo "✅ Порт x-ui: $XUI_PORT"
    
    # 🔥 Настройка UFW
    if command -v ufw &>/dev/null; then
      if ufw status | grep -q "Status: active"; then
        ufw allow "$XUI_PORT"/tcp >/dev/null 2>&1
        ufw allow "$XUI_PORT"/udp >/dev/null 2>&1
        echo "✅ Порт $XUI_PORT (TCP/UDP) открыт."
      else
        echo "ℹ️ UFW отключён, настройка портов не выполняется."
      fi
    else
      echo "ℹ️ UFW не установлен, откройте порт вручную."
    fi
  else
    echo "❌ Не удалось определить порт x-ui. Откройте его вручную."
  fi

   # 🔐 Изменение логина и пароля
  echo ""
  read -p "🔑 Изменить логин и пароль для входа в веб-интерфейс? (y/n): " choice

  if [[ "$choice" == "y" || "$choice" == "Y" || "$choice" == "да" ]]; then
    read -rp "👤 Введите логин: " config_account
    [[ -z $config_account ]] && config_account=$(date +%s%N | md5sum | cut -c 1-8)
    read -rp "🔒 Введите пароль: " config_password
    [[ -z $config_password ]] && config_password=$(date +%s%N | md5sum | cut -c 1-8)

    if /usr/local/x-ui/x-ui setting -username "$config_account" -password "$config_password" >/dev/null 2>&1; then
        /usr/local/x-ui/x-ui setting -remove_secret >/dev/null 2>&1
        systemctl restart x-ui
        echo "✅ Логин и пароль успешно обновлены."
    else
        echo "❌ Ошибка при обновлении логина и пароля!"
    fi
  else
    echo "ℹ️ Изменение логина и пароля отменено."
  fi

   # 🌍 Изменение корневого пути URL
  echo ""
  read -p "🛠  Изменить корневой путь URL адреса панели (webBasePath)? (y/n): " choice

  if [[ "$choice" == "y" || "$choice" == "Y" || "$choice" == "да" ]]; then
    read -rp "📂 Введите корневой путь URL: " config_webBasePath
    /usr/local/x-ui/x-ui setting -webBasePath "${config_webBasePath}" >/dev/null 2>&1
    systemctl restart x-ui
    echo "✅ Корневой путь изменен."
  else
    echo "ℹ️ Изменение пути URL отменено."
  fi

  # 🔄 Настройка автообновления
  (crontab -l 2>/dev/null; echo "35 4 * * * bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > x-ui_update.log 2>&1") | crontab -  
  echo "✅ Автообновление включено. Лог: x-ui_update.log"

  # 🖥 Вывод данных о сервере
  local username=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'username: .+' | awk '{print $2}')
  local password=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'password: .+' | awk '{print $2}')
  local webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
  local port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
  local server_ip=$(curl -s https://api.ipify.org)

  echo ""
  echo "🔹 Логин: ${username}"
  echo "🔹 Пароль: ${password}"
  echo "🔹 Порт: ${port}"
  echo "🔹 Корневой путь: ${webBasePath}"
  echo "🌍 Сервер: http://${server_ip}:${port}${webBasePath}"
}

# 🖥 Показ адреса сервера
show_server_address() {
  if [[ -d "/usr/local/x-ui" ]]; then
    local webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local server_ip=$(curl -s https://api.ipify.org)

    echo "🌍 Сервер: http://${server_ip}:${port}${webBasePath}"
  else
    echo "❌ x-ui не установлен в системе."
  fi
}

uninstall_x-ui() {
  echo ""
  echo "🗑 Начинаем удаление 3x-ui..."

  # Получаем порт, на котором работает x-ui
  local info=$(/usr/local/x-ui/x-ui setting -show true)
  XUI_PORT=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')

  # Удаляем x-ui
  x-ui uninstall
    
    # Проверяем, что порт найден
    if [[ -n "$XUI_PORT" ]]; then
      # Настройка UFW
      if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
          if ufw status | grep -q "$XUI_PORT/tcp"; then
            ufw delete allow "$XUI_PORT/tcp" >/dev/null 2>&1
            echo "✅ TCP порт $XUI_PORT закрыт."
          else
            echo "ℹ️ TCP порт $XUI_PORT не был открыт в брандмауэре."
          fi

          if ufw status | grep -q "$XUI_PORT/udp"; then
            ufw delete allow "$XUI_PORT/udp" >/dev/null 2>&1
            echo "✅ UDP порт $XUI_PORT закрыт."
          else
            echo "ℹ️ UDP порт $XUI_PORT не был открыт в брандмауэре."
          fi
        else
          echo "ℹ️ UFW отключён, закройте порты вручную."
        fi
      else
        echo "ℹ️ UFW не установлен, удалите порты вручную."
      fi
    else
      echo "⚠️  Не удалось определить порт x-ui. Проверьте настройки вручную."
    fi

    # Удаление задачи автообновления из crontab
    if crontab -l | grep -q "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > x-ui_update.log"; then
      crontab -l | grep -v "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > x-ui_update.log" | crontab -
      echo "✅ Автообновление отключено."
    else
      echo " ℹ️ Автообновление не настроено."
    fi

    echo "🎉 Удаление 3x-ui завершено!"
}

# 🔻 Главное меню
while true; do
  echo ""
  echo "📌 Выберите действие:"
  echo "1️⃣  Установить 3x-ui"
  echo "2️⃣  Удалить 3x-ui"
  echo "3️⃣  Показать адрес сервера"
  echo "4️⃣  Установить сертификат для x-ui"
  echo "0️⃣  Выход"
  echo "=============================="
  read -p "👉 Введите номер действия (0-3): " choice

  case $choice in
    1) install_x-ui ;;
    2) uninstall_x-ui ;;
    3) show_server_address ;;
    4) wget https://raw.githubusercontent.com/Joy096/server/refs/heads/main/cloudflare_ssl.sh && bash cloudflare_ssl.sh
    0) echo "👋 Выход."; exit ;;
    *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
  esac
done
