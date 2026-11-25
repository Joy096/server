#!/bin/bash

# Получаем реальный путь к скрипту
SCRIPT_PATH=$(realpath "$0")

# Удаляем скрипт после завершения
trap 'rm -f "$SCRIPT_PATH"' EXIT

# Проверка на root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен выполняться от root!"
    exit 1
fi

# Функция для установки AdGuard Home
install_adguard() {
  echo ""
  echo "Обновление списка пакетов и установка обновлений..."
  export DEBIAN_FRONTEND=noninteractive
  apt update && apt upgrade -y && apt autoremove -y && apt clean

    echo ""
    echo "Проверяем, используется ли порт 53..."
    if lsof -i :53 | grep -q systemd-resolve; then
        echo "⚠️  Порт 53 занят systemd-resolve, выполняем настройки..." # Оставляем предупреждение ⚠️, так как оно несет смысловую нагрузку

        # Отключаем DNSStubListener и настраиваем systemd-resolved
        mkdir -p /etc/systemd/resolved.conf.d
        echo -e "[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no" | tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null

        # Обновляем resolv.conf
        mv /etc/resolv.conf /etc/resolv.conf.backup
        ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

        # Перезапускаем systemd-resolved
        systemctl reload-or-restart systemd-resolved
        echo "✅ Настройки systemd-resolved применены."
    else
        echo "✅ Порт 53 свободен, настройка systemd-resolved не требуется."
    fi

    # Устанавливаем AdGuard Home через Snap
    echo ""
    echo "Устанавливаем AdGuard Home..."
    snap install adguard-home

    # Открываем необходимые порты в UFW
    echo ""
    echo "Настраиваем брандмауэр..."
    ufw allow 3000
    ufw allow 53
    ufw allow 853
    ufw allow 784
    echo "✅ Брандмауэр настроен."

    # Отображаем внешний IP для доступа к веб-панели
    echo ""
    echo "Установка завершена! Перейдите в веб-панель для настройки:"
    echo "http://$(curl -s ifconfig.me):3000"
}

# Функция для удаления AdGuard Home
uninstall_adguard() {
    echo ""
    echo "Удаляем AdGuard Home..."
    snap remove adguard-home
    echo "✅ AdGuard Home удалён."

    # Закрываем порты в UFW
    echo ""
    echo "Закрываем порты в брандмауэре..."
    ufw delete allow 3000
    ufw delete allow 53
    ufw delete allow 853
    ufw delete allow 784
    echo "✅ Порты закрыты."

    echo ""
    echo "Восстанавливаем настройки systemd-resolved..."
    rm -f /etc/systemd/resolved.conf.d/adguardhome.conf
    mv /etc/resolv.conf.backup /etc/resolv.conf 2>/dev/null
    systemctl reload-or-restart systemd-resolved
    echo "✅ Systemd-resolved восстановлен."

    # Автокопия и вспомогательный скрипт резервной копии (сами копии на Google Drive остаются)
    rm -f /etc/cron.d/adguard-backup /usr/local/sbin/adguard-backup.sh
}

# --- Резервная копия настроек на Google Drive ---
# Вспомогательный скрипт кладётся в отдельный файл: автокопия по расписанию (cron) запускается уже без этого меню
BACKUP_TOOL="/usr/local/sbin/adguard-backup.sh"

install_backup_tool() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Устанавливаю python3..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null 2>&1
    fi
    cat > "$BACKUP_TOOL" <<'ADGBACKUP_EOF'
#!/bin/bash
# AdGuard Home: резервная копия выбранных разделов настроек на Google Drive (через rclone).
# Файл создаёт и обновляет adguard_home.sh (меню «Резервная копия настроек»), вручную его править не нужно.
# Команды: backup [--quiet] | list | restore | setup | auto-on | auto-off | auto-toggle | auto-status

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH}"

