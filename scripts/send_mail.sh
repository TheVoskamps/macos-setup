#!/bin/bash

# Central mail dispatch: sends email via msmtp (generic SMTP relay).
# Usage: send_mail.sh <recipient>
#   Reads a complete RFC 822 message from stdin and sends it.
#   Exits with the send command's exit code.

set -euo pipefail

# Ensure Homebrew binaries are on PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/config_common.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: send_mail.sh <recipient>" >&2
    exit 1
fi

RECIPIENT="$1"

# Resolve the [mailer] backend from config.toml; default to msmtp so a
# host with no [mailer] section still works.
MAILER="$(resolve_config_value "$REPO_ROOT" "mailer.backend")"
MAILER="${MAILER:-msmtp}"

# Read stdin into a variable for potential reuse
MESSAGE=$(cat)

case "$MAILER" in
    msmtp)
        # Validate msmtp prerequisites
        if ! command -v msmtp >/dev/null 2>&1; then
            echo "Error: MAILER=msmtp but msmtp is not installed. Run 'make core' first." >&2
            exit 1
        fi
        if [[ ! -f "$HOME/.msmtprc" ]]; then
            echo "Error: MAILER=msmtp but ~/.msmtprc is missing. Run 'make core' first." >&2
            exit 1
        fi
        printf '%s\n' "$MESSAGE" | msmtp "$RECIPIENT"
        ;;
    *)
        echo "Error: Unknown [mailer] backend value '$MAILER' in config.toml. Supported: msmtp" >&2
        exit 1
        ;;
esac
