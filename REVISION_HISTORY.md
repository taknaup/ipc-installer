# Revision history

Newest first. Add an entry here with every change that is committed: version, date, what changed and why,
and the commit it came from (`git log --oneline`). Versions: first number for a redesign, second for new or
changed behaviour, third for fixes.

## 1.6.0 - 2026-10-15
- **SAP network: optional default gateway.** The gateway field now shows for SAP when the network is
  configured (the HAC number and facility address stay HAC-only). Blank means no default route is written to
  the YAML; an entered gateway becomes the default route on `eno1`. A gateway outside `eno1`'s /24 is set
  on-link; the iPC's own address and network/broadcast addresses are rejected. The confirm screen shows the
  result ("None (no default route)" or the route that will be added).

## 1.5.0 - 2026-10-14
- **Network: gateway entry.** A blank gateway puts a default route via the facility network's `.1` address on
  `enp4s0`. An entered gateway is matched to the port whose /24 it is on (controls `eno1`, SAP `enp2s0`,
  facility `enp4s0`) and the default route goes on that port. A gateway that matches none is used on `enp4s0`
  with `on-link: true`. The gateway may no longer be required to sit on the facility network.
  The confirm screen shows which port the route will land on and blocks Start for a gateway the installer
  would reject (the iPC's own address, a network or broadcast address).
- **Network templates** updated to the configuration tested on site: no fixed routes, `never-default` left
  commented out; the only route is the single default route described above.
- **SAP, Ignition-only install:** the Node choice is hidden (nothing applied depends on it). The gateway is
  named `SAP` instead of `SAP_<node>`.
- Added this revision history.

## 1.4.0 - 2026-10-13
- Network setup no longer waits for the new addresses to appear; `VALIDATE_NETWORK` in
  `config/installer.conf` (default `false`) turns that check back on. (`1dfeb2b`)
- IPv6 disabled on every port in the templates. (`9a27e12`)
- Network setup deletes every old netplan file and every stored NetworkManager ethernet profile (the
  "Wired connection" ones), stops NetworkManager recreating them, and turns off automatic DNS. Everything
  removed is backed up first and restored if applying fails. (`d59ed63`)
- Table 200 / SAP-network on-link routes were added and later superseded by the on-site templates in 1.5.0.
  (`99e805f`, `b5f417c`, `3691f47`)

## 1.3.0 - 2026-10-11
- SAP systems: the gateway upload limit (`max-file-size` in `web.xml`) is raised to 128 MB before the final
  restart. Configurable with `SAP_MAX_FILE_SIZE`. (`ebdace5`)

## 1.2.0 - 2026-10-09
- The Perspective Workstation shortcut is now marked trusted from inside the installer. (`17fc008`)
- Perspective Workstation installs into `/usr/local/share/applications/perspective-workstation`; earlier
  copies in `/opt` and loose files in the applications folder are cleaned up. (`cbb9a1c`, `f4ef507`)
- Example Workstation URL in `config/installer.conf` updated. (`62777af`)

## 1.1.0 - 2026-10-08
- Launching is `bash launch.sh` from a terminal only. A double-click launcher and a registered desktop icon
  were tried and removed. `install.sh` was removed. (`d227fe1`, `472758e`, `a6f5a8c`, `bb6886f`, `f07d655`)

## 1.0.0 - 2026-10-07 (first commit of the reworked installer)
Earlier history was removed to save disk space; this version contains everything below.
- Reliable, resumable install that keeps running if the browser closes; checks before starting; backup of any
  existing Ignition; checks each step instead of trusting exit codes.
- Three tasks: install, network only, or both. HAC number and facility address are only asked for when the
  network is configured.
- `scripts/netcfg.py`: renders and validates the netplan files, applies them, rolls back on failure.
- Touch-first interface that fits one screen, with an on-screen number pad.
- Administrator password asked for in a pop-up (pkexec); works from a USB drive and without curl or wget.
- Ignition installer judged by what it installed, not its exit code. MQTT module upload through a Python
  client. Standard gateway backup and module verified against `media/manifest.json`.
