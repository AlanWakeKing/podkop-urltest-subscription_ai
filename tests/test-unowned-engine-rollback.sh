#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^(start_podkop_and_check|stop_podkop_and_verify|restore_unowned_sing_box)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 3) exit }
    END { if (blocks != 3) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: unowned rollback functions missing' >&2
    exit 1
fi
. "$function_file"

UNOWNED_BACKUP_DIR="$work_dir/backup"
binary_path="$work_dir/usr-bin-sing-box"
init_path="$work_dir/etc-init-sing-box"
uci_path="$work_dir/etc-config-sing-box"
config_path="$work_dir/etc-sing-box-config.json"
PODKOP_RUN_STATE_FILE="$work_dir/runtime"
mkdir -p "$UNOWNED_BACKUP_DIR"
cat > "$UNOWNED_BACKUP_DIR/sing-box" <<'BIN'
#!/bin/sh
case "$1" in
    version) printf 'sing-box version 1.12.22\n' ;;
    check) [ -s "$3" ] && [ "$(cat "$3")" = valid ] ;;
    *) exit 1 ;;
esac
BIN
chmod 755 "$UNOWNED_BACKUP_DIR/sing-box"
gzip -c "$UNOWNED_BACKUP_DIR/sing-box" > "$UNOWNED_BACKUP_DIR/sing-box.gz"
sha256sum "$UNOWNED_BACKUP_DIR/sing-box" | cut -d ' ' -f1 > "$UNOWNED_BACKUP_DIR/sha256"
printf 'init-original\n' > "$UNOWNED_BACKUP_DIR/sing-box.init"
printf 'uci-original\n' > "$UNOWNED_BACKUP_DIR/sing-box.uci"
printf 'valid\n' > "$UNOWNED_BACKUP_DIR/config.json"
printf '#!/bin/sh\necho candidate\n' > "$binary_path"
chmod 755 "$binary_path"
printf 'init-candidate\n' > "$init_path"
printf 'uci-candidate\n' > "$uci_path"
printf 'invalid\n' > "$config_path"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"

opkg() {
    [ "$1" = list-installed ] && return 0
    return 1
}
service() {
    case "$2" in
        stop) printf 'stopped\n' > "$PODKOP_RUN_STATE_FILE" ;;
        start) printf 'running\n' > "$PODKOP_RUN_STATE_FILE" ;;
        *) return 1 ;;
    esac
}
podkop() {
    [ "$1" = check_sing_box ] || return 1
    if [ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ]; then
        printf '{"sing_box_process_running":1,"sing_box_ports_listening":1}\n'
    else
        printf '{"sing_box_process_running":0,"sing_box_ports_listening":0}\n'
    fi
}
sleep() { :; }
FAIL_HEALTH=0
wait_for_engine_health() { [ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] && [ "$FAIL_HEALTH" != 1 ]; }
log() { :; }

restore_unowned_sing_box "$binary_path" "$UNOWNED_BACKUP_DIR" "$init_path" "$uci_path" "$config_path" || {
    echo 'FAIL: valid unowned backup was not restored' >&2
    exit 1
}
[ "$(sha256sum "$binary_path" | cut -d ' ' -f1)" = "$(cat "$UNOWNED_BACKUP_DIR/sha256")" ] || { echo 'FAIL: restored unowned binary hash differs' >&2; exit 1; }
[ "$(cat "$init_path")" = init-original ] || { echo 'FAIL: init script was not restored' >&2; exit 1; }
[ "$(cat "$uci_path")" = uci-original ] || { echo 'FAIL: UCI file was not restored' >&2; exit 1; }
[ "$(cat "$config_path")" = valid ] || { echo 'FAIL: config was not restored' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = running ] || { echo 'FAIL: Podkop did not start after unowned rollback' >&2; exit 1; }
echo 'PASS: unowned binary/init/UCI/config restored and health checked'

printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
printf 'bad-hash\n' > "$UNOWNED_BACKUP_DIR/sha256"
printf '#!/bin/sh\necho candidate\n' > "$binary_path"
chmod 755 "$binary_path"
candidate_hash=$(sha256sum "$binary_path" | cut -d ' ' -f1)
if restore_unowned_sing_box "$binary_path" "$UNOWNED_BACKUP_DIR" "$init_path" "$uci_path" "$config_path"; then
    echo 'FAIL: corrupt unowned backup checksum was accepted' >&2
    exit 1
fi
[ "$(sha256sum "$binary_path" | cut -d ' ' -f1)" = "$candidate_hash" ] || { echo 'FAIL: binary was changed before backup checksum validation' >&2; exit 1; }
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: corrupt backup did not leave Podkop stopped' >&2; exit 1; }
echo 'PASS: corrupt unowned backup is rejected before binary restoration'

sha256sum "$UNOWNED_BACKUP_DIR/sing-box" | cut -d ' ' -f1 > "$UNOWNED_BACKUP_DIR/sha256"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
printf 'invalid\n' > "$UNOWNED_BACKUP_DIR/config.json"
printf '#!/bin/sh\necho candidate\n' > "$binary_path"
chmod 755 "$binary_path"
if restore_unowned_sing_box "$binary_path" "$UNOWNED_BACKUP_DIR" "$init_path" "$uci_path" "$config_path"; then
    echo 'FAIL: invalid restored unowned config was accepted' >&2
    exit 1
fi
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: unowned config failure did not leave Podkop stopped' >&2; exit 1; }
echo 'PASS: unowned config failure stops Podkop and reports rollback failure'

printf 'valid\n' > "$UNOWNED_BACKUP_DIR/config.json"
printf 'running\n' > "$PODKOP_RUN_STATE_FILE"
printf '#!/bin/sh\necho candidate\n' > "$binary_path"
chmod 755 "$binary_path"
FAIL_HEALTH=1
if restore_unowned_sing_box "$binary_path" "$UNOWNED_BACKUP_DIR" "$init_path" "$uci_path" "$config_path"; then
    echo 'FAIL: unowned rollback accepted failed runtime health check' >&2
    exit 1
fi
[ "$(cat "$PODKOP_RUN_STATE_FILE")" = stopped ] || { echo 'FAIL: unowned runtime health failure did not leave Podkop stopped' >&2; exit 1; }
FAIL_HEALTH=0
echo 'PASS: unhealthy restored unowned runtime is rejected and stopped'
