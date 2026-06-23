-- modules/apps/iterm.lua
-- Launch iTerm2 windows via AppleScript

local config = require("modules.config")
local utils = require("modules.utils")

local M = {}

-- Polling parameters for detecting new windows
M.POLL_INTERVAL = 0.3   -- Seconds between polls
M.POLL_TIMEOUT  = 5.0   -- Max seconds to wait for windows

--- Launch iTerm2 windows with a given working directory
--- @param launchConfig table  Config: { count = N, position = "preset-name" }
--- @param screen hs.screen  Target screen (unused directly, windows positioned by caller)
--- @param homeDir string  Working directory for new sessions
--- @param callback function  callback(windows) called with array of hs.window objects
function M.launch(launchConfig, screen, homeDir, callback)
    if not launchConfig or not launchConfig.count then
        if callback then callback({}) end
        return
    end

    local count = launchConfig.count
    local expandedHome = config.expandPath(homeDir) or os.getenv("HOME")

    -- Record existing iTerm2 window IDs before launching
    local existingIds = {}
    local itermApp = hs.application.find("iTerm2")
    if itermApp then
        for _, win in ipairs(itermApp:allWindows()) do
            existingIds[win:id()] = true
        end
    end

    -- Create windows via AppleScript sequentially using async delays
    local function createWindow(i, onAllCreated)
        if i > count then
            onAllCreated()
            return
        end

        local title = (homeDir and homeDir:match("([^/]+)$") or "terminal") .. " " .. i
        local safeHome = utils.escapeAppleScript(expandedHome)
        local safeTitle = utils.escapeAppleScript(title)
        local script = string.format([[
            tell application "iTerm2"
                create window with default profile
                tell current session of current window
                    write text "cd %s"
                end tell
                tell current window
                    set name to "%s"
                end tell
            end tell
        ]], safeHome, safeTitle)

        hs.osascript.applescript(script)

        if i < count then
            hs.timer.doAfter(0.3, function()
                createWindow(i + 1, onAllCreated)
            end)
        else
            onAllCreated()
        end
    end

    -- Poll for new windows to appear (started after all windows are created)
    local function startPolling()
        local elapsed = 0
        local function pollForWindows()
            elapsed = elapsed + M.POLL_INTERVAL

            local app = hs.application.find("iTerm2")
            if app then
                local newWindows = {}
                for _, win in ipairs(app:allWindows()) do
                    if win:isStandard() and not existingIds[win:id()] then
                        table.insert(newWindows, win)
                    end
                end

                if #newWindows >= count or elapsed >= M.POLL_TIMEOUT then
                    if callback then callback(newWindows) end
                    return
                end
            elseif elapsed >= M.POLL_TIMEOUT then
                if callback then callback({}) end
                return
            end

            hs.timer.doAfter(M.POLL_INTERVAL, pollForWindows)
        end

        hs.timer.doAfter(M.POLL_INTERVAL, pollForWindows)
    end

    -- Create all windows, then start polling
    createWindow(1, startPolling)
end

return M
