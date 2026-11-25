#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT
if ! awk '
    /^(persistent_overlay_mountpoint|engine_binary_version_for_package|engine_upgrade_action|engine_release_asset_url|ensure_sing_box_updated|install_candidate_engine|persist_engine_recovery_package)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 7) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: updater transaction functions missing' >&2
    exit 1
fi
. "$function_file"

OVERLAY_MOUNT="$work_dir/overlay"
ENGINE_RECOVERY_DIR="$OVERLAY_MOUNT/recovery"
ENGINE_MOUNTS_FILE="$work_dir/mounts"
mkdir -p "$OVERLAY_MOUNT" "$work_dir/bin"
printf '/dev/test %s ext4 rw 0 0\n' "$OVERLAY_MOUNT" > "$ENGINE_MOUNTS_FILE"
mktemp() {
    case "${1:-}" in
        /tmp/podkop-engine-upgrade.XXXXXX) command mktemp -d "$work_dir/engine-upgrade.XXXXXX" ;;
        *) command mktemp "$@" ;;
    esac
}

PACKAGE_VERSION='1.14.4-r27'
BINARY_VERSION='1.14.4-pdk-r27'
TESTED_ENGINE_VERSION='1.14.4-r28'
ENGINE_PREVIOUS_VERSION="$PACKAGE_VERSION"
ENGINE_ORIGIN='podkop-engine'
ENGINE_SWITCH_ACTIVE=0
ENGINE_RECOVERY_REQUIRED=0
ENGINE_RECOVERY_CREATED=0
AUTO_UPDATE_SING_BOX=1
PKG_MANAGER='opkg'
DB_READY=1
ENGINE_PRESENT=1
ENGINE_FULL_PRESENT=0
PODKOP_STATE="$work_dir/podkop-state"
printf 'running\n' > "$PODKOP_STATE"
OPKG_ACTIONS="$work_dir/opkg-actions"
LOG_FILE="$work_dir/log"
: > "$OPKG_ACTIONS"
: > "$LOG_FILE"

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
detect_package_manager() { PKG_MANAGER=opkg; }
opkg_status_database_ready() { [ "$DB_READY" = 1 ]; }
is_package_installed() {
    case "$1" in
        podkop-engine-full) [ "$ENGINE_FULL_PRESENT" = 1 ] ;;
        podkop-engine) [ "$ENGINE_PRESENT" = 1 ] ;;
        *) return 1 ;;
    esac
}
version_rank() {
    case "$1" in
        1.14.4-r27) printf '27\n' ;;
        1.14.4-r28) printf '28\n' ;;
        *) return 1 ;;
    esac
}
opkg() {
    case "$1" in
        status)
            [ "$2" = podkop-engine ] && [ "$ENGINE_PRESENT" = 1 ] || return 1
            printf 'Package: podkop-engine\nVersion: %s\nStatus: install user installed\n' "$PACKAGE_VERSION"
            ;;
        compare-versions)
            left_rank=$(version_rank "$2") || return 1
            right_rank=$(version_rank "$4") || return 1
            [ "$3" = '>=' ] && [ "$left_rank" -ge "$right_rank" ]
            ;;
        --noaction)
            [ "$2" = install ] && [ -f "$3" ] || return 1
            printf 'preflight %s\n' "$3" >> "$OPKG_ACTIONS"
            ;;
        install)
            [ -f "$2" ] || return 1
            printf 'install %s\n' "$2" >> "$OPKG_ACTIONS"
            PACKAGE_VERSION='1.14.4-r28'
            BINARY_VERSION='1.14.4-pdk-r28'
            ;;
        *) return 1 ;;
    esac
}
jsonfilter() {
    [ "$1" = -e ] || return 1
    printf '%s\n' 'https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/123'
}
wget() {
    output=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -qO|-O) output=$2; shift 2 ;;
            --header=*) shift ;;
            *) shift ;;
        esac
    done
    [ -n "$output" ] || return 1
    case "$output" in
        */release.json) printf '{"assets":[]}\n' > "$output" ;;
        */new.ipk) cp "$CANDIDATE_FIXTURE" "$output" ;;
        *) return 1 ;;
    esac
}
curl() {
    output=''
    while [ "$#" -gt 0 ]; do
        case "$1" in -o) output=$2; shift 2 ;; *) shift ;; esac
    done
    [ -n "$output" ] || return 1
    case "$output" in
        */release.json) printf '{"assets":[]}\n' > "$output" ;;
        */new.ipk) cp "$CANDIDATE_FIXTURE" "$output" ;;
        *) return 1 ;;
    esac
}
command -v curl >/dev/null 2>&1 || { echo 'FAIL: curl mock is not discoverable' >&2; exit 1; }

