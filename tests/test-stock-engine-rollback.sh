#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^(start_podkop_and_check|stop_podkop_and_verify|restore_stock_sing_box|restore_previous_sing_box|rollback_engine_once|remove_stock_sing_box_packages|install_candidate_engine)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 7) exit }
    END { if (blocks != 7) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: stock rollback functions missing' >&2
    exit 1
fi
. "$function_file"

TMP_ENGINE_DIR="$work_dir/engine"
STOCK_ROLLBACK_PACKAGE="$TMP_ENGINE_DIR/sing-box_1.12.22-r1_aarch64_cortex-a53.ipk"
STOCK_PREVIOUS_VERSION='1.12.22-r1'
STOCK_ROLLBACK_BINARY_VERSION='sing-box version 1.12.22'
LIVE_BINARY_VERSION="$STOCK_ROLLBACK_BINARY_VERSION"
PODKOP_RUN_STATE_FILE="$work_dir/runtime"
mkdir -p "$TMP_ENGINE_DIR"
printf 'fixture package\n' > "$STOCK_ROLLBACK_PACKAGE"
printf 'candidate package fixture\n' > "$TMP_ENGINE_DIR/new.ipk"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_PRESENT=1
STOCK_PRESENT=0
STOCK_INSTALLED_VERSION=''
FAIL_REMOVE=0
FAIL_INSTALL=0
WRONG_STOCK_VERSION=0
FAIL_START=0
FAIL_HEALTH=0
FAIL_SING_BOX_CHECK=0
FAIL_STOP=0
CANDIDATE_INSTALL_ATTEMPTED=0
OPKG_ACTIONS="$work_dir/opkg-actions"
: > "$OPKG_ACTIONS"

opkg() {
    case "$1" in
        list-installed)
            [ "$ENGINE_PRESENT" != 1 ] || printf 'podkop-engine - 1.14.4-r28\n'
            [ "$STOCK_PRESENT" != 1 ] || printf 'sing-box - %s\n' "$STOCK_INSTALLED_VERSION"
            ;;
        status)
            [ "$2" = sing-box ] && [ "$STOCK_PRESENT" = 1 ] || return 1
            printf 'Package: sing-box\nVersion: %s\nStatus: install user installed\n' "$STOCK_INSTALLED_VERSION"
            ;;
        remove)
            [ "$2" = --force-depends ] || return 1
            case "$3" in
                podkop-engine)
                    [ "$FAIL_REMOVE" != 1 ] || return 1
                    printf 'remove-engine\n' >> "$OPKG_ACTIONS"
                    ENGINE_PRESENT=0
                    ;;
                sing-box)
                    [ "$FAIL_REMOVE" != 1 ] || return 1
                    printf 'remove-stock\n' >> "$OPKG_ACTIONS"
                    STOCK_PRESENT=0
                    ;;
                *) return 1 ;;
            esac
            ;;
        install)
            package_file=$2
            action='install-stock'
            ;;
        --force-downgrade)
            if [ "$2" = --force-reinstall ] && [ "$3" = install ]; then
                package_file=$4
                action='force-reinstall-downgrade-stock'
            elif [ "$2" = install ]; then
                package_file=$3
                action='downgrade-stock'
            else
                return 1
            fi
            ;;
        --force-reinstall)
            [ "$2" = install ] || return 1
            package_file=$3
            action='force-reinstall-stock'
            ;;
        *) return 1 ;;
    esac
    case "$1" in
        install|--force-downgrade|--force-reinstall)
            if [ "$package_file" != "$STOCK_ROLLBACK_PACKAGE" ]; then
                CANDIDATE_INSTALL_ATTEMPTED=1
                return 1
            fi
            [ "$FAIL_INSTALL" != 1 ] || return 1
            printf '%s\n' "$action" >> "$OPKG_ACTIONS"
            STOCK_PRESENT=1
            if [ "$WRONG_STOCK_VERSION" = 1 ]; then
                STOCK_INSTALLED_VERSION='1.12.99-r1'
                LIVE_BINARY_VERSION='sing-box version 1.12.99'
            else
                STOCK_INSTALLED_VERSION="$STOCK_PREVIOUS_VERSION"
                LIVE_BINARY_VERSION="$STOCK_ROLLBACK_BINARY_VERSION"
            fi
            ;;
    esac
}
service() {
    case "$2" in
        stop)
            [ "$FAIL_STOP" != 1 ] || return 1
            printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE"
            ;;
        start)
            [ "$FAIL_START" != 1 ] || return 1
            printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
            ;;
        *) return 1 ;;
    esac
}
podkop() {
    [ "$1" = check_sing_box ] || return 1
    if [ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ]; then
        printf '{"sing_box_process_running":1,"sing_box_ports_listening":1}\n'
    else
        printf '{"sing_box_process_running":0,"sing_box_ports_listening":0}\n'
    fi
}
mkdir -p "$work_dir/bin"
printf '%s\n' '#!/bin/sh' 'case "$1" in' \
    '  version) printf "%s\\n" "$LIVE_BINARY_VERSION" ;;' \
    '  check) [ "$FAIL_SING_BOX_CHECK" != 1 ] ;;' \
    '  *) exit 1 ;;' 'esac' > "$work_dir/bin/sing-box"
