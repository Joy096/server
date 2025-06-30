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
    msg "Обновление списка пакетов..."
    # Подавляем вывод, проверяем код возврата
    if ! sudo apt-get update > /dev/null; then
        warning "Не удалось обновить список пакетов. Проверьте интернет-соединение."
    fi

    msg "Установка необходимых пакетов (unzip, wget, curl, libssl-dev, screen, nano, ufw, jq, zip)..."
    # Добавили zip для архива миграции
    if ! sudo apt-get install -y unzip wget curl libssl-dev screen nano ufw jq zip > /dev/null; then
        # Используем error и exit, так как без зависимостей скрипт бесполезен
        error "Не удалось установить зависимости. Установите вручную: sudo apt install unzip wget curl libssl-dev screen nano ufw jq zip"
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
}

# Создание пользователя для запуска сервера (если еще не создан)
create_server_user() {
    if id "$SERVER_USER" &>/dev/null; then
        msg "Пользователь '$SERVER_USER' уже существует."
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

    # Создаем файл сервиса
    # Используем sudo tee для записи от имени root
    if ! echo "[Unit]
Description=Minecraft Bedrock Server ($current_service_name)
After=network.target

[Service]
User=$SERVER_USER
Group=$SERVER_USER
WorkingDirectory=$current_install_dir
ExecStart=/usr/bin/screen -DmS ${screen_session_name} bash -c 'LD_LIBRARY_PATH=. ./bedrock_server'
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
    if ! is_server_installed; then
        error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен в '$DEFAULT_INSTALL_DIR'."
        return 1
    fi

    # Проверяем включен ли (аналогично start_server)
    if ! sudo systemctl is-enabled "$SERVICE_NAME" &>/dev/null ; then
        warning "Сервис '$SERVICE_NAME' не включен для автозапуска. Включаю..."
        if ! sudo systemctl enable "$SERVICE_NAME"; then
            warning "Не удалось включить автозапуск сервиса $SERVICE_NAME."
        fi
    fi

    # Перезапускаем
    msg "Перезапуск сервиса '$SERVICE_NAME'..."
    if ! sudo systemctl restart "$SERVICE_NAME"; then
        error "Не удалось перезапустить сервис '$SERVICE_NAME'. Проверьте логи."
        return 1
    fi

    msg "Команда перезапуска отправлена. Проверяем статус через 5 секунд..."
    sleep 5
    check_status # Вызываем проверку статуса после перезапуска
    return $? # Возвращаем статус проверки
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
configure_menu() {
    if ! is_server_installed; then
        error "Сервер (ID: ${ACTIVE_SERVER_ID:-N/A}) не установлен. Сначала установите его."
        return 1
    fi

    while true; do
        echo ""
        echo "--- Меню Настройки Сервера (ID: $ACTIVE_SERVER_ID) ---"
        echo "1. ⚙️ Общие (Режим игры, Сложность, Название)"
        echo "2. 📜 Дополнительно (Ключ генерации, Настройки мира)"
        echo "3. 🌐 Игра по сети (PvP, Белый список, Доступ)"
        echo "4. 🛠️ Читы (Команды, Правила игры)"
        echo "0. Назад в главное меню"
        echo "--------------------------------------------------------"

        local config_choice
        read -p "Выберите раздел для настройки: " config_choice

        case $config_choice in
            1) configure_general_settings ;;
            2) configure_advanced_settings ;;
            3) configure_network_settings ;;
            4) configure_cheats_settings ;;
            0) return 0 ;;
            *) msg "Неверная опция." ;;
        esac

        if [[ "$config_choice" != "0" ]]; then
             read -p "Нажмите Enter для возврата в меню настроек..." DUMMY_VAR
        fi
    done
}

