#!/bin/bash

# Resolve email recipient from the [cron] mailto value in config.toml.
# Outputs the email address to stdout if found and the configured mailer is available.
# Outputs nothing and exits 0 if no mailto configured (caller falls back to log file).
# Exits 1 with error on stderr if mailto is configured but mailer prerequisites are missing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/config_common.sh"

# Resolve [cron] mailto across tiers (host > reverse(profiles) > default).
ADDRESS=$(resolve_config_value "$REPO_ROOT" "cron.mailto")
if [[ -z "$ADDRESS" ]]; then
    # No mailto configured — caller should use /dev/null
    exit 0
fi

# Resolve the [mailer] backend; default to msmtp so a host with no
# [mailer] section still works.
MAILER="$(resolve_config_value "$REPO_ROOT" "mailer.backend")"
MAILER="${MAILER:-msmtp}"

# Validate prerequisites for the configured mailer
case "$MAILER" in
    msmtp)
        if ! command -v msmtp >/dev/null 2>&1; then
            echo "Error: [cron] mailto is configured but msmtp is not installed. Run 'make messaging' first." >&2
            exit 1
        fi
        if [[ ! -f "$HOME/.msmtprc" ]]; then
            echo "Error: [cron] mailto is configured but ~/.msmtprc is missing. Run 'make messaging' first." >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: Unknown [mailer] backend value '$MAILER' in config.toml. Supported: msmtp" >&2
        exit 1
        ;;
esac

echo "$ADDRESS"
