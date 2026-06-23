#!/usr/bin/env bash

# Tests for the install-loop failure accumulation (issue #163).
#
# Before #163, `make install` aborted the whole run on the first
# `brew bundle` failure (the `[ $rc -eq 0 ] || exit $rc` guard), so a
# single failing cask left every later slot unapplied. The fix makes
# the loop attempt EVERY slot, collect per-slot `brew bundle` failures,
# print a summary at the end, and exit non-zero iff any slot failed.
#
# These tests stand up a synthetic repo containing the real Makefile
# and the handful of scripts the `install` target invokes, point the
# external host tier at an EMPTY (but present) temp dir so seeding and
# profile resolution no-op, and drive `make install` with a stub `brew`
# that fails for exactly one slot. They assert:
#   - every slot's `brew bundle` is attempted even though an earlier
#     slot failed (no early abort)
#   - the run exits non-zero when a slot failed
#   - the end-of-run summary names the failed slot
#   - a clean run (stub never fails) exits 0 with the success message
#
# The host tier lives OUTSIDE the repo (see host_tier_dir in
# config_common.sh). Pointing MACOS_SETUP_HOST_DIR at a pre-existing
# empty temp dir makes seed_host_tier.sh a no-op (dir present) and
# get_profiles return nothing (no `profiles` file), so the loop
# exercises only the default tier — exactly the path that carried the
# old abort guard.

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

# Build a synthetic repo with the real Makefile + the scripts the
# install target touches, plus three default-tier Install slots whose
# basenames match NONE of the install loop's `case` post-install
# actions (so the case falls through harmlessly).
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" "$root/RemoveAndPurge"
  cp "$REPO_ROOT/Makefile" "$root/Makefile"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$root/scripts/"
  # Three slots, sorted: alpha, beta, gamma. The stub brew keys off
  # the bundle file's content to decide which slot to fail.
  printf 'brew "pkg_alpha"\n' > "$root/Install/90-Install.alpha"
  printf 'brew "pkg_beta"\n'  > "$root/Install/91-Install.beta"
  printf 'brew "pkg_gamma"\n' > "$root/Install/92-Install.gamma"
  echo "$root"
}

# A stub `brew` that:
#   - logs every `bundle --file=<f>` invocation's resolved package line
#     to $BREW_LOG (so the test can assert which slots were attempted)
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

# ---------------------------------------------------------------------
# Block 1: one slot fails -> loop continues, run exits non-zero, summary
# names the failed slot, every slot was attempted.
# ---------------------------------------------------------------------
one_failure_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(mktemp -d)"      # present but empty -> seeding/profiles no-op
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" FAIL_PKG="pkg_beta" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" nonzero "one failure: run exits non-zero"
  ok_contains "$out" "Install/91-Install.beta" "one failure: summary names the failed slot"
  ok_contains "$out" "The following Install slots failed" "one failure: prints a failure summary header"

  # Every slot must have been attempted (no early abort): the stub logged
  # bundle:pkg_alpha, bundle:pkg_beta, bundle:pkg_gamma.
  local logged
  logged="$(paste -sd, - < "$brew_log")"
  ok "$logged" "bundle:pkg_alpha,bundle:pkg_beta,bundle:pkg_gamma" \
    "one failure: every slot attempted despite the middle slot failing"

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 2: the LAST slot's failure is still reported (proves the
# accumulator survives to the end and the success message is suppressed).
# ---------------------------------------------------------------------
last_failure_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" FAIL_PKG="pkg_gamma" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" nonzero "last-slot failure: run exits non-zero"
  ok_contains "$out" "Install/92-Install.gamma" "last-slot failure: summary names the last slot"
  if grep -qF "All Install files applied." <<<"$out"; then
    echo "FAIL: last-slot failure: success message must be suppressed"; ((fail++))
  else
    echo "PASS: last-slot failure: success message suppressed"; ((pass++))
  fi

  rm -rf "$root" "$host_dir" "$brew_log"
}

# ---------------------------------------------------------------------
# Block 3: no slot fails -> exit 0, success message, no summary.
# ---------------------------------------------------------------------
clean_run_test() {
  local root host_dir brew_stub brew_log out rc
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  brew_log="$(mktemp)"

  out="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW_LOG="$brew_log" \
    make install BREW="$brew_stub" 2>&1)"; rc=$?

  ok_rc "$rc" 0 "clean run: exits 0"
  ok_contains "$out" "All Install files applied." "clean run: prints success message"
  if grep -qF "The following Install slots failed" <<<"$out"; then
    echo "FAIL: clean run: must not print a failure summary"; ((fail++))
  else
    echo "PASS: clean run: no failure summary"; ((pass++))
  fi

  rm -rf "$root" "$host_dir" "$brew_log"
}

echo "=== one-failure (middle slot) test ==="
one_failure_test
echo "=== last-slot failure test ==="
last_failure_test
echo "=== clean-run test ==="
clean_run_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All install-failure-accumulation tests passed."
  exit 0
fi
echo "Some install-failure-accumulation tests FAILED."
exit 1
