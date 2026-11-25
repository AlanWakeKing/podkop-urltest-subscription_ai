#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^(persistent_overlay_mountpoint|persist_engine_recovery_package)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 2) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: persistent rollback artifact helpers missing' >&2
    exit 1
fi
. "$function_file"

df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    if [ "${TEST_DF_EXTRA_ROW:-0}" = 1 ]; then
        printf 'tmpfs 1000 1 999 1%% /tmp\n'
    fi
    printf 'overlay 20000 1 %s 1%% %s\n' "$TEST_OVERLAY_FREE_KB" "$TEST_OVERLAY_MOUNT"
}
wc() {
    if [ "${1:-}" = -c ] && [ -n "${MOCK_RECOVERY_BYTES:-}" ]; then
        printf '%s\n' "$MOCK_RECOVERY_BYTES"
    else
        command wc "$@"
    fi
}
log() { :; }

persist_test() { persist_engine_recovery_package "$1" "$2" "$3" "$4" "$5" "$mounts_file"; }

source_file="$work_dir/rollback.ipk"
overlay_mount="$work_dir/overlay"
mkdir -p "$overlay_mount"
mounts_file="$work_dir/mounts"
printf '/dev/test %s ext4 rw 0 0\n' "$overlay_mount" > "$mounts_file"
destination="$overlay_mount/persistent-recovery"
printf 'verified rollback package fixture\n' > "$source_file"
source_hash=$(sha256sum "$source_file" | cut -d ' ' -f1)
TEST_OVERLAY_FREE_KB=12001
TEST_OVERLAY_MOUNT="$overlay_mount"
ENGINE_RECOVERY_PACKAGE=''
if ! persist_test "$source_file" "$destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: sufficient persistent space rejected verified rollback artifact' >&2
    exit 1
fi
[ "$ENGINE_RECOVERY_PACKAGE" = "$destination/rollback.ipk" ] || { echo 'FAIL: helper returned wrong persistent package path' >&2; exit 1; }
[ -f "$ENGINE_RECOVERY_PACKAGE" ] || { echo 'FAIL: persistent rollback IPK missing' >&2; exit 1; }
[ "$(sha256sum "$ENGINE_RECOVERY_PACKAGE" | cut -d ' ' -f1)" = "$source_hash" ] || { echo 'FAIL: persistent rollback IPK hash differs' >&2; exit 1; }
grep -q '^origin=podkop-engine$' "$destination/manifest" || { echo 'FAIL: recovery manifest lacks package origin' >&2; exit 1; }
grep -q '^version=1.14.4-r27$' "$destination/manifest" || { echo 'FAIL: recovery manifest lacks exact version' >&2; exit 1; }
echo 'PASS: exact rollback IPK and manifest persist with verified hash'

printf '/dev/root / ext4 rw 0 0\n' > "$mounts_file"
TEST_OVERLAY_MOUNT="/"
rootfs_destination="$overlay_mount/rootfs-persistent-recovery"
if persist_test "$source_file" "$rootfs_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: root ext4 without an exact /overlay mount was accepted as persistent' >&2
    exit 1
fi
[ ! -e "$rootfs_destination" ] || { echo 'FAIL: recovery artifact was written to rootfs fallback' >&2; exit 1; }
printf '/dev/test %s ext4 rw 0 0\n' "$overlay_mount" > "$mounts_file"
TEST_OVERLAY_MOUNT="$overlay_mount"
echo 'PASS: root ext4 without a dedicated /overlay mount fails closed'

TEST_DF_EXTRA_ROW=1
extra_df_destination="$overlay_mount/extra-df-row-recovery"
if ! persist_test "$source_file" "$extra_df_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: overlay capacity parser assumed the overlay was df output row two' >&2
    exit 1
fi
unset TEST_DF_EXTRA_ROW
echo 'PASS: overlay capacity parser selects the exact mount row rather than a fixed df row'

insufficient_destination="$overlay_mount/insufficient-recovery"
TEST_OVERLAY_FREE_KB=12000
if persist_test "$source_file" "$insufficient_destination" "$overlay_mount" sing-box 1.12.22-r1; then
    echo 'FAIL: insufficient overlay space accepted for rollback artifact' >&2
    exit 1
