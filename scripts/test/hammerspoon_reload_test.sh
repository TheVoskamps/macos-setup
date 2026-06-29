#!/usr/bin/env bash

# Tests for the robust Hammerspoon reload path (issue #18).
#
# The chicken-and-egg bug: hs.ipc's message port is set up by
# `require("hs.ipc")` INSIDE init.lua, so when init.lua is broken or has
# never loaded from the current checkout (a stale symlink), the IPC port is
# down -- and `hs -c "hs.reload()"` IS the IPC path, so the one mechanism
# the script used to reload is the one that cannot work in exactly the
# broken state where reloading matters most. The old code also swallowed
# the real IPC error (`2>/dev/null`) and printed a soft `Note:` that got
# lost in the `make ui` output wall.
#
# reload_hammerspoon now:
#   1. tries IPC WITHOUT discarding stderr (the real error is the signal),
#   2. on IPC failure relaunches the app (killall + open) -- IPC-independent,
#      so it works even when init.lua never loaded -- and re-probes IPC,
#   3. if neither path works, emits a LOUD warning (to stderr) with the
#      manual-reload instruction and returns non-zero (does NOT claim
#      success).
#
# These tests source scripts/hammerspoon_setup.sh (which returns early when
# sourced, exposing only the command-override vars + reload_hammerspoon) and
# drive reload_hammerspoon with stub `hs`/`killall`/`open` binaries via the
# HS/KILLALL/OPEN env overrides, recording each invocation so we can assert
# the call sequence per scenario without a real Hammerspoon.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_ROOT/scripts/hammerspoon_setup.sh"

pass=0
fail=0
ok() {
  # ok <actual> <want> <label>
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Write a stub command at $1 that appends its name+args to $TMP/calls.log,
# emits a recognizable line on stderr, and exits with $2.
write_stub() {
  local path="$1" rc="$2" name
  name="$(basename "$path")"
  cat > "$path" <<STUB
#!/usr/bin/env bash
echo "$name \$*" >> "$TMP/calls.log"
echo "[$name-stub] called with: \$*" >&2
exit $rc
STUB
  chmod +x "$path"
}

# An `hs` stub whose exit code is read fresh from \$TMP/hs_rc on EACH call,
# so scenario 2 can make the first IPC probe fail and the post-relaunch
# probe succeed. Emits the real-world IPC error text on the failing path so
# we can assert it is surfaced (not swallowed).
write_hs_stub() {
  cat > "$TMP/hs" <<STUB
#!/usr/bin/env bash
rc="\$(cat "$TMP/hs_rc")"
echo "hs \$*" >> "$TMP/calls.log"
if [[ "\$rc" != "0" ]]; then
  echo "can't access Hammerspoon message port Hammerspoon; is it running with the ipc module loaded?" >&2
fi
# After the first call, flip to the value in hs_rc_next (used by the
# relaunch-succeeds scenario where the post-relaunch probe must pass).
if [[ -f "$TMP/hs_rc_next" ]]; then
  cp "$TMP/hs_rc_next" "$TMP/hs_rc"
  rm -f "$TMP/hs_rc_next"
fi
exit "\$rc"
STUB
  chmod +x "$TMP/hs"
}

# Source the script under test; the sourcing guard returns before any
# symlink work or config_common.sh sourcing happens.
# shellcheck disable=SC1090
source "$SETUP"
# The sourced script runs `set -e`; turn it back off so our `((pass++))`
# arithmetic (which returns the pre-increment value, i.e. status 1 when the
# counter is 0) does not abort the test harness mid-run.
set +e

ok "$(type -t reload_hammerspoon)" "function" \
  "sourcing hammerspoon_setup.sh exposes reload_hammerspoon"

# Drive reload_hammerspoon with stubbed commands. Echoes
# "<rc>|<combined-output>" and leaves $TMP/calls.log for sequence asserts.
run_reload() {
  # args: <first-hs-rc> <hs-rc-after-first-call> <killall-rc> <open-rc>
  : > "$TMP/calls.log"
  printf '%s' "$1" > "$TMP/hs_rc"
  printf '%s' "$2" > "$TMP/hs_rc_next"
  write_hs_stub
  write_stub "$TMP/killall" "$3"
  write_stub "$TMP/open" "$4"
  local out rc
  out="$(HS="$TMP/hs" KILLALL="$TMP/killall" OPEN="$TMP/open" \
    HS_RELAUNCH_SETTLE=0 reload_hammerspoon 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

echo "=== hammerspoon reload_hammerspoon tests ==="

# --- Scenario 1: IPC reload succeeds on the first try ---
res="$(run_reload 0 0 0 0)"; rc="${res%%|*}"; out="${res#*|}"
ok "$rc" "0" "IPC succeeds -> reload returns 0"
ok_contains "$out" "reloaded (via IPC)" "IPC success -> reports IPC reload"
ok_absent "$(cat "$TMP/calls.log")" "killall" \
  "IPC success -> does NOT relaunch (no killall)"
ok_absent "$(cat "$TMP/calls.log")" "open" \
  "IPC success -> does NOT relaunch (no open)"

# --- Scenario 2: IPC fails, relaunch + re-probe succeeds ---
# First hs call fails (IPC down); after the failure the stub flips hs_rc to
# 0 so the post-relaunch probe passes.
res="$(run_reload 1 0 0 0)"; rc="${res%%|*}"; out="${res#*|}"
ok "$rc" "0" "IPC fails then relaunch works -> reload returns 0"
ok_contains "$out" "relaunched and config reloaded" \
  "relaunch path -> reports relaunch+reload success"
ok_contains "$(cat "$TMP/calls.log")" "killall Hammerspoon" \
  "relaunch path -> kills the running Hammerspoon"
ok_contains "$(cat "$TMP/calls.log")" "open -a Hammerspoon" \
  "relaunch path -> opens Hammerspoon afresh"
# The real IPC error must be surfaced, not swallowed (the core bug).
ok_contains "$out" "can't access Hammerspoon message port" \
  "IPC failure -> the real IPC error is surfaced (stderr not swallowed)"

# --- Scenario 3: IPC fails AND post-relaunch probe also fails ---
# hs fails on every call (hs_rc stays 1, hs_rc_next also 1).
res="$(run_reload 1 1 0 0)"; rc="${res%%|*}"; out="${res#*|}"
ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
  "both paths fail -> reload returns non-zero (does NOT claim success)"
ok_contains "$out" "WARNING: Could not reload Hammerspoon" \
  "both paths fail -> emits a loud WARNING (not a soft Note:)"
ok_contains "$out" "Reload Config" \
  "both paths fail -> warning includes the manual menubar-reload instruction"
ok_absent "$out" "Note: Could not reload" \
  "both paths fail -> no soft 'Note:' line (old buried failure mode is gone)"

# --- Regression: the source no longer swallows the IPC stderr ---
ok_absent "$(cat "$SETUP")" 'hs -c "hs.reload()" 2>/dev/null' \
  "source -> the old stderr-swallowing one-liner is gone"

# --- Regression: the pgrep running-guard is preserved (issue #18 note) ---
# The script must still gate the reload on Hammerspoon actually running, so
# it never launches Hammerspoon where it was deliberately not running.
ok_contains "$(cat "$SETUP")" 'PGREP" -q Hammerspoon' \
  "source -> reload is still gated on a pgrep running-check"

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All hammerspoon reload tests passed."
  exit 0
fi
echo "Some hammerspoon reload tests FAILED."
exit 1
