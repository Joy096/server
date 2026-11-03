# jackett.sh (до 27.10.2026 назывался setup_jackett.sh) — Jackett: установка, настройка, обход Cloudflare, удаление

Интерактивный скрипт для Ubuntu (x86_64 и ARM64). Запуск: `sudo bash jackett.sh`. 995 строк. Название файла `jackett.sh` (решение Vitalii от 27.10.2026; раньше `setup_jackett.sh`). Не использует VPN: Jackett работает напрямую. Рассчитан на Oracle Micro (1 ЦП, ~1 ГБ RAM) и Ampere.

---

## 1. Что делает

- Ставит последнюю версию Jackett с GitHub в `/opt/Jackett` и службу `jackett.service` (штатным `install_service_systemd.sh`).
- Служба работает **не от root**, а от обычного пользователя (по умолчанию `ubuntu` или тот, кто вызвал sudo; если таких нет, создаётся `jackett`); конфиг в `~/.config/Jackett/ServerConfig.json`.
- Включает External access и Allow CORS, задаёт API key (свой или случайный из 32 символов a-z0-9) и пароль панели.
- Открывает порт 9117 в UFW (запоминает правило, только если его не было).
- **HTTPS** включает не этот скрипт, а `ssl.sh` (пункт 1 или 2): Jackett сам HTTPS не умеет, `ssl.sh` ставит перед ним nginx и закрывает обычный HTTP снаружи (см. раздел «HTTPS»). Этот скрипт такой режим понимает и не ломает.
- Ставит **FlareSolverr или Byparr** в Docker (порт только на `127.0.0.1:8191`) для трекеров с защитой Cloudflare и прописывает его в Jackett (лечит ошибку «Challenge detected but FlareSolverr is not configured»); при нехватке памяти предлагает создать **swap-файл**.
- Сохраняет и восстанавливает папку `Indexers` (логины/cookie трекеров).
- Показывает статус.
- Удаляет всё и возвращает систему к состоянию «до установки» (по учёту в файле состояния).

Логины и пароли трекеров скрипт не хранит: их вводят в веб-интерфейсе или они приезжают с папкой `Indexers`.

---

## 2. Файлы и константы

| Что | Значение |
|---|---|
| программа | `APP_DIR=/opt/Jackett`, служба `jackett`, юнит `/etc/systemd/system/jackett.service` |
| конфиг | `$(user_home JK_USER)/.config/Jackett/ServerConfig.json`, порт по умолчанию 9117 |
| состояние | `/etc/jackett-setup.state` |
| бэкап Indexers | `/root/jackett-indexers-<дата>.tar.gz` (chmod 600) |
| FlareSolverr/Byparr | контейнер `flaresolverr` или `byparr`, порт 8191, URL `http://127.0.0.1:8191` |
| swap | `/swapfile` (или `/swapfile.jackett`, если первый занят), строка в `/etc/fstab` |

В состоянии учитывается всё, что создал скрипт: `JK_USER`, `USER_CREATED`, `PKGS_ADDED`, `UFW_RULE`, `FS_CONTAINER` (контейнер создан скриптом), `FS_IMAGE_NEW` (образ скачан скриптом), `SWAP_CREATED`, `FS_ENGINE` (flaresolverr | byparr).

---

## 3. Меню

Меню в стиле `qbittorrent.sh` / `torrserver.sh`: шапка `print_home` + главное меню 0-5 + подменю (в подменю `0` или Enter = назад, Ctrl+D тоже).

**Шапка** (`print_home`): `Jackett:` (не установлен / работает (порт) / остановлен (порт)); `HTTPS:` (`-` / зелёный «включён» со ссылкой `https_url` / красный «включён, но не отвечает» при остановленной `jackett-tls` / жёлтый «выключен (включить: пункт 2 → 6)»); `Cloudflare:` (не установлен / FlareSolverr или Byparr работает / остановлен); `Следующий шаг:` по приоритету: не установлен → пункт 1; остановлен → пункт 2 → 1; пароль панели не задан → пункт 2 → 4; Indexers нет → добавить в панели или пункт 3 → 1; HTTPS включён, но `jackett-tls` не запущена → журнал и пункт 2 → 6; HTTPS выключен → по желанию пункт 2 → 6; иначе «всё настроено, статус: пункт 2 → 3».

