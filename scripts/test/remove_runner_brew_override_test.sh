#!/usr/bin/env bash

# Tests for the `BREW` override in scripts/remove_runner.sh.
#
# WHY THIS EXISTS. scripts/install_filter.sh — the script that INSTALLS —
# has always honored a `BREW` env var (`BREW="${BREW:-brew}"`), and
# docs/INSTALL.md documents that knob. scripts/remove_runner.sh — the
# script that DESTROYS — used to call `brew` by bare name at every one of
# its shell-out points. A caller (or a test) that passed `BREW=<stub>`
# believing it was protected was therefore protected on the install path
# and unprotected on the removal path, silently. That asymmetry cost a
# real Homebrew formula off a developer's machine when a test drove the
# removal loops with only `BREW=` set.
#
# The invariant these tests pin: EVERY shell-out to brew in
# remove_runner.sh goes through `$BREW`, including the `brew list` probes
# — a probe answered by the real brew is exactly what decides whether a
# real `brew uninstall` follows, so a stubbed uninstall with an unstubbed
# probe is not a safe test either.
#
# Three blocks:
#
#   Block 1 (static): no bare `brew` command invocation survives in
#   remove_runner.sh. The check is self-verifying — it is re-run against a
#   deliberately mutated copy of the script and must FIRE there, so a
#   pattern that silently stops matching cannot pass this block.
#
#   Block 2 (behavioral): with BREW pointed at a recording stub, a
#   tripwire `brew` first on PATH is NEVER invoked, while the stub sees
#   both the probe and the uninstall, for formula and cask, in both
#   --mode=uninstall and --mode=purge.
#
#   Block 3 (behavioral): with BREW unset, the runner still resolves bare
#   `brew` from PATH — the override is opt-in and the default is
#   unchanged. That block's PATH stub reports nothing installed, so it
#   drives no uninstall.
#
#   Block 4 (behavioral): `make remove-and-purge BREW=<stub>` reaches the
#   runner. That is the form every other test in this suite relies on, and
#   it works because GNU make exports command-line variables into each
#   recipe's environment — a contract worth pinning rather than assuming.
#
# No block touches real Homebrew: every brew the runner can reach is a
# stub written into a temp dir, and the sentinel package names are not
# real packages.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/remove_runner.sh"

