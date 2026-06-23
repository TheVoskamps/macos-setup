#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CDK_CONFIG_FILE="$HOME/.cdk.json"

source "$SCRIPT_DIR/config_common.sh"

echo "Setting up AWS CDK configuration..."

HOSTNAME_LOWER=$(get_hostname)
PROFILES=$(get_profiles "$REPO_ROOT" | paste -sd ' ' -)
echo "Detected hostname: $HOSTNAME_LOWER"
if [[ -n "$PROFILES" ]]; then
    echo "Using profiles (low to high priority): $PROFILES"
fi

# Resolve .cdk.json through three-tier fallback
SOURCE_FILE=$(resolve_file "$REPO_ROOT" ".cdk.json")
if [[ -z "$SOURCE_FILE" ]]; then
    echo "Error: No CDK config found in computer-specific, profile, or default"
    exit 1
fi
echo "Using config: $SOURCE_FILE"

# Remove existing symlink or file if it exists
if [[ -L "$CDK_CONFIG_FILE" ]]; then
    echo "Removing existing symlink..."
    rm "$CDK_CONFIG_FILE"
elif [[ -f "$CDK_CONFIG_FILE" ]]; then
    echo "Backing up existing .cdk.json to .cdk.json.backup..."
    mv "$CDK_CONFIG_FILE" "$CDK_CONFIG_FILE.backup"
fi

# Create the symlink
echo "Creating symlink: $CDK_CONFIG_FILE -> $SOURCE_FILE"
ln -s "$SOURCE_FILE" "$CDK_CONFIG_FILE"

echo "AWS CDK configuration setup complete!"
echo "Config file: $(readlink "$CDK_CONFIG_FILE")"
