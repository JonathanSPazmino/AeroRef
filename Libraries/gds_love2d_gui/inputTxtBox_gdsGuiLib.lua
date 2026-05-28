-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[textBox_logic.lua]]

textBoxes = {}

CurrentPageTxtBoxValues = {}

function gdsGui_inputTxtBox_create (txtBxId, page, tblTextSpecs, theme_focus, theme_NOTfocus,theme_deactivated,strgtxtBoxCursor,isRequired, myx, myy, anchorPoint, myWidth, myHeight, strgCallbackFunc, tabNum, fontSize, customText, containerName)

	--[[INPUT:
		txtBxId -------------------string-------name of button
		page-----------------------string-------select page from pageNameList table
		theme_focus----------string or table----pngFile or color tbl (frame,fill,inputBox,text)
		theme_NOTfocus-------string or table----pngFile or color tbl (frame,fill,inputBox,text)
		theme_deactivated----string or table----pngFile or color tbl (frame,fill,inputBox,text)
		strgtxtBoxCursor-----------string-------txtBox cursor Character
		defaultText----------------string-------parameter default text
		maxChrNum------------------integer------maximum number of allowed characters
		myx------------------------double-------0 to 1 relative to window size
		myy------------------------double-------0 to 1 relative to window size
		anchorPoint----------------string-------LT,LC,LB,CT,CC,CB,RT,RC,RB
		myWidth--------------------double-------pixels
		myHeight-------------------double-------pixels
		strgCallbackFunc-----------string-------Name of callback funciton
		tabNum---------------------integer------Tab index
		fontSize ------------------integer------int to avoid blurry font

		OUTPUT:
		Objt representing text input box]]

	local nitb = {}
	--new input text box (nitb)

	nitb.id = txtBxId--[[name of txtbox]]
	nitb.page = page--[[page location]]
	nitb.cursor = "|" --[[cursor character]]
	nitb.cursoredCustomText = customText
	nitb.textSpecs = tblTextSpecs
	nitb.state = 1 --[[0 deactivated, 1 = NotFocused, 2 = Focused.]]
	nitb.callbackFunc = strgCallbackFunc
	nitb.maxChrNum = tblTextSpecs["maxCharCount"]
	nitb.defaultText = nitb.id
	nitb.isRequired = isRequired
	if nitb.isRequired == true then
		nitb.initialInstructionText = "Required"
	elseif nitb.isRequired == false then
		nitb.initialInstructionText = "Optional"
	end
	if customText == "" then
		nitb.customText = nitb.initialInstructionText
	else
		nitb.customText = nitb.cursoredCustomText
	end
	nitb.unCoursedCustomText = nitb.customText
	nitb.collectedData = ""
	nitb.textFont = love.graphics.newFont(fontSize)

	nitb.frame = {}
		nitb.frame.width = myWidth
		nitb.frame.height = myHeight
		local myPositions = gdsGui_general_relativePosition (anchorPoint, myx, myy, nitb.frame.width, nitb.frame.height, globApp.safeScreenArea.x, globApp.safeScreenArea.y, globApp.safeScreenArea.w, globApp.safeScreenArea.h) --do not move this line to other part.
		nitb.frame.x = myPositions[1]
		nitb.frame.y = myPositions[2]	

	nitb.lable = {}
		nitb.lable.frame = {}
			nitb.lable.frame.y = nitb.frame.y + (globApp.safeScreenArea.h * 0.01)
			nitb.lable.frame.x = nitb.frame.x + (nitb.lable.frame.y - nitb.frame.y)
			nitb.lable.frame.width = (nitb.frame.width / 2) - (nitb.frame.width * 0.06)
			nitb.lable.frame.height = nitb.frame.height - ( 2 * (nitb.lable.frame.y - nitb.frame.y))

		nitb.lable.text = {}
			nitb.lable.text.x = nitb.lable.frame.x + (nitb.lable.frame.width * 0.05)
			
			nitb.lable.text.width = nitb.lable.frame.width - (nitb.lable.frame.width * 0.1)
			nitb.lable.text.height = nitb.lable.frame.height - (nitb.lable.frame.height * 0.1)
			nitb.lable.text.text = nitb.defaultText
			nitb.lable.text.maxLineCount = findMaxNumOfLinesNeeded (nitb.textFont, nitb.lable.text.width, nitb.defaultText)
			nitb.lable.text.perLineTextHeight = gdsGui_general_returnFontInfo (nitb.textFont, "height")

			--adds all lines height
			nitb.lable.text.totalTextHeight = (nitb.lable.text.maxLineCount * nitb.lable.text.perLineTextHeight)
			nitb.lable.text.height = nitb.lable.text.totalTextHeight
			--adjusts for margines spacer:
			nitb.lable.text.totalTextHeight = nitb.lable.text.totalTextHeight + (nitb.lable.text.totalTextHeight * .1)
			nitb.lable.text.vertHalfTextHeight = nitb.lable.text.totalTextHeight / 2

			nitb.lable.text.y = (nitb.lable.frame.y + ( nitb.lable.frame.height / 2 ) - nitb.lable.text.vertHalfTextHeight)

	nitb.userInput = {}
		nitb.userInput.frame = {}
			nitb.userInput.frame.y = nitb.lable.frame.y
			nitb.userInput.frame.x = nitb.frame.x + (nitb.frame.width / 2) + (nitb.lable.frame.y - nitb.frame.y)
			nitb.userInput.frame.width = nitb.lable.frame.width
			nitb.userInput.frame.height = nitb.lable.frame.height

		nitb.userInput.text = {}
			nitb.userInput.text.lines = {}
			nitb.userInput.text.x = nitb.userInput.frame.x + (nitb.userInput.frame.width * 0.05)
			nitb.userInput.text.width = nitb.userInput.frame.width - (nitb.userInput.frame.width * 0.1)
			nitb.userInput.text.height = nitb.userInput.frame.height - (nitb.userInput.frame.height * 0.1)
			nitb.userInput.text.maxLineCount = findMaxNumOfLinesNeeded (nitb.textFont, nitb.userInput.text.width, nitb.defaultText)
			nitb.userInput.text.perLineTextHeight = gdsGui_general_returnFontInfo (nitb.textFont, "height")

			--adds all lines height
			nitb.userInput.text.totalTextHeight = (nitb.userInput.text.maxLineCount * nitb.userInput.text.perLineTextHeight)
			nitb.userInput.text.height = nitb.userInput.text.totalTextHeight
			--adjusts for margines spacer:
			nitb.userInput.text.totalTextHeight = nitb.userInput.text.totalTextHeight + (nitb.userInput.text.totalTextHeight * .1)
			nitb.userInput.text.vertHalfTextHeight = nitb.userInput.text.totalTextHeight / 2


			local newMaxAllowedLineCount = math.floor(nitb.userInput.frame.height / nitb.userInput.text.perLineTextHeight)
			nitb.userInput.text.y = (nitb.userInput.frame.y + ( nitb.userInput.frame.height / 2 ) - ((newMaxAllowedLineCount * nitb.userInput.text.perLineTextHeight) / 2))

	nitb.themes = {}
		nitb.themes.type = "none"
		if type(theme_focus) == "table" and type (theme_NOTfocus) == "table" and type (theme_deactivated) == "table" then
			nitb.themes.type = "colors"
			nitb.themes.colors = {}
				nitb.themes.colors.focus = {}
					nitb.themes.colors.focus.frame = theme_focus["frame"]
					nitb.themes.colors.focus.fill = theme_focus["fill"]
					nitb.themes.colors.focus.inputBox = theme_focus["inputBox"]
					nitb.themes.colors.focus.text = theme_focus["text"]

				nitb.themes.colors.NOTfocus = {}
					nitb.themes.colors.NOTfocus.frame = theme_NOTfocus["frame"]
					nitb.themes.colors.NOTfocus.fill = theme_NOTfocus["fill"]
					nitb.themes.colors.NOTfocus.inputBox = theme_NOTfocus["inputBox"]
					nitb.themes.colors.NOTfocus.text = theme_NOTfocus["text"]

				nitb.themes.colors.deactivated = {}
					nitb.themes.colors.deactivated.frame = theme_deactivated["frame"]
					nitb.themes.colors.deactivated.fill = theme_deactivated["fill"]
					nitb.themes.colors.deactivated.inputBox = theme_deactivated["inputBox"]
					nitb.themes.colors.deactivated.text = theme_deactivated["text"]

		elseif type(theme_focus) == "string" and type (theme_NOTfocus) == "string" and type (theme_deactivated) == "string" then
			nitb.themes.type = "sprites"
			nitb.themes.sprites = {}

				if theme_focus ~= nil then
					nitb.themes.sprites.focus_png = love.graphics.newImage(theme_focus) 
				end

				if theme_NOTfocus ~= nil then
					nitb.themes.sprites.not_focused_png = love.graphics.newImage(theme_NOTfocus) 
					nitb.themes.sprites.width = nitb.frame.width / nitb.themes.sprites.not_focused_png:getWidth () 
					nitb.themes.sprites.height = nitb.frame.height / nitb.themes.sprites.not_focused_png:getHeight ()
				end

				if theme_deactivated ~= nil then
					nitb.themes.sprites.deactivated_png = love.graphics.newImage(theme_deactivated)
				end

		end

	nitb.myMaxx = nitb.frame.x + nitb.frame.width --[[for button click detection]]
	nitb.myMaxy = nitb.frame.y + nitb.frame.height--[[for button click detection]]
	nitb.tabNum = tabNum

	nitb.userGuideBox = {}

		nitb.userGuideBox.textMarginSpaces = 0.25

		maxDefaultTextLineCount = findMaxNumOfLinesNeeded (nitb.textFont, nitb.frame.width, nitb.defaultText)
		actualDefaultTextFontHeight = gdsGui_general_returnFontInfo (nitb.textFont, "height")

		--adds all lines height
		totalTextHeight = (actualDefaultTextFontHeight * maxDefaultTextLineCount)
		--adjusts for margines spacer:
		totalTextHeight = totalTextHeight + (totalTextHeight * (nitb.userGuideBox.textMarginSpaces * 2))

		nitb.userGuideBox.frame = {}
			nitb.userGuideBox.frame.width = nitb.frame.width
			nitb.userGuideBox.frame.height =  totalTextHeight
			nitb.userGuideBox.frame.x = nitb.frame.x
			nitb.userGuideBox.frame.y = nitb.frame.y - nitb.userGuideBox.frame.height


		nitb.userGuideBox.text = {}
			nitb.userGuideBox.text.x = nitb.userGuideBox.frame.x + (nitb.userGuideBox.frame.width * nitb.userGuideBox.textMarginSpaces)
			nitb.userGuideBox.text.y = nitb.userGuideBox.frame.y + (nitb.userGuideBox.frame.height * nitb.userGuideBox.textMarginSpaces)
			nitb.userGuideBox.text.width = nitb.userGuideBox.frame.width - (nitb.userGuideBox.frame.width * (nitb.userGuideBox.textMarginSpaces * 2))
			nitb.userGuideBox.text.height = nitb.userGuideBox.frame.height - (nitb.userGuideBox.frame.height * (nitb.userGuideBox.textMarginSpaces * 2))
			



	table.insert(textBoxes,nitb)

	globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
	if containerName then
		gdsGui_container_addObject(containerName, "inputTxtBox", txtBxId)
	end

