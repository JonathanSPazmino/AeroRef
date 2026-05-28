-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--scrollBar.lua

local librarySpritesPath = "Libraries/gds_love2d_gui/librarySprites/"

-- Pre-allocated colour tables to avoid creating a new table every draw call.
local _COLOR_BAR_FOCUSED   = {0, 0, 1, 1}
local _COLOR_BAR_UNFOCUSED = {0, 1, 0, 1}

-- scrollbars = {}
globApp.objects.scrollBars = {}

function gdsGui_scrollBar_create (id, strgPage, x, y, width, height, anchorPoint, visibleValues, totalValues, dataRelativePosition, sbType, sbOrientation, scrollSpeed, callback, assets, hapticEnabled, containerName)

	local t = {}
		t.assets = assets or {}

		-- Apply library sprite defaults for any nil sprite paths
		t.assets.up_active     = t.assets.up_active     or (librarySpritesPath .. "gdsLoveGUI_UpArrowButton_pushed.png")
		t.assets.up_inactive   = t.assets.up_inactive   or (librarySpritesPath .. "gdsLoveGUI_UpArrowButton_released.png")
		t.assets.down_active   = t.assets.down_active   or (librarySpritesPath .. "gdsLoveGUI_downArrowButton_pushed.png")
		t.assets.down_inactive = t.assets.down_inactive or (librarySpritesPath .. "gdsLoveGUI_downArrowButton_released.png")
		t.assets.left_active   = t.assets.left_active   or (librarySpritesPath .. "gdsLoveGUI_leftArrowButton_pushed.png")
		t.assets.left_inactive = t.assets.left_inactive or (librarySpritesPath .. "gdsLoveGUI_leftArrowButton_released.png")
		t.assets.right_active  = t.assets.right_active  or (librarySpritesPath .. "gdsLoveGUI_rightArrowButton_pushed.png")
		t.assets.right_inactive= t.assets.right_inactive or (librarySpritesPath .. "gdsLoveGUI_rightArrowButton_released.png")

		t.id = id
		t.type = sbType --[[independent or table-linked]]
		t.objectType = "scrollBar"
		t.orientation = sbOrientation
		t.state = 1
		t.scrollSpeedFactor = scrollSpeed
		t.page = strgPage
		t.isFocused = false
		t.numVisValues = visibleValues
		t.numTotalValues = totalValues
		t.callbackString = callback
		t.callbackFn     = callback and _G[callback] or nil  -- resolved once; avoids _G lookup per event
		t.hapticEnabled = (hapticEnabled == true)
		t._prevSnapIndex = -1
		t._hapticFiredOnFocus = false
		t.focusTouchId = nil

		t.original = {
			x = x,
			y = y,
			width = width,
			height = height,
			anchorPoint = anchorPoint
		}

		
		t.frame = {}
		if t.assets.frame then
			t.frame.img = love.graphics.newImage(t.assets.frame)
			t._dimFrameW, t._dimFrameH = t.frame.img:getDimensions()
		end
		if sbOrientation == "vertical" then
			t.frame.height = height
			t.frame.width = width
		elseif sbOrientation == "horizontal" then
			t.frame.height = height
			t.frame.width = width
		end

			t.frame.positions =
					gdsGui_general_relativePosition (anchorPoint,
										x,
										y,
										t.frame.width,
										t.frame.height,
										globApp.safeScreenArea.x,
										globApp.safeScreenArea.y,
										globApp.safeScreenArea.w,
										globApp.safeScreenArea.h)
			t.frame.x = t.frame.positions[1] - globApp.safeScreenArea.x
			t.frame.y = t.frame.positions[2] - globApp.safeScreenArea.y
	
		if globApp.OperatingSystem == "iOS" or globApp.OperatingSystem == "Android" then
			t.frame.y = t.frame.y + globApp.safeScreenArea.y
		end
	
		if globApp.OperatingSystem ~= "iOS" and globApp.OperatingSystem ~= "Android" then
			if t.orientation == "vertical" then

				t.imgButtonUpArrow_active     = love.graphics.newImage(t.assets.up_active)
				t.imgButtonUpArrow_inactive   = love.graphics.newImage(t.assets.up_inactive)
				t.imgButtonDownArrow_active   = love.graphics.newImage(t.assets.down_active)
				t.imgButtonDownArrow_inactive = love.graphics.newImage(t.assets.down_inactive)

				-- Cache pixel dimensions so draw never calls getDimensions() per frame.
				t._dimUpW,   t._dimUpH   = t.imgButtonUpArrow_inactive:getDimensions()
				t._dimDownW, t._dimDownH = t.imgButtonDownArrow_inactive:getDimensions()

				t.upButton = {}
					t.upButton.width = t.frame.width
					t.upButton.height = t.frame.width
					t.upButton.x = t.frame.x
					t.upButton.y = t.frame.y
					t.upButton.factorWidth = t.upButton.width / t.imgButtonUpArrow_active:getWidth ()
					t.upButton.factorHeight = t.upButton.height / t.imgButtonUpArrow_active:getHeight ()
					t.upButton.isActive = false
				t.upButton.centeredX = t.upButton.x + (t.upButton.width  - t._dimUpW   * t.upButton.factorWidth)  / 2
				t.upButton.centeredY = t.upButton.y + (t.upButton.height - t._dimUpH   * t.upButton.factorHeight) / 2

				t.downButton = {}
					t.downButton.width = t.frame.width
					t.downButton.height = t.frame.width
					t.downButton.x = t.frame.x
					t.downButton.y = t.frame.y + t.frame.height - t.downButton.height
					t.downButton.factorWidth = t.downButton.width / t.imgButtonDownArrow_active:getWidth ()
					t.downButton.factorHeight = t.downButton.height / t.imgButtonDownArrow_active:getHeight ()
					t.downButton.isActive = false
				t.downButton.centeredX = t.downButton.x + (t.downButton.width  - t._dimDownW * t.downButton.factorWidth)  / 2
				t.downButton.centeredY = t.downButton.y + (t.downButton.height - t._dimDownH * t.downButton.factorHeight) / 2

				t.frame.y = t.upButton.y + t.upButton.height
					t.frame.height = t.downButton.y - t.frame.y

			elseif t.orientation == "horizontal" then

				t.imgButtonLeftArrow_active    = love.graphics.newImage(t.assets.left_active)
				t.imgButtonLeftArrow_inactive  = love.graphics.newImage(t.assets.left_inactive)
				t.imgButtonRightArrow_active   = love.graphics.newImage(t.assets.right_active)
				t.imgButtonRightArrow_inactive = love.graphics.newImage(t.assets.right_inactive)

				-- Cache pixel dimensions so draw never calls getDimensions() per frame.
				t._dimLeftW,  t._dimLeftH  = t.imgButtonLeftArrow_inactive:getDimensions()
				t._dimRightW, t._dimRightH = t.imgButtonRightArrow_inactive:getDimensions()

				t.leftButton = {}
					t.leftButton.width = t.frame.height
					t.leftButton.height = t.frame.height
					t.leftButton.x = t.frame.x
					t.leftButton.y = t.frame.y
					t.leftButton.factorWidth = t.leftButton.width / t.imgButtonLeftArrow_active:getWidth ()
					t.leftButton.factorHeight = t.leftButton.height / t.imgButtonLeftArrow_active:getHeight ()
					t.leftButton.isActive = false
				t.leftButton.centeredX = t.leftButton.x + (t.leftButton.width  - t._dimLeftW  * t.leftButton.factorWidth)  / 2
				t.leftButton.centeredY = t.leftButton.y + (t.leftButton.height - t._dimLeftH  * t.leftButton.factorHeight) / 2

				t.rightButton = {}
					t.rightButton.width = t.frame.height
					t.rightButton.height = t.frame.height
					t.rightButton.x = t.frame.x + t.frame.width - t.rightButton.width
					t.rightButton.y = t.frame.y
					t.rightButton.factorWidth = t.rightButton.width / t.imgButtonRightArrow_active:getWidth ()
					t.rightButton.factorHeight = t.rightButton.height / t.imgButtonRightArrow_active:getHeight ()
					t.rightButton.isActive = false
				t.rightButton.centeredX = t.rightButton.x + (t.rightButton.width  - t._dimRightW * t.rightButton.factorWidth)  / 2
				t.rightButton.centeredY = t.rightButton.y + (t.rightButton.height - t._dimRightH * t.rightButton.factorHeight) / 2

					t.frame.x = t.leftButton.x + t.leftButton.width
				t.frame.width = t.rightButton.x - t.frame.x

			end
		end

		-- Pre-compute frame draw scale (updated in resize() after each geometry change).
		-- Horizontal scrollbars reuse vertical sprites rotated 90° CW: swap the scale axes
		-- and store the rotation + pivot so draw calls don't need to branch on orientation.
		if t.frame.img then
			if t.orientation == "horizontal" then
				-- CCW 90° (-π/2): source top-right lands at (frame.x, frame.y); sprite fills
				-- [frame.x, frame.x+frame.width] × [frame.y, frame.y+frame.height] correctly.
				t.frame.rotation = -math.pi / 2
				t.frame.originX  = t._dimFrameW
				t.frame.scaleX   = t.frame.height / t._dimFrameW
				t.frame.scaleY   = t.frame.width  / t._dimFrameH
			else
				t.frame.rotation = 0
				t.frame.originX  = 0
				t.frame.scaleX   = t.frame.width  / t._dimFrameW
				t.frame.scaleY   = t.frame.height / t._dimFrameH
			end
		end

		t.bar = {}
		if t.assets.thumb then
			t.bar.img = love.graphics.newImage(t.assets.thumb)
			t._dimBarW, t._dimBarH = t.bar.img:getDimensions()
		end
			t.bar.position = dataRelativePosition
		if t.orientation == "vertical" then
			t.bar.width = t.frame.width
			t.bar.height = t.frame.width  -- square thumb: height equals scrollbar width
			t.bar.x = t.frame.x
			t.bar.y = t.frame.y + (t.bar.position * (t.frame.height - t.bar.height))
		elseif t.orientation == "horizontal" then
			t.bar.width = t.frame.height  -- square thumb: width equals scrollbar height
			t.bar.height = t.frame.height
			t.bar.x = t.frame.x + (t.bar.position * (t.frame.width - t.bar.width))
			t.bar.y = t.frame.y
		end

		-- Pre-compute bar draw scale (updated in resize() after each geometry change).
		if t.bar.img then
			if t.orientation == "horizontal" then
				t.bar.rotation = -math.pi / 2
				t.bar.originX  = t._dimBarW
				t.bar.scaleX   = t.bar.height / t._dimBarW
				t.bar.scaleY   = t.bar.width  / t._dimBarH
			else
				t.bar.rotation = 0
				t.bar.originX  = 0
				t.bar.scaleX   = t.bar.width  / t._dimBarW
				t.bar.scaleY   = t.bar.height / t._dimBarH
			end
		end

	-- table.insert(scrollBars,t)
	
	function t:resize()
		-- Use the original, relative values for recalculation
		local original = self.original
		
		if self.orientation == "vertical" then
			self.frame.height = original.height
			self.frame.width = original.width
		elseif self.orientation == "horizontal" then
			self.frame.height = original.height
			self.frame.width = original.width
		end

		self.frame.positions =
				gdsGui_general_relativePosition (original.anchorPoint,
									original.x,
									original.y,
									self.frame.width,
									self.frame.height,
									globApp.safeScreenArea.x,
									globApp.safeScreenArea.y,
									globApp.safeScreenArea.w,
									globApp.safeScreenArea.h)
		self.frame.x = self.frame.positions[1] - globApp.safeScreenArea.x
		self.frame.y = self.frame.positions[2] - globApp.safeScreenArea.y

		if globApp.OperatingSystem == "iOS" or globApp.OperatingSystem == "Android" then
			self.frame.y = self.frame.y + globApp.safeScreenArea.y
		end
		
		if globApp.OperatingSystem ~= "iOS" and globApp.OperatingSystem ~= "Android" then
			if self.orientation == "vertical" then

				self.upButton.width = self.frame.width
				self.upButton.height = self.frame.width
				self.upButton.x = self.frame.x
				self.upButton.y = self.frame.y
				self.upButton.factorWidth = self.upButton.width / self.imgButtonUpArrow_active:getWidth ()
				self.upButton.factorHeight = self.upButton.height / self.imgButtonUpArrow_active:getHeight ()
				self.upButton.isActive = false
				self.upButton.centeredX = self.upButton.x + (self.upButton.width  - self._dimUpW   * self.upButton.factorWidth)  / 2
				self.upButton.centeredY = self.upButton.y + (self.upButton.height - self._dimUpH   * self.upButton.factorHeight) / 2

				self.downButton.width = self.frame.width
				self.downButton.height = self.frame.width
				self.downButton.x = self.frame.x
				self.downButton.y = self.frame.y + self.frame.height - self.downButton.height
				self.downButton.factorWidth = self.downButton.width / self.imgButtonDownArrow_active:getWidth ()
				self.downButton.factorHeight = self.downButton.height / self.imgButtonDownArrow_active:getHeight ()
				self.downButton.isActive = false
				self.downButton.centeredX = self.downButton.x + (self.downButton.width  - self._dimDownW * self.downButton.factorWidth)  / 2
				self.downButton.centeredY = self.downButton.y + (self.downButton.height - self._dimDownH * self.downButton.factorHeight) / 2

				self.frame.y = self.upButton.y + self.upButton.height
				self.frame.height = self.downButton.y - self.frame.y
			
			elseif self.orientation == "horizontal" then

				self.leftButton.width = self.frame.height
				self.leftButton.height = self.frame.height
				self.leftButton.x = self.frame.x
				self.leftButton.y = self.frame.y
				self.leftButton.factorWidth = self.leftButton.width / self.imgButtonLeftArrow_active:getWidth ()
				self.leftButton.factorHeight = self.leftButton.height / self.imgButtonLeftArrow_active:getHeight ()
				self.leftButton.isActive = false
				self.leftButton.centeredX = self.leftButton.x + (self.leftButton.width  - self._dimLeftW  * self.leftButton.factorWidth)  / 2
				self.leftButton.centeredY = self.leftButton.y + (self.leftButton.height - self._dimLeftH  * self.leftButton.factorHeight) / 2

				self.rightButton.width = self.frame.height
				self.rightButton.height = self.frame.height
				self.rightButton.x = self.frame.x + self.frame.width - self.rightButton.width
				self.rightButton.y = self.frame.y
				self.rightButton.factorWidth = self.rightButton.width / self.imgButtonRightArrow_active:getWidth ()
				self.rightButton.factorHeight = self.rightButton.height / self.imgButtonRightArrow_active:getHeight ()
				self.rightButton.isActive = false
				self.rightButton.centeredX = self.rightButton.x + (self.rightButton.width  - self._dimRightW * self.rightButton.factorWidth)  / 2
				self.rightButton.centeredY = self.rightButton.y + (self.rightButton.height - self._dimRightH * self.rightButton.factorHeight) / 2

				self.frame.x = self.leftButton.x + self.leftButton.width
				self.frame.width = self.rightButton.x - self.frame.x

			end
		end

		-- self.bar.position is updated externally, so we only recalculate its physical position
		if self.orientation == "vertical" then
			self.bar.width = self.frame.width
			self.bar.height = self.frame.width  -- square thumb: height equals scrollbar width
			self.bar.x = self.frame.x
			self.bar.y = self.frame.y + (self.bar.position * (self.frame.height - self.bar.height))
		elseif self.orientation == "horizontal" then
			self.bar.width = self.frame.height  -- square thumb: width equals scrollbar height
			self.bar.height = self.frame.height
			self.bar.x = self.frame.x + (self.bar.position * (self.frame.width - self.bar.width))
			self.bar.y = self.frame.y
		end

		-- Refresh pre-computed draw scales after geometry changes.
		-- (rotation and originX never change after create(), only scales are recalculated.)
		if self.frame.img then
			if self.orientation == "horizontal" then
				self.frame.scaleX = self.frame.height / self._dimFrameW
				self.frame.scaleY = self.frame.width  / self._dimFrameH
			else
				self.frame.scaleX = self.frame.width  / self._dimFrameW
				self.frame.scaleY = self.frame.height / self._dimFrameH
			end
		end
		if self.bar.img then
			if self.orientation == "horizontal" then
				self.bar.scaleX = self.bar.height / self._dimBarW
				self.bar.scaleY = self.bar.width  / self._dimBarH
			else
				self.bar.scaleX = self.bar.width  / self._dimBarW
				self.bar.scaleY = self.bar.height / self._dimBarH
			end
		end
	end
	t.resize = t.resize

	table.insert(globApp.objects.scrollBars, t)
	globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
	if containerName then
		t.containerFrac = { x=x, y=y, w=width, h=height, anchorPoint=anchorPoint }
		gdsGui_container_addObject(containerName, "scrollBar", id)
	end

