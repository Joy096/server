#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

INSTALL_DIR="/var/www/lampa"            # 📁 Директория для готовых файлов Lampa (веб-сервер)
SOURCE_DIR="/opt/lampa"                 # 🌳 Директория для клонированного репозитория (с готовыми файлами)
NGINX_CONF_NAME="lampa"                 # 📄 Имя файла конфигурации Nginx
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF_FILE="$NGINX_SITES_AVAILABLE/$NGINX_CONF_NAME"
REPO_URL="https://github.com/yumata/lampa.git" # 📦 Репозиторий с ГОТОВЫМИ файлами Lampa
DEFAULT_PORT=80                         # 🔌 Порт по умолчанию
LOG_FILE="/root/lampa_update.log"       # 📜 Лог файл для автообновления
CRON_MARKER="# LAMPACRON_GITHUB_AUTOUPDATE" # ⏰ Маркер для cron задачи

# 🔗 URL скрипта обновления (предоставлен пользователем)
GITHUB_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa_update.sh"
# 🔗 URL скрипта установки Torrserver
TORRSERVER_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh"

# 🔒 Проверка запуска от root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Ошибка: Этот скрипт должен выполняться от root!"
    echo "ℹ️ Пожалуйста, переключитесь на root ('su -' или 'sudo -i') и запустите заново."
    exit 1
fi

# 🔌 Проверка доступности порта
is_port_available() {
  local port="$1"
  if ss -tuln | grep -q ":$port\s"; then
    return 1 # Порт занят
  else
    return 0 # Порт свободен
  fi
}

# ❓ Запрос порта у пользователя
ask_for_port() {
  local chosen_port=$DEFAULT_PORT
  while true; do
    read -p "❓ Введите порт для Lampa (по умолчанию ${DEFAULT_PORT}): " input_port
    chosen_port=${input_port:-$DEFAULT_PORT}

    if ! [[ "$chosen_port" =~ ^[0-9]+$ ]]; then
       echo "❌ Ошибка: Введите корректный номер порта (число)."
       continue
    fi
    if [[ "$chosen_port" -lt 1 || "$chosen_port" -gt 65535 ]]; then
      echo "❌ Ошибка: Порт должен быть в диапазоне 1-65535."
      continue
    fi

    if is_port_available "$chosen_port"; then
      break # Просто выходим из цикла
    else
      echo "⚠️ Порт ${chosen_port} уже используется. Пожалуйста, выберите другой."
      if [[ "$chosen_port" -ne "$DEFAULT_PORT" ]]; then
          DEFAULT_PORT=$chosen_port
      fi
    fi
  done
  echo "$chosen_port"
}

