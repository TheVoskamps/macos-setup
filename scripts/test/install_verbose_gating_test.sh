#!/usr/bin/env bash

# Tests for VERBOSE-gating of the Install tier-walk "not found" lines
# (issue #164).
#
# The per-slot Install tier walk probes every profile and the host tier
# for an Install file. In the common case most tiers contribute nothing,
# and the loop used to echo a "No ... Install found" line for each one
# unconditionally. On a host that opts into ~31 profiles x ~20 slots that
# is ~600 noise lines that bury the real install signal and look like
# errors to someone upgrading.
#
# The fix gates the two negative-case echoes behind a VERBOSE env var,
# via a single shared Makefile macro (VERBOSE_NOTE) used by BOTH the
# `install` batch loop AND the per-slot APPLY_INSTALL_TIERS macro so the
# two cannot drift:
#   - VERBOSE unset/empty (default): the "No ... Install found" lines are
#     suppressed; the run stays quiet about non-contributing tiers.
#   - VERBOSE=1 (any non-empty value): the lines are restored.
# The POSITIVE "Found ... Install" echoes and the failure summary are
# unaffected and always print.
#
# These tests stand up a synthetic repo with one Install slot present
# ONLY at the default tier (so both the profile tier and the host tier
# hit the negative "not found" branch), an active profile (so the profile
# loop body runs), and a stub `brew` that never fails. They drive BOTH
# the per-slot named target AND `make install`, each with VERBOSE unset
# and VERBOSE=1, and assert:
#   - VERBOSE unset  -> neither "No ... Install found" line appears
#   - VERBOSE=1      -> both "No ... Install found" lines appear
#   - the positive "Found ... Install" line for the default tier appears
#     in BOTH cases (gating is limited to the negative lines)
#   - every run exits 0 (no set -u / set -e breakage from the guard).
#
# The host tier lives OUTSIDE the repo (host_tier_dir in
# config_common.sh); MACOS_SETUP_HOST_DIR points it at a temp dir that
# carries a `profiles` file (activating the profile tier) but NO Install
# slot (so the host tier also hits the negative branch).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok_rc() {
  # ok_rc <actual_rc> <want-is-zero: 0|nonzero> <label>
  if [[ "$2" == "0" ]]; then
    if [[ "$1" == "0" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want 0)"; ((fail++)); fi
  else
    if [[ "$1" != "0" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=0 want non-zero)"; ((fail++)); fi
  fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}

# The slot under test. A made-up basename whose numeric prefix and suffix
# collide with NONE of the install loop's `case` post-install actions, so
# the per-slot target's post-install step is a harmless fall-through.
SLOT_BASENAME="93-Install.delta"
SLOT_TARGET="93_Install_delta"
PROFILE_NAME="testprof"

# Build a synthetic repo with the real Makefile + the scripts the install
# targets invoke, plus ONE Install slot present at the default tier only.
# The profile dir exists (so the profile is a valid name) but carries NO
# Install slot, so the profile tier hits the negative branch.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" "$root/RemoveAndPurge" \
           "$root/profiles/$PROFILE_NAME/Install"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/require_dasel_on_path.sh" \
     "$root/scripts/"
  printf 'brew "pkg_default"\n' > "$root/Install/$SLOT_BASENAME"
  echo "$root"
}

# Build the external host tier: a config.toml whose `profiles` array
# selects our profile (so the profile tier is active) but NO Install slot
# (so the host tier hits the negative branch too). The profile selector
# is now the config.toml `profiles` array (issue #156), read via dasel.
make_host_dir() {
  local host_dir; host_dir="$(mktemp -d)"
  mkdir -p "$host_dir/Install"
  printf 'profiles = ["%s"]\n' "$PROFILE_NAME" > "$host_dir/config.toml"
  echo "$host_dir"
}

# A stub `brew` that always succeeds (this test is about output volume,
# not failure handling).
write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$path"
}

