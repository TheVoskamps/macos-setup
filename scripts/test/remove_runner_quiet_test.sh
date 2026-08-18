#!/usr/bin/env bash

# Tests for quiet-by-default empty-TIER suppression in the uninstall /
# purge paths (issue #167, carried across the profiles cutover in #33).
#
# A typical `make update` (-> the uninstall and purge loops) used to print
# ~80 lines like:
#
#   ==> Applying Uninstall: profiles/foo
#   [uninstall] Processing profile foo
#   [uninstall] Done: profile foo
#
# for EVERY tier, even though nearly every tier removes nothing at all.
#
# The fix gates output on whether the tier's `[profile] uninstall` (or
# `purge`) array has any entry, decided inside scripts/remove_runner.sh —
# the ONE place that reads the array — so the Makefile's `==> Applying ...`
# banner (passed via --banner=<text>) and the runner's `Processing`/`Done`
# lines can never disagree about whether a tier is silent:
#   - default (non-VERBOSE): a tier with an EMPTY or absent array prints
#     NOTHING (no banner, no Processing/Done).
#   - a tier with >=1 entry prints fully, INCLUDING any
#     `skip: <pkg> not installed` lines (those are useful).
#   - VERBOSE=1 restores ALL lines for EVERY tier, including empty ones.
#
# The gate is PER MODE, not per tier: a tier that declares only a `purge`
# array stays silent under --mode=uninstall.
#
# Block 1 drives the runner directly (banner + Processing/Done + skip).
# Blocks 2-3 drive the real Makefile `make uninstall` /
# `make remove-and-purge` loops against a synthetic repo with one empty
# tier and one active tier, asserting the empty tier is silent by default
# and fully shown under VERBOSE=1, while the active tier always prints.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/remove_runner.sh"

pass=0
fail=0
ok_rc() {
  # ok_rc <actual_rc> <want-rc> <label>
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want $2)"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}
ok_empty() {
  # ok_empty <haystack> <label>
  if [[ -z "$1" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2 -- output not empty: [$1]"; ((fail++)); fi
}

# A stub `brew` that reports nothing installed (so the active tier's
# entry becomes a `skip` line) and never fails.
#
# EVERY block below routes the runner at this stub, via the BREW env var
# (direct invocations) or the BREW make variable, which GNU make exports
# into the recipe environment (Makefile-driven invocations) -- and also
# shims it onto PATH as `brew` for defence in depth. The active tier names
# a real cask, and blocks 2-3 drive the NON-dry-run `make uninstall` /
# `make remove-and-purge`, so an unstubbed brew here would uninstall (and
# under --mode=purge, --zap) that cask off the developer's machine.
# scripts/test/remove_runner_brew_override_test.sh pins the runner's side
# of that contract.
write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# `brew list --formula <name>` / `brew list --cask <name>` -> not installed.
exit 1
STUB
  chmod +x "$path"
}

# ---------------------------------------------------------------------
# Block 1: drive the runner directly.
# ---------------------------------------------------------------------
runner_direct_test() {
  local dir stub out rc
  dir="$(mktemp -d)"
  # Two tier directories: one whose [profile] section declares no removals
  # at all, one that removes a cask in both modes.
  mkdir -p "$dir/empty" "$dir/active"
  printf '[profile]\npost_install = []\n' > "$dir/empty/config.toml"
  printf '[profile]\nuninstall = ["cask:vibe-notch"]\npurge = ["cask:vibe-notch"]\n' \
    > "$dir/active/config.toml"
  # BREW points every probe at the stub, so the `skip:` assertion below is
  # a property of the runner rather than of whether this developer happens
  # to have vibe-notch installed.
  stub="$dir/stub_brew.sh"
  write_stub_brew "$stub"
  export BREW="$stub"

  # Empty slot, VERBOSE unset -> NOTHING on stdout, rc 0.
  out="$(bash "$RUNNER" "$dir/empty" --mode=uninstall --banner="==> BANNER empty" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: empty tier, VERBOSE unset exits 0"
  ok_empty "$out" "runner: empty tier, VERBOSE unset prints nothing"

  # Empty slot, VERBOSE=1 -> banner + Processing + Done.
  out="$(VERBOSE=1 bash "$RUNNER" "$dir/empty" --mode=uninstall --banner="==> BANNER empty" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: empty tier, VERBOSE=1 exits 0"
  ok_contains "$out" "==> BANNER empty"           "runner: empty tier, VERBOSE=1 shows banner"
  ok_contains "$out" "[uninstall] Processing"     "runner: empty tier, VERBOSE=1 shows Processing"
  ok_contains "$out" "[uninstall] Done"           "runner: empty tier, VERBOSE=1 shows Done"

  # Active slot, VERBOSE unset -> banner + Processing + skip + Done.
  out="$(bash "$RUNNER" "$dir/active" --mode=uninstall --banner="==> BANNER active" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: active tier, VERBOSE unset exits 0"
  ok_contains "$out" "==> BANNER active"          "runner: active tier shows banner"
  ok_contains "$out" "[uninstall] Processing"     "runner: active tier shows Processing"
  ok_contains "$out" "skip: vibe-notch not installed" "runner: active tier keeps the skip line"
  ok_contains "$out" "[uninstall] Done"           "runner: active tier shows Done"

  # Active tier under --mode=purge: banner uses whatever caller passes.
  out="$(bash "$RUNNER" "$dir/active" --mode=purge --banner="==> BANNER purge" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: active tier, purge mode exits 0"
  ok_contains "$out" "[purge] Processing"         "runner: active tier, purge mode uses [purge] prefix"

  # The gate is PER MODE: a tier declaring only a `purge` array must stay
  # silent under --mode=uninstall, or every purge-only tier would print an
  # empty uninstall pass.
  printf '[profile]\npurge = ["cask:vibe-notch"]\n' > "$dir/active/config.toml"
  out="$(bash "$RUNNER" "$dir/active" --mode=uninstall --banner="==> BANNER u" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: purge-only tier under --mode=uninstall exits 0"
  ok_empty "$out" "runner: purge-only tier is silent under --mode=uninstall"

  unset BREW
  rm -rf "$dir"
}

# Build a synthetic repo carrying the real Makefile + the scripts its
# removal loops invoke, with exactly two profile tiers: one that removes
# nothing and one that removes a single cask (in both modes).
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" \
           "$root/profiles/emptyprof" "$root/profiles/activeprof"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/apply_tier.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  printf '[profile]\npost_install = []\n' > "$root/profiles/emptyprof/config.toml"
  printf '[profile]\nuninstall = ["cask:vibe-notch"]\npurge = ["cask:vibe-notch"]\n' \
    > "$root/profiles/activeprof/config.toml"
  echo "$root"
}

