#!/usr/bin/env bash
# Records the README demos with vhs (brew install vhs), using your own nvim config.
#   ./assets/record.sh            # all demos
#   ./assets/record.sh symbol     # just one
# Your rtfm history/bookmarks/favorites are backed up and restored, so the demos leave no trace.
set -euo pipefail
cd "$(dirname "$0")"
command -v vhs >/dev/null || { echo "vhs not found: brew install vhs"; exit 1; }

data="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/rtfm"
files=(history.json bookmarks.json favorites.json)
backup=$(mktemp -d)
for f in "${files[@]}"; do [[ -f "$data/$f" ]] && cp "$data/$f" "$backup/"; done
restore() {
  for f in "${files[@]}"; do
    if [[ -f "$backup/$f" ]]; then cp "$backup/$f" "$data/$f"; else rm -f "$data/$f"; fi
  done
  rm -rf "$backup"
}
trap restore EXIT

mkdir -p out
nvim --headless -u NONE -l warm.lua

tapes=("$@")
[[ ${#tapes[@]} -eq 0 ]] && tapes=(picker symbol ask offline)
for t in "${tapes[@]}"; do
  echo "==> recording $t"
  vhs "tapes/$t.tape"
done
echo "done: $(ls *.gif *.png 2>/dev/null | tr '\n' ' ')"
