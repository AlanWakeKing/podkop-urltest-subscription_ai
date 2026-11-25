#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
function_file="$work_dir/functions.sh"
awk '
    /^(cleanup_update|engine_binary_version_for_package|start_podkop_and_check|restart_podkop_and_check|stop_podkop_and_verify|restore_podkop_engine|restore_previous_sing_box|rollback_engine_once|install_candidate_engine|ensure_sing_box_updated)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 10) exit }
    END { if (blocks != 10) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"
[ -s "$function_file" ] || { echo 'FAIL: rollback functions missing' >&2; exit 1; }
. "$function_file"

mkdir -p "$work_dir/bin" "$work_dir/engine"
printf '%s\n' '#!/bin/sh' 'state=$(cat "$ENGINE_STATE_FILE")' 'case "$1" in' \
    '  version)' '    case "$state" in previous) if [ "${FAIL_RESTORED_BINARY:-0}" = 1 ]; then echo "sing-box version 1.14.4-pdk-r28"; else echo "sing-box version 1.14.4-pdk-r27"; fi ;; current) if [ "${FAIL_CANDIDATE_BINARY:-0}" = 1 ]; then echo "sing-box version 1.14.4-pdk-r27"; else echo "sing-box version 1.14.4-pdk-r28"; fi ;; previous-mismatch) echo "sing-box version 1.14.4-pdk-r28" ;; *) exit 1 ;; esac ;;' \
    '  check) [ "${FAIL_SING_BOX_CHECK:-0}" != 1 ] ;;' '  *) exit 0 ;;' 'esac' > "$work_dir/bin/sing-box"
chmod 755 "$work_dir/bin/sing-box"
export ENGINE_STATE_FILE="$work_dir/engine-state"
export OPKG_ACTIONS="$work_dir/opkg-actions"
export OPKG_STATUS_COUNT_FILE="$work_dir/opkg-status-count"
export PAYLOAD_STATE_FILE="$work_dir/payload-state"
export PODKOP_RUN_STATE_FILE="$work_dir/podkop-run-state"
: > "$OPKG_ACTIONS"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
TMP_ENGINE_DIR="$work_dir/engine"
touch "$TMP_ENGINE_DIR/rollback.ipk" "$TMP_ENGINE_DIR/new.ipk"
ENGINE_PREVIOUS_VERSION='1.14.4-r27'
PATH="$work_dir/bin:$PATH"
export PATH

opkg() {
    state=$(cat "$ENGINE_STATE_FILE")
    case "$1" in
        list-installed)
            [ "${FAIL_OPKG_LIST:-0}" != 1 ] || return 1
            [ "$state" = absent ] && return 0
            case "$state" in previous|previous-mismatch) version=1.14.4-r27 ;; *) version=1.14.4-r28 ;; esac
            printf 'podkop-engine - %s\n' "$version"
            ;;
        status)
            [ "$2" = podkop-engine ] && [ "$state" != absent ] || return 1
            status_count=0
            [ ! -f "$OPKG_STATUS_COUNT_FILE" ] || status_count=$(cat "$OPKG_STATUS_COUNT_FILE")
            status_count=$((status_count + 1))
            printf '%s\n' "$status_count" > "$OPKG_STATUS_COUNT_FILE"
            [ "${FAIL_OPKG_STATUS_AT:-0}" != "$status_count" ] || return 1
            case "$state" in previous|previous-mismatch) version=1.14.4-r27 ;; *) version=1.14.4-r28 ;; esac
            printf 'Package: podkop-engine\nVersion: %s\nStatus: install user installed\n' "$version"
            ;;
        remove)
            printf 'remove\n' >> "$OPKG_ACTIONS"
            printf 'absent\n' > "$ENGINE_STATE_FILE"
            ;;
        --force-downgrade)
            [ "$2" = install ] && [ "$3" = "${ENGINE_RECOVERY_PACKAGE:-$TMP_ENGINE_DIR/rollback.ipk}" ] || return 1
            printf 'downgrade-install\n' >> "$OPKG_ACTIONS"
            if [ "${FAIL_ROLLBACK_INSTALL:-0}" = 1 ]; then
                if [ "${FAIL_STOP_AFTER_ROLLBACK_INSTALL:-0}" = 1 ]; then
                    printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
                    FAIL_STOP=1
                fi
                return 1
            fi
            if [ "${FAIL_RESTORE_PACKAGE_VERSION:-0}" = 1 ]; then
                printf 'current\n' > "$ENGINE_STATE_FILE"
            else
                printf 'previous\n' > "$ENGINE_STATE_FILE"
            fi
            ;;
        --force-reinstall)
            [ "$2" = install ] && [ "$3" = "${ENGINE_RECOVERY_PACKAGE:-$TMP_ENGINE_DIR/rollback.ipk}" ] || return 1
            printf 'reinstall\n' >> "$OPKG_ACTIONS"
            if [ "${FAIL_ROLLBACK_INSTALL:-0}" = 1 ]; then
                printf 'absent\n' > "$ENGINE_STATE_FILE"
                if [ "${FAIL_STOP_AFTER_ROLLBACK_INSTALL:-0}" = 1 ]; then
                    printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
                    FAIL_STOP=1
                fi
                return 1
            fi
            if [ "${FAIL_RESTORE_PACKAGE_VERSION:-0}" = 1 ]; then
                printf 'current\n' > "$ENGINE_STATE_FILE"
            else
                printf 'previous\n' > "$ENGINE_STATE_FILE"
            fi
            printf 'restored\n' > "$PAYLOAD_STATE_FILE"
            ;;
        install)
            if [ "$2" = "$TMP_ENGINE_DIR/new.ipk" ]; then
                printf 'candidate-install\n' >> "$OPKG_ACTIONS"
                if [ "${FAIL_CANDIDATE_INSTALL:-0}" = 1 ]; then
                    printf 'previous-mismatch\n' > "$ENGINE_STATE_FILE"
                    return 1
                fi
                printf 'current\n' > "$ENGINE_STATE_FILE"
            else
                [ "$2" = "${ENGINE_RECOVERY_PACKAGE:-$TMP_ENGINE_DIR/rollback.ipk}" ] || return 1
                printf 'install\n' >> "$OPKG_ACTIONS"
                printf 'previous\n' > "$ENGINE_STATE_FILE"
            fi
            ;;
        *) return 1 ;;
    esac
}
service() {
    printf '%s %s\n' "$1" "$2" >> "$work_dir/service-actions"
    case "$2" in
        stop)
            if [ "${FAIL_STOP:-0}" = 1 ]; then
                [ "${STOP_WITH_ERROR_BUT_STOPPED:-0}" = 1 ] && printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE"
                return 1
            fi
            printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE"
            ;;
        restart)
            [ "${FAIL_RESTART:-0}" != 1 ] || return 1
            printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
            ;;
        start)
            [ "${FAIL_START:-0}" != 1 ] || return 1
            printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
            ;;
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
sleep() { :; }
wait_for_engine_health() { [ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] && [ "${FAIL_HEALTH:-0}" != 1 ]; }
log() { printf '%s\n' "$*" >> "$work_dir/log"; }

