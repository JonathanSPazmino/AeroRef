-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[
    Library: schematic_gdsGuiLib.lua
    Author: Jonathan Pazmino
    Description: A free-form drawing canvas for building generic node/edge
                 "schematic" diagrams: typed elements (nodes), wires (edges
                 between two elements), and N-position controls.

                 This module is domain-agnostic by design (mirrors the rest of
                 the GUI library): it knows nothing about "generator" or
                 "pump" — only shapeType/label/position-names. The app layer
                 (main.lua) supplies aviation-specific catalog naming.

                 COLOR MODEL: elements/wires are NOT directly wired to a
                 control's color. Instead, every control's current position
                 across the whole canvas forms a "signature" (e.g.
                 "sw1=1,valve1=0"). A snapshot records, for one signature,
                 what color each element/wire should show. Live color
                 resolution looks up the current signature in canvas.snapshots
                 and falls back to the element/wire's defaultColor (gray) when
                 no snapshot exists yet for the current combination — i.e.
                 "the logic recreated" from prior snapshots. A live
                 per-element pendingColor (set via the in-canvas color picker)
                 previews a color before it's baked into a snapshot.

                 Not routed through container_gdsGuiLib.lua's per-objectType
                 layout dispatch (it only recognizes button/outputTextBox/
                 scrollBar/rotaryKnob) — the canvas is a standalone top-level
                 system wired directly into general_gdsGuiLib.lua's draw/
                 update/input dispatchers, the same integration level as
                 tables/outputTxtBox.
]]

--------------------------------------------------------------------------------
-- LIBRARY TABLE
--------------------------------------------------------------------------------

globApp.objects.schematics = {}

--------------------------------------------------------------------------------
-- PRIVATE CONSTANTS
--------------------------------------------------------------------------------

local _CONTROL_RADIUS_FRAC   = 0.045   -- control hit/draw radius, as a fraction of min(canvas.contentW, canvas.contentH)
local _GRID_SPACING_PX       = 24
local _MIN_ZOOM               = 1      -- fully zoomed out: the whole canvas box fits exactly in the viewport
local _MAX_ZOOM               = 4
-- Design/edit mode opens pre-zoomed to 2x (see gdsGui_schematic_resetView's
-- caller in main.lua) so the design surface reachable by panning is twice
-- the area of a single viewport-full, giving more room for elements. Pixel
-- size on screen is a function of (fraction size) * canvas.contentW * zoom, so
-- _ELEMENT_DEFAULT_*_FRAC below is halved from what it'd otherwise be to
-- keep a freshly-placed element the same on-screen size it would've been at
-- zoom 1 with the un-halved fraction — "more room, same-looking elements."
local _EDIT_MODE_INITIAL_ZOOM = 2
local _ELEMENT_DEFAULT_W_FRAC = 0.07
local _ELEMENT_DEFAULT_H_FRAC = 0.05
local _PINCH_MIN_DIST_PX      = 1      -- guards against a near-zero divisor right as a pinch begins
local _WIRE_WIDTH_PX         = 4 / 3   -- 2/3 of the previous 2px width
local _WIRE_CROSS_HOP_RADIUS_PX = 5   -- radius of the little arc hop drawn where a wire crosses an unrelated one
local _WIRE_PARALLEL_GAP_PX     = 5   -- spacing between adjacent lanes when 2+ wires' paths overlap (fully or partially)
local _WIRE_PARALLEL_STUB_PX    = 8   -- unsplit length kept right at each anchor before a parallel lane's offset begins
local _CONNECTOR_RELEASE_SLOP_PX = 16  -- forgiveness margin for "which element did the wire-drag land on", since exact-rectangle precision is unreliable on a touchscreen
local _CONNECTOR_TARGET_RADIUS_PX = 9  -- drawn radius of the green "valid connection point" reticle shown at each element's center while a wire is being dragged
local _CONNECTOR_SNAP_COLOR  = {0.25, 0.95, 0.35, 1}
local _DEFAULT_COLOR         = {0.75, 0.75, 0.75, 1}   -- light gray, matches the palette's LIGHT GRAY swatch
local _MENU_ROW_H            = 32
local _MENU_WIDTH_FRAC       = 0.8
local _ELEMENT_TAP_SLOP_PX   = 6   -- max press->release movement still counted as a tap, not a drag
local _LONG_PRESS_SECONDS    = 2.0 -- how long a held (not-yet-moved) press on an element/control/wire takes to unlock move/rotate/direction mode — see gdsGui_schematic_update
local _WIRE_TAP_SLOP_PX      = 10  -- max distance from a wire's drawn line still counted as tapping it
local _SWATCH_ROW_H_PX       = 64  -- height of the single row of color squares in a swatch picker
local _SWATCH_GAP_PX         = 8

