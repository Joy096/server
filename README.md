[English](#english) | [Українська](#українська) | [Polski](#polski) | [Русский](#русский)

---

<a name="english"></a>

## 🛡️ Cloudflare SSL Certificate Management Script using acme.sh (English)

This Bash script automates the process of obtaining and installing free SSL certificates from Let's Encrypt using `acme.sh` and Cloudflare DNS authentication. It also includes options to integrate certificates with popular applications like 3X-UI, Nextcloud (Snap), and AdGuard Home (Snap).

**⚠️ Important:** The script requires `root` privileges to run and **self-deletes** after execution for security. Save a copy if you plan to reuse it.

### ✨ Key Features

*   🚀 **Automatic `acme.sh` Installation**: Installs `acme.sh` if it's not found.
*   🔑 **Certificate Issuance via Cloudflare DNS**: Obtains standard and wildcard (`*.domain.com`) certificates using your Cloudflare API Key.
*   🔄 **Automatic Renewal**: Sets up a cron job via `acme.sh` for automatic certificate renewal.
*   📁 **Convenient Storage**: Saves certificate files to `/root/my_cert/YOUR_DOMAIN/`.
*   🔌 **Application Integration**:
    *   Install certificate for **3X-UI** panel.
    *   Install certificate for **Nextcloud** (installed via Snap).
    *   Install certificate for **AdGuard Home** (installed via Snap), including HTTPS setup and port conflict handling.
*   🗑️ **Complete Removal**: Option to remove `acme.sh`, all issued certificates, the cron job, and the `/root/my_cert` folder.
*   🎨 **Colorized Output**: Uses colors for better readability of messages.
*   🔥 **Self-Deletion**: The script automatically removes its file after execution (`trap 'rm -f "$SCRIPT_PATH"' EXIT`).

### 📋 Prerequisites

1.  **Linux Server**: Tested on Debian/Ubuntu, but should work on other distributions with `apt`, `yum`, `dnf`, or `pacman` (for `curl` installation).
2.  **Root Access**: The script must be run as `root` or using `sudo`.
3.  **Cloudflare-Managed Domain**: Your domain must use Cloudflare's DNS servers.
4.  **Cloudflare Global API Key**: You'll need your Global API Key and Cloudflare account email.
    *   Find the key here: [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (go to "API Keys" -> "Global API Key").
    *   **⚠️ Warning:** The Global API Key grants full access to your Cloudflare account. Handle it with care!
5.  **`curl` Utility**: The script will attempt to install `curl` if it's missing.

### 🚀 How to Use

1.  **Download the script** to your server. Let's name the file `cf_ssl.sh`.
    ```bash
    curl -o cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    # or using wget
    # wget -O cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    ```
2.  **Make the script executable**:
    ```bash
    chmod +x cf_ssl.sh
    ```
3.  **Run the script as root**:
    ```bash
    sudo ./cf_ssl.sh
    ```
4.  **Follow the menu instructions**: The script will present a menu with options.

    ```
    ================================
       Cloudflare SSL Certificate
    ================================
    1. Install acme and issue certificate with auto-renewal
    2. Remove acme.sh, certificates, cron job, and my_cert folder
    3. Show path to certificate files
    4. Install certificate in 3X-UI
    5. Install certificate in Nextcloud
    6. Install certificate in AdGuard Home
    0. Exit ❌
    ================================
    Enter action number (0-6):
    ```

5.  **Remember**: After selecting an option and its completion (or choosing "Exit"), the `cf_ssl.sh` file will be **deleted**.

### 🛠️ Menu Options

1.  **Install acme and issue certificate**:
    *   Checks/installs `acme.sh`.
    *   Prompts for your domain, Cloudflare Global API Key, and email.
    *   Uses `acme.sh` to issue a certificate (including wildcard) via Cloudflare DNS authentication.
    *   Sets up automatic renewal.
    *   Copies certificate files to `/root/my_cert/YOUR_DOMAIN/`.
2.  **Remove everything**:
    *   Executes `acme.sh --uninstall`.
    *   Removes the `acme.sh` cron job.
    *   Deletes the `~/.acme.sh/` directory.
    *   Deletes the `/root/my_cert/` directory with all certificates.
3.  **Show certificate file path**:
    *   Displays the paths to certificate files (`cert.pem`, `private.key`, `fullchain.pem`, `ca.pem`) for previously issued domains in `/root/my_cert/`.
4.  **Install certificate in 3X-UI**:
    *   Prompts for the domain for which to install the certificate.
    *   Copies `fullchain.pem` and `private.key` into the 3X-UI configuration.
    *   Restarts the `x-ui` service.
5.  **Install certificate in Nextcloud (Snap)**:
    *   Prompts for the domain.
    *   Copies certificates (`cert.pem`, `private.key`, `fullchain.pem`) to the Nextcloud Snap directory (`/var/snap/nextcloud/current/certs/custom/`).
    *   Activates the use of these certificates with the `nextcloud.enable-https custom` command.
    *   Restarts the Nextcloud Snap package.
6.  **Install certificate in AdGuard Home (Snap)**:
    *   Prompts for the domain.
    *   Copies `fullchain.pem` and `private.key` to the AdGuard Home Snap directory (`/var/snap/adguard-home/common/certs/`).
    *   Edits the `AdGuardHome.yaml` configuration file to enable TLS and specify certificate paths.
    *   Checks if port 443 is in use. If it is, prompts for an alternative HTTPS port for the AdGuard web interface and opens it in `ufw`.
    *   Restarts the AdGuard Home Snap package.
0.  **Exit**: Terminates the script (and it self-deletes).

### ⚠️ Important Notes

*   **API Key Security**: Your Cloudflare Global API Key is critical. Do not share it or store it insecurely. Consider using [Scoped API Tokens](https://developers.cloudflare.com/api/tokens/create/) in the future for enhanced security, although this script uses the Global Key.
*   **Self-Deletion**: Remember that the script file is deleted after use. If you want to keep it, make a copy before running it.
*   **Snap Applications**: The integration features for Nextcloud and AdGuard Home are specifically designed for Snap-installed versions. Paths and commands might differ for other installation methods.
*   **Backups**: Before making changes to the configuration of running services (Nextcloud, AdGuard), it's recommended to back up their settings.

---

<a name="українська"></a>

## 🛡️ Скрипт керування SSL-сертифікатами Cloudflare за допомогою acme.sh (Українська)

Цей Bash-скрипт автоматизує процес отримання та встановлення безкоштовних SSL-сертифікатів від Let's Encrypt за допомогою `acme.sh` та DNS-аутентифікації через Cloudflare. Він також містить опції для інтеграції сертифікатів з популярними додатками, такими як 3X-UI, Nextcloud (Snap) та AdGuard Home (Snap).

**⚠️ Важливо:** Скрипт вимагає прав `root` для виконання та **самовидаляється** після завершення роботи для безпеки. Збережіть копію, якщо плануєте використовувати його повторно.

### ✨ Основні можливості

*   🚀 **Автоматичне встановлення `acme.sh`**: Якщо `acme.sh` не знайдено, скрипт встановить його.
*   🔑 **Випуск сертифікатів через Cloudflare DNS**: Отримує стандартні та wildcard (`*.domain.com`) сертифікати, використовуючи ваш Cloudflare API Key.
*   🔄 **Автоматичне поновлення**: Налаштовує cron-завдання через `acme.sh` для автоматичного оновлення сертифікатів.
*   📁 **Зручне зберігання**: Зберігає файли сертифікатів у `/root/my_cert/ВАШ_ДОМЕН/`.
*   🔌 **Інтеграція з додатками**:
    *   Встановлення сертифіката для панелі **3X-UI**.
    *   Встановлення сертифіката для **Nextcloud** (встановленого через Snap).
    *   Встановлення сертифіката для **AdGuard Home** (встановленого через Snap), включно з налаштуванням HTTPS та обробкою конфліктів портів.
*   🗑️ **Повне видалення**: Можливість видалити `acme.sh`, усі випущені сертифікати, cron-завдання та папку `/root/my_cert`.
*   🎨 **Кольоровий вивід**: Використовує кольори для кращої читабельності повідомлень.
*   🔥 **Самовидалення**: Скрипт автоматично видаляє свій файл після виконання (`trap 'rm -f "$SCRIPT_PATH"' EXIT`).

### 📋 Передумови

1.  **Linux сервер**: Протестовано на Debian/Ubuntu, але має працювати на інших дистрибутивах з `apt`, `yum`, `dnf` або `pacman` (для встановлення `curl`).
2.  **Root доступ**: Скрипт необхідно запускати від імені користувача `root` або через `sudo`.
3.  **Домен, керований Cloudflare**: Ваш домен повинен використовувати DNS-сервери Cloudflare.
4.  **Cloudflare Global API Key**: Вам знадобиться ваш Global API Key та email акаунту Cloudflare.
    *   Знайти ключ можна тут: [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (перейдіть до розділу "API Keys" -> "Global API Key").
    *   **⚠️ Увага:** Global API Key надає повний доступ до вашого акаунту Cloudflare. Поводьтеся з ним обережно!
5.  **Утиліта `curl`**: Скрипт спробує встановити `curl`, якщо він відсутній.

### 🚀 Як використовувати

1.  **Завантажте скрипт** на ваш сервер. Нехай ім'я файлу буде `cf_ssl.sh`.
    ```bash
    curl -o cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    # або за допомогою wget
    # wget -O cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    ```
2.  **Зробіть скрипт виконуваним**:
    ```bash
    chmod +x cf_ssl.sh
    ```
3.  **Запустіть скрипт від імені root**:
    ```bash
    sudo ./cf_ssl.sh
    ```
4.  **Дотримуйтесь інструкцій у меню**: Скрипт надасть меню з опціями.

    ```
    ================================
       Cloudflare SSL Certificate
    ================================
    1. Встановити acme та випустити сертифікат з автопоновленням
    2. Видалити acme.sh, сертифікати, cron-завдання та папку my_cert
    3. Показати шлях до файлів сертифіката
    4. Встановити сертифікат у 3X-UI
    5. Встановити сертифікат у Nextcloud
    6. Встановити сертифікат у AdGuard Home
    0. Вийти ❌
    ================================
    Введіть номер дії (0-6):
    ```

5.  **Пам'ятайте**: Після вибору опції та її завершення (або вибору "Вийти"), файл `cf_ssl.sh` буде **видалено**.

### 🛠️ Опції меню

1.  **Встановити acme та випустити сертифікат**:
    *   Перевіряє/встановлює `acme.sh`.
    *   Запитує ваш домен, Cloudflare Global API Key та email.
    *   Використовує `acme.sh` для випуску сертифіката (включно з wildcard) через DNS-аутентифікацію Cloudflare.
    *   Налаштовує автоматичне поновлення.
    *   Копіює файли сертифіката до `/root/my_cert/ВАШ_ДОМЕН/`.
2.  **Видалити все**:
    *   Виконує команду `acme.sh --uninstall`.
    *   Видаляє cron-завдання `acme.sh`.
    *   Видаляє директорію `~/.acme.sh/`.
    *   Видаляє директорію `/root/my_cert/` з усіма сертифікатами.
3.  **Показати шлях до файлів сертифіката**:
    *   Відображає шляхи до файлів (`cert.pem`, `private.key`, `fullchain.pem`, `ca.pem`) для раніше випущених доменів у `/root/my_cert/`.
4.  **Встановити сертифікат у 3X-UI**:
    *   Запитує домен, для якого потрібно встановити сертифікат.
    *   Копіює `fullchain.pem` та `private.key` у конфігурацію 3X-UI.
    *   Перезапускає сервіс `x-ui`.
5.  **Встановити сертифікат у Nextcloud (Snap)**:
    *   Запитує домен.
    *   Копіює сертифікати (`cert.pem`, `private.key`, `fullchain.pem`) у директорію Nextcloud Snap (`/var/snap/nextcloud/current/certs/custom/`).
    *   Активує використання цих сертифікатів командою `nextcloud.enable-https custom`.
    *   Перезапускає Snap-пакет Nextcloud.
6.  **Встановити сертифікат у AdGuard Home (Snap)**:
    *   Запитує домен.
    *   Копіює `fullchain.pem` та `private.key` у директорію AdGuard Home Snap (`/var/snap/adguard-home/common/certs/`).
    *   Редагує файл конфігурації `AdGuardHome.yaml`, щоб увімкнути TLS та вказати шляхи до сертифікатів.
    *   Перевіряє, чи зайнятий порт 443. Якщо так, запитує альтернативний порт HTTPS для веб-інтерфейсу AdGuard та відкриває його в `ufw`.
    *   Перезапускає Snap-пакет AdGuard Home.
0.  **Вийти**: Завершує роботу скрипта (і він самовидаляється).

### ⚠️ Важливі зауваження

*   **Безпека API ключа**: Ваш Cloudflare Global API Key є критично важливим. Не діліться ним і не зберігайте його в небезпечних місцях. Розгляньте можливість використання [Scoped API Tokens](https://developers.cloudflare.com/api/tokens/create/) у майбутньому для підвищення безпеки, хоча цей скрипт використовує Global Key.
*   **Самовидалення**: Не забувайте, що файл скрипта видаляється після використання. Якщо ви хочете зберегти його, скопіюйте його перед запуском.
*   **Snap-додатки**: Функції інтеграції з Nextcloud та AdGuard Home розроблені спеціально для версій, встановлених через Snap. Для інших методів встановлення шляхи та команди можуть відрізнятися.
*   **Резервне копіювання**: Перед внесенням змін до конфігурації працюючих сервісів (Nextcloud, AdGuard) рекомендується зробити резервну копію їх налаштувань.

---

<a name="polski"></a>

## 🛡️ Skrypt do zarządzania certyfikatami SSL Cloudflare przy użyciu acme.sh (Polski)

Ten skrypt Bash automatyzuje proces uzyskiwania i instalowania darmowych certyfikatów SSL od Let's Encrypt za pomocą `acme.sh` i uwierzytelniania DNS przez Cloudflare. Zawiera również opcje integracji certyfikatów z popularnymi aplikacjami, takimi jak 3X-UI, Nextcloud (Snap) i AdGuard Home (Snap).

**⚠️ Ważne:** Skrypt wymaga uprawnień `root` do uruchomienia i **usuwa się samoczynnie** po zakończeniu działania ze względów bezpieczeństwa. Zapisz kopię, jeśli planujesz używać go ponownie.

### ✨ Kluczowe funkcje

*   🚀 **Automatyczna instalacja `acme.sh`**: Instaluje `acme.sh`, jeśli nie zostanie znaleziony.
*   🔑 **Wydawanie certyfikatów przez Cloudflare DNS**: Uzyskuje standardowe certyfikaty oraz certyfikaty wildcard (`*.domain.com`), używając Twojego Klucza API Cloudflare.
*   🔄 **Automatyczne odnawianie**: Konfiguruje zadanie cron za pomocą `acme.sh` do automatycznego odnawiania certyfikatów.
*   📁 **Wygodne przechowywanie**: Zapisuje pliki certyfikatów w `/root/my_cert/TWOJA_DOMENA/`.
*   🔌 **Integracja z aplikacjami**:
    *   Instalacja certyfikatu dla panelu **3X-UI**.
    *   Instalacja certyfikatu dla **Nextcloud** (zainstalowanego przez Snap).
    *   Instalacja certyfikatu dla **AdGuard Home** (zainstalowanego przez Snap), w tym konfiguracja HTTPS i obsługa konfliktów portów.
*   🗑️ **Całkowite usunięcie**: Opcja usunięcia `acme.sh`, wszystkich wydanych certyfikatów, zadania cron i folderu `/root/my_cert`.
*   🎨 **Kolorowe komunikaty**: Używa kolorów dla lepszej czytelności komunikatów.
*   🔥 **Samousunięcie**: Skrypt automatycznie usuwa swój plik po wykonaniu (`trap 'rm -f "$SCRIPT_PATH"' EXIT`).

### 📋 Wymagania wstępne

1.  **Serwer Linux**: Testowany na Debian/Ubuntu, ale powinien działać na innych dystrybucjach z `apt`, `yum`, `dnf` lub `pacman` (do instalacji `curl`).
2.  **Dostęp root**: Skrypt musi być uruchamiany jako użytkownik `root` lub przez `sudo`.
3.  **Domena zarządzana przez Cloudflare**: Twoja domena musi używać serwerów DNS Cloudflare.
4.  **Cloudflare Global API Key**: Będziesz potrzebować swojego Global API Key oraz adresu e-mail konta Cloudflare.
    *   Klucz znajdziesz tutaj: [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (przejdź do sekcji "API Keys" -> "Global API Key").
    *   **⚠️ Ostrzeżenie:** Global API Key zapewnia pełny dostęp do Twojego konta Cloudflare. Obchodź się z nim ostrożnie!
5.  **Narzędzie `curl`**: Skrypt spróbuje zainstalować `curl`, jeśli go brakuje.

### 🚀 Jak używać

1.  **Pobierz skrypt** na swój serwer. Nazwijmy plik `cf_ssl.sh`.
    ```bash
    curl -o cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    # lub używając wget
    # wget -O cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    ```
2.  **Nadaj skryptowi uprawnienia do wykonania**:
    ```bash
    chmod +x cf_ssl.sh
    ```
3.  **Uruchom skrypt jako root**:
    ```bash
    sudo ./cf_ssl.sh
    ```
4.  **Postępuj zgodnie z instrukcjami w menu**: Skrypt wyświetli menu z opcjami.

    ```
    ================================
       Cloudflare SSL Certificate
    ================================
    1. Zainstaluj acme i wydaj certyfikat z automatycznym odnawianiem
    2. Usuń acme.sh, certyfikaty, zadanie cron i folder my_cert
    3. Pokaż ścieżkę do plików certyfikatu
    4. Zainstaluj certyfikat w 3X-UI
    5. Zainstaluj certyfikat w Nextcloud
    6. Zainstaluj certyfikat w AdGuard Home
    0. Wyjdź ❌
    ================================
    Wprowadź numer działania (0-6):
    ```

5.  **Pamiętaj**: Po wybraniu opcji i jej zakończeniu (lub wybraniu "Wyjdź"), plik `cf_ssl.sh` zostanie **usunięty**.

### 🛠️ Opcje menu

1.  **Zainstaluj acme i wydaj certyfikat**:
    *   Sprawdza/instaluje `acme.sh`.
    *   Pyta o Twoją domenę, Cloudflare Global API Key i adres e-mail.
    *   Używa `acme.sh` do wydania certyfikatu (w tym wildcard) poprzez uwierzytelnianie DNS Cloudflare.
    *   Konfiguruje automatyczne odnawianie.
    *   Kopiuje pliki certyfikatu do `/root/my_cert/TWOJA_DOMENA/`.
2.  **Usuń wszystko**:
    *   Wykonuje polecenie `acme.sh --uninstall`.
    *   Usuwa zadanie cron `acme.sh`.
    *   Usuwa katalog `~/.acme.sh/`.
    *   Usuwa katalog `/root/my_cert/` ze wszystkimi certyfikatami.
3.  **Pokaż ścieżkę do plików certyfikatu**:
    *   Wyświetla ścieżki do plików certyfikatów (`cert.pem`, `private.key`, `fullchain.pem`, `ca.pem`) dla wcześniej wydanych domen w `/root/my_cert/`.
4.  **Zainstaluj certyfikat w 3X-UI**:
    *   Pyta o domenę, dla której ma zostać zainstalowany certyfikat.
    *   Kopiuje `fullchain.pem` i `private.key` do konfiguracji 3X-UI.
    *   Restartuje usługę `x-ui`.
5.  **Zainstaluj certyfikat w Nextcloud (Snap)**:
    *   Pyta o domenę.
    *   Kopiuje certyfikaty (`cert.pem`, `private.key`, `fullchain.pem`) do katalogu Nextcloud Snap (`/var/snap/nextcloud/current/certs/custom/`).
    *   Aktywuje użycie tych certyfikatów poleceniem `nextcloud.enable-https custom`.
    *   Restartuje pakiet Snap Nextcloud.
6.  **Zainstaluj certyfikat w AdGuard Home (Snap)**:
    *   Pyta o domenę.
    *   Kopiuje `fullchain.pem` i `private.key` do katalogu AdGuard Home Snap (`/var/snap/adguard-home/common/certs/`).
    *   Edytuje plik konfiguracyjny `AdGuardHome.yaml`, aby włączyć TLS i określić ścieżki do certyfikatów.
    *   Sprawdza, czy port 443 jest zajęty. Jeśli tak, pyta o alternatywny port HTTPS dla interfejsu webowego AdGuard i otwiera go w `ufw`.
    *   Restartuje pakiet Snap AdGuard Home.
0.  **Wyjdź**: Kończy działanie skryptu (a on sam się usuwa).

### ⚠️ Ważne uwagi

*   **Bezpieczeństwo Klucza API**: Twój Cloudflare Global API Key jest krytyczny. Nie udostępniaj go ani nie przechowuj w niezabezpieczonych miejscach. Rozważ użycie [Scoped API Tokens](https://developers.cloudflare.com/api/tokens/create/) w przyszłości dla zwiększenia bezpieczeństwa, chociaż ten skrypt używa Global Key.
*   **Samousunięcie**: Pamiętaj, że plik skryptu jest usuwany po użyciu. Jeśli chcesz go zachować, zrób kopię przed uruchomieniem.
*   **Aplikacje Snap**: Funkcje integracji z Nextcloud i AdGuard Home są zaprojektowane specjalnie dla wersji zainstalowanych przez Snap. Ścieżki i polecenia mogą się różnić dla innych metod instalacji.
*   **Kopie zapasowe**: Przed wprowadzeniem zmian w konfiguracji działających usług (Nextcloud, AdGuard) zaleca się wykonanie kopii zapasowej ich ustawień.

---

<a name="русский"></a>

## 🛡️ Скрипт управления SSL-сертификатами Cloudflare с помощью acme.sh (Русский)

Этот Bash-скрипт автоматизирует процесс получения и установки бесплатных SSL-сертификатов от Let's Encrypt с использованием `acme.sh` и DNS-аутентификации через Cloudflare. Он также включает опции для интеграции сертификатов с популярными приложениями, такими как 3X-UI, Nextcloud (Snap) и AdGuard Home (Snap).

**⚠️ Важно:** Скрипт требует прав `root` для выполнения и **самоудаляется** после завершения работы для безопасности. Сохраните копию, если планируете использовать его повторно.

### ✨ Основные возможности

*   🚀 **Автоматическая установка `acme.sh`**: Если `acme.sh` не найден, скрипт установит его.
*   🔑 **Выпуск сертификатов через Cloudflare DNS**: Получает стандартные и wildcard (`*.domain.com`) сертификаты, используя ваш Cloudflare API Key.
*   🔄 **Автоматическое продление**: Настраивает cron-задачу через `acme.sh` для автоматического обновления сертификатов.
*   📁 **Удобное хранение**: Сохраняет файлы сертификатов в `/root/my_cert/ВАШ_ДОМЕН/`.
*   🔌 **Интеграция с приложениями**:
    *   Установка сертификата для панели **3X-UI**.
    *   Установка сертификата для **Nextcloud** (установленного через Snap).
    *   Установка сертификата для **AdGuard Home** (установленного через Snap), включая настройку HTTPS и обработку конфликтов портов.
*   🗑️ **Полное удаление**: Возможность удалить `acme.sh`, все выпущенные сертификаты, cron-задачу и папку `/root/my_cert`.
*   🎨 **Цветной вывод**: Использует цвета для лучшей читаемости сообщений.
*   🔥 **Самоудаление**: Скрипт автоматически удаляет свой файл после выполнения (`trap 'rm -f "$SCRIPT_PATH"' EXIT`).

### 📋 Предварительные требования

1.  **Linux сервер**: Протестировано на Debian/Ubuntu, но должно работать на других дистрибутивах с `apt`, `yum`, `dnf` или `pacman` (для установки `curl`).
2.  **Root доступ**: Скрипт необходимо запускать от имени пользователя `root` или через `sudo`.
3.  **Домен, управляемый Cloudflare**: Ваш домен должен использовать DNS-серверы Cloudflare.
4.  **Cloudflare Global API Key**: Вам понадобится ваш Global API Key и email аккаунта Cloudflare.
    *   Найти ключ можно здесь: [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (перейдите к разделу "API Keys" -> "Global API Key").
    *   **⚠️ Внимание:** Global API Key предоставляет полный доступ к вашему аккаунту Cloudflare. Обращайтесь с ним осторожно!
5.  **Утилита `curl`**: Скрипт попытается установить `curl`, если он отсутствует.

### 🚀 Как использовать

1.  **Загрузите скрипт** на ваш сервер. Пусть имя файла будет `cf_ssl.sh`.
    ```bash
    curl -o cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    # или с помощью wget
    # wget -O cf_ssl.sh https://github.com/Joy096/server/raw/refs/heads/main/cloudflare_ssl.sh
    ```
2.  **Сделайте скрипт исполняемым**:
    ```bash
    chmod +x cf_ssl.sh
    ```
3.  **Запустите скрипт от имени root**:
    ```bash
    sudo ./cf_ssl.sh
    ```
4.  **Следуйте инструкциям в меню**: Скрипт предоставит меню с опциями.

    ```
    ================================
       Cloudflare SSL Certificate
    ================================
    1. Установить acme и выпустить сертификат с автообновлением
    2. Удалить acme.sh, сертификаты, cron-задачу и папку my_cert
    3. Показать путь к файлам сертификата
    4. Установить сертификат в 3X-UI
    5. Установить сертификат в Nextcloud
    6. Установить сертификат в AdGuard Home
    0. Выйти ❌
    ================================
    Введите номер действия (0-6):
    ```

5.  **Помните**: После выбора опции и её завершения (или выбора "Выйти"), файл `cf_ssl.sh` будет **удален**.

### 🛠️ Опции меню

1.  **Установить acme и выпустить сертификат**:
    *   Проверяет/устанавливает `acme.sh`.
    *   Запрашивает ваш домен, Cloudflare Global API Key и email.
    *   Использует `acme.sh` для выпуска сертификата (включая wildcard) через DNS-аутентификацию Cloudflare.
    *   Настраивает автоматическое продление.
    *   Копирует файлы сертификата в `/root/my_cert/ВАШ_ДОМЕН/`.
2.  **Удалить всё**:
    *   Выполняет команду `acme.sh --uninstall`.
    *   Удаляет cron-задачу `acme.sh`.
    *   Удаляет директорию `~/.acme.sh/`.
    *   Удаляет директорию `/root/my_cert/` со всеми сертификатами.
3.  **Показать путь к файлам сертификата**:
    *   Отображает пути к файлам (`cert.pem`, `private.key`, `fullchain.pem`, `ca.pem`) для ранее выпущенных доменов в `/root/my_cert/`.
4.  **Установить сертификат в 3X-UI**:
    *   Запрашивает домен, для которого нужно установить сертификат.
    *   Копирует `fullchain.pem` и `private.key` в конфигурацию 3X-UI.
    *   Перезапускает сервис `x-ui`.
5.  **Установить сертификат в Nextcloud (Snap)**:
    *   Запрашивает домен.
    *   Копирует сертификаты (`cert.pem`, `private.key`, `fullchain.pem`) в директорию Nextcloud Snap (`/var/snap/nextcloud/current/certs/custom/`).
    *   Активирует использование этих сертификатов командой `nextcloud.enable-https custom`.
    *   Перезапускает Snap-пакет Nextcloud.
6.  **Установить сертификат в AdGuard Home (Snap)**:
    *   Запрашивает домен.
    *   Копирует `fullchain.pem` и `private.key` в директорию AdGuard Home Snap (`/var/snap/adguard-home/common/certs/`).
    *   Редактирует файл конфигурации `AdGuardHome.yaml`, чтобы включить TLS и указать пути к сертификатам.
    *   Проверяет, занят ли порт 443. Если занят, запрашивает альтернативный порт HTTPS для веб-интерфейса AdGuard и открывает его в `ufw`.
    *   Перезапускает Snap-пакет AdGuard Home.
0.  **Выйти**: Завершает работу скрипта (и он самоудаляется).

### ⚠️ Важные замечания

*   **Безопасность API ключа**: Ваш Cloudflare Global API Key является критически важным. Не делитесь им и не храните его в небезопасных местах. Рассмотрите возможность использования [Scoped API Tokens](https://developers.cloudflare.com/api/tokens/create/) в будущем для повышения безопасности, хотя данный скрипт использует Global Key.
*   **Самоудаление**: Не забывайте, что файл скрипта удаляется после использования. Если вы хотите сохранить его, скопируйте его перед запуском.
*   **Snap-приложения**: Функции интеграции с Nextcloud и AdGuard Home разработаны специально для версий, установленных через Snap. Для других методов установки пути и команды могут отличаться.
*   **Резервное копирование**: Перед внесением изменений в конфигурацию работающих сервисов (Nextcloud, AdGuard) рекомендуется сделать резервную копию их настроек.
