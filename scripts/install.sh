#!/bin/bash
# Terminal entry point; same as running "bash launch.sh" from the package folder.
# Works from a USB drive: run with  bash scripts/install.sh  (no executable bit needed).
exec bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../launch.sh"
