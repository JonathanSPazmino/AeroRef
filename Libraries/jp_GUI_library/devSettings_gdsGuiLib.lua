
--Settings:
-- require ("pageHandling")

--------------------------------------------------------------------------
						--GENERAL
--------------------------------------------------------------------------

local guiVersion = MAIN_GDSGUI_VERSION

local devSettings = {}
		devSettings.amIdeveloping = false
		devSettings.gdsGui_dev_print = 1
		devSettings.displayFPS = 1


function gdsGui_dev_print (printingValue, OnOffSwitch)
	if devSettings.amIdeveloping == true and (OnOffSwitch == "on" or OnOffSwitch == "ON" or OnOffSwitch == "On") and devSettings.gdsGui_dev_print == 1 then
		print (printingValue)
	end
end

--------------------------------------------------------------------------
					--DEVELOPER DISPLAYS
-------------------------------------------------------------------------
local devDataDisplay = {}
		--FONT
		devDataDisplay.font = {}
			devDataDisplay.font.transparency = .40
			devDataDisplay.font.color = {1, 1, 1}
			devDataDisplay.font.size = math.floor(gdsGui_general_smartFontScaling (0.02, 0.037))
			devDataDisplay.font.font = love.graphics.newFont(devDataDisplay.font.size)
		--TOP ROW
		devDataDisplay.topRow = {}
			-- TOP ROW GENERAL
			devDataDisplay.topRow.isVisible = true
			devDataDisplay.topRow.y = globApp.safeScreenArea.y + (devDataDisplay.font.size)
			-- TOP ROW WINDOW DIMENSIONS
			devDataDisplay.topRow.winDimensions = {}
				devDataDisplay.topRow.winDimensions.textWidht = math.floor(globApp.safeScreenArea.w)
				devDataDisplay.topRow.winDimensions.textHeight = math.floor(globApp.safeScreenArea.h)
				devDataDisplay.topRow.winDimensions.density = math.floor(globApp.appScale)
				devDataDisplay.topRow.winDimensions.x = globApp.safeScreenArea.x + 2
				devDataDisplay.topRow.winDimensions.text = (devDataDisplay.topRow.winDimensions.textWidht .. "x" .. devDataDisplay.topRow.winDimensions.textHeight .. "/d:".. devDataDisplay.topRow.winDimensions.density)
			-- TOP ROW FPS DISPLAY
			devDataDisplay.topRow.fpsData = {}
				devDataDisplay.topRow.fpsData.x = globApp.safeScreenArea.xw - (devDataDisplay.font.size * 7)
				devDataDisplay.topRow.fpsData.fps = love.timer.getFPS()
				devDataDisplay.topRow.fpsData.display = "FPS: ".. devDataDisplay.topRow.fpsData.fps
				devDataDisplay.topRow.fpsData.period = 0.01715
				devDataDisplay.topRow.fpsData.timer = devDataDisplay.topRow.fpsData.period
		--BOTTOM ROW
		devDataDisplay.bottomRow = {} 
			--BOTTOM ROW GENERAL
			devDataDisplay.bottomRow.isVisible = true
			devDataDisplay.bottomRow.y = (globApp.safeScreenArea.y + globApp.safeScreenArea.h ) - (devDataDisplay.font.size * 2)
			--BOTTOM ROW PAGE ID
			devDataDisplay.bottomRow.pageID = {}
				devDataDisplay.bottomRow.pageID.text = gdsGui_page_currentName ()
				devDataDisplay.bottomRow.pageID.x = globApp.safeScreenArea.x + 2
			--BOTTOM ROW OBJECT COUNT DISPLAY
			devDataDisplay.bottomRow.dsplydOjCount = {}
				devDataDisplay.bottomRow.dsplydOjCount.x = globApp.safeScreenArea.x + math.floor(globApp.safeScreenArea.w * 0.30)
				devDataDisplay.bottomRow.dsplydOjCount.text = globApp.numObjectsDisplayed
			--BOTTOM ROW GUI VERSION
			devDataDisplay.bottomRow.GUIversion = {}
				devDataDisplay.bottomRow.GUIversion.x = globApp.safeScreenArea.xw - (devDataDisplay.font.size * 9)
				devDataDisplay.bottomRow.GUIversion.text = guiVersion

