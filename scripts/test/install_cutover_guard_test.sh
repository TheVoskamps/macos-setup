#!/usr/bin/env bash

# Tests for the mise-reachability guard on `make install`'s inline
# version-managers purge (the asdf -> mise cutover).
#
# `make install` is the one place the install path removes anything: right
# after it applies the `version-managers` tier, the batch loop applies that
# same tier's `[profile] purge` array inline, which uninstalls asdf and
# direnv. That removal must never run on a host where mise is not actually
# reachable at that moment -- a host left with neither is strictly worse
# off than a host carrying both.
#
# `set -e` alone is NOT the guard being tested here, and the install loop
# does not even run under it any more (it tracks failures explicitly so an
# early tier's failure cannot skip the later tiers). The real
# versions_setup.sh does exit non-zero when mise is missing, so a run would
# in practice report that tier as failed. That protection is incidental: it
# lives in another file, and a refactor that moves the purge or reorders
# require_mise would reopen the hazard silently. These tests pin the
# EXPLICIT guard -- $(MISE_REACHABLE), evaluated at the destructive call
# site -- so removing it fails the suite.
#
# Two blocks:
#
#   Block 1 (static): MISE_REACHABLE is defined once and used by BOTH
#   destructive paths, and in the `install` recipe it appears before the
#   inline purge rather than after it.
#
#   Block 2 (behavioral): drive the real `make install` in a synthetic
#   repo with a stub versions_setup.sh that SUCCEEDS (so `set -e` cannot
#   be what stops the purge) and MISE pointed at an absent binary. The
#   purge must not run, the run must warn and exit non-zero. With MISE
#   pointed at a reachable binary the same repo purges normally and
#   exits 0.
#
# Block 2 passes a stub `brew` as the BREW make variable AND shims it onto
# PATH. BREW is what scripts/remove_runner.sh honors (see
# scripts/test/remove_runner_brew_override_test.sh, which fails if a bare
# `brew` call is reintroduced there); the PATH shim is kept as defence in
# depth, because the fixture names the host's real asdf and a `make install`
# run reaches more scripts than the runner alone.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAKEFILE="$REPO_ROOT/Makefile"

pass=0
fail=0
ok() {
  # ok <condition-rc> <label>
  if [[ "$1" == "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2"; ((fail++)); fi
}
ok_rc_nonzero() {
  # ok_rc_nonzero <rc> <label>
  if [[ "$1" != "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2 (rc=0, want non-zero)"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}
ok_before() {
  # ok_before <text> <needle-a> <needle-b> <label>: a must appear before b
  local a b
  a="$(grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1)"
  b="$(grep -nF -- "$3" <<<"$1" | head -1 | cut -d: -f1)"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    echo "PASS: $4"; ((pass++))
  else
    echo "FAIL: $4 -- [$2]@${a:-none} is not before [$3]@${b:-none}"; ((fail++))
  fi
}

recipe_of() {
  # recipe_of <target-name>: print the tab-indented body of a target.
  awk -v t="^$1:" '
    $0 ~ t { inr = 1; next }
    inr && /^\t/ { print; next }
    inr { exit }
  ' "$MAKEFILE"
}

# ---------------------------------------------------------------------
# Block 1: the guard is defined once and used by both destructive paths.
# ---------------------------------------------------------------------
static_test() {
  # $(BASH_BIN), not a bare `bash`: the probe runs immediately before the
  # destructive half of the cutover, on a run that may already have removed
  # Homebrew's bash formula (issue #37).
  ok "$(grep -q '^MISE_REACHABLE *= *\$(BASH_BIN) -lc ' "$MAKEFILE" && echo 0 || echo 1)" \
    "MISE_REACHABLE is defined as a shared probe"
  ok "$(grep -q "^MISE_REACHABLE *=.*command -v" "$MAKEFILE" && echo 0 || echo 1)" \
    "MISE_REACHABLE probes for the mise binary"

  local install_recipe update_recipe
  install_recipe="$(recipe_of install)"
  update_recipe="$(recipe_of update)"

  ok "$([[ -n "$install_recipe" && -n "$update_recipe" ]] && echo 0 || echo 1)" \
    "both recipes are non-empty"

  # Both destructive paths gate on the SAME probe.
  ok_contains "$install_recipe" '$(MISE_REACHABLE)' \
    "install gates the inline version-managers purge on MISE_REACHABLE"
  ok_contains "$update_recipe" '$(MISE_REACHABLE)' \
    "update gates its removal loops on MISE_REACHABLE"

  # In `install` the guard precedes the destructive call, not follows it.
  ok_before "$install_recipe" '$(MISE_REACHABLE)' '--mode=purge' \
    "install evaluates the guard before any purge invocation"

  # The tier is named through $(VM_TIER), so renaming the profile cannot
  # leave the inline purge silently pointing at a directory that no longer
  # exists.
  ok_contains "$install_recipe" '$(VM_TIER)' \
    "install names the purge tier through VM_TIER"
  ok "$(grep -q '^VM_PROFILE  *:= *version-managers$' "$MAKEFILE" && echo 0 || echo 1)" \
    "VM_PROFILE names the version-managers profile"
  ok "$(grep -q '^VM_TIER  *:= *profiles/\$(VM_PROFILE)$' "$MAKEFILE" && echo 0 || echo 1)" \
    "VM_TIER derives the tier root from VM_PROFILE"
}

# ---------------------------------------------------------------------
# Block 2: behavioral -- drive the real `make install`.
# ---------------------------------------------------------------------

# A stub `brew` that never reports anything installed and never fails a
# bundle. Passed as BREW= AND shimmed onto PATH (defence in depth).
write_stub_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  bundle) exit 0 ;;
  list)   exit 1 ;;   # nothing is ever "installed"
  *)      exit 0 ;;
esac
STUB
  chmod +x "$1"
}

