#!/bin/sh
# Fake xochitl process control. "start" records the unit as active and launches the
# mock USB web UI; "stop" kills it. The mock loads its catalog only when it starts
# (unless FAKE_LIVE_SCAN=1), so files copied in over scp stay invisible until a restart,
# and a restart means "web UI gone for FAKE_RESTART_SECONDS".
STATE=/run/fake-xochitl.state
PIDF=/run/fake-xochitl.pid
SINCE=/run/fake-xochitl.since
LOG=/home/root/log.txt
WEBLOG=/home/root/webui.log

log() { printf '%s xochitl-fake: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
alive() {
    [ -f "$PIDF" ] || return 1
    p=$(cat "$PIDF" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

case "${1:-}" in
    start)
        if alive; then
            echo active > "$STATE"
            log "start: already running (pid $(cat "$PIDF"))"
            exit 0
        fi
        # New session so the process survives the end of the ssh session that started it.
        setsid python3 /opt/fake-tablet/mock-webui.py < /dev/null >> "$WEBLOG" 2>&1 &
        echo $! > "$PIDF"
        echo active > "$STATE"
        date +%s > "$SINCE"
        log "start: mock web ui pid $!"
        ;;
    stop)
        if alive; then
            p=$(cat "$PIDF")
            kill "$p" 2>/dev/null
            i=0
            while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do
                sleep 0.1
                i=$((i + 1))
            done
            kill -9 "$p" 2>/dev/null
            log "stop: killed pid $p"
        else
            log "stop: not running"
        fi
        rm -f "$PIDF"
        echo inactive > "$STATE"
        date +%s > "$SINCE"
        ;;
    status)
        if alive; then echo active; exit 0; fi
        echo inactive
        exit 3
        ;;
    *)
        echo "usage: xochitl-fake.sh start|stop|status" >&2
        exit 1
        ;;
esac
exit 0
