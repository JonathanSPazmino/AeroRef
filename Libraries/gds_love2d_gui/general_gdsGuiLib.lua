-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--lib_general.lua
--created by /Jonathan Pazmino
--created on 8/2/2021


	--[[GENERAL FUNCTION LOAD/CALLS]]

	math.randomseed(os.time()) --increased randomness of program


function gdsGui_general_simulateUnsafeArea (perX,perY,perW,perH)

	--parameters use percentage of screen ie. 0.5 of total screen widht

	local safeScreenArea = {}
	local totalWindowWidth = love.graphics.getWidth()
	local totalWindowHeight = love.graphics.getHeight()
		
	safeScreenArea.x = perX * totalWindowWidth
	safeScreenArea.y = perY * totalWindowHeight
	safeScreenArea.w = perW * totalWindowWidth
	safeScreenArea.h = perH * totalWindowHeight
	safeScreenArea.xw = safeScreenArea.x + safeScreenArea.w
	safeScreenArea.yh = safeScreenArea.y + safeScreenArea.h

	return safeScreenArea 

end

function gdsGui_general_convertSafeAreaToDPI (percArea, reqResult, isDevMode)

	--[[
	return a single value that represents the DPI equivalent of the desired percentage of width or height safe area
	
	INPUT:
	percWidth-------------------double----------------0 to 1 desired widht %
	percHeight------------------double----------------0 to 1 desired height %
	reqResult-------------------string---------------"width or height" result type
	isDevMode-------------------boolean---------------"true runs unit test"

	OUTPUT:
	result----------------------doble-----------------DPI widht or height

	]]

	local formatedReqResult = reqResult:upper()

	local windowSafeWidth = globApp.safeScreenArea.w

	local windowSafeHeight = globApp.safeScreenArea.h

	if isDevMode == true then
		windowSafeWidth = 1000
		windowSafeHeight = 1000
	end 

	local result = "error"

	if formatedReqResult == "WIDTH" then

		result = windowSafeWidth * percArea

	elseif formatedReqResult == "HEIGHT" then

		result = windowSafeHeight * percArea

	end

	if isDevMode == true then
		local devOutput = {}
				devOutput[1] = result
		return result
	end

	return result

end



function gdsGui_general_getScaledDimensions(originalWidthRatio, originalHeightRatio, aspectRatio)
    local newDimensions = {}

    local boxWidth = originalWidthRatio * globApp.safeScreenArea.w
    local boxHeight = originalHeightRatio * globApp.safeScreenArea.h

    if boxWidth * aspectRatio <= boxHeight then
        -- Width is the limiting dimension
        newDimensions.width = boxWidth
        newDimensions.height = boxWidth * aspectRatio
    else
        -- Height is the limiting dimension
        newDimensions.height = boxHeight
        newDimensions.width = boxHeight / aspectRatio
    end

    return newDimensions
end


function gdsGui_general_handleResize()
    -- Container-owned widgets use fraction-based sizing resolved by the container.
    -- Their standalone resize() methods reference creation-time values that are
    -- now fractions, not pixels, so skip them here; gdsGui_container_resize handles them.
    for _, obj in ipairs(globApp.objects.buttons) do
        if obj.resize and not obj.ownerContainer then obj:resize() end
    end
    for _, obj in ipairs(globApp.objects.tables) do
        if obj.resize then obj:resize() end
    end
    for _, obj in ipairs(globApp.objects.scrollBars) do
        if obj.resize and not obj.ownerContainer then obj:resize() end
    end
    for _, obj in ipairs(globApp.objects.rotaryKnobs) do
        if obj.resize and not obj.ownerContainer then obj:resize() end
    end
    -- Re-layout all pages that have containers so off-screen pages stay correct.
    local seen = {}
    for _, cont in ipairs(globApp.objects.containers) do
        if not seen[cont.page] then
            seen[cont.page] = true
            gdsGui_container_resize(cont.page)
        end
    end
end


function gdsGui_update (dt)

	globApp.lastDt = dt  -- cached so touch handlers avoid redundant love.timer.getDelta() calls

	--RESIZE TRIGGER CODE MUST GO BEFORE EVERYTHING THAT USES SAFESCREEN AREA TABLE
	globApp.resizeDetected = gdsGui_general_resizeDetect ()
	if globApp.resizeDetected == true then

		-- Add these lines to copy the safe area table
		globApp.lastSafeScreenArea = {
			x = globApp.safeScreenArea.x, y = globApp.safeScreenArea.y,
			w = globApp.safeScreenArea.w, h = globApp.safeScreenArea.h,
			xw = globApp.safeScreenArea.xw, yh = globApp.safeScreenArea.yh
		}
		
		globApp.totalWindowWidth = love.graphics.getWidth()
		globApp.totalWindowHeight = love.graphics.getHeight()
		globApp.displayOrientation = gdsGui_general_findScreenOrientation ()
		
		if globApp.isScreenSimulated == false then
			globApp.safeScreenArea = gdsGui_general_getScreenSafeArea ()
		end

		gdsGui_general_handleResize()

	end

	gdsGui_outputTxtBox_update(dt)
	gdsGui_table_physicsUpdate(dt)
	gdsGui_container_physicsUpdate(dt)

	globApp.txtBoxChangeDetected = gdsGui_inputTxtBox_changeTrigger ()
	if globApp.txtBoxChangeDetected == true then
		globApp.doesAnyTextBoxHaveEndingBlankSpace = gdsGui_inputTxtBox_hasEndingBlank ()
					-- print (globApp.doesAnyTextBoxHaveEndingBlankSpace)
		globApp.areCurrentPageRequiredInputTextBoxesEmpty = gdsGui_inputTxtBox_areRequiredEmpty ()
	end

	--UPDATES DEVELOPER DATA SHOWN ON EDGES OF 
	gdsGui_dev_updateDisplays (dt)

	gdsGui_saveLoad_updateProjectAvailability ()

	gdsGui_timeControl_updateTrigger (dt)

	gdsGui_page_loadingUpdate (dt)

	gdsGui_scrollBar_buttonsPressed (dt)

