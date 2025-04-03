[Русский](#русский) | [Українська](#українська) | [English](#english) | [Polski](#polski)

---

<a name="русский"></a>

## 🚀 Скрипты для настройки сервера Linux

Добро пожаловать! Этот репозиторий содержит коллекцию Bash-скриптов для упрощения и автоматизации установки и базовой настройки различного ПО на серверах Linux (в основном протестировано на Debian/Ubuntu).

### 🛠️ Ключевые скрипты

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Выполняет первоначальную настройку сервера, включая обновление системы, установку Docker, настройку брандмауэра UFW и другие базовые утилиты.
*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh):** Устанавливает `acme.sh` для получения и автообновления SSL-сертификатов Let's Encrypt через Cloudflare DNS. Позволяет интегрировать сертификаты с 3X-UI, Nextcloud (Snap) и AdGuard Home (Snap). *Внимание: Скрипт самоудаляется после выполнения.*
*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Устанавливает панель управления прокси-сервисами 3X-UI (форк X-UI).
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Устанавливает сетевой блокировщик рекламы и трекеров AdGuard Home (через Snap).
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Устанавливает VPN-сервер Outline для простого создания и управления VPN-доступом.
*   **[`qBittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qBittorrent.sh):** Устанавливает популярный торрент-клиент qBittorrent с веб-интерфейсом.
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Устанавливает TorrServer Matroska, позволяющий смотреть торренты онлайн без полной загрузки.
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Устанавливает Jackett - прокси-сервер для работы с API различных торрент-трекеров.
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Устанавливает Lampa – веб-интерфейс для просмотра медиаконтента.

### ▶️ Общее использование

1.  **Загрузите нужный скрипт:**
    ```bash
    # Пример с curl:
    curl -O [ССЫЛКА_НА_RAW_СКРИПТ]
    # Пример с wget:
    # wget [ССЫЛКА_НА_RAW_СКРИПТ]
    ```
    Замените `[ССЫЛКА_НА_RAW_СКРИПТ]` на прямую ссылку на файл скрипта (например, `https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh`).
2.  **Сделайте его исполняемым:**
    ```bash
    chmod +x ИМЯ_СКРИПТА.sh
    ```
3.  **Запустите с правами root:**
    ```bash
    sudo ./ИМЯ_СКРИПТА.sh
    ```
4.  Следуйте инструкциям на экране, которые выводит скрипт.

### ⚠️ Важные замечания

*   **Права Root:** **Большинство скриптов необходимо запускать с правами суперпользователя (`root` или через `sudo`),** так как они устанавливают ПО и изменяют системные настройки.
*   **Просмотр перед запуском:** Всегда просматривайте код скрипта перед его выполнением на сервере, особенно при запуске от имени `root`. Убедитесь, что вы понимаете, какие команды он будет выполнять.
*   **Совместимость:** Скрипты в основном ориентированы на Debian/Ubuntu. Работа на других дистрибутивах не гарантируется. Некоторые скрипты используют Snap.
*   **Самоудаление:** Скрипт `cloudflare_ssl.sh` удаляет себя после завершения. Сохраните копию, если он понадобится снова.
*   **Резервные копии:** Перед применением скриптов, особенно `server_new.sh`, рекомендуется сделать резервную копию важных данных или системы.
*   **"Как есть":** Скрипты предоставляются "как есть", без гарантий. Используйте их на свой страх и риск.

---

<a name="українська"></a>

## 🚀 Скрипти для налаштування сервера Linux

Ласкаво просимо! Цей репозиторій містить колекцію Bash-скриптів для спрощення та автоматизації встановлення та базового налаштування різноманітного ПЗ на серверах Linux (переважно протестовано на Debian/Ubuntu).

### 🛠️ Ключові скрипти

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Виконує початкове налаштування сервера, включно з оновленням системи, встановленням Docker, налаштуванням брандмауера UFW та інших базових утиліт.
*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh):** Встановлює `acme.sh` для отримання та автооновлення SSL-сертифікатів Let's Encrypt через Cloudflare DNS. Дозволяє інтегрувати сертифікати з 3X-UI, Nextcloud (Snap) та AdGuard Home (Snap). *Увага: Скрипт самовидаляється після виконання.*
*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Встановлює панель керування проксі-сервісами 3X-UI (форк X-UI).
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Встановлює мережевий блокувальник реклами та трекерів AdGuard Home (через Snap).
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Встановлює VPN-сервер Outline для простого створення та керування VPN-доступом.
*   **[`qBittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qBittorrent.sh):** Встановлює популярний торент-клієнт qBittorrent з веб-інтерфейсом.
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Встановлює TorrServer Matroska, що дозволяє дивитися торенти онлайн без повного завантаження.
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Встановлює Jackett - проксі-сервер для роботи з API різноманітних торент-трекерів.
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Встановлює Lampa – веб-інтерфейс для перегляду медіаконтенту.

