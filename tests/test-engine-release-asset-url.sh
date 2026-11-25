#!/bin/sh
set -eu

UPDATE_SCRIPT=${1:-"$(dirname "$0")/../update.sh"}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/engine-release-url.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
function_file="$work_dir/functions.sh"

if ! awk '
    $0 == "engine_release_asset_url() {" { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 1) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: engine_release_asset_url() is missing from update.sh' >&2
    exit 1
fi
. "$function_file"

json_file="$work_dir/release.json"
printf '{"assets":[]}\n' > "$json_file"
asset_name='podkop-engine_1.14.4-r29_openwrt_x86_64.ipk'
expected='https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/12345'
JSONFILTER_MODE=valid
jsonfilter() {
    [ "$1" = -e ] || return 90
    [ "$2" = "@.assets[@.name='$asset_name'].url" ] || return 91
    case "$JSONFILTER_MODE" in
        valid) printf '%s\n' "$expected" ;;
        duplicate) printf '%s\n%s\n' "$expected" "$expected" ;;
        unsafe) printf '%s\n' 'https://attacker.example/asset' ;;
        empty) return 1 ;;
        *) return 92 ;;
    esac
}

actual=$(engine_release_asset_url "$json_file" "$asset_name") || {
    echo 'FAIL: valid release asset URL was rejected' >&2
    exit 1
}
[ "$actual" = "$expected" ] || { echo 'FAIL: asset URL differs from selected API asset' >&2; exit 1; }

for mode in duplicate unsafe empty; do
    JSONFILTER_MODE=$mode
    if engine_release_asset_url "$json_file" "$asset_name" >/dev/null; then
        printf 'FAIL: %s release asset URL was accepted\n' "$mode" >&2
        exit 1
    fi
done

JSONFILTER_MODE=valid
if engine_release_asset_url "$json_file" "bad'name.ipk" >/dev/null; then
    echo 'FAIL: untrusted asset name was accepted' >&2
    exit 1
fi

echo 'PASS: selected GitHub asset URL is unique and host-validated'
