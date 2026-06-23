-- modules/launcher.lua
-- Workspace launch orchestration
-- Coordinates app launching, window positioning, and space management

local monitors = require("modules.monitors")
local spaces = require("modules.spaces")
local winutil = require("modules.windows")

local itermApp = require("modules.apps.iterm")
local vscodeApp = require("modules.apps.vscode")
local finderApp = require("modules.apps.finder")
local safariApp = require("modules.apps.safari")

local M = {}

-- Delay between app launch phases (seconds)
M.INTER_APP_DELAY     = 0.5
M.SECONDARY_APP_DELAY = 1.0
M.FULLSCREEN_DELAY    = 0.6

-- Delay between un-fullscreen and move, and between move and re-fullscreen.
-- macOS needs a beat to process fullscreen state changes before
-- `moveToScreen` will actually relocate a window.
M.UNFULLSCREEN_DELAY  = 0.3

--- Move a window to a target screen, respecting its fullscreen state.
--- `hs.window:moveToScreen()` is silently a no-op on fullscreen windows,
--- so we must un-fullscreen, wait, move, wait, then re-fullscreen.
--- Always invokes `done()` exactly once when the sequence completes.
---
--- Branch summary:
---   * win or targetScreen nil           -> done() immediately
---   * already on screen, fs state OK    -> done() immediately
---   * already on screen, needs FS       -> setFullScreen(true), done() after delay
---   * wrong screen, not fullscreen      -> moveToScreen, maybe FS, done()
---   * wrong screen, fullscreen          -> unFS, move, reFS, done()
---
--- @param win hs.window|nil
--- @param targetScreen hs.screen|nil
--- @param wantFullscreen boolean
--- @param done function
local function moveWindowToScreenRespectingFullscreen(win, targetScreen, wantFullscreen, done)
    if not win or not targetScreen then
        done()
        return
    end

    local currentScreen = win:screen()
    local onCorrectScreen = currentScreen and currentScreen:id() == targetScreen:id()
    local isFullScreen = win:isFullScreen()

    -- Already on the correct screen
    if onCorrectScreen then
        if wantFullscreen and not isFullScreen then
            win:setFullScreen(true)
            hs.timer.doAfter(M.FULLSCREEN_DELAY, function()
                done()
            end)
        else
            -- Either fullscreen state already matches, or we don't care
            done()
        end
        return
    end

    -- Wrong screen, not fullscreen: just move
    if not isFullScreen then
        win:moveToScreen(targetScreen, true, true)
        if wantFullscreen then
            hs.timer.doAfter(M.FULLSCREEN_DELAY, function()
                if win and win:isVisible() and not win:isFullScreen() then
                    win:setFullScreen(true)
                end
                done()
            end)
        else
            done()
        end
        return
    end

    -- Wrong screen, fullscreen: un-FS, wait, move, wait, re-FS (if wanted)
    win:setFullScreen(false)
    hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
        if not (win and win:isVisible()) then
            done()
            return
        end
        win:moveToScreen(targetScreen, true, true)
        hs.timer.doAfter(M.UNFULLSCREEN_DELAY, function()
            if wantFullscreen and win and win:isVisible() and not win:isFullScreen() then
                win:setFullScreen(true)
            end
            done()
        end)
    end)
end

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--- Check if windows matching a workspace's patterns already exist.
--- Requires matches from at least 2 different application categories to avoid
--- false positives from a single stray Finder or Safari window.
--- @param workspace table  The workspace config entry
--- @return boolean  true if windows from 2+ different apps match
function M.hasExistingWindows(workspace)
    local patterns = workspace.patterns or {}
    if #patterns == 0 then return false end

    local matchedApps = {}
    local allWindows = winutil.allWindowsAcrossSpaces()
    for _, win in ipairs(allWindows) do
        if win:isStandard() then
            local appName = win:application() and win:application():name() or ""
            local title = (win:title() or ""):lower()
            for _, pattern in ipairs(patterns) do
                if string.find(title, pattern:lower(), 1, true) then
                    matchedApps[appName] = true
                    break
                end
            end
        end
    end

    local matchCount = 0
    for _ in pairs(matchedApps) do matchCount = matchCount + 1 end
    return matchCount >= 2
end

--- Calculate the maximum spaceIndex across all workspaces
--- @param workspacesConfig table  The full workspaces config
--- @return number  Maximum spaceIndex found (minimum 1)
local function getMaxSpaceIndex(workspacesConfig)
    local max = 1
    for _, ws in pairs(workspacesConfig.workspaces) do
        if ws.spaceIndex and ws.spaceIndex > max then
            max = ws.spaceIndex
        end
    end
    return max
