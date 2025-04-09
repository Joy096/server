import json
import os
import time
import threading
import requests
import logging
from bs4 import BeautifulSoup
from urllib.parse import quote
from telegram import Update, ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ApplicationBuilder, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler

# Настройка логирования
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

CONFIG_PATH = "/opt/de_liky_bot/config.json"

# Загрузка конфига
def load_config():
    try:
        if not os.path.exists(CONFIG_PATH):
            default_config = {"token": "", "cities": [], "drugs": [], "interval_hours": 12, "chat_ids": []}
            os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
            with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(default_config, f, ensure_ascii=False, indent=4)
            return default_config
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"Ошибка загрузки конфига: {e}")
        return {"token": "", "cities": [], "drugs": [], "interval_hours": 12, "chat_ids": []}

# Сохранение конфига
def save_config(config):
    try:
        os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(config, f, ensure_ascii=False, indent=4)
        return True
    except Exception as e:
        logger.error(f"Ошибка сохранения конфига: {e}")
        return False

config = load_config()

# Приветственное сообщение
WELCOME_TEXT = """Вітаю! Я — 🤖 *Де ліки Bot*.

Я допоможу вам відстежувати наявність потрібних ліків у вибраних містах України через сервіс [tabletki.ua](https://tabletki.ua).

Що я вмію:
🔎 Шукати препарати у вашому місті
➕ Додавати нові міста та ліки для відстеження
📋 Показувати список відстежуваних препаратів
🔔 Повідомляти, коли ліки з'являться в аптеках
⚙️ Налаштовувати інтервал перевірки

*Використовуйте меню або команди для керування ботом.*

_Бажаю здоров'я!_
"""

# Список основных городов Украины для поиска
UKRAINE_CITIES = [
    "Київ", "Харків", "Одеса", "Дніпро", "Донецьк", "Запоріжжя", "Львів", 
    "Кривий Ріг", "Миколаїв", "Маріуполь", "Луганськ", "Вінниця", 
    "Херсон", "Полтава", "Чернігів", "Черкаси", "Житомир", "Суми", 
    "Рівне", "Івано-Франківськ", "Кропивницький", "Тернопіль", "Луцьк", 
    "Ужгород", "Кам'янець-Подільський", "Мелітополь", "Бердянськ", "Нікополь"
]

# Команда /start
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        # Добавляем chat_id в список отслеживаемых
        chat_id = update.effective_chat.id
        if "chat_ids" not in config:
            config["chat_ids"] = []
        if chat_id not in config["chat_ids"]:
            config["chat_ids"].append(chat_id)
            save_config(config)
            
        keyboard = [
            ["🔎 Додати препарат для відстеження"],
            ["📋 Список відстежуваних", "🔎 Перевірити зараз"],
            ["⚙️ Налаштування"]
        ]
        reply_markup = ReplyKeyboardMarkup(keyboard, resize_keyboard=True)
        await update.message.reply_text(WELCOME_TEXT, parse_mode="Markdown", reply_markup=reply_markup)
    except Exception as e:
        logger.error(f"Ошибка в команде start: {e}")
        await update.message.reply_text("Виникла помилка при запуску бота. Спробуйте ще раз.")

