#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# --- Настройки ---
JACKETT_INSTALL_DIR="/opt" # Директория установки Jackett
JACKETT_APP_DIR_PATTERN="Jackett" # Шаблон имени директории приложения в /opt
JACKETT_CONFIG_DIR="/home/ubuntu/.config/Jackett" # Директория конфигурации Jackett (из логов)
JACKETT_SERVICE_NAME="jackett.service" # Имя systemd сервиса
JACKETT_DEFAULT_PORT="9117" # Порт Jackett по умолчанию
UFW_RULE_COMMENT="Jackett Access" # Комментарий для правила UFW

# Переменная для хранения фактического порта
JACKETT_PORT=$JACKETT_DEFAULT_PORT

# --- Проверка запуска от root ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ Ошибка: Этот скрипт должен выполняться от root!"
    echo "ℹ️ Пожалуйста, переключитесь на root ('su -' или 'sudo -i') и запустите заново." # Оставляем ℹ️ для информации
    exit 1
fi

# --- Вспомогательные функции ---

# Проверка доступности порта
is_port_available() {
    local port_to_check="$1"
    # Проверяем, слушается ли порт по TCP
    if ss -tlpn | grep -q ":${port_to_check}\\s"; then
        return 1 # Порт занят
    else
        return 0 # Порт свободен
    fi
}

# Запрос порта у пользователя
ask_for_port() {
    local current_port=$1
    echo "⚠️ Порт ${current_port} уже используется."
    while true; do
        read -p "Введите другой порт для Jackett (1-65535): " input_port # Убрали ❓
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

# Получение публичного IP
get_public_ip() {
    local ip
    # Пробуем несколько сервисов с таймаутом
    ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 api.ipify.org || curl -s -m 5 icanhazip.com || echo "")
    echo "$ip"
}