CONF="${AGH_CONF:-/var/snap/adguard-home/current/AdGuardHome.yaml}"
REMOTE="${AGH_REMOTE:-gdrive}"                    # имя remote в rclone (то же, что в minecraft_bedrock.sh)
REMOTE_DIR="${AGH_REMOTE_DIR:-adguard_backups}"   # папка на Google Drive
KEEP="${AGH_KEEP:-3}"                             # сколько копий хранить на Google Drive
WORK="${AGH_WORK:-/var/lib/adguard-backup}"
SAFETY="${AGH_SAFETY:-/root/AdGuardHome.before_restore.yaml}"   # копия текущих настроек перед восстановлением
CRON_FILE="${AGH_CRON_FILE:-/etc/cron.d/adguard-backup}"
LOG_FILE="${AGH_LOG:-/var/log/adguard-backup.log}"
SNAP_SVC="adguard-home"
QUIET=0

# Разделы настроек, которые попадают в копию (пароль, HTTPS, порты и DNS-серверы не сохраняются).
# Обработка файла настроек: только текстовые блоки по отступам, без сторонних модулей.
IFS= read -r -d '' PY_CODE <<'PYEOF'
import sys

HEADER = "# AdGuard Home: резервная копия выбранных разделов настроек (формат adguard-backup-v1)"

# (название, возможные родительские блоки, ключ); [None] = ключ верхнего уровня
ITEMS = [
    ("Списки блокировки", [None], "filters"),
    ("Списки разрешённых", [None], "whitelist_filters"),
    ("Пользовательские правила", [None], "user_rules"),
    ("Клиенты", ["clients"], "persistent"),
    ("Перезапись DNS", ["filtering", "dns"], "rewrites"),
    ("Заблокированные сервисы", ["filtering", "dns"], "blocked_services"),
    ("Безопасный поиск", ["filtering", "dns"], "safe_search"),
    ("Безопасный поиск", ["filtering", "dns"], "safesearch_enabled"),
    ("Родительский контроль", ["filtering", "dns"], "parental_enabled"),
    ("Безопасность просмотра", ["filtering", "dns"], "safebrowsing_enabled"),
]
LIST_KEYS = ("filters", "whitelist_filters", "user_rules")


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def ind(s):
    return len(s) - len(s.lstrip(" "))


def is_dash(s):
    t = s.strip()
    return t == "-" or t.startswith("- ")


def key_match(s, key, n):
    if ind(s) != n:
        return False
    t = s[n:]
    if not t.startswith(key + ":"):
        return False
    rest = t[len(key) + 1:]
    return rest == "" or rest[0] in " \t"


def block_end(lines, i, n):
    """Строка i - ключ на отступе n. Возвращает индекс после последней строки его значения."""
    dash_ok = lines[i].rstrip().endswith(":")
    j = i + 1
    last = i + 1
    while j < len(lines):
        s = lines[j]
        if s.strip() == "":
            j += 1
            continue
        k = ind(s)
        if k > n or (dash_ok and k == n and is_dash(s)):
            j += 1
            last = j
            continue
        break
    return last


def find_top(lines, key):
    for i, s in enumerate(lines):
        if key_match(s, key, 0):
            return i, block_end(lines, i, 0)
    return None


def child_indent(lines, pi, pe):
    for j in range(pi + 1, pe):
        s = lines[j]
        if s.strip() and not s.strip().startswith("#"):
            return ind(s)
    return None


def find_child(lines, parent, key):
    p = find_top(lines, parent)
    if not p:
        return None
    pi, pe = p
    c = child_indent(lines, pi, pe)
    if not c:
        return None
    for j in range(pi + 1, pe):
        if key_match(lines[j], key, c):
            return j, block_end(lines, j, c), c
    return None


def describe(blk):
    val = blk[0].split(":", 1)[1].strip()
    if val in ("true", "false"):
        return "включено" if val == "true" else "выключено"
    if val in ("[]", "{}", "null", "~", '""', "''"):
        return "пусто"
    if val:
        return "сохранено"
    dashes = [ind(s) for s in blk[1:] if is_dash(s)]
    if dashes:
        m = min(dashes)
        return "%d шт." % sum(1 for s in blk[1:] if is_dash(s) and ind(s) == m)
    return "сохранено"


