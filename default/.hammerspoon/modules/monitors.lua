-- modules/monitors.lua
-- Monitor detection by pattern, role-based lookup, discovery

local M = {}

--- Find a screen by exact name
--- @param name string  Exact screen name to match
--- @return hs.screen|nil
function M.findByName(name)
    if not name or name == "" then return nil end
    local screens = hs.screen.allScreens()
    for _, screen in ipairs(screens) do
        if screen:name() == name then
            return screen
        end
    end
    return nil
end

--- Find all screens whose name matches a pattern (substring match)
--- @param pattern string  Pattern to match against screen name
--- @return table  Array of hs.screen (possibly empty)
function M.findAllByPattern(pattern)
    local matches = {}
    if not pattern or pattern == "" then return matches end
    for _, screen in ipairs(hs.screen.allScreens()) do
        if string.find(screen:name(), pattern, 1, true) then
            table.insert(matches, screen)
        end
    end
    return matches
end

--- Find a screen by pattern (substring match).
--- Thin wrapper around findAllByPattern returning the first match, kept
--- only for hypothetical external callers. Internal callers should use
--- findAllByPattern plus position-aware disambiguation instead.
--- @param pattern string  Pattern to match against screen name
--- @return hs.screen|nil
function M.findByPattern(pattern)
    local matches = M.findAllByPattern(pattern)
    return matches[1]
end

