#!/usr/bin/env bash
# Builds kenbu-shader, the Unity shader translator, into tools/bin/ (beside kenbu-import, which
# scripts/build-tools.sh builds). Its unit tests and clippy (warnings are errors) run first, so a
# broken translator is never installed.
#   tools/kenbu-shader/build.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
manifest="$root/tools/kenbu-shader/Cargo.toml"

cargo test --release --manifest-path "$manifest" --quiet
cargo clippy --release --manifest-path "$manifest" --all-targets -- -D warnings
cargo build --release --manifest-path "$manifest"

mkdir -p "$root/tools/bin"
# Copy then rename, so a Kenbu running a translation never sees a half-written binary.
cp "$root/tools/kenbu-shader/target/release/kenbu-shader" "$root/tools/bin/kenbu-shader.new"
mv "$root/tools/bin/kenbu-shader.new" "$root/tools/bin/kenbu-shader"
"$root/tools/bin/kenbu-shader" --version
