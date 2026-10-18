#!/usr/bin/env bash

# Tests that applying a tier never upgrades installed packages.
#
# scripts/apply_tier.sh runs `brew bundle` on the tier's filtered Brewfile,
# and `brew bundle` upgrades outdated entries unless told not to. Several
# upgrades inside one bundle run collide on Cellar locks and Caskroom
# renames, so the bundle call carries `--no-upgrade` and upgrading is left
# to `make update`.
#
# The test stands up a synthetic repo whose core tier has a Brewfile, stubs
# `brew` through the BREW env var with a script that logs each invocation's
# arguments, runs scripts/apply_tier.sh on that tier, and asserts on the
# logged `bundle` invocation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok_rc() {
  # ok_rc <actual_rc> <label>  (wants 0)
  if [[ "$1" == "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2 (rc=$1 want 0)"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}

# Synthetic repo carrying the scripts apply_tier.sh sources or runs, and a
# core tier with one Brewfile entry.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/apply_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  printf 'brew "pkg_core"\n' > "$root/default/Brewfile"
  echo "$root"
}

# A stub `brew` that appends its arguments, one invocation per line, to the
# log file named by BREW_LOG, and always succeeds.
write_stub_brew() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BREW_LOG"
exit 0
STUB
  chmod +x "$path"
}

# Applying the core tier exits 0, and its logged `brew bundle` call carries
# `--no-upgrade`.
bundle_passes_no_upgrade_test() {
  local root host_dir brew_stub log rc bundle_line
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  brew_stub="$root/scripts/stub_brew.sh"
  log="$root/brew.log"
  : > "$log"
  write_stub_brew "$brew_stub"

  (cd "$root" && \
    MACOS_SETUP_HOST_DIR="$host_dir" BREW="$brew_stub" BREW_LOG="$log" \
    scripts/apply_tier.sh "$root/default" >/dev/null 2>&1)
  rc=$?

  ok_rc "$rc" "apply_tier.sh on the core tier: exits 0"
  bundle_line="$(grep -E '^bundle( |$)' "$log")"
  ok_contains "$bundle_line" "bundle" "apply_tier.sh: brew bundle was invoked"
  ok_contains "$bundle_line" "--no-upgrade" "apply_tier.sh: brew bundle carries --no-upgrade"

  rm -rf "$root" "$host_dir"
}

echo "=== apply_tier.sh brew bundle --no-upgrade ==="
bundle_passes_no_upgrade_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All apply-tier-no-upgrade tests passed."
  exit 0
fi
echo "Some apply-tier-no-upgrade tests FAILED."
exit 1
