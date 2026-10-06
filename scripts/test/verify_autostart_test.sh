#!/usr/bin/env bash

# Tests for verify.sh's autostart checks.
#
# These stand up a synthetic repo tree in a temp dir, stub `brew` on PATH
# so the one-line Brewfile's tap reads present, and point HOME and
# MACOS_SETUP_HOST_DIR at temp dirs. They assert:
#   - a missing autostart plist is warned about without failing verify
#   - a resolved app with no matching .app is warned about without
#     failing verify
#   - a present plist and a found app are reported without a warning

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok_rc() {
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want $2)"; ((fail++)); fi
}
ok_contains() {
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_lacks() {
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output carries [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
ROOT="$SANDBOX/repo"
BINDIR="$SANDBOX/bin"
export HOME="$SANDBOX/home"
export MACOS_SETUP_HOST_DIR="$SANDBOX/host"
mkdir -p "$ROOT/scripts" "$ROOT/default" "$BINDIR" "$HOME/Applications" "$MACOS_SETUP_HOST_DIR"

cp "$REPO_ROOT/scripts/config_common.sh" "$REPO_ROOT/scripts/autostart_common.sh" \
   "$REPO_ROOT/scripts/verify.sh" "$ROOT/scripts/"
printf 'get_hostname() { echo "vautotesthost"; }\n' >> "$ROOT/scripts/config_common.sh"

cat > "$BINDIR/brew" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  tap) printf 'example/tap\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BINDIR/brew"
echo "tap 'example/tap'" > "$ROOT/default/Brewfile"

PLIST="$HOME/Library/LaunchAgents/com.macos-setup.autostart.plist"

run_verify() {
  RC=0
  OUT="$(cd "$ROOT" && PATH="$BINDIR:$PATH" /bin/bash scripts/verify.sh 2>&1)" || RC=$?
}

# Names no real Mac carries, so /Applications and /System/Applications
# never match them.
printf '[autostart]\napps = ["MacosSetupTestFound", "MacosSetupTestMissing"]\n' \
  > "$MACOS_SETUP_HOST_DIR/config.toml"
mkdir -p "$HOME/Applications/MacosSetupTestFound.app"

run_verify
ok_contains "$OUT" "WARNING: autostart LaunchAgent missing" "missing plist is warned about"
ok_contains "$OUT" "WARNING: autostart app 'MacosSetupTestMissing'" "app with no .app is warned about"
ok_contains "$OUT" "autostart:MacosSetupTestFound (found)" "found app is reported"
ok_rc "$RC" 0 "the warnings do not fail verify"

mkdir -p "$(dirname "$PLIST")"
touch "$PLIST"
run_verify
ok_contains "$OUT" "launchagent:com.macos-setup.autostart (installed)" "present plist is reported"
ok_lacks "$OUT" "WARNING: autostart LaunchAgent missing" "present plist is not warned about"
ok_rc "$RC" 0 "verify exits 0 with the plist present"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
