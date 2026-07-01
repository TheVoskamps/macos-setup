#!/bin/bash

set -e

echo "Setting up core system configuration..."

# Check if computer name is already set and not default
current_computer_name=$(scutil --get ComputerName 2>/dev/null || echo "")
current_hostname=$(scutil --get HostName 2>/dev/null || echo "")
current_local_hostname=$(scutil --get LocalHostName 2>/dev/null || echo "")

# Default macOS names that indicate the system hasn't been configured
default_names=("Mac" "MacBook" "iMac" "Mac mini" "Mac Pro" "MacBook Air" "MacBook Pro")
needs_setup=false

# Check if current name is a default or empty
if [[ -z "$current_computer_name" ]]; then
    needs_setup=true
else
    for default in "${default_names[@]}"; do
        if [[ "$current_computer_name" == *"$default"* ]]; then
            needs_setup=true
            break
        fi
    done
fi

echo
echo "Current computer names:"
echo "  ComputerName : $current_computer_name"
echo "  HostName     : $current_hostname"
echo "  LocalHostName: $current_local_hostname"
echo

if [[ "$needs_setup" == true ]]; then
    # Prompt for computer name
    while true; do
        echo -n "Enter a computer name (e.g. 'Edwin's MacBook'): "
        read -r computer_name

        if [[ -n "$computer_name" ]]; then
            break
        else
            echo "Please enter a valid computer name."
        fi
    done

    # Generate variations
    lowercase_name=$(echo "$computer_name" | tr '[:upper:]' '[:lower:]')
    hostname="${lowercase_name}.local"
    # For LocalHostName, remove spaces and special characters, keep only alphanumeric and hyphens
    local_hostname=$(echo "$lowercase_name" | sed 's/[^a-zA-Z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')

    echo
    echo "Setting computer names:"
    echo "  ComputerName: $computer_name"
    echo "  HostName: $hostname"
    echo "  LocalHostName: $local_hostname"
    echo

    # Set the names
    sudo scutil --set ComputerName "$computer_name"
    sudo scutil --set HostName "$hostname"
    sudo scutil --set LocalHostName "$local_hostname"

    # Set /etc/hostname to prevent DHCP from overriding the hostname
    echo "  /etc/hostname: $hostname"
    echo "$hostname" | sudo tee /etc/hostname > /dev/null

    echo "Computer names have been set successfully!"
    echo "Note: Some changes may require a restart to take full effect."
else
    echo "Computer name appears to be already configured: $current_computer_name"
    echo "Skipping computer name setup."
fi

# Disable Homebrew auto-update in .zshrc
ZSHRC="$HOME/.zshrc"
if [[ -f "$ZSHRC" ]]; then
    if ! grep -q "HOMEBREW_NO_AUTO_UPDATE" "$ZSHRC"; then
        echo "Adding HOMEBREW_NO_AUTO_UPDATE=1 to .zshrc..."
        echo "" >> "$ZSHRC"
        echo "# Disable Homebrew auto-update" >> "$ZSHRC"
        echo "export HOMEBREW_NO_AUTO_UPDATE=1" >> "$ZSHRC"
        echo "HOMEBREW_NO_AUTO_UPDATE added to .zshrc"
    else
        echo "HOMEBREW_NO_AUTO_UPDATE already set in .zshrc"
    fi

    # Disable Homebrew 6.0+ interactive ask-mode prompt. Homebrew 6.0
    # made ask mode the default for install/upgrade/reinstall (and, via
    # `brew bundle`'s default upgrade, for bundle too), so every such
    # call blocks on a "Do you want to proceed? [y/n]" prompt. Setting
    # HOMEBREW_NO_ASK covers all of them (and any future brew call) with
    # one lever, so `make update` / `make install` no longer hang.
    if ! grep -q "HOMEBREW_NO_ASK" "$ZSHRC"; then
        echo "Adding HOMEBREW_NO_ASK=1 to .zshrc..."
        echo "" >> "$ZSHRC"
        echo "# Disable Homebrew interactive ask-mode prompt (Homebrew 6.0+)" >> "$ZSHRC"
        echo "export HOMEBREW_NO_ASK=1" >> "$ZSHRC"
        echo "HOMEBREW_NO_ASK added to .zshrc"
    else
        echo "HOMEBREW_NO_ASK already set in .zshrc"
    fi
else
    echo "Warning: .zshrc not found, skipping HOMEBREW_NO_AUTO_UPDATE / HOMEBREW_NO_ASK setup"
fi

echo "Core system configuration complete!"
