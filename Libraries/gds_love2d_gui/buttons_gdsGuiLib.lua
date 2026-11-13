-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    Library: lib_buttons.lua
    Author: Jonathan Pazmino
    Description: Handles creation, state, drawing, and interaction for all GUI buttons.
]]

--------------------------------------------------------------------------------
-- LIBRARY TABLE
--------------------------------------------------------------------------------

globApp.objects.buttons = {}

--------------------------------------------------------------------------------
-- PRIVATE HELPER FUNCTIONS
--------------------------------------------------------------------------------

--[[ Returns the name of the currently active page. ]]
local function _getActivePageName()
    for _, page in ipairs(pages) do
        if page.index == globApp.currentPageIndex then
            return page.name
        end
    end
    return ""
end

--[[ Checks if a given coordinate (x, y) is within the bounds of a button. ]]
local function _isPressed(button, x, y)
    return x >= button.myx and x <= button.myMaxx and y >= button.myy and y <= button.myMaxy
end

-- Press-feedback pulse timing (see gdsGui_button_update/_draw): dips to
-- PULSE_DIP scale right on a RELEASED->PRESSED transition, then eases
-- linearly back to 1.0 over PULSE_SECONDS. A fixed-duration tap pulse, not
-- a sustained "scale while PRESSED" -- PRESSED also means "toggled on" for
-- a toggle-type button, which stays PRESSED indefinitely once flipped on,
-- so binding scale to that state would leave every ON toggle permanently
-- shrunk instead of just tapped.
local _PULSE_SECONDS = 0.15
local _PULSE_DIP = 0.05

--[[ 1.0 at rest; mid-dip-and-recover right after a press. ]]
local function _pulseScale(button)
    local t = button._pressPulseT
    if not t then return 1 end
    return 1 - _PULSE_DIP * math.max(0, 1 - t / _PULSE_SECONDS)
end

--[[ Public wrapper so a container-owned button's own draw path (in
     container_gdsGuiLib.lua -- a separate draw path from gdsGui_button_draw
     below, since a container-owned button draws as part of its container's
     own pass) can apply the same tap feedback instead of sitting dead
     still. ]]
function gdsGui_button_pulseScale(button)
    return _pulseScale(button)
end