: > "$work_dir/service-actions"
printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_START=1
if start_podkop_and_check; then echo 'FAIL: start helper accepted a failed service command' >&2; exit 1; fi
unset FAIL_START
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: failed start changed mocked runtime state' >&2; exit 1; }
echo 'PASS: start helper rejects a failed service command'

: > "$work_dir/service-actions"
printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_SING_BOX_CHECK=1
export FAIL_SING_BOX_CHECK
if start_podkop_and_check; then echo 'FAIL: start helper accepted an invalid sing-box config' >&2; exit 1; fi
unset FAIL_SING_BOX_CHECK
printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE"
echo 'PASS: start helper rejects config-check failure after start'

: > "$work_dir/service-actions"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_STOP=1
if stop_podkop_and_verify; then echo 'FAIL: running Podkop was accepted after stop failure' >&2; exit 1; fi
unset FAIL_STOP
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: failed stop changed mocked runtime state' >&2; exit 1; }
echo 'PASS: failed stop with live process is rejected before package changes'

: > "$work_dir/service-actions"
FAIL_STOP=1
STOP_WITH_ERROR_BUT_STOPPED=1
if ! stop_podkop_and_verify; then echo 'FAIL: verified-stopped Podkop was rejected solely for service exit status' >&2; exit 1; fi
unset FAIL_STOP STOP_WITH_ERROR_BUT_STOPPED
echo 'PASS: nonzero stop status is accepted only when process and ports are confirmed down'

