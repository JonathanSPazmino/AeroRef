-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    lib_haptics.lua
    Single entry-point for haptic feedback across all GUI objects.
    Safely no-ops on desktop and simulator platforms where vibration is
    not supported — no error is raised regardless of platform.
]]

function gdsGui_haptics_vibrate()
    if appSettings and appSettings.hapticsEnabled == false then return end
    if love.system and love.system.vibrate then
        pcall(love.system.vibrate, 0.05)
    end
end
