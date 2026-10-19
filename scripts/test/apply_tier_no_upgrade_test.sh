#!/usr/bin/env bash

# Tests that scripts/apply_tier.sh never upgrades installed packages: its
# `brew bundle` call carries `--no-upgrade`, so applying a tier installs
# absent entries only and upgrading stays with `make update`.
#
# The test stands up a synthetic repo whose core tier has a Brewfile, stubs
# `brew` through the BREW env var with a script that logs each invocation's
# arguments, runs apply_tier.sh on the core tier, and inspects the logged
# `bundle` invocation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok_rc() {
  # ok_rc <actual_rc> <label>
  if [[ "$1" == "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2 (rc=$1 want 0)"; ((fail++)); fi
}
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- missing [$2] in [$1]"; ((fail++)); fi
}

root="$(mktemp -d)"
host_dir="$(mktemp -d)"
trap 'rm -rf "$root" "$host_dir"' EXIT

mkdir -p "$root/scripts" "$root/default"
cp "$REPO_ROOT/scripts/config_common.sh" \
   "$REPO_ROOT/scripts/apply_tier.sh" \
   "$REPO_ROOT/scripts/install_filter.sh" \
   "$root/scripts/"
printf 'brew "pkg_core"\n' > "$root/default/Brewfile"

# A stub `brew` that records one line of arguments per call and succeeds.
brew_log="$root/brew.log"
brew_stub="$root/stub_brew.sh"
cat > "$brew_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$brew_log"
exit 0
STUB
chmod +x "$brew_stub"

echo "=== apply_tier.sh passes --no-upgrade to brew bundle ==="
out="$(MACOS_SETUP_HOST_DIR="$host_dir" BREW="$brew_stub" \
  "$root/scripts/apply_tier.sh" "$root/default" 2>&1)"; rc=$?
ok_rc "$rc" "apply_tier.sh on the core tier exits 0"

bundle_call="$(grep -E '^bundle( |$)' "$brew_log" 2>/dev/null)"
ok_contains "$bundle_call" "bundle" "brew bundle was invoked (output: $out)"
ok_contains "$bundle_call" "--no-upgrade" "brew bundle invocation carries --no-upgrade"

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All apply-tier no-upgrade tests passed."
  exit 0
fi
echo "Some apply-tier no-upgrade tests FAILED."
exit 1
