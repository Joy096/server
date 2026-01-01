#!/bin/bash

#=============================================================================
# Скрипт для установки и управления серверами Minecraft Bedrock Edition
# Автоматизирует установку, настройку и управление серверами
# Работает в режиме управления несколькими серверами.
#=============================================================================

# --- Глобальные переменные/настройки ---

# Пользователь для запуска серверов
SERVER_USER="minecraft"

# Настройки резервного копирования (глобальные для всех серверов)
BACKUP_DIR="/opt/minecraft_bds_backups"
MAX_BACKUPS=10
BACKUP_WORLDS_ONLY=false # false = полный бэкап, true = только папка worlds

# Настройки Мультисерверного Режима (теперь всегда активен)
MULTISERVER_ENABLED=true # Этот флаг теперь всегда true
SERVERS_CONFIG_DIR="/etc/minecraft_servers"
SERVERS_CONFIG_FILE="$SERVERS_CONFIG_DIR/servers.conf"
SERVERS_BASE_DIR="/opt/minecraft_servers" # Базовая директория для всех серверов

# Переменные для ТЕКУЩЕГО АКТИВНОГО СЕРВЕРА (загружаются из конфига)
ACTIVE_SERVER_ID=""         # ID активного сервера (например, "main")
DEFAULT_INSTALL_DIR=""      # Путь к папке активного сервера
SERVICE_NAME=""             # Имя systemd сервиса активного сервера
SERVICE_FILE=""             # Полный путь к файлу сервиса активного сервера
SERVER_PORT=""              # Порт активного сервера

# --- Утилитарные функции ---

# Функция для вывода информационных сообщений
msg() {
    echo -e "🔹 $1"
}

# Функция для вывода предупреждений
warning() {
    echo -e "⚠️ $1"
}

# Функция для вывода ошибок и завершения скрипта
error() {
    echo -e "❌ $1" >&2
    # Не выходим из скрипта при ошибке внутри функции,
    # чтобы можно было обработать ее в вызывающем коде, если нужно.
    # Используйте 'return 1' в функциях и проверяйте '$?'
    # Для фатальных ошибок, где продолжение невозможно, можно оставить exit 1
    # или обрабатывать выше. Пока оставим вывод в stderr.
    # exit 1 # Раскомментируйте, если ошибка должна быть фатальной
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "❌ Этот скрипт нужно запускать с правами root (используйте sudo)." >&2
        exit 1 # Запуск без root - фатально
    fi
}

# --- Функции автообновления ---

get_latest_bedrock_version_info() {
    local download_api_url="https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
    local user_agent="Mozilla/5.0 (X11; CrOS x86_64 12871.102.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.141 Safari/537.36"
    local backup_url="https://raw.githubusercontent.com/ghwns9652/Minecraft-Bedrock-Server-Updater/main/backup_download_link.txt"
    
    # Пытаемся получить JSON с официального API
    local json_response
    json_response=$(curl -s -H "User-Agent: $user_agent" --max-time 10 "$download_api_url")
    
    local download_link=""
    
    if [ -n "$json_response" ]; then
        # Парсим JSON с помощью jq
        download_link=$(echo "$json_response" | jq -r '.result.links[] | select(.downloadType == "serverBedrockLinux") | .downloadUrl')
    fi
    
    # Если ссылка не найдена или ошибка сети, пробуем бэкап URL (как в python скрипте)
    if [ -z "$download_link" ] || [ "$download_link" == "null" ]; then
        warning "Не удалось получить ссылку с официального API. Пробуем резервный источник..."
        download_link=$(curl -s -H "User-Agent: $user_agent" --max-time 10 "$backup_url")
    fi
    
    if [ -z "$download_link" ] || [[ "$download_link" != http* ]]; then
        return 1 # Ошибка получения ссылки
    fi
    
    echo "$download_link"
    return 0
}

# Ядро обновления (общая логика для ручного и авто)
# Аргументы: $1 - путь к zip файлу, $2 - версия (опционально)
perform_update_core() {
    local zip_file_path="$1"
    local version_label="$2"
    
    if [ -z "$zip_file_path" ] || [ ! -f "$zip_file_path" ]; then
        error "Файл обновления не найден: $zip_file_path"
        return 1
    fi

    local update_backup_dir="$DEFAULT_INSTALL_DIR/update_data_backup_$(date +%s)"

    msg "--- Начало обновления сервера '$ACTIVE_SERVER_ID' ---"
    msg "Используемый файл: $zip_file_path"
    
    msg "Создание полной резервной копии перед обновлением..."
    local old_backup_setting=$BACKUP_WORLDS_ONLY
    BACKUP_WORLDS_ONLY=false
    
    # Автоматически останавливаем сервер перед бэкапом, если он запущен
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        msg "Сервер запущен. Остановка для создания корректного бэкапа..."
        stop_server
        sleep 2
    fi
    
    if ! create_backup; then
        read -p "Не удалось создать резервную копию! Продолжить БЕЗ основной копии? (yes/no): " BACKUP_FAIL_CONFIRM
        if [[ "$BACKUP_FAIL_CONFIRM" != "yes" ]]; then 
            BACKUP_WORLDS_ONLY=$old_backup_setting
            error "Обновление отменено пользователем."
            return 1
        fi
    fi
    BACKUP_WORLDS_ONLY=$old_backup_setting

    msg "Остановка сервера '$SERVICE_NAME'..."
    if ! stop_server; then warning "Не удалось остановить сервер, но продолжим обновление..."; fi
    sleep 3

    msg "Создание директории для сохранения текущих данных: $update_backup_dir"
    sudo rm -rf "$update_backup_dir"; sudo mkdir -p "$update_backup_dir"
    sudo chown "$SERVER_USER":"$SERVER_USER" "$update_backup_dir"
    
    msg "Перемещение пользовательских данных во временную директорию..."
    local moved_something=0
    local files_to_keep=("worlds" "server.properties" "permissions.json" "whitelist.json" "behavior_packs" "resource_packs" "valid_known_packs.json" "config" "allowlist.json")
    
    for item in "${files_to_keep[@]}"; do
      if [ -e "$DEFAULT_INSTALL_DIR/$item" ]; then
         if sudo -u "$SERVER_USER" mv "$DEFAULT_INSTALL_DIR/$item" "$update_backup_dir/"; then
             msg "  - '$item' сохранено."
             moved_something=1
         else
             warning "  - Не удалось переместить '$item'. Попытка через sudo..."
             if sudo mv "$DEFAULT_INSTALL_DIR/$item" "$update_backup_dir/"; then msg "  - '$item' перемещено через sudo."; moved_something=1; else warning "  - Ошибка перемещения '$item' даже через sudo."; fi
         fi
      fi
    done
    if [ "$moved_something" -eq 0 ]; then warning "Не удалось сохранить пользовательские данные. Возможно, это была первая установка?"; fi

    msg "Очистка директории сервера '$DEFAULT_INSTALL_DIR' от старых файлов..."
    sudo find "$DEFAULT_INSTALL_DIR" -maxdepth 1 -mindepth 1 ! -name "$(basename "$update_backup_dir")" -exec rm -rf {} \;

    msg "Распаковка архива '$zip_file_path'..."
    if ! sudo unzip -oq "$zip_file_path" -d "$DEFAULT_INSTALL_DIR"; then
        warning "Ошибка распаковки архива! Попытка восстановить данные..."
        if [ -d "$update_backup_dir" ]; then sudo mv "$update_backup_dir"/* "$DEFAULT_INSTALL_DIR/" 2>/dev/null; fi
        sudo rm -rf "$update_backup_dir"
        error "Не удалось распаковать архив. Убедитесь, что это корректный zip-файл."
        return 1
    fi

    msg "Возвращение пользовательских данных..."
    if [ -d "$update_backup_dir" ]; then
        sudo rsync -a --remove-source-files "$update_backup_dir/" "$DEFAULT_INSTALL_DIR/"
        sudo rm -rf "$update_backup_dir"
    fi

    msg "Установка прав доступа..."
    if ! sudo chown -R "$SERVER_USER":"$SERVER_USER" "$DEFAULT_INSTALL_DIR"; then warning "Не удалось изменить владельца."; fi
    if [ -f "$DEFAULT_INSTALL_DIR/bedrock_server" ]; then 
        if ! sudo chmod +x "$DEFAULT_INSTALL_DIR/bedrock_server"; then warning "Не удалось установить +x."; fi
    else 
        warning "bedrock_server не найден после распаковки!"
    fi

    # Обновляем файл версии
    if [ -n "$version_label" ]; then
        msg "Запись версии '$version_label' в файл..."
        echo "$version_label" | sudo tee "$DEFAULT_INSTALL_DIR/version" > /dev/null
        sudo chown "$SERVER_USER":"$SERVER_USER" "$DEFAULT_INSTALL_DIR/version"
    else
        warning "Версия не передана, файл 'version' не обновлен."
    fi

    msg "Запуск обновленного сервера '$SERVICE_NAME'..."
    if ! start_server; then error "Сервер обновлен, но не запустился. Проверьте логи."; return 1; fi

    msg "✅ Обновление сервера успешно завершено!"
    return 0
}

# Ротация лог-файла (если больше 1MB — оставить первые 1000 строк, т.к. новые записи сверху)
rotate_log_if_needed() {
    local log_file="$1"
    local max_size=1048576  # 1MB в байтах
    local keep_lines=1000
    
    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        return 0
    fi
    
    local file_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
    if [ "$file_size" -gt "$max_size" ]; then
        # Новые записи сверху, поэтому оставляем первые строки (head), а не последние
        head -n "$keep_lines" "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
        # Добавляем пометку о ротации в начало
        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Log rotation: kept first ${keep_lines} lines ==="; cat "$log_file"; } > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

# Добавление записи в начало лог-файла (новые записи сверху)
prepend_to_log() {
    local log_file="$1"
    local content="$2"
    
    if [ -z "$log_file" ]; then return 1; fi
    
    if [ -f "$log_file" ]; then
        { echo "$content"; cat "$log_file"; } > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    else
        echo "$content" > "$log_file"
    fi
}

# Автоматическое обновление
# Проверка наличия онлайн игроков через команду сервера
are_players_online() {
    local screen_name="bds_${ACTIVE_SERVER_ID}"
    
    # Проверяем, запущен ли сервер
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        return 1 # Сервер не запущен = игроков нет
    fi
    
    # Проверяем, существует ли screen сессия
    if ! sudo -u "$SERVER_USER" screen -list 2>/dev/null | grep -q "$screen_name"; then
        return 1
    fi
    
    # Создаём временный файл для вывода
    local tmp_file="/tmp/mc_players_check_$$"
    
    # Отправляем команду list и ждём ответ
    # Используем hardcopy для захвата вывода screen
    sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "list^M" 2>/dev/null
    sleep 1
    sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X hardcopy "$tmp_file" 2>/dev/null
    sleep 0.5
    
    if [ -f "$tmp_file" ]; then
        # Ищем строку вида "There are X/Y players online:"
        # Извлекаем число игроков универсальным способом
        local line=$(grep "There are" "$tmp_file" 2>/dev/null | tail -1)
        rm -f "$tmp_file"
        
        if [ -n "$line" ]; then
            # Извлекаем первое число после "There are "
            local player_count=$(echo "$line" | sed -n 's/.*There are \([0-9]*\).*/\1/p')
            
            if [ -n "$player_count" ] && [ "$player_count" -gt 0 ]; then
                echo "Players online: $player_count"
                return 0 # Есть игроки онлайн
            fi
        fi
    else
        rm -f "$tmp_file" 2>/dev/null
    fi
    
    return 1 # Игроков нет или не удалось проверить
}

auto_update_server() {
    local mode="$1" # "interactive" (по умолчанию) или "silent"

    if [ -z "$ACTIVE_SERVER_ID" ]; then
        if [ "$mode" != "silent" ]; then error "Активный сервер не выбран."; fi
        return 1
    fi
    
    # В тихом режиме (cron) ротируем лог и проверяем игроков
    if [ "$mode" == "silent" ]; then
        # Ротация лога если нужно
        rotate_log_if_needed "/var/log/minecraft_update_${ACTIVE_SERVER_ID}.log"
        
        # Проверяем игроков перед началом любых действий
        if are_players_online; then
            echo "Auto-update deferred: Players are online on port $SERVER_PORT."
            return 0
        fi
    fi
    
    if [ "$mode" != "silent" ]; then msg "🔎 Проверка обновлений для сервера '$ACTIVE_SERVER_ID'..."; fi

    local current_version="unknown"
    if [ -f "$DEFAULT_INSTALL_DIR/version" ]; then
        current_version=$(cat "$DEFAULT_INSTALL_DIR/version")
    fi
    if [ "$mode" != "silent" ]; then msg "Текущая версия: $current_version"; fi

    local latest_url
    latest_url=$(get_latest_bedrock_version_info)
    
    if [ $? -ne 0 ] || [ -z "$latest_url" ]; then
        if [ "$mode" != "silent" ]; then error "Не удалось получить информацию о последней версии."; fi
        return 1
    fi

    # Извлекаем версию из URL
    local latest_version
    local filename=$(basename "$latest_url")
    latest_version=$(echo "$filename" | sed -E 's/bedrock-server-(.*)\.zip/\1/')

    if [ "$mode" != "silent" ]; then msg "Последняя доступная версия: $latest_version"; fi

    if [ "$current_version" == "$latest_version" ]; then
        if [ "$mode" != "silent" ]; then
            msg "✅ У вас уже установлена последняя версия."
        else
            echo "Auto-update: No update needed. Current version $current_version is latest."
        fi
        return 0
    fi

    if [ "$mode" != "silent" ]; then
        msg "🚀 Доступна новая версия! ($current_version -> $latest_version)"
        read -p "Хотите обновить сервер сейчас? (yes/no): " UPDATE_NOW
        if [[ "$UPDATE_NOW" != "yes" ]]; then
            msg "Обновление отложено."
            return 0
        fi
    else
        echo "Auto-update: New version found ($current_version -> $latest_version). Updating..."
    fi

    local download_dir="/tmp/minecraft_update"
    mkdir -p "$download_dir"
    local zip_file="$download_dir/$filename"

    if [ "$mode" != "silent" ]; then msg "Скачивание обновления..."; fi
    
    # Используем wget (-q для silent режима если нужно, но пока оставим вывод в лог)
    local wget_opts="-U \"Mozilla/5.0 ...\"" 
    if [ "$mode" == "silent" ]; then 
        if ! wget -q -U "Mozilla/5.0 (X11; CrOS x86_64 12871.102.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.141 Safari/537.36" -O "$zip_file" "$latest_url"; then
             echo "Error downloading update." >&2; return 1
        fi
    else
        if ! wget -U "Mozilla/5.0 (X11; CrOS x86_64 12871.102.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.141 Safari/537.36" -O "$zip_file" "$latest_url"; then
            error "Ошибка скачивания обновления."
            return 1
        fi
    fi

    perform_update_core "$zip_file" "$latest_version"
    local update_result=$?
    
    # Очистка
    rm -rf "$download_dir"
    
    return $update_result
}

# Проверка наличия установленного АКТИВНОГО сервера
is_server_installed() {
    # Проверяем, что директория активного сервера задана и существует
    if [ -z "$DEFAULT_INSTALL_DIR" ]; then
        # Если активный сервер не выбран, считаем, что он не установлен
        return 1
    fi
    if [ -d "$DEFAULT_INSTALL_DIR" ] && [ -f "$DEFAULT_INSTALL_DIR/bedrock_server" ]; then
        return 0 # Установлен
    else
        return 1 # Не установлен
    fi
}

# Установка необходимых зависимостей
install_dependencies() {
    # Проверяем наличие curl и jq (для автообновления)
    if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
        warning "Не найдены 'curl' или 'jq'. Попытка установить..."
        if sudo apt-get update -y > /dev/null 2>&1 && sudo apt-get install -y curl jq > /dev/null 2>&1; then
            msg "✅ curl и jq успешно установлены."
        else
            error "Не удалось установить curl/jq. Автообновление может не работать."
        fi
    fi

    # --- ARM Check (Always run this check on ARM) ---
    if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        if ! command -v box64 >/dev/null; then
            warning "⚠️ Обнаружена архитектура ARM. Для запуска сервера Minecraft Bedrock (x86_64) требуется эмулятор Box64."
            read -p "Установить Box64 автоматически? (yes/no): " INSTALL_BOX64
            if [[ "$INSTALL_BOX64" == "yes" ]]; then
                msg "Добавление репозитория Box64..."
                # Используем метод Ryan Fortner (рекомендуемый для Ubuntu/Debian)
                if sudo wget https://ryanfortner.github.io/box64-debs/box64.list -O /etc/apt/sources.list.d/box64.list; then
                    wget -qO- https://ryanfortner.github.io/box64-debs/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/box64.gpg
                    sudo apt-get update
                    msg "Установка Box64..."
                    if sudo apt-get install -y box64; then
                        msg "✅ Box64 успешно установлен."
                    else
                        error "Не удалось установить Box64 через apt."
                    fi
                else
                    error "Не удалось скачать список репозитория Box64."
                fi
            else
                warning "Box64 не установлен. Сервер не запустится."
            fi
        fi
    fi

    # 1. Если маркер есть - выходим
    if [ -f "$marker_file" ]; then
        return 0
    fi

    # 2. Если маркера нет, но команды ЕСТЬ - создаем маркер и выходим
    if command -v unzip >/dev/null && command -v wget >/dev/null && command -v curl >/dev/null && command -v screen >/dev/null && command -v jq >/dev/null && command -v zip >/dev/null && (command -v ss >/dev/null || command -v netstat >/dev/null); then
         # Создаем маркер
         sudo mkdir -p "$(dirname "$marker_file")"
         if [ -n "$marker_file" ]; then
         sudo touch "$marker_file"
         fi
         return 0
    fi

    msg "Обновление списка пакетов..."
    # Подавляем вывод, проверяем код возврата
    if ! sudo apt-get update > /dev/null; then
        warning "Не удалось обновить список пакетов. Проверьте интернет-соединение."
    fi

    msg "Установка необходимых пакетов (unzip, wget, curl, libssl-dev, screen, nano, ufw, jq, zip, gpg, net-tools)..."
    # Добавили zip для архива миграции и gpg для box64, net-tools для проверки подключений
    if ! sudo apt-get install -y unzip wget curl libssl-dev screen nano ufw jq zip gpg net-tools > /dev/null; then
        # Используем error и exit, так как без зависимостей скрипт бесполезен
        error "Не удалось установить зависимости. Установите вручную: sudo apt install unzip wget curl libssl-dev screen nano ufw jq zip gpg net-tools"
        exit 1
    fi

    # Включаем UFW, если он не активен
    if ! sudo ufw status | grep -q "Status: active"; then
        msg "Включение фаервола UFW..."
        # Подавляем вывод 'y'
        if ! echo "y" | sudo ufw enable; then
            warning "Не удалось включить UFW."
        fi
    fi
    
    # Создаем маркер успешной установки
    sudo mkdir -p "$(dirname "$marker_file")"
    if [ -n "$marker_file" ]; then
    sudo touch "$marker_file"
    fi
}

# Создание пользователя для запуска сервера (если еще не создан)
create_server_user() {
    if id "$SERVER_USER" &>/dev/null; then
        # Пользователь уже существует - молчим
        :
    else
        msg "Создание системного пользователя '$SERVER_USER' без домашней директории..."
        # Создаем системного пользователя (-r) без создания домашней директории (-M)
        # Используем /usr/sbin/nologin как оболочку для безопасности
        if ! sudo useradd -r -M -U -s /usr/sbin/nologin "$SERVER_USER"; then
            error "Не удалось создать пользователя '$SERVER_USER'."
            exit 1 # Критическая ошибка
        fi
        msg "Пользователь '$SERVER_USER' создан."
    fi
}

# Открытие порта в фаерволе
open_firewall_port() {
    local port_to_open="$1" # Принимаем порт как аргумент

    if [ -z "$port_to_open" ]; then
        warning "Внутренняя ошибка: Порт не передан в open_firewall_port."
        return 1
    fi

    msg "Проверка и открытие UDP порта $port_to_open в UFW..."
    # Добавляем правило, если его еще нет
    if ! sudo ufw status | grep -qw "$port_to_open/udp"; then
        sudo ufw allow "$port_to_open"/udp comment "Minecraft Bedrock Server ($port_to_open)" > /dev/null
        if ! sudo ufw reload > /dev/null; then
            warning "Не удалось перезагрузить правила UFW."
        else
             msg "Правило для UDP порта $port_to_open добавлено."
        fi
    else
         msg "Правило для UDP порта $port_to_open уже существует."
    fi
    return 0
}

# Закрытие порта в фаерволе
close_firewall_port() {
    local port_to_close="$1" # Принимаем порт как аргумент

    if [ -z "$port_to_close" ]; then
        warning "Внутренняя ошибка: Порт не передан в close_firewall_port."
        return 1
    fi

    msg "Попытка удаления правила для UDP порта $port_to_close из UFW..."
    # Удаляем правило, если оно есть
    if sudo ufw status | grep -qw "$port_to_close/udp"; then
        sudo ufw delete allow "$port_to_close"/udp > /dev/null
        if ! sudo ufw reload > /dev/null; then
            warning "Не удалось перезагрузить правила UFW."
        else
             msg "Правило для порта $port_to_close удалено."
        fi
    else
         msg "Правило для порта $port_to_close не найдено."
    fi
    return 0
}

# Создание systemd сервиса для автоматического запуска
create_systemd_service() {
    local current_install_dir="$1"    # Принимаем путь как аргумент
    local current_service_name="$2"   # Принимаем имя сервиса как аргумент
    local current_service_file="/etc/systemd/system/${current_service_name}"

    if [ -z "$current_install_dir" ] || [ -z "$current_service_name" ]; then
        error "Внутренняя ошибка: Путь установки или имя сервиса не переданы в create_systemd_service."
        return 1
    fi

    msg "Создание/Обновление файла systemd сервиса: $current_service_file"

    # Имя screen сессии будет таким же, как имя сервиса без ".service"
    local screen_session_name="${current_service_name%.service}"

    # Определяем команду запуска в зависимости от архитектуры
    local exec_cmd="./bedrock_server"
    local arch=$(uname -m)
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        if command -v box64 >/dev/null; then
            msg "⚠️ Обнаружена архитектура ARM ($arch). Используем Box64 для запуска."
            exec_cmd="box64 ./bedrock_server"
        else
            warning "❌ Обнаружена архитектура ARM ($arch), но Box64 не найден!"
            warning "Сервер Minecraft Bedrock (x86_64) не может работать на ARM без эмулятора."
            warning "Пожалуйста, установите Box64 (https://github.com/ptitSeb/box64) и пересоздайте сервис."
        fi
    fi

    # Создаем файл сервиса
    # Используем sudo tee для записи от имени root
    if ! echo "[Unit]
Description=Minecraft Bedrock Server ($current_service_name)
After=network.target

[Service]
User=$SERVER_USER
Group=$SERVER_USER
WorkingDirectory=$current_install_dir
ExecStart=/usr/bin/screen -DmS ${screen_session_name} bash -c 'LD_LIBRARY_PATH=. $exec_cmd'
ExecStop=/usr/bin/screen -p 0 -S ${screen_session_name} -X stuff $'stop\015'
ExecStopPost=/bin/sh -c \"sleep 1 && /usr/bin/screen -S ${screen_session_name} -X quit || true\"
TimeoutStopSec=70
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
" | sudo tee "$current_service_file" > /dev/null; then
        error "Не удалось записать в файл сервиса $current_service_file."
        return 1
    fi

    # Устанавливаем права на файл сервиса
    if ! sudo chmod 644 "$current_service_file"; then
        warning "Не удалось установить права 644 на $current_service_file."
    fi

    msg "Перезагрузка конфигурации systemd..."
    if ! sudo systemctl daemon-reload; then
        # Это критично для применения изменений
        error "Не удалось перезагрузить конфигурацию systemd (daemon-reload)."
        return 1
    fi

    # Включаем автозапуск сервиса
    msg "Включение автозапуска сервиса '$current_service_name'..."
    if ! sudo systemctl enable "$current_service_name"; then
        # Не фатально, но важно
        warning "Не удалось включить автозапуск сервиса '$current_service_name'."
    fi

    msg "Systemd сервис '$current_service_name' успешно создан/обновлен и включен."
    return 0
}

