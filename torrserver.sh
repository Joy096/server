#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен выполняться от root!"
    exit 1
fi

# Функция установки TorrServer
install_torrserver() {
  echo ""
  echo "🔄 Обновление списка пакетов и установка обновлений..."
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt full-upgrade -y && apt autoremove -y && apt clean

  # Проверка и установка jq
    if ! command -v jq &>/dev/null; then
    echo " Устанавливаем jq..."
    apt install -y jq
  fi

		# Проверка наличия curl
			if ! command -v curl &>/dev/null; then
					echo "⚠️ Утилита curl не найдена. Устанавливаем..."
					apt update &&  apt install -y curl
					if ! command -v curl &>/dev/null; then
							echo "❌ Не удалось установить curl. Проверьте соединение."
							exit 1
					fi
			fi

  echo ""
  echo " Установка TorrServer..."
  bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh)

  # Определение порта для веб-интерфейса
   web_port=$(grep -oP '(?<=--port )\d+' /opt/torrserver/torrserver.config 2>/dev/null)
	  
			if [[ -z "$web_port" ]]; then
     web_port="8090"
     echo "⚠️ Не удалось определить порт. Используется значение по умолчанию: $web_port"
   else
     echo "✅ Определён порт: $web_port"
   fi

  # Сохранение порта в файл для дальнейшего использования
  echo "$web_port" | tee /opt/torrserver/port.conf >/dev/null

  echo " Настройка брандмауэра..."
    if command -v ufw &>/dev/null; then
    ufw allow "$web_port"
    echo "✅ Брандмауэр настроен для порта $web_port."
  else
    echo "⚠️ Утилита ufw не найдена. Пожалуйста, настройте брандмауэр вручную для порта $web_port."
  fi

  # Настройка автообновления
  (crontab -l 2>/dev/null; echo "30 4 * * * bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh) --update > torrserver_update.log 2>&1") | crontab -
  echo "✅ Автообновление включено. Проверьте файл torrserver_update.log для получения информации."

 # Установка базовых настроек
  settings_file="/opt/torrserver/settings.json"

  if [[ -f "$settings_file" ]]; then
    tmp_file=$(mktemp)

    jq '
      .BitTorr.CacheSize = 10485760000 |
      .BitTorr.ReaderReadAHead = 95 |
      .BitTorr.PreloadCache = 0 |
      .BitTorr.RemoveCacheOnDrop = true |
      .BitTorr.UseDisk = true |
      .BitTorr.TorrentsSavePath = "/opt/torrserver/cache" |
      .BitTorr.DisableUTP = false |
      .BitTorr.EnableRutorSearch = true
    ' "$settings_file" > "$tmp_file" &&  mv "$tmp_file" "$settings_file"

    # Восстанавливаем владельца и права доступа для файла settings.json
     chown torrserver:torrserver "$settings_file"
     chmod 644 "$settings_file"

    echo "✅ Базовые настройки TorrServer установлены."
    echo "✅ Путь хранения кеша: /opt/torrserver/cache"
    echo "🌍 Адрес сервера: http://$(curl -s ifconfig.me):$web_port"

    # Перезапуск TorrServer для применения настроек
     systemctl restart torrserver
  else
    echo "⚠️ Файл настроек не найден. Проверьте установку TorrServer."
  fi
}

# Функция удаления TorrServer
uninstall_torrserver() {
  echo ""
  echo "🚀 Удаление TorrServer..."

  web_port=$(cat /opt/torrserver/port.conf 2>/dev/null)

  if [[ -z "$web_port" ]]; then
    web_port=$(grep -oP '(?<=--port )\d+' /opt/torrserver/torrserver.config 2>/dev/null)
  fi

  if [[ -z "$web_port" ]]; then
    web_port="8090"
  fi

  echo " Запуск скрипта удаления TorrServer..."
   bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh) --remove

  # Проверяем, установлен ли UFW
  if command -v ufw &>/dev/null; then
    # Проверяем, активен ли UFW
    if ufw status | grep -q "Status: active"; then
      if ufw status | grep -q "$web_port"; then
        ufw delete allow "$web_port" 2>/dev/null
        echo "✅ Порт $web_port закрыт."
      else
        echo "ℹ️ Порт $web_port не был открыт в брандмауэре."
      fi
    else
      echo "ℹ️ UFW отключён, порты не управляются."
    fi
  else
    echo "ℹ️ UFW не установлен, удалите порты вручную."
  fi

  # Удаление задачи автообновления из crontab
  crontab -l | grep -v "bash <(curl -Ls https://raw.githubusercontent.com/YouROK/TorrServer/master/installTorrServerLinux.sh) --update > torrserver_update.log" | crontab -
  echo "✅ Автообновление отключено."

  # Удаление хвостов
  rm -rf torrserver_update.sh torrserver_update.log /opt/torrserver/port.conf 2>/dev/null
  echo "✅ Очистка временных файлов завершена."
}

