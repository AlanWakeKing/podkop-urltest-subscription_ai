#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^(persistent_overlay_mountpoint|unowned_backup_overlay_space_ready)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 2) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: persistent overlay-space helpers missing' >&2
    exit 1
fi
. "$function_file"

TEST_OVERLAY_PATH="$work_dir/overlay"
mkdir -p "$TEST_OVERLAY_PATH"
export TEST_OVERLAY_PATH

df() {
    [ "$1" = -Pk ] && [ "$2" = "$TEST_OVERLAY_PATH" ] || return 1
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    case "${TEST_DF_MODE:-normal}" in
        normal) printf 'overlay 20000 1 %s 1%% %s\n' "$TEST_OVERLAY_FREE_KB" "$TEST_OVERLAY_PATH" ;;
        reordered)
            printf 'tmpfs 1000 1 999 1%% /tmp\n'
            printf 'overlay 20000 1 %s 1%% %s\n' "$TEST_OVERLAY_FREE_KB" "$TEST_OVERLAY_PATH"
            ;;
        duplicate)
            printf 'overlay 20000 1 %s 1%% %s\n' "$TEST_OVERLAY_FREE_KB" "$TEST_OVERLAY_PATH"
            printf 'overlay 20000 1 %s 1%% %s\n' "$TEST_OVERLAY_FREE_KB" "$TEST_OVERLAY_PATH"
            ;;
        missing) printf 'tmpfs 20000 1 %s 1%% /tmp\n' "$TEST_OVERLAY_FREE_KB" ;;
        malformed) printf 'overlay 20000 1 invalid 1%% %s\n' "$TEST_OVERLAY_PATH" ;;
        rootfs) printf 'rootfs 200000 1 %s 1%% /\n' "$TEST_OVERLAY_FREE_KB" ;;
        *) return 1 ;;
    esac
}

mounts_file="$work_dir/mounts"
printf '/dev/test %s ext4 rw 0 0\n' "$TEST_OVERLAY_PATH" > "$mounts_file"

TEST_OVERLAY_FREE_KB=12000
export TEST_OVERLAY_FREE_KB
unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH" || { echo 'FAIL: exact 12,000 KiB reserve was rejected' >&2; exit 1; }
echo 'PASS: overlay backup reserve accepts exact minimum'

printf '/dev/test %s nfs rw 0 0\n' "$TEST_OVERLAY_PATH" > "$mounts_file"
if persistent_overlay_mountpoint "$TEST_OVERLAY_PATH" "$mounts_file"; then
    echo 'FAIL: unrecognized network filesystem was accepted for persistent recovery' >&2
    exit 1
fi
printf '/dev/loop0 %s ext4 rw 0 0\n' "$TEST_OVERLAY_PATH" > "$mounts_file"
if persistent_overlay_mountpoint "$TEST_OVERLAY_PATH" "$mounts_file"; then
    echo 'FAIL: loop-backed ext4 mount was accepted for persistent recovery' >&2
    exit 1
fi
printf '/dev/test %s ext4 rw\n' "$TEST_OVERLAY_PATH" > "$mounts_file"
if persistent_overlay_mountpoint "$TEST_OVERLAY_PATH" "$mounts_file"; then
    echo 'FAIL: incomplete mount record was accepted for persistent recovery' >&2
    exit 1
fi
printf '/dev/test %s ext4 rw 0 0\n' "$TEST_OVERLAY_PATH" > "$mounts_file"

echo 'PASS: unsupported and loop-backed filesystem layouts fail closed'

TEST_DF_MODE=reordered
TEST_OVERLAY_FREE_KB=12000
export TEST_DF_MODE TEST_OVERLAY_FREE_KB
unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH" || { echo 'FAIL: overlay parser assumed df row two' >&2; exit 1; }
echo 'PASS: overlay parser selects exact mount row after unrelated rows'

TEST_DF_MODE=duplicate
TEST_OVERLAY_FREE_KB=99999
export TEST_DF_MODE TEST_OVERLAY_FREE_KB
if unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH"; then
    echo 'FAIL: duplicate /overlay df rows were accepted' >&2
    exit 1
