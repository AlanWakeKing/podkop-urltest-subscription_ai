#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
function_file="$work_dir/function.sh"
awk '
    $0 == "opkg_status_database_ready() {" { capture = 1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { exit }
' "$UPDATE_SCRIPT" > "$function_file"
[ -s "$function_file" ] || { echo 'FAIL: opkg DB guard missing from update.sh' >&2; exit 1; }
. "$function_file"

BASE_FILES_STATUS='Status: install ok installed'
INSTALLED_LIST='base-files - 1\nbusybox - 1'
FAIL_LIST_INSTALLED=0
opkg() {
    case "$1" in
        status)
            [ "$2" = base-files ] || return 1
            printf 'Package: base-files\nVersion: 1\n%s\n' "$BASE_FILES_STATUS"
            ;;
        list-installed)
            [ "$FAIL_LIST_INSTALLED" != 1 ] || return 1
            printf '%b\n' "$INSTALLED_LIST"
            ;;
        *) return 1 ;;
    esac
}

status_file="$work_dir/status"
if opkg_status_database_ready "$status_file"; then
    echo 'FAIL: missing status database accepted' >&2
    exit 1
fi
echo 'PASS: missing status database rejected'

: > "$status_file"
if opkg_status_database_ready "$status_file"; then
    echo 'FAIL: empty status database accepted' >&2
    exit 1
fi
echo 'PASS: empty status database rejected'

printf 'Package: base-files\nVersion: 1\nStatus: install user installed\n\nPackage: busybox\nVersion: 1\nStatus: install user installed\n' > "$status_file"
if ! opkg_status_database_ready "$status_file"; then
    echo 'FAIL: valid base-files package database rejected' >&2
    exit 1
fi
echo 'PASS: nonempty database with installed base-files accepted'

INSTALLED_LIST='busybox - 1'
if opkg_status_database_ready "$status_file"; then
    echo 'FAIL: installed-package listing without base-files accepted' >&2
    exit 1
fi
INSTALLED_LIST='base-files - 1\nbusybox - 1'
echo 'PASS: installed-package listing without base-files rejected'

FAIL_LIST_INSTALLED=1
if opkg_status_database_ready "$status_file"; then
    echo 'FAIL: failed list-installed query accepted' >&2
    exit 1
fi
FAIL_LIST_INSTALLED=0
echo 'PASS: failed installed-package query rejected'

printf 'Package: base-files\nVersion: 1\nStatus: install user installed\n\nPackage: base-files\nVersion: 2\nStatus: install user installed\n' > "$status_file"
if opkg_status_database_ready "$status_file"; then
    echo 'FAIL: duplicate package stanzas accepted' >&2
    exit 1
fi
echo 'PASS: duplicate package stanzas rejected'

BASE_FILES_STATUS='Status: deinstall user not-installed'
if opkg_status_database_ready "$status_file"; then
    echo 'FAIL: database without installed base-files accepted' >&2
    exit 1
fi
echo 'PASS: database without installed base-files rejected'