# --- ОПРЕДЕЛЕНИЕ Функции Мультисерверной Инициализации ---
init_multiserver() {
    msg "Инициализация/Проверка мультисерверного режима..."

    # Гарантируем наличие зависимостей и пользователя
    install_dependencies
    create_server_user

    # Создаем директории, если их нет (используем sudo)
    if [ ! -d "$SERVERS_CONFIG_DIR" ]; then
        msg "Создание директории конфигурации: $SERVERS_CONFIG_DIR"
        sudo mkdir -p "$SERVERS_CONFIG_DIR" || { error "Не удалось создать $SERVERS_CONFIG_DIR"; return 1; }
    fi
    if [ ! -d "$SERVERS_BASE_DIR" ]; then
        msg "Создание базовой директории серверов: $SERVERS_BASE_DIR"
        sudo mkdir -p "$SERVERS_BASE_DIR" || { error "Не удалось создать $SERVERS_BASE_DIR"; return 1; }
        # Устанавливаем владельца базовой папки серверов
        if ! sudo chown "$SERVER_USER":"$SERVER_USER" "$SERVERS_BASE_DIR"; then
             warning "Не удалось установить владельца для $SERVERS_BASE_DIR"
        fi
    fi

    # Проверяем/создаем конфигурационный файл
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then
        msg "Создание файла конфигурации $SERVERS_CONFIG_FILE"
        # Создаем файл и сразу пишем заголовки
        if ! echo -e "# Конфигурация серверов Minecraft Bedrock\n# Формат: SERVER_ID:NAME:PORT:INSTALL_DIR:SERVICE_NAME\n# Пример: main:Основной сервер:19132:/opt/minecraft_servers/main:bds_main.service" | sudo tee "$SERVERS_CONFIG_FILE" > /dev/null; then
             error "Не удалось создать файл конфигурации $SERVERS_CONFIG_FILE."; return 1;
        fi
        # Права на файл конфига обычно root:root или root:adm, оставляем как есть (644)
        sudo chmod 644 "$SERVERS_CONFIG_FILE"

        # --- Логика миграции существующего сервера из /opt/minecraft_bds ---
        local old_default_dir="/opt/minecraft_bds" # Стандартный путь одиночного сервера
        # Проверяем наличие старого сервера ТОЛЬКО если конфиг только что создан
        if [ -d "$old_default_dir" ] && [ -f "$old_default_dir/bedrock_server" ]; then
             warning "Обнаружен существующий сервер старого типа в '$old_default_dir'."
             read -p "Хотите МИГРИРОВАТЬ его в новую мультисерверную структуру? (yes/no): " MIGRATE_EXISTING
             if [[ "$MIGRATE_EXISTING" == "yes" ]]; then
                 # Получаем старые данные (порт, имя сервиса)
                 local old_service="bds.service" # Стандартное имя сервиса
                 local old_port=$(get_property "server-port" "$old_default_dir/server.properties" "19132") # Пробуем прочитать порт
                 local old_service_file="/etc/systemd/system/$old_service"

                 # Запрашиваем новые данные
                 local server_id server_name new_dir new_service new_port
                 read -p "Введите НОВЫЙ ID для этого сервера [main]: " server_id; server_id=${server_id:-"main"}
                 # Проверка ID на корректность и уникальность
                 if ! [[ "$server_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then error "ID содержит недопустимые символы."; return 1; fi
                 if grep -q "^${server_id}:" "$SERVERS_CONFIG_FILE"; then error "ID '$server_id' уже используется."; return 1; fi

                 read -p "Введите имя для этого сервера [Основной]: " server_name; server_name=${server_name:-"Основной"}
                 read -p "Введите порт для этого сервера [$old_port]: " new_port; new_port=${new_port:-$old_port}
                  # Проверка порта
                 if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then error "Некорректный порт."; return 1; fi

                 new_dir="$SERVERS_BASE_DIR/$server_id"
                 new_service="bds_${server_id}.service"

                 msg "Начинаю миграцию сервера '$server_name' (ID: $server_id)..."
                 msg "Новая директория: $new_dir"
                 msg "Новый сервис: $new_service"
                 msg "Порт: $new_port"

                 # 1. Остановить старый сервис (если запущен)
                 if sudo systemctl is-active --quiet "$old_service"; then
                      msg "Остановка старого сервиса '$old_service'..."
                      if ! sudo systemctl stop "$old_service"; then warning "Не удалось остановить старый сервис."; fi
                      sleep 2
                 fi

                 # 2. Создать новую директорию
                 msg "Создание директории '$new_dir'..."
                 if ! sudo mkdir -p "$new_dir"; then error "Не удалось создать '$new_dir'"; return 1; fi

                 # 3. Переместить файлы
                 msg "Перемещение файлов из '$old_default_dir' в '$new_dir'..."
                 # Используем sudo mv -v для вывода перемещаемых файлов
                 if ! sudo mv -v "$old_default_dir"/* "$new_dir/"; then error "Не удалось переместить файлы сервера."; sudo rm -rf "$new_dir"; return 1; fi
                 # Удаляем старую пустую папку
                 if ! sudo rmdir "$old_default_dir"; then warning "Не удалось удалить старую пустую папку '$old_default_dir'"; fi

                 # 4. Установить владельца
                 msg "Установка владельца для '$new_dir'..."
                 if ! sudo chown -R "$SERVER_USER":"$SERVER_USER" "$new_dir"; then warning "Не удалось установить владельца."; fi

                 # 5. Отключить и удалить старый сервис
                 msg "Отключение и удаление старого сервиса '$old_service'..."
                 sudo systemctl disable "$old_service" 2>/dev/null
                 if [ -f "$old_service_file" ]; then sudo rm -f "$old_service_file"; else warning "Старый файл сервиса '$old_service_file' не найден."; fi
                 sudo systemctl daemon-reload # Перезагружаем конфиг после удаления

                 # 6. Создать новый сервис (используя ИСПРАВЛЕННУЮ функцию)
                 # create_systemd_service уже содержит нужные проверки и вызовы
                 if ! create_systemd_service "$new_dir" "$new_service"; then
                      error "Не удалось создать новый сервис '$new_service' для мигрированного сервера."
                      # Что делать дальше? Сервер перемещен, но сервис не создан.
                      # Возможно, стоит предложить пользователю исправить вручную.
                      return 1 # Прерываем инициализацию
                 fi

                 # 7. Добавить запись в конфиг
                 msg "Добавление записи в '$SERVERS_CONFIG_FILE'..."
                 if ! echo "${server_id}:${server_name}:${new_port}:${new_dir}:${new_service}" | sudo tee -a "$SERVERS_CONFIG_FILE" > /dev/null; then
                      error "Не удалось добавить запись в '$SERVERS_CONFIG_FILE'. Добавьте вручную!"
                      # Не прерываем, т.к. сервер почти готов
                 fi

                 # 8. Обновить глобальные переменные и сделать активным
                 MULTISERVER_ENABLED=true # Устанавливаем флаг
                 if ! load_server_config "$server_id"; then error "Не удалось загрузить конфиг мигрированного сервера $server_id"; return 1; fi

                 msg "Миграция сервера '$server_name' завершена!"
                 msg "Сервер теперь активен. Вы можете запустить его через меню управления."
                 read -p "Нажмите Enter для продолжения..." DUMMY_VAR
                 # Миграция завершена, функция init_multiserver выполнила свою работу
                 return 0
             else
                 msg "Миграция отменена. Старый сервер в '$old_default_dir' остался нетронутым."
                 msg "Создайте новый сервер через опцию 1 или добавьте старый вручную в '$SERVERS_CONFIG_FILE'."
             fi
        fi
        # Если старого сервера не было или миграция отменена, конфиг остается пустым (только с комментариями)
    # else
        # msg "Найден конфигурационный файл: $SERVERS_CONFIG_FILE" # Это сообщение не нужно при каждом запуске
    fi

    # Если активный сервер еще не выбран (например, после создания пустого конфига или при обычном запуске без миграции)
    if [ -z "$ACTIVE_SERVER_ID" ]; then
        # Пытаемся загрузить первый сервер из конфига (игнорируя ошибки и комментарии)
        local first_id=$(grep -vE '^#|^$' "$SERVERS_CONFIG_FILE" | head -n 1 | cut -d':' -f1)
        if [ -n "$first_id" ]; then
            # Загружаем тихо, без сообщения об ошибке, если не получится
            # load_server_config вернет 1 при ошибке, но мы это не проверяем здесь,
            # т.к. главное меню покажет "активный не выбран" если что-то пошло не так.
            load_server_config "$first_id" > /dev/null 2>&1
        fi
        # Если first_id пуст (файл пустой или только комменты), ACTIVE_SERVER_ID тоже останется пустым
    fi

    # Устанавливаем флаг в любом случае, т.к. работаем только в этом режиме
    MULTISERVER_ENABLED=true
    # msg "Мультисерверный режим активен." # Это сообщение не нужно при каждом запуске
    return 0
}

# --- Функции управления АКТИВНЫМ сервером ---

# Запуск активного сервера Minecraft
start_server() {
    msg "--- Запуск сервера (ID: $ACTIVE_SERVER_ID, Сервис: $SERVICE_NAME) ---"
    if ! is_server_installed; then
        error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен в '$DEFAULT_INSTALL_DIR'."
        return 1
    fi

    # Проверяем включен ли сервис
    if ! sudo systemctl is-enabled "$SERVICE_NAME" &>/dev/null ; then
        warning "Сервис '$SERVICE_NAME' не включен для автозапуска. Включаю..."
        if ! sudo systemctl enable "$SERVICE_NAME"; then
            warning "Не удалось включить автозапуск сервиса $SERVICE_NAME."
            # Не прерываем, пробуем запустить
        fi
    fi

    # Проверяем, не запущен ли уже
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        msg "Сервис '$SERVICE_NAME' уже запущен."
        return 0
    fi

    # --- FIX: Проверка занятости порта и очистка зависших процессов ---
    if [ -z "$SERVER_PORT" ]; then
         SERVER_PORT=$(get_property "server-port" "$DEFAULT_INSTALL_DIR/server.properties" "19132")
    fi
    
    msg "Проверка доступности порта $SERVER_PORT..."
    
    # Функция для получения PID процесса на порту
    get_port_pid() {
        local port=$1
        if command -v ss &>/dev/null; then
            sudo ss -ulnp | grep ":$port " | grep -o 'pid=[0-9]*' | cut -d'=' -f2 | head -n 1
        elif command -v netstat &>/dev/null; then
            sudo netstat -ulnp | grep ":$port " | awk '{print $7}' | cut -d'/' -f1 | head -n 1
        elif command -v lsof &>/dev/null; then
            sudo lsof -i UDP:$port -t | head -n 1
        else
            echo ""
        fi
    }

    local busy_pid=$(get_port_pid "$SERVER_PORT")

    if [ -n "$busy_pid" ]; then
        warning "Порт $SERVER_PORT занят процессом с PID $busy_pid."
        # Получаем имя процесса
        local proc_name=$(ps -p "$busy_pid" -o comm=)
        msg "Имя процесса: $proc_name"

        if [[ "$proc_name" == "bedrock_server" ]] || [[ "$proc_name" == "screen" ]]; then
             warning "Обнаружен зависший процесс сервера или screen (PID: $busy_pid). Принудительное завершение..."
             if sudo kill -9 "$busy_pid"; then
                 msg "Процесс $busy_pid успешно завершен."
                 sleep 2
             else
                 error "Не удалось завершить процесс $busy_pid. Запуск прерван."
                 return 1
             fi
        else
             error "Порт $SERVER_PORT занят сторонним процессом ($proc_name). Запуск невозможен."
             return 1
        fi
    else
        msg "Порт $SERVER_PORT свободен."
    fi
    # --- END FIX ---

    # Запускаем
    msg "Запуск сервиса '$SERVICE_NAME'..."
    if ! sudo systemctl start "$SERVICE_NAME"; then
        error "Не удалось запустить сервис '$SERVICE_NAME'. Проверьте статус или логи (sudo journalctl -u $SERVICE_NAME)."
        return 1
    fi

    msg "Команда запуска отправлена. Проверяем статус через 5 секунд..."
    sleep 5
    check_status # Вызываем проверку статуса после запуска
    return $? # Возвращаем статус проверки
}

# Остановка активного сервера
stop_server() {
    msg "--- Остановка сервера (ID: $ACTIVE_SERVER_ID, Сервис: $SERVICE_NAME) ---"
    if ! is_server_installed; then
        # Если директории нет, то и останавливать нечего
        msg "Сервер (ID: $ACTIVE_SERVER_ID) не найден в '$DEFAULT_INSTALL_DIR'."
        return 1
    fi

    # Проверяем, активен ли сервис
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME" ; then
        msg "Сервис '$SERVICE_NAME' уже остановлен."
        return 0
    fi

    # Останавливаем
    msg "Остановка сервиса '$SERVICE_NAME' (может занять до 70 секунд)..."
    if ! sudo systemctl stop "$SERVICE_NAME"; then
        warning "Не удалось корректно остановить сервис '$SERVICE_NAME'. Возможно, потребуется ручное вмешательство."
        return 1 # Считаем ошибкой, если не остановился штатно
    fi

    msg "Сервис '$SERVICE_NAME' остановлен."
    return 0
}

# Перезапуск активного сервера
restart_server() {
    msg "--- Перезапуск сервера (ID: $ACTIVE_SERVER_ID, Сервис: $SERVICE_NAME) ---"
    
    # Используем последовательную остановку и запуск для гарантии очистки порта
    # stop_server корректно остановит сервис
    stop_server
    
    # Даем системе немного времени
    sleep 2
    
    # start_server теперь содержит проверку занятости порта и очистку зависших процессов
    start_server
    return $?
}

# Проверка статуса активного сервера
check_status() {
    msg "--- Статус сервера Minecraft Bedrock (ID: $ACTIVE_SERVER_ID) ---"
    # Проверяем, выбран ли активный сервер
    if [ -z "$ACTIVE_SERVER_ID" ]; then
        warning "Активный сервер не выбран."
        return 1
    fi

    if ! is_server_installed; then
        msg "Сервер (ID: $ACTIVE_SERVER_ID) не установлен в '$DEFAULT_INSTALL_DIR'."
        # Проверяем, существует ли файл сервиса, даже если сервер не установлен
        if sudo systemctl cat "$SERVICE_NAME" &>/dev/null ; then
            warning "Найден файл сервиса '$SERVICE_NAME', но файлы сервера отсутствуют!"
            sudo systemctl status "$SERVICE_NAME" --no-pager
        fi
        return 1
    fi

    msg "Директория сервера: $DEFAULT_INSTALL_DIR"
    msg "Имя сервиса: $SERVICE_NAME"
    msg "Проверка статуса сервиса '$SERVICE_NAME'..."
    # Выводим статус, не прерывая скрипт при ошибке
    sudo systemctl status "$SERVICE_NAME" --no-pager
    echo
    msg "Для подробного лога используйте: sudo journalctl -u $SERVICE_NAME -f"
    # Используем имя сервиса без .service для имени screen
    local screen_name=${SERVICE_NAME%.service}
    msg "Для входа в консоль сервера (если запущен): sudo -u $SERVER_USER screen -r $screen_name (Выход: Ctrl+A, затем D)"

    # Возвращаем 0, если сервис активен, иначе другой код
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        return 0
    else
        return 1 # Или другой код, возвращаемый systemctl status
    fi
}

# --- Функции резервного копирования и восстановления (для активного сервера) ---

# Создание резервной копии активного сервера
create_backup() {
    # ID активного сервера берется из глобальной переменной ACTIVE_SERVER_ID
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран для создания бэкапа."; return 1; fi

    local backup_name="backup_${ACTIVE_SERVER_ID}_$(date +%Y-%m-%d_%H-%M-%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    local source_path="$DEFAULT_INSTALL_DIR"
    local worlds_path="$DEFAULT_INSTALL_DIR/worlds"
    local COMPRESS_TYPE="zip" # или tar.gz

    msg "--- Создание резервной копии сервера (ID: $ACTIVE_SERVER_ID) ---"
    if ! is_server_installed; then error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен."; return 1; fi

    # Создаем директорию бэкапов, если ее нет
    if [ ! -d "$BACKUP_DIR" ]; then
        msg "Создание директории для резервных копий: $BACKUP_DIR"
        if ! sudo mkdir -p "$BACKUP_DIR"; then error "Не удалось создать директорию $BACKUP_DIR."; return 1; fi
        if ! sudo chown "$SERVER_USER":"$SERVER_USER" "$BACKUP_DIR"; then warning "Не удалось изменить владельца $BACKUP_DIR"; fi
    fi

    # Проверка места на диске
    local free_space=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}') # В килобайтах
    local required_space_kb=512000 # 500MB в KB
    if [ "$free_space" -lt "$required_space_kb" ]; then
        local free_space_mb=$((free_space / 1024))
        warning "Мало свободного места: ${free_space_mb}МБ. Рекомендуется >500МБ."
        read -p "Продолжить? (yes/no): " SPACE_CONFIRM
        if [[ "$SPACE_CONFIRM" != "yes" ]]; then msg "Создание копии отменено."; return 1; fi
    fi

    # Создаем временную папку для копии
    msg "Создание временной директории для копии: $backup_path"
    if ! mkdir -p "$backup_path"; then error "Не удалось создать $backup_path."; return 1; fi

    # Остановка сервера (опционально)
    local server_was_running=false
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        server_was_running=true
        warning "Сервер '$SERVICE_NAME' запущен. Рекомендуется остановить для точной копии."
        read -p "Остановить сервер? (yes/no): " STOP_CONFIRM
        if [[ "$STOP_CONFIRM" == "yes" ]]; then
            msg "Остановка сервера '$SERVICE_NAME'..."
            if ! stop_server; then # stop_server вернет 0 при успехе
                 # Если не удалось остановить, не продолжаем, т.к. пользователь хотел остановить
                 rm -rf "$backup_path" # Чистим временную папку
                 error "Не удалось остановить сервер. Создание копии прервано."
                 return 1
            fi
            sleep 3 # Даем время
        else
            warning "Копия будет создана без остановки. Возможны несогласованности данных."
        fi
    fi

    # Копирование файлов
    msg "Копирование файлов..."
    local source_to_copy="$source_path"
    if [[ "$BACKUP_WORLDS_ONLY" == "true" ]]; then
        msg "Режим: бэкап только миров ('$worlds_path')"
        source_to_copy="$worlds_path"
        if [ ! -d "$source_to_copy" ]; then error "Директория миров '$source_to_copy' не найдена."; rm -rf "$backup_path"; if $server_was_running && [[ "$STOP_CONFIRM" == "yes" ]]; then start_server; fi; return 1; fi
    else
        msg "Режим: полный бэкап сервера ('$source_path')"
    fi

    # Используем rsync для копирования
    if ! sudo rsync -a --delete "$source_to_copy/" "$backup_path/"; then
        warning "Произошла ошибка при копировании rsync. Результат может быть неполным."
        # Не прерываем, но предупреждаем
    fi

    # Создание информационного файла внутри бэкапа
    local current_version="Unknown"
    if [ -f "$DEFAULT_INSTALL_DIR/version" ]; then current_version=$(cat "$DEFAULT_INSTALL_DIR/version"); cp "$DEFAULT_INSTALL_DIR/version" "$backup_path/version_info"; fi
    echo "Backup created: $(date)" > "$backup_path/backup_info.txt"
    echo "Server ID: $ACTIVE_SERVER_ID" >> "$backup_path/backup_info.txt"
    echo "Server Version: $current_version" >> "$backup_path/backup_info.txt"
    echo "Worlds only: $BACKUP_WORLDS_ONLY" >> "$backup_path/backup_info.txt"
    echo "Original Path: $DEFAULT_INSTALL_DIR" >> "$backup_path/backup_info.txt"

    # Архивирование
    msg "Архивирование резервной копии..."
    local archive_path="$BACKUP_DIR/${backup_name}.${COMPRESS_TYPE}"
    cd "$BACKUP_DIR" # Переходим в директорию бэкапов для корректных путей в архиве
    if [[ "$COMPRESS_TYPE" == "zip" ]]; then
        # Архивируем содержимое папки backup_name в архив с таким же именем + .zip
        if ! sudo zip -r "$archive_path" "$backup_name" > /dev/null; then warning "Ошибка при создании zip-архива."; fi
    else # tar.gz
        if ! sudo tar -czf "$archive_path" "$backup_name" > /dev/null; then warning "Ошибка при создании tar.gz-архива."; fi
    fi
    cd - > /dev/null # Возвращаемся обратно

    # Удаляем временную папку
    sudo rm -rf "$backup_path"

    # Проверка результата и установка прав
    if [ -f "$archive_path" ]; then
        if ! sudo chown "$SERVER_USER":"$SERVER_USER" "$archive_path"; then warning "Не удалось изменить владельца архива $archive_path"; fi
        local archive_size=$(du -h "$archive_path" | cut -f1)
        msg "✅ Резервная копия успешно создана: $archive_path ($archive_size)"
    else
        error "Не удалось создать архив резервной копии."
        # Пытаемся запустить сервер обратно, если останавливали
        if $server_was_running && [[ "$STOP_CONFIRM" == "yes" ]]; then msg "Запуск сервера..."; start_server; fi
        return 1
    fi

    # Запускаем сервер обратно, если останавливали
    if $server_was_running && [[ "$STOP_CONFIRM" == "yes" ]]; then
        msg "Перезапуск сервера '$SERVICE_NAME'..."
        if ! start_server; then warning "Не удалось перезапустить сервер после бэкапа."; fi
    fi

    # Ротация бэкапов
    rotate_backups

    msg "Создание резервной копии завершено."
    return 0
}

# Восстановление активного сервера из резервной копии
restore_backup() {
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран для восстановления."; return 1; fi
    msg "--- Восстановление сервера (ID: $ACTIVE_SERVER_ID) из резервной копии ---"
    if ! is_server_installed; then error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен."; return 1; fi

    # Список бэкапов (почти как в list_backups)
    local backups=()
    local i=1
    msg "Поиск доступных резервных копий в $BACKUP_DIR..."
    if [ ! -d "$BACKUP_DIR" ]; then error "Директория бэкапов $BACKUP_DIR не найдена."; fi

    # Используем find и sort для надежного списка
    mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.zip" -o -name "*.tar.gz" \) -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)

    if [ ${#backups[@]} -eq 0 ]; then error "Резервные копии не найдены."; fi

    echo "Доступные резервные копии:"
    for i in "${!backups[@]}"; do
        local backup_file="${backups[$i]}"
        local backup_basename=$(basename "$backup_file")
        # Попытка извлечь ID сервера из имени файла
        local backup_server_id_info="?"
        if [[ "$backup_basename" =~ backup_([^_]+)_ ]]; then backup_server_id_info="${BASH_REMATCH[1]}"; fi
        printf " %3d. %s (ID: %s, Дата: %s)\n" $((i+1)) "$backup_basename" "$backup_server_id_info" "$(date -r "$backup_file" "+%Y-%m-%d %H:%M")"
    done

    local choice
    read -p "Выберите номер копии для восстановления (1-${#backups[@]}): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then error "Некорректный выбор."; fi

    local selected_backup="${backups[$choice-1]}"
    local backup_name=$(basename "$selected_backup")

    warning "ВНИМАНИЕ! Перезапишет ТЕКУЩИЕ файлы '$DEFAULT_INSTALL_DIR' сервера '$ACTIVE_SERVER_ID'!"
    read -p "Восстановить из '$backup_name'? (yes/no): " RESTORE_CONFIRM
    if [[ "$RESTORE_CONFIRM" != "yes" ]]; then msg "Восстановление отменено."; return 1; fi

    msg "Остановка сервера '$SERVICE_NAME'..."
    if ! stop_server; then error "Не удалось остановить сервер. Восстановление прервано."; return 1; fi
    sleep 2

    # Временная директория для распаковки
    local temp_dir="/tmp/minecraft_restore_$(date +%s)_${ACTIVE_SERVER_ID}"
    msg "Создание временной директории: $temp_dir"
    # Чистим старую, если вдруг осталась
    sudo rm -rf "$temp_dir"
    if ! mkdir -p "$temp_dir"; then error "Не удалось создать $temp_dir."; return 1; fi

    # Распаковка
    msg "Распаковка архива '$backup_name'..."
    local extracted_subdir_name=""
    local archive_cmd_success=false
    if [[ "$backup_name" == *.zip ]]; then
        if sudo unzip -q "$selected_backup" -d "$temp_dir"; then archive_cmd_success=true; fi
        # Пытаемся определить имя папки внутри zip
        extracted_subdir_name=$(unzip -l "$selected_backup" | grep -oE '^ *[0-9]+ +[0-9:]{5} +[^/]+/$' | head -n 1 | awk '{print $NF}' | sed 's|/$||')
    elif [[ "$backup_name" == *.tar.gz ]]; then
        if sudo tar -xzf "$selected_backup" -C "$temp_dir"; then archive_cmd_success=true; fi
        # Пытаемся определить имя папки внутри tar.gz
        extracted_subdir_name=$(tar -tzf "$selected_backup" | grep '/$' | head -n 1 | sed 's|/$||')
    else
        error "Неизвестный формат архива: $backup_name"; sudo rm -rf "$temp_dir"; return 1;
    fi

    if ! $archive_cmd_success; then error "Ошибка при распаковке архива."; sudo rm -rf "$temp_dir"; return 1; fi

    # Определяем источник восстановления
    local restore_source="$temp_dir"
    if [ -n "$extracted_subdir_name" ] && [ -d "$temp_dir/$extracted_subdir_name" ]; then
       restore_source="$temp_dir/$extracted_subdir_name"
       msg "Обнаружена вложенная папка в архиве: '$extracted_subdir_name'"
    fi

    # Определяем тип бэкапа и целевую директорию
    local restore_target_dir="$DEFAULT_INSTALL_DIR"
    local backup_is_worlds_only=false
    if [ -f "$restore_source/backup_info.txt" ]; then
        if grep -q "Worlds only: true" "$restore_source/backup_info.txt"; then
            backup_is_worlds_only=true
            msg "Это резервная копия только миров."
            restore_target_dir="$DEFAULT_INSTALL_DIR/worlds"
            # Источник - сама папка, если нет вложенной 'worlds', иначе вложенная
            if [ -d "$restore_source/worlds" ]; then restore_source="$restore_source/worlds"; fi
            # Создаем папку worlds, если её нет
            sudo mkdir -p "$restore_target_dir"
            sudo chown "$SERVER_USER":"$SERVER_USER" "$restore_target_dir" # Права на папку
        else
            msg "Это полная резервная копия сервера."
        fi
    else
         warning "Файл backup_info.txt не найден. Считаем, что это ПОЛНЫЙ бэкап."
         # В этом случае restore_target_dir остается $DEFAULT_INSTALL_DIR
    fi

    # Бэкап текущего состояния (на всякий случай) - необязательно, но безопасно
    msg "Создание временной копии текущего состояния '$restore_target_dir'..."
    local current_backup_dir="/tmp/pre_restore_state_${ACTIVE_SERVER_ID}_$(date +%s)"
    if sudo rsync -a "$restore_target_dir/" "$current_backup_dir/" > /dev/null 2>&1; then
        msg "Текущее состояние сохранено в $current_backup_dir"
    else
        warning "Не удалось создать копию текущего состояния."
    fi

    # Очистка целевой директории
    msg "Очистка целевой директории: $restore_target_dir"
    # Используем find для большей безопасности, чем rm -rf *
    if [ -d "$restore_target_dir" ]; then
        sudo find "$restore_target_dir" -mindepth 1 -delete || warning "Не удалось полностью очистить $restore_target_dir"
    fi

    # Восстановление файлов
    msg "Восстановление файлов из '$restore_source' в '$restore_target_dir'..."
    if ! sudo rsync -a "$restore_source/" "$restore_target_dir/"; then
        warning "Ошибка при восстановлении файлов! Попытка вернуть предыдущее состояние..."
        sudo find "$restore_target_dir" -mindepth 1 -delete # Очищаем снова
        if [ -d "$current_backup_dir" ]; then
            sudo rsync -a "$current_backup_dir/" "$restore_target_dir/"
            sudo rm -rf "$current_backup_dir"
        fi
        sudo rm -rf "$temp_dir"
        error "Ошибка при восстановлении файлов. Предыдущее состояние (если возможно) возвращено."
        # Пытаемся запустить сервер, чтобы не оставить его выключенным
        start_server
        return 1
    fi

    # Установка прав
    msg "Обновление прав на восстановленные файлы в '$restore_target_dir'..."
    if ! sudo chown -R "$SERVER_USER":"$SERVER_USER" "$restore_target_dir"; then
        warning "Не удалось изменить владельца восстановленных файлов."
    fi
    # Права на исполнение (только если полный бэкап)
    if ! $backup_is_worlds_only && [ -f "$restore_target_dir/bedrock_server" ]; then
        if ! sudo chmod +x "$restore_target_dir/bedrock_server"; then
            warning "Не удалось установить права на исполнение для bedrock_server."
        fi
    fi

    # Очистка временных файлов
    msg "Удаление временных файлов..."
    sudo rm -rf "$temp_dir"
    if [ -d "$current_backup_dir" ]; then sudo rm -rf "$current_backup_dir"; fi

    # Запуск сервера
    msg "Запуск сервера '$SERVICE_NAME' после восстановления..."
    if ! start_server; then
         error "Не удалось запустить сервер после восстановления. Проверьте логи."
         return 1
    fi

    msg "✅ Восстановление из резервной копии завершено успешно."
    return 0
}

# Ротация резервных копий (удаление старых)
rotate_backups() {
    msg "Проверка ротации резервных копий (Макс: $MAX_BACKUPS)..."
    if [ ! -d "$BACKUP_DIR" ]; then return 0; fi

    # Получаем список бэкапов, отсортированный по времени (старые в конце), пропускаем первые MAX_BACKUPS
    # ls -t: сортировка по времени (новые сверху)
    # tail -n +$((MAX_BACKUPS + 1)): берем все, начиная с (MAX+1)-го
    local backups_to_delete=$(ls -t "$BACKUP_DIR"/*.zip "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))

    if [ -n "$backups_to_delete" ]; then
        msg "Удаление старых резервных копий..."
        # Устанавливаем IFS на перевод строки, чтобы корректно обрабатывать имена файлов с пробелами
        local OLD_IFS=$IFS
        IFS=$'\n'
        for backup in $backups_to_delete; do
            if [ -f "$backup" ]; then
                sudo rm "$backup"
                msg "Удален старый бэкап: $(basename "$backup")"
            fi
        done
        IFS=$OLD_IFS
    else
        msg "Ротация не требуется."
    fi
}

# Список резервных копий
list_backups() {
    msg "--- Список резервных копий ---"
    if [ ! -d "$BACKUP_DIR" ]; then warning "Директория бэкапов не найдена."; return 0; fi

    local backups=$(ls "$BACKUP_DIR"/*.zip "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [ -z "$backups" ]; then
        msg "Резервных копий нет."
        return 0
    fi

    echo "Найдено:"
    # Выводим список с размерами и датами
    ls -lh "$BACKUP_DIR" | grep -E "\.zip$|\.tar\.gz$" | awk '{print $9, "(" $5, $6, $7, $8 ")"}'
    echo "Всего места занято: $(du -sh "$BACKUP_DIR" | cut -f1)"
    read -p "Нажмите Enter для продолжения..." DUMMY_VAR
}

# Удаление резервной копии
delete_backup() {
    msg "--- Удаление резервной копии ---"
    if [ ! -d "$BACKUP_DIR" ]; then warning "Директория бэкапов не найдена."; return 0; fi

    # Формируем массив бэкапов
    local backups=()
    mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.zip" -o -name "*.tar.gz" \) -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)

    if [ ${#backups[@]} -eq 0 ]; then msg "Резервных копий нет."; return 0; fi

    echo "Выберите копию для удаления:"
    for i in "${!backups[@]}"; do
        echo "$((i+1)). $(basename "${backups[$i]}")"
    done
    echo "0. Отмена"

    local choice
    read -p "Ваш выбор: " choice

    if [[ "$choice" == "0" ]]; then return 0; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        error "Некорректный выбор."
        return 1
    fi

    local file_to_delete="${backups[$choice-1]}"
    read -p "Удалить '$(basename "$file_to_delete")'? (yes/no): " CONFIRM
    if [[ "$CONFIRM" == "yes" ]]; then
        if sudo rm "$file_to_delete"; then
            msg "Файл удален."
        else
            error "Не удалось удалить файл."
        fi
    else
        msg "Отменено."
    fi
}

# --- Функции Настройки АКТИВНОГО сервера ---

# Получение значения параметра из файла конфигурации
get_property() {
    local key="$1"
    local config_file="$2"
    local default_value="$3"
    local current_value=""

    # Проверяем существование файла перед чтением
    if [ ! -f "$config_file" ]; then
        # Возвращаем значение по умолчанию, если файла нет
        echo "$default_value"
        return
    fi

    # Ищем строку, которая НЕ закомментирована
    # Используем grep -E для расширенных регулярных выражений
    # sed 's/^ *//;s/ *$//' удаляет пробелы в начале и конце значения
    current_value=$(grep -E "^\s*${key}\s*=" "$config_file" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')

    # Если не нашли активную строку
    if [ -z "$current_value" ]; then
        # Ищем первую закомментированную строку с этим ключом
        current_value=$(grep -E "^\s*#\s*${key}\s*=" "$config_file" | head -n 1 | cut -d'=' -f2- | sed 's/^ *//;s/ *$//')

        # Если и закомментированной нет, используем значение по умолчанию
        if [ -z "$current_value" ]; then
            current_value="$default_value"
        fi
    fi

    echo "$current_value"
}

# Установка значения параметра в файл конфигурации
set_property() {
    local key="$1"
    local value="$2"
    local config_file="$3"

    # Проверяем существование файла перед записью
    if [ ! -f "$config_file" ]; then
        error "Файл конфигурации '$config_file' не найден в set_property."
        return 1 # Возвращаем ошибку
    fi

    # Экранируем специальные символы в значении и ключе для sed
    local escaped_value=$(sed 's/[&/\]/\\&/g' <<< "$value")
    local escaped_key=$(sed 's/[&/\]/\\&/g' <<< "$key")

    # Проверяем, существует ли ключ (закомментированный или нет)
    # Используем grep -q для тихой проверки
    if grep -qE "^\s*#?\s*${escaped_key}=" "$config_file"; then
        # Ключ существует, обновляем его значение
        # sed -i редактирует файл на месте
        # Используем | в качестве разделителя в sed на случай, если в пути есть /
        # s|^\s*#*\s*${escaped_key}=.*|${key}=${escaped_value}| заменяет всю строку, начинающуюся с ключа (с любым кол-вом пробелов и #), на новую key=value
        if ! sudo sed -i "s|^\\s*#*\\s*${escaped_key}=.*|${key}=${escaped_value}|" "$config_file"; then
            warning "Команда sed не смогла обновить ключ '$key' в файле '$config_file'."
            return 1
        fi
    else
        # Ключ не существует, добавляем его в конец файла
        if ! echo "${key}=${escaped_value}" | sudo tee -a "$config_file" > /dev/null; then
             warning "Не удалось добавить ключ '$key' в конец файла '$config_file'."
             return 1
        fi
    fi
    return 0
}

# --- Новые функции настройки по разделам, в стиле игры ---

# Подменю настройки сервера (точка входа)
# --- Новые функции настройки по разделам ---

# Хелпер для изменения булевых значений (true/false)
change_prop_bool() {
    local key="$1"; local file="$2"; local desc="$3"
    local current=$(get_property "$key" "$file" "false")
    local new_val="true"
    if [[ "$current" == "true" ]]; then new_val="false"; fi
    
    echo "Текущее значение $desc ($key): $current"
    read -p "Переключить на $new_val? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        set_property "$key" "$new_val" "$file"
        msg "$desc изменено на $new_val"
    fi
}

# Хелпер для выбора из списка
change_prop_select() {
    local key="$1"; local file="$2"; local desc="$3"; shift 3; local options=("$@")
    local current=$(get_property "$key" "$file" "${options[0]}")
    
    echo "--- $desc ($key) ---"
    echo "Текущее: $current"
    local i=1
    for opt in "${options[@]}"; do
        echo "$i. $opt"
        ((i++))
    done
    read -p "Выберите вариант (1-${#options[@]}) или Enter для отмены: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
        set_property "$key" "${options[$choice-1]}" "$file"
        msg "$desc изменено на ${options[$choice-1]}"
    fi
}

# Хелпер для ввода текста/числа
change_prop_text() {
    local key="$1"; local file="$2"; local desc="$3"
    local current=$(get_property "$key" "$file" "")
    
    echo "--- $desc ($key) ---"
    read -p "Введите новое значение [$current]: " new_val
    if [ -n "$new_val" ]; then
        set_property "$key" "$new_val" "$file"
        msg "$desc изменено на $new_val"
    fi
}

# Хелпер для Gamerule (требует активного сервера)
change_gamerule_bool() {
    local rule="$1"; local desc="$2"
    local screen_name=${SERVICE_NAME%.service}
    
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        warning "Сервер не запущен. Нельзя изменить правило '$rule'."
        return
    fi
    
    echo "--- Правило: $desc ($rule) ---"
    echo "1. Включить (true)"
    echo "2. Выключить (false)"
    read -p "Выберите (1/2): " choice
    local val=""
    case $choice in 1) val="true";; 2) val="false";; esac
    
    if [ -n "$val" ]; then
        sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "gamerule $rule $val^M"
        msg "Команда отправлена: gamerule $rule $val"
        sleep 1
    fi
}

# Хелпер для Gamerule (текст/число)
change_gamerule_text() {
    local rule="$1"; local desc="$2"
    local screen_name=${SERVICE_NAME%.service}
    
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        warning "Сервер не запущен. Нельзя изменить правило '$rule'."
        return
    fi
    
    echo "--- Правило: $desc ($rule) ---"
    read -p "Введите новое значение: " val
    
    if [ -n "$val" ]; then
        sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "gamerule $rule $val^M"
        msg "Команда отправлена: gamerule $rule $val"
        sleep 1
    fi
}

# Главное меню настроек
configure_menu() {
    ensure_whiptail
    if ! is_server_installed; then 
        whiptail --msgbox "❌ Сервер не установлен.\n\nСначала установите сервер через опцию 1 в главном меню." 10 60
        return 1
    fi
    local CONFIG_FILE="$DEFAULT_INSTALL_DIR/server.properties"
    
    # Получаем имя сервера для отображения
    local server_name=$(get_property "server-name" "$CONFIG_FILE" "$ACTIVE_SERVER_ID")

    while true; do
        local choice=$(whiptail --title "⚙️ Настройки Сервера" --menu "Сервер: $server_name (ID: $ACTIVE_SERVER_ID)\n\nВыберите раздел настроек:" 20 78 10 \
            "1" "⚙️  Общие (Имя, Режим, Сложность)" \
            "2" "📜 Дополнительно (Мир, Правила, Права)" \
            "3" "🌐 Сеть (Игроки, Whitelist, PvP)" \
            "4" "🛠️  Читы (Команды, Gamerules)" \
            "5" "🔍 Другие настройки" \
            "0" " ← Назад в главное меню" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then return 0; fi

        case $choice in
            1) configure_general_settings ;;
            2) configure_advanced_settings ;;
            3) configure_network_settings ;;
            4) configure_cheats_settings ;;
            5) configure_other_settings ;;
            0) return 0 ;;
        esac
    done
}

