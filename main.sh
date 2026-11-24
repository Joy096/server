#!/bin/bash
# main.sh - общее меню: запускает нужный скрипт из репозитория Joy096/server
#
# Запуск одной строкой:
#   wget -O main.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/main.sh && bash main.sh
#
# Каждый пункт скачивает свежую версию выбранного скрипта с GitHub во временный файл
# и запускает его. Когда скрипт закончит работу (обычно его пункт 0), вы вернётесь сюда.
#
# Как добавить новый скрипт: одна строка в список ITEMS ниже, в формате
#   "Раздел|Название пункта|имя_файла.sh"
# Номера пунктов расставляются сами по порядку строк. Подряд идущие строки с одним
# и тем же разделом печатаются под одним заголовком.

BASE_URL="${SERVER_BASE_URL:-https://raw.githubusercontent.com/Joy096/server/refs/heads/main}"

ITEMS=(
    "Подготовка сервера|Базовая настройка нового сервера|server_new.sh"
    "Подготовка сервера|SSL-сертификаты и HTTPS|ssl.sh"
    "Oracle Cloud|Oracle: поиск, создание, редактирование серверов|oracle.sh"
    "Oracle Cloud|Keepalive: защита от отключения за простой|keepalive.sh"
    "Торренты и кино|TorrServer + VPN|torrserver.sh"
    "Торренты и кино|qBittorrent + VPN|qbittorrent.sh"
    "Торренты и кино|Jackett: поиск по трекерам|jackett.sh"
    "Торренты и кино|Lampa|lampa.sh"
    "VPN и доступ|3X-UI: панель VPN|x-ui.sh"
    "VPN и доступ|Hysteria 2: VPN-сервер|hysteria.sh"
    "VPN и доступ|Outline VPN|outline_vpn.sh"
    "VPN и доступ|RustDesk: свой сервер удалённого доступа|rustdesk.sh"
    "Прочее|AdGuard Home: блокировка рекламы|adguard_home.sh"
    "Прочее|Minecraft Bedrock: игровые серверы|minecraft_bedrock.sh"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Скачивание файла: curl, а если его нет - wget
fetch() {
    local url="$1" out="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "$url" -o "$out" 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -q -T 30 -O "$out" "$url" 2>/dev/null
    else
        echo -e "${RED}❌ Не найден ни curl, ни wget. Установите один из них: apt install -y curl${NC}"
        return 1
    fi
}

# Скачивает скрипт, проверяет, что это bash-скрипт, и запускает
run_item() {
    local file="$1" title="$2" tmp
    tmp=$(mktemp "/tmp/${file%.sh}.XXXXXX.sh") || { echo -e "${RED}❌ Не удалось создать временный файл.${NC}"; return 1; }

    echo -e "\n${YELLOW}=== ${title} ===${NC}"
    echo "Скачиваю ${file}..."
    if ! fetch "${BASE_URL}/${file}" "$tmp" || [[ ! -s "$tmp" ]] || ! head -n 1 "$tmp" | grep -q '^#!.*bash'; then
        echo -e "${RED}❌ Не удалось скачать ${file} (нет интернета, файла нет в репозитории или это не скрипт).${NC}"
        echo "   Ссылка: ${BASE_URL}/${file}"
        rm -f "$tmp"
        return 1
    fi
    echo -e "${GREEN}✅ Скачан. Запускаю.${NC}\n"
    bash "$tmp"
    rm -f "$tmp"
    echo -e "\n${GREEN}Вы вернулись в общее меню.${NC}"
}

print_menu() {
    local i=0 item group title prev=""
    echo -e "\n${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}   Скрипты Joy096/server${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    for item in "${ITEMS[@]}"; do
        IFS='|' read -r group title _ <<< "$item"
        i=$((i + 1))
        if [[ "$group" != "$prev" ]]; then
            echo -e "\n${YELLOW}=== ${group} ===${NC}"
            prev="$group"
        fi
        echo "${i}. ${title}"
    done
    echo -e "\n0. Выход"
}

while true; do
    print_menu
    read -rp "Выберите пункт [0-${#ITEMS[@]}]: " choice || exit 0

    if [[ "$choice" == "0" ]]; then
        echo "Выход."
        exit 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ITEMS[@]} )); then
        IFS='|' read -r _ title file <<< "${ITEMS[$((choice - 1))]}"
        run_item "$file" "$title"
    elif [[ -z "$choice" ]]; then
        continue
    else
        echo -e "${RED}Неверный пункт. Введите число от 0 до ${#ITEMS[@]}.${NC}"
    fi
done
