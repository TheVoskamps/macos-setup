-- modules/apps/safari.lua
-- Launch Safari windows with URL tabs via AppleScript

local utils = require("modules.utils")

local M = {}

-- Polling parameters for detecting new windows
M.POLL_INTERVAL = 0.5   -- Seconds between polls
M.POLL_TIMEOUT  = 8.0   -- Max seconds to wait for Safari window

--- Launch a Safari window with one or more URL tabs
--- @param launchConfig table  Config: { urls = {"https://...", ...} }
--- @param screen hs.screen  Target screen (unused directly, windows positioned by caller)
--- @param homeDir string  Unused for Safari
--- @param callback function  callback(windows) called with array containing the Safari window
function M.launch(launchConfig, screen, homeDir, callback)
    if not launchConfig or not launchConfig.urls or #launchConfig.urls == 0 then
        if callback then callback({}) end
        return
    end

    local urls = launchConfig.urls

    -- Record existing Safari window IDs before launching
    local existingIds = {}
    local safariApp = hs.application.find("Safari")
    if safariApp then
        for _, win in ipairs(safariApp:allWindows()) do
            existingIds[win:id()] = true
        end
    end

    -- Ensure Safari is running (without stealing focus via activate)
    hs.application.open("Safari")

    -- Build AppleScript to create window with first URL, then add tabs for the rest
    -- Note: no 'activate' here to avoid stealing focus during multi-app launch;
    -- the launcher's Phase 4 handles final focus restoration.
    local scriptParts = {
        'tell application "Safari"',
        string.format('    make new document with properties {URL:"%s"}', utils.escapeAppleScript(urls[1])),
    }

    if #urls > 1 then
        table.insert(scriptParts, '    tell window 1')
        for i = 2, #urls do
            table.insert(scriptParts, string.format(
                '        set current tab to (make new tab with properties {URL:"%s"})',
                utils.escapeAppleScript(urls[i])
            ))
        end
        table.insert(scriptParts, '    end tell')
    end

    table.insert(scriptParts, 'end tell')

    local script = table.concat(scriptParts, "\n")
    hs.osascript.applescript(script)

    -- Poll for new Safari window
    local elapsed = 0
    local function pollForWindow()
        elapsed = elapsed + M.POLL_INTERVAL

        local app = hs.application.find("Safari")
        if app then
            for _, win in ipairs(app:allWindows()) do
                if win:isStandard() and not existingIds[win:id()] then
                    if callback then callback({ win }) end
                    return
                end
            end
        end

        if elapsed >= M.POLL_TIMEOUT then
            -- Timeout: try to return any Safari window
            local app2 = hs.application.find("Safari")
            if app2 then
                local wins = app2:allWindows()
                if #wins > 0 then
                    if callback then callback({ wins[1] }) end
                    return
                end
            end
            if callback then callback({}) end
            return
        end

        hs.timer.doAfter(M.POLL_INTERVAL, pollForWindow)
    end

    -- Start polling after a brief initial delay
    hs.timer.doAfter(M.POLL_INTERVAL, pollForWindow)
end

return M
