#!/bin/sh

# --- НАСТРОЙКИ ---
# Здесь можно указать:
# - raw-ссылки на подписки
# - прямые ссылки вида vless://, ss://, trojan://, socks://, hy2://
SOURCE_1=""
SOURCE_2=""
SOURCE_3=""

# Сколько максимум ключей класть в Podkop
LIMIT=27
# -----------------

log() { echo "[$(date '+%F %T')] $*" >&2; }

TMP_PRIORITY="$(mktemp)"
TMP_POOL="$(mktemp)"
TMP_FINAL="$(mktemp)"

trap 'rm -f "$TMP_PRIORITY" "$TMP_POOL" "$TMP_FINAL" "${TMP_POOL}.rnd" "${TMP_PRIORITY}.u" "${TMP_POOL}.u"' EXIT INT TERM

# Ищем в тексте ссылки на поддерживаемые протоколы
PATTERN='(vless|ss|trojan|socks|hy2)://[^"'"'"' <]+'

# --- НОРМАЛИЗАЦИЯ ИМЕНИ ---
# Убираем мусор из названия, но флаги и emoji не трогаем
clean_name() {
    printf '%s' "$1" | \
    sed 's/%20/ /g' | \
    sed 's/[[:cntrl:]]//g' | \
    sed 's/["\\`]/_/g' | \
    sed 's/[?#&]/_/g' | \
    sed 's/[|,]/_/g' | \
    sed 's/[[:space:]]\+/_/g'
}

is_valid_fp() {
    case "$1" in
        chrome|firefox|safari|ios|android|edge|360|random) return 0 ;;
        *) return 1 ;;
    esac
}

# --- СКАЧИВАНИЕ ---
# Загружает сырой текст/HTML/подписку
download_content() {
    raw=$(wget --no-check-certificate --user-agent="v2rayNG/1.8.5" -qO- "$1" 2>/dev/null)
    [ -n "$raw" ] || return 1

    # Если контент base64 — декодируем, иначе возвращаем как есть
    printf '%s' "$raw" | base64 -d 2>/dev/null || printf '%s' "$raw"
}

# --- НОРМАЛИЗАЦИЯ ССЫЛКИ ---
# Приводит ссылку к виду, который понимает Podkop/sing-box
normalize_link() {
    raw="$1"

    # Убираем мусор, чистим HTML-экранирование и пробелы по краям
    link=$(printf '%s' "$raw" | tr -cd '\11\12\15\40-\176' | \
       sed 's/&amp;/\&/g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    # Выкидываем обрезанные ключи (заканчиваются на & или =)
    case "$link" in
        *'='|*'&') return 1 ;;
    esac

    # Принимаем только поддерживаемые схемы
    case "$link" in
        vless://*|ss://*|trojan://*|socks://*|hy2://*) ;;
        *) return 1 ;;
    esac

    # Разделяем ссылку и имя после #
    base="${link%%#*}"
    name=""
    [ "$base" != "$link" ] && name="${link#*#}"

    # Неподдерживаемый транспорт сразу выкидываем
    printf '%s' "$base" | grep -qi 'type=xhttp' && return 1

    # Shadowsocks почти не трогаем: только имя при необходимости
    if printf '%s' "$base" | grep -q 'ss://'; then
        if [ -n "$name" ]; then
            printf '%s#%s\n' "$base" "$(clean_name "$name")"
        else
            printf '%s\n' "$base"
        fi
        return 0
    fi

    # Если query отсутствует, добавляем его для дальнейшей сборки
    case "$base" in
        *\?*) ;;
        *) base="${base}?" ;;
    esac

    # Разбираем query заново:
    # убираем security/type и пустые параметры, чтобы не тащить мусор дальше
    path="${base%%\?*}"
    query=""
    if [ "$path" != "$base" ]; then
        query="${base#*\?}"
    fi

    # если есть пустые значения — выкидываем
    printf '%s' "$query" | grep -qE '(^|&)security=(&|$)' && return 1
    printf '%s' "$query" | grep -qE '(^|&)type=httpupgrade(&|$|#)' && return 1
    printf '%s' "$query" | grep -qE '(^|&)fp=(&|$)' && return 1

    query=$(printf '%s' "$query" | sed 's/^&//; s/&&*/\&/g')

    query_clean=""
    old_ifs=$IFS
    IFS='&'
    for pair in $query; do
        [ -n "$pair" ] || continue

        key=${pair%%=*}
        val=""
        case "$pair" in
            *=*) val=${pair#*=} ;;
        esac

        [ -n "$key" ] || continue
        [ "$key" = "security" ] && continue
        [ "$key" = "type" ] && continue
        [ -n "$val" ] || continue

        if [ -n "$query_clean" ]; then
            query_clean="${query_clean}&${pair}"
        else
            query_clean="$pair"
        fi
    done
    IFS=$old_ifs

    if [ -n "$query_clean" ]; then
        base="${path}?${query_clean}"
    else
        base="${path}?"
    fi

    # SECURITY
    # Reality определяем по наличию pbk
    if printf '%s' "$base" | grep -q 'pbk='; then
        security="reality"
    else
        # Для остальных типов выбираем по порту
        port=$(printf '%s' "$base" | sed -nE 's#.*:([0-9]+).*#\1#p')
        case "$port" in
            443|8443|2053|2083|2096|2087) security="tls" ;;
            *) security="none" ;;
        esac
    fi

    # TYPE
    # Берём только нормальное значение, без хвостов и мусора
    transport=$(printf '%s' "$query" | sed -nE 's/(^|&)type=([A-Za-z0-9]+).*/\2/p')
    transport=$(printf '%s' "$transport" | tr -cd 'a-zA-Z0-9')

    case "$transport" in
        "") transport="tcp" ;;
        tcp|ws|grpc) ;;
        *) return 1 ;;
    esac

    case "$base" in
        *\?*) ;;
        *) base="${base}?" ;;
    esac

    # Собираем финальную ссылку
    base="${base}&security=${security}&type=${transport}"

    # Reality без fp лучше не пускать
    if [ "$security" = "reality" ]; then
        fp=$(printf '%s' "$base" | sed -nE 's/.*[?&]fp=([^&]+).*/\1/p')
        [ -z "$fp" ] && return 1
    fi

    # Чистим хвосты вида ?& / && / & в конце
    res=$(printf '%s' "$base" | sed 's/?&/?/g; s/&&/\&/g; s/&$//; s/?$//')

    # Возвращаем имя, если оно было
    if [ -n "$name" ]; then
        printf '%s#%s\n' "$res" "$(clean_name "$name")"
    else
        printf '%s\n' "$res"
    fi
}

