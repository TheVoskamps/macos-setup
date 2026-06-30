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
#      so it works even when init.lua never loaded -- and confirms the app
#      came back with a READ-ONLY liveness probe (`hs -c "true"`, NOT a
#      second hs.reload()), polled with retry up to a bounded timeout,
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

# An `hs` stub driven by a SEQUENCE of exit codes (one per line in
# $TMP/hs_rc_seq), consumed one per call. This models the retry loop: e.g.
# "1 1 1 0" makes the initial IPC reload fail, the first two post-relaunch
# liveness probes fail, and the third probe succeed. The LAST code in the
# sequence repeats for any further calls (so a "1\n1" sequence keeps
# failing forever, used by the give-up scenario). Each call records its
# argv to calls.log and, on a non-zero code, emits the real-world IPC error
# text so we can assert it is surfaced (not swallowed). The per-call index
# lives in $TMP/hs_call_n.
write_hs_stub() {
  cat > "$TMP/hs" <<STUB
#!/usr/bin/env bash
echo "hs \$*" >> "$TMP/calls.log"
# Determine which call this is (0-based) and bump the counter.
n=0
[[ -f "$TMP/hs_call_n" ]] && n="\$(cat "$TMP/hs_call_n")"
echo "\$(( n + 1 ))" > "$TMP/hs_call_n"
# Read the rc sequence into an array (avoid mapfile -- macOS ships bash 3.2).
seq=()
while IFS= read -r line; do seq+=("\$line"); done < "$TMP/hs_rc_seq"
# Pick the rc for this call; clamp to the last entry for overflow calls.
idx="\$n"
(( idx >= \${#seq[@]} )) && idx=\$(( \${#seq[@]} - 1 ))
rc="\${seq[idx]}"
if [[ "\$rc" != "0" ]]; then
  echo "can't access Hammerspoon message port Hammerspoon; is it running with the ipc module loaded?" >&2
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
# The first arg is a space-separated SEQUENCE of `hs` exit codes (one per
# call, last repeats); e.g. "0" = IPC reload succeeds first try, "1 0" =
# IPC reload fails then the first liveness probe passes, "1 1 1 0" = IPC
# reload fails and the liveness probe passes on its third try, "1 1" = IPC
# reload fails and every probe fails (give-up path).
#
# HS_RELAUNCH_INTERVAL=0 keeps the retry loop from really sleeping; the
# bounded HS_RELAUNCH_TIMEOUT still caps the number of attempts.
run_reload() {
  # args: <hs-rc-sequence> <killall-rc> <open-rc> [hs_relaunch_timeout]
  : > "$TMP/calls.log"
  : > "$TMP/hs_call_n"
  printf '0' > "$TMP/hs_call_n"
  printf '%s\n' $1 > "$TMP/hs_rc_seq"
  write_hs_stub
  write_stub "$TMP/killall" "$2"
  write_stub "$TMP/open" "$3"
  local timeout="${4:-15}"
  local out rc
  out="$(HS="$TMP/hs" KILLALL="$TMP/killall" OPEN="$TMP/open" \
    HS_RELAUNCH_INTERVAL=0 HS_RELAUNCH_TIMEOUT="$timeout" \
    reload_hammerspoon 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

# count_lines_matching <fixed-needle>: how many lines of calls.log contain
# the needle (used to assert call counts, e.g. exactly one hs.reload()).
count_lines_matching() {
  grep -cF -- "$1" "$TMP/calls.log" 2>/dev/null || echo 0
}

echo "=== hammerspoon reload_hammerspoon tests ==="

# --- Scenario 1: IPC reload succeeds on the first try ---
res="$(run_reload 0 0 0)"; rc="${res%%|*}"; out="${res#*|}"
ok "$rc" "0" "IPC succeeds -> reload returns 0"
ok_contains "$out" "reloaded (via IPC)" "IPC success -> reports IPC reload"
ok_absent "$(cat "$TMP/calls.log")" "killall" \
  "IPC success -> does NOT relaunch (no killall)"
ok_absent "$(cat "$TMP/calls.log")" "open" \
  "IPC success -> does NOT relaunch (no open)"

# --- Scenario 2: IPC fails, relaunch + read-only liveness probe succeeds ---
# First hs call (the IPC reload) fails (IPC down); the post-relaunch
# liveness probe then passes on its first try.
res="$(run_reload "1 0" 0 0)"; rc="${res%%|*}"; out="${res#*|}"
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
# The post-relaunch confirmation is a READ-ONLY liveness probe, not a
# second hs.reload(): there must be exactly ONE hs.reload() (the initial
# IPC attempt) and at least one read-only `hs -c true` confirmation.
ok "$(count_lines_matching 'hs -c hs.reload()')" "1" \
  "relaunch path -> confirmation does NOT trigger a second hs.reload()"
ok_contains "$(cat "$TMP/calls.log")" "hs -c true" \
  "relaunch path -> confirmation uses a read-only liveness probe (hs -c true)"

# --- Scenario 2b: post-relaunch probe needs RETRIES before IPC is back ---
# The IPC reload fails, then the liveness probe fails twice (cold launch
# still bringing IPC up) and passes on the third attempt. With a bounded
# timeout the loop must keep polling and ultimately succeed.
res="$(run_reload "1 1 1 0" 0 0)"; rc="${res%%|*}"; out="${res#*|}"
ok "$rc" "0" "probe retries then succeeds -> reload returns 0"
ok_contains "$out" "relaunched and config reloaded" \
  "retry path -> reports relaunch+reload success once a probe passes"
# 1 initial reload probe is hs.reload(); the 3 liveness probes are hs -c true.
ok "$(count_lines_matching 'hs -c true')" "3" \
  "retry path -> polls the read-only probe until it passes (3 attempts)"
ok "$(count_lines_matching 'hs -c hs.reload()')" "1" \
  "retry path -> still only one hs.reload() (the initial IPC attempt)"

# --- Scenario 3: IPC fails AND every post-relaunch probe also fails ---
# hs fails on every call; the bounded retry loop gives up after exhausting
# its attempts. A small timeout keeps the test fast while still exercising
# more than one probe attempt.
res="$(run_reload "1 1" 0 0 3)"; rc="${res%%|*}"; out="${res#*|}"
ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
  "both paths fail -> reload returns non-zero (does NOT claim success)"
ok_contains "$out" "WARNING: Could not reload Hammerspoon" \
  "both paths fail -> emits a loud WARNING (not a soft Note:)"
ok_contains "$out" "Reload Config" \
  "both paths fail -> warning includes the manual menubar-reload instruction"
ok_absent "$out" "Note: Could not reload" \
  "both paths fail -> no soft 'Note:' line (old buried failure mode is gone)"
# The give-up path must have actually retried the bounded probe loop more
# than once before warning (timeout=3, interval=0 -> 4 liveness probes).
ok "$(count_lines_matching 'hs -c true')" "4" \
  "give-up path -> retries the read-only probe up to the bounded timeout"

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
