# qbittorrent.sh (до 27.10.2026 назывался qbittorrent_full.sh) — qBittorrent-nox + WireGuard VPN + kill-switch

Интерактивный скрипт для Ubuntu (Oracle Cloud). Запуск: `sudo bash qbittorrent.sh`. Раньше назывался `setup_qbittorrent.sh`, затем `qbittorrent_full.sh`. 1682 строки, `bash -n` проходит. Схема та же, что у `torrserver.sh`: через VPN идёт **только** трафик пользователя `qbittorrent`; всё остальное (SSH, apt) идёт напрямую. Парный скрипт: `torrserver.md`.

---

## 1. Два сценария (скрипт определяет сам)

1. **На сервере уже есть WireGuard-конфиг** (например от `torrserver.sh`): qBittorrent подключается к ТОМУ ЖЕ туннелю, второй VPN-ключ не нужен. Конфиг не пересоздаётся, добавляются две строки `PostUp`/`PreDown`. TorrServer продолжает работать как раньше.
2. **Чистый сервер:** скрипт спрашивает провайдера, принимает конфиг WireGuard и настраивает всё с нуля.

Номера у qBittorrent, чтобы не пересекаться с TorrServer: таблица маршрутизации **101**, приоритеты правил **91** (ответы с порта веб-интерфейса напрямую), **101** (UID → таблица VPN), **111** (kill-switch `prohibit`). У TorrServer: 100 и 90/100/110.

---

## 2. Файлы и константы

| Что | Путь |
|---|---|
| пользователь / служба | `QB_USER=qbittorrent`, `QB_SVC=qbittorrent`, домашняя папка `/home/qbittorrent` |
| загрузки / .torrent | `/home/qbittorrent/Downloads`, `/home/qbittorrent/torrent_files` |
| конфиг qBittorrent | `/home/qbittorrent/.config/qBittorrent/qBittorrent.conf` |
| юнит службы | `/etc/systemd/system/qbittorrent.service` (`qbittorrent-nox --webui-port=PORT`, `Restart=always`, `LimitNOFILE=65536`) |
| kill-switch | `/usr/local/sbin/qbittorrent-ks.sh`, юнит `qbittorrent-killswitch.service` |
| маршрут VPN | `/usr/local/sbin/qbittorrent-vpn.sh up|down <интерфейс>` |
| drop-in | `/etc/systemd/system/qbittorrent.service.d/vpn.conf` (Requires kill-switch, Wants/After `wg-quick@<имя>`) |
| логин/пароль веб-интерфейса | `/etc/qbittorrent-credentials` (`логин:пароль`, chmod 600) |
| трекеры для новых торрентов | `/etc/qbittorrent-trackers.txt` |
| сертификат для HTTPS веб-интерфейса | `/etc/qbittorrent-cert/` (`fullchain.pem`, `private.key`, файл `domain`); создаёт и обновляет `ssl.sh`, сам `qbittorrent.sh` его не пишет |
| состояние | `/etc/qbittorrent-vpn.state` (`VPN_LABEL, VPN_NAME, VPN_SHARED, WEB_PORT, PKGS_ADDED, UFW_RULES, USER_CREATED`) |
| состояние TorrServer | `/etc/torrserver-vpn.state` (читается, чтобы подхватить название провайдера) |
| веб-порт | по умолчанию `8080` (пользователь выбирает 1024–65535, занятые порты не принимаются) |

---

## 3. Меню (структура с 31.10.2026, как у `torrserver.sh`)

Шапка `print_home` показывается перед каждым показом главного меню (запросов в сеть не делает, только настройки и `systemctl`/`wg show`):
- `qBittorrent:` не установлен / работает (порт) / остановлен (порт);
- `VPN:` `<провайдер> (<интерфейс>)[, общий]: туннель активен|не активен, защита включена|выключена` или `не настроен`;
- `HTTPS:` `-` (не установлен) / включён (`https://<домен из /etc/qbittorrent-cert/domain>:порт`) / выключен (включить: пункт 3 → 7);
- `Следующий шаг:` подсказка по порядку: не установлен → пункт 1; нет VPN → пункт 2 → 1, затем 2 → 2; нет защиты → 2 → 2; туннель не активен → пункт 4; иначе «всё настроено».

