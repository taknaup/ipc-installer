#!/usr/bin/env python3
"""Renders, validates and applies the iPC network configuration (netplan + NetworkManager).

Nothing on the system is changed until the rendered configuration has passed validation. After
applying, the expected addresses are verified and everything is rolled back if they are missing.
Exit code 0 = success, 1 = failure (details in --result-file as {"ok", "message", "hint"}).
"""
import argparse
import glob
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import yaml
except ImportError:  # python3-yaml ships with netplan.io, so this should not happen on Ubuntu
    print("ERROR: python3-yaml is not installed.", flush=True)
    sys.exit(1)

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NETPLAN_FILE = 'etc/netplan/99-netcfg.yaml'
CLOUD_CFG = 'etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
NM_CONN_DIR = 'etc/NetworkManager/system-connections'
VERIFY_TIMEOUT = 30


class NetcfgError(Exception):
    def __init__(self, message, hint=''):
        super().__init__(message)
        self.hint = hint


def log(msg):
    print(msg, flush=True)


def run_cmd(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return 127, '', f'{cmd[0]}: command not found'
    except subprocess.TimeoutExpired:
        return 124, '', f'{" ".join(cmd)} timed out after {timeout}s'
    return r.returncode, r.stdout.strip(), r.stderr.strip()


# ---------------------------------------------------------------- address resolution

def parse_ip(value, label):
    try:
        ip = ipaddress.IPv4Address(value)
    except ValueError:
        raise NetcfgError(f'{label} "{value}" is not a valid IPv4 address.')
    if ip.is_loopback or ip.is_multicast or ip.is_link_local or ip.is_unspecified or ip.is_reserved:
        raise NetcfgError(f'{label} "{value}" cannot be used as a host address.')
    return ip


def node_entry(table, node, where):
    if node in table:
        return table[node]
    raise NetcfgError(f'config.json has no {node} address for {where}.', 'Check network/config.json.')


def resolve_values(cfg, args):
    try:
        values = {'eno1_ip': node_entry(cfg['eno1'][args.system], args.node, f'eno1/{args.system}')}
        if args.system == 'HAC':
            if not args.hac or not args.facility_ip:
                raise NetcfgError('A HAC selection and facility network address are required.')
            values['enp2s0_ip'] = node_entry(cfg['enp2s0'][args.hac], args.node, f'enp2s0/{args.hac}')
            facility = parse_ip(args.facility_ip, 'Facility network address')
            values['enp4s0_ip'] = str(facility)
            if args.facility_gateway:
                gateway = parse_ip(args.facility_gateway, 'Facility gateway')
            else:
                o = str(facility).split('.')
                gateway = ipaddress.IPv4Address('.'.join(o[:3] + ['1']))
            net = ipaddress.ip_network(f'{facility}/24', strict=False)
            if facility in (net.network_address, net.broadcast_address):
                raise NetcfgError(f'Facility address {facility} is a network or broadcast address.')
            if gateway not in net:
                raise NetcfgError(f'Facility gateway {gateway} is not on the same /24 network as {facility}.')
            if gateway == facility:
                raise NetcfgError(
                    f'The facility address {facility} is the same as its default gateway {gateway}.',
                    'Enter the gateway address explicitly.')
            values['enp4s0_gateway'] = str(gateway)
    except KeyError as e:
        raise NetcfgError(f'config.json has no entry for {e}.', 'Check network/config.json.')
    for key in ('eno1_ip', 'enp2s0_ip'):
        if key in values:
            parse_ip(values[key], f'config.json address {key}')
    return values


def render(template_path, values):
    with open(template_path) as f:
        text = f.read()

    def sub(m):
        if m.group(1) not in values:
            raise NetcfgError(f'Template {os.path.basename(template_path)} needs "{m.group(1)}" which was not provided.')
        return values[m.group(1)]

    return re.sub(r'\{\{(\w+)\}\}', sub, text)


def parse_rendered(text):
    try:
        doc = yaml.safe_load(text)
        ethernets = doc['network']['ethernets']
    except Exception as e:
        raise NetcfgError(f'The generated network configuration is invalid: {e}')
    return ethernets


def check_overlaps(ethernets):
    nets = []
    for iface, conf in ethernets.items():
        for addr in conf.get('addresses', []):
            nets.append((iface, ipaddress.ip_interface(addr)))
    for i, (a_if, a) in enumerate(nets):
        for b_if, b in nets[i + 1:]:
            if a_if != b_if and a.network.overlaps(b.network):
                raise NetcfgError(
                    f'{a_if} ({a}) and {b_if} ({b}) are on overlapping networks.',
                    'Choose a facility address that is not on the controls or SAP network.')


# ---------------------------------------------------------------- system helpers

class Net:
    def __init__(self, root, live):
        self.root = root
        self.live = live

    def p(self, rel):
        return os.path.join(self.root, rel.lstrip('/'))

    def interfaces(self):
        base = self.p('sys/class/net')
        try:
            return sorted(n for n in os.listdir(base) if os.path.exists(os.path.join(base, n, 'device')))
        except OSError:
            return []

    def carrier(self, iface):
        try:
            with open(self.p(f'sys/class/net/{iface}/carrier')) as f:
                return f.read().strip() == '1'
        except OSError:
            return False

    def addresses(self, iface):
        rc, out, _ = run_cmd(['ip', '-j', '-4', 'addr', 'show', 'dev', iface])
        if rc != 0:
            return set()
        try:
            return {f"{a['local']}/{a['prefixlen']}" for d in json.loads(out) for a in d.get('addr_info', [])}
        except (ValueError, KeyError):
            return set()


def validate_staged(yaml_text):
    """Runs `netplan generate` against a throwaway root so a bad file never touches /etc."""
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, 'etc/netplan'))
        path = os.path.join(d, 'etc/netplan/99-netcfg.yaml')
        with open(path, 'w') as f:
            f.write(yaml_text)
        os.chmod(path, 0o600)
        rc, _, err = run_cmd(['netplan', 'generate', '--root-dir', d])
        if rc != 0:
            reasons = [l for l in err.splitlines() if l.startswith('ERROR')]
            raise NetcfgError('netplan rejected the generated configuration.', ' '.join(reasons) or err[-300:])


