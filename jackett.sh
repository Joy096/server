#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# --- ⚙️ Настройки ---
JACKETT_INSTALL_DIR="/opt"                          # 🌳 Директория установки Jackett
JACKETT_APP_DIR_PATTERN="Jackett"                   # 📁 Шаблон имени директории приложения в /opt
JACKETT_CONFIG_DIR="/home/ubuntu/.config/Jackett"   # 📄 Директория конфигурации Jackett (из логов)
JACKETT_SERVICE_NAME="jackett.service"              # ⚙️ Имя systemd сервиса
JACKETT_DEFAULT_PORT="9117"                         # 🔌 Порт Jackett по умолчанию
UFW_RULE_COMMENT="Jackett Access"                   # 🔥 Комментарий для правила UFW

# Переменная для хранения фактического порта
JACKETT_PORT=$JACKETT_DEFAULT_PORT

# --- 🔒 Проверка запуска от root ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ Ошибка: Этот скрипт должен выполняться от root!"
    echo "ℹ️ Пожалуйста, переключитесь на root ('su -' или 'sudo -i') и запустите заново."
    exit 1
fi

# --- 🛠️ Вспомогательные функции ---

# 🚦 Проверка доступности порта
is_port_available() {
    local port_to_check="$1"
    # Проверяем, слушается ли порт по TCP
    if ss -tlpn | grep -q ":${port_to_check}\s"; then
        return 1 # Порт занят
    else
        return 0 # Порт свободен
    fi
}

# ❓ Запрос порта у пользователя
ask_for_port() {
    local current_port=$1
    echo "⚠️ Порт ${current_port} уже используется."
    while true; do
        read -p "❓ Введите другой порт для Jackett (1-65535): " input_port
        # Валидация ввода
        if ! [[ "$input_port" =~ ^[0-9]+$ ]]; then
            echo "❌ Ошибка: Введите корректный номер порта (число)."
            continue
        fi
        if [[ "$input_port" -lt 1 || "$input_port" -gt 65535 ]]; then
            echo "❌ Ошибка: Порт должен быть в диапазоне 1-65535."
            continue
        fi
        # Проверка доступности
        if is_port_available "$input_port"; then
            JACKETT_PORT=$input_port # Обновляем глобальную переменную
            echo "✅ Порт ${JACKETT_PORT} выбран и свободен."
            break # Выходим из цикла, порт найден
        else
            echo "⚠️ Порт ${input_port} также занят. Пожалуйста, выберите другой."
        fi
    done
}

# 🌐 Получение публичного IP
get_public_ip() {
    local ip
    # Пробуем несколько сервисов с таймаутом
    ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 api.ipify.org || curl -s -m 5 icanhazip.com || echo "")
    echo "$ip"
}

# 📦 Установка зависимостей
install_dependencies() {
    echo "🔄 Обновление пакетов и установка зависимостей (wget, tar, jq)..."
    export DEBIAN_FRONTEND=noninteractive

    # Обновляем список пакетов
    if ! apt-get update -qq > /dev/null; then
        echo "❌ ОШИБКА: Не удалось обновить список пакетов."
        return 1
    fi

    local packages_to_install=""
    for pkg in wget tar jq; do
        if ! dpkg -s $pkg &> /dev/null; then
            packages_to_install+="$pkg "
        fi
    done

    if [[ -n "$packages_to_install" ]]; then
        if ! apt-get install -y $packages_to_install > /dev/null; then
             echo "❌ ОШИБКА: Не удалось установить: $packages_to_install"
             return 1
        fi
    fi
    return 0
}

# 🏠 Найти директорию приложения Jackett
find_jackett_app_dir() {
    find "${JACKETT_INSTALL_DIR}" -maxdepth 1 -type d -name "${JACKETT_APP_DIR_PATTERN}*" -print -quit
}

# --- 🚀 Основные функции ---