Главное меню (в подменю `0` или Enter = назад; Ctrl+D = выход, без зацикливания):
1. **Установка** (`install_menu`): 1) полная (VPN + защита + qBittorrent) → `setup_full && check_safety`; 2) только qBittorrent без VPN → `setup_qbit_only` (с предупреждением, открывает порт для пиров).
2. **VPN** (`vpn_menu`): 1) добавить/сменить VPN-конфиг (общий туннель или свой) → `setup_vpn`; 2) включить защиту (привязка к VPN, kill-switch) → `fix_qbit_binding`; 3) выключить защиту (откат) → `revert_routing`; 4) статус VPN (интерфейс, рукопожатие, привязка, внешние IP прямой и через VPN) → `check_vpn`.
3. **qBittorrent** (`qbit_menu`): 1) запустить или остановить (текст пункта зависит от состояния службы) → `qb_start` / `qb_stop`; 2) перезапустить → `qb_restart`; 3) статус (служба, веб-интерфейс, HTTPS, VPN) → `check_status`; 4) создать торрент из файла/папки и начать раздачу → `create_torrent`; 5) адрес и логин → `show_address`; 6) сменить логин/пароль → `change_password`; 7) сертификат HTTPS: перейти в `ssl.sh` → `run_ssl_script`.
4. **Проверка безопасности** (`safety_menu`): 1) проверка (при проблемах предложит исправить) → `check_safety`; 2) принудительно пересоздать правила и привязку → `auto_fix`.
5. **Удаление** (вернуть систему к состоянию до установки) → `uninstall_menu`.
0. Выход.

`run_ssl_script` (пункт 3 → 7): скачивает `ssl.sh` по ссылке `SSL_SCRIPT_URL` (`https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh`) во временный файл, проверяет, что это bash-скрипт, запускает `bash файл` (ввод с терминала работает), после выхода из него (пункт 0 в `ssl.sh`) возвращает в меню `qbit_menu` и удаляет временный файл. Нужна актуальная версия `ssl.sh` в репозитории.

`qb_start` / `qb_stop` / `qb_restart` (новые, 31.10.2026): только `systemctl start|stop|restart qbittorrent`; привязка к VPN, kill-switch и настройки не меняются. После запуска и перезапуска ждут ответ веб-интерфейса (`wait_for_web`, до 40 с). Остановка действует до следующего запуска или перезагрузки сервера (служба включена в автозапуск). Если qBittorrent не установлен, пишут «Установка: пункт 1» (`qb_need_installed`).

`check_vpn` (новая): при ненастроенном VPN подсказывает пункт 2 → 1; иначе `wg show` (первые 12 строк), строка про защиту (включена/выключена), тест внешних IP (прямой и от пользователя `qbittorrent` через `runuser`).

Соответствие старой нумерации (до 31.10.2026, плоское меню 1–13) новой: 1→1→1, 2→1→2, 3→2→1, 4→2→2, 5→3→4, 6→3→5, 7→3→6, 8→3→3, 9→4→1, 10→4→2, 11→2→3, 12→5, 13→3→7. Все подсказки «пункт N» в тексте скрипта обновлены на вид «пункт 2 → 1».

---

## 4. Ключевые механики

### Установка qBittorrent (`install_qbittorrent_core`)
- Ставит `qbittorrent-nox mktorrent curl ufw python3` (`apt_install_tracked` запоминает пакеты, которых не было), создаёт пользователя.
- Если конфиг уже есть: логин и пароль сохраняются, спрашивается только порт.
- Иначе `ask_web_settings`: порт, логин (по умолчанию `admin`), пароль (минимум 8 символов); конфиг начинается с `[LegalNotice] Accepted=true`.
- Пароль записывается в формате qBittorrent: **PBKDF2-HMAC-SHA512, 100000 итераций, соль 16 байт** (`qb_hash` на python3) в ключ `WebUI\Password_PBKDF2` как `@ByteArray(соль:хеш)`.
- Порт веб-интерфейса открывается в UFW (`ufw_allow_tracked` запоминает правило только если его не было). Ждёт ответ веб-интерфейса до 40 с (`wait_for_web`).
- Напоминает открыть порт в Security List / NSG в консоли Oracle Cloud.
- Установка «без VPN»: через API (`api_login`) читает `listen_port` и открывает его (tcp и udp) в UFW.
- **Внимание про API:** после 5 неверных входов qBittorrent банит адрес на час, поэтому `api_login` использует только пароль из `/etc/qbittorrent-credentials`.