end

--- Position windows based on their launch config
--- For array positions (staggered), each window gets an indexed position.
--- @param windows table  Array of hs.window objects
--- @param positionName string  Name of the position preset
--- @param screen hs.screen  Screen to resolve positions against
--- @param positionsConfig table  The positions block from workspaces.json
--- @param positionsModule table  The positions module (provides resolve function)
--- @param startIndex number|nil  Starting index for array positions (0-based from config, converted to 1-based)
local function positionWindows(windows, positionName, screen, positionsConfig, positionsModule, startIndex)
    if not windows or #windows == 0 or not positionName then return end

    -- Warn if window count exceeds defined positions (auto-offsets will be used)
    local preset = positionsConfig and positionsConfig[positionName]
    if preset and type(preset) == "table" and #preset > 0 then
        local totalIndex = (startIndex or 0) + #windows
        if totalIndex > #preset then
            print("[launcher] Warning: " .. #windows .. " windows for position '"
                .. positionName .. "' exceeds " .. #preset
                .. " defined positions; auto-offset positions will be used for overflow")
        end
    end

    for i, win in ipairs(windows) do
        -- For staggered positions, index selects which rect from the array
        -- Config uses 0-based index, positions.resolve uses 1-based
        local idx = (startIndex or 0) + i
        local frame = positionsModule.resolve(positionName, screen, positionsConfig, idx)
        if frame and win and win.setFrame then
            win:setFrame(frame)
        end
    end
end

--- Position a single window at a specific index within a position preset
--- @param win hs.window  The window to position
--- @param positionName string  Name of the position preset
--- @param screen hs.screen  Screen to resolve positions against
--- @param positionsConfig table  The positions block from workspaces.json
--- @param positionsModule table  The positions module (provides resolve function)
--- @param index number|nil  1-based index for array positions
local function positionWindow(win, positionName, screen, positionsConfig, positionsModule, index)
    if not win or not positionName then return end

    local frame = positionsModule.resolve(positionName, screen, positionsConfig, index)
    if frame and win.setFrame then
        win:setFrame(frame)
    end
end

--------------------------------------------------------------------------------
-- PHASE 2: PRIMARY MONITOR APP LAUNCHERS
--------------------------------------------------------------------------------

--- Launch apps on the primary monitor sequentially
--- Order: Finder -> iTerm -> VS Code -> Safari
--- @param workspace table  The workspace config entry
--- @param screen hs.screen  Primary screen
--- @param positionsConfig table  Positions block from workspaces.json
--- @param positionsModule table  The positions module (provides resolve function)
--- @param callback function  callback() called when all apps launched
local function launchPrimaryApps(workspace, screen, positionsConfig, positionsModule, callback)
    local launch = workspace.launch or {}
    local homeDir = workspace.homeDir

    -- Track the first iTerm window for final focus
    local firstItermWindow = nil

    -- Build launch queue: each entry is { launcher, config, positioner }
    local queue = {}

    -- 1. Finder windows
    if launch.finder and #launch.finder > 0 then
        table.insert(queue, {
            name = "Finder",
            fn = function(cb)
                finderApp.launch(launch.finder, screen, homeDir, function(windows)
                    -- Match Finder windows to config entries by directory name in title.
                    -- Finder shows the folder name in the window title.
                    local usedWindows = {}
                    for _, entry in ipairs(launch.finder) do
                        local dirName = entry.path and entry.path:match("([^/]+)/?$") or nil
                        local matched = false
                        if dirName then
                            for j, win in ipairs(windows) do
                                if not usedWindows[j] then
                                    local title = (win:title() or ""):lower()
                                    if title == dirName:lower() or string.find(title, dirName:lower(), 1, true) then
                                        local idx = (entry.index or 0) + 1
                                        positionWindow(win, entry.position, screen, positionsConfig, positionsModule, idx)
                                        usedWindows[j] = true
                                        matched = true
                                        break
                                    end
                                end
                            end
                        end
                        -- Fallback: use creation order for unmatched entries
                        if not matched then
                            for j, win in ipairs(windows) do
                                if not usedWindows[j] then
                                    local idx = (entry.index or 0) + 1
                                    positionWindow(win, entry.position, screen, positionsConfig, positionsModule, idx)
                                    usedWindows[j] = true
                                    break
                                end
                            end
                        end
                    end
                    cb()
                end)
            end
        })
    end

    -- 2. iTerm windows
    if launch.iterm then
        table.insert(queue, {
            name = "iTerm",
            fn = function(cb)
                itermApp.launch(launch.iterm, screen, homeDir, function(windows)
                    positionWindows(windows, launch.iterm.position, screen, positionsConfig, positionsModule)
                    if #windows > 0 then
                        firstItermWindow = windows[1]
                    end
                    cb()
                end)
            end
        })
    end

    -- 3. VS Code
    if launch.vscode then
        table.insert(queue, {
            name = "VS Code",
            fn = function(cb)
                vscodeApp.launch(launch.vscode, screen, homeDir, function(windows)
                    if #windows > 0 then
                        positionWindow(windows[1], launch.vscode.position, screen, positionsConfig, positionsModule, 1)
                    end
                    cb()
                end)
            end
        })
    end

    -- 4. Safari
    if launch.safari then
        table.insert(queue, {
            name = "Safari",
            fn = function(cb)
                safariApp.launch(launch.safari, screen, homeDir, function(windows)
                    -- Safari windows don't get positioned (they stay where created)
                    -- unless a position is specified
                    if launch.safari.position and #windows > 0 then
                        positionWindow(windows[1], launch.safari.position, screen, positionsConfig, positionsModule, 1)
                    end
                    cb()
                end)
            end
        })
    end

    -- Execute queue sequentially with delays between each
    local function processQueue(index)
        if index > #queue then
            callback(firstItermWindow)
            return
        end

        local entry = queue[index]
        entry.fn(function()
            hs.timer.doAfter(M.INTER_APP_DELAY, function()
                processQueue(index + 1)
            end)
        end)
    end

    if #queue > 0 then
        processQueue(1)
    else
        callback(nil)
    end
