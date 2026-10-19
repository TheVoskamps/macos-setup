#!/usr/bin/env bash

# Tests for remove_runner.sh on tap-qualified (`<user>/<tap>/<name>`)
# removal entries.
#
# The runner probes and uninstalls by the bare token — the name with any
# `<user>/<tap>/` prefix stripped — as install_filter.sh matches by it, so a
# `cask:<user>/<tap>/<name>` or `brew:<user>/<tap>/<name>` entry removes the
# installed `<name>` rather than skipping it as not installed.
#
# These tests write a tier's config.toml into a tmpdir and run the runner
# with BREW pointed at a recording stub that, like real Homebrew's
# `brew list`, knows each package only by its bare token. A tripwire `brew`
# first on PATH records any bare-name call, so no call can reach real
# Homebrew.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/remove_runner.sh"

pass=0
fail=0
ok_rc() {
  # ok_rc <actual_rc> <want_rc> <label>
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want $2)"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/tier"
CALL_LOG="$DIR/calls.log"
export CALL_LOG

# The recording stub BREW points at. It appends its argv to $CALL_LOG,
# fails a `list` of any name containing `/`, and reports every other
# package installed.
cat > "$DIR/stub-brew" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
if [[ "${1:-}" == "list" && "${*: -1}" == */* ]]; then
  exit 1
fi
exit 0
STUB
chmod +x "$DIR/stub-brew"

# The tripwire bare `brew` on PATH: records a TRIPWIRE line and fails.
cat > "$DIR/bin/brew" <<'STUB'
#!/usr/bin/env bash
printf 'TRIPWIRE %s\n' "$*" >> "$CALL_LOG"
exit 1
STUB
chmod +x "$DIR/bin/brew"

printf '[profile]\nuninstall = ["cask:localstack/tap/lstk", "brew:atlassian/acli/acli"]\npurge = ["cask:localstack/tap/lstk", "brew:atlassian/acli/acli"]\n' \
  > "$DIR/tier/config.toml"

for mode in uninstall purge; do
  : > "$CALL_LOG"
  OUT="$(PATH="$DIR/bin:$PATH" BREW="$DIR/stub-brew" \
    /bin/bash "$RUNNER" "$DIR/tier" "--mode=$mode" 2>&1)"; RC=$?
  CALLS="$(cat "$CALL_LOG")"

  ok_rc "$RC" 0 "--mode=$mode: runner exits 0"
  ok_absent "$CALLS" "TRIPWIRE" "--mode=$mode: bare \`brew\` on PATH is never invoked"
  ok_contains "$CALLS" "list --cask lstk" "--mode=$mode: tap-qualified cask is probed by its bare token"
  ok_contains "$CALLS" "list --formula acli" "--mode=$mode: tap-qualified formula is probed by its bare token"
  ok_contains "$CALLS" "uninstall --formula acli" "--mode=$mode: tap-qualified formula is uninstalled by its bare token"
  if [[ "$mode" == "purge" ]]; then
    ok_contains "$CALLS" "uninstall --cask --zap lstk" "--mode=purge: tap-qualified cask is purged by its bare token"
  else
    ok_contains "$CALLS" "uninstall --cask lstk" "--mode=uninstall: tap-qualified cask is uninstalled by its bare token"
  fi
  ok_absent "$OUT" "not installed" "--mode=$mode: no tap-qualified entry is skipped as not installed"
done

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
