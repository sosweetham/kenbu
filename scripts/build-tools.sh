#!/usr/bin/env bash
# Builds Kenbu's native tools into tools/bin/: kenbu-import, the BeatMods model importer
# (tools/kenbu-import, Rust), and kenbu-shader, the translator of the models' compiled shaders
# (tools/kenbu-shader, Rust). Unit tests and clippy (warnings are errors) run first, so a broken
# tool is never installed.
#   scripts/build-tools.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/tools/kenbu-import/Cargo.toml"

cargo test --release --manifest-path "$manifest" --package kenbu-import --quiet
cargo clippy --release --manifest-path "$manifest" --package kenbu-import --all-targets -- -D warnings
cargo build --release --manifest-path "$manifest" --package kenbu-import

mkdir -p "$root/tools/bin"
# Copy then rename, so a Kenbu running an import never sees a half-written binary.
cp "$root/tools/kenbu-import/target/release/kenbu-import" "$root/tools/bin/kenbu-import.new"
mv "$root/tools/bin/kenbu-import.new" "$root/tools/bin/kenbu-import"
"$root/tools/bin/kenbu-import" --version

"$root/tools/kenbu-shader/build.sh"
