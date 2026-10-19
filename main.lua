-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[ Main.lua
    Author: Jonathan Pazmino
    Description: Core entry file for LÖVE app with timer and GUI integration
]]

-------------------------------------------------------------------------------
-- LIBRARIES LOAD
-------------------------------------------------------------------------------
require("Libraries.gds_love2d_gui.loader_gdsGuiLib")

APP_VERSION = "1.0.18"

-- Original orientation the app was designed for; used by the GUI library to
-- establish the reference container width at first finalize (portrait = 1 col).
globApp.appOriginalOrientation = "portrait"

-- Create base pages
globApp.appColor = {.2, .2, .2, 1} --initializes bg color
gdsGui_page_create(3, "MainMenu",           false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(4, "TermsAndConditions", false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(5, "Learn",              false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(6, "Settings",           false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(7, "SystemSchematic",    false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(8, "SchematicPaywall",   false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(9, "SchematicHome",          false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(10, "SchematicFullScreen",   false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(11, "SchematicManageGallery", false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(12, "AircraftGallery",        false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")

-------------------------------------------------------------------------------
-- GLOBAL STATE
-------------------------------------------------------------------------------
local utc = {}
local lastUtcMin = -1
local lastSavedCountDownTime = 0
local font

-- Pre-defined colors to avoid creating tables in love.update
local colorYellow  = {1, 1, 0, 1}
local colorWarning = {1, 0.55, 0, 1}

-- Timer object
local timer = {
    mode = "COUNT UP",   -- Options: "COUNT UP" or "COUNT DOWN"
    duration = 90,       -- Default countdown duration (in seconds)
    t = 0,               -- Current timer value (in seconds)
    running = false      -- Timer running state
}

local dutyMaxHours    = 1    -- 1–20 hrs
local dutyStartMins   = 0    -- total minutes from 00:00Z (0–1435, 5-min steps)
local lastFlightHours = 0.0  -- 0.0–18.0 in 0.1-hr steps

-- Dirty-flag sentinels: values that can never match real state on first frame.
local _prevTimerT        = -1
local _prevTimerMode     = ""
local _prevAltitude      = -1
local _prevTime          = -1
local _prevDegree        = -1e9
local _prevWindDir       = -1
local _prevWindSpeed     = -1
local _prevWindGust      = -1
local _prevKnobPos       = -1
local _prevDutyMaxHours    = -1
local _prevDutyStartMins   = -1
local _prevLastFlightHours = -1e9

-- Countdown finished blink state
local blink = {active = false, timer = 0, state = false, navSent = false, navigatingToMain = false}

-- True once the user has scrolled to the bottom of the T&C text at least once.
local _tcScrolledToBottom = false

-- Alarm sound (double chime) and settings feedback sound (single chime)
local beepSound
local singleChimeSound

-- Ack button images loaded separately so they can be drawn as an overlay on top
local _ackReleasedImg
local _ackPushedImg

-- App settings (persisted across sessions): loaded from appSettings.lua if it exists
appSettings = {}

-- Keeps globApp.skipPageLoadingScreens (gdsGui_page_switch's "land instantly,
-- no loading-page wait" switch — see pages_gdsGuiLib.lua) in sync with the
-- paid-feature entitlement flag: once System Schematic is unlocked, every
-- page transition in the whole app becomes instant. Called everywhere
-- appSettings.schematicUnlocked can change value (initial load, Simulate
-- Purchase, the unit-test restore, and a data erase).
local function _syncPaidLoadingScreenSkip()
    globApp.skipPageLoadingScreens = (appSettings.schematicUnlocked == true)
end

-- System Schematic (premium feature): a named collection of AIRCRAFT, each
-- owning its own named SYSTEMS (schematicStore.aircraft[].systems), each
-- system its own elements/wires/controls/snapshot-rules. currentAircraftId
-- tracks which aircraft the user is "inside" (its systems gallery);
-- currentSystemId tracks which of that aircraft's systems is currently
-- loaded into the live "mainCanvas" (nil when the canvas page hasn't been
-- opened this session). Loaded/migrated/seeded in love.load(), persisted via
-- the same table.show()/loadFileContents() round trip as appSettings, into
-- schematicProjects.lua.
schematicStore = nil

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------


-- Syncs all footer nav buttons so the button matching activeDest is PRESSED
-- and all others are RELEASED, across every page that has a footer. Any page
-- inside the System Schematic flow (aircraft gallery, the systems gallery —
-- which doubles as "opening an aircraft" now, no separate home page in
-- between — the canvas itself) keeps the schematic dock icon pressed.
local function _navSyncAll(activeDest)
    local schematicFlow = (activeDest == "SystemSchematic" or activeDest == "SchematicHome"
        or activeDest == "SchematicManageGallery" or activeDest == "AircraftGallery")
    for _, pfx in ipairs({"mainMenu", "schematic", "schematicHome", "schematicManage",
        "aircraftGallery", "learn", "settings"}) do
        gdsGui_button_setState(pfx .. "_navMainMenu",  activeDest == "MainMenu" and "pushed" or "released")
        gdsGui_button_setState(pfx .. "_navSchematic", schematicFlow and "pushed" or "released")
        gdsGui_button_setState(pfx .. "_navLearn",     activeDest == "Learn"    and "pushed" or "released")
        gdsGui_button_setState(pfx .. "_navSettings",  activeDest == "Settings" and "pushed" or "released")
    end
end

-- Format seconds into mm:ss
function format_time(s)
    if s < 0 then s = 0 end
    local minutes = math.floor(s / 60)
    local seconds = math.floor(s % 60)
    return string.format("%02d:%02d", minutes, seconds)
end

local _THEME_DARK = {
    app         = {0.20, 0.20, 0.20, 1},
    bg          = {0.18, 0.18, 0.18, 1},
    header      = {0.25, 0.25, 0.25, 1},
    border      = {0.35, 0.35, 0.35, 1},
    text        = {1.00, 1.00, 1.00, 1},
    progressBar = {1.00, 1.00, 0.00, 1},
    canvasBg    = {0.10, 0.10, 0.12, 1},
    canvasGrid  = {1.00, 1.00, 1.00, 0.06},
}
local _THEME_LIGHT = {
    app         = {0.88, 0.88, 0.88, 1},
    bg          = {0.82, 0.82, 0.82, 1},
    header      = {0.72, 0.72, 0.72, 1},
    border      = {0.55, 0.55, 0.55, 1},
    text        = {0.05, 0.10, 0.25, 1},
    progressBar = {0.05, 0.10, 0.40, 1},
    canvasBg    = {0.80, 0.80, 0.83, 1},
    canvasGrid  = {0.00, 0.00, 0.00, 0.08},
}

-- Learn textbox segment data (text + subtitle flag; colors resolved per theme).
local _LEARN_TIMER_RAW = {
    {text="UTC CLOCK", sub=true},
    {text="Current UTC time is displayed in the Main Menu header in HHMM UTC format (e.g. 2359 UTC), always visible regardless of scroll position. Updates each minute. Sourced from the device system clock; verify against a certified time source for time-critical operations.\n"},
    {text="NAVIGATION", sub=true},
    {text="Use the tab bar at the bottom to switch between Main Menu, Learn, and Settings.\n"},
    {text="TIMER MODE", sub=true},
    {text="Press the mode button to switch between COUNT UP and COUNT DOWN.\n"},
    {text="COUNT DOWN", sub=true},
    {text="Use the +/- buttons to set minutes (left pair) and seconds (right pair). Press play/pause to start. The app navigates here automatically 3 seconds before zero. Alarm sounds and the screen flashes red at zero. Press ACK to dismiss. The alarm requires the app to be open and in the foreground. The device silent switch, Focus/Do Not Disturb mode, and low volume settings can prevent the alarm from sounding.\n"},
    {text="COUNT UP", sub=true},
    {text="Press play/pause to start counting from zero.\n"},
    {text="RESET", sub=true},
    {text="Stops the timer. In COUNT DOWN, returns to the last set time. In COUNT UP, returns to zero."},
}
local _LEARN_WIND_RAW = {
    {text="CROSSWIND CALCULATOR", sub=true},
    {text="Calculates headwind and crosswind components from runway heading and wind data.\n"},
    {text="RUNWAY HEADING", sub=true},
    {text="Rotate the outer knob ring to select runway (RWY 01-36) one increment at a time.\n"},
    {text="WIND DIRECTION", sub=true},
    {text="Rotate the inner knob ring to set reported wind direction in 10 degree steps (010-360).\n"},
    {text="WIND SPEED", sub=true},
    {text="Left scrollbar sets steady wind speed from 0 to 45 kt.\n"},
    {text="WIND GUST", sub=true},
    {text="Right scrollbar sets gust speed. Range adjusts dynamically from current speed up to 60 kt.\n"},
    {text="RESULT", sub=true},
    {text="Shows runway, sustained crosswind and headwind/tailwind components. When a gust is set, also shows gust crosswind components and gust factor.\n"},
    {text="AIRCRAFT LIMITS", sub=true},
    {text="Compare results against your aircraft's AFM/POH maximum crosswind component. This calculator has no knowledge of your aircraft type or its published limitations."},
}
local _LEARN_CALC_RAW = {
    {text="ASCENT / DESCENT CALCULATOR", sub=true},
    {text="Calculates required vertical rate and start-of-descent distance.\n"},
    {text="TIME", sub=true},
    {text="Left scrollbar sets time to change altitude (0-25 min).\n"},
    {text="ALTITUDE", sub=true},
    {text="Center scrollbar sets altitude change (0-51,000 ft in 1,000 ft steps).\n"},
    {text="ANGLE", sub=true},
    {text="Right scrollbar sets desired descent angle (0-8.00 degrees in 0.25 degree steps).\n"},
    {text="RESULTS", sub=true},
    {text="REQ FPM — required vertical rate in feet per minute.\nREQ DIST — start-of-descent distance in nautical miles.\n"},
    {text="ASSUMPTIONS", sub=true},
    {text="REQ DIST assumes constant groundspeed. Actual distance varies with wind and aircraft configuration. Verify against your aircraft's performance charts."},
}
local _LEARN_DUTY_RAW = {
    {text="FOR REFERENCE ONLY", sub=true},
    {text="This calculator uses a simplified single-flight model. It does not substitute for applicable duty and rest regulations, your operator's operations specifications, or company fatigue policies. Always verify against the regulations and ops specs governing your operation.\n"},
    {text="DUTY / FLIGHT TIME", sub=true},
    {text="Calculates the latest departure time that keeps your last flight within the duty period.\n"},
    {text="DUTY START", sub=true},
    {text="Scrollbar sets when the duty period begins in UTC (00:00Z – 23:55Z in 5-minute steps).\n"},
    {text="MAX DUTY", sub=true},
    {text="Scrollbar sets the maximum allowed duty period length (1 – 20 hours).\n"},
    {text="LAST FLT BLOCK TIME", sub=true},
    {text="Scrollbar sets the expected block time of the last flight (0.0 – 18.0 hours in 0.1-hour steps).\n"},
    {text="DUTY OUT", sub=true},
    {text="Shows the end of the duty period: Duty Start + Max Duty.\n"},
    {text="DEPART BY", sub=true},
    {text="Latest UTC time to depart so the last flight lands before duty out: Duty Out − Last Flt Block Time."},
}
local _LEARN_SETTINGS_RAW = {
    {text="ACCESS", sub=true},
    {text="Tap the gear icon in the navigation bar to open Settings.\n"},
    {text="DARK / LIGHT MODE", sub=true},
    {text="Toggle between dark background with white text and light background with dark text. Your preference is saved between sessions.\n"},
    {text="TIMER SOUND", sub=true},
    {text="Enable or disable the beep that sounds when the countdown timer reaches zero.\n"},
    {text="HAPTICS", sub=true},
    {text="Enable or disable vibration on button taps and at timer alarm.\n"},
    {text="FONT SIZE", sub=true},
    {text="Drag the scrollbar to set the display font size between 12 pt and 16 pt. The change is applied immediately and saved between sessions."},
}

local function _learnSegsColored(rawSegs, isDark)
    local sc = isDark and {1, 0, 0, 1}          or {0.00, 0.12, 0.40, 1}
    local bc = isDark and {1, 1, 1, 1}          or {0.20, 0.20, 0.20, 1}
    local out = {}
    for _, s in ipairs(rawSegs) do
        out[#out+1] = {text=s.text, color=s.sub and sc or bc}
    end
    return out
end

local function _saveAppSettings()
    love.filesystem.write("appSettings.lua", table.show(appSettings, "appSettings"))
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC HELPERS (premium feature)
-- Thin aviation-specific wrappers over the generic schematic_gdsGuiLib.lua
-- primitives, plus the multi-project persistence round trip (schematicProjects.lua).
-------------------------------------------------------------------------------

-- Catalog for the design-mode "ADD" cascading menu: SYSTEM -> TYPE -> (for
-- controls with more than one position preset) -> POSITION SET. Aviation
-- naming lives here, not in the generic schematic_gdsGuiLib.lua module.
-- connectorColor (per system, not per item): wires are no longer a
-- placeable catalog item — ADD WIRE on an element's own edit menu is now
-- the only way to draw one (see gdsGui_schematic_internal_onElementEditChosen)
-- — but new wires should still come out pre-colored by system rather than
-- a flat gray, so this is threaded into the canvas instead (see
-- _openSystemIntoCanvas -> gdsGui_schematic_setDefaultConnectorColor).

-- Shared by every binary (2-position) switch/valve control below: index 1
-- (the "off"/blocked/non-conducting position, always listed first in that
-- control's own presets) gets the open/disconnected-looking icon, index 2
-- (the "on"/flowing/conducting position) gets the closed/connected-looking
-- one — true for every one of these presets even though the words differ
-- (a SWITCH's OFF vs a VALVE's CLOSED), since what's actually drawn tracks
-- MEANING (does current/fluid flow through it), not the position's name. Not
-- used for MODE SWITCH (AUTO/MANUAL) — that's a mode selector, not a
-- connected/disconnected state, so these icons wouldn't read correctly
-- there. A 3-position preset (SWITCH's OFF/ON/STBY) just has no 3rd entry,
-- falling back to the plain vector icon for STBY only (see
-- gdsGui_schematic_addControl's spritePaths param).
local _SWITCH_SPRITE_PATHS = {"Sprites/control_switchOpen.png", "Sprites/control_switchClosed.png"}

-- A generator's housing is the same icon for OFF and ON (unlike a SWITCH's
-- open/closed pair above, which has a distinct icon per position) — the gear
-- overlay spinning in control mode (see gdsGui_schematic_addControl's
-- overlaySpritePath) is what shows it's live, not a change of base icon.
local _GENERATOR_SPRITE_PATHS = {"Sprites/control_generatorHousing.png", "Sprites/control_generatorHousing.png"}
local _GENERATOR_OVERLAY_SPRITE_PATH = "Sprites/control_generatorGear.png"

local SCHEMATIC_CATALOG = {
    { system = "ELECTRICAL", connectorColor = {0.85, 0.75, 0.15, 1}, items = {
        -- colorDarkenMul 0.8 * 0.85: matches schematic_gdsGuiLib.lua's
        -- _ELEMENT_DARKEN (the blanket darken every element, BATTERY
        -- included, already gets) so the GENERATOR housing reads exactly
        -- as dark as BATTERY's own sprite instead of staying undarkened
        -- like every other control.
        { label = "GENERATOR", kind = "control", presets = { {"OFF", "ON"} },
          spritePaths = _GENERATOR_SPRITE_PATHS, overlaySpritePath = _GENERATOR_OVERLAY_SPRITE_PATH,
          colorDarkenMul = 0.8 * 0.85 },
        -- matchControlSize: same on-screen footprint as a freshly-placed
        -- GENERATOR control (see gdsGui_schematic_armElementPlacement's own
        -- comment for the exact formula), rather than the shared default
        -- element size every other rect/circle item here still uses.
        { label = "BATTERY",   kind = "element", shapeType = "rect", matchControlSize = true,
          defaultProperties = {"VOLTAGE", "CURRENT"}, spritePath = "Sprites/element_battery.png" },
        { label = "BUS",       kind = "element", shapeType = "rect",
          defaultProperties = {"VOLTAGE", "CURRENT"}, spritePath = "Sprites/element_bus.png" },
        -- sizeMul 7/30: the diode symbol reads oversized at the shared
        -- default element size (1/3), shrunk a further 30% on top of that.
        { label = "DIODE",     kind = "element", shapeType = "diode", spritePath = "Sprites/element_diode.png",
          sizeMul = 7 / 30 },
        -- radiusMul 0.7: shrunk 30% from the shared default control size.
        { label = "SWITCH",    kind = "control", presets = { {"OFF", "ON"}, {"OFF", "ON", "STBY"} },
          spritePaths = _SWITCH_SPRITE_PATHS, radiusMul = 0.7 },
    }},
    { system = "HYDRAULIC", connectorColor = {0.15, 0.45, 0.85, 1}, items = {
        { label = "PUMP",         kind = "element", shapeType = "circle" },
        { label = "VALVE",        kind = "element", shapeType = "circle" },
        { label = "RESERVOIR",    kind = "element", shapeType = "circle" },
        { label = "VALVE SWITCH", kind = "control", presets = { {"CLOSED", "OPEN"} },
          spritePaths = _SWITCH_SPRITE_PATHS },
    }},
    { system = "FUEL", connectorColor = {0.75, 0.35, 0.1, 1}, items = {
        { label = "FUEL TANK",   kind = "element", shapeType = "circle" },
        { label = "FUEL PUMP",  kind = "element", shapeType = "circle" },
        { label = "FUEL SWITCH", kind = "control", presets = { {"OFF", "ON"} }, spritePaths = _SWITCH_SPRITE_PATHS },
    }},
    { system = "BLEED AIR", connectorColor = {0.85, 0.5, 0.15, 1}, items = {
        { label = "BLEED VALVE", kind = "element", shapeType = "circle" },
        { label = "BLEED SWITCH", kind = "control", presets = { {"OFF", "ON"} }, spritePaths = _SWITCH_SPRITE_PATHS },
    }},
    { system = "PRESSURIZATION", connectorColor = {0.55, 0.3, 0.75, 1}, items = {
        { label = "OUTFLOW VALVE", kind = "element", shapeType = "circle" },
        { label = "CONTROLLER",    kind = "element", shapeType = "rect",
          defaultProperties = {"CABIN ALT", "RATE"} },
        { label = "MODE SWITCH",   kind = "control", presets = { {"AUTO", "MANUAL"} } },
    }},
}

-- Every system is locked to exactly one of these types for its whole
-- lifetime, and an aircraft has at most one system per type — the systems
-- gallery shows a tile for every catalog type whether or not it's been
-- created yet (see _systemGalleryItems) — SCHEMATIC_CATALOG is the single
-- source of truth for which types exist and what each one's ADD ELEMENT/
-- CONTROL catalog offers.
local function _findCatalogEntryForType(systemType)
    for _, sys in ipairs(SCHEMATIC_CATALOG) do
        if sys.system == systemType then return sys end
    end
    return nil
end

-- "Bleed Air" from "BLEED AIR", for a friendlier default system name.
local function _titleCase(s)
    local words = {}
    for word in s:gmatch("%S+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2):lower())
    end
    return table.concat(words, " ")
end

-- App-layer state for the in-progress cascading menu / control-select flow
-- (menu selection and placement itself are handled inside the library; this
-- only remembers which catalog branch / control a prior menu level chose).
local _catalogChosenSystem      = nil
local _catalogChosenControlItem = nil
local _controlMenuIds           = {}
local _controlMenuSelectedId    = nil
local _pendingSnapshotPlan      = nil

-- Which aircraft/system a gallery's open "manage" action menu (or the rename
-- prompt it leads to) refers to. Two separate trackers since the aircraft
-- gallery (AircraftGallery) and the systems-within-an-aircraft gallery
-- (SchematicManageGallery) are different screens with different menus.
local _manageMenuAircraftId = nil
local _manageMenuSystemId   = nil

-- Control-mode "full screen" viewing: mainCanvas is reassigned onto its own
-- dedicated page (no header/footer/dock to crowd the view) and resized to
-- fill it, then handed back to its normal embedded layout on return. The
-- normal layout is captured once at creation time (see love.load() below)
-- since schCanvasYFrac/schCanvasHFrac are local to that function.
local _schematicFullScreen        = false
local _schematicCanvasNormalLayout = nil
-- The wider layout the embedded canvas progressively grows into as zoom
-- increases past 1x (see gdsGui_schematic_setZoomedLayout) — full screen
-- width, same height as the normal layout. Captured once at creation time
-- alongside _schematicCanvasNormalLayout for the same reason (schCanvasYFrac/
-- schCanvasHFrac are local to love.load()), and reapplied by
-- schematicFullScreenReturnPressed() since schematicFullScreenTogglePressed()
-- clears it (the full-screen page is already at its maximum, so zooming in
-- there has nothing further to expand into).
local _schematicCanvasZoomedLayout = nil
local _prevSchematicZoomText = nil
local _schematicZoomFullScreenFont = nil

-- Sentinels for the combination-readout poll in love.update() below (see
-- "Schematic combination readout") — same dirty-flag-rendering convention as
-- _prevSchematicZoomText above: only pushes a widget update when the
-- underlying value actually changed.
local _prevSchematicCombText        = nil
local _prevSchematicCombHasSnapshot = nil
local _prevSchematicCombCanCycle    = nil
local _prevSchematicCombHidden      = nil

-- Backing cache for _schematicCombControlsChanged below — reused across
-- frames (mutated in place, never reallocated) so detecting "nothing
-- relevant changed" costs no garbage, only a per-control scalar compare.
local _schematicCombCache      = {}
local _schematicCombCacheValid = false
local _schematicCombLastSystemId = nil
local _schematicCombIndex, _schematicCombTotal, _schematicCombSig = 1, 1, ""

-- gdsGui_schematic_getCombinationIndex/computeSignature each re-sort
-- canvas.controls from scratch (see _sortedControls/buildSignature in the
-- library) — fine for the occasional call, wasteful for this readout, which
-- polls every frame because there's no single discrete event to push from
-- (see the call site below). This detects whether anything that index/
-- signature actually depend on — a control's id/detentIndex/numDetents, or
-- having switched to a different system entirely — changed since the last
-- frame, purely by comparing values (not by hunting down every place
-- canvas.controls can be mutated: add/remove, undo, clear-page, reload all
-- fall out of this automatically). Deliberately NOT extended to cover
-- canvas.snapshots/hasSnapshot — that can change (a capture) without any
-- control changing, and the lookup itself is already O(1), so it's left to
-- run fresh every frame off of whichever signature this returns.
local function _schematicCombControlsChanged(canvas)
    local changed = not _schematicCombCacheValid
    if schematicStore.currentSystemId ~= _schematicCombLastSystemId then
        changed = true
        _schematicCombLastSystemId = schematicStore.currentSystemId
    end
    if #_schematicCombCache ~= #canvas.controls then changed = true end
    for i, c in ipairs(canvas.controls) do
        local cached = _schematicCombCache[i]
        if not cached then cached = {}; _schematicCombCache[i] = cached end
        if cached.id ~= c.id or cached.detentIndex ~= c.detentIndex or cached.numDetents ~= c.numDetents then
            changed = true
            cached.id, cached.detentIndex, cached.numDetents = c.id, c.detentIndex, c.numDetents
        end
    end
    for i = #canvas.controls + 1, #_schematicCombCache do _schematicCombCache[i] = nil end
    _schematicCombCacheValid = true
    return changed
end
local _prevSchematicSnapshotCount   = nil
local _prevSchematicPaintActive     = nil
local _prevSchematicAddBtnEnabled   = nil
local _prevSchematicAnnunciatorPanelOpen = nil

local function _findSchematicCanvas()
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "mainCanvas" then return c end
    end
    return nil
end

local function _findAircraft(aircraftId)
    for _, a in ipairs(schematicStore.aircraft) do
        if a.id == aircraftId then return a end
    end
    return nil
end

local function _findCurrentAircraft()
    return schematicStore.currentAircraftId and _findAircraft(schematicStore.currentAircraftId) or nil
end

-- Aircraft "type" thumbnails offered at creation time (see
-- schematicNewAircraftConfirmed below) — required so every aircraft tile in
-- the gallery shows a recognizable icon instead of a blank box. Only the
-- short key is persisted on the aircraft record (aircraft.thumbnail); the
-- generic schematicGallery widget just wants an image path (see
-- _aircraftGalleryItems), not this domain-specific naming.
local AIRCRAFT_THUMBNAILS = {
    { key = "helicopter", label = "HELICOPTER", path = "Sprites/aircraftThumb_helicopter.png" },
    { key = "jet",        label = "JET",        path = "Sprites/aircraftThumb_jet.png" },
    { key = "propeller",  label = "PROP PLANE",  path = "Sprites/aircraftThumb_propeller.png" },
}

local function _aircraftThumbnailPath(key)
    for _, t in ipairs(AIRCRAFT_THUMBNAILS) do
        if t.key == key then return t.path end
    end
    return nil
end

-- Maps schematicStore.aircraft into the aircraftGallery's item list, adding
-- a resolved thumbnailPath per item without polluting the persisted aircraft
-- record with a derived/absolute-ish path.
local function _aircraftGalleryItems()
    local items = {}
    for _, aircraft in ipairs(schematicStore.aircraft) do
        local item = {}
        for k, v in pairs(aircraft) do item[k] = v end
        item.thumbnailPath = _aircraftThumbnailPath(aircraft.thumbnail)
        table.insert(items, item)
    end
    return items
end

-- Systems are scoped to the current aircraft — a system id only has to be
-- unique within its own aircraft's systems list.
local function _findSystem(systemId)
    local aircraft = _findCurrentAircraft()
    if not aircraft then return nil end
    for _, s in ipairs(aircraft.systems) do
        if s.id == systemId then return s end
    end
    return nil
end

-- Per-systemType gallery tile thumbnail, keyed by SCHEMATIC_CATALOG's own
-- system names (not a separate chosen-at-creation field like a aircraft's
-- thumbnail — a system's type already fully determines its icon). A
-- systemType with no entry here just falls back to the gallery's default
-- elements/wires mini-diagram preview (see _drawGalleryTilePreview in
-- schematic_gdsGuiLib.lua). pressedPath (optional): swapped in for the
-- brief span a tile is actually held down, same released/pressed sprite-
-- pair convention a real button uses (see gallery.pressedTileIndex).
local SYSTEM_THUMBNAILS = {
    ELECTRICAL = { path = "Sprites/systemThumb_electrical_released.png",
                   pressedPath = "Sprites/systemThumb_electrical_pressed.png" },
    HYDRAULIC  = { path = "Sprites/systemThumb_hydraulic_released.png",
                   pressedPath = "Sprites/systemThumb_hydraulic_pressed.png" },
    FUEL       = { path = "Sprites/systemThumb_fuel_released.png",
                   pressedPath = "Sprites/systemThumb_fuel_pressed.png" },
    ["BLEED AIR"] = { path = "Sprites/systemThumb_bleedAir_released.png",
                       pressedPath = "Sprites/systemThumb_bleedAir_pressed.png" },
    PRESSURIZATION = { path = "Sprites/systemThumb_pressurization_released.png",
                        pressedPath = "Sprites/systemThumb_pressurization_pressed.png" },
}

-- Builds the manageGallery's item list from SCHEMATIC_CATALOG, not from
-- aircraft.systems directly — every catalog type gets a tile, in catalog
-- order, whether or not this aircraft has actually created it yet. A type
-- the aircraft hasn't created gets a synthetic empty placeholder whose id
-- is the catalog type name itself (e.g. "ELECTRICAL") rather than a real
-- GDS-format serial — schematicSystemGallerySelected tells the two apart by
-- trying _findSystem first, and creates the real record lazily the moment
-- that placeholder is actually tapped. Also adds resolved thumbnailPath/
-- thumbnailPressedPath per item (when its systemType has one — see
-- SYSTEM_THUMBNAILS) without polluting the persisted system record, same
-- "derive it at read time" shape as _aircraftGalleryItems.
local function _systemGalleryItems(aircraft)
    local items = {}
    if not aircraft then return items end
    local byType = {}
    for _, sys in ipairs(aircraft.systems) do byType[sys.systemType] = sys end
    for _, catalogEntry in ipairs(SCHEMATIC_CATALOG) do
        local sys = byType[catalogEntry.system]
        local item
        if sys then
            item = {}
            for k, v in pairs(sys) do item[k] = v end
        else
            item = {
                id = catalogEntry.system, name = _titleCase(catalogEntry.system) .. " System",
                systemType = catalogEntry.system,
                elements = {}, wires = {}, controls = {}, snapshots = {},
            }
        end
        local thumb = SYSTEM_THUMBNAILS[catalogEntry.system]
        if thumb then
            item.thumbnailPath = thumb.path
            item.thumbnailPressedPath = thumb.pressedPath
        end
        table.insert(items, item)
    end
    return items
end

local function _saveSchematicStore()
    love.filesystem.write("schematicProjects.lua", table.show(schematicStore, "schematicStore"))
end

-- Minimum real time between two _saveSchematicStore() disk writes made via
-- _requestSchematicSave below. table.show()+write there serializes the
-- ENTIRE store (every aircraft, every system) — not just the system that
-- changed — so firing it synchronously on every discrete edit (a drag
-- commit, a snapshot capture, even one PREV/NEXT tap) costs O(total
-- accumulated data) instead of O(the edit), on the main thread, every time.
-- Edits landing within this window of the last write are coalesced into one
-- write at the end of it — love.update() below performs that deferred write
-- once the window elapses even if no further edit triggers it.
local _SCHEMATIC_SAVE_THROTTLE_SECONDS = 1.5
local _schematicLastSaveTime = -math.huge

-- Set true by every call site below that's about to mutate mainCanvas and
-- then call _saveCurrentSystem() or _requestSchematicSave() right away;
-- cleared once a write actually runs. Lets _saveCurrentSystemIfDirty() (used
-- only by the defensive "just in case" nav-away saves further down — footer
-- nav, back buttons) skip the deep-copy-the-whole-store-and-rewrite-
-- the-whole-file work when the edit that would've needed it already saved
-- moments ago, which — since every mutation path is synchronous and single-
-- threaded — is always the case in normal use. love.quit()/love.focus(false)
-- deliberately keep calling the unconditional _saveCurrentSystem() instead
-- of this, as a last-line-of-defense that can't be defeated by a future
-- mutation path that forgets to set this flag.
local _schematicDirty = false

-- Deep-copies a plain data table (arrays/maps of numbers/strings/booleans/
-- nested tables). Used to keep the live mainCanvas and the persisted
-- schematicStore record of each system as fully independent tables — never
-- the SAME table by reference — in both directions. Without this, clearing/
-- repopulating mainCanvas for one system (table.remove on canvas.elements,
-- etc. in _clearMainCanvas) would also mutate whichever other system's
-- stored record last happened to alias that same table, silently wiping it.
local function _deepCopyTable(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = _deepCopyTable(v) end
    return copy
end

-- Pulls the live mainCanvas state back into its system record. Called before
-- leaving the canvas page (navigating away, or opening a different system).
-- Deep-copies rather than aliasing (see _deepCopyTable) so this system's
-- stored data survives mainCanvas later being cleared/reloaded for another
-- system.
local function _captureCurrentSystemFromCanvas()
    if not schematicStore.currentSystemId then return end
    local sys = _findSystem(schematicStore.currentSystemId)
    local canvas = _findSchematicCanvas()
    if not sys or not canvas then return end
    sys.elements      = _deepCopyTable(canvas.elements)
    sys.wires         = _deepCopyTable(canvas.wires)
    sys.controls      = _deepCopyTable(canvas.controls)
    sys.annunciators  = _deepCopyTable(canvas.annunciators)
    sys.snapshots     = _deepCopyTable(canvas.snapshots)
    sys.modifiedAt    = os.date("%Y-%m-%d %H:%M:%S")
end

local function _saveCurrentSystem()
    _captureCurrentSystemFromCanvas()
    _saveSchematicStore()
    _schematicDirty = false
    _schematicLastSaveTime = love.timer.getTime()
end

-- Only the defensive nav-away saves scattered below (footer nav, back
-- buttons) call this instead of _saveCurrentSystem()
-- directly — see _schematicDirty's own comment above for why that's safe.
local function _saveCurrentSystemIfDirty()
    if _schematicDirty then _saveCurrentSystem() end
end

-- Used by every rapid-fire-prone edit site (a design-mode drag commit, a
-- snapshot capture, a PREV/NEXT combination step) instead of
-- _saveCurrentSystem() directly. The capture half (cheap — proportional only
-- to the current system, see _deepCopyTable) always runs right away, so
-- schematicStore in memory is correct immediately; only the expensive
-- full-store disk write is throttled (see _SCHEMATIC_SAVE_THROTTLE_SECONDS),
-- with love.update() below guaranteeing a deferred write still lands even if
-- no further edit comes along to trigger one.
local function _requestSchematicSave()
    _captureCurrentSystemFromCanvas()
    _schematicDirty = true
    local now = love.timer.getTime()
    if now - _schematicLastSaveTime >= _SCHEMATIC_SAVE_THROTTLE_SECONDS then
        _saveSchematicStore()
        _schematicDirty = false
        _schematicLastSaveTime = now
    end
end

-- Resolved by name via _G[...] from gdsGui_schematic's _notifyChanged, the
-- same string-callback pattern used for buttons/scrollbars elsewhere in this
-- app. mainCanvas.onChange is wired to this name in love.load() — fires on
-- every discrete design-mode edit (drag committed, element/wire/control
-- added/deleted/renamed, color picked, etc.), so this is the single hot-path
-- source of _schematicDirty.
function schematicCanvasChanged()
    _requestSchematicSave()
end

local function _clearMainCanvas()
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    for i = #canvas.elements, 1, -1 do table.remove(canvas.elements, i) end
    for i = #canvas.wires, 1, -1 do table.remove(canvas.wires, i) end
    for i = #canvas.controls, 1, -1 do table.remove(canvas.controls, i) end
    for i = #canvas.annunciators, 1, -1 do table.remove(canvas.annunciators, i) end
    canvas.snapshots = {}
    canvas.selectedElementId = nil
end

-- Loads one saved system's data into the live mainCanvas (replacing whatever
-- is currently there), marks it as the current system, and puts the canvas
-- into the requested mode. Assumes schematicStore.currentAircraftId is
-- already set to the system's owning aircraft.
local function _openSystemIntoCanvas(systemId, mode)
    local sys = _findSystem(systemId)
    if not sys then return end
    -- A leftover undo snapshot could otherwise splice a DIFFERENT system's
    -- elements/wires/controls back in if "undo" were used right after this.
    gdsGui_schematic_clearUndo("mainCanvas")
    _clearMainCanvas()
    -- A wire drawn via ADD WIRE from here on should still come out
    -- pre-colored by system (electrical=yellow, hydraulic=blue, ...), same
    -- as the old catalog connector items used to be, rather than falling
    -- back to flat gray. nil (a legacy/untyped system with no catalog
    -- entry) clears it back to that gray default.
    local catalogEntry = sys.systemType and _findCatalogEntryForType(sys.systemType)
    gdsGui_schematic_setDefaultConnectorColor("mainCanvas", catalogEntry and catalogEntry.connectorColor)
    -- Every value handed to the library is deep-copied off of sys's own
    -- tables (see _deepCopyTable) so mainCanvas never ends up aliasing the
    -- stored record it was just loaded from.
    for _, e in ipairs(sys.elements or {}) do
        gdsGui_schematic_addElement("mainCanvas", e.id, e.shapeType, e.x, e.y, e.w, e.h, e.label,
            _deepCopyTable(e.defaultColor), _deepCopyTable(e.properties), e.rotation or 0, e.spritePath)
    end
    for _, c in ipairs(sys.controls or {}) do
        gdsGui_schematic_addControl("mainCanvas", c.id, c.x, c.y, _deepCopyTable(c.positions), c.detentIndex,
            c.label, c.callbackFunc, c.radiusScale, c.spritePaths, c.rotation, c.overlaySpritePath,
            _deepCopyTable(c.defaultColor))
    end
    for _, w in ipairs(sys.wires or {}) do
        gdsGui_schematic_addWire("mainCanvas", w.id, w.fromElementId, w.toElementId, _deepCopyTable(w.defaultColor),
            w.directionOverride)
    end
    for _, a in ipairs(sys.annunciators or {}) do
        gdsGui_schematic_addAnnunciator("mainCanvas", a.id, a.label, _deepCopyTable(a.color), a.active)
    end
    local canvas = _findSchematicCanvas()
    if canvas then canvas.snapshots = _deepCopyTable(sys.snapshots or {}) end

    schematicStore.currentSystemId = systemId
    local designing = (mode == "design")
    -- Every initial open (design or control) lands at a fixed 1.4x zoom,
    -- vertically centered (see gdsGui_schematic_resetView) rather than the
    -- old mode-dependent zoom/top-aligned view.
    gdsGui_schematic_resetView("mainCanvas", 1.4)
    appSettings.schematicEditMode = designing
    gdsGui_schematic_setMode("mainCanvas", designing and "design" or "control")
    gdsGui_button_setState("schematicModeToggle", designing and "pushed" or "released")
    gdsGui_button_setState("schematicContextButton", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicContextButton", not designing)
    gdsGui_button_setState("schematicSnapshotBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicSnapshotBtn", not designing)
    gdsGui_button_setState("schematicAddBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicAddBtn", not designing)
    gdsGui_button_setState("schematicPaintBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicPaintBtn", not designing)
    gdsGui_button_setState("schematicAnnunciatorBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicAnnunciatorBtn", not designing)
    gdsGui_button_setState("schematicFullScreenToggle", designing and "deactivated" or "released")
    -- setFontSizeToFit (not a plain setText) since sys.name's length varies
    -- per system — refitting on every load keeps a long name from wrapping/
    -- overflowing at the user's current global font size (see
    -- _applyFontSize, which only re-fits on a FONT SIZE change, not a
    -- system switch).
    gdsGui_outputTxtBox_setText("schematic_pageTitle", sys.name)
    gdsGui_outputTxtBox_setFontSizeToFit("schematic_pageTitle", appSettings.fontSize, 10)
    gdsGui_outputTxtBox_setText("schematicSnapshotLabel", "SNAPSHOTS: " .. gdsGui_schematic_countSnapshots("mainCanvas"))
    _saveSchematicStore()
end

-- One-time starter system seeded on a fresh install (no prior save and no
-- old single-design file to migrate): generator -> power line -> pump, gated
-- by a switch, with one pre-taught snapshot rule (switch ON -> wire green) so
-- the "logic recreated" behavior is visible immediately without any setup.
local function _buildDemoSystem()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    return {
        id = "sys_demo", name = "Demo System", createdAt = now, modifiedAt = now,
        elements = {
            { id = "gen1", shapeType = "rect", x = 0.15, y = 0.15, w = 0.16, h = 0.10,
              label = "GEN 1", defaultColor = {0.55, 0.55, 0.55, 1} },
            { id = "pump1", shapeType = "circle", x = 0.70, y = 0.65, w = 0.14, h = 0.10,
              label = "PUMP 1", defaultColor = {0.55, 0.55, 0.55, 1} },
        },
        wires = {
            { id = "pwr1", fromElementId = "gen1", toElementId = "pump1", defaultColor = {0.55, 0.55, 0.55, 1} },
        },
        controls = {
            { id = "sw1", x = 0.15, y = 0.55, numDetents = 2, positions = {"OFF", "ON"},
              detentIndex = 0, label = "PWR SW", callbackFunc = "schematicDemoSwitchChanged" },
        },
        snapshots = {
            ["sw1=1"] = { elements = {}, wires = { pwr1 = {0, 1, 0, 1} }, timestamp = now },
        },
    }
end

-- Control callback (resolved by name via _G[...]): color handling is already
-- generic in schematic_gdsGuiLib.lua — this hook exists for future side effects.
function schematicDemoSwitchChanged(detentIndex)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — DESIGN-MODE "ADD" CASCADING MENU (SYSTEM > TYPE > POSITIONS)
-- SELECT SYSTEM and POSITIONS each append a "RETURN" row so the user can step
-- back up the cascade instead of only being able to tap outside to cancel out
-- of it entirely. TYPE (the menu the "+" dock button actually opens for every
-- typed system) appends "ANNUNCIATOR" in that spot instead — see
-- _openTypeMenu's own comment for why it no longer needs a RETURN row.
-------------------------------------------------------------------------------

local function _openDesignActionsMenu(canvasName)
    -- ADD ELEMENT/CONTROL moved out to its own dedicated "+" dock button
    -- (schematicAddBtn, top-right of the canvas — see schematicAddBtnPressed)
    -- so starting the ADD cascade below no longer needs this menu at all.
    local options = {}
    -- CLEAR SNAPSHOT only offered when the combination currently showing
    -- actually has one recorded (see gdsGui_schematic_hasSnapshot) — nothing
    -- to clear otherwise.
    if gdsGui_schematic_hasSnapshot(canvasName, gdsGui_schematic_computeSignature(canvasName)) then
        table.insert(options, "CLEAR SNAPSHOT")
    end
    if gdsGui_schematic_canUndo(canvasName) then table.insert(options, "UNDO LAST ACTION") end
    table.insert(options, "RESET (CLEAR PAGE)")
    gdsGui_schematic_openMenu(canvasName, "DESIGN ACTIONS", options, "schematicDesignActionChosen", nil)
end

-- Full SELECT SYSTEM list — only ever shown for a system with no fixed
-- systemType (legacy data saved before systems were typed; see _openAddMenu).
local function _openSystemSelectMenu(canvasName)
    local names = {}
    for _, sys in ipairs(SCHEMATIC_CATALOG) do table.insert(names, sys.system) end
    table.insert(names, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "SELECT SYSTEM", names, "schematicCatalogSystemChosen", nil)
end

-- ANNUNCIATOR is appended after every system's own items instead of a
-- RETURN row (RETURN's old spot) — it's a catalog-wide item, not nested
-- under any one system (see gdsGui_schematic_armAnnunciatorCreation), so it
-- shows the same regardless of which system's TYPE menu this is. There's
-- still a way back up: the dedicated ACTIONS button (schematicContextButtonPressed)
-- reaches _openDesignActionsMenu directly now, so this cascade no longer
-- needs its own RETURN row to get there.
local function _openTypeMenu(canvasName, sys)
    local names = {}
    for _, item in ipairs(sys.items) do table.insert(names, item.label) end
    table.insert(names, "ANNUNCIATOR")
    gdsGui_schematic_openMenu(canvasName, sys.system .. ": TYPE", names, "schematicCatalogItemChosen", nil)
end

-- The catalog entry matching the currently-open system's fixed type, or nil
-- for a legacy/untyped system (pre-dates "one system type per aircraft").
local function _currentSystemCatalogEntry()
    local sys = _findSystem(schematicStore.currentSystemId)
    return sys and sys.systemType and _findCatalogEntryForType(sys.systemType) or nil
end

-- ADD ELEMENT/CONTROL entry point: a typed system already knows which
-- catalog branch it belongs to, so it jumps straight to that TYPE menu
-- instead of making the user pick a system that's already decided. Only a
-- legacy/untyped system falls back to the full SELECT SYSTEM list.
local function _openAddMenu(canvasName)
    local entry = _currentSystemCatalogEntry()
    if entry then
        _catalogChosenSystem = entry
        _openTypeMenu(canvasName, entry)
    else
        _openSystemSelectMenu(canvasName)
    end
end

function schematicCatalogSystemChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        _openDesignActionsMenu(canvasName)
        return
    end
    local sys = SCHEMATIC_CATALOG[index]
    if not sys then return end
    _catalogChosenSystem = sys
    _openTypeMenu(canvasName, sys)
end

function schematicCatalogItemChosen(canvasName, index, optionText)
    -- Catalog-wide, not one of _catalogChosenSystem.items (see _openTypeMenu)
    -- — jumps straight to the name prompt instead of arming a tap-to-place.
    if optionText == "ANNUNCIATOR" then
        gdsGui_schematic_armAnnunciatorCreation(canvasName)
        return
    end
    local item = _catalogChosenSystem and _catalogChosenSystem.items[index]
    if not item then return end
    -- No "connector" kind left in SCHEMATIC_CATALOG — ADD WIRE on an
    -- element's own edit menu replaced it (see
    -- gdsGui_schematic_internal_onElementEditChosen).
    if item.kind == "element" then
        gdsGui_schematic_armElementPlacement(canvasName, item.shapeType, item.label, nil, item.label,
            item.defaultProperties, item.spritePath, item.sizeMul, item.matchControlSize)
    elseif #item.presets == 1 then
        gdsGui_schematic_armControlPlacement(canvasName, item.presets[1], item.label, item.callbackFunc, item.label,
            item.spritePaths, item.overlaySpritePath, item.radiusMul, item.colorDarkenMul)
    else
        _catalogChosenControlItem = item
        local names = {}
        for _, preset in ipairs(item.presets) do
            table.insert(names, #preset .. " (" .. table.concat(preset, "/") .. ")")
        end
        table.insert(names, "RETURN")
        gdsGui_schematic_openMenu(canvasName, item.label .. ": POSITIONS", names, "schematicCatalogPresetChosen", nil)
    end
end

function schematicCatalogPresetChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        if _catalogChosenSystem then _openTypeMenu(canvasName, _catalogChosenSystem) end
        return
    end
    local item = _catalogChosenControlItem
    if not item then return end
    local preset = item.presets[index]
    gdsGui_schematic_armControlPlacement(canvasName, preset, item.label, item.callbackFunc, item.label,
        item.spritePaths, item.overlaySpritePath, item.radiusMul, item.colorDarkenMul)
    _catalogChosenControlItem = nil
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — CONTROL-MODE "SELECT CONTROL" -> "SELECT POSITION" MENUS
-- Same "RETURN" convention as the design-mode cascade above.
-------------------------------------------------------------------------------

local function _openControlActionsMenu(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas or #canvas.controls == 0 then return end
    gdsGui_schematic_openMenu(canvasName, "CONTROL ACTIONS", {"SELECT CONTROL"}, "schematicControlActionChosen", nil)
end

local function _openSelectControlMenu(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    _controlMenuIds = {}
    local names = {}
    for _, c in ipairs(canvas.controls) do
        table.insert(_controlMenuIds, c.id)
        table.insert(names, c.label or c.id)
    end
    table.insert(names, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "SELECT CONTROL", names, "schematicControlChosen", nil)
end

function schematicControlChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        _openControlActionsMenu(canvasName)
        return
    end
    local controlId = _controlMenuIds[index]
    if not controlId then return end
    local canvas = _findSchematicCanvas()
    local control = canvas and canvas.controls
    local found = nil
    if control then
        for _, c in ipairs(control) do
            if c.id == controlId then found = c end
        end
    end
    if not found then return end
    _controlMenuSelectedId = controlId
    local names = {}
    for _, p in ipairs(found.positions) do table.insert(names, p) end
    table.insert(names, "RETURN")
    gdsGui_schematic_openMenu(canvasName, (found.label or controlId) .. ": POSITION", names,
        "schematicControlPositionChosen", nil)
end

function schematicControlPositionChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        _openSelectControlMenu(canvasName)
        _controlMenuSelectedId = nil
        return
    end
    if not _controlMenuSelectedId then return end
    gdsGui_schematic_setControlPosition(canvasName, _controlMenuSelectedId, index - 1)
    _controlMenuSelectedId = nil
end

-- Dedicated "+" dock button (schematicAddBtn, top-right of the canvas, design
-- mode only): the sole entry point into the ADD cascade (SYSTEM > TYPE >
-- POSITIONS, see _openAddMenu), now that it's no longer one of the ACTIONS
-- menu's options. Same reentrancy guard as schematicContextButtonPressed
-- below — opening a brand new top-level menu while a cascade from either
-- entry point is already mid-flight would silently clobber it and orphan its
-- tracking locals (see gdsGui_schematic_isMenuOpen).
function schematicAddBtnPressed()
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    if gdsGui_schematic_getMode("mainCanvas") ~= "design" then return end
    _openAddMenu("mainCanvas")
end

-- Dedicated brush dock button (schematicPaintBtn, just below ADD): a sticky
-- toggle, so newState reflects which way it was just switched (see the
-- button's own "toggle" type comment at its gdsGui_button_create call) —
-- armed/disarmed directly rather than via gdsGui_schematic_togglePaintMode,
-- so this always matches what the button itself just displayed regardless
-- of whether the library's paintMode had already been auto-disarmed by an
-- empty-canvas tap since the last press (see love.update's poll below,
-- which corrects the button back to "released" when that happens). No
-- isMenuOpen reentrancy guard needed, unlike schematicAddBtnPressed above —
-- gdsGui_schematic_pressed checks canvas.menu before ever consulting
-- canvas.paintMode, so arming it under an open menu is inert until that
-- menu closes, not a clobber.
function schematicPaintBtnPressed(newState)
    if newState == globApp.BUTTON_STATES.PRESSED then
        gdsGui_schematic_armPaintMode("mainCanvas")
    else
        gdsGui_schematic_disarmPaintMode("mainCanvas")
    end
end

-- Dedicated annunciator dock button (schematicAnnunciatorBtn, just below
-- PAINT): same sticky-toggle convention as schematicPaintBtnPressed above —
-- newState reflects which way it was just switched, and love.update's poll
-- (see _prevSchematicAnnunciatorPanelOpen) corrects it back to "released" if
-- the panel ever closes some other way (mode switch, or PAINT/ADD taking
-- over via gdsGui_schematic_cancelPlacement).
function schematicAnnunciatorBtnPressed(newState)
    gdsGui_schematic_setAnnunciatorPanelOpen("mainCanvas", newState == globApp.BUTTON_STATES.PRESSED)
end

-- Single consolidated "ACTIONS" button: design mode offers clearing the
-- current combination's snapshot, undoing, and resetting (clearing) the
-- whole page; control mode offers operating a control. Snapshot capture is
-- its own dedicated SNAPSHOT button, and adding an element/control its own
-- dedicated "+" button above — neither is part of this menu.
function schematicContextButtonPressed()
    -- A multi-step cascade (e.g. ADD ELEMENT/CONTROL -> ELECTRICAL ->
    -- SWITCH -> POSITIONS) is itself built out of canvas.menu opens/
    -- replacements chained from that SAME menu's own onSelect callbacks —
    -- intended and left alone. This button is an unrelated entry point
    -- though: opening a brand new top-level menu here while one of those
    -- cascades is already mid-flight would silently clobber it and orphan
    -- its tracking locals (see gdsGui_schematic_isMenuOpen).
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    local mode = gdsGui_schematic_getMode("mainCanvas")
    if mode == "design" then
        _openDesignActionsMenu("mainCanvas")
    else
        _openControlActionsMenu("mainCanvas")
    end
end

function schematicDesignActionChosen(canvasName, index, optionText)
    if optionText == "CLEAR SNAPSHOT" then
        -- Deletes only the snapshot for whichever control-position
        -- combination is currently showing, not every snapshot on the
        -- system (that's RESET's job). Undo-able: pushed onto the undo
        -- stack first, same as RESET, so "UNDO LAST ACTION" brings it back.
        gdsGui_schematic_pushUndo(canvasName)
        gdsGui_schematic_removeSnapshot(canvasName, gdsGui_schematic_computeSignature(canvasName))
        _schematicDirty = true
        _saveCurrentSystem()
    elseif optionText == "UNDO LAST ACTION" then
        gdsGui_schematic_undo(canvasName)
        _schematicDirty = true
        _saveCurrentSystem()
    elseif optionText == "RESET (CLEAR PAGE)" then
        gdsGui_schematic_openMenu(canvasName, "CLEAR ENTIRE PAGE?",
            {"CLEAR", "CANCEL"}, "schematicResetConfirmed", nil, true)
    end
end

-- Wipes every element/wire/control/snapshot from the live canvas and persists
-- the now-blank page to the current system. Irreversible, hence the confirm
-- (and hence pushing an undo snapshot first, so "UNDO LAST ACTION" can bring
-- it all back).
function schematicResetConfirmed(canvasName, index, optionText)
    if optionText ~= "CLEAR" then return end
    gdsGui_schematic_pushUndo(canvasName)
    _clearMainCanvas()
    _schematicDirty = true
    _saveCurrentSystem()
    gdsGui_outputTxtBox_setText("schematicSnapshotLabel", "SNAPSHOTS: 0")
end

-- Control mode is pure "operate": the only menu action is picking a control
-- to cycle without having to find it on the (possibly zoomed/panned) canvas.
-- Color assignment lives in design mode's ACTIONS menu; snapshot capture is
-- the dedicated SNAPSHOT button (design-mode only).
function schematicControlActionChosen(canvasName, index, optionText)
    if optionText == "SELECT CONTROL" then
        _openSelectControlMenu(canvasName)
    end
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — SCHEMATIC HOME (NEW AIRCRAFT / MY AIRCRAFT)
-- The top landing point for the whole System Schematic flow.
-------------------------------------------------------------------------------

-- The systems gallery's header reads "<aircraft name> [SYSTEMS]" once an
-- aircraft is open, so it's clear at a glance whose systems are listed.
local function _aircraftSystemsTitle(aircraft)
    return aircraft.name .. " [SYSTEMS]"
end

-- Keeps the "MY AIRCRAFT" button in sync with whether there's anything to
-- open; called whenever SchematicHome is (re)entered and after an aircraft
-- is deleted.
local function _refreshSchematicHomeAvailability()
    gdsGui_button_setState("schematicHomeMyAircraft",
        (#schematicStore.aircraft > 0) and "released" or "deactivated")
end

function schematicHomeNewPressed()
    gdsGui_textPrompt_open("NAME NEW AIRCRAFT", "Aircraft " .. schematicStore.nextAircraftNum, 24,
        "schematicNewAircraftConfirmed", nil)
end

-- Holds the just-named aircraft's name while the required thumbnail-type
-- picker (below) is open; the aircraft record itself isn't created until a
-- thumbnail is actually chosen, so "require a thumbnail" is enforced simply
-- by there being no other path to an aircraft record existing.
local _pendingNewAircraftName = nil

-- A brand-new aircraft has no systems yet, so it lands on its (all-empty-
-- placeholder) systems gallery rather than straight into the canvas — see
-- navGoToAircraftSystems. Name is confirmed first, then the user must pick
-- one of AIRCRAFT_THUMBNAILS before the record is actually created (see
-- schematicAircraftThumbnailChosen).
function schematicNewAircraftConfirmed(name)
    if name == "" then name = "Aircraft " .. schematicStore.nextAircraftNum end
    _pendingNewAircraftName = name
    local images = {}
    for _, t in ipairs(AIRCRAFT_THUMBNAILS) do
        table.insert(images, { path = t.path, label = t.label })
    end
    gdsGui_choiceMenu_openImagePicker("SELECT AIRCRAFT TYPE", images, {"CANCEL"},
        "schematicAircraftThumbnailChosen", "schematicAircraftThumbnailCancelled")
end

-- optionText is the chosen image's label (e.g. "HELICOPTER") or "CANCEL".
-- id is a GDS-format unique serial (gdsGui_saveLoad_createIdNumber, from
-- saveLoad_gdsGuiLib.lua) rather than a simple incrementing counter, so
-- aircraft records stay unambiguously identifiable even if saves are merged,
-- edited by hand, or a counter ever gets out of sync.
function schematicAircraftThumbnailChosen(optionText)
    local name = _pendingNewAircraftName
    _pendingNewAircraftName = nil
    if optionText == "CANCEL" or not name then return end
    local chosen
    for _, t in ipairs(AIRCRAFT_THUMBNAILS) do
        if t.label == optionText then chosen = t end
    end
    if not chosen then return end

    local id = gdsGui_saveLoad_createIdNumber(schematicStore.aircraft, "id", 17)
    schematicStore.nextAircraftNum = schematicStore.nextAircraftNum + 1
    local now = os.date("%Y-%m-%d %H:%M:%S")
    table.insert(schematicStore.aircraft, {
        id = id, name = name, createdAt = now, modifiedAt = now, systems = {}, thumbnail = chosen.key,
    })
    schematicStore.currentAircraftId = id
    _saveSchematicStore()
    navGoToAircraftSystems()
end

-- Tapping outside the picker (or CANCEL) aborts the whole "new aircraft"
-- flow — no record was ever created, so there's nothing to undo.
function schematicAircraftThumbnailCancelled()
    _pendingNewAircraftName = nil
end

-- Single consolidated entry point: opens the aircraft gallery that handles
-- both opening an aircraft and editing it (rename/delete), chosen per-aircraft
-- from the action menu in schematicAircraftGallerySelected below.
function schematicHomeMyAircraftPressed()
    gdsGui_schematicGallery_setItems("aircraftGallery", _aircraftGalleryItems())
    _navSyncAll("AircraftGallery")
    gdsGui_page_switch("LoadingAircraftGallery", 12, 2, false)
end

-- Tapping an aircraft opens an action menu rather than jumping straight into
-- it, so the same gallery covers opening, renaming, and deleting.
function schematicAircraftGallerySelected(galleryName, aircraftId)
    local aircraft = _findAircraft(aircraftId)
    if not aircraft then return end
    _manageMenuAircraftId = aircraftId
    gdsGui_schematicGallery_openMenu(galleryName, aircraft.name,
        {"OPEN AIRCRAFT", "RENAME", "DELETE", "CANCEL"},
        "schematicAircraftActionChosen", nil)
end

function schematicAircraftActionChosen(galleryName, index, optionText)
    if optionText == "OPEN AIRCRAFT" then
        schematicStore.currentAircraftId = _manageMenuAircraftId
        navGoToAircraftSystems()
    elseif optionText == "RENAME" then
        local aircraft = _findAircraft(_manageMenuAircraftId)
        if aircraft then
            gdsGui_textPrompt_open("RENAME AIRCRAFT", aircraft.name, 24, "schematicAircraftRenameConfirmed", nil)
        end
    elseif optionText == "DELETE" then
        local aircraft = _findAircraft(_manageMenuAircraftId)
        gdsGui_schematicGallery_openMenu(galleryName, "DELETE \"" .. (aircraft and aircraft.name or "") .. "\"?",
            {"DELETE", "CANCEL"}, "schematicAircraftDeleteConfirmed", nil, true)
    end
    -- "CANCEL" (or tapping outside): no-op, _manageMenuAircraftId is overwritten next time.
end

function schematicAircraftRenameConfirmed(newName)
    local aircraft = _findAircraft(_manageMenuAircraftId)
    if aircraft and newName ~= "" then
        aircraft.name = newName
        _saveSchematicStore()
        gdsGui_schematicGallery_setItems("aircraftGallery", _aircraftGalleryItems())
        if schematicStore.currentAircraftId == aircraft.id then
            gdsGui_outputTxtBox_setText("schematicManage_pageTitle", _aircraftSystemsTitle(aircraft))
        end
    end
    _manageMenuAircraftId = nil
end

-- Deleting an aircraft cascades to every system it owns (they live only
-- inside its .systems array — nothing else references them).
function schematicAircraftDeleteConfirmed(galleryName, index, optionText)
    if optionText == "DELETE" and _manageMenuAircraftId then
        for i = #schematicStore.aircraft, 1, -1 do
            if schematicStore.aircraft[i].id == _manageMenuAircraftId then
                table.remove(schematicStore.aircraft, i)
            end
        end
        if schematicStore.currentAircraftId == _manageMenuAircraftId then
            schematicStore.currentAircraftId = nil
            schematicStore.currentSystemId = nil
            _clearMainCanvas()
        end
        _saveSchematicStore()
        gdsGui_schematicGallery_setItems("aircraftGallery", _aircraftGalleryItems())
        _refreshSchematicHomeAvailability()
    end
    _manageMenuAircraftId = nil
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — OPENING AN AIRCRAFT
-- Reached fresh off NEW AIRCRAFT or via the MY AIRCRAFT gallery's OPEN
-- AIRCRAFT action (see above). No separate "aircraft home" page in between
-- any more — opening an aircraft lands directly on its systems gallery,
-- which shows a tile for every SCHEMATIC_CATALOG type (not just ones
-- already created — see _systemGalleryItems) and handles both creating+
-- opening a not-yet-existing one and editing/deleting an existing one
-- (schematicSystemGallerySelected below).
-------------------------------------------------------------------------------

function navGoToAircraftSystems()
    local aircraft = _findCurrentAircraft()
    if not aircraft then navGoToSystemSchematic(); return end
    gdsGui_schematicGallery_setItems("manageGallery", _systemGalleryItems(aircraft))
    gdsGui_outputTxtBox_setText("schematicManage_pageTitle", _aircraftSystemsTitle(aircraft))
    _navSyncAll("SchematicManageGallery")
    gdsGui_page_switch("LoadingSchematicManage", 11, 2, false)
end

-- A real (already-created) system's tile opens the usual action menu. A
-- not-yet-created one (_systemGalleryItems gives it the catalog type name
-- itself as its id, since there's no real id to use yet) skips straight to
-- creating the record and opening it in design mode — no type picker, no
-- naming prompt, no action menu first: tapping an empty slot IS "create and
-- start editing." No RENAME on the real-system menu either — a system's
-- name is its catalog type (see SCHEMATIC_CATALOG/_findCatalogEntryForType),
-- not a freeform label, so there's nothing for the user to type.
function schematicSystemGallerySelected(galleryName, systemId)
    local sys = _findSystem(systemId)
    if sys then
        _manageMenuSystemId = systemId
        gdsGui_schematicGallery_openMenu(galleryName, sys.name,
            {"OPEN IN CONTROL MODE", "OPEN IN DESIGN MODE", "DELETE", "CANCEL"},
            "schematicSystemActionChosen", nil)
        return
    end
    local aircraft = _findCurrentAircraft()
    if not aircraft or not _findCatalogEntryForType(systemId) then return end
    local id = gdsGui_saveLoad_createIdNumber(aircraft.systems, "id", 17)
    local now = os.date("%Y-%m-%d %H:%M:%S")
    table.insert(aircraft.systems, {
        id = id, name = _titleCase(systemId) .. " System", systemType = systemId,
        createdAt = now, modifiedAt = now,
        elements = {}, wires = {}, controls = {}, annunciators = {}, snapshots = {},
    })
    _saveSchematicStore()
    _openSystemIntoCanvas(id, "design")
    _navSyncAll("SystemSchematic")
    gdsGui_page_switch("LoadingSchematic", 7, 3, false)
end

function schematicSystemActionChosen(galleryName, index, optionText)
    if optionText == "OPEN IN CONTROL MODE" then
        _openSystemIntoCanvas(_manageMenuSystemId, "control")
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
    elseif optionText == "OPEN IN DESIGN MODE" then
        _openSystemIntoCanvas(_manageMenuSystemId, "design")
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
    elseif optionText == "DELETE" then
        local sys = _findSystem(_manageMenuSystemId)
        gdsGui_schematicGallery_openMenu(galleryName, "DELETE \"" .. (sys and sys.name or "") .. "\"?",
            {"DELETE", "CANCEL"}, "schematicSystemDeleteConfirmed", nil, true)
    end
    -- "CANCEL" (or tapping outside): no-op, _manageMenuSystemId is overwritten next time.
end

function schematicSystemDeleteConfirmed(galleryName, index, optionText)
    if optionText == "DELETE" and _manageMenuSystemId then
        local aircraft = _findCurrentAircraft()
        if aircraft then
            for i = #aircraft.systems, 1, -1 do
                if aircraft.systems[i].id == _manageMenuSystemId then
                    table.remove(aircraft.systems, i)
                end
            end
        end
        if schematicStore.currentSystemId == _manageMenuSystemId then
            schematicStore.currentSystemId = nil
            _clearMainCanvas()
        end
        _saveSchematicStore()
        gdsGui_schematicGallery_setItems("manageGallery", _systemGalleryItems(aircraft))
    end
    _manageMenuSystemId = nil
end

local function _applyTheme(isDark)
    local t = isDark and _THEME_DARK or _THEME_LIGHT
    for i = 1, 4 do globApp.appColor[i] = t.app[i] end
    -- Read by schematic_gdsGuiLib.lua to darken palette-sourced colors
    -- (brush/swatch-picker swatches and anything drawn with one) in WHITE
    -- MODE, where they'd otherwise read as washed out against the light
    -- canvas backdrop.
    globApp.themeIsDark           = isDark
    globApp.themeTextColor        = { t.text[1],        t.text[2],        t.text[3],        t.text[4] }
    globApp.themeProgressBarColor = { t.progressBar[1], t.progressBar[2], t.progressBar[3], t.progressBar[4] }
    -- Read by schematic_gdsGuiLib.lua's canvas fill/grid draw so the System
    -- Schematic page (previously hardcoded to a fixed dark backdrop
    -- regardless of this toggle) follows DARK/WHITE MODE same as every
    -- other page.
    globApp.themeCanvasBgColor   = { t.canvasBg[1],   t.canvasBg[2],   t.canvasBg[3],   t.canvasBg[4] }
    globApp.themeCanvasGridColor = { t.canvasGrid[1], t.canvasGrid[2], t.canvasGrid[3], t.canvasGrid[4] }
    for _, cont in ipairs(globApp.objects.containers) do
        cont.bgColor     = { t.bg[1],     t.bg[2],     t.bg[3],     t.bg[4] }
        cont.headerColor = { t.header[1], t.header[2], t.header[3], t.header[4] }
        cont.borderColor = { t.border[1], t.border[2], t.border[3], t.border[4] }
    end
    for _, obj in ipairs(globApp.objects.outputTextBox) do
        if obj.name == "mainMenu_utcHeader" then
            obj.text.color = isDark and colorYellow or {0.05, 0.10, 0.40, 1}
        else
            obj.text.color = { t.text[1], t.text[2], t.text[3], t.text[4] }
        end
        if obj.name == "compassBg" then
            obj.bgCircle = (not isDark) and {0.35, 0.35, 0.35, 1} or nil
        end
    end
    local _learnUpdates = {
        {name="timerLearnContent",    raw=_LEARN_TIMER_RAW},
        {name="windLearnContent",     raw=_LEARN_WIND_RAW},
        {name="calcLearnContent",     raw=_LEARN_CALC_RAW},
        {name="dutyLearnContent",     raw=_LEARN_DUTY_RAW},
        {name="settingsLearnContent", raw=_LEARN_SETTINGS_RAW},
    }
    for _, pair in ipairs(_learnUpdates) do
        gdsGui_outputTxtBox_setText(pair.name, _learnSegsColored(pair.raw, isDark))
    end
end

local function _applyFontSize(fontSize)
    globApp.appFont = love.graphics.newFont(fontSize)
    love.graphics.setFont(globApp.appFont)
    local names = {
        -- main menu data panels
        "mainMenu_utcHeader", "timerTopRight", "crosswindData",
        "windSpeedLabel", "windGustLabel",
        "selectedAltitudeBox", "selectedTimeBox", "selectedDegreeBox",
        "requiredFPM", "requiredDistance",
        "dutyStartBox", "dutyMaxHoursBox", "lastFlightBox",
        "dutyOutBox", "departByBox",
        -- settings labels
        "displayModeLabel", "soundsLabel", "hapticsLabel", "fontSizeLabel",
        -- learn page content
        "timerLearnContent", "windLearnContent", "calcLearnContent",
        "dutyLearnContent", "settingsLearnContent",
        -- page header titles (all pages) — schematic_pageTitle is handled
        -- separately below: unlike every other page's title, its text is a
        -- user-renameable system name of arbitrary length, so it needs the
        -- shrink-to-fit variant instead of a flat setFontSize (see
        -- gdsGui_outputTxtBox_setFontSizeToFit's comment).
        "mainMenu_pageTitle", "learn_pageTitle", "settings_pageTitle", "tc_pageTitle",
        "schematicHome_pageTitle", "schematicManage_pageTitle",
        "aircraftGallery_pageTitle",
        -- terms and conditions body
        "tcText",
        -- system schematic page readouts
        "schematicSnapshotLabel", "schematicZoomLabel", "schematicCombLabel",
    }
    for _, name in ipairs(names) do
        gdsGui_outputTxtBox_setFontSize(name, fontSize)
    end
    gdsGui_outputTxtBox_setFontSizeToFit("schematic_pageTitle", fontSize, 10)
    gdsGui_outputTxtBox_setFontSize("dutyWarningBox", math.max(8, fontSize - 2))
    gdsGui_outputTxtBox_setText("fontSizeLabel", "FONT SIZE: " .. fontSize .. "pt")
    for _, sb in ipairs(globApp.objects.scrollBars) do
        if sb.id == "fontSizeScale" then
            sb.bar.position = (fontSize - 12) / 4
            gdsGui_scrollBar_updatePosition(sb, sb.bar.position)
            break
        end
    end

    -- Only relayout once containers have been finalised (not during early init).
    if not globApp.objects.pageScrollStates["MainMenu"] then return end

    -- Recompute each textbox height at the new font size, update containerFrac,
    -- and relayout so containers shrink/grow to fit — no empty space left behind.
    local font = love.graphics.newFont(fontSize)
    local cW   = globApp.safeScreenArea.w
    local function wS(px) return math.floor(px / 320 * cW) end
    local function mH(maxText, fw)
        local textW = (fw - 10) * 0.8
        local lines = 0
        for seg in (maxText .. "\n"):gmatch("([^\n]*)\n") do
            local _, wrapped = font:getWrap(seg == "" and " " or seg, textW)
            lines = lines + #wrapped
        end
        return lines * font:getHeight() + 8
    end

    local tx = globApp.objects.outputTextBox
    local sb = globApp.objects.scrollBars
    local rk = globApp.objects.rotaryKnobs
    local function setCF(list, name, field, value)
        for _, obj in ipairs(list) do
            if (obj.name == name or obj.id == name) then
                obj.containerFrac[field] = value; return
            end
        end
    end

    -- Timer panel
    -- mainMenu_utcHeader lives in the fixed page header; no container relayout needed
    setCF(tx, "timerTopRight", "h", mH("COUNT DOWN\nTIMER:\nM 59:59 S", wS(190)))

    -- Wind panel
    local hWindLabel = mH("WIND\nSPD", 75)
    local hCrosswind = mH(
        "WIND: 36046G61KT\nRWY: 36\nSUS XW:46L TW:46\nGST XW:61L TW:61\nGust Factor: 56",
        wS(200))
    setCF(tx, "windSpeedLabel", "h", hWindLabel)
    setCF(tx, "windGustLabel",  "h", hWindLabel)
    setCF(tx, "crosswindData",  "h", hCrosswind)
    local windSbY  = 10 + hWindLabel + 5
    local knobY    = math.max(100, 10 + hCrosswind + 20)
    local compassY = knobY + 80
    local windSbH  = knobY + 160 - windSbY
    setCF(sb, "windSpeed",   "y", windSbY)
    setCF(sb, "windSpeed",   "h", windSbH)
    setCF(sb, "windGust",    "y", windSbY)
    setCF(sb, "windGust",    "h", windSbH)
    setCF(rk, "runwayKnob",  "y", knobY)
    setCF(tx, "compassBg",   "y", compassY)

    -- Calc panel
    local hCalcSel = mH("SLCTD ALT:\n51000 FT", wS(110)) + 40
    setCF(tx, "selectedAltitudeBox", "h", hCalcSel)
    setCF(tx, "selectedTimeBox",     "h", hCalcSel)
    setCF(tx, "selectedDegreeBox",   "h", hCalcSel)
    local hCalcRes = mH("REQ DIST:\n1925 nm", wS(80)) + 40
    setCF(tx, "requiredFPM",      "h", hCalcRes)
    setCF(tx, "requiredDistance", "h", hCalcRes)
    local calcSbY   = 47 + math.ceil(hCalcSel / 2) + 2
    local calcResCY = calcSbY + math.floor(185 / 2)
    setCF(sb, "timeScale", "y", calcSbY)
    setCF(sb, "altScale",  "y", calcSbY)
    setCF(sb, "deg",       "y", calcSbY)
    setCF(tx, "requiredFPM",      "y", calcResCY)
    setCF(tx, "requiredDistance", "y", calcResCY)

    -- Duty panel (positions depend on heights above, mirroring the _d1.._d8 logic)
    local warnFont = love.graphics.newFont(math.max(8, fontSize - 2))
    local function mHW(maxText, fw)
        local textW = (fw - 10) * 0.8
        local lines = 0
        for seg in (maxText .. "\n"):gmatch("([^\n]*)\n") do
            local _, wrapped = warnFont:getWrap(seg == "" and " " or seg, textW)
            lines = lines + #wrapped
        end
        return lines * warnFont:getHeight() + 8
    end
    local sbH          = 30
    local hDutyStart   = mH("DUTY START: 23:59Z",                                               wS(310))
    local hDutyMax     = mH("MAX DUTY: 20 HRS",                                                  wS(310))
    local hLastFlight  = mH("LAST FLT BLOCK TIME: 18.0 HRS",                                     wS(310))
    local hDutyOut     = mH("DEPART BY\n23:59Z",                                                 wS(120))
    local hDutyWarn    = mHW("FOR REFERENCE ONLY — verify against applicable FARs and ops specs.", wS(310))
    local dGap  = 8
    local lsGap = 4
    local d2 = dGap + hDutyStart  + lsGap
    local d4 = d2 + sbH + dGap   + hDutyMax    + lsGap
    local d6 = d4 + sbH + dGap   + hLastFlight + lsGap
    local d1 = d2 - hDutyStart  - lsGap
    local d3 = d4 - hDutyMax    - lsGap
    local d5 = d6 - hLastFlight - lsGap
    local d7 = d6 + sbH + dGap
    local d8 = d7 + hDutyOut    + dGap
    setCF(tx, "dutyStartBox",    "h", hDutyStart);   setCF(tx, "dutyStartBox",    "y", d1)
    setCF(sb, "dutyStartScale",  "y", d2)
    setCF(tx, "dutyMaxHoursBox", "h", hDutyMax);     setCF(tx, "dutyMaxHoursBox", "y", d3)
    setCF(sb, "dutyHoursScale",  "y", d4)
    setCF(tx, "lastFlightBox",   "h", hLastFlight);  setCF(tx, "lastFlightBox",   "y", d5)
    setCF(sb, "lastFlightScale", "y", d6)
    setCF(tx, "dutyOutBox",      "h", hDutyOut);     setCF(tx, "dutyOutBox",      "y", d7)
    setCF(tx, "departByBox",     "h", hDutyOut);     setCF(tx, "departByBox",     "y", d7)
    setCF(tx, "dutyWarningBox",  "h", hDutyWarn);    setCF(tx, "dutyWarningBox",  "y", d8)

    gdsGui_container_relayoutPage("MainMenu")
    gdsGui_container_scrollToTop("MainMenu")

    -- Learn page: re-measure static content at the new font size
    local lTxtW  = math.floor(cW * 0.85)
    local lTextW = (lTxtW - 10) * 0.8
    local function lH(rawSegs)
        local n = 0
        for _, s in ipairs(rawSegs) do
            local _, wrapped = font:getWrap(s.text, lTextW)
            n = n + #wrapped
        end
        return n * font:getHeight()
    end
    local learnPairs = {
        {"timerLearnContent",    _LEARN_TIMER_RAW},
        {"windLearnContent",     _LEARN_WIND_RAW},
        {"calcLearnContent",     _LEARN_CALC_RAW},
        {"dutyLearnContent",     _LEARN_DUTY_RAW},
        {"settingsLearnContent", _LEARN_SETTINGS_RAW},
    }
    for _, p in ipairs(learnPairs) do
        setCF(tx, p[1], "h", lH(p[2]))
    end
    gdsGui_container_relayoutPage("Learn")
    gdsGui_container_scrollToTop("Learn")
end

-------------------------------------------------------------------------------
-- DEV-MENU HOOKS (called by the GUI library after dev actions)
-------------------------------------------------------------------------------

-- Called by the library after erasing all project data so the app can reset
-- its own persisted settings and bring the T&C screen back on next leave.
function gdsGui_dev_onDataErased()
    appSettings = {}
    love.filesystem.remove("appSettings.lua")
    _tcScrolledToBottom = false
    gdsGui_button_setState("tcAgreementToggle", "deactivated")
    gdsGui_button_setState("tcContinueButton",  "deactivated")
    gdsGui_outputTxtBox_resetScrollState("tcText")
    _syncPaidLoadingScreenSkip()
end

-- Called by the library to determine which page to land on when leaving the
-- dev menu. Returns page 4 (T&C) when settings were wiped, else page 3 (MainMenu).
function gdsGui_dev_getLeaveDestPage()
    return (appSettings.tcAcceptedVersion ~= APP_VERSION) and 4 or 3
end

-------------------------------------------------------------------------------
-- LOVE CALLBACKS
-------------------------------------------------------------------------------
function love.load()
    selectedAltitude      = 0
    selectedTime          = 0
    selectedDegree        = 0
    selectedKnobPos       = 36
    selectedWindDirection = 360
    selectedWindSpeed     = 0
    selectedWindGust      = 0

    ---------------------------------------------------------------------------
    -- LOAD SETTINGS EARLY (needed for layout variables below)
    ---------------------------------------------------------------------------
    gdsGui_saveLoad_loadFileContents("appSettings.lua")
    if appSettings.darkMode         == nil then appSettings.darkMode         = true  end
    if appSettings.soundEnabled     == nil then appSettings.soundEnabled     = true  end
    if appSettings.hapticsEnabled   == nil then appSettings.hapticsEnabled   = true  end
    if appSettings.fontSize         == nil then appSettings.fontSize         = 12    end
    -- System Schematic is a paid feature; schematicUnlocked is a placeholder
    -- entitlement flag (no real store/IAP integration exists in this pure-Lua
    -- app yet) flipped true by the Simulate Purchase button on the paywall page.
    if appSettings.schematicUnlocked == nil then appSettings.schematicUnlocked = false end
    if appSettings.schematicEditMode == nil then appSettings.schematicEditMode = true  end
    -- True if the app was sitting on the SystemSchematic/SchematicFullScreen
    -- page the last time it quit or was backgrounded (see love.quit/
    -- love.focus below) — lets a cold boot resume straight back into that
    -- page/system/mode instead of always landing on MainMenu first.
    if appSettings.schematicResumeActive == nil then appSettings.schematicResumeActive = false end
    _syncPaidLoadingScreenSkip()

    -- Loads the aircraft/systems store; migrates a pre-existing single-design
    -- save (from before projects existed) or a flat project list (from before
    -- aircraft existed) into one aircraft's systems, or seeds a demo system on
    -- a genuinely fresh install, so Home's NEW/MY AIRCRAFT galleries are never
    -- confusingly empty on first run.
    gdsGui_saveLoad_loadFileContents("schematicProjects.lua")
    if schematicStore == nil then
        local migratedSystems = {}
        gdsGui_saveLoad_loadFileContents("schematicDesign.lua")
        if schematicDesign and schematicDesign.elements and #schematicDesign.elements > 0 then
            local now = os.date("%Y-%m-%d %H:%M:%S")
            table.insert(migratedSystems, {
                id = "sys_1", name = "My System", createdAt = now, modifiedAt = now,
                elements = schematicDesign.elements, wires = schematicDesign.wires,
                controls = schematicDesign.controls or {}, snapshots = schematicDesign.snapshots or {},
            })
        else
            table.insert(migratedSystems, _buildDemoSystem())
        end
        local now = os.date("%Y-%m-%d %H:%M:%S")
        schematicStore = {
            aircraft = {{ id = "aircraft_1", name = "My Aircraft", createdAt = now, modifiedAt = now,
                systems = migratedSystems }},
            currentAircraftId = nil, currentSystemId = nil,
            nextAircraftNum = 2,
        }
        love.filesystem.write("schematicProjects.lua", table.show(schematicStore, "schematicStore"))
    elseif schematicStore.aircraft == nil then
        -- Old flat-project-list save (pre-aircraft): wrap it all into one
        -- aircraft so existing systems aren't lost.
        local now = os.date("%Y-%m-%d %H:%M:%S")
        local legacySystems = schematicStore.projects or {}
        schematicStore = {
            aircraft = {{ id = "aircraft_1", name = "My Aircraft", createdAt = now, modifiedAt = now,
                systems = legacySystems }},
            currentAircraftId = nil, currentSystemId = nil,
            nextAircraftNum = 2,
        }
        love.filesystem.write("schematicProjects.lua", table.show(schematicStore, "schematicStore"))
    end

    -- Scale pixel coordinates from the 320-pt design canvas to the actual container width
    -- (iPhone SE 2nd gen = 375 pt reference; _x/_w return floor'd pixel values).
    local _cW = globApp.safeScreenArea.w
    local function _x(px) return math.floor(px / 320 * _cW) end
    local function _w(px) return math.floor(px / 320 * _cW) end

    -- Measure each textbox height from the actual fs=16 font (worst case) so no
    -- textbox ever requires internal scrolling at any user-selectable font size.
    local _sbH    = 30   -- scrollbar height, fixed
    local _font16 = love.graphics.newFont(16)
    local function _measuredH(maxText, frameWidth)
        local textW = (frameWidth - 10) * 0.8
        local lines = 0
        for seg in (maxText .. "\n"):gmatch("([^\n]*)\n") do
            local _, wrapped = _font16:getWrap(seg == "" and " " or seg, textW)
            lines = lines + #wrapped
        end
        return lines * _font16:getHeight() + 8
    end

    local _hUTCHdr     = _measuredH("2359 UTC",                                          _w(96))
    local _hTimer      = _measuredH("COUNT DOWN\nTIMER:\nM 59:59 S",                     _w(190))
    local _hCrosswind  = _measuredH(
        "WIND: 36046G61KT\nRWY: 36\nSUS XW:46L TW:46\nGST XW:61L TW:61\nGust Factor: 56",
        _w(200))
    local _hWindLabel  = _measuredH("WIND\nSPD",                                          75)
    local _hCalcSel    = _measuredH("SLCTD ALT:\n51000 FT",                              _w(110)) + 40
    local _hCalcRes    = _measuredH("REQ DIST:\n1925 nm",                                _w(80))  + 40
    local _hDutyStart  = _measuredH("DUTY START: 23:59Z",                                _w(310))
    local _hDutyMax    = _measuredH("MAX DUTY: 20 HRS",                                  _w(310))
    local _hLastFlight = _measuredH("LAST FLT BLOCK TIME: 18.0 HRS",                     _w(310))
    local _hDutyOut    = _measuredH("DEPART BY\n23:59Z",                                 _w(120))
    local _hDutyWarn   = _measuredH(
        "FOR REFERENCE ONLY — verify against applicable FARs and ops specs.",             _w(310))

    local _windSbY  = 10 + _hWindLabel + 5
    local _knobY    = math.max(100, 10 + _hCrosswind + 20)
    local _compassY = _knobY + 80
    local _windSbH  = _knobY + 160 - _windSbY   -- spans from below label to knob bottom
    local _calcSbY  = 47 + math.ceil(_hCalcSel / 2) + 2
    local _calcResCY = _calcSbY + math.floor(185 / 2)  -- vertical centre of the calc scrollbars
    local _dutyGap  = 8   -- section gap: scrollbar bottom → next group top
    local _lblSbGap = 4   -- label bottom → scrollbar top (tight coupling)

    -- Scrollbar y positions anchor each group; labels are derived from them.
    local _d2 = _dutyGap + _hDutyStart  + _lblSbGap
    local _d4 = _d2 + _sbH + _dutyGap  + _hDutyMax    + _lblSbGap
    local _d6 = _d4 + _sbH + _dutyGap  + _hLastFlight + _lblSbGap

    -- Label y = scrollbar y − label height − small gap (just above the scrollbar)
    local _d1 = _d2 - _hDutyStart  - _lblSbGap
    local _d3 = _d4 - _hDutyMax    - _lblSbGap
    local _d5 = _d6 - _hLastFlight - _lblSbGap

    local _d7 = _d6 + _sbH + _dutyGap
    local _d8 = _d7 + _hDutyOut    + _dutyGap

    ---------------------------------------------------------------------------
    -- SHARED HEADER / FOOTER LAYOUT VALUES
    ---------------------------------------------------------------------------
    local pageHdrH  = math.floor(globApp.safeScreenArea.h * 0.10)
    local pageFootH = pageHdrH
    local hdrCX     = math.floor(globApp.safeScreenArea.w * 0.5)
    local hdrCY     = math.floor(pageHdrH * 0.5)
    local footBtnW  = 50
    local footBtnH  = 50
    local footBtnY  = math.floor(pageFootH * 0.50)
    local footBtnX1 = math.floor(globApp.safeScreenArea.w * (1/8))
    local footBtnX2 = math.floor(globApp.safeScreenArea.w * (3/8))
    local footBtnX3 = math.floor(globApp.safeScreenArea.w * (5/8))
    local footBtnX4 = math.floor(globApp.safeScreenArea.w * (7/8))

    -- Creates the shared header + footer for one app page.
    local function createPageHeaderFooter(pageName, titleText, prefix)
        -- Header
        gdsGui_pageHeader_create(prefix .. "_header", pageName, pageHdrH, {0.15, 0.15, 0.20, 1})
        gdsGui_outputTxtBox_create(prefix .. "_pageTitle", pageName, nil,
            hdrCX, hdrCY, "CC",
            math.floor(globApp.safeScreenArea.w * 0.70), math.floor(pageHdrH * 0.5),
            {1, 1, 1, 1}, titleText, 16, prefix .. "_header"
        )
        -- Footer with 4 navigation buttons: mainMenu | systemSchematic | learn | settings
        gdsGui_pageFooter_create(prefix .. "_footer", pageName, pageFootH, {0.15, 0.15, 0.20, 1})
        gdsGui_button_create(prefix .. "_navMainMenu", pageName, "stickyToggle",
            "Sprites/button_calculator_pressed.png", "Sprites/button_calculator_released.png",
            "Sprites/button_calculator_deactivated.png",
            footBtnX1, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToMainMenu", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
        gdsGui_button_create(prefix .. "_navSchematic", pageName, "stickyToggle",
            "Sprites/button_schematic_pressed.png", "Sprites/button_schematic_released.png",
            "Sprites/button_schematic_deactivated.png",
            footBtnX2, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToSystemSchematic", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
        gdsGui_button_create(prefix .. "_navLearn", pageName, "stickyToggle",
            "Sprites/button_learn_pressed.png", "Sprites/button_learn_released.png",
            "Sprites/button_learn_deactivated.png",
            footBtnX3, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToLearn", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
        gdsGui_button_create(prefix .. "_navSettings", pageName, "stickyToggle",
            "Sprites/button_settings_pressed.png", "Sprites/button_settings_released.png",
            "Sprites/button_settings_deactivated.png",
            footBtnX4, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToSettings", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
    end

    createPageHeaderFooter("MainMenu", "MAIN MENU", "mainMenu")
    -- UTC time pinned to the right of the main menu header — always visible
    gdsGui_outputTxtBox_create("mainMenu_utcHeader", "MainMenu", nil,
        globApp.safeScreenArea.w - 4, hdrCY, "RC",
        math.floor(globApp.safeScreenArea.w * 0.30), _hUTCHdr,
        colorWarning, "0000 UTC", 16, "mainMenu_header"
    )
    createPageHeaderFooter("SystemSchematic", "SYSTEM SCHEMATIC", "schematic")
    createPageHeaderFooter("SchematicHome",          "AIRCRAFT",          "schematicHome")
    createPageHeaderFooter("SchematicManageGallery", "SYSTEMS",           "schematicManage")
    createPageHeaderFooter("AircraftGallery",        "MY AIRCRAFT",       "aircraftGallery")

    -- "<" back button on every schematic-flow page EXCEPT Home itself. Needed
    -- because the dock's schematic icon is a stickyToggle (general_gdsGuiLib.
    -- lua / buttons_gdsGuiLib.lua): once pressed it ignores all further taps
    -- until externally reset, so it cannot be tapped again to navigate while
    -- already inside the schematic flow — these pages need their own
    -- explicit way back. The canvas is "inside" the current aircraft's
    -- systems gallery (one level back — see navBackToAircraftSystems); the
    -- systems gallery itself IS "opening an aircraft" now (no separate home
    -- page in between), so it steps back to the top aircraft picker
    -- (SchematicHome), same as the aircraft gallery one level above it.
    for _, backBtn in ipairs({
        {page = "SystemSchematic",          prefix = "schematic",       callback = "navBackToAircraftSystems"},
        {page = "SchematicManageGallery",    prefix = "schematicManage", callback = "navBackToSchematicHome"},
        {page = "AircraftGallery",           prefix = "aircraftGallery", callback = "navBackToSchematicHome"},
    }) do
        gdsGui_button_create(backBtn.prefix .. "_backBtn", backBtn.page, "pushonoff",
            "Sprites/button_schematicBack_pressed.png", "Sprites/button_schematicBack_released.png",
            "Sprites/button_schematicBack_deactivated.png",
            math.floor(globApp.safeScreenArea.w * 0.08), hdrCY, "CC", 32, 32,
            backBtn.callback, globApp.BUTTON_STATES.RELEASED, false, backBtn.prefix .. "_header"
        )
    end

    createPageHeaderFooter("Learn",    "LEARN",     "learn")
    createPageHeaderFooter("Settings", "SETTINGS",  "settings")


    ---------------------------------------------------------------------------
    -- TIMER PANEL
    -- Pixel positions are relative to the container's scroll-rect origin.
    -- Design canvas: 320 px wide, 585 px tall (portrait, 32 px header stripped).
    ---------------------------------------------------------------------------
    gdsGui_container_create("timerPanel", "MainMenu", "TIMER", 32, 0)

    -- Layout anchors: timer text sits at top; control buttons clear it by 8 px.
    local _timerY = 8
    local _btnY   = _timerY + _hTimer + 8

    -- Timer text — centred across the full container width
    local text = timer.mode .. "\nTIMER:\nM " .. format_time(timer.t) .. " S"
    gdsGui_outputTxtBox_create("timerTopRight", "MainMenu", nil,
        _x(160), _timerY, "CT",
        _w(190), _hTimer,
        colorYellow, text, 12, "timerPanel"
    )

    -- Invisible alarm-acknowledge overlay: same width as before, tall enough to
    -- cover the full container content (text + gap + control button row).
    gdsGui_button_create("acknowlegeAlarm", "MainMenu", "pushonoff",
        nil, nil, nil,
        _x(160), _timerY, "CT",
        _w(190), _hTimer + 41,
        "acknowlegeAlarm", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )

    -- Min +/− buttons — inset from left edge, alongside timer text (countdown mode)
    gdsGui_button_create("incrsMinRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_min_increase_pressed.png", "Sprites/button_min_increase_released.png",
        nil, _x(20), _timerY, "LT",
        33, 33,
        "incrsMinRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )
    gdsGui_button_create("dcrsMinRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_min_decrease_pressed.png", "Sprites/button_min_decrease_released.png",
        nil, _x(20), _timerY + 36, "LT",
        33, 33,
        "dcrsMinRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )

    -- Sec +/− buttons — inset from right edge, alongside timer text (countdown mode)
    gdsGui_button_create("incrsSecRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_sec_increase_pressed.png", "Sprites/button_sec_increase_released.png",
        nil, _x(300), _timerY, "RT",
        33, 33,
        "incrsSecRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )
    gdsGui_button_create("dcrsSecRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_sec_decrease_pressed.png", "Sprites/button_sec_decrease_released.png",
        nil, _x(300), _timerY + 36, "RT",
        33, 33,
        "dcrsSecRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )

    -- Control buttons — evenly spaced row below timer text
    gdsGui_button_create("modeSelectRHTopTimer", "MainMenu", "toggle",
        "Sprites/button_timer_mode_pressed.png", "Sprites/button_timer_mode_released.png",
        "Sprites/button_timer_mode_deactivated.png", _x(100), _btnY, "CT",
        33, 33,
        "modeSelectRHTopTimer", globApp.BUTTON_STATES.RELEASED, true, "timerPanel"
    )
    gdsGui_button_create("pauseRHTopTimer", "MainMenu", "toggle",
        "Sprites/button_pause_play_pressed.png", "Sprites/button_pause_play_released.png",
        "Sprites/button_pause_play_deactivated.png", _x(160), _btnY, "CT",
        33, 33,
        "pauseRHTopTimer", globApp.BUTTON_STATES.RELEASED, true, "timerPanel"
    )
    gdsGui_button_create("resetRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_reset_pressed.png", "Sprites/button_reset_released.png",
        "Sprites/button_reset_deactivated.png", _x(220), _btnY, "CT",
        33, 33,
        "resetRHTopTimer", globApp.BUTTON_STATES.RELEASED, true, "timerPanel"
    )

    ---------------------------------------------------------------------------
    -- WIND PANEL
    ---------------------------------------------------------------------------
    gdsGui_container_create("windPanel", "MainMenu", "RUNWAY / WIND", 32, 0)

    -- Compass background: inserted first so it renders under the knob
    gdsGui_outputTxtBox_create("compassBg", "MainMenu", "Sprites/bg_compass_visible.png",
        _x(160), _compassY, "CC",
        208, 208,
        {1, 1, 1, 1}, "", 1, "windPanel"
    )

    -- Rotary knob (150×150 px square)
    gdsGui_rotaryKnob_createDual(
        "runwayKnob", "MainMenu",
        _x(160) - 80, _knobY, "LT",
        160,
        36, 0,
        "Sprites/knob_runway_released.png", "Sprites/knob_runway_pressed.png",
        "mainKnobChanged",
        36, 0,
        "Sprites/knob_wind_released.png", "Sprites/knob_wind_pressed.png",
        "windKnobChanged",
        true, "windPanel"
    )

    -- Text boxes
    gdsGui_outputTxtBox_create("crosswindData", "MainMenu", nil,
        _x(160), 10, "CT",
        _w(200), _hCrosswind,
        colorYellow, "WIND: 36000KT", 12, "windPanel"
    )
    gdsGui_outputTxtBox_create("windSpeedLabel", "MainMenu", nil,
        _x(30), 10, "CT",
        75, _hWindLabel,
        colorYellow, "WIND\nSPD", 12, "windPanel"
    )
    gdsGui_outputTxtBox_create("windGustLabel", "MainMenu", nil,
        _x(290), 10, "CT",
        75, _hWindLabel,
        colorYellow, "WIND\nGST", 12, "windPanel"
    )

    -- Scrollbars: top starts just below the speed/gust labels; bottom is fixed
    gdsGui_scrollBar_create("windSpeed", "MainMenu",
        _x(30), _windSbY, 30, _windSbH, "CT", 5, 46, 1,
        "independent", "vertical", 46, "windSpeedChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "windPanel")
    gdsGui_scrollBar_create("windGust", "MainMenu",
        _x(290), _windSbY, 30, _windSbH, "CT", 5, 61, 1,
        "independent", "vertical", 61, "windGustChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "windPanel")

    ---------------------------------------------------------------------------
    -- CALCULATIONS PANEL
    ---------------------------------------------------------------------------
    gdsGui_container_create("calcPanel", "MainMenu", "ASCEND / DESCEND", 32, 0)

    -- Text boxes
    local textAltSlctd = "SLCTD ALT:\n" .. selectedAltitude .. " FT"
    gdsGui_outputTxtBox_create("selectedAltitudeBox", "MainMenu", nil,
        _x(164), 47, "CC",
        _w(110), _hCalcSel,
        colorYellow, textAltSlctd, 12, "calcPanel"
    )
    local textTimeSlctd = "SLCTD TIME:\n" .. selectedTime .. " min"
    gdsGui_outputTxtBox_create("selectedTimeBox", "MainMenu", nil,
        _x(52), 47, "CC",
        _w(110), _hCalcSel,
        colorYellow, textTimeSlctd, 12, "calcPanel"
    )
    local textDegreeSlctd = "SLCTD DEG:\n" .. string.format("%.2f", selectedDegree) .. "°"
    gdsGui_outputTxtBox_create("selectedDegreeBox", "MainMenu", nil,
        _x(267), 47, "CC",
        _w(110), _hCalcSel,
        colorYellow, textDegreeSlctd, 12, "calcPanel"
    )
    local requiredFPM = 0
    if selectedTime > 0 then
        requiredFPM = math.ceil(selectedAltitude / selectedTime)
    end
    local requiredFPMtext = "REQ FPM:\n" .. requiredFPM
    gdsGui_outputTxtBox_create("requiredFPM", "MainMenu", nil,
        _x(110), _calcResCY, "CC",
        _w(80), _hCalcRes,
        colorYellow, requiredFPMtext, 12, "calcPanel"
    )
    local requiredDistance = 0
    if selectedDegree > 0 and selectedAltitude > 0 then
        requiredDistance = math.floor(selectedAltitude / (math.tan(math.rad(selectedDegree)) * 6076.115) + 0.5)
    end
    local requiredDistText = "REQ DIST:\n" .. requiredDistance .. " nm"
    gdsGui_outputTxtBox_create("requiredDistance", "MainMenu", nil,
        _x(211), _calcResCY, "CC",
        _w(80), _hCalcRes,
        colorYellow, requiredDistText, 12, "calcPanel"
    )

    -- Scrollbars: top starts just below the selector boxes
    gdsGui_scrollBar_create("timeScale", "MainMenu",
        _x(51), _calcSbY, 30, 185, "CT", 5, 26, 1,
        "independent", "vertical", 26, "roundSelectedTime",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "calcPanel")
    gdsGui_scrollBar_create("altScale", "MainMenu",
        _x(160), _calcSbY, 30, 185, "CT", 5, 52, 1,
        "independent", "vertical", 52, "roundSelectedAltitude",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "calcPanel")
    gdsGui_scrollBar_create("deg", "MainMenu",
        _x(262), _calcSbY, 30, 185, "CT", 5, 33, 1,
        "independent", "vertical", 33, "roundSelectedDegree",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "calcPanel")

    ---------------------------------------------------------------------------
    -- DUTY / FLIGHT TIME PANEL
    ---------------------------------------------------------------------------
    gdsGui_container_create("dutyPanel", "MainMenu", "DUTY / FLIGHT TIME", 32, 0)

    gdsGui_outputTxtBox_create("dutyStartBox",    "MainMenu", nil,
        _x(160), _d1, "CT", _w(310), _hDutyStart,  colorYellow, "DUTY START: 00:00Z", 12, "dutyPanel")
    gdsGui_outputTxtBox_create("dutyMaxHoursBox", "MainMenu", nil,
        _x(160), _d3, "CT", _w(310), _hDutyMax,    colorYellow, "MAX DUTY: 1 HR",     12, "dutyPanel")
    gdsGui_outputTxtBox_create("lastFlightBox",   "MainMenu", nil,
        _x(160), _d5, "CT", _w(310), _hLastFlight, colorYellow, "LAST FLT BLOCK TIME: 0.0 HRS", 12, "dutyPanel")

    gdsGui_scrollBar_create("dutyStartScale", "MainMenu",
        _x(160), _d2, _w(279), _sbH, "CT", 32, 289, 0,
        "independent", "horizontal", 289, "dutyStartChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "dutyPanel")
    gdsGui_scrollBar_create("dutyHoursScale", "MainMenu",
        _x(160), _d4, _w(279), _sbH, "CT", 5, 20, 0,
        "independent", "horizontal", 20, "dutyHoursChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "dutyPanel")
    gdsGui_scrollBar_create("lastFlightScale", "MainMenu",
        _x(160), _d6, _w(279), _sbH, "CT", 20, 181, 0,
        "independent", "horizontal", 181, "lastFlightChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "dutyPanel")

    gdsGui_outputTxtBox_create("dutyOutBox",  "MainMenu", nil,
        _x(80),  _d7, "CT", _w(120), _hDutyOut, colorYellow, "DUTY OUT\n--:--Z",  12, "dutyPanel")
    gdsGui_outputTxtBox_create("departByBox", "MainMenu", nil,
        _x(240), _d7, "CT", _w(120), _hDutyOut, colorYellow, "DEPART BY\n--:--Z", 12, "dutyPanel")
    gdsGui_outputTxtBox_create("dutyWarningBox", "MainMenu", nil,
        _x(160), _d8, "CT", _w(310), _hDutyWarn, colorWarning,
        "FOR REFERENCE ONLY — verify against applicable FARs and ops specs.", 10, "dutyPanel")

    ---------------------------------------------------------------------------
    -- LEARN PAGE CONTAINERS
    ---------------------------------------------------------------------------
    local learnFontSize = math.floor(gdsGui_general_smartFontScaling(0.035, 0.045))
    local learnTxtW     = math.floor(globApp.safeScreenArea.w * 0.85)
    local learnTxtX     = math.floor(globApp.safeScreenArea.w * 0.5)

    -- Compute the exact pixel height needed for a set of raw segments so the
    -- textbox shows all content without any internal scroll.  Mirrors _buildLines:
    -- frame.width = learnTxtW - 10 (SB_WIDTH), text.width = frame.width * 0.8.
    -- Use fs=16 for worst-case wrapping/height since _applyFontSize can set 16pt.
    local _learnFont   = love.graphics.newFont(learnFontSize)
    local _learnFont16 = love.graphics.newFont(16)
    local _learnTxtW   = (learnTxtW - 10) * 0.8
    local _learnLineH  = _learnFont16:getHeight()
    local function learnH(rawSegs)
        local n = 0
        for _, s in ipairs(rawSegs) do
            local _, wrapped = _learnFont16:getWrap(s.text, _learnTxtW)
            n = n + #wrapped
        end
        return n * _learnLineH
    end

    gdsGui_container_create("timerLearn", "Learn", "UTC / TIMER", 32, 0)
    gdsGui_outputTxtBox_create("timerLearnContent", "Learn", nil,
        learnTxtX, 10, "CT",
        learnTxtW, learnH(_LEARN_TIMER_RAW),
        {1, 1, 1, 1}, _learnSegsColored(_LEARN_TIMER_RAW, true),
        learnFontSize, "timerLearn"
    )

    gdsGui_container_create("windLearn", "Learn", "RUNWAY / WIND", 32, 0)
    gdsGui_outputTxtBox_create("windLearnContent", "Learn", nil,
        learnTxtX, 10, "CT",
        learnTxtW, learnH(_LEARN_WIND_RAW),
        {1, 1, 1, 1}, _learnSegsColored(_LEARN_WIND_RAW, true),
        learnFontSize, "windLearn"
    )

    gdsGui_container_create("calcLearn", "Learn", "ASCEND / DESCEND", 32, 0)
    gdsGui_outputTxtBox_create("calcLearnContent", "Learn", nil,
        learnTxtX, 10, "CT",
        learnTxtW, learnH(_LEARN_CALC_RAW),
        {1, 1, 1, 1}, _learnSegsColored(_LEARN_CALC_RAW, true),
        learnFontSize, "calcLearn"
    )

    gdsGui_container_create("dutyLearn", "Learn", "DUTY / FLIGHT TIME", 32, 0)
    gdsGui_outputTxtBox_create("dutyLearnContent", "Learn", nil,
        learnTxtX, 10, "CT",
        learnTxtW, learnH(_LEARN_DUTY_RAW),
        {1, 1, 1, 1}, _learnSegsColored(_LEARN_DUTY_RAW, true),
        learnFontSize, "dutyLearn"
    )

    gdsGui_container_create("settingsLearn", "Learn", "SETTINGS", 32, 0)
    gdsGui_outputTxtBox_create("settingsLearnContent", "Learn", nil,
        learnTxtX, 10, "CT",
        learnTxtW, learnH(_LEARN_SETTINGS_RAW),
        {1, 1, 1, 1}, _learnSegsColored(_LEARN_SETTINGS_RAW, true),
        learnFontSize, "settingsLearn"
    )

    ---------------------------------------------------------------------------
    -- SETTINGS PAGE CONTAINERS
    ---------------------------------------------------------------------------
    local settingsFontSize = math.floor(gdsGui_general_smartFontScaling(0.035, 0.045))
    local settingsBtnW     = 40
    local settingsBtnH     = 40
    -- RT anchor: right edge sits ~20 px from the container's right edge
    local settingsBtnX     = _x(300)
    local settingsRowY     = 12
    local settingsLabelW   = _w(240)
    local settingsLabelH   = 40

    gdsGui_container_create("displaySettings", "Settings", "DISPLAY", 32, 0)
    gdsGui_outputTxtBox_create("displayModeLabel", "Settings", nil,
        12, settingsRowY, "LT", settingsLabelW, settingsLabelH,
        {1, 1, 1, 1}, "DARK / WHITE MODE", settingsFontSize, "displaySettings"
    )
    gdsGui_button_create("darkModeToggle", "Settings", "toggle",
        "Sprites/button_bwmode_dark_released.png", "Sprites/button_bwmode_white_pressed.png",
        "Sprites/button_timer_mode_deactivated.png",
        settingsBtnX, settingsRowY, "RT", settingsBtnW, settingsBtnH,
        "darkModeToggled", globApp.BUTTON_STATES.PRESSED, true, "displaySettings"
    )

    gdsGui_container_create("soundsSettings", "Settings", "SOUNDS", 32, 0)
    gdsGui_outputTxtBox_create("soundsLabel", "Settings", nil,
        12, settingsRowY, "LT", settingsLabelW, settingsLabelH,
        {1, 1, 1, 1}, "TIMER SOUND ON / OFF", settingsFontSize, "soundsSettings"
    )
    gdsGui_button_create("soundToggle", "Settings", "toggle",
        "Sprites/button_onoff_on_released.png", "Sprites/button_onoff_off_pressed.png",
        "Sprites/button_timer_mode_deactivated.png",
        settingsBtnX, settingsRowY, "RT", settingsBtnW, settingsBtnH,
        "soundToggled", globApp.BUTTON_STATES.PRESSED, true, "soundsSettings"
    )

    gdsGui_container_create("hapticsSettings", "Settings", "HAPTICS", 32, 0)
    gdsGui_outputTxtBox_create("hapticsLabel", "Settings", nil,
        12, settingsRowY, "LT", settingsLabelW, settingsLabelH,
        {1, 1, 1, 1}, "VIBRATION ON / OFF", settingsFontSize, "hapticsSettings"
    )
    gdsGui_button_create("hapticsToggle", "Settings", "toggle",
        "Sprites/button_onoff_on_released.png", "Sprites/button_onoff_off_pressed.png",
        "Sprites/button_timer_mode_deactivated.png",
        settingsBtnX, settingsRowY, "RT", settingsBtnW, settingsBtnH,
        "hapticsToggled", globApp.BUTTON_STATES.PRESSED, false, "hapticsSettings"
    )

    gdsGui_container_create("fontSizeSettings", "Settings", "FONT SIZE", 32, 0)
    gdsGui_outputTxtBox_create("fontSizeLabel", "Settings", nil,
        12, settingsRowY, "LT", settingsLabelW, settingsLabelH,
        {1, 1, 1, 1}, "FONT SIZE: 12pt", settingsFontSize, "fontSizeSettings"
    )
    gdsGui_scrollBar_create("fontSizeScale", "Settings",
        _x(160), 60, _w(270), 30, "CT", 5, 5, 0,
        "independent", "horizontal", 5, "fontSizeChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"},
        true, "fontSizeSettings"
    )

    ---------------------------------------------------------------------------
    -- SYSTEM SCHEMATIC PAGE (premium feature)
    -- The canvas is NOT container-managed (container_gdsGuiLib.lua only lays
    -- out button/outputTextBox/scrollBar/rotaryKnob) — it is a standalone
    -- region sized/positioned the same way the header/footer strips are,
    -- filling the body between them. Floating control buttons below the
    -- header are created without a containerName so they draw directly on
    -- top of the canvas (gdsGui_button_draw runs after gdsGui_schematic_draw).
    ---------------------------------------------------------------------------
    local schBtnRowYFrac = (pageHdrH + 16) / globApp.safeScreenArea.h
    local schLabelYFrac  = (pageHdrH + 16 + 30 + 10) / globApp.safeScreenArea.h
    local schCanvasYFrac = schLabelYFrac + (24 / globApp.safeScreenArea.h)
    local schCanvasHFrac = 1 - schCanvasYFrac - (pageFootH / globApp.safeScreenArea.h) - 0.01
    -- canvas.w = wFrac*safeW, canvas.h = hFrac*safeH, so canvas.w/canvas.h
    -- only equals the screen's own aspect ratio (safeW/safeH) when
    -- wFrac == hFrac. Setting wFrac to schCanvasHFrac (instead of the old
    -- fixed 1.0 = full width) makes the embedded canvas's box the same
    -- shape as the full-screen page, so going full screen (see
    -- schematicFullScreenTogglePressed) is a uniform scale-up with no
    -- stretch — centered horizontally since it's now narrower than the
    -- full safe width.
    local schCanvasWFrac = schCanvasHFrac
    local schCanvasXFrac = (1 - schCanvasWFrac) / 2

    -- 4-button row: MODE | ACTIONS (mode-sensitive: add/reset in design, select
    -- control in control) | SNAPSHOT | FULL SCREEN. No dedicated wire tool
    -- button — a wire is drawn via ADD WIRE on an element's own edit menu
    -- instead (see gdsGui_schematic_internal_onElementEditChosen).
    -- SNAPSHOT is the only place a snapshot can be captured (design mode
    -- only, same gating the old DELETE SELECTED button used) — the ACTIONS
    -- menu no longer offers CAPTURE SNAPSHOT. Per-element/wire deletion is
    -- handled by tapping the selected element/wire's own edit menu.
    -- MODE shows the icon for the action a tap performs, not the current mode:
    -- a steering wheel (tap to go operate/control) while in design, a pencil
    -- (tap to go edit/design) while in control.
    gdsGui_button_create("schematicModeToggle", "SystemSchematic", "toggle",
        "Sprites/button_schematicModeToggle_pressed.png", "Sprites/button_schematicModeToggle_released.png",
        "Sprites/button_schematicModeToggle_deactivated.png",
        0.125, schBtnRowYFrac, "CT", 30, 30,
        "schematicModeToggled", globApp.BUTTON_STATES.PRESSED, true, nil
    )
    -- ACTIONS: opens a mode-sensitive menu rather than acting directly, since
    -- it now covers everything design/control mode can do besides capturing
    -- a snapshot and deleting a single selected element
    -- (see schematicContextButtonPressed).
    gdsGui_button_create("schematicContextButton", "SystemSchematic", "pushonoff",
        "Sprites/button_menu_pressed.png", "Sprites/button_menu_released.png",
        "Sprites/button_menu_deactivated.png",
        0.375, schBtnRowYFrac, "CT", 30, 30,
        "schematicContextButtonPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    -- SNAPSHOT (camera): the sole entry point for capturing a snapshot of
    -- the current control combination's colors. Design-mode only, same
    -- enable/disable gating the old DELETE SELECTED button used.
    gdsGui_button_create("schematicSnapshotBtn", "SystemSchematic", "pushonoff",
        "Sprites/button_snapshot_pressed.png", "Sprites/button_snapshot_released.png", "Sprites/button_snapshot_deactivated.png",
        0.625, schBtnRowYFrac, "CT", 30, 30,
        "captureSchematicSnapshot", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    -- FULL SCREEN: viewing-only convenience, so it's only enabled in control
    -- mode (deactivated in design, same gating pattern as SNAPSHOT in reverse).
    gdsGui_button_create("schematicFullScreenToggle", "SystemSchematic", "pushonoff",
        "Sprites/button_fullScreen_pressed.png",
        "Sprites/button_fullScreen_released.png",
        "Sprites/button_fullScreen_deactivated.png",
        0.875, schBtnRowYFrac, "CT", 30, 30,
        "schematicFullScreenTogglePressed", globApp.BUTTON_STATES.DEACTIVATED, true, nil
    )
    -- ADD ("+"): floating at the canvas's own top-right corner rather than in
    -- the 4-button row above (containerName nil, same floating-chrome
    -- convention as every other button here — positioned straight off
    -- safeScreenArea, not off the canvas box, so it never moves with the
    -- canvas's own pan/zoom). Design-mode only, same enable/disable gating
    -- SNAPSHOT uses (see schematicModeToggled/_openSystemIntoCanvas) — the
    -- sole entry point into the ADD cascade now (see schematicAddBtnPressed),
    -- replacing the old ACTIONS-menu "ADD ELEMENT/CONTROL" row.
    gdsGui_button_create("schematicAddBtn", "SystemSchematic", "pushonoff",
        "Sprites/button_schematicAdd_pressed.png",
        "Sprites/button_schematicAdd_released.png",
        "Sprites/button_schematicAdd_deactivated.png",
        0.97, schCanvasYFrac, "RT", 36, 36,
        "schematicAddBtnPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    -- PAINT (brush): docked directly below ADD, same floating-chrome
    -- convention. A sticky on/off toggle (unlike every other dock button
    -- here, which are momentary "pushonoff") since it represents a mode that
    -- stays active across any number of canvas taps — see
    -- schematicPaintBtnPressed/gdsGui_schematic_armPaintMode. Design-mode
    -- only, same enable/disable gating SNAPSHOT/ADD use. Replaces the old
    -- per-item edit menu's embedded color-swatch row (see
    -- gdsGui_schematic_openElementEditMenu and its wire/control siblings).
    gdsGui_button_create("schematicPaintBtn", "SystemSchematic", "toggle",
        "Sprites/button_schematicPaint_pressed.png",
        "Sprites/button_schematicPaint_released.png",
        "Sprites/button_schematicPaint_deactivated.png",
        0.97, schCanvasYFrac + (36 + 10) / globApp.safeScreenArea.h, "RT", 36, 36,
        "schematicPaintBtnPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    -- ANNUNCIATOR: docked directly below PAINT, same floating-chrome
    -- convention and sticky "toggle" type (stays open across any number of
    -- row taps, same as PAINT staying armed — see
    -- schematicAnnunciatorBtnPressed/gdsGui_schematic_setAnnunciatorPanelOpen).
    -- Design-mode only, same enable/disable gating SNAPSHOT/ADD/PAINT use.
    gdsGui_button_create("schematicAnnunciatorBtn", "SystemSchematic", "toggle",
        "Sprites/button_schematicAnnunciator_pressed.png",
        "Sprites/button_schematicAnnunciator_released.png",
        "Sprites/button_schematicAnnunciator_deactivated.png",
        0.97, schCanvasYFrac + 2 * (36 + 10) / globApp.safeScreenArea.h, "RT", 36, 36,
        "schematicAnnunciatorBtnPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    -- COMBINATION PREV/NEXT — design-mode-only, fixed at the left/right
    -- middle of the screen (containerName nil, so like every other floating
    -- schematic chrome button they're positioned straight off safeScreenArea
    -- and never move with the canvas's own pan/zoom). Each press walks the
    -- control-position combination counter one step (see
    -- gdsGui_schematic_stepCombination) — deactivated whenever there's
    -- nothing to cycle (control mode, or fewer than 2 total combinations),
    -- see the per-frame poll in love.update() below.
    gdsGui_button_create("schematicCombPrevBtn", "SystemSchematic", "pushonoff",
        "Sprites/button_schematicCombPrev_pressed.png",
        "Sprites/button_schematicCombPrev_released.png",
        "Sprites/button_schematicCombPrev_deactivated.png",
        0, 0.5, "LC", 32, 64,
        "schematicCombPrevPressed", globApp.BUTTON_STATES.DEACTIVATED, true, nil
    )
    gdsGui_button_create("schematicCombNextBtn", "SystemSchematic", "pushonoff",
        "Sprites/button_schematicCombNext_pressed.png",
        "Sprites/button_schematicCombNext_released.png",
        "Sprites/button_schematicCombNext_deactivated.png",
        1, 0.5, "RC", 32, 64,
        "schematicCombNextPressed", globApp.BUTTON_STATES.DEACTIVATED, true, nil
    )
    -- Narrowed from the old full-width centered box (and anchored off the
    -- opposite side of center) to leave room for schematicZoomLabel right
    -- beside it, so the pair reads as one centered row: "SNAPSHOTS: 0  1.0x".
    gdsGui_outputTxtBox_create("schematicSnapshotLabel", "SystemSchematic", nil,
        0.48, schLabelYFrac, "RT", _w(150), 20,
        colorYellow, "SNAPSHOTS: 0", 12, nil
    )
    gdsGui_outputTxtBox_create("schematicZoomLabel", "SystemSchematic", nil,
        0.52, schLabelYFrac, "LT", _w(60), 20,
        colorYellow, "1.0x", 12, nil
    )
    -- COMBINATION readout — [current/total] of every possible control-
    -- position combination, plus a checkmark that's green once a snapshot
    -- has been captured for whichever combination is currently showing
    -- (gray/empty otherwise). Sits right of schematicZoomLabel, same row.
    -- Widened from the old 46px so multi-digit totals (e.g. "[12/16]")
    -- never wrap to a second line (see _buildLines' getWrap in
    -- outputTxtBox_gdsGuiLib.lua — wrap is width-triggered, so staying
    -- comfortably under the available gap before schematicCombCheckIcon
    -- is what keeps this box single-line).
    gdsGui_outputTxtBox_create("schematicCombLabel", "SystemSchematic", nil,
        0.72, schLabelYFrac, "LT", _w(66), 20,
        colorYellow, "[1/1]", 12, nil
    )
    -- fontSize 10 (not 1) despite this box showing no text of its own: love's
    -- font is global draw state, and outputTxtBox_draw sets it per box
    -- (including text-less ones) — being the last outputTxtBox on this page,
    -- a tiny fontSize here would otherwise leak into gdsGui_schematic_draw's
    -- own element/control label text right after, shrinking it to the point
    -- of illegibility (see schematicZoomLabel/schematicCombLabel above, which
    -- this matches).
    gdsGui_outputTxtBox_create("schematicCombCheckIcon", "SystemSchematic",
        "Sprites/icon_schematicCombSnapshot_empty.png",
        0.985, schLabelYFrac, "RT", _w(16), _w(16),
        {1, 1, 1, 1}, "", 12, nil
    )
    gdsGui_schematic_create("mainCanvas", "SystemSchematic", schCanvasXFrac, schCanvasYFrac, "LT", schCanvasWFrac, schCanvasHFrac)
    -- So the paint-mode swatch palette cascades from the PAINT dock button
    -- itself (see _paintPaletteGeometry in schematic_gdsGuiLib.lua) instead
    -- of floating at an unrelated spot on the canvas.
    gdsGui_schematic_setPaintButtonName("mainCanvas", "schematicPaintBtn")
    -- Same convention for the annunciator management panel, cascading
    -- leftward out of its own dock button — see
    -- _annunciatorPanelGeometry in schematic_gdsGuiLib.lua.
    gdsGui_schematic_setAnnunciatorButtonName("mainCanvas", "schematicAnnunciatorBtn")
    gdsGui_schematic_setBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvas.png")
    gdsGui_schematic_setCornerBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvasCorner.png")
    gdsGui_schematic_setCornerRightBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvasCornerRight.png")
    gdsGui_schematic_setCornerTopRightBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvasCornerTopRight.png")
    -- Fires on every design-mode edit (add/move/rotate/recolor/rename/
    -- delete/property change — see _notifyChanged in schematic_gdsGuiLib.lua),
    -- so in-progress work survives a quit/background without waiting for the
    -- next page-nav save point.
    _findSchematicCanvas().onChange = "schematicCanvasChanged"
    -- Starts empty: the canvas is only ever populated by an explicit NEW
    -- SYSTEM or OPEN action from the aircraft flow (see _openSystemIntoCanvas above).
    _schematicCanvasNormalLayout = { x = schCanvasXFrac, y = schCanvasYFrac, anchorPoint = "LT", wFrac = schCanvasWFrac, hFrac = schCanvasHFrac }
    -- Once zoomed in past 1x, the embedded box progressively grows from the
    -- screen-aspect-matched box above toward the full header-to-footer
    -- rectangle (full width, same height — height has ~0 slack to grow, see
    -- schCanvasHFrac's computation above). The growth is a smooth blend over
    -- the zoom range (see gdsGui_schematic_setZoomedLayout/_calculateGeometry
    -- in the library), not a snap, and element/control scaling is kept on a
    -- fixed basis independent of this box, so widening it never distorts
    -- their aspect ratio.
    _schematicCanvasZoomedLayout = { x = 0, y = schCanvasYFrac, anchorPoint = "LT", wFrac = 1.0, hFrac = schCanvasHFrac }
    gdsGui_schematic_setZoomedLayout("mainCanvas",
        _schematicCanvasZoomedLayout.x, _schematicCanvasZoomedLayout.y, _schematicCanvasZoomedLayout.anchorPoint,
        _schematicCanvasZoomedLayout.wFrac, _schematicCanvasZoomedLayout.hFrac)

    -- FULL-SCREEN RETURN BUTTON — the only control on the dedicated full-
    -- screen page; tapping it hands mainCanvas back to its normal embedded
    -- layout on SystemSchematic (see schematicFullScreenReturnPressed).
    gdsGui_button_create("schematicFullScreenReturnBtn", "SchematicFullScreen", "pushonoff",
        "Sprites/button_smallerScreen_pressed.png",
        "Sprites/button_smallerScreen_released.png",
        "Sprites/button_smallerScreen_deactivated.png",
        0.95, 0.04, "RT", 36, 36,
        "schematicFullScreenReturnPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )

    ---------------------------------------------------------------------------
    -- SCHEMATIC HOME PAGE (premium feature) — NEW AIRCRAFT / MY AIRCRAFT, the
    -- landing point for the schematic dock icon once unlocked. Both buttons'
    -- sprites are native 400x200 (2:1) art; height is derived from width so
    -- the sprite is scaled uniformly instead of stretched to a mismatched box.
    -- Reused as-is (same sizing) for AIRCRAFT HOME's NEW SYSTEM / MY SYSTEMS
    -- pair below — same generic NEW/LOAD sprites, one level deeper.
    ---------------------------------------------------------------------------
    local schHomeBtnW = math.floor(_w(220) / 3)
    local schHomeBtnH = math.floor(schHomeBtnW / 2)
    gdsGui_button_create("schematicHomeNew", "SchematicHome", "pushonoff",
        "Sprites/button_schematicHomeNew_pressed.png", "Sprites/button_schematicHomeNew_released.png",
        "Sprites/button_schematicHomeNew_deactivated.png",
        0.5, 0.40, "CC", schHomeBtnW, schHomeBtnH,
        "schematicHomeNewPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    -- Single consolidated entry point for every saved aircraft: opening it,
    -- renaming it, and deleting it are all offered from the per-aircraft
    -- action menu on AircraftGallery (see schematicAircraftActionChosen).
    -- Disabled until at least one aircraft exists.
    gdsGui_button_create("schematicHomeMyAircraft", "SchematicHome", "pushonoff",
        "Sprites/button_schematicHomeLoad_pressed.png", "Sprites/button_schematicHomeLoad_released.png",
        "Sprites/button_schematicHomeLoad_deactivated.png",
        0.5, 0.60, "CC", schHomeBtnW, schHomeBtnH,
        "schematicHomeMyAircraftPressed",
        (#schematicStore.aircraft > 0) and globApp.BUTTON_STATES.RELEASED or globApp.BUTTON_STATES.DEACTIVATED,
        true, nil
    )

    ---------------------------------------------------------------------------
    -- SCHEMATIC MANAGE GALLERY PAGE — scrollable grid of mini live-rendered
    -- diagram previews, one per system on the current aircraft; handles
    -- opening AND editing.
    ---------------------------------------------------------------------------
    local schGalleryYFrac = pageHdrH / globApp.safeScreenArea.h
    local schGalleryHFrac = 1 - schGalleryYFrac - (pageFootH / globApp.safeScreenArea.h)
    gdsGui_schematicGallery_create("manageGallery", "SchematicManageGallery", 0, schGalleryYFrac, "LT",
        1.0, schGalleryHFrac, 2, "NO SYSTEMS YET")
    gdsGui_schematicGallery_setOnSelect("manageGallery", "schematicSystemGallerySelected")

    ---------------------------------------------------------------------------
    -- AIRCRAFT GALLERY PAGE — scrollable grid of tiles, one per saved
    -- aircraft; handles opening AND editing. Reuses the same generic gallery
    -- widget as SCHEMATIC MANAGE GALLERY above, but an aircraft record has no
    -- .elements/.wires of its own (only its systems do), so each tile's
    -- mini-diagram preview area renders blank — just the name label shows.
    ---------------------------------------------------------------------------
    gdsGui_schematicGallery_create("aircraftGallery", "AircraftGallery", 0, schGalleryYFrac, "LT",
        1.0, schGalleryHFrac, 2, "NO AIRCRAFT YET")
    gdsGui_schematicGallery_setOnSelect("aircraftGallery", "schematicAircraftGallerySelected")

    ---------------------------------------------------------------------------
    -- SCHEMATIC PAYWALL PAGE (premium-feature gate)
    ---------------------------------------------------------------------------
    createSchematicPaywallObjects()

    ---------------------------------------------------------------------------
    -- TERMS AND CONDITIONS PAGE
    ---------------------------------------------------------------------------
    createTermsAndConditionsObjects()

    ---------------------------------------------------------------------------
    -- FINALISE
    ---------------------------------------------------------------------------
    gdsGui_container_finalise("MainMenu")
    gdsGui_container_finalise("Learn")
    gdsGui_container_finalise("Settings")
    gdsGui_container_finalise("SystemSchematic")
    gdsGui_container_finalise("SchematicHome")
    gdsGui_container_finalise("SchematicManageGallery")
    gdsGui_container_finalise("AircraftGallery")
    gdsGui_container_finalise("SchematicPaywall")
    gdsGui_container_finalise("TermsAndConditions")

    _applyTheme(appSettings.darkMode)
    gdsGui_button_setState("darkModeToggle", appSettings.darkMode       and "pushed" or "released")
    gdsGui_button_setState("soundToggle",    appSettings.soundEnabled   and "pushed" or "released")
    gdsGui_button_setState("hapticsToggle",  appSettings.hapticsEnabled and "pushed" or "released")
    _applyFontSize(appSettings.fontSize)

    -- mainCanvas starts empty; _openSystemIntoCanvas() sets its mode and the
    -- dock button states the moment a system is actually opened, so there is
    -- nothing to initialise here — UNLESS this boot is resuming straight back
    -- into a system the user was actively looking at when the app last quit
    -- or backgrounded (appSettings.schematicResumeActive — see
    -- _saveSchematicResumeState), in which case it's loaded right here before
    -- the very first page switch below ever lands on MainMenu at all.
    local showTC = (appSettings.tcAcceptedVersion ~= APP_VERSION)
    local resumeSystem = (not showTC) and appSettings.schematicResumeActive and appSettings.schematicUnlocked
        and _findSystem(schematicStore.currentSystemId)

    if resumeSystem then
        _openSystemIntoCanvas(resumeSystem.id, appSettings.schematicEditMode and "design" or "control")
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
    else
        _navSyncAll("MainMenu")
        gdsGui_page_switch("IntialBooting", showTC and 4 or 3, 3, false)
    end

    -- Initialize starting time
    timer.t = 0

    -- Load alarm and UI feedback sounds
    beepSound        = love.audio.newSource("Sounds/DoubleChime_piano.wav", "static")
    singleChimeSound = love.audio.newSource("Sounds/SingleChime_piano.wav", "static")

    -- Load ack overlay images (drawn manually on top of all other objects)
    _ackReleasedImg = love.graphics.newImage("Sprites/button_ack_released.png")
    _ackPushedImg   = love.graphics.newImage("Sprites/button_ack_pressed.png")

    selectedAltitude = 0
    selectedTime = 0
end

function love.update(dt)
    -- Catches up any schematic save _requestSchematicSave() deferred (see its
    -- own comment) once the throttle window elapses, even if no further edit
    -- comes along to trigger the write itself.
    if _schematicDirty and love.timer.getTime() - _schematicLastSaveTime >= _SCHEMATIC_SAVE_THROTTLE_SECONDS then
        _saveCurrentSystem()
    end

    -- Update UTC clock header label only when the minute changes
    utc = os.date("!*t")
    if utc.min ~= lastUtcMin then
        lastUtcMin = utc.min
        gdsGui_outputTxtBox_setText("mainMenu_utcHeader",
            string.format("%02d%02d UTC", utc.hour, utc.min))
    end

    if timer.t ~= _prevTimerT or timer.mode ~= _prevTimerMode then
        gdsGui_outputTxtBox_setText("timerTopRight", timer.mode .. "\nTIMER:\nM " .. format_time(timer.t) .. " S")
        _prevTimerT, _prevTimerMode = timer.t, timer.mode
    end

    local altChanged    = selectedAltitude ~= _prevAltitude
    local timeChanged   = selectedTime     ~= _prevTime
    local degreeChanged = selectedDegree   ~= _prevDegree

    if altChanged then
        gdsGui_outputTxtBox_setText("selectedAltitudeBox", "SLCTD ALT:\n" .. selectedAltitude .. " FT")
    end

    if timeChanged then
        gdsGui_outputTxtBox_setText("selectedTimeBox", "SLCTD TIME\n" .. selectedTime .. " min")
    end

    if degreeChanged then
        gdsGui_outputTxtBox_setText("selectedDegreeBox", "SLCTD DEG:\n" .. string.format("%.2f", selectedDegree) .. "°")
    end

    if altChanged or timeChanged then
        local requiredFPM = 0
        if selectedTime > 0 then requiredFPM = math.ceil(selectedAltitude / selectedTime) end
        gdsGui_outputTxtBox_setText("requiredFPM", "REQ FPM:\n" .. requiredFPM)
    end

    if altChanged or degreeChanged then
        local requiredDistance = 0
        if selectedDegree > 0 and selectedAltitude > 0 then
            requiredDistance = math.floor(selectedAltitude / (math.tan(math.rad(selectedDegree)) * 6076.115) + 0.5)
        end
        gdsGui_outputTxtBox_setText("requiredDistance", "REQ DIST:\n" .. requiredDistance .. " nm")
    end

    _prevAltitude, _prevTime, _prevDegree = selectedAltitude, selectedTime, selectedDegree

    if selectedWindDirection ~= _prevWindDir or selectedWindSpeed ~= _prevWindSpeed or
       selectedWindGust ~= _prevWindGust or selectedKnobPos ~= _prevKnobPos then
        local rwyDeg = selectedKnobPos * 10
        local susXW, susSide, susHT, susLabel = calcWindComponents(selectedWindDirection, selectedWindSpeed, rwyDeg)
        local crosswindText
        if selectedWindGust > selectedWindSpeed then
            local gstXW, gstSide, gstHT, gstLabel = calcWindComponents(selectedWindDirection, selectedWindGust, rwyDeg)
            crosswindText = string.format(
                "WIND: %03d%02dG%02dKT\nRWY: %02d\nSUS XW:%d%s %s:%d\nGST XW:%d%s %s:%d\nGust Factor: %d",
                selectedWindDirection, selectedWindSpeed, selectedWindGust,
                selectedKnobPos,
                susXW, susSide, susLabel, susHT,
                gstXW, gstSide, gstLabel, gstHT,
                selectedWindGust - selectedWindSpeed)
        else
            crosswindText = string.format(
                "WIND: %03d%02dKT\nRWY: %02d\nSUS XW:%d%s %s:%d",
                selectedWindDirection, selectedWindSpeed,
                selectedKnobPos,
                susXW, susSide, susLabel, susHT)
        end
        gdsGui_outputTxtBox_setText("crosswindData", crosswindText)
        _prevWindDir, _prevWindSpeed, _prevWindGust, _prevKnobPos =
            selectedWindDirection, selectedWindSpeed, selectedWindGust, selectedKnobPos
    end

    if dutyMaxHours ~= _prevDutyMaxHours or dutyStartMins ~= _prevDutyStartMins or lastFlightHours ~= _prevLastFlightHours then
        local dutyHrsLabel = dutyMaxHours == 1 and "1 HR" or (dutyMaxHours .. " HRS")
        gdsGui_outputTxtBox_setText("dutyMaxHoursBox", "MAX DUTY: " .. dutyHrsLabel)
        gdsGui_outputTxtBox_setText("dutyStartBox",
            string.format("DUTY START: %02d:%02dZ", math.floor(dutyStartMins / 60), dutyStartMins % 60))
        gdsGui_outputTxtBox_setText("lastFlightBox", string.format("LAST FLT BLOCK TIME: %.1f HRS", lastFlightHours))
        local dutyEndTotalMins = dutyStartMins + dutyMaxHours * 60
        local dutyOutH = math.floor(dutyEndTotalMins / 60) % 24
        local dutyOutM = dutyEndTotalMins % 60
        gdsGui_outputTxtBox_setText("dutyOutBox", string.format("DUTY OUT\n%02d:%02dZ", dutyOutH, dutyOutM))
        local fltTotalMins = math.floor(lastFlightHours * 60 + 0.5)
        local departMins   = (dutyEndTotalMins - fltTotalMins) % (24 * 60)
        gdsGui_outputTxtBox_setText("departByBox",
            string.format("DEPART BY\n%02d:%02dZ", math.floor(departMins / 60), departMins % 60))
        _prevDutyMaxHours    = dutyMaxHours
        _prevDutyStartMins   = dutyStartMins
        _prevLastFlightHours = lastFlightHours
    end

    -- Schematic zoom readout (normal-mode header pair + full-screen corner
    -- label, drawn separately below) — zoom changes continuously via
    -- pinch/wheel/drag, not through a discrete callback, so this is polled
    -- here like the other live readouts above rather than pushed from the
    -- gesture handlers themselves.
    local schematicZoom = gdsGui_schematic_getZoom("mainCanvas")
    if schematicZoom then
        local zoomText = string.format("%.1fx", schematicZoom)
        if zoomText ~= _prevSchematicZoomText then
            _prevSchematicZoomText = zoomText
            gdsGui_outputTxtBox_setText("schematicZoomLabel", zoomText)
        end
    end

    -- Schematic combination readout ([current/total] + snapshot checkmark,
    -- PREV/NEXT button activation) — polled for the same reason the zoom
    -- readout above is: the combination a control-mode tap/cycle lands on
    -- changes outside of any callback this app layer owns, so there's no
    -- single discrete event to push from. gdsGui_schematic_isMenuOpen also
    -- guards against polling mid-placement, where canvas.controls can be in
    -- a transient state.
    local schematicCanvas = _findSchematicCanvas()
    if schematicCanvas and not gdsGui_schematic_isMenuOpen("mainCanvas") then
        if _schematicCombControlsChanged(schematicCanvas) then
            _schematicCombIndex = gdsGui_schematic_getCombinationIndex("mainCanvas")
            _schematicCombTotal = gdsGui_schematic_getCombinationTotal("mainCanvas")
            _schematicCombSig   = gdsGui_schematic_computeSignature("mainCanvas")
        end
        local combIndex = _schematicCombIndex
        local combTotal = _schematicCombTotal
        local combText = string.format("[%d/%d]", combIndex, combTotal)
        if combText ~= _prevSchematicCombText then
            _prevSchematicCombText = combText
            gdsGui_outputTxtBox_setText("schematicCombLabel", combText)
        end

        -- Not gated behind _schematicCombControlsChanged above — a snapshot
        -- capture/delete changes canvas.snapshots without changing any
        -- control's id/detentIndex/numDetents, so this stays a fresh,
        -- cheap (O(1) hash lookup) check every frame off of _schematicCombSig.
        local hasSnap = gdsGui_schematic_hasSnapshot("mainCanvas", _schematicCombSig)
        if hasSnap ~= _prevSchematicCombHasSnapshot then
            _prevSchematicCombHasSnapshot = hasSnap
            gdsGui_outputTxtBox_setBgSprite("schematicCombCheckIcon",
                hasSnap and "Sprites/icon_schematicCombSnapshot_taken.png" or "Sprites/icon_schematicCombSnapshot_empty.png")
        end

        -- PREV/NEXT are design-mode-only chrome, so they're fully hidden in
        -- control mode (not just deactivated) rather than sitting around as
        -- grayed-out arrows with nothing to cycle in that mode.
        local isControlMode = gdsGui_schematic_getMode("mainCanvas") == "control"
        if isControlMode ~= _prevSchematicCombHidden then
            _prevSchematicCombHidden = isControlMode
            gdsGui_button_setHidden("schematicCombPrevBtn", isControlMode)
            gdsGui_button_setHidden("schematicCombNextBtn", isControlMode)
        end

        -- schematicPaintBtn is a sticky "toggle" button that already shows
        -- PRESSED the instant the user taps it on (schematicPaintBtnPressed
        -- arms it directly) — this poll only needs to catch the OTHER ways
        -- paint mode can turn off without a button press (a mode switch or
        -- project reload resets canvas.paintMode from inside the library),
        -- which would otherwise leave the button stuck showing PRESSED after
        -- paintMode itself has already gone nil. Computed before canCycle
        -- below since PREV/NEXT are also deactivated while painting.
        local paintActive = gdsGui_schematic_isPaintModeActive("mainCanvas")
        if not paintActive and _prevSchematicPaintActive then
            gdsGui_button_setState("schematicPaintBtn", "released")
        end
        _prevSchematicPaintActive = paintActive

        -- Same stuck-toggle correction as schematicPaintBtn just above:
        -- schematicAnnunciatorBtn shows PRESSED the instant the user taps it
        -- (schematicAnnunciatorBtnPressed arms it directly), so this only
        -- needs to catch the panel closing some OTHER way — a mode switch,
        -- or armPaintMode/an ADD placement closing it via
        -- gdsGui_schematic_cancelPlacement (see gdsGui_schematic_setAnnunciatorPanelOpen).
        local annunciatorPanelOpen = gdsGui_schematic_isAnnunciatorPanelOpen("mainCanvas")
        if not annunciatorPanelOpen and _prevSchematicAnnunciatorPanelOpen then
            gdsGui_button_setState("schematicAnnunciatorBtn", "released")
        end
        _prevSchematicAnnunciatorPanelOpen = annunciatorPanelOpen

        -- schematicAddBtn (the "+" dock button) is likewise deactivated while
        -- the brush is armed — starting the ADD cascade mid-stroke would
        -- abandon the paint. Left alone in control mode, where the button is
        -- already hidden/deactivated by the mode-switch code (see
        -- _loadSchematicSystem and schematicModeTogglePressed).
        if not isControlMode then
            local addEnabled = not paintActive
            if addEnabled ~= _prevSchematicAddBtnEnabled then
                _prevSchematicAddBtnEnabled = addEnabled
                gdsGui_button_setState("schematicAddBtn", addEnabled and "released" or "deactivated")
            end
        end

        -- Only pushed on change (not every frame) so a mid-press PRESSED
        -- sprite isn't stomped back to RELEASED by this poll before the
        -- button library gets a chance to draw it. Also deactivated while
        -- the brush is armed — cycling combinations out from under an active
        -- paint would change which snapshot a paint applies to mid-stroke.
        local canCycle = combTotal > 1 and not isControlMode and not paintActive
        if canCycle ~= _prevSchematicCombCanCycle then
            _prevSchematicCombCanCycle = canCycle
            local state = canCycle and "released" or "deactivated"
            gdsGui_button_setState("schematicCombPrevBtn", state)
            gdsGui_button_setState("schematicCombNextBtn", state)
        end

        local snapCount = gdsGui_schematic_countSnapshots("mainCanvas")
        if snapCount ~= _prevSchematicSnapshotCount then
            _prevSchematicSnapshotCount = snapCount
            gdsGui_outputTxtBox_setText("schematicSnapshotLabel", "SNAPSHOTS: " .. snapCount)
        end
    end

    -- Unlock T&C agree toggle once user has scrolled to the bottom at least once.
    if not _tcScrolledToBottom and gdsGui_outputTxtBox_hasReachedBottom("tcText") then
        _tcScrolledToBottom = true
        gdsGui_button_setState("tcAgreementToggle", "released")
    end

    -- Update GUI
    gdsGui_update(dt)

    if blink.active == false then
            gdsGui_button_setState( "acknowlegeAlarm", "deactivated" )
    end

    -- Skip if timer not running
    if timer.running then
        if timer.mode == "COUNT UP" then
                timer.t = timer.t + dt
        else -- COUNT DOWN
            timer.t = math.max(0, timer.t - dt)

            if timer.t <= 3 and timer.t > 0 and not blink.navSent
               and globApp.currentPageIndex ~= 2
               and gdsGui_page_currentName() ~= "MainMenu" then
                blink.navSent          = true
                blink.navigatingToMain = true
                _navSyncAll("MainMenu")
                gdsGui_page_switch("LoadingMainMenu", 3, 3, false)
            end

            if timer.t == 0 then
                timer.running = false
                blink.active  = true
                gdsGui_button_setState("acknowlegeAlarm", "released")
                alarmButtonsDeactivation()
                if gdsGui_page_currentName() ~= "MainMenu" and globApp.currentPageIndex ~= 2 then
                    blink.navigatingToMain = true
                    _navSyncAll("MainMenu")
                    gdsGui_page_switch("LoadingMainMenu", 3, 3, false)
                end
                for _, btn in ipairs(globApp.objects.buttons) do
                    if btn.name == "pauseRHTopTimer" and btn.state == globApp.BUTTON_STATES.PRESSED then
                        btn.state = globApp.BUTTON_STATES.RELEASED
                    end
                end
        end
        end
    end

    -- Handle blinking overlay with vibration and beep
    if blink.active then
        if gdsGui_page_currentName() == "MainMenu" then
            blink.navigatingToMain = false
            blink.timer = blink.timer + dt
            if blink.timer > 0.5 then
                blink.timer = 0
                blink.state = not blink.state
                if blink.state then
                    if love.system.vibrate and appSettings.hapticsEnabled then
                        love.system.vibrate(0.1)
                    end
                    if beepSound and appSettings.soundEnabled then
                        love.audio.play(beepSound)
                    end
                end
            end
        elseif not blink.navigatingToMain then
            -- User navigated away from MainMenu while alarm was active — dismiss it
            acknowlegeAlarm()
        end
        -- if navigatingToMain is true and page is still loading, wait for arrival
    end

    --handles play button state during countdown based on timer
    if timer.t <= 0 then 
        for _, btn in ipairs(globApp.objects.buttons) do
            if btn.name == "modeSelectRHTopTimer" and btn.state == globApp.BUTTON_STATES.PRESSED then
                gdsGui_button_setState ( "pauseRHTopTimer", "deactivated")
            end
        end
    end
end

function love.draw()
    drawPages()
    gdsGui_draw()
    drawSchematicZoomFullScreenLabel()
    drawAlarmOverlay()
    gdsGui_page_drawUnsafeAreaOverlay()
    gdsGui_container_drawFixed(gdsGui_page_currentName())
    -- Drawn last so the schematic's modal menu (catalog/control/color-picker/
    -- conflict-confirm) renders above the floating chrome buttons.
    gdsGui_schematic_drawMenuOverlay(gdsGui_page_currentName())
    -- Same reasoning as the modal menu above, but paint mode's vertical
    -- palette isn't modal — canvas items underneath stay tappable while it's
    -- showing (see gdsGui_schematic_armPaintMode).
    gdsGui_schematic_drawPaintOverlay(gdsGui_page_currentName())
    -- Same reasoning as PAINT's palette above — a non-modal slide-out panel,
    -- not a dimmed modal like the menu overlay.
    gdsGui_schematic_drawAnnunciatorPanelOverlay(gdsGui_page_currentName())
    gdsGui_schematicGallery_drawMenuOverlay(gdsGui_page_currentName())
    -- The text-entry prompt and the option-list menu are each a single global
    -- modal (not page-scoped), drawn above everything else when open. Only
    -- one of the two is ever open at a time.
    gdsGui_textPrompt_draw()
    gdsGui_choiceMenu_draw()
end

-- Design-mode edits (dragging/adding/deleting elements, wires, controls) only
-- get written into schematicStore/disk via _saveCurrentSystem(), which until
-- now only ran on explicit navigation away from the SystemSchematic page
-- (footer nav, back buttons, snapshot capture). Quitting or backgrounding the
-- app while still on that page skipped all of those call sites, so whatever
-- was drawn since the last navigation was silently lost. love.quit() covers
-- an explicit close; love.focus(false) also covers iOS/Android backgrounding,
-- where the OS can later kill the suspended app without ever calling love.quit.
-- Full-screen view (SchematicFullScreen, toggled via
-- schematicFullScreenTogglePressed) shows/edits the same live mainCanvas as
-- SystemSchematic, just reassigned to its own page — so it needs the same
-- save-on-quit/background coverage.
local function _isOnSchematicPage()
    local name = gdsGui_page_currentName()
    return name == "SystemSchematic" or name == "SchematicFullScreen"
end

-- Called from both love.quit() and love.focus(false) below — same "the app
-- is about to stop running right now" moment either covers. Persists
-- schematicResumeActive alongside the content save so a later cold boot
-- (see love.load()'s own resume check) knows whether to land straight back
-- on the schematic page or fall through to the normal MainMenu start.
-- schematicStore.currentAircraftId/currentSystemId and appSettings.
-- schematicEditMode already track WHICH system/mode to reopen — this is only
-- the "were they actually looking at it when they left" bit on top of that.
local function _saveSchematicResumeState()
    local onSchematic = _isOnSchematicPage()
    if onSchematic then _saveCurrentSystem() end
    if appSettings.schematicResumeActive ~= onSchematic then
        appSettings.schematicResumeActive = onSchematic
        _saveAppSettings()
    end
end

function love.quit()
    _saveSchematicResumeState()
end

function love.focus(focused)
    if not focused then _saveSchematicResumeState() end
end

-- Drawn directly (not as an outputTxtBox widget) and called after gdsGui_draw()
-- in love.draw() above: gdsGui_draw()'s own outputTxtBox pass runs BEFORE its
-- schematic-canvas pass (see gdsGui_general_draw's fixed draw order), so a
-- widget would be painted over by the full-screen canvas. Drawing it here,
-- afterward, guarantees it's always on top.
function drawSchematicZoomFullScreenLabel()
    if gdsGui_page_currentName() ~= "SchematicFullScreen" then return end
    if not _prevSchematicZoomText then return end
    local sa = globApp.safeScreenArea
    local w, h = 70, 20
    local pos = gdsGui_general_relativePosition("RB", 0.98, 0.98, w, h, sa.x, sa.y, sa.w, sa.h)
    if not _schematicZoomFullScreenFont then
        _schematicZoomFullScreenFont = love.graphics.newFont(10)
    end
    love.graphics.setFont(_schematicZoomFullScreenFont)
    love.graphics.setColor(1, 1, 1, 0.3)
    love.graphics.printf(_prevSchematicZoomText, pos[1], pos[2], w, "right")
end

-------------------------------------------------------------------------------
-- PAGE DRAWING
-------------------------------------------------------------------------------
function drawPages()
    gdsGui_page_drawBackground()
    -- The embedded schematic canvas is narrower than the safe area (see
    -- love.load()'s schCanvasWFrac), so its left/right margins would
    -- otherwise show the general app background instead of reading as part
    -- of the canvas. Paint just those two side strips (130,130,130 — a
    -- lighter gray than the canvas's own fill, chosen to stand apart from it
    -- rather than blend in) rather than the whole page, so nothing else on
    -- this page's backdrop changes.
    if gdsGui_page_currentName() == "SystemSchematic" then
        local canvas = _findSchematicCanvas()
        if canvas then
            local sa = globApp.safeScreenArea
            love.graphics.setColor(130 / 255, 130 / 255, 130 / 255, 1)
            love.graphics.rectangle("fill", sa.x, canvas.y, canvas.x - sa.x, canvas.h)
            love.graphics.rectangle("fill", canvas.x + canvas.w, canvas.y, (sa.x + sa.w) - (canvas.x + canvas.w), canvas.h)
        end
    end
end

function drawAlarmOverlay()
    if not blink.active then return end
    for _, cont in ipairs(globApp.objects.containers) do
        if cont.name == "timerPanel" then
            local hr = cont.headerRect

            -- Flash only the header strip
            if blink.state then
                love.graphics.setColor(1, 0, 0, 0.65)
                love.graphics.rectangle("fill", hr.x, hr.y, hr.width, hr.height)
            end

            -- Draw ack button image centered within the button's actual bounds
            for _, btn in ipairs(globApp.objects.buttons) do
                if btn.name == "acknowlegeAlarm" then
                    if btn.state ~= globApp.BUTTON_STATES.DEACTIVATED then
                        local img = (btn.state == globApp.BUTTON_STATES.PRESSED)
                                    and _ackPushedImg or _ackReleasedImg
                        local iw, ih = img:getDimensions()
                        love.graphics.setColor(1, 1, 1, 1)
                        love.graphics.draw(img, btn.myx, btn.myy,
                            0, btn.mywidth / iw, btn.myheight / ih)
                    end
                    break
                end
            end

            love.graphics.setColor(1, 1, 1, 1)
            return
        end
    end
end

-------------------------------------------------------------------------------
-- TIMER CONTROL FUNCTIONS
-------------------------------------------------------------------------------

function acknowlegeAlarm()
    if blink.active then
        blink.active          = false
        blink.state           = false
        blink.navigatingToMain = false
        if beepSound then
            love.audio.stop(beepSound)
        end
    end
    alarmAcklgBtnsActiation()
end


function alarmButtonsDeactivation ()

    gdsGui_button_setState( "modeSelectRHTopTimer", "deactivated" )
    gdsGui_button_setState( "incrsMinRHTopTimer", "deactivated" )
    gdsGui_button_setState( "dcrsMinRHTopTimer", "deactivated" )
    gdsGui_button_setState( "incrsSecRHTopTimer", "deactivated" )
    gdsGui_button_setState( "dcrsSecRHTopTimer", "deactivated" )
    gdsGui_button_setState( "pauseRHTopTimer", "deactivated" )
    gdsGui_button_setState( "resetRHTopTimer", "deactivated" )

end

function alarmAcklgBtnsActiation ()

    gdsGui_button_setState( "modeSelectRHTopTimer", "pushed" )
    gdsGui_button_setState( "incrsMinRHTopTimer", "released" )
    gdsGui_button_setState( "dcrsMinRHTopTimer", "released" )
    gdsGui_button_setState( "incrsSecRHTopTimer", "released" )
    gdsGui_button_setState( "dcrsSecRHTopTimer", "released" )
    gdsGui_button_setState( "pauseRHTopTimer", "released" )
    gdsGui_button_setState( "resetRHTopTimer", "released" )

end


function resetRHTopTimer()
    timer.running = false
    if timer.mode == "COUNT DOWN" then
        timer.t = lastSavedCountDownTime
        gdsGui_button_setState ("pauseRHTopTimer", "released")
    else
        timer.t = 0
    end
    blink.active          = false
    blink.navSent         = false
    blink.navigatingToMain = false
    for _, btn in ipairs(globApp.objects.buttons) do
        if btn.name == "pauseRHTopTimer" and btn.state == globApp.BUTTON_STATES.PRESSED then
            btn.state = globApp.BUTTON_STATES.RELEASED
        end
    end
end

function pauseRHTopTimer()
    timer.running = not timer.running
    if timer.running then blink.navSent = false end
end

function incrsMinRHTopTimer()
    timer.t = timer.t + 60
    saveCountdownTime()
    acknowlegeAlarm()
end

function dcrsMinRHTopTimer()
    timer.t = math.max(0, timer.t - 60)
    saveCountdownTime()
end

function incrsSecRHTopTimer()
    timer.t = timer.t + 1
    saveCountdownTime()
    acknowlegeAlarm()
end

function dcrsSecRHTopTimer()
    timer.t = math.max(0, timer.t - 1)
    saveCountdownTime()
end

function modeSelectRHTopTimer()
    timer.mode = (timer.mode == "COUNT UP") and "COUNT DOWN" or "COUNT UP"
    
    if timer.mode == "COUNT DOWN" then
        gdsGui_button_setState( "incrsMinRHTopTimer", "released" )
        gdsGui_button_setState( "dcrsMinRHTopTimer", "released" )
        gdsGui_button_setState( "incrsSecRHTopTimer", "released" )
        gdsGui_button_setState( "dcrsSecRHTopTimer", "released" )
        timer.t = lastSavedCountDownTime
    else
        timer.t = 0
        gdsGui_button_setState( "incrsMinRHTopTimer", "deactivated" )
        gdsGui_button_setState( "dcrsMinRHTopTimer", "deactivated" )
        gdsGui_button_setState( "incrsSecRHTopTimer", "deactivated" )
        gdsGui_button_setState( "dcrsSecRHTopTimer", "deactivated" )
        gdsGui_button_setState( "pauseRHTopTimer", "released")
    end

    -- for _, btn in ipairs(lib_buttons) do
    --     if btn.name == "pauseRHTopTimer" and btn.state == globApp.BUTTON_STATES.PRESSED then
    --         btn.state = 1
    --     end
    -- end

    timer.running = false
end

function saveCountdownTime()
    lastSavedCountDownTime = math.max(0, timer.t)
end

function roundSelectedAltitude (pos)
    selectedAltitude = math.max(0, math.floor(51 * (1 - pos) + 0.5)) * 1000
    return selectedAltitude
end


function roundSelectedTime (pos)
    selectedTime = math.max(0, math.floor(25 * (1 - pos) + 0.5))
    return selectedTime
end

function roundSelectedDegree (pos)
    selectedDegree = math.floor(32 * (1 - pos) + 0.5) * 0.25
    return selectedDegree
end

function calcWindComponents(windDir, windSpd, rwyHeading, devMode)
    local relAngle = math.rad(windDir - rwyHeading)
    local sinA = math.sin(relAngle)
    local cosA = math.cos(relAngle)
    local xw    = math.abs(math.floor(windSpd * sinA + 0.5))
    local ht    = math.floor(windSpd * cosA + 0.5)
    local side  = (sinA >= 0) and "R" or "L"
    local label = (ht >= 0) and "HW" or "TW"
    if devMode then return {xw, side, math.abs(ht), label} end
    return xw, side, math.abs(ht), label
end

function windSpeedChanged(pos)
    selectedWindSpeed = math.floor(45 * (1 - pos) + 0.5)
    return selectedWindSpeed
end

function windGustChanged(pos)
    local range = 60 - selectedWindSpeed
    selectedWindGust = selectedWindSpeed + math.floor(range * (1 - pos) + 0.5)
    return selectedWindGust
end

-- Inner knob callback: runway selector.
-- Detent 0 (12 o'clock) = RWY 36; detents 1-35 = RWY 01-35 clockwise.
function mainKnobChanged(pos)
    local index     = math.floor(pos * 36 + 0.5) % 36
    selectedKnobPos = (index == 0) and 36 or index
    return selectedKnobPos
end

-- Outer knob callback: wind direction.
-- Same detent layout as runway but values are runway × 10 (10°–360°).
-- Detent 0 (12 o'clock) = 360°; detents 1-35 = 10°, 20°, …, 350°.
function windKnobChanged(pos)
    local index           = math.floor(pos * 36 + 0.5) % 36
    local runway          = (index == 0) and 36 or index
    selectedWindDirection = runway * 10
    return selectedWindDirection
end

function dutyHoursChanged(pos)
    dutyMaxHours = 1 + math.floor(19 * pos + 0.5)
    return dutyMaxHours
end

function dutyStartChanged(pos)
    dutyStartMins = math.floor(287 * pos + 0.5) * 5   -- 00:00 (left) … 23:55 (right)
    return dutyStartMins
end

function lastFlightChanged(pos)
    lastFlightHours = math.floor(180 * pos + 0.5) * 0.1   -- 0.0 (left) … 18.0 (right)
    return lastFlightHours
end

-------------------------------------------------------------------------------
-- SETTINGS CALLBACKS
-------------------------------------------------------------------------------

function darkModeToggled(newState)
    appSettings.darkMode = (newState == globApp.BUTTON_STATES.PRESSED)
    _applyTheme(appSettings.darkMode)
    _saveAppSettings()
end

function soundToggled(newState)
    appSettings.soundEnabled = (newState == globApp.BUTTON_STATES.PRESSED)
    if appSettings.soundEnabled and singleChimeSound then
        love.audio.play(singleChimeSound)
    end
    _saveAppSettings()
end

function hapticsToggled(newState)
    appSettings.hapticsEnabled = (newState == globApp.BUTTON_STATES.PRESSED)
    if appSettings.hapticsEnabled and love.system.vibrate then
        love.system.vibrate(0.1)
    end
    _saveAppSettings()
end

function fontSizeChanged(pos)
    local fontSize = 12 + math.floor(4 * pos + 0.5)
    appSettings.fontSize = fontSize
    _applyFontSize(fontSize)
    _saveAppSettings()
    return fontSize
end

-------------------------------------------------------------------------------
-- SCHEMATIC PAYWALL PAGE (premium-feature gate)
-------------------------------------------------------------------------------

function createSchematicPaywallObjects()
    local thisPageName = "SchematicPaywall"
    local pageHdrH  = math.floor(globApp.safeScreenArea.h * 0.10)
    local pageFootH = pageHdrH
    local hdrCX     = math.floor(globApp.safeScreenArea.w * 0.5)
    local hdrCY     = math.floor(pageHdrH * 0.5)
    local footBtnW  = 120
    local footBtnH  = 48
    local footBtnY  = math.floor(pageFootH * 0.50)
    local btnX1     = math.floor(globApp.safeScreenArea.w * (1/3))
    local btnX2     = math.floor(globApp.safeScreenArea.w * (2/3))

    gdsGui_pageHeader_create("paywall_header", thisPageName, pageHdrH, {0.15, 0.15, 0.20, 1})
    gdsGui_outputTxtBox_create("paywall_pageTitle", thisPageName, nil,
        hdrCX, hdrCY, "CC",
        math.floor(globApp.safeScreenArea.w * 0.90), math.floor(pageHdrH * 0.5),
        {1, 1, 1, 1}, "PREMIUM FEATURE", 16, "paywall_header"
    )

    gdsGui_container_create("paywallPanel", thisPageName, "", 0, 0)
    gdsGui_outputTxtBox_create("paywallBodyText", thisPageName, nil,
        hdrCX, 20, "CT",
        math.floor(globApp.safeScreenArea.w * 0.85), 160,
        {1, 1, 1, 1},
        "SYSTEM SCHEMATIC is a premium feature.\n\nThis build lets you simulate the purchase to unlock it for testing — no real payment is processed.",
        14, "paywallPanel"
    )

    gdsGui_pageFooter_create("paywall_footer", thisPageName, pageFootH, {0.15, 0.15, 0.20, 1})
    gdsGui_button_create("paywallSimulatePurchase", thisPageName, "pushonoff",
        "Sprites/button_continue_pressed.png", "Sprites/button_continue_released.png",
        "Sprites/button_continue_deactivated.png",
        btnX1, footBtnY, "CC", footBtnW, footBtnH,
        "simulatePurchaseSchematic", globApp.BUTTON_STATES.RELEASED, true, "paywall_footer"
    )
    gdsGui_button_create("paywallCancel", thisPageName, "pushonoff",
        "Sprites/button_reset_pressed.png", "Sprites/button_reset_released.png",
        "Sprites/button_reset_deactivated.png",
        btnX2, footBtnY, "CC", footBtnW, footBtnH,
        "cancelSchematicPaywall", globApp.BUTTON_STATES.RELEASED, false, "paywall_footer"
    )
end

-------------------------------------------------------------------------------
-- TERMS AND CONDITIONS PAGE
-------------------------------------------------------------------------------

function createTermsAndConditionsObjects()
    local thisPageName = "TermsAndConditions"
    local tcText     = love.filesystem.read("terms.txt") or "Terms and Conditions text not found."
    tcText = tcText:gsub("{{APP_VERSION}}", APP_VERSION)
    local libSprites = "Libraries/gds_love2d_gui/librarySprites/"

    local pageHdrH = math.floor(globApp.safeScreenArea.h * 0.10)
    local pageFootH = pageHdrH
    local hdrCX    = math.floor(globApp.safeScreenArea.w * 0.5)
    local hdrCY    = math.floor(pageHdrH * 0.5)
    local bodyH    = globApp.safeScreenArea.h - pageHdrH - pageFootH
    -- tcTxtH fills the body: contentH = topGap(5) + tcTxtH + PADDING(8) = bodyH
    local tcTxtH   = bodyH - 13
    local tcTxtW   = math.floor(globApp.safeScreenArea.w * 0.90)
    local tcTxtX   = math.floor(globApp.safeScreenArea.w * 0.5)
    local footBtnW = 96
    local footBtnH = 48
    local footBtnY = math.floor(pageFootH * 0.50)
    local tcBtnX1  = math.floor(globApp.safeScreenArea.w * (1/3))
    local tcBtnX2  = math.floor(globApp.safeScreenArea.w * (2/3))

    -- Header
    gdsGui_pageHeader_create("tc_header", thisPageName, pageHdrH, {0.15, 0.15, 0.20, 1})
    gdsGui_outputTxtBox_create("tc_pageTitle", thisPageName, nil,
        hdrCX, hdrCY, "CC",
        math.floor(globApp.safeScreenArea.w * 0.90), math.floor(pageHdrH * 0.5),
        {1, 1, 1, 1}, "TERMS AND CONDITIONS", 16, "tc_header"
    )

    -- Body container housing the scrollable T&C text
    gdsGui_container_create("tcPanel", thisPageName, "", 0, 0)
    gdsGui_outputTxtBox_create("tcText", thisPageName, nil,
        tcTxtX, 5, "CT",
        tcTxtW, tcTxtH,
        {1, 1, 1, 1}, tcText,
        math.floor(gdsGui_general_smartFontScaling(0.04, 0.055)),
        "tcPanel"
    )

    -- Footer: agree toggle (locked until scroll-to-bottom) + continue button
    gdsGui_pageFooter_create("tc_footer", thisPageName, pageFootH, {0.15, 0.15, 0.20, 1})
    gdsGui_button_create("tcAgreementToggle", thisPageName,
        "toggle",
        "Sprites/button_iagree_pressed.png",
        "Sprites/button_iagree_released.png",
        "Sprites/button_iagree_deactivated.png",
        tcBtnX1, footBtnY, "CC", footBtnW, footBtnH,
        "tcAgreementToggled", globApp.BUTTON_STATES.DEACTIVATED, false, "tc_footer"
    )
    gdsGui_button_create("tcContinueButton", thisPageName,
        "pushonoff",
        ("Sprites/button_continue_pressed.png"),
        ("Sprites/button_continue_released.png"),
        ("Sprites/button_continue_deactivated.png"),
        tcBtnX2, footBtnY, "CC", footBtnW, footBtnH,
        "tcContinuePressed", globApp.BUTTON_STATES.DEACTIVATED, false, "tc_footer"
    )
end

function tcAgreementToggled(newState)
    if newState == globApp.BUTTON_STATES.PRESSED then
        gdsGui_button_setState("tcContinueButton", "released")
    else
        gdsGui_button_setState("tcContinueButton", "deactivated")
    end
end

function tcContinuePressed()
    appSettings.tcAcceptedVersion = APP_VERSION
    love.filesystem.write("appSettings.lua", table.show(appSettings, "appSettings"))
    _navSyncAll("MainMenu")
    gdsGui_page_switch("LoadingMainMenu", 3, 3, false)
end

-------------------------------------------------------------------------------
-- FOOTER NAVIGATION CALLBACKS
-------------------------------------------------------------------------------

function navGoToMainMenu()
    if gdsGui_page_currentName() == "SystemSchematic" then _saveCurrentSystemIfDirty() end
    _navSyncAll("MainMenu")
    gdsGui_page_switch("LoadingMainMenu", 3, 3, false)
end

-- Always lands on the top aircraft-picker (SchematicHome), deliberately
-- never straight back into whatever was last open on the canvas — this is
-- "step back up one level", used by the back buttons on AircraftGallery/
-- SchematicManageGallery (which are already one level below Home) and by
-- navGoToSystemSchematic below as its own no-aircraft-yet fallback.
function navBackToSchematicHome()
    if gdsGui_page_currentName() == "SystemSchematic" then _saveCurrentSystemIfDirty() end
    if not appSettings.schematicUnlocked then
        gdsGui_page_switch("LoadingPaywall", 8, 2, false)
        return
    end
    _refreshSchematicHomeAvailability()
    _navSyncAll("SchematicHome")
    gdsGui_page_switch("LoadingSchematicHome", 9, 2, false)
end

-- Footer dock icon's callback — the one global shortcut into the schematic
-- flow from anywhere else in the app (Learn, Settings, MainMenu, ...). If a
-- system is already open (schematicStore.currentSystemId, set the moment any
-- system is opened and left alone by simply navigating elsewhere — see
-- _openSystemIntoCanvas), jumps straight back into the live canvas exactly
-- as it was left (mainCanvas itself is never torn down by navigating away,
-- so its content/mode/zoom/pan/selection are all still sitting there
-- untouched) instead of dropping back to the aircraft picker every time.
-- Only a first-ever visit this session (nothing open yet) or a deleted/
-- missing current system falls through to navBackToSchematicHome.
function navGoToSystemSchematic()
    if gdsGui_page_currentName() == "SystemSchematic" then _saveCurrentSystemIfDirty() end
    if not appSettings.schematicUnlocked then
        gdsGui_page_switch("LoadingPaywall", 8, 2, false)
        return
    end
    if schematicStore.currentSystemId and _findSystem(schematicStore.currentSystemId) then
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
        return
    end
    navBackToSchematicHome()
end

-- Steps back one level (not all the way to the top aircraft picker) from the
-- canvas to the current aircraft's systems gallery, keeping the user's
-- aircraft context instead of dropping them back to MY AIRCRAFT every time.
function navBackToAircraftSystems()
    if gdsGui_page_currentName() == "SystemSchematic" then _saveCurrentSystemIfDirty() end
    navGoToAircraftSystems()
end

function navGoToLearn()
    if gdsGui_page_currentName() == "SystemSchematic" then _saveCurrentSystemIfDirty() end
    _navSyncAll("Learn")
    gdsGui_page_switch("LoadingLearn", 5, 3, false)
end

function navGoToSettings()
    if gdsGui_page_currentName() == "SystemSchematic" then _saveCurrentSystemIfDirty() end
    _navSyncAll("Settings")
    gdsGui_page_switch("LoadingSettings", 6, 3, false)
end

-------------------------------------------------------------------------------
-- SCHEMATIC PAYWALL CALLBACKS
-------------------------------------------------------------------------------

-- Sets the placeholder entitlement flag. Separated from simulatePurchaseSchematic()
-- (which also navigates) so the flag-setting logic itself is directly unit-testable.
function unlockSchematicFeature()
    appSettings.schematicUnlocked = true
    _syncPaidLoadingScreenSkip()
    _saveAppSettings()
    return appSettings.schematicUnlocked
end

-- Exercises unlockSchematicFeature() without permanently flipping the real
-- paywall entitlement on this install: unlockSchematicFeature() itself
-- persists appSettings.schematicUnlocked to disk, so a bare call from a
-- unit test (which can run any time developer mode's dev panel re-runs the
-- suite) would silently and permanently unlock the paid feature. This
-- restores whatever the flag was before the test ran, then re-persists
-- that original value.
function unlockSchematicFeatureTest()
    local prior = appSettings.schematicUnlocked
    local result = unlockSchematicFeature()
    appSettings.schematicUnlocked = prior
    _syncPaidLoadingScreenSkip()
    _saveAppSettings()
    return result
end

function simulatePurchaseSchematic()
    unlockSchematicFeature()
    _refreshSchematicHomeAvailability()
    _navSyncAll("SchematicHome")
    gdsGui_page_switch("LoadingSchematicHome", 9, 2, false)
end

function cancelSchematicPaywall()
    gdsGui_page_switch("LoadingMainMenu", 3, 3, false)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC PAGE CALLBACKS
-------------------------------------------------------------------------------

function schematicModeToggled(newState)
    local designing = (newState == globApp.BUTTON_STATES.PRESSED)
    appSettings.schematicEditMode = designing
    gdsGui_schematic_setMode("mainCanvas", designing and "design" or "control")
    gdsGui_button_setState("schematicContextButton", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicContextButton", not designing)
    gdsGui_button_setState("schematicSnapshotBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicSnapshotBtn", not designing)
    gdsGui_button_setState("schematicAddBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicAddBtn", not designing)
    gdsGui_button_setState("schematicPaintBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicPaintBtn", not designing)
    gdsGui_button_setState("schematicAnnunciatorBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicAnnunciatorBtn", not designing)
    gdsGui_button_setState("schematicFullScreenToggle", designing and "deactivated" or "released")
    _saveAppSettings()
end

-- Control-mode "full screen": re-homes the live mainCanvas object onto its
-- own dock-free page, rather than duplicating canvas data onto a second
-- object — same canvas, same elements/wires/controls, just reassigned page +
-- geometry until the user returns. Covers the full-screen page's entire
-- safe area with no margin: the embedded view's box already has the same
-- aspect ratio as the full screen (schCanvasWFrac == schCanvasHFrac in
-- love.load(), so canvas.w/canvas.h == safeW/safeH there too), so expanding
-- it to 100%/100% here is a uniform scale-up with no stretch, not a shape
-- change.
function schematicFullScreenTogglePressed()
    if _schematicFullScreen then return end
    local canvas = _findSchematicCanvas()
    if not canvas or not _schematicCanvasNormalLayout then return end
    _schematicFullScreen = true
    canvas.page = "SchematicFullScreen"

    canvas.original = { x = 0, y = 0, anchorPoint = "LT", wFrac = 1, hFrac = 1 }
    -- Already at its maximum here, so there's nothing further for zooming
    -- in to expand into — without this, zooming in while full-screen would
    -- wrongly fall back to the embedded page's (now stale) zoomed layout.
    gdsGui_schematic_clearZoomedLayout("mainCanvas")
    canvas:resize()
    -- Full screen is its own view, independent of whatever zoom the
    -- embedded page was left at — always open it fully zoomed out.
    gdsGui_schematic_resetView("mainCanvas", 1)
    globApp.currentPageIndex = 10
end

function schematicFullScreenReturnPressed()
    if not _schematicFullScreen then return end
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    _schematicFullScreen = false
    canvas.page = "SystemSchematic"
    if _schematicCanvasNormalLayout then canvas.original = _schematicCanvasNormalLayout end
    if _schematicCanvasZoomedLayout then
        gdsGui_schematic_setZoomedLayout("mainCanvas",
            _schematicCanvasZoomedLayout.x, _schematicCanvasZoomedLayout.y, _schematicCanvasZoomedLayout.anchorPoint,
            _schematicCanvasZoomedLayout.wFrac, _schematicCanvasZoomedLayout.hFrac)
    end
    canvas:resize()
    globApp.currentPageIndex = 7
end

-- Captures the current control-position combination's element/wire colors as
-- a snapshot rule. If a snapshot already exists for this exact combination
-- with DIFFERENT colors, that's a contradiction: prompt before overwriting.
function captureSchematicSnapshot()
    -- Same guard as schematicContextButtonPressed above: don't clobber an
    -- in-progress ADD ELEMENT/CONTROL cascade (or any other open canvas
    -- menu) by opening the conflict-confirm menu out from under it.
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    local plan = gdsGui_schematic_prepareSnapshot("mainCanvas")
    if plan.hasConflict then
        _pendingSnapshotPlan = plan
        gdsGui_schematic_openMenu("mainCanvas", "CONFLICTS WITH EXISTING SNAPSHOT",
            {"OVERWRITE", "CANCEL"}, "schematicSnapshotConflictResolved", "schematicSnapshotConflictResolved", true)
    else
        gdsGui_schematic_commitSnapshot("mainCanvas", plan)
        gdsGui_outputTxtBox_setText("schematicSnapshotLabel", "SNAPSHOTS: " .. gdsGui_schematic_countSnapshots("mainCanvas"))
        _requestSchematicSave()
        if appSettings.hapticsEnabled and love.system.vibrate then love.system.vibrate(0.1) end
        if appSettings.soundEnabled and singleChimeSound then love.audio.play(singleChimeSound) end
    end
end

-- Shared onSelect/onCancel for the conflict-confirm menu: cancel (tap outside,
-- or the CANCEL row) calls this with no selected option, which falls through
-- without committing.
function schematicSnapshotConflictResolved(canvasName, index, optionText)
    if optionText == "OVERWRITE" and _pendingSnapshotPlan then
        gdsGui_schematic_commitSnapshot(canvasName, _pendingSnapshotPlan)
        gdsGui_outputTxtBox_setText("schematicSnapshotLabel", "SNAPSHOTS: " .. gdsGui_schematic_countSnapshots(canvasName))
        _requestSchematicSave()
    end
    _pendingSnapshotPlan = nil
end

-- COMBINATION PREV/NEXT — steps to the next/previous control-position
-- combination (gdsGui_schematic_stepCombination), which also resets every
-- element/wire/control to the selectable gray color. Same "don't clobber an
-- in-progress canvas menu" guard as captureSchematicSnapshot above; the
-- buttons themselves are only active in design mode with 2+ combinations to
-- begin with (see the per-frame poll in love.update() below), but a guard
-- here too costs nothing and covers a press already in flight when a menu
-- opens.
function schematicCombPrevPressed()
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    gdsGui_schematic_pushUndo("mainCanvas")
    gdsGui_schematic_stepCombination("mainCanvas", -1)
    _requestSchematicSave()
end

function schematicCombNextPressed()
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    gdsGui_schematic_pushUndo("mainCanvas")
    gdsGui_schematic_stepCombination("mainCanvas", 1)
    _requestSchematicSave()
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC TEST HELPERS
-- Each builds its own throwaway canvas so these are independent of the real
-- "mainCanvas" built in love.load(). Return values are kept to primitives
-- (numbers/strings/booleans) to match this app's existing test-harness
-- convention of comparing flattened values, not tables, by equality.
-------------------------------------------------------------------------------

function schematicCascadeDeleteTest()
    gdsGui_schematic_delete("unitTestCanvas")
    gdsGui_schematic_create("unitTestCanvas", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas", "e1", "rect", 0, 0, 0.1, 0.1, "A", {1, 1, 1, 1})
    gdsGui_schematic_addElement("unitTestCanvas", "e2", "rect", 0.5, 0.5, 0.1, 0.1, "B", {1, 1, 1, 1})
    gdsGui_schematic_addWire("unitTestCanvas", "w1", "e1", "e2", {1, 1, 1, 1})
    gdsGui_schematic_removeElement("unitTestCanvas", "e1")
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas" then return #c.wires end
    end
    return -1
end

-- A wire's resolved color comes from its OWN snapshot entry, independent of
-- the colors of the elements it connects.
function schematicResolveColorIndependenceTest()
    gdsGui_schematic_delete("unitTestCanvas2")
    gdsGui_schematic_create("unitTestCanvas2", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas2", "eA", "rect", 0, 0, 0.1, 0.1, "A", {1, 0, 0, 1})
    gdsGui_schematic_addElement("unitTestCanvas2", "eB", "rect", 0.5, 0.5, 0.1, 0.1, "B", {0, 0, 1, 1})
    gdsGui_schematic_addWire("unitTestCanvas2", "wAB", "eA", "eB", {0, 0, 0, 1})
    gdsGui_schematic_commitSnapshot("unitTestCanvas2", { signature = "", elements = {}, wires = { wAB = {0, 1, 0, 1} } })
    local _, g = gdsGui_schematic_resolveColor("unitTestCanvas2", "wire", "wAB")
    return g
end

function schematicPrepareSnapshotShapeTest()
    gdsGui_schematic_delete("unitTestCanvas3")
    gdsGui_schematic_create("unitTestCanvas3", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas3", "e1", "rect", 0, 0, 0.1, 0.1, "A", {0.2, 0.3, 0.4, 1})
    local plan = gdsGui_schematic_prepareSnapshot("unitTestCanvas3")
    local c = plan.elements["e1"]
    if plan.signature == "" and c and c[1] == 0.2 and c[2] == 0.3 and c[3] == 0.4 and c[4] == 1
       and plan.wires["e1"] == nil and plan.hasConflict == false then
        return "pass"
    end
    return "fail"
end

-- Re-capturing the exact same control combination's snapshot with a
-- different resolved color must surface as a conflict (plan.hasConflict),
-- so the app prompts to OVERWRITE/CANCEL instead of silently clobbering
-- what was previously recorded (see captureSchematicSnapshot).
function schematicPrepareSnapshotConflictTest()
    gdsGui_schematic_delete("unitTestCanvas8")
    gdsGui_schematic_create("unitTestCanvas8", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas8", "e1", "rect", 0, 0, 0.1, 0.1, "A", {1, 0, 0, 1})
    gdsGui_schematic_commitSnapshot("unitTestCanvas8", { signature = "", elements = { e1 = {1, 0, 0, 1} }, wires = {} })
    gdsGui_schematic_setPendingColor("unitTestCanvas8", "element", "e1", {0, 0, 1, 1})
    local plan = gdsGui_schematic_prepareSnapshot("unitTestCanvas8")
    if plan.hasConflict then return "pass" end
    return "fail"
end

-- Adding a new control after a snapshot was captured changes the live
-- signature (the new control joins it), orphaning the old snapshot key —
-- re-capturing under the same conditions for the controls that already
-- existed must replace that orphan rather than leave it behind alongside a
-- disconnected new entry (see _matchingSnapshotKeys in schematic_gdsGuiLib.lua).
function schematicSnapshotMigratesOnControlAddedTest()
    gdsGui_schematic_delete("unitTestCanvas9")
    gdsGui_schematic_create("unitTestCanvas9", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas9", "e1", "rect", 0, 0, 0.1, 0.1, "A", {0.55, 0.55, 0.55, 1})
    gdsGui_schematic_addControl("unitTestCanvas9", "c1", 0, 0, {"OFF", "ON"}, 0, "C1", nil)
    gdsGui_schematic_commitSnapshot("unitTestCanvas9", { signature = "c1=0", elements = { e1 = {1, 0, 0, 1} }, wires = {} })
    gdsGui_schematic_addControl("unitTestCanvas9", "c2", 0, 0, {"OFF", "ON"}, 0, "C2", nil)
    local plan = gdsGui_schematic_prepareSnapshot("unitTestCanvas9")
    gdsGui_schematic_commitSnapshot("unitTestCanvas9", plan)
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas9" then
            if c.snapshots["c1=0"] == nil and c.snapshots["c1=0,c2=0"] ~= nil then return "pass" end
            return "fail"
        end
    end
    return "fail"
end

-- Same migration, the other direction: removing a control shrinks the
-- signature, so the old (now-unreachable) wider-signature snapshot must be
-- replaced by the new capture under the narrower one.
function schematicSnapshotMigratesOnControlRemovedTest()
    gdsGui_schematic_delete("unitTestCanvas10")
    gdsGui_schematic_create("unitTestCanvas10", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas10", "e1", "rect", 0, 0, 0.1, 0.1, "A", {0.55, 0.55, 0.55, 1})
    gdsGui_schematic_addControl("unitTestCanvas10", "c1", 0, 0, {"OFF", "ON"}, 0, "C1", nil)
    gdsGui_schematic_addControl("unitTestCanvas10", "c2", 0, 0, {"OFF", "ON"}, 0, "C2", nil)
    gdsGui_schematic_commitSnapshot("unitTestCanvas10", { signature = "c1=0,c2=0", elements = { e1 = {1, 0, 0, 1} }, wires = {} })
    gdsGui_schematic_removeControl("unitTestCanvas10", "c2")
    local plan = gdsGui_schematic_prepareSnapshot("unitTestCanvas10")
    gdsGui_schematic_commitSnapshot("unitTestCanvas10", plan)
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas10" then
            if c.snapshots["c1=0,c2=0"] == nil and c.snapshots["c1=0"] ~= nil then return "pass" end
            return "fail"
        end
    end
    return "fail"
end

function schematicModeToggleTest()
    gdsGui_schematic_delete("unitTestCanvas4")
    gdsGui_schematic_create("unitTestCanvas4", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_setMode("unitTestCanvas4", "control")
    return gdsGui_schematic_getMode("unitTestCanvas4")
end

-- No snapshot exists yet for the current (no-control) signature, so the
-- element must fall back to its own default color.
function schematicResolveColorFallbackTest()
    gdsGui_schematic_delete("unitTestCanvas5")
    gdsGui_schematic_create("unitTestCanvas5", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas5", "e1", "rect", 0, 0, 0.1, 0.1, "A", {0.2, 0.3, 0.4, 1})
    local r = gdsGui_schematic_resolveColor("unitTestCanvas5", "element", "e1")
    return r
end

-- A snapshot captured for the control's current detent must be replayed the
-- next time that same combination is active — "the logic recreated".
function schematicResolveColorSnapshotMatchTest()
    gdsGui_schematic_delete("unitTestCanvas6")
    gdsGui_schematic_create("unitTestCanvas6", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas6", "e1", "rect", 0, 0, 0.1, 0.1, "A", {0.55, 0.55, 0.55, 1})
    gdsGui_schematic_addControl("unitTestCanvas6", "c1", 0, 0, {"OFF", "ON"}, 0, "C1", nil)
    gdsGui_schematic_commitSnapshot("unitTestCanvas6", { signature = "c1=0", elements = { e1 = {1, 0, 0, 1} }, wires = {} })
    local r = gdsGui_schematic_resolveColor("unitTestCanvas6", "element", "e1")
    return r
end

-- A live color-picker override takes priority over any matching snapshot.
function schematicPendingColorOverrideTest()
    gdsGui_schematic_delete("unitTestCanvas7")
    gdsGui_schematic_create("unitTestCanvas7", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas7", "e1", "rect", 0, 0, 0.1, 0.1, "A", {0.55, 0.55, 0.55, 1})
    gdsGui_schematic_setPendingColor("unitTestCanvas7", "element", "e1", {0, 1, 1, 1})
    local r = gdsGui_schematic_resolveColor("unitTestCanvas7", "element", "e1")
    return r
end

-------------------------------------------------------------------------------
-- APP-SPECIFIC UNIT TESTS
-- Registered here (top-level, after all app functions are defined) so both
-- the "gui" and "app" suites exist when gdsGui_dev_createUnitTestObjects()
-- builds the devUnitTest table below.
-------------------------------------------------------------------------------
gdsGui_unitTests_registerSuite("app", function()

    --------------------------------------------------------------------------
    --  format_time
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="format_time_zero",
        ["funcName"]={"format_time"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"00:00"}}

    gdsGui_dev_testExecute {["id"]="format_time_90sec",
        ["funcName"]={"format_time"},
        ["funcParameters"]={90},
        ["funcExpctOutput"]={"01:30"}}

    gdsGui_dev_testExecute {["id"]="format_time_3599sec",
        ["funcName"]={"format_time"},
        ["funcParameters"]={3599},
        ["funcExpctOutput"]={"59:59"}}

    gdsGui_dev_testExecute {["id"]="format_time_negative_clamps_to_zero",
        ["funcName"]={"format_time"},
        ["funcParameters"]={-5},
        ["funcExpctOutput"]={"00:00"}}

    --------------------------------------------------------------------------
    --  calcWindComponents  (returns {xw, side, ht, label} in devMode)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="calcWindComponents_direct_headwind",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={360, 20, 360},
        ["funcExpctOutput"]={0, "R", 20, "HW"}}

    gdsGui_dev_testExecute {["id"]="calcWindComponents_right_crosswind",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={90, 20, 360},
        ["funcExpctOutput"]={20, "R", 0, "HW"}}

    gdsGui_dev_testExecute {["id"]="calcWindComponents_direct_tailwind",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={180, 20, 360},
        ["funcExpctOutput"]={0, "L", 20, "TW"}}

    gdsGui_dev_testExecute {["id"]="calcWindComponents_left_crosswind",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={270, 20, 360},
        ["funcExpctOutput"]={20, "L", 0, "HW"}}

    gdsGui_dev_testExecute {["id"]="calcWindComponents_calm_wind",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={360, 0, 360},
        ["funcExpctOutput"]={0, "R", 0, "HW"}}

    gdsGui_dev_testExecute {["id"]="calcWindComponents_45deg_right_from_ahead",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={45, 20, 360},
        ["funcExpctOutput"]={14, "R", 14, "HW"}}

    gdsGui_dev_testExecute {["id"]="calcWindComponents_45deg_left_from_ahead",
        ["funcName"]={"calcWindComponents"},
        ["funcParameters"]={315, 20, 360},
        ["funcExpctOutput"]={14, "L", 14, "HW"}}

    --------------------------------------------------------------------------
    --  roundSelectedAltitude  (scrollbar top=0, bottom=1)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="roundSelectedAltitude_top_pos_51000ft",
        ["funcName"]={"roundSelectedAltitude"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={51000}}

    gdsGui_dev_testExecute {["id"]="roundSelectedAltitude_bottom_pos_0ft",
        ["funcName"]={"roundSelectedAltitude"},
        ["funcParameters"]={1},
        ["funcExpctOutput"]={0}}

    gdsGui_dev_testExecute {["id"]="roundSelectedAltitude_mid_pos_26000ft",
        ["funcName"]={"roundSelectedAltitude"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={26000}}

    --------------------------------------------------------------------------
    --  roundSelectedTime  (scrollbar top=0 → 25 min, bottom=1 → 0 min)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="roundSelectedTime_top_pos_25min",
        ["funcName"]={"roundSelectedTime"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={25}}

    gdsGui_dev_testExecute {["id"]="roundSelectedTime_bottom_pos_0min",
        ["funcName"]={"roundSelectedTime"},
        ["funcParameters"]={1},
        ["funcExpctOutput"]={0}}

    gdsGui_dev_testExecute {["id"]="roundSelectedTime_mid_pos_13min",
        ["funcName"]={"roundSelectedTime"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={13}}

    --------------------------------------------------------------------------
    --  roundSelectedDegree  (scrollbar top=0 → 8.0°, bottom=1 → 0°)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="roundSelectedDegree_top_pos_8deg",
        ["funcName"]={"roundSelectedDegree"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={8.0}}

    gdsGui_dev_testExecute {["id"]="roundSelectedDegree_bottom_pos_0deg",
        ["funcName"]={"roundSelectedDegree"},
        ["funcParameters"]={1},
        ["funcExpctOutput"]={0.0}}

    gdsGui_dev_testExecute {["id"]="roundSelectedDegree_mid_pos_4deg",
        ["funcName"]={"roundSelectedDegree"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={4.0}}

    --------------------------------------------------------------------------
    --  windSpeedChanged  (scrollbar top=0 → 45 kt, bottom=1 → 0 kt)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="windSpeedChanged_top_pos_45kt",
        ["funcName"]={"windSpeedChanged"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={45}}

    gdsGui_dev_testExecute {["id"]="windSpeedChanged_bottom_pos_0kt",
        ["funcName"]={"windSpeedChanged"},
        ["funcParameters"]={1},
        ["funcExpctOutput"]={0}}

    gdsGui_dev_testExecute {["id"]="windSpeedChanged_mid_pos_23kt",
        ["funcName"]={"windSpeedChanged"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={23}}

    --------------------------------------------------------------------------
    --  windGustChanged  (range relative to selectedWindSpeed; fixed at 0)
    --------------------------------------------------------------------------
    selectedWindSpeed = 0
    gdsGui_dev_testExecute {["id"]="windGustChanged_top_pos_60kt",
        ["funcName"]={"windGustChanged"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={60}}

    selectedWindSpeed = 0
    gdsGui_dev_testExecute {["id"]="windGustChanged_bottom_pos_0kt",
        ["funcName"]={"windGustChanged"},
        ["funcParameters"]={1},
        ["funcExpctOutput"]={0}}

    selectedWindSpeed = 0
    gdsGui_dev_testExecute {["id"]="windGustChanged_mid_pos_30kt",
        ["funcName"]={"windGustChanged"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={30}}

    --------------------------------------------------------------------------
    --  mainKnobChanged  (36 detents: pos=0 → RWY 36, 1/36 → RWY 01)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="mainKnobChanged_pos0_rwy36",
        ["funcName"]={"mainKnobChanged"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={36}}

    gdsGui_dev_testExecute {["id"]="mainKnobChanged_first_detent_rwy01",
        ["funcName"]={"mainKnobChanged"},
        ["funcParameters"]={1/36},
        ["funcExpctOutput"]={1}}

    gdsGui_dev_testExecute {["id"]="mainKnobChanged_mid_rwy18",
        ["funcName"]={"mainKnobChanged"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={18}}

    --------------------------------------------------------------------------
    --  windKnobChanged  (36 detents: pos=0 → 360°, 1/36 → 10°)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="windKnobChanged_pos0_360deg",
        ["funcName"]={"windKnobChanged"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={360}}

    gdsGui_dev_testExecute {["id"]="windKnobChanged_first_detent_10deg",
        ["funcName"]={"windKnobChanged"},
        ["funcParameters"]={1/36},
        ["funcExpctOutput"]={10}}

    gdsGui_dev_testExecute {["id"]="windKnobChanged_mid_180deg",
        ["funcName"]={"windKnobChanged"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={180}}

    gdsGui_dev_testExecute {["id"]="fontSizeChanged_min",
        ["funcName"]={"fontSizeChanged"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={12}}

    gdsGui_dev_testExecute {["id"]="fontSizeChanged_mid",
        ["funcName"]={"fontSizeChanged"},
        ["funcParameters"]={0.5},
        ["funcExpctOutput"]={14}}

    gdsGui_dev_testExecute {["id"]="fontSizeChanged_max",
        ["funcName"]={"fontSizeChanged"},
        ["funcParameters"]={1},
        ["funcExpctOutput"]={16}}

    --------------------------------------------------------------------------
    --  SYSTEM SCHEMATIC (premium feature)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="schematic_buildSignature_sortsByControlId",
        ["funcName"]={"gdsGui_schematic_buildSignature"},
        ["funcParameters"]={ {{id="b",detentIndex=1},{id="a",detentIndex=0}} },
        ["funcExpctOutput"]={"a=0,b=1"}}

    gdsGui_dev_testExecute {["id"]="schematic_buildSignature_empty",
        ["funcName"]={"gdsGui_schematic_buildSignature"},
        ["funcParameters"]={ {} },
        ["funcExpctOutput"]={""}}

    gdsGui_dev_testExecute {["id"]="schematic_colorsDiffer_sameColors_noConflict",
        ["funcName"]={"gdsGui_schematic_colorsDiffer"},
        ["funcParameters"]={ {elements={e1={1,0,0,1}}, wires={}}, {elements={e1={1,0,0,1}}, wires={}} },
        ["funcExpctOutput"]={false}}

    gdsGui_dev_testExecute {["id"]="schematic_colorsDiffer_differentColors_detectsConflict",
        ["funcName"]={"gdsGui_schematic_colorsDiffer"},
        ["funcParameters"]={ {elements={e1={1,0,0,1}}, wires={}}, {elements={e1={0,1,0,1}}, wires={}} },
        ["funcExpctOutput"]={true}}

    -- NOTE: funcParameters always carries one harmless dummy value even for
    -- zero-argument functions — gdsGui_dev_testCreate() builds its call string
    -- from #funcParameters and a bare "(,true)" is a Lua syntax error when
    -- that count is 0. Lua ignores the extra argument on the real function.
    gdsGui_dev_testExecute {["id"]="schematic_addWire_cascadeDeleteOnElementRemoval",
        ["funcName"]={"schematicCascadeDeleteTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0}}

    gdsGui_dev_testExecute {["id"]="schematic_wireColor_independentOfEndpoints",
        ["funcName"]={"schematicResolveColorIndependenceTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1}}

    gdsGui_dev_testExecute {["id"]="schematic_prepareSnapshot_shape",
        ["funcName"]={"schematicPrepareSnapshotShapeTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"pass"}}

    gdsGui_dev_testExecute {["id"]="schematic_prepareSnapshot_flagsConflictOnOverwrite",
        ["funcName"]={"schematicPrepareSnapshotConflictTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"pass"}}

    gdsGui_dev_testExecute {["id"]="schematic_snapshot_migratesOnControlAdded",
        ["funcName"]={"schematicSnapshotMigratesOnControlAddedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"pass"}}

    gdsGui_dev_testExecute {["id"]="schematic_snapshot_migratesOnControlRemoved",
        ["funcName"]={"schematicSnapshotMigratesOnControlRemovedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"pass"}}

    gdsGui_dev_testExecute {["id"]="schematicModeToggled_switchesLibraryMode",
        ["funcName"]={"schematicModeToggleTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"control"}}

    gdsGui_dev_testExecute {["id"]="schematic_resolveColor_fallsBackToDefaultWhenNoSnapshot",
        ["funcName"]={"schematicResolveColorFallbackTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0.2}}

    gdsGui_dev_testExecute {["id"]="schematic_resolveColor_usesMatchingSnapshot",
        ["funcName"]={"schematicResolveColorSnapshotMatchTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1}}

    gdsGui_dev_testExecute {["id"]="schematic_resolveColor_pendingOverrideWinsOverSnapshot",
        ["funcName"]={"schematicPendingColorOverrideTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0}}

    gdsGui_dev_testExecute {["id"]="unlockSchematicFeature_setsEntitlementFlag",
        ["funcName"]={"unlockSchematicFeatureTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true}}

end)

-- Build the unit-test table widget now that both "gui" and "app" suites are registered.
gdsGui_dev_createUnitTestObjects()
