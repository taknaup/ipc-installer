#!/bin/bash
# Terminal entry point. Double-clicking "iPC Setup" does the same thing without a terminal.
# Works from a USB drive: run with  bash install.sh  (no executable bit needed).
exec bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/launch.sh"