def schema_of(lines):
    p = find_top(lines, "schema_version")
    if not p:
        return None
    return lines[p[0]].split(":", 1)[1].strip()


def cmd_extract(conf, out):
    lines = read_lines(conf)
    sv = find_top(lines, "schema_version")
    if not sv:
        print("в файле настроек нет schema_version, это не похоже на AdGuardHome.yaml")
        return 2
    top, groups, order, report = [], {}, [], []
    for human, parents, key in ITEMS:
        if parents == [None]:
            p = find_top(lines, key)
            if p:
                blk = lines[p[0]:p[1]]
                top.append(blk)
                report.append((human, blk))
            continue
        found = False
        for par in parents:
            r = find_child(lines, par, key)
            if r:
                blk = lines[r[0]:r[1]]
                if par not in groups:
                    groups[par] = []
                    order.append(par)
                groups[par].append(blk)
                report.append((human, blk))
                found = True
                break
        if not found and key == "persistent":
            p = find_top(lines, "clients")      # старый формат: clients - список на верхнем уровне
            if p:
                blk = lines[p[0]:p[1]]
                top.append(blk)
                report.append((human, blk))
    if not report:
        print("не нашёл ни одного нужного раздела в файле настроек")
        return 2
    res = [HEADER, lines[sv[0]]]
    for blk in top:
        res += blk
    for par in order:
        res.append(par + ":")
        for blk in groups[par]:
            res += blk
    res.append("")
    write_lines(out, res)
    for human, blk in report:
        print("  • %s: %s" % (human, describe(blk)))
    return 0


def split_fragment(fl):
    items = []
    i, n = 0, len(fl)
    while i < n:
        s = fl[i]
        if s.strip() == "" or s.startswith("#") or ind(s) != 0 or s.startswith("schema_version:"):
            i += 1
            continue
        key = s.split(":", 1)[0]
        e = block_end(fl, i, 0)
        blk = fl[i:e]
        val = s.split(":", 1)[1].strip()
        content = [x for x in blk[1:] if x.strip() and not x.strip().startswith("#")]
        is_group = (val == "" and content and not is_dash(content[0]) and key not in LIST_KEYS)
        if is_group:
            c = ind(content[0])
            j = 1
            while j < len(blk):
                t = blk[j]
                if t.strip() == "" or t.strip().startswith("#") or ind(t) != c:
                    j += 1
                    continue
                ck = t.strip().split(":", 1)[0]
                ce = block_end(blk, j, c)
                items.append((key, ck, blk[j:ce], c))
                j = ce
        else:
            items.append((None, key, blk, 0))
        i = e
    return items


def reindent(blk, delta):
    if delta == 0:
        return blk
    out = []
    for s in blk:
        if s.strip() == "":
            out.append(s)
        elif delta > 0:
            out.append(" " * delta + s)
        else:
            out.append(s[min(-delta, ind(s)):])
    return out


def insert_pos(cl):
    return len(cl) - 1 if cl and cl[-1] == "" else len(cl)


def check_header(fl):
    return bool(fl) and fl[0].startswith("# AdGuard Home: резервная копия")


def cmd_info(frag):
    fl = read_lines(frag)
    if not check_header(fl):
        print("это не файл резервной копии AdGuard Home")
        return 4
    items = split_fragment(fl)
    if not items:
        print("в копии нет разделов")
        return 4
    names = {k: h for h, _, k in ITEMS}
    names["clients"] = "Клиенты"
    for parent, key, blk, c in items:
        print("  • %s: %s" % (names.get(key, key), describe(blk)))
    return 0


def cmd_check(frag, conf):
    fs, cs = schema_of(read_lines(frag)), schema_of(read_lines(conf))
    if fs != cs:
        print("версия формата настроек в копии (%s) и на сервере (%s) разная" % (fs, cs))
        return 3
    return 0


