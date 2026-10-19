#!/usr/bin/env bash

# Tests for verify.sh on tap-qualified (`<user>/<tap>/<name>`) Brewfile
# entries.
#
# `brew list --cask --versions` fails on a tap-qualified cask name, and
# `command -v` never finds a name containing `/`, so verify.sh looks a
# package up by its bare token while printing the name as the Brewfile
# writes it.
#
# These tests stand up a synthetic repo tree in a tmpdir, stub `brew` and
# `acli` on PATH (never touching real Homebrew), point the host tier at a
# temp dir via MACOS_SETUP_HOST_DIR, and run the repo's verify.sh against a
# one-line Brewfile. They assert:
#   - a tap-qualified cask that `brew list --cask --versions <token>`
#     knows is reported installed (exit 0)
#   - a tap-qualified cask brew does not know is reported missing (exit 1)
#   - a tap-qualified formula whose bare token is on PATH is reported
#     installed with its version, not "not on PATH?"

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
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}

ROOT="$(mktemp -d)"
HOSTDIR="$(mktemp -d)"
BINDIR="$(mktemp -d)"
export MACOS_SETUP_HOST_DIR="$HOSTDIR"
trap 'rm -rf "$ROOT" "$HOSTDIR" "$BINDIR"' EXIT

mkdir -p "$ROOT/scripts" "$ROOT/default"
cp "$REPO_ROOT/scripts/config_common.sh" \
   "$REPO_ROOT/scripts/autostart_common.sh" \
   "$REPO_ROOT/scripts/verify.sh" "$ROOT/scripts/"
printf 'get_hostname() { echo "vtapqualtesthost"; }\n' >> "$ROOT/scripts/config_common.sh"

# A stub `brew` that knows exactly one cask, `lstk`, and only by its bare
# token, as real Homebrew does. Every other call fails.
cat > "$BINDIR/brew" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "list --cask --versions lstk" ]]; then
  printf 'lstk 1.0.0\n'
  exit 0
fi
exit 1
STUB
chmod +x "$BINDIR/brew"

# A stub `acli` on PATH that answers `--version`.
cat > "$BINDIR/acli" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { printf 'acli version 1.2.3\n'; exit 0; }
exit 1
STUB
chmod +x "$BINDIR/acli"

run_verify() {
  # run_verify <brewfile-line> -> stdout+stderr in OUT; rc in RC
  echo "$1" > "$ROOT/default/Brewfile"
  RC=0
  OUT="$(cd "$ROOT" && PATH="$BINDIR:$PATH" /bin/bash scripts/verify.sh 2>&1)" || RC=$?
}

run_verify "cask 'localstack/tap/lstk'"
ok_contains "$OUT" "cask:localstack/tap/lstk (installed)" "tap-qualified cask reported installed"
ok_rc "$RC" 0 "tap-qualified cask exits 0"

run_verify "cask 'other/tap/nothere'"
ok_contains "$OUT" "cask:other/tap/nothere (missing)" "unknown tap-qualified cask reported missing"
ok_rc "$RC" 1 "unknown tap-qualified cask exits 1"

run_verify "brew 'atlassian/acli/acli'"
ok_contains "$OUT" "brew:atlassian/acli/acli (installed) - acli version 1.2.3" "tap-qualified formula on PATH reported with version"
ok_absent "$OUT" "not on PATH?" "tap-qualified formula not reported off PATH"
ok_rc "$RC" 0 "tap-qualified formula exits 0"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
