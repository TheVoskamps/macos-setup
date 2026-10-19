#!/usr/bin/env bash

# Tests for check_mas_login in bootstrap.sh.
#
# No mas subcommand reports App Store sign-in state, so the step only
# reminds the user to sign in: it calls no mas subcommand, never claims the
# user is or is not signed in, opens the App Store app only when it is not
# already running, and returns 0 whatever happens.
#
# bootstrap.sh runs main when sourced, so the function body is extracted
# and evaluated alone. pgrep, open and mas are stubs on PATH that record
# their argv; the pgrep stub's exit status is set per case.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/bootstrap.sh"

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

func_src="$(sed -n '/^check_mas_login() {/,/^}/p' "$BOOTSTRAP")"
if [[ -z "$func_src" ]]; then
  echo "FAIL: check_mas_login not found in $BOOTSTRAP" >&2
  exit 1
fi

mkdir -p "$TMP/bin"
# shellcheck disable=SC2016  # the stub bodies expand at stub run time
for cmd in open mas; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nexit "${%s_RC:-0}"\n' \
    "$cmd" "$(tr '[:lower:]' '[:upper:]' <<<"$cmd")" > "$TMP/bin/$cmd"
done
# shellcheck disable=SC2016  # the stub body expands at stub run time
printf '#!/usr/bin/env bash\necho "pgrep $*" >> "$CALLS"\nexit "${PGREP_RC:-1}"\n' > "$TMP/bin/pgrep"
chmod +x "$TMP/bin/"*

# run_case <pgrep-rc> <open-rc>: runs check_mas_login under set -e with the
# stubs first on PATH; prints "<rc>|<output>|<calls>".
run_case() {
  local calls="$TMP/calls.$1.$2"
  : > "$calls"
  local out rc
  out="$(
    PATH="$TMP/bin:$PATH" CALLS="$calls" PGREP_RC="$1" OPEN_RC="$2" bash -c '
      set -euo pipefail
      log() { printf "[BOOTSTRAP] %s\n" "$*"; }
      warn() { printf "[WARN] %s\n" "$*"; }
      eval "$1"
      check_mas_login
    ' _ "$func_src" 2>&1
  )"
  rc=$?
  printf '%s|%s|%s' "$rc" "$out" "$(tr '\n' ';' < "$calls")"
}

echo "=== App Store not running: opened ==="
res="$(run_case 1 0)"
ok "${res%%|*}" "0" "not running: returns 0"
calls="${res##*|}"
ok "$([[ "$calls" == *'open -a App Store'* ]] && echo yes)" "yes" "not running: opens the App Store app"
ok "$([[ "$calls" == *'pgrep -x App Store'* ]] && echo yes)" "yes" "not running: probes with pgrep -x \"App Store\""

echo "=== App Store already running: not opened ==="
res="$(run_case 0 0)"
ok "${res%%|*}" "0" "running: returns 0"
calls="${res##*|}"
ok "$([[ "$calls" == *'open '* ]] && echo yes || echo no)" "no" "running: does not open the App Store app"

echo "=== open fails: still returns 0 ==="
res="$(run_case 1 1)"
ok "${res%%|*}" "0" "open failure: returns 0"

echo "=== no sign-in claim, no mas call ==="
for pg in 0 1; do
  res="$(run_case "$pg" 0)"
  out="${res#*|}"; out="${out%|*}"
  calls="${res##*|}"
  ok "$([[ "$out" == *'Not signed into'* || "$out" == *'signed in:'* ]] && echo yes || echo no)" "no" \
    "pgrep rc $pg: claims no sign-in state"
  ok "$([[ "$out" == *'Sign into the Mac App Store'*'make install'* ]] && echo yes || echo no)" "yes" \
    "pgrep rc $pg: logs the sign-in instruction"
  ok "$([[ "$calls" == *'mas '* ]] && echo yes || echo no)" "no" "pgrep rc $pg: calls no mas subcommand"
done

echo
echo "Passed: $pass  Failed: $fail"
[[ "$fail" -eq 0 ]]
