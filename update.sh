#!/bin/sh

# --- НАСТРОЙКИ ---
# Здесь можно указать:
# - raw-ссылки на подписки
# - прямые ссылки вида vless://, ss://, trojan://, socks://, hy2://
SCRIPT_VERSION="2026.04.29-1"
SOURCE_1=""
SOURCE_2=""
SOURCE_3=""
CONFIG_FILE="/etc/podkop-update.conf"
UPDATE_INTERVAL_HOURS="3"
FORCE_SETUP="0"
UPDATES_ONLY="0"
CHECK_SELF_UPDATE_ONLY="0"
AUTO_UPDATE_SCRIPT="1"
AUTO_UPDATE_PODKOP="1"
PODKOP_INSTALL_AUTO_YES="1"
SCRIPT_UPDATE_URL="https://git.kinoteka.space/KirsanovAdmin/podkop-urltest-subscription_ai/raw/branch/main/update.sh"
PODKOP_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
PODKOP_PACKAGE_CANDIDATES="luci-app-podkop podkop"
PKG_MANAGER=""
PKG_INDEXES_UPDATED="0"
SCRIPT_SELF_PATH=""

# User-Agent, который увидит сервер подписки.
SUBSCRIPTION_USER_AGENT="v2rayNG/1.8.5"

# Файл с постоянным HWID. Если X_HWID пустой, скрипт возьмет значение отсюда
# или создаст новый UUID при первом запуске.
HWID_FILE="/etc/podkop-hwid"

# Опциональный ручной override для HWID.
X_HWID=""

# Заголовки устройства для bot-vpn/subpage:
# - X-Device-OS
# - X-Ver-OS
# - X-Device-Model
X_DEVICE_OS=""
X_VER_OS=""
X_DEVICE_MODEL=""

# Устаревшие совместимые переменные.
# Если они заданы, скрипт постарается корректно преобразовать их в новые поля.
X_OS=""
X_MODEL=""

# Автоматически поддерживать cron-задачу для обновления подписок.
AUTO_INSTALL_CRON="1"
CRON_FILE="/etc/crontabs/root"
CRON_SCHEDULE="0 */3 * * *"
CRON_COMMAND="/usr/bin/podkop-update >> /var/log/podkop-update.log 2>&1"
UPDATE_CRON_SCHEDULE="0 5 * * 1"
UPDATE_CRON_COMMAND="/usr/bin/podkop-update --updates-only >> /var/log/podkop-update.log 2>&1"

# URL для URLTest и последующей проверки доступности после перезапуска Podkop.
URLTEST_TESTING_URL="https://cp.cloudflare.com/generate_204"
POST_RESTART_CHECK_ATTEMPTS="10"
POST_RESTART_CHECK_DELAY="3"

# Сколько максимум ключей класть в Podkop
LIMIT=27
# -----------------

log() { echo "[$(date '+%F %T')] $*" >&2; }

TMP_PRIORITY="$(mktemp)"
TMP_POOL="$(mktemp)"
TMP_FINAL="$(mktemp)"
TMP_WRITTEN="$(mktemp)"
TMP_CURRENT="$(mktemp)"

trap 'rm -f "$TMP_PRIORITY" "$TMP_POOL" "$TMP_FINAL" "$TMP_WRITTEN" "$TMP_CURRENT" "${TMP_POOL}.rnd" "${TMP_PRIORITY}.u" "${TMP_POOL}.u" "${TMP_WRITTEN}.u" "${TMP_CURRENT}.u"' EXIT INT TERM

