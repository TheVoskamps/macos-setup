#!/usr/bin/env bash

# Tests for the up-front dasel-on-PATH reachability gate (issue #4).
#
# scripts/require_dasel_on_path.sh is a single hard gate the
# config-dependent `make` targets (install, update, verify, outdated)
# run BEFORE any host-tier seeding, list_profiles.sh, or config read. It
# checks that `dasel` is reachable as a BARE command and aborts loudly
# with a PATH-specific remediation when it is not — turning the old
# cryptic, late `dasel version exited 127` (from require_dasel_v3 partway
# into 00-Install.core) into an actionable up-front abort.
#
# This is a REACHABILITY check only; the exactly-v3 version assertion is
# the separate job of require_dasel_v3 (covered by
# dasel_version_guard_test.sh). These tests drive the gate via the same
# `DASEL` env override the rest of the suite uses, pointing it at a real
# binary (pass) or a nonexistent path (fail).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/require_dasel_on_path.sh"

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++))
  fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Run the gate with the given DASEL override; echo "<exit-code>|<stderr>"
# so we can assert both the exit code and the diagnostic.
run_gate() {
  local dasel="$1" errfile rc out
  errfile="$(mktemp)"
  DASEL="$dasel" bash "$GATE" >/dev/null 2>"$errfile"
  rc=$?
  out="$(cat "$errfile")"
  rm -f "$errfile"
  printf '%s|%s' "$rc" "$out"
}

# A fake `dasel` that merely exists and is executable — the gate only
# checks reachability (command -v), not behavior.
FAKE_DASEL="$TMP/dasel"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_DASEL"
chmod +x "$FAKE_DASEL"

echo "=== require_dasel_on_path gate tests ==="

# --- Pass: dasel reachable (an executable on an absolute path) ---
res="$(run_gate "$FAKE_DASEL")"
rc="${res%%|*}"; msg="${res#*|}"
ok "$rc" "0" "reachable dasel -> gate exits 0"
ok "$( [[ -z "$msg" ]] && echo quiet || echo noisy )" "quiet" \
  "reachable dasel -> gate is silent on success"

# --- Pass: bare-name dasel found on the ambient PATH (real binary) ---
if command -v dasel >/dev/null 2>&1; then
  res="$(run_gate "dasel")"
  rc="${res%%|*}"
  ok "$rc" "0" "bare-name dasel on PATH -> gate exits 0"
else
  echo "SKIP: real dasel not on PATH; bare-name pass case not exercised"
fi

# --- Fail: dasel NOT reachable (nonexistent absolute path) ---
res="$(run_gate "$TMP/does-not-exist-dasel")"
rc="${res%%|*}"; msg="${res#*|}"
ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
  "unreachable dasel -> gate exits non-zero"
ok "$( [[ -n "$msg" ]] && echo loud || echo silent )" "loud" \
  "unreachable dasel -> gate writes a diagnostic to stderr"
ok "$( [[ "$msg" == *"dasel not in PATH"* ]] && echo named || echo unnamed )" "named" \
  "unreachable dasel -> diagnostic says 'dasel not in PATH'"
ok "$( [[ "$msg" == *"make install"* ]] && echo remediated || echo bare )" "remediated" \
  "unreachable dasel -> diagnostic includes the new-shell remediation"

# --- The Makefile wires the gate as a prerequisite on the
#     config-dependent batch targets. Assert each entry point declares
#     it, so the up-front gate cannot be silently dropped. ---
for tgt in install update verify outdated; do
  if grep -Eq "^$tgt:[^#]*\brequire-dasel\b" "$REPO_ROOT/Makefile"; then
    echo "PASS: Makefile target '$tgt' depends on require-dasel"; ((pass++))
  else
    echo "FAIL: Makefile target '$tgt' does not depend on require-dasel"; ((fail++))
  fi
done

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All require_dasel_on_path gate tests passed."
  exit 0
fi
echo "Some require_dasel_on_path gate tests FAILED."
exit 1
