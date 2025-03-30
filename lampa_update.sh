#!/bin/bash

# --- ⚙️ Конфигурация ---
SOURCE_DIR="/opt/lampa"                 # 🌳 Директория клона
INSTALL_DIR="/var/www/lampa"            # 📁 Директория веб-сервера
REPO_URL="https://github.com/yumata/lampa.git" # 📦 Репозиторий с ГОТОВЫМИ файлами
TARGET_BRANCH="main"                    # 🎯 Целевая ветка (проверьте актуальность)

# --- 🚀 Начало автообновления ---
echo "" # Добавим пустую строку для отделения от предыдущих запусков в логе
echo "🔄 [$(date '+%Y-%m-%d %H:%M:%S')] Запуск автообновления Lampa..."

# 1. Переход в директорию / Клонирование при необходимости
if ! cd "${SOURCE_DIR}" &> /dev/null; then
  # echo "ℹ️ Директория ${SOURCE_DIR} не найдена. Клонирование..." # Скрыто
  rm -rf "${SOURCE_DIR}"
  git clone --quiet "${REPO_URL}" "${SOURCE_DIR}" || {
    echo "❌ [$(date '+%F %T')] Ошибка: Не удалось клонировать ${REPO_URL}."
    exit 1
  }
  cd "${SOURCE_DIR}" || {
    echo "❌ [$(date '+%F %T')] Ошибка: Не удалось перейти в ${SOURCE_DIR} после клонирования."
    exit 1
  }
fi

# 2. Обновление локального репозитория
# echo "⏬ Обновление репозитория (ветка '${TARGET_BRANCH}')..." # Скрыто
git fetch origin || {
  echo "❌ [$(date '+%F %T')] Ошибка: 'git fetch' не удался."
  exit 1
}
git reset --hard "origin/${TARGET_BRANCH}" || {
  echo "❌ [$(date '+%F %T')] Ошибка: 'git reset --hard' не удался."
  exit 1
}
# Очистка неотслеживаемых файлов и директорий
git clean -fdx

# 3. Копирование обновленных файлов
# echo "📁 Подготовка ${INSTALL_DIR} и копирование файлов..." # Скрыто
if [[ -d "${INSTALL_DIR}" ]]; then
  rm -rf "${INSTALL_DIR}"/* || {
    echo "❌ [$(date '+%F %T')] Не удалось очистить ${INSTALL_DIR}."
    exit 1
  }
else
  mkdir -p "${INSTALL_DIR}" || {
    echo "❌ [$(date '+%F %T')] Не удалось создать ${INSTALL_DIR}."
    exit 1
  }
fi

shopt -s dotglob # Включаем скрытые файлы
cp -r ./* "${INSTALL_DIR}/" || {
  echo "❌ [$(date '+%F %T')] Не удалось скопировать файлы."
  shopt -u dotglob # Выключаем в случае ошибки
  exit 1
}
shopt -u dotglob # Выключаем после успешного копирования
rm -rf "${INSTALL_DIR}/.git" # Удаляем метаданные git

# 4. Установка прав
# echo "🔑 Установка прав..." # Скрыто
chown -R www-data:www-data "$INSTALL_DIR" &> /dev/null
chmod -R 755 "$INSTALL_DIR" &> /dev/null

# 5. Завершение
echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')] Автообновление Lampa завершено успешно."
echo "" # Пустая строка для читаемости лога

exit 0
