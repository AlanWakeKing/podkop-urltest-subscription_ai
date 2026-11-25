#!/bin/sh
set -eu

UPDATE_SCRIPT=${1:-"$(dirname "$0")/../update.sh"}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/engine-package-replacement.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
function_file="$work_dir/functions.sh"

if ! awk '
    /^(remove_stock_sing_box_packages|install_candidate_engine)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 2) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: stock package replacement helpers are missing' >&2
    exit 1
fi
. "$function_file"

OPKG_ACTIONS="$work_dir/opkg-actions"
printf '' > "$OPKG_ACTIONS"
PACKAGE_STATE='sing-box sing-box-tiny'
REMOVE_RC=1
LEAVE_TINY=0
STATUS_FAIL=0
TESTED_ENGINE_VERSION='1.14.4-r29'
ENGINE_ORIGIN='stock'
ENGINE_SWITCH_ACTIVE=0
TMP_ENGINE_DIR="$work_dir/tmp"
mkdir -p "$TMP_ENGINE_DIR" "$work_dir/bin"
printf 'fixture' > "$TMP_ENGINE_DIR/new.ipk"
cat > "$work_dir/bin/sing-box" <<'MOCK_SING_BOX'
#!/bin/sh
echo 'sing-box version 1.14.4-pdk-r29'
MOCK_SING_BOX
chmod 700 "$work_dir/bin/sing-box"
PATH="$work_dir/bin:$PATH"
export PATH

log() { :; }
stop_podkop_and_verify() { printf 'stop\n' >> "$OPKG_ACTIONS"; return 0; }
restart_podkop_and_check() { printf 'restart\n' >> "$OPKG_ACTIONS"; return 0; }
rollback_engine_once() { printf 'rollback\n' >> "$OPKG_ACTIONS"; return 0; }
engine_binary_version_for_package() { printf '1.14.4-pdk-r29\n'; }

opkg() {
    command_name=$1
    shift
    case "$command_name" in
        remove)
            [ "$*" = '--force-depends sing-box sing-box-tiny' ] || {
                printf 'FAIL: unexpected removal command: opkg remove %s\n' "$*" >&2
                return 90
            }
            printf 'remove %s\n' "$*" >> "$OPKG_ACTIONS"
            if [ "$LEAVE_TINY" = 1 ]; then PACKAGE_STATE='sing-box-tiny'; else PACKAGE_STATE=''; fi
            return "$REMOVE_RC"
            ;;
        list-installed)
            [ "$STATUS_FAIL" != 1 ] || return 1
            [ -z "$PACKAGE_STATE" ] || printf '%s - fixture\n' "$PACKAGE_STATE"
            ;;
        install)
            printf 'install\n' >> "$OPKG_ACTIONS"
            PACKAGE_STATE='podkop-engine'
            ;;
        status)
            printf 'Package: podkop-engine\nVersion: 1.14.4-r29\nStatus: install user installed\n'
            ;;
        *)
            printf 'FAIL: unexpected opkg operation: %s\n' "$command_name" >&2
            return 91
            ;;
    esac
}

if ! install_candidate_engine; then
    echo 'FAIL: replacement should tolerate a nonzero remove result when both stock packages are absent' >&2
    exit 1
fi
expected=$(printf 'stop\nremove --force-depends sing-box sing-box-tiny\ninstall\nrestart')
actual=$(cat "$OPKG_ACTIONS")
[ "$actual" = "$expected" ] || {
    printf 'FAIL: unexpected operation sequence:\n%s\n' "$actual" >&2
    exit 1
}
[ "$ENGINE_SWITCH_ACTIVE" = 0 ] || { echo 'FAIL: successful replacement left switch active' >&2; exit 1; }

: > "$OPKG_ACTIONS"
PACKAGE_STATE='sing-box sing-box-tiny'
REMOVE_RC=0
LEAVE_TINY=1
ENGINE_SWITCH_ACTIVE=0
actual_rc=0
install_candidate_engine || actual_rc=$?
[ "$actual_rc" -ne 0 ] || { echo 'FAIL: remaining stock package did not block replacement' >&2; exit 1; }
case "$(cat "$OPKG_ACTIONS")" in
    *install*) echo 'FAIL: candidate install ran while stock package remained' >&2; exit 1 ;;
esac
case "$(cat "$OPKG_ACTIONS")" in
    *'remove --force-depends sing-box sing-box-tiny'*) ;;
    *) echo 'FAIL: stock package removal was not attempted' >&2; exit 1 ;;
esac

echo 'PASS: stock replacement removes both conflicting packages and fails closed if either remains'
