#!/bin/bash

# Own the scheduled `make update` LaunchAgent, com.macos-setup.update:
# validate the [cron.update] table, expand its keys to days, write and
# load the plist, remove the legacy daily and weekly plists, and print the
# lines `make schedule-list` shows.
#
# Usage:
#   schedule_update.sh install
#       Build the plist from [cron.update], remove the legacy plists,
#       then install and load the new one. Any error in the table fails
#       before a plist is written or removed.
#   schedule_update.sh remove-legacy
#       Boot out and delete the legacy plists that are present.
#   schedule_update.sh list [<plist-name>...]
#       Print a status line for com.macos-setup.update, one for each legacy
#       plist that is present, and one for each named plist under
#       LAUNCH_AGENTS_DIR.
#
# [cron.update] maps a set of days to an `HH:MM` run time:
#
#   daily      every day
#   weekdays   Mon-Fri
#   weekend    Sat, Sun
#   monday ... sunday   that one day
#
# A day no key covers gets no run. A day two keys cover, an unknown key,
# a malformed time, and a profile config.toml that defines the table are
# each an error.
#
# The Makefile passes LAUNCH_AGENTS_DIR, LAUNCHAGENT_LOG_DIR, and
# LAUNCHAGENT_RUNNER; each defaults to the path the Makefile uses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/config_common.sh"

PLIST_BUDDY=/usr/libexec/PlistBuddy
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LAUNCHAGENT_LOG_DIR="${LAUNCHAGENT_LOG_DIR:-$HOME/Library/Logs/macos-setup}"
LAUNCHAGENT_RUNNER="${LAUNCHAGENT_RUNNER:-$HOME/.zsh-shared/launchagent_runner}"

LABEL=com.macos-setup.update
JOB=macos-setup-update
LEGACY_LABELS=(com.macos-setup.daily-update com.macos-setup.weekly-update)

# launchd numbers weekdays from Sunday = 0; plist entries and printed
# schedules run Monday first.
DAY_ORDER=(1 2 3 4 5 6 0)
TIME_RE='^([01][0-9]|2[0-3]):[0-5][0-9]$'

# Filled by resolve_schedule. DAY_TIME holds each day's run time and
# DAY_KEY the key that set it, both indexed by launchd weekday;
# DAILY_ONLY is non-empty when the table's one key is `daily`.
DAY_TIME=()
DAY_KEY=()
DAILY_ONLY=""

# The install staging directory, global so the EXIT trap can still read it
# once install has returned.
STAGING=""

err() {
    echo "Error: $*" >&2
}

# Print the three-letter name of a launchd weekday. launchd also reads 7
# as Sunday, and a plist read back from disk may carry it.
day_abbrev() {
    case "$1" in
        0|7) echo Sun ;; 1) echo Mon ;; 2) echo Tue ;; 3) echo Wed ;;
        4) echo Thu ;; 5) echo Fri ;; 6) echo Sat ;;
    esac
}

# Print the full name of a launchd weekday, 0 (Sunday) through 6; nothing
# for any other value.
day_name() {
    case "$1" in
        0) echo Sunday ;; 1) echo Monday ;; 2) echo Tuesday ;; 3) echo Wednesday ;;
        4) echo Thursday ;; 5) echo Friday ;; 6) echo Saturday ;;
    esac
}

# Print the launchd weekdays a [cron.update] key covers; nothing for an
# unknown key.
key_days() {
    case "$1" in
        daily)     echo 1 2 3 4 5 6 0 ;;
        weekdays)  echo 1 2 3 4 5 ;;
        weekend)   echo 6 0 ;;
        monday)    echo 1 ;;
        tuesday)   echo 2 ;;
        wednesday) echo 3 ;;
        thursday)  echo 4 ;;
        friday)    echo 5 ;;
        saturday)  echo 6 ;;
        sunday)    echo 0 ;;
    esac
}

