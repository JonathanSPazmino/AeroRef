-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    lib_haptics.lua
    Single entry-point for haptic feedback across all GUI objects.
    Safely no-ops on desktop and simulator platforms where vibration is
    not supported — no error is raised regardless of platform.

    gdsGui_haptics_feedback(style) plays one of iOS's feedback styles:
        "selection"  a tick as a choice changes (a pipe snapping onto a port)
        "light"      a small thing committed (a port placed)
        "medium"     a bigger one (a pipe connected, move mode unlocked)
        "heavy"
        "success" / "warning" / "error"   an outcome (warning: a destructive
                                          confirm fired; error: refused)
    On iOS these go to UIKit's own feedback generators through LuaJIT's FFI,
    the same taps native apps play. love.system.vibrate can't do that on iOS:
    there it plays the long system buzz whatever duration it's given. If the
    native route isn't available, iOS falls back to that buzz for the strong
    styles only, and skips the subtle ones rather than buzzing for a tick.
    Elsewhere (Android) each style is a short vibration of its own length.
]]

local _haptics = {
    MIN_INTERVAL = 0.05, -- seconds; a burst of events (fast dragging) plays once, not as a buzz
    lastAt = -math.huge,
    lastRank = 0,
    -- Within MIN_INTERVAL only a stronger style than the last one still plays,
    -- so an outcome (a pipe connected) isn't swallowed by the tick just before it.
    ranks = { selection = 1, light = 2, medium = 3, heavy = 4, success = 5, warning = 5, error = 5 },
    -- Android vibration lengths, seconds.
    durations = { selection = 0.01, light = 0.015, medium = 0.03, heavy = 0.05, success = 0.03, warning = 0.05, error = 0.07 },
    -- Styles worth the full system buzz when iOS has nothing finer.
    strongOnIOS = { medium = true, heavy = true, success = true, warning = true, error = true },
    native = nil, -- false once the iOS route has failed; else the table _haptics.loadNative builds
}

-- UIKit's feedback generators, reached through the Objective-C runtime with
-- LuaJIT's FFI. objc_msgSend is cast to each exact signature it's called
-- with, as arm64 requires. Generators are made once and kept. Returns nil if
-- any of it is missing (not iOS, no FFI, an older iOS).
function _haptics.loadNative()
    if not (love.system and love.system.getOS and love.system.getOS() == "iOS") then return nil end
    local okFfi, ffi = pcall(require, "ffi")
    if not okFfi then return nil end
    local okDef = pcall(ffi.cdef, [[
        typedef struct objc_object *gdsHaptics_id;
        typedef struct objc_selector *gdsHaptics_SEL;
        gdsHaptics_id objc_getClass(const char *name);
        gdsHaptics_SEL sel_registerName(const char *name);
        void objc_msgSend(void);
    ]])
    if not okDef then return nil end
    local C = ffi.C
    local send = C.objc_msgSend
    local msgId = ffi.cast("gdsHaptics_id (*)(gdsHaptics_id, gdsHaptics_SEL)", send)
    local msgIdLong = ffi.cast("gdsHaptics_id (*)(gdsHaptics_id, gdsHaptics_SEL, long)", send)
    local msgVoid = ffi.cast("void (*)(gdsHaptics_id, gdsHaptics_SEL)", send)
    local msgVoidLong = ffi.cast("void (*)(gdsHaptics_id, gdsHaptics_SEL, long)", send)
    local sel = function(name) return C.sel_registerName(name) end
    local function class(name)
        local cls = C.objc_getClass(name)
        if cls == nil then error("no class " .. name) end
        return cls
    end
    local function new(className, styleArg)
        local obj = msgId(class(className), sel("alloc"))
        if styleArg then return msgIdLong(obj, sel("initWithStyle:"), styleArg) end
        return msgId(obj, sel("init"))
    end
    -- UIImpactFeedbackStyle: light 0, medium 1, heavy 2.
    -- UINotificationFeedbackType: success 0, warning 1, error 2.
    local impacts = { light = new("UIImpactFeedbackGenerator", 0), medium = new("UIImpactFeedbackGenerator", 1),
        heavy = new("UIImpactFeedbackGenerator", 2) }
    local selection = new("UISelectionFeedbackGenerator")
    local notification = new("UINotificationFeedbackGenerator")
    local notices = { success = 0, warning = 1, error = 2 }
    local selImpact, selChanged, selNotify, selPrepare =
        sel("impactOccurred"), sel("selectionChanged"), sel("notificationOccurred:"), sel("prepare")
    return {
        play = function(style)
            if impacts[style] then
                msgVoid(impacts[style], selImpact)
                msgVoid(impacts[style], selPrepare)
            elseif notices[style] then
                msgVoidLong(notification, selNotify, notices[style])
                msgVoid(notification, selPrepare)
            else
                msgVoid(selection, selChanged)
                msgVoid(selection, selPrepare)
            end
        end,
    }
end

function _haptics.enabled()
    return not (appSettings and appSettings.hapticsEnabled == false)
end

-- One feedback tap in the given style (see the header); "medium" if none.
function gdsGui_haptics_feedback(style)
    style = style or "medium"
    if not _haptics.enabled() then return end
    local now = love.timer and love.timer.getTime() or 0
    local rank = _haptics.ranks[style] or 3
    if now - _haptics.lastAt < _haptics.MIN_INTERVAL and rank <= _haptics.lastRank then return end
    _haptics.lastAt, _haptics.lastRank = now, rank

    if _haptics.native == nil then
        local ok, native = pcall(_haptics.loadNative)
        _haptics.native = (ok and native) or false
    end
    if _haptics.native then
        if pcall(_haptics.native.play, style) then return end
        _haptics.native = false
    end

    if not (love.system and love.system.vibrate) then return end
    local isIOS = love.system.getOS and love.system.getOS() == "iOS"
    if isIOS and not _haptics.strongOnIOS[style] then return end
    pcall(love.system.vibrate, _haptics.durations[style] or 0.03)
end

-- The original single-strength entry point (buttons, knobs, scrollbars,
-- tables), unchanged: one 0.05 s vibration, unthrottled.
function gdsGui_haptics_vibrate()
    if not _haptics.enabled() then return end
    if love.system and love.system.vibrate then
        pcall(love.system.vibrate, 0.05)
    end
end