end


-- function scrollBar_delete (id, strgPage)
-- 	for i = #globApp.objects.scrollBars,1,-1 do
-- 		local scrollbar = globApp.objects.scrollBars[i]
-- 		if scrollbar.id == id and scrollbar.page == strgPage then
-- 			table.remove(globApp.objects.scrollBars,i)
-- 			globApp.numObjectsDisplayed = globApp.numObjectsDisplayed - 1
-- 		end
-- 	end
-- end


-- Draw one scrollbar object.  Called by the container system for owned scrollbars.
function gdsGui_scrollBar_drawSingle(x)
	love.graphics.setColor(1, 1, 1, 1)
	if x.frame.img then
		love.graphics.draw(x.frame.img, x.frame.x, x.frame.y, x.frame.rotation, x.frame.scaleX, x.frame.scaleY, x.frame.originX, 0)
	else
		love.graphics.rectangle("fill", x.frame.x, x.frame.y, x.frame.width, x.frame.height)
	end
	if x.bar.img then
		love.graphics.draw(x.bar.img, x.bar.x, x.bar.y, x.bar.rotation, x.bar.scaleX, x.bar.scaleY, x.bar.originX, 0)
	else
		love.graphics.setColor(x.isFocused and _COLOR_BAR_FOCUSED or _COLOR_BAR_UNFOCUSED)
		love.graphics.rectangle("fill", x.bar.x, x.bar.y, x.bar.width, x.bar.height)
	end
	local _isDark = not globApp.themeTextColor or globApp.themeTextColor[1] > 0.5
	local _btnBg  = _isDark and {1, 1, 0, 1} or {0.3, 0.3, 0.3, 1}
	if x.orientation == "vertical" then
		if x.upButton then
			love.graphics.setColor(_btnBg)
			love.graphics.rectangle("fill", x.upButton.x, x.upButton.y, x.upButton.width, x.upButton.height)
			love.graphics.setColor(1, 1, 1, 1)
			local img = x.upButton.isActive and x.imgButtonUpArrow_active or x.imgButtonUpArrow_inactive
			love.graphics.draw(img, x.upButton.centeredX, x.upButton.centeredY, 0, x.upButton.factorWidth, x.upButton.factorHeight)
		end
		if x.downButton then
			love.graphics.setColor(_btnBg)
			love.graphics.rectangle("fill", x.downButton.x, x.downButton.y, x.downButton.width, x.downButton.height)
			love.graphics.setColor(1, 1, 1, 1)
			local img = x.downButton.isActive and x.imgButtonDownArrow_active or x.imgButtonDownArrow_inactive
			love.graphics.draw(img, x.downButton.centeredX, x.downButton.centeredY, 0, x.downButton.factorWidth, x.downButton.factorHeight)
		end
	elseif x.orientation == "horizontal" then
		if x.leftButton then
			love.graphics.setColor(_btnBg)
			love.graphics.rectangle("fill", x.leftButton.x, x.leftButton.y, x.leftButton.width, x.leftButton.height)
			love.graphics.setColor(1, 1, 1, 1)
			local img = x.leftButton.isActive and x.imgButtonLeftArrow_active or x.imgButtonLeftArrow_inactive
			love.graphics.draw(img, x.leftButton.centeredX, x.leftButton.centeredY, 0, x.leftButton.factorWidth, x.leftButton.factorHeight)
		end
		if x.rightButton then
			love.graphics.setColor(_btnBg)
			love.graphics.rectangle("fill", x.rightButton.x, x.rightButton.y, x.rightButton.width, x.rightButton.height)
			love.graphics.setColor(1, 1, 1, 1)
			local img = x.rightButton.isActive and x.imgButtonRightArrow_active or x.imgButtonRightArrow_inactive
			love.graphics.draw(img, x.rightButton.centeredX, x.rightButton.centeredY, 0, x.rightButton.factorWidth, x.rightButton.factorHeight)
		end
	end
	love.graphics.setColor(1, 1, 1, 1)