-- shapeTypes whose icon is directional (e.g. a diode's anode/cathode arrow),
-- so it makes sense to spin it to one of the 4 cardinal orientations. Every
-- other shapeType ignores element.rotation entirely.
local _ROTATABLE_SHAPES      = { diode = true }

-- Small built-in named palette for the in-canvas color picker. Colors are a
-- generic concept (unlike element/control catalog naming), so this lives here
-- rather than in the app layer.
local _COLOR_PALETTE = {
    {name = "LIGHT GRAY", color = {0.75, 0.75, 0.75, 1}},
    {name = "RED",        color = {1, 0, 0, 1}},
    {name = "GREEN",      color = {0, 1, 0, 1}},
    {name = "LIGHT BLUE", color = {0.4, 0.8, 1, 1}},
    {name = "YELLOW",     color = {1, 1, 0, 1}},
}

--------------------------------------------------------------------------------
-- PRIVATE HELPERS
--------------------------------------------------------------------------------

local function _getActivePageName()
    for _, page in ipairs(pages) do
        if page.index == globApp.currentPageIndex then
            return page.name
        end
    end
    return ""
end

local function _findCanvas(canvasName)
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == canvasName then return c end
    end
    return nil
end

local function _findElement(canvas, id)
    for _, e in ipairs(canvas.elements) do
        if e.id == id then return e end
    end
    return nil
end

local function _findWire(canvas, id)
    for _, w in ipairs(canvas.wires) do
        if w.id == id then return w end
    end
    return nil
end

-- A second (or third, ...) wire drawn between the exact same two anchors is
-- a legitimate, common schematic pattern (it's exactly what the parallel-lane
-- bundling in _computeWirePlans exists to render distinctly) — but the
-- deterministic "<from>_to_<to>" id handed to it collides with the first
-- wire's id. Since _computeWirePlans and every other wire lookup key off
-- w.id as if it were unique, a collision doesn't just mis-render: it
-- silently overwrites the first wire's plan entry, so only one line is drawn
-- for however many wires actually share that id. Suffix with _2, _3, ... to
-- keep every wire's id actually unique.
local function _uniqueWireId(canvas, baseId)
    if not _findWire(canvas, baseId) then return baseId end
    local n = 2
    while _findWire(canvas, baseId .. "_" .. n) do n = n + 1 end
    return baseId .. "_" .. n
end

-- Keeps canvas._placementCounter from ever handing out an id that collides
-- with one already on the canvas. gdsGui_schematic_create seeds the counter
-- at 0 every time a canvas object is constructed (including after an app
-- restart, when a system's previously-saved elements/controls are reloaded
-- via addElement/addControl below) — without this, placing a new element
-- right after reload could mint the same "<idPrefix>_<n>" id a prior session
-- already used, and two elements sharing one id makes _findElement/
-- _findWire resolve ambiguously and removeElement/removeControl delete both.
local function _resyncPlacementCounter(canvas, id)
    local suffix = id and tostring(id):match("_(%d+)$")
    if suffix then
        canvas._placementCounter = math.max(canvas._placementCounter, tonumber(suffix))
    end
end

local function _findControl(canvas, id)
    for _, c in ipairs(canvas.controls) do
        if c.id == id then return c end
    end
    return nil
end

-- A wire/connector endpoint can be either an element (box) or a control
-- (rotary switch) — looks across both id namespaces, elements first.
local function _findAnchor(canvas, id)
    return _findElement(canvas, id) or _findControl(canvas, id)
end

local function _deepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = _deepCopy(v) end
    return copy
end

-- Multi-step "undo" support: snapshots elements/wires/controls onto a stack
-- right before a design-mode gesture mutates them, so each UNDO LAST ACTION
-- pops one step further back. Callers are the specific interactive gesture
-- handlers below/in the app layer, never the generic add/remove primitives
-- themselves — those are reused for bulk, non-undoable operations too
-- (loading a project, seeding the demo, tests).
-- Forward-declared: defined further down (PUBLIC API — DESIGN-MODE ELEMENT
-- PROPERTIES MENU / RENAME), but referenced by
-- gdsGui_schematic_internal_onElementEditChosen above that point.
local _openPropertiesMenu
local _openElementRenamePrompt

local _UNDO_STACK_MAX = 20

local function _snapshotState(canvas)
    return {
        elements  = _deepCopy(canvas.elements),
        wires     = _deepCopy(canvas.wires),
        controls  = _deepCopy(canvas.controls),
        snapshots = _deepCopy(canvas.snapshots),
    }
end

local function _commitUndoSnapshot(canvas, snapshot)
    table.insert(canvas._undoStack, snapshot)
    if #canvas._undoStack > _UNDO_STACK_MAX then
        table.remove(canvas._undoStack, 1)
    end
end

local function _pushUndo(canvas)
    _commitUndoSnapshot(canvas, _snapshotState(canvas))
end

-- Lets the app layer persist a system's work-in-progress as it's edited,
-- instead of only at page-navigation boundaries (see every call site below).
-- canvas.onChange is a callback name string, resolved the same way as every
-- other string-registered callback in this library (buttons, scrollbars,
-- textPrompt). Only fires in design mode — control-mode interaction (flipping
-- a switch to check colors) isn't an edit and shouldn't trigger a save.
local function _notifyChanged(canvas)
    if canvas.mode ~= "design" then return end
    if canvas.onChange then
        local fn = _G[canvas.onChange]
        if fn then fn(canvas.name) end
    end
end

-- Element and control labels share one naming namespace per canvas so a name
-- typed for a new element can't collide with an existing control's, or vice
-- versa — compared trimmed/case-insensitive so "Switch" and "switch" collide.
-- excludeKind/excludeId (optional) skip one element/control's own current
-- label — used when renaming, so keeping (or just re-casing) the same name
-- doesn't falsely collide with itself.
local function _labelInUse(canvas, label, excludeKind, excludeId)
    local needle = label:gsub("^%s*(.-)%s*$", "%1"):lower()
    for _, e in ipairs(canvas.elements) do
        if e.label and e.label:lower() == needle and not (excludeKind == "element" and e.id == excludeId) then
            return true
        end
    end
    for _, c in ipairs(canvas.controls) do
        if c.label and c.label:lower() == needle and not (excludeKind == "control" and c.id == excludeId) then
            return true
        end
    end
    return false
end

-- Suggests "TYPE_N" for the "name this element/control" prompt, where TYPE is
-- the catalog label (e.g. "GENERATOR") and N is one past the highest
-- "TYPE_<n>" name already on the canvas — the LAST element of that type's
-- number, plus 1, not a running total. So deleting some back down still
-- resumes after the highest survivor rather than reusing a freed number, and
-- a user who renamed their instances away from this pattern simply doesn't
-- count toward it.
local function _suggestedPlacementName(canvas, typeLabel)
    local pattern = "^" .. typeLabel:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1") .. "_(%d+)$"
    local maxN = 0
    for _, list in ipairs({canvas.elements, canvas.controls}) do
        for _, item in ipairs(list) do
            local n = item.label and item.label:match(pattern)
            if n then maxN = math.max(maxN, tonumber(n)) end
        end
    end
    return typeLabel .. "_" .. (maxN + 1)
end

-- Set while the "name this element/control" prompt is open after a design-mode
-- placement tap; holds everything gdsGui_schematic_placementNameConfirmed needs
-- to actually create the element/control once a valid, unique name is given.
local _pendingNamedPlacement = nil

local function _openPlacementNamePrompt(title, initialText)
    gdsGui_textPrompt_open(title, initialText, 24,
        "gdsGui_schematic_placementNameConfirmed", "gdsGui_schematic_placementNameCancelled")
end

-- Resolved by name via _G[...] from textPrompt_gdsGuiLib.lua, like every other
-- string-registered callback in this library.
function gdsGui_schematic_placementNameConfirmed(name)
    local pending = _pendingNamedPlacement
    if not pending then return end
    local canvas = _findCanvas(pending.canvasName)
    local trimmed = (name or ""):gsub("^%s*(.-)%s*$", "%1")
    if not canvas then return end
    if trimmed == "" then
        _openPlacementNamePrompt("NAME REQUIRED, TRY AGAIN", trimmed)
        return
    end
    if _labelInUse(canvas, trimmed) then
        _openPlacementNamePrompt("NAME TAKEN, TRY AGAIN", trimmed)
        return
    end
    if pending.kind == "element" then
        _pushUndo(canvas)
        local properties = {}
        for _, key in ipairs(pending.defaultPropertyKeys or {}) do
            table.insert(properties, { key = key, value = "" })
        end
        gdsGui_schematic_addElement(pending.canvasName, pending.newId, pending.shapeType,
            pending.fracX, pending.fracY, _ELEMENT_DEFAULT_W_FRAC, _ELEMENT_DEFAULT_H_FRAC,
            trimmed, pending.defaultColor, properties, nil, pending.spritePath)
        _notifyChanged(canvas)
    else
        _pushUndo(canvas)
        gdsGui_schematic_addControl(pending.canvasName, pending.newId, pending.fracX, pending.fracY,
            pending.positions, 0, trimmed, pending.callbackFunc, 1 / _EDIT_MODE_INITIAL_ZOOM, pending.spritePaths)
        _notifyChanged(canvas)
    end
    _pendingNamedPlacement = nil
end

function gdsGui_schematic_placementNameCancelled()
    _pendingNamedPlacement = nil
end

-- Keeps canvas.panX/panY inside the range that still leaves the zoomed
-- content fully covering the viewport (no empty margin past its edges).
-- At zoom == _MIN_ZOOM the range collapses to exactly {0,0} — i.e. panning
-- is a no-op until the user has actually zoomed in. Uses contentW/H (not
-- canvas.w/h) for the world size: the viewport can be wider than the
-- content's own per-zoom-unit basis (see _calculateGeometry), and it's the
-- content that must fully cover the viewport, not the other way around.
local function _clampPan(canvas)
    local worldW = canvas.contentW * canvas.zoom
    local worldH = canvas.contentH * canvas.zoom
    local minPanX = math.min(0, canvas.w - worldW)
    local minPanY = math.min(0, canvas.h - worldH)
    canvas.panX = math.max(minPanX, math.min(0, canvas.panX))
    canvas.panY = math.max(minPanY, math.min(0, canvas.panY))
end

-- (Re)compute all screen-space geometry for a canvas from its stored
-- fractional original values. Called once at creation, again on window
-- resize, and again on every zoom change.
--
-- Two distinct notions of "size" live on the canvas:
--   canvas.contentW/H  — the fixed, zoom-invariant basis every element/
--                         control fraction is scaled against (always
--                         derived from canvas.original, never from
--                         zoomedOriginal). Keeping this fixed is what keeps
--                         elements/controls from stretching: if the scale
--                         used for fracX differed from the one used for
--                         fracY, or either changed independently of zoom,
--                         shapes authored under one ratio would visibly
--                         distort under another.
--   canvas.w/h (+x/y)  — the actual on-screen viewport rectangle (used for
--                         background fill, scissor clip, and hit-testing).
--                         When a zoomedOriginal layout is set, this grows at
--                         the exact same rate the content itself does
--                         (worldW = contentW * zoom) rather than some
--                         separately-paced blend — so the box's own edges
--                         expand in lockstep with the content, the way a PDF
--                         viewer's page feels like one uniform zoom, not two
--                         things moving at different speeds. Growth stops
--                         once the box reaches zoomedOriginal's size; past
--                         that zoom level the viewport is already at its
--                         max and further zoom just reveals more of the
--                         (still-growing) world via pan, same as any
--                         max-width-reached zoom. With no zoomedOriginal
--                         set, it's just canvas.original's box at every
--                         zoom (e.g. the full-screen page, already at its
--                         maximum, has nothing to expand into).
local function _calculateGeometry(canvas)
    local o = canvas.original
    canvas.contentW = o.wFrac * globApp.safeScreenArea.w
    canvas.contentH = o.hFrac * globApp.safeScreenArea.h

    local target  = canvas.zoomedOriginal or o
    local targetW = target.wFrac * globApp.safeScreenArea.w
    local targetH = target.hFrac * globApp.safeScreenArea.h

    canvas.w = math.min(targetW, canvas.contentW * canvas.zoom)
    canvas.h = math.min(targetH, canvas.contentH * canvas.zoom)

    -- How far along the (capped) growth from contentW/H to targetW/H this
    -- frame's box size is — reused to blend x/y the same amount, so the
    -- box's position tracks its size instead of jumping ahead of/behind it.
    local pFracW = (targetW ~= canvas.contentW) and ((canvas.w - canvas.contentW) / (targetW - canvas.contentW)) or 0
    local pFracH = (targetH ~= canvas.contentH) and ((canvas.h - canvas.contentH) / (targetH - canvas.contentH)) or 0
    local x = o.x + (target.x - o.x) * pFracW
    local y = o.y + (target.y - o.y) * pFracH

    local pos = gdsGui_general_relativePosition(
        o.anchorPoint, x, y, canvas.w, canvas.h,
        globApp.safeScreenArea.x, globApp.safeScreenArea.y,
        globApp.safeScreenArea.w, globApp.safeScreenArea.h
    )
    canvas.x = pos[1]
    canvas.y = pos[2]
    canvas.controlRadius = _CONTROL_RADIUS_FRAC * math.min(canvas.contentW, canvas.contentH)
    _clampPan(canvas)
end

-- Convert an element/control's 0-1 fractional position into live canvas
-- pixels, accounting for the canvas's current pan/zoom view state. Uses the
-- fixed contentW/H basis (not the viewport's own canvas.w/h) so a widened
-- viewport never stretches content — see _calculateGeometry.
local function _toPixel(canvas, fracX, fracY)
    return canvas.x + canvas.panX + fracX * canvas.contentW * canvas.zoom,
           canvas.y + canvas.panY + fracY * canvas.contentH * canvas.zoom
end

-- Inverse of _toPixel: screen pixel -> 0-1 fraction of the canvas box.
local function _toFraction(canvas, px, py)
    local fracX = ((px - canvas.x - canvas.panX) / canvas.zoom) / canvas.contentW
    local fracY = ((py - canvas.y - canvas.panY) / canvas.zoom) / canvas.contentH
    return fracX, fracY
end

-- Snaps a 0-1 fraction position to the same world-space grid _drawGrid
-- renders, then clamps to [0,1]. Shared by every element/control placement
-- and drag site so a dragged piece always lands exactly on a drawn line —
-- spacing is expressed in world units (contentW/H at zoom 1) so, like the
-- grid itself, the snapped fraction grid gets finer as the user zooms in.
local function _snapToGrid(canvas, fracX, fracY)
    local spacingX = (_GRID_SPACING_PX / canvas.zoom) / canvas.contentW
    local spacingY = (_GRID_SPACING_PX / canvas.zoom) / canvas.contentH
    fracX = math.floor(fracX / spacingX + 0.5) * spacingX
    fracY = math.floor(fracY / spacingY + 0.5) * spacingY
    return math.max(0, math.min(1, fracX)), math.max(0, math.min(1, fracY))
end

-- Snaps an ELEMENT's center (not its stored top-left corner) to the grid,
-- then returns the corresponding top-left. Wires connect to element centers
-- (_elementCenter/_anchorCenter), so snapping the corner directly would only
-- guarantee the corner is on-grid — two elements of different w/h could both
-- have on-grid corners while their centers (what a wire actually routes to)
-- sit a few pixels apart, breaking the straight-line case in
-- _clampedOrthogonalSegments and visibly misaligning the wire from the shape.
-- Controls don't need this: their x/y already IS the center point.
local function _snapElementToGrid(canvas, fracX, fracY, wFrac, hFrac)
    local cx, cy = _snapToGrid(canvas, fracX + wFrac / 2, fracY + hFrac / 2)
    return cx - wFrac / 2, cy - hFrac / 2
end

local function _elementPixelRect(canvas, e)
    local px, py = _toPixel(canvas, e.x, e.y)
    return px, py, e.w * canvas.contentW * canvas.zoom, e.h * canvas.contentH * canvas.zoom
end

local function _elementCenter(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    return ex + ew / 2, ey + eh / 2
end

-- Center point of any wire/connector endpoint, element or control alike — an
-- element's box center, or a control's own position (already its center,
-- the same point _drawControl circles around).
local function _anchorCenter(canvas, anchor)
    if anchor.w then
        return _elementCenter(canvas, anchor)
    end
    return _toPixel(canvas, anchor.x, anchor.y)
end

-- Pivot point for the "spin to set direction" drag on an already-selected
-- wire — the midpoint between its two anchors' centers, mirroring how an
-- element's own center is the pivot for its rotate drag (see
-- gdsGui_schematic_pressed/_moved's "rotate"/"wireDirection" dragKinds).
local function _wireMidpoint(canvas, wire)
    local fromA, toA = _findAnchor(canvas, wire.fromElementId), _findAnchor(canvas, wire.toElementId)
    if not fromA or not toA then return nil end
    local x1, y1 = _anchorCenter(canvas, fromA)
    local x2, y2 = _anchorCenter(canvas, toA)
    return (x1 + x2) / 2, (y1 + y2) / 2
end

-- Topmost element whose pixel bounding box contains the point (last-added wins).
local function _hitElement(canvas, px, py)
    for i = #canvas.elements, 1, -1 do
        local e = canvas.elements[i]
        local ex, ey, ew, eh = _elementPixelRect(canvas, e)
        if px >= ex and px <= ex + ew and py >= ey and py <= ey + eh then
            return e
        end
    end
    return nil
end

local function _hitControl(canvas, px, py)
    for i = #canvas.controls, 1, -1 do
        local c = canvas.controls[i]
        local rad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
        local cx, cy = _toPixel(canvas, c.x, c.y)
        local dx, dy = px - cx, py - cy
        if (dx * dx + dy * dy) <= (rad * rad) then
            return c
        end
    end
    return nil
end

-- Either kind of wire/connector endpoint, exact hit only.
local function _hitAnchor(canvas, px, py)
    return _hitElement(canvas, px, py) or _hitControl(canvas, px, py)
end

local function _distPointToSegment(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local lenSq = dx * dx + dy * dy
    local t = 0
    if lenSq > 0 then
        t = math.max(0, math.min(1, ((px - x1) * dx + (py - y1) * dy) / lenSq))
    end
    local cx, cy = x1 + t * dx, y1 + t * dy
    local ex, ey = px - cx, py - cy
    return math.sqrt(ex * ex + ey * ey)
end

-- _hitWire itself is defined further below, right after _computeWirePlans
-- (it needs that function's per-wire lane-offset output to tell co-located
-- wires apart — see the comment there for why).

-- Like _hitAnchor, but tolerant of a near-miss: if the point isn't exactly
-- inside any element's box or control's radius, falls back to the nearest
-- one within _CONNECTOR_RELEASE_SLOP_PX pixels. Used only for "which anchor
-- did a wire-drag land on" — a release a few pixels off (easy to do,
-- especially with a finger) should still connect rather than silently fail.
local function _hitAnchorNear(canvas, px, py)
    local exact = _hitAnchor(canvas, px, py)
    if exact then return exact end
    local best, bestDist = nil, _CONNECTOR_RELEASE_SLOP_PX
    for _, e in ipairs(canvas.elements) do
        local ex, ey, ew, eh = _elementPixelRect(canvas, e)
        local cx = math.max(ex, math.min(px, ex + ew))
        local cy = math.max(ey, math.min(py, ey + eh))
        local dx, dy = px - cx, py - cy
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < bestDist then
            best, bestDist = e, dist
        end
    end
    for _, c in ipairs(canvas.controls) do
        local rad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
        local cx, cy = _toPixel(canvas, c.x, c.y)
        local dx, dy = px - cx, py - cy
        local dist = math.max(0, math.sqrt(dx * dx + dy * dy) - rad)
        if dist < bestDist then
            best, bestDist = c, dist
        end
    end
    return best
end

-- The anchor a wire-in-progress would actually connect to if released right
-- now, or nil if none (including: too far from anything, or the only match
-- is the wire's own starting anchor). Single source of truth shared by the
-- live snap-preview (drawing) and the actual connect-on-release logic, so
-- what the user sees while dragging is exactly what they'll get.
local function _connectorSnapTarget(canvas)
    if not canvas.wireTool.fromId then return nil end
    local target = _hitAnchorNear(canvas, canvas.wireTool.curX, canvas.wireTool.curY)
    if target and target.id ~= canvas.wireTool.fromId then return target end
    return nil
end

-- Snaps any angle (radians) to the nearest of the 4 cardinal orientations,
-- returned in degrees (0/90/180/270) — the only rotations a rotatable
-- element's icon (e.g. a diode's arrow) is ever drawn at.
local function _snapRotationDegrees(angleRad)
    local twoPi = math.pi * 2
    local a = angleRad % twoPi
    if a < 0 then a = a + twoPi end
    local snapped = math.floor(a / (math.pi / 2) + 0.5) % 4
    return snapped * 90
end

local function _fireControlCallback(control)
    if control.callbackFunc then
        local cb = _G[control.callbackFunc]
        if cb and type(cb) == "function" then
            cb(control.detentIndex)
        end
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — CANVAS
--------------------------------------------------------------------------------

--[[
    Creates a schematic drawing canvas and registers it in globApp.objects.schematics.
    x, y, wFrac, hFrac are fractions of the safe screen area (wFrac/hFrac are the
    canvas's own width/height as a fraction, not pixel-ratio like buttons use).
]]
function gdsGui_schematic_create(name, page, x, y, anchorPoint, wFrac, hFrac)
    local canvas = {}
    canvas.name       = name
    canvas.page       = page
    canvas.objectType = "schematic"
    canvas.mode       = "design"   -- "design" | "control"
    canvas.elements   = {}
    canvas.wires      = {}
    canvas.controls   = {}
    canvas.snapshots  = {}   -- keyed by signature string -> {elements={id=color}, wires={id=color}, timestamp}
    canvas.selectedElementId = nil
    canvas.selectedControlId = nil
    canvas.selectedWireId    = nil
    -- True once a held press on the current element/control/wire selection
    -- has crossed _LONG_PRESS_SECONDS without moving (see
    -- gdsGui_schematic_update), unlocking it for drag/rotate/direction —
    -- drawn as a magenta outline instead of the plain "selected" yellow
    -- one. Stays
    -- true across separate press/release cycles on the SAME target (so the
    -- user can lift and re-grab it without holding again) until a
    -- different element/control/wire is selected or selection is cleared.
    canvas.selectionMoveModeActive = false
    canvas.wireToolActive    = false
    canvas.wireTool          = { fromId = nil, curX = nil, curY = nil, color = nil }
    canvas.defaultConnectorColor = nil  -- see gdsGui_schematic_setDefaultConnectorColor
    canvas.focusTouchId      = nil
    canvas.dragKind          = nil   -- "element" | "control" | "wire" | "wireDirection" | "rotate" | "controlRotate" | "pendingLongPress" | "pan" | nil
    canvas.dragOffsetX       = 0
    canvas.dragOffsetY       = 0
    canvas.dragStartX        = 0
    canvas.dragStartY        = 0
    canvas.dragMoved         = false
    canvas.longPressTargetKind = nil  -- "element" | "control" | "wire", set at the start of a "pendingLongPress" dragKind; see gdsGui_schematic_pressed/_update
    canvas.longPressElapsed    = 0    -- seconds held so far this "pendingLongPress"; see gdsGui_schematic_update
    canvas.rotateGrabAngleOffset = 0  -- set at the start of a "rotate" or "wireDirection" drag; see gdsGui_schematic_pressed
    -- Captured at the start of an "element"/"control"/"rotate" drag (before
    -- any position/rotation change), but only actually pushed onto
    -- _undoStack once that drag crosses the tap-vs-drag slop threshold —
    -- see gdsGui_schematic_moved. A plain tap that never moves anything
    -- never touches the undo stack; a real move/rotate becomes exactly one
    -- undo step capturing the pre-drag state, not the post-drag one.
    canvas._pendingDragUndoSnapshot = nil
    canvas.panStartX         = 0   -- canvas.panX/panY at the start of a "pan" drag
    canvas.panStartY         = 0
    canvas.menu              = nil  -- generic modal list: {title, options, onSelect, onCancel}
    canvas.pendingPlacement  = nil  -- armed "place next tap": {kind, shapeType|positions, label, ...}
    canvas.pendingConnectorColor = nil  -- armed "draw next wire" from the catalog, independent of wireToolActive/the dock toggle; disarms after one connector
    canvas.pendingColorAssignPick = false  -- armed "tap an element or wire to assign its snapshot color"; disarms after one pick
    canvas.pendingWireFromId = nil  -- armed via ADD WIRE in the element edit menu: elementId the next press-drag-release starts a wire from, with no need to land that press on an anchor; disarms after one drag
    canvas._placementCounter = 0
    canvas._colorPickTarget     = nil  -- {kind="element"|"wire", id=...} while the color-picker menu is open
    canvas._elementEditTargetId = nil  -- elementId while the design-mode edit (color+properties+delete) menu is open
    canvas._wireEditTargetId    = nil  -- wireId while the design-mode wire edit (color+delete) menu is open
    canvas._controlEditTargetId = nil  -- controlId while the design-mode control edit (position+delete) menu is open
    canvas._propertyEditTargetId = nil -- elementId while the PROPERTIES submenu is open
    canvas._propertyActionKey    = nil -- property key targeted by the EDIT VALUE/DELETE PROPERTY submenu
    canvas._undoStack            = {}  -- array of {elements,wires,controls} snapshots, most recent last

    -- Pan/zoom view state: zoom 1 = fully zoomed out (the whole canvas box
    -- fits the viewport exactly, the historical/default look); up to 4x.
    -- panX/panY are pixel offsets of the zoomed content within the viewport.
    -- touches tracks every finger currently down inside this canvas (id ->
    -- {x,y}) so a second simultaneous touch can be recognized as a pinch,
    -- independent of the single-touch drag/focusTouchId model above.
    canvas.zoom    = _MIN_ZOOM
    canvas.panX    = 0
    canvas.panY    = 0
    canvas.touches = {}
    canvas.pinch   = nil

    canvas.original = { x = x, y = y, anchorPoint = anchorPoint, wFrac = wFrac, hFrac = hFrac }
    canvas.zoomedOriginal = nil  -- see gdsGui_schematic_setZoomedLayout
    _calculateGeometry(canvas)

    -- A resize/orientation-change (or the app's own full-screen toggle,
    -- which reassigns canvas.page and implicitly resizes it) arriving
    -- mid-gesture invalidates dragOffsetX/Y, panStartX/Y, and the pinch's
    -- startDist/anchor fractions — all computed against the PRE-resize
    -- x/pan/zoom/w/h. Left stale, the next moved() event would compute the
    -- dragged element/control/pan's new position from the NEW geometry but
    -- the OLD offset, making it visibly jump instead of tracking the
    -- finger smoothly. Safest to just cleanly end whatever single-touch or
    -- pinch gesture was in flight — resize is a rare, discontinuous event
    -- (unlike pinch/wheel zoom, which also call _calculateGeometry every
    -- frame/scroll and must NOT be interrupted this way), so there's no
    -- way to carry a gesture smoothly across it anyway. Deliberately
    -- narrower than gdsGui_schematic_setMode's reset — a mere resize
    -- shouldn't also cancel an armed catalog placement or close an open
    -- menu.
    function canvas:resize()
        self.focusTouchId = nil
        self.dragKind = nil
        self.wireTool.fromId = nil
        self._pendingDragUndoSnapshot = nil
        self.touches = {}
        self.pinch = nil
        _calculateGeometry(self)
    end

    table.insert(globApp.objects.schematics, canvas)
    globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
end

-- An alternate layout the canvas's on-screen VIEWPORT (not its element/
-- control content scale — see _calculateGeometry) grows into as zoom
-- increases past _MIN_ZOOM, at the same rate the content itself scales
-- (worldW = contentW * zoom) until the viewport reaches this layout's size,
-- then holds there for any further zoom — continuously, never a snap, and
-- blending back to the normal gdsGui_schematic_create layout as zoom
-- returns to _MIN_ZOOM. Lets the app layer offer a smaller, screen-aspect-
-- matched box at the default 1x view, then hand over a larger viewport,
-- growing in step with the zoom itself (a "PDF zoom" feel, box and content
-- expanding together) as the user zooms in and pans around a cropped view
-- — with no stretching of elements/controls, since their own fraction-
-- >pixel scale stays fixed throughout (see canvas.contentW/H). Pass nil (or
-- call gdsGui_schematic_clearZoomedLayout) to go back to always using the
-- normal layout regardless of zoom — e.g. while the canvas is on a page
-- that's already using its full layout, so zooming in has nothing further
-- to expand into.
function gdsGui_schematic_setZoomedLayout(canvasName, x, y, anchorPoint, wFrac, hFrac)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.zoomedOriginal = { x = x, y = y, anchorPoint = anchorPoint, wFrac = wFrac, hFrac = hFrac }
    _calculateGeometry(canvas)
end

function gdsGui_schematic_clearZoomedLayout(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.zoomedOriginal = nil
    _calculateGeometry(canvas)
end

-- Removes a canvas previously made with gdsGui_schematic_create. There was
-- previously no way to do this at all, so any caller that re-creates a
-- canvas under a name it already used (e.g. a test suite re-run) just piled
-- up duplicates in globApp.objects.schematics forever, with _findCanvas
-- silently resolving to the stale first match on every call after the first.
function gdsGui_schematic_delete(canvasName)
    for i = #globApp.objects.schematics, 1, -1 do
        if globApp.objects.schematics[i].name == canvasName then
            table.remove(globApp.objects.schematics, i)
            globApp.numObjectsDisplayed = globApp.numObjectsDisplayed - 1
        end
    end
end

function gdsGui_schematic_getZoom(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return nil end
    return canvas.zoom
end

function gdsGui_schematic_setMode(canvasName, mode)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.mode = mode
    canvas.wireToolActive = false
    canvas.wireTool.fromId = nil
    canvas.wireTool.color = nil
    canvas.pendingPlacement = nil
    canvas.pendingConnectorColor = nil
    canvas.pendingColorAssignPick = false
    canvas.pendingWireFromId = nil
    canvas.menu = nil
    canvas.touches = {}
    canvas.pinch = nil
    canvas.focusTouchId = nil
    canvas.dragKind = nil
    canvas._pendingDragUndoSnapshot = nil
    canvas.selectionMoveModeActive = false
end

function gdsGui_schematic_getMode(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas and canvas.mode or nil
end

-- Lets the app layer snapshot canvas state before a mutation it performs
-- directly (e.g. a "delete selected element" dock button), so that gesture
-- also becomes undoable, matching every in-library gesture handler below.
function gdsGui_schematic_pushUndo(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then _pushUndo(canvas) end
end

-- Discards the whole undo history. Called by the app layer when switching to
-- a different project's data, so "undo" can never splice one project's
-- elements/wires/controls onto another's.
function gdsGui_schematic_clearUndo(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas._undoStack = {} end
end

function gdsGui_schematic_canUndo(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and #canvas._undoStack > 0
end

-- Pops the most recent snapshot off the stack and restores it. Repeated
-- calls step further back through history, up to _UNDO_STACK_MAX deep.
function gdsGui_schematic_undo(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas or #canvas._undoStack == 0 then return end
    local snapshot = table.remove(canvas._undoStack)
    canvas.elements  = snapshot.elements
    canvas.wires     = snapshot.wires
    canvas.controls  = snapshot.controls
    canvas.snapshots = snapshot.snapshots
    canvas.selectedElementId = nil
    canvas.selectedControlId = nil
    canvas.selectedWireId    = nil
end

-- Resets the pan/zoom view to centered, at either the fully-zoomed-out level
-- or an explicit startZoom (e.g. _EDIT_MODE_INITIAL_ZOOM — see its definition
-- above for why design mode opens pre-zoomed). Called whenever a project is
-- (re)loaded into the canvas so each one opens at a known view rather than
-- wherever the previous project's view was left.
-- The zoom level design/edit mode should open at (see _EDIT_MODE_INITIAL_ZOOM
-- above). Exposed so the app layer's mode-dependent gdsGui_schematic_resetView
-- call doesn't hardcode a number that has to stay in sync with the halved
-- _ELEMENT_DEFAULT_*_FRAC compensation.
function gdsGui_schematic_getEditModeInitialZoom()
    return _EDIT_MODE_INITIAL_ZOOM
end

function gdsGui_schematic_resetView(canvasName, startZoom)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.zoom = math.max(_MIN_ZOOM, math.min(_MAX_ZOOM, startZoom or _MIN_ZOOM))
    -- The new zoom may change the viewport box size (see
    -- gdsGui_schematic_setZoomedLayout) — recompute before resetting pan so
    -- panX/panY=0 lines up with the resulting box.
    _calculateGeometry(canvas)
    canvas.panX = 0
    canvas.panY = 0
end

-- defaultColor (optional): color to stamp on the next connector drawn while
-- this arming lasts, e.g. a catalog item picking a system-specific color
-- (electrical wire vs. hydraulic/fuel/pneumatic pipe). Omit for the plain
-- "WIRE TOOL" dock button, which falls back to the library's default color.
function gdsGui_schematic_setWireToolActive(canvasName, active, defaultColor)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.wireToolActive = (active == true)
    canvas.wireTool.fromId = nil
    canvas.wireTool.color  = (active == true) and defaultColor or nil
end

--------------------------------------------------------------------------------
-- PUBLIC API — ELEMENTS / WIRES / CONTROLS
--------------------------------------------------------------------------------

-- shapeType: "rect" | "circle" | "diode". x,y,w,h are 0-1 fractions of the
-- canvas box. properties (optional): array of {key=string, value=string} —
-- a generic, domain-agnostic key/value list (the app layer decides what keys
-- mean, e.g. "VOLTAGE"/"CURRENT" for an electrical element). rotation
-- (optional, degrees, defaults to 0): current cardinal orientation (0/90/
-- 180/270) of a rotatable shapeType's icon (see _ROTATABLE_SHAPES) — ignored
-- by every other shapeType. spritePath (optional): an app-supplied image
-- path drawn letterboxed into the element's box instead of the plain
-- rect/circle/diode shape (see _drawElementSprite) — same arm's-length
-- "just a string the app layer resolved" relationship as a gallery tile's
-- item.thumbnailPath; the library never interprets what it depicts. The
-- element's resolved color (base/pending/snapshot, same as any other
-- shapeType) still tints it, so color-coding by snapshot still works.
function gdsGui_schematic_addElement(canvasName, id, shapeType, x, y, w, h, label, defaultColor, properties, rotation, spritePath)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    table.insert(canvas.elements, {
        id = id, shapeType = shapeType, x = x, y = y, w = w, h = h,
        label = label, defaultColor = defaultColor or _DEFAULT_COLOR, pendingColor = nil,
        properties = properties or {}, rotation = rotation or 0, spritePath = spritePath,
    })
    _resyncPlacementCounter(canvas, id)
end

-- Upserts a property by key (case-sensitive), preserving insertion order for
-- display. value is a plain string — units/formatting are the app layer's concern.
function gdsGui_schematic_setElementProperty(canvasName, elementId, key, value)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el then return end
    el.properties = el.properties or {}
    for _, p in ipairs(el.properties) do
        if p.key == key then p.value = value; return end
    end
    table.insert(el.properties, { key = key, value = value })
end

function gdsGui_schematic_removeElementProperty(canvasName, elementId, key)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el or not el.properties then return end
    for i = #el.properties, 1, -1 do
        if el.properties[i].key == key then table.remove(el.properties, i) end
    end
end

function gdsGui_schematic_getElementProperties(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return {} end
    local el = _findElement(canvas, elementId)
    return (el and el.properties) or {}
end

-- Removing an element cascades: any wire touching it is removed too.
function gdsGui_schematic_removeElement(canvasName, id)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    for i = #canvas.elements, 1, -1 do
        if canvas.elements[i].id == id then table.remove(canvas.elements, i) end
    end
    for i = #canvas.wires, 1, -1 do
        local w = canvas.wires[i]
        if w.fromElementId == id or w.toElementId == id then
            table.remove(canvas.wires, i)
        end
    end
    if canvas.selectedElementId == id then canvas.selectedElementId = nil end
end

-- directionOverride (optional, 0/90/180/270) forces the h-first-vs-v-first
-- choice in the orthogonal routing below — see _wireForceAxis — the same
-- "nil means automatic" convention as an element's own rotation parameter.
function gdsGui_schematic_addWire(canvasName, id, fromElementId, toElementId, defaultColor, directionOverride)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    table.insert(canvas.wires, {
        id = id, fromElementId = fromElementId, toElementId = toElementId,
        defaultColor = defaultColor or _DEFAULT_COLOR, pendingColor = nil,
        directionOverride = directionOverride,
    })
end

function gdsGui_schematic_removeWire(canvasName, id)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    for i = #canvas.wires, 1, -1 do
        if canvas.wires[i].id == id then table.remove(canvas.wires, i) end
    end
    if canvas.selectedWireId == id then canvas.selectedWireId = nil end
end

-- x,y are 0-1 fractions of the canvas box (controls are placed on the grid too).
-- positions is an ordered array of position names, e.g. {"OFF","ON"} or {"OFF","ON","STBY"}.
-- radiusScale (optional, defaults to 1): multiplies canvas.controlRadius for
-- this control only — see _ELEMENT_DEFAULT_*_FRAC's comment above. Unlike an
-- element's w/h, a control's radius is normally one shared canvas-wide
-- constant (canvas.controlRadius), so this is the per-instance equivalent of
-- that halved default, passed as 1/_EDIT_MODE_INITIAL_ZOOM by the design-mode
-- placement flow so a freshly-placed control still looks the historical size
-- under the new pre-zoomed default. Omitted (nil -> 1) for every other
-- caller (loading saved data, the demo seed, unit tests), so already-placed
-- controls keep rendering exactly as they always have. spritePaths
-- (optional): array of image paths parallel to positions — the one at
-- detentIndex+1 is drawn (letterboxed, see _drawControl) instead of the
-- plain vector circle+indicator-line for whichever position is currently
-- selected; an entry can be nil (or the array shorter than positions) to
-- fall back to the vector icon for just that one position. Same
-- arm's-length "just paths the app layer resolved" relationship as an
-- element's own spritePath. rotation (optional, degrees, defaults to 0):
-- every control is rotatable (unlike an element, where only specific
-- shapeTypes are — see _ROTATABLE_SHAPES), spinning its icon — sprite or
-- vector alike — to one of the 4 cardinal orientations.
function gdsGui_schematic_addControl(canvasName, id, x, y, positions, initialDetentIndex, label, callbackFunc, radiusScale, spritePaths, rotation)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local numDetents = math.max(2, #positions)
    table.insert(canvas.controls, {
        id = id, x = x, y = y, numDetents = numDetents, positions = positions,
        detentIndex = math.max(0, math.min(numDetents - 1, initialDetentIndex or 0)),
        label = label, callbackFunc = callbackFunc, radiusScale = radiusScale or 1,
        spritePaths = spritePaths, rotation = rotation or 0,
    })
    _resyncPlacementCounter(canvas, id)
end

-- Inverse of gdsGui_schematic_buildSignature: "a=0,b=1" -> {a=0, b=1}. ""
-- parses to an empty table (the no-controls signature).
local function _parseSignature(signature)
    local states = {}
    if signature == "" then return states end
    for pair in signature:gmatch("[^,]+") do
        local id, idx = pair:match("^(.-)=(%-?%d+)$")
        if id then states[id] = tonumber(idx) end
    end
    return states
end

-- A snapshot key encodes a condition on every control present when it was
-- captured (e.g. "swA=0,swB=1"). Removing just ONE of several controls a
-- key references still leaves it migratable: gdsGui_schematic_prepareSnapshot's
-- _matchingSnapshotKeys folds an old key forward into the next capture via
-- whichever ids still agree (see its own comment) — swB removed, swA still
-- matching, recapturing finds "swA=0,swB=1" and carries its taught colors
-- into the new narrower signature. So pruning here must NOT drop a key just
-- because one of its controls is gone — only once EVERY control it
-- references is gone does it become unreachable forever (no future
-- capture could ever share an id with it again, so _matchingSnapshotKeys
-- could never fold it forward either), at which point it really is just
-- dead weight inflating gdsGui_schematic_countSnapshots and the SNAPSHOTS
-- gallery list. Called by gdsGui_schematic_removeControl right after the
-- cascade below, once the removed control is already gone from
-- canvas.controls, so "survives" below means "among what's left."
local function _pruneUnreachableSnapshots(canvas)
    for key in pairs(canvas.snapshots) do
        local states = _parseSignature(key)
        if next(states) ~= nil then
            local anySurvives = false
            for id in pairs(states) do
                if _findControl(canvas, id) then anySurvives = true; break end
            end
            if not anySurvives then canvas.snapshots[key] = nil end
        end
    end
end

-- Removing a control cascades: any wire touching it is removed too (a
-- control is a valid wire endpoint, same as an element), and any snapshot
-- that's now unreachable by every control it referenced is pruned.
function gdsGui_schematic_removeControl(canvasName, id)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    for i = #canvas.controls, 1, -1 do
        if canvas.controls[i].id == id then table.remove(canvas.controls, i) end
    end
    for i = #canvas.wires, 1, -1 do
        local w = canvas.wires[i]
        if w.fromElementId == id or w.toElementId == id then
            table.remove(canvas.wires, i)
        end
    end
    _pruneUnreachableSnapshots(canvas)
end

-- Direct position selection (used by the control-mode "select control" + "select
-- position" menus). Also reachable by repeatedly tapping the control's canvas glyph,
-- which cycles one position per tap via gdsGui_schematic_pressed.
function gdsGui_schematic_setControlPosition(canvasName, controlId, positionIndex)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local control = _findControl(canvas, controlId)
    if not control then return end
    positionIndex = math.max(0, math.min(control.numDetents - 1, positionIndex))
    if positionIndex ~= control.detentIndex then
        control.detentIndex = positionIndex
        _fireControlCallback(control)
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — PLACEMENT ARMING (design-mode "add from catalog" flow)
--------------------------------------------------------------------------------

-- defaultPropertyKeys (optional): array of property-name strings to pre-seed
-- on the placed element with empty values, e.g. {"VOLTAGE","CURRENT"} for a
-- catalog item the app layer knows is electrical — ready for the user to fill
-- in via the design-mode element edit menu's PROPERTIES option. spritePath
-- (optional): see gdsGui_schematic_addElement — threaded through unchanged.
function gdsGui_schematic_armElementPlacement(canvasName, shapeType, label, defaultColor, idPrefix, defaultPropertyKeys, spritePath)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    -- At most one of pendingPlacement/pendingConnectorColor/
    -- pendingColorAssignPick/pendingWireFromId is ever meant to be armed at
    -- once (gdsGui_schematic_cancelPlacement/_setMode both disarm all four
    -- together) — clear the other three so arming this one can't leave a
    -- stale one of them still live to silently fire on some later,
    -- unrelated tap.
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pendingPlacement = { kind = "element", shapeType = shapeType, label = label,
        defaultColor = defaultColor, idPrefix = idPrefix or label, defaultPropertyKeys = defaultPropertyKeys,
        spritePath = spritePath }
end

-- spritePaths (optional): see gdsGui_schematic_addControl — threaded
-- through unchanged.
function gdsGui_schematic_armControlPlacement(canvasName, positions, label, callbackFunc, idPrefix, spritePaths)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pendingPlacement = { kind = "control", positions = positions, label = label,
        callbackFunc = callbackFunc, idPrefix = idPrefix or label, spritePaths = spritePaths }
end

-- Arms a one-shot "draw the next wire/pipe/etc." gesture: tap one element,
-- then another, to connect them in defaultColor. Independent of
-- wireToolActive (the dock's persistent WIRE TOOL checkmark toggle) — picking
-- a connector from the catalog no longer requires that toggle to be on, and
-- doesn't touch its button state. Disarms itself after the gesture resolves
-- (whether or not it actually landed on a second element), same as every
-- other catalog placement being a single tap-to-commit action.
function gdsGui_schematic_armConnectorPlacement(canvasName, defaultColor)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pendingConnectorColor = defaultColor or _DEFAULT_COLOR
end

-- The color a wire drawn via ADD WIRE (an element's own edit menu — see
-- gdsGui_schematic_internal_onElementEditChosen) comes out pre-set to,
-- instead of the library's flat gray _DEFAULT_COLOR — e.g. the app layer
-- calling this once per system (electrical=yellow, hydraulic=blue, ...)
-- whenever that system's data is loaded into the canvas, same arm's-length
-- "just a color the app layer resolved" relationship as an element's own
-- spritePath. nil clears it back to the library default. Doesn't affect
-- gdsGui_schematic_armConnectorPlacement's own defaultColor param — that
-- one is still a per-gesture override, this is just the fallback under it.
function gdsGui_schematic_setDefaultConnectorColor(canvasName, color)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.defaultConnectorColor = color end
end

-- Arms a one-shot "tap an element or wire to assign its snapshot color" pick,
-- parallel to armElementPlacement/armConnectorPlacement above. The very next
-- design-mode tap that lands on an element or wire opens the swatch color
-- picker for it (setting its pendingColor) instead of selecting/dragging it;
-- a tap that lands on empty space just disarms with no target chosen.
function gdsGui_schematic_armColorAssignPick(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pendingColorAssignPick = true
end

function gdsGui_schematic_cancelPlacement(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas.pendingPlacement = nil
        canvas.pendingConnectorColor = nil
        canvas.pendingColorAssignPick = false
        canvas.pendingWireFromId = nil
    end
end

function gdsGui_schematic_isPlacementArmed(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and (canvas.pendingPlacement ~= nil or canvas.pendingConnectorColor ~= nil or
        canvas.pendingColorAssignPick or canvas.pendingWireFromId ~= nil)
end

--------------------------------------------------------------------------------
-- PUBLIC API — GENERIC MODAL LIST MENU
-- Reused for: design-mode catalog cascade, control-mode control/position
-- pickers, the built-in color picker, and snapshot-conflict confirmation.
--------------------------------------------------------------------------------

-- onSelectFunc(canvasName, index, optionText) and onCancelFunc(canvasName) are
-- global function names (strings), resolved via _G[...] like every other
-- string-named callback in this library.
function gdsGui_schematic_openMenu(canvasName, title, options, onSelectFunc, onCancelFunc)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc }
end

function gdsGui_schematic_closeMenu(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.menu = nil end
end

function gdsGui_schematic_isMenuOpen(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and canvas.menu ~= nil
end

-- Generalized over any owner with .x/.y/.w/.h (schematic canvas or gallery)
-- so both widget types can share one modal-menu implementation below.
-- A menu is normally a plain vertical list of text rows (menu.options). When
-- menu.isSwatchPicker is set, the first #menu.swatchColors entries render as
-- a single row of colored squares instead (menu.extraOptions, e.g. "DELETE",
-- still render as ordinary text rows below it) — the swatch count plus the
-- extra-option count must equal #menu.options, since hit-testing/selection
-- still indexes into that one combined list.
local function _menuGeometry(owner, menu)
    local w = owner.w * _MENU_WIDTH_FRAC
    local titleH = menu.title and _MENU_ROW_H or 0
    local bodyH
    if menu.isSwatchPicker then
        bodyH = _SWATCH_ROW_H_PX + #menu.extraOptions * _MENU_ROW_H
    else
        bodyH = #menu.options * _MENU_ROW_H
    end
    local h = titleH + bodyH + 10
    local x = owner.x + (owner.w - w) / 2
    local y = owner.y + math.max(0, (owner.h - h) / 2)
    return x, y, w, h, titleH
end

-- Geometry of one swatch square in a swatch-picker row, by 1-based index.
local function _swatchRect(mx, mw, count, index)
    local totalGap = _SWATCH_GAP_PX * (count + 1)
    local size = (mw - totalGap) / count
    local sx = mx + _SWATCH_GAP_PX + (index - 1) * (size + _SWATCH_GAP_PX)
    return sx, size
end

-- Returns the 1-based index (into menu.options) tapped, "outside" if the tap
-- missed the menu box entirely (treated as cancel), or nil if inside the box
-- but not on a row/swatch.
local function _menuRowAt(owner, menu, px, py)
    local mx, my, mw, mh, titleH = _menuGeometry(owner, menu)
    if px < mx or px > mx + mw or py < my or py > my + mh then return "outside" end
    local rowY = my + titleH

    if menu.isSwatchPicker then
        local n = #menu.swatchColors
        if py >= rowY and py < rowY + _SWATCH_ROW_H_PX then
            for i = 1, n do
                local sx, size = _swatchRect(mx, mw, n, i)
                if px >= sx and px <= sx + size then return i end
            end
            return nil
        end
        rowY = rowY + _SWATCH_ROW_H_PX
        for j = 1, #menu.extraOptions do
            if py >= rowY and py < rowY + _MENU_ROW_H then return n + j end
            rowY = rowY + _MENU_ROW_H
        end
        return nil
    end

    for i = 1, #menu.options do
        if py >= rowY and py < rowY + _MENU_ROW_H then return i end
        rowY = rowY + _MENU_ROW_H
    end
    return nil
end

-- Shared press-dispatch for any owner with a .menu (schematic canvas or
-- gallery): just records what this touch landed on (a row index, "outside"
-- the box entirely, or nil for inside-but-on-nothing) and which touch it
-- was — doesn't fire anything yet. _handleMenuRelease below is what
-- actually fires onSelect/onCancel, and only once the matching release
-- comes back to confirm it landed on that SAME target (standard
-- touch-up-inside semantics, so a press that drags off a row, or off the
-- backdrop, before releasing does nothing).
local function _handleMenuPress(owner, touchId, px, py)
    -- Only the first finger down gets tracked (the comment above and
    -- _handleMenuRelease below both assume this) — a second one touching
    -- the menu while the first is still held must not hijack (overwrite)
    -- or silently discard the first finger's in-progress press/release pair.
    if owner.menu._pressedTouchId ~= nil and owner.menu._pressedTouchId ~= touchId then return end
    owner.menu._pressedHit     = _menuRowAt(owner, owner.menu, px, py)
    owner.menu._pressedTouchId = touchId
end

-- Shared release-dispatch pairing with _handleMenuPress above. A second
-- finger's release (the menu is modal and only ever tracks the first one
-- that touched it) is ignored outright, leaving the tracked press's own
-- release to resolve it.
local function _handleMenuRelease(owner, touchId, px, py)
    local menu = owner.menu
    if not menu or menu._pressedTouchId ~= touchId then return end
    local pressedHit = menu._pressedHit
    menu._pressedHit, menu._pressedTouchId = nil, nil
    if pressedHit == nil then return end
    local releasedHit = _menuRowAt(owner, menu, px, py)
    if releasedHit ~= pressedHit then return end
    if pressedHit == "outside" then
        local cb = menu.onCancel
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name) end
    elseif type(pressedHit) == "number" then
        local opt = menu.options[pressedHit]
        local cb = menu.onSelect
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name, pressedHit, opt) end
    end
end

-- One text menu row, highlighted red when it's the destructive "DELETE"
-- option (wherever it appears: the design-mode element-edit menu, a project's
-- manage-action menu, or either one's delete-confirm step).
local function _drawMenuTextRow(mx, mw, rowY, opt)
    if opt == "DELETE" then
        love.graphics.setColor(0.75, 0.15, 0.15, 1)
        love.graphics.rectangle("fill", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("line", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
    else
        love.graphics.setColor(1, 1, 1, 0.15)
        love.graphics.rectangle("line", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
        love.graphics.setColor(1, 1, 1, 1)
    end
    love.graphics.printf(opt, mx, rowY + 8, mw, "center")
end

-- Shared modal-menu box drawing for any owner with a .menu.
local function _drawMenuBox(owner, menu)
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", owner.x, owner.y, owner.w, owner.h)

    local mx, my, mw, mh, titleH = _menuGeometry(owner, menu)
    love.graphics.setColor(0.15, 0.15, 0.18, 1)
    love.graphics.rectangle("fill", mx, my, mw, mh)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", mx, my, mw, mh)

    local rowY = my
    if menu.title then
        love.graphics.setColor(0.25, 0.25, 0.25, 1)
        love.graphics.rectangle("fill", mx, rowY, mw, titleH)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(menu.title, mx, rowY + 8, mw, "center")
        rowY = rowY + titleH
    end

    if menu.isSwatchPicker then
        local n = #menu.swatchColors
        local _, firstSize = _swatchRect(mx, mw, n, 1)
        local sy = rowY + (_SWATCH_ROW_H_PX - firstSize) / 2
        for i, c in ipairs(menu.swatchColors) do
            local sx, size = _swatchRect(mx, mw, n, i)
            love.graphics.setColor(c[1], c[2], c[3], c[4] or 1)
            love.graphics.rectangle("fill", sx, sy, size, size)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.rectangle("line", sx, sy, size, size)
        end
        rowY = rowY + _SWATCH_ROW_H_PX
        for _, opt in ipairs(menu.extraOptions) do
            _drawMenuTextRow(mx, mw, rowY, opt)
            rowY = rowY + _MENU_ROW_H
        end
    else
        for _, opt in ipairs(menu.options) do
            _drawMenuTextRow(mx, mw, rowY, opt)
            rowY = rowY + _MENU_ROW_H
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- PUBLIC API — BUILT-IN COLOR PICKER (opens a swatch-style menu: one row of
-- actual-color squares, one per _COLOR_PALETTE entry, plus any extraOptions
-- as ordinary text rows below — e.g. "DELETE" for the element-edit menu
-- further down). extraOptions are appended to the shared options list so
-- hit-testing/selection still indexes into one combined array.
--------------------------------------------------------------------------------

local function _openSwatchColorMenu(canvasName, title, extraOptions, onSelectFunc, onCancelFunc)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local options, swatchColors = {}, {}
    for _, entry in ipairs(_COLOR_PALETTE) do
        table.insert(options, entry.name)
        table.insert(swatchColors, entry.color)
    end
    for _, opt in ipairs(extraOptions or {}) do table.insert(options, opt) end
    canvas.menu = {
        title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc,
        isSwatchPicker = true, swatchColors = swatchColors, extraOptions = extraOptions or {},
    }
end

function gdsGui_schematic_openColorPicker(canvasName, targetKind, targetId, title)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas._colorPickTarget = { kind = targetKind, id = targetId }
    _openSwatchColorMenu(canvasName, title or "PICK COLOR", {},
        "gdsGui_schematic_internal_onColorPicked", "gdsGui_schematic_internal_onColorPickCancelled")
end

function gdsGui_schematic_setPendingColor(canvasName, targetKind, targetId, color)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    -- Not the "A and B or C" idiom (see gdsGui_schematic_resolveColor's
    -- comment): B (_findElement's result) can itself be nil for a bad
    -- targetId, which would otherwise silently fall through to a wire
    -- lookup and recolor the WRONG object if a wire happened to share
    -- that id.
    local target
    if targetKind == "element" then target = _findElement(canvas, targetId)
    else target = _findWire(canvas, targetId) end
    if target then target.pendingColor = color end
end

function gdsGui_schematic_internal_onColorPicked(canvasName, index)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._colorPickTarget then return end
    local entry = _COLOR_PALETTE[index]
    if entry then
        gdsGui_schematic_setPendingColor(canvasName, canvas._colorPickTarget.kind, canvas._colorPickTarget.id, entry.color)
    end
    canvas._colorPickTarget = nil
end

function gdsGui_schematic_internal_onColorPickCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas._colorPickTarget = nil end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ELEMENT EDIT MENU (color + delete, opened by a
-- plain tap on an element while in design mode; a drag still repositions it
-- instead). Sets the element's base defaultColor directly — unlike the
-- control-mode color picker above, there's no signature/snapshot involved
-- here, just the element's permanent appearance when no snapshot overrides it.
--------------------------------------------------------------------------------

function gdsGui_schematic_openElementEditMenu(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el then return end
    canvas._elementEditTargetId = elementId
    _openSwatchColorMenu(canvasName, el.label or elementId, {"ADD WIRE", "RENAME", "PROPERTIES", "DELETE"},
        "gdsGui_schematic_internal_onElementEditChosen", "gdsGui_schematic_internal_onElementEditCancelled")
end

function gdsGui_schematic_internal_onElementEditChosen(canvasName, index)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._elementEditTargetId then return end
    local elementId = canvas._elementEditTargetId
    local nColors = #_COLOR_PALETTE
    if index == nColors + 1 then
        -- ADD WIRE tapped: arm a one-shot wire-drag whose fixed start is
        -- this element (see canvas.pendingWireFromId in
        -- gdsGui_schematic_pressed) — keeps it selected (highlighted)
        -- while the user drags the loose end to whatever it should
        -- connect to, same "stay selected mid-flow" convention as
        -- RENAME/PROPERTIES below.
        canvas._elementEditTargetId = nil
        -- Disarm any other pending placement/pick first (see
        -- gdsGui_schematic_armElementPlacement's comment on why) — then
        -- arm this one, since cancelPlacement would otherwise immediately
        -- clear the very field being set on the next line.
        gdsGui_schematic_cancelPlacement(canvasName)
        canvas.pendingWireFromId = elementId
        return
    elseif index == nColors + 2 then
        -- RENAME tapped: hand off to the rename prompt, keeping the element
        -- selected while that flow is in progress.
        canvas._elementEditTargetId = nil
        _openElementRenamePrompt(canvasName, elementId)
        return
    elseif index == nColors + 3 then
        -- PROPERTIES tapped: hand off to the properties submenu, keeping the
        -- element selected while that flow is in progress.
        canvas._elementEditTargetId = nil
        _openPropertiesMenu(canvasName, elementId)
        return
    elseif index == nColors + 4 then
        -- DELETE tapped: confirm before actually removing it. Keep
        -- _elementEditTargetId set — the confirm/cancel handler below clears it.
        local el = _findElement(canvas, elementId)
        gdsGui_schematic_openMenu(canvasName, "DELETE \"" .. (el and (el.label or elementId) or elementId) .. "\"?",
            {"DELETE", "CANCEL"}, "gdsGui_schematic_internal_onElementDeleteConfirmed",
            "gdsGui_schematic_internal_onElementDeleteConfirmed")
        return
    end
    canvas._elementEditTargetId = nil
    canvas.selectedElementId = nil
    local entry = _COLOR_PALETTE[index]
    if entry then
        local el = _findElement(canvas, elementId)
        if el then
            _pushUndo(canvas)
            el.defaultColor = entry.color
            _notifyChanged(canvas)
        end
    end
end

-- Tapping outside the edit menu (or outside the confirm/properties menus it
-- leads to) cancels it — the element should no longer read as "selected"
-- once the edit flow it was selected for has ended.
function gdsGui_schematic_internal_onElementEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._elementEditTargetId = nil
        canvas.selectedElementId = nil
    end
end

-- Shared onSelect/onCancel for the delete-confirm menu above: both DELETE and
-- CANCEL land here (distinguished by optionText), as does tapping outside
-- (optionText is nil — treated the same as CANCEL).
function gdsGui_schematic_internal_onElementDeleteConfirmed(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local elementId = canvas._elementEditTargetId
    canvas._elementEditTargetId = nil
    canvas.selectedElementId = nil
    if optionText == "DELETE" and elementId then
        _pushUndo(canvas)
        gdsGui_schematic_removeElement(canvasName, elementId)
        _notifyChanged(canvas)
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ELEMENT RENAME (reached via the element edit
-- menu's RENAME option). Reuses the same label namespace/uniqueness rule as
-- initial placement (_labelInUse), just excluding the element's own current
-- label so re-confirming it (or only changing its case) isn't a false collision.
--------------------------------------------------------------------------------

-- Holds the element being renamed while the text prompt is open; only one
-- rename is ever in flight at a time, same shape as _pendingNamedPlacement.
local _pendingRename = nil   -- {canvasName, elementId}

function _openElementRenamePrompt(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el then return end
    canvas.selectedElementId = elementId
    _pendingRename = { canvasName = canvasName, elementId = elementId }
    gdsGui_textPrompt_open("RENAME \"" .. (el.label or elementId) .. "\"", el.label or "", 24,
        "gdsGui_schematic_elementRenameConfirmed", "gdsGui_schematic_elementRenameCancelled")
end

-- Resolved by name via _G[...] from textPrompt_gdsGuiLib.lua, like every other
-- string-registered callback in this library. onConfirmFunc receives only the
-- entered text (see gdsGui_textPrompt_confirm) — the target element comes
-- from _pendingRename, same pattern as gdsGui_schematic_placementNameConfirmed.
function gdsGui_schematic_elementRenameConfirmed(text)
    local pending = _pendingRename
    if not pending then return end
    local canvas = _findCanvas(pending.canvasName)
    local trimmed = (text or ""):gsub("^%s*(.-)%s*$", "%1")
    if not canvas then return end
    local el = _findElement(canvas, pending.elementId)
    if not el then
        _pendingRename = nil
        canvas.selectedElementId = nil
        return
    end
    if trimmed == "" then
        gdsGui_textPrompt_open("NAME REQUIRED, TRY AGAIN", trimmed, 24,
            "gdsGui_schematic_elementRenameConfirmed", "gdsGui_schematic_elementRenameCancelled")
        return
    end
    if _labelInUse(canvas, trimmed, "element", pending.elementId) then
        gdsGui_textPrompt_open("NAME TAKEN, TRY AGAIN", trimmed, 24,
            "gdsGui_schematic_elementRenameConfirmed", "gdsGui_schematic_elementRenameCancelled")
        return
    end
    _pushUndo(canvas)
    el.label = trimmed
    _pendingRename = nil
    canvas.selectedElementId = nil
    _notifyChanged(canvas)
end

function gdsGui_schematic_elementRenameCancelled()
    local pending = _pendingRename
    _pendingRename = nil
    if pending then
        local canvas = _findCanvas(pending.canvasName)
        if canvas then canvas.selectedElementId = nil end
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE WIRE EDIT MENU (color + delete, opened by a plain
-- tap on a wire while in design mode). Mirrors the element edit menu above,
-- minus PROPERTIES (wires carry no key/value list) — same base defaultColor
-- semantics otherwise.
--------------------------------------------------------------------------------

function gdsGui_schematic_openWireEditMenu(canvasName, wireId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local w = _findWire(canvas, wireId)
    if not w then return end
    canvas._wireEditTargetId = wireId
    _openSwatchColorMenu(canvasName, "WIRE: " .. wireId, {"DELETE"},
        "gdsGui_schematic_internal_onWireEditChosen", "gdsGui_schematic_internal_onWireEditCancelled")
end

function gdsGui_schematic_internal_onWireEditChosen(canvasName, index)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._wireEditTargetId then return end
    local wireId = canvas._wireEditTargetId
    local nColors = #_COLOR_PALETTE
    if index == nColors + 1 then
        -- DELETE tapped: confirm before actually removing it. Keep
        -- _wireEditTargetId set — the confirm/cancel handler below clears it.
        gdsGui_schematic_openMenu(canvasName, "DELETE \"WIRE: " .. wireId .. "\"?",
            {"DELETE", "CANCEL"}, "gdsGui_schematic_internal_onWireDeleteConfirmed",
            "gdsGui_schematic_internal_onWireDeleteConfirmed")
        return
    end
    canvas._wireEditTargetId = nil
    canvas.selectedWireId = nil
    local entry = _COLOR_PALETTE[index]
    if entry then
        local w = _findWire(canvas, wireId)
        if w then
            _pushUndo(canvas)
            w.defaultColor = entry.color
            _notifyChanged(canvas)
        end
    end
end

-- Tapping outside the edit menu (or outside the confirm step it leads to)
-- cancels it — the wire should no longer read as "selected" once the edit
-- flow it was selected for has ended.
function gdsGui_schematic_internal_onWireEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._wireEditTargetId = nil
        canvas.selectedWireId = nil
    end
end

-- Shared onSelect/onCancel for the delete-confirm menu above: both DELETE and
-- CANCEL land here (distinguished by optionText), as does tapping outside
-- (optionText is nil — treated the same as CANCEL).
function gdsGui_schematic_internal_onWireDeleteConfirmed(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local wireId = canvas._wireEditTargetId
    canvas._wireEditTargetId = nil
    canvas.selectedWireId = nil
    if optionText == "DELETE" and wireId then
        _pushUndo(canvas)
        gdsGui_schematic_removeWire(canvasName, wireId)
        _notifyChanged(canvas)
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE CONTROL EDIT MENU (position + delete, opened by a
-- plain tap on a control while in design mode; a drag still repositions it
-- instead, same tap-vs-drag gesture as the element/wire edit menus above). A
-- plain text list, not a swatch picker — controls have no color of their own
-- to set, just their named positions.
--------------------------------------------------------------------------------

function gdsGui_schematic_openControlEditMenu(canvasName, controlId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local ctrl = _findControl(canvas, controlId)
    if not ctrl then return end
    canvas._controlEditTargetId = controlId
    local options = {}
    for _, p in ipairs(ctrl.positions) do table.insert(options, p) end
    table.insert(options, "DELETE")
    gdsGui_schematic_openMenu(canvasName, ctrl.label or controlId, options,
        "gdsGui_schematic_internal_onControlEditChosen", "gdsGui_schematic_internal_onControlEditCancelled")
end

function gdsGui_schematic_internal_onControlEditChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._controlEditTargetId then return end
    local controlId = canvas._controlEditTargetId
    if optionText == "DELETE" then
        -- DELETE tapped: confirm before actually removing it. Keep
        -- _controlEditTargetId set — the confirm/cancel handler below clears it.
        local ctrl = _findControl(canvas, controlId)
        gdsGui_schematic_openMenu(canvasName, "DELETE \"" .. (ctrl and (ctrl.label or controlId) or controlId) .. "\"?",
            {"DELETE", "CANCEL"}, "gdsGui_schematic_internal_onControlDeleteConfirmed",
            "gdsGui_schematic_internal_onControlDeleteConfirmed")
        return
    end
    canvas._controlEditTargetId = nil
    canvas.selectedControlId = nil
    -- Pushed here, not inside gdsGui_schematic_setControlPosition itself —
    -- that function is also how control-mode "just operate the switch"
    -- cycles a position on every tap (gdsGui_schematic_pressed), which is
    -- deliberately NOT undoable (same as any other instrument interaction).
    -- This design-mode edit-menu path is a genuine edit though, same as
    -- every sibling mutation here (rename, delete, color pick, move).
    _pushUndo(canvas)
    gdsGui_schematic_setControlPosition(canvasName, controlId, index - 1)
    _notifyChanged(canvas)
end

-- Tapping outside the edit menu (or outside the confirm step it leads to)
-- cancels it — the control should no longer read as "selected" once the edit
-- flow it was selected for has ended.
function gdsGui_schematic_internal_onControlEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._controlEditTargetId = nil
        canvas.selectedControlId = nil
    end
end

-- Shared onSelect/onCancel for the delete-confirm menu above: both DELETE and
-- CANCEL land here (distinguished by optionText), as does tapping outside
-- (optionText is nil — treated the same as CANCEL).
function gdsGui_schematic_internal_onControlDeleteConfirmed(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local controlId = canvas._controlEditTargetId
    canvas._controlEditTargetId = nil
    canvas.selectedControlId = nil
    if optionText == "DELETE" and controlId then
        _pushUndo(canvas)
        gdsGui_schematic_removeControl(canvasName, controlId)
        _notifyChanged(canvas)
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ELEMENT PROPERTIES MENU (generic key/value list,
-- reached via the element edit menu's PROPERTIES option). The app layer
-- assigns meaning to keys (e.g. "VOLTAGE"/"CURRENT" for an electrical
-- element) — this module just stores and lets the user add/edit/delete them.
--------------------------------------------------------------------------------

-- Two-step "type a key, then type a value" text entry, shared by ADD PROPERTY
-- (key starts empty) and EDIT VALUE (key is already known). Only one of these
-- is ever in flight at a time, same as _pendingNamedPlacement above.
local _pendingPropertyEntry = nil

function _openPropertiesMenu(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el then return end
    canvas._elementEditTargetId = nil
    canvas._propertyEditTargetId = elementId
    canvas.selectedElementId = elementId
    local options = {}
    for _, p in ipairs(el.properties or {}) do
        table.insert(options, p.key .. ": " .. ((p.value == "" or p.value == nil) and "(not set)" or p.value))
    end
    table.insert(options, "ADD PROPERTY")
    table.insert(options, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "PROPERTIES: " .. (el.label or elementId), options,
        "gdsGui_schematic_internal_onPropertyRowChosen", "gdsGui_schematic_internal_onPropertiesCancelled")
end

function gdsGui_schematic_internal_onPropertiesCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._propertyEditTargetId = nil
        canvas.selectedElementId = nil
    end
end

function gdsGui_schematic_internal_onPropertyRowChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._propertyEditTargetId then return end
    local elementId = canvas._propertyEditTargetId
    if optionText == "RETURN" then
        canvas._propertyEditTargetId = nil
        canvas.selectedElementId = nil
        return
    elseif optionText == "ADD PROPERTY" then
        _pendingPropertyEntry = { canvasName = canvasName, elementId = elementId }
        gdsGui_textPrompt_open("NEW PROPERTY NAME (e.g. VOLTAGE)", "", 20,
            "gdsGui_schematic_propertyKeyConfirmed", "gdsGui_schematic_propertyEntryCancelled")
        return
    end
    local el = _findElement(canvas, elementId)
    local prop = el and el.properties and el.properties[index]
    if not prop then return end
    canvas._propertyActionKey = prop.key
    gdsGui_schematic_openMenu(canvasName, prop.key, {"EDIT VALUE", "DELETE PROPERTY", "RETURN"},
        "gdsGui_schematic_internal_onPropertyActionChosen", "gdsGui_schematic_internal_onPropertyActionCancelled")
end

function gdsGui_schematic_internal_onPropertyActionChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._propertyEditTargetId then return end
    local elementId = canvas._propertyEditTargetId
    local key = canvas._propertyActionKey
    if optionText == "EDIT VALUE" then
        local el = _findElement(canvas, elementId)
        local current = ""
        for _, p in ipairs((el and el.properties) or {}) do
            if p.key == key then current = p.value end
        end
        _pendingPropertyEntry = { canvasName = canvasName, elementId = elementId, key = key }
        gdsGui_textPrompt_open("VALUE FOR " .. key, current, 20,
            "gdsGui_schematic_propertyValueConfirmed", "gdsGui_schematic_propertyEntryCancelled")
    elseif optionText == "DELETE PROPERTY" then
        _pushUndo(canvas)
        gdsGui_schematic_removeElementProperty(canvasName, elementId, key)
        _notifyChanged(canvas)
        _openPropertiesMenu(canvasName, elementId)
    else -- RETURN
        _openPropertiesMenu(canvasName, elementId)
    end
end

function gdsGui_schematic_internal_onPropertyActionCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas and canvas._propertyEditTargetId then
        _openPropertiesMenu(canvasName, canvas._propertyEditTargetId)
    end
end

-- Resolved by name via _G[...] from textPrompt_gdsGuiLib.lua, like every other
-- string-registered callback in this library.
function gdsGui_schematic_propertyKeyConfirmed(text)
    local pending = _pendingPropertyEntry
    if not pending then return end
    local trimmed = (text or ""):gsub("^%s*(.-)%s*$", "%1"):upper()
    if trimmed == "" then
        gdsGui_textPrompt_open("NAME REQUIRED, TRY AGAIN", "", 20,
            "gdsGui_schematic_propertyKeyConfirmed", "gdsGui_schematic_propertyEntryCancelled")
        return
    end
    pending.key = trimmed
    gdsGui_textPrompt_open("VALUE FOR " .. trimmed, "", 20,
        "gdsGui_schematic_propertyValueConfirmed", "gdsGui_schematic_propertyEntryCancelled")
end

function gdsGui_schematic_propertyValueConfirmed(text)
    local pending = _pendingPropertyEntry
    _pendingPropertyEntry = nil
    if not pending then return end
    local canvas = _findCanvas(pending.canvasName)
    if canvas then _pushUndo(canvas) end
    gdsGui_schematic_setElementProperty(pending.canvasName, pending.elementId, pending.key, text or "")
    if canvas then _notifyChanged(canvas) end
    _openPropertiesMenu(pending.canvasName, pending.elementId)
end

function gdsGui_schematic_propertyEntryCancelled()
    local pending = _pendingPropertyEntry
    _pendingPropertyEntry = nil
    if pending then _openPropertiesMenu(pending.canvasName, pending.elementId) end
end

--------------------------------------------------------------------------------
-- PUBLIC API — SIGNATURE / SNAPSHOT-AS-RULE COLOR RESOLUTION
--------------------------------------------------------------------------------

--[[
    Pure signature builder — independent of any live canvas, directly
    unit-testable. controlStates is an array of {id=string, detentIndex=number}.
    Sorted by id so the same combination always produces the same string
    regardless of input order.
]]
function gdsGui_schematic_buildSignature(controlStates)
    local sorted = {}
    for _, cs in ipairs(controlStates) do table.insert(sorted, cs) end
    table.sort(sorted, function(a, b) return a.id < b.id end)
    local parts = {}
    for _, cs in ipairs(sorted) do
        table.insert(parts, cs.id .. "=" .. tostring(cs.detentIndex))
    end
    return table.concat(parts, ",")
end

function gdsGui_schematic_computeSignature(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return "" end
    local states = {}
    for _, c in ipairs(canvas.controls) do
        table.insert(states, { id = c.id, detentIndex = c.detentIndex })
    end
    return gdsGui_schematic_buildSignature(states)
end

local function _colorEquals(c1, c2)
    if not c1 or not c2 then return false end
    return c1[1] == c2[1] and c1[2] == c2[2] and c1[3] == c2[3] and c1[4] == c2[4]
end

-- Pure conflict check: true if `candidate` assigns a different color than
-- `existing` for any id the two snapshots share.
function gdsGui_schematic_colorsDiffer(existing, candidate)
    for id, col in pairs(candidate.elements or {}) do
        local ex = existing.elements and existing.elements[id]
        if ex and not _colorEquals(ex, col) then return true end
    end
    for id, col in pairs(candidate.wires or {}) do
        local ex = existing.wires and existing.wires[id]
        if ex and not _colorEquals(ex, col) then return true end
    end
    return false
end

-- targetKind: "element" | "wire". Returns r,g,b,a for the entity's live resolved color:
-- 1) a pending color-picker override, else 2) the snapshot matching the current
-- control-position signature, else 3) the entity's default (gray) color.
function gdsGui_schematic_resolveColor(canvasName, targetKind, targetId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] end
    -- Not the "A and B or C" idiom: _findElement can itself return nil for
    -- a bad targetId, which would otherwise silently fall through to a
    -- wire lookup and resolve the WRONG object's color if a wire happened
    -- to share that id.
    local target
    if targetKind == "element" then target = _findElement(canvas, targetId)
    else target = _findWire(canvas, targetId) end
    if not target then return _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] end

    if target.pendingColor then
        local c = target.pendingColor
        return c[1], c[2], c[3], c[4]
    end

    local signature = gdsGui_schematic_computeSignature(canvasName)
    local snap = canvas.snapshots[signature]
    if snap then
        local bucket = (targetKind == "element") and snap.elements or snap.wires
        local c = bucket and bucket[targetId]
        if c then return c[1], c[2], c[3], c[4] end
    end

    local dc = target.defaultColor
    return dc[1], dc[2], dc[3], dc[4]
end

-- Like resolveColor above, but this is the one actually drawn on the canvas
-- (_drawElement/_drawWire below) — snapshot playback only ever applies in
-- CONTROL (operate) mode. In DESIGN mode, repositioning a control to set up
-- a capture target must never itself change what's shown (a pendingColor
-- preview from ASSIGN COLOR still shows); only an explicit CAPTURE SNAPSHOT
-- changes the picture. gdsGui_schematic_prepareSnapshot still calls the full
-- resolveColor above directly, so a recapture correctly preserves every
-- other element/wire's previously-captured color for this signature.
function gdsGui_schematic_resolveDisplayColor(canvasName, targetKind, targetId)
    local canvas = _findCanvas(canvasName)
    if canvas and canvas.mode == "design" then
        local target
        if targetKind == "element" then target = _findElement(canvas, targetId)
        else target = _findWire(canvas, targetId) end
        if not target then return _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] end
        if target.pendingColor then
            local c = target.pendingColor
            return c[1], c[2], c[3], c[4]
        end
        local dc = target.defaultColor
        return dc[1], dc[2], dc[3], dc[4]
    end
    return gdsGui_schematic_resolveColor(canvasName, targetKind, targetId)
end

-- Existing snapshot keys whose captured control conditions agree with
-- currentStates (id -> detentIndex) on every control id the two have in
-- common. A control added or removed since an old snapshot was captured
-- changes canvas's signature string, so an exact-key lookup alone would
-- leave that old snapshot orphaned (unreachable forever) while a
-- disconnected duplicate accumulates under the new signature. Comparing
-- only the shared ids treats "same conditions, plus/minus a control" as
-- the same captured scenario, so capturing again finds and replaces it
-- instead. (If several old keys all reduce to the same shared-id
-- conditions — possible once the control that distinguished them is
-- removed — all of them match and get folded into the one new capture.)
local function _matchingSnapshotKeys(canvas, currentStates)
    local matches = {}
    for key in pairs(canvas.snapshots) do
        local oldStates = _parseSignature(key)
        -- An empty oldStates (the "no controls yet" baseline "" key) has
        -- nothing to disagree on and always matches, by design. Otherwise
        -- at least one id must actually be shared with currentStates — zero
        -- overlap means every old control was removed and replaced with
        -- entirely unrelated ones, which is a different scenario, not a
        -- continuation of the old one, and must not match (it would
        -- otherwise agree vacuously and get folded/deleted below).
        local agree, sharedAny = true, false
        for id, val in pairs(oldStates) do
            local cur = currentStates[id]
            if cur ~= nil then
                sharedAny = true
                if cur ~= val then agree = false; break end
            end
        end
        if agree and (sharedAny or next(oldStates) == nil) then table.insert(matches, key) end
    end
    return matches
end

--[[
    Builds (without saving) the snapshot that would be captured for the
    current control-position signature: every element/wire's live resolved
    color (so manual color-picker overrides are included), plus whether this
    would conflict with a different snapshot already stored at that same
    signature. plan.replacesKeys lists every existing snapshot key (if any —
    usually just the current signature itself, but see _matchingSnapshotKeys
    for the added/removed-control case) that gdsGui_schematic_commitSnapshot
    will delete in favor of this capture. The caller (app layer) decides
    whether to prompt and then calls gdsGui_schematic_commitSnapshot with
    this same plan table.
]]
function gdsGui_schematic_prepareSnapshot(canvasName)
    local canvas = _findCanvas(canvasName)
    local plan = { signature = "", elements = {}, wires = {}, conflict = nil, hasConflict = false, replacesKeys = {} }
    if not canvas then return plan end
    plan.signature = gdsGui_schematic_computeSignature(canvasName)

    local currentStates = {}
    for _, c in ipairs(canvas.controls) do currentStates[c.id] = c.detentIndex end
    plan.replacesKeys = _matchingSnapshotKeys(canvas, currentStates)

    -- gdsGui_schematic_resolveColor's own fallback chain (pendingColor,
    -- then a snapshot already at THIS EXACT signature) has no way to see a
    -- DIFFERENT, now-replaced signature's snapshot — so without this, an
    -- element/wire that isn't currently overridden and was never captured
    -- under the brand-new signature would resolve to its bare
    -- defaultColor, silently discarding whatever color a migrated old
    -- entry (see plan.replacesKeys above) had taught it under the old
    -- signature, even though that entry is about to be deleted in favor of
    -- this very capture. Use its color as one more fallback tier, below
    -- pendingColor/exact-match but above defaultColor.
    local migratedFrom = plan.replacesKeys[1] and canvas.snapshots[plan.replacesKeys[1]]
    local exactSnapshot = canvas.snapshots[plan.signature]
    for _, e in ipairs(canvas.elements) do
        local r, g, b, a = gdsGui_schematic_resolveColor(canvasName, "element", e.id)
        if not e.pendingColor and not (exactSnapshot and exactSnapshot.elements[e.id])
           and migratedFrom and migratedFrom.elements[e.id] then
            local c = migratedFrom.elements[e.id]
            r, g, b, a = c[1], c[2], c[3], c[4]
        end
        plan.elements[e.id] = { r, g, b, a }
    end
    for _, w in ipairs(canvas.wires) do
        local r, g, b, a = gdsGui_schematic_resolveColor(canvasName, "wire", w.id)
        if not w.pendingColor and not (exactSnapshot and exactSnapshot.wires[w.id])
           and migratedFrom and migratedFrom.wires[w.id] then
            local c = migratedFrom.wires[w.id]
            r, g, b, a = c[1], c[2], c[3], c[4]
        end
        plan.wires[w.id] = { r, g, b, a }
    end

    -- Conflict is only ever flagged against an EXACT signature match — i.e.
    -- re-capturing the identical combination with a different color, the
    -- established "are you sure" case. A structural match from an
    -- added/removed control (a different signature string) is folded in
    -- via replacesKeys without prompting: that old snapshot was already
    -- unreachable the moment the control set changed, so there's nothing
    -- for the user to knowingly contradict.
    if exactSnapshot then
        plan.conflict = exactSnapshot
        plan.hasConflict = gdsGui_schematic_colorsDiffer(exactSnapshot, plan)
    end
    return plan
end

-- Saves (or overwrites) the snapshot for plan.signature, first deleting
-- every key in plan.replacesKeys (orphaned snapshots from before a control
-- was added/removed that represent this same captured condition — see
-- _matchingSnapshotKeys), and clears every element/wire's pending
-- color-picker override now that it is baked in.
function gdsGui_schematic_commitSnapshot(canvasName, plan)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    for _, key in ipairs(plan.replacesKeys or {}) do
        canvas.snapshots[key] = nil
    end
    canvas.snapshots[plan.signature] = {
        elements = plan.elements, wires = plan.wires,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    }
    for _, e in ipairs(canvas.elements) do e.pendingColor = nil end
    for _, w in ipairs(canvas.wires) do w.pendingColor = nil end
end

function gdsGui_schematic_countSnapshots(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return 0 end
    local n = 0
    for _ in pairs(canvas.snapshots) do n = n + 1 end
    return n
end

function gdsGui_schematic_removeSnapshot(canvasName, signature)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.snapshots[signature] = nil end
end

--------------------------------------------------------------------------------
-- DRAWING
--------------------------------------------------------------------------------

-- Grid lines live at fixed canvas-box positions spaced _GRID_SPACING_PX/zoom
-- apart, so on screen they land _GRID_SPACING_PX apart regardless of zoom
-- level (constant visual density) while the underlying world-space cell
-- shrinks as the user zooms in, exposing finer positions to place on/snap to.
local function _drawGrid(canvas)
    love.graphics.setColor(1, 1, 1, 0.06)
    local spacing = _GRID_SPACING_PX / canvas.zoom
    local x0, y0, x1, y1 = canvas.x, canvas.y, canvas.x + canvas.w, canvas.y + canvas.h

    local worldLeft = (x0 - canvas.x - canvas.panX) / canvas.zoom
    local worldRight = (x1 - canvas.x - canvas.panX) / canvas.zoom
    local gx = math.floor(worldLeft / spacing) * spacing
    while gx <= worldRight do
        local sx = canvas.x + canvas.panX + gx * canvas.zoom
        love.graphics.line(sx, y0, sx, y1)
        gx = gx + spacing
    end

    local worldTop = (y0 - canvas.y - canvas.panY) / canvas.zoom
    local worldBottom = (y1 - canvas.y - canvas.panY) / canvas.zoom
    local gy = math.floor(worldTop / spacing) * spacing
    while gy <= worldBottom do
        local sy = canvas.y + canvas.panY + gy * canvas.zoom
        love.graphics.line(x0, sy, x1, sy)
        gy = gy + spacing
    end
end

-- Caches an element's sprite image by path, same lazy-load-once pattern as
-- _loadGalleryImage further below (kept separate since that one is defined
-- after this point in the file and elements are drawn far more often per
-- frame than gallery tiles are rebuilt).
local _elementSpriteCache = {}
local function _loadElementSprite(path)
    if not _elementSpriteCache[path] then
        _elementSpriteCache[path] = love.graphics.newImage(path)
    end
    return _elementSpriteCache[path]
end

-- Draws a spritePath image (an element's own, or a control's spritePaths
-- entry for its current detent — see gdsGui_schematic_addControl) letterboxed
-- into the given box (tinted by r,g,b,a — the normal resolved color, so
-- snapshot/pending color overrides still read on a sprite the same as they
-- do on a plain rect/circle). Scales to fit, not to fill, so a non-square
-- source image (or box) never gets stretched out of proportion. rotationDeg
-- (optional, 0/90/180/270, see _snapRotationDegrees) spins it around the
-- box's own center — same cardinal-orientation convention as
-- _drawDiodeSymbol, just generalized to any image instead of hand-drawn
-- line art.
local function _drawElementSprite(path, ex, ey, ew, eh, r, g, b, a, rotationDeg)
    local image = _loadElementSprite(path)
    local iw, ih = image:getDimensions()
    local scale = math.min(ew / iw, eh / ih)
    local drawW, drawH = iw * scale, ih * scale
    love.graphics.setColor(r, g, b, a)
    if rotationDeg and rotationDeg ~= 0 then
        love.graphics.push()
        love.graphics.translate(ex + ew / 2, ey + eh / 2)
        love.graphics.rotate(math.rad(rotationDeg))
        love.graphics.draw(image, -drawW / 2, -drawH / 2, 0, scale, scale)
        love.graphics.pop()
    else
        love.graphics.draw(image, ex + (ew - drawW) / 2, ey + (eh - drawH) / 2, 0, scale, scale)
    end
end

-- Standard diode symbol (triangle + cathode bar, no leads) pointing right
-- at rotation 0; rotationDeg (0/90/180/270, see
-- _snapRotationDegrees) spins it to the other 3 cardinal directions. Colored
-- like every other shape (an element's resolved color), since a diode can
-- still carry a snapshot/pending color override.
local function _drawDiodeSymbol(cx, cy, ew, eh, rotationDeg, r, g, b, a)
    local halfW, halfH = ew / 2 * 0.7, eh / 2 * 0.7
    local barX = halfW * 0.7
    love.graphics.push()
    love.graphics.translate(cx, cy)
    love.graphics.rotate(math.rad(rotationDeg or 0))
    love.graphics.setColor(r, g, b, a)
    love.graphics.setLineWidth(2)
    love.graphics.polygon("fill", -barX, -halfH * 0.7, -barX, halfH * 0.7, barX, 0)
    love.graphics.line(barX, -halfH * 0.7, barX, halfH * 0.7)
    love.graphics.setLineWidth(1)
    love.graphics.pop()
end

local function _drawElement(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    local r, g, b, a = gdsGui_schematic_resolveDisplayColor(canvas.name, "element", e.id)
    love.graphics.setColor(r, g, b, a)
    if e.spritePath then
        _drawElementSprite(e.spritePath, ex, ey, ew, eh, r, g, b, a, e.rotation)
        love.graphics.setColor(1, 1, 1, 1)
    elseif e.shapeType == "circle" then
        love.graphics.ellipse("fill", ex + ew / 2, ey + eh / 2, ew / 2, eh / 2)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.ellipse("line", ex + ew / 2, ey + eh / 2, ew / 2, eh / 2)
    elseif e.shapeType == "diode" then
        _drawDiodeSymbol(ex + ew / 2, ey + eh / 2, ew, eh, e.rotation, r, g, b, a)
        love.graphics.setColor(1, 1, 1, 1)
    else
        love.graphics.rectangle("fill", ex, ey, ew, eh)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("line", ex, ey, ew, eh)
    end
    if canvas.selectedElementId == e.id then
        -- Magenta once the 2-second hold has unlocked drag/rotate for it
        -- (see gdsGui_schematic_update's long-press timer) — yellow is
        -- still "selected, but a drag here won't move/rotate it; a tap
        -- opens its menu, or hold to unlock that."
        if canvas.selectionMoveModeActive then
            love.graphics.setColor(1, 0, 1, 1)
        else
            love.graphics.setColor(1, 1, 0, 1)
        end
        love.graphics.rectangle("line", ex - 3, ey - 3, ew + 6, eh + 6)
    end
    if e.label then
        love.graphics.setColor(1, 1, 1, 1)
        if e.shapeType == "diode" or e.spritePath then
            -- A diode has no filled body to back the label against (just
            -- thin lines), and at a 90/270 rotation those lines run right
            -- through the box's vertical center — so unlike every other
            -- shape, its label sits below the box instead of across it. A
            -- sprite is the same problem from the opposite direction: it
            -- DOES fill most of the box with actual art, which centered
            -- text would just overlap.
            love.graphics.printf(e.label, ex, ey + eh + 2, ew, "center")
        else
            love.graphics.printf(e.label, ex, ey + eh / 2 - 6, ew, "center")
        end
    end
end

-- Draws a right-angle (horizontal-then-vertical) connector between two points
-- instead of a diagonal line, matching conventional schematic/flowchart routing.
local function _drawOrthogonalLine(x1, y1, x2, y2)
    if x1 == x2 or y1 == y2 then
        love.graphics.line(x1, y1, x2, y2)
    else
        love.graphics.line(x1, y1, x2, y1, x2, y2)
    end
end

-- Where a purely-horizontal or purely-vertical ray from an anchor's own
-- center (cx,cy), travelling outward along one axis, exits that anchor's own
-- shape — the rectangle for a "rect" element, the ellipse for a "circle"
-- element (ew/eh may differ), or the circle for a control. Since the
-- orthogonal wire routing below only ever approaches an anchor along a
-- single axis, this is just the matching half-extent in that direction, not
-- a general ray/shape intersection.
--
-- A "diode" element has no filled body reaching its own bounding box (just
-- thin line art shrunk well inside it — see _drawDiodeSymbol), so clamping
-- to that box's edge like a rect/circle would leave the connector dangling
-- in empty space, visibly disconnected from the drawn symbol (and forming a
-- stray jog wherever the routed path bends). It connects straight to its
-- own center instead, same as a control.
-- Half-extent of an anchor's own shape along one screen axis (same value
-- for both axes of a control's circle) — a diode reports 0 since it has no
-- filled body reaching its bounding box (see _anchorEdgePoint below), and a
-- nil anchor (the live wire-drag preview's loose cursor/finger end) reports
-- 0 too, since there's no shape there to clear.
local function _anchorHalfExtent(canvas, anchor, axis)
    if not anchor or anchor.shapeType == "diode" then return 0 end
    if anchor.w then
        local _, _, ew, eh = _elementPixelRect(canvas, anchor)
        return (axis == "x") and (ew / 2) or (eh / 2)
    end
    return canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1)
end

local function _anchorEdgePoint(canvas, anchor, cx, cy, axis, sign)
    if anchor and anchor.shapeType == "diode" then return cx, cy end
    local half = _anchorHalfExtent(canvas, anchor, axis)
    if axis == "x" then
        return cx + sign * half, cy
    end
    return cx, cy + sign * half
end

-- Returns the 1-3 straight, axis-aligned segments {x1,y1,x2,y2} making up an
-- orthogonal connector's clamped path between two anchors — the same
-- geometry _drawWire renders, factored out so the crossing/overlap analysis
-- below can reason about exactly what gets drawn. Either anchor may be
-- omitted (nil) to leave that end at the raw point passed in (used by the
-- live wire-drag preview's loose cursor/finger end, which isn't anchored to
-- anything yet). forceAxis ("h", "v", or nil/omitted for the automatic
-- default below) lets a wire's user-set directionOverride (see
-- gdsGui_schematic_pressed/_moved's "wireDirection" dragKind) win the
-- h-first-vs-v-first choice when both anchors are offset on both axes and
-- either bend would look equally clean; it has no effect when only one
-- orientation is actually clean (no real choice to make) or when the
-- anchors are already aligned on one axis (single straight segment).
local function _clampedOrthogonalSegments(canvas, fromAnchor, x1, y1, toAnchor, x2, y2, forceAxis)
    if x1 == x2 and y1 == y2 then return {} end
    if y1 == y2 then
        local sx = (x2 > x1) and 1 or -1
        if fromAnchor then x1, y1 = _anchorEdgePoint(canvas, fromAnchor, x1, y1, "x", sx) end
        if toAnchor   then x2, y2 = _anchorEdgePoint(canvas, toAnchor,   x2, y2, "x", -sx) end
        return { { x1, y1, x2, y2 } }
    elseif x1 == x2 then
        local sy = (y2 > y1) and 1 or -1
        if fromAnchor then x1, y1 = _anchorEdgePoint(canvas, fromAnchor, x1, y1, "y", sy) end
        if toAnchor   then x2, y2 = _anchorEdgePoint(canvas, toAnchor,   x2, y2, "y", -sy) end
        return { { x1, y1, x2, y2 } }
    end

    -- Two anchors offset on both axes. The simplest bend — always
    -- horizontal-then-vertical, corner at (x2,y1) — can leave a degenerate
    -- jog shorter than the radius of whichever anchor sits at that
    -- segment's end, when the two anchors are almost (but not quite)
    -- aligned on one axis. That renders as a stray stub poking INTO that
    -- anchor's own shape instead of a connector visibly reaching its edge
    -- (e.g. two same-sized controls placed nearly, but not perfectly,
    -- level with each other). Try both possible single-bend orientations
    -- (preferring the historical horizontal-first default when it's fine),
    -- and only fall back to a 3-segment route — its single perpendicular
    -- jog placed safely in the open space between the two anchors, rather
    -- than at either one — when neither single bend can clear both ends.
    local fromHalfX, fromHalfY = _anchorHalfExtent(canvas, fromAnchor, "x"), _anchorHalfExtent(canvas, fromAnchor, "y")
    local toHalfX, toHalfY     = _anchorHalfExtent(canvas, toAnchor, "x"), _anchorHalfExtent(canvas, toAnchor, "y")
    local dx, dy = math.abs(x2 - x1), math.abs(y2 - y1)
    local margin = 1
    local hFirstClean = (dx > fromHalfX + margin) and (dy > toHalfY + margin)
    local vFirstClean = (dy > fromHalfY + margin) and (dx > toHalfX + margin)

    local sx = (x2 > x1) and 1 or -1
    local sy = (y2 > y1) and 1 or -1

    -- Both bends clean (anchors genuinely diagonal, either orientation
    -- works) is exactly the ambiguous case forceAxis is for — let a "v"
    -- override win it instead of the historical h-first default. Outside
    -- that ambiguous case there's no real choice, so forceAxis is ignored
    -- and whichever orientation is actually clean (or the 3-segment
    -- fallback) is used same as always.
    if hFirstClean and not (forceAxis == "v" and vFirstClean) then
        local fx1, fy1 = _anchorEdgePoint(canvas, fromAnchor, x1, y1, "x", sx)
        local tx2, ty2 = _anchorEdgePoint(canvas, toAnchor, x2, y2, "y", -sy)
        return { { fx1, fy1, x2, fy1 }, { x2, fy1, tx2, ty2 } }
    elseif vFirstClean then
        local fx1, fy1 = _anchorEdgePoint(canvas, fromAnchor, x1, y1, "y", sy)
        local tx2, ty2 = _anchorEdgePoint(canvas, toAnchor, x2, y2, "x", -sx)
        return { { fx1, fy1, fx1, y2 }, { fx1, y2, tx2, ty2 } }
    elseif dy <= math.max(fromHalfY, toHalfY) + margin then
        -- The Y-separation is too small to clear either anchor — exit both
        -- horizontally and put the one vertical jog safely between them.
        local fx1, fy1 = _anchorEdgePoint(canvas, fromAnchor, x1, y1, "x", sx)
        local fx2, fy2 = _anchorEdgePoint(canvas, toAnchor, x2, y2, "x", -sx)
        local midX = (fx1 + fx2) / 2
        return { { fx1, fy1, midX, fy1 }, { midX, fy1, midX, fy2 }, { midX, fy2, fx2, fy2 } }
    else
        -- The X-separation is too small instead — exit both vertically and
        -- put the one horizontal jog safely between them.
        local fx1, fy1 = _anchorEdgePoint(canvas, fromAnchor, x1, y1, "y", sy)
        local fx2, fy2 = _anchorEdgePoint(canvas, toAnchor, x2, y2, "y", -sy)
        local midY = (fy1 + fy2) / 2
        return { { fx1, fy1, fx1, midY }, { fx1, midY, fx2, midY }, { fx2, midY, fx2, fy2 } }
    end
end

-- Fixed, deterministic perpendicular direction for an axis-aligned segment
-- (up for horizontal, left for vertical) — used both for the parallel-lane
-- offset and the crossing hop's bulge, so everything reads as "the same
-- side" consistently across the whole canvas.
local function _segmentPerp(y1, y2)
    if y1 == y2 then return 0, -1 end
    return -1, 0
end

-- Do two perpendicular (one horizontal, one vertical) segments cross at a
-- point strictly inside both — i.e. a true mid-path crossing, not merely
-- touching at one of their own endpoints (a shared anchor or bend corner)?
-- Parallel/collinear pairs (both horizontal or both vertical) are never a
-- "crossing" in this sense — see the duplicate-anchor-pair lane offset
-- below for how those are handled instead.
local function _segmentsCross(segA, segB)
    local ax1, ay1, ax2, ay2 = segA[1], segA[2], segA[3], segA[4]
    local bx1, by1, bx2, by2 = segB[1], segB[2], segB[3], segB[4]
    local aHoriz, bHoriz = (ay1 == ay2), (by1 == by2)
    if aHoriz == bHoriz then return false end
    local hx, hy, aLo, aHi, bLo, bHi
    if aHoriz then
        hx, hy = bx1, ay1
        aLo, aHi = math.min(ax1, ax2), math.max(ax1, ax2)
        bLo, bHi = math.min(by1, by2), math.max(by1, by2)
    else
        hx, hy = ax1, by1
        aLo, aHi = math.min(ay1, ay2), math.max(ay1, ay2)
        bLo, bHi = math.min(bx1, bx2), math.max(bx1, bx2)
    end
    local onA = aHoriz and hx or hy
    local onB = aHoriz and hy or hx
    if onA > aLo + 0.5 and onA < aHi - 0.5 and onB > bLo + 0.5 and onB < bHi - 0.5 then
        return true, hx, hy
    end
    return false
end

local function _distAlongSegment(seg, x, y)
    if seg[1] == seg[3] then return math.abs(y - seg[2]) end
    return math.abs(x - seg[1])
end

-- Nearest-pixel rounding for the collinear-line grouping key below —
-- segments computed from independently-positioned anchors can differ by
-- sub-pixel float error even when they're meant to run along the exact
-- same line, and a sub-pixel gap isn't visually distinguishable anyway.
local function _roundPx(v) return math.floor(v + 0.5) end

-- The point at the given coordinate along seg's own fixed line (an x value
-- for a vertical segment's shared x, a y value for a horizontal segment's
-- shared y) — the inverse of what _distAlongSegment measures, used to
-- convert an absolute overlap-range boundary back into a point on seg.
local function _pointOnLine(seg, coord)
    if seg[2] == seg[4] then return coord, seg[2] end
    return seg[1], coord
end

-- Draws one straight axis-aligned segment, inserting a small semicircular
-- hop at each distance in hopDistances (the conventional "not electrically
-- connected" symbol for two crossing wires), and/or a perpendicular offset
-- over each {lo, hi, offset} zone in offsetRanges — with a short unsplit
-- stub at whichever end(s) touch a real anchor (stubStart/stubEnd) — how
-- colocated/overlapping parallel wires are kept from merging into one
-- indistinguishable line. Zones don't have to span the whole segment (see
-- _computeWirePlans: two wires may only share part of their path), so any
-- distance not covered by a zone draws at zero offset. Hops and the lane
-- offset compose naturally: a hop's arc is centered on whatever point this
-- segment would otherwise be drawn at (offset or not), since both go
-- through the same pointAt().
local function _drawSegmentWithHopsAndOffset(x1, y1, x2, y2, hopDistances, offsetRanges, stubStart, stubEnd, zoom)
    zoom = zoom or 1
    local stubPx = _WIRE_PARALLEL_STUB_PX * zoom
    local hopRadiusPx = _WIRE_CROSS_HOP_RADIUS_PX * zoom
    local horiz = (y1 == y2)
    local dirX, dirY
    if horiz then dirX, dirY = (x2 > x1) and 1 or -1, 0
    else          dirX, dirY = 0, (y2 > y1) and 1 or -1 end
    local length = horiz and math.abs(x2 - x1) or math.abs(y2 - y1)
    local perpX, perpY = _segmentPerp(y1, y2)
    offsetRanges = offsetRanges or {}

    local function offsetAt(d)
        if #offsetRanges == 0 then return 0, 0 end
        if stubStart and d < stubPx then return 0, 0 end
        if stubEnd and d > length - stubPx then return 0, 0 end
        for _, r in ipairs(offsetRanges) do
            if d >= r.lo - 0.01 and d <= r.hi + 0.01 then
                return perpX * r.offset, perpY * r.offset
            end
        end
        return 0, 0
    end

    local function pointAt(d)
        local offX, offY = offsetAt(d)
        return x1 + dirX * d + offX, y1 + dirY * d + offY
    end

    local cuts = { 0, length }
    if #offsetRanges > 0 then
        for _, r in ipairs(offsetRanges) do
            if r.lo > 0 and r.lo < length then table.insert(cuts, r.lo) end
            if r.hi > 0 and r.hi < length then table.insert(cuts, r.hi) end
        end
        if stubStart and stubPx < length then table.insert(cuts, stubPx) end
        if stubEnd and length - stubPx > 0 then table.insert(cuts, length - stubPx) end
    end
    local hopRanges = {}
    for _, d in ipairs(hopDistances or {}) do
        local lo = math.max(0, d - hopRadiusPx)
        local hi = math.min(length, d + hopRadiusPx)
        table.insert(cuts, lo)
        table.insert(cuts, hi)
        table.insert(hopRanges, { lo = lo, hi = hi, center = d })
    end
    table.sort(cuts)
    local dedup = {}
    for _, c in ipairs(cuts) do
        if #dedup == 0 or (c - dedup[#dedup]) > 0.01 then table.insert(dedup, c) end
    end
    cuts = dedup

    for i = 1, #cuts - 1 do
        local a, b = cuts[i], cuts[i + 1]
        local mid = (a + b) / 2
        local inHop = nil
        for _, hr in ipairs(hopRanges) do
            if mid >= hr.lo and mid <= hr.hi then inHop = hr end
        end
        if inHop then
            local cxp, cyp = pointAt(inHop.center)
            local startAngle, endAngle
            if horiz then startAngle, endAngle = math.pi, math.pi * 2
            else          startAngle, endAngle = math.pi / 2, math.pi * 1.5 end
            love.graphics.arc("line", "open", cxp, cyp, hopRadiusPx, startAngle, endAngle)
        else
            local ax, ay = pointAt(a)
            local bx, by = pointAt(b)
            love.graphics.line(ax, ay, bx, by)
        end
    end

    -- This segment's actual (post-offset) drawn start/end, for
    -- _drawWirePlanSegments/_drawClampedOrthogonalLine below to bridge the
    -- gap a shared bend corner would otherwise leave — see their own
    -- comments for why that gap exists.
    local startX, startY = pointAt(0)
    local endX, endY = pointAt(length)
    return startX, startY, endX, endY
end

-- Draws every segment of a precomputed wire plan (see _computeWirePlans),
-- applying that wire's own hop points and lane-offset zones per segment.
-- Each segment only carries its OWN lane offset along its OWN axis (a
-- vertical segment's offset shifts its x; a horizontal one shifts its y —
-- see _drawSegmentWithHopsAndOffset), so a lane that isn't exactly centered
-- has the previous segment's real (post-offset) end land at a different
-- point than the next one's real start, with nothing drawn between them.
-- _bridgeSegmentJoint below connects them with the natural right-angle
-- corner (the previous segment's own offset axis combined with the next
-- one's) so overlapping lanes read as the nested, staggered-corner bends
-- real parallel bus routing uses instead of a gap or a diagonal cut corner.
local function _bridgeSegmentJoint(prevEndX, prevEndY, prevVertical, startX, startY, halfW)
    local cornerX = prevVertical and prevEndX or startX
    local cornerY = prevVertical and startY or prevEndY
    -- One connected 3-point polyline, not two separate love.graphics.line()
    -- calls, so its own internal corner joins cleanly; each of its two
    -- junctions against the segments' own separate line draws still gets
    -- the same small square patch _drawSegmentWithHopsAndOffset's own
    -- butt-cap notch needs (see its comment).
    love.graphics.line(prevEndX, prevEndY, cornerX, cornerY, startX, startY)
    love.graphics.rectangle("fill", prevEndX - halfW, prevEndY - halfW, halfW * 2, halfW * 2)
    love.graphics.rectangle("fill", startX - halfW, startY - halfW, halfW * 2, halfW * 2)
end

local function _drawWirePlanSegments(plan, zoom)
    local n = #plan.segments
    local halfW = love.graphics.getLineWidth() / 2
    local prevEndX, prevEndY, prevVertical
    for idx, seg in ipairs(plan.segments) do
        local stubStart, stubEnd = (idx == 1), (idx == n)
        local startX, startY, endX, endY = _drawSegmentWithHopsAndOffset(
            seg[1], seg[2], seg[3], seg[4], plan.hopDistances[idx], plan.offsetRanges[idx], stubStart, stubEnd, zoom)
        if idx > 1 then
            _bridgeSegmentJoint(prevEndX, prevEndY, prevVertical, startX, startY, halfW)
        end
        prevEndX, prevEndY = endX, endY
        prevVertical = (seg[1] == seg[3])
    end
end

-- Draws an orthogonal connector line between two anchors' centers, clamped
-- to each anchor's own edge, with no hop/lane-offset treatment — used by the
-- live wire-drag preview and the (unrelated-to-other-wires) selection
-- highlight pass, neither of which need the cross-wire analysis below.
local function _drawClampedOrthogonalLine(canvas, fromAnchor, x1, y1, toAnchor, x2, y2)
    local segments = _clampedOrthogonalSegments(canvas, fromAnchor, x1, y1, toAnchor, x2, y2)
    local halfW = love.graphics.getLineWidth() / 2
    local prevEndX, prevEndY, prevVertical
    for idx, seg in ipairs(segments) do
        local startX, startY, endX, endY =
            _drawSegmentWithHopsAndOffset(seg[1], seg[2], seg[3], seg[4], nil, nil, false, false, canvas.zoom)
        -- Same bend-corner joint bridge as _drawWirePlanSegments above —
        -- see its comment (collapses to a no-op here in practice, since
        -- this preview has no lane offsets to bridge between, but kept for
        -- the same stray butt-cap notch at a plain, unoffset corner).
        if idx > 1 then
            _bridgeSegmentJoint(prevEndX, prevEndY, prevVertical, startX, startY, halfW)
        end
        prevEndX, prevEndY = endX, endY
        prevVertical = (seg[1] == seg[3])
    end
end

-- Precomputes, for every wire on the canvas, the crossing-hop points and/or
-- parallel-lane offset zones needed to render the two conventional "these
-- are not the same connection" cues:
--   - ANY two (or more) segments — from any wires, not just ones sharing
--     both anchors — that run along the exact same line and overlap are
--     split into evenly-spaced parallel lanes (see _WIRE_PARALLEL_GAP_PX)
--     over just the overlapping stretch, instead of overlapping into one
--     indistinguishable line. A classic duplicate connector (same two
--     anchors on both wires) is just the special case where the overlap
--     happens to span each wire's entire path;
--   - any OTHER pair of wires whose paths cross at a true interior point
--     gets a small arc hop on the later-added wire (by creation order in
--     canvas.wires), the standard "not electrically connected" symbol.
-- Three+-way overlap groups are handled (evenly spaced, not just pairwise),
-- and since the offset is computed per overlapping sub-range rather than
-- once for the whole wire, a wire's lane count/position can change partway
-- along its path if which other wires it overlaps changes there. A wire
-- that's simultaneously in an overlap group AND crosses some unrelated
-- third wire still gets both treatments correctly (see
-- _drawSegmentWithHopsAndOffset).
-- Cheap O(n) fingerprint of everything _computeWirePlans' result depends on
-- (every anchor's position/rotation, the wire list itself, and the view
-- transform), so gdsGui_schematic_draw can skip the expensive O(wires^2 *
-- segments^2) crossing/parallel-lane analysis below on frames where nothing
-- actually changed (the common case: a canvas just sitting on screen).
local function _wirePlansSignature(canvas)
    local parts = {}
    for _, e in ipairs(canvas.elements) do
        parts[#parts + 1] = e.id .. ":" .. e.x .. "," .. e.y .. "," .. e.rotation
    end
    for _, c in ipairs(canvas.controls) do
        parts[#parts + 1] = c.id .. ":" .. c.x .. "," .. c.y
    end
    for _, w in ipairs(canvas.wires) do
        parts[#parts + 1] = w.id .. ":" .. w.fromElementId .. ">" .. w.toElementId .. ":" .. (w.directionOverride or "")
    end
    parts[#parts + 1] = canvas.zoom .. "," .. canvas.panX .. "," .. canvas.panY
        .. "," .. canvas.w .. "," .. canvas.h
    return table.concat(parts, "|")
end

-- Collapses a wire's user-set directionOverride (0/90/180/270, see
-- gdsGui_schematic_pressed/_moved's "wireDirection" dragKind) to the "h"/"v"
-- axis preference _clampedOrthogonalSegments understands — left/right and
-- up/down both mean the same thing to the h-first-vs-v-first choice, since
-- the actual exit side is already decided by which way the other anchor
-- lies. nil (never dragged) means no override: the automatic default.
local function _wireForceAxis(w)
    local d = w.directionOverride
    if d == 90 or d == 270 then return "v" end
    if d == 0 or d == 180 then return "h" end
    return nil
end

-- Offset at distance d along a segment of the given length, honoring the
-- same stub/offsetRanges rules _drawSegmentWithHopsAndOffset uses to draw it
-- — kept in sync with that function's offsetAt() so a wire hit-tests exactly
-- where it's actually drawn, lane offset included.
local function _offsetAtDistance(d, length, offsetRanges, stubPx, stubStart, stubEnd)
    if not offsetRanges or #offsetRanges == 0 then return 0 end
    if stubStart and d < stubPx then return 0 end
    if stubEnd and d > length - stubPx then return 0 end
    for _, r in ipairs(offsetRanges) do
        if d >= r.lo - 0.01 and d <= r.hi + 0.01 then return r.offset end
    end
    return 0
end

local function _computeWirePlans(canvas)
    local sig = _wirePlansSignature(canvas)
    if canvas._wirePlansCache and canvas._wirePlansSig == sig then
        return canvas._wirePlansCache
    end

    local plans = {}
    -- Segments grouped by the exact line they run along (key "H:<y>" or
    -- "V:<x>", nearest-pixel rounded), each entry recording the segment's
    -- own along-line absolute range — the input to the overlap sweep below.
    local lineGroups = {}
    for order, w in ipairs(canvas.wires) do
        local fromE, toE = _findAnchor(canvas, w.fromElementId), _findAnchor(canvas, w.toElementId)
        if fromE and toE then
            local x1, y1 = _anchorCenter(canvas, fromE)
            local x2, y2 = _anchorCenter(canvas, toE)
            local segments = _clampedOrthogonalSegments(canvas, fromE, x1, y1, toE, x2, y2, _wireForceAxis(w))
            plans[w.id] = { segments = segments, hopDistances = {}, offsetRanges = {} }
            for segIdx, seg in ipairs(segments) do
                local horiz = (seg[2] == seg[4])
                local loAbs, hiAbs
                if horiz then loAbs, hiAbs = math.min(seg[1], seg[3]), math.max(seg[1], seg[3])
                else          loAbs, hiAbs = math.min(seg[2], seg[4]), math.max(seg[2], seg[4]) end
                if hiAbs - loAbs > 0.01 then
                    local key = (horiz and "H:" or "V:") .. _roundPx(horiz and seg[2] or seg[1])
                    lineGroups[key] = lineGroups[key] or {}
                    table.insert(lineGroups[key], {
                        wireId = w.id, order = order, seg = seg, segIdx = segIdx, loAbs = loAbs, hiAbs = hiAbs,
                    })
                end
            end
        end
    end

    -- Sweep each line's entries: break it into sub-ranges at every entry's
    -- own start/end, then for each sub-range rank whichever entries actually
    -- cover it (by canvas.wires creation order, for a deterministic lane
    -- assignment every wire in the group agrees on) and evenly space them.
    for _, entries in pairs(lineGroups) do
        if #entries > 1 then
            local breakpoints = {}
            for _, e in ipairs(entries) do
                table.insert(breakpoints, e.loAbs)
                table.insert(breakpoints, e.hiAbs)
            end
            table.sort(breakpoints)
            local dedup = {}
            for _, b in ipairs(breakpoints) do
                if #dedup == 0 or (b - dedup[#dedup]) > 0.01 then table.insert(dedup, b) end
            end
            breakpoints = dedup

            for bi = 1, #breakpoints - 1 do
                local a, b = breakpoints[bi], breakpoints[bi + 1]
                local mid = (a + b) / 2
                local active = {}
                for _, e in ipairs(entries) do
                    if e.loAbs <= mid and e.hiAbs >= mid then table.insert(active, e) end
                end
                local n = #active
                if n > 1 then
                    table.sort(active, function(x, y) return x.order < y.order end)
                    for k, e in ipairs(active) do
                        local offset = (k - (n + 1) / 2) * _WIRE_PARALLEL_GAP_PX * canvas.zoom
                        local ax, ay = _pointOnLine(e.seg, a)
                        local bx, by = _pointOnLine(e.seg, b)
                        local dA, dB = _distAlongSegment(e.seg, ax, ay), _distAlongSegment(e.seg, bx, by)
                        local lo, hi = math.min(dA, dB), math.max(dA, dB)
                        local ranges = plans[e.wireId].offsetRanges
                        ranges[e.segIdx] = ranges[e.segIdx] or {}
                        table.insert(ranges[e.segIdx], { lo = lo, hi = hi, offset = offset })
                    end
                end
            end
        end
    end

    for i = 1, #canvas.wires do
        local pi = plans[canvas.wires[i].id]
        if pi then
            for j = i + 1, #canvas.wires do
                local wj = canvas.wires[j]
                local pj = plans[wj.id]
                if pj then
                    for si, segI in ipairs(pi.segments) do
                        for sj, segJ in ipairs(pj.segments) do
                            local hit, hx, hy = _segmentsCross(segI, segJ)
                            if hit then
                                local d = _distAlongSegment(segJ, hx, hy)
                                pj.hopDistances[sj] = pj.hopDistances[sj] or {}
                                table.insert(pj.hopDistances[sj], d)
                            end
                        end
                    end
                end
            end
        end
    end

    canvas._wirePlansSig   = sig
    canvas._wirePlansCache = plans
    return plans
end

-- Straight-line pieces approximating a wire's ACTUAL drawn path: each
-- segment's own per-lane perpendicular offset from a precomputed plan (see
-- _computeWirePlans) is applied, so two+ wires bundled along the same path
-- produce visually (and now hit-test-ably) distinct pieces instead of all
-- collapsing onto the same raw anchor-to-anchor bend. Falls back to the raw
-- bend when there's no plan (e.g. a dangling wire mid-undo). Ignores the
-- small crossing-hop arcs — a straight line through where the arc would be
-- is close enough for tap tolerance.
local function _wireOffsetPieces(canvas, w, plan)
    local fromA, toA = _findAnchor(canvas, w.fromElementId), _findAnchor(canvas, w.toElementId)
    if not (fromA and toA) then return {} end
    if not plan then
        local x1, y1 = _anchorCenter(canvas, fromA)
        local x2, y2 = _anchorCenter(canvas, toA)
        return { { x1, y1, x2, y2 } }
    end
    local pieces = {}
    local n = #plan.segments
    local stubPx = _WIRE_PARALLEL_STUB_PX * canvas.zoom
    for idx, seg in ipairs(plan.segments) do
        local x1, y1, x2, y2 = seg[1], seg[2], seg[3], seg[4]
        local horiz = (y1 == y2)
        local dirX, dirY
        if horiz then dirX, dirY = (x2 > x1) and 1 or -1, 0
        else          dirX, dirY = 0, (y2 > y1) and 1 or -1 end
        local length = horiz and math.abs(x2 - x1) or math.abs(y2 - y1)
        local perpX, perpY = _segmentPerp(y1, y2)
        local offsetRanges = plan.offsetRanges[idx] or {}
        local stubStart, stubEnd = (idx == 1), (idx == n)

        local cuts = { 0, length }
        for _, r in ipairs(offsetRanges) do
            if r.lo > 0 and r.lo < length then table.insert(cuts, r.lo) end
            if r.hi > 0 and r.hi < length then table.insert(cuts, r.hi) end
        end
        if stubStart and stubPx < length then table.insert(cuts, stubPx) end
        if stubEnd and length - stubPx > 0 then table.insert(cuts, length - stubPx) end
        table.sort(cuts)
        local dedup = {}
        for _, c in ipairs(cuts) do
            if #dedup == 0 or (c - dedup[#dedup]) > 0.01 then table.insert(dedup, c) end
        end
        cuts = dedup

        local function pointAt(d)
            local off = _offsetAtDistance(d, length, offsetRanges, stubPx, stubStart, stubEnd)
            return x1 + dirX * d + perpX * off, y1 + dirY * d + perpY * off
        end

        for i = 1, #cuts - 1 do
            local a, b = cuts[i], cuts[i + 1]
            local ax, ay = pointAt(a)
            local bx, by = pointAt(b)
            table.insert(pieces, { ax, ay, bx, by })
        end
    end
    return pieces
end

-- Topmost wire whose ACTUAL drawn path (lane offset included — see
-- _wireOffsetPieces) passes within _WIRE_TAP_SLOP_PX of the point.
-- Last-added wins, matching _hitElement. Using the raw anchor-to-anchor bend
-- here (as this used to) made every wire bundled along the same path
-- hit-test identically, so only the last-added one was ever selectable —
-- lane-offset-aware hit-testing is what makes the others tappable too.
local function _hitWire(canvas, px, py)
    local plans = _computeWirePlans(canvas)
    for i = #canvas.wires, 1, -1 do
        local w = canvas.wires[i]
        for _, piece in ipairs(_wireOffsetPieces(canvas, w, plans[w.id])) do
            local dist = _distPointToSegment(px, py, piece[1], piece[2], piece[3], piece[4])
            if dist <= _WIRE_TAP_SLOP_PX then return w end
        end
    end
    return nil
end

local function _drawWire(canvas, w, plan)
    if not plan then return end
    local wireWidth = _WIRE_WIDTH_PX * canvas.zoom
    if canvas.selectedWireId == w.id then
        -- Same yellow/magenta selection emphasis as an element's outline
        -- (see its comment on gdsGui_schematic_update's long-press timer),
        -- drawn as a wider line underneath so it reads as a highlight
        -- around the wire. Magenta once the hold has unlocked its
        -- direction-drag; yellow means a tap opens the menu, or hold to
        -- unlock that.
        if canvas.selectionMoveModeActive then
            love.graphics.setColor(1, 0, 1, 1)
        else
            love.graphics.setColor(1, 1, 0, 1)
        end
        love.graphics.setLineWidth(wireWidth + 6 * canvas.zoom)
        _drawWirePlanSegments(plan, canvas.zoom)
    end
    local r, g, b, a = gdsGui_schematic_resolveDisplayColor(canvas.name, "wire", w.id)
    love.graphics.setColor(r, g, b, a)
    love.graphics.setLineWidth(wireWidth)
    _drawWirePlanSegments(plan, canvas.zoom)
    love.graphics.setLineWidth(1)
end

local function _drawControl(canvas, c)
    local cx, cy = _toPixel(canvas, c.x, c.y)
    local rad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
    if canvas.selectedControlId == c.id then
        -- Same yellow/magenta selection emphasis as an element's outline —
        -- see its comment.
        if canvas.selectionMoveModeActive then
            love.graphics.setColor(1, 0, 1, 1)
        else
            love.graphics.setColor(1, 1, 0, 1)
        end
        love.graphics.circle("line", cx, cy, rad + 4)
    end
    local spritePath = c.spritePaths and c.spritePaths[c.detentIndex + 1]
    if spritePath then
        _drawElementSprite(spritePath, cx - rad, cy - rad, rad * 2, rad * 2, 1, 1, 1, 1, c.rotation)
    else
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.circle("line", cx, cy, rad)
        -- The detent-position angle and the control's own manual rotation
        -- (see gdsGui_schematic_addControl) both spin the same indicator
        -- line — combined, not one overriding the other, so rotating a
        -- control (e.g. to line up with the wires it connects to) doesn't
        -- lose which position it's showing.
        local angle = (c.detentIndex / c.numDetents) * math.pi * 2 + math.rad(c.rotation or 0)
        love.graphics.setLineWidth(3)
        love.graphics.line(cx, cy, cx + math.sin(angle) * rad, cy - math.cos(angle) * rad)
        love.graphics.setLineWidth(1)
    end
    local posName = (c.positions and c.positions[c.detentIndex + 1]) or tostring(c.detentIndex)
    local text = (c.label or "") .. "\n" .. posName
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(text, cx - rad * 2, cy + rad + 2, rad * 4, "center")
end

-- Draws one target reticle at an anchor's (element or control) center,
-- filled solid if it's the current snap target, a faint outline otherwise.
local function _drawOneConnectorTarget(canvas, anchor, snapTarget)
    if anchor.id == canvas.wireTool.fromId then return end
    local cx, cy = _anchorCenter(canvas, anchor)
    local rad = _CONNECTOR_TARGET_RADIUS_PX * canvas.zoom
    if snapTarget and snapTarget.id == anchor.id then
        love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 1)
        love.graphics.circle("fill", cx, cy, rad)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.circle("line", cx, cy, rad)
    else
        love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 0.55)
        love.graphics.circle("line", cx, cy, rad)
    end
end

-- Green "valid connection point" reticles at every other anchor's (element
-- or control) center, shown only while a wire is actively being dragged
-- (gone the instant it isn't). The one currently in snap range is filled
-- solid to show the clamp that's about to happen if released now; the rest
-- are faint outlines.
local function _drawConnectorTargets(canvas, snapTarget)
    for _, e in ipairs(canvas.elements) do _drawOneConnectorTarget(canvas, e, snapTarget) end
    for _, c in ipairs(canvas.controls) do _drawOneConnectorTarget(canvas, c, snapTarget) end
end

function gdsGui_schematic_draw(pageName)
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName then
            love.graphics.setScissor(canvas.x, canvas.y, canvas.w, canvas.h)

            love.graphics.setColor(0.10, 0.10, 0.12, 1)
            love.graphics.rectangle("fill", canvas.x, canvas.y, canvas.w, canvas.h)
            if canvas.mode == "design" then _drawGrid(canvas) end

            local wirePlans = _computeWirePlans(canvas)
            for _, w in ipairs(canvas.wires) do _drawWire(canvas, w, wirePlans[w.id]) end
            for _, e in ipairs(canvas.elements) do _drawElement(canvas, e) end
            for _, c in ipairs(canvas.controls) do _drawControl(canvas, c) end

            if canvas.wireTool.fromId then
                local fromE = _findAnchor(canvas, canvas.wireTool.fromId)
                if fromE and canvas.wireTool.curX then
                    local snapTarget = _connectorSnapTarget(canvas)
                    _drawConnectorTargets(canvas, snapTarget)
                    local fx, fy = _anchorCenter(canvas, fromE)
                    -- Clamped to the snap target's center (if any) rather than
                    -- the raw cursor/finger position, so the line visibly locks
                    -- on once in range instead of just trailing the touch point.
                    local tx, ty = canvas.wireTool.curX, canvas.wireTool.curY
                    if snapTarget then
                        tx, ty = _anchorCenter(canvas, snapTarget)
                    end
                    love.graphics.setColor(1, 1, 1, 0.6)
                    love.graphics.setLineWidth(2 * canvas.zoom)
                    -- fromE's end always clamps to its own edge; the loose
                    -- cursor/finger end only clamps once it's snapped onto a
                    -- real target (snapTarget), same as the finished wire.
                    _drawClampedOrthogonalLine(canvas, fromE, fx, fy, snapTarget, tx, ty)
                    love.graphics.setLineWidth(1)
                end
            end

            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.setScissor()
        end
    end
end

-- Drawn separately so the app layer can call it LAST in love.draw(), after
-- the floating chrome buttons — guaranteeing the modal menu renders on top.
function gdsGui_schematic_drawMenuOverlay(pageName)
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName and canvas.menu then
            _drawMenuBox(canvas, canvas.menu)
        end
    end
end

--------------------------------------------------------------------------------
-- PAN / PINCH-ZOOM (two-finger gesture, independent of the single-touch
-- element/control drag and canvas-pan machinery in the INPUT section below)
--------------------------------------------------------------------------------

local function _touchCount(touches)
    local n = 0
    for _ in pairs(touches) do n = n + 1 end
    return n
end

-- Any two of the currently tracked touches, in no particular stable order
-- (fine: a pinch only cares about the pair's distance/midpoint each frame).
local function _firstTwoTouches(touches)
    local a, b = nil, nil
    for _, pt in pairs(touches) do
        if not a then a = pt elseif not b then b = pt else break end
    end
    return a, b
end

local function _startPinch(canvas)
    local p1, p2 = _firstTwoTouches(canvas.touches)
    if not (p1 and p2) then return end
    local dx, dy = p2.x - p1.x, p2.y - p1.y
    local dist = math.max(_PINCH_MIN_DIST_PX, math.sqrt(dx * dx + dy * dy))
    local midX, midY = (p1.x + p2.x) / 2, (p1.y + p2.y) / 2
    -- The content point currently under the gesture's midpoint; held fixed
    -- on screen (standard "zoom around the pinch center") for the rest of
    -- it. Stored as a true 0-1 content fraction (dividing out contentW/H),
    -- not a raw pixel offset, so it stays correct even as the viewport's
    -- own box smoothly grows mid-gesture (see _calculateGeometry).
    local anchorFracX = ((midX - canvas.x - canvas.panX) / canvas.zoom) / canvas.contentW
    local anchorFracY = ((midY - canvas.y - canvas.panY) / canvas.zoom) / canvas.contentH
    canvas.pinch = {
        active = true, startDist = dist, startZoom = canvas.zoom,
        anchorFracX = anchorFracX, anchorFracY = anchorFracY,
    }
end

local function _updatePinch(canvas)
    if not (canvas.pinch and canvas.pinch.active) then return end
    local p1, p2 = _firstTwoTouches(canvas.touches)
    if not (p1 and p2) then return end
    local dx, dy = p2.x - p1.x, p2.y - p1.y
    local dist = math.max(_PINCH_MIN_DIST_PX, math.sqrt(dx * dx + dy * dy))
    local midX, midY = (p1.x + p2.x) / 2, (p1.y + p2.y) / 2
    local newZoom = canvas.pinch.startZoom * (dist / canvas.pinch.startDist)
    newZoom = math.max(_MIN_ZOOM, math.min(_MAX_ZOOM, newZoom))
    canvas.zoom = newZoom
    -- The viewport box smoothly tracks zoom too (see _calculateGeometry) —
    -- recompute before placing pan against the resulting x/y.
    _calculateGeometry(canvas)
    canvas.panX = midX - canvas.x - canvas.pinch.anchorFracX * canvas.contentW * newZoom
    canvas.panY = midY - canvas.y - canvas.pinch.anchorFracY * canvas.contentH * newZoom
    _clampPan(canvas)
end

-- Desktop/trackpad equivalent of a pinch: no touchscreen means no second
-- finger to pinch with, so mouse-wheel scroll (dy > 0 = scroll up/away =
-- zoom in, matching Figma/Maps/etc.) is the only way to zoom without one.
-- Same "hold the point under the cursor fixed" anchoring as _updatePinch,
-- just computed in one step instead of across a continuous gesture.
local _WHEEL_ZOOM_SENSITIVITY = 0.12  -- zoom multiplier per unit of wheel delta

function gdsGui_schematic_wheelZoom(x, y, dy)
    if dy == 0 then return end
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == activePageName and not canvas.menu
           and x >= canvas.x and x <= canvas.x + canvas.w
           and y >= canvas.y and y <= canvas.y + canvas.h then
            -- True 0-1 content fractions (not raw pixel offsets) so they
            -- stay correct even as the viewport box smoothly grows with
            -- zoom (see _calculateGeometry).
            local anchorFracX = ((x - canvas.x - canvas.panX) / canvas.zoom) / canvas.contentW
            local anchorFracY = ((y - canvas.y - canvas.panY) / canvas.zoom) / canvas.contentH
            local newZoom = canvas.zoom * ((1 + _WHEEL_ZOOM_SENSITIVITY) ^ dy)
            newZoom = math.max(_MIN_ZOOM, math.min(_MAX_ZOOM, newZoom))
            canvas.zoom = newZoom
            _calculateGeometry(canvas)
            canvas.panX = x - canvas.x - anchorFracX * canvas.contentW * newZoom
            canvas.panY = y - canvas.y - anchorFracY * canvas.contentH * newZoom
            _clampPan(canvas)
            return
        end
    end
end

local function _endPinchIfBelowTwo(canvas)
    if canvas.pinch and canvas.pinch.active and _touchCount(canvas.touches) < 2 then
        canvas.pinch.active = false
    end
end

--------------------------------------------------------------------------------
-- INPUT (generalizes the exclusive focusTouchId ownership pattern used by
-- scrollBar_gdsGuiLib.lua / rotaryKnobs_gdsGuiLib.lua to free, unclamped 2D drag)
--------------------------------------------------------------------------------

function gdsGui_schematic_pressed(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page ~= activePageName then goto continue end

        -- A modal menu always takes priority and consumes the tap. Only
        -- records what it landed on — gdsGui_schematic_released below is
        -- what actually fires onSelect/onCancel.
        if canvas.menu then
            _handleMenuPress(canvas, touchId, x, y)
            goto continue
        end

        if x < canvas.x or x > canvas.x + canvas.w or y < canvas.y or y > canvas.y + canvas.h then goto continue end

        -- Track every finger down inside this canvas regardless of what the
        -- first one is already doing, so a second one lands as a pinch.
        canvas.touches[touchId] = { x = x, y = y }
        if _touchCount(canvas.touches) >= 2 then
            canvas.focusTouchId    = nil
            canvas.dragKind        = nil
            canvas.wireTool.fromId = nil
            _startPinch(canvas)
            goto continue
        end

        if canvas.focusTouchId ~= nil then goto continue end

        if canvas.mode == "control" then
            -- Pure "operate" mode: the only thing a tap can do is cycle a
            -- control. Color assignment and snapshot capture are design-mode
            -- (ACTIONS menu) actions now — anything else here just pans.
            local control = _hitControl(canvas, x, y)
            if control then
                control.detentIndex = (control.detentIndex + 1) % control.numDetents
                _fireControlCallback(control)
                goto continue
            end
            canvas.focusTouchId = touchId
            canvas.dragKind     = "pan"
            canvas.dragStartX   = x
            canvas.dragStartY   = y
            canvas.panStartX    = canvas.panX
            canvas.panStartY    = canvas.panY
            goto continue
        end

        -- design mode
        if canvas.pendingPlacement then
            local fracX, fracY = _toFraction(canvas, x, y)
            if canvas.pendingPlacement.kind == "element" then
                fracX, fracY = _snapElementToGrid(canvas, fracX, fracY,
                    _ELEMENT_DEFAULT_W_FRAC, _ELEMENT_DEFAULT_H_FRAC)
            else
                fracX, fracY = _snapToGrid(canvas, fracX, fracY)
            end
            canvas._placementCounter = canvas._placementCounter + 1
            local newId = canvas.pendingPlacement.idPrefix .. "_" .. canvas._placementCounter
            _pendingNamedPlacement = {
                canvasName = canvas.name, newId = newId, fracX = fracX, fracY = fracY,
                kind = canvas.pendingPlacement.kind, shapeType = canvas.pendingPlacement.shapeType,
                positions = canvas.pendingPlacement.positions, defaultColor = canvas.pendingPlacement.defaultColor,
                callbackFunc = canvas.pendingPlacement.callbackFunc,
                defaultPropertyKeys = canvas.pendingPlacement.defaultPropertyKeys,
                spritePath = canvas.pendingPlacement.spritePath,
                spritePaths = canvas.pendingPlacement.spritePaths,
            }
            _openPlacementNamePrompt("NAME THIS " .. canvas.pendingPlacement.kind:upper(),
                _suggestedPlacementName(canvas, canvas.pendingPlacement.label))
            canvas.pendingPlacement = nil
            goto continue
        end

        if canvas.pendingColorAssignPick then
            -- One-shot pick armed via gdsGui_schematic_armColorAssignPick:
            -- whatever this tap lands on (element, then wire) gets its
            -- swatch color picker opened directly; empty space just disarms.
            canvas.pendingColorAssignPick = false
            local pickedElem = _hitElement(canvas, x, y)
            if pickedElem then
                gdsGui_schematic_openColorPicker(canvas.name, "element", pickedElem.id,
                    "COLOR: " .. (pickedElem.label or pickedElem.id))
            else
                local pickedWire = _hitWire(canvas, x, y)
                if pickedWire then
                    gdsGui_schematic_openColorPicker(canvas.name, "wire", pickedWire.id,
                        "COLOR: WIRE: " .. pickedWire.id)
                end
            end
            goto continue
        end

        if canvas.pendingWireFromId then
            -- Armed via ADD WIRE in the element edit menu (see
            -- gdsGui_schematic_internal_onElementEditChosen): the source
            -- anchor is already decided, so unlike the WIRE TOOL/catalog
            -- connector flows below, this very next press doesn't need to
            -- land on an anchor at all — it just starts the loose, dragged
            -- end from wherever it lands. Disarms either way; if the source
            -- element was somehow removed since arming (its own edit menu
            -- was still open, so only a bulk load/undo could do this),
            -- there's nothing to connect from, so just drop it.
            local fromId = canvas.pendingWireFromId
            canvas.pendingWireFromId = nil
            if _findAnchor(canvas, fromId) then
                canvas.focusTouchId    = touchId
                canvas.wireTool.fromId = fromId
                canvas.wireTool.curX   = x
                canvas.wireTool.curY   = y
            end
            goto continue
        end

        local hitElem = _hitElement(canvas, x, y)
        if canvas.wireToolActive or canvas.pendingConnectorColor then
            -- A connector can start from either an element (box) or a
            -- control (rotary switch) — both are valid wire endpoints.
            local anchor = hitElem or _hitControl(canvas, x, y)
            if anchor then
                canvas.focusTouchId    = touchId
                canvas.wireTool.fromId = anchor.id
                canvas.wireTool.curX   = x
                canvas.wireTool.curY   = y
                if canvas.pendingConnectorColor then
                    canvas.wireTool.color = canvas.pendingConnectorColor
                end
            end
        elseif hitElem then
            -- Two-tier gesture: a plain tap always opens the edit menu
            -- (see gdsGui_schematic_released); only once a hold on the
            -- CURRENT selection has already crossed _LONG_PRESS_SECONDS
            -- (gdsGui_schematic_update) does a press immediately start
            -- dragging/rotating it, same as before. selectionMoveModeActive
            -- persists across separate press/release cycles on the same
            -- target, so the user can lift and re-grab without holding
            -- again — it's cleared below the moment selection moves to
            -- something else ("tapping anywhere else deactivates" it).
            local isActiveMoveTarget = canvas.selectionMoveModeActive and canvas.selectedElementId == hitElem.id
            canvas.focusTouchId       = touchId
            canvas.selectedElementId  = hitElem.id
            canvas.selectedControlId  = nil
            canvas.selectedWireId     = nil
            canvas.dragStartX         = x
            canvas.dragStartY         = y
            canvas.dragMoved          = false
            if not isActiveMoveTarget then canvas.selectionMoveModeActive = false end
            if isActiveMoveTarget then
                canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                if _ROTATABLE_SHAPES[hitElem.shapeType] then
                    canvas.dragKind = "rotate"
                    local cx, cy = _elementCenter(canvas, hitElem)
                    canvas.rotateGrabAngleOffset = math.atan2(y - cy, x - cx) - math.rad(hitElem.rotation or 0)
                else
                    canvas.dragKind    = "element"
                    local ex, ey = _toPixel(canvas, hitElem.x, hitElem.y)
                    canvas.dragOffsetX = x - ex
                    canvas.dragOffsetY = y - ey
                end
            else
                canvas.dragKind            = "pendingLongPress"
                canvas.longPressTargetKind = "element"
                canvas.longPressElapsed    = 0
            end
        else
            local hitCtrl = _hitControl(canvas, x, y)
            if hitCtrl then
                -- Same two-tier gesture as an element above.
                local isActiveMoveTarget = canvas.selectionMoveModeActive and canvas.selectedControlId == hitCtrl.id
                canvas.focusTouchId      = touchId
                canvas.selectedControlId = hitCtrl.id
                canvas.selectedElementId = nil
                canvas.selectedWireId    = nil
                canvas.dragStartX        = x
                canvas.dragStartY        = y
                canvas.dragMoved         = false
                if not isActiveMoveTarget then canvas.selectionMoveModeActive = false end
                if isActiveMoveTarget then
                    -- Every control is rotatable (unlike elements, where
                    -- only specific shapeTypes are — see _ROTATABLE_SHAPES
                    -- above) — pressing an already-active control rotates
                    -- it instead of moving it, same first-drag-moves/
                    -- every-later-drag-rotates pattern as a rotatable
                    -- element (see gdsGui_schematic_update's promotion,
                    -- which is what unlocks the FIRST, move, drag).
                    canvas.dragKind = "controlRotate"
                    canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                    local cx, cy = _toPixel(canvas, hitCtrl.x, hitCtrl.y)
                    canvas.rotateGrabAngleOffset = math.atan2(y - cy, x - cx) - math.rad(hitCtrl.rotation or 0)
                else
                    canvas.dragKind            = "pendingLongPress"
                    canvas.longPressTargetKind = "control"
                    canvas.longPressElapsed    = 0
                end
            else
                local hitWire = _hitWire(canvas, x, y)
                if hitWire then
                    -- Same two-tier gesture as an element/control above: a
                    -- plain tap always (re)selects and opens the edit menu
                    -- on release; only once a hold on the CURRENT selection
                    -- has already crossed _LONG_PRESS_SECONDS
                    -- (gdsGui_schematic_update) does a press immediately
                    -- start setting its forced bend direction, pivoting
                    -- around the wire's own midpoint instead of an element
                    -- center. A wire has no position of its own to move, so
                    -- unlocking goes straight to "direction" rather than
                    -- "move then rotate."
                    local isActiveMoveTarget = canvas.selectionMoveModeActive and canvas.selectedWireId == hitWire.id
                    canvas.focusTouchId      = touchId
                    canvas.selectedWireId    = hitWire.id
                    canvas.selectedElementId = nil
                    canvas.selectedControlId = nil
                    canvas.dragStartX        = x
                    canvas.dragStartY        = y
                    canvas.dragMoved         = false
                    if not isActiveMoveTarget then canvas.selectionMoveModeActive = false end
                    if isActiveMoveTarget then
                        local pivotX, pivotY = _wireMidpoint(canvas, hitWire)
                        if pivotX then
                            canvas.dragKind = "wireDirection"
                            canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                            canvas.rotateGrabAngleOffset =
                                math.atan2(y - pivotY, x - pivotX) - math.rad(hitWire.directionOverride or 0)
                        else
                            canvas.dragKind = "wire"
                        end
                    else
                        canvas.dragKind            = "pendingLongPress"
                        canvas.longPressTargetKind = "wire"
                        canvas.longPressElapsed    = 0
                    end
                else
                    canvas.selectedElementId = nil
                    canvas.selectedControlId = nil
                    canvas.selectedWireId    = nil
                    canvas.selectionMoveModeActive = false
                    -- Empty space: a one-finger drag pans the (possibly zoomed) view.
                    canvas.focusTouchId = touchId
                    canvas.dragKind     = "pan"
                    canvas.dragStartX   = x
                    canvas.dragStartY   = y
                    canvas.panStartX    = canvas.panX
                    canvas.panStartY    = canvas.panY
                end
            end
        end

        ::continue::
    end
end

function gdsGui_schematic_moved(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        -- Without this, a finger still down when the user navigates away
        -- (e.g. via a footer nav button while mid-drag) keeps applying
        -- pan/drag/pinch math to a canvas the user can no longer see,
        -- silently moving its contents until the finger finally lifts.
        -- gdsGui_schematic_pressed/_draw already gate on this; this and
        -- _released below didn't.
        if canvas.page ~= activePageName then goto continue end
        if canvas.menu then goto continue end

        if canvas.touches[touchId] then
            canvas.touches[touchId].x = x
            canvas.touches[touchId].y = y
        end

        if canvas.pinch and canvas.pinch.active then
            _updatePinch(canvas)
            goto continue
        end

        if canvas.focusTouchId ~= touchId then goto continue end

        if canvas.wireTool.fromId then
            canvas.wireTool.curX = x
            canvas.wireTool.curY = y
        elseif canvas.dragKind == "pendingLongPress" then
            -- Moved too far before the hold reached _LONG_PRESS_SECONDS —
            -- cancel it outright (gdsGui_schematic_update below won't
            -- promote it once canvas.dragMoved is true) so it reads as
            -- neither a clean tap (which would open the menu on release)
            -- nor a completed hold, same as a long-press being cancelled
            -- by movement on a real touch device.
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
            end
        elseif canvas.dragKind == "element" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem then
                local fracX, fracY = _toFraction(canvas, x - canvas.dragOffsetX, y - canvas.dragOffsetY)
                elem.x, elem.y = _snapElementToGrid(canvas, fracX, fracY, elem.w, elem.h)
            end
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "rotate" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem then
                local cx, cy = _elementCenter(canvas, elem)
                local rawAngle = math.atan2(y - cy, x - cx) - canvas.rotateGrabAngleOffset
                elem.rotation = _snapRotationDegrees(rawAngle)
            end
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "wireDirection" and canvas.selectedWireId then
            local wire = _findWire(canvas, canvas.selectedWireId)
            if wire then
                local pivotX, pivotY = _wireMidpoint(canvas, wire)
                if pivotX then
                    local rawAngle = math.atan2(y - pivotY, x - pivotX) - canvas.rotateGrabAngleOffset
                    wire.directionOverride = _snapRotationDegrees(rawAngle)
                end
            end
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "control" and canvas.selectedControlId then
            local ctrl = _findControl(canvas, canvas.selectedControlId)
            if ctrl then
                local fracX, fracY = _toFraction(canvas, x - canvas.dragOffsetX, y - canvas.dragOffsetY)
                ctrl.x, ctrl.y = _snapToGrid(canvas, fracX, fracY)
            end
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "controlRotate" and canvas.selectedControlId then
            local ctrl = _findControl(canvas, canvas.selectedControlId)
            if ctrl then
                local cx, cy = _toPixel(canvas, ctrl.x, ctrl.y)
                local rawAngle = math.atan2(y - cy, x - cx) - canvas.rotateGrabAngleOffset
                ctrl.rotation = _snapRotationDegrees(rawAngle)
            end
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "wire" and canvas.selectedWireId then
            -- A wire has no position to drag — just the same tap-vs-drag
            -- slop tracking as element/control, so a real finger-drag past
            -- the wire doesn't also pop its edit menu open on release.
            if math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
               math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX then
                canvas.dragMoved = true
            end
        elseif canvas.dragKind == "pan" then
            canvas.panX = canvas.panStartX + (x - canvas.dragStartX)
            canvas.panY = canvas.panStartY + (y - canvas.dragStartY)
            _clampPan(canvas)
        end

        ::continue::
    end
end

function gdsGui_schematic_released(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page ~= activePageName then goto continue end
        canvas.touches[touchId] = nil
        _endPinchIfBelowTwo(canvas)

        if canvas.menu then
            -- A menu opened by something OTHER than this touch (e.g. the
            -- separate ACTIONS button, while this touch was already
            -- mid-drag) never gets a chance to run the focusTouchId/
            -- dragKind cleanup below — left stuck, canvas.focusTouchId
            -- would keep pointing at a touch that no longer exists, and
            -- gdsGui_schematic_pressed's "ignore input while a touch is
            -- already focused" guard would then block every further
            -- single-touch tap on this canvas. Clear it here regardless of
            -- the menu; the gesture itself is simply abandoned (whatever
            -- it had already committed via _notifyChanged during moved()
            -- stays as-is).
            if canvas.focusTouchId == touchId then
                canvas.focusTouchId = nil
                canvas.dragKind = nil
                canvas.wireTool.fromId = nil
                canvas._pendingDragUndoSnapshot = nil
            end
            _handleMenuRelease(canvas, touchId, x, y)
            goto continue
        end
        if canvas.focusTouchId == touchId then
            if canvas.wireTool.fromId then
                local toElem = _connectorSnapTarget(canvas)
                if toElem then
                    local baseId = canvas.wireTool.fromId .. "_to_" .. toElem.id
                    -- wireTool.color: an explicit per-gesture override (set
                    -- only by a still-armed gdsGui_schematic_armConnectorPlacement
                    -- color, nil for ADD WIRE). defaultConnectorColor: the
                    -- per-canvas fallback ADD WIRE actually relies on — see
                    -- gdsGui_schematic_setDefaultConnectorColor.
                    gdsGui_schematic_addWire(canvas.name, _uniqueWireId(canvas, baseId),
                        canvas.wireTool.fromId, toElem.id,
                        canvas.wireTool.color or canvas.defaultConnectorColor or _DEFAULT_COLOR)
                    _notifyChanged(canvas)
                end
                -- A catalog-armed connector is one-shot: disarm it once this
                -- gesture resolves, whether or not it actually hit a second
                -- element, matching every other catalog placement's single-
                -- tap-commits semantics. The dock's WIRE TOOL toggle (if that's
                -- what started this instead) is untouched and stays armed.
                if canvas.pendingConnectorColor then
                    canvas.pendingConnectorColor = nil
                    canvas.wireTool.color = nil
                end
            elseif canvas.mode == "design" and canvas.dragKind == "pendingLongPress" and not canvas.dragMoved then
                -- Released before the hold reached _LONG_PRESS_SECONDS
                -- (gdsGui_schematic_update), and never wandered past tap
                -- slop either (gdsGui_schematic_moved would have set
                -- dragMoved) — a clean, single tap, so it opens the
                -- element/control's menu the same as any other tap, move/
                -- rotate mode having never unlocked.
                if canvas.longPressTargetKind == "element" and canvas.selectedElementId then
                    gdsGui_schematic_openElementEditMenu(canvas.name, canvas.selectedElementId)
                elseif canvas.longPressTargetKind == "control" and canvas.selectedControlId then
                    gdsGui_schematic_openControlEditMenu(canvas.name, canvas.selectedControlId)
                elseif canvas.longPressTargetKind == "wire" and canvas.selectedWireId then
                    gdsGui_schematic_openWireEditMenu(canvas.name, canvas.selectedWireId)
                end
            elseif canvas.mode == "design" and canvas.dragKind == "element" and
                   canvas.selectedElementId and not canvas.dragMoved then
                -- A plain tap (no drag) on an element in design mode: open the
                -- color+delete menu instead of just leaving it selected.
                gdsGui_schematic_openElementEditMenu(canvas.name, canvas.selectedElementId)
            elseif canvas.mode == "design" and canvas.dragKind == "rotate" and
                   canvas.selectedElementId and not canvas.dragMoved then
                -- Same tap-to-edit gesture as a plain element drag: a tap
                -- with no actual rotation opens the edit menu instead.
                gdsGui_schematic_openElementEditMenu(canvas.name, canvas.selectedElementId)
            elseif canvas.mode == "design" and canvas.dragKind == "wire" and
                   canvas.selectedWireId and not canvas.dragMoved then
                -- Same tap-to-edit gesture as an element, applied to a wire.
                gdsGui_schematic_openWireEditMenu(canvas.name, canvas.selectedWireId)
            elseif canvas.mode == "design" and canvas.dragKind == "wireDirection" and
                   canvas.selectedWireId and not canvas.dragMoved then
                -- Same tap-to-edit gesture as a plain wire drag: a tap with
                -- no actual direction change opens the edit menu instead.
                gdsGui_schematic_openWireEditMenu(canvas.name, canvas.selectedWireId)
            elseif canvas.mode == "design" and canvas.dragKind == "control" and
                   canvas.selectedControlId and not canvas.dragMoved then
                -- Same tap-to-edit gesture, applied to a control: lets design
                -- mode change its position/delete it, not just reposition it.
                gdsGui_schematic_openControlEditMenu(canvas.name, canvas.selectedControlId)
            elseif canvas.mode == "design" and canvas.dragKind == "controlRotate" and
                   canvas.selectedControlId and not canvas.dragMoved then
                -- Same tap-to-edit gesture as a plain control drag: a tap
                -- with no actual rotation opens the edit menu instead.
                gdsGui_schematic_openControlEditMenu(canvas.name, canvas.selectedControlId)
            end
            -- An actual drag (element/rotate/control/controlRotate moved,
            -- not just tapped) settled at its final position/angle here —
            -- persist it now rather than waiting for the next page-nav
            -- save point.
            if canvas.mode == "design" and canvas.dragMoved and
               (canvas.dragKind == "element" or canvas.dragKind == "rotate" or
                canvas.dragKind == "control" or canvas.dragKind == "wireDirection" or
                canvas.dragKind == "controlRotate") then
                _notifyChanged(canvas)
            end
            canvas.focusTouchId    = nil
            canvas.dragKind        = nil
            canvas.wireTool.fromId = nil
            -- A plain tap never crossed the slop threshold, so this was
            -- never committed to the undo stack (see gdsGui_schematic_moved)
            -- — nothing left to discard but the pending capture itself.
            canvas._pendingDragUndoSnapshot = nil
        end
        ::continue::
    end
end

-- A stationary held touch generates no touchmoved/mousemoved events at
-- all, so the "has this press been held _LONG_PRESS_SECONDS without
-- moving" check for gdsGui_schematic_pressed's "pendingLongPress" dragKind
-- has to live here, polled every frame, rather than in
-- gdsGui_schematic_moved.
function gdsGui_schematic_update(dt)
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page ~= activePageName then goto continue end
        if canvas.dragKind ~= "pendingLongPress" then goto continue end
        -- The touch already lifted (gdsGui_schematic_released clears
        -- dragKind on release, so this is only a same-frame-ordering
        -- safety net) or wandered past tap slop (gdsGui_schematic_moved
        -- already marked it as such) — neither should unlock move/rotate
        -- mode.
        if not canvas.focusTouchId or canvas.dragMoved then goto continue end

        canvas.longPressElapsed = (canvas.longPressElapsed or 0) + dt
        if canvas.longPressElapsed < _LONG_PRESS_SECONDS then goto continue end

        -- Held long enough — unlock move/rotate mode for whatever's
        -- currently selected, and seamlessly promote this SAME still-held
        -- touch straight into dragging/rotating it (reusing the exact
        -- grab-offset/angle setup gdsGui_schematic_pressed uses for an
        -- already-unlocked target), so the user doesn't have to lift and
        -- press again.
        canvas.selectionMoveModeActive = true
        gdsGui_haptics_vibrate()
        local touch = canvas.touches[canvas.focusTouchId]
        local x = touch and touch.x or canvas.dragStartX
        local y = touch and touch.y or canvas.dragStartY

        -- Always "move" on THIS first unlock, even for a rotatable
        -- element/any control — matches gdsGui_schematic_pressed's
        -- isActiveMoveTarget branch below, which is what picks "rotate"
        -- instead, but only once already active and pressed again (same
        -- first-drag-moves/every-later-drag-rotates pattern the original
        -- "wasSelected" gesture used before the long-press hold existed).
        if canvas.longPressTargetKind == "element" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem then
                canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                canvas.dragKind    = "element"
                local ex, ey = _toPixel(canvas, elem.x, elem.y)
                canvas.dragOffsetX = x - ex
                canvas.dragOffsetY = y - ey
            end
        elseif canvas.longPressTargetKind == "control" and canvas.selectedControlId then
            local ctrl = _findControl(canvas, canvas.selectedControlId)
            if ctrl then
                canvas.dragKind = "control"
                canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                local cx, cy = _toPixel(canvas, ctrl.x, ctrl.y)
                canvas.dragOffsetX = x - cx
                canvas.dragOffsetY = y - cy
            end
        elseif canvas.longPressTargetKind == "wire" and canvas.selectedWireId then
            -- A wire has no position to move, so unlocking goes straight to
            -- its "direction" drag instead of a move-first step.
            local wire = _findWire(canvas, canvas.selectedWireId)
            if wire then
                local pivotX, pivotY = _wireMidpoint(canvas, wire)
                if pivotX then
                    canvas.dragKind = "wireDirection"
                    canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                    canvas.rotateGrabAngleOffset =
                        math.atan2(y - pivotY, x - pivotX) - math.rad(wire.directionOverride or 0)
                end
            end
        end

        ::continue::
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — PROJECT GALLERY
-- A scrollable grid of mini schematic previews. Used by the app layer's
-- project-management screens ("load a project" / "manage my projects"), so
-- the user can pick a saved design visually instead of from a text list. Each
-- item is just {id, name, elements, wires} — callers can hand this the actual
-- project records directly (no separate "thumbnail" asset is ever generated;
-- the preview is redrawn live from the real element/wire data every frame).
-- Not container-managed, same standalone integration tier as the canvas above.
--------------------------------------------------------------------------------

globApp.objects.schematicGalleries = {}

local _GALLERY_GAP_PX      = 12
local _GALLERY_TILE_H_PX   = 110
local _GALLERY_LABEL_H_PX  = 20
local _GALLERY_TAP_SLOP_PX = 6

local function _findGallery(galleryName)
    for _, g in ipairs(globApp.objects.schematicGalleries) do
        if g.name == galleryName then return g end
    end
    return nil
end

local function _calculateGalleryGeometry(gallery)
    local o = gallery.original
    gallery.w = o.wFrac * globApp.safeScreenArea.w
    gallery.h = o.hFrac * globApp.safeScreenArea.h
    local pos = gdsGui_general_relativePosition(
        o.anchorPoint, o.x, o.y, gallery.w, gallery.h,
        globApp.safeScreenArea.x, globApp.safeScreenArea.y,
        globApp.safeScreenArea.w, globApp.safeScreenArea.h
    )
    gallery.x = pos[1]
    gallery.y = pos[2]
    gallery.tileW = (gallery.w - _GALLERY_GAP_PX * (gallery.columns + 1)) / gallery.columns
end

-- emptyText (optional): message shown when the gallery has no items, e.g.
-- "NO AIRCRAFT YET" vs. "NO SYSTEMS YET" for two galleries sharing this same
-- generic widget. Defaults to the original copy for callers that don't pass it.
-- tileH (optional): per-instance tile row height, overriding the shared
-- default — e.g. the snapshots gallery needs taller rows to fit a
-- thumbnail-plus-status-text layout (see item.statusLines below) instead of
-- just a diagram tile.
function gdsGui_schematicGallery_create(name, page, x, y, anchorPoint, wFrac, hFrac, columns, emptyText, tileH)
    local gallery = {}
    gallery.name        = name
    gallery.page        = page
    gallery.objectType  = "schematicGallery"
    gallery.items       = {}   -- {id, name, elements, wires, ...}
    gallery.columns      = columns or 2
    gallery.emptyText    = emptyText or "NO SAVED PROJECTS YET"
    gallery.tileH        = tileH or _GALLERY_TILE_H_PX
    gallery.scrollY       = 0
    gallery.focusTouchId  = nil
    gallery.pressStartX   = 0
    gallery.pressStartY   = 0
    gallery.pressStartScrollY = 0
    gallery.moved         = false
    gallery.menu          = nil   -- generic modal list, same shape as the canvas's
    gallery.onSelect      = nil   -- global function name: called (galleryName, itemId) on tap

    gallery.original = { x = x, y = y, anchorPoint = anchorPoint, wFrac = wFrac, hFrac = hFrac }
    _calculateGalleryGeometry(gallery)

    function gallery:resize() _calculateGalleryGeometry(self) end

    table.insert(globApp.objects.schematicGalleries, gallery)
    globApp.numObjectsDisplayed = globApp.numObjectsDisplayed + 1
end

function gdsGui_schematicGallery_setItems(galleryName, items)
    local gallery = _findGallery(galleryName)
    if not gallery then return end
    gallery.items = items or {}
    gallery.scrollY = 0
end

function gdsGui_schematicGallery_setOnSelect(galleryName, callbackFuncName)
    local gallery = _findGallery(galleryName)
    if gallery then gallery.onSelect = callbackFuncName end
end

function gdsGui_schematicGallery_openMenu(galleryName, title, options, onSelectFunc, onCancelFunc)
    local gallery = _findGallery(galleryName)
    if not gallery then return end
    gallery.menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc }
end

function gdsGui_schematicGallery_closeMenu(galleryName)
    local gallery = _findGallery(galleryName)
    if gallery then gallery.menu = nil end
end

local function _galleryContentHeight(gallery)
    local rows = math.ceil(#gallery.items / gallery.columns)
    return _GALLERY_GAP_PX + rows * (gallery.tileH + _GALLERY_LABEL_H_PX + _GALLERY_GAP_PX)
end

local function _galleryMaxScroll(gallery)
    return math.max(0, _galleryContentHeight(gallery) - gallery.h)
end

local function _galleryTileRect(gallery, index)
    local col = (index - 1) % gallery.columns
    local row = math.floor((index - 1) / gallery.columns)
    local tx = gallery.x + _GALLERY_GAP_PX + col * (gallery.tileW + _GALLERY_GAP_PX)
    local ty = gallery.y + _GALLERY_GAP_PX
        + row * (gallery.tileH + _GALLERY_LABEL_H_PX + _GALLERY_GAP_PX) - gallery.scrollY
    return tx, ty, gallery.tileW, gallery.tileH
end

local function _galleryTileAt(gallery, px, py)
    for i = 1, #gallery.items do
        local tx, ty, tw, th = _galleryTileRect(gallery, i)
        if px >= tx and px <= tx + tw and py >= ty and py <= ty + th + _GALLERY_LABEL_H_PX then
            return i
        end
    end
    return nil
end

-- Caches images loaded for gallery tiles by path, same lazy-load-once
-- pattern as buttons_gdsGuiLib.lua's per-button image loading, but keyed by
-- path since tiles (unlike buttons) are rebuilt every time setItems runs.
local _galleryImageCache = {}
local function _loadGalleryImage(path)
    if not _galleryImageCache[path] then
        _galleryImageCache[path] = love.graphics.newImage(path)
    end
    return _galleryImageCache[path]
end

-- Draws a plain image (e.g. an app-supplied aircraft-type thumbnail) scaled
-- to fit inside (tx,ty,tw,th), letterboxed to preserve aspect ratio. The
-- library has no idea what the image depicts — it's just an item.thumbnailPath
-- string the app layer resolved, same arm's-length relationship as item.name.
local function _drawThumbnailImage(path, tx, ty, tw, th)
    love.graphics.setColor(0.08, 0.08, 0.10, 1)
    love.graphics.rectangle("fill", tx, ty, tw, th)
    local image = _loadGalleryImage(path)
    local iw, ih = image:getDimensions()
    local pad = math.min(tw, th) * 0.1
    local avail = math.min(tw, th) - pad * 2
    local scale = avail / math.max(iw, ih)
    local drawW, drawH = iw * scale, ih * scale
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(image, tx + (tw - drawW) / 2, ty + (th - drawH) / 2, 0, scale, scale)
end

-- Pure geometry preview: draws the item's real elements/wires, scaled into an
-- arbitrary (tx,ty,tw,th) rect. Always uses each entity's defaultColor (no
-- snapshot/signature resolution — a gallery tile has no "live" control state).
local function _drawMiniDiagram(elements, wires, controls, tx, ty, tw, th)
    love.graphics.setColor(0.08, 0.08, 0.10, 1)
    love.graphics.rectangle("fill", tx, ty, tw, th)

    local function toPixel(fx, fy) return tx + fx * tw, ty + fy * th end
    local function elementCenter(e)
        local ex, ey = toPixel(e.x, e.y)
        return ex + (e.w * tw) / 2, ey + (e.h * th) / 2
    end
    -- A wire's endpoint may be a control (e.g. a switch wired to a bus), not
    -- only an element — the live canvas allows both anchor kinds (_findAnchor),
    -- so the preview has to recognize both too or that wire just vanishes.
    local function anchorCenter(id)
        for _, e in ipairs(elements or {}) do
            if e.id == id then return elementCenter(e) end
        end
        for _, c in ipairs(controls or {}) do
            if c.id == id then return toPixel(c.x, c.y) end
        end
        return nil
    end

    for _, w in ipairs(wires or {}) do
        local x1, y1 = anchorCenter(w.fromElementId)
        local x2, y2 = anchorCenter(w.toElementId)
        if x1 and x2 then
            local c = w.defaultColor or _DEFAULT_COLOR
            love.graphics.setColor(c[1], c[2], c[3], c[4])
            love.graphics.setLineWidth(2)
            _drawOrthogonalLine(x1, y1, x2, y2)
            love.graphics.setLineWidth(1)
        end
    end

    for _, e in ipairs(elements or {}) do
        local ex, ey = toPixel(e.x, e.y)
        local ew, eh = e.w * tw, e.h * th
        local c = e.defaultColor or _DEFAULT_COLOR
        if e.spritePath then
            _drawElementSprite(e.spritePath, ex, ey, ew, eh, c[1], c[2], c[3], c[4], e.rotation)
        elseif e.shapeType == "circle" then
            love.graphics.setColor(c[1], c[2], c[3], c[4])
            love.graphics.ellipse("fill", ex + ew / 2, ey + eh / 2, ew / 2, eh / 2)
        elseif e.shapeType == "diode" then
            _drawDiodeSymbol(ex + ew / 2, ey + eh / 2, ew, eh, e.rotation, c[1], c[2], c[3], c[4])
        else
            love.graphics.setColor(c[1], c[2], c[3], c[4])
            love.graphics.rectangle("fill", ex, ey, ew, eh)
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- One tile's preview artwork: an app-supplied thumbnail image if the item
-- has one (e.g. an aircraft's type icon), else the elements/wires diagram.
local function _drawGalleryTilePreview(item, tx, ty, tw, th)
    if item.thumbnailPath then
        _drawThumbnailImage(item.thumbnailPath, tx, ty, tw, th)
    else
        _drawMiniDiagram(item.elements, item.wires, item.controls, tx, ty, tw, th)
    end
end

function gdsGui_schematicGallery_draw(pageName)
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page == pageName then
            love.graphics.setScissor(gallery.x, gallery.y, gallery.w, gallery.h)
            love.graphics.setColor(0.10, 0.10, 0.12, 1)
            love.graphics.rectangle("fill", gallery.x, gallery.y, gallery.w, gallery.h)

            if #gallery.items == 0 then
                love.graphics.setColor(1, 1, 1, 0.6)
                love.graphics.printf(gallery.emptyText, gallery.x, gallery.y + gallery.h / 2 - 10,
                    gallery.w, "center")
            else
                for i, item in ipairs(gallery.items) do
                    local tx, ty, tw, th = _galleryTileRect(gallery, i)
                    if ty + th + _GALLERY_LABEL_H_PX >= gallery.y and ty <= gallery.y + gallery.h then
                        if item.statusLines then
                            -- Thumbnail + status-text row layout (the
                            -- snapshots gallery): a square thumbnail on the
                            -- left, the item's name/timestamp and its list of
                            -- control positions filling the rest of the row.
                            local diagW = th
                            _drawGalleryTilePreview(item, tx, ty, diagW, th)
                            love.graphics.setColor(1, 1, 0, 1)
                            love.graphics.rectangle("line", tx, ty, diagW, th)
                            love.graphics.setColor(1, 1, 1, 1)
                            local textX, textW = tx + diagW + 8, tw - diagW - 8
                            love.graphics.printf(item.name or item.id, textX, ty, textW, "left")
                            love.graphics.printf(table.concat(item.statusLines, "\n"), textX, ty + 18, textW, "left")
                        else
                            _drawGalleryTilePreview(item, tx, ty, tw, th)
                            love.graphics.setColor(1, 1, 0, 1)
                            love.graphics.rectangle("line", tx, ty, tw, th)
                            love.graphics.setColor(1, 1, 1, 1)
                            love.graphics.printf(item.name or item.id, tx, ty + th + 2, tw, "center")
                        end
                    end
                end
            end

            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.setScissor()
        end
    end
end

-- Drawn last by the app layer, after floating chrome buttons, same convention
-- as gdsGui_schematic_drawMenuOverlay.
function gdsGui_schematicGallery_drawMenuOverlay(pageName)
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page == pageName and gallery.menu then
            _drawMenuBox(gallery, gallery.menu)
        end
    end
end

function gdsGui_schematicGallery_pressed(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page ~= activePageName then goto continue end

        if gallery.menu then
            _handleMenuPress(gallery, touchId, x, y)
            goto continue
        end

        if gallery.focusTouchId ~= nil then goto continue end
        if x < gallery.x or x > gallery.x + gallery.w or y < gallery.y or y > gallery.y + gallery.h then
            goto continue
        end

        gallery.focusTouchId      = touchId
        gallery.pressStartX       = x
        gallery.pressStartY       = y
        gallery.pressStartScrollY = gallery.scrollY
        gallery.moved             = false

        ::continue::
    end
end

function gdsGui_schematicGallery_moved(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page ~= activePageName then goto continue end
        if gallery.menu then goto continue end
        if gallery.focusTouchId ~= touchId then goto continue end

        local dy = gallery.pressStartY - y
        if math.abs(dy) > _GALLERY_TAP_SLOP_PX then gallery.moved = true end
        local maxScroll = _galleryMaxScroll(gallery)
        gallery.scrollY = math.max(0, math.min(maxScroll, gallery.pressStartScrollY + dy))

        ::continue::
    end
end

function gdsGui_schematicGallery_released(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page ~= activePageName then goto continue end
        if gallery.menu then
            -- Same stuck-focusTouchId guard as gdsGui_schematic_released
            -- above — see its comment.
            if gallery.focusTouchId == touchId then gallery.focusTouchId = nil end
            _handleMenuRelease(gallery, touchId, x, y)
            goto continue
        end
        if gallery.focusTouchId == touchId then
            if not gallery.moved then
                local idx = _galleryTileAt(gallery, gallery.pressStartX, gallery.pressStartY)
                local item = idx and gallery.items[idx]
                if item and gallery.onSelect and _G[gallery.onSelect] then
                    _G[gallery.onSelect](gallery.name, item.id)
                end
            end
            gallery.focusTouchId = nil
        end
        ::continue::
    end
end

function gdsGui_schematicGallery_update(dt)
    -- No per-frame physics (scroll is directly position-driven); no-op for now.
end
