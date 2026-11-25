#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^release_asset_details\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 1) exit }
    END { if (blocks != 1) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: release asset validation function missing' >&2
    exit 1
fi
. "$function_file"

asset_name='podkop-engine_1.14.4-r28_openwrt_x86_64.ipk'
asset_url='https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/12345'
asset_digest='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
valid_json="$work_dir/valid.json"
jq -cn --arg name "$asset_name" --arg url "$asset_url" --arg digest "$asset_digest" \
    '{assets:[{name:$name,url:$url,digest:$digest,size:123456}]}' > "$valid_json"
expected=$(printf '%s\t%s\t%s' "$asset_url" "$asset_digest" 123456)
actual=$(release_asset_details "$valid_json" "$asset_name") || { echo 'FAIL: valid release asset was rejected' >&2; exit 1; }
[ "$actual" = "$expected" ] || { echo 'FAIL: valid release asset details differ' >&2; exit 1; }
echo 'PASS: exact release asset details parsed'

duplicate_json="$work_dir/duplicate.json"
jq -cn --arg name "$asset_name" --arg url "$asset_url" --arg digest "$asset_digest" \
    '{assets:[{name:$name,url:$url,digest:$digest,size:123456},{name:$name,url:$url,digest:$digest,size:123456}]}' > "$duplicate_json"
if release_asset_details "$duplicate_json" "$asset_name" >/dev/null; then
    echo 'FAIL: duplicate matching release assets were accepted' >&2
    exit 1
fi
echo 'PASS: duplicate matching release assets rejected'

missing_json="$work_dir/missing.json"
jq -cn '{assets:[]}' > "$missing_json"
if release_asset_details "$missing_json" "$asset_name" >/dev/null; then
    echo 'FAIL: missing release asset was accepted' >&2
    exit 1
fi
echo 'PASS: missing release asset rejected'

for invalid_json in "$work_dir/bad-size.json" "$work_dir/missing-digest.json"; do
    case "$invalid_json" in
        *bad-size*) jq -cn --arg name "$asset_name" --arg url "$asset_url" --arg digest "$asset_digest" '{assets:[{name:$name,url:$url,digest:$digest,size:0}]}' > "$invalid_json" ;;
        *) jq -cn --arg name "$asset_name" --arg url "$asset_url" '{assets:[{name:$name,url:$url,size:123456}]}' > "$invalid_json" ;;
    esac
    if release_asset_details "$invalid_json" "$asset_name" >/dev/null; then
        echo 'FAIL: malformed release asset metadata was accepted' >&2
        exit 1
    fi
done
echo 'PASS: invalid size and missing digest rejected'