def cmd_apply(frag, conf):
    fl, cl = read_lines(frag), read_lines(conf)
    if not check_header(fl):
        print("это не файл резервной копии AdGuard Home")
        return 4
    if schema_of(fl) != schema_of(cl):
        print("версия формата настроек в копии (%s) и на сервере (%s) разная" % (schema_of(fl), schema_of(cl)))
        return 3
    for parent, key, blk, c in split_fragment(fl):
        if parent is None:
            p = find_top(cl, key)
            if p:
                cl[p[0]:p[1]] = blk
            else:
                pos = insert_pos(cl)
                cl[pos:pos] = blk
            continue
        r = find_child(cl, parent, key)
        if r:
            cl[r[0]:r[1]] = reindent(blk, r[2] - c)
            continue
        p = find_top(cl, parent)
        if p:
            ct = child_indent(cl, p[0], p[1]) or c
            cl[p[1]:p[1]] = reindent(blk, ct - c)
        else:
            pos = insert_pos(cl)
            cl[pos:pos] = [parent + ":"] + blk
    write_lines(conf, cl)
    return 0


def main():
    a = sys.argv[1:]
    if not a:
        return 1
    if a[0] == "extract":
        return cmd_extract(a[1], a[2])
    if a[0] == "info":
        return cmd_info(a[1])
    if a[0] == "check":
        return cmd_check(a[1], a[2])
    if a[0] == "apply":
        return cmd_apply(a[1], a[2])
    return 1


sys.exit(main())
PYEOF

# --- Вывод сообщений ---
msg()  { [ "$QUIET" = 1 ] || echo -e "🔹 $*"; }
ok()   { [ "$QUIET" = 1 ] || echo -e "✅ $*"; }
warn() { [ "$QUIET" = 1 ] || echo -e "⚠️ $*"; }
err()  { echo -e "❌ $*" >&2; }
qlog() { [ "$QUIET" = 1 ] && echo "$(date '+%F %T') $*"; return 0; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Нужны права root."
        exit 1
    fi
}

pyt() { python3 -I -c "$PY_CODE" "$@"; }

ensure_python() {
    command -v python3 >/dev/null 2>&1 && return 0
    msg "Устанавливаю python3..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null 2>&1
    command -v python3 >/dev/null 2>&1
}

