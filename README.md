# iPC Setup

Installs Ignition Edge and sets up the network on a touchscreen iPC (Ubuntu).

## Using it
Open a terminal in this folder (right-click an empty area of the folder, then **Open in Terminal**) and run:

    bash launch.sh

The installer opens in your browser.
1. Follow the screens: Task, This iPC, Network (HAC only), Confirm.
2. Press **Start**. A window asks for the administrator password, then setup runs.
3. When it finishes, use **Restart iPC** or **Open Perspective Workstation**, then **Finish**.

### Running from a USB drive
Everything is started through `bash` or `python3`, so `bash launch.sh` works even when the USB is mounted
`noexec` or cannot store file permissions (FAT/exFAT/NTFS).

Nothing needs to be installed on the iPC first: only Python 3 and the tools that ship with Ubuntu Desktop
are used (no curl or wget).

## Settings
`config/installer.conf` holds the standard admin account, the service user, and the Workstation project
URL. Network addresses are in `network/config.json`.

## Logs and backups
- Installer logs: `/var/log/ipc-installer/`
- Backups of anything replaced: `/var/backups/ignition-installer/`
- Launcher log: `~/.local/state/ipc-installer/server.log`

## Maintaining the package
After changing anything in `media/`, run `scripts/make-manifest.sh` to refresh `media/manifest.json`.