end


function gdsGui_draw ()

	gdsGui_page_loadingDraw ()
	gdsGui_general_draw ()
	gdsGui_dev_drawAll()

end

function gdsGui_general_draw ()

	-- Only re-search when the page index changes; saves a linear scan every draw call.
	if globApp._cachedPageIndex ~= globApp.currentPageIndex then
		globApp._cachedPageIndex = globApp.currentPageIndex
		for _, pgs in ipairs(pages) do
			if pgs.index == globApp.currentPageIndex then
				globApp._cachedPageName = pgs.name
				break
			end
		end
	end
	local activePageName = globApp._cachedPageName or 0

	gdsGui_container_draw (activePageName)
	gdsGui_outputTxtBox_draw (activePageName)
	gdsGui_table_draw (activePageName)
	gdsGui_scrollBar_draw (activePageName)
	gdsGui_rotaryKnob_draw (activePageName)
	gdsGui_button_draw (activePageName)

end


function gdsGui_general_relativePosition (anchorPoint, x, y, width, height, baseX, baseY, baseWidth, baseHeight)

	--positions sprites and other objects based on indicated anchor Point of the object and fractional position compared to base object
	
	--[[
	INPUT:

		anchorPoint: ------------string--------------LT,LC,LB,CT,CC,CB,RT,RC,RB relative
		x------------------------double--------------x coordinate obj
		y------------------------double--------------y coordinate obj
		width -------------------double--------------obj width
		height ------------------double--------------obj height
		baseX--------------------double--------------x coordinate base object
		baseY--------------------double--------------y coordinate base object
		baseWidth----------------double--------------base object widht
		baseHeight---------------double--------------base object height

	OUTPUT:

		Float number representing pixels of position (NOT PERCENTAGE OF SCREEN)
	]]


	local result = {}

	if string.upper(anchorPoint) == "LT" then

		result[1] = math.floor(baseX + (x * baseWidth))
		result[2] = math.floor(baseY + (y * baseHeight))

	elseif string.upper(anchorPoint) == "LC" then

		result[1] = math.floor(baseX + (x * baseWidth))
		result[2] = math.floor(baseY + (y * baseHeight) - height/2)

	elseif string.upper(anchorPoint) == "LB" then

		result[1] = math.floor(baseX + (x * baseWidth))
		result[2] = math.floor(baseY + (y * baseHeight) - height)

	elseif string.upper(anchorPoint) == "CT" then

		result[1] = math.floor(baseX + (x * baseWidth) - width/2)
		result[2] = math.floor(baseY + (y * baseHeight))

	elseif string.upper(anchorPoint) == "CC" then

		result[1] = math.floor(baseX + ((x * baseWidth) - width/2))
		result[2] = math.floor(baseY + ((y * baseHeight) - height/2))

	elseif string.upper(anchorPoint) == "CB" then

		result[1] = math.floor(baseX + (x * baseWidth) - width/2)
		result[2] = math.floor(baseY + (y * baseHeight) - height)

	elseif string.upper(anchorPoint) == "RT" then

		result[1] = math.floor(baseX + (x * baseWidth) - width)
		result[2] = math.floor(baseY + (y * baseHeight))

	elseif string.upper(anchorPoint) == "RC" then

		result[1] = math.floor(baseX + (x * baseWidth) - width)
		result[2] = math.floor(baseY + (y * baseHeight) - height/2)

	elseif string.upper(anchorPoint) == "RB" then

		result[1] = math.floor(baseX + (x * baseWidth) - width)
		result[2] = math.floor(baseY + (y * baseHeight) - height)

	end

	return result
	
end


