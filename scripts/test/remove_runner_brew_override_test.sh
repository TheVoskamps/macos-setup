#!/usr/bin/env bash

# Tests for the binary overrides (`BREW`, `MAS`, `SUDO`) in
# scripts/remove_runner.sh.
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
# `mas` carried the identical asymmetry one binary over, on a path that is
# `sudo mas uninstall`, and now carries the identical override: `MAS` for
# the binary and `SUDO` for the privilege escalation that drives it.
# Overriding one without the other is not enough — stub only `MAS` and the
# real sudo still runs, stub only `SUDO` and the real mas is what it runs
# — so these tests pin the composition, not just the pair of knobs.
#
# The invariant these tests pin: EVERY shell-out to brew, mas, or sudo in
# remove_runner.sh goes through `$BREW` / `$MAS` / `$SUDO`, including the
# `brew list` and `mas list` probes — a probe answered by the real binary
# is exactly what decides whether a real uninstall follows, so a stubbed
# uninstall with an unstubbed probe is not a safe test either.
#
# The blocks:
#
#   Block 1 (static): no bare `brew`, `mas`, or `sudo` command invocation
#   survives in remove_runner.sh. Each check is self-verifying — it is
#   re-run against a deliberately mutated copy of the script and must FIRE
#   there, so a pattern that silently stops matching cannot pass this
#   block.
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
#   Block 4 (behavioral): `make remove-and-purge BREW=<stub> MAS=<stub>
#   SUDO=<stub>` reaches the runner. That is the form every other test in
#   this suite relies on, and it works because GNU make exports
#   command-line variables into each recipe's environment — a contract
#   worth pinning rather than assuming.
#
#   Block 5 (behavioral): the mas path. With MAS and SUDO pointed at
#   recording stubs, tripwire `mas` and `sudo` first on PATH are NEVER
#   invoked; the mas stub sees the `list` probe, and the sudo stub sees —
#   and execs — the overridden mas, so the composition is observed rather
#   than assumed.
#
#   Block 6 (behavioral): with MAS and SUDO unset, the runner still
#   resolves bare `mas` from PATH. That block's PATH stub reports nothing
#   installed, so it drives no uninstall and never reaches sudo.
#
# No block touches real Homebrew, the real Mac App Store, or real sudo:
# every brew, mas, and sudo the runner can reach is a stub written into a
# temp dir, and the sentinel package names and app id are not real.

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
# Block 1: no bare `brew` / `mas` / `sudo` command invocation in the
# runner.
# ---------------------------------------------------------------------

# Print every line of <file> that invokes <cmd> in COMMAND position.
#
# Comments are stripped first (the header talks about brew and mas
# constantly), then double-quoted spans (log messages quote the command
# lines they are about to run, and the `=~` patterns quote their
# delimiters). What survives is code, and a <cmd> token there that sits at
# the start of a simple command — after start-of-line, whitespace, `;`,
# `&`, `|`, `(`, or a leading `!` — and is followed by a subcommand or a
# flag, is a bare invocation.
#
# `"$BREW" list ...` does not match (the token is `"$BREW"`), and neither
# does `BREW="${BREW:-brew}"` (the whole quoted span is stripped) nor a
# `=~ ^brew[[:space:]]` regex literal (that `brew` is followed by `[`).
# The same three exemptions hold verbatim for `mas`.
#
# `sudo` is checked by the same rule, and catches both halves of a
# half-stubbed mas removal: a reintroduced `sudo "$MAS" uninstall` leaves
# a bare `sudo` in command position, while a reintroduced
# `"$SUDO" mas uninstall` leaves a bare `mas`.
bare_cmd_hits() {
  # bare_cmd_hits <file> <cmd>
  sed -E 's/#.*//; s/"[^"]*"//g' "$1" \
    | grep -nE "(^|[[:space:]]|[;&|(])(!([[:space:]]+))?$2[[:space:]]+[a-z-]"
}