function gdsGui_dev_updateDisplays (dt)
	--WILL RUN ONLY WHEN RESIZE FUNCTION RETURNS TRUE
	if globApp.resizeDetected == true then
		--FONT
			devDataDisplay.font.size = math.floor(gdsGui_general_smartFontScaling (0.02, 0.037))
			devDataDisplay.font.font = love.graphics.newFont(devDataDisplay.font.size)

		--TOP_ROW 
			--TOPROW GENERAL
			devDataDisplay.topRow.y = globApp.safeScreenArea.y + (devDataDisplay.font.size)
			--WINDIMENSIONS
			devDataDisplay.topRow.winDimensions.textWidht = math.floor(globApp.safeScreenArea.w)
			devDataDisplay.topRow.winDimensions.textHeight = math.floor(globApp.safeScreenArea.h)
			devDataDisplay.topRow.winDimensions.density = math.floor(globApp.appScale)
			devDataDisplay.topRow.winDimensions.x = globApp.safeScreenArea.x + 2
			devDataDisplay.topRow.winDimensions.text = (devDataDisplay.topRow.winDimensions.textWidht .. "x" .. devDataDisplay.topRow.winDimensions.textHeight .. "/d:".. devDataDisplay.topRow.winDimensions.density)
			--FPS DATA
			devDataDisplay.topRow.fpsData.x = globApp.safeScreenArea.xw - (devDataDisplay.font.size * 7)

		--BOTTOM_ROW
			--BOTTOM ROW GENERAL
			devDataDisplay.bottomRow.y = (globApp.safeScreenArea.y + globApp.safeScreenArea.h ) - (devDataDisplay.font.size * 2)
			--PAGE ID
			devDataDisplay.bottomRow.pageID.x = globApp.safeScreenArea.x + 2
			--DISPLAY OBJECTS COUNT
			devDataDisplay.bottomRow.dsplydOjCount.x = globApp.safeScreenArea.x + math.floor(globApp.safeScreenArea.w * 0.30)
			--GUI VERSION
			devDataDisplay.bottomRow.GUIversion.x = globApp.safeScreenArea.xw - (devDataDisplay.font.size * 9)
	end

	--RUNS CONTINUOUSLY
	devDataDisplay.topRow.fpsData.timer = devDataDisplay.topRow.fpsData.timer - dt
	if devDataDisplay.topRow.fpsData.timer <= 0 then
		devDataDisplay.topRow.fpsData.fps = love.timer.getFPS()
		devDataDisplay.topRow.fpsData.timer = devDataDisplay.topRow.fpsData.period
		devDataDisplay.topRow.fpsData.display = "FPS: ".. devDataDisplay.topRow.fpsData.fps
	end
	devDataDisplay.bottomRow.pageID.text = gdsGui_page_currentName ()
	devDataDisplay.bottomRow.dsplydOjCount.text = globApp.numObjectsDisplayed
end

function gdsGui_dev_drawTopRow ()
	--RUNS ONLY IF DEV DISPLAYS ARE SELECTED VISIBLE FROM VAR DECLARATION
	if devSettings.amIdeveloping == true and devDataDisplay.topRow.isVisible == true then
		--GENERAL
		love.graphics.setFont(devDataDisplay.font.font)
		love.graphics.setColor(devDataDisplay.font.color[1], devDataDisplay.font.color[2], devDataDisplay.font.color[3], devDataDisplay.font.transparency)
		--WINDOW DIMENSIONS:
		love.graphics.print (devDataDisplay.topRow.winDimensions.text, devDataDisplay.topRow.winDimensions.x, devDataDisplay.topRow.y)
		love.graphics.reset ()
		--FPS DISPLAY:
		if devDataDisplay.topRow.fpsData.fps >= 50 then
			love.graphics.setColor(0, 1, 0, devDataDisplay.font.transparency)
		elseif devDataDisplay.topRow.fpsData.fps < 50 and devDataDisplay.topRow.fpsData.fps >= 30 then
			love.graphics.setColor(0.6, 0, 0, devDataDisplay.font.transparency)
		elseif devDataDisplay.topRow.fpsData.fps < 30 then
			love.graphics.setColor(1, 0, 1, devDataDisplay.font.transparency)
		end
		
		love.graphics.print (devDataDisplay.topRow.fpsData.display, devDataDisplay.topRow.fpsData.x, devDataDisplay.topRow.y)
		love.graphics.reset ()
	end
end

function gdsGui_dev_drawBottomRow ()

	if devSettings.amIdeveloping == true and devDataDisplay.bottomRow.isVisible == true then

		love.graphics.setFont(devDataDisplay.font.font)

		love.graphics.setColor(devDataDisplay.font.color[1], devDataDisplay.font.color[2], devDataDisplay.font.color[3], devDataDisplay.font.transparency)

		love.graphics.print("pg: " .. devDataDisplay.bottomRow.pageID.text, devDataDisplay.bottomRow.pageID.x, devDataDisplay.bottomRow.y)

		love.graphics.print("#Objs: " .. devDataDisplay.bottomRow.dsplydOjCount.text, devDataDisplay.bottomRow.dsplydOjCount.x, devDataDisplay.bottomRow.y)

		love.graphics.print("GUI: " .. devDataDisplay.bottomRow.GUIversion.text, devDataDisplay.bottomRow.GUIversion.x, devDataDisplay.bottomRow.y)

	end
end

function gdsGui_dev_drawAll ()

	--DEVELOPER PAGES
	-- developerMenuPage()

	-- developerUnitTestPage ()

	-- screenTestMenuPage ()

	-- unitTestInfoPage ()

	-- switchScreenSizePage ()

	-- devEraseDataConfirmationPage ()

	-- devAboutPage ()

	--DEVELOPER DISPLAYS:
	gdsGui_dev_drawTopRow ()

	gdsGui_dev_drawBottomRow ()

	gdsGui_timeControl_testTrigger ()

	love.graphics.reset ()
