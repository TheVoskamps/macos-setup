#!/usr/bin/env bash

# Tests for the tap-trusting side effect of install_filter.sh (issue #172).
#
# Homebrew 6.0 made `brew trust <tap>` required for third-party (non-
# official) taps. Until a tap is trusted, `brew bundle` silently SKIPS its
# formulae/casks and still exits 0, so the failure-tolerant install loop
# (which keys off brew bundle's exit code) reports success while nothing
# installs. The fix is proactive: install_filter.sh — the single chokepoint
# every `brew bundle` invocation routes through — trusts each `tap`
# directive that SURVIVES filtering into its emitted output, before the
# caller runs `brew bundle`.
#
# These tests stand up a synthetic repo tree in a tmpdir, stub `brew` so it
# records every `trust --tap <name>` invocation to a log file (never
# touching real Homebrew), point the host tier at a temp dir via
# MACOS_SETUP_HOST_DIR, and run install_filter.sh with BREW pointed at the
# stub. They assert:
#   - an emitted `tap` directive gets trusted (one trust call per tap)
#   - a tap whose own line is FILTERED OUT (commented by Uninstall) is
#     NOT trusted; an emitted tap in the same file still is
#   - re-running is idempotent (no error; the stub is invoked the same way
#     each run — `brew trust` itself is a no-op on already-trusted taps)
#   - the emitted file still contains the tap line verbatim (trust is a
#     side effect; the text transform is unchanged)
#
# The host tier lives OUTSIDE the repo (host_tier_dir in config_common.sh);
# every block points MACOS_SETUP_HOST_DIR at a temp dir so no real
# ~/.config path is touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILTER="$REPO_ROOT/scripts/install_filter.sh"

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++)); fi
}
ok_rc() {
  # ok_rc <actual_rc> <want_rc> <label>
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

# A stub `brew` that records `trust --tap <name>` invocations to the file
# named by the BREW_TRUST_LOG env var, one tap name per line. All other
# subcommands are accepted and ignored. Always exits 0.
write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "trust" ]]; then
  # forms: `trust --tap <name>` or `trust <name>`
  shift
  [[ "${1:-}" == "--tap" ]] && shift
  printf '%s\n' "${1:-}" >> "$BREW_TRUST_LOG"
fi
exit 0
STUB
  chmod +x "$path"
}

# Build a minimal synthetic repo: scripts the filter sources, plus an
# Install/Uninstall/RemoveAndPurge tree the caller can populate. Echoes the
# repo root path.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" "$root/RemoveAndPurge"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  echo "$root"
}

# Run install_filter.sh on $root/Install/$slot with a fresh trust log and a
# host tier pointed at a temp dir. Captures:
#   RUN_RC       : filter exit code
#   RUN_OUT_FILE : path the filter printed (the emitted temp file)
#   RUN_EMITTED  : contents of that emitted file
#   TRUST_LOG    : path to the trust log (one trusted tap per line)
run_filter() {
  local root="$1" slot="$2"
  local host_dir brew_stub
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  write_stub_brew "$brew_stub"
  TRUST_LOG="$(mktemp)"

  RUN_OUT_FILE="$(cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" \
    BREW="$brew_stub" BREW_TRUST_LOG="$TRUST_LOG" \
    bash scripts/install_filter.sh "Install/$slot" 2>/dev/null)"; RUN_RC=$?

  RUN_EMITTED=""
  [[ -f "$RUN_OUT_FILE" ]] && RUN_EMITTED="$(cat "$RUN_OUT_FILE")"
  rm -f "$RUN_OUT_FILE"
  rm -rf "$host_dir"
}

trust_count() {
  # trust_count <tap-name> — how many times the stub trusted this tap.
  # `grep -c` exits non-zero on zero matches and still prints 0, so we
  # count matching lines ourselves to get a single clean integer.
  local n
  n="$(grep -Fx -- "$1" "$TRUST_LOG" 2>/dev/null | wc -l)"
  echo "$((n))"
}

