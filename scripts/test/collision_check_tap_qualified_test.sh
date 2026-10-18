#!/usr/bin/env bash

# Tests for collision_check.sh on tap-qualified (`<user>/<tap>/<name>`)
# Brewfile entries and removal identifiers.
#
# A same-tier collision compares bare tokens — the name with any
# `<user>/<tap>/` prefix stripped — on both the Brewfile and the removal
# side, so a tap-qualified spelling on either side still collides with
# the bare spelling on the other.
#
# These tests stand up a synthetic repo tree in a tmpdir, point the host
# tier at a temp dir via MACOS_SETUP_HOST_DIR, and run collision_check.sh
# in report mode, which writes nothing. No brew call is made, but `brew`
# is stubbed on PATH all the same so none could reach real Homebrew.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok_rc() {
  # ok_rc <actual_rc> <want_rc> <label>
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want $2)"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}

ROOT="$(mktemp -d)"
HOSTDIR="$(mktemp -d)"
BINDIR="$(mktemp -d)"
export MACOS_SETUP_HOST_DIR="$HOSTDIR"
trap 'rm -rf "$ROOT" "$HOSTDIR" "$BINDIR"' EXIT

mkdir -p "$ROOT/scripts" "$ROOT/default"
cp "$REPO_ROOT/scripts/config_common.sh" \
   "$REPO_ROOT/scripts/collision_check.sh" "$ROOT/scripts/"

printf '#!/usr/bin/env bash\nexit 1\n' > "$BINDIR/brew"
chmod +x "$BINDIR/brew"

run_check() {
  # run_check <brewfile-line> <uninstall-entry> -> output in OUT; rc in RC
  printf '%s\n' "$1" > "$ROOT/default/Brewfile"
  printf '[profile]\nuninstall = ["%s"]\n' "$2" > "$ROOT/default/config.toml"
  RC=0
  OUT="$(cd "$ROOT" && PATH="$BINDIR:$PATH" bash scripts/collision_check.sh 2>&1)" || RC=$?
}

run_check "cask 'localstack/tap/lstk'" "cask:lstk"
ok_contains "$OUT" "same-tier collision in core" "tap-qualified cask collides with cask:lstk"
ok_rc "$RC" 1 "tap-qualified cask vs cask:lstk exits 1"

run_check "brew 'lstk'" "brew:localstack/tap/lstk"
ok_contains "$OUT" "same-tier collision in core" "brew 'lstk' collides with brew:localstack/tap/lstk"
ok_rc "$RC" 1 "brew 'lstk' vs tap-qualified brew: exits 1"

run_check "cask 'localstack/tap/lstk'" "brew:lstk"
ok_contains "$OUT" "no same-tier" "a cask does not collide with a brew: entry of the same token"
ok_rc "$RC" 0 "cask vs brew: of the same token exits 0"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
