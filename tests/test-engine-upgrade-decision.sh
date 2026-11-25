#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
fn_file=$(mktemp)
trap 'rm -f "$fn_file"' EXIT
awk '
    /^(engine_binary_version_for_package|engine_upgrade_action)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 2) exit }
' "$UPDATE_SCRIPT" > "$fn_file"
if [ ! -s "$fn_file" ]; then
    echo 'FAIL: engine version decision functions are missing from update.sh' >&2
    exit 1
fi
. "$fn_file"

TESTED_ENGINE_VERSION='1.14.4-r29'
opkg() {
    [ "$1" = 'compare-versions' ] || return 1
    left=$2
    operator=$3
    right=$4
    case "$left:$operator:$right" in
        'unknown:>=:unknown'|'1.14.4-r27:>=:1.14.4-r29'|'1.14.4-r28:>=:1.14.4-r29'|'1.14.4-r29:>=:1.14.4-r30') return 1 ;;
        '1.14.4-r27:>=:1.14.4-r27'|'1.14.4-r28:>=:1.14.4-r28'|'1.14.4-r29:>=:1.14.4-r29'|'1.14.4-r30:>=:1.14.4-r30'|'1.14.4-r30:>=:1.14.4-r29') return 0 ;;
        *) echo "unexpected version comparison: $left $operator $right" >&2; return 2 ;;
    esac
}

assert_action() {
    label=$1
    package_version=$2
    binary_version=$3
    expected=$4
    actual=$(engine_upgrade_action "$package_version" "$binary_version")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s -> %s\n' "$label" "$actual"
}

assert_action 'older patched engine is upgraded' '1.14.4-r28' 'sing-box version 1.14.4-pdk-r28' 'upgrade'
assert_action 'target engine remains unchanged' '1.14.4-r29' 'sing-box version 1.14.4-pdk-r29' 'current'
assert_action 'newer patched engine is preserved' '1.14.4-r30' 'sing-box version 1.14.4-pdk-r30' 'newer'
assert_action 'package/binary mismatch is not changed automatically' '1.14.4-r28' 'sing-box version 1.14.4-pdk-r29' 'unverified'
assert_action 'malformed package version is not changed automatically' 'unknown' 'sing-box version unknown' 'unverified'

restore_file=$(mktemp)
trap 'rm -f "$fn_file" "$restore_file"' EXIT
awk '
    $0 == "restore_previous_sing_box() {" { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
' "$UPDATE_SCRIPT" > "$restore_file"
if [ ! -s "$restore_file" ]; then
    echo 'FAIL: restore_previous_sing_box() is missing from update.sh' >&2
    exit 1
fi
. "$restore_file"
restore_podkop_engine() { printf 'podkop-rollback'; }
restore_stock_sing_box() { printf 'stock-rollback'; }
restore_unowned_sing_box() { printf 'unowned-rollback'; }
log() { :; }
service() { :; }
ENGINE_ORIGIN='podkop-engine'
if restore_output=$(restore_previous_sing_box); then restore_rc=0; else restore_rc=$?; fi
if [ "$restore_rc" -ne 0 ] || [ "$restore_output" != 'podkop-rollback' ]; then
    printf 'FAIL: existing-engine rollback dispatch: rc=%s output=<%s>\n' "$restore_rc" "$restore_output" >&2
    exit 1
fi
printf '%s\n' 'PASS: existing podkop-engine dispatches to package rollback'

ENGINE_ORIGIN='stock'
if [ "$(restore_previous_sing_box)" != 'stock-rollback' ]; then
    echo 'FAIL: stock sing-box rollback dispatch changed' >&2
    exit 1
fi
printf '%s\n' 'PASS: stock sing-box still dispatches to its rollback'

ENGINE_ORIGIN='unowned'
if [ "$(restore_previous_sing_box)" != 'unowned-rollback' ]; then
    echo 'FAIL: unowned sing-box rollback dispatch changed' >&2
    exit 1
fi
printf '%s\n' 'PASS: unowned sing-box still dispatches to its backup rollback'