# 1. Настройка раздела "Общие"
configure_general_settings() {
    msg "--- ⚙️ Настройка: Общие ---"
    local CONFIG_FILE="$DEFAULT_INSTALL_DIR/server.properties"
    if [ ! -f "$CONFIG_FILE" ]; then error "Файл '$CONFIG_FILE' не найден."; return 1; fi

    local key current_val new_val valid_options is_valid

    # Название мира (server-name)
    echo "" && echo "-- Название мира --"
    key="server-name"; current_val=$(get_property "$key" "$CONFIG_FILE" "Мой мир");
    read -p "Название [$current_val]: " new_val; set_property "$key" "${new_val:-$current_val}" "$CONFIG_FILE"

    # Режим игры (gamemode)
    echo "" && echo "-- Режим игры --"
    key="gamemode"; current_val=$(get_property "$key" "$CONFIG_FILE" "survival"); valid_options=("survival" "creative" "adventure");
    while true; do
        read -p "Режим (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"
        is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done
        if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi
    done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    # Уровень сложности (difficulty)
    echo "" && echo "-- Уровень сложности --"
    key="difficulty"; current_val=$(get_property "$key" "$CONFIG_FILE" "easy"); valid_options=("peaceful" "easy" "normal" "hard");
    while true; do
        read -p "Сложность (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"
        is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done
        if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi
    done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    msg "Настройки 'Общие' сохранены в $CONFIG_FILE. Требуется перезапуск сервера для применения."
    return 0
}

# 2. Настройка раздела "Дополнительно"
configure_advanced_settings() {
    msg "--- 📜 Настройка: Дополнительно ---"
    local CONFIG_FILE="$DEFAULT_INSTALL_DIR/server.properties"
    if [ ! -f "$CONFIG_FILE" ]; then error "Файл '$CONFIG_FILE' не найден."; return 1; fi

    local key current_val new_val

    # --- Часть 1: Настройки из server.properties (требуют перезапуска) ---
    echo "" && msg "--- Настройки Мира (требуют перезапуска) ---"

    # level-seed
    echo "" && echo "-- Ключ генерации мира --"
    key="level-seed"; current_val=$(get_property "$key" "$CONFIG_FILE" "");
    read -p "Ключ генерации (сид) [$current_val]: " new_val; set_property "$key" "${new_val:-$current_val}" "$CONFIG_FILE"

    # spawn-radius
    echo "" && echo "-- Радиус возрождения --"; echo "Максимальный радиус в блоках от точки возрождения мира."
    key="spawn-radius"; current_val=$(get_property "$key" "$CONFIG_FILE" "10");
    read -p "Радиус (например, 5, 10) [$current_val]: " new_val; new_val="${new_val:-$current_val}";
    if [[ "$new_val" =~ ^[0-9]+$ ]]; then set_property "$key" "$new_val" "$CONFIG_FILE"; else warning "Некорректное значение, оставлено: $current_val"; fi

    # simulation-distance
    echo "" && echo "-- Дистанция моделирования --"; echo "Расстояние, на котором мир 'живет'. Влияет на производительность."
    key="simulation-distance"; current_val=$(get_property "$key" "$CONFIG_FILE" "8");
    read -p "Дистанция (чанки, например 4, 6, 8) [$current_val]: " new_val; new_val="${new_val:-$current_val}";
    if [[ "$new_val" =~ ^[0-9]+$ ]] && [ "$new_val" -ge 4 ]; then set_property "$key" "$new_val" "$CONFIG_FILE"; else warning "Некорректное значение, оставлено: $current_val"; fi

    # --- Часть 2: Настройки Gamerules (требуют читов) ---
    echo "" && msg "--- Правила Игры (требуют читов и запущенный сервер) ---"
    local allow_cheats_enabled=$(get_property "allow-cheats" "$CONFIG_FILE" "false")

    if [[ "$allow_cheats_enabled" != "true" ]]; then
        warning "Читы выключены. Настройка правил из этого раздела невозможна."
        return 0
    fi
    # Продолжаем, только если читы включены
    # ... (код для настройки gamerules из этого раздела) ...
    # Мы перенесли все gamerules в "Читы", так что эта часть может быть пустой
    # или можно оставить самые нейтральные правила здесь.
    # Давайте оставим здесь только 'showcoordinates', а остальное в читах.

    local screen_name=${SERVICE_NAME%.service}
    local server_is_active=false
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then server_is_active=true; else warning "Сервер не запущен, правила не применить."; fi

    # Вспомогательная функция для запроса да/нет
    ask_and_set_gamerule() {
        local rule_name="$1"; local question="$2"; local choice state=""
        echo "" && echo "-- $question --"
        read -p "$question? (yes/no): " choice
        if [[ "$choice" == "yes" || "$choice" == "y" ]]; then state="true"; fi
        if [[ "$choice" == "no" || "$choice" == "n" ]]; then state="false"; fi
        if [[ -n "$state" ]]; then
            # Отправляем команду
            local rule_cmd="gamerule $rule_name $state"
            if $server_is_active; then
                if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "$rule_cmd"$'\015'; then
                    msg "Команда '$rule_cmd' отправлена."
                    sleep 1
                fi
            fi
        else warning "Ввод некорректен, пропущено."; fi
    }
    
    ask_and_set_gamerule "showcoordinates" "Показывать координаты"
    # Другие нейтральные правила можно добавить сюда

    msg "Настройка 'Дополнительно' завершена. Не забудьте перезапустить сервер для применения некоторых изменений."
    return 0
}