print_usage() {
    cat <<EOF
Использование:
  $0 [--setup|--updates-only|--check-self-update|--version]

Опции:
  --setup          Запустить мастер настройки и сохранить ответы в $CONFIG_FILE
  --updates-only   Проверить и установить обновления podkop-update и Podkop, затем выйти
  --check-self-update  Проверить наличие новой версии podkop-update и выйти
  --version        Показать версию podkop-update и выйти
EOF
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

resolve_script_path() {
    case "$0" in
        /*) SCRIPT_SELF_PATH="$0" ;;
        *)
            SCRIPT_SELF_PATH="$(command -v "$0" 2>/dev/null)"
            [ -n "$SCRIPT_SELF_PATH" ] || SCRIPT_SELF_PATH="$0"
            ;;
    esac
}

prompt_required_number() {
    label="$1"
    min="$2"
    max="$3"

    while :; do
        printf '%s (%s-%s): ' "$label" "$min" "$max"
        IFS= read -r value || exit 1

        case "$value" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
                    PROMPT_VALUE="$value"
                    return 0
                fi
                ;;
        esac

        echo "Введите число от $min до $max."
    done
}

prompt_required_text() {
    label="$1"

    while :; do
        printf '%s: ' "$label"
        IFS= read -r value || exit 1
        if [ -n "$value" ]; then
            PROMPT_VALUE="$value"
            return 0
        fi
        echo "Поле не может быть пустым."
    done
}

prompt_optional_text() {
    label="$1"
    printf '%s (Enter = пропустить): ' "$label"
    IFS= read -r PROMPT_VALUE || exit 1
}

prompt_agent_choice() {
    echo "Агент подписки:"
    echo "  1. Happ/2.7.0"
    echo "  2. v2rayNG/1.8.5"
    echo "  3. INCY/2.0.9"

    while :; do
        printf 'Выберите агент (1-3): '
        IFS= read -r value || exit 1
        case "$value" in
            1|Happ/2.7.0|happ|Happ)
                PROMPT_VALUE="Happ/2.7.0"
                return 0
                ;;
            2|v2rayNG/1.8.5|v2rayNG|v2rayng)
                PROMPT_VALUE="v2rayNG/1.8.5"
                return 0
                ;;
            3|INCY/2.0.9|incy|INCY)
                PROMPT_VALUE="INCY/2.0.9"
                return 0
                ;;
        esac
        echo "Выберите 1, 2 или 3."
    done
}

normalize_update_interval() {
    case "$UPDATE_INTERVAL_HOURS" in
        ''|*[!0-9]*) UPDATE_INTERVAL_HOURS="3" ;;
        *)
            if [ "$UPDATE_INTERVAL_HOURS" -lt 1 ] || [ "$UPDATE_INTERVAL_HOURS" -gt 12 ]; then
                UPDATE_INTERVAL_HOURS="3"
            fi
            ;;
    esac

    CRON_SCHEDULE="0 */$UPDATE_INTERVAL_HOURS * * *"
}

detect_package_manager() {
    if [ -n "$PKG_MANAGER" ]; then
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        return 0
    fi

    if command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
        return 0
    fi

    return 1
}

ensure_package_indexes_updated() {
    [ "$PKG_INDEXES_UPDATED" = "1" ] && return 0
    detect_package_manager || return 1

    case "$PKG_MANAGER" in
        apk)
            log "📦 Обновление индексов пакетов apk..."
            apk update >/dev/null 2>&1 || return 1
            ;;
        opkg)
            log "📦 Обновление индексов пакетов opkg..."
            opkg update >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac

    PKG_INDEXES_UPDATED="1"
    return 0
}

is_package_installed() {
    pkg="$1"
    detect_package_manager || return 1

    case "$PKG_MANAGER" in
        apk)
            apk info -e "$pkg" >/dev/null 2>&1
            ;;
        opkg)
            opkg status "$pkg" 2>/dev/null | grep -q '^Status: .* installed'
            ;;
        *)
            return 1
            ;;
    esac
}

upgrade_package_if_installed() {
    pkg="$1"
    is_package_installed "$pkg" || return 1
    ensure_package_indexes_updated || return 1

    case "$PKG_MANAGER" in
        apk)
            log "📦 Проверка обновления пакета $pkg..."
            apk upgrade "$pkg" >/dev/null 2>&1 || return 1
            ;;
        opkg)
            log "📦 Проверка обновления пакета $pkg..."
            opkg upgrade "$pkg" >/dev/null 2>&1 || return 1
            ;;
        *)
            return 1
            ;;
    esac

    return 0
}