# ---------------------------------------------------------------------
# Block 1: an emitted tap gets trusted (one trust call).
# ---------------------------------------------------------------------
emitted_tap_is_trusted_test() {
  local root; root="$(make_repo)"
  cat > "$root/Install/50-Install.example" <<'EOF'
tap 'atlassian/homebrew-acli'
brew 'acli'
EOF
  run_filter "$root" "50-Install.example"
  ok_rc "$RUN_RC" 0 "emitted tap: filter exits 0"
  ok "$(trust_count 'atlassian/homebrew-acli')" "1" "emitted tap: trusted exactly once"
  ok_contains "$RUN_EMITTED" "tap 'atlassian/homebrew-acli'" "emitted tap: tap line still emitted verbatim"
  ok_contains "$RUN_EMITTED" "brew 'acli'" "emitted tap: brew line still emitted"
  rm -rf "$root"
}

# ---------------------------------------------------------------------
# Block 2: a tap whose own line is filtered out is NOT trusted; an
# emitted tap in the same file still is.
#
# install_filter only filters brew/cask/mas identifiers (not `tap`
# directives), so to exercise "tap line not emitted" we comment it out
# directly in the Install file. The tap whose line is a live directive
# must be trusted; the commented-out one must not. We also include a
# brew that IS filtered by Uninstall, to confirm trust keys off the tap
# line's own emission, not off whether a sibling package survived.
# ---------------------------------------------------------------------
filtered_tap_not_trusted_test() {
  local root; root="$(make_repo)"
  cat > "$root/Install/51-Install.example" <<'EOF'
tap 'aws/tap'
# tap 'commented/out'
brew 'awscli'
EOF
  # Uninstall awscli at the same tier so its brew line is filtered out.
  # The `aws/tap` line itself still emits, so it must still be trusted —
  # this is the "trust keys off the tap line, not its packages" case.
  cat > "$root/Uninstall/51-Uninstall.example" <<'EOF'
brew 'awscli'
EOF
  run_filter "$root" "51-Install.example"
  ok_rc "$RUN_RC" 0 "filtered case: filter exits 0"
  ok "$(trust_count 'aws/tap')" "1" "filtered case: emitted tap trusted once"
  ok "$(trust_count 'commented/out')" "0" "filtered case: commented-out tap NOT trusted"
  ok_contains "$RUN_EMITTED" "# filtered: also listed in" "filtered case: awscli was filtered out"
  rm -rf "$root"
}

# ---------------------------------------------------------------------
# Block 3: fully-filtered slot does not spuriously trust.
#
# A slot whose ONLY tap line is commented out (so nothing surviving is a
# `tap` directive) must produce zero trust calls.
# ---------------------------------------------------------------------
fully_commented_tap_not_trusted_test() {
  local root; root="$(make_repo)"
  cat > "$root/Install/52-Install.example" <<'EOF'
# tap 'never/trusted'
brew 'ripgrep'
EOF
  run_filter "$root" "52-Install.example"
  ok_rc "$RUN_RC" 0 "fully-commented: filter exits 0"
  ok "$(wc -l < "$TRUST_LOG" | tr -d ' ')" "0" "fully-commented: zero trust calls"
  rm -rf "$root"
}

# ---------------------------------------------------------------------
# Block 4: idempotent re-run — running twice trusts the tap each run
# without error (brew trust itself is a no-op on already-trusted taps,
# which the stub models by simply accepting every call).
# ---------------------------------------------------------------------
idempotent_rerun_test() {
  local root; root="$(make_repo)"
  cat > "$root/Install/53-Install.example" <<'EOF'
tap 'localstack/tap'
brew 'localstack'
EOF
  run_filter "$root" "53-Install.example"
  local rc1="$RUN_RC" cnt1; cnt1="$(trust_count 'localstack/tap')"
  run_filter "$root" "53-Install.example"
  local rc2="$RUN_RC" cnt2; cnt2="$(trust_count 'localstack/tap')"
  ok_rc "$rc1" 0 "idempotent: first run exits 0"
  ok_rc "$rc2" 0 "idempotent: second run exits 0"
  ok "$cnt1" "1" "idempotent: first run trusts once"
  ok "$cnt2" "1" "idempotent: second run trusts once (fresh log)"
  rm -rf "$root"
}

echo "=== emitted tap is trusted ==="
emitted_tap_is_trusted_test
echo "=== filtered tap not trusted, emitted tap still trusted ==="
filtered_tap_not_trusted_test
echo "=== fully-commented tap not trusted ==="
fully_commented_tap_not_trusted_test
echo "=== idempotent re-run ==="
idempotent_rerun_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All install-filter trust-tap tests passed."
  exit 0
fi
echo "Some install-filter trust-tap tests FAILED."
exit 1