end


function gdsGui_scrollBar_draw (pageName)
	for i,x in ipairs(globApp.objects.scrollBars) do --[[runs continuously]]
			if x.page == pageName and not x.ownerContainer then
				if x.bar.position ~= dataRelativePosition and dataRelativePosition ~= nil then
					if x.type == "independent" then
						gdsGui_scrollBar_updatePosition (x, x.bar.position)
					elseif x.type == "table-linked" then
						gdsGui_scrollBar_updatePosition (x, dataRelativePosition)
					end
				end
				
					--------------------------------------------------------------------------
											--SCROLLBAR FRAME
					--------------------------------------------------------------------------
					love.graphics.setColor(1, 1, 1, 1)
					if x.frame.img then
						love.graphics.draw(x.frame.img, x.frame.x, x.frame.y, x.frame.rotation, x.frame.scaleX, x.frame.scaleY, x.frame.originX, 0)
					else
						love.graphics.rectangle("fill", x.frame.x, x.frame.y, x.frame.width, x.frame.height)
					end

					---------------------------------------------------------------------------
											--BAR
					---------------------------------------------------------------------------
					if x.bar.img then
						love.graphics.draw(x.bar.img, x.bar.x, x.bar.y, x.bar.rotation, x.bar.scaleX, x.bar.scaleY, x.bar.originX, 0)
					else
						love.graphics.setColor(x.isFocused and _COLOR_BAR_FOCUSED or _COLOR_BAR_UNFOCUSED)
						love.graphics.rectangle("fill", x.bar.x, x.bar.y, x.bar.width, x.bar.height)
					end
					
					---------------------------------------------------------------------------
											--BUTTONS
					---------------------------------------------------------------------------
					local _isDark = not globApp.themeTextColor or globApp.themeTextColor[1] > 0.5
					local _btnBg  = _isDark and {1, 1, 0, 1} or {0.3, 0.3, 0.3, 1}
					if x.orientation == "vertical" then
						if x.upButton then
							love.graphics.setColor(_btnBg)
							love.graphics.rectangle("fill", x.upButton.x, x.upButton.y, x.upButton.width, x.upButton.height)
							love.graphics.setColor(1, 1, 1, 1)
							local img = x.upButton.isActive and x.imgButtonUpArrow_active or x.imgButtonUpArrow_inactive
							love.graphics.draw(img, x.upButton.centeredX, x.upButton.centeredY, 0, x.upButton.factorWidth, x.upButton.factorHeight)
						end

						if x.downButton then
							love.graphics.setColor(_btnBg)
							love.graphics.rectangle("fill", x.downButton.x, x.downButton.y, x.downButton.width, x.downButton.height)
							love.graphics.setColor(1, 1, 1, 1)
							local img = x.downButton.isActive and x.imgButtonDownArrow_active or x.imgButtonDownArrow_inactive
							love.graphics.draw(img, x.downButton.centeredX, x.downButton.centeredY, 0, x.downButton.factorWidth, x.downButton.factorHeight)
						end
					elseif x.orientation == "horizontal" then
						if x.leftButton then
							love.graphics.setColor(_btnBg)
							love.graphics.rectangle("fill", x.leftButton.x, x.leftButton.y, x.leftButton.width, x.leftButton.height)
							love.graphics.setColor(1, 1, 1, 1)
							local img = x.leftButton.isActive and x.imgButtonLeftArrow_active or x.imgButtonLeftArrow_inactive
							love.graphics.draw(img, x.leftButton.centeredX, x.leftButton.centeredY, 0, x.leftButton.factorWidth, x.leftButton.factorHeight)
						end
						if x.rightButton then
							love.graphics.setColor(_btnBg)
							love.graphics.rectangle("fill", x.rightButton.x, x.rightButton.y, x.rightButton.width, x.rightButton.height)
							love.graphics.setColor(1, 1, 1, 1)
							local img = x.rightButton.isActive and x.imgButtonRightArrow_active or x.imgButtonRightArrow_inactive
							love.graphics.draw(img, x.rightButton.centeredX, x.rightButton.centeredY, 0, x.rightButton.factorWidth, x.rightButton.factorHeight)
						end
					end
					love.graphics.setColor(1, 1, 1, 1)
			end
	    end
	end




