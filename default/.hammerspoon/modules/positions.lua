-- modules/positions.lua
-- Unit rect to pixel frame conversion for a given screen

local M = {}

--- Resolve a named position preset to a pixel-frame hs.geometry.rect
--- Supports both single rect and arrays of rects (for staggered windows).
--- For arrays, the `index` parameter selects which rect to use (1-based).
---
--- @param positionName string  Name of the position preset from workspaces.json positions block
--- @param screen hs.screen  The screen to resolve against
--- @param positionsConfig table  The positions block from workspaces.json
--- @param index number|nil  For array positions, which rect to use (1-based, defaults to 1)
--- @return hs.geometry.rect|nil  Pixel-frame rect, or nil if position not found
function M.resolve(positionName, screen, positionsConfig, index)
    if not positionName or not screen or not positionsConfig then
        return nil
    end

    local preset = positionsConfig[positionName]
    if not preset then
        return nil
    end

    local unitRect
    if preset.x then
        -- Single rect definition
        unitRect = preset
    elseif #preset > 0 then
        -- Array of rects (staggered positions)
        local idx = index or 1
        if idx <= #preset then
            unitRect = preset[idx]
        else
            -- Auto-generate offset position from last defined position
            local lastRect = preset[#preset]
            local overflow = idx - #preset
            local offsetX = overflow * 0.05  -- 5% offset per extra window
            local offsetY = overflow * 0.05
            unitRect = {
                x = math.min(lastRect.x + offsetX, 1.0 - lastRect.w),
                y = math.min(lastRect.y + offsetY, 1.0 - lastRect.h),
                w = lastRect.w,
                h = lastRect.h,
            }
        end
    else
        return nil
    end

    if not unitRect or not unitRect.x or not unitRect.y or not unitRect.w or not unitRect.h then
        return nil
    end

    -- Convert unit rect (0.0-1.0 fractions) to pixel frame
    local screenFrame = screen:frame()
    local pixelX = screenFrame.x + (unitRect.x * screenFrame.w)
    local pixelY = screenFrame.y + (unitRect.y * screenFrame.h)
    local pixelW = unitRect.w * screenFrame.w
    local pixelH = unitRect.h * screenFrame.h

    return hs.geometry.rect(pixelX, pixelY, pixelW, pixelH)
end

return M
