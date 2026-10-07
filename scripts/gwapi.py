#!/usr/bin/env python3
"""Minimal HTTP client for the Ignition gateway.

Air-gapped iPCs do not ship curl, but Python 3 is always present, so setup.sh uses this instead.

  gwapi.py state URL                      print the "state" from a StatusPing response (blank if unreachable)
  gwapi.py post URL [--file PATH] [--timeout SECONDS]
                                          POST (optionally the file as application/octet-stream);
                                          print the response body; exit 1 on any error
"""
import json
import os
import sys
import urllib.error
import urllib.request

# The gateway is local; never go through a configured proxy.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def cmd_state(url):
    try:
        with OPENER.open(url, timeout=5) as r:
            print(json.load(r).get('state', ''))
    except Exception:
        print('')
    return 0


def cmd_post(url, path, timeout):
    headers = {}
    data = b''
    fh = None
    try:
        if path:
            fh = open(path, 'rb')
            data = fh
            headers = {'Content-Type': 'application/octet-stream', 'Content-Length': str(os.path.getsize(path))}
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')
        with OPENER.open(req, timeout=timeout) as r:
            sys.stdout.write(r.read().decode('utf-8', 'replace'))
        return 0
    except urllib.error.HTTPError as e:
        sys.stderr.write(f'HTTP {e.code} {e.reason}: {e.read().decode("utf-8", "replace")[:300]}\n')
    except Exception as e:  # connection refused, timeout, unreadable file...
        sys.stderr.write(f'{type(e).__name__}: {e}\n')
    finally:
        if fh:
            fh.close()
    return 1


def main(argv):
    if len(argv) >= 3 and argv[1] == 'state':
        return cmd_state(argv[2])
    if len(argv) >= 3 and argv[1] == 'post':
        path, timeout, rest = '', 60.0, argv[3:]
        while rest:
            if rest[0] == '--file' and len(rest) > 1:
                path, rest = rest[1], rest[2:]
            elif rest[0] == '--timeout' and len(rest) > 1:
                timeout, rest = float(rest[1]), rest[2:]
            else:
                sys.stderr.write(f'Unknown argument: {rest[0]}\n')
                return 2
        return cmd_post(argv[2], path, timeout)
    sys.stderr.write(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
