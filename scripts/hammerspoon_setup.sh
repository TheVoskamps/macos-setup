#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

# Commands the reload path drives, overridable so tests can stub them.
HS="${HS:-hs}"
PGREP="${PGREP:-pgrep}"
KILLALL="${KILLALL:-killall}"
OPEN="${OPEN:-open}"
# Post-relaunch IPC confirmation is a probe-with-retry loop, not a single
# fixed sleep: a cold launch can take a while to bring its IPC port up, so
# a single 5s sleep + one probe used to false-negative. Instead we poll
# every HS_RELAUNCH_INTERVAL seconds for up to HS_RELAUNCH_TIMEOUT seconds,
# succeeding as soon as a probe passes. Both are env-overridable so tests
# don't have to really wait. HS_RELAUNCH_SETTLE is honored for backward
# compatibility as an alias for the per-probe interval.
HS_RELAUNCH_INTERVAL="${HS_RELAUNCH_INTERVAL:-${HS_RELAUNCH_SETTLE:-1}}"
HS_RELAUNCH_TIMEOUT="${HS_RELAUNCH_TIMEOUT:-15}"

# reload_hammerspoon: apply the freshly-repointed symlinks to a RUNNING
# Hammerspoon, robustly and loudly.
#
# Chicken-and-egg problem (issue #18): hs.ipc's message port is set up by
# `require("hs.ipc")` INSIDE init.lua. When init.lua is broken or has never
# loaded from the current checkout (e.g. a stale symlink), the IPC port is
# down -- but `hs -c "hs.reload()"` IS the IPC path, so the one mechanism
# used to reload is the one that cannot work in exactly the broken state
# where reloading matters most.
#
# Strategy: try IPC first (showing its real error, not swallowing it); on
# failure fall back to an IPC-independent app relaunch (killall + open),
# which re-execs init.lua from the now-correct symlink and brings IPC back
# up; then poll IPC with a read-only liveness probe (retry up to a bounded
# timeout) to confirm it actually came back. If no path works, emit a loud
# warning with the manual-reload instruction and return non-zero rather
# than claiming success.
#
# The caller guards on Hammerspoon actually running, so this never
# launches Hammerspoon on a machine where it was deliberately not running.
reload_hammerspoon() {
    # 1. Try IPC. Do NOT discard stderr -- the real error
    #    ("can't access Hammerspoon message port ...; is it running with
    #    the ipc module loaded?") is the signal the user needs.
    if "$HS" -c "hs.reload()"; then
        echo "Hammerspoon config reloaded (via IPC)"
        return 0
    fi

    echo "IPC reload failed; falling back to relaunching Hammerspoon..."

    # 2. IPC-independent fallback: relaunch the app. A fresh launch
    #    re-execs init.lua from the (now-correct) symlink and brings IPC
    #    back up. AppleScript ('execute lua code') is NOT a reliable
    #    fallback -- it is disabled by default in default/.hammerspoon
    #    (hs.allowAppleScript(true) is not set), so relaunch is the only
    #    path that reliably works when init.lua has not loaded.
    "$KILLALL" Hammerspoon 2>/dev/null || true
    "$OPEN" -a Hammerspoon

    # The relaunched app's IPC port comes up only once it has loaded
    # init.lua, which can take a while on a cold launch. Poll for IPC
    # liveness every HS_RELAUNCH_INTERVAL seconds up to a bounded
    # HS_RELAUNCH_TIMEOUT total, succeeding as soon as a probe passes
    # (rather than a single fixed sleep + one probe, which false-negatives
    # on a slow launch). The probe is a READ-ONLY liveness command
    # (`hs -c "true"`), NOT a second hs.reload() -- the relaunch already
    # re-loaded init.lua from the corrected symlink, so a second reload
    # would be redundant; we only need to confirm IPC is back up.
    #
    # Derive a whole-number attempt cap from the timeout/interval so the
    # loop is bounded even when the interval is 0 (as the unit test sets
    # it, to avoid real sleeping). With a 0 interval we still probe
    # HS_RELAUNCH_TIMEOUT+1 times; with a positive interval we probe
    # ceil(timeout/interval)+1 times, covering t=0 through t=timeout.
    local interval="$HS_RELAUNCH_INTERVAL" timeout="$HS_RELAUNCH_TIMEOUT" attempts
    if (( interval > 0 )); then
        attempts=$(( (timeout + interval - 1) / interval + 1 ))
    else
        attempts=$(( timeout + 1 ))
    fi
    local n
    for (( n = 0; n < attempts; n++ )); do
        if "$HS" -c "true"; then
            echo "Hammerspoon relaunched and config reloaded"
            return 0
        fi
        # Don't sleep after the final probe -- nothing follows it.
        (( n < attempts - 1 )) && sleep "$interval"
    done

    # 3. Neither path worked. Make the failure loud, not a soft Note.
    echo "" >&2
    echo "========================================================================" >&2
    echo "WARNING: Could not reload Hammerspoon automatically." >&2
    echo "The symlinks are updated, but the running Hammerspoon has NOT picked" >&2
    echo "them up, so your hotkeys may be dead until you reload manually." >&2
    echo "" >&2
    echo "  -> Reload now from the menubar: Hammerspoon icon -> Reload Config" >&2
    echo "========================================================================" >&2
    echo "" >&2
    return 1
}

