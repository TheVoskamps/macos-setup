#!/usr/bin/env bash

# Tests for VERBOSE-gating of the install tier-walk "nothing here" lines
# (issue #164, carried across the profiles cutover in issue #33).
#
# The install tier walk visits every tier this host has — the core tier,
# each profile in the host's list, then the host tier. In the common case
# most tiers contribute no Brewfile and no post_install actions, and
# echoing a line for each one buries the real install signal under noise
# that looks like errors to someone upgrading.
#
# The fix gates the negative-case echoes behind a VERBOSE env var, in ONE
# place — scripts/apply_tier.sh, which every install path routes through
# (`make install`, `make core`, `make profile <name>`, and `make update`'s
# version-managers step). A single chokepoint is what stops those paths
# from drifting apart on output volume:
#   - VERBOSE unset/empty (default): "No Brewfile found at ..." and
#     "No post_install entries for ..." are suppressed.
#   - VERBOSE=1 (any non-empty value): both are restored.
# The POSITIVE "==> Applying ..." echoes and every failure line are
# unaffected and always print.
#
# These tests stand up a synthetic repo whose CORE tier has a Brewfile and
# whose one active PROFILE has neither a Brewfile nor a post_install list
# (so that tier hits both negative branches), plus a stub `brew` that
# never fails. They drive BOTH `make profile <name>` and `make install`,
# each with VERBOSE unset and VERBOSE=1.

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

PROFILE_NAME="testprof"

# Synthetic repo: the core tier carries a Brewfile (the positive line),
# the profile directory exists but is EMPTY (so both negative branches
# fire for it).
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" "$root/profiles/$PROFILE_NAME"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/apply_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/require_dasel_on_path.sh" \
     "$root/scripts/"
  printf 'brew "pkg_core"\n' > "$root/default/Brewfile"
  echo "$root"
}

# The external host tier: selects our profile (so the profile tier is
# active) but carries no Brewfile of its own, so it too hits the negative
# branch.
make_host_dir() {
  local host_dir; host_dir="$(mktemp -d)"
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

# Run `make <target...>` against a fresh synthetic repo + host dir, with
# the given VERBOSE value ("" for unset, "1" for set). Captures combined
# output into RUN_OUT and exit code into RUN_RC.
run_make() {
  local verbose="$1"; shift
  local root host_dir brew_stub
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"

  if [[ -n "$verbose" ]]; then
    RUN_OUT="$(cd "$root" && \
      MACOS_SETUP_HOST_DIR="$host_dir" VERBOSE="$verbose" \
      make "$@" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  else
    RUN_OUT="$(cd "$root" && \
      MACOS_SETUP_HOST_DIR="$host_dir" \
      make "$@" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  fi

  rm -rf "$root" "$host_dir"
}

NO_BREWFILE_NOTE="No Brewfile found at"
NO_HOOKS_NOTE="No post_install entries for"
APPLYING="==> Applying"   # the positive line

# ---------------------------------------------------------------------
# Block 1: `make profile <name>`, VERBOSE unset -> notes suppressed.
# ---------------------------------------------------------------------
per_profile_quiet_test() {
  run_make "" profile "$PROFILE_NAME"
  ok_rc "$RUN_RC" 0 "make profile, VERBOSE unset: exits 0"
  ok_absent "$RUN_OUT" "$NO_BREWFILE_NOTE" "make profile, VERBOSE unset: 'No Brewfile' suppressed"
  ok_absent "$RUN_OUT" "$NO_HOOKS_NOTE" "make profile, VERBOSE unset: 'No post_install' suppressed"
}

# ---------------------------------------------------------------------
# Block 2: `make profile <name>`, VERBOSE=1 -> notes restored.
# ---------------------------------------------------------------------
per_profile_verbose_test() {
  run_make "1" profile "$PROFILE_NAME"
  ok_rc "$RUN_RC" 0 "make profile, VERBOSE=1: exits 0"
  ok_contains "$RUN_OUT" "$NO_BREWFILE_NOTE" "make profile, VERBOSE=1: 'No Brewfile' shown"
  ok_contains "$RUN_OUT" "$NO_HOOKS_NOTE" "make profile, VERBOSE=1: 'No post_install' shown"
}

# ---------------------------------------------------------------------
# Block 3: batch `make install`, VERBOSE unset -> notes suppressed, but
# the positive line for the core tier's Brewfile still prints.
# ---------------------------------------------------------------------
batch_quiet_test() {
  run_make "" install
  ok_rc "$RUN_RC" 0 "make install, VERBOSE unset: exits 0"
  ok_absent "$RUN_OUT" "$NO_BREWFILE_NOTE" "make install, VERBOSE unset: 'No Brewfile' suppressed"
  ok_absent "$RUN_OUT" "$NO_HOOKS_NOTE" "make install, VERBOSE unset: 'No post_install' suppressed"
  ok_contains "$RUN_OUT" "$APPLYING" "make install, VERBOSE unset: core tier still applied (positive line kept)"
}

# ---------------------------------------------------------------------
# Block 4: batch `make install`, VERBOSE=1 -> notes restored.
# ---------------------------------------------------------------------
batch_verbose_test() {
  run_make "1" install
  ok_rc "$RUN_RC" 0 "make install, VERBOSE=1: exits 0"
  ok_contains "$RUN_OUT" "$NO_BREWFILE_NOTE" "make install, VERBOSE=1: 'No Brewfile' shown"
  ok_contains "$RUN_OUT" "$NO_HOOKS_NOTE" "make install, VERBOSE=1: 'No post_install' shown"
  ok_contains "$RUN_OUT" "$APPLYING" "make install, VERBOSE=1: positive line still printed"
}

echo "=== make profile, VERBOSE unset (quiet) ==="
per_profile_quiet_test
echo "=== make profile, VERBOSE=1 (verbose) ==="
per_profile_verbose_test
echo "=== make install, VERBOSE unset (quiet) ==="
batch_quiet_test
echo "=== make install, VERBOSE=1 (verbose) ==="
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