end

--------------------------------------------------------------------------------
-- PHASE 3: SECONDARY MONITOR APPS
--------------------------------------------------------------------------------

--- Launch and position the apps for a single secondary descriptor.
--- A "secondary descriptor" is `{name=..., screen=..., config=...}` as
--- returned by `monitors.findSecondaries` (or synthesized by
--- `M.launchMonitor`).
--- @param secondary table  { name, screen, config }
--- @param callback function|nil  callback() called when done
local function launchAppsForSecondary(secondary, callback)
    if not secondary or not secondary.screen then
        if callback then callback() end
        return
    end

    local apps = (secondary.config or {}).apps or {}
    local doFullscreen = (secondary.config or {}).fullscreen == true

    local appQueue = {}
    for _, appName in ipairs(apps) do
        table.insert(appQueue, {
            appName = appName,
            screen = secondary.screen,
            fullscreen = doFullscreen,
        })
    end

    local function processApp(index)
        if index > #appQueue then
            if callback then callback() end
            return
        end

        local entry = appQueue[index]

        hs.application.launchOrFocus(entry.appName)

        hs.timer.doAfter(M.SECONDARY_APP_DELAY, function()
            local win = winutil.windowForApp(entry.appName)
            moveWindowToScreenRespectingFullscreen(win, entry.screen, entry.fullscreen, function()
                processApp(index + 1)
            end)
        end)
    end

    if #appQueue > 0 then
        processApp(1)
    else
        if callback then callback() end
    end
end

--- Launch and position apps on all secondary monitors in sequence.
--- @param monitorsConfig table  The monitors config
--- @param callback function  callback() called when done
local function launchSecondaryApps(monitorsConfig, callback)
    local secondaries = monitors.findSecondaries(monitorsConfig)
    if #secondaries == 0 then
        if callback then callback() end
        return
    end

    local function processSecondary(index)
        if index > #secondaries then
            if callback then callback() end
            return
        end
        launchAppsForSecondary(secondaries[index], function()
            processSecondary(index + 1)
        end)
    end
    processSecondary(1)
end

