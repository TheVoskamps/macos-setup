# macos-setup: workspace launcher + monitor helpers (via Hammerspoon IPC).
# Sourced via ~/.zsh-shared.

# Workspace / monitor / position dispatcher (via Hammerspoon IPC)
# Usage: ws                       show inline help (workspaces + monitors)
#        ws <name>                launch workspace, monitor, or position
#        ws close <name>          close
#        ws restart <name>        close + launch
#        ws screens               list physical screens
#        ws fix                   re-sort all windows
ws() {
    local verb="$1"
    case "$verb" in
        "")
            hs -c 'listWorkspaces()'
            ;;
        screens)
            hs -c 'listScreens()'
            ;;
        fix)
            hs -c 'resortAllWindows()'
            ;;
        close|restart)
            local name="$2"
            if [[ -z "$name" ]]; then
                echo "ws: '$verb' requires a name" >&2
                return 1
            fi
            # Escape backslashes first, then double-quotes, for safe Lua string literal embedding
            name="${name//\\/\\\\}"
            name="${name//\"/\\\"}"
            if [[ "$verb" == "close" ]]; then
                hs -c "wsCloseDispatch(\"$name\")"
            else
                hs -c "wsRestartDispatch(\"$name\")"
            fi
            ;;
        *)
            local name="$verb"
            # Escape backslashes first, then double-quotes, for safe Lua string literal embedding
            name="${name//\\/\\\\}"
            name="${name//\"/\\\"}"
            hs -c "wsDispatch(\"$name\")"
            ;;
    esac
}