def conflicting_netplan_files(netplan_dir, ifaces):
    """Other netplan files that configure the same ports. netplan merges address lists across files, so
    leftovers (installer defaults, cloud-init, earlier manual files) would add stale addresses."""
    found = []
    for path in sorted(glob.glob(os.path.join(netplan_dir, '*.yaml'))):
        if os.path.basename(path) == os.path.basename(NETPLAN_FILE):
            continue
        try:
            with open(path) as f:
                doc = yaml.safe_load(f) or {}
            defined = set((doc.get('network') or {}).get('ethernets') or {})
        except (OSError, yaml.YAMLError) as e:
            log(f'[Network] Warning: could not read {path}: {e}')
            continue
        if defined & set(ifaces):
            found.append(path)
    return found


def nm_conflicts(net, ifaces):
    """Non-netplan NetworkManager ethernet profiles (e.g. 'Wired connection 1') bound to our ports."""
    if not net.live:
        return []
    rc, out, _ = run_cmd(['nmcli', '-t', '-f', 'UUID,NAME,TYPE,DEVICE', 'con', 'show'])
    if rc != 0:
        return []
    found = []
    for line in out.splitlines():
        parts = line.split(':')
        if len(parts) < 4 or parts[2] != '802-3-ethernet' or parts[1].startswith('netplan-'):
            continue
        uuid, device = parts[0], parts[3]
        rc, bound, _ = run_cmd(['nmcli', '-g', 'connection.interface-name,connection.autoconnect', 'con', 'show', 'uuid', uuid])
        fields = bound.splitlines() if rc == 0 else []
        iface = fields[0] if fields else ''
        autoconnect = fields[1] if len(fields) > 1 else 'yes'
        if (iface in ifaces or (not iface and device in ifaces)) and autoconnect == 'yes':
            found.append((uuid, parts[1]))
    return found


# ---------------------------------------------------------------- apply with rollback

class State:
    def __init__(self):
        self.new_file = None
        self.cloud_file = None
        self.moved = []        # (original, backup copy)
        self.nm_disabled = []  # uuids


