import http.server
import socketserver
import json
import subprocess
import os
import re
import sys
import ipaddress
import secrets
import atexit
import shutil
import tempfile
import threading
import time
from urllib.parse import urlparse, parse_qs

HOST = '127.0.0.1'  # local touchscreen only; never expose root-level install to the plant network
PORT = int(os.environ.get('IPC_PORT', '3636'))
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(BASE_DIR, 'web')
SETUP_SCRIPT = os.path.join(BASE_DIR, 'scripts', 'setup.sh')

# Must match scripts/setup.sh
STATE_DIR = os.environ.get('IPC_STATE_DIR', '/var/lib/ipc-installer')
LOG_DIR = os.environ.get('IPC_LOG_DIR', '/var/log/ipc-installer')
# Private per-run directory (0700): a fixed name in /tmp can belong to another user and then cannot be opened.
_launch_dir = tempfile.mkdtemp(prefix='ipc-installer-')
atexit.register(shutil.rmtree, _launch_dir, ignore_errors=True)
LAUNCH_ERR_FILE = os.path.join(_launch_dir, 'launch.err')

ALLOWED_HOSTS = {f'localhost:{PORT}', f'127.0.0.1:{PORT}'}
RUN_ID_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
LOCATION_RE = re.compile(r'^[A-Za-z0-9_.-]{0,64}$')
HAC_RE = re.compile(r'^HAC-0[1-8]$')

PW_LAUNCHER = '/usr/local/share/applications/perspective-workstation/perspectiveworkstation.sh'
CONFIG_FILE = os.path.join(BASE_DIR, 'config', 'installer.conf')

_lock = threading.Lock()
_proc = None  # Popen handle of the most recent setup.sh launch
_httpd = None


class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Clients dropping mid-response (flaky network, closed tab) are not server faults.
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)):
            return
        super().handle_error(request, client_address)


def read_status():
    try:
        with open(os.path.join(STATE_DIR, 'status.json')) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def is_running():
    if _proc is not None and _proc.poll() is None:
        return True
    status = read_status()
    pid = status.get('pid')
    return status.get('state') == 'running' and isinstance(pid, int) and os.path.exists(f'/proc/{pid}')


def validate_payload(payload):
    """Returns (clean_values, error_message)."""
    if not isinstance(payload, dict):
        return None, 'Invalid request.'

    work_mode = payload.get('work_mode', 'install')
    system_type = payload.get('system_type', '')
    node_type = payload.get('node_type', '')
    location = payload.get('location', '') or ''
    hac = payload.get('hac_selection', '') or ''
    enp4s0_ip = payload.get('enp4s0_ip', '') or ''
    enp4s0_gateway = payload.get('enp4s0_gateway', '') or ''

    if work_mode not in ('install', 'network', 'full'):
        return None, 'Task must be install, network or full.'
    if system_type not in ('HAC', 'SAP'):
        return None, 'System type must be HAC or SAP.'
    if node_type not in ('Primary', 'Backup'):
        return None, 'Node designation must be Primary or Backup.'
    if not isinstance(location, str) or not LOCATION_RE.match(location):
        return None, 'Location may only contain letters, numbers, dot, dash and underscore.'
    # HAC number and facility address only matter when the network is being configured; a gateway is optional
    # for HAC (blank = facility .1) and for SAP (blank = no default route).
    needs_network = work_mode in ('network', 'full')
    if needs_network and system_type == 'HAC':
        if re.match(r'^HAC\d+$', hac):
            hac = 'HAC-' + hac[3:]
        if not HAC_RE.match(hac):
            return None, 'HAC selection must be HAC-01 through HAC-08.'
        try:
            ipaddress.IPv4Address(enp4s0_ip)
        except ValueError:
            return None, 'Facility network address is not a valid IPv4 address.'
    else:
        hac, enp4s0_ip = '', ''
    if needs_network and enp4s0_gateway:
        # Any valid address: netcfg.py puts the default route on the port the gateway belongs to.
        try:
            gateway = ipaddress.IPv4Address(enp4s0_gateway)
        except ValueError:
            return None, 'Gateway is not a valid IPv4 address.'
        if gateway.is_loopback or gateway.is_multicast or gateway.is_unspecified or gateway.is_link_local:
            return None, 'Gateway cannot be used as a host address.'
    else:
        enp4s0_gateway = ''

    return {
        'work_mode': work_mode,
        'location': location,
        'system_type': system_type,
        'node_type': node_type,
        'hac': hac,
        'enp4s0_ip': enp4s0_ip,
        'enp4s0_gateway': enp4s0_gateway,
    }, None