fi
echo 'PASS: duplicate /overlay rows fail closed'

TEST_DF_MODE=missing
if unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH"; then
    echo 'FAIL: missing /overlay df row was accepted' >&2
    exit 1
fi
TEST_DF_MODE=malformed
if unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH"; then
    echo 'FAIL: malformed /overlay capacity was accepted' >&2
    exit 1
fi
unset TEST_DF_MODE
echo 'PASS: missing and malformed /overlay rows fail closed'

printf '/dev/root / ext4 rw 0 0\n' > "$mounts_file"
TEST_DF_MODE=rootfs
TEST_OVERLAY_FREE_KB=12000
export TEST_DF_MODE TEST_OVERLAY_FREE_KB
if unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH"; then
    echo 'FAIL: writable ext4 root without an exact overlay mount was accepted' >&2
    exit 1
fi
echo 'PASS: writable ext4 root without exact overlay mount fails closed'

symlink_target="$work_dir/overlay-symlink"
ln -s "$work_dir" "$symlink_target"
if persistent_overlay_mountpoint "$symlink_target" "$mounts_file"; then
    echo 'FAIL: symlinked recovery storage path was accepted' >&2
    exit 1
fi
regular_path="$work_dir/overlay-not-directory"
: > "$regular_path"
if persistent_overlay_mountpoint "$regular_path" "$mounts_file"; then
    echo 'FAIL: non-directory recovery storage path was accepted' >&2
    exit 1
fi

duplicate_mounts="$work_dir/duplicate-mounts"
printf '/dev/root / ext4 rw 0 0\n/dev/test %s ext4 rw 0 0\n/dev/other %s ext4 rw 0 0\n' "$TEST_OVERLAY_PATH" "$TEST_OVERLAY_PATH" > "$duplicate_mounts"
if persistent_overlay_mountpoint "$TEST_OVERLAY_PATH" "$duplicate_mounts"; then
    echo 'FAIL: duplicate /overlay mount records were accepted' >&2
    exit 1
fi

printf '/dev/test %s ext4 ro 0 0\n' "$TEST_OVERLAY_PATH" > "$mounts_file"
if persistent_overlay_mountpoint "$TEST_OVERLAY_PATH" "$mounts_file"; then
    echo 'FAIL: read-only exact /overlay mount was accepted' >&2
    exit 1
fi
printf '/dev/root / ext4 rw 0 0\n' > "$mounts_file"
printf '/dev/root / ext4 rw 0 0\n/dev/other / ext4 rw 0 0\n' > "$duplicate_mounts"
if persistent_overlay_mountpoint "$TEST_OVERLAY_PATH" "$duplicate_mounts"; then
    echo 'FAIL: duplicate root mount records were accepted' >&2
    exit 1
fi

echo 'PASS: symlinks, duplicate mounts, and read-only overlay mounts fail closed'

printf 'overlayfs / overlay rw 0 0\n' > "$mounts_file"
if unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH"; then
    echo 'FAIL: volatile overlay root was accepted for persistent backup' >&2
    exit 1
fi
printf '/dev/root / ext4 ro 0 0\n' > "$mounts_file"
if unowned_backup_overlay_space_ready "$mounts_file" "$TEST_OVERLAY_PATH"; then
    echo 'FAIL: read-only ext4 rootfs was accepted for persistent backup' >&2
    exit 1
fi
printf '/dev/test /overlay ext4 rw 0 0\n' > "$mounts_file"
unset TEST_DF_MODE
echo 'PASS: volatile and read-only rootfs layouts fail closed'

if grep -E 'df -Pk /overlay.*NR[[:space:]]*==[[:space:]]*2' "$UPDATE_SCRIPT" >/dev/null; then
    echo 'FAIL: fixed-row /overlay capacity parsing remains' >&2
    exit 1
fi
echo 'PASS: no fixed-row /overlay capacity parsing remains'