# 3. Настройка раздела "Игра по сети"
configure_network_settings() {
    msg "--- 🌐 Настройка: Игра по сети ---"
    local CONFIG_FILE="$DEFAULT_INSTALL_DIR/server.properties"
    if [ ! -f "$CONFIG_FILE" ]; then error "Файл '$CONFIG_FILE' не найден."; return 1; fi

    local key current_val new_val valid_options is_valid

    # max-players
    echo "" && echo "-- Максимальное количество игроков --"
    key="max-players"; current_val=$(get_property "$key" "$CONFIG_FILE" "10");
    read -p "Максимум игроков [$current_val]: " new_val; new_val="${new_val:-$current_val}";
    if [[ "$new_val" =~ ^[0-9]+$ ]] && [ "$new_val" -ge 1 ]; then set_property "$key" "$new_val" "$CONFIG_FILE"; else warning "Некорректное значение, оставлено: $current_val"; fi

    # pvp ("Огонь по своим")
    echo "" && echo "-- Огонь по своим (PvP) --"
    key="pvp"; current_val=$(get_property "$key" "$CONFIG_FILE" "true"); valid_options=("true" "false");
    while true; do read -p "Разрешить PvP? (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    # white-list
    echo "" && echo "-- Белый список --"; echo "Аналог 'Доступ игрока' для выделенного сервера."
    key="white-list"; current_val=$(get_property "$key" "$CONFIG_FILE" "false"); valid_options=("true" "false");
    while true; do read -p "Включить Белый список? (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    # default-player-permission-level
    echo "" && echo "-- Разрешения игрока по умолчанию --"
    key="default-player-permission-level"; current_val=$(get_property "$key" "$CONFIG_FILE" "member"); valid_options=("visitor" "member" "operator");
    while true; do read -p "Разрешения (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    # online-mode
    echo "" && echo "-- Режим онлайн (online-mode) --"; echo "true = только для лицензионных клиентов с Xbox Live."
    key="online-mode"; current_val=$(get_property "$key" "$CONFIG_FILE" "true"); valid_options=("true" "false");
    while true; do read -p "Режим онлайн? (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    msg "Настройки 'Игра по сети' сохранены. Требуется перезапуск сервера для применения."
    return 0
}