### Привязка к интерфейсу VPN (`set_qb_interface`, `clear_qb_interface`)
- В конфиг qBittorrent прописываются `Session\Interface` и `Session\InterfaceName` в секции **`[BitTorrent]`** (не `[Preferences]`) — эквивалент Tools → Options → Advanced → Network interface.
- Менять файл можно только при остановленной службе (qBittorrent перезаписывает его при выходе).
- `fix_qbit_binding` вызывает `set_qb_interface "$CONF_NAME"` после drop-in; `remove_routing_parts` и `remove_vpn_parts_for_replace` вызывают `clear_qb_interface` (без VPN привязка к интерфейсу туннеля оставила бы qBittorrent без сети).
- Ветка `up` сгенерированного `qbittorrent-vpn.sh` выполняет `systemctl try-restart --no-block qbittorrent.service`: после перезапуска туннеля qBittorrent перезапускается и заново привязывается (если служба не запущена, например при загрузке системы, команда ничего не делает).

### VPN (`setup_vpn`) — то же, что у TorrServer
Установка `wireguard curl ufw iproute2 python3`, проверка ядра (`check_kernel_support`), выбор «1. Использовать существующий туннель» (`join_wg_conf`, требуется `Table = off`) или «2. Добавить отдельный конфиг» (`ask_vpn_provider`, вставка, `validate_wg_conf`, `fix_vpn_config`: `Table = off`, PostUp/PreDown, без DNS, только IPv4 в Address, `PersistentKeepalive = 25`, бэкап, метка `# vpn-scripts-managed`). Если конфиг уже используется TorrServer, в списке пишется «(используется TorrServer)»; строки TorrServer `torrserver-vpn.sh` не трогаются.

### Создание торрента (`create_torrent`)
- Путь к файлу/папке (с автодополнением, `~`), он **перемещается** в `Downloads`; при занятом имени добавляется `_1`, `_2`…
- Трекеры берутся из `/etc/qbittorrent-trackers.txt` (создаётся со списком по умолчанию: `udp://tracker.opentrackr.org:1337/announce`, `udp://open.stealth.si:80/announce`, `udp://tracker.torrent.eu.org:451/announce`, `udp://exodus.desync.com:6969/announce`, `udp://tracker.opentrackers.org:8080/announce`); файл можно редактировать.
- Вопрос «Сделать торрент приватным (без DHT/PEX)?»; для приватных копия `.torrent` кладётся в `/root/torrents`.
- Права: каталоги 755, файлы 644, владелец `qbittorrent`; торрент создаётся `mktorrent` в `torrent_files/`, затем через веб-API (`/api/v2/torrents/add`, до 3 попыток, `skip_checking=true`, путь сохранения `Downloads`) добавляется в qBittorrent, раздача стартует сразу. Файл `.torrent` для публикации остаётся в `torrent_files/` (скачать через scp). Это поведение прежнего `qBittorrent.sh`.

### Смена пароля, адрес
`show_address`: адрес (при HTTPS `https://домен:порт`, домен берётся из `/etc/qbittorrent-cert/domain`; при обычном режиме `http://IP:порт`), логин; пароль смотреть в `/etc/qbittorrent-credentials`. `change_password`: останавливает службу, пишет новый хеш, перезапускает.

### HTTPS веб-интерфейса (добавлено 27.10.2026)
- HTTPS включает **не этот скрипт, а `ssl.sh`** (пункты 1 и 2 его меню). В hook-скрипте `ssl.sh` есть блок 5: если на сервере есть служба `qbittorrent` и пользователь `qbittorrent`, он копирует `fullchain.pem` и `private.key` в `/etc/qbittorrent-cert/` (владелец `qbittorrent`, права: папка 700, ключ 600), пишет рядом файл `domain`, останавливает службу, прописывает в секцию `[Preferences]` три ключа `WebUI\HTTPS\Enabled=true`, `WebUI\HTTPS\CertificatePath`, `WebUI\HTTPS\KeyPath`, запускает службу (только если она была запущена), ждёт ответ по HTTPS до 30 с и пишет адрес `https://домен:порт`. То же при каждом автообновлении сертификата (перезапуск qBittorrent на несколько секунд).
- Папка `/etc/qbittorrent-cert` нужна потому, что qBittorrent работает от пользователя `qbittorrent`, а в `/root/my_cert` у него нет доступа.
- В `qbittorrent.sh` добавлены `web_scheme` (читает `WebUI\HTTPS\Enabled` из конфига) и `web_base` (адрес для запросов с самого сервера: `https://127.0.0.1:порт` или `http://127.0.0.1:порт`; если HTTPS включён, но не отвечает, а HTTP отвечает, берёт HTTP). Все локальные запросы (`api_login`, `wait_for_web`, чтение настроек при установке без VPN, добавление торрента, статус, проверка безопасности) идут через `web_base` и с `curl -k`, потому что сертификат выписан на домен, а не на 127.0.0.1. Шапка меню использует только `web_scheme` (без запросов в сеть).
- Статус (пункт 3 → 3) показывает протокол и строку «HTTPS: включён / выключен (включается скриптом ssl.sh)»; пункт 3 → 5 показывает адрес с доменом.
- Удаление qBittorrent (`remove_qbit_service`) удаляет и `/etc/qbittorrent-cert`. В `ssl.sh` пункт 4 (удалить acme.sh) сам отключает HTTPS в qBittorrent и удаляет папку сертификата.
- На VPN, kill-switch, правила маршрутизации, порт и UFW HTTPS не влияет: шифруется только связь браузера с панелью. Единственное — перезапуск службы при включении и при продлении сертификата (раз в ~60 дней).
- Заходить нужно по домену из сертификата (он должен указывать на IP этого сервера); по IP откроется с предупреждением браузера.

