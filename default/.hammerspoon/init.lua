-- ~/.hammerspoon/init.lua
-- Default Hammerspoon configuration
-- Uses shared modules for monitor switching and discovery

--------------------------------------------------------------------------------
-- MODULE LOADING
--------------------------------------------------------------------------------

local config = require("modules.config")
local monitors = require("modules.monitors")
local positions = require("modules.positions")
local launcher = require("modules.launcher")
local screenFocus = require("modules.screen_focus")
local sorter = require("modules.sorter")

-- Enable IPC for command-line access (hs -c "...")
require("hs.ipc")

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local configDir = config.getConfigDir()
local monitorsConfig = config.loadConfig("monitors.json", false) or { monitors = {} }
local workspacesConfig = config.loadConfig("workspaces.json", false) or { workspaces = {}, positions = {} }

-- Validate config on load
local valid, err = config.validateMonitors(monitorsConfig)
if not valid then
    hs.alert.show("monitors.json validation error: " .. (err or "unknown"))
end

--------------------------------------------------------------------------------
-- MONITOR HELPERS
--------------------------------------------------------------------------------

local focusScreen = screenFocus.focusScreen

--------------------------------------------------------------------------------
-- GLOBAL FUNCTIONS (accessible via IPC)
--------------------------------------------------------------------------------

--- List all connected screens (for monitor discovery)
--- Usage: hs -c "listScreens()"
function listScreens()
    return monitors.listScreens()
end

--- Re-sort all windows to their configured monitors.
--- Usage: hs -c "resortAllWindows()"
function resortAllWindows()
    return sorter.resortAll(monitorsConfig, workspacesConfig, positions)
end

-- Validate cross-namespace uniqueness. If it fails, we refuse to define the
-- dispatch globals so that `ws <anything>` fails fast until the config is fixed.
local nsValid, nsCollisions = config.validateNamespaces(monitorsConfig, workspacesConfig)
if not nsValid then
    local body = "ws namespace collisions:\n\n  - " .. table.concat(nsCollisions, "\n  - ")
    print(body)
    if hs.dialog and hs.dialog.blockAlert then
        hs.dialog.blockAlert("ws config collisions", body, "OK")
    else
        hs.alert.show("ws config collisions (see console)", 5)
    end
else
    --- Classify a name across workspaces, monitors, and positions and dispatch.
    local function classify(name)
        if not name or name == "" then return nil end
        if (workspacesConfig.workspaces or {})[name] then return "workspace" end
        if (monitorsConfig.monitors or {})[name] then return "monitor" end
        for _, m in pairs(monitorsConfig.monitors or {}) do
            if m.position == name then return "position" end
        end
        return nil
    end

    function launchWorkspace(name)
        if not name or name == "" then
            return listWorkspaces()
        end
        launcher.launch(name, workspacesConfig, monitorsConfig, positions)
    end

    function closeWorkspace(name)
        return launcher.closeWorkspace(name, workspacesConfig)
    end

    function restartWorkspace(name)
        return launcher.restartWorkspace(name, workspacesConfig, monitorsConfig, positions)
    end

    function listWorkspaces()
        return launcher.listWorkspaces(workspacesConfig, monitorsConfig)
    end

    function wsDispatch(name)
        local kind = classify(name)
        if kind == "workspace" then
            launcher.launch(name, workspacesConfig, monitorsConfig, positions)
        elseif kind == "monitor" then
            launcher.launchMonitor(name, monitorsConfig)
        elseif kind == "position" then
            launcher.launchPosition(name, monitorsConfig)
        else
            print("ws: unknown name '" .. tostring(name) .. "' (run 'ws' to see available names)")
        end
    end

    function wsCloseDispatch(name)
        local kind = classify(name)
        if kind == "workspace" then
            launcher.closeWorkspace(name, workspacesConfig)
        elseif kind == "monitor" then
            launcher.closeMonitor(name, monitorsConfig)
        elseif kind == "position" then
            launcher.closePosition(name, monitorsConfig)
        else
            print("ws: unknown name '" .. tostring(name) .. "' (run 'ws' to see available names)")
        end
    end

    function wsRestartDispatch(name)
        local kind = classify(name)
        if kind == "workspace" then
            launcher.restartWorkspace(name, workspacesConfig, monitorsConfig, positions)
        elseif kind == "monitor" then
            launcher.restartMonitor(name, monitorsConfig)
        elseif kind == "position" then
            launcher.restartPosition(name, monitorsConfig)
        else
            print("ws: unknown name '" .. tostring(name) .. "' (run 'ws' to see available names)")
        end
    end
end

-- Register URL handler for workspace launching
-- Usage: open "hammerspoon://launchWorkspace?name=macos-setup"
hs.urlevent.bind("launchWorkspace", function(eventName, params)
    if params and params.name then
        launchWorkspace(params.name)
    end
end)

--------------------------------------------------------------------------------
-- HOTKEYS
--------------------------------------------------------------------------------

-- Cycle between all monitors: Ctrl+Alt+Cmd+Tab
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "tab", function()
    local currentScreen = hs.mouse.getCurrentScreen()
    local nextScreen = currentScreen:next()
    focusScreen(nextScreen)
end)

-- Directional monitor focus: Ctrl+Alt+Cmd+Arrow
-- Uses `position` field from monitors.json entries.
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "left", function()
    if not monitors.focusByPosition("left", monitorsConfig) then
        hs.alert.show("No monitor left")
    end
end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "right", function()
    if not monitors.focusByPosition("right", monitorsConfig) then
        hs.alert.show("No monitor right")
    end
end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "up", function()
    if not monitors.focusByPosition("up", monitorsConfig) then
        hs.alert.show("No monitor up")
    end
end)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "down", function()
    if not monitors.focusByPosition("down", monitorsConfig) then
        hs.alert.show("No monitor down")
    end
end)

-- Reload config: Ctrl+Alt+Cmd+Shift+R
hs.hotkey.bind({"ctrl", "alt", "cmd", "shift"}, "r", function()
    hs.reload()
end)

-- Monitor discovery: Ctrl+Alt+Cmd+Shift+L
hs.hotkey.bind({"ctrl", "alt", "cmd", "shift"}, "l", function()
    listScreens()
end)

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

-- Auto-reload when config files change
hs.pathwatcher.new(configDir, function(files)
    for _, file in ipairs(files) do
        if string.find(file, "%.lua$") or string.find(file, "%.json$") then
            hs.reload()
            return
        end
    end
end):start()

-- Auto-reload when module files change
local modulesDir = configDir .. "modules/"
hs.pathwatcher.new(modulesDir, function(files)
    for _, file in ipairs(files) do
        if string.find(file, "%.lua$") then
            hs.reload()
            return
        end
    end
end):start()

-- Auto-reload when app module files change
local appsDir = modulesDir .. "apps/"
hs.pathwatcher.new(appsDir, function(files)
    for _, file in ipairs(files) do
        if string.find(file, "%.lua$") then
            hs.reload()
            return
        end
    end
end):start()

hs.alert.show("Hammerspoon config loaded", 1)

-- Show monitor info on startup
hs.timer.doAfter(2, function()
    local screens = hs.screen.allScreens()
    local message = "Monitors detected: " .. #screens
    if #screens > 1 then
        message = message .. "\nCtrl+Alt+Cmd+Tab = Cycle monitors"
    end
    message = message .. "\nCtrl+Alt+Cmd+Shift+L = List screens"
    hs.alert.show(message, 3)
end)