end

local function returnNumberOfDisplays ()
	local DisplayCount = love.window.getDisplayCount( )
	return DisplayCount
end

local function returnVsyncStatus ()
	local config_vsync = love.window.getVSync()
	return config_vsync
end

local function returnDesktopDimensions (strgMode)
	local stdFormatMode = string.lower(strgMode)
	local desktopWidth, desktopHeight = love.window.getDesktopDimensions( 1 )

	if stdFormatMode == "height" then
		return desktopWidth
	elseif stdFormatMode == "width" then
		return desktopHeight
	end
end



------------------------------------------------------------------------------
							--TDD
--TEST DRIVEN DEVELOPMENT SECTION:
--The following code is related to testing development written in a OOP fashion.
--The Objects are stored in the devTests table and can referenced globaly
--------------------------------------------------------------------------------
devTests = {}

function gdsGui_dev_testCreate (myLable, myTestingUnit, myInput, myExpectedOutPut)

	--[[GUIDE:
		NOTES: unlimited input and output table paramters

		INPUT:
			myLable--------------------string-------------anyUniqueName
			myTestingUnit--------------stringTABLE--------full path values from outter2inner
			myInput--------------------table--------------any data type table format only
			myExpectedOutPut-----------table--------------any data type table format only

		OUTPUT:
			resultString-----------string----------------name,result,elspsedtime
		]]

	processedInput  = myInput

	local path_level_counter = 0
	local parameter_counter = 0
	local expected_output_counter = 0
	local start = 0

	for i=1 , #myTestingUnit, 1 do
		path_level_counter = path_level_counter + 1
	end

	for i=1 , #myInput, 1 do
		parameter_counter = parameter_counter + 1
	end

	NewTest = {}
	NewTest.name = myLable
	NewTest.result = "*fail*"
	NewTest.path = {}


	local msg_positive_test = "passed"

	for i= 1, path_level_counter, 1 do
		if i~= path_level_counter then
			NewTest.path[i] = myTestingUnit[i]
			getfenv()[NewTest.path[i]]()
		elseif i == path_level_counter then
			NewTest.test = myTestingUnit[#myTestingUnit]
		end
	end

	--[[THIS PART RUNNS THE TEST PASSING PARAMETERS]]

	local fullParameterString1 = "NewTest.output = getfenv()[NewTest.test]("
	local fullParameterString2 = ""
	local fullParameterString3 = ""

	for i=1, parameter_counter, 1 do

		if i~= parameter_counter then
		local unitParameterString = ("processedInput[" .. i .. "], ")
		fullParameterString2 = fullParameterString2 .. unitParameterString
		elseif i== parameter_counter then
		local unitParameterString = ("processedInput[" .. i .. "]")
		fullParameterString2 = fullParameterString2 .. unitParameterString
		end
		
	end

	fullParameterString3 = fullParameterString1 .. fullParameterString2 .. ",true)"

	
	local executeStringTestFunction = loadstring(fullParameterString3)
	local startTime = love.timer.getTime()
	executeStringTestFunction()
	local endTime = love.timer.getTime() - startTime

	for i=1, #myExpectedOutPut, 1 do
		expected_output_counter = expected_output_counter + 1
	end

	local testFailTrigger = false
	NewTest.failingParameter = ""

	if type (NewTest.output) ~= "table" and NewTest.output ~= nil then --converts single values to table format

		local tamporaryOutputHolder = NewTest.output
		NewTest.output = {}
		NewTest.output[1] = tamporaryOutputHolder

	end

	for i=1, #myExpectedOutPut, 1 do

		if NewTest.output[i] ~= myExpectedOutPut[i] then

			local outputExists = true
			local expectedOutputExists = true

			if NewTest.output[i] == nil then
				outputExists = false
			end 
			if myExpectedOutPut[i] == nil then
				expectedOutputExists = false
			end 

			testFailTrigger = true

			if outputExists == true and expectedOutputExists == true then
				NewTest.failingParameter = NewTest.failingParameter .. i .. ")_xpctd:" .. tostring(myExpectedOutPut[i]) .. "_butGot:" .. tostring(NewTest.output[i]) ..  ", "
			elseif outputExists == false and expectedOutputExists == true then
				NewTest.failingParameter = NewTest.failingParameter .. i .. ")_noXpctdVal: " .. "_butGot: " .. tostring(NewTest.output[i]) ..  ","
			elseif outputExists == true and expectedOutputExists == false then
				NewTest.failingParameter = NewTest.failingParameter .. i .. ")_xpct:" .. tostring (myExpectedOutPut[i]) .. "butGotNoOutput,"
			end

		end
	end

	if testFailTrigger == false then
		NewTest.result = msg_positive_test
	end

	NewTest.elapsedTime = tonumber(string.format("%.5f", endTime * 1000))

	local serializedUnitTestData = gdsGui_saveLoad_createProjectData ({"name","result","path","test","failingParameter","elapsedTime","output"}, {NewTest.name, NewTest.result, NewTest.path, NewTest.test, NewTest.failingParameter, NewTest.elapsedTime, NewTest.output}, devTests, "UTL", 7)
	
	table.insert(devTests, serializedUnitTestData)

	-- table.insert (devTests, NewTest)

end

function gdsGui_dev_testExecute (testSpecs)

	--[[ 
		PARAMETERS:

		mylabel---------------string-----------------unique name
		myTestingUnit-------string table-------------outer to inner functions to be called 5 max
		myInput --------------table------------------all required parameters MAX 10
		myExpectedOutPut------table------------------all expected outputs max 4

		RETURN:
		
			result----------------string-----------------concatenated unit test result, 1) test name, 2)result, 3)elapsed time
	]]

	local testId = testSpecs["id"]
	local functionID = testSpecs["funcName"]
	local parameters = testSpecs ["funcParameters"]
	local results = testSpecs["funcExpctOutput"]



	if globApp.developerMode == true then
		local testCount = 0
		local testExists = false

		for i, test in ipairs (devTests) do
			testCount = testCount + 1
			if test.name == testId then
				testExists = true
			end
		end

		if testCount == 0 or testExists == false then
			gdsGui_dev_testCreate (testId, functionID, parameters, results)
		end
	end
