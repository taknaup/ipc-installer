#!/bin/bash
# Removes an Ignition install. Called by setup.sh (as root) after the data has been backed up.
set -u

INSTALL_DIR="${1:-/usr/local/bin/ignition}"
SERVICE_NAME="${2:-ignition}"

if [ "$EUID" -ne 0 ]; then
    echo "uninstall.sh must be run as root." >&2
    exit 1
fi

case "$INSTALL_DIR" in
    ""|"/"|"/usr"|"/usr/local"|"/usr/local/bin"|"/opt"|"/home")
        echo "Refusing to remove unsafe path: '$INSTALL_DIR'" >&2
        exit 1
        ;;
esac

if [ -x "$INSTALL_DIR/ignition.sh" ]; then
    "$INSTALL_DIR/ignition.sh" stop || echo "Warning: ignition.sh stop returned an error."
    "$INSTALL_DIR/ignition.sh" remove || echo "Warning: ignition.sh remove returned an error."
fi

# Belt and braces: make sure no unit or stale override survives a failed 'remove'.
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
rm -rf "/etc/systemd/system/${SERVICE_NAME}.service.d"
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload

rm -rf "$INSTALL_DIR"
echo "Removed $INSTALL_DIR"
