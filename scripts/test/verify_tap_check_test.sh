#!/usr/bin/env bash

# Tests for verify.sh's tap check (_check_tap, issue #47).
#
# Homebrew accepts both `user/name` and `user/homebrew-name` as the same
# tap on input, but `brew tap` LISTS only the short form. A literal
# whole-line comparison of the Brewfile's spelling against that listing
# therefore reports every long-form declaration as missing, making
# `make verify` exit non-zero on a correctly provisioned host. The fix
# normalizes the Brewfile spelling to the short form before comparing.
#
# These tests stand up a synthetic repo tree in a tmpdir, stub `brew` on
# PATH so `brew tap` answers with the short form (never touching real
# Homebrew), point the host tier at a temp dir via MACOS_SETUP_HOST_DIR,
# and run the repo's verify.sh against a one-line Brewfile. They assert:
#   - a long-form tap declaration is reported present (exit 0)
#   - a short-form tap declaration is reported present (exit 0)
#   - a genuinely untapped tap is still reported missing (exit 1)

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
   "$REPO_ROOT/scripts/verify.sh" "$ROOT/scripts/"
printf 'get_hostname() { echo "vtaptesthost"; }\n' >> "$ROOT/scripts/config_common.sh"

# A stub `brew` whose `tap` subcommand lists the one installed tap under
# its short name, as real Homebrew does. The Brewfiles below carry only
# tap lines, so no other subcommand is exercised.
cat > "$BINDIR/brew" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  tap) printf 'atlassian/acli\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BINDIR/brew"

run_verify() {
  # run_verify <tap-line> -> stdout+stderr; rc in global RC
  echo "$1" > "$ROOT/default/Brewfile"
  RC=0
  OUT="$(cd "$ROOT" && PATH="$BINDIR:$PATH" bash scripts/verify.sh 2>&1)" || RC=$?
}

run_verify "tap 'atlassian/homebrew-acli'"
ok_contains "$OUT" "tap:atlassian/homebrew-acli (present)" "long-form spelling reported present"
ok_rc "$RC" 0 "long-form spelling exits 0"

run_verify "tap 'atlassian/acli'"
ok_contains "$OUT" "tap:atlassian/acli (present)" "short-form spelling reported present"
ok_rc "$RC" 0 "short-form spelling exits 0"

run_verify "tap 'other/thing'"
ok_contains "$OUT" "tap:other/thing (missing)" "untapped tap reported missing"
ok_rc "$RC" 1 "untapped tap exits 1"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