# Функция для поиска лекарств через парсинг сайта
def search_drugs(drug_name, city_name=None):
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept-Language': 'uk-UA,uk;q=0.9,ru;q=0.8,en-US;q=0.7,en;q=0.6'
    }
    
    # Формируем URL для поиска
    encoded_drug = quote(drug_name)
    url = f"https://tabletki.ua/uk/search/?q={encoded_drug}"
    if city_name:
        encoded_city = quote(city_name)
        url += f"&city={encoded_city}"
    
    try:
        logger.info(f"Поиск: {drug_name} {f'в {city_name}' if city_name else ''}, URL: {url}")
        response = requests.get(url, headers=headers, timeout=10)
        response.raise_for_status()
        
        soup = BeautifulSoup(response.text, 'html.parser')
        
        # Проверяем наличие результатов поиска
        no_results_selectors = ['.search-result-empty', '.no-results', '.empty-results']
        for selector in no_results_selectors:
            no_results = soup.select(selector)
            if no_results:
                logger.info(f"Ничего не найдено для {drug_name} {f'в {city_name}' if city_name else ''}")
                return []
        
        # Ищем результаты на странице
        results = []
        product_selectors = ['.search-result-item', '.product-item', '.med-item', '.result-item', '.item']
        
        products = []
        for selector in product_selectors:
            products = soup.select(selector)
            if products:
                break
        
        if not products:
            # Если не нашли по селекторам, попробуем найти по атрибутам
            products = soup.find_all('div', class_=lambda c: c and ('item' in c or 'product' in c or 'result' in c))
            # Можно также попробовать найти по тегам
            if not products:
                products = soup.find_all(['div', 'li'], attrs={'data-id': True})
            
        for product in products:
            try:
                # Пробуем разные селекторы для названия
                name_selectors = ['.item-title', '.product-name', '.title', 'h3', 'h2', '.name']
                name_elem = None
                for selector in name_selectors:
                    name_elem = product.select_one(selector)
                    if name_elem:
                        break
                
                # Пробуем получить название из атрибута, если селекторы не сработали
                if not name_elem:
                    name_elem = product.get('data-name') or product.get('title')
                
                name = name_elem.text.strip() if hasattr(name_elem, 'text') else name_elem or "Без назви"
                
                # Пробуем разные селекторы для цены
                price_selectors = ['.price', '.cost', '.product-price', '.money']
                price_elem = None
                for selector in price_selectors:
                    price_elem = product.select_one(selector)
                    if price_elem:
                        break
                
                # Пробуем получить цену из атрибута, если селекторы не сработали
                if not price_elem:
                    price_elem = product.get('data-price')
                
                price = price_elem.text.strip() if hasattr(price_elem, 'text') else price_elem or "Ціна невідома"
                
                # Пробуем разные селекторы для аптеки
                pharmacy_selectors = ['.pharmacy-title', '.store-name', '.pharmacy-name', '.pharmacy', '.store']
                pharmacy_elem = None
                for selector in pharmacy_selectors:
                    pharmacy_elem = product.select_one(selector)
                    if pharmacy_elem:
                        break
                
                # Пробуем получить аптеку из атрибута, если селекторы не сработали
                if not pharmacy_elem:
                    pharmacy_elem = product.get('data-pharmacy') or product.get('data-store')
                
                pharmacy = pharmacy_elem.text.strip() if hasattr(pharmacy_elem, 'text') else pharmacy_elem or "Аптека невідома"
                
                # Дополнительная информация: производитель, форма, вес и т.д.
                info_selectors = ['.description', '.product-desc', '.details', '.info']
                info_elem = None
                for selector in info_selectors:
                    info_elem = product.select_one(selector)
                    if info_elem:
                        break
                
                info = info_elem.text.strip() if info_elem else ""
                
                # Ссылка на изображение
                img_elem = product.select_one('img')
                img_url = img_elem.get('src') if img_elem else ""
                
                # Ссылка на продукт
                link_elem = product.select_one('a')
                link = link_elem.get('href') if link_elem else ""
                if link and not link.startswith('http'):
                    link = f"https://tabletki.ua{link}"
                
                results.append({
                    "name": name,
                    "price": price,
                    "pharmacy": pharmacy,
                    "info": info,
                    "img_url": img_url,
                    "link": link,
                    "city": city_name if city_name else ""
                })
            except Exception as e:
                logger.error(f"Ошибка при парсинге элемента: {e}")
        
        logger.info(f"Найдено {len(results)} результатов для {drug_name} {f'в {city_name}' if city_name else ''}")
        return results
    except Exception as e:
        logger.error(f"Ошибка при поиске {drug_name} {f'в {city_name}' if city_name else ''}: {e}")
        return []

# Функция для поиска городов по шаблону
def search_cities(city_pattern):
    try:
        # Фильтруем города из списка по паттерну
        pattern = city_pattern.lower()
        matching_cities = [city for city in UKRAINE_CITIES if pattern in city.lower()]
        
        # Сортируем города так, чтобы наиболее точные совпадения были вверху
        matching_cities.sort(key=lambda x: (0 if x.lower().startswith(pattern) else 1, len(x)))
        
        return matching_cities[:10]  # Возвращаем не более 10 городов
    except Exception as e:
        logger.error(f"Ошибка при поиске городов: {e}")
        return []

# Функция проверки наличия препарата в конкретном городе
def check_drug_availability(drug_name, city_name):
    try:
        results = search_drugs(drug_name, city_name)
        return results
    except Exception as e:
        logger.error(f"Ошибка при проверке наличия {drug_name} в {city_name}: {e}")
        return []

# Функция для отправки уведомления о наличии препарата
def notify_drug_available(chat_id, drug_name, city_name, bot):
    try:
        results = check_drug_availability(drug_name, city_name)
        if results:
            message = f"💊 *{drug_name}* з'явився у місті *{city_name}*!\n\n"
            
            # Добавляем до 3 аптек с ценами
            for i, result in enumerate(results[:3]):
                message += f"{i+1}. {result['name']}\n   💰 {result['price']}\n   🏥 {result['pharmacy']}\n\n"
            
            bot.send_message(chat_id, message, parse_mode="Markdown")
            return True
        return False
    except Exception as e:
        logger.error(f"Ошибка при отправке уведомления: {e}")
        return False

