#!/bin/bash
# Ignition Edge iPC installer. Runs as root, detached from the web UI.
#
# Usage: setup.sh <location> <system_type> <node_type> <hac_selection> <enp4s0_ip> [run_id] [fresh|resume] [work_mode] [facility_gateway]
#   work_mode: install (Ignition + modules only, default) | network (network settings only) | full (both)
#   hac_selection / enp4s0_ip / facility_gateway are only used when the network is configured
#   (the gateway is optional and defaults to x.x.x.1 of the facility address).
#
# Progress is written as JSON lines to $LOG_DIR/events-<run_id>.jsonl (polled by server.py) and
# as plain text to $LOG_DIR/install-<run_id>.log. Each step records a marker so a failed
# install can be resumed from the step that failed.
set -Eeuo pipefail
umask 022
trap '' HUP   # keep going if the terminal that launched us is closed

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

if [ "$EUID" -ne 0 ]; then
    echo "setup.sh must be run as root. Please start the installer with: bash launch.sh" >&2
    exit 1
fi

LOCATION="${1:-${LOCATION:-Plant-01}}"
SYSTEM_TYPE="${2:-${SYSTEM_TYPE:-HAC}}"
NODE_TYPE="${3:-${NODE_TYPE:-Primary}}"
HAC_SELECTION="${4:-${HAC_SELECTION:-}}"
ENP4S0_IP="${5:-${ENP4S0_IP:-}}"
RUN_ID="${6:-$(date +%Y%m%d-%H%M%S)}"
RUN_MODE="${7:-fresh}"
WORK_MODE="${8:-install}"
ENP4S0_GATEWAY="${9:-}"

# Normalize HAC_SELECTION (e.g., HAC01 -> HAC-01)
if [[ "$HAC_SELECTION" =~ ^HAC[0-9]+$ ]]; then
    HAC_SELECTION="HAC-${HAC_SELECTION#HAC}"
fi

[[ "$RUN_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid run id." >&2; exit 1; }
[[ "$SYSTEM_TYPE" =~ ^(HAC|SAP)$ ]] || { echo "Invalid system type: $SYSTEM_TYPE" >&2; exit 1; }
[[ "$WORK_MODE" =~ ^(install|network|full)$ ]] || { echo "Invalid work mode: $WORK_MODE" >&2; exit 1; }
[[ "$NODE_TYPE" =~ ^(Primary|Backup)$ ]] || { echo "Invalid node type: $NODE_TYPE" >&2; exit 1; }

#################### Configuration ####################
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin/ignition}"
SERVICE_NAME="${SERVICE_NAME:-ignition}"
GATEWAY_URL="http://localhost:8088/StatusPing"
GATEWAY_TIMEOUT=300
MODULE_UPLOAD_URL="http://localhost:8088/data/api/v1/modules/upload"
MODULE_INSTALL_URL="http://localhost:8088/data/api/v1/modules/install"
MIN_FREE_KB="${MIN_FREE_KB:-$((5 * 1024 * 1024))}"

# (INSTALL_DIR, SERVICE_NAME, MIN_FREE_KB and the *_DIR paths can be overridden from the environment for testing.)

# Perspective Workstation lives in its own folder inside the applications folder, which is shared with every
# other launcher, so nothing outside that folder is ever replaced.
PW_DIR="${PW_DIR:-/usr/local/share/applications/perspective-workstation}"
PW_FLAT_DIR="${PW_FLAT_DIR:-/usr/local/share/applications}"   # an earlier version unpacked it loose in here
PW_OLD_DIR="${PW_OLD_DIR:-/opt/perspective-workstation}"       # ...and an even earlier one used /opt
PW_ITEMS=(app runtime install.sh perspectiveworkstation.sh)
PW_LEGACY_DIR="${PW_LEGACY_DIR:-/usr/share/applications}"

# Shared settings (admin account, service user, Workstation URL...). Environment values win.
CONFIG_FILE="$BASE_DIR/config/installer.conf"
_env_gateway_user="${GATEWAY_USER:-}"; _env_force="${FORCE_REINSTALL:-}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
[ -z "$_env_gateway_user" ] || GATEWAY_USER="$_env_gateway_user"
[ -z "$_env_force" ] || FORCE_REINSTALL="$_env_force"
GATEWAY_ADMIN_USERNAME="${GATEWAY_ADMIN_USERNAME:-test}"
GATEWAY_ADMIN_PASSWORD="${GATEWAY_ADMIN_PASSWORD:-ignition}"
GATEWAY_USER="${GATEWAY_USER:-root}"
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
WORKSTATION_URL="${WORKSTATION_URL:-}"
VALIDATE_NETWORK="${VALIDATE_NETWORK:-false}"
case "${VALIDATE_NETWORK,,}" in
    true|yes|1)  VALIDATE_NETWORK=true ;;
    false|no|0)  VALIDATE_NETWORK=false ;;
    *) echo "Invalid VALIDATE_NETWORK (use true or false): $VALIDATE_NETWORK" >&2; exit 1 ;;
