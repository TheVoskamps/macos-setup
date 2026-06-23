#!/usr/bin/env bash

# Tests for per-slot named-target failure tolerance (issue #163).
#
# PR #165 made the `make install` BATCH loop attempt every slot and
# collect per-slot `brew bundle` failures. But the per-slot NAMED
# targets (`make ui`, `make 16`, the generated `NN_Install_*` targets,
# etc.) were only partially fault-tolerant: each ran three tier helpers
# as three separate recipe lines, and only the MIDDLE tier
# (RUN_PROFILE_SPECIFIC) collected-and-continued. The default tier
# (APPLY_INSTALL_FILE) and the host tier (RUN_COMPUTER_SPECIFIC) still
# aborted on the first `brew bundle` failure. Worse, because the three
# helpers were separate recipe lines, a non-zero exit from an earlier
# line made `make` abort the target and SKIP the later tiers entirely.
#
# The fix collapses the three tiers into a single APPLY_INSTALL_TIERS
# helper that runs default -> profiles(order) -> host in ONE shell,
# accumulating failures across all three tiers and exiting non-zero
# (with an end-of-run summary) only after every tier was attempted.
#
# This test guards the per-slot path the batch-loop test does not
# exercise. It stands up a synthetic repo with ONE Install slot present
# at all three tiers (default + one profile + host), points the host
# tier at a temp dir that also carries a `profiles` file (so the
# profile tier is active), and drives the canonical per-slot target
# `make <NN>_Install_<suffix>` with a stub `brew` that fails exactly
# one tier. It asserts, for a default-tier failure AND (separately) a
# host-tier failure:
#   - every tier's `brew bundle` is still attempted (no early abort,
#     no skipped tier)
#   - the target exits non-zero
#   - the end-of-run summary names the failed tier's slot
# Plus a clean run that exits 0 with no summary.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"
    ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"
    ((fail++))
  fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_rc() {
  # ok_rc <actual_rc> <want-is-zero: 0|nonzero> <label>
  if [[ "$2" == "0" ]]; then
    if [[ "$1" == "0" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want 0)"; ((fail++)); fi
  else
    if [[ "$1" != "0" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=0 want non-zero)"; ((fail++)); fi
  fi
}

# The slot under test. A made-up basename whose numeric prefix and
# suffix collide with NONE of the install loop's `case` post-install
# actions, so the per-slot target's post-install step is a harmless
# fall-through. Canonical target = 93_Install_delta.
SLOT_BASENAME="93-Install.delta"
SLOT_TARGET="93_Install_delta"
PROFILE_NAME="testprof"

# Build a synthetic repo with the real Makefile + the scripts the
# per-slot target chain invokes, plus one Install slot present at the
# default tier and at one profile tier. The host-tier copy is written
# into the external host dir by make_host_dir (it lives OUTSIDE the
# repo). Each tier's bundle file carries a distinct pkg_<tier> marker
# so the stub brew can fail a specific tier and the test can assert
# which tiers were attempted.
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
     "$root/scripts/"
  # Default tier and profile tier slots (same basename).
  printf 'brew "pkg_default"\n' > "$root/Install/$SLOT_BASENAME"
  printf 'brew "pkg_profile"\n' > "$root/profiles/$PROFILE_NAME/Install/$SLOT_BASENAME"
  echo "$root"
}

# Build the external host tier dir: a config.toml whose `profiles` array
# selects our one profile (so the profile tier is active) and a host-tier
# copy of the slot. The host tier lives OUTSIDE the repo (host_tier_dir).
# The profile selector is now the config.toml `profiles` array (issue
# #156), read via dasel.
make_host_dir() {
  local host_dir; host_dir="$(mktemp -d)"
  mkdir -p "$host_dir/Install"
  printf 'profiles = ["%s"]\n' "$PROFILE_NAME" > "$host_dir/config.toml"
  printf 'brew "pkg_host"\n' > "$host_dir/Install/$SLOT_BASENAME"
  echo "$host_dir"
}

# A stub `brew` that logs each `bundle --file=<f>` invocation's resolved
# package marker to $BREW_LOG and exits 1 when the bundle file mentions
# $FAIL_PKG, else exits 0.
write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# Stub brew for install_failure_per_slot_test.sh.
if [[ "${1:-}" == "bundle" ]]; then
  file=""
  for a in "$@"; do
    case "$a" in --file=*) file="${a#--file=}" ;; esac
  done
  pkg="$(grep -oE 'pkg_[a-z]+' "$file" 2>/dev/null | head -n1)"
  echo "bundle:$pkg" >> "$BREW_LOG"
  if [[ -n "${FAIL_PKG:-}" && "$pkg" == "$FAIL_PKG" ]]; then
    echo "stub-brew: simulated failure for $pkg" >&2
    exit 1
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$path"
}

