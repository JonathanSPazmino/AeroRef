-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[tables.lua]]

-- spreadSheets = {}
globApp.objects.tables = {}
local recordErased = false
local TableCell_create
local determineSizeOfArray
local table_lookUp
local tablefuncCallbackToString

-- ---------------------------------------------------------------------------
--  MOMENTUM SCROLL PHYSICS CONSTANTS  (mirrors lib_outputTxtBox.lua values)
-- ---------------------------------------------------------------------------
local TBL_SCROLL_FRICTION  = 3.5
local TBL_SPRING_OMEGA     = 18.0
local TBL_SPRING_K         = TBL_SPRING_OMEGA * TBL_SPRING_OMEGA
local TBL_SPRING_C         = 2.0 * TBL_SPRING_OMEGA
local TBL_RUBBER_BAND      = 0.35
local TBL_COAST_STOP_VEL   = 8.0
local TBL_BOUNCE_STOP_DISP = 0.5
local TBL_BOUNCE_STOP_VEL  = 5.0
local TBL_AXIS_LOCK_PX     = 6.0   -- accumulated pixels before dominant axis is chosen

-- ---------------------------------------------------------------------------
--  PRIVATE HELPERS
-- ---------------------------------------------------------------------------

-- Vertical scroll limits: offsetY = 0 is natural top; minOff < 0 when content overflows.
local function _getTblScrollLimitsY(tbl)
	local minOff = math.min(0, tbl.scrollBox.height - tbl.combinedRowsHeight)
	return minOff, 0
end

-- Horizontal scroll limits.
local function _getTblScrollLimitsX(tbl)
	local minOff = math.min(0, tbl.scrollBox.width - tbl.combinedCollumnsWidth)
	return minOff, 0
end

-- Elastic rubber-band resistance past boundaries.
local function _applyTblRubberBand(offset, minOffset, maxOffset)
	if offset < minOffset then
		return minOffset + (offset - minOffset) * TBL_RUBBER_BAND
	elseif offset > maxOffset then
		return maxOffset + (offset - maxOffset) * TBL_RUBBER_BAND
	end
	return offset
end

