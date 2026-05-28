-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[API = Menu labels Lybrary ]]

-----------------------------------------------------------------
globApp.objects.outputTextBox = {}

-- ---------------------------------------------------------------------------
--  MOMENTUM SCROLL PHYSICS CONSTANTS
-- ---------------------------------------------------------------------------
local SCROLL_FRICTION  = 3.5    -- exponential velocity decay rate (per second)
local SPRING_OMEGA     = 18.0   -- natural frequency of bounce spring (rad/s)
local SPRING_K         = SPRING_OMEGA * SPRING_OMEGA   -- stiffness  = 324
local SPRING_C         = 2.0   * SPRING_OMEGA          -- critical damping = 36
local RUBBER_BAND      = 0.35   -- drag resistance factor when beyond limits (0–1)
local COAST_STOP_VEL   = 8.0    -- pixels/sec below which coasting is considered stopped
local BOUNCE_STOP_DISP = 0.5    -- pixels of displacement below which spring snaps to limit
local BOUNCE_STOP_VEL  = 5.0    -- pixels/sec below which spring is considered settled
local BOTTOM_READ_THRESHOLD = 20  -- pixels from minOffset that counts as "read to bottom"
local SB_WIDTH              = 10  -- width of the embedded scrollbar strip in pixels


-- ---------------------------------------------------------------------------
--  PRIVATE HELPERS
-- ---------------------------------------------------------------------------

-- Returns (minOffsetY, maxOffsetY) for tb.scroll.offsetY.
-- maxOffset is always 0 (content at natural top position).
-- minOffset is negative when content is taller than the frame.
local function _getScrollLimits(tb)
	local minOffset = math.min(0, tb.frame.height - tb.text.combinedTxtHeight)
	return minOffset, 0
end

-- Applies elastic rubber-band resistance when offset exceeds limits.
local function _applyRubberBand(offset, minOffset, maxOffset)
	if offset < minOffset then
		return minOffset + (offset - minOffset) * RUBBER_BAND
	elseif offset > maxOffset then
		return maxOffset + (offset - maxOffset) * RUBBER_BAND
	end
	return offset
end

-- Recomputes the scrollbar thumb size and Y position from current offsetY.
local function _updateScrollbarThumb(tb)
	if not tb.scrollbar then return end
	local sb = tb.scrollbar
	local minOff, _ = _getScrollLimits(tb)
	sb.visible = (minOff < -0.5)
	if not sb.visible then return end
	local trackH    = sb.track.h
	local proportion = tb.frame.height / tb.text.combinedTxtHeight
	local thumbH    = math.max(math.floor(trackH * proportion), SB_WIDTH * 2)
	thumbH = math.min(thumbH, trackH)
	local clampedOff  = math.max(minOff, math.min(0, tb.scroll.offsetY))
	local scrollFrac  = clampedOff / minOff   -- 0=top, 1=bottom
	sb.thumb.x = sb.track.x
	sb.thumb.y = math.floor(sb.track.y + scrollFrac * (trackH - thumbH))
	sb.thumb.w = SB_WIDTH
	sb.thumb.h = thumbH
end

-- Recalculates all scrollbar geometry from the current frame position/size.
-- Must be called after frame.x/y/width/height change.
local function _setupScrollbarGeometry(tb)
	if not tb.scrollbar then return end
	local sb = tb.scrollbar
	sb.x      = tb.frame.x + tb.frame.width   -- right edge of the text area
	sb.y      = tb.frame.y
	sb.height = tb.frame.height
	local isDesktop = (globApp.OperatingSystem ~= "iOS" and globApp.OperatingSystem ~= "Android")
	if isDesktop then
		local btnH   = SB_WIDTH
		sb.upBtn     = sb.upBtn   or {}
		sb.downBtn   = sb.downBtn or {}
		sb.upBtn.x   = sb.x;  sb.upBtn.y  = sb.y
		sb.upBtn.w   = SB_WIDTH; sb.upBtn.h = btnH
		sb.upBtn.isActive = false
		sb.downBtn.x = sb.x;  sb.downBtn.y = sb.y + sb.height - btnH
		sb.downBtn.w = SB_WIDTH; sb.downBtn.h = btnH
		sb.downBtn.isActive = false
		sb.track.x = sb.x;  sb.track.y = sb.y + btnH
		sb.track.w = SB_WIDTH; sb.track.h = sb.height - btnH * 2
	else
		sb.upBtn   = nil
		sb.downBtn = nil
		sb.track.x = sb.x;  sb.track.y = sb.y
		sb.track.w = SB_WIDTH; sb.track.h = sb.height
	end
	_updateScrollbarThumb(tb)
