# torrserver.sh (до 27.10.2026 назывался torrserver_full.sh) — TorrServer + WireGuard VPN с kill-switch

Интерактивный скрипт для Ubuntu (Oracle Cloud). Ставит TorrServer и пускает через любой WireGuard VPN **только** трафик его пользователя. Запуск: `sudo bash torrserver.sh`. Раньше назывался `setup_all.sh`, затем `torrserver_full.sh`. 1492 строки, `bash -n` проходит. В комментариях внутри файла кое-где ещё написано `torrserver_full.sh` / `qbittorrent_full.sh` (на работу не влияет). Рассчитан на свежий сервер после базовой настройки (`server_new.sh`, его пункт меню 1), но умеет подхватывать уже существующую установку.

Парные файлы: `qbittorrent.sh` / `qbittorrent.md` (та же схема для qBittorrent, они делят один WireGuard-туннель) и `ssl.sh` / `ssl.md` (сертификат и HTTPS).

---

## 1. Схема работы

- Через VPN идёт только трафик системного пользователя `torrserver` (policy routing по UID). SSH, apt и всё остальное идёт напрямую (интерфейс `ens3` Oracle).
- Ответы веб-интерфейса TorrServer (порт 8090 по умолчанию) с порта идут напрямую (на ТВ), а не через VPN. То же для порта HTTPS (8091), если HTTPS включён (см. раздел «HTTPS»).
- **Kill-switch:** если VPN упал, у пользователя `torrserver` нет сети вообще (правило `prohibit`), утечки через основной интерфейс нет.
- Любой провайдер WireGuard (ClearVPN, Mullvad, Proton и т.д.): название спрашивается один раз, из него получается имя интерфейса и конфига.

Номера правил и таблиц:

| Что | Значение |
|---|---|
| таблица маршрутизации | `TABLE=100` |
| правило «ответы с порта веб-интерфейса идут напрямую» | приоритет **90** (`ipproto tcp sport PORT lookup main`; такое же правило для порта HTTPS, если он включён) |
| правило «трафик UID идёт в таблицу VPN» | приоритет **100** (`uidrange U-U lookup 100`) |
| kill-switch | приоритет **110** (`uidrange U-U prohibit`) |

У qBittorrent свои номера (таблица 101, приоритеты 91/101/111), поэтому они не пересекаются.

---

## 2. Файлы и константы

| Что | Путь |
|---|---|
| пользователь / служба | `TS_USER=torrserver`, `TS_SVC=torrserver` |
| каталог TorrServer | `/opt/torrserver` (настройки `settings.json`, кэш `cache/`) |
| kill-switch скрипт | `/usr/local/sbin/torrserver-ks.sh` (генерируется) |
| скрипт маршрута VPN | `/usr/local/sbin/torrserver-vpn.sh up|down <интерфейс>` (генерируется) |
| юнит kill-switch | `/etc/systemd/system/torrserver-killswitch.service` (oneshot, `Before=torrserver.service`) |
| drop-in службы | `/etc/systemd/system/torrserver.service.d/vpn.conf` (User=torrserver, Requires kill-switch, Wants/After `wg-quick@<имя>`) |
| WireGuard-конфиг | `/etc/wireguard/<имя>.conf`, служба `wg-quick@<имя>` |
| состояние | `/etc/torrserver-vpn.state` |
| порт | `WEB_PORT` — из `torrserver.config`, потом из юнита, иначе 8090 (`detect_port`) |
| порт HTTPS | `SSL_PORT` — из `--sslport` в `DAEMON_OPTIONS` файла `/opt/torrserver/torrserver.config`, по умолчанию 8091; пусто, если в `DAEMON_OPTIONS` нет `--ssl` (`detect_ssl_port`) |
| сертификат для HTTPS | `/etc/torrserver-cert/` (`fullchain.pem`, `private.key`, `domain`, `ufw_port`); создаёт и обновляет `ssl.sh`, владелец — пользователь службы (`CERT_DIR`; `ensure_user` делает `chown`) |
| ссылка на ssl.sh | `SSL_SCRIPT_URL=https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh` (пункт 3 → 5) |