run_official_podkop_installer() {
    action_label="$1"
    [ -n "$PODKOP_INSTALL_SCRIPT_URL" ] || return 1

    tmp_installer="$(mktemp /tmp/podkop-install.XXXXXX)" || return 1

    if wget --no-check-certificate -qO "$tmp_installer" "$PODKOP_INSTALL_SCRIPT_URL" 2>/dev/null; then
        if grep -q '^#!/' "$tmp_installer"; then
            log "📦 $action_label Podkop через официальный install.sh..."
            if [ "$PODKOP_INSTALL_AUTO_YES" = "1" ]; then
                log "ℹ️  Автоответ на вопросы install.sh: yes"
                yes | sh "$tmp_installer"
            elif [ -t 0 ] && [ -t 1 ]; then
                sh "$tmp_installer"
            else
                log "ℹ️  Нет интерактивного терминала, официальный install.sh пропущен"
                rm -f "$tmp_installer"
                return 1
            fi
            if [ $? -eq 0 ]; then
                rm -f "$tmp_installer"
                return 0
            fi
            log "⚠️  Официальный install.sh завершился с ошибкой"
        else
            log "⚠️  Получен некорректный install.sh для Podkop"
        fi
    else
        log "⚠️  Не удалось скачать официальный install.sh для Podkop"
    fi

    rm -f "$tmp_installer"
    return 1
}

ensure_podkop_installed() {
    if [ -x /etc/init.d/podkop ]; then
        return 0
    fi

    log "📦 Podkop не найден, пытаюсь установить..."

    if run_official_podkop_installer "Установка"; then
        if [ -x /etc/init.d/podkop ]; then
            log "✅ Podkop установлен"
            return 0
        fi
        log "⚠️  install.sh завершился без ошибки, но Podkop не найден после установки"
    fi

    log "❌ Не удалось установить Podkop"
    return 1
}

ensure_podkop_updated() {
    [ "$AUTO_UPDATE_PODKOP" = "1" ] || return 0
    [ -x /etc/init.d/podkop ] || return 0

    if run_official_podkop_installer "Проверка обновления"; then
        log "✅ Проверка обновления Podkop через install.sh выполнена"
        return 0
    fi

    log "⚠️  Перехожу к fallback через пакетный менеджер"

    found_pkg="0"
    for pkg in $PODKOP_PACKAGE_CANDIDATES; do
        if is_package_installed "$pkg"; then
            found_pkg="1"
            if upgrade_package_if_installed "$pkg"; then
                log "✅ Проверка обновления Podkop выполнена для пакета $pkg"
            else
                log "⚠️  Не удалось проверить или установить обновление для пакета $pkg"
            fi
        fi
    done

    if [ "$found_pkg" != "1" ]; then
        log "ℹ️  Пакет Podkop не найден в списке: $PODKOP_PACKAGE_CANDIDATES"
    fi
}

ensure_script_updated() {
    [ "$AUTO_UPDATE_SCRIPT" = "1" ] || return 0
    [ -n "$SCRIPT_UPDATE_URL" ] || return 0

    resolve_script_path
    [ -n "$SCRIPT_SELF_PATH" ] || return 0
    [ -w "$SCRIPT_SELF_PATH" ] || return 0

    tmp_script="$(mktemp /tmp/podkop-update.XXXXXX)" || return 1

    if ! wget --no-check-certificate -qO "$tmp_script" "$SCRIPT_UPDATE_URL" 2>/dev/null; then
        log "⚠️  Не удалось проверить обновление скрипта"
        rm -f "$tmp_script"
        return 1
    fi

    if ! grep -q '^#!/bin/sh' "$tmp_script"; then
        log "⚠️  Получен некорректный файл обновления скрипта"
        rm -f "$tmp_script"
        return 1
    fi

    if cmp -s "$tmp_script" "$SCRIPT_SELF_PATH"; then
        rm -f "$tmp_script"
        return 0
    fi

    if mv "$tmp_script" "$SCRIPT_SELF_PATH"; then
        chmod +x "$SCRIPT_SELF_PATH" 2>/dev/null
        log "✅ Скрипт обновлен: $SCRIPT_SELF_PATH"
        return 0
    fi

    log "⚠️  Не удалось установить обновление скрипта"
    rm -f "$tmp_script"
    return 1
}