end

-- Recomputes each line's screen Y from its natural (unscrolled) Y plus the
-- current scroll offset, then refreshes isVisible.
local function _apply_scroll_offset(tb)
	-- Skip when neither the scroll offset nor the line layout has changed.
	local sc = tb.scroll
	local lineGen = tb.text._lineGen or 0
	if sc._lastOffY == sc.offsetY and sc._lastLineGen == lineGen then return end
	sc._lastOffY    = sc.offsetY
	sc._lastLineGen = lineGen

	for _, line in ipairs(tb.text.lines) do
		line.y = line.naturalY + sc.offsetY
		line.isVisible = gdsGui_outputTxtBox_isTextInFrame(tb.frame, line)
	end
	-- Mark as read-to-bottom once (never cleared by scrolling back up).
	if not sc.hasReachedBottom then
		local minOff, _ = _getScrollLimits(tb)
		if minOff >= -0.5 then
			sc.hasReachedBottom = true
		elseif sc.offsetY <= minOff + BOTTOM_READ_THRESHOLD then
			sc.hasReachedBottom = true
		end
	end
	_updateScrollbarThumb(tb)
end


-- ---------------------------------------------------------------------------
--  TEXT SEGMENT HELPERS
-- ---------------------------------------------------------------------------

-- Converts text + defaultColor into a uniform {text, color}[] segment list.
-- A plain string becomes one segment; a table of {text, color} pairs is used as-is.
local function _normalizeText(text, defaultColor)
	if type(text) == "string" then
		return { { text = text, color = defaultColor } }
	end
	local out = {}
	for _, seg in ipairs(text) do
		out[#out + 1] = { text = seg.text or "", color = seg.color or defaultColor }
	end
	return out
end

-- Builds tb.text.lines from tb.text.text (string or segment table).
-- Sets maxTextLineCount, combinedTxtHeight, and _lineGen.
-- Requires tb.text.{font, width, height, x, baseY, color} to already be set.
local function _buildLines(tb)
	local segments = _normalizeText(tb.text.text, tb.text.color)
	local allLines = {}
	for _, seg in ipairs(segments) do
		local _w, wrapped = tb.text.font:getWrap(seg.text, tb.text.width)
		for _, l in ipairs(wrapped) do
			allLines[#allLines + 1] = { text = l, color = seg.color }
		end
	end
	local n = #allLines
	tb.text.maxTextLineCount  = n
	tb.text.combinedTxtHeight = tb.text.height * n
	tb.text._lineGen          = (tb.text._lineGen or 0) + 1
	tb.text.lines = {}
	for i, item in ipairs(allLines) do
		local line = {}
		line.text      = item.text
		line.x         = tb.text.x
		line.width     = tb.text.width
		line.naturalY  = tb.text.baseY + (tb.text.height * (i - 1))
		line.y         = line.naturalY
		line.height    = tb.text.height
		line.color     = item.color
		line.alignement= "center"
		line.isVisible = gdsGui_outputTxtBox_isTextInFrame(tb.frame, line)
		tb.text.lines[i] = line
	end
end


-- ---------------------------------------------------------------------------
--  CREATION
-- ---------------------------------------------------------------------------

function gdsGui_outputTxtBox_create (id, page, bgSprite, x, y, anchorPoint, width, height, txtColor, text, fontSize, containerName)

	local tb = {}

		tb.name       = id
		tb.objectType = "outputTextBox"
		tb.page       = page
		tb.type       = labelType

		tb.x           = x
		tb.y           = y
		tb.anchorPoint = anchorPoint
		tb.rltvWidth   = width
		tb.rltvHeight  = height
			local myPositions = gdsGui_general_relativePosition(anchorPoint, x, y, tb.rltvWidth, tb.rltvHeight,
			                                     globApp.safeScreenArea.x, globApp.safeScreenArea.y,
			                                     globApp.safeScreenArea.w, globApp.safeScreenArea.h)
		tb.state = 1
		tb.origTotalWidth = width   -- full width including the scrollbar strip

		tb.frame = {}
			tb.frame.width  = width - SB_WIDTH  -- text area only; scrollbar occupies the right SB_WIDTH px
			tb.frame.height = height
			tb.frame.x = math.floor(myPositions[1])
			tb.frame.y = math.floor(myPositions[2])

		tb.bgSprite = {}
			if bgSprite ~= nil then
				tb.bgSprite.sprite = love.graphics.newImage(bgSprite)
				tb.bgSprite.width  = tb.origTotalWidth / tb.bgSprite.sprite:getWidth()
				tb.bgSprite.height = height / tb.bgSprite.sprite:getHeight()
				tb.bgSprite.x = tb.frame.x
				tb.bgSprite.y = tb.frame.y
			end

		tb.text = {}
			tb.text.font = love.graphics.newFont(fontSize)
			if tb.state == 1 then
				tb.text.color    = txtColor
				tb.text.text     = text
				tb.text.lastText = text
			elseif tb.state == 2 then
				tb.text.color    = {1, 0, 0, 1}
				tb.text.text     = "txtOutputBox Error"
				tb.text.lastText = "txtOutputBox Error"
			end

			tb.text.width  = tb.frame.width * 0.8
			tb.text.height = gdsGui_general_returnFontInfo(tb.text.font, "height")
			tb.text.x      = tb.frame.x + ((tb.frame.width - tb.text.width) / 2)
			tb.text.baseY  = tb.frame.y
			_buildLines(tb)

		-- Momentum scroll physics state
		tb.scroll = {
			offsetY          = 0,
			velocityY        = 0,
			phase            = "idle",
			isDragging       = false,
			hasReachedBottom = false,
		}

		-- Embedded scrollbar state (geometry filled by _setupScrollbarGeometry below)
		tb.scrollbar = {
			x=0, y=0, width=SB_WIDTH, height=0, visible=false,
			track = {x=0, y=0, w=0, h=0},
			thumb = {x=0, y=0, w=0, h=0, isDragging=false, focusTouchId=nil, dragStartY=0, dragStartOffset=0},
			upBtn=nil, downBtn=nil,
		}
		_setupScrollbarGeometry(tb)

		table.insert(globApp.objects.outputTextBox, tb)
		globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
		if containerName then
			tb.containerFrac = { x=x, y=y, w=width, h=height, anchorPoint=anchorPoint }
			gdsGui_container_addObject(containerName, "outputTextBox", id)
		end

end


-- ---------------------------------------------------------------------------
--  PRIVATE RECALCULATE (resize / text change)
-- ---------------------------------------------------------------------------

local function _recalculate_textBox(updtLbl)

	if globApp.lastSafeScreenArea and globApp.lastSafeScreenArea.w > 0 then

		-- Use origTotalWidth for anchor/centering so the full declared width governs layout.
		updtLbl.rltvWidth  = updtLbl.origTotalWidth or (updtLbl.frame.width + SB_WIDTH)
		updtLbl.rltvHeight = updtLbl.frame.height

		-- Container-owned textboxes: the container system owns frame.x/y.
		-- Recalculating from relative coords would snap the box back to its
		-- original pre-scroll position on every text change.
		if not updtLbl.ownerContainer then
			local myPositions = gdsGui_general_relativePosition(updtLbl.anchorPoint, updtLbl.x, updtLbl.y,
			                                     updtLbl.rltvWidth, updtLbl.rltvHeight,
			                                     globApp.safeScreenArea.x, globApp.safeScreenArea.y,
			                                     globApp.safeScreenArea.w, globApp.safeScreenArea.h)
			updtLbl.frame.x = math.floor(myPositions[1])
			updtLbl.frame.y = math.floor(myPositions[2])
			if updtLbl.bgSprite.sprite ~= nil then
				updtLbl.bgSprite.x = updtLbl.frame.x
				updtLbl.bgSprite.y = updtLbl.frame.y
			end
		end

		if updtLbl.bgSprite.sprite ~= nil then
			updtLbl.bgSprite.width  = updtLbl.rltvWidth / updtLbl.bgSprite.sprite:getWidth()
			updtLbl.bgSprite.height = updtLbl.frame.height / updtLbl.bgSprite.sprite:getHeight()
		end

		updtLbl.text.width  = updtLbl.frame.width * 0.8
		updtLbl.text.height = gdsGui_general_returnFontInfo(updtLbl.text.font, "height")
		updtLbl.text.x      = updtLbl.frame.x + ((updtLbl.frame.width - updtLbl.text.width) / 2)
		updtLbl.text.baseY  = updtLbl.frame.y
		_buildLines(updtLbl)

		-- Clamp scroll to new limits and re-apply offset
		if updtLbl.scroll then
			local minOff, maxOff = _getScrollLimits(updtLbl)
			updtLbl.scroll.offsetY = math.max(minOff, math.min(maxOff, updtLbl.scroll.offsetY))
			_apply_scroll_offset(updtLbl)
		end

		_setupScrollbarGeometry(updtLbl)

	end
end


-- ---------------------------------------------------------------------------
--  UPDATE (called every frame with dt from gdsGui_update)
-- ---------------------------------------------------------------------------

function gdsGui_outputTxtBox_update(dt)

	for i, updtLbl in ipairs(globApp.objects.outputTextBox) do

		-- Rebuild lines on resize or text change
		if globApp.resizeDetected or (updtLbl.text.text ~= updtLbl.text.lastText) then
			_recalculate_textBox(updtLbl)
			updtLbl.text.lastText = updtLbl.text.text
		end

		-- Physics: skip when dragging, idle, or no real dt
		if updtLbl.scroll and not updtLbl.scroll.isDragging
		   and updtLbl.scroll.phase ~= "idle"
		   and dt and dt > 0 then

			local minOff, maxOff = _getScrollLimits(updtLbl)
			local canScroll = (minOff < -0.5)  -- content must overflow frame to scroll

			if canScroll then

				if updtLbl.scroll.phase == "coasting" then
					-- ── Exponential friction ──────────────────────────────────────
					updtLbl.scroll.velocityY = updtLbl.scroll.velocityY * math.exp(-SCROLL_FRICTION * dt)
					updtLbl.scroll.offsetY   = updtLbl.scroll.offsetY   + updtLbl.scroll.velocityY * dt

					if updtLbl.scroll.offsetY < minOff or updtLbl.scroll.offsetY > maxOff then
						if updtLbl.scroll.noBounce then
							-- Interrupted coast: clamp to boundary, no spring
							updtLbl.scroll.offsetY   = math.max(minOff, math.min(maxOff, updtLbl.scroll.offsetY))
							updtLbl.scroll.velocityY = 0
							updtLbl.scroll.phase     = "idle"
							updtLbl.scroll.noBounce  = nil
						else
							-- Flew past a boundary → hand off to spring
							updtLbl.scroll.phase = "bouncing"
						end
					elseif math.abs(updtLbl.scroll.velocityY) < COAST_STOP_VEL then
						updtLbl.scroll.phase     = "idle"
						updtLbl.scroll.velocityY = 0
						updtLbl.scroll.noBounce  = nil
					end
					_apply_scroll_offset(updtLbl)

				elseif updtLbl.scroll.phase == "bouncing" then
					-- ── Critically-damped spring back to nearest limit ────────────
					local target     = math.max(minOff, math.min(maxOff, updtLbl.scroll.offsetY))
					local disp       = updtLbl.scroll.offsetY - target
					local springAcc  = (-SPRING_K * disp) + (-SPRING_C * updtLbl.scroll.velocityY)
					updtLbl.scroll.velocityY = updtLbl.scroll.velocityY + springAcc * dt
					updtLbl.scroll.offsetY   = updtLbl.scroll.offsetY   + updtLbl.scroll.velocityY * dt

					-- Settle check
					local newDisp = math.abs(updtLbl.scroll.offsetY - target)
					if newDisp < BOUNCE_STOP_DISP and math.abs(updtLbl.scroll.velocityY) < BOUNCE_STOP_VEL then
						updtLbl.scroll.offsetY   = target
						updtLbl.scroll.velocityY = 0
						updtLbl.scroll.phase     = "idle"
					end
					_apply_scroll_offset(updtLbl)

				end
			end
		end

	end

end




-- Public wrapper used by container.lua after repositioning a textbox.
function gdsGui_outputTxtBox_syncScrollbarGeometry(tb)
	_setupScrollbarGeometry(tb)
end


-- ---------------------------------------------------------------------------
--  DRAW HELPERS
-- ---------------------------------------------------------------------------

local function _drawScrollbarWidget(tb)
	local sb = tb.scrollbar
	if not sb or not sb.visible then return end

	local isDark = not globApp.themeTextColor or globApp.themeTextColor[1] > 0.5

	-- Track background
	if isDark then
		love.graphics.setColor(0.2, 0.2, 0.2, 0.55)
	else
		love.graphics.setColor(0.60, 0.60, 0.60, 0.45)
	end
	love.graphics.rectangle("fill", sb.track.x, sb.track.y, sb.track.w, sb.track.h)

	-- Thumb
	if sb.thumb.isDragging then
		love.graphics.setColor(isDark and 1 or 0.10, isDark and 1 or 0.10, isDark and 1 or 0.10, 1)
	else
		if isDark then
			love.graphics.setColor(0.65, 0.65, 0.65, 0.9)
		else
			love.graphics.setColor(0.25, 0.25, 0.25, 0.9)
		end
	end
	love.graphics.rectangle("fill", sb.thumb.x, sb.thumb.y, sb.thumb.w, sb.thumb.h, 2, 2)

	-- Arrow buttons (desktop only)
	if sb.upBtn then
		local ac = sb.upBtn.isActive and {1,1,1,1} or {0.45,0.45,0.45,0.85}
		love.graphics.setColor(ac[1], ac[2], ac[3], ac[4])
		love.graphics.rectangle("fill", sb.upBtn.x, sb.upBtn.y, sb.upBtn.w, sb.upBtn.h)
		love.graphics.setColor(0.1, 0.1, 0.1, 1)
		local cx = sb.upBtn.x + sb.upBtn.w * 0.5
		local cy = sb.upBtn.y + sb.upBtn.h * 0.5
		local r  = sb.upBtn.w * 0.28
		love.graphics.polygon("fill", cx, cy - r, cx - r, cy + r, cx + r, cy + r)
	end
	if sb.downBtn then
		local ac = sb.downBtn.isActive and {1,1,1,1} or {0.45,0.45,0.45,0.85}
		love.graphics.setColor(ac[1], ac[2], ac[3], ac[4])
		love.graphics.rectangle("fill", sb.downBtn.x, sb.downBtn.y, sb.downBtn.w, sb.downBtn.h)
		love.graphics.setColor(0.1, 0.1, 0.1, 1)
		local cx = sb.downBtn.x + sb.downBtn.w * 0.5
		local cy = sb.downBtn.y + sb.downBtn.h * 0.5
		local r  = sb.downBtn.w * 0.28
		love.graphics.polygon("fill", cx - r, cy - r, cx + r, cy - r, cx, cy + r)
	end
end

-- Draws one textbox: text (clipped to frame) then the embedded scrollbar.
-- outerClip: container clip {x,y,width,height} to restore after text scissor; nil for standalone.
function gdsGui_outputTxtBox_drawSingle(tb, outerClip)
	if tb.bgCircle then
		local c  = tb.bgCircle
		local cx = tb.frame.x + (tb.origTotalWidth or tb.frame.width) * 0.5
		local cy = tb.frame.y + tb.frame.height * 0.5
		local r  = (tb.origTotalWidth or tb.frame.width) * 0.5
		love.graphics.setColor(c[1], c[2], c[3], c[4] or 1)
		love.graphics.circle("fill", cx, cy, r)
		love.graphics.setColor(1, 1, 1, 1)
	end
	if tb.bgSprite and tb.bgSprite.sprite then
		love.graphics.draw(tb.bgSprite.sprite, tb.bgSprite.x, tb.bgSprite.y,
		                   0, tb.bgSprite.width, tb.bgSprite.height)
	end

	love.graphics.setFont(tb.text.font)
	love.graphics.setScissor(tb.frame.x, tb.frame.y, tb.frame.width, tb.frame.height)

	if type(tb.text.text) == "string" then
		-- Single-colour path: honour tb.text.color so _applyTheme changes take effect immediately.
		love.graphics.setColor(tb.text.color[1], tb.text.color[2],
		                       tb.text.color[3], tb.text.color[4] or 1)
		for _, line in ipairs(tb.text.lines) do
			if line.isVisible then
				love.graphics.printf(line.text, line.x, line.y, line.width, "center")
			end
		end
	else
		-- Segmented path: each line carries its own developer-specified colour.
		local curColor = nil
		for _, line in ipairs(tb.text.lines) do
			if line.isVisible then
				if line.color ~= curColor then
					love.graphics.setColor(line.color[1], line.color[2], line.color[3], line.color[4] or 1)
					curColor = line.color
				end
				love.graphics.printf(line.text, line.x, line.y, line.width, "center")
			end
		end
	end

	-- Restore outer clip (or clear) so the scrollbar isn't clipped by the text frame.
	if outerClip then
		love.graphics.setScissor(outerClip.x, outerClip.y, outerClip.width, outerClip.height)
	else
		love.graphics.setScissor()
	end

	_drawScrollbarWidget(tb)
	love.graphics.setColor(1, 1, 1, 1)

	-- Restore outer clip if present (container will also call _setClip, but be safe).
	if outerClip then
		love.graphics.setScissor(outerClip.x, outerClip.y, outerClip.width, outerClip.height)
	end
end


-- ---------------------------------------------------------------------------
--  DRAW
-- ---------------------------------------------------------------------------

function gdsGui_outputTxtBox_draw (pg)
	for _, t in ipairs(globApp.objects.outputTextBox) do
		if t.page == pg and not t.ownerContainer and t.state == 1 then
			gdsGui_outputTxtBox_drawSingle(t, nil)
		end
	end
end


-- ---------------------------------------------------------------------------
--  VISIBILITY HELPER
-- ---------------------------------------------------------------------------

function gdsGui_outputTxtBox_isTextInFrame (txtBoxTable, lineTable)
	local result = false
	if lineTable.y >= txtBoxTable.y and (lineTable.y + lineTable.height) <= (txtBoxTable.y + txtBoxTable.height) then
		result = true
	end
	return result
end


-- ---------------------------------------------------------------------------
--  TOUCH / MOUSE DRAG SCROLL
-- ---------------------------------------------------------------------------

-- Called from gdsGui_general_touchpressed / gdsGui_general_mousepressed.
-- Handles arrow button presses and thumb grab on the embedded scrollbar.
function gdsGui_outputTxtBox_scrollbarPressed(id, x, y, button, istouch)
	if button ~= 1 and not istouch then return end
	local activePage = gdsGui_page_currentName()

	for _, tb in ipairs(globApp.objects.outputTextBox) do
		if tb.page ~= activePage then goto sbp_continue end
		if not tb.scrollbar or not tb.scrollbar.visible then goto sbp_continue end
		local sb = tb.scrollbar

		-- Up arrow button
		if sb.upBtn and x >= sb.upBtn.x and x <= sb.upBtn.x + sb.upBtn.w
		           and y >= sb.upBtn.y and y <= sb.upBtn.y + sb.upBtn.h then
			sb.upBtn.isActive = true
			local minOff, maxOff = _getScrollLimits(tb)
			tb.scroll.offsetY   = math.min(maxOff, tb.scroll.offsetY + tb.text.height)
			tb.scroll.velocityY = 0
			tb.scroll.phase     = "idle"
			_apply_scroll_offset(tb)
			return
		end

		-- Down arrow button
		if sb.downBtn and x >= sb.downBtn.x and x <= sb.downBtn.x + sb.downBtn.w
		             and y >= sb.downBtn.y and y <= sb.downBtn.y + sb.downBtn.h then
			sb.downBtn.isActive = true
			local minOff, maxOff = _getScrollLimits(tb)
			tb.scroll.offsetY   = math.max(minOff, tb.scroll.offsetY - tb.text.height)
			tb.scroll.velocityY = 0
			tb.scroll.phase     = "idle"
			_apply_scroll_offset(tb)
			return
		end

		-- Scrollbar thumb grab
		if x >= sb.thumb.x and x <= sb.thumb.x + sb.thumb.w
		and y >= sb.thumb.y and y <= sb.thumb.y + sb.thumb.h then
			sb.thumb.isDragging     = true
			sb.thumb.focusTouchId   = id
			sb.thumb.dragStartY     = y
			sb.thumb.dragStartOffset= tb.scroll.offsetY
			tb.scroll.phase         = "idle"
			tb.scroll.velocityY     = 0
			return
		end

		::sbp_continue::
	end
end


-- Called from gdsGui_general_touchmoved and gdsGui_general_mousemoved.
-- dx, dy are pixel deltas for this frame.
function gdsGui_outputTxtBox_touchScroll (id, x, y, dx, dy, pressure, button, istouch)

	-- Scrollbar thumb drag takes priority over content scroll.
	local matchId = id or "mouse"
	local activePage = gdsGui_page_currentName()
	for _, tb in ipairs(globApp.objects.outputTextBox) do
		if tb.page == activePage and tb.scrollbar and tb.scrollbar.thumb.isDragging
		   and tb.scrollbar.thumb.focusTouchId == matchId then
			local sb   = tb.scrollbar
			local minOff, maxOff = _getScrollLimits(tb)
			local trackRange = sb.track.h - sb.thumb.h
			if trackRange > 0 then
				local delta      = y - sb.thumb.dragStartY
				local scrollRange = -minOff   -- total scrollable pixels
				local newOffset  = sb.thumb.dragStartOffset - (delta / trackRange) * scrollRange
				tb.scroll.offsetY = math.max(minOff, math.min(maxOff, newOffset))
				_apply_scroll_offset(tb)
			end
			return
		end
	end

	-- Accept both touch-slide and mouse-button-held drags
	local isGestureActive = (globApp.userInput == "slide") or love.mouse.isDown(1)
	if not isGestureActive then return end

	for i, tb in ipairs(globApp.objects.outputTextBox) do

		-- Only consider textboxes on the active page
		if tb.page ~= activePage then goto continue end

		-- Only act when the pointer is inside this textbox's frame
		if x >= tb.frame.x and x <= (tb.frame.x + tb.frame.width) and
		   y >= tb.frame.y and y <= (tb.frame.y + tb.frame.height) then

			local minOff, maxOff = _getScrollLimits(tb)
			if minOff < -0.5 then  -- only scroll when content overflows the frame

				-- When this textbox takes focus, interrupt any other active textboxes on this page.
				for _, other in ipairs(globApp.objects.outputTextBox) do
					if other ~= tb and other.page == activePage and other.scroll.phase ~= "idle" then
						other.scroll.isDragging = false  -- prevent touchReleased re-triggering bounce
						local otherMin, otherMax = _getScrollLimits(other)
						if other.scroll.offsetY < otherMin or other.scroll.offsetY > otherMax then
							-- Past a boundary: snap to limit and settle immediately
							other.scroll.offsetY   = math.max(otherMin, math.min(otherMax, other.scroll.offsetY))
							other.scroll.velocityY = 0
							other.scroll.phase     = "idle"
							_apply_scroll_offset(other)
						else
							-- Within bounds: let it coast to a natural stop, but skip the bounce
							other.scroll.noBounce = true
						end
					end
				end

				tb.scroll.isDragging = true
				tb.scroll.phase      = "coasting"

				tb.scroll.offsetY = _applyRubberBand(tb.scroll.offsetY + dy, minOff, maxOff)

				local frameDt = globApp.lastDt or 0
				if frameDt > 0 then
					local rawVel = dy / frameDt
					tb.scroll.velocityY = tb.scroll.velocityY * 0.5 + rawVel * 0.5
				end

				_apply_scroll_offset(tb)
			end
			break  -- pointer matched this frame; don't process other textboxes

		end

		::continue::
	end

end


-- Called from gdsGui_general_touchreleased and gdsGui_general_mousereleased.
-- Seeds the correct physics phase from the accumulated drag velocity.
function gdsGui_outputTxtBox_touchReleased (id, x, y)
	local matchId = id or "mouse"

	for _, tb in ipairs(globApp.objects.outputTextBox) do

		-- Release scrollbar thumb or arrow buttons
		if tb.scrollbar then
			if tb.scrollbar.thumb.isDragging and tb.scrollbar.thumb.focusTouchId == matchId then
				tb.scrollbar.thumb.isDragging   = false
				tb.scrollbar.thumb.focusTouchId = nil
			end
			if tb.scrollbar.upBtn   then tb.scrollbar.upBtn.isActive   = false end
			if tb.scrollbar.downBtn then tb.scrollbar.downBtn.isActive = false end
		end

		-- Release content drag and seed physics
		if tb.scroll.isDragging then
			tb.scroll.isDragging = false
			local minOff, maxOff = _getScrollLimits(tb)

			if tb.scroll.offsetY < minOff or tb.scroll.offsetY > maxOff then
				tb.scroll.phase = "bouncing"
			elseif math.abs(tb.scroll.velocityY) > COAST_STOP_VEL then
				tb.scroll.phase = "coasting"
			else
				tb.scroll.phase     = "idle"
				tb.scroll.velocityY = 0
			end
		end

	end
end


-- ---------------------------------------------------------------------------
--  TEXT UPDATE
-- ---------------------------------------------------------------------------

function gdsGui_outputTxtBox_setText(name, text)
	for _, box in ipairs(globApp.objects.outputTextBox) do
		if box.name == name then
			box.text.text = text
			break
		end
	end
end

-- Returns true once the named textbox has been scrolled to near its bottom
-- at least once (or if its content fits the frame without any scrolling).
function gdsGui_outputTxtBox_hasReachedBottom(name)
	for _, tb in ipairs(globApp.objects.outputTextBox) do
		if tb.name == name then
			return tb.scroll.hasReachedBottom
		end
	end
	return false
end

-- Resets the scroll position and the hasReachedBottom flag back to initial
-- state (used when the T&C page needs to be re-shown after a data wipe).
function gdsGui_outputTxtBox_resetScrollState(name)
	for _, tb in ipairs(globApp.objects.outputTextBox) do
		if tb.name == name then
			tb.scroll.hasReachedBottom = false
			tb.scroll.offsetY    = 0
			tb.scroll.velocityY  = 0
			tb.scroll.phase      = "idle"
			tb.scroll.isDragging = false
			tb.scroll._lastOffY  = nil  -- invalidate dirty flag so _apply_scroll_offset re-runs
			_apply_scroll_offset(tb)
			return
		end
	end
end
