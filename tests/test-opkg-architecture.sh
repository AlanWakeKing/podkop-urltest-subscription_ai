#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"

fn_file=$(mktemp)
trap 'rm -f "$fn_file"' EXIT
awk '
    $0 == "detect_opkg_engine_arch() {" { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
' "$UPDATE_SCRIPT" > "$fn_file"
if [ ! -s "$fn_file" ]; then
    echo 'FAIL: detect_opkg_engine_arch() is missing from update.sh' >&2
    exit 1
fi
. "$fn_file"

opkg() {
    [ "$1" = "print-architecture" ] || return 1
    printf '%s' "$OPKG_ARCH_FIXTURE"
}

assert_arch() {
    label=$1
    fixture=$2
    expected=$3
    OPKG_ARCH_FIXTURE=$fixture
    actual=$(detect_opkg_engine_arch)
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s -> %s\n' "$label" "$actual"
}

assert_arch 'OpenWrt opkg output with arch prefix' 'arch all 1
arch noarch 1
arch aarch64_cortex-a53 10' 'aarch64_cortex-a53'
assert_arch 'OpenWrt opkg output without arch prefix' 'all 1
noarch 1
aarch64_cortex-a53 10' 'aarch64_cortex-a53'
assert_arch 'universal-only output has no target architecture' 'arch all 1
arch noarch 1' ''

update_url=$(sed -n 's/^SCRIPT_UPDATE_URL="\([^"]*\)"$/\1/p' "$UPDATE_SCRIPT")
case "$update_url" in
    */canary-singbox-r28/update.sh) echo 'PASS: canary self-update stays on canary branch' ;;
    *) printf 'FAIL: canary self-update points to <%s>\n' "$update_url" >&2; exit 1 ;;
esac
