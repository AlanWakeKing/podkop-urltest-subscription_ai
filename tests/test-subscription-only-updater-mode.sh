#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/../update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^(disable_software_updates|remove_legacy_update_cron|restart_cron|ensure_cron_job|run_updates_only|require_podkop_installed)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0 }
    END { if (blocks != 6) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: subscriptions-only control functions missing' >&2
    exit 1
fi
. "$function_file"

legacy_branch_precedes_install=$(awk '
    index($0, "run_updates_only || exit 1") { updates_line = NR }
    index($0, "require_podkop_installed || exit 1") { install_line = NR }
    END { if (updates_line > 0 && install_line > updates_line) print "yes"; else exit 1 }
' "$UPDATE_SCRIPT")
[ "$legacy_branch_precedes_install" = yes ] || {
    echo 'FAIL: legacy update cron could install Podkop before being disabled' >&2
    exit 1
}

log() { printf '%s\n' "$*" >> "$work_dir/log"; }
restart_cron() { :; }

AUTO_UPDATE_SCRIPT=1
AUTO_UPDATE_PODKOP=1
AUTO_UPDATE_SING_BOX=1
disable_software_updates
[ "$AUTO_UPDATE_SCRIPT" = 0 ] && [ "$AUTO_UPDATE_PODKOP" = 0 ] && [ "$AUTO_UPDATE_SING_BOX" = 0 ] || {
    echo 'FAIL: software-update flags were not forcibly disabled' >&2
    exit 1
}
echo 'PASS: script, Podkop and sing-box updates are disabled regardless of saved settings'

podkop_init="$work_dir/podkop-init"
: > "$podkop_init"
chmod +x "$podkop_init"
require_podkop_installed "$podkop_init"
rm -f "$podkop_init"
if require_podkop_installed "$podkop_init"; then
    echo 'FAIL: updater accepted a missing Podkop init script (could affect Forkop)' >&2
    exit 1
fi
grep -q 'does not manage Forkop' "$work_dir/log" || {
    echo 'FAIL: missing Podkop was not reported as an unsupported Forkop target' >&2
    exit 1
}
echo 'PASS: normal subscription path rejects Forkop instead of installing Podkop'

CRON_FILE="$work_dir/root.crontab"
CRON_SCHEDULE='0 */3 * * *'
CRON_COMMAND='/usr/bin/podkop-update >> /var/log/podkop-update.log 2>&1'
UPDATE_CRON_SCHEDULE='0 * * * *'
UPDATE_CRON_COMMAND='/usr/bin/podkop-update --updates-only >> /var/log/podkop-update.log 2>&1'
AUTO_INSTALL_CRON=1
printf '%s\n' \
    "$CRON_SCHEDULE $CRON_COMMAND" \
    "$UPDATE_CRON_SCHEDULE $UPDATE_CRON_COMMAND" \
    '15 2 * * * /root/other-job' > "$CRON_FILE"
: > "$work_dir/log"
run_updates_only
subscription_count=$(grep -Fc "$CRON_COMMAND" "$CRON_FILE" || true)
software_update_count=$(grep -Ec 'podkop-update[[:space:]]+--updates-only' "$CRON_FILE" || true)
other_job_count=$(grep -Fc '/root/other-job' "$CRON_FILE" || true)
[ "$subscription_count" -eq 1 ] && [ "$software_update_count" -eq 0 ] && [ "$other_job_count" -eq 1 ] || {
    echo 'FAIL: legacy update cron was not replaced by subscription-only cron' >&2
    exit 1
}
grep -q 'software updates are disabled' "$work_dir/log" || {
    echo 'FAIL: legacy --updates-only invocation did not report disabled software updates' >&2
    exit 1
}
echo 'PASS: legacy --updates-only invocation removes its software cron and preserves subscription cron'

AUTO_INSTALL_CRON=0
printf '%s\n' \
    '0 */3 * * * /usr/bin/podkop-update >> /var/log/podkop-update.log 2>&1' \
    '0 * * * * /usr/bin/podkop-update --updates-only >> /var/log/podkop-update.log 2>&1' \
    '15 2 * * * /root/other-job' > "$CRON_FILE"
ensure_cron_job
software_update_count=$(grep -Ec 'podkop-update[[:space:]]+--updates-only' "$CRON_FILE" || true)
subscription_count=$(grep -Fc '/usr/bin/podkop-update >> /var/log/podkop-update.log 2>&1' "$CRON_FILE" || true)
other_job_count=$(grep -Fc '/root/other-job' "$CRON_FILE" || true)
[ "$software_update_count" -eq 0 ] && [ "$subscription_count" -eq 1 ] && [ "$other_job_count" -eq 1 ] || {
    echo 'FAIL: disabling automatic subscription cron left legacy software-update cron behind' >&2
    exit 1
}
echo 'PASS: legacy software-update cron is removed even when subscription cron installation is disabled'
