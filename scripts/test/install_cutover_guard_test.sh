#!/usr/bin/env bash

# Tests for the mise-reachability guard on `make install`'s inline
# slot-04 RemoveAndPurge (the asdf -> mise cutover).
#
# `make install` is the one place the install path removes anything: the
# `04-Install.versionmanagers` case in the batch loop applies slot 04's
# RemoveAndPurge inline, which uninstalls asdf and direnv. That removal
# must never run on a host where mise is not actually reachable at that
# moment -- a host left with neither is strictly worse off than a host
# carrying both.
#
# `set -e` alone is NOT the guard being tested here. The recipe does run
# under .ONESHELL + `set -euo pipefail`, and versions_setup.sh does exit
# non-zero when mise is missing, so the run would in practice abort before
# the purge lines. That protection is incidental: it lives in another
# file, and a refactor that moves the purge or reorders require_mise would
# reopen the hazard silently. These tests pin the EXPLICIT guard --
# $(MISE_REACHABLE), evaluated at the destructive call site -- so removing
# it fails the suite.
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
# Block 2 shims a stub `brew` onto PATH, not just into the BREW make
# variable: scripts/remove_runner.sh invokes `brew` by bare name, so
# without the shim a test run would drive the REAL brew against the
# host's real asdf.

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
  ok "$(grep -q '^MISE_REACHABLE *= *bash -lc ' "$MAKEFILE" && echo 0 || echo 1)" \
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
    "install gates the inline slot-04 purge on MISE_REACHABLE"
  ok_contains "$update_recipe" '$(MISE_REACHABLE)' \
    "update gates its removal loops on MISE_REACHABLE"

  # In `install` the guard precedes the destructive call, not follows it.
  ok_before "$install_recipe" '$(MISE_REACHABLE)' '--mode=purge' \
    "install evaluates the guard before any purge invocation"

  # The purge slot is named through $(VM_PURGE), so a rename cannot leave
  # the inline purge silently pointing at a file that no longer exists.
  ok_contains "$install_recipe" 'vmp="$(VM_PURGE)"' \
    "install names the purge slot through VM_PURGE"
  ok "$(grep -q '^VM_PURGE  *:= *04-RemoveAndPurge\.versionmanagers$' "$MAKEFILE" && echo 0 || echo 1)" \
    "VM_PURGE names the version-manager RemoveAndPurge slot"
}

# ---------------------------------------------------------------------
# Block 2: behavioral -- drive the real `make install`.
# ---------------------------------------------------------------------

# A stub `brew` that never reports anything installed and never fails a
# bundle. Shimmed onto PATH (bare-name callers) AND passed as BREW=.
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

# Synthetic repo: the real Makefile, the scripts `install` invokes, one
# slot-04 Install file and one slot-04 RemoveAndPurge file with an active
# directive (so the runner prints its banner and the test can see it).
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" "$root/RemoveAndPurge" "$root/bin"
  cp "$MAKEFILE" "$root/Makefile"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/require_dasel_on_path.sh" \
     "$REPO_ROOT/scripts/remove_runner.sh" \
     "$root/scripts/"
  write_stub_versions_setup "$root/scripts/versions_setup.sh"
  write_stub_brew "$root/bin/brew"
  printf 'brew "mise"\n' > "$root/Install/04-Install.versionmanagers"
  printf "# header\nbrew 'asdf'\n" > "$root/RemoveAndPurge/04-RemoveAndPurge.versionmanagers"
  echo "$root"
}

PURGE_BANNER="==> Applying global RemoveAndPurge: RemoveAndPurge/04-RemoveAndPurge.versionmanagers"

run_install() {
  # run_install <mise-value> -> sets RUN_OUT / RUN_RC
  local mise="$1" root host_dir
  root="$(make_repo)"
  host_dir="$(mktemp -d)"   # present but empty -> seeding/profiles no-op
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
  ok_absent "$RUN_OUT" "All Install files applied." \
    "mise unreachable: the success message is suppressed"

  # mise reachable -> purge runs, clean exit. `true` is a real binary on
  # PATH, so `command -v` finds it; the stub versions_setup never calls it.
  run_install "true"
  ok "$RUN_RC" "mise reachable: run exits 0"
  ok_contains "$RUN_OUT" "$PURGE_BANNER" \
    "mise reachable: the asdf/direnv purge runs"
  ok_absent "$RUN_OUT" "WARNING: mise is not reachable" \
    "mise reachable: no skip warning"
  ok_contains "$RUN_OUT" "All Install files applied." \
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
