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

local _prompt = nil   -- {title, buffer, maxChars, onConfirm, onCancel, hint, rejectFlash}

local _MAX_CHARS_DEFAULT = 24
local _BOX_W_FRAC = 0.8
local _BOX_H_PX   = 140
local _BTN_H_PX   = 40
local _HINT_H_PX  = 24  -- extra box height reserved for the constraint hint row, only when one is set

-- How long the input field's border/fill flashes red after a keystroke is
-- rejected (numericOnly's character filter, the one-decimal-point rule, or
-- the maxChars cap) — see gdsGui_textPrompt_textinput and
-- gdsGui_textPrompt_update. Previously a rejected keystroke just silently
-- didn't land, with nothing on screen telling the user why.
local _REJECT_FLASH_SECONDS = 0.35

local function _geometry()
    local w = globApp.safeScreenArea.w * _BOX_W_FRAC
    local h = _BOX_H_PX + ((_prompt and _prompt.hint) and _HINT_H_PX or 0)
    local x = globApp.safeScreenArea.x + (globApp.safeScreenArea.w - w) / 2
    local y = globApp.safeScreenArea.y + (globApp.safeScreenArea.h - h) / 2
    return x, y, w, h
end

-- numericOnly (optional, false by default): when true, every character
-- typed via gdsGui_textPrompt_textinput below that isn't a digit, or a
-- SECOND "." (one decimal point is allowed), is silently dropped instead
-- of appended — rather than letting anything through and validating
-- after the fact, so the field can never even contain something like
-- "24V" or "abc" to begin with. initialText is NOT filtered (the caller's
-- own responsibility — every current numericOnly caller already only
-- ever seeds it with "" or a known-numeric tostring(...) value).
-- hint (optional): a short constraint line drawn under the input field
-- (e.g. "e.g. 24 or 28") so the format is communicated UP FRONT instead of
-- only being caught after a failed submission. numericOnly with no
-- explicit hint falls back to a generic one, so every numeric field gets
-- SOME up-front guidance even if a caller doesn't pass its own.
function gdsGui_textPrompt_open(title, initialText, maxChars, onConfirmFunc, onCancelFunc, numericOnly, hint)
    -- A prompt already open gets its own onCancel fired before being
    -- replaced, rather than silently discarded with no callback at all —
    -- any app-level state tied to it (e.g. a pending rename target) would
    -- otherwise never get cleared via its intended cancel path.
    if _prompt then gdsGui_textPrompt_cancel() end
    if not hint and numericOnly then hint = "NUMBERS ONLY — ONE DECIMAL POINT MAX" end
    _prompt = {
        title = title, buffer = initialText or "", maxChars = maxChars or _MAX_CHARS_DEFAULT,
        onConfirm = onConfirmFunc, onCancel = onCancelFunc, numericOnly = numericOnly or false,
        hint = hint, rejectFlash = 0,
    }
    local x, y, w, h = _geometry()
    love.keyboard.setTextInput(true, x, y, w, h)
end

-- Called from gdsGui_update(dt) (general_gdsGuiLib.lua) whenever a prompt is
-- open, to decay the reject-flash timer set by gdsGui_textPrompt_textinput.
function gdsGui_textPrompt_update(dt)
    if not _prompt or _prompt.rejectFlash <= 0 then return end
    _prompt.rejectFlash = math.max(0, _prompt.rejectFlash - dt)
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
    -- numericOnly: reject anything that isn't a digit, or a second "." —
    -- checked per INPUT EVENT (t can be more than one character on some
    -- input methods), not per codepoint, so a whole paste/IME commit is
    -- accepted or rejected as one unit rather than silently keeping just
    -- its digits.
    local combined = _prompt.buffer .. t
    if _prompt.numericOnly then
        if t:find("[^%d%.]") then
            _prompt.rejectFlash = _REJECT_FLASH_SECONDS
            return
        end
        -- checked against the COMBINED string, not just "does t have a dot
        -- and does the existing buffer have one" — otherwise pasting a
        -- multi-dot chunk like "1.2.3" into an empty/dot-less buffer passed
        -- both halves of that check and landed whole.
        if combined:find("%..*%.") then
            _prompt.rejectFlash = _REJECT_FLASH_SECONDS
            return
        end
    end
    -- maxChars counts codepoints, not bytes, so a multi-byte UTF-8 buffer
    -- near the limit is measured the same way deletion below measures it
    -- (via utf8.offset) rather than letting #buffer undercount and allow
    -- a few extra bytes through. Checked against the COMBINED length, not
    -- just the pre-append buffer length — otherwise a multi-character t
    -- (paste/IME commit) could push the buffer past maxChars in one event.
    local utf8 = require("utf8")
    local combinedLen = utf8.len(combined)
    if combinedLen and combinedLen <= _prompt.maxChars then
        _prompt.buffer = combined
    else
        _prompt.rejectFlash = _REJECT_FLASH_SECONDS
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
    -- Border flashes red for _REJECT_FLASH_SECONDS right after a rejected
    -- keystroke (see gdsGui_textPrompt_textinput) instead of the keystroke
    -- just silently not landing with no on-screen explanation.
    if _prompt.rejectFlash > 0 then
        local a = _prompt.rejectFlash / _REJECT_FLASH_SECONDS
        love.graphics.setColor(1, 0.2, 0.2, a)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", bx + 10, fieldY, bw - 20, 30)
        love.graphics.setLineWidth(1)
    else
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("line", bx + 10, fieldY, bw - 20, 30)
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(_prompt.buffer .. "|", bx + 16, fieldY + 6, bw - 32, "left")

    if _prompt.hint then
        love.graphics.setColor(0.65, 0.65, 0.65, 1)
        love.graphics.printf(_prompt.hint, bx + 10, fieldY + 34, bw - 20, "center")
        love.graphics.setColor(1, 1, 1, 1)
    end

    local btnY = by + bh - _BTN_H_PX - 10
    love.graphics.setColor(1, 1, 1, 0.15)
    love.graphics.rectangle("line", bx + 8, btnY, bw / 2 - 12, _BTN_H_PX)
    love.graphics.rectangle("line", bx + bw / 2 + 4, btnY, bw / 2 - 12, _BTN_H_PX)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("CANCEL", bx + 8, btnY + 12, bw / 2 - 12, "center")
    love.graphics.printf("OK", bx + bw / 2 + 4, btnY + 12, bw / 2 - 12, "center")
end