# Установка зависимостей
install_dependencies() {
    echo "Обновление пакетов и установка зависимостей (wget, tar, jq)..." # Убрали 🔄
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

# Найти директорию приложения Jackett
find_jackett_app_dir() {
    find "${JACKETT_INSTALL_DIR}" -maxdepth 1 -type d -name "${JACKETT_APP_DIR_PATTERN}*" -print -quit
}

# --- Основные функции ---

# Функция установки Jackett
install_jackett() {
    local install_dir_exists
    install_dir_exists=$(find_jackett_app_dir)
    JACKETT_PORT=$JACKETT_DEFAULT_PORT # Сброс к дефолтному порту

    # 1. Проверка существующей установки и удаление
    if [[ -d "$JACKETT_CONFIG_DIR" || -n "$install_dir_exists" ]]; then
        read -p "Jackett уже установлен. Переустановить? (y/N): " confirm # Убрали ❓
        if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then
            echo "Отмена." # Убрали 🚫
            return 1
        fi
        echo "Удаление предыдущей версии..." # Убрали 🔄
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
    echo "Проверка доступности порта ${JACKETT_PORT}..." # Убрали 🚦
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
        *) echo "❌ ОШИБКА: Неподдерживаемая архитектура: ${ARCH}."
           return 1 ;;
    esac

    echo "Получение последней версии Jackett..." # Убрали 🔄
    local RELEASE_TAG
    RELEASE_TAG=$(wget -q https://github.com/Jackett/Jackett/releases/latest -O - | grep 'title>Release' | cut -d ' ' -f 4)
    if [ -z "$RELEASE_TAG" ]; then
        echo "❌ ОШИБКА: Не удалось определить последнюю версию Jackett."
        return 1
    fi
    # Формируем команду wget с правильным URL
    local DOWNLOAD_URL="https://github.com/Jackett/Jackett/releases/download/${RELEASE_TAG}/${JACKETT_FILENAME}"
    echo "Загрузка ${DOWNLOAD_URL}..." # Убрали 📥

    if ! wget --quiet --show-progress -O "/tmp/${JACKETT_FILENAME}" "${DOWNLOAD_URL}"; then
         echo "❌ ОШИБКА: Не удалось скачать Jackett."
         rm -f "/tmp/${JACKETT_FILENAME}" # Удаляем частично скачанный файл
         return 1
    fi

    # 5. Распаковка
    echo "Распаковка Jackett в ${JACKETT_INSTALL_DIR}..." # Убрали 📦
    if ! tar -xzf "/tmp/${JACKETT_FILENAME}" -C "${JACKETT_INSTALL_DIR}"; then
        echo "❌ ОШИБКА: Не удалось распаковать архив Jackett."
        rm -f "/tmp/${JACKETT_FILENAME}"
        # Попытаемся удалить созданную директорию при ошибке распаковки
        rm -rf $(find ${JACKETT_INSTALL_DIR} -maxdepth 1 -type d -name "Jackett*" -print -quit)
        return 1
    fi
    rm -f "/tmp/${JACKETT_FILENAME}" # Удаляем архив после успешной распаковки

    # Получаем фактическое имя установочной директории
    local actual_install_dir
    actual_install_dir=$(find_jackett_app_dir)
    if [[ -z "$actual_install_dir" ]]; then
        echo "❌ ОШИБКА: Не удалось найти установочную директорию Jackett после распаковки."
        return 1
    fi

    # 6. Настройка прав
    chown -R ubuntu:ubuntu "$actual_install_dir" # Пример пользователя ubuntu, изменить при необходимости
    chmod +x "${actual_install_dir}/jackett"

    # 7. Создание systemd сервиса
    echo "Создание systemd сервиса (${JACKETT_SERVICE_NAME})..." # Убрали ⚙️
    cat << EOF > /etc/systemd/system/${JACKETT_SERVICE_NAME}
[Unit]
Description=Jackett Daemon
After=network.target

[Service]
User=ubuntu # Пример пользователя ubuntu
Group=ubuntu # Пример группы ubuntu
WorkingDirectory=${actual_install_dir}
ExecStart=${actual_install_dir}/jackett --NoRestart --Port ${JACKETT_PORT} # Используем выбранный порт
Restart=always
RestartSec=5
Environment=DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 # Для совместимости

[Install]
WantedBy=multi-user.target
EOF

    # 8. Перезагрузка systemd и запуск сервиса
    echo "Перезагрузка конфигурации systemd..." # Убрали 🔄
    systemctl daemon-reload
    echo "Запуск и включение сервиса ${JACKETT_SERVICE_NAME}..." # Убрали ▶️
    if ! systemctl enable ${JACKETT_SERVICE_NAME} --now; then
        echo "❌ ОШИБКА: Не удалось запустить или включить сервис Jackett."
        echo " Попробуйте посмотреть логи: journalctl -u ${JACKETT_SERVICE_NAME}"
        # Удаляем файл сервиса при ошибке
        rm -f /etc/systemd/system/${JACKETT_SERVICE_NAME}
        systemctl daemon-reload
        return 1
    fi

    # 9. Настройка UFW
    echo "Настройка UFW для порта ${JACKETT_PORT}..." # Убрали 🔥
    if command -v ufw &> /dev/null; then
        ufw allow proto tcp to any port ${JACKETT_PORT} comment "${UFW_RULE_COMMENT}"
        echo "UFW: Добавлено правило для порта ${JACKETT_PORT}."
    else
        echo "⚠️ UFW не найден. Правило для порта ${JACKETT_PORT} не добавлено."
    fi

    # 10. Финальное сообщение
    echo ""
    echo "✅ Установка Jackett завершена!"
    show_address_internal $JACKETT_PORT
    echo "ℹ️ Логи можно посмотреть командой: journalctl -u ${JACKETT_SERVICE_NAME}"
    echo "ℹ️ Конфигурация находится в: ${JACKETT_CONFIG_DIR}"
    echo "ℹ️ Если вы используете прокси или Docker, может потребоваться дополнительная настройка."
    echo "ℹ️ Возможно, потребуется перезагрузка сервера для полной уверенности, что все работает корректно."
    echo "ℹ️ При первом запуске веб-интерфейса может потребоваться установить пароль администратора."
    return 0
}

# Внутренняя функция удаления Jackett
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
        echo "Удаление Jackett" # Убрали 🗑️
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

        read -p "Удалить Jackett (конфиг: ${config_dir_actual}, порт ${port_to_remove})? (y/N): " confirmation # Убрали ❓
        if [[ ! "$confirmation" =~ ^[YyДд]$ ]]; then
            echo "Удаление отменено." # Убрали 🚫
            return 1
        fi
    fi

    echo "Остановка и отключение сервиса ${JACKETT_SERVICE_NAME}..." # Убрали ⏳
    systemctl disable ${JACKETT_SERVICE_NAME} --now &> /dev/null
    # Файл сервиса не найден, так что удалять его не нужно
    # echo "Удаляем файл сервиса..." # Убрали 🗑️
    # rm -f /etc/systemd/system/${JACKETT_SERVICE_NAME}
    echo "Перезагрузка конфигурации systemd..." # Убрали 🔄
    systemctl daemon-reload
    systemctl reset-failed # Сброс состояния failed юнитов

    echo "Удаление конфигурационной директории (${config_dir_actual})..." # Убрали 🗑️
    rm -rf "${config_dir_actual}"

    if [[ -n "$install_dir_to_remove" && -d "$install_dir_to_remove" ]]; then
        echo "Удаление установочной директории ${install_dir_to_remove}..." # Убрали 🗑️
        rm -rf "$install_dir_to_remove"
    else
        echo "ℹ️ Установочная директория Jackett в ${JACKETT_INSTALL_DIR} не найдена."
    fi

    echo "UFW: Удаление правила для порта ${port_to_remove}..." # Убрали 🔥
    if command -v ufw &> /dev/null; then
        ufw delete allow proto tcp to any port ${port_to_remove} comment "${UFW_RULE_COMMENT}" &> /dev/null || echo "ℹ️ UFW: Правило не найдено или не удалось удалить."
    fi

    echo ""
    echo "✅ Удаление Jackett завершено!"
    return 0
}

