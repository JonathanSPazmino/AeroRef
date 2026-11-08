-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[app_config.lua
	contains all app configurations]]

function love.conf(t)

	t.identity = "AeroRef"     -- The name of the save directory (string)
    t.appendidentity = false            -- Search files in source directory before save directory (boolean)
    t.version = "12.0"                  -- The LÖVE version this game was made for (string)
    t.console = false                   -- Attach a console (boolean, Windows only)
    t.highdpi = true                    -- Enable high-dpi mode for the window on a Retina display (boolean)
    t.accelerometerjoystick = false     -- Enable the accelerometer on iOS and Android by exposing it as a Joystick (boolean)
    t.externalstorage = false           -- True to save files (and read from the save directory) in external storage on Android (boolean) 
 
    t.audio.mic = false                 -- Request and use microphone capabilities in Android (boolean)
    t.audio.mixwithsystem = true        -- Keep background music playing when opening LOVE (boolean, iOS and Android only)

    -- On: blends the glow halo, the pipe wall/body/light/fluid/streak
    -- layers, and the dashed color-sequence wires (an ambiguous multi-
    -- source node) in linear light instead of raw sRGB, so overlapping
    -- semi-transparent layers mix the way they'd actually look instead of
    -- muddying/darkening at the seams. Changes how every existing alpha
    -- value and palette color actually renders -- if anything reads
    -- noticeably off (too washed out/too dark) after this, it's a palette
    -- value to retune, not a sign this should go back to false.
    t.graphics.gammacorrect = true      -- Enable gamma-correct rendering, when supported by the system (boolean)

    t.window.title = "AeroRef"            -- The window title (string)
    t.window.icon = nil   -- Filepath to an image to use as the window's icon (string)
    t.window.width = 375 				-- The window width (number)
    t.window.height = 667 				-- The window height (number)
    t.window.borderless = false         -- Remove all border visuals from the window (boolean)
    t.window.resizable = true           -- Let the window be user-resizable (boolean)
    t.window.minwidth = 375             -- Minimum window width if the window is resizable (number)
    t.window.minheight = 667            -- Minimum window height if the window is resizable (number)
    t.window.fullscreen = false         -- Enable fullscreen (boolean)
    t.window.fullscreentype = "exclusive" -- Choose between "desktop" fullscreen or "exclusive" fullscreen mode (string)
    t.window.vsync = 1                  -- Vertical sync mode (number)
    -- Off, not 4: with it on, this LÖVE 12 (pre-release — see changes.txt)
    -- Metal backend hard-crashes ("RenderPass Descriptor Validation...
    -- resolveTexture" assertions, Xcode console) the instant the glow
    -- shader's offscreen canvases (schematic_gdsGuiLib.lua's _glow) become
    -- the active render target — Debug-only (Metal API Validation isn't
    -- run for Release/Archive builds, which is why this only ever showed
    -- up as a black screen on an Xcode Run, not in the installed app). See
    -- _glow.ensureResources's own comment for the two variants hit and
    -- ruled out before landing here. Revisit once the engine's MSAA+Canvas
    -- interaction is solid enough to turn this back on.
    t.window.msaa = 0                   -- Multi-sampled antialiasing: smooth edges on pipes, outlines, circles and rounded menus (number)
    t.window.depth = nil                -- The number of bits per sample in the depth buffer
    t.window.stencil = nil              -- The number of bits per sample in the stencil buffer
    t.window.displayindex = 1           -- Index of the monitor to show the window in (number)
    t.window.usedpiscale = true         -- Enable automatic DPI scaling when highdpi is set to true as well (boolean)
    t.window.orientation = "portrait"  -- Lock to portrait on mobile (iOS/Android)
    t.window.x = nil                    -- The x-coordinate of the window's position in the specified display (number)
    t.window.y = 40                    -- The y-coordinate of the window's position in the specified display (number)
 
    t.modules.audio = true              -- Enable the audio module (boolean)
    t.modules.data = true               -- Enable the data module (boolean)
    t.modules.event = true              -- Enable the event module (boolean)
    t.modules.font = true               -- Enable the font module (boolean)
    t.modules.graphics = true           -- Enable the graphics module (boolean)
    t.modules.image = true              -- Enable the image module (boolean)
    t.modules.joystick = false           -- Enable the joystick module (boolean)
    t.modules.keyboard = true           -- Enable the keyboard module (boolean)
    t.modules.math = true               -- Enable the math module (boolean)
    t.modules.mouse = true              -- Enable the mouse module (boolean)
    t.modules.physics = false           -- Enable the physics module (boolean)
    t.modules.sound = true              -- Enable the sound module (boolean)
    t.modules.system = true             -- Enable the system module (boolean)
    t.modules.thread = true             -- Enable the thread module (boolean)
    t.modules.timer = true              -- Enable the timer module (boolean), Disabling it will result 0 delta time in love.update
    t.modules.touch = true              -- Enable the touch module (boolean)
    t.modules.video = false             -- Enable the video module (boolean)
    t.modules.window = true             -- Enable the window module (boolean)

end