configure_general_settings() {
    local f="$DEFAULT_INSTALL_DIR/server.properties"
    while true; do
        local server_name=$(fmt_value "$(get_property "server-name" "$f" "не задано")" 25)
        local gamemode_raw=$(get_property "gamemode" "$f" "survival")
        local difficulty_raw=$(get_property "difficulty" "$f" "easy")
        local gamemode=$(display_ru "gamemode" "$gamemode_raw")
        local difficulty=$(display_ru "difficulty" "$difficulty_raw")
        local hardcore=$(fmt_bool "$(get_property "hardcore" "$f" "false")")
        
        local choice=$(whiptail --title "⚙️ Общие Настройки" --menu "Выберите параметр для изменения:" 18 78 8 \
            "server-name" "Имя сервера: $server_name" \
            "gamemode" "Режим игры: $gamemode" \
            "difficulty" "Сложность: $difficulty" \
            "hardcore" "Хардкор: $hardcore" \
            "0" "← Назад" 3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then return; fi

        case $choice in
            server-name) input_prop "server-name" "$f" "Имя сервера" ;;
            gamemode) select_prop "gamemode" "$f" "Режим игры" "survival" "creative" "adventure" ;;
            difficulty) select_prop "difficulty" "$f" "Сложность" "peaceful" "easy" "normal" "hard" ;;
            hardcore) 
                local desc=$(get_setting_description "hardcore")
                local current=$(get_property "hardcore" "$f" "false")
                
                # Определяем текущее состояние для radiolist
                local true_status="OFF"
                local false_status="OFF"
                if [[ "${current,,}" == "true" ]]; then
                    true_status="ON"
                else
                    false_status="ON"
                fi
                
                local choice_hc=$(whiptail --title "Хардкор" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$true_status" \
                    "false" "Выключить" "$false_status" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_hc" ]; then
                    if ! set_property "hardcore" "$choice_hc" "$f"; then
                        whiptail --msgbox "❌ Ошибка при изменении настройки!" 8 50
                    fi
                fi
                ;;
            0) return ;;
        esac
    done
}

