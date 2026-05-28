-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
-- loader_gdsGuiLib.lua
-- Created on 7/20/2021
-- Created by Jonathan Pazmino
-- Last Modified 7/20/2021

MAIN_GDSGUI_VERSION = "0.8.0"

-- Nearest-neighbour filtering for all subsequently loaded images and fonts;
-- prevents bilinear blur when sprites are drawn at non-1:1 scale on PC.
love.graphics.setDefaultFilter("nearest", "nearest")

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