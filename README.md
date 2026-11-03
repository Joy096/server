[Русский](#русский) | [Українська](#українська) | [English](#english) | [Polski](#polski)

---

<a name="русский"></a>

## 🚀 Скрипты для настройки сервера Linux

Добро пожаловать! Этот репозиторий содержит коллекцию Bash-скриптов для упрощения и автоматизации установки и базовой настройки различного ПО на серверах Linux (в основном протестировано на Debian/Ubuntu).

### 🛠️ Скрипты

У каждого скрипта ниже есть готовая команда: она скачивает файл (если такой уже лежит рядом, он заменяется свежим) и сразу запускает его. ⚠️ отмечает важные предупреждения.

#### 🧰 Настройка и обслуживание сервера

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Первоначальная настройка нового сервера: обновление системы, брандмауэр UFW (SSH, 80, 443), BBR, локаль и часовой пояс, копирование SSH-ключей в root, ночное автообновление через cron. ⚠️ В конце перезагружает сервер. Запускайте первым.
    ```bash
    wget -O server_new.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/server_new.sh && sudo bash server_new.sh
    ```
*   **[`updater.sh`](https://github.com/Joy096/server/raw/refs/heads/main/updater.sh):** Обновление системы (`apt full-upgrade`), удаление старых версий snap и перезагрузка. `server_new.sh` ставит его в cron на 04:00 каждую ночь. ⚠️ Перезагружает сервер.
    ```bash
    wget -O updater.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/updater.sh && sudo bash updater.sh
    ```
*   **[`aapanel_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/aapanel_update.sh):** Обновление панели aaPanel: запускает `bt 16`.
    ```bash
    wget -O aapanel_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/aapanel_update.sh && sudo bash aapanel_update.sh
    ```

#### 🔐 SSL-сертификаты

*   **[`ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/ssl.sh):** Выпуск и автообновление SSL-сертификатов Let's Encrypt через `acme.sh` (DNS: Cloudflare, DuckDNS, deSEC, Dynu). Сам устанавливает сертификат в 3X-UI, Nextcloud (Snap), AdGuard Home (Snap), qBittorrent, TorrServer и Jackett и показывает, где HTTPS уже включён. Заменил прежний `cloudflare_ssl.sh`. Подробнее: [`ssl.md`](https://github.com/Joy096/server/blob/main/ssl.md).
    ```bash
    wget -O ssl.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh && sudo bash ssl.sh
    ```
*   **[`lego_cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lego_cert.sh):** Альтернатива `ssl.sh` только для AdGuard Home: сертификаты Let's Encrypt через LEGO и Cloudflare DNS, продление раз в месяц через cron.
    ```bash
    wget -O lego_cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lego_cert.sh && sudo bash lego_cert.sh
    ```
*   **[`update-nextcloud-cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/update-nextcloud-cert.sh):** Обновляет сертификат Nextcloud (Snap) через Let's Encrypt: временно переключает порты на 80/443 и возвращает прежние (нужен пакет `expect`). ⚠️ Домен и email прописаны прямо в скрипте: поправьте под себя перед запуском.
    ```bash
    wget -O update-nextcloud-cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/update-nextcloud-cert.sh && sudo bash update-nextcloud-cert.sh
    ```

#### 🌐 Сеть и доступ

*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Устанавливает панель управления прокси-сервисами 3X-UI (форк X-UI).
    ```bash
    wget -O x-ui.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/x-ui.sh && sudo bash x-ui.sh
    ```
*   **[`hysteria.sh`](https://github.com/Joy096/server/raw/refs/heads/main/hysteria.sh):** Установка и управление сервером Hysteria v2 (Ubuntu 24 / Debian 12+): сертификат ACME (Let's Encrypt) или самоподписанный.
    ```bash
    wget -O hysteria.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/hysteria.sh && sudo bash hysteria.sh
    ```
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Устанавливает VPN-сервер Outline для простого создания и управления VPN-доступом.
    ```bash
    wget -O outline_vpn.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/outline_vpn.sh && sudo bash outline_vpn.sh
    ```
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Устанавливает сетевой блокировщик рекламы и трекеров AdGuard Home (через Snap).
    ```bash
    wget -O adguard_home.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/adguard_home.sh && sudo bash adguard_home.sh
    ```
*   **[`rustdesk.sh`](https://github.com/Joy096/server/raw/refs/heads/main/rustdesk.sh):** Свой сервер удалённого доступа RustDesk (hbbs + hbbr) без Docker для серверов Oracle (Micro и Ampere): подключение только по ключу, автообновление раз в неделю с откатом, если новая версия не запустилась. Подробнее: [`rustdesk.md`](https://github.com/Joy096/server/blob/main/rustdesk.md).
    ```bash
    wget -O rustdesk.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/rustdesk.sh && sudo bash rustdesk.sh
    ```

#### 🎬 Торренты и медиа

*   **[`qbittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qbittorrent.sh):** Устанавливает торрент-клиент qBittorrent с веб-интерфейсом. Его трафик идёт через WireGuard VPN с kill-switch (можно и без VPN). Умеет создавать торренты и запускать раздачу; HTTPS подключается через `ssl.sh`. Подробнее: [`qbittorrent.md`](https://github.com/Joy096/server/blob/main/qbittorrent.md).
    ```bash
    wget -O qbittorrent.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/qbittorrent.sh && sudo bash qbittorrent.sh
    ```
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Устанавливает TorrServer, позволяющий смотреть торренты онлайн без полной загрузки. Его трафик идёт через WireGuard VPN с kill-switch (можно и без VPN), есть два профиля настроек (слабый и мощный сервер); HTTPS подключается через `ssl.sh`. Подробнее: [`torrserver.md`](https://github.com/Joy096/server/blob/main/torrserver.md).
    ```bash
    wget -O torrserver.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh && sudo bash torrserver.sh
    ```
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Устанавливает Jackett, прокси для API торрент-трекеров: пароль и API key, сохранение и восстановление Indexers, FlareSolverr или Byparr для трекеров с защитой Cloudflare, автосоздание swap; HTTPS подключается через `ssl.sh`. Подробнее: [`jackett.md`](https://github.com/Joy096/server/blob/main/jackett.md).
    ```bash
    wget -O jackett.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/jackett.sh && sudo bash jackett.sh
    ```
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Устанавливает Lampa – веб-интерфейс для просмотра медиаконтента. Подробнее: [`lampa.md`](https://github.com/Joy096/server/blob/main/lampa.md).
    ```bash
    wget -O lampa.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa.sh && sudo bash lampa.sh
    ```
*   **[`lampa_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa_update.sh):** Обновляет Lampa из репозитория `yumata/lampa` и копирует файлы в `/var/www/lampa`. Рассчитан на запуск из cron.
    ```bash
    wget -O lampa_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa_update.sh && sudo bash lampa_update.sh
    ```

#### ☁️ Oracle Cloud

*   **[`oracle.sh`](https://github.com/Joy096/server/raw/refs/heads/main/oracle.sh):** Автоматически создаёт бесплатный сервер Oracle Cloud (Ampere или Micro): ищет свободное место в фоне и пишет в Telegram, когда сервер создан. Также показывает ваши серверы, меняет ЦП, память и диск, удаляет серверы. Подробнее: [`oracle.md`](https://github.com/Joy096/server/blob/main/oracle.md).
    ```bash
    wget -O oracle.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/oracle.sh && sudo bash oracle.sh
    ```
*   **[`keepalive.sh`](https://github.com/Joy096/server/raw/refs/heads/main/keepalive.sh):** Защищает бесплатный сервер Oracle от отключения за простой: на Ampere занимает часть памяти, на Micro делает короткие всплески нагрузки на ЦП. Запускать на самом сервере Oracle. Подробнее: [`keepalive.md`](https://github.com/Joy096/server/blob/main/keepalive.md).
    ```bash
    wget -O keepalive.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/keepalive.sh && sudo bash keepalive.sh
    ```

#### 🧩 Прочее

*   **[`minecraft_bedrock.sh`](https://github.com/Joy096/server/raw/refs/heads/main/minecraft_bedrock.sh):** Установка и управление несколькими серверами Minecraft Bedrock Edition: настройка и резервные копии.
    ```bash
    wget -O minecraft_bedrock.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/minecraft_bedrock.sh && sudo bash minecraft_bedrock.sh
    ```
*   **[`tg_monitoring_group_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/tg_monitoring_group_bot.sh):** Устанавливает Telegram-бота, который следит за сообщениями в группе по ключевым словам. Запускайте от обычного пользователя, без `sudo`: служба бота создаётся от вашего пользователя.
    ```bash
    wget -O tg_monitoring_group_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/tg_monitoring_group_bot.sh && bash tg_monitoring_group_bot.sh
    ```
*   **[`meds_watch_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/de_liku_bot/meds_watch_bot.sh):** Устанавливает и настраивает Telegram-бота «Де ліки Bot» (поиск лекарств на tabletki.ua) как службу systemd. Для Ubuntu Server 22.04.
    ```bash
    wget -O meds_watch_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/de_liku_bot/meds_watch_bot.sh && sudo bash meds_watch_bot.sh
    ```
*   **[`usb_chromeos_ubuntu.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_ubuntu.sh):** Готовит образ ChromeOS (Brunch) для установки с USB: спрашивает ссылки на recovery-образ ChromeOS и на Brunch и собирает `chromeos.img` в `~/chrome_os`. Запускайте от обычного пользователя, без `sudo`.
    ```bash
    wget -O usb_chromeos_ubuntu.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_ubuntu.sh && bash usb_chromeos_ubuntu.sh
    ```
*   **[`usb_chromeos_win.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_win.sh):** Вариант для Windows: то же самое, но дополнительно спрашивает имя итогового образа. ⚠️ В конце удаляет все остальные файлы в текущей папке, поэтому команда ниже запускает его в отдельной пустой папке `~/chromeos`. Запускайте без `sudo`.
    ```bash
    mkdir -p ~/chromeos && cd ~/chromeos && wget -O usb_chromeos_win.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_win.sh && bash usb_chromeos_win.sh
    ```

### ▶️ Общее использование

1.  **Выберите скрипт** в списке выше и скопируйте его команду в терминал сервера. Шаблон команды:
    ```bash
    wget -O ИМЯ_СКРИПТА.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ИМЯ_СКРИПТА.sh && sudo bash ИМЯ_СКРИПТА.sh
    ```
    Параметр `-O` записывает файл под этим именем поверх старого, поэтому повторный запуск всегда берёт актуальную версию.
2.  Следуйте инструкциям на экране, которые выводит скрипт.

### ⚠️ Важные замечания

*   **Права Root:** **Большинство скриптов необходимо запускать с правами суперпользователя (`root` или через `sudo`),** так как они устанавливают ПО и изменяют системные настройки. Исключения без `sudo` указаны в их описании: `tg_monitoring_group_bot.sh`, `usb_chromeos_ubuntu.sh`, `usb_chromeos_win.sh`.
*   **Просмотр перед запуском:** Всегда просматривайте код скрипта перед его выполнением на сервере, особенно при запуске от имени `root`. Убедитесь, что вы понимаете, какие команды он будет выполнять.
*   **Совместимость:** Скрипты в основном ориентированы на Debian/Ubuntu. Работа на других дистрибутивах не гарантируется. Некоторые скрипты используют Snap, а скрипты для Oracle Cloud рассчитаны на серверы Oracle.
*   **Перезагрузка:** `server_new.sh` и `updater.sh` в конце перезагружают сервер.
*   **Самоудаление:** Скрипты `server_new.sh`, `x-ui.sh`, `adguard_home.sh`, `outline_vpn.sh`, `lampa.sh`, `hysteria.sh` и `lego_cert.sh` удаляют себя после завершения. Это не проблема: команда из списка при необходимости скачает их заново.
*   **Резервные копии:** Перед применением скриптов, особенно `server_new.sh`, рекомендуется сделать резервную копию важных данных или системы.
*   **"Как есть":** Скрипты предоставляются "как есть", без гарантий. Используйте их на свой страх и риск.

---

<a name="українська"></a>

## 🚀 Скрипти для налаштування сервера Linux

Ласкаво просимо! Цей репозиторій містить колекцію Bash-скриптів для спрощення та автоматизації встановлення та базового налаштування різноманітного ПЗ на серверах Linux (переважно протестовано на Debian/Ubuntu).

### 🛠️ Скрипти

У кожного скрипта нижче є готова команда: вона завантажує файл (якщо такий уже лежить поруч, його буде замінено свіжим) і одразу запускає його. ⚠️ позначає важливі попередження.

#### 🧰 Налаштування та обслуговування сервера

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Початкове налаштування нового сервера: оновлення системи, брандмауер UFW (SSH, 80, 443), BBR, локаль і часовий пояс, копіювання SSH-ключів у root, нічне автооновлення через cron. ⚠️ Наприкінці перезавантажує сервер. Запускайте першим.
    ```bash
    wget -O server_new.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/server_new.sh && sudo bash server_new.sh
    ```
*   **[`updater.sh`](https://github.com/Joy096/server/raw/refs/heads/main/updater.sh):** Оновлення системи (`apt full-upgrade`), видалення старих версій snap і перезавантаження. `server_new.sh` ставить його в cron на 04:00 щоночі. ⚠️ Перезавантажує сервер.
    ```bash
    wget -O updater.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/updater.sh && sudo bash updater.sh
    ```
*   **[`aapanel_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/aapanel_update.sh):** Оновлення панелі aaPanel: запускає `bt 16`.
    ```bash
    wget -O aapanel_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/aapanel_update.sh && sudo bash aapanel_update.sh
    ```

#### 🔐 SSL-сертифікати

*   **[`ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/ssl.sh):** Випуск та автооновлення SSL-сертифікатів Let's Encrypt через `acme.sh` (DNS: Cloudflare, DuckDNS, deSEC, Dynu). Сам встановлює сертифікат у 3X-UI, Nextcloud (Snap), AdGuard Home (Snap), qBittorrent, TorrServer та Jackett і показує, де HTTPS уже ввімкнено. Замінив попередній `cloudflare_ssl.sh`. Докладніше: [`ssl.md`](https://github.com/Joy096/server/blob/main/ssl.md).
    ```bash
    wget -O ssl.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh && sudo bash ssl.sh
    ```
*   **[`lego_cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lego_cert.sh):** Альтернатива `ssl.sh` лише для AdGuard Home: сертифікати Let's Encrypt через LEGO та Cloudflare DNS, продовження раз на місяць через cron.
    ```bash
    wget -O lego_cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lego_cert.sh && sudo bash lego_cert.sh
    ```
*   **[`update-nextcloud-cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/update-nextcloud-cert.sh):** Оновлює сертифікат Nextcloud (Snap) через Let's Encrypt: тимчасово перемикає порти на 80/443 і повертає попередні (потрібен пакет `expect`). ⚠️ Домен та email прописані прямо в скрипті: виправте під себе перед запуском.
    ```bash
    wget -O update-nextcloud-cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/update-nextcloud-cert.sh && sudo bash update-nextcloud-cert.sh
    ```

#### 🌐 Мережа та доступ

*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Встановлює панель керування проксі-сервісами 3X-UI (форк X-UI).
    ```bash
    wget -O x-ui.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/x-ui.sh && sudo bash x-ui.sh
    ```
*   **[`hysteria.sh`](https://github.com/Joy096/server/raw/refs/heads/main/hysteria.sh):** Встановлення та керування сервером Hysteria v2 (Ubuntu 24 / Debian 12+): сертифікат ACME (Let's Encrypt) або самопідписаний.
    ```bash
    wget -O hysteria.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/hysteria.sh && sudo bash hysteria.sh
    ```
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Встановлює VPN-сервер Outline для простого створення та керування VPN-доступом.
    ```bash
    wget -O outline_vpn.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/outline_vpn.sh && sudo bash outline_vpn.sh
    ```
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Встановлює мережевий блокувальник реклами та трекерів AdGuard Home (через Snap).
    ```bash
    wget -O adguard_home.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/adguard_home.sh && sudo bash adguard_home.sh
    ```
*   **[`rustdesk.sh`](https://github.com/Joy096/server/raw/refs/heads/main/rustdesk.sh):** Власний сервер віддаленого доступу RustDesk (hbbs + hbbr) без Docker для серверів Oracle (Micro та Ampere): підключення лише за ключем, автооновлення раз на тиждень із відкатом, якщо нова версія не запустилася. Докладніше: [`rustdesk.md`](https://github.com/Joy096/server/blob/main/rustdesk.md).
    ```bash
    wget -O rustdesk.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/rustdesk.sh && sudo bash rustdesk.sh
    ```

#### 🎬 Торенти та медіа

*   **[`qbittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qbittorrent.sh):** Встановлює торент-клієнт qBittorrent з веб-інтерфейсом. Його трафік іде через WireGuard VPN з kill-switch (можна й без VPN). Вміє створювати торенти та запускати роздачу; HTTPS підключається через `ssl.sh`. Докладніше: [`qbittorrent.md`](https://github.com/Joy096/server/blob/main/qbittorrent.md).
    ```bash
    wget -O qbittorrent.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/qbittorrent.sh && sudo bash qbittorrent.sh
    ```
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Встановлює TorrServer, що дозволяє дивитися торенти онлайн без повного завантаження. Його трафік іде через WireGuard VPN з kill-switch (можна й без VPN), є два профілі налаштувань (слабкий і потужний сервер); HTTPS підключається через `ssl.sh`. Докладніше: [`torrserver.md`](https://github.com/Joy096/server/blob/main/torrserver.md).
    ```bash
    wget -O torrserver.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh && sudo bash torrserver.sh
    ```
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Встановлює Jackett, проксі для API торент-трекерів: пароль і API key, збереження та відновлення Indexers, FlareSolverr або Byparr для трекерів із захистом Cloudflare, автостворення swap; HTTPS підключається через `ssl.sh`. Докладніше: [`jackett.md`](https://github.com/Joy096/server/blob/main/jackett.md).
    ```bash
    wget -O jackett.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/jackett.sh && sudo bash jackett.sh
    ```
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Встановлює Lampa – веб-інтерфейс для перегляду медіаконтенту. Докладніше: [`lampa.md`](https://github.com/Joy096/server/blob/main/lampa.md).
    ```bash
    wget -O lampa.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa.sh && sudo bash lampa.sh
    ```
*   **[`lampa_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa_update.sh):** Оновлює Lampa з репозиторію `yumata/lampa` і копіює файли в `/var/www/lampa`. Розрахований на запуск із cron.
    ```bash
    wget -O lampa_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa_update.sh && sudo bash lampa_update.sh
    ```

#### ☁️ Oracle Cloud

*   **[`oracle.sh`](https://github.com/Joy096/server/raw/refs/heads/main/oracle.sh):** Автоматично створює безкоштовний сервер Oracle Cloud (Ampere або Micro): шукає вільне місце у фоні та пише в Telegram, коли сервер створено. Також показує ваші сервери, змінює ЦП, пам'ять і диск, видаляє сервери. Докладніше: [`oracle.md`](https://github.com/Joy096/server/blob/main/oracle.md).
    ```bash
    wget -O oracle.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/oracle.sh && sudo bash oracle.sh
    ```
*   **[`keepalive.sh`](https://github.com/Joy096/server/raw/refs/heads/main/keepalive.sh):** Захищає безкоштовний сервер Oracle від вимкнення за простій: на Ampere займає частину пам'яті, на Micro робить короткі сплески навантаження на ЦП. Запускати на самому сервері Oracle. Докладніше: [`keepalive.md`](https://github.com/Joy096/server/blob/main/keepalive.md).
    ```bash
    wget -O keepalive.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/keepalive.sh && sudo bash keepalive.sh
    ```

#### 🧩 Інше

*   **[`minecraft_bedrock.sh`](https://github.com/Joy096/server/raw/refs/heads/main/minecraft_bedrock.sh):** Встановлення та керування кількома серверами Minecraft Bedrock Edition: налаштування та резервні копії.
    ```bash
    wget -O minecraft_bedrock.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/minecraft_bedrock.sh && sudo bash minecraft_bedrock.sh
    ```
*   **[`tg_monitoring_group_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/tg_monitoring_group_bot.sh):** Встановлює Telegram-бота, який стежить за повідомленнями в групі за ключовими словами. Запускайте від звичайного користувача, без `sudo`: служба бота створюється від вашого користувача.
    ```bash
    wget -O tg_monitoring_group_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/tg_monitoring_group_bot.sh && bash tg_monitoring_group_bot.sh
    ```
*   **[`meds_watch_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/de_liku_bot/meds_watch_bot.sh):** Встановлює та налаштовує Telegram-бота «Де ліки Bot» (пошук ліків на tabletki.ua) як службу systemd. Для Ubuntu Server 22.04.
    ```bash
    wget -O meds_watch_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/de_liku_bot/meds_watch_bot.sh && sudo bash meds_watch_bot.sh
    ```
*   **[`usb_chromeos_ubuntu.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_ubuntu.sh):** Готує образ ChromeOS (Brunch) для встановлення з USB: запитує посилання на recovery-образ ChromeOS та на Brunch і збирає `chromeos.img` у `~/chrome_os`. Запускайте від звичайного користувача, без `sudo`.
    ```bash
    wget -O usb_chromeos_ubuntu.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_ubuntu.sh && bash usb_chromeos_ubuntu.sh
    ```
*   **[`usb_chromeos_win.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_win.sh):** Варіант для Windows: те саме, але додатково запитує назву підсумкового образу. ⚠️ Наприкінці видаляє всі інші файли в поточній папці, тому команда нижче запускає його в окремій порожній папці `~/chromeos`. Запускайте без `sudo`.
    ```bash
    mkdir -p ~/chromeos && cd ~/chromeos && wget -O usb_chromeos_win.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_win.sh && bash usb_chromeos_win.sh
    ```

### ▶️ Загальне використання

1.  **Оберіть скрипт** у списку вище та скопіюйте його команду в термінал сервера. Шаблон команди:
    ```bash
    wget -O ІМЯ_СКРИПТА.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ІМЯ_СКРИПТА.sh && sudo bash ІМЯ_СКРИПТА.sh
    ```
    Параметр `-O` записує файл під цим іменем поверх старого, тому повторний запуск завжди бере актуальну версію.
2.  Дотримуйтесь інструкцій на екрані, які виводить скрипт.

### ⚠️ Важливі зауваження

*   **Права Root:** **Більшість скриптів необхідно запускати з правами суперкористувача (`root` або через `sudo`),** оскільки вони встановлюють ПЗ та змінюють системні налаштування. Винятки без `sudo` зазначені в їхньому описі: `tg_monitoring_group_bot.sh`, `usb_chromeos_ubuntu.sh`, `usb_chromeos_win.sh`.
*   **Перегляд перед запуском:** Завжди переглядайте код скрипта перед його виконанням на сервері, особливо під час запуску від імені `root`. Переконайтеся, що ви розумієте, які команди він виконуватиме.
*   **Сумісність:** Скрипти переважно орієнтовані на Debian/Ubuntu. Робота на інших дистрибутивах не гарантується. Деякі скрипти використовують Snap, а скрипти для Oracle Cloud розраховані на сервери Oracle.
*   **Перезавантаження:** `server_new.sh` та `updater.sh` наприкінці перезавантажують сервер.
*   **Самовидалення:** Скрипти `server_new.sh`, `x-ui.sh`, `adguard_home.sh`, `outline_vpn.sh`, `lampa.sh`, `hysteria.sh` та `lego_cert.sh` видаляють себе після завершення. Це не проблема: команда зі списку за потреби завантажить їх знову.
*   **Резервні копії:** Перед застосуванням скриптів, особливо `server_new.sh`, рекомендується зробити резервну копію важливих даних або системи.
*   **"Як є":** Скрипти надаються "як є", без гарантій. Використовуйте їх на свій ризик.

---

<a name="english"></a>

## 🚀 Linux Server Setup Scripts

Welcome! This repository contains a collection of Bash scripts to simplify and automate the installation and basic configuration of various software on Linux servers (primarily tested on Debian/Ubuntu).

### 🛠️ Scripts

Every script below comes with a ready-made command: it downloads the file (replacing an older copy of the same name, if any) and runs it right away. ⚠️ marks important warnings.

#### 🧰 Server setup and maintenance

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Initial setup of a new server: system update, UFW firewall (SSH, 80, 443), BBR, locale and timezone, copying SSH keys to root, nightly auto-update via cron. ⚠️ Reboots the server at the end. Run it first.
    ```bash
    wget -O server_new.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/server_new.sh && sudo bash server_new.sh
    ```
*   **[`updater.sh`](https://github.com/Joy096/server/raw/refs/heads/main/updater.sh):** System update (`apt full-upgrade`), removal of old snap revisions and a reboot. `server_new.sh` schedules it in cron for 04:00 every night. ⚠️ Reboots the server.
    ```bash
    wget -O updater.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/updater.sh && sudo bash updater.sh
    ```
*   **[`aapanel_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/aapanel_update.sh):** Updates the aaPanel control panel: runs `bt 16`.
    ```bash
    wget -O aapanel_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/aapanel_update.sh && sudo bash aapanel_update.sh
    ```

#### 🔐 SSL certificates

*   **[`ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/ssl.sh):** Issues and auto-renews Let's Encrypt SSL certificates via `acme.sh` (DNS: Cloudflare, DuckDNS, deSEC, Dynu). Installs the certificate into 3X-UI, Nextcloud (Snap), AdGuard Home (Snap), qBittorrent, TorrServer and Jackett by itself and shows where HTTPS is already enabled. Replaces the former `cloudflare_ssl.sh`. Details: [`ssl.md`](https://github.com/Joy096/server/blob/main/ssl.md).
    ```bash
    wget -O ssl.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh && sudo bash ssl.sh
    ```
*   **[`lego_cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lego_cert.sh):** An alternative to `ssl.sh` for AdGuard Home only: Let's Encrypt certificates via LEGO and Cloudflare DNS, renewed monthly via cron.
    ```bash
    wget -O lego_cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lego_cert.sh && sudo bash lego_cert.sh
    ```
*   **[`update-nextcloud-cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/update-nextcloud-cert.sh):** Renews the Nextcloud (Snap) certificate via Let's Encrypt: temporarily switches the ports to 80/443 and restores the previous ones (needs the `expect` package). ⚠️ The domain and email are hard-coded in the script: edit them before running.
    ```bash
    wget -O update-nextcloud-cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/update-nextcloud-cert.sh && sudo bash update-nextcloud-cert.sh
    ```

#### 🌐 Networking and access

*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Installs the 3X-UI proxy service management panel (a fork of X-UI).
    ```bash
    wget -O x-ui.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/x-ui.sh && sudo bash x-ui.sh
    ```
*   **[`hysteria.sh`](https://github.com/Joy096/server/raw/refs/heads/main/hysteria.sh):** Installs and manages a Hysteria v2 server (Ubuntu 24 / Debian 12+): ACME (Let's Encrypt) or self-signed certificate.
    ```bash
    wget -O hysteria.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/hysteria.sh && sudo bash hysteria.sh
    ```
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Installs the Outline VPN server for easy creation and management of VPN access.
    ```bash
    wget -O outline_vpn.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/outline_vpn.sh && sudo bash outline_vpn.sh
    ```
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Installs the network-wide ad and tracker blocker AdGuard Home (via Snap).
    ```bash
    wget -O adguard_home.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/adguard_home.sh && sudo bash adguard_home.sh
    ```
*   **[`rustdesk.sh`](https://github.com/Joy096/server/raw/refs/heads/main/rustdesk.sh):** Your own RustDesk remote access server (hbbs + hbbr) without Docker for Oracle servers (Micro and Ampere): key-only connections, weekly auto-update with a rollback if the new version fails to start. Details: [`rustdesk.md`](https://github.com/Joy096/server/blob/main/rustdesk.md).
    ```bash
    wget -O rustdesk.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/rustdesk.sh && sudo bash rustdesk.sh
    ```

#### 🎬 Torrents and media

*   **[`qbittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qbittorrent.sh):** Installs the qBittorrent torrent client with its web UI. Its traffic goes through a WireGuard VPN with a kill-switch (VPN is optional). Can create torrents and start seeding; HTTPS is enabled via `ssl.sh`. Details: [`qbittorrent.md`](https://github.com/Joy096/server/blob/main/qbittorrent.md).
    ```bash
    wget -O qbittorrent.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/qbittorrent.sh && sudo bash qbittorrent.sh
    ```
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Installs TorrServer, which lets you watch torrents online without a full download. Its traffic goes through a WireGuard VPN with a kill-switch (VPN is optional), with two settings profiles (weak and powerful server); HTTPS is enabled via `ssl.sh`. Details: [`torrserver.md`](https://github.com/Joy096/server/blob/main/torrserver.md).
    ```bash
    wget -O torrserver.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh && sudo bash torrserver.sh
    ```
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Installs Jackett, a proxy for torrent tracker APIs: password and API key, saving and restoring Indexers, FlareSolverr or Byparr for Cloudflare-protected trackers, automatic swap creation; HTTPS is enabled via `ssl.sh`. Details: [`jackett.md`](https://github.com/Joy096/server/blob/main/jackett.md).
    ```bash
    wget -O jackett.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/jackett.sh && sudo bash jackett.sh
    ```
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Installs Lampa – a web interface for viewing media content. Details: [`lampa.md`](https://github.com/Joy096/server/blob/main/lampa.md).
    ```bash
    wget -O lampa.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa.sh && sudo bash lampa.sh
    ```
*   **[`lampa_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa_update.sh):** Updates Lampa from the `yumata/lampa` repository and copies the files to `/var/www/lampa`. Designed to be run from cron.
    ```bash
    wget -O lampa_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa_update.sh && sudo bash lampa_update.sh
    ```

#### ☁️ Oracle Cloud

*   **[`oracle.sh`](https://github.com/Joy096/server/raw/refs/heads/main/oracle.sh):** Automatically creates a free Oracle Cloud server (Ampere or Micro): searches for free capacity in the background and messages you on Telegram once the server is created. Also lists your servers, changes CPU, memory and disk, and deletes servers. Details: [`oracle.md`](https://github.com/Joy096/server/blob/main/oracle.md).
    ```bash
    wget -O oracle.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/oracle.sh && sudo bash oracle.sh
    ```
*   **[`keepalive.sh`](https://github.com/Joy096/server/raw/refs/heads/main/keepalive.sh):** Protects a free Oracle server from being reclaimed for idling: on Ampere it holds part of the memory, on Micro it makes short CPU load bursts. Run it on the Oracle server itself. Details: [`keepalive.md`](https://github.com/Joy096/server/blob/main/keepalive.md).
    ```bash
    wget -O keepalive.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/keepalive.sh && sudo bash keepalive.sh
    ```

#### 🧩 Other

*   **[`minecraft_bedrock.sh`](https://github.com/Joy096/server/raw/refs/heads/main/minecraft_bedrock.sh):** Installs and manages multiple Minecraft Bedrock Edition servers: configuration and backups.
    ```bash
    wget -O minecraft_bedrock.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/minecraft_bedrock.sh && sudo bash minecraft_bedrock.sh
    ```
*   **[`tg_monitoring_group_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/tg_monitoring_group_bot.sh):** Installs a Telegram bot that watches group messages for keywords. Run it as a regular user, without `sudo`: the bot's service is created for your user.
    ```bash
    wget -O tg_monitoring_group_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/tg_monitoring_group_bot.sh && bash tg_monitoring_group_bot.sh
    ```
*   **[`meds_watch_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/de_liku_bot/meds_watch_bot.sh):** Installs and configures the Telegram bot "Де ліки Bot" (medicine search on tabletki.ua) as a systemd service. For Ubuntu Server 22.04.
    ```bash
    wget -O meds_watch_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/de_liku_bot/meds_watch_bot.sh && sudo bash meds_watch_bot.sh
    ```
*   **[`usb_chromeos_ubuntu.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_ubuntu.sh):** Prepares a ChromeOS (Brunch) image for installing from USB: asks for the links to the ChromeOS recovery image and to Brunch and builds `chromeos.img` in `~/chrome_os`. Run it as a regular user, without `sudo`.
    ```bash
    wget -O usb_chromeos_ubuntu.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_ubuntu.sh && bash usb_chromeos_ubuntu.sh
    ```
*   **[`usb_chromeos_win.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_win.sh):** The Windows variant: the same, but it also asks for the name of the resulting image. ⚠️ At the end it deletes all other files in the current folder, so the command below runs it in a separate empty folder `~/chromeos`. Run it without `sudo`.
    ```bash
    mkdir -p ~/chromeos && cd ~/chromeos && wget -O usb_chromeos_win.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_win.sh && bash usb_chromeos_win.sh
    ```

### ▶️ General Usage

1.  **Pick a script** from the list above and paste its command into the server terminal. The command template:
    ```bash
    wget -O SCRIPT_NAME.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/SCRIPT_NAME.sh && sudo bash SCRIPT_NAME.sh
    ```
    The `-O` option writes the file under that name over the old one, so running it again always fetches the latest version.
2.  Follow the on-screen instructions provided by the script.

### ⚠️ Important Notes

*   **Root Privileges:** **Most scripts must be run with superuser privileges (`root` or via `sudo`)** as they install software and modify system settings. The exceptions that run without `sudo` are marked in their descriptions: `tg_monitoring_group_bot.sh`, `usb_chromeos_ubuntu.sh`, `usb_chromeos_win.sh`.
*   **Review Before Running:** Always review the script's code before executing it on your server, especially when running as `root`. Ensure you understand the commands it will run.
*   **Compatibility:** Scripts are primarily targeted at Debian/Ubuntu. Functionality on other distributions is not guaranteed. Some scripts use Snap, and the Oracle Cloud scripts are meant for Oracle servers.
*   **Reboot:** `server_new.sh` and `updater.sh` reboot the server at the end.
*   **Self-Deletion:** The scripts `server_new.sh`, `x-ui.sh`, `adguard_home.sh`, `outline_vpn.sh`, `lampa.sh`, `hysteria.sh` and `lego_cert.sh` delete themselves upon completion. That is fine: the command from the list downloads them again when needed.
*   **Backups:** Before applying scripts, especially `server_new.sh`, it is recommended to back up important data or the system.
*   **"As Is":** The scripts are provided "as is" without warranty. Use them at your own risk.

---

<a name="polski"></a>

## 🚀 Skrypty do konfiguracji serwera Linux

Witaj! To repozytorium zawiera kolekcję skryptów Bash do uproszczenia i automatyzacji instalacji oraz podstawowej konfiguracji różnego oprogramowania na serwerach Linux (głównie testowane na Debian/Ubuntu).

### 🛠️ Skrypty

Każdy skrypt poniżej ma gotowe polecenie: pobiera plik (zastępując starszą kopię o tej samej nazwie, jeśli istnieje) i od razu go uruchamia. ⚠️ oznacza ważne ostrzeżenia.

#### 🧰 Konfiguracja i utrzymanie serwera

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Wstępna konfiguracja nowego serwera: aktualizacja systemu, zapora UFW (SSH, 80, 443), BBR, ustawienia regionalne i strefa czasowa, kopiowanie kluczy SSH do roota, nocna automatyczna aktualizacja przez cron. ⚠️ Na końcu restartuje serwer. Uruchom go jako pierwszy.
    ```bash
    wget -O server_new.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/server_new.sh && sudo bash server_new.sh
    ```
*   **[`updater.sh`](https://github.com/Joy096/server/raw/refs/heads/main/updater.sh):** Aktualizacja systemu (`apt full-upgrade`), usunięcie starych wersji snap i restart. `server_new.sh` dodaje go do crona na 04:00 każdej nocy. ⚠️ Restartuje serwer.
    ```bash
    wget -O updater.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/updater.sh && sudo bash updater.sh
    ```
*   **[`aapanel_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/aapanel_update.sh):** Aktualizacja panelu aaPanel: uruchamia `bt 16`.
    ```bash
    wget -O aapanel_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/aapanel_update.sh && sudo bash aapanel_update.sh
    ```

#### 🔐 Certyfikaty SSL

*   **[`ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/ssl.sh):** Wystawia i automatycznie odnawia certyfikaty SSL Let's Encrypt przez `acme.sh` (DNS: Cloudflare, DuckDNS, deSEC, Dynu). Sam instaluje certyfikat w 3X-UI, Nextcloud (Snap), AdGuard Home (Snap), qBittorrent, TorrServer i Jackett oraz pokazuje, gdzie HTTPS jest już włączony. Zastępuje dawny `cloudflare_ssl.sh`. Szczegóły: [`ssl.md`](https://github.com/Joy096/server/blob/main/ssl.md).
    ```bash
    wget -O ssl.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh && sudo bash ssl.sh
    ```
*   **[`lego_cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lego_cert.sh):** Alternatywa dla `ssl.sh` tylko dla AdGuard Home: certyfikaty Let's Encrypt przez LEGO i Cloudflare DNS, odnawiane raz w miesiącu przez cron.
    ```bash
    wget -O lego_cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lego_cert.sh && sudo bash lego_cert.sh
    ```
*   **[`update-nextcloud-cert.sh`](https://github.com/Joy096/server/raw/refs/heads/main/update-nextcloud-cert.sh):** Odnawia certyfikat Nextcloud (Snap) przez Let's Encrypt: tymczasowo przełącza porty na 80/443 i przywraca poprzednie (wymaga pakietu `expect`). ⚠️ Domena i e-mail są wpisane na stałe w skrypcie: popraw je przed uruchomieniem.
    ```bash
    wget -O update-nextcloud-cert.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/update-nextcloud-cert.sh && sudo bash update-nextcloud-cert.sh
    ```

#### 🌐 Sieć i dostęp

*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Instaluje panel zarządzania usługami proxy 3X-UI (fork X-UI).
    ```bash
    wget -O x-ui.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/x-ui.sh && sudo bash x-ui.sh
    ```
*   **[`hysteria.sh`](https://github.com/Joy096/server/raw/refs/heads/main/hysteria.sh):** Instalacja i zarządzanie serwerem Hysteria v2 (Ubuntu 24 / Debian 12+): certyfikat ACME (Let's Encrypt) lub samopodpisany.
    ```bash
    wget -O hysteria.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/hysteria.sh && sudo bash hysteria.sh
    ```
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Instaluje serwer VPN Outline do łatwego tworzenia i zarządzania dostępem VPN.
    ```bash
    wget -O outline_vpn.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/outline_vpn.sh && sudo bash outline_vpn.sh
    ```
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Instaluje sieciowy bloker reklam i trackerów AdGuard Home (przez Snap).
    ```bash
    wget -O adguard_home.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/adguard_home.sh && sudo bash adguard_home.sh
    ```
*   **[`rustdesk.sh`](https://github.com/Joy096/server/raw/refs/heads/main/rustdesk.sh):** Własny serwer zdalnego dostępu RustDesk (hbbs + hbbr) bez Dockera dla serwerów Oracle (Micro i Ampere): połączenia tylko z kluczem, cotygodniowa automatyczna aktualizacja z wycofaniem, jeśli nowa wersja się nie uruchomi. Szczegóły: [`rustdesk.md`](https://github.com/Joy096/server/blob/main/rustdesk.md).
    ```bash
    wget -O rustdesk.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/rustdesk.sh && sudo bash rustdesk.sh
    ```

#### 🎬 Torrenty i multimedia

*   **[`qbittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qbittorrent.sh):** Instaluje klienta torrent qBittorrent z interfejsem webowym. Jego ruch idzie przez WireGuard VPN z kill-switchem (VPN jest opcjonalny). Potrafi tworzyć torrenty i rozpoczynać seedowanie; HTTPS włącza się przez `ssl.sh`. Szczegóły: [`qbittorrent.md`](https://github.com/Joy096/server/blob/main/qbittorrent.md).
    ```bash
    wget -O qbittorrent.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/qbittorrent.sh && sudo bash qbittorrent.sh
    ```
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Instaluje TorrServer, pozwalający oglądać torrenty online bez pełnego pobierania. Jego ruch idzie przez WireGuard VPN z kill-switchem (VPN jest opcjonalny), są dwa profile ustawień (słaby i mocny serwer); HTTPS włącza się przez `ssl.sh`. Szczegóły: [`torrserver.md`](https://github.com/Joy096/server/blob/main/torrserver.md).
    ```bash
    wget -O torrserver.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/torrserver.sh && sudo bash torrserver.sh
    ```
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Instaluje Jackett, proxy do API trackerów torrent: hasło i API key, zapis i przywracanie Indexers, FlareSolverr lub Byparr dla trackerów chronionych przez Cloudflare, automatyczne tworzenie swap; HTTPS włącza się przez `ssl.sh`. Szczegóły: [`jackett.md`](https://github.com/Joy096/server/blob/main/jackett.md).
    ```bash
    wget -O jackett.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/jackett.sh && sudo bash jackett.sh
    ```
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Instaluje Lampa – interfejs webowy do przeglądania treści multimedialnych. Szczegóły: [`lampa.md`](https://github.com/Joy096/server/blob/main/lampa.md).
    ```bash
    wget -O lampa.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa.sh && sudo bash lampa.sh
    ```
*   **[`lampa_update.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa_update.sh):** Aktualizuje Lampa z repozytorium `yumata/lampa` i kopiuje pliki do `/var/www/lampa`. Przeznaczony do uruchamiania z crona.
    ```bash
    wget -O lampa_update.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/lampa_update.sh && sudo bash lampa_update.sh
    ```

#### ☁️ Oracle Cloud

*   **[`oracle.sh`](https://github.com/Joy096/server/raw/refs/heads/main/oracle.sh):** Automatycznie tworzy darmowy serwer Oracle Cloud (Ampere lub Micro): szuka wolnego miejsca w tle i pisze na Telegramie, gdy serwer zostanie utworzony. Pokazuje też Twoje serwery, zmienia CPU, pamięć i dysk oraz usuwa serwery. Szczegóły: [`oracle.md`](https://github.com/Joy096/server/blob/main/oracle.md).
    ```bash
    wget -O oracle.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/oracle.sh && sudo bash oracle.sh
    ```
*   **[`keepalive.sh`](https://github.com/Joy096/server/raw/refs/heads/main/keepalive.sh):** Chroni darmowy serwer Oracle przed wyłączeniem z powodu bezczynności: na Ampere zajmuje część pamięci, na Micro robi krótkie skoki obciążenia CPU. Uruchamiaj go na samym serwerze Oracle. Szczegóły: [`keepalive.md`](https://github.com/Joy096/server/blob/main/keepalive.md).
    ```bash
    wget -O keepalive.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/keepalive.sh && sudo bash keepalive.sh
    ```

#### 🧩 Inne

*   **[`minecraft_bedrock.sh`](https://github.com/Joy096/server/raw/refs/heads/main/minecraft_bedrock.sh):** Instalacja i zarządzanie wieloma serwerami Minecraft Bedrock Edition: konfiguracja i kopie zapasowe.
    ```bash
    wget -O minecraft_bedrock.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/minecraft_bedrock.sh && sudo bash minecraft_bedrock.sh
    ```
*   **[`tg_monitoring_group_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/tg_monitoring_group_bot.sh):** Instaluje bota Telegram, który śledzi wiadomości w grupie pod kątem słów kluczowych. Uruchamiaj jako zwykły użytkownik, bez `sudo`: usługa bota jest tworzona dla Twojego użytkownika.
    ```bash
    wget -O tg_monitoring_group_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/tg_monitoring_group_bot.sh && bash tg_monitoring_group_bot.sh
    ```
*   **[`meds_watch_bot.sh`](https://github.com/Joy096/server/raw/refs/heads/main/de_liku_bot/meds_watch_bot.sh):** Instaluje i konfiguruje bota Telegram „Де ліки Bot” (wyszukiwanie leków na tabletki.ua) jako usługę systemd. Dla Ubuntu Server 22.04.
    ```bash
    wget -O meds_watch_bot.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/de_liku_bot/meds_watch_bot.sh && sudo bash meds_watch_bot.sh
    ```
*   **[`usb_chromeos_ubuntu.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_ubuntu.sh):** Przygotowuje obraz ChromeOS (Brunch) do instalacji z USB: pyta o linki do obrazu recovery ChromeOS i do Brunch i buduje `chromeos.img` w `~/chrome_os`. Uruchamiaj jako zwykły użytkownik, bez `sudo`.
    ```bash
    wget -O usb_chromeos_ubuntu.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_ubuntu.sh && bash usb_chromeos_ubuntu.sh
    ```
*   **[`usb_chromeos_win.sh`](https://github.com/Joy096/server/raw/refs/heads/main/usb_chromeos_win.sh):** Wariant dla Windows: to samo, ale dodatkowo pyta o nazwę końcowego obrazu. ⚠️ Na końcu usuwa wszystkie pozostałe pliki w bieżącym folderze, dlatego poniższe polecenie uruchamia go w osobnym pustym folderze `~/chromeos`. Uruchamiaj bez `sudo`.
    ```bash
    mkdir -p ~/chromeos && cd ~/chromeos && wget -O usb_chromeos_win.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/usb_chromeos_win.sh && bash usb_chromeos_win.sh
    ```

### ▶️ Ogólne użycie

1.  **Wybierz skrypt** z listy powyżej i wklej jego polecenie do terminala serwera. Szablon polecenia:
    ```bash
    wget -O NAZWA_SKRYPTU.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/NAZWA_SKRYPTU.sh && sudo bash NAZWA_SKRYPTU.sh
    ```
    Opcja `-O` zapisuje plik pod tą nazwą na miejscu starego, dlatego ponowne uruchomienie zawsze pobiera najnowszą wersję.
2.  Postępuj zgodnie z instrukcjami wyświetlanymi przez skrypt.

### ⚠️ Ważne uwagi

*   **Uprawnienia Root:** **Większość skryptów musi być uruchamiana z uprawnieniami superużytkownika (`root` lub przez `sudo`),** ponieważ instalują oprogramowanie i modyfikują ustawienia systemowe. Wyjątki uruchamiane bez `sudo` są zaznaczone w ich opisach: `tg_monitoring_group_bot.sh`, `usb_chromeos_ubuntu.sh`, `usb_chromeos_win.sh`.
*   **Przegląd przed uruchomieniem:** Zawsze przeglądaj kod skryptu przed jego wykonaniem na serwerze, zwłaszcza podczas uruchamiania jako `root`. Upewnij się, że rozumiesz, jakie polecenia zostaną wykonane.
*   **Kompatybilność:** Skrypty są głównie przeznaczone dla systemów Debian/Ubuntu. Działanie na innych dystrybucjach nie jest gwarantowane. Niektóre skrypty używają Snap, a skrypty dla Oracle Cloud są przeznaczone dla serwerów Oracle.
*   **Restart:** `server_new.sh` i `updater.sh` na końcu restartują serwer.
*   **Samousunięcie:** Skrypty `server_new.sh`, `x-ui.sh`, `adguard_home.sh`, `outline_vpn.sh`, `lampa.sh`, `hysteria.sh` i `lego_cert.sh` usuwają się po zakończeniu. To nie problem: polecenie z listy w razie potrzeby pobierze je ponownie.
*   **Kopie zapasowe:** Przed zastosowaniem skryptów, zwłaszcza `server_new.sh`, zaleca się wykonanie kopii zapasowej ważnych danych lub systemu.
*   **"Tak jak jest":** Skrypty są dostarczane "tak jak są", bez żadnej gwarancji. Używaj ich na własne ryzyko.
