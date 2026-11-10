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

local _CONTROL_RADIUS_FRAC   = 0.045   -- shared control hit/draw radius basis, as a fraction of min(canvas.contentW, canvas.contentH) — see _controlGridRadiusScale
-- World units between grid lines (see _snapToGrid) AND the one "gridUnit"
-- every element/control's own footprint is now authored in: a catalog item
-- with gridW=2 (or gridSize=2 for a control) places as exactly 2 of these
-- squares wide on screen, at any zoom or window size, the same way
-- _snapToGrid keeps a snapped position on-grid regardless of zoom — see
-- _elementGridFootprintFrac/_controlGridRadiusScale below.
local _GRID_SPACING_PX       = 2
local _MIN_ZOOM               = 1      -- fully zoomed out: the whole canvas box fits exactly in the viewport
local _MAX_ZOOM               = 8
-- Element/control labels are invisible from _MIN_ZOOM through
-- _LABEL_FADE_START_ZOOM (zoomed out, symbols are small and crowded —
-- labels would just be clutter), then fade in linearly as zoom climbs from
-- there up to _MAX_ZOOM, reaching fully opaque only once fully zoomed in.
local _LABEL_FADE_START_ZOOM   = 4
-- Floor on an element's label print width (see _drawElement) — not scaled
-- by zoom, since the label font itself isn't either, so this stays a fixed
-- on-screen budget comfortably wide enough for a short name at any normal
-- font size, regardless of how narrow the element's own gridW/gridH box is.
local _LABEL_MIN_WIDTH_PX     = 160
local _PINCH_MIN_DIST_PX      = 1      -- guards against a near-zero divisor right as a pinch begins
local _WIRE_WIDTH_PX         = 2 / 3   -- half of the previous 4/3px width
local _WIRE_CROSS_HOP_RADIUS_PX = 2.5   -- radius of the little arc hop drawn where a wire crosses an unrelated one
local _WIRE_BUNDLE_STRIPE_LEN_PX = _GRID_SPACING_PX    -- length of one color's own diagonal band along a bundle -- exactly 1 grid unit (see _GRID_SPACING_PX)
local _CONNECTOR_RELEASE_SLOP_PX = 16  -- forgiveness margin for "which element did the wire-drag land on", since exact-rectangle precision is unreliable on a touchscreen
local _CONNECTOR_TARGET_RADIUS_PX = 9  -- drawn radius of the green "valid connection point" reticle shown at each element's center while a wire is being dragged
local _CONNECTOR_SNAP_COLOR  = {0.25, 0.95, 0.35, 1}
local _DEFAULT_COLOR         = {0.75, 0.75, 0.75, 1}   -- light gray, matches the palette's LIGHT GRAY swatch

-- In WHITE MODE (globApp.themeIsDark == false, set by the app layer's
-- dark/light toggle), every palette-sourced color — the paint-brush/swatch-
-- picker swatch previews, plus every element/wire/control actually showing
-- one, default gray included — reads as washed out against the light
-- canvas backdrop, so it's darkened by this factor before being drawn.
-- Dark mode (also the default when the app layer never sets the flag at
-- all) leaves colors untouched.
-- The default gray (_DEFAULT_COLOR, the palette's LIGHT GRAY) is the one
-- exception: it's stored as a single value but drawn as a fixed per-theme
-- shade instead — 150/150/150 in dark mode, 50/50/50 in white mode — so
-- every unpainted element/wire/control (and the gray swatch itself) reads
-- the same against either canvas backdrop.
local _LIGHT_MODE_COLOR_DARKEN = 0.6
local function _themedPaletteColor(r, g, b, a)
    local isLight = globApp.themeIsDark == false
    if r == _DEFAULT_COLOR[1] and g == _DEFAULT_COLOR[2] and b == _DEFAULT_COLOR[3] then
        local gray = (isLight and 50 or 150) / 255
        return gray, gray, gray, a
    end
    if isLight then
        return r * _LIGHT_MODE_COLOR_DARKEN, g * _LIGHT_MODE_COLOR_DARKEN, b * _LIGHT_MODE_COLOR_DARKEN, a
    end
    return r, g, b, a
end
local _MENU_ROW_H            = 32
local _MENU_WIDTH_FRAC       = 0.8
local _MENU_OPACITY          = 0.85 -- all modal menu panels render 15% transparent
local _ELEMENT_TAP_SLOP_PX   = 6   -- max press->release movement still counted as a tap, not a drag
local _LONG_PRESS_SECONDS    = 1.3 -- how long a held (not-yet-moved) press on an element/control/wire takes to unlock move/rotate/direction mode — see gdsGui_schematic_update
local _CONFIRM_HOLD_SECONDS  = 2   -- how long a menu's explicitly-marked confirm row(s) must be held before firing — see _markConfirmMenu/_pollMenuHoldToConfirm
local _CONFIRM_HOLD_MAX_DT   = 0.1 -- per-frame cap when accumulating the hold above — stops one stalled/slow frame (GC pause, app resume) from satisfying the whole hold instantly
local _WIRE_TAP_SLOP_PX      = 10  -- max distance from a wire's drawn line still counted as tapping it
local _SWATCH_ROW_H_PX       = 64  -- height of the single row of color squares in a swatch picker
local _SWATCH_GAP_PX         = 8
local _OVERLAY_SPIN_RADPS    = math.pi * 1.5  -- a control's overlaySpritePath spin rate in control mode (0.75 rev/s)
local _MOVE_ARROW_SIZE_PX    = 7   -- move-mode edge-arrow glyph length (see _drawMoveModeOverlay)
local _MOVE_ARROW_GAP_PX     = 5   -- gap between the bounding box edge and the nearest point of its arrow
local _ROTATE_ARC_GAP_RAD    = math.rad(70)  -- open gap left in the rotate-mode ring (see _drawRotateModeOverlay) so it reads as an arrow, not a closed circle
local _ROTATE_ARC_MARGIN_PX  = 6   -- gap between the shape's own outline and the rotate ring drawn around it

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

-- Fixed 4-color set for annunciators (see the ANNUNCIATORS section below) —
-- the standard caution/warning palette real annunciator panels use, kept
-- separate from the generic 5-color _COLOR_PALETTE above since an
-- annunciator's color is a meaningful status indicator (not just a free
-- paint choice) and the app asks for exactly 4 options. Order here IS the
-- readout's display rank (red on top, down to white — see
-- _annunciatorColorRank/_sortedActiveAnnunciatorsForDisplay further down),
-- so it also determines the order the color-pick menu itself lists them in.
local _ANNUNCIATOR_COLORS = {
    {name = "RED",    color = {0.95, 0.15, 0.15, 1}},
    {name = "YELLOW", color = {1, 0.9, 0, 1}},
    {name = "GREEN",  color = {0.15, 0.85, 0.3, 1}},
    {name = "WHITE",  color = {1, 1, 1, 1}},
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

-- Finds an app-registered dock button (PAINT/ANNUNCIATOR/menu anchor — see
-- gdsGui_schematic_setPaintButtonName and its siblings) by name, or nil if
-- none was ever registered.
local function _findButton(name)
    if not name then return nil end
    for _, b in ipairs(globApp.objects.buttons) do
        if b.name == name then return b end
    end
    return nil
end

-- Gap between a dock tool's button column and the popup (menu, paint
-- palette, annunciator panel) it opens to its left, top-aligned with the
-- canvas's own top edge — see _toolPopupOrigin.
local _TOOL_POPUP_GAP_PX = 8

-- Right edge x and top y a dock tool's popup of width w opens at: just left
-- of that tool's button, flush with the canvas's top edge. Every tool popup
-- (ADD's catalog menus, the paint palette, the annunciator panel) shares
-- this one origin so they all read as opening out of the same spot.
local function _toolPopupOrigin(canvas, btn, w)
    local x = math.max(canvas.x, btn.myx - _TOOL_POPUP_GAP_PX - w)
    return x, canvas.y
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

-- Shared "look up a color-pick/resolve target by its kind" dispatch for
-- gdsGui_schematic_setPendingColor/_resolveColor/_resolveDisplayColor below.
-- Not the "A and B or C" idiom (see gdsGui_schematic_resolveColor's own
-- comment on this): _findElement/_findWire can each themselves return nil
-- for a bad targetId, which would otherwise silently fall through to the
-- next kind's lookup and resolve/recolor the WRONG object if a different
-- kind happened to share that id.
local function _findByKind(canvas, targetKind, id)
    if targetKind == "element" then return _findElement(canvas, id)
    elseif targetKind == "wire" then return _findWire(canvas, id)
    else return _findControl(canvas, id) end
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
-- Forward-declared like the two above: defined further down (PUBLIC API —
-- ANNUNCIATORS) once _openSwatchColorMenu exists, but referenced by
-- gdsGui_schematic_placementNameConfirmed well before that point.
local _openAnnunciatorColorMenu
-- Forward-declared like _openElementRenamePrompt above: assigned further
-- down (PUBLIC API — DESIGN-MODE ANNUNCIATOR EDIT MENU) but called from
-- gdsGui_schematic_internal_onAnnunciatorEditChosen, defined earlier in that
-- same section — needs to already exist as this upvalue at that point.
local _openAnnunciatorRenamePrompt

local _UNDO_STACK_MAX = 20

local function _snapshotState(canvas)
    -- Shallow, not deep — canvas.snapshots is one full color map PER
    -- CAPTURED COMBINATION (gdsGui_schematic_commitSnapshot), so a deep
    -- copy of it scales with elements x captured snapshots, paid on every
    -- undo-tracked edit (every drag, rename, delete...) — for a user
    -- who's captured a few hundred combinations (exactly what the AI
    -- panel's own workflow encourages), that's a real, unbounded cost on
    -- every subsequent drag. Safe because an individual captured
    -- snapshot (canvas.snapshots[sig]) is only ever replaced wholesale or
    -- deleted outright — commitSnapshot assigns canvas.snapshots[sig] =
    -- {a brand-new table}, deletion sets canvas.snapshots[sig] = nil —
    -- never mutated in place field by field once created (no call site
    -- anywhere writes into an existing snap.elements/controls/wires
    -- bucket directly). A later replace/delete on the LIVE
    -- canvas.snapshots can't retroactively change what THIS copy's own
    -- entries already point to, so reusing the same inner per-signature
    -- tables here is exactly as correct as a full recursive copy, at a
    -- fraction of the cost. Built as a plain local loop (not a separate
    -- top-level _shallowCopy helper) since it has exactly one caller.
    local snapshotsCopy = {}
    for k, v in pairs(canvas.snapshots) do snapshotsCopy[k] = v end

    return {
        elements     = _deepCopy(canvas.elements),
        wires        = _deepCopy(canvas.wires),
        controls     = _deepCopy(canvas.controls),
        annunciators = _deepCopy(canvas.annunciators),
        snapshots    = snapshotsCopy,
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
    for _, a in ipairs(canvas.annunciators) do
        if a.label and a.label:lower() == needle and not (excludeKind == "annunciator" and a.id == excludeId) then
            return true
        end
    end
    return false
end

-- Suggests "TYPE_N" for the "name this element/control" prompt, where TYPE is
-- the short type name the app passed as the placement label (e.g. "BATT") and N is one past the highest
-- "TYPE_<n>" name already on the canvas — the LAST element of that type's
-- number, plus 1, not a running total. So deleting some back down still
-- resumes after the highest survivor rather than reusing a freed number, and
-- a user who renamed their instances away from this pattern simply doesn't
-- count toward it.
local function _suggestedPlacementName(canvas, typeLabel)
    local pattern = "^" .. typeLabel:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1") .. "_(%d+)$"
    local maxN = 0
    for _, list in ipairs({canvas.elements, canvas.controls, canvas.annunciators}) do
        for _, item in ipairs(list) do
            local n = item.label and item.label:match(pattern)
            if n then maxN = math.max(maxN, tonumber(n)) end
        end
    end
    return typeLabel .. "_" .. (maxN + 1)
end

-- Set while either naming flow below is open — the plain text prompt
-- (gdsGui_schematic_placementNameConfirmed, annunciators only) or the
-- unified placement grid (_openElementPlacementGrid, every element/
-- control) — holding everything needed to actually create the thing once a
-- valid, unique name (and, for the grid, everything else it collected) is
-- confirmed.
local _pendingNamedPlacement = nil
-- _openElementPlacementGrid's own shadow rows (NAME + whatever
-- canvas.elementPlacementExtraRows/defaultPropertyKeys add) while that grid
-- is open — read back in gdsGui_schematic_internal_onElementPlacementSaved,
-- same "stash it, the grid's own canvas.menu is already gone by the time
-- the callback fires" reasoning _openPropertiesMenu's own
-- canvas._pendingPropertyRows uses.
local _pendingPlacementRows = nil

local function _openPlacementNamePrompt(title, initialText)
    gdsGui_textPrompt_open(title, initialText, 24,
        "gdsGui_schematic_placementNameConfirmed", "gdsGui_schematic_placementNameCancelled")
end

-- Finalizes a validated placement (pending.kind == "element" | "control"):
-- creates the element/control and wipes every existing snapshot, since
-- either kind of addition changes the "cast" a snapshot colors (for a
-- control, also the total number of combinations — see the CONTROL-POSITION
-- COMBINATION CYCLING section below). Split out of
-- gdsGui_schematic_placementNameConfirmed so the snapshot-wipe confirm step
-- there can defer actually running this until the user confirms.
-- Converts a catalog item's gridW/gridH (its footprint in whole "grid
-- units" — see _GRID_SPACING_PX) into the 0-1 content-fraction w/h
-- gdsGui_schematic_addElement expects: multiply by the shared world-unit
-- grid pitch, then divide out contentW/H (not a precomputed static
-- fraction) so the result stays exactly gridW/gridH squares wide/tall
-- regardless of the live window's current size/aspect ratio, including a
-- later resize.
local function _elementGridFootprintFrac(canvas, gridW, gridH)
    return (gridW or 1) * _GRID_SPACING_PX / canvas.contentW,
           (gridH or 1) * _GRID_SPACING_PX / canvas.contentH
end

-- Converts a control catalog item's gridSize (its diameter in whole grid
-- units) into the radiusScale gdsGui_schematic_addControl stores
-- per-instance: canvas.controlRadius is the one shared, size-fits-all
-- control radius (see _CONTROL_RADIUS_FRAC), so dividing the grid-unit
-- radius by it bakes in whatever scale this particular gridSize needs —
-- the control equivalent of _elementGridFootprintFrac above.
local function _controlGridRadiusScale(canvas, gridSize)
    return (gridSize or 2) * _GRID_SPACING_PX / 2 / canvas.controlRadius
end

-- Computes wFrac/hFrac for a pending "element" placement the same way
-- _commitNamedPlacement builds the real element below, so grid-snapping
-- (which runs before the element exists, at the initial-tap call site)
-- uses the element's true gridW/gridH footprint.
local function _pendingElementSizeFrac(canvas, pending)
    if pending.wFrac then return pending.wFrac, pending.hFrac end
    return _elementGridFootprintFrac(canvas, pending.gridW, pending.gridH)
end

local function _commitNamedPlacement(canvas, pending, trimmed)
    gdsGui_haptics_feedback("light")
    if pending.kind == "element" then
        _pushUndo(canvas)
        local properties = {}
        for _, key in ipairs(pending.defaultPropertyKeys or {}) do
            table.insert(properties, { key = key, value = "" })
        end
        local wFrac, hFrac = _pendingElementSizeFrac(canvas, pending)
        gdsGui_schematic_addElement(pending.canvasName, pending.newId, pending.shapeType,
            pending.fracX, pending.fracY, wFrac, hFrac,
            trimmed, pending.defaultColor, properties, pending.rotation, pending.spritePath, pending.componentType,
            _deepCopy(pending.terminals))
        canvas.elements[#canvas.elements].shapePoints = pending.shapePoints
        canvas.snapshots = {}
        _notifyChanged(canvas)
    else
        _pushUndo(canvas)
        gdsGui_schematic_addControl(pending.canvasName, pending.newId, pending.fracX, pending.fracY,
            pending.positions, 0, trimmed, pending.callbackFunc,
            _controlGridRadiusScale(canvas, pending.gridSize), pending.spritePaths,
            nil, pending.overlaySpritePath, nil, pending.colorDarkenMul, pending.componentType,
            _deepCopy(pending.terminals))
        canvas.snapshots = {}
        _notifyChanged(canvas)
    end
    -- Lets the app layer react to a freshly-placed element/control right
    -- away (e.g. prompting a "source"-role item for its voltage the instant
    -- it's named) without this library needing to know what componentType
    -- actually means — same callback-by-name convention as canvas.onChange
    -- above, just fired with the new item's own kind/id/componentType too.
    if canvas.onElementPlaced then
        local fn = _G[canvas.onElementPlaced]
        if fn then fn(pending.canvasName, pending.kind, pending.newId, pending.componentType) end
    end
end

-- Finalizes everything beyond NAME that _openElementPlacementGrid's own grid
-- collected (SOURCE TYPE/VOLTAGE/POWERED COLOR via canvas.
-- elementPlacementExtraRows, any defaultPropertyKeys), once the element/
-- control itself already exists (_commitNamedPlacement already ran by the
-- time either call site below reaches this). Rows apply strictly IN ORDER
-- (not two passes) so an earlier row's write is already live by the time a
-- later row's own hook runs — e.g. POWERED COLOR's own
-- canvas.elementPropertiesRowSaved reads entity.voltage, which only exists
-- because VOLTAGE (always the row right before it) already landed. A row
-- with target == "field" is written straight onto the entity by its own key
-- (e.g. .voltage, .voltageType — main.lua reads these directly, same as it
-- always has); a row with any OTHER target (e.g. "voltageColor") is left
-- entirely to canvas.elementPropertiesRowSaved — the exact same by-name hook
-- the PROPERTIES edit grid's own onPropertiesSaved defers to, so a row
-- shape only ever needs one app-side handler regardless of which grid
-- collected it; a row with no target at all (the default) goes through the
-- normal gdsGui_schematic_setElementProperty path, same as any other custom
-- property. Row 1 (NAME) is skipped here — _commitNamedPlacement already
-- consumed it. Fires canvas.elementPlacementConfigured (optional, by-name)
-- once everything's written, for the app to react to the FINAL state (e.g.
-- flagging a bus tie's logic as possibly needing a new row for the new
-- voltage) — separate from canvas.onElementPlaced, which
-- _commitNamedPlacement already fired earlier while these fields were all
-- still blank.
-- Global, not local — this file is already at Lua's 200-top-level-local
-- ceiling (same constraint main.lua's own _openFundamentalsMenu comment
-- describes).
function _applyPlacementExtraRows(canvasName, canvas, newId, rows)
    local entity = _findAnchor(canvas, newId)
    if not entity then return end
    for i = 2, #rows do
        local row = rows[i]
        if row.target == "field" then
            entity[row.key] = (row.numeric and tonumber(row.value)) or row.value
        elseif row.target then
            if canvas.elementPropertiesRowSaved then
                local fn = _G[canvas.elementPropertiesRowSaved]
                if fn then fn(canvasName, newId, row) end
            end
        else
            gdsGui_schematic_setElementProperty(canvasName, newId, row.key, row.value or "")
        end
    end
    _notifyChanged(canvas)
    if canvas.elementPlacementConfigured then
        local fn = _G[canvas.elementPlacementConfigured]
        if fn then fn(canvasName, newId) end
    end
end

-- Replaces the old "NAME THIS <KIND>" text prompt for every element/control
-- placement (tap-to-place path below) with one unified grid: NAME (always,
-- pre-filled with the same auto-suggested unique name the old prompt
-- started with), plus whatever extra rows canvas.elementPlacementExtraRows
-- supplies for this item's own componentType (main.lua uses this for a
-- "source" item's SOURCE TYPE/VOLTAGE), plus one row per defaultPropertyKeys
-- — all mandatory (requireAll), same "fill it in before moving on"
-- treatment a bus tie's own missing logic gets (see _relays.checkLogic in
-- main.lua), just collected up front instead of chased down after the fact.
-- The validate closure enforces the exact same non-empty/unique NAME rule
-- gdsGui_schematic_placementNameConfirmed always has, just in-place instead
-- of closing and reopening a separate prompt on rejection.
-- Global, not local — same 200-top-level-local ceiling as
-- _applyPlacementExtraRows just above.
function _openElementPlacementGrid(canvasName, pending)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local rows = { { key = "__name", label = "NAME", value = _suggestedPlacementName(canvas, pending.label) } }
    if canvas.elementPlacementExtraRows then
        local fn = _G[canvas.elementPlacementExtraRows]
        local extra = fn and fn(canvasName, pending.componentType, pending)
        for _, r in ipairs(extra or {}) do table.insert(rows, r) end
    end
    for _, key in ipairs(pending.defaultPropertyKeys or {}) do
        table.insert(rows, { key = key, label = key, value = "" })
    end
    _pendingNamedPlacement = pending
    _pendingPlacementRows = rows
    gdsGui_schematic_openPropertyGrid(canvasName, gdsGui_schematic_elementPropertiesTitle(), pending.header, rows, true,
        "gdsGui_schematic_internal_onElementPlacementSaved", "gdsGui_schematic_internal_onElementPlacementCancelled",
        function(gridRows)
            local trimmed = (gridRows[1].value or ""):gsub("^%s*(.-)%s*$", "%1")
            if trimmed == "" then return false, 1, "NAME REQUIRED" end
            if _labelInUse(canvas, trimmed) then return false, 1, "NAME TAKEN, TRY ANOTHER" end
            return true
        end)
    -- Auto-focuses NAME the instant the grid opens, matching the old
    -- standalone text prompt's own immediate-keyboard behavior — the user
    -- still has to tap into every OTHER row, just not this near-universal
    -- first one.
    canvas.menu.activeRow = 1
    local g = _propertyGrid.geometry(canvas, canvas.menu)
    love.keyboard.setTextInput(true, _propertyGrid.valueBoxRect(g, g.bodyY))
end

function gdsGui_schematic_internal_onElementPlacementSaved(canvasName)
    local pending = _pendingNamedPlacement
    local rows = _pendingPlacementRows
    _pendingNamedPlacement, _pendingPlacementRows = nil, nil
    if not pending or not rows then return end
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local trimmed = (rows[1].value or ""):gsub("^%s*(.-)%s*$", "%1")
    -- _commitNamedPlacement unconditionally wipes every snapshot — worth an
    -- explicit "are you sure" only when there's actually something to lose,
    -- same gate gdsGui_schematic_placementNameConfirmed's own equivalent
    -- step uses (gdsGui_schematic_internal_onPlacementSnapshotWipeConfirmed
    -- below is shared with that older flow — pending.confirmedRows, only
    -- ever set here, is what tells its own CONTINUE branch there's more to
    -- apply than just the name).
    local snapshotCount = gdsGui_schematic_countSnapshots(canvasName)
    if snapshotCount > 0 then
        pending.confirmedName = trimmed
        pending.confirmedRows = rows
        _pendingNamedPlacement = pending
        gdsGui_schematic_openMenu(canvasName,
            "ADDING A NEW " .. pending.kind:upper() .. " WILL DELETE ALL " ..
            snapshotCount .. " SNAPSHOT(S). CONTINUE?",
            {"CONTINUE", "CANCEL"},
            "gdsGui_schematic_internal_onPlacementSnapshotWipeConfirmed",
            "gdsGui_schematic_internal_onPlacementSnapshotWipeConfirmed", 1)
        return
    end
    _commitNamedPlacement(canvas, pending, trimmed)
    _applyPlacementExtraRows(canvasName, canvas, pending.newId, rows)
end

function gdsGui_schematic_internal_onElementPlacementCancelled()
    _pendingNamedPlacement = nil
    _pendingPlacementRows = nil
end

-- Resolved by name via _G[...] from textPrompt_gdsGuiLib.lua, like every other
-- string-registered callback in this library. Only ever reached for
-- pending.kind == "annunciator" now (gdsGui_schematic_armAnnunciatorCreation
-- below is this prompt's only remaining entry point) — every element/
-- control placement goes through _openElementPlacementGrid instead, which
-- enforces this same non-empty/unique NAME rule itself (see its own
-- validate closure).
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
    pending.confirmedName = trimmed
    _openAnnunciatorColorMenu(pending.canvasName)
end

function gdsGui_schematic_placementNameCancelled()
    _pendingNamedPlacement = nil
end

-- Entry point for the catalog's "ANNUNCIATOR" row (main.lua's
-- schematicCatalogItemChosen — see the app-layer ADD cascade). Unlike every
-- other catalog item, an annunciator has no canvas position to tap for: it
-- always renders in the fixed, alphabetically-stacked top-left corner (see
-- _drawAnnunciators further down), so there's no pendingPlacement/tap-to-
-- place step — choosing it jumps straight to the plain NAME text prompt
-- (gdsGui_schematic_placementNameConfirmed/_Cancelled), the one placement
-- kind still simple enough not to need the full unified grid every
-- element/control placement opens instead.
function gdsGui_schematic_armAnnunciatorCreation(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    _pendingNamedPlacement = { canvasName = canvasName, kind = "annunciator" }
    _openPlacementNamePrompt(gdsGui_schematic_elementPropertiesTitle(), _suggestedPlacementName(canvas, "ANNC"))
end

-- Shared onSelect/onCancel for the snapshot-wipe confirm menu above: both
-- CONTINUE and CANCEL land here (distinguished by optionText), as does
-- tapping outside (optionText is nil — treated the same as CANCEL, i.e. the
-- placement is abandoned rather than silently falling back to the text
-- prompt).
function gdsGui_schematic_internal_onPlacementSnapshotWipeConfirmed(canvasName, index, optionText)
    local pending = _pendingNamedPlacement
    _pendingNamedPlacement = nil
    if not pending or pending.canvasName ~= canvasName then return end
    if optionText == "CONTINUE" then
        local canvas = _findCanvas(canvasName)
        if canvas then
            _commitNamedPlacement(canvas, pending, pending.confirmedName)
            -- Only set when this came from _openElementPlacementGrid's own
            -- SAVE (gdsGui_schematic_internal_onElementPlacementSaved
            -- above) — the older plain-text NAME prompt never sets it, so
            -- this is a no-op for that path.
            if pending.confirmedRows then
                _applyPlacementExtraRows(canvasName, canvas, pending.newId, pending.confirmedRows)
            end
        end
    end
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
-- and drag site so a dragged piece always lands exactly on a drawn line.
-- Spacing is expressed in world units (contentW/H, zoom-independent) so the
-- grid is a fixed reference: a position on-grid at one zoom level is still
-- on-grid at any other, the same way physical graph paper doesn't redraw
-- its own lines when you zoom a photo of it. (A spacing that divided by
-- canvas.zoom here, matching _drawGrid's on-screen _GRID_SPACING_PX-apart appearance,
-- would instead make "on-grid" itself zoom-dependent — two elements each
-- perfectly snapped at different zoom levels would no longer align with
-- each other, since each was snapped against a differently-pitched grid.)
local function _snapToGrid(canvas, fracX, fracY)
    local spacingX = _GRID_SPACING_PX / canvas.contentW
    local spacingY = _GRID_SPACING_PX / canvas.contentH
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

-- True for a quarter-turn (90 or 270, mod 360) — the only rotations
-- (alongside 0/180, which leave w/h as-is) a rotatable element sits at unless
-- it's reshapable (see _snapRotationDegrees, _shapePoly.freeRotationDegrees),
-- and the only ones where its own axis-aligned footprint comes out with
-- width/height swapped from its stored w/h.
local function _isQuarterTurnRotation(rotationDeg)
    return ((rotationDeg or 0) % 180) == 90
end

-- An element's TRUE axis-aligned world-space footprint — the box every
-- hit-test/collision/selection site should measure against, as opposed to
-- _elementPixelRect's own ew,eh, which stay the UNROTATED local dimensions
-- the draw-time push/rotate transform expects (see _drawElement's
-- drawShapeWithColor). A quarter turn's real footprint is exactly its stored
-- box with width/height swapped; a reshapable element at any other angle gets
-- the box enclosing it, and its own outline does the exact hit/collision tests
-- (see _shapePoly). Center stays the same point either way, so it's computed off the
-- original (unswapped) box before swapping.
local function _elementFootprintRect(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    local cx, cy = ex + ew / 2, ey + eh / 2
    if _isQuarterTurnRotation(e.rotation) then
        ew, eh = eh, ew
    elseif (e.rotation or 0) % 90 ~= 0 then
        local cosR, sinR = _shapePoly.cosSin(e.rotation)
        ew, eh = math.abs(ew * cosR) + math.abs(eh * sinR), math.abs(ew * sinR) + math.abs(eh * cosR)
    end
    return cx - ew / 2, cy - eh / 2, ew, eh
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

-- RESHAPABLE ELEMENTS: an element whose kind the app has named (see
-- gdsGui_schematic_setReshapableKind — e.g. a fuel tank) can have its outline
-- redrawn in a third gesture mode after move and rotate. Its shape is stored
-- as e.shapePoints, a flat { c1, r1, c2, r2, ... } list of polygon corners in
-- grid units, always shifted so the corners' own bounding box starts at 0,0 —
-- which e.x/y/w/h keep tracking, so every bounding-box consumer (rotation,
-- label, move arrows) just keeps working. Always a simple polygon with no
-- straight-through corners (see _shapePoly.encode). nil until the first real
-- edit, so an untouched element keeps drawing as its own plain shapeType.
-- Global for the same 200-local ceiling as _propertyGrid below.
_shapePoly = {}
_shapePoly.HOLD_SECONDS = 2    -- the hold that unlocks a reshapable element's modes, in place of _LONG_PRESS_SECONDS
_shapePoly.HANDLE_HIT_PX = 14  -- reach of a corner handle or side, in screen pixels (not zoom-scaled, so a fingertip always fits)
_shapePoly.EMPTY_SHADE = 0.25  -- brightness of the part of a tank above its fill line (see drawLevel)
_shapePoly.parsedCache = setmetatable({}, { __mode = "k" })

-- Decoded shapePoints, cached per table (each edit stores a brand-new one):
-- corners (the draggable vertices), edges (each corner to the next), triangles
-- (the fill), and runs (each row's spans of grid squares the shape reaches
-- into, half-open c0..c1, which is what it collides with — see eachSpanBox).
function _shapePoly.parse(points)
    local p = _shapePoly.parsedCache[points]
    if p then return p end
    p = { rows = 0, cols = 0, corners = {}, edges = {}, runs = {}, triangles = love.math.triangulate(points) }
    for i = 1, #points, 2 do
        local c, r = points[i], points[i + 1]
        table.insert(p.corners, { c = c, r = r })
        table.insert(p.edges, { c, r, points[i + 2] or points[1], points[i + 3] or points[2] })
        p.cols, p.rows = math.max(p.cols, c), math.max(p.rows, r)
    end
    local lastC, lastR = math.ceil(p.cols) - 1, math.ceil(p.rows) - 1
    for r = 0, lastR do
        local runStart
        for c = 0, lastC + 1 do
            local reached = c <= lastC and _shapePoly.reachesSquare(p, c, r)
            if reached and not runStart then
                runStart = c
            elseif runStart and not reached then
                table.insert(p.runs, { c0 = runStart, c1 = c, r = r })
                runStart = nil
            end
        end
    end
    _shapePoly.parsedCache[points] = p
    return p
end

-- Even-odd test, in grid units.
function _shapePoly.containsLocal(p, lx, ly)
    local inside = false
    for _, edge in ipairs(p.edges) do
        local c1, r1, c2, r2 = edge[1], edge[2], edge[3], edge[4]
        if (r1 > ly) ~= (r2 > ly) and lx < c1 + (ly - r1) / (r2 - r1) * (c2 - c1) then
            inside = not inside
        end
    end
    return inside
end

-- Whether the shape overlaps the inside of grid square c,r: either the square
-- sits within it, or its outline passes through the square (running along the
-- square's border doesn't count).
function _shapePoly.reachesSquare(p, c, r)
    if _shapePoly.containsLocal(p, c + 0.5, r + 0.5) then return true end
    for _, edge in ipairs(p.edges) do
        local tMin, tMax = 0, 1
        for _, slab in ipairs({ { edge[1], edge[3] - edge[1], c }, { edge[2], edge[4] - edge[2], r } }) do
            local from, step, low = slab[1], slab[2], slab[3]
            if step ~= 0 then
                local t1, t2 = (low - from) / step, (low + 1 - from) / step
                tMin, tMax = math.max(tMin, math.min(t1, t2)), math.min(tMax, math.max(t1, t2))
            elseif from <= low or from >= low + 1 then
                tMax = -1
            end
        end
        if tMin < tMax then return true end
    end
    return false
end

-- The kind check behind every reshape gesture (see gdsGui_schematic_setReshapableKind).
function _shapePoly.allowed(canvas, e)
    local kinds = canvas.reshapableKind
    if not kinds then return false end
    for _, k in ipairs(kinds) do
        if e.shapeType == k.shapeType and e.componentType == k.componentType then return true end
    end
    return false
end

-- The element in reshape mode right now, or nil.
function _shapePoly.activeTarget(canvas)
    if not (canvas.reshapeModeActive and canvas.selectionMoveModeActive and canvas.selectedElementId) then return nil end
    local e = _findElement(canvas, canvas.selectedElementId)
    return (e and _shapePoly.allowed(canvas, e)) and e or nil
end

-- e.shapePoints, or the full box a not-yet-edited element's first edit starts from.
function _shapePoly.pointsOf(canvas, e)
    if e.shapePoints then return e.shapePoints end
    local cols = math.max(1, math.floor(e.w * canvas.contentW / _GRID_SPACING_PX + 0.5))
    local rows = math.max(1, math.floor(e.h * canvas.contentH / _GRID_SPACING_PX + 0.5))
    return { 0, 0, cols, 0, cols, rows, 0, rows }
end

-- The polygon for a shape saved as the rows of "#"/"." grid squares tanks used
-- before they became polygons ({"###", "#..", "#.."} is an L): walks its outer
-- boundary clockwise from its top-left corner, taking the right-hand way at a
-- diagonal pinch so the walk stays on the outer boundary. Keeps the bounding
-- box exactly, so the saved e.x/y/w/h still fit it.
function _shapePoly.pointsFromRows(rows)
    local function filled(c, r, offsetC, offsetR)
        local line = rows[math.floor(r + offsetR / 2) + 1]
        return line ~= nil and line:sub(math.floor(c + offsetC / 2) + 1, math.floor(c + offsetC / 2) + 1) == "#"
    end
    local startC = rows[1]:find("#", 1, true) - 1
    local points = { startC, 0 }
    local c, r, dirC, dirR = startC + 1, 0, 1, 0
    while c ~= startC or r ~= 0 do
        -- The body stays on the walk's right, so the two squares just ahead
        -- decide the next step: right if the right one's empty, left if the
        -- left one's filled too, otherwise straight on.
        local nextC, nextR = dirC, dirR
        if not filled(c, r, dirC - dirR, dirR + dirC) then
            nextC, nextR = -dirR, dirC
        elseif filled(c, r, dirC + dirR, dirR - dirC) then
            nextC, nextR = dirR, -dirC
        end
        if nextC ~= dirC or nextR ~= dirR then
            table.insert(points, c)
            table.insert(points, r)
        end
        dirC, dirR = nextC, nextR
        c, r = c + dirC, r + dirR
    end
    return (_shapePoly.encode(points))
end

-- A cardinal turn rounds to exact 0/1/-1 rather than carrying float noise into
-- wire endpoints, which is what keeps a straight wire exactly straight.
function _shapePoly.cosSin(rotationDeg)
    local a = math.rad(rotationDeg or 0)
    if (rotationDeg or 0) % 90 == 0 then
        return math.floor(math.cos(a) + 0.5), math.floor(math.sin(a) + 0.5)
    end
    return math.cos(a), math.sin(a)
end

-- A reshapable element's rotate drag: any whole degree, except that within 3
-- degrees of a cardinal it settles on the cardinal, so getting a tank back to
-- exactly square with the grid doesn't take a steady hand.
function _shapePoly.freeRotationDegrees(angleRad)
    local deg = math.deg(angleRad) % 360
    local cardinal = math.floor(deg / 90 + 0.5) * 90
    if math.abs(deg - cardinal) <= 3 then return cardinal % 360 end
    return math.floor(deg + 0.5) % 360
end

-- Grid-unit coordinates (lx,ly, 0..cols/0..rows) to screen pixels, for a
-- shape centered at cx,cy with grid units cw x ch pixels — and back again.
function _shapePoly.toWorld(cx, cy, cw, ch, p, rotationDeg, lx, ly)
    local cosR, sinR = _shapePoly.cosSin(rotationDeg)
    local dx, dy = (lx - p.cols / 2) * cw, (ly - p.rows / 2) * ch
    return cx + dx * cosR - dy * sinR, cy + dx * sinR + dy * cosR
end

function _shapePoly.toLocal(cx, cy, cw, ch, p, rotationDeg, x, y)
    local cosR, sinR = _shapePoly.cosSin(rotationDeg)
    local dx, dy = x - cx, y - cy
    return (dx * cosR + dy * sinR) / cw + p.cols / 2, (-dx * sinR + dy * cosR) / ch + p.rows / 2
end

-- An element's live frame: center, grid unit size in pixels, and parsed shape.
function _shapePoly.frame(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    local p = _shapePoly.parse(_shapePoly.pointsOf(canvas, e))
    return ex + ew / 2, ey + eh / 2, ew / p.cols, eh / p.rows, p
end

function _shapePoly.containsPoint(canvas, e, x, y)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    return _shapePoly.containsLocal(p, _shapePoly.toLocal(cx, cy, cw, ch, p, e.rotation, x, y))
end

-- Calls fn(centerX, centerY, halfX, halfY) with screen-axis-aligned boxes that
-- together cover the shape, stopping at and returning whatever fn first returns
-- truthy. Each row span is one exact box at a cardinal turn; at any other angle
-- each grid square gets its own enclosing box, which stays much tighter around
-- the shape than one enclosing a long diagonal span would.
function _shapePoly.eachSpanBox(p, cx, cy, cw, ch, rotationDeg, fn)
    local perCell = (rotationDeg or 0) % 90 ~= 0
    for _, run in ipairs(p.runs) do
        local c0 = run.c0
        while c0 < run.c1 do
            local c1 = perCell and (c0 + 1) or run.c1
            local minX, maxX, minY, maxY
            for _, vertex in ipairs({ { c0, run.r }, { c1, run.r }, { c0, run.r + 1 }, { c1, run.r + 1 } }) do
                local x, y = _shapePoly.toWorld(cx, cy, cw, ch, p, rotationDeg, vertex[1], vertex[2])
                minX, maxX = math.min(minX or x, x), math.max(maxX or x, x)
                minY, maxY = math.min(minY or y, y), math.max(maxY or y, y)
            end
            local hit, extra = fn((minX + maxX) / 2, (minY + maxY) / 2, (maxX - minX) / 2, (maxY - minY) / 2)
            if hit then return hit, extra end
            c0 = c1
        end
    end
    return false
end

-- Where a wire running along axis ("x"/"y") in direction sign, through the
-- point x,y, should stop on this shape: the outermost point where that line
-- crosses the outline, on the side the wire is arriving from, so a wire whose
-- box center sits in a cut-away notch runs on through the notch to the tank's
-- actual body. Only a rotated shape's line can miss the outline, and then the
-- wire just runs to x,y itself.
function _shapePoly.edgePoint(canvas, e, x, y, axis, sign)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    local lx, ly = _shapePoly.toLocal(cx, cy, cw, ch, p, e.rotation, x, y)
    local cosR, sinR = _shapePoly.cosSin(e.rotation)
    local dirX, dirY = (axis == "x") and sign or 0, (axis == "y") and sign or 0
    local stepC, stepR = (dirX * cosR + dirY * sinR) / cw, (-dirX * sinR + dirY * cosR) / ch
    local best
    for _, edge in ipairs(p.edges) do
        local edgeC, edgeR = edge[3] - edge[1], edge[4] - edge[2]
        local denom = stepC * edgeR - stepR * edgeC
        if denom ~= 0 then
            local toC, toR = edge[1] - lx, edge[2] - ly
            local alongEdge = (toC * stepR - toR * stepC) / denom
            if alongEdge >= 0 and alongEdge <= 1 then
                local t = (toC * edgeR - toR * edgeC) / denom
                if not best or t > best then best = t end
            end
        end
    end
    if not best then return x, y end
    return _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, lx + best * stepC, ly + best * stepR)
end

-- A tank's own corners round off by this fraction of its own smaller
-- on-screen dimension (NOT a fixed/zoom-scaled pixel size -- a constant
-- size grows to swallow a small tank, or exceed half of ANY tank's own
-- width/height at high enough zoom, and the per-corner clamp below then has
-- nowhere left to go but the shape's own half-width/half-height, drawing a
-- stadium or, on a square tank, a flat circle instead of a rounded rect).
-- e.fillPercent ~= nil is the same "this holds a fluid level" signal
-- _drawElement's own drawLevel dispatch already keys off, so only an actual
-- tank-like element (reshaped or still its catalog default rect) gets the
-- rounded look; a plain bus/duct/engine stays sharp-cornered.
_shapePoly.CORNER_RADIUS_FRACTION = 0.1

-- How many straight pieces to approximate an arc of radius r with, fine
-- enough to look smooth at any zoom. Self-contained rather than reusing
-- _pipes.bendSegments (the pipe system's own equivalent) deliberately: this
-- table is built well before _pipes exists as a local at load time (see
-- _drawPipeTreeSymbol's own comment on the same ordering issue).
function _shapePoly.arcSegments(r)
    return math.max(4, math.min(32, math.ceil(r * math.pi / 6)))
end

-- p's own straight-edged outline (see _shapePoly.parse), corner-rounded: a
-- version of the same closed polygon with every vertex replaced by a short
-- arc of radius `radius`, pulled back along each adjacent edge to make room
-- for it (clamped per corner to half the shorter of the two, same rule
-- _pipes.corners uses for a pipe bend -- the two ends of one shared edge
-- can independently clamp to their own corner's radius, so a short edge
-- between two rounded corners just ends up with a shorter, possibly
-- zero-length, straight stretch between their arcs rather than a crowded
-- overlap). In the caller's already centered local pixel space (ew,eh).
-- Returns segs (straight stretches to stroke, {x1,y1,x2,y2} each), arcs
-- (one per corner, keyed by corner index, r == 0 meaning "no room for a
-- curve here, draw it as a corner handled by the straight stretches
-- themselves instead"), and fillPoints -- the same boundary flattened to a
-- {x,y,x,y,...} list (straight endpoints plus sampled arc points) ready for
-- love.math.triangulate, so the fill and the stroke always trace the exact
-- same rounded boundary.
function _shapePoly.roundedOutline(p, ew, eh, radius)
    local cw, ch = ew / p.cols, eh / p.rows
    local left, top = -ew / 2, -eh / 2
    local n = #p.corners
    local function vertex(i)
        local c = p.corners[((i - 1) % n) + 1]
        return left + c.c * cw, top + c.r * ch
    end

    -- Edge lengths, computed once so the per-corner loop below can reuse
    -- them (for its own two adjacent edges) without re-measuring.
    local edgeLen = {}
    for i = 1, n do
        local ax, ay = vertex(i)
        local bx, by = vertex(i + 1)
        edgeLen[i] = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    end

    -- Shortest distance from point (px,py) to the segment (ax,ay)-(bx,by).
    local function pointSegDist(px, py, ax, ay, bx, by)
        local dx, dy = bx - ax, by - ay
        local lenSq = dx * dx + dy * dy
        local t = lenSq > 1e-9 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq)) or 0
        local cx, cy = ax + t * dx, ay + t * dy
        return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
    end

    -- A corner's own two adjacent edges already cap ITS radius (lenA/2,
    -- lenB/2 below), which alone guarantees any two corners sharing a single
    -- edge can't overlap (their radii can sum to at most that edge's own
    -- length). What that doesn't catch is a thin/stretched shape where two
    -- corners that AREN'T adjacent -- opposite sides of a dart, say -- sit
    -- physically close together: each one's own local check passes, but
    -- their arcs can still cross, which love.math.triangulate legitimately
    -- refuses outright (used to fall back silently to the fully sharp-
    -- cornered path below -- see drawLocal's own pcall -- rather than the
    -- crash this exact shape used to cause before a cap existed). Capping
    -- each corner's radius by its OWN clearance -- the closest approach of
    -- its vertex to any edge it isn't already touching -- catches that
    -- directly, is purely a function of this shape's own proportions, and so
    -- (unlike an earlier version of this cap, keyed off a short EDGE
    -- elsewhere in the shape with no particular relation to ew/eh) scales
    -- the exact same way at every zoom level rather than only clearing
    -- love.math.triangulate's okay at some.
    -- Overall winding sign (shoelace), used below to tell a convex corner
    -- from a reflex one -- a corner's own turn direction matching the
    -- shape's dominant winding is convex; opposite is reflex.
    local signedArea = 0
    for i = 1, n do
        local ax, ay = vertex(i)
        local bx, by = vertex(i + 1)
        signedArea = signedArea + (ax * by - bx * ay)
    end

    local arcs = {}
    for i = 1, n do
        local ax, ay = vertex(i - 1)
        local px, py = vertex(i)
        local bx, by = vertex(i + 1)
        local lenA, lenB = edgeLen[((i - 2) % n) + 1], edgeLen[i]
        local adjA, adjB = ((i - 2) % n) + 1, i
        local clearance = math.huge
        for k = 1, n do
            if k ~= adjA and k ~= adjB then
                local eax, eay = vertex(k)
                local ebx, eby = vertex(k + 1)
                local d = pointSegDist(px, py, eax, eay, ebx, eby)
                if d < clearance then clearance = d end
            end
        end
        local farCap = (clearance < math.huge) and (clearance * 0.45) or radius

        local r = 0
        local entryX, entryY, exitX, exitY, cx, cy
        if lenA > 1e-6 and lenB > 1e-6 then
            local d1x, d1y = (px - ax) / lenA, (py - ay) / lenA   -- incoming edge direction
            local d2x, d2y = (bx - px) / lenB, (by - py) / lenB   -- outgoing edge direction
            -- The tangent-point distance along each edge and the center's
            -- distance from the corner both depend on the corner's own
            -- HALF-ANGLE, not just r -- backing up by exactly r (as an
            -- earlier version of this did) only happens to work for an
            -- exact 90deg corner; any other angle produced a center that
            -- wasn't actually equidistant from both edges, i.e. a bogus
            -- "rounded" corner love.math.triangulate was right to refuse
            -- (intermittently, depending on just how bogus a given r made
            -- it) -- which is what made this flip between round and sharp
            -- from one zoom level to the next on the very same tank.
            local v1x, v1y, v2x, v2y = -d1x, -d1y, d2x, d2y
            local dot = math.max(-1, math.min(1, v1x * v2x + v1y * v2y))
            local turnCross = d1x * d2y - d1y * d2x
            local isReflex = turnCross * signedArea < 0
            -- dot near +1: a near-zero-width spike (can't round with a
            -- finite tangent length). dot near -1: a near-straight corner
            -- (no turn to round in the first place; the bisector below is
            -- undefined right at the limit). Either way, and for a reflex
            -- corner (bulges outward, not handled here), leave it sharp
            -- rather than risk a wrong-direction or degenerate arc.
            if not isReflex and dot > -0.999 and dot < 0.999 then
                local half = math.acos(dot) / 2
                -- tangentDist is the distance backed up along each edge; r =
                -- tangentDist*tan(half) and centerDist = tangentDist/cos(half),
                -- so each of the three caps (base radius ceiling, clearance
                -- margin on the CENTER's reach, and the edges' own room)
                -- converts to a tangentDist bound the same way.
                local tangentDist = math.min(lenA / 2, lenB / 2,
                    radius / math.tan(half), farCap * math.cos(half))
                local centerDist = tangentDist / math.cos(half)
                local bx2, by2 = v1x + v2x, v1y + v2y
                local blen = math.sqrt(bx2 * bx2 + by2 * by2)
                if tangentDist > 0.25 and blen > 1e-6 then
                    local bux, buy = bx2 / blen, by2 / blen
                    r = tangentDist * math.tan(half)
                    entryX, entryY = px - d1x * tangentDist, py - d1y * tangentDist
                    exitX, exitY = px + d2x * tangentDist, py + d2y * tangentDist
                    cx, cy = px + bux * centerDist, py + buy * centerDist
                end
            end
        end
        if r > 0.25 then
            local a1 = math.atan2(entryY - cy, entryX - cx)
            local a2 = math.atan2(exitY - cy, exitX - cx)
            local sweep = a2 - a1
            if sweep > math.pi then sweep = sweep - 2 * math.pi elseif sweep < -math.pi then sweep = sweep + 2 * math.pi end
            arcs[i] = { cx = cx, cy = cy, r = r, a1 = a1, a2 = a1 + sweep,
                px = px, py = py, entryX = entryX, entryY = entryY, exitX = exitX, exitY = exitY }
        else
            arcs[i] = { r = 0, px = px, py = py, entryX = px, entryY = py, exitX = px, exitY = py }
        end
    end

    -- Straight stretches to stroke for the OUTLINE between one corner's own
    -- arc and the next's (see drawLocal -- the fill no longer needs these:
    -- it's carved out of the plain sharp polygon with a stencil instead of
    -- built as one big custom polygon, so there's no fillPoints list here
    -- any more).
    local segs = {}
    for i = 1, n do
        local prev = arcs[((i - 2) % n) + 1]
        local cur = arcs[i]
        if math.abs(prev.exitX - cur.entryX) > 0.1 or math.abs(prev.exitY - cur.entryY) > 0.1 then
            segs[#segs + 1] = { prev.exitX, prev.exitY, cur.entryX, cur.entryY }
        end
    end
    return segs, arcs
end

-- Filled body and white outline, in the caller's already centered+rotated
-- space; r,g,b,a is the fill, outlineAlpha the outline (0 for a glow halo).
-- ew,eh already reflect the current zoom (same pixel box every other shape
-- in this file draws into), so a tank's rounded corners (see
-- CORNER_RADIUS_FRACTION above) scale with it automatically, with no zoom
-- parameter of its own needed.
function _shapePoly.drawLocal(e, ew, eh, r, g, b, a, outlineAlpha)
    local p = _shapePoly.parse(e.shapePoints)
    local radius = (e.fillPercent ~= nil) and (math.min(ew, eh) * _shapePoly.CORNER_RADIUS_FRACTION) or 0
    local cw, ch = ew / p.cols, eh / p.rows
    local left, top = -ew / 2, -eh / 2
    local function fillSharpBody()
        for _, t in ipairs(p.triangles) do
            love.graphics.polygon("fill", left + t[1] * cw, top + t[2] * ch, left + t[3] * cw, top + t[4] * ch,
                left + t[5] * cw, top + t[6] * ch)
        end
    end

    if radius <= 0.25 then
        love.graphics.setColor(r, g, b, a)
        fillSharpBody()
        love.graphics.setColor(1, 1, 1, outlineAlpha)
        _shapePoly.strokeEdges(p, ew, eh)
        return
    end

    -- Rounded corners are carved out of the plain sharp fill with a stencil
    -- rather than built as one big custom polygon and handed to
    -- love.math.triangulate -- an earlier version did that, and triangulate
    -- turned out to reject it almost arbitrarily (small floating-point
    -- differences between near-collinear arc-sampled points flipping it
    -- between accepting and refusing the exact same shape), which is what
    -- made corners round at one zoom level and sharp at the next on the very
    -- same tank. Every primitive used here instead -- p.triangles (already
    -- validated once, at parse time), a plain 3-point corner triangle, and
    -- an arc "fill" "pie" slice -- is one the GPU rasterizes directly, with
    -- no polygon validity question to get a different answer on.
    local segs, arcs = _shapePoly.roundedOutline(p, ew, eh, radius)
    love.graphics.stencil(fillSharpBody, "replace", 1)
    for _, arc in ipairs(arcs) do
        if arc.r > 0 then
            love.graphics.stencil(function()
                love.graphics.polygon("fill", arc.px, arc.py, arc.entryX, arc.entryY, arc.exitX, arc.exitY)
            end, "replace", 0)
            love.graphics.stencil(function()
                love.graphics.arc("fill", "pie", arc.cx, arc.cy, arc.r, arc.a1, arc.a2, _shapePoly.arcSegments(arc.r))
            end, "replace", 1)
        end
    end
    love.graphics.setStencilTest("gequal", 1)
    love.graphics.setColor(r, g, b, a)
    fillSharpBody()
    love.graphics.setStencilTest()

    love.graphics.setColor(1, 1, 1, outlineAlpha)
    for _, seg in ipairs(segs) do love.graphics.line(seg[1], seg[2], seg[3], seg[4]) end
    for _, arc in ipairs(arcs) do
        if arc.r > 0 then
            love.graphics.arc("line", "open", arc.cx, arc.cy, arc.r, arc.a1, arc.a2, _shapePoly.arcSegments(arc.r))
        end
    end
end

function _shapePoly.strokeEdges(p, ew, eh)
    local cw, ch = ew / p.cols, eh / p.rows
    for _, edge in ipairs(p.edges) do
        love.graphics.line(-ew / 2 + edge[1] * cw, -eh / 2 + edge[2] * ch, -ew / 2 + edge[3] * cw, -eh / 2 + edge[4] * ch)
    end
end

-- The selection/collision outline: the shape's real boundary, in whatever
-- color the caller has set — the shaped counterpart of _drawElement's plain
-- footprint rectangle.
function _shapePoly.strokeOutline(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    love.graphics.push()
    love.graphics.translate(ex + ew / 2, ey + eh / 2)
    love.graphics.rotate(math.rad(e.rotation or 0))
    _shapePoly.strokeEdges(_shapePoly.parse(e.shapePoints), ew, eh)
    love.graphics.pop()
end

-- The screen height of an element's fill line (e.fillPercent, set by the app; nil
-- is full): 100% at the shape's topmost point on screen, 0% at its bottommost,
-- however the element is turned, the way liquid settles.
function _shapePoly.levelLineY(canvas, e)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    local minY, maxY
    for _, corner in ipairs(p.corners) do
        local _, y = _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, corner.c, corner.r)
        minY, maxY = math.min(minY or y, y), math.max(maxY or y, y)
    end
    return maxY - (maxY - minY) * e.fillPercent / 100, maxY
end

_shapePoly.WAVE_AMPLITUDE_PX = 0.6 -- how far the fluid's top surface rises/dips, screen px at zoom 1
_shapePoly.WAVE_CYCLES = 1.8       -- how many full up/down cycles span the tank's own on-screen width
_shapePoly.WAVE_SPEED = 0.5        -- cycles/second the ripple travels sideways
_shapePoly.WAVE_SAMPLES = 28       -- points sampled along the curve -- the mask polygon's own
                                     -- smoothness, not a strip count, since the edge it cuts is an
                                     -- exact curve rather than an approximation of one.
_shapePoly.WAVE_TAPER_PERCENT = 6  -- fillPercent span, right at 100, over which the ripple damps to
                                     -- flat -- a brimming tank has no headspace left to slosh in.

-- Draws an element's whole body dimmed, then again in full color below its fill
-- line, by way of drawBody(r, g, b, a). Always top-of-tank-to-bottom oriented
-- (the fill line runs level on screen, however the element itself is turned),
-- regardless of the tank's own port locations or count. The line's own top
-- edge ripples side to side instead of sitting dead flat, as a fluid-movement
-- cue: a real sine curve, sampled into a polygon and used as a stencil mask
-- for a SINGLE drawBody call. Two earlier versions got tried and dropped:
-- thin vertical scissor strips (plain intersectScissor is screen-axis-aligned
-- rectangles only, so a single call can't bend into a curve) approximated the
-- wave as a staircase AND, on a non-rectangular tank (a triangle tapering to
-- a point), chopped the shape's own diagonal edge into visible steps too --
-- repeatedly re-rasterizing it against each strip's hard rectangular cut,
-- rather than once, whole, the way a single mask leaves it. A line stroked
-- along the curve on top of that fixed the stepping but, drawn across the
-- element's full bounding-box width with no shape awareness, overshot past
-- the same triangle's slanted sides. A stencil mask has neither problem: it
-- clips the one drawBody call to the exact curve, so the shape's own edges
-- rasterize normally and only the fill boundary follows the wave. Safe to use
-- a stencil here because gdsGui_schematic_draw runs after gdsGui_container_draw
-- has already finished and disabled its own rounded-card stencil test (see
-- _setRoundedStencil in container_gdsGuiLib.lua) -- nothing else has a stencil
-- test active while this runs, and every Canvas that can be the active render
-- target here (_glow.canvasA/B, _menuBackdrop.full) is created with
-- stencil=true for exactly this. The mask is erased right after use so no
-- leftover stencil value can bleed into another element's draw this frame.
function _shapePoly.drawLevel(canvas, e, drawBody, r, g, b, a)
    local shade = _shapePoly.EMPTY_SHADE
    drawBody(r * shade, g * shade, b * shade, a)
    if e.fillPercent <= 0 then return end
    local lineY, maxY = _shapePoly.levelLineY(canvas, e)
    local ex, _, ew = _elementPixelRect(canvas, e)
    -- Everything below is in screen space, which ignores the transform, so the
    -- line and bottom go through it: a lifted tank (see _selection.beginLift)
    -- draws scaled, and its level/ripple must scale with it.
    local screenX1 = love.graphics.transformPoint(ex, lineY)
    local screenX2 = love.graphics.transformPoint(ex + ew, lineY)
    local left, right = math.min(screenX1, screenX2), math.max(screenX1, screenX2)
    local _, screenLineY = love.graphics.transformPoint(0, lineY)
    local _, screenMaxY = love.graphics.transformPoint(0, maxY)
    local bottom = math.ceil(screenMaxY) + 1
    local taper = math.min(1, (100 - e.fillPercent) / _shapePoly.WAVE_TAPER_PERCENT)
    local amp = _shapePoly.WAVE_AMPLITUDE_PX * canvas.zoom * taper
    local now = _selection.now()

    local points = {}
    for s = 0, _shapePoly.WAVE_SAMPLES do
        local t = s / _shapePoly.WAVE_SAMPLES
        local phase = t * _shapePoly.WAVE_CYCLES * math.pi * 2 + now * _shapePoly.WAVE_SPEED
        table.insert(points, left + (right - left) * t)
        table.insert(points, screenLineY + amp * math.sin(phase))
    end
    table.insert(points, right)
    table.insert(points, bottom)
    table.insert(points, left)
    table.insert(points, bottom)
    local maskTop = math.floor(screenLineY - amp) - 1

    love.graphics.stencil(function() love.graphics.polygon("fill", points) end, "replace", 1)
    love.graphics.setStencilTest("gequal", 1)
    drawBody(r, g, b, a)
    love.graphics.setStencilTest()
    love.graphics.stencil(function()
        love.graphics.rectangle("fill", left, maskTop, right - left, bottom - maskTop)
    end, "replace", 0)
end

-- Reshape-mode affordance: a square handle on every draggable corner.
function _shapePoly.drawHandles(canvas, e)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    local half = math.max(3, 0.7 * canvas.zoom)
    love.graphics.setColor(1, 0, 1, 1)
    for _, corner in ipairs(p.corners) do
        local x, y = _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, corner.c, corner.r)
        love.graphics.rectangle("fill", x - half, y - half, half * 2, half * 2)
    end
end

-- What a press grabbed, as the corner's index in p.corners plus isSide (the
-- index then names the side running from that corner to the next), or nil.
-- Nearest corner first. The middle third of a side is the exception: on a tank
-- small enough on screen for its corners' reach to cover every side whole, that
-- stretch still has to be able to grab the side.
function _shapePoly.handleAt(canvas, e, x, y)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    local corner, cornerDist = nil, _shapePoly.HANDLE_HIT_PX
    local side, sideDist, sideIsMiddle = nil, _shapePoly.HANDLE_HIT_PX, false
    for i, edge in ipairs(p.edges) do
        local x1, y1 = _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, edge[1], edge[2])
        local x2, y2 = _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, edge[3], edge[4])
        local dist = math.sqrt((x1 - x) ^ 2 + (y1 - y) ^ 2)
        if dist <= cornerDist then corner, cornerDist = i, dist end
        local segX, segY = x2 - x1, y2 - y1
        local t = math.max(0, math.min(1, ((x - x1) * segX + (y - y1) * segY) / (segX * segX + segY * segY)))
        dist = math.sqrt((x1 + t * segX - x) ^ 2 + (y1 + t * segY - y) ^ 2)
        if dist <= sideDist then side, sideDist, sideIsMiddle = i, dist, t >= 1 / 3 and t <= 2 / 3 end
    end
    if corner and not (side and sideIsMiddle and sideDist < cornerDist) then return corner, false end
    if side then return side, true end
    return nil
end

function _shapePoly.beginDrag(canvas, e, index, isSide)
    canvas._shapeDrag = {
        index = index, isSide = isSide, points = _shapePoly.pointsOf(canvas, e), originalPoints = e.shapePoints,
        x = e.x, y = e.y, w = e.w, h = e.h, ports = e.terminals,
    }
end

-- The corner list a drag offset by whole grid units (dc,dr) produces: a grabbed
-- corner moves that far, and a grabbed side gains a new corner that far from
-- the exact center of the side. Moving by whole units from where it started
-- keeps that new corner dead center on an odd-length side pulled straight out.
function _shapePoly.candidatePoints(p, drag, dc, dr)
    local points = {}
    for i, corner in ipairs(p.corners) do
        local moved = i == drag.index and not drag.isSide
        table.insert(points, moved and corner.c + dc or corner.c)
        table.insert(points, moved and corner.r + dr or corner.r)
        if i == drag.index and drag.isSide then
            local nextCorner = p.corners[i % #p.corners + 1]
            table.insert(points, (corner.c + nextCorner.c) / 2 + dc)
            table.insert(points, (corner.r + nextCorner.r) / 2 + dr)
        end
    end
    return points
end

-- Which way c,r turns relative to the line from a to b: the sign is the side, 0 is on it.
function _shapePoly.turn(ac, ar, bc, br, c, r)
    return (bc - ac) * (r - ar) - (br - ar) * (c - ac)
end

-- Whether two segments share any point at all, a mere touch included.
function _shapePoly.segmentsTouch(a, b)
    local function within(s, c, r)
        return c >= math.min(s[1], s[3]) and c <= math.max(s[1], s[3]) and r >= math.min(s[2], s[4]) and r <= math.max(s[2], s[4])
    end
    local turn = _shapePoly.turn
    local t1, t2 = turn(b[1], b[2], b[3], b[4], a[1], a[2]), turn(b[1], b[2], b[3], b[4], a[3], a[4])
    local t3, t4 = turn(a[1], a[2], a[3], a[4], b[1], b[2]), turn(a[1], a[2], a[3], a[4], b[3], b[4])
    if ((t1 > 0) ~= (t2 > 0)) and ((t3 > 0) ~= (t4 > 0)) and t1 ~= 0 and t2 ~= 0 and t3 ~= 0 and t4 ~= 0 then return true end
    return (t1 == 0 and within(b, a[1], a[2])) or (t2 == 0 and within(b, a[3], a[4])) or
           (t3 == 0 and within(a, b[1], b[2])) or (t4 == 0 and within(a, b[3], b[4]))
end

-- A corner list as finished shapePoints plus its box's min corner, or nil if
-- it isn't a real polygon: a corner dragged flat onto the line between its
-- neighbors (or onto a neighbor) simply stops being a corner, while an outline
-- left with no area, or crossing or touching itself, is rejected.
function _shapePoly.encode(points)
    local corners = {}
    for i = 1, #points, 2 do table.insert(corners, { points[i], points[i + 1] }) end
    local i = 1
    while i <= #corners and #corners >= 3 do
        local a, b, c = corners[(i - 2) % #corners + 1], corners[i], corners[i % #corners + 1]
        if _shapePoly.turn(a[1], a[2], b[1], b[2], c[1], c[2]) == 0 then
            table.remove(corners, i)
            i = 1
        else
            i = i + 1
        end
    end
    local n = #corners
    if n < 3 then return nil end
    local minC, minR = corners[1][1], corners[1][2]
    local segments = {}
    for j, corner in ipairs(corners) do
        minC, minR = math.min(minC, corner[1]), math.min(minR, corner[2])
        local nextCorner = corners[j % n + 1]
        segments[j] = { corner[1], corner[2], nextCorner[1], nextCorner[2] }
    end
    for j = 1, n do
        for k = j + 2, n do
            -- Neighboring sides share their corner by definition.
            if not (j == 1 and k == n) and _shapePoly.segmentsTouch(segments[j], segments[k]) then return nil end
        end
    end
    local result = {}
    for _, corner in ipairs(corners) do
        table.insert(result, corner[1] - minC)
        table.insert(result, corner[2] - minR)
    end
    return result, minC, minR
end

-- True if a candidate footprint (cx,cy = pixel-space center, halfX,halfY =
-- pixel-space half-extents) would overlap any EXISTING element or control
-- other than excludeId (the one actually being placed/dragged, if it
-- already exists on the canvas — nil for a brand-new placement, nothing
-- to exclude). Wires are completely exempt from this — only elements and
-- controls (see gdsGui_schematic_pressed's pendingPlacement branch and
-- _moved's "element"/"control" dragKinds, the only two callers) can never
-- sit on top of each other; two+ WIRES sharing the same path are exactly
-- what the "twisted bundle" draws (see _computeWirePlans), a deliberate
-- opposite rule for a completely different kind of entity. Every shape (a
-- control's circle included) is checked as its own axis-aligned bounding
-- box — simpler than a true circle-vs-rect test, and only ever more
-- conservative (a control placed exactly diagonal to another, just
-- outside true circle-to-circle contact, could still be flagged here),
-- never less safe. bufferPx pads every comparison by one full grid unit
-- (world-space, so it scales with zoom like everything else here — see
-- _GRID_SPACING_PX) so two boxes can never even land flush against each
-- other, only ever a grid unit or more apart. Second return value is the
-- actual obstacle (an entry from canvas.elements or canvas.controls) hit,
-- nil when there's no overlap — callers that only care about the boolean
-- (most of them) simply ignore it; gdsGui_schematic_moved's element/control
-- drag branches use it to flag which obstacle to highlight red (see
-- canvas.collidingObstacleId / _drawElement/_drawControl).
local function _footprintOverlapsAnother(canvas, cx, cy, halfX, halfY, excludeId)
    local bufferPx = 1 * _GRID_SPACING_PX * canvas.zoom -- 1 grid unit of required gap
    for _, e in ipairs(canvas.elements) do
        if e.id ~= excludeId and e.shapePoints then
            -- A shaped element only blocks where its outline actually reaches, so
            -- something can sit in a notch cut out of it.
            local ecx, ecy, cw, ch, p = _shapePoly.frame(canvas, e)
            local hit = _shapePoly.eachSpanBox(p, ecx, ecy, cw, ch, e.rotation, function(sx, sy, sHalfX, sHalfY)
                return math.abs(cx - sx) < halfX + sHalfX + bufferPx and math.abs(cy - sy) < halfY + sHalfY + bufferPx
            end)
            if hit then return true, e end
        elseif e.id ~= excludeId then
            local ex, ey, ew, eh = _elementFootprintRect(canvas, e)
            local ecx, ecy, ehalfX, ehalfY = ex + ew / 2, ey + eh / 2, ew / 2, eh / 2
            if math.abs(cx - ecx) < halfX + ehalfX + bufferPx and math.abs(cy - ecy) < halfY + ehalfY + bufferPx then
                return true, e
            end
        end
    end
    for _, c in ipairs(canvas.controls) do
        if c.id ~= excludeId and not c.hidden then
            local ccx, ccy = _toPixel(canvas, c.x, c.y)
            local crad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
            if math.abs(cx - ccx) < halfX + crad + bufferPx and math.abs(cy - ccy) < halfY + crad + bufferPx then
                return true, c
            end
        end
    end
    return false
end

-- The same check for a shaped element about to sit at center cx,cy with grid units
-- cw x ch pixels: each of its row spans is its own candidate footprint.
function _shapePoly.blockedAt(canvas, elem, p, cx, cy, cw, ch, rotationDeg)
    return _shapePoly.eachSpanBox(p, cx, cy, cw, ch, rotationDeg, function(sx, sy, sHalfX, sHalfY)
        return _footprintOverlapsAnother(canvas, sx, sy, sHalfX, sHalfY, elem.id)
    end)
end

-- Applies the current finger position to an in-progress corner/side drag.
-- Always recomputed from the shape the press started on (canvas._shapeDrag), so
-- dragging back undoes the change live; a result that crosses itself, off the
-- canvas, or on top of a neighbor simply isn't applied — same "stops at the
-- obstacle" feel as a move drag. Nothing applies until the press has become a
-- real drag, so a tap's finger jitter can't nudge a corner or sprout a new one.
-- Returns true once e differs from that start.
function _shapePoly.updateDrag(canvas, e, x, y)
    local drag = canvas._shapeDrag
    if not drag.started then
        if math.abs(x - canvas.dragStartX) <= _ELEMENT_TAP_SLOP_PX and math.abs(y - canvas.dragStartY) <= _ELEMENT_TAP_SLOP_PX then
            return false
        end
        drag.started = true
    end
    local p = _shapePoly.parse(drag.points)
    local bx, by = _toPixel(canvas, drag.x, drag.y)
    local bw, bh = drag.w * canvas.contentW * canvas.zoom, drag.h * canvas.contentH * canvas.zoom
    local bcx, bcy, cw, ch = bx + bw / 2, by + bh / 2, bw / p.cols, bh / p.rows
    local lx, ly = _shapePoly.toLocal(bcx, bcy, cw, ch, p, e.rotation, x, y)
    local startX, startY = _shapePoly.toLocal(bcx, bcy, cw, ch, p, e.rotation, canvas.dragStartX, canvas.dragStartY)
    local dc, dr = math.floor(lx - startX + 0.5), math.floor(ly - startY + 0.5)
    local points, minC, minR = _shapePoly.encode(_shapePoly.candidatePoints(p, drag, dc, dr))
    canvas.collidingObstacleId = nil
    if not points then return false end
    if table.concat(points, ",") == table.concat(drag.points, ",") then
        e.shapePoints, e.x, e.y, e.w, e.h = drag.originalPoints, drag.x, drag.y, drag.w, drag.h
        e.terminals = drag.ports
        return false
    end
    local np = _shapePoly.parse(points)
    -- Where the new box's center lands, keeping every surviving corner exactly
    -- where it already was on screen.
    local ncx, ncy = _shapePoly.toWorld(bcx, bcy, cw, ch, p, e.rotation, minC + np.cols / 2, minR + np.rows / 2)
    local cosR, sinR = _shapePoly.cosSin(e.rotation)
    cosR, sinR = math.abs(cosR), math.abs(sinR)
    local newW, newH = np.cols * cw, np.rows * ch
    local halfX, halfY = (newW * cosR + newH * sinR) / 2, (newW * sinR + newH * cosR) / 2
    local baseHalfX, baseHalfY = (bw * cosR + bh * sinR) / 2, (bw * sinR + bh * cosR) / 2
    -- Canvas bounds, world-space. A tank already poking past an edge (only
    -- its center is ever clamped — see _snapToGrid) can still be edited.
    local originX, originY = _toPixel(canvas, 0, 0)
    local maxX, maxY = _toPixel(canvas, 1, 1)
    if ncx - halfX < math.min(originX, bcx - baseHalfX) - 0.001 or ncx + halfX > math.max(maxX, bcx + baseHalfX) + 0.001 or
       ncy - halfY < math.min(originY, bcy - baseHalfY) - 0.001 or ncy + halfY > math.max(maxY, bcy + baseHalfY) + 0.001 then
        return false
    end
    local blocked, obstacle = _shapePoly.blockedAt(canvas, e, np, ncx, ncy, cw, ch, e.rotation)
    if blocked then
        canvas.collidingObstacleId = obstacle and obstacle.id or nil
        return false
    end
    local fracW, fracH = np.cols * drag.w / p.cols, np.rows * drag.h / p.rows
    local cfx, cfy = _toFraction(canvas, ncx, ncy)
    e.shapePoints, e.w, e.h = points, fracW, fracH
    e.x, e.y = cfx - fracW / 2, cfy - fracH / 2
    e.terminals = _shapePoly.reseatPorts(drag.ports, p, np, minC, minR)
    return true
end

-- The bounding-box-relative corners of e's left-right mirror image. Paired with
-- the opposite rotation (see openMirror), that's the true mirror of e as it
-- actually sits on the canvas.
function _shapePoly.mirroredPoints(canvas, e)
    local points = _shapePoly.pointsOf(canvas, e)
    local p = _shapePoly.parse(points)
    local mirrored = {}
    for i = 1, #points, 2 do
        mirrored[i], mirrored[i + 1] = p.cols - points[i], points[i + 1]
    end
    return mirrored
end

-- The nearest clear on-canvas spot (top-left fractions) for a shape of size
-- wFrac x hFrac, searching outward one grid unit at a time from centerX,centerY,
-- along the row first. Only X snaps to the grid: a reshaped tank's center can sit
-- off it, and its twin should still line up level with it. nil if there's no room.
function _shapePoly.findClearSpot(canvas, p, rotationDeg, centerX, centerY, wFrac, hFrac)
    local startX = _snapElementToGrid(canvas, centerX - wFrac / 2, centerY - hFrac / 2, wFrac, hFrac)
    local startY = centerY - hFrac / 2
    local stepX, stepY = _GRID_SPACING_PX / canvas.contentW, _GRID_SPACING_PX / canvas.contentH
    local cosR, sinR = _shapePoly.cosSin(rotationDeg)
    cosR, sinR = math.abs(cosR), math.abs(sinR)
    local bw, bh = wFrac * canvas.contentW * canvas.zoom, hFrac * canvas.contentH * canvas.zoom
    local halfX, halfY = (bw * cosR + bh * sinR) / 2, (bw * sinR + bh * cosR) / 2
    local originX, originY = _toPixel(canvas, 0, 0)
    local maxX, maxY = _toPixel(canvas, 1, 1)
    local function isClear(dx, dy)
        local px, py = _toPixel(canvas, startX + dx * stepX, startY + dy * stepY)
        local cx, cy = px + bw / 2, py + bh / 2
        return cx - halfX >= originX - 0.001 and cx + halfX <= maxX + 0.001 and
               cy - halfY >= originY - 0.001 and cy + halfY <= maxY + 0.001 and
               not _shapePoly.blockedAt(canvas, {}, p, cx, cy, bw / p.cols, bh / p.rows, rotationDeg)
    end
    local maxRing = math.ceil(math.max(1 / stepX, 1 / stepY))
    for ring = 0, maxRing do
        for i = 0, 2 * ring do
            local dy = (i % 2 == 1) and (i + 1) / 2 or -i / 2
            -- The ring's outline only: every column on its top and bottom
            -- rows, just the two end columns on the rows between.
            local stride = (math.abs(dy) == ring) and 1 or 2 * ring
            for dx = -ring, ring, stride do
                if isClear(dx, dy) then return startX + dx * stepX, startY + dy * stepY end
            end
        end
    end
    return nil
end

-- The edit menu's MIRROR option: asks for the new tank's NAME and properties
-- through the same grid placing one from the catalog does, then creates it with
-- e's outline flipped left-right. It lands across the canvas's vertical
-- centerline from e, which is the matching wing on a symmetric aircraft, or the
-- nearest clear spot to that if something's already there.
function _shapePoly.openMirror(canvasName, canvas, e)
    local points = _shapePoly.mirroredPoints(canvas, e)
    local rotation = -(e.rotation or 0) % 360
    local fracX, fracY = _shapePoly.findClearSpot(canvas, _shapePoly.parse(points), rotation,
        1 - (e.x + e.w / 2), e.y + e.h / 2, e.w, e.h)
    if not fracX then
        gdsGui_haptics_feedback("error")
        gdsGui_schematic_openMenu(canvasName, "NO ROOM ON THE CANVAS FOR A MIRRORED TANK.", {"OK"},
            "gdsGui_schematic_internal_onPlacementOverlapDismissed", nil)
        return
    end
    local propertyKeys = {}
    for _, property in ipairs(e.properties or {}) do table.insert(propertyKeys, property.key) end
    canvas._placementCounter = canvas._placementCounter + 1
    _openElementPlacementGrid(canvasName, {
        canvasName = canvasName, kind = "element", shapeType = e.shapeType, componentType = e.componentType,
        newId = (e.id:gsub("_%d+$", "")) .. "_" .. canvas._placementCounter,
        label = ((e.label or e.id):gsub("_%d+$", "")),
        header = "MIRROR OF " .. (e.label or e.id),
        fracX = fracX, fracY = fracY, wFrac = e.w, hFrac = e.h, rotation = rotation, shapePoints = points,
        terminals = _shapePoly.mirroredPorts(e.terminals),
        defaultColor = _deepCopy(e.defaultColor), defaultPropertyKeys = propertyKeys,
    })
end

-- Wire-terminal helpers for a control with its own `terminals` list (see
-- gdsGui_schematic_addControl), e.g. a DPST switch's 4 lugs — one table of
-- functions, defined just below _hitControl (and _terminals.segments after
-- _clampedOrthogonalSegments), to stay under this file's 200-local ceiling.
local _terminals = {}
-- The CHOICE GRID modal form's helpers (see gdsGui_schematic_openChoiceGrid).
local _choiceGrid = {}
-- The PROPERTY GRID modal form's helpers (see gdsGui_schematic_openPropertyGrid).
-- Global, not local like _choiceGrid above — this file is already at Lua's
-- 200-top-level-local ceiling (same constraint main.lua's own comments on
-- _openFundamentalsMenu describe).
_propertyGrid = {}
-- The powered-glow helpers (see gdsGui_schematic_setGlow).
local _glow = {}
-- The pipe-connector helpers (see gdsGui_schematic_setPipeConnectors).
local _pipes = {}

-- Pivot point for the "spin to set direction" drag on an already-selected
-- wire — the midpoint between its two ends (anchor centers, or the
-- terminals it's attached to), mirroring how an element's own center is
-- the pivot for its rotate drag (see gdsGui_schematic_pressed/_moved's
-- "rotate"/"wireDirection" dragKinds).
local function _wireMidpoint(canvas, wire)
    local fromA, toA = _findAnchor(canvas, wire.fromElementId), _findAnchor(canvas, wire.toElementId)
    if not fromA or not toA then return nil end
    local x1, y1 = _terminals.wireEnd(canvas, fromA, wire.fromTerminal)
    local x2, y2 = _terminals.wireEnd(canvas, toA, wire.toTerminal)
    return (x1 + x2) / 2, (y1 + y2) / 2
end

-- Topmost element whose pixel bounding box contains the point (last-added wins).
local function _hitElement(canvas, px, py)
    for i = #canvas.elements, 1, -1 do
        local e = canvas.elements[i]
        local ex, ey, ew, eh = _elementFootprintRect(canvas, e)
        if px >= ex and px <= ex + ew and py >= ey and py <= ey + eh
           and (not e.shapePoints or _shapePoly.containsPoint(canvas, e, px, py)) then
            return e
        end
    end
    return nil
end

-- A control with terminals hit-tests its whole square icon box, not just
-- the inscribed circle — its terminals sit out in the box's corners (a
-- DPST's lugs), exactly where a wire is meant to be started/dropped.
local function _hitControl(canvas, px, py)
    for i = #canvas.controls, 1, -1 do
        local c = canvas.controls[i]
        local rad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
        local cx, cy = _toPixel(canvas, c.x, c.y)
        local dx, dy = px - cx, py - cy
        if c.hidden then
            -- not on the canvas at all (see addControl's hidden note)
        elseif c.terminals then
            if math.abs(dx) <= rad and math.abs(dy) <= rad then return c end
        elseif (dx * dx + dy * dy) <= (rad * rad) then
            return c
        end
    end
    return nil
end

-- Pixel position of terminal `index` on `anchor` (offset from its center
-- as a fraction of its icon box — a control's square, an element's own
-- unrotated w/h box — spun with its own rotation the same way its sprite
-- is), plus the screen axis ("h" or "v") a wire leaves that terminal along
-- — the terminal's own exitX/exitY, rotated. nil when the anchor has no
-- such terminal.
function _terminals.point(canvas, anchor, index)
    local t = anchor.terminals and anchor.terminals[index]
    if not t then return nil end
    local cx, cy, boxW, boxH
    if anchor.w then
        local _, _, ew, eh = _elementPixelRect(canvas, anchor)
        cx, cy = _elementCenter(canvas, anchor)
        boxW, boxH = ew, eh
    else
        cx, cy = _toPixel(canvas, anchor.x, anchor.y)
        boxW = canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1) * 2
        boxH = boxW
    end
    local rot = math.rad(anchor.rotation or 0)
    local cosR, sinR = math.cos(rot), math.sin(rot)
    local ox, oy = t.x * boxW, t.y * boxH
    local ex, ey = t.exitX or 0, t.exitY or 0
    local rex, rey = ex * cosR - ey * sinR, ex * sinR + ey * cosR
    return cx + ox * cosR - oy * sinR, cy + ox * sinR + oy * cosR,
        (math.abs(rex) > math.abs(rey)) and "h" or "v"
end

-- Index of anchor's terminal nearest the pixel point — how a wire picks
-- which terminal it attaches to: whichever one the user drags/drops it
-- closest to. nil for an anchor without terminals.
function _terminals.nearest(canvas, anchor, px, py)
    if not anchor.terminals then return nil end
    local best, bestDistSq
    for i in ipairs(anchor.terminals) do
        local tx, ty = _terminals.point(canvas, anchor, i)
        local distSq = (tx - px) * (tx - px) + (ty - py) * (ty - py)
        if not bestDistSq or distSq < bestDistSq then best, bestDistSq = i, distSq end
    end
    return best
end

-- Where one end of a wire meets its anchor: x, y, the anchor to clamp the
-- wire to (see _anchorEdgePoint), and the exit axis. A terminal end is the
-- terminal's own point with nothing to clamp to (the wire meets the lug
-- itself, not the icon's edge); any other end is the anchor's center,
-- clamped as usual, with no exit axis of its own.
function _terminals.wireEnd(canvas, anchor, terminalIndex)
    if terminalIndex and anchor.terminals and anchor.terminals[terminalIndex] then
        local x, y, axis = _terminals.point(canvas, anchor, terminalIndex)
        return x, y, nil, axis
    end
    local x, y = _anchorCenter(canvas, anchor)
    return x, y, anchor, nil
end

-- What to call terminal `index` on screen while picking a port: its own `name`,
-- else what its role says. Beside a suction port (an ejector's), an inlet is the
-- motive port and an outlet the discharge; a port with no direction (a tank's)
-- is numbered.
function _terminals.label(anchor, index)
    local t = anchor.terminals[index]
    if t.name then return t.name end
    if t.suction then return "SUCTION" end
    local hasSuction = false
    for _, other in ipairs(anchor.terminals) do
        if other.suction then hasSuction = true end
    end
    if t.flow == "in" then return hasSuction and "MOTIVE" or "IN" end
    if t.flow == "out" then return hasSuction and "DISCHARGE" or "OUT" end
    return "PORT " .. index
end

-- The terminal of anchor a tap at the pixel point picks: the nearest, if the
-- tap is within PORT_TAP_SLOP_PX of it. nil otherwise.
function _terminals.pickAt(canvas, anchor, px, py)
    local index = _terminals.nearest(canvas, anchor, px, py)
    if not index then return nil end
    local tx, ty = _terminals.point(canvas, anchor, index)
    local slop = _shapePoly.PORT_TAP_SLOP_PX
    if (tx - px) * (tx - px) + (ty - py) * (ty - py) <= slop * slop then return index end
    return nil
end

-- Terminal `index`'s label (see _terminals.label) on a dark plate, just off the
-- terminal in the direction a wire leaves it.
function _terminals.drawLabel(canvas, anchor, index)
    local t = anchor.terminals[index]
    local tx, ty = _terminals.point(canvas, anchor, index)
    local rot = math.rad(anchor.rotation or 0)
    local ex, ey = t.exitX or 0, t.exitY or 0
    local dx, dy = ex * math.cos(rot) - ey * math.sin(rot), ex * math.sin(rot) + ey * math.cos(rot)
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0 then dx, dy = dx / len, dy / len else dx, dy = 0, -1 end
    love.graphics.setFont(globApp.appFont or love.graphics.getFont())
    local font = love.graphics.getFont()
    local text = _terminals.label(anchor, index)
    local w, h = font:getWidth(text), font:getHeight()
    local gap = 12
    local cx, cy = tx + dx * (gap + w / 2), ty + dy * (gap + h / 2)
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", cx - w / 2 - 3, cy - h / 2 - 1, w + 6, h + 2, 3, 3)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(text, math.floor(cx - w / 2 + 0.5), math.floor(cy - h / 2 + 0.5))
end

-- The ports of an element whose wire is waiting on a port (pendingWirePortPick),
-- each labeled; then, once picked, just that one, until the wire is drawn.
function _terminals.drawPick(canvas)
    local id, chosen = canvas.pendingWirePortPick, nil
    local noun = _pipes.noun(canvas)
    local prompt = "TAP THE PORT TO RUN THE " .. noun .. " FROM"
    if not id and canvas.pendingWireFromId and canvas.pendingWireFromTerminal then
        id, chosen = canvas.pendingWireFromId, canvas.pendingWireFromTerminal
    elseif not id and canvas.wireTool.fromId and canvas.wireTool.portPicked then
        id, chosen, prompt = canvas.wireTool.fromId, canvas.wireTool.fromTerminal, nil
    end
    local anchor = id and _findAnchor(canvas, id)
    if not anchor or not anchor.terminals then return end
    local radius = math.max(4, math.min(8, canvas.zoom * 1.5))
    for i in ipairs(anchor.terminals) do
        if not chosen or i == chosen then
            local tx, ty = _terminals.point(canvas, anchor, i)
            love.graphics.setColor(0, 0, 0, 1)
            love.graphics.circle("fill", tx, ty, radius + 1)
            if chosen then
                love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 1)
            else
                love.graphics.setColor(1, 1, 1, 1)
            end
            love.graphics.circle("fill", tx, ty, radius)
            _terminals.drawLabel(canvas, anchor, i)
        end
    end
    if chosen and prompt then
        prompt = "DRAG FROM " .. _terminals.label(anchor, chosen) .. " TO WHERE THE " .. noun .. " GOES"
    end
    if prompt then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(prompt, canvas.x, canvas.y + 4, canvas.w, "center")
    end
end

-- A reshapable element's ports (ADD PORT on its edit menu): ordinary wire terminals
-- the user places on its outline, so pipes meet the tank there. Each is a terminal
-- with no flow direction, since a tank's pipes can run either way. Once a tank has
-- any, all its pipes sit on them, which is also what addWire settles them onto when
-- a saved system loads.

-- How far off an edge or a port a tap still counts, in screen pixels.
_shapePoly.PORT_TAP_SLOP_PX = 24

-- The point on p's outline nearest grid position lc,lr, at half-grid steps along
-- its edge so ports on straight sides line up with pipes, and that edge's outward
-- direction. Returns c, r, outwardC, outwardR.
function _shapePoly.nearestOutlinePoint(p, lc, lr)
    local bestC, bestR, bestOutC, bestOutR, bestDistSq
    for _, edge in ipairs(p.edges) do
        local ac, ar, bc, br = edge[1], edge[2], edge[3], edge[4]
        local dc, dr = bc - ac, br - ar
        local length = math.sqrt(dc * dc + dr * dr)
        if length > 0 then
            local along = math.max(0, math.min(length, ((lc - ac) * dc + (lr - ar) * dr) / length))
            along = math.min(length, math.floor(along * 2 + 0.5) / 2)
            local c, r = ac + dc * along / length, ar + dr * along / length
            local distSq = (c - lc) * (c - lc) + (r - lr) * (r - lr)
            if not bestDistSq or distSq < bestDistSq then
                local outC, outR = dr / length, -dc / length
                -- Tested off the edge's middle, clear of any other edge at a corner.
                if _shapePoly.containsLocal(p, (ac + bc) / 2 + outC * 0.01, (ar + br) / 2 + outR * 0.01) then
                    outC, outR = -outC, -outR
                end
                bestC, bestR, bestOutC, bestOutR, bestDistSq = c, r, outC, outR, distSq
            end
        end
    end
    return bestC, bestR, bestOutC, bestOutR
end

-- A terminal at grid position c,r of p, leaving in direction outC,outR.
function _shapePoly.portAt(p, c, r, outC, outR)
    return { x = c / p.cols - 0.5, y = r / p.rows - 0.5, exitX = outC, exitY = outR }
end

-- ports moved from outline p onto reshaped outline np, whose box starts at minC,minR
-- of p's grid: each to the nearest point of the new outline, keeping its index so
-- the pipes on it stay put. nil for none.
function _shapePoly.reseatPorts(ports, p, np, minC, minR)
    if not ports then return nil end
    local moved = {}
    for i, t in ipairs(ports) do
        local c, r, outC, outR = _shapePoly.nearestOutlinePoint(np, (t.x + 0.5) * p.cols - minC, (t.y + 0.5) * p.rows - minR)
        moved[i] = _shapePoly.portAt(np, c, r, outC, outR)
    end
    return moved
end

-- ports for e's left-right mirror image (see _shapePoly.mirroredPoints). nil for none.
function _shapePoly.mirroredPorts(ports)
    if not ports then return nil end
    local mirrored = {}
    for i, t in ipairs(ports) do
        mirrored[i] = { x = -t.x, y = t.y, exitX = -t.exitX, exitY = t.exitY }
    end
    return mirrored
end

-- Puts any of e's pipes not on a port onto its nearest one.
function _shapePoly.settleWiresOnPorts(canvas, e)
    if not e.terminals then return end
    for _, w in ipairs(canvas.wires) do
        for _, ends in ipairs({ { "fromElementId", "fromTerminal", "toElementId", "toTerminal" },
                                { "toElementId", "toTerminal", "fromElementId", "fromTerminal" } }) do
            if w[ends[1]] == e.id and not w[ends[2]] then
                local other = _findAnchor(canvas, w[ends[3]])
                if other then
                    local ox, oy = _terminals.wireEnd(canvas, other, w[ends[4]])
                    w[ends[2]] = _terminals.nearest(canvas, e, ox, oy)
                end
            end
        end
    end
end

-- The port a tap at x,y would put on e's outline, snapped as nearestOutlinePoint
-- does. nil if the tap's too far from the outline, or lands where one of e's
-- ports (other than port `except`, if given) already is.
function _shapePoly.outlinePortAt(canvas, e, x, y, except)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    local c, r, outC, outR = _shapePoly.nearestOutlinePoint(p, _shapePoly.toLocal(cx, cy, cw, ch, p, e.rotation, x, y))
    local wx, wy = _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, c, r)
    local slop = _shapePoly.PORT_TAP_SLOP_PX
    if (wx - x) * (wx - x) + (wy - y) * (wy - y) > slop * slop then return nil end
    local port = _shapePoly.portAt(p, c, r, outC, outR)
    for i, t in ipairs(e.terminals or {}) do
        if i ~= except and math.abs(t.x - port.x) < 1e-6 and math.abs(t.y - port.y) < 1e-6 then return nil end
    end
    return port
end

-- Adds a port where a tap at x,y lands on e's outline. False if the tap's too far
-- from the outline, or on a port that's already there.
function _shapePoly.addPortAt(canvas, e, x, y)
    local port = _shapePoly.outlinePortAt(canvas, e, x, y)
    if not port then return false end
    _pushUndo(canvas)
    e.terminals = e.terminals or {}
    table.insert(e.terminals, port)
    _shapePoly.settleWiresOnPorts(canvas, e)
    _notifyChanged(canvas)
    return true
end

-- Removes the port a tap at x,y lands on, keeping every other pipe on its own port;
-- one that was on this port moves to the nearest left, or back to the tank's body
-- if there are none. False if the tap isn't near a port.
function _shapePoly.removePortAt(canvas, e, x, y)
    local index = _terminals.nearest(canvas, e, x, y)
    if not index then return false end
    local px, py = _terminals.point(canvas, e, index)
    local slop = _shapePoly.PORT_TAP_SLOP_PX
    if (px - x) * (px - x) + (py - y) * (py - y) > slop * slop then return false end
    _pushUndo(canvas)
    table.remove(e.terminals, index)
    if #e.terminals == 0 then e.terminals = nil end
    for _, w in ipairs(canvas.wires) do
        for _, ends in ipairs({ { "fromElementId", "fromTerminal" }, { "toElementId", "toTerminal" } }) do
            local terminal = w[ends[2]]
            if w[ends[1]] == e.id and terminal then
                if terminal == index then
                    w[ends[2]] = nil
                elseif terminal > index then
                    w[ends[2]] = terminal - 1
                end
            end
        end
    end
    _shapePoly.settleWiresOnPorts(canvas, e)
    _notifyChanged(canvas)
    return true
end

-- Moves port `index` of e to where a tap at x,y lands on its outline. It keeps
-- its index, so the pipes on it go with it. False if the tap's off the outline
-- or on another port, or lands on the port's own spot (nothing to move).
function _shapePoly.movePortTo(canvas, e, index, x, y)
    local old = e.terminals and e.terminals[index]
    if not old then return false end
    local port = _shapePoly.outlinePortAt(canvas, e, x, y, index)
    if not port or (math.abs(old.x - port.x) < 1e-6 and math.abs(old.y - port.y) < 1e-6) then return false end
    _pushUndo(canvas)
    -- A new table, so the cached wire routes see the change (_wirePlansChanged).
    local moved = {}
    for i, t in ipairs(e.terminals) do moved[i] = t end
    moved[index] = port
    e.terminals = moved
    _notifyChanged(canvas)
    return true
end

-- e's ports, and what to do next while ADD PORT, REMOVE PORT or MOVE PORT waits
-- on a tap. MOVE PORT's picked port is drawn in the snap color.
function _shapePoly.drawPorts(canvas, e)
    if not _shapePoly.allowed(canvas, e) then return end
    local radius = math.max(2.5, math.min(6, canvas.zoom))
    local pending = canvas.pendingPort
    if pending and pending.elementId ~= e.id then pending = nil end
    for i in ipairs(e.terminals or {}) do
        local tx, ty = _terminals.point(canvas, e, i)
        love.graphics.setColor(0, 0, 0, 1)
        love.graphics.circle("fill", tx, ty, radius + 1)
        if pending and pending.moving == i then
            love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 1)
        else
            love.graphics.setColor(1, 1, 1, 1)
        end
        love.graphics.circle("fill", tx, ty, radius)
    end
    if pending then
        local prompt
        if pending.removing then
            prompt = "TAP A PORT TO REMOVE IT"
        elseif pending.moving == true then
            prompt = "TAP THE PORT TO MOVE"
        elseif pending.moving then
            prompt = "TAP THE TANK'S EDGE TO MOVE THE PORT THERE"
        else
            prompt = "TAP THE TANK'S EDGE TO ADD A PORT"
        end
        love.graphics.setFont(globApp.appFont or love.graphics.getFont())
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(prompt, canvas.x, canvas.y + 4, canvas.w, "center")
    end
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

-- Which anchor (element or control) a point lands on, tolerant of a
-- near-miss: if the point isn't exactly
-- inside any element's box or control's radius, falls back to the nearest
-- one within _CONNECTOR_RELEASE_SLOP_PX pixels. Used only for "which anchor
-- did a wire-drag land on" — a release a few pixels off (easy to do,
-- especially with a finger) should still connect rather than silently fail.
local function _hitAnchorNear(canvas, px, py)
    local exact = _hitElement(canvas, px, py) or _hitControl(canvas, px, py)
    if exact then return exact end
    local best, bestDist = nil, _CONNECTOR_RELEASE_SLOP_PX
    for _, e in ipairs(canvas.elements) do
        local ex, ey, ew, eh = _elementFootprintRect(canvas, e)
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
        if dist < bestDist and not c.hidden then
            best, bestDist = c, dist
        end
    end
    return best
end

-- The anchor a wire-in-progress would actually connect to if released right
-- now, or nil if none (including: too far from anything, or the only match
-- is the wire's own starting anchor). Single source of truth shared by the
-- live snap-preview (drawing) and the actual connect-on-release logic, so
-- what the user sees while dragging is exactly what they'll get. Second
-- return value: for a target with terminals, the one nearest the loose end
-- (see _terminals.nearest), nil otherwise.
local function _connectorSnapTarget(canvas)
    if not canvas.wireTool.fromId then return nil end
    local x, y = canvas.wireTool.curX, canvas.wireTool.curY
    local target = _hitAnchorNear(canvas, x, y)
    if target and target.id ~= canvas.wireTool.fromId then
        return target, _terminals.nearest(canvas, target, x, y)
    end
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
    canvas.annunciators = {}  -- {id, label, color, active} — see the ANNUNCIATORS section below; drawn top-left of the canvas like another element, managed via the slide-out panel
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
    -- True once move mode (above) has had a no-op tap-to-confirm land on
    -- the SAME still-active target (see gdsGui_schematic_released) —
    -- switches the drawn overlay/next-press meaning from "drag to move"
    -- (4 edge arrows) to "drag to rotate" (ring arrow). Reset alongside
    -- selectionMoveModeActive everywhere above/below it clears.
    canvas.rotateModeActive = false
    -- The third stop on that same tap cycle, for a reshapable element only
    -- (see _shapePoly): move -> rotate -> reshape -> move.
    canvas.reshapeModeActive = false
    canvas.reshapableKind    = nil   -- see gdsGui_schematic_setReshapableKind
    canvas._shapeDrag        = nil   -- start-of-gesture state while dragKind is "reshape"
    canvas.wireToolActive    = false
    canvas.wireTool          = { fromId = nil, curX = nil, curY = nil, color = nil }
    canvas.defaultConnectorColor = nil  -- see gdsGui_schematic_setDefaultConnectorColor
    canvas.backgroundImagePath = nil  -- see gdsGui_schematic_setBackgroundImage
    canvas.cornerBackgroundImagePath = nil  -- see gdsGui_schematic_setCornerBackgroundImage
    canvas.cornerRightBackgroundImagePath = nil  -- see gdsGui_schematic_setCornerRightBackgroundImage
    canvas.cornerTopRightBackgroundImagePath = nil  -- see gdsGui_schematic_setCornerTopRightBackgroundImage
    canvas.focusTouchId      = nil
    canvas.dragKind          = nil   -- "element" | "control" | "wire" | "wireDirection" | "rotate" | "controlRotate" | "reshape" | "reshapeEnter" | "pendingLongPress" | "pan" | nil
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
    -- Blended 50/50 with the previous frame's instantaneous delta each
    -- "pan" moved event (see gdsGui_schematic_moved), same smoothing
    -- outputTxtBox_gdsGuiLib.lua's own scroll velocity uses — drives the
    -- post-release coast in gdsGui_schematic_update below.
    canvas.panVelX           = 0
    canvas.panVelY           = 0
    canvas._panCoasting      = false
    canvas.menu              = nil  -- generic modal list: {title, options, onSelect, onCancel}
    canvas.pendingPlacement  = nil  -- armed "place next tap": {kind, shapeType|positions, label, ...}
    canvas.pendingConnectorColor = nil  -- armed "draw next wire" from the catalog, independent of wireToolActive/the dock toggle; disarms after one connector
    canvas.pendingColorAssignPick = false  -- armed "tap an element or wire to assign its snapshot color"; disarms after one pick
    canvas.pendingWireFromId = nil  -- armed via ADD WIRE in the element edit menu: elementId the next press-drag-release starts a wire from, with no need to land that press on an anchor; disarms after one drag
    canvas.pendingPort       = nil  -- armed via ADD PORT/REMOVE PORT/MOVE PORT in the element edit menu: {elementId, removing, moving}, what the next tap does; moving is true until a port is picked, then that port's index. Disarms after one tap (MOVE PORT: after two)
    canvas.pendingWirePortPick = nil  -- armed via ADD WIRE on an element with two or more terminals: its id, waiting on a tap on the port the wire leaves from; disarms after one tap
    canvas.pathEdit = nil  -- {wireId, index, pendingInsert, grabX, grabY} while EDIT PATH is on for a connector (see _wirePath)
    canvas.pendingWireFromTerminal = nil  -- the port picked for pendingWireFromId, so its wire leaves from there rather than whichever port ends up nearest the far end
    canvas.paintMode = nil  -- { color = {r,g,b,a} | nil } while the PAINT brush is armed; see gdsGui_schematic_armPaintMode. Unlike the pending* one-shot fields above, stays armed across any number of taps.
    canvas._paintTarget = nil  -- {kind, id} of whatever a "paint" drag's press landed on, between press and release
    canvas._paintButtonName = nil  -- name of the app's PAINT dock button, set via gdsGui_schematic_setPaintButtonName; the swatch palette cascades from it
    -- ANNUNCIATOR management panel (slide-out list, cascades left out of the
    -- app's ANNUNCIATOR dock button — see gdsGui_schematic_setAnnunciatorButtonName
    -- and the ANNUNCIATORS section below). annunciatorPanelOpen is the sticky
    -- toggle (parallel to paintMode staying armed across taps); the rest
    -- track a single in-flight press on the panel itself (tap a row to
    -- toggle it, drag to scroll) the same tap-vs-drag-slop way every other
    -- gesture in this file does.
    canvas.annunciatorPanelOpen         = false
    canvas.annunciatorPanelScroll       = 0
    canvas._annunciatorButtonName       = nil
    canvas._annunciatorPanelTouchId     = nil
    canvas._annunciatorPanelPressedHit  = nil
    canvas._annunciatorPanelDragStartY  = nil
    canvas._annunciatorPanelDragStartScroll = nil
    canvas._annunciatorPanelMoved       = false
    -- How long the current panel-row press has been held without moving —
    -- polled in gdsGui_schematic_update exactly like canvas.longPressElapsed
    -- is for an on-canvas element/control/wire, but kept separate since a
    -- panel row has no move/rotate mode to unlock: crossing _LONG_PRESS_SECONDS
    -- here opens the rename/delete edit menu instead (see
    -- gdsGui_schematic_openAnnunciatorEditMenu further down).
    canvas._annunciatorPanelLongPressElapsed = 0
    canvas._annunciatorEditTargetId     = nil  -- annunciator id while its rename/delete edit menu is open
    canvas._placementCounter = 0
    canvas._colorPickTarget     = nil  -- {kind="element"|"wire", id=...} while the color-picker menu is open
    canvas._elementEditTargetId = nil  -- elementId while the design-mode edit (color+properties+delete) menu is open
    canvas._wireEditTargetId    = nil  -- wireId while the design-mode wire edit (color+delete) menu is open
    canvas._controlEditTargetId = nil  -- controlId while the design-mode control edit (position+delete) menu is open
    canvas._propertyEditTargetId = nil -- element/control id while the PROPERTIES grid is open
    canvas._propertyEditTargetIsControl = nil -- whether the id above is a control (vs an element)
    canvas._pendingPropertyRows  = nil -- that grid's own shadow rows — see _openPropertiesMenu's own comment
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

    -- Radians accumulated while canvas.mode == "control", driving any
    -- control's overlaySpritePath spin (see gdsGui_schematic_update and
    -- _drawControl) — frozen (not reset) the instant mode leaves "control",
    -- so re-entering control mode resumes the spin rather than restarting it.
    canvas._overlayAnimAngle = 0

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
        self._annunciatorPanelTouchId = nil
        self._annunciatorPanelMoved = false
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

-- The canvas's own on-screen draw rectangle (pixels) — x, y, w, h — same
-- fields the library's own grid/content-clipping math uses internally (see
-- e.g. the grid overlay's x0,y0,x1,y1). Lets app-layer code draw its own
-- overlay positioned relative to the live canvas (e.g. a panel pinned to
-- its bottom edge) without reaching into the canvas table's internals
-- directly.
function gdsGui_schematic_getCanvasRect(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return nil end
    return canvas.x, canvas.y, canvas.w, canvas.h
end

-- Registers (or, passing nil, clears) a screen-space dead zone — a tap
-- landing inside {x, y, w, h} is consumed outright by
-- gdsGui_schematic_pressed (see its own check) before reaching any canvas
-- interaction (pan/select/drag/paint/...), same "takes priority" treatment
-- the library's own modal menu and annunciator panel already get. Lets
-- app-layer code (e.g. a non-library overlay like main.lua's AI info
-- panel) inhibit canvas interaction under its own drawn footprint without
-- the library needing to know anything about what's actually there or why
-- — purely geometric, re-set every frame by whatever owns it (the app
-- layer, not this library, is responsible for keeping it in sync with
-- wherever its overlay is actually drawn this frame, including clearing it
-- once that overlay closes).
-- wheelCallbackFuncName (optional): a by-name callback (resolved via
-- _G[...], same convention as every other string-registered callback in
-- this library), called as fn(delta, isDrag) instead of the usual zoom/pan
-- whenever a mouse wheel event's position falls inside the SAME rect (see
-- gdsGui_schematic_wheelZoom's own check — isDrag false, delta the wheel's
-- own notch-count dy), or whenever a touch that PRESSED inside the rect
-- then drags (see gdsGui_schematic_moved's own check — isDrag true, delta
-- a raw pixel Y offset since the last move, not a notch count). Lets the
-- app's overlay (e.g. a scrollable text panel) claim both the wheel and a
-- touch-drag over its own footprint, without this library needing to know
-- it's scrolling anything — the app's own callback decides how to scale
-- each delta kind.
function gdsGui_schematic_setInputBlockRect(canvasName, rect, wheelCallbackFuncName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas.inputBlockRect = rect
        canvas.inputBlockWheelCallback = rect and wheelCallbackFuncName or nil
    end
end

function gdsGui_schematic_setMode(canvasName, mode)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local modeChanged = canvas.mode ~= mode
    canvas.mode = mode
    -- pendingColor is a design-mode-only preview (see resolveColor) — left
    -- set (e.g. a picked-but-never-captured color) it would otherwise leak
    -- into control mode, where resolveColor checks it BEFORE the
    -- signature-matched snapshot and so masks every snapshot cycled to with
    -- that stale preview instead of replaying it.
    for _, e in ipairs(canvas.elements) do e.pendingColor = nil end
    for _, w in ipairs(canvas.wires) do w.pendingColor = nil end
    for _, c in ipairs(canvas.controls) do c.pendingColor = nil end
    canvas.wireToolActive = false
    canvas.wireTool.fromId = nil
    canvas.wireTool.color = nil
    canvas.pendingPlacement = nil
    canvas.pendingConnectorColor = nil
    canvas.pendingColorAssignPick = false
    canvas.pendingWireFromId = nil
    canvas.pendingWirePortPick = nil
    canvas.pendingWireFromTerminal = nil
    canvas.pathEdit = nil
    canvas.paintMode = nil
    canvas._paintTarget = nil
    canvas.annunciatorPanelOpen = false
    canvas._annunciatorPanelTouchId = nil
    canvas._annunciatorPanelMoved = false
    canvas.menu = nil
    canvas.touches = {}
    canvas.pinch = nil
    canvas.focusTouchId = nil
    canvas.dragKind = nil
    canvas._pendingDragUndoSnapshot = nil
    canvas.selectionMoveModeActive = false
    canvas.rotateModeActive = false
    canvas.reshapeModeActive = false
    -- Selection is a design-mode-only concept (every selection-driven drag/
    -- menu branch above gates on canvas.mode == "design") -- leaving an
    -- element/wire selected while switching into control mode would keep it
    -- drawn with its selection highlight there with no way to clear it.
    if mode == "control" then
        canvas.selectedElementId = nil
        canvas.selectedWireId    = nil
    end
    -- Lets the app keep its own mode-dependent chrome (the EDIT MODE
    -- toggle's own pressed state, dock tool visibility, etc.) in sync even
    -- when this library changes mode on its own — e.g. the control-mode
    -- long-press's auto-promote/revert (gdsGui_schematic_pressed/_update) —
    -- not just when the app's own toggle button calls this directly. See
    -- gdsGui_schematic_setModeChangedCallback.
    if modeChanged and canvas.onModeChanged then
        _G[canvas.onModeChanged](canvasName, mode)
    end
end

-- Registers a string-named callback (resolved via _G, same convention as
-- every other button/menu callback in this library) fired after every
-- ACTUAL mode change on this canvas, including ones this library makes on
-- its own (see gdsGui_schematic_setMode) — so the app can keep its own
-- mode-dependent UI in sync regardless of what triggered the change.
function gdsGui_schematic_setModeChangedCallback(canvasName, callbackName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.onModeChanged = callbackName end
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
    canvas.elements     = snapshot.elements
    canvas.wires        = snapshot.wires
    canvas.controls     = snapshot.controls
    canvas.annunciators = snapshot.annunciators or {}
    canvas.snapshots    = snapshot.snapshots
    canvas.selectedElementId = nil
    canvas.selectedControlId = nil
    canvas.selectedWireId    = nil
end

-- Resets the pan/zoom view to a given startZoom (or _MIN_ZOOM, fully zoomed
-- out, if omitted), vertically centered. Called whenever a project is
-- (re)loaded into the canvas so each one opens at a known view rather than
-- wherever the previous project's view was left.
function gdsGui_schematic_resetView(canvasName, startZoom)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.zoom = math.max(_MIN_ZOOM, math.min(_MAX_ZOOM, startZoom or _MIN_ZOOM))
    -- The new zoom may change the viewport box size (see
    -- gdsGui_schematic_setZoomedLayout) — recompute before resetting pan so
    -- panX/panY line up with the resulting box.
    _calculateGeometry(canvas)
    canvas.panX = 0
    -- canvas.h stays fixed across zoom levels (only width grows to track
    -- zoom — see _schematicCanvasZoomedLayout in main.lua), so once zoom
    -- exceeds _MIN_ZOOM the content's world height overflows the viewport.
    -- Center that overflow top/bottom instead of pinning the content's top
    -- edge to the viewport's, so opening a system lands on its vertical
    -- middle rather than whatever happened to be placed highest.
    canvas.panY = (canvas.h - canvas.contentH * canvas.zoom) / 2
    _clampPan(canvas)
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
-- 180/270) of the element's icon -- every shapeType is rotatable (see
-- _drawElement). spritePath (optional): an app-supplied image
-- path drawn letterboxed into the element's box instead of the plain
-- rect/circle/diode shape (see _drawElementSprite) — same arm's-length
-- "just a string the app layer resolved" relationship as a gallery tile's
-- item.thumbnailPath; the library never interprets what it depicts. The
-- element's resolved color (base/pending/snapshot, same as any other
-- shapeType) still tints it, so color-coding by snapshot still works.
-- componentType (optional, nil by default): an opaque string the app layer
-- assigns — never interpreted here, same arm's-length relationship as
-- spritePath — naming this element's role in the inference model's graph
-- (e.g. "source" | "path" | "gate" | "directionalGate" | "sink"; see
-- model/graph.lua). nil means untagged/excluded from solving, so every
-- element placed before this feature existed keeps working unchanged.
-- terminals (optional): wire attachment points, same shape and behavior
-- as gdsGui_schematic_addControl's own — x/y are fractions of the
-- element's own (unrotated) w/h box here, since its sprite fills that box.
function gdsGui_schematic_addElement(canvasName, id, shapeType, x, y, w, h, label, defaultColor, properties, rotation, spritePath, componentType, terminals)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    table.insert(canvas.elements, {
        id = id, shapeType = shapeType, x = x, y = y, w = w, h = h,
        label = label, defaultColor = defaultColor or _DEFAULT_COLOR, pendingColor = nil,
        properties = properties or {}, rotation = rotation or 0, spritePath = spritePath,
        componentType = componentType, predictedColor = nil, terminals = terminals,
    })
    _resyncPlacementCounter(canvas, id)
end

-- Upserts a property by key (case-sensitive), preserving insertion order for
-- display. value is a plain string — units/formatting are the app layer's
-- concern. elementId may name either an element OR a control (_findAnchor) —
-- both carry their own .properties list (see gdsGui_schematic_addControl).
function gdsGui_schematic_setElementProperty(canvasName, elementId, key, value)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findAnchor(canvas, elementId)
    if not el then return end
    el.properties = el.properties or {}
    for _, p in ipairs(el.properties) do
        if p.key == key then p.value = value; return end
    end
    table.insert(el.properties, { key = key, value = value })
end


function gdsGui_schematic_getElementProperties(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return {} end
    local el = _findAnchor(canvas, elementId)
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
-- fromTerminal/toTerminal (optional): which of that end's control's own
-- terminals (see gdsGui_schematic_addControl) the wire attaches to, by
-- index. Ignored for an end without terminals. Left nil for an end that
-- does have them (a wire saved before that control had terminals), it's
-- settled here once, to the terminal nearest the wire's other end, so
-- drawing and the app's own connectivity model always agree on it.
function gdsGui_schematic_addWire(canvasName, id, fromElementId, toElementId, defaultColor, directionOverride, fromTerminal, toTerminal)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local fromA, toA = _findAnchor(canvas, fromElementId), _findAnchor(canvas, toElementId)
    if fromA and toA then
        if not fromTerminal and fromA.terminals then
            local ox, oy = _terminals.wireEnd(canvas, toA, toTerminal)
            fromTerminal = _terminals.nearest(canvas, fromA, ox, oy)
        end
        if not toTerminal and toA.terminals then
            local ox, oy = _terminals.wireEnd(canvas, fromA, fromTerminal)
            toTerminal = _terminals.nearest(canvas, toA, ox, oy)
        end
    end
    table.insert(canvas.wires, {
        id = id, fromElementId = fromElementId, toElementId = toElementId,
        fromTerminal = fromA and fromA.terminals and fromTerminal or nil,
        toTerminal = toA and toA.terminals and toTerminal or nil,
        defaultColor = defaultColor or _DEFAULT_COLOR, pendingColor = nil,
        directionOverride = directionOverride, predictedColor = nil,
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
-- this control only. Unlike an element's w/h, a control's radius is
-- normally one shared canvas-wide constant (canvas.controlRadius), so this
-- is the per-instance equivalent of an element's own gridW/gridH — the
-- design-mode placement flow passes _controlGridRadiusScale(canvas,
-- gridSize) so a freshly-placed control is exactly gridSize grid units
-- across (see gdsGui_schematic_armControlPlacement). Omitted (nil -> 1) for
-- every other caller (loading saved data, the demo seed, unit tests), so
-- already-placed controls keep rendering exactly as they always have. spritePaths
-- (optional): array of image paths parallel to positions — the one at
-- detentIndex+1 is drawn (letterboxed, see _drawControl) instead of the
-- plain vector circle+indicator-line for whichever position is currently
-- selected; an entry can be nil (or the array shorter than positions) to
-- fall back to the vector icon for just that one position. Same
-- arm's-length "just paths the app layer resolved" relationship as an
-- element's own spritePath. rotation (optional, degrees, defaults to 0):
-- every control is rotatable, same as every element now, spinning its icon
-- (sprite or vector alike) to one of the 4 cardinal orientations.
-- overlaySpritePath
-- (optional): a second image drawn on top of spritePaths' current-detent
-- icon (or the plain vector fallback), same letterboxed size, continuously
-- spinning while canvas.mode == "control" AND the control sits in its last
-- ("ON"/flowing/conducting) position — same last-position-means-on
-- convention as _SWITCH_SPRITE_PATHS — frozen at rest otherwise (design
-- mode, or control mode with the control OFF) — see
-- gdsGui_schematic_update's _OVERLAY_SPIN_RADPS accumulator and
-- _drawControl. For a control whose base icon doesn't change per detent
-- (e.g. a generator's housing, same for OFF/ON), the spin is the only thing
-- that visually tells a user it's switched on and running. defaultColor
-- (optional, defaults to the library's flat gray _DEFAULT_COLOR): a
-- control's base tint, same ASSIGN COLOR/design-mode-edit-menu/snapshot
-- machinery as an element or wire's own defaultColor — see
-- gdsGui_schematic_resolveDisplayColor and _drawControl.
-- colorDarkenMul (optional, defaults to 1): flat multiplier on this
-- control's own resolved r/g/b at draw time, for a control whose icon
-- should read darker than its assigned color.
-- componentType (optional, nil by default): see gdsGui_schematic_addElement
-- above — the same opaque app-assigned graph-role string, for a control
-- that's an interactive source or gate (e.g. a generator switch or a
-- breaker) rather than a passive element.
-- terminals (optional): array of wire attachment points on the icon,
-- {x, y, exitX, exitY, ...} — x/y the terminal's offset from the control's
-- center as a fraction of its icon box (-0.5..0.5, before rotation),
-- exitX/exitY the unit direction a wire leaves it in. A wire to a control
-- with terminals attaches to one of them (whichever it's dropped nearest —
-- see _terminals.nearest) instead of the control's edge, and remembers
-- which (the wire's fromTerminal/toTerminal). Any other keys (e.g. the
-- app's own pole number) are stored untouched for the app layer.
-- An app may set `hidden = true` on a control afterwards: it's then never
-- drawn, tapped, overlap-checked or wired, but still counts toward the
-- combination signature like any other control (e.g. an app-wide state such
-- as the aircraft's gear position that snapshots must depend on).
function gdsGui_schematic_addControl(canvasName, id, x, y, positions, initialDetentIndex, label, callbackFunc, radiusScale, spritePaths, rotation, overlaySpritePath, defaultColor, colorDarkenMul, componentType, terminals)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local numDetents = math.max(2, #positions)
    table.insert(canvas.controls, {
        id = id, x = x, y = y, numDetents = numDetents, positions = positions,
        detentIndex = math.max(0, math.min(numDetents - 1, initialDetentIndex or 0)),
        label = label, callbackFunc = callbackFunc, radiusScale = radiusScale or 1,
        spritePaths = spritePaths, rotation = rotation or 0, overlaySpritePath = overlaySpritePath,
        defaultColor = defaultColor or _DEFAULT_COLOR, pendingColor = nil,
        colorDarkenMul = colorDarkenMul or 1,
        componentType = componentType, predictedColor = nil, terminals = terminals,
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
    if canvas.selectedControlId == id then canvas.selectedControlId = nil end
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

-- Places a new control distanceGridUnits grid units from anchorId's center,
-- out along terminal terminalIndex's own exit direction (rotated with the
-- anchor), and wires that terminal to it — e.g. the pilot switch commanding
-- a relay. terminals (optional) are the new control's own (see addControl);
-- the wire lands on its terminal linkTerminal. idPrefix/label follow the
-- catalog placement conventions: the id is minted from the canvas's
-- placement counter, and label gets a numeric suffix if already taken.
-- Does not push undo or notify — the caller is expected to be inside a
-- placement that already did. Returns the new control's id, or nil if the
-- anchor or terminal doesn't exist.
function gdsGui_schematic_addLinkedControl(canvasName, anchorId, terminalIndex, distanceGridUnits, idPrefix, label, positions, spritePaths, gridSize, componentType, terminals, linkTerminal)
    local canvas = _findCanvas(canvasName)
    if not canvas then return nil end
    local anchor = _findAnchor(canvas, anchorId)
    local t = anchor and anchor.terminals and anchor.terminals[terminalIndex]
    if not t then return nil end

    local cx, cy = anchor.x, anchor.y
    if anchor.w then cx, cy = anchor.x + anchor.w / 2, anchor.y + anchor.h / 2 end
    local rot = math.rad(anchor.rotation or 0)
    local ex, ey = t.exitX or 0, t.exitY or 0
    local dx, dy = ex * math.cos(rot) - ey * math.sin(rot), ex * math.sin(rot) + ey * math.cos(rot)
    local fracX = cx + dx * distanceGridUnits * _GRID_SPACING_PX / canvas.contentW
    local fracY = cy + dy * distanceGridUnits * _GRID_SPACING_PX / canvas.contentH
    fracX, fracY = _snapToGrid(canvas, fracX, fracY)

    canvas._placementCounter = canvas._placementCounter + 1
    local id = idPrefix .. "_" .. canvas._placementCounter
    local uniqueLabel, n = label, 2
    while _labelInUse(canvas, uniqueLabel) do
        uniqueLabel = label .. " " .. n
        n = n + 1
    end
    gdsGui_schematic_addControl(canvasName, id, fracX, fracY, positions, 0, uniqueLabel, nil,
        _controlGridRadiusScale(canvas, gridSize), spritePaths, nil, nil, nil, nil, componentType, terminals)
    gdsGui_schematic_addWire(canvasName, _uniqueWireId(canvas, anchorId .. "_to_" .. id), anchorId, id,
        nil, nil, terminalIndex, linkTerminal)
    return id
end

-- Swaps the image an element draws (see addElement's spritePath) — for app
-- state the artwork itself shows, e.g. a relay drawn open or closed.
function gdsGui_schematic_setElementSprite(canvasName, elementId, spritePath)
    local canvas = _findCanvas(canvasName)
    local el = canvas and _findElement(canvas, elementId)
    if el then el.spritePath = spritePath end
end

--------------------------------------------------------------------------------
-- PUBLIC API — PLACEMENT ARMING (design-mode "add from catalog" flow)
--------------------------------------------------------------------------------

-- defaultPropertyKeys (optional): array of property-name strings to pre-seed
-- on the placed element with empty values, e.g. {"VOLTAGE","CURRENT"} for a
-- catalog item the app layer knows is electrical — ready for the user to fill
-- in via the design-mode element edit menu's PROPERTIES option. spritePath
-- (optional): see gdsGui_schematic_addElement — threaded through unchanged.
-- gridW/gridH (both optional, default to 1): this element's footprint in
-- whole "grid units" (see _GRID_SPACING_PX) — a BATTERY catalog entry with
-- gridW=2, gridH=4 places as exactly 2 grid squares wide by 4 tall, on
-- screen, at any zoom or window size — see _elementGridFootprintFrac.
-- componentType (optional): see gdsGui_schematic_addElement — threaded
-- through unchanged, onto canvas.pendingPlacement, for _commitNamedPlacement
-- to pass on to the real addElement call once the user names the placement.
-- terminals (optional): see gdsGui_schematic_addElement.
function gdsGui_schematic_armElementPlacement(canvasName, shapeType, label, defaultColor, idPrefix, defaultPropertyKeys, spritePath, gridW, gridH, componentType, terminals)
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
        spritePath = spritePath, gridW = gridW, gridH = gridH,
        componentType = componentType, terminals = terminals }
end

-- spritePaths, overlaySpritePath (both optional): see
-- gdsGui_schematic_addControl — threaded through unchanged.
-- gridSize (optional, defaults to 2): this control's diameter in whole
-- "grid units" (see _GRID_SPACING_PX) — the control equivalent of an
-- element's own gridW/gridH, e.g. a SWITCH catalog entry with gridSize=2
-- places as exactly 2 grid squares across — see _controlGridRadiusScale.
-- colorDarkenMul (optional, defaults to 1): see gdsGui_schematic_addControl
-- — threaded through unchanged.
-- componentType (optional): see gdsGui_schematic_addElement above —
-- threaded through unchanged, same as the other arm-time options here.
-- terminals (optional): see gdsGui_schematic_addControl — deep-copied per
-- placement so no two controls share one table.
function gdsGui_schematic_armControlPlacement(canvasName, positions, label, callbackFunc, idPrefix, spritePaths, overlaySpritePath, gridSize, colorDarkenMul, componentType, terminals)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pendingPlacement = { kind = "control", positions = positions, label = label,
        callbackFunc = callbackFunc, idPrefix = idPrefix or label, spritePaths = spritePaths,
        overlaySpritePath = overlaySpritePath, gridSize = gridSize, colorDarkenMul = colorDarkenMul,
        componentType = componentType, terminals = terminals }
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

-- An app-supplied backdrop image drawn behind the grid/elements/wires, same
-- arm's-length "just a path the app layer resolved" relationship as an
-- element's own spritePath — the library never interprets what it depicts.
-- Lives in the same world coordinate system elements/controls do, so it
-- pans and zooms WITH the content rather than staying pinned to the
-- viewport like a fixed wallpaper — see _drawCanvasBackground. nil clears
-- it back to the library's plain flat fill.
function gdsGui_schematic_setBackgroundImage(canvasName, path)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.backgroundImagePath = path end
end

-- A second, smaller backdrop image anchored to the bottom-left corner of
-- the content box (see _drawCanvasCornerBackground for sizing/positioning),
-- drawn BEHIND backgroundImagePath above rather than on top of it — same
-- arm's-length "just a path" relationship, same world-space pan/zoom
-- behavior. nil clears it.
function gdsGui_schematic_setCornerBackgroundImage(canvasName, path)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.cornerBackgroundImagePath = path end
end

-- Mirror of gdsGui_schematic_setCornerBackgroundImage for the bottom-RIGHT
-- corner of the content box — same size, same world-space pan/zoom,
-- same layering behind backgroundImagePath. nil clears it.
function gdsGui_schematic_setCornerRightBackgroundImage(canvasName, path)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.cornerRightBackgroundImagePath = path end
end

-- Same again for the TOP-right corner of the content box — same size,
-- same world-space pan/zoom, same layering. nil clears it.
function gdsGui_schematic_setCornerTopRightBackgroundImage(canvasName, path)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.cornerTopRightBackgroundImagePath = path end
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
        canvas.pendingWirePortPick = nil
        canvas.pendingWireFromTerminal = nil
        canvas.pendingPort = nil
        -- Ending EDIT PATH also lets go of the connector it selected.
        if canvas.pathEdit then canvas.selectedWireId = nil end
        canvas.pathEdit = nil
        canvas.paintMode = nil
        canvas.annunciatorPanelOpen = false
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — PAINT MODE (brush button): a sticky, multi-tap alternative to
-- the one-shot pending-pick field above. Once armed, a plain tap (no drag)
-- on an element/wire/control immediately paints it with whatever color is
-- currently loaded, instead of opening its edit menu — replacing that menu's
-- own embedded color-swatch row (see gdsGui_schematic_openElementEditMenu and
-- its wire/control siblings, which no longer offer one). Stays armed across
-- any number of paints — a miss on empty canvas space just pans the view
-- instead (see gdsGui_schematic_pressed), same as outside paint mode — until
-- explicitly disarmed via the brush button again
-- (gdsGui_schematic_disarmPaintMode); never one-shot on a hit, unlike
-- pendingColorAssignPick above. A "source"-role element/control is excluded
-- from painting entirely (see gdsGui_schematic_pressed's paintMode branch)
-- — its color is app-layer-automatic now, derived from its own voltage.
--------------------------------------------------------------------------------

function gdsGui_schematic_armPaintMode(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.paintMode = { color = nil }
    canvas.selectedElementId = nil
    canvas.selectedControlId = nil
    canvas.selectedWireId = nil
end

function gdsGui_schematic_disarmPaintMode(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.paintMode = nil end
end

function gdsGui_schematic_isPaintModeActive(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and canvas.paintMode ~= nil
end

-- Tells the swatch palette which app button to cascade from (see
-- _paintPaletteGeometry) — the app registers its own PAINT dock button's
-- name here once, typically right after creating it.
function gdsGui_schematic_setPaintButtonName(canvasName, buttonName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas._paintButtonName = buttonName end
end

function gdsGui_schematic_isPlacementArmed(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and (canvas.pendingPlacement ~= nil or canvas.pendingConnectorColor ~= nil or
        canvas.pendingColorAssignPick or canvas.pendingWireFromId ~= nil or canvas.pendingPort ~= nil or
        canvas.pendingWirePortPick ~= nil or canvas.pathEdit ~= nil)
end

--------------------------------------------------------------------------------
-- PUBLIC API — GENERIC MODAL LIST MENU
-- Reused for: design-mode catalog cascade, control-mode control/position
-- pickers, the built-in color picker, and snapshot-conflict confirmation.
--------------------------------------------------------------------------------

-- Called only when the caller explicitly passes a confirmIndex (a
-- destructive action — DELETE, RESET, OVERWRITE, CONTINUE). confirmIndex is
-- either a plain number (1-based into menu.options — the original, still-
-- supported single-row shape, always drawn in red)
-- or an array of {index, color} entries for 2+ independently-colored
-- confirm rows in the SAME menu (e.g. DESIGN ACTIONS' own CLEAR THIS
-- SNAPSHOT/yellow and CLEAR ALL SNAPSHOTS/red) — color is {r,g,b,a},
-- optional per entry (falls back to the same red default). Builds
-- menu.confirmRows = {[index] = color}, consulted everywhere a row used to
-- be compared against a single menu.confirmIndex (_handleMenuRelease,
-- _pollMenuHoldToConfirm, _drawMenuBox/_drawMenuTextRow).
--
-- Tags every row named in confirmRows as requiring a sustained
-- _CONFIRM_HOLD_SECONDS press instead of a plain tap, guarding against an
-- accidental tap triggering something destructive, and folds a hint about
-- that into the title so the user isn't left holding a row with no idea why
-- it isn't responding (naming the one row by text when there's only one,
-- same as before; a plain generic hint once there's more than one, since
-- each row's own color already distinguishes it on screen) — see
-- _pollMenuHoldToConfirm for where the hold is actually timed. Every
-- destructive row lives directly in its menu's own option list alongside
-- ordinary (plain-tap) rows — e.g. the element edit menu's own DELETE —
-- rather than behind a separate "are you sure" popup: one hold IS the
-- confirmation, so there's nothing left to pop up a second menu for.
-- Deliberately passed explicitly by every call site rather than inferred
-- from option text/shape — a future row that happens to be named "DELETE"
-- or sit in a 2-option menu must not be silently gated behind a hold it
-- never asked for.
local function _markConfirmMenu(menu, confirmIndex)
    if not confirmIndex then return end
    -- Red — the historical single-confirm-row color, still the default
    -- when a caller passes a plain confirmIndex number, or omits a color
    -- for one entry of a per-row table. Local to here (its only use), not
    -- file scope, to stay under this file's 200-local ceiling.
    local defaultColor = {0.75, 0.15, 0.15, 1}
    local rows = {}
    if type(confirmIndex) == "table" then
        for _, entry in ipairs(confirmIndex) do
            rows[entry.index] = entry.color or defaultColor
        end
    else
        rows[confirmIndex] = defaultColor
    end
    menu.confirmRows = rows
    if menu.title then
        local names = {}
        for idx in pairs(rows) do table.insert(names, menu.options[idx]) end
        if #names == 1 then
            menu.title = menu.title .. " (PRESS & HOLD \"" .. names[1] .. "\" " .. _CONFIRM_HOLD_SECONDS .. "S TO CONFIRM)"
        else
            menu.title = menu.title .. " (PRESS & HOLD TO CONFIRM)"
        end
    end
end

-- onSelectFunc(canvasName, index, optionText) and onCancelFunc(canvasName) are
-- global function names (strings), resolved via _G[...] like every other
-- string-named callback in this library. confirmIndex (optional) marks one
-- or more rows a destructive hold-to-confirm gate instead of a plain tap —
-- see _markConfirmMenu for its two accepted shapes. widthFrac (optional) overrides the
-- menu box's width as a fraction of the canvas width (default
-- _MENU_WIDTH_FRAC). toggleStates (optional): an array of booleans parallel
-- to options — when given, EVERY row renders as an iOS-style ON/OFF switch
-- instead of plain centered text (see _drawMenuToggleRow), and tapping a row
-- flips its own entry in place and calls onSelectFunc(canvasName, index,
-- optionText, newState) WITHOUT closing the menu — unlike an ordinary row,
-- which closes it (see _handleMenuRelease). Tapping outside the menu (or
-- its anchor dock button again) still closes it the normal way. Meant for a
-- small fixed set of independent on/off choices (e.g. which canvas
-- watermark layers are showing) where the user flips several in a row
-- without the menu closing after each one.
function gdsGui_schematic_openMenu(canvasName, title, options, onSelectFunc, onCancelFunc, confirmIndex, widthFrac, toggleStates)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    -- A menu always takes priority over the annunciator panel (see
    -- gdsGui_schematic_pressed, which checks canvas.menu first) — close the
    -- panel here too so it doesn't keep drawing underneath/behind the menu
    -- it's no longer receiving input for (e.g. the ADD "+" button opening
    -- the catalog cascade while the panel happens to be open).
    canvas.annunciatorPanelOpen = false
    -- Likewise EDIT PATH: its handles would draw over the menu, and the tap
    -- after it (placing an element from ADD, say) would only end the edit.
    if canvas.pathEdit then _wirePath.finish(canvas) end
    canvas.menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc,
        anchorButtonName = canvas._menuAnchorButtonName, widthFrac = widthFrac, toggleStates = toggleStates }
    _markConfirmMenu(canvas.menu, confirmIndex)
end

-- While set, every menu this canvas opens (openMenu and the swatch pickers)
-- is pinned just left of the named dock button at the canvas's top edge
-- (see _toolPopupOrigin) instead of centered — the app sets this for as
-- long as a dock tool whose flow is made of menus (e.g. ADD's catalog
-- cascade) is active, and clears it (nil) once that tool is deactivated.
function gdsGui_schematic_setMenuAnchorButton(canvasName, buttonName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas._menuAnchorButtonName = buttonName
    if canvas.menu then canvas.menu.anchorButtonName = buttonName end
end

function gdsGui_schematic_closeMenu(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.menu = nil end
end

function gdsGui_schematic_isMenuOpen(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and canvas.menu ~= nil
end

-- True if the ACTIVE page currently has any modal schematic surface open —
-- a canvas's openMenu (ADD catalog, element/wire/control/annunciator edit,
-- properties grid, etc.), its annunciator panel, or a gallery's action
-- menu. gdsGui_schematic_pressed/_released and gdsGui_schematicGallery_
-- pressed/_released already give these top priority WITHIN their own
-- canvas/gallery, but every OTHER control on the page (buttons, text boxes,
-- tables, scrollbars, rotary knobs) has no such awareness on its own —
-- general_gdsGuiLib.lua's input dispatchers call this to keep those from
-- also reacting to a tap that a modal surface elsewhere on the page should
-- have exclusive priority over, the same "modal takes priority" treatment
-- gdsGui_textPrompt_isOpen/gdsGui_choiceMenu_isOpen already get.
function gdsGui_schematic_isAnyMenuOpen()
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == activePageName and (canvas.menu or canvas.annunciatorPanelOpen) then
            return true
        end
    end
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page == activePageName and gallery.menu then
            return true
        end
    end
    return false
end

-- Narrower than gdsGui_schematic_isAnyMenuOpen above: true only for a true
-- full-overlay modal (a canvas's own openMenu, or a gallery's menu) — one
-- that can legitimately render on top of some OTHER button elsewhere on the
-- page, which is why gdsGui_button_pressed/_released skip themselves while
-- this is true. The annunciator panel deliberately does NOT count here even
-- though isAnyMenuOpen treats it the same way everywhere else: it's docked
-- just left of its own ANNUNCIATOR button (see _toolPopupOrigin), never
-- over any other button, and that same button is the ONLY way to close it
-- (see _handleAnnunciatorPanelPress's own comment) — gating gdsGui_button_
-- pressed/_released behind the panel being open would make that one button
-- unpressable for as long as its own panel stayed up.
function gdsGui_schematic_isHardMenuOpen()
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == activePageName and canvas.menu then
            return true
        end
    end
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page == activePageName and gallery.menu then
            return true
        end
    end
    return false
end

-- Measures how tall the title row needs to be so a long, wrapped title (e.g.
-- the "ADDING A NEW ELEMENT WILL DELETE ALL N SNAPSHOT(S)..." confirm
-- warning, longer still once _markConfirmMenu appends its "PRESS & HOLD"
-- suffix) doesn't bleed into the option rows below it. Previously a fixed
-- _MENU_ROW_H regardless of how many lines the title actually wrapped to.
-- Uses love.graphics.getFont() — the same ambient font _drawMenuBox's own
-- printf call below renders the title with (this file never calls setFont
-- itself, see its module header) — and the same wrap width (mw, no extra
-- padding) that printf wraps against, so the measured height always matches
-- what's actually drawn.
local function _titleHeight(mw, title)
    if not title then return 0 end
    local titleVPad = 16 -- 8px top inset (matches rowY + 8 below) + 8px bottom
    local font = love.graphics.getFont()
    local _, lines = font:getWrap(title, mw)
    local numLines = math.max(1, #lines)
    return math.max(_MENU_ROW_H, numLines * font:getHeight() + titleVPad)
end

-- Menus are drawn the way iOS draws an action sheet: a rounded group of options
-- (title on top in gray, hairlines between rows) docked at the bottom of the
-- canvas/gallery, with the way out on a separate CANCEL button below it, and a
-- short slide up when one opens. A menu pinned to a dock button (see
-- gdsGui_schematic_setMenuAnchorButton) and the swatch picker keep their own
-- spots and just share the look. A global table, like _shapePoly, since this
-- file is at Lua's 200-local ceiling.
_actionSheet = {}
_actionSheet.MARGIN_PX = 8        -- clear space between the sheet and the owner's edges
_actionSheet.GAP_PX = 8           -- between the options group and its CANCEL button
_actionSheet.MAX_W_PX = 420       -- a sheet's widest, so it doesn't stretch across a tablet
_actionSheet.RADIUS_PX = 12
_actionSheet.ROW_H_PX = 44        -- preferred row height (iOS's touch target); falls back to _MENU_ROW_H when a long menu wouldn't fit
_actionSheet.SLIDE_SECONDS = 0.22
_actionSheet.CANCEL_TEXT = "CANCEL"
-- Opaque, so a pressed row's fill can overlap the group's rounded corners cleanly.
-- text/textDim: plain (non-action) row label colors — used by the
-- annunciator panel's toggle rows, which read as list items rather than
-- iOS action-sheet commands, so they don't borrow the blue `action` color.
_actionSheet.DARK = { bg = {0.17, 0.17, 0.18, 1}, pressed = {0.26, 0.26, 0.28, 1}, separator = {0.33, 0.33, 0.35, 1},
    title = {0.60, 0.60, 0.63, 1}, action = {0.04, 0.52, 1, 1}, destructive = {1, 0.27, 0.23, 1},
    text = {1, 1, 1, 1}, textDim = {0.5, 0.5, 0.5, 1} }
_actionSheet.LIGHT = { bg = {0.97, 0.97, 0.97, 1}, pressed = {0.84, 0.84, 0.86, 1}, separator = {0.78, 0.78, 0.80, 1},
    title = {0.43, 0.43, 0.45, 1}, action = {0, 0.48, 1, 1}, destructive = {1, 0.23, 0.19, 1},
    text = {0.07, 0.07, 0.08, 1}, textDim = {0.6, 0.6, 0.6, 1} }

-- An option that reads as the way out of its menu, shown as the sheet's CANCEL button.
function _actionSheet.isExitOption(opt)
    return opt == "CANCEL" or opt == "RETURN"
end

-- An option that deletes or clears something, drawn in red as iOS draws destructive actions.
function _actionSheet.isDestructive(opt)
    return type(opt) == "string" and (opt:find("^DELETE") or opt:find("^REMOVE") or opt:find("^CLEAR")) ~= nil
end

-- Fills a rectangle, rounding only its top corners, its bottom ones, both or neither.
function _actionSheet.fill(x, y, w, h, roundTop, roundBottom)
    local r = math.min(_actionSheet.RADIUS_PX, h / 2)
    if not roundTop and not roundBottom then
        love.graphics.rectangle("fill", x, y, w, h)
        return
    end
    love.graphics.rectangle("fill", x, y, w, h, r, r)
    if not roundTop then love.graphics.rectangle("fill", x, y, w, r) end
    if not roundBottom then love.graphics.rectangle("fill", x, y + h - r, w, r) end
end

-- Generalized over any owner with .x/.y/.w/.h (schematic canvas or gallery)
-- so both widget types can share one modal-menu implementation below.
-- A menu is normally a plain vertical list of text rows (menu.options). When
-- menu.isSwatchPicker is set, the first #menu.swatchColors entries render as
-- a single row of colored squares instead (menu.extraOptions, e.g. "DELETE",
-- still render as ordinary text rows below it) — the swatch count plus the
-- extra-option count must equal #menu.options, since hit-testing/selection
-- still indexes into that one combined list.
-- Returns the layout: x, w; y, h and titleH of the options group; swatchY (swatch
-- picker only); rows, each {index into menu.options, y, h}; cancel, {hit, text, y, h}
-- or nil, where hit is the option index of a trailing CANCEL/RETURN or "cancel" for
-- the plain one (which closes the menu as a tap outside it does); and reveal, 0-1
-- through the opening slide (see _drawMenuBox, which starts it).
local function _menuGeometry(owner, menu)
    local M = _actionSheet.MARGIN_PX
    local anchorBtn = menu.anchorButtonName and _findButton(menu.anchorButtonName)
    local sheet = not menu.isSwatchPicker and not anchorBtn
    local n = #menu.options
    local firstRow, lastRow = 1, n
    if menu.isSwatchPicker then firstRow = #menu.swatchColors + 1 end
    local cancel
    if sheet and n >= 2 then
        if _actionSheet.isExitOption(menu.options[n]) and not (menu.confirmRows and menu.confirmRows[n]) then
            cancel = { hit = n, text = menu.options[n] }
            lastRow = n - 1
        else
            cancel = { hit = "cancel", text = _actionSheet.CANCEL_TEXT }
        end
    end

    local w = sheet and math.min(owner.w - 2 * M, _actionSheet.MAX_W_PX) or owner.w * (menu.widthFrac or _MENU_WIDTH_FRAC)
    local titleH = _titleHeight(w, menu.title)
    local swatchH = menu.isSwatchPicker and _SWATCH_ROW_H_PX or 0
    local rowCount = lastRow - firstRow + 1
    local rowH = sheet and _actionSheet.ROW_H_PX or _MENU_ROW_H
    local function totalFor(h) return titleH + swatchH + rowCount * h + (cancel and (_actionSheet.GAP_PX + h) or 0) end
    if sheet and totalFor(rowH) > owner.h - 2 * M then rowH = _MENU_ROW_H end
    -- Still too tall: the separate CANCEL button goes (a tap outside still
    -- cancels, and a trailing CANCEL/RETURN goes back to being its last row).
    if sheet and cancel and totalFor(rowH) > owner.h - 2 * M then
        cancel = nil
        lastRow = n
        rowCount = lastRow - firstRow + 1
    end
    local groupH = titleH + swatchH + rowCount * rowH

    local x = owner.x + (owner.w - w) / 2
    local y
    if anchorBtn then
        -- Opened by a dock tool (see gdsGui_schematic_setMenuAnchorButton):
        -- pinned just left of that tool's button at the canvas's top edge.
        x, y = _toolPopupOrigin(owner, anchorBtn, w)
    elseif menu.isSwatchPicker then
        -- The selected-item color picker is anchored in the bottom third of
        -- the canvas/gallery area (rather than dead-center) so it sits below
        -- the item being edited instead of covering it; clamped back inside
        -- owner bounds in case the band is shorter than the menu itself.
        local bandY = owner.y + owner.h * 2 / 3
        local bandH = owner.h / 3
        y = bandY + (bandH - groupH) / 2
        y = math.max(owner.y, math.min(y, owner.y + owner.h - groupH))
    else
        -- Docked at the bottom, but never above the owner's top edge, so the
        -- title and first rows of a long menu stay on screen and tappable.
        y = math.max(owner.y, owner.y + owner.h - M - totalFor(rowH))
    end

    -- The opening slide, eased out: from just below the owner's bottom edge.
    local reveal = 1
    if sheet and menu._openedAt then
        local t = (love.timer.getTime() - menu._openedAt) / _actionSheet.SLIDE_SECONDS
        if t < 1 then
            reveal = 1 - (1 - math.max(0, t)) ^ 3
            y = y + (1 - reveal) * (owner.y + owner.h - y)
        end
    end

    local layout = { x = x, w = w, y = y, h = groupH, titleH = titleH, rows = {}, cancel = cancel, reveal = reveal }
    local rowY = y + titleH
    if menu.isSwatchPicker then
        layout.swatchY = rowY
        rowY = rowY + swatchH
    end
    for i = firstRow, lastRow do
        table.insert(layout.rows, { index = i, y = rowY, h = rowH })
        rowY = rowY + rowH
    end
    if cancel then cancel.y, cancel.h = y + groupH + _actionSheet.GAP_PX, rowH end
    return layout
end

-- Geometry of one swatch square in a swatch-picker row, by 1-based index.
local function _swatchRect(mx, mw, count, index)
    local totalGap = _SWATCH_GAP_PX * (count + 1)
    local size = (mw - totalGap) / count
    local sx = mx + _SWATCH_GAP_PX + (index - 1) * (size + _SWATCH_GAP_PX)
    return sx, size
end

-- Returns the 1-based index (into menu.options) tapped, "cancel" for the sheet's
-- own CANCEL button, "outside" if the tap missed the menu entirely (both close
-- it), or nil if inside the options group but not on a row/swatch.
local function _menuRowAt(owner, menu, px, py)
    local layout = _menuGeometry(owner, menu)
    local function within(y, h)
        return px >= layout.x and px <= layout.x + layout.w and py >= y and py < y + h
    end
    if layout.cancel and within(layout.cancel.y, layout.cancel.h) then return layout.cancel.hit end
    if not within(layout.y, layout.h) then return "outside" end
    if menu.isSwatchPicker and py >= layout.swatchY and py < layout.swatchY + _SWATCH_ROW_H_PX then
        local n = #menu.swatchColors
        for i = 1, n do
            local sx, size = _swatchRect(layout.x, layout.w, n, i)
            if px >= sx and px <= sx + size then return i end
        end
        return nil
    end
    for _, row in ipairs(layout.rows) do
        if py >= row.y and py < row.y + row.h then return row.index end
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
    -- A press while the menu is still sliding in finishes the slide first, so
    -- the press and its release are hit-tested against the same, settled layout.
    if owner.menu._openedAt then
        owner.menu._openedAt = math.min(owner.menu._openedAt, love.timer.getTime() - _actionSheet.SLIDE_SECONDS)
    end
    owner.menu._pressedHit     = _menuRowAt(owner, owner.menu, px, py)
    owner.menu._pressedTouchId = touchId
    -- Fresh press, fresh hold timer — see _pollMenuHoldToConfirm, which is
    -- what actually fires a confirm row once this reaches
    -- _CONFIRM_HOLD_SECONDS; harmless to reset here even for a non-confirm
    -- menu, since nothing ever reads it without menu.confirmRows set.
    owner.menu._holdElapsed    = 0
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
    if pressedHit == "outside" or pressedHit == "cancel" then
        local cb = menu.onCancel
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name) end
    elseif menu.confirmRows and menu.confirmRows[pressedHit] then
        -- A confirm row (see _markConfirmMenu) only ever fires via a
        -- sustained hold, timed by _pollMenuHoldToConfirm — a plain
        -- tap-release here, however deliberate it looked, is just an
        -- abandoned attempt. The menu stays open so the user can try again.
        return
    elseif menu.toggleStates and type(pressedHit) == "number" then
        -- See gdsGui_schematic_openMenu's own comment on toggleStates: flips
        -- in place and fires onSelect with the new state, but — unlike the
        -- plain-row branch below — leaves owner.menu set so the user can
        -- flip more rows without it closing.
        menu.toggleStates[pressedHit] = not menu.toggleStates[pressedHit]
        gdsGui_haptics_feedback("selection")
        local opt = menu.options[pressedHit]
        local cb = menu.onSelect
        if cb and _G[cb] then _G[cb](owner.name, pressedHit, opt, menu.toggleStates[pressedHit]) end
    elseif type(pressedHit) == "number" then
        local opt = menu.options[pressedHit]
        local cb = menu.onSelect
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name, pressedHit, opt) end
    end
end

-- Polled every frame (from gdsGui_schematic_update/gdsGui_schematicGallery_update)
-- against any owner currently showing a menu: if that menu is a confirm menu
-- (menu.confirmRows set — see _markConfirmMenu) and whichever row is
-- currently pressed is one of its confirm rows, accumulates the hold and
-- fires onSelect the instant it crosses _CONFIRM_HOLD_SECONDS — the same
-- action a completed tap-release would fire on any ordinary menu row, just
-- gated behind a deliberate hold instead of an easy-to-land-by-accident
-- tap. Firing on elapsed time rather than waiting for release is
-- deliberate: a destructive confirm should commit the moment the hold
-- requirement is actually met, not one more gesture after it.
local function _pollMenuHoldToConfirm(owner, dt)
    local menu = owner.menu
    if not menu or not menu.confirmRows then return end
    local pressedIndex = menu._pressedHit
    if menu._pressedTouchId == nil or not menu.confirmRows[pressedIndex] then
        menu._holdElapsed = 0
        return
    end
    menu._holdElapsed = (menu._holdElapsed or 0) + math.min(dt, _CONFIRM_HOLD_MAX_DT)
    if menu._holdElapsed < _CONFIRM_HOLD_SECONDS then return end
    gdsGui_haptics_feedback("warning")
    local opt = menu.options[pressedIndex]
    local cb = menu.onSelect
    owner.menu = nil
    if cb and _G[cb] then _G[cb](owner.name, pressedIndex, opt) end
end

-- One text row's label, in the iOS action color: red for a destructive one, or
-- for a confirm-gated row (menu.confirmRows[idx] — see _markConfirmMenu) its own
-- confirm color, the default red reading as iOS red. holdFrac (optional, 0-1):
-- while a confirm-gated row is being held down (see _pollMenuHoldToConfirm),
-- a left-to-right fill in that color shows how much longer the hold needs,
-- reaching the row's full width just as it fires.
local function _drawMenuTextRow(x, w, y, h, opt, confirmColor, holdFrac, palette)
    local color = palette.action
    if confirmColor then
        local isDefaultRed = confirmColor[1] > 0.6 and confirmColor[2] < 0.3 and confirmColor[3] < 0.3
        if not isDefaultRed then
            local k = (globApp.themeIsDark == false) and _LIGHT_MODE_COLOR_DARKEN or 1
            color = { confirmColor[1] * k, confirmColor[2] * k, confirmColor[3] * k, 1 }
        else
            color = palette.destructive
        end
    elseif _actionSheet.isDestructive(opt) then
        color = palette.destructive
    end
    if holdFrac and holdFrac > 0 then
        love.graphics.setColor(color[1], color[2], color[3], 0.3)
        love.graphics.rectangle("fill", x + 4, y + 3, (w - 8) * math.min(1, holdFrac), h - 6, 6, 6)
    end
    love.graphics.setColor(color)
    love.graphics.printf(opt, x, y + (h - love.graphics.getFont():getHeight()) / 2, w, "center")
end

-- iOS-style ON/OFF switch size, for a toggle-menu row (menu.toggleStates —
-- see gdsGui_schematic_openMenu/_drawMenuToggleRow below). Sized to sit
-- comfortably inside _MENU_ROW_H (anchored menus never use the taller
-- _actionSheet.ROW_H_PX — see _menuGeometry — so this is the only size that
-- has to fit).
_actionSheet.SWITCH_W = 34
_actionSheet.SWITCH_H = 20
-- iOS's own switch green — unlike every other row color above, it does NOT
-- follow DARK/LIGHT (iOS doesn't re-theme its switches either); only the
-- OFF track does, via palette.separator below.
_actionSheet.SWITCH_ON = { 0.20, 0.78, 0.35, 1 }

-- One iOS-style ON/OFF switch, top-left corner at (x, y). isOn selects the
-- green track (true) or the current theme's own separator gray (false,
-- read from palette so it stays legible in both themes); the knob is always
-- white, same as iOS never re-themes its own knob either. A field on
-- _actionSheet (like every helper below it), not a separate local function
-- — this file is already at Lua's 200-top-level-local ceiling (see
-- _shapePoly's own comment on the same constraint).
function _actionSheet.drawSwitch(x, y, isOn, palette)
    local w, h = _actionSheet.SWITCH_W, _actionSheet.SWITCH_H
    local r = h / 2
    love.graphics.setColor(isOn and _actionSheet.SWITCH_ON or palette.separator)
    love.graphics.rectangle("fill", x, y, w, h, r, r)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", isOn and (x + w - r) or (x + r), y + r, r - 2)
end

-- One toggle-menu row (menu.toggleStates — see gdsGui_schematic_openMenu):
-- the label left-aligned (unlike _drawMenuTextRow's centered plain-row
-- text, since the switch itself owns the row's right edge) plus its own
-- ON/OFF switch, always in the row's own themed text color — a toggle row
-- is never destructive/confirm-gated, so it never borrows palette.action/
-- destructive the way a plain row can.
function _actionSheet.drawToggleRow(x, w, y, h, label, isOn, palette)
    local pad = 16
    love.graphics.setColor(palette.text)
    love.graphics.printf(label, x + pad, y + (h - love.graphics.getFont():getHeight()) / 2,
        w - pad * 2 - _actionSheet.SWITCH_W, "left")
    _actionSheet.drawSwitch(x + w - pad - _actionSheet.SWITCH_W, y + (h - _actionSheet.SWITCH_H) / 2, isOn, palette)
end

-- Shared modal-menu drawing for any owner with a .menu (see _menuGeometry for the layout).
local function _drawMenuBox(owner, menu)
    if menu.choiceGrid then return _choiceGrid.draw(owner, menu) end
    if menu.propertyGrid then return _propertyGrid.draw(owner, menu) end
    local now = love.timer.getTime()
    if not menu._openedAt then
        -- One menu straight after another (a cascade, or a menu reopening
        -- itself after a pick) is already up, so it doesn't slide in again.
        local alreadyUp = owner._menuLastDrawnAt and now - owner._menuLastDrawnAt < 0.1
        menu._openedAt = alreadyUp and (now - _actionSheet.SLIDE_SECONDS) or now
    end
    owner._menuLastDrawnAt = now
    local layout = _menuGeometry(owner, menu)
    local palette = (globApp.themeIsDark == false) and _actionSheet.LIGHT or _actionSheet.DARK
    local x, w = layout.x, layout.w
    local pressed = menu._pressedTouchId ~= nil and menu._pressedHit or nil

    love.graphics.setColor(0, 0, 0, 0.4 * layout.reveal)
    love.graphics.rectangle("fill", owner.x, owner.y, owner.w, owner.h)
    -- Mid-slide the sheet starts below the owner's bottom edge; keep it from
    -- drawing over whatever sits there (the dock, the page footer).
    local sx, sy, sw, sh = love.graphics.getScissor()
    local sliding = layout.reveal < 1
    if sliding then love.graphics.intersectScissor(owner.x, owner.y, owner.w, owner.h) end

    -- Same soft elevation shadow a dragged element draws with (see
    -- _selection.beginLift) -- this modal sheet floats above the canvas
    -- too. Faded out mid-slide along with the sheet itself (layout.reveal).
    gdsGui_general_drawShadow(x, layout.y, w, layout.h, _actionSheet.RADIUS_PX, 0, 4, 14, 0.35 * layout.reveal)
    love.graphics.setColor(palette.bg)
    gdsGui_general_drawRoundedRect(x, layout.y, w, layout.h, _actionSheet.RADIUS_PX)
    if menu.title then
        love.graphics.setColor(palette.title)
        love.graphics.printf(menu.title, x, layout.y + 8, w, "center")
    end

    -- Which row (by combined options index — same indexing menu.confirmRows
    -- itself uses, swatches included) is a confirm action currently being
    -- held down, and how far through _CONFIRM_HOLD_SECONDS that hold is.
    local holdIndex, holdFrac
    if menu.confirmRows and pressed and menu.confirmRows[pressed] then
        holdIndex = pressed
        holdFrac = (menu._holdElapsed or 0) / _CONFIRM_HOLD_SECONDS
    end

    if menu.isSwatchPicker then
        if menu.title then
            love.graphics.setColor(palette.separator)
            local hairline = gdsGui_general_hairline()
            love.graphics.rectangle("fill", x, gdsGui_general_pixelCenter(layout.swatchY) - hairline / 2, w, hairline)
        end
        local n = #menu.swatchColors
        local _, firstSize = _swatchRect(x, w, n, 1)
        local sy = layout.swatchY + (_SWATCH_ROW_H_PX - firstSize) / 2
        for i, c in ipairs(menu.swatchColors) do
            local sx, size = _swatchRect(x, w, n, i)
            love.graphics.setColor(_themedPaletteColor(c[1], c[2], c[3], c[4] or 1))
            love.graphics.rectangle("fill", sx, sy, size, size, 4, 4)
            love.graphics.setColor(palette.separator)
            local prevLineWidth = love.graphics.getLineWidth()
            love.graphics.setLineWidth(gdsGui_general_hairline())
            love.graphics.rectangle("line", sx, sy, size, size, 4, 4)
            love.graphics.setLineWidth(prevLineWidth)
        end
    end

    for k, row in ipairs(layout.rows) do
        local atTop = row.y <= layout.y + 0.5
        if pressed == row.index then
            love.graphics.setColor(palette.pressed)
            _actionSheet.fill(x, row.y, w, row.h, atTop, k == #layout.rows)
        end
        if not atTop then
            love.graphics.setColor(palette.separator)
            local hairline = gdsGui_general_hairline()
            love.graphics.rectangle("fill", x, gdsGui_general_pixelCenter(row.y) - hairline / 2, w, hairline)
        end
        if menu.toggleStates then
            _actionSheet.drawToggleRow(x, w, row.y, row.h, menu.options[row.index], menu.toggleStates[row.index], palette)
        else
            _drawMenuTextRow(x, w, row.y, row.h, menu.options[row.index], menu.confirmRows and menu.confirmRows[row.index],
                (row.index == holdIndex) and holdFrac or nil, palette)
        end
    end

    local cancel = layout.cancel
    if cancel then
        if pressed ~= cancel.hit then
            gdsGui_general_drawShadow(x, cancel.y, w, cancel.h, _actionSheet.RADIUS_PX, 0, 4, 14, 0.35 * layout.reveal)
        end
        love.graphics.setColor(pressed == cancel.hit and palette.pressed or palette.bg)
        gdsGui_general_drawRoundedRect(x, cancel.y, w, cancel.h, _actionSheet.RADIUS_PX)
        love.graphics.setColor(palette.action)
        love.graphics.printf(cancel.text, x, cancel.y + (cancel.h - love.graphics.getFont():getHeight()) / 2, w, "center")
    end
    if sliding then love.graphics.setScissor(sx, sy, sw, sh) end
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- PUBLIC API — CHOICE GRID: a modal, scrollable form where every row must get
-- one of a fixed set of choices (e.g. OPEN/CLOSED) before SAVE unlocks. It
-- lives in canvas.menu (menu.choiceGrid set) so it gets the same modal
-- treatment as any other menu — isMenuOpen, input priority, drawing.
-- Tapping outside never closes it: SAVE is the only way out, unless
-- onCancelFunc is given, which adds a CANCEL button beside SAVE (fired as
-- fn(canvasName) after the grid closes, nothing saved).
-- rows: array of {label = string, choice = nil | index into choices}, kept
-- by reference — the app's onChange callback, fn(canvasName, rowIndex,
-- choiceIndex), fires after a tap sets row.choice and may edit other rows
-- (e.g. keep linked rows in agreement). onSave: fn(canvasName), fired once
-- every row has a choice and SAVE is tapped; the grid closes first.
-- header (optional): column caption drawn above the rows.
--------------------------------------------------------------------------------

_choiceGrid.ROW_H, _choiceGrid.FOOTER_H = 46, 44

function gdsGui_schematic_openChoiceGrid(canvasName, title, header, rows, choices, onChangeFunc, onSaveFunc, onCancelFunc)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.annunciatorPanelOpen = false
    canvas.menu = { choiceGrid = true, title = title, header = header, rows = rows, choices = choices,
        onChange = onChangeFunc, onSave = onSaveFunc, onCancel = onCancelFunc, scroll = 0 }
end

-- Footer button rects: SAVE, and CANCEL to its left when the grid has one.
function _choiceGrid.footerButtons(g, menu)
    local y, h = g.footerY + 4, _choiceGrid.FOOTER_H - 8
    if not menu.onCancel then return { save = { x = g.x + 4, y = y, w = g.w - 8, h = h } } end
    local half = (g.w - 12) / 2
    return { cancel = { x = g.x + 4, y = y, w = half, h = h }, save = { x = g.x + 8 + half, y = y, w = half, h = h } }
end

function _choiceGrid.remaining(menu)
    local n = 0
    for _, row in ipairs(menu.rows) do if not row.choice then n = n + 1 end end
    return n
end

-- Box, rows viewport and footer geometry, plus the scroll limit.
function _choiceGrid.geometry(owner, menu)
    local w = owner.w * 0.94
    local titleH = _titleHeight(w, menu.title)
    local headerH = menu.header and _MENU_ROW_H or 0
    -- Rows grow to fit the tallest multi-line label.
    local maxLines = 1
    for _, row in ipairs(menu.rows) do
        local _, breaks = row.label:gsub("\n", "")
        maxLines = math.max(maxLines, breaks + 1)
    end
    local rowH = math.max(_choiceGrid.ROW_H, maxLines * love.graphics.getFont():getHeight() + 14)
    local contentH = #menu.rows * rowH
    local maxBodyH = owner.h * 0.92 - titleH - headerH - _choiceGrid.FOOTER_H
    local bodyH = math.max(rowH, math.min(contentH, maxBodyH))
    local h = titleH + headerH + bodyH + _choiceGrid.FOOTER_H
    local x = owner.x + (owner.w - w) / 2
    local y = owner.y + math.max(0, (owner.h - h) / 2)
    return { x = x, y = y, w = w, h = h, titleH = titleH, headerH = headerH, rowH = rowH,
        bodyY = y + titleH + headerH, bodyH = bodyH, footerY = y + h - _choiceGrid.FOOTER_H,
        maxScroll = math.max(0, contentH - bodyH) }
end

-- The choice cells' x/width within a row: right-hand half of the box, split evenly.
function _choiceGrid.cellRect(g, menu, choiceIndex)
    local areaX = g.x + g.w * 0.5
    local cellW = (g.w * 0.5 - 6) / #menu.choices
    return areaX + (choiceIndex - 1) * cellW, cellW
end

-- {kind = "cell", row, choice} | {kind = "save"} | nil for what (px, py) is on.
function _choiceGrid.hit(owner, menu, px, py)
    local g = _choiceGrid.geometry(owner, menu)
    if px < g.x or px > g.x + g.w then return nil end
    if py >= g.footerY and py <= g.footerY + _choiceGrid.FOOTER_H then
        local cancel = _choiceGrid.footerButtons(g, menu).cancel
        if cancel and px < cancel.x + cancel.w then return { kind = "cancel" } end
        return { kind = "save" }
    end
    if py < g.bodyY or py >= g.bodyY + g.bodyH then return nil end
    local rowIndex = math.floor((py - g.bodyY + menu.scroll) / g.rowH) + 1
    if not menu.rows[rowIndex] then return nil end
    for c = 1, #menu.choices do
        local cx, cw = _choiceGrid.cellRect(g, menu, c)
        if px >= cx and px < cx + cw then return { kind = "cell", row = rowIndex, choice = c } end
    end
    return nil
end

function _choiceGrid.press(owner, touchId, px, py)
    local menu = owner.menu
    if menu._pressedTouchId ~= nil and menu._pressedTouchId ~= touchId then return end
    menu._pressedTouchId, menu._pressY, menu._pressScroll, menu._dragging = touchId, py, menu.scroll, false
end

function _choiceGrid.move(owner, touchId, px, py)
    local menu = owner.menu
    if menu._pressedTouchId ~= touchId then return end
    local dy = py - menu._pressY
    if math.abs(dy) > _ELEMENT_TAP_SLOP_PX then menu._dragging = true end
    if menu._dragging then
        local g = _choiceGrid.geometry(owner, menu)
        menu.scroll = math.max(0, math.min(g.maxScroll, menu._pressScroll - dy))
    end
end

function _choiceGrid.release(owner, touchId, px, py)
    local menu = owner.menu
    if menu._pressedTouchId ~= touchId then return end
    menu._pressedTouchId = nil
    if menu._dragging then return end
    local hit = _choiceGrid.hit(owner, menu, px, py)
    if not hit then return end
    if hit.kind == "cell" then
        menu.rows[hit.row].choice = hit.choice
        if menu.onChange and _G[menu.onChange] then _G[menu.onChange](owner.name, hit.row, hit.choice) end
    elseif hit.kind == "save" and _choiceGrid.remaining(menu) == 0 then
        local cb = menu.onSave
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name) end
    elseif hit.kind == "cancel" then
        local cb = menu.onCancel
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name) end
    end
end

function _choiceGrid.wheel(owner, dy)
    local menu = owner.menu
    local g = _choiceGrid.geometry(owner, menu)
    menu.scroll = math.max(0, math.min(g.maxScroll, menu.scroll - dy * g.rowH))
end

function _choiceGrid.draw(owner, menu)
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", owner.x, owner.y, owner.w, owner.h)
    local g = _choiceGrid.geometry(owner, menu)
    love.graphics.setColor(0.15, 0.15, 0.18, _MENU_OPACITY)
    love.graphics.rectangle("fill", g.x, g.y, g.w, g.h)

    love.graphics.setColor(0.25, 0.25, 0.25, _MENU_OPACITY)
    love.graphics.rectangle("fill", g.x, g.y, g.w, g.titleH)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(menu.title or "", g.x, g.y + 8, g.w, "center")
    if menu.header then
        love.graphics.setColor(1, 1, 1, 0.7)
        love.graphics.printf(menu.header, g.x + 8, g.y + g.titleH + 8, g.w - 16, "left")
    end

    local prevScX, prevScY, prevScW, prevScH = love.graphics.getScissor()
    love.graphics.intersectScissor(g.x, g.bodyY, g.w, g.bodyH)
    for i, row in ipairs(menu.rows) do
        local rowY = g.bodyY + (i - 1) * g.rowH - menu.scroll
        if rowY + g.rowH >= g.bodyY and rowY <= g.bodyY + g.bodyH then
            -- An unanswered row is flagged so the user can find what's left.
            if not row.choice then
                love.graphics.setColor(0.6, 0.15, 0.15, 0.35)
                love.graphics.rectangle("fill", g.x + 2, rowY + 1, g.w - 4, g.rowH - 2)
            end
            -- Labels and choices are printed unwrapped (a label may carry
            -- its own "\n"), vertically centered in the row.
            local font = love.graphics.getFont()
            local _, lineCount = row.label:gsub("\n", "")
            local textY = rowY + (g.rowH - (lineCount + 1) * font:getHeight()) / 2
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.print(row.label, g.x + 8, textY)
            for c, choiceLabel in ipairs(menu.choices) do
                local cx, cw = _choiceGrid.cellRect(g, menu, c)
                if row.choice == c then
                    love.graphics.setColor(1, 1, 0, 1)
                    love.graphics.rectangle("fill", cx + 2, rowY + 4, cw - 4, g.rowH - 8)
                    love.graphics.setColor(0, 0, 0, 1)
                else
                    love.graphics.setColor(1, 1, 1, 0.4)
                    love.graphics.rectangle("line", cx + 2, rowY + 4, cw - 4, g.rowH - 8)
                    love.graphics.setColor(1, 1, 1, 1)
                end
                -- Shrunk to fit a narrow cell rather than spilling past it.
                local textW = font:getWidth(choiceLabel)
                local fit = math.min(1, (cw - 8) / textW)
                love.graphics.print(choiceLabel, cx + (cw - textW * fit) / 2,
                    rowY + (g.rowH - font:getHeight() * fit) / 2, 0, fit, fit)
            end
        end
    end
    if prevScX then love.graphics.setScissor(prevScX, prevScY, prevScW, prevScH) else love.graphics.setScissor() end

    -- Scroll position indicator, only when there's more than fits.
    if g.maxScroll > 0 then
        local barH = g.bodyH * g.bodyH / (g.bodyH + g.maxScroll)
        local barY = g.bodyY + (g.bodyH - barH) * (menu.scroll / g.maxScroll)
        love.graphics.setColor(1, 1, 1, 0.5)
        love.graphics.rectangle("fill", g.x + g.w - 4, barY, 3, barH)
    end

    local remaining = _choiceGrid.remaining(menu)
    local buttons = _choiceGrid.footerButtons(g, menu)
    local font = love.graphics.getFont()
    local function button(rect, label, fill, textAlpha)
        love.graphics.setColor(fill)
        love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)
        love.graphics.setColor(1, 1, 1, textAlpha)
        love.graphics.printf(label, rect.x, rect.y + (rect.h - font:getHeight()) / 2, rect.w, "center")
    end
    if buttons.cancel then button(buttons.cancel, "CANCEL", { 0.35, 0.35, 0.35, 1 }, 1) end
    local saveLabel = remaining == 0 and "SAVE" or (buttons.cancel and (remaining .. " LEFT") or ("SET ALL ROWS (" .. remaining .. " LEFT)"))
    button(buttons.save, saveLabel, remaining == 0 and { 0.15, 0.55, 0.2, 1 } or { 0.3, 0.3, 0.3, 1 }, remaining == 0 and 1 or 0.6)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", g.x, g.y, g.w, g.h)
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- PUBLIC API — PROPERTY GRID: same modal chrome as the CHOICE GRID just
-- above (title bar, scrollable rows, SAVE/CANCEL footer, yellow border) but
-- each row is either a tappable inline text field or, when the row itself
-- asks for it, a fixed set of choice buttons (_choiceGrid's own cell style)
-- — for an element's own free-text custom properties (main.lua's
-- defaultProperties) and, via main.lua's element-placement grid, a few
-- fixed-choice fields like SOURCE TYPE (VDC/VAC) alongside them, all in one
-- scrollable form instead of a drill-down per field. rows: array of
-- {key, label, value = string, choices = nil | array of strings,
-- numericOnly = nil | true}, kept by reference so the app can read back
-- whatever the user entered after SAVE fires, same "rows live on past menu
-- close" convention _relays.editing/_choiceGrid's own callers already rely
-- on. A row with `choices` set renders/behaves exactly like one of
-- _choiceGrid's own rows (tap a cell, it's immediately selected into
-- row.value, onChange fires same as any other edit — no keyboard involved);
-- omitted, it's a free-text box. swatchColors (optional, parallel to
-- choices): each cell filled with its own color instead of the plain
-- yellow-highlight/outline, the swatch itself standing in for the label (no
-- text drawn) — see main.lua's POWERED COLOR row. buttonColors (optional,
-- also parallel to choices): same per-cell fill, but for a choice that
-- reads as an ACTION rather than a value to keep — the label IS still drawn
-- (on top of the fill), and it's never shown "selected" — e.g. main.lua's
-- green "+ ADD LOAD" row, whose onChange opens a whole new grid on tap.
-- numericOnly (text rows only): same digit/one-decimal-point filter
-- gdsGui_textPrompt_open's own numericOnly uses, applied per keystroke by
-- gdsGui_schematic_propertyGridTextInput below. slider = {min, max, unit,
-- format} (optional): a horizontal scrollbar in place of the value box, dragged
-- or tapped in whole steps, with row.value as the number in string form and the
-- current value shown after the row's label (through string.format, if format
-- is given). onChange (optional): called with no arguments after the user edits
-- this row, by typing or by slider, so linked rows can follow it live. requireAll (optional): true
-- gates SAVE on every row having a non-empty value (same "remaining" gate
-- _choiceGrid.remaining enforces); false/omitted lets SAVE commit as-is,
-- blank rows included. validateFunc (optional, a plain Lua function, NOT a
-- by-name string — only ever used library-internally, see
-- _openElementPlacementGrid below): fn(rows) -> true | false, rowIndex,
-- errorText, run right before SAVE actually commits (after the requireAll
-- gate already passed); a false keeps the grid open with that row flagged
-- and errorText shown in place of the header, so e.g. a taken NAME can be
-- caught and retried in place instead of closing and reopening. CANCEL is
-- always offered (unlike _choiceGrid, where it's conditional on
-- fromGateRules) — tapping it or SAVE both close the grid and release the
-- keyboard the same way. Only one row can be mid-edit at a time
-- (menu.activeRow) — LÖVE's own love.keyboard.setTextInput positions a
-- single OS/IME capture region, so this follows the same one-active-field-
-- at-a-time convention textPrompt_gdsGuiLib.lua's single global prompt
-- already established, just inline inside this grid instead of a separate
-- floating popup.
--------------------------------------------------------------------------------

_propertyGrid.ROW_H, _propertyGrid.FOOTER_H = 46, 44
_propertyGrid.MAX_CHARS = 24
_propertyGrid.SLIDER_THUMB_W = 16

-- header (optional): a read-only caption drawn above the rows, same slot
-- _choiceGrid's own header fills — main.lua uses it for an element's sensed
-- values (VOLTAGE/CURRENT, ...), which aren't part of `rows` since they're
-- never editable. While validateFunc has flagged an error (menu.errorText),
-- that takes over this same slot instead — see _propertyGrid.draw.
-- The one title every element/control/connector properties or rules window
-- carries. detail (optional) goes on the line below it, for a window whose
-- rows don't already say which item it's for.
function gdsGui_schematic_elementPropertiesTitle(detail)
    return detail and ("ELEMENT PROPERTIES\n" .. detail) or "ELEMENT PROPERTIES"
end

function gdsGui_schematic_openPropertyGrid(canvasName, title, header, rows, requireAll, onSaveFunc, onCancelFunc, validateFunc)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.annunciatorPanelOpen = false
    canvas.menu = { propertyGrid = true, title = title, header = header, rows = rows, requireAll = requireAll,
        onSave = onSaveFunc, onCancel = onCancelFunc, validate = validateFunc, scroll = 0, activeRow = nil }
    love.keyboard.setTextInput(false)
end

-- Rows with no value yet only count against SAVE when requireAll asked for
-- every row filled in (see openPropertyGrid's own comment).
function _propertyGrid.remaining(menu)
    if not menu.requireAll then return 0 end
    local n = 0
    for _, row in ipairs(menu.rows) do if (row.value or "") == "" then n = n + 1 end end
    return n
end

-- Footer is always SAVE+CANCEL split evenly — no single-button fallback
-- like _choiceGrid.footerButtons has, since this grid's CANCEL is never omitted.
function _propertyGrid.footerButtons(g)
    local y, h = g.footerY + 4, _propertyGrid.FOOTER_H - 8
    local half = (g.w - 12) / 2
    return { cancel = { x = g.x + 4, y = y, w = half, h = h }, save = { x = g.x + 8 + half, y = y, w = half, h = h } }
end

function _propertyGrid.geometry(owner, menu)
    local w = owner.w * 0.94
    local titleH = _titleHeight(w, menu.title)
    -- errorText takes over the header's own slot (see _propertyGrid.draw),
    -- so it reserves the same space whichever of the two is actually showing.
    local headerText = menu.errorText or menu.header
    local headerH = headerText and _titleHeight(w - 16, headerText) or 0
    local rowH = _propertyGrid.ROW_H
    local contentH = math.max(1, #menu.rows) * rowH
    -- Pinned to the top edge (M clear space top and bottom) rather than
    -- vertically centered: NAME auto-focuses the instant this opens (see
    -- _openElementPlacementGrid) and brings up a touch keyboard that eats
    -- the bottom of the screen, so the grid needs all the room above that
    -- keyboard it can get instead of leaving half of it unused above a
    -- box that was centered for a keyboard-less layout.
    local M = _actionSheet.MARGIN_PX
    local maxBodyH = owner.h - M * 2 - titleH - headerH - _propertyGrid.FOOTER_H
    local bodyH = math.max(rowH, math.min(contentH, maxBodyH))
    local h = titleH + headerH + bodyH + _propertyGrid.FOOTER_H
    local x = owner.x + (owner.w - w) / 2
    local y = owner.y + M
    return { x = x, y = y, w = w, h = h, titleH = titleH, headerH = headerH, rowH = rowH,
        bodyY = y + titleH + headerH, bodyH = bodyH, footerY = y + h - _propertyGrid.FOOTER_H,
        maxScroll = math.max(0, contentH - bodyH) }
end

-- The value box's rect within a row — right-hand half, same label-left/
-- control-right split _choiceGrid's own cells use.
function _propertyGrid.valueBoxRect(g, rowY)
    local bx = g.x + g.w * 0.5
    local bw = g.w * 0.5 - 8
    return bx, rowY + 6, bw, g.rowH - 12
end

-- A choice row's own cell rect (one of row.choices) — same right-hand-half,
-- split-evenly layout _choiceGrid.cellRect uses for its own (single, grid-
-- wide) choices array, just per-row here since different rows can offer
-- different choice sets.
function _propertyGrid.cellRect(g, rowY, row, choiceIndex)
    local areaX = g.x + g.w * 0.5
    local cellW = (g.w * 0.5 - 8) / #row.choices
    return areaX + (choiceIndex - 1) * cellW, rowY + 6, cellW, g.rowH - 12
end

-- Sets a slider row's value from a touch at pixel x, across its track (the
-- same rect a text row's value box uses, less the thumb's own width).
function _propertyGrid.setSliderFromX(owner, menu, rowIndex, px)
    local row = menu.rows[rowIndex]
    local g = _propertyGrid.geometry(owner, menu)
    local bx, _, bw = _propertyGrid.valueBoxRect(g, 0)
    local travel = bw - _propertyGrid.SLIDER_THUMB_W
    local t = math.max(0, math.min(1, (px - bx - _propertyGrid.SLIDER_THUMB_W / 2) / travel))
    row.value = tostring(math.floor(row.slider.min + t * (row.slider.max - row.slider.min) + 0.5))
    if row.onChange then row.onChange() end
end

-- {kind = "row", row} | {kind = "choice", row, choice} | {kind = "slider", row} |
-- {kind = "save"} | {kind = "cancel"} | nil.
function _propertyGrid.hit(owner, menu, px, py)
    local g = _propertyGrid.geometry(owner, menu)
    if px < g.x or px > g.x + g.w then return nil end
    if py >= g.footerY and py <= g.footerY + _propertyGrid.FOOTER_H then
        local buttons = _propertyGrid.footerButtons(g)
        if px < buttons.cancel.x + buttons.cancel.w then return { kind = "cancel" } end
        return { kind = "save" }
    end
    if py < g.bodyY or py >= g.bodyY + g.bodyH then return nil end
    local rowIndex = math.floor((py - g.bodyY + menu.scroll) / g.rowH) + 1
    local row = menu.rows[rowIndex]
    if not row then return nil end
    if row.slider then
        return px >= g.x + g.w * 0.5 and { kind = "slider", row = rowIndex } or nil
    end
    if row.choices then
        local rowY = g.bodyY + (rowIndex - 1) * g.rowH - menu.scroll
        for c = 1, #row.choices do
            local cx, _, cw = _propertyGrid.cellRect(g, rowY, row, c)
            if px >= cx and px < cx + cw then return { kind = "choice", row = rowIndex, choice = c } end
        end
        return nil
    end
    return { kind = "row", row = rowIndex }
end

function _propertyGrid.press(owner, touchId, px, py)
    local menu = owner.menu
    if menu._pressedTouchId ~= nil and menu._pressedTouchId ~= touchId then return end
    menu._pressedTouchId, menu._pressY, menu._pressScroll, menu._dragging = touchId, py, menu.scroll, false
    local hit = _propertyGrid.hit(owner, menu, px, py)
    menu._sliderRow = hit and hit.kind == "slider" and hit.row or nil
    if menu._sliderRow then
        menu.activeRow = nil
        menu.errorRow, menu.errorText = nil, nil
        love.keyboard.setTextInput(false)
        _propertyGrid.setSliderFromX(owner, menu, menu._sliderRow, px)
    end
end

function _propertyGrid.move(owner, touchId, px, py)
    local menu = owner.menu
    if menu._pressedTouchId ~= touchId then return end
    -- A press that started on a slider stays on it, wherever the finger
    -- wanders, rather than scrolling the grid.
    if menu._sliderRow then
        _propertyGrid.setSliderFromX(owner, menu, menu._sliderRow, px)
        return
    end
    local dy = py - menu._pressY
    if math.abs(dy) > _ELEMENT_TAP_SLOP_PX then menu._dragging = true end
    if menu._dragging then
        local g = _propertyGrid.geometry(owner, menu)
        menu.scroll = math.max(0, math.min(g.maxScroll, menu._pressScroll - dy))
    end
end

-- Focuses the tapped row's text field (positioning the OS/IME capture
-- region over its on-screen box), or SAVEs/CANCELs the whole grid — a tap
-- that lands on nothing (outside any row, scrolled past the last one)
-- simply blurs whatever row was active, same as tapping away from a normal
-- text field anywhere else in this app.
function _propertyGrid.release(owner, touchId, px, py)
    local menu = owner.menu
    if menu._pressedTouchId ~= touchId then return end
    menu._pressedTouchId = nil
    if menu._sliderRow then
        menu._sliderRow = nil
        return
    end
    if menu._dragging then return end
    local hit = _propertyGrid.hit(owner, menu, px, py)
    if not hit then
        menu.activeRow = nil
        love.keyboard.setTextInput(false)
        return
    end
    if hit.kind == "row" then
        menu.activeRow = hit.row
        menu.errorRow, menu.errorText = nil, nil
        local g = _propertyGrid.geometry(owner, menu)
        local rowY = g.bodyY + (hit.row - 1) * g.rowH - menu.scroll
        love.keyboard.setTextInput(true, _propertyGrid.valueBoxRect(g, rowY))
    elseif hit.kind == "choice" then
        -- One-tap selection, same as _choiceGrid's own cells — no keyboard
        -- involved, so any text field mid-edit elsewhere in this grid is
        -- left exactly as it was.
        local row = menu.rows[hit.row]
        row.value = row.choices[hit.choice]
        menu.errorRow, menu.errorText = nil, nil
        -- Same onChange contract the slider/text paths already honor above
        -- (see openPropertyGrid's own comment) — this is what lets a
        -- choice-row act as a button (e.g. main.lua's "+ ADD LOAD" row)
        -- instead of just a value picker: its onChange can open a whole new
        -- grid on the spot, same as any other row's can react live.
        if row.onChange then row.onChange() end
    elseif hit.kind == "save" and _propertyGrid.remaining(menu) == 0 then
        if menu.validate then
            local ok, badRow, errText = menu.validate(menu.rows)
            if not ok then
                menu.errorRow, menu.errorText = badRow, errText
                return
            end
        end
        local cb = menu.onSave
        owner.menu = nil
        love.keyboard.setTextInput(false)
        if cb and _G[cb] then _G[cb](owner.name) end
    elseif hit.kind == "cancel" then
        local cb = menu.onCancel
        owner.menu = nil
        love.keyboard.setTextInput(false)
        if cb and _G[cb] then _G[cb](owner.name) end
    end
end

function _propertyGrid.wheel(owner, dy)
    local menu = owner.menu
    local g = _propertyGrid.geometry(owner, menu)
    menu.scroll = math.max(0, math.min(g.maxScroll, menu.scroll - dy * g.rowH))
end

-- Whichever canvas/menu currently has a focused property-grid row, or nil —
-- queried by love.textinput/love.keypressed (general_gdsGuiLib.lua) to know
-- whether a keystroke belongs here instead of the single global textPrompt
-- or an inputTxtBox field.
function _propertyGrid.activeTarget()
    for _, canvas in ipairs(globApp.objects.schematics) do
        local menu = canvas.menu
        if menu and menu.propertyGrid and menu.activeRow then return canvas, menu end
    end
    return nil
end

function gdsGui_schematic_propertyGridIsActive()
    return _propertyGrid.activeTarget() ~= nil
end

-- Called from love.textinput when _propertyGridIsActive() — appends straight
-- onto the focused row's own value, capped at MAX_CHARS (silently drops
-- anything past it, same "just stop accepting" behavior maxChars already
-- has elsewhere). row.numericOnly (optional): same digit/one-decimal-point
-- filter gdsGui_textPrompt_textinput's own numericOnly applies, rejecting
-- the whole input event (t can be more than one character on some input
-- methods) rather than stripping just the invalid part — no reject-flash
-- here though, unlike that prompt; this field just silently keeps whatever
-- it already had.
function gdsGui_schematic_propertyGridTextInput(t)
    local _, menu = _propertyGrid.activeTarget()
    if not menu then return end
    local row = menu.rows[menu.activeRow]
    if not row then return end
    if row.numericOnly and t:find("[^%d%.]") then return end
    local combined = (row.value or "") .. t
    if row.numericOnly and combined:find("%..*%.") then return end
    if #combined > _propertyGrid.MAX_CHARS then return end
    row.value = combined
    if row.onChange then row.onChange() end
end

-- Called from love.keypressed when _propertyGridIsActive(). RETURN just
-- blurs the field (hides the keyboard) rather than saving the whole
-- grid — SAVE is its own explicit footer tap, same as every other field
-- here, so one stray RETURN can't commit a grid the user hasn't finished.
function gdsGui_schematic_propertyGridKeypressed(key)
    local _, menu = _propertyGrid.activeTarget()
    if not menu then return end
    local row = menu.rows[menu.activeRow]
    if not row then return end
    if key == "backspace" then
        row.value = (row.value or ""):sub(1, -2)
        if row.onChange then row.onChange() end
    elseif key == "return" or key == "kpenter" then
        menu.activeRow = nil
        love.keyboard.setTextInput(false)
    end
end

function _propertyGrid.draw(owner, menu)
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", owner.x, owner.y, owner.w, owner.h)
    local g = _propertyGrid.geometry(owner, menu)
    love.graphics.setColor(0.15, 0.15, 0.18, _MENU_OPACITY)
    love.graphics.rectangle("fill", g.x, g.y, g.w, g.h)

    love.graphics.setColor(0.25, 0.25, 0.25, _MENU_OPACITY)
    love.graphics.rectangle("fill", g.x, g.y, g.w, g.titleH)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(menu.title or "", g.x, g.y + 8, g.w, "center")
    if menu.errorText then
        love.graphics.setColor(1, 0.4, 0.4, 1)
        love.graphics.printf(menu.errorText, g.x + 8, g.y + g.titleH + 8, g.w - 16, "left")
    elseif menu.header then
        love.graphics.setColor(1, 1, 1, 0.7)
        love.graphics.printf(menu.header, g.x + 8, g.y + g.titleH + 8, g.w - 16, "left")
    end

    local prevScX, prevScY, prevScW, prevScH = love.graphics.getScissor()
    love.graphics.intersectScissor(g.x, g.bodyY, g.w, g.bodyH)
    local font = love.graphics.getFont()
    if #menu.rows == 0 then
        love.graphics.setColor(1, 1, 1, 0.5)
        love.graphics.printf("NO PROPERTIES", g.x, g.bodyY + (g.bodyH - font:getHeight()) / 2, g.w, "center")
    end
    for i, row in ipairs(menu.rows) do
        local rowY = g.bodyY + (i - 1) * g.rowH - menu.scroll
        if rowY + g.rowH >= g.bodyY and rowY <= g.bodyY + g.bodyH then
            -- An unfilled row is flagged the same red tint _choiceGrid uses
            -- for an unanswered one (while requireAll is actually gating
            -- SAVE on it), same as a row validateFunc just rejected.
            if (menu.requireAll and (row.value or "") == "") or menu.errorRow == i then
                love.graphics.setColor(0.6, 0.15, 0.15, 0.35)
                love.graphics.rectangle("fill", g.x + 2, rowY + 1, g.w - 4, g.rowH - 2)
            end
            love.graphics.setColor(1, 1, 1, 1)
            local labelText = row.label
            if row.slider then
                local shown = row.slider.format and string.format(row.slider.format, tonumber(row.value) or 0) or (row.value or "")
                labelText = row.label .. ": " .. shown .. " " .. (row.slider.unit or "")
            end
            love.graphics.print(labelText, g.x + 8, rowY + (g.rowH - font:getHeight()) / 2)

            if row.slider then
                local bx, by, bw, bh = _propertyGrid.valueBoxRect(g, rowY)
                local thumbW = _propertyGrid.SLIDER_THUMB_W
                local t = ((tonumber(row.value) or row.slider.min) - row.slider.min) / (row.slider.max - row.slider.min)
                love.graphics.setColor(1, 1, 1, 0.4)
                love.graphics.rectangle("line", bx, by + bh * 0.25, bw, bh * 0.5)
                love.graphics.setColor(1, 1, 0, 1)
                love.graphics.rectangle("fill", bx + t * (bw - thumbW), by, thumbW, bh)
            elseif row.choices then
                for c, choiceLabel in ipairs(row.choices) do
                    local cx, cy, cw, ch = _propertyGrid.cellRect(g, rowY, row, c)
                    -- swatchColors (optional, parallel to row.choices — e.g.
                    -- main.lua's POWERED COLOR row, or this file's own
                    -- annunciator COLOR row further down): each cell is
                    -- filled with its own actual color instead of the plain
                    -- yellow-highlight/outline every other choice row
                    -- uses — the swatch itself IS the label, so no text is
                    -- drawn over it. Whoever builds the row supplies the
                    -- colors directly (app-side via gdsGui_schematic_
                    -- colorForPaletteName, or library-side straight off
                    -- _ANNUNCIATOR_COLORS) — this grid has no opinion on
                    -- where a choice's color comes from.
                    if row.buttonColors then
                        -- Parallel to swatchColors just below, but for a
                        -- choice that reads as an ACTION (e.g. main.lua's
                        -- green "+ ADD LOAD" row) rather than a value to
                        -- pick and keep — so, unlike a swatch, the label IS
                        -- still drawn on top (a flat color with no text
                        -- wouldn't read as a button). Never shows a
                        -- selected/outlined state: tapping it fires
                        -- row.onChange (see _propertyGrid.release) and the
                        -- row typically closes or rebuilds the grid right
                        -- away instead of sitting "selected".
                        local btn = row.buttonColors[c] or { 0.3, 0.3, 0.3, 1 }
                        love.graphics.setColor(btn[1], btn[2], btn[3], btn[4] or 1)
                        love.graphics.rectangle("fill", cx + 2, cy, cw - 4, ch)
                        love.graphics.setColor(1, 1, 1, 1)
                        local textW = font:getWidth(choiceLabel)
                        local fit = math.min(1, (cw - 8) / textW)
                        love.graphics.print(choiceLabel, cx + (cw - textW * fit) / 2,
                            cy + (ch - font:getHeight() * fit) / 2, 0, fit, fit)
                    elseif row.swatchColors then
                        local swatch = row.swatchColors[c] or { 0.3, 0.3, 0.3, 1 }
                        love.graphics.setColor(swatch[1], swatch[2], swatch[3], swatch[4] or 1)
                        love.graphics.rectangle("fill", cx + 2, cy, cw - 4, ch)
                        if row.value == choiceLabel then
                            love.graphics.setColor(1, 1, 0, 1)
                            love.graphics.rectangle("line", cx + 1, cy - 1, cw - 2, ch + 2)
                        else
                            love.graphics.setColor(1, 1, 1, 0.4)
                            love.graphics.rectangle("line", cx + 2, cy, cw - 4, ch)
                        end
                    elseif row.value == choiceLabel then
                        love.graphics.setColor(1, 1, 0, 1)
                        love.graphics.rectangle("fill", cx + 2, cy, cw - 4, ch)
                        love.graphics.setColor(0, 0, 0, 1)
                        local textW = font:getWidth(choiceLabel)
                        local fit = math.min(1, (cw - 8) / textW)
                        love.graphics.print(choiceLabel, cx + (cw - textW * fit) / 2,
                            cy + (ch - font:getHeight() * fit) / 2, 0, fit, fit)
                    else
                        love.graphics.setColor(1, 1, 1, 0.4)
                        love.graphics.rectangle("line", cx + 2, cy, cw - 4, ch)
                        love.graphics.setColor(1, 1, 1, 1)
                        local textW = font:getWidth(choiceLabel)
                        local fit = math.min(1, (cw - 8) / textW)
                        love.graphics.print(choiceLabel, cx + (cw - textW * fit) / 2,
                            cy + (ch - font:getHeight() * fit) / 2, 0, fit, fit)
                    end
                end
            else
                local bx, by, bw, bh = _propertyGrid.valueBoxRect(g, rowY)
                local active = menu.activeRow == i
                if active then love.graphics.setColor(1, 1, 0, 1) else love.graphics.setColor(1, 1, 1, 1) end
                love.graphics.rectangle(active and "fill" or "line", bx, by, bw, bh)

                local value = row.value or ""
                local showPlaceholder = value == "" and not active
                if active then
                    love.graphics.setColor(0, 0, 0, 1)
                else
                    love.graphics.setColor(1, 1, 1, showPlaceholder and 0.4 or 1)
                end
                -- Trailing "|" while focused — same static (non-blinking)
                -- cursor convention gdsGui_textPrompt_draw's own buffer uses.
                local text = showPlaceholder and "TAP TO ENTER" or (active and (value .. "|") or value)
                love.graphics.print(text, bx + 6, by + (bh - font:getHeight()) / 2)
            end
        end
    end
    if prevScX then love.graphics.setScissor(prevScX, prevScY, prevScW, prevScH) else love.graphics.setScissor() end

    if g.maxScroll > 0 then
        local barH = g.bodyH * g.bodyH / (g.bodyH + g.maxScroll)
        local barY = g.bodyY + (g.bodyH - barH) * (menu.scroll / g.maxScroll)
        love.graphics.setColor(1, 1, 1, 0.5)
        love.graphics.rectangle("fill", g.x + g.w - 4, barY, 3, barH)
    end

    local remaining = _propertyGrid.remaining(menu)
    local buttons = _propertyGrid.footerButtons(g)
    local function button(rect, label, fill, textAlpha)
        love.graphics.setColor(fill)
        love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)
        love.graphics.setColor(1, 1, 1, textAlpha)
        love.graphics.printf(label, rect.x, rect.y + (rect.h - font:getHeight()) / 2, rect.w, "center")
    end
    button(buttons.cancel, "CANCEL", { 0.35, 0.35, 0.35, 1 }, 1)
    local saveLabel = remaining == 0 and "SAVE" or (remaining .. " LEFT")
    button(buttons.save, saveLabel, remaining == 0 and { 0.15, 0.55, 0.2, 1 } or { 0.3, 0.3, 0.3, 1 }, remaining == 0 and 1 or 0.6)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", g.x, g.y, g.w, g.h)
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- PUBLIC API — BUILT-IN COLOR PICKER (opens a swatch-style menu: one row of
-- actual-color squares, one per _COLOR_PALETTE entry, plus any extraOptions
-- as ordinary text rows below — e.g. "DELETE" for the element-edit menu
-- further down). extraOptions are appended to the shared options list so
-- hit-testing/selection still indexes into one combined array.
--------------------------------------------------------------------------------

local function _openSwatchColorMenu(canvasName, title, extraOptions, onSelectFunc, onCancelFunc, palette)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local options, swatchColors = {}, {}
    for _, entry in ipairs(palette or _COLOR_PALETTE) do
        table.insert(options, entry.name)
        table.insert(swatchColors, entry.color)
    end
    for _, opt in ipairs(extraOptions or {}) do table.insert(options, opt) end
    canvas.menu = {
        title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc,
        isSwatchPicker = true, swatchColors = swatchColors, extraOptions = extraOptions or {},
        anchorButtonName = canvas._menuAnchorButtonName,
    }
end

function gdsGui_schematic_openColorPicker(canvasName, targetKind, targetId, title)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas._colorPickTarget = { kind = targetKind, id = targetId }
    _openSwatchColorMenu(canvasName, title or "PICK COLOR", {},
        "gdsGui_schematic_internal_onColorPicked", "gdsGui_schematic_internal_onColorPickCancelled")
end

-- Same swatch-style picker as gdsGui_schematic_openColorPicker above, but
-- not tied to writing any one element/wire/control's pendingColor — the
-- app layer's own onSelectFuncName (resolved by name, called as
-- (canvasName, index), same signature gdsGui_schematic_internal_onColorPicked
-- itself gets) decides what the chosen color means. Lets app-layer code
-- (e.g. an inference-model medium's user-configurable powered/unpowered
-- display colors) reuse the same swatch UI without the library needing to
-- know anything about what's being colored.
function gdsGui_schematic_openGenericColorPicker(canvasName, title, onSelectFuncName, onCancelFuncName)
    _openSwatchColorMenu(canvasName, title or "PICK COLOR", {}, onSelectFuncName, onCancelFuncName)
end

-- Read-only lookup into the same 5-entry _COLOR_PALETTE every swatch picker
-- draws from, by the 1-based index a swatch picker's onSelect callback
-- receives. Returns color, name (both nil if index is out of range) — lets
-- app-layer code resolve what was actually picked, the same way
-- gdsGui_schematic_internal_onColorPicked does internally.
function gdsGui_schematic_getColorPaletteEntry(index)
    local entry = _COLOR_PALETTE[index]
    return entry and entry.color, entry and entry.name
end

-- By-name siblings of the by-index lookup above — used by a propertyGrid
-- swatch row (see _openPropertiesMenu's own POWERED COLOR row and
-- _propertyGrid.draw's own row.swatchColors), where the chosen value is
-- stored as the palette entry's NAME (a plain row.value string, same as
-- any other choice row)
-- rather than an index. gdsGui_schematic_getColorPaletteNames feeds that
-- row's own `choices` list.
function gdsGui_schematic_getColorPaletteNames()
    local names = {}
    for _, entry in ipairs(_COLOR_PALETTE) do table.insert(names, entry.name) end
    return names
end

function gdsGui_schematic_colorForPaletteName(name)
    for _, entry in ipairs(_COLOR_PALETTE) do
        if entry.name == name then return entry.color end
    end
    return nil
end

-- Reverse of the above — which palette entry (if any) an already-resolved
-- color matches, so a row can be pre-filled with its current selection.
function gdsGui_schematic_colorPaletteNameForColor(color)
    if not color then return nil end
    for _, entry in ipairs(_COLOR_PALETTE) do
        local c = entry.color
        if math.abs(c[1] - color[1]) < 0.01 and math.abs(c[2] - color[2]) < 0.01
           and math.abs(c[3] - color[3]) < 0.01 and math.abs((c[4] or 1) - (color[4] or 1)) < 0.01 then
            return entry.name
        end
    end
    return nil
end

function gdsGui_schematic_setPendingColor(canvasName, targetKind, targetId, color)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local target = _findByKind(canvas, targetKind, targetId)
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
-- PAINT MODE — vertical swatch palette (see the PUBLIC API block above) and
-- the press/release handling further down that uses it. Reuses
-- _COLOR_PALETTE, the same 5 named colors the old per-item edit-menu swatch
-- row and the control-mode color picker both draw from.
--------------------------------------------------------------------------------

local _PAINT_SWATCH_SIZE_PX   = 34
-- No gap: the swatches sit flush as one rounded iOS action-sheet group (see
-- gdsGui_schematic_drawPaintOverlay), separated only by hairlines, rather
-- than floating as separate squares.
local _PAINT_SWATCH_GAP_PX    = 0

-- Opens just left of the PAINT button, top-aligned with the canvas (the
-- shared dock-tool popup origin, see _toolPopupOrigin) so the palette reads
-- as "opened out of" the button that armed it, rather than as an unrelated
-- panel elsewhere on the canvas — a fixed screen-space stack independent of pan/zoom, same
-- convention as the modal menu box (_menuGeometry), so it stays put and
-- legible regardless of what's underneath it. Falls back to the canvas's own
-- left edge, vertically centered, if the app never registered a button name.
local function _paintPaletteGeometry(canvas)
    local n = #_COLOR_PALETTE
    local totalH = n * _PAINT_SWATCH_SIZE_PX + (n - 1) * _PAINT_SWATCH_GAP_PX
    local btn = _findButton(canvas._paintButtonName)
    if btn then
        local x, y = _toolPopupOrigin(canvas, btn, _PAINT_SWATCH_SIZE_PX)
        return x, y, _PAINT_SWATCH_SIZE_PX, totalH
    end
    local x = canvas.x + _TOOL_POPUP_GAP_PX
    local y = canvas.y + (canvas.h - totalH) / 2
    return x, y, _PAINT_SWATCH_SIZE_PX, totalH
end

local function _paintSwatchRect(canvas, index)
    local x, y, size = _paintPaletteGeometry(canvas)
    return x, y + (index - 1) * (size + _PAINT_SWATCH_GAP_PX), size, size
end

-- Returns the 1-based _COLOR_PALETTE index tapped, "panel" if the tap landed
-- inside the palette's bounding box but between swatches (still consumed —
-- only a tap that misses the panel ENTIRELY counts as "elsewhere" and exits
-- paint mode, see gdsGui_schematic_pressed), or nil if it missed outright.
local function _paintPaletteHit(canvas, px, py)
    local x, y, size, totalH = _paintPaletteGeometry(canvas)
    if px < x or px > x + size or py < y or py > y + totalH then return nil end
    for i = 1, #_COLOR_PALETTE do
        local sx, sy, sw, sh = _paintSwatchRect(canvas, i)
        if py >= sy and py < sy + sh then return i end
    end
    return "panel"
end

-- Applies a paint-mode color pick to an element/wire/control's base
-- defaultColor — the same permanent-appearance semantics the removed
-- per-item edit-menu color swatches used (see gdsGui_schematic_
-- internal_onElementEditChosen's own comment on why pendingColor is also
-- set: without it, resolveColor would fall through past this pick — to a
-- snapshot, a model-layer prediction, or the bare default — until the next
-- combination change forces a re-resolve).
local function _applyPaint(canvas, targetKind, targetId, color)
    local target = _findByKind(canvas, targetKind, targetId)
    if not target then return end
    _pushUndo(canvas)
    target.defaultColor = color
    target.pendingColor = color
    _notifyChanged(canvas)
end

-- Drawn alongside the modal-menu overlay (gdsGui_schematic_drawMenuOverlay,
-- see its own comment on why that's called LAST in the app's love.draw,
-- after the floating chrome buttons) so the palette renders on top of
-- everything — but unlike a modal, canvas items underneath stay tappable.
-- Styled as one rounded iOS action-sheet group (see _actionSheet, used by
-- every modal menu in this file) even though this is a persistent, non-modal
-- popup: a themed rounded-rect body behind the flush swatch stack, hairlines
-- between them, and the active brush marked with the sheet's own action-blue
-- ring instead of a plain white one.
function gdsGui_schematic_drawPaintOverlay(pageName)
    local palette = (globApp.themeIsDark == false) and _actionSheet.LIGHT or _actionSheet.DARK
    local hairline = gdsGui_general_hairline()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName and canvas.paintMode then
            local activeColor = canvas.paintMode.color
            local x, y, size, totalH = _paintPaletteGeometry(canvas)
            love.graphics.setColor(palette.bg)
            love.graphics.rectangle("fill", x, y, size, totalH, _actionSheet.RADIUS_PX, _actionSheet.RADIUS_PX)
            local n = #_COLOR_PALETTE
            for i, entry in ipairs(_COLOR_PALETTE) do
                local sx, sy, sw, sh = _paintSwatchRect(canvas, i)
                love.graphics.setColor(_themedPaletteColor(entry.color[1], entry.color[2], entry.color[3], entry.color[4] or 1))
                if i == 1 or i == n then
                    _actionSheet.fill(sx, sy, sw, sh, i == 1, i == n)
                else
                    love.graphics.rectangle("fill", sx, sy, sw, sh)
                end
                if i > 1 then
                    love.graphics.setColor(palette.separator)
                    love.graphics.rectangle("fill", sx, gdsGui_general_pixelCenter(sy) - hairline / 2, sw, hairline)
                end
                -- Compared against the raw (undarkened) entry.color, same as
                -- activeColor itself (canvas.paintMode.color is set straight
                -- from a palette entry, never the themed display variant) —
                -- the "is this swatch the active brush" check, unlike the
                -- fill color just above, isn't a themed draw.
                local isActive = activeColor and activeColor[1] == entry.color[1] and
                    activeColor[2] == entry.color[2] and activeColor[3] == entry.color[3]
                if isActive then
                    love.graphics.setColor(palette.action)
                    love.graphics.setLineWidth(3)
                    love.graphics.rectangle("line", sx + 1.5, sy + 1.5, sw - 3, sh - 3, 4, 4)
                    love.graphics.setLineWidth(1)
                end
            end
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- ANNUNCIATORS — a catalog-wide "element" (see main.lua's ADD cascade, which
-- offers it alongside every system's own items rather than nested under one)
-- with no canvas position of its own: named and colored once at creation
-- (gdsGui_schematic_armAnnunciatorCreation above), then only ever toggled
-- active/inactive afterward via the slide-out management panel below. Every
-- active one lists alphabetically, by name, in its own color, in a black
-- readout screen pinned to the content's own top-left world corner — a
-- fixed base footprint that grows/shrinks with canvas.zoom exactly like any
-- other element (_drawAnnunciators, see its own comment); an inactive one
-- simply isn't listed.
--------------------------------------------------------------------------------

local function _findAnnunciator(canvas, id)
    for _, a in ipairs(canvas.annunciators) do
        if a.id == id then return a end
    end
    return nil
end

-- Every annunciator on this canvas, alphabetically by label — shared by the
-- management panel (all of them, active or not) and the on-canvas stack
-- (_drawAnnunciators, active-only — see its own filter).
local function _sortedAnnunciators(canvas)
    local list = {}
    for _, a in ipairs(canvas.annunciators) do table.insert(list, a) end
    table.sort(list, function(a, b) return (a.label or ""):lower() < (b.label or ""):lower() end)
    return list
end

-- Finishes what gdsGui_schematic_armAnnunciatorCreation above started: name
-- already confirmed (pending.confirmedName), now pick one of the fixed 4
-- annunciator colors. Reuses the same generic swatch-picker menu machinery
-- element/wire/control color-picking uses (_openSwatchColorMenu), just with
-- _ANNUNCIATOR_COLORS in place of the default _COLOR_PALETTE.
_openAnnunciatorColorMenu = function(canvasName)
    _openSwatchColorMenu(canvasName, "ANNUNCIATOR COLOR", {},
        "gdsGui_schematic_internal_onAnnunciatorColorChosen",
        "gdsGui_schematic_internal_onAnnunciatorColorCancelled", _ANNUNCIATOR_COLORS)
end

function gdsGui_schematic_internal_onAnnunciatorColorChosen(canvasName, index)
    local pending = _pendingNamedPlacement
    _pendingNamedPlacement = nil
    if not pending or pending.canvasName ~= canvasName or pending.kind ~= "annunciator" then return end
    local entry = _ANNUNCIATOR_COLORS[index]
    if not entry then return end
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    _pushUndo(canvas)
    canvas._placementCounter = canvas._placementCounter + 1
    local newId = "ANNUNCIATOR_" .. canvas._placementCounter
    table.insert(canvas.annunciators,
        { id = newId, label = pending.confirmedName, color = entry.color, active = true })
    _notifyChanged(canvas)
end

function gdsGui_schematic_internal_onAnnunciatorColorCancelled(canvasName)
    -- Tapping outside the color menu abandons the whole creation, same as
    -- cancelling the name prompt itself — there's no partial "named but
    -- uncolored" annunciator left lying around.
    local pending = _pendingNamedPlacement
    if pending and pending.canvasName == canvasName and pending.kind == "annunciator" then
        _pendingNamedPlacement = nil
    end
end

-- Restores one annunciator exactly as saved (app-layer load — see main.lua's
-- _openSystemIntoCanvas, parallel to gdsGui_schematic_addElement/addControl).
-- The creation flow above (gdsGui_schematic_internal_onAnnunciatorColorChosen)
-- builds its own entry inline rather than calling this, since it also needs
-- to mint a fresh id via _placementCounter instead of restoring a saved one.
function gdsGui_schematic_addAnnunciator(canvasName, id, label, color, active)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    _resyncPlacementCounter(canvas, id)
    table.insert(canvas.annunciators, { id = id, label = label, color = color, active = (active ~= false) })
end

-- Reached via the management panel's edit menu (DELETE, hold-to-confirm) —
-- see gdsGui_schematic_internal_onAnnunciatorEditChosen further down. An
-- annunciator has no wires/position of its own to also clean up, so this is
-- simpler than gdsGui_schematic_removeElement/removeControl above.
function gdsGui_schematic_removeAnnunciator(canvasName, id)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    for i = #canvas.annunciators, 1, -1 do
        if canvas.annunciators[i].id == id then table.remove(canvas.annunciators, i) end
    end
end

-- Toggled by a tap on its row in the management panel (see
-- _handleAnnunciatorPanelRelease below) — not undoable (matches every other
-- plain status flip in this file, e.g. cycling a control in control mode),
-- but still persisted (_notifyChanged) so it survives navigating away.
function gdsGui_schematic_setAnnunciatorActive(canvasName, id, active)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local a = _findAnnunciator(canvas, id)
    if not a then return end
    a.active = active
    _notifyChanged(canvas)
end

-- Tells the management panel which app button to cascade (leftward) from —
-- same one-time registration convention as gdsGui_schematic_setPaintButtonName.
function gdsGui_schematic_setAnnunciatorButtonName(canvasName, buttonName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas._annunciatorButtonName = buttonName end
end

function gdsGui_schematic_setAnnunciatorPanelOpen(canvasName, open)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    if open then
        -- Only one of paint mode / a catalog placement / this panel is ever
        -- active at a time — same discipline gdsGui_schematic_armPaintMode
        -- already follows via this same call.
        gdsGui_schematic_cancelPlacement(canvasName)
        canvas.menu = nil
    end
    canvas.annunciatorPanelOpen = open
    canvas.annunciatorPanelScroll = 0
end

function gdsGui_schematic_isAnnunciatorPanelOpen(canvasName)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and canvas.annunciatorPanelOpen == true
end

local _ANNUNCIATOR_ROW_H_PX    = 32
local _ANNUNCIATOR_SWATCH_PX   = 16
local _ANNUNCIATOR_PANEL_W_PX  = 170
local _ANNUNCIATOR_PANEL_MAX_VISIBLE_ROWS = 6

-- Opens just left of the ANNUNCIATOR dock button at the canvas's top edge
-- (the shared dock-tool popup origin, see _toolPopupOrigin), capped at
-- _ANNUNCIATOR_PANEL_MAX_VISIBLE_ROWS tall regardless of how many
-- annunciators exist — the drag-to-scroll handling further down is what
-- brings the rest into view, so a long list never eats the whole canvas (the
-- "make the list scrollable" requirement). Returns the sorted list alongside
-- the geometry since every caller needs both together.
local function _annunciatorPanelGeometry(canvas)
    local list = _sortedAnnunciators(canvas)
    local n = #list
    local visibleRows = math.max(1, math.min(n, _ANNUNCIATOR_PANEL_MAX_VISIBLE_ROWS))
    local headerH = _ANNUNCIATOR_ROW_H_PX
    local bodyH = visibleRows * _ANNUNCIATOR_ROW_H_PX
    local w, h = _ANNUNCIATOR_PANEL_W_PX, headerH + bodyH
    local btn = _findButton(canvas._annunciatorButtonName)
    local x, y
    if btn then
        x, y = _toolPopupOrigin(canvas, btn, w)
    else
        x = canvas.x + canvas.w - w - _TOOL_POPUP_GAP_PX
        y = canvas.y + _TOOL_POPUP_GAP_PX
    end
    return x, y, w, h, headerH, bodyH, list
end

local function _annunciatorMaxScroll(list, bodyH)
    return math.max(0, #list * _ANNUNCIATOR_ROW_H_PX - bodyH)
end

-- Returns "outside" (tap missed the panel box entirely), "header", a 1-based
-- index into the sorted list (a row — may be scrolled fully/partially out of
-- the visible body; callers check against bodyH themselves), or nil (inside
-- the box, below the last row, on no row at all).
local function _annunciatorRowAt(canvas, px, py)
    local x, y, w, h, headerH, bodyH, list = _annunciatorPanelGeometry(canvas)
    if px < x or px > x + w or py < y or py > y + h then return "outside" end
    if py < y + headerH then return "header" end
    local scroll = canvas.annunciatorPanelScroll or 0
    local rowIdx = math.floor((py - y - headerH + scroll) / _ANNUNCIATOR_ROW_H_PX) + 1
    if rowIdx >= 1 and rowIdx <= #list then return rowIdx end
    return nil
end

-- Press/move/release for the panel: a plain tap on a row toggles it; a
-- vertical drag scrolls the list — same tap-vs-drag _ELEMENT_TAP_SLOP_PX
-- distinction, and the same "only the first finger down is tracked" rule,
-- every other gesture/menu in this file uses. A tap-and-HOLD on a row (no
-- drag) instead opens its rename/delete edit menu — see the
-- canvas._annunciatorPanelLongPressElapsed poll in gdsGui_schematic_update —
-- so a plain tap keeps doing the frequent in-flight action (toggling active)
-- while the rarer edit actions stay a deliberate long-press away, same
-- "tap operates, long-press edits" split every on-canvas element/control/
-- wire already uses. Called from gdsGui_schematic_pressed/_moved/_released
-- while canvas.annunciatorPanelOpen,
-- at the same priority canvas.menu gets (a tap anywhere on the canvas while
-- the panel is open is consumed here, never falls through to normal
-- selection/pan — the panel is effectively a lightweight modal, closed by
-- pressing the ANNUNCIATOR dock button again or tapping empty canvas space
-- outside it).
local function _handleAnnunciatorPanelPress(canvas, touchId, px, py)
    if canvas._annunciatorPanelTouchId ~= nil and canvas._annunciatorPanelTouchId ~= touchId then return end
    canvas._annunciatorPanelTouchId    = touchId
    canvas._annunciatorPanelPressedHit = _annunciatorRowAt(canvas, px, py)
    canvas._annunciatorPanelDragStartY = py
    canvas._annunciatorPanelDragStartScroll = canvas.annunciatorPanelScroll or 0
    canvas._annunciatorPanelMoved = false
    canvas._annunciatorPanelLongPressElapsed = 0
end

local function _handleAnnunciatorPanelMove(canvas, touchId, px, py)
    if canvas._annunciatorPanelTouchId ~= touchId then return end
    local dy = py - canvas._annunciatorPanelDragStartY
    if not canvas._annunciatorPanelMoved and
       math.abs(dy) <= _ELEMENT_TAP_SLOP_PX then return end
    canvas._annunciatorPanelMoved = true
    local _, _, _, _, _, bodyH, list = _annunciatorPanelGeometry(canvas)
    local maxScroll = _annunciatorMaxScroll(list, bodyH)
    canvas.annunciatorPanelScroll =
        math.max(0, math.min(maxScroll, canvas._annunciatorPanelDragStartScroll - dy))
end

local function _handleAnnunciatorPanelRelease(canvas, touchId, px, py)
    if canvas._annunciatorPanelTouchId ~= touchId then return end
    local pressedHit = canvas._annunciatorPanelPressedHit
    local moved       = canvas._annunciatorPanelMoved
    canvas._annunciatorPanelTouchId    = nil
    canvas._annunciatorPanelPressedHit = nil
    canvas._annunciatorPanelMoved      = false
    if moved or type(pressedHit) ~= "number" then return end
    if _annunciatorRowAt(canvas, px, py) ~= pressedHit then return end
    local list = _sortedAnnunciators(canvas)
    local a = list[pressedHit]
    if a then gdsGui_schematic_setAnnunciatorActive(canvas.name, a.id, not a.active) end
end

-- Drawn alongside the paint palette / modal menu overlay (see
-- gdsGui_schematic_drawPaintOverlay's own comment on draw-last ordering) so
-- the panel renders on top of the canvas content underneath it. Styled like
-- the iOS action sheet (_actionSheet) every other menu in this file uses —
-- same themed rounded group, gray title, and hairline row separators —
-- even though this one isn't built on _menuGeometry/_drawMenuBox (it's a
-- persistent toggle list, not a modal pick-one-and-close menu).
local function _drawAnnunciatorPanel(canvas)
    local x, y, w, h, headerH, bodyH, list = _annunciatorPanelGeometry(canvas)
    local palette = (globApp.themeIsDark == false) and _actionSheet.LIGHT or _actionSheet.DARK
    local hairline = gdsGui_general_hairline()

    love.graphics.setColor(palette.bg)
    love.graphics.rectangle("fill", x, y, w, h, _actionSheet.RADIUS_PX, _actionSheet.RADIUS_PX)

    love.graphics.setFont(globApp.appFont or love.graphics.getFont())
    love.graphics.setColor(palette.title)
    love.graphics.printf("ANNUNCIATORS", x, y + (headerH - love.graphics.getFont():getHeight()) / 2, w, "center")
    love.graphics.setColor(palette.separator)
    love.graphics.rectangle("fill", x, gdsGui_general_pixelCenter(y + headerH) - hairline / 2, w, hairline)

    -- Only a plain tap-and-hold (not a drag that's scrolling the list) reads
    -- as "pressed" — same touch-up-inside feel _drawMenuBox's own row
    -- highlight gives every other menu.
    local pressedRow = (canvas._annunciatorPanelTouchId ~= nil and not canvas._annunciatorPanelMoved)
        and canvas._annunciatorPanelPressedHit or nil

    love.graphics.setScissor(x, y + headerH, w, bodyH)
    local scroll = canvas.annunciatorPanelScroll or 0
    for i, a in ipairs(list) do
        local rowY = y + headerH + (i - 1) * _ANNUNCIATOR_ROW_H_PX - scroll
        if rowY + _ANNUNCIATOR_ROW_H_PX > y + headerH and rowY < y + headerH + bodyH then
            if i == pressedRow then
                love.graphics.setColor(palette.pressed)
                _actionSheet.fill(x, rowY, w, _ANNUNCIATOR_ROW_H_PX, false, i == #list)
            end
            if i > 1 then
                love.graphics.setColor(palette.separator)
                love.graphics.rectangle("fill", x, gdsGui_general_pixelCenter(rowY) - hairline / 2, w, hairline)
            end
            local swX = x + 10
            local swY = rowY + (_ANNUNCIATOR_ROW_H_PX - _ANNUNCIATOR_SWATCH_PX) / 2
            if a.active then
                love.graphics.setColor(_themedPaletteColor(a.color[1], a.color[2], a.color[3], a.color[4] or 1))
                love.graphics.rectangle("fill", swX, swY, _ANNUNCIATOR_SWATCH_PX, _ANNUNCIATOR_SWATCH_PX, 4, 4)
                love.graphics.setColor(palette.separator)
                love.graphics.setLineWidth(hairline)
                love.graphics.rectangle("line", swX, swY, _ANNUNCIATOR_SWATCH_PX, _ANNUNCIATOR_SWATCH_PX, 4, 4)
                love.graphics.setLineWidth(1)
                love.graphics.setColor(palette.text)
            else
                -- Grayed out: no fill, dim outline, dim label — matches the
                -- "deactivated annunciators are grayed out" requirement.
                love.graphics.setColor(palette.textDim)
                love.graphics.rectangle("line", swX, swY, _ANNUNCIATOR_SWATCH_PX, _ANNUNCIATOR_SWATCH_PX, 4, 4)
                love.graphics.setColor(palette.textDim)
            end
            love.graphics.printf(a.label or a.id, swX + _ANNUNCIATOR_SWATCH_PX + 8,
                rowY + (_ANNUNCIATOR_ROW_H_PX - love.graphics.getFont():getHeight()) / 2,
                w - (_ANNUNCIATOR_SWATCH_PX + 26), "left")
        end
    end
    love.graphics.setScissor()
    love.graphics.setColor(1, 1, 1, 1)
end

function gdsGui_schematic_drawAnnunciatorPanelOverlay(pageName)
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName and canvas.annunciatorPanelOpen then
            _drawAnnunciatorPanel(canvas)
        end
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ANNUNCIATOR EDIT MENU (rename + properties +
-- delete, opened by a tap-and-HOLD on a row in the management panel — see
-- the canvas._annunciatorPanelLongPressElapsed poll in
-- gdsGui_schematic_update and _handleAnnunciatorPanelPress/
-- _annunciatorRowAt above). A plain tap keeps toggling active/inactive;
-- this is the deliberate-hold path to the rarer rename/properties/delete
-- actions, same split the element/control/wire edit menus use between a tap
-- (opens their menu) and a held drag (moves them). PROPERTIES opens the
-- exact same propertyGrid chrome every element/control's own PROPERTIES
-- option does (_propertyGrid.draw) — just a COLOR swatch row for now (see
-- _openAnnunciatorPropertiesMenu below); more rows (actual configurable
-- RULES, not just color) are deliberately left for later, same deferred
-- scope _relays' own "future work" comments elsewhere use. COLOR writes
-- straight to the annunciator's own .color field, same immediate-mutation
-- convention RENAME uses below — UNLIKE the element/wire/control edit
-- menus, which dropped their own embedded color row in favor of paint
-- mode's pendingColor/snapshot workflow: an annunciator's color is a flat,
-- always-on property (never participates in paint mode or per-combination
-- snapshots), so there's nothing to hand off to there.
--------------------------------------------------------------------------------

-- DELETE sits last (index 3) and is passed as this menu's own confirmIndex
-- (see gdsGui_schematic_openMenu/_markConfirmMenu) — holding IT down for
-- _CONFIRM_HOLD_SECONDS is the entire confirmation, no separate "DELETE
-- \"X\"?" popup involved. RENAME/PROPERTIES stay plain-tap rows in the same menu.
function gdsGui_schematic_openAnnunciatorEditMenu(canvasName, annunciatorId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local a = _findAnnunciator(canvas, annunciatorId)
    if not a then return end
    canvas._annunciatorEditTargetId = annunciatorId
    gdsGui_schematic_openMenu(canvasName, gdsGui_schematic_elementPropertiesTitle(a.label or annunciatorId), {"RENAME", "PROPERTIES", "DELETE"},
        "gdsGui_schematic_internal_onAnnunciatorEditChosen", "gdsGui_schematic_internal_onAnnunciatorEditCancelled", 3)
end

function gdsGui_schematic_internal_onAnnunciatorEditChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._annunciatorEditTargetId then return end
    local annunciatorId = canvas._annunciatorEditTargetId
    if optionText == "RENAME" then
        -- RENAME tapped: hand off to the rename prompt, keeping the target
        -- id around while that flow is in progress (same convention as the
        -- element edit menu's own RENAME option).
        canvas._annunciatorEditTargetId = nil
        _openAnnunciatorRenamePrompt(canvasName, annunciatorId)
        return
    elseif optionText == "PROPERTIES" then
        -- PROPERTIES tapped: hand off to the properties grid, keeping the
        -- target id around while that flow is in progress (same convention
        -- as the element/control edit menus' own PROPERTIES option).
        canvas._annunciatorEditTargetId = nil
        _openAnnunciatorPropertiesMenu(canvasName, annunciatorId)
        return
    elseif optionText == "DELETE" then
        -- DELETE only ever reaches here via the sustained hold the menu's
        -- own confirmIndex gates it behind (see openAnnunciatorEditMenu
        -- above) — a plain tap-release on this row is swallowed by
        -- _handleMenuRelease before onSelect ever fires, so by the time
        -- optionText == "DELETE" lands here the hold has already happened.
        -- Safe to act immediately.
        canvas._annunciatorEditTargetId = nil
        _pushUndo(canvas)
        gdsGui_schematic_removeAnnunciator(canvasName, annunciatorId)
        _notifyChanged(canvas)
        return
    end
    canvas._annunciatorEditTargetId = nil
end

-- Tapping outside the edit menu (or outside the rename/confirm steps it
-- leads to) just drops the in-flight target — unlike the element/control/
-- wire edit menus, there's no on-canvas "selected" highlight to also clear
-- here, since an annunciator isn't drawn as a selectable canvas object.
function gdsGui_schematic_internal_onAnnunciatorEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas._annunciatorEditTargetId = nil end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ANNUNCIATOR PROPERTIES MENU (reached via the edit
-- menu's PROPERTIES option above) — the same gdsGui_schematic_
-- openPropertyGrid chrome every element/control's own PROPERTIES menu uses
-- (_openPropertiesMenu further up), just entirely self-contained here since
-- an annunciator is a library-owned concept with no app-layer hooks of its
-- own (unlike _openPropertiesMenu's elementPropertiesExtraRows/RowSaved).
-- One row for now (COLOR, reusing the same _ANNUNCIATOR_COLORS 4-color set
-- creation's own picker draws from — _openAnnunciatorColorMenu further up —
-- rendered as true swatches via row.swatchColors, same as every other
-- color-choice row this grid supports); real configurable RULES are
-- deliberately left for later (see this section's own header comment above).
--------------------------------------------------------------------------------

-- Reverse of _ANNUNCIATOR_COLORS' own by-index lookup — which entry (if
-- any) an already-resolved color matches, so the COLOR row can be
-- pre-filled with its current selection, same pattern gdsGui_schematic_
-- colorPaletteNameForColor uses for the generic 5-color _COLOR_PALETTE.
-- Global, not local — this file is already at Lua's 200-top-level-local
-- ceiling (same constraint main.lua's own _openFundamentalsMenu comment
-- describes).
function _annunciatorColorName(color)
    if not color then return nil end
    for _, entry in ipairs(_ANNUNCIATOR_COLORS) do
        local c = entry.color
        if math.abs(c[1] - color[1]) < 0.01 and math.abs(c[2] - color[2]) < 0.01
           and math.abs(c[3] - color[3]) < 0.01 and math.abs((c[4] or 1) - (color[4] or 1)) < 0.01 then
            return entry.name
        end
    end
    return nil
end

-- That grid's own shadow row + target id while it's open — read back in
-- onAnnunciatorPropertiesSaved below, same "canvas.menu is already gone by
-- the time SAVE's callback fires" reasoning canvas._pendingPropertyRows
-- exists for (_openPropertiesMenu's own comment) — annunciators just don't
-- have a canvas field of their own to stash it on, since they're not drawn
-- on the canvas at all (see gdsGui_schematic_internal_onAnnunciatorEditCancelled's
-- own comment). Global, not local — same 200-top-level-local ceiling as
-- _annunciatorColorName just above.
_pendingAnnunciatorPropertyEdit = nil -- {canvasName, annunciatorId, rows}

-- Global, not local — same ceiling as _annunciatorColorName above.
function _openAnnunciatorPropertiesMenu(canvasName, annunciatorId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local a = _findAnnunciator(canvas, annunciatorId)
    if not a then return end
    local names, colors = {}, {}
    for _, entry in ipairs(_ANNUNCIATOR_COLORS) do
        table.insert(names, entry.name)
        table.insert(colors, entry.color)
    end
    local rows = {
        { key = "color", label = "COLOR", choices = names, swatchColors = colors,
            value = _annunciatorColorName(a.color) or "" },
    }
    _pendingAnnunciatorPropertyEdit = { canvasName = canvasName, annunciatorId = annunciatorId, rows = rows }
    gdsGui_schematic_openPropertyGrid(canvasName, gdsGui_schematic_elementPropertiesTitle(), a.label or annunciatorId, rows, false,
        "gdsGui_schematic_internal_onAnnunciatorPropertiesSaved", "gdsGui_schematic_internal_onAnnunciatorPropertiesCancelled")
end

function gdsGui_schematic_internal_onAnnunciatorPropertiesSaved(canvasName)
    local pending = _pendingAnnunciatorPropertyEdit
    _pendingAnnunciatorPropertyEdit = nil
    if not pending then return end
    local canvas = _findCanvas(pending.canvasName)
    local a = canvas and _findAnnunciator(canvas, pending.annunciatorId)
    if not a then return end
    _pushUndo(canvas)
    for _, row in ipairs(pending.rows) do
        if row.key == "color" then
            for _, entry in ipairs(_ANNUNCIATOR_COLORS) do
                if entry.name == row.value then a.color = entry.color end
            end
        end
    end
    _notifyChanged(canvas)
end

function gdsGui_schematic_internal_onAnnunciatorPropertiesCancelled(canvasName)
    _pendingAnnunciatorPropertyEdit = nil
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ANNUNCIATOR RENAME (reached via the edit menu's
-- RENAME option above). Reuses the same shared element/control/annunciator
-- label namespace/uniqueness rule as initial placement (_labelInUse), just
-- excluding the annunciator's own current label — same pattern as
-- _openElementRenamePrompt further up.
--------------------------------------------------------------------------------

-- Holds the annunciator being renamed while the text prompt is open; only
-- one rename is ever in flight at a time, same shape as _pendingRename.
local _pendingAnnunciatorRename = nil   -- {canvasName, annunciatorId}

_openAnnunciatorRenamePrompt = function(canvasName, annunciatorId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local a = _findAnnunciator(canvas, annunciatorId)
    if not a then return end
    _pendingAnnunciatorRename = { canvasName = canvasName, annunciatorId = annunciatorId }
    gdsGui_textPrompt_open("RENAME \"" .. (a.label or annunciatorId) .. "\"", a.label or "", 24,
        "gdsGui_schematic_annunciatorRenameConfirmed", "gdsGui_schematic_annunciatorRenameCancelled")
end

-- Resolved by name via _G[...] from textPrompt_gdsGuiLib.lua, like every
-- other string-registered callback in this library. onConfirmFunc receives
-- only the entered text (see gdsGui_textPrompt_confirm) — the target
-- annunciator comes from _pendingAnnunciatorRename, same pattern as
-- gdsGui_schematic_elementRenameConfirmed.
function gdsGui_schematic_annunciatorRenameConfirmed(text)
    local pending = _pendingAnnunciatorRename
    if not pending then return end
    local canvas = _findCanvas(pending.canvasName)
    local trimmed = (text or ""):gsub("^%s*(.-)%s*$", "%1")
    if not canvas then return end
    local a = _findAnnunciator(canvas, pending.annunciatorId)
    if not a then
        _pendingAnnunciatorRename = nil
        return
    end
    if trimmed == "" then
        gdsGui_textPrompt_open("NAME REQUIRED, TRY AGAIN", trimmed, 24,
            "gdsGui_schematic_annunciatorRenameConfirmed", "gdsGui_schematic_annunciatorRenameCancelled")
        return
    end
    if _labelInUse(canvas, trimmed, "annunciator", pending.annunciatorId) then
        gdsGui_textPrompt_open("NAME TAKEN, TRY AGAIN", trimmed, 24,
            "gdsGui_schematic_annunciatorRenameConfirmed", "gdsGui_schematic_annunciatorRenameCancelled")
        return
    end
    _pushUndo(canvas)
    a.label = trimmed
    _pendingAnnunciatorRename = nil
    _notifyChanged(canvas)
end

function gdsGui_schematic_annunciatorRenameCancelled()
    _pendingAnnunciatorRename = nil
end

-- Annunciator readout: one black screen anchored at the content's own
-- top-left world corner (_toPixel — same positioning every element/control
-- uses), with a fixed BASE footprint (_ANNUNCIATOR_READOUT_W/H_FRAC, fixed
-- fractions of contentW/H) that then scales with canvas.zoom exactly like
-- any other element/control — e.g. a GENERATOR control's own on-screen size
-- is likewise "a fixed base radius * canvas.zoom". So it pans and grows/
-- shrinks with the rest of the content, not a screen-space HUD. UNLIKE every
-- element's own label (which never scales with zoom — see _drawElement),
-- the text here DOES scale with it, via a graphics scale transform rather
-- than a new Font object per size: capped at 1x the configured app font size
-- (globApp.appFont), reached exactly at _MAX_ZOOM, and shrinking as the user
-- zooms out from there — it never grows past that cap.
local _ANNUNCIATOR_READOUT_W_FRAC = 0.30
local _ANNUNCIATOR_READOUT_H_FRAC = 0.16
local _ANNUNCIATOR_READOUT_MARGIN_FRAC = 0.02
local _ANNUNCIATOR_READOUT_PAD_PX = 6
local _ANNUNCIATOR_READOUT_ROW_GAP_PX = 2
local _ANNUNCIATOR_READOUT_COL_GAP_PX = 6

-- Which _ANNUNCIATOR_COLORS slot a given annunciator's stored color matches
-- (array order there IS the rank — see its own comment), or one past the end
-- for a color that somehow doesn't match any entry (never happens via the
-- normal creation flow, which always copies a color straight out of that
-- same table — just a safe fallback). Floating-point == is safe here since
-- a.color is never arithmetically derived, only ever copied unmodified from
-- one of these exact table entries at creation/load time.
local function _annunciatorColorRank(a)
    for i, entry in ipairs(_ANNUNCIATOR_COLORS) do
        if a.color and a.color[1] == entry.color[1] and a.color[2] == entry.color[2]
           and a.color[3] == entry.color[3] then
            return i
        end
    end
    return #_ANNUNCIATOR_COLORS + 1
end

-- Every ACTIVE annunciator, ranked red/yellow/green/white (per
-- _annunciatorColorRank) and alphabetically within each color — the
-- readout's own display order, distinct from _sortedAnnunciators (plain
-- alphabetical, used for the management panel and name-collision checks).
local function _sortedActiveAnnunciatorsForDisplay(canvas)
    local list = {}
    for _, a in ipairs(canvas.annunciators) do
        if a.active then table.insert(list, a) end
    end
    table.sort(list, function(x, y)
        local rx, ry = _annunciatorColorRank(x), _annunciatorColorRank(y)
        if rx ~= ry then return rx < ry end
        return (x.label or ""):lower() < (y.label or ""):lower()
    end)
    return list
end

local function _drawAnnunciators(canvas)
    local active = _sortedActiveAnnunciatorsForDisplay(canvas)
    if #active == 0 then return end
    local font = globApp.appFont or love.graphics.getFont()
    love.graphics.setFont(font)
    local textScale = math.min(1, canvas.zoom / _MAX_ZOOM)
    local rowH = (font:getHeight() + _ANNUNCIATOR_READOUT_ROW_GAP_PX) * textScale

    local x, y = _toPixel(canvas, _ANNUNCIATOR_READOUT_MARGIN_FRAC, _ANNUNCIATOR_READOUT_MARGIN_FRAC)
    local w = _ANNUNCIATOR_READOUT_W_FRAC * canvas.contentW * canvas.zoom
    local h = _ANNUNCIATOR_READOUT_H_FRAC * canvas.contentH * canvas.zoom

    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(1, 1, 1, 0.5)
    love.graphics.rectangle("line", x, y, w, h)

    -- How many whole rows fit vertically at the current (zoom-scaled) box
    -- height/font size — the left column fills up to this many (ranked
    -- order) before a second (right) column starts taking the overflow;
    -- anything past 2x this many is left clipped by the scissor below, same
    -- "zooming in reveals more" behavior as before, just across 2 columns.
    local rowsPerCol = math.max(0, math.floor((h - 2 * _ANNUNCIATOR_READOUT_PAD_PX) / rowH))
    local colW = (w - _ANNUNCIATOR_READOUT_PAD_PX * 2 - _ANNUNCIATOR_READOUT_COL_GAP_PX) / 2

    love.graphics.setScissor(x, y, w, h)
    for i, a in ipairs(active) do
        local col = (i - 1 < rowsPerCol) and 0 or 1
        local rowInCol = (col == 0) and (i - 1) or (i - 1 - rowsPerCol)
        if rowInCol < rowsPerCol then
            local colX = x + _ANNUNCIATOR_READOUT_PAD_PX + col * (colW + _ANNUNCIATOR_READOUT_COL_GAP_PX)
            local rowY = y + _ANNUNCIATOR_READOUT_PAD_PX + rowInCol * rowH
            local r, g, b, al = a.color[1], a.color[2], a.color[3], a.color[4] or 1
            love.graphics.setColor(r, g, b, al)
            -- Scale transform (not a resized Font) so the text grows/shrinks
            -- with zoom the way the box itself does — the wrap width passed
            -- to printf is in the scaled coordinate space, so it must be
            -- divided back out by textScale to still cover this column's own
            -- unscaled on-screen width colW. Left-aligned (not centered) so
            -- two columns read as two columns rather than two staggered
            -- center lines.
            love.graphics.push()
            love.graphics.translate(colX, rowY)
            love.graphics.scale(textScale, textScale)
            love.graphics.printf(a.label or a.id, 0, 0, colW / textScale, "left")
            love.graphics.pop()
        end
    end
    love.graphics.setScissor()
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ELEMENT EDIT MENU (delete + wire/rename/
-- properties, opened by a plain tap on an element while in design mode; a
-- drag still repositions it instead). No longer offers a color swatch row —
-- that's now PAINT MODE's job (see its own PUBLIC API block above), which
-- replaces this and its wire/control siblings' embedded color pickers.
-- DELETE is this menu's own confirmIndex row (passed to openMenu below) —
-- holding IT down for _CONFIRM_HOLD_SECONDS is the whole confirmation, no
-- separate "DELETE \"X\"?" popup. ADD WIRE/RENAME/PROPERTIES stay plain-tap,
-- as does MIRROR, offered only on a reshapable element (see _shapePoly.openMirror).
--------------------------------------------------------------------------------

function gdsGui_schematic_openElementEditMenu(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el then return end
    canvas._elementEditTargetId = elementId
    local options = {_pipes.addLabel(canvas), "RENAME", "PROPERTIES", "DELETE"}
    if _shapePoly.allowed(canvas, el) then
        table.insert(options, 3, "MIRROR")
        table.insert(options, 4, "ADD PORT")
        if el.terminals then
            table.insert(options, 5, "REMOVE PORT")
            table.insert(options, 6, "MOVE PORT")
        end
    end
    local title = el.label or elementId
    -- canvas.elementMenuTitleSuffix (optional, by-name like every other
    -- string-registered hook): called as fn(canvasName, elementId) just
    -- before this menu opens, for a line to APPEND to its title. The
    -- library never interprets what comes back; nil/"" means nothing extra
    -- to show, same as the hook simply not being registered at all. Not
    -- currently wired up by main.lua — the app used this for its sensed-
    -- voltage reading until that moved to the PROPERTIES menu instead (see
    -- canvas.elementSensedValues, _openPropertiesMenu below).
    if canvas.elementMenuTitleSuffix then
        local fn = _G[canvas.elementMenuTitleSuffix]
        local suffix = fn and fn(canvasName, elementId)
        if suffix and suffix ~= "" then title = title .. "  (" .. suffix .. ")" end
    end
    gdsGui_schematic_openMenu(canvasName, gdsGui_schematic_elementPropertiesTitle(title), options,
        "gdsGui_schematic_internal_onElementEditChosen", "gdsGui_schematic_internal_onElementEditCancelled", #options)
end

function gdsGui_schematic_internal_onElementEditChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._elementEditTargetId then return end
    local elementId = canvas._elementEditTargetId
    if optionText == _pipes.addLabel(canvas) then
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
        -- More than one port (a tank's, an ejector's): ask which one first, so
        -- the wire leaves from the port the user means (see pendingWirePortPick
        -- in gdsGui_schematic_pressed).
        local el = _findElement(canvas, elementId)
        if el and el.terminals and #el.terminals >= 2 then
            canvas.pendingWirePortPick = elementId
        else
            canvas.pendingWireFromId = elementId
        end
        return
    elseif optionText == "RENAME" then
        -- RENAME tapped: hand off to the rename prompt, keeping the element
        -- selected while that flow is in progress.
        canvas._elementEditTargetId = nil
        _openElementRenamePrompt(canvasName, elementId)
        return
    elseif optionText == "MIRROR" then
        canvas._elementEditTargetId = nil
        canvas.selectedElementId = nil
        local el = _findElement(canvas, elementId)
        if el then _shapePoly.openMirror(canvasName, canvas, el) end
        return
    elseif optionText == "ADD PORT" or optionText == "REMOVE PORT" or optionText == "MOVE PORT" then
        -- Waits on the next tap, keeping the tank selected, same as ADD WIRE above.
        -- MOVE PORT waits on two: the port, then where on the edge it goes.
        canvas._elementEditTargetId = nil
        gdsGui_schematic_cancelPlacement(canvasName)
        canvas.pendingPort = { elementId = elementId, removing = optionText == "REMOVE PORT",
            moving = optionText == "MOVE PORT" or nil }
        return
    elseif optionText == "PROPERTIES" then
        -- PROPERTIES tapped: hand off to the properties submenu, keeping the
        -- element selected while that flow is in progress.
        canvas._elementEditTargetId = nil
        _openPropertiesMenu(canvasName, elementId)
        return
    elseif optionText == "DELETE" then
        -- DELETE only ever reaches here via the sustained hold this menu's
        -- own confirmIndex gates it behind (see openElementEditMenu above) —
        -- a plain tap-release on this row is swallowed by _handleMenuRelease
        -- before onSelect ever fires. Safe to act immediately.
        canvas._elementEditTargetId = nil
        canvas.selectedElementId = nil
        _pushUndo(canvas)
        gdsGui_schematic_removeElement(canvasName, elementId)
        canvas.snapshots = {}
        _notifyChanged(canvas)
        return
    end
    canvas._elementEditTargetId = nil
    canvas.selectedElementId = nil
end

-- Tapping outside the edit menu (or outside the properties menu it leads to)
-- cancels it — the element should no longer read as "selected" once the
-- edit flow it was selected for has ended.
function gdsGui_schematic_internal_onElementEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._elementEditTargetId = nil
        canvas.selectedElementId = nil
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
-- PUBLIC API — DESIGN-MODE WIRE EDIT MENU (delete, opened by a plain tap on
-- a wire while in design mode). No longer offers a color swatch row — see
-- the matching comment on the element edit menu above. Its one DELETE row is
-- itself the confirmIndex row (passed to openMenu below): holding it down
-- for _CONFIRM_HOLD_SECONDS is the whole confirmation, no separate popup.
--------------------------------------------------------------------------------

function gdsGui_schematic_openWireEditMenu(canvasName, wireId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local w = _findWire(canvas, wireId)
    if not w then return end
    canvas._wireEditTargetId = wireId
    -- noDelete: an app-set flag for an item that only goes away along with
    -- whatever owns it (e.g. a relay's command wire and switch).
    if w.noDelete then
        gdsGui_schematic_openMenu(canvasName, gdsGui_schematic_elementPropertiesTitle(_pipes.noun(canvas) .. ": " .. wireId .. "\nCan't be deleted on its own — delete the item it belongs to."),
            {"OK"}, "gdsGui_schematic_internal_onWireEditCancelled", "gdsGui_schematic_internal_onWireEditCancelled")
        return
    end
    -- EDIT PATH draws the connector's own route (see _wirePath); RESET PATH,
    -- once it has one, goes back to the automatic route.
    local options = { "EDIT PATH" }
    if w.waypoints then table.insert(options, "RESET PATH") end
    table.insert(options, "DELETE")
    gdsGui_schematic_openMenu(canvasName, gdsGui_schematic_elementPropertiesTitle(_pipes.noun(canvas) .. ": " .. wireId), options,
        "gdsGui_schematic_internal_onWireEditChosen", "gdsGui_schematic_internal_onWireEditCancelled", #options)
end

function gdsGui_schematic_internal_onWireEditChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._wireEditTargetId then return end
    local wireId = canvas._wireEditTargetId
    if optionText == "DELETE" then
        -- DELETE only ever reaches here via the sustained hold this menu's
        -- own confirmIndex gates it behind (see openWireEditMenu above) — a
        -- plain tap-release on this row is swallowed by _handleMenuRelease
        -- before onSelect ever fires. Safe to act immediately.
        canvas._wireEditTargetId = nil
        canvas.selectedWireId = nil
        _pushUndo(canvas)
        gdsGui_schematic_removeWire(canvasName, wireId)
        canvas.snapshots = {}
        _notifyChanged(canvas)
        return
    elseif optionText == "EDIT PATH" then
        canvas._wireEditTargetId = nil
        _wirePath.start(canvasName, wireId)
        return
    elseif optionText == "RESET PATH" then
        local w = _findWire(canvas, wireId)
        if w and w.waypoints then
            _pushUndo(canvas)
            w.waypoints = nil
            _notifyChanged(canvas)
        end
    end
    canvas._wireEditTargetId = nil
    canvas.selectedWireId = nil
end

-- Tapping outside the edit menu cancels it — the wire should no longer read
-- as "selected" once the edit flow it was selected for has ended.
function gdsGui_schematic_internal_onWireEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._wireEditTargetId = nil
        canvas.selectedWireId = nil
    end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE CONTROL EDIT MENU (properties + position +
-- delete, opened by a plain tap on a control while in design mode; a drag
-- still repositions it instead, same tap-vs-drag gesture as the element/wire
-- edit menus above). No longer offers a color swatch row — see the matching
-- comment on the element edit menu above (POWERED COLOR, for a source
-- control, now lives inside PROPERTIES instead — see _openPropertiesMenu).
-- ADD WIRE always leads (index 1, unless noAddWire), PROPERTIES always
-- follows it, and DELETE always trails (index #positions + offset + 1),
-- checked by INDEX rather than optionText so a control whose own position
-- happens to be named "ADD WIRE", "PROPERTIES", or "DELETE" can't collide
-- with them — DELETE's index doubles as this menu's own confirmIndex
-- (passed to openMenu below), so holding IT down for _CONFIRM_HOLD_SECONDS
-- is the whole confirmation, no separate popup.
--------------------------------------------------------------------------------

function gdsGui_schematic_openControlEditMenu(canvasName, controlId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local ctrl = _findControl(canvas, controlId)
    if not ctrl then return end
    canvas._controlEditTargetId = controlId
    -- noAddWire: an app-set flag for a control whose wiring the app owns
    -- (e.g. a relay's command switch) — no ADD WIRE row. PROPERTIES always
    -- shows (same reasoning as the element edit menu's own PROPERTIES row
    -- below) — opens _openPropertiesMenu, the same grid used to edit any
    -- element/control's custom properties (and a source control's own
    -- POWERED COLOR row — see _openPropertiesMenu's own comment).
    local options = ctrl.noAddWire and {} or {_pipes.addLabel(canvas)}
    table.insert(options, "PROPERTIES")
    for _, p in ipairs(ctrl.positions) do table.insert(options, p) end
    -- No DELETE for a noDelete control (see openWireEditMenu).
    if not ctrl.noDelete then table.insert(options, "DELETE") end
    gdsGui_schematic_openMenu(canvasName, gdsGui_schematic_elementPropertiesTitle(ctrl.label or controlId), options,
        "gdsGui_schematic_internal_onControlEditChosen", "gdsGui_schematic_internal_onControlEditCancelled",
        (not ctrl.noDelete) and #options or nil)
end

function gdsGui_schematic_internal_onControlEditChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._controlEditTargetId then return end
    local controlId = canvas._controlEditTargetId
    local ctrl = _findControl(canvas, controlId)
    local nPositions = ctrl and #ctrl.positions or 0
    -- Rows: [ADD WIRE unless noAddWire], PROPERTIES (always), one per
    -- position, [DELETE unless noDelete].
    local offsetAddWire = (ctrl and ctrl.noAddWire) and 0 or 1
    local offset = offsetAddWire + 1
    if offsetAddWire == 1 and index == 1 then
        -- ADD WIRE tapped: arm a one-shot wire-drag whose fixed start is
        -- this control, same "stay armed, no need to land on an anchor
        -- next press" convention as an element's own ADD WIRE (see
        -- gdsGui_schematic_internal_onElementEditChosen) — _findAnchor
        -- resolves a control id just as readily as an element id.
        canvas._controlEditTargetId = nil
        gdsGui_schematic_cancelPlacement(canvasName)
        canvas.pendingWireFromId = controlId
        return
    elseif index == offsetAddWire + 1 then
        -- PROPERTIES tapped: hand off to the properties grid, keeping the
        -- control selected while that flow is in progress (same "stay
        -- selected mid-flow" convention as ADD WIRE above).
        canvas._controlEditTargetId = nil
        _openPropertiesMenu(canvasName, controlId)
        return
    elseif index == nPositions + offset + 1 then
        -- DELETE only ever reaches here via the sustained hold this menu's
        -- own confirmIndex gates it behind (see openControlEditMenu above) —
        -- a plain tap-release on this row is swallowed by _handleMenuRelease
        -- before onSelect ever fires. Safe to act immediately.
        canvas._controlEditTargetId = nil
        canvas.selectedControlId = nil
        _pushUndo(canvas)
        gdsGui_schematic_removeControl(canvasName, controlId)
        canvas.snapshots = {}
        _notifyChanged(canvas)
        return
    end
    canvas._controlEditTargetId = nil
    canvas.selectedControlId = nil
    -- Pushed here, not inside gdsGui_schematic_setControlPosition itself —
    -- that function is also how control-mode "just operate the switch"
    -- cycles a position on every tap (gdsGui_schematic_pressed), which is
    -- deliberately NOT undoable (same as any other instrument interaction).
    -- This design-mode edit-menu path is a genuine edit though, same as
    -- every sibling mutation here (rename, delete, move). A position's
    -- 0-based index is index - offset - 1 (ADD WIRE, when shown, is row 1).
    _pushUndo(canvas)
    gdsGui_schematic_setControlPosition(canvasName, controlId, index - offset - 1)
    _notifyChanged(canvas)
end

-- Tapping outside the edit menu cancels it — the control should no longer
-- read as "selected" once the edit flow it was selected for has ended.
function gdsGui_schematic_internal_onControlEditCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._controlEditTargetId = nil
        canvas.selectedControlId = nil
    end
end

-- CONTROL-MODE "operate" menu (see gdsGui_schematic_pressed/_released's
-- "controlTap" dragKind): an iOS-styled list of ONLY this control's own
-- positions — unlike gdsGui_schematic_openControlEditMenu above (design
-- mode's fuller ADD WIRE/PROPERTIES/position/DELETE menu), there's nothing
-- else here. Picking one jumps straight to it (gdsGui_schematic_
-- setControlPosition, the same function the old tap-to-cycle gesture this
-- replaces used) instead of stepping through positions one tap at a time.
function gdsGui_schematic_openControlPositionMenu(canvasName, controlId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local ctrl = _findControl(canvas, controlId)
    if not ctrl or not ctrl.positions or #ctrl.positions == 0 then return end
    canvas._controlTapTargetId = controlId
    canvas.selectedControlId = controlId -- the usual selection frame while the menu is open
    gdsGui_schematic_openMenu(canvasName, gdsGui_schematic_elementPropertiesTitle(ctrl.label or controlId), ctrl.positions,
        "gdsGui_schematic_internal_onControlPositionChosen", "gdsGui_schematic_internal_onControlPositionCancelled")
end

function gdsGui_schematic_internal_onControlPositionChosen(canvasName, index, optionText)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._controlTapTargetId then return end
    local controlId = canvas._controlTapTargetId
    canvas._controlTapTargetId = nil
    canvas.selectedControlId = nil
    gdsGui_haptics_feedback("selection")
    gdsGui_schematic_setControlPosition(canvasName, controlId, index - 1)
end

function gdsGui_schematic_internal_onControlPositionCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._controlTapTargetId = nil
        canvas.selectedControlId = nil
    end
end

-- CONTROL-MODE element quick view (see gdsGui_schematic_pressed/_released's
-- "elementTap" dragKind): lets the app layer offer a focused, LIVE-
-- committing popup for a plain element with nothing of its own like a
-- control's positions -- a fluid tank's quantity, say -- without it
-- needing control-mode positions of its own. Kept domain-agnostic the
-- same way elementPropertiesExtraRows/elementSensedValues already are: a
-- string-named callback the app registers (gdsGui_schematic_
-- setElementControlRowsCallback), resolved via _G, asked for a `rows`
-- array (the same shape gdsGui_schematic_openPropertyGrid already takes)
-- -- nil/empty means nothing to show, so nothing happens at all, same as
-- tapping a plain element in control mode always has.
function gdsGui_schematic_openElementControlRows(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el or not canvas.elementControlRows then return end
    local fn = _G[canvas.elementControlRows]
    local rows = fn and fn(canvasName, elementId)
    if not rows or not rows[1] then return end
    canvas._elementControlRowsTargetId = elementId
    canvas.selectedElementId = elementId
    gdsGui_schematic_openPropertyGrid(canvasName, gdsGui_schematic_elementPropertiesTitle(el.label or elementId), nil, rows,
        false, "gdsGui_schematic_internal_onElementControlRowsClosed", "gdsGui_schematic_internal_onElementControlRowsClosed")
end

-- Shared SAVE/CANCEL handler: every row here already commits live via its
-- own onChange (see _elementControlRows in main.lua), so there's nothing
-- left to apply on close either way -- just clear the selection.
function gdsGui_schematic_internal_onElementControlRowsClosed(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._elementControlRowsTargetId = nil
        canvas.selectedElementId = nil
    end
end

-- Registers the string-named callback gdsGui_schematic_openElementControlRows
-- consults (resolved via _G, same convention as every other button/menu
-- callback here) to ask the app for a control-mode element's own quick-
-- view rows, if it has any at all.
function gdsGui_schematic_setElementControlRowsCallback(canvasName, callbackName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.elementControlRows = callbackName end
end

--------------------------------------------------------------------------------
-- PUBLIC API — DESIGN-MODE ELEMENT/CONTROL PROPERTIES MENU (generic key/
-- value grid, reached via either edit menu's own PROPERTIES option — see
-- gdsGui_schematic_openPropertyGrid above for the widget itself). The app
-- layer assigns meaning to keys (e.g. "VOLTAGE"/"CURRENT" for an electrical
-- element) — this module just stores and lets the user edit them, all in
-- one scrollable grid rather than a drill-down per property. elementId may
-- name either an element OR a control (_findAnchor) — canvas.
-- _propertyEditTargetIsControl remembers which, so onPropertiesSaved/
-- Cancelled below know which of selectedElementId/selectedControlId to
-- clear again once this flow ends.
--------------------------------------------------------------------------------

-- canvas.elementSensedValues (optional, by-name like canvas.onChange and
-- every other string-registered hook): called as fn(canvasName, elementId)
-- just before the PROPERTIES grid opens, returning an array of
-- {label=string, value=string|nil} READ-ONLY sensed readings (e.g. VOLTAGE,
-- eventually CURRENT once current is modeled — see main.lua's
-- schematicElementSensedValues), shown as the grid's own header caption
-- rather than rows — these were never meant to be typed into, and the grid's
-- rows are now all uniformly editable (see openPropertyGrid's own header
-- comment). canvas.elementPropertiesExtraRows (same by-name convention,
-- optional): called as fn(canvasName, elementId) right after the sensed-
-- values header is built, returning an array of EDITABLE rows (same shape
-- _openElementPlacementGrid's own extra rows use — target == "field" writes
-- straight onto the entity by key, anything else is deferred entirely to
-- canvas.elementPropertiesRowSaved below) to show ahead of the item's own
-- custom properties — main.lua uses this for a source's own TYPE/VOLTAGE/
-- POWERED COLOR rows (POWERED COLOR is a row.swatchColors choice row — see
-- _propertyGrid.draw — pre-filled from that source's own color),
-- letting the user edit all of it right here, the exact same rows (and same
-- pre-fill behavior) the placement grid collects at creation time, instead
-- of a second, separate flow. Always opens with requireAll false — a freshly-placed
-- element's own default properties are collected mandatorily up front
-- instead, by the placement grid itself (see main.lua's
-- schematicElementPlacementExtraRows and schematic_gdsGuiLib.lua's own
-- _openElementPlacementGrid), so by the time this (editing an EXISTING
-- element/control, reached via its own edit menu's PROPERTIES option below)
-- ever opens there's nothing left to force full.
-- Public entry point into the PROPERTIES grid below, for an app-layer call
-- site that isn't itself an edit-menu PROPERTIES tap (e.g. main.lua's PER-
-- SOURCE SETTINGS list redirects its own VOLTAGE row straight here instead
-- of a second, separate grid) — identical to tapping PROPERTIES on the
-- element/control edit menu.
function gdsGui_schematic_openPropertiesMenu(canvasName, elementId)
    _openPropertiesMenu(canvasName, elementId)
end

function _openPropertiesMenu(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findAnchor(canvas, elementId)
    if not el then return end
    local isControl = _findControl(canvas, elementId) ~= nil
    canvas._elementEditTargetId = nil
    canvas._controlEditTargetId = nil
    canvas._propertyEditTargetId = elementId
    canvas._propertyEditTargetIsControl = isControl
    if isControl then canvas.selectedControlId = elementId else canvas.selectedElementId = elementId end
    local headerLines, sensedLabels = {}, {}
    if canvas.elementSensedValues then
        local fn = _G[canvas.elementSensedValues]
        local sensed = fn and fn(canvasName, elementId)
        for _, s in ipairs(sensed or {}) do
            table.insert(headerLines, s.label .. ": " .. ((s.value == nil or s.value == "") and "N/A" or s.value))
            sensedLabels[s.label:upper()] = true
        end
    end
    -- A custom property sharing a reserved sensed-value label (e.g. a
    -- "VOLTAGE" property hand-added before this feature existed) would
    -- otherwise show a second, user-editable "VOLTAGE" row right next to the
    -- real read-only one above — stale/confusing, so it's stripped on
    -- sight. Not pushed onto the undo stack — this is a one-time data
    -- migration, not a user edit the user would ever want to "undo" back in.
    if next(sensedLabels) ~= nil and el.properties then
        local removedAny = false
        for i = #el.properties, 1, -1 do
            if sensedLabels[el.properties[i].key:upper()] then
                table.remove(el.properties, i)
                removedAny = true
            end
        end
        if removedAny then _notifyChanged(canvas) end
    end
    -- Row 1 is always NAME (key "__name", same sentinel _openElementPlacementGrid's
    -- own row 1 uses) — the exact same row/validation the placement grid
    -- collects it with, just pre-filled from the live label instead of a
    -- fresh suggestion, and excluding the item's OWN current label from the
    -- uniqueness check (_labelInUse's own excludeKind/excludeId) so leaving
    -- it unchanged (or just re-casing it) never falsely collides with itself.
    local rows = { { key = "__name", label = "NAME", value = el.label or elementId } }
    if canvas.elementPropertiesExtraRows then
        local fn = _G[canvas.elementPropertiesExtraRows]
        for _, r in ipairs((fn and fn(canvasName, elementId)) or {}) do table.insert(rows, r) end
    end
    for _, p in ipairs(el.properties or {}) do
        table.insert(rows, { key = p.key, label = p.key, value = p.value or "" })
    end
    -- Stashed here, not read back via canvas.menu.rows in onPropertiesSaved
    -- below — by the time SAVE's callback fires, _propertyGrid.release has
    -- already cleared canvas.menu (same "closes first, callback after"
    -- order _choiceGrid's own save/cancel release use).
    canvas._pendingPropertyRows = rows
    gdsGui_schematic_openPropertyGrid(canvasName, gdsGui_schematic_elementPropertiesTitle(),
        (#headerLines > 0) and table.concat(headerLines, "\n") or nil, rows, false,
        "gdsGui_schematic_internal_onPropertiesSaved", "gdsGui_schematic_internal_onPropertiesCancelled",
        function(gridRows)
            local trimmed = (gridRows[1].value or ""):gsub("^%s*(.-)%s*$", "%1")
            if trimmed == "" then return false, 1, "NAME REQUIRED" end
            if _labelInUse(canvas, trimmed, isControl and "control" or "element", elementId) then
                return false, 1, "NAME TAKEN, TRY ANOTHER"
            end
            return true
        end)
end

function gdsGui_schematic_internal_onPropertiesCancelled(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then
        canvas._propertyEditTargetId = nil
        canvas._propertyEditTargetIsControl = nil
        canvas._pendingPropertyRows = nil
        canvas.selectedElementId = nil
        canvas.selectedControlId = nil
    end
end

-- SAVE writes every row straight back onto the element/control (the grid's
-- own rows were a shadow copy — see openPropertyGrid's own comment — so
-- nothing changed on the real entity until now), then un-selects it the same
-- way every other edit-menu flow's own finish does. A row with target ==
-- "field" writes straight onto the entity by key (same convention
-- _applyPlacementExtraRows uses for the placement grid); any OTHER target
-- (e.g. "voltageColor" — main.lua's POWERED COLOR row) is left entirely to
-- canvas.elementPropertiesRowSaved below, fired once per such row AFTER
-- every plain row/field write above has landed — the library has no idea
-- what "voltageColor" means (canvas.voltageColors is an app-added field, not
-- part of this library's own canvas schema — see main.lua's own VOLTAGE ->
-- COLOR REGISTRATION section comment). A row with no target at all is an
-- ordinary custom property, same as before this hook existed. Row 1 (NAME)
-- is consumed directly onto el.label here, same as _commitNamedPlacement
-- does for the placement grid's own row 1 — already validated non-empty/
-- unique by this grid's own validateFunc (see _openPropertiesMenu above)
-- before SAVE could ever reach here, so no re-check needed. Fires
-- canvas.elementPropertiesSaved (optional, by-name) once everything above
-- has landed, for the app to react to the FINAL state (e.g. flagging a bus
-- tie's logic as possibly needing a new row for a changed VOLTAGE) — the
-- editing-flow sibling of canvas.elementPlacementConfigured.
function gdsGui_schematic_internal_onPropertiesSaved(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas or not canvas._propertyEditTargetId then return end
    local elementId = canvas._propertyEditTargetId
    local el = _findAnchor(canvas, elementId)
    local rows = canvas._pendingPropertyRows
    canvas._propertyEditTargetId = nil
    canvas._propertyEditTargetIsControl = nil
    canvas._pendingPropertyRows = nil
    canvas.selectedElementId = nil
    canvas.selectedControlId = nil
    if not el or not rows then return end
    _pushUndo(canvas)
    local trimmedName = (rows[1] and rows[1].value or ""):gsub("^%s*(.-)%s*$", "%1")
    if trimmedName ~= "" then el.label = trimmedName end
    for i = 2, #rows do
        local row = rows[i]
        if row.target == "field" then
            el[row.key] = (row.numeric and tonumber(row.value)) or row.value
        elseif not row.target then
            gdsGui_schematic_setElementProperty(canvasName, elementId, row.key, row.value or "")
        end
    end
    if canvas.elementPropertiesRowSaved then
        local fn = _G[canvas.elementPropertiesRowSaved]
        if fn then
            for i = 2, #rows do
                local row = rows[i]
                if row.target and row.target ~= "field" then fn(canvasName, elementId, row) end
            end
        end
    end
    _notifyChanged(canvas)
    if canvas.elementPropertiesSaved then
        local fn = _G[canvas.elementPropertiesSaved]
        if fn then fn(canvasName, elementId) end
    end
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

-- Public wrapper around _parseSignature above — the inverse of
-- gdsGui_schematic_buildSignature ("a=0,b=1" -> {a=0, b=1}), exposed so
-- app-layer code can recover a PAST snapshot's own control positions
-- straight from its signature key rather than relying on canvas.controls'
-- current (possibly since-moved-on) detentIndex values.
function gdsGui_schematic_parseSignature(signature)
    return _parseSignature(signature)
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
    for id, col in pairs(candidate.controls or {}) do
        local ex = existing.controls and existing.controls[id]
        if ex and not _colorEquals(ex, col) then return true end
    end
    return false
end

-- A snapshot's bucket for a given targetKind ("element"/"wire"/"control") —
-- snap.controls can be absent on a snapshot captured before controls were
-- colorable, same backward-compatible nil-bucket handling the caller below
-- already relies on.
local function _snapshotBucket(snap, targetKind)
    if targetKind == "element" then return snap.elements
    elseif targetKind == "wire" then return snap.wires
    else return snap.controls end
end

-- targetKind: "element" | "wire" | "control". Returns r,g,b,a for the
-- entity's live resolved color: 1) a pending color-picker override, else 2)
-- the snapshot matching the current control-position signature, else 2.5) a
-- model-layer predicted color (see predictedColor below), else 3) the
-- entity's default (gray) color.
-- cachedSignature is an optional precomputed gdsGui_schematic_computeSignature
-- result — every caller that resolves many colors off the SAME signature in
-- one pass (the main per-frame draw loop below, over every element/wire/
-- control) should pass it in once rather than paying computeSignature's
-- table.sort + string-concat cost again per entity for a value that can't
-- have changed mid-pass. Falls back to computing it fresh when omitted, so
-- every other caller (a one-off resolve, or a unit test) is unaffected.
--
-- predictedColor (tier 2.5): unlike pendingColor/the snapshot bucket, this
-- is never written by the paint tool or commitSnapshot — it's an optional
-- field the app layer's inference model sets (see
-- gdsGui_schematic_applySolvedColors) when it has solved a color for a
-- control combination nobody has hand-painted yet. Sitting below the
-- snapshot tier keeps an authored capture permanently authoritative over a
-- prediction for the exact same combination; sitting above the bare
-- default lets an unpainted-but-solvable combination show something better
-- than flat gray. See gdsGui_schematic_isColorPredicted to tell which case
-- actually fired, e.g. to badge a guess visually.
function gdsGui_schematic_resolveColor(canvasName, targetKind, targetId, cachedSignature)
    local canvas = _findCanvas(canvasName)
    if not canvas then return _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] end
    local target = _findByKind(canvas, targetKind, targetId)
    if not target then return _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] end

    if target.pendingColor then
        local c = target.pendingColor
        return c[1], c[2], c[3], c[4]
    end

    local signature = cachedSignature or gdsGui_schematic_computeSignature(canvasName)
    local snap = canvas.snapshots[signature]
    if snap then
        local bucket = _snapshotBucket(snap, targetKind)
        local c = bucket and bucket[targetId]
        if c then return c[1], c[2], c[3], c[4] end
    end

    if target.predictedColor then
        local c = target.predictedColor
        return c[1], c[2], c[3], c[4]
    end

    local dc = target.defaultColor or _DEFAULT_COLOR
    return dc[1], dc[2], dc[3], dc[4]
end

-- True if resolveColor's predictedColor tier (2.5) is the one that would
-- actually fire for this entity right now — i.e. there's no pending paint
-- override and no snapshot for the current combination, but the model
-- layer has set a predicted color. Lets a draw function badge a guess
-- (e.g. a dashed outline) without having to re-derive the same priority
-- chain or compare colors by equality.
function gdsGui_schematic_isColorPredicted(canvasName, targetKind, targetId, cachedSignature)
    local canvas = _findCanvas(canvasName)
    if not canvas then return false end
    local target = _findByKind(canvas, targetKind, targetId)
    if not target or not target.predictedColor or target.pendingColor then return false end
    local signature = cachedSignature or gdsGui_schematic_computeSignature(canvasName)
    local snap = canvas.snapshots[signature]
    if snap then
        local bucket = _snapshotBucket(snap, targetKind)
        if bucket and bucket[targetId] then return false end
    end
    return true
end

-- Writes solvedColors (shaped like a snapshot bucket: {elements={id=color},
-- wires={...}, controls={...}}) into every matching entity's predictedColor
-- — never into pendingColor/defaultColor, so this can never shadow an
-- authored paint-in-progress or a captured snapshot (see resolveColor's
-- tier order above). An entity solvedColors doesn't cover is left with no
-- prediction, falling through to its bare default. The app-layer model
-- adapter is the only intended caller — see _solveCurrentSchematic in
-- main.lua — called after gdsGui_schematic_stepCombination lands on a
-- combination with no captured snapshot, and once after a system loads.
-- solvedColors.{elements,wires,controls}[id] is normally a flat {r,g,b,a}
-- color (c[1] a number) -- but may instead be a SEQUENCE of 2+ such colors
-- (c[1] itself a table, see model/solver.lua's solveSourceAttribution and
-- the per-source-color tie-break in _solveCurrentSchematic) when more than
-- one active source reaches that node at once and neither one's voltage
-- settles it. A sequence sets BOTH predictedColor (its first entry, kept
-- as the single representative color every existing consumer --
-- resolveColor, isColorPredicted, snapshot capture -- already expects) AND
-- predictedColorSequence (consulted only by the draw functions, to render
-- an alternating dash pattern instead of a flat fill). Nested (not a
-- top-level local) purely to stay under this file's 200-local ceiling —
-- it has exactly one caller.
function gdsGui_schematic_applySolvedColors(canvasName, solvedColors)
    local canvas = _findCanvas(canvasName)
    if not canvas or not solvedColors then return end
    local function applyOne(target, c)
        if c and type(c[1]) == "table" then
            target.predictedColor = { c[1][1], c[1][2], c[1][3], c[1][4] }
            local seq = {}
            for i, color in ipairs(c) do seq[i] = { color[1], color[2], color[3], color[4] } end
            target.predictedColorSequence = seq
        elseif c then
            target.predictedColor = { c[1], c[2], c[3], c[4] }
            target.predictedColorSequence = nil
        else
            target.predictedColor = nil
            target.predictedColorSequence = nil
        end
    end
    for _, e in ipairs(canvas.elements) do
        applyOne(e, solvedColors.elements and solvedColors.elements[e.id])
    end
    for _, w in ipairs(canvas.wires) do
        applyOne(w, solvedColors.wires and solvedColors.wires[w.id])
    end
    for _, ctl in ipairs(canvas.controls) do
        applyOne(ctl, solvedColors.controls and solvedColors.controls[ctl.id])
    end
end

-- Like resolveColor, but for a node whose CURRENT prediction is a
-- multi-color tie rather than one flat color (see
-- gdsGui_schematic_applySolvedColors' own comment above). Returns nil
-- whenever there's no sequence actually in play right now -- an authored
-- pendingColor or an exact-signature snapshot always wins outright over
-- ANY prediction, same priority resolveColor's own tier chain uses, so
-- this intentionally mirrors that precedence (see isColorPredicted,
-- just below resolveColor, for the equivalent single-color check this
-- parallels). The draw functions fall through to plain resolveColor
-- whenever this returns nil.
function gdsGui_schematic_resolveColorSequence(canvasName, targetKind, targetId, cachedSignature)
    local canvas = _findCanvas(canvasName)
    if not canvas then return nil end
    local target = _findByKind(canvas, targetKind, targetId)
    if not target or not target.predictedColorSequence or target.pendingColor then return nil end
    local signature = cachedSignature or gdsGui_schematic_computeSignature(canvasName)
    local snap = canvas.snapshots[signature]
    if snap then
        local bucket = _snapshotBucket(snap, targetKind)
        if bucket and bucket[targetId] then return nil end
    end
    return target.predictedColorSequence
end

-- Like resolveColor above, but this is the one actually drawn on the canvas
-- (_drawElement/_drawWire below). Used to skip the snapshot lookup entirely
-- in DESIGN mode so repositioning a control to set up a capture target
-- couldn't silently replay a different combination's snapshot. That's now
-- handled upstream instead — gdsGui_schematic_stepCombination (the only way
-- a control's position changes in design mode) clears every pendingColor
-- (and predictedColor) the instant the combination changes, via
-- resetColorsToDefault — so deferring to the full resolveColor here is
-- safe, and necessary: once commitSnapshot bakes a pick in (clearing
-- pendingColor), this needs to fall through to the snapshot it just wrote,
-- not all the way to bare defaultColor, or the canvas would look like the
-- capture silently reverted.
-- cachedSignature: see gdsGui_schematic_resolveColor above.
function gdsGui_schematic_resolveDisplayColor(canvasName, targetKind, targetId, cachedSignature)
    local r, g, b, a = gdsGui_schematic_resolveColor(canvasName, targetKind, targetId, cachedSignature)
    return _themedPaletteColor(r, g, b, a)
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
    local plan = { signature = "", elements = {}, wires = {}, controls = {}, conflict = nil, hasConflict = false, replacesKeys = {} }
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
    -- .controls is a newer bucket than .elements/.wires — an older snapshot
    -- (captured before controls were colorable) simply lacks it, so every
    -- access below is guarded rather than assumed present like the two loops
    -- above.
    for _, ctl in ipairs(canvas.controls) do
        local r, g, b, a = gdsGui_schematic_resolveColor(canvasName, "control", ctl.id)
        if not ctl.pendingColor and not (exactSnapshot and exactSnapshot.controls and exactSnapshot.controls[ctl.id])
           and migratedFrom and migratedFrom.controls and migratedFrom.controls[ctl.id] then
            local c = migratedFrom.controls[ctl.id]
            r, g, b, a = c[1], c[2], c[3], c[4]
        end
        plan.controls[ctl.id] = { r, g, b, a }
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
        elements = plan.elements, wires = plan.wires, controls = plan.controls,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    }
    for _, e in ipairs(canvas.elements) do e.pendingColor = nil end
    for _, w in ipairs(canvas.wires) do w.pendingColor = nil end
    for _, c in ipairs(canvas.controls) do c.pendingColor = nil end
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

function gdsGui_schematic_removeAllSnapshots(canvasName)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.snapshots = {} end
end

function gdsGui_schematic_hasSnapshot(canvasName, signature)
    local canvas = _findCanvas(canvasName)
    return canvas ~= nil and canvas.snapshots[signature] ~= nil
end

--------------------------------------------------------------------------------
-- PUBLIC API — CONTROL-POSITION COMBINATION CYCLING (app-layer PREV/NEXT
-- arrows). A "combination" is one assignment of every control's detentIndex
-- — the same thing a snapshot's signature (gdsGui_schematic_computeSignature
-- above) encodes — so walking every combination is just a mixed-radix
-- counter over canvas.controls, sorted by id (the same canonical order
-- gdsGui_schematic_buildSignature uses so the two stay in lockstep), one
-- control's numDetents per digit. Total combinations is the product of every
-- control's numDetents — 1 when there are no controls (a single, trivial
-- combination).
--------------------------------------------------------------------------------

local function _sortedControls(canvas)
    local sorted = {}
    for _, c in ipairs(canvas.controls) do table.insert(sorted, c) end
    table.sort(sorted, function(a, b) return a.id < b.id end)
    return sorted
end

function gdsGui_schematic_getCombinationTotal(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return 1 end
    local total = 1
    for _, c in ipairs(canvas.controls) do total = total * c.numDetents end
    return total
end

-- 1-based index of the combination the controls' CURRENT positions
-- represent, out of gdsGui_schematic_getCombinationTotal(canvasName).
function gdsGui_schematic_getCombinationIndex(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return 1 end
    local idx = 0
    for _, c in ipairs(_sortedControls(canvas)) do
        idx = idx * c.numDetents + c.detentIndex
    end
    return idx + 1
end

-- Clears every element/wire/control's pendingColor AND predictedColor — the
-- "nothing captured, nothing solved yet" blank slate — so a freshly-cycled-
-- to combination never silently replays a previously captured snapshot's
-- (or a stale prediction's) colors. Falls through to resolveColor's tier 3
-- (each entity's own defaultColor, gray for virtually everything in
-- practice) rather than forcing one flat shared gray, so an entity with a
-- genuinely custom default color keeps showing it here same as it would
-- anywhere else resolveColor is consulted.
--
-- Deliberately does NOT re-populate pendingColor with gray the way it used
-- to: resolveColor's pendingColor tier sits ABOVE the predictedColor tier,
-- so if this still force-set pendingColor here, a model-layer prediction
-- written afterward via gdsGui_schematic_applySolvedColors could never be
-- seen — see resolveColor's own comment on the predictedColor tier, and the
-- call site below, which is the only caller.
function gdsGui_schematic_resetColorsToDefault(canvasName)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    for _, e in ipairs(canvas.elements) do e.pendingColor = nil; e.predictedColor = nil end
    for _, w in ipairs(canvas.wires) do w.pendingColor = nil; w.predictedColor = nil end
    for _, c in ipairs(canvas.controls) do c.pendingColor = nil; c.predictedColor = nil end
end

-- Seeds every element/wire/control's pendingColor from `snapshot` instead of
-- gray — same "always an explicit pendingColor, never a bare default" shape
-- resetColorsToDefault keeps (so resolveColor's pendingColor-first priority
-- still wins), just replaying what was actually captured for this
-- combination. An entity the snapshot doesn't cover (added since capture, or
-- an older snapshot missing the newer .controls bucket) falls back to gray,
-- same as a never-captured entity would.
local function _applySnapshotAsPending(canvas, snapshot)
    for _, e in ipairs(canvas.elements) do
        local c = snapshot.elements and snapshot.elements[e.id]
        e.pendingColor = c and { c[1], c[2], c[3], c[4] }
            or { _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] }
    end
    for _, w in ipairs(canvas.wires) do
        local c = snapshot.wires and snapshot.wires[w.id]
        w.pendingColor = c and { c[1], c[2], c[3], c[4] }
            or { _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] }
    end
    for _, ctl in ipairs(canvas.controls) do
        local c = snapshot.controls and snapshot.controls[ctl.id]
        ctl.pendingColor = c and { c[1], c[2], c[3], c[4] }
            or { _DEFAULT_COLOR[1], _DEFAULT_COLOR[2], _DEFAULT_COLOR[3], _DEFAULT_COLOR[4] }
    end
end

-- Advances (direction = 1) or retreats (direction = -1) to the next/previous
-- combination, wrapping at both ends, then either replays the snapshot
-- already captured for the landed-on combination (so the user can tweak it
-- further, same as just having captured it) or, if none exists yet, resets
-- every entity to the selectable gray color (see
-- gdsGui_schematic_resetColorsToDefault above). The app layer's checkmark
-- readout (driven by gdsGui_schematic_hasSnapshot) still reflects which case
-- happened. Returns the new 1-based index and the total, so the caller can
-- update its header readout without a second pass over canvas.controls.
function gdsGui_schematic_stepCombination(canvasName, direction)
    local canvas = _findCanvas(canvasName)
    if not canvas then return 1, 1 end
    local sorted = _sortedControls(canvas)

    local total = 1
    for _, c in ipairs(sorted) do total = total * c.numDetents end

    local idx = 0
    for _, c in ipairs(sorted) do idx = idx * c.numDetents + c.detentIndex end
    idx = (idx + direction) % total

    for i = #sorted, 1, -1 do
        local c = sorted[i]
        c.detentIndex = idx % c.numDetents
        idx = math.floor(idx / c.numDetents)
    end

    local snap = canvas.snapshots[gdsGui_schematic_computeSignature(canvasName)]
    if snap then
        _applySnapshotAsPending(canvas, snap)
    else
        gdsGui_schematic_resetColorsToDefault(canvasName)
    end
    return gdsGui_schematic_getCombinationIndex(canvasName), total
end

--------------------------------------------------------------------------------
-- DRAWING
--------------------------------------------------------------------------------

-- Grid lines live at fixed world-space positions spaced _GRID_SPACING_PX
-- apart (same fixed pitch _snapToGrid snaps to — see its comment), so they
-- spread apart on screen as the user zooms in and draw closer together
-- zoomed out, exactly like physical units would. This keeps a position
-- that's on-grid at one zoom level on-grid at every zoom level.
local function _drawGrid(canvas)
    -- globApp.themeCanvasGridColor (set by the app layer's dark/light mode
    -- toggle, if it sets one at all) lets the grid stay readable against
    -- either canvas backdrop; a plain GUI-library consumer that never sets
    -- it still gets the original faint-white-on-dark look.
    local g = globApp.themeCanvasGridColor or {1, 1, 1, 0.06}
    -- True one-device-pixel lines, each on a pixel center, so the grid is
    -- crisp on a Retina screen; alpha scaled up to match, so it reads as
    -- strongly as the old wider line did.
    local hairline = gdsGui_general_hairline()
    love.graphics.setColor(g[1], g[2], g[3], math.min(1, g[4] / hairline))
    local prevLineWidth = love.graphics.getLineWidth()
    love.graphics.setLineWidth(hairline)
    local spacing = _GRID_SPACING_PX
    local x0, y0, x1, y1 = canvas.x, canvas.y, canvas.x + canvas.w, canvas.y + canvas.h

    local worldLeft = (x0 - canvas.x - canvas.panX) / canvas.zoom
    local worldRight = (x1 - canvas.x - canvas.panX) / canvas.zoom
    local gx = math.floor(worldLeft / spacing) * spacing
    while gx <= worldRight do
        local sx = gdsGui_general_pixelCenter(canvas.x + canvas.panX + gx * canvas.zoom)
        love.graphics.line(sx, y0, sx, y1)
        gx = gx + spacing
    end

    local worldTop = (y0 - canvas.y - canvas.panY) / canvas.zoom
    local worldBottom = (y1 - canvas.y - canvas.panY) / canvas.zoom
    local gy = math.floor(worldTop / spacing) * spacing
    while gy <= worldBottom do
        local sy = gdsGui_general_pixelCenter(canvas.y + canvas.panY + gy * canvas.zoom)
        love.graphics.line(x0, sy, x1, sy)
        gy = gy + spacing
    end
    love.graphics.setLineWidth(prevLineWidth)
end

-- Caches an element's sprite image by path, same lazy-load-once pattern as
-- _loadGalleryImage further below (kept separate since that one is defined
-- after this point in the file and elements are drawn far more often per
-- frame than gallery tiles are rebuilt).
-- Element art is drawn far smaller than its source (1080 px squares down to a
-- few dozen pixels), so it's mipmapped and linearly filtered: smooth edges, and
-- no shimmer as the canvas pans and zooms. Falls back to a plain image where
-- mipmaps aren't supported.
gdsGui_schematic_internal_loadSmoothImage = function(path)
    local ok, img = pcall(love.graphics.newImage, path, { mipmaps = true })
    if not ok then img = love.graphics.newImage(path) end
    img:setFilter("linear", "linear")
    if ok then pcall(img.setMipmapFilter, img, "linear") end
    return img
end

local _elementSpriteCache = {}
local function _loadElementSprite(path)
    if not _elementSpriteCache[path] then
        _elementSpriteCache[path] = gdsGui_schematic_internal_loadSmoothImage(path)
    end
    return _elementSpriteCache[path]
end

-- Calls drawFn(r, g, b, a) once per entry in colors, each time scissored to
-- one band of (boundsX, boundsY, boundsW, boundsH) -- an "unresolved tie"
-- indicator for a node fed by more than one active source at once with no
-- clear voltage winner (see model/solver.lua's solveSourceAttribution and
-- gdsGui_schematic_resolveColorSequence just above). drawFn is whatever the
-- caller would normally call ONCE with a single resolved color -- reusing
-- it under each band means every shape (sprite-tinted or hand-drawn)
-- stripes correctly with no shape-specific duplication.
--
-- Scissor coordinates are always screen-space
-- in LÖVE regardless of the current transform, so this always stripes in
-- SCREEN-space bands, not rotated with the element — a deliberate
-- simplification (this is a rare ambiguity indicator, not core rendering)
-- rather than computing a rotated bounding box. The caller's own scissor
-- (if any — e.g. the canvas's own viewport clip) is restored afterward,
-- but is itself REPLACED (not intersected) while a band is active, same
-- caveat as any nested love.graphics.setScissor call.
-- 6: inlined rather than a named constant purely to stay under this
-- file's 200-local ceiling.
local function _drawColorSequenceStriped(boundsX, boundsY, boundsW, boundsH, colors, drawFn)
    local prevScX, prevScY, prevScW, prevScH = love.graphics.getScissor()
    for i = 0, 6 - 1 do
        local c = colors[(i % #colors) + 1]
        local bandW = boundsW / 6
        love.graphics.setScissor(boundsX + i * bandW, boundsY, bandW + 1, boundsH)
        drawFn(c[1], c[2], c[3], c[4] or 1)
    end
    if prevScX then love.graphics.setScissor(prevScX, prevScY, prevScW, prevScH) else love.graphics.setScissor() end
end

-- Draws a spritePath image (an element's own, or a control's spritePaths
-- entry for its current detent — see gdsGui_schematic_addControl) filling
-- the given box exactly (tinted by r,g,b,a — the normal resolved color, so
-- snapshot/pending color overrides still read on a sprite the same as they
-- do on a plain rect/circle). Scales X and Y independently to fill, not to
-- fit, so the drawn sprite always matches the box's own edges (the same box
-- the selection square/collision check use — see _drawElement) exactly,
-- never shrunk/letterboxed to preserve the source image's own aspect ratio.
-- A control's box is always square (see _drawControl's drawHalf), so this
-- is a no-op there either way; it only matters for an element whose own
-- gridW/gridH box isn't the same aspect as its source image. rotationDeg
-- (optional, 0/90/180/270, see _snapRotationDegrees) spins it around the
-- box's own center — same cardinal-orientation convention as
-- _drawDiodeSymbol, just generalized to any image instead of hand-drawn
-- line art.
local function _drawElementSprite(path, ex, ey, ew, eh, r, g, b, a, rotationDeg)
    local image = _loadElementSprite(path)
    local iw, ih = image:getDimensions()
    local scaleX, scaleY = ew / iw, eh / ih
    love.graphics.setColor(r, g, b, a)
    if rotationDeg and rotationDeg ~= 0 then
        love.graphics.push()
        love.graphics.translate(ex + ew / 2, ey + eh / 2)
        love.graphics.rotate(math.rad(rotationDeg))
        love.graphics.draw(image, -ew / 2, -eh / 2, 0, scaleX, scaleY)
        love.graphics.pop()
    else
        love.graphics.draw(image, ex, ey, 0, scaleX, scaleY)
    end
end

-- Draws canvas.backgroundImagePath (see gdsGui_schematic_setBackgroundImage)
-- scaled, at the reference zoom/pan (zoom 1, pan 0 — the "whole canvas box
-- fits exactly in the viewport" state, see _MIN_ZOOM), to exactly fill the
-- content box's width — preserving aspect ratio, so height is whatever that
-- implies — and vertically centered. Deliberately NOT "scale to fit" like
-- _drawElementSprite above: filling width exactly means there's never a gap
-- to either side regardless of the image's own aspect ratio, only possibly
-- above/below (which the caller's scissor already clips, same as everything
-- else drawn on the canvas).
--
-- Positioned/scaled against canvas.contentW/H (the fixed world-space basis
-- _toPixel itself uses — see its own comment) rather than the live
-- canvas.x/y/w/h viewport box, and the exact same
-- "canvas.x + canvas.panX + worldUnits * canvas.zoom" shape _toPixel
-- applies to every element/control — so the background pans and zooms
-- WITH the content, instead of staying pinned to the viewport like a fixed
-- wallpaper (canvas.w/h are clamped viewport sizes, not the true content
-- extent, so they're the wrong basis for this — see _calculateGeometry).
local _CANVAS_BG_OPACITY = 0.35  -- shared by the main backdrop and the corner images below

-- These background/corner watermarks (the airplane/schematic-canvas artwork
-- set via gdsGui_schematic_setBackground*Image below) are tinted per theme
-- rather than drawn at the art's own color, so they read as a faint
-- watermark against either canvas backdrop instead of going invisible (a
-- light tint vanishes on a light canvas) or clashing too brightly (plain
-- white on a dark canvas). Dark mode: flat mid-gray (80,80,80). WHITE MODE
-- (globApp.themeIsDark == false): darker gray so it stays faint against the
-- light backdrop too.
local _BG_DARK_MODE_TINT  = {80 / 255, 80 / 255, 80 / 255}
local _BG_LIGHT_MODE_TINT = {0.25, 0.25, 0.25}
local function _drawTintedImage(image, px, py, scale, a)
    local tint = (globApp.themeIsDark == false) and _BG_LIGHT_MODE_TINT or _BG_DARK_MODE_TINT
    love.graphics.setColor(tint[1], tint[2], tint[3], a)
    love.graphics.draw(image, px, py, 0, scale, scale)
end

local function _drawCanvasBackground(canvas)
    if not canvas.backgroundImagePath then return end
    local image = _loadElementSprite(canvas.backgroundImagePath)
    local iw, ih = image:getDimensions()
    local worldScale = canvas.contentW / iw
    local drawH = ih * worldScale
    local worldY = (canvas.contentH - drawH) / 2
    local px = canvas.x + canvas.panX
    local py = canvas.y + canvas.panY + worldY * canvas.zoom
    local scale = worldScale * canvas.zoom
    _drawTintedImage(image, px, py, scale, _CANVAS_BG_OPACITY)
end

-- Draws canvas.cornerBackgroundImagePath / cornerRightBackgroundImagePath /
-- cornerTopRightBackgroundImagePath (see gdsGui_schematic_setCorner*
-- BackgroundImage) each sized to _CORNER_BG_HEIGHT_FRAC of the content
-- box's height (preserving aspect ratio), anchored so the image's own
-- bottom-left/bottom-right/top-right corner sits exactly on the content
-- box's matching corner.
-- Same world-space pan/zoom positioning as _drawCanvasBackground, so it
-- moves and scales with the canvas content like every other image. Always
-- drawn before _drawCanvasBackground (see gdsGui_schematic_draw) so it reads
-- as sitting behind that backdrop wherever the two overlap.
local _CORNER_BG_HEIGHT_FRAC = 0.175  -- 30% smaller than the original 0.25
-- sizeMul (optional, defaults to 1): per-corner multiplier on _CORNER_BG_HEIGHT_FRAC.
local function _drawCornerImage(canvas, path, alignRight, alignTop, sizeMul)
    if not path then return end
    local image = _loadElementSprite(path)
    local iw, ih = image:getDimensions()
    local targetH = canvas.contentH * _CORNER_BG_HEIGHT_FRAC * (sizeMul or 1)
    local worldScale = targetH / ih
    local worldX = alignRight and (canvas.contentW - iw * worldScale) or 0
    local worldY = alignTop and 0 or (canvas.contentH - targetH)
    local px = canvas.x + canvas.panX + worldX * canvas.zoom
    local py = canvas.y + canvas.panY + worldY * canvas.zoom
    local scale = worldScale * canvas.zoom
    _drawTintedImage(image, px, py, scale, _CANVAS_BG_OPACITY)
end

local function _drawCanvasCornerBackground(canvas)
    _drawCornerImage(canvas, canvas.cornerBackgroundImagePath, false)
    _drawCornerImage(canvas, canvas.cornerRightBackgroundImagePath, true)
    _drawCornerImage(canvas, canvas.cornerTopRightBackgroundImagePath, true, true, 1.5)
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

-- One small outward-pointing triangle glyph, used 4x by _drawMoveModeOverlay
-- below — (px,py) is the glyph's own outward tip, (dx,dy) the outward unit
-- direction it points in (so the base sits closer to the shape than the tip).
local function _drawArrowGlyph(px, py, dx, dy, size)
    local perpX, perpY = -dy, dx
    local tipX,  tipY  = px + dx * size * 0.6, py + dy * size * 0.6
    local baseX, baseY = px - dx * size * 0.6, py - dy * size * 0.6
    love.graphics.polygon("fill",
        tipX, tipY,
        baseX + perpX * size * 0.5, baseY + perpY * size * 0.5,
        baseX - perpX * size * 0.5, baseY - perpY * size * 0.5)
end

-- Move-mode affordance: once a long-press has unlocked drag (see
-- canvas.selectionMoveModeActive), 4 small arrows sit just outside the
-- element/control's own edges — one per cardinal direction — signaling
-- "this can be dragged" on top of the existing yellow->magenta outline
-- swap. cx,cy is the shape's own center; halfW,halfH its half-extents (a
-- control passes its radius for both, reading as a diamond of 4 arrows
-- around the circle).
local function _drawMoveModeOverlay(cx, cy, halfW, halfH, zoom)
    local size = _MOVE_ARROW_SIZE_PX * zoom
    local gap  = _MOVE_ARROW_GAP_PX * zoom
    _drawArrowGlyph(cx, cy - halfH - gap - size, 0, -1, size)
    _drawArrowGlyph(cx, cy + halfH + gap + size, 0, 1, size)
    _drawArrowGlyph(cx - halfW - gap - size, cy, -1, 0, size)
    _drawArrowGlyph(cx + halfW + gap + size, cy, 1, 0, size)
end

-- Rotate-mode affordance: pressing an already-move-unlocked element/control
-- again rotates it instead (see gdsGui_schematic_pressed's isActiveMoveTarget
-- branch) — a semi-completed circular arrow contouring the shape (a ring
-- with one end left open and an arrowhead at the other, like a classic
-- "rotate" icon) hints at that drag-to-rotate gesture. Only drawn for
-- rotatable targets -- every control and every element now (toggled each
-- press, not shown together) -- see call sites.
local function _drawRotateModeOverlay(cx, cy, radius, zoom)
    local startAngle = -math.pi / 2 + _ROTATE_ARC_GAP_RAD / 2
    local endAngle    = startAngle + (math.pi * 2 - _ROTATE_ARC_GAP_RAD)
    local ringRadius  = radius + _ROTATE_ARC_MARGIN_PX * zoom
    love.graphics.setLineWidth(2 * zoom)
    love.graphics.arc("line", "open", cx, cy, ringRadius, startAngle, endAngle, 48)
    love.graphics.setLineWidth(1)
    -- Arrowhead at the arc's leading end, tangent to the ring so it reads
    -- as continuing the curve's direction of travel.
    local tipX, tipY   = cx + math.cos(endAngle) * ringRadius, cy + math.sin(endAngle) * ringRadius
    local tanX, tanY   = -math.sin(endAngle), math.cos(endAngle)
    local normX, normY = math.cos(endAngle), math.sin(endAngle)
    local headSize = _MOVE_ARROW_SIZE_PX * zoom
    love.graphics.polygon("fill",
        tipX + tanX * headSize * 0.7, tipY + tanY * headSize * 0.7,
        tipX - tanX * headSize * 0.4 + normX * headSize * 0.5, tipY - tanY * headSize * 0.4 + normY * headSize * 0.5,
        tipX - tanX * headSize * 0.4 - normX * headSize * 0.5, tipY - tanY * headSize * 0.4 - normY * headSize * 0.5)
end

-- 0 from _MIN_ZOOM through _LABEL_FADE_START_ZOOM, then linearly up to 1 at
-- _MAX_ZOOM — see _LABEL_FADE_START_ZOOM's comment for why labels fade in
-- as zoom grows.
local function _labelAlphaForZoom(zoom)
    return math.max(0, math.min(1, (zoom - _LABEL_FADE_START_ZOOM) / (_MAX_ZOOM - _LABEL_FADE_START_ZOOM)))
end

-- The shortest line height still readable, in pixels on screen whatever the font
-- size setting: below it a label gives up lines rather than shrink further, and
-- shows nothing once even its first line won't fit.
_shapePoly.CENTER_TEXT_MIN_LINE_PX = 9

-- The middle of an element's real outline on screen: its polygon's center of area,
-- since a reshaped tank's outline needn't sit evenly inside its box.
function _shapePoly.centroid(canvas, e)
    local cx, cy, cw, ch, p = _shapePoly.frame(canvas, e)
    local points = {}
    for i, corner in ipairs(p.corners) do
        points[i] = { _shapePoly.toWorld(cx, cy, cw, ch, p, e.rotation, corner.c, corner.r) }
    end
    local area, sumX, sumY = 0, 0, 0
    for i, a in ipairs(points) do
        local b = points[i % #points + 1]
        local cross = a[1] * b[2] - b[1] * a[2]
        area = area + cross
        sumX = sumX + (a[1] + b[1]) * cross
        sumY = sumY + (a[2] + b[2]) * cross
    end
    if math.abs(area) < 1e-6 then return cx, cy end
    return sumX / (3 * area), sumY / (3 * area)
end

-- The most of lines (from the first) that fit inside the element's real outline
-- around its centroid at a readable scale. Returns how many, the scale and their
-- unscaled width, or nil if not even the first line fits.
function _shapePoly.fitCenterText(canvas, e, lines, font)
    local centerX, centerY = _shapePoly.centroid(canvas, e)
    local margin = 2
    local function fits(w, h)
        local halfW, halfH = w / 2 + margin, h / 2 + margin
        return _shapePoly.containsPoint(canvas, e, centerX - halfW, centerY - halfH)
            and _shapePoly.containsPoint(canvas, e, centerX + halfW, centerY - halfH)
            and _shapePoly.containsPoint(canvas, e, centerX - halfW, centerY + halfH)
            and _shapePoly.containsPoint(canvas, e, centerX + halfW, centerY + halfH)
    end
    local minScale = math.min(1, _shapePoly.CENTER_TEXT_MIN_LINE_PX / font:getHeight())
    for count = #lines, 1, -1 do
        local textW = 0
        for i = 1, count do textW = math.max(textW, font:getWidth(lines[i])) end
        local textH = count * font:getHeight()
        local scale = 1
        while scale >= minScale do
            if fits(textW * scale, textH * scale) then return count, scale, textW end
            scale = scale * 0.9
        end
    end
    return nil
end

-- canvas.elementCenterText (optional, by-name like canvas.elementStatusText):
-- called as fn(canvasName, elementId), returning text to show over the middle of
-- that element, one reading a line with the most important first, or nil for none.
-- Unlike the name label below the box, it stays upright whatever the rotation,
-- doesn't fade with zoom, and sits inside the element's real outline, shrinking and
-- then dropping its last lines to do so. It's outlined rather than backed by a box,
-- so it reads over the filled and empty parts of a tank without hiding the level.
function _shapePoly.drawCenterText(canvas, e)
    local fn = canvas.elementCenterText and _G[canvas.elementCenterText]
    local text = fn and fn(canvas.name, e.id)
    if not text then return end
    local font = globApp.appFont or love.graphics.getFont()
    local lines = {}
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local count, scale, textW = _shapePoly.fitCenterText(canvas, e, lines, font)
    if not count then return end
    local shown = table.concat(lines, "\n", 1, count)
    local centerX, centerY = _shapePoly.centroid(canvas, e)
    local x, y = centerX - textW * scale / 2, centerY - count * font:getHeight() * scale / 2
    love.graphics.setFont(font)
    love.graphics.setColor(0, 0, 0, 1)
    for _, offset in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        love.graphics.printf(shown, x + offset[1], y + offset[2], textW, "center", 0, scale, scale)
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(shown, x, y, textW, "center", 0, scale, scale)
end

--------------------------------------------------------------------------------
-- COLOR TRANSITIONS — a plain-color element/control/wire (see
-- gdsGui_schematic_resolveDisplayColor) cross-fades to a NEW resolved color
-- instead of snapping to it instantly, e.g. a bus energizing or a snapshot
-- combination replaying a different capture. Global, not local, same as
-- _actionSheet/_menuBackdrop/_galleryBadge above — this file is already at
-- Lua's 200-top-level-local ceiling.
--
-- Scoped to the plain (single, non-striped) color path only -- the
-- resolveColorSequence ("striped", multiple simultaneous colors) path, and
-- the wire-bundle color-band pass, keep today's instant snap; blending a
-- whole sequence coherently is a meaningfully bigger problem, not worth it
-- for a less common case. No canvases, no shaders -- a pure per-draw-call
-- color lerp, same cost class as everything else in these draw functions.
--
-- Transition state lives directly on the entity table itself
-- (entity._colorBlend), the same convention pendingColor/predictedColor
-- already use for transient per-entity cosmetic state, keyed by the
-- entity's own object identity rather than a separate id-indexed cache.
--------------------------------------------------------------------------------

_colorBlend = {}
_colorBlend.DURATION = 0.25 -- seconds

-- The color entity._colorBlend (cb) is currently actually showing --
-- mid-transition if cb.startTime is set, else its settled target.
function _colorBlend.sample(cb)
    if not cb.startTime then return cb.to[1], cb.to[2], cb.to[3], cb.to[4] end
    local t = math.min(1, (love.timer.getTime() - cb.startTime) / _colorBlend.DURATION)
    t = t * t * (3 - 2 * t) -- smoothstep ease
    return cb.from[1] + (cb.to[1] - cb.from[1]) * t, cb.from[2] + (cb.to[2] - cb.from[2]) * t,
        cb.from[3] + (cb.to[3] - cb.from[3]) * t, cb.from[4] + (cb.to[4] - cb.from[4]) * t
end

-- Call once per entity per frame with its freshly resolved target color;
-- returns the color to actually draw with this frame (the target itself,
-- most frames -- or a blended in-between while a transition is running).
function _colorBlend.resolve(entity, r, g, b, a)
    local cb = entity._colorBlend
    if cb and cb.to[1] == r and cb.to[2] == g and cb.to[3] == b and cb.to[4] == a then
        if not cb.startTime then return r, g, b, a end -- settled; common case
    else
        -- The target changed (or this is the first time this entity's
        -- color was ever resolved) -- (re)start a transition from whatever
        -- is CURRENTLY actually showing, so a change arriving mid-transition
        -- doesn't pop. First time: nothing to transition from, so from==to
        -- and it reads as already settled.
        local fromR, fromG, fromB, fromA = r, g, b, a
        if cb then fromR, fromG, fromB, fromA = _colorBlend.sample(cb) end
        entity._colorBlend = { to = { r, g, b, a }, from = { fromR, fromG, fromB, fromA }, startTime = love.timer.getTime() }
        cb = entity._colorBlend
    end
    local t = (love.timer.getTime() - cb.startTime) / _colorBlend.DURATION
    if t >= 1 then
        cb.from, cb.startTime = nil, nil -- settled
        return r, g, b, a
    end
    t = t * t * (3 - 2 * t)
    return cb.from[1] + (r - cb.from[1]) * t, cb.from[2] + (g - cb.from[2]) * t,
        cb.from[3] + (b - cb.from[3]) * t, cb.from[4] + (a - cb.from[4]) * t
end

local function _drawElement(canvas, e, signature)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    -- Drawn exactly as resolved (no extra darken), so an element shows the
    -- same palette color — default gray included — as a wire or control.
    -- isHalo: drawing a powered-glow copy (see _glow.halo) — the shapes'
    -- white outlines are left out so the halo stays the element's own color.
    local function drawShapeWithColor(r, g, b, a, isHalo)
        local outline = isHalo and 0 or 1
        love.graphics.setColor(r, g, b, a)
        if e.spritePath then
            _drawElementSprite(e.spritePath, ex, ey, ew, eh, r, g, b, a, e.rotation)
            love.graphics.setColor(1, 1, 1, 1)
        elseif e.shapeType == "pipeTree" then
            -- Checked ahead of e.shapePoints just below: a pipeTree element
            -- (MANIFOLD — see _drawPipeTreeSymbol's own comment) carries a
            -- shapePoints polygon too, but only for hit-testing/selection —
            -- it never draws from it.
            _drawPipeTreeSymbol(canvas, e, ex, ey, ew, eh, r, g, b, a, isHalo)
        elseif e.shapePoints then
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            _shapePoly.drawLocal(e, ew, eh, r, g, b, a, outline)
            love.graphics.pop()
        elseif e.shapeType == "circle" then
            -- Every shapeType is rotatable now (move/rotate mode applies
            -- uniformly — see gdsGui_schematic_pressed's toggle), so an
            -- off-square ellipse (ew ~= eh) visibly turns too, same
            -- push/translate/rotate-around-center convention as the diode
            -- symbol below.
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            love.graphics.ellipse("fill", 0, 0, ew / 2, eh / 2)
            love.graphics.setColor(1, 1, 1, outline)
            love.graphics.ellipse("line", 0, 0, ew / 2, eh / 2)
            love.graphics.pop()
        elseif e.shapeType == "diode" then
            _drawDiodeSymbol(ex + ew / 2, ey + eh / 2, ew, eh, e.rotation, r, g, b, a)
            love.graphics.setColor(1, 1, 1, 1)
        else
            -- Plain rect, same rotation treatment as circle above. A tank
            -- (e.fillPercent ~= nil -- the same "holds a fluid level" signal
            -- the drawLevel dispatch below already keys off) still at its
            -- catalog default outline, never reshaped, rounds its corners
            -- the same amount a reshaped one's own _shapePoly.drawLocal
            -- does; a plain bus/duct/engine stays sharp-cornered.
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            local radius = (e.fillPercent ~= nil) and (math.min(ew, eh) * _shapePoly.CORNER_RADIUS_FRACTION) or 0
            love.graphics.rectangle("fill", -ew / 2, -eh / 2, ew, eh, radius, radius)
            love.graphics.setColor(1, 1, 1, outline)
            love.graphics.rectangle("line", -ew / 2, -eh / 2, ew, eh, radius, radius)
            love.graphics.pop()
        end
    end

    -- A tank showing its level; its powered-glow halo stays the whole body.
    -- Always top-of-tank-to-bottom oriented, regardless of port location or
    -- count -- see _shapePoly.drawLevel's own wavy top surface for the
    -- fluid-movement cue instead of a port-draining animation.
    if e.fillPercent then
        local drawWhole = drawShapeWithColor
        drawShapeWithColor = function(r, g, b, a, isHalo)
            if isHalo then return drawWhole(r, g, b, a, true) end
            _shapePoly.drawLevel(canvas, e, drawWhole, r, g, b, a)
        end
    end

    -- A sequence (2+ colors — a node fed by more than one active source at
    -- once with no clear voltage winner, see model/solver.lua's
    -- solveSourceAttribution) draws the shape N times, each scissored to
    -- one band, instead of the normal single resolved color.
    local sequence = gdsGui_schematic_resolveColorSequence(canvas.name, "element", e.id, signature)
    if sequence then
        _glow.haloStriped(canvas, ex, ey, ew, eh, sequence, drawShapeWithColor)
        _drawColorSequenceStriped(ex, ey, ew, eh, sequence, drawShapeWithColor)
    else
        local r, g, b, a = gdsGui_schematic_resolveDisplayColor(canvas.name, "element", e.id, signature)
        r, g, b, a = _colorBlend.resolve(e, r, g, b, a)
        if _glow.applies(canvas, r, g, b) then _glow.halo(canvas.zoom, r, g, b, drawShapeWithColor) end
        drawShapeWithColor(r, g, b, a)
    end

    -- From here on, ex,ey,ew,eh give way to the element's own TRUE
    -- (rotation-aware) footprint — everything below is either the
    -- selection outline/overlays (which must match what
    -- _footprintOverlapsAnother/_hitElement actually collide against, see
    -- _elementFootprintRect) or the label (world-space text, not inside
    -- the shape's own push/rotate block above, so "below the box" means
    -- below the box as it actually sits rotated).
    local fex, fey, few, feh = _elementFootprintRect(canvas, e)
    _shapePoly.drawCenterText(canvas, e)
    _shapePoly.drawPorts(canvas, e)
    -- Flagged by gdsGui_schematic_moved's "element"/"control" dragKind
    -- branches as the specific obstacle a relocation drag is currently
    -- pushing into (via _footprintOverlapsAnother's 2nd return value) —
    -- red for exactly as long as that stays true, cleared the instant the
    -- drag clears it or the gesture ends. Independent of (and drawn before,
    -- so selection's own yellow/magenta wins if both were ever true at
    -- once) the normal selection outline below.
    if canvas.collidingObstacleId == e.id then
        love.graphics.setColor(1, 0, 0, 1)
        if e.shapePoints then
            _shapePoly.strokeOutline(canvas, e)
        else
            love.graphics.rectangle("line", fex, fey, few, feh)
        end
    end
    if canvas.selectedElementId == e.id then
        -- Magenta once the 2-second hold has unlocked drag/rotate for it
        -- (see gdsGui_schematic_update's long-press timer) — yellow is
        -- still "selected, but a drag here won't move/rotate it; a tap
        -- opens its menu, or hold to unlock that." Magenta drawn at half
        -- opacity (both the outline and the move/rotate overlay below,
        -- which inherits this same setColor) so it reads as an active
        -- affordance without visually competing with the element itself.
        -- The rounded selection frame sits just outside the footprint (see
        -- _selection); a reshaped element's follows its real outline. The
        -- exact footprint, the box drags and placements collide against
        -- (_elementFootprintRect), shows as a thin line only while it's dragged.
        local key = "e:" .. e.id
        local lift = _selection.lift(canvas)
        local function drawSelected(alpha)
            if e.shapePoints then
                _selection.drawOutline(canvas, e, alpha, lift)
            else
                _selection.drawFrame(fex, fey, few, feh, alpha, lift)
            end
        end
        drawSelected(_selection.mark(canvas, key))
        _selection.remember(canvas, key, drawSelected)
        if canvas.dragKind == "element" and canvas.dragMoved then
            love.graphics.setLineWidth(gdsGui_general_hairline())
            _selection.setAccent(0.6)
            love.graphics.rectangle("line", fex, fey, few, feh)
            love.graphics.setLineWidth(1)
        end
        local holdFraction = _selection.holdFraction(canvas, "element")
        if holdFraction then _selection.drawHoldTrace(fex, fey, few, feh, holdFraction) end
        -- The move/rotate overlay below draws in this color, translucent so it
        -- doesn't compete with the item itself.
        _selection.setAccent(0.5)
        if canvas.selectionMoveModeActive then
            -- Mutually exclusive, not both at once: every further tap on
            -- the active target toggles between them (see
            -- gdsGui_schematic_pressed's isActiveMoveTarget branch) rather
            -- than opening the edit menu. Every element is rotatable now,
            -- same as every control.
            if canvas.reshapeModeActive and _shapePoly.allowed(canvas, e) then
                _shapePoly.drawHandles(canvas, e)
            elseif canvas.rotateModeActive then
                -- Half-diagonal, not half-width/height — the smallest
                -- circle that still fully encloses the (now exact, not
                -- shared-size) selection box above, so the rotate arc nests
                -- just outside its corners rather than cutting through them.
                local ringBase = math.sqrt((few / 2) ^ 2 + (feh / 2) ^ 2)
                _drawRotateModeOverlay(fex + few / 2, fey + feh / 2, ringBase, canvas.zoom)
            else
                _drawMoveModeOverlay(fex + few / 2, fey + feh / 2, few / 2, feh / 2, canvas.zoom)
            end
        end
    end
    if e.label then
        local tc = globApp.themeTextColor or {1, 1, 1, 1}
        love.graphics.setColor(tc[1], tc[2], tc[3], _labelAlphaForZoom(canvas.zoom))
        -- Explicit, not ambient: outputTxtBox_gdsGuiLib.lua's own draw pass
        -- (gdsGui_outputTxtBox_draw, runs immediately before this one every
        -- frame — see gdsGui_general_draw) leaves love.graphics' font set to
        -- whatever its own LAST textbox used, which has nothing to do with
        -- the app's global font-size setting. globApp.appFont (set by the
        -- app layer's FONT SIZE control, if it sets one at all) is what
        -- actually tracks that setting — falling back to the ambient font
        -- so the GUI library still draws something without it.
        love.graphics.setFont(globApp.appFont or love.graphics.getFont())
        -- canvas.elementStatusText (optional, by-name like canvas.onChange/
        -- canvas.elementSensedValues): called as fn(canvasName, elementId),
        -- returning an optional status string (e.g. a source element's
        -- sensed voltage) for this element's own row 2 — the element
        -- equivalent of a control's current position (see _drawControl's
        -- posName). Stays nil, and the label stays one row, for any element
        -- the app layer hasn't wired a status reading for. Kept as an
        -- app-resolved hook (not a field this domain-agnostic library reads
        -- directly off `e`) for the same reason componentType/onChange are
        -- callback-by-name — see this file's own header comment.
        local statusText = canvas.elementStatusText and _G[canvas.elementStatusText]
            and _G[canvas.elementStatusText](canvas.name, e.id)
        local labelText = statusText and ((e.label or "") .. "\n" .. statusText) or e.label
        -- Always below the box, never centered across it — same position/
        -- style as a control's own label (see _drawControl), one consistent
        -- look for every anchor kind. A diode/sprite had no other choice
        -- already (diode has no filled body to back text against; a sprite
        -- fills the box with actual art), now shared by every shape.
        --
        -- Print width is NOT just ew: an element's own box can now be far
        -- narrower than its name needs (a 2-grid-unit-wide BATTERY, say —
        -- see armElementPlacement's gridW/gridH), and the label font is a
        -- fixed on-screen size that doesn't shrink with it (not scaled by
        -- canvas.zoom like ew is) — so a plain `ew` width would wrap even a
        -- short name onto a second line it was never meant to have. Floored
        -- at _LABEL_MIN_WIDTH_PX (comfortably wider than a short label needs
        -- at any normal font size) and still centered on the box's own
        -- center, so a wide element (a BUS) is unaffected either way.
        local labelW = math.max(few, _LABEL_MIN_WIDTH_PX)
        love.graphics.printf(labelText, fex + few / 2 - labelW / 2, fey + feh + 2, labelW, "center")
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
--
-- A sprite-drawn anchor (an element's spritePath, or a control's current-
-- detent spritePaths entry plus any overlaySpritePath) is the exception: its
-- image is letterboxed into the box (see _drawElementSprite) and the art
-- itself rarely fills the image edge to edge, so the box edge can sit well
-- outside what's actually drawn. Wires clamp to the art's visible extent
-- instead, measured from the image's own opaque pixels — so a padded image
-- needs no hand-cropping for wires to meet it.
--
-- Returns minX, maxX, minY, maxY — the visible art's extent relative to the
-- anchor's center, in screen pixels, after its rotation — or nil when the
-- anchor isn't sprite-drawn. The opaque-pixel scan runs once per image path
-- and is cached as 0-1 fractions of that image.
local _spriteArtExtents
do
    local boundsCache = {}
    local function contentBounds(path)
        local cached = boundsCache[path]
        if cached ~= nil then return cached or nil end
        local ok, data = pcall(love.image.newImageData, path)
        if not ok then boundsCache[path] = false; return nil end
        local w, h = data:getDimensions()
        local x0, y0, x1, y1 = w, h, -1, -1
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local _, _, _, a = data:getPixel(x, y)
                if a > 0.1 then
                    if x < x0 then x0 = x end
                    if x > x1 then x1 = x end
                    if y < y0 then y0 = y end
                    if y > y1 then y1 = y end
                end
            end
        end
        local b = (x1 >= 0) and { l = x0 / w, r = (x1 + 1) / w, t = y0 / h, b = (y1 + 1) / h, w = w, h = h } or false
        boundsCache[path] = b
        return b or nil
    end

    _spriteArtExtents = function(canvas, anchor)
        local paths, boxW, boxH
        if anchor.w then
            if not anchor.spritePath then return nil end
            paths = { anchor.spritePath }
            local _, _, ew, eh = _elementPixelRect(canvas, anchor)
            boxW, boxH = ew, eh
        else
            local base = anchor.spritePaths and anchor.spritePaths[(anchor.detentIndex or 0) + 1]
            if not base then return nil end
            paths = { base, anchor.overlaySpritePath }
            local rad = canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1)
            boxW, boxH = rad * 2, rad * 2
        end
        local minX, maxX, minY, maxY
        local rot = math.rad(anchor.rotation or 0)
        local cosR, sinR = math.cos(rot), math.sin(rot)
        for _, path in ipairs(paths) do
            local b = contentBounds(path)
            if b then
                -- Same fit-not-fill letterbox scale _drawElementSprite uses.
                local scale = math.min(boxW / b.w, boxH / b.h)
                local dw, dh = b.w * scale, b.h * scale
                local l, r = (b.l - 0.5) * dw, (b.r - 0.5) * dw
                local t, bt = (b.t - 0.5) * dh, (b.b - 0.5) * dh
                for _, corner in ipairs({ {l, t}, {r, t}, {l, bt}, {r, bt} }) do
                    local px = corner[1] * cosR - corner[2] * sinR
                    local py = corner[1] * sinR + corner[2] * cosR
                    minX = math.min(minX or px, px); maxX = math.max(maxX or px, px)
                    minY = math.min(minY or py, py); maxY = math.max(maxY or py, py)
                end
            end
        end
        if not minX then return nil end
        return minX, maxX, minY, maxY
    end
end

local function _anchorHalfExtent(canvas, anchor, axis)
    if not anchor then return 0 end
    local minX, maxX, minY, maxY = _spriteArtExtents(canvas, anchor)
    if minX then
        if axis == "x" then return math.max(-minX, maxX) end
        return math.max(-minY, maxY)
    end
    if anchor.shapeType == "diode" then return 0 end
    if anchor.w then
        local _, _, ew, eh = _elementPixelRect(canvas, anchor)
        if anchor.shapePoints then _, _, ew, eh = _elementFootprintRect(canvas, anchor) end
        return (axis == "x") and (ew / 2) or (eh / 2)
    end
    return canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1)
end

local function _anchorEdgePoint(canvas, anchor, cx, cy, axis, sign)
    if anchor and anchor.shapePoints then
        return _shapePoly.edgePoint(canvas, anchor, cx, cy, axis, sign)
    end
    if anchor then
        -- Per-side, not symmetric: art that sits off-center in its image
        -- (e.g. a switch's lever swinging to one side of its terminals)
        -- reaches further on one side than the other.
        local minX, maxX, minY, maxY = _spriteArtExtents(canvas, anchor)
        if minX then
            if axis == "x" then return cx + ((sign > 0) and maxX or minX), cy end
            return cx, cy + ((sign > 0) and maxY or minY)
        end
        if anchor.shapeType == "diode" then return cx, cy end
    end
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

-- _clampedOrthogonalSegments, for ends from _terminals.wireEnd: a terminal
-- end (fromAxis/toAxis set) always leaves along its own exit axis, so a
-- wire never runs sideways out of a DPST's top lug straight across its
-- neighbouring lug. With no terminal end, or the two ends already level on
-- one axis, it's exactly _clampedOrthogonalSegments.
function _terminals.segments(canvas, x1, y1, fromA, fromAxis, x2, y2, toA, toAxis, forceAxis)
    if (not fromAxis and not toAxis) or x1 == x2 or y1 == y2 then
        return _clampedOrthogonalSegments(canvas, fromA, x1, y1, toA, x2, y2, forceAxis)
    end
    if fromAxis and fromAxis == toAxis then
        -- Both ends are terminals leaving on the same axis: out of one, a
        -- single jog midway, into the other.
        if fromAxis == "v" then
            local midY = (y1 + y2) / 2
            return { { x1, y1, x1, midY }, { x1, midY, x2, midY }, { x2, midY, x2, y2 } }
        end
        local midX = (x1 + x2) / 2
        return { { x1, y1, midX, y1 }, { midX, y1, midX, y2 }, { midX, y2, x2, y2 } }
    end
    -- One terminal end, one plain anchor whose own body already spans the
    -- terminal's line (e.g. a bus sitting right above a top lug): a single
    -- straight run off that anchor's edge, not a stub sideways out of it.
    local plainA = (not fromAxis and fromA) or (not toAxis and toA)
    if plainA and (fromAxis or toAxis) then
        local axis = fromAxis or toAxis
        local ax, ay = (plainA == fromA) and x1 or x2, (plainA == fromA) and y1 or y2
        local tx, ty = (plainA == fromA) and x2 or x1, (plainA == fromA) and y2 or y1
        local seg
        if axis == "v" and math.abs(tx - ax) < _anchorHalfExtent(canvas, plainA, "x") then
            local _, ey = _anchorEdgePoint(canvas, plainA, ax, ay, "y", (ty > ay) and 1 or -1)
            seg = { tx, ey, tx, ty }
        elseif axis == "h" and math.abs(ty - ay) < _anchorHalfExtent(canvas, plainA, "y") then
            local ex = _anchorEdgePoint(canvas, plainA, ax, ay, "x", (tx > ax) and 1 or -1)
            seg = { ex, ty, tx, ty }
        end
        if seg then
            if plainA == fromA then return { seg } end
            return { { seg[3], seg[4], seg[1], seg[2] } }
        end
    end
    -- One bend: the first leg along the from-terminal's own exit axis (or,
    -- for a plain from-anchor, whichever axis lets the last leg arrive
    -- along the to-terminal's), the second straight into the far end.
    local firstAxis = fromAxis or ((toAxis == "v") and "h" or "v")
    local sx, sy = (x2 > x1) and 1 or -1, (y2 > y1) and 1 or -1
    local fx, fy, tx, ty = x1, y1, x2, y2
    if firstAxis == "v" then
        if fromA then fx, fy = _anchorEdgePoint(canvas, fromA, x1, y1, "y", sy) end
        if toA then tx, ty = _anchorEdgePoint(canvas, toA, x2, y2, "x", -sx) end
        return { { fx, fy, fx, ty }, { fx, ty, tx, ty } }
    end
    if fromA then fx, fy = _anchorEdgePoint(canvas, fromA, x1, y1, "x", sx) end
    if toA then tx, ty = _anchorEdgePoint(canvas, toA, x2, y2, "y", -sy) end
    return { { fx, fy, tx, fy }, { tx, fy, tx, ty } }
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
-- connected" symbol for two crossing wires) and leaving a gap entirely
-- over each {lo, hi} zone in bundledRanges — a bundledRanges zone means
-- some OTHER call has already drawn (or will draw) a _drawWireBundleSegment
-- there covering this same stretch, so this wire's own solo line has
-- nothing left to do over that zone. Zones don't have to span the whole
-- segment (see _computeWirePlans: two wires may only share part of their
-- path), so any distance not covered by a bundle zone draws solo as
-- normal. No offset/lane math at all — every segment always draws at its
-- own true, unmoved position; see _computeWirePlans' own comment for why
-- that's enough now that overlapping wires draw as one shared bundle
-- instead of being nudged apart into separate parallel lines. lineFn
-- (optional): called as lineFn(ax, ay, bx, by) to draw each straight stretch,
-- in place of a plain love.graphics.line. trimLo/trimHi (optional): how far
-- in from the start/end to stop drawing, where a pipe's rounded bend (see
-- _pipes.corners) takes over.
local function _drawSegmentWithHopsAndGaps(x1, y1, x2, y2, hopDistances, bundledRanges, zoom, lineFn, trimLo, trimHi)
    zoom = zoom or 1
    local hopRadiusPx = _WIRE_CROSS_HOP_RADIUS_PX * zoom
    local horiz = (y1 == y2)
    local dirX, dirY
    if horiz then dirX, dirY = (x2 > x1) and 1 or -1, 0
    else          dirX, dirY = 0, (y2 > y1) and 1 or -1 end
    local length = horiz and math.abs(x2 - x1) or math.abs(y2 - y1)
    bundledRanges = bundledRanges or {}

    local function pointAt(d) return x1 + dirX * d, y1 + dirY * d end

    local cuts = { 0, length }
    for _, r in ipairs(bundledRanges) do
        if r.lo > 0 and r.lo < length then table.insert(cuts, r.lo) end
        if r.hi > 0 and r.hi < length then table.insert(cuts, r.hi) end
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

    local drawLo, drawHi = trimLo or 0, length - (trimHi or 0)
    for i = 1, #cuts - 1 do
        local a, b = cuts[i], cuts[i + 1]
        local whole = a >= drawLo - 0.01 and b <= drawHi + 0.01
        a, b = math.max(a, drawLo), math.min(b, drawHi)
        if b - a <= 0.01 then goto nextPiece end
        local mid = (a + b) / 2
        local inBundle = false
        for _, r in ipairs(bundledRanges) do
            if mid >= r.lo and mid <= r.hi then inBundle = true break end
        end
        if not inBundle then
            local inHop = nil
            for _, hr in ipairs(hopRanges) do
                if mid >= hr.lo and mid <= hr.hi then inHop = hr end
            end
            if inHop and not whole then
                -- A hop cut into by a bend: leave it out rather than draw half an arc.
            elseif inHop then
                local cxp, cyp = pointAt(inHop.center)
                local startAngle, endAngle
                if horiz then startAngle, endAngle = math.pi, math.pi * 2
                else          startAngle, endAngle = math.pi / 2, math.pi * 1.5 end
                love.graphics.arc("line", "open", cxp, cyp, hopRadiusPx, startAngle, endAngle)
            else
                local ax, ay = pointAt(a)
                local bx, by = pointAt(b)
                if lineFn then lineFn(ax, ay, bx, by) else love.graphics.line(ax, ay, bx, by) end
            end
        end
        ::nextPiece::
    end

    -- This segment's true start/end, for _drawWirePlanSegments/
    -- _drawClampedOrthogonalLine below to patch the sharp-corner cap LÖVE
    -- otherwise leaves where two separately-drawn segments meet.
    local startX, startY = pointAt(0)
    local endX, endY = pointAt(length)
    return startX, startY, endX, endY
end

-- Draws one straight axis-aligned BUNDLE segment (x1,y1)-(x2,y2) as a
-- single line the same width as a normal wire, with
-- each DISTINCT entry in colors (in creation order of the wires sharing this
-- stretch) repeating as a diagonal band along it — the "twisted cable" look
-- replacing the old per-wire parallel-lane offset (see _computeWirePlans'
-- own comment): instead of N separate thin lines nudged apart, every wire
-- sharing this exact stretch draws as ONE shared line instead, with
-- color alone (not position) showing what feeds it. Wires sharing a color
-- share one band, so every band is exactly _WIRE_BUNDLE_STRIPE_LEN_PX (1 grid
-- unit) long: 3 wires in 2 colors draw color1,color2,color1,... rather than
-- color1,color1,color2,... and 2 wires in one color draw solid. Bands sit on
-- the world grid (see _drawGrid), not the segment's own start, so the pattern
-- runs unbroken across adjacent bundle zones along one line and doesn't crawl
-- on pan/zoom. Each end is cut square, half the line's width past its
-- endpoint so a bundle's bends meet with a full corner. isHalo: drawing the
-- powered-glow copy (captured at the bundle draw site) — wider, and only the bands that glow.
local function _drawWireBundleSegment(canvas, x1, y1, x2, y2, colors, isHalo)
    local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    if length < 0.01 or #colors == 0 then return end

    local distinct = {}
    for _, c in ipairs(colors) do
        local seen = false
        for _, d in ipairs(distinct) do
            if d[1] == c[1] and d[2] == c[2] and d[3] == c[3] and (d[4] or 1) == (c[4] or 1) then seen = true break end
        end
        if not seen then table.insert(distinct, c) end
    end

    local thickness = _pipes.fluidWidth(canvas) * (isHalo and _glow.WIRE_WIDTH or 1)
    local stripeLen = _WIRE_BUNDLE_STRIPE_LEN_PX * canvas.zoom
    local halfT = thickness / 2
    local capLo, capHi = -halfT, length + halfT

    -- Keeps the part of a convex polygon on one side of the vertical line
    -- x = bound (sign 1 keeps x >= bound, sign -1 keeps x <= bound).
    local function clip(pts, bound, sign)
        local out = {}
        for i = 1, #pts - 1, 2 do
            local ax, ay = pts[i], pts[i + 1]
            local bx, by = pts[(i + 1) % #pts + 1], pts[(i + 2) % #pts + 1]
            local aIn, bIn = (ax - bound) * sign >= 0, (bx - bound) * sign >= 0
            if aIn then out[#out + 1] = ax; out[#out + 1] = ay end
            if aIn ~= bIn then
                out[#out + 1] = bound
                out[#out + 1] = ay + (by - ay) * (bound - ax) / (bx - ax)
            end
        end
        return out
    end

    -- World-grid distance of (x1,y1) along this segment's own axis.
    local along = (y1 == y2) and (x1 - canvas.x - canvas.panX) or (y1 - canvas.y - canvas.panY)
    local band = math.floor((along - thickness) / stripeLen)
    love.graphics.push()
    love.graphics.translate(x1, y1)
    love.graphics.rotate(math.atan2(y2 - y1, x2 - x1))
    while true do
        local d = band * stripeLen - along
        if d >= length + thickness then break end
        local pts = clip(clip({
            d + halfT, -halfT,
            d + stripeLen + halfT, -halfT,
            d + stripeLen - halfT, halfT,
            d - halfT, halfT,
        }, capLo, 1), capHi, -1)
        local c = distinct[(band % #distinct) + 1]
        if #pts >= 6 and (not isHalo or _glow.applies(canvas, c[1], c[2], c[3])) then
            love.graphics.setColor(c[1], c[2], c[3], c[4] or 1)
            love.graphics.polygon("fill", pts)
        end
        band = band + 1
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.pop()
end

-- Patches the sharp-corner butt-cap gap LÖVE's line rendering otherwise
-- leaves where two separately-drawn segments of one bend meet — every
-- segment now always draws at its own true, unmoved position (see
-- _computeWirePlans' own comment on why bundling replaced per-wire lane
-- offsets), so prevEnd and the next segment's start are always the exact
-- same point; this just squares off that one shared joint.
local function _bridgeSegmentJoint(prevEndX, prevEndY, prevVertical, startX, startY, halfW)
    local cornerX = prevVertical and prevEndX or startX
    local cornerY = prevVertical and startY or prevEndY
    -- One connected 3-point polyline, not two separate love.graphics.line()
    -- calls, so its own internal corner joins cleanly; each of its two
    -- junctions against the segments' own separate line draws still gets
    -- the same small square patch _drawSegmentWithHopsAndGaps's own
    -- butt-cap notch needs (see its comment).
    love.graphics.line(prevEndX, prevEndY, cornerX, cornerY, startX, startY)
    love.graphics.rectangle("fill", prevEndX - halfW, prevEndY - halfW, halfW * 2, halfW * 2)
    love.graphics.rectangle("fill", startX - halfW, startY - halfW, halfW * 2, halfW * 2)
end

-- Draws every segment of a precomputed wire plan (see _computeWirePlans),
-- applying that wire's own hop points and bundle gaps per segment (see
-- _drawSegmentWithHopsAndGaps) — the bundle zones themselves are drawn
-- separately, once per bundle, by _drawWireBundleSegment.
-- radius (optional): a pipe's bend radius (see _pipes.corners), rounding each
-- bend instead of squaring it off.
local function _drawWirePlanSegments(plan, zoom, radius)
    local halfW = love.graphics.getLineWidth() / 2
    local corners = radius and _pipes.corners(plan, radius)
    local prevEndX, prevEndY, prevVertical
    for idx, seg in ipairs(plan.segments) do
        local before, after = corners and corners[idx - 1], corners and corners[idx]
        local startX, startY, endX, endY = _drawSegmentWithHopsAndGaps(
            seg[1], seg[2], seg[3], seg[4], plan.hopDistances[idx], plan.bundledRanges[idx], zoom, nil,
            before and before.r, after and after.r)
        if before then
            _pipes.drawBend(before)
        elseif idx > 1 then
            _bridgeSegmentJoint(prevEndX, prevEndY, prevVertical, startX, startY, halfW)
        end
        prevEndX, prevEndY = endX, endY
        prevVertical = (seg[1] == seg[3])
    end
end

--------------------------------------------------------------------------------
-- PIPE CONNECTORS: while enabled, a connector is three equal-width lines side
-- by side — two gray walls that never take a color, around the usual wire line
-- as the fluid inside. All walls draw in a pass of their own before any fluid,
-- so where pipes meet the fluid runs unbroken from one into the other.
--------------------------------------------------------------------------------
_pipes.WIDTH_MULT = 3                -- full pipe width, as a multiple of a wire's width
_pipes.WALL_GRAY_DARK = 90 / 255     -- wall shade per theme: distinct from an empty pipe's
_pipes.WALL_GRAY_LIGHT = 170 / 255   -- gray fluid (see _themedPaletteColor) against either backdrop
_pipes.BEND_RADIUS_MULT = 1          -- a bend's centerline radius, as a multiple of the full pipe width
_pipes.BEND_PX_PER_SEGMENT = 3     -- device pixels of outer wall per straight piece of a bend
_pipes.EDGE_FRACTION = 0.12        -- dark outer edge, as a fraction of the full pipe width
_pipes.LIGHT_FRACTION = 0.55       -- lit inner band, as a fraction of each wall
_pipes.STREAK_FRACTION = 0.35      -- shine down the fluid, as a fraction of its width
_pipes.STREAK_ALPHA = 0.22

-- A pipe's widths on this canvas, each a whole, odd number of device pixels so
-- that, centered on a device pixel (see _pipes.snapPlans), both edges land on
-- pixel boundaries: crisp, and the two walls always equal. Layers, outermost
-- first: pipe (dark edge), body (wall), light (lit inner band of each wall),
-- fluid, streak (shine; nil when the fluid is too thin for one). nil for plain
-- wires, which keep their own widths.
function _pipes.widths(canvas)
    if not canvas.pipeConnectors then return nil end
    local dpi = love.graphics.getDPIScale()
    local cached = canvas._pipeWidths
    if cached and cached.zoom == canvas.zoom and cached.dpi == dpi then return cached end
    local function odd(px) return math.max(1, 2 * math.floor(px / 2) + 1) end
    local wirePx = _WIRE_WIDTH_PX * canvas.zoom * dpi
    local fluidPx = odd(wirePx)
    local wallPx = math.max(1, math.floor(wirePx * (_pipes.WIDTH_MULT - 1) / 2 + 0.5))
    local pipePx = fluidPx + 2 * wallPx
    local edgePx = math.max(1, math.floor(pipePx * _pipes.EDGE_FRACTION + 0.5))
    local bodyPx = pipePx - 2 * edgePx
    local lightPx = fluidPx + 2 * math.max(1, math.floor(wallPx * _pipes.LIGHT_FRACTION + 0.5))
    if lightPx >= bodyPx then lightPx = nil end
    local streakPx = fluidPx >= 3 and odd(fluidPx * _pipes.STREAK_FRACTION) or nil
    cached = { zoom = canvas.zoom, dpi = dpi, pipe = pipePx / dpi, body = bodyPx / dpi,
        light = lightPx and lightPx / dpi, fluid = fluidPx / dpi, streak = streakPx and streakPx / dpi }
    canvas._pipeWidths = cached
    return cached
end

-- The width a connector's fluid (or a plain wire) draws at.
function _pipes.fluidWidth(canvas)
    local widths = _pipes.widths(canvas)
    return widths and widths.fluid or _WIRE_WIDTH_PX * canvas.zoom
end

-- The radius a pipe's bends are drawn at on this canvas, or nil for plain wires,
-- which keep their square schematic corners.
function _pipes.bendRadius(canvas)
    local widths = _pipes.widths(canvas)
    return widths and widths.pipe * _pipes.BEND_RADIUS_MULT
end

-- How many straight pieces a bend of radius r sweeping `sweep` radians needs at
-- the current line width, so its outer wall stays smooth at any zoom.
function _pipes.bendSegments(r, sweep)
    local outer = r + love.graphics.getLineWidth() / 2
    local px = outer * math.abs(sweep) * love.graphics.getDPIScale()
    return math.max(6, math.min(96, math.ceil(px / _pipes.BEND_PX_PER_SEGMENT)))
end

-- Moves every pipe path of plans and bundles onto device-pixel centers (see
-- _pipes.widths), in place. Idempotent, and every shared corner moves the same
-- way, so runs stay joined and square to the grid.
function _pipes.snapPlans(plans, bundles)
    local snap = gdsGui_general_pixelCenter
    for _, plan in pairs(plans) do
        for _, seg in ipairs(plan.segments) do
            seg[1], seg[2], seg[3], seg[4] = snap(seg[1]), snap(seg[2]), snap(seg[3]), snap(seg[4])
        end
        plan._corners = nil
    end
    for _, bundle in ipairs(bundles) do
        bundle.x1, bundle.y1, bundle.x2, bundle.y2 = snap(bundle.x1), snap(bundle.y1), snap(bundle.x2), snap(bundle.y2)
    end
end

-- The rounded bend at each corner of plan, keyed by the index of the segment
-- coming into it: {r, cx, cy, a1, a2, x1, y1, x2, y2}, an arc of radius r about
-- cx,cy from angle a1 to a2, leaving that segment at x1,y1 and joining the next
-- at x2,y2 (r back from the corner along each). Each r is the full radius when
-- both segments have room for it, else as much as half the shorter one allows.
-- A corner inside a bundle (whose square walls are drawn whole, see
-- _pipes.drawAllWalls) or with no real turn gets none, and keeps the square
-- join. Kept on the plan, which only changes when the wiring does.
function _pipes.corners(plan, radius)
    if plan._corners and plan._cornersRadius == radius then return plan._corners end
    local corners = {}
    local segs = plan.segments
    local function lengthOf(seg) return math.abs(seg[3] - seg[1]) + math.abs(seg[4] - seg[2]) end
    local function bundledAt(idx, d)
        for _, range in ipairs(plan.bundledRanges[idx] or {}) do
            if d >= range.lo - 0.01 and d <= range.hi + 0.01 then return true end
        end
        return false
    end
    for k = 1, #segs - 1 do
        local a, b = segs[k], segs[k + 1]
        local lenA, lenB = lengthOf(a), lengthOf(b)
        local r = math.min(radius, lenA / 2, lenB / 2)
        if r > 0.5 and not bundledAt(k, lenA) and not bundledAt(k + 1, 0) then
            local d1x, d1y = (a[3] - a[1]) / lenA, (a[4] - a[2]) / lenA
            local d2x, d2y = (b[3] - b[1]) / lenB, (b[4] - b[2]) / lenB
            if math.abs(d1x * d2y - d1y * d2x) > 0.5 then
                local px, py = a[3], a[4]
                local x1, y1 = px - d1x * r, py - d1y * r
                local cx, cy = x1 + d2x * r, y1 + d2y * r
                local a1 = math.atan2(-d2y, -d2x)
                local sweep = math.atan2(d1y, d1x) - a1
                if sweep > math.pi then sweep = sweep - 2 * math.pi elseif sweep < -math.pi then sweep = sweep + 2 * math.pi end
                corners[k] = { r = r, cx = cx, cy = cy, a1 = a1, a2 = a1 + sweep,
                    x1 = x1, y1 = y1, x2 = px + d2x * r, y2 = py + d2y * r }
            end
        end
    end
    plan._corners, plan._cornersRadius = corners, radius
    return corners
end

-- One bend (see _pipes.corners), in the current color and line width.
function _pipes.drawBend(bend)
    love.graphics.arc("line", "open", bend.cx, bend.cy, bend.r, bend.a1, bend.a2, _pipes.bendSegments(bend.r, bend.a2 - bend.a1))
end

-- noun: what the menus call a connector on this canvas ("PIPE", "DUCT"), or nil
-- for plain wires.
function gdsGui_schematic_setPipeConnectors(canvasName, noun)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.pipeConnectors = noun ~= nil
    canvas.connectorNoun = noun
end

-- Names every kind of element on this canvas whose outline can be redrawn
-- (see _shapePoly) — kinds: an array of {shapeType, componentType} pairs
-- (e.g. a system with both a reshapable TANK ("rect"/"source") and a
-- reshapable MANIFOLD ("rect"/"path") passes both), or nil/{} for none.
-- Matched by kind rather than stored on each element, so items placed
-- before this existed (or before a given pair was added here) qualify too.
function gdsGui_schematic_setReshapableKind(canvasName, kinds)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.reshapableKind = (kinds and #kinds > 0) and kinds or nil
end

-- Public wrapper over _elementGridFootprintFrac above (gridW/gridH in whole
-- grid units -> the 0-1 content-fraction w/h addElement expects), for an
-- app-layer feature that needs to size or resize an element to a GENERATED
-- shape's own grid footprint after placement — _GRID_SPACING_PX itself, and
-- the canvas-dimension math this depends on, are both private to this file.
-- 0, 0 if canvasName doesn't name a live canvas.
function gdsGui_schematic_gridUnitsToFrac(canvasName, gridW, gridH)
    local canvas = _findCanvas(canvasName)
    if not canvas then return 0, 0 end
    return _elementGridFootprintFrac(canvas, gridW, gridH)
end

function _pipes.noun(canvas)
    return canvas.connectorNoun or "WIRE"
end

function _pipes.addLabel(canvas)
    return "ADD " .. _pipes.noun(canvas)
end

-- The yellow/magenta emphasis around a selected connector. Magenta once the
-- hold has unlocked its direction-drag; yellow means a tap opens the menu, or
-- hold to unlock that. Once magenta (rebending mode) on a LIQUID pipe (see
-- _pipes.isLiquid) specifically, a plain tap no longer reopens the menu —
-- see gdsGui_schematic_released's "wireDirection" branch — it cycles
-- w.gravityDirection instead, same spot a drag there changes the bend.
function _pipes.drawSelection(canvas, plan, width)
    _selection.drawConnector(canvas, plan, width)
end

function _pipes.setWallColor(shade)
    local gray = globApp.themeIsDark == false and _pipes.WALL_GRAY_LIGHT or _pipes.WALL_GRAY_DARK
    gray = math.min(1, gray * (shade or 1))
    love.graphics.setColor(gray, gray, gray, 1)
end

-- The wall layers that give a pipe its rounded, tube-like look, outermost first:
-- {width key in _pipes.widths, shade of the wall gray}. Each covers the middle
-- of the one before, leaving a dark rim at the outer edge and a lit band beside
-- the fluid.
_pipes.WALL_LAYERS = { { "pipe", 0.55 }, { "body", 1 }, { "light", 1.35 } }

-- Every pipe's walls, one layer at a time across all of them (see
-- _pipes.WALL_LAYERS), so where pipes meet, one's dark rim never paints over
-- another's wall. A selected pipe's emphasis goes underneath all of it.
-- isVisible(plan) and isRectVisible(x, y, w, h) cull what's off-screen.
function _pipes.drawAllWalls(canvas, plans, bundles, isVisible, isRectVisible)
    local widths = _pipes.widths(canvas)
    local radius = _pipes.bendRadius(canvas)
    local selected = canvas.selectedWireId and plans[canvas.selectedWireId]
    if selected and isVisible(selected) then
        _pipes.drawSelection(canvas, selected, widths.pipe)
    end
    for _, layer in ipairs(_pipes.WALL_LAYERS) do
        local width = widths[layer[1]]
        if width then
            _pipes.setWallColor(layer[2])
            love.graphics.setLineWidth(width)
            for _, w in ipairs(canvas.wires) do
                local plan = plans[w.id]
                if plan and isVisible(plan) then _drawWirePlanSegments(plan, canvas.zoom, radius) end
            end
            -- A bundle zone's walls are cut square half a pipe past each end, so
            -- bends in a bundle meet with a full corner.
            local half = width / 2
            for _, bundle in ipairs(bundles) do
                local loX, hiX = math.min(bundle.x1, bundle.x2), math.max(bundle.x1, bundle.x2)
                local loY, hiY = math.min(bundle.y1, bundle.y2), math.max(bundle.y1, bundle.y2)
                if isRectVisible(loX, loY, hiX - loX, hiY - loY) then
                    love.graphics.rectangle("fill", loX - half, loY - half, hiX - loX + half * 2, hiY - loY + half * 2)
                end
            end
        end
    end
    love.graphics.setLineWidth(1)
end

-- Draws e.pipeRoutes (an array of routes, each an array of 2-3 {x,y} points,
-- -0.5..0.5 fractions of e's own box — same convention a terminal's x,y
-- already use) as real pipe-styled segments: the same wall/body/light
-- layers, the same widths (_pipes.widths), the same rounded bends
-- (_pipes.bendRadius/_drawWirePlanSegments' own corner handling) and center
-- streak every actual drawn connector gets — rather than _shapePoly.drawLocal's
-- single flat fill + outline every other custom-outline element (a reshaped
-- tank, say) uses. e.shapeType == "pipeTree" routes _drawElement here instead
-- (see that dispatch) — e.shapePoints, if e also has one (MANIFOLD's own
-- does, from _shapePoly.pointsFromRows), stays only for hit-testing/
-- selection footprint; it's never what gets drawn for a pipeTree element.
-- Global, not local (called from _drawElement, textually well before
-- _drawWirePlanSegments/_pipes.widths/WALL_LAYERS exist as locals/fields at
-- THIS point in the file — a global sidesteps that ordering, same reason
-- _shapePoly/_wirePath's own public entry points are globals too).
-- isHalo: only the fluid core itself glows, same "leave walls/outlines out
-- of the halo" rule every other isHalo branch in this file already follows.
function _drawPipeTreeSymbol(canvas, e, ex, ey, ew, eh, r, g, b, a, isHalo)
    local widths = _pipes.widths(canvas)
    local radius = _pipes.bendRadius(canvas)
    love.graphics.push()
    love.graphics.translate(ex + ew / 2, ey + eh / 2)
    love.graphics.rotate(math.rad(e.rotation or 0))
    local function planFor(route)
        local segs, hops, bundled = {}, {}, {}
        for i = 1, #route - 1 do
            segs[i] = { route[i][1] * ew, route[i][2] * eh, route[i + 1][1] * ew, route[i + 1][2] * eh }
            hops[i], bundled[i] = {}, {}
        end
        return { segments = segs, hopDistances = hops, bundledRanges = bundled }
    end
    if not isHalo then
        for _, layer in ipairs(_pipes.WALL_LAYERS) do
            local width = widths[layer[1]]
            if width then
                _pipes.setWallColor(layer[2])
                love.graphics.setLineWidth(width)
                for _, route in ipairs(e.pipeRoutes) do
                    _drawWirePlanSegments(planFor(route), canvas.zoom, radius)
                end
            end
        end
    end
    love.graphics.setColor(r, g, b, a)
    love.graphics.setLineWidth(isHalo and (widths.fluid * _glow.WIRE_WIDTH) or widths.fluid)
    for _, route in ipairs(e.pipeRoutes) do
        _drawWirePlanSegments(planFor(route), canvas.zoom, radius)
    end
    if not isHalo and widths.streak then
        love.graphics.setColor(1, 1, 1, _pipes.STREAK_ALPHA)
        love.graphics.setLineWidth(widths.streak)
        for _, route in ipairs(e.pipeRoutes) do
            _drawWirePlanSegments(planFor(route), canvas.zoom, radius)
        end
    end
    -- FLOWING FLUID (see that section header, further down this file),
    -- extended to a MANIFOLD's own tubes: each route inherits the moving/
    -- direction state of whichever wire is actually attached to its own
    -- port -- route i is always terminal i (see _manifoldShapeAndTerminals
    -- in main.lua) -- so "a manifold is treated as a pipe" (model/fluid.lua's
    -- own leak-feature comment) extends to how it looks mid-flow too, not
    -- just whether it leaks. A port with no wire on it, or whose wire isn't
    -- moving, just stays plain. isHalo skips this, same as every other
    -- glow-only pass in this file -- the dashes glow along with the fluid
    -- core they're drawn over, not separately.
    if not isHalo and _pipes.isLiquid(canvas) and canvas.mode == "control" then
        for i, route in ipairs(e.pipeRoutes) do
            local wire, atFromEnd
            for _, w in ipairs(canvas.wires) do
                if w.fromElementId == e.id and w.fromTerminal == i then wire, atFromEnd = w, true; break end
                if w.toElementId == e.id and w.toTerminal == i then wire, atFromEnd = w, false; break end
            end
            if wire and wire.fluidMoving then
                local dir = wire.pumpedDirection or wire.gravityDirection
                if dir then
                    -- A wire's own "forward" means fromElementId -> toElementId.
                    -- When this port IS that from-end, forward already means
                    -- fluid leaving the manifold through it; when this port is
                    -- the wire's TO-end instead, forward means fluid arriving
                    -- through it.
                    local outOfManifold = (atFromEnd and dir == "forward") or (not atFromEnd and dir == "reverse")
                    -- Every tube route's own points run spine (route[1]) ->
                    -- port (route[#route]), so "leaving the manifold" is
                    -- route-forward (t increasing) there -- but the trunk
                    -- (route 1, terminal 1) is stored the OPPOSITE way, port
                    -- (route[1]) -> spine (route[#route]) -- see
                    -- _manifoldShapeAndTerminals in main.lua, whose trunk
                    -- terminal sits at this shape's x = -0.5 edge while every
                    -- tube's own sits at x = 0.5 -- so "leaving" is
                    -- route-REVERSE there instead. Missing this is exactly
                    -- what made a manifold's own inlet (route 1) animate
                    -- backward while every outflow tube animated correctly.
                    local portAtStart = (i == 1)
                    local routeDir = (outOfManifold ~= portAtStart) and "forward" or "reverse"
                    _pipes.drawFlowDashes(canvas, { pumpedDirection = routeDir }, planFor(route), widths.fluid, r, g, b)
                end
            end
        end
    end
    love.graphics.setLineWidth(1)
    love.graphics.pop()
end

-- A thin shine down the middle of every pipe's fluid, bundles included, so the
-- fluid reads as filling a round pipe. Drawn after the fluid and before the
-- drained stretch (_pipes.drawEmptiedRun), which covers it where the pipe is empty.
function _pipes.drawAllStreaks(canvas, plans, bundles, isVisible, isRectVisible)
    local widths = _pipes.widths(canvas)
    if not widths or not widths.streak then return end
    local radius = _pipes.bendRadius(canvas)
    love.graphics.setColor(1, 1, 1, _pipes.STREAK_ALPHA)
    love.graphics.setLineWidth(widths.streak)
    for _, w in ipairs(canvas.wires) do
        local plan = plans[w.id]
        if plan and isVisible(plan) then _drawWirePlanSegments(plan, canvas.zoom, radius) end
    end
    for _, bundle in ipairs(bundles) do
        local loX, hiX = math.min(bundle.x1, bundle.x2), math.max(bundle.x1, bundle.x2)
        local loY, hiY = math.min(bundle.y1, bundle.y2), math.max(bundle.y1, bundle.y2)
        if isRectVisible(loX, loY, hiX - loX, hiY - loY) then
            love.graphics.line(bundle.x1, bundle.y1, bundle.x2, bundle.y2)
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setLineWidth(1)
end

--------------------------------------------------------------------------------
-- GRAVITY DIRECTION: a LIQUID pipe (connectorNoun == "PIPE" — HYDRAULIC/FUEL,
-- not a gas DUCT) can mark which way gravity drives the fluid through that
-- particular run, shown in edit mode as a single open chevron (>) near the
-- pipe's output end pointing that way (see _pipes.drawDirectionArrow) — or no
-- arrow at all for "none" (e.g. a run that sits level, so gravity alone
-- doesn't move anything through it). Hidden once in control mode, where the
-- FLOWING FLUID streaks are the only indication fluid is moving, and which
-- way. Not fed into the solver: the same "nil means automatic/unset"
-- convention as w.directionOverride, just for flow direction
-- instead of bend shape. Cycled by a plain tap once rebending/direction mode has already
-- unlocked on the wire (gdsGui_schematic_released's own "wireDirection"
-- branch), not a menu row — meant to be as quick and repeatable as the
-- direction-drag itself while routing a run of pipe.
--------------------------------------------------------------------------------

-- w.gravityDirection: nil ("none"), "forward" (fromElementId -> toElementId)
-- or "reverse" (toElementId -> fromElementId).
function _pipes.isLiquid(canvas)
    return canvas.pipeConnectors and canvas.connectorNoun == "PIPE"
end

-- none -> forward -> reverse -> none -> ...
function _pipes.cycleGravityDirection(w)
    if w.gravityDirection == nil then
        w.gravityDirection = "forward"
    elseif w.gravityDirection == "forward" then
        w.gravityDirection = "reverse"
    else
        w.gravityDirection = nil
    end
end


-- plan's path as it's drawn, rounded bends included (see _pipes.corners), in
-- order from its first segment to its last: straight runs {x1, y1, x2, y2,
-- seg, segOffset} and bends {bend}, each with len and d0 (distance along the
-- path where it starts). seg and segOffset place a run within its segment, for
-- the segment's own hop and bundle distances. Returns pieces, total length.
-- Kept on the plan, which only changes when the wiring or view does.
function _pipes.pathPieces(canvas, plan)
    local radius = _pipes.bendRadius(canvas) or 0
    if plan._pieces and plan._piecesRadius == radius then return plan._pieces, plan._piecesTotal end
    local corners = _pipes.corners(plan, radius)
    local pieces, total = {}, 0
    for i, seg in ipairs(plan.segments) do
        local before, after = corners[i - 1], corners[i]
        local x1, y1 = before and before.x2 or seg[1], before and before.y2 or seg[2]
        local x2, y2 = after and after.x1 or seg[3], after and after.y1 or seg[4]
        local len = math.abs(x2 - x1) + math.abs(y2 - y1)
        table.insert(pieces, { x1 = x1, y1 = y1, x2 = x2, y2 = y2, seg = i, segOffset = before and before.r or 0,
            len = len, d0 = total })
        total = total + len
        if after then
            local bendLen = after.r * math.abs(after.a2 - after.a1)
            table.insert(pieces, { bend = after, len = bendLen, d0 = total })
            total = total + bendLen
        end
    end
    plan._pieces, plan._piecesRadius, plan._piecesTotal = pieces, radius, total
    return pieces, total
end

-- The point t along piece (0 to piece.len), and the unit direction the path
-- runs there.
function _pipes.pointOnPiece(piece, t)
    local bend = piece.bend
    if bend then
        local sweep = bend.a2 - bend.a1
        local angle = bend.a1 + sweep * (piece.len > 0 and t / piece.len or 0)
        local turn = sweep >= 0 and 1 or -1
        return bend.cx + math.cos(angle) * bend.r, bend.cy + math.sin(angle) * bend.r,
            -math.sin(angle) * turn, math.cos(angle) * turn
    end
    local dx, dy = piece.x2 - piece.x1, piece.y2 - piece.y1
    local f = piece.len > 0 and t / piece.len or 0
    local ux, uy = 0, 0
    if piece.len > 0 then ux, uy = dx / piece.len, dy / piece.len end
    return piece.x1 + dx * f, piece.y1 + dy * f, ux, uy
end

-- Draws the part of piece from t0 to t1 as one stroke, at the current line width.
function _pipes.strokePiece(piece, t0, t1)
    local bend = piece.bend
    if bend then
        local sweep = bend.a2 - bend.a1
        local a0 = bend.a1 + sweep * t0 / piece.len
        local a1 = bend.a1 + sweep * t1 / piece.len
        love.graphics.arc("line", "open", bend.cx, bend.cy, bend.r, a0, a1, _pipes.bendSegments(bend.r, a1 - a0))
    else
        local ax, ay = _pipes.pointOnPiece(piece, t0)
        local bx, by = _pipes.pointOnPiece(piece, t1)
        love.graphics.line(ax, ay, bx, by)
    end
end

--------------------------------------------------------------------------------
-- DIRECTION ARROW: in edit (design) mode, a single solid-tipped ">" mark near
-- the output end of a LIQUID pipe that's been marked with a gravity direction
-- (w.gravityDirection, set by _pipes.cycleGravityDirection) -- not drawn at all
-- for "none", or once in control mode, where the FLOWING FLUID streaks (see
-- below) take over as the stand-in for "which way, and is it actually moving".
--------------------------------------------------------------------------------
_pipes.CHEVRON_THICKNESS = 0.28   -- stroke, as a fraction of the fluid's width
_pipes.ARROW_INSET_PX = _GRID_SPACING_PX  -- world units of clear pipe between the output end and the arrow's tip

-- One ">"-shaped mark centered at x,y pointing along unit tx,ty: two arms of
-- stroke `thick` meeting at a rounded tip, reaching halfSpan either side of
-- the path and `depth` along it.
function _pipes.drawChevron(x, y, tx, ty, halfSpan, depth, thick)
    local px, py = -ty, tx
    local tipX, tipY = x + tx * depth / 2, y + ty * depth / 2
    local backX, backY = x - tx * depth / 2, y - ty * depth / 2
    local h = thick / 2
    for side = -1, 1, 2 do
        local endX, endY = backX + px * halfSpan * side, backY + py * halfSpan * side
        local ax, ay = tipX - endX, tipY - endY
        local alen = math.sqrt(ax * ax + ay * ay)
        if alen > 0 then
            local nx, ny = -ay / alen * h, ax / alen * h
            love.graphics.polygon("fill", endX + nx, endY + ny, tipX + nx, tipY + ny, tipX - nx, tipY - ny, endX - nx, endY - ny)
        end
        love.graphics.circle("fill", endX, endY, h, 10)
    end
    love.graphics.circle("fill", tipX, tipY, h, 10)
end

-- The point insetPx world units clear of whichever end of pieces (see
-- _pipes.pathPieces) fluid moving as dir ("forward": path start -> end,
-- "reverse": end -> start) is heading OUT of, and the unit tangent pointing
-- that same outward direction -- nil if the path is zero-length or its
-- tangent there is degenerate. Shared by the direction arrow above (design
-- mode) and the leak spray below (control mode): both mark the exact same
-- "this is the downstream end" spot, just with a different symbol.
function _pipes.outputPoint(pieces, total, dir, insetPx, zoom)
    if total <= 0 then return nil end
    local backward = (dir == "reverse")
    local inset = math.min(total / 2, insetPx * zoom)
    local d = backward and inset or (total - inset)
    local index = 1
    while pieces[index + 1] and pieces[index + 1].d0 <= d do index = index + 1 end
    local piece = pieces[index]
    local x, y, tx, ty = _pipes.pointOnPiece(piece, d - piece.d0)
    if backward then tx, ty = -tx, -ty end
    if tx == 0 and ty == 0 then return nil end
    return x, y, tx, ty
end

-- The pipe's own direction arrow (see the section header), one grid unit
-- short of whichever end the fluid is marked to run toward so its tip clears
-- the joint with the element there.
function _pipes.drawDirectionArrow(canvas, w, plan)
    if canvas.mode ~= "design" then return end
    local dir = w.gravityDirection
    if not dir then return end
    local widths = _pipes.widths(canvas)
    local pieces, total = _pipes.pathPieces(canvas, plan)
    if total <= 0 then return end
    local dpi = love.graphics.getDPIScale()
    local onePx = 1 / dpi
    local thick = math.max(onePx, math.floor(widths.fluid * _pipes.CHEVRON_THICKNESS * dpi + 0.5) / dpi)
    -- A dark rim one device pixel wide, when the fluid is wide enough to hold it.
    local rim = onePx
    local halfSpan = widths.fluid / 2 - thick / 2 - rim
    if halfSpan < thick then
        rim = 0
        halfSpan = widths.fluid / 2 - thick / 2
    end
    if halfSpan <= 0 then return end
    local depth = halfSpan * 1.1
    -- 3x the size this whole mark would otherwise be, uniformly (span, depth
    -- AND stroke thickness all scale together so it stays the same shape,
    -- just bigger) -- a deliberately oversized, easy-to-spot gravity-flow
    -- indicator rather than one sized to just clear the fluid's own width.
    halfSpan, depth, thick = halfSpan * 3, depth * 3, thick * 3
    local x, y, tx, ty = _pipes.outputPoint(pieces, total, dir, _pipes.ARROW_INSET_PX, canvas.zoom)
    if not x then return end
    -- Magenta (not a theme-neutral gray like every other pipe/wire mark in
    -- this file) so the gravity-flow indicator reads as its own distinct
    -- annotation rather than blending in as part of the pipe itself — same
    -- two-tone rim/fill shape as before, just a deep magenta rim around a
    -- bright magenta fill instead of near-black around near-white.
    local dark = { 0.35, 0, 0.35 }
    local light = { 1, 0, 1 }
    if rim > 0 then
        love.graphics.setColor(dark[1], dark[2], dark[3], 0.6)
        _pipes.drawChevron(x, y, tx, ty, halfSpan, depth, thick + rim * 2)
    end
    love.graphics.setColor(light[1], light[2], light[3], 1)
    _pipes.drawChevron(x, y, tx, ty, halfSpan, depth, thick)
    love.graphics.setColor(1, 1, 1, 1)
end

-- The emptied stretch of a draining pipe (w.fluidPercent, set by the app; nil is
-- full), laid over its fluid in canvas.emptyPipeColor from whichever end gravity
-- is pulling away from, so the fluid visibly runs out toward the far end.
function _pipes.drawEmptiedRun(canvas, w, plan)
    if not w.fluidPercent or w.fluidPercent >= 100 or not canvas.emptyPipeColor then return end
    local pieces, total = _pipes.pathPieces(canvas, plan)
    local c = canvas.emptyPipeColor
    love.graphics.setColor(_themedPaletteColor(c[1], c[2], c[3], c[4] or 1))
    love.graphics.setLineWidth(_pipes.fluidWidth(canvas))
    local empty = total * (1 - w.fluidPercent / 100)
    -- Measured from the end gravity pulls away from: the path's start, or its
    -- end for a reversed run.
    local lo, hi = 0, empty
    if w.gravityDirection == "reverse" then lo, hi = total - empty, total end
    for _, piece in ipairs(pieces) do
        local t0 = math.max(0, lo - piece.d0)
        local t1 = math.min(piece.len, hi - piece.d0)
        if t1 - t0 > 0.01 then _pipes.strokePiece(piece, t0, t1) end
    end
    love.graphics.setLineWidth(1)
end

--------------------------------------------------------------------------------
-- FLOWING FLUID: while fluid runs through a liquid pipe (w.fluidMoving, set by
-- the app, in control mode), the same marching contour dashes as a wire's own
-- rebend/direction mode once move mode unlocks on it (see _selection's own
-- "DASH_PX"/"DASH_SPEED" and gdsGui_schematic_released's "wireDirection"
-- branch) travel along its length, in the direction fluid is actually moving
-- (w.pumpedDirection, or w.gravityDirection when nothing's pumping). Colored
-- with the pipe's own resolved fluid color (gdsGui_schematic_resolveDisplayColor)
-- rather than the selection accent, so it reads as "this fluid is moving," not
-- "this pipe is selected." An earlier attempt here (a shader-driven shimmer)
-- read as a distracting diagonal light beam rather than a flow cue and was
-- dropped; _pipes.drawAllStreaks (a STATIC center highlight giving a pipe its
-- round-tube look) is unrelated and stays.
--------------------------------------------------------------------------------

-- Marching dashes along w's own path, in the color r,g,b (the pipe's own
-- resolved fluid color), traveling toward w.pumpedDirection/gravityDirection.
-- Same dash length/speed as _selection.drawConnector's unlocked-wire dashes,
-- just colored and timed by flow instead of a hold-to-unlock gesture.
function _pipes.drawFlowDashes(canvas, w, plan, width, r, g, b)
    local dir = w.pumpedDirection or w.gravityDirection
    local pieces, total = _pipes.pathPieces(canvas, plan)
    local dash = _selection.DASH_PX
    local speed = (dir == "reverse") and -_selection.DASH_SPEED or _selection.DASH_SPEED
    local offset = (_selection.now() * speed) % (dash * 2)
    love.graphics.setColor(r, g, b, 0.9)
    love.graphics.setLineWidth(width + 4)
    local start = offset - dash * 2
    while start < total do
        local lo, hi = math.max(0, start), math.min(total, start + dash)
        for _, piece in ipairs(pieces) do
            local t0, t1 = math.max(0, lo - piece.d0), math.min(piece.len, hi - piece.d0)
            if t1 - t0 > 0.01 then _pipes.strokePiece(piece, t0, t1) end
        end
        start = start + dash * 2
    end
    love.graphics.setLineWidth(1)
end

-- The marching dashes (see above) over every liquid pipe with fluid running
-- through it. Drawn over the fluid, before its shine and the drained stretch,
-- which covers the dashes where the pipe is empty.
function _pipes.drawAllFlow(canvas, plans, isVisible, signature)
    if not _pipes.isLiquid(canvas) or canvas.mode ~= "control" then return end
    local width = _pipes.fluidWidth(canvas)
    for _, w in ipairs(canvas.wires) do
        local dir = w.pumpedDirection or w.gravityDirection
        local plan = plans[w.id]
        if w.fluidMoving and dir and plan and isVisible(plan) then
            local r, g, b = gdsGui_schematic_resolveDisplayColor(canvas.name, "wire", w.id, signature)
            _pipes.drawFlowDashes(canvas, w, plan, width, r, g, b)
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

--------------------------------------------------------------------------------
-- LEAK SPRAY: while fluid runs through a liquid pipe whose downstream end has
-- nowhere to go (w.leaking, set by model/fluid.lua's step() -- an open valve,
-- check valve, or now-unconnected manifold port, with no sink or tank beyond
-- it to receive the fluid; see that module's own header comment), a small
-- burst of droplets flings outward from that open end, the control-mode
-- stand-in for the direction arrow's design-mode "which way" -- here it's
-- "and it's going nowhere but out."
--------------------------------------------------------------------------------
_pipes.LEAK_DROPLETS = 6     -- reference count, at LEAK_REFERENCE_PSI
_pipes.LEAK_SPEED = 1.2      -- droplet cycles a second, AT LEAK_SPEED_MAX_PSI (full speed, the cap) --
                               -- see the speed calculation in drawLeakSprayAt, which uses this and
                               -- the next 2 constants instead of the general intensity/LEAK_REFERENCE_PSI
                               -- below (droplet count/size's own reference PSI is tuned much lower,
                               -- matching a typical pump -- speed instead keeps climbing well past that,
                               -- all the way out to a genuinely high-pressure pump before it maxes out).
_pipes.LEAK_SPEED_MAX_PSI = 50  -- the cap: speed climbs with pressure up to here and no higher beyond it
_pipes.LEAK_SPEED_MIN_FACTOR = 0.2 -- slowest the cycle ever runs (at/near zero pressure) -- low enough
                                    -- to read as a lazy trickle, but never literally 0 (frozen droplets
                                    -- look broken, not just slow).
_pipes.LEAK_SPEED_TRANSITION_SECONDS = 3 -- how long a pressure change (the pump switching on/off, say)
                                          -- takes to fully settle into the leak's new speed, eased
                                          -- rather than snapped -- see drawLeakSprayAt's own state table.
_pipes._leakSpeedState = {} -- seedKey -> {speedFactor, phaseBase, lastTime}, persisted across frames
                             -- so the eased transition above (and the phase it drives) has something
                             -- to continue from each time a leak is drawn again.
_pipes.LEAK_RANGE_MULT = 3   -- how far a droplet travels, in multiples of the pipe's own fluid
                               -- width -- a fixed reach every leak gets regardless of its own
                               -- pressure (that's what LEAK_SPEED above is for instead).
_pipes.LEAK_RADIUS_MULT = 0.6 -- droplet size, same units
_pipes.LEAK_WIDTH_MULT = 2    -- total lateral spread, in multiples of the pipe's own fluid width --
                               -- a narrow, straight-out jet rather than a widening cone
_pipes.LEAK_REFERENCE_PSI = 15 -- the pressure LEAK_DROPLETS above is tuned for -- a typical pump's own
                               -- PSI (GRAVITY_LEAK_BASELINE_PSI, in model/fluid.lua, is well below this
                               -- on purpose -- gravity alone is the weak case)
_pipes.LEAK_MIN_INTENSITY = 0.6 -- floor/ceiling on the pressure-driven scale-up/down below. The floor
                                 -- is deliberately not much below 1 -- a pipe's own fluid width is only
                                 -- a few px on this app's small canvas, so a leak scaled much smaller
                                 -- than "reference" stops reading as a spray at all, not just a weaker one.
_pipes.LEAK_MAX_INTENSITY = 2.0
-- A small fraction of ARROW_INSET_PX (the direction arrow's own clearance,
-- tuned so its chevron tip doesn't visually collide with the joint) -- a
-- leak isn't a symbol that needs that much clearance, it IS the opening,
-- so it belongs right at the dead end's own literal position (e.g. a check
-- valve's output port) instead of visibly starting a little way upstream
-- of it. Not exactly 0: pathPieces' corner-rounding can leave a genuinely
-- zero-length final piece sitting right at that literal endpoint, which
-- has no defined tangent (see pointOnPiece) -- outputPoint then returns
-- nil and the whole spray silently never draws. Any positive inset lands
-- in the piece just before that zero-length one instead.
_pipes.LEAK_INSET_PX = 0.5

-- The leak spray (see the section header) for one pipe, colored r,g,b (the
-- pipe's own resolved fluid color). Droplet paths are deterministic from the
-- wire's own id and droplet index rather than math.random, so every canvas
-- drawing the same wire at the same moment in time draws the identical
-- spray, with no per-wire particle state to keep between frames.
-- One droplet's outline: a point trailing behind (away from the direction
-- of travel, tx,ty) smoothly rounding into a 240-degree arc on the leading
-- side -- a teardrop, not a circle, so a droplet in flight reads as moving
-- the way it's actually moving instead of a generic dot. cx,cy is the
-- droplet's own center; px,py is the unit vector perpendicular to tx,ty
-- (same one the lateral jitter above is built from).
-- Not `local` -- this file is already at Lua's 200-top-level-local ceiling
-- (see CLAUDE.md); every other constant/helper added after that point
-- already follows this same pattern.
_TEARDROP_SEGMENTS = 8
function _teardropVertices(cx, cy, tx, ty, px, py, radius)
    local tailLen = radius * 1.8
    local verts = { cx - tx * tailLen, cy - ty * tailLen }
    for i = 0, _TEARDROP_SEGMENTS do
        local a = math.rad(-120 + 240 * i / _TEARDROP_SEGMENTS)
        local u, v = math.cos(a) * radius, math.sin(a) * radius
        verts[#verts + 1] = cx + tx * u + px * v
        verts[#verts + 1] = cy + ty * u + py * v
    end
    return verts
end

-- The droplet rendering shared by both leak sources (see the section
-- header): a dead-end pipe (_pipes.drawLeakSpray, below) and an element's
-- own disconnected port (_pipes.drawOpenPortLeaks, further down) -- same
-- narrow straight jet either way, just anchored/aimed differently.
-- seedKey makes each spray's droplet paths deterministic (see the section
-- header's own comment) without requiring a wire id specifically.
function _pipes.drawLeakSprayAt(canvas, seedKey, x, y, tx, ty, leakPressure, r, g, b)
    local fluidW = _pipes.fluidWidth(canvas)
    -- How hard the fluid is actually being pushed scales the spray itself,
    -- not just its look -- a weak gravity trickle sprays less/shorter than
    -- a pump-driven blast (leakPressure, set in model/fluid.lua's step()
    -- for a pipe leak -- real PSI for a pump-driven leak, a flat baseline
    -- for gravity alone; 0, an open port's own case -- nothing's actually
    -- pushing an unconnected port -- clamps to that same gravity floor;
    -- nil would instead read as LEAK_REFERENCE_PSI's own full intensity).
    local intensity = math.max(_pipes.LEAK_MIN_INTENSITY, math.min(_pipes.LEAK_MAX_INTENSITY,
        (leakPressure or _pipes.LEAK_REFERENCE_PSI) / _pipes.LEAK_REFERENCE_PSI))
    local dropletCount = math.max(2, math.floor(_pipes.LEAK_DROPLETS * intensity + 0.5))
    -- DISTANCE is fixed (LEAK_RANGE_MULT fluid-widths, always) -- pressure
    -- instead speeds the animation up or slows it down (see the phase
    -- computation in the droplet loop below), rather than changing how far
    -- it reaches.
    local range = fluidW * _pipes.LEAK_RANGE_MULT
    local radius = fluidW * _pipes.LEAK_RADIUS_MULT
    local onePx = 1 / love.graphics.getDPIScale()
    local now = _selection.now()
    local halfWidth = fluidW * _pipes.LEAK_WIDTH_MULT / 2
    local px, py = -ty, tx -- unit vector perpendicular to the spray's own direction
    -- Pressure speeds the cycle up or slows it down -- its OWN scale, not
    -- the general intensity above (droplet count/size there is tuned
    -- against a typical pump's PSI; speed instead keeps climbing until a
    -- genuinely high-pressure LEAK_SPEED_MAX_PSI, the cap). Distance itself
    -- stays fixed at LEAK_RANGE_MULT regardless either way (see range, above).
    local targetSpeedFactor = math.max(_pipes.LEAK_SPEED_MIN_FACTOR, math.min(1,
        (leakPressure or _pipes.LEAK_SPEED_MAX_PSI) / _pipes.LEAK_SPEED_MAX_PSI))
    -- Eased toward targetSpeedFactor, taking LEAK_SPEED_TRANSITION_SECONDS
    -- to fully settle on ANY pressure change (a pump switching on/off, say)
    -- -- a fixed DURATION, not a fixed rate, so a small change doesn't
    -- finish almost instantly while only a big one actually takes the full
    -- 3 seconds. Persisted per leak (seedKey) across frames, since a
    -- transition needs to remember where it started and when. Phase itself
    -- is accumulated the same way (state.phaseBase += speed * dt) rather
    -- than the simpler now * speed used before this -- speed now changes
    -- continuously while easing, and now * speed jumps discontinuously
    -- (by an amount proportional to now, the app's whole running time)
    -- the instant speed itself changes, which an accumulator sidesteps.
    local state = _pipes._leakSpeedState[seedKey]
    if not state then
        state = { speedFactor = targetSpeedFactor, fromFactor = targetSpeedFactor,
            toFactor = targetSpeedFactor, transitionStart = now, phaseBase = 0, lastTime = now }
        _pipes._leakSpeedState[seedKey] = state
    end
    local dt = math.max(0, now - state.lastTime)
    state.lastTime = now
    if targetSpeedFactor ~= state.toFactor then
        -- Pressure just changed -- start a fresh 3-second transition from
        -- wherever the displayed speed actually sits right now (mid-
        -- transition or already settled, either way), not from the old
        -- target, so a pressure change arriving before the previous one
        -- finished still eases smoothly instead of jumping to catch up.
        state.fromFactor = state.speedFactor
        state.toFactor = targetSpeedFactor
        state.transitionStart = now
    end
    local t = math.min(1, (now - state.transitionStart) / _pipes.LEAK_SPEED_TRANSITION_SECONDS)
    state.speedFactor = state.fromFactor + (state.toFactor - state.fromFactor) * t
    local speed = _pipes.LEAK_SPEED * state.speedFactor
    state.phaseBase = (state.phaseBase + speed * dt) % 1
    for i = 1, dropletCount do
        local seed = ((string.byte(seedKey, 1) or 1) * 7 + i * 31) % 97 / 97
        local phase = (state.phaseBase + i / dropletCount) % 1
        -- Straight line the whole way along tx,ty (no droop toward world-
        -- down, no angular fan-out either, so it stays a narrow jet
        -- instead of a widening cone) -- each droplet's own small, FIXED
        -- sideways offset (not growing with phase) is what gives the jet
        -- its ~LEAK_WIDTH_MULT-fluid-widths-wide body.
        local lateral = (seed - 0.5) * 2 * halfWidth
        local dropX = x + tx * range * phase + px * lateral
        local dropY = y + ty * range * phase + py * lateral
        -- A bright rim one device pixel wide keeps a droplet readable
        -- against a pipe/tank of a similar hue right behind it (the usual
        -- case -- a leak sprays from the very thing it's leaking out of),
        -- the same rim-for-contrast trick the chevron/direction-arrow
        -- drawing uses.
        local dropRadius = math.max(2, radius * (1 - phase * 0.5))
        love.graphics.setColor(1, 1, 1, (1 - phase) * 0.6)
        love.graphics.polygon("fill", _teardropVertices(dropX, dropY, tx, ty, px, py, dropRadius + onePx))
        love.graphics.setColor(r, g, b, (1 - phase) * 0.9)
        love.graphics.polygon("fill", _teardropVertices(dropX, dropY, tx, ty, px, py, dropRadius))
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- A directionalGate (check valve) element's own OUTPUT-side point and
-- outward unit direction -- the "forward" side its own rotation faces (see
-- model/graph.lua's _directionalGateForwardVector and this file's own
-- _drawDiodeSymbol, both using the same "rotation 0 points +x" convention).
-- A check valve that's the dead end of a leaking wire realistically leaks
-- PAST its own seal, out this side, not back out the pipe feeding its
-- other (input) side -- see _pipes.drawLeakSpray below, the only caller.
function _pipes.directionalGateOutputPoint(canvas, e)
    local _, _, ew, eh = _elementPixelRect(canvas, e)
    local cx, cy = _elementCenter(canvas, e)
    local rad = math.rad(e.rotation or 0)
    local fx, fy = math.cos(rad), math.sin(rad)
    -- Projects onto whichever half-extent the forward axis actually runs
    -- along, so a tall/narrow or wide/short valve still lands its output
    -- point right at its own edge instead of overshooting a non-square one.
    local half = math.abs(fx) >= math.abs(fy) and ew / 2 or eh / 2
    return cx + fx * half, cy + fy * half, fx, fy
end

function _pipes.drawLeakSpray(canvas, w, plan, r, g, b)
    local dir = w.pumpedDirection or w.gravityDirection
    if not dir then return end
    -- The dead end is whichever side of the wire fluid is heading TOWARD
    -- (forward: the "to" element; reverse: the "from" one) -- if that's a
    -- check valve, spray from its own output side (above) instead of the
    -- wire's own literal end, which sits at the valve's INPUT side.
    local deadEndId = (dir == "reverse") and w.fromElementId or w.toElementId
    local gate = deadEndId and _findElement(canvas, deadEndId)
    local x, y, tx, ty
    if gate and gate.componentType == "directionalGate" then
        x, y, tx, ty = _pipes.directionalGateOutputPoint(canvas, gate)
    else
        local pieces, total = _pipes.pathPieces(canvas, plan)
        x, y, tx, ty = _pipes.outputPoint(pieces, total, dir, _pipes.LEAK_INSET_PX, canvas.zoom)
    end
    if not x then return end
    _pipes.drawLeakSprayAt(canvas, w.id, x, y, tx, ty, w.leakPressure, r, g, b)
end

-- Whether element e has any terminal with no wire plugged into it at all --
-- the shared test both _pipes.drawOpenPortLeaks below (which also needs to
-- know WHICH terminal, to spray from it) and the public
-- gdsGui_schematic_elementHasOpenPort wrapper (which only needs yes/no --
-- model/fluid.lua reads that, via the app layer, to let a leaking tank
-- still accept gravity/pump inflow at 100% instead of blocking it like a
-- genuinely sealed full tank) run.
-- Not `local` -- this file is already at Lua's 200-top-level-local ceiling
-- (see CLAUDE.md).
function _elementHasOpenTerminal(canvas, e)
    if not e.terminals then return false end
    local connected = {}
    for _, w in ipairs(canvas.wires) do
        if w.fromElementId == e.id and w.fromTerminal then connected[w.fromTerminal] = true end
        if w.toElementId == e.id and w.toTerminal then connected[w.toTerminal] = true end
    end
    for i in ipairs(e.terminals) do
        if not connected[i] then return true end
    end
    return false
end

-- Public wrapper for the app layer (main.lua's own _fluidFlowInputs, not
-- this file, which must stay domain-agnostic about what an "open port"
-- means to the fluid MODEL specifically -- see _elementHasOpenTerminal's
-- own comment).
function gdsGui_schematic_elementHasOpenPort(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    local e = canvas and _findElement(canvas, elementId)
    return e ~= nil and _elementHasOpenTerminal(canvas, e)
end

-- A tank (or any other fluid-holding source) with a port that has no wire
-- plugged into it at all -- not a dead-end PIPE (see the section header
-- and _pipes.drawLeak/drawLeakSpray above, model/fluid.lua's own leak
-- detection), just an opening in the element's own body with nothing
-- connected -- sprays the same way, aimed along the straight line from the
-- element's own center through that port (not the port's stored exit
-- normal -- a port off the element's own centerline would otherwise aim
-- parallel to the edge instead of outward through the opening itself).
function _pipes.drawOpenPortLeaks(canvas, signature)
    if not _pipes.isLiquid(canvas) or canvas.mode ~= "control" then return end
    for _, e in ipairs(canvas.elements) do
        if e.componentType == "source" and e.shapeType and e.terminals and (e.fillPercent or 100) > 0 then
            local connected, tankPsi = {}, 0
            for _, w in ipairs(canvas.wires) do
                if w.fromElementId == e.id and w.fromTerminal then connected[w.fromTerminal] = true end
                if w.toElementId == e.id and w.toTerminal then connected[w.toTerminal] = true end
                -- Whether a pump wired to this tank (through one of its
                -- OTHER, connected ports) is actually switched on right now,
                -- and if so its own real PSI -- its own position's LABEL,
                -- not w.pumpedDirection (set only once the model has
                -- actually resolved a full delivery route for it, which a
                -- pump switched on but routing its flow through a different
                -- port, or into an already-full tank with nowhere to put
                -- it, would leave unset even though the pump itself is
                -- genuinely running and genuinely pressurizing this port
                -- too) -- so a pump control sitting OFF leaves tankPsi at 0
                -- exactly as the open port itself has no pump of its own.
                -- A tank's own fill level does NOT factor in here (it did
                -- before -- see model/fluid.lua's own "no tank pressure
                -- concept" comment on the FUEL TANK catalog entry -- a
                -- full-but-unpumped tank isn't actually under any more
                -- pressure than an empty one in this model, so its leak
                -- shouldn't look stronger either). The highest PSI of
                -- possibly several pumps wins.
                if w.fromElementId == e.id or w.toElementId == e.id then
                    local otherId = (w.fromElementId == e.id) and w.toElementId or w.fromElementId
                    local pump = _findControl(canvas, otherId)
                    if pump and pump.componentType == "source" then
                        local label = pump.positions and pump.positions[(pump.detentIndex or 0) + 1]
                        if label ~= "OFF" and label ~= "CLOSED" then
                            local psi = tonumber(pump.voltage)
                            if psi and psi > tankPsi then tankPsi = psi end
                        end
                    end
                end
            end
            local cx, cy = _elementCenter(canvas, e)
            for i in ipairs(e.terminals) do
                if not connected[i] then
                    local px, py = _terminals.point(canvas, e, i)
                    if px then
                        local dx, dy = px - cx, py - cy
                        local len = math.sqrt(dx * dx + dy * dy)
                        if len > 0.001 then
                            local tx, ty = dx / len, dy / len
                            local r, g, b = gdsGui_schematic_resolveDisplayColor(canvas.name, "element", e.id, signature)
                            -- An open port has no pump/wire of its own to
                            -- carry a real PSI -- 0 (same as a dead-end
                            -- PIPE leak with nothing pushing it -- see
                            -- drawLeakSpray above) unless a pump elsewhere
                            -- on this same tank is actually running right
                            -- now (tankPsi, above), in which case that
                            -- pump's own real PSI applies here too.
                            _pipes.drawLeakSprayAt(canvas, e.id .. i, px, py, tx, ty, tankPsi, r, g, b)
                        end
                    end
                end
            end
        end
    end
end

-- The leak spray, drawn only in control mode and only on a pipe step()
-- actually marked w.leaking.
function _pipes.drawLeak(canvas, w, plan, signature)
    if canvas.mode ~= "control" or not w.leaking then return end
    local r, g, b = gdsGui_schematic_resolveDisplayColor(canvas.name, "wire", w.id, signature)
    _pipes.drawLeakSpray(canvas, w, plan, r, g, b)
end

-- Draws an orthogonal connector line between two anchors' centers, clamped
-- to each anchor's own edge, with no hop/bundle treatment — used by the
-- live wire-drag preview and the (unrelated-to-other-wires) selection
-- highlight pass, neither of which need the cross-wire analysis below.
local function _drawClampedOrthogonalLine(canvas, segments)
    local halfW = love.graphics.getLineWidth() / 2
    local prevEndX, prevEndY, prevVertical
    for idx, seg in ipairs(segments) do
        local startX, startY, endX, endY =
            _drawSegmentWithHopsAndGaps(seg[1], seg[2], seg[3], seg[4], nil, nil, canvas.zoom)
        -- Same bend-corner joint bridge as _drawWirePlanSegments above —
        -- see its comment.
        if idx > 1 then
            _bridgeSegmentJoint(prevEndX, prevEndY, prevVertical, startX, startY, halfW)
        end
        prevEndX, prevEndY = endX, endY
        prevVertical = (seg[1] == seg[3])
    end
end

-- Precomputes, for every wire on the canvas, the crossing-hop points and/or
-- bundle zones needed to render the two conventional "these are not
-- necessarily one single connection" cues:
--   - ANY two (or more) segments — from any wires, not just ones sharing
--     both anchors — that run along the exact same line and overlap draw
--     as ONE shared "twisted bundle" line (see _drawWireBundleSegment)
--     over just the overlapping stretch, instead of each wire separately
--     drawing its own line there. A classic duplicate connector (same two
--     anchors on both wires) is just the special case where the overlap
--     happens to span each wire's entire path;
--   - any OTHER pair of wires whose paths cross at a true interior point
--     gets a small arc hop on the later-added wire (by creation order in
--     canvas.wires), the standard "not electrically connected" symbol.
-- Unlike that crossing hop, a bundle zone needs no per-wire lane ranking
-- or offset math at all — every wire sharing a stretch just contributes
-- its own color band to the ONE shared line drawn there, in creation
-- order (see _drawWireBundleSegment) — the simplification over this
-- module's previous approach of nudging every overlapping wire into its
-- own separate parallel lane. A wire that's simultaneously in a bundle
-- AND crosses some unrelated third wire still gets both treatments
-- correctly (see _drawSegmentWithHopsAndGaps).
-- Detects whether anything _computeWirePlans' result depends on (every
-- anchor's position/rotation, the wire list itself, and the view transform)
-- changed since the last call, so gdsGui_schematic_draw can skip the
-- expensive O(wires^2 * segments^2) crossing/bundle analysis below on
-- frames where nothing actually changed (the common case: a canvas just
-- sitting on screen). Compares live values directly against scalars cached
-- in canvas._wpSig (reused across frames, mutated in place) rather than
-- rebuilding and comparing a signature string every frame — every dependency
-- is still scanned every single call (so a mid-drag position change is still
-- caught the instant it happens), this just avoids the table/string
-- allocation that scan used to cost on the common "nothing changed" case.
-- Correct across any mutation path (add/remove/undo/reload/...) without
-- having to hook each one individually, since it only ever compares values,
-- never relies on being told something changed.
local function _wirePlansChanged(canvas)
    local sig = canvas._wpSig
    if not sig then
        sig = { elements = {}, controls = {}, wires = {} }
        canvas._wpSig = sig
    end
    local changed = false

    if sig.zoom ~= canvas.zoom or sig.panX ~= canvas.panX or sig.panY ~= canvas.panY
       or sig.w ~= canvas.w or sig.h ~= canvas.h or sig.x ~= canvas.x or sig.y ~= canvas.y then
        changed = true
        sig.zoom, sig.panX, sig.panY, sig.w, sig.h, sig.x, sig.y =
            canvas.zoom, canvas.panX, canvas.panY, canvas.w, canvas.h, canvas.x, canvas.y
    end

    local elems = sig.elements
    if #elems ~= #canvas.elements then changed = true end
    for i, e in ipairs(canvas.elements) do
        local se = elems[i]
        if not se then se = {}; elems[i] = se end
        -- shapePoints: a reshaped element's wires stop at its real outline (see
        -- _shapePoly.edgePoint), and each edit stores a brand-new table.
        -- terminals: likewise, a moved port (_shapePoly.movePortTo) is a new
        -- terminals table, since its pipes keep the same terminal index.
        if se.id ~= e.id or se.x ~= e.x or se.y ~= e.y or se.rotation ~= e.rotation or se.shapePoints ~= e.shapePoints
           or se.terminals ~= e.terminals then
            changed = true
            se.id, se.x, se.y, se.rotation, se.shapePoints, se.terminals = e.id, e.x, e.y, e.rotation, e.shapePoints, e.terminals
        end
    end
    for i = #canvas.elements + 1, #elems do elems[i] = nil end

    local ctrls = sig.controls
    if #ctrls ~= #canvas.controls then changed = true end
    for i, c in ipairs(canvas.controls) do
        local sc = ctrls[i]
        if not sc then sc = {}; ctrls[i] = sc end
        -- rotation: a terminal-bearing control's wires attach at points
        -- that spin with it (see _terminals.point).
        if sc.id ~= c.id or sc.x ~= c.x or sc.y ~= c.y or sc.rotation ~= c.rotation then
            changed = true
            sc.id, sc.x, sc.y, sc.rotation = c.id, c.x, c.y, c.rotation
        end
    end
    for i = #canvas.controls + 1, #ctrls do ctrls[i] = nil end

    local wires = sig.wires
    if #wires ~= #canvas.wires then changed = true end
    for i, w in ipairs(canvas.wires) do
        local sw = wires[i]
        if not sw then sw = {}; wires[i] = sw end
        if sw.id ~= w.id or sw.fromElementId ~= w.fromElementId or sw.toElementId ~= w.toElementId
           or sw.directionOverride ~= w.directionOverride or sw.waypoints ~= w.waypoints
           or sw.fromTerminal ~= w.fromTerminal or sw.toTerminal ~= w.toTerminal then
            changed = true
            sw.id, sw.fromElementId, sw.toElementId, sw.directionOverride, sw.waypoints =
                w.id, w.fromElementId, w.toElementId, w.directionOverride, w.waypoints
            sw.fromTerminal, sw.toTerminal = w.fromTerminal, w.toTerminal
        end
    end
    for i = #canvas.wires + 1, #wires do wires[i] = nil end

    return changed
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

-- A finished wire's own routed segments between its two (already looked
-- up) anchors, attaching at its fromTerminal/toTerminal where it has them.
-- With a user-drawn path (w.waypoints, see _wirePath) it runs through each
-- of its points in turn, each a corner: the leg out of a point starts square
-- to the way the path came in, and goes straight on when the next stop lies
-- dead ahead. Also returns the legs, {first, last} segment indices of each
-- stretch between stops (start, each point, end), for EDIT PATH's handles.
function _terminals.wireSegments(canvas, w, fromE, toE)
    local x1, y1, fromA, fromAxis = _terminals.wireEnd(canvas, fromE, w.fromTerminal)
    local x2, y2, toA, toAxis = _terminals.wireEnd(canvas, toE, w.toTerminal)
    if not w.waypoints or #w.waypoints == 0 then
        local segments = _terminals.segments(canvas, x1, y1, fromA, fromAxis, x2, y2, toA, toAxis, _wireForceAxis(w))
        return segments, { { first = 1, last = #segments } }
    end
    local stops = { { x1, y1, fromA, fromAxis } }
    for _, point in ipairs(w.waypoints) do
        local px, py = _toPixel(canvas, point.x, point.y)
        table.insert(stops, { px, py })
    end
    table.insert(stops, { x2, y2, toA, toAxis })
    local segments, legs = {}, {}
    for k = 1, #stops - 1 do
        local a, b = stops[k], stops[k + 1]
        local prev = segments[#segments]
        local forceAxis = prev and ((prev[2] == prev[4]) and "v" or "h") or nil
        -- A bend point leaves on that axis as if it were a port's exit, so the
        -- leg can't start back along the stretch it arrived on, even into a
        -- port or element that would otherwise pick the first axis itself.
        local fromAxis = a[4] or forceAxis
        local first = #segments + 1
        for _, seg in ipairs(_terminals.segments(canvas, a[1], a[2], a[3], fromAxis, b[1], b[2], b[3], b[4], forceAxis)) do
            table.insert(segments, seg)
        end
        legs[k] = { first = first, last = #segments }
    end
    return segments, legs
end

--------------------------------------------------------------------------------
-- USER-DRAWN CONNECTOR PATHS (EDIT PATH on a connector's edit menu, any
-- system). A connector's path is its list of bend points, w.waypoints, each
-- {x, y} in canvas fractions snapped to the grid like an element's position;
-- nil for the automatic route. While canvas.pathEdit = {wireId} is set:
-- drag a point to move it, drag a "+" at the middle of any stretch to put a
-- new point there, tap a point to remove it, tap anywhere else to finish.
-- A global table, like _shapePoly, since this file is at Lua's 200-local
-- ceiling.
--------------------------------------------------------------------------------
_wirePath = {}
_wirePath.POINT_RADIUS_PX = 7     -- a bend point's handle
_wirePath.INSERT_RADIUS_PX = 6    -- a "+" handle
_wirePath.HIT_PX = 24             -- how far off a handle a touch still takes it
_wirePath.MIN_LEG_PX = 36         -- stretches shorter than this on screen get no "+"

-- A copy of w's points, to change and then store as a new table (the wire
-- route cache spots an edit by the table changing, see _wirePlansChanged).
function _wirePath.copy(w)
    local points = {}
    for i, p in ipairs(w.waypoints or {}) do points[i] = { x = p.x, y = p.y } end
    return points
end

-- The handles EDIT PATH shows for w, routed as plan: {kind = "point", index}
-- at each bend point, then {kind = "insert", index} at the middle of each
-- stretch long enough for one, index being where a new point goes in w.waypoints.
function _wirePath.handles(canvas, w, plan)
    local handles = {}
    for i, p in ipairs(w.waypoints or {}) do
        local px, py = _toPixel(canvas, p.x, p.y)
        table.insert(handles, { kind = "point", index = i, x = px, y = py })
    end
    for k, leg in ipairs(plan.legs or {}) do
        local total = 0
        for s = leg.first, leg.last do
            local seg = plan.segments[s]
            total = total + math.abs(seg[3] - seg[1]) + math.abs(seg[4] - seg[2])
        end
        if total >= _wirePath.MIN_LEG_PX then
            local remaining = total / 2
            for s = leg.first, leg.last do
                local seg = plan.segments[s]
                local len = math.abs(seg[3] - seg[1]) + math.abs(seg[4] - seg[2])
                if remaining <= len and len > 0 then
                    local t = remaining / len
                    table.insert(handles, { kind = "insert", index = k,
                        x = seg[1] + (seg[3] - seg[1]) * t, y = seg[2] + (seg[4] - seg[2]) * t })
                    break
                end
                remaining = remaining - len
            end
        end
    end
    return handles
end

-- w's route as it stands now, {segments, legs}, worked out fresh. nil if an end is missing.
function _wirePath.plan(canvas, w)
    local fromE, toE = _findAnchor(canvas, w.fromElementId), _findAnchor(canvas, w.toElementId)
    if not (fromE and toE) then return nil end
    local segments, legs = _terminals.wireSegments(canvas, w, fromE, toE)
    return { segments = segments, legs = legs }
end

-- The handle of the wire being edited nearest x,y, within reach; bend points
-- win over "+" handles. nil if none.
function _wirePath.hitHandle(canvas, w, x, y)
    local plan = _wirePath.plan(canvas, w)
    if not plan then return nil end
    local best, bestDistSq
    local reach = _wirePath.HIT_PX * _wirePath.HIT_PX
    for _, handle in ipairs(_wirePath.handles(canvas, w, plan)) do
        local distSq = (handle.x - x) ^ 2 + (handle.y - y) ^ 2
        if distSq <= reach then
            local better = not best or (handle.kind == "point" and best.kind ~= "point")
                or (handle.kind == best.kind and distSq < bestDistSq)
            if better then best, bestDistSq = handle, distSq end
        end
    end
    return best
end

-- Puts w's point `index` at the grid point nearest pixel x,y. True if it moved.
function _wirePath.movePoint(canvas, w, index, x, y)
    local fx, fy = _snapToGrid(canvas, _toFraction(canvas, x, y))
    local current = w.waypoints and w.waypoints[index]
    if not current or (math.abs(current.x - fx) < 1e-9 and math.abs(current.y - fy) < 1e-9) then return false end
    local points = _wirePath.copy(w)
    points[index] = { x = fx, y = fy }
    w.waypoints = points
    return true
end

function _wirePath.start(canvasName, wireId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pathEdit = { wireId = wireId }
    canvas.selectedWireId = wireId
end

function _wirePath.finish(canvas)
    canvas.pathEdit = nil
    canvas.selectedWireId = nil
end

-- A press while EDIT PATH is on (see gdsGui_schematic_pressed): takes a
-- handle, or finishes editing. Nothing changes until the press is known to be a
-- drag or a tap, so one that becomes a pinch leaves the path alone: a "+"
-- puts its new point in once dragged (or tapped), a bend point moves once
-- dragged and goes when tapped. Each is one undo step.
function _wirePath.press(canvas, touchId, x, y)
    local edit = canvas.pathEdit
    local w = _findWire(canvas, edit.wireId)
    local handle = w and _wirePath.hitHandle(canvas, w, x, y)
    if not handle then
        _wirePath.finish(canvas)
        return
    end
    canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
    gdsGui_haptics_feedback("selection")
    if handle.kind == "insert" then
        edit.index, edit.pendingInsert = nil, { index = handle.index, x = handle.x, y = handle.y }
    else
        edit.index, edit.pendingInsert = handle.index, nil
    end
    -- Remembered past commitPress (which clears pendingInsert once the drag
    -- actually starts) so release() can tell "a '+' that got dragged onto
    -- another element/control" (branchAt below) apart from "an existing
    -- bend point dragged" (never branches — see release's own comment).
    edit.wasInsert = (handle.kind == "insert")
    edit.grabX, edit.grabY = handle.x - x, handle.y - y
    canvas.focusTouchId = touchId
    canvas.dragKind = "pathPoint"
    canvas.dragMoved = false
    canvas.dragStartX, canvas.dragStartY = x, y
end

-- Commits the pressed handle's undo step and, for a "+", puts its new point
-- in where the "+" sat; edit.index is then that point.
function _wirePath.commitPress(canvas, w)
    local edit = canvas.pathEdit
    if canvas._pendingDragUndoSnapshot then
        _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
        canvas._pendingDragUndoSnapshot = nil
    end
    local insert = edit.pendingInsert
    if insert then
        local fx, fy = _snapToGrid(canvas, _toFraction(canvas, insert.x, insert.y))
        local points = _wirePath.copy(w)
        table.insert(points, insert.index, { x = fx, y = fy })
        w.waypoints = points
        edit.index, edit.pendingInsert = insert.index, nil
        gdsGui_haptics_feedback("light")
        return true
    end
    return false
end

-- The drag of a bend point, snapping to the grid with a tick at each step.
function _wirePath.move(canvas, x, y)
    local edit = canvas.pathEdit
    local w = _findWire(canvas, edit.wireId)
    if not w then return end
    if not canvas.dragMoved and (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                                 math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
        canvas.dragMoved = true
        _wirePath.commitPress(canvas, w)
    end
    if not canvas.dragMoved or not edit.index then return end
    if _wirePath.movePoint(canvas, w, edit.index, x + edit.grabX, y + edit.grabY) then
        gdsGui_haptics_feedback("selection")
    end
end

-- Mirrors the direct wire-drag release handler's own 2-terminal/fixed-
-- terminal wire cap (its local twoTerminalAnchorAtWireLimit, further down
-- this file) — branchAt below never goes through that handler's own
-- wireTool state at all, so it re-checks the same thing itself here:
-- landing on an anchor with no free terminal left (every one of its own
-- named terminals already has a wire — a DIODE/EJECTOR/battery-style fixed
-- port list — or, for a 2-position gate/directionalGate with no terminals
-- list of its own, its flat 2-wire cap) would otherwise just silently
-- share a terminal two wires are meant to use one at a time.
function _wirePath.anchorAtWireLimit(canvas, anchorId)
    local ctrl = _findControl(canvas, anchorId)
    local elem = not ctrl and _findElement(canvas, anchorId)
    local terms = (ctrl or elem) and (ctrl or elem).terminals
    if terms then
        for i = 1, #terms do
            local used = false
            for _, w in ipairs(canvas.wires) do
                if (w.fromElementId == anchorId and w.fromTerminal == i)
                   or (w.toElementId == anchorId and w.toTerminal == i) then used = true; break end
            end
            if not used then return false end
        end
        return true
    end
    local isTwoTerminal = (ctrl and ctrl.componentType == "gate" and ctrl.numDetents == 2)
        or (elem and elem.componentType == "directionalGate")
    if not isTwoTerminal then return false end
    local count = 0
    for _, w in ipairs(canvas.wires) do
        if w.fromElementId == anchorId or w.toElementId == anchorId then count = count + 1 end
    end
    return count >= 2
end

-- Converts the "+" just dragged to w.waypoints[index] into a 3-way junction
-- instead of leaving it as a plain bend point, when it lands on another
-- element/control: splits w in two — ending, then starting again, at a
-- new, tiny, sprite-less componentType "path" element sitting exactly at
-- that point (drawn as a plain filled dot, same as any other no-sprite
-- circle element always has been — see _drawElement; a "path" role reads
-- as a pure pass-through node to the inference model the same way a BUS or
-- MANIFOLD already does, so nothing downstream needs to know a junction is
-- a new kind of thing at all) — then adds a 3rd wire from that junction out
-- to the target, letting it auto-pick a terminal the same way any other
-- connector drag does (see gdsGui_schematic_addWire's own fromTerminal/
-- toTerminal auto-resolve). The dragged point's own position becomes the
-- junction's, so it's never itself a waypoint of either resulting half.
--
-- False (leaving w's own commitPress/movePoint result from the drag as the
-- ordinary bend point it already is — exactly today's EDIT PATH behavior,
-- unchanged) when there's nothing valid to branch onto: empty canvas, one
-- of w's own two existing endpoints (nothing to branch TO), or an anchor
-- already at its wire/terminal limit (anchorAtWireLimit above).
--
-- One side effect worth knowing: a fresh junction never carries over the
-- original wire's own painted snapshot colors (gdsGui_schematic_
-- commitSnapshot keys by wire id, and the new "after" half is a new one) —
-- same as splicing any wire in two would; re-paint it per snapshot same as
-- any newly drawn connector.
function _wirePath.branchAt(canvas, w, index)
    local point = w.waypoints and w.waypoints[index]
    if not point then return false end
    local px, py = _toPixel(canvas, point.x, point.y)
    local target = _hitElement(canvas, px, py) or _hitControl(canvas, px, py)
    if not target or target.id == w.fromElementId or target.id == w.toElementId then return false end
    if _wirePath.anchorAtWireLimit(canvas, target.id) then return false end

    local points = _wirePath.copy(w)
    local before, after = {}, {}
    for i = 1, index - 1 do before[i] = points[i] end
    for i = index + 1, #points do after[#after + 1] = points[i] end

    -- A fresh id, never user-named: reuses canvas._placementCounter's own
    -- running "next free number" the same way a normal placement's
    -- suggested name does (see _resyncPlacementCounter), just under its own
    -- "JCT_" prefix so it can never collide with a user-typed abbrev's own
    -- numbering.
    canvas._placementCounter = canvas._placementCounter + 1
    local jId = "JCT_" .. canvas._placementCounter
    local jw, jh = _elementGridFootprintFrac(canvas, 1, 1)
    gdsGui_schematic_addElement(canvas.name, jId, "circle", point.x - jw / 2, point.y - jh / 2,
        jw, jh, nil, nil, nil, 0, nil, "path", nil)

    -- w becomes the "before" half, redirected to end at the junction — its
    -- own id, fromElementId/fromTerminal, defaultColor etc. all stay
    -- exactly as they were, so it keeps reading as the same wire it always
    -- was right up to the new junction.
    local oldToId, oldToTerminal = w.toElementId, w.toTerminal
    w.toElementId, w.toTerminal = jId, nil
    w.waypoints = #before > 0 and before or nil

    -- The "after" half: a new wire carrying w's own color/direction
    -- override forward (so the split reads as one continuous run, not two
    -- differently-styled ones) out to wherever w used to end.
    local afterId = _uniqueWireId(canvas, jId .. "_to_" .. oldToId)
    gdsGui_schematic_addWire(canvas.name, afterId, jId, oldToId,
        _deepCopy(w.defaultColor), w.directionOverride, nil, oldToTerminal)
    local afterWire = _findWire(canvas, afterId)
    if afterWire then afterWire.waypoints = #after > 0 and after or nil end

    -- The branch itself: a brand new, plain, unpainted connector — same
    -- default-gray convention every other freshly drawn wire starts with.
    -- toTerminal is picked explicitly (nearest FREE one, if target has a
    -- fixed terminal list) rather than left for addWire's own auto-resolve
    -- to pick — that one only goes by distance, with no idea some of
    -- target's terminals are already spoken for, so left to it alone it
    -- could just as easily reuse the terminal anchorAtWireLimit above was
    -- checking was still free.
    local toTerminal
    if target.terminals then
        local bestDistSq
        for i = 1, #target.terminals do
            local used = false
            for _, w2 in ipairs(canvas.wires) do
                if (w2.fromElementId == target.id and w2.fromTerminal == i)
                   or (w2.toElementId == target.id and w2.toTerminal == i) then used = true; break end
            end
            if not used then
                local tx, ty = _terminals.point(canvas, target, i)
                local d = (tx - px) ^ 2 + (ty - py) ^ 2
                if not toTerminal or d < bestDistSq then toTerminal, bestDistSq = i, d end
            end
        end
    end
    gdsGui_schematic_addWire(canvas.name, _uniqueWireId(canvas, jId .. "_to_" .. target.id), jId, target.id,
        nil, nil, nil, toTerminal)
    return true
end

-- The end of a handle's press: a "+" dragged onto another element/control
-- branches off a new wire there (branchAt above) instead; a "+" tapped (not
-- dragged) or dragged anywhere else just puts its point in; a bend point
-- tapped is removed.
function _wirePath.release(canvas)
    local edit = canvas.pathEdit
    local w = _findWire(canvas, edit.wireId)
    if w and not canvas.dragMoved then
        if not _wirePath.commitPress(canvas, w) and edit.index then
            local points = _wirePath.copy(w)
            table.remove(points, edit.index)
            w.waypoints = #points > 0 and points or nil
            gdsGui_haptics_feedback("light")
        end
    elseif w and canvas.dragMoved and edit.wasInsert and edit.index then
        if _wirePath.branchAt(canvas, w, edit.index) then
            gdsGui_haptics_feedback("selection")
        end
    end
    canvas._pendingDragUndoSnapshot = nil
    edit.index, edit.pendingInsert, edit.wasInsert = nil, nil, nil
    _notifyChanged(canvas)
end

-- The handles over the wire being edited, and what to do next.
function _wirePath.draw(canvas)
    local edit = canvas.pathEdit
    if not edit then return end
    local w = _findWire(canvas, edit.wireId)
    local plan = w and canvas._wirePlansCache and canvas._wirePlansCache[w.id]
    if not plan then return end
    local accent = { 0.04, 0.52, 1, 1 }
    for _, handle in ipairs(_wirePath.handles(canvas, w, plan)) do
        if handle.kind == "insert" then
            local r = _wirePath.INSERT_RADIUS_PX
            love.graphics.setColor(0, 0, 0, 0.55)
            love.graphics.circle("fill", handle.x, handle.y, r + 1.5)
            love.graphics.setColor(1, 1, 1, 0.92)
            love.graphics.circle("fill", handle.x, handle.y, r)
            love.graphics.setColor(accent)
            love.graphics.setLineWidth(2)
            love.graphics.line(handle.x - r * 0.55, handle.y, handle.x + r * 0.55, handle.y)
            love.graphics.line(handle.x, handle.y - r * 0.55, handle.x, handle.y + r * 0.55)
        end
    end
    for _, handle in ipairs(_wirePath.handles(canvas, w, plan)) do
        if handle.kind == "point" then
            local r = _wirePath.POINT_RADIUS_PX * ((edit.index == handle.index and canvas.dragKind == "pathPoint") and 1.3 or 1)
            love.graphics.setColor(0, 0, 0, 0.55)
            love.graphics.circle("fill", handle.x, handle.y, r + 2.5)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.circle("fill", handle.x, handle.y, r + 1.5)
            love.graphics.setColor(accent)
            love.graphics.circle("fill", handle.x, handle.y, r)
        end
    end
    love.graphics.setLineWidth(1)
    love.graphics.setFont(globApp.appFont or love.graphics.getFont())
    love.graphics.setColor(1, 1, 1, 1)
    local hint = (w.waypoints and #w.waypoints > 0) and "DRAG + TO ADD A BEND\nTAP A BEND TO REMOVE IT\nTAP AWAY WHEN DONE"
        or "DRAG A + TO ADD A BEND\nTAP AWAY WHEN DONE"
    local font = love.graphics.getFont()
    local width = canvas.w - 16
    local _, lines = font:getWrap(hint, width)
    local textW = 0
    for _, line in ipairs(lines) do textW = math.max(textW, font:getWidth(line)) end
    local plateH = #lines * font:getHeight() + 8
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", canvas.x + (canvas.w - textW) / 2 - 8, canvas.y + 2, textW + 16, plateH, 6, 6)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(hint, canvas.x + 8, canvas.y + 6, width, "center")
end


local function _computeWirePlans(canvas)
    -- Mid-gesture fast path: recomputes ONLY each wire's own segments
    -- (cheap, O(wires) -- one _clampedOrthogonalSegments call per wire,
    -- independent of every other wire) so a wire keeps visually tracking
    -- the element/control it's attached to, or the view itself, in real
    -- time -- and skips the expensive O(wires^2 * segments^2) crossing-
    -- hop/bundle sweep below entirely for the duration, rather than
    -- reusing its last result. hopDistances/bundledRanges are left EMPTY
    -- here, not stale — bundles (the 2nd return value) are stored as
    -- ABSOLUTE pixel coordinates computed against whatever segment
    -- geometry was live at the time of that last sweep, so reusing them
    -- while segments themselves keep moving every frame (a drag/pan/pinch
    -- changes exactly that geometry) visibly detaches the bundled/hop
    -- rendering from the rest of the diagram — it was tried, and looked
    -- exactly like that: solid colored shapes left floating at their old
    -- screen position while everything else panned underneath them, only
    -- snapping to the new position on release. Drawing every wire as a
    -- plain solo line instead (no hop arcs, no bundled bands) for the
    -- gesture's duration has no such risk, since every pixel drawn still
    -- comes from THIS frame's own live segment. Purely a cosmetic
    -- simplification, same as the old pre-bundling look, that resolves
    -- itself the instant the gesture ends and the full sweep below runs
    -- again for real. Without this, a diagram with many wires gets
    -- progressively laggier and less responsive to edit the more wires it
    -- has, since every single frame of every drag/pan/pinch was paying
    -- that full O(n^2) sweep whether or not anything about the CROSSINGS
    -- themselves had actually changed. The cache/signature
    -- (canvas._wirePlansCache/_wpSig) is deliberately left untouched
    -- here, so the very first frame after the gesture ends falls through
    -- to the normal path below, sees "changed" (true positions now differ
    -- from the signature last recorded before the gesture began), and
    -- recomputes for real exactly once to catch up. Active gesture: an
    -- element/control/rotate/wireDirection drag or pan that has actually
    -- started moving (canvas.focusTouchId set AND canvas.dragMoved true —
    -- see gdsGui_schematic_pressed/_moved/_released), or a pinch-zoom
    -- (canvas.pinch.active). Deliberately NOT just "focusTouchId ~= nil":
    -- that's already set the instant a finger touches down, including a
    -- plain tap-and-hold that never moves (dragKind "pendingLongPress", or
    -- a "pan"/"element"/etc. press held perfectly still) — nothing about
    -- the geometry has changed yet in that case, so dropping to the plain-
    -- line fast path there only hid the hop arcs/bundle bands for the
    -- entire hold (reappearing on release) with no performance benefit,
    -- since the expensive sweep below hadn't actually run again.
    if canvas._wirePlansCache and ((canvas.focusTouchId ~= nil and canvas.dragMoved) or (canvas.pinch and canvas.pinch.active)) then
        local plans = {}
        for _, w in ipairs(canvas.wires) do
            local fromE, toE = _findAnchor(canvas, w.fromElementId), _findAnchor(canvas, w.toElementId)
            if fromE and toE then
                local segments, legs = _terminals.wireSegments(canvas, w, fromE, toE)
                plans[w.id] = { segments = segments, legs = legs, hopDistances = {}, bundledRanges = {} }
            end
        end
        return plans, {}
    end

    local changed = _wirePlansChanged(canvas)
    if canvas._wirePlansCache and not changed then
        return canvas._wirePlansCache, canvas._wireBundlesCache
    end

    local plans = {}
    -- Segments grouped by the exact line they run along (key "H:<y>" or
    -- "V:<x>", nearest-pixel rounded), each entry recording the segment's
    -- own along-line absolute range — the input to the bundle sweep below.
    local lineGroups = {}
    for order, w in ipairs(canvas.wires) do
        local fromE, toE = _findAnchor(canvas, w.fromElementId), _findAnchor(canvas, w.toElementId)
        if fromE and toE then
            local segments, legs = _terminals.wireSegments(canvas, w, fromE, toE)
            plans[w.id] = { segments = segments, legs = legs, hopDistances = {}, bundledRanges = {} }
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
    -- own start/end, then wherever 2+ entries actually cover a sub-range,
    -- record ONE bundle zone there (member wires in creation order) —
    -- see _drawWireBundleSegment, the only consumer of bundles below. No
    -- lane ranking/offset math needed: every member just contributes its
    -- own color band to that one shared line at draw time.
    local bundles = {}
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
                if #active > 1 then
                    table.sort(active, function(x, y) return x.order < y.order end)
                    local ref = active[1]
                    local ax, ay = _pointOnLine(ref.seg, a)
                    local bx, by = _pointOnLine(ref.seg, b)
                    local wireIds = {}
                    for _, e in ipairs(active) do
                        table.insert(wireIds, e.wireId)
                        local eax, eay = _pointOnLine(e.seg, a)
                        local ebx, eby = _pointOnLine(e.seg, b)
                        local dA, dB = _distAlongSegment(e.seg, eax, eay), _distAlongSegment(e.seg, ebx, eby)
                        local ranges = plans[e.wireId].bundledRanges
                        ranges[e.segIdx] = ranges[e.segIdx] or {}
                        table.insert(ranges[e.segIdx], { lo = math.min(dA, dB), hi = math.max(dA, dB) })
                    end
                    table.insert(bundles, { x1 = ax, y1 = ay, x2 = bx, y2 = by, wireIds = wireIds })
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

    if canvas.pipeConnectors then _pipes.snapPlans(plans, bundles) end
    canvas._wirePlansCache = plans
    canvas._wireBundlesCache = bundles
    return plans, bundles
end

-- Topmost wire whose segment path passes within _WIRE_TAP_SLOP_PX of the
-- point. Last-added wins, matching _hitElement — a bundled stretch (see
-- _computeWirePlans) no longer nudges overlapping wires into visually
-- distinct lanes, so every wire sharing it sits at the exact same screen
-- position; "last added" is also which one draws its color band on top at
-- that point, so the two stay consistent with each other. Falls back to
-- the raw anchor-to-anchor bend when a wire has no plan yet (e.g. a
-- dangling wire mid-undo).
local function _hitWire(canvas, px, py)
    local plans = _computeWirePlans(canvas)
    for i = #canvas.wires, 1, -1 do
        local w = canvas.wires[i]
        local plan = plans[w.id]
        if plan then
            for _, seg in ipairs(plan.segments) do
                if _distPointToSegment(px, py, seg[1], seg[2], seg[3], seg[4]) <= _WIRE_TAP_SLOP_PX then return w end
            end
        else
            local fromA, toA = _findAnchor(canvas, w.fromElementId), _findAnchor(canvas, w.toElementId)
            if fromA and toA then
                local x1, y1 = _terminals.wireEnd(canvas, fromA, w.fromTerminal)
                local x2, y2 = _terminals.wireEnd(canvas, toA, w.toTerminal)
                if _distPointToSegment(px, py, x1, y1, x2, y2) <= _WIRE_TAP_SLOP_PX then return w end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- POWERED GLOW: while enabled (gdsGui_schematic_setGlow), every element,
-- control and wire whose display color isn't plain (gray-ish, the library's
-- default gray, or one of the app's plain colors such as its unpowered gray)
-- gets a soft, slowly pulsing halo in its own color, so live parts read as
-- energized at a glance. A striped color sequence (no single answer) never
-- glows. How: each glowing item's shape is also drawn into an offscreen
-- canvas at SCALE resolution (_glow.capture), which is blurred with a
-- separable Gaussian shader and added over the schematic once per frame
-- (_glow.finish) — a real blur, so overlapping wires and corners stay
-- smooth instead of stacking into blocks.
--------------------------------------------------------------------------------

-- 0.75, not the full screen: the blur already hides most of the resolution
-- loss (that's the whole point of blurring it), so this buys back edge
-- definition around small/thin elements a plain half-res capture used to
-- round off, for ~2.25x the blur fragment cost rather than 4x at 1.0.
_glow.SCALE = 0.75       -- offscreen glow resolution, relative to the screen
_glow.PASSES = 2         -- blur iterations (each one horizontal + vertical)
_glow.SPREAD = 1.0       -- blur tap distance, in offscreen pixels
_glow.INTENSITY = 0.75   -- composite strength before the pulse
_glow.WIRE_WIDTH = 1.8   -- a wire's glow source, as a multiple of its width

-- plainColors: array of {r,g,b[,a]} that never glow. enabled false/nil turns
-- the effect off.
function gdsGui_schematic_setGlow(canvasName, enabled, plainColors)
    local canvas = _findCanvas(canvasName)
    if canvas then canvas.glow = enabled and { plain = plainColors or {} } or nil end
end

-- Drops the cached blur shader/offscreen canvases so _glow.ensureResources
-- rebuilds them fresh next frame, and gives a previously-_glow.failed
-- session a clean retry. Call this whenever the app regains focus (see
-- main.lua's love.focus) — an iOS app suspend/resume is free to reclaim or
-- invalidate GPU resources like these while backgrounded, and LÖVE's own
-- Canvas object surviving that (same Lua reference, same reported
-- dimensions) doesn't guarantee the texture it points at still is: drawing
-- to/from a canvas the OS already reclaimed is exactly the kind of failure
-- _glow.guarded exists to catch, but recovering from it needs a FRESH
-- canvas, not just a reset of graphics state around the same broken one.
function gdsGui_schematic_glowInvalidateResources()
    _glow.shader, _glow.canvasA, _glow.canvasB = nil, nil, nil
    _glow.failed = false
end

function _glow.applies(canvas, r, g, b)
    if not canvas.glow or not canvas.glow.active then return false end
    -- Grays (and white) never glow, whatever their exact shade.
    if math.max(r, g, b) - math.min(r, g, b) < 0.12 then return false end
    for _, c in ipairs(canvas.glow.plain) do
        if math.abs(c[1] - r) < 0.02 and math.abs(c[2] - g) < 0.02 and math.abs(c[3] - b) < 0.02 then return false end
    end
    return true
end

-- 0.75..1, a slow breathing pulse shared by everything glowing.
function _glow.pulse()
    return 0.875 + 0.125 * math.sin(love.timer.getTime() * 2.5)
end

-- Lazily builds the blur shader and the two offscreen canvases (rebuilt if
-- the window size changed). False if shaders aren't available — the glow is
-- then simply skipped.
function _glow.ensureResources()
    if _glow.failed then return false end
    if not _glow.shader then
        local ok, shader = pcall(love.graphics.newShader, [[
            uniform vec2 direction;
            vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
                vec4 sum = Texel(tex, tc) * 0.2270270270;
                sum += Texel(tex, tc + direction * 1.3846153846) * 0.3162162162;
                sum += Texel(tex, tc - direction * 1.3846153846) * 0.3162162162;
                sum += Texel(tex, tc + direction * 3.2307692308) * 0.0702702703;
                sum += Texel(tex, tc - direction * 3.2307692308) * 0.0702702703;
                return sum * color;
            }
        ]])
        if not ok then _glow.failed = true; return false end
        _glow.shader = shader
    end
    local w = math.max(1, math.ceil(love.graphics.getWidth() * _glow.SCALE))
    local h = math.max(1, math.ceil(love.graphics.getHeight() * _glow.SCALE))
    if not _glow.canvasA or _glow.canvasA:getWidth() ~= w or _glow.canvasA:getHeight() ~= h then
        -- Same pcall guard as the shader above, and for the same reason: a
        -- window-size change mid-session (e.g. the on-screen keyboard
        -- resizing the viewport when a placement grid's NAME field
        -- auto-focuses — see _openElementPlacementGrid) can land here again
        -- well after startup, and love.graphics.newCanvas is just as able to
        -- fail/throw on a size it doesn't like as the shader compile is.
        -- Unguarded, that's an uncaught error out of _glow.begin (this
        -- function's only caller runs OUTSIDE _glow.guarded, deliberately —
        -- a failure here means there's no canvas to draw into at all, so
        -- the guarded block's own draw calls would only fail right after
        -- it anyway) — exactly the "freezes and stays frozen" failure mode
        -- this whole _glow.guarded apparatus exists to prevent.
        local ok, a, b = pcall(function()
            -- Deliberately plain (sampleCount 1, no msaa option) — see
            -- conf.lua's own t.window.msaa comment. A version matching the
            -- window's own msaa was tried here first (a mismatched plain
            -- canvas as render target while the window is multisampled
            -- crashed outright on this LÖVE 12/Metal build — Xcode console:
            -- "MTLRenderPassAttachmentDescriptor texture must be
            -- MTLTextureType2DMultisample ... when using a resolveTexture")
            -- but that only traded it for a SECOND Metal validation failure
            -- one layer deeper ("RenderPass Descriptor texture and
            -- resolveTexture size mismatch") once this canvas's own
            -- multisample buffer got drawn/resolved during the blur
            -- ping-pong below — this engine's pre-release Metal backend
            -- (changes.txt: "LOVE 12.0 ... Released: N/A") doesn't reliably
            -- support mixing MSAA canvases into THIS particular render
            -- sequence yet. conf.lua turning off the window's own msaa is
            -- the other half of this fix: with no resolveTexture anywhere
            -- in the renderer, neither failure can occur, by construction.
            -- stencil=true (plain, no msaa -- same reasoning as the comment
            -- above): every normal element draw, not just the halo capture
            -- passes, lands on canvasA while a glow pass is active (see the
            -- main loop below), and _shapePoly.drawLevel's wave-curve mask
            -- needs a real stencil buffer on whatever canvas is bound, or
            -- LÖVE throws "Drawing to the stencil buffer with a Canvas
            -- active requires ... stencil=true".
            local newA = love.graphics.newCanvas(w, h, { stencil = true })
            local newB = love.graphics.newCanvas(w, h, { stencil = true })
            -- Drawn back at full size: linear, so the glow scales up soft rather than blocky.
            newA:setFilter("linear", "linear")
            newB:setFilter("linear", "linear")
            return newA, newB
        end)
        if not ok then _glow.failed = true; return false end
        _glow.canvasA, _glow.canvasB = a, b
    end
    return true
end

-- Explicit save/restore of the state the glow passes change (render
-- target, scissor, shader, blend mode, color, line width) — relied on
-- instead of push("all"), which didn't reliably restore the render target.
function _glow.saveState()
    local st = { canvas = love.graphics.getCanvas(), shader = love.graphics.getShader(),
        lineWidth = love.graphics.getLineWidth() }
    st.scX, st.scY, st.scW, st.scH = love.graphics.getScissor()
    st.blend, st.alphaMode = love.graphics.getBlendMode()
    st.r, st.g, st.b, st.a = love.graphics.getColor()
    return st
end

function _glow.restoreState(st)
    love.graphics.setCanvas(st.canvas)
    if st.scX then love.graphics.setScissor(st.scX, st.scY, st.scW, st.scH) else love.graphics.setScissor() end
    love.graphics.setShader(st.shader)
    love.graphics.setBlendMode(st.blend, st.alphaMode)
    love.graphics.setColor(st.r, st.g, st.b, st.a)
    love.graphics.setLineWidth(st.lineWidth)
end

-- Unconditional known-good baseline -- NOT a restore of anything captured
-- (contrast restoreState above, which trusts whatever love.graphics.getCanvas()
-- etc. happened to already be, right or wrong). Used only as a last-resort
-- recovery when a glow pass fails outright (see _glow.guarded below): if that
-- failure left the real render target pointed at one of the offscreen glow
-- canvases (or the shader/blend mode left mid-pass), every draw call AFTER
-- it -- for the rest of THIS frame and, since nothing else in the app ever
-- re-asserts canvas=screen on its own, every frame after it too -- would
-- silently render into/through that broken state instead of the visible
-- screen (a white/blank canvas that never recovers on its own, exactly the
-- "freezes and stays frozen until something else happens to reset it"
-- failure mode a real render-target leak produces).
function _glow.resetGraphicsState()
    love.graphics.setCanvas()
    love.graphics.setShader()
    love.graphics.setScissor()
    love.graphics.setBlendMode("alpha")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setLineWidth(1)
end

-- Runs fn() guarded against both a hard Lua error (a stale/invalidated
-- offscreen Canvas -- e.g. after an iOS app suspend/resume reclaims GPU
-- memory -- can make love.graphics calls against it throw) AND simply
-- never trying again once one has failed (_glow.failed latches permanently
-- -- the effect is purely cosmetic, so disabling it for the rest of this
-- session is far safer than risking a repeat of whatever just broke).
-- Either way, the render target/shader/blend state is forced back to a
-- known-good baseline rather than left wherever the failed call abandoned
-- it -- see resetGraphicsState's own comment for why that step is the
-- actual fix, not just belt-and-suspenders.
function _glow.guarded(fn)
    if _glow.failed then return end
    local ok = pcall(fn)
    if not ok then
        _glow.failed = true
        _glow.resetGraphicsState()
    end
end

-- Start of a schematic canvas's frame: clears the offscreen glow buffer.
function _glow.begin(canvas)
    if not canvas.glow then return end
    canvas.glow.active = _glow.ensureResources()
    if not canvas.glow.active then return end
    _glow.guarded(function()
        local st = _glow.saveState()
        love.graphics.setCanvas(_glow.canvasA)
        -- clear() honors the scissor: with the canvas's screen-space scissor
        -- still set, part of this half-size buffer was never cleared, and the
        -- blur kept smearing last frame's glow across it.
        love.graphics.setScissor()
        love.graphics.clear(0, 0, 0, 0)
        _glow.restoreState(st)
    end)
    if _glow.failed then canvas.glow.active = false end
end

-- Draws drawFn() (an item's bare shape, already in its own glow color) into
-- the offscreen glow buffer instead of the screen.
function _glow.capture(drawFn)
    _glow.guarded(function()
        local st = _glow.saveState()
        love.graphics.setCanvas(_glow.canvasA)
        love.graphics.setScissor()
        love.graphics.setBlendMode("alpha")
        love.graphics.push()
        love.graphics.origin()
        love.graphics.scale(_glow.SCALE)
        drawFn()
        love.graphics.pop()
        _glow.restoreState(st)
    end)
end

-- End of the canvas's frame: blurs the buffer and adds it over the canvas
-- (clipped to the canvas's own rect).
function _glow.finish(canvas)
    if not canvas.glow or not canvas.glow.active then return end
    canvas.glow.active = false
    _glow.guarded(function()
        local w, h = _glow.canvasA:getDimensions()
        local st = _glow.saveState()
        love.graphics.push()
        love.graphics.origin()
        love.graphics.setScissor()
        love.graphics.setShader(_glow.shader)
        love.graphics.setBlendMode("alpha", "premultiplied")
        love.graphics.setColor(1, 1, 1, 1)
        for _ = 1, _glow.PASSES do
            love.graphics.setCanvas(_glow.canvasB)
            love.graphics.clear(0, 0, 0, 0)
            _glow.shader:send("direction", { _glow.SPREAD / w, 0 })
            love.graphics.draw(_glow.canvasA)
            love.graphics.setCanvas(_glow.canvasA)
            love.graphics.clear(0, 0, 0, 0)
            _glow.shader:send("direction", { 0, _glow.SPREAD / h })
            love.graphics.draw(_glow.canvasB)
        end
        love.graphics.setShader()
        love.graphics.setCanvas(st.canvas)
        love.graphics.setScissor(canvas.x, canvas.y, canvas.w, canvas.h)
        love.graphics.setBlendMode("add", "premultiplied")
        local k = math.min(1, _glow.INTENSITY * _glow.pulse())
        love.graphics.setColor(k, k, k, k)
        love.graphics.draw(_glow.canvasA, 0, 0, 0, 1 / _glow.SCALE, 1 / _glow.SCALE)
        -- A second, lighter layer for the bright core when INTENSITY > 1.
        local extra = _glow.INTENSITY * _glow.pulse() - 1
        if extra > 0 then
            love.graphics.setColor(extra, extra, extra, extra)
            love.graphics.draw(_glow.canvasA, 0, 0, 0, 1 / _glow.SCALE, 1 / _glow.SCALE)
        end
        love.graphics.pop()
        _glow.restoreState(st)
    end)
end

--------------------------------------------------------------------------------
-- MENU BACKDROP BLUR — a real frosted-glass material behind an open action
-- sheet (gdsGui_schematic_drawMenuOverlay/_drawMenuBox), replacing what
-- would otherwise be a flat dim rectangle over the sharp canvas. Global,
-- not local, same as _actionSheet/_propertyGrid/_galleryBadge above — this
-- file is already at Lua's 200-top-level-local ceiling.
--
-- gdsGui_schematic_draw (below) redirects a canvas's ENTIRE normal draw
-- pass into _menuBackdrop.full instead of the screen, for exactly the
-- frames a menu is open on it — a plain, full-WINDOW-resolution (1:1)
-- canvas, deliberately NOT scaled, so every existing absolute-pixel
-- love.graphics.setScissor(canvas.x, ...) call inside that draw pass keeps
-- clipping to the right place with no change to it at all. Once that pass
-- finishes, the captured frame is downsampled and blurred (canvasA/
-- canvasB, the same separable-Gaussian ping-pong _glow.finish already
-- uses, just this module's own instances so the two never fight over the
-- same canvas in one frame) and drawn to the screen in its place —
-- _drawMenuBox's own existing dim rect + panel then layer on top of that
-- exactly as before, with no changes needed there.
--
-- Same plain/pcall-guarded canvas pattern as _glow throughout (see
-- conf.lua's own t.window.msaa=0 comment on the Metal-backend crash this
-- sidesteps): any failure here just skips the blur for the rest of this
-- session and that canvas's content draws straight to the screen as
-- always, identical to before this module existed.
--------------------------------------------------------------------------------

_menuBackdrop = {}
_menuBackdrop.SCALE = 0.35   -- ping-pong blur resolution, relative to the window
_menuBackdrop.PASSES = 3     -- more than _glow's own 2 -- a modal backdrop wants to read as clearly out-of-focus
_menuBackdrop.SPREAD = 2.2

function _menuBackdrop.ensureResources()
    if _menuBackdrop.failed then return false end
    if not _menuBackdrop.shader then
        local ok, shader = pcall(love.graphics.newShader, [[
            uniform vec2 direction;
            vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
                vec4 sum = Texel(tex, tc) * 0.2270270270;
                sum += Texel(tex, tc + direction * 1.3846153846) * 0.3162162162;
                sum += Texel(tex, tc - direction * 1.3846153846) * 0.3162162162;
                sum += Texel(tex, tc + direction * 3.2307692308) * 0.0702702703;
                sum += Texel(tex, tc - direction * 3.2307692308) * 0.0702702703;
                return sum * color;
            }
        ]])
        if not ok then _menuBackdrop.failed = true; return false end
        _menuBackdrop.shader = shader
    end
    local fullW = math.max(1, love.graphics.getWidth())
    local fullH = math.max(1, love.graphics.getHeight())
    local w = math.max(1, math.ceil(fullW * _menuBackdrop.SCALE))
    local h = math.max(1, math.ceil(fullH * _menuBackdrop.SCALE))
    if not _menuBackdrop.full or _menuBackdrop.full:getWidth() ~= fullW or _menuBackdrop.full:getHeight() ~= fullH
       or not _menuBackdrop.canvasA or _menuBackdrop.canvasA:getWidth() ~= w then
        -- Same pcall guard as the shader above, and for the same reason
        -- _glow.ensureResources gives: a window-size change mid-session can
        -- land here again well after startup, and love.graphics.newCanvas is
        -- just as able to fail/throw on a size it doesn't like as the shader
        -- compile is.
        local ok, full, a, b = pcall(function()
            -- Deliberately plain (no msaa option) -- see conf.lua's own
            -- t.window.msaa comment; _glow hit two separate Metal validation
            -- crashes mixing an MSAA canvas into a shader ping-pong on this
            -- LÖVE 12 pre-release backend, and this is the exact same kind
            -- of ping-pong.
            -- stencil=true on "full": every element behind an open modal
            -- menu draws into this buffer (see gdsGui_schematic_draw's own
            -- backdropActive redirect below), and _shapePoly.drawLevel's
            -- wave-curve mask needs a real stencil buffer on whatever canvas
            -- is bound -- same reasoning as _glow.ensureResources above.
            local newFull = love.graphics.newCanvas(fullW, fullH, { stencil = true })
            local newA, newB = love.graphics.newCanvas(w, h), love.graphics.newCanvas(w, h)
            newA:setFilter("linear", "linear")
            newB:setFilter("linear", "linear")
            return newFull, newA, newB
        end)
        if not ok then _menuBackdrop.failed = true; return false end
        _menuBackdrop.full, _menuBackdrop.canvasA, _menuBackdrop.canvasB = full, a, b
    end
    return true
end

function _menuBackdrop.guarded(fn)
    if _menuBackdrop.failed then return end
    local ok = pcall(fn)
    if not ok then
        _menuBackdrop.failed = true
        _glow.resetGraphicsState()
    end
end

-- Redirects every draw call that follows (until _menuBackdrop.finish) into
-- the full-resolution capture canvas instead of the screen. Only called
-- when canvas.menu is actually set, so this costs nothing on any frame
-- without an open menu.
function _menuBackdrop.begin()
    _menuBackdrop.active = _menuBackdrop.ensureResources()
    if not _menuBackdrop.active then return end
    _menuBackdrop.guarded(function()
        love.graphics.setCanvas(_menuBackdrop.full)
        love.graphics.setScissor()
        love.graphics.clear(0, 0, 0, 0)
    end)
    if _menuBackdrop.failed then _menuBackdrop.active = false end
end

-- Ends the redirect, blurs the captured frame, and draws the blurred
-- result to the screen in its place -- gdsGui_schematic_drawMenuOverlay's
-- own dim rect + panel, drawn later this same frame, then layer on top of
-- it exactly as they already do over the sharp canvas.
function _menuBackdrop.finish()
    if not _menuBackdrop.active then return end
    _menuBackdrop.active = false
    _menuBackdrop.guarded(function()
        local w, h = _menuBackdrop.canvasA:getDimensions()
        love.graphics.setCanvas()
        love.graphics.setShader()
        love.graphics.setScissor()
        love.graphics.setBlendMode("alpha")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setCanvas(_menuBackdrop.canvasA)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.draw(_menuBackdrop.full, 0, 0, 0, _menuBackdrop.SCALE, _menuBackdrop.SCALE)
        love.graphics.setShader(_menuBackdrop.shader)
        for _ = 1, _menuBackdrop.PASSES do
            love.graphics.setCanvas(_menuBackdrop.canvasB)
            love.graphics.clear(0, 0, 0, 0)
            _menuBackdrop.shader:send("direction", { _menuBackdrop.SPREAD / w, 0 })
            love.graphics.draw(_menuBackdrop.canvasA)
            love.graphics.setCanvas(_menuBackdrop.canvasA)
            love.graphics.clear(0, 0, 0, 0)
            _menuBackdrop.shader:send("direction", { 0, _menuBackdrop.SPREAD / h })
            love.graphics.draw(_menuBackdrop.canvasB)
        end
        love.graphics.setShader()
        love.graphics.setCanvas()
        love.graphics.draw(_menuBackdrop.canvasA, 0, 0, 0, 1 / _menuBackdrop.SCALE, 1 / _menuBackdrop.SCALE)
        love.graphics.setColor(1, 1, 1, 1)
    end)
end

-- Glow source for a wire: its own path, a little wider than the wire.
function _glow.wire(plan, zoom, wireWidth, r, g, b, bendRadius)
    _glow.capture(function()
        love.graphics.setColor(r, g, b, 1)
        love.graphics.setLineWidth(wireWidth * _glow.WIRE_WIDTH)
        _drawWirePlanSegments(plan, zoom, bendRadius)
    end)
end

-- Glow source for an element/control: drawFn(r, g, b, a, isHalo) draws its
-- bare shape (isHalo leaves out outlines that aren't its own color).
function _glow.halo(zoom, r, g, b, drawFn)
    _glow.capture(function() drawFn(r, g, b, 1, true) end)
end

-- The same for a striped element/control (see _drawColorSequenceStriped): each
-- band halos in its own color, unless that color doesn't glow. The band bounds
-- are scaled because a scissor ignores the glow buffer's own scale transform.
function _glow.haloStriped(canvas, x, y, w, h, colors, drawFn)
    if not canvas.glow or not canvas.glow.active then return end
    local scale = _glow.SCALE
    _glow.capture(function()
        _drawColorSequenceStriped(x * scale, y * scale, w * scale, h * scale, colors, function(r, g, b)
            if _glow.applies(canvas, r, g, b) then drawFn(r, g, b, 1, true) end
        end)
    end)
end

--------------------------------------------------------------------------------
-- SELECTION: one look for a selected element, control or connector in the
-- editor. A rounded frame in the accent color just outside an element's or
-- control's footprint (or along a reshaped tank's own outline), with a faint
-- fill, a soft halo and corner handles; a connector gets the halo along its
-- own path, a dot at each end and a light frame on the two things it joins.
-- Selecting fades it in and deselecting fades it out. Holding to unlock move
-- mode traces the frame (or the connector) as the hold fills. Once unlocked,
-- the item lifts: a little larger, with a shadow, its frame slowly pulsing,
-- and a connector's halo marching along it. A global table, like _shapePoly,
-- since this file is at Lua's 200-local ceiling.
--------------------------------------------------------------------------------
_selection = {}
_selection.ACCENT = { 0.04, 0.52, 1 }
_selection.PAD_PX = 4             -- frame's clearance outside the footprint
_selection.RADIUS_PX = 6          -- frame corner radius
_selection.HANDLE_PX = 3.5        -- corner handle half-size
_selection.FADE_SECONDS = 0.12
_selection.LIFT_SECONDS = 0.15
_selection.LIFT_SCALE = 0.04      -- how much larger a lifted item draws
_selection.PULSE_SECONDS = 1.2
_selection.HOLD_SHOW_AFTER = 0.2  -- a hold shows its progress only once it's clearly not a tap
_selection.DASH_PX = 6
_selection.DASH_SPEED = 24        -- pixels a second the marching dashes travel
-- Halo layers, widest and faintest first: {extra width in pixels, strength}.
_selection.HALO = { { 14, 0.16 }, { 8, 0.28 }, { 4, 0.42 } }

function _selection.now() return love.timer.getTime() end

function _selection.setAccent(alpha)
    local a = _selection.ACCENT
    love.graphics.setColor(a[1], a[2], a[3], alpha)
end

-- Notes that `key` is drawn selected this frame; returns its fade-in, 0 to 1.
function _selection.mark(canvas, key)
    local now = _selection.now()
    if canvas._selKey ~= key then
        canvas._selKey, canvas._selSince = key, now
    end
    canvas._selDrawn = key
    return math.min(1, (now - canvas._selSince) / _selection.FADE_SECONDS)
end

-- Keeps drawFn(alpha), how `key` is drawn selected, so it can fade out once
-- deselected (see _selection.endFrame).
function _selection.remember(canvas, key, drawFn)
    canvas._selGhost = { key = key, fn = drawFn }
end

-- After everything else on the canvas: fades out a selection that's just gone.
function _selection.endFrame(canvas)
    local ghost = canvas._selGhost
    if ghost and ghost.key ~= canvas._selDrawn then
        local now = _selection.now()
        ghost.endedAt = ghost.endedAt or now
        local alpha = 1 - (now - ghost.endedAt) / _selection.FADE_SECONDS
        if alpha <= 0 then canvas._selGhost = nil else ghost.fn(alpha) end
    end
    if not canvas._selDrawn then canvas._selKey = nil end
    canvas._selDrawn = nil
end

-- How far the selected item is lifted (move mode unlocked), 0 to 1, eased.
function _selection.lift(canvas)
    if not canvas.selectionMoveModeActive then return 0 end
    local t = (_selection.now() - (canvas._liftStartedAt or 0)) / _selection.LIFT_SECONDS
    t = math.min(1, math.max(0, t))
    return 1 - (1 - t) ^ 3
end

-- The frame's slow pulse while lifted: a multiplier on its stroke, 0.7 to 1.
function _selection.pulse(lift)
    if lift <= 0 then return 1 end
    local phase = (_selection.now() % _selection.PULSE_SECONDS) / _selection.PULSE_SECONDS
    return 1 - lift * 0.15 * (1 - math.cos(phase * 2 * math.pi))
end

-- A soft accent glow: strokeFn(extra) strokes the shape `extra` pixels wider
-- than its own line, once per layer. Lighten (dark theme) or darken (light)
-- blending, so where strokes overlap (a connector's joints) the glow doesn't
-- build up; plain alpha if the device can't blend that way.
function _selection.halo(strokeFn, alpha)
    local dark = globApp.themeIsDark ~= false
    local prevMode, prevAlphaMode = love.graphics.getBlendMode()
    local blended = pcall(love.graphics.setBlendMode, dark and "lighten" or "darken", "premultiplied")
    local accent = _selection.ACCENT
    for _, layer in ipairs(_selection.HALO) do
        local a = layer[2] * alpha
        if not blended then
            love.graphics.setColor(accent[1], accent[2], accent[3], a * 0.6)
        elseif dark then
            love.graphics.setColor(accent[1] * a, accent[2] * a, accent[3] * a, a)
        else
            love.graphics.setColor(1 - (1 - accent[1]) * a, 1 - (1 - accent[2]) * a, 1 - (1 - accent[3]) * a, 1)
        end
        strokeFn(layer[1])
    end
    love.graphics.setBlendMode(prevMode, prevAlphaMode)
end

-- The rounded frame around a footprint x,y,w,h (see the section header).
function _selection.drawFrame(x, y, w, h, alpha, lift)
    local pad, r = _selection.PAD_PX, _selection.RADIUS_PX
    local fx, fy, fw, fh = x - pad, y - pad, w + pad * 2, h + pad * 2
    local stroke = 2 * gdsGui_general_hairline()
    local prevWidth = love.graphics.getLineWidth()
    _selection.halo(function(extra)
        love.graphics.setLineWidth(stroke + extra)
        love.graphics.rectangle("line", fx, fy, fw, fh, r, r)
    end, alpha)
    _selection.setAccent(0.08 * alpha)
    love.graphics.rectangle("fill", fx, fy, fw, fh, r, r)
    love.graphics.setLineWidth(stroke)
    _selection.setAccent(alpha * _selection.pulse(lift or 0))
    love.graphics.rectangle("line", fx, fy, fw, fh, r, r)
    local hs = _selection.HANDLE_PX
    for _, corner in ipairs({ { fx, fy }, { fx + fw, fy }, { fx + fw, fy + fh }, { fx, fy + fh } }) do
        love.graphics.setColor(1, 1, 1, alpha)
        love.graphics.rectangle("fill", corner[1] - hs, corner[2] - hs, hs * 2, hs * 2, 1.5, 1.5)
        _selection.setAccent(alpha)
        love.graphics.rectangle("line", corner[1] - hs, corner[2] - hs, hs * 2, hs * 2, 1.5, 1.5)
    end
    love.graphics.setLineWidth(prevWidth)
end

-- The same treatment along a reshaped tank's own outline (no corner handles:
-- its reshape mode has its own).
function _selection.drawOutline(canvas, e, alpha, lift)
    local stroke = 2 * gdsGui_general_hairline()
    local prevWidth = love.graphics.getLineWidth()
    _selection.halo(function(extra)
        love.graphics.setLineWidth(stroke + extra)
        _shapePoly.strokeOutline(canvas, e)
    end, alpha)
    love.graphics.setLineWidth(stroke)
    _selection.setAccent(alpha * _selection.pulse(lift or 0))
    _shapePoly.strokeOutline(canvas, e)
    love.graphics.setLineWidth(prevWidth)
end

-- How far through the hold that unlocks move mode a press on `kind` is, 0 to
-- 1, shown only once it's clearly a hold. nil when there's no such hold.
function _selection.holdFraction(canvas, kind)
    if canvas.dragKind ~= "pendingLongPress" or canvas.longPressTargetKind ~= kind then return nil end
    if not canvas.focusTouchId or canvas.dragMoved then return nil end
    local holdSeconds = _LONG_PRESS_SECONDS
    if kind == "element" then
        local e = canvas.selectedElementId and _findElement(canvas, canvas.selectedElementId)
        if e and _shapePoly.allowed(canvas, e) then holdSeconds = _shapePoly.HOLD_SECONDS end
    end
    local show = _selection.HOLD_SHOW_AFTER
    local elapsed = canvas.longPressElapsed or 0
    if elapsed < show then return nil end
    return math.min(1, (elapsed - show) / (holdSeconds - show))
end

-- The frame around x,y,w,h traced clockwise from its top middle, `fraction` of
-- the way round, over a faint track: a hold's progress.
function _selection.drawHoldTrace(x, y, w, h, fraction)
    local pad, r = _selection.PAD_PX, _selection.RADIUS_PX
    local fx, fy, fw, fh = x - pad, y - pad, w + pad * 2, h + pad * 2
    r = math.min(r, fw / 2, fh / 2)
    local points = { fx + fw / 2, fy }
    local corners = { { fx + fw - r, fy + r, -math.pi / 2 }, { fx + fw - r, fy + fh - r, 0 },
        { fx + r, fy + fh - r, math.pi / 2 }, { fx + r, fy + r, math.pi } }
    for _, corner in ipairs(corners) do
        for k = 0, 6 do
            local angle = corner[3] + (math.pi / 2) * k / 6
            points[#points + 1] = corner[1] + math.cos(angle) * r
            points[#points + 1] = corner[2] + math.sin(angle) * r
        end
    end
    points[#points + 1], points[#points + 2] = fx + fw / 2, fy
    local total = 0
    for i = 3, #points, 2 do
        total = total + math.sqrt((points[i] - points[i - 2]) ^ 2 + (points[i + 1] - points[i - 1]) ^ 2)
    end
    local prevWidth = love.graphics.getLineWidth()
    local width = 4 * gdsGui_general_hairline() + 1
    love.graphics.setLineWidth(width)
    love.graphics.setColor(1, 1, 1, 0.25)
    love.graphics.line(points)
    local remaining = total * fraction
    local traced = { points[1], points[2] }
    for i = 3, #points, 2 do
        if remaining <= 0 then break end
        local len = math.sqrt((points[i] - points[i - 2]) ^ 2 + (points[i + 1] - points[i - 1]) ^ 2)
        local t = len > 0 and math.min(1, remaining / len) or 1
        traced[#traced + 1] = points[i - 2] + (points[i] - points[i - 2]) * t
        traced[#traced + 1] = points[i - 1] + (points[i + 1] - points[i - 1]) * t
        remaining = remaining - len
    end
    if #traced >= 4 then
        _selection.setAccent(1)
        love.graphics.line(traced)
    end
    love.graphics.setLineWidth(prevWidth)
end

-- Starts drawing a lifted item centered at cx,cy (footprint w by h): its shadow,
-- then a transform that draws it a little larger. Pair with love.graphics.pop().
function _selection.beginLift(cx, cy, w, h, lift)
    local r = _selection.RADIUS_PX
    for i = 3, 1, -1 do
        local spread = i * 2 * lift
        love.graphics.setColor(0, 0, 0, 0.12 * lift)
        love.graphics.rectangle("fill", cx - w / 2 - spread, cy - h / 2 - spread + 3 * lift,
            w + spread * 2, h + spread * 2, r + spread, r + spread)
    end
    love.graphics.push()
    love.graphics.translate(cx, cy)
    local scale = 1 + _selection.LIFT_SCALE * lift
    love.graphics.scale(scale, scale)
    love.graphics.translate(-cx, -cy)
end

-- The footprint of an element or control, for framing it: x, y, w, h.
function _selection.anchorRect(canvas, anchor)
    if _findElement(canvas, anchor.id) then return _elementFootprintRect(canvas, anchor) end
    local cx, cy = _toPixel(canvas, anchor.x, anchor.y)
    local half = canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1) + 4
    return cx - half, cy - half, half * 2, half * 2
end

-- A selected connector's halo (and, once unlocked, its marching dashes), drawn
-- under it. width: its own drawn width (the full pipe, for a pipe).
function _selection.drawConnector(canvas, plan, width)
    local key = "w:" .. tostring(canvas.selectedWireId)
    local fade = _selection.mark(canvas, key)
    local radius = _pipes.bendRadius(canvas)
    local function draw(alpha)
        local prevWidth = love.graphics.getLineWidth()
        _selection.halo(function(extra)
            love.graphics.setLineWidth(width + extra)
            _drawWirePlanSegments(plan, canvas.zoom, radius)
        end, alpha)
        love.graphics.setLineWidth(prevWidth)
    end
    draw(fade)
    _selection.remember(canvas, key, draw)
    if canvas.selectionMoveModeActive then
        local pieces, total = _pipes.pathPieces(canvas, plan)
        local dash = _selection.DASH_PX
        local offset = (_selection.now() * _selection.DASH_SPEED) % (dash * 2)
        love.graphics.setLineWidth(width + 4)
        _selection.setAccent(0.9 * _selection.lift(canvas))
        local start = offset - dash * 2
        while start < total do
            local lo, hi = math.max(0, start), math.min(total, start + dash)
            for _, piece in ipairs(pieces) do
                local t0, t1 = math.max(0, lo - piece.d0), math.min(piece.len, hi - piece.d0)
                if t1 - t0 > 0.01 then _pipes.strokePiece(piece, t0, t1) end
            end
            start = start + dash * 2
        end
        love.graphics.setLineWidth(1)
    end
end

-- Over everything: the selected connector's end dots, a light frame on the two
-- things it joins, and a hold's progress along it.
function _selection.drawConnectorExtras(canvas, plans)
    local w = canvas.selectedWireId and _findWire(canvas, canvas.selectedWireId)
    local plan = w and plans[w.id]
    if not plan or #plan.segments == 0 then return end
    local alpha = canvas._selKey == "w:" .. w.id and math.min(1, (_selection.now() - (canvas._selSince or 0)) / _selection.FADE_SECONDS) or 1
    for _, id in ipairs({ w.fromElementId, w.toElementId }) do
        local anchor = _findAnchor(canvas, id)
        if anchor then
            local x, y, fw, fh = _selection.anchorRect(canvas, anchor)
            local pad, r = _selection.PAD_PX, _selection.RADIUS_PX
            love.graphics.setLineWidth(gdsGui_general_hairline() * 2)
            _selection.setAccent(0.35 * alpha)
            love.graphics.rectangle("line", x - pad, y - pad, fw + pad * 2, fh + pad * 2, r, r)
        end
    end
    local first, last = plan.segments[1], plan.segments[#plan.segments]
    for _, p in ipairs({ { first[1], first[2] }, { last[3], last[4] } }) do
        love.graphics.setColor(1, 1, 1, alpha)
        love.graphics.circle("fill", p[1], p[2], 5)
        _selection.setAccent(alpha)
        love.graphics.circle("fill", p[1], p[2], 3.5)
    end
    local fraction = _selection.holdFraction(canvas, "wire")
    if fraction then
        local pieces, total = _pipes.pathPieces(canvas, plan)
        local widths = _pipes.widths(canvas)
        love.graphics.setLineWidth((widths and widths.pipe or _WIRE_WIDTH_PX * canvas.zoom) + 4)
        _selection.setAccent(0.9)
        local reach = total * fraction
        for _, piece in ipairs(pieces) do
            local t1 = math.min(piece.len, reach - piece.d0)
            if t1 > 0.01 then _pipes.strokePiece(piece, 0, t1) end
        end
    end
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

local function _drawWire(canvas, w, plan, signature)
    if not plan then return end
    local wireWidth = _pipes.fluidWidth(canvas)
    if canvas.selectedWireId == w.id and not canvas.pipeConnectors then
        -- Same yellow/magenta selection emphasis as an element's outline
        -- (see its comment on gdsGui_schematic_update's long-press timer),
        -- drawn as a wider line underneath so it reads as a highlight
        -- around the wire. A pipe draws its own with its walls instead.
        _pipes.drawSelection(canvas, plan, wireWidth)
    end

    -- A wire fed by more than one source at once (see
    -- gdsGui_schematic_resolveColorSequence) reads the same as a bundle: one
    -- line of diagonal one-unit color bands (_drawWireBundleSegment), glowing
    -- the same way, with each hop arc in its first color.
    local sequence = gdsGui_schematic_resolveColorSequence(canvas.name, "wire", w.id, signature)
    if sequence then
        local colors = {}
        for i, c in ipairs(sequence) do colors[i] = { _themedPaletteColor(c[1], c[2], c[3], c[4] or 1) } end
        local function drawBands(arcColor, arcWidth, isHalo)
            local function setArcColor() love.graphics.setColor(arcColor[1], arcColor[2], arcColor[3], arcColor[4] or 1) end
            setArcColor()
            love.graphics.setLineWidth(arcWidth)
            local bendRadius = _pipes.bendRadius(canvas)
            local corners = bendRadius and _pipes.corners(plan, bendRadius)
            for idx, seg in ipairs(plan.segments) do
                local before, after = corners and corners[idx - 1], corners and corners[idx]
                _drawSegmentWithHopsAndGaps(seg[1], seg[2], seg[3], seg[4], plan.hopDistances[idx], plan.bundledRanges[idx], canvas.zoom,
                    function(ax, ay, bx, by)
                        if ax > bx or ay > by then ax, ay, bx, by = bx, by, ax, ay end
                        _drawWireBundleSegment(canvas, ax, ay, bx, by, colors, isHalo)
                        setArcColor()
                    end, before and before.r, after and after.r)
                -- A bend carries the run's first color, as a hop arc does.
                if before then _pipes.drawBend(before) end
            end
        end
        for _, c in ipairs(colors) do
            if _glow.applies(canvas, c[1], c[2], c[3]) then
                _glow.capture(function() drawBands({ c[1], c[2], c[3], 1 }, wireWidth * _glow.WIRE_WIDTH, true) end)
                break
            end
        end
        drawBands(colors[1], wireWidth)
    else
        local r, g, b, a = gdsGui_schematic_resolveDisplayColor(canvas.name, "wire", w.id, signature)
        r, g, b, a = _colorBlend.resolve(w, r, g, b, a)
        local bendRadius = _pipes.bendRadius(canvas)
        if _glow.applies(canvas, r, g, b) then _glow.wire(plan, canvas.zoom, wireWidth, r, g, b, bendRadius) end
        love.graphics.setColor(r, g, b, a)
        love.graphics.setLineWidth(wireWidth)
        _drawWirePlanSegments(plan, canvas.zoom, bendRadius)
    end
    love.graphics.setLineWidth(1)
end

local function _drawControl(canvas, c, signature)
    local cx, cy = _toPixel(canvas, c.x, c.y)
    local rad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
    -- Half-extent of the square SELECTION outline/label layout only — a
    -- few px of cosmetic breathing room around the icon. The icon itself
    -- (sprite, vector fallback, striped-sequence bounds, overlay sprite)
    -- draws at the bare hit-test radius (rad), the same one
    -- _footprintOverlapsAnother/_hitControl use, so a control's drawn
    -- footprint never exceeds the box that actually keeps it from
    -- overlapping its neighbors (see gdsGui's own "selection box IS the
    -- collision box" rule) — the +4 ring just frames it, never grows it.
    local drawHalf = rad + 4
    -- Same obstacle-highlight flag _drawElement checks — see its own
    -- comment and gdsGui_schematic_moved's "element"/"control" dragKind
    -- branches.
    if canvas.collidingObstacleId == c.id then
        love.graphics.setColor(1, 0, 0, 1)
        love.graphics.rectangle("line", cx - drawHalf, cy - drawHalf, drawHalf * 2, drawHalf * 2)
    end
    if canvas.selectedControlId == c.id then
        -- The same selection frame as an element's (see _selection), around
        -- the control's square footprint.
        local key = "c:" .. c.id
        local lift = _selection.lift(canvas)
        local function drawSelected(alpha)
            _selection.drawFrame(cx - drawHalf, cy - drawHalf, drawHalf * 2, drawHalf * 2, alpha, lift)
        end
        drawSelected(_selection.mark(canvas, key))
        _selection.remember(canvas, key, drawSelected)
        local holdFraction = _selection.holdFraction(canvas, "control")
        if holdFraction then _selection.drawHoldTrace(cx - drawHalf, cy - drawHalf, drawHalf * 2, drawHalf * 2, holdFraction) end
        -- The move/rotate overlay below draws in this color, translucent so it
        -- doesn't compete with the item itself.
        _selection.setAccent(0.5)
        if canvas.selectionMoveModeActive then
            -- Mutually exclusive, not both at once — see the matching
            -- comment in _drawElement.
            if canvas.rotateModeActive then
                _drawRotateModeOverlay(cx, cy, drawHalf, canvas.zoom)
            else
                _drawMoveModeOverlay(cx, cy, drawHalf, drawHalf, canvas.zoom)
            end
        end
    end
    -- Same resolved-color machinery (pendingColor preview, then
    -- signature-matched snapshot, then defaultColor) as an element/wire — see
    -- gdsGui_schematic_resolveDisplayColor and ASSIGN COLOR/the design-mode
    -- edit menu's swatch picker below.
    local darkenMul = c.colorDarkenMul or 1
    local spritePath = c.spritePaths and c.spritePaths[c.detentIndex + 1]
    local function drawBodyWithColor(rr, gg, bb, aa)
        rr, gg, bb = rr * darkenMul, gg * darkenMul, bb * darkenMul
        if spritePath then
            _drawElementSprite(spritePath, cx - rad, cy - rad, rad * 2, rad * 2, rr, gg, bb, aa, c.rotation)
        else
            love.graphics.setColor(rr, gg, bb, aa)
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
    end

    -- Same "stripe it instead of filling solid" treatment as _drawElement
    -- — see its own comment and gdsGui_schematic_resolveColorSequence.
    local r, g, b, a
    local sequence = gdsGui_schematic_resolveColorSequence(canvas.name, "control", c.id, signature)
    if sequence then
        r, g, b, a = sequence[1][1], sequence[1][2], sequence[1][3], sequence[1][4]
        _glow.haloStriped(canvas, cx - rad, cy - rad, rad * 2, rad * 2, sequence, drawBodyWithColor)
        _drawColorSequenceStriped(cx - rad, cy - rad, rad * 2, rad * 2, sequence, drawBodyWithColor)
    else
        r, g, b, a = gdsGui_schematic_resolveDisplayColor(canvas.name, "control", c.id, signature)
        r, g, b, a = _colorBlend.resolve(c, r, g, b, a)
        if _glow.applies(canvas, r, g, b) then _glow.halo(canvas.zoom, r, g, b, drawBodyWithColor) end
        drawBodyWithColor(r, g, b, a)
    end
    -- overlaySpritePath below reuses this same (darkened) representative
    -- color regardless of path, same as before this split.
    r, g, b = r * darkenMul, g * darkenMul, b * darkenMul
    if c.overlaySpritePath then
        -- Spins only in control mode AND while the control sits in its last
        -- ("ON"/flowing/conducting) position — same last-position-means-on
        -- convention _SWITCH_SPRITE_PATHS documents, so a generator's gear
        -- (or any other animated-overlay control) reads as "running" only
        -- when it's actually switched on, not just because the schematic
        -- itself is in control mode. Static (just c.rotation) otherwise —
        -- see gdsGui_schematic_update's _overlayAnimAngle. Tinted the same as
        -- the base icon so the two layers read as one colored object.
        local isOn = c.detentIndex == c.numDetents - 1
        local spinDeg = (canvas.mode == "control" and isOn) and math.deg(canvas._overlayAnimAngle or 0) or 0
        _drawElementSprite(c.overlaySpritePath, cx - rad, cy - rad, rad * 2, rad * 2, r, g, b, a,
            spinDeg + (c.rotation or 0))
    end
    -- A port with a flow direction (a pump's inlet/outlet) gets a labelled
    -- arrow pointing the way fluid moves through it.
    local labelAlpha = _labelAlphaForZoom(canvas.zoom)
    for i, t in ipairs(c.terminals or {}) do
        if t.flow then
            local tx, ty = _terminals.point(canvas, c, i)
            local rot = math.rad(c.rotation or 0)
            local ex, ey = t.exitX or 0, t.exitY or 0
            local exitX = ex * math.cos(rot) - ey * math.sin(rot)
            local exitY = ex * math.sin(rot) + ey * math.cos(rot)
            local sign = (t.flow == "out") and 1 or -1
            local dx, dy = exitX * sign, exitY * sign
            local size = rad * 0.32
            love.graphics.setColor(r, g, b, a)
            love.graphics.polygon("fill", tx + dx * size, ty + dy * size,
                tx - dx * size - dy * size, ty - dy * size + dx * size,
                tx - dx * size + dy * size, ty - dy * size - dx * size)
            -- Clear of both the icon and the pipe leaving the port: above a
            -- port on the side, beside one on the top or bottom.
            local tc = globApp.themeTextColor or {1, 1, 1, 1}
            love.graphics.setColor(tc[1], tc[2], tc[3], labelAlpha)
            love.graphics.setFont(globApp.appFont or love.graphics.getFont())
            local text = (t.flow == "out") and "OUT" or "IN"
            local font = love.graphics.getFont()
            local textW, textH = font:getWidth(text), font:getHeight()
            if math.abs(exitX) > math.abs(exitY) then
                love.graphics.print(text, tx + exitX * textW / 2 - textW / 2, ty - size - textH)
            else
                love.graphics.print(text, tx + size, ty + exitY * textH / 2 - textH / 2)
            end
        end
    end
    local posName = (c.positions and c.positions[c.detentIndex + 1]) or tostring(c.detentIndex)
    -- Row 1: the label (name). Row 2: the control's current status (ON/OFF,
    -- OPEN/CLOSED, STBY, ...).
    local text = (c.label or "") .. "\n" .. posName
    local tc = globApp.themeTextColor or {1, 1, 1, 1}
    love.graphics.setColor(tc[1], tc[2], tc[3], _labelAlphaForZoom(canvas.zoom))
    -- See _drawElement's matching comment just above its own label draw —
    -- same reason this can't rely on whatever font outputTxtBox's draw pass
    -- last left active.
    love.graphics.setFont(globApp.appFont or love.graphics.getFont())
    love.graphics.printf(text, cx - drawHalf * 2, cy + drawHalf + 2, drawHalf * 4, "center")
end

-- Draws one target reticle at an anchor's (element or control) center,
-- filled solid if it's the current snap target, a faint outline otherwise.
-- An anchor with terminals gets one (smaller) reticle per terminal instead,
-- only the snapped-to terminal (snapTerminal) filled.
local function _drawOneConnectorTarget(canvas, anchor, snapTarget, snapTerminal)
    if anchor.id == canvas.wireTool.fromId then return end
    if anchor.terminals then
        local rad = _CONNECTOR_TARGET_RADIUS_PX * canvas.zoom * 0.6
        for i in ipairs(anchor.terminals) do
            local tx, ty = _terminals.point(canvas, anchor, i)
            if snapTarget and snapTarget.id == anchor.id and snapTerminal == i then
                love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 1)
                gdsGui_general_drawCircle(tx, ty, rad)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.circle("line", tx, ty, rad)
            else
                love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 0.55)
                love.graphics.circle("line", tx, ty, rad)
            end
        end
        return
    end
    local cx, cy = _anchorCenter(canvas, anchor)
    local rad = _CONNECTOR_TARGET_RADIUS_PX * canvas.zoom
    if snapTarget and snapTarget.id == anchor.id then
        love.graphics.setColor(_CONNECTOR_SNAP_COLOR[1], _CONNECTOR_SNAP_COLOR[2], _CONNECTOR_SNAP_COLOR[3], 1)
        gdsGui_general_drawCircle(cx, cy, rad)
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
local function _drawConnectorTargets(canvas, snapTarget, snapTerminal)
    for _, e in ipairs(canvas.elements) do _drawOneConnectorTarget(canvas, e, snapTarget, snapTerminal) end
    for _, c in ipairs(canvas.controls) do
        if not c.hidden then _drawOneConnectorTarget(canvas, c, snapTarget, snapTerminal) end
    end
end

function gdsGui_schematic_draw(pageName)
    -- Highlights whichever element/control the AI info panel's current
    -- REASON line is blaming for this combination's own confidence
    -- shortfall — canvas.aiCulpritId, a plain transient field the
    -- main.lua adapter sets each frame the AI panel is open and clears
    -- the instant it isn't (same "just a shared field on canvas, no
    -- public setter" convention canvas.collidingObstacleId already
    -- uses). Drawn as its own final overlay pass (see its one call site,
    -- after every element/control/wire/annunciator) rather than inline
    -- inside _drawElement/_drawControl like the obstacle/selection
    -- highlights are — so the ring is never partially hidden by some
    -- OTHER entity drawn on top of it later in the same frame. Nested
    -- here (not a file-scope local like every other _draw* helper) to
    -- stay under this file's 200-local ceiling.
    local function drawAiCulpritHighlight(canvas)
        local id = canvas.aiCulpritId
        if not id then return end
        local anchor = _findAnchor(canvas, id)
        if not anchor then return end

        local cx, cy, radius
        if anchor.w then
            local fex, fey, few, feh = _elementFootprintRect(canvas, anchor)
            cx, cy = fex + few / 2, fey + feh / 2
            radius = math.sqrt((few / 2) ^ 2 + (feh / 2) ^ 2) + 6
        else
            cx, cy = _toPixel(canvas, anchor.x, anchor.y)
            radius = canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1) + 8
        end

        love.graphics.setColor(1, 0.84, 0, 1) -- gold
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", cx, cy, radius)
        love.graphics.setLineWidth(1)
        love.graphics.setColor(1, 1, 1, 1)
    end

    -- Viewport culling: skip issuing draw calls entirely for anything whose
    -- own bounding box doesn't even overlap the canvas's visible on-screen
    -- rect (canvas.x/y/w/h — the same rect love.graphics.setScissor already
    -- clips to below, GPU-side). Scissor only discards already-issued
    -- fragments at the GPU; it does nothing for the CPU-side cost of
    -- actually BUILDING each draw call (table reads, color resolution,
    -- love.graphics state changes) in the first place — that cost was
    -- previously paid for every element/control/wire in the WHOLE diagram,
    -- every frame, regardless of how much of it was actually panned into
    -- view. Padded by cullPad so nothing merely near the edge (a label
    -- that overflows its own box, a selection/highlight ring's extra
    -- radius) pops in/out right at the boundary. vx/vy/vw/vh are set fresh
    -- per canvas below (each schematic page's own canvas has its own
    -- rect); rectVisible reads them as upvalues, so one closure serves
    -- every canvas in the loop.
    local cullPad = 48
    local vx, vy, vw, vh
    local function rectVisible(x, y, w, h)
        return x < vx + vw and x + w > vx and y < vy + vh and y + h > vy
    end

    -- Unconditional self-heal, once per frame, before anything below ever
    -- touches a render target/shader/blend mode: nothing else in this app
    -- ever re-asserts "the screen" as the active canvas on its own, so a
    -- render-target leak from ANY source (a glow pass that failed mid-frame
    -- last frame — see _glow.guarded's own comment — or a stale GPU
    -- resource from an iOS app suspend/resume) would otherwise silently
    -- persist forever, with every draw call from here on landing on
    -- whatever got left active instead of the visible screen. Cheap (a
    -- handful of state-setting calls) and always safe to force, whether or
    -- not anything was actually wrong.
    _glow.resetGraphicsState()

    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName then
            -- An open menu (gdsGui_schematic_drawMenuOverlay, drawn later
            -- this frame) gets a real blurred backdrop instead of a flat
            -- dim rect — see _menuBackdrop's own header comment. Redirects
            -- every draw call below into an offscreen buffer instead of
            -- the screen; _menuBackdrop.finish (at the bottom of this same
            -- iteration) blurs it and draws it to the screen in its place.
            local backdropActive = false
            if canvas.menu then
                _menuBackdrop.begin()
                backdropActive = _menuBackdrop.active
            end
            love.graphics.setScissor(canvas.x, canvas.y, canvas.w, canvas.h)
            vx, vy = canvas.x - cullPad, canvas.y - cullPad
            vw, vh = canvas.w + cullPad * 2, canvas.h + cullPad * 2

            -- globApp.themeCanvasBgColor (set by the app layer's dark/light
            -- mode toggle, if it sets one at all) — see _drawGrid's own
            -- fallback comment just below for why this isn't just hardcoded.
            local canvasBg = globApp.themeCanvasBgColor or {0.10, 0.10, 0.12, 1}
            love.graphics.setColor(canvasBg[1], canvasBg[2], canvasBg[3], canvasBg[4])
            love.graphics.rectangle("fill", canvas.x, canvas.y, canvas.w, canvas.h)
            _drawCanvasCornerBackground(canvas)
            _drawCanvasBackground(canvas)
            if canvas.mode == "design" then _drawGrid(canvas) end

            -- Computed once per canvas per frame and threaded through every
            -- element/wire/control draw call below, rather than each of them
            -- separately calling gdsGui_schematic_computeSignature on its own
            -- (a table.sort + string-concat over every control, repeated once
            -- per drawn entity for a value that cannot change mid-frame).
            local signature = gdsGui_schematic_computeSignature(canvas.name)
            local wirePlans, wireBundles = _computeWirePlans(canvas)
            _glow.begin(canvas)
            -- Culled by the bounding box of its own ACTUAL path (every
            -- segment's endpoints), not just a straight line between its
            -- two anchors — a jogged/bent wire can swing well outside
            -- that straight-line box while still having a real anchor
            -- off-screen on each end. No plan (a dangling wire mid-undo,
            -- same case _hitWire's own fallback handles) always draws —
            -- nothing to measure, so nothing safe to cull.
            local function wireVisible(plan)
                local visible = true
                if plan and plan.segments and #plan.segments > 0 then
                    local minX, minY, maxX, maxY
                    for _, seg in ipairs(plan.segments) do
                        local loX, hiX = math.min(seg[1], seg[3]), math.max(seg[1], seg[3])
                        local loY, hiY = math.min(seg[2], seg[4]), math.max(seg[2], seg[4])
                        minX = minX and math.min(minX, loX) or loX
                        maxX = maxX and math.max(maxX, hiX) or hiX
                        minY = minY and math.min(minY, loY) or loY
                        maxY = maxY and math.max(maxY, hiY) or hiY
                    end
                    visible = rectVisible(minX, minY, maxX - minX, maxY - minY)
                end
                return visible
            end
            if canvas.pipeConnectors then
                _pipes.drawAllWalls(canvas, wirePlans, wireBundles, wireVisible, rectVisible)
            end
            for _, w in ipairs(canvas.wires) do
                local plan = wirePlans[w.id]
                if wireVisible(plan) then _drawWire(canvas, w, plan, signature) end
            end
            -- Each bundle zone (see _computeWirePlans) draws as ONE
            -- line with its member wires' own colors, resolved fresh here
            -- (not cached in the plan) same as every other entity's color —
            -- see _drawWireBundleSegment. Culled by its own two endpoints
            -- directly (already absolute pixel coordinates, unlike a wire's
            -- segments — no need to scan anything to get its bounding box).
            for _, bundle in ipairs(wireBundles) do
                local loX, hiX = math.min(bundle.x1, bundle.x2), math.max(bundle.x1, bundle.x2)
                local loY, hiY = math.min(bundle.y1, bundle.y2), math.max(bundle.y1, bundle.y2)
                if rectVisible(loX, loY, hiX - loX, hiY - loY) then
                    local colors = {}
                    for _, wireId in ipairs(bundle.wireIds) do
                        local sequence = gdsGui_schematic_resolveColorSequence(canvas.name, "wire", wireId, signature)
                        if sequence then
                            for _, c in ipairs(sequence) do
                                table.insert(colors, { _themedPaletteColor(c[1], c[2], c[3], c[4] or 1) })
                            end
                        else
                            table.insert(colors, { gdsGui_schematic_resolveDisplayColor(canvas.name, "wire", wireId, signature) })
                        end
                    end
                    if canvas.glow and canvas.glow.active then
                        _glow.capture(function()
                            _drawWireBundleSegment(canvas, bundle.x1, bundle.y1, bundle.x2, bundle.y2, colors, true)
                        end)
                    end
                    _drawWireBundleSegment(canvas, bundle.x1, bundle.y1, bundle.x2, bundle.y2, colors)
                end
            end
            if canvas.pipeConnectors then
                -- drawAllStreaks is the STATIC center highlight giving a pipe
                -- its round-tube look; drawAllFlow (see its own section
                -- header) is the marching-dash flow cue, unrelated to it.
                _pipes.drawAllStreaks(canvas, wirePlans, wireBundles, wireVisible, rectVisible)
                _pipes.drawAllFlow(canvas, wirePlans, wireVisible, signature)
            end
            -- Direction arrow (see _pipes.drawDirectionArrow) and leak spray
            -- (see _pipes.drawLeak): drawn in their own pass, after both the
            -- per-wire fluid lines AND the bundle color bands above, so a
            -- mark on a stretch shared with another pipe (bundled) still
            -- shows on top instead of being painted over by that later
            -- bundle-band pass.
            if _pipes.isLiquid(canvas) then
                for _, w in ipairs(canvas.wires) do
                    local plan = wirePlans[w.id]
                    if plan and wireVisible(plan) then
                        _pipes.drawEmptiedRun(canvas, w, plan)
                        _pipes.drawDirectionArrow(canvas, w, plan)
                    end
                end
            end
            for _, e in ipairs(canvas.elements) do
                local ex, ey, ew, eh = _elementFootprintRect(canvas, e)
                if rectVisible(ex, ey, ew, eh) then
                    -- A selected element with move mode unlocked draws lifted (see _selection).
                    local lift = canvas.selectedElementId == e.id and _selection.lift(canvas) or 0
                    if lift > 0 then _selection.beginLift(ex + ew / 2, ey + eh / 2, ew, eh, lift) end
                    _drawElement(canvas, e, signature)
                    if lift > 0 then love.graphics.pop() end
                end
            end
            for _, c in ipairs(canvas.controls) do
                local ccx, ccy = _toPixel(canvas, c.x, c.y)
                local crad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
                if not c.hidden and rectVisible(ccx - crad, ccy - crad, crad * 2, crad * 2) then
                    local lift = canvas.selectedControlId == c.id and _selection.lift(canvas) or 0
                    if lift > 0 then _selection.beginLift(ccx, ccy, crad * 2, crad * 2, lift) end
                    _drawControl(canvas, c, signature)
                    if lift > 0 then love.graphics.pop() end
                end
            end
            -- Leak spray (see _pipes.drawLeak): drawn after elements/controls,
            -- not in the per-wire pass above -- a dead-end leak sits right at
            -- a valve/manifold port, and that element's own redraw (just
            -- above) would otherwise paint straight over the spray.
            if _pipes.isLiquid(canvas) then
                for _, w in ipairs(canvas.wires) do
                    local plan = wirePlans[w.id]
                    if plan and wireVisible(plan) then
                        _pipes.drawLeak(canvas, w, plan, signature)
                    end
                end
                _pipes.drawOpenPortLeaks(canvas, signature)
            end
            _glow.finish(canvas)
            _drawAnnunciators(canvas)
            drawAiCulpritHighlight(canvas)
            _terminals.drawPick(canvas)
            _selection.drawConnectorExtras(canvas, wirePlans)
            _wirePath.draw(canvas)
            _selection.endFrame(canvas)

            if canvas.wireTool.fromId then
                local fromE = _findAnchor(canvas, canvas.wireTool.fromId)
                if fromE and canvas.wireTool.curX then
                    local snapTarget, snapTerminal = _connectorSnapTarget(canvas)
                    _drawConnectorTargets(canvas, snapTarget, snapTerminal)
                    -- Name the port it would land on, so an ejector's suction
                    -- port can be told from its motive port. Pipes and ducts
                    -- only: a switch's lugs have nothing worth naming.
                    if snapTerminal and #snapTarget.terminals >= 2 and _pipes.noun(canvas) ~= "WIRE" then
                        _terminals.drawLabel(canvas, snapTarget, snapTerminal)
                    end
                    -- Clamped to the snap target's center/terminal (if any)
                    -- rather than the raw cursor/finger position, so the line
                    -- visibly locks on once in range instead of just trailing
                    -- the touch point.
                    local tx, ty = canvas.wireTool.curX, canvas.wireTool.curY
                    local toA, toAxis
                    if snapTarget then
                        tx, ty, toA, toAxis = _terminals.wireEnd(canvas, snapTarget, snapTerminal)
                    end
                    -- A from-terminal not yet picked (ADD WIRE started off
                    -- the control) follows whichever is nearest the loose end
                    -- — the same pick the release makes.
                    local fromTerminal = canvas.wireTool.fromTerminal or _terminals.nearest(canvas, fromE, tx, ty)
                    local fx, fy, fromA, fromAxis = _terminals.wireEnd(canvas, fromE, fromTerminal)
                    love.graphics.setColor(1, 1, 1, 0.6)
                    love.graphics.setLineWidth(2 * canvas.zoom)
                    -- fromE's end always clamps to its own edge (or meets its
                    -- terminal); the loose cursor/finger end only clamps once
                    -- it's snapped onto a real target, same as the finished
                    -- wire.
                    _drawClampedOrthogonalLine(canvas,
                        _terminals.segments(canvas, fx, fy, fromA, fromAxis, tx, ty, toA, toAxis))
                    love.graphics.setLineWidth(1)
                end
            end

            love.graphics.setColor(1, 1, 1, 1)
            if backdropActive then _menuBackdrop.finish() end
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

function gdsGui_schematic_wheelZoom(x, y, dy)
    if dy == 0 then return end
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        -- Same dead zone gdsGui_schematic_pressed's own check consumes taps
        -- against — a wheel event over it scrolls the app's overlay
        -- instead of zooming the canvas underneath.
        if canvas.page == activePageName and canvas.inputBlockRect then
            local r = canvas.inputBlockRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                if canvas.inputBlockWheelCallback then
                    local fn = _G[canvas.inputBlockWheelCallback]
                    if fn then fn(dy, false) end
                end
                return
            end
        end
        if canvas.page == activePageName and canvas.menu and canvas.menu.choiceGrid then
            _choiceGrid.wheel(canvas, dy)
            return
        end
        if canvas.page == activePageName and canvas.menu and canvas.menu.propertyGrid then
            _propertyGrid.wheel(canvas, dy)
            return
        end
        if canvas.page == activePageName and not canvas.menu
           and x >= canvas.x and x <= canvas.x + canvas.w
           and y >= canvas.y and y <= canvas.y + canvas.h then
            -- True 0-1 content fractions (not raw pixel offsets) so they
            -- stay correct even as the viewport box smoothly grows with
            -- zoom (see _calculateGeometry).
            local anchorFracX = ((x - canvas.x - canvas.panX) / canvas.zoom) / canvas.contentW
            local anchorFracY = ((y - canvas.y - canvas.panY) / canvas.zoom) / canvas.contentH
            local wheelZoomSensitivity = 0.12 -- zoom multiplier per unit of wheel delta
            local newZoom = canvas.zoom * ((1 + wheelZoomSensitivity) ^ dy)
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

-- True if (px,py) lands on a visible, active floating chrome button for this
-- page (ADD/PAINT/SNAPSHOT/etc. — any button with no owner container, since
-- those dock directly over the canvas rather than inside a page container).
-- gdsGui_general_mousepressed/_touchpressed call gdsGui_button_pressed and
-- gdsGui_schematic_pressed back-to-back for the SAME press with no
-- "consumed" signal between them, so a dock button that sits geometrically
-- inside the canvas's own x/y/w/h box (every floating button here does) is
-- also seen by the canvas as a tap on itself. That's harmless for a plain
-- selection/pan tap, but PAINT MODE treats any miss as empty canvas space
-- (which pans the view — see just below) and would otherwise immediately
-- start panning the instant the PAINT button that just armed it is tapped —
-- this guard is what stops that.
local function _hitsFloatingButton(pageName, px, py)
    for _, b in ipairs(globApp.objects.buttons) do
        if b.page == pageName and not b.hidden and b.state ~= globApp.BUTTON_STATES.DEACTIVATED and
           not b.ownerContainer and px >= b.myx and px <= b.myMaxx and py >= b.myy and py <= b.myMaxy then
            return true
        end
    end
    return false
end

function gdsGui_schematic_pressed(touchId, x, y)
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page ~= activePageName then goto continue end

        -- A press a button already handled (see globApp.buttonPressConsumed
        -- in buttons_gdsGuiLib.lua) never reaches the canvas — checked even
        -- before the modal menu below, since a dock tool button (e.g. ADD)
        -- can open that very menu in its own press callback, and this same
        -- press would otherwise be recorded as an "outside" tap that
        -- cancels it on release.
        if globApp.buttonPressConsumed then goto continue end

        -- A modal menu always takes priority and consumes the tap. Only
        -- records what it landed on — gdsGui_schematic_released below is
        -- what actually fires onSelect/onCancel.
        if canvas.menu then
            if canvas.menu.choiceGrid then
                _choiceGrid.press(canvas, touchId, x, y)
            elseif canvas.menu.propertyGrid then
                _propertyGrid.press(canvas, touchId, x, y)
            else
                _handleMenuPress(canvas, touchId, x, y)
            end
            goto continue
        end

        if x < canvas.x or x > canvas.x + canvas.w or y < canvas.y or y > canvas.y + canvas.h then goto continue end

        -- A floating dock button (ADD/PAINT/SNAPSHOT/...) geometrically
        -- overlaps the canvas it floats on top of — let the button own this
        -- tap entirely rather than also treating it as a canvas tap (see
        -- _hitsFloatingButton's own comment for why this matters for PAINT
        -- MODE specifically).
        if _hitsFloatingButton(activePageName, x, y) then goto continue end

        -- An app-registered dead zone (see gdsGui_schematic_
        -- setInputBlockRect) — e.g. main.lua's AI info panel, an
        -- app-layer overlay the library itself knows nothing about —
        -- consumes the tap outright, same "takes priority" treatment as
        -- canvas.menu/the annunciator panel below, just opaque to WHY.
        -- Also starts tracking this touch for drag-to-scroll forwarding
        -- (see gdsGui_schematic_moved/_released below) — the SAME
        -- inputBlockWheelCallback the mouse-wheel path uses, just fed a
        -- pixel delta instead of a wheel notch count.
        if canvas.inputBlockRect then
            local r = canvas.inputBlockRect
            if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                canvas.inputBlockTouchId = touchId
                canvas.inputBlockTouchY = y
                goto continue
            end
        end

        -- Same "takes priority, consumes the tap" treatment as canvas.menu
        -- above — see _handleAnnunciatorPanelPress's own comment for why.
        if canvas.annunciatorPanelOpen then
            -- A tap outside the panel on empty canvas space (no element/
            -- wire/control drawn there) closes it, same as toggling the
            -- ANNUNCIATOR button off — the app layer's poll restores the
            -- dock. Anything else is still consumed by the panel.
            if _annunciatorRowAt(canvas, x, y) == "outside" and canvas.mode == "design"
               and not (_hitElement(canvas, x, y) or _hitWire(canvas, x, y) or _hitControl(canvas, x, y)) then
                canvas.annunciatorPanelOpen = false
            else
                _handleAnnunciatorPanelPress(canvas, touchId, x, y)
            end
            goto continue
        end

        -- Track every finger down inside this canvas regardless of what the
        -- first one is already doing, so a second one lands as a pinch.
        canvas.touches[touchId] = { x = x, y = y }
        if _touchCount(canvas.touches) >= 2 then
            canvas.focusTouchId        = nil
            canvas.dragKind            = nil
            canvas.wireTool.fromId     = nil
            canvas.collidingObstacleId = nil
            _startPinch(canvas)
            goto continue
        end

        if canvas.focusTouchId ~= nil then goto continue end

        if canvas.pathEdit and canvas.mode == "design" then
            _wirePath.press(canvas, touchId, x, y)
            goto continue
        end

        if canvas.mode == "control" then
            -- "Operate" mode: tapping (or holding — there's no timed
            -- long-press distinction here) a control opens an iOS-styled
            -- menu listing its own positions directly (gdsGui_schematic_
            -- released below) instead of cycling it one step at a time.
            -- Anything without positions of its own (a plain element, a
            -- wire) has nothing to select here at all — same as tapping
            -- empty canvas space.
            local control = _hitControl(canvas, x, y)
            if control then
                canvas.focusTouchId  = touchId
                canvas.dragStartX    = x
                canvas.dragStartY    = y
                canvas.dragMoved     = false
                canvas.dragKind      = "controlTap"
                canvas._controlTapId = control.id
                goto continue
            end
            -- A plain element (a tank, say) has no positions of its own,
            -- but the app layer may still have something quick to show for
            -- it (gdsGui_schematic_openElementControlRows below) -- same
            -- "resolve what to do about it on release" deferral as a
            -- control's own tap just above; an element with nothing to
            -- show there just does nothing, same as today.
            local elem = _hitElement(canvas, x, y)
            if elem then
                canvas.focusTouchId  = touchId
                canvas.dragStartX    = x
                canvas.dragStartY    = y
                canvas.dragMoved     = false
                canvas.dragKind      = "elementTap"
                canvas._elementTapId = elem.id
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
            local isElementPlacement = canvas.pendingPlacement.kind == "element"
            local wFrac, hFrac
            if isElementPlacement then
                wFrac, hFrac = _pendingElementSizeFrac(canvas, canvas.pendingPlacement)
                fracX, fracY = _snapElementToGrid(canvas, fracX, fracY, wFrac, hFrac)
            else
                fracX, fracY = _snapToGrid(canvas, fracX, fracY)
            end

            -- Same "can't overlap an existing element/control" rule the
            -- drag handlers enforce (see _footprintOverlapsAnother) —
            -- checked here at the tap itself so an invalid spot never
            -- even reaches the ELEMENT PROPERTIES grid. pendingPlacement
            -- stays armed either way — a rejected tap is simply ignored,
            -- same as missing the canvas entirely, so the user can just
            -- try a different spot right away.
            local candCx, candCy, candHalfX, candHalfY
            if isElementPlacement then
                local px, py = _toPixel(canvas, fracX, fracY)
                local pw, ph = wFrac * canvas.contentW * canvas.zoom, hFrac * canvas.contentH * canvas.zoom
                candCx, candCy, candHalfX, candHalfY = px + pw / 2, py + ph / 2, pw / 2, ph / 2
            else
                candCx, candCy = _toPixel(canvas, fracX, fracY)
                candHalfX = canvas.controlRadius * canvas.zoom * _controlGridRadiusScale(canvas, canvas.pendingPlacement.gridSize)
                candHalfY = candHalfX
            end
            if _footprintOverlapsAnother(canvas, candCx, candCy, candHalfX, candHalfY, nil) then
                gdsGui_haptics_feedback("error")
                gdsGui_schematic_openMenu(canvas.name, "CAN'T PLACE HERE — IT OVERLAPS ANOTHER ELEMENT.", {"OK"},
                    "gdsGui_schematic_internal_onPlacementOverlapDismissed", nil)
                goto continue
            end

            canvas._placementCounter = canvas._placementCounter + 1
            local newId = canvas.pendingPlacement.idPrefix .. "_" .. canvas._placementCounter
            _pendingNamedPlacement = {
                canvasName = canvas.name, newId = newId, fracX = fracX, fracY = fracY,
                label = canvas.pendingPlacement.label,
                kind = canvas.pendingPlacement.kind, shapeType = canvas.pendingPlacement.shapeType,
                positions = canvas.pendingPlacement.positions, defaultColor = canvas.pendingPlacement.defaultColor,
                callbackFunc = canvas.pendingPlacement.callbackFunc,
                defaultPropertyKeys = canvas.pendingPlacement.defaultPropertyKeys,
                spritePath = canvas.pendingPlacement.spritePath,
                spritePaths = canvas.pendingPlacement.spritePaths,
                overlaySpritePath = canvas.pendingPlacement.overlaySpritePath,
                gridW = canvas.pendingPlacement.gridW,
                gridH = canvas.pendingPlacement.gridH,
                -- Was missing entirely -- _commitNamedPlacement reads all
                -- three of these off `pending` (componentType for
                -- addElement/addControl's own trailing param, gridSize/
                -- colorDarkenMul for a control's radiusScale/dim factor),
                -- but nothing ever copied them from canvas.pendingPlacement
                -- into this struct, so every catalog-placed element/control
                -- silently got componentType=nil (opting it out of the
                -- inference model's graph entirely) and every control was
                -- placed at a flat radiusScale/colorDarkenMul regardless of
                -- its catalog entry's own gridSize/colorDarkenMul.
                componentType = canvas.pendingPlacement.componentType,
                gridSize = canvas.pendingPlacement.gridSize,
                colorDarkenMul = canvas.pendingPlacement.colorDarkenMul,
                terminals = canvas.pendingPlacement.terminals,
            }
            -- Every tap-to-place item (element or control — never an
            -- annunciator, which has no canvas position to tap for and
            -- goes straight from gdsGui_schematic_armAnnunciatorCreation to
            -- the plain _openPlacementNamePrompt below instead) now opens
            -- one unified NAME(+TYPE/VOLTAGE/PROPERTIES) grid — see
            -- _openElementPlacementGrid.
            _openElementPlacementGrid(canvas.name, _pendingNamedPlacement)
            canvas.pendingPlacement = nil
            goto continue
        end

        if canvas.pendingColorAssignPick then
            -- One-shot pick armed via gdsGui_schematic_armColorAssignPick:
            -- whatever this tap lands on (element, then wire, then control)
            -- gets its swatch color picker opened directly; empty space just
            -- disarms.
            canvas.pendingColorAssignPick = false
            local pickedElem = _hitElement(canvas, x, y)
            if pickedElem then
                gdsGui_schematic_openColorPicker(canvas.name, "element", pickedElem.id,
                    "COLOR: " .. (pickedElem.label or pickedElem.id))
            else
                local pickedWire = _hitWire(canvas, x, y)
                if pickedWire then
                    gdsGui_schematic_openColorPicker(canvas.name, "wire", pickedWire.id,
                        "COLOR: " .. _pipes.noun(canvas) .. ": " .. pickedWire.id)
                else
                    local pickedControl = _hitControl(canvas, x, y)
                    if pickedControl then
                        gdsGui_schematic_openColorPicker(canvas.name, "control", pickedControl.id,
                            "COLOR: " .. (pickedControl.label or pickedControl.id))
                    end
                end
            end
            goto continue
        end

        if canvas.paintMode then
            local hit = _paintPaletteHit(canvas, x, y)
            if hit == "panel" then
                goto continue -- missed every swatch but still inside the palette panel; consumed, no-op
            elseif hit then
                canvas.paintMode.color = _COLOR_PALETTE[hit].color
                goto continue
            end
            -- Not the palette — see if the tap landed on a paintable target.
            -- Deliberately its own dragKind ("paint"), untouched by the
            -- ordinary selection/move/rotate machinery below: a held-and-
            -- dragged press never paints (see gdsGui_schematic_moved/
            -- _released, which only commit the paint on an unmoved release),
            -- and nothing here sets canvas.selectedElementId/etc. either, so
            -- paint mode never leaves a stray selection behind.
            local target, targetKind = _hitElement(canvas, x, y), "element"
            if not target then target, targetKind = _hitWire(canvas, x, y), "wire" end
            if not target then target, targetKind = _hitControl(canvas, x, y), "control" end
            -- A "source"-role element/control (BATTERY, GENERATOR, ...)
            -- isn't a paintable target: its powered-state color is now
            -- fully automatic (app-layer, keyed off its own VOLTAGE — see
            -- main.lua's PER-SOURCE SETTINGS), and a brush pick here would
            -- write a permanent pendingColor that outranks that derived
            -- color in resolveColor's own tier chain, silently freezing the
            -- source's appearance out of sync with its voltage forever. A
            -- tap on one falls through to the plain-miss/pan branch below,
            -- same as tapping empty canvas space. Wires between sources
            -- stay paintable as normal — only the source node itself is
            -- excluded.
            if target and target.componentType == "source" then target = nil end
            -- noPaint: an app-set flag for any item whose color the app
            -- doesn't want taught (e.g. a relay's command wire and switch).
            if target and target.noPaint then target = nil end
            if target then
                canvas.focusTouchId = touchId
                canvas.dragKind     = "paint"
                canvas.dragStartX   = x
                canvas.dragStartY   = y
                canvas.dragMoved    = false
                canvas._paintTarget = { kind = targetKind, id = target.id }
            else
                -- A miss (empty canvas space, no item drawn there) pans the
                -- view instead, same as a plain miss outside paint mode — a
                -- clean TAP here (not an actual pan/pinch) also disarms the
                -- brush on release though, same as the PAINT dock button
                -- itself (gdsGui_schematic_disarmPaintMode) — see
                -- gdsGui_schematic_released's own dragKind == "pan" branch.
                canvas.focusTouchId = touchId
                canvas.dragKind     = "pan"
                canvas.dragStartX   = x
                canvas.dragStartY   = y
                canvas.panStartX    = canvas.panX
                canvas.panStartY    = canvas.panY
            end
            goto continue
        end

        if canvas.pendingWirePortPick then
            -- ADD WIRE on an element with two or more ports: this press says
            -- which port the wire leaves from, and starts dragging it from
            -- there. A tap that lands on no port cancels, same as ADD PORT.
            -- Just tapping the port keeps it armed from that port; see the
            -- wireTool branch of the release. portPicked = "pick" marks this
            -- press, and pressX/pressY tell that tap from a drag.
            local anchor = _findAnchor(canvas, canvas.pendingWirePortPick)
            canvas.pendingWirePortPick = nil
            local index = anchor and _terminals.pickAt(canvas, anchor, x, y)
            if index then
                gdsGui_haptics_feedback("selection")
                canvas.focusTouchId          = touchId
                canvas.wireTool.fromId       = anchor.id
                canvas.wireTool.fromTerminal = index
                canvas.wireTool.portPicked   = "pick"
                canvas.wireTool.pressX       = x
                canvas.wireTool.pressY       = y
                canvas.wireTool.curX         = x
                canvas.wireTool.curY         = y
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
            local pickedTerminal = canvas.pendingWireFromTerminal
            canvas.pendingWireFromId = nil
            canvas.pendingWireFromTerminal = nil
            local fromAnchor = _findAnchor(canvas, fromId)
            if fromAnchor then
                canvas.focusTouchId    = touchId
                canvas.wireTool.fromId = fromId
                canvas.wireTool.curX   = x
                canvas.wireTool.curY   = y
                -- Starting the drag on the control itself picks its terminal
                -- right here; starting anywhere else leaves it to follow
                -- the loose end (see the wire-drag preview in
                -- gdsGui_schematic_draw, and the release).
                -- A port already picked (pendingWirePortPick) holds either way.
                canvas.wireTool.fromTerminal = pickedTerminal or ((_hitControl(canvas, x, y) == fromAnchor)
                    and _terminals.nearest(canvas, fromAnchor, x, y) or nil)
                canvas.wireTool.portPicked = pickedTerminal ~= nil
            end
            goto continue
        end

        if canvas.pendingPort then
            -- Disarms either way, so a tap away from the tank cancels it.
            local pending = canvas.pendingPort
            canvas.pendingPort = nil
            local tank = _findElement(canvas, pending.elementId)
            if tank then
                local done
                if pending.removing then
                    done = _shapePoly.removePortAt(canvas, tank, x, y)
                elseif pending.moving == true then
                    -- MOVE PORT's first tap picks the port; off every port cancels.
                    local index = _terminals.pickAt(canvas, tank, x, y)
                    if index then
                        canvas.pendingPort = { elementId = tank.id, moving = index }
                        gdsGui_haptics_feedback("selection")
                    end
                elseif pending.moving then
                    done = _shapePoly.movePortTo(canvas, tank, pending.moving, x, y)
                else
                    done = _shapePoly.addPortAt(canvas, tank, x, y)
                end
                if done then gdsGui_haptics_feedback("light") end
            end
            goto continue
        end

        -- Reshape mode's corner handles and sides straddle the shape's outline,
        -- and an outward pull starts on them, so they're checked ahead of any hit-test.
        local reshapeTarget = _shapePoly.activeTarget(canvas)
        if reshapeTarget and not (canvas.wireToolActive or canvas.pendingConnectorColor) then
            local handleIndex, isSide = _shapePoly.handleAt(canvas, reshapeTarget, x, y)
            if handleIndex then
                canvas.focusTouchId = touchId
                canvas.dragKind     = "reshape"
                canvas.dragStartX   = x
                canvas.dragStartY   = y
                canvas.dragMoved    = false
                canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                _shapePoly.beginDrag(canvas, reshapeTarget, handleIndex, isSide)
                goto continue
            end
        end

        local hitElem = _hitElement(canvas, x, y)
        if canvas.wireToolActive or canvas.pendingConnectorColor then
            -- A connector can start from either an element (box) or a
            -- control (rotary switch) — both are valid wire endpoints.
            local anchor = hitElem or _hitControl(canvas, x, y)
            if anchor then
                canvas.focusTouchId    = touchId
                canvas.wireTool.fromId = anchor.id
                canvas.wireTool.fromTerminal = _terminals.nearest(canvas, anchor, x, y)
                canvas.wireTool.portPicked = nil
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
            if not isActiveMoveTarget then
                canvas.selectionMoveModeActive = false
                canvas.rotateModeActive = false
            end
            if isActiveMoveTarget then
                canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                -- Every element is rotatable now (move/rotate applies
                -- uniformly across every shapeType/system) — a fresh press
                -- on an already-unlocked selection TOGGLES between the two
                -- modes rather than always picking one, so repeated taps
                -- alternate move/rotate/move/rotate... (see the matching
                -- control branch below, and gdsGui_schematic_released's
                -- now-redundant-but-harmless confirm of the same flag).
                -- Set here (press time), not just on a no-drag release, so
                -- the overlay already matches for the whole gesture if this
                -- press goes straight into a real drag.
                -- A reshapable element has a third stop: from rotate, the
                -- next tap enters reshape (dragging nothing until a corner or
                -- side is pressed), and a tap on its body, or a side without
                -- dragging it (see gdsGui_schematic_released), comes back
                -- around to move.
                if canvas.rotateModeActive and _shapePoly.allowed(canvas, hitElem) then
                    canvas.dragKind = "reshapeEnter"
                    canvas.rotateModeActive = false
                    canvas.reshapeModeActive = true
                    canvas._pendingDragUndoSnapshot = nil
                elseif not canvas.rotateModeActive and not canvas.reshapeModeActive then
                    canvas.dragKind = "rotate"
                    canvas.rotateModeActive = true
                    local cx, cy = _elementCenter(canvas, hitElem)
                    canvas.rotateGrabAngleOffset = math.atan2(y - cy, x - cx) - math.rad(hitElem.rotation or 0)
                else
                    canvas.dragKind    = "element"
                    canvas.rotateModeActive = false
                    canvas.reshapeModeActive = false
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
                if not isActiveMoveTarget then
                    canvas.selectionMoveModeActive = false
                    canvas.rotateModeActive = false
                end
                if isActiveMoveTarget then
                    -- Every control is rotatable, same as every element now
                    -- — pressing an already-unlocked control TOGGLES
                    -- between move/rotate each press, same as the element
                    -- branch above (see its comment).
                    canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                    if not canvas.rotateModeActive then
                        canvas.dragKind = "controlRotate"
                        canvas.rotateModeActive = true
                        local cx, cy = _toPixel(canvas, hitCtrl.x, hitCtrl.y)
                        canvas.rotateGrabAngleOffset = math.atan2(y - cy, x - cx) - math.rad(hitCtrl.rotation or 0)
                    else
                        canvas.dragKind = "control"
                        canvas.rotateModeActive = false
                        local cx, cy = _toPixel(canvas, hitCtrl.x, hitCtrl.y)
                        canvas.dragOffsetX = x - cx
                        canvas.dragOffsetY = y - cy
                    end
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
                    if not isActiveMoveTarget then
                        canvas.selectionMoveModeActive = false
                        canvas.rotateModeActive = false
                    end
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
                    canvas.rotateModeActive = false
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

-- Auto-pans the canvas, every frame, while an element MOVE or a reshape-
-- handle drag is held with the finger/cursor near the edge of the visible
-- canvas rect -- same purpose a file manager's drag-to-the-edge autoscroll
-- or a drawing app's canvas edge-pan serves: without it, relocating an
-- element to (or reshaping a tank's corner out past) whatever happens to be
-- in view right now is simply impossible, since the rest of the diagram the
-- user would drag it onto is scrolled off-screen with no way to reach it
-- mid-drag. One shared namespace, called from gdsGui_schematic_update for
-- every canvas in globApp.objects.schematics regardless of which system
-- (ELECTRICAL/HYDRAULIC/FUEL/PRESSURIZATION/...) it belongs to -- there is
-- only the one canvas type and the one update loop, so this is already
-- global across every system by construction, not something each needs its
-- own copy of. Global, not local (same reason _shapePoly/_propertyGrid
-- elsewhere in this file are): this file is already at its 200-local-per-
-- chunk ceiling, and a global table doesn't count against that.
_edgePan = {}
_edgePan.MARGIN_PX = 36    -- how close to the canvas edge (screen px) triggers panning
_edgePan.SPEED_PX_S = 420  -- pan speed (screen px/sec) at the very edge, ramping from 0 at the margin's outer boundary

-- The whole-element MOVE drag's own "follow the touch" step: snaps (x,y) to
-- the grid, then either applies it or leaves elem where it was if that would
-- overlap another element -- factored out of gdsGui_schematic_moved's own
-- "element" dragKind branch below so _edgePan.update (further down) can
-- re-run the exact same step on every frame the drag is held near the
-- canvas edge, not just on an actual touchmoved/mousemoved event.
function _edgePan.applyElementDragPosition(canvas, elem, x, y)
    local fracX, fracY = _toFraction(canvas, x - canvas.dragOffsetX, y - canvas.dragOffsetY)
    local candX, candY = _snapElementToGrid(canvas, fracX, fracY, elem.w, elem.h)
    -- Elements (unlike wires — see _footprintOverlapsAnother's own comment)
    -- can never overlap: simply don't apply the candidate position at all
    -- when it would, so the element just stops following the finger right
    -- at the obstacle's edge instead of passing through it.
    local px, py = _toPixel(canvas, candX, candY)
    local pw, ph = elem.w * canvas.contentW * canvas.zoom, elem.h * canvas.contentH * canvas.zoom
    if _isQuarterTurnRotation(elem.rotation) then pw, ph = ph, pw end
    local blocked, obstacle
    if elem.shapePoints then
        local p = _shapePoly.parse(elem.shapePoints)
        local bw, bh = elem.w * canvas.contentW * canvas.zoom, elem.h * canvas.contentH * canvas.zoom
        blocked, obstacle = _shapePoly.blockedAt(canvas, elem, p, px + bw / 2, py + bh / 2,
            bw / p.cols, bh / p.rows, elem.rotation)
    else
        blocked, obstacle = _footprintOverlapsAnother(canvas, px + pw / 2, py + ph / 2, pw / 2, ph / 2, elem.id)
    end
    -- Flags the obstacle actually in the way so _drawElement/_drawControl can
    -- highlight it red for as long as the drag keeps pushing into it --
    -- cleared the instant it's clear again (nil obstacle) or the gesture
    -- ends (gdsGui_schematic_released's own cleanup).
    canvas.collidingObstacleId = obstacle and obstacle.id or nil
    if not blocked then
        elem.x, elem.y = candX, candY
    end
end

function _edgePan.update(canvas, dt)
    if canvas.dragKind ~= "element" and canvas.dragKind ~= "reshape" then return end
    if canvas.pinch and canvas.pinch.active then return end
    local touch = canvas.focusTouchId and canvas.touches[canvas.focusTouchId]
    if not touch then return end
    local x, y = touch.x, touch.y

    -- Nested (not a sibling top-level local) for the same 200-local-per-
    -- chunk reason _edgePan itself is one table rather than several locals
    -- -- a local inside a function body doesn't count against that budget.
    local function intensity(dist)
        return math.max(0, math.min(1, (_edgePan.MARGIN_PX - dist) / _edgePan.MARGIN_PX))
    end
    local dPanX = intensity(x - canvas.x) * _edgePan.SPEED_PX_S * dt
        - intensity(canvas.x + canvas.w - x) * _edgePan.SPEED_PX_S * dt
    local dPanY = intensity(y - canvas.y) * _edgePan.SPEED_PX_S * dt
        - intensity(canvas.y + canvas.h - y) * _edgePan.SPEED_PX_S * dt
    if dPanX == 0 and dPanY == 0 then return end

    local prevPanX, prevPanY = canvas.panX, canvas.panY
    canvas.panX = canvas.panX + dPanX
    canvas.panY = canvas.panY + dPanY
    _clampPan(canvas)
    -- What actually took effect, which can fall short of the requested dPanX/Y
    -- once _clampPan has pinned the view against the content's own edge.
    local appliedDX, appliedDY = canvas.panX - prevPanX, canvas.panY - prevPanY

    -- A reshape drag's own corner math (_shapePoly.updateDrag) measures how
    -- far the cursor has moved from canvas.dragStartX/Y in raw SCREEN
    -- pixels -- correct as long as the pan stays put, but the pan itself
    -- just moved the WORLD under a cursor that hasn't physically moved at
    -- all, which that measurement has no way to see. Shifting dragStartX/Y
    -- by the same applied amount keeps it meaning "moved this far in WORLD
    -- terms", so the corner stays glued to the cursor through the pan
    -- instead of visibly drifting off it. A plain element MOVE doesn't need
    -- this -- _applyElementDragPosition re-reads panX/Y fresh every call via
    -- _toFraction, so it already tracks correctly without it -- but shifting
    -- it unconditionally here is still harmless for that case too, since the
    -- only other thing dragStartX/Y feeds for an "element" drag is the
    -- already-long-past tap-vs-drag slop check.
    canvas.dragStartX = canvas.dragStartX + appliedDX
    canvas.dragStartY = canvas.dragStartY + appliedDY

    -- The finger/cursor itself hasn't moved (that's exactly why this is
    -- driven from the per-frame update loop rather than a touchmoved event),
    -- but the world just slid out from under it -- re-run the same "follow
    -- the touch" step the drag's own moved-event branch uses, against the
    -- SAME screen position but the NEW pan, so the dragged element/handle
    -- stays glued to the finger through the newly revealed area instead of
    -- visually lagging behind while the canvas pans past it.
    if canvas.dragKind == "element" and canvas.selectedElementId then
        local elem = _findElement(canvas, canvas.selectedElementId)
        if elem then _edgePan.applyElementDragPosition(canvas, elem, x, y) end
    elseif canvas.dragKind == "reshape" and canvas.selectedElementId then
        local elem = _findElement(canvas, canvas.selectedElementId)
        if elem and canvas._shapeDrag then _shapePoly.updateDrag(canvas, elem, x, y) end
    end
end

function gdsGui_schematic_moved(touchId, x, y)
    local activePageName = _getActivePageName()
    -- For a "directionalGate" element (DIODE) being rotated
    -- below: which cardinal AXIS ("h" or "v") its own connected wires
    -- predominantly run along, by summing each connected neighbor's own
    -- |dx|/|dy| offset from the element's center across every wire
    -- touching it — nil when it has no wires at all (nothing to sense
    -- yet; the rotate-drag branch below falls back to every cardinal
    -- direction in that case, same as any other rotatable element). Lets
    -- that branch restrict itself to just the 2 rotations that keep the
    -- diode's own conducting axis lined up with how it's ACTUALLY wired —
    -- only 2 of the 4 cardinal rotations could ever make physical sense
    -- once it's wired to something; the other 2 would point its
    -- conducting direction crosswise to both its own leads. Nested (not a
    -- top-level local, which this file's handlers otherwise all are)
    -- purely to stay under this file's 200-local ceiling — both of these
    -- have exactly one caller, below.
    local function directionalGateWireAxis(canvas, elem)
        local cx, cy = _anchorCenter(canvas, elem)
        local sumAbsDx, sumAbsDy, count = 0, 0, 0
        for _, w in ipairs(canvas.wires) do
            local otherId
            if w.fromElementId == elem.id then otherId = w.toElementId
            elseif w.toElementId == elem.id then otherId = w.fromElementId end
            if otherId then
                local other = _findAnchor(canvas, otherId)
                if other then
                    local ox, oy = _anchorCenter(canvas, other)
                    sumAbsDx = sumAbsDx + math.abs(ox - cx)
                    sumAbsDy = sumAbsDy + math.abs(oy - cy)
                    count = count + 1
                end
            end
        end
        if count == 0 then return nil end
        return (sumAbsDy > sumAbsDx) and "v" or "h"
    end

    -- Same job as _snapRotationDegrees above, but restricted to just the
    -- 2 cardinal rotations axis allows ("v" -> 90/270, "h" -> 0/180) —
    -- picks whichever of those 2 the raw drag angle is actually closer
    -- to, so the gesture still tracks the finger/cursor naturally, it
    -- just can never land on the other axis's pair.
    local function snapRotationDegreesToAxis(angleRad, axis)
        local candidates = (axis == "v") and {90, 270} or {0, 180}
        local twoPi = math.pi * 2
        local a = angleRad % twoPi
        if a < 0 then a = a + twoPi end
        local bestDeg, bestDiff
        for _, deg in ipairs(candidates) do
            local diff = math.abs(a - math.rad(deg))
            diff = math.min(diff, twoPi - diff)
            if not bestDiff or diff < bestDiff then bestDiff, bestDeg = diff, deg end
        end
        return bestDeg
    end

    for _, canvas in ipairs(globApp.objects.schematics) do
        -- Without this, a finger still down when the user navigates away
        -- (e.g. via a footer nav button while mid-drag) keeps applying
        -- pan/drag/pinch math to a canvas the user can no longer see,
        -- silently moving its contents until the finger finally lifts.
        -- gdsGui_schematic_pressed/_draw already gate on this; this and
        -- _released below didn't.
        if canvas.page ~= activePageName then goto continue end
        if canvas.menu then
            if canvas.menu.choiceGrid then _choiceGrid.move(canvas, touchId, x, y) end
            if canvas.menu.propertyGrid then _propertyGrid.move(canvas, touchId, x, y) end
            goto continue
        end
        if canvas.annunciatorPanelOpen then
            _handleAnnunciatorPanelMove(canvas, touchId, x, y)
            goto continue
        end
        -- Drag-to-scroll forwarding for the dead zone a press started
        -- inside (see gdsGui_schematic_pressed's own inputBlockRect
        -- branch) — a raw pixel delta, unlike the wheel path's notch
        -- count; the app's own callback decides how to scale it.
        if canvas.inputBlockTouchId == touchId then
            if canvas.inputBlockWheelCallback then
                local fn = _G[canvas.inputBlockWheelCallback]
                if fn then fn(canvas.inputBlockTouchY - y, true) end
            end
            canvas.inputBlockTouchY = y
            goto continue
        end

        if canvas.touches[touchId] then
            canvas.touches[touchId].x = x
            canvas.touches[touchId].y = y
        end

        if canvas.pinch and canvas.pinch.active then
            _updatePinch(canvas)
            goto continue
        end

        if canvas.focusTouchId ~= touchId then goto continue end

        if canvas.dragKind == "pathPoint" and canvas.pathEdit then
            _wirePath.move(canvas, x, y)
        elseif canvas.wireTool.fromId then
            canvas.wireTool.curX = x
            canvas.wireTool.curY = y
            -- A tick each time the loose end locks onto a new element or
            -- port, as the drag preview does (see _connectorSnapTarget).
            local snapTarget, snapTerminal = _connectorSnapTarget(canvas)
            local snapKey = snapTarget and (snapTarget.id .. "#" .. tostring(snapTerminal)) or nil
            if snapKey ~= canvas.wireTool.snapKey then
                canvas.wireTool.snapKey = snapKey
                if snapKey then gdsGui_haptics_feedback("selection") end
            end
        elseif canvas.dragKind == "paint" then
            -- Moved too far to count as a tap — cancels the pending paint
            -- outright (gdsGui_schematic_released below only applies it when
            -- dragMoved is still false), same slop-triggered cancel as
            -- "pendingLongPress" just below, with no drag/move side effect
            -- of its own either.
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
            end
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
        elseif canvas.dragKind == "controlTap" then
            -- Same tap-vs-drag slop cancel as "pendingLongPress" above —
            -- dragging off a control cancels its position menu instead of
            -- opening it on release.
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
            end
        elseif canvas.dragKind == "elementTap" then
            -- Same tap-vs-drag slop cancel as "controlTap" above.
            if not canvas.dragMoved and
               (math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX) then
                canvas.dragMoved = true
            end
        elseif canvas.dragKind == "reshape" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem and canvas._shapeDrag and _shapePoly.updateDrag(canvas, elem, x, y) and not canvas.dragMoved then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "element" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem then _edgePan.applyElementDragPosition(canvas, elem, x, y) end
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
            if elem and _shapePoly.allowed(canvas, elem) then
                -- Any angle, not just the 4 cardinals — which also means a
                -- tap's own finger jitter would turn it, so nothing applies
                -- until the press has become a real drag. Off-cardinal angles
                -- rely on the polygon hit/collision/wire paths, so its
                -- shape is made explicit here (it looks the same either way).
                if canvas.dragMoved or math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                   math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX then
                    local cx, cy = _elementCenter(canvas, elem)
                    local rawAngle = math.atan2(y - cy, x - cx) - canvas.rotateGrabAngleOffset
                    local candRotation = _shapePoly.freeRotationDegrees(rawAngle)
                    elem.shapePoints = _shapePoly.pointsOf(canvas, elem)
                    local _, _, cw, ch, p = _shapePoly.frame(canvas, elem)
                    if not _shapePoly.blockedAt(canvas, elem, p, cx, cy, cw, ch, candRotation) then
                        elem.rotation = candRotation
                    end
                end
            elseif elem then
                local cx, cy = _elementCenter(canvas, elem)
                local rawAngle = math.atan2(y - cy, x - cx) - canvas.rotateGrabAngleOffset
                local axis = elem.componentType == "directionalGate" and directionalGateWireAxis(canvas, elem)
                local candRotation = axis and snapRotationDegreesToAxis(rawAngle, axis) or _snapRotationDegrees(rawAngle)
                -- Rotating a non-square element (gridW ~= gridH) can swap its
                -- own footprint into/out of overlapping a neighbor it never
                -- touched before — same "just don't apply it" guard the
                -- move-drag above uses (see _footprintOverlapsAnother), so a
                -- quarter-turn that would collide simply doesn't take.
                local pw, ph = elem.w * canvas.contentW * canvas.zoom, elem.h * canvas.contentH * canvas.zoom
                if _isQuarterTurnRotation(candRotation) then pw, ph = ph, pw end
                if not _footprintOverlapsAnother(canvas, cx, cy, pw / 2, ph / 2, elem.id) then
                    if elem.rotation ~= candRotation then gdsGui_haptics_feedback("selection") end
                    elem.rotation = candRotation
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
                local candX, candY = _snapToGrid(canvas, fracX, fracY)
                -- Same "just stop at the obstacle" treatment as the
                -- element drag above — see _footprintOverlapsAnother.
                local px, py = _toPixel(canvas, candX, candY)
                local rad = canvas.controlRadius * canvas.zoom * (ctrl.radiusScale or 1)
                local blocked, obstacle = _footprintOverlapsAnother(canvas, px, py, rad, rad, ctrl.id)
                -- Same obstacle-highlight flag as the element drag above.
                canvas.collidingObstacleId = obstacle and obstacle.id or nil
                if not blocked then
                    ctrl.x, ctrl.y = candX, candY
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
        elseif canvas.dragKind == "controlRotate" and canvas.selectedControlId then
            local ctrl = _findControl(canvas, canvas.selectedControlId)
            if ctrl then
                local cx, cy = _toPixel(canvas, ctrl.x, ctrl.y)
                local rawAngle = math.atan2(y - cy, x - cx) - canvas.rotateGrabAngleOffset
                local snapped = _snapRotationDegrees(rawAngle)
                if ctrl.rotation ~= snapped then gdsGui_haptics_feedback("selection") end
                ctrl.rotation = snapped
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
            local oldPanX, oldPanY = canvas.panX, canvas.panY
            canvas.panX = canvas.panStartX + (x - canvas.dragStartX)
            canvas.panY = canvas.panStartY + (y - canvas.dragStartY)
            _clampPan(canvas)
            -- Instantaneous this-event velocity, blended 50/50 with the
            -- running value — same smoothing outputTxtBox_gdsGuiLib.lua's
            -- own drag-velocity tracking uses — so gdsGui_schematic_released
            -- has something to coast with once the finger lifts (see
            -- gdsGui_schematic_update's own coast step).
            local frameDt = globApp.lastDt or 0
            if frameDt > 0 then
                canvas.panVelX = canvas.panVelX * 0.5 + ((canvas.panX - oldPanX) / frameDt) * 0.5
                canvas.panVelY = canvas.panVelY * 0.5 + ((canvas.panY - oldPanY) / frameDt) * 0.5
            end
        end

        ::continue::
    end
end

-- Set while the "add a new connector will delete all snapshots" confirm
-- menu is open after a wire-drag release lands on a valid target anchor;
-- holds everything gdsGui_schematic_internal_onWireCreateConfirmed needs to
-- actually create the wire if the user confirms. Only one wire-drag can be
-- in flight at a time, same shape as _pendingNamedPlacement above.
local _pendingWireCreation = nil

-- Shared onSelect/onCancel for the snapshot-wipe confirm menu above: both
-- CONTINUE and CANCEL land here (distinguished by optionText), as does
-- tapping outside (optionText is nil — treated the same as CANCEL, i.e. the
-- connector is simply never created).
function gdsGui_schematic_internal_onWireCreateConfirmed(canvasName, index, optionText)
    local pending = _pendingWireCreation
    _pendingWireCreation = nil
    if not pending or pending.canvasName ~= canvasName then return end
    if optionText == "CONTINUE" then
        local canvas = _findCanvas(canvasName)
        if not canvas then return end
        local baseId = pending.fromId .. "_to_" .. pending.toId
        gdsGui_schematic_addWire(canvasName, _uniqueWireId(canvas, baseId),
            pending.fromId, pending.toId, pending.color, nil, pending.fromTerminal, pending.toTerminal)
        canvas.snapshots = {}
        _notifyChanged(canvas)
    end
end

-- Purely dismisses the "2-terminal device already has its max 2 wires"
-- notice (see gdsGui_schematic_released's twoTerminalAnchorAtWireLimit
-- check) — the connector itself was never created, so there's nothing
-- left to do.
function gdsGui_schematic_internal_onTwoTerminalWireLimitDismissed()
end

-- Purely dismisses the "can't place here, overlaps another element"
-- notice (see gdsGui_schematic_pressed's pendingPlacement branch) — the
-- placement was never created, so there's nothing left to do.
function gdsGui_schematic_internal_onPlacementOverlapDismissed()
end

-- A press that lands on empty canvas space while a catalog placement is
-- armed (canvas.pendingPlacement) synchronously opens the "NAME THIS
-- ELEMENT/CONTROL" textPrompt right there inside gdsGui_schematic_pressed —
-- see that function's pendingPlacement branch. That same press already
-- tracked this finger in canvas.touches (every finger down inside the
-- canvas is tracked up front, regardless of what it lands on, so a second
-- one can be recognized as a pinch). But gdsGui_general_touchreleased/
-- _mousereleased special-case an open textPrompt/choiceMenu by routing the
-- matching release ENTIRELY to that modal instead of to
-- gdsGui_schematic_released below — which is the only place that ever
-- clears canvas.touches[touchId]. Left uncleared, that entry is a
-- permanent ghost finger: the next real single-touch tap on this canvas
-- makes _touchCount(canvas.touches) read 2, so gdsGui_schematic_pressed
-- mistakes it for the START of a two-finger pinch instead of a normal
-- select/drag — and sliding that one real finger past the stationary
-- ghost continuously changes the measured pinch distance, i.e. "zoom"
-- with only one finger down. Called by both general_gdsGuiLib handlers
-- right before they hand a release off to textPrompt/choiceMenu, so this
-- bookkeeping runs no matter which modal ends up owning the release.
function gdsGui_schematic_clearTouch(touchId)
    local activePageName = _getActivePageName()
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page ~= activePageName then goto continue end
        canvas.touches[touchId] = nil
        _endPinchIfBelowTwo(canvas)
        ::continue::
    end
end

function gdsGui_schematic_released(touchId, x, y)
    local activePageName = _getActivePageName()
    -- Non-nil if anchorId is a simple 2-terminal device -- a gate-role
    -- control with exactly 2 positions (OFF/ON, CLOSED/OPEN, ..., the
    -- "two-way switch" case) OR a directionalGate-role element (DIODE
    -- -- the same 2-lead "anode in, cathode out" component
    -- model/graph.lua's own _resolveDirectionalEdges assumes throughout)
    -- -- and it ALREADY has 2 wires touching it, the physical maximum
    -- either kind of 2-terminal device can ever actually have wired to
    -- it. A 3-position switch (numDetents ~= 2), any other control role
    -- (e.g. GENERATOR, "source" -- a real output terminal can
    -- legitimately feed more than one bus), or any other element role
    -- isn't limited here at all. A control with its own terminals list
    -- (a DPST's 4 lugs -- see gdsGui_schematic_addControl) is capped at
    -- one wire per terminal instead: that exact terminal already taken
    -- is what blocks. Returns the notice to show, or nil when not at the
    -- limit. Nested (not a top-level local, which
    -- this file's handlers otherwise all are) purely to stay under this
    -- file's 200-local ceiling -- it has exactly one caller, below.
    local function twoTerminalAnchorAtWireLimit(canvas, anchorId, terminalIndex)
        local ctrl = _findControl(canvas, anchorId)
        local elem = not ctrl and _findElement(canvas, anchorId)
        if (ctrl and ctrl.terminals) or (elem and elem.terminals) then
            for _, w in ipairs(canvas.wires) do
                if (w.fromElementId == anchorId and w.fromTerminal == terminalIndex)
                   or (w.toElementId == anchorId and w.toTerminal == terminalIndex) then
                    return "THAT TERMINAL ALREADY HAS A " .. _pipes.noun(canvas) .. "."
                end
            end
            return nil
        end
        local isTwoTerminal = (ctrl and ctrl.componentType == "gate" and ctrl.numDetents == 2)
            or (elem and elem.componentType == "directionalGate")
        if not isTwoTerminal then return nil end
        local count = 0
        for _, w in ipairs(canvas.wires) do
            if w.fromElementId == anchorId or w.toElementId == anchorId then count = count + 1 end
        end
        if count >= 2 then return "A 2-POSITION SWITCH OR DIODE CAN HAVE AT MOST 2 " .. _pipes.noun(canvas) .. "S." end
        return nil
    end

    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page ~= activePageName then goto continue end
        canvas.touches[touchId] = nil
        _endPinchIfBelowTwo(canvas)

        if canvas.inputBlockTouchId == touchId then
            canvas.inputBlockTouchId = nil
            goto continue
        end

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
                canvas.collidingObstacleId = nil
                canvas._pendingDragUndoSnapshot = nil
            end
            if canvas.menu.choiceGrid then
                _choiceGrid.release(canvas, touchId, x, y)
            elseif canvas.menu.propertyGrid then
                _propertyGrid.release(canvas, touchId, x, y)
            else
                _handleMenuRelease(canvas, touchId, x, y)
            end
            goto continue
        end
        if canvas.annunciatorPanelOpen then
            _handleAnnunciatorPanelRelease(canvas, touchId, x, y)
            goto continue
        end
        if canvas.focusTouchId == touchId then
            if canvas.dragKind == "pathPoint" and canvas.pathEdit then
                _wirePath.release(canvas)
            elseif canvas.dragKind == "paint" then
                -- Only a clean tap (never crossed the slop threshold —
                -- gdsGui_schematic_moved) actually paints; a tap that turned
                -- into a drag/pan gesture applies nothing, matching every
                -- other tap-vs-drag gesture in this file.
                if not canvas.dragMoved and canvas.paintMode and canvas.paintMode.color and canvas._paintTarget then
                    _applyPaint(canvas, canvas._paintTarget.kind, canvas._paintTarget.id, canvas.paintMode.color)
                end
                canvas._paintTarget = nil
            elseif canvas.wireTool.fromId then
                local toElem, toTerminal = _connectorSnapTarget(canvas)
                local fromElem = toElem and _findAnchor(canvas, canvas.wireTool.fromId)
                local fromTerminal = canvas.wireTool.fromTerminal
                if fromElem and not fromTerminal then
                    -- Not picked at press (see gdsGui_schematic_pressed's
                    -- pendingWireFromId branch): the terminal nearest where
                    -- the wire actually lands, same as the drag preview.
                    local ox, oy = _terminals.wireEnd(canvas, toElem, toTerminal)
                    fromTerminal = _terminals.nearest(canvas, fromElem, ox, oy)
                end
                canvas.wireTool.fromTerminal = nil
                canvas.wireTool.snapKey = nil
                -- A port picked by pendingWirePortPick and then only tapped:
                -- stay armed from that port, so the next drag can start
                -- anywhere and still leave from it. A drag that ends on
                -- nothing disarms instead, as does the next drag if it misses
                -- too, the same way a tap off every port cancels the pick.
                local tw = canvas.wireTool
                if tw.portPicked == "pick" and not toElem and tw.pressX
                   and math.abs(x - tw.pressX) <= _ELEMENT_TAP_SLOP_PX
                   and math.abs(y - tw.pressY) <= _ELEMENT_TAP_SLOP_PX then
                    canvas.pendingWireFromId = tw.fromId
                    canvas.pendingWireFromTerminal = fromTerminal
                end
                tw.portPicked, tw.pressX, tw.pressY = nil, nil, nil
                local limitNotice = toElem and (twoTerminalAnchorAtWireLimit(canvas, canvas.wireTool.fromId, fromTerminal)
                    or twoTerminalAnchorAtWireLimit(canvas, toElem.id, toTerminal))
                if toElem then
                    if limitNotice then
                        gdsGui_haptics_feedback("error")
                        gdsGui_schematic_openMenu(canvas.name, limitNotice, {"OK"},
                            "gdsGui_schematic_internal_onTwoTerminalWireLimitDismissed", nil)
                    else
                        -- wireTool.color: an explicit per-gesture override (set
                        -- only by a still-armed gdsGui_schematic_armConnectorPlacement
                        -- color, nil for ADD WIRE). defaultConnectorColor: the
                        -- per-canvas fallback ADD WIRE actually relies on — see
                        -- gdsGui_schematic_setDefaultConnectorColor.
                        local pendingColor = canvas.wireTool.color or canvas.defaultConnectorColor or _DEFAULT_COLOR
                        -- A new connector wipes every existing snapshot (same as
                        -- a new element/control — see _commitNamedPlacement)
                        -- — worth an explicit "are you sure" only when there's
                        -- actually something to lose.
                        local snapshotCount = gdsGui_schematic_countSnapshots(canvas.name)
                        if snapshotCount > 0 then
                            _pendingWireCreation = {
                                canvasName = canvas.name, fromId = canvas.wireTool.fromId,
                                toId = toElem.id, color = pendingColor,
                                fromTerminal = fromTerminal, toTerminal = toTerminal,
                            }
                            gdsGui_schematic_openMenu(canvas.name,
                                "ADDING A NEW CONNECTOR WILL DELETE ALL " .. snapshotCount .. " SNAPSHOT(S). CONTINUE?",
                                {"CONTINUE", "CANCEL"},
                                "gdsGui_schematic_internal_onWireCreateConfirmed",
                                "gdsGui_schematic_internal_onWireCreateConfirmed", 1)
                        else
                            local baseId = canvas.wireTool.fromId .. "_to_" .. toElem.id
                            gdsGui_schematic_addWire(canvas.name, _uniqueWireId(canvas, baseId),
                                canvas.wireTool.fromId, toElem.id, pendingColor, nil, fromTerminal, toTerminal)
                            gdsGui_haptics_feedback("medium")
                            canvas.snapshots = {}
                            _notifyChanged(canvas)
                        end
                    end
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
            elseif canvas.mode == "control" and canvas.dragKind == "controlTap" and not canvas.dragMoved then
                -- A clean tap (or hold — there's no timing distinction any
                -- more) on a control: show its own positions as an
                -- iOS-styled menu instead of cycling it one step at a time.
                gdsGui_schematic_openControlPositionMenu(canvas.name, canvas._controlTapId)
            elseif canvas.mode == "control" and canvas.dragKind == "elementTap" and not canvas.dragMoved then
                -- A clean tap on a plain element -- only opens anything if
                -- the app layer actually has a quick view for it (a fluid
                -- tank's quantity, say); nothing otherwise, same as today.
                gdsGui_schematic_openElementControlRows(canvas.name, canvas._elementTapId)
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
                -- A plain tap (no drag) once move mode is already unlocked
                -- (including the very tap that JUST unlocked it via the
                -- 2-second hold, see gdsGui_schematic_update) no longer
                -- opens the edit menu — it stays selected in move mode,
                -- showing the 4-arrow overlay (_drawMoveModeOverlay),
                -- ready for either an actual drag (moves it) or another
                -- tap (see the "rotate" branch below, which is what a
                -- repeat tap on a rotatable element resolves to).
                canvas.rotateModeActive = false
            elseif canvas.mode == "design" and canvas.dragKind == "rotate" and
                   canvas.selectedElementId and not canvas.dragMoved then
                -- A plain tap here means the user pressed again on an
                -- already-move-unlocked rotatable element (gdsGui_schematic_
                -- pressed's isActiveMoveTarget branch is what resolves a
                -- fresh press straight to "rotate") without dragging —
                -- switches the overlay from the 4-arrow move hint to the
                -- ring-arrow rotate hint (_drawRotateModeOverlay) instead of
                -- opening the edit menu.
                canvas.rotateModeActive = true
            elseif canvas.mode == "design" and canvas.dragKind == "wire" and
                   canvas.selectedWireId and not canvas.dragMoved then
                -- Same tap-to-edit gesture as an element, applied to a wire.
                gdsGui_schematic_openWireEditMenu(canvas.name, canvas.selectedWireId)
            elseif canvas.mode == "design" and canvas.dragKind == "wireDirection" and
                   canvas.selectedWireId and not canvas.dragMoved then
                -- Rebending/direction mode is already unlocked on this wire
                -- (see gdsGui_schematic_pressed's isActiveMoveTarget branch)
                -- and this tap never actually dragged a new bend direction.
                -- For a LIQUID pipe (_pipes.isLiquid — HYDRAULIC/FUEL, not a
                -- gas DUCT), that plain tap cycles its gravity-flow direction
                -- instead of reopening the edit menu (see
                -- _pipes.cycleGravityDirection) — quick and repeatable, same
                -- spirit as the direction-drag itself. Every other wire
                -- keeps the previous tap-to-edit behavior.
                local w = _pipes.isLiquid(canvas) and _findWire(canvas, canvas.selectedWireId)
                if w then
                    _pushUndo(canvas)
                    _pipes.cycleGravityDirection(w)
                    _notifyChanged(canvas)
                else
                    gdsGui_schematic_openWireEditMenu(canvas.name, canvas.selectedWireId)
                end
            elseif canvas.mode == "design" and canvas.dragKind == "control" and
                   canvas.selectedControlId and not canvas.dragMoved then
                -- Same no-menu move-mode tap as an element above (every
                -- control is rotatable, so this is only ever the tap that
                -- just unlocked move mode itself — a repeat tap on an
                -- already-active control always resolves straight to
                -- "controlRotate" below instead).
                canvas.rotateModeActive = false
            elseif canvas.mode == "design" and canvas.dragKind == "controlRotate" and
                   canvas.selectedControlId and not canvas.dragMoved then
                -- Same move->rotate overlay switch as an element's "rotate"
                -- branch above, instead of opening the edit menu.
                canvas.rotateModeActive = true
            elseif canvas.dragKind == "pan" and canvas.paintMode and not canvas.dragMoved then
                -- PAINT MODE's own press handler only ever starts a "pan"
                -- here on a genuine miss — every element/wire/control (and
                -- the swatch palette itself) resolves to dragKind == "paint"
                -- instead (see gdsGui_schematic_pressed's own paintMode
                -- branch) — so reaching this with dragMoved still false
                -- means a clean tap landed on empty canvas space with
                -- nothing painted. Same "it's just quietly treated as a pan
                -- start" miss every other mode gives an empty tap, except
                -- here it also disarms the brush — same convention the
                -- PAINT dock button's own gdsGui_schematic_disarmPaintMode
                -- uses, just reached by tapping away instead of the button.
                -- An actual pan/pinch (dragMoved true) leaves it armed.
                canvas.paintMode = nil
            end
            -- An actual drag (element/rotate/control/controlRotate moved,
            -- not just tapped) settled at its final position/angle here —
            -- persist it now rather than waiting for the next page-nav
            -- save point.
            if canvas.mode == "design" and canvas.dragMoved and
               (canvas.dragKind == "element" or canvas.dragKind == "rotate" or
                canvas.dragKind == "control" or canvas.dragKind == "wireDirection" or
                canvas.dragKind == "controlRotate" or canvas.dragKind == "reshape") then
                _notifyChanged(canvas)
            end
            -- A side tapped rather than dragged counts as a tap on the body,
            -- which is all that's left of a tank small on screen once its
            -- sides' reach covers it (see gdsGui_schematic_pressed's cycle).
            if canvas.dragKind == "reshape" and canvas._shapeDrag and canvas._shapeDrag.isSide and not canvas.dragMoved then
                canvas.reshapeModeActive = false
            end
            -- Finger lifted off an actual pan drag with enough carried
            -- velocity -- coast (gdsGui_schematic_update), rather than
            -- stopping dead. 8.0 px/s, same COAST_STOP_VEL threshold
            -- outputTxtBox_gdsGuiLib.lua's own scroll coast uses.
            if canvas.dragKind == "pan" and
               (math.abs(canvas.panVelX) > 8.0 or math.abs(canvas.panVelY) > 8.0) then
                canvas._panCoasting = true
            else
                canvas.panVelX, canvas.panVelY, canvas._panCoasting = 0, 0, false
            end
            canvas.focusTouchId       = nil
            canvas.dragKind           = nil
            canvas._shapeDrag         = nil
            canvas.wireTool.fromId    = nil
            -- Gesture's over either way (applied or blocked) — nothing left
            -- to flag red (see gdsGui_schematic_moved's "element"/"control"
            -- dragKind branches).
            canvas.collidingObstacleId = nil
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
        if canvas.page == activePageName and canvas.mode == "control" then
            canvas._overlayAnimAngle = (canvas._overlayAnimAngle or 0) + dt * _OVERLAY_SPIN_RADPS
        end
        if canvas.page ~= activePageName then goto continue end
        _pollMenuHoldToConfirm(canvas, dt)
        _edgePan.update(canvas, dt)

        -- Post-release pan coast (see gdsGui_schematic_moved's velocity
        -- tracking and gdsGui_schematic_released's seeding of this flag) --
        -- same friction-decay formula outputTxtBox_gdsGuiLib.lua's own
        -- scroll coast uses (SCROLL_FRICTION = 3.5), just reusing the
        -- canvas's existing rigid _clampPan every frame instead of a
        -- rubber-band+spring boundary (pan/zoom have no overshoot model
        -- here, unlike those scroll widgets). A fresh "pan" drag pauses
        -- this for free (the dragKind guard below), and a pinch in
        -- progress is excluded since it drives panX/Y itself.
        if canvas._panCoasting and canvas.dragKind ~= "pan" and not (canvas.pinch and canvas.pinch.active) then
            canvas.panVelX = canvas.panVelX * math.exp(-3.5 * dt)
            canvas.panVelY = canvas.panVelY * math.exp(-3.5 * dt)
            canvas.panX = canvas.panX + canvas.panVelX * dt
            canvas.panY = canvas.panY + canvas.panVelY * dt
            _clampPan(canvas)
            if math.abs(canvas.panVelX) < 8.0 and math.abs(canvas.panVelY) < 8.0 then
                canvas._panCoasting = false
            end
        end

        -- A stationary held touch on an annunciator-panel row generates no
        -- touchmoved event either, so this poll is what notices the hold has
        -- crossed _LONG_PRESS_SECONDS and opens that row's edit menu — same
        -- "polled every frame" reason as the on-canvas pendingLongPress
        -- handling below, just independent of it since a panel row has no
        -- dragKind/move-mode of its own.
        if canvas.annunciatorPanelOpen and canvas._annunciatorPanelTouchId ~= nil
           and not canvas._annunciatorPanelMoved
           and type(canvas._annunciatorPanelPressedHit) == "number" then
            canvas._annunciatorPanelLongPressElapsed = (canvas._annunciatorPanelLongPressElapsed or 0) + dt
            if canvas._annunciatorPanelLongPressElapsed >= _LONG_PRESS_SECONDS then
                local list = _sortedAnnunciators(canvas)
                local a = list[canvas._annunciatorPanelPressedHit]
                canvas._annunciatorPanelTouchId    = nil
                canvas._annunciatorPanelPressedHit = nil
                canvas._annunciatorPanelLongPressElapsed = 0
                if a then
                    gdsGui_haptics_feedback("medium")
                    gdsGui_schematic_openAnnunciatorEditMenu(canvas.name, a.id)
                end
            end
        else
            canvas._annunciatorPanelLongPressElapsed = 0
        end

        if canvas.dragKind ~= "pendingLongPress" then goto continue end
        -- The touch already lifted (gdsGui_schematic_released clears
        -- dragKind on release, so this is only a same-frame-ordering
        -- safety net) or wandered past tap slop (gdsGui_schematic_moved
        -- already marked it as such) — neither should unlock move/rotate
        -- mode.
        if not canvas.focusTouchId or canvas.dragMoved then goto continue end

        canvas.longPressElapsed = (canvas.longPressElapsed or 0) + dt

        local holdElem = canvas.longPressTargetKind == "element" and canvas.selectedElementId
            and _findElement(canvas, canvas.selectedElementId)
        local holdSeconds = (holdElem and _shapePoly.allowed(canvas, holdElem)) and _shapePoly.HOLD_SECONDS or _LONG_PRESS_SECONDS
        if canvas.longPressElapsed < holdSeconds then goto continue end

        -- Held long enough — unlock move/rotate mode for whatever's
        -- currently selected, and seamlessly promote this SAME still-held
        -- touch straight into dragging/rotating it (reusing the exact
        -- grab-offset/angle setup gdsGui_schematic_pressed uses for an
        -- already-unlocked target), so the user doesn't have to lift and
        -- press again.
        canvas.selectionMoveModeActive = true
        canvas.rotateModeActive = false
        canvas.reshapeModeActive = false
        canvas._liftStartedAt = love.timer.getTime()
        gdsGui_haptics_feedback("medium")
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
    -- Which tile (1-based index into gallery.items) is currently held down,
    -- for an item whose thumbnailPressedPath wants a press/release sprite
    -- swap like a real button (see _drawGalleryTilePreview) — nil whenever
    -- nothing is held, the held point isn't over a tile, or the touch has
    -- moved past tap slop into a scroll (see gdsGui_schematicGallery_moved).
    gallery.pressedTileIndex = nil
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

-- confirmIndex: see gdsGui_schematic_openMenu's own comment — same optional
-- 1-based "this row needs a hold, not a tap" marker, just for a gallery's
-- action menu instead of a canvas's.
function gdsGui_schematicGallery_openMenu(galleryName, title, options, onSelectFunc, onCancelFunc, confirmIndex)
    local gallery = _findGallery(galleryName)
    if not gallery then return end
    gallery.menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc }
    _markConfirmMenu(gallery.menu, confirmIndex)
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
        _galleryImageCache[path] = gdsGui_schematic_internal_loadSmoothImage(path)
    end
    return _galleryImageCache[path]
end

-- Gallery thumbnails/mini-diagrams render slightly darker than the main
-- canvas (same 0.02-per-channel offset the original hardcoded shades used:
-- 0.10,0.10,0.12 canvas vs 0.08,0.08,0.10 thumbnail) so tiles read as
-- distinct from the canvas/backdrop behind them instead of blending in.
local function _thumbnailBgColor()
    local canvasBg = globApp.themeCanvasBgColor or {0.10, 0.10, 0.12, 1}
    return {
        math.max(0, canvasBg[1] - 0.02),
        math.max(0, canvasBg[2] - 0.02),
        math.max(0, canvasBg[3] - 0.02),
        canvasBg[4],
    }
end

-- Draws a plain image (e.g. an app-supplied aircraft-type thumbnail) scaled
-- to fit inside (tx,ty,tw,th), letterboxed to preserve aspect ratio. The
-- library has no idea what the image depicts — it's just an item.thumbnailPath
-- string the app layer resolved, same arm's-length relationship as item.name.
local function _drawThumbnailImage(path, tx, ty, tw, th)
    local bg = _thumbnailBgColor()
    love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
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
    local bg = _thumbnailBgColor()
    love.graphics.setColor(bg[1], bg[2], bg[3], bg[4])
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
            -- Through a user-drawn path's points (see _wirePath), if it has one.
            local px, py = x1, y1
            for _, p in ipairs(w.waypoints or {}) do
                local qx, qy = toPixel(p.x, p.y)
                _drawOrthogonalLine(px, py, qx, qy)
                px, py = qx, qy
            end
            _drawOrthogonalLine(px, py, x2, y2)
            love.graphics.setLineWidth(1)
        end
    end

    for _, e in ipairs(elements or {}) do
        local ex, ey = toPixel(e.x, e.y)
        local ew, eh = e.w * tw, e.h * th
        local c = e.defaultColor or _DEFAULT_COLOR
        if e.spritePath then
            _drawElementSprite(e.spritePath, ex, ey, ew, eh, c[1], c[2], c[3], c[4], e.rotation)
        elseif e.shapePoints then
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            _shapePoly.drawLocal(e, ew, eh, c[1], c[2], c[3], c[4], 0)
            love.graphics.pop()
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
-- isPressed (optional): true while this exact tile is being held down (see
-- gallery.pressedTileIndex) — swaps to item.thumbnailPressedPath for that
-- span, same released/pressed sprite-pair convention a real button uses,
-- if the item supplied one; falls back to the plain thumbnailPath otherwise
-- (an item with no pressed variant just doesn't animate on press).
local function _drawGalleryTilePreview(item, tx, ty, tw, th, isPressed)
    local path = (isPressed and item.thumbnailPressedPath) or item.thumbnailPath
    if path then
        _drawThumbnailImage(path, tx, ty, tw, th)
    else
        _drawMiniDiagram(item.elements, item.wires, item.controls, tx, ty, tw, th)
    end
end

-- A small badge over a tile's top-right corner reporting an app-supplied
-- compatibility result (item.compatBadge — e.g. the aircraft gallery's own
-- one-time-per-update check; any other gallery just never sets the field, so
-- nothing is drawn): "ok" a green check, "issues" a red "!", "fixed" both —
-- a yellow "!" next to a green check, since that item needed changes but
-- came through fine. Purely cosmetic — the library has no idea what the
-- badge means, same arm's-length relationship as item.thumbnailPath. A
-- global table, like _selection/_shapePoly/_pipes/_glow, since this file is
-- at Lua's 200-local ceiling.
_galleryBadge = {}
_galleryBadge.R_PX = 8

function _galleryBadge.dot(cx, cy, r, cr, cg, cb)
    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.circle("fill", cx, cy, r + 1.5)
    love.graphics.setColor(cr, cg, cb, 1)
    love.graphics.circle("fill", cx, cy, r)
end

function _galleryBadge.check(cx, cy, r)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setLineWidth(2)
    love.graphics.line(cx - r * 0.5, cy, cx - r * 0.1, cy + r * 0.4, cx + r * 0.55, cy - r * 0.45)
    love.graphics.setLineWidth(1)
end

function _galleryBadge.bang(cx, cy, r)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.setLineWidth(2)
    love.graphics.line(cx, cy - r * 0.5, cx, cy + r * 0.1)
    love.graphics.setLineWidth(1)
    love.graphics.circle("fill", cx, cy + r * 0.45, 1.2)
end

function _galleryBadge.draw(tx, ty, tw, badge)
    if not badge then return end
    local r = _galleryBadge.R_PX
    local cy = ty + r + 3
    if badge == "fixed" then
        local bangCx, checkCx = tx + tw - r * 3 - 4, tx + tw - r - 3
        _galleryBadge.dot(bangCx, cy, r, 0.95, 0.75, 0.10)
        _galleryBadge.bang(bangCx, cy, r)
        _galleryBadge.dot(checkCx, cy, r, 0.18, 0.75, 0.30)
        _galleryBadge.check(checkCx, cy, r)
    elseif badge == "issues" then
        _galleryBadge.dot(tx + tw - r - 3, cy, r, 0.85, 0.18, 0.18)
        _galleryBadge.bang(tx + tw - r - 3, cy, r)
    else
        _galleryBadge.dot(tx + tw - r - 3, cy, r, 0.18, 0.75, 0.30)
        _galleryBadge.check(tx + tw - r - 3, cy, r)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- Draws one badge glyph on its own, at an app-chosen position/size, rather
-- than pinned to a tile's corner — e.g. a legend explaining what the
-- aircraft gallery's own per-tile badges (_galleryBadge.draw above) mean.
-- kind: "ok" | "issues" | "fixed", same three values item.compatBadge
-- takes; any other value draws nothing. Same arm's-length relationship as
-- the badge itself — the library only draws the glyph, the app supplies
-- whatever label text goes next to it.
function gdsGui_schematicGallery_drawBadgeIcon(cx, cy, r, kind)
    if kind == "fixed" then
        _galleryBadge.dot(cx, cy, r, 0.95, 0.75, 0.10)
        _galleryBadge.bang(cx, cy, r)
    elseif kind == "issues" then
        _galleryBadge.dot(cx, cy, r, 0.85, 0.18, 0.18)
        _galleryBadge.bang(cx, cy, r)
    elseif kind == "ok" then
        _galleryBadge.dot(cx, cy, r, 0.18, 0.75, 0.30)
        _galleryBadge.check(cx, cy, r)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function gdsGui_schematicGallery_draw(pageName)
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page == pageName then
            love.graphics.setScissor(gallery.x, gallery.y, gallery.w, gallery.h)
            local galleryBg = globApp.themeCanvasBgColor or {0.10, 0.10, 0.12, 1}
            love.graphics.setColor(galleryBg[1], galleryBg[2], galleryBg[3], galleryBg[4])
            love.graphics.rectangle("fill", gallery.x, gallery.y, gallery.w, gallery.h)

            if #gallery.items == 0 then
                love.graphics.setColor(1, 1, 1, 0.6)
                love.graphics.printf(gallery.emptyText, gallery.x, gallery.y + gallery.h / 2 - 10,
                    gallery.w, "center")
            else
                for i, item in ipairs(gallery.items) do
                    local tx, ty, tw, th = _galleryTileRect(gallery, i)
                    local isPressed = (i == gallery.pressedTileIndex)
                    if ty + th + _GALLERY_LABEL_H_PX >= gallery.y and ty <= gallery.y + gallery.h then
                        if item.statusLines then
                            -- Thumbnail + status-text row layout (the
                            -- snapshots gallery): a square thumbnail on the
                            -- left, the item's name/timestamp and its list of
                            -- control positions filling the rest of the row.
                            local diagW = th
                            _drawGalleryTilePreview(item, tx, ty, diagW, th, isPressed)
                            love.graphics.setColor(1, 1, 0, 1)
                            love.graphics.rectangle("line", tx, ty, diagW, th)
                            love.graphics.setColor(1, 1, 1, 1)
                            local textX, textW = tx + diagW + 8, tw - diagW - 8
                            love.graphics.printf(item.name or item.id, textX, ty, textW, "left")
                            love.graphics.printf(table.concat(item.statusLines, "\n"), textX, ty + 18, textW, "left")
                        else
                            _drawGalleryTilePreview(item, tx, ty, tw, th, isPressed)
                            love.graphics.setColor(1, 1, 0, 1)
                            love.graphics.rectangle("line", tx, ty, tw, th)
                            love.graphics.setColor(1, 1, 1, 1)
                            love.graphics.printf(item.name or item.id, tx, ty + th + 2, tw, "center")
                            _galleryBadge.draw(tx, ty, tw, item.compatBadge)
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
        gallery.pressedTileIndex  = _galleryTileAt(gallery, x, y)

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
        if math.abs(dy) > _GALLERY_TAP_SLOP_PX then
            -- Past tap slop — this is a scroll, not a tap-and-hold on the
            -- tile; drop the pressed-sprite feedback same as a button would
            -- un-press once a drag carries the touch off it.
            gallery.moved = true
            gallery.pressedTileIndex = nil
        end
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
            gallery.pressedTileIndex = nil
        end
        ::continue::
    end
end

function gdsGui_schematicGallery_update(dt)
    -- No per-frame physics (scroll is directly position-driven) beyond
    -- timing a held confirm-menu action row (see _pollMenuHoldToConfirm).
    local activePageName = _getActivePageName()
    for _, gallery in ipairs(globApp.objects.schematicGalleries) do
        if gallery.page == activePageName then
            _pollMenuHoldToConfirm(gallery, dt)
        end
    end
end