check_self_update() {
    [ -n "$SCRIPT_UPDATE_URL" ] || {
        log "⚠️  SCRIPT_UPDATE_URL не задан"
        return 1
    }

    resolve_script_path
    [ -n "$SCRIPT_SELF_PATH" ] || {
        log "⚠️  Не удалось определить путь к текущему скрипту"
        return 1
    }

    tmp_script="$(mktemp /tmp/podkop-update-check.XXXXXX)" || return 1

    if ! wget --no-check-certificate -qO "$tmp_script" "$SCRIPT_UPDATE_URL" 2>/dev/null; then
        log "❌ Не удалось скачать удалённую версию скрипта"
        rm -f "$tmp_script"
        return 1
    fi

    remote_version=$(sed -n "s/^SCRIPT_VERSION=\"\\([^\"]*\\)\"$/\\1/p" "$tmp_script" | sed -n '1p')
    [ -n "$remote_version" ] || remote_version="unknown"

    if cmp -s "$tmp_script" "$SCRIPT_SELF_PATH"; then
        echo "podkop-update: актуальная версия"
        echo "local:  $SCRIPT_VERSION"
        echo "remote: $remote_version"
        rm -f "$tmp_script"
        return 0
    fi

    echo "podkop-update: доступно обновление"
    echo "local:  $SCRIPT_VERSION"
    echo "remote: $remote_version"
    rm -f "$tmp_script"
    return 1
}

load_config() {
    [ -r "$CONFIG_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    return 0
}

save_config() {
    tmp_config="$(mktemp /tmp/podkop-update.conf.XXXXXX)" || return 1

    {
        echo "# Автоматически создано podkop-update"
        printf 'SOURCE_1=%s\n' "$(shell_quote "$SOURCE_1")"
        printf 'SOURCE_2=%s\n' "$(shell_quote "$SOURCE_2")"
        printf 'SOURCE_3=%s\n' "$(shell_quote "$SOURCE_3")"
        printf 'SUBSCRIPTION_USER_AGENT=%s\n' "$(shell_quote "$SUBSCRIPTION_USER_AGENT")"
        printf 'X_DEVICE_OS=%s\n' "$(shell_quote "$X_DEVICE_OS")"
        printf 'X_VER_OS=%s\n' "$(shell_quote "$X_VER_OS")"
        printf 'X_DEVICE_MODEL=%s\n' "$(shell_quote "$X_DEVICE_MODEL")"
        printf 'UPDATE_INTERVAL_HOURS=%s\n' "$(shell_quote "$UPDATE_INTERVAL_HOURS")"
    } > "$tmp_config" || {
        rm -f "$tmp_config"
        return 1
    }

    chmod 600 "$tmp_config" 2>/dev/null
    mv "$tmp_config" "$CONFIG_FILE"
}

run_setup_wizard() {
    if [ ! -t 0 ]; then
        log "❌ Нет интерактивного терминала. Запустите $0 --setup вручную по SSH."
        exit 1
    fi

    echo "=== Мастер настройки podkop-update ==="

    prompt_required_number "1. Сколько подписок" 1 3
    source_count="$PROMPT_VALUE"

    SOURCE_1=""
    SOURCE_2=""
    SOURCE_3=""

    idx=1
    while [ "$idx" -le "$source_count" ]; do
        prompt_required_text "2.$idx Ссылка на подписку"
        case "$idx" in
            1) SOURCE_1="$PROMPT_VALUE" ;;
            2) SOURCE_2="$PROMPT_VALUE" ;;
            3) SOURCE_3="$PROMPT_VALUE" ;;
        esac
        idx=$((idx + 1))
    done

    prompt_agent_choice
    SUBSCRIPTION_USER_AGENT="$PROMPT_VALUE"

    prompt_optional_text "3. Операционная система"
    X_DEVICE_OS="$PROMPT_VALUE"

    prompt_optional_text "4. Версия ОС"
    X_VER_OS="$PROMPT_VALUE"

    prompt_optional_text "5. Модель девайса"
    X_DEVICE_MODEL="$PROMPT_VALUE"

    prompt_required_number "6. Авто-обновление подписки в часах" 1 12
    UPDATE_INTERVAL_HOURS="$PROMPT_VALUE"

    normalize_update_interval

    save_config || {
        log "❌ Не удалось сохранить конфиг в $CONFIG_FILE"
        exit 1
    }

    log "✅ Настройки сохранены в $CONFIG_FILE"
}

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