### Проверка безопасности (`check_safety`)
То же, что у TorrServer: WireGuard и свежее рукопожатие, qBittorrent от пользователя `qbittorrent`, правило UID→таблица 101, kill-switch (prohibit), правило ответов веб-интерфейса, маршрут в таблице 101, **разные внешние IP** (прямой и через `runuser -u qbittorrent`), локальный ответ веб-интерфейса. При ошибках предлагается автоисправление (`auto_fix`: помощники, `reapply_vpn`, `fix_qbit_binding`).

### Откат и удаление
`revert_routing` убирает привязку (общий туннель остаётся, свой возвращается из бэкапа). `uninstall_menu`: всё / только VPN / только qBittorrent (служба, пользователь, данные, правила UFW, пакеты) / по компонентам; учитываются зависимости; если на сервере установлен TorrServer (`/etc/torrserver-vpn.state`), общие пакеты (`wireguard wireguard-tools curl ufw jq iproute2 python3`) не удаляются; общий WireGuard-конфиг остаётся. Домашняя папка (скачанное, `.torrent`, настройки) удаляется только с явным подтверждением. Копии приватных торрентов в `/root/torrents` скрипт не удаляет. Напоминает закрыть порт в Oracle и отозвать ключ в кабинете VPN (если конфиг был свой).

---

## 5. Решения и история

- Переименован `setup_qbittorrent.sh` → `qbittorrent_full.sh`. Обе схемы (qBittorrent и TorrServer) работают на одном туннеле одновременно; каждая со своими таблицами и приоритетами.
- Добавлено в этой серии работ (подтверждено пользователем, «всё работает»): привязка к интерфейсу VPN (`set_bt_key`, `set_qb_interface`, `clear_qb_interface`) и автоперезапуск qBittorrent при подъёме туннеля (`try-restart`).
- Резервная копия до этих правок: `qbittorrent_full.before_iface.sh`.
- 27.10.2026: скрипт переименован в `qbittorrent.sh` (решение Vitalii). Добавлена поддержка HTTPS веб-интерфейса (см. раздел 4): интеграция в `ssl.sh` (автоматически, без вопросов), определение протокола и `curl -k` в `qbittorrent.sh`. Резервные копии: `qbittorrent.before_https.sh`, `ssl.before_qbittorrent.sh`. Проверено на заглушках: поддельный qBittorrent по HTTP и HTTPS, повторный прогон hook (без дублей ключей), остановленная служба, сбой копирования, откат на HTTP, удаление.
- 27.10.2026: добавлен пункт меню «Сертификат HTTPS: перейти в ssl.sh» (тогда пункт 13). Резервная копия до этого: `qbittorrent.before_sslmenu.sh`. Проверено на локальном сервере-заглушке: успешный запуск с вводом и возвратом в меню, не-скрипт и 404 дают понятную ошибку, временный файл удаляется. Сама ссылка на GitHub из песочницы не проверена.
- 31.10.2026: меню систематизировано как в `torrserver.sh` (решение Vitalii): шапка со статусом и «Следующий шаг», 5 пунктов главного меню и подменю (см. раздел 3). По просьбе Vitalii добавлены «запустить/остановить», «перезапустить» и «Статус VPN». Логика VPN, kill-switch, HTTPS, установки и удаления не менялась. Резервная копия до этого: `qbittorrent.before_menu.sh`. Проверено на заглушках (поддельный qBittorrent, заглушки `systemctl`, `wg`, `curl`): шапка и подсказки во всех состояниях (не установлен, без VPN, защита выкл/вкл, туннель не активен, служба остановлена, HTTPS включён), запуск, остановка, перезапуск, статус, адрес, статус VPN, неверный ввод, Enter и Ctrl+D. Настоящие `ip`/`wg`/Oracle в песочнице не проверялись.
