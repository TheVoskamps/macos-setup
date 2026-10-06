#!/bin/bash

# Start every app the resolved [autostart] section of config.toml names.
#
# Run at every login by the com.macos-setup.autostart LaunchAgent that
# scripts/autostart_setup.sh writes, through launchagent_runner, so its
# output lands in ~/Library/Logs/macos-setup/autostart.log. The config is
# read here, at login, so an edit to any tier's config.toml takes effect
# at the next login without a `make` run.
#
# Each name is looked up as `<name>.app` in /Applications,
# /System/Applications, then ~/Applications, and the first match is
# opened in the background. A name with no match is warned about and
# skipped without affecting the exit status; the script exits 1 when any
# `open` fails, and 0 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/config_common.sh"
source "$SCRIPT_DIR/autostart_common.sh"

OPEN="${OPEN:-open}"

rc=0
while IFS= read -r app; do
    path="$(autostart_app_path "$app")"
    if [[ -z "$path" ]]; then
        echo "Warning: no $app.app in /Applications, /System/Applications, or ~/Applications; skipping" >&2
        continue
    fi
    echo "Starting $app ($path)"
    if ! "$OPEN" -g -a "$path"; then
        echo "Warning: failed to start $app ($path)" >&2
        rc=1
    fi
done < <(resolve_autostart_apps "$REPO_ROOT")

exit "$rc"