is_rclone_installed() { command -v rclone >/dev/null 2>&1; }
is_gdrive_configured() { is_rclone_installed && rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:"; }

# Копии на Google Drive: имена по возрастанию (последняя строка = самая новая)
remote_files() {
    rclone lsf "${REMOTE}:${REMOTE_DIR}/" --files-only 2>/dev/null \
        | grep -E '^adguard_backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9a-f]{8}\.yaml$' | sort
}

pretty_date() {
    sed -E 's/^adguard_backup_([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})_.*/\3.\2.\1 \4:\5:\6/' <<< "$1"
}

# --- Копия ---
rotate_backups() {
    local files count f
    files=$(remote_files)
    count=$(printf '%s\n' "$files" | grep -c .)
    if [ "$count" -gt "$KEEP" ]; then
        printf '%s\n' "$files" | head -n $((count - KEEP)) | while IFS= read -r f; do
            [ -n "$f" ] || continue
            if rclone deletefile "${REMOTE}:${REMOTE_DIR}/${f}" >/dev/null 2>&1; then
                msg "Удалена старая копия с Google Drive: $(pretty_date "$f")"
            fi
        done
    fi
}

do_backup() {
    local frag="${WORK}/backup.yaml" out rc hash newest name o now
    mkdir -p "$WORK" && chmod 700 "$WORK"
    out=$(pyt extract "$CONF" "$frag" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        err "Не удалось подготовить копию: ${out}"
        qlog "ошибка: не удалось подготовить копию: ${out}"
        return 1
    fi
    if [ "$QUIET" != 1 ]; then
        msg "В копию вошли разделы:"
        echo "$out"
    fi
    hash=$(sha256sum "$frag" | cut -c1-8)
    newest=$(remote_files | tail -n 1)
    if [ -n "$newest" ] && [[ "$newest" == *"_${hash}.yaml" ]]; then
        msg "Настройки не менялись с последней копии ($(pretty_date "$newest")), новая копия не нужна."
        qlog "без изменений, копия не нужна"
        return 0
    fi
    now="${AGH_NOW:-$(date +%F_%H-%M-%S)}"
    name="adguard_backup_${now}_${hash}.yaml"
    rclone mkdir "${REMOTE}:${REMOTE_DIR}" >/dev/null 2>&1
    if ! o=$(rclone copyto "$frag" "${REMOTE}:${REMOTE_DIR}/${name}" 2>&1); then
        err "Не удалось загрузить копию на Google Drive:"
        echo "$o" >&2
        qlog "ошибка загрузки на Google Drive"
        return 1
    fi
    ok "Копия загружена на Google Drive: ${REMOTE_DIR}/${name}"
    qlog "копия загружена: ${name}"
    rotate_backups
    return 0
}

cmd_backup() {
    need_root
    ensure_python || { err "Не удалось установить python3."; return 1; }
    if [ ! -f "$CONF" ]; then
        err "Не нашёл файл настроек AdGuard Home (${CONF}). Сначала установите AdGuard Home и пройдите первую настройку в браузере."
        qlog "ошибка: нет файла настроек"
        return 1
    fi
    if ! is_gdrive_configured; then
        if [ "$QUIET" = 1 ]; then
            qlog "ошибка: Google Drive не настроен"
            return 1
        fi
        local a
        read -rp "Google Drive ещё не подключён. Настроить сейчас? [Y/n, Enter = Y (да)]: " a
        case "$a" in n|N|н|Н) echo "Отменено."; return 1 ;; esac
        cmd_setup
        return $?
    fi
    do_backup
}

cmd_list() {
    need_root
    if ! is_gdrive_configured; then
        err "Google Drive не настроен. Выберите «Настроить Google Drive»."
        return 1
    fi
    local files f i=0
    files=$(remote_files | sort -r)
    if [ -z "$files" ]; then
        msg "Копий на Google Drive пока нет."
        return 0
    fi
    msg "Копии на Google Drive (папка ${REMOTE_DIR}), сверху самая новая:"
    while IFS= read -r f; do
        i=$((i + 1))
        echo "  ${i}. $(pretty_date "$f")"
    done <<< "$files"
}

wait_agh() {
    local i
    for i in $(seq 1 30); do
        if snap services "$SNAP_SVC" 2>/dev/null | awk 'NR>1{print $3}' | grep -qx 'active' \
            && ss -lnu 2>/dev/null | awk '$4 ~ /:53$/ {f=1} END{exit !f}'; then
            return 0
        fi
        sleep 1
    done
    return 1
}

cmd_restore() {
    need_root
    ensure_python || { err "Не удалось установить python3."; return 1; }
    if [ ! -f "$CONF" ]; then
        err "Не нашёл файл настроек AdGuard Home (${CONF}). Сначала установите AdGuard Home и пройдите первую настройку в браузере."
        return 1
    fi
    if ! is_gdrive_configured; then
        err "Google Drive не настроен. Выберите «Настроить Google Drive»."
        return 1
    fi
    local files f i=0 n pick name frag out rc a was=0
    files=$(remote_files | sort -r)
    if [ -z "$files" ]; then
        msg "Копий на Google Drive пока нет, восстанавливать нечего."
        return 0
    fi
    msg "Копии на Google Drive, сверху самая новая:"
    while IFS= read -r f; do
        i=$((i + 1))
        echo "  ${i}. $(pretty_date "$f")"
    done <<< "$files"
    n=$i
    read -rp "Номер копии [Enter = 1 (самая новая), 0 = отмена]: " pick
    pick=${pick:-1}
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$n" ]; then
        echo "Отменено."
        return 0
    fi
    name=$(printf '%s\n' "$files" | sed -n "${pick}p")
    mkdir -p "$WORK" && chmod 700 "$WORK"
    frag="${WORK}/restore.yaml"
    rm -f "$frag"
    if ! rclone copyto "${REMOTE}:${REMOTE_DIR}/${name}" "$frag" >/dev/null 2>&1 || [ ! -s "$frag" ]; then
        err "Не удалось скачать копию с Google Drive."
        return 1
    fi
    out=$(pyt info "$frag" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        err "Файл копии не подходит: ${out}"
        return 1
    fi
    msg "В копии от $(pretty_date "$name") есть разделы:"
    echo "$out"
    out=$(pyt check "$frag" "$CONF" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        err "Восстановление невозможно: ${out}. Ничего не изменено."
        return 1
    fi
    echo "   Эти разделы заменят такие же в текущих настройках. Пароль, HTTPS, порты и DNS-серверы не изменятся."
    read -rp "Восстановить? [y/N, Enter = N (нет)]: " a
    case "$a" in y|Y|д|Д) ;; *) echo "Отменено. Ничего не изменено."; return 0 ;; esac

    cat "$CONF" > "$SAFETY"
    chmod 600 "$SAFETY"
    msg "Текущие настройки сохранены на случай отката: ${SAFETY}"
    snap services "$SNAP_SVC" 2>/dev/null | awk 'NR>1{print $3}' | grep -qx 'active' && was=1
    snap stop "$SNAP_SVC" >/dev/null 2>&1
    out=$(pyt apply "$frag" "$CONF" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$SAFETY" > "$CONF"
        [ "$was" = 1 ] && snap start "$SNAP_SVC" >/dev/null 2>&1
        err "Не удалось применить копию: ${out}. Настройки возвращены как были."
        return 1
    fi
    if [ "$was" = 1 ]; then
        msg "Запускаю AdGuard Home..."
        snap start "$SNAP_SVC" >/dev/null 2>&1
        if ! wait_agh; then
            snap stop "$SNAP_SVC" >/dev/null 2>&1
            cat "$SAFETY" > "$CONF"
            snap start "$SNAP_SVC" >/dev/null 2>&1
            err "AdGuard Home не запустился с восстановленными настройками. Настройки возвращены как были (смотрите: snap logs ${SNAP_SVC} -n 30)."
            return 1
        fi
    fi
    ok "Настройки восстановлены из копии от $(pretty_date "$name")."
    if grep -qE '^[[:space:]]+- domain:' "$frag"; then
        echo "   В копии есть записи «Перезапись DNS»: если сервер или сеть новые, проверьте в них IP-адреса."
    fi
    return 0
}

# --- Google Drive (rclone) ---
install_rclone() {
    is_rclone_installed && return 0
    msg "Устанавливаю rclone..."
    if curl -s https://rclone.org/install.sh | bash >/dev/null 2>&1 && is_rclone_installed; then
        ok "rclone установлен."
        return 0
    fi
    err "Не удалось установить rclone."
    return 1
}

cmd_setup() {
    need_root
    ensure_python || { err "Не удалось установить python3."; return 1; }
    install_rclone || return 1
    local a token cfg_dir cfg_file tmp
    if is_gdrive_configured; then
        msg "Google Drive уже подключён (remote: ${REMOTE})."
        read -rp "Перенастроить подключение? [y/N, Enter = N (нет, оставить как есть)]: " a
        case "$a" in
            y|Y|д|Д) rclone config delete "$REMOTE" >/dev/null 2>&1 ;;
        esac
    fi
    if ! is_gdrive_configured; then
        echo ""
        echo "Нужно один раз войти в Google-аккаунт. Сервер без браузера, поэтому токен получаем на компьютере:"
        echo "  1. Скачайте rclone для своего компьютера: https://rclone.org/downloads/"
        echo "  2. Распакуйте архив, откройте терминал в этой папке."
        echo '  3. Выполните команду. Windows (PowerShell): .\rclone authorize "drive"   macOS/Linux: ./rclone authorize "drive"'
        echo "  4. В браузере войдите в Google-аккаунт и разрешите доступ (потом появится «Success!»)."
        echo "  5. В терминале появится строка между «Paste the following...» и «<---End paste»,"
        echo '     она начинается с { и заканчивается }. Скопируйте её.'
        echo ""
        read -rp "Нажмите Enter, когда токен скопирован..." a
        echo "Вставьте токен целиком:"
        read -r token
        if [ -z "$token" ] || [[ "$token" != \{* ]] || [[ "$token" != *access_token* ]]; then
            err "Это не похоже на токен (должна быть строка вида {\"access_token\":\"...\"}). Ничего не изменено."
            return 1
        fi
        cfg_dir="${HOME}/.config/rclone"
        cfg_file="${cfg_dir}/rclone.conf"
        mkdir -p "$cfg_dir"
        if [ -f "$cfg_file" ]; then
            tmp=$(mktemp)
            awk -v s="[${REMOTE}]" '/^\[/{skip=($0==s)} !skip{print}' "$cfg_file" > "$tmp" && cat "$tmp" > "$cfg_file"
            rm -f "$tmp"
        fi
        printf '\n[%s]\ntype = drive\ntoken = %s\n' "$REMOTE" "$token" >> "$cfg_file"
        chmod 600 "$cfg_file"
    fi
    msg "Проверяю подключение к Google Drive..."
    if ! rclone lsd "${REMOTE}:" >/dev/null 2>&1; then
        err "Не удалось подключиться к Google Drive. Проверьте токен и повторите настройку."
        return 1
    fi
    rclone mkdir "${REMOTE}:${REMOTE_DIR}" >/dev/null 2>&1
    ok "Google Drive подключён. Копии будут храниться в папке ${REMOTE_DIR} (последние ${KEEP})."

    if [ -f "$CONF" ]; then
        read -rp "Сделать первую копию сейчас? [Y/n, Enter = Y (да)]: " a
        case "$a" in n|N|н|Н) ;; *) do_backup ;; esac
    else
        warn "Файл настроек AdGuard Home ещё не создан (первая настройка в браузере не завершена), первую копию сделаем позже."
    fi

    if ! auto_enabled; then
        echo ""
        echo "Автоматическая копия делает то же самое каждую ночь (в 04:20 по времени сервера) без вашего участия."
        echo "Если настройки не менялись, новая копия не создаётся."
        read -rp "Включить автоматическую копию раз в сутки? [y/N, Enter = N (нет)]: " a
        case "$a" in y|Y|д|Д) cmd_auto_on ;; *) msg "Автокопия не включена. Включить можно позже в меню резервной копии." ;; esac
    fi
    return 0
}