# Assert <file> has no bare <cmd> invocation, then self-verify the
# detector by re-running it on a copy mutated to reintroduce one.
# <mutate-sed> must turn an overridden call back into a bare one, and
# <mutation-witness> is the literal text that proves the mutation landed.
# Without the self-verification a detector that quietly stopped matching
# would report a clean bill of health forever.
assert_no_bare_cmd() {
  # assert_no_bare_cmd <cmd> <mutate-sed> <mutation-witness>
  local cmd="$1" mutate="$2" witness="$3" hits dir mutated
  hits="$(bare_cmd_hits "$RUNNER" "$cmd")"
  if [[ -z "$hits" ]]; then
    echo "PASS: remove_runner.sh has no bare $cmd invocation"; ((pass++))
  else
    echo "FAIL: remove_runner.sh has bare $cmd invocation(s):"; echo "$hits"; ((fail++))
  fi

  dir="$(mktemp -d)"
  mutated="$dir/mutated_runner.sh"
  sed -E "$mutate" "$RUNNER" > "$mutated"
  ok "$(grep -qF -- "$witness" "$mutated" && echo 0 || echo 1)" \
    "mutation applied (the copy really does call bare $cmd)"
  ok "$([[ -n "$(bare_cmd_hits "$mutated" "$cmd")" ]] && echo 0 || echo 1)" \
    "the detector fires on a reintroduced bare $cmd call"
  rm -rf "$dir"
}

static_test() {
  assert_no_bare_cmd brew \
    's/"\$BREW" list --formula/brew list --formula/' 'brew list --formula'
  assert_no_bare_cmd mas \
    's/"\$MAS" list/mas list/' 'mas list'
  assert_no_bare_cmd sudo \
    's/"\$SUDO" "\$MAS" uninstall/sudo "$MAS" uninstall/' 'sudo "$MAS" uninstall'

  ok "$(grep -q '^BREW="\${BREW:-brew}"$' "$RUNNER" && echo 0 || echo 1)" \
    "remove_runner.sh defines the BREW override the way install_filter.sh does"
  ok "$(grep -q '^MAS="\${MAS:-mas}"$' "$RUNNER" && echo 0 || echo 1)" \
    "remove_runner.sh defines the MAS override in that same form"
  ok "$(grep -q '^SUDO="\${SUDO:-sudo}"$' "$RUNNER" && echo 0 || echo 1)" \
    "remove_runner.sh defines the SUDO override in that same form"
  ok "$(grep -q '^BREW="\${BREW:-brew}"$' "$REPO_ROOT/scripts/install_filter.sh" && echo 0 || echo 1)" \
    "install_filter.sh still uses that same form (the convention is shared)"
}

# ---------------------------------------------------------------------
# Blocks 2-3 (brew) and 5-6 (mas/sudo): behavioral.
# ---------------------------------------------------------------------

# A brew stub that appends its full argv to $CALL_LOG and reports
# every queried package as INSTALLED, so the runner proceeds to uninstall
# it (against the stub, which just records the call).
write_recording_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
exit 0
STUB
  chmod +x "$1"
}

# The tripwire: installed first on PATH as bare `brew`. It records every
# invocation to the SAME $CALL_LOG, tagged `TRIPWIRE`, and reports
# nothing installed (so even a hit can only ever produce a `skip:` line,
# never a real removal — it is a stub, not Homebrew). A `TRIPWIRE` line in
# the log means the runner reached bare `brew`.
write_tripwire_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'TRIPWIRE %s\n' "$*" >> "$CALL_LOG"
exit 1
STUB
  chmod +x "$1"
}

# The mas sentinel: a fake App Store id no real app carries, plus stubs
# that record to the same $CALL_LOG the brew stubs use.
MAS_SENTINEL_ID="1234567890"

# A mas stub that records its argv and answers `list` with the sentinel id,
# so the runner believes the app IS installed and proceeds to uninstall it
# (against this stub, which just records the call).
write_recording_mas() {
  cat > "$1" <<STUB
#!/usr/bin/env bash
printf 'MAS %s\n' "\$*" >> "\$CALL_LOG"
if [[ "\${1:-}" == "list" ]]; then
  printf '$MAS_SENTINEL_ID  Sentinel App  (1.0)\n'
fi
exit 0
STUB
  chmod +x "$1"
}

