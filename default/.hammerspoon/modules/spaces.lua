-- modules/spaces.lua
-- Space creation + title-bar-drag workaround for macOS 15+ (Tahoe/Sequoia)

local M = {}

--------------------------------------------------------------------------------
-- TIMING CONSTANTS (tune these if drag workaround is unreliable)
--------------------------------------------------------------------------------

M.PRE_DRAG_DELAY      = 0.05   -- Seconds before mouseDown to let mouse settle
M.DRAG_ENGAGE_DELAY   = 0.05   -- Seconds after mouseDown before small move
M.DRAG_MOVE_PX        = 5      -- Pixels to move to engage drag mode
M.PRE_KEYSTROKE_DELAY = 0.05   -- Seconds after drag engage before sending keystroke
M.SPACE_SWITCH_DELAY  = 0.7    -- Seconds to wait for Space transition animation
M.MOUSE_UP_DELAY      = 0.1    -- Seconds after space switch before mouseUp
M.VERIFY_DELAY        = 0.3    -- Seconds after mouseUp before verifying
M.RETRY_DELAY         = 1.0    -- Seconds before retry attempt
M.TITLEBAR_Y_OFFSET   = 12     -- Pixels from top of window frame to titlebar center

--------------------------------------------------------------------------------
-- SPACE QUERIES
--------------------------------------------------------------------------------

--- Get ordered spaces for a screen
--- @param screen hs.screen  The screen to query
--- @return table|nil  Array of space IDs, or nil
function M.getSpacesForScreen(screen)
    if not screen then return nil end
    local uuid = screen:getUUID()
    if not uuid then return nil end
    return hs.spaces.spacesForScreen(uuid)
end

--- Navigate to a specific space
--- @param spaceID number  The space ID to navigate to
function M.gotoSpace(spaceID)
    if not spaceID then return end
    hs.spaces.gotoSpace(spaceID)
end

--------------------------------------------------------------------------------
-- SPACE CREATION
--------------------------------------------------------------------------------

--- Ensure a screen has at least N spaces
--- @param screen hs.screen  The screen to check
--- @param n number  Minimum number of spaces needed
--- @return boolean  true if spaces were created, false if already sufficient
function M.ensureCount(screen, n)
    if not screen or not n or n < 1 then return false end

    local spaces = M.getSpacesForScreen(screen)
    if not spaces then return false end

    local created = false
    while #spaces < n do
        hs.spaces.addSpaceToScreen(screen:getUUID())
        spaces = M.getSpacesForScreen(screen)
        if not spaces then return created end
        created = true
    end

    return created
end

--------------------------------------------------------------------------------
-- TITLE-BAR DRAG WORKAROUND
--------------------------------------------------------------------------------

--- Move a window to a target space using title-bar drag workaround
--- This works around hs.spaces.moveWindowToSpace() being broken on macOS 15+.
---
--- Implementation:
---   1. Move mouse to window's title bar center
---   2. Simulate mouseDown (start drag)
---   3. Small mouse movement to engage drag mode
---   4. Trigger Ctrl+N keyboard shortcut (Switch to Desktop N)
---   5. Wait for Space transition animation
---   6. Simulate mouseUp (drop window)
---   7. Verify via hs.spaces.windowSpaces(win), retry once if failed
---
--- @param win hs.window  The window to move
--- @param spaceID number  The target space ID
--- @param spaceIndex number  The 1-based space index (for Ctrl+N shortcut)
--- @param callback function|nil  Optional callback(success) called when done
function M.moveWindowToSpace(win, spaceID, spaceIndex, callback)
    if not win or not spaceID or not spaceIndex then
        if callback then callback(false) end
        return
    end

    -- Ctrl+N shortcuts only work for spaces 1-9
    if spaceIndex < 1 or spaceIndex > 9 then
        if callback then callback(false) end
        return
    end

    -- Check if already on target space
    local currentSpaces = hs.spaces.windowSpaces(win)
    if currentSpaces and currentSpaces[1] == spaceID then
        if callback then callback(true) end
        return
    end

    local function attemptDrag(isRetry)
        -- Step 1: Position mouse at title bar center
        local frame = win:frame()
        local titleBarCenter = hs.geometry.point(
            frame.x + frame.w / 2,
            frame.y + M.TITLEBAR_Y_OFFSET
        )

        -- Ensure the window is focused
        win:focus()

        hs.mouse.setAbsolutePosition(titleBarCenter)

        -- Step 2: Mouse down
        hs.timer.doAfter(M.PRE_DRAG_DELAY, function()
            hs.eventtap.event.newMouseEvent(
                hs.eventtap.event.types.leftMouseDown,
                titleBarCenter
            ):post()

            -- Step 3: Small move to engage drag mode
            hs.timer.doAfter(M.DRAG_ENGAGE_DELAY, function()
                local dragPoint = hs.geometry.point(
                    titleBarCenter.x + M.DRAG_MOVE_PX,
                    titleBarCenter.y
                )
                hs.eventtap.event.newMouseEvent(
                    hs.eventtap.event.types.leftMouseDragged,
                    dragPoint
                ):post()

                -- Step 4: Trigger Ctrl+N to switch to target desktop
                hs.timer.doAfter(M.PRE_KEYSTROKE_DELAY, function()
                    hs.eventtap.keyStroke({"ctrl"}, tostring(spaceIndex), 0)

                    -- Step 5: Wait for space transition animation
                    hs.timer.doAfter(M.SPACE_SWITCH_DELAY, function()
                        -- Step 6: Mouse up (drop window)
                        local currentPos = hs.mouse.absolutePosition()
                        hs.eventtap.event.newMouseEvent(
                            hs.eventtap.event.types.leftMouseUp,
                            currentPos
                        ):post()

                        -- Step 7: Verify
                        hs.timer.doAfter(M.VERIFY_DELAY, function()
                            local newSpaces = hs.spaces.windowSpaces(win)
                            local success = newSpaces and newSpaces[1] == spaceID

                            if not success and not isRetry then
                                -- Retry once
                                hs.timer.doAfter(M.RETRY_DELAY, function()
                                    attemptDrag(true)
                                end)
                            else
                                if callback then callback(success) end
                            end
                        end)
                    end)
                end)
            end)
        end)
    end

    attemptDrag(false)
end

return M