--- Launch the apps assigned to a single named monitor.
--- Output goes to stdout (read by `hs -c` for shell IPC). No on-screen alerts:
--- `ws lg-left` users see results in the terminal.
--- @param monitorName string
--- @param monitorsConfig table
function M.launchMonitor(monitorName, monitorsConfig)
    if not monitorName or monitorName == "" then
        print("launchMonitor: missing monitor name")
        return
    end
    local monitorCfg = (monitorsConfig and monitorsConfig.monitors or {})[monitorName]
    if not monitorCfg then
        print("Monitor not found: " .. monitorName)
        return
    end
    local apps = monitorCfg.apps or {}
    if #apps == 0 then
        print("Monitor '" .. monitorName .. "' has no apps")
        return
    end
    local screen = monitors.getScreenForMonitor(monitorName, monitorsConfig)
    if not screen then
        print("Monitor '" .. monitorName .. "' not connected")
        return
    end
    print("Launching monitor: " .. monitorName .. "...")
    launchAppsForSecondary({ name = monitorName, screen = screen, config = monitorCfg }, function()
        print("Monitor '" .. monitorName .. "' launched")
    end)
end

--- Close windows of apps assigned to a monitor.
--- Output goes to stdout (read by `hs -c` for shell IPC). No on-screen alerts:
--- `ws close lg-left` users see results in the terminal.
--- @param monitorName string
--- @param monitorsConfig table
function M.closeMonitor(monitorName, monitorsConfig)
    if not monitorName or monitorName == "" then
        print("closeMonitor: missing monitor name")
        return nil
    end
    local monitorCfg = (monitorsConfig and monitorsConfig.monitors or {})[monitorName]
    if not monitorCfg then
        print("Monitor not found: " .. monitorName)
        return nil
    end
    local apps = monitorCfg.apps or {}
    if #apps == 0 then
        print("Monitor '" .. monitorName .. "' has no apps")
        print("[launcher] closeMonitor: closed 0 windows for '" .. monitorName .. "'")
        return 0
    end

    -- Build set of app names (case-insensitive)
    local appSet = {}
    for _, a in ipairs(apps) do appSet[a:lower()] = true end

    local closedCount = 0
    for _, win in ipairs(winutil.allWindowsAcrossSpaces()) do
        if win:isStandard() then
            local app = win:application()
            local appName = app and app:name() or ""
            if appSet[appName:lower()] then
                win:close()
                closedCount = closedCount + 1
            end
        end
    end

    print("Monitor '" .. monitorName .. "' closed (" .. closedCount .. " windows)")
    print("[launcher] closeMonitor: closed " .. closedCount .. " windows for '" .. monitorName .. "'")
    return closedCount
end

--- Close then relaunch a monitor's app set.
function M.restartMonitor(monitorName, monitorsConfig)
    M.closeMonitor(monitorName, monitorsConfig)
    hs.timer.doAfter(M.RESTART_DELAY or 0.5, function()
        M.launchMonitor(monitorName, monitorsConfig)
    end)
end

--- Resolve a position value to a monitor key.
local function findMonitorByPosition(position, monitorsConfig)
    if not position or not monitorsConfig or not monitorsConfig.monitors then return nil end
    for name, m in pairs(monitorsConfig.monitors) do
        if m.position == position then return name end
    end
    return nil
end

function M.launchPosition(position, monitorsConfig)
    local name = findMonitorByPosition(position, monitorsConfig)
    if not name then
        print("No monitor at position '" .. tostring(position) .. "'")
        return
    end
    M.launchMonitor(name, monitorsConfig)
end

function M.closePosition(position, monitorsConfig)
    local name = findMonitorByPosition(position, monitorsConfig)
    if not name then
        print("No monitor at position '" .. tostring(position) .. "'")
        return nil
    end
    return M.closeMonitor(name, monitorsConfig)
end

function M.restartPosition(position, monitorsConfig)
    local name = findMonitorByPosition(position, monitorsConfig)
    if not name then
        print("No monitor at position '" .. tostring(position) .. "'")
        return
    end
    M.restartMonitor(name, monitorsConfig)
end

--------------------------------------------------------------------------------
-- LIST WORKSPACES
--------------------------------------------------------------------------------