--[[ Invokes a button's callback function if it exists. ]]
local function _executeCallback(button)
    if button.callbackFunc then
        -- _G is a table containing all global variables.
        -- This is a safe way to call a global function by its name stored as a string.
        local callback = _G[button.callbackFunc]
        if callback and type(callback) == "function" then
            callback(button.state)
        else
            print("Button '" .. button.name .. "' callback function '" .. button.callbackFunc .. "' not found.")
        end
    else
        -- This is not an error, some buttons might not have callbacks.
        -- print("Button '" .. button.name .. "' has no callback function assigned.")
    end
end


--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
    Creates a new button and adds it to the global button list.
]]
function gdsGui_button_create(label, page, buttonType, imgPressed, imgReleased, imgDeactivated, x, y, anchorPoint, width, height, callbackFunc, initialState, hapticEnabled, containerName)
    local newButton = {}

    newButton.name = label
    newButton.page = page
    newButton.objectType = "button"
    newButton.type = buttonType -- "toggle" or "pushonoff"

    -- Store images in a sub-table for cleaner state-based drawing.
    newButton.images = {
        [globApp.BUTTON_STATES.DEACTIVATED] = imgDeactivated and love.graphics.newImage(imgDeactivated),
        [globApp.BUTTON_STATES.RELEASED]    = imgReleased    and love.graphics.newImage(imgReleased),
        [globApp.BUTTON_STATES.PRESSED]     = imgPressed     and love.graphics.newImage(imgPressed),
    }

    -- Store original relative properties for robust resizing
    newButton.original = {
        x = x,
        y = y,
        -- The original width/height are absolute, so we calculate their initial
        -- ratio relative to the screen's safe area for later use.
        widthRatio = width / globApp.safeScreenArea.w,
        heightRatio = height / globApp.safeScreenArea.h,
        aspectRatio = height / width,
        anchorPoint = anchorPoint
    }

    -- This position is updated in the new resize() method.
    newButton.mywidth = width
    newButton.myheight = height
    newButton.anchorPoint = anchorPoint
    local myPositions = gdsGui_general_relativePosition(newButton.anchorPoint, x, y, newButton.mywidth, newButton.myheight, globApp.safeScreenArea.x, globApp.safeScreenArea.y, globApp.safeScreenArea.w, globApp.safeScreenArea.h)
    newButton.myx = myPositions[1]
    newButton.myy = myPositions[2]

    -- Pre-calculate scaling factors and max coordinates for efficiency.
    local baseImage = newButton.images[globApp.BUTTON_STATES.RELEASED] or newButton.images[globApp.BUTTON_STATES.PRESSED]
    newButton.factorWidth  = baseImage and (newButton.mywidth  / baseImage:getWidth())  or 1
    newButton.factorHeight = baseImage and (newButton.myheight / baseImage:getHeight()) or 1
    newButton.myMaxx = newButton.myx + newButton.mywidth
    newButton.myMaxy = newButton.myy + newButton.myheight

    newButton.deactivated = (initialState == globApp.BUTTON_STATES.DEACTIVATED)
    newButton.state = initialState
    newButton.callbackFunc = callbackFunc
    newButton.hapticEnabled = (hapticEnabled == true)
    newButton.hidden = false
    -- Press-feedback pulse (see gdsGui_button_update/_draw): nil whenever
    -- settled at rest, so most buttons cost nothing extra per frame.
    newButton._pressPulseT = nil
    -- Opt-in soft drop shadow for UI that visually floats above other
    -- content (a dock tool button over the canvas) rather than sitting
    -- flush in a header/footer row -- see gdsGui_button_setFloatingShadow.
    newButton.floatingShadow = false

    -- The new resize method for this object
    function newButton:resize()
        local original = self.original

        -- Recalculate absolute size based on the new safe area and original ratio
        local newDims = gdsGui_general_getScaledDimensions(original.widthRatio, original.heightRatio, original.aspectRatio)
        self.mywidth = newDims.width
        self.myheight = newDims.height

        -- Recalculate absolute position using the consistent relative values
        local myPositions = gdsGui_general_relativePosition(
            self.anchorPoint, original.x, original.y,
            self.mywidth, self.myheight,
            globApp.safeScreenArea.x, globApp.safeScreenArea.y,
            globApp.safeScreenArea.w, globApp.safeScreenArea.h
        )
        self.myx = myPositions[1]
        self.myy = myPositions[2]

        -- Update other derived properties
        local baseImage = self.images[globApp.BUTTON_STATES.RELEASED] or self.images[globApp.BUTTON_STATES.PRESSED]
        self.factorWidth  = baseImage and (self.mywidth  / baseImage:getWidth())  or 1
        self.factorHeight = baseImage and (self.myheight / baseImage:getHeight()) or 1
        self.myMaxx = self.myx + self.mywidth
        self.myMaxy = self.myy + self.myheight
    end
    newButton.resize = newButton.resize

    table.insert(globApp.objects.buttons, newButton)
    globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
    if containerName then
        newButton.containerFrac = { x=x, y=y, w=width, h=height, anchorPoint=anchorPoint }
        gdsGui_container_addObject(containerName, "button", label)
    end
end

--[[
    Advances every button's press-feedback pulse (see _pulseScale above).
    Settled (_pressPulseT nil) buttons are skipped, so this costs nothing
    for the vast majority of buttons on any given frame.
]]
function gdsGui_button_update(dt)
    for _, button in ipairs(globApp.objects.buttons) do
        if button._pressPulseT then
            button._pressPulseT = button._pressPulseT + dt
            if button._pressPulseT >= _PULSE_SECONDS then button._pressPulseT = nil end
        end
    end
end

--[[
    Draws all buttons that belong to the specified page.
]]
function gdsGui_button_draw(pageName)
    love.graphics.setColor(1, 1, 1, 1)
    for _, button in ipairs(globApp.objects.buttons) do
        if button.page == pageName and not button.ownerContainer and not button.hidden then
            local imageToDraw = button.images[button.state]
            if imageToDraw then
                if button.floatingShadow then
                    gdsGui_general_drawShadow(button.myx, button.myy, button.mywidth, button.myheight,
                        math.min(button.mywidth, button.myheight) * 0.22, 0, 3, 8, 0.35)
                    love.graphics.setColor(1, 1, 1, 1)
                end
                local scale = _pulseScale(button)
                local cx = button.myx + button.mywidth / 2
                local cy = button.myy + button.myheight / 2
                love.graphics.draw(imageToDraw, cx, cy, 0,
                    button.factorWidth * scale, button.factorHeight * scale,
                    imageToDraw:getWidth() / 2, imageToDraw:getHeight() / 2)
            end
        end
    end
