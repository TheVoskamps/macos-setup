#!/usr/bin/env bash

# Tests for scripts/schedule_update.sh and the Makefile targets that call
# it (schedule-update, schedule-list, unschedule-all).
#
# Each case runs against a throwaway repo holding the Makefile,
# schedule_update.sh, config_common.sh, a resolve_mailto.sh stub that
# prints $STUB_MAILTO, and a default/config.toml the case writes. HOME
# and MACOS_SETUP_HOST_DIR point at temp dirs, and a `launchctl` stub that
# records every call sits first on PATH. The cases cover:
#   - key expansion: daily, weekdays, weekend, single days
#   - the host tier's table replacing default/'s, never merged with it
#   - a byte-identical plist on a re-run
#   - the overlap, unknown-key, malformed-time, missing-table, and profile
#     errors, each failing without writing a plist
#   - mailto in ProgramArguments
#   - legacy plist removal by schedule-update and unschedule-all
#   - the schedule-list lines, legacy flag included

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_BUDDY=/usr/libexec/PlistBuddy

pass=0
fail=0
# Pass when got equals want. Args: got, want, case label.
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++))
  fi
}

# Pass when the haystack contains the needle.
has() {
  if [[ "$1" == *"$2"* ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- [$1] lacks [$2]"; ((fail++))
  fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
FAKE_REPO="$SANDBOX/repo"
BINDIR="$SANDBOX/bin"
LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
export HOME="$SANDBOX/home"
export MACOS_SETUP_HOST_DIR="$SANDBOX/host"
export STUB_MAILTO=""
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/com.macos-setup.update.plist"

mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/default" "$BINDIR"
cp "$REPO_ROOT/Makefile" "$FAKE_REPO/"
cp "$REPO_ROOT/scripts/schedule_update.sh" "$REPO_ROOT/scripts/config_common.sh" "$FAKE_REPO/scripts/"
cat > "$FAKE_REPO/scripts/resolve_mailto.sh" <<'STUB'
#!/bin/sh
[ -n "$STUB_MAILTO" ] && echo "$STUB_MAILTO"
exit 0
STUB
chmod +x "$FAKE_REPO/scripts/"*.sh

cat > "$BINDIR/launchctl" <<STUB
#!/usr/bin/env bash
echo "launchctl \$*" >> "$LAUNCHCTL_LOG"
# \`launchctl list <label>\` reports nothing loaded.
[[ "\$1" == list ]] && exit 1
exit 0
STUB
chmod +x "$BINDIR/launchctl"

# Reset the host tier, profiles, agents, and launchctl log; write
# default/config.toml from $1 and, when given, the host tier's from $2.
setup() {
  rm -rf "$MACOS_SETUP_HOST_DIR" "$FAKE_REPO/profiles" "$HOME"
  mkdir -p "$MACOS_SETUP_HOST_DIR" "$HOME"
  : > "$LAUNCHCTL_LOG"
  printf '%s\n' "$1" > "$FAKE_REPO/default/config.toml"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" > "$MACOS_SETUP_HOST_DIR/config.toml"
  fi
}

# Run the script directly; stdout to $SANDBOX/out, stderr to $SANDBOX/err.
run_script() {
  PATH="$BINDIR:$PATH" /bin/bash "$FAKE_REPO/scripts/schedule_update.sh" "$@" \
    >"$SANDBOX/out" 2>"$SANDBOX/err"
}

# Run make targets in the throwaway repo; output goes where run_script's does.
run_make() {
  PATH="$BINDIR:$PATH" make -C "$FAKE_REPO" -s "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
}

# Print a key path of the update plist; prints nothing and fails when the
# key is absent.
print_key() {
  "$PLIST_BUDDY" -c "Print :$1" "$PLIST" 2>/dev/null
}

# Print how many StartCalendarInterval entries the update plist holds.
entry_count() {
  local i=0
  while "$PLIST_BUDDY" -c "Print :StartCalendarInterval:$i" "$PLIST" >/dev/null 2>&1; do
    i=$((i + 1))
  done
  echo "$i"
}

# Print every entry as "<Weekday or ->@<Hour>:<Minute>", space-separated.
entries() {
  local i=0 out="" wd
  while "$PLIST_BUDDY" -c "Print :StartCalendarInterval:$i" "$PLIST" >/dev/null 2>&1; do
    wd="$(print_key "StartCalendarInterval:$i:Weekday" || echo -)"
    out="$out ${wd}@$(print_key "StartCalendarInterval:$i:Hour"):$(print_key "StartCalendarInterval:$i:Minute")"
    i=$((i + 1))
  done
  echo "${out# }"
}

# Write a minimal legacy plist under the given label.
write_legacy() {
  mkdir -p "$AGENTS"
  "$PLIST_BUDDY" -c "Clear dict" "$AGENTS/$1.plist" >/dev/null
  "$PLIST_BUDDY" -c "Add :Label string $1" "$AGENTS/$1.plist"
  "$PLIST_BUDDY" -c "Add :StartCalendarInterval dict" "$AGENTS/$1.plist"
  "$PLIST_BUDDY" -c "Add :StartCalendarInterval:Weekday integer 0" "$AGENTS/$1.plist"
  "$PLIST_BUDDY" -c "Add :StartCalendarInterval:Hour integer 11" "$AGENTS/$1.plist"
  "$PLIST_BUDDY" -c "Add :StartCalendarInterval:Minute integer 0" "$AGENTS/$1.plist"
}

# Expect a failing install that writes no plist and names $1 on stderr.
expect_error() {
  run_script install
  ok "$?" "1" "$2: install exits 1"
  ok "$([[ -e "$PLIST" ]] && echo written)" "" "$2: no plist written"
  has "$(cat "$SANDBOX/err")" "$1" "$2: error names $1"
}

# --- daily alone, via make schedule-update ---
setup '[cron.update]
daily = "04:00"'
run_make schedule-update
ok "$?" "0" "daily: make schedule-update exits 0"
ok "$(print_key Label)" "com.macos-setup.update" "daily: Label"
ok "$(print_key ProgramArguments:0)" "$HOME/.zsh-shared/launchagent_runner" "daily: ProgramArguments[0] is the runner"
ok "$(print_key ProgramArguments:1)" "macos-setup-update" "daily: job name"
ok "$(print_key ProgramArguments:2) $(print_key ProgramArguments:3) $(print_key ProgramArguments:4)" \
  "-- make update" "daily: runs make update, log only"
ok "$(print_key EnvironmentVariables:PATH)" "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "daily: PATH"
ok "$(entries)" "-@4:0" "daily: one entry, no Weekday"
has "$(cat "$LAUNCHCTL_LOG")" "launchctl bootstrap gui/$(id -u) $PLIST" "daily: plist bootstrapped"
has "$(cat "$SANDBOX/out")" "macos-setup-update.log" "daily: names the log"

cp "$PLIST" "$SANDBOX/first.plist"
run_make schedule-update
ok "$(cmp -s "$SANDBOX/first.plist" "$PLIST" && echo same)" "same" "daily: re-run writes a byte-identical plist"

run_make schedule-list
has "$(cat "$SANDBOX/out")" "com.macos-setup.update: installed but not loaded | Daily at 04:00 | no email (log only)" \
  "daily: schedule-list line"
has "$(cat "$SANDBOX/out")" "com.macos-setup.autostart: not installed" "schedule-list still lists the other agents"

# --- host table replaces default's, never merged ---
setup '[cron.update]
daily = "04:00"' '[cron]
mailto = "x@example.com"

[cron.update]
weekdays = "07:00"
saturday = "10:00"
sunday   = "11:30"'
run_script install
ok "$?" "0" "host: install exits 0 (default's daily is not merged in)"
ok "$(entries)" "1@7:0 2@7:0 3@7:0 4@7:0 5@7:0 6@10:0 0@11:30" "host: weekdays + saturday + sunday expand Monday first"

# --- weekend and single days; schedule-list text ---
setup '[cron.update]
monday    = "07:00"
wednesday = "09:00"
friday    = "08:00"
weekend   = "10:15"'
run_script install
ok "$?" "0" "days: install exits 0"
ok "$(entry_count)" "5" "days: one entry per scheduled day"
run_script list
has "$(cat "$SANDBOX/out")" "Mon 07:00, Wed 09:00, Fri 08:00, Sat 10:15, Sun 10:15" "days: list prints the expanded schedule"

# --- mailto ---
setup '[cron.update]
daily = "04:00"'
STUB_MAILTO="me@example.com" run_script install
ok "$(print_key ProgramArguments:2) $(print_key ProgramArguments:3)" "--mail me@example.com" "mailto: --mail recipient"
ok "$(print_key ProgramArguments:4)" "macos-setup update" "mailto: subject"
ok "$(print_key ProgramArguments:5) $(print_key ProgramArguments:6) $(print_key ProgramArguments:7)" "-- make update" "mailto: command"

# --- errors ---
setup '[cron.update]
weekdays = "07:00"
monday   = "08:00"'
expect_error "Monday" "overlap"

setup '[cron.update]
daily  = "04:00"
sunday = "11:00"'
expect_error "Sunday" "daily overlap"

setup '[cron.update]
funday = "07:00"'
expect_error "'funday'" "unknown key"

setup '[cron.update]
monday = "7:00"'
expect_error "'7:00'" "malformed time"

setup '[cron.update]
monday = "24:00"'
expect_error "'24:00'" "out-of-range time"

setup '[cron]
mailto = "x@example.com"'
expect_error "[cron.update]" "no table"

setup '[cron.update]
daily = "04:00"'
mkdir -p "$FAKE_REPO/profiles/web"
printf '[cron.update]\nsunday = "11:00"\n' > "$FAKE_REPO/profiles/web/config.toml"
expect_error "$FAKE_REPO/profiles/web/config.toml" "profile table"

# --- legacy removal by schedule-update ---
setup '[cron.update]
daily = "04:00"'
write_legacy com.macos-setup.daily-update
write_legacy com.macos-setup.weekly-update
run_script list
has "$(cat "$SANDBOX/out")" "com.macos-setup.weekly-update: installed but not loaded | Sun 11:00 | no email (log only) | legacy: run 'make schedule-update' to replace it" \
  "legacy: list flags a legacy plist"
run_make schedule-update
ok "$?" "0" "legacy: schedule-update exits 0"
ok "$(ls "$AGENTS")" "com.macos-setup.update.plist" "legacy: schedule-update deletes both legacy plists"
has "$(cat "$LAUNCHCTL_LOG")" "launchctl bootout gui/$(id -u) $AGENTS/com.macos-setup.daily-update.plist" "legacy: daily booted out"
has "$(cat "$LAUNCHCTL_LOG")" "launchctl bootout gui/$(id -u) $AGENTS/com.macos-setup.weekly-update.plist" "legacy: weekly booted out"

# --- legacy removal by unschedule-all ---
write_legacy com.macos-setup.daily-update
write_legacy com.macos-setup.weekly-update
: > "$LAUNCHCTL_LOG"
run_make unschedule-all
ok "$?" "0" "unschedule-all exits 0"
ok "$(ls "$AGENTS")" "" "unschedule-all deletes the update and both legacy plists"
has "$(cat "$LAUNCHCTL_LOG")" "launchctl bootout gui/$(id -u) $AGENTS/com.macos-setup.weekly-update.plist" "unschedule-all: legacy booted out"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
