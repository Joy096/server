#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

INSTALL_DIR="/var/www/lampa" # Директория для готовых файлов Lampa (веб-сервер)
SOURCE_DIR="/opt/lampa" # Директория для клонированного репозитория (с готовыми файлами)
NGINX_CONF_NAME="lampa" # Имя файла конфигурации Nginx
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF_FILE="$NGINX_SITES_AVAILABLE/$NGINX_CONF_NAME"
REPO_URL="https://github.com/yumata/lampa.git" # Репозиторий с ГОТОВЫМИ файлами Lampa
DEFAULT_PORT=80 # Порт по умолчанию
LOG_FILE="/root/lampa_update.log" # Лог файл для автообновления
CRON_MARKER="# LAMPACRON_GITHUB_AUTOUPDATE" # Маркер для cron задачи
# URL скрипта обновления (предоставлен пользователем)
GITHUB_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa_update.sh"
# URL скрипта установки Torrserver
TORRSERVER_SCRIPT_URL="https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh"

# Проверка запуска от root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Ошибка: Этот скрипт должен выполняться от root!"
    echo "ℹ️ Пожалуйста, переключитесь на root ('su -' или 'sudo -i') и запустите заново."
    exit 1
fi

# --- Учёт того, что поставил скрипт (нужен для удаления по компонентам) ---
STATE_FILE="/etc/lampa-setup.state"
PKGS_ADDED=""   # пакеты, которых не было до установки Lampa (в том числе nginx)

