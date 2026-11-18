#!/usr/bin/env bash
# Runs Kenbu on the desktop without XR, where maps play with autoplay.
#   scripts/run-desktop.sh [godot args...]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
exec godot --path "$root" --xr-mode off "$@"