configure_advanced_settings() {
    local f="$DEFAULT_INSTALL_DIR/server.properties"
    while true; do
        local level_type_raw=$(get_property "level-type" "$f" "DEFAULT")
        local is_flat="false"
        if [[ "$level_type_raw" == "FLAT" ]]; then is_flat="true"; fi
        local level_type_disp=$(fmt_bool "$is_flat")

        local start_with_map=$(fmt_bool "$(get_property "start-with-map" "$f" "false")")
        local bonus_chest=$(fmt_bool "$(get_property "bonus-chest" "$f" "false")")
        local show_coords=$(fmt_bool "$(get_property "showcoordinates" "$f" "false")")
        local show_days=$(fmt_bool "$(get_property "showdayspassed" "$f" "false")")
        local recipes_unlock=$(fmt_bool "$(get_property "recipesunlock" "$f" "true")")
        local fire_tick=$(fmt_bool "$(get_property "dofiretick" "$f" "true")")
        local tnt_explodes=$(fmt_bool "$(get_property "tntexplodes" "$f" "true")")
        local mob_loot=$(fmt_bool "$(get_property "doentitydrops" "$f" "true")")
        local natural_regen=$(fmt_bool "$(get_property "naturalregeneration" "$f" "true")")
        local tile_drops=$(fmt_bool "$(get_property "dotiledrops" "$f" "true")")
        local instant_respawn=$(fmt_bool "$(get_property "doimmediaterespawn" "$f" "false")")
        local respawn_explode=$(fmt_bool "$(get_property "respawnblocksexplode" "$f" "false")")
        local sleep_pct=$(get_property "playerssleepingpercentage" "$f" "100")
        local sim_dist=$(get_property "simulation-distance" "$f" "8")
        local spawn_rad=$(get_property "spawn-radius" "$f" "10")
        local perms_raw=$(get_property "default-player-permission-level" "$f" "member")
        local perms_disp=$(display_ru "default-player-permission-level" "$perms_raw")
        
        local choice=$(whiptail --title "📜 Дополнительные Настройки" --menu "Выберите параметр:" 22 80 12 \
            "level-type" "Плоский мир: $level_type_disp" \
            "start-with-map" "Начальная карта: $start_with_map" \
            "bonus-chest" "Бонусный сундук: $bonus_chest" \
            "showcoordinates" "Показать координаты: $show_coords" \
            "showdayspassed" "Показать количество прошедших дней: $show_days" \
            "recipesunlock" "Разблокировка рецептов: $recipes_unlock" \
            "dofiretick" "Распространение огня: $fire_tick" \
            "tntexplodes" "Детонация динамита: $tnt_explodes" \
            "doentitydrops" "Добыча из мобов: $mob_loot" \
            "naturalregeneration" "Естественная регенерация: $natural_regen" \
            "dotiledrops" "Выпадение предметов из блоков: $tile_drops" \
            "playerssleepingpercentage" "Необходимы спящие игроки: $sleep_pct%" \
            "doimmediaterespawn" "Мгновенное возрождение: $instant_respawn" \
            "respawnblocksexplode" "Возрождающиеся блоки взрываются: $respawn_explode" \
            "simulation-distance" "Дистанция моделирования: $sim_dist" \
            "spawn-radius" "Радиус возрождения: $spawn_rad" \
            "default-player-permission-level" "Разрешения игрока по умолчанию: $perms_disp" \
            "0" "← Назад" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return; fi

        case $choice in
            level-type)
                local desc=$(get_setting_description "level-type")
                local state_flat="OFF"; local state_default="OFF"
                if [[ "$is_flat" == "true" ]]; then state_flat="ON"; else state_default="ON"; fi
                local choice_lt=$(whiptail --title "Плоский мир" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "FLAT" "Включить" "$state_flat" \
                    "DEFAULT" "Выключить" "$state_default" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_lt" ]; then
                    set_property "level-type" "$choice_lt" "$f"
                fi
                ;;
            start-with-map)
                local desc=$(get_setting_description "start-with-map")
                local cur=$(get_property "start-with-map" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_sw=$(whiptail --title "Начальная карта" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_sw" ]; then
                    set_property "start-with-map" "$choice_sw" "$f"
                fi
                ;;
            bonus-chest)
                local desc=$(get_setting_description "bonus-chest")
                local cur=$(get_property "bonus-chest" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_bc=$(whiptail --title "Бонусный сундук" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_bc" ]; then
                    set_property "bonus-chest" "$choice_bc" "$f"
                fi
                ;;
            showcoordinates)
                local desc=$(get_setting_description "showcoordinates")
                local cur=$(get_property "showcoordinates" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_sc=$(whiptail --title "Показать координаты" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_sc" ]; then
                    set_property "showcoordinates" "$choice_sc" "$f"
                fi
                ;;
            showdayspassed)
                local desc=$(get_setting_description "showdayspassed")
                local cur=$(get_property "showdayspassed" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_sdp=$(whiptail --title "Показать прошедшие дни" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_sdp" ]; then
                    set_property "showdayspassed" "$choice_sdp" "$f"
                fi
                ;;
            recipesunlock)
                local desc=$(get_setting_description "recipesunlock")
                local cur=$(get_property "recipesunlock" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_ru=$(whiptail --title "Разблокировка рецептов" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ru" ]; then
                    set_property "recipesunlock" "$choice_ru" "$f"
                fi
                ;;
            dofiretick)
                local desc=$(get_setting_description "dofiretick")
                local cur=$(get_property "dofiretick" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_ft=$(whiptail --title "Распространение огня" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ft" ]; then
                    set_property "dofiretick" "$choice_ft" "$f"
                fi
                ;;
            tntexplodes)
                local desc=$(get_setting_description "tntexplodes")
                local cur=$(get_property "tntexplodes" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_tnt=$(whiptail --title "Детонация динамита" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_tnt" ]; then
                    set_property "tntexplodes" "$choice_tnt" "$f"
                fi
                ;;
            doentitydrops)
                local desc=$(get_setting_description "doentitydrops")
                local cur=$(get_property "doentitydrops" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_ed=$(whiptail --title "Добыча из мобов" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ed" ]; then
                    set_property "doentitydrops" "$choice_ed" "$f"
                fi
                ;;
            naturalregeneration)
                local desc=$(get_setting_description "naturalregeneration")
                local cur=$(get_property "naturalregeneration" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_nr=$(whiptail --title "Естественная регенерация" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_nr" ]; then
                    set_property "naturalregeneration" "$choice_nr" "$f"
                fi
                ;;
            dotiledrops)
                local desc=$(get_setting_description "dotiledrops")
                local cur=$(get_property "dotiledrops" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_td=$(whiptail --title "Выпадение предметов из блоков" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_td" ]; then
                    set_property "dotiledrops" "$choice_td" "$f"
                fi
                ;;
            playerssleepingpercentage)
                local desc=$(get_setting_description "playerssleepingpercentage")
                local current=$(get_property "playerssleepingpercentage" "$f" "100")
                local val=$(whiptail --inputbox "Необходимы спящие игроки (0-100):\n\n$desc\n\nТекущее значение: $current" 14 70 "$current" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$val" ]; then
                    if validate_number "$val" "0" "100"; then
                        set_property "playerssleepingpercentage" "$val" "$f"
                    else
                        whiptail --msgbox "❌ Неверное значение! Должно быть от 0 до 100" 8 50
                    fi
                fi
                ;;
            doimmediaterespawn)
                local desc=$(get_setting_description "doimmediaterespawn")
                local cur=$(get_property "doimmediaterespawn" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_ir=$(whiptail --title "Мгновенное возрождение" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ir" ]; then
                    set_property "doimmediaterespawn" "$choice_ir" "$f"
                fi
                ;;
            respawnblocksexplode)
                local desc=$(get_setting_description "respawnblocksexplode")
                local cur=$(get_property "respawnblocksexplode" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_rb=$(whiptail --title "Возрождающиеся блоки взрываются" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_rb" ]; then
                    set_property "respawnblocksexplode" "$choice_rb" "$f"
                fi
                ;;
            simulation-distance) 
                local desc=$(get_setting_description "simulation-distance")
                local current=$(get_property "simulation-distance" "$f" "8")
                local sim4="OFF"; local sim6="OFF"; local sim8="OFF"
                case "$current" in
                    4) sim4="ON" ;;
                    6) sim6="ON" ;;
                    *) sim8="ON" ;; # по умолчанию 8
                esac
                local choice_sim=$(whiptail --title "Дистанция моделирования" --radiolist "$desc\n\nТекущее значение: $current фрагментов\n\nВыберите значение:" 20 80 3 \
                    "4" "Фрагментов: 4" "$sim4" \
                    "6" "Фрагментов: 6" "$sim6" \
                    "8" "Фрагментов: 8" "$sim8" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_sim" ]; then
                    set_property "simulation-distance" "$choice_sim" "$f"
                fi
                ;;
            spawn-radius)
                local desc=$(get_setting_description "spawn-radius")
                local current=$(get_property "spawn-radius" "$f" "10")
                local sr0="OFF"; local sr64="OFF"; local sr128="OFF"
                case "$current" in
                    0) sr0="ON" ;;
                    64) sr64="ON" ;;
                    128) sr128="ON" ;;
                    *) sr64="ON" ;;
                esac
                local choice_sr=$(whiptail --title "Радиус возрождения" --radiolist "$desc\n\nТекущее значение: $current\n\nВыберите значение:" 20 80 3 \
                    "0" "0" "$sr0" \
                    "64" "64" "$sr64" \
                    "128" "128" "$sr128" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_sr" ]; then
                    set_property "spawn-radius" "$choice_sr" "$f"
                fi
                ;;
            default-player-permission-level) select_prop "default-player-permission-level" "$f" "Разрешения игрока по умолчанию" "visitor" "member" "operator" ;;
            0) return ;;
        esac
    done
}

configure_network_settings() {
    local f="$DEFAULT_INSTALL_DIR/server.properties"
    while true; do
        local multiplayer=$(fmt_bool "$(get_property "multiplayer" "$f" "true")")
        local mp_on=$(get_property "multiplayer" "$f" "true")

        local access_raw="invited"
        local access_disp="недоступно"
        local perms_raw="member"
        local perms_disp="недоступно"
        if [[ "${mp_on,,}" == "true" ]]; then
            access_raw=$(get_property "player-access" "$f" "invited")
            access_disp=$(display_ru "player-access" "$access_raw")
            perms_raw=$(get_property "default-player-permission-level" "$f" "member")
            perms_disp=$(display_ru "default-player-permission-level" "$perms_raw")
        fi

        local visible_lan=$(fmt_bool "$(get_property "visible-lan" "$f" "true")")
        local pvp=$(fmt_bool "$(get_property "pvp" "$f" "true")")
        local locator=$(fmt_bool "$(get_property "locator-panel" "$f" "true")")

        # Динамически собираем меню, чтобы скрывать пункты при выключенном мультиплеере
        local menu_items=(
            "multiplayer" "Многопользовательская игра: $multiplayer"
        )
        if [[ "${mp_on,,}" == "true" ]]; then
            menu_items+=(
                "player-access" "Доступ игрока: $access_disp"
                "default-player-permission-level" "Разрешения по умолчанию: $perms_disp"
            )
        fi
        menu_items+=(
            "visible-lan" "Видят игроки в локальной сети: $visible_lan"
            "pvp" "Огонь по своим: $pvp"
            "locator-panel" "Панель локатора: $locator"
            "0" "← Назад"
        )

        local choice=$(whiptail --title "🌐 Игра по сети" --menu "Выберите параметр:" 22 80 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return; fi

        case $choice in
            multiplayer)
                local desc=$(get_setting_description "multiplayer")
                local cur=$(get_property "multiplayer" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_mp=$(whiptail --title "Многопользовательская игра" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_mp" ]; then
                    set_property "multiplayer" "$choice_mp" "$f"
                fi
                ;;
            player-access)
                local mp_cur=$(get_property "multiplayer" "$f" "true")
                if [[ "${mp_cur,,}" != "true" ]]; then
                    whiptail --msgbox "Включите «Многопользовательская игра», чтобы настроить доступ." 10 60
                    continue
                fi
                local desc=$(get_setting_description "player-access")
                local acc_inv="OFF"; local acc_fr="OFF"; local acc_fof="OFF"
                case "$access_raw" in
                    friends) acc_fr="ON" ;;
                    friends-of-friends) acc_fof="ON" ;;
                    *) acc_inv="ON" ;;
                esac
                local choice_pa=$(whiptail --title "Доступ игрока" --radiolist "$desc\n\nТекущее: $access_disp\n\nВыберите вариант:" 20 80 3 \
                    "invited" "Приглашенные" "$acc_inv" \
                    "friends" "Друзья" "$acc_fr" \
                    "friends-of-friends" "Друзья друзей" "$acc_fof" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_pa" ]; then
                    set_property "player-access" "$choice_pa" "$f"
                fi
                ;;
            default-player-permission-level)
                local mp_cur=$(get_property "multiplayer" "$f" "true")
                if [[ "${mp_cur,,}" != "true" ]]; then
                    whiptail --msgbox "Включите «Многопользовательская игра», чтобы настроить разрешения." 10 60
                    continue
                fi
                select_prop "default-player-permission-level" "$f" "Разрешения игрока по умолчанию" "visitor" "member" "operator"
                ;;
            visible-lan)
                local desc=$(get_setting_description "visible-lan")
                local cur=$(get_property "visible-lan" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_lan=$(whiptail --title "Видят игроки в локальной сети" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_lan" ]; then
                    set_property "visible-lan" "$choice_lan" "$f"
                fi
                ;;
            pvp) toggle_prop "pvp" "$f" ;;
            locator-panel)
                local desc=$(get_setting_description "locator-panel")
                local cur=$(get_property "locator-panel" "$f" "true")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_loc=$(whiptail --title "Панель локатора" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_loc" ]; then
                    set_property "locator-panel" "$choice_loc" "$f"
                fi
                ;;
            0) return ;;
        esac
    done
}

configure_cheats_settings() {
    local f="$DEFAULT_INSTALL_DIR/server.properties"
    while true; do
        local allow_cheats_val=$(get_property "allow-cheats" "$f" "false")
        local allow_cheats=$(fmt_bool "$allow_cheats_val")
        local cmd_blocks=$(fmt_bool "$(get_property "enable-command-blocks" "$f" "false")")
        
        local day_night=$(get_gamerule_value "dodaylightcycle")
        local keep_inv=$(get_gamerule_value "keepinventory")
        local mob_spawn=$(get_gamerule_value "domobspawning")
        local mob_grief=$(get_gamerule_value "mobgriefing")
        local weather=$(get_gamerule_value "doweathercycle")
        local entity_drops=$(get_gamerule_value "doentitydrops")
        local cmd_output=$(get_gamerule_value "commandblockoutput")
        
        # Gamerules хранятся в мире, а не в server.properties. Отображаем значок "⚡" чтобы показать что это команда.
        
        # Меню строим динамически: если читы выключены, скрываем остальные пункты
        local menu_items=(
            "allow-cheats" "Разрешить читы: $allow_cheats"
        )
        if [[ "${allow_cheats_val,,}" == "true" ]]; then
            menu_items+=(
                "enable-command-blocks" "Командные блоки: $cmd_blocks"
                "dodaylightcycle" "⚡ Смена дня и ночи ($day_night)"
                "keepinventory" "⚡ Сохранять инвентарь ($keep_inv)"
                "domobspawning" "⚡ Создание мобов ($mob_spawn)"
                "mobgriefing" "⚡ Вредительство мобов ($mob_grief)"
                "doweathercycle" "⚡ Смена погоды ($weather)"
                "doentitydrops" "⚡ Выпадение добычи из сущностей ($entity_drops)"
                "commandblockoutput" "⚡ Вывод командных блоков ($cmd_output)"
            )
        fi
        menu_items+=("0" "← Назад")

        local choice=$(whiptail --title "🛠️ Читы и Команды" --menu "⚡ = Gamerule (применяется к запущенному серверу)\n(...) = Последнее установленное значение через этот скрипт\n\nВыберите параметр:" 24 80 14 "${menu_items[@]}" 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then return; fi

        case $choice in
            allow-cheats)
                local desc=$(get_setting_description "allow-cheats")
                local cur=$(get_property "allow-cheats" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_ac=$(whiptail --title "Разрешить читы" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ac" ]; then
                    set_property "allow-cheats" "$choice_ac" "$f"
                fi
                ;;
            enable-command-blocks)
                local desc=$(get_setting_description "enable-command-blocks")
                local cur=$(get_property "enable-command-blocks" "$f" "false")
                local on="OFF"; local off="OFF"; if [[ "${cur,,}" == "true" ]]; then on="ON"; else off="ON"; fi
                local choice_cb=$(whiptail --title "Командные блоки" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_cb" ]; then
                    set_property "enable-command-blocks" "$choice_cb" "$f"
                fi
                ;;
            dodaylightcycle)
                local desc=$(get_setting_description "dodaylightcycle")
                local cur="true"
                local on="ON"; local off="OFF"
                local choice_gc=$(whiptail --title "Смена дня и ночи" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_gc" ]; then
                    menu_gamerule_cmd "dodaylightcycle" "$choice_gc"
                fi
                ;;
            keepinventory)
                local desc=$(get_setting_description "keepinventory")
                local on="ON"; local off="OFF"
                local choice_ki=$(whiptail --title "Сохранять инвентарь" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "$on" \
                    "false" "Выключить" "$off" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ki" ]; then
                    menu_gamerule_cmd "keepinventory" "$choice_ki"
                fi
                ;;
            domobspawning)
                local desc=$(get_setting_description "domobspawning")
                local choice_ms=$(whiptail --title "Создание мобов" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "ON" \
                    "false" "Выключить" "OFF" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ms" ]; then
                    menu_gamerule_cmd "domobspawning" "$choice_ms"
                fi
                ;;
            mobgriefing)
                local desc=$(get_setting_description "mobgriefing")
                local choice_mg=$(whiptail --title "Вредительство мобов" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "ON" \
                    "false" "Выключить" "OFF" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_mg" ]; then
                    menu_gamerule_cmd "mobgriefing" "$choice_mg"
                fi
                ;;
            doweathercycle)
                local desc=$(get_setting_description "doweathercycle")
                local choice_wc=$(whiptail --title "Смена погоды" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "ON" \
                    "false" "Выключить" "OFF" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_wc" ]; then
                    menu_gamerule_cmd "doweathercycle" "$choice_wc"
                fi
                ;;
            doentitydrops)
                local desc=$(get_setting_description "doentitydrops")
                local choice_ed=$(whiptail --title "Выпадение добычи" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "ON" \
                    "false" "Выключить" "OFF" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_ed" ]; then
                    menu_gamerule_cmd "doentitydrops" "$choice_ed"
                fi
                ;;
            commandblockoutput)
                local desc=$(get_setting_description "commandblockoutput")
                local choice_cbo=$(whiptail --title "Вывод командных блоков" --radiolist "$desc\n\nВыберите состояние:" 20 80 2 \
                    "true" "Включить" "ON" \
                    "false" "Выключить" "OFF" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ] && [ -n "$choice_cbo" ]; then
                    menu_gamerule_cmd "commandblockoutput" "$choice_cbo"
                fi
                ;;
            0) return ;;
        esac
    done
}

configure_other_settings() {
    local f="$DEFAULT_INSTALL_DIR/server.properties"
    # Список ключей, которые мы уже показали в других меню
    local known="server-name|gamemode|difficulty|level-seed|level-type|simulation-distance|spawn-radius|default-player-permission-level|max-players|online-mode|white-list|pvp|view-distance|allow-cheats|enable-command-blocks|server-port|server-portv6|server-ip"
    
    # Ищем ключи, которых нет в known
    local others=($(grep -vE "^#|^$|($known)=" "$f" | cut -d'=' -f1 | sort))
    
    if [ ${#others[@]} -eq 0 ]; then 
        whiptail --msgbox "✅ Все настройки уже доступны в других разделах.\n\nНет дополнительных параметров для редактирования." 10 60
        return
    fi
    
    local menu_items=("0" "← Назад")
    for key in "${others[@]}"; do
        local val=$(get_property "$key" "$f" "")
        local display_val=$(fmt_value "$val" 30)
        menu_items+=("$key" "$key = $display_val")
    done
    
    local choice=$(whiptail --title "🔍 Другие настройки" --menu "Выберите параметр для редактирования:" 20 80 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ "$choice" != "0" ]; then
        input_prop "$choice" "$f" "$choice"
    fi
}

# Helper for Gamerule (Direct Command)
menu_gamerule_cmd() {
    local rule="$1"; local val="$2"
    local screen_name=${SERVICE_NAME%.service}
    
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        whiptail --msgbox "⚠️ Сервер не запущен.\n\nПравило '$rule' можно изменить только когда сервер работает.\n\nЗапустите сервер и попробуйте снова." 12 60
        return 1
    fi
    
    if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "gamerule $rule $val^M" 2>/dev/null; then
        # Сохраняем успешное изменение в кэш
        local cache_file="$DEFAULT_INSTALL_DIR/.gamerules_cache"
        # Удаляем старую запись если есть
        if [ -f "$cache_file" ]; then
            grep -v "^${rule}=" "$cache_file" > "${cache_file}.tmp" && mv "${cache_file}.tmp" "$cache_file"
        fi
        echo "${rule}=${val}" >> "$cache_file"
        
        # Сообщение убрано по просьбе пользователя
        # local display_val="ВЫКЛ"
        # if [[ "$val" == "true" ]]; then display_val="ВКЛ"; fi
        # whiptail --msgbox "✅ Правило '$rule' установлено: $display_val\n\nИзменения применены немедленно." 10 50
        return 0
    else
        whiptail --msgbox "❌ Ошибка при отправке команды серверу!" 8 50
        return 1
    fi
}

ensure_whiptail() {
    if ! command -v whiptail >/dev/null; then
        echo "Установка whiptail..."
        sudo apt-get update && sudo apt-get install -y whiptail
    fi
}

# Helper to format boolean for menu
fmt_bool() {
    local val="${1,,}"  # Приводим к нижнему регистру
    if [[ "$val" == "true" || "$val" == "1" ]]; then echo "ВКЛ"; else echo "ВЫКЛ"; fi
}

# Helper to format value for menu display (truncate long values)
fmt_value() {
    local val="$1"
    local max_len="${2:-20}"  # По умолчанию 20 символов
    if [ ${#val} -gt $max_len ]; then
        echo "${val:0:$((max_len-3))}..."
    else
        echo "$val"
    fi
}

# Helper to get display name in Russian for known keys/values
display_ru() {
    local key="$1"; local val="$2"
    case "$key" in
        gamemode)
            case "$val" in
                survival) echo "Выживание" ;;
                creative) echo "Творческий" ;;
                adventure) echo "Приключение" ;;
                *) echo "$val" ;;
            esac
            ;;
        difficulty)
            case "$val" in
                peaceful) echo "Мирный" ;;
                easy) echo "Легкий" ;;
                normal) echo "Обычный" ;;
                hard) echo "Сложный" ;;
                *) echo "$val" ;;
            esac
            ;;
        default-player-permission-level)
            case "$val" in
                visitor) echo "Посетитель" ;;
                member) echo "Участник" ;;
                operator) echo "Оператор" ;;
                *) echo "$val" ;;
            esac
            ;;
        player-access)
            case "$val" in
                invited) echo "Приглашенные" ;;
                friends) echo "Друзья" ;;
                friends-of-friends) echo "Друзья друзей" ;;
                *) echo "$val" ;;
            esac
            ;;
        multiplayer)
            case "$val" in
                true) echo "ВКЛ" ;;
                false) echo "ВЫКЛ" ;;
                *) echo "$val" ;;
            esac
            ;;
        showdayspassed)
            case "$val" in
                true) echo "ВКЛ" ;;
                false) echo "ВЫКЛ" ;;
                *) echo "$val" ;;
            esac
            ;;
        *) echo "$val" ;;
    esac
}

# Helper to get cached gamerule value
get_gamerule_value() {
    local rule="$1"
    local cache_file="$DEFAULT_INSTALL_DIR/.gamerules_cache"
    local default="Неизв."
    
    if [ -f "$cache_file" ]; then
        local val=$(grep "^${rule}=" "$cache_file" | cut -d'=' -f2)
        if [ -n "$val" ]; then
            if [[ "$val" == "true" ]]; then echo "ВКЛ"; else echo "ВЫКЛ"; fi
            return
        fi
    fi
    echo "$default"
}


# Helper to validate number
validate_number() {
    local num="$1"
    local min="${2:-0}"
    local max="${3:-2147483647}"
    
    # Проверяем, что это число
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Проверяем диапазон
    if [ "$num" -lt "$min" ] || [ "$num" -gt "$max" ]; then
        return 1
    fi
    
    return 0
}

# Helper to get setting description (как на скриншотах)
get_setting_description() {
    local key="$1"
    case "$key" in
        "server-name")
            echo "Название вашего сервера, которое видят игроки при подключении"
            ;;
        "gamemode")
            echo "Режим игры определяет возможности игроков:\n• Выживание: исследуйте мир, собирайте ресурсы, сражайтесь\n• Творческий: неограниченные ресурсы, полет, неуязвимость\n• Приключение: как выживание, но нельзя ломать блоки"
            ;;
        "difficulty")
            echo "Уровень сложности влияет на урон и поведение мобов:\n• Мирный: нет враждебных мобов, нет голода\n• Легкий: мобы наносят меньше урона\n• Обычный: стандартная сложность\n• Сложный: максимальный урон, голод снижает здоровье до 0.5"
            ;;
        "level-seed")
            echo "Управляет алгоритмом, который создает ваш мир.\nОдинаковый сид создаст одинаковый мир.\nОставьте пустым для случайного мира."
            ;;
        "level-type")
            echo "Плоский мир.\nКопайте или стройте в удовольствие.\n• Обычный: стандартная генерация с биомами\n• Плоский: плоский мир для строительства\n• Классический: старая генерация"
            ;;
        "simulation-distance")
            echo "Дистанция моделирования.\nИгра загружается и применяет изменения на максимальном расстоянии от игрока (в блоках):\n• 4 фрагмента: 64x64 блоков\n• 6 фрагментов: 96x96 блоков\n• 8 фрагментов: 128x128 блоков\nВлияет на производительность сервера."
            ;;
        "spawn-radius")
            echo "Возрождение в пределах указанного радиуса в блоках, если не установлена точка появления.\nМаксимальное значение: 128"
            ;;
        "default-player-permission-level")
            echo "Права игроков по умолчанию:\n• Посетитель: только просмотр, нельзя взаимодействовать\n• Участник: может строить, добывать, атаковать\n• Оператор: все права участника + команды"
            ;;
        "max-players")
            echo "Максимальное количество игроков, которые могут одновременно находиться на сервере"
            ;;
        "view-distance")
            echo "Дистанция прорисовки (в блоках).\nОпределяет, как далеко игроки видят мир.\nБольше значение = лучше видимость, но выше нагрузка."
            ;;
        "online-mode")
            echo "Проверка лицензий Minecraft.\nВКЛ: только игроки с лицензией могут подключиться\nВЫКЛ: любой может подключиться (пиратские копии)"
            ;;
        "white-list")
            echo "Белый список игроков.\nВКЛ: только игроки из whitelist.json могут подключиться\nВЫКЛ: любой может подключиться (если online-mode выключен)"
            ;;
        "pvp")
            echo "Огонь по своим.\nВКЛ: игроки могут наносить урон друг другу\nВЫКЛ: игроки не могут атаковать друг друга"
            ;;
        "allow-cheats")
            echo "Разрешить использование читов и команд в игре.\nВКЛ: игроки могут использовать команды (если есть права)\nВЫКЛ: команды недоступны"
            ;;
        "enable-command-blocks")
            echo "Используйте команды для программирования этих блоков.\nВКЛ: командные блоки работают\nВЫКЛ: командные блоки не работают"
            ;;
        "showcoordinates")
            echo "Отображение вашего текущего положения в мире.\nПоказывает координаты X, Y, Z"
            ;;
        "dofiretick")
            echo "Распространение огня.\nВКЛ: огонь может переходить с одной сущности на другую\nВЫКЛ: огонь не распространяется"
            ;;
        "tntexplodes")
            echo "Детонация динамита.\nВКЛ: TNT взрывается при активации\nВЫКЛ: TNT не взрывается"
            ;;
        "player-access")
            echo "Доступ игрока.\nКто может подключаться к вашему миру:\n• Приглашенные\n• Друзья\n• Друзья друзей"
            ;;
        "visible-lan")
            echo "Видят игроки в локальной сети.\nИгроки в вашей локальной сети могут присоединиться к вашему миру."
            ;;
        "locator-panel")
            echo "Панель локатора.\nПоказывает направление ближайших игроков в мире."
            ;;
        "multiplayer")
            echo "Многопользовательская игра.\nДругие игроки могут присоединиться к вашему миру."
            ;;
        "doimmediaterespawn")
            echo "Мгновенное возрождение.\nВКЛ: пропустить меню «Ты умер!» и сразу возродиться\nВЫКЛ: показывать экран смерти"
            ;;
        "showdayspassed")
            echo "Показать количество прошедших дней.\nОтобразить количество прошедших игровых дней."
            ;;
        "naturalregeneration")
            echo "Естественная регенерация.\nВКЛ: увеличение или потеря здоровья из-за голода\nВЫКЛ: здоровье не восстанавливается автоматически"
            ;;
        "keepinventory")
            echo "Сохранение инвентаря при смерти.\nВКЛ: все предметы остаются в инвентаре после смерти\nВЫКЛ: предметы выпадают при смерти"
            ;;
        "dodaylightcycle")
            echo "Смена дня и ночи.\nВКЛ: время в игре идет нормально, день и ночь сменяются\nВЫКЛ: время застывает"
            ;;
        "doweathercycle")
            echo "Смена погоды.\nВКЛ: возможность дождя, снега и грозы\nВЫКЛ: погода не меняется"
            ;;
        "domobspawning")
            echo "Создание мобов.\nВКЛ: мобы создаются естественным образом\nВЫКЛ: мобы не спавнятся"
            ;;
        "mobgriefing")
            echo "Вредительство мобов.\nВКЛ: мобы могут перемещать и уничтожать блоки в мире\nВЫКЛ: мобы не могут изменять блоки"
            ;;
        "doentitydrops")
            echo "Выпадение добычи из сущностей.\nВКЛ: из объектов, не являющихся мобами (например, из картин), выпадают предметы\nВЫКЛ: предметы не выпадают"
            ;;
        "dotiledrops")
            echo "Выпадение предметов из блоков.\nВКЛ: при разрушении блоков выпадают предметы\nВЫКЛ: предметы не выпадают"
            ;;
        "commandblockoutput")
            echo "Вывод командных блоков.\nВКЛ: команды из командных блоков выводятся в чат\nВЫКЛ: команды скрыты"
            ;;
        "randomtickspeed")
            echo "Случайная скорость такта.\nВлияет на поведение определенных блоков, например, на скорость роста и гниения растительности.\n0 = отключено, 1 = нормально (макс. 4096)"
            ;;
        "playerssleepingpercentage")
            echo "Процент спящих игроков.\nСколько игроков должно быть в кровати, чтобы пропустить ночь?\n0-100% (100% = все игроки)"
            ;;
        "recipesunlock")
            echo "Разблокировка рецептов.\nВКЛ: собирайте материалы, чтобы открыть новые рецепты в книге рецептов\nВЫКЛ: все рецепты доступны сразу"
            ;;
        "respawnblocksexplode")
            echo "Возрождающиеся блоки взрываются.\nВКЛ: якоря возрождения и кровати могут взрываться\nВЫКЛ: блоки не взрываются"
            ;;
        "hardcore")
            echo "Хардкор режим.\nВы не сможете возродиться, если умрете. Удачи! Она вам понадобится."
            ;;
        "start-with-map")
            echo "Начальная карта.\nВКЛ: появиться на пустой карте, чтобы исследовать мир\nВЫКЛ: без карты"
            ;;
        "bonus-chest")
            echo "Бонусный сундук.\nВКЛ: появление рядом с сундуком с предметами в начале игры\nВЫКЛ: без бонусного сундука"
            ;;
        *)
            echo "Настройка параметра сервера"
            ;;
    esac
}