esac
SAP_MAX_FILE_SIZE="${SAP_MAX_FILE_SIZE:-134217728}"
[[ "$SAP_MAX_FILE_SIZE" =~ ^[0-9]+$ ]] || { echo "Invalid SAP_MAX_FILE_SIZE." >&2; exit 1; }
[[ "$GATEWAY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Invalid GATEWAY_USER: $GATEWAY_USER" >&2; exit 1; }
[[ -z "$WORKSTATION_URL" || "$WORKSTATION_URL" =~ ^[A-Za-z0-9:/._?\&=%#@-]+$ ]] || { echo "Invalid WORKSTATION_URL." >&2; exit 1; }

MANIFEST="$BASE_DIR/media/manifest.json"
STATE_DIR="${STATE_DIR:-/var/lib/ipc-installer}"
STEP_DIR="$STATE_DIR/steps"
LOG_DIR="${LOG_DIR:-/var/log/ipc-installer}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/ignition-installer}"
EVENTS="$LOG_DIR/events-$RUN_ID.jsonl"
LOGFILE="$LOG_DIR/install-$RUN_ID.log"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKUP_DIR"
chmod 755 "$STATE_DIR" "$LOG_DIR"
touch "$EVENTS" "$LOGFILE"
chmod 644 "$EVENTS" "$LOGFILE"
find "$LOG_DIR" -type f -mtime +14 -delete 2>/dev/null || true

# Only one install at a time. Taken before any traps so a rejected start never touches status.
exec 9>"$STATE_DIR/install.lock"
flock -n 9 || { echo "Another installation is already running." >&2; exit 2; }

#################### Logging / events ####################
MAIN_PID=$$
CURRENT_STEP="init"
ERROR_REPORTED=0

json_escape() {
    local s="$1"
    s="${s//$'\t'/ }"
    s="${s//[^[:print:]]/}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

log_msg() {
    local level="info" msg ts
    if [ "$#" -ge 2 ]; then level="$1"; msg="$2"; else msg="$1"; fi
    ts=$(date '+%H:%M:%S')
    printf '[%s] %s %s\n' "$ts" "$level" "$msg" >> "$LOGFILE"
    if [ "$level" = "error" ]; then
        printf '{"type": "log", "level": "error", "timestamp": "%s", "message": "%s"}\n' "$ts" "$(json_escape "$msg")" >> "$EVENTS"
    else
        printf '{"type": "log", "timestamp": "%s", "message": "%s"}\n' "$ts" "$(json_escape "$msg")" >> "$EVENTS"
    fi
}

progress() {
    printf '{"type": "progress", "percent": %d, "message": "%s"}\n' "$1" "$(json_escape "$2")" >> "$EVENTS"
    printf '[%s] progress %s%% %s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$LOGFILE"
}

write_status() {
    printf '{"state": "%s", "pid": %d, "run_id": "%s", "step": "%s", "mode": "%s"}\n' "$1" "$$" "$RUN_ID" "$CURRENT_STEP" "$WORK_MODE" > "$STATE_DIR/status.json.tmp"
    mv "$STATE_DIR/status.json.tmp" "$STATE_DIR/status.json"
}

# fail "what went wrong" ["what to try"] -- reports to the UI and stops.
fail() {
    ERROR_REPORTED=1
    log_msg error "$1"
    printf '{"type": "error", "step": "%s", "message": "%s", "hint": "%s"}\n' \
        "$CURRENT_STEP" "$(json_escape "$1")" "$(json_escape "${2:-}")" >> "$EVENTS"
    exit 1
}

on_err() {
    # Subshells (pipeline members) also fire the trap; only the main shell reports.
    [ "$BASHPID" = "$MAIN_PID" ] || return 0
    log_msg error "Command failed (line $1): $2"
}

on_exit() {
    local rc=$?
    trap - ERR EXIT
    if [ "$rc" -eq 0 ]; then
        write_status done
    else
        if [ "$ERROR_REPORTED" -eq 0 ]; then
            printf '{"type": "error", "step": "%s", "message": "%s", "hint": "%s"}\n' "$CURRENT_STEP" \
                "The installer stopped unexpectedly during step '$CURRENT_STEP'." \
                "Details were saved to $LOGFILE" >> "$EVENTS"
        fi
        write_status failed
    fi
    exit "$rc"
}

trap 'on_err $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT
write_status running

# Streams each output line of a command into the UI log. Returns the command's exit code.
log_stream() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] || log_msg "$line"
    done
    return 0
}
run() {
    local rc=0
    "$@" 9>&- 2>&1 | log_stream || rc=${PIPESTATUS[0]}
    return "$rc"
}

#################### Resume handling ####################
PARAMS="$WORK_MODE|$LOCATION|$SYSTEM_TYPE|$NODE_TYPE|$HAC_SELECTION|$ENP4S0_IP|$ENP4S0_GATEWAY"
if [ "$RUN_MODE" = "resume" ] && [ -f "$STATE_DIR/params" ] && [ "$(cat "$STATE_DIR/params")" = "$PARAMS" ]; then
    log_msg "[System] Resuming previous installation (completed steps will be skipped)."
else
    rm -rf "$STEP_DIR"
fi
mkdir -p "$STEP_DIR"
printf '%s' "$PARAMS" > "$STATE_DIR/params"

step_event() { # step_event <name> <start|done>
    printf '{"type": "step", "name": "%s", "state": "%s"}\n' "$1" "$2" >> "$EVENTS"
}

# health <ok|warn> <message> -- an item for the "all done" summary on the final screen.
health() {
    local ok=true
    [ "$1" = "ok" ] || ok=false
    printf '{"type": "health", "ok": %s, "message": "%s"}\n' "$ok" "$(json_escape "$2")" >> "$EVENTS"
    log_msg "[Health] $2"
}

run_step() { # run_step <name> <percent> <label> <function>
    local name="$1" pct="$2" msg="$3" fn="$4"
    CURRENT_STEP="$name"
    write_status running
    progress "$pct" "$msg"
    step_event "$name" start
    if [ -e "$STEP_DIR/$name.done" ]; then
        log_msg "[Resume] Step '$name' already completed, skipping."
    else
        "$fn"
        touch "$STEP_DIR/$name.done"
    fi
    step_event "$name" done
}

# emit_plan -- tells the UI which steps to list, from the STEPS array ("name|percent|label|function").
emit_plan() {
    local entry name pct label fn json=""
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r name pct label fn <<< "$entry"
        json+="${json:+, }{\"name\": \"$name\", \"label\": \"$(json_escape "$label")\"}"
    done
    printf '{"type": "plan", "steps": [%s]}\n' "$json" >> "$EVENTS"
}

#################### Helpers ####################
manifest_get() { # manifest_get <section> <key>
    python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])
PY
}

# media_path <manifest section> -- sets MEDIA_FILE (not a subshell, so fail() can report properly).
media_path() {
    local rel
    rel=$(manifest_get "$1" file) || fail "media/manifest.json is missing or invalid." "Run scripts/make-manifest.sh to regenerate it."
    MEDIA_FILE="$BASE_DIR/media/$rel"
}

ignition_installed() {
    [ -d "$INSTALL_DIR" ] || systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1
}

# Version of the Ignition currently installed (empty if none), e.g. 8.3.8.
installed_version() {
    local jar
    for jar in "$INSTALL_DIR"/lib/core/gateway/gateway-[0-9]*.jar; do
        [ -e "$jar" ] || continue
        jar="${jar##*/gateway-}"
        printf '%s' "${jar%.jar}"
        return 0
    done
    return 0
}

# True when the installed Ignition is the packaged version and runs as GATEWAY_USER, so it can be
# kept (only the backup and modules are re-applied) instead of being removed and reinstalled.
can_reuse_install() {
    local target installed owner
    [ "$FORCE_REINSTALL" != "true" ] || return 1
    [ -x "$INSTALL_DIR/ignition.sh" ] || return 1
    target=$(manifest_version) || return 1
    installed=$(installed_version)
    [ -n "$installed" ] && [ "$installed" = "$target" ] || return 1
    # The install folder's owner (data/ only appears after the first start).
    owner=$(stat -c %U "$INSTALL_DIR" 2>/dev/null) || return 1
    [ "$owner" = "$GATEWAY_USER" ]
}

# Version in the packaged installer's file name (ignition-8.3.8-linux-64-installer.run -> 8.3.8).
manifest_version() {
    local rel
    rel=$(manifest_get installer file) || return 1
    [[ "$rel" =~ ignition-([0-9]+(\.[0-9]+)+)- ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

ensure_gateway_user() {
    [ "$GATEWAY_USER" != "root" ] || return 0
    if ! id -u "$GATEWAY_USER" >/dev/null 2>&1; then
        log_msg "[Install] Creating service account '$GATEWAY_USER'..."
        # Needs a real shell: ignition.sh starts the gateway through 'runuser -'. No password is set, so
        # nobody can log in as this account.
        run useradd --system --home-dir "$INSTALL_DIR" --no-create-home --shell /bin/bash "$GATEWAY_USER" ||
            fail "Could not create the '$GATEWAY_USER' service account."
    fi
    # Serial ports (Modbus RTU etc.) belong to dialout.
    if getent group dialout >/dev/null 2>&1; then usermod -aG dialout "$GATEWAY_USER" || true; fi
}

gateway_state() {
    python3 "$BASE_DIR/scripts/gwapi.py" state "$GATEWAY_URL" 2>/dev/null || true
}

# gw_post <url> [--file PATH] [--timeout N] -- prints the response; failures are written to the log.
gw_post() {
    local out rc=0 errf="$STATE_DIR/gwapi.err"
    out=$(python3 "$BASE_DIR/scripts/gwapi.py" post "$@" 2>"$errf") || rc=$?
    if [ -s "$errf" ]; then log_msg "[API] $(tr '\n' ' ' < "$errf")"; fi
    printf '%s' "$out"
    return "$rc"
}

gateway_failed() { # gateway_failed <message>
    local wrapper="$INSTALL_DIR/logs/wrapper.log"
    if [ -f "$wrapper" ]; then
        log_msg "--- last lines of wrapper.log ---"
        tail -n 30 "$wrapper" | log_stream
    fi
    fail "$1" "See $LOGFILE and $wrapper for details."
}

wait_for_gateway() {
    local elapsed=0 state
    while true; do
        state=$(gateway_state)
        [ "$state" = "RUNNING" ] && return 0
        if systemctl is-failed --quiet "$SERVICE_NAME"; then
            gateway_failed "The Ignition service stopped with an error."
        fi
        if [ "$state" = "FAULTED" ]; then
            gateway_failed "The Ignition Gateway reported a fault."
        fi
        if [ "$elapsed" -ge "$GATEWAY_TIMEOUT" ]; then
            gateway_failed "Timed out after ${GATEWAY_TIMEOUT}s waiting for the Ignition Gateway to start."
        fi
        if [ $((elapsed % 30)) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
            log_msg "[Install] Still waiting for the gateway (${elapsed}s)..."
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

ensure_gateway() {
    if [ "$(gateway_state)" != "RUNNING" ]; then
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            log_msg "[Service] Gateway is not running, starting it..."
            systemctl start "${SERVICE_NAME}.service" || fail "Could not start the Ignition service."
        fi
        wait_for_gateway
    fi
}

# After a restore/restart the old process can still answer RUNNING for a moment. Wait for it to
# go down (or give up after 30s if the restart was already finished) before waiting for it to return.
wait_for_gateway_restart() {
    local i
    for i in $(seq 1 15); do
        [ "$(gateway_state)" = "RUNNING" ] || break
        sleep 2
    done
    wait_for_gateway
}

#################### Steps ####################
step_preflight() {
    local cmd avail_kb check_dir files port_in_use

    for cmd in python3 systemctl tar sha256sum flock ss; do
        command -v "$cmd" >/dev/null 2>&1 || fail "Required tool '$cmd' is not installed." "Install it with: sudo apt install $cmd"
    done

    if [ "$WORK_MODE" != "network" ]; then
        # Perspective Workstation's install.sh needs these (and stops half-way without them); the iPC may be offline.
        for cmd in xdg-mime xdg-icon-resource update-mime-database update-desktop-database gtk-update-icon-cache; do
            command -v "$cmd" >/dev/null 2>&1 ||
                fail "Required desktop tool '$cmd' is not installed." "Needed by Perspective Workstation. Install xdg-utils, shared-mime-info, desktop-file-utils and libgtk-3-bin."
        done
        if [ "$GATEWAY_USER" != "root" ]; then
            command -v useradd >/dev/null 2>&1 || fail "'useradd' is not available." "Install the passwd package."
        fi
    fi

    [ "$(uname -m)" = "x86_64" ] || fail "This installer only supports x86_64 iPCs (found $(uname -m))."
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        log_msg "[Preflight] OS: ${PRETTY_NAME:-unknown}"
        [ "${ID:-}" = "ubuntu" ] || log_msg "[Preflight] Warning: expected Ubuntu, found ${ID:-unknown}."
        case "${VERSION_ID:-}" in
            24.04|26.04) ;;
            *) log_msg "[Preflight] Warning: tested on Ubuntu 24.04/26.04, found ${VERSION_ID:-unknown}." ;;
        esac
    fi

    if [ "$WORK_MODE" != "install" ]; then
        command -v netplan >/dev/null 2>&1 || fail "netplan is not installed." "Install it with: sudo apt install netplan.io"
        python3 -c 'import yaml' 2>/dev/null || fail "python3-yaml is not installed." "Install it with: sudo apt install python3-yaml"
        systemctl is-active --quiet NetworkManager || fail "NetworkManager is not running." "Start it with: sudo systemctl start NetworkManager"
    fi

    if [ "$WORK_MODE" = "network" ]; then
        log_msg "[Preflight] Network-only task: skipping installer file checks."
        return 0
    fi

    check_dir="$(dirname "$INSTALL_DIR")"
    avail_kb=$(df --output=avail -k "$check_dir" | tail -n 1 | tr -d ' ')
    [ "$avail_kb" -ge "$MIN_FREE_KB" ] || fail "Not enough free disk space ($((avail_kb / 1024)) MB free, $((MIN_FREE_KB / 1024)) MB required)." "Free up space and press Retry."

    port_in_use=$(ss -ltnH '( sport = :8088 )' || true)
    if ! ignition_installed && [ -n "$port_in_use" ]; then
        fail "Port 8088 is already in use by another program." "Stop that program and press Retry."
    fi

    [ -f "$MANIFEST" ] || fail "media/manifest.json is missing." "Run scripts/make-manifest.sh."
    log_msg "[Preflight] Verifying installer files (this can take a minute)..."
    files=$(python3 - "$MANIFEST" <<'PY'
import json, sys
for entry in json.load(open(sys.argv[1])).values():
    print(f"{entry['sha256']}  {entry['file']}")
PY
    ) || fail "Could not read media/manifest.json."
    (cd "$BASE_DIR/media" && printf '%s\n' "$files" | run sha256sum -c -) ||
        fail "An installer file is missing or damaged." "Re-copy the installer package and press Retry."
    log_msg "[Preflight] All checks passed."
}

step_backup_existing() {
    local ts paths=() p
    if ! ignition_installed; then
        log_msg "[Backup] No existing Ignition installation, nothing to back up."
        return 0
    fi
    ts=$(date +%Y%m%d-%H%M%S)
    for p in data user-lib; do
        if [ -e "$INSTALL_DIR/$p" ]; then paths+=("$p"); fi
    done
    if [ "${#paths[@]}" -gt 0 ]; then
        log_msg "[Backup] Saving existing Ignition data to $BACKUP_DIR/ignition-data-$ts.tar.gz"
        run tar -czf "$BACKUP_DIR/ignition-data-$ts.tar.gz" -C "$INSTALL_DIR" "${paths[@]}" ||
            fail "Could not back up the existing Ignition installation. Nothing was changed." "Check free disk space and press Retry."
    fi
    if [ -x "$INSTALL_DIR/gwcmd.sh" ] && [ "$(gateway_state)" = "RUNNING" ]; then
        run "$INSTALL_DIR/gwcmd.sh" --backup "$BACKUP_DIR/ignition-$ts.gwbk" ||
            log_msg "[Backup] Warning: gateway backup (.gwbk) could not be created; the data folder copy was saved."
    fi
}

step_uninstall() {
    if ! ignition_installed; then
        log_msg "[Uninstall] No Ignition installation detected, skipping."
        return 0
    fi
    if can_reuse_install; then
        log_msg "[Uninstall] Ignition $(installed_version) is already installed and runs as $GATEWAY_USER; keeping it (set FORCE_REINSTALL=true in config/installer.conf to reinstall)."
        return 0
    fi
    log_msg "[Uninstall] Removing existing Ignition installation..."
    run bash "$BASE_DIR/scripts/uninstall.sh" "$INSTALL_DIR" "$SERVICE_NAME" ||
        fail "Could not remove the existing Ignition installation."
}

step_install_ignition() {
    local installer owner rc=0
    if can_reuse_install; then
        log_msg "[Install] Reusing the existing Ignition $(installed_version) installation."
        return 0
    fi
    media_path installer
    installer="$MEDIA_FILE"
    # A previous attempt that died mid-install leaves a partial directory behind.
    if ignition_installed; then
        log_msg "[Install] Cleaning up leftovers from an earlier attempt..."
        run bash "$BASE_DIR/scripts/uninstall.sh" "$INSTALL_DIR" "$SERVICE_NAME" || fail "Could not clean up a partial installation."
    fi
    ensure_gateway_user
    # Run through bash, so the executable bit is not needed (and cannot be set on FAT/exFAT USB drives).
    chmod +x "$installer" 2>/dev/null || true
    log_msg "[Install] Starting installer: $installer"
    # unattended=text : command-line feedback only, no GUI
    # autoStart=false : do not boot the gateway before the overrides are applied (8.1.22+)
    run bash "$installer" --nox11 -- "unattended=text" "location=$INSTALL_DIR" "serviceName=$SERVICE_NAME" "user=$GATEWAY_USER" "autoStart=false" || rc=$?
    # The installer can finish ("Install complete") yet exit non-zero (e.g. its X11 helper has no display
    # in this session), so judge it by what it left behind, not only by its exit code.
    if [ "$rc" -ne 0 ]; then
        log_msg "[Install] The Ignition installer exited with code $rc; checking whether the installation is complete..."
        if [ -f /root/.ignition/install/install.log ]; then
            tail -n 15 /root/.ignition/install/install.log | log_stream
        fi
    fi
    if [ ! -x "$INSTALL_DIR/ignition.sh" ] || [ ! -x "$INSTALL_DIR/gwcmd.sh" ] || [ ! -d "$INSTALL_DIR/lib/core/gateway" ] ||
        ! systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        fail "The Ignition installer failed (exit code $rc) and did not finish installing." "See the log for details, then press Retry."
    fi
    if [ "$rc" -ne 0 ]; then
        log_msg "[Install] Installation is complete despite the exit code; continuing."
    fi
    if [ "$GATEWAY_USER" != "root" ]; then
        # ignition.sh refuses to start if RUN_AS_USER does not match, and the service account must own
        # the install folder (pid/status files, data, logs, temp).
        grep -q "^RUN_AS_USER=$GATEWAY_USER\$" "$INSTALL_DIR/ignition.sh" ||
            sed -i "s/^RUN_AS_USER=.*/RUN_AS_USER=$GATEWAY_USER/" "$INSTALL_DIR/ignition.sh"
        owner=$(stat -c %U "$INSTALL_DIR/data" 2>/dev/null || echo "")
        if [ "$owner" != "$GATEWAY_USER" ] || [ "$(stat -c %U "$INSTALL_DIR")" != "$GATEWAY_USER" ]; then
            log_msg "[Install] Giving $GATEWAY_USER ownership of $INSTALL_DIR..."
            chown -R "$GATEWAY_USER:$GATEWAY_USER" "$INSTALL_DIR" || fail "Could not set ownership of $INSTALL_DIR."
        fi
    fi
    log_msg "[Install] Ignition Edge $(installed_version) installed (service user: $GATEWAY_USER)."
}

step_configure_service() {
    local override_dir="/etc/systemd/system/${SERVICE_NAME}.service.d" conf="$INSTALL_DIR/data/ignition.conf"
    log_msg "[Service] Creating systemd overrides..."
    mkdir -p "$override_dir"
    cat > "$override_dir/override.conf" <<OVERRIDE
[Service]
Environment="ACCEPT_IGNITION_EULA=Y"
Environment="IGNITION_EDITION=edge"
Environment="GATEWAY_ADMIN_USERNAME=$GATEWAY_ADMIN_USERNAME"
Environment="GATEWAY_ADMIN_PASSWORD=$GATEWAY_ADMIN_PASSWORD"
Environment="GATEWAY_DEFAULT_PORTS=true"
Environment="ACCEPT_MODULE_LICENSES=com.cirruslink.mqtt.transmission.gateway"
Environment="ACCEPT_MODULE_CERTS=com.cirruslink.mqtt.transmission.gateway"
OVERRIDE
    chmod 600 "$override_dir/override.conf"

    # With a non-root service user, ignition.sh uses 'runuser -' (a login shell) which discards the
    # variables above. The module acceptance variables are passed to the JVM via the wrapper instead.
    if [ "$GATEWAY_USER" != "root" ] && ! grep -q "ipc-installer module acceptance" "$conf"; then
        log_msg "[Service] Adding module acceptance settings to data/ignition.conf for user $GATEWAY_USER..."
        cat >> "$conf" <<CONF

# ipc-installer module acceptance
set.ACCEPT_IGNITION_EULA=Y
set.ACCEPT_MODULE_LICENSES=com.cirruslink.mqtt.transmission.gateway
set.ACCEPT_MODULE_CERTS=com.cirruslink.mqtt.transmission.gateway
CONF
        chown "$GATEWAY_USER:$GATEWAY_USER" "$conf"
    fi

    systemctl daemon-reload || fail "systemctl daemon-reload failed."
    run systemctl enable "${SERVICE_NAME}.service" || fail "Could not enable the Ignition service."
}

step_start_gateway() {
    log_msg "[Install] Starting Ignition..."
    # restart (not start) so a reused installation picks up the refreshed service settings.
    systemctl restart "${SERVICE_NAME}.service" || fail "Could not start the Ignition service."
    log_msg "[Install] Waiting for Ignition Gateway to start (up to $((GATEWAY_TIMEOUT / 60)) minutes)..."
    wait_for_gateway
    log_msg "[Install] Ignition Gateway is ready."
}

step_restore_backup() {
    local backup gw_name
    media_path backup
    backup="$MEDIA_FILE"
    ensure_gateway
    # An Ignition-only SAP install has no node (the screen does not ask), so the gateway is just "SAP".
    gw_name="${SYSTEM_TYPE}_${NODE_TYPE}"
    if [ "$SYSTEM_TYPE" = "SAP" ] && [ "$WORK_MODE" = "install" ]; then gw_name="SAP"; fi
    log_msg "[Restore] Loading Gateway backup from: $backup (gateway name: $gw_name)"
    run "$INSTALL_DIR/gwcmd.sh" --restore "$backup" --name "$gw_name" -y ||
        fail "Restoring the gateway backup failed." "See the log for details, then press Retry."
    log_msg "[Restore] Backup restored, waiting for the gateway to restart..."
    wait_for_gateway_restart
}

# Installs the MQTT Transmission module via the gateway OpenAPI. Module license/certificate
# acceptance is pre-seeded by the ACCEPT_MODULE_* variables in the systemd override above.
step_install_module() {
    local module response module_id
    if [ "$SYSTEM_TYPE" != "HAC" ]; then
        log_msg "[MQTT] Not a HAC system, skipping module install."
        return 0
    fi
    media_path module
    module="$MEDIA_FILE"
    ensure_gateway
    log_msg "[MQTT] Uploading MQTT Transmission module..."
    response=$(gw_post "$MODULE_UPLOAD_URL?fileName=$(basename "$module")" --file "$module" --timeout 300) ||
        fail "Uploading the MQTT module failed." "Make sure the gateway is running and press Retry."
    module_id=$(printf '%s' "$response" | python3 -c '
import sys, json
m = json.load(sys.stdin).get("moduleId")
if not isinstance(m, str) or not m:
    sys.exit(1)
print(m)') || fail "The gateway did not return a valid module ID for the MQTT module."
    log_msg "[MQTT] Module uploaded (moduleId: $module_id), installing..."
    gw_post "$MODULE_INSTALL_URL?moduleId=$module_id" --timeout 120 >/dev/null ||
        fail "Installing the MQTT module failed."
    log_msg "[MQTT] MQTT Transmission module installed."
}

# trust_launcher <user> <home> <file> -- lets GNOME launch the icon without the "untrusted launcher" prompt.
# The trusted flag lives in the user's own gvfs metadata, reached over their D-Bus session. pkexec starts us
# with HOME=/root and no session bus, so without these variables gio fails ("attribute not supported").
trust_launcher() {
    local user="$1" home="$2" file="$3" rt out
    rt="/run/user/$(id -u "$user")"
    if [ ! -S "$rt/bus" ]; then
        log_msg "[Install] Warning: $user has no desktop session open, so the shortcut could not be trusted. Right-click it and choose Allow Launching."
        return 0
    fi
    if out=$(runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
            gio set "$file" metadata::trusted true 2>&1); then
        log_msg "[Install] Desktop shortcut marked as trusted."
    else
        log_msg "[Install] Warning: could not trust the desktop shortcut ($out). Right-click it and choose Allow Launching."
    fi
}

# Installs Perspective Workstation for all users into $PW_DIR (/usr/local/share/applications/perspective-workstation).
# The launcher bakes its own location into the desktop entries, so it must stay put. Then adds a desktop
# shortcut and optional autostart for the person who ran the installer.
step_perspective_workstation() {
    local archive="$INSTALL_DIR/lib/core/launch/perspectiveworkstation.tar.gz"
    local f dir user home desktop_dir
    [ -f "$archive" ] || fail "Perspective Workstation archive not found at $archive."
    # PW_DIR is deleted and recreated below, so it must be a folder of its own.
    case "$PW_DIR" in
        */perspective-workstation) ;;
        *) fail "Invalid Perspective Workstation folder: $PW_DIR" ;;
    esac

    # Earlier versions of this installer unpacked the four items loose into a shared applications folder.
    for dir in "$PW_LEGACY_DIR" "$PW_FLAT_DIR"; do
        if [ -n "$dir" ] && [ -f "$dir/perspectiveworkstation.sh" ]; then
            log_msg "[Install] Removing files left by an older installer in $dir..."
            for f in "${PW_ITEMS[@]}"; do rm -rf "${dir:?}/$f"; done
        fi
    done
    if [ -n "$PW_OLD_DIR" ] && [ "$PW_OLD_DIR" != "$PW_DIR" ] && [ -f "$PW_OLD_DIR/perspectiveworkstation.sh" ]; then
        log_msg "[Install] Removing the earlier copy in $PW_OLD_DIR..."
        rm -rf "${PW_OLD_DIR:?}"
    fi

    log_msg "[Install] Extracting Perspective Workstation to $PW_DIR..."
    rm -rf "${PW_DIR:?}"
    mkdir -p "$PW_DIR"
    run tar -xzf "$archive" --no-same-owner --strip-components=1 -C "$PW_DIR" || fail "Could not extract Perspective Workstation."
    chown -R root:root "$PW_DIR"
    chmod -R u=rwX,go=rX "$PW_DIR"
    for f in perspectiveworkstation.sh install.sh app/workstation-linux.jar runtime/bin/java; do
        [ -e "$PW_DIR/$f" ] || fail "Perspective Workstation is incomplete (missing $f)."
    done
    chmod +x "$PW_DIR/perspectiveworkstation.sh" "$PW_DIR/install.sh" "$PW_DIR/runtime/bin/java"

    log_msg "[Install] Registering Perspective Workstation for all users..."
    run bash "$PW_DIR/install.sh" || fail "Perspective Workstation setup failed."

    # Who ran the installer: sudo sets SUDO_USER, pkexec (the password pop-up) sets PKEXEC_UID.
    user="${SUDO_USER:-}"
    if [ -z "$user" ] && [ -n "${PKEXEC_UID:-}" ]; then
        user=$(getent passwd "$PKEXEC_UID" | cut -d: -f1 || true)
    fi
    if [ -z "$user" ] || [ "$user" = "root" ] || ! id -u "$user" >/dev/null 2>&1; then
        log_msg "[Install] No desktop user detected, skipping desktop shortcut and autostart."
        return 0
    fi
    home="${DESKTOP_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
    desktop_dir="$home/Desktop"
    mkdir -p "$desktop_dir"
    cat > "$desktop_dir/Perspective Workstation.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Perspective Workstation
Exec=bash -c "$PW_DIR/perspectiveworkstation.sh"
Icon=$PW_DIR/app/launcher.png
Terminal=false
Categories=Application;Network;
DESKTOP
    chmod +x "$desktop_dir/Perspective Workstation.desktop"
    chown "$user:$(id -gn "$user")" "$desktop_dir" "$desktop_dir/Perspective Workstation.desktop"
    trust_launcher "$user" "$home" "$desktop_dir/Perspective Workstation.desktop"
    log_msg "[Install] Desktop shortcut created for $user."

    if [ -n "$WORKSTATION_URL" ]; then
        mkdir -p "$home/.config/autostart"
        cat > "$home/.config/autostart/perspective-workstation.desktop" <<AUTOSTART
[Desktop Entry]
Type=Application
Name=Perspective Workstation
Exec=bash -c "$PW_DIR/perspectiveworkstation.sh '$WORKSTATION_URL'"
X-GNOME-Autostart-Delay=20
Terminal=false
AUTOSTART
        chown -R "$user:$(id -gn "$user")" "$home/.config/autostart"
        log_msg "[Install] Perspective Workstation will open $WORKSTATION_URL at login."
    else
        log_msg "[Install] No WORKSTATION_URL set in config/installer.conf; autostart not configured."
    fi
    log_msg "[Install] Perspective Workstation installed."
}

# SAP systems accept larger uploads than Ignition's 20 MB default: set max-file-size in the gateway web
# server's web.xml (read when the gateway starts, so finalize's restart applies it). Safe to repeat.
step_webserver_limits() {
    local webxml="$INSTALL_DIR/webserver/webapps/main/WEB-INF/web.xml" before
    if [ "$SYSTEM_TYPE" != "SAP" ]; then
        log_msg "[Web] Not a SAP system, leaving the upload limit at its default."
        return 0
    fi
    [ -f "$webxml" ] || fail "Could not find the gateway web server settings ($webxml)."
    [ -f "$webxml.orig" ] || cp -p "$webxml" "$webxml.orig"
    before=$(python3 -I - "$webxml" "$SAP_MAX_FILE_SIZE" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
pattern = re.compile(r"(<max-file-size>\s*)(\d+)(\s*</max-file-size>)")
found = pattern.findall(text)
if len(found) != 1:
    sys.exit(f"expected exactly one max-file-size, found {len(found)}")
open(path, "w", encoding="utf-8").write(pattern.sub(lambda m: m.group(1) + new + m.group(3), text))
print(found[0][1])
PY
    ) || fail "Could not update the upload limit in web.xml." "The original was kept as $webxml.orig"
    grep -q "<max-file-size>$SAP_MAX_FILE_SIZE</max-file-size>" "$webxml" ||
        fail "The upload limit in web.xml was not updated."
    log_msg "[Web] Upload limit (max-file-size) changed from $before to $SAP_MAX_FILE_SIZE bytes ($((SAP_MAX_FILE_SIZE / 1048576)) MB)."
    health ok "Upload limit set to $((SAP_MAX_FILE_SIZE / 1048576)) MB"
}

step_finalize() {
    log_msg "[Service] Restarting Ignition Gateway service..."
    systemctl restart "${SERVICE_NAME}.service" || fail "Could not restart the Ignition service."
    sleep 5
    wait_for_gateway
    log_msg "[Service] Ignition Gateway is running."

    # Final health report.
    systemctl is-enabled --quiet "${SERVICE_NAME}.service" ||
        fail "The Ignition service is not set to start at boot." "Run: sudo systemctl enable ${SERVICE_NAME}"
    health ok "Ignition $(installed_version) is running and starts automatically at boot"
    run "$INSTALL_DIR/gwcmd.sh" --info || log_msg "[Health] Warning: gwcmd --info did not return status."
    if [ "$SYSTEM_TYPE" = "HAC" ]; then
        health ok "MQTT Transmission module installed"
    fi
    if [ -x "$PW_DIR/perspectiveworkstation.sh" ]; then
        health ok "Perspective Workstation installed"
    else
        health warn "Perspective Workstation is not installed"
    fi
}

#################### Run ####################
log_msg "[System] Starting installer on Linux iPC (run $RUN_ID)."
log_msg "[Config] Task: $WORK_MODE, System: $SYSTEM_TYPE, Node: $NODE_TYPE${LOCATION:+, Location: $LOCATION}"

#################### Network ####################
# scripts/netcfg.py renders network/*-template.yaml with the addresses from network/config.json,
# validates it, backs up and replaces conflicting netplan/NetworkManager config, applies it, verifies
# the addresses and rolls back on failure.
step_network() {
    local result="$STATE_DIR/netcfg-result.json" args message hint
    args=(--system "$SYSTEM_TYPE" --node "$NODE_TYPE" --backup-dir "$BACKUP_DIR/network" --result-file "$result")
    if [ "$SYSTEM_TYPE" = "HAC" ]; then
        args+=(--hac "$HAC_SELECTION" --facility-ip "$ENP4S0_IP")
    fi
    # HAC: blank = facility .1. SAP: blank = no default route.
    [ -z "$ENP4S0_GATEWAY" ] || args+=(--facility-gateway "$ENP4S0_GATEWAY")
    [ "$VALIDATE_NETWORK" = "true" ] || args+=(--skip-verify)
    rm -f "$result"
    if ! run python3 "$BASE_DIR/scripts/netcfg.py" "${args[@]}"; then
        message=$(result_field "$result" message) || message=""
        hint=$(result_field "$result" hint) || hint=""
        fail "${message:-Network configuration failed.}" "${hint:-Your previous network settings were restored. See the log for details.}"
    fi
    log_msg "[Network] Network settings applied."
    result_field "$result" summary | while IFS= read -r line; do
        [ -z "$line" ] || health ok "$line"
    done
    if [ "$VALIDATE_NETWORK" != "true" ]; then
        health warn "Network settings were saved but not checked. Restart the iPC to make sure they are active."
    fi
}

result_field() { # result_field <file> <key>
    python3 -c '
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
print("\n".join(v) if isinstance(v, list) else v)' "$1" "$2"
}

# Steps per task ("name|percent|label|function"). Network runs first in "full" so cabling/address
# problems surface before the long install.
STEPS=()
if [ "$WORK_MODE" = "network" ]; then
    STEPS+=("preflight|10|Checking the system|step_preflight" "network|50|Configuring the network|step_network")
else
    STEPS+=("preflight|3|Checking the system|step_preflight")
    if [ "$WORK_MODE" = "full" ]; then STEPS+=("network|8|Configuring the network|step_network"); fi
    STEPS+=(
        "backup_existing|14|Backing up any existing installation|step_backup_existing"
        "uninstall|20|Removing the previous Ignition|step_uninstall"
        "install_ignition|30|Installing Ignition Edge|step_install_ignition"
        "configure_service|40|Setting up the Ignition service|step_configure_service"
        "start_gateway|50|Starting the gateway|step_start_gateway"
        "restore_backup|60|Loading the gateway configuration|step_restore_backup"
    )
    if [ "$SYSTEM_TYPE" = "HAC" ]; then STEPS+=("install_module|70|Installing the MQTT module|step_install_module"); fi
    if [ "$SYSTEM_TYPE" = "SAP" ]; then STEPS+=("webserver|75|Raising the upload limit|step_webserver_limits"); fi
    STEPS+=(
        "perspective|80|Installing Perspective Workstation|step_perspective_workstation"
        "finalize|90|Final checks|step_finalize"
    )
fi
emit_plan

for entry in "${STEPS[@]}"; do
    IFS='|' read -r _name _pct _label _fn <<< "$entry"
    run_step "$_name" "$_pct" "$_label" "$_fn"
done

CURRENT_STEP="done"
rm -rf "$STEP_DIR" "$STATE_DIR/params"
progress 100 "Finalizing..."
if [ "$WORK_MODE" != "network" ]; then
    log_msg "[System] Ignition Gateway is accessible at: http://localhost:8088"
fi
printf '{"type": "done", "message": "Installation complete."}\n' >> "$EVENTS"
