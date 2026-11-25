#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^opkg_info_package_size\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 1) exit }
    END { if (blocks != 1) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: opkg package size helper missing' >&2
    exit 1
fi
. "$function_file"

INFO_TEXT='Package: sing-box\nVersion: 1.12.21-r1\nSize: 100\n\nPackage: sing-box\nVersion: 1.12.22-r1\nSize: 12345\n'
FAIL_INFO=0
opkg() {
    [ "$1" = info ] && [ "$2" = sing-box ] || return 1
    [ "$FAIL_INFO" != 1 ] || return 1
    printf '%b' "$INFO_TEXT"
}

[ "$(opkg_info_package_size sing-box 1.12.22-r1)" = 12345 ] || { echo 'FAIL: exact opkg asset size not selected' >&2; exit 1; }
echo 'PASS: exact package version size selected from opkg metadata'

INFO_TEXT='Package: sing-box\nVersion: 1.12.22-r1\nSize: 12345\n\nPackage: sing-box\nVersion: 1.12.22-r1\nSize: 12345\n'
if opkg_info_package_size sing-box 1.12.22-r1 >/dev/null; then
    echo 'FAIL: duplicate exact package metadata accepted' >&2
    exit 1
fi
echo 'PASS: duplicate exact package metadata rejected'

INFO_TEXT='Package: sing-box\nVersion: 1.12.22-r1\n'
if opkg_info_package_size sing-box 1.12.22-r1 >/dev/null; then
    echo 'FAIL: missing package size accepted' >&2
    exit 1
fi
echo 'PASS: missing package size rejected'

INFO_TEXT='Package: sing-box\nVersion: 1.12.22-r1\nSize: huge\n'
if opkg_info_package_size sing-box 1.12.22-r1 >/dev/null; then
    echo 'FAIL: malformed package size accepted' >&2
    exit 1
fi
echo 'PASS: malformed package size rejected'

FAIL_INFO=1
if opkg_info_package_size sing-box 1.12.22-r1 >/dev/null; then
    echo 'FAIL: failed opkg info query accepted' >&2
    exit 1
fi
echo 'PASS: failed opkg info query rejected'