# 🚀 Функция установки Jackett
install_jackett() {
    local install_dir_exists
    install_dir_exists=$(find_jackett_app_dir)
    JACKETT_PORT=$JACKETT_DEFAULT_PORT # Сброс к дефолтному порту

    # 1. Проверка существующей установки и удаление
    if [[ -d "$JACKETT_CONFIG_DIR" || -n "$install_dir_exists" ]]; then
        read -p "❓ Jackett уже установлен. Переустановить? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then
            echo "🚫 Отмена."
            return 1
        fi
        echo "🔄 Удаление предыдущей версии..."
        local old_port=$JACKETT_DEFAULT_PORT
        if [[ -f "${JACKETT_CONFIG_DIR}/ServerConfig.json" ]]; then
            # Пытаемся получить порт из конфига, если не удается или не число - используем дефолт
            old_port=$(jq -r '.Port // empty' "${JACKETT_CONFIG_DIR}/ServerConfig.json" 2>/dev/null) || old_port=$JACKETT_DEFAULT_PORT
             [[ "$old_port" =~ ^[0-9]+$ ]] || old_port=$JACKETT_DEFAULT_PORT
        fi
        # Вызываем внутреннюю функцию удаления
        if ! remove_jackett_internal "skip_confirmation" "$old_port"; then
            echo "❌ Ошибка удаления предыдущей версии. Установка прервана."
            return 1
        fi
        echo "✅ Предыдущая версия удалена."
    fi

    # 2. Проверка и выбор порта
    echo ""
    echo "🚦 Проверка доступности порта ${JACKETT_PORT}..."
    if ! is_port_available "$JACKETT_PORT"; then
        ask_for_port "$JACKETT_PORT" # Запросить новый порт
    fi

    # 3. Установка зависимостей
    if ! install_dependencies; then
        return 1
    fi

    # 4. Определение архитектуры и версии
    local ARCH
    ARCH=$(dpkg --print-architecture)

    local JACKETT_FILENAME=""
    local INSTALL_CMD=""
    case "$ARCH" in
        arm64) JACKETT_FILENAME="Jackett.Binaries.LinuxARM64.tar.gz" ;;
        amd64) JACKETT_FILENAME="Jackett.Binaries.LinuxAMDx64.tar.gz" ;;
        *)
           echo "❌ ОШИБКА: Неподдерживаемая архитектура: ${ARCH}."
           return 1
           ;;
    esac

    echo "🔄 Получение последней версии Jackett..."
    local RELEASE_TAG
    RELEASE_TAG=$(wget -q https://github.com/Jackett/Jackett/releases/latest -O - | grep 'title>Release' | cut -d ' ' -f 4)
    if [ -z "$RELEASE_TAG" ]; then
        echo "❌ ОШИБКА: Не удалось определить последнюю версию Jackett."
        return 1
    fi

    # Формируем команду установки (без sudo, т.к. скрипт под root)
    INSTALL_CMD="f=${JACKETT_FILENAME} && \
    rm -f \"\${f}\" && \
    wget -q -Nc https://github.com/Jackett/Jackett/releases/download/${RELEASE_TAG}/\"\${f}\" && \
    tar -xzf \"\${f}\" && \
    rm -f \"\${f}\" && \
    cd ${JACKETT_APP_DIR_PATTERN}* && \
    ./install_service_systemd.sh"

    # 5. Скачивание, распаковка, установка сервиса
    echo ""
    echo "🚀 Установка Jackett (скачивание, распаковка, установка сервиса)..."
    # Создаем директорию, если не существует
    if ! mkdir -p "${JACKETT_INSTALL_DIR}"; then
        echo "❌ ОШИБКА: Не удалось создать директорию ${JACKETT_INSTALL_DIR}"
        return 1
    fi
    # Переходим в директорию установки
    if ! cd "${JACKETT_INSTALL_DIR}"; then
        echo "❌ ОШИБКА: Не удалось перейти в директорию ${JACKETT_INSTALL_DIR}"
        return 1
    fi
    # Выполняем команду установки
    if ! eval "$INSTALL_CMD"; then
        echo "❌ ОШИБКА: Во время выполнения команды установки произошла ошибка."
        cd ~ # Вернуться в домашнюю директорию на всякий случай
        return 1
    fi
    # Возвращаемся в /opt после 'cd Jackett*' внутри eval
    if ! cd "${JACKETT_INSTALL_DIR}"; then
        echo "⚠️ Не удалось вернуться в ${JACKETT_INSTALL_DIR} после установки."
    fi

    # 6. Ожидание файла конфигурации
    systemctl daemon-reload

    if ! systemctl start ${JACKETT_SERVICE_NAME}; then
         echo "⚠️ Не удалось запустить сервис ${JACKETT_SERVICE_NAME} (возможно, он уже был запущен)."
    fi

    local wait_time=0
    local max_wait=30
    local config_found=0

    # Создаем директории и устанавливаем владельца ubuntu
    mkdir -p "${JACKETT_CONFIG_DIR}"
    chown -R ubuntu:ubuntu "$(dirname ${JACKETT_CONFIG_DIR})" # Права на /home/ubuntu/.config
    chown -R ubuntu:ubuntu "${JACKETT_CONFIG_DIR}"          # Права на /home/ubuntu/.config/Jackett

    while [[ $config_found -eq 0 && $wait_time -lt $max_wait ]]; do
        # Проверяем, активен ли сервис
        if ! systemctl status ${JACKETT_SERVICE_NAME} &> /dev/null; then
             echo "❌ ОШИБКА: Сервис Jackett остановился во время ожидания конфигурационного файла!"
             echo "ℹ️ Проверьте логи: journalctl -u ${JACKETT_SERVICE_NAME}"
             return 1
        fi
        # Проверяем наличие файла
        if [[ -f "${JACKETT_CONFIG_DIR}/ServerConfig.json" ]]; then
            config_found=1
        else
            sleep 2
            wait_time=$((wait_time + 2))
        fi
    done

    if [[ $config_found -eq 0 ]]; then
        echo "❌ ОШИБКА: Файл конфигурации не найден в ${JACKETT_CONFIG_DIR} после ${max_wait} секунд!"
        echo "ℹ️ Проверьте права доступа к директории и логи сервиса: journalctl -u ${JACKETT_SERVICE_NAME}"
        return 1
    fi

    # 7. Запрос API ключа
    echo ""
    local api_key=""
    while [ -z "$api_key" ]; do
        # Используем read -p (без -s) для видимого ввода
        read -p "🔑 Введите ваш API ключ для Jackett: " api_key
        if [ -z "$api_key" ]; then
            echo "⚠️ API ключ не должен быть пустым. Попробуйте еще раз."
        fi
    done

    # 8. Настройка конфигурации
    local SERVER_CONFIG_JSON="${JACKETT_CONFIG_DIR}/ServerConfig.json"

    # Убедимся, что владелец - ubuntu
    chown ubuntu:ubuntu "$SERVER_CONFIG_JSON" 2>/dev/null || true

    # Используем jq для модификации JSON
    if ! jq --arg newkey "$api_key" --argjson newport "$JACKETT_PORT" \
            '.AllowExternal = true | .AllowCors = true | .APIKey = $newkey | .Port = $newport' \
            "${SERVER_CONFIG_JSON}" > "${SERVER_CONFIG_JSON}.tmp"; then
        echo "❌ ОШИБКА: Не удалось выполнить команду jq."
        rm -f "${SERVER_CONFIG_JSON}.tmp" # Удалить временный файл, если он создался
        return 1
    fi
    # Заменяем оригинальный файл временным
    if ! mv "${SERVER_CONFIG_JSON}.tmp" "${SERVER_CONFIG_JSON}"; then
        echo "❌ ОШИБКА: Не удалось переместить временный файл конфигурации."
        return 1
    fi
    # Восстанавливаем владельца после редактирования root'ом
    chown ubuntu:ubuntu "$SERVER_CONFIG_JSON"
    echo "✅ Конфигурация обновлена (API ключ, External Access, CORS, Порт)."

    # 9. Перезапуск сервиса
    systemctl restart ${JACKETT_SERVICE_NAME}
    sleep 5 # Даем время на перезапуск

    if ! systemctl status ${JACKETT_SERVICE_NAME} &> /dev/null; then
        echo "❌ ОШИБКА: Сервис Jackett не запустился после перезапуска!"
        echo "ℹ️ Проверьте конфигурационный файл (${SERVER_CONFIG_JSON}) и логи: journalctl -u ${JACKETT_SERVICE_NAME}"
        return 1
    fi

    # 10. Настройка UFW
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            # Сначала удаляем старое правило (если было)
            ufw delete allow proto tcp to any port ${JACKETT_PORT} comment "${UFW_RULE_COMMENT}" &> /dev/null
            # Добавляем новое
            if ! ufw allow ${JACKETT_PORT}/tcp comment "${UFW_RULE_COMMENT}" > /dev/null; then
                 echo "⚠️ UFW: Не удалось добавить правило для порта ${JACKETT_PORT}."
            fi
            echo "✅ UFW: Правило для порта ${JACKETT_PORT} добавлено."
        else
             echo "ℹ️ UFW установлен, но не активен. Правило не добавлено."
        fi
    else
        echo "ℹ️ UFW не установлен. Если используется другой фаервол, откройте порт ${JACKETT_PORT} вручную."
    fi

    # 11. Замена Indexers (опционально)
    echo ""
    read -p "❓ Заменить папку Indexers из вашего источника? (y/N): " replace_indexers
    if [[ "$replace_indexers" =~ ^[YyДд]$ ]]; then
        read -e -p "📂 Введите ПОЛНЫЙ путь к вашей папке Indexers: " indexers_source_path
        if [ -n "$indexers_source_path" ] && [ -d "$indexers_source_path" ]; then
            echo "📑 Копирование содержимого из ${indexers_source_path} в ${JACKETT_CONFIG_DIR}/Indexers..."
            local indexer_target_dir="${JACKETT_CONFIG_DIR}/Indexers"
            mkdir -p "$indexer_target_dir"
            # Используем rsync для копирования
            if ! rsync -a --delete "${indexers_source_path}/" "$indexer_target_dir/"; then
                 echo "⚠️ Ошибка при копировании Indexers с помощью rsync."
            fi
            # Устанавливаем права для пользователя ubuntu
            chown -R ubuntu:ubuntu "$indexer_target_dir"
            chmod -R 750 "$indexer_target_dir" # Права для владельца и группы
            echo "🔄 Перезапуск Jackett после копирования Indexers..."
            systemctl restart ${JACKETT_SERVICE_NAME}
            sleep 5
        else
            echo "⚠️ Указанный путь не существует или не является директорией. Папка Indexers не была заменена."
        fi
    else
        echo "ℹ️ Пропуск замены папки Indexers."
    fi

    # 12. Финальное сообщение
    echo ""
    echo "✅ Установка Jackett успешно завершена!"
    echo "🔑 API ключ: ${api_key}"
    echo "🔌 Порт: ${JACKETT_PORT}"
    echo ""
    show_address_internal "$JACKETT_PORT" # Показываем адрес
    echo ""
    echo "👉 Откройте веб-интерфейс Jackett и установите пароль администратора."
    return 0
}

