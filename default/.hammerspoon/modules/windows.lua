-- modules/windows.lua
-- Cross-Space window enumeration, plus a targeted per-app lookup that
-- survives fullscreen-in-other-Space cases.
--
-- Background: hs.window.filter and app:allWindows() do NOT reliably
-- return fullscreen windows that live in non-current Mission Control
-- Spaces. The only consistently-working entry points for those windows
-- are hs.application.get(...):mainWindow() and :focusedWindow().
--
-- Why not hs.window.filter: filter:getWindows() walks every running
-- application via the macOS Accessibility API. WebKit content processes
-- (com.apple.WebKit.WebContent, spawned by Zoom, Slack, Electron apps,
-- etc.) do not respond to AX queries; macOS enforces a 6-second timeout
-- per process. A machine with N WebContent processes blocks for ~6×N
-- seconds per enumeration, which makes synchronous IPC (listWorkspaces,
-- hasExistingWindows) time out. See Hammerspoon/hammerspoon#3719 and
-- #3712.

local M = {}

-- Accessibility-slow XPC bundles to skip during enumeration. These
-- processes do not respond to AX queries and cause per-process 6s
-- timeouts on macOS.
local SKIP_BUNDLES = {
    ["com.apple.WebKit.WebContent"] = true,
    ["com.apple.WebKit.Networking"] = true,
    ["com.apple.WebKit.GPU"] = true,
}

--- Return all standard windows across all Mission Control Spaces.
--- Best-effort: may miss fullscreen windows that live in other Spaces.
--- Skips WebKit XPC processes that stall AX queries for 6 seconds each.
--- @return table  Array of hs.window
function M.allWindowsAcrossSpaces()
    local windows = {}
    for _, app in ipairs(hs.application.runningApplications()) do
        if not SKIP_BUNDLES[app:bundleID() or ""] then
            for _, w in ipairs(app:allWindows()) do
                if w:isStandard() then
                    table.insert(windows, w)
                end
            end
        end
    end
    return windows
end

--- Look up a single window for a specific running application, using
--- multiple fallback strategies because Hammerspoon's filter and
--- app:allWindows() don't reliably return fullscreen windows that live
--- in non-current Mission Control Spaces.
---
--- Fallback order: mainWindow -> focusedWindow -> visibleWindows[1] -> allWindows[1]
--- All return only standard (titled, resizable) windows.
---
--- Known limitation: returns at most one window per app. For multi-window
--- apps like code editors, only the main/focused window is returned.
---
--- @param appName string  Application name (exact match)
--- @return hs.window|nil  The window if found and standard, else nil
function M.windowForApp(appName)
    if not appName or appName == "" then return nil end
    local a = hs.application.get(appName)
    if not a then return nil end

    -- Try mainWindow first -- survives fullscreen-in-other-Space cases
    local mw = a:mainWindow()
    if mw and mw:isStandard() then return mw end

    -- Focused window -- also tends to survive non-current-Space cases
    local fw = a:focusedWindow()
    if fw and fw:isStandard() then return fw end

    -- Visible windows in the current Space
    for _, w in ipairs(a:visibleWindows() or {}) do
        if w:isStandard() then return w end
    end

    -- Last resort: allWindows (also Space-limited but try anyway)
    for _, w in ipairs(a:allWindows() or {}) do
        if w:isStandard() then return w end
    end

    return nil
end

return M