function gdsGui_scrollBar_updatePosition (sb, dataPercPosition)
	if sb.state == 1 then
		if sb.orientation == "vertical" then
			sb.bar.y = sb.frame.y + (dataPercPosition * (sb.frame.height - sb.bar.height))
		elseif sb.orientation == "horizontal" then
			sb.bar.x = sb.frame.x + (dataPercPosition * (sb.frame.width - sb.bar.width))
		end
	end
end


function gdsGui_scrollBar_focus (id, x,y,button,istouch)

	if button == 1 or globApp.userInput == "touch pressed" then

		local activePage = gdsGui_page_currentName()
		for i, sb in ipairs (globApp.objects.scrollBars) do

			-- Only process scrollbars belonging to the active page.
			if sb.page ~= activePage then goto sb_focus_continue end

			-- Ignore touches that fall outside the scrollbar's owner container clip rect.
			if sb.ownerContainer and not gdsGui_container_isTouchInOwnerContainer(sb, x, y) then goto sb_focus_continue end

			-- Thumb focus: fire haptic once on initial tap, track which touch owns this scrollbar.
			if x >= sb.bar.x and x <= (sb.bar.x + sb.bar.width) and y >= sb.bar.y and y <= sb.bar.y + sb.bar.height then
				if not sb.isFocused then
					sb.isFocused = true
					sb.focusTouchId = id
					if sb.hapticEnabled then gdsGui_haptics_vibrate() end
				end
			end

			local stepSize = 0
			if sb.numTotalValues and sb.numTotalValues > 1 then -- Ensure at least 2 total values to allow movement
				stepSize = 1 / (sb.numTotalValues - 1)
			end

			if sb.orientation == "vertical" then
				if sb.upButton then -- Only check if button exists
					if x >= sb.upButton.x and x <= (sb.upButton.x + sb.upButton.width) and y >= sb.upButton.y and y <= sb.upButton.y + sb.upButton.height then
						if not sb.upButton.isActive then -- Only step if not already active (first press)
							sb.upButton.isActive = true
							-- Discrete step for up arrow
							sb.bar.position = math.max(0, sb.bar.position - stepSize)
							gdsGui_scrollBar_updatePosition(sb, sb.bar.position)
							if sb.callbackFn then
								sb.callbackFn(sb.bar.position)
							end
						end
					end
				end

				if sb.downButton then -- Only check if button exists
					if x >= sb.downButton.x and x <= (sb.downButton.x + sb.downButton.width) and y >= sb.downButton.y and y <= sb.downButton.y + sb.downButton.height then
						if not sb.downButton.isActive then -- Only step if not already active (first press)
							sb.downButton.isActive = true
							-- Discrete step for down arrow
							sb.bar.position = math.min(1, sb.bar.position + stepSize)
							gdsGui_scrollBar_updatePosition(sb, sb.bar.position)
							if sb.callbackFn then
								sb.callbackFn(sb.bar.position)
							end
						end
					end
				end

			elseif sb.orientation == "horizontal" then
				if sb.leftButton then -- Only check if button exists
					if x >= sb.leftButton.x and x <= (sb.leftButton.x + sb.leftButton.width) and y >= sb.leftButton.y and y <= sb.leftButton.y + sb.leftButton.height then
						if not sb.leftButton.isActive then -- Only step if not already active (first press)
							sb.leftButton.isActive = true
							-- Discrete step for left arrow
							sb.bar.position = math.max(0, sb.bar.position - stepSize)
							gdsGui_scrollBar_updatePosition(sb, sb.bar.position)
							if sb.callbackFn then
								sb.callbackFn(sb.bar.position)
							end
						end
					end
				end

				if sb.rightButton then
					if x >= sb.rightButton.x and x <= (sb.rightButton.x + sb.rightButton.width) and y >= sb.rightButton.y and y <= sb.rightButton.y + sb.rightButton.height then
						if not sb.rightButton.isActive then -- Only step if not already active (first press)
							sb.rightButton.isActive = true
							-- Discrete step for right arrow
							sb.bar.position = math.min(1, sb.bar.position + stepSize)
							gdsGui_scrollBar_updatePosition(sb, sb.bar.position)
							if sb.callbackFn then
								sb.callbackFn(sb.bar.position)
							end
						end
					end
				end

			end

			::sb_focus_continue::
		end

	end
