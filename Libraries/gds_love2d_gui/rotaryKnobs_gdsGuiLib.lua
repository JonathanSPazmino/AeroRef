-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    Library: lib_rotaryKnobs.lua
    Author: Jonathan Pazmino
    Description: Handles creation, drawing, and interaction for rotary knob controls.
                 Supports single knobs and dual (concentric inner + outer) knobs.
                 Architecture mirrors lib_buttons.lua / lib_scrollBar.lua.
]]

--------------------------------------------------------------------------------
-- LIBRARY TABLE
--------------------------------------------------------------------------------

globApp.objects.rotaryKnobs = {}

--------------------------------------------------------------------------------
-- PRIVATE CONSTANTS
--------------------------------------------------------------------------------

-- Full 360° circle: detents are distributed evenly with no hard stops.
-- Continuous rotation wraps from last detent back to first in either direction.
local _KNOB_FULL_CIRCLE = math.pi * 2

-- Inner knob diameter as a fraction of the outer knob diameter (dual knobs only).
local _KNOB_INNER_RATIO = 0.8

-- Absolute pixel radius below which touch-drag is ignored to avoid the atan2
-- singularity right at the pivot.  Dragging anywhere outside this tiny zone —
-- including well outside the knob circle — is fully tracked.
local _KNOB_CENTER_DEAD_ZONE_PX = 6

--------------------------------------------------------------------------------
-- PRIVATE HELPERS
--------------------------------------------------------------------------------

local function _getActivePageName()
    for _, page in ipairs(pages) do
        if page.index == globApp.currentPageIndex then
            return page.name
        end
    end
    return ""
end

-- Convert a normalized position (0-1) to a draw angle in radians.
-- Position 0 → angle 0 → sprite drawn un-rotated (indicator at 12 o'clock if
-- the sprite has its indicator pointing straight up in the image file).
local function _positionToAngle(position)
    return position * _KNOB_FULL_CIRCLE
end

-- Snap a raw angle (radians, any value) to the nearest of N evenly-spaced detents
-- distributed around the full 360° circle.  Wraps seamlessly past the last detent.
-- Returns: snappedPosition (0 to (N-1)/N), detentIndex (0-based, 0 to N-1).
local function _snapToDetent(rawAngle, numDetents)
    if numDetents < 1 then return 0, 0 end
    local normalized = rawAngle % _KNOB_FULL_CIRCLE
    local rawIndex   = normalized / _KNOB_FULL_CIRCLE * numDetents
    local index      = math.floor(rawIndex + 0.5) % numDetents
    return index / numDetents, index
end

-- Write sprite-scale fields into a part table (outer knob or inner sub-table).
-- `part` receives scaleX/Y and imgOrigin* computed from its reference sprite and
-- the desired on-screen diameter `size`.
local function _setPartSpriteGeometry(part, referenceImg, size)
    local iw, ih    = referenceImg:getDimensions()
    part.scaleX     = size / iw
    part.scaleY     = size / ih
    part.imgOriginX = iw * 0.5
    part.imgOriginY = ih * 0.5
end

-- (Re)compute all screen-space geometry from the knob's stored original values.
-- Called once at creation and again whenever the window is resized.
local function _calculateGeometry(knob)
    local dims = gdsGui_general_getScaledDimensions(
        knob.original.widthRatio,
        knob.original.heightRatio,
        knob.original.aspectRatio
    )
    knob.size = dims.width  -- knobs are square; width == height

    local pos = gdsGui_general_relativePosition(
        knob.original.anchorPoint,
        knob.original.x, knob.original.y,
        knob.size, knob.size,
        globApp.safeScreenArea.x, globApp.safeScreenArea.y,
        globApp.safeScreenArea.w, globApp.safeScreenArea.h
    )
    knob.x       = pos[1]
    knob.y       = pos[2]
    knob.centerX = knob.x + knob.size * 0.5
    knob.centerY = knob.y + knob.size * 0.5

    _setPartSpriteGeometry(knob, knob.imgReleased, knob.size)

    -- Inner knob (dual only): 80% of the outer diameter, same center.
    if knob.isDual then
        knob.inner.size = knob.size * _KNOB_INNER_RATIO
        _setPartSpriteGeometry(knob.inner, knob.inner.imgReleased, knob.inner.size)
    end
end