# Run `make <SLOT_TARGET>` against a fresh synthetic repo + host dir,
# with the stub brew failing $1 (a pkg_<tier> marker, or empty for a
# clean run). Captures combined output into $RUN_OUT, exit code into
# $RUN_RC, and the ordered attempted-tier log into $RUN_LOG.
run_slot() {
  local fail_pkg="$1"
  local root host_dir brew_stub brew_log
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  RUN_OUT="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" FAIL_PKG="$fail_pkg" \
    make "$SLOT_TARGET" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  RUN_LOG="$(paste -sd, - < "$brew_log")"

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 1: DEFAULT-tier failure. The pre-fix bug aborted here (bare
# `brew bundle` under set -e), skipping profile + host tiers entirely.
# Assert all three tiers still attempted, non-zero exit, summary names
# the default slot.
# ---------------------------------------------------------------------
default_tier_failure_test() {
  run_slot "pkg_default"
  ok_rc "$RUN_RC" nonzero "default-tier failure: per-slot target exits non-zero"
  ok_contains "$RUN_OUT" "Install/$SLOT_BASENAME" "default-tier failure: summary names the default slot"
  ok_contains "$RUN_OUT" "brew bundle returned non-zero" "default-tier failure: prints a failure summary"
  ok "$RUN_LOG" "bundle:pkg_default,bundle:pkg_profile,bundle:pkg_host" \
    "default-tier failure: profile and host tiers still attempted (no early abort)"
}

# ---------------------------------------------------------------------
# Block 2: HOST-tier failure. The pre-fix bug aborted here too (bare
# `brew bundle` under set -e). The default + profile tiers run first
# and succeed; the host tier fails. Assert all three tiers attempted,
# non-zero exit, summary names the host slot.
# ---------------------------------------------------------------------
host_tier_failure_test() {
  run_slot "pkg_host"
  ok_rc "$RUN_RC" nonzero "host-tier failure: per-slot target exits non-zero"
  ok_contains "$RUN_OUT" "/Install/$SLOT_BASENAME" "host-tier failure: summary names the host slot"
  ok_contains "$RUN_OUT" "brew bundle returned non-zero" "host-tier failure: prints a failure summary"
  ok "$RUN_LOG" "bundle:pkg_default,bundle:pkg_profile,bundle:pkg_host" \
    "host-tier failure: every tier attempted"
}

# ---------------------------------------------------------------------
# Block 3: clean run -> exit 0, no failure summary, all tiers attempted.
# ---------------------------------------------------------------------
clean_slot_test() {
  run_slot ""
  ok_rc "$RUN_RC" 0 "clean per-slot run: exits 0"
  ok "$RUN_LOG" "bundle:pkg_default,bundle:pkg_profile,bundle:pkg_host" \
    "clean per-slot run: every tier attempted"
  if grep -qF "brew bundle returned non-zero" <<<"$RUN_OUT"; then
    echo "FAIL: clean per-slot run: must not print a failure summary"; ((fail++))
  else
    echo "PASS: clean per-slot run: no failure summary"; ((pass++))
  fi
}

echo "=== default-tier failure (per-slot target) ==="
default_tier_failure_test
echo "=== host-tier failure (per-slot target) ==="
host_tier_failure_test
echo "=== clean per-slot run ==="
clean_slot_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All per-slot install-failure tests passed."
  exit 0
fi
echo "Some per-slot install-failure tests FAILED."
exit 1