# 🗑️ Внутренняя функция удаления Jackett
remove_jackett_internal() {
    local skip_confirmation=$1
    local port_to_remove=$2
    # Проверка и установка дефолтного порта, если нужно
    [[ -z "$port_to_remove" ]] && port_to_remove=$JACKETT_DEFAULT_PORT
    [[ "$port_to_remove" =~ ^[0-9]+$ ]] || port_to_remove=$JACKETT_DEFAULT_PORT

    local install_dir_to_remove
    install_dir_to_remove=$(find_jackett_app_dir)
    local config_dir_actual="${JACKETT_CONFIG_DIR}"

    # Запрос подтверждения, если не пропущено
    if [[ "$skip_confirmation" != "skip_confirmation" ]]; then
        echo ""
        echo "🗑️ Удаление Jackett 🗑️"
        # Проверка, есть ли что удалять
        if [[ ! -d "$config_dir_actual" && -z "$install_dir_to_remove" ]]; then
            echo "ℹ️ Jackett не найден. Нечего удалять."
            return 0
        fi
        # Определяем порт из конфига для сообщения пользователю
        if [[ -f "$config_dir_actual/ServerConfig.json" ]]; then
            current_port_in_config=$(jq -r '.Port // empty' "$config_dir_actual/ServerConfig.json" 2>/dev/null) || current_port_in_config=$JACKETT_DEFAULT_PORT
            [[ "$current_port_in_config" =~ ^[0-9]+$ ]] || current_port_in_config=$JACKETT_DEFAULT_PORT
            port_to_remove=$current_port_in_config # Используем фактический порт для UFW
        fi
        read -p "❓ Удалить Jackett (конфиг: ${config_dir_actual}, порт ${port_to_remove})? (y/N): " confirmation
        if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
            echo "🚫 Удаление отменено."
            return 1
        fi
    fi

    echo "⏳ Остановка и отключение сервиса ${JACKETT_SERVICE_NAME}..."
    systemctl disable ${JACKETT_SERVICE_NAME} --now &> /dev/null

    # Файл сервиса не найден, так что удалять его не нужно
    # echo "🗑️ Удаляем файл сервиса..."
    # rm -f /etc/systemd/system/${JACKETT_SERVICE_NAME}

    echo "🔄 Перезагрузка конфигурации systemd..."
    systemctl daemon-reload
    systemctl reset-failed # Сброс состояния failed юнитов

    echo "🗑️  Удаление конфигурационной директории (${config_dir_actual})..."
    rm -rf "${config_dir_actual}"

    if [[ -n "$install_dir_to_remove" && -d "$install_dir_to_remove" ]]; then
        echo "🗑️  Удаление установочной директории ${install_dir_to_remove}..."
        rm -rf "$install_dir_to_remove"
    else
        echo "ℹ️ Установочная директория Jackett в ${JACKETT_INSTALL_DIR} не найдена."
    fi

    echo "🔥 UFW: Удаление правила для порта ${port_to_remove}..."
    if command -v ufw &> /dev/null; then
        ufw delete allow proto tcp to any port ${port_to_remove} comment "${UFW_RULE_COMMENT}" &> /dev/null || echo "ℹ️ UFW: Правило не найдено или не удалось удалить."
    fi

    echo ""
    echo "✅ Удаление Jackett завершено!"
    return 0
}

