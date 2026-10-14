-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    Library: textPrompt_gdsGuiLib.lua
    A single global modal text-entry popup (name/rename prompts, etc).

    Deliberately NOT built on inputTxtBox_gdsGuiLib.lua: that widget is a
    labeled, container-managed form field (it only draws when placed inside a
    container via gdsGui_container_addObject), whereas this needs to float on
    top of ANY page, with no container, for short one-line values only. It
    captures love.textinput/keypressed directly, the same OS text-input APIs
    inputTxtBox uses internally.

    Only one prompt can be open at a time. onConfirmFunc/onCancelFunc are
    global function names (strings), resolved via _G[...] like every other
    string-named callback in this library. onConfirmFunc receives the final
    text as its only argument; onCancelFunc receives nothing.
]]

local _prompt = nil   -- {title, buffer, maxChars, onConfirm, onCancel}

local _MAX_CHARS_DEFAULT = 24
local _BOX_W_FRAC = 0.8
local _BOX_H_PX   = 140
local _BTN_H_PX   = 40

local function _geometry()
    local w = globApp.safeScreenArea.w * _BOX_W_FRAC
    local h = _BOX_H_PX
    local x = globApp.safeScreenArea.x + (globApp.safeScreenArea.w - w) / 2
    local y = globApp.safeScreenArea.y + (globApp.safeScreenArea.h - h) / 2
    return x, y, w, h
end

function gdsGui_textPrompt_open(title, initialText, maxChars, onConfirmFunc, onCancelFunc)
    -- A prompt already open gets its own onCancel fired before being
    -- replaced, rather than silently discarded with no callback at all —
    -- any app-level state tied to it (e.g. a pending rename target) would
    -- otherwise never get cleared via its intended cancel path.
    if _prompt then gdsGui_textPrompt_cancel() end
    _prompt = {
        title = title, buffer = initialText or "", maxChars = maxChars or _MAX_CHARS_DEFAULT,
        onConfirm = onConfirmFunc, onCancel = onCancelFunc,
    }
    local x, y, w, h = _geometry()
    love.keyboard.setTextInput(true, x, y, w, h)
end

function gdsGui_textPrompt_isOpen()
    return _prompt ~= nil
end

function gdsGui_textPrompt_close()
    _prompt = nil
    love.keyboard.setTextInput(false)
end

function gdsGui_textPrompt_confirm()
    if not _prompt then return end
    local cb, buf = _prompt.onConfirm, _prompt.buffer
    gdsGui_textPrompt_close()
    if cb and _G[cb] then _G[cb](buf) end
end

function gdsGui_textPrompt_cancel()
    if not _prompt then return end
    local cb = _prompt.onCancel
    gdsGui_textPrompt_close()
    if cb and _G[cb] then _G[cb]() end
end

-- Called from love.textinput when a prompt is open (general_gdsGuiLib.lua).
function gdsGui_textPrompt_textinput(t)
    if not _prompt then return end
    -- maxChars counts codepoints, not bytes, so a multi-byte UTF-8 buffer
    -- near the limit is measured the same way deletion below measures it
    -- (via utf8.offset) rather than letting #buffer undercount and allow
    -- a few extra bytes through.
    local utf8 = require("utf8")
    if utf8.len(_prompt.buffer) < _prompt.maxChars then
        _prompt.buffer = _prompt.buffer .. t
    end
end

-- Called from love.keypressed when a prompt is open (general_gdsGuiLib.lua).
function gdsGui_textPrompt_keypressed(key)
    if not _prompt then return end
    if key == "backspace" or key == "delete" then
        local utf8 = require("utf8")
        local byteoffset = utf8.offset(_prompt.buffer, -1)
        if byteoffset then _prompt.buffer = string.sub(_prompt.buffer, 1, byteoffset - 1) end
    elseif key == "return" or key == "kpenter" then
        gdsGui_textPrompt_confirm()
    elseif key == "escape" then
        gdsGui_textPrompt_cancel()
    end
end

