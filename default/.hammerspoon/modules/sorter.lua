-- modules/sorter.lua
-- Window re-sort logic with position-aware placement
-- Determines where each window belongs and moves it to the correct monitor/space

local monitors = require("modules.monitors")
local spaces = require("modules.spaces")
local winutil = require("modules.windows")

local M = {}

-- Delay between un-fullscreen and move, and between move and re-fullscreen.
-- macOS needs a beat to process fullscreen state changes before
-- `moveToScreen` will actually relocate a window.
M.UNFULLSCREEN_DELAY = 0.3

-- Track windows being processed to avoid duplicate fullscreen attempts
local processingWindows = {}

--------------------------------------------------------------------------------
-- APP NAME MAPPING
--------------------------------------------------------------------------------

-- Map application names to workspace launch config keys
-- Used to look up position config for a window during re-sort
local APP_TO_LAUNCH_KEY = {
    ["iTerm2"]              = "iterm",
    ["Code"]                = "vscode",
    ["Visual Studio Code"]  = "vscode",
    ["Cursor"]              = "vscode",
    ["Finder"]              = "finder",
    ["Safari"]              = "safari",
}

--------------------------------------------------------------------------------
-- WINDOW HELPERS
--------------------------------------------------------------------------------

--- Move a window to a target screen (if not already there)
--- @param win hs.window  The window to move
--- @param targetScreen hs.screen  The screen to move to
--- @return boolean  true if the window was moved, false if already on correct screen
function M.moveWindowToScreen(win, targetScreen)
    if not win or not targetScreen then return false end

    local currentScreen = win:screen()
    if currentScreen and currentScreen:id() == targetScreen:id() then
        return false -- Already on correct screen
    end

    -- `hs.window:moveToScreen()` is silently a no-op on a fullscreen
    -- window. Un-fullscreen first, wait for macOS to settle, move, then
    -- re-fullscreen on the target screen.
    if win:isFullScreen() then
        win:setFullScreen(false)
        hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
            if win and win:isVisible() then
                win:moveToScreen(targetScreen, true, true)
                hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                    if win and win:isVisible() and not win:isFullScreen() then
                        win:setFullScreen(true)
                    end
                end)
            end
        end)
    else
        win:moveToScreen(targetScreen, true, true)
    end
    return true
end

--- Ensure a window is fullscreen if its monitor config requires it
--- @param win hs.window  The window to fullscreen
--- @param monitorName string  The monitor name key
--- @param monitorsConfig table  The monitors config
--- @param delay number|nil  Delay before applying fullscreen (default 0.3)
--- @return boolean  true if fullscreen was initiated
function M.ensureFullscreen(win, monitorName, monitorsConfig, delay)
    local monitorDef = monitorsConfig.monitors[monitorName]
    if not monitorDef or monitorDef.fullscreen ~= true then return false end
    if win:isFullScreen() then return false end

    local winId = win:id()
    local actualDelay = delay or 0.3

    processingWindows[winId] = true
    hs.timer.doAfter(actualDelay, function()
        if win and win:isVisible() and not win:isFullScreen() then
            win:setFullScreen(true)
        end
        processingWindows[winId] = nil
    end)
    return true
end

--------------------------------------------------------------------------------
-- ASSIGNMENT LOGIC
--------------------------------------------------------------------------------

--- Check if app is in a monitor's apps list
--- Returns the monitor name if found, nil otherwise
--- @param appName string  The application name
--- @param monitorsConfig table  The monitors config
--- @return string|nil  Monitor name or nil
local function getMonitorForApp(appName, monitorsConfig)
    for monitorName, monitorDef in pairs(monitorsConfig.monitors) do
        if monitorDef.apps then
            for _, app in ipairs(monitorDef.apps) do
                if app == appName then
                    return monitorName
                end
            end
        end
    end
    return nil
end

