-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
-- container_gdsGuiLib.lua
-- Page-layout system: fixed header/footer zones + single scrollable body containing panels.
--
-- DEVELOPER USAGE (in main.lua):
--
--   -- 1) Create containers FIRST (before any widgets that belong to them):
--   gdsGui_container_create("navBar",    "MainMenu", "PILOT COMPANION", 50, 0, "pageHeader")
--   gdsGui_container_create("footBar",   "MainMenu", "",                40, 0, "pageFooter")
--   gdsGui_container_create("myPanel",   "MainMenu", "MY PANEL",        32, 0)
--
--   -- 2) Pass the container name as the last arg when creating widgets:
--   gdsGui_button_create("myBtn",   "MainMenu", ..., true, "myPanel")
--   gdsGui_outputTxtBox_create("myLabel", "MainMenu", ..., 12, "myPanel")
--   -- gdsGui_container_addObject is called automatically; no manual calls needed.
--
--   -- 3) Finalise once after all containers on a page are declared:
--   gdsGui_container_finalise("MainMenu")
--
-- addObject role: "scroll" (default) | "header" | "footer"
-- Container pageRole: nil/"body" | "pageHeader" | "pageFooter"
--   pageHeader/pageFooter: fixed zones; their headerHeight param = total zone pixel height.
--   body: auto-sizes to content and participates in page-level scroll.

gdsGui_generateConsoleMessage("info", "Containers initialized")

globApp.objects.containers       = {}
globApp.objects.pageScrollStates = {}  -- keyed by pageName

-- ---------------------------------------------------------------------------
--  PHYSICS CONSTANTS
-- ---------------------------------------------------------------------------
local CONT_FRICTION       = 3.5
local CONT_SPRING_OMEGA   = 18.0
local CONT_SPRING_K       = CONT_SPRING_OMEGA * CONT_SPRING_OMEGA
local CONT_SPRING_C       = 2.0 * CONT_SPRING_OMEGA
local CONT_RUBBER_BAND    = 0.35
local CONT_COAST_STOP_VEL = 8.0
local CONT_BOUNCE_STOP_D  = 0.5
local CONT_BOUNCE_STOP_V  = 5.0

-- ---------------------------------------------------------------------------
--  LAYOUT CONSTANTS
-- ---------------------------------------------------------------------------
local PADDING    = 8    -- px gap around/between objects inside a container
local MIN_ITEM_W = 120  -- px: min item width before layout adds a second column

-- ---------------------------------------------------------------------------
--  PAGE SCROLLBAR CONSTANTS
-- ---------------------------------------------------------------------------
local PAGE_SB_WIDTH     = 10  -- px: floating indicator strip on right edge of body
local PAGE_SB_MIN_THUMB = 16  -- px: minimum thumb height
local PAGE_SB_STEP      = 60  -- px scrolled per arrow button click

-- Arrow-button sprites (desktop only); loaded lazily on first draw.
local _pageSBImgs

local function _ensurePageSBImgs()
    if _pageSBImgs then return end
    if globApp.OperatingSystem == "iOS" or globApp.OperatingSystem == "Android" then return end
    local p = "Libraries/gds_love2d_gui/librarySprites/"
    _pageSBImgs = {
        upActive     = love.graphics.newImage(p .. "gdsLoveGUI_UpArrowButton_pushed.png"),
        upInactive   = love.graphics.newImage(p .. "gdsLoveGUI_UpArrowButton_released.png"),
        downActive   = love.graphics.newImage(p .. "gdsLoveGUI_downArrowButton_pushed.png"),
        downInactive = love.graphics.newImage(p .. "gdsLoveGUI_downArrowButton_released.png"),
    }
end

-- ---------------------------------------------------------------------------
--  PRIVATE — resize a widget to explicit pixel dimensions
-- ---------------------------------------------------------------------------

local function _setObjDimensions(obj, pixW, pixH)
    if obj.objectType == "button" then
        obj.mywidth  = pixW
        obj.myheight = pixH
        local baseImg = obj.images[globApp.BUTTON_STATES.RELEASED]
                     or obj.images[globApp.BUTTON_STATES.PRESSED]
        obj.factorWidth  = baseImg and (pixW / baseImg:getWidth())  or 1
        obj.factorHeight = baseImg and (pixH / baseImg:getHeight()) or 1

    elseif obj.objectType == "outputTextBox" then
        local sbW = (obj.scrollbar and obj.scrollbar.width) or 0
        obj.origTotalWidth = pixW
        obj.frame.width    = pixW - sbW   -- text area excludes scrollbar strip
        obj.frame.height   = pixH
        if obj.bgSprite and obj.bgSprite.sprite then
            obj.bgSprite.width  = pixW / obj.bgSprite.sprite:getWidth()
            obj.bgSprite.height = pixH / obj.bgSprite.sprite:getHeight()
        end
        obj.text.width             = obj.frame.width * 0.8
        obj.text.maxTextLineCount  = gdsGui_findMaxNumOfLinesNeeded(obj.text.font, obj.text.width, obj.text.text)
        obj.text.height            = gdsGui_general_returnFontInfo(obj.text.font, "height")
        obj.text.combinedTxtHeight = obj.text.height * obj.text.maxTextLineCount
        obj.text.lastText          = nil  -- force line reflow on next update

    elseif obj.objectType == "scrollBar" then
        obj.original.width  = pixW
        obj.original.height = pixH
        if obj.orientation == "horizontal" then
            obj.frame.height = pixH
            if obj.leftButton then
                local arrowSide = pixH
                obj.leftButton.width          = arrowSide;  obj.leftButton.height  = pixH
                obj.rightButton.width         = arrowSide;  obj.rightButton.height = pixH
                obj.leftButton.factorWidth    = arrowSide / obj.imgButtonLeftArrow_active:getWidth()
                obj.leftButton.factorHeight   = pixH / obj.imgButtonLeftArrow_active:getHeight()
                obj.rightButton.factorWidth   = arrowSide / obj.imgButtonRightArrow_active:getWidth()
                obj.rightButton.factorHeight  = pixH / obj.imgButtonRightArrow_active:getHeight()
                obj.frame.width = pixW - 2 * arrowSide
            else
                obj.frame.width = pixW
            end
            obj.bar.width = pixH;  obj.bar.height = pixH
        else  -- vertical
            obj.frame.width = pixW
            if obj.upButton then
                local arrowSide = pixW
                obj.upButton.width          = pixW;     obj.upButton.height          = arrowSide
                obj.downButton.width        = pixW;     obj.downButton.height        = arrowSide
                obj.upButton.factorWidth    = pixW / obj.imgButtonUpArrow_active:getWidth()
                obj.upButton.factorHeight   = arrowSide / obj.imgButtonUpArrow_active:getHeight()
                obj.downButton.factorWidth  = pixW / obj.imgButtonDownArrow_active:getWidth()
                obj.downButton.factorHeight = arrowSide / obj.imgButtonDownArrow_active:getHeight()
                obj.frame.height = pixH - 2 * arrowSide
            else
                obj.frame.height = pixH
            end
            obj.bar.width = pixW;  obj.bar.height = pixW
        end
        if obj.frame.img then
            if obj.orientation == "horizontal" then
                obj.frame.scaleX = obj.frame.height / obj._dimFrameW
                obj.frame.scaleY = obj.frame.width  / obj._dimFrameH
            else
                obj.frame.scaleX = obj.frame.width  / obj._dimFrameW
                obj.frame.scaleY = obj.frame.height / obj._dimFrameH
            end
        end
        if obj.bar.img then
            if obj.orientation == "horizontal" then
                obj.bar.scaleX = obj.bar.height / obj._dimBarW
                obj.bar.scaleY = obj.bar.width  / obj._dimBarH
            else
                obj.bar.scaleX = obj.bar.width  / obj._dimBarW
                obj.bar.scaleY = obj.bar.height / obj._dimBarH
            end
        end

    elseif obj.objectType == "rotaryKnob" then
        local s        = pixW   -- knobs are square; width drives size
        obj.size       = s
        local iw, ih   = obj.imgReleased:getDimensions()
        obj.scaleX     = s / iw
        obj.scaleY     = s / ih
        obj.imgOriginX = iw * 0.5
        obj.imgOriginY = ih * 0.5
        if obj.isDual then
            local ratio        = obj.innerRatio or 0.8
            obj.inner.size     = s * ratio
            local iiw, iih     = obj.inner.imgReleased:getDimensions()
            obj.inner.scaleX   = obj.inner.size / iiw
            obj.inner.scaleY   = obj.inner.size / iih
        end
    end