end



function gdsGui_dev_writeTestResults (alertMode, alertType)

	if alertMode == "console" then

		for i, test in pairs (devTests) do

			if test.result ~= "passed" and alertType == "fail" then

				local stringResult = (test.result.. " __ in ".. test.elapsedTime .. " secs." .. " __ " .. test.name .. " failures: " .. test.failingParameter)
				-- print (stringResult)
				gdsGui_generateConsoleMessage ("error", stringResult)

			elseif test.result == "passed" and alertType == "passed" then

				local stringResult = (test.result.. " __ in ".. test.elapsedTime .. " secs." .. " __ " .. test.name )
				gdsGui_generateConsoleMessage ("info", stringResult)

			elseif alertType == "all" then

				if test.result ~= "passed" then

					local stringResult = (test.result.. " __ in ".. test.elapsedTime .. " secs." .. " __ " .. test.name .. " failures: " .. test.failingParameter)
					gdsGui_generateConsoleMessage ("error", stringResult)

				elseif test.result == "passed" then

					local stringResult = (test.result.. " __ in ".. test.elapsedTime .. " secs." .. " __ " .. test.name )
					gdsGui_generateConsoleMessage ("info", stringResult)

				end

			end

		end

	end

end


function gdsGui_dev_openByEightTap (x,y,button,istouch)

	if globApp.OperatingSystem == "iOS" or globApp.OperatingSystem == "Android" then return end

	if globApp.developerMode == true then

		if (button == 1 or globApp.userInput == "tap") and globApp.currentPageIndex == 2 and globApp.devTapCounter < 8 and globApp.fourDevTap == false then
			
			globApp.devTapCounter = globApp.devTapCounter + 1

			gdsGui_generateConsoleMessage ("info", "devTap #"..globApp.devTapCounter)

			if globApp.devTapCounter == 8 then

				globApp.fourDevTap = true 

				globApp.devTapCounter = 0
				gdsGui_generateConsoleMessage ("info", "Developer access granted")
			end
			
		end



	end

end 






----------------------------------------------------------------------------------
							--SWITCH PAGES FUNCTIONS
----------------------------------------------------------------------------------

function gdsGui_dev_openMainMenu ()

	gdsGui_page_switch ("LodingDeveloperMenu", 20050, 2, false)

end

local safeLoadTimer = 0.1

function gdsGui_dev_leave ()

	globApp.fourDevTap = false

	globApp.devTapCounter = 0

	-- Allow the app to override the destination page (e.g. to show T&C after
	-- a data-erase). Falls back to page 3 (MainMenu) if no hook is defined.
	local destPage = 3
	if _G["gdsGui_dev_getLeaveDestPage"] then
		destPage = _G["gdsGui_dev_getLeaveDestPage"]() or 3
	end

	gdsGui_page_switch ("leavingDevPage", destPage, safeLoadTimer, false)

end


function gdsGui_dev_openUnitTestPage ()
	gdsGui_unitTests_executeAll ("DeveloperMenu")

	if globApp.currentPageIndex == 20054 then
		focusedUnitTest = "none"
	end
	gdsGui_page_switch ("LoadingUnitTestsPage", 20051, 2, false)

end


function gdsGui_dev_openScreenTestsPage ()

	gdsGui_page_switch ("LoadingScreenTestsMenuPage", 20052, 2, false)

end

function gdsGui_dev_openEraseDataPage ()

	gdsGui_page_switch ("LoadingScreenTestsMenuPage", 20055, .3, false)

end


function gdsGui_dev_openSwitchScreenPage ()

	gdsGui_dev_screenSimulatorsInit ()

	gdsGui_page_switch ("LoadingSwitchScreenSizePage", 20053, 2, false)

end

function gdsGui_dev_openAboutPage ()
	gdsGui_page_switch ("LoadingDevAboutPage", 20056, 2, false)

end




----------------------------------------------------------------------------------
							--DEV PAGES
