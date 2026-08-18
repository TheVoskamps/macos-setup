#!/usr/bin/env bash

# Turn off Claude Code's background self-update, from both levers:
#
#   The CLI setting — `claude config set -g autoUpdates false`.
#   The environment override — `export DISABLE_AUTOUPDATER=1` in
#     ~/.zshrc, which also covers invocations that bypass the CLI config.
#
# Idempotent: a second run is a no-op for both.
#
# This used to live inside `claude_setup.sh`; it survived the migration
# to a real ~/.claude clone (issue #111) and now stands alone so any
# profile that installs Claude Code can name it as a post-install action.
# The CLI setting used to be a bare `claude config set ...` line in the
# Makefile's per-slot recipe; it moved in here when post-install dispatch
# became a `[profile] post_install` list of scripts, so both levers pull
# together.

set -euo pipefail

# The CLI setting. Best-effort: the `claude` CLI may not be installed yet
# (the cask is installed by the same tier that runs this script, and a
# `brew bundle` failure would leave it absent), and the setting is not
# load-bearing enough to fail the run over.
if command -v claude >/dev/null 2>&1; then
    if claude config set -g autoUpdates false >/dev/null 2>&1; then
        echo "Claude CLI autoUpdates set to false"
    else
        echo "Warning: 'claude config set -g autoUpdates false' failed; continuing"
    fi
else
    echo "claude CLI not on PATH; skipping the autoUpdates config setting"
fi

# The environment override.
ZSHRC="$HOME/.zshrc"

if [[ ! -f "$ZSHRC" ]]; then
    echo "Warning: $ZSHRC not found, skipping DISABLE_AUTOUPDATER setup"
    exit 0
fi

if grep -q "DISABLE_AUTOUPDATER" "$ZSHRC"; then
    echo "DISABLE_AUTOUPDATER already set in $ZSHRC"
    exit 0
fi

echo "Adding DISABLE_AUTOUPDATER=1 to $ZSHRC..."
{
    echo ""
    echo "# Disable Claude Code autoupdater"
    echo "export DISABLE_AUTOUPDATER=1"
} >>"$ZSHRC"
echo "DISABLE_AUTOUPDATER added to $ZSHRC"