-- Recompute every cell's screen position from its natural (unscrolled) position
-- plus the current scroll offsets.  Header row (row == 1) is X-scrolled only.
local function _applyTblScrollOffset(tbl)
	-- Update all cell screen positions first (always needed for correct rendering).
	for _, cl in ipairs(tbl.cells) do
		cl.x = cl.naturalX + tbl.scroll.offsetX
		if cl.row ~= 1 then
			cl.y = cl.naturalY + tbl.scroll.offsetY
		end
	end

	-- Rebuild the visible-cell cache only when offset or cell layout has changed.
	local sc = tbl.scroll
	local cellGen = tbl._cellGeneration or 0
	if sc._lastOffX == sc.offsetX and sc._lastOffY == sc.offsetY
	   and sc._lastCellGen == cellGen then
		return
	end
	sc._lastOffX    = sc.offsetX
	sc._lastOffY    = sc.offsetY
	sc._lastCellGen = cellGen

	-- Rebuild draw caches: header cells (fixed list) and visible data cells (y-culled).
	local vc = tbl.visibleCells
	local hc = tbl.headerCells
	if not vc then tbl.visibleCells = {}; vc = tbl.visibleCells end
	if not hc then tbl.headerCells  = {}; hc = tbl.headerCells  end
	for i = #vc, 1, -1 do vc[i] = nil end
	for i = #hc, 1, -1 do hc[i] = nil end
	local sbY    = tbl.scrollBox.y
	local sbYmax = sbY + tbl.scrollBox.height
	for _, cl in ipairs(tbl.cells) do
		if cl.row == 1 then
			hc[#hc + 1] = cl
		elseif cl.y + cl.height > sbY and cl.y < sbYmax then
			vc[#vc + 1] = cl
		end
	end
end

-- Push the current scroll offset back into the linked scrollbar positions.
local function _syncTblScrollbars(tbl)
	if tbl.combinedRowsHeight > tbl.scrollBox.height then
		local spanY = tbl.combinedRowsHeight - tbl.scrollBox.height
		local pos = math.max(0, math.min(1, -tbl.scroll.offsetY / spanY))
		local sb = tbl.verticalScrollBar.ref
		if sb then
			gdsGui_scrollBar_updatePosition(sb, pos)
			tbl.dataCurrentVertPosition = pos
		end
	end
	if tbl.combinedCollumnsWidth > tbl.scrollBox.width then
		local spanX = tbl.combinedCollumnsWidth - tbl.scrollBox.width
		local pos = math.max(0, math.min(1, -tbl.scroll.offsetX / spanX))
		local sb = tbl.horizontalScrollBar.ref
		if sb then
			gdsGui_scrollBar_updatePosition(sb, pos)
			tbl.dataCurrentHorzPosition = pos
		end
	end
end

local function _tblScrollToOrigin(tbl)
	if not tbl.scroll then return end
	tbl.scroll.offsetY   = 0
	tbl.scroll.offsetX   = 0
	tbl.scroll.velocityY = 0
	tbl.scroll.velocityX = 0
	tbl.scroll.phase     = "idle"
	tbl.scroll._lastOffX = nil  -- invalidate dirty flag so _applyTblScrollOffset re-runs
	tbl.scroll._lastOffY = nil
	tbl.dataCurrentVertPosition = 0
	tbl.dataCurrentHorzPosition = 0
	_applyTblScrollOffset(tbl)
	_syncTblScrollbars(tbl)
end

function gdsGui_table_scrollToOrigin(tableName)
	for _, tbl in ipairs(globApp.objects.tables) do
		if tbl.name == tableName then
			_tblScrollToOrigin(tbl)
			return
		end
	end
end

------------------------------------------------------------
			--OBJECT CREATION
------------------------------------------------------------
function gdsGui_table_create (spreadSheetName, strgPage, strgspreadSheetType, dataTable, myX, myY, tableWidth, tableHeight, anchorPoint, strgImgspreadSheetBg, tblCallbackFuncs, fontSize, headerTitles, hapticEnabled, containerName)

	local t = {}

	t.name = spreadSheetName
	t.page = strgPage
	t.objectType = "table"
	t.type = strgspreadSheetType
	t.hapticEnabled = (hapticEnabled == true)
	t.rowsCount = determineSizeOfArray (dataTable, "rows")
	t.collumnsCount = #headerTitles

	-- Store original properties for resize
	t.original = {
		x = myX,
		y = myY,
		width = tableWidth,
		height = tableHeight,
		aspectRatio = (tableHeight * globApp.safeScreenArea.h) / (tableWidth * globApp.safeScreenArea.w),
		anchorPoint = anchorPoint,
		fontSize = fontSize,
		headerTitles = headerTitles,
		tblCallbackFuncs = tblCallbackFuncs,
		dataTable = dataTable
	}

	t.fonts = {
		title = { size = 12, font = love.graphics.newFont(12) },
		headers = { size = 12, font = love.graphics.newFont(12) },
		cells = { size = 12, font = love.graphics.newFont(12) }
	}

	if strgImgspreadSheetBg ~= nil then
		t.imgSpreadSheetBg = love.graphics.newImage(strgImgspreadSheetBg)
	end

	-- Initialize all sub-tables
	t.frame, t.masks, t.titleBox, t.titleCaption, t.headersBox, t.scrollBox, t.buttons, t.cells, t.verticalScrollBar, t.horizontalScrollBar = {},{},{},{},{},{},{},{},{},{}

	-- This internal function calculates all geometry. It's called on creation and again on resize.
	local function calculate_geometry_and_layout(tbl)
		local original = tbl.original
		
		-- Recalculate frame
		local newDims = gdsGui_general_getScaledDimensions(original.width, original.height, original.aspectRatio)
		tbl.frame.width = newDims.width
		tbl.frame.height = newDims.height
		local framePositions = gdsGui_general_relativePosition(original.anchorPoint, original.x, original.y, tbl.frame.width, tbl.frame.height, globApp.safeScreenArea.x, globApp.safeScreenArea.y, globApp.safeScreenArea.w, globApp.safeScreenArea.h)
		tbl.frame.x = framePositions[1]
		tbl.frame.y = framePositions[2]

		-- ADDED: Recalculate masks
		tbl.masks = {}
		tbl.masks.properties = {}
		tbl.masks.properties.color = globApp.appColor
		tbl.masks.top = {
			x = globApp.safeScreenArea.x,
			y = globApp.safeScreenArea.y,
			width = globApp.safeScreenArea.w,
			height = tbl.frame.y - globApp.safeScreenArea.y
		}
		tbl.masks.left = {
			x = globApp.safeScreenArea.x,
			y = globApp.safeScreenArea.y + tbl.masks.top.height,
			width = tbl.frame.x - globApp.safeScreenArea.x,
			height = tbl.frame.height
		}
		tbl.masks.right = {
			x = tbl.frame.x + tbl.frame.width,
			y = globApp.safeScreenArea.y + tbl.masks.top.height,
			width = (globApp.safeScreenArea.x + globApp.safeScreenArea.w) - (tbl.frame.x + tbl.frame.width),
			height = tbl.frame.height
		}
		tbl.masks.bottom = {
			x = globApp.safeScreenArea.x,
			y = tbl.frame.y + tbl.frame.height,
			width = globApp.safeScreenArea.w,
			height = (globApp.safeScreenArea.y + globApp.safeScreenArea.h) - (tbl.frame.y + tbl.frame.height)
		}

		-- Other base properties
		tbl.rowHeight = tbl.fonts.cells.size + (tbl.fonts.cells.size * .4)
		tbl.displayWidth = tbl.frame.width
		tbl.displayHeight = original.height * globApp.safeScreenArea.h

		-- Recalculate Buttons
        tbl.buttons = {}
        tbl.callbackFuncNames = {}
		local iterator1 = 0
		for i=1, #original.tblCallbackFuncs, 1 do
			local index = ""
			for j, cb in pairs(original.tblCallbackFuncs[i]) do
				index = j
				iterator1 = iterator1 + 1
				tbl.callbackFuncNames[index] = cb
				tbl.buttons[index] = {
					text = index,
					x = tbl.frame.x + (iterator1 * (tbl.displayWidth / #original.tblCallbackFuncs)) - (tbl.displayWidth / #original.tblCallbackFuncs),
					y = tbl.frame.y + tbl.displayHeight - tbl.rowHeight,
					width = tbl.displayWidth / #original.tblCallbackFuncs,
					height = tbl.rowHeight,
					isFocused = false
				}
			end
		end

		-- Recalculate Boxes
		tbl.titleBox = { x = tbl.frame.x, y = tbl.frame.y, width = tbl.frame.width, height = tbl.fonts.title.size * 1.3 }
		tbl.titleCaption = { x = tbl.titleBox.x + (tbl.titleBox.width * .1), y = tbl.titleBox.y + (tbl.titleBox.height * .1), wrapWidth = tbl.titleBox.width * 0.8}
		tbl.headersBox = { x = tbl.titleBox.x, y = tbl.titleBox.y + tbl.titleBox.height, w = tbl.titleBox.width, h = 0 }

		-- Recalculate column width
		tbl.minCollumnWidth = tbl.fonts.cells.size * 10
		tbl.maxCollumnWidth = tbl.frame.width - tbl.fonts.cells.size
		if tbl.collumnsCount == 1 then
			tbl.collumWidth = tbl.frame.width - tbl.fonts.cells.size
		else
			tbl.collumWidth = ((tbl.frame.width - tbl.fonts.cells.size) / tbl.collumnsCount)
			if tbl.collumWidth < tbl.minCollumnWidth then tbl.collumWidth = tbl.minCollumnWidth end
		end
		tbl.textWrapCellPercentWidth = tbl.collumWidth * 0.8
		
		-- On resize, we must recalculate cell positions. Recreating them is the safest way to implement this now.
		tbl.cells = {}
		tbl._cellGeneration = (tbl._cellGeneration or 0) + 1
		local headerData = original.headerTitles
		local dataTable = original.dataTable
		local allTblHeaders = {}
		for i=1, #dataTable, 1 do allTblHeaders[i] = dataTable[i]["ID"] end
		
		-- Header cell height: lines needed for header text + one font-size of padding on each side
		local headerLineCount = math.max(1, gdsGui_findMaxNumOfLinesNeeded(tbl.fonts.headers.font, tbl.textWrapCellPercentWidth, headerData))
		local actualHeaderFontHeight = gdsGui_general_returnFontInfo(tbl.fonts.headers.font, "height")
		tbl.headersBox.h = (actualHeaderFontHeight * headerLineCount) + (2 * tbl.fonts.headers.size)

		-- Data cell height: sized for the widest data row content only
		local maxDataLineCount = 1
		local actualCellFontHeight = gdsGui_general_returnFontInfo(tbl.fonts.cells.font, "height")
		for i = 1, tbl.rowsCount, 1 do
			local textTable = {}
			for z=1, #headerData, 1 do textTable[z] = table_lookUp(dataTable, i, headerData[z]) end
			maxDataLineCount = math.max(maxDataLineCount, gdsGui_findMaxNumOfLinesNeeded(tbl.fonts.cells.font, tbl.textWrapCellPercentWidth, textTable))
		end
		tbl.uniformCellHeight = (actualCellFontHeight * maxDataLineCount) * (1 + 0.30)
		
		local cellPositions = {w = tbl.collumWidth}
		local previewsRowY, previewsRowH = tbl.headersBox.y, tbl.headersBox.h
		tbl.combinedRowsHeight = 0
		for i = 1, tbl.rowsCount + 1, 1 do
			for j = 1, #headerData , 1 do
				cellPositions.x = tbl.frame.x - tbl.collumWidth + (tbl.collumWidth * j)
				if i == 1 then
					cellPositions.y, cellPositions.h = tbl.headersBox.y, tbl.headersBox.h
					TableCell_create((i..","..j), cellPositions.x, cellPositions.y, cellPositions.w, cellPositions.h, i, j, headerData[j], false, tbl.cells, "HEADER")
				else
					if j == 1 then
						cellPositions.y = (previewsRowY + previewsRowH)
						cellPositions.h = tbl.uniformCellHeight
						previewsRowY, previewsRowH = cellPositions.y, cellPositions.h
						tbl.combinedRowsHeight = tbl.combinedRowsHeight + cellPositions.h
					end
					TableCell_create((i..","..j), cellPositions.x, cellPositions.y, cellPositions.w, cellPositions.h, i, j, table_lookUp(dataTable, i-1, headerData[j]), true, tbl.cells, allTblHeaders[i-1])
				end
			end
		end

		-- Recalculate ScrollBox (depends on final header height)
		tbl.scrollBox = {
			x = tbl.frame.x,
			y = tbl.frame.y + tbl.titleBox.height + tbl.headersBox.h,
			width = tbl.frame.width - tbl.fonts.cells.size,
			height = (tbl.displayHeight - ( (tbl.frame.y + tbl.titleBox.height + tbl.headersBox.h) - tbl.frame.y)) - (tbl.rowHeight * 2)
		}

		-- Scrollbar positions as fractions of safe area; sizes as direct pixel values (DIP).
		-- Subtract safeScreenArea.y/x before dividing so the scrollbar creation code does not
		-- double-add the safe-area offset on mobile (iOS/Android add it back internally).
		tbl.verticalScrollBar = {
			name = tbl.name .. "_vsb",
			x = (tbl.frame.x + tbl.frame.width - tbl.fonts.cells.size) / globApp.safeScreenArea.w,
			y = (tbl.scrollBox.y - globApp.safeScreenArea.y) / globApp.safeScreenArea.h,
			width = tbl.fonts.cells.size,
			height = tbl.scrollBox.height,
			ref = tbl.verticalScrollBar and tbl.verticalScrollBar.ref
		}
		tbl.horizontalScrollBar = {
			name = tbl.name .. "_hsb",
			x = tbl.frame.x / globApp.safeScreenArea.w,
			y = (tbl.scrollBox.y + tbl.scrollBox.height - globApp.safeScreenArea.y) / globApp.safeScreenArea.h,
			width = tbl.scrollBox.width,
			height = tbl.rowHeight,
			ref = tbl.horizontalScrollBar and tbl.horizontalScrollBar.ref
		}

		if tbl.rowsCount > 0 then tbl.avrgRowHeight = tbl.combinedRowsHeight / tbl.rowsCount else tbl.avrgRowHeight = 1 end
		tbl.numRowsPerDisplay = tbl.scrollBox.height / tbl.avrgRowHeight
		tbl.combinedCollumnsWidth = tbl.collumnsCount * tbl.collumWidth
		if tbl.collumnsCount > 0 then tbl.avrgCollumnsWidht = tbl.collumWidth else tbl.avrgCollumnsWidht = 1 end
		tbl.numCollumnsPerDisplay = tbl.scrollBox.width / tbl.collumWidth

		-- Initialise (or re-clamp on resize) the momentum scroll state.
		if not tbl.scroll then
			tbl.scroll = {
				offsetY           = 0,
				velocityY         = 0,
				offsetX           = 0,
				velocityX         = 0,
				phase             = "idle",
				isDragging        = false,
				touchStartedInside = false,
				axisLock          = nil,
				accumDx           = 0,
				accumDy           = 0,
			}
		else
			-- Clamp preserved offset to new geometry, reset physics.
			local minY, _ = _getTblScrollLimitsY(tbl)
			local minX, _ = _getTblScrollLimitsX(tbl)
			tbl.scroll.offsetY           = math.max(minY, math.min(0, tbl.scroll.offsetY))
			tbl.scroll.offsetX           = math.max(minX, math.min(0, tbl.scroll.offsetX))
			tbl.scroll.velocityY         = 0
			tbl.scroll.velocityX         = 0
			tbl.scroll.phase             = "idle"
			tbl.scroll.isDragging        = false
			tbl.scroll.touchStartedInside = false
			tbl.scroll.axisLock          = nil
			tbl.scroll.accumDx           = 0
			tbl.scroll.accumDy           = 0
		end
		_applyTblScrollOffset(tbl)
	end

	-- NEW: The resize method for this object
    function t:resize()
        calculate_geometry_and_layout(self)
        local vsb = self.verticalScrollBar.ref
        if vsb then
            vsb.original.x, vsb.original.y, vsb.original.width, vsb.original.height = self.verticalScrollBar.x, self.verticalScrollBar.y, self.verticalScrollBar.width, self.verticalScrollBar.height
            if vsb.resize then vsb:resize() end
        end
        local hsb = self.horizontalScrollBar.ref
        if hsb then
            hsb.original.x, hsb.original.y, hsb.original.width, hsb.original.height = self.horizontalScrollBar.x, self.horizontalScrollBar.y, self.horizontalScrollBar.width, self.horizontalScrollBar.height
            if hsb.resize then hsb:resize() end
        end
    end
    t.resize = t.resize

	-- Run initial calculations
	calculate_geometry_and_layout(t)

	t.dataCurrentVertPosition, t.dataCurrentHorzPosition, t.state = 0.0, 0.0, 1

	table.insert(globApp.objects.tables, t)
	globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
	if containerName then
		gdsGui_container_addObject(containerName, "table", spreadSheetName)
	end

	-- Create the scrollbar objects
	gdsGui_scrollBar_create (t.verticalScrollBar.name, t.page, t.verticalScrollBar.x, t.verticalScrollBar.y, t.verticalScrollBar.width, t.verticalScrollBar.height, "LT", t.numRowsPerDisplay, t.rowsCount, t.dataCurrentVertPosition, "table-linked", "vertical", 30, "gdsGui_table_scrollbarVertCallback")
	gdsGui_scrollBar_create (t.horizontalScrollBar.name, t.page, t.horizontalScrollBar.x, t.horizontalScrollBar.y, t.horizontalScrollBar.width, t.horizontalScrollBar.height, "LT", t.numCollumnsPerDisplay, t.collumnsCount, t.dataCurrentHorzPosition, "table-linked", "horizontal", 30, "gdsGui_table_scrollbarHorzCallback")

	-- Cache direct refs so _syncTblScrollbars and resize avoid O(n) search every frame
	for _, sb in ipairs(globApp.objects.scrollBars) do
		if sb.id == t.verticalScrollBar.name then
			t.verticalScrollBar.ref = sb
		elseif sb.id == t.horizontalScrollBar.name then
			t.horizontalScrollBar.ref = sb
		end
	end
end


function gdsGui_table_setData(name, dataTable)
	for _, t in ipairs(globApp.objects.tables) do
		if t.name == name then
			t.original.dataTable = dataTable
			t.rowsCount = determineSizeOfArray(dataTable, "rows")
			t:resize()
			_tblScrollToOrigin(t)
			return
		end
	end
end


-- function spreadSheet_delete (spreadSheetName,strgPage)

-- 	for i = #spreadSheets,1,-1 do

-- 		local spreadSheet = spreadSheets[i]

-- 		--LOAD PROJECT:

-- 			if spreadSheet.name == spreadSheetName and spreadSheet.page == strgPage then

-- 				table.remove(spreadSheets,i)

-- 				globApp.numObjectsDisplayed = globApp.numObjectsDisplayed - 1

-- 			end

-- 	end
-- end

function gdsGui_table_draw (pageName)

	-- local activePageName = 0

	-- for i, pgs in ipairs (pages) do
	-- 	if pgs.index == globApp.currentPageIndex then
	-- 		activePageName = pageName
	-- 	end
	-- end

	-- local spreadSheetExists = false


	-- if activePageName == strgPage then --[[compares object pg to current page]]

		-- if spreadSheetExists == false then --[[runs once]]

		-- 	gdsGui_table_create (spreadSheetName, strgPage, strgspreadSheetType, dataTable, myX, myY, tableWidth, tableHeight, anchorPoint, strgImgspreadSheetBg, tblCallbackFuncs, fontSize, headerTitles)

		-- elseif spreadSheetExists == true and (globApp.resizeDetected == true or globApp.projectsTblChanged == true) then --[[updates only if window is resized]]

		-- if globApp.projectAvailable == false then
		-- -- 	spreadSheet_update(spreadSheetName, strgPage, strgspreadSheetType, dataTable, myX, myY, tableWidth, tableHeight, anchorPoint, strgImgspreadSheetBg, tblCallbackFuncs, fontSize, headerTitles)
		-- -- else  
		-- 	gdsGui_page_switch ("LoadingMainMenu", 3, 2, false)
		-- end
		-- 	globApp.projectsTblChanged = false

		-- -- end

		for i,x in ipairs(globApp.objects.tables) do --[[draws table]]

			if x.page == pageName then

				if x.state == 0  then
					
				elseif x.state == 1  then

					--TABLE FONT SIZE
					love.graphics.setFont(x.fonts.cells.font)

					--TABLE TOTAL BG AREA
					love.graphics.setColor(.3, .3, .3, 1)
					love.graphics.rectangle("fill", x.titleBox.x, x.titleBox.y, x.displayWidth, x.displayHeight)

					--SCROLLABLE SPACE
					love.graphics.setColor(0, 0, 0, 1)
					love.graphics.rectangle("fill", x.scrollBox.x, x.scrollBox.y, x.scrollBox.width, x.scrollBox.height)

					--CELLS:
					local _vc = x.visibleCells or x.cells
					for j, cells in ipairs(_vc) do

						if cells.focused == false then

							love.graphics.setColor(.5, .5, .5, 1)
							love.graphics.rectangle("line", cells.x, cells.y, cells.width, cells.height)

							love.graphics.setColor(1, 1, 1, 1)
							love.graphics.printf(cells.content, cells.x + (cells.width * 0.05), cells.y + (cells.height * 0.05), (cells.width * 0.95), "center")

						elseif cells.focused == true then

							love.graphics.setColor(0, 1, 0, 1)
							love.graphics.rectangle("fill", cells.x, cells.y, cells.width, cells.height)

							love.graphics.setColor(1, 0, 0, 1)
							love.graphics.printf(cells.content, cells.x + (cells.width * 0.05), cells.y + (cells.height * 0.05), (cells.width * 0.95), "center")

						end

					end

					--TITLE:

					love.graphics.setFont(x.fonts.title.font)
					love.graphics.setColor(.2, .2, .2, 1)
					love.graphics.rectangle("fill", x.titleBox.x, x.titleBox.y, x.titleBox.width , x.titleBox.height)--[[title rectangle]]

					love.graphics.setColor(1, 1, 1, 1)
					
					love.graphics.printf(x.name, x.titleCaption.x, x.titleCaption.y, x.titleCaption.wrapWidth, "center") --[[Title text]]

					--HEADERS
					love.graphics.setFont(x.fonts.headers.font)

					local _hc = x.headerCells or x.cells
					for j, cells in ipairs(_hc) do

						love.graphics.setColor(.3, .3, .3, 1)
						love.graphics.rectangle("fill", cells.x, cells.y, cells.width, cells.height)

						love.graphics.setColor(0, 1, 0, 1)
						love.graphics.printf(cells.content, cells.x + (cells.width * 0.05), cells.y + (cells.height * 0.05), (cells.width * 0.95), "center")

					end
					

					--[[TABLE BUTTONS]]
					for j, bt in pairs (x.buttons) do

						if bt.isFocused == true then
							love.graphics.setColor(0, 1, 1, 1)
							love.graphics.rectangle("fill", bt.x, bt.y, bt.width, bt.height)
							love.graphics.setColor(1, 0, 0, 1)
						else
							love.graphics.setColor(.3, .3, .3, 1)
							love.graphics.rectangle("fill", bt.x, bt.y, bt.width, bt.height)
							love.graphics.setColor(1, 1, 1, 1)
						end
						love.graphics.printf(bt.text, bt.x + (bt.width * .1), bt.y + (bt.height * 0.1), (bt.width * 0.8), "center")
						love.graphics.setColor(1, 1, 1, 1)

					end




					--MASKS (skipped for container-owned tables; the container provides clipping):
						if not x.ownerContainer then
							love.graphics.setColor(globApp.appColor[1], globApp.appColor[2], globApp.appColor[3], globApp.appColor[4])
							--TOP
							love.graphics.rectangle("fill", x.masks.top.x, x.masks.top.y, x.masks.top.width, x.masks.top.height, rx, ry, segments)
							--LEFT
							love.graphics.rectangle("fill", x.masks.left.x, x.masks.left.y, x.masks.left.width, x.masks.left.height, rx, ry, segments)
							--RIGHT
							love.graphics.rectangle("fill", x.masks.right.x, x.masks.right.y, x.masks.right.width, x.masks.right.height, rx, ry, segments)
							--BOTTOM
							love.graphics.rectangle("fill", x.masks.bottom.x, x.masks.bottom.y, x.masks.bottom.width, x.masks.bottom.height, rx, ry, segments)
						end

						love.graphics.setColor(1, 1, 1, 1)

					--UNSAFE AREA MASKS:
						love.graphics.setColor(0,0,0,1)
						--TOP
						love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), globApp.safeScreenArea.y, rx, ry, segments)
						--LEFT
						love.graphics.rectangle("fill", 0, 0, globApp.safeScreenArea.x, love.graphics.getHeight(), rx, ry, segments)
						-- --RIGHT
						love.graphics.rectangle("fill", globApp.safeScreenArea.xw, 0, (love.graphics.getWidth()-globApp.safeScreenArea.xw), love.graphics.getHeight(), rx, ry, segments)
						-- --BOTTOM
						love.graphics.rectangle("fill", 0, globApp.safeScreenArea.yh, love.graphics.getWidth(), (love.graphics.getHeight()-globApp.safeScreenArea.yh), rx, ry, segments)

						love.graphics.setColor(1, 1, 1, 1)

				end

			end
	    end

	-- elseif activePageName ~= strgPage  then--[[compares object pg to current page]]
 
	 	-- if spreadSheetExists == true then
			
		-- 	spreadSheet_delete (spreadSheetName, strgPage)
		-- 	scrollBar_delete ((spreadSheetName.. "_hsb"), strgPage)
		-- 	scrollBar_delete ((spreadSheetName.. "_vsb"), strgPage)

		-- end
	
	-- end	
end

TableCell_create = function (name, x, y, width, height, myRow, myCollumn, content, scrollable, addTo, recordID)

	local newCell = {}

		newCell.recordID = recordID
		newCell.name = name
		newCell.x = x
		newCell.y = y
		newCell.naturalX = x   -- unscrolled reference position
		newCell.naturalY = y
		newCell.row = myRow
		newCell.collumn = myCollumn
		newCell.width = width
		newCell.height = height
		newCell.content = content
		newCell.focused = false
		newCell.scrollable = scrollable

		table.insert(addTo, newCell)
end

determineSizeOfArray = function (myArray, resultType)
	--[[returns table with 1) #rows, 2) #collums, 3) #dimensions, 4) #dataPicies]]

	--[[PARAMETERS:

		myArray ----------------Table/Array ----------------any 1d or 2d array
		resultType --------------string --------------------required result, choose from
															rows, collums, dimensions, dataCount or info.

	]]


	local resultArray = {}
	local arrayRows = 0
	local arrayCollums = 0
	local arrayDimensions = 0
	local arrayPicesOfData = 0
	local maxCollumFinder = 0

	if myArray ~= nil then

		if #myArray > 0 then --[[checks if the first dimension exists]]

			arrayDimensions = arrayDimensions + 1 --[[adds one to dimensions counter]]

		end

		for i, rows in pairs (myArray) do

			arrayRows = arrayRows + 1

			arrayCollums = 0

			if type(rows) == "table" then

				for j, collums in pairs (rows) do

						arrayCollums = arrayCollums + 1

						if arrayCollums > maxCollumFinder then --[[finds the max number of collums]]

							maxCollumFinder = arrayCollums

						end

						if arrayCollums >= 1 then --[[checks if the second dimension exists]]

							arrayDimensions = 2

						end

					arrayPicesOfData = arrayPicesOfData + 1

				end

			end

		end

		arrayCollums = maxCollumFinder

	elseif myArray == nil then

		local errorMessage = "Table does not exist"
		arrayRows = errorMessage
		arrayCollums = errorMessage
		arrayDimensions = errorMessage
		arrayPicesOfData = errorMessage

	end

	resultArray[1] = arrayRows
	resultArray[2] = arrayCollums
	resultArray[3] = arrayDimensions
	resultArray[4] = arrayPicesOfData


	if resultType == "rows" then

		return resultArray[1]

	elseif resultType == "collums" then

		return resultArray[2]

	elseif resultType == "dimensions" then

		return resultArray[3]

	elseif resultType == "dataCount" then

		return resultArray[4]

	elseif resultType == "info" and myArray ~= nil then

		print ("Array info: " .. resultArray[1] .. " rows, " .. resultArray[2] .. " collums, " .. resultArray[3] .. " dimensions, and " .. resultArray[4].. " pieces of data")

	end
end

table_lookUp = function (array, rcrdIndex, header)
	--[[returns specified value based grid coordinates. returns empty if no value was found at coordinates]]

	local cellContent = "empty"
	local counters = {}

	counters.row = 0 

	for i=1, #array, 1 do

		counters.row = counters.row + 1 
		counters.collum = 0

		if type(array[i]) == "table" then

			for j, data in pairs (array[i])do
				counters.collum = counters.collum + 1 
					
				if rcrdIndex == counters.row and j == header then

					local preFormatCellContent = array[i][header]
					local postFormatCellContent = ""
					if type(preFormatCellContent) == "table" then
						for indx, val in ipairs (preFormatCellContent) do
							if indx == 1 then
								postFormatCellContent = val
							else
								postFormatCellContent = (postFormatCellContent .. ", " .. val)
							end
							
						end
					else
						postFormatCellContent = preFormatCellContent
					end
					cellContent = postFormatCellContent

				end
			
			end

		end

	end
					
	return cellContent
end

-- Called from gdsGui_general_touchmoved and gdsGui_general_mousemoved.
-- Applies rubber-band drag and accumulates velocity for momentum physics.
function gdsGui_table_touchScroll (id, x, y, dx, dy, pressure, button, istouch)
	-- Accept both touch-slide and mouse-button-held drags.
	local isGestureActive = (globApp.userInput == "slide") or love.mouse.isDown(1)
	if not isGestureActive then return end

	local activePage = gdsGui_page_currentName()
	for _, tbl in ipairs(globApp.objects.tables) do
		if not tbl.scroll then goto continue end
		if tbl.page ~= activePage then goto continue end

		-- Only act when pointer is inside the scrollable area AND the touch/drag
		-- originated inside it (prevents dragging from outside into the scroll area).
		if x >= tbl.scrollBox.x and x <= (tbl.scrollBox.x + tbl.scrollBox.width) and
		   y >= tbl.scrollBox.y and y <= (tbl.scrollBox.y + tbl.scrollBox.height) and
		   tbl.scroll.touchStartedInside then

			-- First frame of a new drag: reset axis detection accumulators.
			if not tbl.scroll.isDragging then
				tbl.scroll.axisLock = nil
				tbl.scroll.accumDx  = 0
				tbl.scroll.accumDy  = 0
			end

			tbl.scroll.isDragging = true
			tbl.scroll.phase      = "coasting"  -- arms physics for release

			-- Accumulate raw movement until a dominant axis can be chosen.
			if not tbl.scroll.axisLock then
				tbl.scroll.accumDx = tbl.scroll.accumDx + math.abs(dx)
				tbl.scroll.accumDy = tbl.scroll.accumDy + math.abs(dy)
				if tbl.scroll.accumDx + tbl.scroll.accumDy >= TBL_AXIS_LOCK_PX then
					if tbl.scroll.accumDx >= tbl.scroll.accumDy then
						tbl.scroll.axisLock = "horizontal"
					else
						tbl.scroll.axisLock = "vertical"
					end
				end
			end

			local allowV = (tbl.scroll.axisLock == nil) or (tbl.scroll.axisLock == "vertical")
			local allowH = (tbl.scroll.axisLock == nil) or (tbl.scroll.axisLock == "horizontal")

			local frameDt = globApp.lastDt or 0

			-- VERTICAL
			local minY, maxY = _getTblScrollLimitsY(tbl)
			local prevInBoundsY = (tbl.scroll.offsetY >= minY and tbl.scroll.offsetY <= maxY)
			if allowV and minY < -0.5 then  -- content taller than viewport
				tbl.scroll.offsetY = _applyTblRubberBand(tbl.scroll.offsetY + dy, minY, maxY)
				if frameDt > 0 then
					local rawVelY = dy / frameDt
					tbl.scroll.velocityY = tbl.scroll.velocityY * 0.5 + rawVelY * 0.5
				end
			end

			-- HORIZONTAL
			local minX, maxX = _getTblScrollLimitsX(tbl)
			if allowH and minX < -0.5 then  -- content wider than viewport
				tbl.scroll.offsetX = _applyTblRubberBand(tbl.scroll.offsetX + dx, minX, maxX)
				if frameDt > 0 then
					local rawVelX = dx / frameDt
					tbl.scroll.velocityX = tbl.scroll.velocityX * 0.5 + rawVelX * 0.5
				end
			end

			-- Fire haptic once when the vertical scroll boundary is first crossed (top/bottom only).
			if tbl.hapticEnabled then
				local nowOutY = tbl.scroll.offsetY < minY or tbl.scroll.offsetY > maxY
				if prevInBoundsY and nowOutY then
					gdsGui_haptics_vibrate()
				end
			end

			_applyTblScrollOffset(tbl)
			_syncTblScrollbars(tbl)
			break
		end
		::continue::
	end
end

-- Called from gdsGui_general_touchreleased and gdsGui_general_mousereleased.
-- Seeds the correct physics phase from accumulated drag velocity.
function gdsGui_table_touchReleasedScroll (x, y)
	for _, tbl in ipairs(globApp.objects.tables) do
		if tbl.scroll then
			tbl.scroll.touchStartedInside = false  -- reset so next press re-evaluates origin
		end
		if tbl.scroll and tbl.scroll.isDragging then
			tbl.scroll.isDragging = false

			-- Kill velocity on the axis that was not scrolled.
			if tbl.scroll.axisLock == "vertical" then
				tbl.scroll.velocityX = 0
			elseif tbl.scroll.axisLock == "horizontal" then
				tbl.scroll.velocityY = 0
			end
			tbl.scroll.axisLock = nil
			tbl.scroll.accumDx  = 0
			tbl.scroll.accumDy  = 0

			local minY, maxY = _getTblScrollLimitsY(tbl)
			local minX, maxX = _getTblScrollLimitsX(tbl)

			local outOfBoundsY = tbl.scroll.offsetY < minY or tbl.scroll.offsetY > maxY
			local outOfBoundsX = tbl.scroll.offsetX < minX or tbl.scroll.offsetX > maxX

			if outOfBoundsY or outOfBoundsX then
				tbl.scroll.phase = "bouncing"
			elseif math.abs(tbl.scroll.velocityY) > TBL_COAST_STOP_VEL or
			       math.abs(tbl.scroll.velocityX) > TBL_COAST_STOP_VEL then
				tbl.scroll.phase = "coasting"
			else
				tbl.scroll.phase     = "idle"
				tbl.scroll.velocityY = 0
				tbl.scroll.velocityX = 0
			end
		end
	end
end

-- Called every frame from gdsGui_update(dt). Runs coasting and spring-back physics.
function gdsGui_table_physicsUpdate (dt)
	if not dt or dt <= 0 then return end

	local activePage = gdsGui_page_currentName()
	for _, tbl in ipairs(globApp.objects.tables) do
		if not tbl.scroll then goto continue end
		if tbl.page ~= activePage then goto continue end
		if tbl.scroll.isDragging or tbl.scroll.phase == "idle" then goto continue end

		local minY, maxY = _getTblScrollLimitsY(tbl)
		local minX, maxX = _getTblScrollLimitsX(tbl)
		local changed = false

		if tbl.scroll.phase == "coasting" then
			-- Exponential friction on both axes.
			local decay = math.exp(-TBL_SCROLL_FRICTION * dt)
			tbl.scroll.velocityY = tbl.scroll.velocityY * decay
			tbl.scroll.velocityX = tbl.scroll.velocityX * decay
			tbl.scroll.offsetY   = tbl.scroll.offsetY + tbl.scroll.velocityY * dt
			tbl.scroll.offsetX   = tbl.scroll.offsetX + tbl.scroll.velocityX * dt
			changed = true

			-- Clamp X at its hard limits so reaching the horizontal edge doesn't
			-- kill vertical momentum; Y overscroll still triggers spring-back.
			local outX = tbl.scroll.offsetX < minX or tbl.scroll.offsetX > maxX
			if outX then
				tbl.scroll.offsetX   = math.max(minX, math.min(maxX, tbl.scroll.offsetX))
				tbl.scroll.velocityX = 0
			end

			local outY = tbl.scroll.offsetY < minY or tbl.scroll.offsetY > maxY
			if outY then
				tbl.scroll.phase = "bouncing"
			elseif math.abs(tbl.scroll.velocityY) < TBL_COAST_STOP_VEL and
			       math.abs(tbl.scroll.velocityX) < TBL_COAST_STOP_VEL then
				tbl.scroll.phase     = "idle"
				tbl.scroll.velocityY = 0
				tbl.scroll.velocityX = 0
			end

		elseif tbl.scroll.phase == "bouncing" then
			-- Critically-damped spring back to nearest boundary on each axis.
			local targetY   = math.max(minY, math.min(maxY, tbl.scroll.offsetY))
			local dispY     = tbl.scroll.offsetY - targetY
			local springAccY = (-TBL_SPRING_K * dispY) + (-TBL_SPRING_C * tbl.scroll.velocityY)
			tbl.scroll.velocityY = tbl.scroll.velocityY + springAccY * dt
			tbl.scroll.offsetY   = tbl.scroll.offsetY   + tbl.scroll.velocityY * dt

			local targetX   = math.max(minX, math.min(maxX, tbl.scroll.offsetX))
			local dispX     = tbl.scroll.offsetX - targetX
			local springAccX = (-TBL_SPRING_K * dispX) + (-TBL_SPRING_C * tbl.scroll.velocityX)
			tbl.scroll.velocityX = tbl.scroll.velocityX + springAccX * dt
			tbl.scroll.offsetX   = tbl.scroll.offsetX   + tbl.scroll.velocityX * dt
			changed = true

			-- Settle when displacement and velocity are negligible on both axes.
			local newDispY = math.abs(tbl.scroll.offsetY - targetY)
			local newDispX = math.abs(tbl.scroll.offsetX - targetX)
			if newDispY < TBL_BOUNCE_STOP_DISP and math.abs(tbl.scroll.velocityY) < TBL_BOUNCE_STOP_VEL and
			   newDispX < TBL_BOUNCE_STOP_DISP and math.abs(tbl.scroll.velocityX) < TBL_BOUNCE_STOP_VEL then
				tbl.scroll.offsetY   = targetY
				tbl.scroll.offsetX   = targetX
				tbl.scroll.velocityY = 0
				tbl.scroll.velocityX = 0
				tbl.scroll.phase     = "idle"
			end
		end

		if changed then
			_applyTblScrollOffset(tbl)
			_syncTblScrollbars(tbl)
		end
		::continue::
	end
end


function gdsGui_table_rowSelect (x,y,button,istouch)

	--isolate table
	local myTable = globApp.objects.tables
	local spreadSheetExist = false
	local totalCollums = 0
	local justATapOrClick = false

	--determine if it is just a tap or click
	if globApp.userInput == "left click" or globApp.userInput == "tap"then 
		--determine if there are spreadsheets available 
		for i, tbls in ipairs (myTable) do 

			if i > 0 then
				spreadSheetExist = true
			end

			totalRows = tbls.rowsCount
			totalCollums = tbls.collumnsCount

		end

		--skip code if no spreadsheet is present
		if spreadSheetExist == true then
			
			--identify touch or click within any cell

			for i, tbl in ipairs (myTable) do

				if gdsGui_page_currentName() == tbl.page then
					for j, cl in ipairs (tbl.cells) do

						if cl.row ~= 1 then

							--determine if touch was made within scrollable area
							if x >= tbl.scrollBox.x and x <= (tbl.scrollBox.x + tbl.scrollBox.width) and y >= tbl.scrollBox.y and y <= (tbl.scrollBox.y + tbl.scrollBox.height ) then

								if  y >= cl.y and y <= (cl.y + cl.height) and cl.focused == false then
									if cl.focused == false then
										cl.focused = true
									elseif cl.focused == true then
										cl.focused = false
									end

								else

								cl.focused = false

								end

							end

						end

					end
				end

			end

		end

	end
end


tablefuncCallbackToString = function (strgFuncCallBackName, parameters)

	--writes a string that corresponds to an executable function

	--create function strings
	local funcStrings = {}
	local fullStringPath = ""

	funcStrings[1] = (strgFuncCallBackName .. "(")

	fullStringPath = funcStrings[1]


	for i = 1, #parameters, 1 do

		if tonumber (parameters[i]) ~= nil then

			parameters[i] = tonumber (parameters[i])

		end

		if type(parameters[i]) == "string" then

			parameters[i] = ("\"" .. parameters[i] .. "\"")

		end

	end


	for i = 1, #parameters, 1 do

		if i ~= #parameters then
			funcStrings[i + 1] = tostring(parameters[i]) .. ","
		elseif i == #parameters then
			funcStrings[i + 1] = tostring(parameters[i]) .. ")"
		end

		fullStringPath = (fullStringPath .. funcStrings[i + 1])

	end

	return (fullStringPath)
end

function gdsGui_table_buttonsPressed (x,y,button,istouch)

	local myTable = globApp.objects.tables

	if button == 1 or globApp.userInput == "touch pressed" then
		for i, tbl in ipairs (myTable) do
			if gdsGui_page_currentName() == tbl.page then
				for j, bt in pairs (tbl.buttons) do
					if x >= bt.x and x <= (bt.x + bt.width) and y >= bt.y and y <= (bt.y + bt.height) then
						if bt.isFocused == false then
							bt.isFocused = true
						end
					end
				end
			end
		end
	end
end

function gdsGui_table_buttonsReleased (x,y,button,istouch)

	local myTable = globApp.objects.tables

	if button == 1 or globApp.userInput == "touch released" then
		for i, tbl in ipairs (myTable) do
			if gdsGui_page_currentName() == tbl.page then
				for j, bt in pairs (tbl.buttons) do
					if x >= bt.x and x <= (bt.x + bt.width) and y >= bt.y and y <= (bt.y + bt.height) then
						if bt.isFocused == true then

							local isDataSelected = false
							local selectedRow = {}
							local selectedRcrdID = ""
							local collumnIterator = 1
							local callBackId = tbl.callbackFuncNames[bt.text]
							local callBackParameters = {}
							local wasFunctionDeclared = false

							for k, cell in ipairs(tbl.cells) do
								if cell.focused == true and collumnIterator == 1 then
									isDataSelected = true
									selectedRcrdID = cell.recordID
									callBackParameters[1] = selectedRcrdID
									collumnIterator = collumnIterator + 1
								end
							end

							local func = callBackId

							if _G[func] then
							    wasFunctionDeclared = true
							else
								print ("Callback " .. callBackId .. " was NOT declared, for button " .. bt.text .. ", please declare one!")
							end

							if selectedRcrdID ~= "" and wasFunctionDeclared == true then
								_G[callBackId](table.unpack(callBackParameters))
							end
							bt.isFocused = false
						end
					end
				end
			end
		end
	end
end



function gdsGui_table_scrollbarVertCallback (position)
	for _, t in ipairs(globApp.objects.tables) do
		if t.state == 1 and t.scroll then
			if t.combinedRowsHeight > t.scrollBox.height then
				local spanY = t.combinedRowsHeight - t.scrollBox.height
				t.scroll.offsetY = -(spanY * position)
				t.scroll.velocityY = 0
				t.scroll.phase = "idle"
			end
			t.dataCurrentVertPosition = position
			_applyTblScrollOffset(t)
		end
	end
end


function gdsGui_table_scrollbarHorzCallback (position)
	for _, t in ipairs(globApp.objects.tables) do
		if t.state == 1 and t.scroll then
			if t.combinedCollumnsWidth > t.scrollBox.width then
				local spanX = t.combinedCollumnsWidth - t.scrollBox.width
				t.scroll.offsetX = -(spanX * position)
				t.scroll.velocityX = 0
				t.scroll.phase = "idle"
			end
			t.dataCurrentHorzPosition = position
			_applyTblScrollOffset(t)
		end
	end
end

function gdsGui_findMaxNumOfLinesNeeded (thisFont, wrapWidth, txt)
	local maxLineFound = 1

	if type(txt) == "table" then
		for i, txt in ipairs (txt) do
			local thisText = tostring(txt)
			local width, lines = thisFont:getWrap(thisText, wrapWidth)
			if #lines > maxLineFound then
				maxLineFound = #lines
			end
		end
	else
		local width, lines = thisFont:getWrap(tostring(txt), wrapWidth)
		if #lines > maxLineFound then

			maxLineFound = #lines
		end
	end
	return maxLineFound
end

