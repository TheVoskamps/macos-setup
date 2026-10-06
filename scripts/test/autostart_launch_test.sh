#!/usr/bin/env bash

# Tests for scripts/autostart_launch.sh.
#
# The script runs from a synthetic repo tree in a temp dir, so the real
# default/config.toml never feeds the resolved list. HOME and
# MACOS_SETUP_HOST_DIR point at temp dirs, and OPEN points at a stub that
# records its arguments. Apps are planted under ~/Applications, the one
# search directory a test can populate. They assert:
#   - `open -g -a <path>` runs once per resolved app that is found
#   - an excluded app is not opened
#   - a name with no matching .app is warned about and skipped, exit 0
#   - an empty resolved list exits 0 without invoking open
#   - a name cased differently from the bundle is not found, even on a
#     case-insensitive volume

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++))
  fi
}
ok_contains() {
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
ROOT="$SANDBOX/repo"
export HOME="$SANDBOX/home"
export MACOS_SETUP_HOST_DIR="$SANDBOX/host"
OPEN_LOG="$SANDBOX/open.log"
export OPEN="$SANDBOX/open-stub"
mkdir -p "$ROOT/scripts" "$ROOT/default" "$HOME/Applications" "$MACOS_SETUP_HOST_DIR"

cp "$REPO_ROOT/scripts/config_common.sh" "$REPO_ROOT/scripts/autostart_common.sh" \
   "$REPO_ROOT/scripts/autostart_launch.sh" "$ROOT/scripts/"

cat > "$OPEN" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$OPEN_LOG"
STUB
chmod +x "$OPEN"

# Names no real Mac carries, so /Applications and /System/Applications
# never match them.
mkdir -p "$HOME/Applications/MacosSetupTestAlpha.app" \
         "$HOME/Applications/MacosSetupTestExcluded.app"

run_launch() {
  rm -f "$OPEN_LOG"
  RC=0
  OUT="$(/bin/bash "$ROOT/scripts/autostart_launch.sh" 2>&1)" || RC=$?
}

# Empty resolved list.
run_launch
ok "$RC" "0" "empty list exits 0"
ok "$([[ -e "$OPEN_LOG" ]] && echo called)" "" "empty list never invokes open"

printf '[autostart]\napps = ["MacosSetupTestAlpha", "MacosSetupTestMissing"]\n' \
  > "$ROOT/default/config.toml"
cat > "$MACOS_SETUP_HOST_DIR/config.toml" <<'EOF'
[autostart]
apps = ["MacosSetupTestExcluded", "MacosSetupTestAlpha"]
exclude = ["MacosSetupTestExcluded"]
EOF

run_launch
ok "$RC" "0" "a missing app still exits 0"
ok "$(cat "$OPEN_LOG" 2>/dev/null)" "-g -a $HOME/Applications/MacosSetupTestAlpha.app" \
  "open -g -a runs once, for the found app only"
ok_contains "$OUT" "MacosSetupTestMissing" "the missing app is warned about"

# A name cased differently from the bundle does not match it.
printf '[autostart]\napps = ["macossetuptestalpha"]\n' > "$ROOT/default/config.toml"
rm -f "$MACOS_SETUP_HOST_DIR/config.toml"
run_launch
ok "$RC" "0" "a wrongly cased name still exits 0"
ok "$([[ -e "$OPEN_LOG" ]] && echo called)" "" "a wrongly cased name is not opened"
ok_contains "$OUT" "no macossetuptestalpha.app" "the wrongly cased name is warned about"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
