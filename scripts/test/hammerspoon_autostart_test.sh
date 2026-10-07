#!/bin/bash
# Tests for the monitors.json `autostart` flag: launcher.autostartMonitors and
# config.validateMonitors, loaded under the mise-pinned lua with every hs.* call
# the code reaches replaced by a stub. Timers fire synchronously, so a launch
# sequence completes before the harness reads what it recorded.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HS_DIR="$REPO_ROOT/default/.hammerspoon"

if ! command -v lua >/dev/null 2>&1; then
    echo "FAIL: lua not on PATH (pinned in mise.toml)"
    exit 1
fi

cd "$HS_DIR" || exit 1

lua - <<'LUA'
package.path = "./?.lua;" .. package.path

local failures = 0
local function check(name, cond)
    if cond then
        print("PASS: " .. name)
    else
        print("FAIL: " .. name)
        failures = failures + 1
    end
end

-- Stub state, reset per scenario.
local running, launched, moved, printed, connected

local function newWindow(appName)
    return {
        screen = function() return { id = function() return "other" end } end,
        isFullScreen = function() return false end,
        isStandard = function() return true end,
        moveToScreen = function() table.insert(moved, appName) end,
        setFullScreen = function() end,
    }
end

hs = {
    timer = { doAfter = function(_, fn) fn() end },
    application = {
        get = function(name)
            if not running[name] then return nil end
            local w = newWindow(name)
            return {
                mainWindow = function() return w end,
                focusedWindow = function() return w end,
                visibleWindows = function() return { w } end,
                allWindows = function() return { w } end,
            }
        end,
        launchOrFocus = function(name)
            table.insert(launched, name)
            running[name] = true
        end,
    },
    json = { decode = function() return {} end },
    alert = { show = function() end },
}
package.loaded["hs.json"] = hs.json

local realPrint = print
local function capturePrint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    table.insert(printed, table.concat(parts, " "))
end

package.loaded["modules.monitors"] = {
    getScreenForMonitor = function(name)
        if connected[name] then
            return { id = function() return "screen-" .. name end }
        end
        return nil
    end,
}
package.loaded["modules.spaces"] = {}
for _, m in ipairs({ "iterm", "vscode", "finder", "safari" }) do
    package.loaded["modules.apps." .. m] = {}
end

local launcher = require("modules.launcher")
local config = require("modules.config")

local function run(cfg, runningApps, connectedMonitors)
    running, launched, moved, printed, connected = {}, {}, {}, {}, {}
    for _, a in ipairs(runningApps) do running[a] = true end
    for _, m in ipairs(connectedMonitors) do connected[m] = true end
    print = capturePrint
    launcher.autostartMonitors(cfg)
    print = realPrint
end

local function list(t) return table.concat(t, ",") end

-- Connected autostart monitor: only the missing app is launched and placed.
local cfg = { monitors = {
    left = { pattern = "LG", apps = { "Slack", "Mail" }, autostart = true },
} }
run(cfg, { "Slack" }, { "left" })
check("launches only the app that is not running", list(launched) == "Mail")
check("places only the launched app", list(moved) == "Mail")
check("leaves the monitor config's apps unchanged", list(cfg.monitors.left.apps) == "Slack,Mail")

-- Every app running: nothing launched, nothing moved.
run(cfg, { "Slack", "Mail" }, { "left" })
check("all running: launches nothing", #launched == 0)
check("all running: moves nothing", #moved == 0)

-- Disconnected monitor: skipped with a printed line naming it.
run(cfg, {}, {})
check("disconnected: launches nothing", #launched == 0)
check("disconnected: prints a line naming the monitor",
    printed[1] ~= nil and printed[1]:find("'left'", 1, true) ~= nil)

-- autostart absent or false: nothing launched.
run({ monitors = {
    a = { pattern = "A", apps = { "Notes" } },
    b = { pattern = "B", apps = { "Music" }, autostart = false },
} }, {}, { "a", "b" })
check("autostart absent or false: launches nothing", #launched == 0)

-- Several monitors run one after another, a disconnected one in between.
run({ monitors = {
    a = { pattern = "A", apps = { "Notes" }, autostart = true },
    b = { pattern = "B", apps = { "Music" }, autostart = true },
    c = { pattern = "C", apps = { "Mail" }, autostart = true },
} }, {}, { "a", "c" })
check("visits every connected autostart monitor", list(launched) == "Notes,Mail")

-- Schema validation.
local function validate(autostart)
    return config.validateMonitors({ monitors = {
        m = { pattern = "M", autostart = autostart },
    } })
end
check("validation accepts autostart true", (validate(true)))
check("validation accepts autostart false", (validate(false)))
check("validation accepts autostart absent", (validate(nil)))
local ok, err = validate("yes")
check("validation rejects a string autostart", not ok and err:find("autostart", 1, true) ~= nil)
check("validation rejects a numeric autostart", not (validate(1)))

os.exit(failures == 0 and 0 or 1)
LUA