# A sudo stub that records its argv and then EXECS it. Recording alone
# would prove sudo was stubbed; exec'ing is what lets the log show which
# binary sudo actually ran, so the MAS-under-SUDO composition is observed
# rather than assumed.
write_recording_sudo() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'SUDO %s\n' "$*" >> "$CALL_LOG"
exec "$@"
STUB
  chmod +x "$1"
}

# Tripwires for bare `mas` / bare `sudo`, installed first on PATH. Each
# records a TRIPWIRE line and fails, so even a hit can only produce a
# `skip:` line — never a real removal, and never a real sudo prompt.
write_tripwire_mas() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'TRIPWIRE-MAS %s\n' "$*" >> "$CALL_LOG"
exit 1
STUB
  chmod +x "$1"
}

write_tripwire_sudo() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'TRIPWIRE-SUDO %s\n' "$*" >> "$CALL_LOG"
exit 1
STUB
  chmod +x "$1"
}

override_test() {
  local dir tier stub log out rc
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  # The removal list is a TIER's config.toml [profile] arrays (issue #33).
  # Both modes list the same two packages so each mode has work to do.
  tier="$dir/tier"
  mkdir -p "$tier"
  printf '[profile]\nuninstall = ["brew:sentinel-formula", "cask:sentinel-cask"]\npurge = ["brew:sentinel-formula", "cask:sentinel-cask"]\n' \
    > "$tier/config.toml"

  stub="$dir/stub-brew"         # what BREW points at
  log="$dir/brew-calls.log"
  write_tripwire_brew "$dir/bin/brew"   # bare-name `brew` resolves here
  write_recording_brew "$stub"

  for mode in uninstall purge; do
    : > "$log"
    out="$(PATH="$dir/bin:$PATH" BREW="$stub" CALL_LOG="$log" \
      bash "$RUNNER" "$tier" "--mode=$mode" 2>&1)"; rc=$?
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
  local dir tier log rc out
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  tier="$dir/tier"
  mkdir -p "$tier"
  printf '[profile]\nuninstall = ["brew:sentinel-formula"]\n' > "$tier/config.toml"
  log="$dir/brew-calls.log"
  : > "$log"
  write_tripwire_brew "$dir/bin/brew"

  out="$(PATH="$dir/bin:$PATH" CALL_LOG="$log" \
    env -u BREW bash "$RUNNER" "$tier" --mode=uninstall 2>&1)"; rc=$?
  ok "$rc" "BREW unset: runner exits 0"
  ok_contains "$(cat "$log")" "TRIPWIRE list --formula sentinel-formula" \
    "BREW unset: the runner falls back to bare \`brew\` on PATH"
  ok_contains "$out" "skip: sentinel-formula not installed" \
    "BREW unset: an absent package is skipped, not uninstalled"

  rm -rf "$dir"
}

# ---------------------------------------------------------------------
# Blocks 5-6: the mas path (MAS + SUDO).
# ---------------------------------------------------------------------