end

--[[
    The old gui_buttons_update function is now deprecated and removed.
    Its logic has been replaced by the .resize() method on each button object,
    plus gdsGui_button_update above for the press-feedback pulse.
]]

--[[
    Handles the logic for when a mouse button or touch event is pressed down.
]]
function gdsGui_button_pressed(x, y, button, istouch)
    -- We only care about left-click or a touch event.
    if button ~= 1 then return end

    local activePageName = _getActivePageName()

    -- True once this press lands on a live button, so widgets dispatched
    -- after buttons for the SAME press (e.g. a schematic canvas a floating
    -- button sits over) can tell it was already consumed — even when the
    -- button's own callback moved or hid it, so hit-testing its rect again
    -- afterward would miss.
    globApp.buttonPressConsumed = false

    for _, p in ipairs(globApp.objects.buttons) do
        if p.page == activePageName and not p.hidden and p.state ~= globApp.BUTTON_STATES.DEACTIVATED and _isPressed(p, x, y) and
           (not p.ownerContainer or gdsGui_container_isTouchInOwnerContainer(p, x, y)) then
            globApp.buttonPressConsumed = true
            if p.type == "toggle" then
                if p.state == globApp.BUTTON_STATES.RELEASED then
                    p.state = globApp.BUTTON_STATES.PRESSED
                    p._pressPulseT = 0
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    _executeCallback(p)
                elseif p.state == globApp.BUTTON_STATES.PRESSED then
                    p.state = globApp.BUTTON_STATES.RELEASED
                    p._pressPulseT = 0
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    _executeCallback(p)
                end
            elseif p.type == "stickyToggle" then
                -- Fires on RELEASED→PRESSED only; PRESSED state ignores all input
                -- so the button stays locked until externally reset via setState.
                if p.state == globApp.BUTTON_STATES.RELEASED then
                    p.state = globApp.BUTTON_STATES.PRESSED
                    p._pressPulseT = 0
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    _executeCallback(p)
                end
            elseif p.type == "pushonoff" then
                if p.state == globApp.BUTTON_STATES.RELEASED then
                    p.state = globApp.BUTTON_STATES.PRESSED
                    p._pressPulseT = 0
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    -- For pushonoff, callback is usually on release.
                end
            end
        end
    end
end

--[[
    Handles the logic for when a mouse button or touch event is released.
]]
function gdsGui_button_released(x, y, button, istouch)
    if button ~= 1 then return end

    local activePageName = _getActivePageName()
    for _, p in ipairs(globApp.objects.buttons) do
        if p.page == activePageName and p.type == "pushonoff" and p.state == globApp.BUTTON_STATES.PRESSED then
            p.state = globApp.BUTTON_STATES.RELEASED
            -- Only fire the callback if this release is actually over the
            -- button that was pressed (standard touch-up-inside semantics) —
            -- otherwise a drag-off-and-release cancels it, and a release
            -- elsewhere on the page can't fire an unrelated still-pressed
            -- button (e.g. the other finger of a two-button multi-touch).
            if not p.hidden and _isPressed(p, x, y) and
               (not p.ownerContainer or gdsGui_container_isTouchInOwnerContainer(p, x, y)) then
                _executeCallback(p)
            end
        end
    end
end

--[[
    Sets the state of a specific button by its name.
    States: "deactivated", "released", "pushed"
]]
function gdsGui_button_setState(buttonName, state)
    local targetState
    if state == "deactivated" then
        targetState = globApp.BUTTON_STATES.DEACTIVATED
    elseif state == "released" then
        targetState = globApp.BUTTON_STATES.RELEASED
    elseif state == "pushed" then
        targetState = globApp.BUTTON_STATES.PRESSED
    else
        return -- Invalid state string
    end

    for _, b in ipairs(globApp.objects.buttons) do
        if b.name == buttonName then
            b.state = targetState
            b.deactivated = (targetState == globApp.BUTTON_STATES.DEACTIVATED)
            return
        end
    end
end