--- Print inline help for `ws` / `launchWorkspace` IPC: usage, workspaces (with
--- a `(launched)` marker for any whose `hasExistingWindows` is true), and
--- monitors (key, role, and fullscreen flag).
---
--- The launched-status check reuses `M.hasExistingWindows` so the help screen
--- reports the same truth as the launcher's own 'already launched' guard.
---
--- @param workspacesConfig table  The full workspaces config
--- @param monitorsConfig table|nil  The monitors config (optional)
--- @return table  Array of workspace name strings
function M.listWorkspaces(workspacesConfig, monitorsConfig)
    local lines = {}
    table.insert(lines, "ws -- Hammerspoon workspace control")
    table.insert(lines, "")
    table.insert(lines, "Usage:")
    table.insert(lines, "  ws                       show this help")
    table.insert(lines, "  ws <name>                launch workspace, monitor, or position")
    table.insert(lines, "  ws close <name>          close")
    table.insert(lines, "  ws restart <name>        close + launch")
    table.insert(lines, "  ws screens               list physical screens")
    table.insert(lines, "  ws fix                   re-sort all windows")
    table.insert(lines, "")

    -- Workspaces section
    local entries = {}
    for name, ws in pairs((workspacesConfig or {}).workspaces or {}) do
        local launched = false
        -- Guard with pcall: hs.window.allWindows can fail in odd states
        local ok, result = pcall(M.hasExistingWindows, ws)
        if ok then launched = result end
        table.insert(entries, { name = name, launched = launched })
    end
    table.sort(entries, function(a, b) return a.name < b.name end)

    table.insert(lines, "Workspaces:")
    if #entries == 0 then
        table.insert(lines, "  (none defined)")
    else
        for _, e in ipairs(entries) do
            if e.launched then
                table.insert(lines, "  * " .. e.name .. "    (launched)")
            else
                table.insert(lines, "    " .. e.name)
            end
        end
    end
    table.insert(lines, "")

    -- Monitors section
    table.insert(lines, "Monitors:")
    local monitorMap = ((monitorsConfig or {}).monitors) or {}
    local monitorKeys = {}
    for k in pairs(monitorMap) do table.insert(monitorKeys, k) end
    table.sort(monitorKeys)
    if #monitorKeys == 0 then
        table.insert(lines, "  (none configured)")
    else
        -- Compute column widths for name and position bracket
        local maxName = 0
        local maxPos = 0
        for _, key in ipairs(monitorKeys) do
            if #key > maxName then maxName = #key end
            local p = monitorMap[key].position
            if p then
                local pl = #("[" .. p .. "]")
                if pl > maxPos then maxPos = pl end
            end
        end
        for _, key in ipairs(monitorKeys) do
            local m = monitorMap[key]
            local role = m.role or "unknown"
            local suffix = role
            if m.fullscreen == true then
                suffix = suffix .. ", fullscreen"
            end
            local posBracket = m.position and ("[" .. m.position .. "]") or ""
            local namePad = string.rep(" ", maxName - #key)
            local posPad = string.rep(" ", maxPos == 0 and 0 or (maxPos - #posBracket))
            table.insert(lines, "  " .. key .. namePad .. "  " .. posBracket .. posPad .. " (" .. suffix .. ")")
        end
    end

    local out = table.concat(lines, "\n")
    print(out)
end

--------------------------------------------------------------------------------
-- MAIN LAUNCH FUNCTION
--------------------------------------------------------------------------------

--- Launch a workspace by name
--- Orchestrates the full launch sequence: validate, prepare spaces,
--- launch primary apps, launch secondary apps, focus.
---
--- @param workspaceName string  Name of the workspace to launch
--- @param workspacesConfig table  The full workspaces config
--- @param monitorsConfig table  The full monitors config
--- @param positionsModule table  The positions module (provides resolve function)
--- @param opts table|nil  Optional flags. `opts.force == true` bypasses the
---                        `hasExistingWindows` 'already launched' guard.
function M.launch(workspaceName, workspacesConfig, monitorsConfig, positionsModule, opts)
    if not workspaceName or not workspacesConfig then
        print("Launcher: missing workspace name or config")
        return
    end

    --------------------------------------------------------------------------
    -- Phase 0: Validate
    --------------------------------------------------------------------------

    -- Find workspace by name (hash lookup on keyed object)
    local workspace = (workspacesConfig.workspaces or {})[workspaceName]

    if not workspace then
        print("Workspace not found: " .. workspaceName)
        return
    end

    -- Find primary monitor
    local primaryScreen = monitors.findPrimary(monitorsConfig)
    if not primaryScreen then
        print("Primary monitor not connected - cannot launch workspace")
        return
    end

    -- Check for existing windows (duplicate prevention).
    -- Bypass when opts.force is set (used by restartWorkspace).
    if not (opts and opts.force) and M.hasExistingWindows(workspace) then
        print("Workspace '" .. workspaceName .. "' appears already launched")
        return
    end

    print("Launching workspace: " .. workspaceName .. "...")

    --------------------------------------------------------------------------
    -- Phase 1: Prepare Spaces
    --------------------------------------------------------------------------

    local maxSpaceIndex = getMaxSpaceIndex(workspacesConfig)
    spaces.ensureCount(primaryScreen, maxSpaceIndex)

    -- Navigate to this workspace's space
    local primarySpaces = spaces.getSpacesForScreen(primaryScreen)
    if primarySpaces and workspace.spaceIndex and #primarySpaces >= workspace.spaceIndex then
        spaces.gotoSpace(primarySpaces[workspace.spaceIndex])
    end

    -- Brief delay for space transition
    hs.timer.doAfter(0.5, function()

        --------------------------------------------------------------------
        -- Phase 2: Primary monitor windows
        --------------------------------------------------------------------

        local positionsConfig = workspacesConfig.positions or {}

        launchPrimaryApps(workspace, primaryScreen, positionsConfig, positionsModule, function(firstItermWindow)

            ----------------------------------------------------------------
            -- Phase 3: Secondary monitor apps
            ----------------------------------------------------------------

            launchSecondaryApps(monitorsConfig, function()

                ------------------------------------------------------------
                -- Phase 4: Focus
                ------------------------------------------------------------

                -- Navigate back to workspace space
                local currentSpaces = spaces.getSpacesForScreen(primaryScreen)
                if currentSpaces and workspace.spaceIndex and #currentSpaces >= workspace.spaceIndex then
                    spaces.gotoSpace(currentSpaces[workspace.spaceIndex])
                end

                -- Focus first iTerm window if available
                if firstItermWindow then
                    hs.timer.doAfter(0.3, function()
                        firstItermWindow:focus()
                    end)
                end

                print("Workspace '" .. workspaceName .. "' launched")
            end)
        end)
    end)
end

--------------------------------------------------------------------------------
-- CLOSE WORKSPACE
--------------------------------------------------------------------------------

--- Close all standard windows whose titles match a workspace's patterns.
--- Mirrors `M.launch`: looks up the workspace by name, then iterates
--- all windows across Spaces and closes any standard window whose title
--- contains one of the workspace's patterns (case-insensitive substring).
--- Only closes matching windows -- never quits whole apps -- so unrelated
--- windows of the same application remain open.
---
--- @param workspaceName string  Name of the workspace to close
--- @param workspacesConfig table  The full workspaces config
function M.closeWorkspace(workspaceName, workspacesConfig)
    if not workspaceName or not workspacesConfig then
        print("Launcher: missing workspace name or config")
        return nil
    end

    local workspace = (workspacesConfig.workspaces or {})[workspaceName]

    if not workspace then
        print("Workspace not found: " .. workspaceName)
        return nil
    end

    local patterns = workspace.patterns or {}
    if #patterns == 0 then
        print("Workspace '" .. workspaceName .. "' has no patterns")
        print("[launcher] closeWorkspace: closed 0 windows for '" .. workspaceName .. "'")
        return 0
    end

    local closedCount = 0
    for _, win in ipairs(winutil.allWindowsAcrossSpaces()) do
        if win:isStandard() then
            local title = (win:title() or ""):lower()
            for _, pattern in ipairs(patterns) do
                if string.find(title, pattern:lower(), 1, true) then
                    win:close()
                    closedCount = closedCount + 1
                    break
                end
            end
        end
    end

    print("Workspace '" .. workspaceName .. "' closed (" .. closedCount .. " windows)")
    print("[launcher] closeWorkspace: closed " .. closedCount .. " windows for '" .. workspaceName .. "'")
    return closedCount
end

--------------------------------------------------------------------------------
-- RESTART WORKSPACE
--------------------------------------------------------------------------------

--- Delay between close and relaunch (seconds). Gives windows time to disappear
--- so the launcher's existence checks see a clean slate.
M.RESTART_DELAY = 0.5

--- Close a workspace and relaunch it in one operation. Bypasses the
--- `hasExistingWindows` 'already launched' guard via `opts.force`.
---
--- @param workspaceName string  Name of the workspace to restart
--- @param workspacesConfig table  The full workspaces config
--- @param monitorsConfig table  The full monitors config
--- @param positionsModule table  The positions module (provides resolve function)
function M.restartWorkspace(workspaceName, workspacesConfig, monitorsConfig, positionsModule)
    if not workspaceName or not workspacesConfig then
        print("Launcher: missing workspace name or config")
        return
    end

    M.closeWorkspace(workspaceName, workspacesConfig)

    hs.timer.doAfter(M.RESTART_DELAY, function()
        M.launch(workspaceName, workspacesConfig, monitorsConfig, positionsModule, { force = true })
    end)
end

return M