Состояние (`STATE_FILE`) хранит: `VPN_LABEL`, `VPN_NAME`, `VPN_SHARED`, `PROFILE`, `PKGS_ADDED`, `UFW_PORT_ADDED`, `USER_CREATED`. По нему удаление возвращает систему к состоянию «до установки»: удаляется только то, что создал скрипт (чужие пакеты, правила UFW, пользователи не трогаются).

**Автоподхват старой установки:** если файла состояния нет, но есть drop-in `vpn.conf`, `load_state` берёт имя туннеля из `wg-quick@…` в drop-in, ставит `VPN_LABEL=VPN_NAME`, сохраняет состояние. Пакеты, пользователь и порт UFW при этом не учитываются, поэтому при удалении они останутся нетронутыми.

---

## 3. Меню (переделано 28.10.2026 в стиле `oracle.sh`)

Шапка (`print_home`): TorrServer (работает с портом и профилем / остановлен / не установлен), VPN (провайдер, интерфейс, туннель активен или нет, защита включена или выключена), HTTPS (включён с портом / выключен), «Следующий шаг» (подсказка, что делать дальше). Мастера первого запуска нет.

Главное меню:
1. Установка (`install_menu`)
2. VPN (`vpn_menu`)
3. TorrServer (`torrserver_menu`)
4. Проверка безопасности (`safety_menu`)
5. Удаление (`uninstall_menu`)
0. Выход

Подменю (в каждом `0. Назад`):
- **1 Установка:** 1) Полная установка VPN + защита + TorrServer (`setup_vpn && setup_torrserver; check_safety`); 2) Только TorrServer, без VPN (`setup_torrserver_only`, с предупреждением о риске жалоб на IP Oracle).
- **2 VPN:** 1) Добавить или сменить VPN-конфиг WireGuard (`setup_vpn`); 2) Включить защиту: TorrServer только через VPN (`fix_torrserver_binding`); 3) Выключить защиту: TorrServer напрямую, без VPN (`revert_routing`); 4) Статус VPN (`check_vpn`).
- **3 TorrServer:** 1) Запустить / Остановить (одна строка, текст зависит от `systemctl is-active torrserver`; `ts_start` / `ts_stop`); 2) Перезапустить (`ts_restart`); 3) Статус TorrServer (`check_torrserver`); 4) Сменить профиль настроек (`change_profile`); 5) Сертификат HTTPS: перейти в `ssl.sh` (`run_ssl_script`: скачивает `ssl.sh` по `SSL_SCRIPT_URL` во временный файл `mktemp /tmp/ssl.XXXXXX.sh`, `curl -fsSL --max-time 30`, проверяет, что файл не пустой и первая строка `#!...bash`, запускает `bash файл`, после его пункта 0 возвращает в меню TorrServer, удаляет файл и подсказывает проверить HTTPS пунктом 4).
- **4 Проверка безопасности:** 1) Проверка безопасности (`check_safety`, при проблемах предлагает исправление); 2) Принудительно пересоздать правила и привязку (`auto_fix`: нужен, если проверка не помогла).

Запуск и остановка службы не трогают привязку к VPN и профиль. Если TorrServer не установлен, пункты 3 → 1/2 отвечают «не установлен, установка: пункт 1».

Подсказки в тексте скрипта используют формат «пункт A → B» (например «пункт 2 → 2»).

---

## 4. Что делает каждая часть