# --- Автоматическая копия (cron) ---
auto_enabled() { [ -f "$CRON_FILE" ]; }

cmd_auto_on() {
    need_root
    if ! is_gdrive_configured; then
        err "Сначала подключите Google Drive (пункт «Настроить Google Drive»)."
        return 1
    fi
    if [ -z "${AGH_SKIP_CRON_SERVICE:-}" ]; then
        if ! command -v cron >/dev/null 2>&1 && ! [ -x /usr/sbin/cron ]; then
            msg "Устанавливаю cron..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y cron >/dev/null 2>&1
        fi
        systemctl enable --now cron >/dev/null 2>&1
    fi
    cat > "$CRON_FILE" <<CRONEOF
# AdGuard Home: ежедневная резервная копия настроек на Google Drive
HOME=/root
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
20 4 * * * root ${AGH_SELF:-/usr/local/sbin/adguard-backup.sh} backup --quiet >> ${LOG_FILE} 2>&1
CRONEOF
    chmod 644 "$CRON_FILE"
    ok "Автокопия включена: каждую ночь в 04:20 (время сервера). Журнал: ${LOG_FILE}"
}

cmd_auto_off() {
    need_root
    rm -f "$CRON_FILE"
    ok "Автокопия выключена."
}

cmd_auto_status() {
    if auto_enabled; then echo "включена"; else echo "выключена"; fi
}

