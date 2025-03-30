#!/bin/bash
# Скрипт автоматического обновления Lampa (для cron)

# Конфигурация путей (должна совпадать с основным скриптом)
SOURCE_DIR="/opt/lampa"      # Директория с исходниками
INSTALL_DIR="/var/www/lampa" # Директория веб-сервера
REPO_URL="https://github.com/yumata/lampa.git" # На случай, если директории нет

# Логгирование уже настроено в cron задаче (перенаправление >>)
# Не нужно перенаправлять вывод внутри этого скрипта

echo "======================================"
echo "Запуск автообновления Lampa: $(date)"
echo "======================================"

# Проверяем, существует ли директория с исходниками
if [ ! -d "$SOURCE_DIR/.git" ]; then
    echo "Директория $SOURCE_DIR не найдена/не git репозиторий. Клонирование..."
    # Установка ca-certificates нужна для curl https, убедимся что есть
    if ! dpkg -s ca-certificates > /dev/null 2>&1; then
        echo "Установка ca-certificates..."
        apt-get update && apt-get install -y ca-certificates || echo "Не удалось установить ca-certificates"
    fi
    rm -rf "$SOURCE_DIR"
    git clone "$REPO_URL" "$SOURCE_DIR" || { echo "Ошибка: Не удалось клонировать репозиторий."; exit 1; }
    cd "$SOURCE_DIR" || { echo "Ошибка: Не удалось перейти в $SOURCE_DIR"; exit 1; }
else
    # Переходим в директорию
    cd "$SOURCE_DIR" || { echo "Ошибка: Не удалось перейти в $SOURCE_DIR"; exit 1; }

    # Получаем обновления
    echo "--> Получение обновлений из Git..."
    git fetch origin
    DEFAULT_BRANCH=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
    DEFAULT_BRANCH=${DEFAULT_BRANCH:-main} # Запасной вариант - main
    echo "--> Сброс локальных изменений и обновление до origin/$DEFAULT_BRANCH..."
    git checkout "$DEFAULT_BRANCH" || echo "Предупреждение: git checkout $DEFAULT_BRANCH не удался (возможно, уже на ветке)"
    git reset --hard "origin/$DEFAULT_BRANCH" || { echo "Ошибка: git reset --hard не удался"; exit 1; }
    # git pull origin "$DEFAULT_BRANCH" # git pull не нужен после reset --hard
fi

# Установка/обновление зависимостей
echo "--> Установка/обновление Node.js зависимостей (npm install)..."
# Проверяем наличие npm
if ! command -v npm &> /dev/null; then
    echo "Ошибка: команда npm не найдена. Установите Node.js и npm."
    # Попытка установить, если не найдено (требует работающих репозиториев)
     if ! command -v node &> /dev/null; then
        echo "Попытка установить Node.js/npm..."
        apt-get update && apt-get install -y nodejs npm || { echo "Не удалось установить nodejs/npm."; exit 1; }
     else
        echo "Node.js найден, но npm нет. Попробуйте переустановить Node.js."
        exit 1
     fi
fi
if ! npm install --unsafe-perm=true --allow-root --prefer-offline --no-audit --progress=false; then
    echo "Первая попытка npm install не удалась, пробуем с очисткой кэша..."
    npm cache clean --force
    rm -rf node_modules package-lock.json # Удаляем старые зависимости
    npm install --unsafe-perm=true --allow-root --no-audit --progress=false || { echo "Ошибка: npm install окончательно не удался."; exit 1; }
fi


# Сборка проекта
echo "--> Сборка проекта Lampa (npm run build)..."
if ! npm run build --unsafe-perm=true --allow-root; then
    echo "Ошибка: npm run build не удался."
    exit 1
fi

# Проверка наличия директории сборки
if [ ! -d "build" ]; then
  echo "ОШИБКА: Директория 'build' не найдена после сборки."
  exit 1
fi

# Копирование собранных файлов
echo "--> Копирование собранных файлов в $INSTALL_DIR..."
# Создаем директорию веб-сервера, если ее вдруг нет
mkdir -p "$INSTALL_DIR"
# Удаляем старое содержимое перед копированием
shopt -s dotglob # Включаем копирование скрытых файлов (если они есть в build)
rm -rf "$INSTALL_DIR"/*
shopt -u dotglob # Выключаем обратно
cp -r build/* "$INSTALL_DIR/" || { echo "Ошибка: Копирование файлов не удалось."; exit 1; }

# Установка прав доступа
echo "--> Установка прав доступа для $INSTALL_DIR..."
chown -R www-data:www-data "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR"

echo "--> Обновление Lampa успешно завершено: $(date)"
echo ""

exit 0