jq() { printf '\n'; }
ensure_jq_installed() { return 0; }
detect_opkg_engine_arch() { printf 'x86_64\n'; }
release_asset_details() {
    printf 'https://api.github.com/repos/podkop-net/podkop-engine/releases/assets/123\tsha256:%s\t%s\n' "$CANDIDATE_HASH" "$CANDIDATE_SIZE"
}
engine_tmp_space_ready() { return 0; }
verify_engine_ipk() {
    [ -s "$1" ] && [ "$2" = "$TESTED_ENGINE_VERSION" ] || return 1
    printf '%s\n' '#!/bin/sh' 'case "$1" in check) exit 0 ;; *) exit 0 ;; esac' > "$3"
    chmod 755 "$3"
}
engine_ipk_install_contracts_match() { [ -s "$1" ] && [ -s "$2" ]; }
download_engine_rollback_package() {
    rollback_file="$TMP_ENGINE_DIR/rollback.ipk"
    printf 'previous-engine-fixture\n' > "$rollback_file"
    persist_engine_recovery_package "$rollback_file" "$ENGINE_RECOVERY_DIR" "$OVERLAY_MOUNT" podkop-engine "$1" "$ENGINE_MOUNTS_FILE"
}
df() {
    path=''
    for arg do path=$arg; done
    case "$path" in
        "$OVERLAY_MOUNT") printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\noverlay 100000 1 99999 1%% %s\n' "$OVERLAY_MOUNT" ;;
        /tmp) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\ntmpfs 200000 1 199999 1%% /tmp\n' ;;
        *) return 1 ;;
    esac
}
stop_podkop_and_verify() { printf 'stopped\n' > "$PODKOP_STATE"; return 0; }
restart_podkop_and_check() {
    [ "$PACKAGE_VERSION" = "$TESTED_ENGINE_VERSION" ] &&
        [ "$BINARY_VERSION" = '1.14.4-pdk-r28' ] || return 1
    printf 'running\n' > "$PODKOP_STATE"
}
cat > "$work_dir/bin/sing-box" <<'EOF'
#!/bin/sh
printf 'sing-box version %s\n' "$BINARY_VERSION"
EOF
chmod 755 "$work_dir/bin/sing-box"
PATH="$work_dir/bin:$PATH"
export PATH BINARY_VERSION

CANDIDATE_FIXTURE="$work_dir/candidate.ipk"
printf 'candidate-engine-fixture\n' > "$CANDIDATE_FIXTURE"
CANDIDATE_HASH=$(sha256sum "$CANDIDATE_FIXTURE" | cut -d ' ' -f1)
CANDIDATE_SIZE=$(wc -c < "$CANDIDATE_FIXTURE" | tr -d '[:space:]')
export CANDIDATE_FIXTURE CANDIDATE_HASH CANDIDATE_SIZE

actual_rc=0
ensure_sing_box_updated || actual_rc=$?
[ "$actual_rc" = 0 ] || { echo "FAIL: older-engine transaction returned $actual_rc" >&2; cat "$LOG_FILE" >&2; exit 1; }
[ "$PACKAGE_VERSION" = "$TESTED_ENGINE_VERSION" ] || { echo 'FAIL: package state did not reach target version' >&2; exit 1; }
[ "$BINARY_VERSION" = '1.14.4-pdk-r28' ] || { echo 'FAIL: binary state did not reach target version' >&2; exit 1; }
[ "$(cat "$PODKOP_STATE")" = running ] || { echo 'FAIL: runtime was not healthy after candidate install' >&2; exit 1; }
[ "$ENGINE_SWITCH_ACTIVE" = 0 ] || { echo 'FAIL: successful transaction retained switch-active marker' >&2; exit 1; }
grep -q '^preflight ' "$OPKG_ACTIONS" || { echo 'FAIL: opkg dependency preflight was skipped' >&2; exit 1; }
grep -q '^install .*new.ipk$' "$OPKG_ACTIONS" || { echo 'FAIL: candidate package was not installed' >&2; exit 1; }
[ -f "$ENGINE_RECOVERY_DIR/rollback.ipk" ] && [ -f "$ENGINE_RECOVERY_DIR/manifest" ] || { echo 'FAIL: rollback artifact was not staged before package mutation' >&2; exit 1; }
[ "$(awk '/^install / { print NR; exit }' "$OPKG_ACTIONS")" -gt "$(awk '/^preflight / { print NR; exit }' "$OPKG_ACTIONS")" ] || { echo 'FAIL: candidate mutation preceded package preflight' >&2; exit 1; }
echo 'PASS: older-engine updater path preflights, persists rollback, installs exact candidate, verifies, and restarts'
