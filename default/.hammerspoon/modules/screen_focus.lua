-- modules/screen_focus.lua
-- Shared screen focus utility used by all init.lua configurations

local M = {}

--- Focus a screen by moving the mouse to its center and clicking
--- Shows an alert with the screen name, or an error if screen is nil
--- @param screen hs.screen|nil  The screen to focus
function M.focusScreen(screen)
    if screen then
        local rect = screen:fullFrame()
        local center = hs.geometry.rectMidPoint(rect)
        hs.mouse.setAbsolutePosition(center)
        hs.timer.doAfter(0.1, function()
            hs.eventtap.leftClick(center)
        end)
        hs.alert.show("Switched to: " .. screen:name(), nil, screen, 1)
    else
        hs.alert.show("Screen not found!")
    end
end

return M