load_state() { [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"; }
save_state() {
    echo "PKGS_ADDED=$(printf '%q' "$PKGS_ADDED")" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}
load_state

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# Вопрос с ответом y/N (Enter = нет)
ask_no() {
    local a
    read -rp "$1 [y/N, Enter = N (нет)]: " a
    [[ "$a" =~ ^[YyДд]$ ]]
}

# Порт, на котором Lampa слушает в nginx (пусто, если конфига нет)
lampa_port() {
    awk '$1=="listen" && $2 ~ /^[0-9]+;$/ {gsub(";","",$2); print $2; exit}' "$NGINX_CONF_FILE" 2>/dev/null
}

# Какие программы на сервере используют nginx, кроме Lampa (она удаляется сейчас).
# Печатает по строке «  • что именно» на каждую найденную программу; если таких нет, не печатает ничего.
nginx_other_users() {
    local f n found=0 pkgs
    if [[ -f /etc/systemd/system/jackett-tls.service || -f /etc/jackett-cert/nginx.conf ]]; then
        echo "  • HTTPS для Jackett (служба jackett-tls, конфиг /etc/jackett-cert/nginx.conf)"; found=1
    fi
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [[ -e "$f" ]] || continue
        n=$(basename "$f")
        case "$n" in default|"$NGINX_CONF_NAME") continue ;; esac
        echo "  • другой сайт nginx: $f"; found=1
    done
    pkgs=$(apt-cache rdepends --installed nginx 2>/dev/null | awk '/^  /{gsub(/[| ]/,""); print}' | grep -Ev '^(lib)?nginx' | sort -u | tr '\n' ' ')
    if [[ -n "${pkgs// /}" ]]; then
        echo "  • пакеты, которым нужен nginx: ${pkgs}"; found=1
    fi
}

# Удаляет пакет nginx. Если им пользуются другие программы, показывает какие, предупреждает и спрашивает подтверждение
# (Enter = нет). Возвращает 0, если пакет удалён, и 1, если оставлен.
purge_nginx_checked() {
    local others
    others=$(nginx_other_users)
    if [[ -n "$others" ]]; then
        echo "⚠️ Пакет nginx нужен и другим программам на этом сервере:"
        echo "$others"
        echo "   Если удалить пакет, эти программы перестанут работать."
        if ! ask_no "Всё равно удалить пакет nginx?"; then
            echo "ℹ️ Пакет nginx оставлен."
            return 1
        fi
    fi
    systemctl stop nginx &> /dev/null
    apt-get purge -y 'nginx*' > /dev/null 2>&1
    return 0
}

# Проверка доступности порта
is_port_available() {
    local port="$1"
    if ss -tuln | grep -q ":$port\\s"; then
        return 1 # Порт занят
    else
        return 0 # Порт свободен
    fi
}

# Запрос порта у пользователя
ask_for_port() {
    local chosen_port=$DEFAULT_PORT
    while true; do
        read -p "Введите порт для Lampa (по умолчанию ${DEFAULT_PORT}): " input_port
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

# Функция установки Lampa
install_lampa_simple() {
    echo ""
    echo "Установка Lampa"

    # Проверка существующей установки
    if [[ -d "$INSTALL_DIR" || -f "$NGINX_CONF_FILE" || -d "$SOURCE_DIR" ]]; then
        read -p "Похоже, Lampa уже установлена. Переустановить? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then # Добавим русские 'Д/д'
            echo "Отмена переустановки."
            return 1 # Возвращаем код ошибки для индикации отмены
        fi
        echo "Продолжение переустановки..."
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
    echo "Запрос порта для Nginx..."
    nginx_port=$(ask_for_port) # Получаем ТОЛЬКО номер порта
    if [[ -z "$nginx_port" ]]; then
        echo "❌ Ошибка: Порт не был определен."; return 1;
    fi
    # Выводим сообщение об успехе ЗДЕСЬ:
    echo "✅ Порт ${nginx_port} выбран и свободен."

    # Установка минимально необходимых пакетов
    echo ""
    echo "Обновление списка пакетов и установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive # Как в примере, для неинтерактивной установки
    # Скрываем вывод apt update, но выводим apt install
    apt update > /dev/null
    # Запоминаем пакеты, которых раньше не было: при удалении Lampa предложим убрать только их
    local pkg newly=()
    for pkg in git nginx curl wget ca-certificates; do
        pkg_installed "$pkg" || newly+=("$pkg")
    done
    apt install -y git nginx curl wget ca-certificates || { echo "❌ ОШИБКА: Не удалось установить пакеты."; return 1; }
    for pkg in "${newly[@]}"; do
        if pkg_installed "$pkg" && [[ " $PKGS_ADDED " != *" $pkg "* ]]; then
            PKGS_ADDED="${PKGS_ADDED:+$PKGS_ADDED }$pkg"
        fi
    done
    save_state

    # Клонирование репозитория с ГОТОВЫМИ файлами
    echo ""
    echo "Клонирование готовых файлов Lampa"
    if [[ -d "$SOURCE_DIR" ]]; then
        rm -rf "$SOURCE_DIR"
    fi
    # Используем git clone, проверяем результат
    git clone "${REPO_URL}" "${SOURCE_DIR}" || { echo "❌ ОШИБКА: 'git clone' не удался."; return 1; }

    # Подготовка веб-директории и копирование
    echo ""
    echo "Создание/очистка директории веб-сервера: ${INSTALL_DIR}"
    mkdir -p "$INSTALL_DIR" || { echo "❌ Не удалось создать ${INSTALL_DIR}"; return 1; }
    rm -rf "${INSTALL_DIR}"/* || { echo "❌ Не удалось очистить ${INSTALL_DIR}"; return 1; }
    echo "Копирование ГОТОВЫХ файлов Lampa в ${INSTALL_DIR}..."
    shopt -s dotglob # Включаем копирование скрытых файлов
    cp -r "${SOURCE_DIR}"/* "${INSTALL_DIR}/" || { echo "❌ Не удалось скопировать файлы Lampa."; shopt -u dotglob; return 1; }
    shopt -u dotglob # Выключаем обратно
    rm -rf "${INSTALL_DIR}/.git" # Удаляем .git из целевой директории

    # Настройка Nginx (остается такой же)
    echo ""
    echo "Настройка Nginx..."
    rm -f "$NGINX_SITES_ENABLED/default" "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME"
    # Создание конфига Nginx
    cat << EOF > "$NGINX_CONF_FILE"
server {
    listen ${nginx_port};
    listen [::]:${nginx_port};
    server_name _;
    root ${INSTALL_DIR};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
    # Подобные заголовки "разрешают все", что может быть вопросом безопасности,
    # но они необходимы для некоторых функций Lampa
    add_header Access-Control-Allow-Origin "*";
    add_header Access-Control-Allow-Headers "*";
    add_header Access-Control-Allow-Methods "*";
}
EOF
    if [ $? -ne 0 ]; then
        echo "❌ ОШИБКА: Не удалось создать файл Nginx конфигурации!"
        return 1
    fi
    
    # Проверка конфигурации и связывание её
    ln -sf "$NGINX_CONF_FILE" "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME" || {
        echo "❌ ОШИБКА: Не удалось создать символическую ссылку в sites-enabled!";
        return 1;
    }

    if ! nginx -t; then
        echo "❌ ОШИБКА: Неверная конфигурация Nginx!"
        return 1
    fi

    # Запуск Nginx
    echo ""
    echo "Запуск Nginx..."
    systemctl restart nginx || {
        echo "❌ ОШИБКА: Не удалось запустить Nginx!";
        return 1;
    }

    # Добавление правила UFW, если UFW установлен и активен
    echo ""
    echo "Настройка UFW..."
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            # Сначала удалим старое правило на всякий случай
            ufw delete allow proto tcp to any port "${nginx_port}" comment 'Lampa HTTP' &> /dev/null
            ufw allow "${nginx_port}/tcp" comment "Lampa HTTP" || echo "⚠️ Не удалось добавить правило UFW."
            echo "✅ Правило UFW для TCP ${nginx_port} добавлено."
        else
            echo "ℹ️ UFW установлен, но не активен. Правило не добавлено."
        fi
    else
        echo "ℹ️ UFW не установлен. Откройте порт ${nginx_port} вручную."
    fi

    # Добавление Cron задачи
    echo ""
    echo "Добавление задачи автообновления в cron (ежедневно в 3:00)..."
    ( crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; \
      echo "0 3 * * * curl -sL '$GITHUB_SCRIPT_URL' | bash > '$LOG_FILE' $CRON_MARKER" ) | crontab - || { echo "❌ ОШИБКА: Не удалось добавить задачу в cron."; }
    echo "✅ Задача Cron добавлена."

    # Финальное сообщение
    echo ""
    echo "Автообновление настроено."
    echo "Клон репозитория с готовыми файлами: ${SOURCE_DIR}"
    echo "✅ Установка Lampa успешно завершена!"
    echo ""
    show_address_internal "$nginx_port" # Показываем адрес в конце
    return 0
}

# --- Удаление по компонентам ---

# Задача автообновления в cron и её журнал
rm_lampa_cron() {
    echo ""
    echo "Удаление задачи cron..."
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
        crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab - || echo "⚠️ Не удалось удалить cron."
    else
        echo "ℹ️ Cron не найден."
    fi
    echo "Удаление ${LOG_FILE}...";
    rm -f "$LOG_FILE"
}

# Сайт Lampa в nginx. Параметр "no_reload": не трогать работу nginx (пакет сейчас будет удалён).
rm_lampa_site() {
    echo "Удаление Nginx конфига..."
    rm -f "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME" "$NGINX_CONF_FILE"
    [[ "$1" == "no_reload" ]] && return 0
    command -v nginx &> /dev/null || return 0
    nginx -t || echo "ℹ️ Конфиг Nginx пуст/некорректен."
    systemctl reload nginx || echo "ℹ️ Nginx не активен/reload не удался."
    if ! systemctl is-active --quiet nginx; then
        if systemctl list-unit-files | grep -q 'nginx.service'; then
            echo "⚠️ Nginx не активен. Запуск...";
            systemctl start nginx || echo "❌ Не удалось запустить Nginx."
        fi
    fi
}

# Файлы Lampa и клон репозитория
rm_lampa_files() {
    echo ""
    echo "Удаление ${INSTALL_DIR}...";
    rm -rf "$INSTALL_DIR"
    echo "Удаление ${SOURCE_DIR}...";
    rm -rf "$SOURCE_DIR"
}

# Порты правил UFW с комментарием "Lampa HTTP" (по одному в строке)
lampa_ufw_ports() {
    command -v ufw &> /dev/null || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
    ufw status 2>/dev/null | grep 'Lampa HTTP' | awk '{print $1}' | grep -Eo '^[0-9]+' | sort -u
}

# Правило UFW (если оно было создано этим скриптом: у него комментарий "Lampa HTTP")
rm_lampa_ufw() {
    local p
    for p in $(lampa_ufw_ports); do
        if ufw --force delete allow "${p}/tcp" &> /dev/null; then
            echo "✅ Правило UFW для порта ${p} удалено."
        else
            echo "ℹ️ Правило UFW для порта ${p} (Lampa HTTP) не найдено."
        fi
    done
}

# Функция удаления Lampa без вопросов (нужна при переустановке): всё, кроме пакетов
uninstall_lampa_internal() {
    if [[ ! -f "$NGINX_CONF_FILE" && ! -d "$INSTALL_DIR" && ! -d "$SOURCE_DIR" ]]; then
        echo "ℹ️ Lampa не установлена."
        return 0 # Успех, т.к. делать нечего
    fi
    rm_lampa_cron
    rm_lampa_site
    rm_lampa_files
    rm_lampa_ufw
    echo "✅ Удаление Lampa завершено!"
    return 0
}

# Удаление из меню: всё сразу или по компонентам
uninstall_lampa() {
    local has_site=0 has_files=0 has_cron=0 has_ufw=0 has_nginx=0 pkgs="" pkg ports port others sc
    echo ""
    echo "Удаление Lampa"
    [[ -f "$NGINX_CONF_FILE" || -L "$NGINX_SITES_ENABLED/$NGINX_CONF_NAME" ]] && has_site=1
    [[ -d "$INSTALL_DIR" || -d "$SOURCE_DIR" ]] && has_files=1
    if crontab -l 2>/dev/null | grep -q "$CRON_MARKER" || [[ -f "$LOG_FILE" ]]; then has_cron=1; fi
    ports=$(lampa_ufw_ports | tr '\n' ' '); ports="${ports% }"
    [[ -n "$ports" ]] && has_ufw=1
    for pkg in $PKGS_ADDED; do
        pkg_installed "$pkg" || continue
        if [[ "$pkg" == "nginx" ]]; then has_nginx=1; else pkgs="${pkgs:+$pkgs }$pkg"; fi
    done

    if (( has_site + has_files + has_cron + has_ufw + has_nginx == 0 )) && [[ -z "$pkgs" ]]; then
        echo "ℹ️ Удалять нечего: Lampa не установлена."
        rm -f "$STATE_FILE"
        return 0
    fi

    port=$(lampa_port)
    echo "Найдено:"
    (( has_site ))  && echo "  • сайт Lampa в nginx: ${NGINX_CONF_FILE} (порт ${port:-не определён})"
    (( has_files )) && echo "  • файлы Lampa: ${INSTALL_DIR} и клон репозитория ${SOURCE_DIR}"
    (( has_cron ))  && echo "  • автообновление: задача cron (ежедневно в 3:00) и журнал ${LOG_FILE}"
    (( has_ufw ))   && echo "  • правило UFW (Lampa HTTP): порт ${ports}"
    (( has_nginx )) && echo "  • пакет nginx (поставлен скриптом при установке Lampa)"
    [[ -n "$pkgs" ]] && echo "  • другие пакеты, поставленные скриптом: ${pkgs}"
    if (( has_nginx )); then
        others=$(nginx_other_users)
        if [[ -n "$others" ]]; then
            echo "    ⚠️ Пакет nginx нужен и другим программам на этом сервере:"
            echo "$others" | sed 's/^/  /'
            echo "    Пакет будет удалён только после отдельного подтверждения."
        fi
    fi
    if [[ ! -f "$STATE_FILE" ]] && (( has_site + has_files > 0 )); then
        echo "ℹ️ Lampa установлена прежней версией скрипта: пакеты, которые она поставила (nginx, git и др.), не отслеживались"
        echo "   и в список не попали. Чтобы скрипт их учитывал, переустановите Lampa (пункт 1 меню)."
    fi
    echo ""
    echo "1. Всё: вернуть систему к состоянию до установки"
    echo "2. Выбрать по компонентам"
    echo "0. Отмена"
    read -rp "Выберите [0-2]: " sc

    local d_site=0 d_files=0 d_cron=0 d_ufw=0 d_nginx=0 d_pkg=0
    case "$sc" in
        1) d_site=$has_site; d_files=$has_files; d_cron=$has_cron; d_ufw=$has_ufw; d_nginx=$has_nginx; [[ -n "$pkgs" ]] && d_pkg=1 ;;
        2)
            (( has_site ))  && ask_no "Удалить сайт Lampa из nginx?" && d_site=1
            (( has_files )) && ask_no "Удалить файлы Lampa (${INSTALL_DIR} и ${SOURCE_DIR})?" && d_files=1
            (( has_cron ))  && ask_no "Удалить автообновление (cron и журнал)?" && d_cron=1
            (( has_ufw ))   && ask_no "Удалить правило UFW (порт ${ports})?" && d_ufw=1
            (( has_nginx )) && ask_no "Удалить пакет nginx?" && d_nginx=1
            [[ -n "$pkgs" ]] && ask_no "Удалить пакеты (${pkgs})?" && d_pkg=1
            ;;
        *) echo "Отменено."; return 0 ;;
    esac

    # Зависимости: сайт работает только на пакете nginx
    local extra=()
    if (( d_nginx && has_site && !d_site )); then d_site=1; extra+=("сайт Lampa в nginx (он работает только на пакете nginx)"); fi

    if (( d_site + d_files + d_cron + d_ufw + d_nginx + d_pkg == 0 )); then echo "Ничего не выбрано."; return 0; fi

    echo ""
    echo "Будет удалено:"
    (( d_site ))  && echo "  ✗ сайт Lampa в nginx"
    (( d_files )) && echo "  ✗ файлы Lampa и клон репозитория"
    (( d_cron ))  && echo "  ✗ автообновление (cron и журнал)"
    (( d_ufw ))   && echo "  ✗ правило UFW (порт ${ports})"
    (( d_nginx )) && echo "  ✗ пакет nginx (с проверкой, не нужен ли он другим программам)"
    (( d_pkg ))   && echo "  ✗ пакеты: ${pkgs}"
    if (( ${#extra[@]} )); then
        echo "Дополнительно из-за зависимостей:"
        printf '  + %s\n' "${extra[@]}"
    fi
    echo ""
    ask_no "Подтвердите удаление" || { echo "Отменено."; return 0; }

    (( d_cron ))  && rm_lampa_cron
    (( d_site ))  && { if (( d_nginx )); then rm_lampa_site no_reload; else rm_lampa_site; fi; }
    (( d_files )) && rm_lampa_files
    (( d_ufw ))   && rm_lampa_ufw
    if (( d_nginx )); then
        echo ""
        echo "Проверяем пакет nginx: не нужен ли он другим программам..."
        if purge_nginx_checked; then
            echo "✅ Пакет nginx удалён."
        else
            # Пакет оставлен, но сайт мы убирали без перезапуска nginx: применим изменения
            command -v nginx &> /dev/null && systemctl reload nginx &> /dev/null
        fi
    fi
    if (( d_pkg )); then
        echo ""
        echo "Удаление пакетов: ${pkgs}"
        # shellcheck disable=SC2086
        apt-get purge -y $pkgs
        echo "autoremove может затронуть и пакеты, не связанные со скриптом. Список:"
        apt-get -s autoremove --purge 2>/dev/null | grep '^Remove' | sed 's/^Remove /  - /' | head -n 30
        ask_no "Выполнить autoremove?" && apt-get autoremove --purge -y
    fi

    # Оставляем в учёте только то, что ещё стоит
    local left=""
    for pkg in $PKGS_ADDED; do pkg_installed "$pkg" && left="${left:+$left }$pkg"; done
    PKGS_ADDED="$left"
    if [[ -z "$PKGS_ADDED" ]]; then rm -f "$STATE_FILE"; else save_state; fi

    echo ""
    echo "✅ Выбранное удалено."
    if [[ -f "$NGINX_CONF_FILE" || -d "$INSTALL_DIR" || -d "$SOURCE_DIR" || -n "$PKGS_ADDED" ]]; then
        echo "   Остальное можно удалить повторно через этот же пункт."
    fi
    return 0
}

# Функция показа адреса
show_address_internal() {
    local port_to_show=$1
    local public_ip
    # Пытаемся получить внешний IP. Используем -m 5 для таймаута в 5 секунд.
    public_ip=$(curl -s -m 5 ifconfig.me || curl -s -m 5 api.ipify.org || curl -s -m 5 icanhazip.com || echo "")
    if [[ -z "$public_ip" ]]; then
        echo "⚠️ Не удалось определить внешний IP-адрес сервера через ifconfig.me/api.ipify.org/icanhazip.com."
        echo " Показываем локальные IP (могут быть недоступны извне):"
        # В качестве запасного варианта покажем локальные
        local ip_addresses
        ip_addresses=$(ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1')
        if [[ -z "$ip_addresses" ]]; then
            echo "⚠️ Не удалось определить и локальные IP-адреса."
            return 1
        fi
        for ip in $ip_addresses; do
            echo " http://${ip}:${port_to_show}"
        done
        return 1 # Возвращаем ошибку, т.к. основной метод не сработал
    fi
    echo "Адрес сервера: http://${public_ip}:${port_to_show}"
}

show_address() {
    local detected_port=""
    echo ""
    if [[ -f "$NGINX_CONF_FILE" ]]; then
        detected_port=$(lampa_port)
        if [[ -n "$detected_port" ]]; then
            show_address_internal "$detected_port"
        else
            echo "⚠️ Конфиг найден, порт не определен."
        fi
    else
        echo "ℹ️ Конфиг Nginx не найден."
    fi
}

# Функция запуска скрипта Torrserver
run_torrserver_script() {
    # -O: новый файл записывается поверх старого (без -O wget сохранил бы его как torrserver.sh.1, а запустился бы старый)
    if wget -O torrserver.sh "$TORRSERVER_SCRIPT_URL"; then
        chmod +x torrserver.sh
        bash torrserver.sh
    else
        echo "❌ Ошибка при скачивании скрипта Torrserver."
    fi
}

# --- Основная часть скрипта (Меню) ---
while true; do
    echo ""
    echo " ======== Меню Lampa ======== "
    echo " 1. Установить / Переустановить Lampa"
    echo " 2. Удалить Lampa (всё или по компонентам)"
    echo " 3. Показать адрес сервера Lampa"
    echo " 4. Torrserver (Установка/Управление)"
    echo " 0. Выход"
    echo ""
    read -p "Введите номер действия (0-4): " choice
    case $choice in
        1) install_lampa_simple ;; # Используем простую установку
        2) uninstall_lampa ;;
        3) show_address ;;
        4) run_torrserver_script
           continue ;;
        0) echo "Выход."
           echo ""
           exit 0 ;;
        *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
    esac
    echo ""
    read -p "Нажмите Enter для продолжения..." enter_key
done
