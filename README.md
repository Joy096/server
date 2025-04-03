[English](#english) | [Українська](#українська) | [Polski](#polski) | [Русский](#русский)

---

<a name="english"></a>

## 🚀 Joy096/server - Linux Server Utility Scripts (English)

Welcome to the `Joy096/server` repository! This is a collection of Bash scripts designed to simplify and automate the installation and basic configuration of various popular services and tools on Linux servers (primarily tested on Debian/Ubuntu).

### Included Scripts

*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/blob/main/cloudflare_ssl.sh):**
    *   Installs `acme.sh` and obtains Let's Encrypt SSL certificates (including wildcards) using Cloudflare DNS API.
    *   Sets up automatic certificate renewal.
    *   Provides options to automatically install certificates into 3X-UI, Nextcloud (Snap), and AdGuard Home (Snap).
    *   *Note:* This script self-deletes after execution for security.
*   **[`xui_install.sh`](https://github.com/Joy096/server/blob/main/xui_install.sh):**
    *   Installs the 3X-UI panel (a popular panel for managing proxy services like VLESS, VMess, Trojan).
*   **[`nextcloud_install.sh`](https://github.com/Joy096/server/blob/main/nextcloud_install.sh):**
    *   Installs Nextcloud using the official Snap package, providing a self-hosted cloud storage and collaboration platform.
*   **[`adguard_install.sh`](https://github.com/Joy096/server/blob/main/adguard_install.sh):**
    *   Installs AdGuard Home using the official Snap package, setting up a network-wide ad & tracker blocker.
*   **[`docker_install.sh`](https://github.com/Joy096/server/blob/main/docker_install.sh):**
    *   Installs Docker Engine and Docker Compose, enabling containerized application deployment.
*   **[`fail2ban_install.sh`](https://github.com/Joy096/server/blob/main/fail2ban_install.sh):**
    *   Installs and enables Fail2ban with a basic configuration to protect SSH from brute-force attacks.
*   **[`warp.sh`](https://github.com/Joy096/server/blob/main/warp.sh):**
    *   Installs and configures Cloudflare WARP, potentially for use as a SOCKS5 proxy or to change the server's outgoing IP address. (Verify script details for exact functionality).

### General Usage

1.  **Download the desired script:**
    ```bash
    # Example using curl:
    curl -O https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    # Example using wget:
    # wget https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    ```
    Replace `SCRIPT_NAME.sh` with the actual script filename (e.g., `docker_install.sh`).
2.  **Make it executable:**
    ```bash
    chmod +x SCRIPT_NAME.sh
    ```
3.  **Run with root privileges:**
    ```bash
    sudo ./SCRIPT_NAME.sh
    ```
4.  Follow any on-screen prompts provided by the script.

### ⚠️ Important Notes

*   **Root Privileges:** Most scripts require `root` or `sudo` access to install packages and modify system configurations.
*   **Review Before Running:** **Always review the script's code before executing it on your server, especially when running as root.** Understand what commands it will run.
*   **Compatibility:** Scripts are primarily developed and tested on Debian/Ubuntu systems. Compatibility with other distributions may vary. Specific scripts might target Snap package installations (Nextcloud, AdGuard).
*   **Self-Deletion:** The `cloudflare_ssl.sh` script deletes itself upon completion. Make a copy if you need to reuse it without redownloading. Check other scripts if this behavior is intended elsewhere.
*   **Backups:** Before running installation scripts that might alter system configurations or install major software, ensure you have adequate backups.
*   **Use As-Is:** These scripts are provided "as-is" without warranty. Use them at your own risk.

---

<a name="українська"></a>

## 🚀 Joy096/server - Утилітні скрипти для сервера Linux (Українська)

Ласкаво просимо до репозиторію `Joy096/server`! Це колекція Bash-скриптів, призначених для спрощення та автоматизації встановлення та базової конфігурації різноманітних популярних сервісів та інструментів на серверах Linux (переважно протестовано на Debian/Ubuntu).

### Наявні скрипти

*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/blob/main/cloudflare_ssl.sh):**
    *   Встановлює `acme.sh` та отримує SSL-сертифікати Let's Encrypt (включно з wildcard) за допомогою Cloudflare DNS API.
    *   Налаштовує автоматичне поновлення сертифікатів.
    *   Надає опції для автоматичного встановлення сертифікатів у 3X-UI, Nextcloud (Snap) та AdGuard Home (Snap).
    *   *Примітка:* Цей скрипт самовидаляється після виконання для безпеки.
*   **[`xui_install.sh`](https://github.com/Joy096/server/blob/main/xui_install.sh):**
    *   Встановлює панель 3X-UI (популярна панель для керування проксі-сервісами, такими як VLESS, VMess, Trojan).
*   **[`nextcloud_install.sh`](https://github.com/Joy096/server/blob/main/nextcloud_install.sh):**
    *   Встановлює Nextcloud за допомогою офіційного Snap-пакету, надаючи платформу для власного хмарного сховища та співпраці.
*   **[`adguard_install.sh`](https://github.com/Joy096/server/blob/main/adguard_install.sh):**
    *   Встановлює AdGuard Home за допомогою офіційного Snap-пакету, налаштовуючи блокувальник реклами та трекерів для всієї мережі.
*   **[`docker_install.sh`](https://github.com/Joy096/server/blob/main/docker_install.sh):**
    *   Встановлює Docker Engine та Docker Compose, що дозволяє розгортати контейнеризовані додатки.
*   **[`fail2ban_install.sh`](https://github.com/Joy096/server/blob/main/fail2ban_install.sh):**
    *   Встановлює та вмикає Fail2ban з базовою конфігурацією для захисту SSH від атак перебору (brute-force).
*   **[`warp.sh`](https://github.com/Joy096/server/blob/main/warp.sh):**
    *   Встановлює та налаштовує Cloudflare WARP, потенційно для використання як SOCKS5 проксі або для зміни вихідної IP-адреси сервера. (Перевірте деталі скрипта для точної функціональності).

### Загальне використання

1.  **Завантажте потрібний скрипт:**
    ```bash
    # Приклад з curl:
    curl -O https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    # Приклад з wget:
    # wget https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    ```
    Замініть `SCRIPT_NAME.sh` на фактичне ім'я файлу скрипта (наприклад, `docker_install.sh`).
2.  **Зробіть його виконуваним:**
    ```bash
    chmod +x SCRIPT_NAME.sh
    ```
3.  **Запустіть з правами root:**
    ```bash
    sudo ./SCRIPT_NAME.sh
    ```
4.  Дотримуйтесь інструкцій на екрані, які надає скрипт.

### ⚠️ Важливі зауваження

*   **Права Root:** Більшість скриптів вимагають доступу `root` або `sudo` для встановлення пакетів та зміни системних конфігурацій.
*   **Перегляд перед запуском:** **Завжди переглядайте код скрипта перед його виконанням на сервері, особливо при запуску від імені root.** Розумійте, які команди він буде виконувати.
*   **Сумісність:** Скрипти переважно розроблені та протестовані на системах Debian/Ubuntu. Сумісність з іншими дистрибутивами може відрізнятися. Деякі скрипти можуть бути орієнтовані на встановлення через Snap (Nextcloud, AdGuard).
*   **Самовидалення:** Скрипт `cloudflare_ssl.sh` видаляє себе після завершення роботи. Зробіть копію, якщо потрібно використати його повторно без перезавантаження. Перевірте інші скрипти, якщо така поведінка передбачена і для них.
*   **Резервні копії:** Перед запуском інсталяційних скриптів, які можуть змінити конфігурацію системи або встановити основне програмне забезпечення, переконайтеся, що у вас є відповідні резервні копії.
*   **Використання "як є":** Ці скрипти надаються "як є" без гарантій. Використовуйте їх на свій ризик.

---

<a name="polski"></a>

## 🚀 Joy096/server - Skrypty narzędziowe dla serwera Linux (Polski)

Witamy w repozytorium `Joy096/server`! Jest to kolekcja skryptów Bash stworzonych w celu uproszczenia i automatyzacji instalacji oraz podstawowej konfiguracji różnych popularnych usług i narzędzi na serwerach Linux (głównie testowane na Debian/Ubuntu).

### Dostępne skrypty

*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/blob/main/cloudflare_ssl.sh):**
    *   Instaluje `acme.sh` i uzyskuje certyfikaty SSL Let's Encrypt (w tym wildcard) używając Cloudflare DNS API.
    *   Konfiguruje automatyczne odnawianie certyfikatów.
    *   Udostępnia opcje automatycznej instalacji certyfikatów w 3X-UI, Nextcloud (Snap) i AdGuard Home (Snap).
    *   *Uwaga:* Ten skrypt usuwa się samoczynnie po wykonaniu ze względów bezpieczeństwa.
*   **[`xui_install.sh`](https://github.com/Joy096/server/blob/main/xui_install.sh):**
    *   Instaluje panel 3X-UI (popularny panel do zarządzania usługami proxy, takimi jak VLESS, VMess, Trojan).
*   **[`nextcloud_install.sh`](https://github.com/Joy096/server/blob/main/nextcloud_install.sh):**
    *   Instaluje Nextcloud przy użyciu oficjalnego pakietu Snap, zapewniając własną platformę do przechowywania danych w chmurze i współpracy.
*   **[`adguard_install.sh`](https://github.com/Joy096/server/blob/main/adguard_install.sh):**
    *   Instaluje AdGuard Home przy użyciu oficjalnego pakietu Snap, konfigurując bloker reklam i trackerów dla całej sieci.
*   **[`docker_install.sh`](https://github.com/Joy096/server/blob/main/docker_install.sh):**
    *   Instaluje Docker Engine i Docker Compose, umożliwiając wdrażanie aplikacji w kontenerach.
*   **[`fail2ban_install.sh`](https://github.com/Joy096/server/blob/main/fail2ban_install.sh):**
    *   Instaluje i włącza Fail2ban z podstawową konfiguracją do ochrony SSH przed atakami typu brute-force.
*   **[`warp.sh`](https://github.com/Joy096/server/blob/main/warp.sh):**
    *   Instaluje i konfiguruje Cloudflare WARP, potencjalnie do użytku jako proxy SOCKS5 lub do zmiany wychodzącego adresu IP serwera. (Sprawdź szczegóły skryptu, aby poznać dokładną funkcjonalność).

### Ogólne użycie

1.  **Pobierz wybrany skrypt:**
    ```bash
    # Przykład użycia curl:
    curl -O https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    # Przykład użycia wget:
    # wget https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    ```
    Zastąp `SCRIPT_NAME.sh` rzeczywistą nazwą pliku skryptu (np. `docker_install.sh`).
2.  **Nadaj mu uprawnienia do wykonania:**
    ```bash
    chmod +x SCRIPT_NAME.sh
    ```
3.  **Uruchom z uprawnieniami root:**
    ```bash
    sudo ./SCRIPT_NAME.sh
    ```
4.  Postępuj zgodnie z komunikatami wyświetlanymi przez skrypt.

### ⚠️ Ważne uwagi

*   **Uprawnienia Root:** Większość skryptów wymaga dostępu `root` lub `sudo` do instalowania pakietów i modyfikowania konfiguracji systemu.
*   **Sprawdź przed uruchomieniem:** **Zawsze przejrzyj kod skryptu przed jego wykonaniem na serwerze, zwłaszcza gdy uruchamiasz go jako root.** Zrozum, jakie polecenia zostaną wykonane.
*   **Kompatybilność:** Skrypty są głównie tworzone i testowane na systemach Debian/Ubuntu. Kompatybilność z innymi dystrybucjami może być różna. Niektóre skrypty mogą być przeznaczone do instalacji za pomocą pakietów Snap (Nextcloud, AdGuard).
*   **Samousunięcie:** Skrypt `cloudflare_ssl.sh` usuwa się po zakończeniu działania. Zrób kopię, jeśli potrzebujesz go użyć ponownie bez ponownego pobierania. Sprawdź inne skrypty, jeśli takie zachowanie jest zamierzone również dla nich.
*   **Kopie zapasowe:** Przed uruchomieniem skryptów instalacyjnych, które mogą zmienić konfigurację systemu lub zainstalować główne oprogramowanie, upewnij się, że posiadasz odpowiednie kopie zapasowe.
*   **Używaj "tak jak jest":** Te skrypty są dostarczane "tak jak są", bez żadnej gwarancji. Używaj ich na własne ryzyko.

---

<a name="русский"></a>

## 🚀 Joy096/server - Скрипты-утилиты для сервера Linux (Русский)

Добро пожаловать в репозиторий `Joy096/server`! Это коллекция Bash-скриптов, предназначенных для упрощения и автоматизации установки и базовой настройки различных популярных сервисов и инструментов на серверах Linux (преимущественно протестировано на Debian/Ubuntu).

### Состав репозитория

*   **[`cloudflare_ssl.sh`](https://github.com/Joy096/server/blob/main/cloudflare_ssl.sh):**
    *   Устанавливает `acme.sh` и получает SSL-сертификаты Let's Encrypt (включая wildcard) с использованием Cloudflare DNS API.
    *   Настраивает автоматическое продление сертификатов.
    *   Предоставляет опции для автоматической установки сертификатов в 3X-UI, Nextcloud (Snap) и AdGuard Home (Snap).
    *   *Примечание:* Этот скрипт самоудаляется после выполнения в целях безопасности.
*   **[`xui_install.sh`](https://github.com/Joy096/server/blob/main/xui_install.sh):**
    *   Устанавливает панель 3X-UI (популярная панель для управления прокси-сервисами, такими как VLESS, VMess, Trojan).
*   **[`nextcloud_install.sh`](https://github.com/Joy096/server/blob/main/nextcloud_install.sh):**
    *   Устанавливает Nextcloud с помощью официального Snap-пакета, предоставляя платформу для собственного облачного хранилища и совместной работы.
*   **[`adguard_install.sh`](https://github.com/Joy096/server/blob/main/adguard_install.sh):**
    *   Устанавливает AdGuard Home с помощью официального Snap-пакета, настраивая блокировщик рекламы и трекеров для всей сети.
*   **[`docker_install.sh`](https://github.com/Joy096/server/blob/main/docker_install.sh):**
    *   Устанавливает Docker Engine и Docker Compose, позволяя разворачивать контейнеризированные приложения.
*   **[`fail2ban_install.sh`](https://github.com/Joy096/server/blob/main/fail2ban_install.sh):**
    *   Устанавливает и включает Fail2ban с базовой конфигурацией для защиты SSH от атак перебора (brute-force).
*   **[`warp.sh`](https://github.com/Joy096/server/blob/main/warp.sh):**
    *   Устанавливает и настраивает Cloudflare WARP, возможно, для использования в качестве SOCKS5 прокси или для смены исходящего IP-адреса сервера. (Проверьте детали скрипта для точной функциональности).

### Общее использование

1.  **Загрузите нужный скрипт:**
    ```bash
    # Пример с curl:
    curl -O https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    # Пример с wget:
    # wget https://raw.githubusercontent.com/Joy096/server/main/SCRIPT_NAME.sh
    ```
    Замените `SCRIPT_NAME.sh` на фактическое имя файла скрипта (например, `docker_install.sh`).
2.  **Сделайте его исполняемым:**
    ```bash
    chmod +x SCRIPT_NAME.sh
    ```
3.  **Запустите с правами root:**
    ```bash
    sudo ./SCRIPT_NAME.sh
    ```
4.  Следуйте инструкциям на экране, которые выводит скрипт.

### ⚠️ Важные замечания

*   **Права Root:** Большинство скриптов требуют доступа `root` или `sudo` для установки пакетов и изменения конфигураций системы.
*   **Просмотр перед запуском:** **Всегда просматривайте код скрипта перед его выполнением на сервере, особенно при запуске от имени root.** Понимайте, какие команды он будет выполнять.
*   **Совместимость:** Скрипты в основном разработаны и протестированы на системах Debian/Ubuntu. Совместимость с другими дистрибутивами может отличаться. Некоторые скрипты могут быть ориентированы на установку через Snap (Nextcloud, AdGuard).
*   **Самоудаление:** Скрипт `cloudflare_ssl.sh` удаляет себя после завершения работы. Сделайте копию, если вам нужно использовать его повторно без повторной загрузки. Проверьте другие скрипты, если такое поведение предусмотрено и для них.
*   **Резервное копирование:** Перед запуском установочных скриптов, которые могут изменить конфигурацию системы или установить крупное программное обеспечение, убедитесь в наличии актуальных резервных копий.
*   **Использование "как есть":** Эти скрипты предоставляются "как есть", без каких-либо гарантий. Используйте их на свой страх и риск.