--- Check titleAssignments for an app.
--- Returns the target monitor name if a `matchAll` assignment exists for
--- this app, otherwise nil. Per-window workspace pattern matching (see
--- `getWorkspaceForWindow`) takes precedence over titleAssignments and
--- is checked first by `resortAll`, so titleAssignments no longer need
--- an `excludePatterns` opt-out: workspace-matching windows are claimed
--- before this function is consulted.
--- @param appName string  The application name
--- @param monitorsConfig table  The monitors config
--- @return string|nil  Monitor name or nil
local function getMonitorForTitleAssignment(appName, monitorsConfig)
    local titleAssignments = monitorsConfig.titleAssignments or {}
    for _, assignment in ipairs(titleAssignments) do
        if assignment.app == appName and assignment.matchAll then
            return assignment.monitor
        end
    end
    return nil
end

--- Check if window matches a primary-monitor workspace via title patterns
--- @param title string  The window title
--- @param workspacesConfig table  The workspaces config
--- @return string|nil  Workspace name or nil
--- @return number|nil  Space index or nil
local function getWorkspaceForWindow(title, workspacesConfig)
    for name, ws in pairs(workspacesConfig.workspaces) do
        for _, pattern in ipairs(ws.patterns or {}) do
            if string.find(title:lower(), pattern:lower(), 1, true) then
                return name, ws.spaceIndex
            end
        end
    end
    return nil, nil
end

--- Apply position from workspace launch config to a window
--- Matches the window's app to the workspace's launch config and applies positioning
--- @param win hs.window  The window to position
--- @param wsName string  The workspace name
--- @param screen hs.screen  The screen to resolve positions against
--- @param workspacesConfig table  The workspaces config
--- @param positionsModule table  The positions module
local function applyWorkspacePosition(win, wsName, screen, workspacesConfig, positionsModule)
    if not win or not wsName or not screen or not positionsModule then return end

    local positionsConfig = workspacesConfig.positions or {}
    if not next(positionsConfig) then return end

    -- Find the workspace config (hash lookup on keyed object)
    local workspace = (workspacesConfig.workspaces or {})[wsName]
    if not workspace or not workspace.launch then return end

    -- Determine launch key from app name
    local app = win:application()
    local appName = app and app:name() or ""
    local launchKey = APP_TO_LAUNCH_KEY[appName]
    if not launchKey then return end

    local launchConfig = workspace.launch[launchKey]
    if not launchConfig then return end

    -- For finder, the config is an array of entries; pick the first matching one
    if launchKey == "finder" and type(launchConfig) == "table" and launchConfig[1] then
        local title = (win:title() or ""):lower()
        for _, entry in ipairs(launchConfig) do
            if entry.position then
                local dirName = entry.path and entry.path:match("([^/]+)/?$") or nil
                if dirName and string.find(title, dirName:lower(), 1, true) then
                    local idx = (entry.index or 0) + 1
                    local frame = positionsModule.resolve(entry.position, screen, positionsConfig, idx)
                    if frame then win:setFrame(frame) end
                    return
                end
            end
        end
        -- Fallback: use first entry with a position
        for _, entry in ipairs(launchConfig) do
            if entry.position then
                local idx = (entry.index or 0) + 1
                local frame = positionsModule.resolve(entry.position, screen, positionsConfig, idx)
                if frame then win:setFrame(frame) end
                return
            end
        end
        return
    end

    -- For other apps, get the position name from the config
    local positionName = launchConfig.position
    if not positionName then return end

    local frame = positionsModule.resolve(positionName, screen, positionsConfig, 1)
    if frame then
        win:setFrame(frame)
    end
end

--------------------------------------------------------------------------------
-- MAIN RESORT FUNCTION
--------------------------------------------------------------------------------