cmd_auto_toggle() {
    need_root
    local a
    if auto_enabled; then
        read -rp "Автокопия сейчас включена. Выключить? [y/N, Enter = N (нет, оставить включённой)]: " a
        case "$a" in y|Y|д|Д) cmd_auto_off ;; *) echo "Без изменений." ;; esac
    else
        read -rp "Автокопия сейчас выключена. Включить (каждую ночь в 04:20)? [y/N, Enter = N (нет)]: " a
        case "$a" in y|Y|д|Д) cmd_auto_on ;; *) echo "Без изменений." ;; esac
    fi
}

case "${1:-}" in
    backup)
        shift
        [ "${1:-}" = "--quiet" ] && QUIET=1
        if [ "$QUIET" = 1 ] && [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 300 ]; then
            tmp_log=$(mktemp); tail -n 200 "$LOG_FILE" > "$tmp_log"; cat "$tmp_log" > "$LOG_FILE"; rm -f "$tmp_log"
        fi
        cmd_backup ;;
    list)        cmd_list ;;
    restore)     cmd_restore ;;
    setup)       cmd_setup ;;
    auto-on)     cmd_auto_on ;;
    auto-off)    cmd_auto_off ;;
    auto-toggle) cmd_auto_toggle ;;
    auto-status) cmd_auto_status ;;
    *) echo "Использование: $0 backup [--quiet] | list | restore | setup | auto-on | auto-off | auto-toggle | auto-status"; exit 1 ;;
