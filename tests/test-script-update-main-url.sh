#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
update_script=${1:-$SCRIPT_DIR/../update.sh}
expected='https://raw.githubusercontent.com/AlanWakeKing/podkop-urltest-subscription_ai/main/update.sh'
[ -f "$update_script" ] || { printf 'FAIL: updater not found: %s\n' "$update_script" >&2; exit 1; }

url_assignment_count=$(grep -c '^SCRIPT_UPDATE_URL=' "$update_script" || true)
[ "$url_assignment_count" -eq 1 ] || {
    printf 'FAIL: expected exactly one SCRIPT_UPDATE_URL assignment, found %s\n' "$url_assignment_count" >&2
    exit 1
}
actual=$(sed -n 's/^SCRIPT_UPDATE_URL="\([^"]*\)"$/\1/p' "$update_script")
[ "$actual" = "$expected" ] || {
    printf 'FAIL: production updater URL expected <%s>, got <%s>\n' "$expected" "$actual" >&2
    exit 1
}
printf 'PASS: exactly one production self-update URL targets main\n'