# Helper to toggle boolean property
toggle_prop() {
    local key="$1"; local file="$2"
    local current=$(get_property "$key" "$file" "false")
    local new_val="true"
    local current_display=$(fmt_bool "$current")
    local desc=$(get_setting_description "$key")
    
    if [[ "${current,,}" == "true" ]]; then 
        new_val="false"
    fi
    
    local new_display=$(fmt_bool "$new_val")
    
    # Показываем описание и подтверждение
    local title=""
    case "$key" in
        "online-mode") title="Online Mode (Лицензия)" ;;
        "white-list") title="Белый список" ;;
        "pvp") title="PvP (Огонь по своим)" ;;
        "allow-cheats") title="Разрешить читы" ;;
        "enable-command-blocks") title="Командные блоки" ;;
        *) title="$key" ;;
    esac
    
    if whiptail --yesno "$title\n\n$desc\n\nТекущее значение: $current_display\nНовое значение: $new_display" 15 70 --yes-button "Изменить" --no-button "Отмена"; then
        if ! set_property "$key" "$new_val" "$file"; then
            whiptail --msgbox "❌ Ошибка при изменении настройки!" 8 50
        fi
    fi
}

# Helper for Input Box
input_prop() {
    local key="$1"; local file="$2"; local title="$3"
    local min_val="${4:-}"  # Минимальное значение (опционально)
    local max_val="${5:-}"  # Максимальное значение (опционально)
    local current=$(get_property "$key" "$file" "")
    local desc=$(get_setting_description "$key")
    
    # Показываем описание сначала
    whiptail --msgbox "$title\n\n$desc\n\nТекущее значение: ${current:-не задано}" 15 70
    
    local prompt="Введите новое значение:"
    
    # Добавляем информацию о диапазоне, если указан
    if [ -n "$min_val" ] && [ -n "$max_val" ]; then
        prompt="$prompt\n(Диапазон: $min_val - $max_val)"
    fi
    
    while true; do
        local new_val=$(whiptail --title "$title" --inputbox "$prompt" 12 60 "$current" 3>&1 1>&2 2>&3)
        local exit_code=$?
        
        if [ $exit_code -ne 0 ]; then
            return  # Пользователь отменил
        fi
        
        # Для некоторых полей пустое значение допустимо (например, level-seed)
        if [ -z "$new_val" ] && [[ "$key" != "level-seed" && "$key" != "server-name" ]]; then
            whiptail --msgbox "❌ Значение не может быть пустым!" 8 50
            continue
        fi
        
        # Валидация числовых значений, если указан диапазон
        if [ -n "$min_val" ] && [ -n "$max_val" ] && [ -n "$new_val" ]; then
            if ! validate_number "$new_val" "$min_val" "$max_val"; then
                whiptail --msgbox "❌ Неверное значение!\n\nДолжно быть числом от $min_val до $max_val" 10 50
                continue
            fi
        fi
        
        # Сохраняем значение
        if set_property "$key" "$new_val" "$file"; then
            return 0
        else
            whiptail --msgbox "❌ Ошибка при сохранении настройки!" 8 50
            return 1
        fi
    done
}

# Helper for Radio List (Select)
select_prop() {
    local key="$1"; local file="$2"; local title="$3"; shift 3; local options=("$@")
    local current=$(get_property "$key" "$file" "")
    local desc=$(get_setting_description "$key")
    
    # Маппинг английских названий на русские
    declare -A translations=(
        ["survival"]="Выживание"
        ["creative"]="Творческий"
        ["adventure"]="Приключение"
        ["peaceful"]="Мирный"
        ["easy"]="Легкий"
        ["normal"]="Обычный"
        ["hard"]="Сложный"
        ["DEFAULT"]="Обычный"
        ["FLAT"]="Плоский"
        ["LEGACY"]="Классический"
        ["visitor"]="Посетитель"
        ["member"]="Участник"
        ["operator"]="Оператор"
    )
    
    # Создаем массив для radiolist (только русские названия в интерфейсе)
    local args=()
    for opt in "${options[@]}"; do
        local status="OFF"
        local ru_name="${translations[$opt]:-$opt}" # отображаемое значение
        
        if [[ "$opt" == "$current" ]]; then status="ON"; fi
        # В качестве тега используем русское имя, чтобы не выводить английский столбец
        args+=("$ru_name" "" "$status")
    done
    
    # Показываем описание прямо в radiolist (размер 20x80)
    local selected_ru=$(whiptail --title "$title" --radiolist "$desc\n\nВыберите значение:" 20 80 6 "${args[@]}" 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ] && [ -n "$selected_ru" ]; then
        # Конвертируем выбранное русское значение обратно в исходный ключ
        local new_val="$current"
        for opt in "${options[@]}"; do
            local ru_name="${translations[$opt]:-$opt}"
            if [[ "$ru_name" == "$selected_ru" ]]; then
                new_val="$opt"
                break
            fi
        done

        if ! set_property "$key" "$new_val" "$file"; then
            whiptail --msgbox "❌ Ошибка при сохранении настройки!" 8 50
        fi
    fi
}

# Helper for Gamerule (Menu)
menu_gamerule() {
    local rule="$1"; local title="$2"
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        whiptail --msgbox "⚠️ Сервер не запущен.\n\nПравило '$rule' можно изменить только когда сервер работает." 10 60
        return
    fi
    
    local screen_name=${SERVICE_NAME%.service}
    local desc=$(get_setting_description "$rule")
    
    # Показываем описание правила
    whiptail --msgbox "$title\n\n$desc" 12 70
    
    local choice=$(whiptail --title "$title" --menu "Выберите состояние правила '$rule':" 12 60 2 \
        "true" "Включить ✓" \
        "false" "Выключить ✗" 3>&1 1>&2 2>&3)
        
    if [ $? -eq 0 ]; then
        if ! sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "gamerule $rule $choice^M" 2>/dev/null; then
            whiptail --msgbox "❌ Ошибка при отправке команды серверу!" 8 50
        fi
    fi
}

# Управление файлом белого списка (whitelist.json)
manage_whitelist() {
    msg "--- Управление списком разрешенных игроков (ID: $ACTIVE_SERVER_ID) ---"
    if ! is_server_installed; then error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен."; return 1; fi

    local WHITELIST_FILE="$DEFAULT_INSTALL_DIR/whitelist.json"
    local TEMP_FILE="/tmp/whitelist_temp_${ACTIVE_SERVER_ID}.json" # Уникальный временный файл
    local screen_name=${SERVICE_NAME%.service} # Имя screen сессии

    # Проверяем jq
    if ! command -v jq &>/dev/null; then error "Утилита jq не найдена. Установите: sudo apt install jq"; return 1; fi

    # Создаем файл, если его нет
    if [ ! -f "$WHITELIST_FILE" ]; then
        msg "Файл '$WHITELIST_FILE' не найден. Создание..."
        echo "[]" | sudo tee "$WHITELIST_FILE" > /dev/null
        if ! sudo chown "$SERVER_USER":"$SERVER_USER" "$WHITELIST_FILE"; then warning "Не удалось изменить владельца $WHITELIST_FILE"; fi
    fi

    # Показываем текущий список
    echo "Текущий список разрешенных игроков:"
    # Используем sudo cat для чтения файла, к которому у root может не быть прямого доступа
    if sudo jq -e '. | length > 0' "$WHITELIST_FILE" > /dev/null; then # Проверяем, что массив не пустой
        sudo jq -r '.[] | "- \(.name) (Игнор. лимит: \(.ignoresPlayerLimit // false))"' "$WHITELIST_FILE"
    else
        echo "(Список пуст)"
    fi

    echo ""; echo "Опции:"; echo "1. Добавить игрока"; echo "2. Удалить игрока"; echo "3. Очистить список"; echo "0. Назад"
    local choice; read -p "Выберите (0-3): " choice
    local changed=false # Флаг, что изменения были

    case $choice in
        1) # Добавить
            local player_name
            read -p "Введите имя игрока для добавления: " player_name
            if [ -z "$player_name" ]; then error "Имя не может быть пустым."; continue; fi
            # Проверяем, есть ли уже (читаем с sudo)
            if sudo jq -e ".[] | select(.name == \"$player_name\")" "$WHITELIST_FILE" > /dev/null; then
                msg "Игрок '$player_name' уже есть в списке."
                continue # Возвращаемся к меню опций
            fi
            # Добавляем (читаем с sudo, пишем во временный файл, потом заменяем с sudo)
            if sudo jq ". += [{\"ignoresPlayerLimit\":false, \"name\":\"$player_name\"}]" "$WHITELIST_FILE" > "$TEMP_FILE"; then
                if [ -s "$TEMP_FILE" ]; then # Проверяем, что временный файл не пустой
                    if sudo mv "$TEMP_FILE" "$WHITELIST_FILE"; then
                        sudo chown "$SERVER_USER":"$SERVER_USER" "$WHITELIST_FILE"
                        msg "Игрок '$player_name' добавлен."
                        changed=true
                    else
                        error "Не удалось переместить временный файл в '$WHITELIST_FILE'."
                        sudo rm -f "$TEMP_FILE"
                    fi
                else
                     error "Ошибка jq: Временный файл пуст."
                     sudo rm -f "$TEMP_FILE"
                fi
            else
                error "Ошибка при обработке файла белого списка с помощью jq."
                sudo rm -f "$TEMP_FILE"
            fi
            ;;
        2) # Удалить
            if ! sudo jq -e '. | length > 0' "$WHITELIST_FILE" > /dev/null; then msg "Список пуст."; continue; fi
            local players=(); mapfile -t players < <(sudo jq -r '.[].name' "$WHITELIST_FILE")
            echo "Выберите игрока для удаления:"
            for i in "${!players[@]}"; do echo "$((i+1)). ${players[i]}"; done
            local player_choice; read -p "Номер (1-${#players[@]}) или 0 для отмены: " player_choice
            if [ "$player_choice" -eq 0 ]; then msg "Отменено."; continue; fi
            if ! [[ "$player_choice" =~ ^[0-9]+$ ]] || [ "$player_choice" -lt 1 ] || [ "$player_choice" -gt ${#players[@]} ]; then error "Некорректный выбор."; continue; fi
            local selected_player="${players[$player_choice-1]}"
            # Удаляем
            if sudo jq "del(.[] | select(.name == \"$selected_player\"))" "$WHITELIST_FILE" > "$TEMP_FILE"; then
                 if sudo mv "$TEMP_FILE" "$WHITELIST_FILE"; then
                    sudo chown "$SERVER_USER":"$SERVER_USER" "$WHITELIST_FILE"
                    msg "Игрок '$selected_player' удален."
                    changed=true
                 else
                    error "Не удалось переместить временный файл в '$WHITELIST_FILE'."
                    sudo rm -f "$TEMP_FILE"
                 fi
            else
                error "Ошибка при обработке файла белого списка с помощью jq для удаления."
                sudo rm -f "$TEMP_FILE"
            fi
            ;;
        3) # Очистить
            read -p "Уверены, что хотите ОЧИСТИТЬ ВЕСЬ белый список? (yes/no): " CLEAR_CONFIRM
            if [[ "$CLEAR_CONFIRM" != "yes" ]]; then msg "Очистка отменена."; continue; fi
            if echo "[]" | sudo tee "$WHITELIST_FILE" > /dev/null; then
                 sudo chown "$SERVER_USER":"$SERVER_USER" "$WHITELIST_FILE"
                 msg "Белый список очищен."
                 changed=true
            else
                 error "Не удалось очистить файл '$WHITELIST_FILE'."
            fi
            ;;
        0) return 0 ;;
        *) msg "Неверная опция." ;;
    esac

    # Применяем изменения на сервере, если они были и сервер запущен
    if $changed ; then
        if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
            msg "Отправка команды 'whitelist reload' на сервер '$screen_name'..."
            # Команда без слэша
            if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff $'whitelist reload\015'; then
                 msg "Команда отправлена."
                 sleep 1
            else
                 warning "Не удалось отправить команду 'whitelist reload' в screen '$screen_name'."
                 msg "Изменения будут применены после перезапуска сервера."
            fi
        else
            msg "Сервер не запущен. Изменения вступят в силу при следующем старте."
        fi
    fi
    # Не выходим из цикла, позволяем выбрать другую опцию
    # return 0 # Убрали выход здесь
}

# Управление операторами (через команды)
manage_operators() {
    msg "--- Управление Операторами Сервера (ID: $ACTIVE_SERVER_ID) ---"
    if ! is_server_installed; then error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен."; return 1; fi

    local CONFIG_FILE="$DEFAULT_INSTALL_DIR/server.properties"
    local allow_cheats_enabled=$(get_property "allow-cheats" "$CONFIG_FILE" "false")
    local screen_name=${SERVICE_NAME%.service} # Имя screen сессии

    # Проверяем читы
    if [[ "$allow_cheats_enabled" != "true" ]]; then
        error "Чит-команды ВЫКЛЮЧЕНЫ (allow-cheats=false). Управление операторами НЕВОЗМОЖНО."
        return 1
    fi

    # Проверяем, запущен ли сервер
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        warning "Сервер '$SERVICE_NAME' НЕ запущен. Команды op и deop не могут быть отправлены."
        return 1
    fi

    # Меню опций
    echo ""; echo "Опции:"; echo "1. Добавить оператора (op)"; echo "2. Удалить оператора (deop)"; echo "3. Показать онлайн-игроков (list)"; echo "0. Назад"
    local choice player_name cmd
    read -p "Выберите (0-3): " choice

    case $choice in
        1) # Добавить OP
            read -p "Введите ТОЧНОЕ имя игрока для назначения оператором: " player_name
            if [ -z "$player_name" ]; then msg "Имя не может быть пустым."; continue; fi # Повторяем меню
            # Команда без слэша, без кавычек (т.к. тест показал, что кавычки мешают)
            cmd="op $player_name"
            msg "Отправка команды '$cmd' на сервер '$screen_name'..."
            if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "$cmd"$'\015'; then
                 msg "Команда отправлена. Проверьте консоль ('screen -r $screen_name') на ответ сервера."
                 sleep 1 # Пауза
            else error "Не удалось отправить команду в screen '$screen_name'."; fi
            ;;
        2) # Удалить OP
            read -p "Введите ТОЧНОЕ имя игрока для снятия прав оператора: " player_name
            if [ -z "$player_name" ]; then msg "Имя не может быть пустым."; continue; fi # Повторяем меню
            # Команда без слэша, без кавычек
            cmd="deop $player_name"
            msg "Отправка команды '$cmd' на сервер '$screen_name'..."
            if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "$cmd"$'\015'; then
                 msg "Команда отправлена. Проверьте консоль ('screen -r $screen_name') на ответ сервера."
                 sleep 1 # Пауза
            else error "Не удалось отправить команду в screen '$screen_name'."; fi
            ;;
        3) # list
            # Команда без слэша
            cmd="list"
            msg "Отправка команды '$cmd' на сервер '$screen_name'..."
            if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "$cmd"$'\015'; then
                 msg "Команда отправлена. Результат в консоли ('screen -r $screen_name')."
                 sleep 1 # Пауза
            else error "Не удалось отправить команду в screen '$screen_name'."; fi
            read -p "Нажмите Enter для продолжения..." DUMMY_VAR
            ;;
        0) return 0 ;; # Выход из функции (и подменю)
        *) msg "Неверная опция." ;;
    esac
    # Не выходим из цикла здесь, чтобы пользователь мог выполнить еще действие
    # return 0 # Убрали выход
}

# Подменю управления игроками
players_menu() {
    if ! is_server_installed; then error "Сервер (ID: ${ACTIVE_SERVER_ID:-N/A}) не установлен."; return 1; fi
    while true; do
        echo ""; echo "--- Управление Игроками (Сервер ID: $ACTIVE_SERVER_ID) ---"
        echo "1. Включить/отключить белый список (в server.properties)"
        echo "2. Управление файлом белого списка (whitelist.json)"
        echo "3. Управление операторами (команды op, deop)"
        echo "0. Назад в главное меню"
        echo "-----------------------------------"
        local players_choice; read -p "Выберите опцию: " players_choice
        case $players_choice in
            1) toggle_whitelist ;;
            2) manage_whitelist ;;
            3) manage_operators ;;
            0) return 0 ;; # Выход из подменю
            *) msg "Неверная опция." ;;
        esac
         # Пауза перед повторным показом меню подраздела, если не вышли
        if [[ "$players_choice" != "0" ]]; then
             read -p "Нажмите Enter для возврата в меню управления игроками..." DUMMY_VAR
        fi
    done
}

# Настройка автообновления через cron
setup_auto_update() {
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; return 1; fi
    msg "--- Настройка автоматического обновления (Cron) для '$ACTIVE_SERVER_ID' ---"
    
    # Проверка cron
    if ! command -v crontab &> /dev/null; then
        error "Утилита 'crontab' не найдена. Установите cron."
        return 1
    fi

    # URL скрипта на GitHub (всегда актуальная версия)
    local script_url="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/minecraft_bedrock.sh"
    local cron_marker="minecraft_autoupdate_${ACTIVE_SERVER_ID}"
    # Новые записи добавляются в начало лога (свежее сверху)
    local log_file="/var/log/minecraft_update_${ACTIVE_SERVER_ID}.log"
    local cron_cmd="tmp=\$(mktemp); curl -Ls $script_url | bash -s -- --auto-update $ACTIVE_SERVER_ID > \$tmp 2>&1; { cat \$tmp; cat $log_file 2>/dev/null; } > ${log_file}.new && mv ${log_file}.new $log_file; rm -f \$tmp # $cron_marker"
    
    # Проверяем, есть ли уже задача (ищем по маркеру)
    if sudo crontab -l 2>/dev/null | grep -Fq "$cron_marker"; then
        msg "⚠️ Автообновление для этого сервера уже настроено."
        read -p "Хотите удалить существующее расписание? (yes/no): " DEL_CRON
        if [[ "$DEL_CRON" == "yes" ]]; then
            # Удаляем строку из crontab по маркеру
            sudo crontab -l 2>/dev/null | grep -Fv "$cron_marker" | sudo crontab -
            msg "✅ Автообновление отключено."
        fi
        return 0
    fi

    echo "Выберите частоту проверки обновлений:"
    echo "1. Каждый час"
    echo "2. Каждый день (в 4:00 утра)"
    echo "3. Каждую неделю (Воскресенье в 4:00 утра)"
    echo "0. Отмена"
    
    local freq_choice
    read -p "Ваш выбор: " freq_choice
    
    local cron_schedule=""
    case $freq_choice in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 4 * * *" ;;
        3) cron_schedule="0 4 * * 0" ;;
        0) return 0 ;;
        *) error "Неверный выбор."; return 1 ;;
    esac

    msg "Добавление задачи в crontab root..."
    # Добавляем новую задачу, сохраняя старые
    (sudo crontab -l 2>/dev/null; echo "$cron_schedule $cron_cmd") | sudo crontab -
    
    msg "✅ Автообновление успешно настроено!"
    msg "Скрипт будет скачиваться с GitHub при каждой проверке (всегда актуальная версия)."
    msg "Логи будут писаться в: /var/log/minecraft_update_${ACTIVE_SERVER_ID}.log"
    read -p "Нажмите Enter для продолжения..." DUMMY_VAR
}

# Функция для ручного обновления сервера (пользователь предоставляет архив)
manual_update_server() {
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран для обновления."; return 1; fi
    msg "--- Установка Обновления Сервера (ID: $ACTIVE_SERVER_ID) ВРУЧНУЮ ---"

    local user_downloaded_zip
    read -p "Введите ПОЛНЫЙ путь к скачанному вами .zip архиву новой версии сервера: " user_downloaded_zip

    if [ -z "$user_downloaded_zip" ] || [ ! -f "$user_downloaded_zip" ]; then
        error "Файл архива '$user_downloaded_zip' не найден или путь не указан."
        return 1
    fi

    local new_version_manual
    read -p "Введите номер новой версии, которую вы устанавливаете (например, 1.21.80.01): " new_version_manual

    if [ -z "$new_version_manual" ]; then
        warning "Номер версии не указан. Файл 'version' не будет обновлен."
    fi

    msg "Вы собираетесь обновить сервер '$ACTIVE_SERVER_ID' используя файл: $user_downloaded_zip"
    msg "Будет установлена версия: ${new_version_manual:-'не указана'}"
    read -p "Продолжить установку обновления? (yes/no): " CONFIRM_MANUAL_UPDATE
    if [[ "$CONFIRM_MANUAL_UPDATE" != "yes" ]]; then
        msg "Установка обновления отменена."
        return 1
    fi

    perform_update_core "$user_downloaded_zip" "$new_version_manual"
}

# --- Функции Мультисерверного режима ---

# Загрузка конфигурации конкретного сервера
load_server_config() {
    local server_id="$1"
    if [ -z "$server_id" ]; then error "Не указан ID сервера."; return 1; fi
    # Проверяем существование файла конфига перед чтением
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then error "Файл конфигурации серверов '$SERVERS_CONFIG_FILE' не найден."; return 1; fi

    # Ищем строку для указанного сервера, игнорируя комментарии
    local server_info=$(grep -v '^#' "$SERVERS_CONFIG_FILE" | grep "^${server_id}:")
    if [ -z "$server_info" ]; then error "Сервер с ID '$server_id' не найден в '$SERVERS_CONFIG_FILE'."; return 1; fi

    # Извлекаем данные с помощью IFS
    # Отключаем глоббинг на время read, чтобы символы типа * не интерпретировались
    local glob_setting=$(set +o | grep noglob) # Сохраняем текущую настройку noglob
    set -f # Отключаем глоббинг
    IFS=':' read -r id name port dir service <<< "$server_info"
    # Возвращаем настройку глоббинга
    if [[ "$glob_setting" == "noglob       	off" ]]; then set +f; else set -f; fi


    # Проверяем корректность извлеченных значений
    if [ -z "$dir" ] || [ -z "$service" ] || [ -z "$port" ] || [ -z "$name" ]; then
        error "Некорректная или неполная запись для сервера с ID '$server_id' в конфигурации."
        # Сбрасываем глобальные переменные на всякий случай
        ACTIVE_SERVER_ID=""; DEFAULT_INSTALL_DIR=""; SERVICE_NAME=""; SERVER_PORT=""; SERVICE_FILE=""
        return 1
    fi

    # Обновляем глобальные переменные
    DEFAULT_INSTALL_DIR="$dir"
    SERVICE_NAME="$service"
    SERVICE_FILE="/etc/systemd/system/${service}"
    SERVER_PORT="$port"
    ACTIVE_SERVER_ID="$id"

    msg ">>> Активный сервер: $id (Порт: $port, Путь: $dir, Сервис: $service) <<<"
    return 0
}