esac
ADGBACKUP_EOF
    chmod 755 "$BACKUP_TOOL"
}

backup_menu() {
    install_backup_tool || return
    while true; do
        echo ""
        echo "Резервная копия настроек AdGuard Home (Google Drive):"
        echo "   Сохраняются: списки блокировки, пользовательские правила, клиенты, перезапись DNS,"
        echo "   заблокированные сервисы, родительский контроль, безопасный поиск и безопасность просмотра."
        echo "   Пароль, HTTPS, порты и DNS-серверы в копию не попадают. Хранятся последние 3 копии."
        echo ""
        echo "1. Сделать копию сейчас (если Google Drive ещё не подключён, скрипт предложит настроить)"
        echo "2. Показать копии на Google Drive"
        echo "3. Восстановить настройки из копии"
        echo "4. Автокопия раз в сутки: $("$BACKUP_TOOL" auto-status) (включить/выключить)"
        echo "5. Настроить Google Drive"
        echo "0. Назад"
        echo ""
        read -rp "Введите номер пункта и нажмите Enter: " bchoice || break
        case $bchoice in
            1) "$BACKUP_TOOL" backup ;;
            2) "$BACKUP_TOOL" list ;;
            3) "$BACKUP_TOOL" restore ;;
            4) "$BACKUP_TOOL" auto-toggle ;;
            5) "$BACKUP_TOOL" setup ;;
            0) break ;;
            *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
        esac
    done
}

# Меню
while true; do
    echo ""
    echo "Выберите действие:"
    echo "1. Установка AdGuard Home"
    echo "2. Удаление AdGuard Home"
    echo "3. Установка сертификата для AdGuard Home"
    echo "4. Резервная копия настроек на Google Drive"
    echo "0. Выход"
    echo ""
    read -rp "Введите номер пункта и нажмите Enter: " choice

    case $choice in
        1) install_adguard ;;
        2) uninstall_adguard ;;
        3) wget -O ssl.sh https://raw.githubusercontent.com/Joy096/server/refs/heads/main/ssl.sh && bash ssl.sh ;;
        4) backup_menu ;;
        0) echo "Выход."; echo ""; exit ;;
        *) echo "❌ Некорректный ввод. Попробуйте снова." ;;
    esac
done
