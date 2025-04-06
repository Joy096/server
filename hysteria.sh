#!/bin/bash

# ==============================================================================
# Скрипт управления сервером Hysteria v2 на Ubuntu 24/Debian 12+
# ==============================================================================

# --- Глобальные Константы ---
HYSTERIA_BIN_PATH="/usr/local/bin/hysteria"        # Путь к бинарному файлу Hysteria
HYSTERIA_CONFIG_DIR="/etc/hysteria"                # Директория конфигурации Hysteria
HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml" # Файл конфигурации Hysteria
HYSTERIA_CONN_INFO_FILE="${HYSTERIA_CONFIG_DIR}/connection_info.dat" # Файл для хранения данных подключения
HYSTERIA_SERVICE_FILE="/etc/systemd/system/hysteria-server.service" # Файл службы systemd
DEFAULT_CERT_PATH="${HYSTERIA_CONFIG_DIR}/server.crt" # Путь к сертификату (для self-signed)
DEFAULT_KEY_PATH="${HYSTERIA_CONFIG_DIR}/server.key"  # Путь к приватному ключу (для self-signed)

# --- Цвета для вывода ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Вспомогательные функции ---
error_msg() { 
    echo -e "${RED}❌ Ошибка: $1${NC}" >&2
}

info_msg() { 
    echo -e "${GREEN}✅ $1${NC}"
}

warning_msg() { 
    echo -e "${YELLOW}⚠️ $1${NC}"
}

# Функция отображения прогресса с анимацией точек
spinner() {
    local pid=$1
    local message="$2"
    local delay=0.3
    
    # Выводим сообщение с зеленым цветом
    echo -ne "${GREEN}$message...${NC}"
    
    # Массив для анимации точек
    local frames=(" .." ". ." ".. " "...")
    local i=0
    
    # Пока процесс работает
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r${GREEN}$message%s${NC}" "${frames[$i]}"
        sleep $delay
    done
    
    # Завершающее сообщение
    printf "\r${GREEN}$message...    ${NC}\n"
}

is_hysteria_installed() { 
    if [[ -f "$HYSTERIA_BIN_PATH" && -f "$HYSTERIA_CONFIG_FILE" && -f "$HYSTERIA_SERVICE_FILE" ]]; then 
        return 0
    else 
        return 1
    fi
}

get_config_value() { 
    local key="$1"
    
    if [[ -f "$HYSTERIA_CONFIG_FILE" ]]; then 
        grep -E "^\s*${key}" "$HYSTERIA_CONFIG_FILE" | sed -e "s/^\s*${key}\s*//" -e "s/\s*#.*$//" | tr -d '"' | tr -d "'" | head -n 1
    else 
        echo ""
    fi
}