def rollback(net, st):
    log('[Network] Rolling back to the previous network configuration...')
    if st.new_file and os.path.exists(st.new_file):
        os.remove(st.new_file)
    if st.cloud_file and os.path.exists(st.cloud_file):
        os.remove(st.cloud_file)
    for original, saved in st.moved:
        try:
            shutil.move(saved, original)
        except OSError as e:
            log(f'[Network] Warning: could not restore {original}: {e}')
    if net.live:
        for uuid in st.nm_disabled:
            run_cmd(['nmcli', 'con', 'modify', 'uuid', uuid, 'connection.autoconnect', 'yes'])
        rc, _, err = run_cmd(['netplan', 'apply'], timeout=90)
        if rc != 0:
            log(f'[Network] Warning: netplan apply during rollback failed: {err}')
    log('[Network] Previous configuration restored.')


def backup_configs(net, backup_dir):
    stamp = time.strftime('%Y%m%d-%H%M%S')
    dest = os.path.join(backup_dir, f'network-{stamp}')
    os.makedirs(dest, exist_ok=True)
    for rel in ('etc/netplan', NM_CONN_DIR):
        src = net.p(rel)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(dest, rel), dirs_exist_ok=True)
    log(f'[Network] Saved the current network configuration to {dest}')
    return dest


def check_duplicate_addresses(net, ethernets):
    if not net.live:
        return
    if not shutil.which('arping'):
        log('[Network] arping not installed; skipping duplicate-address check.')
        return
    for iface, conf in ethernets.items():
        if not net.carrier(iface):
            continue
        have = net.addresses(iface)
        for addr in conf.get('addresses', []):
            if addr in have:
                continue
            ip = addr.split('/')[0]
            rc, _, _ = run_cmd(['arping', '-D', '-q', '-c', '2', '-w', '4', '-I', iface, ip], timeout=15)
            if rc == 1:
                raise NetcfgError(f'Another device on the {iface} network already uses {ip}.',
                                  'Check the node (Primary/Backup) and HAC selection, then try again.')


def verify(net, ethernets):
    deadline = time.time() + VERIFY_TIMEOUT
    pending = {iface: set(conf.get('addresses', [])) for iface, conf in ethernets.items()}
    while True:
        missing = {i: sorted(a - net.addresses(i)) for i, a in pending.items()}
        missing = {i: a for i, a in missing.items() if a}
        if not missing:
            return
        if time.time() >= deadline:
            detail = '; '.join(f'{i}: {", ".join(a)}' for i, a in missing.items())
            raise NetcfgError(f'The new addresses did not come up ({detail}).')
        time.sleep(2)


def report_link_state(net, ethernets):
    for iface, conf in ethernets.items():
        if net.live and not net.carrier(iface):
            log(f'[Network] Warning: no cable detected on {iface}; the address is set and will work once it is plugged in.')
        for route in conf.get('routes', []):
            gw = route.get('via')
            if gw and net.live and net.carrier(iface):
                rc, _, _ = run_cmd(['ping', '-c', '1', '-W', '2', '-I', iface, gw], timeout=10)
                log(f'[Network] Gateway {gw} on {iface}: {"reachable" if rc == 0 else "not answering (continuing)"}')


