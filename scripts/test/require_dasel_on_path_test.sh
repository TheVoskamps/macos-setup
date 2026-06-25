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

# --- list_profiles.sh quiet short-circuit (issue #4 regression) ---
# The Makefile expands `PROFILES := $(shell bash scripts/list_profiles.sh
# 2>/dev/null)` at PARSE time, before the require-dasel prerequisite runs.
# With dasel off PATH, list_profiles.sh must short-circuit QUIETLY (exit 0,
# empty stdout, and crucially NO `kill -s TERM "$$"` from require_dasel_v3
# that would make make's parent shell print a `Terminated: 15` line ahead
# of the gate's clean error). This unit-level case asserts the source-level
# fix; the make-level cases below assert the end-to-end symptom is gone.
LISTER="$REPO_ROOT/scripts/list_profiles.sh"
lp_errfile="$(mktemp)"
lp_out="$(DASEL="$TMP/does-not-exist-dasel" bash "$LISTER" 2>"$lp_errfile")"
lp_rc=$?
lp_err="$(cat "$lp_errfile")"; rm -f "$lp_errfile"
ok "$lp_rc" "0" "list_profiles.sh (no dasel) -> exits 0"
ok "$( [[ -z "$lp_out" ]] && echo empty || echo nonempty )" "empty" \
  "list_profiles.sh (no dasel) -> empty stdout (no profiles)"
ok "$( [[ "$lp_err" != *"Terminated"* ]] && echo clean || echo noisy )" "clean" \
  "list_profiles.sh (no dasel) -> no Terminated/SIGTERM noise on stderr"

# When dasel IS reachable, list_profiles.sh must still resolve normally
# (exit 0) and must not regress on the short-circuit. Point it at a
# scratch host tier with a known two-profile list and assert that exact
# list comes back — proving the short-circuit only fires on unreachable
# dasel, not whenever DASEL is set.
if command -v dasel >/dev/null 2>&1; then
  lp_host="$TMP/lp_host"; mkdir -p "$lp_host"
  printf 'profiles = ["dev-core", "aws"]\n' > "$lp_host/config.toml"
  lp_norm="$(MACOS_SETUP_HOST_DIR="$lp_host" bash "$LISTER" 2>/dev/null)"
  ok "$lp_norm" "$(printf 'dev-core\naws')" \
    "list_profiles.sh (dasel present) -> resolves the configured profile list"
else
  echo "SKIP: real dasel not on PATH; list_profiles.sh normal-resolution case not exercised"
fi

# --- End-to-end: the config-dependent make targets must, on a no-dasel
#     PATH, emit the gate's clean error as the ONLY config output — with
#     NO parse-time `Terminated: 15` line from the PROFILES `$(shell ...)`.
#     This is the exact symptom issue #4 exists to eliminate. We drive
#     real `make` with DASEL pointed at a nonexistent binary (mimicking
#     dasel-installed-but-off-PATH: `command -v` misses it) and a scratch
#     host tier so no real machine state is touched. ---
if command -v make >/dev/null 2>&1; then
  e2e_host="$TMP/e2e_host"
  for tgt in install update verify outdated; do
    # Fresh empty host tier each iteration so we also prove the gate
    # aborts BEFORE host-tier seeding (the dir must not be created).
    rm -rf "$e2e_host"
    out="$(cd "$REPO_ROOT" && DASEL="$TMP/does-not-exist-dasel" \
      MACOS_SETUP_HOST_DIR="$e2e_host" make "$tgt" 2>&1 || true)"
    ok "$( [[ "$out" == *"dasel not in PATH"* ]] && echo gated || echo ungated )" \
      "gated" "make $tgt (no dasel) -> emits the gate's clean error"
    ok "$( [[ "$out" != *"Terminated"* ]] && echo clean || echo noisy )" \
      "clean" "make $tgt (no dasel) -> no parse-time 'Terminated: 15' noise"
    ok "$( [[ ! -d "$e2e_host" ]] && echo unseeded || echo seeded )" \
      "unseeded" "make $tgt (no dasel) -> aborts before host-tier seeding"
  done
else
  echo "SKIP: make not on PATH; end-to-end no-dasel target cases not exercised"
fi

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All require_dasel_on_path gate tests passed."
  exit 0
fi
echo "Some require_dasel_on_path gate tests FAILED."
exit 1