--- Move a window to a target screen with full serialization.
--- Fully completes the un-fullscreen -> move -> re-fullscreen sequence,
--- then invokes `done(wasMoved)`. Safe to chain: guarantees no other
--- fullscreen transition is in flight when `done` fires.
--- @param win hs.window
--- @param targetScreen hs.screen
--- @param wantFullscreen boolean  Whether the window should be fullscreen
--- @param done fun(wasMoved: boolean, wasFullscreened: boolean)  Callback
function M.moveWindowToScreenAsync(win, targetScreen, wantFullscreen, done)
    if not win or not targetScreen then
        done(false, false); return
    end

    local currentScreen = win:screen()
    local alreadyOnTargetScreen = currentScreen and currentScreen:id() == targetScreen:id()
    local alreadyFullscreen = win:isFullScreen()

    if alreadyOnTargetScreen then
        -- On the right screen already. Reconcile fullscreen state.
        if wantFullscreen == alreadyFullscreen then
            print("[serial sorter] noop id=" .. tostring(win:id()) .. " (already on target, fs state matches want=" .. tostring(wantFullscreen) .. ")")
            return done(false, false)
        elseif wantFullscreen and not alreadyFullscreen then
            print("[serial sorter] F setFullScreen(true) id=" .. tostring(win:id()))
            win:setFullScreen(true)
            hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                print("[serial sorter] G done id=" .. tostring(win:id()) .. " (fullscreened in place)")
                done(false, true)
            end)
            return
        else
            -- not wantFullscreen and alreadyFullscreen
            print("[serial sorter] H setFullScreen(false) id=" .. tostring(win:id()))
            win:setFullScreen(false)
            hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                print("[serial sorter] I done id=" .. tostring(win:id()) .. " (unfullscreened in place)")
                done(false, true)
            end)
            return
        end
    end

    if alreadyFullscreen then
        print("[serial sorter] A setFullScreen(false) id=" .. tostring(win:id()))
        win:setFullScreen(false)
        hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
            print("[serial sorter] B timer fired id=" .. tostring(win:id()) .. " vis=" .. tostring(win:isVisible()) .. " fs=" .. tostring(win:isFullScreen()))
            if win and win:isVisible() then
                win:moveToScreen(targetScreen, true, true)
                print("[serial sorter] C moveToScreen done id=" .. tostring(win:id()))
                hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                    print("[serial sorter] D timer fired id=" .. tostring(win:id()))
                    if wantFullscreen and win and win:isVisible() and not win:isFullScreen() then
                        win:setFullScreen(true)
                        hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                            print("[serial sorter] E done id=" .. tostring(win:id()))
                            done(true, true)
                        end)
                    else
                        print("[serial sorter] E done (no refs) id=" .. tostring(win:id()))
                        done(true, false)
                    end
                end)
            else
                print("[serial sorter] B win gone id=" .. tostring(win and win:id()))
                done(false, false)
            end
        end)
    else
        win:moveToScreen(targetScreen, true, true)
        if wantFullscreen then
            hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                if win and win:isVisible() and not win:isFullScreen() then
                    win:setFullScreen(true)
                    hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
                        done(true, true)
                    end)
                else
                    done(true, false)
                end
            end)
        else
            done(true, false)
        end
    end
end

