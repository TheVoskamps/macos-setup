#!/usr/bin/env bash

# Tests for the install-loop failure accumulation (issue #163, carried
# across the profiles cutover in issue #33).
#
# Before #163, `make install` aborted the whole run on the first
# `brew bundle` failure, so a single failing cask left every later unit
# unapplied. The fix makes the loop attempt EVERY unit, collect the
# failures, print a summary at the end, and exit non-zero iff any failed.
# Issue #33 changed the unit from a numbered Install slot to a TIER (the
# core tier, then each profile the host opts into, then the host tier);
# the accumulation contract is unchanged and is what this file pins.
#
# These tests stand up a synthetic repo containing the real Makefile and
# the scripts the `install` target invokes, point the external host tier
# at a temp dir whose config.toml selects two profiles, and drive
# `make install` with a stub `brew` that fails for exactly one tier. They
# assert:
#   - every tier's `brew bundle` is attempted even though an earlier tier
#     failed (no early abort)
#   - the run exits non-zero when a tier failed
#   - the end-of-run summary names the failed tier
#   - a clean run (stub never fails) exits 0 with the success message

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

# Build a synthetic repo with the real Makefile + the scripts the install
# target touches, plus three tiers that each carry a Brewfile: the core
# tier and two profiles. None declares a post_install action, so no real
# setup script runs.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" \
           "$root/profiles/beta" "$root/profiles/gamma"
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
  printf 'brew "pkg_alpha"\n' > "$root/default/Brewfile"
  printf 'brew "pkg_beta"\n'  > "$root/profiles/beta/Brewfile"
  printf 'brew "pkg_gamma"\n' > "$root/profiles/gamma/Brewfile"
  echo "$root"
}

# The external host tier: present (so seeding no-ops) and selecting both
# profiles in order, with no Brewfile of its own.
make_host_dir() {
  local host_dir; host_dir="$(mktemp -d)"
  printf 'profiles = ["beta", "gamma"]\n' > "$host_dir/config.toml"
  echo "$host_dir"
}

# A stub `brew` that:
#   - logs every `bundle --file=<f>` invocation's resolved package line
#     to $BREW_LOG (so the test can assert which tiers were attempted)
#   - exits 1 when the bundle file mentions the package named in
#     $FAIL_PKG, else exits 0
# Written into the synthetic repo and passed to make via BREW=.
write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# Stub brew for install_failure_accumulation_test.sh.
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

FAIL_HEADER="The following tiers failed"
SUCCESS_MSG="All tiers applied."

# ---------------------------------------------------------------------
# Block 1: one tier fails -> loop continues, run exits non-zero, summary
# names the failed tier, every tier was attempted.
# ---------------------------------------------------------------------
one_failure_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" FAIL_PKG="pkg_beta" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" nonzero "one failure: run exits non-zero"
  ok_contains "$out" "profiles/beta" "one failure: summary names the failed tier"
  ok_contains "$out" "$FAIL_HEADER" "one failure: prints a failure summary header"

  # Every tier must have been attempted (no early abort): the stub logged
  # bundle:pkg_alpha, bundle:pkg_beta, bundle:pkg_gamma.
  local logged
  logged="$(paste -sd, - < "$brew_log")"
  ok "$logged" "bundle:pkg_alpha,bundle:pkg_beta,bundle:pkg_gamma" \
    "one failure: every tier attempted despite the middle tier failing"

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 2: the LAST tier's failure is still reported (proves the
# accumulator survives to the end and the success message is suppressed).
# ---------------------------------------------------------------------
last_failure_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" FAIL_PKG="pkg_gamma" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" nonzero "last-tier failure: run exits non-zero"
  ok_contains "$out" "profiles/gamma" "last-tier failure: summary names the last tier"
  if grep -qF "$SUCCESS_MSG" <<<"$out"; then
    echo "FAIL: last-tier failure: success message must be suppressed"; ((fail++))
  else
    echo "PASS: last-tier failure: success message suppressed"; ((pass++))
  fi

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 3: no tier fails -> exit 0, success message, no summary.
# ---------------------------------------------------------------------
clean_run_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" 0 "clean run: exits 0"
  ok_contains "$out" "$SUCCESS_MSG" "clean run: prints success message"
  if grep -qF "$FAIL_HEADER" <<<"$out"; then
    echo "FAIL: clean run: must not print a failure summary"; ((fail++))
  else
    echo "PASS: clean run: no failure summary"; ((pass++))
  fi

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 4: a FAILING post_install action is tracked the same way a
# failing brew bundle is — reported, not fatal, and it does not stop the
# later tiers. This is what makes the whole run failure-tolerant rather
# than just its brew half.
# ---------------------------------------------------------------------
post_install_failure_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  cat > "$root/scripts/boom.sh" <<'EOF'
#!/usr/bin/env bash
echo "boom: deliberate post_install failure" >&2
exit 1
EOF
  chmod +x "$root/scripts/boom.sh"
  printf '[profile]\npost_install = ["scripts/boom.sh"]\n' \
    > "$root/profiles/beta/config.toml"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" nonzero "post_install failure: run exits non-zero"
  ok_contains "$out" "profiles/beta" "post_install failure: summary names the tier"
  local logged
  logged="$(paste -sd, - < "$brew_log")"
  ok "$logged" "bundle:pkg_alpha,bundle:pkg_beta,bundle:pkg_gamma" \
    "post_install failure: later tiers still applied"

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 5: a post_install entry naming a script that does not exist is
# reported and tracked, not silently skipped. A hook that never runs
# because of a typo is exactly the failure this reports.
# ---------------------------------------------------------------------
missing_post_install_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(make_host_dir)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  printf '[profile]\npost_install = ["scripts/no_such_script.sh"]\n' \
    > "$root/profiles/gamma/config.toml"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" nonzero "missing post_install script: run exits non-zero"
  ok_contains "$out" "not found or not executable" \
    "missing post_install script: says the script is missing"
  ok_contains "$out" "scripts/no_such_script.sh" \
    "missing post_install script: names the script"

  rm -rf "$root" "$host_dir" "$brew_log"
}

echo "=== one-failure (middle tier) test ==="
one_failure_test
echo "=== last-tier failure test ==="
last_failure_test
echo "=== clean-run test ==="
clean_run_test
echo "=== post_install failure test ==="
post_install_failure_test
echo "=== missing post_install script test ==="
missing_post_install_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All install-failure-accumulation tests passed."
  exit 0
fi
echo "Some install-failure-accumulation tests FAILED."
exit 1