# Установка сервера Bedrock
install_bds() {
    local install_dir="$1"
    local service_name="$2"
    local server_port="$3"
    local local_zip_path="$4"

    if [ -z "$install_dir" ] || [ -z "$service_name" ] || [ -z "$server_port" ]; then
        error "Внутренняя ошибка: Неверные аргументы для install_bds."
        return 1
    fi

    msg "--- Установка сервера в '$install_dir' ---"

    # 1. Создание директории
    if [ ! -d "$install_dir" ]; then
        msg "Создание директории установки..."
        if ! sudo mkdir -p "$install_dir"; then error "Не удалось создать директорию."; return 1; fi
        sudo chown "$SERVER_USER":"$SERVER_USER" "$install_dir"
    fi

    # 2. Скачивание или использование локального файла
    local temp_zip="/tmp/bedrock_server.zip"
    
    if [ -n "$local_zip_path" ]; then
        msg "Использование локального файла: $local_zip_path"
        if [ ! -f "$local_zip_path" ]; then
            error "Локальный файл не найден: $local_zip_path"
            return 1
        fi
        # Копируем во временный файл, чтобы не трогать оригинал и унифицировать процесс
        if ! cp "$local_zip_path" "$temp_zip"; then
            error "Не удалось скопировать локальный файл во временную директорию."
            return 1
        fi
    else
        msg "Получение ссылки на последнюю версию..."
        # Парсим страницу загрузки, чтобы найти актуальную ссылку
        # Используем User-Agent, чтобы сайт не блокировал запрос
        local download_url=$(curl -s -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" https://www.minecraft.net/en-us/download/server/bedrock | grep -o 'https://minecraft.azureedge.net/bin-linux/[^"]*zip' | head -n 1)

        if [ -z "$download_url" ]; then
            error "Не удалось найти ссылку для скачивания. Возможно, изменилась структура сайта Minecraft."
            return 1
        fi

        msg "Скачивание сервера: $download_url"
        if ! wget -q --show-progress -O "$temp_zip" "$download_url"; then
            error "Ошибка при скачивании файла."
            return 1
        fi
    fi

    # 3. Распаковка
    msg "Распаковка архива..."
    if ! sudo unzip -q -o "$temp_zip" -d "$install_dir"; then
        error "Ошибка при распаковке."
        rm -f "$temp_zip"
        return 1
    fi
    rm -f "$temp_zip"

    # 4. Настройка прав
    msg "Настройка прав доступа..."
    sudo chown -R "$SERVER_USER":"$SERVER_USER" "$install_dir"
    sudo chmod +x "$install_dir/bedrock_server"

    # 5. Настройка порта в server.properties
    msg "Настройка порта $server_port..."
    local props_file="$install_dir/server.properties"
    if [ -f "$props_file" ]; then
        # Используем функцию set_property, но она требует, чтобы файл существовал
        # Мы не можем использовать set_property напрямую, так как она работает с sudo и может не найти файл, если права кривые
        # Но мы только что сделали chown.
        # Однако set_property - это функция скрипта.
        # Проще сделать sed напрямую здесь или вызвать set_property, если она доступна.
        # set_property определена выше, так что доступна.
        set_property "server-port" "$server_port" "$props_file"
        # Используем порт+1 для IPv6, чтобы избежать конфликтов
        local portv6=$((server_port + 1))
        set_property "server-portv6" "$portv6" "$props_file"
    else
        warning "Файл server.properties не найден после распаковки."
    fi

    # 6. Создание сервиса
    if ! create_systemd_service "$install_dir" "$service_name"; then
        error "Не удалось создать сервис."
        return 1
    fi

    # 7. Открытие порта
    open_firewall_port "$server_port"

    msg "✅ Установка сервера завершена успешно."
    return 0
}

# Удаление сервера (файлы, сервис, порт)
uninstall_bds() {
    local dir="$1"
    local service="$2"
    local port="$3"

    msg "--- Процесс удаления сервера ---"

    # 1. Остановка и отключение сервиса
    if sudo systemctl is-active --quiet "$service"; then
        msg "Остановка сервиса '$service'..."
        sudo systemctl stop "$service"
    fi
    if sudo systemctl is-enabled --quiet "$service"; then
        msg "Отключение автозапуска..."
        sudo systemctl disable "$service"
    fi

    # 2. Удаление файла сервиса
    local service_file="/etc/systemd/system/$service"
    if [ -f "$service_file" ]; then
        msg "Удаление файла сервиса..."
        sudo rm -f "$service_file"
        sudo systemctl daemon-reload
    fi

    # 3. Закрытие порта
    if [ -n "$port" ]; then
        close_firewall_port "$port"
    fi

    # 4. Удаление файлов
    if [ -d "$dir" ]; then
        msg "Удаление директории сервера '$dir'..."
        sudo rm -rf "$dir"
    else
        warning "Директория '$dir' не найдена."
    fi

    msg "✅ Сервер удален."
    return 0
}

# Создание нового сервера
create_new_server() {
    msg "--- Создание нового сервера Minecraft Bedrock ---"
    # Мультисерверный режим теперь всегда активен, проверка MULTISERVER_ENABLED не нужна

    local server_id server_display_name server_port new_dir new_service
    
    # 1. Запрос ID сервера
    while [ -z "$server_id" ]; do
        read -p "Введите уникальный ID для нового сервера (латиница, цифры, _, -): " server_id
        # Очистка ID (удаляем все кроме букв, цифр, _ и -)
        server_id=$(echo "$server_id" | tr -cd '[:alnum:]_-')
        
        if [ -z "$server_id" ]; then
             warning "ID не может быть пустым и должен содержать хотя бы одну букву или цифру."
        elif grep -q "^${server_id}:" "$SERVERS_CONFIG_FILE" 2>/dev/null; then
             warning "Сервер с ID '$server_id' уже существует! Выберите другой ID."
             server_id=""
        fi
    done
    
    # 2. Запрос отображаемого имени сервера (server-name в server.properties)
    read -p "Введите имя сервера (отображается в игре) [Dedicated Server]: " server_display_name
    server_display_name=${server_display_name:-"Dedicated Server"}
    
    msg "Создается сервер: ID=$server_id, Имя='$server_display_name'"

    # Запрос порта
    read -p "Введите порт для сервера (например, 19132): " server_port
    server_port=${server_port:-19132}
    if ! [[ "$server_port" =~ ^[0-9]+$ ]] || [ "$server_port" -lt 1024 ] || [ "$server_port" -gt 65535 ]; then error "Некорректный порт (1024-65535)."; return 1; fi
    # Проверка уникальности порта (игнорируя комментарии)
    if grep -v '^#' "$SERVERS_CONFIG_FILE" | grep -q ":${server_port}:"; then
        warning "Порт $server_port уже используется другим сервером!"
        read -p "Продолжить с этим портом (может вызвать проблемы)? (yes/no): " CONT
        if [[ "$CONT" != "yes" ]]; then msg "Создание сервера отменено."; return 1; fi
    fi

    # Определение путей
    new_dir="$SERVERS_BASE_DIR/$server_id"
    if [ -d "$new_dir" ]; then error "Директория '$new_dir' уже существует."; return 1; fi
    new_service="bds_${server_id}.service"

    # Выбор метода установки
    echo "Выберите метод установки:"
    echo "1. Скачать автоматически (с minecraft.net)"
    echo "2. Использовать локальный zip-файл"
    local install_method
    read -p "Ваш выбор [1]: " install_method
    install_method=${install_method:-1}

    local local_zip=""
    if [[ "$install_method" == "2" ]]; then
        read -p "Введите полный путь к zip-файлу: " local_zip
        if [ ! -f "$local_zip" ]; then
            error "Файл '$local_zip' не найден."
            return 1
        fi
    fi

    # Запускаем установку с новыми параметрами
    msg "Установка нового сервера '$server_display_name' (ID: $server_id)..."
    # install_bds сама создаст директорию, сервис, откроет порт
    if ! install_bds "$new_dir" "$new_service" "$server_port" "$local_zip"; then
        # install_bds должна была вывести свою ошибку
        error "Не удалось завершить установку нового сервера."
        # Дополнительно чистим, если что-то было создано частично
        sudo rm -rf "$new_dir"
        if [ -f "/etc/systemd/system/$new_service" ]; then sudo rm "/etc/systemd/system/$new_service"; sudo systemctl daemon-reload; fi
        return 1
    fi

    # Проверяем успешность установки еще раз (файл bedrock_server должен появиться)
    if [ ! -f "$new_dir/bedrock_server" ]; then error "Установка вроде бы завершилась, но файл bedrock_server не найден в '$new_dir'."; return 1; fi

    # Устанавливаем server-name в server.properties
    local props_file="$new_dir/server.properties"
    if [ -f "$props_file" ]; then
        set_property "server-name" "$server_display_name" "$props_file"
        msg "Имя сервера установлено: '$server_display_name'"
    fi

    # Добавляем запись в конфигурацию
    echo "${server_id}:${server_id}:${server_port}:${new_dir}:${new_service}" | sudo tee -a "$SERVERS_CONFIG_FILE" > /dev/null
    msg "Сервер '$server_display_name' (ID: $server_id) добавлен в $SERVERS_CONFIG_FILE."

    # Предлагаем сделать его активным
    read -p "Сделать '$server_display_name' активным сервером сейчас? (yes/no): " ACTIVATE_NEW
    if [[ "$ACTIVATE_NEW" == "yes" ]]; then
        if ! load_server_config "$server_id"; then
             warning "Не удалось автоматически активировать новый сервер."
        else
             # Автозапуск
             msg "Запуск нового сервера..."
             if start_server; then
                 msg "Сервер запущен!"
             else
                 warning "Не удалось запустить сервер."
             fi
        fi
    fi
    return 0
}

# Удаление существующего сервера (вызывается из главного меню для активного)
delete_server() {
    msg "--- Удаление Активного Сервера Minecraft Bedrock ---"
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран для удаления."; return 1; fi

    # Получаем данные АКТИВНОГО сервера
    local id=$ACTIVE_SERVER_ID
    local name=$(grep "^${id}:" "$SERVERS_CONFIG_FILE" | cut -d':' -f2)
    local port=$SERVER_PORT
    local dir=$DEFAULT_INSTALL_DIR
    local service=$SERVICE_NAME

    warning "ВНИМАНИЕ! Удаление сервера (ID: $id) приведет к потере всех данных из '$dir'!"
    read -p "Создать резервную копию ПЕРЕД удалением? (yes/no): " BACKUP_CONFIRM
    if [[ "$BACKUP_CONFIRM" == "yes" ]]; then
        msg "Создание резервной копии для сервера '$id'..."
        if create_backup; then
            msg "Резервная копия создана."
        else
            warning "Не удалось создать копию!"
            read -p "Продолжить удаление БЕЗ копии? (yes/no): " CONT_DEL
            if [[ "$CONT_DEL" != "yes" ]]; then msg "Удаление отменено."; return 1; fi
        fi
    fi

    read -p "Вы ТОЧНО уверены, что хотите удалить сервер (ID: $id)? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then msg "Удаление отменено."; return 1; fi

    # Используем uninstall_bds для основной работы (остановка, удаление сервиса, папки, порт)
    # Передаем данные удаляемого сервера, а не глобальные переменные
    if ! uninstall_bds "$dir" "$service" "$port"; then
        error "Произошла ошибка во время процесса удаления. Проверьте вывод выше."
        # Не продолжаем удаление из конфига, если основное удаление не удалось
        return 1
    fi

    # Удаляем запись из конфигурационного файла
    msg "Удаление записи из $SERVERS_CONFIG_FILE..."
    # Используем временный файл для безопасного удаления строки
    local temp_conf=$(mktemp)
    grep -v "^${id}:" "$SERVERS_CONFIG_FILE" > "$temp_conf"
    if sudo mv "$temp_conf" "$SERVERS_CONFIG_FILE"; then
         msg "Запись для ID '$id' удалена из конфигурации."
    else
         error "Не удалось обновить файл конфигурации '$SERVERS_CONFIG_FILE'. Исправьте вручную!"
         # Не возвращаем ошибку здесь, т.к. основное удаление прошло
    fi

    # Сбрасываем активный сервер, т.к. он удален
    msg "Сброс активного сервера..."
    ACTIVE_SERVER_ID=""; DEFAULT_INSTALL_DIR=""; SERVICE_NAME=""; SERVER_PORT=""; SERVICE_FILE=""

    # Пытаемся выбрать новый активный сервер (первый из оставшихся)
    local remaining_servers=$(grep -v '^#' "$SERVERS_CONFIG_FILE" | wc -l)
    if [ "$remaining_servers" -gt 0 ]; then
        local new_active_id=$(grep -v '^#' "$SERVERS_CONFIG_FILE" | head -n 1 | cut -d':' -f1)
        msg "Попытка активировать следующий сервер (ID: $new_active_id)..."
        load_server_config "$new_active_id" || msg "Не удалось загрузить новый активный сервер."
    else
        warning "В конфигурации не осталось серверов."
    fi

    msg "Сервер (ID: $id) удален."
    return 0
}

# Изменение имени сервера (server-name в server.properties)
rename_server_display_name() {
    msg "--- Изменение имени сервера (отображается в игре) ---"
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; return 1; fi
    
    local props_file="$DEFAULT_INSTALL_DIR/server.properties"
    if [ ! -f "$props_file" ]; then
        error "Файл server.properties не найден."
        return 1
    fi
    
    local current_name=$(get_property "server-name" "$props_file" "Dedicated Server")
    msg "Текущее имя сервера: '$current_name'"
    
    read -p "Введите новое имя сервера [$current_name]: " new_name
    new_name=${new_name:-$current_name}
    
    if [ "$new_name" == "$current_name" ]; then
        msg "Имя не изменилось."
        return 0
    fi
    
    set_property "server-name" "$new_name" "$props_file"
    msg "✅ Имя сервера изменено: '$current_name' → '$new_name'"
    
    # Проверяем, запущен ли сервер
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        msg "⚠️ Для применения изменений требуется перезапуск сервера."
        read -p "Перезапустить сервер сейчас? (yes/no): " RESTART_NOW
        if [[ "$RESTART_NOW" == "yes" ]]; then
            restart_server
        fi
    fi
    
    return 0
}

# Изменение ID сервера (переименование)
rename_server_id() {
    msg "--- Изменение ID сервера ---"
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; return 1; fi

    local current_id="$ACTIVE_SERVER_ID"
    local current_dir="$DEFAULT_INSTALL_DIR"
    local current_service="$SERVICE_NAME"
    local current_port="$SERVER_PORT"
    local current_name_conf=$(grep "^${current_id}:" "$SERVERS_CONFIG_FILE" | cut -d':' -f2) # Для сохранения имени, если оно отличается (в нашей текущей логике name=id)

    msg "Текущий ID: $current_id"
    local new_id
    while [ -z "$new_id" ]; do
        read -p "Введите НОВЫЙ уникальный ID (латиница, цифры, _, -): " new_id
        local safe_id=$(echo "$new_id" | tr -cd '[:alnum:]_-')
        
        if [ -z "$new_id" ]; then
             warning "ID не может быть пустым."
        elif [ "$new_id" != "$safe_id" ]; then
             warning "ID содержит недопустимые символы. Используйте только буквы, цифры, _ и -."
             new_id=""
        elif grep -q "^${safe_id}:" "$SERVERS_CONFIG_FILE" 2>/dev/null; then
             warning "Сервер с ID '$safe_id' уже существует!"
             new_id=""
        fi
    done

    msg "ВНИМАНИЕ: Процесс переименования остановит сервер, переместит файлы и пересоздаст сервис."
    read -p "Вы уверены, что хотите переименовать '$current_id' в '$new_id'? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then msg "Переименование отменено."; return 1; fi

    # 1. Остановка сервера
    if sudo systemctl is-active --quiet "$current_service"; then
        msg "Остановка сервера '$current_id'..."
        stop_server
    fi

    # 2. Переименование директории
    local new_dir="$SERVERS_BASE_DIR/$new_id"
    if [ -d "$new_dir" ]; then error "Директория '$new_dir' уже существует (конфликт)."; return 1; fi

    msg "Перемещение файлов из '$current_dir' в '$new_dir'..."
    if ! sudo mv "$current_dir" "$new_dir"; then
        error "Не удалось переименовать директорию. Отмена."
        return 1
    fi

    # 3. Обновление сервиса systemd
    # Удаляем старый сервис
    msg "Удаление старого сервиса '$current_service'..."
    if sudo systemctl is-enabled --quiet "$current_service"; then
        sudo systemctl disable "$current_service"
    fi
    local old_service_file="/etc/systemd/system/$current_service"
    if [ -f "$old_service_file" ]; then
        sudo rm "$old_service_file"
    fi
    
    # Создаем новый сервис
    local new_service="bds_${new_id}.service"
    msg "Создание нового сервиса '$new_service'..."
    # Временно подменяем глобальные переменные для create_systemd_service (хотя она принимает аргументы, но использует SERVER_USER)
    if ! create_systemd_service "$new_dir" "$new_service"; then
        error "Не удалось создать новый сервис! Файлы находятся в '$new_dir'."
        # Пытаемся откатить? Сложно. Оставим файлы в новом месте, но без конфига скрипта это проблема.
        # Лучше просто вернуть ошибку.
        return 1
    fi

    # 4. Обновление конфигурации скрипта (servers.conf)
    msg "Обновление конфигурации серверов..."
    local temp_conf=$(mktemp)
    # Удаляем старую запись
    grep -v "^${current_id}:" "$SERVERS_CONFIG_FILE" > "$temp_conf"
    # Добавляем новую. Имя (name) меняем на новый ID, так как мы договорились id=name
    echo "${new_id}:${new_id}:${current_port}:${new_dir}:${new_service}" >> "$temp_conf"
    
    if sudo mv "$temp_conf" "$SERVERS_CONFIG_FILE"; then
         msg "Конфигурация обновлена."
    else
         error "Не удалось обновить '$SERVERS_CONFIG_FILE'. Проверьте вручную."
    fi

    # 5. Обновление Cron задач (автообновление и бэкапы)
    msg "Обновление задач планировщика (Cron)..."
    local cron_temp=$(mktemp)
    sudo crontab -l 2>/dev/null > "$cron_temp"
    
    # Заменяем старый ID на новый в маркерах и командах
    # Новый формат использует маркеры: minecraft_autoupdate_SERVER_ID и minecraft_autobackup_SERVER_ID
    if grep -q "$current_id" "$cron_temp"; then
        # Обновляем маркеры автообновления
        sed -i "s/minecraft_autoupdate_${current_id}/minecraft_autoupdate_${new_id}/g" "$cron_temp"
        # Обновляем аргументы команд
        sed -i "s/--auto-update $current_id /--auto-update $new_id /g" "$cron_temp"
        sed -i "s/--auto-update $current_id$/--auto-update $new_id/g" "$cron_temp"
        
        # Лог файлы в кроне тоже могут содержать ID
        sed -i "s/minecraft_update_${current_id}.log/minecraft_update_${new_id}.log/g" "$cron_temp"
        
        # То же для бэкапов
        sed -i "s/minecraft_autobackup_${current_id}/minecraft_autobackup_${new_id}/g" "$cron_temp"
        sed -i "s/--auto-backup $current_id /--auto-backup $new_id /g" "$cron_temp"
        sed -i "s/--auto-backup $current_id$/--auto-backup $new_id/g" "$cron_temp"
        sed -i "s/minecraft_backup_${current_id}.log/minecraft_backup_${new_id}.log/g" "$cron_temp"
        
        sudo crontab "$cron_temp"
        msg "Cron обновлен."
    else
        msg "Задач Cron для этого сервера не найдено."
    fi
    rm "$cron_temp"

    # 6. Обновление текущего состояния
    msg "Переключение активного сервера на новый ID..."
    if load_server_config "$new_id"; then
        msg "✅ Успешно переименовано: $current_id -> $new_id"
        msg "Автоматический запуск сервера..."
        if start_server; then
            msg "Сервер успешно запущен!"
        else
            warning "Не удалось автоматически запустить сервер. Запустите его вручную."
        fi
    else
        error "Переименование завершено, но не удалось загрузить новый конфиг."
    fi
}

# Выбор активного сервера
select_active_server() {
    msg "--- Выбор активного сервера ---"
    # Проверка наличия конфиг файла
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then error "Файл конфигурации '$SERVERS_CONFIG_FILE' не найден."; return 1; fi
    local server_count=$(grep -v '^#' "$SERVERS_CONFIG_FILE" | wc -l)
    if [ "$server_count" -eq 0 ]; then error "Нет зарегистрированных серверов в '$SERVERS_CONFIG_FILE'."; return 1; fi

    local servers=(); local server_names=(); local i=1
    msg "Список доступных серверов:"
    # Читаем файл построчно
    while IFS=: read -r id name port dir service; do
        # Пропускаем комментарии и пустые строки
         [[ -z "$id" || "$id" =~ ^# ]] && continue
        servers+=("$id"); server_names+=("$name")
        local status="остановлен"; if sudo systemctl is-active --quiet "$service"; then status="АКТИВЕН ✅"; fi
        local active_mark=" "; if [ "$id" == "$ACTIVE_SERVER_ID" ]; then active_mark="*"; fi
        printf "%1s %2d. %-25s (Порт: %-5s Статус: %s)\n" "$active_mark" $i "$id" "$port" "$status"
        ((i++))
    done < "$SERVERS_CONFIG_FILE"

    local choice;
    # Проверяем, есть ли вообще что выбирать
    if [ ${#servers[@]} -eq 0 ]; then msg "Нет серверов для выбора."; return 1; fi

    read -p "Выберите номер сервера для активации (1-${#servers[@]}) или 0 для отмены: " choice
    if [[ "$choice" == "0" ]]; then msg "Выбор отменен."; return 0; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#servers[@]} ]; then error "Некорректный выбор."; return 1; fi

    local selected_id="${servers[$choice-1]}"
    if [ "$selected_id" == "$ACTIVE_SERVER_ID" ]; then msg "Сервер '$selected_id' уже является активным."; return 0; fi

    # Загружаем конфигурацию выбранного сервера
    if ! load_server_config "$selected_id"; then
        error "Не удалось загрузить конфигурацию для ID $selected_id"
        return 1
    fi
    # load_server_config уже выводит сообщение об активации
    return 0
}

# Групповые операции с серверами
manage_all_servers() {
    msg "--- Управление всеми серверами ---"
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then error "Файл конфигурации '$SERVERS_CONFIG_FILE' не найден."; return 1; fi
    local server_count=$(grep -v '^#' "$SERVERS_CONFIG_FILE" | wc -l)
    if [ "$server_count" -eq 0 ]; then error "Нет зарегистрированных серверов в '$SERVERS_CONFIG_FILE'."; return 1; fi

    echo "1. Запустить все"; echo "2. Остановить все"; echo "3. Перезапустить все"; echo "4. Бэкап всех"; echo "5. Статус всех"; echo "0. Назад"
    local choice; read -p "Выберите операцию (0-5): " choice

    local original_active_id=$ACTIVE_SERVER_ID # Сохраняем текущий активный ID

    case $choice in
        1|2|3|4) # Операции, требующие перебора
            local action verb past_verb
            case $choice in
                 1) action="start"; verb="Запуск"; past_verb="запущен"; ;;
                 2) action="stop"; verb="Остановка"; past_verb="остановлен"; ;;
                 3) action="restart"; verb="Перезапуск"; past_verb="перезапущен"; ;;
                 4) action="backup"; verb="Бэкап"; past_verb="создан"; ;;
            esac
            msg "$verb всех серверов..."
            local success_count=0 error_count=0
            while IFS=: read -r id name port dir service; do
                 # Пропускаем комментарии и пустые строки
                [[ -z "$id" || "$id" =~ ^# ]] && continue
                msg "$verb сервера '$name' (ID: $id)..."
                # Временно делаем сервер активным для выполнения действия
                if ! load_server_config "$id"; then
                    warning "Не удалось загрузить конфиг для '$name'. Пропуск."
                    ((error_count++))
                    continue
                fi

                # Выполняем действие
                local operation_success=false
                if [[ "$action" == "backup" ]]; then
                    if create_backup; then operation_success=true; fi
                else
                    if sudo systemctl "$action" "$service"; then operation_success=true; msg "Сервер '$name' $past_verb."; else warning "Не удалось выполнить '$action' для '$name'."; fi
                    # Небольшая пауза между операциями systemctl
                    if [[ "$action" != "stop" ]]; then sleep 1; fi
                fi

                if $operation_success; then ((success_count++)); else ((error_count++)); fi

            done < "$SERVERS_CONFIG_FILE"
            msg "Операция '$verb всех' завершена. Успешно: $success_count, Ошибки: $error_count."
            ;;
        5) # Статус
            msg "Статус всех серверов:"
            local format_string=" %-25s | %-10s | %-5s | %-10s | %s\n"
            printf "$format_string" "Название" "ID" "Порт" "Статус" "Директория"
            echo "---------------------------+------------+-------+------------+-----------------------------"
            local running_count=0 stopped_count=0
            while IFS=: read -r id name port dir service; do
                 # Пропускаем комментарии и пустые строки
                [[ -z "$id" || "$id" =~ ^# ]] && continue
                local status="остановлен"
                if sudo systemctl is-active --quiet "$service"; then status="АКТИВЕН ✅"; ((running_count++)); else ((stopped_count++)); fi
                printf "$format_string" "$name" "$id" "$port" "$status" "$dir"
            done < "$SERVERS_CONFIG_FILE"
             echo "---------------------------+------------+-------+------------+-----------------------------"
            msg "Всего: $server_count | Запущено: $running_count | Остановлено: $stopped_count"
            ;;
        0) ;; # Назад
        *) msg "Неверная опция." ;;
    esac

    # Восстанавливаем исходный активный сервер, если он был и все еще существует
    if [ -n "$original_active_id" ]; then
        if grep -q "^${original_active_id}:" "$SERVERS_CONFIG_FILE"; then
             load_server_config "$original_active_id"
        else
            # Если исходный сервер был удален, сбрасываем активный
             msg "Исходный активный сервер (ID: $original_active_id) больше не существует."
             ACTIVE_SERVER_ID=""
        fi
    fi
    return 0
}