mas_override_test() {
  local dir tier mas_stub sudo_stub log out rc calls
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  tier="$dir/tier"
  mkdir -p "$tier"
  # "mas:<id>:<Name>" carries the label the log lines use; the id is what
  # `mas uninstall` is actually handed.
  printf '[profile]\nuninstall = ["mas:%s:Sentinel App"]\npurge = ["mas:%s:Sentinel App"]\n' \
    "$MAS_SENTINEL_ID" "$MAS_SENTINEL_ID" > "$tier/config.toml"

  mas_stub="$dir/stub-mas"       # what MAS points at
  sudo_stub="$dir/stub-sudo"     # what SUDO points at
  log="$dir/calls.log"
  write_tripwire_mas "$dir/bin/mas"     # bare-name `mas` resolves here
  write_tripwire_sudo "$dir/bin/sudo"   # bare-name `sudo` resolves here
  write_recording_mas "$mas_stub"
  write_recording_sudo "$sudo_stub"

  for mode in uninstall purge; do
    : > "$log"
    out="$(PATH="$dir/bin:$PATH" MAS="$mas_stub" SUDO="$sudo_stub" \
      CALL_LOG="$log" bash "$RUNNER" "$tier" "--mode=$mode" 2>&1)"; rc=$?
    ok "$rc" "MAS/SUDO override, --mode=$mode: runner exits 0"

    calls="$(cat "$log")"

    # Neither bare binary was reached. This is the whole point.
    ok_absent "$calls" "TRIPWIRE" \
      "MAS/SUDO override, --mode=$mode: bare \`mas\`/\`sudo\` on PATH are never invoked"

    ok_contains "$calls" "MAS list" \
      "MAS/SUDO override, --mode=$mode: the mas PROBE goes through \$MAS"
    # The sudo stub execs what it was handed, so this line proves sudo ran
    # the OVERRIDDEN mas — the composition, not just the two knobs.
    ok_contains "$calls" "SUDO $mas_stub uninstall $MAS_SENTINEL_ID" \
      "MAS/SUDO override, --mode=$mode: \$SUDO runs \$MAS, not bare mas"
    ok_contains "$calls" "MAS uninstall $MAS_SENTINEL_ID" \
      "MAS/SUDO override, --mode=$mode: the mas uninstall goes through \$MAS"

    # The runner's own log names the binaries it actually ran.
    ok_contains "$out" "RUN: $sudo_stub $mas_stub uninstall $MAS_SENTINEL_ID" \
      "MAS/SUDO override, --mode=$mode: the RUN: line names the overridden binaries"
  done

  # --dry-run must reach neither binary for the uninstall, and must name
  # the overridden ones in the line it prints instead.
  : > "$log"
  out="$(PATH="$dir/bin:$PATH" MAS="$mas_stub" SUDO="$sudo_stub" \
    CALL_LOG="$log" bash "$RUNNER" "$tier" --mode=purge --dry-run 2>&1)"; rc=$?
  ok "$rc" "MAS/SUDO override, --dry-run: runner exits 0"
  ok_absent "$(cat "$log")" "uninstall" \
    "MAS/SUDO override, --dry-run: no uninstall is executed"
  ok_contains "$out" "DRY-RUN: $sudo_stub $mas_stub uninstall $MAS_SENTINEL_ID" \
    "MAS/SUDO override, --dry-run: the DRY-RUN line names the overridden binaries"

  # An override pointing at nothing must report the path it actually
  # probed, and must NOT quietly fall through to the `mas` on PATH.
  : > "$log"
  out="$(PATH="$dir/bin:$PATH" MAS="$dir/no-such-mas" SUDO="$sudo_stub" \
    CALL_LOG="$log" bash "$RUNNER" "$tier" --mode=uninstall 2>&1)"; rc=$?
  ok "$rc" "MAS pointed at a missing binary: runner exits 0"
  ok_contains "$out" "mas CLI not found: $dir/no-such-mas" \
    "MAS pointed at a missing binary: the skip line names the probed path"
  ok_absent "$(cat "$log")" "TRIPWIRE" \
    "MAS pointed at a missing binary: bare \`mas\` on PATH is not used instead"

  rm -rf "$dir"
}