-- Initialise all mutable tracking fields for a draggable part (outer or inner).
-- Works on both the top-level knob table and the knob.inner sub-table.
local function _initPartState(part, numDetents, initialPosition, callbackFunc)
    part.numDetents       = math.max(2, numDetents)
    part.callbackFunc     = callbackFunc
    part.isFocused        = false
    part._prevDetentIndex = -1
    part._grabAngleOffset = 0

    local clampedPos = math.max(0, math.min(1, initialPosition or 0))
    part.position, part.detentIndex = _snapToDetent(clampedPos * _KNOB_FULL_CIRCLE, part.numDetents)
    part.angle            = _positionToAngle(part.position)
    part._prevDetentIndex = part.detentIndex
end

-- Fire a part's callback only when the detent index has actually changed.
local function _fireCallbackIfChanged(part)
    if part.detentIndex ~= part._prevDetentIndex then
        part._prevDetentIndex = part.detentIndex
        if part.callbackFunc then
            local cb = _G[part.callbackFunc]
            if cb and type(cb) == "function" then
                cb(part.position)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
    Creates a single rotary knob and registers it in globApp.objects.rotaryKnobs.

    PARAMETERS
    id              string   — unique identifier
    page            string   — page name this knob belongs to
    x               number   — horizontal position as a fraction of the safe area (0-1)
    y               number   — vertical position as a fraction of the safe area (0-1)
    anchorPoint     string   — anchor string ("CC", "LT", "RT"…)
    size            number   — knob diameter in pixels
    numDetents      number   — discrete positions (minimum 2)
    initialPosition number   — starting fraction 0-1
    spriteReleased  string   — idle sprite path
    spriteFocused   string   — held sprite path
    callbackFunc    string   — global function name; receives position (0-1) on detent change
    hapticEnabled   boolean  — haptic fires once on the initial tap
]]
function gdsGui_rotaryKnob_create(id, page, x, y, anchorPoint, size, numDetents,
        initialPosition, spriteReleased, spriteFocused, callbackFunc, hapticEnabled, containerName)

    local knob = {}
    knob.id            = id
    knob.page          = page
    knob.objectType    = "rotaryKnob"
    knob.isDual        = false
    knob.hapticEnabled = (hapticEnabled == true)
    knob.focusTouchId  = nil
    knob.focusedPart   = nil

    knob.imgReleased = love.graphics.newImage(spriteReleased)
    knob.imgFocused  = love.graphics.newImage(spriteFocused)

    knob.original = {
        x           = x,
        y           = y,
        anchorPoint = anchorPoint,
        widthRatio  = size / globApp.safeScreenArea.w,
        heightRatio = size / globApp.safeScreenArea.h,
        aspectRatio = 1.0
    }

    _initPartState(knob, numDetents, initialPosition, callbackFunc)
    _calculateGeometry(knob)

    function knob:resize() _calculateGeometry(self) end

    table.insert(globApp.objects.rotaryKnobs, knob)
    globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
    if containerName then
        knob.containerFrac = { x=x, y=y, w=size, h=size, anchorPoint=anchorPoint }
        gdsGui_container_addObject(containerName, "rotaryKnob", id)
    end
end


--[[
    Creates a dual (concentric inner + outer) rotary knob.

    The outer knob spans the full `size` diameter.  The inner knob is drawn on
    top of it at _KNOB_INNER_RATIO (80%) of that diameter.

    Hit regions:
      Inner : dist from center ≤ inner radius
      Outer : inner radius < dist ≤ outer radius  (annular gap only)

    Only one part can be focused at a time per knob.  If a touch already owns a
    part, new presses on the same knob are ignored until it is released.

    PARAMETERS (common)
    id, page, x, y, anchorPoint, size — same as gdsGui_rotaryKnob_create

    OUTER KNOB
    outerNumDetents     number  — outer detent count
    outerInitialPos     number  — outer starting position (0-1)
    outerSpriteReleased string  — outer idle sprite path
    outerSpriteFocused  string  — outer held sprite path
    outerCallbackFunc   string  — outer callback (receives position 0-1)

    INNER KNOB
    innerNumDetents, innerInitialPos, innerSpriteReleased,
    innerSpriteFocused, innerCallbackFunc — same semantics as outer

    hapticEnabled   boolean  — haptic fires once on whichever part is first tapped
]]
function gdsGui_rotaryKnob_createDual(id, page, x, y, anchorPoint, size,
        outerNumDetents, outerInitialPos, outerSpriteReleased, outerSpriteFocused, outerCallbackFunc,
        innerNumDetents, innerInitialPos, innerSpriteReleased, innerSpriteFocused, innerCallbackFunc,
        hapticEnabled, containerName)

    local knob = {}
    knob.id            = id
    knob.page          = page
    knob.objectType    = "rotaryKnob"
    knob.isDual        = true
    knob.hapticEnabled = (hapticEnabled == true)
    knob.focusTouchId  = nil
    knob.focusedPart   = nil  -- "outer" | "inner" | nil

    -- Outer knob sprites stored at the top level (mirrors single-knob layout).
    knob.imgReleased = love.graphics.newImage(outerSpriteReleased)
    knob.imgFocused  = love.graphics.newImage(outerSpriteFocused)

    -- Inner knob data lives in a sub-table so it can carry its own sprites,
    -- angle, detent state, and callback independently of the outer knob.
    knob.inner = {}
    knob.inner.imgReleased = love.graphics.newImage(innerSpriteReleased)
    knob.inner.imgFocused  = love.graphics.newImage(innerSpriteFocused)

    knob.original = {
        x           = x,
        y           = y,
        anchorPoint = anchorPoint,
        widthRatio  = size / globApp.safeScreenArea.w,
        heightRatio = size / globApp.safeScreenArea.h,
        aspectRatio = 1.0
    }

    knob.innerRatio = _KNOB_INNER_RATIO  -- stored so container can resize the inner knob

    _initPartState(knob,       outerNumDetents, outerInitialPos, outerCallbackFunc)
    _initPartState(knob.inner, innerNumDetents, innerInitialPos, innerCallbackFunc)
    _calculateGeometry(knob)

    function knob:resize() _calculateGeometry(self) end

    table.insert(globApp.objects.rotaryKnobs, knob)
    globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
    if containerName then
        knob.containerFrac = { x=x, y=y, w=size, h=size, anchorPoint=anchorPoint }
        gdsGui_container_addObject(containerName, "rotaryKnob", id)
    end