generate_hwid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi

    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
        return 0
    fi

    return 1
}

detect_openwrt_os() {
    if [ -r /etc/openwrt_release ]; then
        os_name=$(sed -n "s/^DISTRIB_ID=['\"]\\{0,1\\}\\([^'\"]*\\)['\"]\\{0,1\\}$/\\1/p" /etc/openwrt_release | sed -n '1p')
        if [ -n "$os_name" ]; then
            printf '%s\n' "$os_name"
            return 0
        fi
    fi

    printf '%s\n' "OpenWrt"
}

detect_openwrt_version() {
    if [ -r /etc/openwrt_release ]; then
        sed -n "s/^DISTRIB_RELEASE=['\"]\\{0,1\\}\\([^'\"]*\\)['\"]\\{0,1\\}$/\\1/p" /etc/openwrt_release | sed -n '1p'
        return 0
    fi

    return 1
}

detect_openwrt_target() {
    if [ -r /etc/openwrt_release ]; then
        sed -n "s/^DISTRIB_TARGET=['\"]\\{0,1\\}\\([^'\"]*\\)['\"]\\{0,1\\}$/\\1/p" /etc/openwrt_release | sed -n '1p'
        return 0
    fi

    return 1
}

detect_openwrt_model() {
    if [ -s /tmp/sysinfo/model ]; then
        sed -n '1p' /tmp/sysinfo/model
        return 0
    fi

    if [ -s /tmp/sysinfo/board_name ]; then
        sed -n '1p' /tmp/sysinfo/board_name
        return 0
    fi

    if [ -r /proc/device-tree/model ]; then
        tr -d '\000' < /proc/device-tree/model
        return 0
    fi

    target="$(detect_openwrt_target)"
    if [ -n "$target" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    return 1
}

is_version_like() {
    case "$1" in
        '' ) return 1 ;;
        *[!0-9._-]* ) return 1 ;;
        *[0-9]*.*[0-9]* ) return 0 ;;
        * ) return 1 ;;
    esac
}

ensure_hwid() {
    [ -n "$X_HWID" ] && return 0

    if [ -s "$HWID_FILE" ]; then
        X_HWID=$(sed -n '1p' "$HWID_FILE" | tr -d '\r\n')
        [ -n "$X_HWID" ] && return 0
    fi

    X_HWID=$(generate_hwid) || {
        log "⚠️  Не удалось сгенерировать HWID"
        return 1
    }

    if printf '%s\n' "$X_HWID" > "$HWID_FILE" 2>/dev/null; then
        log "🆔 Создан новый HWID: $HWID_FILE"
    else
        log "⚠️  HWID сгенерирован, но не сохранен в $HWID_FILE"
    fi
}

ensure_device_headers() {
    if [ -z "$X_DEVICE_OS" ]; then
        if [ -n "$X_OS" ] && ! is_version_like "$X_OS"; then
            X_DEVICE_OS="$X_OS"
        else
            X_DEVICE_OS="$(detect_openwrt_os)"
        fi
    fi

    if [ -z "$X_VER_OS" ]; then
        if is_version_like "$X_MODEL"; then
            X_VER_OS="$X_MODEL"
        else
            X_VER_OS="$(detect_openwrt_version)"
        fi
    fi

    if [ -z "$X_DEVICE_MODEL" ]; then
        if [ -n "$X_MODEL" ] && ! is_version_like "$X_MODEL"; then
            X_DEVICE_MODEL="$X_MODEL"
        else
            X_DEVICE_MODEL="$(detect_openwrt_model)"
        fi
    fi
}