--[[
    Swaps a button's sprite images in place (e.g. a theme change re-tinting
    a checkbox) -- same three-state imgPressed/imgReleased/imgDeactivated
    arguments as gdsGui_button_create, nil leaving a state's current image
    untouched. Re-derives factorWidth/factorHeight from the new RELEASED
    (or PRESSED) image so a differently-sized replacement still fills the
    button's own on-screen footprint correctly.
]]
function gdsGui_button_setImages(buttonName, imgPressed, imgReleased, imgDeactivated)
    for _, b in ipairs(globApp.objects.buttons) do
        if b.name == buttonName then
            if imgDeactivated then b.images[globApp.BUTTON_STATES.DEACTIVATED] = love.graphics.newImage(imgDeactivated) end
            if imgReleased    then b.images[globApp.BUTTON_STATES.RELEASED]    = love.graphics.newImage(imgReleased) end
            if imgPressed     then b.images[globApp.BUTTON_STATES.PRESSED]     = love.graphics.newImage(imgPressed) end
            local baseImage = b.images[globApp.BUTTON_STATES.RELEASED] or b.images[globApp.BUTTON_STATES.PRESSED]
            b.factorWidth  = baseImage and (b.mywidth  / baseImage:getWidth())  or 1
            b.factorHeight = baseImage and (b.myheight / baseImage:getHeight()) or 1
            return
        end
    end
end

--[[
    Moves a button by name to a new relative (0-1 of the safe area) position,
    keeping its anchor point and size. Stored as its new original position so
    a later window resize keeps it there.
]]
function gdsGui_button_setPosition(buttonName, x, y)
    for _, b in ipairs(globApp.objects.buttons) do
        if b.name == buttonName then
            b.original.x = x
            b.original.y = y
            b:resize()
            return
        end
    end
end

--[[
    Shows or fully hides a button by name — unlike the DEACTIVATED state
    (still drawn, just unresponsive), a hidden button is skipped entirely by
    both drawing and press handling.
]]
function gdsGui_button_setHidden(buttonName, hidden)
    for _, b in ipairs(globApp.objects.buttons) do
        if b.name == buttonName then
            b.hidden = hidden
            return
        end
    end
end

--[[
    Opts a button into the soft floating-elevation shadow (see
    gdsGui_button_draw) -- for chrome that visually floats above other
    content (a dock tool button over the canvas), not a flush header/footer
    button. Off by default.
]]
function gdsGui_button_setFloatingShadow(buttonName, floating)
    for _, b in ipairs(globApp.objects.buttons) do
        if b.name == buttonName then
            b.floatingShadow = floating
            return
        end
    end
end

