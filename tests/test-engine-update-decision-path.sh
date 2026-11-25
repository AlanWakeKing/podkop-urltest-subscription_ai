#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^(engine_binary_version_for_package|engine_upgrade_action|ensure_sing_box_updated)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 3) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: updater decision path missing' >&2
    exit 1
fi
. "$function_file"

mkdir -p "$work_dir/bin"
ln -s "$(command -v sed)" "$work_dir/bin/sed"
ln -s "$(command -v grep)" "$work_dir/bin/grep"
ln -s "$(command -v rm)" "$work_dir/bin/rm"
ln -s "$(command -v mkdir)" "$work_dir/bin/mkdir"
printf '#!/bin/sh\nprintf "sing-box version %%s\\n" "$BINARY_VERSION"\n' > "$work_dir/bin/sing-box"
chmod 755 "$work_dir/bin/sing-box"
PATH="$work_dir/bin"
export PATH

TESTED_ENGINE_VERSION='1.14.4-r29'
ENGINE_RECOVERY_DIR="$work_dir/recovery"
AUTO_UPDATE_SING_BOX=1
ENGINE_PRESENT=1
ENGINE_FULL_PRESENT=0
DB_READY=1
PACKAGE_VERSION='1.14.4-r29'
BINARY_VERSION='1.14.4-pdk-r29'
export BINARY_VERSION
FAIL_STATUS=0
OPKG_ACTIONS="$work_dir/opkg-actions"
LOG_FILE="$work_dir/log"
: > "$OPKG_ACTIONS"
: > "$LOG_FILE"

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
detect_package_manager() { PKG_MANAGER=opkg; }
opkg_status_database_ready() { [ "$DB_READY" = 1 ]; }
is_package_installed() {
    case "$1" in
        podkop-engine-full) [ "$ENGINE_FULL_PRESENT" = 1 ] ;;
        podkop-engine) [ "$ENGINE_PRESENT" = 1 ] ;;
        sing-box) return 1 ;;
        *) return 1 ;;
    esac
}
version_rank() {
    case "$1" in
        1.14.4-r27) printf '27\n' ;;
        1.14.4-r28) printf '28\n' ;;
        1.14.4-r29) printf '29\n' ;;
        1.14.4-r30) printf '30\n' ;;
        *) return 1 ;;
    esac
}
opkg() {
    case "$1" in
        status)
            [ "$2" = podkop-engine ] && [ "$FAIL_STATUS" = 0 ] || return 1
            printf 'Package: podkop-engine\nVersion: %s\nStatus: install user installed\n' "$PACKAGE_VERSION"
            ;;
        compare-versions)
            left_rank=$(version_rank "$2") || return 1
            right_rank=$(version_rank "$4") || return 1
            case "$3" in
                '>=' ) [ "$left_rank" -ge "$right_rank" ] ;;
                *) return 1 ;;
            esac
            ;;
        remove|install)
            printf '%s\n' "$*" >> "$OPKG_ACTIONS"
            return 1
            ;;
        *) return 1 ;;
    esac
}
run_and_check() {
    expected_rc=$1
    expected_log=$2
    : > "$LOG_FILE"
    actual_rc=0
    ensure_sing_box_updated || actual_rc=$?
    [ "$actual_rc" = "$expected_rc" ] || {
        echo "FAIL: updater decision returned $actual_rc, expected $expected_rc for $PACKAGE_VERSION/$BINARY_VERSION" >&2
        exit 1
    }
    grep -q "$expected_log" "$LOG_FILE" || {
        echo "FAIL: expected decision log not found: $expected_log" >&2
        exit 1
    }
    [ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: decision path mutated package state' >&2; exit 1; }
}

run_and_check 0 'already installed'
echo 'PASS: tested exact package/binary state is left unchanged by updater path'

PACKAGE_VERSION='1.14.4-r30'
BINARY_VERSION='1.14.4-pdk-r30'
run_and_check 0 'newer podkop-engine'
echo 'PASS: newer package/binary state is preserved by updater path'

PACKAGE_VERSION='1.14.4-r28'
BINARY_VERSION='1.14.4-pdk-r29'
run_and_check 0 'state is unverified'
echo 'PASS: package/binary mismatch is not changed by updater path'

PACKAGE_VERSION='1.14.4-r28'
BINARY_VERSION='1.14.4-pdk-r28'
run_and_check 1 'will be upgraded'
echo 'PASS: older package reaches update preflight but performs no mutation without curl'

PACKAGE_VERSION='malformed'
BINARY_VERSION='sing-box version unknown'
run_and_check 0 'state is unverified'
echo 'PASS: malformed package/binary state is not changed by updater path'

FAIL_STATUS=1
PACKAGE_VERSION='1.14.4-r28'
BINARY_VERSION='1.14.4-pdk-r28'
run_and_check 0 'state is unverified'
echo 'PASS: failed package-status query is not changed by updater path'

mkdir -p "$ENGINE_RECOVERY_DIR"
run_and_check 1 'prior engine recovery artifact exists'
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: prior recovery artifact did not block package mutation' >&2; exit 1; }
echo 'PASS: persistent recovery marker blocks a subsequent updater run'
