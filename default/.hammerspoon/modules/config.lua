-- modules/config.lua
-- Config loading, validation, path expansion

local json = require("hs.json")

local M = {}

local configDir = os.getenv("HOME") .. "/.hammerspoon/"

--- Expand ~/  paths to $HOME
--- @param path string
--- @return string
function M.expandPath(path)
    if not path then return path end
    local home = os.getenv("HOME")
    if home and path:sub(1, 2) == "~/" then
        return home .. path:sub(2)
    end
    return path
end

--- Load and parse a JSON config file from ~/.hammerspoon/
--- @param filename string  Name of the JSON file (e.g., "monitors.json")
--- @param required boolean|nil  If true (default), log missing files to console; if false, silently return nil
--- @return table|nil  Parsed table, or nil on error
function M.loadConfig(filename, required)
    -- Default to required=true for backward compatibility
    if required == nil then required = true end

    local filepath = configDir .. filename
    local file = io.open(filepath, "r")
    if not file then
        if required then
            print("Config not found: " .. filename)
        end
        return nil
    end
    local content = file:read("*all")
    file:close()

    local ok, result = pcall(json.decode, content)
    if not ok then
        hs.alert.show("JSON parse error in " .. filename)
        return nil
    end
    return result
end

--- Validate monitors.json config structure.
--- Checks required fields, role/position enums, at most one 'primary',
--- and the pattern-uniqueness rule: if two or more entries share a
--- `pattern`, every entry with that pattern must have a `position` and
--- all those positions must be distinct (so pattern+position resolves
--- unambiguously to a single physical screen).
--- @param config table  The parsed monitors config
--- @return boolean  true if valid
--- @return string|nil  Error message if invalid
function M.validateMonitors(config)
    if not config then
        return false, "monitors config is nil"
    end
    if not config.monitors then
        return false, "monitors config missing 'monitors' key"
    end
    if type(config.monitors) ~= "table" then
        return false, "'monitors' must be a table"
    end

    local primaryCount = 0
    for name, monitor in pairs(config.monitors) do
        if type(monitor) ~= "table" then
            return false, "monitor '" .. name .. "' must be a table"
        end
        if monitor.pattern == nil then
            return false, "monitor '" .. name .. "' missing 'pattern' field"
        end
        if monitor.role then
            if monitor.role ~= "primary" and monitor.role ~= "secondary" then
                return false, "monitor '" .. name .. "' has invalid role: " .. tostring(monitor.role)
            end
            if monitor.role == "primary" then
                primaryCount = primaryCount + 1
            end
        end
        if monitor.position ~= nil then
            if monitor.position ~= "left" and monitor.position ~= "right"
                and monitor.position ~= "up" and monitor.position ~= "down" then
                return false, "monitor '" .. name .. "' has invalid position: "
                    .. tostring(monitor.position)
                    .. " (expected 'left'|'right'|'up'|'down')"
            end
        end
    end

    if primaryCount > 1 then
        return false, "multiple monitors have role 'primary' (expected at most 1)"
    end

    -- Multi-match rule: if two entries share a pattern, every entry with
    -- that pattern must have a distinct 'position' so pattern+position is
    -- unique. This catches configs where bare patterns collide.
    local patternGroups = {}
    for name, monitor in pairs(config.monitors) do
        if monitor.pattern and monitor.pattern ~= "" then
            local group = patternGroups[monitor.pattern]
            if not group then
                group = {}
                patternGroups[monitor.pattern] = group
            end
            table.insert(group, { name = name, position = monitor.position })
        end
    end
    for pattern, group in pairs(patternGroups) do
        if #group > 1 then
            local seenPositions = {}
            for _, entry in ipairs(group) do
                if not entry.position then
                    return false, "multiple monitors share pattern '" .. pattern
                        .. "' but '" .. entry.name .. "' has no 'position' field"
                end
                if seenPositions[entry.position] then
                    return false, "monitors '" .. seenPositions[entry.position]
                        .. "' and '" .. entry.name
                        .. "' share pattern '" .. pattern
                        .. "' AND position '" .. entry.position .. "'"
                end
                seenPositions[entry.position] = entry.name
            end
        end
    end

    -- Validate titleAssignments if present.
    --
    -- Schema (per issue #50): each entry must have `app` and `monitor`,
    -- and may have `matchAll` (boolean). The `excludePatterns` field is
    -- no longer supported -- workspace pattern matching from
    -- workspaces.json takes precedence over titleAssignments, so the
    -- exclude list (which used to duplicate workspaces' patterns) is
    -- redundant. Stale `excludePatterns` entries are ignored (a
    -- one-line console warning is emitted) so users notice on next reload.
    if config.titleAssignments then
        if type(config.titleAssignments) ~= "table" then
            return false, "'titleAssignments' must be an array"
        end
        for i, assignment in ipairs(config.titleAssignments) do
            if not assignment.app then
                return false, "titleAssignment[" .. i .. "] missing 'app' field"
            end
            if not assignment.monitor then
                return false, "titleAssignment[" .. i .. "] missing 'monitor' field"
            end
            if not config.monitors[assignment.monitor] then
                return false, "titleAssignment[" .. i .. "] references unknown monitor: " .. assignment.monitor
            end
            if assignment.excludePatterns ~= nil then
                print("[config] titleAssignment[" .. i .. "] (app='"
                    .. tostring(assignment.app)
                    .. "') has obsolete 'excludePatterns' field; ignoring. "
                    .. "Workspace patterns in workspaces.json now take "
                    .. "precedence over titleAssignments (issue #50).")
            end
        end
    end

    return true, nil
end

--- Validate workspaces.json config structure
--- Supports the enhanced schema with positions and launch blocks
--- @param config table  The parsed workspaces config
--- @return boolean  true if valid
--- @return string|nil  Error message if invalid
function M.validateWorkspaces(config)
    if not config then
        return false, "workspaces config is nil"
    end
    if not config.workspaces then
        return false, "workspaces config missing 'workspaces' key"
    end
    if type(config.workspaces) ~= "table" then
        return false, "'workspaces' must be a table"
    end

    -- Validate positions block if present
    if config.positions then
        if type(config.positions) ~= "table" then
            return false, "'positions' must be a table"
        end
        for name, preset in pairs(config.positions) do
            if type(preset) == "table" then
                if preset.x then
                    -- Single rect: must have x, y, w, h
                    if preset.y == nil or preset.w == nil or preset.h == nil then
                        return false, "position '" .. name .. "' missing x/y/w/h fields"
                    end
                elseif #preset > 0 then
                    -- Array of rects
                    for j, rect in ipairs(preset) do
                        if not rect.x or not rect.y or not rect.w or not rect.h then
                            return false, "position '" .. name .. "[" .. j .. "]' missing x/y/w/h fields"
                        end
                    end
                end
            end
        end
    end

    -- Reject the legacy array shape (see issue #56). In the new shape,
    -- `workspaces` is a table keyed by workspace name. The legacy shape was
    -- an array of objects each with a `name` field.
    if #config.workspaces > 0 then
        return false, "'workspaces' must be a keyed object (name -> config), "
            .. "not an array. See issue #56 for the new schema."
    end

    -- Collect all position names referenced in launch configs for cross-validation
    local referencedPositions = {}

    for name, ws in pairs(config.workspaces) do
        if type(name) ~= "string" then
            return false, "workspace keys must be strings (got " .. type(name) .. ")"
        end
        if type(ws) ~= "table" then
            return false, "workspace '" .. name .. "' must be a table"
        end
        if ws.name ~= nil then
            return false, "workspace '" .. name .. "' must not have a 'name' field "
                .. "(the key is the name). See issue #56."
        end
        if not ws.spaceIndex then
            return false, "workspace '" .. name .. "' missing 'spaceIndex' field"
        end

        -- Validate launch block if present
        if ws.launch then
            if type(ws.launch) ~= "table" then
                return false, "workspace '" .. name .. "' launch must be a table"
            end

            -- Validate finder config (must be an array)
            if ws.launch.finder then
                if type(ws.launch.finder) ~= "table" then
                    return false, "workspace '" .. name .. "' launch.finder must be an array"
                end
                -- Check it's an array (has numeric keys)
                if ws.launch.finder[1] == nil and next(ws.launch.finder) ~= nil then
                    return false, "workspace '" .. name .. "' launch.finder must be an array, not an object"
                end
                -- Collect position references from finder entries
                for _, entry in ipairs(ws.launch.finder) do
                    if entry.position then
                        referencedPositions[entry.position] = name .. ".launch.finder"
                    end
                end
            end

            -- Validate iterm config (must have count)
            if ws.launch.iterm then
                if type(ws.launch.iterm) ~= "table" then
                    return false, "workspace '" .. name .. "' launch.iterm must be a table"
                end
                if not ws.launch.iterm.count then
                    return false, "workspace '" .. name .. "' launch.iterm missing 'count' field"
                end
                if ws.launch.iterm.position then
                    referencedPositions[ws.launch.iterm.position] = name .. ".launch.iterm"
                end
            end

            -- Validate vscode config
            if ws.launch.vscode then
                if type(ws.launch.vscode) ~= "table" then
                    return false, "workspace '" .. name .. "' launch.vscode must be a table"
                end
                if ws.launch.vscode.position then
                    referencedPositions[ws.launch.vscode.position] = name .. ".launch.vscode"
                end
            end

            -- Validate safari config
            if ws.launch.safari then
                if type(ws.launch.safari) ~= "table" then
                    return false, "workspace '" .. name .. "' launch.safari must be a table"
                end
                if ws.launch.safari.position then
                    referencedPositions[ws.launch.safari.position] = name .. ".launch.safari"
                end
            end
        end
    end

    -- Cross-validate: every referenced position name must exist in config.positions
    if config.positions then
        for posName, source in pairs(referencedPositions) do
            if not config.positions[posName] then
                return false, "position '" .. posName .. "' referenced in " .. source .. " does not exist in positions block"
            end
        end
    elseif next(referencedPositions) then
        local posName, source = next(referencedPositions)
        return false, "position '" .. posName .. "' referenced in " .. source .. " but no positions block defined"
    end

    return true, nil
end

--- Reserved names that cannot be used as workspace/monitor/position keys.
M.RESERVED_WS_NAMES = { "close", "restart", "screens", "fix", "" }

--- Validate that workspace names, monitor names, and position values are
--- unique across all three namespaces and do not collide with reserved words.
--- @param monitorsConfig table|nil
--- @param workspacesConfig table|nil
--- @return boolean  true if no collisions
--- @return table|nil  list of collision strings if invalid
function M.validateNamespaces(monitorsConfig, workspacesConfig)
    local reserved = {}
    for _, w in ipairs(M.RESERVED_WS_NAMES) do reserved[w] = true end

    -- name -> { source, source, ... }
    local sources = {}
    local function addSource(name, source)
        if name == nil then return end
        if not sources[name] then sources[name] = {} end
        table.insert(sources[name], source)
    end

    local collisions = {}

    if workspacesConfig and type(workspacesConfig.workspaces) == "table" then
        for name, _ in pairs(workspacesConfig.workspaces) do
            if type(name) == "string" then
                addSource(name, "workspace '" .. name .. "'")
                if reserved[name] then
                    table.insert(collisions, "workspace '" .. name .. "' uses reserved word")
                end
            end
        end
    end

    local positionCounts = {}
    if monitorsConfig and type(monitorsConfig.monitors) == "table" then
        for name, m in pairs(monitorsConfig.monitors) do
            if type(name) == "string" then
                addSource(name, "monitor '" .. name .. "'")
                if reserved[name] then
                    table.insert(collisions, "monitor '" .. name .. "' uses reserved word")
                end
            end
            if type(m) == "table" and type(m.position) == "string" then
                addSource(m.position, "monitor '" .. tostring(name) .. "' position")
                if reserved[m.position] then
                    table.insert(collisions,
                        "monitor '" .. tostring(name) .. "' position '" .. m.position .. "' uses reserved word")
                end
                positionCounts[m.position] = (positionCounts[m.position] or 0) + 1
            end
        end
    end

    -- Duplicate positions across monitors
    for pos, count in pairs(positionCounts) do
        if count > 1 then
            table.insert(collisions, "position '" .. pos .. "' assigned to " .. count .. " monitors")
        end
    end

    -- Cross-namespace uniqueness
    local dupNames = {}
    for name, srcs in pairs(sources) do
        if #srcs > 1 then table.insert(dupNames, name) end
    end
    table.sort(dupNames)
    for _, name in ipairs(dupNames) do
        table.insert(collisions, "name '" .. name .. "' used by: " .. table.concat(sources[name], ", "))
    end

    if #collisions == 0 then
        return true, nil
    end
    return false, collisions
end

--- Get the config directory path
--- @return string
function M.getConfigDir()
    return configDir
end

return M
