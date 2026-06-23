-- modules/apps/vscode.lua
-- Launch VS Code via CLI and poll for window

local config = require("modules.config")

local M = {}

-- Polling parameters for detecting new windows
M.POLL_INTERVAL = 0.5   -- Seconds between polls
M.POLL_TIMEOUT  = 10.0  -- Max seconds to wait for VS Code window

-- Resolve VS Code CLI path dynamically (supports both Intel and Apple Silicon)
local codePath = (hs.execute("which code 2>/dev/null") or ""):gsub("%s+$", "")
if codePath == "" then codePath = "/opt/homebrew/bin/code" end  -- Apple Silicon default

--- Launch VS Code with a workspace file or folder
--- @param launchConfig table  Config: { workspaceFile = "path", position = "preset" } or { folder = "path", position = "preset" }
--- @param screen hs.screen  Target screen (unused directly, windows positioned by caller)
--- @param homeDir string  Fallback directory (used if neither workspaceFile nor folder given)
--- @param callback function  callback(windows) called with array containing the VS Code window
function M.launch(launchConfig, screen, homeDir, callback)
    if not launchConfig then
        if callback then callback({}) end
        return
    end

    -- Determine what to open
    local target
    local matchHint  -- substring to match in window title
    if launchConfig.workspaceFile then
        target = config.expandPath(launchConfig.workspaceFile)
        -- VS Code titles workspace files like "project-name (Workspace)"
        matchHint = target:match("([^/]+)%.code%-workspace$") or target:match("([^/]+)$")
    elseif launchConfig.folder then
        target = config.expandPath(launchConfig.folder)
        matchHint = target:match("([^/]+)/?$")
    elseif homeDir then
        -- Fallback: open homeDir as folder when neither workspaceFile nor folder given
        target = config.expandPath(homeDir)
        matchHint = target:match("([^/]+)/?$")
    else
        if callback then callback({}) end
        return
    end

    -- Record existing VS Code window IDs
    local existingIds = {}
    local vscodeApp = hs.application.find("Code") or hs.application.find("Visual Studio Code")
    if vscodeApp then
        for _, win in ipairs(vscodeApp:allWindows()) do
            existingIds[win:id()] = true
        end
    end

    -- Launch via CLI (non-blocking)
    local args = { target }
    if launchConfig.workspaceFile then
        -- code opens workspace files directly
    end
    hs.task.new(codePath, nil, function() return true end, args):start()

    -- Poll for new VS Code window
    local elapsed = 0
    local function pollForWindow()
        elapsed = elapsed + M.POLL_INTERVAL

        local app = hs.application.find("Code") or hs.application.find("Visual Studio Code")
        if app then
            for _, win in ipairs(app:allWindows()) do
                if win:isStandard() and not existingIds[win:id()] then
                    -- Found a new window
                    if callback then callback({ win }) end
                    return
                end
            end

            -- Also check by title match if no new window ID found
            -- (VS Code may reuse an existing window)
            if matchHint then
                for _, win in ipairs(app:allWindows()) do
                    if win:isStandard() then
                        local title = win:title() or ""
                        if string.find(title:lower(), matchHint:lower(), 1, true) then
                            if callback then callback({ win }) end
                            return
                        end
                    end
                end
            end
        end

        if elapsed >= M.POLL_TIMEOUT then
            -- Timeout: return empty
            if callback then callback({}) end
            return
        end

        hs.timer.doAfter(M.POLL_INTERVAL, pollForWindow)
    end

    -- Start polling after initial delay (VS Code takes a moment to start)
    hs.timer.doAfter(1.0, pollForWindow)
end

return M
