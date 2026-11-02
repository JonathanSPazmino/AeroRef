-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
-- loader_gdsGuiLib.lua
-- Created on 7/20/2021
-- Created by Jonathan Pazmino
-- Last Modified 7/20/2021

MAIN_GDSGUI_VERSION = "0.8.0"

-- Nearest-neighbour filtering for all subsequently loaded images and fonts;
-- prevents bilinear blur when sprites are drawn at non-1:1 scale on PC.
love.graphics.setDefaultFilter("nearest", "nearest")

-- Text drawn at a fractional position lands between device pixels, so its
-- glyphs come out blurred or unevenly spaced. Every print/printf has its
-- position snapped to the nearest device pixel (DPI-aware), as long as only a
-- translation is in effect; scaled or rotated drawing is left exactly as asked.
do
	local rawPrint, rawPrintf = love.graphics.print, love.graphics.printf
	local function snapped(x, y)
		if type(x) ~= "number" or type(y) ~= "number" or not love.graphics.transformPoint then return x, y end
		local ax, ay = love.graphics.transformPoint(0, 0)
		local bx, by = love.graphics.transformPoint(1, 1)
		-- With a tolerance: LÖVE's transform is single precision, so under a
		-- fractional translation the unit step rarely comes back as exactly 1.
		if math.abs(bx - ax - 1) > 1e-4 or math.abs(by - ay - 1) > 1e-4 then return x, y end
		local dpi = love.graphics.getDPIScale()
		return math.floor((ax + x) * dpi + 0.5) / dpi - ax, math.floor((ay + y) * dpi + 0.5) / dpi - ay
	end
	love.graphics.print = function(text, x, y, ...)
		x, y = snapped(x, y)
		return rawPrint(text, x, y, ...)
	end
	love.graphics.printf = function(text, x, y, ...)
		x, y = snapped(x, y)
		return rawPrintf(text, x, y, ...)
	end
end

local function requireGUILibraries ()

	--when calling files, no need for .lua externsions
	local pathToLibrary = "Libraries.gds_love2d_gui."

	-- general_gdsGuiLib must be loaded first to initialize globApp
	require (pathToLibrary .. "general_gdsGuiLib") --[[general functions]]
	require (pathToLibrary .. "haptics_gdsGuiLib") --[[haptic feedback]]
	require (pathToLibrary .. "pages_gdsGuiLib") --[[handles all app pages]]
	require (pathToLibrary .. "buttons_gdsGuiLib") --[[contains buttons related code]]
	require (pathToLibrary .. "inputTxtBox_gdsGuiLib") --[[contains text box related code]]
	require (pathToLibrary .. "outputTxtBox_gdsGuiLib") --[[contains labels related code]]
	require (pathToLibrary .. "container_gdsGuiLib") --[[scrollable widget containers]]
	require (pathToLibrary .. "saveLoad_gdsGuiLib") --[[save and load data code]]
	require (pathToLibrary .. "table_gdsGuiLib") --[[data display tables]]
	require (pathToLibrary .. "scrollBar_gdsGuiLib")--[[scrollbars]]
	require (pathToLibrary .. "rotaryKnobs_gdsGuiLib")--[[rotary knob controls]]
	require (pathToLibrary .. "schematic_gdsGuiLib")--[[system schematic drawing canvas]]
	require (pathToLibrary .. "textPrompt_gdsGuiLib")--[[modal text-entry popup]]
	require (pathToLibrary .. "choiceMenu_gdsGuiLib")--[[modal option-list popup]]
	require (pathToLibrary .. "timeControl_gdsGuiLib") --[[time triggers callbacks]]
	require (pathToLibrary .. "unitTests_gdsGuiLib")--[[developement and settings]]
	require (pathToLibrary .. "devSettings_gdsGuiLib")--[[developement and settings]]

end

function gdsGui_generateConsoleMessage (mode, text)
	if (mode == "info" or mode == "error") and (text ~= "" and text ~= nil) then
		if mode == "info" and not (globApp and globApp.developerMode) then return end
		local msg1 = "GDS_GUI_v" .. MAIN_GDSGUI_VERSION .. " | "
		local msg2 = ""
		if mode == "info" then
			msg2 = "Info |  "
		elseif mode == "error" then
			msg2 = "Error | "
		end
		local msg3 = text
		print (msg1 .. msg2 .. msg3)
	else
		print ("gdsGUI| CALLBACK ERROR| generateOutputMessage callback is missing parameters")
	end
end

gdsGui_generateConsoleMessage ("info", "GDS_LOVE2D_GUI initilized")

requireGUILibraries ()