# Функция работы с авторизацией
manage_auth() {
		local accs_db="/opt/torrserver/accs.db"
		[[ ! -f "$accs_db" ]] && echo "{}" |  tee "$accs_db" >/dev/null

		while true; do
				echo ""
				echo " 🔐 Меню авторизации:"
				echo "1️⃣  Добавить пользователя"
				echo "2️⃣  Удалить пользователя"
				echo "3️⃣  Отобразить всех пользователей"
				echo "4️⃣  Отключить авторизацию"
				echo "0️⃣  Назад"
				echo "=============================="
				read -p " Введите номер действия (0-4): " auth_choice

				case $auth_choice in
						1) add_user ;;
						2) remove_user ;;
						3) list_users ;;
						4) disable_auth ;;
						0) return ;;
						*) echo "❌ Некорректный ввод. Попробуйте снова." ;;
				esac
		done
}

# Функция добавления пользователя для авторизации
add_user() {
  local accs_db="/opt/torrserver/accs.db"
  local port_file="/opt/torrserver/port.conf"

  [[ ! -f "$accs_db" ]] && echo "{}" |  tee "$accs_db" >/dev/null

  read -p "Введите имя пользователя: " answer_user
  read -p "Введите пароль: " answer_pass

  if jq -e --arg user "$answer_user" '.[$user] != null' "$accs_db" >/dev/null; then
    auth_pass=$(jq -r --arg user "$answer_user" '.[$user]' "$accs_db")
    echo "Такое имя уже существует. Реквизиты для авторизации: $answer_user:$auth_pass"
  else
    tmp_file=$(mktemp)
    jq --arg user "$answer_user" --arg pass "$answer_pass" '. + {($user): $pass}' "$accs_db" > "$tmp_file" &&  mv "$tmp_file" "$accs_db"
    echo "✅ Пользователь $answer_user добавлен."
  fi

  # Добавляем данные в torrserver.config чтобы авторизация работала
  web_port=$(cat /opt/torrserver/port.conf 2>/dev/null)

  if [[ -z "$web_port" ]]; then
    web_port=$(grep -oP '(?<=--port )\d+' /opt/torrserver/torrserver.config 2>/dev/null)
  fi

  if [[ -z "$web_port" ]]; then
    web_port="8090"
  fi

    cat << EOF |  tee /opt/torrserver/torrserver.config >/dev/null
DAEMON_OPTIONS="--port $web_port --path /opt/torrserver --httpauth"
EOF
		
		# Восстанавливаем владельца и права доступа для файла accs_db чтобы torrserver мог считывать их
		 chown torrserver:torrserver "$accs_db"
		 chmod 644 "$accs_db"

  # Перезапуск сервиса
   systemctl restart torrserver
}