end

-- ---------------------------------------------------------------------------
--  PRIVATE — position a widget absolutely (used at layout time and on scroll)
-- ---------------------------------------------------------------------------

local function _initObjForContainer(obj, natX, natY)
    if obj.objectType == "button" then
        obj.myx    = math.floor(natX)
        obj.myy    = math.floor(natY)
        obj.myMaxx = obj.myx + obj.mywidth
        obj.myMaxy = obj.myy + obj.myheight

    elseif obj.objectType == "outputTextBox" then
        local dy       = natY - obj.frame.y
        obj.frame.x    = math.floor(natX)
        obj.frame.y    = math.floor(natY)
        obj.bgSprite.x = obj.frame.x
        obj.bgSprite.y = obj.frame.y
        obj.text.x     = obj.frame.x + (obj.frame.width - obj.text.width) / 2
        for _, line in ipairs(obj.text.lines) do
            line.x         = obj.text.x
            line.naturalY  = line.naturalY + dy
            line.y         = line.naturalY
            line.isVisible = (line.y + line.height > obj.frame.y) and
                             (line.y < obj.frame.y + obj.frame.height)
        end
        gdsGui_outputTxtBox_syncScrollbarGeometry(obj)

    elseif obj.objectType == "scrollBar" then
        local top  = math.floor(natY)
        local left = math.floor(natX)
        if obj.orientation == "horizontal" then
            obj.frame.y = top
            if obj.leftButton then
                obj.leftButton.x  = left
                obj.leftButton.y  = top
                obj.leftButton.centeredX  = left + (obj.leftButton.width  - obj._dimLeftW  * obj.leftButton.factorWidth)  / 2
                obj.leftButton.centeredY  = top  + (obj.leftButton.height - obj._dimLeftH  * obj.leftButton.factorHeight) / 2
                obj.rightButton.x = left + obj.original.width - obj.rightButton.width
                obj.rightButton.y = top
                obj.rightButton.centeredX = obj.rightButton.x + (obj.rightButton.width  - obj._dimRightW * obj.rightButton.factorWidth)  / 2
                obj.rightButton.centeredY = top + (obj.rightButton.height - obj._dimRightH * obj.rightButton.factorHeight) / 2
                obj.frame.x = left + obj.leftButton.width
            else
                obj.frame.x = left
            end
            obj.bar.y = top
            obj.bar.x = obj.frame.x + (obj.bar.position * (obj.frame.width - obj.bar.width))
        else  -- vertical
            if obj.upButton then
                obj.upButton.x   = left
                obj.upButton.y   = top
                obj.upButton.centeredX = left + (obj.upButton.width  - obj._dimUpW   * obj.upButton.factorWidth)  / 2
                obj.upButton.centeredY = top  + (obj.upButton.height - obj._dimUpH   * obj.upButton.factorHeight) / 2
                obj.downButton.x = left
                obj.downButton.y = top + obj.original.height - obj.downButton.height
                obj.downButton.centeredX = left + (obj.downButton.width  - obj._dimDownW * obj.downButton.factorWidth)  / 2
                obj.downButton.centeredY = obj.downButton.y + (obj.downButton.height - obj._dimDownH * obj.downButton.factorHeight) / 2
                obj.frame.y      = top + obj.upButton.height
            else
                obj.frame.y = top
            end
            obj.frame.x = left
            obj.bar.x   = left
            obj.bar.y   = obj.frame.y + (obj.bar.position * (obj.frame.height - obj.bar.height))
        end

    elseif obj.objectType == "rotaryKnob" then
        obj.x       = math.floor(natX)
        obj.y       = math.floor(natY)
        obj.centerX = obj.x + obj.size * 0.5
        obj.centerY = obj.y + obj.size * 0.5
    end
end

-- Update only the Y coordinate of a widget (called every frame during scroll).
local function _setObjY(obj, newY)
    if obj.objectType == "button" then
        obj.myy    = math.floor(newY)
        obj.myMaxy = obj.myy + obj.myheight

    elseif obj.objectType == "outputTextBox" then
        local dy       = math.floor(newY) - obj.frame.y
        obj.frame.y    = math.floor(newY)
        obj.bgSprite.y = obj.frame.y
        for _, line in ipairs(obj.text.lines) do
            line.naturalY  = line.naturalY + dy
            line.y         = line.naturalY + obj.scroll.offsetY
            line.isVisible = (line.y + line.height > obj.frame.y) and
                             (line.y < obj.frame.y + obj.frame.height)
        end
        gdsGui_outputTxtBox_syncScrollbarGeometry(obj)

    elseif obj.objectType == "scrollBar" then
        local top = math.floor(newY)
        if obj.orientation == "horizontal" then
            obj.frame.y = top
            if obj.leftButton then
                obj.leftButton.y          = top
                obj.leftButton.centeredY  = top + (obj.leftButton.height  - obj._dimLeftH  * obj.leftButton.factorHeight)  / 2
                obj.rightButton.y         = top
                obj.rightButton.centeredY = top + (obj.rightButton.height - obj._dimRightH * obj.rightButton.factorHeight) / 2
            end
            obj.bar.y = top
        else  -- vertical
            if obj.upButton then
                obj.upButton.y   = top
                obj.upButton.centeredY   = top + (obj.upButton.height  - obj._dimUpH   * obj.upButton.factorHeight)  / 2
                obj.frame.y      = top + obj.upButton.height
                obj.downButton.y = top + obj.original.height - obj.downButton.height
                obj.downButton.centeredY = obj.downButton.y + (obj.downButton.height - obj._dimDownH * obj.downButton.factorHeight) / 2
            else
                obj.frame.y = top
            end
            obj.bar.y = obj.frame.y + (obj.bar.position * (obj.frame.height - obj.bar.height))
        end

    elseif obj.objectType == "rotaryKnob" then
        obj.y       = math.floor(newY)
        obj.centerY = obj.y + obj.size * 0.5
    end
end

-- Update only the X coordinate of a widget (mirror of _setObjY, used by hScroll).
local function _setObjX(obj, newX)
    if obj.objectType == "button" then
        obj.myx    = math.floor(newX)
        obj.myMaxx = obj.myx + obj.mywidth

    elseif obj.objectType == "outputTextBox" then
        obj.frame.x    = math.floor(newX)
        if obj.bgSprite then obj.bgSprite.x = obj.frame.x end
        obj.text.x = obj.frame.x + (obj.frame.width - obj.text.width) / 2
        for _, line in ipairs(obj.text.lines) do
            line.x = obj.text.x
        end
        gdsGui_outputTxtBox_syncScrollbarGeometry(obj)

    elseif obj.objectType == "rotaryKnob" then
        obj.x       = math.floor(newX)
        obj.centerX = obj.x + obj.size * 0.5
    end
end

-- ---------------------------------------------------------------------------
--  PRIVATE — horizontal scroll helpers (pageHeader / pageFooter containers)
-- ---------------------------------------------------------------------------