function gdsGui_general_smartScaling (scalingMode, minPercentWidth, maxPercentWidth, minPercentHeight, maxPercentHeight, heightToWidthRatio,strgReturValue ) 
	--[[use percentage of total window size]]
	--[[PARAMETERS:
		scalingMode:------------string ------- inverse or normal
		minPercentWidth: -------float ---------percentage of window screen
		maxPercentWidth: -------float---------percentage of window screen
		minPercentHeight: ------float---------percentage of window screen
		maxPercentHeight: ------float---------percentage of window screen
		heightToWidthRatio------float---------height divided by width
		strgReturValue----------string--------"width","height" or "font"]]

		--[[declaring app window dimensions]]
	local currentWindowWidth = globApp.safeScreenArea.w
	local currentWindowHeight = globApp.safeScreenArea.h
	local winMinWidth = globApp.minWindowWidth
	local winMinHeight = globApp.minWindowHeight
	local winMaxWidth = globApp.maxWindowWidth
	local winMaxHeight = globApp.maxWindowHeight
	local winWidthSpan = winMaxWidth - winMinWidth --[[window width span]]
	local winHeightSpan = winMaxHeight - winMinHeight --[[window height span]]
	
	local newDimensions = {} --[[initialize result dimensions tables]]

	--[[Assign obj Min and Max pixel values based on percentage times min and max window values from above:]]
	if scalingMode == "inverse" then

			--[[devclaring object dimensions]]
		local objMinWidth = winMinWidth * maxPercentWidth
		local objMaxWidth = winMaxWidth * minPercentWidth
		local objMinHeight =  maxPercentHeight * winMinHeight
		local objMaxHeight =  minPercentHeight * winMaxHeight
		local objWidthSpan = objMaxWidth - objMinWidth
		local objHeightSpan = objMaxHeight - objMinHeight


		--[[determine object size as function of window size and mode (landscape,
		portrait)]]
		if currentWindowWidth < currentWindowHeight then --[[width is controlling if portrait]]
			
			newDimensions.newWidth = (currentWindowWidth - winMinWidth) / winWidthSpan
			
			newDimensions.newWidth = objMinWidth + (newDimensions.newWidth * objWidthSpan)

			newDimensions.newHeight = newDimensions.newWidth * heightToWidthRatio

		elseif currentWindowWidth >= currentWindowHeight then --[[height is controlling if landscape]]
			
			--[[determine the relationship between current window height to the total span of the window, result is percentage of total span]]
			newDimensions.newHeight = (currentWindowHeight - winMinHeight) / winHeightSpan

			--[[find new object heigth by multiplying previews value by object height span and adding the min objt height]]
			newDimensions.newHeight = objMinHeight + (newDimensions.newHeight * objHeightSpan)

			--[[new width = percentage new height from above times 1 divided the heightToWidthRatio parameter. fyi= we convert to widthToHeightRatio by dividing by one]]
			newDimensions.newWidth = newDimensions.newHeight * (1  / heightToWidthRatio )

		end

		if string.lower(strgReturValue) == "width" then

			return newDimensions.newWidth

		elseif string.lower(strgReturValue) == "height" then

			return newDimensions.newHeight

		end

	end

	if scalingMode == "normal" then

		--[[assing minimum and maximum values (PIXELS) to object variables
		based on parameters and window dimensions--see above]]
		
		--[[object width]]
		objMinWidth = winMinWidth * minPercentWidth
		objMaxWidth = winMaxWidth * maxPercentWidth

		--[[object height]]
		objMinHeight =  maxPercentHeight * winMaxHeight
		objMaxHeight =  minPercentHeight * winMinHeight

		--[[object widht and height span]]
		objWidthSpan = objMaxWidth - objMinWidth
		objHeightSpan = objMaxHeight - objMinHeight


		--[[determine object size as function of window size and mode (landscape,
		portrait)]]
		if currentWindowWidth < currentWindowHeight then --[[width is controlling if portrait]]
			
			newDimensions.newWidth = (currentWindowWidth - winMinWidth) / winWidthSpan
			--[[newWidth equals current window size minus minimum windowsize divided by the span]]

			newDimensions.newWidth = objMinWidth + (newDimensions.newWidth * objWidthSpan)

			newDimensions.newHeight = newDimensions.newWidth * heightToWidthRatio

		elseif currentWindowWidth >= currentWindowHeight then --[[height is controlling if landscape]]
			

			newDimensions.newHeight = (currentWindowHeight - winMinHeight) / winHeightSpan

			newDimensions.newHeight = objMinHeight + (newDimensions.newHeight * objHeightSpan)

			newDimensions.newWidth = newDimensions.newHeight * (1  / heightToWidthRatio )

		end

		if string.lower(strgReturValue) == "width" then

			return newDimensions.newWidth

		elseif string.lower(strgReturValue) == "height" then

			return newDimensions.newHeight

		end

	end

end


function gdsGui_general_resizeDetect ()
	--[[returns boolean true when it detects a change on window dimensions]]

	local resizeDetected = false

	local lastSaveWidth = globApp.totalWindowWidth
	globApp.lastWindowWidth = lastSaveWidth
	local lastSavedHeight = globApp.totalWindowHeight
	globApp.lastWindowHeight = lastSavedHeight

	local currentWidth, currentHeight = love.graphics.getDimensions()

	if lastSaveWidth ~= currentWidth or lastSavedHeight ~= currentHeight then

		resizeDetected = true
		print ("dev= resize detected!")

	end

	return resizeDetected

end