def apply(net, args, yaml_text, ethernets):
    ifaces = list(ethernets)

    if net.live:
        available = net.interfaces()
        missing = [i for i in ifaces if i not in available]
        if missing:
            raise NetcfgError(
                f'This iPC has no network port named {", ".join(missing)}.',
                f'Ports found: {", ".join(available) or "none"}. Update the port names in network/config.json and the templates.')
    check_duplicate_addresses(net, ethernets)

    backup_configs(net, args.backup_dir)
    st = State()
    try:
        netplan_dir = net.p('etc/netplan')
        os.makedirs(netplan_dir, exist_ok=True)
        aside = os.path.join(args.backup_dir, 'netplan-replaced')
        os.makedirs(aside, exist_ok=True)
        for path in conflicting_netplan_files(netplan_dir, ifaces):
            saved = os.path.join(aside, f'{time.strftime("%Y%m%d-%H%M%S")}-{os.path.basename(path)}')
            shutil.move(path, saved)
            st.moved.append((path, saved))
            log(f'[Network] Moved aside conflicting {os.path.basename(path)}')

        st.new_file = net.p(NETPLAN_FILE)
        with open(st.new_file, 'w') as f:
            f.write(yaml_text)
        os.chmod(st.new_file, 0o600)

        cloud_dir = net.p('etc/cloud')
        if os.path.isdir(cloud_dir) and not os.path.exists(net.p(CLOUD_CFG)):
            os.makedirs(os.path.dirname(net.p(CLOUD_CFG)), exist_ok=True)
            with open(net.p(CLOUD_CFG), 'w') as f:
                f.write('network: {config: disabled}\n')
            st.cloud_file = net.p(CLOUD_CFG)

        for uuid, name in nm_conflicts(net, ifaces):
            rc, _, _ = run_cmd(['nmcli', 'con', 'modify', 'uuid', uuid, 'connection.autoconnect', 'no'])
            if rc == 0:
                st.nm_disabled.append(uuid)
                log(f'[Network] Disabled automatic connection profile "{name}"')

        if net.live:
            log('[Network] Applying network configuration...')
            rc, _, err = run_cmd(['netplan', 'apply'], timeout=90)
            if rc != 0:
                raise NetcfgError('netplan could not apply the configuration.', err[-300:])
            if args.skip_verify:
                log('[Network] Skipping the check that the new addresses are up (VALIDATE_NETWORK is off); '
                    'they may only appear after the iPC restarts.')
            else:
                verify(net, ethernets)
                report_link_state(net, ethernets)
    except Exception:
        rollback(net, st)
        raise
    log('[Network] Network configuration applied.' if args.skip_verify else '[Network] Network configuration applied and verified.')


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--system', required=True, choices=['HAC', 'SAP'])
    ap.add_argument('--node', required=True, choices=['Primary', 'Backup'])
    ap.add_argument('--hac', default='')
    ap.add_argument('--facility-ip', default='')
    ap.add_argument('--facility-gateway', default='')
    ap.add_argument('--config', default=os.path.join(BASE_DIR, 'network', 'config.json'))
    ap.add_argument('--template-dir', default=os.path.join(BASE_DIR, 'network'))
    ap.add_argument('--backup-dir', default='/var/backups/ignition-installer/network')
    ap.add_argument('--root', default='/', help='filesystem root to operate on (testing)')
    ap.add_argument('--dry-run', action='store_true', help='render and validate only; print the result')
    ap.add_argument('--no-apply', action='store_true', help='write files under --root but do not run netplan/nmcli')
    ap.add_argument('--skip-verify', action='store_true',
                    help='do not wait for / require the new addresses to be up after netplan apply')
    ap.add_argument('--result-file', default='')
    args = ap.parse_args()

    result = {'ok': False, 'message': '', 'hint': ''}
    try:
        with open(args.config) as f:
            cfg = json.load(f)
        values = resolve_values(cfg, args)
        template = 'hac-manager-template.yaml' if args.system == 'HAC' else 'sap-manager-template.yaml'
        yaml_text = render(os.path.join(args.template_dir, template), values)
        ethernets = parse_rendered(yaml_text)
        check_overlaps(ethernets)
        validate_staged(yaml_text)
        log(f'[Network] Configuration for {args.system} {args.node} validated: ' +
            ', '.join(f'{i}={c["addresses"][0]}' for i, c in ethernets.items()))

        if args.dry_run:
            print(yaml_text)
        else:
            net = Net(os.path.abspath(args.root), live=(os.path.abspath(args.root) == '/' and not args.no_apply))
            apply(net, args, yaml_text, ethernets)
        roles = {'eno1': 'SAP network' if args.system == 'SAP' else 'Controls network',
                 'enp2s0': 'SAP network', 'enp4s0': 'Facility network'}
        result['summary'] = [f'{roles.get(i, i)} ({i}): {c["addresses"][0]}' for i, c in ethernets.items()]
        result['verified'] = not args.skip_verify
        result['ok'] = True
    except NetcfgError as e:
        result.update(message=str(e), hint=e.hint)
    except (OSError, ValueError) as e:
        result.update(message=f'Network configuration failed: {e}')

    if args.result_file:
        with open(args.result_file, 'w') as f:
            json.dump(result, f)
    if not result['ok']:
        log(f'ERROR: {result["message"]} {result["hint"]}'.strip())
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