--------------------------------------------------------------------------------
-- SCROLL DOCKS — a named screen-space region where a press-and-drag scrolls
-- a group of floating buttons instead of tapping whichever one it landed on.
--
-- Buttons here have no notion of "this touch turned into a scroll, don't
-- fire" -- a "toggle" button fires its callback the instant it's pressed
-- (see gdsGui_button_pressed above), so a drag starting on one would already
-- have fired before any movement could be measured. gdsGui_general_mouse/
-- touchpressed/_moved/_released (general_gdsGuiLib.lua) each call the three
-- gate functions below BEFORE their own normal gdsGui_button_pressed/
-- _released call for the same event, and skip that normal call whenever the
-- gate reports it already owns this touch/mouse id -- see each gate
-- function's own comment for exactly what that means at that stage of the
-- gesture.
--
-- The app layer owns the geometry and the "what does this group mean"
-- entirely (via gdsGui_button_setScrollDockRect, called every frame the
-- dock's own rect needs to track something live, e.g. a resize) -- this is
-- purely geometric gating plus a drag threshold, same "opaque to why"
-- contract gdsGui_schematic_setInputBlockRect already uses for the canvas.
--------------------------------------------------------------------------------

globApp.objects.buttonScrollDocks = {}

local _DOCK_DRAG_THRESHOLD_PX = 6

--[[
    Registers (or, passing a nil rect, clears) a scroll dock by name. rect is
    {x, y, w, h} in screen pixels; scrollCallbackName (ignored when rect is
    nil) is a by-name callback, resolved via _G[...] same convention as every
    other string-registered callback in this library, called as
    fn(deltaPixelsY) once per drag move past the threshold (positive delta =
    finger/cursor moved down since the last move).
]]
function gdsGui_button_setScrollDockRect(dockName, pageName, rect, scrollCallbackName)
    for _, d in ipairs(globApp.objects.buttonScrollDocks) do
        if d.name == dockName then
            d.page = pageName
            d.rect = rect
            d.scrollCallback = rect and scrollCallbackName or nil
            return
        end
    end
    table.insert(globApp.objects.buttonScrollDocks, {
        name = dockName, page = pageName, rect = rect,
        scrollCallback = rect and scrollCallbackName or nil, capture = nil,
    })
end

local function _findScrollDockAt(pageName, x, y)
    for _, d in ipairs(globApp.objects.buttonScrollDocks) do
        if d.page == pageName and d.rect and
           x >= d.rect.x and x <= d.rect.x + d.rect.w and
           y >= d.rect.y and y <= d.rect.y + d.rect.h then
            return d
        end
    end
    return nil
end

local function _findScrollDockByCapture(id)
    for _, d in ipairs(globApp.objects.buttonScrollDocks) do
        if d.capture and d.capture.id == id then return d end
    end
    return nil
end

--[[
    Call before dispatching a press to gdsGui_button_pressed. Returns true
    (and starts tracking this touch/mouse id) when (x,y) lands inside a
    registered scroll dock on the active page -- the caller must skip its
    own normal gdsGui_button_pressed call for THIS press when true, since
    gdsGui_button_dockGateReleased below is what actually fires it, once it
    knows whether the gesture turned out to be a tap or a drag. Returns
    false (do nothing, handle this press exactly as before) for every press
    outside every registered dock.

    Also sets globApp.buttonPressConsumed, same as gdsGui_button_pressed
    itself does on a hit -- a dock's own drag rect is deliberately bigger
    than the sum of its buttons' hitboxes (it has to cover the GAPS between
    them too, or a drag starting in a gap would fall straight through to
    whatever's underneath), so a press landing in one of those gaps has no
    button of its own to be "consumed" by. Without this, something layered
    under the dock (e.g. a schematic canvas's own pan) would see the SAME
    press as a miss on every button and handle it too, double-driving the
    gesture alongside the dock scroll this gate is about to start.
]]
function gdsGui_button_dockGatePressed(id, x, y, button, istouch)
    if button and button ~= 1 then return false end
    local d = _findScrollDockAt(_getActivePageName(), x, y)
    if not d then return false end
    d.capture = { id = id, startX = x, startY = y, lastY = y, isDrag = false }
    globApp.buttonPressConsumed = true
    return true
end

--[[
    Call on every move for this id. While movement since the press stays
    under the drag threshold this does nothing but keep waiting; once past
    it, this and every subsequent move scrolls (calls the dock's registered
    callback with the pixel delta since the last move) and a tap can no
    longer fire for this gesture. Returns true for as long as a capture for
    this id is live (even before the threshold trips), so the caller can
    skip whatever per-move button bookkeeping it would otherwise do --
    harmless either way for a "toggle" button (which only reacts on press),
    but matters for a "pushonoff" one.
]]
function gdsGui_button_dockGateMoved(id, x, y, dx, dy)
    local d = _findScrollDockByCapture(id)
    if not d then return false end
    local c = d.capture
    if not c.isDrag and (math.abs(y - c.startY) > _DOCK_DRAG_THRESHOLD_PX or math.abs(x - c.startX) > _DOCK_DRAG_THRESHOLD_PX) then
        c.isDrag = true
    end
    if c.isDrag and d.scrollCallback then
        local fn = _G[d.scrollCallback]
        if fn then fn(y - c.lastY) end
    end
    c.lastY = y
    return true
end

--[[
    Call on release for this id, BEFORE the caller's own normal
    gdsGui_button_released. A gesture that never crossed the drag threshold
    replays as a plain tap -- gdsGui_button_pressed then gdsGui_button_released,
    both at this exact release point -- so whichever button the finger is
    still over fires exactly as if the dock had never intercepted the press;
    one that did drag ends here with no tap at all. Returns true once a
    capture for this id existed (even when nothing ends up firing), so the
    caller knows to skip its own release handling for this same event; false
    when this id was never captured (nothing to do).
]]
function gdsGui_button_dockGateReleased(id, x, y, button, istouch)
    local d = _findScrollDockByCapture(id)
    if not d then return false end
    local wasDrag = d.capture.isDrag
    d.capture = nil
    if not wasDrag then
        gdsGui_button_pressed(x, y, 1, istouch)
        gdsGui_button_released(x, y, 1, istouch)
    end
    return true
end