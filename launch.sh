#!/bin/bash
# Starts the iPC installer and opens it in the browser.
# Run it with:  bash launch.sh   (also what install.sh does). The administrator password is requested
# later, by a pop-up window, when the installation starts.
cd "$(dirname "$(readlink -f "$0")")" || exit 1

PORT="${IPC_PORT:-3636}"
URL="http://localhost:$PORT"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ipc-installer"
LOG="$LOG_DIR/server.log"
mkdir -p "$LOG_DIR"

echo "Ignition Edge iPC Installer -> $URL"

problem() {
    echo "Error: $1" >&2
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        zenity --error --title="iPC Setup" --width=420 --text="$1" 2>/dev/null
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "iPC Setup" "$1"
    fi
}

server_up() {
    python3 - "$URL/api/status" <<'PY' 2>/dev/null
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=2).read()
except Exception:
    sys.exit(1)
PY
}

open_browser() {
    [ -z "${IPC_NO_BROWSER:-}" ] || return 0
    (xdg-open "$URL" >/dev/null 2>&1 &) || true
}

if [ "$(id -u)" -eq 0 ]; then
    problem "Please start iPC Setup as your normal user, not as root. It will ask for the administrator password when it needs it."
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { problem "Python 3 is not installed, so iPC Setup cannot start."; exit 1; }
command -v pkexec >/dev/null 2>&1 || { problem "The 'pkexec' tool (policykit) is missing, so iPC Setup cannot ask for the administrator password."; exit 1; }

# Already open? Just bring up the page again.
if server_up; then
    open_browser
    exit 0
fi

chmod +x scripts/*.sh scripts/netcfg.py 2>/dev/null || true

python3 server.py >> "$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT INT TERM

for _ in $(seq 1 30); do
    server_up && break
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        problem "iPC Setup could not start. Is it already open in another window?

$(tail -n 5 "$LOG" 2>/dev/null)"
        exit 1
    fi
    sleep 0.5
done
server_up || { problem "iPC Setup did not start in time. Details are in $LOG"; exit 1; }

open_browser
wait "$SERVER_PID"