# Run `make <target>` against a fresh synthetic repo + host dir, with the
# given VERBOSE value ("" for unset, "1" for set). Captures combined
# output into RUN_OUT and exit code into RUN_RC.
run_make() {
  local target="$1" verbose="$2"
  local root host_dir brew_stub
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"

  if [[ -n "$verbose" ]]; then
    RUN_OUT="$(cd "$root" && \
      MACOS_SETUP_HOST_DIR="$host_dir" VERBOSE="$verbose" \
      make "$target" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  else
    RUN_OUT="$(cd "$root" && \
      MACOS_SETUP_HOST_DIR="$host_dir" \
      make "$target" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  fi

  rm -rf "$root" "$host_dir"
}

PROFILE_NOTE="No profile Install found"
HOST_NOTE="No computer-specific Install found"
FOUND_DEFAULT="==> Applying"   # the default-tier positive line

# ---------------------------------------------------------------------
# Block 1: per-slot named target, VERBOSE unset -> notes suppressed.
# ---------------------------------------------------------------------
per_slot_quiet_test() {
  run_make "$SLOT_TARGET" ""
  ok_rc "$RUN_RC" 0 "per-slot, VERBOSE unset: exits 0"
  ok_absent "$RUN_OUT" "$PROFILE_NOTE" "per-slot, VERBOSE unset: profile 'not found' line suppressed"
  ok_absent "$RUN_OUT" "$HOST_NOTE" "per-slot, VERBOSE unset: host 'not found' line suppressed"
  ok_contains "$RUN_OUT" "$FOUND_DEFAULT" "per-slot, VERBOSE unset: default tier still applied (positive line kept)"
}

# ---------------------------------------------------------------------
# Block 2: per-slot named target, VERBOSE=1 -> notes restored.
# ---------------------------------------------------------------------
per_slot_verbose_test() {
  run_make "$SLOT_TARGET" "1"
  ok_rc "$RUN_RC" 0 "per-slot, VERBOSE=1: exits 0"
  ok_contains "$RUN_OUT" "$PROFILE_NOTE" "per-slot, VERBOSE=1: profile 'not found' line shown"
  ok_contains "$RUN_OUT" "$HOST_NOTE" "per-slot, VERBOSE=1: host 'not found' line shown"
}

# ---------------------------------------------------------------------
# Block 3: batch `make install`, VERBOSE unset -> notes suppressed.
# ---------------------------------------------------------------------
batch_quiet_test() {
  run_make "install" ""
  ok_rc "$RUN_RC" 0 "batch install, VERBOSE unset: exits 0"
  ok_absent "$RUN_OUT" "$PROFILE_NOTE" "batch install, VERBOSE unset: profile 'not found' line suppressed"
  ok_absent "$RUN_OUT" "$HOST_NOTE" "batch install, VERBOSE unset: host 'not found' line suppressed"
  ok_contains "$RUN_OUT" "$FOUND_DEFAULT" "batch install, VERBOSE unset: default tier still applied (positive line kept)"
}

# ---------------------------------------------------------------------
# Block 4: batch `make install`, VERBOSE=1 -> notes restored.
# ---------------------------------------------------------------------
batch_verbose_test() {
  run_make "install" "1"
  ok_rc "$RUN_RC" 0 "batch install, VERBOSE=1: exits 0"
  ok_contains "$RUN_OUT" "$PROFILE_NOTE" "batch install, VERBOSE=1: profile 'not found' line shown"
  ok_contains "$RUN_OUT" "$HOST_NOTE" "batch install, VERBOSE=1: host 'not found' line shown"
}

echo "=== per-slot target, VERBOSE unset (quiet) ==="
per_slot_quiet_test
echo "=== per-slot target, VERBOSE=1 (verbose) ==="
per_slot_verbose_test
echo "=== batch install, VERBOSE unset (quiet) ==="
batch_quiet_test
echo "=== batch install, VERBOSE=1 (verbose) ==="
batch_verbose_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All install-verbose-gating tests passed."
  exit 0
fi
echo "Some install-verbose-gating tests FAILED."
exit 1