function gdsGui_general_smartFontScaling (minFontPercentSize, maxFontPercentSize)

	--[[window dimensions]]

	local currentWindowWidth = globApp.safeScreenArea.w
	local currentWindowHeight = globApp.safeScreenArea.h

	local winMinWidth = globApp.minWindowWidth
	local winMinHeight = globApp.minWindowHeight

	local winMaxWidth = globApp.maxWindowWidth
	local winMaxHeight = globApp.maxWindowHeight
	-- love.window.fromPixels(love.window.getDesktopDimensions( 1 ))

	local winWidthSpan = winMaxWidth - winMinWidth --[[window width span]]
	local winHeightSpan = winMaxHeight - winMinHeight --[[window height span]]
	
	--[[font dimensions:]]

	local newFontSize = 0  --[[initialize new font size -- return variable]]

	--[[determine font size as function of window size and mode (landscape,
		portrait)]]
	if currentWindowWidth <= currentWindowHeight then --[[smallest of window widht or height is controlling]]

		local fontMinSize =  maxFontPercentSize * winMinWidth
		local fontMaxSize =  minFontPercentSize * winMaxWidth
		local fontSizeSpan = fontMaxSize - fontMinSize
			
		newFontSize = (currentWindowWidth - winMinWidth) / winWidthSpan
		
		newFontSize = fontMinSize + (newFontSize * fontSizeSpan)

	elseif currentWindowWidth > currentWindowHeight then --[[height is controlling if landscape]]
		
		local fontMinSize =  maxFontPercentSize * winMinHeight
		local fontMaxSize =  minFontPercentSize * winMaxHeight
		local fontSizeSpan = fontMaxSize - fontMinSize

		newFontSize = (currentWindowHeight - winMinHeight) / winHeightSpan

		newFontSize = fontMinSize + (newFontSize * fontSizeSpan)

	end

	return newFontSize --[[returns value as pixels]]

end 