# Команда /list
async def list_items(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        # Получаем информацию о парах препарат-город для пользователя
        chat_id = update.effective_chat.id
        user_tracking = config.get("tracking", {}).get(str(chat_id), [])
        
        if not user_tracking:
            await update.message.reply_text("У вас ще немає препаратів для відстеження.")
            return
        
        text = "*Відстежувані препарати:*\n\n"
        
        for i, item in enumerate(user_tracking):
            drug = item.get("drug", "")
            city = item.get("city", "")
            text += f"{i+1}. 💊 *{drug}* у місті 🏙️ *{city}*\n"
        
        # Добавляем кнопки для удаления препаратов из отслеживания
        keyboard = []
        for i, item in enumerate(user_tracking):
            drug = item.get("drug", "")
            city = item.get("city", "")
            keyboard.append([InlineKeyboardButton(f"❌ {drug} ({city})", callback_data=f"remove_tracking:{i}")])
        
        markup = InlineKeyboardMarkup(keyboard)
        await update.message.reply_text(text, parse_mode="Markdown", reply_markup=markup)
    except Exception as e:
        logger.error(f"Ошибка в команде list: {e}")
        await update.message.reply_text("Виникла помилка при отриманні списку.")

# Команда /settings
async def settings(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        keyboard = [
            [InlineKeyboardButton("3 години", callback_data="interval:3")],
            [InlineKeyboardButton("6 годин", callback_data="interval:6")],
            [InlineKeyboardButton("12 годин", callback_data="interval:12")],
            [InlineKeyboardButton("24 години", callback_data="interval:24")]
        ]
        markup = InlineKeyboardMarkup(keyboard)
        await update.message.reply_text(
            f"⏰ Поточний інтервал перевірки: кожні {config.get('interval_hours',12)} годин.\n\nОберіть новий інтервал:",
            reply_markup=markup
        )
    except Exception as e:
        logger.error(f"Ошибка в команде settings: {e}")
        await update.message.reply_text("Виникла помилка при налаштуванні інтервалу.")

# Команда /check
async def check_now(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        chat_id = update.effective_chat.id
        user_tracking = config.get("tracking", {}).get(str(chat_id), [])
        
        if not user_tracking:
            await update.message.reply_text("У вас ще немає препаратів для відстеження.")
            return
        
        await update.message.reply_text("🔎 Виконується перевірка наявності препаратів...")
        
        found = False
        for item in user_tracking:
            drug = item.get("drug", "")
            city = item.get("city", "")
            
            results = check_drug_availability(drug, city)
            if results:
                found = True
                message = f"💊 *{drug}* доступний у місті *{city}*!\n\n"
                
                # Добавляем до 3 аптек с ценами
                for i, result in enumerate(results[:3]):
                    message += f"{i+1}. {result['name']}\n   💰 {result['price']}\n   🏥 {result['pharmacy']}\n\n"
                
                await update.message.reply_text(message, parse_mode="Markdown")
        
        if not found:
            await update.message.reply_text("❌ Жодних відстежуваних препаратів не знайдено в обраних містах.")
    except Exception as e:
        logger.error(f"Ошибка в команде check: {e}")
        await update.message.reply_text("Виникла помилка при перевірці наявності ліків.")

# Поиск препаратов по тексту и показ вариантов выбора
async def search_and_show_drugs(update: Update, context: ContextTypes.DEFAULT_TYPE, query):
    try:
        await update.message.reply_text(f"🔎 Пошук препаратів \"{query}\"...")
        
        # Ищем препараты без указания города
        results = search_drugs(query)
        
        if not results:
            await update.message.reply_text("Нічого не знайдено. Спробуйте інший запит.")
            return False
        
        # Группируем препараты по названию (убираем дубликаты)
        unique_drugs = {}
        for result in results:
            name = result['name']
            if name not in unique_drugs:
                unique_drugs[name] = result
        
        # Создаем кнопки с названиями препаратов
        keyboard = []
        for name in list(unique_drugs.keys())[:10]:  # Ограничиваем 10 препаратами
            keyboard.append([InlineKeyboardButton(name, callback_data=f"select_drug_for_tracking:{name}")])
        
        markup = InlineKeyboardMarkup(keyboard)
        await update.message.reply_text(
            "Оберіть препарат для відстеження з варіантів нижче:", 
            reply_markup=markup
        )
        
        # Сохраняем результаты в контексте пользователя
        context.user_data['search_results'] = unique_drugs
        return True
    except Exception as e:
        logger.error(f"Ошибка при поиске препаратов: {e}")
        await update.message.reply_text("Виникла помилка при пошуку. Спробуйте пізніше.")
        return False

# Показ списка городов для выбора
async def show_cities_for_selection(update: Update, context: ContextTypes.DEFAULT_TYPE, city_pattern=None):
    try:
        if city_pattern:
            cities = search_cities(city_pattern)
        else:
            # Если шаблон не передан, показываем основные города
            cities = UKRAINE_CITIES[:10]
        
        if not cities:
            await update.callback_query.edit_message_text(
                "Не знайдено підходящих міст. Введіть назву міста ще раз:"
            )
            return False
        
        # Создаем кнопки с городами
        keyboard = []
        for city in cities:
            keyboard.append([InlineKeyboardButton(city, callback_data=f"select_city_for_tracking:{city}")])
        
        markup = InlineKeyboardMarkup(keyboard)
        
        # В зависимости от типа сообщения, редактируем или отправляем новое
        if update.callback_query:
            await update.callback_query.edit_message_text(
                "Оберіть місто для відстеження препарату:",
                reply_markup=markup
            )
        else:
            await update.message.reply_text(
                "Оберіть місто для відстеження препарату:",
                reply_markup=markup
            )
        
        return True
    except Exception as e:
        logger.error(f"Ошибка при отображении списка городов: {e}")
        if update.callback_query:
            await update.callback_query.edit_message_text("Виникла помилка при виборі міста. Спробуйте пізніше.")
        else:
            await update.message.reply_text("Виникла помилка при виборі міста. Спробуйте пізніше.")
        return False

# Добавление препарата и города в отслеживание
def add_to_tracking(chat_id, drug_name, city_name):
    try:
        if "tracking" not in config:
            config["tracking"] = {}
        
        if str(chat_id) not in config["tracking"]:
            config["tracking"][str(chat_id)] = []
        
        # Проверяем, не отслеживается ли уже такой препарат в этом городе
        user_tracking = config["tracking"][str(chat_id)]
        for item in user_tracking:
            if item.get("drug") == drug_name and item.get("city") == city_name:
                return False  # Уже отслеживается
        
        # Добавляем в отслеживание
        config["tracking"][str(chat_id)].append({
            "drug": drug_name,
            "city": city_name,
            "added": time.time()
        })
        
        save_config(config)
        return True
    except Exception as e:
        logger.error(f"Ошибка при добавлении в отслеживание: {e}")
        return False

# Удаление препарата из отслеживания
def remove_from_tracking(chat_id, index):
    try:
        if "tracking" not in config or str(chat_id) not in config["tracking"]:
            return False
        
        user_tracking = config["tracking"][str(chat_id)]
        if index >= len(user_tracking):
            return False
        
        # Удаляем из отслеживания
        del user_tracking[index]
        save_config(config)
        return True
    except Exception as e:
        logger.error(f"Ошибка при удалении из отслеживания: {e}")
        return False

# Фоновая проверка по расписанию
def schedule_checks(application):
    def loop():
        while True:
            interval_hours = config.get("interval_hours", 12)
            logger.info(f"Запланирована проверка через {interval_hours} часов")
            
            time.sleep(interval_hours * 3600)
            
            try:
                tracking = config.get("tracking", {})
                logger.info(f"Проверка препаратов для {len(tracking)} пользователей")
                
                for chat_id, user_tracking in tracking.items():
                    for item in user_tracking:
                        drug = item.get("drug", "")
                        city = item.get("city", "")
                        
                        if drug and city:
                            notify_drug_available(int(chat_id), drug, city, application.bot)
            except Exception as e:
                logger.error(f"Scheduled check error: {e}")
    
    t = threading.Thread(target=loop, daemon=True)
    t.start()
    logger.info(f"Background checker started with interval: {config.get('interval_hours', 12)} hours")

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        query = update.callback_query
        await query.answer()
        
        if query.data.startswith("select_drug_for_tracking:"):
            # Пользователь выбрал препарат, предлагаем выбрать город
            drug_name = query.data.split(":", 1)[1]
            
            # Сохраняем выбранный препарат
            context.user_data["selected_drug"] = drug_name
            
            # Показываем список городов для выбора
            context.user_data["waiting_for"] = "city_for_tracking"
            await show_cities_for_selection(update, context)
        
        elif query.data.startswith("select_city_for_tracking:"):
            # Пользователь выбрал город
            city_name = query.data.split(":", 1)[1]
            drug_name = context.user_data.get("selected_drug", "")
            
            if not drug_name:
                await query.edit_message_text("Помилка: не вибрано препарат. Почніть спочатку.")
                return
            
            # Добавляем в отслеживание
            chat_id = update.effective_chat.id
            if add_to_tracking(chat_id, drug_name, city_name):
                await query.edit_message_text(
                    f"✅ Препарат *{drug_name}* буде відстежуватися у місті *{city_name}*.\n\n"
                    f"Ви отримаєте повідомлення, коли препарат з'явиться в наявності.",
                    parse_mode="Markdown"
                )
            else:
                await query.edit_message_text(
                    f"ℹ️ Препарат *{drug_name}* у місті *{city_name}* вже відстежується.",
                    parse_mode="Markdown"
                )
            
            # Очищаем состояние ожидания
            context.user_data.pop("waiting_for", None)
            context.user_data.pop("selected_drug", None)
        
        elif query.data.startswith("remove_tracking:"):
            # Пользователь хочет удалить препарат из отслеживания
            index = int(query.data.split(":", 1)[1])
            chat_id = update.effective_chat.id
            
            user_tracking = config.get("tracking", {}).get(str(chat_id), [])
            if index < len(user_tracking):
                drug = user_tracking[index].get("drug", "")
                city = user_tracking[index].get("city", "")
                
                if remove_from_tracking(chat_id, index):
                    await query.edit_message_text(
                        f"🗑️ Препарат *{drug}* у місті *{city}* видалено з відстеження.",
                        parse_mode="Markdown"
                    )
                else:
                    await query.edit_message_text(
                        "❌ Помилка при видаленні препарату з відстеження.",
                    )
            else:
                await query.edit_message_text("❌ Препарат не знайдено.")
        
        elif query.data.startswith("interval:"):
            hours = int(query.data.split(":", 1)[1])
            config["interval_hours"] = hours
            save_config(config)
            await query.edit_message_text(f"⏰ Інтервал перевірки змінено на *{hours} годин*.", parse_mode="Markdown")
    
    except Exception as e:
        logger.error(f"Ошибка в button_handler: {e}")
        await query.edit_message_text("Виникла помилка при обробці запиту.")

async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        text = update.message.text.strip()
        
        if text == "🔎 Додати препарат для відстеження":
            await update.message.reply_text("Введіть назву препарату для пошуку:")
            context.user_data["waiting_for"] = "drug_search"
            return
        
        if text == "📋 Список відстежуваних":
            await list_items(update, context)
            return
        
        if text == "🔎 Перевірити зараз":
            await check_now(update, context)
            return
        
        if text == "⚙️ Налаштування":
            await settings(update, context)
            return
        
        # Проверяем, ожидаем ли ввод от пользователя
        waiting_for = context.user_data.get("waiting_for")
        
        if waiting_for == "drug_search":
            # Пользователь ввел название препарата
            await search_and_show_drugs(update, context, text)
            return
        
        elif waiting_for == "city_for_tracking":
            # Пользователь ввел название города
            await show_cities_for_selection(update, context, text)
            return
        
        else:
            # Если ничего не ожидаем, считаем ввод поиском препарата
            await search_and_show_drugs(update, context, text)
    
    except Exception as e:
        logger.error(f"Ошибка в handle_text: {e}")
        await update.message.reply_text("Виникла помилка при обробці тексту.")

def main():
    try:
        if not config["token"]:
            logger.error("Токен бота не найден в конфигурации")
            print("Ошибка: токен бота не найден в конфигурации!")
            return
            
        app = ApplicationBuilder().token(config["token"]).build()
        
        # Добавляем обработчики команд
        app.add_handler(CommandHandler("start", start))
        app.add_handler(CommandHandler("list", list_items))
        app.add_handler(CommandHandler("check", check_now))
        app.add_handler(CommandHandler("settings", settings))
        
        # Добавляем обработчик для callback-запросов от кнопок
        app.add_handler(CallbackQueryHandler(button_handler))
        
        # Добавляем обработчик для текстовых сообщений
        app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
        
        # Запускаем фоновую проверку
        schedule_checks(app)
        
        # Запускаем бота
        logger.info("Bot started!")
        print("Bot started!")
        app.run_polling()
    except Exception as e:
        logger.critical(f"Критическая ошибка при запуске бота: {e}")
        print(f"Критическая ошибка при запуске бота: {e}")

if __name__ == "__main__":
    main()