**Главное меню**
1. Установка (установить / обновить Jackett) → `install_jackett`
2. Jackett (запуск, статус, настройка, HTTPS) → `jackett_menu`
3. Indexers (восстановить, сохранить) → `indexers_menu`
4. Обход Cloudflare (FlareSolverr / Byparr) → `cloudflare_menu`
5. Удаление (вернуть систему к состоянию до установки) → `uninstall_jackett`
0. Выход

**2. Jackett** (`jackett_menu`): 1 Остановить/Запустить (по состоянию службы; `jk_stop`/`jk_start`), 2 Перезапустить (`jk_restart`; запуск и перезапуск ждут ответа панели до 40 с, `wait_for_panel`), 3 Статус (`show_status`), 4 Настроить: API key, пароль панели, External access, CORS (`configure_basic`), 5 Показать адрес и API key (`show_address`: HTTPS-ссылка или `http://IP:порт`, API key целиком с предупреждением, Torznab-адрес), 6 Сертификат HTTPS: переход в `ssl.sh` (`run_ssl_script`).

**3. Indexers** (`indexers_menu`): 1 Восстановить папку Indexers (из папки или архива `.tar.gz` / `.zip`), 2 Сохранить Indexers в архив.

**4. Обход Cloudflare** (`cloudflare_menu`): 1 Установить / сменить FlareSolverr или Byparr (`install_flaresolverr`, ошибка «Challenge detected»), 2 Остановить/Запустить обходчик (`fs_stop`/`fs_start`; после остановки контейнер сам не стартует после перезагрузки сервера, из-за `--restart unless-stopped`), 3 Статус обходчика (`fs_status`: контейнер, здоровье, ответ, память, адрес в Jackett, RAM/swap).

Все подсказки «пункт N» в тексте скрипта ссылаются на эти номера (например, настройка = пункт 2 → 4, HTTPS = пункт 2 → 6, обходчик = пункт 4 → 1, Indexers = пункт 3 → 1).

---

## 4. Ключевые механики

### Установка (`install_jackett`)
Архитектура: `x86_64` → `Jackett.Binaries.LinuxAMDx64.tar.gz`, `aarch64` → `Jackett.Binaries.LinuxARM64.tar.gz`. Версия определяется редиректом `github.com/Jackett/Jackett/releases/latest`. Архив скачивается (`curl --retry 3`), проверяется `tar -tzf`, старый `/opt/Jackett` удаляется (настройки и Indexers лежат в домашней папке пользователя и сохраняются), распаковывается в `/opt`, `chown` на пользователя службы (установщик Jackett берёт пользователя из владельца файлов), запуск `install_service_systemd.sh`, ожидание появления конфига (до 45 с), затем `configure_basic`, открытие порта, `install_flaresolverr auto`, итоговая сводка (адрес `http://IP:порт`, напоминание открыть порт в Security List/NSG Oracle).

### Настройка (`configure_basic`)
Спрашивает API key (8–64 символа a-zA-Z0-9 или Enter = сгенерировать) и пароль панели (минимум 8). Пишет в `ServerConfig.json` через `jq`: `APIKey`, `AdminPassword` (хеш), `AllowExternal=true`, `AllowCORS=true` (служба на время правки останавливается). Хеш пароля Jackett: **SHA-512 от (пароль + API key) в UTF-16LE, hex в нижнем регистре** — поэтому при смене API key пароль нужно задавать заново (скрипт всегда спрашивает оба). Затем `verify_login`: без пароля панель должна быть закрыта, с паролем открываться (HTTP-проверка `/UI/Dashboard`).

### Indexers
`backup_indexers` — `tar.gz` папки Indexers в `/root` (в архиве логины и cookie трекеров: хранить как пароль). `restore_indexers` — принимает путь к папке или архиву (`.zip` ставит `unzip`), проверяет наличие `*.json`, заменяет папку, ставит права, перезапускает службу.

### Обход Cloudflare: FlareSolverr или Byparr
- Оба слушают порт 8191, работает **один** из них. `set_engine` задаёт образ:
  - FlareSolverr: `ghcr.io/flaresolverr/flaresolverr:latest` (Chrome), порог памяти `SWAP_NEEDED_MB=2800` (RAM+swap), нужно ~1.5–2 ГБ;
  - Byparr: `ghcr.io/thephaseless/byparr:latest` (браузер Camoufox, совместимый API), порог 2000, запускается с `--shm-size=512m`.