----------------------------------------------------------------------------------

local screenTestButtonInitialState = 1

if globApp.OperatingSystem == "iOS" or globApp.OperatingSystem == "Android" then

	screenTestButtonInitialState = 0

end



function gdsGui_dev_createMenuObjects()

	local thisPageName = "DeveloperMenu"

	gdsGui_button_create("unitTest"--[[ButtonLable]], 
		thisPageName--[[page]], 
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_devUnitTest_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_devUnitTest_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_devUnitTest_deactivated.png")--[[sprite:deactivated]],
		.5--[[x coordinate]],
		.20--[[y coordinate]],
		"CC"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"height" )--[[height]],
		"gdsGui_dev_openUnitTestPage"--[[callback function]], 
		1--[[button initial status]])

	gdsGui_button_create("screenDevTests"--[[ButtonLable]], 
		thisPageName--[[page]], 
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_screenTestMenuButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_screenTestMenuButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_screenTestMenuButton_deactivated.png")--[[sprite:deactivated]],
		.5--[[x coordinate]],
		.35--[[y coordinate]],
		"CC"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"height" )--[[height]],
		"gdsGui_dev_openScreenTestsPage"--[[callback function]], 
		screenTestButtonInitialState --[[button initial status]])

	gdsGui_button_create("resetData"--[[ButtonLable]], 
		thisPageName--[[page]], 
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_devEraseDataButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_devEraseDataButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_devEraseDataButton_deactivated.png")--[[sprite:deactivated]],
		.5--[[x coordinate]],
		.50--[[y coordinate]],
		"CC"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"height" )--[[height]],
		"gdsGui_dev_openEraseDataPage"--[[callback function]],
		1--[[button initial status]])

	gdsGui_button_create("aboutAppPage"--[[ButtonLable]], 
		thisPageName--[[page]], 
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_devaAboutButton_pressed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_devaAboutButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_devaAboutButton_deactivated.png")--[[sprite:deactivated]],
		.5--[[x coordinate]],
		.65--[[y coordinate]],
		"CC"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"height" )--[[height]],
		"gdsGui_dev_openAboutPage"--[[callback function]], 
		1--[[button initial status]])


	gdsGui_button_create("exitDevMenu"--[[ButtonLable]], 
		thisPageName--[[page]], 
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_exitDevMenuButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_exitDevMenuButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_exitDevMenuButton_deactivated.png")--[[sprite:deactivated]],
		.5--[[x coordinate]],
		.80--[[y coordinate]],
		"CC"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"height" )--[[height]],
		"gdsGui_dev_leave"--[[callback function]], 
		1--[[button initial status]])
end 

gdsGui_dev_createMenuObjects()

