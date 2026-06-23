#!/usr/bin/env bash

# Tests for quiet-by-default empty-slot suppression in the Uninstall /
# RemoveAndPurge paths (issue #167).
#
# A typical `make update` (-> the Uninstall and RemoveAndPurge loops)
# used to print ~80 lines like:
#
#   ==> Applying global Uninstall: Uninstall/00-Uninstall.core
#   [uninstall] Processing Uninstall/00-Uninstall.core
#   [uninstall] Done: Uninstall/00-Uninstall.core
#
# for EVERY numbered slot (00-19), even though nearly every slot file is
# just a comment header with no actual package to remove.
#
# The fix gates output on whether the slot file has any ACTIVE directive
# (an uncommented, non-blank brew/cask/mas line), decided as a static
# check inside scripts/remove_runner.sh — the ONE place that reads the
# file — so the Makefile's `==> Applying ...` banner (now passed via
# --banner=<text>) and the runner's `Processing`/`Done` lines can never
# disagree about whether a slot+tier is silent:
#   - default (non-VERBOSE): a slot with ZERO active directives prints
#     NOTHING (no banner, no Processing/Done).
#   - a slot with >=1 active directive prints fully, INCLUDING any
#     `skip: <pkg> not installed` lines (those are useful).
#   - VERBOSE=1 restores ALL lines for EVERY slot, including empty ones.
#
# Block 1 drives the runner directly (banner + Processing/Done + skip).
# Blocks 2-3 drive the real Makefile `make uninstall` /
# `make remove-and-purge` loops against a synthetic repo with one empty
# slot and one active slot, asserting the empty slot is silent by default
# and fully shown under VERBOSE=1, while the active slot always prints.

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

# A stub `brew` that reports nothing installed (so the active slot's
# directive becomes a `skip` line) and never fails.
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
  local dir empty active out rc
  dir="$(mktemp -d)"
  printf '# header only\n# Casks\n'              > "$dir/empty"
  printf "# header\n# Casks\ncask 'vibe-notch'\n" > "$dir/active"

  # Empty slot, VERBOSE unset -> NOTHING on stdout, rc 0.
  out="$(bash "$RUNNER" "$dir/empty" --mode=uninstall --banner="==> BANNER empty" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: empty slot, VERBOSE unset exits 0"
  ok_empty "$out" "runner: empty slot, VERBOSE unset prints nothing"

  # Empty slot, VERBOSE=1 -> banner + Processing + Done.
  out="$(VERBOSE=1 bash "$RUNNER" "$dir/empty" --mode=uninstall --banner="==> BANNER empty" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: empty slot, VERBOSE=1 exits 0"
  ok_contains "$out" "==> BANNER empty"           "runner: empty slot, VERBOSE=1 shows banner"
  ok_contains "$out" "[uninstall] Processing"     "runner: empty slot, VERBOSE=1 shows Processing"
  ok_contains "$out" "[uninstall] Done"           "runner: empty slot, VERBOSE=1 shows Done"

  # Active slot, VERBOSE unset -> banner + Processing + skip + Done.
  out="$(bash "$RUNNER" "$dir/active" --mode=uninstall --banner="==> BANNER active" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: active slot, VERBOSE unset exits 0"
  ok_contains "$out" "==> BANNER active"          "runner: active slot shows banner"
  ok_contains "$out" "[uninstall] Processing"     "runner: active slot shows Processing"
  ok_contains "$out" "skip: vibe-notch not installed" "runner: active slot keeps the skip line"
  ok_contains "$out" "[uninstall] Done"           "runner: active slot shows Done"

  # Active slot under --mode=purge: banner uses whatever caller passes.
  out="$(bash "$RUNNER" "$dir/active" --mode=purge --banner="==> BANNER purge" --dry-run 2>&1)"; rc=$?
  ok_rc "$rc" 0 "runner: active slot, purge mode exits 0"
  ok_contains "$out" "[purge] Processing"         "runner: active slot, purge mode uses [purge] prefix"

  rm -rf "$dir"
}

