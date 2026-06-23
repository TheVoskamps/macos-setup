-- modules/apps/finder.lua
-- Launch Finder windows via AppleScript

local config = require("modules.config")
local utils = require("modules.utils")

local M = {}

-- Polling parameters for detecting new windows
M.POLL_INTERVAL = 0.3   -- Seconds between polls
M.POLL_TIMEOUT  = 5.0   -- Max seconds to wait for windows

--- Launch Finder windows at specified paths
--- @param launchConfig table  Array of { path = "~/path", position = "preset", index = N }
--- @param screen hs.screen  Target screen (unused directly, windows positioned by caller)
--- @param homeDir string  Fallback directory (unused, paths come from config)
--- @param callback function  callback(windows) called with array of hs.window objects
function M.launch(launchConfig, screen, homeDir, callback)
    if not launchConfig or #launchConfig == 0 then
        if callback then callback({}) end
        return
    end

    -- Record existing Finder window IDs before launching
    local existingIds = {}
    local finderApp = hs.application.find("Finder")
    if finderApp then
        for _, win in ipairs(finderApp:allWindows()) do
            existingIds[win:id()] = true
        end
    end

    local count = #launchConfig

    -- Create Finder windows via AppleScript sequentially using async delays
    local function createWindow(idx, onAllCreated)
        if idx > count then
            onAllCreated()
            return
        end

        local entry = launchConfig[idx]
        local expandedPath = config.expandPath(entry.path) or entry.path
        local safePath = utils.escapeAppleScript(expandedPath)
        local script = string.format([[
            tell application "Finder"
                make new Finder window to (POSIX file "%s" as alias)
            end tell
        ]], safePath)

        hs.osascript.applescript(script)

        if idx < count then
            hs.timer.doAfter(0.2, function()
                createWindow(idx + 1, onAllCreated)
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

            local app = hs.application.find("Finder")
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