chmod 755 "$work_dir/bin/sing-box"
PATH="$work_dir/bin:$PATH"
export PATH STOCK_ROLLBACK_BINARY_VERSION LIVE_BINARY_VERSION FAIL_SING_BOX_CHECK
STOCK_BINARY_PATH="$work_dir/bin/sing-box"
STOCK_PREVIOUS_BINARY_SHA256=$(sha256sum "$STOCK_BINARY_PATH" | cut -d ' ' -f1)
STOCK_ROLLBACK_BINARY_SHA256="$STOCK_PREVIOUS_BINARY_SHA256"
sleep() { :; }
wait_for_engine_health() { [ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] && [ "$FAIL_HEALTH" != 1 ]; }
log() { :; }

restore_stock_sing_box || { echo 'FAIL: valid stock rollback rejected' >&2; exit 1; }
[ "$ENGINE_PRESENT" = 0 ] && [ "$STOCK_PRESENT" = 1 ] || { echo 'FAIL: stock rollback did not restore package ownership' >&2; exit 1; }
[ "$STOCK_INSTALLED_VERSION" = "$STOCK_PREVIOUS_VERSION" ] || { echo 'FAIL: stock rollback installed wrong version' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: stock rollback did not start Podkop' >&2; exit 1; }
echo 'PASS: stock package and runtime restored exactly'

: > "$OPKG_ACTIONS"
ENGINE_PRESENT=0
STOCK_PRESENT=1
STOCK_INSTALLED_VERSION="$STOCK_PREVIOUS_VERSION"
LIVE_BINARY_VERSION='sing-box version 1.12.21'
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
restore_stock_sing_box || { echo 'FAIL: already-installed stock package could not be repaired' >&2; exit 1; }
grep -q '^force-reinstall-downgrade-stock$' "$OPKG_ACTIONS" || { echo 'FAIL: same-version stock payload was not forcibly restored' >&2; exit 1; }
echo 'PASS: already-installed stock package is force-reinstalled from verified IPK'

: > "$OPKG_ACTIONS"
ENGINE_PRESENT=0
STOCK_PRESENT=1
STOCK_INSTALLED_VERSION="$STOCK_PREVIOUS_VERSION"
FAIL_INSTALL=1
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
restore_stock_sing_box || { echo 'FAIL: unchanged exact stock package was treated as failed rollback' >&2; exit 1; }
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: exact pre-existing stock package was redundantly reinstalled' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: unchanged stock rollback did not restart Podkop' >&2; exit 1; }
FAIL_INSTALL=0
echo 'PASS: exact installed stock package is accepted after failed removal without redundant reinstall'

: > "$OPKG_ACTIONS"
ENGINE_PRESENT=0
STOCK_PRESENT=1
STOCK_INSTALLED_VERSION="$STOCK_PREVIOUS_VERSION"
LIVE_BINARY_VERSION="$STOCK_ROLLBACK_BINARY_VERSION"
STOCK_PREVIOUS_BINARY_SHA256=$(printf '%064d' 0)
printf 'running\\n' > "$PODKOP_RUN_STATE_FILE"
restore_stock_sing_box || { echo 'FAIL: stock package with changed binary hash could not be repaired' >&2; exit 1; }
grep -q '^force-reinstall-downgrade-stock$' "$OPKG_ACTIONS" || { echo 'FAIL: stock package with changed pre-switch binary hash was accepted unchanged' >&2; exit 1; }
STOCK_PREVIOUS_BINARY_SHA256=$(sha256sum "$STOCK_BINARY_PATH" | cut -d ' ' -f1)
echo 'PASS: changed stock binary hash triggers exact rollback reinstall despite matching version strings'

: > "$OPKG_ACTIONS"
ENGINE_PRESENT=0
STOCK_PRESENT=1
STOCK_INSTALLED_VERSION="$STOCK_PREVIOUS_VERSION"
LIVE_BINARY_VERSION="$STOCK_ROLLBACK_BINARY_VERSION"
STOCK_PREVIOUS_BINARY_SHA256=$(printf '%064d' 0)
STOCK_ROLLBACK_BINARY_SHA256=$(printf '%064d' 0)
FAIL_INSTALL=0
printf 'running\\n' > "$PODKOP_RUN_STATE_FILE"
if restore_stock_sing_box; then
    echo 'FAIL: stock rollback accepted installed binary different from verified rollback IPK' >&2
    exit 1