-- Returns (minOffsetX, maxOffsetX) for cont.hScroll.offsetX.
-- maxOffset is always 0 (content at natural left).
local function _hScrollLimits(cont)
    if not cont.hScroll then return 0, 0 end
    local minOff = math.min(0, cont.frame.width - (cont.hScroll.contentWidth or 0))
    return minOff, 0
end

-- Shift all widgets in a header/footer container by hScroll.offsetX.
local function _applyHScroll(cont)
    if not cont.hScroll then return end
    local ox = cont.hScroll.offsetX
    for _, entry in ipairs(cont.objects) do
        _setObjX(entry.ref, entry.naturalX + ox)
    end
end

-- Called after _layoutObjects to measure the total content width and clamp offset.
local function _computeHScrollContentWidth(cont)
    if not cont.hScroll then return end
    local maxRight = cont.frame.x
    for _, entry in ipairs(cont.objects) do
        local obj   = entry.ref
        local right = entry.naturalX
        if     obj.objectType == "button"       then right = right + obj.mywidth
        elseif obj.objectType == "outputTextBox" then right = right + obj.frame.width
        elseif obj.objectType == "rotaryKnob"   then right = right + obj.size
        end
        if right > maxRight then maxRight = right end
    end
    cont.hScroll.contentWidth = math.max(0, maxRight - cont.frame.x) + PADDING
    local minOff = math.min(0, cont.frame.width - cont.hScroll.contentWidth)
    cont.hScroll.offsetX = math.max(minOff, math.min(0, cont.hScroll.offsetX))
    _applyHScroll(cont)
end

-- ---------------------------------------------------------------------------
--  PRIVATE — sub-rect geometry
-- ---------------------------------------------------------------------------

local function _computeSubrects(cont)
    local f  = cont.frame
    local hh = cont.headerHeight
    local fh = cont.footerHeight
    cont.headerRect = { x=f.x, y=f.y,                   width=f.width, height=hh }
    cont.scrollRect = { x=f.x, y=f.y + hh,              width=f.width, height=f.height - hh - fh }
    cont.footerRect = { x=f.x, y=f.y + f.height - fh,   width=f.width, height=fh }
end

-- ---------------------------------------------------------------------------
--  PRIVATE — page-level scroll helpers
-- ---------------------------------------------------------------------------

local function _pageScrollLimits(state)
    local minOff = math.min(0, state.bodyArea.height - state.contentHeight)
    return minOff, 0
end

-- Returns true when the page body content exceeds the body viewport height.
local function _isPageScrollbarVisible(state)
    return state ~= nil and
           math.min(0, state.bodyArea.height - state.contentHeight) < -0.5
end

-- Returns the scrollbar track and thumb geometry for a page scroll state.
local function _pageScrollbarGeometry(state)
    local ba        = state.bodyArea
    local isDesktop = globApp.OperatingSystem ~= "iOS" and globApp.OperatingSystem ~= "Android"
    local btnH      = isDesktop and PAGE_SB_WIDTH or 0
    local trackH    = ba.height - 2 * btnH
    local thumbH    = math.max(PAGE_SB_MIN_THUMB,
                               math.floor(trackH * ba.height / state.contentHeight))
    local maxScrollDist = state.contentHeight - ba.height
    local scrollFrac    = (maxScrollDist > 0)
                          and ((-state.scroll.offsetY) / maxScrollDist) or 0
    scrollFrac = math.max(0, math.min(1, scrollFrac))
    local trackY = ba.y + btnH
    return {
        x         = ba.x + ba.width - PAGE_SB_WIDTH,
        y         = ba.y,
        w         = PAGE_SB_WIDTH,
        h         = ba.height,
        trackY    = trackY,
        trackH    = trackH,
        thumbY    = trackY + scrollFrac * (trackH - thumbH),
        thumbH    = thumbH,
        btnH      = btnH,
        isDesktop = isDesktop,
    }
end

-- Returns true when (x, y) is within the page scrollbar strip.
local function _isTouchInPageScrollbar(state, x, y)
    if not _isPageScrollbarVisible(state) then return false end
    local g = _pageScrollbarGeometry(state)
    return x >= g.x and x <= g.x + g.w and y >= g.y and y <= g.y + g.h
end

-- Draws the page-level scrollbar as a floating overlay over the body area.
local function _drawPageScrollbar(state)
    if not _isPageScrollbarVisible(state) then return end
    local g      = _pageScrollbarGeometry(state)
    local isDark = not globApp.themeTextColor or globApp.themeTextColor[1] > 0.5
    love.graphics.setScissor()

    -- Track
    if isDark then
        love.graphics.setColor(0.15, 0.15, 0.15, 0.45)
    else
        love.graphics.setColor(0.60, 0.60, 0.60, 0.45)
    end
    love.graphics.rectangle("fill", g.x, g.trackY, g.w, g.trackH)

    -- Thumb
    local isDragging = state.pageSB and state.pageSB.isDragging
    if isDragging then
        love.graphics.setColor(isDark and 1 or 0.05, isDark and 1 or 0.05, isDark and 1 or 0.05, 1)
    elseif isDark then
        love.graphics.setColor(0.85, 0.85, 0.85, 0.80)
    else
        love.graphics.setColor(0.20, 0.20, 0.20, 0.80)
    end
    love.graphics.rectangle("fill", g.x, g.thumbY, g.w, g.thumbH)

    -- Arrow buttons (desktop only)
    if g.isDesktop then
        _ensurePageSBImgs()
        if _pageSBImgs then
            local sb   = state.pageSB
            local upAct  = sb and sb.upBtn   and sb.upBtn.isActive
            local dnAct  = sb and sb.downBtn and sb.downBtn.isActive
            local upImg  = upAct  and _pageSBImgs.upActive   or _pageSBImgs.upInactive
            local dnImg  = dnAct  and _pageSBImgs.downActive or _pageSBImgs.downInactive
            local upW, upH = upImg:getDimensions()
            local dnW, dnH = dnImg:getDimensions()
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(upImg, g.x, g.y,             0, g.w / upW, g.btnH / upH)
            love.graphics.draw(dnImg, g.x, g.y + g.h - g.btnH, 0, g.w / dnW, g.btnH / dnH)
        end
    end

    love.graphics.setColor(1, 1, 1, 1)
end

-- Move all body containers on a page by the current page scroll offset.
-- entry.naturalY stores the widget's Y at offsetY == 0 (set at layout time).
local function _applyPageScroll(pageName)
    local state = globApp.objects.pageScrollStates[pageName]
    if not state then return end
    local offsetY = state.scroll.offsetY
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == pageName and cont.pageRole == "body" then
            cont.frame.y = cont.frameNaturalY + offsetY
            _computeSubrects(cont)
            for _, entry in ipairs(cont.objects) do
                _setObjY(entry.ref, entry.naturalY + offsetY)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
--  PRIVATE — resolve anchor-point pixel position
-- ---------------------------------------------------------------------------

-- ox, oy: pixel offsets from the base rect's origin (container scroll-rect
-- top-left).  Returns {floor(x), floor(y)} of the widget's top-left corner.
local function _anchorPos(anchor, ox, oy, w, h, bx, by)
    local ax = anchor:sub(1, 1)   -- L / C / R
    local ay = anchor:sub(2, 2)   -- T / C / B
    local px = bx + ox
    local py = by + oy
    if     ax == "C" then px = px - w * 0.5
    elseif ax == "R" then px = px - w
    end
    if     ay == "C" then py = py - h * 0.5
    elseif ay == "B" then py = py - h
    end
    return { math.floor(px), math.floor(py) }
end

-- ---------------------------------------------------------------------------
--  PRIVATE — layout widgets within a single container
-- ---------------------------------------------------------------------------