mas_default_test() {
  # With MAS and SUDO unset the runner must still resolve bare `mas` from
  # PATH: the override is opt-in, and the default behavior is unchanged.
  # Here a TRIPWIRE-MAS line is the PASS condition. The PATH `mas` stub
  # reports nothing installed, so sudo is never reached at all.
  local dir tier log rc out calls
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  tier="$dir/tier"
  mkdir -p "$tier"
  printf '[profile]\nuninstall = ["mas:%s:Sentinel App"]\n' \
    "$MAS_SENTINEL_ID" > "$tier/config.toml"
  log="$dir/calls.log"
  : > "$log"
  write_tripwire_mas "$dir/bin/mas"
  write_tripwire_sudo "$dir/bin/sudo"

  out="$(PATH="$dir/bin:$PATH" CALL_LOG="$log" \
    env -u MAS -u SUDO bash "$RUNNER" "$tier" --mode=uninstall 2>&1)"; rc=$?
  ok "$rc" "MAS/SUDO unset: runner exits 0"
  calls="$(cat "$log")"
  ok_contains "$calls" "TRIPWIRE-MAS list" \
    "MAS unset: the runner falls back to bare \`mas\` on PATH"
  ok_absent "$calls" "TRIPWIRE-SUDO" \
    "MAS/SUDO unset: an absent app never reaches sudo"
  ok_contains "$out" "skip: Sentinel App (id $MAS_SENTINEL_ID) not installed" \
    "MAS/SUDO unset: an absent app is skipped, not uninstalled"

  rm -rf "$dir"
}

# ---------------------------------------------------------------------
# Block 4: the Makefile's BREW= / MAS= / SUDO= reach the runner.
# ---------------------------------------------------------------------
makefile_test() {
  local root host_dir stub mas_stub sudo_stub log out rc calls
  root="$(mktemp -d)"
  host_dir="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" "$root/profiles/sentinel" "$root/bin"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/apply_tier.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  printf '[profile]\npurge = ["cask:sentinel-cask", "mas:%s:Sentinel App"]\n' \
    "$MAS_SENTINEL_ID" > "$root/profiles/sentinel/config.toml"
  # The host must opt into the profile for the purge loop to walk that tier.
  printf 'profiles = ["sentinel"]\n' > "$host_dir/config.toml"

  stub="$root/scripts/stub-brew"
  mas_stub="$root/scripts/stub-mas"
  sudo_stub="$root/scripts/stub-sudo"
  log="$root/calls.log"
  : > "$log"
  write_recording_brew "$stub"
  write_recording_mas "$mas_stub"
  write_recording_sudo "$sudo_stub"
  write_tripwire_brew "$root/bin/brew"
  write_tripwire_mas "$root/bin/mas"
  write_tripwire_sudo "$root/bin/sudo"

  out="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" \
    CALL_LOG="$log" make remove-and-purge BREW="$stub" MAS="$mas_stub" \
    SUDO="$sudo_stub" 2>&1)"; rc=$?
  ok "$rc" "make remove-and-purge BREW=/MAS=/SUDO=<stub> exits 0"
  calls="$(cat "$log")"
  ok_absent "$calls" "TRIPWIRE" \
    "make remove-and-purge: bare \`brew\`/\`mas\`/\`sudo\` on PATH are never invoked"
  ok_contains "$calls" "list --cask sentinel-cask" \
    "make's BREW= reaches the runner's probe"
  ok_contains "$calls" "uninstall --cask --zap sentinel-cask" \
    "make's BREW= reaches the runner's purge uninstall"
  ok_contains "$calls" "MAS list" \
    "make's MAS= reaches the runner's mas probe"
  ok_contains "$calls" "SUDO $mas_stub uninstall $MAS_SENTINEL_ID" \
    "make's SUDO= reaches the runner, and runs the overridden mas"

  rm -rf "$root" "$host_dir"
}

echo "=== Block 1: no bare brew/mas/sudo invocation in remove_runner.sh ==="
static_test
echo "=== Block 2: BREW override covers probes and uninstalls ==="
override_test
echo "=== Block 3: BREW unset falls back to bare brew ==="
default_test
echo "=== Block 4: make's BREW=/MAS=/SUDO= reach the runner ==="
makefile_test
echo "=== Block 5: MAS/SUDO override covers the probe and the uninstall ==="
mas_override_test
echo "=== Block 6: MAS/SUDO unset falls back to bare mas ==="
mas_default_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All remove-runner binary-override tests passed."
  exit 0
fi
echo "Some remove-runner binary-override tests FAILED."
exit 1
