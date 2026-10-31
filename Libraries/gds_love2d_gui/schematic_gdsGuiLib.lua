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
    return _elementGridFootprintFrac(canvas, pending.gridW, pending.gridH)
end

local function _commitNamedPlacement(canvas, pending, trimmed)
    if pending.kind == "element" then
        _pushUndo(canvas)
        local properties = {}
        for _, key in ipairs(pending.defaultPropertyKeys or {}) do
            table.insert(properties, { key = key, value = "" })
        end
        local wFrac, hFrac = _pendingElementSizeFrac(canvas, pending)
        gdsGui_schematic_addElement(pending.canvasName, pending.newId, pending.shapeType,
            pending.fracX, pending.fracY, wFrac, hFrac,
            trimmed, pending.defaultColor, properties, nil, pending.spritePath, pending.componentType,
            _deepCopy(pending.terminals))
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
        local extra = fn and fn(canvasName, pending.componentType)
        for _, r in ipairs(extra or {}) do table.insert(rows, r) end
    end
    for _, key in ipairs(pending.defaultPropertyKeys or {}) do
        table.insert(rows, { key = key, label = key, value = "" })
    end
    _pendingNamedPlacement = pending
    _pendingPlacementRows = rows
    gdsGui_schematic_openPropertyGrid(canvasName, "NAME THIS " .. pending.kind:upper(), nil, rows, true,
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
    _openPlacementNamePrompt("NAME THIS ANNUNCIATOR", _suggestedPlacementName(canvas, "ANNC"))
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
-- it's reshapable (see _snapRotationDegrees, _shapeCells.freeRotationDegrees),
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
-- the box enclosing it, and its own cells do the exact hit/collision tests
-- (see _shapeCells). Center stays the same point either way, so it's computed off the
-- original (unswapped) box before swapping.
local function _elementFootprintRect(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    local cx, cy = ex + ew / 2, ey + eh / 2
    if _isQuarterTurnRotation(e.rotation) then
        ew, eh = eh, ew
    elseif (e.rotation or 0) % 90 ~= 0 then
        local cosR, sinR = _shapeCells.cosSin(e.rotation)
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
-- as e.shapeRows, one string per grid-unit row with "#" for a filled cell and
-- "." for an empty one ({"###", "#..", "#.."} is an L), always trimmed to the
-- filled cells' own bounding box — which e.x/y/w/h keep tracking, so every
-- bounding-box consumer (rotation, label, move arrows) just keeps working.
-- Whole cells are why every corner stays square. nil until the first real
-- edit, so an untouched element keeps drawing as its own plain shapeType.
-- Global for the same 200-local ceiling as _propertyGrid below.
_shapeCells = {}
_shapeCells.HOLD_SECONDS = 2    -- the hold that unlocks a reshapable element's modes, in place of _LONG_PRESS_SECONDS
_shapeCells.HANDLE_HIT_PX = 14  -- reach of a corner handle, in screen pixels (not zoom-scaled, so a fingertip always fits)
_shapeCells.parsedCache = setmetatable({}, { __mode = "k" })

-- Decoded shapeRows, cached per table (each edit stores a brand-new one):
-- set[r][c] for the filled cells, runs (each row's filled spans, half-open
-- c0..c1), edges (every boundary cell side), corners (the draggable vertices).
function _shapeCells.parse(rows)
    local p = _shapeCells.parsedCache[rows]
    if p then return p end
    p = { rows = #rows, cols = #rows[1], set = {}, runs = {}, edges = {}, corners = {} }
    for r = 0, p.rows - 1 do
        local line, row, runStart = rows[r + 1], {}, nil
        p.set[r] = row
        for c = 0, p.cols do
            local isFilled = line:sub(c + 1, c + 1) == "#"
            if isFilled then row[c] = true end
            if isFilled and not runStart then
                runStart = c
            elseif runStart and not isFilled then
                table.insert(p.runs, { c0 = runStart, c1 = c, r = r })
                runStart = nil
            end
        end
    end
    local has = _shapeCells.has
    for r = 0, p.rows - 1 do
        for c = 0, p.cols - 1 do
            if has(p.set, c, r) then
                if not has(p.set, c, r - 1) then table.insert(p.edges, { c, r, c + 1, r }) end
                if not has(p.set, c, r + 1) then table.insert(p.edges, { c, r + 1, c + 1, r + 1 }) end
                if not has(p.set, c - 1, r) then table.insert(p.edges, { c, r, c, r + 1 }) end
                if not has(p.set, c + 1, r) then table.insert(p.edges, { c + 1, r, c + 1, r + 1 }) end
            end
        end
    end
    for r = 0, p.rows do
        for c = 0, p.cols do
            local count = _shapeCells.filledAround(p.set, c, r)
            if count == 1 or count == 3 then table.insert(p.corners, { c = c, r = r }) end
        end
    end
    _shapeCells.parsedCache[rows] = p
    return p
end

function _shapeCells.has(set, c, r)
    return set[r] ~= nil and set[r][c] == true
end

-- How many of the 4 cells meeting at grid vertex (c,r) are filled: 1 is a
-- convex corner, 3 a concave one, 2 a straight edge (or a diagonal pinch).
function _shapeCells.filledAround(set, c, r)
    local count = 0
    for _, q in ipairs({ { c - 1, r - 1 }, { c, r - 1 }, { c - 1, r }, { c, r } }) do
        if _shapeCells.has(set, q[1], q[2]) then count = count + 1 end
    end
    return count
end

-- The kind check behind every reshape gesture (see gdsGui_schematic_setReshapableKind).
function _shapeCells.allowed(canvas, e)
    local kind = canvas.reshapableKind
    return kind ~= nil and e.shapeType == kind.shapeType and e.componentType == kind.componentType
end

-- The element in reshape mode right now, or nil.
function _shapeCells.activeTarget(canvas)
    if not (canvas.reshapeModeActive and canvas.selectionMoveModeActive and canvas.selectedElementId) then return nil end
    local e = _findElement(canvas, canvas.selectedElementId)
    return (e and _shapeCells.allowed(canvas, e)) and e or nil
end

-- e.shapeRows, or the full box a not-yet-edited element's first edit starts from.
function _shapeCells.rowsOf(canvas, e)
    if e.shapeRows then return e.shapeRows end
    local cols = math.max(1, math.floor(e.w * canvas.contentW / _GRID_SPACING_PX + 0.5))
    local rowCount = math.max(1, math.floor(e.h * canvas.contentH / _GRID_SPACING_PX + 0.5))
    local rows = {}
    for r = 1, rowCount do rows[r] = string.rep("#", cols) end
    return rows
end

-- A cardinal turn rounds to exact 0/1/-1 rather than carrying float noise into
-- wire endpoints, which is what keeps a straight wire exactly straight.
function _shapeCells.cosSin(rotationDeg)
    local a = math.rad(rotationDeg or 0)
    if (rotationDeg or 0) % 90 == 0 then
        return math.floor(math.cos(a) + 0.5), math.floor(math.sin(a) + 0.5)
    end
    return math.cos(a), math.sin(a)
end

-- A reshapable element's rotate drag: any whole degree, except that within 3
-- degrees of a cardinal it settles on the cardinal, so getting a tank back to
-- exactly square with the grid doesn't take a steady hand.
function _shapeCells.freeRotationDegrees(angleRad)
    local deg = math.deg(angleRad) % 360
    local cardinal = math.floor(deg / 90 + 0.5) * 90
    if math.abs(deg - cardinal) <= 3 then return cardinal % 360 end
    return math.floor(deg + 0.5) % 360
end

-- Grid-vertex coordinates (lx,ly, 0..cols/0..rows) to screen pixels, for a
-- shape centered at cx,cy with cells cw x ch pixels — and back again.
function _shapeCells.toWorld(cx, cy, cw, ch, p, rotationDeg, lx, ly)
    local cosR, sinR = _shapeCells.cosSin(rotationDeg)
    local dx, dy = (lx - p.cols / 2) * cw, (ly - p.rows / 2) * ch
    return cx + dx * cosR - dy * sinR, cy + dx * sinR + dy * cosR
end

function _shapeCells.toLocal(cx, cy, cw, ch, p, rotationDeg, x, y)
    local cosR, sinR = _shapeCells.cosSin(rotationDeg)
    local dx, dy = x - cx, y - cy
    return (dx * cosR + dy * sinR) / cw + p.cols / 2, (-dx * sinR + dy * cosR) / ch + p.rows / 2
end

-- An element's live frame: center, cell size in pixels, and parsed shape.
function _shapeCells.frame(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    local p = _shapeCells.parse(_shapeCells.rowsOf(canvas, e))
    return ex + ew / 2, ey + eh / 2, ew / p.cols, eh / p.rows, p
end

function _shapeCells.containsPoint(canvas, e, x, y)
    local cx, cy, cw, ch, p = _shapeCells.frame(canvas, e)
    local lx, ly = _shapeCells.toLocal(cx, cy, cw, ch, p, e.rotation, x, y)
    return _shapeCells.has(p.set, math.floor(lx), math.floor(ly))
end

-- Calls fn(centerX, centerY, halfX, halfY) with screen-axis-aligned boxes that
-- together cover the shape, stopping at and returning whatever fn first returns
-- truthy. Each row span is one exact box at a cardinal turn; at any other angle
-- each cell gets its own enclosing box, which stays much tighter around the
-- shape than one enclosing a long diagonal span would.
function _shapeCells.eachSpanBox(p, cx, cy, cw, ch, rotationDeg, fn)
    local perCell = (rotationDeg or 0) % 90 ~= 0
    for _, run in ipairs(p.runs) do
        local c0 = run.c0
        while c0 < run.c1 do
            local c1 = perCell and (c0 + 1) or run.c1
            local minX, maxX, minY, maxY
            for _, vertex in ipairs({ { c0, run.r }, { c1, run.r }, { c0, run.r + 1 }, { c1, run.r + 1 } }) do
                local x, y = _shapeCells.toWorld(cx, cy, cw, ch, p, rotationDeg, vertex[1], vertex[2])
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
-- point x,y, should stop on this shape: the outermost point of that line on any
-- filled cell, on the side the wire is arriving from, so a wire whose box center
-- sits in a cut-away notch runs on through the notch to the tank's actual body.
-- Only a rotated shape's line can miss every cell, and then the wire just runs
-- to x,y itself.
function _shapeCells.edgePoint(canvas, e, x, y, axis, sign)
    local cx, cy, cw, ch, p = _shapeCells.frame(canvas, e)
    local lx, ly = _shapeCells.toLocal(cx, cy, cw, ch, p, e.rotation, x, y)
    local cosR, sinR = _shapeCells.cosSin(e.rotation)
    local dirX, dirY = (axis == "x") and sign or 0, (axis == "y") and sign or 0
    local stepC, stepR = (dirX * cosR + dirY * sinR) / cw, (-dirX * sinR + dirY * cosR) / ch
    local best
    for _, run in ipairs(p.runs) do
        local tMin, tMax = -math.huge, math.huge
        for _, slab in ipairs({ { lx, stepC, run.c0, run.c1 }, { ly, stepR, run.r, run.r + 1 } }) do
            local from, step, low, high = slab[1], slab[2], slab[3], slab[4]
            if step ~= 0 then
                local t1, t2 = (low - from) / step, (high - from) / step
                tMin, tMax = math.max(tMin, math.min(t1, t2)), math.min(tMax, math.max(t1, t2))
            elseif from < low or from > high then
                tMax = -math.huge
            end
        end
        if tMin <= tMax and (not best or tMax > best) then best = tMax end
    end
    if not best then return x, y end
    return _shapeCells.toWorld(cx, cy, cw, ch, p, e.rotation, lx + best * stepC, ly + best * stepR)
end

-- Filled body and white outline, in the caller's already centered+rotated
-- space; r,g,b,a is the fill, outlineAlpha the outline (0 for a glow halo).
function _shapeCells.drawLocal(e, ew, eh, r, g, b, a, outlineAlpha)
    local p = _shapeCells.parse(e.shapeRows)
    local cw, ch = ew / p.cols, eh / p.rows
    love.graphics.setColor(r, g, b, a)
    for _, run in ipairs(p.runs) do
        love.graphics.rectangle("fill", -ew / 2 + run.c0 * cw, -eh / 2 + run.r * ch, (run.c1 - run.c0) * cw, ch)
    end
    love.graphics.setColor(1, 1, 1, outlineAlpha)
    _shapeCells.strokeEdges(p, ew, eh)
end

function _shapeCells.strokeEdges(p, ew, eh)
    local cw, ch = ew / p.cols, eh / p.rows
    for _, edge in ipairs(p.edges) do
        love.graphics.line(-ew / 2 + edge[1] * cw, -eh / 2 + edge[2] * ch, -ew / 2 + edge[3] * cw, -eh / 2 + edge[4] * ch)
    end
end

-- The selection/collision outline: the shape's real boundary, in whatever
-- color the caller has set — the shaped counterpart of _drawElement's plain
-- footprint rectangle.
function _shapeCells.strokeOutline(canvas, e)
    local ex, ey, ew, eh = _elementPixelRect(canvas, e)
    love.graphics.push()
    love.graphics.translate(ex + ew / 2, ey + eh / 2)
    love.graphics.rotate(math.rad(e.rotation or 0))
    _shapeCells.strokeEdges(_shapeCells.parse(e.shapeRows), ew, eh)
    love.graphics.pop()
end

-- Reshape-mode affordance: a square handle on every draggable corner.
function _shapeCells.drawHandles(canvas, e)
    local cx, cy, cw, ch, p = _shapeCells.frame(canvas, e)
    local half = math.max(3, 0.7 * canvas.zoom)
    love.graphics.setColor(1, 0, 1, 1)
    for _, corner in ipairs(p.corners) do
        local x, y = _shapeCells.toWorld(cx, cy, cw, ch, p, e.rotation, corner.c, corner.r)
        love.graphics.rectangle("fill", x - half, y - half, half * 2, half * 2)
    end
end

-- The corner handle under a press, nearest first, or nil.
function _shapeCells.cornerAt(canvas, e, x, y)
    local cx, cy, cw, ch, p = _shapeCells.frame(canvas, e)
    local best, bestDist = nil, _shapeCells.HANDLE_HIT_PX
    for _, corner in ipairs(p.corners) do
        local hx, hy = _shapeCells.toWorld(cx, cy, cw, ch, p, e.rotation, corner.c, corner.r)
        local dist = math.sqrt((hx - x) ^ 2 + (hy - y) ^ 2)
        if dist <= bestDist then best, bestDist = corner, dist end
    end
    return best
end

function _shapeCells.beginDrag(canvas, e, corner)
    canvas._shapeDrag = {
        c = corner.c, r = corner.r, rows = _shapeCells.rowsOf(canvas, e), originalRows = e.shapeRows,
        x = e.x, y = e.y, w = e.w, h = e.h,
    }
end

-- Fills the half-open rectangle between grid vertices (c1,r1) and (c2,r2).
function _shapeCells.setRect(set, c1, r1, c2, r2, value)
    for r = math.min(r1, r2), math.max(r1, r2) - 1 do
        set[r] = set[r] or {}
        for c = math.min(c1, c2), math.max(c1, c2) - 1 do set[r][c] = value end
    end
end

-- The cell set a drag from drag.c,drag.r to grid vertex (fc,fr) produces.
-- Pushing a corner into the body cuts a square notch out of it. Pulling a
-- concave corner into its empty quadrant fills that rectangle in. Pulling a
-- convex corner outward carries its two edges along with it, the way a
-- rectangle's corner handle works in any drawing program, so a plain tank
-- just grows into a bigger plain tank. Any axis of a pull that points inward
-- is ignored rather than undoing the other axis's growth.
function _shapeCells.candidateSet(p, drag, fc, fr)
    local set = {}
    for r, row in pairs(p.set) do
        set[r] = {}
        for c in pairs(row) do set[r][c] = true end
    end
    local has = _shapeCells.has
    local vc, vr = drag.c, drag.r
    local dc, dr = fc - vc, fr - vr
    if dc == 0 and dr == 0 then return set end
    local qc = (dc > 0) and vc or (vc - 1)
    local qr = (dr > 0) and vr or (vr - 1)
    if dc ~= 0 and dr ~= 0 and has(p.set, qc, qr) then
        _shapeCells.setRect(set, vc, vr, fc, fr, nil)
    elseif _shapeCells.filledAround(p.set, vc, vr) == 3 then
        if dc ~= 0 and dr ~= 0 then _shapeCells.setRect(set, vc, vr, fc, fr, true) end
    else
        -- Convex: (oc,or) is the one filled cell at this vertex; (outC,outR)
        -- point away from it. Each edge is walked back from the corner for as
        -- long as it stays a boundary, then pushed out to the finger.
        local oc = has(p.set, vc, vr) and vc or (has(p.set, vc, vr - 1) and vc or (vc - 1))
        local or_ = has(p.set, oc, vr) and vr or (vr - 1)
        local outC, outR = (oc == vc) and -1 or 1, (or_ == vr) and -1 or 1
        local pullC, pullR = dc * outC > 0, dr * outR > 0
        if pullC then
            local r = or_
            while has(p.set, oc, r) and not has(p.set, oc + outC, r) do
                _shapeCells.setRect(set, vc, r, fc, r + 1, true)
                r = r - outR
            end
        end
        if pullR then
            local c = oc
            while has(p.set, c, or_) and not has(p.set, c, or_ + outR) do
                _shapeCells.setRect(set, c, vr, c + 1, fr, true)
                c = c - outC
            end
        end
        if pullC and pullR then _shapeCells.setRect(set, vc, vr, fc, fr, true) end
    end
    return set
end

-- A cell set as trimmed shapeRows plus its box's min corner, or nil if it's
-- empty or split into more than one piece.
function _shapeCells.encode(set)
    local minC, maxC, minR, maxR, startC, startR
    local total = 0
    for r, row in pairs(set) do
        for c in pairs(row) do
            total = total + 1
            startC, startR = c, r
            minC, maxC = math.min(minC or c, c), math.max(maxC or c, c)
            minR, maxR = math.min(minR or r, r), math.max(maxR or r, r)
        end
    end
    if total == 0 then return nil end
    local seen, stack, reached = {}, { { startC, startR } }, 0
    while #stack > 0 do
        local cell = table.remove(stack)
        local c, r = cell[1], cell[2]
        seen[r] = seen[r] or {}
        if _shapeCells.has(set, c, r) and not seen[r][c] then
            seen[r][c] = true
            reached = reached + 1
            table.insert(stack, { c + 1, r })
            table.insert(stack, { c - 1, r })
            table.insert(stack, { c, r + 1 })
            table.insert(stack, { c, r - 1 })
        end
    end
    if reached ~= total then return nil end
    local rows = {}
    for r = minR, maxR do
        local chars = {}
        for c = minC, maxC do chars[#chars + 1] = _shapeCells.has(set, c, r) and "#" or "." end
        rows[#rows + 1] = table.concat(chars)
    end
    return rows, minC, minR
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
        if e.id ~= excludeId and e.shapeRows then
            -- A shaped element only blocks where it's actually filled, so
            -- something can sit in a notch cut out of it.
            local ecx, ecy, cw, ch, p = _shapeCells.frame(canvas, e)
            local hit = _shapeCells.eachSpanBox(p, ecx, ecy, cw, ch, e.rotation, function(sx, sy, sHalfX, sHalfY)
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

-- The same check for a shaped element about to sit at center cx,cy with cells
-- cw x ch pixels: each of its filled spans is its own candidate footprint.
function _shapeCells.blockedAt(canvas, elem, p, cx, cy, cw, ch, rotationDeg)
    return _shapeCells.eachSpanBox(p, cx, cy, cw, ch, rotationDeg, function(sx, sy, sHalfX, sHalfY)
        return _footprintOverlapsAnother(canvas, sx, sy, sHalfX, sHalfY, elem.id)
    end)
end

-- Applies the current finger position to an in-progress corner drag. Always
-- recomputed from the shape the press started on (canvas._shapeDrag), so
-- dragging back undoes the change live; a result that's split in two, off the
-- canvas, or on top of a neighbor simply isn't applied — same "stops at the
-- obstacle" feel as a move drag. Returns true once e differs from that start.
function _shapeCells.updateDrag(canvas, e, x, y)
    local drag = canvas._shapeDrag
    local p = _shapeCells.parse(drag.rows)
    local bx, by = _toPixel(canvas, drag.x, drag.y)
    local bw, bh = drag.w * canvas.contentW * canvas.zoom, drag.h * canvas.contentH * canvas.zoom
    local bcx, bcy, cw, ch = bx + bw / 2, by + bh / 2, bw / p.cols, bh / p.rows
    local lx, ly = _shapeCells.toLocal(bcx, bcy, cw, ch, p, e.rotation, x, y)
    local fc, fr = math.floor(lx + 0.5), math.floor(ly + 0.5)
    local rows, minC, minR = _shapeCells.encode(_shapeCells.candidateSet(p, drag, fc, fr))
    canvas.collidingObstacleId = nil
    if not rows then return false end
    if table.concat(rows, "\n") == table.concat(drag.rows, "\n") then
        e.shapeRows, e.x, e.y, e.w, e.h = drag.originalRows, drag.x, drag.y, drag.w, drag.h
        return false
    end
    local np = _shapeCells.parse(rows)
    -- Where the new box's center lands, keeping every surviving cell exactly
    -- where it already was on screen.
    local ncx, ncy = _shapeCells.toWorld(bcx, bcy, cw, ch, p, e.rotation, minC + np.cols / 2, minR + np.rows / 2)
    local cosR, sinR = _shapeCells.cosSin(e.rotation)
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
    local blocked, obstacle = _shapeCells.blockedAt(canvas, e, np, ncx, ncy, cw, ch, e.rotation)
    if blocked then
        canvas.collidingObstacleId = obstacle and obstacle.id or nil
        return false
    end
    local fracW, fracH = np.cols * drag.w / p.cols, np.rows * drag.h / p.rows
    local cfx, cfy = _toFraction(canvas, ncx, ncy)
    e.shapeRows, e.w, e.h = rows, fracW, fracH
    e.x, e.y = cfx - fracW / 2, cfy - fracH / 2
    return true
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
           and (not e.shapeRows or _shapeCells.containsPoint(canvas, e, px, py)) then
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
    -- (see _shapeCells): move -> rotate -> reshape -> move.
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
    canvas.menu              = nil  -- generic modal list: {title, options, onSelect, onCancel}
    canvas.pendingPlacement  = nil  -- armed "place next tap": {kind, shapeType|positions, label, ...}
    canvas.pendingConnectorColor = nil  -- armed "draw next wire" from the catalog, independent of wireToolActive/the dock toggle; disarms after one connector
    canvas.pendingColorAssignPick = false  -- armed "tap an element or wire to assign its snapshot color"; disarms after one pick
    canvas.pendingWireFromId = nil  -- armed via ADD WIRE in the element edit menu: elementId the next press-drag-release starts a wire from, with no need to land that press on an anchor; disarms after one drag
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
        canvas.pendingColorAssignPick or canvas.pendingWireFromId ~= nil)
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
-- _MENU_WIDTH_FRAC).
function gdsGui_schematic_openMenu(canvasName, title, options, onSelectFunc, onCancelFunc, confirmIndex, widthFrac)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    -- A menu always takes priority over the annunciator panel (see
    -- gdsGui_schematic_pressed, which checks canvas.menu first) — close the
    -- panel here too so it doesn't keep drawing underneath/behind the menu
    -- it's no longer receiving input for (e.g. the ADD "+" button opening
    -- the catalog cascade while the panel happens to be open).
    canvas.annunciatorPanelOpen = false
    canvas.menu = { title = title, options = options, onSelect = onSelectFunc, onCancel = onCancelFunc,
        anchorButtonName = canvas._menuAnchorButtonName, widthFrac = widthFrac }
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

-- Generalized over any owner with .x/.y/.w/.h (schematic canvas or gallery)
-- so both widget types can share one modal-menu implementation below.
-- A menu is normally a plain vertical list of text rows (menu.options). When
-- menu.isSwatchPicker is set, the first #menu.swatchColors entries render as
-- a single row of colored squares instead (menu.extraOptions, e.g. "DELETE",
-- still render as ordinary text rows below it) — the swatch count plus the
-- extra-option count must equal #menu.options, since hit-testing/selection
-- still indexes into that one combined list.
local function _menuGeometry(owner, menu)
    local w = owner.w * (menu.widthFrac or _MENU_WIDTH_FRAC)
    local titleH = _titleHeight(w, menu.title)
    local bodyH
    if menu.isSwatchPicker then
        bodyH = _SWATCH_ROW_H_PX + #menu.extraOptions * _MENU_ROW_H
    else
        bodyH = #menu.options * _MENU_ROW_H
    end
    local h = titleH + bodyH + 10
    local x = owner.x + (owner.w - w) / 2
    local y
    local anchorBtn = menu.anchorButtonName and _findButton(menu.anchorButtonName)
    if anchorBtn then
        -- Opened by a dock tool (see gdsGui_schematic_setMenuAnchorButton):
        -- pinned just left of that tool's button at the canvas's top edge
        -- instead of centered.
        x, y = _toolPopupOrigin(owner, anchorBtn, w)
    elseif menu.isSwatchPicker then
        -- The selected-item color picker is anchored in the bottom third of
        -- the canvas/gallery area (rather than dead-center) so it sits below
        -- the item being edited instead of covering it; clamped back inside
        -- owner bounds in case the band is shorter than the menu itself.
        local bandY = owner.y + owner.h * 2 / 3
        local bandH = owner.h / 3
        y = bandY + (bandH - h) / 2
        y = math.max(owner.y, math.min(y, owner.y + owner.h - h))
    else
        y = owner.y + math.max(0, (owner.h - h) / 2)
    end
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
    if pressedHit == "outside" then
        local cb = menu.onCancel
        owner.menu = nil
        if cb and _G[cb] then _G[cb](owner.name) end
    elseif menu.confirmRows and menu.confirmRows[pressedHit] then
        -- A confirm row (see _markConfirmMenu) only ever fires via a
        -- sustained hold, timed by _pollMenuHoldToConfirm — a plain
        -- tap-release here, however deliberate it looked, is just an
        -- abandoned attempt. The menu stays open so the user can try again.
        return
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
    local opt = menu.options[pressedIndex]
    local cb = menu.onSelect
    owner.menu = nil
    if cb and _G[cb] then _G[cb](owner.name, pressedIndex, opt) end
end

-- One text menu row, filled with confirmColor whenever it's a confirm-gated
-- action (menu.confirmRows[idx] — see _markConfirmMenu) — EVERY row
-- requiring a sustained hold to fire, whatever its label actually says
-- ("DELETE", "DELETE PROPERTY", "CLEAR PAGE", "CONTINUE", "OVERWRITE", ...),
-- not just rows whose text happens to literally read "DELETE". Previously
-- keyed off an exact opt == "DELETE" text match, so every other
-- confirm-gated row (RESET, SNAPSHOT RESET's CONTINUE, a snapshot-conflict
-- OVERWRITE, ...) looked like an ordinary plain-tap row even though it
-- already required the same hold to actually fire — inconsistent styling
-- for identical behavior. holdFrac (optional, 0-1): while this row is a
-- confirm-gated action AND is currently being held down (see
-- _pollMenuHoldToConfirm), draws a left-to-right loading-bar overlay across
-- it so the user can see how much longer the hold needs to last instead of
-- just waiting blind — reaching the row's full width exactly when the hold
-- is about to fire.
local function _drawMenuTextRow(mx, mw, rowY, opt, confirmColor, holdFrac)
    if confirmColor then
        love.graphics.setColor(confirmColor[1], confirmColor[2], confirmColor[3], confirmColor[4] or 1)
        love.graphics.rectangle("fill", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("line", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
        -- Black for a light confirm color (yellow and up), white otherwise
        -- — keeps the row's own label readable regardless of which color
        -- it was given (the historical red default always resolved to
        -- white text; yellow needs the opposite). Plain luminance
        -- threshold, not a true perceptual formula — this only ever has
        -- to pick between two colors wildly far apart in brightness,
        -- never a close call. Nested here (its only caller) to stay under
        -- this file's 200-local ceiling.
        local luminance = 0.299 * confirmColor[1] + 0.587 * confirmColor[2] + 0.114 * confirmColor[3]
        if luminance > 0.6 then love.graphics.setColor(0, 0, 0, 1) else love.graphics.setColor(1, 1, 1, 1) end
    elseif opt == "RETURN" then
        -- Every RETURN row, on every schematic menu (this function is the
        -- one shared draw path _drawMenuBox/gdsGui_schematicGallery_
        -- drawMenuOverlay both call) — a footer matching _drawMenuBox's
        -- own title-bar treatment exactly (full-bleed fill, no inset
        -- margin, no outline), not another row styled like the
        -- confirmColor ones above. Still an ordinary single-tap row —
        -- only its background changes, no hold-to-confirm behavior.
        love.graphics.setColor(0.25, 0.25, 0.25, _MENU_OPACITY)
        love.graphics.rectangle("fill", mx, rowY, mw, _MENU_ROW_H)
        love.graphics.setColor(1, 1, 1, 1)
    else
        love.graphics.setColor(1, 1, 1, 0.15)
        love.graphics.rectangle("line", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
        love.graphics.setColor(1, 1, 1, 1)
    end
    love.graphics.printf(opt, mx, rowY + 8, mw, "center")
    if holdFrac and holdFrac > 0 then
        love.graphics.setColor(0.2, 0.5, 1, 0.5)
        love.graphics.rectangle("fill", mx + 4, rowY + 2, (mw - 8) * math.min(1, holdFrac), _MENU_ROW_H - 4)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("line", mx + 4, rowY + 2, mw - 8, _MENU_ROW_H - 4)
        love.graphics.printf(opt, mx, rowY + 8, mw, "center")
    end
end

-- Shared modal-menu box drawing for any owner with a .menu.
local function _drawMenuBox(owner, menu)
    if menu.choiceGrid then return _choiceGrid.draw(owner, menu) end
    if menu.propertyGrid then return _propertyGrid.draw(owner, menu) end
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", owner.x, owner.y, owner.w, owner.h)

    local mx, my, mw, mh, titleH = _menuGeometry(owner, menu)
    love.graphics.setColor(0.15, 0.15, 0.18, _MENU_OPACITY)
    love.graphics.rectangle("fill", mx, my, mw, mh)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", mx, my, mw, mh)

    local rowY = my
    if menu.title then
        love.graphics.setColor(0.25, 0.25, 0.25, _MENU_OPACITY)
        love.graphics.rectangle("fill", mx, rowY, mw, titleH)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(menu.title, mx, rowY + 8, mw, "center")
        rowY = rowY + titleH
    end

    -- Which row (by combined options index — same indexing menu.confirmRows
    -- itself uses, swatches included) is a confirm action currently being
    -- held down, and how far through _CONFIRM_HOLD_SECONDS that hold is —
    -- see _drawMenuTextRow's own comment for why.
    local holdIndex, holdFrac
    if menu.confirmRows and menu._pressedTouchId ~= nil and menu.confirmRows[menu._pressedHit] then
        holdIndex = menu._pressedHit
        holdFrac = (menu._holdElapsed or 0) / _CONFIRM_HOLD_SECONDS
    end

    if menu.isSwatchPicker then
        local n = #menu.swatchColors
        local _, firstSize = _swatchRect(mx, mw, n, 1)
        local sy = rowY + (_SWATCH_ROW_H_PX - firstSize) / 2
        for i, c in ipairs(menu.swatchColors) do
            local sx, size = _swatchRect(mx, mw, n, i)
            love.graphics.setColor(_themedPaletteColor(c[1], c[2], c[3], c[4] or 1))
            love.graphics.rectangle("fill", sx, sy, size, size)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.rectangle("line", sx, sy, size, size)
        end
        rowY = rowY + _SWATCH_ROW_H_PX
        for j, opt in ipairs(menu.extraOptions) do
            local idx = n + j
            _drawMenuTextRow(mx, mw, rowY, opt, menu.confirmRows and menu.confirmRows[idx], (idx == holdIndex) and holdFrac or nil)
            rowY = rowY + _MENU_ROW_H
        end
    else
        for i, opt in ipairs(menu.options) do
            _drawMenuTextRow(mx, mw, rowY, opt, menu.confirmRows and menu.confirmRows[i], (i == holdIndex) and holdFrac or nil)
            rowY = rowY + _MENU_ROW_H
        end
    end
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
-- row.value — no keyboard involved); omitted, it's a free-text box.
-- numericOnly (text rows only): same digit/one-decimal-point filter
-- gdsGui_textPrompt_open's own numericOnly uses, applied per keystroke by
-- gdsGui_schematic_propertyGridTextInput below. slider = {min, max, unit}
-- (optional): a horizontal scrollbar in place of the value box, dragged or
-- tapped in whole steps, with row.value as the number in string form and the
-- current value shown after the row's label. requireAll (optional): true
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
    local maxBodyH = owner.h * 0.92 - titleH - headerH - _propertyGrid.FOOTER_H
    local bodyH = math.max(rowH, math.min(contentH, maxBodyH))
    local h = titleH + headerH + bodyH + _propertyGrid.FOOTER_H
    local x = owner.x + (owner.w - w) / 2
    local y = owner.y + math.max(0, (owner.h - h) / 2)
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
        menu.rows[hit.row].value = menu.rows[hit.row].choices[hit.choice]
        menu.errorRow, menu.errorText = nil, nil
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
            local labelText = row.slider and (row.label .. ": " .. (row.value or "") .. " " .. (row.slider.unit or "")) or row.label
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
                    if row.swatchColors then
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
local _PAINT_SWATCH_GAP_PX    = 8

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
function gdsGui_schematic_drawPaintOverlay(pageName)
    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName and canvas.paintMode then
            local activeColor = canvas.paintMode.color
            for i, entry in ipairs(_COLOR_PALETTE) do
                local sx, sy, sw, sh = _paintSwatchRect(canvas, i)
                love.graphics.setColor(_themedPaletteColor(entry.color[1], entry.color[2], entry.color[3], entry.color[4] or 1))
                love.graphics.rectangle("fill", sx, sy, sw, sh)
                -- Compared against the raw (undarkened) entry.color, same as
                -- activeColor itself (canvas.paintMode.color is set straight
                -- from a palette entry, never the themed display variant) —
                -- the "is this swatch the active brush" check, unlike the
                -- fill color just above, isn't a themed draw.
                local isActive = activeColor and activeColor[1] == entry.color[1] and
                    activeColor[2] == entry.color[2] and activeColor[3] == entry.color[3]
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.setLineWidth(isActive and 3 or 1)
                love.graphics.rectangle("line", sx, sy, sw, sh)
                love.graphics.setLineWidth(1)
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
-- the panel renders on top of the canvas content underneath it.
local function _drawAnnunciatorPanel(canvas)
    local x, y, w, h, headerH, bodyH, list = _annunciatorPanelGeometry(canvas)
    love.graphics.setColor(0.12, 0.12, 0.14, 0.95)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", x, y, w, h)

    love.graphics.setFont(globApp.appFont or love.graphics.getFont())
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("ANNUNCIATORS", x, y + (headerH - 14) / 2, w, "center")
    love.graphics.setColor(1, 1, 1, 0.3)
    love.graphics.line(x + 2, y + headerH, x + w - 2, y + headerH)

    love.graphics.setScissor(x, y + headerH, w, bodyH)
    local scroll = canvas.annunciatorPanelScroll or 0
    for i, a in ipairs(list) do
        local rowY = y + headerH + (i - 1) * _ANNUNCIATOR_ROW_H_PX - scroll
        if rowY + _ANNUNCIATOR_ROW_H_PX > y + headerH and rowY < y + headerH + bodyH then
            local swX = x + 10
            local swY = rowY + (_ANNUNCIATOR_ROW_H_PX - _ANNUNCIATOR_SWATCH_PX) / 2
            if a.active then
                love.graphics.setColor(_themedPaletteColor(a.color[1], a.color[2], a.color[3], a.color[4] or 1))
                love.graphics.rectangle("fill", swX, swY, _ANNUNCIATOR_SWATCH_PX, _ANNUNCIATOR_SWATCH_PX)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.rectangle("line", swX, swY, _ANNUNCIATOR_SWATCH_PX, _ANNUNCIATOR_SWATCH_PX)
                love.graphics.setColor(1, 1, 1, 1)
            else
                -- Grayed out: no fill, dim outline, dim label — matches the
                -- "deactivated annunciators are grayed out" requirement.
                love.graphics.setColor(0.4, 0.4, 0.4, 1)
                love.graphics.rectangle("line", swX, swY, _ANNUNCIATOR_SWATCH_PX, _ANNUNCIATOR_SWATCH_PX)
                love.graphics.setColor(0.55, 0.55, 0.55, 1)
            end
            love.graphics.printf(a.label or a.id, swX + _ANNUNCIATOR_SWATCH_PX + 8,
                rowY + (_ANNUNCIATOR_ROW_H_PX - 14) / 2, w - (_ANNUNCIATOR_SWATCH_PX + 26), "left")
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
    gdsGui_schematic_openMenu(canvasName, a.label or annunciatorId, {"RENAME", "PROPERTIES", "DELETE"},
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
    gdsGui_schematic_openPropertyGrid(canvasName, "PROPERTIES: " .. (a.label or annunciatorId), nil, rows, false,
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
-- separate "DELETE \"X\"?" popup. ADD WIRE/RENAME/PROPERTIES stay plain-tap.
--------------------------------------------------------------------------------

function gdsGui_schematic_openElementEditMenu(canvasName, elementId)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    local el = _findElement(canvas, elementId)
    if not el then return end
    canvas._elementEditTargetId = elementId
    local options = {_pipes.addLabel(canvas), "RENAME", "PROPERTIES", "DELETE"}
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
    gdsGui_schematic_openMenu(canvasName, title, options,
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
        canvas.pendingWireFromId = elementId
        return
    elseif optionText == "RENAME" then
        -- RENAME tapped: hand off to the rename prompt, keeping the element
        -- selected while that flow is in progress.
        canvas._elementEditTargetId = nil
        _openElementRenamePrompt(canvasName, elementId)
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
        gdsGui_schematic_openMenu(canvasName, _pipes.noun(canvas) .. ": " .. wireId .. "\nCan't be deleted on its own — delete the item it belongs to.",
            {"OK"}, "gdsGui_schematic_internal_onWireEditCancelled", "gdsGui_schematic_internal_onWireEditCancelled")
        return
    end
    gdsGui_schematic_openMenu(canvasName, _pipes.noun(canvas) .. ": " .. wireId, {"DELETE"},
        "gdsGui_schematic_internal_onWireEditChosen", "gdsGui_schematic_internal_onWireEditCancelled", 1)
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
    gdsGui_schematic_openMenu(canvasName, ctrl.label or controlId, options,
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
    gdsGui_schematic_openPropertyGrid(canvasName, "PROPERTIES: " .. (el.label or elementId),
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
    love.graphics.setColor(g[1], g[2], g[3], g[4])
    local spacing = _GRID_SPACING_PX
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
        elseif e.shapeRows then
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            _shapeCells.drawLocal(e, ew, eh, r, g, b, a, outline)
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
            -- Plain rect, same rotation treatment as circle above.
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            love.graphics.rectangle("fill", -ew / 2, -eh / 2, ew, eh)
            love.graphics.setColor(1, 1, 1, outline)
            love.graphics.rectangle("line", -ew / 2, -eh / 2, ew, eh)
            love.graphics.pop()
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
    -- Flagged by gdsGui_schematic_moved's "element"/"control" dragKind
    -- branches as the specific obstacle a relocation drag is currently
    -- pushing into (via _footprintOverlapsAnother's 2nd return value) —
    -- red for exactly as long as that stays true, cleared the instant the
    -- drag clears it or the gesture ends. Independent of (and drawn before,
    -- so selection's own yellow/magenta wins if both were ever true at
    -- once) the normal selection outline below.
    if canvas.collidingObstacleId == e.id then
        love.graphics.setColor(1, 0, 0, 1)
        if e.shapeRows then
            _shapeCells.strokeOutline(canvas, e)
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
        if canvas.selectionMoveModeActive then
            love.graphics.setColor(1, 0, 1, 0.5)
        else
            love.graphics.setColor(1, 1, 0, 1)
        end
        -- Hugs the element's own true pixel footprint (fex,fey,few,feh) with
        -- no padding — the exact same box _footprintOverlapsAnother checks
        -- placement/drag collisions against (see _elementFootprintRect), so
        -- the visible selection square IS the collision boundary — rotated
        -- right along with the element for a non-square (gridW ~= gridH)
        -- one, not a separate shared size that only approximated it.
        -- Square, same as a control's own selection box (see _drawControl's
        -- matching "rectangle" line) — one consistent "this is selected"
        -- shape for every anchor kind. A reshaped element traces its real
        -- outline instead, which is what it collides against (see _shapeCells).
        if e.shapeRows then
            _shapeCells.strokeOutline(canvas, e)
        else
            love.graphics.rectangle("line", fex, fey, few, feh)
        end
        if canvas.selectionMoveModeActive then
            -- Mutually exclusive, not both at once: every further tap on
            -- the active target toggles between them (see
            -- gdsGui_schematic_pressed's isActiveMoveTarget branch) rather
            -- than opening the edit menu. Every element is rotatable now,
            -- same as every control.
            if canvas.reshapeModeActive and _shapeCells.allowed(canvas, e) then
                _shapeCells.drawHandles(canvas, e)
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
        if anchor.shapeRows then _, _, ew, eh = _elementFootprintRect(canvas, anchor) end
        return (axis == "x") and (ew / 2) or (eh / 2)
    end
    return canvas.controlRadius * canvas.zoom * (anchor.radiusScale or 1)
end

local function _anchorEdgePoint(canvas, anchor, cx, cy, axis, sign)
    if anchor and anchor.shapeRows then
        return _shapeCells.edgePoint(canvas, anchor, cx, cy, axis, sign)
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
-- in place of a plain love.graphics.line.
local function _drawSegmentWithHopsAndGaps(x1, y1, x2, y2, hopDistances, bundledRanges, zoom, lineFn)
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

    for i = 1, #cuts - 1 do
        local a, b = cuts[i], cuts[i + 1]
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
            if inHop then
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

    local thickness = _WIRE_WIDTH_PX * canvas.zoom * (isHalo and _glow.WIRE_WIDTH or 1)
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
local function _drawWirePlanSegments(plan, zoom)
    local halfW = love.graphics.getLineWidth() / 2
    local prevEndX, prevEndY, prevVertical
    for idx, seg in ipairs(plan.segments) do
        local startX, startY, endX, endY = _drawSegmentWithHopsAndGaps(
            seg[1], seg[2], seg[3], seg[4], plan.hopDistances[idx], plan.bundledRanges[idx], zoom)
        if idx > 1 then
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

-- noun: what the menus call a connector on this canvas ("PIPE", "DUCT"), or nil
-- for plain wires.
function gdsGui_schematic_setPipeConnectors(canvasName, noun)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.pipeConnectors = noun ~= nil
    canvas.connectorNoun = noun
end

-- Names the one kind of element on this canvas whose outline can be redrawn
-- (see _shapeCells), or nil for none. Matched by kind rather than stored on
-- each element, so items placed before this existed qualify too.
function gdsGui_schematic_setReshapableKind(canvasName, shapeType, componentType)
    local canvas = _findCanvas(canvasName)
    if not canvas then return end
    canvas.reshapableKind = shapeType and { shapeType = shapeType, componentType = componentType } or nil
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
    if canvas.selectionMoveModeActive then
        love.graphics.setColor(1, 0, 1, 1)
    else
        love.graphics.setColor(1, 1, 0, 1)
    end
    love.graphics.setLineWidth(width)
    _drawWirePlanSegments(plan, canvas.zoom)
end

function _pipes.setWallColor()
    local gray = globApp.themeIsDark == false and _pipes.WALL_GRAY_LIGHT or _pipes.WALL_GRAY_DARK
    love.graphics.setColor(gray, gray, gray, 1)
end

-- One wire's walls, with its selection emphasis (if any) around them.
function _pipes.drawWireWalls(canvas, w, plan)
    local pipeWidth = _WIRE_WIDTH_PX * _pipes.WIDTH_MULT * canvas.zoom
    if canvas.selectedWireId == w.id then
        _pipes.drawSelection(canvas, plan, pipeWidth + 1.6 * canvas.zoom)
    end
    _pipes.setWallColor()
    love.graphics.setLineWidth(pipeWidth)
    _drawWirePlanSegments(plan, canvas.zoom)
end

-- One bundle zone's walls, cut square half a pipe past each end so bends in a
-- bundle meet with a full corner (the walls' version of _drawWireBundleSegment).
function _pipes.drawBundleWalls(canvas, bundle)
    local half = _WIRE_WIDTH_PX * _pipes.WIDTH_MULT * canvas.zoom / 2
    local loX, hiX = math.min(bundle.x1, bundle.x2), math.max(bundle.x1, bundle.x2)
    local loY, hiY = math.min(bundle.y1, bundle.y2), math.max(bundle.y1, bundle.y2)
    _pipes.setWallColor()
    love.graphics.rectangle("fill", loX - half, loY - half, hiX - loX + half * 2, hiY - loY + half * 2)
end

--------------------------------------------------------------------------------
-- GRAVITY DIRECTION: a LIQUID pipe (connectorNoun == "PIPE" — HYDRAULIC/FUEL,
-- not a gas DUCT) can mark which way gravity drives the fluid through that
-- particular run, shown as a row of open chevrons (>) along its own center
-- pointing that way — or no chevrons at all for "none" (e.g. a run that sits
-- level, so gravity alone doesn't move anything through it). Purely a visual
-- annotation, not fed into the solver: the same "nil means automatic/unset"
-- convention as w.directionOverride, just for flow direction instead of bend
-- shape. Cycled by a plain tap once rebending/direction mode has already
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

_pipes.GRAVITY_CHEVRON_SPACING = _GRID_SPACING_PX * 2  -- world units between chevrons

-- One open ">"-shaped chevron centered at (cx,cy), pointing in unit direction
-- (dx,dy) — a 3-point polyline (never filled), so it reads as a notch across
-- the fluid rather than a solid arrowhead.
function _pipes.drawChevron(cx, cy, dx, dy, size)
    local perpX, perpY = -dy, dx
    local tipX,  tipY  = cx + dx * size * 0.5, cy + dy * size * 0.5
    local backX, backY = cx - dx * size * 0.5, cy - dy * size * 0.5
    love.graphics.line(
        backX + perpX * size * 0.45, backY + perpY * size * 0.45,
        tipX, tipY,
        backX - perpX * size * 0.45, backY - perpY * size * 0.45)
end

-- Every chevron along one wire's plan, evenly spaced along its WHOLE path
-- (the running "carry" phase below keeps the interval continuous across a
-- bend from one segment into the next) — nothing drawn at all for "none".
-- Drawn in the wall's own gray (_pipes.setWallColor) so it reads consistently
-- regardless of the fluid's own (per-source) color.
function _pipes.drawGravityChevrons(canvas, w, plan)
    local dir = w.gravityDirection
    if not dir then return end
    local pointBackward = (dir == "reverse")
    local pipeWidth = _WIRE_WIDTH_PX * _pipes.WIDTH_MULT * canvas.zoom
    local size = pipeWidth * 0.9
    local spacing = math.max(size * 2.2, _pipes.GRAVITY_CHEVRON_SPACING * canvas.zoom)
    _pipes.setWallColor()
    love.graphics.setLineWidth(math.max(1, pipeWidth * 0.35))
    local carry = spacing / 2
    for _, seg in ipairs(plan.segments) do
        local x1, y1, x2, y2 = seg[1], seg[2], seg[3], seg[4]
        local dx, dy = x2 - x1, y2 - y1
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0.001 then
            local ux, uy = dx / len, dy / len
            local pointX = pointBackward and -ux or ux
            local pointY = pointBackward and -uy or uy
            local d = carry
            while d < len do
                _pipes.drawChevron(x1 + ux * d, y1 + uy * d, pointX, pointY, size)
                d = d + spacing
            end
            carry = d - len
        end
    end
    love.graphics.setLineWidth(1)
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
        -- shapeRows: a reshaped element's wires stop at its real outline (see
        -- _shapeCells.edgePoint), and each edit stores a brand-new table.
        if se.id ~= e.id or se.x ~= e.x or se.y ~= e.y or se.rotation ~= e.rotation or se.shapeRows ~= e.shapeRows then
            changed = true
            se.id, se.x, se.y, se.rotation, se.shapeRows = e.id, e.x, e.y, e.rotation, e.shapeRows
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
           or sw.directionOverride ~= w.directionOverride
           or sw.fromTerminal ~= w.fromTerminal or sw.toTerminal ~= w.toTerminal then
            changed = true
            sw.id, sw.fromElementId, sw.toElementId, sw.directionOverride =
                w.id, w.fromElementId, w.toElementId, w.directionOverride
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
function _terminals.wireSegments(canvas, w, fromE, toE)
    local x1, y1, fromA, fromAxis = _terminals.wireEnd(canvas, fromE, w.fromTerminal)
    local x2, y2, toA, toAxis = _terminals.wireEnd(canvas, toE, w.toTerminal)
    return _terminals.segments(canvas, x1, y1, fromA, fromAxis, x2, y2, toA, toAxis, _wireForceAxis(w))
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
                local segments = _terminals.wireSegments(canvas, w, fromE, toE)
                plans[w.id] = { segments = segments, hopDistances = {}, bundledRanges = {} }
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
            local segments = _terminals.wireSegments(canvas, w, fromE, toE)
            plans[w.id] = { segments = segments, hopDistances = {}, bundledRanges = {} }
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
-- canvas at half resolution (_glow.capture), which is blurred with a
-- separable Gaussian shader and added over the schematic once per frame
-- (_glow.finish) — a real blur, so overlapping wires and corners stay
-- smooth instead of stacking into blocks.
--------------------------------------------------------------------------------

_glow.SCALE = 0.5        -- offscreen glow resolution, relative to the screen
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
        _glow.canvasA = love.graphics.newCanvas(w, h)
        _glow.canvasB = love.graphics.newCanvas(w, h)
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

-- Start of a schematic canvas's frame: clears the offscreen glow buffer.
function _glow.begin(canvas)
    if not canvas.glow then return end
    canvas.glow.active = _glow.ensureResources()
    if not canvas.glow.active then return end
    local st = _glow.saveState()
    love.graphics.setCanvas(_glow.canvasA)
    -- clear() honors the scissor: with the canvas's screen-space scissor
    -- still set, part of this half-size buffer was never cleared, and the
    -- blur kept smearing last frame's glow across it.
    love.graphics.setScissor()
    love.graphics.clear(0, 0, 0, 0)
    _glow.restoreState(st)
end

-- Draws drawFn() (an item's bare shape, already in its own glow color) into
-- the offscreen glow buffer instead of the screen.
function _glow.capture(drawFn)
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
end

-- End of the canvas's frame: blurs the buffer and adds it over the canvas
-- (clipped to the canvas's own rect).
function _glow.finish(canvas)
    if not canvas.glow or not canvas.glow.active then return end
    canvas.glow.active = false
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
end

-- Glow source for a wire: its own path, a little wider than the wire.
function _glow.wire(plan, zoom, wireWidth, r, g, b)
    _glow.capture(function()
        love.graphics.setColor(r, g, b, 1)
        love.graphics.setLineWidth(wireWidth * _glow.WIRE_WIDTH)
        _drawWirePlanSegments(plan, zoom)
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

local function _drawWire(canvas, w, plan, signature)
    if not plan then return end
    local wireWidth = _WIRE_WIDTH_PX * canvas.zoom
    if canvas.selectedWireId == w.id and not canvas.pipeConnectors then
        -- Same yellow/magenta selection emphasis as an element's outline
        -- (see its comment on gdsGui_schematic_update's long-press timer),
        -- drawn as a wider line underneath so it reads as a highlight
        -- around the wire. A pipe draws its own with its walls instead.
        _pipes.drawSelection(canvas, plan, wireWidth + 2.4 * canvas.zoom)
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
            for idx, seg in ipairs(plan.segments) do
                _drawSegmentWithHopsAndGaps(seg[1], seg[2], seg[3], seg[4], plan.hopDistances[idx], plan.bundledRanges[idx], canvas.zoom,
                    function(ax, ay, bx, by)
                        if ax > bx or ay > by then ax, ay, bx, by = bx, by, ax, ay end
                        _drawWireBundleSegment(canvas, ax, ay, bx, by, colors, isHalo)
                        setArcColor()
                    end)
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
        if _glow.applies(canvas, r, g, b) then _glow.wire(plan, canvas.zoom, wireWidth, r, g, b) end
        love.graphics.setColor(r, g, b, a)
        love.graphics.setLineWidth(wireWidth)
        _drawWirePlanSegments(plan, canvas.zoom)
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
        -- Same yellow/magenta selection emphasis as an element's outline —
        -- see its comment (including the half-opacity magenta).
        if canvas.selectionMoveModeActive then
            love.graphics.setColor(1, 0, 1, 0.5)
        else
            love.graphics.setColor(1, 1, 0, 1)
        end
        -- Square, not round — controls are sized in square grid units (see
        -- gdsGui_schematic_armControlPlacement's gridSize), so a square
        -- selection box reads as "this many grid squares" the same way an
        -- element's own rectangular footprint does.
        love.graphics.rectangle("line", cx - drawHalf, cy - drawHalf, drawHalf * 2, drawHalf * 2)
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
                love.graphics.circle("fill", tx, ty, rad)
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

    for _, canvas in ipairs(globApp.objects.schematics) do
        if canvas.page == pageName then
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
                for _, w in ipairs(canvas.wires) do
                    local plan = wirePlans[w.id]
                    if plan and wireVisible(plan) then _pipes.drawWireWalls(canvas, w, plan) end
                end
                for _, bundle in ipairs(wireBundles) do
                    local loX, hiX = math.min(bundle.x1, bundle.x2), math.max(bundle.x1, bundle.x2)
                    local loY, hiY = math.min(bundle.y1, bundle.y2), math.max(bundle.y1, bundle.y2)
                    if rectVisible(loX, loY, hiX - loX, hiY - loY) then _pipes.drawBundleWalls(canvas, bundle) end
                end
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
            -- Gravity-direction chevrons (see _pipes.drawGravityChevrons):
            -- drawn in their own pass, after both the per-wire fluid lines
            -- AND the bundle color bands above, so a chevron on a stretch
            -- shared with another pipe (bundled) still shows on top instead
            -- of being painted over by that later bundle-band pass.
            if _pipes.isLiquid(canvas) then
                for _, w in ipairs(canvas.wires) do
                    local plan = wirePlans[w.id]
                    if plan and wireVisible(plan) then _pipes.drawGravityChevrons(canvas, w, plan) end
                end
            end
            for _, e in ipairs(canvas.elements) do
                local ex, ey, ew, eh = _elementFootprintRect(canvas, e)
                if rectVisible(ex, ey, ew, eh) then _drawElement(canvas, e, signature) end
            end
            for _, c in ipairs(canvas.controls) do
                local ccx, ccy = _toPixel(canvas, c.x, c.y)
                local crad = canvas.controlRadius * canvas.zoom * (c.radiusScale or 1)
                if not c.hidden and rectVisible(ccx - crad, ccy - crad, crad * 2, crad * 2) then _drawControl(canvas, c, signature) end
            end
            _glow.finish(canvas)
            _drawAnnunciators(canvas)
            drawAiCulpritHighlight(canvas)

            if canvas.wireTool.fromId then
                local fromE = _findAnchor(canvas, canvas.wireTool.fromId)
                if fromE and canvas.wireTool.curX then
                    local snapTarget, snapTerminal = _connectorSnapTarget(canvas)
                    _drawConnectorTargets(canvas, snapTarget, snapTerminal)
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
            -- even reaches the "NAME THIS..." prompt. pendingPlacement
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
                canvas.wireTool.fromTerminal = (_hitControl(canvas, x, y) == fromAnchor)
                    and _terminals.nearest(canvas, fromAnchor, x, y) or nil
            end
            goto continue
        end

        -- Reshape mode's corner handles straddle the shape's outline, and an
        -- outward pull starts on them, so they're checked ahead of any hit-test.
        local reshapeTarget = _shapeCells.activeTarget(canvas)
        if reshapeTarget and not (canvas.wireToolActive or canvas.pendingConnectorColor) then
            local corner = _shapeCells.cornerAt(canvas, reshapeTarget, x, y)
            if corner then
                canvas.focusTouchId = touchId
                canvas.dragKind     = "reshape"
                canvas.dragStartX   = x
                canvas.dragStartY   = y
                canvas.dragMoved    = false
                canvas._pendingDragUndoSnapshot = _snapshotState(canvas)
                _shapeCells.beginDrag(canvas, reshapeTarget, corner)
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
                -- next tap enters reshape (dragging nothing until a corner
                -- handle is pressed), and a tap on its body, off every handle
                -- (see the check above), comes back around to move.
                if canvas.rotateModeActive and _shapeCells.allowed(canvas, hitElem) then
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

        if canvas.wireTool.fromId then
            canvas.wireTool.curX = x
            canvas.wireTool.curY = y
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
        elseif canvas.dragKind == "reshape" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem and canvas._shapeDrag and _shapeCells.updateDrag(canvas, elem, x, y) and not canvas.dragMoved then
                canvas.dragMoved = true
                if canvas._pendingDragUndoSnapshot then
                    _commitUndoSnapshot(canvas, canvas._pendingDragUndoSnapshot)
                    canvas._pendingDragUndoSnapshot = nil
                end
            end
        elseif canvas.dragKind == "element" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem then
                local fracX, fracY = _toFraction(canvas, x - canvas.dragOffsetX, y - canvas.dragOffsetY)
                local candX, candY = _snapElementToGrid(canvas, fracX, fracY, elem.w, elem.h)
                -- Elements (unlike wires — see _footprintOverlapsAnother's
                -- own comment) can never overlap: simply don't apply the
                -- candidate position at all when it would, so the element
                -- just stops following the finger right at the obstacle's
                -- edge instead of passing through it.
                local px, py = _toPixel(canvas, candX, candY)
                local pw, ph = elem.w * canvas.contentW * canvas.zoom, elem.h * canvas.contentH * canvas.zoom
                if _isQuarterTurnRotation(elem.rotation) then pw, ph = ph, pw end
                local blocked, obstacle
                if elem.shapeRows then
                    local p = _shapeCells.parse(elem.shapeRows)
                    local bw, bh = elem.w * canvas.contentW * canvas.zoom, elem.h * canvas.contentH * canvas.zoom
                    blocked, obstacle = _shapeCells.blockedAt(canvas, elem, p, px + bw / 2, py + bh / 2,
                        bw / p.cols, bh / p.rows, elem.rotation)
                else
                    blocked, obstacle = _footprintOverlapsAnother(canvas, px + pw / 2, py + ph / 2, pw / 2, ph / 2, elem.id)
                end
                -- Flags the obstacle actually in the way so _drawElement/
                -- _drawControl can highlight it red for as long as the drag
                -- keeps pushing into it — cleared the instant it's clear
                -- again (nil obstacle) or the gesture ends (gdsGui_schematic_
                -- released's own cleanup).
                canvas.collidingObstacleId = obstacle and obstacle.id or nil
                if not blocked then
                    elem.x, elem.y = candX, candY
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
        elseif canvas.dragKind == "rotate" and canvas.selectedElementId then
            local elem = _findElement(canvas, canvas.selectedElementId)
            if elem and _shapeCells.allowed(canvas, elem) then
                -- Any angle, not just the 4 cardinals — which also means a
                -- tap's own finger jitter would turn it, so nothing applies
                -- until the press has become a real drag. Off-cardinal angles
                -- rely on the cell-based hit/collision/wire paths, so its
                -- shape is made explicit here (it looks the same either way).
                if canvas.dragMoved or math.abs(x - canvas.dragStartX) > _ELEMENT_TAP_SLOP_PX or
                   math.abs(y - canvas.dragStartY) > _ELEMENT_TAP_SLOP_PX then
                    local cx, cy = _elementCenter(canvas, elem)
                    local rawAngle = math.atan2(y - cy, x - cx) - canvas.rotateGrabAngleOffset
                    local candRotation = _shapeCells.freeRotationDegrees(rawAngle)
                    elem.shapeRows = _shapeCells.rowsOf(canvas, elem)
                    local _, _, cw, ch, p = _shapeCells.frame(canvas, elem)
                    if not _shapeCells.blockedAt(canvas, elem, p, cx, cy, cw, ch, candRotation) then
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
            if canvas.dragKind == "paint" then
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
                local limitNotice = toElem and (twoTerminalAnchorAtWireLimit(canvas, canvas.wireTool.fromId, fromTerminal)
                    or twoTerminalAnchorAtWireLimit(canvas, toElem.id, toTerminal))
                if toElem then
                    if limitNotice then
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
                    gdsGui_haptics_vibrate()
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
        local holdSeconds = (holdElem and _shapeCells.allowed(canvas, holdElem)) and _shapeCells.HOLD_SECONDS or _LONG_PRESS_SECONDS
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
        _galleryImageCache[path] = love.graphics.newImage(path)
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
        elseif e.shapeRows then
            love.graphics.push()
            love.graphics.translate(ex + ew / 2, ey + eh / 2)
            love.graphics.rotate(math.rad(e.rotation or 0))
            _shapeCells.drawLocal(e, ew, eh, c[1], c[2], c[3], c[4], 0)
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
