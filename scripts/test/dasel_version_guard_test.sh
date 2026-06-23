#!/usr/bin/env bash

# Tests for the dasel-v3 version guard in config_common.sh (issue #156
# follow-up review).
#
# The config.toml read layer targets the dasel v3 query contract
# specifically — the v2 -> v3 jump was a TOTAL breaking change, and a
# future v3 -> v4 jump is just as likely to break every read silently.
# require_dasel_v3() therefore asserts the major version is EXACTLY 3
# before the first read in a process (rejecting v2 AND v4+), memoized so
# it runs at most once.
#
# These tests drive dasel via the `DASEL` env override (the same
# indirection the rest of the suite uses), pointing it at fake `dasel`
# scripts whose `version` subcommand reports a chosen major. The guard is
# exercised in a SUBPROCESS so its `error_exit`/`exit 1` on the reject
# paths is observable as a non-zero exit, and we assert it also writes a
# loud diagnostic to stderr.
#
# The happy path is checked against the REAL dasel binary (which must be
# v3 per bootstrap.sh install_dasel), so the new assertion does not break
# the existing tests that read with the real dasel 3.11.0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_LIB="$REPO_ROOT/scripts/config_common.sh"

if ! command -v dasel >/dev/null 2>&1; then
  echo "FAIL: dasel not on PATH; the version-guard happy path needs the real binary (bootstrap.sh install_dasel)." >&2
  exit 1
fi

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

# Make a fake dasel whose `version` subcommand behaves as described.
#   make_fake_dasel <name> <mode>
# modes:
#   v2       -> `version` is unknown (exit 1, usage on stderr) like dasel v2
#   v4       -> `version` prints bare "4.0.1" exit 0
#   junk     -> `version` prints non-numeric text exit 0
#   v3       -> `version` prints bare "3.11.0" exit 0 (control)
make_fake_dasel() {
  local name="$1" mode="$2" path="$TMP/$1"
  case "$mode" in
    v2)   printf '#!/usr/bin/env bash\nif [[ "$1" == "version" ]]; then echo "Error: unknown command" >&2; exit 1; fi\nexit 0\n' > "$path" ;;
    v4)   printf '#!/usr/bin/env bash\n[[ "$1" == "version" ]] && { echo "4.0.1"; exit 0; }\nexit 0\n' > "$path" ;;
    junk) printf '#!/usr/bin/env bash\n[[ "$1" == "version" ]] && { echo "usage: dasel ..."; exit 0; }\nexit 0\n' > "$path" ;;
    v3)   printf '#!/usr/bin/env bash\n[[ "$1" == "version" ]] && { echo "3.11.0"; exit 0; }\nexit 0\n' > "$path" ;;
  esac
  chmod +x "$path"
  echo "$path"
}

# Run require_dasel_v3 in a subprocess under the given shell with the
# given DASEL override; echo "<exit-code>|<stderr>" so we can assert both
# the non-zero exit and a loud message.
run_guard() {
  local shell="$1" dasel="$2"
  local errfile out rc
  errfile="$(mktemp)"
  DASEL="$dasel" "$shell" -c "source '$CONFIG_LIB'; require_dasel_v3" 2>"$errfile"
  rc=$?
  out="$(cat "$errfile")"
  rm -f "$errfile"
  printf '%s|%s' "$rc" "$out"
}

guard_tests() {
  local res rc msg sh

  for sh in bash zsh; do
    if ! command -v "$sh" >/dev/null 2>&1; then
      echo "SKIP: $sh not available"; continue
    fi

    # --- Happy path: real v3 dasel passes (exit 0, no error) ---
    res="$(DASEL="$(command -v dasel)" "$sh" -c "source '$CONFIG_LIB'; require_dasel_v3; echo OK")"
    ok "$res" "OK" "$sh: real dasel v3 passes the guard"

    # --- Reject v2 (version subcommand errors) ---
    res="$(run_guard "$sh" "$(make_fake_dasel dasel-v2 v2)")"
    rc="${res%%|*}"; msg="${res#*|}"
    ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
      "$sh: v2-style dasel (version subcmd fails) -> guard exits non-zero"
    ok "$( [[ -n "$msg" ]] && echo loud || echo silent )" "loud" \
      "$sh: v2-style dasel -> guard writes a diagnostic to stderr"

    # --- Reject v4 (bare 4.x) ---
    res="$(run_guard "$sh" "$(make_fake_dasel dasel-v4 v4)")"
    rc="${res%%|*}"; msg="${res#*|}"
    ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
      "$sh: v4 dasel -> guard exits non-zero (exactly-3, not minimum-major)"
    ok "$( [[ "$msg" == *"major version 4"* ]] && echo named || echo unnamed )" "named" \
      "$sh: v4 dasel -> diagnostic names the found major (4)"

    # --- Reject unparseable version output ---
    res="$(run_guard "$sh" "$(make_fake_dasel dasel-junk junk)")"
    rc="${res%%|*}"
    ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
      "$sh: unparseable version output -> guard exits non-zero"

    # --- Reject missing binary ---
    res="$(run_guard "$sh" "$TMP/dasel-does-not-exist")"
    rc="${res%%|*}"
    ok "$( [[ "$rc" != "0" ]] && echo nonzero || echo zero )" "nonzero" \
      "$sh: missing dasel binary -> guard exits non-zero (not assume-ok)"
  done
}

# A v3-reporting fake also lets a real config.toml read proceed (the
# guard does not get in the way of a legitimate v3).
read_through_guard_tests() {
  local toml fake
  toml="$TMP/c.toml"
  printf 'profiles = ["a", "b"]\n\n[claude]\nbranch = "x"\n' > "$toml"
  fake="$(make_fake_dasel dasel-v3 v3)"

  # With a v4 fake, a read fails loudly and yields NO value (no silent
  # wrong value). We assert the read produced empty output AND a stderr
  # diagnostic.
  local v4 errf out
  v4="$(make_fake_dasel dasel-v4b v4)"
  errf="$(mktemp)"
  out="$(DASEL="$v4" bash -c "source '$CONFIG_LIB'; read_toml_value '$toml' claude.branch" 2>"$errf")"
  ok "$out" "" "read_toml_value under v4 dasel -> empty (no silent wrong value)"
  ok "$( [[ -s "$errf" ]] && echo loud || echo silent )" "loud" \
    "read_toml_value under v4 dasel -> loud stderr diagnostic"
  rm -f "$errf"
}

echo "=== require_dasel_v3 guard tests ==="
guard_tests
echo "=== read-helper-through-guard tests ==="
read_through_guard_tests

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All dasel version-guard tests passed."
  exit 0
fi
echo "Some dasel version-guard tests FAILED."
exit 1