- `analyze_system` показывает процессор, RAM/swap, диск и **рекомендует**: RAM < 1500 МБ → Byparr (FlareSolverr на такой памяти часто падает), иначе FlareSolverr (надёжнее совместим с Jackett). Предупреждения: RAM+swap < 2 ГБ (нужен swap), один слабый процессор (проверка Cloudflare может занимать > 60 с; ошибка «HttpClient.Timeout of 60 seconds» — ограничение сервера, а не движка), свободно меньше 4 ГБ диска.
- `choose_engine`: выбор «1. FlareSolverr / 2. Byparr» (Enter = уже установленный, иначе рекомендованный). При смене движка старый контейнер удаляется, если его создал скрипт (чужой контейнер не трогается).
- `install_flaresolverr`: при автоустановке и RAM < 1500 МБ пропускает с подсказкой запустить пункт 4 → 1; проверяет и при необходимости создаёт swap (`ensure_swap`); ставит `docker.io` (отслеживается как пакет); тянет образ, запускает контейнер `--restart unless-stopped -p 127.0.0.1:8191:8191`; ждёт готовность до 3 минут; прописывает `FlareSolverrUrl` в Jackett. Для Byparr выводится предупреждение: проект моложе, возможна ошибка «The cookies provided by FlareSolverr are not valid» (известная проблема, issue #407) — тогда вернуться на FlareSolverr (пункт 5, выбор 1).
- Проверка готовности: FlareSolverr — ответ `/` содержит `ready`; Byparr — `/docs` отдаёт 200.

### Swap (`ensure_swap`, `remove_swap`)
Если RAM+swap меньше порога выбранного движка, предлагает создать swap: 2048 МБ при RAM < 1500, иначе 1024 МБ; проверяет, что свободно на диске не меньше `размер + 3000` МБ; `fallocate` (или `dd`), `mkswap`, `swapon`, строка в `/etc/fstab`; запоминает в `SWAP_CREATED`. Удаляется только swap, созданный скриптом. Если контейнер уже был и swap только что создан, контейнер перезапускается.

### Статус (`show_status`)
Служба и автозапуск, пользователь, порт (слушает ли), локальный HTTP-код панели, длина API key (показываются первые 4 символа), External/CORS, задан ли пароль панели, число индексеров, состояние FlareSolverr/Byparr и адрес в Jackett, память RAM/swap, правила UFW.

### Удаление (`uninstall_jackett`)
Если HTTPS-прокси ставил `ssl.sh` (метка `pkg_nginx_added`), перед удалением пакета nginx скрипт проверяет, не используют ли его другие программы (`nginx_other_users`: сайт Lampa, другие сайты nginx, пакеты с зависимостью от nginx, запущенная служба nginx). В списке «Найдено» тогда есть предупреждение, а сам пакет удаляется только после отдельного вопроса `[y/N, Enter = N (нет, оставить)]` (`purge_nginx_checked`). Если пакет оставлен, остальное всё равно удаляется.

Пакет `docker.io` (если его поставил этот скрипт) удаляется так же осторожно: `docker_other_users` ищет другие контейнеры (кроме нашего), образы без контейнера, тома Docker, службы systemd с зависимостью от Docker, пакеты с зависимостью от docker.io, а если служба Docker остановлена, смотрит `/var/lib/docker/containers` и папки известных программ (`/opt/outline`, `/opt/rustdesk-server`). Если что-то найдено, в «Найдено» есть предупреждение, а пакет удаляется только после вопроса `[y/N, Enter = N (нет, оставить)]` (`confirm_docker_purge`); при отказе остальные пакеты всё равно удаляются, docker.io остаётся в учёте скрипта.

Показывает найденное: программа и служба, настройки и Indexers, контейнер FlareSolverr/Byparr (и образ, если его скачал скрипт), правило UFW, swap-файл, пользователь (если его создал скрипт, вместе с домашней папкой), пакеты. Варианты: всё / по компонентам / отмена. Учитывает зависимости (удаление пользователя тянет программу и настройки; удаление `docker.io` тянет контейнер). Перед удалением настроек предлагает сохранить Indexers в `/root`.

### HTTPS (делает ssl.sh, блок 7 в hook-скрипте)
- Проверено по исходникам Jackett: он слушает только `http://`, в `ServerConfig.json` нет ни пути к сертификату, ни порта HTTPS. Поэтому в веб-панели настроек HTTPS нет и быть не может. Разработчики предлагают обратный прокси (README, «Running Behind Reverse Proxy»: нужны исходный Host и заголовок `X-Forwarded-Proto: https`).
- **Прокси: nginx** (отдельный экземпляр со своим конфигом и службой `jackett-tls`). История: сначала Vitalii выбрал stunnel (27.10.2026), но он не умеет добавлять `X-Forwarded-Proto`: после входа Jackett редиректил на `http://домен:9118/UI/Login`, а на порту HTTPS обычный HTTP не работает, и браузер показывал `ERR_CONNECTION_RESET` (в логе stunnel: `SSL routines::http request`). `BaseUrlOverride` на редирект входа не влияет. Поэтому stunnel заменён на nginx; старые установки хук переводит сам.
- Решение Vitalii: обычный HTTP снаружи **закрывается**.
- Что делает `jackett_https` в hook-скрипте (срабатывает, если найдена служба `jackett`; запускается из пункта 1 и 2 `ssl.sh` и при каждом автопродлении сертификата):
  1. Копия сертификата в `/etc/jackett-cert` (`fullchain.pem`, `private.key`, файл `domain`); в `/root` у служб доступа нет.
  2. Если нет nginx, ставит пакет `nginx` (на время установки создаётся `/usr/sbin/policy-rc.d`, чтобы пакет не запустил свой сайт на порту 80), отключает стандартную службу `nginx` и оставляет отметку `pkg_nginx_added` (при удалении пакет убирается, только если его поставил `ssl.sh`).
  3. Конфиг `/etc/jackett-cert/nginx.conf` (`listen 9118 ssl` -> `proxy_pass http://127.0.0.1:9117`, `Host $http_host`, `X-Forwarded-Proto https`, `X-Forwarded-For`, `proxy_read_timeout 300s`), проверка `nginx -t` и **собственная** служба `jackett-tls.service`. Порт HTTPS по умолчанию 9118; если уже задан (в `nginx.conf` или в старом `stunnel.conf`), берётся он. Порт Jackett читается из его `ServerConfig.json`.
  4. Переход со старой версии: удаляется `stunnel.conf`, пакет `stunnel4` убирается, если его ставил `ssl.sh` (метка `pkg_stunnel_added`); значение `BaseUrlOverride`, которое прописывала старая версия (`https://домен:порт`), возвращается к прежнему.
  5. Порт HTTPS открывается в UFW (в `ufw_port` запоминается, только если правила не было).
  6. Ждёт ответ HTTPS до 30 с. **Самопроверка:** адрес в `Location` ответа на `/UI/Dashboard` должен начинаться с `https://`, иначе хук пишет об ошибке и **не закрывает обычный HTTP** (иначе заблокировались бы). Так же HTTP не закрывается, если HTTPS не ответил (Jackett остановлен или упал).
  7. Закрывает HTTP: `AllowExternal=false`, `LocalBindAddress=127.0.0.1` (если было пусто). Прежние значения сохранены в `prev_allow_external` и `prev_base_url`. Jackett на время правки останавливается; если правка не нужна (повторный запуск при продлении), Jackett не перезапускается, а `jackett-tls` перезапускается, чтобы взять новый сертификат.
  8. Проверяет, что порт Jackett слушает только `127.0.0.1`, и удаляет правило UFW для порта Jackett (номер в `ufw_closed_port`, чтобы вернуть при удалении HTTPS).
- Программы на этом же сервере могут по-прежнему ходить на `http://127.0.0.1:9117`: ссылки в выдаче строятся по адресу запроса (по HTTPS получатся `https://домен:9118/...`, по локальному HTTP получатся `http://127.0.0.1:9117/...`).
- Если браузер открыл `http://домен:9118` (без `https://`), nginx отвечает «400 The plain HTTP request was sent to HTTPS port» (вместо сброса соединения, как было у stunnel).
- В Oracle Cloud вручную: открыть порт 9118/tcp и закрыть 9117/tcp в Security List / NSG.
- Отключение: `ssl.sh` пункт 4 (`remove_jackett_https`) возвращает `AllowExternal`, `BaseUrlOverride` и правило UFW, удаляет службу, конфиг, копию сертификата и (если ставил) пакеты nginx и stunnel4. То же умеет пункт 7 `jackett.sh` (компонент «HTTPS-прокси»); при удалении самого Jackett прокси удаляется вместе с ним.
- Как это учитывает `jackett.sh`: `https_active` (есть `/etc/jackett-cert/domain` и служба `jackett-tls`) и `https_url` (порт из `nginx.conf`, для старых установок из `stunnel.conf`). При включённом HTTPS пункт 2 (`configure_basic`) оставляет `AllowExternal=false`, установка не открывает порт Jackett в UFW, статус и итоговая сводка показывают адрес HTTPS, а без HTTPS подсказывают пункт 8.
- **Пункт 2 → 6 меню (`run_ssl_script`)** сделан так же, как пункт 13 в `qbittorrent.sh`: скачивает `ssl.sh` из репозитория Vitalii (`SSL_SCRIPT_URL`, Joy096/server, ветка main) во временный файл, проверяет, что это bash-скрипт, запускает его и после выхода из `ssl.sh` (его пункт 0) возвращает в меню Jackett; если HTTPS включён, показывает его адрес. Если Jackett не установлен, предупреждает: сертификат выпустится, но HTTPS для Jackett включится только после установки (тогда запустить пункт 2 → 6 ещё раз и выбрать в `ssl.sh` пункт 2). Новые версии `ssl.sh` Vitalii загружает в репозиторий сам; блок Jackett в `ssl.sh` работает, только если в репозитории лежит версия с ним.

---

## 5. Решения и история

- Базовая версия: установка, API key/пароль, External/CORS, UFW, Indexers, FlareSolverr, учёт для удаления.
- Пользователь службы выбирается без вопросов (ubuntu/sudo-пользователь/jackett).
- Добавлено **автосоздание swap** (`ensure_swap`) после того, как на Micro падал Chrome (ошибки «chrome not reachable», «Connection reset by peer»); строка про память в статусе; удаление swap при деинсталляции. Резервная копия до этого: `setup_jackett.before_swap.sh`.
- Добавлен выбор движка **FlareSolverr / Byparr** с анализом системы и пункт 5 меню; пороги памяти 2800 (FlareSolverr) и 2000 (Byparr). Резервная копия до этого: `setup_jackett.before_byparr.sh`.
- Пользователь знает про таймаут Jackett «HttpClient.Timeout of 60 seconds» на слабом процессоре: это ограничение сервера.
- 27.10.2026: скрипт переименован в `jackett.sh`; изменена только строка «Запуск» в шапке (код не менялся). Резервная копия: `jackett.before_rename.sh`. Старые резервные копии (`setup_jackett.before_*.sh`) остаются под прежними именами.
- 27.10.2026: добавлен HTTPS через `ssl.sh` (stunnel, порт 9118, обычный HTTP снаружи закрыт). В `jackett.sh` изменены: `https_active`/`https_url`, `configure_basic`, открытие порта при установке, сводка, статус, удаление (компонент «HTTPS-прокси»); меню не менялось. Резервные копии: `jackett.before_https.sh`, `ssl.before_jackett.sh`. Проверено на заглушках (`systemctl`, `ufw`, `acme.sh`) с настоящим stunnel и тестовым сервером вместо Jackett, который выбирает адрес прослушивания по `AllowExternal`, как настоящий; сам Jackett в песочнице не запускался.
- 27.10.2026: добавлен пункт 8 меню (переход в `ssl.sh`, как пункт 13 в qBittorrent); подсказки про HTTPS в статусе и сводке теперь ссылаются на пункт 8. Резервная копия: `jackett.before_ssl_menu.sh`. Остальные пункты меню не менялись. На GitHub лежит `ssl.sh` без блока Jackett (проверено), поэтому новую версию нужно загрузить в репозиторий.
- 27.10.2026 (позже): stunnel заменён на nginx из-за редиректа на `http://` после входа (см. раздел «HTTPS»); добавлена самопроверка `Location` и автоматический переход старых установок. Резервные копии: `jackett.before_nginx.sh`, `ssl.before_nginx.sh`. Проверено на стенде: воспроизведена ошибка (Location http:// со stunnel), с nginx Location https://, переход со старой установки, повторный запуск, установка с нуля, защитная проверка, удаление.
- 28.10.2026: по просьбе Vitalii в `ssl.sh` убраны строки про закрытый HTTP и про открытие порта HTTPS / закрытие порта Jackett в Oracle Security List (блок Jackett), а также строка про порт в Security List в блоке TorrServer. В блоке Jackett добавлена подсказка: если ссылка сразу не открылась, подождать 1-2 минуты (Jackett после перезапуска стартует не сразу). `jackett.sh` не менялся. Резервная копия: `ssl.before_msgs.sh`. Актуальный `ssl.sh` с этими правками уже лежит в проекте.
- 28.10.2026: итоги проверки Cloudflare на Micro (1 ЦП, ~1 ГБ RAM, своп занят): Rutracker отвечает проверкой Cloudflare (`cf-mitigated: challenge`), Byparr ждёт 120-184 с и сдаётся (`Timed out while loading the page or solving the challenge`), не проходит и тестовую страницу Cloudflare. Таймаут Jackett 60 с изменить нельзя. Byparr исправен (контейнер запущен, `/health` 200, без перезапусков и OOM), проблема в нехватке ресурсов Micro и в строгости проверки для IP дата-центра. Рекомендация: обходчик на Ampere (Vitalii планирует взять сервер 1 ЦП / 6 ГБ, потом 3 ЦП / 18 ГБ или увеличить размер до 4 ЦП / 24 ГБ через Edit shape) и прописать его адрес в `FlareSolverrUrl`; на Micro Byparr остановить (`docker stop byparr`). Образ Byparr для ARM проверить при установке.
- 28.10.2026: у Vitalii подключены индексеры `rutor` и `toloka` (сайты отвечают кодом 200 за 0,2 с без обходчика; Jackett по `https://домен:9118/api/v2.0/indexers/all/results` отвечает 200, CORS `access-control-allow-origin: *`). Jackett работает от пользователя `ubuntu`, конфиг лежит в `/home/ubuntu/.config/Jackett/ServerConfig.json`, пользователь определяется командой `systemctl show -p User --value jackett`. Лампа показывала «Парсер не отвечает на запрос» при рабочем сервере, причина на стороне настроек Лампы (адрес, ключ), на момент записи не выяснена.
- 31.10.2026: меню переделано в стиль `qbittorrent.sh`: шапка `print_home` (Jackett, HTTPS со ссылкой, Cloudflare, «Следующий шаг»), главное меню 0-5, подменю «Jackett», «Indexers», «Обход Cloudflare». Новое: запуск/остановка/перезапуск Jackett, показ адреса и API key (с Torznab-адресом), запуск/остановка и статус обходчика Cloudflare. Все «пункт N» в тексте обновлены. Резервная копия: `jackett.before_menu.sh`. Протестировано на заглушках (systemctl, docker, curl, getent).
- 31.10.2026 (позже): в `show_status` значения выровнены в ровную колонку (подписи дополнены пробелами вручную до 16 символов, без зависимости от локали); API key показывается целиком (можно скопировать); строка про FlareSolverr/Byparr стала `Cloudflare:`; правила UFW выводятся по одному на строку без лишних пробелов. Резервная копия: `jackett.before_status.sh`.
- 03.11.2026 (чат про RustDesk): добавлены `nginx_other_users` и `purge_nginx_checked`, предупреждение в «Найдено» при удалении HTTPS-прокси, отдельное подтверждение на удаление пакета nginx, если им пользуются другие программы (Lampa и др.). Остальное не менялось. Резервная копия: `jackett.before_nginxcheck.sh`. Тест на заглушках: nginx остаётся при Lampa, удаляется без вопроса, когда других пользователей нет.
- 03.11.2026 (чат про RustDesk): проверка «Docker нужен другим программам» перед удалением пакета docker.io (`docker_other_users`, `confirm_docker_purge`, предупреждение в «Найдено»). Docker ставит и удаляет только `jackett.sh`: `outline_vpn.sh` и перенос ключа в `rustdesk.sh` только пользуются Docker, пакет не удаляют. Резервная копия: `jackett.before_dockercheck.sh`. Тест на заглушках (docker, apt, dpkg-query): чужой контейнер/образ/том/пакет, остановленная служба Docker, ответы n и y, случай без чужих программ.