### ▶️ Загальне використання

1.  **Завантажте потрібний скрипт:**
    ```bash
    # Приклад з curl:
    curl -O [ПОСИЛАННЯ_НА_RAW_СКРИПТ]
    # Приклад з wget:
    # wget [ПОСИЛАННЯ_НА_RAW_СКРИПТ]
    ```
    Замініть `[ПОСИЛАННЯ_НА_RAW_СКРИПТ]` на пряме посилання на файл скрипта (наприклад, `https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh`).
2.  **Зробіть його виконуваним:**
    ```bash
    chmod +x ІМЯ_СКРИПТА.sh
    ```
3.  **Запустіть з правами root:**
    ```bash
    sudo ./ІМЯ_СКРИПТА.sh
    ```
4.  Дотримуйтесь інструкцій на екрані, які виводить скрипт.

### ⚠️ Важливі зауваження

*   **Права Root:** **Більшість скриптів необхідно запускати з правами суперкористувача (`root` або через `sudo`),** оскільки вони встановлюють ПЗ та змінюють системні налаштування.
*   **Перегляд перед запуском:** Завжди переглядайте код скрипта перед його виконанням на сервері, особливо під час запуску від імені `root`. Переконайтеся, що ви розумієте, які команди він виконуватиме.
*   **Сумісність:** Скрипти переважно орієнтовані на Debian/Ubuntu. Робота на інших дистрибутивах не гарантується. Деякі скрипти використовують Snap.
*   **Самовидалення:** Скрипт `cloudflare_ssl.sh` видаляє себе після завершення. Збережіть копію, якщо він знадобиться знову.
*   **Резервні копії:** Перед застосуванням скриптів, особливо `server_new.sh`, рекомендується зробити резервну копію важливих даних або системи.
*   **"Як є":** Скрипти надаються "як є", без гарантій. Використовуйте їх на свій ризик.

---

<a name="english"></a>

## 🚀 Linux Server Setup Scripts

Welcome! This repository contains a collection of Bash scripts to simplify and automate the installation and basic configuration of various software on Linux servers (primarily tested on Debian/Ubuntu).