# Подменю управления активным сервером
active_server_menu() {
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; return 1; fi
    while true; do
        local display_name=$(get_property "server-name" "$DEFAULT_INSTALL_DIR/server.properties" "$ACTIVE_SERVER_ID")
        echo ""; echo "--- Управление Активным Сервером (ID: $ACTIVE_SERVER_ID, Имя: $display_name) ---"
        echo "1. Состояние / Запуск / Остановка"
        echo "2. Настройки сервера (server.properties)"
        echo "3. Управление игроками (Whitelist/OP)"
        echo "4. Резервные копии"
        echo "5. Обновление сервера"
        echo "6. Изменить ID сервера"
        echo "7. Изменить имя сервера (в игре)"
        echo "0. Назад"
        
        local choice; read -p "Опция: " choice
        case $choice in
            1) 
                 # Подменю статуса/запуска (бывшее 4)
                 while true; do
                     local current_status="остановлен"
                     if sudo systemctl is-active --quiet "$SERVICE_NAME"; then current_status="АКТИВЕН ✅"; fi
                     echo ""; echo "--- Состояние Сервера ($current_status) ---"
                     echo "1. Запустить"; echo "2. Остановить"; echo "3. Перезапустить"; echo "4. Логи"; echo "0. Назад"
                     local mgmt_choice; read -p "Опция: " mgmt_choice
                 case $mgmt_choice in
                     1) start_server ;; 2) stop_server ;; 3) restart_server ;; 4) check_status ;; 0) break ;; *) msg "Неверно.";;
                 esac
                 if [[ "$mgmt_choice" != "0" ]]; then read -p "Нажмите Enter для продолжения..." DUMMY; fi
                 done
                 ;;
            2) configure_menu ;;
            3) players_menu ;;
            4) full_backup_menu ;;
            5) 
                while true; do
                     echo ""; echo "--- Обновление Сервера ---"
                     echo "1. Автоматическое обновление (Онлайн)"
                     echo "2. Настроить автообновление по расписанию"
                     echo "3. Ручное обновление (.zip)"
                     echo "0. Назад"
                     local u_choice; read -p "Опция: " u_choice
                     case $u_choice in
                         1) auto_update_server; read -p "Нажмите Enter..." DUMMY ;;
                         2) setup_auto_update ;; 
                         3) manual_update_server; read -p "Нажмите Enter..." DUMMY ;; 
                         0) break ;; 
                         *) msg "Неверно."; read -p "Нажмите Enter..." DUMMY ;;
                     esac
                     # Пауза теперь внутри case для нужных опций
                     # if [[ "$u_choice" != "0" ]]; then read -p "Нажмите Enter..." DUMMY; fi
                done
                ;;
            6) rename_server_id ;;
            7) rename_server_display_name ;;
            0) return 0 ;;
            *) msg "Неверно." ;;
        esac
    done
}

# Подменю системных инструментов
system_tools_menu() {
    while true; do
        echo ""; echo "--- Системные Инструменты ---"
        echo "1. Миграция: Создать архив всех серверов"
        echo "2. Миграция: Восстановить из архива"
        echo "3. Диагностика сети"
        echo "4. ОПАСНАЯ ЗОНА: Удалить ВСЕ серверы"
        echo "0. Назад"
        
        local choice; read -p "Опция: " choice
        case $choice in
            1) create_migration_archive ;;
            2) restore_from_migration_archive ;;
            3) troubleshoot_server ;;
            4) wipe_all_servers ;;
            0) return 0 ;;
            *) msg "Неверно." ;;
        esac
        # Убираем паузу для пункта 0
        if [[ "$choice" != "0" ]]; then read -p "Нажмите Enter..." DUMMY; fi
    done
}

# Подменю выбора сервера (Главный пункт 1)
server_selection_menu() {
    while true; do
        echo ""; echo "--- Управление Списком Серверов ---"
        echo "1. Создать НОВЫЙ сервер"
        echo "2. Выбрать активный сервер (из списка)"
        echo "3. Удалить сервер"
        echo "0. Назад"
        
        local choice; read -p "Опция: " choice
        case $choice in
            1) create_new_server ;;
            2) select_active_server ;;
            3) 
                if [ -z "$ACTIVE_SERVER_ID" ]; then
                    warning "Сначала выберите сервер (пункт 2), который хотите удалить."
                else
                    delete_server
                fi
                ;;
            0) return 0 ;;
            *) msg "Неверно." ;;
        esac
        # Убираем паузу для пункта 0
        if [[ "$choice" != "0" ]]; then read -p "Нажмите Enter..." DUMMY; fi
    done
}

# Подменю мультисерверного режима (точка входа)
multiserver_menu() {
    _multiserver_menu_impl # Вызываем реализацию
}

# Реализация меню мультисерверного режима
multiserver_menu() {
    _multiserver_menu_impl # Вызываем реализацию
}

# Реализация меню мультисерверного режима
_multiserver_menu_impl() {
    while true; do
        # Динамически получаем имя активного сервера
        local active_server_display="не выбран"
        if [ -n "$ACTIVE_SERVER_ID" ]; then
             local name_temp=$(grep "^${ACTIVE_SERVER_ID}:" "$SERVERS_CONFIG_FILE" 2>/dev/null | cut -d':' -f2)
             active_server_display=${name_temp:-$ACTIVE_SERVER_ID} # Используем ID если имя не найдено
             active_server_display="$active_server_display (ID: $ACTIVE_SERVER_ID)"
        fi

        echo ""; echo "--- Меню Управления Серверами ---" # Переименовали меню
        echo " Активный сервер: $active_server_display"
        echo "-----------------------------------"
        echo "1. Проверить/Обновить конфигурацию мультисервера" # Переименовали опцию
        echo "2. Выбрать активный сервер"
        echo "3. Создать новый сервер"
        echo "4. Удалить сервер из конфигурации" # Уточнили
        echo "5. Управление всеми серверами (групповые операции)"
        echo "0. Назад в главное меню"
        echo "-----------------------------------"
        local choice; read -p "Выберите опцию: " choice
        case $choice in
            1) init_multiserver ;; # Оставили вызов init, он безопасен для повторного запуска
            2) select_active_server ;;
            3) create_new_server ;;
            4) # Вызов функции удаления (она запросит выбор)
                 _delete_server_from_menu # Новая вспомогательная функция
                 ;;
            5) manage_all_servers ;;
            0) return 0 ;; # Выход из подменю
            *) msg "Неверная опция." ;;
        esac
         # Пауза перед повторным показом меню подраздела, если не вышли
        if [[ "$choice" != "0" ]]; then
             read -p "Нажмите Enter для возврата в меню управления серверами..." DUMMY_VAR
        fi
    done
}

