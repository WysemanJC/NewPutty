#!/bin/sh
# Start the macOS PuTTY.app a few ways and check that it stays up,
# taking screenshots for a human to look at. Used by CI.
#
# Usage: scripts/macos-smoke-test.sh <build dir> <screenshot dir>

set -u

build=$1
out=$2
app="$build/PuTTY.app/Contents/MacOS/PuTTY"
mkdir -p "$out"
PUTTYDIR=$(mktemp -d)
export PUTTYDIR
status=0

"$app" -version || exit 1

crash_report() {
    for f in "$HOME"/Library/Logs/DiagnosticReports/PuTTY*; do
        [ -f "$f" ] && { echo "=== $f"; head -c 20000 "$f"; }
    done
}

# Run PuTTY with the given arguments for a few seconds, then take a
# screenshot called $1.png and stop it.
check_run() {
    name=$1
    shift
    "$app" "$@" &
    pid=$!
    sleep 8
    if kill -0 "$pid" 2>/dev/null; then
        screencapture -x "$out/$name.png" 2>/dev/null || true
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "$name: OK"
    else
        wait "$pid"
        echo "$name: PuTTY exited early with status $?" >&2
        crash_report
        status=1
    fi
}

# The configuration box, as when PuTTY is started from the Finder.
check_run config-box

# A session window, talking to a little server that sends some text.
python3 - <<'PYEOF' &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 2323))
s.listen(1)
c, _ = s.accept()
c.sendall(b"Hello from \x1b[1;32mPuTTY\x1b[0m on macOS\r\n"
          b"\x1b[31mred \x1b[32mgreen \x1b[34mblue \x1b[7minverse\x1b[0m\r\n"
          b"UTF-8: \xc3\xa9\xc3\xa0\xc3\xbc \xe2\x9c\x93 \xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90\r\n"
          b"\x1b#6Double width\r\n")
time.sleep(30)
PYEOF
server=$!
sleep 1
check_run session -raw -P 2323 127.0.0.1
kill "$server" 2>/dev/null

# A connection that fails, which puts up an error box.
check_run connect-error -raw -P 1 127.0.0.1

exit $status