ensure_cron_job() {
    [ "$AUTO_INSTALL_CRON" = "1" ] || return 0

    cron_line="${CRON_SCHEDULE} ${CRON_COMMAND}"
    update_cron_line="${UPDATE_CRON_SCHEDULE} ${UPDATE_CRON_COMMAND}"

    if [ -f "$CRON_FILE" ] &&
       grep -Fxq "$cron_line" "$CRON_FILE" &&
       grep -Fxq "$update_cron_line" "$CRON_FILE"; then
        return 0
    fi

    if [ ! -f "$CRON_FILE" ]; then
        : > "$CRON_FILE" 2>/dev/null || {
            log "⚠️  Не удалось создать $CRON_FILE"
            return 1
        }
    fi

    sed -i '/\/usr\/bin\/podkop-update/d' "$CRON_FILE" 2>/dev/null || {
        log "⚠️  Не удалось обновить cron в $CRON_FILE"
        return 1
    }

    printf '%s\n' "$cron_line" >> "$CRON_FILE" || {
        log "⚠️  Не удалось записать cron-задачу"
        return 1
    }

    printf '%s\n' "$update_cron_line" >> "$CRON_FILE" || {
        log "⚠️  Не удалось записать cron-задачу обновления"
        return 1
    }

    /etc/init.d/cron restart >/dev/null 2>&1 || {
        log "⚠️  Не удалось перезапустить cron"
        return 1
    }

    log "⏰ Cron обновлен: подписки '$CRON_SCHEDULE', обновления '$UPDATE_CRON_SCHEDULE'"
}

wait_for_podkop() {
    attempt=1
    while [ "$attempt" -le "$POST_RESTART_CHECK_ATTEMPTS" ]; do
        if /etc/init.d/podkop status >/dev/null 2>&1 || pidof sing-box >/dev/null 2>&1; then
            return 0
        fi

        sleep "$POST_RESTART_CHECK_DELAY"
        attempt=$((attempt + 1))
    done

    return 1
}

check_servers_after_restart() {
    if ! wait_for_podkop; then
        log "❌ Podkop не поднялся после перезапуска"
        return 1
    fi

    log "✅ Podkop запущен; дальнейшая проверка доступности выполняется встроенным URLTest"
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --setup)
            FORCE_SETUP="1"
            ;;
        --updates-only)
            UPDATES_ONLY="1"
            ;;
        --check-self-update)
            CHECK_SELF_UPDATE_ONLY="1"
            ;;
        --version)
            echo "$SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log "❌ Неизвестный аргумент: $1"
            print_usage
            exit 1
            ;;
    esac
    shift
done

ensure_podkop_installed || exit 1

if [ "$CHECK_SELF_UPDATE_ONLY" = "1" ]; then
    check_self_update
    exit $?
fi

load_config >/dev/null 2>&1

if [ "$FORCE_SETUP" = "1" ] || [ ! -s "$CONFIG_FILE" ]; then
    run_setup_wizard
fi

load_config >/dev/null 2>&1
normalize_update_interval

if [ "$UPDATES_ONLY" = "1" ]; then
    log "🔄 Проверка обновлений..."
    ensure_script_updated
    ensure_podkop_updated
    ensure_cron_job
    log "✅ Проверка обновлений завершена"
    exit 0
fi