run_make() {
  # run_make <target> <verbose:""|"1"> -> sets RUN_OUT / RUN_RC
  local target="$1" verbose="$2"
  local root host_dir brew_stub
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  # The host opts into both profiles so both tiers are in the loops' walk.
  printf 'profiles = ["emptyprof", "activeprof"]\n' > "$host_dir/config.toml"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  # Same stub also shimmed onto PATH as bare `brew` (defence in depth --
  # see the write_stub_brew header).
  mkdir -p "$root/bin"
  cp "$brew_stub" "$root/bin/brew"
  if [[ -n "$verbose" ]]; then
    RUN_OUT="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" VERBOSE="$verbose" \
      make "$target" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  else
    RUN_OUT="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" \
      make "$target" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  fi
  rm -rf "$root" "$host_dir"
}

EMPTY_BANNER_U="==> Applying Uninstall: profiles/emptyprof"
ACTIVE_BANNER_U="==> Applying Uninstall: profiles/activeprof"
EMPTY_BANNER_P="==> Applying RemoveAndPurge: profiles/emptyprof"
ACTIVE_BANNER_P="==> Applying RemoveAndPurge: profiles/activeprof"

# ---------------------------------------------------------------------
# Block 2: `make uninstall` loop.
# ---------------------------------------------------------------------
uninstall_loop_test() {
  run_make "uninstall" ""
  ok_rc "$RUN_RC" 0 "make uninstall, VERBOSE unset exits 0"
  ok_absent   "$RUN_OUT" "$EMPTY_BANNER_U"  "make uninstall: empty tier banner suppressed by default"
  ok_absent   "$RUN_OUT" "Processing profile emptyprof" "make uninstall: empty tier Processing suppressed by default"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_U" "make uninstall: active tier banner always shown"
  ok_contains "$RUN_OUT" "skip: vibe-notch not installed" "make uninstall: active tier skip line shown"

  run_make "uninstall" "1"
  ok_rc "$RUN_RC" 0 "make uninstall, VERBOSE=1 exits 0"
  ok_contains "$RUN_OUT" "$EMPTY_BANNER_U"  "make uninstall, VERBOSE=1: empty tier banner restored"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_U" "make uninstall, VERBOSE=1: active tier banner shown"
}

# ---------------------------------------------------------------------
# Block 3: `make remove-and-purge` loop (incl. dry-run companion).
# ---------------------------------------------------------------------
purge_loop_test() {
  run_make "remove-and-purge" ""
  ok_rc "$RUN_RC" 0 "make remove-and-purge, VERBOSE unset exits 0"
  ok_absent   "$RUN_OUT" "$EMPTY_BANNER_P"  "make remove-and-purge: empty tier banner suppressed by default"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_P" "make remove-and-purge: active tier banner always shown"

  run_make "remove-and-purge" "1"
  ok_rc "$RUN_RC" 0 "make remove-and-purge, VERBOSE=1 exits 0"
  ok_contains "$RUN_OUT" "$EMPTY_BANNER_P"  "make remove-and-purge, VERBOSE=1: empty tier banner restored"

  run_make "remove-and-purge-dry-run" ""
  ok_rc "$RUN_RC" 0 "make remove-and-purge-dry-run, VERBOSE unset exits 0"
  ok_absent   "$RUN_OUT" "$EMPTY_BANNER_P"  "make remove-and-purge-dry-run: empty tier banner suppressed by default"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_P" "make remove-and-purge-dry-run: active tier banner shown"
}

echo "=== Block 1: runner direct ==="
runner_direct_test
echo "=== Block 2: make uninstall loop ==="
uninstall_loop_test
echo "=== Block 3: make remove-and-purge loop ==="
purge_loop_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All remove-runner-quiet tests passed."
  exit 0
fi
echo "Some remove-runner-quiet tests FAILED."
exit 1