-- Positions widgets using pixel-based containerFrac values (x, y, w, h in px).
-- x/y are pixel offsets from the container's scroll-rect origin; the anchor
-- point determines which corner/edge of the widget sits at that coordinate.
local function _layoutObjects(cont)
    local sr          = cont.scrollRect
    local maxContentH = 0
    local minTopY     = math.huge

    for _, entry in ipairs(cont.objects) do
        local obj = entry.ref
        local cf  = obj.containerFrac
        if not cf then goto continue end

        local baseX, baseY
        if     entry.role == "header" then baseX, baseY = cont.headerRect.x, cont.headerRect.y
        elseif entry.role == "footer" then baseX, baseY = cont.footerRect.x, cont.footerRect.y
        else                               baseX, baseY = sr.x, sr.y
        end

        local pixW = math.max(1, math.floor(cf.w))
        local pixH = math.max(1, math.floor(cf.h))
        if obj.objectType == "rotaryKnob" then pixH = pixW end

        _setObjDimensions(obj, pixW, pixH)

        local anchorW = pixW
        local anchorH = (obj.objectType == "rotaryKnob") and obj.size or pixH
        local pos     = _anchorPos(cf.anchorPoint, cf.x, cf.y, anchorW, anchorH, baseX, baseY)

        entry.naturalX = pos[1]
        entry.naturalY = pos[2]
        _initObjForContainer(obj, pos[1], pos[2])

        if entry.role == "scroll" then
            local topY   = pos[2] - sr.y
            local bottom = topY + anchorH
            if topY   < minTopY     then minTopY     = topY   end
            if bottom > maxContentH then maxContentH = bottom  end
        end

        ::continue::
    end

    -- Bottom buffer mirrors the top gap, with PADDING as a minimum so containers
    -- whose topmost widget starts at y=0 (e.g. CC-anchored) still get spacing.
    local bottomBuffer = (minTopY < math.huge) and math.max(PADDING, minTopY) or PADDING
    cont.contentHeight = math.max(0, maxContentH + bottomBuffer)
end

-- ---------------------------------------------------------------------------
--  PRIVATE — reposition widgets when a container's scroll-rect dimensions change
-- ---------------------------------------------------------------------------
-- Repositions widgets when a container's scroll-rect dimensions change.
-- Widget sizes (DIP) are never altered; only positions shift.
-- Horizontal: all objects shift by dW*0.5 regardless of anchor so the group
-- stays centred in the wider/narrower container and inter-object spacing is
-- preserved exactly.
-- Vertical: anchor-aware shift, suppressed for header/footer-role objects.
local function _layoutObjectsScaled(cont)
    local origW = cont.originalScrollWidth
    local origH = cont.originalScrollHeight
    local sr    = cont.scrollRect          -- already updated by _computeSubrects
    local dW    = sr.width  - origW        -- how much wider/narrower the scroll area is
    local dH    = sr.height - origH        -- how much taller/shorter

    local maxContentH = 0
    local minTopY     = math.huge

    for _, entry in ipairs(cont.objects) do
        local obj = entry.ref
        local cf0 = entry.origCF or obj.containerFrac
        if not cf0 then goto continue end

        local baseX, baseY
        if     entry.role == "header" then baseX, baseY = cont.headerRect.x, cont.headerRect.y
        elseif entry.role == "footer" then baseX, baseY = cont.footerRect.x, cont.footerRect.y
        else                               baseX, baseY = sr.x, sr.y
        end

        -- Sizes are density-independent and never rescaled.
        local pixW = math.max(1, cf0.w)
        local pixH = math.max(1, cf0.h)
        if obj.objectType == "rotaryKnob" then pixH = pixW end

        _setObjDimensions(obj, pixW, pixH)

        local anchorW = pixW
        local anchorH = (obj.objectType == "rotaryKnob") and obj.size or pixH

        -- Horizontal: uniform shift for all objects so spacing between them is preserved.
        local effX = cf0.x + dW * 0.5

        -- Vertical: anchor-aware, but Y shift is suppressed outside the scroll area.
        local ay   = cf0.anchorPoint:sub(2, 2)  -- T / C / B
        local effY = cf0.y
        if entry.role == "scroll" then
            if     ay == "C" then effY = cf0.y + dH * 0.5
            elseif ay == "B" then effY = cf0.y + dH
            end
        end

        local pos = _anchorPos(cf0.anchorPoint,
                               math.floor(effX), math.floor(effY),
                               anchorW, anchorH, baseX, baseY)

        entry.naturalX = pos[1]
        entry.naturalY = pos[2]
        _initObjForContainer(obj, pos[1], pos[2])

        if entry.role == "scroll" then
            local topY   = pos[2] - sr.y
            local bottom = topY + anchorH
            if topY   < minTopY     then minTopY     = topY   end
            if bottom > maxContentH then maxContentH = bottom  end
        end

        ::continue::
    end

    local bottomBuffer = (minTopY < math.huge) and math.max(PADDING, minTopY) or PADDING
    cont.contentHeight = math.max(0, maxContentH + bottomBuffer)
end

-- ---------------------------------------------------------------------------
--  PRIVATE — page-level layout
-- ---------------------------------------------------------------------------