### `setup_vpn` (подключение VPN)
1. Ставит `wireguard jq curl ufw iproute2` (`apt_install_tracked` запоминает, какие пакеты поставил именно скрипт), `check_kernel_support` (проверка `ip rule` с `ipproto/sport/uidrange`), создаёт пользователя, `install_routing_helpers`.
2. Если VPN уже настроен: «Заменить конфиг или сменить провайдера?» Нет → `reapply_conf`. Да → старое подключение убирается (свой конфиг удаляется, общий остаётся другому скрипту).
3. Если на сервере уже есть `/etc/wireguard/*.conf` (например от qBittorrent): выбор «1. Использовать существующий туннель (второй VPN-ключ не нужен)» (по умолчанию) или «2. Добавить отдельный конфиг». Вариант 1 → `join_wg_conf`: в конфиг дописываются только строки `PostUp = torrserver-vpn.sh up %i` и `PreDown = torrserver-vpn.sh down %i` после `[Interface]`; требует в конфиге `Table = off` (иначе wg-quick завернёт весь трафик сервера, включая SSH); перед правкой бэкап `*.ts-bak.<дата>`. Затем `activate_shared_tunnel` включает маршрут сразу, не перезапуская туннель (им может пользоваться qBittorrent).
4. Вариант 2: `ask_vpn_provider` (название → `sanitize_iface`: до 15 символов a-z0-9_-; при конфликте имени с существующим интерфейсом добавляется `-ts`), вставка конфига (Ctrl+D), `validate_wg_conf` (должны быть `[Interface] PrivateKey Address [Peer] PublicKey Endpoint AllowedIPs`; предупреждение, если нет `0.0.0.0/0`), `fix_vpn_config`, метка `# vpn-scripts-managed` (по ней конфиг можно удалить, когда он больше никому не нужен), перезапуск и включение `wg-quick@`.

### `fix_vpn_config` (правка конфига любого провайдера)
- `Table = off` и PostUp/PreDown: через туннель идёт только трафик torrserver;
- убирает `DNS` (иначе подменит DNS всей системы), чужие `PostUp/PostDown/PreUp/SaveConfig` (строки qBittorrent `qbittorrent-vpn.sh` не трогает);
- в `Address` оставляет только IPv4 (wg-quick падает, если IPv6 на сервере отключён; для TorrServer IPv6 закрыт kill-switch);
- добавляет `PersistentKeepalive = 25`, если его нет;
- бэкап исходного конфига `*.bak.<дата>` один раз, до первой правки; снимает `\r`.

### Профили настроек TorrServer (`choose_profile`, `apply_profile_settings`)
- **weak** (по умолчанию при RAM < 4000 МБ, например Oracle Micro с 1 ГБ): кэш 200 МБ только в памяти, `ConnectionsLimit=30`.
- **strong** (от 4 ГБ RAM): кэш 10 ГБ на диске (`/opt/torrserver/cache`, `UseDisk=true`); предупреждение, если свободно <15 ГБ.
- В обоих: `ReaderReadAHead=95`, `PreloadCache=0`, `RemoveCacheOnDrop=true`, **`DisableUTP=true`** (uTP идёт по UDP, внутри UDP-туннеля WireGuard с MTU 1420 пакеты фрагментируются и теряются, раньше из-за этого бывало 0 пиров; через TCP стабильнее).
- Правится `settings.json` через `jq` (учитывается и секция `BitTorr`, если она есть), только при остановленной службе.

### `fix_torrserver_binding`
Требует настроенный VPN (иначе kill-switch оставит TorrServer без сети). Останавливает службу, создаёт пользователя и делает `chown`, ставит kill-switch и маршрутные скрипты, drop-in, применяет профиль, запускает.

### Установка TorrServer
Официальный установщик `YouROK/TorrServer` (`installTorrServerLinux.sh`), нужно отвечать «да» на запуск от root (так проверена вся схема). Скрипт ждёт появления `settings.json` (до 20 с), определяет порт, открывает его в UFW (запоминает, только если правила не было). Напоминает открыть порт в Security List / NSG Oracle Cloud.

