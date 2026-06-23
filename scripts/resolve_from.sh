#!/bin/bash

# Resolve the From address for outgoing mail.
# Outputs the From address to stdout.
# Prefers [mailer] smtp_from from config.toml, then the `from` line in
# ~/.msmtprc, then falls back to "noreply@localhost".

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/config_common.sh"

# Resolve [mailer] smtp_from across tiers.
SMTP_FROM="$(resolve_config_value "$REPO_ROOT" "mailer.smtp_from")"

if [[ -n "$SMTP_FROM" ]]; then
    echo "$SMTP_FROM"
else
    FROM=$(grep '^from' "$HOME/.msmtprc" 2>/dev/null | head -1 | awk '{print $2}') || true
    echo "${FROM:-noreply@localhost}"
fi
