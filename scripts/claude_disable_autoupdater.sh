#!/usr/bin/env bash

# Append `export DISABLE_AUTOUPDATER=1` to ~/.zshrc so Claude Code
# doesn't auto-update itself in the background. Idempotent: a second
# run is a no-op.
#
# This used to live inside `claude_setup.sh`; it survived the migration
# to a real ~/.claude clone (issue #111) and now stands alone so
# `make ai` can call it independently of `claude_repo_setup.sh`.

set -euo pipefail

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
