#!/bin/sh

# --- НАСТРОЙКИ ---
# Здесь можно указать:
# - raw-ссылки на подписки
# - прямые ссылки вида vless://, ss://, trojan://, socks://, hy2://
SCRIPT_VERSION="2026.11.25.1"
SOURCE_1=""
SOURCE_2=""
SOURCE_3=""
CONFIG_FILE="/etc/podkop-update.conf"
UPDATE_INTERVAL_HOURS="3"
FORCE_SETUP="0"
UPDATES_ONLY="0"
CHECK_SELF_UPDATE_ONLY="0"
AUTO_UPDATE_SCRIPT="1"
AUTO_UPDATE_PODKOP="0"
AUTO_UPDATE_SING_BOX="1"
# Pinned build selected for the current Podkop integration.
TESTED_ENGINE_VERSION="1.14.4-r29"
PODKOP_INSTALL_AUTO_YES="1"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/AlanWakeKing/podkop-urltest-subscription_ai/main/update.sh"
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
UPDATE_CRON_SCHEDULE="0 * * * *"
UPDATE_CRON_COMMAND="/usr/bin/podkop-update --updates-only >> /var/log/podkop-update.log 2>&1"

# URL для URLTest и последующей проверки доступности после перезапуска Podkop.
URLTEST_TESTING_URL="https://cp.cloudflare.com/generate_204"
POST_RESTART_CHECK_ATTEMPTS="10"
POST_RESTART_CHECK_DELAY="3"

# Сколько максимум ключей класть в Podkop
LIMIT=60

# Исключать серверы по имени (grep -E, ДО URL-декодирования — буквы/цифры как есть,
# пробел/спецсимволы в %XX-виде). Группы, которые не должны попадать в Podkop:
# EU Balanser WIFI #*, Moscow *, RU -> EU Balanser #*
EXCLUDE_NAME_PATTERN='Balanser%20WIFI|Moscow|RU%20-%3E%20'
# -----------------

log() { echo "[$(date '+%F %T')] $*" >&2; }

MAX_LOG_LINES=500
LOG_FILE="/var/log/podkop-update.log"
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

TMP_PRIORITY="$(mktemp)"
TMP_POOL="$(mktemp)"
TMP_FINAL="$(mktemp)"
TMP_WRITTEN="$(mktemp)"
TMP_CURRENT="$(mktemp)"
TMP_ENGINE_DIR=""
ENGINE_SWITCH_ACTIVE="0"
ENGINE_RECOVERY_REQUIRED="0"
ENGINE_RECOVERY_DIR="/overlay/podkop-update-sing-box-recovery"
ENGINE_RECOVERY_PACKAGE=""
ENGINE_RECOVERY_CREATED="0"
ENGINE_ORIGIN=""
ENGINE_PREVIOUS_VERSION=""
STOCK_PREVIOUS_VERSION=""
STOCK_PREVIOUS_BINARY_SHA256=""
STOCK_ROLLBACK_BINARY_SHA256=""
STOCK_BINARY_PATH="/usr/bin/sing-box"
STOCK_ROLLBACK_PACKAGE=""
STOCK_ROLLBACK_BINARY_VERSION=""
UNOWNED_BACKUP_DIR="/etc/podkop-update-sing-box-backup"
UNOWNED_BACKUP_STAGING=""