# 🚀 Функция установки Lampa
install_lampa_simple() {
    echo ""
    echo "🚀 Установка Lampa 🚀"

    # Проверка существующей установки
    if [[ -d "$INSTALL_DIR" || -f "$NGINX_CONF_FILE" || -d "$SOURCE_DIR" ]]; then
        read -p "❓ Похоже, Lampa уже установлена. Переустановить? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then # Добавим русские 'Д/д'
            echo "🚫 Отмена переустановки."
            return 1 # Возвращаем код ошибки для индикации отмены
        fi
        echo "🔄 Продолжение переустановки..."
        # Вызываем удаление без подтверждения, проверяем результат
        if ! uninstall_lampa_internal "skip_confirmation"; then
             echo "❌ Ошибка во время удаления предыдущей версии. Установка прервана."
             return 1
        fi
    fi

    # Проверка и остановка Nginx
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx || { echo "❌ ОШИБКА: Не удалось остановить Nginx!"; return 1; }
    fi

    # Выбор порта
    local nginx_port
    echo ""
    echo "🌐 Запрос порта для Nginx..."
    nginx_port=$(ask_for_port) # Получаем ТОЛЬКО номер порта
    if [[ -z "$nginx_port" ]]; then echo "❌ Ошибка: Порт не был определен."; return 1; fi
    # Выводим сообщение об успехе ЗДЕСЬ:
    echo "✅ Порт ${nginx_port} выбран и свободен."

    # Установка минимально необходимых пакетов
    echo ""
    echo "🔄 Обновление списка пакетов и установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive # Как в примере, для неинтерактивной установки
    # Скрываем вывод apt update, но выводим apt install
    apt update > /dev/null
    apt install -y git nginx curl wget ca-certificates || { echo "❌ ОШИБКА: Не удалось установить пакеты."; return 1; }

    # Клонирование репозитория с ГОТОВЫМИ файлами
    echo ""
    echo "💾 Клонирование готовых файлов Lampa"
    if [[ -d "$SOURCE_DIR" ]]; then
        rm -rf "$SOURCE_DIR"
    fi
    # Используем git clone, проверяем результат
    git clone "${REPO_URL}" "${SOURCE_DIR}" || { echo "❌ ОШИБКА: 'git clone' не удался."; return 1; }

    # Подготовка веб-директории и копирование
    echo ""
    echo "📁 Создание/очистка директории веб-сервера: ${INSTALL_DIR}"
    mkdir -p "$INSTALL_DIR" || { echo "❌ Не удалось создать ${INSTALL_DIR}"; return 1; }
    rm -rf "${INSTALL_DIR}"/* || { echo "❌ Не удалось очистить ${INSTALL_DIR}"; return 1; }
    echo "📑 Копирование ГОТОВЫХ файлов Lampa в ${INSTALL_DIR}..."
    shopt -s dotglob # Включаем копирование скрытых файлов
    cp -r "${SOURCE_DIR}"/* "${INSTALL_DIR}/" || { echo "❌ Не удалось скопировать файлы Lampa."; shopt -u dotglob; return 1; }
    shopt -u dotglob # Выключаем обратно
    rm -rf "${INSTALL_DIR}/.git" # Удаляем .git из целевой директории

    # Настройка Nginx (остается такой же)
    echo ""
    echo "⚙️  Настройка Nginx..."
    rm -f "$NGINX_SITES_ENABLED/default" "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME"
    # Создание конфига Nginx
    cat <<EOF > "$NGINX_CONF_FILE"
server {
    listen ${nginx_port};
    listen [::]:${nginx_port};
    server_name _;
    root ${INSTALL_DIR};
    index index.html index.htm;
    location / { try_files \$uri \$uri/ /index.html; }
    location ~* \.(?:css|js|jpg|jpeg|gif|png|ico|svg|woff|woff2)$ { access_log off; log_not_found off; expires 1M; add_header Cache-Control "public"; }
}
EOF
    ln -s "$NGINX_CONF_FILE" "$NGINX_SITES_ENABLED/" || { echo "❌ Не удалось создать ссылку Nginx."; return 1; }
    echo "🩺 Проверка конфигурации Nginx..."
    if ! nginx -t; then echo "❌ ОШИБКА: Конфигурация Nginx неверна!"; rm -f "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME" "$NGINX_CONF_FILE"; return 1; fi

    # Запуск Nginx
    systemctl restart nginx || { echo "❌ ОШИБКА: Не удалось запустить/перезапустить Nginx!"; return 1; }

    # Настройка прав
    chown -R www-data:www-data "$INSTALL_DIR" || echo "⚠️ Не удалось изменить владельца."
    chmod -R 755 "$INSTALL_DIR" || echo "⚠️ Не удалось изменить права."

    # Настройка UFW
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            echo ""
            echo "🔥 UFW активен. Настройка правила для порта ${nginx_port}..."
            ufw delete allow proto tcp to any port "${nginx_port}" comment 'Lampa HTTP' &> /dev/null
            ufw allow "${nginx_port}/tcp" comment "Lampa HTTP" || echo "⚠️ Не удалось добавить правило UFW."
            echo "✔️  Правило UFW для TCP ${nginx_port} добавлено."
        else
             echo "ℹ️ UFW установлен, но не активен. Правило не добавлено."
        fi
    else
        echo "ℹ️ UFW не установлен. Откройте порт ${nginx_port} вручную."
    fi

    # Добавление Cron задачи
    echo ""
    echo "⏰ Добавление задачи автообновления в cron (ежедневно в 3:00)..."
    ( crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; \
      echo "0 3 * * * curl -sL '$GITHUB_SCRIPT_URL' | bash >> '$LOG_FILE' 2>&1 $CRON_MARKER" ) | crontab - || { echo "❌ ОШИБКА: Не удалось добавить задачу в cron."; }
    echo "✔️  Задача Cron добавлена."

    # Финальное сообщение
    echo ""
    echo "🔄 Автообновление настроено."
    echo "🌳 Клон репозитория с готовыми файлами: ${SOURCE_DIR}"
    echo "✅🎉 Установка Lampa успешно завершена! 🎉✅"
    echo ""
    show_address_internal "$nginx_port" # Показываем адрес в конце
    return 0
}

# 🗑️ Функция удаления Lampa
uninstall_lampa_internal() {
    local detected_port=""

    if [[ ! -f "$NGINX_CONF_FILE" && ! -d "$INSTALL_DIR" && ! -d "$SOURCE_DIR" ]]; then
        echo "ℹ️ Lampa не установлена."
        return 0 # Успех, т.к. делать нечего
    fi

    if [[ -f "$NGINX_CONF_FILE" ]]; then
        detected_port=$(grep -E '^\s*listen\s+[0-9]+;' "$NGINX_CONF_FILE"|head -n 1|sed -E 's/^\s*listen\s+([0-9]+);.*/\1/')
        [[ -n "$detected_port" ]]
    fi

    echo ""
    echo "⏰ Удаление задачи cron..."
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - || echo "⚠️ Не удалось удалить cron."
    else
        echo "ℹ️ Cron не найден."
    fi

    echo "⚙️  Удаление Nginx конфига..."
    rm -f "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME" "$NGINX_CONF_FILE"
    nginx -t || echo "ℹ️ Конфиг Nginx пуст/некорректен."
    systemctl reload nginx || echo "ℹ️ Nginx не активен/reload не удался."
    if ! systemctl is-active --quiet nginx; then
        if systemctl list-unit-files | grep -q 'nginx.service'; then
            echo "⚠️ Nginx не активен. Запуск..."; systemctl start nginx || echo "❌ Не удалось запустить Nginx.";
        fi
    fi

    echo ""
    echo "📁 Удаление ${INSTALL_DIR}..."; rm -rf "$INSTALL_DIR"
    echo "🌳 Удаление ${SOURCE_DIR}..."; rm -rf "$SOURCE_DIR"
    echo "📜 Удаление ${LOG_FILE}..."; rm -f "$LOG_FILE"

    # Удаление правила UFW
    if [[ -n "$detected_port" ]]; then
      if command -v ufw &> /dev/null; then
          if ufw status | grep -q "Status: active"; then
              if ufw delete allow proto tcp to any port "${detected_port}" comment 'Lampa HTTP' &> /dev/null; then
                  echo "✔️  Правило UFW удалено."
              else
                  echo "ℹ️ Правило UFW для порта ${detected_port} (Lampa HTTP) не найдено."
              fi
          fi
      fi
    fi
    echo "✅🎉 Удаление Lampa завершено! 🎉✅"
    return 0
}

