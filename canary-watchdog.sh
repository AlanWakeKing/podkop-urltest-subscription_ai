#!/bin/sh
# Single-router canary safety timer. Only for an unowned sing-box migration.
# Usage: sh canary-watchdog.sh /tmp/pdk-canary.XXXXXX [seconds]
set -u
umask 077
D=${1:-}
SECONDS=${2:-1200}
B=/etc/podkop-update-sing-box-backup
case "$D:$SECONDS" in
    /tmp/pdk-canary:*|/tmp/pdk-canary.*:* ) ;;
    * ) echo 'invalid canary directory' >&2; exit 2 ;;
esac
case "$SECONDS" in ''|*[!0-9]*) echo 'invalid timer' >&2; exit 2 ;; esac
[ -d "$D" ] || exit 2
printf '%s\n' "$$" > "$D/watchdog.pid"
: > "$D/watchdog.ready"
sleep "$SECONDS"
if [ -e "$D/confirmed" ]; then
    echo 'Canary confirmed; watchdog did not roll back'
    exit 0
fi
# Never remove a package while the updater is still switching it. Give its
# TERM trap time to roll back; refuse a concurrent opkg operation if it hangs.
if [ -f "$D/update.pid" ]; then
    update_pid=$(cat "$D/update.pid")
    case "$update_pid" in
        ''|*[!0-9]*) echo 'Invalid updater PID; refusing concurrent rollback' >&2; exit 1 ;;
    esac
    if [ -r "/proc/$update_pid/cmdline" ] && grep -Fq "$D/run.sh" "/proc/$update_pid/cmdline"; then
        kill -TERM "$update_pid" 2>/dev/null
        n=0
        while [ "$n" -lt 60 ] && [ -r "/proc/$update_pid/cmdline" ] &&
            grep -Fq "$D/run.sh" "/proc/$update_pid/cmdline"; do
            sleep 1
            n=$((n+1))
        done
        if [ -r "/proc/$update_pid/cmdline" ] && grep -Fq "$D/run.sh" "/proc/$update_pid/cmdline"; then
            echo 'CRITICAL: updater still running; refusing concurrent opkg rollback' >&2
            exit 1
        fi
    fi
fi
if [ ! -f "$B/sing-box.gz" ] || [ ! -f "$B/sha256" ]; then
    echo 'No completed persistent backup; no package switch to roll back'
    exit 0
fi
expected=$(cat "$B/sha256") || exit 1
actual=$(gzip -dc "$B/sing-box.gz" | sha256sum | cut -d ' ' -f1)
if ! gzip -t "$B/sing-box.gz" 2>/dev/null || [ "$expected" != "$actual" ]; then
    echo 'CRITICAL: backup verification failed; cannot restore' >&2
    exit 1
fi
[ -e "$D/confirmed" ] && exit 0
echo 'Canary not confirmed; restoring original sing-box'
service podkop stop >/dev/null 2>&1
installed=$(opkg list-installed) || exit 1
if printf '%s\n' "$installed" | grep -q '^podkop-engine - '; then
    remove_rc=0
    opkg remove --force-depends podkop-engine >/dev/null 2>&1 || remove_rc=$?
    installed=$(opkg list-installed) || exit 1
    if printf '%s\n' "$installed" | grep -q '^podkop-engine - '; then
        echo "CRITICAL: could not remove podkop-engine (exit $remove_rc); original kept in backup" >&2
        exit 1
    fi
    [ "$remove_rc" -eq 0 ] || echo "Warning: opkg returned $remove_rc, but engine package is absent"
fi
installed=$(opkg list-installed) || exit 1
if printf '%s\n' "$installed" | grep -q '^podkop-engine - '; then
    echo 'CRITICAL: package still owns executable; refusing overwrite' >&2
    exit 1
fi
current=$(sha256sum /usr/bin/sing-box 2>/dev/null | cut -d ' ' -f1)
if [ "$current" = "$expected" ]; then
    echo 'Original binary is already restored; checking Podkop health'
    service podkop start >/dev/null 2>&1
else
    if ! gzip -dc "$B/sing-box.gz" > /usr/bin/sing-box ||
        ! chmod 755 /usr/bin/sing-box ||
        [ "$(sha256sum /usr/bin/sing-box | cut -d ' ' -f1)" != "$expected" ]; then
        echo 'CRITICAL: original binary restore failed' >&2
        exit 1
    fi
    [ ! -f "$B/sing-box.init" ] || cp -p "$B/sing-box.init" /etc/init.d/sing-box || exit 1
    [ ! -f "$B/sing-box.uci" ] || cp -p "$B/sing-box.uci" /etc/config/sing-box || exit 1
    [ ! -f "$B/config.json" ] || cp -p "$B/config.json" /etc/sing-box/config.json || exit 1
    service podkop start >/dev/null 2>&1
fi
n=0
while [ "$n" -lt 30 ]; do
    if podkop check_sing_box | jq -e '.sing_box_process_running == 1 and .sing_box_ports_listening == 1' >/dev/null 2>&1; then
        echo 'Original sing-box restored; Podkop process and ports healthy'
        exit 0
    fi
    n=$((n+1))
    sleep 1
done
echo 'CRITICAL: original binary restored but Podkop did not start' >&2
exit 1