get_public_ip() { 
    local ip
    
    ip=$(curl -fsSL https://ipinfo.io/ip || curl -fsSL https://api.ipify.org || echo "")
    
    if [[ -z "$ip" ]]; then 
        error_msg "Не удалось определить IP."
        return 1
    fi
    
    echo "$ip"
    return 0
}

get_mbps() { 
    local s="$1"
    
    if [[ -z "$s" ]]; then 
        echo ""
        return
    fi
    
    local v=$(echo "$s" | grep -oE '^[0-9]+')
    
    if [[ -z "$v" ]]; then 
        echo ""
        return
    fi
    
    if [[ "$s" == *"gbps"* ]]; then 
        v=$((v * 1000))
    elif [[ "$s" == *"kbps"* ]]; then 
        v=$(awk "BEGIN {print int(${v}/1000)}")
        [[ "$v" -eq 0 ]] && v="1"
    fi
    
    echo "$v"
}

command_exists() { 
    command -v "$1" >/dev/null 2>&1
}


# --- Основные функции меню ---

# Функция установки или перенастройки Hysteria 2
install_hysteria() {
    # Проверка на существующую установку
    if is_hysteria_installed; then
        warning_msg " Hysteria уже установлена."
        
        local confirm_reinstall
        read -p "Хотите переустановить/перенастроить? (y/N): " confirm_reinstall
        
        if [[ ! "$confirm_reinstall" =~ ^[Yy]$ ]]; then 
            info_msg "Отмена."
            return 0
        fi
        
        warning_msg " Конфигурация будет перезаписана."
    fi

    # 1. Зависимости
    # Запускаем длительные операции в фоне и сохраняем их PID
    {
        apt update > /dev/null 2>&1 && \
        DEBIAN_FRONTEND=noninteractive apt install -y curl ufw openssl jq qrencode wget > /dev/null 2>&1
    } &
    local apt_pid=$!
    
    # Запускаем анимацию и ждем завершения apt
    spinner $apt_pid "Обновление и установка зависимостей"
    
    # Проверяем, успешно ли завершились команды
    if ! wait $apt_pid; then
        error_msg "Ошибка установки пакетов."
        return 1
    fi


    # 2. Параметры
    echo ""
    info_msg "--- Настройка параметров Hysteria ---"
    warning_msg " [Enter] для значения по умолчанию."

    # Переменные для сбора данных
    local hysteria_port hysteria_password bw_up bw_down tls_choice profile_name
    local server_addr domain_name cert_path key_path
    local final_sni final_insecure final_fingerprint="" # Переменные для сохранения
    local is_external_acme_flag="false" # Флаг типа сертификата для сохранения

    cert_path="$DEFAULT_CERT_PATH" # Путь по умолчанию для self-signed
    key_path="$DEFAULT_KEY_PATH"   # Путь по умолчанию для self-signed

    # Порт
    local default_port="443"
    read -p "Порт Hysteria (UDP) [${default_port}]: " hysteria_port
    hysteria_port=${hysteria_port:-$default_port}
    
    if ! [[ "$hysteria_port" =~ ^[0-9]+$ ]] || [[ "$hysteria_port" -lt 1 ]] || [[ "$hysteria_port" -gt 65535 ]]; then 
        error_msg "Неверный порт: $hysteria_port."
        return 1
    fi

    # Пароль
    local default_password=$(openssl rand -base64 16)
    read -p "Пароль аутентификации [случайный]: " hysteria_password
    hysteria_password=${hysteria_password:-$default_password}
    
    if [[ -z "$hysteria_password" ]]; then 
        error_msg "Пароль пуст."
        return 1
    fi

    # Лимиты
    read -p "Лимит Upload (напр. 50 mbps) [Enter=безлимит]: " bw_up
    read -p "Лимит Download (напр. 300 mbps) [Enter=безлимит]: " bw_down

    # Имя профиля
    local default_profile_name="Hysteria_$(hostname -s)_${hysteria_port}"
    read -p "Имя профиля V2RayNG [${default_profile_name}]: " profile_name
    profile_name=${profile_name:-$default_profile_name}

    # Метод TLS
    echo "--------------------------------------------------"
    echo "Выберите метод TLS:"
    echo "  1) ACME (Let's Encrypt) [Нужен зарегистрированный домен, указывающий на сервер. SNI = оригинальный домен]"
    echo "  2) Self-signed сертификат [Домен НЕ нужен, используется IP-адрес. Можно использовать fake-SNI]"
    read -p "Ваш выбор [1]: " tls_choice
    tls_choice=${tls_choice:-1}
    echo "--------------------------------------------------"

    # Создаем директорию
    if ! mkdir -p "$HYSTERIA_CONFIG_DIR"; then 
        error_msg "Не удалось создать ${HYSTERIA_CONFIG_DIR}"
        return 1
    fi

    # Обработка TLS и определение финальных параметров для сохранения
    if [[ "$tls_choice" == "1" ]]; then
        # --- ACME (Внешний) ---
        is_external_acme_flag="true"
        local has_cert
        read -p "У вас уже есть готовые файлы сертификата (fullchain.pem/private.key)? (y/N): " has_cert

        if [[ "$has_cert" =~ ^[Yy]$ ]]; then
            read -p "Введите доменное имя, для которого выдан сертификат: " domain_name
            
            if [[ -z "$domain_name" ]]; then 
                error_msg "Домен пуст."
                return 1
            fi
            
            server_addr=$domain_name
            final_sni=$domain_name # Устанавливаем финальный SNI
            final_insecure="0"     # ACME -> проверка включена

            local default_cert_path="/root/my_cert/${domain_name}/fullchain.pem"
            local default_key_path="/root/my_cert/${domain_name}/private.key"
            
            read -p "Путь к cert (${domain_name}) [${default_cert_path}]: " cert_path
            cert_path=${cert_path:-$default_cert_path}
            
            read -p "Путь к key (${domain_name}) [${default_key_path}]: " key_path
            key_path=${key_path:-$default_key_path}

            if [[ ! -r "$cert_path" ]]; then 
                error_msg "Сертификат не найден/не читается: ${cert_path}"
                return 1
            fi
            
            if [[ ! -r "$key_path" ]]; then 
                error_msg "Ключ не найден/не читается: ${key_path}"
                return 1
            fi
            
            info_msg "Используются внешние сертификаты для ${domain_name}:"
            echo "  Cert: ${cert_path}"
            echo "  Key:  ${key_path}"
        else
            # Запускаем внешний скрипт и выходим
            info_msg "Запуск внешнего скрипта для получения сертификата..."
            local ext_script_url="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/cloudflare_ssl.sh"
            local ext_script="/tmp/cloudflare_ssl.sh"
            
            info_msg "Скачивание ${ext_script_url}..."
            
            if ! wget -q "$ext_script_url" -O "$ext_script"; then 
                error_msg "Ошибка скачивания скрипта."
            else
                chmod +x "$ext_script"
                info_msg "Запуск bash ${ext_script}..."
                
                if bash "$ext_script"; then 
                    info_msg "Скрипт завершился."
                else 
                    warning_msg " Скрипт завершился неуспешно или отменен."
                fi
                
                rm -f "$ext_script"
            fi
            
            warning_msg " Возврат в главное меню. Выберите опцию снова после проверки результата работы скрипта."
            return 0 # ВЫХОД
        fi
    else
        # --- Self-signed ---
        is_external_acme_flag="false"
        server_addr=$(get_public_ip)
        
        if [[ $? -ne 0 ]]; then 
            return 1
        fi
        
        info_msg "IP: ${server_addr}"
        info_msg "Генерация self-signed..."
        cert_path="$DEFAULT_CERT_PATH"
        key_path="$DEFAULT_KEY_PATH" # Устанавливаем пути
        
        if ! openssl ecparam -genkey -name prime256v1 -out "$key_path"; then 
            error_msg "Ошибка ключа."
            return 1
        fi
        
        if ! openssl req -new -x509 -days 3650 -key "$key_path" -out "$cert_path" -subj "/CN=hysteria"; then 
            error_msg "Ошибка сертификата."
            rm -f "$key_path"
            return 1
        fi
        
        info_msg "Сертификат сгенерирован."
        info_msg "Установка прав..."
        
        if ! chmod 600 "$key_path"; then 
            warning_msg " Ошибка прав ключа."
        fi
        
        if ! chmod 644 "$cert_path"; then 
            warning_msg " Ошибка прав серт."
        fi
        
        final_sni=""           # SNI не используется
        final_insecure="1"     # Self-signed -> проверка отключена
        # Генерируем отпечаток для сохранения
        final_fingerprint=$(openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | cut -d'=' -f2)
    fi
    echo "--------------------------------------------------"

    # 3. Установка бинарника Hysteria
    info_msg "Установка бинарника (get.hy2.sh)..."
    local url="https://get.hy2.sh/"
    local script="/tmp/hysteria_install.sh"
    
    if ! curl -fsSL "$url" -o "$script" > /dev/null 2>&1; then 
        error_msg "Ошибка скачивания $url"
        return 1
    fi
    
    chmod +x "$script"
    
    if ! bash "$script" > /dev/null 2>&1; then 
        error_msg "Ошибка установки."
        rm -f "$script"
        return 1
    fi
    
    rm -f "$script"
    
    if [[ ! -f "$HYSTERIA_BIN_PATH" ]]; then 
        error_msg "${HYSTERIA_BIN_PATH} не найден!"
        return 1
    fi
    
    if [[ ! -x "$HYSTERIA_BIN_PATH" ]]; then 
        warning_msg " ${HYSTERIA_BIN_PATH} не исполняемый!"
        
        if ! chmod +x "$HYSTERIA_BIN_PATH"; then 
            error_msg "Не удалось исправить права."
            return 1
        fi
    fi

    # 4. Создание файла конфигурации
    info_msg "Создание ${HYSTERIA_CONFIG_FILE}..."
    > "$HYSTERIA_CONFIG_FILE"
    
    printf "listen: :%s\n\n" "$hysteria_port" >> "$HYSTERIA_CONFIG_FILE"
    printf "tls:\n  cert: %s\n  key: %s\n\n" "$cert_path" "$key_path" >> "$HYSTERIA_CONFIG_FILE"
    printf "auth:\n  type: password\n  password: %s\n\n" "$hysteria_password" >> "$HYSTERIA_CONFIG_FILE"
    
    if [[ -n "$bw_up" || -n "$bw_down" ]]; then
        printf "bandwidth:\n"
        
        if [[ -n "$bw_up" ]]; then 
            printf "  up: %s\n" "$bw_up" >> "$HYSTERIA_CONFIG_FILE"
        fi
        
        if [[ -n "$bw_down" ]]; then 
            printf "  down: %s\n" "$bw_down" >> "$HYSTERIA_CONFIG_FILE"
        fi
        
        printf "\n" >> "$HYSTERIA_CONFIG_FILE"
    fi
    
    printf "# Доп. настройки:\n# masquerade: ...\n" >> "$HYSTERIA_CONFIG_FILE"
    
    if [[ $? -ne 0 ]]; then 
        error_msg "Ошибка записи ${HYSTERIA_CONFIG_FILE}"
        return 1
    fi

    # 5. Настройка UFW
    info_msg "Настройка UFW..."
    
    if command_exists ufw; then
        if ! ufw allow ssh > /dev/null; then 
            warning_msg " Ошибка правила SSH."
        fi
        
        ufw delete allow ${hysteria_port}/udp > /dev/null 2>&1
        
        if ! ufw allow ${hysteria_port}/udp > /dev/null; then 
            error_msg "Ошибка правила ${hysteria_port}/udp."
        fi
        
        ufw delete allow 80/tcp > /dev/null 2>&1 # Порт 80 не нужен
        
        if ! ufw status | grep -qw active; then 
            info_msg "Включение UFW..."
            
            if ! ufw --force enable; then 
                error_msg "Ошибка включения UFW."
            fi
            
            if ! ufw reload > /dev/null; then
                warning_msg " Ошибка перезагрузки UFW."
            fi
        fi
        
    else 
        warning_msg " UFW не найден."
        warning_msg " Порт ${hysteria_port}/udp должен быть открыт!"
    fi

    # 6. Создание systemd сервиса
    info_msg "Настройка systemd..."
    
    cat << EOF > "$HYSTERIA_SERVICE_FILE"
[Unit]
Description=Hysteria v2 Server Service
Documentation=https://v2.hysteria.network/
After=network.target
[Service]
Type=simple
ExecStart=${HYSTERIA_BIN_PATH} server --config ${HYSTERIA_CONFIG_FILE}
WorkingDirectory=${HYSTERIA_CONFIG_DIR}
User=root
Group=root
RestartSec=10
Restart=on-failure
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    
    if [[ $? -ne 0 ]]; then 
        error_msg "Ошибка записи ${HYSTERIA_SERVICE_FILE}"
        return 1
    fi

    # 7. Перезагрузка и запуск сервиса
    info_msg "Перезагрузка systemd..."
    systemctl daemon-reload
    
    if ! systemctl enable hysteria-server > /dev/null 2>&1; then 
        warning_msg " Ошибка enable."
    fi
    
    info_msg "Перезапуск Hysteria..."
    
    if ! systemctl restart hysteria-server; then 
        error_msg "Ошибка restart!"
        error_msg "Логи: journalctl -u hysteria-server -n 50"
        return 1
    fi
    
    sleep 3

    # 8. Проверка статуса сервиса
    info_msg "Проверка статуса..."
    
    if ! systemctl is-active --quiet hysteria-server; then
        error_msg "Сервис не запустился."
        error_msg "Логи: journalctl -u hysteria-server -e"
        return 1
    fi
    
    info_msg "Сервис Hysteria запущен!"

    # 9. СОХРАНЕНИЕ ДАННЫХ ДЛЯ ПОДКЛЮЧЕНИЯ
    info_msg "Сохранение данных для подключения в ${HYSTERIA_CONN_INFO_FILE}..."
    # Используем printf для корректной записи значений с кавычками/спецсимволами
    {
        printf "PROFILE_NAME=%q\n" "${profile_name}"
        printf "SERVER_ADDR=%q\n" "${server_addr}"
        printf "SERVER_PORT=%q\n" "${hysteria_port}"
        printf "PASSWORD=%q\n" "${hysteria_password}"
        printf "SNI=%q\n" "${final_sni}"
        printf "INSECURE=%q\n" "${final_insecure}"
        printf "BW_UP=%q\n" "${bw_up}"
        printf "BW_DOWN=%q\n" "${bw_down}"
        printf "FINGERPRINT=%q\n" "${final_fingerprint}"
        printf "IS_EXTERNAL_ACME=%q\n" "${is_external_acme_flag}" # Сохраняем флаг
    } > "$HYSTERIA_CONN_INFO_FILE"

    if [[ $? -ne 0 ]]; then
        error_msg "Не удалось сохранить данные для подключения в ${HYSTERIA_CONN_INFO_FILE}."
        # Не прерываем, но show_connection_info может показать не то
    else
        # Устанавливаем права на файл
        chmod 600 "$HYSTERIA_CONN_INFO_FILE"
    fi

    # 10. Показ данных
    show_connection_info # Вызываем показ данных

    return 0
}

# Функция удаления Hysteria 2 (без подтверждения)
uninstall_hysteria() {
    info_msg "--- Удаление Hysteria v2 ---"
    
    if ! is_hysteria_installed; then
        warning_msg "Hysteria не установлена."
        return 0
    fi

    info_msg "Остановка/отключение сервиса..."
    systemctl stop hysteria-server > /dev/null 2>&1
    systemctl disable hysteria-server > /dev/null 2>&1

    info_msg "Удаление файла сервиса..."
    rm -f "$HYSTERIA_SERVICE_FILE"
    systemctl daemon-reload > /dev/null 2>&1

    info_msg "Удаление бинарника..."
    rm -f "$HYSTERIA_BIN_PATH"

    local port
    if [[ -f "$HYSTERIA_CONFIG_FILE" ]]; then
        port=$(get_config_value "listen:" | sed 's/.*://')
    fi

    info_msg "Удаление конфига и данных подключения..."
    rm -rf "$HYSTERIA_CONFIG_DIR" # Удалит и config.yaml, и connection_info.dat

    if command_exists ufw; then
        info_msg "Удаление правил UFW..."
        local reload_needed=false
        
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            info_msg "Порт UDP ${port}..."
            
            if ufw delete allow ${port}/udp > /dev/null 2>&1; then
                reload_needed=true
            fi
        else
            warning_msg " Порт UDP не найден."
        fi
        
        # Порт 80 не трогаем
        if $reload_needed; then
            info_msg "Перезагрузка UFW..."
            
            if ! ufw reload > /dev/null; then
                warning_msg " Ошибка перезагрузки UFW."
            fi
        fi
    else
        warning_msg " UFW не найден."
    fi
    
    info_msg "Удаление завершено!"
    return 0
}

# Функция отображения информации для подключения (читает из файла)
show_connection_info() {
    # Проверяем основную установку
    if ! is_hysteria_installed; then
        error_msg "Hysteria не установлена. Используйте опцию '1' для установки."
        return 1
    fi

    # Создаем временный файл для безопасного чтения
    local tmpfile=$(mktemp)
    # Копируем и добавляем экспорт к переменным для безопасного использования source
    sed 's/^\([A-Z_]*\)=/export \1=/' "$HYSTERIA_CONN_INFO_FILE" > "$tmpfile"
    
    # Используем source для загрузки переменных
    source "$tmpfile"
    rm -f "$tmpfile"
    
    # Проверяем, что ключевые переменные загрузились
    if [[ -n "$SERVER_ADDR" && -n "$SERVER_PORT" && -n "$PASSWORD" ]]; then
        profile_name="$PROFILE_NAME"
        server_addr="$SERVER_ADDR"
        server_port="$SERVER_PORT"
        password="$PASSWORD"
        sni="$SNI"
        insecure="$INSECURE"
        bw_up="$BW_UP"
        bw_down="$BW_DOWN"
        fingerprint="$FINGERPRINT"
        is_external_acme="$IS_EXTERNAL_ACME"
        read_from_file_ok=true
    else
        warning_msg " Не удалось прочитать основные данные из ${HYSTERIA_CONN_INFO_FILE}. Попытка чтения из config.yaml..."
    fi

    # Проверка зависимостей (после попытки чтения/определения)
    local jq_found=true
    local qrencode_found=true
    
    if ! command_exists jq; then 
        warning_msg " jq не найден."
        jq_found=false
    fi
    
    if ! command_exists qrencode; then 
        warning_msg " qrencode не найден."
        qrencode_found=false
    fi

    # Финальные проверки адреса
    if [[ "$server_addr" == "<ERR>" ]]; then 
        error_msg "Не удалось определить адрес сервера."
        return 1
    fi

    # Скорость
    local up_mbps down_mbps
    up_mbps=$(get_mbps "$bw_up")
    down_mbps=$(get_mbps "$bw_down")

    # Имя профиля
    local profile_name_to_show=${profile_name:-"Hysteria_$(hostname -s)_${server_port}"} # Запасной вариант имени

    # Вывод информации
    echo "--------------------------------------------------"
    echo -e "  ${YELLOW}Имя профиля:     ${NC} ${GREEN}${profile_name_to_show}${NC}"
    echo -e "  ${YELLOW}Адрес сервера:   ${NC} ${GREEN}${server_addr}:${server_port}${NC}"
    echo -e "  ${YELLOW}Пароль:          ${NC} ${GREEN}${password}${NC}"
    echo -e "  ${YELLOW}SNI:             ${NC} ${GREEN}${sni:-<пусто>}${NC}"
    
    if [[ "$insecure" == "0" ]]; then # Используем значение из файла/fallback
        echo -e "  ${YELLOW}Проверка серт.:  ${NC} ${GREEN}Включена (insecure=0)${NC}"
    else
        echo -e "  ${YELLOW}Проверка серт.:  ${NC} ${RED}Отключена (insecure=1)${NC}"
        
        if [[ -n "$fingerprint" ]]; then # Отпечаток есть только для self-signed
            echo -e "  ${YELLOW}Отпечаток SHA256:${NC} ${GREEN}${fingerprint}${NC}"
        fi
    fi
    
    echo -e "  ${YELLOW}Лимит Upload:    ${NC} ${GREEN}${bw_up:-Без лимита}${NC}"
    echo -e "  ${YELLOW}Лимит Download:  ${NC} ${GREEN}${bw_down:-Без лимита}${NC}"
    echo "--------------------------------------------------"
    
    # Формируем URL без использования дополнительных переменных
    v2rayng_url="hysteria2://${password}@${server_addr}:${server_port}?sni=${sni}&insecure=${insecure}"
    
    if [[ -n "$up_mbps" ]]; then 
        v2rayng_url+="&upmbps=${up_mbps}"
    fi
    
    if [[ -n "$down_mbps" ]]; then 
        v2rayng_url+="&downmbps=${down_mbps}"
    fi
    
    local remark_name_encoded=$(echo "$profile_name_to_show" | sed 's/ /%20/g')
    v2rayng_url+="#${remark_name_encoded}"
    
    echo -e "${YELLOW}Ссылка V2RayNG:${NC}"
    echo -e "${GREEN}${v2rayng_url}${NC}"
    echo "--------------------------------------------------"
    echo -e "${YELLOW}QR-код V2RayNG:${NC}"
    
    if $qrencode_found; then 
        qrencode -t ANSIUTF8 "${v2rayng_url}"
        echo -e "${YELLOW}(Может искажаться)${NC}"
    else 
        warning_msg " qrencode не найден."
    fi
    
    echo "--------------------------------------------------"
    # JSON конфиг убран по запросу
    info_msg "Полезные команды:"
    echo -e "  Логи: ${GREEN}journalctl -u hysteria-server -f${NC}"
    echo -e "  Конфиг: ${GREEN}cat ${HYSTERIA_CONFIG_FILE}${NC}"
    echo -e "  Статус: ${GREEN}systemctl status hysteria-server${NC}"
    echo -e "  Рестарт: ${GREEN}systemctl restart hysteria-server${NC}"
    echo -e "  Стоп: ${GREEN}systemctl stop hysteria-server${NC}"

    return 0
}

# --- Главное меню и точка входа ---
main_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}   Меню управления Hysteria v2     ${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e " ${YELLOW}1.${NC} Установить / Перенастроить"
    echo -e " ${YELLOW}2.${NC} Удалить"
    echo -e " ${YELLOW}3.${NC} Показать данные"
    echo -e " ${YELLOW}0.${NC} Выйти" # Выход по 0
    echo "-------------------------------------"
    
    if is_hysteria_installed; then
        if systemctl is-active --quiet hysteria-server; then
            echo -e " Статус: ${GREEN}Запущено${NC}"
        else
            echo -e " Статус: ${YELLOW}Остановлено${NC}"
            warning_msg " Сервис неактивен."
        fi
    else
        echo -e " Статус: ${RED}Не установлено${NC}"
    fi
    
    echo "-------------------------------------"
    local choice
    read -p "Выберите опцию [0-3]: " choice # Изменен диапазон
    
    case $choice in
        1) install_hysteria ;;
        2) uninstall_hysteria ;;
        3) show_connection_info ;;
        0) info_msg "Выход."; exit 0 ;; # Выход по 0
        *) error_msg "Неверный выбор." ;;
    esac
    
    echo ""
    read -p "Нажмите Enter для возврата..."
}

# --- Запуск скрипта ---
if [[ $EUID -ne 0 ]]; then 
    error_msg "Запуск от root!"
    exit 1
fi

while true; do 
    main_menu
done