PKEXEC_DENIED = ('Administrator permission was not given. Press "Try again" and enter the administrator '
                 'password when the window asks for it.')
PKEXEC_MISSING = ('This iPC cannot show the administrator password window (pkexec is missing). '
                  'Install the "pkexec" package or run the installer from a terminal with sudo.')


def launch_error_text(run_id):
    """Explains why setup.sh never produced events for run_id (e.g. the password window was dismissed)."""
    if _proc is None or _proc.poll() in (None, 0):
        return ''
    if read_status().get('run_id') == run_id:
        return ''
    try:
        with open(LAUNCH_ERR_FILE) as f:
            detail = f.read().strip()[-300:]
    except OSError:
        detail = ''
    if _proc.returncode in (126, 127):  # pkexec: dialog dismissed / not authorized
        return PKEXEC_DENIED
    return detail or f'The installer could not be started (exit code {_proc.returncode}).'


class InstallerHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

    def log_message(self, fmt, *args):
        if not self.path.startswith('/api/events'):
            super().log_message(fmt, *args)

    def _json(self, code, obj):
        body = json.dumps(obj).encode('utf-8')
        try:
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True

    def _host_ok(self):
        # Blocks DNS-rebinding style requests from web pages that are not the installer UI.
        if self.headers.get('Host', '') not in ALLOWED_HOSTS:
            self._json(403, {'error': 'Forbidden'})
            return False
        return True

    def do_GET(self):
        if not self._host_ok():
            return
        parsed = urlparse(self.path)
        if parsed.path == '/api/status':
            status = read_status()
            self._json(200, {
                'running': is_running(),
                'run_id': status.get('run_id', ''),
                'state': status.get('state', ''),
                'mode': status.get('mode', ''),
            })
        elif parsed.path == '/api/events':
            self._events(parse_qs(parsed.query))
        elif parsed.path == '/api/route-preview':
            self._route_preview(parse_qs(parsed.query))
        else:
            super().do_GET()

    def _route_preview(self, query):
        """Where the default route will go, for the confirm screen (same logic the installer uses)."""
        q = {k: (v[0] if v else '') for k, v in query.items()}
        values, error = validate_payload({
            'work_mode': 'network', 'system_type': q.get('system', 'HAC'), 'node_type': q.get('node', 'Primary'),
            'hac_selection': q.get('hac', ''), 'enp4s0_ip': q.get('ip', ''), 'enp4s0_gateway': q.get('gw', '')})
        if error:
            self._json(200, {'ok': False, 'text': error})
            return
        try:
            sys.path.insert(0, os.path.join(BASE_DIR, 'scripts'))
            import netcfg
            with open(os.path.join(BASE_DIR, 'network', 'config.json')) as f:
                cfg = json.load(f)
            self._json(200, netcfg.preview_default_route(
                cfg, values['system_type'], values['node_type'], values['hac'], values['enp4s0_ip'], values['enp4s0_gateway']))
        except Exception as e:  # missing python3-yaml, unreadable config...
            self._json(200, {'ok': False, 'text': f'Could not work out the route: {e}'})

    def _events(self, query):
        run_id = (query.get('run') or [''])[0]
        try:
            offset = max(0, int((query.get('offset') or ['0'])[0]))
        except ValueError:
            offset = 0
        if not RUN_ID_RE.match(run_id):
            self._json(400, {'error': 'Invalid run id.'})
            return

        # Check "running" BEFORE reading so a finished run can never hide unread events.
        running = is_running()
        events, next_offset = [], offset
        try:
            with open(os.path.join(LOG_DIR, f'events-{run_id}.jsonl'), 'rb') as f:
                f.seek(offset)
                data = f.read()
            end = data.rfind(b'\n')  # only whole lines
            if end >= 0:
                next_offset = offset + end + 1
                for line in data[:end].decode('utf-8', 'replace').splitlines():
                    try:
                        events.append(json.loads(line))
                    except ValueError:
                        events.append({'type': 'log', 'message': line})
        except OSError:
            pass

        self._json(200, {
            'events': events,
            'offset': next_offset,
            'running': running,
            'launch_error': '' if running else launch_error_text(run_id),
        })

    def _restart(self, payload):
        if is_running():
            self._json(409, {'error': 'An installation is still running.'})
            return
        if payload.get('confirm') is not True:
            self._json(400, {'error': 'Restart must be confirmed.'})
            return
        # An active desktop session may reboot without asking; otherwise polkit shows the password window.
        for cmd in (['systemctl', 'reboot'], ['pkexec', 'systemctl', 'reboot']):
            try:
                if subprocess.run(cmd, capture_output=True, timeout=15).returncode == 0:
                    self._json(200, {'ok': True})
                    return
            except (OSError, subprocess.TimeoutExpired):
                continue
        self._json(500, {'error': 'The iPC could not be restarted from here. Use the system menu to restart it.'})

    def _launch_hmi(self):
        if not os.path.exists(PW_LAUNCHER):
            self._json(404, {'error': 'Perspective Workstation is not installed on this iPC.'})
            return
        cmd = [PW_LAUNCHER]
        try:
            with open(CONFIG_FILE) as f:
                m = re.search(r'^WORKSTATION_URL="([^"]*)"', f.read(), re.M)
            if m and re.match(r'^[A-Za-z0-9:/._?&=%#@-]+$', m.group(1)):
                cmd.append(m.group(1))
        except OSError:
            pass
        try:
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            self._json(500, {'error': f'Could not start Perspective Workstation: {e}'})
            return
        self._json(200, {'ok': True})

    def do_POST(self):
        if not self._host_ok():
            return
        if self.path not in ('/api/install', '/api/restart', '/api/launch-hmi', '/api/quit'):
            self.send_error(404, 'Not Found')
            return
        if 'application/json' not in self.headers.get('Content-Type', ''):
            self._json(415, {'error': 'Expected application/json.'})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 4096:
                raise ValueError
            payload = json.loads(self.rfile.read(length).decode('utf-8'))
        except (ValueError, UnicodeDecodeError):
            self._json(400, {'error': 'Invalid request.'})
            return

        if self.path == '/api/restart':
            self._restart(payload)
            return
        if self.path == '/api/launch-hmi':
            self._launch_hmi()
            return
        if self.path == '/api/quit':
            self._json(200, {'ok': True})
            if _httpd is not None:
                threading.Thread(target=_httpd.shutdown, daemon=True).start()
            return

        values, error = validate_payload(payload)
        if error:
            self._json(400, {'error': error})
            return

        global _proc
        with _lock:
            if is_running():
                self._json(409, {'error': 'An installation is already running.'})
                return

            if not shutil.which('pkexec'):
                self._json(500, {'error': PKEXEC_MISSING})
                return

            run_id = time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(2)
            mode = 'fresh'
            previous = read_status().get('run_id', '')
            if payload.get('retry') and RUN_ID_RE.match(previous or ''):
                run_id, mode = previous, 'resume'

            try:
                # pkexec shows the graphical administrator-password window (polkit), so no terminal is needed.
                # Own process group: Ctrl+C or closing the browser never kills the install.
                with open(LAUNCH_ERR_FILE, 'w') as err:
                    _proc = subprocess.Popen(
                        ['pkexec', '/bin/bash', SETUP_SCRIPT, values['location'], values['system_type'],
                         values['node_type'], values['hac'], values['enp4s0_ip'], run_id, mode, values['work_mode'], values['enp4s0_gateway']],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err,
                        process_group=0, cwd=BASE_DIR)
            except OSError as e:
                self._json(500, {'error': f'Could not start the installer: {e}'})
                return

        self._json(200, {'run_id': run_id, 'resumed': mode == 'resume'})


if __name__ == '__main__':
    with ReusableTCPServer((HOST, PORT), InstallerHandler) as httpd:
        _httpd = httpd
        print(f"Starting Installer Web Server on http://localhost:{PORT}")
        print("Press Ctrl+C to stop.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down server.")
            httpd.server_close()
