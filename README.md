# iPC Setup

Installs Ignition Edge and sets up the network on a touchscreen iPC (Ubuntu).

## Using it
**First time (once per iPC):** open this folder, right-click **launch.sh** and choose **Run as a Program**.
(On Ubuntu 26.04 the file manager opens `.sh` and `.desktop` files in the text editor when you
double-click them, so use the right-click menu. If you don't see "Run as a Program", right-click an empty
area of the folder, choose **Open in Terminal** and run `bash launch.sh`.)

That starts the installer in your browser and adds an **iPC Setup** icon to the application menu (press the
Super key and type "iPC Setup") and to the Desktop. From then on, just double-click that icon.

Then:
1. Follow the screens: Task, This iPC, Network (HAC only), Confirm.
2. Press **Start**. A window asks for the administrator password, then setup runs.
3. When it finishes, use **Restart iPC** or **Open Perspective Workstation**, then **Finish**.

The `iPC Setup.desktop` file in this folder is the same launcher; it only works after Ubuntu has been told
to trust it (right-click -> **Allow Launching**), so `launch.sh` is the dependable route.

### Running from a USB drive
Everything is started through `bash` or `python3`, so it works even when the USB is mounted `noexec` or
cannot store file permissions (FAT/exFAT/NTFS). If **Run as a Program** is missing or does nothing (some USB
formats), open the folder, right-click an empty area, choose **Open in Terminal**, and run:

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
