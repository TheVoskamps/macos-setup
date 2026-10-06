#!/usr/bin/env bash

# Tests for scripts/autostart_setup.sh.
#
# HOME and MACOS_SETUP_HOST_DIR point at temp dirs, and a `launchctl`
# stub that records every call sits first on PATH. They assert:
#   - the plist lands at ~/Library/LaunchAgents/com.macos-setup.autostart.plist
#     with the label, RunAtLoad true, the launchagent_runner
#     ProgramArguments, and the PATH environment variable
#   - a second run leaves the plist byte-identical and does not rewrite it
#   - a plist whose content differs is rewritten
#   - launchctl is never invoked

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_BUDDY=/usr/libexec/PlistBuddy

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++))
  fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export MACOS_SETUP_HOST_DIR="$SANDBOX/host"
BINDIR="$SANDBOX/bin"
LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
mkdir -p "$HOME" "$MACOS_SETUP_HOST_DIR" "$BINDIR"

cat > "$BINDIR/launchctl" <<STUB
#!/usr/bin/env bash
echo "launchctl \$*" >> "$LAUNCHCTL_LOG"
STUB
chmod +x "$BINDIR/launchctl"

PLIST="$HOME/Library/LaunchAgents/com.macos-setup.autostart.plist"

run_setup() {
  PATH="$BINDIR:$PATH" /bin/bash "$REPO_ROOT/scripts/autostart_setup.sh" >/dev/null 2>&1
}

print_key() {
  "$PLIST_BUDDY" -c "Print :$1" "$PLIST" 2>/dev/null
}

run_setup
ok "$?" "0" "first run exits 0"
ok "$([[ -f "$PLIST" ]] && echo yes)" "yes" "plist written to ~/Library/LaunchAgents"
ok "$(print_key Label)" "com.macos-setup.autostart" "Label"
ok "$(print_key RunAtLoad)" "true" "RunAtLoad is true"
ok "$(print_key ProgramArguments:0)" "$HOME/.zsh-shared/launchagent_runner" "ProgramArguments[0] is the runner"
ok "$(print_key ProgramArguments:1)" "autostart" "ProgramArguments[1] is the job name"
ok "$(print_key ProgramArguments:2)" "--" "ProgramArguments[2] is --"
ok "$(print_key ProgramArguments:3)" "scripts/autostart_launch.sh" "ProgramArguments[3] is the launch script"
ok "$(print_key ProgramArguments:4)" "" "ProgramArguments has no fifth element"
ok "$(print_key EnvironmentVariables:PATH)" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "EnvironmentVariables:PATH"

# Backdate the plist so a rewrite would show as a changed mtime, then
# run again.
cp "$PLIST" "$SANDBOX/first.plist"
touch -t 200001010000 "$PLIST"
before="$(stat -f '%m %i' "$PLIST")"
run_setup
ok "$?" "0" "second run exits 0"
ok "$(cmp -s "$SANDBOX/first.plist" "$PLIST" && echo same)" "same" "second run leaves the plist byte-identical"
ok "$(stat -f '%m %i' "$PLIST")" "$before" "second run does not rewrite the plist"

# A plist whose content differs is rewritten.
"$PLIST_BUDDY" -c "Set :RunAtLoad false" "$PLIST"
run_setup
ok "$(print_key RunAtLoad)" "true" "a differing plist is rewritten"

ok "$([[ -s "$LAUNCHCTL_LOG" ]] && cat "$LAUNCHCTL_LOG")" "" "launchctl is never invoked"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
