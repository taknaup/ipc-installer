# iPC Setup

Installs Ignition Edge and sets up the network on a touchscreen iPC (Ubuntu).

## Using it
1. Double-click **iPC Setup** in this folder.
   - The first time, Ubuntu may ask whether to trust the launcher: choose **Trust and Launch**
     (or right-click it and choose **Allow Launching**).
2. Follow the screens: Task, This iPC, Network (HAC only), Confirm.
3. Press **Start**. A window asks for the administrator password, then setup runs.
4. When it finishes, use **Restart iPC** or **Open Perspective Workstation**, then **Finish**.

From a terminal, `bash install.sh` does the same thing.

### Running from a USB drive
Everything is started through `bash` or `python3`, so it works even when the USB is mounted `noexec` or
cannot store file permissions (FAT/exFAT/NTFS). If double-clicking **iPC Setup** does nothing or asks you
to allow launching and cannot (some USB formats), open the folder, right-click an empty area, choose
**Open in Terminal**, and run:

    bash launch.sh

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