fi
[ ! -e "$insufficient_destination" ] || { echo 'FAIL: destination created despite insufficient overlay space' >&2; exit 1; }
echo 'PASS: insufficient persistent space blocks recovery artifact write'

MOCK_RECOVERY_BYTES=999999999
TEST_OVERLAY_FREE_KB=988562
boundary_destination="$overlay_mount/boundary-recovery"
if persist_test "$source_file" "$boundary_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: 32-bit boundary capacity accepted below required reserve' >&2
    exit 1
fi
[ ! -e "$boundary_destination" ] || { echo 'FAIL: boundary preflight created recovery files' >&2; exit 1; }
unset MOCK_RECOVERY_BYTES
echo 'PASS: maximum bounded package size reserves space without arithmetic overflow'

MOCK_RECOVERY_BYTES=1000000000
TEST_OVERLAY_FREE_KB=20000
oversize_destination="$overlay_mount/oversize-recovery"
if persist_test "$source_file" "$oversize_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: package size above the safe decimal bound was accepted' >&2
    exit 1
fi
[ ! -e "$oversize_destination" ] || { echo 'FAIL: oversized package preflight created recovery files' >&2; exit 1; }
unset MOCK_RECOVERY_BYTES
echo 'PASS: oversized package size is rejected before arithmetic'

TEST_OVERLAY_FREE_KB=20000
misplaced_destination="$work_dir/outside-recovery"
if persist_test "$source_file" "$misplaced_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: recovery artifact outside the overlay mount was accepted' >&2
    exit 1
fi
[ ! -e "$misplaced_destination" ] || { echo 'FAIL: misplaced recovery destination was created' >&2; exit 1; }
echo 'PASS: recovery artifact destination must be a direct child of overlay'

TEST_OVERLAY_MOUNT="$work_dir"
unmounted_destination="$overlay_mount/unmounted-recovery"
if persist_test "$source_file" "$unmounted_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: non-mountpoint overlay path was accepted' >&2
    exit 1
fi
[ ! -e "$unmounted_destination" ] || { echo 'FAIL: recovery artifact was created without confirmed mountpoint' >&2; exit 1; }
TEST_OVERLAY_MOUNT="$overlay_mount"
echo 'PASS: recovery artifact requires confirmed persistent mountpoint'

printf 'tmpfs %s tmpfs rw 0 0\n' "$overlay_mount" > "$mounts_file"
nonpersistent_destination="$overlay_mount/nonpersistent-recovery"
if persist_test "$source_file" "$nonpersistent_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: volatile tmpfs mount was accepted as persistent recovery storage' >&2
    exit 1
fi
[ ! -e "$nonpersistent_destination" ] || { echo 'FAIL: recovery artifact was written to volatile tmpfs' >&2; exit 1; }
printf '/dev/test %s ext4 rw 0 0\n' "$overlay_mount" > "$mounts_file"
echo 'PASS: volatile tmpfs is rejected as recovery storage'

printf 'overlayfs / overlay rw 0 0\n' > "$mounts_file"
TEST_OVERLAY_MOUNT="/"
root_overlay_destination="$overlay_mount/root-overlay-recovery"
if persist_test "$source_file" "$root_overlay_destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: volatile overlay root was accepted as persistent recovery storage' >&2
    exit 1
fi
[ ! -e "$root_overlay_destination" ] || { echo 'FAIL: root overlay recovery artifact was created' >&2; exit 1; }
printf '/dev/test %s ext4 rw 0 0\n' "$overlay_mount" > "$mounts_file"
TEST_OVERLAY_MOUNT="$overlay_mount"
echo 'PASS: non-persistent overlay root is rejected'

printf 'old-recovery\n' > "$destination/preserved-marker"
TEST_OVERLAY_FREE_KB=20000
if persist_test "$source_file" "$destination" "$overlay_mount" podkop-engine 1.14.4-r27; then
    echo 'FAIL: existing recovery directory was overwritten' >&2
    exit 1
fi
[ "$(cat "$destination/preserved-marker")" = old-recovery ] || { echo 'FAIL: existing recovery contents changed' >&2; exit 1; }
echo 'PASS: pre-existing recovery directory is preserved and update refused'