: > "$work_dir/service-actions"
FAIL_RESTART=1
if restart_podkop_and_check; then echo 'FAIL: restart helper accepted a failed service command' >&2; exit 1; fi
unset FAIL_RESTART
grep -q '^podkop restart$' "$work_dir/service-actions" || { echo 'FAIL: restart helper did not invoke Podkop restart' >&2; exit 1; }
echo 'PASS: restart helper rejects a failed service command'

printf 'previous\n' > "$ENGINE_STATE_FILE"
printf 'corrupted\n' > "$PAYLOAD_STATE_FILE"
if ! restore_podkop_engine; then echo 'FAIL: healthy previous package did not recover' >&2; exit 1; fi
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: prior engine state changed' >&2; exit 1; }
[ "$(cat "$PAYLOAD_STATE_FILE")" = restored ] || { echo 'FAIL: intact-version rollback did not restore other package payload files' >&2; exit 1; }
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'reinstall ' ] || { echo 'FAIL: already-previous package was not restored from the verified IPK' >&2; exit 1; }
echo 'PASS: already-previous package is reinstalled from the verified rollback IPK'

: > "$OPKG_ACTIONS"
printf 'current\n' > "$ENGINE_STATE_FILE"
if ! restore_podkop_engine; then echo 'FAIL: current package was not rolled back' >&2; exit 1; fi
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: previous package version was not restored' >&2; exit 1; }
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'downgrade-install ' ] || { echo 'FAIL: rollback did not use package-manager downgrade transaction' >&2; exit 1; }
echo 'PASS: candidate engine is downgraded transactionally to the exact previous package'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
printf 'current\n' > "$ENGINE_STATE_FILE"
FAIL_ROLLBACK_INSTALL=1
if restore_podkop_engine; then echo 'FAIL: rollback install failure was reported as success' >&2; exit 1; fi
unset FAIL_ROLLBACK_INSTALL
[ "$(cat "$ENGINE_STATE_FILE")" = current ] || { echo 'FAIL: failed downgrade unexpectedly changed package state' >&2; exit 1; }
grep -q '^podkop stop$' "$work_dir/service-actions" || { echo 'FAIL: Podkop was not stopped after rollback install failure' >&2; exit 1; }
! grep -q '^remove$' "$OPKG_ACTIONS" || { echo 'FAIL: rollback removed the current package before downgrade' >&2; exit 1; }
echo 'PASS: failed rollback transaction leaves package intact and stops Podkop'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
printf 'previous-mismatch\n' > "$ENGINE_STATE_FILE"
if ! restore_podkop_engine; then echo 'FAIL: verified rollback package did not repair same-version binary mismatch' >&2; exit 1; fi
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: same-version mismatch rollback did not restore previous binary' >&2; exit 1; }
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'reinstall ' ] || { echo 'FAIL: same-version mismatch did not use exact package reinstall' >&2; exit 1; }
echo 'PASS: same-version package/binary mismatch is repaired by exact rollback reinstall'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
printf 'previous-mismatch\n' > "$ENGINE_STATE_FILE"
FAIL_ROLLBACK_INSTALL=1
if restore_podkop_engine; then echo 'FAIL: failed same-version reinstall was reported as success' >&2; exit 1; fi
unset FAIL_ROLLBACK_INSTALL
[ "$(cat "$ENGINE_STATE_FILE")" = absent ] || { echo 'FAIL: reinstall-failure simulation did not leave the expected partial state' >&2; exit 1; }
grep -q '^podkop stop$' "$work_dir/service-actions" || { echo 'FAIL: Podkop was not stopped after force-reinstall failure' >&2; exit 1; }
echo 'PASS: failed force-reinstall stops Podkop even if package state is partial'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
printf 'current\n' > "$ENGINE_STATE_FILE"
FAIL_HEALTH=1
if restore_podkop_engine; then echo 'FAIL: rollback health failure was reported as success' >&2; exit 1; fi
unset FAIL_HEALTH
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: rollback package was not installed before health check' >&2; exit 1; }
grep -q '^podkop stop$' "$work_dir/service-actions" || { echo 'FAIL: Podkop was not stopped after rollback health failure' >&2; exit 1; }
echo 'PASS: failed rollback health check stops Podkop'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
printf 'previous\n' > "$ENGINE_STATE_FILE"
FAIL_RESTART=1
if restore_podkop_engine; then echo 'FAIL: failed service restart was reported as success' >&2; exit 1; fi
unset FAIL_RESTART
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'reinstall ' ] || { echo 'FAIL: previous package was not restored before detecting restart failure' >&2; exit 1; }
grep -q '^podkop stop$' "$work_dir/service-actions" || { echo 'FAIL: Podkop was not stopped after restart failure' >&2; exit 1; }
echo 'PASS: previous package is reinstalled, restart failure is detected, and Podkop stopped'