### Подсказка про VLC на Windows (добавлено 31.10.2026)
В конце обеих установок (`setup_torrserver`, `setup_torrserver_only`) вызывается `print_vlc_note`: кнопка VLC в веб-интерфейсе (настройки «Плееры») открывает ссылку `vlc://`, которую Windows не знает. Нужно один раз скачать программу vlc-protocol (`https://github.com/northsea4/vlc-protocol`, ссылку дал Vitalii), скопировать её в папку VLC (рядом с `vlc.exe`), запустить и перезапустить браузер. Запасной путь (Ctrl+N и ссылка) в скрипте не пишем: Vitalii отказался. Подробные шаги для разных способов установки (PowerShell, bat, exe) в README проекта на GitHub не проверялись. Резервная копия: `torrserver.before_vlcnote.sh`.

### HTTPS веб-интерфейса (добавлено 27.10.2026)
- Включает **не этот скрипт, а `ssl.sh`**: пункты 1 и 2 его меню, блок 6 hook-скрипта (запуск из этого меню: пункт 3 → 5). Блок копирует сертификат в `/etc/torrserver-cert/`, правит `DAEMON_OPTIONS` в `/opt/torrserver/torrserver.config` (добавляет ` --ssl --sslport 8091 --sslcert .../fullchain.pem --sslkey .../private.key`), открывает порт в UFW (если правила не было; порт запоминается в `ufw_port`), обновляет kill-switch (`torrserver-ks.sh up`), перезапускает службу и ждёт ответа `https://127.0.0.1:8091/echo` до 30 с. Итог: `https://домен:8091`.
- Обычный HTTP (порт 8090) продолжает работать рядом; `--force-https` Vitalii не включал («пока так»). В приложениях (TS на телефоне/ТВ и др.) адрес сервера нужно указывать с `https://` и портом 8091: с `http://` на порту 8091 приложение получает «Temporary Redirect» и показывает ошибку (подтверждено: с `https://` всё работает).
- В веб-интерфейсе TorrServer переключателя HTTPS нет; параметры только в `DAEMON_OPTIONS` (установщик хранит их в `torrserver.config`, служба читает файл через `EnvironmentFile`).
- Сертификат должен читать тот пользователь, от которого работает служба (после привязки к VPN это `torrserver`): поэтому `ensure_user` делает `chown -R torrserver:torrserver /etc/torrserver-cert`, а `ssl.sh` определяет владельца через `systemctl show -p User --value torrserver` (иначе root).
- Kill-switch (`install_routing_helpers`, heredoc `KSEOF`): добавлены `CONF=__CONF__` и чтение порта HTTPS при каждом запуске (`up`); если HTTPS включён, добавляются правила приоритета 90 `ipproto tcp sport SSLPORT lookup main` (IPv4 и IPv6), иначе ответы с порта 8091 ушли бы в VPN/kill-switch и страница не открывалась бы. Старые установки получают новый kill-switch через пункт 4 → 2 (принудительное пересоздание) или 2 → 2.
- Проверка безопасности (`check_safety`, пункт 4 → 1): при включённом HTTPS проверяет правило `sport ${SSL_PORT} lookup main` и локальный `curl -sk https://127.0.0.1:${SSL_PORT}/echo` (любой код, кроме 000, считается ответом).
- Удаление (`remove_torrserver_parts`): если есть `/etc/torrserver-cert`, читает `ufw_port`, закрывает это правило UFW, удаляет папку сертификата; в итоговом напоминании про Oracle добавляется строка про порт HTTPS. В `ssl.sh` пункт 4 сам отключает HTTPS в TorrServer (`remove_torrserver_https`).
- Порт HTTPS (8091) нужно открыть и в Security List / NSG Oracle Cloud.
- Шифруется только связь браузера/приложения с TorrServer; провайдер дома всё равно видит IP сервера и DNS-имя, объём и время трафика. Торрент-трафик идёт через VPN.

