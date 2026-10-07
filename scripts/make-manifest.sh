#!/bin/bash
# Regenerates media/manifest.json (exact payload file names + sha256).
# Run this whenever the installer, module or backup in media/ changes.
set -euo pipefail
cd "$(dirname "$0")/../media"

pick() {
    local pattern="$1" matches=()
    mapfile -t matches < <(compgen -G "$pattern" || true)
    if [ "${#matches[@]}" -ne 1 ]; then
        echo "Expected exactly one file matching media/$pattern, found ${#matches[@]}: ${matches[*]:-none}" >&2
        exit 1
    fi
    printf '%s' "${matches[0]}"
}

INSTALLER=$(pick 'software/ignition-*.run')
MODULE=$(pick 'modules/MQTT-Transmission*.modl')
BACKUP=$(pick 'backups/*.gwbk')

python3 - "$INSTALLER" "$MODULE" "$BACKUP" <<'PY'
import hashlib, json, sys

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

manifest = {
    key: {"file": path, "sha256": sha256(path)}
    for key, path in zip(("installer", "module", "backup"), sys.argv[1:])
}
with open("manifest.json", "w") as f:
    json.dump(manifest, f, indent=4)
    f.write("\n")
print(json.dumps(manifest, indent=4))
PY
