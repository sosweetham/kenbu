#!/usr/bin/env bash
# Headless checks: every script parses, then every tests/*.gd runs (each exits non-zero on
# failure). SONGS_DIR points the map tests at a songs folder. Nothing needs the editor's import
# step: icons, fonts and menu music are read from their files at runtime. addons/ is third-party
# editor tooling (it declares global classes) and is not parse-checked.
#   scripts/test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0

# OpenXR stays off in every headless run; a run that hangs fails after its time limit.
godot_run() {
  local limit="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$limit" godot --headless --xr-mode off --path "$root" "$@"
}

while IFS= read -r script; do
  out="$(godot_run 60 --check-only --script "res://$script" 2>&1)"
  if grep -qE 'SCRIPT ERROR|Parse Error|ERROR:' <<<"$out"; then
    echo "FAIL parse $script"
    grep -E 'SCRIPT ERROR|Parse Error|ERROR:|at: ' <<<"$out" | head -6
    failed=1
  fi
done < <(find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | sed 's|^\./||' | sort)

for test in tests/*.gd; do
  [[ -e "$test" ]] || continue
  if godot_run 600 --script "res://$test"; then
    echo "PASS $test"
  else
    echo "FAIL $test"
    failed=1
  fi
done

exit "$failed"
