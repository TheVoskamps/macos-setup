#!/bin/bash

# Wrap a command's output into an email and send via configured mailer.
# Usage: mail_wrapper.sh <recipient> <subject> <command...>
#
# Runs the command, captures stdout+stderr, and sends the output
# as a plain-text email. Exits with the command's exit code.

set -euo pipefail

# Ensure Homebrew binaries are on PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 3 ]]; then
    echo "Usage: mail_wrapper.sh <recipient> <subject> <command...>" >&2
    exit 1
fi

RECIPIENT="$1"
SUBJECT="$2"
shift 2

# Run the command, capture output and exit code
OUTPUT=$("$@" 2>&1) || CMD_EXIT=$?
CMD_EXIT=${CMD_EXIT:-0}

# Add success/failure to subject line
if [[ $CMD_EXIT -eq 0 ]]; then
    SUBJECT="$SUBJECT [OK]"
else
    SUBJECT="$SUBJECT [FAILED exit=$CMD_EXIT]"
fi

HOSTNAME=$(hostname -s)
DATE=$(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')

# Resolve From address via configured mailer backend
FROM=$("$SCRIPT_DIR/resolve_from.sh") || true

# Build email with proper headers and pipe to send_mail.sh
{
    echo "From: ${FROM:-noreply@localhost}"
    echo "To: $RECIPIENT"
    echo "Subject: $SUBJECT"
    echo "Date: $DATE"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "X-Mailer: macos-setup mail_wrapper"
    echo ""
    echo "Host: $HOSTNAME"
    echo "Command: $*"
    echo "Exit code: $CMD_EXIT"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
    echo "--- Output ---"
    echo ""
    printf '%s\n' "$OUTPUT"
} | "$SCRIPT_DIR/send_mail.sh" "$RECIPIENT" || {
    echo "Failed to send email (exit $?)" >&2
}

exit $CMD_EXIT
