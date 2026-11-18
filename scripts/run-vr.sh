#!/usr/bin/env bash
# Plays Kenbu in the headset through OpenLoop's OpenXR runtime. Launch OpenLoop on the headset
# as well. OPENLOOP_DIR points at the OpenLoop checkout.
#   scripts/run-vr.sh [godot args...]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
openloop="${OPENLOOP_DIR:-$HOME/projs/openloop/openloop}"
# Optimized runtime and openloopd: a rhythm game needs every frame on time.
exec "$openloop/scripts/run.sh" --release godot --path "$root" "$@"
