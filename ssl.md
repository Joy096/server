# ssl.sh: описание

Скрипт Vitalii (репозиторий GitHub `Joy096/server`, ссылка `https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh`): выпуск сертификата Let's Encrypt через acme.sh (DNS-проверка) и автоматическая установка сертификата в программы на сервере. Запуск: `sudo bash ssl.sh`. Другие скрипты (`qbittorrent.sh` пункт 13, `torrserver.sh` пункт 12, `jackett.sh` пункт 8) скачивают его по ссылке выше и запускают; после пункта 0 возвращают в свои меню. Новые версии `ssl.sh` в репозиторий Vitalii заливает сам.

Решения Vitalii: в скрипте нет самоудаления (trap) и проверки root; их он добавляет сам, если нужно. Интерфейс только на русском.

## Меню
1. Установить/перевыпустить сертификат: `ssl_cert_issue_and_deploy`. Если сертификат уже есть, показывает его и спрашивает `[y/N, Enter = N]` (лимит Let's Encrypt около 5 одинаковых сертификатов в неделю). Выпуск без `--force`. Провайдеры DNS: Cloudflare, DuckDNS, deSEC (корневой домен или поддомен через challenge-alias), Dynu. Затем создаётся hook и запускается на новом сертификате.
2. Синхронизировать сертификаты с приложениями: `sync_certificates`. **Не перевыпускает** сертификат и не спрашивает провайдера: спрашивает только домен (Enter берёт самый новый из `/root/my_cert`), проверяет, что acme.sh знает домен (`~/.acme.sh/<домен>_ecc` или `<домен>`), заново создаёт hook и запускает его. acme.sh хранит только путь к hook-скрипту, поэтому пересоздания файла достаточно.
3. Показать путь к файлам сертификата (`/root/my_cert`).
4. Полностью удалить acme.sh, сертификаты и настройки (`remove_acme`): отключает HTTPS в qBittorrent, TorrServer и Jackett (`remove_*_https`), удаляет `~/.acme.sh`, `/root/my_cert`, hook.
5. Статус программ и HTTPS (добавлено 28.10.2026): таблица по всем шести программам.
0. Выход.

Шапка меню: список сертификатов (домен, дата окончания, дней осталось; цвет по срокам) и строка `Программы с HTTPS: N из M установленных (подробно: пункт 5)`.

## Статус программ (`app_https_state`, `count_apps_https`, `print_apps_summary`, `show_apps_status`)
Для каждой программы определяется состояние none / off / on / unknown и порт HTTPS. Третий столбец везде: `HTTPS: включён (порт)` / `выключен` / `неизвестно`. Для включённого HTTPS в пункте 5 ещё проверяется ответ `https://127.0.0.1:порт/` (`https_answers`, `curl -k`); если не отвечает, строка красная: `включён (порт), но не отвечает`. В шапке ответы не проверяются (только настройки).
- Nextcloud: есть `/var/snap/nextcloud/`; порт `snap get nextcloud ports.https` (по умолчанию 443); включён, если есть `certs/custom/fullchain.pem` или непустая `certs/live`.
- AdGuard Home: есть `/var/snap/adguard-home/`; в `AdGuardHome.yaml` блок `tls:`: `enabled: true` и `port_https` (не 0), порт по умолчанию 443.
- 3X-UI: есть `/usr/local/x-ui/x-ui`; `x-ui setting -getCert true` (строка `cert:` непустая = включён), порт из `x-ui setting -show true`. Если команда не отвечает или формат другой: `неизвестно`. Формат вывода на живом сервере не проверялся.
- qBittorrent: есть `/etc/systemd/system/qbittorrent.service`; `WebUI\HTTPS\Enabled=true` в `qBittorrent.conf`, порт `WebUI\Port` (по умолчанию 8080).
- TorrServer: служба `torrserver`; в `DAEMON_OPTIONS` есть `--ssl`, порт `--sslport` (по умолчанию 8091).
- Jackett: служба `jackett`; HTTPS включён, если есть `jackett-tls.service` и `/etc/jackett-cert/domain`; порт из `listen N ssl;` в `/etc/jackett-cert/nginx.conf` (по умолчанию 9118).

## Hook-скрипт `/root/renew_hook.sh`
Создаётся `create_renew_hook` (первые строки пишутся через echo с доменом, остальное heredoc `'EOF'`). Вызывается acme.sh при каждом продлении (`--renew-hook`) и вручную при выпуске и синхронизации. Лог: `/root/acme_renew.log`. Блоки, каждый срабатывает только если программа найдена:
1. Копия сертификата в `/root/my_cert/<домен>/` (`cert.pem`, `private.key`, `fullchain.pem`, `ca.pem`).
2. Nextcloud (snap): сертификат в `.../certs/custom/`, домен в `trusted_domains`, `nextcloud.enable-https custom`, перезапуск.
3. AdGuard Home (snap): сертификат в `/var/snap/adguard-home/common/certs/`, `server_name` в yaml, перезапуск.
4. 3X-UI: `x-ui cert -webCert ... -webCertKey ...`, перезапуск `x-ui`.
5. qBittorrent: копия в `/etc/qbittorrent-cert/` (владелец `qbittorrent`, папка 700, ключ 600, файл `domain`); при остановленной службе правит в `[Preferences]` три ключа `WebUI\HTTPS\Enabled`, `CertificatePath`, `KeyPath`; запускает (если была запущена), ждёт `200` по HTTPS до 30 с. Порт открывать не нужно, он уже открыт у веб-интерфейса.
6. TorrServer: копия в `/etc/torrserver-cert/` (владелец: пользователь, от которого работает служба; fallback root); правит `DAEMON_OPTIONS` в `/opt/torrserver/torrserver.config` через `ts_set_ssl_opts` (убирает старые `--ssl*`, дописывает ` --ssl --sslport P --sslcert ... --sslkey ...` внутрь кавычек); порт HTTPS оставляет прежний, иначе 8091; открывает его в UFW, если правила не было (порт запоминается в `ufw_port`); запускает `torrserver-ks.sh up` (kill-switch: ответы с порта HTTPS идут напрямую, правило приоритета 90 `sport`), для старого kill-switch предупреждает запустить `torrserver.sh` пункт 9; перезапускает службу и ждёт ответа `https://127.0.0.1:P/echo` до 30 с. Итог: адрес `https://домен:порт`, обычный HTTP (по умолчанию 8090) продолжает работать, в приложениях указывать адрес с `https://`. Подсказку про открытие порта в Security List / NSG Oracle Cloud скрипт больше не выводит (убрана по просьбе Vitalii 28.10.2026). `--force-https` Vitalii не включал («пока так»).
7. Jackett: сам HTTPS не умеет, поэтому `jackett_https` ставит перед ним **nginx** (отдельный экземпляр, служба `jackett-tls`, конфиг `/etc/jackett-cert/nginx.conf`, `daemon off`, свой pid): `https://домен:9118` -> `127.0.0.1:9117`, заголовки `Host` и `X-Forwarded-Proto: https`. Сертификат копируется в `/etc/jackett-cert/`. Пакет nginx ставится с запретом автозапуска (`policy-rc.d`), стандартная служба nginx отключается; отметка `pkg_nginx_added` нужна, чтобы при удалении убрать пакет только если его поставил `ssl.sh`. Порт 9118 открывается в UFW (`ufw_port`). Пока HTTPS не ответил и перенаправление не https, обычный HTTP не закрывается. Потом `AllowExternal=false`, `LocalBindAddress=127.0.0.1` в `ServerConfig.json` (прежние значения в `prev_allow_external`, `prev_base_url`), правило UFW для порта Jackett удаляется (`ufw_closed_port`, возвращается при удалении). Остатки прежней версии со stunnel (порт 9118 тот же) убираются. Из-за закрытого HTTP программы на этом же сервере ходят к Jackett по `http://127.0.0.1:9117`. В конце выводит адрес `https://домен:порт` и подсказку: если ссылка сразу не открылась, подождать 1-2 минуты и обновить страницу (Jackett после перезапуска стартует не сразу). Строк про закрытый HTTP и про порты в Oracle Security List больше не выводит (убраны по просьбе Vitalii 28.10.2026).

## Удаление HTTPS по программам
`remove_qbittorrent_https`, `remove_torrserver_https` (убирает `--ssl*` и `--force-https`, обновляет kill-switch, перезапускает, закрывает порт UFW из `ufw_port`, удаляет `/etc/torrserver-cert`), `remove_jackett_https` (возвращает настройки Jackett и UFW, удаляет службу, конфиг, пакет nginx если он наш, `/etc/jackett-cert`). Все вызываются из `remove_acme` (пункт 4).

## Как работать с этим файлом (общее правило для чатов проекта)
- Актуальная рабочая копия: `claude/ssl.sh` и описание `claude/ssl.md` в файлах проекта. Перед правкой читать её оттуда, после правки записать обратно (в проекте файл заменяется целиком, истории версий нет).
- Серверы берут скрипт с GitHub: после правок Vitalii заливает его туда сам.
- Правки `ssl.sh` из чатов про qBittorrent, TorrServer и Jackett делаются только под их блоки; остальное не трогать. Основные правки лучше вести в отдельном чате про `ssl.sh`.
- Перед правкой копия `ssl.before_<тема>.sh`, после правки `bash -n` и тест на заглушках (подмена `systemctl`, `curl`, `snap`, путей; `ssl.sh` в песочнице не запускать в настоящих путях `/root`).

## История
- 27.10.2026: HTTPS qBittorrent (блок 5), TorrServer (блок 6, пункт 12 в `torrserver.sh`), Jackett (блок 7); пункт 2 меню без перевыпуска и без вопросов про DNS; статус сертификата в шапке; подтверждение при повторном выпуске.
- 28.10.2026: строка про `https://` в приложениях для TorrServer; пункт 5 меню и строка в шапке со статусом HTTPS по всем программам. Резервные копии: `ssl.before_status.sh`, `ssl.before_appmsg2.sh`.
- 28.10.2026 (чат про Jackett): убраны строка про порт в Security List (TorrServer) и строки про закрытый HTTP и порты в Oracle (Jackett); для Jackett добавлена подсказка подождать 1-2 минуты. Резервная копия: `ssl.before_msgs.sh`.
- Известные вопросы: в блоке qBittorrent осталась строка «(домен должен указывать на IP этого сервера; по IP страница тоже откроется, но браузер покажет предупреждение)». В блоке TorrServer её убрали по просьбе, в блоке qBittorrent пока нет.
