#!/usr/bin/env bash

# Tests for install_filter.sh on tap-qualified (`<user>/<tap>/<name>`)
# Brewfile entries.
#
# The removal filter compares bare tokens — the name with any
# `<user>/<tap>/` prefix stripped — on both the Brewfile and the removal
# side, and a tap-qualified `brew` or `cask` line that survives filtering
# gets its tap trusted, as an emitted `tap` line does.
#
# These tests stand up a synthetic repo tree in a tmpdir, stub `brew` so it
# records every `trust --tap <name>` invocation to a log file (never
# touching real Homebrew), point the host tier at a temp dir via
# MACOS_SETUP_HOST_DIR, and run install_filter.sh with BREW pointed at the
# stub. They assert:
#   - a bare removal identifier filters a tap-qualified Brewfile line, and
#     a tap-qualified identifier filters a bare line, for cask and brew
#   - an emitted tap-qualified line trusts its tap, once
#   - a filtered-out tap-qualified line trusts nothing when no `tap` line
#     for its tap emits
#   - an emitted bare line trusts nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# A stub `brew` that records `trust --tap <name>` invocations to the file
# named by BREW_TRUST_LOG, one tap name per line. Always exits 0.
write_stub_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "trust" ]]; then
  shift
  [[ "${1:-}" == "--tap" ]] && shift
  printf '%s\n' "${1:-}" >> "$BREW_TRUST_LOG"
fi
exit 0
STUB
  chmod +x "$1"
}

# run_filter <brewfile-content> <uninstall-entry|""> — runs the filter on
# a fresh synthetic repo's default/Brewfile, with a default/config.toml
# uninstalling the given entry when one is given. Sets RUN_RC, RUN_EMITTED
# and TRUST_LOG.
run_filter() {
  local root host_dir
  root="$(mktemp -d)"
  host_dir="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  write_stub_brew "$root/scripts/stub_brew.sh"
  printf '%s\n' "$1" > "$root/default/Brewfile"
  if [[ -n "$2" ]]; then
    printf '[profile]\nuninstall = ["%s"]\n' "$2" > "$root/default/config.toml"
  fi
  TRUST_LOG="$root/trust.log"
  : > "$TRUST_LOG"

  local out_file
  out_file="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" \
    BREW="$root/scripts/stub_brew.sh" BREW_TRUST_LOG="$TRUST_LOG" \
    /bin/bash scripts/install_filter.sh "default/Brewfile" 2>/dev/null)"; RUN_RC=$?

  RUN_EMITTED=""
  [[ -f "$out_file" ]] && RUN_EMITTED="$(cat "$out_file")"
  rm -f "$out_file"
  rm -rf "$host_dir"
  CLEANUP+=("$root")
}

CLEANUP=()
trap 'rm -rf "${CLEANUP[@]}"' EXIT

trust_count() {
  # trust_count <tap-name> — how many times the stub trusted this tap.
  grep -cFx -- "$1" "$TRUST_LOG"
}

# --- Bare-token matching, both directions, cask and brew ---------------

run_filter "cask 'localstack/tap/lstk'" "cask:lstk"
ok "$RUN_RC" "0" "cask:lstk: filter exits 0"
ok_contains "$RUN_EMITTED" "# cask 'localstack/tap/lstk'" "cask:lstk filters cask 'localstack/tap/lstk'"

run_filter "cask 'lstk'" "cask:localstack/tap/lstk"
ok_contains "$RUN_EMITTED" "# cask 'lstk'" "cask:localstack/tap/lstk filters cask 'lstk'"

run_filter "brew 'localstack/tap/lstk'" "brew:lstk"
ok_contains "$RUN_EMITTED" "# brew 'localstack/tap/lstk'" "brew:lstk filters brew 'localstack/tap/lstk'"

run_filter "brew 'lstk'" "brew:localstack/tap/lstk"
ok_contains "$RUN_EMITTED" "# brew 'lstk'" "brew:localstack/tap/lstk filters brew 'lstk'"

# --- Trust for tap-qualified lines --------------------------------------

run_filter "cask 'localstack/tap/lstk'" ""
ok "$RUN_RC" "0" "emitted tap-qualified cask: filter exits 0"
ok "$(trust_count 'localstack/tap')" "1" "emitted tap-qualified cask trusts its tap once"

run_filter "cask 'localstack/tap/lstk'"$'\n'"brew 'localstack/tap/other'" ""
ok "$(trust_count 'localstack/tap')" "1" "two entries from one tap trust it once"

run_filter "cask 'localstack/tap/lstk'" "cask:lstk"
ok "$(trust_count 'localstack/tap')" "0" "filtered-out tap-qualified cask trusts nothing"

run_filter "cask 'lstk'" ""
ok "$(wc -l < "$TRUST_LOG" | tr -d ' ')" "0" "bare cask trusts nothing"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