### 🛠️ Key Scripts

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Performs initial server setup, including system updates, Docker installation, UFW firewall configuration, and other basic utilities.
*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh):** Installs `acme.sh` to obtain and auto-renew Let's Encrypt SSL certificates via Cloudflare DNS. Allows integration with 3X-UI, Nextcloud (Snap), and AdGuard Home (Snap). *Warning: The script self-deletes after execution.*
*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Installs the 3X-UI proxy service management panel (a fork of X-UI).
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Installs the network-wide ad and tracker blocker AdGuard Home (via Snap).
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Installs the Outline VPN server for easy creation and management of VPN access.
*   **[`qBittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qBittorrent.sh):** Installs the popular qBittorrent torrent client with its web UI.
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Installs TorrServer Matroska, allowing online torrent streaming without full download.
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Installs Jackett - a proxy server for working with the APIs of various torrent trackers.
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Installs Lampa – ф web interface for viewing media content.

### ▶️ General Usage

1.  **Download the desired script:**
    ```bash
    # Example using curl:
    curl -O [RAW_SCRIPT_LINK]
    # Example using wget:
    # wget [RAW_SCRIPT_LINK]
    ```
    Replace `[RAW_SCRIPT_LINK]` with the direct link to the script file (e.g., `https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh`).
2.  **Make it executable:**
    ```bash
    chmod +x SCRIPT_NAME.sh
    ```
3.  **Run with root privileges:**
    ```bash
    sudo ./SCRIPT_NAME.sh
    ```
4.  Follow the on-screen instructions provided by the script.

### ⚠️ Important Notes

*   **Root Privileges:** **Most scripts must be run with superuser privileges (`root` or via `sudo`)** as they install software and modify system settings.
*   **Review Before Running:** Always review the script's code before executing it on your server, especially when running as `root`. Ensure you understand the commands it will run.
*   **Compatibility:** Scripts are primarily targeted at Debian/Ubuntu. Functionality on other distributions is not guaranteed. Some scripts use Snap.
*   **Self-Deletion:** The `cloudflare_ssl.sh` script deletes itself upon completion. Save a copy if you need it again.
*   **Backups:** Before applying scripts, especially `server_new.sh`, it is recommended to back up important data or the system.
*   **"As Is":** The scripts are provided "as is" without warranty. Use them at your own risk.

---

<a name="polski"></a>

## 🚀 Skrypty do konfiguracji serwera Linux

Witaj! To repozytorium zawiera kolekcję skryptów Bash do uproszczenia i automatyzacji instalacji oraz podstawowej konfiguracji różnego oprogramowania na serwerach Linux (głównie testowane na Debian/Ubuntu).

### 🛠️ Kluczowe skrypty

*   **[`server_new.sh`](https://github.com/Joy096/server/raw/refs/heads/main/server_new.sh):** Przeprowadza wstępną konfigurację serwera, w tym aktualizację systemu, instalację Dockera, konfigurację zapory UFW i innych podstawowych narzędzi.
*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh):** Instaluje `acme.sh` do uzyskiwania i automatycznego odnawiania certyfikatów SSL Let's Encrypt przez Cloudflare DNS. Umożliwia integrację certyfikatów z 3X-UI, Nextcloud (Snap) i AdGuard Home (Snap). *Uwaga: Skrypt usuwa się samoczynnie po wykonaniu.*
*   **[`x-ui.sh`](https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh):** Instaluje panel zarządzania usługami proxy 3X-UI (fork X-UI).
*   **[`adguard_home.sh`](https://github.com/Joy096/server/raw/refs/heads/main/adguard_home.sh):** Instaluje sieciowy bloker reklam i trackerów AdGuard Home (przez Snap).
*   **[`outline_vpn.sh`](https://github.com/Joy096/server/raw/refs/heads/main/outline_vpn.sh):** Instaluje serwer VPN Outline do łatwego tworzenia i zarządzania dostępem VPN.
*   **[`qBittorrent.sh`](https://github.com/Joy096/server/raw/refs/heads/main/qBittorrent.sh):** Instaluje popularnego klienta torrent qBittorrent z interfejsem webowym.
*   **[`torrserver.sh`](https://github.com/Joy096/server/raw/refs/heads/main/torrserver.sh):** Instaluje TorrServer Matroska, pozwalający oglądać torrenty online bez pełnego pobierania.
*   **[`jackett.sh`](https://github.com/Joy096/server/raw/refs/heads/main/jackett.sh):** Instaluje Jackett - serwer proxy do pracy z API różnych trackerów torrent.
*   **[`lampa.sh`](https://github.com/Joy096/server/raw/refs/heads/main/lampa.sh):** Instaluje Lampa – interfejs webowy do przeglądania treści multimedialnych.

### ▶️ Ogólne użycie

1.  **Pobierz potrzebny skrypt:**
    ```bash
    # Przykład użycia curl:
    curl -O [LINK_DO_RAW_SKRYPTU]
    # Przykład użycia wget:
    # wget [LINK_DO_RAW_SKRYPTU]
    ```
    Zastąp `[LINK_DO_RAW_SKRYPTU]` bezpośrednim linkiem do pliku skryptu (np. `https://github.com/Joy096/server/raw/refs/heads/main/x-ui.sh`).
2.  **Nadaj mu uprawnienia do wykonania:**
    ```bash
    chmod +x NAZWA_SKRYPTU.sh
    ```
3.  **Uruchom z uprawnieniami root:**
    ```bash
    sudo ./NAZWA_SKRYPTU.sh
    ```
4.  Postępuj zgodnie z instrukcjami wyświetlanymi przez skrypt.

### ⚠️ Ważne uwagi

*   **Uprawnienia Root:** **Większość skryptów musi być uruchamiana z uprawnieniami superużytkownika (`root` lub przez `sudo`),** ponieważ instalują oprogramowanie i modyfikują ustawienia systemowe.
*   **Przegląd przed uruchomieniem:** Zawsze przeglądaj kod skryptu przed jego wykonaniem na serwerze, zwłaszcza podczas uruchamiania jako `root`. Upewnij się, że rozumiesz, jakie polecenia zostaną wykonane.
*   **Kompatybilność:** Skrypty są głównie przeznaczone dla systemów Debian/Ubuntu. Działanie na innych dystrybucjach nie jest gwarantowane. Niektóre skrypty używają Snap.
*   **Samousunięcie:** Skrypt `cloudflare_ssl.sh` usuwa się po zakończeniu. Zachowaj kopię, jeśli będzie ponownie potrzebny.
*   **Kopie zapasowe:** Przed zastosowaniem skryptów, zwłaszcza `server_new.sh`, zaleca się wykonanie kopii zapasowej ważnych danych lub systemu.
*   **"Tak jak jest":** Skrypty są dostarczane "tak jak są", bez żadnej gwarancji. Używaj ich na własne ryzyko.