end

function gdsGui_inputTxtBox_update(txtBxId,anchorPoint, myx, myy, myWidth, myHeight,fontSize)
	
	for i, updTxtBx in ipairs(textBoxes) do 

		if updTxtBx.id == txtBxId then

			updTxtBx.textFont = love.graphics.newFont(fontSize)

			updTxtBx.frame.width = myWidth
			updTxtBx.frame.height = myHeight
			local myPositions = gdsGui_general_relativePosition (anchorPoint, myx, myy, updTxtBx.frame.width, updTxtBx.frame.height, globApp.safeScreenArea.x, globApp.safeScreenArea.y, globApp.safeScreenArea.w, globApp.safeScreenArea.h) --do not move this line to other part.
			updTxtBx.frame.x = myPositions[1]
			updTxtBx.frame.y = myPositions[2]	

			updTxtBx.lable.frame.y = updTxtBx.frame.y + (globApp.safeScreenArea.h * 0.01)
			updTxtBx.lable.frame.x = updTxtBx.frame.x + (updTxtBx.lable.frame.y - updTxtBx.frame.y)
			updTxtBx.lable.frame.width = (updTxtBx.frame.width / 2) - (updTxtBx.frame.width * 0.06)
			updTxtBx.lable.frame.height = updTxtBx.frame.height - ( 2 * (updTxtBx.lable.frame.y - updTxtBx.frame.y))

			updTxtBx.lable.text.x = updTxtBx.lable.frame.x + (updTxtBx.lable.frame.width * 0.05)
			
			updTxtBx.lable.text.width = updTxtBx.lable.frame.width - (updTxtBx.lable.frame.width * 0.1)
			updTxtBx.lable.text.height = updTxtBx.lable.frame.height - (updTxtBx.lable.frame.height * 0.1)
			updTxtBx.lable.text.maxLineCount = findMaxNumOfLinesNeeded (updTxtBx.textFont, updTxtBx.lable.text.width, updTxtBx.defaultText)
			updTxtBx.lable.text.perLineTextHeight = gdsGui_general_returnFontInfo (updTxtBx.textFont, "height")

			--adds all lines height
			updTxtBx.lable.text.totalTextHeight = (updTxtBx.lable.text.maxLineCount * updTxtBx.lable.text.perLineTextHeight)
			updTxtBx.lable.text.height = updTxtBx.lable.text.totalTextHeight
			--adjusts for margines spacer:
			updTxtBx.lable.text.totalTextHeight = updTxtBx.lable.text.totalTextHeight + (updTxtBx.lable.text.totalTextHeight * .1)
			updTxtBx.lable.text.vertHalfTextHeight = updTxtBx.lable.text.totalTextHeight / 2

			updTxtBx.lable.text.y = (updTxtBx.lable.frame.y + ( updTxtBx.lable.frame.height / 2 ) - updTxtBx.lable.text.vertHalfTextHeight)
			updTxtBx.userInput.frame.y = updTxtBx.lable.frame.y
			updTxtBx.userInput.frame.x = updTxtBx.frame.x + (updTxtBx.frame.width / 2) + (updTxtBx.lable.frame.y - updTxtBx.frame.y)
			updTxtBx.userInput.frame.width = updTxtBx.lable.frame.width
			updTxtBx.userInput.frame.height = updTxtBx.lable.frame.height

			updTxtBx.userInput.text.x = updTxtBx.userInput.frame.x + (updTxtBx.userInput.frame.width * 0.05)
			updTxtBx.userInput.text.width = updTxtBx.userInput.frame.width - (updTxtBx.userInput.frame.width * 0.1)
			updTxtBx.userInput.text.height = updTxtBx.userInput.frame.height - (updTxtBx.userInput.frame.height * 0.1)
			updTxtBx.userInput.text.maxLineCount = findMaxNumOfLinesNeeded (updTxtBx.textFont, updTxtBx.userInput.text.width, updTxtBx.defaultText)
			updTxtBx.userInput.text.perLineTextHeight = gdsGui_general_returnFontInfo (updTxtBx.textFont, "height")

			--adds all lines height
			updTxtBx.userInput.text.totalTextHeight = (updTxtBx.userInput.text.maxLineCount * updTxtBx.userInput.text.perLineTextHeight)
			updTxtBx.userInput.text.height = updTxtBx.userInput.text.totalTextHeight
			--adjusts for margines spacer:
			updTxtBx.userInput.text.totalTextHeight = updTxtBx.userInput.text.totalTextHeight + (updTxtBx.userInput.text.totalTextHeight * .1)
			updTxtBx.userInput.text.vertHalfTextHeight = updTxtBx.userInput.text.totalTextHeight / 2


			if updTxtBx.themes.sprites ~= nil then
					updTxtBx.themes.sprites.width = updTxtBx.frame.width / updTxtBx.themes.sprites.not_focused_png:getWidth () 
					updTxtBx.themes.sprites.height = updTxtBx.frame.height / updTxtBx.themes.sprites.not_focused_png:getHeight ()
			end

			updTxtBx.myMaxx = updTxtBx.frame.x + updTxtBx.frame.width --[[for button click detection]]
			updTxtBx.myMaxy = updTxtBx.frame.y + updTxtBx.frame.height--[[for button click detection]]

			maxDefaultTextLineCount = findMaxNumOfLinesNeeded (updTxtBx.textFont, updTxtBx.frame.width, updTxtBx.defaultText)
			actualDefaultTextFontHeight = gdsGui_general_returnFontInfo (updTxtBx.textFont, "height")

			--adds all lines height
			totalTextHeight = (actualDefaultTextFontHeight * maxDefaultTextLineCount)
			--adjusts for margines spacer:
			totalTextHeight = totalTextHeight + (totalTextHeight * (updTxtBx.userGuideBox.textMarginSpaces * 2))


			-- gathers text string information, puts the string into a table for iteration
			local width, wrappedtext = updTxtBx.textFont:getWrap( updTxtBx.cursoredCustomText, updTxtBx.userInput.text.width )

			if #wrappedtext > 0 then 
				local newTotalTextHeight = (updTxtBx.userInput.text.perLineTextHeight * (#wrappedtext))
				
				local newMaxAllowedLineCount = math.floor(updTxtBx.userInput.frame.height / updTxtBx.userInput.text.perLineTextHeight)
				if newMaxAllowedLineCount < 1 then
					newMaxAllowedLineCount =1
				end

				local newCursoredDisplayText = ""
				local newUnCursoredDisplayText = ""

				for u, o in ipairs(wrappedtext) do
					if u > (#wrappedtext - newMaxAllowedLineCount) then
						newCursoredDisplayText = newCursoredDisplayText .. o
					end
					if u <= newMaxAllowedLineCount then
						newUnCursoredDisplayText = newUnCursoredDisplayText .. o
					end
				end
				
				--UPDATES NEWLY INPUT TEXT
				updTxtBx.unCoursedCustomText = newUnCursoredDisplayText
				updTxtBx.cursoredCustomText = newCursoredDisplayText
				updTxtBx.userInput.text.y = (updTxtBx.userInput.frame.y + ( updTxtBx.userInput.frame.height / 2 ) - ((newMaxAllowedLineCount * updTxtBx.userInput.text.perLineTextHeight) / 2))
			else
				local newMaxAllowedLineCount = math.floor(updTxtBx.userInput.frame.height / updTxtBx.userInput.text.perLineTextHeight)
				if newMaxAllowedLineCount < 1 then
					newMaxAllowedLineCount =1
				end
				updTxtBx.userInput.text.y = (updTxtBx.userInput.frame.y + ( updTxtBx.userInput.frame.height / 2 ) - ((newMaxAllowedLineCount * updTxtBx.userInput.text.perLineTextHeight) / 2))

			end

			updTxtBx.userGuideBox.frame.width = updTxtBx.frame.width
			updTxtBx.userGuideBox.frame.height =  totalTextHeight
			updTxtBx.userGuideBox.frame.x = updTxtBx.frame.x
			updTxtBx.userGuideBox.frame.y = updTxtBx.frame.y - updTxtBx.userGuideBox.frame.height

			updTxtBx.userGuideBox.text.x = updTxtBx.userGuideBox.frame.x + (updTxtBx.userGuideBox.frame.width * updTxtBx.userGuideBox.textMarginSpaces)
			updTxtBx.userGuideBox.text.y = updTxtBx.userGuideBox.frame.y + (updTxtBx.userGuideBox.frame.height * updTxtBx.userGuideBox.textMarginSpaces)
			updTxtBx.userGuideBox.text.width = updTxtBx.userGuideBox.frame.width - (updTxtBx.userGuideBox.frame.width * (updTxtBx.userGuideBox.textMarginSpaces * 2))
			updTxtBx.userGuideBox.text.height = updTxtBx.userGuideBox.frame.height - (updTxtBx.userGuideBox.frame.height * (updTxtBx.userGuideBox.textMarginSpaces * 2))

		end

	end

end

function gdsGui_inputTxtBox_delete (txtBxId,page)

	for i = #textBoxes,1,-1 do

		local b = textBoxes[i]

		if b.id == txtBxId and b.page == page then

			table.remove(textBoxes,i)

			globApp.numObjectsDisplayed = globApp.numObjectsDisplayed - 1

		end

	end

end

function gdsGui_inputTxtBox_draw (txtBxId, page, tblTextSpecs, theme_focus, theme_NOTfocus,theme_deactivated,strgtxtBoxCursor,isRequired, myx, myy, anchorPoint, myWidth, myHeight, strgCallbackFunc, tabNum, fontSize, customText)

	local activePageName = 0

	for i, pgs in ipairs (pages) do

		if pgs.index == globApp.currentPageIndex then

			activePageName = pgs.name

		end
	end

	local txtBxExists = false

	for i,x in ipairs(textBoxes) do
		
		if x.id == txtBxId then

			txtBxExists = true
	
		end

	end

	if activePageName == page then

		if txtBxExists == false then

			gdsGui_inputTxtBox_create (txtBxId, page, tblTextSpecs, theme_focus, theme_NOTfocus,theme_deactivated,strgtxtBoxCursor,isRequired, myx, myy, anchorPoint, myWidth, myHeight, strgCallbackFunc, tabNum, fontSize, customText)

			gdsGui_inputTxtBox_deactivate ()

		elseif txtBxExists == true  and globApp.resizeDetected == true then --[[updates only if window is resized]]

			gdsGui_inputTxtBox_update(txtBxId, anchorPoint, myx, myy, myWidth, myHeight,fontSize)

		end

		for i,x in ipairs(textBoxes) do
			
			if x.id == txtBxId and x.state == 0  then --[[When textbox is deactivated draw the following:]]

				if x.themes.type == "colors" then

					--DRAW RECTANGULAR FILL BACKGROUND:
					love.graphics.setColor(x.themes.colors.deactivated.fill[1], x.themes.colors.deactivated.fill[2], x.themes.colors.deactivated.fill[3], x.themes.colors.deactivated.fill[4])
					love.graphics.rectangle("fill", x.frame.x, x.frame.y, x.frame.width, x.frame.height, rx, ry, segments)
					--DRAW FRAMW LINE RECTANGLE:
					love.graphics.setColor(x.themes.colors.deactivated.frame[1], x.themes.colors.deactivated.frame[2], x.themes.colors.deactivated.frame[3], x.themes.colors.deactivated.frame[4])
					love.graphics.rectangle("line", x.frame.x, x.frame.y, x.frame.width, x.frame.height, rx, ry, segments)
					--DRAW INPUT BOX FILL SQUARE:
					love.graphics.setColor(x.themes.colors.deactivated.inputBox[1], x.themes.colors.deactivated.inputBox[2], x.themes.colors.deactivated.inputBox[3], x.themes.colors.deactivated.inputBox[4])
					love.graphics.rectangle("fill", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)
					--DRAW INPUT BOX FRAME SQUARE:
					love.graphics.setColor(x.themes.colors.deactivated.frame[1], x.themes.colors.deactivated.frame[2], x.themes.colors.deactivated.frame[3], x.themes.colors.deactivated.frame[4])
					love.graphics.rectangle("line", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)

					--PRINT LABEL AND USER INPUT TEXT:
					love.graphics.setFont(x.textFont)
					love.graphics.setColor(x.themes.colors.deactivated.text[1], x.themes.colors.deactivated.text[2], x.themes.colors.deactivated.text[3], x.themes.colors.deactivated.text[4])
					love.graphics.printf(x.customText, x.userInput.text.x, x.userInput.text.y, x.userInput.text.width, "center", r, sx, sy, ox, oy, kx, ky)
					love.graphics.printf(x.lable.text.text, x.lable.text.x, x.lable.text.y, x.lable.text.width,"center", 0)

				elseif x.themes.type == "sprites" then

					--DRAW SPRITE BACKGROUND:
					love.graphics.draw(x.themes.sprites.deactivated_png, x.frame.x, x.frame.y, 0, x.themes.sprites.width, x.themes.sprites.height, ox, oy, kx, ky) 
					--DRAW INPUT BOX FILL SQUARE:
					love.graphics.setColor(1,1,1,1)
					love.graphics.rectangle("fill", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)

					--PRINT LABEL AND USER INPUT TEXT:
					love.graphics.setFont(x.textFont)
					love.graphics.setColor(0,0,0,1)
					love.graphics.printf(x.customText, x.userInput.text.x, x.userInput.text.y, x.userInput.text.width, "center", r, sx, sy, ox, oy, kx, ky)
					love.graphics.printf(x.lable.text.text, x.lable.text.x, x.lable.text.y, x.lable.text.width,"center", 0)

				end
				
				love.graphics.reset()


			elseif x.id == txtBxId and x.state == 1  then --[[When textbox is not focused draw then following:]]

				if x.themes.type == "colors" then

					--DRAW RECTANGULAR FILL BACKGROUND:
					love.graphics.setColor(x.themes.colors.NOTfocus.fill[1], x.themes.colors.NOTfocus.fill[2], x.themes.colors.NOTfocus.fill[3], x.themes.colors.NOTfocus.fill[4])
					love.graphics.rectangle("fill", x.frame.x, x.frame.y, x.frame.width, x.frame.height, rx, ry, segments)
					--DRAW FRAMW LINE RECTANGLE:
					love.graphics.setColor(x.themes.colors.NOTfocus.frame[1], x.themes.colors.NOTfocus.frame[2], x.themes.colors.NOTfocus.frame[3], x.themes.colors.NOTfocus.frame[4])
					love.graphics.rectangle("line", x.frame.x, x.frame.y, x.frame.width, x.frame.height, rx, ry, segments)
					--DRAW INPUT BOX FILL SQUARE:
					love.graphics.setColor(x.themes.colors.NOTfocus.inputBox[1], x.themes.colors.NOTfocus.inputBox[2], x.themes.colors.NOTfocus.inputBox[3], x.themes.colors.NOTfocus.inputBox[4])
					love.graphics.rectangle("fill", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)
					--DRAW INPUT BOX FRAME SQUARE:
					love.graphics.setColor(x.themes.colors.NOTfocus.frame[1], x.themes.colors.NOTfocus.frame[2], x.themes.colors.NOTfocus.frame[3], x.themes.colors.NOTfocus.frame[4])
					love.graphics.rectangle("line", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)
					--PRINT LABEL AND USER INPUT TEXT:
					love.graphics.setFont(x.textFont)
					love.graphics.setColor(x.themes.colors.NOTfocus.text[1], x.themes.colors.NOTfocus.text[2], x.themes.colors.NOTfocus.text[3], x.themes.colors.NOTfocus.text[4])
					love.graphics.printf(x.unCoursedCustomText, x.userInput.text.x, x.userInput.text.y, x.userInput.text.width, "center", r, sx, sy, ox, oy, kx, ky)
					love.graphics.printf(x.lable.text.text, x.lable.text.x, x.lable.text.y, x.lable.text.width,"center", 0)

				elseif x.themes.type == "sprites" then

					--DRAW SPRITE BACKGROUND:
					love.graphics.draw(x.themes.sprites.not_focused_png, x.frame.x, x.frame.y, 0, x.themes.sprites.width, x.themes.sprites.height, ox, oy, kx, ky) 
					--DRAW INPUT BOX FILL SQUARE:
					love.graphics.setColor(1,1,1,1)
					love.graphics.rectangle("fill", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)

					--PRINT LABEL AND USER INPUT TEXT:
					love.graphics.setFont(x.textFont)
					love.graphics.setColor(0,0,0,1)
					love.graphics.printf(x.unCoursedCustomText, x.userInput.text.x, x.userInput.text.y, x.userInput.text.width, "center", r, sx, sy, ox, oy, kx, ky)
					love.graphics.printf(x.lable.text.text, x.lable.text.x, x.lable.text.y, x.lable.text.width,"center", 0)

				end
				
				love.graphics.reset()

			elseif x.id == txtBxId and x.state == 2  then --[[when textbox is focused draw the following:]]
				if x.themes.type == "colors" then

					--DRAW RECTANGULAR FILL BACKGROUND:
					love.graphics.setColor(x.themes.colors.focus.fill[1], x.themes.colors.focus.fill[2], x.themes.colors.focus.fill[3], x.themes.colors.focus.fill[4])
					love.graphics.rectangle("fill", x.frame.x, x.frame.y, x.frame.width, x.frame.height, rx, ry, segments)
					--DRAW FRAMW LINE RECTANGLE:
					love.graphics.setColor(x.themes.colors.focus.frame[1], x.themes.colors.focus.frame[2], x.themes.colors.focus.frame[3], x.themes.colors.focus.frame[4])
					love.graphics.rectangle("line", x.frame.x, x.frame.y, x.frame.width, x.frame.height, rx, ry, segments)
					--DRAW INPUT BOX FILL SQUARE:
					love.graphics.setColor(x.themes.colors.focus.inputBox[1], x.themes.colors.focus.inputBox[2], x.themes.colors.focus.inputBox[3], x.themes.colors.focus.inputBox[4])
					love.graphics.rectangle("fill", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)
					--DRAW INPUT BOX FRAME SQUARE:
					love.graphics.setColor(x.themes.colors.focus.frame[1], x.themes.colors.focus.frame[2], x.themes.colors.focus.frame[3], x.themes.colors.focus.frame[4])
					love.graphics.rectangle("line", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)
					--PRINT LABEL AND USER INPUT TEXT:
					love.graphics.setFont(x.textFont)
					love.graphics.setColor(x.themes.colors.focus.text[1], x.themes.colors.focus.text[2], x.themes.colors.focus.text[3], x.themes.colors.focus.text[4])
					love.graphics.printf(x.cursoredCustomText, x.userInput.text.x, x.userInput.text.y, x.userInput.text.width, "left", r, sx, sy, ox, oy, kx, ky)
					love.graphics.printf(x.lable.text.text, x.lable.text.x, x.lable.text.y, x.lable.text.width,"center", 0)

				elseif x.themes.type == "sprites" then

					--DRAW SPRITE BACKGROUND:
					love.graphics.draw(x.themes.sprites.focus_png, x.frame.x, x.frame.y, 0, x.themes.sprites.width, x.themes.sprites.height, ox, oy, kx, ky) 
					--DRAW INPUT BOX FILL SQUARE:
					love.graphics.setColor(1,1,1,1)
					love.graphics.rectangle("fill", x.userInput.frame.x, x.userInput.frame.y, x.userInput.frame.width, x.userInput.frame.height, rx, ry, segments)
					love.graphics.reset()
					--PRINT LABEL AND USER INPUT TEXT:
					love.graphics.setFont(x.textFont)
					love.graphics.setColor(0,0,0,1)
					love.graphics.printf(x.cursoredCustomText, x.userInput.text.x, x.userInput.text.y, x.userInput.text.width, "left", r, sx, sy, ox, oy, kx, ky)
					love.graphics.printf(x.lable.text.text, x.lable.text.x, x.lable.text.y, x.lable.text.width,"center", 0)

				end
				
				love.graphics.reset()
			end

	    end

	elseif activePageName ~= page  then
 
	 	if txtBxExists == true then
			
			gdsGui_inputTxtBox_delete (txtBxId, page)

		end
	
	end
	
end


function gdsGui_inputTxtBox_deactivate ()
	
	--[[future code]]

end


function gdsGui_inputTxtBox_pressed (x,y,button,istouch)
	--[[Focuses a textbox when it is pressed and unfocuses the txbx when click elsewhere]]

	local activePageName = gdsGui_page_currentName ()
	local currentTxtBxTable = textBoxes

	--focus txtBox CODE

	for h=1, 2, 1 do --runs the code twice to set all boxes as deactivated before activating one
	
		for i,p in ipairs(currentTxtBxTable) do

			local selectedButtonId = p.id

				if h == 1 then -- deactivates all boxes
					if (button == 1 or globApp.userInput == "tap") and (x < p.frame.x or x > p.myMaxx or y < p.frame.y or y > p.myMaxy) then
						
						if p.state == 2 then
							p.state = 1 --disables the input box
							if p.customText == "" then 
								p.unCoursedCustomText = p.initialInstructionText 
								p.cursoredCustomText = p.initialInstructionText
						
							end
							
							if p.callbackFunc ~= nil then -- runs input textbox callback when deactivating
								local t = {}
									t["id"] = p.id
									t["state"] = p.state
									t["text"] = p.customText
									if p.initialInstructionText == p.customText then
										t["isDefaultText"] = true
									else 
										t["isDefaultText"] = false
									end
									if p.customText == "" then
										t["isEmpty"] = true
									else
										t["isEmpty"] = false
									end
								

								getfenv()[p.callbackFunc](t)
							else
								gdsGui_generateConsoleMessage ("error", "no callback has been assigned to this txtBox")
							end

							gdsGui_inputTxtBox_toggleKeyboard(false, p.frame.x, p.frame.y, p.myMaxx - p.frame.x , p.myMaxy - p.frame.y) -- desables keyboard

							love.keyboard.setKeyRepeat(false)--quick erasing no longer needed
						end

					end

				end

				if h == 2 then -- activates selected box

					if (button == 1 or globApp.userInput == "tap") and x >= p.frame.x and x <= p.myMaxx and y >= p.frame.y and y <= p.myMaxy then

						if p.state == 1 then

							p.state = 2
							
							love.keyboard.setKeyRepeat(true)--needed for quick erasing

							gdsGui_inputTxtBox_toggleKeyboard(true, p.frame.x, p.frame.y, p.myMaxx - p.frame.x , p.myMaxy - p.frame.y) --enables keyboard
							if p.customText == p.initialInstructionText or p.customText == "" then -- erases input field
								p.customText = ""
								p.unCoursedCustomText = "" --resets custom text to 
								p.cursoredCustomText = p.cursor
							end
							
							if p.callbackFunc ~= nil then
								local t = {}
									t["id"] = p.id
									t["state"] = p.state
									t["text"] = p.customText
									if p.initialInstructionText == p.customText then
										t["isDefaultText"] = true
									else 
										t["isDefaultText"] = false
									end
									if p.customText == "" then
										t["isEmpty"] = true
									else
										t["isEmpty"] = false
									end
								
								getfenv()[p.callbackFunc](t)
							else
								print ("no callback has been assigned to this txtBox")
							end
						
						end

					end

				end

			end

		end

end


function gdsGui_inputTxtBox_toggleKeyboard(boolEnable, myX, myY, myWidth, myHeight)
	--This displays the native or dissables textInput events
	--on touchscreen devices: IOS and Android it also displays the on screen keyboard
	love.keyboard.setTextInput(boolEnable,myX, myY, myWidth, myHeight)

end


function gdsGui_inputTxtBox_textUpdate (mode,t, key)

		for i, w in ipairs (textBoxes) do
			print (w.id)
			if w.state == 2 then

				local newText = ""

				local isFirstCharEmpty = false
				s = w.customText
				x = string.sub(s,1,1)
				if x == "" and t == " " then
					isFirstCharEmpty = true
				end

				if mode == "add" then
					if isFirstCharEmpty == false then
						if gdsGui_inputTxtBox_isCharInvalid (t, w.textSpecs, string.len(w.customText), w.collectedData) == false and string.len(w.customText) <= (w.maxChrNum - 1)  then
							w.customText = w.customText .. t 
							w.collectedData = w.customText
							w.unCoursedCustomText = w.collectedData
							w.cursoredCustomText = w.unCoursedCustomText .. w.cursor
							newText = w.cursoredCustomText
						else 

							erroMessage = ("( " .. t .. " ) is not allowed!")

							gdsGui_generateConsoleMessage ("error", erroMessage)
							w.customText = w.customText
							w.collectedData = w.customText
							w.unCoursedCustomText = w.collectedData
							w.cursoredCustomText = w.unCoursedCustomText .. w.cursor
							newText = w.cursoredCustomText
						end

					end

				elseif mode == "remove" and (key == "backspace" or key == "delete") then

					local utf8 = require("utf8")

				    if key == "backspace" then
				        -- get the byte offset to the last UTF-8 character in the string.
				        local byteoffset = utf8.offset(w.customText, -1)
				 
				        if byteoffset then
				            --[[remove the last UTF-8 character.string.sub operates on bytes rather than UTF-8 characters, so we couldn't do string.sub(customText, 1, -2).]]
				            w.customText = string.sub(w.customText, 1, byteoffset - 1)
				            w.collectedData = w.customText
				            w.unCoursedCustomText = w.collectedData
				            w.cursoredCustomText = w.unCoursedCustomText .. w.cursor
				            newText = w.cursoredCustomText
				        end

				    end

				    if key == "delete" then

				    	w.customText = ""
				    	w.collectedData = ""
				    	w.unCoursedCustomText = ""
				    	w.cursoredCustomText = w.cursor
				    	newText = w.cursoredCustomText

				    end

				end
				-- gathers text string information, puts the string into a table for iteration
				local width, wrappedtext = w.textFont:getWrap( newText, w.userInput.text.width )
				
				w.userInput.text.lines = wrappedtext

				if #w.userInput.text.lines > 0 then 
					local newTotalTextHeight = (w.userInput.text.perLineTextHeight * (#wrappedtext))
					
					local newMaxAllowedLineCount = math.floor(w.userInput.frame.height / w.userInput.text.perLineTextHeight)

					local newCursoredDisplayText = ""
					local newUnCursoredDisplayText = ""

					for u, o in ipairs(w.userInput.text.lines) do
						if u > (#w.userInput.text.lines - newMaxAllowedLineCount) then
							newCursoredDisplayText = newCursoredDisplayText .. o
						end
						if u <= newMaxAllowedLineCount then
							newUnCursoredDisplayText = newUnCursoredDisplayText .. o
							newUnCursoredDisplayText=string.sub(newUnCursoredDisplayText, 1, -2)
						end
					end
					
					--UPDATES NEWLY INPUT TEXT
					w.cursoredCustomText = newCursoredDisplayText
					w.unCoursedCustomText = newUnCursoredDisplayText
					w.userInput.text.y = (w.userInput.frame.y + ( w.userInput.frame.height / 2 ) - ((newMaxAllowedLineCount * w.userInput.text.perLineTextHeight) / 2))
				end
				
			end

		end
end


function gdsGui_inputTxtBox_tabToSwitch (key)
	--[[cycles through tab numbers activating the next textbox when tab button is pressed.
	MUST: receive key parameters from key.pressed function from main.lua]]

	local totalTabsOnPage = 0

	local activePageName = gdsGui_page_currentName ()

	for i,x in ipairs(textBoxes) do --[[checks number of txtBxs on current page]]

		if activePageName == x.page then

			totalTabsOnPage = totalTabsOnPage + 1 

		end

	end

	local currentTab = 0

	local nextTabNum = 0

	for i, n in ipairs(textBoxes) do --[[defocuses the the current textbox]]

		if key == "tab" then --[[runs only when tab is pressed]]

			if n.state == 2 then

				currentTab = n.tabNum --[[determines what is the current tab number based on table]]

				n.state = 1 --[[defocuses the current focused textbox]]

				if n.customText == "" then --[[checks if text was inputed prior to deactivation]]

					n.customText = n.initialInstructionText
					n.unCoursedCustomText = n.initialInstructionText
					n.cursoredCustomText = n.initialInstructionText

				end

				if (currentTab + 1) <= totalTabsOnPage then --[[increases currentTab var only if it will not exceed total number of txtboxes on page when added 1]]

					nextTabNum = currentTab + 1 

				elseif (currentTab + 1) > totalTabsOnPage then --[[resets currentTab to 1 if max tab num will be exceeded]]

					nextTabNum = 1

				end 

			end

		end 

		if key == "return" or key == "enter" then --[[defocuses active current textbox ]]

			if n.state == 2 then

				n.state = 1 --[[defocuses the current focused textbox]]

				gdsGui_inputTxtBox_toggleKeyboard(false, n.frame.x, n.frame.y, n.myMaxx -n.frame.x , n.myMaxy - n.frame.y)

				if n.customText == "" then --[[checks if text was inputed prior to deactivation]]

					n.customText = n.initialInstructionText --[[inserts default text into textbox]]
					n.unCoursedCustomText = n.initialInstructionText --resets custom text to 
					n.cursoredCustomText = n.initialInstructionText

				end

			end

		end

	end

	for i, y in ipairs(textBoxes) do --[[focuses the next textbox based on tabNumbe and clears default text from new active text]]

		if y.tabNum == nextTabNum then
			
			y.state = 2

			if y.customText == y.initialInstructionText then

				y.customText = ""
				y.unCoursedCustomText = "" --resets custom text to 
				y.cursoredCustomText = y.cursor

			end

		end 

	end

end

function gdsGui_inputTxtBox_areRequiredEmpty ()

	local result = true
	local count_reqTxtBox = 0
	local data = {}
	local currentPageName = gdsGui_page_currentName ()

	--CHECK IF THERE ARE INPUT TEXTBOXES IN THE CURRENT PAGE:
	for i, txBoxes in ipairs (textBoxes) do 
		if i >= 1 then
			pgHasTxtBoxes = true
		end
	end

	if pgHasTxtBoxes == true then 
		for i, txt in ipairs(textBoxes) do
			if txt.page == currentPageName then
				if txt.isRequired == true then
					count_reqTxtBox = count_reqTxtBox + 1
					data[count_reqTxtBox] = txt.collectedData
				end 
			end
		end

		local count_nonEmptyData = 0
		for f = #data, 1, -1 do
			if data[f] ~= "" then
				count_nonEmptyData = count_nonEmptyData + 1
			end
		end

		if count_nonEmptyData == count_reqTxtBox then
			result = false
		else
			result = true
		end
		return result
	end

end


function gdsGui_inputTxtBox_hasEndingBlank ()

	local result = true
	local data = {}
	local currentPageName = gdsGui_page_currentName ()

	--CHECK IF THERE ARE INPUT TEXTBOXES IN THE CURRENT PAGE:
	for i, txBoxes in ipairs (textBoxes) do 
		if i >= 1 then
			pgHasTxtBoxes = true
		end
	end

	if pgHasTxtBoxes == true then 

		local count_boxesWithBlankEmptySpace = 0

		for i, txt in ipairs(textBoxes) do
			if txt.page == currentPageName then
				thisText = txt.collectedData

				local str = thisText
				local lastNonBlankSpace = 0
				local lastBlankSpace = 0

				for i = 1, #str do
				   	local c = str:sub(i,i)
			   		if c ~= " " then
				   		lastNonBlankSpace = i
				   	elseif c == " " then
					   lastBlankSpace = i
					end
				end
				
				if lastNonBlankSpace < lastBlankSpace then
					count_boxesWithBlankEmptySpace = count_boxesWithBlankEmptySpace + 1
				end
			end
		end
		-- print (count_boxesWithBlankEmptySpace)
		if count_boxesWithBlankEmptySpace == 0 then
			result = false
		end
	end

	return result

end


function gdsGui_inputTxtBox_extractData (boxId)
	
	local pgHasTxtBoxes = false
	local currentPageName = gdsGui_page_currentName ()

	--CHECK IF THERE ARE INPUT TEXTBOXES IN THE CURRENT PAGE:
	for i, txBoxes in ipairs (textBoxes) do 
		if i >= 1 then
			pgHasTxtBoxes = true
		end
	end

	if pgHasTxtBoxes == true then 
		for i, box in ipairs (textBoxes) do
			if box.id == boxId then
				local returnData = box.collectedData
				return returnData
			end
		end
	end
end


function gdsGui_inputTxtBox_changeTrigger ()

	local pgHasTxtBoxes = false
	local textBoxChanged = false
	local currentPageName = gdsGui_page_currentName ()

	--CHECK IF THERE ARE INPUT TEXTBOXES IN THE CURRENT PAGE:
	for i, txBoxes in ipairs (textBoxes) do 
		if i >= 1 then
			pgHasTxtBoxes = true
		end
	end

	if pgHasTxtBoxes == true then 

		local initValues = {}
		local latestValues = {}

		--COLLECT INITIAL TEXTBOX CONTENTS EITHER FROM GLOB VAR OR BY LOOPING PAGE TEXTBOXES
		if CurrentPageTxtBoxValues ~= nil and #CurrentPageTxtBoxValues == #textBoxes then
			initValues = CurrentPageTxtBoxValues
		else
			for i, txt in ipairs(textBoxes) do
				if txt.page == currentPageName then
					initValues[i] = txt.collectedData
				end
			end
		end

		--COLLECTS TEXTBOX A SECOND TIME FOR COMPAIRASON
		for i, txt in ipairs(textBoxes) do
			if txt.page == currentPageName then
				latestValues[i] = txt.collectedData
			end
		end

		if latestValues ~= nil or initValues ~= nil then
			if #latestValues == #initValues then
				for i=1, #latestValues,1 do
					if latestValues[i] ~= initValues[i] then
						textBoxChanged = true
					end
				end
			end
		end

		CurrentPageTxtBoxValues = latestValues

		return textBoxChanged
	end
end


function gdsGui_inputTxtBox_createPattern (maxCharCount, pattern)

	local result = ""

	result = pattern
	-- local s = "KGUUI, KSUS K1FU; and KOORL"
	-- print(string.gmatch(s, "%w%w%w%w"))
	-- --> word, word word; word word


	local str = "KGUUI, KSUS K44U; and KOORL"
	local str2 = "01/30/2021"

	-- This one only gives you the substring;
	-- it doesn't tell you where it starts or ends
	for substring in str:gmatch '%w%w%w%w%s%w[1-4]%w%w' do
	   print(substring)
	end
	for substring in str2:gmatch '[0-1][0-9]/[0-3][0-9]/[1-2][0-2][0-9][0-9]' do
	   print(substring)
	end



	return result

end


function gdsGui_inputTxtBox_isCharInvalid (newCharacter, tblTextSpecs, currentChrCount, currentText)

	local pattern = tblTextSpecs["pattern"]
	local cpyOrigPattern = pattern

	local invalidChar = false

	local curText = ""

	if currentText ~= "" and currentText ~= nil and type(currentText) ~= "boolean" then
		curText = currentText
	end

	local currentCharCount = string.len(curText)
	local hypttclText = curText .. newCharacter

	local hypttclTextCharCount = string.len(hypttclText)

	if currentChrCount >= tblTextSpecs["maxCharCount"] then
		invalidChar = true
	end

	if tblTextSpecs["invalCharacters"] ~= nil then
		for b, ic in pairs (tblTextSpecs["invalCharacters"]) do
			if newCharacter == ic then
				invalidChar = true
			end
		end
	end 


	local testPatterSimbolsIdex = {}

	for d=1, 3, 1 do 

		for x=1, string.len(pattern), 1 do
			if string.sub(pattern, x, x) == "%" then
				testPatterSimbolsIdex[x] = "simbol"
			else 
				testPatterSimbolsIdex[x] = "string"
			end
		end

		if d == 1 then
			stringCounter = 0
			for p, c in ipairs (testPatterSimbolsIdex)do
				if c == "string" then
					stringCounter = stringCounter + 1
				end
			end
		end

		if d == 2 then
			local reps = math.floor((tblTextSpecs["maxCharCount"] / stringCounter) + 0.5 )
			-- print (reps)
			if stringCounter > 1 then
				if reps > 1 then
					for x=1, reps, 1 do
						pattern = pattern .."%s" ..cpyOrigPattern
					end
				end
			end
		end
	end

	local remainChars = hypttclTextCharCount
	local iteratorCounter = 0
	
	for x, h in pairs (testPatterSimbolsIdex) do
		simbReset = false
		if remainChars > 0 then
			if h == "simbol" then
				iteratorCounter = iteratorCounter + 1
			elseif h == "string" then
				remainChars = remainChars - 1
				iteratorCounter = iteratorCounter + 1
			end
		end
	end

	local howShouldStringLookByNow = string.sub(pattern, 1, iteratorCounter)
	if string.find(hypttclText, howShouldStringLookByNow) ~= nil then 
		-- print ("yes, text is valid, " .. hypttclText)
	else
		-- print ("incorrect character, try other")
		invalidChar = true
	end
	return invalidChar
end 