# 🗑️ Функция удаления Jackett (публичная)
remove_jackett() {
    echo ""
    local current_port=$JACKETT_DEFAULT_PORT
    local config_path="${JACKETT_CONFIG_DIR}/ServerConfig.json"
    # Определяем порт из конфига перед вызовом внутренней функции
    if [[ -f "$config_path" ]]; then
        current_port=$(jq -r '.Port // empty' "$config_path" 2>/dev/null) || current_port=$JACKETT_DEFAULT_PORT
        [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=$JACKETT_DEFAULT_PORT
    fi
    if ! remove_jackett_internal "skip_confirmation" "$current_port"; then
        echo "❌ Ошибка во время процесса удаления."
        return 1
    fi
}

# 🌐 Функция показа адреса (внутренняя)
show_address_internal() {
    local port_to_show=$1
    local public_ip
    public_ip=$(get_public_ip)

    if [[ -z "$public_ip" ]]; then
        echo "⚠️ Не удалось определить внешний IP-адрес сервера. Не могу показать ссылку."
    else
        echo "🌍 Адрес сервера:  http://${public_ip}:${port_to_show}"
    fi
}

# 🌐 Функция показа адреса (публичная)
show_address() {
    echo ""
    local current_port=$JACKETT_DEFAULT_PORT
    local config_path="${JACKETT_CONFIG_DIR}/ServerConfig.json"

    # Пытаемся получить актуальный порт из конфига
    if [[ -f "$config_path" ]]; then
         current_port=$(jq -r '.Port // empty' "$config_path" 2>/dev/null) || current_port=$JACKETT_DEFAULT_PORT
         [[ "$current_port" =~ ^[0-9]+$ ]] || current_port=$JACKETT_DEFAULT_PORT
    fi

    # Используем systemctl status для проверки активности
    if systemctl status ${JACKETT_SERVICE_NAME} &> /dev/null; then
         show_address_internal "$current_port"
    else
         # Проверяем, известен ли сервис системе
         if systemctl list-units --full -all | grep -q "${JACKETT_SERVICE_NAME}"; then
             echo "ℹ️ Сервис Jackett установлен, но сейчас не активен. Адрес показать не могу."
             echo "   Попробуйте запустить: systemctl start ${JACKETT_SERVICE_NAME}"
         else
             echo "ℹ️ Jackett не установлен или сервис не найден."
         fi
    fi
}

# --- 🎬 Основная часть скрипта (Меню) ---
while true; do
    echo ""
    echo "🎬 ======== Меню Jackett ======== 🎬"
    echo "1️⃣   Установить / Переустановить Jackett"
    echo "2️⃣   Удалить Jackett"
    echo "3️⃣   Показать адрес сервера Jackett"
    echo "0️⃣  👋 Выход"
    echo ""
    read -p "👉 Введите номер действия (0-3): " choice

    case $choice in
        1)
            install_jackett
            ;;
        2)
            remove_jackett
            ;;
        3)
            show_address
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
    echo "" # Добавляем пустую строку после выполнения действия для отделения от следующего меню
done