# Build a synthetic repo carrying the real Makefile + the scripts its
# removal loops invoke, with exactly two slots: one empty (comment-only)
# and one active (a single cask). The host tier (pointed at a temp dir by
# the caller) is left empty so only the global tier contributes.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" "$root/RemoveAndPurge"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  # Empty slot 00, active slot 01 — for both Uninstall and RemoveAndPurge.
  printf '# header only\n'                        > "$root/Uninstall/00-Uninstall.empty"
  printf "# header\ncask 'vibe-notch'\n"          > "$root/Uninstall/01-Uninstall.active"
  printf '# header only\n'                        > "$root/RemoveAndPurge/00-RemoveAndPurge.empty"
  printf "# header\ncask 'vibe-notch'\n"          > "$root/RemoveAndPurge/01-RemoveAndPurge.active"
  echo "$root"
}

run_make() {
  # run_make <target> <verbose:""|"1"> -> sets RUN_OUT / RUN_RC
  local target="$1" verbose="$2"
  local root host_dir brew_stub
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  if [[ -n "$verbose" ]]; then
    RUN_OUT="$(cd "$root" && MACOS_SETUP_HOST_DIR="$host_dir" VERBOSE="$verbose" \
      make "$target" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  else
    RUN_OUT="$(cd "$root" && MACOS_SETUP_HOST_DIR="$host_dir" \
      make "$target" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  fi
  rm -rf "$root" "$host_dir"
}

EMPTY_BANNER_U="==> Applying global Uninstall: Uninstall/00-Uninstall.empty"
ACTIVE_BANNER_U="==> Applying global Uninstall: Uninstall/01-Uninstall.active"
EMPTY_BANNER_P="==> Applying global RemoveAndPurge: RemoveAndPurge/00-RemoveAndPurge.empty"
ACTIVE_BANNER_P="==> Applying global RemoveAndPurge: RemoveAndPurge/01-RemoveAndPurge.active"

# ---------------------------------------------------------------------
# Block 2: `make uninstall` loop.
# ---------------------------------------------------------------------
uninstall_loop_test() {
  run_make "uninstall" ""
  ok_rc "$RUN_RC" 0 "make uninstall, VERBOSE unset exits 0"
  ok_absent   "$RUN_OUT" "$EMPTY_BANNER_U"  "make uninstall: empty slot banner suppressed by default"
  ok_absent   "$RUN_OUT" "00-Uninstall.empty (dry-run)" "make uninstall: empty slot Processing suppressed by default"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_U" "make uninstall: active slot banner always shown"
  ok_contains "$RUN_OUT" "skip: vibe-notch not installed" "make uninstall: active slot skip line shown"

  run_make "uninstall" "1"
  ok_rc "$RUN_RC" 0 "make uninstall, VERBOSE=1 exits 0"
  ok_contains "$RUN_OUT" "$EMPTY_BANNER_U"  "make uninstall, VERBOSE=1: empty slot banner restored"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_U" "make uninstall, VERBOSE=1: active slot banner shown"
}

# ---------------------------------------------------------------------
# Block 3: `make remove-and-purge` loop (incl. dry-run companion).
# ---------------------------------------------------------------------
purge_loop_test() {
  run_make "remove-and-purge" ""
  ok_rc "$RUN_RC" 0 "make remove-and-purge, VERBOSE unset exits 0"
  ok_absent   "$RUN_OUT" "$EMPTY_BANNER_P"  "make remove-and-purge: empty slot banner suppressed by default"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_P" "make remove-and-purge: active slot banner always shown"

  run_make "remove-and-purge" "1"
  ok_rc "$RUN_RC" 0 "make remove-and-purge, VERBOSE=1 exits 0"
  ok_contains "$RUN_OUT" "$EMPTY_BANNER_P"  "make remove-and-purge, VERBOSE=1: empty slot banner restored"

  run_make "remove-and-purge-dry-run" ""
  ok_rc "$RUN_RC" 0 "make remove-and-purge-dry-run, VERBOSE unset exits 0"
  ok_absent   "$RUN_OUT" "$EMPTY_BANNER_P"  "make remove-and-purge-dry-run: empty slot banner suppressed by default"
  ok_contains "$RUN_OUT" "$ACTIVE_BANNER_P" "make remove-and-purge-dry-run: active slot banner shown"
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