pass=0
fail=0
ok() {
  # ok <condition-rc> <label>
  if [[ "$1" == "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}

# ---------------------------------------------------------------------
# Block 1: no bare `brew` command invocation in the runner.
# ---------------------------------------------------------------------

# Print every line of <file> that invokes `brew` in COMMAND position.
#
# Comments are stripped first (the header talks about brew constantly),
# then double-quoted spans (log messages quote brew command lines, and the
# `=~` patterns quote their delimiters). What survives is code, and a
# `brew` token there that sits at the start of a simple command — after
# start-of-line, whitespace, `;`, `&`, `|`, `(`, or a leading `!` — and is
# followed by a subcommand or a flag, is a bare invocation.
#
# `"$BREW" list ...` does not match (the token is `"$BREW"`), and neither
# does `BREW="${BREW:-brew}"` (that `brew` is followed by `}`) nor a
# `=~ ^brew[[:space:]]` regex literal (that `brew` is followed by `[`).
bare_brew_hits() {
  sed -E 's/#.*//; s/"[^"]*"//g' "$1" \
    | grep -nE '(^|[[:space:]]|[;&|(])(!([[:space:]]+))?brew[[:space:]]+[a-z-]'
}

static_test() {
  local hits
  hits="$(bare_brew_hits "$RUNNER")"
  if [[ -z "$hits" ]]; then
    echo "PASS: remove_runner.sh has no bare brew invocation"; ((pass++))
  else
    echo "FAIL: remove_runner.sh has bare brew invocation(s):"; echo "$hits"; ((fail++))
  fi

  ok "$(grep -q '^BREW="\${BREW:-brew}"$' "$RUNNER" && echo 0 || echo 1)" \
    "remove_runner.sh defines the BREW override the way install_filter.sh does"
  ok "$(grep -q '^BREW="\${BREW:-brew}"$' "$REPO_ROOT/scripts/install_filter.sh" && echo 0 || echo 1)" \
    "install_filter.sh still uses that same form (the convention is shared)"

  # Self-verification: the detector must fire on a mutated copy. Without
  # this, a detector that quietly stopped matching would report a clean
  # bill of health forever.
  local dir mutated
  dir="$(mktemp -d)"
  mutated="$dir/mutated_runner.sh"
  sed -E 's/"\$BREW" list --formula/brew list --formula/' "$RUNNER" > "$mutated"
  ok "$(grep -q 'brew list --formula' "$mutated" && echo 0 || echo 1)" \
    "mutation applied (the copy really does call bare brew)"
  ok "$([[ -n "$(bare_brew_hits "$mutated")" ]] && echo 0 || echo 1)" \
    "the detector fires on a reintroduced bare brew call"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------
# Blocks 2-3: behavioral.
# ---------------------------------------------------------------------

# A brew stub that appends its full argv to $BREW_CALL_LOG and reports
# every queried package as INSTALLED, so the runner proceeds to uninstall
# it (against the stub, which just records the call).
write_recording_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_CALL_LOG"
exit 0
STUB
  chmod +x "$1"
}

# The tripwire: installed first on PATH as bare `brew`. It records every
# invocation to the SAME $BREW_CALL_LOG, tagged `TRIPWIRE`, and reports
# nothing installed (so even a hit can only ever produce a `skip:` line,
# never a real removal — it is a stub, not Homebrew). A `TRIPWIRE` line in
# the log means the runner reached bare `brew`.
write_tripwire_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'TRIPWIRE %s\n' "$*" >> "$BREW_CALL_LOG"
exit 1
STUB
  chmod +x "$1"
}

override_test() {
  local dir slot stub log out rc
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  slot="$dir/00-Uninstall.sentinel"
  printf "# header\nbrew 'sentinel-formula'\ncask 'sentinel-cask'\n" > "$slot"

  stub="$dir/stub-brew"         # what BREW points at
  log="$dir/brew-calls.log"
  write_tripwire_brew "$dir/bin/brew"   # bare-name `brew` resolves here
  write_recording_brew "$stub"

  for mode in uninstall purge; do
    : > "$log"
    out="$(PATH="$dir/bin:$PATH" BREW="$stub" BREW_CALL_LOG="$log" \
      bash "$RUNNER" "$slot" "--mode=$mode" 2>&1)"; rc=$?
    ok "$rc" "BREW override, --mode=$mode: runner exits 0"

    local calls; calls="$(cat "$log")"

    # Nothing reached bare `brew`. This is the whole point of the test.
    ok_absent "$calls" "TRIPWIRE" \
      "BREW override, --mode=$mode: bare \`brew\` on PATH is never invoked"

    ok_contains "$calls" "list --formula sentinel-formula" \
      "BREW override, --mode=$mode: the formula PROBE goes through \$BREW"
    ok_contains "$calls" "uninstall --formula sentinel-formula" \
      "BREW override, --mode=$mode: the formula uninstall goes through \$BREW"
    ok_contains "$calls" "list --cask sentinel-cask" \
      "BREW override, --mode=$mode: the cask PROBE goes through \$BREW"
    if [[ "$mode" == "purge" ]]; then
      ok_contains "$calls" "uninstall --cask --zap sentinel-cask" \
        "BREW override, --mode=purge: the cask uninstall carries --zap"
    else
      ok_contains "$calls" "uninstall --cask sentinel-cask" \
        "BREW override, --mode=uninstall: the cask uninstall goes through \$BREW"
      ok_absent "$calls" "--zap" \
        "BREW override, --mode=uninstall: no --zap"
    fi

    # The runner's own log names the binary it actually ran.
    ok_contains "$out" "RUN: $stub uninstall --formula sentinel-formula" \
      "BREW override, --mode=$mode: the RUN: line names the overridden binary"
  done

  rm -rf "$dir"
}

default_test() {
  # With BREW unset the runner must still resolve bare `brew` from PATH:
  # the override is opt-in, and the default behavior is unchanged. Here a
  # TRIPWIRE line is the PASS condition, not the failure condition.
  local dir slot log rc out
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  slot="$dir/00-Uninstall.sentinel"
  printf "# header\nbrew 'sentinel-formula'\n" > "$slot"
  log="$dir/brew-calls.log"
  : > "$log"
  write_tripwire_brew "$dir/bin/brew"

  out="$(PATH="$dir/bin:$PATH" BREW_CALL_LOG="$log" \
    env -u BREW bash "$RUNNER" "$slot" --mode=uninstall 2>&1)"; rc=$?
  ok "$rc" "BREW unset: runner exits 0"
  ok_contains "$(cat "$log")" "TRIPWIRE list --formula sentinel-formula" \
    "BREW unset: the runner falls back to bare \`brew\` on PATH"
  ok_contains "$out" "skip: sentinel-formula not installed" \
    "BREW unset: an absent package is skipped, not uninstalled"

  rm -rf "$dir"
}

# ---------------------------------------------------------------------
# Block 4: the Makefile's BREW= reaches the runner.
# ---------------------------------------------------------------------
makefile_test() {
  local root host_dir stub log out rc calls
  root="$(mktemp -d)"
  host_dir="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" \
           "$root/RemoveAndPurge" "$root/bin"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  printf "# header\ncask 'sentinel-cask'\n" > "$root/RemoveAndPurge/00-RemoveAndPurge.sentinel"

  stub="$root/scripts/stub-brew"
  log="$root/brew-calls.log"
  : > "$log"
  write_recording_brew "$stub"
  write_tripwire_brew "$root/bin/brew"

  out="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" \
    BREW_CALL_LOG="$log" make remove-and-purge BREW="$stub" 2>&1)"; rc=$?
  ok "$rc" "make remove-and-purge BREW=<stub> exits 0"
  calls="$(cat "$log")"
  ok_absent "$calls" "TRIPWIRE" \
    "make remove-and-purge: bare \`brew\` on PATH is never invoked"
  ok_contains "$calls" "list --cask sentinel-cask" \
    "make's BREW= reaches the runner's probe"
  ok_contains "$calls" "uninstall --cask --zap sentinel-cask" \
    "make's BREW= reaches the runner's purge uninstall"

  rm -rf "$root" "$host_dir"
}

echo "=== Block 1: no bare brew invocation in remove_runner.sh ==="
static_test
echo "=== Block 2: BREW override covers probes and uninstalls ==="
override_test
echo "=== Block 3: BREW unset falls back to bare brew ==="
default_test
echo "=== Block 4: make's BREW= reaches the runner ==="
makefile_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All remove-runner BREW-override tests passed."
  exit 0
fi
echo "Some remove-runner BREW-override tests FAILED."
exit 1
