-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    Library: choiceMenu_gdsGuiLib.lua
    A single global modal option-list popup: pick one of several text rows
    (gdsGui_choiceMenu_open), or one of a handful of icon images in a single
    row (gdsGui_choiceMenu_openImagePicker, e.g. an aircraft-type thumbnail
    picker) with optional plain text rows below it.

    Sibling to textPrompt_gdsGuiLib.lua: same "floats on top of ANY page, no
    container, only one open at a time" shape, but offers a list of options
    instead of a text field. Needed because the existing schematic
    canvas/gallery modal menu (schematic_gdsGuiLib.lua) is only ever attached
    to a canvas or gallery owner widget, so it can't be opened from a plain
    page like AircraftHome that has neither.

    Only one menu can be open at a time. onSelectFunc(optionText) and
    onCancelFunc() are global function names (strings), resolved via _G[...]
    like every other string-named callback in this library.
]]

local _menu = nil   -- {title, options, onSelect, onCancel, isImagePicker, images, extraOptions}

local _ROW_H         = 32
local _TITLE_VPAD    = 16  -- 8px top inset (matches title printf's "by + 8" below) + 8px bottom
local _BOX_W_FRAC    = 0.8
local _IMAGE_ROW_H   = 110  -- height of the single row of icon cells in an image picker
local _IMAGE_LABEL_H = 18   -- label text under each icon, inside the same row
local _IMAGE_GAP     = 10

local _imageCache = {}
local function _loadImage(path)
    if not _imageCache[path] then
        _imageCache[path] = love.graphics.newImage(path)
    end
    return _imageCache[path]
end

-- Geometry of one icon cell in an image-picker row, by 1-based index —
-- mirrors schematic_gdsGuiLib.lua's _swatchRect for its color swatch row.
local function _imageCellRect(bx, bw, count, index)
    local totalGap = _IMAGE_GAP * (count + 1)
    local size = (bw - totalGap) / count
    local ix = bx + _IMAGE_GAP + (index - 1) * (size + _IMAGE_GAP)
    return ix, size
end

-- A title longer than one line (e.g. an import/export result notice) must
-- grow the box instead of overflowing into the option rows below it — mirrors
-- schematic_gdsGuiLib.lua's own _titleHeight, same formula and same ambient-
-- font assumption (this file never calls setFont itself either).
local function _titleHeight(mw, title)
    if not title then return _ROW_H end
    local font = love.graphics.getFont()
    local _, lines = font:getWrap(title, mw)
    local numLines = math.max(1, #lines)
    return math.max(_ROW_H, numLines * font:getHeight() + _TITLE_VPAD)
end

local function _geometry()
    local w = globApp.safeScreenArea.w * _BOX_W_FRAC
    local bodyH
    if _menu.isImagePicker then
        bodyH = _IMAGE_ROW_H + _IMAGE_LABEL_H + (#_menu.extraOptions * _ROW_H)
    else
        bodyH = #_menu.options * _ROW_H
    end
    local h = _titleHeight(w, _menu.title) + bodyH + 10
    local x = globApp.safeScreenArea.x + (globApp.safeScreenArea.w - w) / 2
    local y = globApp.safeScreenArea.y + (globApp.safeScreenArea.h - h) / 2
    return x, y, w, h
end

-- A menu already open gets its own onCancel fired before being replaced,
-- rather than silently discarded with no callback at all — any app-level
-- state tied to it would otherwise never get cleared via its intended
-- cancel path. Defined ahead of gdsGui_choiceMenu_close only because it
-- needs _menu's CURRENT (pre-replacement) value; gdsGui_choiceMenu_close
-- itself is declared further below.
local function _cancelExistingMenu()
    if not _menu then return end
    local cb = _menu.onCancel
    _menu = nil
    if cb and _G[cb] then _G[cb]() end
end

function gdsGui_choiceMenu_open(title, options, onSelectFunc, onCancelFunc)
    _cancelExistingMenu()
    -- if the just-fired onCancel itself opened a new menu (chaining), _menu
    -- is already set at this point — let that one win rather than
    -- unconditionally overwriting it with the menu THIS call was about to open.
    if _menu then return end
    _menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc,
        isImagePicker = false, extraOptions = {} }
end

-- images: array of {path=string, label=string} drawn as one row of square
-- icon cells (e.g. aircraft-type thumbnails) instead of plain text rows.
-- extraOptions (optional): ordinary text rows appended below the icon row,
-- e.g. {"CANCEL"}. onSelectFunc receives the chosen image's label, or an
-- extraOptions entry's own text — same single combined options list/index
-- space schematic_gdsGuiLib.lua's swatch picker uses.
function gdsGui_choiceMenu_openImagePicker(title, images, extraOptions, onSelectFunc, onCancelFunc)
    -- _imageCellRect divides cell width by the image count; an empty list
    -- would make that a division by zero, corrupting every cell's geometry.
    if not images or #images == 0 then return end
    _cancelExistingMenu()
    -- see gdsGui_choiceMenu_open's matching comment: a chained open() from
    -- within onCancel already claimed _menu by this point — don't clobber it.
    if _menu then return end
    local options = {}
    for _, img in ipairs(images) do table.insert(options, img.label) end
    for _, opt in ipairs(extraOptions or {}) do table.insert(options, opt) end
    _menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc,
        isImagePicker = true, images = images, extraOptions = extraOptions or {} }
end

function gdsGui_choiceMenu_isOpen()
    return _menu ~= nil
end

function gdsGui_choiceMenu_close()
    _menu = nil
end

-- "outside" (outside the whole menu box — backdrop), an option index
-- (number, 1-based into _menu.options; covers both plain text rows and
-- image-picker cells/extraOptions, the same combined index space
-- gdsGui_choiceMenu_openImagePicker builds), or nil (inside the box but on
-- neither — the title area, gaps between image cells).
local function _hitMenuOption(x, y)
    local bx, by, bw, bh = _geometry()
    if x < bx or x > bx + bw or y < by or y > by + bh then return "outside" end
    local rowY = by + _titleHeight(bw, _menu.title)

    if _menu.isImagePicker then
        local n = #_menu.images
        if y < rowY + _IMAGE_ROW_H + _IMAGE_LABEL_H then
            for i = 1, n do
                local ix, size = _imageCellRect(bx, bw, n, i)
                if x >= ix and x <= ix + size then return i end
            end
            return nil
        end
        rowY = rowY + _IMAGE_ROW_H + _IMAGE_LABEL_H
        for j = 1, #_menu.extraOptions do
            if y >= rowY and y < rowY + _ROW_H then return n + j end
            rowY = rowY + _ROW_H
        end
        return nil
    end

    for i = 1, #_menu.options do
        if y >= rowY and y < rowY + _ROW_H then return i end
        rowY = rowY + _ROW_H
    end
    return nil
end

-- Always consumes the tap (the menu is modal); only records what it
-- landed on and which touch it was — gdsGui_choiceMenu_released below is
-- what actually fires onSelect/onCancel.
function gdsGui_choiceMenu_pressed(touchId, x, y)
    if not _menu then return end
    _menu._pressedHit     = _hitMenuOption(x, y)
    _menu._pressedTouchId = touchId
end

-- Fires onCancel if both this release and the matching press landed
-- outside the menu box, or onSelect(options[i]) if both landed on the
-- same option i — touch-up-inside semantics, same as
-- gdsGui_textPrompt_released: a press that drags off before releasing
-- does nothing. A second finger's release (the menu only ever tracks the
-- first one that touched it) is ignored outright.
function gdsGui_choiceMenu_released(touchId, x, y)
    if not _menu or _menu._pressedTouchId ~= touchId then return end
    local pressedHit = _menu._pressedHit
    _menu._pressedHit, _menu._pressedTouchId = nil, nil
    if pressedHit == nil then return end
    if _hitMenuOption(x, y) ~= pressedHit then return end
    if pressedHit == "outside" then
        local cb = _menu.onCancel
        _menu = nil
        if cb and _G[cb] then _G[cb]() end
    elseif type(pressedHit) == "number" then
        local opt = _menu.options[pressedHit]
        local cb = _menu.onSelect
        _menu = nil
        if cb and _G[cb] then _G[cb](opt) end
    end
