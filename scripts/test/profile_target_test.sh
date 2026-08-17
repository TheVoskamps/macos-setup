#!/usr/bin/env bash

# Tests for the `make profile <name> [<name>...]` target (issue #33), the
# replacement for the per-slot named targets and the 40 hardcoded alias
# lines the numbered-slot convention needed.
#
# The target's contract, and what each block below pins:
#
#   1. VALIDATION RUNS BEFORE THE APPLY LOOP. A typo anywhere in the list
#      aborts with exit 2 and applies NOTHING — a half-applied run from a
#      misspelled fifth name is the failure this ordering prevents.
#   2. NO ARGUMENTS is a usage error (exit 2) naming the known profiles.
#   3. PROFILES APPLY IN THE ORDER GIVEN, not sorted and not in the host's
#      configured order.
#   4. THE APPLY LOOP IS FAILURE-TOLERANT WITH AN END-OF-RUN SUMMARY,
#      matching `make install`. A bare `for` loop returns only the last
#      iteration's status, so a mid-list failure would be silently
#      swallowed — worse than the behavior it replaced.
#   5. A NEW PROFILE NEEDS NO MAKEFILE EDIT. The known-profile list is a
#      directory glob, so creating profiles/<new>/ makes it immediately
#      valid and appliable.
#
# Each block stands up a synthetic repo carrying the real Makefile and the
# scripts the target invokes, with a stub `brew` that fails for a chosen
# package.

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
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}
ok_rc() {
  # ok_rc <actual_rc> <want_rc> <label>
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want $2)"; ((fail++)); fi
}
ok_rc_nonzero() {
  if [[ "$1" != "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2 (rc=0 want non-zero)"; ((fail++)); fi
}

# Synthetic repo: three profiles, each with a Brewfile naming a distinct
# package, and a core tier. No post_install anywhere, so no real setup
# script runs.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" \
           "$root/profiles/alpha" "$root/profiles/beta" "$root/profiles/gamma"
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
  printf 'brew "pkg_core"\n'  > "$root/default/Brewfile"
  printf 'brew "pkg_alpha"\n' > "$root/profiles/alpha/Brewfile"
  printf 'brew "pkg_beta"\n'  > "$root/profiles/beta/Brewfile"
  printf 'brew "pkg_gamma"\n' > "$root/profiles/gamma/Brewfile"
  echo "$root"
}

write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# Stub brew for profile_target_test.sh.
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

# Run `make profile <args...>` against a fresh synthetic repo. Sets
# RUN_OUT, RUN_RC, RUN_LOG (the stub brew's ordered bundle log) and
# RUN_ROOT (left in place for the caller to inspect, then removed here).
run_profile() {
  local fail_pkg="$1"; shift
  local root host_dir brew_stub brew_log
  root="$(make_repo)"
  host_dir="$(mktemp -d)"     # present, no profiles array, no Brewfile
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  RUN_OUT="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" FAIL_PKG="$fail_pkg" \
    make profile "$@" BREW="$brew_stub" 2>&1)"; RUN_RC=$?
  RUN_LOG="$(paste -sd, - < "$brew_log")"

  rm -rf "$root" "$host_dir" "$brew_log"
}

FAIL_HEADER="The following profiles failed"

# ---------------------------------------------------------------------
# Block 1: unknown profile name -> exit 2, nothing applied.
# ---------------------------------------------------------------------
unknown_profile_test() {
  run_profile "" alpha nonexistent gamma
  ok_rc "$RUN_RC" 2 "unknown profile: exits 2"
  ok_contains "$RUN_OUT" "unknown profile(s): nonexistent" \
    "unknown profile: names the offending argument"
  ok_contains "$RUN_OUT" "known profiles:" "unknown profile: lists the known profiles"
  # The critical property: validation ran BEFORE the apply loop, so the
  # VALID names in the list were not half-applied.
  ok "$RUN_LOG" "" "unknown profile: nothing applied (validation precedes apply)"
}

# ---------------------------------------------------------------------
# Block 2: no arguments -> usage error, exit 2.
# ---------------------------------------------------------------------
no_args_test() {
  run_profile ""
  ok_rc "$RUN_RC" 2 "no arguments: exits 2"
  ok_contains "$RUN_OUT" "usage: make profile <name>" "no arguments: prints usage"
  ok "$RUN_LOG" "" "no arguments: nothing applied"
}

# ---------------------------------------------------------------------
# Block 3: profiles apply in the ORDER GIVEN, and the reverse order
# reverses the apply order. Only the named profiles are applied — the
# core tier is NOT (that is `make core` / `make install`).
# ---------------------------------------------------------------------
order_test() {
  run_profile "" gamma alpha beta
  ok_rc "$RUN_RC" 0 "ordered apply: exits 0"
  ok "$RUN_LOG" "bundle:pkg_gamma,bundle:pkg_alpha,bundle:pkg_beta" \
    "ordered apply: applies in the order given, not sorted"

  run_profile "" beta alpha
  ok "$RUN_LOG" "bundle:pkg_beta,bundle:pkg_alpha" \
    "ordered apply: reversing the arguments reverses the apply order"
  ok_absent "$RUN_LOG" "pkg_core" "ordered apply: the core tier is not applied"
}