# --- СКАЧИВАНИЕ ---
# Загружает сырой текст/HTML/подписку
download_content() {
    url="$1"

    set -- \
        --no-check-certificate \
        --user-agent="$SUBSCRIPTION_USER_AGENT" \
        -qO-

    [ -n "$X_HWID" ] && set -- "$@" --header="X-HWID: $X_HWID"
    [ -n "$X_DEVICE_OS" ] && set -- "$@" --header="X-Device-OS: $X_DEVICE_OS"
    [ -n "$X_VER_OS" ] && set -- "$@" --header="X-Ver-OS: $X_VER_OS"
    [ -n "$X_DEVICE_MODEL" ] && set -- "$@" --header="X-Device-Model: $X_DEVICE_MODEL"
    [ -n "$X_OS" ] && set -- "$@" --header="X-OS: $X_OS"
    [ -n "$X_MODEL" ] && set -- "$@" --header="X-Model: $X_MODEL"

    raw=$(wget "$@" "$url" 2>/dev/null)
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

    [ -n "$input" ] || return 0

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
ensure_hwid
ensure_device_headers
ensure_cron_job
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
    printf '%s\n' "$link" >> "$TMP_WRITTEN"
    WRITTEN=$((WRITTEN + 1))
done < "$TMP_FINAL"

# Если после финальной фильтрации не осталось валидных серверов — ничего не меняем
if [ "$WRITTEN" -eq 0 ]; then
    log "❌ После финальной проверки не осталось валидных серверов — ничего не меняем"
    exit 0
fi

uci -q export podkop 2>/dev/null | awk '
    $1 == "config" && $2 == "section" {
        in_main = ($3 == "'\''main'\''")
        next
    }
    in_main && $1 == "list" && $2 == "urltest_proxy_links" {
        line = $0
        sub(/^[[:space:]]*list urltest_proxy_links /, "", line)
        sub(/^'\''/, "", line)
        sub(/'\''$/, "", line)
        print line
    }
' > "$TMP_CURRENT"

sort -u "$TMP_WRITTEN" > "${TMP_WRITTEN}.u" && mv "${TMP_WRITTEN}.u" "$TMP_WRITTEN"
sort -u "$TMP_CURRENT" > "${TMP_CURRENT}.u" && mv "${TMP_CURRENT}.u" "$TMP_CURRENT"

LINKS_CHANGED=0
SETTINGS_CHANGED=0

cmp -s "$TMP_WRITTEN" "$TMP_CURRENT" || LINKS_CHANGED=1
[ "$(uci -q get podkop.main.connection_type)" = "proxy" ] || SETTINGS_CHANGED=1
[ "$(uci -q get podkop.main.proxy_config_type)" = "urltest" ] || SETTINGS_CHANGED=1
[ "$(uci -q get podkop.main.urltest_check_interval)" = "1m" ] || SETTINGS_CHANGED=1
[ "$(uci -q get podkop.main.urltest_tolerance)" = "150" ] || SETTINGS_CHANGED=1
[ "$(uci -q get podkop.main.urltest_testing_url)" = "$URLTEST_TESTING_URL" ] || SETTINGS_CHANGED=1

if [ "$LINKS_CHANGED" -eq 0 ] && [ "$SETTINGS_CHANGED" -eq 0 ]; then
    log "✅ Изменений в конфиге Podkop нет — перезапуск не требуется"
    log "🚀 Обновление успешно завершено! Записано серверов: $WRITTEN"
    exit 0
fi

# --- UCI ---
log "🧹 Применение изменений в конфиг Podkop..."
uci -q delete podkop.main.urltest_proxy_links

# Затем настраиваем Podkop
log "⚙️  Настройка Podkop: включение URLTest и запись ключей..."
uci set podkop.main.connection_type='proxy'
uci set podkop.main.proxy_config_type='urltest'
uci set podkop.main.urltest_check_interval='1m'
uci set podkop.main.urltest_tolerance='150'
uci set podkop.main.urltest_testing_url="$URLTEST_TESTING_URL"

while read -r link; do
    [ -n "$link" ] || continue
    uci add_list podkop.main.urltest_proxy_links="$link"
done < "$TMP_WRITTEN"

uci commit podkop

# Перезапускаем сервис
log "🔄 Перезапуск сервиса..."
/etc/init.d/podkop restart || {
    log "❌ Не удалось перезапустить Podkop"
    exit 1
}

log "🩺 Проверка доступности серверов..."
check_servers_after_restart

log "🚀 Обновление успешно завершено! Записано серверов: $WRITTEN"