# A stub versions_setup.sh that SUCCEEDS unconditionally. This is what
# makes the test about the explicit guard rather than about `set -e`:
# with the real script, a missing mise would abort the recipe on its own.
write_stub_versions_setup() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "stub-versions-setup: ${1:-full}"
exit 0
STUB
  chmod +x "$1"
}

# Synthetic repo: the real Makefile, the scripts `install` invokes, and a
# `version-managers` profile whose Brewfile installs mise, whose
# post_install calls the stub versions_setup.sh, and whose `[profile]
# purge` array removes asdf (so the runner prints its banner and the test
# can see it).
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" "$root/profiles/version-managers" "$root/bin"
  cp "$MAKEFILE" "$root/Makefile"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/apply_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/require_dasel_on_path.sh" \
     "$REPO_ROOT/scripts/remove_runner.sh" \
     "$root/scripts/"
  write_stub_versions_setup "$root/scripts/versions_setup.sh"
  write_stub_brew "$root/bin/brew"
  printf 'brew "mise"\n' > "$root/profiles/version-managers/Brewfile"
  {
    printf '[profile]\n'
    printf 'post_install = ["scripts/versions_setup.sh full"]\n'
    printf 'purge = ["brew:asdf"]\n'
  } > "$root/profiles/version-managers/config.toml"
  echo "$root"
}

PURGE_BANNER="==> Applying RemoveAndPurge: profiles/version-managers"

run_install() {
  # run_install <mise-value> -> sets RUN_OUT / RUN_RC
  local mise="$1" root host_dir
  root="$(make_repo)"
  # The host tier selects the version-managers profile, so the install
  # loop reaches the tier that owns the cutover.
  host_dir="$(mktemp -d)"
  printf 'profiles = ["version-managers"]\n' > "$host_dir/config.toml"
  RUN_OUT="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" \
    make install BREW="$root/bin/brew" MISE="$mise" 2>&1)"; RUN_RC=$?
  rm -rf "$root" "$host_dir"
}

behavioral_test() {
  # mise unreachable -> purge held back, warning, non-zero exit.
  run_install "mise-that-does-not-exist-$$"
  ok_rc_nonzero "$RUN_RC" "mise unreachable: run exits non-zero"
  ok_absent "$RUN_OUT" "$PURGE_BANNER" \
    "mise unreachable: the asdf/direnv purge does not run"
  ok_contains "$RUN_OUT" "WARNING: mise is not reachable" \
    "mise unreachable: the run warns"
  ok_contains "$RUN_OUT" "Skipped the asdf/direnv removal" \
    "mise unreachable: the end-of-run summary names the skip"
  ok_absent "$RUN_OUT" "All tiers applied." \
    "mise unreachable: the success message is suppressed"

  # mise reachable -> purge runs, clean exit. `true` is a real binary on
  # PATH, so `command -v` finds it; the stub versions_setup never calls it.
  run_install "true"
  ok "$RUN_RC" "mise reachable: run exits 0"
  ok_contains "$RUN_OUT" "$PURGE_BANNER" \
    "mise reachable: the asdf/direnv purge runs"
  ok_absent "$RUN_OUT" "WARNING: mise is not reachable" \
    "mise reachable: no skip warning"
  ok_contains "$RUN_OUT" "All tiers applied." \
    "mise reachable: prints the success message"
}

echo "=== Block 1: the guard is shared and precedes the purge ==="
static_test
echo "=== Block 2: make install with mise reachable / unreachable ==="
behavioral_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All install-cutover-guard tests passed."
  exit 0
fi
echo "Some install-cutover-guard tests FAILED."
exit 1