end


function gdsGui_scrollBar_unfocus (id, x,y,button,istouch)
	if button == 1 or globApp.userInput == "touch released" then --isolate to mouse use
		for i, sb in ipairs (globApp.objects.scrollBars) do
			-- Arrow buttons are desktop-only; always reset their active state on any release
			-- so they never stay visually stuck in the pressed state.
			if sb.orientation == "vertical" then
				if sb.upButton   then sb.upButton.isActive   = false end
				if sb.downButton then sb.downButton.isActive = false end
			elseif sb.orientation == "horizontal" then
				if sb.leftButton  then sb.leftButton.isActive  = false end
				if sb.rightButton then sb.rightButton.isActive = false end
			end
			-- Thumb focus is per-touch: only unfocus the scrollbar owned by this interaction.
			if sb.focusTouchId == id then
				sb.isFocused = false
				sb._prevSnapIndex = -1
				sb.focusTouchId = nil
			end
		end
	end
end


function gdsGui_scrollBar_holdAndDrag (id, x,y,button,istouch, devMode)
	--moves scrolling bar up or down when the bar is focused and dragged
	--runs using the love.mouseMoved callback function

	for i, sb in ipairs (globApp.objects.scrollBars) do--scroll through available scrollbars
		-- Only drag the scrollbar that was originally focused by this touch/mouse interaction.
		if sb.focusTouchId ~= id then goto continue end

		if sb.orientation == "vertical" then
			totalPositionSpan = sb.frame.height - sb.bar.height
		elseif sb.orientation == "horizontal" then
			totalPositionSpan = sb.frame.width - sb.bar.width
		end

		if totalPositionSpan > 0 then -- code only runs if bar is smaller than frame
			if sb.isFocused == true then --isolates focused bars only
				if sb.orientation == "vertical" then
					if y - (sb.bar.height / 2) >= sb.frame.y and ((y - (sb.bar.height / 2)) + sb.bar.height) <= (sb.frame.y + sb.frame.height) then
						sb.bar.y = y - (sb.bar.height / 2)
					elseif y - (sb.bar.height / 2) < sb.frame.y then
						sb.bar.y = sb.frame.y
					elseif (y + sb.bar.height) > (sb.frame.y + sb.frame.height)then
						sb.bar.y = (sb.frame.y + sb.frame.height) - sb.bar.height
					end
					-- Snap to nearest increment
					if sb.numTotalValues and sb.numTotalValues > 1 then
						sb.bar.position = (sb.bar.y - sb.frame.y) / totalPositionSpan
						local snapIdx = math.floor(sb.bar.position * (sb.numTotalValues - 1) + 0.5)
						sb.bar.position = snapIdx / (sb.numTotalValues - 1)
						sb._prevSnapIndex = snapIdx
					else
						sb.bar.position = (sb.bar.y - sb.frame.y) / totalPositionSpan
					end
					gdsGui_scrollBar_updatePosition(sb, sb.bar.position) -- Update physical position after snapping
				elseif sb.orientation == "horizontal" then
					if x - (sb.bar.width / 2) >= sb.frame.x and ((x - (sb.bar.width / 2)) + sb.bar.width) <= (sb.frame.x + sb.frame.width) then
						sb.bar.x = x - (sb.bar.width / 2)
					elseif x - (sb.bar.width / 2) < sb.frame.x then
						sb.bar.x = sb.frame.x
					elseif (x + sb.bar.width) > (sb.frame.x + sb.frame.width)then
						sb.bar.x = (sb.frame.x + sb.frame.width) - sb.bar.width
					end
					sb.bar.position = (sb.bar.x - sb.frame.x) / totalPositionSpan
					-- Snap to nearest increment
					if sb.numTotalValues and sb.numTotalValues > 1 then
						local snapIdx = math.floor(sb.bar.position * (sb.numTotalValues - 1) + 0.5)
						sb.bar.position = snapIdx / (sb.numTotalValues - 1)
						sb._prevSnapIndex = snapIdx
					end
					gdsGui_scrollBar_updatePosition(sb, sb.bar.position) -- Update physical position after snapping
				end

				if sb.callbackFn then
					sb.callbackFn(sb.bar.position)
				end
			end
		end

		if devMode == true then
			local result = {}
				result.sBarPosition = sb.bar.position
			return result
		end

		::continue::
	end
end


function gdsGui_scrollBar_buttonsPressed (dt)
	-- Continuous scrolling for scrollbar buttons is now handled by discrete steps in gdsGui_scrollBar_focus.
	-- This function will no longer actively move scrollbars based on button presses.
end


