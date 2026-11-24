#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен выполняться от root!"
    exit 1
fi

# Функция установки x-ui
install_x-ui() {
    echo ""
    echo "Обновление списка пакетов и установка обновлений..." # Убрали 🔄
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y && apt autoremove -y && apt clean

    # Проверка и установка jq
    if ! command -v jq &>/dev/null; then
       echo "Устанавливаем jq..." # Убрали 📦
       apt install -y jq
    fi

    # Проверка наличия curl
    if ! command -v curl &>/dev/null; then
        echo "⚠️ Утилита curl не найдена. Устанавливаем..."
        apt update && apt install -y curl
        if ! command -v curl &>/dev/null; then
            echo "❌ Не удалось установить curl. Проверьте соединение."
            exit 1
        fi
    fi

    echo ""
    echo "Установка 3x-ui..." # Убрали 🚀
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || { echo "❌ Ошибка установки 3x-ui!"; exit 1; }

    # Получаем порт x-ui
    local info=$(/usr/local/x-ui/x-ui setting -show true)
    XUI_PORT=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')

    if [[ -n "$XUI_PORT" ]]; then
        echo "✅ Порт x-ui: $XUI_PORT"
        # Настройка UFW
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

    # Изменение логина и пароля
    echo ""
    read -p "Изменить логин и пароль для входа в веб-интерфейс? (y/n): " choice # Убрали 🔑
    if [[ "$choice" == "y" || "$choice" == "Y" || "$choice" == "да" ]]; then
        read -rp "Введите логин: " config_account # Убрали 👤
        [[ -z $config_account ]] && config_account=$(date +%s%N | md5sum | cut -c 1-8)
        read -rp "Введите пароль: " config_password # Убрали 🔒
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

    # Изменение корневого пути URL
    echo ""
    read -p "Изменить корневой путь URL адреса панели (webBasePath)? (y/n): " choice # Убрали 🛠️
    if [[ "$choice" == "y" || "$choice" == "Y" || "$choice" == "да" ]]; then
        read -rp "Введите корневой путь URL: " config_webBasePath # Убрали 📂
        /usr/local/x-ui/x-ui setting -webBasePath "${config_webBasePath}" >/dev/null 2>&1
        systemctl restart x-ui
        echo "✅ Корневой путь изменен."
    else
        echo "ℹ️ Изменение пути URL отменено."
    fi

    # Настройка автообновления
    (crontab -l 2>/dev/null; echo "35 4 * * * bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > x-ui_update.log 2>&1") | crontab -
    echo "✅ Автообновление включено. Лог: x-ui_update.log"

    # Вывод данных о сервере
    local username=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'username: .+' | awk '{print $2}')
    local password=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'password: .+' | awk '{print $2}')
    local webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local server_ip=$(curl -s https://api.ipify.org)

    echo ""
    echo "Логин: ${username}" # Убрали 🔹
    echo "Пароль: ${password}" # Убрали 🔹
    echo "Порт: ${port}" # Убрали 🔹
    echo "Корневой путь: ${webBasePath}" # Убрали 🔹
    echo "Сервер: http://${server_ip}:${port}${webBasePath}" # Убрали 🌍
}

# Показ адреса сервера
show_server_address() {
    if [[ -d "/usr/local/x-ui" ]]; then
        local webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
        local port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
        local server_ip=$(curl -s https://api.ipify.org)
        echo "Сервер: http://${server_ip}:${port}${webBasePath}" # Убрали 🌍
    else
        echo "❌ x-ui не установлен в системе."
    fi
}

uninstall_x-ui() {
    echo ""
    echo "Начинаем удаление 3x-ui..." # Убрали 🗑️
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
        echo "⚠️ Не удалось определить порт x-ui. Проверьте настройки вручную."
    fi

    # Удаление задачи автообновления из crontab
    if crontab -l | grep -q "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > x-ui_update.log"; then
        crontab -l | grep -v "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) > x-ui_update.log" | crontab -
        echo "✅ Автообновление отключено."
    else
        echo " ℹ️ Автообновление не настроено."
    fi

    echo "Удаление 3x-ui завершено!" # Убрали 🎉
}

# Главное меню
while true; do
    echo ""
    echo "Выберите действие:" # Убрали 📌
    echo "1. Установить 3x-ui" # Убрали 1️⃣
    echo "2. Удалить 3x-ui" # Убрали 2️⃣
    echo "3. Показать адрес сервера" # Убрали 3️⃣
    echo "4. Установить сертификат для x-ui" # Убрали 4️⃣
    echo "0. Выход" # Убрали 0️⃣
    echo "=============================="
    read -p "Введите номер действия (0-4): " choice # Убрали 👉, изменили диапазон
    case $choice in
        1) install_x-ui ;;
        2) uninstall_x-ui ;;
        3) show_server_address ;;
        4) wget -O ssl.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh && bash ssl.sh ;;
        0) echo "Выход."; echo ""; exit ;; # Убрали 👋
        *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
    esac
done