# 4. Настройка раздела "Читы"
configure_cheats_settings() {
    msg "--- 🛠️ Настройка: Читы и Правила Игры ---"
    if ! is_server_installed; then error "Сервер (ID: $ACTIVE_SERVER_ID) не установлен."; return 1; fi

    local CONFIG_FILE="$DEFAULT_INSTALL_DIR/server.properties"
    local allow_cheats_enabled key current_val new_val valid_options is_valid

    # Главный переключатель "Читы"
    echo ""
    warning "Включение читов позволит использовать команды и изменять правила игры, но ОТКЛЮЧИТ получение достижений."
    key="allow-cheats"; current_val=$(get_property "$key" "$CONFIG_FILE" "false"); valid_options=("true" "false");
    while true; do read -p "Включить читы? (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"
    allow_cheats_enabled="$new_val"

    # Настройки из server.properties, которые логично находятся здесь
    echo "" && msg "--- Дополнительные опции (требуют перезапуска) ---"

    key="enable-command-blocks"; current_val=$(get_property "$key" "$CONFIG_FILE" "false"); valid_options=("true" "false");
    echo "" && echo "-- Командные блоки --"
    while true; do read -p "Включить командные блоки? (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    key="education-edition"; current_val=$(get_property "$key" "$CONFIG_FILE" "false"); valid_options=("true" "false");
    echo "" && echo "-- Education Edition --"
    while true; do read -p "Включить Education Edition? (${valid_options[*]}) [$current_val]: " new_val; new_val="${new_val:-$current_val}"; is_valid=0; for option in "${valid_options[@]}"; do if [[ "$new_val" == "$option" ]]; then is_valid=1; break; fi; done; if [[ $is_valid -eq 1 ]]; then break; else echo "Неверно!"; fi; done
    set_property "$key" "$new_val" "$CONFIG_FILE"

    # Настройка Gamerules
    if [[ "$allow_cheats_enabled" != "true" ]]; then
        msg "Читы выключены. Настройка остальных правил игры недоступна."
        msg "Не забудьте перезапустить сервер для применения сделанных настроек."
        return 0
    fi

    echo "" && msg "--- Правила Игры (применяются на лету, если сервер активен) ---"
    local screen_name=${SERVICE_NAME%.service}
    local server_is_active=false
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then server_is_active=true; msg "Сервер '$SERVICE_NAME' активен."; else warning "Сервер НЕ активен, правила не применить."; fi

    # Вспомогательная функция для запроса да/нет
    ask_and_set_gamerule() {
        local rule_name="$1"; local question="$2"; local choice state=""
        echo "" && echo "-- $question --"
        read -p "$question? (yes/no): " choice
        if [[ "$choice" == "yes" || "$choice" == "y" ]]; then state="true"; fi
        if [[ "$choice" == "no" || "$choice" == "n" ]]; then state="false"; fi
        if [[ -n "$state" ]]; then
            local rule_cmd="gamerule $rule_name $state"
            if $server_is_active; then
                if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "$rule_cmd"$'\015'; then msg "Команда '$rule_cmd' отправлена."; sleep 1; fi
            fi
        else warning "Ввод некорректен, пропущено."; fi
    }

    ask_and_set_gamerule "dodaylightcycle" "Смена дня и ночи"
    ask_and_set_gamerule "keepinventory" "Сохранять инвентарь"
    ask_and_set_gamerule "domobspawning" "Создание мобов"
    ask_and_set_gamerule "mobgriefing" "Вредительство мобов"
    ask_and_set_gamerule "domobloot" "Выпадение добычи из сущностей"
    ask_and_set_gamerule "doweathercycle" "Смена погоды"

    echo "" && echo "-- Случайная скорость такта --"; echo "Стандарт: 3"
    read -p "Введите скорость такта (целое число) [3]: " new_tick_speed; new_tick_speed=${new_tick_speed:-3}
    if [[ "$new_tick_speed" =~ ^[0-9]+$ ]]; then
        local rule_cmd="gamerule randomtickspeed $new_tick_speed"
        if $server_is_active; then
             if sudo -u "$SERVER_USER" screen -S "$screen_name" -p 0 -X stuff "$rule_cmd"$'\015'; then msg "Команда '$rule_cmd' отправлена."; sleep 1; fi
        fi
    else warning "Некорректное значение, пропущено."; fi

    msg "Настройка 'Читы' завершена."
    msg "Изменения, требующие перезапуска: 'Включить читы', 'Командные блоки', 'Education Edition'."
    return 0
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

    local update_backup_dir="$DEFAULT_INSTALL_DIR/manual_update_data_backup_$(date +%s)"

    msg "Создание полной резервной копии перед обновлением..."
    local old_backup_setting=$BACKUP_WORLDS_ONLY
    BACKUP_WORLDS_ONLY=false
    if ! create_backup; then
        read -p "Не удалось создать резервную копию! Продолжить БЕЗ основной копии? (yes/no): " BACKUP_FAIL_CONFIRM
        if [[ "$BACKUP_FAIL_CONFIRM" != "yes" ]]; then BACKUP_WORLDS_ONLY=$old_backup_setting; error "Обновление отменено."; return 1; fi
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
    local files_to_keep=("worlds" "server.properties" "permissions.json" "whitelist.json" "behavior_packs" "resource_packs" "valid_known_packs.json" "config")
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

    msg "Распаковка вашего архива '$user_downloaded_zip'..."
    if ! sudo unzip -oq "$user_downloaded_zip" -d "$DEFAULT_INSTALL_DIR"; then
        warning "Ошибка распаковки вашего архива! Попытка восстановить данные..."
        if [ -d "$update_backup_dir" ]; then sudo mv "$update_backup_dir"/* "$DEFAULT_INSTALL_DIR/" 2>/dev/null; fi
        sudo rm -rf "$update_backup_dir"
        error "Не удалось распаковать ваш архив. Убедитесь, что это корректный zip-файл сервера Bedrock."
        return 1
    fi

    msg "Возвращение пользовательских данных..."
    if [ -d "$update_backup_dir" ]; then
        sudo rsync -a --remove-source-files "$update_backup_dir/" "$DEFAULT_INSTALL_DIR/"
        sudo rm -rf "$update_backup_dir"
    fi

    msg "Установка прав доступа..."
    if ! sudo chown -R "$SERVER_USER":"$SERVER_USER" "$DEFAULT_INSTALL_DIR"; then warning "Не удалось изменить владельца."; fi
    if [ -f "$DEFAULT_INSTALL_DIR/bedrock_server" ]; then if ! sudo chmod +x "$DEFAULT_INSTALL_DIR/bedrock_server"; then warning "Не удалось установить +x."; fi; else warning "bedrock_server не найден после распаковки!"; fi

    if [ -n "$new_version_manual" ]; then
        msg "Запись версии '$new_version_manual'..."
        if echo "$new_version_manual" | sudo tee "$DEFAULT_INSTALL_DIR/version" > /dev/null; then
            sudo chown "$SERVER_USER":"$SERVER_USER" "$DEFAULT_INSTALL_DIR/version"
        else
            warning "Не удалось записать файл версии."
        fi
    fi

    msg "Запуск обновленного сервера '$SERVICE_NAME'..."
    if ! start_server; then error "Сервер обновлен, но не запустился. Проверьте логи."; return 1; fi

    msg "--- Ручная установка обновления сервера (ID: $ACTIVE_SERVER_ID) завершена! ---"
    return 0
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

    msg ">>> Активный сервер: $name (ID: $id, Порт: $port, Путь: $dir, Сервис: $service) <<<"
    return 0
}

# Создание нового сервера
create_new_server() {
    msg "--- Создание нового сервера Minecraft Bedrock ---"
    # Мультисерверный режим теперь всегда активен, проверка MULTISERVER_ENABLED не нужна

    local server_name server_id server_port new_dir new_service input_id
    # Запрос имени
    read -p "Введите название нового сервера: " server_name
    if [ -z "$server_name" ]; then error "Название сервера не может быть пустым."; return 1; fi

    # Генерация и запрос ID
    server_id=$(echo "$server_name" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-'); server_id=${server_id:-"server$(date +%s)"}
    read -p "Введите ID сервера (только буквы, цифры, _-) [$server_id]: " input_id
    if [ -n "$input_id" ]; then server_id="$input_id"; fi
    # Простая валидация ID
    if ! [[ "$server_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then error "ID содержит недопустимые символы."; return 1; fi
    # Проверка уникальности ID
    if grep -q "^${server_id}:" "$SERVERS_CONFIG_FILE"; then error "Сервер с ID '$server_id' уже существует."; return 1; fi

    # Запрос порта
    read -p "Введите порт для сервера (например, 19133): " server_port
    if ! [[ "$server_port" =~ ^[0-9]+$ ]] || [ "$server_port" -lt 1024 ] || [ "$server_port" -gt 65535 ]; then error "Некорректный порт (1024-65535)."; return 1; fi
    # Проверка уникальности порта
    if grep -q ":${server_port}:" "$SERVERS_CONFIG_FILE"; then
        warning "Порт $server_port уже используется другим сервером!"
        read -p "Продолжить с этим портом (может вызвать проблемы)? (yes/no): " CONT
        if [[ "$CONT" != "yes" ]]; then msg "Создание сервера отменено."; return 1; fi
    fi

    # Определение путей
    new_dir="$SERVERS_BASE_DIR/$server_id"
    if [ -d "$new_dir" ]; then error "Директория '$new_dir' уже существует."; return 1; fi
    new_service="bds_${server_id}.service"

    # Запускаем установку с новыми параметрами
    msg "Установка нового сервера '$server_name' (ID: $server_id)..."
    # install_bds сама создаст директорию, сервис, откроет порт
    if ! install_bds "$new_dir" "$new_service" "$server_port"; then
        # install_bds должна была вывести свою ошибку
        error "Не удалось завершить установку нового сервера."
        # Дополнительно чистим, если что-то было создано частично
        sudo rm -rf "$new_dir"
        if [ -f "/etc/systemd/system/$new_service" ]; then sudo rm "/etc/systemd/system/$new_service"; sudo systemctl daemon-reload; fi
        return 1
    fi

    # Проверяем успешность установки еще раз (файл bedrock_server должен появиться)
    if [ ! -f "$new_dir/bedrock_server" ]; then error "Установка вроде бы завершилась, но файл bedrock_server не найден в '$new_dir'."; return 1; fi

    # Добавляем запись в конфигурацию
    echo "${server_id}:${server_name}:${server_port}:${new_dir}:${new_service}" | sudo tee -a "$SERVERS_CONFIG_FILE" > /dev/null
    msg "Сервер '$server_name' (ID: $server_id) добавлен в $SERVERS_CONFIG_FILE."

    # Предлагаем сделать его активным
    read -p "Сделать '$server_name' активным сервером сейчас? (yes/no): " ACTIVATE_NEW
    if [[ "$ACTIVATE_NEW" == "yes" ]]; then
        if ! load_server_config "$server_id"; then
             warning "Не удалось автоматически активировать новый сервер."
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

    warning "ВНИМАНИЕ! Удаление сервера '$name' (ID: $id) приведет к потере всех данных из '$dir'!"
    read -p "Создать резервную копию ПЕРЕД удалением? (yes/no): " BACKUP_CONFIRM
    if [[ "$BACKUP_CONFIRM" == "yes" ]]; then
        msg "Создание резервной копии для сервера '$name'..."
        if create_backup; then
            msg "Резервная копия создана."
        else
            warning "Не удалось создать копию!"
            read -p "Продолжить удаление БЕЗ копии? (yes/no): " CONT_DEL
            if [[ "$CONT_DEL" != "yes" ]]; then msg "Удаление отменено."; return 1; fi
        fi
    fi

    read -p "Вы ТОЧНО уверены, что хотите удалить сервер '$name' (ID: $id)? (yes/no): " CONFIRM
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

    msg "Сервер '$name' (ID: $id) удален."
    return 0
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
        printf "%1s %2d. %-25s (ID: %-10s Порт: %-5s Статус: %s)\n" "$active_mark" $i "$name" "$id" "$port" "$status"
        ((i++))
    done < "$SERVERS_CONFIG_FILE"

    local choice;
    # Проверяем, есть ли вообще что выбирать
    if [ ${#servers[@]} -eq 0 ]; then msg "Нет серверов для выбора."; return 1; fi

    read -p "Выберите номер сервера для активации (1-${#servers[@]}) или 0 для отмены: " choice
    if [[ "$choice" == "0" ]]; then msg "Выбор отменен."; return 0; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#servers[@]} ]; then error "Некорректный выбор."; return 1; fi

    local selected_id="${servers[$choice-1]}"
    if [ "$selected_id" == "$ACTIVE_SERVER_ID" ]; then msg "Сервер '${server_names[$choice-1]}' уже является активным."; return 0; fi

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

# Подменю мультисерверного режима (точка входа)
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

# --- Обработка аргументов командной строки (для автобэкапа) ---
handle_command_args() {
    if [ "$1" == "--auto-backup" ]; then
        # Используем echo для вывода в лог cron
        echo "--- Запуск автоматического резервного копирования $(date) ---"
        # Автобэкап должен запускаться от root, поэтому check_root не нужен здесь,
        # но все команды внутри должны использовать sudo или быть выполнены от root
        # Проверка прав выполняется перед вызовом этой функции в основном коде

        # Загружаем глобальные настройки из скрипта (на случай прямого запуска cron)
        if ! source "$(readlink -f "$0")"; then
            echo "Ошибка: Не удалось загрузить переменные из скрипта $0" >&2
            exit 1 # Критическая ошибка
        fi

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
    fi
    # Здесь можно добавить обработку других аргументов в будущем
    # Если аргумент не распознан, просто возвращаемся
    return 0
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
    SERVER_STATUS="Мультисервер"
    SERVER_INFO_LINE="Выберите сервер или операцию"
    active_server_name_display="не выбран"

    # Получаем имя активного сервера, если он выбран
    if [ -n "$ACTIVE_SERVER_ID" ]; then
         # Используем get_property для чтения имени из файла server.properties активного сервера
         # Это дает более актуальное имя, чем в servers.conf
         active_server_name_display=$(get_property "server-name" "$DEFAULT_INSTALL_DIR/server.properties" "$ACTIVE_SERVER_ID")
         # Если имя пустое в properties, используем ID
         if [ -z "$active_server_name_display" ]; then active_server_name_display=$ACTIVE_SERVER_ID; fi

         SERVER_STATUS="Активен: $active_server_name_display (ID: $ACTIVE_SERVER_ID)"
         # Проверяем статус сервиса
         if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
             SERVER_INFO_LINE="Сервис: $SERVICE_NAME (АКТИВЕН ✅)"
         else
             # Дополнительно проверяем, включен ли сервис
             if sudo systemctl is-enabled --quiet "$SERVICE_NAME"; then
                 SERVER_INFO_LINE="Сервис: $SERVICE_NAME (остановлен, автозапуск ВКЛ)"
             else
                  SERVER_INFO_LINE="Сервис: $SERVICE_NAME (остановлен, автозапуск ВЫКЛ)"
             fi
         fi
    else
         SERVER_STATUS="Мультисервер (активный не выбран)"
         SERVER_INFO_LINE="Выберите сервер (опция 8 -> 2) или создайте новый (опция 1)"
    fi

    # Отображаем главное меню
    echo ""
    echo "=========== Minecraft Bedrock Server Manager (Мультисервер) ==========="
    echo "   Статус: $SERVER_STATUS"
    echo "   $SERVER_INFO_LINE"
    echo "======================================================================"
    echo " --- Операции с Серверами ---"
    echo " 1. Создать НОВЫЙ сервер"
    echo " 2. Удалить активный сервер"
    echo " 3. Настроить активный сервер (Подменю)"
    echo " 4. Управление активным сервером (Запуск/Стоп/Статус)"
    echo " 5. Управление игроками активного сервера (Whitelist/OP)"
    echo " 6. Резервные копии активного сервера (Подменю)"
    echo " 7. Установить обновление активного сервера (ВРУЧНУЮ)"
    echo " 8. Меню Мультисервера (Выбор/Управление всеми)"
    echo " --- Дополнительно ---"
    echo " 9. Показать адрес активного сервера для подключения"
    echo "10. Настроить Авто-Бэкап (для всех серверов)"
    echo "11. Посмотреть все резервные копии"
    echo "12. Создать Архив Миграции (все серверы)"
    echo "13. Восстановить из Архива Миграции"
    echo "14. УДАЛИТЬ ВСЕ СЕРВЕРЫ И ДАННЫЕ"
    echo " 0. Выход"
    echo "======================================================================"

    # Сбрасываем choice перед запросом
    choice=""
    read -p "Выберите опцию: " choice

    # Блокируем опции, требующие активного сервера
    if [ -z "$ACTIVE_SERVER_ID" ] && [[ "$choice" =~ ^[2-7]$|^9$ ]]; then
        warning "Сначала выберите активный сервер (опция 8 -> 2)."
        read -p "Нажмите Enter для продолжения..." DUMMY_VAR
        continue # Возвращаемся к началу цикла while
    fi

    # Обработка выбора
    case $choice in
        1) create_new_server ;;
        2) delete_server ;; # Удаляет активный, требует выбора
        3) configure_menu ;; # Требует выбора активного
        4) # Подменю управления активным сервером
             while true; do
                 current_status="остановлен"
                 if sudo systemctl is-active --quiet "$SERVICE_NAME"; then current_status="АКТИВЕН ✅"; fi
                 echo ""; echo "--- Управление Сервером (ID: $ACTIVE_SERVER_ID | Статус: $current_status) ---"
                 echo "1. Запустить"; echo "2. Остановить"; echo "3. Перезапустить"; echo "4. Статус/Логи"; echo "0. Назад"
                 mgmt_choice=""; read -p "Опция: " mgmt_choice
                 case $mgmt_choice in
                     1) start_server ;; 2) stop_server ;; 3) restart_server ;; 4) check_status ;; 0) break ;; *) msg "Неверно.";;
                 esac
             done ;;
        5) players_menu ;; # Требует выбора активного
        6) # Подменю бэкапов активного сервера
            while true; do
                 echo ""; echo "--- Резервные Копии (Сервер ID: $ACTIVE_SERVER_ID) ---"
                 echo "1. Создать копию активного сервера"
                 echo "2. Восстановить активный сервер из копии"
                 echo "3. Список ВСЕХ резервных копий"
                 echo "4. Удалить резервную копию"
                 echo "0. Назад"
                 local backup_choice; read -p "Опция: " backup_choice
                 case $backup_choice in
                     1) create_backup ;; 2) restore_backup ;; 3) list_backups ;; 4) delete_backup ;; 0) break ;; *) msg "Неверно.";;
                 esac
                  # Пауза перед повторным показом меню подраздела, если не вышли
                 if [[ "$backup_choice" != "0" ]]; then
                     read -p "Нажмите Enter для возврата в меню бэкапов..." DUMMY_VAR
                 fi
            done ;;
        7) manual_update_server ;; # Требует выбора активного
        8) multiserver_menu ;;
        9) show_server_address ;; # Требует выбора активного
        10) setup_auto_backup ;;
        11) list_backups ;; # Показывает все бэкапы
        12) create_migration_archive ;; # Не требует активного
        13) restore_from_migration_archive ;; # Не требует активного
        14) wipe_all_servers ;;
        0) msg "Выход."; exit 0 ;;
        *) msg "Неверная опция. Попробуйте снова." ;;
    esac

    # Добавляем паузу перед повторным отображением главного меню, если не выходим
     if [[ "$choice" != "0" ]]; then
         # Пропускаем паузу после выхода из подменю, где уже могла быть своя пауза
         # (Подменю 4, 5, 6, 8 имеют свои циклы и/или паузы)
         if ! [[ "$choice" =~ ^[4-6]$|^8$ ]]; then
             read -p "Нажмите Enter для возврата в главное меню..." DUMMY_VAR
         fi
     fi

done

# Эта строка никогда не будет достигнута из-за 'exit 0' в опции 0, но для полноты
exit 0