uninstall_lampa() {
    uninstall_lampa_internal
}

# 🌐 Функция показа адреса
show_address_internal() {
    local port_to_show=$1
    local public_ip

    # Пытаемся получить внешний IP. Используем -m 5 для таймаута в 5 секунд.
    public_ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 api.ipify.org || curl -s -m 5 icanhazip.com || echo "")

    if [[ -z "$public_ip" ]]; then
        echo "⚠️ Не удалось определить внешний IP-адрес сервера через ifconfig.me/api.ipify.org/icanhazip.com."
        echo "   Показываем локальные IP (могут быть недоступны извне):"
        # В качестве запасного варианта покажем локальные
        local ip_addresses
        ip_addresses=$(ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1')
        if [[ -z "$ip_addresses" ]]; then
             echo "⚠️ Не удалось определить и локальные IP-адреса."
             return 1
        fi
        for ip in $ip_addresses; do
            echo "   ➡️  http://${ip}:${port_to_show}"
        done
        return 1 # Возвращаем ошибку, т.к. основной метод не сработал
    fi

    echo "🌍 Адрес сервера: http://${public_ip}:${port_to_show}"
}

show_address() {
    local detected_port=""
    echo ""
    if [[ -f "$NGINX_CONF_FILE" ]]; then
        detected_port=$(grep -E '^\s*listen\s+[0-9]+;' "$NGINX_CONF_FILE"|head -n 1|sed -E 's/^\s*listen\s+([0-9]+);.*/\1/')
        if [[ -n "$detected_port" ]]; then
            show_address_internal "$detected_port"
        else
            echo "⚠️ Конфиг найден, порт не определен."
        fi
    else
        echo "ℹ️ Конфиг Nginx не найден."
    fi
}

# ⚙️ Функция запуска скрипта Torrserver
run_torrserver_script() {
      if wget https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh; then
          chmod +x torrserver.sh
          bash torrserver.sh 
      else
          echo "❌ Ошибка при скачивании скрипта Torrserver."
      fi
}

# --- 🎬 Основная часть скрипта (Меню) ---
while true; do
  echo ""
  echo " 🎬 ======== Меню Lampa ======== 🎬"
  echo " 1️⃣  🚀 Установить / Переустановить Lampa"
  echo " 2️⃣  🗑️  Удалить Lampa"
  echo " 3️⃣  🌐 Показать адрес сервера Lampa"
  echo " 4️⃣  🎬 Torrserver (Установка/Управление)"
  echo " 0️⃣  👋 Выход"
  echo ""
  read -p "👉 Введите номер действия (0-3): " choice

  case $choice in
    1)
      install_lampa_simple # Используем простую установку
      ;;
    2)
      uninstall_lampa
      ;;
    3)
      show_address
      ;;
    4)
      run_torrserver_script
      continue
      ;;
    0)
      echo "👋 Выход."
      echo ""
      exit 0
      ;;
    *)
      echo "❌ Некорректный ввод. Попробуйте снова."
      ;;
  esac
  echo ""
  read -p "Нажмите Enter для продолжения..." enter_key
done
