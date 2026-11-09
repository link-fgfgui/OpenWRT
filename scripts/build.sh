#!/bin/sh
# Build the Orange Pi 3 LTS image (ImmortalWrt v23.05.7, Linux 5.15).
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
exec sh "$HERE/scripts/build-immortalwrt-23.05.sh" "$@"