# ---------------------------------------------------------------------
# Block 4: a mid-list failure does not abort the run; every later profile
# still applies, the summary names the failure, and the run exits
# non-zero.
# ---------------------------------------------------------------------
failure_tolerance_test() {
  run_profile "pkg_alpha" beta alpha gamma
  ok_rc_nonzero "$RUN_RC" "mid-list failure: exits non-zero"
  ok_contains "$RUN_OUT" "$FAIL_HEADER" "mid-list failure: prints the summary header"
  ok_contains "$RUN_OUT" "- alpha" "mid-list failure: summary names the failed profile"
  ok "$RUN_LOG" "bundle:pkg_beta,bundle:pkg_alpha,bundle:pkg_gamma" \
    "mid-list failure: later profiles still applied"

  # The LAST profile failing must also be reported — a bare `for` loop
  # would return its status by accident, so this is the case that does
  # NOT prove the accumulator works; block 1's mid-list case does. This
  # asserts the summary, which only the accumulator can produce.
  run_profile "pkg_gamma" alpha gamma
  ok_rc_nonzero "$RUN_RC" "last-profile failure: exits non-zero"
  ok_contains "$RUN_OUT" "- gamma" "last-profile failure: summary names the failed profile"

  # A clean run prints no summary at all.
  run_profile "" alpha
  ok_rc "$RUN_RC" 0 "clean run: exits 0"
  ok_absent "$RUN_OUT" "$FAIL_HEADER" "clean run: no failure summary"
}

# ---------------------------------------------------------------------
# Block 5: adding profiles/<new>/ requires NO Makefile edit — the
# known-profile list is a directory glob, so a profile created after the
# Makefile was written is immediately valid and appliable.
# ---------------------------------------------------------------------
new_profile_needs_no_makefile_edit_test() {
  local root host_dir brew_stub brew_log out rc log
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  # Created AFTER make_repo copied the (unmodified) Makefile in.
  mkdir -p "$root/profiles/brand-new"
  printf 'brew "pkg_brandnew"\n' > "$root/profiles/brand-new/Brewfile"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" \
    make profile brand-new BREW="$brew_stub" 2>&1)"; rc=$?
  log="$(paste -sd, - < "$brew_log")"

  ok_rc "$rc" 0 "new profile: applies with no Makefile edit"
  ok "$log" "bundle:pkg_brandnew" "new profile: its Brewfile was applied"

  # And `make profiles` lists it.
  out="$(cd "$root" && MACOS_SETUP_HOST_DIR="$host_dir" make profiles 2>&1)"
  ok_contains "$out" "brand-new" "new profile: 'make profiles' lists it"

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 6: a profile's post_install actions run after its Brewfile, in
# declared order, and with the arguments the entry carries.
# ---------------------------------------------------------------------
post_install_order_test() {
  local root host_dir brew_stub brew_log hook_log out rc
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"
  hook_log="$(mktemp)"

  cat > "$root/scripts/hook.sh" <<'EOF'
#!/usr/bin/env bash
echo "hook:$*" >> "$HOOK_LOG"
EOF
  chmod +x "$root/scripts/hook.sh"
  printf '[profile]\npost_install = ["scripts/hook.sh one", "scripts/hook.sh two --flag"]\n' \
    > "$root/profiles/alpha/config.toml"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" HOOK_LOG="$hook_log" \
    make profile alpha BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" 0 "post_install: exits 0"
  ok "$(paste -sd, - < "$hook_log")" "hook:one,hook:two --flag" \
    "post_install: runs in declared order, arguments preserved"
  # The Brewfile came first: its bundle line is in the brew log, and the
  # hook log is non-empty, so both halves ran.
  ok "$(paste -sd, - < "$brew_log")" "bundle:pkg_alpha" \
    "post_install: the tier's Brewfile was applied too"

  rm -rf "$root" "$host_dir" "$brew_log" "$hook_log"
}

echo "=== unknown-profile validation test ==="
unknown_profile_test
echo "=== no-arguments usage test ==="
no_args_test
echo "=== ordered-apply test ==="
order_test
echo "=== failure-tolerance test ==="
failure_tolerance_test
echo "=== new-profile-needs-no-Makefile-edit test ==="
new_profile_needs_no_makefile_edit_test
echo "=== post_install ordering test ==="
post_install_order_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All make-profile target tests passed."
  exit 0
fi
echo "Some make-profile target tests FAILED."
exit 1