rm -f "$TMP_ENGINE_DIR/rollback.ipk"
: > "$work_dir/service-actions"
printf 'current\n' > "$ENGINE_STATE_FILE"
if restore_podkop_engine; then echo 'FAIL: missing rollback package was reported as success' >&2; exit 1; fi
grep -q '^podkop stop$' "$work_dir/service-actions" || { echo 'FAIL: Podkop was not stopped when rollback package was missing' >&2; exit 1; }
echo 'PASS: missing rollback package stops Podkop'
touch "$TMP_ENGINE_DIR/rollback.ipk"

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_OPKG_LIST=1
if restore_podkop_engine; then echo 'FAIL: opkg list failure was reported as successful rollback' >&2; exit 1; fi
unset FAIL_OPKG_LIST
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: package changed after opkg list failure' >&2; exit 1; }
echo 'PASS: installed-package query failure blocks rollback package mutation'

: > "$OPKG_ACTIONS"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_OPKG_STATUS_AT=1
if restore_podkop_engine; then echo 'FAIL: installed package-status failure was reported as success' >&2; exit 1; fi
unset FAIL_OPKG_STATUS_AT
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: package changed after installed status query failure' >&2; exit 1; }
echo 'PASS: installed package-status failure blocks rollback package mutation'

: > "$OPKG_ACTIONS"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_OPKG_STATUS_AT=2
if restore_podkop_engine; then echo 'FAIL: restored package-status query failure was reported as success' >&2; exit 1; fi
unset FAIL_OPKG_STATUS_AT
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { printf 'FAIL: restored status query failure left state=%s actions=%s status_calls=%s\n' "$(cat "$ENGINE_STATE_FILE")" "$(tr '\n' ' ' < "$OPKG_ACTIONS")" "$(cat "$OPKG_STATUS_COUNT_FILE")" >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: Podkop was not stopped after restored status query failure' >&2; exit 1; }
echo 'PASS: restored package-status query failure stops Podkop'

: > "$OPKG_ACTIONS"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_RESTORE_PACKAGE_VERSION=1
if restore_podkop_engine; then echo 'FAIL: wrong restored package version was reported as success' >&2; exit 1; fi
unset FAIL_RESTORE_PACKAGE_VERSION
[ "$(cat "$ENGINE_STATE_FILE")" = current ] || { echo 'FAIL: package-version mismatch fixture was not preserved' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: Podkop was not stopped after restored package version mismatch' >&2; exit 1; }
echo 'PASS: restored package version mismatch is rejected and Podkop stopped'

: > "$OPKG_ACTIONS"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
FAIL_RESTORED_BINARY=1
export FAIL_RESTORED_BINARY
if restore_podkop_engine; then echo 'FAIL: mismatched restored binary was reported as success' >&2; exit 1; fi
unset FAIL_RESTORED_BINARY
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: binary-mismatch fixture did not retain previous package' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: Podkop was not stopped after restored binary mismatch' >&2; exit 1; }
echo 'PASS: restored binary version mismatch is rejected and Podkop stopped'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
touch "$TMP_ENGINE_DIR/rollback.ipk" "$TMP_ENGINE_DIR/new.ipk"
printf 'previous\n' > "$ENGINE_STATE_FILE"
printf 'corrupted\n' > "$PAYLOAD_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_ORIGIN='podkop-engine'
ENGINE_PREVIOUS_VERSION='1.14.4-r27'
TESTED_ENGINE_VERSION='1.14.4-r28'
ENGINE_SWITCH_ACTIVE='0'
FAIL_CANDIDATE_INSTALL=1
if install_candidate_engine; then echo 'FAIL: failed candidate installation was reported as success' >&2; exit 1; fi
unset FAIL_CANDIDATE_INSTALL
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: candidate install failure did not restore the previous package' >&2; exit 1; }
[ "$(cat "$PAYLOAD_STATE_FILE")" = restored ] || { echo 'FAIL: candidate failure did not restore previous package payload' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: successful rollback did not restart Podkop' >&2; exit 1; }
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'candidate-install reinstall ' ] || { echo 'FAIL: candidate failure did not dispatch the verified rollback transaction' >&2; exit 1; }
[ "$ENGINE_SWITCH_ACTIVE" = '0' ] || { echo 'FAIL: completed rollback left engine switch marked active' >&2; exit 1; }
echo 'PASS: candidate install failure dispatches and verifies exact package rollback end-to-end'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'previous\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_SWITCH_ACTIVE='0'
if ! install_candidate_engine; then echo 'FAIL: valid candidate package transaction was rejected' >&2; exit 1; fi
[ "$(cat "$ENGINE_STATE_FILE")" = current ] || { echo 'FAIL: successful candidate transaction did not retain target package' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: successful candidate transaction did not restart Podkop' >&2; exit 1; }
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'candidate-install ' ] || { echo 'FAIL: successful candidate transaction unexpectedly ran rollback' >&2; exit 1; }
echo 'PASS: candidate install path verifies package/binary and restarts Podkop'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'previous\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_SWITCH_ACTIVE='0'
FAIL_CANDIDATE_BINARY=1
export FAIL_CANDIDATE_BINARY
if install_candidate_engine; then echo 'FAIL: candidate binary mismatch was reported as success' >&2; exit 1; fi
unset FAIL_CANDIDATE_BINARY
[ "$(cat "$ENGINE_STATE_FILE")" = previous ] || { echo 'FAIL: candidate binary mismatch did not roll package back' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: candidate binary mismatch rollback did not restart Podkop' >&2; exit 1; }
[ "$(tr '\n' ' ' < "$OPKG_ACTIONS")" = 'candidate-install downgrade-install ' ] || { echo 'FAIL: candidate binary mismatch did not use verified rollback transaction' >&2; exit 1; }
echo 'PASS: candidate binary mismatch dispatches rollback and restores prior running state'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_ORIGIN='podkop-engine'
ENGINE_PREVIOUS_VERSION='1.14.4-r27'
ENGINE_SWITCH_ACTIVE='1'
FAIL_ROLLBACK_INSTALL=1
if rollback_engine_once; then echo 'FAIL: rollback_engine_once swallowed restore failure' >&2; exit 1; fi
unset FAIL_ROLLBACK_INSTALL
[ "$ENGINE_SWITCH_ACTIVE" = '1' ] || { echo 'FAIL: failed rollback cleared the active switch marker' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: failed rollback did not leave Podkop stopped' >&2; exit 1; }
ENGINE_SWITCH_ACTIVE='0'
echo 'PASS: rollback failure propagates and preserves active recovery state'

: > "$OPKG_ACTIONS"
: > "$work_dir/service-actions"
: > "$work_dir/log"
rm -f "$OPKG_STATUS_COUNT_FILE"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_ORIGIN='podkop-engine'
ENGINE_PREVIOUS_VERSION='1.14.4-r27'
ENGINE_SWITCH_ACTIVE='1'
ENGINE_RECOVERY_REQUIRED='0'
FAIL_ROLLBACK_INSTALL=1
FAIL_STOP_AFTER_ROLLBACK_INSTALL=1
TMP_PRIORITY="$work_dir/tmp-priority"
TMP_POOL="$work_dir/tmp-pool"
TMP_FINAL="$work_dir/tmp-final"
TMP_WRITTEN="$work_dir/tmp-written"
TMP_CURRENT="$work_dir/tmp-current"
LOCK_FILE="$work_dir/lock"
TMP_ENGINE_DIR="$work_dir/engine"
ENGINE_RECOVERY_DIR="$work_dir/persistent-recovery"
ENGINE_RECOVERY_PACKAGE="$ENGINE_RECOVERY_DIR/rollback.ipk"
ENGINE_RECOVERY_CREATED='1'
UNOWNED_BACKUP_STAGING=''
mkdir -p "$TMP_ENGINE_DIR" "$ENGINE_RECOVERY_DIR"
printf 'verified rollback fixture\n' > "$TMP_ENGINE_DIR/rollback.ipk"
printf 'verified persistent rollback fixture\n' > "$ENGINE_RECOVERY_PACKAGE"
printf 'origin=podkop-engine\nversion=1.14.4-r27\n' > "$ENGINE_RECOVERY_DIR/manifest"
cleanup_update
unset FAIL_ROLLBACK_INSTALL FAIL_STOP_AFTER_ROLLBACK_INSTALL FAIL_STOP
[ "$ENGINE_SWITCH_ACTIVE" = '1' ] || { echo 'FAIL: cleanup cleared the switch marker despite failed rollback' >&2; exit 1; }
[ "$ENGINE_RECOVERY_REQUIRED" = '1' ] || { echo 'FAIL: cleanup did not preserve recovery-required state after failed rollback' >&2; exit 1; }
[ -f "$TMP_ENGINE_DIR/rollback.ipk" ] || { echo 'FAIL: cleanup deleted the verified rollback artifact after recovery failed' >&2; exit 1; }
[ -f "$ENGINE_RECOVERY_PACKAGE" ] && [ -f "$ENGINE_RECOVERY_DIR/manifest" ] || { echo 'FAIL: cleanup deleted persistent recovery artifacts after recovery failed' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: mock runtime did not remain active after stop failure' >&2; exit 1; }
grep -q 'manual recovery required' "$work_dir/log" || { echo 'FAIL: cleanup did not record manual recovery requirement' >&2; exit 1; }
grep -q 'Podkop could not be confirmed stopped' "$work_dir/log" || { echo 'FAIL: cleanup claimed an unverified stopped state' >&2; exit 1; }
echo 'PASS: failed rollback retains recovery artifacts and reports unconfirmed live Podkop'

: > "$OPKG_ACTIONS"
AUTO_UPDATE_SING_BOX=1
if ensure_sing_box_updated; then
    echo 'FAIL: a later updater run ignored preserved recovery state' >&2
    exit 1
fi
[ ! -s "$OPKG_ACTIONS" ] || { echo 'FAIL: later updater run mutated packages despite recovery marker' >&2; exit 1; }
[ -f "$ENGINE_RECOVERY_PACKAGE" ] && [ -f "$ENGINE_RECOVERY_DIR/manifest" ] || { echo 'FAIL: later updater run removed retained recovery artifacts' >&2; exit 1; }
grep -q 'prior engine recovery artifact exists' "$work_dir/log" || { echo 'FAIL: later updater run did not report recovery gate' >&2; exit 1; }
echo 'PASS: retained failed-rollback artifact blocks the next updater invocation'

: > "$OPKG_ACTIONS"
: > "$work_dir/log"
printf 'current\n' > "$ENGINE_STATE_FILE"
printf 'running\\n' > "$PODKOP_RUN_STATE_FILE"
ENGINE_SWITCH_ACTIVE='1'
ENGINE_RECOVERY_REQUIRED='0'
ENGINE_RECOVERY_CREATED='0'
cleanup_update
[ "$ENGINE_SWITCH_ACTIVE" = '0' ] || { echo 'FAIL: successful cleanup did not clear restored switch marker' >&2; exit 1; }
[ -f "$ENGINE_RECOVERY_PACKAGE" ] && [ -f "$ENGINE_RECOVERY_DIR/manifest" ] || { echo 'FAIL: cleanup deleted a pre-existing recovery directory it did not create' >&2; exit 1; }
echo 'PASS: cleanup preserves pre-existing recovery artifacts not owned by this invocation'