# When sourced (e.g. by the unit test) rather than executed, stop here:
# expose the overridable command vars and reload_hammerspoon, but do not
# run the symlink setup or even source config_common.sh.
(return 0 2>/dev/null) && return 0

source "$SCRIPT_DIR/config_common.sh"

echo "Setting up Hammerspoon configuration..."

HOSTNAME_LOWER=$(get_hostname)
PROFILES=$(get_profiles "$REPO_ROOT" | paste -sd ' ' -)
echo "Detected hostname: $HOSTNAME_LOWER"
if [[ -n "$PROFILES" ]]; then
    echo "Using profiles (low to high priority): $PROFILES"
fi

# Create .hammerspoon directory if it doesn't exist
mkdir -p "$HAMMERSPOON_DIR"

# Resolve init.lua through three-tier fallback
SOURCE_FILE=$(resolve_file "$REPO_ROOT" ".hammerspoon/init.lua")
if [[ -z "$SOURCE_FILE" ]]; then
    echo "Error: No Hammerspoon init.lua found in computer-specific, profile, or default"
    exit 1
fi
echo "Using config: $SOURCE_FILE"

# Remove existing symlink or file if it exists
if [[ -L "$HAMMERSPOON_DIR/init.lua" ]]; then
    echo "Removing existing symlink..."
    rm "$HAMMERSPOON_DIR/init.lua"
elif [[ -f "$HAMMERSPOON_DIR/init.lua" ]]; then
    echo "Backing up existing init.lua to init.lua.backup..."
    mv "$HAMMERSPOON_DIR/init.lua" "$HAMMERSPOON_DIR/init.lua.backup"
fi

# Create the symlink
echo "Creating symlink: $HAMMERSPOON_DIR/init.lua -> $SOURCE_FILE"
ln -s "$SOURCE_FILE" "$HAMMERSPOON_DIR/init.lua"

echo "Hammerspoon init.lua setup complete!"
echo "Config file: $(readlink "$HAMMERSPOON_DIR/init.lua")"

# Symlink JSON config files
echo ""
echo "Setting up JSON config files..."
for config_file in monitors.json workspaces.json; do
    SOURCE_CONFIG=$(resolve_file "$REPO_ROOT" ".hammerspoon/$config_file")
    if [[ -z "$SOURCE_CONFIG" ]]; then
        echo "No $config_file found, skipping"
        continue
    fi
    echo "Using config: $SOURCE_CONFIG"

    TARGET_CONFIG="$HAMMERSPOON_DIR/$config_file"

    if [[ -L "$TARGET_CONFIG" ]]; then
        echo "Removing existing symlink for $config_file..."
        rm "$TARGET_CONFIG"
    elif [[ -f "$TARGET_CONFIG" ]]; then
        echo "Backing up existing $config_file to $config_file.backup..."
        mv "$TARGET_CONFIG" "$TARGET_CONFIG.backup"
    fi

    echo "Creating symlink: $TARGET_CONFIG -> $SOURCE_CONFIG"
    ln -s "$SOURCE_CONFIG" "$TARGET_CONFIG"
done

# Symlink modules/ directory through three-tier fallback
echo ""
echo "Setting up Hammerspoon modules..."
SOURCE_MODULES=$(resolve_dir "$REPO_ROOT" ".hammerspoon/modules")
if [[ -n "$SOURCE_MODULES" ]]; then
    TARGET_MODULES="$HAMMERSPOON_DIR/modules"

    if [[ -L "$TARGET_MODULES" ]]; then
        echo "Removing existing modules symlink..."
        rm "$TARGET_MODULES"
    elif [[ -d "$TARGET_MODULES" ]]; then
        echo "Backing up existing modules/ to modules.backup..."
        mv "$TARGET_MODULES" "$HAMMERSPOON_DIR/modules.backup"
    fi

    echo "Creating symlink: $TARGET_MODULES -> $SOURCE_MODULES"
    ln -s "$SOURCE_MODULES" "$TARGET_MODULES"
else
    echo "No modules/ directory found, skipping"
fi

# Configure Ctrl+1-9 desktop switching shortcuts
SPACES_SCRIPT="$SCRIPT_DIR/spaces_shortcuts_setup.sh"
if [[ -x "$SPACES_SCRIPT" ]]; then
    echo ""
    echo "Configuring desktop switching shortcuts..."
    "$SPACES_SCRIPT"
else
    echo ""
    echo "spaces_shortcuts_setup.sh not found or not executable, skipping"
fi

echo ""
echo "Hammerspoon configuration setup complete!"

# Reload Hammerspoon if it's running. Keep the pgrep guard so we never
# launch Hammerspoon on a machine where it was deliberately not running.
if "$PGREP" -q Hammerspoon; then
    # Don't let `set -e` abort on a failed reload before its loud warning
    # has been printed; surface the failure as this script's exit status.
    reload_hammerspoon || exit $?
fi