-- "CANCEL", "OK", "outside" (outside the whole dialog box — backdrop), or
-- nil (inside the box but on neither button). Mirrors choiceMenu_gdsGuiLib
-- .lua's _hitMenuOption, including its "outside" case — that one already
-- dismisses on an outside tap; this prompt didn't, which read as an
-- inconsistency between the two modal types (the only way out was
-- explicitly hitting CANCEL/OK).
local function _hitButton(x, y)
    local bx, by, bw, bh = _geometry()
    if x < bx or x > bx + bw or y < by or y > by + bh then return "outside" end
    local btnY = by + bh - _BTN_H_PX - 10
    local cancelX, cancelW = bx + 8, bw / 2 - 12
    local okX, okW = bx + bw / 2 + 4, bw / 2 - 12
    if y >= btnY and y <= btnY + _BTN_H_PX then
        if x >= cancelX and x <= cancelX + cancelW then return "CANCEL" end
        if x >= okX and x <= okX + okW then return "OK" end
    end
    return nil
end

-- Called from the mouse/touch pressed dispatchers when a prompt is open.
-- Always consumes the tap (the prompt is modal); only records what it
-- landed on and which touch it was — gdsGui_textPrompt_released below is
-- what actually fires CANCEL/OK/the outside-tap cancel. Only the first
-- finger down gets tracked, same as choiceMenu's menu — a second one
-- touching the prompt while the first is still held must not hijack or
-- silently discard the first finger's in-progress press/release pair.
function gdsGui_textPrompt_pressed(touchId, x, y)
    if not _prompt then return end
    if _prompt._pressedTouchId ~= nil and _prompt._pressedTouchId ~= touchId then return end
    _prompt._pressedButton  = _hitButton(x, y)
    _prompt._pressedTouchId = touchId
end

-- Called from the mouse/touch released dispatchers when a prompt is open.
-- Fires CANCEL/OK/the outside cancel only if THIS release lands on the
-- SAME target the matching press landed on (touch-up-inside semantics) —
-- a press on OK dragged off and released elsewhere does nothing, matching
-- how a real button behaves. A second finger's release (the prompt only
-- ever tracks the first one that touched it) is ignored outright.
function gdsGui_textPrompt_released(touchId, x, y)
    if not _prompt or _prompt._pressedTouchId ~= touchId then return end
    local pressedButton = _prompt._pressedButton
    _prompt._pressedButton, _prompt._pressedTouchId = nil, nil
    if not pressedButton then return end
    if _hitButton(x, y) ~= pressedButton then return end
    if pressedButton == "CANCEL" or pressedButton == "outside" then
        gdsGui_textPrompt_cancel()
    elseif pressedButton == "OK" then
        gdsGui_textPrompt_confirm()
    end
end

function gdsGui_textPrompt_draw()
    if not _prompt then return end

    love.graphics.setColor(0, 0, 0, 0.65)
    love.graphics.rectangle("fill", globApp.safeScreenArea.x, globApp.safeScreenArea.y,
        globApp.safeScreenArea.w, globApp.safeScreenArea.h)

    local bx, by, bw, bh = _geometry()
    love.graphics.setColor(0.15, 0.15, 0.18, 1)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", bx, by, bw, bh)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(_prompt.title, bx, by + 10, bw, "center")

    local fieldY = by + 40
    love.graphics.setColor(0.05, 0.05, 0.07, 1)
    love.graphics.rectangle("fill", bx + 10, fieldY, bw - 20, 30)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("line", bx + 10, fieldY, bw - 20, 30)
    love.graphics.printf(_prompt.buffer .. "|", bx + 16, fieldY + 6, bw - 32, "left")

    local btnY = by + bh - _BTN_H_PX - 10
    love.graphics.setColor(1, 1, 1, 0.15)
    love.graphics.rectangle("line", bx + 8, btnY, bw / 2 - 12, _BTN_H_PX)
    love.graphics.rectangle("line", bx + bw / 2 + 4, btnY, bw / 2 - 12, _BTN_H_PX)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("CANCEL", bx + 8, btnY + 12, bw / 2 - 12, "center")
    love.graphics.printf("OK", bx + bw / 2 + 4, btnY + 12, bw / 2 - 12, "center")
end