persistent_overlay_mountpoint() {
    mount_target=$1
    mounts_file=${2:-/proc/mounts}
    case "$mount_target" in /*) ;; *) return 1 ;; esac
    [ -d "$mount_target" ] && [ ! -L "$mount_target" ] || return 1
    [ -r "$mounts_file" ] || return 1
    mount_record=$(awk -v path="$mount_target" '
        $2 == path {
            exact_count++
            if (NF != 6 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/)
                invalid = 1
            exact_source = $1
            exact_path = $2
            exact_type = $3
            exact_options = $4
        }
        END {
            if (exact_count == 1 && !invalid) print exact_source "|" exact_path "|" exact_type "|" exact_options
        }
    ' "$mounts_file") || return 1
    mount_source=$(printf '%s\n' "$mount_record" | cut -d '|' -f1)
    mount_path=$(printf '%s\n' "$mount_record" | cut -d '|' -f2)
    mount_type=$(printf '%s\n' "$mount_record" | cut -d '|' -f3)
    mount_options=$(printf '%s\n' "$mount_record" | cut -d '|' -f4)
    if [ -z "$mount_source" ] || [ -z "$mount_path" ] || [ -z "$mount_type" ] || [ -z "$mount_options" ]; then
        return 1
    fi
    case "$mount_source" in /dev/loop*|loop*) return 1 ;; esac
    case "$mount_type" in ext4|f2fs|jffs2|ubifs) ;; *) return 1 ;; esac
    case ",$mount_options," in *,rw,*) ;; *) return 1 ;; esac
    printf '%s\n' "$mount_path"
}

persist_engine_recovery_package() {
    recovery_source=$1
    recovery_destination=$2
    recovery_overlay=$3
    recovery_origin=$4
    recovery_version=$5
    [ -f "$recovery_source" ] && [ ! -L "$recovery_source" ] || return 1
    case "$recovery_origin" in podkop-engine|stock) ;; *) return 1 ;; esac
    case "$recovery_version" in ''|*[!a-zA-Z0-9.+_-]*) return 1 ;; esac
    recovery_parent=${recovery_destination%/*}
    case "$recovery_overlay" in /*) ;; *) return 1 ;; esac
    if [ "$recovery_parent" != "$recovery_overlay" ] ||
        [ ! -d "$recovery_overlay" ] || [ ! -w "$recovery_overlay" ]; then
        log "❌ CRITICAL: recovery destination must be a writable direct child of the persistent overlay"
        return 1
    fi
    recovery_mounts_file=${6:-/proc/mounts}
    recovery_overlay_mountpoint=$(persistent_overlay_mountpoint "$recovery_overlay" "$recovery_mounts_file") || {
        log "❌ CRITICAL: $recovery_overlay is not backed by a writable persistent filesystem"
        return 1
    }
    if [ -e "$recovery_destination" ] || [ -L "$recovery_destination" ]; then
        log "❌ CRITICAL: prior recovery directory exists at $recovery_destination; refusing package update"
        return 1
    fi
    recovery_size_bytes=$(wc -c < "$recovery_source" | tr -d '[:space:]') || return 1
    case "$recovery_size_bytes" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#recovery_size_bytes}" -le 9 ] || return 1
    recovery_overlay_df=$(df -Pk "$recovery_overlay" 2>/dev/null) || return 1
    recovery_overlay_free_kb=$(printf '%s\n' "$recovery_overlay_df" | awk -v path="$recovery_overlay_mountpoint" '
        NR == 1 { next }
        NF >= 6 && $NF == path { rows++; available = $4 }
        END { if (rows == 1 && available ~ /^[0-9]+$/) print available }
    ')
    case "$recovery_overlay_free_kb" in ''|*[!0-9]*) return 1 ;; esac
    case "$recovery_overlay_free_kb" in 0*) [ "$recovery_overlay_free_kb" = "0" ] || return 1 ;; esac
    recovery_required_kb=$(((recovery_size_bytes + 1023) / 1024 + 12000))
    # size_bytes is at most 9 decimal digits, so required_kb is < 1,000,000.
    # Values with 7+ digits therefore exceed the maximum reserve without shell arithmetic.
    if [ "${#recovery_overlay_free_kb}" -le 6 ] &&
        [ "$recovery_overlay_free_kb" -lt "$recovery_required_kb" ]; then
        log "❌ sing-box: insufficient /overlay space for persistent rollback package"
        return 1
    fi
    recovery_source_hash=$(sha256sum "$recovery_source" 2>/dev/null | cut -d ' ' -f1) || return 1
    [ "${#recovery_source_hash}" -eq 64 ] || return 1
    recovery_staging=$(mktemp -d "${recovery_destination}.XXXXXX") || return 1
    chmod 700 "$recovery_staging" || { rm -rf "$recovery_staging"; return 1; }
    if ! cp "$recovery_source" "$recovery_staging/rollback.ipk" ||
        ! chmod 600 "$recovery_staging/rollback.ipk" ||
        [ "$(wc -c < "$recovery_staging/rollback.ipk" | tr -d '[:space:]')" != "$recovery_size_bytes" ] ||
        [ "$(sha256sum "$recovery_staging/rollback.ipk" 2>/dev/null | cut -d ' ' -f1)" != "$recovery_source_hash" ]; then
        rm -rf "$recovery_staging"
        return 1
    fi
    {
        printf 'origin=%s\n' "$recovery_origin"
        printf 'version=%s\n' "$recovery_version"
        printf 'size_bytes=%s\n' "$recovery_size_bytes"
        printf 'sha256=%s\n' "$recovery_source_hash"
    } > "$recovery_staging/manifest" || { rm -rf "$recovery_staging"; return 1; }
    chmod 600 "$recovery_staging/manifest" || { rm -rf "$recovery_staging"; return 1; }
    if ! mv "$recovery_staging" "$recovery_destination"; then
        rm -rf "$recovery_staging"
        return 1
    fi
    ENGINE_RECOVERY_PACKAGE="$recovery_destination/rollback.ipk"
    ENGINE_RECOVERY_CREATED="1"
    return 0
}

LOCK_FILE="/var/run/podkop-update.lock"
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        log "⚠️  Уже запущен (PID $lock_pid), выход"
        exit 0
    fi
fi
printf '%s\n' "$$" > "$LOCK_FILE"

cleanup_update() {
    # A second TERM during emergency rollback must not abort recovery.
    trap '' INT TERM
    if [ "$ENGINE_SWITCH_ACTIVE" = "1" ]; then
        log "❌ sing-box: interrupted during package switch; attempting rollback"
        cleanup_restore_rc=0
        restore_previous_sing_box || cleanup_restore_rc=$?
        if [ "$cleanup_restore_rc" -ne 0 ]; then
            ENGINE_RECOVERY_REQUIRED="1"
            log "❌ CRITICAL: automatic engine rollback failed during cleanup; manual recovery required"
            if ! stop_podkop_and_verify; then
                service podkop stop >/dev/null 2>&1 || :
                log "❌ CRITICAL: Podkop could not be confirmed stopped after rollback failure"
            else
                log "⚠️  Podkop is stopped after rollback failure; manual recovery required"
            fi
        else
            ENGINE_RECOVERY_REQUIRED="0"
            ENGINE_SWITCH_ACTIVE="0"
        fi
    fi
    rm -f "$TMP_PRIORITY" "$TMP_POOL" "$TMP_FINAL" "$TMP_WRITTEN" "$TMP_CURRENT" \
        "${TMP_POOL}.rnd" "${TMP_PRIORITY}.u" "${TMP_POOL}.u" "${TMP_WRITTEN}.u" "${TMP_CURRENT}.u" "$LOCK_FILE"
    if [ -n "$TMP_ENGINE_DIR" ] && [ "$ENGINE_RECOVERY_REQUIRED" = "1" ]; then
        log "❌ CRITICAL: temporary recovery artifacts retained at $TMP_ENGINE_DIR"
    elif [ -n "$TMP_ENGINE_DIR" ]; then
        rm -rf "$TMP_ENGINE_DIR"
    fi
    if [ "${ENGINE_RECOVERY_CREATED:-0}" = "1" ]; then
        if [ "$ENGINE_RECOVERY_REQUIRED" = "1" ]; then
            log "❌ CRITICAL: persistent rollback package and manifest retained at $ENGINE_RECOVERY_DIR"
        elif ! rm -rf "$ENGINE_RECOVERY_DIR"; then
            log "❌ CRITICAL: unable to remove unused persistent rollback artifacts at $ENGINE_RECOVERY_DIR"
        fi
    fi
    [ -z "$UNOWNED_BACKUP_STAGING" ] || rm -rf "$UNOWNED_BACKUP_STAGING"
}
trap 'cleanup_update' EXIT
trap 'exit 143' INT TERM

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
    echo "  1. Happ/3.25.1"
    echo "  2. v2rayNG/1.8.5"
    echo "  3. INCY/3.3.0"

    while :; do
        printf 'Выберите агент (1-3): '
        IFS= read -r value || exit 1
        case "$value" in
            1|Happ/3.25.1|happ|Happ)
                PROMPT_VALUE="Happ/3.25.1"
                return 0
                ;;
            2|v2rayNG/1.8.5|v2rayNG|v2rayng)
                PROMPT_VALUE="v2rayNG/1.8.5"
                return 0
                ;;
            3|INCY/3.3.0|incy|INCY)
                PROMPT_VALUE="INCY/3.3.0"
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

ensure_jq_installed() {
    command -v jq >/dev/null 2>&1 && return 0
    detect_package_manager || return 1
    ensure_package_indexes_updated || return 1

    log "📦 Установка jq (нужен для разбора JSON-подписки)..."
    case "$PKG_MANAGER" in
        apk) apk add jq >/dev/null 2>&1 ;;
        opkg) opkg install jq >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac

    command -v jq >/dev/null 2>&1
}

# Скачивает файл по URL в указанный путь; пробует wget, затем curl
download_file() {
    local url="$1" dest="$2"
    if wget --no-check-certificate -qO "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSLk -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ] && return 0
    fi
    return 1
}

run_official_podkop_installer() {
    action_label="$1"
    [ -n "$PODKOP_INSTALL_SCRIPT_URL" ] || return 1

    tmp_installer="$(mktemp /tmp/podkop-install.XXXXXX)" || return 1

    if download_file "$PODKOP_INSTALL_SCRIPT_URL" "$tmp_installer"; then
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

# Podkop restart runs asynchronously; an init.d status can report success
# before sing-box has bound its ports. Check the actual process and sockets.
wait_for_engine_health() {
    engine_attempt=0
    while [ "$engine_attempt" -lt 30 ]; do
        if podkop check_sing_box | jq -e '.sing_box_process_running == 1 and .sing_box_ports_listening == 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        engine_attempt=$((engine_attempt + 1))
    done
    return 1
}

# Verify the unowned-binary backup still leaves its 12 MiB persistent reserve.
unowned_backup_overlay_space_ready() {
    backup_mounts_file=${1:-/proc/mounts}
    backup_overlay_path=${2:-/overlay}
    backup_overlay_mountpoint=$(persistent_overlay_mountpoint "$backup_overlay_path" "$backup_mounts_file") || return 1
    backup_overlay_df=$(df -Pk "$backup_overlay_path" 2>/dev/null) || return 1
    backup_free_kb=$(printf '%s\n' "$backup_overlay_df" | awk -v path="$backup_overlay_mountpoint" '
        NR == 1 { next }
        $NF == path {
            rows++
            if (NF < 6 || $4 !~ /^[0-9]+$/) invalid = 1
            else available = $4
        }
        END {
            if (rows == 1 && !invalid) print available
        }
    ') || return 1
    case "$backup_free_kb" in ''|*[!0-9]*) return 1 ;; esac
    case "$backup_free_kb" in 0*) [ "$backup_free_kb" = "0" ] || return 1 ;; esac
    # Values with 7+ digits exceed 999,999 KiB, so avoid shell arithmetic.
    [ "${#backup_free_kb}" -le 6 ] || return 0
    [ "$backup_free_kb" -ge 12000 ]
}

# An unowned binary has no opkg package to reinstall. Keep a persistent,
# private copy across reboot before allowing a package to claim its paths.
backup_unowned_sing_box() {
    if [ -e "$UNOWNED_BACKUP_DIR" ]; then
        log "❌ sing-box: existing unowned backup needs manual review; unchanged"
        return 1
    fi
    umask 077
    UNOWNED_BACKUP_STAGING=$(mktemp -d /etc/podkop-update-sing-box-backup.XXXXXX) || return 1
    source_hash=$(sha256sum /usr/bin/sing-box 2>/dev/null) || {
        log "❌ sing-box: cannot hash original binary; unchanged"
        return 1
    }
    source_hash=${source_hash%% *}
    if [ "${#source_hash}" -ne 64 ] || printf '%s' "$source_hash" | grep -q '[^0-9a-f]'; then
        log "❌ sing-box: invalid original binary hash; unchanged"
        return 1
    fi
    if ! gzip -c /usr/bin/sing-box > "$UNOWNED_BACKUP_STAGING/sing-box.gz"; then
        log "❌ sing-box: unable to back up unowned binary; unchanged"
        return 1
    fi
    backup_hash=$(gzip -dc "$UNOWNED_BACKUP_STAGING/sing-box.gz" | sha256sum | cut -d ' ' -f1)
    if ! gzip -t "$UNOWNED_BACKUP_STAGING/sing-box.gz" 2>/dev/null ||
        [ "$backup_hash" != "$source_hash" ]; then
        log "❌ sing-box: original binary backup failed verification; unchanged"
        return 1
    fi
    printf '%s\n' "$source_hash" > "$UNOWNED_BACKUP_STAGING/sha256"
    [ ! -f /etc/init.d/sing-box ] || cp -p /etc/init.d/sing-box "$UNOWNED_BACKUP_STAGING/sing-box.init" || return 1
    [ ! -f /etc/config/sing-box ] || cp -p /etc/config/sing-box "$UNOWNED_BACKUP_STAGING/sing-box.uci" || return 1
    [ ! -f /etc/sing-box/config.json ] || cp -p /etc/sing-box/config.json "$UNOWNED_BACKUP_STAGING/config.json" || return 1
    if ! unowned_backup_overlay_space_ready; then
        log "❌ sing-box: insufficient or ambiguous /overlay space after persistent backup; unchanged"
        return 1
    fi
    if ! mv "$UNOWNED_BACKUP_STAGING" "$UNOWNED_BACKUP_DIR"; then
        log "❌ sing-box: cannot finalize persistent backup; unchanged"
        return 1
    fi
    UNOWNED_BACKUP_STAGING=""
    log "🔒 Original unowned sing-box saved to $UNOWNED_BACKUP_DIR"
    return 0
}

restore_unowned_sing_box() {
    unowned_binary_path=${1:-/usr/bin/sing-box}
    unowned_backup_dir=${2:-$UNOWNED_BACKUP_DIR}
    unowned_init_path=${3:-/etc/init.d/sing-box}
    unowned_uci_path=${4:-/etc/config/sing-box}
    unowned_config_path=${5:-/etc/sing-box/config.json}
    stop_podkop_and_verify || {
        log "❌ CRITICAL: cannot confirm Podkop is stopped before restoring unowned sing-box"
        return 1
    }
    installed_now=$(opkg list-installed 2>/dev/null) || {
        log "❌ CRITICAL: cannot read opkg database during rollback"
        return 1
    }
    if printf '%s\n' "$installed_now" | grep -q '^podkop-engine - '; then
        remove_rc=0
        opkg remove --force-depends podkop-engine >/dev/null 2>&1 || remove_rc=$?
        installed_now=$(opkg list-installed 2>/dev/null) || {
            log "❌ CRITICAL: cannot re-read opkg database after rollback removal"
            return 1
        }
        if printf '%s\n' "$installed_now" | grep -q '^podkop-engine - '; then
            log "❌ CRITICAL: podkop-engine removal failed (exit $remove_rc)"
            return 1
        fi
        [ "$remove_rc" -eq 0 ] || log "⚠️  opkg remove returned $remove_rc, but package is absent from installed database"
    fi
    if [ ! -f "$unowned_backup_dir/sing-box.gz" ] || [ ! -f "$unowned_backup_dir/sha256" ]; then
        log "❌ CRITICAL: unowned binary backup missing"
        return 1
    fi
    expected_old_hash=$(cat "$unowned_backup_dir/sha256")
    # Verify the compressed backup before touching the executable. Streaming
    # avoids filling OpenWrt's small /tmp during an emergency rollback.
    actual_old_hash=$(gzip -dc "$unowned_backup_dir/sing-box.gz" | sha256sum | cut -d ' ' -f1)
    if ! gzip -t "$unowned_backup_dir/sing-box.gz" 2>/dev/null ||
        [ "$expected_old_hash" != "$actual_old_hash" ]; then
        log "❌ CRITICAL: original binary backup failed checksum verification"
        return 1
    fi
    current_old_hash=$(sha256sum "$unowned_binary_path" 2>/dev/null | cut -d ' ' -f1)
    if [ "$current_old_hash" != "$expected_old_hash" ]; then
        if ! gzip -dc "$unowned_backup_dir/sing-box.gz" > "$unowned_binary_path" ||
            ! chmod 755 "$unowned_binary_path" ||
            [ "$(sha256sum "$unowned_binary_path" | cut -d ' ' -f1)" != "$expected_old_hash" ]; then
            log "❌ CRITICAL: cannot restore original binary"
            return 1
        fi
    fi
    [ ! -f "$unowned_backup_dir/sing-box.init" ] || cp -p "$unowned_backup_dir/sing-box.init" "$unowned_init_path" || return 1
    [ ! -f "$unowned_backup_dir/sing-box.uci" ] || cp -p "$unowned_backup_dir/sing-box.uci" "$unowned_uci_path" || return 1
    [ ! -f "$unowned_backup_dir/config.json" ] || cp -p "$unowned_backup_dir/config.json" "$unowned_config_path" || return 1
    if [ "$(sha256sum "$unowned_binary_path" 2>/dev/null | cut -d ' ' -f1)" != "$expected_old_hash" ]; then
        log "❌ CRITICAL: restored unowned binary hash does not match the verified backup"
        return 1
    fi
    if start_podkop_and_check "$unowned_binary_path" "$unowned_config_path"; then
        log "⚠️  Original unowned sing-box restored and running"
        return 0
    fi
    log "❌ CRITICAL: original unowned binary restored but config/start/health check failed"
    stop_podkop_and_verify || log "❌ CRITICAL: Podkop could not be confirmed stopped after unowned rollback failure"
    return 1
}

start_podkop_and_check() {
    sing_box_executable=${1:-sing-box}
    sing_box_config=${2:-/etc/sing-box/config.json}
    "$sing_box_executable" check -c "$sing_box_config" >/dev/null 2>&1 || return 1
    start_rc=0
    service podkop start >/dev/null 2>&1 || start_rc=$?
    [ "$start_rc" -eq 0 ] || return 1
    wait_for_engine_health
}

restart_podkop_and_check() {
    restart_rc=0
    service podkop restart >/dev/null 2>&1 || restart_rc=$?
    [ "$restart_rc" -eq 0 ] || return 1
    wait_for_engine_health && sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1
}

stop_podkop_and_verify() {
    stop_command_rc=0
    service podkop stop >/dev/null 2>&1 || stop_command_rc=$?
    engine_stop_attempt=0
    while [ "$engine_stop_attempt" -lt 30 ]; do
        if podkop check_sing_box 2>/dev/null | jq -e '.sing_box_process_running == 0 and .sing_box_ports_listening == 0' >/dev/null 2>&1; then
            [ "$stop_command_rc" -eq 0 ] || log "⚠️  Podkop stop returned $stop_command_rc, but process and ports are confirmed stopped"
            return 0
        fi
        sleep 1
        engine_stop_attempt=$((engine_stop_attempt + 1))
    done
    log "❌ CRITICAL: Podkop process or ports remain active after stop request (exit $stop_command_rc)"
    return 1
}

restore_podkop_engine() {
    stop_podkop_and_verify || {
        log "❌ CRITICAL: cannot confirm Podkop is stopped before engine rollback"
        return 1
    }
    rollback_package=${ENGINE_RECOVERY_PACKAGE:-$TMP_ENGINE_DIR/rollback.ipk}
    if [ ! -f "$rollback_package" ] || [ -z "$ENGINE_PREVIOUS_VERSION" ]; then
        log "❌ CRITICAL: verified podkop-engine rollback package missing"
        return 1
    fi
    installed_now=$(opkg list-installed 2>/dev/null) || {
        log "❌ CRITICAL: cannot read opkg database during engine rollback"
        return 1
    }
    if printf '%s\n' "$installed_now" | grep -q '^podkop-engine - '; then
        installed_status=$(opkg status podkop-engine 2>/dev/null) || {
            log "❌ CRITICAL: cannot read installed podkop-engine status during rollback"
            return 1
        }
        installed_engine_version=$(printf '%s\n' "$installed_status" | sed -n 's/^Version: //p' | sed -n '1p')
        if [ -z "$installed_engine_version" ]; then
            log "❌ CRITICAL: installed podkop-engine version is unknown; refusing rollback transaction"
            return 1
        fi
        if [ "$installed_engine_version" = "$ENGINE_PREVIOUS_VERSION" ]; then
            # Exact rollback IPK and install-contract parity were verified before switching.
            if ! opkg --force-reinstall install "$rollback_package" >/dev/null 2>&1; then
                log "❌ CRITICAL: verified podkop-engine reinstall transaction failed"
                service podkop stop >/dev/null 2>&1
                return 1
            fi
        else
            # Keep the package installed so opkg can validate and apply one downgrade transaction.
            if ! opkg --force-downgrade install "$rollback_package" >/dev/null 2>&1; then
                log "❌ CRITICAL: verified podkop-engine downgrade transaction failed"
                service podkop stop >/dev/null 2>&1
                return 1
            fi
        fi
    else
        if ! opkg install "$rollback_package" >/dev/null 2>&1; then
            log "❌ CRITICAL: verified podkop-engine rollback package install failed"
            service podkop stop >/dev/null 2>&1
            return 1
        fi
    fi
    restored_status=$(opkg status podkop-engine 2>/dev/null) || {
        log "❌ CRITICAL: cannot read restored podkop-engine status"
        service podkop stop >/dev/null 2>&1
        return 1
    }
    restored_package_version=$(printf '%s\n' "$restored_status" | sed -n 's/^Version: //p' | sed -n '1p')
    expected_binary=$(engine_binary_version_for_package "$ENGINE_PREVIOUS_VERSION") || expected_binary=""
    restored_binary_version=$(sing-box version 2>/dev/null | sed -n '1p')
    if [ "$restored_package_version" = "$ENGINE_PREVIOUS_VERSION" ] &&
        [ -n "$expected_binary" ] &&
        [ "$restored_binary_version" = "sing-box version $expected_binary" ] &&
        restart_podkop_and_check; then
        log "⚠️  Previous podkop-engine $ENGINE_PREVIOUS_VERSION restored and running"
        return 0
    fi
    log "❌ CRITICAL: previous podkop-engine restored incompletely; stopping Podkop"
    service podkop stop >/dev/null 2>&1
    return 1
}

restore_previous_sing_box() {
    case "$ENGINE_ORIGIN" in
        stock) restore_stock_sing_box && return 0 ;;
        unowned) restore_unowned_sing_box && return 0 ;;
        podkop-engine) restore_podkop_engine && return 0 ;;
        *) log "❌ CRITICAL: unknown original sing-box package" ;;
    esac
    service podkop stop >/dev/null 2>&1
    log "⚠️  Podkop stopped to restore ordinary DNS; manual recovery required"
    return 1
}

rollback_engine_once() {
    trap '' INT TERM
    rollback_rc=0
    restore_previous_sing_box || rollback_rc=$?
    if [ "$rollback_rc" -eq 0 ]; then
        ENGINE_SWITCH_ACTIVE="0"
        ENGINE_RECOVERY_REQUIRED="0"
    else
        ENGINE_RECOVERY_REQUIRED="1"
        log "❌ CRITICAL: automatic engine rollback failed; preserving recovery state for exit cleanup"
        if ! stop_podkop_and_verify; then
            service podkop stop >/dev/null 2>&1 || :
            log "❌ CRITICAL: Podkop could not be confirmed stopped after rollback failure"
        fi
    fi
    trap 'exit 143' INT TERM
    return "$rollback_rc"
}

remove_stock_sing_box_packages() {
    remove_rc=0
    opkg remove --force-depends sing-box sing-box-tiny >/dev/null 2>&1 || remove_rc=$?
    installed_now=$(opkg list-installed 2>/dev/null) || {
        log "❌ sing-box: cannot verify stock package removal"
        return 1
    }
    remaining_stock_packages=$(printf '%s\n' "$installed_now" | awk '
        $1 == "sing-box" || $1 == "sing-box-tiny" { print $1 }
    ')
    if [ -n "$remaining_stock_packages" ]; then
        log "❌ sing-box: stock packages remain after removal: $remaining_stock_packages"
        return 1
    fi
    [ "$remove_rc" -eq 0 ] || log "⚠️  sing-box: opkg remove returned $remove_rc, but both stock packages are absent"
    return 0
}

install_candidate_engine() {
    log "📦 sing-box: replacing $ENGINE_ORIGIN binary with tested $TESTED_ENGINE_VERSION"
    ENGINE_SWITCH_ACTIVE="1"
    if ! stop_podkop_and_verify; then
        ENGINE_SWITCH_ACTIVE="0"
        log "❌ sing-box: cannot confirm Podkop is stopped; package unchanged"
        return 1
    fi
    if [ "$ENGINE_ORIGIN" = "stock" ] && ! remove_stock_sing_box_packages; then
        log "❌ sing-box: stock package removal failed; restoring original"
        rollback_engine_once
        return 1
    fi
    if ! opkg install "$TMP_ENGINE_DIR/new.ipk" >/dev/null 2>&1; then
        log "❌ sing-box: install failed; restoring original"
        rollback_engine_once
        return 1
    fi
    installed_status=$(opkg status podkop-engine 2>/dev/null) || {
        log "❌ sing-box: cannot read installed candidate package status; restoring original"
        rollback_engine_once
        return 1
    }
    installed_engine_version=$(printf '%s\n' "$installed_status" | sed -n 's/^Version: //p' | sed -n '1p')
    expected_binary=$(engine_binary_version_for_package "$TESTED_ENGINE_VERSION") || expected_binary=""
    installed_binary_version=$(sing-box version 2>/dev/null | sed -n '1p')
    if [ "$installed_engine_version" != "$TESTED_ENGINE_VERSION" ] ||
        [ -z "$expected_binary" ] ||
        [ "$installed_binary_version" != "sing-box version $expected_binary" ] ||
        ! restart_podkop_and_check; then
        log "❌ sing-box: post-install package/binary/health check failed; restoring original"
        rollback_engine_once
        return 1
    fi
    ENGINE_SWITCH_ACTIVE="0"
    log "✅ sing-box: $TESTED_ENGINE_VERSION installed; Podkop running"
    return 0
}

# Restore the pre-downloaded stock package after a failed engine switch.
restore_stock_sing_box() {
    stop_podkop_and_verify || {
        log "❌ CRITICAL: cannot confirm Podkop is stopped before stock sing-box rollback"
        return 1
    }
    if [ -z "$STOCK_ROLLBACK_PACKAGE" ] || [ ! -f "$STOCK_ROLLBACK_PACKAGE" ] ||
        [ -z "$STOCK_PREVIOUS_VERSION" ] || [ -z "$STOCK_ROLLBACK_BINARY_VERSION" ] ||
        [ "${#STOCK_ROLLBACK_BINARY_SHA256}" -ne 64 ]; then
        log "❌ CRITICAL: verified stock sing-box rollback package/state is missing"
        return 1
    fi
    case "$STOCK_ROLLBACK_BINARY_SHA256" in *[!0-9a-f]*)
        log "❌ CRITICAL: verified stock sing-box rollback binary hash is malformed"
        return 1 ;;
    esac
    installed_now=$(opkg list-installed 2>/dev/null) || {
        log "❌ CRITICAL: cannot read opkg database during stock rollback"
        return 1
    }
    if printf '%s\n' "$installed_now" | grep -q '^podkop-engine - '; then
        remove_rc=0
        opkg remove --force-depends podkop-engine >/dev/null 2>&1 || remove_rc=$?
        installed_now=$(opkg list-installed 2>/dev/null) || {
            log "❌ CRITICAL: cannot re-read opkg database after stock rollback removal"
            return 1
        }
        if printf '%s\n' "$installed_now" | grep -q '^podkop-engine - '; then
            log "❌ CRITICAL: podkop-engine removal failed (exit $remove_rc)"
            return 1
        fi
        [ "$remove_rc" -eq 0 ] || log "⚠️  opkg remove returned $remove_rc, but podkop-engine is absent"
    fi
    stock_payload_matches=0
    stock_expected_binary_hash="$STOCK_ROLLBACK_BINARY_SHA256"
    if printf '%s\n' "$installed_now" | grep -q '^sing-box - '; then
        preexisting_stock_status=$(opkg status sing-box 2>/dev/null || :)
        preexisting_stock_version=$(printf '%s\n' "$preexisting_stock_status" | awk '
            /^Package: / { packages++; package_name = $2 }
            /^Version: / { versions++; package_version = $2 }
            /^Status: / { statuses++; if ($NF == "installed") installed = 1 }
            END {
                if (packages == 1 && package_name == "sing-box" && versions == 1 &&
                    statuses == 1 && installed && package_version != "") print package_version
            }
        ')
        preexisting_stock_binary=$(sing-box version 2>/dev/null | sed -n '1p')
        preexisting_stock_binary_hash=$(sha256sum "$STOCK_BINARY_PATH" 2>/dev/null | awk 'NR == 1 {print $1}')
        if [ "$preexisting_stock_version" = "$STOCK_PREVIOUS_VERSION" ] &&
            [ "$preexisting_stock_binary" = "$STOCK_ROLLBACK_BINARY_VERSION" ] &&
            [ "${#STOCK_PREVIOUS_BINARY_SHA256}" -eq 64 ] &&
            [ "$preexisting_stock_binary_hash" = "$STOCK_PREVIOUS_BINARY_SHA256" ]; then
            stock_payload_matches=1
            stock_expected_binary_hash="$STOCK_PREVIOUS_BINARY_SHA256"
        fi
    fi
    if [ "$stock_payload_matches" != 1 ]; then
        if printf '%s\n' "$installed_now" | grep -q '^sing-box - '; then
            if ! opkg --force-downgrade --force-reinstall install "$STOCK_ROLLBACK_PACKAGE" >/dev/null 2>&1; then
                log "❌ CRITICAL: exact stock sing-box reinstall/downgrade failed"
                return 1
            fi
        elif ! opkg install "$STOCK_ROLLBACK_PACKAGE" >/dev/null 2>&1; then
            log "❌ CRITICAL: exact stock sing-box package install failed"
            return 1
        fi
    fi
    restored_status=$(opkg status sing-box 2>/dev/null) || {
        log "❌ CRITICAL: cannot read restored stock sing-box status"
        return 1
    }
    restored_package_fields=$(printf '%s\n' "$restored_status" | awk '
        /^Package: / { packages++; package_name = $2 }
        /^Version: / { versions++; package_version = $2 }
        /^Status: / { statuses++; if ($NF == "installed") installed = 1 }
        END {
            if (!installed || packages != 1 || versions != 1 || statuses != 1) exit 1
            printf "%s\t%s", package_name, package_version
        }
    ') || {
        log "❌ CRITICAL: restored stock sing-box package status is malformed"
        return 1
    }
    restored_package_name=$(printf '%s\n' "$restored_package_fields" | cut -f1)
    restored_package_version=$(printf '%s\n' "$restored_package_fields" | cut -f2)
    restored_binary_version=$(sing-box version 2>/dev/null | sed -n '1p')
    restored_binary_hash=$(sha256sum "$STOCK_BINARY_PATH" 2>/dev/null | awk 'NR == 1 {print $1}')
    if [ "$restored_package_name" = 'sing-box' ] &&
        [ "$restored_package_version" = "$STOCK_PREVIOUS_VERSION" ] &&
        [ "$restored_binary_version" = "$STOCK_ROLLBACK_BINARY_VERSION" ] &&
        [ "$restored_binary_hash" = "$stock_expected_binary_hash" ] &&
        start_podkop_and_check; then
        log "⚠️  Stock sing-box $STOCK_PREVIOUS_VERSION restored and running"
        return 0
    fi
    log "❌ CRITICAL: stock package/version/binary/config/health verification failed"
    stop_podkop_and_verify || log "❌ CRITICAL: Podkop could not be confirmed stopped after stock rollback failure"
    return 1
}

# Only the tested, pinned podkop-engine build fixes the REALITY regression.
# Stock 'sing-box' may be numerically newer but still lack that patch.
detect_opkg_engine_arch() {
    opkg print-architecture | awk '
        $1 == "arch" {
            arch = $2
            priority = $3
        }
        $1 != "arch" {
            arch = $1
            priority = $2
        }
        priority ~ /^[0-9]+$/ && arch != "all" && arch != "noarch" &&
            priority + 0 > best_priority {
            selected = arch
            best_priority = priority + 0
        }
        END { if (selected != "") print selected }
    '
}

engine_tmp_space_ready() {
    asset_size_bytes=$1
    reserve_kb=${2:-35000}
    [ -n "$asset_size_bytes" ] && [ -n "$reserve_kb" ] || return 1
    case "$asset_size_bytes" in ''|0*|*[!0-9]*) return 1 ;; esac
    case "$reserve_kb" in
        ''|*[!0-9]*) return 1 ;;
        0*) [ "$reserve_kb" = "0" ] || return 1 ;;
    esac
    # Keep decimal arithmetic inside 32-bit BusyBox ash's signed range:
    # package bytes <= 999,999,999 and reserve KB <= 999,999.
    [ "${#asset_size_bytes}" -le 9 ] && [ "${#reserve_kb}" -le 6 ] || return 1
    tmp_df_output=$(df -Pk /tmp 2>/dev/null) || return 1
    tmp_free_kb=$(printf '%s\n' "$tmp_df_output" | awk '
        NR == 1 { next }
        $NF == "/tmp" {
            rows++
            if (NF < 6 || $4 !~ /^[0-9]+$/) invalid = 1
            else available = $4
        }
        END {
            if (rows == 1 && !invalid) print available
        }
    ') || return 1
    case "$tmp_free_kb" in ''|*[!0-9]*) return 1 ;; esac
    case "$tmp_free_kb" in 0*) [ "$tmp_free_kb" = "0" ] || return 1 ;; esac
    [ "${#tmp_free_kb}" -le 9 ] || return 0
    required_tmp_kb=$(((asset_size_bytes + 1023) / 1024 + reserve_kb))
    [ "$tmp_free_kb" -ge "$required_tmp_kb" ]
}

release_asset_details() {
    release_json=$1
    asset_name=$2
    jq -e '.assets | type == "array"' "$release_json" >/dev/null 2>&1 || return 1
    asset_count=$(jq --arg name "$asset_name" '[.assets[] | select(.name == $name)] | length' "$release_json" 2>/dev/null) || return 1
    [ "$asset_count" = "1" ] || return 1
    jq -er --arg name "$asset_name" '
        .assets[] | select(.name == $name) |
        select((.url | type) == "string" and (.digest | type) == "string" and
            (.size | type) == "number" and .size > 0 and (.size | floor) == .size) |
        [.url, .digest, (.size | tostring)] | @tsv
    ' "$release_json" 2>/dev/null
}

engine_release_asset_url() {
    release_json=$1
    asset_name=$2
    [ -f "$release_json" ] && [ ! -L "$release_json" ] || return 1
    case "$asset_name" in ''|*[!a-zA-Z0-9._+-]*) return 1 ;; esac
    command -v jsonfilter >/dev/null 2>&1 || return 1
    engine_url=$(jsonfilter -e "@.assets[@.name='$asset_name'].url" < "$release_json" 2>/dev/null) || return 1
    asset_url_count=$(printf '%s\n' "$engine_url" | awk 'NF { count++ } END { print count + 0 }')
    [ "$asset_url_count" = 1 ] || return 1
    asset_api_prefix='https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/'
    case "$engine_url" in "$asset_api_prefix"*) ;; *) return 1 ;; esac
    asset_id=${engine_url#"$asset_api_prefix"}
    case "$asset_id" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$engine_url"
}

opkg_info_package_size() {
    package_name=$1
    expected_version=$2
    package_info=$(opkg info "$package_name" 2>/dev/null) || return 1
    printf '%s\n' "$package_info" | awk -v wanted_package="$package_name" -v wanted_version="$expected_version" '
        function finish_package() {
            if (current_package == wanted_package && current_version == wanted_version) {
                matches++
                if (version_fields != 1 || size_fields != 1 || size !~ /^[0-9]+$/ || size + 0 <= 0) invalid = 1
                else selected_size = size
            }
        }
        /^Package: / {
            finish_package()
            current_package = $2
            current_version = ""
            version_fields = 0
            size_fields = 0
            size = ""
            next
        }
        /^Version: / { current_version = $2; version_fields++; next }
        /^Size: / { size = $2; size_fields++; next }
        END {
            finish_package()
            if (invalid || matches != 1) exit 1
            print selected_size
        }
    '
}

opkg_status_database_ready() {
    status_file=${1:-/usr/lib/opkg/status}
    [ -s "$status_file" ] || return 1
    awk '
        function finish_stanza() {
            if (have_package && (!have_version || !have_status)) invalid = 1
        }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]/ { next }
        /^Package: / {
            finish_stanza()
            package_name = $2
            if (package_name == "" || seen[package_name]++) invalid = 1
            have_package = 1
            have_version = 0
            have_status = 0
            package_count++
            next
        }
        /^Version: / { if (!have_package || have_version++ || $2 == "") invalid = 1; next }
        /^Status: / { if (!have_package || have_status++ || NF < 2) invalid = 1; next }
        { if (index($0, ":") < 2) invalid = 1 }
        END {
            finish_stanza()
            if (invalid || package_count == 0 || seen["base-files"] != 1) exit 1
        }
    ' "$status_file" || return 1
    base_files_status=$(opkg status base-files 2>/dev/null) || return 1
    printf '%s\n' "$base_files_status" | awk '
        /^Package: / { packages++; if ($2 != "base-files") invalid = 1 }
        /^Version: / { versions++; if ($2 == "") invalid = 1 }
        /^Status: / { statuses++; if ($NF != "installed") invalid = 1 }
        END { if (invalid || packages != 1 || versions != 1 || statuses != 1) exit 1 }
    ' || return 1
    installed_list=$(opkg list-installed 2>/dev/null) || return 1
    printf '%s\n' "$installed_list" | awk '
        $2 == "-" && $3 != "" {
            if (seen[$1]++) invalid = 1
            if ($1 == "base-files") base_count++
            package_count++
        }
        END { if (invalid || package_count == 0 || base_count != 1) exit 1 }
    '
}

engine_binary_version_for_package() {
    package_version=$1
    case "$package_version" in
        *-r*) ;;
        *) return 1 ;;
    esac
    package_revision=${package_version##*-r}
    case "$package_revision" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s-pdk-r%s' "${package_version%-r*}" "$package_revision"
}

engine_ipk_control_valid() {
    package_file=$1
    package_control=$(tar xOzf "$package_file" ./control.tar.gz 2>/dev/null | tar xOzf - ./control 2>/dev/null) || return 1
    printf '%s\n' "$package_control" | awk '
        BEGIN { invalid = 0; previous_field = 0; have_field = 0 }
        /^[[:space:]]*$/ { previous_field = 0; next }
        /^[[:space:]]/ {
            if (!previous_field) { invalid = 1; exit }
            next
        }
        {
            colon = index($0, ":")
            if (index($0, "\r") || colon < 2) {
                invalid = 1
                exit
            }
            field = substr($0, 1, colon - 1)
            if (field !~ /^[A-Za-z0-9][A-Za-z0-9-]*$/ || seen[field]++) {
                invalid = 1
                exit
            }
            previous_field = 1
            have_field = 1
        }
        END { if (invalid || !have_field) exit 1 }
    '
}

engine_ipk_control_field() {
    package_file=$1
    field_name=$2
    package_control=$(tar xOzf "$package_file" ./control.tar.gz 2>/dev/null | tar xOzf - ./control 2>/dev/null) || return 1
    printf '%s\n' "$package_control" | awk -v key="$field_name" '
        {
            if (substr($0, 1, length(key) + 1) == key ":") {
                found = 1
                value = substr($0, length(key) + 2)
                sub(/^[[:space:]]+/, "", value)
                next
            }
            if (found && /^[[:space:]]/) {
                sub(/^[[:space:]]+/, " ")
                value = value $0
                next
            }
            if (found) {
                print value
                printed = 1
                exit
            }
        }
        END { if (found && !printed) print value }
    '
}

engine_ipk_install_contracts_match() {
    candidate_package=$1
    rollback_package=$2
    engine_ipk_control_valid "$candidate_package" || return 1
    engine_ipk_control_valid "$rollback_package" || return 1
    for field_name in Depends Pre-Depends Conflicts Breaks Replaces Provides; do
        candidate_value=$(engine_ipk_control_field "$candidate_package" "$field_name") || return 1
        rollback_value=$(engine_ipk_control_field "$rollback_package" "$field_name") || return 1
        [ "$candidate_value" = "$rollback_value" ] || return 1
    done
}

verify_engine_ipk() {
    package_file=$1
    expected_package_version=$2
    binary_output=$3
    expected_arch=$4
    expected_binary=$(engine_binary_version_for_package "$expected_package_version") || return 1
    engine_ipk_control_valid "$package_file" || return 1
    package_control=$(tar xOzf "$package_file" ./control.tar.gz 2>/dev/null | tar xOzf - ./control 2>/dev/null) || return 1
    actual_package_name=$(printf '%s\n' "$package_control" | sed -n 's/^Package: //p' | sed -n '1p')
    actual_package_version=$(printf '%s\n' "$package_control" | sed -n 's/^Version: //p' | sed -n '1p')
    actual_package_arch=$(printf '%s\n' "$package_control" | sed -n 's/^Architecture: //p' | sed -n '1p')
    [ "$actual_package_name" = 'podkop-engine' ] || return 1
    [ "$actual_package_version" = "$expected_package_version" ] || return 1
    [ "$actual_package_arch" = "$expected_arch" ] || return 1
    # Candidate and rollback packages must expose the core install contract; a
    # missing field cannot be treated as proof that the packages are compatible.
    for required_field in Depends Conflicts Provides; do
        required_value=$(engine_ipk_control_field "$package_file" "$required_field") || return 1
        [ -n "$required_value" ] || return 1
    done
    if ! (tar xOzf "$package_file" ./data.tar.gz | tar xOzf - ./usr/bin/sing-box > "$binary_output"); then
        rm -f "$binary_output"
        return 1
    fi
    chmod 700 "$binary_output" || { rm -f "$binary_output"; return 1; }
    if ! "$binary_output" version | grep -q "^sing-box version $expected_binary$"; then
        rm -f "$binary_output"
        return 1
    fi
}

verify_stock_sing_box_ipk() {
    package_file=$1
    expected_package_version=$2
    binary_output=$3
    expected_arch=$4
    engine_ipk_control_valid "$package_file" || return 1
    package_control=$(tar xOzf "$package_file" ./control.tar.gz 2>/dev/null | tar xOzf - ./control 2>/dev/null) || return 1
    actual_package_name=$(printf '%s\n' "$package_control" | sed -n 's/^Package: //p' | sed -n '1p')
    actual_package_version=$(printf '%s\n' "$package_control" | sed -n 's/^Version: //p' | sed -n '1p')
    actual_package_arch=$(printf '%s\n' "$package_control" | sed -n 's/^Architecture: //p' | sed -n '1p')
    [ "$actual_package_name" = 'sing-box' ] || return 1
    [ "$actual_package_version" = "$expected_package_version" ] || return 1
    [ "$actual_package_arch" = "$expected_arch" ] || return 1
    if ! (tar xOzf "$package_file" ./data.tar.gz | tar xOzf - ./usr/bin/sing-box > "$binary_output"); then
        rm -f "$binary_output"
        return 1
    fi
    chmod 700 "$binary_output" || { rm -f "$binary_output"; return 1; }
    stock_version_output=$("$binary_output" version 2>/dev/null) || { rm -f "$binary_output"; return 1; }
    stock_binary_version=$(printf '%s\n' "$stock_version_output" | sed -n '1p')
    case "$stock_binary_version" in
        'sing-box version '*) [ -n "${stock_binary_version#sing-box version }" ] || { rm -f "$binary_output"; return 1; } ;;
        *) rm -f "$binary_output"; return 1 ;;
    esac
    printf '%s\n' "$stock_binary_version"
}

download_engine_rollback_package() {
    rollback_version=$1
    case "$rollback_version" in
        ''|*[!a-zA-Z0-9.+_-]*)
            log "❌ sing-box: invalid installed engine version for rollback"
            return 1 ;;
    esac
    rollback_asset="podkop-engine_${rollback_version}_openwrt_${engine_arch}.ipk"
    rollback_release="https://api.github.com/repos/podkop-net/podkop-engine/releases/tags/v${rollback_version}"
    rollback_metadata="$TMP_ENGINE_DIR/rollback-release.json"
    rollback_package="$TMP_ENGINE_DIR/rollback.ipk"
    if ! curl -fsSL --connect-timeout 10 --max-time 40 -o "$rollback_metadata" "$rollback_release" 2>/dev/null; then
        log "❌ sing-box: exact rollback release $rollback_version unavailable; unchanged"
        return 1
    fi
    rollback_record=$(release_asset_details "$rollback_metadata" "$rollback_asset") || {
        log "❌ sing-box: rollback asset is missing, duplicated, or malformed; unchanged"
        return 1
    }
    rollback_url=$(printf '%s\n' "$rollback_record" | cut -f1)
    rollback_digest=$(printf '%s\n' "$rollback_record" | cut -f2)
    rollback_asset_size=$(printf '%s\n' "$rollback_record" | cut -f3)
    rollback_hash=${rollback_digest#sha256:}
    case "$rollback_url:$rollback_digest" in
        https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/*:sha256:*) ;;
        *) log "❌ sing-box: no trusted rollback package/digest for $rollback_version; unchanged"; return 1 ;;
    esac
    if [ "${#rollback_hash}" -ne 64 ] || printf '%s' "$rollback_hash" | grep -q '[^0-9a-f]'; then
        log "❌ sing-box: invalid rollback SHA256 digest; unchanged"
        return 1
    fi
    if ! engine_tmp_space_ready "$rollback_asset_size" 35000; then
        log "❌ sing-box: insufficient /tmp space for rollback download plus 35 MB reserve; unchanged"
        return 1
    fi
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -H 'Accept: application/octet-stream' \
        -o "$rollback_package" "$rollback_url" 2>/dev/null; then
        log "❌ sing-box: rollback package download failed; unchanged"
        return 1
    fi
    downloaded_rollback_size=$(wc -c < "$rollback_package" | tr -d '[:space:]')
    [ "$downloaded_rollback_size" = "$rollback_asset_size" ] || { log "❌ sing-box: rollback asset size differs from release metadata; unchanged"; return 1; }
    printf '%s  %s\n' "$rollback_hash" "$rollback_package" | sha256sum -c - >/dev/null 2>&1 || {
        log "❌ sing-box: rollback package SHA256 mismatch; unchanged"
        return 1
    }
    # The downloaded package is already accounted for; require 35,000 KiB
    # remaining for inspection/extraction using the same validated df parser.
    if ! engine_tmp_space_ready 1 34999; then
        log "❌ sing-box: less than 35 MB available in /tmp for rollback preflight; unchanged"
        return 1
    fi
    if ! verify_engine_ipk "$rollback_package" "$rollback_version" "$TMP_ENGINE_DIR/rollback-sing-box" "$engine_arch"; then
        log "❌ sing-box: rollback package metadata/binary mismatch; unchanged"
        return 1
    fi
    if ! engine_ipk_install_contracts_match "$TMP_ENGINE_DIR/new.ipk" "$rollback_package"; then
        log "❌ sing-box: candidate and rollback package install contracts differ; unchanged"
        return 1
    fi
    if ! persist_engine_recovery_package "$rollback_package" "$ENGINE_RECOVERY_DIR" /overlay podkop-engine "$rollback_version"; then
        log "❌ sing-box: could not preserve exact engine rollback IPK on /overlay; unchanged"
        return 1
    fi
    rm -f "$TMP_ENGINE_DIR/rollback-sing-box"
    # The candidate's opkg preflight covers these matching install contracts; rollback is applied as one downgrade transaction.
}

engine_upgrade_action() {
    current_version=$1
    current_binary_version=$2
    expected_binary=$(engine_binary_version_for_package "$current_version") || {
        printf 'unverified'
        return 0
    }
    if [ "$current_binary_version" != "sing-box version $expected_binary" ] ||
        ! opkg compare-versions "$current_version" '>=' "$current_version"; then
        printf 'unverified'
        return 0
    fi
    if opkg compare-versions "$current_version" '>=' "$TESTED_ENGINE_VERSION"; then
        if opkg compare-versions "$TESTED_ENGINE_VERSION" '>=' "$current_version"; then
            printf 'current'
        else
            printf 'newer'
        fi
    else
        printf 'upgrade'
    fi
}

ensure_sing_box_updated() {
    [ "$AUTO_UPDATE_SING_BOX" = "1" ] || return 0
    if [ -e "$ENGINE_RECOVERY_DIR" ] || [ -L "$ENGINE_RECOVERY_DIR" ]; then
        log "❌ CRITICAL: prior engine recovery artifact exists at $ENGINE_RECOVERY_DIR; manual recovery required before another update"
        return 1
    fi
    detect_package_manager || return 1
    if [ "$PKG_MANAGER" != "opkg" ]; then
        log "⚠️  sing-box: automatic replacement tested only on opkg; unchanged"
        return 0
    fi
    if ! opkg_status_database_ready; then
        log "⚠️  sing-box: opkg status database is empty or unhealthy; unchanged"
        return 0
    fi
    if is_package_installed podkop-engine-full; then
        log "⚠️  sing-box: podkop-engine-full installed; preserving broader protocol support"
        return 0
    fi
    if is_package_installed podkop-engine; then
        current_engine_version=$(opkg status podkop-engine 2>/dev/null | sed -n 's/^Version: //p' | sed -n '1p')
        current_engine_binary_version=$(sing-box version 2>/dev/null | sed -n '1p')
        engine_action=$(engine_upgrade_action "$current_engine_version" "$current_engine_binary_version")
        case "$engine_action" in
            current)
                log "✅ sing-box: tested podkop-engine $current_engine_version already installed; unchanged"
                return 0 ;;
            newer)
                log "✅ sing-box: newer podkop-engine $current_engine_version preserved; unchanged"
                return 0 ;;
            unverified)
                log "⚠️  sing-box: podkop-engine package/binary state is unverified; manual review required"
                return 0 ;;
            upgrade)
                ENGINE_ORIGIN="podkop-engine"
                ENGINE_PREVIOUS_VERSION="$current_engine_version"
                log "ℹ️  sing-box: verified podkop-engine $current_engine_version will be upgraded to $TESTED_ENGINE_VERSION" ;;
            *)
                log "⚠️  sing-box: unknown engine upgrade decision; unchanged"
                return 0 ;;
        esac
    else
        binary_owner=$(opkg search /usr/bin/sing-box 2>/dev/null) || {
            log "❌ sing-box: ownership lookup failed; unchanged"
            return 1
        }
        init_owner=$(opkg search /etc/init.d/sing-box 2>/dev/null) || {
            log "❌ sing-box: init-script ownership lookup failed; unchanged"
            return 1
        }
        if is_package_installed sing-box; then
            ENGINE_ORIGIN="stock"
        elif [ -x /usr/bin/sing-box ] && [ -x /etc/init.d/sing-box ] &&
            [ -z "$binary_owner" ] && [ -z "$init_owner" ] &&
            ! sing-box version | grep -q -- '-pdk-r'; then
            ENGINE_ORIGIN="unowned"
            log "ℹ️  sing-box binary and init script are unowned by opkg; persistent backup required"
        else
            log "⚠️  sing-box: unknown package/owner; unchanged"
            return 0
        fi
    fi
    command -v curl >/dev/null 2>&1 || { log "❌ sing-box: curl required for verified download; unchanged"; return 1; }
    command -v wget >/dev/null 2>&1 || { log "❌ sing-box: wget required for GitHub asset download; unchanged"; return 1; }
    command -v jsonfilter >/dev/null 2>&1 || { log "❌ sing-box: jsonfilter required for GitHub asset selection; unchanged"; return 1; }
    ensure_jq_installed || { log "❌ sing-box: jq unavailable; unchanged"; return 1; }

    engine_arch=$(detect_opkg_engine_arch)
    case "$engine_arch" in
        ''|all|noarch|*[!a-zA-Z0-9_-]*)
            log "❌ sing-box: unsupported package architecture; unchanged"
            return 1 ;;
    esac
    engine_asset="podkop-engine_${TESTED_ENGINE_VERSION}_openwrt_${engine_arch}.ipk"
    engine_release="https://api.github.com/repos/podkop-net/podkop-engine/releases/tags/v${TESTED_ENGINE_VERSION}"
    TMP_ENGINE_DIR=$(mktemp -d /tmp/podkop-engine-upgrade.XXXXXX) || return 1
    chmod 700 "$TMP_ENGINE_DIR"

    if ! wget -qO "$TMP_ENGINE_DIR/release.json" "$engine_release" 2>/dev/null; then
        log "❌ sing-box: pinned release metadata unavailable; unchanged"
        return 1
    fi
    engine_record=$(release_asset_details "$TMP_ENGINE_DIR/release.json" "$engine_asset") || {
        log "❌ sing-box: release asset is missing, duplicated, or malformed; unchanged"
        return 1
    }
    metadata_engine_url=$(printf '%s\n' "$engine_record" | cut -f1)
    engine_digest=$(printf '%s\n' "$engine_record" | cut -f2)
    engine_asset_size=$(printf '%s\n' "$engine_record" | cut -f3)
    engine_url=$(engine_release_asset_url "$TMP_ENGINE_DIR/release.json" "$engine_asset") || {
        log "❌ sing-box: jsonfilter did not select exactly one trusted release asset; unchanged"
        return 1
    }
    [ "$engine_url" = "$metadata_engine_url" ] || {
        log "❌ sing-box: asset URL differs between jsonfilter and release metadata parser; unchanged"
        return 1
    }
    engine_hash=${engine_digest#sha256:}
    case "$engine_url:$engine_digest" in
        https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/*:sha256:*) ;;
        *) log "❌ sing-box: no trusted package/digest for $engine_arch; unchanged"; return 1 ;;
    esac
    if [ "${#engine_hash}" -ne 64 ] || printf '%s' "$engine_hash" | grep -q '[^0-9a-f]'; then
        log "❌ sing-box: invalid SHA256 digest; unchanged"
        return 1
    fi
    if ! engine_tmp_space_ready "$engine_asset_size" 35000; then
        log "❌ sing-box: insufficient /tmp space for candidate download plus 35 MB reserve; unchanged"
        return 1
    fi
    if ! wget -O "$TMP_ENGINE_DIR/new.ipk" --header='Accept: application/octet-stream' \
        "$engine_url" >/dev/null 2>&1; then
        log "❌ sing-box: package download failed; unchanged"
        return 1
    fi
    downloaded_engine_size=$(wc -c < "$TMP_ENGINE_DIR/new.ipk" | tr -d '[:space:]')
    [ "$downloaded_engine_size" = "$engine_asset_size" ] || { log "❌ sing-box: candidate asset size differs from release metadata; unchanged"; return 1; }
    printf '%s  %s\n' "$engine_hash" "$TMP_ENGINE_DIR/new.ipk" | sha256sum -c - >/dev/null 2>&1 || {
        log "❌ sing-box: package SHA256 mismatch; unchanged"
        return 1
    }
    # The package and extracted executable coexist in tmpfs. Leave enough
    # headroom for the tested build and the router's other temporary files.
    # The downloaded package is already accounted for; require 35,000 KiB
    # remaining for candidate inspection/extraction through the validated parser.
    if ! engine_tmp_space_ready 1 34999; then
        log "❌ sing-box: less than 35 MB available in /tmp for preflight; unchanged"
        return 1
    fi

    # Inspect the digest-verified package metadata and binary in RAM before touching the live package.
    if ! verify_engine_ipk "$TMP_ENGINE_DIR/new.ipk" "$TESTED_ENGINE_VERSION" "$TMP_ENGINE_DIR/sing-box" "$engine_arch"; then
        log "❌ sing-box: package metadata/binary preflight failed; unchanged"
        return 1
    fi
    if ! "$TMP_ENGINE_DIR/sing-box" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        log "❌ sing-box: candidate config preflight failed; unchanged"
        return 1
    fi

    # The candidate must actually connect using this router's credentials.
    for engine_type in hysteria2 vless; do
        engine_tag=$(jq -r --arg type "$engine_type" '[.outbounds[] | select(.type == $type) | .tag][0] // empty' /etc/sing-box/config.json)
        [ -n "$engine_tag" ] || continue
        jq --arg tag "$engine_tag" '{log:{level:"error"},outbounds:[.outbounds[] | select(.tag == $tag)],route:{final:$tag}}' \
            /etc/sing-box/config.json > "$TMP_ENGINE_DIR/probe.json" || return 1
        if ! "$TMP_ENGINE_DIR/sing-box" tools fetch -c "$TMP_ENGINE_DIR/probe.json" -o "$engine_tag" \
            "$URLTEST_TESTING_URL" >/dev/null 2>&1; then
            log "❌ sing-box: candidate cannot reach $engine_type through $engine_tag; unchanged"
            return 1
        fi
    done

    rm -f "$TMP_ENGINE_DIR/sing-box" "$TMP_ENGINE_DIR/probe.json"
    case "$ENGINE_ORIGIN" in
        stock)
            # The exact installed stock version must be available BEFORE removal.
            stock_status=$(opkg status sing-box 2>/dev/null) || { log "❌ sing-box: cannot query installed stock package; unchanged"; return 1; }
            stock_version=$(printf '%s\n' "$stock_status" | sed -n 's/^Version: //p' | sed -n '1p')
            [ -n "$stock_version" ] || { log "❌ sing-box: installed version unknown; unchanged"; return 1; }
            STOCK_PREVIOUS_VERSION="$stock_version"
            STOCK_PREVIOUS_BINARY_SHA256=$(sha256sum "$STOCK_BINARY_PATH" 2>/dev/null | awk 'NR == 1 {print $1}')
            case "$STOCK_PREVIOUS_BINARY_SHA256" in ''|*[!0-9a-f]*)
                log "❌ sing-box: could not fingerprint the installed stock binary; unchanged"
                return 1 ;;
            esac
            [ "${#STOCK_PREVIOUS_BINARY_SHA256}" -eq 64 ] || {
                log "❌ sing-box: installed stock binary SHA256 is malformed; unchanged"
                return 1
            }
            ensure_package_indexes_updated || { log "❌ sing-box: rollback index unavailable; unchanged"; return 1; }
            stock_package_size=$(opkg_info_package_size sing-box "$stock_version") || {
                log "❌ sing-box: exact stock package size unavailable from opkg metadata; unchanged"
                return 1
            }
            engine_tmp_space_ready "$stock_package_size" 35000 || {
                log "❌ sing-box: insufficient /tmp space for stock rollback download plus 35 MB reserve; unchanged"
                return 1
            }
            if ! (cd "$TMP_ENGINE_DIR" && opkg download sing-box >/dev/null 2>&1); then
                log "❌ sing-box: rollback package unavailable; unchanged"
                return 1
            fi
            set -- "$TMP_ENGINE_DIR"/sing-box_*.ipk
            case "$#:$1" in
                1:"$TMP_ENGINE_DIR"/sing-box_"$stock_version"_*.ipk) ;;
                *) log "❌ sing-box: exact rollback version $stock_version unavailable; unchanged"; return 1 ;;
            esac
            [ -f "$1" ] || { log "❌ sing-box: rollback package missing; unchanged"; return 1; }
            downloaded_stock_size=$(wc -c < "$1" | tr -d '[:space:]')
            [ "$downloaded_stock_size" = "$stock_package_size" ] || { log "❌ sing-box: stock rollback package size does not match opkg metadata; unchanged"; return 1; }
            STOCK_ROLLBACK_PACKAGE="$1"
            STOCK_ROLLBACK_BINARY_VERSION=$(verify_stock_sing_box_ipk "$STOCK_ROLLBACK_PACKAGE" "$STOCK_PREVIOUS_VERSION" "$TMP_ENGINE_DIR/stock-sing-box" "$engine_arch") || {
                log "❌ sing-box: stock rollback package metadata/binary verification failed; unchanged"
                return 1
            }
            STOCK_ROLLBACK_BINARY_SHA256=$(sha256sum "$TMP_ENGINE_DIR/stock-sing-box" 2>/dev/null | awk 'NR == 1 {print $1}')
            case "$STOCK_ROLLBACK_BINARY_SHA256" in ''|*[!0-9a-f]*)
                log "❌ sing-box: stock rollback binary SHA256 is malformed; unchanged"
                return 1 ;;
            esac
            [ "${#STOCK_ROLLBACK_BINARY_SHA256}" -eq 64 ] || {
                log "❌ sing-box: stock rollback binary SHA256 is malformed; unchanged"
                return 1
            }
            if ! persist_engine_recovery_package "$STOCK_ROLLBACK_PACKAGE" "$ENGINE_RECOVERY_DIR" /overlay stock "$STOCK_PREVIOUS_VERSION"; then
                log "❌ sing-box: could not preserve exact stock rollback IPK on /overlay; unchanged"
                return 1
            fi
            STOCK_ROLLBACK_PACKAGE="$ENGINE_RECOVERY_PACKAGE"
            rm -f "$TMP_ENGINE_DIR/stock-sing-box"
            ;;
        podkop-engine)
            if ! opkg --noaction install "$TMP_ENGINE_DIR/new.ipk" >/dev/null 2>&1; then
                log "❌ sing-box: engine package dependency preflight failed; unchanged"
                return 1
            fi
            download_engine_rollback_package "$ENGINE_PREVIOUS_VERSION" || return 1
            ;;
        unowned)
            backup_unowned_sing_box || return 1
            ;;
        *)
            log "❌ sing-box: unsupported package replacement origin; unchanged"
            return 1 ;;
    esac

    install_candidate_engine || return 1
    return 0
}

ensure_script_updated() {
    [ "$AUTO_UPDATE_SCRIPT" = "1" ] || return 0
    [ -n "$SCRIPT_UPDATE_URL" ] || return 0

    resolve_script_path
    [ -n "$SCRIPT_SELF_PATH" ] || return 0
    [ -w "$SCRIPT_SELF_PATH" ] || return 0

    tmp_script="$(mktemp /tmp/podkop-update.XXXXXX)" || return 1

    if ! download_file "$SCRIPT_UPDATE_URL" "$tmp_script"; then
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

    if ! download_file "$SCRIPT_UPDATE_URL" "$tmp_script"; then
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
PATTERN='(vless|ss|trojan|socks|hy2|hysteria2)://[^"'"'"' <]+'

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
    ensure_sing_box_updated || exit 1
    ensure_cron_job
    log "✅ Проверка обновлений завершена"
    exit 0
fi

# --- СКАЧИВАНИЕ ---
# Загружает сырой текст/HTML/подписку
download_content() {
    url="$1"

    raw=""

    # Пробуем wget с таймаутом
    set -- \
        --no-check-certificate \
        --timeout=15 \
        --user-agent="$SUBSCRIPTION_USER_AGENT" \
        -qO-

    [ -n "$X_HWID" ] && set -- "$@" --header="X-HWID: $X_HWID"
    [ -n "$X_DEVICE_OS" ] && set -- "$@" --header="X-Device-OS: $X_DEVICE_OS"
    [ -n "$X_VER_OS" ] && set -- "$@" --header="X-Ver-OS: $X_VER_OS"
    [ -n "$X_DEVICE_MODEL" ] && set -- "$@" --header="X-Device-Model: $X_DEVICE_MODEL"
    [ -n "$X_OS" ] && set -- "$@" --header="X-OS: $X_OS"
    [ -n "$X_MODEL" ] && set -- "$@" --header="X-Model: $X_MODEL"

    raw=$(wget "$@" "$url" 2>/dev/null)

    # Fallback на curl если wget не справился
    if [ -z "$raw" ] && command -v curl >/dev/null 2>&1; then
        raw=$(curl -fsSLk \
            --max-time 15 \
            --user-agent "$SUBSCRIPTION_USER_AGENT" \
            ${X_HWID:+-H "X-HWID: $X_HWID"} \
            ${X_DEVICE_OS:+-H "X-Device-OS: $X_DEVICE_OS"} \
            ${X_VER_OS:+-H "X-Ver-OS: $X_VER_OS"} \
            ${X_DEVICE_MODEL:+-H "X-Device-Model: $X_DEVICE_MODEL"} \
            ${X_OS:+-H "X-OS: $X_OS"} \
            ${X_MODEL:+-H "X-Model: $X_MODEL"} \
            "$url" 2>/dev/null)
    fi

    [ -n "$raw" ] || return 1

    # Проверяем что строка похожа на base64 перед декодированием
    if printf '%s' "$raw" | grep -qE '^[A-Za-z0-9+/=]{20,}$'; then
        decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null)
        if [ -n "$decoded" ]; then
            printf '%s' "$decoded"
            return 0
        fi
    fi

    printf '%s' "$raw"
}

# Некоторые подписки отдают не список ссылок, а Xray-конфиг (JSON-массив профилей).
# Определяем это по первому непробельному символу.
is_json_content() {
    printf '%s' "$1" | grep -qE '^[[:space:]]*[][{]'
}

# Each JSON row carries its authorized section separately from the share link.
# OpenWrt jq is commonly compiled without the regex library: avoid sub/test/match.
JQ_XRAY_FILTER='
if type == "array" then .[] elif type == "object" then . else empty end
| select(type == "object" and (.outbounds | type) == "array")
| . as $profile
| ($profile.remarks // "") as $base_name
| (if ($base_name | endswith("YOUTUBE NO ADS")) then "main"
   elif ($base_name | endswith("Germany # 2") or endswith("Germany # 5") or endswith("Poland # 1")) then "Gemini"
   elif (($base_name | startswith("🇳🇱 Netherlands #")) and
         ((try ($base_name | split("#") | last | tonumber) catch null) != null)) then "AI"
   elif ($base_name | endswith("AUTO-EU")) then "Other"
   else "" end) as $section
| select($section == "main" or $section == "Gemini" or $section == "AI" or $section == "Other")
| ([$profile.outbounds[] | select(.protocol=="vless" or .protocol=="hysteria")]) as $matches
| ($matches | length) as $match_count
| (range(0; $match_count)) as $idx
| ($matches[$idx]) as $o
| ($base_name + (if $match_count > 1 then " (\($idx+1))" else "" end)) as $name
| if $o.protocol == "vless" then
    ($o.settings.vnext[0]) as $vn
    | ($vn.users[0]) as $u
    | ($o.streamSettings) as $ss
    | ($ss.network // "tcp") as $net
    | ($ss.security // "none") as $sec
    | ($ss.realitySettings.serverName // $ss.tlsSettings.serverName // "") as $sni
    | ($ss.realitySettings.fingerprint // $ss.tlsSettings.fingerprint // "") as $fp
    | ($ss.realitySettings.publicKey // "") as $pbk
    | ($ss.realitySettings.shortId // "") as $sid
    | ($ss.grpcSettings.serviceName // "") as $svc
    | ($u.flow // "") as $flow
    | ($u.encryption // "none") as $enc
    | "\($section)\tvless://\($u.id)@\($vn.address):\($vn.port)?encryption=\($enc)"
      + (if $flow != "" then "&flow=\($flow)" else "" end)
      + "&type=\($net)"
      + (if $net == "grpc" then "&serviceName=\($svc)&mode=gun" else "" end)
      + (if $net == "xhttp" then "&path=\(($ss.xhttpSettings.path // "/")|@uri)&mode=\($ss.xhttpSettings.mode // "auto")" else "" end)
      + "&security=\($sec)"
      + (if $sni != "" then "&sni=\($sni)" else "" end)
      + (if $fp != "" then "&fp=\($fp)" else "" end)
      + (if $pbk != "" then "&pbk=\($pbk)" else "" end)
      + (if $sid != "" then "&sid=\($sid)" else "" end)
      + "#\($name|@uri)"
  else
    ($o.settings) as $s
    | ($o.streamSettings) as $ss
    | ($ss.tlsSettings.serverName // "") as $sni
    | ($ss.finalmask // {} | tostring) as $fm
    | "\($section)\thysteria2://\($ss.hysteriaSettings.auth)@\($s.address):\($s.port)/?sni=\($sni)"
      + (if $fm != "{}" then "&fm=\($fm|@uri)" else "" end)
      + "#\($name|@uri)"
  end
'

convert_json_subscription() {
    ensure_jq_installed || return 1
    printf '%s' "$1" | jq -er "$JQ_XRAY_FILTER" 2>/dev/null
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
        vless://*|ss://*|trojan://*|socks://*|hy2://*|hysteria2://*) ;;
        *) return 1 ;;
    esac

    # Разделяем ссылку и имя после #
    base="${link%%#*}"
    name=""
    [ "$base" != "$link" ] && name="${link#*#}"

    # Исключаем сервера по имени (см. EXCLUDE_NAME_PATTERN выше)
    if [ -n "$name" ] && [ -n "$EXCLUDE_NAME_PATTERN" ]; then
        printf '%s' "$name" | grep -qE "$EXCLUDE_NAME_PATTERN" && return 1
    fi

    # Неподдерживаемый транспорт сразу выкидываем
    printf '%s' "$base" | grep -qi 'type=xhttp' && return 1

    # Shadowsocks и Hysteria2 не трогаем: только имя при необходимости
    case "$base" in
        ss://*|hy2://*|hysteria2://*)
            if [ -n "$name" ]; then
                printf '%s#%s\n' "$base" "$(clean_name "$name")"
            else
                printf '%s\n' "$base"
            fi
            return 0
            ;;
    esac

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
    transport=$(printf '%s' "&${query}" | grep -oE '&type=[A-Za-z0-9]*' | tail -n1 | cut -d= -f2)
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

# --- GROUPED COLLECTION ---
# For text/base64 subscriptions authorize only exact, unsuffixed profile names.
# JSON metadata is authoritative and is handled above, before names get (1)..(4).
link_section() {
    case "${1#*#}" in
        *YOUTUBE%20NO%20ADS|*'YOUTUBE NO ADS') echo main ;;
        *Germany%20%23%202|*Germany%20%23%205|*Poland%20%23%201|*'Germany # 2'|*'Germany # 5'|*'Poland # 1') echo Gemini ;;
        *Netherlands%20%23[0-9]*|*'Netherlands #'[0-9]*)
            number="${1#*#}"
            case "$number" in
                *Netherlands%20%23*) number="${number##*Netherlands%20%23}" ;;
                *) number="${number##*Netherlands #}" ;;
            esac
            case "$number" in ''|*[!0-9]*) ;; *) echo AI ;; esac
            ;;
        *AUTO-EU) echo Other ;;
    esac
}

collect() {
    local input="$1" num="$2" content converted row section link norm
    [ -n "$input" ] || return 0
    case "$input" in
        vless://*|ss://*|trojan://*|socks://*|hy2://*|hysteria2://*)
            section=$(link_section "$input")
            [ -n "$section" ] || { log "⚠️  Source $num: unnamed/unauthorized direct link"; return 1; }
            norm=$(normalize_link "$input") || return 1
            printf '%s\t%s\n' "$section" "$norm" >> "$TMP_POOL"
            return
            ;;
    esac
    log "📡 Source $num: downloading..."
    content=$(download_content "$input") || { log "❌ Source $num: download failed"; return 1; }
    if is_json_content "$content"; then
        converted=$(convert_json_subscription "$content") || { log "❌ Source $num: invalid JSON/profile"; return 1; }
        [ -n "$converted" ] || return 1
        while IFS="$(printf '\t')" read -r section link; do
            case "$section" in main|Gemini|AI|Other) ;; *) continue ;; esac
            norm=$(normalize_link "$link") || continue
            printf '%s\t%s\n' "$section" "$norm" >> "$TMP_POOL"
        done <<EOF
$converted
EOF
    else
        # A text/HTML/base64 format has no reliable profile metadata; only names
        # with an exact authorized suffix may enter a section.
        printf '%s\n' "$content" | grep -oE "$PATTERN" | while IFS= read -r link; do
            section=$(link_section "$link")
            [ -n "$section" ] || continue
            norm=$(normalize_link "$link") || continue
            printf '%s\t%s\n' "$section" "$norm" >> "$TMP_POOL"
        done
    fi
}

# Append unique list values, retaining any pre-existing user choices in Other.
add_list_once() {
    local target="$1" value="$2" current
    current=$(uci -q get "$target" 2>/dev/null || :)
    case " $current " in *" $value "*) return 0 ;; esac
    uci add_list "$target=$value"
}

# Move only routing selectors that were on main. Never mutate Gemini's google_ai
# or delete selectors belonging to any unrelated section.
migrate_main_routes() {
    local key value item
    for key in community_lists user_domains user_subnets local_domain_lists local_subnet_lists remote_domain_lists remote_subnet_lists fully_routed_ips; do
        value=$(uci -q get "podkop.main.$key" 2>/dev/null || :)
        for item in $value; do
            [ "$key" = community_lists ] && [ "$item" = youtube ] && continue
            [ "$key" = user_domains ] && [ "$item" = www.googleapis.com ] && continue
            add_list_once "podkop.Other.$key" "$item" || return 1
        done
        [ -z "$value" ] || uci -q delete "podkop.main.$key" || return 1
    done
    for key in user_domain_list_type user_subnet_list_type user_domains_text user_subnets_text; do
        value=$(uci -q get "podkop.main.$key" 2>/dev/null || :)
        [ -z "$value" ] && continue
        if [ -n "$(uci -q get "podkop.Other.$key" 2>/dev/null)" ] &&
           [ "$(uci -q get "podkop.Other.$key")" != "$value" ]; then
            log "❌ Conflicting Other.$key; refusing migration"
            return 1
        fi
        uci set "podkop.Other.$key=$value" || return 1
        uci -q delete "podkop.main.$key" || return 1
    done
    add_list_once podkop.main.community_lists youtube
}

# Replaces only the four explicitly managed sections' proxy pools. A missing
# authorized pool fails before any UCI changes (no partial subscription update).
set_proxy_pool() {
    local section="$1" link
    uci set "podkop.$section.connection_type=proxy" || return 1
    uci set "podkop.$section.proxy_config_type=urltest" || return 1
    uci set "podkop.$section.urltest_check_interval=1m" || return 1
    uci set "podkop.$section.urltest_tolerance=150" || return 1
    uci set "podkop.$section.urltest_testing_url=$URLTEST_TESTING_URL" || return 1
    uci -q delete "podkop.$section.urltest_proxy_links" || :
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        uci add_list "podkop.$section.urltest_proxy_links=$link" || return 1
    done < "$TMP_CURRENT"
}

rollback_podkop() {
    log "❌ Update failed, restoring Podkop backup $BACKUP_FILE"
    if [ -s "${BACKUP_FILE}.config" ]; then
        cp "${BACKUP_FILE}.config" /etc/config/podkop || return 1
        uci -q revert podkop || :
    else
        uci -q revert podkop || :
        uci -q import podkop < "$BACKUP_FILE" || return 1
        uci commit podkop || return 1
    fi
    /etc/init.d/podkop restart >/dev/null 2>&1 || log "❌ Restore requires manual service restart"
}

log "📥 Collecting authorized profiles..."
ensure_hwid || exit 1
ensure_device_headers
ensure_cron_job
collect "$SOURCE_1" 1 || exit 1
collect "$SOURCE_2" 2 || exit 1
collect "$SOURCE_3" 3 || exit 1

# Deterministic idempotence: sort, dedupe and limit each section independently.
sort -u "$TMP_POOL" > "${TMP_POOL}.u" || exit 1
mv "${TMP_POOL}.u" "$TMP_POOL" || exit 1
for section in main Gemini AI Other; do
    awk -F '\t' -v section="$section" '$1==section {print $2}' "$TMP_POOL" | sed -n "1,${LIMIT}p" > "$TMP_CURRENT"
    [ -s "$TMP_CURRENT" ] || { log "❌ No supported links for $section; unchanged"; exit 1; }
    # Filter every pool before modifying any UCI section.
    while IFS= read -r link; do
        case "$link" in
            *pbk=*)
                fp=$(printf '%s' "$link" | sed -nE 's/.*[?&]fp=([^&]+).*/\1/p')
                is_valid_fp "$fp" || { log "❌ Invalid fingerprint in $section"; exit 1; }
                ;;
        esac
    done < "$TMP_CURRENT"
    sed "s/^/$section$(printf '\t')/" "$TMP_CURRENT" >> "$TMP_FINAL"
done

# Backup before staging, persist it for manual recovery. Export is also used
# as the exact idempotence comparison; never log credentials.
BACKUP_FILE="/etc/podkop-update-backup-$(date '+%Y%m%d-%H%M%S')-$$"
umask 077
uci -q export podkop > "$BACKUP_FILE" || { rm -f "$BACKUP_FILE"; exit 1; }
cp /etc/config/podkop "${BACKUP_FILE}.config" || { rm -f "$BACKUP_FILE"; exit 1; }

apply_sections() {
    local section link domain
    for section in main Gemini AI Other; do
        if ! uci -q get "podkop.$section" >/dev/null 2>&1; then
            # UCI get section may not return the type on all versions; check show.
            uci -q show "podkop.$section" >/dev/null 2>&1 || uci set "podkop.$section=section" || return 1
        fi
    done
    migrate_main_routes || return 1
    uci set podkop.main.user_domain_list_type=dynamic || return 1
    add_list_once podkop.main.user_domains www.googleapis.com || return 1
    add_list_once podkop.Gemini.community_lists google_ai || return 1
    # Static core OpenAI/Claude domains supplement the versioned official
    # sing-geosite rule sets below and keep login/API hosts available.
    case "$(uci -q get podkop.AI.user_domain_list_type 2>/dev/null)" in
        ''|dynamic) ;;
        *) log "❌ AI user-domain type conflicts with dynamic list"; return 1 ;;
    esac
    uci set podkop.AI.user_domain_list_type=dynamic || return 1
    for domain in openai.com chatgpt.com oaistatic.com oaiusercontent.com api.openai.com anthropic.com claude.ai api.anthropic.com claudeusercontent.com; do
        add_list_once podkop.AI.user_domains "$domain" || return 1
    done
    # Official sing-box geosite rulesets are maintained independently and
    # refreshed by Podkop's settings.update_interval; static domains remain
    # as a fallback if an upstream list omits a necessary login/API host.
    add_list_once podkop.AI.remote_domain_lists 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs' || return 1
    add_list_once podkop.AI.remote_domain_lists 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-anthropic.srs' || return 1
    for section in main Gemini AI Other; do
        awk -F '\t' -v section="$section" '$1==section {print $2}' "$TMP_FINAL" > "$TMP_CURRENT"
        set_proxy_pool "$section" || return 1
    done
}

if ! apply_sections || ! uci -q export podkop > "$TMP_WRITTEN"; then
    rollback_podkop
    exit 1
fi
if cmp -s "$BACKUP_FILE" "$TMP_WRITTEN"; then
    uci -q revert podkop || :
    rm -f "$BACKUP_FILE" "${BACKUP_FILE}.config"
    log "✅ No Podkop changes; restart unnecessary"
    exit 0
fi
if ! uci commit podkop; then
    rollback_podkop
    exit 1
fi
log "🔄 Reloading Podkop..."
if ! /etc/init.d/podkop reload >/dev/null 2>&1; then
    if ! /etc/init.d/podkop restart >/dev/null 2>&1; then
        rollback_podkop
        exit 1
    fi
fi
if ! check_servers_after_restart; then
    rollback_podkop
    exit 1
fi
log "✅ Updated main, Gemini, AI, Other; backup: $BACKUP_FILE"