--- Pick a single screen from a list of matches using a position hint.
--- Emits a print() warning (never an alert) on ties or missing position
--- with multiple matches; this code path is reachable from shell IPC
--- where popups are banned.
--- @param matches table         Array of hs.screen
--- @param position string|nil   "left"|"right"|"up"|"down" or nil
--- @param entryName string      Monitor entry name for diagnostics
--- @return hs.screen|nil
local function pickByPosition(matches, position, entryName)
    if not matches or #matches == 0 then return nil end
    if #matches == 1 then return matches[1] end

    if not position then
        print(string.format(
            "[monitors] config error: monitor '%s' has no position but pattern matches %d screens",
            tostring(entryName), #matches))
        return matches[1]
    end

    local axis = (position == "left" or position == "right") and "x" or "y"
    local takeLarger = (position == "right" or position == "down")

    local chosen = matches[1]
    for i = 2, #matches do
        local s = matches[i]
        local sv = s:frame()[axis]
        local cv = chosen:frame()[axis]
        if takeLarger then
            if sv > cv then chosen = s end
        else
            if sv < cv then chosen = s end
        end
    end

    local extreme = chosen:frame()[axis]
    local tieCount = 0
    for _, s in ipairs(matches) do
        if s:frame()[axis] == extreme then
            tieCount = tieCount + 1
        end
    end
    if tieCount > 1 then
        print(string.format(
            "[monitors] ambiguous: monitor '%s' at position '%s' has %d tied screens; picking first",
            tostring(entryName), tostring(position), tieCount))
    end
    return chosen
end

--- Find the primary monitor based on monitors config
--- Falls back to the largest screen if no primary pattern matches
--- @param monitorsConfig table  The monitors config (config.monitors)
--- @return hs.screen|nil
function M.findPrimary(monitorsConfig)
    if not monitorsConfig or not monitorsConfig.monitors then return nil end

    -- Look for a monitor with role "primary"
    for name, monitor in pairs(monitorsConfig.monitors) do
        if monitor.role == "primary" then
            if monitor.pattern and monitor.pattern ~= "" then
                local matches = M.findAllByPattern(monitor.pattern)
                local screen = pickByPosition(matches, monitor.position, name)
                if screen then return screen end
            end
            -- Primary defined but pattern doesn't match; fall through to largest
            break
        end
    end

    -- Fallback: return the largest screen
    local screens = hs.screen.allScreens()
    if #screens == 0 then return nil end

    local largest = screens[1]
    local largestArea = largest:frame().w * largest:frame().h

    for _, screen in ipairs(screens) do
        local area = screen:frame().w * screen:frame().h
        if area > largestArea then
            largest = screen
            largestArea = area
        end
    end
    return largest
end

--- Find all secondary monitors based on monitors config
--- @param monitorsConfig table  The monitors config
--- @return table  Array of {name=string, screen=hs.screen, config=table}
function M.findSecondaries(monitorsConfig)
    if not monitorsConfig or not monitorsConfig.monitors then return {} end

    local secondaries = {}
    local seenUUID = {}
    for name, monitor in pairs(monitorsConfig.monitors) do
        if monitor.role == "secondary" then
            local screen = nil
            if monitor.pattern and monitor.pattern ~= "" then
                local matches = M.findAllByPattern(monitor.pattern)
                screen = pickByPosition(matches, monitor.position, name)
            end
            if screen then
                local uuid = screen:getUUID() or tostring(screen:id())
                if seenUUID[uuid] then
                    print(string.format(
                        "[monitors] warning: secondary '%s' resolves to same screen as '%s'; dropping duplicate",
                        tostring(name), tostring(seenUUID[uuid])))
                else
                    seenUUID[uuid] = name
                    table.insert(secondaries, {
                        name = name,
                        screen = screen,
                        config = monitor
                    })
                end
            end
        end
    end

    -- Sort by screen x position (left to right)
    table.sort(secondaries, function(a, b)
        return a.screen:frame().x < b.screen:frame().x
    end)

    return secondaries
end

--- Get the hs.screen object for a named monitor from the config
--- @param monitorName string  The monitor name key (e.g., "lg-left")
--- @param monitorsConfig table  The monitors config
--- @return hs.screen|nil
function M.getScreenForMonitor(monitorName, monitorsConfig)
    if not monitorsConfig or not monitorsConfig.monitors then return nil end

    local monitor = monitorsConfig.monitors[monitorName]
    if not monitor then return nil end

    -- For primary role, use findPrimary (includes fallback logic)
    if monitor.role == "primary" then
        return M.findPrimary(monitorsConfig)
    end

    -- For others, match by pattern and disambiguate by position
    if monitor.pattern and monitor.pattern ~= "" then
        local matches = M.findAllByPattern(monitor.pattern)
        return pickByPosition(matches, monitor.position, monitorName)
    end

    return nil
end

--- Focus a monitor by directional position ("left"|"right"|"up"|"down")
--- Finds monitors.json entries with the matching position, resolves them
--- to physical screens, picks the extreme one in that direction if multiple
--- match, and focuses it via screen_focus.focusScreen.
--- @param position string  One of "left"|"right"|"up"|"down"
--- @param monitorsConfig table  The monitors config (config.monitors)
--- @return boolean  true if a screen was focused
function M.focusByPosition(position, monitorsConfig)
    if not position or position == "" then return false end
    if not monitorsConfig or not monitorsConfig.monitors then return false end

    local screenFocus = require("modules.screen_focus")

    -- Collect all screens matching entries with the requested position
    local matches = {}
    local seen = {}
    for _, monitor in pairs(monitorsConfig.monitors) do
        if monitor.position == position
            and monitor.pattern and monitor.pattern ~= "" then
            for _, screen in ipairs(M.findAllByPattern(monitor.pattern)) do
                local uuid = screen:getUUID() or tostring(screen:id())
                if not seen[uuid] then
                    seen[uuid] = true
                    table.insert(matches, screen)
                end
            end
        end
    end

    if #matches == 0 then return false end

    -- Pick extreme screen in the requested direction.
    -- Hammerspoon coords: smaller x = left, smaller y = up.
    local chosen = matches[1]
    for i = 2, #matches do
        local s = matches[i]
        local cf = chosen:frame()
        local sf = s:frame()
        if position == "left" and sf.x < cf.x then
            chosen = s
        elseif position == "right" and sf.x > cf.x then
            chosen = s
        elseif position == "up" and sf.y < cf.y then
            chosen = s
        elseif position == "down" and sf.y > cf.y then
            chosen = s
        end
    end

    -- Detect ties on the relevant axis
    local axis = (position == "left" or position == "right") and "x" or "y"
    local extreme = chosen:frame()[axis]
    local tieCount = 0
    for _, s in ipairs(matches) do
        if s:frame()[axis] == extreme then
            tieCount = tieCount + 1
        end
    end
    if tieCount > 1 then
        hs.alert.show("Ambiguous monitor " .. position .. ": " .. tieCount .. " screens tied")
    end

    screenFocus.focusScreen(chosen)
    return true
end

--- List all connected screens with details
--- Outputs to stdout (read by `hs -c` for shell IPC).
--- Hotkey-driven Ctrl+Alt+Cmd+Shift+L also calls this; output goes to the
--- Hammerspoon console rather than an on-screen alert. The shell-driven
--- `ws screens` path is the dominant caller and must not show an overlay.
--- @return string  The formatted screen list
function M.listScreens()
    local screens = hs.screen.allScreens()
    local lines = { "Connected Screens:" }

    for i, screen in ipairs(screens) do
        local name = screen:name()
        local frame = screen:fullFrame()
        local uuid = screen:getUUID() or "unknown"
        local line = string.format(
            '  %d. "%s" -- %dx%d @ (%d, %d) -- UUID: %s',
            i, name, frame.w, frame.h, frame.x, frame.y, uuid
        )
        table.insert(lines, line)
    end

    table.insert(lines, "")
    table.insert(lines, "Copy a screen name into monitors.json to configure it.")

    local output = table.concat(lines, "\n")
    print(output)
    return output
end

return M