--- Resort all windows based on config assignments
--- Uses a serialized async pipeline: every fullscreen transition completes
--- before the next begins. This avoids saturating the Hammerspoon event loop
--- (which caused IPC `already recursing` errors when many fullscreen windows
--- needed to move at once).
---
--- @param monitorsConfig table  The monitors config
--- @param workspacesConfig table  The workspaces config
--- @param positionsModule table  The positions module (provides resolve function)
function M.resortAll(monitorsConfig, workspacesConfig, positionsModule)
    local movedToMonitor = 0
    local fullscreened = 0

    processingWindows = {}

    -- Build the work queue from CONFIG, not from window enumeration.
    -- Reason: hs.window.filter / allWindows() don't reliably return
    -- fullscreen windows in other Spaces, so the old enumeration-driven
    -- approach silently dropped exactly the windows that most needed
    -- fixing. By iterating the config and looking each app up via
    -- windows.windowForApp (which uses mainWindow/focusedWindow), we
    -- catch the fullscreen-in-other-Space cases.
    local workQueue = {}
    local spaceMoveQueue = {}
    local seenWinIds = {}

    -- Pass 1: monitor.apps lists (config-driven, per-app lookup)
    for monitorName, monitorDef in pairs(monitorsConfig.monitors or {}) do
        for _, appName in ipairs(monitorDef.apps or {}) do
            local win = winutil.windowForApp(appName)
            if win and win:isStandard() and not seenWinIds[win:id()] then
                local targetScreen = monitors.getScreenForMonitor(monitorName, monitorsConfig)
                if targetScreen then
                    seenWinIds[win:id()] = true
                    local wantFullscreen = monitorDef.fullscreen == true
                    table.insert(workQueue, {
                        kind = "monitor",
                        win = win,
                        targetScreen = targetScreen,
                        monitorName = monitorName,
                        wantFullscreen = wantFullscreen,
                    })
                end
            end
        end
    end

    -- Pass 2: workspace patterns (title-based, full enumeration).
    --
    -- Workspace pattern matching wins over titleAssignments: a window
    -- whose title matches a workspace pattern in workspaces.json is
    -- routed to that workspace's Space, even if its app also has a
    -- titleAssignment in monitors.json. Running this pass before Pass 3
    -- (titleAssignments) means workspace-matching windows are claimed
    -- via `seenWinIds` and the titleAssignment fallback can't override
    -- them. This is the precedence rule from issue #50; it removes the
    -- need for `excludePatterns` on titleAssignments, which previously
    -- duplicated the pattern lists from workspaces.json.
    --
    -- Workspace patterns must be matched by title, not app name, so we
    -- still need a window enumeration here. This pass is best-effort
    -- against the filter; it can't see fullscreen-in-other-Space
    -- windows but workspace items typically aren't fullscreen.
    for _, win in ipairs(winutil.allWindowsAcrossSpaces()) do
        if win:isStandard() and not seenWinIds[win:id()] then
            local title = win:title() or ""
            local wsName, spaceIndex = getWorkspaceForWindow(title, workspacesConfig)
            if wsName and spaceIndex then
                local primary = monitors.findPrimary(monitorsConfig)
                if primary then
                    seenWinIds[win:id()] = true
                    table.insert(workQueue, {
                        kind = "workspace",
                        win = win,
                        targetScreen = primary,
                        wsName = wsName,
                        spaceIndex = spaceIndex,
                    })
                end
            end
        end
    end

    -- Pass 3: titleAssignments (config-driven, per-app lookup).
    -- Only `matchAll` assignments resolve here; workspace matches above
    -- have already claimed any workspace-pattern windows.
    for _, assignment in ipairs(monitorsConfig.titleAssignments or {}) do
        local win = winutil.windowForApp(assignment.app)
        if win and win:isStandard() and not seenWinIds[win:id()] then
            local monitorName = getMonitorForTitleAssignment(assignment.app, monitorsConfig)
            if monitorName then
                local targetScreen = monitors.getScreenForMonitor(monitorName, monitorsConfig)
                if targetScreen then
                    local monitorDef = monitorsConfig.monitors[monitorName]
                    local wantFullscreen = monitorDef and monitorDef.fullscreen == true
                    seenWinIds[win:id()] = true
                    table.insert(workQueue, {
                        kind = "monitor",
                        win = win,
                        targetScreen = targetScreen,
                        monitorName = monitorName,
                        wantFullscreen = wantFullscreen,
                    })
                end
            end
        end
    end

    print("[serial sorter] workQueue size=" .. tostring(#workQueue))

    local movedToSpace = 0

    local function showSortSummary()
        local total = movedToMonitor + movedToSpace
        local msg = "Sorted: " .. movedToMonitor .. " to monitors, " .. movedToSpace .. " to spaces"
        if fullscreened > 0 then
            msg = msg .. ", " .. fullscreened .. " fullscreened"
        end
        if total > 0 or fullscreened > 0 then
            print(msg)
        else
            print("All windows in correct positions")
        end
        print("[serial sorter] summary: " .. msg)
    end

    local summaryShown = false
    local function showSortSummaryOnce(reason)
        if summaryShown then
            print("[serial sorter] showSortSummary suppressed (" .. tostring(reason) .. "), already shown")
            return
        end
        summaryShown = true
        print("[serial sorter] showSortSummary reason=" .. tostring(reason))
        showSortSummary()
    end

    local function processNextSpaceMove(index)
        if index > #spaceMoveQueue then
            print("[serial sorter] spaceMoveQueue drained")
            showSortSummaryOnce("spaceMoveQueue drained")
            return
        end
        local move = spaceMoveQueue[index]
        local winId = move.win and move.win:id() or "?"
        print("[serial sorter] spaceMove " .. index .. "/" .. #spaceMoveQueue ..
              " winId=" .. tostring(winId) .. " targetSpace=" .. tostring(move.targetSpace))
        local advanced = false
        local function advance(success, via)
            if advanced then
                print("[serial sorter] spaceMove " .. index .. " advance suppressed (via=" .. tostring(via) .. "), already advanced")
                return
            end
            advanced = true
            print("[serial sorter] spaceMove " .. index .. " complete success=" .. tostring(success) .. " via=" .. tostring(via))
            if success then movedToSpace = movedToSpace + 1 end
            processNextSpaceMove(index + 1)
        end
        spaces.moveWindowToSpace(move.win, move.targetSpace, move.spaceIndex, function(success)
            advance(success, "callback")
        end)
        -- Safety net: if the spaces module never invokes the callback,
        -- force-advance so the summary still prints.
        hs.timer.doAfter(3.0, function()
            advance(false, "timeout")
        end)
    end

    local function processNext(index)
        if index > #workQueue then
            print("[serial sorter] workQueue drained, " .. #spaceMoveQueue .. " space moves queued")
            if #spaceMoveQueue > 0 then
                processNextSpaceMove(1)
            else
                showSortSummaryOnce("workQueue drained, no space moves")
            end
            return
        end

        local item = workQueue[index]
        print("[serial sorter] processNext " .. index .. "/" .. #workQueue ..
              " kind=" .. item.kind .. " id=" .. tostring(item.win:id()))

        if item.kind == "monitor" then
            M.moveWindowToScreenAsync(item.win, item.targetScreen, item.wantFullscreen, function(wasMoved, wasFullscreened)
                print("[serial sorter] processNext " .. index .. " done wasMoved=" .. tostring(wasMoved) .. " wasFullscreened=" .. tostring(wasFullscreened))
                if wasMoved then movedToMonitor = movedToMonitor + 1 end
                if wasFullscreened then fullscreened = fullscreened + 1 end
                processNext(index + 1)
            end)
        elseif item.kind == "workspace" then
            print("[serial sorter] workspace handler id=" .. tostring(item.win:id()) ..
                  " wsName=" .. tostring(item.wsName) .. " spaceIndex=" .. tostring(item.spaceIndex))
            -- Workspace items: primary monitor is never fullscreen.
            M.moveWindowToScreenAsync(item.win, item.targetScreen, false, function(wasMoved, _)
                print("[serial sorter] processNext " .. index .. " done wasMoved=" .. tostring(wasMoved) .. " (workspace)")
                if wasMoved then movedToMonitor = movedToMonitor + 1 end
                applyWorkspacePosition(item.win, item.wsName, item.targetScreen, workspacesConfig, positionsModule)

                local primarySpaces = spaces.getSpacesForScreen(item.targetScreen)
                if primarySpaces and #primarySpaces >= item.spaceIndex then
                    local targetSpace = primarySpaces[item.spaceIndex]
                    local currentSpaces = hs.spaces.windowSpaces(item.win)
                    if currentSpaces and currentSpaces[1] ~= targetSpace then
                        print("[serial sorter] queueing spaceMove id=" .. tostring(item.win:id()) ..
                              " targetSpace=" .. tostring(targetSpace))
                        table.insert(spaceMoveQueue, {
                            win = item.win,
                            targetSpace = targetSpace,
                            spaceIndex = item.spaceIndex,
                        })
                    else
                        print("[serial sorter] no spaceMove needed id=" .. tostring(item.win:id()))
                    end
                else
                    print("[serial sorter] primarySpaces unavailable id=" .. tostring(item.win:id()))
                end
                processNext(index + 1)
            end)
        else
            print("[serial sorter] processNext " .. index .. " unknown kind=" .. tostring(item.kind))
            processNext(index + 1)
        end
    end

    processNext(1)
end

return M