function gdsGui_general_smartRelocation (position_1, perOfScreen_1, position_2, perOfScreen_2, position_3, perOfScreen_3, position_4, perOfScreen_4, returnValue)
	--[[relocates objects to specified locations based on diferent screens sizes and aspect ratios, use height to width ratio ONLY]]

	--[[PARAMETERS:

		position_1 --------------------double--------------------relative percent of screen
		perOfScreen_1------------------double--------------------percentage of total span
		position_2 --------------------double--------------------relative percent of screen
		perOfScreen_2------------------double--------------------percentage of total span
		position_3 --------------------double--------------------relative percent of screen
		perOfScreen_3------------------double--------------------percentage of total span
		position_4 --------------------double--------------------relative percent of screen
		perOfScreen_4------------------double--------------------percentage of total span
		returnValue -------------------string--------------------x or y
	
	]]

	local countConstraints = 0 --[[determines how many contraints were received as parameter]]

	--[[window dimensions]]

	local winMaxWidth = globApp.maxWindowWidth
	local winMaxHeight = globApp.maxWindowHeight

	-- local winMaxWidth = globApp.safeScreenArea.w
	-- local winMaxHeight = globApp.safeScreenArea.h

	-- winMaxHeight = love.window.getDesktopDimensions( 1 ) --removed on 12/16/2021
	
	if returnValue == "x" then

		winMinWidth = globApp.minWindowWidth
		
		winWidthSpan = winMaxWidth - winMinWidth --[[window width span]]
		
		currentPercWinSize = (globApp.safeScreenArea.w - winMinWidth) / winWidthSpan

	elseif returnValue == "y" then

		winMinHeight = globApp.minWindowHeight

		winHeightSpan = winMaxHeight - winMinHeight --[[window height span]]

		currentPercWinSize = (globApp.safeScreenArea.h - winMinHeight) / winHeightSpan

	end

	--[[Creating a sorted table]]
	local positions = {}

	if position_1 ~= nil then

		local siglePositions = {}
			siglePositions.objPosition = position_1
			siglePositions.windPercSize = perOfScreen_1

		table.insert(positions, siglePositions)

	end

	if position_2 ~= nil then
		
		local siglePositions = {}
			siglePositions.objPosition = position_2
			siglePositions.windPercSize = perOfScreen_2

		table.insert(positions, siglePositions)

	end

	if position_3 ~= nil then
		
		local siglePositions = {}
			siglePositions.objPosition = position_3
			siglePositions.windPercSize = perOfScreen_3

		table.insert(positions, siglePositions)

	end

	if position_4 ~= nil then

		local siglePositions = {}
			siglePositions.objPosition = position_4
			siglePositions.windPercSize = perOfScreen_4

		table.insert(positions, siglePositions)

	end

	local sortedValuesTable = {}
			sortedValuesTable.windowPerSizes = {}
			sortedValuesTable.objPerLocation = {}


	for i,p in ipairs (positions) do

		winPerCValue = p.windPercSize

		sortedValuesTable.windowPerSizes[i]= winPerCValue --[[inserts unsorted windowPerSize values into sorting table]]

	end

	table.sort(sortedValuesTable.windowPerSizes) --[[sorts the values of the positions table]]
		
	for i,tbl1column1val in ipairs (sortedValuesTable.windowPerSizes) do--[[inserts values of corresponding unsorted table into second table created on parallel to sorted first collumn tables]]
		
		for j, tbl2val in ipairs (positions) do

			winPerCValue = tbl2val.windPercSize

			objPositionVal =  tbl2val.objPosition

			if tbl1column1val == winPerCValue then

				sortedValuesTable.objPerLocation[i] = objPositionVal

			end

		end

		countConstraints = countConstraints + 1
	
	end

	local currentHeightToWidthRatio = globApp.safeScreenArea.h / globApp.safeScreenArea.w--define the current width to height ratio of the screen

	local minScreenSizeCons = sortedValuesTable.windowPerSizes[1] --define minimum constraint value

	local maxScreenSizeCons = sortedValuesTable.windowPerSizes[#sortedValuesTable.windowPerSizes] --define the maximum contraint value

	local middlePoints = {}

	for i = 1,(#sortedValuesTable.windowPerSizes - 1), 1 do

		middlePoints[i] = sortedValuesTable.windowPerSizes[i] + ((sortedValuesTable.windowPerSizes[i + 1 ] - sortedValuesTable.windowPerSizes[i]) / 2)
	
	end

	if countConstraints == 2 then

		if currentPercWinSize <= middlePoints[1] then

			return sortedValuesTable.objPerLocation[1]

		elseif currentPercWinSize > middlePoints[1] then

			return sortedValuesTable.objPerLocation[2]

		end

	elseif countConstraints == 3 then

		if currentPercWinSize <= middlePoints[1] then

			return sortedValuesTable.objPerLocation[1]

		elseif currentPercWinSize > middlePoints[1] and currentPercWinSize < middlePoints[2] then

			return sortedValuesTable.objPerLocation[2]

		elseif currentPercWinSize >= middlePoints[2] then

			return sortedValuesTable.objPerLocation[3]

		end

	elseif countConstraints == 4 then

		if currentPercWinSize <= middlePoints[1] then

			return sortedValuesTable.objPerLocation[1]

		elseif currentPercWinSize > middlePoints[1] and currentPercWinSize <= middlePoints[2] then

			return sortedValuesTable.objPerLocation[2]

		elseif currentPercWinSize > middlePoints[2] and currentPercWinSize < middlePoints[3] then

			return sortedValuesTable.objPerLocation[3]


		elseif currentPercWinSize >= middlePoints[3] then

			return sortedValuesTable.objPerLocation[4]

		end

	end

end


function gdsGui_general_findScreenOrientation (myWidht, myHeight, devMode)

	local currentWidht = globApp.safeScreenArea.w
	local currentHeight = globApp.safeScreenArea.h
	local result = "no orientation"

	if devMode ==  true then	
		currentWidht = myWidht
		currentHeight = myHeight
	end

	local widthToHeightRatio = currentWidht / currentHeight


	if widthToHeightRatio > 1 then
		result = "landscape"
	elseif widthToHeightRatio == 1 then
		result = "square"
	elseif widthToHeightRatio < 1 then
		result = "portrait"
	end

	return result

end


function gdsGui_general_determineSafeArea (strgOrientation, strgOS, myWidht, myHeight, isDevMode)

	local safeScreenArea = {}

	local totalWidth = globApp.totalWindowWidth
	local totalHeight = globApp.totalWindowHeight
	local OS = globApp.OperatingSystem
	local screenOrientation = globApp.displayOrientation

	if isDevMode == true then
		totalWidth = myWidht
		totalHeight = myHeight
		OS = strgOS
		screenOrientation = strgOrientation

	end


	if OS ==  "Android" or  OS == "iOS" then

		if screenOrientation == "portrait" then

			safeScreenArea[1] = 0
			safeScreenArea[2] = totalHeight * 0.06
			safeScreenArea[3] = totalWidth
			safeScreenArea[4] = totalHeight * .88


		elseif screenOrientation == "landscape"  then

			safeScreenArea[1] = totalWidth * 0.06
			safeScreenArea[2] = 0
			safeScreenArea[3] = totalWidth * .88
			safeScreenArea[4] = totalHeight * .94 

		elseif screenOrientation == "square"  then

			safeScreenArea[1] = totalWidth * 0.8
			safeScreenArea[2] = totalHeight * 0.8 
			safeScreenArea[3] = totalWidth * 0.84
			safeScreenArea[4] = totalHeight * 0.84 

		end

	else 

		safeScreenArea[1] = 0
		safeScreenArea[2] = 0
		safeScreenArea[3] = totalWidth
		safeScreenArea[4] = totalHeight

	end

	safeScreenArea[5] = safeScreenArea[1] + safeScreenArea[3]
	safeScreenArea[6] = safeScreenArea[2] + safeScreenArea[4]

	return safeScreenArea 


end


function gdsGui_general_getScreenSafeArea ()

	local safeScreenArea = {}
	local x, y, w, h = love.window.getSafeArea( )
		
	safeScreenArea.x = x
	safeScreenArea.y = y
	safeScreenArea.w = w
	safeScreenArea.h = h
	safeScreenArea.xw = safeScreenArea.x + safeScreenArea.w
	safeScreenArea.yh = safeScreenArea.y + safeScreenArea.h

	return safeScreenArea 

end



------------------------------------------------------------------------------
				--TOUCHES AND CLICKS
------------------------------------------------------------------------------

function love.touchpressed( id, x, y, dx, dy, pressure )

	gdsGui_general_touchpressed (id, x, y, dx, dy, pressure)

end


function love.touchmoved( id, x, y, dx, dy, pressure )

	gdsGui_general_touchmoved (id, x, y, dx, dy, pressure)

end


function love.touchreleased( id, x, y, dx, dy, pressure )

	gdsGui_general_touchreleased (id, x, y, dx, dy, pressure)

end


function love.mousepressed (x,y,button,istouch, presses)

	gdsGui_general_mousepressed (x, y, button, istouch, presses)

end

function love.mousemoved ( x, y, button, istouch, presses )

	gdsGui_general_mousemoved (x, y, button, istouch, presses)

end


function love.mousereleased ( x, y, button, istouch, presses )

	gdsGui_general_mousereleased (x, y, button, istouch, presses)

end




function gdsGui_general_isTouchInSafeArea (touchX, touchY)

	local result = false
	
	if touchX >= globApp.safeScreenArea.x and touchX <= globApp.safeScreenArea.xw and touchY >= globApp.safeScreenArea.y and touchY <= globApp.safeScreenArea.yh then

		result = true
	
	end
	
	return result
	
end

function gdsGui_general_convertButtonNumToString (buttonNum)

	local buttonName = ""

	if buttonNum == 1 then
		buttonName = "left"
	elseif buttonNum == 2 then
		buttonName = "right"
	end

	return buttonName

end


---------------MOUSE-----------------------

function gdsGui_general_mousepressed (x, y, button, istouch, presses)

	if istouch == false then

		local buttonName = gdsGui_general_convertButtonNumToString (button)

		local calledFunction = (buttonName .. " click pressed")
		globApp.userInput = calledFunction

gdsGui_button_pressed (x,y,button,istouch) --runs when clicked on created buttons
		
		gdsGui_inputTxtBox_pressed (x,y,button,istouch) --runs when clicked or touched on textboxes

		gdsGui_table_buttonsPressed (x,y,button,istouch)

		gdsGui_scrollBar_focus ("mouse", x,y,button,istouch)

		gdsGui_outputTxtBox_scrollbarPressed("mouse", x, y, button, istouch)

		gdsGui_rotaryKnob_pressed ("mouse", x, y)

		-- Mark tables where mouse press started inside the scrollable area.
		local activePage = gdsGui_page_currentName()
		for _, tbl in ipairs(globApp.objects.tables) do
			if tbl.scroll and tbl.page == activePage then
				if x >= tbl.scrollBox.x and x <= (tbl.scrollBox.x + tbl.scrollBox.width) and
				   y >= tbl.scrollBox.y and y <= (tbl.scrollBox.y + tbl.scrollBox.height) then
					tbl.scroll.touchStartedInside = true
				end
			end
		end

		gdsGui_container_markTouchStart(x, y)

		if x >= .8 * globApp.safeScreenArea.xw and y >= .9 * globApp.safeScreenArea.yh then

			gdsGui_dev_openByEightTap (x,y,button,istouch) -- opens and closes devPage

		end

	end

end


function gdsGui_general_mousereleased (x, y, button, istouch, presses)
	
	if istouch == false then

		local buttonName = gdsGui_general_convertButtonNumToString (button)

		if globApp.userInput == (buttonName .. " click pressed") then

			local calledFunction = (buttonName .. " click")
			globApp.userInput = calledFunction

			gdsGui_button_released (x, y, 1, istouch, presses)
		
			gdsGui_table_rowSelect (x,y,button,istouch)

			gdsGui_table_buttonsReleased (x,y,button,istouch)

			gdsGui_scrollBar_unfocus ("mouse", x,y,button,istouch)

			gdsGui_rotaryKnob_released ("mouse")

			gdsGui_outputTxtBox_touchReleased ("mouse", x, y)
			gdsGui_table_touchReleasedScroll (x, y)
			gdsGui_container_touchReleased(x, y)

			globApp.userInput = "none"

		end

	end

end


function gdsGui_general_mousemoved (x, y, button, istouch, presses)
	-- NOTE: in LÖVE's love.mousemoved signature, the 3rd/4th params are dx/dy.
	-- The existing code names them 'button' and 'istouch' — preserved as-is.
	-- So here: button = dx, istouch = dy, presses = actual LÖVE istouch boolean.

	-- On mobile, love.mousemoved fires for touch events (istouch=true) in addition
	-- to love.touchmoved. Skip here to avoid applying scroll deltas twice.
	if presses then return end

	gdsGui_scrollBar_holdAndDrag ("mouse", x, y, button, istouch)

	-- button = dx, istouch = dy for this callback (see note above).
	gdsGui_rotaryKnob_moved ("mouse", x, y, button, istouch)

	-- Pass mouse drag deltas into the output textbox and table scroll systems.
	-- button = dx, istouch = dy (see note above).
	gdsGui_outputTxtBox_touchScroll(nil, x, y, button, istouch, nil, nil, nil)
	gdsGui_table_touchScroll(nil, x, y, button, istouch, nil, nil, nil)
	gdsGui_container_touchScroll(nil, x, y, button, istouch)

end


---------------------------------------------------------------------
					--KEYBOARD AND TEXT GATHERING
---------------------------------------------------------------------

function love.textinput(t)

	gdsGui_inputTxtBox_textUpdate ("add",t, nil)

end


function love.keypressed(key, unicode)

	if gdsGui_general_isTextRemoveCommanded (key) == true then
		gdsGui_inputTxtBox_textUpdate ("remove",nil, key)
	end
	
	gdsGui_inputTxtBox_tabToSwitch (key)

end 

function gdsGui_general_isTextRemoveCommanded (key)

	local removeKeys = {}
		removeKeys[1] = "backspace"
		removeKeys[2] = "delete"

	local isRemoveKeyValid = false

	for i, rk in ipairs (removeKeys) do

		if key == rk then 

			isRemoveKeyValid = true

		end

	end

	return isRemoveKeyValid

end


--------------------------------------------------
				--TOUCHSCREEN INTERACTION
--------------------------------------------------

function gdsGui_general_touchpressed (id, x, y, dx, dy, pressure)

	local calledFunction = "touch pressed"

	globApp.userInput = calledFunction -- insert code below this line to user glob var

	gdsGui_button_pressed (x,y,1,true) --runs when clicked on created buttons

	gdsGui_table_buttonsPressed (x,y,1,true)

	gdsGui_scrollBar_focus (id, x,y,1,true)

	gdsGui_outputTxtBox_scrollbarPressed(id, x, y, 1, true)

	gdsGui_rotaryKnob_pressed (id, x, y)

	gdsGui_table_rowSelect (x,y,1,true)

	-- Mark tables where touch started inside the scrollable area.
	local activePage = gdsGui_page_currentName()
	for _, tbl in ipairs(globApp.objects.tables) do
		if tbl.scroll and tbl.page == activePage then
			if x >= tbl.scrollBox.x and x <= (tbl.scrollBox.x + tbl.scrollBox.width) and
			   y >= tbl.scrollBox.y and y <= (tbl.scrollBox.y + tbl.scrollBox.height) then
				tbl.scroll.touchStartedInside = true
			end
		end
	end

	gdsGui_container_markTouchStart(x, y)

end

function gdsGui_general_touchmoved (id, x, y, dx, dy, pressure)

	touches = love.touch.getTouches()

	local calledFunction = "slide"
	local slideSensitivity=3
	local slideSensitivityPixelsPositive = slideSensitivity
	local slideSensitivityPixelsNegative = -(slideSensitivity)

	-- Handle scrollbar and knob drag for this specific touch independently.
	gdsGui_scrollBar_holdAndDrag (id, x, y, 1, true)
	gdsGui_rotaryKnob_moved (id, x, y, dx, dy)

	for i, tchs in ipairs (touches) do --isolate to first touch only

		if i == 1 then

			if globApp.userInput == "touch pressed" and ((dx > slideSensitivityPixelsPositive or dx < slideSensitivityPixelsNegative) or (dy > slideSensitivityPixelsPositive or dy < slideSensitivityPixelsNegative )) then

				globApp.userInput = "slide"

			end

			gdsGui_button_released (x, y, 1, istouch, presses)

			gdsGui_table_touchScroll (id, x, y, dx, dy, pressure, button, istouch)

			gdsGui_outputTxtBox_touchScroll (id, x, y, dx, dy, pressure, button, istouch)
			gdsGui_container_touchScroll(id, x, y, dx, dy)

		end

	end

end


function gdsGui_general_touchreleased (id, x, y, dx, dy, pressure)

	local calledFunction = "touch released"

	if globApp.userInput == "touch pressed" then

		globApp.userInput = "tap"

	end 

	
	if 	globApp.userInput == "tap" then

		-- buttons_pressed (x,y,button,istouch) --runs when clicked on created buttons

		gdsGui_button_released (x, y, 1, istouch, presses)		gdsGui_inputTxtBox_pressed (x,y,button,istouch) --runs when clicked or touched on textboxes
		gdsGui_table_rowSelect (x,y,button,true)

		if x >= .8 * globApp.safeScreenArea.xw and y >= .9 * globApp.safeScreenArea.yh then
			gdsGui_dev_openByEightTap (x,y,button,istouch) -- opens and closes devPage 
		end

	end

	globApp.userInput = calledFunction

	gdsGui_table_buttonsReleased (x,y,button,istouch)

	gdsGui_scrollBar_unfocus (id, x,y,1,true)

	gdsGui_rotaryKnob_released (id)

	gdsGui_outputTxtBox_touchReleased (id, x, y)
	gdsGui_table_touchReleasedScroll (x, y)
	gdsGui_container_touchReleased(x, y)

	globApp.userInput = "none"

end


--------------------------------------------------------------------------------
							--FONT
--------------------------------------------------------------------------------
function gdsGui_general_returnFontInfo (thisFont, reqInfo)

	local result = {}

	result.lineHeight = thisFont:getLineHeight()
	result.baseline = thisFont:getBaseline()
	result.ascent = thisFont:getAscent()
	result.descent = thisFont:getDescent()
	result.height = thisFont:getHeight()
	result.width = thisFont:getWidth(1)


	if reqInfo == "print" then
		local printString = ""
		for i, info in pairs (result) do
			printString = (printString .. i .. "=" .. info .. " || ")
		end
		print (printString)
	else 
		for i, info in pairs (result) do
			if reqInfo == i then
				local tblResult = {}
				tblResult[1] = info
				return tblResult[1]
			end
		end
	end
	
end


-------------------------------------------------------------------------------------
							--READ ABOUT PAGE
-------------------------------------------------------------------------------------

function gdsGui_general_doesAboutPageExist (path, isUnitTest)
	local exists = false
   	local info = love.filesystem.getInfo(path)
   	if info ~= nil then
   		exists = true
   	else
   		if isUnitTest ~= true then
   			gdsGui_generateConsoleMessage ("error", "no about.txt file was found, add one")
   		end
   	end
   	return exists
end

function gdsGui_general_isAboutFileEmpty (path, isUnitTest)
	local isEmpty = true
	contents, size = love.filesystem.read( path )
	if size > 0 then
		isEmpty = false
	else
		if isUnitTest ~= true or isUnitTest == nil then
			gdsGui_generateConsoleMessage ("error", "your " .. path .. " file is empty")
		end
	end
	return isEmpty
end

function gdsGui_general_readAboutPage ()
	local aboutFileExits = gdsGui_general_doesAboutPageExist ("about.txt")
	if aboutFileExits == true then
		local isAboutFileEmpty = gdsGui_general_isAboutFileEmpty ("about.txt")
		local contents = "NO ABOUT.TXT FILE FOUND"
		if aboutFileExits == true and isAboutFileEmpty == false then
			contents = love.filesystem.read( "about.txt" )
		end
		return contents
	end
end

function gdsGui_general_readLibraryInfo ()
	local path = "Libraries/gds_love2d_gui/gds_love2d_gui_info.txt"
	local info = love.filesystem.getInfo(path)
	if info ~= nil then
		local contents, size = love.filesystem.read(path)
		if size and size > 0 then
			return contents
		end
	end
	return "Library info file not found."
end



--THE FOLLOWING TABLE VARIABLE CONTAINS ALL GUI OBJECTS
-- gui_objects = {}

--[[GLOBAL VARIABLES TABLE:]]
	globApp = {} --[[global variables table]]
		globApp.BUTTON_STATES = {
			DEACTIVATED = 0,
			RELEASED = 1,
			PRESSED = 2
		}
		globApp.objects = {}
		globApp.developerMode = false
		globApp.OperatingSystem  = love.system.getOS( ) --[["OS X", "Windows", "Linux", "Android" or "iOS"]]
		globApp.fourDevTap = false
		globApp.devTapCounter = 0
		globApp.minWindowWidth = 230 --[[defines minimum app width]]
		globApp.minWindowHeight = 230 --[[defines minimum app height]]
		globApp.maxWindowWidth = 1920
		globApp.maxWindowHeight = 1920
		globApp.appColor = {0.15,0.15,0.15,1} -- RGBT 0-1
		globApp.numObjectsDisplayed = 0 --[[displayed on lower status bar]]
		globApp.totalWindowWidth = love.graphics.getWidth() --[[can be called instd love func]]
		globApp.totalWindowHeight = love.graphics.getHeight() --[[can be called instd love func]]
		globApp.safeScreenArea = gdsGui_general_getScreenSafeArea () --gdsGui_general_simulateUnsafeArea (0,.1,1,.8) --
		globApp.lastSafeScreenArea = globApp.safeScreenArea -- Add this line
		globApp.isScreenSimulated = false
		globApp.displayOrientation = gdsGui_general_findScreenOrientation ()
		globApp.appScale = love.graphics.getDPIScale ()
		globApp.currentPageIndex = 1 --[[activates the first page to load when app starts]]
		globApp.pageChanged = false
		globApp.resizeDetected = false --[[Event Initialization]]
		globApp.lastWindowWidth = 0
		globApp.lastWindowHeight = 0
		globApp.txtBoxChangeDetected = false --[[Event initialization]]
		globApp.areCurrentPageRequiredInputTextBoxesEmpty = true
		globApp.doesAnyTextBoxHaveEndingBlankSpace = true
		globApp.projects = {} --[[table that contains all the saved projects data]]
		globApp.projectAvailable = false --[[true activates the main menu "Loal Projct but."]]
		globApp.projectsTblChanged = false
		globApp.selectedProject = "none"
		globApp.userInput = "none"
		globApp.mouseSensitivity = 2
		globApp.touchSensitivity = 2
		globApp.scrollbarThickness = 15
		globApp.devCompanyAcronym = "GDS"
		globApp.aboutPageContent = gdsGui_general_readAboutPage ()
		globApp.libraryInfoContent = gdsGui_general_readLibraryInfo ()

	devSpritesPath = "Libraries/gds_love2d_gui/librarySprites/"