# Функция удаления пользователя
remove_user() {
  local accs_db="/opt/torrserver/accs.db"
  local port_file="/opt/torrserver/port.conf"

  # ANSI-коды для цвета
  RED='\033[1;31m'  # Красный
  NC='\033[0m'      # Сброс цвета

  # Проверяем, есть ли пользователи
  if [[ ! -f "$accs_db" || "$(jq 'keys | length' "$accs_db")" -eq 0 ]]; then
    echo "⚠️ Пользователи не найдены"
    return
  fi

  echo "📜 Список пользователей:"
  local users
  users=($(jq -r 'keys[]' "$accs_db"))  # Массив пользователей

  # Вывод списка пользователей с номерами
  for i in "${!users[@]}"; do
    echo -e "${RED}$((i + 1)).${NC} ${users[i]}"
  done

  # Запрос номера пользователя
  echo -en "\n📝 Введите номер пользователя для удаления: "
  read -r num

  # Проверка, является ли введённое значение числом
  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    echo "❌ Ошибка: Введите корректный номер!"
    return
  fi

  # Приводим к индексу массива
  local index=$((num - 1))

  # Проверяем, существует ли введённый номер
  if (( index < 0 || index >= ${#users[@]} )); then
    echo "❌ Ошибка: Неверный номер пользователя!"
    return
  fi

  local user="${users[index]}"

  # Удаляем пользователя
  jq "del(.\"$user\")" "$accs_db" > "${accs_db}.tmp" && mv "${accs_db}.tmp" "$accs_db"
  echo "✅ Пользователь '$user' удалён!"
	
		# Настраиваем torrserver.config
  web_port=$(cat /opt/torrserver/port.conf 2>/dev/null)
		
		if [[ -z "$web_port" ]]; then
    web_port=$(grep -oP '(?<=--port )\d+' /opt/torrserver/torrserver.config 2>/dev/null)
  fi

  if [[ -z "$web_port" ]]; then
    web_port="8090"
  fi
		
		[[ ! -f "$accs_db" ]] && { echo "❌ База пользователей не найдена."; return; }
		
		if [[ $(jq 'length' "$accs_db") -gt 0 ]]; then
    cat << EOF |  tee /opt/torrserver/torrserver.config >/dev/null
DAEMON_OPTIONS="--port $web_port --path /opt/torrserver --httpauth"
EOF
  else
    cat << EOF |  tee /opt/torrserver/torrserver.config >/dev/null
DAEMON_OPTIONS="--port $web_port --path /opt/torrserver"
EOF
    echo "✅ Все пользователи удалены. Авторизация отключена."
  fi
		
		# Восстанавливаем владельца и права доступа для файла accs_db чтобы torrserver мог считывать их
		 chown torrserver:torrserver "$accs_db"
		 chmod 644 "$accs_db"

  # Перезапуск сервиса
   systemctl restart torrserver
}

# Функция отображения всех пользователей
list_users() {
  local accs_db="/opt/torrserver/accs.db"

  # Проверяем, существует ли файл и не пуст ли он
  if [[ ! -f "$accs_db" || "$(jq 'keys | length' "$accs_db")" -eq 0 ]]; then
    echo -e "❌ Пользователи не найдены!"
    return
  fi

  # Выводим пользователей и пароли в цвете
  jq -r 'to_entries[] | "\u001b[1;34m" + .key + " \u001b[0;37m: \u001b[1;32m" + .value + "\u001b[0m"' "$accs_db"
}

# Функция отключения авторизации
disable_auth() {
  local port_file="/opt/torrserver/port.conf"

   rm -f /opt/torrserver/accs.db
		
		# Настраиваем torrserver.config
  web_port=$(cat /opt/torrserver/port.conf 2>/dev/null)
		
		if [[ -z "$web_port" ]]; then
    web_port=$(grep -oP '(?<=--port )\d+' /opt/torrserver/torrserver.config 2>/dev/null)
  fi

  if [[ -z "$web_port" ]]; then
    web_port="8090"
  fi
		
		  cat << EOF |  tee /opt/torrserver/torrserver.config >/dev/null
DAEMON_OPTIONS="--port $web_port --path /opt/torrserver"
EOF
    echo "✅ Все пользователи удалены. Авторизация отключена."

  # Перезапуск сервиса
   systemctl restart torrserver
}

# Функция очистки кэша
clear_cache() {
  # Проверяем, установлен ли TorrServer в systemctl
    if ! systemctl list-units --type=service --all | grep -q "torrserver"; then
        echo "⚠️  TorrServer не установлен или не зарегистрирован как сервис systemd!"
        return 1
    fi
    
  echo ""
  echo " Очистка кэша TorrServer..."

  if [[ -d /opt/torrserver/cache ]]; then
    find /opt/torrserver/cache -type f -delete
    echo "✅ Кэш очищен."
  else
    echo "⚠️ Папка /opt/torrserver/cache не найдена."
  fi
}

# Функция для отображения адреса сервера
show_server_address() {
    # Проверяем, установлен ли TorrServer в systemctl
    if ! systemctl list-units --type=service --all | grep -q "torrserver"; then
        echo "⚠️  TorrServer не установлен или не зарегистрирован как сервис systemd!"
        return 1
    fi

    web_port=$(cat /opt/torrserver/port.conf 2>/dev/null)

    if [[ -z "$web_port" ]]; then
        web_port=$(grep -oP '(?<=--port )\d+' /opt/torrserver/torrserver.config 2>/dev/null)
    fi

    if [[ -z "$web_port" ]]; then
        web_port="8090"
    fi

    echo ""
    echo "🌍 Адрес сервера: http://$(curl -s ifconfig.me):$web_port"
}

# Главное меню
while true; do
  echo ""
  echo " Выберите действие:"
  echo "1️⃣  Установка TorrServer"
  echo "2️⃣  Удаление TorrServer"
  echo "3️⃣  Авторизация"
  echo "4️⃣  Очистка кэша"
  echo "5️⃣  Показать адрес сервера"
  echo "0️⃣  Выход"
  echo "=============================="
  read -p " Введите номер действия (0-4): " choice

  case $choice in
    1) install_torrserver ;;
    2) uninstall_torrserver ;;
    3) manage_auth ;;
    4) clear_cache ;;
    5) show_server_address ;;
    0) echo " Выход."; exit ;;
    *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
  esac
done