function gdsGui_dev_createScreenTestObjects ()

	local thisPageName = "screenTestsMenu"

	gdsGui_button_create("returnDevMenu"--[[ButtonLable]], 
		thisPageName--[[page]],
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_deactivated.png")--[[sprite:deactivated]],
		.035--[[x coordinate]],
		.043--[[y coordinate]],
		"LT"--[[anchorPoint string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"height" )--[[height]],
		"gdsGui_dev_openMainMenu"--[[callback function]],
		1--[[button initial status]])

	gdsGui_button_create("switchScreenSize"--[[ButtonLable]],
		thisPageName--[[page]],
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_switchScreenSizeButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_switchScreenSizeButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_switchScreenSizeButton_deactivated.png")--[[sprite:deactivated]],
		.5--[[x coordinate]],
		.25--[[y coordinate]],
		"CC"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", 0.36, .54, .080, 0.12, 0.22,"height" )--[[height]],
		"gdsGui_dev_openSwitchScreenPage"--[[callback function]],
		1--[[button initial status]])
end

gdsGui_dev_createScreenTestObjects ()


function gdsGui_dev_createEraseDataObjects ()

	local thisPageName = "devEraseDataConfirmationPage"
	local devSA        = globApp.safeScreenArea
	local pageHdrH     = math.floor(devSA.h * 0.10)
	local pageFootH    = pageHdrH
	local bodyH        = devSA.h - pageHdrH - pageFootH
	local contTitleH   = 32   -- container title-strip pixel height
	local bodyGap      = 8    -- PADDING constant matching container lib

	-- ── Page header ─────────────────────────────────────────────────────────
	gdsGui_pageHeader_create("eraseData_header", thisPageName, pageHdrH, {0.15, 0.15, 0.20, 1})
	gdsGui_outputTxtBox_create("eraseData_pageTitle", thisPageName, nil,
		math.floor(devSA.w * 0.5), math.floor(pageHdrH * 0.5), "CC",
		math.floor(devSA.w * 0.70), math.floor(pageHdrH * 0.5),
		{1, 1, 1, 1}, "ERASE DATA", 16, "eraseData_header"
	)

	-- ── Data table container ─────────────────────────────────────────────────
	-- Container 1 holds the data table. A same-size invisible placeholder
	-- outputTxtBox is added so the container auto-sizes to fit the table area.
	local tblContH      = math.floor(bodyH * 0.60)
	local tblInnerH     = tblContH - contTitleH - bodyGap
	gdsGui_container_create("eraseDataTableCont", thisPageName, "DATA TO BE ERASED", contTitleH, 0)
	gdsGui_outputTxtBox_create("eraseData_tblSpacer", thisPageName, nil,
		math.floor(devSA.w * 0.5), bodyGap, "CT",
		math.floor(devSA.w * 0.90), tblInnerH - bodyGap,
		{0, 0, 0, 0}, "", 8, "eraseDataTableCont"
	)

	-- Data table (fraction-positioned to overlap the container content area)
	local tblTopPx   = pageHdrH + contTitleH + bodyGap * 2
	local tblHeightPx = tblInnerH - bodyGap * 2
	local eraseDataRows = {
		{ ID="EDR1", ["Data"]="Project saves",  ["Status"]="ERASED" },
		{ ID="EDR2", ["Data"]="App settings",   ["Status"]="ERASED" },
		{ ID="EDR3", ["Data"]="T&C acceptance", ["Status"]="RESET"  },
	}
	gdsGui_table_create(
		"eraseDataTable", thisPageName, "static", eraseDataRows,
		0.5,
		(tblTopPx + tblHeightPx * 0.5) / devSA.h,
		0.85,
		tblHeightPx / devSA.h,
		"CC",
		nil, {},
		gdsGui_general_smartFontScaling(0.025, 0.032),
		{ [1] = "Data", [2] = "Status" },
		false,
		"eraseDataTableCont"
	)

	-- ── Warning container ────────────────────────────────────────────────────
	local warnInnerH = math.floor(bodyH * 0.40) - contTitleH - bodyGap
	gdsGui_container_create("eraseDataWarnCont", thisPageName, "WARNING", contTitleH, 0)
	gdsGui_outputTxtBox_create("eraseData_warning", thisPageName, nil,
		math.floor(devSA.w * 0.5), bodyGap, "CT",
		math.floor(devSA.w * 0.85), warnInnerH - bodyGap,
		{1, 0.80, 0.10, 1},
		"All stored data will be permanently erased and app defaults will be applied. This action cannot be undone.",
		gdsGui_general_smartFontScaling(0.025, 0.030),
		"eraseDataWarnCont"
	)

	-- ── Page footer with YES / NO buttons ───────────────────────────────────
	local footBtnW  = 96
	local footBtnH  = 48
	local footBtnY  = math.floor(pageFootH * 0.50)
	gdsGui_pageFooter_create("eraseData_footer", thisPageName, pageFootH, {0.15, 0.15, 0.20, 1})
	gdsGui_button_create("yesConfirmation", thisPageName, "pushonoff",
		(devSpritesPath .. "jpLoveGUI_yesConfirmButton_pushed.png"),
		(devSpritesPath .. "jpLoveGUI_yesConfirmButton_released.png"),
		(devSpritesPath .. "jpLoveGUI_yesConfirmButton_deactivated.png"),
		math.floor(devSA.w * (1/3)), footBtnY, "CC",
		footBtnW, footBtnH,
		"gdsGui_dev_deleteAllProjectData", 1, false, "eraseData_footer"
	)
	gdsGui_button_create("noConfirmation", thisPageName, "pushonoff",
		(devSpritesPath .. "jpLoveGUI_noConfirmButton_pushed.png"),
		(devSpritesPath .. "jpLoveGUI_noConfirmButton_released.png"),
		(devSpritesPath .. "jpLoveGUI_noConfirmButton_deactivated.png"),
		math.floor(devSA.w * (2/3)), footBtnY, "CC",
		footBtnW, footBtnH,
		"gdsGui_dev_openMainMenu", 1, false, "eraseData_footer"
	)

	gdsGui_container_finalise(thisPageName)
end

gdsGui_dev_createEraseDataObjects ()

function gdsGui_dev_deleteAllProjectData ()
	--delete data from love2d memory
	for i = #globApp.projects,1,-1 do
        table.remove(globApp.projects,i)
   end
   --ovewrite data file with empty table:
   gdsGui_saveLoad_saveProject ("savedProjectData.lua", globApp.projects, "globApp.projects")

   -- notify app layer so it can wipe its own settings (T&C, preferences, etc.)
   if _G["gdsGui_dev_onDataErased"] then _G["gdsGui_dev_onDataErased"]() end

   --returns to devMainMenu after deleting all project data:
   gdsGui_dev_openMainMenu ()
end

function gdsGui_dev_createUnitTestObjects ()

	local thisPageName = "UnitTesting"
	gdsGui_unitTests_executeAll ("DeveloperMenu")

	gdsGui_table_create (
		"devUnitTest", --[spreadsheet name]
		thisPageName, --[[page]]
		"static", --[[type]]
		devTests,--[[dataTable]]
		.5, --[[x position]]
		gdsGui_general_smartRelocation (.30,0,.27,.25,.24,.5,.21,1,"y"), --[[y position]]
		.8, --[[table width]]
		.6,--[[table height]]
		"CT", --[[anchor point]]
		nil, --[[bg sprite]]
		{ 	[1]={["INFO"]="gdsGui_dev_openUTInfoCallback"},},--[[callback function]]
		gdsGui_general_smartFontScaling (0.025, 0.032),--[[font size]]
		{	[1] = "name", 
			[2]= "result", 
			[3] = "failingParameter"},
		true)



	gdsGui_button_create("returnDevMenu"--[[ButtonLable]],
		thisPageName--[[page]],
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_deactivated.png")--[[sprite:deactivated]],
		.035--[[x coordinate]],
		.043--[[y coordinate]],
		"LT"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"height" )--[[height]],
		"gdsGui_dev_openMainMenu"--[[callback function]],
		1--[[button initial status]])

	gdsGui_button_create("rerunUnitTests"--[[ButtonLable]],
		thisPageName--[[page]],
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_devUnitTest_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_devUnitTest_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_devUnitTest_deactivated.png")--[[sprite: deactivated]],
		.965--[[x coordinate]],
		.043--[[y coordinate]],
		"RT"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"height" )--[[height]],
		"gdsGui_dev_rerunUnitTests"--[[callback function]],
		1--[[button initial status]])