# --- СБОР ---
# Если источник — прямая ссылка, кладём её в приоритет
# Если источник — подписка/страница, скачиваем и парсим из неё все ключи
collect() {
    input="$1"
    num="$2"

    case "$input" in
        vless://*|ss://*|trojan://*|socks://*|hy2://*)
            norm=$(normalize_link "$input") || {
                log "⚠️  Ссылка $num: прямой ключ отброшен"
                return
            }
            log "✅ Ссылка $num: добавлен прямой ключ (приоритет)"
            printf '%s\n' "$norm" >> "$TMP_PRIORITY"
            ;;

        *)
            log "📡 Ссылка $num: загрузка..."
            content=$(download_content "$input") || {
                log "❌ Ссылка $num: ошибка загрузки"
                return
            }

            # Считаем найденные ключи до фильтрации
            count=$(printf '%s\n' "$content" | grep -oE "$PATTERN" | wc -l | tr -d ' ')
            log "✅ Ссылка $num: найдено ключей: $count"

            # Парсим каждый найденный ключ отдельно
            printf '%s\n' "$content" | grep -oE "$PATTERN" | while read -r link; do
                norm=$(normalize_link "$link") || continue
                printf '%s\n' "$norm" >> "$TMP_POOL"
            done
            ;;
    esac
}

# --- СТАРТ ---
log "📥 Сбор ключей..."
collect "$SOURCE_1" "1"
collect "$SOURCE_2" "2"
collect "$SOURCE_3" "3"

log "🔍 Фильтрация, исправление и выборка $LIMIT случайных ключей..."

# Убираем дубли в приоритете и в пуле
sort -u "$TMP_PRIORITY" > "${TMP_PRIORITY}.u" && mv "${TMP_PRIORITY}.u" "$TMP_PRIORITY"
sort -u "$TMP_POOL" > "${TMP_POOL}.u" && mv "${TMP_POOL}.u" "$TMP_POOL"

# Рандомизируем только пул
if [ -s "$TMP_POOL" ]; then
    awk 'BEGIN{srand()} {print rand() "\t" $0}' "$TMP_POOL" | sort -n | cut -f2- > "${TMP_POOL}.rnd"
else
    : > "${TMP_POOL}.rnd"
fi

# Сначала добавляем приоритетные прямые ключи
cat "$TMP_PRIORITY" > "$TMP_FINAL"

# Потом добираем случайными из пула до LIMIT
while read -r link; do
    [ -z "$link" ] && continue

    count=$(wc -l < "$TMP_FINAL" | tr -d ' ')
    [ "$count" -ge "$LIMIT" ] && break

    grep -Fxq "$link" "$TMP_FINAL" && continue
    printf '%s\n' "$link" >> "$TMP_FINAL"
done < "${TMP_POOL}.rnd"

TOTAL=$(wc -l < "$TMP_FINAL" | tr -d ' ')

# Если ничего не осталось — ничего не меняем
if [ "$TOTAL" -eq 0 ]; then
    log "❌ Нет рабочих ключей — ничего не меняем"
    exit 0
fi

log "✨ Готово! Выбрано $TOTAL качественных серверов"

# --- UCI ---
# Сначала удаляем старые ключи
uci -q delete podkop.main.urltest_proxy_links
log "🧹 Старые ключи удалены из конфига"

# Затем настраиваем Podkop
log "⚙️  Настройка Podkop: включение URLTest и запись ключей..."
uci set podkop.main.connection_type='proxy'
uci set podkop.main.proxy_config_type='urltest'
uci set podkop.main.urltest_check_interval='1m'
uci set podkop.main.urltest_tolerance='150'
uci set podkop.main.urltest_testing_url='https://cp.cloudflare.com/generate_204'

# Записываем список ключей в конфиг
WRITTEN=0
while read -r link; do
    [ -n "$link" ] || continue
    case "$link" in
        *pbk=*)
            fp=$(printf '%s' "$link" | sed -nE 's/.*[?&]fp=([^&]+).*/\1/p')
            case "$fp" in
                chrome|firefox|safari|ios|android|edge|360|random) ;;
                *)
                    log "⛔ Отброшен (fp='$fp'): $link"
                    continue
                    ;;
            esac
            ;;
    esac
    uci add_list podkop.main.urltest_proxy_links="$link"
    WRITTEN=$((WRITTEN + 1))
done < "$TMP_FINAL"

uci commit podkop

# Перезапускаем сервис
log "🔄 Перезапуск сервиса..."
/etc/init.d/podkop restart

log "🚀 Обновление успешно завершено! Записано серверов: $WRITTEN"