local function _layoutPage(pageName)
    local sa = globApp.safeScreenArea

    -- Bucket containers by role.
    local headerConts, footerConts, bodyConts = {}, {}, {}
    for _, c in ipairs(globApp.objects.containers) do
        if c.page == pageName then
            if     c.pageRole == "pageHeader" then table.insert(headerConts, c)
            elseif c.pageRole == "pageFooter" then table.insert(footerConts, c)
            else                                   table.insert(bodyConts,   c)
            end
        end
    end

    -- ── pageHeader containers (stacked at top, full width) ──────────────────
    -- For these, headerHeight is the total pixel height of the fixed zone.
    local headerZoneH = 0
    for _, cont in ipairs(headerConts) do
        local h = cont.headerHeight
        cont.frame = { x=sa.x, y=sa.y + headerZoneH, width=sa.w, height=h }
        _computeSubrects(cont)
        _layoutObjects(cont)
        _computeHScrollContentWidth(cont)
        headerZoneH = headerZoneH + h
    end

    -- ── pageFooter containers (stacked at bottom, full width) ───────────────
    local footerZoneH = 0
    for _, cont in ipairs(footerConts) do
        footerZoneH = footerZoneH + cont.headerHeight
    end
    local footerCurY = sa.y + sa.h - footerZoneH
    for _, cont in ipairs(footerConts) do
        local h = cont.headerHeight
        cont.frame = { x=sa.x, y=footerCurY, width=sa.w, height=h }
        _computeSubrects(cont)
        _layoutObjects(cont)
        _computeHScrollContentWidth(cont)
        footerCurY = footerCurY + h
    end

    -- ── Body area (middle zone) ──────────────────────────────────────────────
    local bodyArea = {
        x      = sa.x,
        y      = sa.y + headerZoneH,
        width  = sa.w,
        height = sa.h - headerZoneH - footerZoneH,
    }

    if #bodyConts > 0 then
        -- First-layout detection: originalScrollWidth is nil until first finalize.
        -- At first finalize we always use single-column (portrait reference) to
        -- establish per-container original dimensions and per-object origCF.
        local isFirstLayout = not bodyConts[1].originalScrollWidth

        -- Original container width = portrait single-column body width.
        -- On subsequent layouts this drives the column count decision.
        local origContW = isFirstLayout and bodyArea.width
                                        or  bodyConts[1].originalScrollWidth

        -- Number of columns: how many original-width containers fit side by side.
        local numCols = math.max(1, math.min(#bodyConts,
                                 math.floor(bodyArea.width / origContW)))

        local contentH = 0
        local curY     = bodyArea.y

        if isFirstLayout then
            -- ── First layout: single column, capture reference dimensions ──────
            for _, cont in ipairs(bodyConts) do
                cont.frame = { x=bodyArea.x, y=curY, width=bodyArea.width, height=0 }
                _computeSubrects(cont)
                _layoutObjects(cont)
                cont.frame.height = cont.headerHeight + cont.contentHeight + cont.footerHeight

                -- Store per-container originals (portrait, single-column reference).
                cont.originalScrollWidth  = cont.scrollRect.width
                cont.originalScrollHeight = cont.contentHeight

                -- Store per-object origCF so resize can scale positions proportionally.
                for _, entry in ipairs(cont.objects) do
                    local cf = entry.ref.containerFrac
                    if cf then
                        entry.origCF = { x=cf.x, y=cf.y, w=cf.w, h=cf.h,
                                         anchorPoint=cf.anchorPoint }
                    end
                end

                cont.frameNaturalY = curY
                curY = curY + cont.frame.height
            end
            contentH = curY - bodyArea.y

        else
            -- ── Resize layout: row-based, proportional X/Y scaling ───────────

            -- Build rows of numCols containers each.
            local rows = {}
            local idx  = 1
            while idx <= #bodyConts do
                local row = {}
                for _ = 1, numCols do
                    if bodyConts[idx] then
                        table.insert(row, bodyConts[idx])
                        idx = idx + 1
                    end
                end
                table.insert(rows, row)
            end

            for _, row in ipairs(rows) do
                local numInRow = #row
                local baseW    = math.floor(bodyArea.width / numInRow)

                -- Row frame height = tallest container in the row
                -- (each cont's natural frame height = header + origScrollH + footer).
                local rowFrameH = 0
                for _, cont in ipairs(row) do
                    local fh = cont.headerHeight + cont.originalScrollHeight + cont.footerHeight
                    if fh > rowFrameH then rowFrameH = fh end
                end

                for ci, cont in ipairs(row) do
                    -- Last container fills any remaining pixel-rounding remainder.
                    local x = bodyArea.x + (ci - 1) * baseW
                    local w = (ci == numInRow)
                              and (bodyArea.x + bodyArea.width - x) or baseW

                    cont.frame = { x=x, y=curY, width=w, height=rowFrameH }
                    _computeSubrects(cont)
                    -- _computeSubrects sets scrollRect to reflect the new dimensions,
                    -- so _layoutObjectsScaled can read dW/dH directly from cont.
                    _layoutObjectsScaled(cont)
                    cont.frameNaturalY = curY
                end

                curY    = curY    + rowFrameH
            end

            contentH = curY - bodyArea.y
        end

        -- Initialise or update the page scroll state for this page.
        if not globApp.objects.pageScrollStates[pageName] then
            globApp.objects.pageScrollStates[pageName] = {
                bodyArea      = bodyArea,
                contentHeight = contentH,
                scroll = {
                    offsetY            = 0,
                    velocityY          = 0,
                    phase              = "idle",
                    isDragging         = false,
                    touchStartedInside = false,
                },
                pageSB = {
                    isDragging   = false,
                    dragStartY   = 0,
                    dragStartOff = 0,
                    upBtn        = { isActive = false },
                    downBtn      = { isActive = false },
                },
            }
        else
            local state = globApp.objects.pageScrollStates[pageName]
            state.bodyArea      = bodyArea
            state.contentHeight = contentH
            local minOff = math.min(0, bodyArea.height - contentH)
            state.scroll.offsetY   = math.max(minOff, math.min(0, state.scroll.offsetY))
            state.scroll.velocityY = 0
            state.scroll.phase     = "idle"
            if not state.pageSB then
                state.pageSB = {
                    isDragging = false, dragStartY = 0, dragStartOff = 0,
                    upBtn = { isActive = false }, downBtn = { isActive = false },
                }
            elseif not state.pageSB.upBtn then
                state.pageSB.upBtn  = { isActive = false }
                state.pageSB.downBtn = { isActive = false }
            end
            _applyPageScroll(pageName)
        end
    end
end

-- ---------------------------------------------------------------------------
--  PRIVATE — drawing helpers
-- ---------------------------------------------------------------------------

local function _setClip(clip)
    if clip then
        love.graphics.setScissor(clip.x, clip.y, clip.width, clip.height)
    end
end

local function _drawWidget(obj, clip)
    local ot = obj.objectType

    if ot == "button" then
        local img = obj.images[obj.state]
        if img then
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(img, obj.myx, obj.myy, 0, obj.factorWidth, obj.factorHeight)
        end

    elseif ot == "outputTextBox" then
        gdsGui_outputTxtBox_drawSingle(obj, clip)

    elseif ot == "scrollBar" then
        gdsGui_scrollBar_drawSingle(obj)

    elseif ot == "rotaryKnob" then
        gdsGui_rotaryKnob_drawSingle(obj)
    end

    -- Restore clip after any widget that may call love.graphics.reset().
    _setClip(clip)
end

local function _drawContainer(cont, clip)
    local f  = cont.frame
    local hr = cont.headerRect
    local fr = cont.footerRect

    -- pageHeader/pageFooter clip to their own frame so h-scrolled content
    -- doesn't bleed outside the fixed zones.
    local effectiveClip = clip
    if cont.pageRole == "pageHeader" or cont.pageRole == "pageFooter" then
        effectiveClip = f
    end

    _setClip(effectiveClip)

    -- Background + border.
    love.graphics.setColor(cont.bgColor[1], cont.bgColor[2], cont.bgColor[3], cont.bgColor[4] or 1)
    love.graphics.rectangle("fill", f.x, f.y, f.width, f.height)
    love.graphics.setColor(cont.borderColor[1], cont.borderColor[2], cont.borderColor[3], 1)
    love.graphics.rectangle("line", f.x, f.y, f.width, f.height)

    -- Header strip.
    if hr.height > 0 then
        love.graphics.setColor(cont.headerColor[1], cont.headerColor[2], cont.headerColor[3], 1)
        love.graphics.rectangle("fill", hr.x, hr.y, hr.width, hr.height)
        if cont.title and cont.title ~= "" then
            local tc = globApp.themeTextColor or {1, 1, 1, 1}
            love.graphics.setColor(tc[1], tc[2], tc[3], tc[4] or 1)
            if globApp.appFont then love.graphics.setFont(globApp.appFont) end
            love.graphics.printf(cont.title, hr.x + PADDING, hr.y + PADDING,
                                 hr.width - 2 * PADDING, "left")
        end
        for _, entry in ipairs(cont.objects) do
            if entry.role == "header" then
                _drawWidget(entry.ref, effectiveClip)
            end
        end
    end

    -- Content (scroll-role) widgets.
    for _, entry in ipairs(cont.objects) do
        if entry.role == "scroll" then
            _drawWidget(entry.ref, effectiveClip)
        end
    end

    -- Footer strip.
    if fr.height > 0 then
        _setClip(effectiveClip)
        love.graphics.setColor(cont.footerColor[1], cont.footerColor[2], cont.footerColor[3], 1)
        love.graphics.rectangle("fill", fr.x, fr.y, fr.width, fr.height)
        for _, entry in ipairs(cont.objects) do
            if entry.role == "footer" then
                _drawWidget(entry.ref, effectiveClip)
            end
        end
    end

    love.graphics.setScissor()
end

-- ---------------------------------------------------------------------------
--  PRIVATE — touch-on-widget hit test
-- ---------------------------------------------------------------------------

local function _isTouchOnWidget(obj, x, y)
    local ot = obj.objectType
    if ot == "button" then
        if obj.state == globApp.BUTTON_STATES.DEACTIVATED then return false end
        return x >= obj.myx and x <= obj.myMaxx and y >= obj.myy and y <= obj.myMaxy
    elseif ot == "outputTextBox" then
        -- Include the scrollbar strip (right of text frame) in the hit area
        local sbW = (obj.scrollbar and obj.scrollbar.width) or 0
        if not (x >= obj.frame.x and x <= obj.frame.x + obj.frame.width + sbW and
                y >= obj.frame.y and y <= obj.frame.y + obj.frame.height) then
            return false
        end
        -- Only suppress page scroll if the text content actually overflows the frame
        local contentH = obj.text and obj.text.combinedTxtHeight or 0
        return obj.frame.height - contentH < -0.5
    elseif ot == "scrollBar" then
        if obj.orientation == "horizontal" then
            local left  = obj.leftButton  and obj.leftButton.x  or obj.frame.x
            local right = obj.rightButton and (obj.rightButton.x + obj.rightButton.width) or (obj.frame.x + obj.frame.width)
            return x >= left and x <= right and
                   y >= obj.frame.y and y <= obj.frame.y + obj.frame.height
        else
            local top    = obj.upButton   and obj.upButton.y                             or obj.frame.y
            local bottom = obj.downButton and (obj.downButton.y + obj.downButton.height) or (obj.frame.y + obj.frame.height)
            return x >= obj.frame.x and x <= obj.frame.x + obj.frame.width and
                   y >= top and y <= bottom
        end
    elseif ot == "rotaryKnob" then
        return x >= obj.x and x <= obj.x + obj.size and y >= obj.y and y <= obj.y + obj.size
    end
    return false
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — creation
-- ---------------------------------------------------------------------------

-- pageRole: nil/"body" | "pageHeader" | "pageFooter"
-- For pageHeader/pageFooter, headerHeight doubles as the total fixed zone height.
function gdsGui_container_create(name, page, title, headerHeight, footerHeight, pageRole)
    local cont = {}
    cont.name          = name
    cont.page          = page
    cont.title         = title or ""
    cont.headerHeight  = headerHeight or 0
    cont.footerHeight  = footerHeight or 0
    cont.pageRole      = pageRole or "body"
    cont.objects       = {}
    cont.contentHeight = 0
    cont.frameNaturalY = 0

    cont.frame      = { x=0, y=0, width=0, height=0 }
    cont.headerRect = { x=0, y=0, width=0, height=0 }
    cont.scrollRect = { x=0, y=0, width=0, height=0 }
    cont.footerRect = { x=0, y=0, width=0, height=0 }

    cont.bgColor     = { 0.18, 0.18, 0.18, 1 }
    cont.headerColor = { 0.25, 0.25, 0.25, 1 }
    cont.footerColor = { 0.22, 0.22, 0.22, 1 }
    cont.borderColor = { 0.35, 0.35, 0.35, 1 }

    -- Horizontal scroll state (only for fixed pageHeader / pageFooter zones).
    if pageRole == "pageHeader" or pageRole == "pageFooter" then
        cont.hScroll = {
            offsetX      = 0,
            velocityX    = 0,
            phase        = "idle",
            isDragging   = false,
            touchStarted = false,
            contentWidth = 0,
        }
        cont.gestureDx = 0
        cont.gestureDy = 0
    end

    table.insert(globApp.objects.containers, cont)
    gdsGui_generateConsoleMessage("info", "Container '" .. name .. "' created on page '" .. page .. "'")
end

-- Assign an existing widget to a container.
-- role: "scroll" (default) | "header" | "footer"
function gdsGui_container_addObject(containerName, objectType, objectName, role)
    local cont
    for _, c in ipairs(globApp.objects.containers) do
        if c.name == containerName then cont = c; break end
    end
    if not cont then
        gdsGui_generateConsoleMessage("error", "gdsGui_container_addObject: container '" .. containerName .. "' not found")
        return
    end

    local obj
    if objectType == "button" then
        for _, o in ipairs(globApp.objects.buttons) do
            if o.name == objectName then obj = o; break end
        end
    elseif objectType == "outputTextBox" then
        for _, o in ipairs(globApp.objects.outputTextBox) do
            if o.name == objectName then obj = o; break end
        end
    elseif objectType == "scrollBar" then
        for _, o in ipairs(globApp.objects.scrollBars) do
            if o.id == objectName then obj = o; break end
        end
    elseif objectType == "rotaryKnob" then
        for _, o in ipairs(globApp.objects.rotaryKnobs) do
            if o.id == objectName then obj = o; break end
        end
    elseif objectType == "table" then
        for _, o in ipairs(globApp.objects.tables) do
            if o.name == objectName then obj = o; break end
        end
    elseif objectType == "inputTxtBox" then
        for _, o in ipairs(textBoxes) do
            if o.id == objectName then obj = o; break end
        end
    else
        gdsGui_generateConsoleMessage("error", "gdsGui_container_addObject: unsupported objectType '" .. objectType .. "'")
        return
    end

    if not obj then
        gdsGui_generateConsoleMessage("error", "gdsGui_container_addObject: widget '" .. objectName .. "' not found")
        return
    end

    obj.ownerContainer = containerName

    -- pageHeader/pageFooter containers have no separate scroll area; default
    -- widgets to the "header" role so they are laid out in the full frame.
    local effectiveRole = role or (
        (cont.pageRole == "pageHeader" or cont.pageRole == "pageFooter")
        and "header" or "scroll"
    )

    table.insert(cont.objects, {
        ref      = obj,
        role     = effectiveRole,
        naturalX = 0,
        naturalY = 0,
    })
end

-- Call once after all containers on a page are declared, and again on resize.
function gdsGui_container_finalise(pageName)
    _layoutPage(pageName)
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — convenience header / footer creators
-- ---------------------------------------------------------------------------
-- These wrap gdsGui_container_create so callers don't need to know about
-- pageRole or the internal height/footer-height parameters.
--
-- Widgets are added to a header or footer the same way as any container:
--   pass the header/footer name as the last "containerName" argument of any
--   widget-creation function (gdsGui_button_create, gdsGui_outputTxtBox_create …)
-- ---------------------------------------------------------------------------

-- Creates a fixed-height zone pinned to the top of the page.
--   name    : unique string identifier
--   page    : page this header belongs to
--   height  : pixel height of the zone
--   bgColor : {r,g,b[,a]} fill color; nil uses the library default dark gray
function gdsGui_pageHeader_create(name, page, height, bgColor)
    gdsGui_container_create(name, page, "", height, 0, "pageHeader")
    if bgColor then
        local cont = globApp.objects.containers[#globApp.objects.containers]
        cont.bgColor     = { bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1 }
        cont.headerColor = cont.bgColor
    end
end

-- Creates a fixed-height zone pinned to the bottom of the page.
--   name    : unique string identifier
--   page    : page this footer belongs to
--   height  : pixel height of the zone
--   bgColor : {r,g,b[,a]} fill color; nil uses the library default dark gray
function gdsGui_pageFooter_create(name, page, height, bgColor)
    gdsGui_container_create(name, page, "", height, 0, "pageFooter")
    if bgColor then
        local cont = globApp.objects.containers[#globApp.objects.containers]
        cont.bgColor     = { bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1 }
        cont.headerColor = cont.bgColor
    end
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — physics update (page-level scroll)
-- ---------------------------------------------------------------------------

function gdsGui_container_physicsUpdate(dt)
    if not dt or dt <= 0 then return end

    local activePage = gdsGui_page_currentName()

    -- ── Vertical page scroll ────────────────────────────────────────────────
    local state = globApp.objects.pageScrollStates[activePage]
    if state then
        local s = state.scroll
        if not (s.isDragging or s.phase == "idle") then
            local minOff, maxOff = _pageScrollLimits(state)
            if minOff < -0.5 then
                if s.phase == "coasting" then
                    s.velocityY = s.velocityY * math.exp(-CONT_FRICTION * dt)
                    s.offsetY   = s.offsetY   + s.velocityY * dt
                    if s.offsetY < minOff or s.offsetY > maxOff then
                        s.phase = "bouncing"
                    elseif math.abs(s.velocityY) < CONT_COAST_STOP_VEL then
                        s.phase = "idle";  s.velocityY = 0
                    end
                    _applyPageScroll(activePage)
                elseif s.phase == "bouncing" then
                    local target = math.max(minOff, math.min(maxOff, s.offsetY))
                    local disp   = s.offsetY - target
                    local acc    = (-CONT_SPRING_K * disp) + (-CONT_SPRING_C * s.velocityY)
                    s.velocityY  = s.velocityY + acc * dt
                    s.offsetY    = s.offsetY   + s.velocityY * dt
                    if math.abs(s.offsetY - target) < CONT_BOUNCE_STOP_D and
                       math.abs(s.velocityY) < CONT_BOUNCE_STOP_V then
                        s.offsetY = target;  s.velocityY = 0;  s.phase = "idle"
                    end
                    _applyPageScroll(activePage)
                end
            end
        end
    end

    -- ── Horizontal scroll for pageHeader / pageFooter containers ────────────
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == activePage and cont.hScroll then
            local hs = cont.hScroll
            if not (hs.isDragging or hs.phase == "idle") then
                local minOff, maxOff = _hScrollLimits(cont)
                if minOff < -0.5 then
                    if hs.phase == "coasting" then
                        hs.velocityX = hs.velocityX * math.exp(-CONT_FRICTION * dt)
                        hs.offsetX   = hs.offsetX   + hs.velocityX * dt
                        if hs.offsetX < minOff or hs.offsetX > maxOff then
                            hs.phase = "bouncing"
                        elseif math.abs(hs.velocityX) < CONT_COAST_STOP_VEL then
                            hs.phase = "idle";  hs.velocityX = 0
                        end
                        _applyHScroll(cont)
                    elseif hs.phase == "bouncing" then
                        local target = math.max(minOff, math.min(maxOff, hs.offsetX))
                        local disp   = hs.offsetX - target
                        local acc    = (-CONT_SPRING_K * disp) + (-CONT_SPRING_C * hs.velocityX)
                        hs.velocityX = hs.velocityX + acc * dt
                        hs.offsetX   = hs.offsetX   + hs.velocityX * dt
                        if math.abs(hs.offsetX - target) < CONT_BOUNCE_STOP_D and
                           math.abs(hs.velocityX) < CONT_BOUNCE_STOP_V then
                            hs.offsetX = target;  hs.velocityX = 0;  hs.phase = "idle"
                        end
                        _applyHScroll(cont)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — touch/mouse scroll (page-level)
-- ---------------------------------------------------------------------------

function gdsGui_container_touchScroll(id, x, y, dx, dy)
    local isGestureActive = (globApp.userInput == "slide") or love.mouse.isDown(1)
    if not isGestureActive then return end

    local activePage = gdsGui_page_currentName()
    local frameDt    = love.timer.getDelta()

    -- ── Vertical page scroll ─────────────────────────────────────────────────
    local state = globApp.objects.pageScrollStates[activePage]
    if state then
        local minOff, maxOff = _pageScrollLimits(state)
        if state.pageSB and state.pageSB.isDragging then
            -- Scrollbar thumb drag: convert thumb delta to scroll offset delta.
            if minOff < -0.5 then
                local g          = _pageScrollbarGeometry(state)
                local thumbTrack = g.trackH - g.thumbH
                if thumbTrack > 0 then
                    local ratio  = (state.contentHeight - state.bodyArea.height) / thumbTrack
                    local newOff = state.scroll.offsetY - dy * ratio
                    state.scroll.offsetY   = math.max(minOff, math.min(maxOff, newOff))
                    state.scroll.velocityY = 0
                    _applyPageScroll(activePage)
                end
            end
        elseif state.scroll.touchStartedInside then
            local s = state.scroll
            if minOff < -0.5 then
                s.isDragging = true
                s.phase      = "coasting"
                local newOff = s.offsetY + dy
                if newOff < minOff then
                    newOff = minOff + (newOff - minOff) * CONT_RUBBER_BAND
                elseif newOff > maxOff then
                    newOff = maxOff + (newOff - maxOff) * CONT_RUBBER_BAND
                end
                s.offsetY = newOff
                if frameDt > 0 then
                    s.velocityY = s.velocityY * 0.5 + (dy / frameDt) * 0.5
                end
                _applyPageScroll(activePage)
            end
        end
    end

    -- ── Horizontal scroll for pageHeader / pageFooter containers ─────────────
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == activePage and cont.hScroll and cont.hScroll.touchStarted then
            local hs = cont.hScroll
            local minOff, maxOff = _hScrollLimits(cont)
            if minOff < -0.5 then
                hs.isDragging = true
                hs.phase      = "coasting"
                local newOff = hs.offsetX + dx
                if newOff < minOff then
                    newOff = minOff + (newOff - minOff) * CONT_RUBBER_BAND
                elseif newOff > maxOff then
                    newOff = maxOff + (newOff - maxOff) * CONT_RUBBER_BAND
                end
                hs.offsetX = newOff
                if frameDt > 0 then
                    hs.velocityX = hs.velocityX * 0.5 + (dx / frameDt) * 0.5
                end
                _applyHScroll(cont)
            end
        end
    end
end

function gdsGui_container_touchReleased(x, y)
    local activePage = gdsGui_page_currentName()

    -- ── Vertical page scroll release ─────────────────────────────────────────
    local state = globApp.objects.pageScrollStates[activePage]
    if state then
        if state.pageSB then
            state.pageSB.isDragging = false
            if state.pageSB.upBtn   then state.pageSB.upBtn.isActive   = false end
            if state.pageSB.downBtn then state.pageSB.downBtn.isActive  = false end
        end
        local s = state.scroll
        if s.isDragging then
            s.isDragging         = false
            s.touchStartedInside = false
            local minOff, maxOff = _pageScrollLimits(state)
            if s.offsetY < minOff or s.offsetY > maxOff then
                s.phase = "bouncing"
            elseif math.abs(s.velocityY) > CONT_COAST_STOP_VEL then
                s.phase = "coasting"
            else
                s.phase = "idle";  s.velocityY = 0
            end
        end
        s.touchStartedInside = false
    end

    -- ── Horizontal scroll release for pageHeader / pageFooter ────────────────
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == activePage and cont.hScroll then
            local hs = cont.hScroll
            if hs.isDragging then
                hs.isDragging = false
                local minOff, maxOff = _hScrollLimits(cont)
                if hs.offsetX < minOff or hs.offsetX > maxOff then
                    hs.phase = "bouncing"
                elseif math.abs(hs.velocityX) > CONT_COAST_STOP_VEL then
                    hs.phase = "coasting"
                else
                    hs.phase = "idle";  hs.velocityX = 0
                end
            end
            hs.touchStarted = false
        end
    end
end

-- Mark scroll-start state when a touch/mouse-press lands.
-- • Body area  → marks vertical page scroll touchStartedInside (suppressed if on a widget).
-- • Header/Footer zone → marks horizontal scroll touchStarted for that container.
function gdsGui_container_markTouchStart(x, y)
    local activePage = gdsGui_page_currentName()

    -- ── Header / footer horizontal scroll start ──────────────────────────────
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == activePage and cont.hScroll then
            local f = cont.frame
            if x >= f.x and x <= f.x + f.width and
               y >= f.y and y <= f.y + f.height then
                cont.hScroll.touchStarted = true
                cont.hScroll.velocityX    = 0
            end
        end
    end

    -- ── Body vertical page scroll start ─────────────────────────────────────
    local state = globApp.objects.pageScrollStates[activePage]
    if not state then return end

    local ba = state.bodyArea
    if not (x >= ba.x and x <= ba.x + ba.width and
            y >= ba.y and y <= ba.y + ba.height) then
        return
    end

    -- Page scrollbar drag/click takes priority over content scroll.
    if _isTouchInPageScrollbar(state, x, y) then
        local g      = _pageScrollbarGeometry(state)
        local minOff = math.min(0, state.bodyArea.height - state.contentHeight)
        if g.isDesktop and y < g.trackY then
            -- Up button: scroll up one step
            state.pageSB.upBtn.isActive = true
            state.scroll.offsetY   = math.min(0, state.scroll.offsetY + PAGE_SB_STEP)
            state.scroll.velocityY = 0
            state.scroll.phase     = "idle"
            _applyPageScroll(activePage)
        elseif g.isDesktop and y >= g.trackY + g.trackH then
            -- Down button: scroll down one step
            state.pageSB.downBtn.isActive = true
            state.scroll.offsetY   = math.max(minOff, state.scroll.offsetY - PAGE_SB_STEP)
            state.scroll.velocityY = 0
            state.scroll.phase     = "idle"
            _applyPageScroll(activePage)
        else
            -- Track: start thumb drag
            state.pageSB.isDragging   = true
            state.pageSB.dragStartY   = y
            state.pageSB.dragStartOff = state.scroll.offsetY
            state.scroll.velocityY    = 0
        end
        return
    end

    -- Suppress page scroll when the touch is directly on a widget.
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == activePage and cont.pageRole == "body" then
            for _, entry in ipairs(cont.objects) do
                if _isTouchOnWidget(entry.ref, x, y) then
                    return
                end
            end
        end
    end

    state.scroll.touchStartedInside = true
    state.scroll.velocityY          = 0
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — programmatic scroll-to-panel
-- ---------------------------------------------------------------------------

-- Instantly scrolls the body so that the named container is at the top of the
-- body area.  Useful for navigation buttons in a fixed footer.
function gdsGui_container_scrollToBody(pageName, containerName)
    local state = globApp.objects.pageScrollStates[pageName]
    if not state then return end
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == pageName and cont.pageRole == "body" and cont.name == containerName then
            local minOff = math.min(0, state.bodyArea.height - state.contentHeight)
            local target = math.max(minOff, math.min(0, state.bodyArea.y - cont.frameNaturalY))
            state.scroll.offsetY   = target
            state.scroll.phase     = "idle"
            state.scroll.velocityY = 0
            _applyPageScroll(pageName)
            return
        end
    end
end

function gdsGui_container_scrollToTop(pageName)
    local state = globApp.objects.pageScrollStates[pageName]
    if not state then return end
    state.scroll.offsetY   = 0
    state.scroll.velocityY = 0
    state.scroll.phase     = "idle"
    _applyPageScroll(pageName)
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — container clip hit-test
-- ---------------------------------------------------------------------------

-- Returns true when (x,y) is within the visible clip rect of obj's owner container.
-- • body containers  → clip is the page body area (between fixed header and footer).
-- • header/footer    → clip is the container's own frame.
-- • no ownerContainer → always true (standalone widget).
function gdsGui_container_isTouchInOwnerContainer(obj, x, y)
    if not obj.ownerContainer then return true end
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.name == obj.ownerContainer then
            if cont.pageRole == "body" then
                local state = globApp.objects.pageScrollStates[cont.page]
                if state then
                    local ba = state.bodyArea
                    return x >= ba.x and x <= ba.x + ba.width and
                           y >= ba.y and y <= ba.y + ba.height
                end
                return true
            end
            local f = cont.frame
            return x >= f.x and x <= f.x + f.width and
                   y >= f.y and y <= f.y + f.height
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — resize
-- ---------------------------------------------------------------------------

function gdsGui_container_resize(pageName)
    _layoutPage(pageName or gdsGui_page_currentName())
end

-- Re-runs a full layout from containerFrac (not origCF), then updates
-- originalScrollHeight and origCF so future window-resize layouts are correct.
-- Call this after updating containerFrac.h/y on any widgets (e.g. font resize).
function gdsGui_container_relayoutPage(pageName)
    local sa = globApp.safeScreenArea

    local headerConts, footerConts, bodyConts = {}, {}, {}
    for _, c in ipairs(globApp.objects.containers) do
        if c.page == pageName then
            if     c.pageRole == "pageHeader" then table.insert(headerConts, c)
            elseif c.pageRole == "pageFooter" then table.insert(footerConts, c)
            else                                   table.insert(bodyConts,   c)
            end
        end
    end

    local headerZoneH = 0
    for _, cont in ipairs(headerConts) do
        local h = cont.headerHeight
        cont.frame = { x=sa.x, y=sa.y + headerZoneH, width=sa.w, height=h }
        _computeSubrects(cont)
        _layoutObjects(cont)
        headerZoneH = headerZoneH + h
    end

    local footerZoneH = 0
    for _, cont in ipairs(footerConts) do footerZoneH = footerZoneH + cont.headerHeight end
    local footerCurY = sa.y + sa.h - footerZoneH
    for _, cont in ipairs(footerConts) do
        local h = cont.headerHeight
        cont.frame = { x=sa.x, y=footerCurY, width=sa.w, height=h }
        _computeSubrects(cont)
        _layoutObjects(cont)
        footerCurY = footerCurY + h
    end

    local bodyArea = {
        x=sa.x, y=sa.y + headerZoneH,
        width=sa.w, height=sa.h - headerZoneH - footerZoneH,
    }

    local contentH = 0
    local curY = bodyArea.y
    for _, cont in ipairs(bodyConts) do
        cont.frame = { x=bodyArea.x, y=curY, width=bodyArea.width, height=0 }
        _computeSubrects(cont)
        _layoutObjects(cont)
        cont.frame.height = cont.headerHeight + cont.contentHeight + cont.footerHeight

        -- Refresh reference dimensions so the next window-resize uses the
        -- new font-size heights rather than the old originals.
        cont.originalScrollWidth  = cont.scrollRect.width
        cont.originalScrollHeight = cont.contentHeight
        for _, entry in ipairs(cont.objects) do
            local cf = entry.ref.containerFrac
            if cf then
                entry.origCF = { x=cf.x, y=cf.y, w=cf.w, h=cf.h,
                                 anchorPoint=cf.anchorPoint }
            end
        end

        cont.frameNaturalY = curY
        curY = curY + cont.frame.height
    end
    contentH = curY - bodyArea.y

    local state = globApp.objects.pageScrollStates[pageName]
    if state then
        state.bodyArea      = bodyArea
        state.contentHeight = contentH
        local minOff = math.min(0, bodyArea.height - contentH)
        if state.scroll.offsetY < minOff then state.scroll.offsetY = minOff end
        if state.scroll.offsetY > 0 then state.scroll.offsetY = 0 end
    end
end

-- ---------------------------------------------------------------------------
--  PUBLIC API — draw
-- ---------------------------------------------------------------------------

function gdsGui_container_draw(pageName)
    local state    = globApp.objects.pageScrollStates[pageName]
    local bodyClip = state and state.bodyArea

    -- Pass 1: body containers (clipped to body area so they can't bleed into
    -- the fixed header/footer zones when partially scrolled off-screen).
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == pageName and cont.pageRole == "body" then
            _drawContainer(cont, bodyClip)
        end
    end

    -- Page-level scrollbar overlay: drawn above body content, below fixed zones.
    if state then _drawPageScrollbar(state) end

    love.graphics.reset()
end

-- Draws only the fixed header/footer containers for a page.
-- Called from love.draw() AFTER gdsGui_page_drawUnsafeAreaOverlay() so the
-- header/footer always renders on top of the unsafe-area mask, covering the
-- overlap pixels and eliminating any gap at the safe-area boundary.
function gdsGui_container_drawFixed(pageName)
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.page == pageName and cont.pageRole ~= "body" then
            _drawContainer(cont, nil)
        end
    end
    love.graphics.reset()
end