end


--[[
    Draws all rotary knobs that belong to the specified page.
    For dual knobs, the outer sprite is drawn first and the inner on top of it.
    Each part switches between its released and focused sprites based on focus state.
]]
-- Draw one rotary knob.  Called by the container system for owned knobs.
function gdsGui_rotaryKnob_drawSingle(knob)
    local outerAlpha = (knob.isDual and knob.focusedPart == "inner") and 0.3 or 1.0
    love.graphics.setColor(1, 1, 1, outerAlpha)
    local outerImg = knob.isFocused and knob.imgFocused or knob.imgReleased
    love.graphics.draw(outerImg, knob.centerX, knob.centerY, knob.angle,
                       knob.scaleX, knob.scaleY, knob.imgOriginX, knob.imgOriginY)
    if knob.isDual then
        local innerAlpha = (knob.focusedPart == "outer") and 0.3 or 1.0
        love.graphics.setColor(1, 1, 1, innerAlpha)
        local innerImg = knob.inner.isFocused and knob.inner.imgFocused or knob.inner.imgReleased
        love.graphics.draw(innerImg, knob.centerX, knob.centerY, knob.inner.angle,
                           knob.inner.scaleX, knob.inner.scaleY,
                           knob.inner.imgOriginX, knob.inner.imgOriginY)
    end
    love.graphics.reset()
end


function gdsGui_rotaryKnob_draw(pageName)
    for _, knob in ipairs(globApp.objects.rotaryKnobs) do
        if knob.page ~= pageName then goto continue end
        if knob.ownerContainer      then goto continue end

        -- Outer (or only) knob
        local outerAlpha = (knob.isDual and knob.focusedPart == "inner") and 0.3 or 1.0
        love.graphics.setColor(1, 1, 1, outerAlpha)
        local outerImg = knob.isFocused and knob.imgFocused or knob.imgReleased
        love.graphics.draw(
            outerImg,
            knob.centerX, knob.centerY,
            knob.angle,
            knob.scaleX, knob.scaleY,
            knob.imgOriginX, knob.imgOriginY
        )

        -- Inner knob drawn on top (dual only)
        if knob.isDual then
            local innerAlpha = (knob.focusedPart == "outer") and 0.3 or 1.0
            love.graphics.setColor(1, 1, 1, innerAlpha)
            local innerImg = knob.inner.isFocused and knob.inner.imgFocused or knob.inner.imgReleased
            love.graphics.draw(
                innerImg,
                knob.centerX, knob.centerY,
                knob.inner.angle,
                knob.inner.scaleX, knob.inner.scaleY,
                knob.inner.imgOriginX, knob.inner.imgOriginY
            )
        end

        love.graphics.reset()
        ::continue::
    end
end


