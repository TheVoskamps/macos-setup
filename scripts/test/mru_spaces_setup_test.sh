#!/usr/bin/env bash

# Tests for scripts/mru_spaces_setup.sh.
#
# HOME and MACOS_SETUP_HOST_DIR point at temp dirs, and `defaults` and
# `killall` stubs that record every call sit first on PATH. The
# `defaults read` stub reports the value in $MRU_STATE, or fails when that
# file is absent, as an unset key does. The tests assert:
#   - a fullscreen monitor with mru-spaces on writes it false and
#     restarts the Dock
#   - a fullscreen monitor with mru-spaces unset does the same
#   - a fullscreen monitor with mru-spaces already 0 changes nothing
#   - no fullscreen monitor, in the host tier or the repo default,
#     changes nothing
#   - the script never writes mru-spaces true and never calls dasel itself

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/mru_spaces_setup.sh"

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++))
  fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export MACOS_SETUP_HOST_DIR="$SANDBOX/host"
BINDIR="$SANDBOX/bin"
CALLS="$SANDBOX/calls.log"
MRU_STATE="$SANDBOX/mru"
mkdir -p "$HOME" "$MACOS_SETUP_HOST_DIR/.hammerspoon" "$BINDIR"

cat > "$BINDIR/defaults" <<STUB
#!/usr/bin/env bash
echo "defaults \$*" >> "$CALLS"
if [[ "\$1" == "read" ]]; then
  [[ -f "$MRU_STATE" ]] || exit 1
  cat "$MRU_STATE"
fi
STUB
cat > "$BINDIR/killall" <<STUB
#!/usr/bin/env bash
echo "killall \$*" >> "$CALLS"
STUB
chmod +x "$BINDIR/defaults" "$BINDIR/killall"

FULLSCREEN_JSON='{"monitors":{"primary":{"role":"primary"},"side":{"apps":["Slack"],"fullscreen":true}}}'
WINDOWED_JSON='{"monitors":{"primary":{"role":"primary"},"side":{"apps":["Slack"],"fullscreen":false}}}'

# Args: host monitors.json content ("" for none), mru-spaces value ("" for unset)
run_setup() {
  rm -f "$CALLS" "$MRU_STATE" "$MACOS_SETUP_HOST_DIR/.hammerspoon/monitors.json"
  touch "$CALLS"
  [[ -n "$1" ]] && printf '%s\n' "$1" > "$MACOS_SETUP_HOST_DIR/.hammerspoon/monitors.json"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$MRU_STATE"
  PATH="$BINDIR:$PATH" /bin/bash "$SCRIPT" >/dev/null 2>&1
}

writes() { grep -c '^defaults write' "$CALLS"; }
kills() { grep -c '^killall' "$CALLS"; }

run_setup "$FULLSCREEN_JSON" "1"
ok "$?" "0" "fullscreen, mru on: exits 0"
ok "$(grep '^defaults write' "$CALLS")" "defaults write com.apple.dock mru-spaces -bool false" \
  "fullscreen, mru on: writes mru-spaces false"
ok "$(grep '^killall' "$CALLS")" "killall Dock" "fullscreen, mru on: restarts the Dock"

run_setup "$FULLSCREEN_JSON" ""
ok "$?" "0" "fullscreen, mru unset: exits 0"
ok "$(writes)" "1" "fullscreen, mru unset: writes mru-spaces"
ok "$(kills)" "1" "fullscreen, mru unset: restarts the Dock"

run_setup "$FULLSCREEN_JSON" "0"
ok "$?" "0" "fullscreen, mru off: exits 0"
ok "$(writes)" "0" "fullscreen, mru off: writes nothing"
ok "$(kills)" "0" "fullscreen, mru off: leaves the Dock alone"

run_setup "$WINDOWED_JSON" "1"
ok "$?" "0" "no fullscreen monitor: exits 0"
ok "$(writes)" "0" "no fullscreen monitor: writes nothing"
ok "$(kills)" "0" "no fullscreen monitor: leaves the Dock alone"
ok "$(grep -c 'mru-spaces' "$CALLS")" "0" "no fullscreen monitor: never reads mru-spaces"

run_setup "" "1"
ok "$?" "0" "repo default monitors.json: exits 0"
ok "$(writes)" "0" "repo default monitors.json: writes nothing"

ok "$(grep -c -- '-bool true' "$SCRIPT")" "0" "script never writes mru-spaces true"
ok "$(grep -c 'dasel' "$SCRIPT")" "0" "script never calls dasel itself"

echo ""
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