end

function gdsGui_choiceMenu_draw()
    if not _menu then return end

    love.graphics.setColor(0, 0, 0, 0.65)
    love.graphics.rectangle("fill", globApp.safeScreenArea.x, globApp.safeScreenArea.y,
        globApp.safeScreenArea.w, globApp.safeScreenArea.h)

    local bx, by, bw, bh = _geometry()
    love.graphics.setColor(0.15, 0.15, 0.18, 1)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", bx, by, bw, bh)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(_menu.title, bx, by + 8, bw, "center")

    local rowY = by + _titleHeight(bw, _menu.title)

    if _menu.isImagePicker then
        local n = #_menu.images
        for i, img in ipairs(_menu.images) do
            local ix, size = _imageCellRect(bx, bw, n, i)
            love.graphics.setColor(1, 1, 1, 0.15)
            love.graphics.rectangle("line", ix, rowY, size, _IMAGE_ROW_H)

            local image = _loadImage(img.path)
            local iw, ih = image:getDimensions()
            local pad = 8
            local avail = size - pad * 2
            local scale = avail / math.max(iw, ih)
            local drawW, drawH = iw * scale, ih * scale
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(image, ix + (size - drawW) / 2, rowY + pad + (avail - drawH) / 2, 0, scale, scale)
            love.graphics.printf(img.label, ix, rowY + _IMAGE_ROW_H, size, "center")
        end
        rowY = rowY + _IMAGE_ROW_H + _IMAGE_LABEL_H
        for _, opt in ipairs(_menu.extraOptions) do
            love.graphics.setColor(1, 1, 1, 0.15)
            love.graphics.rectangle("line", bx + 4, rowY + 2, bw - 8, _ROW_H - 4)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.printf(opt, bx, rowY + 8, bw, "center")
            rowY = rowY + _ROW_H
        end
        love.graphics.setColor(1, 1, 1, 1)
        return
    end

    for _, opt in ipairs(_menu.options) do
        if opt == "CANCEL" then
            love.graphics.setColor(1, 1, 1, 0.15)
        else
            love.graphics.setColor(1, 1, 1, 0.3)
        end
        love.graphics.rectangle("line", bx + 4, rowY + 2, bw - 8, _ROW_H - 4)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(opt, bx, rowY + 8, bw, "center")
        rowY = rowY + _ROW_H
    end
end