# Вспомогательная функция для удаления сервера из подменю (чтобы не удалять активный по умолчанию)
_delete_server_from_menu() {
     msg "--- Удаление сервера из конфигурации ---"
     if [ ! -f "$SERVERS_CONFIG_FILE" ]; then error "Файл конфигурации '$SERVERS_CONFIG_FILE' не найден."; return 1; fi
     local server_count=$(grep -v '^#' "$SERVERS_CONFIG_FILE" | wc -l)
     if [ "$server_count" -eq 0 ]; then error "Нет зарегистрированных серверов для удаления."; return 1; fi

     local servers=(); local server_names=(); local i=1
     msg "Список серверов для удаления:"
     while IFS=: read -r id name port dir service; do
         [[ -z "$id" || "$id" =~ ^# ]] && continue
         servers+=("$id"); server_names+=("$name")
         printf " %2d. %-25s (ID: %s)\n" $i "$name" "$id"
         ((i++))
     done < "$SERVERS_CONFIG_FILE"

     local choice; read -p "Выберите номер сервера для удаления (1-${#servers[@]}) или 0 для отмены: " choice
     if [[ "$choice" == "0" ]]; then msg "Удаление отменено."; return 0; fi
     if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#servers[@]} ]; then error "Некорректный выбор."; return 1; fi

     local selected_id="${servers[$choice-1]}"
     local selected_name="${server_names[$choice-1]}"

     # Делаем выбранный сервер временно активным для вызова delete_server
     local original_active_id=$ACTIVE_SERVER_ID
     if ! load_server_config "$selected_id"; then
         error "Не удалось загрузить конфигурацию сервера '$selected_name' для удаления."
         # Возвращаем исходный активный сервер, если он был
         if [ -n "$original_active_id" ]; then load_server_config "$original_active_id"; fi
         return 1
     fi

     # Вызываем основную функцию удаления (она запросит подтверждение и бэкап)
     if delete_server; then
         msg "Сервер '$selected_name' успешно удален."
     else
         msg "Удаление сервера '$selected_name' было отменено или завершилось с ошибкой."
         # Возвращаем исходный активный сервер, т.к. delete_server сбросил его
         if [ -n "$original_active_id" ]; then
              if grep -q "^${original_active_id}:" "$SERVERS_CONFIG_FILE"; then # Проверяем, не был ли он удален
                   load_server_config "$original_active_id"
              fi
         fi
     fi
     # Активный сервер уже восстановлен (или сброшен) внутри delete_server
     return 0
}


# --- Вспомогательные функции ---

# Показ адреса активного сервера для подключения
show_server_address() {
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; return 1; fi
    msg "--- Адрес активного сервера (ID: $ACTIVE_SERVER_ID) для подключения ---"
    local LOCAL_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d / -f 1 | head -n 1)
    # Увеличим таймаут для curl
    local PUBLIC_IP=$(curl -s -4 --max-time 10 https://api.ipify.org || curl -s -4 --max-time 10 https://ifconfig.me || echo "Не определен")

    echo
    if [[ "$PUBLIC_IP" == "Не определен" ]]; then
        warning "Не удалось автоматически определить публичный IP-адрес."
        if [ -n "$LOCAL_IP" ]; then msg "==> Локальный IP (для вашей сети): $LOCAL_IP"; fi
    else
        msg "==> Публичный IP (для интернета): $PUBLIC_IP"
    fi
    if [ -n "$LOCAL_IP" ]; then msg "==> Локальный IP (для вашей сети): $LOCAL_IP"; fi
    # Используем текущий SERVER_PORT активного сервера
    msg "==> Порт сервера: $SERVER_PORT (UDP)"
    echo
    return 0
}

# --- Функции Миграции ---

# Создание архива для миграции всех серверов
create_migration_archive() {
    msg "--- Создание Архива Миграции ---"
    check_root # Нужны права для чтения всего

    # Проверяем, что конфиг существует и не пуст
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then error "Файл конфигурации '$SERVERS_CONFIG_FILE' не найден."; return 1; fi
    local server_count=$(grep -vE '^#|^$' "$SERVERS_CONFIG_FILE" | wc -l) # Считаем непустые строки без #
    if [ "$server_count" -eq 0 ]; then error "В конфигурации '$SERVERS_CONFIG_FILE' нет зарегистрированных серверов для архивации."; return 1; fi

    local archive_filename="minecraft_migration_$(date +%Y%m%d_%H%M%S).zip"
    local default_archive_path="/tmp/$archive_filename"
    local archive_path

    read -p "Введите путь для сохранения архива миграции [$default_archive_path]: " archive_path
    archive_path=${archive_path:-$default_archive_path}

    # Получаем директорию из пути
    local archive_dir=$(dirname "$archive_path")
    # Проверяем существование и права на запись
    if ! sudo test -d "$archive_dir" || ! sudo test -w "$archive_dir"; then
         error "Директория '$archive_dir' не существует или нет прав на запись."
         return 1
    fi

    msg "Будут заархивированы:"
    msg " - Данные серверов из: $SERVERS_BASE_DIR"
    msg " - Конфигурация из:   $SERVERS_CONFIG_DIR"
    msg "В архив: $archive_path"
    read -p "Продолжить создание архива? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then msg "Создание архива отменено."; return 1; fi

    # Проверяем наличие zip
    if ! command -v zip &> /dev/null; then
        warning "Команда 'zip' не найдена. Попытка установить..."
        if ! sudo apt-get update -y > /dev/null 2>&1 || ! sudo apt-get install -y zip > /dev/null 2>&1; then
            error "Не удалось установить 'zip'. Установите вручную: sudo apt install zip"; return 1
        fi
    fi

    msg "Создание архива... Это может занять некоторое время."
    # Архивируем базовые директории целиком
    # Важно: переходим в корень (/), чтобы сохранить пути от корня в архиве
    # Используем sudo для zip, так как читаем системные папки
    if (cd / && sudo zip -qr "$archive_path" "${SERVERS_BASE_DIR#/}" "${SERVERS_CONFIG_DIR#/}" -x "*.DS_Store" -x "__MACOSX*"); then
        local archive_size=$(sudo du -sh "$archive_path" | cut -f1)
        msg "✅ Архив миграции успешно создан: $archive_path ($archive_size)"
        msg "Теперь скопируйте этот файл на новый сервер (например, с помощью scp или FileZilla)."
        msg "Затем запустите этот скрипт на новом сервере и выберите опцию 'Восстановить из Архива Миграции'."
    else
        error "Не удалось создать архив миграции. Проверьте права доступа и свободное место."
        return 1 # Возвращаем ошибку
    fi
    return 0 # Возвращаем успех
}

# Восстановление серверов из архива миграции
restore_from_migration_archive() {
    msg "--- Восстановление из Архива Миграции ---"
    check_root # Нужны права для всего

    local archive_path
    read -p "Введите ПОЛНЫЙ путь к архиву миграции (e.g., /tmp/minecraft_migration_archive.zip): " archive_path

    if [ -z "$archive_path" ] || [ ! -f "$archive_path" ]; then
        error "Файл архива '$archive_path' не найден или путь не указан."
        return 1
    fi

    warning "ВНИМАНИЕ! Восстановление перезапишет существующие файлы серверов"
    warning "в директориях '$SERVERS_BASE_DIR' и '$SERVERS_CONFIG_DIR', если они существуют!"
    read -p "Вы уверены, что хотите продолжить восстановление? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then msg "Восстановление отменено."; return 1; fi

    # Шаг 1: Установка базовых зависимостей и пользователя
    msg "Установка необходимых пакетов..."
    install_dependencies # Эта функция уже содержит exit при ошибке
    msg "Создание пользователя '$SERVER_USER' (если не существует)..."
    create_server_user # Эта функция уже содержит exit при ошибке

    # Шаг 2: Создание базовых директорий (на случай, если их нет)
    msg "Создание базовых директорий..."
    sudo mkdir -p "$SERVERS_BASE_DIR"
    sudo mkdir -p "$SERVERS_CONFIG_DIR"
    # Устанавливаем владельца базовых папок (на случай, если создали только что)
    sudo chown "$SERVER_USER":"$SERVER_USER" "$SERVERS_BASE_DIR"
    # Конфиги обычно читает root, так что оставляем владельца root

    # Шаг 3: Распаковка архива
    # Проверяем наличие unzip
    if ! command -v unzip &> /dev/null; then
        warning "Команда 'unzip' не найдена. Попытка установить..."
        if ! sudo apt-get update -y > /dev/null 2>&1 || ! sudo apt-get install -y unzip > /dev/null 2>&1; then
            error "Не удалось установить 'unzip'. Установите вручную: sudo apt install unzip"; return 1
        fi
    fi

    msg "Распаковка архива '$archive_path' в корень системы (/)..."
    # Распаковываем в корень, флаг -o перезаписывает файлы без запроса
    if sudo unzip -oq "$archive_path" -d /; then
        msg "Архив успешно распакован."
    else
        error "Не удалось распаковать архив. Проверьте целостность файла или права."; return 1
    fi

    # Шаг 4: Проверка наличия файла конфигурации
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then
        error "Файл конфигурации '$SERVERS_CONFIG_FILE' не найден после распаковки. Архив поврежден или некорректен."; return 1
    fi
    msg "Конфигурационный файл '$SERVERS_CONFIG_FILE' найден."

    # Шаг 5: Настройка каждого сервера из конфига
    msg "Настройка восстановленных серверов..."
    local restored_count=0
    local error_count=0
    local first_restored_id="" # Запомним ID первого сервера

    # Читаем восстановленный конфиг
    while IFS=: read -r id name port dir service; do
        # Пропускаем пустые строки или комментарии
        [[ -z "$id" || "$id" =~ ^# ]] && continue

        msg "--- Настройка сервера '$name' (ID: $id) ---"

        # Проверяем существование директории сервера
        if [ ! -d "$dir" ]; then
            warning "Директория '$dir' для сервера '$name' не найдена после распаковки. Пропуск."
            ((error_count++))
            continue
        fi

        # Проверяем наличие исполняемого файла
        if [ ! -f "$dir/bedrock_server" ]; then
             warning "Исполняемый файл '$dir/bedrock_server' не найден. Сервер не сможет запуститься! Убедитесь, что архив содержал его."
             # Не прерываем, но предупреждаем
        fi

        # Установка владельца
        msg "Установка владельца для '$dir'..."
        if ! sudo chown -R "$SERVER_USER":"$SERVER_USER" "$dir"; then
            warning "Не удалось установить владельца для '$dir'. Пропуск настройки сервиса."
            ((error_count++))
            continue
        fi

        # Установка прав на исполнение
        if [ -f "$dir/bedrock_server" ]; then
            msg "Установка прав на исполнение для '$dir/bedrock_server'..."
            if ! sudo chmod +x "$dir/bedrock_server"; then
                warning "Не удалось установить права на исполнение."
                # Не критично для создания сервиса, но сервер не запустится
            fi
        fi

        # Создание systemd сервиса
        msg "Создание/Обновление сервиса '$service'..."
        # Вызываем функцию, она сама сделает daemon-reload и enable
        if create_systemd_service "$dir" "$service"; then
             msg "Сервис '$service' успешно настроен."
        else
             warning "Не удалось создать сервис '$service'."
             ((error_count++))
             continue # Не можем открыть порт без сервиса
        fi

        # Открытие порта
        msg "Открытие порта $port/udp..."
        open_firewall_port "$port" # Эта функция уже обрабатывает ошибки внутри

        msg "Сервер '$name' (ID: $id) успешно настроен."
        ((restored_count++))
        # Запоминаем ID первого успешно настроенного сервера
        if [ -z "$first_restored_id" ]; then
            first_restored_id="$id"
        fi

    done < "$SERVERS_CONFIG_FILE" # Читаем из восстановленного файла

    # Шаг 6: Завершение
    if [ "$restored_count" -gt 0 ]; then
        msg "✅ Восстановление завершено! Настроено серверов: $restored_count."
        if [ "$error_count" -gt 0 ]; then
            warning "Во время настройки возникло ошибок: $error_count. Проверьте вывод выше."
        fi
        # Устанавливаем флаг мультисервера и загружаем конфиг первого сервера
        MULTISERVER_ENABLED=true # Устанавливаем флаг (хотя он уже должен быть true)
        if [ -n "$first_restored_id" ]; then
            msg "Загрузка конфигурации первого восстановленного сервера ($first_restored_id) как активного..."
            if ! load_server_config "$first_restored_id"; then
                  msg "Попытка запуска активного сервера '$first_restored_id'..."
                if start_server; then # start_server использует глобальные переменные активного сервера
                    msg "Сервер '$first_restored_id' успешно запущен."
                else
                    warning "Не удалось автоматически запустить сервер '$first_restored_id'."
                    warning "Попробуйте запустить его вручную через опцию 4 главного меню."
                fi
            else
                 warning "Не удалось автоматически активировать сервер '$first_restored_id'."
            fi
        fi
        msg "Вы можете управлять восстановленными серверами через главное меню."
    else
        if [ "$error_count" -gt 0 ]; then
             error "Не удалось настроить ни одного сервера из конфигурационного файла из-за ошибок."
        else
             error "Конфигурационный файл '$SERVERS_CONFIG_FILE' пуст или не содержит корректных записей."
        fi
        return 1
    fi

    return 0
}

# Функция для ПОЛНОГО удаления ВСЕХ серверов и данных
wipe_all_servers() {
    msg "--- ПОЛНОЕ УДАЛЕНИЕ ВСЕХ СЕРВЕРОВ И ДАННЫХ ---"
    check_root # Требует root

    # Проверяем, существует ли вообще конфигурация
    if [ ! -f "$SERVERS_CONFIG_FILE" ]; then
        warning "Файл конфигурации '$SERVERS_CONFIG_FILE' не найден."
        warning "Возможно, нет серверов, управляемых этим скриптом."
        # Спросим, нужно ли удалять базовые папки и пользователя, если они есть
    fi

    warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    warning "ВНИМАНИЕ! Это действие ПОЛНОСТЬЮ УДАЛИТ:"
    warning " - ВСЕ серверы из директории '$SERVERS_BASE_DIR'"
    warning " - ВСЮ конфигурацию мультисервера из '$SERVERS_CONFIG_DIR'"
    warning " - ВСЕ systemd сервисы, связанные с этими серверами"
    warning "Это действие НЕОБРАТИМО и приведет к ПОТЕРЕ ВСЕХ МИРОВ И НАСТРОЕК!"
    warning "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

    read -p "Вы ПОНИМАЕТЕ риски и хотите продолжить? (Введите 'YES' заглавными буквами): " CONFIRM1
    if [[ "$CONFIRM1" != "YES" ]]; then
        msg "Полное удаление отменено."
        return 1
    fi

    # Второе подтверждение
    read -p "ПОСЛЕДНЕЕ ПРЕДУПРЕЖДЕНИЕ! Вы точно уверены? (Введите 'DELETE ALL' заглавными буквами): " CONFIRM2
    if [[ "$CONFIRM2" != "DELETE ALL" ]]; then
        msg "Полное удаление отменено."
        return 1
    fi

    msg "Начинается необратимое удаление..."

    # 1. Остановить, отключить, удалить все сервисы и закрыть порты из конфига
    if [ -f "$SERVERS_CONFIG_FILE" ]; then
        msg "Обработка серверов из '$SERVERS_CONFIG_FILE'..."
        local processed_ports=() # Массив для отслеживания уже обработанных портов
        while IFS=: read -r id name port dir service; do
            # Пропускаем комментарии и пустые строки
            [[ -z "$id" || "$id" =~ ^# ]] && continue

            msg "--- Удаление сервиса и порта для '$name' (ID: $id) ---"
            local service_file="/etc/systemd/system/$service"

            # Останавливаем сервис
            msg "Остановка сервиса '$service'..."
            sudo systemctl stop "$service" &>/dev/null # Игнорируем ошибки, если не запущен

            # Отключаем автозапуск
            msg "Отключение автозапуска '$service'..."
            sudo systemctl disable "$service" &>/dev/null # Игнорируем ошибки

            # Удаляем файл сервиса
            if [ -f "$service_file" ]; then
                msg "Удаление файла '$service_file'..."
                if ! sudo rm -f "$service_file"; then
                    warning "Не удалось удалить файл сервиса '$service_file'."
                fi
            else
                 msg "Файл сервиса '$service_file' не найден."
            fi

            # Закрываем порт (если еще не закрывали для этого номера)
            local port_processed=false
            for processed_port in "${processed_ports[@]}"; do
                if [[ "$processed_port" == "$port" ]]; then
                    port_processed=true
                    break
                fi
            done
            if ! $port_processed && [ -n "$port" ]; then
                 close_firewall_port "$port" # Эта функция выводит свои сообщения
                 processed_ports+=("$port") # Добавляем порт в список обработанных
            fi

        done < "$SERVERS_CONFIG_FILE"

        # Перезагружаем systemd после удаления всех файлов
        msg "Перезагрузка конфигурации systemd..."
        sudo systemctl daemon-reload || warning "Не удалось перезагрузить systemd."
    else
         msg "Конфигурационный файл не найден, пропускаем удаление сервисов и портов."
    fi

    # 2. Удаляем базовую директорию серверов
    if [ -d "$SERVERS_BASE_DIR" ]; then
        msg "Удаление директории данных серверов '$SERVERS_BASE_DIR'..."
        if ! sudo rm -rf "$SERVERS_BASE_DIR"; then
            error "Не удалось удалить '$SERVERS_BASE_DIR'."
            # Не прерываем, пытаемся удалить остальное
        else
            msg "Директория '$SERVERS_BASE_DIR' удалена."
        fi
    else
        msg "Директория '$SERVERS_BASE_DIR' не найдена."
    fi

    # 3. Удаляем директорию конфигурации
    if [ -d "$SERVERS_CONFIG_DIR" ]; then
        msg "Удаление директории конфигурации '$SERVERS_CONFIG_DIR'..."
        if ! sudo rm -rf "$SERVERS_CONFIG_DIR"; then
            error "Не удалось удалить '$SERVERS_CONFIG_DIR'."
        else
             msg "Директория '$SERVERS_CONFIG_DIR' удалена."
        fi
    else
        msg "Директория '$SERVERS_CONFIG_DIR' не найдена."
    fi

    # 4. Сброс активных переменных
    ACTIVE_SERVER_ID=""; DEFAULT_INSTALL_DIR=""; SERVICE_NAME=""; SERVER_PORT=""; SERVICE_FILE=""
    msg "Переменные активного сервера сброшены."

    # 5. Опциональное удаление пользователя minecraft
    if id "$SERVER_USER" &>/dev/null; then
        read -p "Удалить системного пользователя '$SERVER_USER'? (yes/no): " DEL_USER_CONFIRM
        if [[ "$DEL_USER_CONFIRM" == "yes" ]]; then
            msg "Удаление пользователя '$SERVER_USER'..."
            # Пытаемся убить процессы пользователя на всякий случай
            sudo pkill -u "$SERVER_USER"
            sleep 1
            if sudo userdel -r "$SERVER_USER"; then # -r удаляет и домашнюю директорию, если есть
                msg "Пользователь '$SERVER_USER' удален."
            else
                warning "Не удалось удалить пользователя '$SERVER_USER'."
            fi
        fi
    fi

    # 6. Опциональное удаление директории бэкапов
    if [ -d "$BACKUP_DIR" ]; then
         read -p "Удалить директорию резервных копий '$BACKUP_DIR'? (yes/no): " DEL_BACKUP_CONFIRM
         if [[ "$DEL_BACKUP_CONFIRM" == "yes" ]]; then
              msg "Удаление директории бэкапов '$BACKUP_DIR'..."
              if ! sudo rm -rf "$BACKUP_DIR"; then
                   warning "Не удалось удалить '$BACKUP_DIR'."
              else
                   msg "Директория бэкапов удалена."
              fi
         fi
    fi

    msg "✅ Процесс полного удаления завершен."
    msg "Все серверы, управляемые этим скриптом, их данные и конфигурация были удалены."
    return 0
}

# Настройка автоматического резервного копирования (cron)
setup_auto_backup() {
    msg "--- Настройка Автоматического Бэкапа ---"
    msg "Эта функция добавит задание в cron для запуска этого скрипта с флагом --auto-backup."
    msg "Бэкапы будут создаваться для ВСЕХ серверов."

    # URL скрипта на GitHub (всегда актуальная версия)
    local script_url="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/minecraft_bedrock.sh"
    local cron_marker="minecraft_autobackup_all"

    # Проверяем, есть ли уже задание (ищем по маркеру)
    local current_cron=$(sudo crontab -l 2>/dev/null)
    if echo "$current_cron" | grep -Fq "$cron_marker"; then
        msg "Автобэкап уже настроен."
        read -p "Хотите удалить или изменить расписание? (delete/change/cancel): " ACTION
        if [[ "$ACTION" == "delete" ]]; then
            # Удаляем строку по маркеру
            echo "$current_cron" | grep -Fv "$cron_marker" | sudo crontab -
            msg "Автобэкап отключен."
            return 0
        elif [[ "$ACTION" != "change" ]]; then
            return 0
        fi
    fi

    echo "Выберите частоту бэкапов:"
    echo "1. Ежедневно в 04:00"
    echo "2. Каждые 12 часов (04:00 и 16:00)"
    echo "3. Каждый час (в 00 минут)"
    echo "4. Ввести свое выражение cron"
    read -p "Ваш выбор: " choice

    local cron_schedule=""
    case $choice in
        1) cron_schedule="0 4 * * *" ;;
        2) cron_schedule="0 4,16 * * *" ;;
        3) cron_schedule="0 * * * *" ;;
        4) read -p "Введите выражение cron (например, '30 2 * * *'): " cron_schedule ;;
        *) msg "Неверный выбор."; return 1 ;;
    esac

    if [ -z "$cron_schedule" ]; then error "Пустое расписание."; return 1; fi

    # Формируем новую задачу с использованием curl
    # Новые записи добавляются в начало лога (свежее сверху)
    local log_file="/var/log/minecraft_backup.log"
    local new_job="$cron_schedule tmp=\$(mktemp); curl -Ls $script_url | bash -s -- --auto-backup > \$tmp 2>&1; { cat \$tmp; cat $log_file 2>/dev/null; } > ${log_file}.new && mv ${log_file}.new $log_file; rm -f \$tmp # $cron_marker"

    # Удаляем старую задачу (если была) и добавляем новую
    local temp_cron=$(mktemp)
    sudo crontab -l 2>/dev/null | grep -Fv "$cron_marker" > "$temp_cron"
    echo "$new_job" >> "$temp_cron"
    
    if sudo crontab "$temp_cron"; then
        msg "✅ Автобэкап успешно настроен: $cron_schedule"
        msg "Скрипт будет скачиваться с GitHub при каждом запуске."
        msg "Логи будут писаться в /var/log/minecraft_backup.log"
    else
        error "Не удалось обновить crontab."
    fi
    rm -f "$temp_cron"
}

# Диагностика проблем с подключением
troubleshoot_server() {
    msg "--- Диагностика проблем с подключением ---"
    if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; return 1; fi

    msg "1. Проверка статуса сервиса..."
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        msg "✅ Сервис '$SERVICE_NAME' активен (running)."
    else
        warning "❌ Сервис '$SERVICE_NAME' НЕ активен."
        sudo systemctl status "$SERVICE_NAME" --no-pager
    fi

    msg "2. Проверка прослушивания порта $SERVER_PORT..."
    # Пытаемся найти PID процесса, занимающего порт
    local busy_pid=""
    if command -v ss &>/dev/null; then
        busy_pid=$(sudo ss -ulnp | grep ":$SERVER_PORT " | grep -o 'pid=[0-9]*' | cut -d'=' -f2 | head -n 1)
    elif command -v lsof &>/dev/null; then
        busy_pid=$(sudo lsof -i UDP:$SERVER_PORT -t | head -n 1)
    fi

    if [ -n "$busy_pid" ]; then
        local proc_name=$(ps -p "$busy_pid" -o comm=)
        warning "⚠️ Порт $SERVER_PORT занят процессом '$proc_name' (PID: $busy_pid)."
        msg "Это нормально, если сервер работает. Но если сервер не запускается, этот процесс нужно убить."
        read -p "Убить процесс $busy_pid ($proc_name)? (yes/no): " KILL_PROC
        if [[ "$KILL_PROC" == "yes" ]]; then
            sudo kill -9 "$busy_pid"
            msg "✅ Процесс убит. Порт должен быть свободен."
        fi
    else
        msg "✅ Порт $SERVER_PORT свободен (никто не слушает)."
    fi

    msg "3. Проверка фаервола UFW..."
    if sudo ufw status | grep -q "Status: active"; then
        msg "✅ UFW активен."
        if sudo ufw status | grep "$SERVER_PORT/udp" | grep -q "ALLOW"; then
             msg "✅ Правило для порта $SERVER_PORT/udp найдено (ALLOW)."
        else
             warning "❌ Правило для порта $SERVER_PORT/udp НЕ найдено!"
             read -p "Попробовать добавить правило снова? (yes/no): " FIX_UFW
             if [[ "$FIX_UFW" == "yes" ]]; then
                 open_firewall_port "$SERVER_PORT"
             fi
        fi
    else
        warning "⚠️ UFW не активен. Фаервол выключен (все порты открыты, если нет другого фаервола)."
    fi

    msg "4. Проверка server.properties..."
    local props="$DEFAULT_INSTALL_DIR/server.properties"
    if [ -f "$props" ]; then
        local bind_ip=$(get_property "server-ip" "$props" "")
        if [ -n "$bind_ip" ]; then
            warning "⚠️ В server.properties установлен server-ip=$bind_ip."
            warning "Если этот IP не принадлежит этому серверу, он не запустится или не будет доступен."
            read -p "Очистить server-ip (рекомендуется)? (yes/no): " FIX_IP
            if [[ "$FIX_IP" == "yes" ]]; then
                set_property "server-ip" "" "$props"
                msg "server-ip очищен."
            fi
        else
            msg "✅ server-ip не задан (слушает все интерфейсы)."
        fi

        # Проверка конфликта портов v4/v6
        local current_port=$(get_property "server-port" "$props" "19132")
        local current_portv6=$(get_property "server-portv6" "$props" "19133")
        
        if [ "$current_port" == "$current_portv6" ]; then
            warning "⚠️ server-port и server-portv6 совпадают ($current_port)."
            warning "Это вызывает ошибку 'Port in use' на Linux (конфликт IPv4/IPv6)."
            read -p "Изменить server-portv6 на $((current_port + 1))? (yes/no): " FIX_V6
            if [[ "$FIX_V6" == "yes" ]]; then
                set_property "server-portv6" "$((current_port + 1))" "$props"
                msg "✅ server-portv6 изменен. Теперь сервер должен запуститься."
            fi
        fi
    else
        error "❌ Файл server.properties не найден."
    fi

    msg "5. Тестовый запуск сервера (Debug Run)..."
    msg "Попытка запустить сервер напрямую, чтобы увидеть ошибки..."
    
    # Останавливаем сервис, если он пытается перезапускаться
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null

    # Переходим в папку
    cd "$DEFAULT_INSTALL_DIR" || { error "Не удалось перейти в папку $DEFAULT_INSTALL_DIR"; return 1; }

    # Запускаем с таймаутом 5 секунд, чтобы он не висел вечно, если работает
    # Используем timeout из coreutils
    msg "Запуск ./bedrock_server (макс. 5 секунд) от имени $SERVER_USER..."
    local output
    output=$(sudo -u "$SERVER_USER" bash -c "cd '$DEFAULT_INSTALL_DIR' && LD_LIBRARY_PATH=. timeout -s 9 5s ./bedrock_server" 2>&1)
    local exit_code=$?

    echo "---------------------------------------------------"
    echo "$output"
    echo "---------------------------------------------------"

    if [ $exit_code -eq 124 ] || [ $exit_code -eq 137 ]; then
        msg "✅ Сервер запустился и работал 5 секунд (таймаут). Похоже, бинарный файл в порядке."
        msg "Проблема скорее всего в конфигурации systemd или screen."
    else
        warning "❌ Сервер завершил работу с кодом $exit_code."
        warning "Внимательно изучите вывод выше. Часто не хватает библиотек (libssl)."
    fi
    
    # Восстанавливаем права (на всякий случай)
    sudo chown -R "$SERVER_USER":"$SERVER_USER" "$DEFAULT_INSTALL_DIR"

    msg "6. Тестовый запуск через SCREEN..."
    msg "Проверяем, работает ли screen корректно..."
    
    # Пробуем запустить screen с простым sleep
    local screen_out
    screen_out=$(sudo -u "$SERVER_USER" /usr/bin/screen -DmS test_screen bash -c 'sleep 3' 2>&1)
    local screen_ret=$?
    
    if [ $screen_ret -eq 0 ]; then
        msg "✅ Screen работает корректно (тестовая команда sleep выполнена)."
    else
        warning "❌ Ошибка запуска screen! Код возврата: $screen_ret"
        echo "Вывод screen: $screen_out"
        warning "Возможно, проблема в правах доступа к /run/screen."
        
        # Пытаемся исправить права
        if [ -d "/run/screen" ]; then
             msg "Попытка исправить права на /run/screen..."
             sudo chmod 1777 /run/screen
             msg "Права исправлены. Попробуйте запустить сервер снова."
        fi
    fi

    msg "7. Полная симуляция запуска (Screen + Server)..."
    msg "Запускаем сервер через screen с логированием, чтобы понять причину падения..."
    
    local debug_log="/tmp/bds_debug.log"
    rm -f "$debug_log"
    
    # Запускаем на 5 секунд
    # Используем timeout, чтобы убить screen, если он все-таки запустится
    sudo -u "$SERVER_USER" timeout -s 9 5s /usr/bin/screen -DmS test_bds -L -Logfile "$debug_log" bash -c "cd '$DEFAULT_INSTALL_DIR' && LD_LIBRARY_PATH=. ./bedrock_server"
    
    if [ -f "$debug_log" ]; then
        msg "Лог запуска внутри screen:"
        echo "---------------------------------------------------"
        cat "$debug_log"
        echo "---------------------------------------------------"
        if grep -q "Server started" "$debug_log"; then
             msg "✅ Судя по логу, сервер запускается корректно."
        else
             warning "❌ В логе нет сообщения о старте. Изучите ошибки выше."
        fi
    else
        warning "❌ Лог файл не создан. Screen не запустился или упал мгновенно."
    fi

    msg "--- Диагностика завершена ---"
    read -p "Нажмите Enter..." DUMMY
}

# --- Обработка аргументов командной строки (для автобэкапа) ---
handle_command_args() {
    if [ "$1" == "--auto-backup" ]; then
        # ... (существующий код --auto-backup) ...
        # Используем echo для вывода в лог cron
        echo "--- Запуск автоматического резервного копирования $(date) ---"
        
        # Ротация лога если нужно
        rotate_log_if_needed "/var/log/minecraft_backup.log"
        
        # Автобэкап должен запускаться от root, поэтому check_root не нужен здесь,
        # но все команды внутри должны использовать sudo или быть выполнены от root
        # Проверка прав выполняется перед вызовом этой функции в основном коде

        # Все функции и переменные уже загружены при выполнении скрипта

        # Проверяем режим работы (всегда мультисервер)
        if [ ! -f "$SERVERS_CONFIG_FILE" ]; then
            echo "Ошибка автобэкапа: Конфигурационный файл $SERVERS_CONFIG_FILE не найден." >&2
            exit 1
        fi

        # Проверяем, есть ли серверы в конфиге
        if ! grep -qE '^[a-zA-Z0-9_]+:' "$SERVERS_CONFIG_FILE"; then
             echo "Ошибка автобэкапа: Нет серверов в конфигурации $SERVERS_CONFIG_FILE." >&2
             # Выходим с успехом, т.к. нечего бэкапить
             exit 0
        fi

        local original_active_id=$ACTIVE_SERVER_ID # Сохраняем текущий
        echo "Мультисерверный режим. Создание бэкапов для всех серверов..."
        local success_count=0 fail_count=0

        while IFS=: read -r id name port dir service; do
             # Пропускаем комментарии и пустые строки
             [[ -z "$id" || "$id" =~ ^# ]] && continue
             echo "--- Бэкап сервера '$name' (ID: $id) ---"
             # Делаем активным для create_backup (используем load_server_config)
             if load_server_config "$id"; then
                 # Вызываем create_backup (она использует глобальные переменные активного сервера)
                 if create_backup; then
                      ((success_count++))
                 else
                      echo "Ошибка при создании бэкапа для '$name' (ID: $id)." >&2
                      ((fail_count++))
                 fi
             else
                  echo "Ошибка: Не удалось загрузить конфиг для '$name' (ID: $id). Бэкап пропущен." >&2
                  ((fail_count++))
             fi
        done < "$SERVERS_CONFIG_FILE" # Читаем напрямую из файла

        echo "Автобэкап завершен. Успешно: $success_count, Ошибки: $fail_count."

        # Восстанавливаем исходный активный сервер, если он был и все еще существует
        if [ -n "$original_active_id" ]; then
            if grep -q "^${original_active_id}:" "$SERVERS_CONFIG_FILE"; then
                 load_server_config "$original_active_id"
            fi
        fi
        exit $fail_count # Выход с кодом ошибки = кол-во неудачных бэкапов
    elif [ "$1" == "--auto-update" ]; then
        local target_server_id="$2"
        echo "--- Запуск автоматического обновления $(date) ---"
        
        # Все функции и переменные уже загружены при выполнении скрипта

        if [ -z "$target_server_id" ]; then
            echo "Ошибка: Не указан ID сервера для обновления." >&2; exit 1
        fi

        # Загружаем конфиг сервера
        if load_server_config "$target_server_id"; then
            echo "Проверка обновлений для сервера $target_server_id..."
            auto_update_server "silent"
        else
            echo "Ошибка: Не удалось загрузить конфигурацию сервера $target_server_id." >&2; exit 1
        fi
        exit 0
    fi
    # Здесь можно добавить обработку других аргументов в будущем
    # Если аргумент не распознан, просто возвращаемся
    return 0
}

# Объединенное меню резервного копирования
full_backup_menu() {
    while true; do
        echo ""; echo "--- Управление Резервными Копиями ---"
        echo "1. Создать копию активного сервера (ID: ${ACTIVE_SERVER_ID:-не выбран})"
        echo "2. Восстановить активный сервер из копии"
        echo "3. Удалить резервную копию"
        echo "4. Список ВСЕХ резервных копий"
        echo "5. Настроить авто-бэкап (для всех серверов)"
        echo "0. Назад в главное меню"
        echo "-----------------------------------"
        
        local backup_choice; read -p "Выберите опцию: " backup_choice
        case $backup_choice in
            1) 
                if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; else create_backup; fi 
                ;;
            2) 
                if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; else restore_backup; fi 
                ;;
            3) 
                # delete_backup требует активного сервера для контекста или можно доработать, но пока оставим проверку
                # В текущей реализации delete_backup спрашивает какую копию удалить из списка, 
                # но список часто фильтруется. В функции delete_backup есть проверка на active server id?
                # Посмотрим... функция delete_backup требует ACTIVE_SERVER_ID.
                if [ -z "$ACTIVE_SERVER_ID" ]; then error "Активный сервер не выбран."; else delete_backup; fi
                ;;
            4) list_backups ;;
            5) setup_auto_backup ;;
            0) return 0 ;;
            *) msg "Неверно.";;
        esac
        
        # Пауза перед возвратом в меню бэкапов (кроме выхода)
        if [[ "$backup_choice" != "0" ]]; then
             read -p "Нажмите Enter для продолжения..." DUMMY_VAR
        fi
    done
}

# --- Инициализация и Главный Цикл ---

# Проверяем аргументы командной строки ПЕРЕД проверкой root для основного меню
if [ $# -gt 0 ]; then
    handle_command_args "$@"
    # Если handle_command_args завершилась с exit, скрипт дальше не пойдет
fi

# Проверяем права root для основного интерактивного меню
check_root

# --- Инициализация Мультисерверного Режима при каждом запуске ---
# Эта функция установит MULTISERVER_ENABLED=true и загрузит конфиг
# Она также предложит миграцию, если конфига нет, но есть старый сервер
init_multiserver || exit 1 # Выходим, если инициализация провалилась

# Главный цикл меню
while true; do
    SERVER_STATUS_LINE="Статус: Мультисервер (активный не выбран)"
    SERVER_ADDRESS_LINE=""

    # Получаем данные активного сервера, если он выбран
    if [ -n "$ACTIVE_SERVER_ID" ]; then
         current_v="Unknown"
         if [ -f "$DEFAULT_INSTALL_DIR/version" ]; then
             current_v=$(cat "$DEFAULT_INSTALL_DIR/version")
         fi
         
         # Получаем имя сервера из server.properties
         display_name="$ACTIVE_SERVER_ID"
         if [ -f "$DEFAULT_INSTALL_DIR/server.properties" ]; then
             display_name=$(get_property "server-name" "$DEFAULT_INSTALL_DIR/server.properties" "$ACTIVE_SERVER_ID")
         fi

         status_icon="ОСТАНОВЛЕН 🔴"
         if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
             status_icon="АКТИВЕН ✅"
         fi
         
         SERVER_STATUS_LINE="Сервер: $display_name (ID: $ACTIVE_SERVER_ID) | Версия: $current_v | $status_icon"
         
         # Попытка определить внешний IP
         # Используем внешний сервис для определения публичного IP, с таймаутом
         server_ip=$(curl -s --max-time 2 https://api.ipify.org || hostname -I | cut -d' ' -f1)
         
         if [ -z "$server_ip" ]; then server_ip="127.0.0.1"; fi
         
         SERVER_ADDRESS_LINE="Адрес: $server_ip:$SERVER_PORT"
    fi

    # Отображаем главное меню
    echo ""
    echo "=========== Minecraft Bedrock Server Manager (Мультисервер) ==========="
    echo "   $SERVER_STATUS_LINE"
    if [ -n "$SERVER_ADDRESS_LINE" ]; then
        echo "   $SERVER_ADDRESS_LINE"
    fi
    echo "======================================================================"
    echo " 1. Управление серверами (Создание / Удаление / Выбор)"
    echo " 2. Управление активным сервером (Старт, Настройки, Бэкап, Обновление)"
    echo " 3. Системные инструменты (Миграция, Диагностика, Сброс)"
    echo " 0. Выход"
    echo "======================================================================"

    # Сбрасываем choice перед запросом
    choice=""
    read -p "Выберите опцию: " choice

    # Обработка выбора
    case $choice in
        1) server_selection_menu ;;
        2) active_server_menu ;;
        3) system_tools_menu ;;
        0) msg "Выход."; exit 0 ;;
        *) msg "Неверная опция. Попробуйте снова." ;;
    esac

    # Пауза только для неверных вариантов (не 1, 2, 3, 0)
     if [[ "$choice" != "0" ]]; then
        if ! [[ "$choice" =~ ^[1-3]$ ]]; then
            read -p "Нажмите Enter для продолжения..." DUMMY_VAR
         fi
     fi

done

# Эта строка никогда не будет достигнута из-за 'exit 0' в опции 0, но для полноты
exit 0