fi
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: rollback IPK hash mismatch did not stop Podkop' >&2; exit 1; }
STOCK_PREVIOUS_BINARY_SHA256=$(sha256sum "$STOCK_BINARY_PATH" | cut -d ' ' -f1)
STOCK_ROLLBACK_BINARY_SHA256="$STOCK_PREVIOUS_BINARY_SHA256"
echo 'PASS: stock rollback refuses to start on post-install binary hash mismatch'

: > "$OPKG_ACTIONS"
ENGINE_PRESENT=0
STOCK_PRESENT=1
STOCK_INSTALLED_VERSION="$STOCK_PREVIOUS_VERSION"
LIVE_BINARY_VERSION="$STOCK_ROLLBACK_BINARY_VERSION"
ENGINE_ORIGIN=stock
ENGINE_SWITCH_ACTIVE=0
ENGINE_RECOVERY_REQUIRED=0
TESTED_ENGINE_VERSION='1.14.4-r28'
CANDIDATE_INSTALL_ATTEMPTED=0
FAIL_REMOVE=1
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
if install_candidate_engine; then
    echo 'FAIL: candidate upgrade succeeded after stock removal failure' >&2
    exit 1
fi
[ "$STOCK_PRESENT" = 1 ] && [ "$STOCK_INSTALLED_VERSION" = "$STOCK_PREVIOUS_VERSION" ] || { echo 'FAIL: stock package changed after failed removal' >&2; exit 1; }
[ "$CANDIDATE_INSTALL_ATTEMPTED" = 0 ] || { echo 'FAIL: candidate installation ran after stock removal failure' >&2; exit 1; }
[ "$ENGINE_SWITCH_ACTIVE" = 0 ] && [ "$ENGINE_RECOVERY_REQUIRED" = 0 ] || { echo 'FAIL: successful original-state recovery left inconsistent markers' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: rollback did not restart Podkop after failed stock removal' >&2; exit 1; }
FAIL_REMOVE=0
echo 'PASS: failed stock removal recognizes unchanged package, aborts upgrade, and restores runtime'

: > "$OPKG_ACTIONS"
ENGINE_PRESENT=1
STOCK_PRESENT=0
FAIL_STOP=1
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
if restore_stock_sing_box; then
    echo 'FAIL: stock rollback proceeded without confirmed stop' >&2
    exit 1
fi
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: package mutation occurred after stop verification failed' >&2; exit 1; }
FAIL_STOP=0
echo 'PASS: unverified stop blocks stock package changes'

ENGINE_PRESENT=1
STOCK_PRESENT=0
STOCK_INSTALLED_VERSION=''
FAIL_REMOVE=1
: > "$OPKG_ACTIONS"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
if restore_stock_sing_box; then
    echo 'FAIL: stock rollback continued after engine removal failed' >&2
    exit 1
fi
[ "$ENGINE_PRESENT" = 1 ] && [ "$STOCK_PRESENT" = 0 ] || { echo 'FAIL: package state changed after failed engine removal' >&2; exit 1; }
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: stock install ran after engine removal failed' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: failed engine removal did not leave Podkop stopped' >&2; exit 1; }
FAIL_REMOVE=0
echo 'PASS: failed engine removal blocks stock install and leaves Podkop stopped'

ENGINE_PRESENT=1
STOCK_PRESENT=0
STOCK_INSTALLED_VERSION=''
WRONG_STOCK_VERSION=1
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
if restore_stock_sing_box; then
    echo 'FAIL: stock rollback accepted wrong installed package version' >&2
    exit 1
fi
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: wrong stock package did not leave Podkop stopped' >&2; exit 1; }
echo 'PASS: wrong stock package version rejected and Podkop stopped'

ENGINE_PRESENT=1
STOCK_PRESENT=0
STOCK_INSTALLED_VERSION=''
WRONG_STOCK_VERSION=0
FAIL_SING_BOX_CHECK=1
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
if restore_stock_sing_box; then
    echo 'FAIL: stock rollback accepted invalid config' >&2
    exit 1
fi
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: config failure did not leave Podkop stopped' >&2; exit 1; }
echo 'PASS: invalid stock config rejected and Podkop stopped'

FAIL_SING_BOX_CHECK=0
FAIL_HEALTH=1
ENGINE_PRESENT=1
STOCK_PRESENT=0
STOCK_INSTALLED_VERSION=''
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
if restore_stock_sing_box; then
    echo 'FAIL: stock rollback accepted failed runtime health check' >&2
    exit 1
fi
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: runtime health failure did not leave Podkop stopped' >&2; exit 1; }
FAIL_HEALTH=0
echo 'PASS: unhealthy restored stock runtime is rejected and stopped'