# Fail, naming the file, when any profile's config.toml defines
# [cron.update]: the table schedules the whole host, so only the host tier
# and default/ may carry it. Also fails when reading a profile's table
# fails, leaving read_toml_table's report on stderr.
check_profiles() {
    local toml rc
    for toml in "$REPO_ROOT"/profiles/*/config.toml; do
        [[ -f "$toml" ]] || continue
        rc=0
        read_toml_table "$toml" cron.update >/dev/null || rc=$?
        case $rc in
            0)
                err "$toml defines [cron.update]; the table belongs in the host tier's config.toml or default/config.toml."
                return 1
                ;;
            1) ;;
            *) return 1 ;;
        esac
    done
}

# Read [cron.update] and fill DAY_TIME, DAY_KEY, and DAILY_ONLY, or fail
# naming the offending key, value, or day.
resolve_schedule() {
    local table line key value days day
    table="$(resolve_host_or_default_table "$REPO_ROOT" cron.update)" || return 1
    if [[ -z "$table" ]]; then
        err "no [cron.update] table schedules a day; set one in the host tier's config.toml or default/config.toml."
        return 1
    fi

    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        days="$(key_days "$key")"
        if [[ -z "$days" ]]; then
            err "unknown [cron.update] key '$key' (want daily, weekdays, weekend, or monday through sunday)."
            return 1
        fi
        if [[ ! "$value" =~ $TIME_RE ]]; then
            err "malformed [cron.update] time '$value' for key '$key' (want HH:MM, 24-hour)."
            return 1
        fi
        for day in $days; do
            if [[ -n "${DAY_TIME[$day]:-}" ]]; then
                err "$(day_name "$day") is covered by both [cron.update] keys '${DAY_KEY[$day]}' and '$key'."
                return 1
            fi
            DAY_TIME[day]="$value"
            DAY_KEY[day]="$key"
        done
        # `daily` covers every day, so any other key has already failed as
        # an overlap: a table holding `daily` holds nothing else.
        [[ "$key" == daily ]] && DAILY_ONLY=1
    done <<<"$table"
    return 0
}

# Write the update plist to the given path from DAY_TIME and DAILY_ONLY,
# which resolve_schedule must already have filled.
# Args: plist, mailto (empty for log only)
write_plist() {
    local plist="$1" mailto="$2"
    local i=0 day time

    "$PLIST_BUDDY" -c "Clear dict" "$plist" >/dev/null
    "$PLIST_BUDDY" -c "Add :Label string $LABEL" "$plist"
    "$PLIST_BUDDY" -c "Add :ProgramArguments array" "$plist"
    "$PLIST_BUDDY" -c "Add :ProgramArguments:0 string $LAUNCHAGENT_RUNNER" "$plist"
    "$PLIST_BUDDY" -c "Add :ProgramArguments:1 string $JOB" "$plist"
    if [[ -n "$mailto" ]]; then
        "$PLIST_BUDDY" -c "Add :ProgramArguments:2 string --mail" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:3 string $mailto" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:4 string macos-setup update" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:5 string --" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:6 string make" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:7 string update" "$plist"
    else
        "$PLIST_BUDDY" -c "Add :ProgramArguments:2 string --" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:3 string make" "$plist"
        "$PLIST_BUDDY" -c "Add :ProgramArguments:4 string update" "$plist"
    fi

    "$PLIST_BUDDY" -c "Add :StartCalendarInterval array" "$plist"
    for day in "${DAY_ORDER[@]}"; do
        time="${DAY_TIME[$day]:-}"
        [[ -n "$time" ]] || continue
        "$PLIST_BUDDY" -c "Add :StartCalendarInterval:$i dict" "$plist"
        if [[ -z "$DAILY_ONLY" ]]; then
            "$PLIST_BUDDY" -c "Add :StartCalendarInterval:$i:Weekday integer $day" "$plist"
        fi
        "$PLIST_BUDDY" -c "Add :StartCalendarInterval:$i:Hour integer $((10#${time%%:*}))" "$plist"
        "$PLIST_BUDDY" -c "Add :StartCalendarInterval:$i:Minute integer $((10#${time##*:}))" "$plist"
        i=$((i + 1))
        # One entry with no Weekday fires every day.
        [[ -z "$DAILY_ONLY" ]] || break
    done

    "$PLIST_BUDDY" -c "Add :EnvironmentVariables dict" "$plist"
    "$PLIST_BUDDY" -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$plist"
}

# Boot out and delete each legacy plist present under LAUNCH_AGENTS_DIR,
# printing a line for each one removed.
remove_legacy() {
    local label plist
    for label in "${LEGACY_LABELS[@]}"; do
        plist="$LAUNCH_AGENTS_DIR/$label.plist"
        [[ -f "$plist" ]] || continue
        launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "Removed legacy $label"
    done
}

# Run the install subcommand. Exits the script, rather than returning, on
# any failure.
install() {
    local mailto plist
    check_profiles || exit 1
    resolve_schedule || exit 1
    mailto="$("$SCRIPT_DIR/resolve_mailto.sh")" || exit 1

    STAGING="$(mktemp -d)"
    trap 'rm -rf "$STAGING"' EXIT
    write_plist "$STAGING/$LABEL.plist" "$mailto"

    echo "Setting up the update LaunchAgent: $(schedule_text "$STAGING/$LABEL.plist")"
    if [[ -n "$mailto" ]]; then
        echo "Email notifications enabled: $mailto"
    else
        echo "No mailto configured — output to log only"
    fi

    mkdir -p "$LAUNCH_AGENTS_DIR" "$LAUNCHAGENT_LOG_DIR"
    remove_legacy
    plist="$LAUNCH_AGENTS_DIR/$LABEL.plist"
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    cp "$STAGING/$LABEL.plist" "$plist"
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "Update LaunchAgent installed and loaded: $plist"
    echo "Logs: $LAUNCHAGENT_LOG_DIR/$JOB.log"
}

# Print a plist's StartCalendarInterval as text: one `<Day> HH:MM` per
# entry with a Weekday, `Daily at HH:MM` for one without, joined by
# ", ", or `At login` when it has none. The interval may be a single dict
# or an array of them.
schedule_text() {
    local plist="$1"
    local entries=() entry hour minute weekday text="" i=0

    # Test for the array first: PlistBuddy reads a non-numeric index into
    # an array, so `:StartCalendarInterval:Hour` succeeds on both forms.
    while "$PLIST_BUDDY" -c "Print :StartCalendarInterval:$i" "$plist" >/dev/null 2>&1; do
        entries+=(":StartCalendarInterval:$i")
        i=$((i + 1))
    done
    if [[ ${#entries[@]} -eq 0 ]] \
        && "$PLIST_BUDDY" -c "Print :StartCalendarInterval:Hour" "$plist" >/dev/null 2>&1; then
        entries=(":StartCalendarInterval")
    fi
    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "At login"
        return 0
    fi

    for entry in "${entries[@]}"; do
        hour="$("$PLIST_BUDDY" -c "Print $entry:Hour" "$plist" 2>/dev/null || echo 0)"
        minute="$("$PLIST_BUDDY" -c "Print $entry:Minute" "$plist" 2>/dev/null || echo 0)"
        weekday="$("$PLIST_BUDDY" -c "Print $entry:Weekday" "$plist" 2>/dev/null || true)"
        [[ -z "$text" ]] || text="$text, "
        if [[ -n "$weekday" ]]; then
            text="$text$(day_abbrev "$weekday") $(printf '%02d:%02d' "$hour" "$minute")"
        else
            text="${text}Daily at $(printf '%02d:%02d' "$hour" "$minute")"
        fi
    done
    echo "$text"
}

# Print one schedule-list line for a plist name under LAUNCH_AGENTS_DIR.
# Args: plist-name, suffix (appended to an installed plist's line)
describe() {
    local name="$1" suffix="${2:-}"
    local label="${name%.plist}" plist="$LAUNCH_AGENTS_DIR/$1"
    local status prog email mailto

    if [[ ! -f "$plist" ]]; then
        echo "  $label: not installed"
        return 0
    fi
    if launchctl list "$label" >/dev/null 2>&1; then
        status="loaded"
    else
        status="installed but not loaded"
    fi

    prog="$("$PLIST_BUDDY" -c "Print :ProgramArguments:0" "$plist" 2>/dev/null || true)"
    if [[ "$prog" == *launchagent_runner* ]]; then
        if [[ "$("$PLIST_BUDDY" -c "Print :ProgramArguments:2" "$plist" 2>/dev/null || true)" == "--mail" ]]; then
            mailto="$("$PLIST_BUDDY" -c "Print :ProgramArguments:3" "$plist" 2>/dev/null || true)"
            email="email to $mailto"
        else
            email="no email (log only)"
        fi
    elif [[ "$prog" == *mail_wrapper* ]]; then
        mailto="$("$PLIST_BUDDY" -c "Print :ProgramArguments:1" "$plist" 2>/dev/null || true)"
        email="email to $mailto (legacy plist; re-run make schedule-update to upgrade)"
    else
        email="no email (log only)"
    fi

    echo "  $label: $status | $(schedule_text "$plist") | $email$suffix"
}

# Run the list subcommand: a line for the update plist, one for each legacy
# plist present, flagged for replacement, then one for each named plist.
# Args: plist-name...
list() {
    local label name
    describe "$LABEL.plist"
    for label in "${LEGACY_LABELS[@]}"; do
        [[ -f "$LAUNCH_AGENTS_DIR/$label.plist" ]] || continue
        describe "$label.plist" " | legacy: run 'make schedule-update' to replace it"
    done
    for name in "$@"; do
        describe "$name"
    done
}

case "${1:-}" in
    install)
        install
        ;;
    remove-legacy)
        remove_legacy
        ;;
    list)
        shift
        list "$@"
        ;;
    *)
        echo "usage: schedule_update.sh install | remove-legacy | list [<plist-name>...]" >&2
        exit 2
        ;;
esac
