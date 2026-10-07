#!/bin/bash
# Tests for sorter.reorderFullscreen and spaces.fullscreenSpaceOrder, loaded
# under the mise-pinned lua against a model of one screen's Spaces: leaving
# fullscreen removes a window's Space, and entering fullscreen appends a new
# Space at the right. Timers queue rather than fire, so the harness can tell
# whether a fullscreen transition starts while another is still in flight.

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

-- Model state, reset per scenario.
local spaceList, nextSpace, windows, timers, toggles, inFlight, overlapped

local SCREEN = { id = function() return "side" end, getUUID = function() return "uuid-side" end }

local function spaceOf(winId)
    for i, s in ipairs(spaceList) do
        if s.window == winId then return i end
    end
end

local function newWindow(id, appName)
    local w = { fullscreen = true }
    w.id = function() return id end
    w.isStandard = function() return true end
    w.application = function() return { name = function() return appName end } end
    w.screen = function() return SCREEN end
    w.isFullScreen = function() return w.fullscreen end
    w.moveToScreen = function() end
    w.setFullScreen = function(_, on)
        if inFlight then overlapped = true end
        inFlight = true
        table.insert(toggles, (on and "+" or "-") .. appName)
        w.fullscreen = on
        if on then
            nextSpace = nextSpace + 1
            table.insert(spaceList, { id = nextSpace, kind = "fullscreen", window = id })
        else
            table.remove(spaceList, spaceOf(id))
        end
    end
    return w
end

hs = {
    timer = { doAfter = function(_, fn) table.insert(timers, fn) end },
    spaces = {
        spacesForScreen = function()
            local ids = {}
            for _, s in ipairs(spaceList) do table.insert(ids, s.id) end
            return ids
        end,
        spaceType = function(id)
            for _, s in ipairs(spaceList) do
                if s.id == id then return s.kind end
            end
        end,
        windowsForSpace = function(id)
            for _, s in ipairs(spaceList) do
                if s.id == id then return { s.window } end
            end
            return {}
        end,
    },
}

package.loaded["modules.monitors"] = {
    getScreenForMonitor = function(name)
        if name == "side" then return SCREEN end
    end,
}
package.loaded["modules.windows"] = {
    windowsById = function() return windows end,
}

local sorter = require("modules.sorter")
local spaces = require("modules.spaces")

-- Lay out the screen: one desktop Space, then one fullscreen Space per app
-- name, left to right. Returns nothing; the model holds the state.
local function layout(appNames)
    spaceList, nextSpace, windows, timers, toggles = { { id = 1, kind = "user" } }, 1, {}, {}, {}
    inFlight, overlapped = false, false
    for i, appName in ipairs(appNames) do
        local id = 100 + i
        windows[id] = newWindow(id, appName)
        nextSpace = nextSpace + 1
        table.insert(spaceList, { id = nextSpace, kind = "fullscreen", window = id })
    end
end

local function order()
    local names = {}
    for _, s in ipairs(spaces.fullscreenSpaceOrder(SCREEN)) do
        table.insert(names, windows[s.window].application():name())
    end
    return table.concat(names, ",")
end

local function reorder(apps)
    local cfg = { monitors = {
        primary = { role = "primary" },
        side = { fullscreen = true, apps = apps },
    } }
    local rebuilt
    toggles, inFlight, overlapped = {}, false, false
    sorter.reorderFullscreen(cfg, function(n) rebuilt = n end)
    while #timers > 0 do
        local fn = table.remove(timers, 1)
        inFlight = false
        fn()
    end
    return rebuilt
end

-- fullscreenSpaceOrder skips the desktop Space and pairs each fullscreen
-- Space with its window.
layout({ "Slack", "Mail" })
check("fullscreenSpaceOrder lists fullscreen Spaces left to right", order() == "Slack,Mail")

-- A late-launched app at the far right moves into its apps slot.
layout({ "Slack", "Notes", "Mail" })
local rebuilt = reorder({ "Slack", "Mail", "Notes" })
check("out of order: ends in apps order", order() == "Slack,Mail,Notes")
check("out of order: never toggles the window left of the first mismatch",
    not table.concat(toggles, ","):find("Slack", 1, true))
check("out of order: rebuilds from the first mismatch onward",
    table.concat(toggles, ",") == "-Notes,-Mail,+Mail,+Notes")
check("out of order: reports the rebuilt count", rebuilt == 2)
check("out of order: no transition starts while another is in flight", not overlapped)

-- Already in order: nothing toggles.
rebuilt = reorder({ "Slack", "Mail", "Notes" })
check("in order: toggles nothing", #toggles == 0)
check("in order: reports zero rebuilt", rebuilt == 0)

-- Unlisted apps follow the listed ones in their current relative order.
layout({ "Zoom", "Mail", "Teams", "Slack" })
reorder({ "Slack", "Mail" })
check("unlisted apps follow listed ones in current order", order() == "Slack,Mail,Zoom,Teams")
check("unlisted: no transition starts while another is in flight", not overlapped)

-- An app with two fullscreen windows keeps them together in its slot.
layout({ "Mail", "Code", "Slack", "Code" })
reorder({ "Code", "Slack", "Mail" })
check("multi-window app: windows grouped in its slot", order() == "Code,Code,Slack,Mail")
local ids = {}
for _, s in ipairs(spaces.fullscreenSpaceOrder(SCREEN)) do table.insert(ids, s.window) end
check("multi-window app: leftmost window keeps the slot's first position", ids[1] == 102 and ids[2] == 104)

-- An app in apps that is not running is skipped.
layout({ "Mail", "Slack" })
reorder({ "Slack", "Notes", "Mail" })
check("app not running: remaining apps in order", order() == "Slack,Mail")

-- A window that cannot be resolved past the first mismatch leaves the
-- monitor untouched.
layout({ "Mail", "Slack" })
windows[101] = nil
reorder({ "Slack", "Mail" })
check("unresolved window: toggles nothing", #toggles == 0)

os.exit(failures == 0 and 0 or 1)
LUA