end

function gdsGui_dev_refreshUnitTestDisplay()
	gdsGui_table_setData("devUnitTest", devTests)
end

function gdsGui_dev_rerunUnitTests()
	gdsGui_unitTests_rerunAll()
	gdsGui_dev_refreshUnitTestDisplay()
	gdsGui_table_scrollToOrigin("devUnitTest")
end

local focusedUnitTest = "none"
function gdsGui_dev_openUTInfoCallback (utID)

	focusedUnitTest = utID

	gdsGui_dev_openUTInfoPage ()
end

function gdsGui_dev_openUTInfoPage ()

	gdsGui_page_switch ("LodingUnitTestInfoPage", 20054, .5, false)
end

function gdsGui_dev_createUTInfoObjects ()

	local thisPageName = "unitTestInfo"
	
	local selectedUnitTest = focusedUnitTest
	local utData = {}
	local resultString = ""

	if selectedUnitTest ~= "none" then
		for i, rcrd in ipairs (devTests) do
			if rcrd.ID == selectedUnitTest then
				utData = rcrd
				
				resultString = "[TEST NAME]: " .. rcrd.name
				resultString = resultString .. "\n[TEST ELAPSED TIME]: " .. rcrd.elapsedTime
				resultString = resultString .. "\n[TEST RESULT]: " .. rcrd.result

			end
		end
	end

	gdsGui_button_create("returnToUnitTestPage"--[[ButtonLable]], 
		thisPageName--[[page]], 
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_deactivated.png")--[[sprite:deactivated]],
		.035--[[x coordinate]],
		.043--[[y coordinate]],
		"LT"--[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"height" )--[[height]],
		"gdsGui_dev_openUnitTestPage"--[[callback function]], 
		1--[[button initial status]])

	-- outputTxtBox_draw ("UnitTestInfo",--[[Label name]]
	-- 	thisPageName, --[[strg page]]
	-- 	nil, --[[image to be used as bg]]
	-- 	.5, --[[x percentage of screen]]
	-- 	.2, --[[y percentage of screen]]
	-- 	"CC", --[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]]
	-- 	gdsGui_general_smartScaling ("inverse", 0.80, 0.65, .144, 0.117, 0.18,"width"),--[[width]]
	-- 	gdsGui_general_smartScaling ("inverse", 0.80, 0.65, .144, 0.117, 0.18,"height"), --[[height]]
	-- 	{0,1,0,1},--[[rgba]]
	-- 	selectedUnitTest, --[[string of label display 1]]
	-- 	math.floor(gdsGui_general_smartFontScaling (0.03, 0.04))--[[font size]])


	-- outputTxtBox_draw ("testInfo",--[[Label name]]
	-- 	thisPageName, --[[strg page]]
	-- 	nil, --[[image to be used as bg]]
	-- 	.5, --[[x percentage of screen]]
	-- 	.6, --[[y percentage of screen]]
	-- 	"CC", --[[anchorPoint -- string= LT,LC,LB,CT,CC,CB,RT,RC,RB]]
	-- 	gdsGui_general_smartScaling ("inverse", .9, .8, .63, .56, 0.7,"width"),--[[width]]
	-- 	gdsGui_general_smartScaling ("inverse", .9, .8, .63, .56, 0.7,"height"), --[[height]]
	-- 	{1,1,1,1},--[[rgba]]
	-- 	resultString, --[[string of label display 1]]
	-- 	math.floor(gdsGui_general_smartFontScaling (0.02, 0.05))--[[font size]])


end

gdsGui_dev_createUTInfoObjects ()

--------------------------------------------------------------------------------
					--CHANGE SCREEN SIZE FUNCTION
--------------------------------------------------------------------------------

local screenSimulators = {}

function gdsGui_dev_createScreenSimulator (screenName, dpiWidht, dpiHeight, tblUnsafeScreen, simulatedDensity)
	screenSimultorData = gdsGui_saveLoad_createProjectData ({"name","dpiWidht","dpiHeight", "tblUnsafeScreen", "simulatedDensity"}, {screenName, dpiWidht, dpiHeight, tblUnsafeScreen, simulatedDensity or 1}, screenSimulators, "SML", 7)

	table.insert(screenSimulators, screenSimultorData)
