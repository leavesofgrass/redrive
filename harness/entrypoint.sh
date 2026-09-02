#!/bin/sh
# fake-tablet entrypoint: loopback alias, ssh key permissions, sample data,
# per-profile system files, mock xochitl (web UI) and finally dropbear.
set -u

XDIR=/home/root/.local/share/remarkable/xochitl
GEN=/opt/fake-tablet/gen-sample-xochitl.py
AK=/home/root/.ssh/authorized_keys
AK_HOST=/opt/fake-tablet/authorized_keys.host
LOG=/home/root/log.txt
: "${FAKE_PROFILE:=paperpro-3.27}"
export FAKE_PROFILE

log() { printf '%s entrypoint: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" >&2; }

# 1. The tablet answers on 10.11.99.1 inside itself (compose grants NET_ADMIN).
ip addr add 10.11.99.1/32 dev lo 2>/dev/null || true

# 2. ssh directory and authorized_keys. Sources, in order:
#      - FAKE_AUTHORIZED_KEYS (public key line(s) passed through the environment; written to
#        harness/.env by Start-FakeTablet.ps1). This is the reliable path: Docker Desktop's
#        view of a freshly created Windows file can be stale, in which case a single-file
#        bind silently becomes an empty directory.
#      - $AK_HOST, the optional bind of the host's authorized_keys file (a Windows bind mount
#        shows up as mode 0777 on a read-only mount, which dropbear rejects, so it is copied).
#    The result is written to $AK with mode 0600, which dropbear insists on.
mkdir -p /home/root/.ssh
chmod 755 /home/root
chmod 700 /home/root/.ssh
: "${FAKE_AUTHORIZED_KEYS:=}"
tmp="$AK.tmp"
: > "$tmp"
if [ -n "$FAKE_AUTHORIZED_KEYS" ]; then
    printf '%s\n' "$FAKE_AUTHORIZED_KEYS" | tr -d '\r' | grep . >> "$tmp"
    log "authorized_keys: $(printf '%s\n' "$FAKE_AUTHORIZED_KEYS" | grep -c .) key line(s) from FAKE_AUTHORIZED_KEYS"
fi
if [ -f "$AK_HOST" ]; then
    tr -d '\r' < "$AK_HOST" | grep . >> "$tmp"
    log "authorized_keys: $(grep -c . "$AK_HOST") key line(s) from $AK_HOST"
elif [ -d "$AK_HOST" ]; then
    log "warning: $AK_HOST is a directory (Docker Desktop could not see the host file at mount time); ignored"
fi
if [ -s "$tmp" ]; then
    sort -u "$tmp" > "$tmp.u" && mv -f "$tmp.u" "$tmp"
    if mv -f "$tmp" "$AK" 2>/dev/null; then
        chmod 600 "$AK"
        log "authorized_keys installed at $AK ($(grep -c . "$AK") key line(s), mode 0600)"
    else
        rm -f "$tmp"
        log "warning: cannot replace $AK (read-only mount?); using it as is"
    fi
else
    rm -f "$tmp"
fi
if [ -e "$AK" ]; then
    chmod 600 "$AK" 2>/dev/null || log "warning: cannot chmod $AK (read-only mount?); dropbear needs 0600"
else
    log "warning: no authorized_keys; only password login (root/fake) will work"
fi

# 3. Sample data on the first boot of an empty volume; system files on every boot.
if [ -z "$(ls -A "$XDIR" 2>/dev/null)" ]; then
    log "xochitl dir is empty: generating sample data (profile $FAKE_PROFILE)"
    python3 "$GEN" --root "$XDIR" --profile "$FAKE_PROFILE" || log "warning: sample generation failed"
fi
python3 "$GEN" --root "$XDIR" --profile "$FAKE_PROFILE" --system-files-only || log "warning: system file generation failed"

# 4. Fresh runtime state (a reboot clears systemd's start counter too), then start xochitl.
rm -f /run/fake-xochitl.state /run/fake-xochitl.starts /run/fake-xochitl.pid /run/fake-xochitl.since
/usr/local/bin/xochitl-fake.sh start

# 5. dropbear in the foreground. Host keys are generated on demand into /etc/dropbear
#    (a named volume, so they stay stable across container recreation). Password login
#    stays enabled (root / fake) for the Setup path.
log "starting dropbear (profile $FAKE_PROFILE, live-scan ${FAKE_LIVE_SCAN:-0}, restart gap ${FAKE_RESTART_SECONDS:-8}s)"
exec dropbear -F -E -R -p 22
