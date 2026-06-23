-- modules/utils.lua
-- Shared utility functions for Hammerspoon modules

local M = {}

--- Escape a string for safe interpolation into AppleScript double-quoted strings.
--- Escapes backslashes first, then double quotes, preventing injection.
--- @param s string  The raw string to escape
--- @return string  The escaped string safe for AppleScript interpolation
function M.escapeAppleScript(s)
    if not s then return "" end
    return s:gsub('\\', '\\\\'):gsub('"', '\\"')
end

return M