### Проверка безопасности (`check_safety`)
Проверяет: интерфейс WireGuard и свежее рукопожатие (<5 мин); TorrServer запущен от `torrserver`; правило UID→таблица 100; kill-switch; правило ответов веб-интерфейса; маршрут default dev в таблице 100; **разные внешние IP** (прямой и у пользователя torrserver через `runuser -u torrserver -- curl …`); локальный ответ веб-интерфейса `/echo`=200. При проблемах предлагает автоисправление.

### Авто-исправление / откат
`auto_fix`: заново ставит помощников, `reapply_conf`, `fix_torrserver_binding`. `revert_routing`: убирает kill-switch, правила, drop-in, скрипты; общий конфиг оставляет, свой возвращает из бэкапа; TorrServer продолжает работать с обычного IP.

### Удаление (`uninstall_menu`)
Показывает найденное: привязка к VPN, WireGuard, TorrServer (служба и `/opt/torrserver`), правило UFW, пользователь, пакеты. Варианты: всё / только VPN / только TorrServer / по компонентам / отмена. Обрабатывает зависимости (например удаление пользователя тянет удаление привязки). Если установлен qBittorrent (`/etc/qbittorrent-vpn.state`), общие пакеты (`wireguard wireguard-tools curl ufw iproute2 python3`) не удаляются; общий WireGuard-конфиг остаётся, из него убираются только строки TorrServer. В конце напоминание: закрыть порт в Oracle, отозвать ключ в кабинете VPN, файлы установщика вне `/opt/torrserver` не отслеживаются.

---

## 5. Решения и история

- Скрипт переименован `setup_all.sh` → `torrserver_full.sh` по общей схеме `*_full.sh`, 27.10.2026 → `torrserver.sh` (решение Vitalii: файлы называются `<имя>.sh` и `<имя>.md`).
- Совместное использование туннеля с qBittorrent: метка `vpn-scripts-managed`, `VPN_SHARED`, `join_wg_conf`; конфиг пересоздаётся только если его создал скрипт.
- Сообщение при удалении общего конфига: «→ обрабатываю WireGuard-конфиг...» (раньше было «удаляю», что вводило в заблуждение).
- Автоподхват прежней установки без файла состояния (см. выше): без него новый скрипт «не видел» старую установку.
- Подтверждено пользователем: схема работает вместе с qBittorrent на одном туннеле.
- 27.10.2026: добавлена поддержка HTTPS через `ssl.sh` (см. раздел «HTTPS»): `detect_ssl_port`, правило 90 для порта HTTPS в kill-switch, проверки в `check_safety`, очистка при удалении, `chown` папки сертификата в `ensure_user`. Резервные копии: `torrserver.before_https.sh`, `torrserver.before_sslmenu.sh`. Проверено на заглушках; на живом сервере Vitalii подтвердил: «всё работает».
- 27.10.2026: добавлен переход в `ssl.sh` (тогда пункт 12 плоского меню, теперь 3 → 5).
- 28.10.2026: меню переделано в группы (Установка / VPN / TorrServer / Проверка / Удаление) с шапкой состояния и «Следующим шагом»; слова «привязать» и «откат» заменены на «включить / выключить защиту»; добавлены запуск, остановка и перезапуск службы. Все подсказки «пункт N» в скрипте обновлены. `ssl.sh` не менялся (в нём лишь редкое предупреждение про старый kill-switch с устаревшим номером пункта: при случае поправить на «пункт 4 → 2»). Резервная копия: `torrserver.before_menu.sh`. Проверено на заглушках.
- Пункт 2 в `ssl.sh` (синхронизация) только устанавливает уже выпущенный сертификат, без перевыпуска и вопросов про DNS-провайдера.
- Принятый отказ: `--force-https` не включаем («Нет, пусть пока так»).
- Приложение «TS» (скорость/воспроизведение): адрес с `https://`, а не `http://` на порту 8091 (иначе «Temporary Redirect»).