--[[
    Call from mouse/touch PRESSED handlers.

    Single knob : focuses if the press lands within the knob circle.
    Dual knob   : focuses the inner part if inside the inner circle, or the
                  outer part if inside the annular gap between the two edges.
    Only one part of a dual knob can be focused at a time; a second press while
    any part is already focused is ignored until the touch is released.

    touchId — "mouse" for mouse input, or the LÖVE touch id for touch input.
]]
function gdsGui_rotaryKnob_pressed(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, knob in ipairs(globApp.objects.rotaryKnobs) do
        if knob.page ~= activePageName then goto continue end
        -- Block new presses while this knob is already owned by a touch.
        if knob.focusTouchId ~= nil       then goto continue end
        -- Ignore touches outside the knob's owner container clip rect.
        if knob.ownerContainer and not gdsGui_container_isTouchInOwnerContainer(knob, x, y) then goto continue end

        local dx          = x - knob.centerX
        local dy          = y - knob.centerY
        local dist        = math.sqrt(dx * dx + dy * dy)
        local outerRadius = knob.size * 0.5
        local fingerAngle = math.atan2(dy, dx)

        if not knob.isDual then
            -- Single knob: any press within the circle focuses it.
            if dist <= outerRadius then
                knob.isFocused        = true
                knob.focusTouchId     = touchId
                knob.focusedPart      = "outer"
                knob._prevDetentIndex = knob.detentIndex
                knob._grabAngleOffset = fingerAngle - knob.angle
                if knob.hapticEnabled then gdsGui_haptics_vibrate() end
            end
        else
            local innerRadius = knob.inner.size * 0.5
            if dist <= innerRadius then
                -- Inside inner circle → focus inner knob.
                knob.inner.isFocused        = true
                knob.focusTouchId           = touchId
                knob.focusedPart            = "inner"
                knob.inner._prevDetentIndex = knob.inner.detentIndex
                knob.inner._grabAngleOffset = fingerAngle - knob.inner.angle
                if knob.hapticEnabled then gdsGui_haptics_vibrate() end
            elseif dist <= outerRadius then
                -- Annular gap between inner and outer edges → focus outer knob.
                knob.isFocused        = true
                knob.focusTouchId     = touchId
                knob.focusedPart      = "outer"
                knob._prevDetentIndex = knob.detentIndex
                knob._grabAngleOffset = fingerAngle - knob.angle
                if knob.hapticEnabled then gdsGui_haptics_vibrate() end
            end
        end

        ::continue::
    end
end


--[[
    Call from mouse/touch MOVED handlers.
    Routes movement to whichever part (inner or outer) is currently focused.
    Once a knob part is focused the pointer is tracked anywhere on screen —
    not just within the knob circle — giving finer precision at greater distance.

    touchId — must match the id used in gdsGui_rotaryKnob_pressed to be processed.
    dx, dy  — unused; kept for a consistent call signature with the LÖVE callbacks.
]]
function gdsGui_rotaryKnob_moved(touchId, x, y, dx, dy)
    for _, knob in ipairs(globApp.objects.rotaryKnobs) do
        if knob.focusTouchId ~= touchId then goto continue end

        local cx, cy = knob.centerX, knob.centerY
        -- Skip the tiny pivot dead zone to avoid the atan2 singularity.
        if (x - cx)^2 + (y - cy)^2 < _KNOB_CENTER_DEAD_ZONE_PX^2 then goto continue end

        local fingerAngle = math.atan2(y - cy, x - cx)

        if knob.focusedPart == "inner" then
            local snappedPos, snapIdx = _snapToDetent(fingerAngle - knob.inner._grabAngleOffset, knob.inner.numDetents)
            knob.inner.position    = snappedPos
            knob.inner.detentIndex = snapIdx
            knob.inner.angle       = _positionToAngle(snappedPos)
            _fireCallbackIfChanged(knob.inner)
        else
            -- "outer" covers both explicit outer focus and single-knob focus.
            local snappedPos, snapIdx = _snapToDetent(fingerAngle - knob._grabAngleOffset, knob.numDetents)
            knob.position    = snappedPos
            knob.detentIndex = snapIdx
            knob.angle       = _positionToAngle(snappedPos)
            _fireCallbackIfChanged(knob)
        end

        ::continue::
    end
end


--[[
    Call from mouse/touch RELEASED handlers.
    Releases whichever knob part is owned by the given touchId.
    Both inner and outer isFocused flags are cleared and focusedPart is reset.
]]
function gdsGui_rotaryKnob_released(touchId)
    for _, knob in ipairs(globApp.objects.rotaryKnobs) do
        if knob.focusTouchId == touchId then
            knob.isFocused    = false
            knob.focusTouchId = nil
            knob.focusedPart  = nil
            if knob.isDual then
                knob.inner.isFocused = false
            end
        end
    end
end