# Функция удаления Jackett (публичная)
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

# Функция показа адреса (внутренняя)
show_address_internal() {
    local port_to_show=$1
    local public_ip
    public_ip=$(get_public_ip)
    if [[ -z "$public_ip" ]]; then
        echo "⚠️ Не удалось определить внешний IP-адрес сервера. Не могу показать ссылку."
    else
        echo "Адрес сервера: http://${public_ip}:${port_to_show}" # Убрали 🌍
    fi
}

# Функция показа адреса (публичная)
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
           echo " Попробуйте запустить: systemctl start ${JACKETT_SERVICE_NAME}"
        else
           echo "ℹ️ Jackett не установлен или сервис не найден."
        fi
    fi
}

# --- Основная часть скрипта (Меню) ---
while true; do
    echo ""
    echo "======== Меню Jackett ========" # Убрали 🎬
    echo "1. Установить / Переустановить Jackett" # Убрали 1️⃣
    echo "2. Удалить Jackett" # Убрали 2️⃣
    echo "3. Показать адрес сервера Jackett" # Убрали 3️⃣
    echo "0. Выход" # Убрали 0️⃣ 👋
    echo ""
    read -p "Введите номер действия (0-3): " choice # Убрали 👉
    case $choice in
        1) install_jackett ;;
        2) remove_jackett ;;
        3) show_address ;;
        0) echo "Выход." echo "" exit 0 ;; # Убрали 👋
        *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
    esac
    echo "" # Добавляем пустую строку после выполнения действия для отделения от следующего меню
done
