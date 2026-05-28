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
    Draws all buttons that belong to the specified page.
]]
function gdsGui_button_draw(pageName)
    love.graphics.setColor(1, 1, 1, 1)
    for _, button in ipairs(globApp.objects.buttons) do
        if button.page == pageName and not button.ownerContainer then
            local imageToDraw = button.images[button.state]
            if imageToDraw then
                love.graphics.draw(imageToDraw, button.myx, button.myy, 0, button.factorWidth, button.factorHeight)
            end
        end
    end
end

--[[
    The old gui_buttons_update function is now deprecated and removed.
    Its logic has been replaced by the .resize() method on each button object.
]]

--[[
    Handles the logic for when a mouse button or touch event is pressed down.
]]
function gdsGui_button_pressed(x, y, button, istouch)
    -- We only care about left-click or a touch event.
    if button ~= 1 then return end

    local activePageName = _getActivePageName()

    for _, p in ipairs(globApp.objects.buttons) do
        if p.page == activePageName and p.state ~= globApp.BUTTON_STATES.DEACTIVATED and _isPressed(p, x, y) and
           (not p.ownerContainer or gdsGui_container_isTouchInOwnerContainer(p, x, y)) then
            if p.type == "toggle" then
                if p.state == globApp.BUTTON_STATES.RELEASED then
                    p.state = globApp.BUTTON_STATES.PRESSED
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    _executeCallback(p)
                elseif p.state == globApp.BUTTON_STATES.PRESSED then
                    p.state = globApp.BUTTON_STATES.RELEASED
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    _executeCallback(p)
                end
            elseif p.type == "stickyToggle" then
                -- Fires on RELEASED→PRESSED only; PRESSED state ignores all input
                -- so the button stays locked until externally reset via setState.
                if p.state == globApp.BUTTON_STATES.RELEASED then
                    p.state = globApp.BUTTON_STATES.PRESSED
                    if p.hapticEnabled then gdsGui_haptics_vibrate() end
                    _executeCallback(p)
                end
            elseif p.type == "pushonoff" then
                if p.state == globApp.BUTTON_STATES.RELEASED then
                    p.state = globApp.BUTTON_STATES.PRESSED
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
        if p.page == activePageName and p.type == "pushonoff" then
            if p.state == globApp.BUTTON_STATES.PRESSED then
                p.state = globApp.BUTTON_STATES.RELEASED
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