end

--------------------------------------------------------------------------------
						--SCREEN OBJECTS CREATION
--------------------------------------------------------------------------------

function gdsGui_dev_screenSimulatorsInit ()
	--VERTICAL
	gdsGui_dev_createScreenSimulator ("iphone16pro_vertical", 320, 617, {0,0.07,1,0.86}, 3) --xywh
	gdsGui_dev_createScreenSimulator ("smsngS7Edge_vertical", 336, 640, {0,0,1,1})
	gdsGui_dev_createScreenSimulator ("ipadAir2_vertical", 768, 1004, {0,0,1,1})

	--HORIZONTAL
	gdsGui_dev_createScreenSimulator ("iphone16pro_horizontal", 617, 320, {0.07, 0.0, .86,.90}, 3)
	gdsGui_dev_createScreenSimulator ("smsngS7Edge_horizontal", 640, 336, {0,0,1,1})
	gdsGui_dev_createScreenSimulator ("ipadAir2_horizontal", 1024, 748, {0,0,1,1})
end

function gdsGui_dev_createSwitchScreenObjects ()

	local thisPageName = "switchScreenSize"
	gdsGui_dev_screenSimulatorsInit ()
	gdsGui_table_create (
		"screenSizesTable", --[spreadsheet name]
		thisPageName, --[[page]]
		"static", --[[type]]
		screenSimulators,--[[dataTable]]
		.5, --[[x position]]
		gdsGui_general_smartRelocation (.30,0,.27,.25,.24,.5,.21,1,"y"), --[[y position]]
		.8, --[[table width]]
		.6,--[[table height]]
		"CT", --[[anchor point]]
		nil, --[[bg sprite]]
		{ 	[1]={["SELECT"]="gdsGui_dev_changeScreenSize"},},--[[callback function]]
		gdsGui_general_smartFontScaling (0.025, 0.032),--[[font size]]
		{	[1]= "name", 
			[2]= "dpiWidht", 
			[3]= "dpiHeight"},
		true)


	gdsGui_button_create("returnScreenTestsMenu"--[[ButtonLable]], 
		thisPageName--[[page]],
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_deactivated.png")--[[sprite:deactivated]],
		.035--[[x coordinate]],
		.043--[[y coordinate]],
		"LT"--[[anchorPoint string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"height" )--[[height]],
		"gdsGui_dev_openScreenTestsPage"--[[callback function]],
		1--[[button initial status]])

end

gdsGui_dev_createSwitchScreenObjects ()


function gdsGui_dev_changeScreenSize (par1, par2, par3)
	local allowScreenResizeTimer = 0.4 --secs

	for i, screenSim in ipairs (screenSimulators) do
		if screenSim.ID == par1 then

			love.window.setMode(screenSim.dpiWidht, screenSim.dpiHeight)
			love.window.setPosition(0, 40)
			globApp.appScale = screenSim.simulatedDensity

			if screenSim.tblUnsafeScreen ~= nil then
				globApp.safeScreenArea = gdsGui_general_simulateUnsafeArea (screenSim.tblUnsafeScreen[1], screenSim.tblUnsafeScreen[2], screenSim.tblUnsafeScreen[3], screenSim.tblUnsafeScreen[4])
				globApp.isScreenSimulated = true
			end
		end
	end

	gdsGui_timeControl_createTrigger ("waitToLeaveChangeScreenSizePage", {safeLoadTimer + allowScreenResizeTimer}, {"gdsGui_dev_leave"})
end


function gdsGui_dev_createAboutObjects ()
	local thisPageName = "devAboutPage"

	gdsGui_button_create("returnScreenTestsMenu"--[[ButtonLable]], 
		thisPageName--[[page]],
		"pushonoff"--[[buttonType]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_pushed.png")--[[sprite: pushed]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_released.png")--[[sprite: released]],
		(devSpritesPath .. "jpLoveGUI_returnPrevPageButton_deactivated.png")--[[sprite:deactivated]],
		.035--[[x coordinate]],
		.043--[[y coordinate]],
		"LT"--[[anchorPoint string= LT,LC,LB,CT,CC,CB,RT,RC,RB]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"width" )--[[width]],
		gdsGui_general_smartScaling ("inverse", .07, .13, .07, .13, 1,"height" )--[[height]],
		"gdsGui_dev_openMainMenu"--[[callback function]],
		1--[[button initial status]])

	gdsGui_outputTxtBox_create("libraryInfoContents",
		thisPageName,
		nil,
		.5,
		.5,
		"CC",
		globApp.safeScreenArea.w * 0.8,
		globApp.safeScreenArea.h * 0.8,
		{1, 1, 1, 1},
		globApp.libraryInfoContent or "Library info not loaded.",
		math.floor(gdsGui_general_smartFontScaling(0.04, 0.055)))

end 
gdsGui_dev_createAboutObjects ()