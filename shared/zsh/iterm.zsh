# macos-setup: iTerm2 tab/title helpers. Sourced via ~/.zsh-shared.

# Count tabs in current iTerm2 window (0 outside iTerm2).
iterm_tab_count() {
    if [[ -n "$ITERM_SESSION_ID" ]]; then
        osascript -e 'tell application "iTerm2" to tell current window to count of tabs' 2>/dev/null
    else
        echo "0"
    fi
}

# Set tab title (if multiple tabs) or window title (if single tab).
set_title() {
    if [[ -z "$1" ]]; then
        echo "Usage: set_title <title>"
        return 1
    fi

    local title="$1"
    local tab_count
    tab_count=$(iterm_tab_count)

    # Disable iTerm2's automatic title updates
    echo -ne "\033]1337;SetAutoTitle=0\007"

    if [[ "$tab_count" -gt 1 ]]; then
        # Multiple tabs - set tab title only
        echo -ne "\033]1;${title}\007"
    else
        # Single tab - set window title
        echo -ne "\033]0;${title}\007"
    fi
}
