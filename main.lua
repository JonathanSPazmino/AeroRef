-- Copyright (c) 2025-2026 Gateway Dynamic Software, LLC. All rights reserved.
--[[ Main.lua
    Author: Jonathan Pazmino
    Description: Core entry file for LÖVE app with timer and GUI integration
]]

-------------------------------------------------------------------------------
-- LIBRARIES LOAD
-------------------------------------------------------------------------------
require("Libraries.gds_love2d_gui.loader_gdsGuiLib")

-- Pure-Lua, love.*-free inference model layer (graph/solver/media) — see the
-- inference-schematic-assistance plan. Kept separate from the GUI library:
-- these modules never touch canvas/globApp directly, only the plain-table
-- shapes the adapter functions below build from the live schematic.
local ModelGraph = require("model.graph")
local ModelSolver = require("model.solver")
local ModelLearner = require("model.learner")
local ModelSuggest = require("model.suggest")
local ELECTRICAL_MEDIUM = require("model.media.electrical")
-- Self-registering media (see model/media/registry.lua) -- no local needed,
-- loading them once for the side effect is enough for _currentMedium()'s
-- own require("model.media.registry").get(systemType) to find them later.
require("model.media.hydraulic")
require("model.media.fuel")
require("model.media.bleedAir")

APP_VERSION = "1.0.26"

-- Shape version of schematicProjects.lua's data, independent of APP_VERSION
-- (an app update can ship with no data-shape change at all, or vice versa).
-- Bump only when the aircraft/system/element/wire/control/annunciator record
-- shape actually changes, and add a matching step to
-- _verifyAndRepairSchematicStore's migration handling.
-- v2: elements/controls gained an optional componentType tag (source/path/
-- gate/directionalGate/sink) for the inference model's graph — nil-safe on
-- any record saved before this existed, so no migration step was needed.
-- v3: a system gained an optional rules field ({gateId -> ruleTable} learned
-- by model/learner.lua's findSimplestRule, or user-locked — see
-- _recomputeGateRules) — nil-safe (sys.rules or {}) on any record saved
-- before this existed, same convention as v2, no migration step needed.
SCHEMATIC_SCHEMA_VERSION = 3

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

-- Set once in love.load() (see _buildSchematicCompatNotice) when the
-- one-time-per-APP_VERSION schematic data compatibility check has something
-- to tell the user; drawn as a one-button info popup the first moment the
-- user actually lands on the SystemSchematic page (see love.update below),
-- then cleared. nil the rest of the time (including every version after the
-- first one it's shown for).
local _pendingSchematicCompatNotice = nil

-- Set once in love.load(), right after the store is loaded and before
-- anything can re-save it (which would overwrite the evidence): true when
-- the save on disk was last written by a different, non-nil APP_VERSION
-- (i.e. an update was just installed over the previous build) AND no system
-- was open at the time (currentSystemId nil), meaning the user never got
-- past the aircraft picker last session. In that case, landing back on
-- SchematicHome risks looking like data vanished, so the schematic-flow
-- entry points below send the user to AircraftGallery ("MY AIRCRAFT")
-- instead, where their existing aircraft are immediately visible.
local _schematicJustUpdatedNoSystemOpen = false

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

-- Required descent/climb rate is undefined at zero minutes unless the
-- altitude change is also zero (nothing to do either way) -- shown as
-- "N/A" rather than a plain "0", which reads as "no rate needed" instead
-- of "this isn't a computable answer".
function _formatRequiredFPM(altitude, time)
    if time > 0 then
        return "REQ FPM:\n" .. math.ceil(altitude / time)
    elseif altitude == 0 then
        return "REQ FPM:\n0"
    else
        return "REQ FPM:\nN/A"
    end
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
-- Global, not local like the other _LEARN_*_RAW tables above -- this file
-- is already at Lua's 200-top-level-local ceiling (see the "Nested here...
-- to stay under this file's 200-local ceiling" comment elsewhere in this
-- file for the same constraint), and the handful of reads this table gets
-- work exactly as well through a global.
_LEARN_SCHEMATIC_RAW = {
    {text="WHAT IT IS", sub=true},
    {text="The System Schematics tool lets you draw a simplified wiring/plumbing diagram for any aircraft system — electrical, hydraulic, fuel, bleed air, or pressurization — out of a small shared set of building blocks, then simulate it and paint what's live.\n"},
    {text="SOURCE", sub=true},
    {text="Where power, pressure, or flow originates — a battery, generator, pump, or fuel tank. Some sources are always on once placed (a battery, a fuel tank); others are switched by the pilot (a generator, a pump switch).\n"},
    {text="PATH", sub=true},
    {text="Just carries whatever reaches it, with no logic of its own — a bus, manifold, or duct.\n"},
    {text="GATE", sub=true},
    {text="Can block or allow flow through itself — a switch, breaker, or shutoff valve. Closed lets it through; open blocks it.\n"},
    {text="ONE-WAY GATE", sub=true},
    {text="Lets flow pass in only one direction — a diode or check valve. Which direction is set by how the symbol is rotated on the diagram, the same way the real part only ever conducts the one way.\n"},
    {text="SINK", sub=true},
    {text="Where flow ends up and gets used — a light, motor, or engine.\n"},
    {text="INDEPENDENT SYSTEMS", sub=true},
    {text="Each system is modeled entirely on its own. A hydraulic schematic has no effect on, and no knowledge of, the electrical one — every system's wiring, switch positions, and captured snapshots are kept separate.\n"},
    {text="HOW IT LEARNS", sub=true},
    {text="Every time you CAPTURE a snapshot — the current switch/valve positions plus the colors you've painted to show what's live — the app studies it. After a few snapshots with different positions, it starts noticing patterns, e.g. \"this relay is closed exactly when that bus is powered and that switch is off,\" and turns a confirmed pattern into a rule it applies automatically from then on.\n"},
    {text="NEVER A GUESS", sub=true},
    {text="If the evidence is incomplete or contradicts itself, the app says so rather than making something up — a rule only forms once your own captured snapshots actually confirm it, and each one shows how many snapshots back it.\n"},
    {text="FOR REFERENCE ONLY", sub=true},
    {text="A modeling and training aid, not a certified systems diagram. Always verify against your aircraft's actual wiring diagrams and AFM/POH."},
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
-- Every element, wire and control starts out the palette's LIGHT GRAY (the
-- library's own default, themed for dark/white mode at draw time) — no
-- per-system wire color, so a fresh schematic reads as one uniform gray until
-- it's painted.

-- Shared by every binary (2-position) switch/valve control below: index 1
-- (the "open"/blocked/non-conducting position, always listed first in that
-- control's own presets) gets the open/disconnected-looking icon, index 2
-- (the "closed"/flowing/conducting position) gets the closed/connected-
-- looking one — true for every one of these presets even when a given
-- item's own words differ (e.g. FUEL/BLEED SWITCH still say OFF/ON), since
-- what's actually drawn tracks MEANING (does current/fluid flow through
-- it), not the position's name. Not used for MODE SWITCH (AUTO/MANUAL) —
-- that's a mode selector, not a connected/disconnected state, so these
-- icons wouldn't read correctly there. A 3-position preset (SWITCH's
-- OPEN/CLOSED/STBY) just has no 3rd entry, falling back to the plain
-- vector icon for STBY only (see gdsGui_schematic_addControl's
-- spritePaths param).
local _SWITCH_SPRITE_PATHS = {"Sprites/control_switchOpen.png", "Sprites/control_switchClosed.png"}

-- A generator's housing is the same icon for OFF and ON (unlike a SWITCH's
-- open/closed pair above, which has a distinct icon per position) — the gear
-- overlay spinning in control mode (see gdsGui_schematic_addControl's
-- overlaySpritePath) is what shows it's live, not a change of base icon.
local _GENERATOR_SPRITE_PATHS = {"Sprites/control_generatorHousing.png", "Sprites/control_generatorHousing.png"}
local _GENERATOR_OVERLAY_SPRITE_PATH = "Sprites/control_generatorGear.png"

-- abbrev: the short (up to 4-letter) name the "NAME THIS ..." prompt
-- suggests for a newly placed item, as ABBREV_N (e.g. BATT_1) — see
-- schematicCatalogItemChosen/_suggestedPlacementName.
local SCHEMATIC_CATALOG = {
    { system = "ELECTRICAL", items = {
        -- componentType: this item's role in the inference model's graph
        -- (model/graph.lua) — "source" | "path" | "gate" | "directionalGate"
        -- | "sink" — see schematicCatalogItemChosen/PresetChosen below,
        -- which pass it straight through to armElementPlacement/
        -- armControlPlacement. Every system below is tagged now (the
        -- model/media/registry.lua medium registry is what makes a second
        -- tagged system safe — see that file's own header comment) — each
        -- system's own elements/wires/controls are a separate canvas
        -- (schematicStore.aircraft[].systems[].{elements,wires,controls}),
        -- so one aircraft's HYDRAULIC schematic and its ELECTRICAL
        -- schematic are solved/deduced completely independently; nothing
        -- here lets a gate or rule in one system see, let alone affect,
        -- another's state. PRESSURIZATION's CONTROLLER and MODE SWITCH are
        -- the one deliberate exception, left untagged below — neither is a
        -- flow/propagation node (a mode selector and an avionics box, not
        -- something current/fluid/air passes through), so forcing a
        -- source/path/gate/sink role onto either would just be wrong, not
        -- merely incomplete (see that entry's own comment).
        -- gridSize: diameter in grid units (see schematic_gdsGuiLib.lua's
        -- _GRID_SPACING_PX) — every element/control size in this catalog is
        -- authored this way now, not as a multiplier on some shared default.
        { label = "GENERATOR", abbrev = "GENR", kind = "control", presets = { {"OFF", "ON"} },
          spritePaths = _GENERATOR_SPRITE_PATHS, overlaySpritePath = _GENERATOR_OVERLAY_SPRITE_PATH,
          gridSize = 2, componentType = "source" },
        { label = "BATTERY", abbrev = "BATT",   kind = "element", shapeType = "rect",
          defaultProperties = {"VOLTAGE", "CURRENT"}, spritePath = "Sprites/element_battery.png",
          gridW = 2, gridH = 3, componentType = "source" },
        { label = "BUS", abbrev = "BUS",       kind = "element", shapeType = "rect",
          defaultProperties = {"VOLTAGE", "CURRENT"}, spritePath = "Sprites/element_bus.png",
          gridW = 4, gridH = 2, componentType = "path" },
        { label = "DIODE", abbrev = "DIOD",     kind = "element", shapeType = "diode", spritePath = "Sprites/element_diode.png",
          gridW = 2, gridH = 2, componentType = "directionalGate" },
        { label = "SWITCH", abbrev = "SWCH",    kind = "control", presets = { {"OPEN", "CLOSED"}, {"OPEN", "CLOSED", "STBY"} },
          spritePaths = _SWITCH_SPRITE_PATHS, gridSize = 2, componentType = "gate" },
        -- Double pole, single throw: two mechanically-ganged switch poles
        -- (the dashed link drawn between them in the artwork) each feeding
        -- its own diode before reaching its own "ending" terminal — a fixed
        -- static symbol (kind = "element", like DIODE/BATTERY/BUS above),
        -- not an interactive on/off control.
        { label = "DPST SWITCH", abbrev = "DPST", kind = "element", shapeType = "rect",
          spritePath = "Sprites/element_dpstDiode.png", gridW = 3, gridH = 4, componentType = "directionalGate" },
    }},
    { system = "HYDRAULIC", items = {
        -- ACCUMULATOR/PUMP mirror BATTERY/GENERATOR's own split exactly: a
        -- passive always-pressurized element (stored residual pressure,
        -- present whenever placed, like a battery) plus a pilot-switchable
        -- source control (reuses GENERATOR's own spinning-gear-overlay
        -- affordance — a motor/engine-driven pump "spinning up" reads the
        -- same way a generator does). Placing either prompts for its
        -- nominal PRESSURE the same way a new electrical source prompts
        -- for VOLTAGE (model/media/hydraulic.lua's own magnitudeLabel —
        -- see schematicSourceElementPlaced).
        { label = "ACCUMULATOR", abbrev = "ACUM", kind = "element", shapeType = "rect",
          defaultProperties = {"PRESSURE"}, gridW = 2, gridH = 3, componentType = "source" },
        { label = "PUMP", abbrev = "PUMP", kind = "control", presets = { {"OFF", "ON"} },
          spritePaths = _GENERATOR_SPRITE_PATHS, overlaySpritePath = _GENERATOR_OVERLAY_SPRITE_PATH,
          gridSize = 2, componentType = "source" },
        { label = "MANIFOLD", abbrev = "MNFD", kind = "element", shapeType = "rect",
          defaultProperties = {"PRESSURE"}, gridW = 4, gridH = 2, componentType = "path" },
        -- Non-user-operated, one-way flow — same role/geometry-derived
        -- conduction direction as ELECTRICAL's own DIODE above (see
        -- model/graph.lua's _resolveDirectionalEdges), just reusing that
        -- same vector symbol for a check valve rather than a dedicated
        -- fluid-power glyph (no art asset for one exists yet).
        { label = "CHECK VALVE", abbrev = "CVLV", kind = "element", shapeType = "diode",
          gridW = 2, gridH = 2, componentType = "directionalGate" },
        -- A 3rd AUTO position (e.g. a PTU/priority valve) behaves exactly
        -- like SWITCH's own STBY above — not "CLOSED", so it reads as the
        -- inactive/open position for gate-blocking purposes, just a named
        -- 3rd detent rather than a special case.
        { label = "SHUTOFF VALVE", abbrev = "HSOV", kind = "control",
          presets = { {"CLOSED", "OPEN"}, {"CLOSED", "OPEN", "AUTO"} },
          spritePaths = _SWITCH_SPRITE_PATHS, gridSize = 2, componentType = "gate" },
        { label = "RESERVOIR", abbrev = "RSVR", kind = "element", shapeType = "circle",
          gridW = 3, gridH = 3, componentType = "sink" },
    }},
    { system = "FUEL", items = {
        { label = "FUEL TANK", abbrev = "FTNK", kind = "element", shapeType = "circle",
          defaultProperties = {"QUANTITY"}, gridW = 3, gridH = 3, componentType = "source" },
        -- Boost pump: mirrors HYDRAULIC's own PUMP control above (and
        -- ELECTRICAL's GENERATOR) — a pilot-switchable source, not the
        -- always-present FUEL TANK itself.
        { label = "FUEL PUMP", abbrev = "FPMP", kind = "control", presets = { {"OFF", "ON"} },
          spritePaths = _GENERATOR_SPRITE_PATHS, overlaySpritePath = _GENERATOR_OVERLAY_SPRITE_PATH,
          gridSize = 2, componentType = "source" },
        { label = "FUEL MANIFOLD", abbrev = "FMFD", kind = "element", shapeType = "rect",
          defaultProperties = {"PRESSURE"}, gridW = 4, gridH = 2, componentType = "path" },
        -- Same non-user-operated, one-way role as HYDRAULIC's own CHECK
        -- VALVE above (e.g. an anti-siphon or crossfeed check valve).
        { label = "CHECK VALVE", abbrev = "CKVL", kind = "element", shapeType = "diode",
          gridW = 2, gridH = 2, componentType = "directionalGate" },
        { label = "FUEL SHUTOFF VALVE", abbrev = "FSOV", kind = "control",
          presets = { {"CLOSED", "OPEN"}, {"CLOSED", "OPEN", "AUTO"} },
          spritePaths = _SWITCH_SPRITE_PATHS, gridSize = 2, componentType = "gate" },
        { label = "ENGINE", abbrev = "ENGN", kind = "element", shapeType = "rect",
          defaultProperties = {"FUEL FLOW"}, gridW = 3, gridH = 2, componentType = "sink" },
    }},
    { system = "BLEED AIR", items = {
        -- The engine/APU's own bleed air supply — always "there" whenever
        -- the engine's running, same always-on-when-placed role as BATTERY/
        -- FUEL TANK above (this system has no separate switchable-source
        -- control; bleed is throttled downstream by BLEED VALVE instead).
        { label = "BLEED AIR SOURCE", abbrev = "BSRC", kind = "element", shapeType = "circle",
          defaultProperties = {"PRESSURE"}, gridW = 3, gridH = 3, componentType = "source" },
        { label = "DUCT", abbrev = "DUCT", kind = "element", shapeType = "rect",
          defaultProperties = {"PRESSURE"}, gridW = 4, gridH = 2, componentType = "path" },
        -- Same non-user-operated, one-way role as the other systems' own
        -- CHECK VALVE above (e.g. an engine-to-engine isolation check
        -- valve preventing backflow).
        { label = "CHECK VALVE", abbrev = "BCVL", kind = "element", shapeType = "diode",
          gridW = 2, gridH = 2, componentType = "directionalGate" },
        -- The pilot-operated shutoff itself, same single-item pattern as
        -- ELECTRICAL's own SWITCH (the valve body IS the control; there's
        -- no separate static "valve element" + "switch control" pair).
        { label = "BLEED VALVE", abbrev = "BVLV", kind = "control", presets = { {"CLOSED", "OPEN"} },
          spritePaths = _SWITCH_SPRITE_PATHS, gridSize = 2, componentType = "gate" },
    }},
    { system = "PRESSURIZATION", items = {
        -- Converted from a static element to a control (like ELECTRICAL's
        -- own SWITCH) — a real outflow valve IS pilot-operable in MANUAL
        -- mode, not a fixed symbol. componentType = "gate": open lets
        -- cabin air escape, closed holds pressure, same role SHUTOFF
        -- VALVE/BLEED VALVE play in their own systems.
        { label = "OUTFLOW VALVE", abbrev = "OFVL", kind = "control", presets = { {"CLOSED", "OPEN"} },
          spritePaths = _SWITCH_SPRITE_PATHS, gridSize = 2, componentType = "gate" },
        -- Deliberately untagged: an avionics logic box, not a flow node —
        -- nothing current/fluid/air passes THROUGH a controller the way it
        -- does through every componentType above, so no source/path/gate/
        -- sink role fits it (see this system's own header comment).
        { label = "CONTROLLER", abbrev = "CTLR", kind = "element", shapeType = "rect",
          defaultProperties = {"CABIN ALT", "RATE"}, gridW = 4, gridH = 3 },
        -- Deliberately untagged: AUTO/MANUAL is a mode selector (which
        -- logic drives OUTFLOW VALVE), not a connected/disconnected flow
        -- state — same reasoning the file's own shared-sprite-table
        -- comment above _SWITCH_SPRITE_PATHS already gives for why this
        -- item was excluded from that icon convention.
        { label = "MODE SWITCH", abbrev = "MSWT", kind = "control", presets = { {"AUTO", "MANUAL"} }, gridSize = 2 },
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

-- Phase 5 (inference-schematic-assistance plan) UI state: which gate the
-- open GATE RULES detail menu's LOCK action targets, and the detents the
-- open SUGGEST NEXT SNAPSHOT menu's APPLY action would jump to — see
-- _openGateRulesListMenu/_openSuggestNextSnapshotMenu below and their
-- *Chosen callbacks further down the file.
local _pendingGateRuleGateId    = nil
local _pendingSuggestedDetents  = nil
-- Which ambiguous node the open ATTRIBUTION RULES detail menu's LOCK
-- action targets — see _openAttributionRulesListMenu below.
local _pendingAttributionRuleNodeId = nil
-- Which "source"-role node the open PER-SOURCE SETTINGS detail menu's
-- VOLTAGE action targets — see _openPerSourceSettingDetailMenu below.
local _pendingPerSourceTargetId = nil

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

-- Floating tool dock at the canvas's top-right (ADD / PAINT / ANNUNCIATOR,
-- top to bottom). x and each button's normal y (0-1 of the safe area) are
-- captured once at creation in love.load() for the same reason as
-- _schematicCanvasNormalLayout above. While one tool is active
-- (_activeSchematicTool, see _enterSchematicTool), that tool's button moves
-- up to the top slot and the others are hidden until it's deactivated.
local _SCHEMATIC_DOCK_TOOLS = {
    add         = "schematicAddBtn",
    paint       = "schematicPaintBtn",
    annunciator = "schematicAnnunciatorBtn",
}
local _schematicDockX      = nil
local _schematicDockSlotY  = {}   -- button name -> normal y
local _activeSchematicTool = nil  -- nil | "add" | "paint" | "annunciator"
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

-- Shared by all three schematic header readouts (zoom/snapshot/combination,
-- see their create calls below) — sets a box's text and immediately
-- shrinks its font to fit on one line within its own current width, same
-- mechanism/rationale as schematic_pageTitle's own setFontSizeToFit use
-- (see _applyFontSize's comment on why that one needs a per-use refit too,
-- not just the one tied to an actual FONT SIZE setting change). Guarantees
-- none of the three ever wraps onto a second line — no matter how long
-- "(PREDICTED)" or a growing snapshot/combination count makes the text —
-- at the cost of shrinking (down to minSize) rather than breaking a line.
local function _setHeaderReadoutText(boxName, text, minSize)
    gdsGui_outputTxtBox_setText(boxName, text)
    gdsGui_outputTxtBox_setFontSizeToFit(boxName, appSettings.fontSize, minSize)
end

-- "SNAPSHOTS" abbreviated to "SNAP" so this fixed-width readout has room to
-- spare at the user's current font size before _setHeaderReadoutText's
-- shrink-to-fit ever needs to kick in at all.
local function _setSnapshotLabelText(count)
    _setHeaderReadoutText("schematicSnapshotLabel", "SNAP: " .. count, 8)
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
-- helicopter/propeller point at their own CANVAS_BACKGROUND_BY_TYPE
-- watermark art (below) rather than a dedicated aircraftThumb_*.png — those
-- two dedicated files wouldn't render in the live picker (content verified
-- correct on disk, still blank/not showing in-app after a full restart), so
-- these reuse art already confirmed working elsewhere in the running app.
-- jet has no CANVAS_BACKGROUND_BY_TYPE entry of its own (falls back to
-- CANVAS_BACKGROUND_DEFAULT, not jet-specific), so it keeps its own
-- dedicated thumbnail file, which does render correctly.
local AIRCRAFT_THUMBNAILS = {
    { key = "helicopter", label = "HELICOPTER", path = "Sprites/bg_schematicCanvas_helicopter.png" },
    { key = "jet",        label = "JET",        path = "Sprites/aircraftThumb_jet.png" },
    { key = "propeller",  label = "PROP PLANE",  path = "Sprites/bg_schematicCanvas_propeller.png" },
}

local function _aircraftThumbnailPath(key)
    for _, t in ipairs(AIRCRAFT_THUMBNAILS) do
        if t.key == key then return t.path end
    end
    return nil
end

-- Per-aircraft-type watermark shown behind mainCanvas (see
-- gdsGui_schematic_setBackgroundImage and _openSystemIntoCanvas below), keyed
-- by the same AIRCRAFT_THUMBNAILS.key as the gallery tile. A type with no
-- entry here (e.g. "jet") falls back to CANVAS_BACKGROUND_DEFAULT.
local CANVAS_BACKGROUND_BY_TYPE = {
    propeller  = "Sprites/bg_schematicCanvas_propeller.png",
    helicopter = "Sprites/bg_schematicCanvas_helicopter.png",
}
local CANVAS_BACKGROUND_DEFAULT = "Sprites/bg_schematicCanvas.png"

local function _canvasBackgroundPath(aircraft)
    return (aircraft and CANVAS_BACKGROUND_BY_TYPE[aircraft.thumbnail]) or CANVAS_BACKGROUND_DEFAULT
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

-- The active medium for whichever system is currently open — looked up by
-- that system's own systemType against model/media/registry.lua's
-- {systemType -> medium} registry, which is the seam
-- model/media/electrical.lua's own header comment anticipates for a future
-- hydraulic.lua/fuel.lua: every caller below resolves "the" medium through
-- here instead of naming ELECTRICAL_MEDIUM directly, so plugging in a
-- second medium only ever means registering it, never touching this
-- function's callers. Falls back to ELECTRICAL_MEDIUM -- the same default
-- this app had unconditionally before the registry existed -- whenever no
-- system is open yet (schematicStore nil/currentSystemId unset, e.g. every
-- existing unit test building a throwaway canvas outside schematicStore
-- entirely) or that system's systemType has no registered medium, so
-- nothing already working regresses.
local function _currentMedium()
    local sys = schematicStore and _findSystem(schematicStore.currentSystemId)
    return (sys and require("model.media.registry").get(sys.systemType)) or ELECTRICAL_MEDIUM
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

-- Verify-then-promote write: a bad serialize must never be able to clobber
-- the last good save, and there must always be one prior generation to
-- recover from. See _loadSchematicStoreSafely below for the matching load
-- side of this.
-- fileName defaults to the real save; unit tests pass a throwaway name so
-- they can exercise this without ever touching the user's actual save data.
local function _saveSchematicStore(fileName)
    fileName = fileName or "schematicProjects.lua"
    schematicStore.schemaVersion     = SCHEMATIC_SCHEMA_VERSION
    schematicStore.savedByAppVersion = APP_VERSION

    local serialized = table.show(schematicStore, "schematicStore")
    local tmpName = fileName .. ".tmp"
    love.filesystem.write(tmpName, serialized)

    -- Round-trips the just-written chunk through load() (compiles only,
    -- doesn't run it) before it's ever allowed to touch the real file — a
    -- table.show() edge case that produced invalid Lua source must never get
    -- the chance to overwrite a good save with garbage.
    if not love.filesystem.load(tmpName) then
        love.filesystem.remove(tmpName)
        print("WARNING: " .. fileName .. " save aborted -- serialized data failed to parse back. Previous save left untouched.")
        return
    end

    -- Roll the current good file into a one-generation backup before
    -- overwriting it, so even a write that parses fine but is wrong in some
    -- other way still leaves a last-known-good copy to fall back to.
    if love.filesystem.getInfo(fileName) then
        local prevContents = love.filesystem.read(fileName)
        if prevContents then
            love.filesystem.write(fileName .. ".bak", prevContents)
        end
    end

    love.filesystem.write(fileName, serialized)
    love.filesystem.remove(tmpName)
end

-- Loads/executes a serialized Lua data file inside pcall, so a truncated or
-- otherwise broken save can never crash love.load() outright the way
-- gdsGui_saveLoad_loadFileContents's unguarded loadData() call would.
-- Returns true only if the file existed AND executed without error.
local function _tryLoadLuaDataFile(fileName)
    if not love.filesystem.getInfo(fileName) then return false end
    local chunk = love.filesystem.load(fileName)
    if not chunk then return false end
    return pcall(chunk)
end

-- A corrupt save is archived under a timestamped name, never deleted outright
-- — always hand-recoverable even in the worst case.
local function _archiveCorruptSchematicFile(fileName)
    local contents = love.filesystem.read(fileName)
    if contents then
        love.filesystem.write(fileName .. ".corrupt-" .. os.time(), contents)
    end
    love.filesystem.remove(fileName)
end

-- Loads a serialized aircraft/systems store with a fallback chain so a
-- corrupted save can never silently lose a user's aircraft: primary file ->
-- <fileName>.bak (one rolling generation, see _saveSchematicStore above) ->
-- nil, which the caller's own existing fresh-install migration/seed logic in
-- love.load() already handles exactly as before. fileName defaults to the
-- real save; unit tests pass a throwaway name instead. An old-but-valid
-- shape (e.g. the legacy flat project list) is still a plain table and is
-- left alone here — only a file that fails to parse/execute, or that
-- executes into something that isn't even a table, counts as corruption.
-- Returns a status string consumed only by the one-time compat notice.
local function _loadSchematicStoreSafely(fileName)
    fileName = fileName or "schematicProjects.lua"
    schematicStore = nil
    local primaryExisted = love.filesystem.getInfo(fileName) ~= nil
    local execOk = _tryLoadLuaDataFile(fileName)
    local primaryUsable = execOk and (schematicStore == nil or type(schematicStore) == "table")

    if primaryUsable or not primaryExisted then
        return "ok"
    end

    _archiveCorruptSchematicFile(fileName)

    schematicStore = nil
    local bakOk = _tryLoadLuaDataFile(fileName .. ".bak")
    if bakOk and type(schematicStore) == "table" then
        love.filesystem.write(fileName, table.show(schematicStore, "schematicStore"))
        return "restoredFromBackup"
    end

    schematicStore = nil
    return "recoveredNone"
end

-- Suffixes the id of any list item whose id collides with an earlier item's
-- (by idField) with _2, _3, ... — the same scheme already proven for wires
-- (_uniqueWireId in schematic_gdsGuiLib.lua) — generalized here so a
-- duplicate id anywhere in a loaded save can never make _findElement/
-- _findWire/_findControl-style lookups resolve ambiguously. Renames the
-- second (and later) occurrence; never deletes either record. notes is
-- appended to via describe(oldId, newId) for the compat notice.
local function _dedupeIds(list, idField, describe, notes)
    local allIds = {}
    for _, item in ipairs(list) do
        if item[idField] ~= nil then allIds[item[idField]] = true end
    end
    local firstSeen = {}
    for _, item in ipairs(list) do
        local id = item[idField]
        if id ~= nil then
            if not firstSeen[id] then
                firstSeen[id] = true
            else
                local n = 2
                while allIds[id .. "_" .. n] do n = n + 1 end
                local newId = id .. "_" .. n
                allIds[newId] = true
                table.insert(notes, describe(id, newId))
                item[idField] = newId
            end
        end
    end
end

-- Runs on every load (not just once per APP_VERSION — a duplicate-id issue
-- isn't tied to app updates) and mutates store in place: nil-guards every
-- expected array field per aircraft/system instead of ever discarding a
-- record for a missing one, and de-duplicates aircraft/system/element/wire/
-- control/annunciator ids via _dedupeIds. Returns {notes, aircraftCount,
-- systemCount} for the one-time compat notice to summarize.
local function _verifyAndRepairSchematicStore(store)
    local notes = {}
    local aircraftList = (store and store.aircraft) or {}
    _dedupeIds(aircraftList, "id", function(old, new)
        return "aircraft id '" .. old .. "' was duplicated — second instance renamed to '" .. new .. "'"
    end, notes)

    local aircraftCount, systemCount = 0, 0
    for _, aircraft in ipairs(aircraftList) do
        aircraftCount = aircraftCount + 1
        aircraft.systems = aircraft.systems or {}
        _dedupeIds(aircraft.systems, "id", function(old, new)
            return "system id '" .. old .. "' was duplicated in aircraft '" .. (aircraft.name or aircraft.id) ..
                "' — second instance renamed to '" .. new .. "'"
        end, notes)
        for _, sys in ipairs(aircraft.systems) do
            systemCount = systemCount + 1
            sys.elements     = sys.elements     or {}
            sys.wires        = sys.wires        or {}
            sys.controls     = sys.controls     or {}
            sys.annunciators = sys.annunciators or {}
            sys.snapshots    = sys.snapshots    or {}
            local sysLabel = sys.name or sys.id or "?"
            _dedupeIds(sys.elements, "id", function(old, new)
                return "system '" .. sysLabel .. "': duplicate element id '" .. old .. "' renamed to '" .. new .. "'"
            end, notes)
            _dedupeIds(sys.wires, "id", function(old, new)
                return "system '" .. sysLabel .. "': duplicate wire id '" .. old .. "' renamed to '" .. new .. "'"
            end, notes)
            _dedupeIds(sys.controls, "id", function(old, new)
                return "system '" .. sysLabel .. "': duplicate control id '" .. old .. "' renamed to '" .. new .. "'"
            end, notes)
            _dedupeIds(sys.annunciators, "id", function(old, new)
                return "system '" .. sysLabel .. "': duplicate annunciator id '" .. old .. "' renamed to '" .. new .. "'"
            end, notes)
        end
    end

    return { notes = notes, aircraftCount = aircraftCount, systemCount = systemCount }
end

-- Builds the one-time-per-APP_VERSION info-popup message (see love.load()'s
-- use of _pendingSchematicCompatNotice and love.update()'s display of it).
local function _buildSchematicCompatNotice(loadStatus, repair)
    local summary
    if loadStatus == "restoredFromBackup" then
        summary = "A saved aircraft file could not be read and was restored from the last backup."
    elseif loadStatus == "recoveredNone" then
        summary = "A saved aircraft file could not be read and no backup was available. " ..
            "Your previous file was kept as a '.corrupt' file (visible in the app's save folder) " ..
            "for support; a starter project was loaded instead."
    else
        summary = string.format("%d aircraft / %d system(s) verified compatible with v%s.",
            repair.aircraftCount, repair.systemCount, APP_VERSION)
    end
    if #repair.notes > 0 then
        summary = summary .. " Repaired " .. #repair.notes .. " duplicate ID issue(s) automatically — nothing was lost."
    end
    return summary
end

-- No-op onSelect for the compat notice's single "OK" row (see love.update()
-- below) — resolved by name via _G[...], same convention every other
-- schematic menu callback uses.
function schematicCompatNoticeDismissed()
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
    sys.rules         = _deepCopyTable(canvas.rules)
    sys.attributionRules = _deepCopyTable(canvas.attributionRules)
    sys.voltageColors = _deepCopyTable(canvas.voltageColors)
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

local function _clearMainCanvas()
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    for i = #canvas.elements, 1, -1 do table.remove(canvas.elements, i) end
    for i = #canvas.wires, 1, -1 do table.remove(canvas.wires, i) end
    for i = #canvas.controls, 1, -1 do table.remove(canvas.controls, i) end
    for i = #canvas.annunciators, 1, -1 do table.remove(canvas.annunciators, i) end
    canvas.snapshots = {}
    canvas.rules = {}
    canvas.attributionRules = {}
    canvas.voltageColors = {}
    canvas.selectedElementId = nil
    -- Every id-bearing thing this counter could ever collide with (every
    -- element/control/annunciator above) is already gone at this point —
    -- nothing left for a stale high counter to protect against, so a reset
    -- page should mint ids starting back at _1 like a brand-new canvas does
    -- (see schematic_gdsGuiLib.lua's own canvas._placementCounter = 0 at
    -- creation), not silently keep climbing from wherever it left off.
    canvas._placementCounter = 0
end

-------------------------------------------------------------------------------
-- INFERENCE MODEL ADAPTER
-- Translates the live mainCanvas (elements/controls/wires + their
-- componentType tags, see SCHEMATIC_CATALOG) into the plain-table shapes
-- model/graph.lua and model/solver.lua expect, and translates the solved
-- result back into colors gdsGui_schematic_applySolvedColors can apply. See
-- the inference-schematic-assistance plan's Phase 1 — electrical domain
-- only; componentType is nil (untagged) for every other system's catalog
-- items today, so _solveCurrentSchematic is a no-op for them.
-------------------------------------------------------------------------------

local function _buildComponentTypeMap(canvas)
    local map = {}
    for _, e in ipairs(canvas.elements) do if e.componentType then map[e.id] = e.componentType end end
    for _, c in ipairs(canvas.controls) do if c.componentType then map[c.id] = c.componentType end end
    return map
end

-- {id -> {x, y, rotation}} for every element AND control on canvas, fed to
-- ModelGraph.buildGraph as its optional 5th param so it can resolve a
-- "directionalGate" (DIODE, DPST SWITCH) edge's real conducting direction
-- geometrically — from the diode's own rotation and which side of it a
-- neighbor physically sits on — instead of from whichever element the wire
-- happened to be DRAWN from first (model/graph.lua's own prior, admittedly
-- fragile convention; see its own comment). x/y is each node's own CENTER,
-- in the same 0-1-of-canvas fractional space every element/control is
-- already stored in: an element's x/y is its box's top-left corner (so
-- center = x + w/2, y + h/2), while a control's x/y already IS its center
-- (see schematic_gdsGuiLib.lua's own _anchorCenter, same "element box vs.
-- control point" split, just in fraction space here rather than pixels —
-- fine for this purpose since only the SIGN of a same-axis delta ever
-- matters, never true distance). rotation defaults to 0 (nil-safe) and is
-- only ever consulted for a "directionalGate" node — carried for every
-- node uniformly rather than filtered, since it's cheap and harmless for
-- every other role.
local function _nodePositionsForGraph(canvas)
    local positions = {}
    for _, e in ipairs(canvas.elements) do
        positions[e.id] = { x = e.x + (e.w or 0) / 2, y = e.y + (e.h or 0) / 2, rotation = e.rotation or 0 }
    end
    for _, c in ipairs(canvas.controls) do
        positions[c.id] = { x = c.x, y = c.y, rotation = c.rotation or 0 }
    end
    return positions
end

-- The live element OR control table for id, whichever array it's actually
-- in — a "source" node can be either (BATTERY is an element, GENERATOR is
-- a control). Used by _colorForPoweredNode's per-source color/voltage
-- lookup below, and by the per-source settings menus further down.
local function _findSourceEntity(canvas, id)
    for _, e in ipairs(canvas.elements) do if e.id == id then return e end end
    for _, c in ipairs(canvas.controls) do if c.id == id then return c end end
    return nil
end

-- "ON"/"CLOSED" is the v1 convention for "this control is in its
-- conducting position" (a gate that's closed, or a source that's on) --
-- the plan's open design question flags a per-catalog-item
-- closedPositionLabels table as a possible refinement, but a hard-coded
-- literal check is the stated Phase 1 baseline, not a stand-in for it.
local function _isActivePosition(control)
    local label = control.positions and control.positions[control.detentIndex + 1]
    return label == "ON" or label == "CLOSED"
end

local function _currentGateStates(canvas, componentTypes)
    local states = {}
    for _, c in ipairs(canvas.controls) do
        if componentTypes[c.id] == "gate" then
            states[c.id] = _isActivePosition(c) and "closed" or "open"
        end
    end
    return states
end

-- A "source" element (e.g. BATTERY) has no detent of its own, so it's
-- simply on whenever it's present; a "source" control (e.g. GENERATOR) is
-- on only in its active position.
local function _currentSourceStates(canvas, componentTypes)
    local states = {}
    for _, e in ipairs(canvas.elements) do
        if componentTypes[e.id] == "source" then states[e.id] = true end
    end
    for _, c in ipairs(canvas.controls) do
        if componentTypes[c.id] == "source" then states[c.id] = _isActivePosition(c) end
    end
    return states
end

-- Like _currentGateStates/_currentSourceStates above, but for a CANDIDATE
-- detents table (model/suggest.lua's own {id -> detentIndex} shape) rather
-- than canvas.controls' own live detentIndex -- lets _computeAiPanelStats'
-- targeted-suggestion scorer ask "what would this gate/source look like
-- UNDER a combination that hasn't actually been navigated to" without
-- touching the live canvas at all. A control missing from detents falls
-- back to its own current detentIndex, same "control added since this
-- reference point existed" safety as _pastGateAndSourceStates' own
-- signature-parsing fallback.
local function _gateAndSourceStatesForDetents(canvas, componentTypes, detents)
    local gateStates, sourceStates = {}, {}
    for _, e in ipairs(canvas.elements) do
        if componentTypes[e.id] == "source" then sourceStates[e.id] = true end
    end
    for _, c in ipairs(canvas.controls) do
        local isActive = _isActivePosition({ positions = c.positions, detentIndex = detents[c.id] or c.detentIndex })
        if componentTypes[c.id] == "gate" then
            gateStates[c.id] = isActive and "closed" or "open"
        elseif componentTypes[c.id] == "source" then
            sourceStates[c.id] = isActive
        end
    end
    return gateStates, sourceStates
end

-- Builds the graph from the live mainCanvas, solves it, and maps the
-- result through the electrical medium's style table into a
-- snapshot-bucket-shaped {elements={id=color}, wires={id=color},
-- controls={id=color}} ready for gdsGui_schematic_applySolvedColors.
-- Returns nil if the canvas has no graph-tagged nodes at all (nothing to
-- solve — e.g. every other system besides ELECTRICAL today). No canvasName
-- parameter, same as _requestSchematicSave/_captureCurrentSystemFromCanvas
-- above — this app only ever has the one live canvas, "mainCanvas" (see
-- _findSchematicCanvas); a throwaway-canvas unit test exercises the smaller
-- pieces (_buildComponentTypeMap/_currentGateStates/_currentSourceStates,
-- which DO take an explicit canvas table) directly instead.
-- The color registered for a given nominal voltage on THIS system
-- (canvas.voltageColors, keyed by the plain voltage number — see
-- _ensureVoltageHasColor), or defaultColor if that voltage has none yet
-- registered on this particular system. voltage == nil (the source was
-- never assigned one at all, e.g. a freshly-placed BATTERY whose VOLTAGE
-- prompt hasn't been answered yet) is a DIFFERENT case from that —
-- there's no "powered, color just not picked yet" state to show; it reads
-- as the flat unpowered gray outright, same as a source that's actually
-- off, rather than defaultColor (every production caller passes
-- _currentMedium().style.powered there, which would otherwise show an
-- unassigned source as a generic energized yellow it hasn't earned yet).
local function _colorForVoltage(canvas, voltage, defaultColor)
    if not voltage then return _currentMedium().style.unpowered end
    local registered = canvas.voltageColors and canvas.voltageColors[voltage]
    return registered or defaultColor
end

-- The source id a learned/locked attribution rule (model/learner.lua's
-- findAttributionRule, see _recomputeAttributionRules) predicts actually
-- explains nodeId under the CURRENT combination (nodeStates — the same
-- "powered"/"unpowered" vocabulary _snapshotToNodeStates/solve() produce),
-- or nil when there's no rule for this node, or the rule exists but its
-- condition states were never seen in training (buildConditionKey returns
-- nil for a missing condition state, or the key just isn't in the
-- mapping) — either way, "not covered," not a guess.
local function _attributionRuleWinner(canvas, nodeId, nodeStates)
    local rule = canvas.attributionRules and canvas.attributionRules[nodeId]
    if not rule or (rule.status ~= "learned" and rule.status ~= "locked") then return nil end
    local key = ModelLearner.buildConditionKey(rule.conditionIds, nodeStates)
    return key and rule.mapping[key]
end

-- True when a node reached by 2+ contributing sources is genuinely
-- ambiguous in DISPLAY-COLOR terms — i.e. _colorForPoweredNode's
-- highest-voltage pick is an actual, unverified assumption about which
-- contributor dominates, not a foregone conclusion. False (not ambiguous
-- at all, nothing to teach or distrust) when the TOP voltage among the
-- contributors is shared by two or more of them — a true parallel tie
-- (e.g. two 28V generators feeding the same bus) always resolves to the
-- identical registered color regardless of which one "really" explains
-- it, exactly like _colorForPoweredNode's own "a tie in voltage is never
-- ambiguous on its own" case. Only when the top voltage belongs to
-- exactly ONE contributor (a genuine highest-vs-the-rest pick that could
-- be wrong — see the single-shared-gate-node case in
-- _colorForPoweredNode's own comment) or some contributor's voltage is
-- unset at all (the dashed-sequence fallback, truly unknowable) does this
-- return true. Shared by _deduceAttributionWinnersForSnapshot (only
-- worth teaching a winner for a genuinely ambiguous node — trying to
-- match a tied-but-same-color case would just find the painted color
-- matching BOTH tied contributors at once and get correctly skipped as
-- inconclusive anyway, so there's nothing to learn there) and
-- _aiColorAttributionConfidence (only worth scoring unconfident for one).
local function _isGenuinelyColorAmbiguous(canvas, contributingIds)
    local count, maxVoltage, maxCount, allHaveVoltage = 0, -math.huge, 0, true
    for id in pairs(contributingIds) do
        count = count + 1
        local entity = _findSourceEntity(canvas, id)
        local voltage = entity and entity.voltage
        if not voltage then
            allHaveVoltage = false
        elseif voltage > maxVoltage then
            maxVoltage, maxCount = voltage, 1
        elseif voltage == maxVoltage then
            maxCount = maxCount + 1
        end
    end
    if count <= 1 then return false end
    if not allHaveVoltage then return true end
    return maxCount == 1
end

-- (The single-highest-voltage-contributor pick this same reasoning needs
-- for canvas.voltageDominanceRule lives as a nested local inside
-- _recomputeAttributionRules below — its only caller — rather than here
-- at file scope, to stay under this file's 200-local ceiling.)

-- Which color (or, when genuinely ambiguous — see below — which SEQUENCE
-- of colors) a powered node should show, given attribution[nodeId] (the
-- set of currently-active sources actually reaching it — see
-- model/solver.lua's solveSourceAttribution) and each source's own
-- optional VOLTAGE (see _openPerSourceSettingsListMenu). Color is keyed by
-- VOLTAGE now, not by individual source (_colorForVoltage above) — so two
-- sources sharing a voltage always share a color too, automatically.
-- nodeStates (optional, defaults to {}) is this combination's own solved
-- "powered"/"unpowered" state per node — needed only to look up an
-- attribution rule's condition match; every existing caller that doesn't
-- care about rules (e.g. a hand-built test canvas) can omit it and falls
-- straight through to the voltage heuristic below, unchanged.
--
-- A node reached by exactly one active source shows that source's voltage
-- color (falling back to the system-wide default powered color if it has
-- no voltage registered). A node reached by TWO OR MORE at once (an
-- un-isolated tie, e.g. a bus-tie relay left closed with both sides live,
-- or a single "gate"-role node whose two real-world terminals are fed by
-- different sources while it's open — see model/solver.lua's own comment)
-- first asks whether a learned/locked attribution rule actually covers
-- this exact combination (_attributionRuleWinner) — evidence straight
-- from a painted snapshot beats a structural assumption. Only when no
-- rule covers it does this fall back to picking the single highest-
-- voltage contributor's color outright, as long as every contributor's
-- voltage is actually known — a real higher-voltage source would
-- genuinely dominate/back-feed a lower one, though this is exactly the
-- assumption that can be WRONG for the single-shared-node case above
-- (see _aiColorAttributionConfidence, which scores this fallback as
-- unconfident for precisely that reason). A tie in voltage is never
-- ambiguous on its own: equal voltages already resolve to the identical
-- registered color. Only when some contributor's voltage is UNSET does
-- this stay genuinely unknowable — that source's real color can't be
-- derived, so this returns every contributor's color as a SEQUENCE
-- instead of a single color — the caller threads this through
-- applySolvedColors as-is, and the draw functions render a sequence as an
-- alternating dash pattern rather than a flat fill, precisely because
-- there's no principled single answer.
local function _colorForPoweredNode(nodeId, attribution, canvas, defaultColor, nodeStates)
    nodeStates = nodeStates or {}
    local contributingIds = attribution[nodeId]
    if not contributingIds or next(contributingIds) == nil then return defaultColor end

    local sortedIds = {}
    for id in pairs(contributingIds) do table.insert(sortedIds, id) end
    table.sort(sortedIds)

    if #sortedIds == 1 then
        local entity = _findSourceEntity(canvas, sortedIds[1])
        return _colorForVoltage(canvas, entity and entity.voltage, defaultColor)
    end

    local winnerId = _attributionRuleWinner(canvas, nodeId, nodeStates)
    if winnerId then
        local entity = _findSourceEntity(canvas, winnerId)
        return _colorForVoltage(canvas, entity and entity.voltage, defaultColor)
    end

    local colors, allHaveVoltage, maxVoltage = {}, true, -math.huge
    for _, id in ipairs(sortedIds) do
        local entity = _findSourceEntity(canvas, id)
        local voltage = entity and entity.voltage
        table.insert(colors, _colorForVoltage(canvas, voltage, defaultColor))
        if not voltage then
            allHaveVoltage = false
        elseif voltage > maxVoltage then
            maxVoltage = voltage
        end
    end

    if allHaveVoltage then return _colorForVoltage(canvas, maxVoltage, defaultColor) end

    return colors -- a sequence (length 2+) -- see this function's own comment
end

local function _solveCurrentSchematic()
    local canvas = _findSchematicCanvas()
    if not canvas then return nil end
    local componentTypes = _buildComponentTypeMap(canvas)
    if next(componentTypes) == nil then return nil end
    local medium = _currentMedium()

    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local gateStates = _currentGateStates(canvas, componentTypes)

    -- A "gate"-role node the user operates directly (gateStates already
    -- has an entry for it, via _currentGateStates) is ALWAYS passed to
    -- solveWithRules as a lockedGateStates entry — a user's own switch
    -- position is ground truth, never second-guessed by a learned rule,
    -- even if one happens to exist for that same id. Only a gate with NO
    -- direct user control (a relay/element-kind gate — see canvas.rules'
    -- own comment above _recomputeGateRules) is left for its rule, if any,
    -- to decide every iteration. Plain solve() is still used whenever no
    -- rule exists at all yet (canvas.rules empty) — same Phase 1 behavior,
    -- unchanged, until there's actually something for Phase 4 to feed back.
    local nodeStates
    local oscillatingIds = {}
    -- Every gate's FINAL open/closed position (direct control positions,
    -- same as gateStates, plus whatever a rule decided for a relay) — kept
    -- separately from gateStates itself since a relay's entry only exists
    -- on solveWithRules' own result, not on the plain lockedGateStates this
    -- function passes in. Used below by the wire loop's open-gate anchor
    -- check, which needs EVERY gate's real position, not just the
    -- directly-controlled ones.
    local finalGateStates = gateStates
    if canvas.rules and next(canvas.rules) ~= nil then
        local rulesByGate = {}
        for gateId, rule in pairs(canvas.rules) do
            if rule and (rule.status == "learned" or rule.status == "locked") and not gateStates[gateId] then
                rulesByGate[gateId] = rule
            end
        end
        local result = ModelSolver.solveWithRules(graph, sourceStates, gateStates, rulesByGate)
        nodeStates = result.nodeStates
        finalGateStates = result.gateStates
        if not result.converged then
            for _, id in ipairs(result.oscillating) do oscillatingIds[id] = true end
        end
    else
        nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
    end

    -- Which active source(s) actually reach each powered node — see
    -- _colorForPoweredNode's own comment. Purely a display/coloring
    -- concern layered on top of nodeStates above, never consulted by the
    -- logical powered/unpowered vocabulary itself (deduction, rule
    -- learning, solveWithRules' own feedback loop are all untouched by
    -- this — a node is still simply "powered" or "unpowered" to all of
    -- them, exactly as before per-source colors existed).
    local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)

    -- A node with no settled answer (see oscillatingIds above) is left out
    -- entirely — resolveColor falls through to that entity's own flat
    -- defaultColor tier rather than painting an arbitrary guess for a gate
    -- Phase 4 couldn't actually resolve.
    local result = { elements = {}, wires = {}, controls = {} }
    for _, e in ipairs(canvas.elements) do
        local state = nodeStates[e.id]
        if state and not oscillatingIds[e.id] then
            result.elements[e.id] = state == ModelSolver.POWERED
                and _colorForPoweredNode(e.id, attribution, canvas, medium.style.powered, nodeStates)
                or medium.style.unpowered
        end
    end
    for _, c in ipairs(canvas.controls) do
        local state = nodeStates[c.id]
        if state and not oscillatingIds[c.id] then
            -- A "gate"-role control (SWITCH, ...) in its OPEN position, or a
            -- "source"-role control (GENERATOR, ...) that's switched OFF,
            -- always reads as the flat unpowered gray, even though solve()
            -- itself still marks it POWERED when its input terminal is
            -- genuinely hot (see solver.lua's own comment — that's correct
            -- physics, kept for the logical powered/unpowered vocabulary
            -- deduction/rule-learning reason over). This is purely the
            -- display override: an open switch's/off generator's own body
            -- shows its own OFF state, not whatever's live on the wire
            -- feeding it: ON/CLOSED still takes its color from the
            -- highest-voltage source reaching it, same as any other
            -- powered node, via _colorForPoweredNode below.
            local isOpenGate = componentTypes[c.id] == "gate" and not _isActivePosition(c)
            local isOffSource = componentTypes[c.id] == "source" and not sourceStates[c.id]
            result.controls[c.id] = (state == ModelSolver.POWERED and not isOpenGate and not isOffSource)
                and _colorForPoweredNode(c.id, attribution, canvas, medium.style.powered, nodeStates)
                or medium.style.unpowered
        end
    end
    -- A wire's predicted color is a conservative "both ends powered"
    -- approximation, not a true per-edge flow trace (solve() only reports
    -- per-node reachability, not which edge actually carried the power to
    -- a node reachable several ways) — it's enough to show power stopping
    -- exactly at an open gate or an unreached branch, which is all Phase 1
    -- needs to prove. Colored off the FROM end's own attribution (what's
    -- leaving that end), same approximation in spirit — not a true
    -- per-edge trace either, just "which color this wire would carry if
    -- it's actually conducting right now" — EXCEPT when the FROM end is
    -- itself an OPEN gate and the TO end isn't: an open gate is exactly
    -- the "single node whose two real-world terminals are fed by
    -- different sources" case _isGenuinelyColorAmbiguous's own comment
    -- flags (e.g. a generator feeding the gate's near side while the far
    -- side is independently backfed from a bus on the other side of the
    -- very contact that's open) — the gate's OWN attributed color can be
    -- the WRONG side's source entirely for THIS specific wire, whereas the
    -- non-gate end's attribution is never affected by whether this one
    -- edge conducts. Anchoring off that end instead is still the same
    -- approximation, just picking whichever end it's actually accurate
    -- for.
    --
    -- A wire touching a "directionalGate" node (DIODE, DPST SWITCH) is a
    -- DIFFERENT case from the open-gate one above, not an extension of
    -- it: the gate's own graph node is a single powered/unpowered value
    -- that can't represent its two real-world leads being at DIFFERENT
    -- states at once -- exactly the normal case for a reverse-biased
    -- diode (cathode lead hot off a live bus, anode lead cold because the
    -- diode is correctly blocking that bus from backfeeding through it).
    -- Requiring BOTH ends powered off that single shared value, same as
    -- every ordinary wire, would leave the cathode-side wire gray even
    -- though the bus it's directly, un-gatedly wired to is live. So
    -- instead: this wire's hotness and color are taken ENTIRELY from its
    -- own non-gate endpoint's own state/attribution (never the gate
    -- node's) -- correct for either leg, since solve()'s own forward-only
    -- traversal (model/solver.lua) already guarantees an entry/anode-side
    -- neighbor only reads powered when something is actually feeding IN,
    -- and an exit/cathode-side neighbor only reads powered when something
    -- is actually live on it (independently or fed forward through the
    -- gate) -- this is just trusting that neighbor's own already-correct
    -- answer instead of re-deriving it through the lossy single-node
    -- diode value.
    for _, w in ipairs(canvas.wires) do
        local fromIsDirectionalGate = componentTypes[w.fromElementId] == "directionalGate"
        local toIsDirectionalGate = componentTypes[w.toElementId] == "directionalGate"
        if fromIsDirectionalGate or toIsDirectionalGate then
            local otherId = fromIsDirectionalGate and w.toElementId or w.fromElementId
            local otherState = nodeStates[otherId]
            if otherState and not oscillatingIds[otherId] then
                result.wires[w.id] = (otherState == ModelSolver.POWERED)
                    and _colorForPoweredNode(otherId, attribution, canvas, medium.style.powered, nodeStates)
                    or medium.style.unpowered
            end
        else
            local fromState, toState = nodeStates[w.fromElementId], nodeStates[w.toElementId]
            if fromState and toState and not oscillatingIds[w.fromElementId] and not oscillatingIds[w.toElementId] then
                if fromState == ModelSolver.POWERED and toState == ModelSolver.POWERED then
                    local fromIsOpenGate = componentTypes[w.fromElementId] == "gate" and finalGateStates[w.fromElementId] ~= "closed"
                    local toIsOpenGate = componentTypes[w.toElementId] == "gate" and finalGateStates[w.toElementId] ~= "closed"
                    local anchorId = (fromIsOpenGate and not toIsOpenGate) and w.toElementId or w.fromElementId
                    result.wires[w.id] = _colorForPoweredNode(anchorId, attribution, canvas, medium.style.powered, nodeStates)
                else
                    result.wires[w.id] = medium.style.unpowered
                end
            end
        end
    end
    return result
end

-- Re-solves and re-applies predicted colors for whatever combination
-- mainCanvas is currently on — called once after a system loads, and after
-- PREV/NEXT lands on a combination with no captured snapshot (see
-- schematicCombPrevPressed/NextPressed below). Safe to call even when
-- there's nothing to solve (_solveCurrentSchematic returns nil) or when a
-- snapshot already covers this combination — applySolvedColors only ever
-- writes the predictedColor tier, which resolveColor consults strictly
-- below an authored snapshot, so this can't override one.
local function _applySolvedColorsToCurrentCombination()
    gdsGui_schematic_applySolvedColors("mainCanvas", _solveCurrentSchematic())
end

-- Forward-declared (defined/assigned below, near _recomputeGateRules/
-- _recomputeAttributionRules) purely so schematicCanvasChanged just below
-- can call it — a plain "local function" there would textually postdate
-- this point, putting it out of lexical scope for THIS closure specifically
-- (globals don't care about definition order, but this is a local upvalue).
-- Same single-local cost either way, just split across two statements.
local _recomputeDeducedGateStates

-- Resolved by name via _G[...] from gdsGui_schematic's _notifyChanged, the
-- same string-callback pattern used for buttons/scrollbars elsewhere in this
-- app. mainCanvas.onChange is wired to this name in love.load() — fires on
-- every discrete design-mode edit (drag committed, element/wire/control
-- added/deleted/renamed, color picked, etc.), so this is the single hot-path
-- source of _schematicDirty. Defined here (rather than back where
-- _schematicDirty/_requestSchematicSave live) specifically so
-- _applySolvedColorsToCurrentCombination is already in lexical scope —
-- schematicCanvasChanged is a global (resolved by name, so WHERE it's
-- defined never matters for callers), but the identifiers inside its own
-- body still resolve lexically at parse time, same as any other function.
function schematicCanvasChanged()
    -- A design-mode edit (wire drawn, element/control added, componentType
    -- changed via a re-placement, etc.) can change what the graph itself
    -- looks like, not just a control's position — the per-frame poll in
    -- love.update() only re-solves on a control id/detentIndex/numDetents
    -- change (see _schematicCombControlsChanged), which misses a wire or
    -- element being added/removed with every control left untouched. This
    -- is the one hook that already fires for every such edit, so it's the
    -- right place to also keep predicted colors in sync — safe to call even
    -- when there's nothing to solve yet (see _applySolvedColorsToCurrentCombination).
    _applySolvedColorsToCurrentCombination()
    -- The AI panel's confidence score is driven by canvas.rules/
    -- attributionRules, which are only ever rebuilt by
    -- _recomputeDeducedGateStates (see its own comment) — without this
    -- call here, adding/removing an element/control/wire left every
    -- existing rule's confidence stale (still scored off evidence that,
    -- for a structural edit, was just invalidated — element/wire/control
    -- deletion also wipes canvas.snapshots outright, see e.g.
    -- gdsGui_schematic_internal_onElementEditChosen's DELETE branch).
    _recomputeDeducedGateStates()
    _requestSchematicSave()
end

-- True if ANY element/control on canvasName is currently showing a
-- predictedColor rather than an authored snapshot or flat default (see
-- gdsGui_schematic_isColorPredicted) — i.e. the combination readout's
-- "(predicted)" suffix (Phase 5, see the love.update() poll below) should
-- show. Only meaningful when the combination has no exact snapshot of its
-- own (resolveColor's tier 1/2 always win over tier 2.5 anyway), but cheap
-- enough to just check outright rather than duplicate that tier logic here.
local function _currentCombinationHasPredictedColor(canvasName, signature)
    local canvas = _findSchematicCanvas()
    if not canvas then return false end
    for _, e in ipairs(canvas.elements) do
        if gdsGui_schematic_isColorPredicted(canvasName, "element", e.id, signature) then return true end
    end
    for _, c in ipairs(canvas.controls) do
        if gdsGui_schematic_isColorPredicted(canvasName, "control", c.id, signature) then return true end
    end
    return false
end

-- Reverse-maps one snapshot's painted colors back into {id -> "powered"|
-- "unpowered"} for every graph node, via an exact-match lookup against the
-- CURRENT medium's own style -- the same colors _solveCurrentSchematic
-- writes forward. A color that doesn't exactly match either style entry (a
-- manual pick that isn't flat gray/yellow) simply has no entry, same as a
-- node the snapshot's buckets never mention -- model/learner.lua's
-- inferGate already treats a missing/unmatched state as no evidence
-- rather than guessing.
local function _stateForColor(color)
    if not color then return nil end
    for state, styleColor in pairs(_currentMedium().style) do
        if color[1] == styleColor[1] and color[2] == styleColor[2]
           and color[3] == styleColor[3] and color[4] == styleColor[4] then
            return state
        end
    end
    return nil
end

local function _snapshotToNodeStates(snapshot, graph)
    local nodeStates = {}
    for id in pairs(graph.nodes) do
        local color = (snapshot.elements and snapshot.elements[id]) or (snapshot.controls and snapshot.controls[id])
        local state = _stateForColor(color)
        if state then nodeStates[id] = state end
    end
    return nodeStates
end

-- Reconstructs ONE already-captured snapshot's own gateStates/sourceStates
-- straight off its signature key (gdsGui_schematic_parseSignature) rather
-- than canvas.controls' CURRENT detentIndex, which may have moved on
-- since this snapshot was taken. Unlike a relay's open/closed position
-- (which model/learner.lua's inferGate has to deduce from context because
-- nothing records it directly), every control's position at capture time
-- IS recorded, in the signature itself -- no deduction needed here, just
-- parsing. A control missing from the signature (added to the schematic
-- after this snapshot was captured) falls back to solve()'s own safe
-- default (open/off), same as a gate with no gateStates entry at all.
local function _pastGateAndSourceStates(canvas, graph, signature)
    local detentById = gdsGui_schematic_parseSignature(signature)
    local controlById = {}
    for _, c in ipairs(canvas.controls) do controlById[c.id] = c end

    local gateStates, sourceStates = {}, {}
    for id, node in pairs(graph.nodes) do
        if node.role == "gate" or node.role == "source" then
            local control = controlById[id]
            if control then
                local detentIndex = detentById[id]
                local isActive = detentIndex ~= nil
                    and _isActivePosition({ positions = control.positions, detentIndex = detentIndex })
                if node.role == "gate" then
                    gateStates[id] = isActive and "closed" or "open"
                else
                    sourceStates[id] = isActive or false
                end
            elseif node.role == "source" then
                sourceStates[id] = true -- element-kind source: always on when present, same as _currentSourceStates
            end
        end
    end
    return gateStates, sourceStates
end

-- For one already-captured snapshot, re-solves source attribution under
-- THAT snapshot's own combination (_pastGateAndSourceStates above), then
-- for every node GENUINELY ambiguous there (_isGenuinelyColorAmbiguous —
-- a node merely tied at its top voltage isn't worth a word: the painted
-- color would match every tied contributor's identical registered color
-- at once, correctly skipped below as inconclusive, so there's nothing
-- real to learn from it), checks whether the snapshot's own painted color
-- exactly matches exactly one contributor's registered voltage color
-- (canvas.voltageColors, via that source's own .voltage — see
-- _colorForVoltage). An exact, UNIQUE match is a positive "this source
-- actually explains this node" example; no match, or a match shared by
-- two or more contributors that happen to share the same registered
-- color, is inconclusive and skipped — same "never guess" discipline
-- model/learner.lua's own _tryConditionSet contradiction handling follows
-- for gate rules.
-- Returns {nodeId -> sourceId} for this one snapshot.
local function _deduceAttributionWinnersForSnapshot(canvas, graph, signature, snapshot)
    local gateStates, sourceStates = _pastGateAndSourceStates(canvas, graph, signature)
    local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)

    local winners = {}
    for nodeId, contributingIds in pairs(attribution) do
        if _isGenuinelyColorAmbiguous(canvas, contributingIds) then
            local paintedColor = (snapshot.elements and snapshot.elements[nodeId]) or (snapshot.controls and snapshot.controls[nodeId])
            if paintedColor then
                local matchedId, matchCount = nil, 0
                for id in pairs(contributingIds) do
                    local entity = _findSourceEntity(canvas, id)
                    local color = entity and entity.voltage and canvas.voltageColors and canvas.voltageColors[entity.voltage]
                    if color and color[1] == paintedColor[1] and color[2] == paintedColor[2]
                       and color[3] == paintedColor[3] and (color[4] or 1) == (paintedColor[4] or 1) then
                        matchedId, matchCount = id, matchCount + 1
                    end
                end
                if matchCount == 1 then winners[nodeId] = matchedId end
            end
        end
    end
    return winners
end

-- Deduced gate states (open/closed/unknown), per already-captured snapshot
-- signature -- keyed off each snapshot's OWN painted colors via
-- model/learner.lua's inferGate, not off whatever control the app thinks
-- drives the gate (contrast _currentGateStates above, which only knows
-- about a gate the user operates directly). This is what will eventually
-- let a relay nothing in the UI sets directly still get a learned rule
-- (Phase 3). Purely a derived, in-memory cache -- never a system-record
-- field, never persisted (recomputing from the snapshots that are already
-- saved is cheap and avoids yet another JSON-export gap, see the plan's
-- "persist deduced gate states?" open question) -- rebuilt wholesale by
-- _recomputeDeducedGateStates after every snapshot commit and after a
-- system loads.
local _deducedGateStatesBySignature = {}

-- canvas.rules[gateId] = a model/learner.lua rule table (see
-- findSimplestRule), or {status="noRule"} -- always an explicit entry for
-- every "gate"-role node, same "never omit, always say what's known"
-- convention as _deducedGateStatesBySignature above. A rule the user has
-- LOCKED (Phase 5's eventual confirm/lock action -- see _lockGateRule
-- below) is the one entry this never overwrites: relearning only ever
-- replaces a rule the learner itself produced, never one a person
-- confirmed. Unlike _deducedGateStatesBySignature, canvas.rules IS
-- persisted (sys.rules, see _captureCurrentSystemFromCanvas/
-- _openSystemIntoCanvas) -- a lock is a user decision, not something
-- cheaply re-derivable from the snapshots alone.
--
-- Builds each gate's training examples from every captured snapshot whose
-- deduced state for that gate isn't "unknown" (see
-- _deducedGateStatesBySignature), paired with that same snapshot's own
-- painted node states as the pool of candidate explanatory conditions
-- (every other graph node, sorted by id for a deterministic candidate
-- order -- sense-linked-first ordering per the plan's R4 is a seam left
-- for whenever that optional feature is actually built, not wired here).
local function _recomputeGateRules(canvas, graph)
    canvas.rules = canvas.rules or {}

    local examplesByGate = {}
    for signature, snapshot in pairs(canvas.snapshots) do
        local gateStates = _deducedGateStatesBySignature[signature]
        if gateStates then
            local nodeStates = _snapshotToNodeStates(snapshot, graph)
            for gateId, state in pairs(gateStates) do
                if state ~= ModelLearner.UNKNOWN then
                    examplesByGate[gateId] = examplesByGate[gateId] or {}
                    table.insert(examplesByGate[gateId], { nodeStates = nodeStates, result = state })
                end
            end
        end
    end

    for id, node in pairs(graph.nodes) do
        if node.role == "gate" then
            local existing = canvas.rules[id]
            if not (existing and existing.status == "locked") then
                local candidateIds = {}
                for otherId in pairs(graph.nodes) do
                    if otherId ~= id then table.insert(candidateIds, otherId) end
                end
                table.sort(candidateIds)
                canvas.rules[id] = ModelLearner.findSimplestRule(id, examplesByGate[id] or {}, candidateIds)
            end
        end
    end
end

-- Confirms a gate's current rule as user-verified, so future relearning
-- (_recomputeGateRules above) never touches it again. No-op if the gate
-- has no learned rule yet (nothing to lock) — mirrors _recomputeGateRules'
-- own skip condition exactly, so a caller can't lock a rule that wasn't
-- actually "learned".
local function _lockGateRule(canvas, gateId)
    local rule = canvas.rules and canvas.rules[gateId]
    if rule and rule.status == "learned" then rule.status = "locked" end
end

-- canvas.attributionRules[nodeId] = a model/learner.lua attribution rule
-- (see findAttributionRule), or {status="noRule"} — same "always an
-- explicit entry for every node that's ever shown up ambiguous, never
-- touch a LOCKED one" shape as canvas.rules just above, just keyed by
-- ambiguous node instead of by gate, and sourced from
-- _deduceAttributionWinnersForSnapshot instead of inferGate. Also
-- persisted (sys.attributionRules — see _captureCurrentSystemFromCanvas/
-- _openSystemIntoCanvas) for the same reason: a lock is a user decision.
--
-- Also rebuilds canvas.voltageDominanceRule alongside the per-node table
-- above — the GLOBAL counterpart (model/learner.lua's
-- findVoltageDominanceRule): not keyed by node id at all, since it's
-- testing one single system-wide hypothesis ("the highest-voltage
-- contributor always wins") rather than learning a per-node mapping.
-- Folded into this same function (rather than its own top-level local)
-- purely to stay under this file's 200-local ceiling; it draws from the
-- exact same per-snapshot `winners` this function already computes, just
-- pooling every node's evidence together instead of splitting it out by
-- id, paired with whether that winner was the single highest-voltage
-- contributor's own pick (nil when that pick isn't well-defined — some
-- contributor has no registered voltage, or the top voltage is tied
-- across 2+ of them, same conditions _isGenuinelyColorAmbiguous's own
-- "not allHaveVoltage"/"maxCount==1" checks test — every such case has no
-- single "the heuristic's pick" to compare the winner against at all, so
-- isn't informative about the global hypothesis either way). Purely a
-- derived, in-memory value, same as _deducedGateStatesBySignature's own
-- "cheap enough to just rebuild wholesale, never persisted" reasoning,
-- and never locked — there's no per-node rule to protect from relearning
-- here, just one yes/no hypothesis that either keeps holding or doesn't.
local function _recomputeAttributionRules(canvas, graph)
    canvas.attributionRules = canvas.attributionRules or {}

    local function singleHighestVoltageContributor(contributingIds)
        local highestId, highestVoltage, maxCount, allHaveVoltage = nil, -math.huge, 0, true
        for id in pairs(contributingIds) do
            local entity = _findSourceEntity(canvas, id)
            local voltage = entity and entity.voltage
            if not voltage then
                allHaveVoltage = false
            elseif voltage > highestVoltage then
                highestId, highestVoltage, maxCount = id, voltage, 1
            elseif voltage == highestVoltage then
                maxCount = maxCount + 1
            end
        end
        if not allHaveVoltage or maxCount ~= 1 then return nil end
        return highestId
    end

    local examplesByNode = {}
    local dominanceExamples = {}
    local confirmedDominanceSignatures = {}
    for signature, snapshot in pairs(canvas.snapshots) do
        local winners = _deduceAttributionWinnersForSnapshot(canvas, graph, signature, snapshot)
        if next(winners) ~= nil then
            local nodeStates = _snapshotToNodeStates(snapshot, graph)
            local gateStates, sourceStates = _pastGateAndSourceStates(canvas, graph, signature)
            local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)

            -- One dominance example per SNAPSHOT, not per (node, snapshot)
            -- pair — every ambiguous node this one snapshot resolves a
            -- winner for is typically the SAME single real-world event
            -- (one generator backfeeding one bus) seen from several
            -- vantage points at once (a bus, the battery it backfeeds, the
            -- switch between them...), not independent confirmations.
            -- Counting each vantage point as its own example let a single
            -- busy capture saturate _AI_CONFIDENT_EXAMPLE_COUNT outright,
            -- reporting system-wide 100% certainty off one combination —
            -- collapsing them to one boolean per snapshot (AND across its
            -- own nodes: any contradiction anywhere in it voids the whole
            -- snapshot's vote) requires that many SEPARATE combinations be
            -- captured before the global rule can saturate, same
            -- discipline examplesByNode below already applies per node id.
            local sawConfirmed, sawContradicted = false, false
            for nodeId, sourceId in pairs(winners) do
                examplesByNode[nodeId] = examplesByNode[nodeId] or {}
                table.insert(examplesByNode[nodeId], { nodeStates = nodeStates, result = sourceId })

                local highestId = singleHighestVoltageContributor(attribution[nodeId])
                if highestId then
                    if sourceId == highestId then sawConfirmed = true else sawContradicted = true end
                end
            end
            if sawContradicted then
                table.insert(dominanceExamples, false)
            elseif sawConfirmed then
                table.insert(dominanceExamples, true)
                table.insert(confirmedDominanceSignatures, signature)
            end
        end
    end

    -- teachableTotal: every combination in the ENTIRE combination space
    -- (captured or not) where the global hypothesis is even testable at
    -- all — at least one node is genuinely ambiguous
    -- (_isGenuinelyColorAmbiguous) AND not forced to a flat, unattributed
    -- display (an open gate's or off source's own body always shows plain
    -- gray regardless of attribution — see _aiColorAttributionConfidence's
    -- own short-circuits — so painting one of those never actually
    -- asserts a color there is anything to learn from). Brute-force
    -- enumerated — the app's own COMBINATION: X/Y counter already assumes
    -- this whole space is small enough for a human to step through one at
    -- a time, so it's small enough to walk here too — only on a recompute
    -- (snapshot capture/system load), never per frame. Lets
    -- _aiColorAttributionConfidence turn exampleCount into a fraction of
    -- every OTHER combination that could have confirmed or refuted this
    -- exact hypothesis, rather than against an arbitrary fixed constant —
    -- see its own comment.
    local function teachableCombosTotal()
        local sortedIds, numDetentsById = {}, {}
        for _, c in ipairs(canvas.controls) do
            table.insert(sortedIds, c.id)
            numDetentsById[c.id] = c.numDetents
        end
        local componentTypes = {}
        for id, node in pairs(graph.nodes) do componentTypes[id] = node.role end

        local detents = {}
        for _, id in ipairs(sortedIds) do detents[id] = 0 end
        local total = 0
        while true do
            local gateStates, sourceStates = _gateAndSourceStatesForDetents(canvas, componentTypes, detents)
            local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
            local teachable = false
            for nodeId, contributingIds in pairs(attribution) do
                if _isGenuinelyColorAmbiguous(canvas, contributingIds) then
                    local role = graph.nodes[nodeId].role
                    local isOpenGate = role == "gate" and gateStates[nodeId] ~= "closed"
                    local isOffSource = role == "source" and not sourceStates[nodeId]
                    if not isOpenGate and not isOffSource then
                        teachable = true
                        break
                    end
                end
            end
            if teachable then total = total + 1 end

            local i = #sortedIds
            while i >= 1 do
                local id = sortedIds[i]
                detents[id] = detents[id] + 1
                if detents[id] < numDetentsById[id] then break end
                detents[id] = 0
                i = i - 1
            end
            if i == 0 then break end
        end
        return total
    end

    canvas.voltageDominanceRule = ModelLearner.findVoltageDominanceRule(dominanceExamples)
    canvas.voltageDominanceRule.teachableTotal = teachableCombosTotal()
    -- Which captured combinations actually backed a "learned" verdict, by
    -- signature (converted to a combination NUMBER only at display time —
    -- _combinationIndexForDetents isn't in scope yet this early in the
    -- file) — so the AI panel can name them instead of just saying
    -- "confirmed elsewhere".
    canvas.voltageDominanceRule.confirmedSignatures = confirmedDominanceSignatures

    for nodeId, examples in pairs(examplesByNode) do
        local existing = canvas.attributionRules[nodeId]
        if not (existing and existing.status == "locked") then
            local candidateIds = {}
            for otherId in pairs(graph.nodes) do
                if otherId ~= nodeId then table.insert(candidateIds, otherId) end
            end
            table.sort(candidateIds)
            canvas.attributionRules[nodeId] = ModelLearner.findAttributionRule(examples, candidateIds)
        end
    end
    -- Prune entries for a node no longer in the graph at all (its element/
    -- control was deleted) — same spirit as the library's own
    -- _pruneUnreachableSnapshots, just for this table. A node that's
    -- simply stopped being ambiguous (circuit edited, still exists) keeps
    -- its stale rule rather than being pruned — harmless dead weight,
    -- since _attributionRuleWinner is only ever consulted for a node that
    -- IS currently ambiguous.
    for nodeId in pairs(canvas.attributionRules) do
        if not graph.nodes[nodeId] then canvas.attributionRules[nodeId] = nil end
    end
end

-- Confirms an ambiguous node's current attribution rule as user-verified
-- — same shape/reasoning as _lockGateRule above.
local function _lockAttributionRule(canvas, nodeId)
    local rule = canvas.attributionRules and canvas.attributionRules[nodeId]
    if rule and rule.status == "learned" then rule.status = "locked" end
end

-- True if rule is LOCKED and its verdict disagrees with deducedState (the
-- gate's actual position per THIS snapshot's own painted colors — see
-- model/learner.lua's inferGate). A merely "learned" (not yet confirmed)
-- rule never contradicts anything here — relearning already absorbs new
-- evidence for those every time (_recomputeGateRules); only a LOCKED rule
-- is a standing claim a fresh paint can actually break.
local function _ruleContradictsDeducedState(rule, nodeStates, deducedState)
    if not rule or rule.status ~= "locked" then return false end
    if deducedState == ModelLearner.UNKNOWN then return false end
    local matches = true
    for _, conditionId in ipairs(rule.conditionIds) do
        if nodeStates[conditionId] ~= rule.conditionStates[conditionId] then matches = false; break end
    end
    local predicted = (matches and rule.resultState == "closed") and "closed" or "open"
    return predicted ~= deducedState
end

-- Checked right after a snapshot commit (see captureSchematicSnapshot/
-- schematicSnapshotConflictResolved) — this is Phase 5's "contradiction
-- flagging": a fresh paint for a combination can reveal that a gate's
-- LOCKED rule (a user-confirmed claim, never silently relearned — see
-- _recomputeGateRules) no longer actually holds. Returns the first broken
-- gate's id, or nil if nothing contradicts.
local function _findLockedRuleContradiction(canvas, graph, signature)
    local snapshot = canvas.snapshots[signature]
    local deducedStates = _deducedGateStatesBySignature[signature]
    if not snapshot or not deducedStates then return nil end
    local nodeStates = _snapshotToNodeStates(snapshot, graph)
    for gateId, rule in pairs(canvas.rules or {}) do
        if _ruleContradictsDeducedState(rule, nodeStates, deducedStates[gateId]) then return gateId end
    end
    return nil
end

-- Shared by both snapshot-commit sites below: re-finds a contradiction
-- against a LOCKED rule for whatever combination mainCanvas is now showing,
-- and surfaces it as a one-shot informational notice (never blocking the
-- commit itself — the paint already happened; this only tells the user
-- their locked rule's claim just got disproven, so they can revisit it via
-- DESIGN ACTIONS > GATE RULES).
local function _flagLockedRuleContradictionIfAny(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local componentTypes = _buildComponentTypeMap(canvas)
    if next(componentTypes) == nil then return end
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local signature = gdsGui_schematic_computeSignature(canvasName)
    local brokenGateId = _findLockedRuleContradiction(canvas, graph, signature)
    if brokenGateId then
        local labelsById = _labelsByIdForCanvas(canvas)
        gdsGui_schematic_openMenu(canvasName,
            "This paint contradicts the locked rule for " .. (labelsById[brokenGateId] or brokenGateId) .. ".",
            { "OK" }, "schematicRuleContradictionDismissed", nil)
    end
end

-- Plain-English description of one gate's rule, e.g. "G1 is closed when
-- BUS A is powered" — reusing each referenced node's own display label
-- (falling back to its bare id when no label is known) so this reads
-- using the same names already painted on the schematic, not internal
-- ids. Pure/testable on its own: takes plain lookup tables, never touches
-- canvas/globApp directly (see _labelsByIdForCanvas below for the
-- live-canvas adapter that builds labelsById).
local function _formatRuleText(gateId, rule, labelsById)
    labelsById = labelsById or {}
    local function labelFor(id) return labelsById[id] or id end
    if not rule or (rule.status ~= "learned" and rule.status ~= "locked") then
        return labelFor(gateId) .. ": no rule learned yet"
    end
    local clauses = {}
    for _, conditionId in ipairs(rule.conditionIds) do
        table.insert(clauses, labelFor(conditionId) .. " is " .. rule.conditionStates[conditionId])
    end
    return labelFor(gateId) .. " is " .. rule.resultState .. " when " .. table.concat(clauses, " and ")
end

-- Plain-English description of one ambiguous node's attribution rule —
-- same shape/reasoning as _formatRuleText above, except the rule's
-- vocabulary is an explicit condition-state -> winner MAPPING rather than
-- a single clause (see model/learner.lua's findAttributionRule), so every
-- entry in the mapping becomes its own clause, e.g. "BUS_1 is powered ->
-- GENR_1; BUS_1 is unpowered -> BATT_2". Each mapping key is the same
-- "state1|state2|..." format model/learner.lua's buildConditionKey
-- produces, aligned positionally with rule.conditionIds.
local function _formatAttributionRuleText(nodeId, rule, labelsById)
    labelsById = labelsById or {}
    local function labelFor(id) return labelsById[id] or id end
    if not rule or (rule.status ~= "learned" and rule.status ~= "locked") then
        return labelFor(nodeId) .. ": no rule learned yet (defaults to the highest-voltage contributor)"
    end
    local clauses = {}
    for key, winnerId in pairs(rule.mapping) do
        local parts, i = {}, 1
        for state in (key .. "|"):gmatch("([^|]*)|") do
            table.insert(parts, labelFor(rule.conditionIds[i]) .. " is " .. state)
            i = i + 1
        end
        table.insert(clauses, table.concat(parts, " and ") .. " -> " .. labelFor(winnerId))
    end
    table.sort(clauses)
    return labelFor(nodeId) .. ": " .. table.concat(clauses, "; ")
end

-- Live-canvas adapter for _formatRuleText above: every element/control's
-- own .label, keyed by id.
local function _labelsByIdForCanvas(canvas)
    local labelsById = {}
    for _, e in ipairs(canvas.elements) do labelsById[e.id] = e.label end
    for _, c in ipairs(canvas.controls) do labelsById[c.id] = c.label end
    return labelsById
end

-- Deterministic (sorted) id order for every "source"-role node, same
-- "stable row-to-id mapping without stashing the list" convention as
-- _sortedGateIds below.
local function _sortedSourceIds(canvas)
    local componentTypes = _buildComponentTypeMap(canvas)
    local sourceIds = {}
    for id, role in pairs(componentTypes) do
        if role == "source" then table.insert(sourceIds, id) end
    end
    table.sort(sourceIds)
    return sourceIds
end

function _recomputeDeducedGateStates()
    _deducedGateStatesBySignature = {}
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local componentTypes = _buildComponentTypeMap(canvas)
    if next(componentTypes) == nil then return end
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    for signature, snapshot in pairs(canvas.snapshots) do
        local nodeStates = _snapshotToNodeStates(snapshot, graph)
        _deducedGateStatesBySignature[signature] = ModelLearner.deduceAllGates(graph, nodeStates)
    end
    _recomputeGateRules(canvas, graph)
    _recomputeAttributionRules(canvas, graph) -- also rebuilds canvas.voltageDominanceRule, see its own comment
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — AI INFO PANEL: a read-only overlay (schematicAiBtn,
-- just below ANNUNCIATOR) surfacing three things about the inference
-- engine's current state for whichever system is open:
--   COMBINATION         -- which control-position combination is showing
--                          now (same counter as schematicCombLabel).
--   PREDICTION CONFIDENCE -- how much to trust the colors currently
--                          shown. 100% only when the current combination
--                          has an exact authored snapshot (ground truth,
--                          nothing inferred at all); otherwise the
--                          average, over every "thing this combination
--                          had to guess rather than read off directly",
--                          of: _aiGateConfidence (one per rule-governed
--                          gate — did we have to infer its open/closed
--                          position?) and _aiColorAttributionConfidence
--                          (one per powered element/control — did we have
--                          to pick a winner among 2+ sources reaching it
--                          at once, rather than there being exactly one
--                          unambiguous explanation?). Both matter: a
--                          system with every gate directly user-operated
--                          (nothing to infer there) can still show a
--                          wrong, low-confidence color purely from the
--                          second factor — see _aiColorAttributionConfidence's
--                          own comment for a concrete case.
--   SNAPSHOT IMPORTANCE -- of every snapshot captured on this system, what
--                          fraction actually taught the engine anything
--                          (contributed a non-"unknown" deduced state for
--                          at least one gate — see
--                          _deducedGateStatesBySignature) rather than
--                          being dead weight the learner can't use.
-------------------------------------------------------------------------------

-- A "learned" (not yet locked) rule's own confidence scales with how many
-- example snapshots it was learned from (model/learner.lua's
-- findSimplestRule -> rule.confidence), saturating at 100% once it has
-- this many — more agreeing examples make a coincidental fit less likely,
-- but there's no principled "correct" threshold; chosen as a reasonable,
-- reachable-in-normal-use target, not derived from anything. A gate whose
-- iterative solve never settled THIS combination (model/solver.lua's
-- solveWithRules' own "oscillating" set) has no trustworthy answer at all,
-- regardless of its rule's own history.
local _AI_CONFIDENT_EXAMPLE_COUNT = 5

local function _aiGateConfidence(rule, isOscillating)
    if isOscillating then return 0 end
    if not rule or rule.status == "noRule" then return 0 end
    if rule.status == "locked" then return 1 end
    return math.min(1, (rule.confidence or 0) / _AI_CONFIDENT_EXAMPLE_COUNT)
end

-- 1 when exactly one active source's attribution reaches nodeId (the
-- color shown there traces back to a single, unambiguous explanation, OR
-- several contributors that are tied at the top voltage anyway — see
-- _isGenuinelyColorAmbiguous, whose whole point is that a true parallel
-- tie (e.g. two 28V generators sharing a bus with a 24V battery) is NOT
-- actually at risk: the displayed color is the same regardless of which
-- tied contributor "really" explains it). For a GENUINELY ambiguous node —
-- _colorForPoweredNode's risky case, e.g. a "gate"-role node whose single
-- shared graph point blends BOTH of its real-world terminals when fed by
-- different-voltage sources (see model/solver.lua's own comment) — this
-- matches _colorForPoweredNode's OWN tier order exactly: a LOCKED
-- attribution rule that covers this combination is trusted fully (1); a
-- "learned" (not yet confirmed) one scales by its own example count, same
-- shape _aiGateConfidence uses for gate rules; no rule, or one that
-- doesn't cover this exact combination (buildConditionKey/mapping miss —
-- never seen in training), falls back to the GLOBAL voltage-dominance
-- rule (see below) and only scores a flat 0 once THAT has nothing either —
-- which is exactly the case that flagged this check's own addition: a
-- wire against an open switch's far side painted the WRONG side's
-- (higher-voltage) color with no rule yet to say otherwise. A wire's own
-- color is taken straight from its FROM node (see
-- _colorForPoweredNode's caller in _solveCurrentSchematic), so checking
-- every powered element/control node already covers every wire's
-- confidence too without a separate pass over canvas.wires.
--
-- gateStates (optional, the DIRECT per-control map from
-- _currentGateStates/_pastGateAndSourceStates — never the relay-inclusive
-- "final" one) short-circuits to 1 when nodeId is itself a currently OPEN
-- gate CONTROL: that node's own displayed color is ALWAYS the flat
-- unpowered-gray override (_solveCurrentSchematic's own isOpenGate check),
-- never actually painted from attribution at all, open or closed — so
-- however ambiguous its attribution looks on paper, there is no guess
-- being shown for it to be wrong about. Without this, an open switch fed
-- from two different-voltage sources on its two (graph-merged) terminals
-- scored 0 confidence and got flagged "ambiguous, currently showing a
-- guess" even though nothing resembling that guess was ever displayed or
-- captured — the exact false alarm a real schematic (two sources separated
-- by an open switch, never actually tied) would trip on every combination.
-- sourceStates (optional, same DIRECT per-control provenance as gateStates)
-- short-circuits to 1 the same way when nodeId is itself a currently OFF
-- source CONTROL (a generator switched off but still reached by another
-- source on the same bus — see solver.lua's own comment): that node's own
-- displayed color is ALWAYS the flat unpowered-gray isOffSource override
-- too, so it's never actually showing whatever its attribution computes to
-- either, same "no guess being shown to be wrong about" reasoning.
local function _aiColorAttributionConfidence(canvas, attribution, nodeStates, nodeId, gateStates, sourceStates)
    if gateStates and gateStates[nodeId] == "open" then return 1 end
    if sourceStates and sourceStates[nodeId] == false then return 1 end
    local contributingIds = attribution[nodeId]
    if not contributingIds or not _isGenuinelyColorAmbiguous(canvas, contributingIds) then return 1 end

    local rule = canvas.attributionRules and canvas.attributionRules[nodeId]
    if rule and (rule.status == "learned" or rule.status == "locked") then
        local key = ModelLearner.buildConditionKey(rule.conditionIds, nodeStates)
        if key and rule.mapping[key] then
            if rule.status == "locked" then return 1 end
            return math.min(1, (rule.confidence or 0) / _AI_CONFIDENT_EXAMPLE_COUNT)
        end
    end

    -- No per-node rule covers nodeId specifically (there may be no rule at
    -- all — e.g. nodeId has never been ambiguous in any captured snapshot,
    -- a brand new battery on a bus other captures never touched) — fall
    -- back to the GLOBAL voltage-dominance rule (canvas.voltageDominanceRule,
    -- see _recomputeAttributionRules' own comment/model/learner.lua's
    -- findVoltageDominanceRule): has "the single highest-voltage contributor
    -- wins" actually been CONFIRMED (and never contradicted) anywhere else
    -- in this system? If so, that's real evidence for THIS node too, even
    -- though nobody ever painted it specifically.
    --
    -- Scaled differently than a per-node rule though: not against the
    -- fixed _AI_CONFIDENT_EXAMPLE_COUNT constant, but as a fraction of
    -- every OTHER combination in the whole combination space that could
    -- have confirmed or refuted this same global hypothesis
    -- (dominanceRule.teachableTotal, see its own comment) — "every other
    -- possible test, not an arbitrary count" is a meaningful ceiling a
    -- fixed constant can't be: it reaches 100% exactly when every
    -- reachable alternative test has in fact been run and agreed (nothing
    -- left that COULD still contradict it), and stays appropriately low
    -- when many untested alternatives remain. teachableTotal always counts
    -- THIS node's own current combination too (reaching this line already
    -- proves nodeId itself is ambiguous and not forced-gray — the two
    -- guard clauses above would have returned 1 otherwise — so it's
    -- unconditionally one of the counted combinations), hence the -1.
    local dominanceRule = canvas.voltageDominanceRule
    if dominanceRule and dominanceRule.status == "learned" then
        local otherTeachable = math.max(1, (dominanceRule.teachableTotal or 1) - 1)
        return math.min(1, (dominanceRule.exampleCount or 0) / otherTeachable)
    end
    return 0
end

-- Mirrors gdsGui_schematic_getCombinationIndex's own mixed-radix formula
-- exactly (sorted controls by id, idx = idx*numDetents + detentIndex), but
-- for a CANDIDATE detents table rather than the canvas' CURRENT positions
-- — lets a suggestion (model/suggest.lua's own {detents=...} shape) be
-- reported as a combination NUMBER without touching the live canvas (and
-- so without disturbing whatever combination is actually showing) to find
-- out.
local function _combinationIndexForDetents(canvas, detents)
    local sorted = {}
    for _, c in ipairs(canvas.controls) do table.insert(sorted, c) end
    table.sort(sorted, function(a, b) return a.id < b.id end)
    local idx = 0
    for _, c in ipairs(sorted) do
        idx = idx * c.numDetents + (detents[c.id] or 0)
    end
    return idx + 1
end

local function _controlsForSuggest(canvas)
    local list = {}
    for _, c in ipairs(canvas.controls) do
        table.insert(list, { id = c.id, numDetents = c.numDetents })
    end
    return list
end

local function _capturedSignaturesSet(canvas)
    local set = {}
    for signature in pairs(canvas.snapshots) do set[signature] = true end
    return set
end

-- {combinationIndex, combinationTotal, confidencePercent,
-- primaryReasonText, primaryReasonNodeId, suggestedCombinationIndex,
-- fixInstructionText, teachCombos, snapshotImportancePercent} for
-- whichever system mainCanvas currently has open — confidencePercent is
-- nil (rather than a misleading number) when there's genuinely nothing to
-- measure (an untyped/non-ELECTRICAL system); snapshotImportancePercent
-- is nil when nothing anywhere in the space is teachable at all (so
-- there's no maximum to be a fraction of). nil entirely if there's no
-- canvas at all.
-- primaryReasonNodeId is the element/control id primaryReasonText is
-- actually about (always set alongside it) — drawSchematicAiPanel copies
-- it onto canvas.aiCulpritId each frame so gdsGui_schematic_draw's own
-- drawAiCulpritHighlight can ring it in gold; nothing else reads it.
-- primaryReasonText is set alongside any confidencePercent < 100.
-- fixInstructionText is the ONE case primaryReasonText can be set WITHOUT
-- suggestedCombinationIndex alongside it: structuralColorMismatches below
-- catches a captured snapshot's own paint flatly contradicting a
-- provable single-source expectation — not a data gap a new combination
-- could fix, but an outright mistake in THIS exact snapshot, so
-- fixInstructionText instead just says to repaint and re-capture it
-- (OVERWRITE).
-- Otherwise, suggestedCombinationIndex is set only for a gate-rule data
-- gap (or any oscillating factor) worth navigating to: for a learnable
-- gate rule, model/suggest.lua's suggestTargetedSnapshot targets one that
-- would deduce a gate state not already seen in training (falls back to
-- its plain suggestNextSnapshot if no such candidate exists); for an
-- oscillating gate, any untested neighbor is as good as any other (a
-- stability problem, not a data-gap one), so the plain heuristic is used
-- directly. An ambiguous-attribution worst case gets neither: THIS
-- combination already exercises the ambiguity, so there's no missing
-- COMBINATION to navigate to — only a missing disagreeing EXAMPLE, which
-- teachCombos (below) surfaces instead, system-wide rather than scoped to
-- just this one factor.
-- teachCombos is a persistent, GLOBAL checklist — always populated
-- (possibly empty) whenever there's a graph at all, independent of
-- confidencePercent: every combination NUMBER anywhere in the whole space
-- that's teachable for at least one node (scanTeachableSpace below),
-- each tagged with whether its own snapshot has already been captured —
-- EXCEPT combinationIndex itself (this combination), excluded below: it's
-- a checklist of combos to go CAPTURE, and you're already looking at this
-- one, captured or not.
-- snapshotImportancePercent ranks THIS combination's own value as a
-- capture target against the single most valuable combination anywhere
-- in the space (see scanTeachableSpace's own comment on "recurrence").
local function _computeAiPanelStats()
    local canvas = _findSchematicCanvas()
    if not canvas then return nil end

    local stats = { combinationIndex = _schematicCombIndex, combinationTotal = _schematicCombTotal }

    local componentTypes = _buildComponentTypeMap(canvas)
    if next(componentTypes) == nil then return stats end -- untyped/non-ELECTRICAL: nothing to infer

    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local gateStates = _currentGateStates(canvas, componentTypes)

    -- Every captured combination (by combination NUMBER, see
    -- _combinationIndexForDetents) that was actually usable as a training
    -- example for gateId's rule, PAIRED with that example's own deduced
    -- result ("open"/"closed") — the exact signature set
    -- _recomputeGateRules' own examplesByGate loop draws from, just mapped
    -- to something a user can read instead of a raw signature string.
    -- Shared by both the low-confidence REASON text and the full-
    -- confidence WHY text below — nested here (not top-level locals)
    -- purely to stay under this file's 200-local ceiling.
    local function gateExamplesByCombination(gateId)
        local examples = {}
        for signature in pairs(canvas.snapshots) do
            local deduced = _deducedGateStatesBySignature[signature]
            local s = deduced and deduced[gateId]
            if s and s ~= ModelLearner.UNKNOWN then
                table.insert(examples,
                    { index = _combinationIndexForDetents(canvas, gdsGui_schematic_parseSignature(signature)), result = s })
            end
        end
        table.sort(examples, function(a, b) return a.index < b.index end)
        return examples
    end

    -- Same as above, but for an attribution rule — every captured
    -- combination whose own painted color was usable as a winner example
    -- for nodeId (see _deduceAttributionWinnersForSnapshot), paired with
    -- that winning source's own label.
    local function attributionExamplesByCombination(nodeId, labelsById)
        local examples = {}
        for signature, snapshot in pairs(canvas.snapshots) do
            local winners = _deduceAttributionWinnersForSnapshot(canvas, graph, signature, snapshot)
            local winnerId = winners[nodeId]
            if winnerId then
                table.insert(examples, { index = _combinationIndexForDetents(canvas, gdsGui_schematic_parseSignature(signature)),
                    result = labelsById[winnerId] or winnerId })
            end
        end
        table.sort(examples, function(a, b) return a.index < b.index end)
        return examples
    end

    -- "7/8, 12/16" style list of the captured combinations that actually
    -- back the GLOBAL voltage-dominance rule (canvas.voltageDominanceRule.
    -- confirmedSignatures, see _recomputeAttributionRules' own comment) —
    -- named by number so both the REASON and WHY lines below can say
    -- WHICH combinations confirmed it instead of just "confirmed
    -- elsewhere". Empty string (never nil) when there's nothing to list.
    local function dominanceConfirmedComboList()
        local indices = {}
        for _, signature in ipairs((canvas.voltageDominanceRule or {}).confirmedSignatures or {}) do
            table.insert(indices, _combinationIndexForDetents(canvas, gdsGui_schematic_parseSignature(signature)))
        end
        table.sort(indices)
        local parts = {}
        for _, idx in ipairs(indices) do table.insert(parts, idx .. "/" .. _schematicCombTotal) end
        return table.concat(parts, ", ")
    end

    -- Plain-English reason one rule isn't fully trusted yet — deliberately
    -- short (at most 2 short sentences: the shortfall, then an optional
    -- dominance-credit sentence) rather than enumerating every backing
    -- combination by number; that detail is still there to find via TRY
    -- NEXT/TEACH, this line's only job is a quick, readable "why". Shared
    -- by both the gate-position and color-attribution confidence factors,
    -- since both use the same model/learner.lua {status, reason,
    -- exampleCount} shape (see findSimplestRule/findAttributionRule's own
    -- comments). The caller only reaches here once it already knows
    -- confidence < 1, so there's always something to say.
    local function reasonTextWithEvidence(entry, labelsById)
        local examples = (entry.kind == "gateRule")
            and gateExamplesByCombination(entry.id)
            or attributionExamplesByCombination(entry.id, labelsById)

        -- An "attribution" entry with nothing learned for its OWN node id
        -- can still carry partial credit from the GLOBAL voltage-dominance
        -- rule (see _aiColorAttributionConfidence's own fallback) — named
        -- here too so the reason text never undersells a confidence that
        -- isn't actually a flat zero. Independent of whatever this node's
        -- own per-node search concluded (even "no_consistent_explanation"
        -- below): a changing set of CONTRIBUTORS between captures can make
        -- one node's own literal winner differ across examples even while
        -- the highest-voltage-wins hypothesis itself held in every one of
        -- them, so the two aren't the same question.
        local function dominanceClause()
            local dominanceRule = entry.kind == "attribution" and canvas.voltageDominanceRule
            if not (dominanceRule and dominanceRule.status == "learned") then return "" end
            -- Same ratio _aiColorAttributionConfidence itself uses (every
            -- OTHER combination that could have confirmed/refuted this —
            -- see its own comment), kept in sync so this sentence's own
            -- percent always matches the number shown above it.
            local otherTeachable = math.max(1, (dominanceRule.teachableTotal or 1) - 1)
            local percent = math.floor(math.min(1, (dominanceRule.exampleCount or 0) / otherTeachable) * 100 + 0.5)
            return " \"Higher voltage wins\" confirmed at " .. dominanceConfirmedComboList()
                .. ", worth " .. percent .. "% here already."
        end

        local rule = entry.rule
        if not rule or rule.status == "noRule" then
            local reason = rule and rule.reason
            local base
            if reason == "insufficient_examples" then
                base = (#examples == 0) and "No snapshots have taught this yet."
                    or ("Only " .. #examples .. " snapshot captured so far — needs at least 2 with different outcomes.")
            elseif reason == "no_variation" then
                base = "Every captured snapshot agrees so far — needs one with a different outcome."
            elseif reason == "no_consistent_explanation" then
                base = "Captured snapshots disagree, with no consistent pattern yet."
            else
                base = "Nothing taught yet."
            end
            return base .. dominanceClause()
        elseif rule.status == "learned" then
            return "Learned from " .. #examples .. " snapshot(s), not yet confirmed."
        end
        return "Nothing taught yet." -- locked: unreachable as a primary-reason source (full confidence instead)
    end

    -- Every powered element/control/wire in signature's own captured
    -- snapshot whose painted color flatly contradicts what the model can
    -- PROVE it must be — not a guess, not a rule, just "exactly one
    -- source can possibly reach this, that source has a registered
    -- voltage color, and the snapshot's own paint is neither that color
    -- nor plain unpowered gray". Unlike every other confidence factor in
    -- this file, this needs NO ambiguity and NO learned rule to fire —
    -- it's the one thing a captured snapshot (otherwise unconditional
    -- ground truth, see the hasSnapshot branch below) can still be
    -- flatly WRONG about on its own terms, e.g. a wire left showing some
    -- stale/unrelated color that was never actually live under this
    -- combination's own true source attribution. Mirrors the SAME
    -- open-gate wire-anchor logic _solveCurrentSchematic's live wire loop
    -- uses, so this never flags a wire the live display itself wouldn't
    -- also color that way. Nested here (not a top-level local) purely to
    -- stay under this file's 200-local ceiling.
    local function structuralColorMismatches(signature, snapshot)
        local gateStatesForSig, sourceStatesForSig = _pastGateAndSourceStates(canvas, graph, signature)
        local nodeStatesForSig = ModelSolver.solve(graph, sourceStatesForSig, gateStatesForSig)
        local attributionForSig = ModelSolver.solveSourceAttribution(graph, sourceStatesForSig, gateStatesForSig)
        local labelsById = _labelsByIdForCanvas(canvas)
        local detentById = gdsGui_schematic_parseSignature(signature)

        local function colorsEqual(a, b)
            if not a or not b then return false end
            for i = 1, 3 do if math.abs((a[i] or 0) - (b[i] or 0)) > 0.02 then return false end end
            return true
        end

        -- nil when nodeId's attribution isn't provably a single source
        -- (genuinely ambiguous, or that one source has no registered
        -- voltage to compare against) — those cases are left to the
        -- ordinary confidence/attribution-rule machinery, never flagged
        -- here as a flat contradiction.
        local function expectedColorAndSource(nodeId)
            local contributingIds = attributionForSig[nodeId]
            if not contributingIds or _isGenuinelyColorAmbiguous(canvas, contributingIds) then return nil end
            local onlySourceId
            for sourceId in pairs(contributingIds) do onlySourceId = sourceId end
            if not onlySourceId then return nil end
            local entity = _findSourceEntity(canvas, onlySourceId)
            local voltage = entity and entity.voltage
            if not voltage then return nil end
            return _colorForVoltage(canvas, voltage, _currentMedium().style.powered), onlySourceId
        end

        local mismatches = {}
        for _, e in ipairs(canvas.elements) do
            if nodeStatesForSig[e.id] == ModelSolver.POWERED then
                local expected, sourceId = expectedColorAndSource(e.id)
                local painted = snapshot.elements and snapshot.elements[e.id]
                if expected and painted and not colorsEqual(expected, painted) then
                    table.insert(mismatches, { id = e.id, label = labelsById[e.id] or e.id,
                        expectedSourceLabel = labelsById[sourceId] or sourceId })
                end
            end
        end
        for _, c in ipairs(canvas.controls) do
            -- An open gate's or off source's own body always displays flat
            -- unpowered gray regardless of attribution (see
            -- _solveCurrentSchematic's own isOpenGate/isOffSource override)
            -- — checking it against its source's color would be a false
            -- positive, not a real contradiction.
            local isOpenGate = componentTypes[c.id] == "gate"
                and not _isActivePosition({ positions = c.positions, detentIndex = detentById[c.id] or c.detentIndex })
            local isOffSource = componentTypes[c.id] == "source" and not sourceStatesForSig[c.id]
            if nodeStatesForSig[c.id] == ModelSolver.POWERED and not isOpenGate and not isOffSource then
                local expected, sourceId = expectedColorAndSource(c.id)
                local painted = snapshot.controls and snapshot.controls[c.id]
                if expected and painted and not colorsEqual(expected, painted) then
                    table.insert(mismatches, { id = c.id, label = labelsById[c.id] or c.id,
                        expectedSourceLabel = labelsById[sourceId] or sourceId })
                end
            end
        end
        for _, w in ipairs(canvas.wires) do
            -- A directionalGate-touching wire is checked off its own
            -- non-gate endpoint alone, same "the gate's single shared node
            -- can't represent its two leads independently" reasoning
            -- _solveCurrentSchematic's own live wire loop uses — never
            -- both-ends-powered, which would simply never fire for a
            -- correctly-blocking diode's cathode-side wire at all.
            local fromIsDirectionalGate = componentTypes[w.fromElementId] == "directionalGate"
            local toIsDirectionalGate = componentTypes[w.toElementId] == "directionalGate"
            local powered, anchorId
            if fromIsDirectionalGate or toIsDirectionalGate then
                anchorId = fromIsDirectionalGate and w.toElementId or w.fromElementId
                powered = nodeStatesForSig[anchorId] == ModelSolver.POWERED
            else
                local fromState, toState = nodeStatesForSig[w.fromElementId], nodeStatesForSig[w.toElementId]
                powered = fromState == ModelSolver.POWERED and toState == ModelSolver.POWERED
                local fromIsOpenGate = componentTypes[w.fromElementId] == "gate" and gateStatesForSig[w.fromElementId] ~= "closed"
                local toIsOpenGate = componentTypes[w.toElementId] == "gate" and gateStatesForSig[w.toElementId] ~= "closed"
                anchorId = (fromIsOpenGate and not toIsOpenGate) and w.toElementId or w.fromElementId
            end
            if powered then
                local expected, sourceId = expectedColorAndSource(anchorId)
                local painted = snapshot.wires and snapshot.wires[w.id]
                if expected and painted and not colorsEqual(expected, painted) then
                    table.insert(mismatches, { id = w.id, label = labelsById[w.id] or w.id,
                        expectedSourceLabel = labelsById[sourceId] or sourceId })
                end
            end
        end
        return mismatches
    end

    local currentSignature = gdsGui_schematic_computeSignature("mainCanvas")
    if gdsGui_schematic_hasSnapshot("mainCanvas", currentSignature) then
        -- An exact authored snapshot is normally this combination's
        -- ground truth outright — EXCEPT when its own paint flatly
        -- contradicts a provable single-source expectation (see
        -- structuralColorMismatches above); that's not "nothing was
        -- inferred", it's a captured color the model can PROVE is wrong
        -- on its own terms, so it no longer gets a free pass to 100%.
        local snapshot = canvas.snapshots[currentSignature]
        local mismatches = structuralColorMismatches(currentSignature, snapshot)
        if #mismatches == 0 then
            stats.confidencePercent = 100
        else
            stats.confidencePercent = 0
            local worst = mismatches[1]
            stats.primaryReasonNodeId = worst.id
            stats.primaryReasonText = worst.label .. ": wrong color, should be " .. worst.expectedSourceLabel .. "'s."
                .. (#mismatches > 1 and (" (+" .. (#mismatches - 1) .. " more)") or "")
            stats.fixInstructionText = "Repaint " .. worst.label .. " " .. worst.expectedSourceLabel
                .. "'s color, then re-capture (OVERWRITE)."
        end
    else
        -- Only a gate NOT directly pinned by the user's own control
        -- (gateStates already has an entry for one of those — see
        -- _currentGateStates) has its POSITION guessed at; a plain
        -- user-operated switch's position is ground truth. Its COLOR can
        -- still be guessed though (see _aiColorAttributionConfidence
        -- below), which is exactly why this no longer short-circuits to
        -- 100% just because ruleGovernedIds turns out empty.
        local ruleGovernedIds = {}
        for id, node in pairs(graph.nodes) do
            if node.role == "gate" and not gateStates[id] then table.insert(ruleGovernedIds, id) end
        end

        local rulesByGate = {}
        for gateId, rule in pairs(canvas.rules or {}) do
            if rule and (rule.status == "learned" or rule.status == "locked") and not gateStates[gateId] then
                rulesByGate[gateId] = rule
            end
        end
        local result = ModelSolver.solveWithRules(graph, sourceStates, gateStates, rulesByGate)
        local oscillating = {}
        if not result.converged then
            for _, id in ipairs(result.oscillating) do oscillating[id] = true end
        end

        -- {confidence, id, isOscillating, rule, kind} per factor, not bare
        -- numbers — kept around only long enough to both average them AND
        -- find the single WORST one to explain below. kind ("gateRule" or
        -- "attribution") tells the suggestion-building step below which of
        -- two very different remedies actually applies to whichever entry
        -- turns out worst — see that step's own comment.
        local confidenceEntries = {}
        for _, id in ipairs(ruleGovernedIds) do
            local rule = canvas.rules and canvas.rules[id]
            local isOsc = oscillating[id]
            table.insert(confidenceEntries,
                { confidence = _aiGateConfidence(rule, isOsc), id = id, isOscillating = isOsc, rule = rule, kind = "gateRule" })
        end

        local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
        for id, state in pairs(result.nodeStates) do
            if state == ModelSolver.POWERED and not oscillating[id] then
                local rule = canvas.attributionRules and canvas.attributionRules[id]
                table.insert(confidenceEntries,
                    { confidence = _aiColorAttributionConfidence(canvas, attribution, result.nodeStates, id, gateStates, sourceStates),
                      id = id, rule = rule, kind = "attribution" })
            end
        end

        if #confidenceEntries == 0 then
            stats.confidencePercent = 100 -- nothing powered, nothing rule-governed: genuinely nothing to guess
        else
            local total, worst = 0, nil
            for _, e in ipairs(confidenceEntries) do
                total = total + e.confidence
                if not worst or e.confidence < worst.confidence or (e.confidence == worst.confidence and e.id < worst.id) then
                    worst = e
                end
            end
            stats.confidencePercent = math.floor(total / #confidenceEntries * 100 + 0.5)

            if stats.confidencePercent < 100 then
                local labelsById = _labelsByIdForCanvas(canvas)
                local label = labelsById[worst.id] or worst.id
                local why = worst.isOscillating
                    and "Relay feedback never settled here (unstable)."
                    or reasonTextWithEvidence(worst, labelsById)
                stats.primaryReasonText = label .. ": " .. why
                stats.primaryReasonNodeId = worst.id

                -- currentSignature is marked as if already captured so
                -- neither remedy below ever points at the very combination
                -- this panel is currently unsure about — capturing THAT
                -- one trivially hits 100% by the exact-snapshot short-
                -- circuit above without teaching anything, which would
                -- make either remedy a circular/useless claim.
                local excludedSignatures = _capturedSignaturesSet(canvas)
                excludedSignatures[currentSignature] = true

                -- An ambiguous-attribution worst case has no navigation
                -- target at all — THIS combination already exercises the
                -- ambiguity (that's exactly why it's the worst factor
                -- right now), and what's missing is a disagreeing
                -- EXAMPLE, not a missing combination (see TEACH's own
                -- comment below, scanTeachableSpace, for where/how that
                -- gets surfaced instead). A gate-rule data gap (or an
                -- oscillating gate) IS a genuinely missing combination
                -- though, so only that case gets a navigation suggestion.
                if not (worst.kind == "attribution" and not worst.isOscillating) then
                    -- Gate-rule data gap (or an oscillating gate — see
                    -- below): a genuinely missing COMBINATION, so a
                    -- navigation suggestion actually helps here, unlike
                    -- the attribution case above. For an oscillating gate,
                    -- any nearby untested combination is as good as any
                    -- other (it's a stability problem, not a data-gap
                    -- one), so this keeps the plain one-flip heuristic.
                    -- For a learnable gate rule (insufficient_examples/
                    -- no_variation/no_consistent_explanation), targets a
                    -- combination that would deduce a state for worst.id
                    -- NOT already seen in training — see suggestTargetedSnapshot
                    -- and _gateAndSourceStatesForDetents above.
                    local suggestion
                    if worst.kind == "gateRule" and not worst.isOscillating then
                        local seenStates = {}
                        for signature in pairs(canvas.snapshots) do
                            local deduced = _deducedGateStatesBySignature[signature]
                            local s = deduced and deduced[worst.id]
                            if s and s ~= ModelLearner.UNKNOWN then seenStates[s] = true end
                        end
                        local function scoreFn(candidateDetents)
                            local candGateStates, candSourceStates =
                                _gateAndSourceStatesForDetents(canvas, componentTypes, candidateDetents)
                            local candNodeStates = ModelSolver.solve(graph, candSourceStates, candGateStates)
                            local deduced = ModelLearner.inferGate(worst.id, candNodeStates, graph)
                            if deduced == ModelLearner.UNKNOWN then return nil end
                            return (not seenStates[deduced]) and 2 or 1
                        end
                        suggestion = ModelSuggest.suggestTargetedSnapshot(_controlsForSuggest(canvas), excludedSignatures, scoreFn)
                    end
                    suggestion = suggestion or ModelSuggest.suggestNextSnapshot(_controlsForSuggest(canvas), excludedSignatures)
                    if suggestion then
                        stats.suggestedCombinationIndex = _combinationIndexForDetents(canvas, suggestion.detents)
                    end
                end
            end
        end
    end

    -- Persistent, GLOBAL teaching checklist — unlike the REASON/TRY NEXT
    -- pair above (which only ever speak to whichever single factor is
    -- worst for THIS combination), this scans the ENTIRE combination
    -- space for every combo NUMBER that's teachable for AT LEAST ONE node
    -- — same per-combo ambiguous-and-not-forced-flat test
    -- teachableCombosTotal (above _recomputeAttributionRules) uses for
    -- "any node at all" — paired with whether that combo's own snapshot
    -- has already been captured, so the panel can show a standing
    -- checklist (every one checked off eventually) rather than a list
    -- that shrinks and loses its own history as captures happen.
    --
    -- SNAPSHOT IMPORTANCE reuses the same per-node scan to rank combos by
    -- how many OTHER combos they'd help teach: a combo's "recurrence" is
    -- the number of (node, other combo) pairs it shares a teach-set with
    -- (every node where BOTH combos are genuinely ambiguous means
    -- capturing either one teaches something relevant to the other). The
    -- combo with the highest recurrence anywhere in the space is the
    -- single most valuable one to capture (100%); every other combo's
    -- importance — including whichever one is currently showing — is
    -- just its own recurrence as a fraction of that maximum.
    local function scanTeachableSpace()
        local sortedIds, numDetentsById = {}, {}
        for _, c in ipairs(canvas.controls) do
            table.insert(sortedIds, c.id)
            numDetentsById[c.id] = c.numDetents
        end
        local capturedSignatures = _capturedSignaturesSet(canvas)
        local candDetents = {}
        for _, id in ipairs(sortedIds) do candDetents[id] = 0 end

        local capturedByIndex, indicesByNode = {}, {}
        while true do
            local candGateStates, candSourceStates = _gateAndSourceStatesForDetents(canvas, componentTypes, candDetents)
            local candAttribution = ModelSolver.solveSourceAttribution(graph, candSourceStates, candGateStates)
            local idx = _combinationIndexForDetents(canvas, candDetents)
            local teachableHere = false
            for nodeId, contributingIds in pairs(candAttribution) do
                if _isGenuinelyColorAmbiguous(canvas, contributingIds) then
                    local role = graph.nodes[nodeId].role
                    local isOpenGate = role == "gate" and candGateStates[nodeId] ~= "closed"
                    local isOffSource = role == "source" and not candSourceStates[nodeId]
                    if not isOpenGate and not isOffSource then
                        teachableHere = true
                        indicesByNode[nodeId] = indicesByNode[nodeId] or {}
                        table.insert(indicesByNode[nodeId], idx)
                    end
                end
            end
            if teachableHere then
                local candControlStates = {}
                for _, id in ipairs(sortedIds) do
                    table.insert(candControlStates, { id = id, detentIndex = candDetents[id] })
                end
                local candSignature = gdsGui_schematic_buildSignature(candControlStates)
                capturedByIndex[idx] = capturedSignatures[candSignature] or false
            end

            local i = #sortedIds
            while i >= 1 do
                local id = sortedIds[i]
                candDetents[id] = candDetents[id] + 1
                if candDetents[id] < numDetentsById[id] then break end
                candDetents[id] = 0
                i = i - 1
            end
            if i == 0 then break end
        end

        local teachableIndices = {}
        for idx in pairs(capturedByIndex) do table.insert(teachableIndices, idx) end
        table.sort(teachableIndices)

        local recurrenceByIndex = {}
        for _, indices in pairs(indicesByNode) do
            local n = #indices
            if n > 1 then
                for _, idx in ipairs(indices) do
                    recurrenceByIndex[idx] = (recurrenceByIndex[idx] or 0) + (n - 1)
                end
            end
        end

        return teachableIndices, capturedByIndex, recurrenceByIndex
    end

    local teachableIndices, capturedByIndex, recurrenceByIndex = scanTeachableSpace()

    -- The combo currently showing is excluded from its own checklist — the
    -- whole point of TEACH is "combos to go CAPTURE", and you're already
    -- looking at this one, captured or not; listing it as something to go
    -- navigate to would be pointing at yourself.
    stats.teachCombos = {}
    for _, idx in ipairs(teachableIndices) do
        if idx ~= stats.combinationIndex then
            table.insert(stats.teachCombos, { index = idx, captured = capturedByIndex[idx] })
        end
    end

    local maxRecurrence = 0
    for _, r in pairs(recurrenceByIndex) do
        if r > maxRecurrence then maxRecurrence = r end
    end
    if maxRecurrence > 0 then
        stats.snapshotImportancePercent = math.floor((recurrenceByIndex[stats.combinationIndex] or 0) / maxRecurrence * 100 + 0.5)
    end

    return stats
end

-- Whether the AI panel overlay is currently showing — see
-- schematicAiBtnPressed/drawSchematicAiPanel below. A plain app-layer flag
-- (not a canvas field, unlike the annunciator panel's own library-owned
-- open/close state): this is a read-only info overlay with no editing
-- semantics of its own, so it doesn't need anything the library tracks —
-- just drawn directly, same convention as drawSchematicZoomFullScreenLabel.
-- Canvas interaction under its own footprint IS inhibited though (see
-- _syncAiPanelInputBlock/gdsGui_schematic_setInputBlockRect) — unlike
-- PAINT's swatch palette or the annunciator panel, a tap meant for
-- scrolling this panel's text must never also pan/select on the canvas
-- underneath it.
local _aiPanelOpen = false
local _aiPanelFont  = nil
-- How many pixels of the panel's own text content are scrolled past the
-- top (0 = top; clamped against actual content height every draw — see
-- drawSchematicAiPanel) — fed by schematicAiPanelScrolled, the wheel/
-- drag-forwarding callback gdsGui_schematic_setInputBlockRect calls.
local _aiPanelScrollY = 0
local _AI_PANEL_WHEEL_PX_PER_NOTCH = 24

function schematicAiBtnPressed(newState)
    _aiPanelOpen = (newState == globApp.BUTTON_STATES.PRESSED)
    _aiPanelScrollY = 0 -- fresh scroll position each time the panel is (re)opened
end

-- The panel's own on-screen rectangle, pinned to the bottom 1/4 of the
-- live canvas — shared by drawSchematicAiPanel (what actually gets drawn)
-- and _syncAiPanelInputBlock (what gets blocked/scroll-forwarded), so the
-- two can never drift out of sync with each other. nil if there's no
-- canvas to pin to at all.
local function _aiPanelRect()
    local cx, cy, cw, ch = gdsGui_schematic_getCanvasRect("mainCanvas")
    if not cx then return nil end
    local panelH = ch * 0.25
    return cx, cy + ch - panelH, cw, panelH
end

-- gdsGui_schematic_setInputBlockRect's own by-name wheel/drag callback
-- (see _syncAiPanelInputBlock below, which registers this name) — delta is
-- either a wheel notch count (isDrag false) or a raw drag pixel offset
-- (isDrag true, see that setter's own comment). Actual clamping against
-- content height happens once, at draw time (drawSchematicAiPanel), not
-- here — this just accumulates an unclamped intent.
function schematicAiPanelScrolled(delta, isDrag)
    if isDrag then
        _aiPanelScrollY = _aiPanelScrollY + delta
    else
        _aiPanelScrollY = _aiPanelScrollY - delta * _AI_PANEL_WHEEL_PX_PER_NOTCH
    end
end

-- Polled once a frame (see love.update(), right after gdsGui_update(dt) so
-- canvas.x/y/w/h already reflect this frame's pan/zoom) rather than only
-- at open/close: the panel's rectangle moves whenever the canvas itself
-- pans/zooms/resizes, and the dead zone has to track it exactly or it'd
-- either block taps on canvas content the panel no longer actually covers,
-- or (worse) leave a gap where the panel LOOKS like it's blocking input
-- but isn't.
local function _syncAiPanelInputBlock()
    if _aiPanelOpen and gdsGui_page_currentName() == "SystemSchematic" and not gdsGui_schematic_isMenuOpen("mainCanvas") then
        local px, py, pw, ph = _aiPanelRect()
        if px then
            gdsGui_schematic_setInputBlockRect("mainCanvas", { x = px, y = py, w = pw, h = ph }, "schematicAiPanelScrolled")
            return
        end
    end
    gdsGui_schematic_setInputBlockRect("mainCanvas", nil)
end

-- Drawn directly (not as an outputTxtBox widget), after gdsGui_draw() in
-- love.draw(): the library's own schematic-canvas draw pass needs to have
-- already happened so this paints on top of it, same reasoning as
-- drawSchematicZoomFullScreenLabel above. Modal to the CANVAS underneath
-- its own footprint (see _syncAiPanelInputBlock) but not to the rest of
-- the UI — the AI panel ISN'T part of _SCHEMATIC_DOCK_TOOLS' mutually-
-- exclusive set (see its own creation comment), so it CAN stay open while
-- a schematic modal menu (DESIGN ACTIONS, the color picker, ...) is also
-- open — skipped here whenever one is, so its bottom-of-canvas footprint
-- never covers up menu options a modal is relying on being tappable.
function drawSchematicAiPanel()
    -- canvas.aiCulpritId (gold-ring highlight, see
    -- gdsGui_schematic_draw's own drawAiCulpritHighlight) must never
    -- outlive the panel it was computed for — cleared on every early-exit
    -- below, same as the panel itself not drawing.
    local culpritCanvas = _findSchematicCanvas()
    local function clearCulprit() if culpritCanvas then culpritCanvas.aiCulpritId = nil end end

    if not _aiPanelOpen then clearCulprit(); return end
    if gdsGui_page_currentName() ~= "SystemSchematic" then clearCulprit(); return end
    if gdsGui_schematic_isMenuOpen("mainCanvas") then clearCulprit(); return end
    local px, py, pw, ph = _aiPanelRect()
    if not px then clearCulprit(); return end

    local stats = _computeAiPanelStats()
    if not stats then clearCulprit(); return end
    if culpritCanvas then culpritCanvas.aiCulpritId = stats.primaryReasonNodeId end

    love.graphics.setColor(0, 0, 0, 0.72)
    love.graphics.rectangle("fill", px, py, pw, ph)
    love.graphics.setColor(1, 1, 0, 1)
    love.graphics.rectangle("line", px, py, pw, ph)

    if not _aiPanelFont then _aiPanelFont = love.graphics.newFont(13) end
    love.graphics.setFont(_aiPanelFont)

    -- Each entry is either a plain string, or {text=, checkmark=true} for
    -- one row of the vertical TEACH checklist below — checkmark draws a
    -- green check mark at the row's right edge, for whichever combo
    -- numbers already have a captured snapshot.
    local lines = {
        string.format("COMBINATION: %d / %d", stats.combinationIndex, stats.combinationTotal),
        "PREDICTION CONFIDENCE: " .. (stats.confidencePercent and (stats.confidencePercent .. "%") or "N/A"),
    }
    -- REASON/TRY NEXT only ever appear alongside a confidence shortfall —
    -- see _computeAiPanelStats' own comment on why these fields are only
    -- ever set together with confidencePercent < 100. TEACH (below) is
    -- the one exception: a persistent, GLOBAL checklist shown regardless
    -- of confidencePercent, replacing the old WHY line entirely.
    if stats.primaryReasonText then
        table.insert(lines, "REASON: " .. stats.primaryReasonText)
    end
    if stats.suggestedCombinationIndex then
        table.insert(lines, string.format("TRY NEXT: COMBINATION %d/%d", stats.suggestedCombinationIndex, stats.combinationTotal))
    end
    if stats.fixInstructionText then
        table.insert(lines, "FIX: " .. stats.fixInstructionText)
    end
    if stats.teachCombos then
        if #stats.teachCombos == 0 then
            table.insert(lines, "TEACH: N/A")
        else
            table.insert(lines, "TEACH:")
            for _, combo in ipairs(stats.teachCombos) do
                table.insert(lines, { text = tostring(combo.index), checkmark = combo.captured })
            end
        end
    end
    table.insert(lines, "SNAPSHOT IMPORTANCE: " .. (stats.snapshotImportancePercent and (stats.snapshotImportancePercent .. "%") or "N/A"))

    local pad, wrapW, lineGap = 10, pw - 20, 4
    local lineH = _aiPanelFont:getHeight() + lineGap

    -- First pass: each line's own wrapped height (REASON in particular can
    -- run past one line's width) and the running total — needed to clamp
    -- scroll BEFORE drawing anything, so a stale scroll position (e.g.
    -- left over from a longer REASON line that just got shorter) never
    -- leaves a blank gap hanging at the bottom instead of snapping back.
    local lineCounts, totalH = {}, 0
    for i, line in ipairs(lines) do
        local text = type(line) == "table" and line.text or line
        local _, wrapped = _aiPanelFont:getWrap(text, wrapW)
        lineCounts[i] = math.max(1, #wrapped)
        totalH = totalH + lineCounts[i] * lineH
    end
    local innerH = ph - pad * 2
    local maxScroll = math.max(0, totalH - innerH)
    _aiPanelScrollY = math.max(0, math.min(maxScroll, _aiPanelScrollY))

    love.graphics.setScissor(px, py, pw, ph)
    local y = py + pad - _aiPanelScrollY
    for i, line in ipairs(lines) do
        local text = type(line) == "table" and line.text or line
        love.graphics.setColor(1, 1, 0, 1)
        love.graphics.printf(text, px + pad, y, wrapW, "left")
        if type(line) == "table" and line.checkmark then
            -- Drawn as two short line segments (not a text glyph — the
            -- panel's default font has no guaranteed check-mark glyph) a
            -- few characters to the right of the combo number itself,
            -- vertically centered on its own line.
            local cx = px + pad + _aiPanelFont:getWidth(text) + 14
            local cy = y + _aiPanelFont:getHeight() / 2
            love.graphics.setColor(0, 1, 0, 1)
            love.graphics.setLineWidth(2)
            love.graphics.line(cx - 6, cy, cx - 2, cy + 4, cx + 6, cy - 5)
            love.graphics.setLineWidth(1)
        end
        y = y + lineCounts[i] * lineH
    end
    love.graphics.setScissor()

    -- A thin scroll-position indicator along the right edge — only drawn
    -- once content actually overflows the panel (maxScroll > 0); nothing
    -- to indicate otherwise.
    if maxScroll > 0 then
        local trackX = px + pw - 6
        love.graphics.setColor(1, 1, 1, 0.25)
        love.graphics.rectangle("fill", trackX, py + 2, 3, ph - 4)
        local thumbH = math.max(14, (innerH / totalH) * (ph - 4))
        local thumbY = py + 2 + (_aiPanelScrollY / maxScroll) * (ph - 4 - thumbH)
        love.graphics.setColor(1, 1, 0, 0.8)
        love.graphics.rectangle("fill", trackX, thumbY, 3, thumbH)
    end

    love.graphics.setColor(1, 1, 1, 1)
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
    gdsGui_schematic_setBackgroundImage("mainCanvas", _canvasBackgroundPath(_findCurrentAircraft()))
    -- Every value handed to the library is deep-copied off of sys's own
    -- tables (see _deepCopyTable) so mainCanvas never ends up aliasing the
    -- stored record it was just loaded from.
    local canvas = _findSchematicCanvas()
    for _, e in ipairs(sys.elements or {}) do
        gdsGui_schematic_addElement("mainCanvas", e.id, e.shapeType, e.x, e.y, e.w, e.h, e.label,
            _deepCopyTable(e.defaultColor), _deepCopyTable(e.properties), e.rotation or 0, e.spritePath,
            e.componentType)
        -- voltage (per-source display setting — see
        -- _openPerSourceSettingsMenu) isn't among addElement's own
        -- parameters, so it doesn't round-trip through it like
        -- componentType does — attached directly here instead, same as
        -- how a loaded canvas's predictedColor is never trusted from disk
        -- in the first place (always nil-safe, re-derived or re-set,
        -- never a required field). Color itself is never stored per-source
        -- any more — it's derived live from voltage via this system's own
        -- canvas.voltageColors, set just below (see _colorForPoweredNode).
        if canvas then
            local el = canvas.elements[#canvas.elements]
            el.voltage = e.voltage
        end
    end
    for _, c in ipairs(sys.controls or {}) do
        gdsGui_schematic_addControl("mainCanvas", c.id, c.x, c.y, _deepCopyTable(c.positions), c.detentIndex,
            c.label, c.callbackFunc, c.radiusScale, c.spritePaths, c.rotation, c.overlaySpritePath,
            _deepCopyTable(c.defaultColor), c.colorDarkenMul, c.componentType)
        if canvas then
            local ctrl = canvas.controls[#canvas.controls]
            ctrl.voltage = c.voltage
        end
    end
    for _, w in ipairs(sys.wires or {}) do
        gdsGui_schematic_addWire("mainCanvas", w.id, w.fromElementId, w.toElementId, _deepCopyTable(w.defaultColor),
            w.directionOverride)
    end
    for _, a in ipairs(sys.annunciators or {}) do
        gdsGui_schematic_addAnnunciator("mainCanvas", a.id, a.label, _deepCopyTable(a.color), a.active)
    end
    if canvas then
        canvas.snapshots = _deepCopyTable(sys.snapshots or {})
        canvas.rules = _deepCopyTable(sys.rules or {})
        canvas.attributionRules = _deepCopyTable(sys.attributionRules or {})
        -- Starts empty for a system that's never had a voltage taught yet
        -- (new system, or one re-created after deleting it or its whole
        -- aircraft) — same "has to be taught again" lifecycle as
        -- snapshots/rules just above, deliberately not an appSettings
        -- global (see _ensureVoltageHasColor's own comment).
        canvas.voltageColors = _deepCopyTable(sys.voltageColors or {})
    end
    _applySolvedColorsToCurrentCombination()
    _recomputeDeducedGateStates()

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
    gdsGui_button_setState("schematicAiBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicAiBtn", not designing)
    _aiPanelOpen = false -- a freshly (re)loaded system starts with the AI panel closed
    gdsGui_button_setState("schematicFullScreenToggle", designing and "deactivated" or "released")
    -- setFontSizeToFit (not a plain setText) since sys.name's length varies
    -- per system — refitting on every load keeps a long name from wrapping/
    -- overflowing at the user's current global font size (see
    -- _applyFontSize, which only re-fits on a FONT SIZE change, not a
    -- system switch).
    gdsGui_outputTxtBox_setText("schematic_pageTitle", sys.name)
    gdsGui_outputTxtBox_setFontSizeToFit("schematic_pageTitle", appSettings.fontSize, 10)
    _setSnapshotLabelText(gdsGui_schematic_countSnapshots("mainCanvas"))
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
-- SYSTEM SCHEMATIC — DESIGN-MODE "ADD" CASCADING MENU
-- (SYSTEM >) FUNDAMENTALS > TYPE > POSITIONS, with TYPE's own PATH list
-- additionally branching into CONNECTOR > CONNECTOR FROM. SELECT SYSTEM,
-- TYPE, POSITIONS, and CONNECTOR FROM each append a "RETURN" row so the
-- user can step back up the cascade instead of only being able to tap
-- outside to cancel out of it entirely. FUNDAMENTALS (the menu the "+"
-- dock button actually opens for every typed system) appends "ANNUNCIATOR"
-- in that spot instead — see _openFundamentalsMenu's own comment for why
-- it no longer needs a RETURN row.
-------------------------------------------------------------------------------

local function _openDesignActionsMenu(canvasName)
    -- ADD ELEMENT/CONTROL moved out to its own dedicated "+" dock button
    -- (schematicAddBtn, top-right of the canvas — see schematicAddBtnPressed)
    -- so starting the ADD cascade below no longer needs this menu at all.
    local options = {}
    if gdsGui_schematic_canUndo(canvasName) then table.insert(options, "UNDO LAST ACTION") end
    -- GATE RULES only offered once the canvas actually has a "gate"-role
    -- node to show a rule for (see model/learner.lua's findSimplestRule,
    -- Phase 3) — nothing untyped/non-electrical schematics could ever
    -- populate. SUGGEST NEXT SNAPSHOT only needs controls to exist at all
    -- (model/suggest.lua's heuristic is domain-agnostic — see its own
    -- comment), so it's offered for any system with at least one.
    local canvas = _findSchematicCanvas()
    if canvas then
        local componentTypes = _buildComponentTypeMap(canvas)
        for _, role in pairs(componentTypes) do
            if role == "gate" then table.insert(options, "GATE RULES"); break end
        end
        -- ATTRIBUTION RULES only offered once some node has actually shown
        -- up ambiguous across a captured snapshot (see
        -- _recomputeAttributionRules) — nothing to show otherwise.
        if next(canvas.attributionRules or {}) ~= nil then
            table.insert(options, "ATTRIBUTION RULES")
        end
        if #canvas.controls > 0 then table.insert(options, "SUGGEST NEXT SNAPSHOT") end
    end
    -- <MEDIUM> COLORS lets the user pick their own powered/unpowered
    -- display colors (default yellow/gray, or whatever this medium's own
    -- style says — see _currentMedium) instead of being stuck with the
    -- medium's built-in ones, plus per-source magnitude/color (PER-SOURCE
    -- SETTINGS — see _openPerSourceSettingsListMenu). Shown for any
    -- system, not just ELECTRICAL (every systemType has its own medium
    -- now — see model/media/registry.lua), gated only on componentTypes,
    -- not systemType (a system with nothing tagged yet still has a color
    -- scheme worth being able to set before placing anything).
    local sys = _findSystem(schematicStore.currentSystemId)
    if sys then table.insert(options, (_currentMedium().name or "ELECTRICAL") .. " COLORS") end
    -- Every row from here down is destructive and requires a sustained
    -- press-and-hold instead of a plain tap — the hold itself IS the
    -- confirmation (see _markConfirmMenu), so none of these pop up a
    -- separate "are you sure?" sub-menu. Each is colored by how
    -- destructive it actually is: yellow for CLEAR THIS SNAPSHOT (just the
    -- current combination), red for CLEAR ALL SNAPSHOTS/CLEAR PAGE (every
    -- snapshot, or the whole diagram). confirmRows tracks each one's
    -- actual index as it's conditionally inserted, rather than assuming a
    -- fixed position — gdsGui_schematic_openMenu's confirmIndex now
    -- accepts a list of {index, color} entries for exactly this (see its
    -- own comment).
    local confirmRows = {}
    -- CLEAR THIS SNAPSHOT only offered when the combination currently
    -- showing actually has one recorded (see gdsGui_schematic_hasSnapshot)
    -- — nothing to clear otherwise.
    if gdsGui_schematic_hasSnapshot(canvasName, gdsGui_schematic_computeSignature(canvasName)) then
        table.insert(options, "CLEAR THIS SNAPSHOT")
        table.insert(confirmRows, { index = #options, color = { 1, 1, 0, 1 } })
    end
    -- CLEAR ALL SNAPSHOTS -- unlike CLEAR THIS SNAPSHOT (just the current
    -- combination) or CLEAR PAGE just below (the whole diagram, snapshots
    -- included), this wipes every snapshot AND every learned/locked gate
    -- rule on the system while leaving the elements/wires/controls/
    -- annunciators themselves untouched -- "start teaching the engine over"
    -- without having to rebuild the diagram from scratch. Only offered when
    -- there's actually something to reset.
    if gdsGui_schematic_countSnapshots(canvasName) > 0 then
        table.insert(options, "CLEAR ALL SNAPSHOTS")
        table.insert(confirmRows, { index = #options })
    end
    table.insert(options, "CLEAR PAGE")
    table.insert(confirmRows, { index = #options })
    gdsGui_schematic_openMenu(canvasName, "DESIGN ACTIONS", options, "schematicDesignActionChosen", nil, confirmRows)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — GATE RULES (inference-schematic-assistance plan, Phase
-- 5): lists every "gate"-role node (see model/graph.lua) with its current
-- rule status, then drills into one gate's plain-word rule text with a LOCK
-- action (see _lockGateRule) — all built from the library's generic
-- gdsGui_schematic_openMenu primitive, same as _openDesignActionsMenu above,
-- never touching the library's own element/control edit menu (componentType/
-- rules stay app-layer-opaque per CLAUDE.md's library/app boundary).
-------------------------------------------------------------------------------

-- Deterministic (sorted) gate id order, shared by the list menu below and
-- its onSelect callback (schematicGateRulesListChosen, further down the
-- file) so a row's tapped INDEX maps back to the same gate every time,
-- without having to stash the list itself in module state.
local function _sortedGateIds(canvas)
    local componentTypes = _buildComponentTypeMap(canvas)
    local gateIds = {}
    for id, role in pairs(componentTypes) do
        if role == "gate" then table.insert(gateIds, id) end
    end
    table.sort(gateIds)
    return gateIds
end

local function _openGateRulesListMenu(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local gateIds = _sortedGateIds(canvas)
    local labelsById = _labelsByIdForCanvas(canvas)

    local options = {}
    for _, id in ipairs(gateIds) do
        local rule = canvas.rules and canvas.rules[id]
        local status = (rule and rule.status) or "noRule"
        table.insert(options, (labelsById[id] or id) .. " (" .. status .. ")")
    end
    table.insert(options, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "GATE RULES", options, "schematicGateRulesListChosen", nil, nil, 0.8)
end

local function _openGateRuleDetailMenu(canvasName, gateId)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local rule = canvas.rules and canvas.rules[gateId]
    local text = _formatRuleText(gateId, rule, _labelsByIdForCanvas(canvas))

    local options = {}
    -- Only a freshly-learned (not yet confirmed) rule can be locked — a
    -- rule that's already locked, or isn't learned at all yet, has nothing
    -- for this action to do (mirrors _lockGateRule's own no-op guard).
    if rule and rule.status == "learned" then table.insert(options, "LOCK THIS RULE") end
    table.insert(options, "RETURN")

    _pendingGateRuleGateId = gateId
    gdsGui_schematic_openMenu(canvasName, text, options, "schematicGateRuleDetailChosen", "schematicGateRuleDetailCancelled", nil, 0.8)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — ATTRIBUTION RULES: same list/detail/LOCK shape as GATE
-- RULES just above, for a node ambiguous between 2+ simultaneously-active
-- sources (see model/learner.lua's findAttributionRule and
-- _recomputeAttributionRules) instead of a gate's own open/closed
-- position.
-------------------------------------------------------------------------------

-- Deterministic (sorted) id order over canvas.attributionRules' own keys
-- (every node that's EVER shown up ambiguous across a captured snapshot —
-- see _recomputeAttributionRules), same "stable row-to-id mapping without
-- stashing the list" convention as _sortedGateIds above.
local function _sortedAmbiguousNodeIds(canvas)
    local ids = {}
    for id in pairs(canvas.attributionRules or {}) do table.insert(ids, id) end
    table.sort(ids)
    return ids
end

local function _openAttributionRulesListMenu(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local nodeIds = _sortedAmbiguousNodeIds(canvas)
    local labelsById = _labelsByIdForCanvas(canvas)

    local options = {}
    for _, id in ipairs(nodeIds) do
        local rule = canvas.attributionRules[id]
        local status = (rule and rule.status) or "noRule"
        table.insert(options, (labelsById[id] or id) .. " (" .. status .. ")")
    end
    table.insert(options, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "ATTRIBUTION RULES", options, "schematicAttributionRulesListChosen", nil, nil, 0.8)
end

local function _openAttributionRuleDetailMenu(canvasName, nodeId)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local rule = canvas.attributionRules and canvas.attributionRules[nodeId]
    local text = _formatAttributionRuleText(nodeId, rule, _labelsByIdForCanvas(canvas))

    local options = {}
    if rule and rule.status == "learned" then table.insert(options, "LOCK THIS RULE") end
    table.insert(options, "RETURN")

    _pendingAttributionRuleNodeId = nodeId
    gdsGui_schematic_openMenu(canvasName, text, options, "schematicAttributionRuleDetailChosen",
        "schematicAttributionRuleDetailCancelled", nil, 0.8)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — SUGGEST NEXT SNAPSHOT (Phase 5): surfaces
-- model/suggest.lua's one-flip-from-an-existing-capture heuristic, and lets
-- the user jump the live combination straight to it (APPLY) instead of
-- hunting for an untested combination by hand.
-------------------------------------------------------------------------------

local function _openSuggestNextSnapshotMenu(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local suggestion = ModelSuggest.suggestNextSnapshot(_controlsForSuggest(canvas), _capturedSignaturesSet(canvas))
    if not suggestion then
        gdsGui_schematic_openMenu(canvasName,
            "Every one-flip combination from an existing snapshot is already captured.",
            { "OK" }, "schematicSuggestNextSnapshotDismissed", nil)
        return
    end

    local labelsById = _labelsByIdForCanvas(canvas)
    local parts = {}
    for _, c in ipairs(canvas.controls) do
        local detentIndex = suggestion.detents[c.id]
        local positionLabel = (detentIndex and c.positions and c.positions[detentIndex + 1]) or tostring(detentIndex)
        table.insert(parts, (labelsById[c.id] or c.id) .. "=" .. positionLabel)
    end

    _pendingSuggestedDetents = suggestion.detents
    gdsGui_schematic_openMenu(canvasName, "TRY: " .. table.concat(parts, ", "),
        { "APPLY", "CANCEL" }, "schematicSuggestNextSnapshotChosen", "schematicSuggestNextSnapshotDismissed", nil, 0.8)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — ELECTRICAL COLORS: lets the user pick their own
-- powered/unpowered display color (default yellow/gray — see
-- ELECTRICAL_MEDIUM.style) instead of being stuck with the medium's
-- built-in ones. The SAME style table drives both forward prediction
-- (_solveCurrentSchematic) and backward deduction (_stateForColor/
-- inferGate/findSimplestRule), so picking a color here is what actually
-- "teaches" the inference model to recognize it — paint, prediction, and
-- deduction all stay in lockstep automatically, with no separate step.
--
-- One real caveat, called out in the swatch picker's own title text below
-- rather than hidden: changing this AFTER painting snapshots under the old
-- color doesn't retroactively relabel them. The snapshots still DISPLAY
-- correctly forever (an authored snapshot always wins over a prediction,
-- regardless of color scheme) — but _stateForColor's exact-match lookup
-- against the CURRENT style table means the deduction/rule-learner no
-- longer recognizes that old color as "powered", so a gate whose only
-- evidence came from pre-change snapshots reverts to unknown/noRule until
-- those combinations are re-painted in the new color.
-------------------------------------------------------------------------------

local function _openElectricalColorsMenu(canvasName)
    gdsGui_schematic_openMenu(canvasName, (_currentMedium().name or "ELECTRICAL") .. " COLORS",
        { "POWERED COLOR", "UNPOWERED COLOR", "PER-SOURCE SETTINGS", "RETURN" }, "schematicElectricalColorsChosen", nil)
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — PER-SOURCE SETTINGS: an individual source (BATTERY,
-- GENERATOR, ...) is given a nominal VOLTAGE — its powered color is never
-- set directly any more; it's always whatever color is registered for that
-- VOLTAGE on THIS system (canvas.voltageColors — see
-- _ensureVoltageHasColor), so any two sources sharing a voltage on the
-- same system always read as the same color automatically. Purely a
-- display-layer setting consulted only by _solveCurrentSchematic's color
-- provenance step (see model/solver.lua's solveSourceAttribution), never
-- by the solver's own logical powered/unpowered vocabulary or the
-- deduction/rule-learning pipeline, which stay medium-wide and
-- source-blind exactly as before.
--
-- When a node is reached by more than one currently-active source at once
-- (a genuine tie, e.g. an unisolated bus-tie), _solveCurrentSchematic picks
-- the single highest-VOLTAGE contributor's color outright, as long as
-- every contributor's voltage is known (the higher-voltage source would
-- actually dominate/back-feed the lower one on a real bus) — a tie in
-- voltage no longer needs special-casing, since equal voltages already
-- share the identical registered color. Only when voltage is genuinely
-- unset on some contributor does it fall back to an alternating dashed mix
-- of every contributor's color.
-------------------------------------------------------------------------------

-- The palette name of the color currently registered for a voltage ON THIS
-- SYSTEM (canvas.voltageColors — see _ensureVoltageHasColor), or
-- "UNASSIGNED" if that voltage has no color yet (nil voltage reads as
-- "? V" by its caller instead of hitting this).
local function _voltageColorDescription(canvas, voltage)
    local c = canvas.voltageColors and canvas.voltageColors[voltage]
    if not c then return "UNASSIGNED" end
    for i = 1, 5 do
        local paletteColor, paletteName = gdsGui_schematic_getColorPaletteEntry(i)
        if paletteColor and paletteColor[1] == c[1] and paletteColor[2] == c[2]
           and paletteColor[3] == c[3] and (paletteColor[4] or 1) == (c[4] or 1) then
            return paletteName
        end
    end
    return "CUSTOM"
end

local function _openPerSourceSettingsListMenu(canvasName)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local sourceIds = _sortedSourceIds(canvas)
    local labelsById = _labelsByIdForCanvas(canvas)

    local unit = _currentMedium().magnitudeUnit or "V"
    local options = {}
    for _, id in ipairs(sourceIds) do
        local entity = _findSourceEntity(canvas, id)
        local voltage = entity and entity.voltage
        local voltageDescription = voltage and (voltage .. unit) or ("? " .. unit)
        local colorDescription = voltage and _voltageColorDescription(canvas, voltage) or "default"
        table.insert(options, (labelsById[id] or id) .. " (" .. voltageDescription .. ", " .. colorDescription .. ")")
    end
    table.insert(options, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "PER-SOURCE SETTINGS", options, "schematicPerSourceSettingsListChosen", nil, nil, 0.85)
end

local function _openPerSourceSettingDetailMenu(canvasName, sourceId)
    _pendingPerSourceTargetId = sourceId
    local canvas = _findSchematicCanvas()
    local labelsById = canvas and _labelsByIdForCanvas(canvas) or {}
    gdsGui_schematic_openMenu(canvasName, labelsById[sourceId] or sourceId,
        { _currentMedium().magnitudeLabel or "VOLTAGE", "RETURN" },
        "schematicPerSourceSettingDetailChosen", "schematicPerSourceSettingDetailCancelled")
end

-- Full SELECT SYSTEM list — only ever shown for a system with no fixed
-- systemType (legacy data saved before systems were typed; see _openAddMenu).
local function _openSystemSelectMenu(canvasName)
    local names = {}
    for _, sys in ipairs(SCHEMATIC_CATALOG) do table.insert(names, sys.system) end
    table.insert(names, "RETURN")
    gdsGui_schematic_openMenu(canvasName, "SELECT SYSTEM", names, "schematicCatalogSystemChosen", nil)
end

-- 1st level of the ADD cascade now: one button per model/graph.lua node
-- role that at least one of sys's own catalog items actually declares
-- ("directionalGate" shown as FLOW — see the Learn page's own "ONE-WAY
-- GATE" explanation of the same concept under friendlier words), in the
-- order a user naturally thinks about a flow network: what starts it,
-- what carries it, what blocks it, which way it's allowed, where it ends.
-- A role with zero matching items for THIS system (ELECTRICAL/BLEED AIR
-- have no "sink"-tagged item yet) just isn't offered — nothing to drill
-- into. OTHER covers any catalog item with no role at all (PRESSURIZATION's
-- CONTROLLER/MODE SWITCH — see those entries' own comments for why
-- they're deliberately untagged), only shown when sys actually has one.
-- ANNUNCIATOR is appended last instead of a RETURN row (RETURN's old
-- spot) — it's a catalog-wide item, not nested under any one role (see
-- gdsGui_schematic_armAnnunciatorCreation), so it shows the same
-- regardless of sys. There's still a way back up: the dedicated ACTIONS
-- button (schematicContextButtonPressed) reaches _openDesignActionsMenu
-- directly, so this level doesn't need its own RETURN row to get there.
-- Global, not local like its sibling helpers in this section — this file
-- is already at Lua's 200-top-level-local ceiling (see _LEARN_SCHEMATIC_RAW's
-- own comment on the same constraint), and this function's two callers
-- (_openAddMenu, schematicCatalogSystemChosen) call it just as well
-- through a global lookup.
function _openFundamentalsMenu(canvasName, sys)
    local roleOrder  = { "directionalGate", "source", "path", "gate", "sink" }
    local roleLabels = { directionalGate = "FLOW", source = "SOURCE", path = "PATH", gate = "GATE", sink = "SINK" }
    local present, hasOther = {}, false
    for _, item in ipairs(sys.items) do
        if item.componentType then present[item.componentType] = true else hasOther = true end
    end
    -- SINK always shows regardless of present["sink"] -- unlike the other
    -- four roles, every system gets this button up front even before any
    -- sink-tagged catalog item exists for it (ELECTRICAL/BLEED AIR don't
    -- yet). Tapping it just opens _openTypeMenu's own empty-list-plus-
    -- RETURN case until one does -- deliberately blank for now, not a bug.
    present.sink = true
    local names = {}
    for _, role in ipairs(roleOrder) do
        if present[role] then table.insert(names, roleLabels[role]) end
    end
    if hasOther then table.insert(names, "OTHER") end
    table.insert(names, "ANNUNCIATOR")
    -- Half the default menu width (0.8 of the canvas) — a short list of
    -- single-word button names doesn't need the full-width box.
    gdsGui_schematic_openMenu(canvasName, "ADD:", names, "schematicFundamentalChosen", nil, nil, 0.4)
end

-- 2nd level: every one of sys's own catalog items whose componentType
-- matches role ("OTHER" — see _openFundamentalsMenu above — matches an
-- item with none at all). PATH's own list gets one extra CONNECTOR row
-- appended, when the canvas actually has something to connect FROM (see
-- schematicCatalogItemChosen's own CONNECTOR branch below) — a plain wire
-- is itself a "path" in every sense that matters here, it just has no
-- fixed element/control shape to place and so no catalog entry of its own
-- (wires were never a catalog "kind" — see that same branch's comment).
-- RETURN steps back up to the fundamentals menu.
local function _openTypeMenu(canvasName, sys, role)
    local names = {}
    for _, item in ipairs(sys.items) do
        local matches = (role == "OTHER" and not item.componentType) or item.componentType == role
        if matches then table.insert(names, item.label) end
    end
    if role == "path" then
        local canvas = _findSchematicCanvas()
        if canvas and (#canvas.elements + #canvas.controls) > 0 then
            table.insert(names, "CONNECTOR")
        end
    end
    table.insert(names, "RETURN")
    -- Half the default menu width (0.8 of the canvas) — a short list of
    -- single-word item names doesn't need the full-width box.
    gdsGui_schematic_openMenu(canvasName, "ADD:", names, "schematicCatalogItemChosen", nil, nil, 0.4)
end

function schematicConnectorFromChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        if _catalogChosenSystem then _openTypeMenu(canvasName, _catalogChosenSystem, "path") end
        return
    end
    local fromId = _controlMenuIds[index]
    if not fromId then return end
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    -- Disarm any other pending placement/pick first (see
    -- gdsGui_schematic_armElementPlacement's own comment on why), then arm
    -- this one — same two-step order gdsGui_schematic_internal_
    -- onElementEditChosen's own ADD WIRE branch uses.
    gdsGui_schematic_cancelPlacement(canvasName)
    canvas.pendingWireFromId = fromId
end

-- The catalog entry matching the currently-open system's fixed type, or nil
-- for a legacy/untyped system (pre-dates "one system type per aircraft").
local function _currentSystemCatalogEntry()
    local sys = _findSystem(schematicStore.currentSystemId)
    return sys and sys.systemType and _findCatalogEntryForType(sys.systemType) or nil
end

-- ADD ELEMENT/CONTROL entry point: a typed system already knows which
-- catalog branch it belongs to, so it jumps straight to that FUNDAMENTALS
-- menu instead of making the user pick a system that's already decided.
-- Only a legacy/untyped system falls back to the full SELECT SYSTEM list.
local function _openAddMenu(canvasName)
    local entry = _currentSystemCatalogEntry()
    if entry then
        _catalogChosenSystem = entry
        _openFundamentalsMenu(canvasName, entry)
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
    _openFundamentalsMenu(canvasName, sys)
end

-- FUNDAMENTALS button tapped: FLOW/SOURCE/PATH/GATE/SINK drill into that
-- role's own item list (_openTypeMenu); OTHER drills into the untagged
-- one; ANNUNCIATOR jumps straight to the name prompt instead (catalog-
-- wide, not nested under any role — see _openFundamentalsMenu above).
function schematicFundamentalChosen(canvasName, index, optionText)
    if optionText == "ANNUNCIATOR" then
        gdsGui_schematic_armAnnunciatorCreation(canvasName)
        return
    end
    local sys = _catalogChosenSystem
    if not sys then return end
    if optionText == "OTHER" then
        _openTypeMenu(canvasName, sys, "OTHER")
        return
    end
    local roleByLabel = { FLOW = "directionalGate", SOURCE = "source", PATH = "path", GATE = "gate", SINK = "sink" }
    local role = roleByLabel[optionText]
    if not role then return end
    _openTypeMenu(canvasName, sys, role)
end

function schematicCatalogItemChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        if _catalogChosenSystem then _openFundamentalsMenu(canvasName, _catalogChosenSystem) end
        return
    end
    if optionText == "CONNECTOR" then
        -- Lets the user pick ANY already-placed element or control as a
        -- wire's starting point, without first having to tap that item's
        -- own body and open its edit menu. Arms the exact same one-shot
        -- "stay armed, drag the loose end to whatever it should connect
        -- to" mechanism ADD WIRE on an element's/control's own edit menu
        -- already arms (gdsGui_schematic_internal_onElementEditChosen/
        -- onControlEditChosen's own canvas.pendingWireFromId — _findAnchor
        -- resolves either kind of id just as readily) — that existing
        -- per-item shortcut is completely untouched by this; both paths
        -- into the same wire-drawing flow now exist side by side.
        -- Reuses _controlMenuIds (see the CONTROL-MODE "SELECT CONTROL"
        -- menu further below, its other user) purely as a scratch "menu
        -- row -> id" map — the two flows are never open at once, and this
        -- rebuilds it fresh every time it opens anyway. No separate
        -- top-level local function for this — it has exactly one caller.
        local canvas = _findSchematicCanvas()
        if not canvas then return end
        _controlMenuIds = {}
        local names = {}
        for _, e in ipairs(canvas.elements) do
            table.insert(_controlMenuIds, e.id)
            table.insert(names, e.label or e.id)
        end
        for _, c in ipairs(canvas.controls) do
            table.insert(_controlMenuIds, c.id)
            table.insert(names, c.label or c.id)
        end
        table.insert(names, "RETURN")
        gdsGui_schematic_openMenu(canvasName, "CONNECTOR FROM:", names, "schematicConnectorFromChosen", nil)
        return
    end
    -- Matched by label, not index — _openTypeMenu's own list is filtered
    -- to one role at a time now, so a row's position in that list no
    -- longer lines up with its position in sys.items (labels are unique
    -- within one system, same assumption _currentSystemCatalogEntry's
    -- whole catalog already relies on).
    local sys = _catalogChosenSystem
    local item = nil
    if sys then
        for _, candidate in ipairs(sys.items) do
            if candidate.label == optionText then item = candidate; break end
        end
    end
    if not item then return end
    -- No "connector" kind left in SCHEMATIC_CATALOG — ADD WIRE on an
    -- element's own edit menu, or CONNECTOR above, cover that now (see
    -- gdsGui_schematic_internal_onElementEditChosen).
    if item.kind == "element" then
        gdsGui_schematic_armElementPlacement(canvasName, item.shapeType, item.abbrev or item.label, nil, item.label,
            item.defaultProperties, item.spritePath, item.gridW, item.gridH, item.componentType)
    elseif #item.presets == 1 then
        gdsGui_schematic_armControlPlacement(canvasName, item.presets[1], item.abbrev or item.label, item.callbackFunc, item.label,
            item.spritePaths, item.overlaySpritePath, item.gridSize, item.colorDarkenMul, item.componentType)
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
        if _catalogChosenSystem and _catalogChosenControlItem then
            _openTypeMenu(canvasName, _catalogChosenSystem, _catalogChosenControlItem.componentType or "OTHER")
        end
        _catalogChosenControlItem = nil
        return
    end
    local item = _catalogChosenControlItem
    if not item then return end
    local preset = item.presets[index]
    gdsGui_schematic_armControlPlacement(canvasName, preset, item.abbrev or item.label, item.callbackFunc, item.label,
        item.spritePaths, item.overlaySpritePath, item.gridSize, item.colorDarkenMul, item.componentType)
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
-- mode only): the sole entry point into the ADD cascade ((SYSTEM >)
-- FUNDAMENTALS > TYPE > POSITIONS, see _openAddMenu), now that it's no
-- longer one of the ACTIONS menu's options. Same reentrancy guard as
-- schematicContextButtonPressed below — opening a brand new top-level menu
-- while a cascade from either entry point is already mid-flight would
-- silently clobber it and orphan its tracking locals (see
-- gdsGui_schematic_isMenuOpen).
-- Activating a dock tool moves its button up to the top dock slot (ADD's)
-- and hides the other tools until it's deactivated, so its popup — which
-- always opens just left of the dock at the canvas's top edge (see
-- _toolPopupOrigin in schematic_gdsGuiLib.lua) — sits right beside it.
local function _enterSchematicTool(tool)
    _activeSchematicTool = tool
    local topY = _schematicDockSlotY[_SCHEMATIC_DOCK_TOOLS.add]
    for t, name in pairs(_SCHEMATIC_DOCK_TOOLS) do
        if t == tool then
            gdsGui_button_setPosition(name, _schematicDockX, topY)
        else
            gdsGui_button_setHidden(name, true)
        end
    end
end

-- Puts every dock tool back in its normal slot. Only unhides them in design
-- mode — a mode switch to control mode ends the active tool too (setMode
-- clears paint/panel/menu state), and the dock stays hidden there.
local function _exitSchematicTool()
    if not _activeSchematicTool then return end
    _activeSchematicTool = nil
    gdsGui_schematic_setMenuAnchorButton("mainCanvas", nil)
    local designing = gdsGui_schematic_getMode("mainCanvas") == "design"
    for _, name in pairs(_SCHEMATIC_DOCK_TOOLS) do
        gdsGui_button_setPosition(name, _schematicDockX, _schematicDockSlotY[name])
        gdsGui_button_setHidden(name, not designing)
        if designing then gdsGui_button_setState(name, "released") end
    end
end

-- Whether the active tool still has anything open — polled every frame in
-- love.update() so a tool that ends on its own (ADD's flow finishing or
-- being cancelled, a mode switch, a system reload) restores the dock the
-- same as the user toggling the tool's own button off.
local function _schematicToolStillActive(tool)
    if tool == "paint" then
        return gdsGui_schematic_isPaintModeActive("mainCanvas")
    elseif tool == "annunciator" then
        return gdsGui_schematic_isAnnunciatorPanelOpen("mainCanvas")
    elseif tool == "add" then
        -- Any step of the ADD flow: a catalog menu, an armed tap-to-place,
        -- or the NAME THIS ... prompt that follows the tap.
        return gdsGui_schematic_isMenuOpen("mainCanvas") or gdsGui_schematic_isPlacementArmed("mainCanvas")
            or gdsGui_textPrompt_isOpen()
    end
    return false
end

-- Dedicated "+" dock button (schematicAddBtn, top-right of the canvas, design
-- mode only): the sole entry point into the ADD cascade ((SYSTEM >)
-- FUNDAMENTALS > TYPE > POSITIONS, see _openAddMenu). A sticky toggle like
-- PAINT/ANNUNCIATOR:
-- switching it on opens the cascade pinned beside the dock; switching it
-- off abandons whatever step of the flow is open. Same reentrancy guard as
-- schematicContextButtonPressed below — opening a brand new top-level menu
-- while another cascade is already mid-flight would silently clobber it and
-- orphan its tracking locals (see gdsGui_schematic_isMenuOpen).
function schematicAddBtnPressed(newState)
    if newState == globApp.BUTTON_STATES.PRESSED then
        if gdsGui_schematic_isMenuOpen("mainCanvas") or gdsGui_schematic_getMode("mainCanvas") ~= "design" then
            gdsGui_button_setState("schematicAddBtn", "released")
            return
        end
        _enterSchematicTool("add")
        gdsGui_schematic_setMenuAnchorButton("mainCanvas", "schematicAddBtn")
        _openAddMenu("mainCanvas")
    else
        gdsGui_schematic_closeMenu("mainCanvas")
        gdsGui_schematic_cancelPlacement("mainCanvas")
        _exitSchematicTool()
    end
end

-- Dedicated brush dock button (schematicPaintBtn, just below ADD): a sticky
-- toggle, so newState reflects which way it was just switched (see the
-- button's own "toggle" type comment at its gdsGui_button_create call) —
-- armed/disarmed directly rather than via gdsGui_schematic_togglePaintMode,
-- so this always matches what the button itself just displayed regardless
-- of whether the library's paintMode had already been disarmed some other
-- way (a mode switch or project reload — see love.update's poll below,
-- which corrects the button back to "released" when that happens; a drag
-- on empty canvas space while armed just pans the view instead, it's not a
-- disarm). No
-- isMenuOpen reentrancy guard needed, unlike schematicAddBtnPressed above —
-- gdsGui_schematic_pressed checks canvas.menu before ever consulting
-- canvas.paintMode, so arming it under an open menu is inert until that
-- menu closes, not a clobber.
function schematicPaintBtnPressed(newState)
    if newState == globApp.BUTTON_STATES.PRESSED then
        gdsGui_schematic_armPaintMode("mainCanvas")
        _enterSchematicTool("paint")
    else
        gdsGui_schematic_disarmPaintMode("mainCanvas")
        _exitSchematicTool()
    end
end

-- Dedicated annunciator dock button (schematicAnnunciatorBtn, just below
-- PAINT): same sticky-toggle convention as schematicPaintBtnPressed above —
-- newState reflects which way it was just switched, and love.update's poll
-- (see _prevSchematicAnnunciatorPanelOpen) corrects it back to "released" if
-- the panel ever closes some other way (mode switch, or PAINT/ADD taking
-- over via gdsGui_schematic_cancelPlacement).
function schematicAnnunciatorBtnPressed(newState)
    local open = newState == globApp.BUTTON_STATES.PRESSED
    gdsGui_schematic_setAnnunciatorPanelOpen("mainCanvas", open)
    if open then _enterSchematicTool("annunciator") else _exitSchematicTool() end
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
    if optionText == "CLEAR THIS SNAPSHOT" then
        -- Only ever reaches here via the sustained hold DESIGN ACTIONS'
        -- own confirmRows gates it behind (see _openDesignActionsMenu
        -- above) — a plain tap-release on this row is swallowed before
        -- onSelect ever fires. Deletes only the snapshot for whichever
        -- control-position combination is currently showing, not every
        -- snapshot on the system (that's CLEAR ALL SNAPSHOTS' job).
        -- Undo-able: pushed onto the undo stack first, same as CLEAR PAGE,
        -- so "UNDO LAST ACTION" brings it back.
        gdsGui_schematic_pushUndo(canvasName)
        gdsGui_schematic_removeSnapshot(canvasName, gdsGui_schematic_computeSignature(canvasName))
        -- Same reasoning as every snapshot-commit call site (capture,
        -- OVERWRITE, CAPTURE AS SHOWN/ANYWAY): removing a snapshot changes
        -- the evidence canvas.rules/attributionRules were learned from, so
        -- the AI panel's confidence score (read off those tables once this
        -- combination no longer has an exact snapshot of its own) must be
        -- rebuilt here too, not left scored off a rule that may have
        -- counted the just-deleted snapshot as one of its examples.
        _recomputeDeducedGateStates()
        _applySolvedColorsToCurrentCombination()
        _schematicDirty = true
        _saveCurrentSystem()
    elseif optionText == "CLEAR ALL SNAPSHOTS" then
        -- Only ever reaches here via the sustained hold DESIGN ACTIONS'
        -- own confirmRows gates it behind — same "the hold IS the
        -- confirmation" treatment as CLEAR PAGE below, no separate
        -- CONTINUE/CANCEL popup. Wipes every snapshot AND every learned/
        -- locked gate/attribution rule on the system while leaving the
        -- elements/wires/controls/annunciators themselves untouched —
        -- "start teaching the engine over" without rebuilding the diagram.
        -- Undo-able, same as every other destructive row here.
        local canvas = _findSchematicCanvas()
        if canvas then
            gdsGui_schematic_pushUndo(canvasName)
            canvas.snapshots = {}
            -- Cleared outright (not left to _recomputeDeducedGateStates'
            -- own _recomputeGateRules/_recomputeAttributionRules passes
            -- below) — specifically to override those passes' usual
            -- "never touch a LOCKED rule" protection — this is meant to
            -- wipe every taught rule, confirmed or not, same as
            -- _clearMainCanvas' own unconditional canvas.rules = {} on a
            -- full CLEAR PAGE.
            canvas.rules = {}
            canvas.attributionRules = {}
            _recomputeDeducedGateStates()
            _applySolvedColorsToCurrentCombination()
            _schematicDirty = true
            _saveCurrentSystem()
            _setSnapshotLabelText(0)
        end
    elseif optionText == "UNDO LAST ACTION" then
        gdsGui_schematic_undo(canvasName)
        _schematicDirty = true
        _saveCurrentSystem()
    elseif optionText == "GATE RULES" then
        _openGateRulesListMenu(canvasName)
    elseif optionText == "ATTRIBUTION RULES" then
        _openAttributionRulesListMenu(canvasName)
    elseif optionText == "SUGGEST NEXT SNAPSHOT" then
        _openSuggestNextSnapshotMenu(canvasName)
    elseif optionText == (_currentMedium().name or "ELECTRICAL") .. " COLORS" then
        _openElectricalColorsMenu(canvasName)
    elseif optionText == "CLEAR PAGE" then
        -- CLEAR PAGE only ever reaches here via the sustained hold the
        -- DESIGN ACTIONS menu's own confirmRows gates it behind (see
        -- _openDesignActionsMenu above) — a plain tap-release on this row is
        -- swallowed before onSelect ever fires. Safe to act immediately.
        -- Wipes every element/wire/control/snapshot from the live canvas and
        -- persists the now-blank page. Irreversible, hence the hold (and
        -- hence pushing an undo snapshot first, so "UNDO LAST ACTION" can
        -- bring it all back).
        gdsGui_schematic_pushUndo(canvasName)
        _clearMainCanvas()
        _schematicDirty = true
        _saveCurrentSystem()
        _setSnapshotLabelText(0)
    end
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

-- The systems gallery's header reads "<AIRCRAFT NAME> SYSTEMS" once an
-- aircraft is open, so it's clear at a glance whose systems are listed.
local function _aircraftSystemsTitle(aircraft)
    return string.upper(aircraft.name) .. " SYSTEMS"
end

-- Keeps the "MY AIRCRAFT" button in sync with whether there's anything to
-- open; called whenever SchematicHome is (re)entered and after an aircraft
-- is deleted.
local function _refreshSchematicHomeAvailability()
    gdsGui_button_setState("schematicHomeMyAircraft",
        (#schematicStore.aircraft > 0) and "released" or "deactivated")
end

-- Opens the NAME NEW AIRCRAFT prompt directly.
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
    -- DELETE (index 3) is this menu's own confirmIndex row — holding IT down
    -- for the usual hold duration is the whole confirmation, no separate
    -- "DELETE \"X\"?" popup. OPEN AIRCRAFT/RENAME/CANCEL stay plain-tap.
    gdsGui_schematicGallery_openMenu(galleryName, aircraft.name,
        {"OPEN AIRCRAFT", "RENAME", "DELETE", "CANCEL"},
        "schematicAircraftActionChosen", nil, 3)
end

-- Deleting an aircraft cascades to every system it owns (they live only
-- inside its .systems array — nothing else references them). DELETE only
-- ever reaches here via the sustained hold the gallery menu's own
-- confirmIndex gates it behind (see schematicAircraftGallerySelected above)
-- — a plain tap-release on that row is swallowed before onSelect ever
-- fires. Safe to act immediately.
function schematicAircraftActionChosen(galleryName, index, optionText)
    if optionText == "OPEN AIRCRAFT" then
        schematicStore.currentAircraftId = _manageMenuAircraftId
        navGoToAircraftSystems()
    elseif optionText == "RENAME" then
        local aircraft = _findAircraft(_manageMenuAircraftId)
        if aircraft then
            gdsGui_textPrompt_open("RENAME AIRCRAFT", aircraft.name, 24, "schematicAircraftRenameConfirmed", nil)
        end
    elseif optionText == "DELETE" and _manageMenuAircraftId then
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
        _manageMenuAircraftId = nil
        -- Deleted the last aircraft: AircraftGallery would otherwise just
        -- sit there empty, so step back up to SchematicHome where NEW
        -- AIRCRAFT is one tap away instead of two.
        if #schematicStore.aircraft == 0 then
            _navSyncAll("SchematicHome")
            gdsGui_page_switch("LoadingSchematicHome", 9, 2, false)
        end
    end
    -- "CANCEL" (or tapping outside), OPEN AIRCRAFT, and RENAME all
    -- leave _manageMenuAircraftId set — RENAME's text prompt confirms later,
    -- asynchronously, and still needs it; it's simply overwritten next time
    -- an aircraft tile is tapped.
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
        -- DELETE (index 3) is this menu's own confirmIndex row — holding IT
        -- down for the usual hold duration is the whole confirmation, no
        -- separate "DELETE \"X\"?" popup.
        gdsGui_schematicGallery_openMenu(galleryName, sys.name,
            {"OPEN IN CONTROL MODE", "OPEN IN DESIGN MODE", "DELETE", "CANCEL"},
            "schematicSystemActionChosen", nil, 3)
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

-- DELETE only ever reaches here via the sustained hold the gallery menu's
-- own confirmIndex gates it behind (see schematicSystemGallerySelected
-- above) — a plain tap-release on that row is swallowed before onSelect
-- ever fires. Safe to act immediately.
function schematicSystemActionChosen(galleryName, index, optionText)
    if optionText == "OPEN IN CONTROL MODE" then
        _openSystemIntoCanvas(_manageMenuSystemId, "control")
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
    elseif optionText == "OPEN IN DESIGN MODE" then
        _openSystemIntoCanvas(_manageMenuSystemId, "design")
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
    elseif optionText == "DELETE" and _manageMenuSystemId then
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
        _manageMenuSystemId = nil
    end
    -- "CANCEL" (or tapping outside): no-op, _manageMenuSystemId is overwritten next time.
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
        {name="schematicLearnContent", raw=_LEARN_SCHEMATIC_RAW},
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
        "dutyLearnContent", "settingsLearnContent", "schematicLearnContent",
        -- page header titles (all pages) — schematic_pageTitle and the
        -- three schematic header readouts (zoom/snapshot/combination) are
        -- handled separately below: unlike every other page's title/
        -- readout, their text is variable-length (a user-renameable system
        -- name; a growing snapshot/combination count; a trailing
        -- " (PREDICTED)"), so they need the shrink-to-fit variant instead
        -- of a flat setFontSize (see gdsGui_outputTxtBox_setFontSizeToFit's
        -- comment) to guarantee they never wrap onto a second line.
        "mainMenu_pageTitle", "learn_pageTitle", "settings_pageTitle", "tc_pageTitle",
        "schematicHome_pageTitle", "schematicManage_pageTitle",
        "aircraftGallery_pageTitle",
        -- terms and conditions body
        "tcText",
    }
    for _, name in ipairs(names) do
        gdsGui_outputTxtBox_setFontSize(name, fontSize)
    end
    gdsGui_outputTxtBox_setFontSizeToFit("schematic_pageTitle", fontSize, 10)
    -- Re-fit each at whatever text is CURRENTLY showing rather than
    -- recomputing it — idempotent, same "re-display what's already there
    -- at the new size" shape as schematic_pageTitle just above. Safe
    -- before any system is ever opened too: mainCanvas (and its empty
    -- snapshots table) already exists by the time love.load() first calls
    -- this (see gdsGui_schematic_create's own call site), and
    -- _prevSchematicZoomText/_prevSchematicCombText fall back to each
    -- box's own initial create-time text before the first live poll ever
    -- runs (see the per-frame polling block further down).
    _setSnapshotLabelText(gdsGui_schematic_countSnapshots("mainCanvas"))
    _setHeaderReadoutText("schematicZoomLabel", _prevSchematicZoomText or "1.0x", 10)
    _setHeaderReadoutText("schematicCombLabel", _prevSchematicCombText or "[1/1]", 8)
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
        {"schematicLearnContent", _LEARN_SCHEMATIC_RAW},
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
    -- Which schematic-flow page (SchematicHome/AircraftGallery/
    -- SchematicManageGallery/SystemSchematic) the app was sitting on the last
    -- time it quit or was backgrounded (see love.quit/love.focus below), or
    -- nil if it wasn't in the schematic flow at all — lets a cold boot resume
    -- straight back into that exact page (and system/mode, for the canvas)
    -- instead of always landing on MainMenu first.
    if appSettings.schematicLastPage == nil then appSettings.schematicLastPage = false end
    -- A user-chosen override for the ELECTRICAL medium's powered/unpowered
    -- display colors (see schematicPoweredColorChosen/
    -- schematicUnpoweredColorChosen below) — nil means "use
    -- model/media/electrical.lua's own default yellow/gray". Applied here,
    -- once, since ELECTRICAL_MEDIUM is a single shared module table
    -- (require() caches it) consulted by both forward prediction
    -- (_solveCurrentSchematic) and backward deduction (_stateForColor) —
    -- overriding it here keeps both consistent without touching either.
    if appSettings.electricalPoweredColor then ELECTRICAL_MEDIUM.style.powered = appSettings.electricalPoweredColor end
    if appSettings.electricalUnpoweredColor then ELECTRICAL_MEDIUM.style.unpowered = appSettings.electricalUnpoweredColor end
    -- Voltage -> powered color is PER-SYSTEM (canvas.voltageColors — see
    -- _clearMainCanvas/_openSystemIntoCanvas below), not an appSettings
    -- global: every source sharing a nominal VOLTAGE within the SAME system
    -- shares a display color automatically, picked once (see
    -- _ensureVoltageHasColor) and reused for the rest of that system's
    -- life — but a fresh system (a brand new one, or re-creating one after
    -- deleting it or its whole aircraft) starts with no voltage colors
    -- taught at all, same as it starts with no snapshots/rules taught.
    _syncPaidLoadingScreenSkip()

    -- Loads the aircraft/systems store (see _loadSchematicStoreSafely for the
    -- corrupt-file/backup fallback chain this now goes through); migrates a
    -- pre-existing single-design save (from before projects existed) or a
    -- flat project list (from before aircraft existed) into one aircraft's
    -- systems, or seeds a demo system on a genuinely fresh install, so Home's
    -- NEW/MY AIRCRAFT galleries are never confusingly empty on first run.
    local _schematicLoadStatus = _loadSchematicStoreSafely()
    -- Captured here, before the nil/legacy-migration branches below (or the
    -- repair save further down) can touch schematicStore.savedByAppVersion —
    -- see _schematicJustUpdatedNoSystemOpen's declaration above.
    _schematicJustUpdatedNoSystemOpen = schematicStore ~= nil
        and schematicStore.savedByAppVersion ~= nil
        and schematicStore.savedByAppVersion ~= APP_VERSION
        and schematicStore.currentSystemId == nil
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
        _saveSchematicStore()
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
        _saveSchematicStore()
    end

    -- Structural + duplicate-id repair always runs (cheap, protective, not
    -- tied to app updates) — only the user-facing notice about it is gated
    -- to once per APP_VERSION, mirroring tcAcceptedVersion's own one-time-
    -- per-version pattern just above.
    local _schematicRepair = _verifyAndRepairSchematicStore(schematicStore)
    if appSettings.schematicCompatCheckedVersion ~= APP_VERSION then
        _pendingSchematicCompatNotice = _buildSchematicCompatNotice(_schematicLoadStatus, _schematicRepair)
        appSettings.schematicCompatCheckedVersion = APP_VERSION
        _saveAppSettings()
    end
    if #_schematicRepair.notes > 0 then
        _saveSchematicStore()
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
    local requiredFPMtext = _formatRequiredFPM(selectedAltitude, selectedTime)
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

    gdsGui_container_create("schematicLearn", "Learn", "SYSTEM SCHEMATICS", 32, 0)
    gdsGui_outputTxtBox_create("schematicLearnContent", "Learn", nil,
        learnTxtX, 10, "CT",
        learnTxtW, learnH(_LEARN_SCHEMATIC_RAW),
        {1, 1, 1, 1}, _learnSegsColored(_LEARN_SCHEMATIC_RAW, true),
        learnFontSize, "schematicLearn"
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
    gdsGui_button_create("schematicAddBtn", "SystemSchematic", "toggle",
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
    -- AI: docked directly below ANNUNCIATOR, same floating-chrome
    -- convention and sticky "toggle" type (stays open across any number of
    -- taps, same as PAINT/ANNUNCIATOR). Deliberately NOT one of
    -- _SCHEMATIC_DOCK_TOOLS' mutually-exclusive set, unlike those three —
    -- it's a read-only info overlay (see drawSchematicAiPanel), so there's
    -- no reason it couldn't stay open alongside PAINT or an ADD placement;
    -- it just sits in its own fixed slot below them, toggled independently
    -- (schematicAiBtnPressed). Design-mode only, same enable/disable
    -- gating SNAPSHOT/ADD/PAINT/ANNUNCIATOR use.
    gdsGui_button_create("schematicAiBtn", "SystemSchematic", "toggle",
        "Sprites/button_schematicAi_pressed.png",
        "Sprites/button_schematicAi_released.png",
        "Sprites/button_schematicAi_deactivated.png",
        0.97, schCanvasYFrac + 3 * (36 + 10) / globApp.safeScreenArea.h, "RT", 36, 36,
        "schematicAiBtnPressed", globApp.BUTTON_STATES.RELEASED, true, nil
    )
    _schematicDockX = 0.97
    _schematicDockSlotY[_SCHEMATIC_DOCK_TOOLS.add]         = schCanvasYFrac
    _schematicDockSlotY[_SCHEMATIC_DOCK_TOOLS.paint]       = schCanvasYFrac + (36 + 10) / globApp.safeScreenArea.h
    _schematicDockSlotY[_SCHEMATIC_DOCK_TOOLS.annunciator] = schCanvasYFrac + 2 * (36 + 10) / globApp.safeScreenArea.h
    -- COMBINATION PREV/NEXT — design-mode-only, fixed at the left/right
    -- edges of the screen (containerName nil, so like every other floating
    -- schematic chrome button they're positioned straight off safeScreenArea
    -- and never move with the canvas's own pan/zoom). Anchored bottom (LB/RB)
    -- at the AI panel's own top edge (_aiPanelRect: cy + ch*(1-0.25), same
    -- 0.25 panelH fraction) so the buttons sit flush atop the panel instead
    -- of overlapping it once it's open. Each press walks the control-position
    -- combination counter one step (see gdsGui_schematic_stepCombination) —
    -- deactivated whenever there's nothing to cycle (control mode, or fewer
    -- than 2 total combinations), see the per-frame poll in love.update()
    -- below.
    local schCombBtnYFrac = schCanvasYFrac + schCanvasHFrac * 0.75
    gdsGui_button_create("schematicCombPrevBtn", "SystemSchematic", "pushonoff",
        "Sprites/button_schematicCombPrev_pressed.png",
        "Sprites/button_schematicCombPrev_released.png",
        "Sprites/button_schematicCombPrev_deactivated.png",
        0, schCombBtnYFrac, "LB", 32, 64,
        "schematicCombPrevPressed", globApp.BUTTON_STATES.DEACTIVATED, true, nil
    )
    gdsGui_button_create("schematicCombNextBtn", "SystemSchematic", "pushonoff",
        "Sprites/button_schematicCombNext_pressed.png",
        "Sprites/button_schematicCombNext_released.png",
        "Sprites/button_schematicCombNext_deactivated.png",
        1, schCombBtnYFrac, "RB", 32, 64,
        "schematicCombNextPressed", globApp.BUTTON_STATES.DEACTIVATED, true, nil
    )
    -- One header row, left to right: ZOOM (shortest, fixed-ish length —
    -- "999.9x" never gets much longer) — SNAPSHOT — COMBINATION (longest
    -- and most variable, since it can grow a trailing " (PREDICTED)" — see
    -- its own creation comment below). ZOOM moved to the far left (was
    -- 0.52, center-ish) specifically to free up the wide middle-to-right
    -- span for the other two, which need it far more. All three rely on
    -- _setHeaderReadoutText's shrink-to-fit, not generous width alone, to
    -- actually guarantee no wrap — the widths below are a reasonable
    -- starting budget, not a hard requirement to fit at full font size.
    gdsGui_outputTxtBox_create("schematicZoomLabel", "SystemSchematic", nil,
        0.02, schLabelYFrac, "LT", _w(55), 20,
        colorYellow, "1.0x", 12, nil
    )
    gdsGui_outputTxtBox_create("schematicSnapshotLabel", "SystemSchematic", nil,
        0.21, schLabelYFrac, "LT", _w(85), 20,
        colorYellow, "SNAP: 0", 12, nil
    )
    -- COMBINATION readout — [current/total] of every possible control-
    -- position combination, plus a checkmark that's green once a snapshot
    -- has been captured for whichever combination is currently showing
    -- (gray/empty otherwise), and a trailing " (PREDICTED)" (Phase 5) when
    -- the shown color is only a model guess, not an authored snapshot —
    -- by far the longest string any of these three readouts ever shows, so
    -- it gets the largest share of the row, immediately left of
    -- schematicCombCheckIcon.
    gdsGui_outputTxtBox_create("schematicCombLabel", "SystemSchematic", nil,
        0.49, schLabelYFrac, "LT", _w(140), 20,
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
    gdsGui_schematic_setBackgroundImage("mainCanvas", CANVAS_BACKGROUND_DEFAULT)
    gdsGui_schematic_setCornerBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvasCorner.png")
    gdsGui_schematic_setCornerRightBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvasCornerRight.png")
    gdsGui_schematic_setCornerTopRightBackgroundImage("mainCanvas", "Sprites/bg_schematicCanvasCornerTopRight.png")
    -- Fires on every design-mode edit (add/move/rotate/recolor/rename/
    -- delete/property change — see _notifyChanged in schematic_gdsGuiLib.lua),
    -- so in-progress work survives a quit/background without waiting for the
    -- next page-nav save point.
    _findSchematicCanvas().onChange = "schematicCanvasChanged"
    -- Fires once, right after a freshly-placed element/control is named —
    -- see schematicSourceElementPlaced below, which chains straight into the
    -- VOLTAGE prompt for a "source"-role item (BATTERY, GENERATOR, ...) and
    -- ignores everything else.
    _findSchematicCanvas().onElementPlaced = "schematicSourceElementPlaced"
    -- Read-only VOLTAGE/CURRENT rows (schematicElementSensedValues below)
    -- shown above an element's own custom properties in its PROPERTIES menu
    -- — previously VOLTAGE alone was appended to the edit-menu's own TITLE
    -- (canvas.elementMenuTitleSuffix) instead.
    _findSchematicCanvas().elementSensedValues = "schematicElementSensedValues"
    -- On-canvas row-2 status text under an element's own label (see
    -- schematic_gdsGuiLib.lua's canvas.elementStatusText hook / _drawElement)
    -- — the element equivalent of a control's own position readout
    -- (OPEN/CLOSED, ON/OFF, ...). Reuses the same sensed-voltage reading
    -- schematicElementSensedValues already shows in the PROPERTIES menu, so
    -- a source element (BATTERY, GENERATOR, ...) with a known voltage shows
    -- e.g. "24V"; anything else (BUS, DIODE, no voltage taught yet, ...)
    -- shows no second row at all.
    _findSchematicCanvas().elementStatusText = "schematicElementStatusText"
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
    -- into whichever schematic-flow page the user was actually looking at
    -- when the app last quit or backgrounded (appSettings.schematicLastPage —
    -- see _saveSchematicResumeState), in which case that page's own setup is
    -- done right here before the very first page switch below ever lands on
    -- MainMenu at all.
    local showTC = (appSettings.tcAcceptedVersion ~= APP_VERSION)
    local lastSchematicPage = (not showTC) and appSettings.schematicUnlocked and appSettings.schematicLastPage

    local resumeSystem = lastSchematicPage == "SystemSchematic" and _findSystem(schematicStore.currentSystemId)
    local resumeAircraft = lastSchematicPage == "SchematicManageGallery" and _findCurrentAircraft()

    if resumeSystem then
        _openSystemIntoCanvas(resumeSystem.id, appSettings.schematicEditMode and "design" or "control")
        _navSyncAll("SystemSchematic")
        gdsGui_page_switch("LoadingSchematic", 7, 3, false)
    elseif resumeAircraft then
        gdsGui_schematicGallery_setItems("manageGallery", _systemGalleryItems(resumeAircraft))
        gdsGui_outputTxtBox_setText("schematicManage_pageTitle", _aircraftSystemsTitle(resumeAircraft))
        _navSyncAll("SchematicManageGallery")
        gdsGui_page_switch("LoadingSchematicManage", 11, 2, false)
    elseif lastSchematicPage == "AircraftGallery" then
        gdsGui_schematicGallery_setItems("aircraftGallery", _aircraftGalleryItems())
        _navSyncAll("AircraftGallery")
        gdsGui_page_switch("LoadingAircraftGallery", 12, 2, false)
    elseif lastSchematicPage == "SchematicHome" and _schematicJustUpdatedNoSystemOpen then
        -- Was sitting on the aircraft picker with no system ever opened, and
        -- an update was just installed over the previous build — resume
        -- into AircraftGallery instead (see _schematicJustUpdatedNoSystemOpen).
        gdsGui_schematicGallery_setItems("aircraftGallery", _aircraftGalleryItems())
        _navSyncAll("AircraftGallery")
        gdsGui_page_switch("LoadingAircraftGallery", 12, 2, false)
    elseif lastSchematicPage == "SchematicHome" then
        _refreshSchematicHomeAvailability()
        _navSyncAll("SchematicHome")
        gdsGui_page_switch("LoadingSchematicHome", 9, 2, false)
    else
        _navSyncAll("MainMenu")
        gdsGui_page_switch("IntialBooting", showTC and 4 or 3, 3, false)
    end
    -- This boot's resume decision is made exactly once, right above, no
    -- matter which branch fired -- so _schematicJustUpdatedNoSystemOpen's
    -- job is done the moment we get here. Clearing it unconditionally (not
    -- just inside the branch that actually read it) matters because the
    -- resumeAircraft/AircraftGallery branches above can each fire with the
    -- flag still true (lastSchematicPage was SchematicManageGallery/
    -- AircraftGallery, not SchematicHome, so they never check it) -- leaving
    -- it set would make the first later navBackToSchematicHome() call this
    -- session (e.g. the "<" back button) wrongly redirect to AircraftGallery
    -- again instead of actually stepping up to SchematicHome.
    _schematicJustUpdatedNoSystemOpen = false

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
        gdsGui_outputTxtBox_setText("requiredFPM", _formatRequiredFPM(selectedAltitude, selectedTime))
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
        -- Also re-fits on every resize, not just a text change — see
        -- schematicSnapshotLabel's own resize-refit comment further down,
        -- same reasoning applies to every one of these three readouts.
        if zoomText ~= _prevSchematicZoomText or globApp.resizeDetected then
            _prevSchematicZoomText = zoomText
            _setHeaderReadoutText("schematicZoomLabel", zoomText, 10)
        end
    end

    -- Schematic combination readout ([current/total] + snapshot checkmark,
    -- PREV/NEXT button activation) — polled for the same reason the zoom
    -- readout above is: the combination a control-mode tap/cycle lands on
    -- changes outside of any callback this app layer owns, so there's no
    -- single discrete event to push from. gdsGui_schematic_isMenuOpen also
    -- guards against polling mid-placement, where canvas.controls can be in
    -- a transient state.
    -- A dock tool that ended some way other than its own button being
    -- toggled off (ADD's flow finishing, a mode switch, a system reload)
    -- puts the dock back — see _enterSchematicTool. Outside the menu-open
    -- guard below, since an open ADD menu is exactly what keeps that tool alive.
    if _activeSchematicTool and not _schematicToolStillActive(_activeSchematicTool) then
        _exitSchematicTool()
    end

    local schematicCanvas = _findSchematicCanvas()
    if schematicCanvas and not gdsGui_schematic_isMenuOpen("mainCanvas") then
        if _schematicCombControlsChanged(schematicCanvas) then
            _schematicCombIndex = gdsGui_schematic_getCombinationIndex("mainCanvas")
            _schematicCombTotal = gdsGui_schematic_getCombinationTotal("mainCanvas")
            _schematicCombSig   = gdsGui_schematic_computeSignature("mainCanvas")
            -- A control tap in control mode (gdsGui_schematic_general's touch
            -- handler cycles detentIndex directly, with no app-layer callback
            -- of its own — catalog items don't set one) lands here same as
            -- add/remove/undo/reload: _schematicCombControlsChanged already
            -- catches every way a control's detentIndex can change, so this
            -- is the one place that covers all of them, not just PREV/NEXT.
            _applySolvedColorsToCurrentCombination()
        end
        local combIndex = _schematicCombIndex
        local combTotal = _schematicCombTotal
        -- Not gated behind _schematicCombControlsChanged above — a snapshot
        -- capture/delete changes canvas.snapshots without changing any
        -- control's id/detentIndex/numDetents, so this stays a fresh,
        -- cheap (O(1) hash lookup) check every frame off of _schematicCombSig.
        local hasSnap = gdsGui_schematic_hasSnapshot("mainCanvas", _schematicCombSig)
        -- "(PREDICTED)" (Phase 5) only ever applies when there's no exact
        -- authored snapshot for this combination at all — an authored
        -- snapshot always wins outright (resolveColor's tier 1/2), so
        -- checking isColorPredicted would be redundant/never true there.
        local isPredicted = not hasSnap and _currentCombinationHasPredictedColor("mainCanvas", _schematicCombSig)
        local combText = string.format("[%d/%d]", combIndex, combTotal) .. (isPredicted and " (PREDICTED)" or "")
        -- Also re-fits on every resize, not just a text change — see
        -- schematicSnapshotLabel's own resize-refit comment further down,
        -- same reasoning applies to every one of these three readouts.
        if combText ~= _prevSchematicCombText or globApp.resizeDetected then
            _prevSchematicCombText = combText
            _setHeaderReadoutText("schematicCombLabel", combText, 8)
        end
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

        -- Also re-fits on every resize (not just a count change): a resize
        -- narrows/widens schematicSnapshotLabel's own frame (see
        -- outputTxtBox_gdsGuiLib.lua's _recalculate_textBox), but that pass
        -- only re-wraps at whatever font is CURRENTLY set — it never re-
        -- shrinks/re-grows it, so without this the label could still wrap
        -- after the window is resized smaller than whatever width it was
        -- last fit to.
        local snapCount = gdsGui_schematic_countSnapshots("mainCanvas")
        if snapCount ~= _prevSchematicSnapshotCount or globApp.resizeDetected then
            _prevSchematicSnapshotCount = snapCount
            _setSnapshotLabelText(snapCount)
        end
    end

    -- Unlock T&C agree toggle once user has scrolled to the bottom at least once.
    if not _tcScrolledToBottom and gdsGui_outputTxtBox_hasReachedBottom("tcText") then
        _tcScrolledToBottom = true
        gdsGui_button_setState("tcAgreementToggle", "released")
    end

    -- Update GUI
    gdsGui_update(dt)
    _syncAiPanelInputBlock()

    -- Fires the one-time-per-APP_VERSION schematic data compatibility notice
    -- (built in love.load(), see _buildSchematicCompatNotice) the first
    -- moment the user actually lands on the schematic page, covering both
    -- ways they can get there (navGoToSystemSchematic and the cold-boot
    -- resume branch in love.load()) from one spot instead of duplicating the
    -- open-menu call at both call sites.
    if _pendingSchematicCompatNotice and gdsGui_page_currentName() == "SystemSchematic"
       and not gdsGui_schematic_isMenuOpen("mainCanvas") then
        gdsGui_schematic_openMenu("mainCanvas", _pendingSchematicCompatNotice, {"OK"},
            "schematicCompatNoticeDismissed", nil)
        _pendingSchematicCompatNotice = nil
    end

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
    -- Same non-modal reasoning as the two immediately above — see
    -- drawSchematicAiPanel's own comment.
    drawSchematicAiPanel()
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
-- Every page that's part of the schematic flow, i.e. reachable from the
-- footer dock icon without leaving it. SchematicFullScreen maps back onto
-- "SystemSchematic" below — it's the same live canvas on its own page, not a
-- distinct place to resume into.
local _SCHEMATIC_FLOW_PAGES = {
    SystemSchematic        = true,
    SchematicFullScreen    = true,
    SchematicHome          = true,
    AircraftGallery        = true,
    SchematicManageGallery = true,
}

local function _isOnSchematicPage()
    return _SCHEMATIC_FLOW_PAGES[gdsGui_page_currentName()] == true
end

-- Called from both love.quit() and love.focus(false) below — same "the app
-- is about to stop running right now" moment either covers. Persists exactly
-- which schematic-flow page (if any) was on screen, alongside the content
-- save, so a later cold boot (see love.load()'s own resume check) knows
-- whether to land straight back on that same page or fall through to the
-- normal MainMenu start. schematicStore.currentAircraftId/currentSystemId
-- and appSettings.schematicEditMode already track WHICH aircraft/system/mode
-- to reopen — this is only the "which screen were they actually looking at"
-- bit on top of that.
local function _saveSchematicResumeState()
    local pageName = gdsGui_page_currentName()
    local onSchematic = _isOnSchematicPage()
    if pageName == "SystemSchematic" or pageName == "SchematicFullScreen" then
        _saveCurrentSystem()
        pageName = "SystemSchematic"
    end
    local newLastPage = onSchematic and pageName or false
    if appSettings.schematicLastPage ~= newLastPage then
        appSettings.schematicLastPage = newLastPage
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
    -- clamped to 59:59 -- the display container is sized for "M 59:59 S"
    -- and silently overflows/clips past that (see format_time's own 3599s cap).
    timer.t = math.min(3599, timer.t + 60)
    saveCountdownTime()
    acknowlegeAlarm()
    _rearmPreAlarmNavIfAboveWindow()
end

function dcrsMinRHTopTimer()
    timer.t = math.max(0, timer.t - 60)
    saveCountdownTime()
end

function incrsSecRHTopTimer()
    timer.t = math.min(3599, timer.t + 1)
    saveCountdownTime()
    acknowlegeAlarm()
    _rearmPreAlarmNavIfAboveWindow()
end

-- blink.navSent is a one-shot "already auto-navigated to MainMenu for this
-- trip through the <=3s warning window" latch (see love.update's COUNT DOWN
-- branch). Bumping the timer back above that window with +1 min/+1 sec
-- must re-arm it, or a countdown that re-enters the window a second time
-- (e.g. nudged up mid-countdown) silently never gets the early warning nav
-- again -- only the final zero-alarm, unaffected by this flag, still fires.
function _rearmPreAlarmNavIfAboveWindow()
    if timer.t > 3 then
        blink.navSent = false
    end
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
    -- An update was just installed over the previous build, and no system
    -- was ever opened last session — land on AircraftGallery instead of the
    -- aircraft picker, so existing aircraft are immediately visible (see
    -- _schematicJustUpdatedNoSystemOpen). Cleared immediately after use: this
    -- function is also AircraftGallery's own back-button callback, so if the
    -- flag stayed set it would just bounce the user right back to
    -- AircraftGallery instead of actually stepping up to SchematicHome.
    if _schematicJustUpdatedNoSystemOpen then
        _schematicJustUpdatedNoSystemOpen = false
        gdsGui_schematicGallery_setItems("aircraftGallery", _aircraftGalleryItems())
        _navSyncAll("AircraftGallery")
        gdsGui_page_switch("LoadingAircraftGallery", 12, 2, false)
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
    gdsGui_button_setState("schematicAiBtn", designing and "released" or "deactivated")
    gdsGui_button_setHidden("schematicAiBtn", not designing)
    if not designing then _aiPanelOpen = false end
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
-- Otherwise, if the about-to-be-captured colors contain a provable
-- MISMATCH — a node/wire whose color contradicts the only source that can
-- possibly reach it, same flat-contradiction check _computeAiPanelStats'
-- own structuralColorMismatches runs AFTER the fact on an already-saved
-- snapshot, just run here BEFORE commit instead — warns and requires
-- confirmation rather than silently saving a provably-wrong color. Failing
-- that, if the combination has any genuinely-ambiguous, rule-uncovered
-- color showing right now, prompts to confirm those are correct before
-- committing them — capturing one as-is bakes its current guessed color in
-- exactly as if it had been hand-painted (gdsGui_schematic_resolveColor's
-- predictedColor tier is what prepareSnapshot already reads for an
-- unpainted node — there's no separate "confirmed" flag, so "capture as
-- shown" and "paint this exact same color first" produce byte-identical
-- snapshot data), which is exactly what lets a correct guess count as real
-- evidence without forcing a redundant repaint.
function captureSchematicSnapshot()
    -- Same guard as schematicContextButtonPressed above: don't clobber an
    -- in-progress ADD ELEMENT/CONTROL cascade (or any other open canvas
    -- menu) by opening the conflict-confirm menu out from under it.
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    local plan = gdsGui_schematic_prepareSnapshot("mainCanvas")
    if plan.hasConflict then
        _pendingSnapshotPlan = plan
        gdsGui_schematic_openMenu("mainCanvas", "CONFLICTS WITH EXISTING SNAPSHOT",
            {"OVERWRITE", "CANCEL"}, "schematicSnapshotConflictResolved", "schematicSnapshotConflictResolved", 1)
        return
    end

    local canvas = _findSchematicCanvas()
    -- Every powered node in the LIVE current combination whose displayed
    -- color is a genuinely-ambiguous, rule-uncovered guess (the same
    -- "confidence 0" case _aiColorAttributionConfidence flags), OR a
    -- provable single-source MISMATCH against the PLAN's own
    -- about-to-be-captured color. Mirrors _solveCurrentSchematic's own
    -- canvas.rules-aware branching and open-gate wire-anchor logic so
    -- neither list ever disagrees with what's actually on screen.
    local ambiguous, mismatches = {}, {}
    if canvas then
        local componentTypes = _buildComponentTypeMap(canvas)
        if next(componentTypes) ~= nil then
            local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
            local sourceStates = _currentSourceStates(canvas, componentTypes)
            local gateStates = _currentGateStates(canvas, componentTypes)

            local nodeStates
            if canvas.rules and next(canvas.rules) ~= nil then
                local rulesByGate = {}
                for gateId, rule in pairs(canvas.rules) do
                    if rule and (rule.status == "learned" or rule.status == "locked") and not gateStates[gateId] then
                        rulesByGate[gateId] = rule
                    end
                end
                nodeStates = ModelSolver.solveWithRules(graph, sourceStates, gateStates, rulesByGate).nodeStates
            else
                nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
            end

            local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
            local labelsById = _labelsByIdForCanvas(canvas)

            for id, state in pairs(nodeStates) do
                if state == ModelSolver.POWERED and _aiColorAttributionConfidence(canvas, attribution, nodeStates, id, gateStates, sourceStates) == 0 then
                    local contributorIds = {}
                    for sourceId in pairs(attribution[id] or {}) do table.insert(contributorIds, sourceId) end
                    table.sort(contributorIds)
                    local contributorLabels = {}
                    for _, sourceId in ipairs(contributorIds) do
                        table.insert(contributorLabels, labelsById[sourceId] or sourceId)
                    end
                    table.insert(ambiguous, (labelsById[id] or id) .. " (currently showing "
                        .. table.concat(contributorLabels, "/") .. "'s guess)")
                end
            end
            table.sort(ambiguous)

            local function colorsEqual(a, b)
                if not a or not b then return false end
                for i = 1, 3 do if math.abs((a[i] or 0) - (b[i] or 0)) > 0.02 then return false end end
                return true
            end
            -- nil when contributingIds isn't provably a single source
            -- (genuinely ambiguous, or that one source has no registered
            -- voltage to compare against) — left to the AMBIGUOUS check
            -- above instead, never flagged here as a flat contradiction.
            local function expectedColorAndSource(contributingIds)
                if not contributingIds or _isGenuinelyColorAmbiguous(canvas, contributingIds) then return nil end
                local onlySourceId
                for sourceId in pairs(contributingIds) do onlySourceId = sourceId end
                if not onlySourceId then return nil end
                local entity = _findSourceEntity(canvas, onlySourceId)
                local voltage = entity and entity.voltage
                if not voltage then return nil end
                return _colorForVoltage(canvas, voltage, _currentMedium().style.powered), onlySourceId
            end

            for _, e in ipairs(canvas.elements) do
                if nodeStates[e.id] == ModelSolver.POWERED then
                    local expected, sourceId = expectedColorAndSource(attribution[e.id])
                    local painted = plan.elements[e.id]
                    if expected and painted and not colorsEqual(expected, painted) then
                        table.insert(mismatches, (labelsById[e.id] or e.id)
                            .. " (expected " .. (labelsById[sourceId] or sourceId) .. "'s color)")
                    end
                end
            end
            for _, c in ipairs(canvas.controls) do
                -- An open gate's or off source's own body always displays
                -- flat unpowered gray regardless of attribution (see
                -- _solveCurrentSchematic's own isOpenGate/isOffSource
                -- override) — checking it against its source's color would
                -- be a false positive, not a real contradiction.
                local isOpenGate = componentTypes[c.id] == "gate" and not _isActivePosition(c)
                local isOffSource = componentTypes[c.id] == "source" and not sourceStates[c.id]
                if nodeStates[c.id] == ModelSolver.POWERED and not isOpenGate and not isOffSource then
                    local expected, sourceId = expectedColorAndSource(attribution[c.id])
                    local painted = plan.controls[c.id]
                    if expected and painted and not colorsEqual(expected, painted) then
                        table.insert(mismatches, (labelsById[c.id] or c.id)
                            .. " (expected " .. (labelsById[sourceId] or sourceId) .. "'s color)")
                    end
                end
            end
            for _, w in ipairs(canvas.wires) do
                -- A directionalGate-touching wire is checked off its own
                -- non-gate endpoint alone, same "the gate's single shared
                -- node can't represent its two leads independently"
                -- reasoning _solveCurrentSchematic's own live wire loop
                -- uses — never both-ends-powered, which would simply
                -- never fire for a correctly-blocking diode's cathode-side
                -- wire at all.
                local fromIsDirectionalGate = componentTypes[w.fromElementId] == "directionalGate"
                local toIsDirectionalGate = componentTypes[w.toElementId] == "directionalGate"
                local powered, anchorId
                if fromIsDirectionalGate or toIsDirectionalGate then
                    anchorId = fromIsDirectionalGate and w.toElementId or w.fromElementId
                    powered = nodeStates[anchorId] == ModelSolver.POWERED
                else
                    local fromState, toState = nodeStates[w.fromElementId], nodeStates[w.toElementId]
                    powered = fromState == ModelSolver.POWERED and toState == ModelSolver.POWERED
                    local fromIsOpenGate = componentTypes[w.fromElementId] == "gate" and gateStates[w.fromElementId] ~= "closed"
                    local toIsOpenGate = componentTypes[w.toElementId] == "gate" and gateStates[w.toElementId] ~= "closed"
                    anchorId = (fromIsOpenGate and not toIsOpenGate) and w.toElementId or w.fromElementId
                end
                if powered then
                    local expected, sourceId = expectedColorAndSource(attribution[anchorId])
                    local painted = plan.wires[w.id]
                    if expected and painted and not colorsEqual(expected, painted) then
                        table.insert(mismatches, (labelsById[w.id] or w.id)
                            .. " (expected " .. (labelsById[sourceId] or sourceId) .. "'s color)")
                    end
                end
            end
            table.sort(mismatches)
        end
    end

    if #mismatches > 0 then
        _pendingSnapshotPlan = plan
        gdsGui_schematic_openMenu("mainCanvas",
            "WARNING — contradicts the only possible source: " .. table.concat(mismatches, "; ")
                .. " — capture anyway, or cancel to fix the paint first",
            {"CAPTURE ANYWAY", "CANCEL"}, "schematicAmbiguousColorConfirmed", "schematicAmbiguousColorConfirmed", nil, 0.9)
        return
    end

    if #ambiguous > 0 then
        _pendingSnapshotPlan = plan
        gdsGui_schematic_openMenu("mainCanvas",
            "Capture as shown if correct, or cancel to repaint first",
            {"CAPTURE AS SHOWN", "CANCEL"}, "schematicAmbiguousColorConfirmed", "schematicAmbiguousColorConfirmed", nil, 0.9)
        return
    end

    gdsGui_schematic_commitSnapshot("mainCanvas", plan)
    _recomputeDeducedGateStates()
    _setSnapshotLabelText(gdsGui_schematic_countSnapshots("mainCanvas"))
    _requestSchematicSave()
    if appSettings.hapticsEnabled and love.system.vibrate then love.system.vibrate(0.1) end
    if appSettings.soundEnabled and singleChimeSound then love.audio.play(singleChimeSound) end
    _flagLockedRuleContradictionIfAny("mainCanvas")
end

-- Shared onSelect/onCancel for the conflict-confirm menu: cancel (tap outside,
-- or the CANCEL row) calls this with no selected option, which falls through
-- without committing.
function schematicSnapshotConflictResolved(canvasName, index, optionText)
    if optionText == "OVERWRITE" and _pendingSnapshotPlan then
        gdsGui_schematic_commitSnapshot(canvasName, _pendingSnapshotPlan)
        _recomputeDeducedGateStates()
        _setSnapshotLabelText(gdsGui_schematic_countSnapshots(canvasName))
        _requestSchematicSave()
        _flagLockedRuleContradictionIfAny(canvasName)
    end
    _pendingSnapshotPlan = nil
end

-- Shared by both the AMBIGUOUS and WARNING (structural mismatch) confirm
-- menus above — CAPTURE AS SHOWN/CAPTURE ANYWAY both commit the plan
-- exactly as prepareSnapshot already resolved it (see
-- captureSchematicSnapshot's own comment on why that's enough to count a
-- correct guess as real evidence, and why a mismatch still needs an
-- explicit override rather than being silently saved). CANCEL (or tapping
-- outside) falls through without committing either way, leaving the PAINT
-- tool as the way to fix/assert a different color instead.
function schematicAmbiguousColorConfirmed(canvasName, index, optionText)
    if (optionText == "CAPTURE AS SHOWN" or optionText == "CAPTURE ANYWAY") and _pendingSnapshotPlan then
        gdsGui_schematic_commitSnapshot(canvasName, _pendingSnapshotPlan)
        _recomputeDeducedGateStates()
        _setSnapshotLabelText(gdsGui_schematic_countSnapshots(canvasName))
        _requestSchematicSave()
        _flagLockedRuleContradictionIfAny(canvasName)
    end
    _pendingSnapshotPlan = nil
end

function schematicRuleContradictionDismissed() end

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
    _applySolvedColorsToCurrentCombination()
    _requestSchematicSave()
end

function schematicCombNextPressed()
    if gdsGui_schematic_isMenuOpen("mainCanvas") then return end
    gdsGui_schematic_pushUndo("mainCanvas")
    gdsGui_schematic_stepCombination("mainCanvas", 1)
    _applySolvedColorsToCurrentCombination()
    _requestSchematicSave()
end

-- GATE RULES list row tapped — index maps back to _sortedGateIds' own
-- deterministic order (see that function's comment), RETURN steps back up
-- to DESIGN ACTIONS.
function schematicGateRulesListChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        _openDesignActionsMenu(canvasName)
        return
    end
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local gateId = _sortedGateIds(canvas)[index]
    if gateId then _openGateRuleDetailMenu(canvasName, gateId) end
end

-- LOCK THIS RULE / RETURN from one gate's detail view — both reopen the
-- (now possibly refreshed) list rather than dropping all the way back to
-- DESIGN ACTIONS, so locking several gates in a row doesn't require
-- re-opening the menu from scratch each time.
function schematicGateRuleDetailChosen(canvasName, index, optionText)
    local canvas = _findSchematicCanvas()
    if optionText == "LOCK THIS RULE" and canvas and _pendingGateRuleGateId then
        _lockGateRule(canvas, _pendingGateRuleGateId)
        _requestSchematicSave()
    end
    _pendingGateRuleGateId = nil
    if canvas then _openGateRulesListMenu(canvasName) end
end

function schematicGateRuleDetailCancelled()
    _pendingGateRuleGateId = nil
end

-- ATTRIBUTION RULES list row tapped — index maps back to
-- _sortedAmbiguousNodeIds' own deterministic order, RETURN steps back up
-- to DESIGN ACTIONS. Same shape as schematicGateRulesListChosen above.
function schematicAttributionRulesListChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        _openDesignActionsMenu(canvasName)
        return
    end
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local nodeId = _sortedAmbiguousNodeIds(canvas)[index]
    if nodeId then _openAttributionRuleDetailMenu(canvasName, nodeId) end
end

-- LOCK THIS RULE / RETURN from one node's detail view — same "reopen the
-- list, not DESIGN ACTIONS" shape as schematicGateRuleDetailChosen above.
function schematicAttributionRuleDetailChosen(canvasName, index, optionText)
    local canvas = _findSchematicCanvas()
    if optionText == "LOCK THIS RULE" and canvas and _pendingAttributionRuleNodeId then
        _lockAttributionRule(canvas, _pendingAttributionRuleNodeId)
        _requestSchematicSave()
    end
    _pendingAttributionRuleNodeId = nil
    if canvas then _openAttributionRulesListMenu(canvasName) end
end

function schematicAttributionRuleDetailCancelled()
    _pendingAttributionRuleNodeId = nil
end

-- APPLY jumps the live combination straight to the suggested detents (same
-- level of directness gdsGui_schematic_stepCombination already uses
-- internally for c.detentIndex) and re-solves/re-saves exactly like
-- PREV/NEXT above; CANCEL (or tapping outside) leaves the combination
-- untouched.
function schematicSuggestNextSnapshotChosen(canvasName, index, optionText)
    if optionText == "APPLY" and _pendingSuggestedDetents then
        local canvas = _findSchematicCanvas()
        if canvas then
            gdsGui_schematic_pushUndo(canvasName)
            for _, c in ipairs(canvas.controls) do
                local detentIndex = _pendingSuggestedDetents[c.id]
                if detentIndex then c.detentIndex = detentIndex end
            end
            _applySolvedColorsToCurrentCombination()
            _requestSchematicSave()
        end
    end
    _pendingSuggestedDetents = nil
end

function schematicSuggestNextSnapshotDismissed()
    _pendingSuggestedDetents = nil
end

function schematicElectricalColorsChosen(canvasName, index, optionText)
    if optionText == "POWERED COLOR" then
        gdsGui_schematic_openGenericColorPicker(canvasName,
            "POWERED COLOR (snapshots already painted in the old color will need repainting to keep being learned from)",
            "schematicPoweredColorChosen", nil)
    elseif optionText == "UNPOWERED COLOR" then
        gdsGui_schematic_openGenericColorPicker(canvasName,
            "UNPOWERED COLOR (snapshots already painted in the old color will need repainting to keep being learned from)",
            "schematicUnpoweredColorChosen", nil)
    elseif optionText == "PER-SOURCE SETTINGS" then
        _openPerSourceSettingsListMenu(canvasName)
    elseif optionText == "RETURN" then
        _openDesignActionsMenu(canvasName)
    end
end

-- PER-SOURCE SETTINGS list row tapped — index maps back to _sortedSourceIds'
-- own deterministic order, RETURN steps back up to ELECTRICAL COLORS.
function schematicPerSourceSettingsListChosen(canvasName, index, optionText)
    if optionText == "RETURN" then
        _openElectricalColorsMenu(canvasName)
        return
    end
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    local sourceId = _sortedSourceIds(canvas)[index]
    if sourceId then _openPerSourceSettingDetailMenu(canvasName, sourceId) end
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — VOLTAGE -> COLOR REGISTRATION: the single place a
-- voltage's powered color actually gets picked. Shared by both the
-- initial-placement flow further down (schematicSourceElementPlaced) and
-- PER-SOURCE SETTINGS' own VOLTAGE edit just below — either path lands
-- here once a source's voltage is known, and either registers that voltage
-- a NEW color on THIS system (first use) or silently reuses whatever this
-- system already has registered for it (every use after the first), which
-- is the whole point of keying color by voltage instead of by individual
-- source. Lives on canvas.voltageColors, NOT an appSettings global — a
-- fresh system (new, or re-created after deleting it or its whole
-- aircraft) starts with nothing registered, same as it starts with no
-- snapshots/rules taught, so every voltage has to be taught again. Declared
-- ahead of every caller below since _ensureVoltageHasColor is a local
-- (upvalue, not a by-name global callback) — Lua doesn't hoist local
-- functions.
-------------------------------------------------------------------------------

-- Which voltage the open swatch picker (armed by _ensureVoltageHasColor
-- below) is registering a color FOR — only one such pick is ever in
-- flight at a time, same convention as _pendingPerSourceTargetId.
local _pendingVoltageColorPickValue = nil

local function _resolveAndSaveSchematic()
    _requestSchematicSave()
    _applySolvedColorsToCurrentCombination()
end

local function _ensureVoltageHasColor(canvasName, voltage)
    local canvas = _findSchematicCanvas()
    if not canvas then return end
    -- canvas.voltageColors is an app-added field (not part of the library's
    -- own canvas schema), normally set by _openSystemIntoCanvas/
    -- _clearMainCanvas before any element could be placed at all — self-heals
    -- to an empty table here rather than crashing on a nil index if either
    -- of those somehow hasn't run yet for this canvas.
    canvas.voltageColors = canvas.voltageColors or {}
    if canvas.voltageColors[voltage] then
        _resolveAndSaveSchematic()
        return
    end
    _pendingVoltageColorPickValue = voltage
    gdsGui_schematic_openGenericColorPicker(canvasName,
        voltage .. (_currentMedium().magnitudeUnit or "V")
            .. " POWERED COLOR (every source at this magnitude, on this system, will share it)",
        "schematicVoltageColorChosen", "schematicVoltageColorCancelled")
end

function schematicVoltageColorChosen(canvasName, index)
    local color = gdsGui_schematic_getColorPaletteEntry(index)
    local canvas = _findSchematicCanvas()
    if color and canvas and _pendingVoltageColorPickValue then
        canvas.voltageColors = canvas.voltageColors or {}
        canvas.voltageColors[_pendingVoltageColorPickValue] = color
    end
    _pendingVoltageColorPickValue = nil
    _resolveAndSaveSchematic()
end

function schematicVoltageColorCancelled(canvasName)
    -- The voltage itself is already set on the source either way — it'll
    -- just show the system-wide default POWERED COLOR (see
    -- _colorForPoweredNode's defaultColor fallback) until a color is
    -- registered for it some other time (PER-SOURCE SETTINGS > VOLTAGE,
    -- re-entering the same value, revisits this picker).
    _pendingVoltageColorPickValue = nil
    _resolveAndSaveSchematic()
end

-- Reverse of the registration above: "24V" (or "1500PSI", ... — see
-- _currentMedium's own magnitudeUnit) when elementId's CURRENTLY DISPLAYED
-- color (gdsGui_schematic_resolveColor — the exact same tiered
-- pendingColor/snapshot/predictedColor/default lookup the live canvas
-- itself paints with, so this can never disagree with what's actually on
-- screen) matches one of this system's own registered voltageColors
-- entries, else nil — an unpowered element (flat gray), a legacy/untyped
-- system predating "one system type per aircraft" (no voltageColors
-- concept at all), or a multi-source dashed sequence with no single flat
-- color all read as "no one sensed a magnitude to report," same as the
-- hook simply returning nothing.
-- Formerly shown appended to the element edit menu's own title
-- (schematic_gdsGuiLib.lua's canvas.elementMenuTitleSuffix hook); now one of
-- the read-only rows schematicElementSensedValues below hands to the
-- PROPERTIES menu instead (canvas.elementSensedValues), alongside CURRENT.
function schematicElementSensedVoltage(canvasName, elementId)
    local canvas = _findSchematicCanvas()
    if not canvas or not canvas.voltageColors then return nil end
    local r, g, b, a = gdsGui_schematic_resolveColor(canvasName, "element", elementId)
    for voltage, color in pairs(canvas.voltageColors) do
        if math.abs(color[1] - r) < 0.01 and math.abs(color[2] - g) < 0.01
           and math.abs(color[3] - b) < 0.01 and math.abs((color[4] or 1) - a) < 0.01 then
            return voltage .. (_currentMedium().magnitudeUnit or "V")
        end
    end
    return nil
end

-- Current is not modeled anywhere yet (model/solver.lua's graph is a pure
-- powered/unpowered flood-fill — see its own header comment — with no
-- resistance/current arithmetic at all), so this always reads N/A for now.
-- Kept as its own named function (rather than inlining "nil" at the call
-- site below) so a future current model has a single, already-wired-in
-- place to plug its real per-element reading into — canvasName/elementId
-- are already threaded through, nothing else would need to change.
function schematicElementSensedCurrent(canvasName, elementId)
    return nil
end

-- canvas.elementSensedValues hook (schematic_gdsGuiLib.lua's
-- _openPropertiesMenu, wired up once in love.load()): the read-only VOLTAGE/
-- CURRENT rows shown above an element's own custom properties. Order here
-- is display order.
function schematicElementSensedValues(canvasName, elementId)
    return {
        { label = _currentMedium().magnitudeLabel or "VOLTAGE", value = schematicElementSensedVoltage(canvasName, elementId) },
        { label = "CURRENT", value = schematicElementSensedCurrent(canvasName, elementId) },
    }
end

-- canvas.elementStatusText hook (schematic_gdsGuiLib.lua's _drawElement):
-- the on-canvas row-2 status text under an element's own label, same
-- sensed-voltage reading schematicElementSensedValues shows in the
-- PROPERTIES menu — nil (no second row at all) for anything without a
-- taught voltage, same as that menu's own "N/A" case resolves to nothing
-- here instead (a canvas label has no room for a literal "N/A").
function schematicElementStatusText(canvasName, elementId)
    return schematicElementSensedVoltage(canvasName, elementId)
end

function schematicPerSourceSettingDetailChosen(canvasName, index, optionText)
    if optionText == (_currentMedium().magnitudeLabel or "VOLTAGE") and _pendingPerSourceTargetId then
        local canvas = _findSchematicCanvas()
        local entity = canvas and _findSourceEntity(canvas, _pendingPerSourceTargetId)
        local label = _currentMedium().magnitudeLabel or "VOLTAGE"
        gdsGui_textPrompt_open("SOURCE " .. label .. " (NUMBER)", entity and entity.voltage and tostring(entity.voltage) or "",
            6, "schematicPerSourceVoltageConfirmed", nil, true, "e.g. 24 or 28")
        return -- keep _pendingPerSourceTargetId set for the text-prompt's own callback
    elseif optionText == "RETURN" then
        _pendingPerSourceTargetId = nil
        _openPerSourceSettingsListMenu(canvasName)
        return
    end
    _pendingPerSourceTargetId = nil
end

function schematicPerSourceSettingDetailCancelled()
    _pendingPerSourceTargetId = nil
end

-- Writes straight onto the targeted source's own element/control table
-- (voltage — see _openPerSourceSettingsListMenu's own comment), then makes
-- sure that voltage has a registered color (_ensureVoltageHasColor, which
-- itself re-solves/re-saves once it's done — see that function's own
-- comment) so the canvas reflects the change right away, same as the
-- system-wide POWERED COLOR/UNPOWERED COLOR callbacks above.
function schematicPerSourceVoltageConfirmed(text)
    local canvas = _findSchematicCanvas()
    local entity = canvas and _pendingPerSourceTargetId and _findSourceEntity(canvas, _pendingPerSourceTargetId)
    _pendingPerSourceTargetId = nil
    if not entity or not canvas then return end
    local voltage = tonumber(text)
    entity.voltage = voltage -- nil (cleared) if text wasn't a valid number, same as an empty field
    if voltage then
        _ensureVoltageHasColor(canvas.name, voltage)
    else
        _requestSchematicSave()
        _applySolvedColorsToCurrentCombination()
    end
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC — NEW SOURCE PLACEMENT: a freshly-placed "source"-role
-- element/control (BATTERY, GENERATOR, HYDRAULIC PUMP, ...) is prompted for
-- its nominal magnitude immediately, via mainCanvas.onElementPlaced (wired
-- in love.load()) — required, since a source with none can never get an
-- automatic powered color of its own (see _colorForPoweredNode's
-- defaultColor fallback). The element/control already exists on the canvas
-- by the time this fires (the library's placement commit runs first), so
-- cancelling out of the prompt just leaves it unset rather than undoing the
-- placement — there'd be nothing left to put it back the way it was.
-- The prompt's own wording is pulled from the CURRENT medium's
-- magnitudeLabel ("VOLTAGE" for ELECTRICAL, "PRESSURE" for HYDRAULIC/FUEL/
-- BLEED AIR — see model/media/hydraulic.lua's own comment) so a freshly-
-- placed hydraulic PUMP isn't asked for a "VOLTAGE" — still stored on the
-- entity as .voltage internally either way; only the prompt's own text
-- changes per medium, not the field name underneath it.
-------------------------------------------------------------------------------

-- Which newly-placed source the open magnitude prompt belongs to — only one
-- placement is ever in flight at a time, same convention as
-- _pendingPerSourceTargetId.
local _pendingNewSourceId = nil

function schematicSourceElementPlaced(canvasName, kind, newId, componentType)
    if componentType ~= "source" then return end
    _pendingNewSourceId = newId
    local label = _currentMedium().magnitudeLabel or "VOLTAGE"
    gdsGui_textPrompt_open("SOURCE " .. label .. " (NUMBER)", "", 6,
        "schematicNewSourceVoltageConfirmed", "schematicNewSourceVoltageCancelled", true, "e.g. 24 or 28")
end

function schematicNewSourceVoltageConfirmed(text)
    local voltage = tonumber(text)
    if not voltage then
        local label = _currentMedium().magnitudeLabel or "VOLTAGE"
        gdsGui_textPrompt_open(label .. " REQUIRED (NUMBER), TRY AGAIN", text or "", 6,
            "schematicNewSourceVoltageConfirmed", "schematicNewSourceVoltageCancelled", true, "e.g. 24 or 28")
        return
    end
    local canvas = _findSchematicCanvas()
    local entity = canvas and _pendingNewSourceId and _findSourceEntity(canvas, _pendingNewSourceId)
    _pendingNewSourceId = nil
    if not entity or not canvas then return end
    entity.voltage = voltage
    _ensureVoltageHasColor(canvas.name, voltage)
end

function schematicNewSourceVoltageCancelled()
    _pendingNewSourceId = nil
end

-- Both callbacks below: the CURRENT medium's own .style is the ONE table
-- both _solveCurrentSchematic (forward prediction) and _stateForColor
-- (backward deduction, see model/learner.lua) read — overwriting one entry
-- here keeps paint/predict/deduce all using the same color from this point
-- forward, with no separate "teach it" step. Re-solving and re-deducing
-- immediately (rather than waiting for the next snapshot/combination
-- change) means the canvas reflects the new color right away, including
-- for any gate whose rule depended on evidence that's about to stop
-- matching (see this section's own comment above _openElectricalColorsMenu).
-- Resolved via _currentMedium() rather than ELECTRICAL_MEDIUM directly —
-- today this menu only ever opens for an ELECTRICAL system (see its own
-- "ELECTRICAL COLORS" gate above _openElectricalColorsMenu), so the two
-- are the same object in practice, but a future medium's own color-override
-- menu can reuse these two callbacks unchanged.
function schematicPoweredColorChosen(canvasName, index)
    local color = gdsGui_schematic_getColorPaletteEntry(index)
    if not color then return end
    _currentMedium().style.powered = color
    appSettings.electricalPoweredColor = color
    _saveAppSettings()
    _recomputeDeducedGateStates()
    _applySolvedColorsToCurrentCombination()
end

function schematicUnpoweredColorChosen(canvasName, index)
    local color = gdsGui_schematic_getColorPaletteEntry(index)
    if not color then return end
    _currentMedium().style.unpowered = color
    appSettings.electricalUnpoweredColor = color
    _saveAppSettings()
    _recomputeDeducedGateStates()
    _applySolvedColorsToCurrentCombination()
end

-------------------------------------------------------------------------------
-- SYSTEM SCHEMATIC TEST HELPERS
-- Each builds its own throwaway canvas so these are independent of the real
-- "mainCanvas" built in love.load(). Return values are kept to primitives
-- (numbers/strings/booleans) to match this app's existing test-harness
-- convention of comparing flattened values, not tables, by equality.
-------------------------------------------------------------------------------

function schematicGetColorPaletteEntryTest()
    local color, name = gdsGui_schematic_getColorPaletteEntry(3) -- GREEN, per _COLOR_PALETTE's own order
    return color[1], color[2], color[3], name
end

-- model/media/registry.lua round-trip, plus _currentMedium()'s own
-- fallback (see that function's comment): no system open yet
-- (schematicStore.currentSystemId unset, same as every other test here)
-- must still resolve to ELECTRICAL_MEDIUM, exactly the unconditional
-- default this app had before the registry existed. Doesn't exercise the
-- systemType-match branch itself -- that needs a real aircraft/system
-- fixture in schematicStore, left for whenever a second medium is actually
-- wired into a real system rather than faked here.
function mediaRegistryCurrentMediumTest()
    local fallbackIsElectrical = _currentMedium() == ELECTRICAL_MEDIUM

    local registry = require("model.media.registry")
    local fakeMedium = { name = "TEST_MEDIUM", style = { unpowered = { 0, 0, 0, 1 }, powered = { 1, 1, 1, 1 } } }
    registry.register("TEST_MEDIUM", fakeMedium)
    local registryRoundTrips = registry.get("TEST_MEDIUM") == fakeMedium
    local unregisteredIsNil = registry.get("NOT_A_REAL_SYSTEM_TYPE") == nil

    return fallbackIsElectrical, registryRoundTrips, unregisteredIsNil
end

-- _colorForPoweredNode tests (voltage-keyed powered colors, see that
-- function's own comment above _solveCurrentSchematic). Hand-built
-- {elements=..., controls=..., voltageColors=...} tables, not a real
-- schematic canvas -- _colorForPoweredNode/_findSourceEntity only ever
-- read .id/.voltage off elements/controls, and voltageColors directly
-- (canvas.voltageColors is per-system, not an appSettings global — see
-- _ensureVoltageHasColor's own comment).
local _TEST_RED, _TEST_YELLOW, _TEST_DEFAULT = { 1, 0, 0, 1 }, { 1, 1, 0, 1 }, { 0.9, 0.9, 0.9, 1 }

function colorForPoweredNode_singleSourceOwnColorTest()
    local canvas = { elements = { { id = "batt1", voltage = 24 } }, controls = {}, voltageColors = { [24] = _TEST_RED } }
    local color = _colorForPoweredNode("bus1", { bus1 = { batt1 = true } }, canvas, _TEST_DEFAULT)
    return color[1], color[2], color[3]
end

function colorForPoweredNode_singleSourceNoColorFallsBackTest()
    local canvas = { elements = { { id = "batt1" } }, controls = {}, voltageColors = {} } -- no voltage -> no registered color
    local color = _colorForPoweredNode("bus1", { bus1 = { batt1 = true } }, canvas, _TEST_DEFAULT)
    return color[1], color[2], color[3]
end

function colorForPoweredNode_tieHigherVoltageWinsTest()
    local canvas = {
        elements = { { id = "batt1", voltage = 24 } },
        controls = { { id = "gen1", voltage = 28 } },
        voltageColors = { [24] = _TEST_RED, [28] = _TEST_YELLOW },
    }
    local color = _colorForPoweredNode("bus1", { bus1 = { batt1 = true, gen1 = true } }, canvas, _TEST_DEFAULT)
    return color[1], color[2], color[3]
end

function colorForPoweredNode_tieNoVoltageDashesTest()
    local canvas = {
        elements = { { id = "batt1" } }, -- no voltage
        controls = { { id = "gen1", voltage = 28 } },
        voltageColors = { [28] = _TEST_YELLOW },
    }
    local color = _colorForPoweredNode("bus1", { bus1 = { batt1 = true, gen1 = true } }, canvas, _TEST_DEFAULT)
    if type(color[1]) ~= "table" then return "not a sequence" end
    return #color
end

-- Equal voltages no longer need a dashed fallback at all: both contributors
-- share the IDENTICAL registered color for that voltage now, so this
-- asserts a single flat color instead of the old 2-entry dashed sequence —
-- the exact behavior change this refactor (color keyed by voltage, not by
-- individual source) was for.
function colorForPoweredNode_tieEqualVoltageSameColorTest()
    local canvas = {
        elements = { { id = "batt1", voltage = 24 } },
        controls = { { id = "gen1", voltage = 24 } },
        voltageColors = { [24] = _TEST_RED },
    }
    local color = _colorForPoweredNode("bus1", { bus1 = { batt1 = true, gen1 = true } }, canvas, _TEST_DEFAULT)
    if type(color[1]) == "table" then return "unexpected sequence" end
    return color[1], color[2], color[3]
end

-- Full-stack integration: two real sources (BATT 1 element, GEN 1 control)
-- both wired into the same bus, GEN 1's 28V beating BATT 1's 24V end to
-- end through buildGraph -> solve -> solveSourceAttribution ->
-- _colorForPoweredNode.
function schematicVoltageTieBreakIntegrationTest()
    gdsGui_schematic_delete("unitTestCanvas24")
    gdsGui_schematic_create("unitTestCanvas24", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas24", "batt1", "rect", 0, 0, 0.1, 0.1, "BATT 1", nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas24", "gen1", 0.3, 0, {"OFF", "ON"}, 1, "GEN 1", nil,
        1, nil, nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas24", "bus1", "rect", 0.6, 0, 0.1, 0.1, "BUS 1", nil, nil, nil, nil, "path")
    gdsGui_schematic_addWire("unitTestCanvas24", "w1", "batt1", "bus1", nil)
    gdsGui_schematic_addWire("unitTestCanvas24", "w2", "gen1", "bus1", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas24" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    canvas.voltageColors = { [24] = _TEST_RED, [28] = _TEST_YELLOW } -- per-system, not an appSettings global
    canvas.elements[1].voltage = 24
    canvas.controls[1].voltage = 28

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local gateStates = _currentGateStates(canvas, componentTypes)
    local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
    if nodeStates.bus1 ~= "powered" then return "fail: bus1 not powered" end

    local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
    local color = _colorForPoweredNode("bus1", attribution, canvas, ELECTRICAL_MEDIUM.style.powered)
    return color[1], color[2], color[3]
end

-- A "gate"-role control's (SWITCH, ...) own display color: OPEN always
-- reads as the flat unpowered gray even though solve() itself still marks
-- the switch's own node POWERED (its input terminal genuinely is hot, fed
-- straight off BATT 1 — see solver.lua's own comment, and the wire test
-- below: w1 batt1->sw1 reads hot right up to the open contact). That's
-- purely a display-layer override (main.lua's own isOpenGate check below)
-- — logically, the node stays "powered" so a feeding wire can still show
-- correctly, and so deduction/rule-learning keep seeing real reachability
-- data. CLOSED takes its color from the highest-voltage source reaching
-- it, same as any other powered node. Mirrors _solveCurrentSchematic's
-- own controls-loop override against a throwaway canvas (same "full
-- Phase 1 adapter path, still isolated from mainCanvas" convention as
-- schematicVoltageTieBreakIntegrationTest above — _solveCurrentSchematic
-- itself only ever operates on the real mainCanvas, so can't be called
-- directly from a test).
function schematicOpenGateShowsUnpoweredColorTest()
    gdsGui_schematic_delete("unitTestCanvas25")
    gdsGui_schematic_create("unitTestCanvas25", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas25", "batt1", "rect", 0, 0, 0.1, 0.1, "BATT 1", nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas25", "sw1", 0.3, 0, {"OFF", "ON"}, 1, "SW 1", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addElement("unitTestCanvas25", "bus1", "rect", 0.6, 0, 0.1, 0.1, "BUS 1", nil, nil, nil, nil, "path")
    gdsGui_schematic_addWire("unitTestCanvas25", "w1", "batt1", "sw1", nil)
    gdsGui_schematic_addWire("unitTestCanvas25", "w2", "sw1", "bus1", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas25" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    canvas.voltageColors = { [24] = _TEST_RED } -- per-system, not an appSettings global
    canvas.elements[1].voltage = 24

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes)

    local function displayColorForSw1()
        local gateStates = _currentGateStates(canvas, componentTypes)
        local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
        local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
        local isOpenGate = componentTypes.sw1 == "gate" and not _isActivePosition(canvas.controls[1])
        local color = (nodeStates.sw1 == ModelSolver.POWERED and not isOpenGate)
            and _colorForPoweredNode("sw1", attribution, canvas, ELECTRICAL_MEDIUM.style.powered)
            or ELECTRICAL_MEDIUM.style.unpowered
        return color, nodeStates.sw1
    end

    canvas.controls[1].detentIndex = 1 -- "ON" (closed)
    local closedColor = displayColorForSw1()
    canvas.controls[1].detentIndex = 0 -- "OFF" (open)
    local openColor, openNodeState = displayColorForSw1()

    local closedIsRed = closedColor[1] == 1 and closedColor[2] == 0 and closedColor[3] == 0
    local openIsGray = openColor[1] == ELECTRICAL_MEDIUM.style.unpowered[1]
        and openColor[2] == ELECTRICAL_MEDIUM.style.unpowered[2]
        and openColor[3] == ELECTRICAL_MEDIUM.style.unpowered[3]
    return closedIsRed, openIsGray, openNodeState -- openNodeState: "powered" proves the input terminal is still physically hot
end

-- Full pipeline test for learned attribution rules (model/learner.lua's
-- findAttributionRule + main.lua's _recomputeAttributionRules/
-- _attributionRuleWinner/_aiColorAttributionConfidence).
--
-- Topology: battA(24V) -- gate1(open) -- busX -- genB(28V) -- gate1's own
-- node is ambiguous (2 contributors) whenever open, same single-shared-
-- node case as a real open switch — mirrors Aircraft 15's own SWITCH_57/
-- BATT_2/GENR_1 scenario. A second, independent branch — battA -- gate2 --
-- sinkC — gives a condition whose REAL solved state (not just a label)
-- tracks gate2's own open/closed position: sinkC is only reached (and so
-- only "powered") when gate2 actually conducts. Two snapshots teach "gate2
-- open -> battA wins at gate1" and "gate2 closed -> genB wins at gate1" by
-- painting gate1 each source's own registered color and sinkC its real
-- resulting state.
--
-- Verifies: (1) a rule gets learned at all; (2) applying it to a NEW,
-- never-snapshotted combination at EACH gate2 position (via the real
-- solve()/solveSourceAttribution() path, not a snapshot lookup) picks the
-- taught winner instead of the unverified highest-voltage default (which
-- would always pick genB, 28V, regardless of gate2); (3) color-attribution
-- confidence is now > 0 at an ambiguous node once a rule covers it —
-- the exact gap flagged by the Aircraft 15 bug report.
function schematicAttributionRuleLearnedAndAppliedTest()
    gdsGui_schematic_delete("unitTestCanvas26")
    gdsGui_schematic_create("unitTestCanvas26", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas26", "battA", "rect", 0, 0, 0.1, 0.1, "BATT A", nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas26", "genB", "rect", 0.8, 0, 0.1, 0.1, "GEN B", nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas26", "busX", "rect", 0.6, 0, 0.1, 0.1, "BUS X", nil, nil, nil, nil, "path")
    gdsGui_schematic_addElement("unitTestCanvas26", "sinkC", "rect", 0.3, 0.5, 0.1, 0.1, "SINK C", nil, nil, nil, nil, "sink")
    gdsGui_schematic_addControl("unitTestCanvas26", "gate1", 0.3, 0, {"OFF", "ON"}, 0, "GATE 1", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addControl("unitTestCanvas26", "gate2", 0.3, 0.3, {"OFF", "ON"}, 0, "GATE 2", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addWire("unitTestCanvas26", "w1", "battA", "gate1", nil)
    gdsGui_schematic_addWire("unitTestCanvas26", "w2", "gate1", "busX", nil)
    gdsGui_schematic_addWire("unitTestCanvas26", "w3", "busX", "genB", nil)
    gdsGui_schematic_addWire("unitTestCanvas26", "w4", "battA", "gate2", nil)
    gdsGui_schematic_addWire("unitTestCanvas26", "w5", "gate2", "sinkC", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas26" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    canvas.elements[1].voltage = 24 -- battA
    canvas.elements[2].voltage = 28 -- genB
    canvas.voltageColors = { [24] = _TEST_RED, [28] = _TEST_YELLOW }

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))

    local POWERED, UNPOWERED = ELECTRICAL_MEDIUM.style.powered, ELECTRICAL_MEDIUM.style.unpowered
    local function paintAndCommit(gate2Detent, gate1Winner, sinkState)
        canvas.controls[1].detentIndex = 0 -- gate1 always OFF (open) -- its own ambiguity doesn't depend on its position
        canvas.controls[2].detentIndex = gate2Detent
        canvas.elements[1].pendingColor = _TEST_RED    -- battA: its own registered color
        canvas.elements[2].pendingColor = _TEST_YELLOW -- genB: its own registered color
        canvas.elements[3].pendingColor = POWERED      -- busX: always fed by genB
        canvas.elements[4].pendingColor = sinkState    -- sinkC: the taught condition
        canvas.controls[1].pendingColor = gate1Winner  -- gate1: the taught winner's color
        canvas.controls[2].pendingColor = POWERED      -- gate2: its own node is always reached from battA regardless of position
        gdsGui_schematic_commitSnapshot("unitTestCanvas26", gdsGui_schematic_prepareSnapshot("unitTestCanvas26"))
    end
    paintAndCommit(0, _TEST_RED, UNPOWERED)    -- gate2 OFF (open): sinkC unreached -> battA wins
    paintAndCommit(1, _TEST_YELLOW, POWERED)   -- gate2 ON (closed): sinkC reached -> genB wins

    _recomputeAttributionRules(canvas, graph)
    local rule = canvas.attributionRules["gate1"]
    if not rule or rule.status ~= "learned" then return "fail: rule not learned, status=" .. tostring(rule and rule.status) end

    -- Apply to a live (never-snapshotted-at-this-exact-signature) combination
    -- via the real solve()/solveSourceAttribution() path, exactly like
    -- _solveCurrentSchematic does, not a snapshot lookup.
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local function liveColorAndConfidence()
        local gateStates = _currentGateStates(canvas, componentTypes)
        local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
        local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
        local color = _colorForPoweredNode("gate1", attribution, canvas, { 0.9, 0.9, 0.9, 1 }, nodeStates)
        local confidence = _aiColorAttributionConfidence(canvas, attribution, nodeStates, "gate1")
        return color, confidence
    end

    canvas.controls[2].detentIndex = 1 -- gate2 ON
    local colorWhenOn, confidenceWhenOn = liveColorAndConfidence()
    canvas.controls[2].detentIndex = 0 -- gate2 OFF
    local colorWhenOff, confidenceWhenOff = liveColorAndConfidence()

    local onIsGenB = colorWhenOn[1] == _TEST_YELLOW[1] and colorWhenOn[2] == _TEST_YELLOW[2] and colorWhenOn[3] == _TEST_YELLOW[3]
    local offIsBattA = colorWhenOff[1] == _TEST_RED[1] and colorWhenOff[2] == _TEST_RED[2] and colorWhenOff[3] == _TEST_RED[3]

    return onIsGenB, offIsBattA, confidenceWhenOn > 0, confidenceWhenOff > 0
end

-- Regression test for the real Aircraft 15 report: a bus fed by a 24V
-- battery (direct, no gate) plus two 28V generators (each through its own
-- closed switch) is reached by THREE sources at once, but the top voltage
-- (28V) is shared by two of them — a true parallel tie, not a genuine
-- "which one wins" guess (see _isGenuinelyColorAmbiguous's own comment).
-- Before that check existed, EVERY multi-source node scored 0 confidence
-- unconditionally, which made whole combinations read 0% even though
-- nothing about them was actually uncertain. Verifies: (1) the bus's
-- color is still deterministically the tied-top-voltage color (28V
-- green); (2) its confidence is now 1 (not 0) with NO rule involved at
-- all; (3) a snapshot painted at this exact combination produces NO
-- attribution-rule training example for the bus (nothing genuine to
-- learn from a tie — see _deduceAttributionWinnersForSnapshot's own
-- comment).
function schematicTiedVoltageAttributionConfidenceTest()
    gdsGui_schematic_delete("unitTestCanvas27")
    gdsGui_schematic_create("unitTestCanvas27", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas27", "battA", "rect", 0, 0, 0.1, 0.1, "BATT A", nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas27", "busX", "rect", 0.3, 0, 0.1, 0.1, "BUS X", nil, nil, nil, nil, "path")
    gdsGui_schematic_addControl("unitTestCanvas27", "gate1", 0.5, 0, {"OFF", "ON"}, 1, "GATE 1", nil,
        1, nil, nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas27", "gate2", 0.5, 0.3, {"OFF", "ON"}, 1, "GATE 2", nil,
        1, nil, nil, nil, nil, nil, "source")
    gdsGui_schematic_addWire("unitTestCanvas27", "w1", "battA", "busX", nil)
    gdsGui_schematic_addWire("unitTestCanvas27", "w2", "gate1", "busX", nil)
    gdsGui_schematic_addWire("unitTestCanvas27", "w3", "gate2", "busX", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas27" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    canvas.elements[1].voltage = 24  -- battA
    canvas.controls[1].voltage = 28  -- gate1 (a source control, e.g. a generator)
    canvas.controls[2].voltage = 28  -- gate2 (ditto, tied with gate1)
    canvas.voltageColors = { [24] = _TEST_RED, [28] = _TEST_YELLOW }

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes) -- both controls ON (detentIndex 1)
    local gateStates = _currentGateStates(canvas, componentTypes)
    local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
    local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)

    local color = _colorForPoweredNode("busX", attribution, canvas, { 0.9, 0.9, 0.9, 1 }, nodeStates)
    local confidence = _aiColorAttributionConfidence(canvas, attribution, nodeStates, "busX")
    local isTiedVoltageColor = color[1] == _TEST_YELLOW[1] and color[2] == _TEST_YELLOW[2] and color[3] == _TEST_YELLOW[3]

    -- A snapshot painted at exactly this combination must not generate an
    -- attribution-rule example for busX -- there's nothing genuine to teach.
    local snapshot = { elements = { busX = _TEST_YELLOW, battA = _TEST_RED },
        controls = { gate1 = _TEST_YELLOW, gate2 = _TEST_YELLOW } }
    local signature = gdsGui_schematic_buildSignature({
        { id = "gate1", detentIndex = 1 }, { id = "gate2", detentIndex = 1 },
    })
    local winners = _deduceAttributionWinnersForSnapshot(canvas, graph, signature, snapshot)

    return isTiedVoltageColor, confidence == 1, winners.busX == nil
end

-- Verifies the GLOBAL voltage-dominance rule (model/learner.lua's
-- findVoltageDominanceRule, rebuilt by main.lua's own
-- _recomputeAttributionRules alongside its per-node table — see that
-- function's own comment) actually generalizes "the single highest-
-- voltage contributor wins"
-- ACROSS different node ids, unlike a per-node canvas.attributionRules
-- entry (contrast schematicAttributionRuleLearnedAndAppliedTest above,
-- which only ever teaches ONE node id). Topology: battA(24V) and genB
-- (28V, a source control) share busX directly (no gate — genB always
-- backfeeds battA's own node too, ambiguous between the two whenever genB
-- is on); a THIRD source, battC(24V), joins the same bus only through
-- gate3. One snapshot captured with gate3 OPEN (battC not part of the
-- ambiguity at all yet) paints busX AND battA genB's own registered
-- color — confirming the highest-voltage heuristic, but only ever for
-- busX/battA's node ids, never battC's (which has never been ambiguous in
-- any capture, let alone painted).
-- Verifies: (1) the global rule gets learned from that evidence; (2)
-- canvas.attributionRules has NO entry at all for "battC" (never trained
-- per-node); (3) once gate3 closes and battC becomes ambiguous for the
-- very first time, at a combination never captured, its own color-
-- attribution confidence is already > 0 — covered by the global rule even
-- though nothing was ever taught about battC specifically, the exact
-- generalization the real Aircraft 21 report asked for.
function schematicVoltageDominanceGeneralizesAcrossNodesTest()
    gdsGui_schematic_delete("unitTestCanvas28")
    gdsGui_schematic_create("unitTestCanvas28", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas28", "battA", "rect", 0, 0, 0.1, 0.1, "BATT A", nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas28", "busX", "rect", 0.3, 0, 0.1, 0.1, "BUS X", nil, nil, nil, nil, "path")
    gdsGui_schematic_addElement("unitTestCanvas28", "battC", "rect", 0.6, 0.3, 0.1, 0.1, "BATT C", nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas28", "genB", 0.6, 0, {"OFF", "ON"}, 1, "GEN B", nil,
        1, nil, nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas28", "gate3", 0.45, 0.3, {"OFF", "ON"}, 0, "GATE 3", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addWire("unitTestCanvas28", "w1", "battA", "busX", nil)
    gdsGui_schematic_addWire("unitTestCanvas28", "w2", "genB", "busX", nil)
    gdsGui_schematic_addWire("unitTestCanvas28", "w3", "battC", "gate3", nil)
    gdsGui_schematic_addWire("unitTestCanvas28", "w4", "gate3", "busX", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas28" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    canvas.elements[1].voltage = 24 -- battA
    canvas.elements[3].voltage = 24 -- battC
    canvas.controls[1].voltage = 28 -- genB
    canvas.voltageColors = { [24] = _TEST_RED, [28] = _TEST_YELLOW }

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))

    -- Capture ONE snapshot: gate3 OPEN (battC isolated, not part of the
    -- ambiguity at all), genB ON — busX, battA AND genB's own node are all
    -- ambiguous between {battA, genB}, painted genB's own color at every
    -- one of them (the generator backfeeding the battery's own node too,
    -- same convention the real captured data used) — confirms the
    -- heuristic at 3 different nodes AT ONCE, but since they're all the
    -- SAME underlying event, this is still only ONE dominance example
    -- (see _recomputeAttributionRules' own "one example per snapshot, not
    -- per node" comment). This topology's own combination space (2
    -- controls, 4 combos total) only has TWO combinations where the
    -- hypothesis is even testable at all — this one (gate3 open) and
    -- battC's own target combo (gate3 closed) — so teachableTotal = 2,
    -- and with that target excluded (see _aiColorAttributionConfidence's
    -- own "-1" comment) there's exactly ONE other testable combination,
    -- already confirmed: battC's confidence should come out at 100%, not
    -- merely ">0".
    canvas.controls[2].detentIndex = 0 -- gate3 OFF (open)
    canvas.elements[1].pendingColor = _TEST_YELLOW -- battA: backfed by genB
    canvas.elements[2].pendingColor = _TEST_YELLOW -- busX: backfed by genB
    canvas.elements[3].pendingColor = { 0.75, 0.75, 0.75, 1 } -- battC: isolated by open gate3, flat unpowered gray
    canvas.controls[1].pendingColor = _TEST_YELLOW -- genB: its own color
    canvas.controls[2].pendingColor = { 0.75, 0.75, 0.75, 1 } -- gate3: open, flat unpowered gray
    gdsGui_schematic_commitSnapshot("unitTestCanvas28", gdsGui_schematic_prepareSnapshot("unitTestCanvas28"))

    _recomputeAttributionRules(canvas, graph)

    if canvas.attributionRules["battC"] then
        return "fail: battC should have no per-node rule at all (never ambiguous in any capture)"
    end
    if not canvas.voltageDominanceRule or canvas.voltageDominanceRule.status ~= "learned" then
        return "fail: global voltage-dominance rule not learned, status=" ..
            tostring(canvas.voltageDominanceRule and canvas.voltageDominanceRule.status)
    end

    -- Close gate3: battC joins the bus and becomes ambiguous for the very
    -- first time, at a combination nothing was ever captured for.
    canvas.controls[2].detentIndex = 1 -- gate3 ON (closed)
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local gateStates = _currentGateStates(canvas, componentTypes)
    local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)
    local attribution = ModelSolver.solveSourceAttribution(graph, sourceStates, gateStates)
    local battCConfidence = _aiColorAttributionConfidence(canvas, attribution, nodeStates, "battC", gateStates, sourceStates)
    local battCColor = _colorForPoweredNode("battC", attribution, canvas, { 0.9, 0.9, 0.9, 1 }, nodeStates)
    local battCIsGenBColor = battCColor[1] == _TEST_YELLOW[1] and battCColor[2] == _TEST_YELLOW[2] and battCColor[3] == _TEST_YELLOW[3]

    return battCConfidence == 1, battCIsGenBColor
end

-- Changing ELECTRICAL_MEDIUM.style.powered (what
-- schematicPoweredColorChosen actually does) must make _stateForColor
-- recognize the NEW color as "powered" and stop recognizing the OLD one —
-- the exact trade-off called out in this section's own comment above
-- _openElectricalColorsMenu: paint/predict/deduce all move together, but a
-- snapshot painted under the old color needs repainting to keep being
-- learned from.
function schematicElectricalColorOverride_stateForColorTest()
    local originalPowered = ELECTRICAL_MEDIUM.style.powered
    local oldColor = { 1, 1, 0, 1 }
    local newColor = { 0, 1, 0, 1 }

    ELECTRICAL_MEDIUM.style.powered = newColor
    local recognizesNew = _stateForColor(newColor) == "powered"
    local recognizesOld = _stateForColor(oldColor) == "powered"
    ELECTRICAL_MEDIUM.style.powered = originalPowered -- restore before any other test runs

    return recognizesNew, recognizesOld
end

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

-- The management panel's edit menu's DELETE option: DELETE is that menu's
-- own confirmIndex row (see gdsGui_schematic_openAnnunciatorEditMenu), so
-- the held-to-completion hold and the plain-tap RENAME/COLOR rows share one
-- onSelect dispatch — calling it directly with optionText "DELETE" is
-- exactly what a completed hold fires, no separate confirm popup involved.
function schematicAnnunciatorDeleteTest()
    gdsGui_schematic_delete("unitTestCanvas11")
    gdsGui_schematic_create("unitTestCanvas11", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addAnnunciator("unitTestCanvas11", "a1", "MASTER CAUTION", {1, 1, 0, 1}, true)
    gdsGui_schematic_openAnnunciatorEditMenu("unitTestCanvas11", "a1")
    gdsGui_schematic_internal_onAnnunciatorEditChosen("unitTestCanvas11", 3, "DELETE")
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas11" then return #c.annunciators end
    end
    return -1
end

-- The edit menu's RENAME option, end to end: open the menu, choose RENAME,
-- confirm a new label through the same callback the text prompt itself uses.
function schematicAnnunciatorRenameTest()
    gdsGui_schematic_delete("unitTestCanvas12")
    gdsGui_schematic_create("unitTestCanvas12", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addAnnunciator("unitTestCanvas12", "a1", "MASTER CAUTION", {1, 1, 0, 1}, true)
    gdsGui_schematic_openAnnunciatorEditMenu("unitTestCanvas12", "a1")
    gdsGui_schematic_internal_onAnnunciatorEditChosen("unitTestCanvas12", 1, "RENAME")
    gdsGui_schematic_annunciatorRenameConfirmed("FIRE WARN")
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas12" then
            for _, a in ipairs(c.annunciators) do
                if a.id == "a1" then return a.label end
            end
        end
    end
    return "not found"
end

-- The edit menu's COLOR option, end to end: open the menu, choose COLOR,
-- pick a swatch through the same callback the swatch picker itself uses —
-- mirrors the creation-time color pick (gdsGui_schematic_internal_
-- onAnnunciatorColorChosen) but mutates the existing entry's .color in
-- place instead of building a new one.
function schematicAnnunciatorColorEditTest()
    gdsGui_schematic_delete("unitTestCanvas14")
    gdsGui_schematic_create("unitTestCanvas14", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addAnnunciator("unitTestCanvas14", "a1", "MASTER CAUTION", {1, 1, 1, 1}, true)
    gdsGui_schematic_openAnnunciatorEditMenu("unitTestCanvas14", "a1")
    gdsGui_schematic_internal_onAnnunciatorEditChosen("unitTestCanvas14", 2, "COLOR")
    gdsGui_schematic_internal_onAnnunciatorColorEditChosen("unitTestCanvas14", 1)
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas14" then
            for _, a in ipairs(c.annunciators) do
                if a.id == "a1" then return a.color[1] end
            end
        end
    end
    return -1
end

-- Renaming to a label already in use by another annunciator (shared
-- namespace with elements/controls — see _labelInUse) must be rejected, same
-- as it would be for an element — the target keeps its original label.
function schematicAnnunciatorRenameRejectsDuplicateTest()
    gdsGui_schematic_delete("unitTestCanvas13")
    gdsGui_schematic_create("unitTestCanvas13", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addAnnunciator("unitTestCanvas13", "a1", "MASTER CAUTION", {1, 1, 0, 1}, true)
    gdsGui_schematic_addAnnunciator("unitTestCanvas13", "a2", "MASTER WARNING", {1, 0, 0, 1}, true)
    gdsGui_schematic_openAnnunciatorEditMenu("unitTestCanvas13", "a2")
    gdsGui_schematic_internal_onAnnunciatorEditChosen("unitTestCanvas13", 1, "RENAME")
    gdsGui_schematic_annunciatorRenameConfirmed("MASTER CAUTION")
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas13" then
            for _, a in ipairs(c.annunciators) do
                if a.id == "a2" then return a.label end
            end
        end
    end
    return "not found"
end

-------------------------------------------------------------------------------
-- SCHEMATIC PROJECT PERSISTENCE HARDENING TESTS
-- Exercise _loadSchematicStoreSafely/_verifyAndRepairSchematicStore/
-- _buildSchematicCompatNotice directly against throwaway filenames/tables —
-- never the real schematicProjects.lua/appSettings, so a test run can never
-- put the user's own saved aircraft at risk.
-------------------------------------------------------------------------------

-- A primary file that fails to even parse (truncated/corrupt) must fall back
-- to its .bak rather than losing the store — see _loadSchematicStoreSafely's
-- "corrupted" branch.
function schematicLoadSafely_corruptPrimary_restoresFromBackupTest()
    local testFile = "unitTestCorruptStore.lua"
    love.filesystem.write(testFile, "schematicStore = { aircraft = { broken")
    love.filesystem.write(testFile .. ".bak",
        "schematicStore = { aircraft = {{ id = \"ac1\", name = \"Backup Aircraft\", systems = {} }} }")

    local savedRealStore = schematicStore
    local status = _loadSchematicStoreSafely(testFile)
    local recoveredId = schematicStore and schematicStore.aircraft and
        schematicStore.aircraft[1] and schematicStore.aircraft[1].id or "none"
    schematicStore = savedRealStore

    love.filesystem.remove(testFile)
    love.filesystem.remove(testFile .. ".bak")
    -- _loadSchematicStoreSafely promotes the recovered backup back over the
    -- (now-archived) primary name, and the corrupt original is archived
    -- under "<testFile>.corrupt-<timestamp>" rather than deleted outright —
    -- clean up whatever that timestamp turned out to be.
    for _, item in ipairs(love.filesystem.getDirectoryItems("")) do
        if item:match("^" .. testFile:gsub("%.", "%%.") .. "%.corrupt%-%d+$") then
            love.filesystem.remove(item)
        end
    end

    if status == "restoredFromBackup" and recoveredId == "ac1" then return 1 end
    return 0
end

-- Two elements sharing an id in a loaded system must both survive with
-- distinct ids, never silently collapse into one — see _dedupeIds.
function schematicRepair_dedupesElementIdsTest()
    local store = { aircraft = {
        { id = "ac1", name = "Test Aircraft", systems = {
            { id = "sys1", name = "Electrical",
              elements = { { id = "el_1", label = "A" }, { id = "el_1", label = "B" } },
              wires = {}, controls = {}, annunciators = {} },
        } },
    } }
    local repair = _verifyAndRepairSchematicStore(store)
    local els = store.aircraft[1].systems[1].elements
    if #els == 2 and els[1].id ~= els[2].id and #repair.notes >= 1 then return 1 end
    return 0
end

-- The compat notice is built from a load status, but whether it's actually
-- shown is gated on appSettings.schematicCompatCheckedVersion ~= APP_VERSION
-- (see love.load()) — verifies that gate flips to "already checked" after
-- being marked, the same one-time-per-version behavior tcAcceptedVersion
-- already relies on elsewhere in this file.
function schematicCompatNotice_gatesOncePerVersionTest()
    local savedCheckedVersion = appSettings.schematicCompatCheckedVersion
    appSettings.schematicCompatCheckedVersion = nil
    local firstBoot  = appSettings.schematicCompatCheckedVersion ~= APP_VERSION
    appSettings.schematicCompatCheckedVersion = APP_VERSION
    local secondBoot = appSettings.schematicCompatCheckedVersion ~= APP_VERSION
    appSettings.schematicCompatCheckedVersion = savedCheckedVersion

    local notice = _buildSchematicCompatNotice("ok", { notes = {}, aircraftCount = 2, systemCount = 3 })
    local mentionsCounts = notice:find("2 aircraft") ~= nil

    if firstBoot and not secondBoot and mentionsCounts then return 1 end
    return 0
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
-- INFERENCE MODEL TESTS
-- model/graph.lua + model/solver.lua are pure Lua and need no canvas at all
-- — hand-built node/edge tables exercise them directly, same "pure logic
-- tested directly" convention _toJSON-style helpers elsewhere in this file
-- use. The integration test below instead exercises the real main.lua
-- adapter helpers (_buildComponentTypeMap/_currentGateStates/
-- _currentSourceStates, which DO take an explicit canvas table) against a
-- throwaway canvas fetched the same way every other schematic test here
-- does, composed with the same model calls and
-- gdsGui_schematic_applySolvedColors/resolveColor the real
-- _solveCurrentSchematic uses — full Phase 1 adapter path, still isolated
-- from "mainCanvas".
-------------------------------------------------------------------------------

function modelSolverClosedGatePowersSinkTest()
    local elements = { {id = "s1"}, {id = "sink1"} }
    local controls = { {id = "g1"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "g1" },
        { id = "w2", fromElementId = "g1", toElementId = "sink1" },
    }
    local componentTypes = { s1 = "source", g1 = "gate", sink1 = "sink" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local states = ModelSolver.solve(graph, { s1 = true }, { g1 = "closed" })
    return states.sink1
end

function modelSolverOpenGateBlocksSinkTest()
    local elements = { {id = "s1"}, {id = "sink1"} }
    local controls = { {id = "g1"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "g1" },
        { id = "w2", fromElementId = "g1", toElementId = "sink1" },
    }
    local componentTypes = { s1 = "source", g1 = "gate", sink1 = "sink" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local states = ModelSolver.solve(graph, { s1 = true }, { g1 = "open" })
    return states.sink1
end

-- bus2 is reachable from the source two ways: through g1, and directly via
-- w4 — so it must still have an alternate path once w3 (the edge out of
-- g1) is excluded.
function modelGraphHasAltPathTest()
    local elements = { {id = "s1"}, {id = "bus1"}, {id = "bus2"} }
    local controls = { {id = "g1"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "bus1" },
        { id = "w2", fromElementId = "bus1", toElementId = "g1" },
        { id = "w3", fromElementId = "g1", toElementId = "bus2" },
        { id = "w4", fromElementId = "s1", toElementId = "bus2" },
    }
    local componentTypes = { s1 = "source", bus1 = "path", bus2 = "path", g1 = "gate" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    return ModelGraph.hasAltPath(graph, "bus2", "w3")
end

-- s1 (on) feeds bus1 directly; s2 (off, e.g. an off generator) also sits on
-- bus1, with sink2 wired only through s2. s2's own terminal must read
-- powered (the real wire from bus1 carries voltage right up to it, same as
-- a gate's input terminal) but it must still block propagation PAST
-- itself, same as a gate blocks onward when open — so sink2, reachable
-- only through s2, must stay unpowered.
function modelSolverOffSourceReachedButBlocksPastTest()
    local elements = { {id = "bus1"}, {id = "sink2"} }
    local controls = { {id = "s1"}, {id = "s2"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "bus1" },
        { id = "w2", fromElementId = "bus1", toElementId = "s2" },
        { id = "w3", fromElementId = "s2", toElementId = "sink2" },
    }
    local componentTypes = { s1 = "source", s2 = "source", bus1 = "path", sink2 = "sink" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local states = ModelSolver.solve(graph, { s1 = true, s2 = false }, {})
    return states.s2, states.sink2
end

-- A diode (d1, rotation 0 -- its own artwork points +x, see
-- schematic_gdsGuiLib.lua's _drawDiodeSymbol) sits between "left" and
-- "right", BOTH wires deliberately drawn pointing OUT of the diode
-- (d1->left, d1->right) -- the exact "inconsistent per-wire draw order"
-- bug class reported against the old convention. With real positions
-- supplied, geometry must override that draw order entirely: current
-- should flow left->right (matching the diode's rotation), never the
-- reverse, regardless of how either wire was drawn.
function modelGraphDiodeDirectionFromRotationTest()
    local elements = { {id = "left"}, {id = "right"}, {id = "d1"} }
    local controls = {}
    local wires = {
        { id = "w1", fromElementId = "d1", toElementId = "left" },
        { id = "w2", fromElementId = "d1", toElementId = "right" },
    }
    local positions = {
        left = { x = 0.2, y = 0.5, rotation = 0 },
        d1 = { x = 0.5, y = 0.5, rotation = 0 },
        right = { x = 0.8, y = 0.5, rotation = 0 },
    }
    local forwardTypes = { left = "source", right = "sink", d1 = "directionalGate" }
    local forwardGraph = ModelGraph.buildGraph(elements, controls, wires, forwardTypes, positions)
    local rightPowered = ModelSolver.solve(forwardGraph, { left = true }, {}).right

    local reverseTypes = { left = "sink", right = "source", d1 = "directionalGate" }
    local reverseGraph = ModelGraph.buildGraph(elements, controls, wires, reverseTypes, positions)
    local leftPowered = ModelSolver.solve(reverseGraph, { right = true }, {}).left

    return rightPowered, leftPowered
end

-- The exact real-world layout that broke a plain sign-of-cosine test: a
-- source (e.g. an off generator) wired in from dead BELOW a diode (a
-- perpendicular bearing relative to the diode's own rotation-0/pointing-
-- right axis) whose wire then bends sideways to a bus up and to the
-- right. The connection is drawn correctly; only the diode's sibling
-- comparison (see _resolveDirectionalEdges) can tell that "perpendicular"
-- neighbor is still the relatively-more-behind one of the two, and so the
-- entry/anode side. Mirrors GENR_1/DIODE_7/BUS_3 from a real saved
-- schematic.
function modelGraphDiodeDirectionIgnoresPerpendicularBendTest()
    local elements = { {id = "bus1"}, {id = "d1"} }
    local controls = { {id = "gen1"} }
    local wires = {
        { id = "w1", fromElementId = "gen1", toElementId = "d1" },
        { id = "w2", fromElementId = "d1", toElementId = "bus1" },
    }
    local componentTypes = { bus1 = "path", d1 = "directionalGate", gen1 = "source" }
    local positions = {
        gen1 = { x = 0.4416, y = 0.4871, rotation = 0 },  -- straight below d1: perpendicular bearing
        d1   = { x = 0.4416, y = 0.4403, rotation = 0 },
        bus1 = { x = 0.5415, y = 0.4169, rotation = 0 },  -- up and to the right: on-axis
    }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes, positions)
    local poweredFromGenerator = ModelSolver.solve(graph, { gen1 = true }, {}).bus1
    local backfeedIntoGenerator = ModelSolver.solve(graph, { gen1 = false }, {}).gen1
    return poweredFromGenerator, backfeedIntoGenerator
end

-- Two diodes wired DIRECTLY together, each rotated so its own cathode
-- faces the other (d1 rotation 180 points away from d2 sitting to its
-- right; d2 rotation 0 points away from d1 sitting to its left) -- a
-- genuine contradiction, since neither diode's own rotation agrees on
-- who feeds whom. The old code only ever consulted whichever end
-- happened to be the wire's own fromElementId (here d1), confidently
-- REVERSING the wire's drawn d1->d2 order to d2->d1 off that single,
-- arbitrarily-picked side while silently ignoring that d2's own rotation
-- disagrees just as much. The fix (_resolveDirectionalEdges' bothGates
-- branch) detects the contradiction and leaves the edge unresolved,
-- which makes buildGraph fall back to the wire's own original d1->d2
-- draw order instead of confidently asserting the reverse.
function modelGraphDiodeToDiodeContradictionFallsBackToDrawOrderTest()
    local elements = { {id = "d1"}, {id = "d2"} }
    local wires = {
        { id = "w1", fromElementId = "d1", toElementId = "d2" },
    }
    local positions = {
        d1 = { x = 0.3, y = 0.5, rotation = 180 }, -- forward points away from d2
        d2 = { x = 0.5, y = 0.5, rotation = 0 },   -- forward points away from d1
    }
    local componentTypes = { d1 = "directionalGate", d2 = "directionalGate" }
    local graph = ModelGraph.buildGraph(elements, {}, wires, componentTypes, positions)
    local w1Edge = nil
    for _, e in ipairs(graph.edges) do if e.id == "w1" then w1Edge = e end end
    return w1Edge.fromId, w1Edge.toId
end

-- Integration test for the directionalGate wire-coloring fix
-- (_solveCurrentSchematic's own wire loop, reproduced manually here since
-- that function is hardcoded to "mainCanvas" only — same reason
-- schematicComponentTypePropagationTest below reproduces its solve step
-- by hand): a diode (rotation 270, so it conducts upward) sits between an
-- OFF generator below it and a bus above it that's ALSO independently fed
-- by an always-on battery, wired straight to the bus with no gate between
-- them. The diode's own node must stay unpowered (nothing feeds its
-- anode/generator side) but the wire from the diode to the bus must still
-- read powered -- it's directly wired to an already-hot bus, and the
-- diode's single shared node can't represent its two leads (hot cathode,
-- cold anode) independently. Without the fix, requiring both wire ends
-- powered off that single node would leave this wire gray forever.
function schematicDiodeCathodeWireFollowsBusTest()
    gdsGui_schematic_delete("unitTestCanvas22")
    gdsGui_schematic_create("unitTestCanvas22", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addControl("unitTestCanvas22", "gen1", 0.3, 0.6, {"OFF", "ON"}, 0, "GEN 1", nil,
        1, nil, 0, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas22", "diode1", "diode", 0.28, 0.4, 0.05, 0.05, "D1", nil,
        nil, 270, nil, "directionalGate")
    gdsGui_schematic_addElement("unitTestCanvas22", "bus1", "rect", 0.3, 0.1, 0.1, 0.1, "BUS 1", nil,
        nil, 0, nil, "path")
    gdsGui_schematic_addElement("unitTestCanvas22", "batt1", "rect", 0.6, 0.1, 0.1, 0.1, "BATT 1", nil,
        nil, 0, nil, "source")
    gdsGui_schematic_addWire("unitTestCanvas22", "w1", "gen1", "diode1", nil)
    gdsGui_schematic_addWire("unitTestCanvas22", "w2", "diode1", "bus1", nil)
    gdsGui_schematic_addWire("unitTestCanvas22", "w3", "batt1", "bus1", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas22" then canvas = c end
    end
    if not canvas then return "canvas not found" end

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes,
        _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local gateStates = _currentGateStates(canvas, componentTypes)
    local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)

    local w2 = nil
    for _, w in ipairs(canvas.wires) do if w.id == "w2" then w2 = w end end
    local fromIsGate = componentTypes[w2.fromElementId] == "directionalGate"
    local otherId = fromIsGate and w2.toElementId or w2.fromElementId
    local wirePowered = nodeStates[otherId] == ModelSolver.POWERED

    return nodeStates.diode1, wirePowered
end

-- Full Phase 1 adapter path against a throwaway canvas: GEN 1 (source,
-- control) -> SW 1 (gate, control) -> BUS 1 (path, element), switch ON,
-- never a single snapshot painted. If propagation is wiring correctly, BUS
-- 1 resolves straight to the electrical medium's "powered" color via the
-- predictedColor tier — this is Phase 1's whole point.
function schematicComponentTypePropagationTest()
    gdsGui_schematic_delete("unitTestCanvas20")
    gdsGui_schematic_create("unitTestCanvas20", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addControl("unitTestCanvas20", "gen1", 0, 0, {"OFF", "ON"}, 1, "GEN 1", nil,
        1, nil, nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas20", "sw1", 0.3, 0, {"OFF", "ON"}, 1, "SW 1", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addElement("unitTestCanvas20", "bus1", "rect", 0.6, 0, 0.1, 0.1, "BUS 1", nil,
        nil, nil, nil, "path")
    gdsGui_schematic_addWire("unitTestCanvas20", "w1", "gen1", "sw1", nil)
    gdsGui_schematic_addWire("unitTestCanvas20", "w2", "sw1", "bus1", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas20" then canvas = c end
    end
    if not canvas then return "canvas not found" end

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local sourceStates = _currentSourceStates(canvas, componentTypes)
    local gateStates = _currentGateStates(canvas, componentTypes)
    local nodeStates = ModelSolver.solve(graph, sourceStates, gateStates)

    gdsGui_schematic_applySolvedColors("unitTestCanvas20",
        { elements = { bus1 = ELECTRICAL_MEDIUM.style[nodeStates.bus1] }, wires = {}, controls = {} })
    local r = gdsGui_schematic_resolveColor("unitTestCanvas20", "element", "bus1")
    return r
end

-- Same source -> gate -> sink topology as the solver tests above, but this
-- time the gate itself is reached (powered) and the sink is ALSO powered
-- with no alternate path to the source — the only way that's consistent
-- is a closed gate.
function modelLearnerInferGateClosedTest()
    local elements = { {id = "s1"}, {id = "sink1"} }
    local controls = { {id = "g1"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "g1" },
        { id = "w2", fromElementId = "g1", toElementId = "sink1" },
    }
    local componentTypes = { s1 = "source", g1 = "gate", sink1 = "sink" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local nodeStates = { s1 = "powered", g1 = "powered", sink1 = "powered" }
    return ModelLearner.inferGate("g1", nodeStates, graph)
end

-- Same topology, gate reached (powered) but the sink is unpowered — the
-- only way that's consistent is an open gate.
function modelLearnerInferGateOpenTest()
    local elements = { {id = "s1"}, {id = "sink1"} }
    local controls = { {id = "g1"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "g1" },
        { id = "w2", fromElementId = "g1", toElementId = "sink1" },
    }
    local componentTypes = { s1 = "source", g1 = "gate", sink1 = "sink" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local nodeStates = { s1 = "powered", g1 = "powered", sink1 = "unpowered" }
    return ModelLearner.inferGate("g1", nodeStates, graph)
end

-- The gate was never even reached in this snapshot (everything unpowered)
-- — there's no evidence either way, so this must stay "unknown", never a
-- guess.
function modelLearnerInferGateUnknownWhenUnreachedTest()
    local elements = { {id = "s1"}, {id = "sink1"} }
    local controls = { {id = "g1"} }
    local wires = {
        { id = "w1", fromElementId = "s1", toElementId = "g1" },
        { id = "w2", fromElementId = "g1", toElementId = "sink1" },
    }
    local componentTypes = { s1 = "source", g1 = "gate", sink1 = "sink" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local nodeStates = { s1 = "unpowered", g1 = "unpowered", sink1 = "unpowered" }
    return ModelLearner.inferGate("g1", nodeStates, graph)
end

-- Integration test against a throwaway canvas: source -> gate (a real,
-- user-toggled control here, same as Phase 1's test — inferGate doesn't
-- care HOW the gate's position was set, only what the painted colors show)
-- -> sink. Captures two real snapshots via the actual prepareSnapshot/
-- commitSnapshot path (one with the gate closed, one open), each hand-
-- painted via pendingColor exactly like the PAINT tool's _applyPaint does
-- internally, then asserts model/learner.lua deduces the right state for
-- each snapshot purely from its own colors.
function schematicDeducedGateStatesFromSnapshotsTest()
    gdsGui_schematic_delete("unitTestCanvas21")
    gdsGui_schematic_create("unitTestCanvas21", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas21", "s1", "rect", 0, 0, 0.1, 0.1, "SRC", nil, nil, nil, nil, "source")
    gdsGui_schematic_addControl("unitTestCanvas21", "g1", 0.3, 0, {"OPEN", "CLOSED"}, 0, "G1", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addElement("unitTestCanvas21", "snk1", "rect", 0.6, 0, 0.1, 0.1, "SNK", nil, nil, nil, nil, "sink")
    gdsGui_schematic_addWire("unitTestCanvas21", "w1", "s1", "g1", nil)
    gdsGui_schematic_addWire("unitTestCanvas21", "w2", "g1", "snk1", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas21" then canvas = c end
    end
    if not canvas then return false end

    local POWERED, UNPOWERED = ELECTRICAL_MEDIUM.style.powered, ELECTRICAL_MEDIUM.style.unpowered

    -- Snapshot 1: gate at detent 1 ("CLOSED"), everything painted powered.
    canvas.controls[1].detentIndex = 1
    canvas.elements[1].pendingColor = POWERED -- s1
    canvas.controls[1].pendingColor = POWERED -- g1
    canvas.elements[2].pendingColor = POWERED -- snk1
    gdsGui_schematic_commitSnapshot("unitTestCanvas21", gdsGui_schematic_prepareSnapshot("unitTestCanvas21"))
    local sigClosed = gdsGui_schematic_computeSignature("unitTestCanvas21")

    -- Snapshot 2: gate at detent 0 ("OPEN") — still energized at its own
    -- input, but the sink it feeds is unreached.
    canvas.controls[1].detentIndex = 0
    canvas.elements[1].pendingColor = POWERED
    canvas.controls[1].pendingColor = POWERED
    canvas.elements[2].pendingColor = UNPOWERED
    gdsGui_schematic_commitSnapshot("unitTestCanvas21", gdsGui_schematic_prepareSnapshot("unitTestCanvas21"))
    local sigOpen = gdsGui_schematic_computeSignature("unitTestCanvas21")

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))
    local closedStates = ModelLearner.deduceAllGates(graph, _snapshotToNodeStates(canvas.snapshots[sigClosed], graph))
    local openStates = ModelLearner.deduceAllGates(graph, _snapshotToNodeStates(canvas.snapshots[sigOpen], graph))

    return closedStates.g1 == "closed" and openStates.g1 == "open"
end

-- A condition that perfectly predicts the gate's result in both examples
-- -> a learned single-condition rule naming that exact condition.
function modelLearnerFindRuleSingleConditionTest()
    local examples = {
        { nodeStates = { cond = "powered" }, result = "closed" },
        { nodeStates = { cond = "unpowered" }, result = "open" },
    }
    local rule = ModelLearner.findSimplestRule("g1", examples, { "cond" })
    if rule.status ~= "learned" then return "fail:" .. tostring(rule.status) end
    return rule.conditionIds[1], rule.resultState
end

-- The only candidate condition contradicts itself (same state, different
-- results across examples) -- never guess, report no consistent rule.
function modelLearnerFindRuleContradictionTest()
    local examples = {
        { nodeStates = { cond = "powered" }, result = "closed" },
        { nodeStates = { cond = "powered" }, result = "open" },
    }
    local rule = ModelLearner.findSimplestRule("g1", examples, { "cond" })
    return rule.status
end

-- Neither condition alone explains the gate (each contradicts itself in
-- isolation), but the PAIR together does -- single-condition search must
-- exhaust before falling through to pairs.
function modelLearnerFindRulePairConditionTest()
    local examples = {
        { nodeStates = { condA = "powered", condB = "powered" }, result = "closed" },
        { nodeStates = { condA = "powered", condB = "unpowered" }, result = "open" },
        { nodeStates = { condA = "unpowered", condB = "powered" }, result = "open" },
    }
    local rule = ModelLearner.findSimplestRule("g1", examples, { "condA", "condB" })
    if rule.status ~= "learned" then return "fail:" .. tostring(rule.status) end
    return #rule.conditionIds
end

-- Integration test: two independently-toggled gates (g1 feeding sink1,
-- swA feeding busA, no wire between the two branches at all) painted
-- across two snapshots so that g1's deduced state tracks busA's power
-- exactly, while every other node (s1, s2, swA, sink1 by itself) is
-- either constant or IS the gate's own direct effect — proving the
-- learner picks the genuinely correlated, independent busA over those,
-- purely from candidate order (busA sorts first alphabetically here).
function schematicGateRuleLearnedFromSnapshotsTest()
    gdsGui_schematic_delete("unitTestCanvas22")
    gdsGui_schematic_create("unitTestCanvas22", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas22", "s1", "rect", 0, 0, 0.1, 0.1, "S1", nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas22", "sink1", "rect", 0.6, 0, 0.1, 0.1, "SNK", nil, nil, nil, nil, "sink")
    gdsGui_schematic_addElement("unitTestCanvas22", "s2", "rect", 0, 0.3, 0.1, 0.1, "S2", nil, nil, nil, nil, "source")
    gdsGui_schematic_addElement("unitTestCanvas22", "busA", "rect", 0.6, 0.3, 0.1, 0.1, "BUSA", nil, nil, nil, nil, "path")
    gdsGui_schematic_addControl("unitTestCanvas22", "g1", 0.3, 0, {"OPEN", "CLOSED"}, 0, "G1", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addControl("unitTestCanvas22", "swA", 0.3, 0.3, {"OPEN", "CLOSED"}, 0, "SWA", nil,
        1, nil, nil, nil, nil, nil, "gate")
    gdsGui_schematic_addWire("unitTestCanvas22", "w1", "s1", "g1", nil)
    gdsGui_schematic_addWire("unitTestCanvas22", "w2", "g1", "sink1", nil)
    gdsGui_schematic_addWire("unitTestCanvas22", "w3", "s2", "swA", nil)
    gdsGui_schematic_addWire("unitTestCanvas22", "w4", "swA", "busA", nil)

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas22" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    local POWERED, UNPOWERED = ELECTRICAL_MEDIUM.style.powered, ELECTRICAL_MEDIUM.style.unpowered

    -- Snapshot 1: both gates CLOSED -- g1 closed (sink powered), busA powered.
    canvas.controls[1].detentIndex = 1 -- g1
    canvas.controls[2].detentIndex = 1 -- swA
    canvas.elements[1].pendingColor = POWERED   -- s1
    canvas.controls[1].pendingColor = POWERED   -- g1
    canvas.elements[2].pendingColor = POWERED   -- sink1
    canvas.elements[3].pendingColor = POWERED   -- s2
    canvas.controls[2].pendingColor = POWERED   -- swA
    canvas.elements[4].pendingColor = POWERED   -- busA
    gdsGui_schematic_commitSnapshot("unitTestCanvas22", gdsGui_schematic_prepareSnapshot("unitTestCanvas22"))

    -- Snapshot 2: both gates OPEN -- g1 open (sink unpowered), busA unpowered.
    canvas.controls[1].detentIndex = 0
    canvas.controls[2].detentIndex = 0
    canvas.elements[1].pendingColor = POWERED
    canvas.controls[1].pendingColor = POWERED
    canvas.elements[2].pendingColor = UNPOWERED
    canvas.elements[3].pendingColor = POWERED
    canvas.controls[2].pendingColor = POWERED
    canvas.elements[4].pendingColor = UNPOWERED
    gdsGui_schematic_commitSnapshot("unitTestCanvas22", gdsGui_schematic_prepareSnapshot("unitTestCanvas22"))

    local componentTypes = _buildComponentTypeMap(canvas)
    local graph = ModelGraph.buildGraph(canvas.elements, canvas.controls, canvas.wires, componentTypes, _nodePositionsForGraph(canvas))

    local examples = {}
    for _, snapshot in pairs(canvas.snapshots) do
        local nodeStates = _snapshotToNodeStates(snapshot, graph)
        local gateStates = ModelLearner.deduceAllGates(graph, nodeStates)
        if gateStates.g1 ~= ModelLearner.UNKNOWN then
            table.insert(examples, { nodeStates = nodeStates, result = gateStates.g1 })
        end
    end

    local candidateIds = {}
    for id in pairs(graph.nodes) do
        if id ~= "g1" then table.insert(candidateIds, id) end
    end
    table.sort(candidateIds)

    local rule = ModelLearner.findSimplestRule("g1", examples, candidateIds)
    if rule.status ~= "learned" then return "fail: " .. tostring(rule.status) end
    if rule.conditionIds[1] ~= "busA" then return "fail: conditionId=" .. tostring(rule.conditionIds[1]) end
    return rule.resultState
end

-- An independent bus (busX) is always powered regardless of g1 -- the
-- rule's verdict never changes, so the feedback loop settles immediately.
function modelSolverSolveWithRulesConvergesTest()
    local elements = { {id="s1"}, {id="sink1"}, {id="sX"}, {id="busX"} }
    local controls = { {id="g1"} }
    local wires = {
        { id="w1", fromElementId="s1", toElementId="g1" },
        { id="w2", fromElementId="g1", toElementId="sink1" },
        { id="w3", fromElementId="sX", toElementId="busX" },
    }
    local componentTypes = { s1="source", g1="gate", sink1="sink", sX="source", busX="path" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local rule = { status="learned", conditionIds={"busX"}, conditionStates={busX="powered"}, resultState="closed" }
    local result = ModelSolver.solveWithRules(graph, { s1=true, sX=true }, {}, { g1=rule })
    return result.converged, result.gateStates.g1
end

-- g1 is told to close exactly when the one bus it SOLELY feeds is
-- unpowered -- i.e. exactly when g1 itself is currently open -- so every
-- re-evaluation flips it. No fixed point exists; must report non-convergence.
function modelSolverSolveWithRulesDetectsOscillationTest()
    local elements = { {id="s1"}, {id="busA"} }
    local controls = { {id="g1"} }
    local wires = {
        { id="w1", fromElementId="s1", toElementId="g1" },
        { id="w2", fromElementId="g1", toElementId="busA" },
    }
    local componentTypes = { s1="source", g1="gate", busA="path" }
    local graph = ModelGraph.buildGraph(elements, controls, wires, componentTypes)
    local rule = { status="learned", conditionIds={"busA"}, conditionStates={busA="unpowered"}, resultState="closed" }
    local result = ModelSolver.solveWithRules(graph, { s1=true }, {}, { g1=rule })
    return result.converged
end

function formatRuleTextLearnedSingleConditionTest()
    local rule = { status="learned", conditionIds={"busA"}, conditionStates={busA="powered"}, resultState="closed" }
    return _formatRuleText("g1", rule, { g1="RELAY 1", busA="BUS A" })
end

function formatRuleTextNoRuleYetTest()
    return _formatRuleText("g1", { status="noRule" }, { g1="RELAY 1" })
end

-- _labelsByIdForCanvas (the live-canvas adapter) feeding straight into
-- _formatRuleText, against real elements/controls with their own labels.
function schematicFormatRuleTextUsesCanvasLabelsTest()
    gdsGui_schematic_delete("unitTestCanvas23")
    gdsGui_schematic_create("unitTestCanvas23", "UnitTestPage", 0, 0, "LT", 1, 1)
    gdsGui_schematic_addElement("unitTestCanvas23", "busA", "rect", 0, 0, 0.1, 0.1, "BUS A", nil, nil, nil, nil, "path")
    gdsGui_schematic_addControl("unitTestCanvas23", "g1", 0.3, 0, {"OPEN", "CLOSED"}, 0, "RELAY 1", nil,
        1, nil, nil, nil, nil, nil, "gate")

    local canvas = nil
    for _, c in ipairs(globApp.objects.schematics) do
        if c.name == "unitTestCanvas23" then canvas = c end
    end
    if not canvas then return "fail: canvas not found" end

    local rule = { status="learned", conditionIds={"busA"}, conditionStates={busA="powered"}, resultState="closed" }
    return _formatRuleText("g1", rule, _labelsByIdForCanvas(canvas))
end

-- _lockGateRule must flip a learned rule to locked (so _recomputeGateRules
-- will never relearn over it), and must leave a non-learned rule alone.
function schematicLockGateRuleTest()
    local canvasA = { rules = { g1 = { status="learned", conditionIds={}, conditionStates={}, resultState="closed" } } }
    _lockGateRule(canvasA, "g1")
    local lockedResult = canvasA.rules.g1.status

    local canvasB = { rules = { g1 = { status="noRule" } } }
    _lockGateRule(canvasB, "g1")
    local noRuleResult = canvasB.rules.g1.status

    return lockedResult, noRuleResult
end

function suggestNextSnapshotNoCapturesYetTest()
    local controls = { {id="a", numDetents=2}, {id="b", numDetents=2} }
    local suggestion = ModelSuggest.suggestNextSnapshot(controls, {})
    return suggestion.signature
end

function suggestNextSnapshotOneFlipFromCapturedTest()
    local controls = { {id="a", numDetents=2}, {id="b", numDetents=2} }
    local captured = { ["a=0,b=0"] = true }
    local suggestion = ModelSuggest.suggestNextSnapshot(controls, captured)
    return suggestion.signature, suggestion.flippedControlId
end

function suggestNextSnapshotNilWhenFullyCapturedTest()
    local controls = { {id="a", numDetents=2} }
    local captured = { ["a=0"] = true, ["a=1"] = true }
    local suggestion = ModelSuggest.suggestNextSnapshot(controls, captured)
    if suggestion == nil then return "nil" end
    return suggestion.signature
end

-- "a" is iterated before "b" in controls, so a=1,b=0 is the FIRST
-- untested neighbor suggestNextSnapshot's own "first one wins" shortcut
-- would return -- scoreFn instead rates the SECOND-considered a=0,b=1
-- higher, proving suggestTargetedSnapshot keeps searching and picks the
-- best-scored candidate rather than stopping at the first.
function suggestTargetedSnapshotPicksHighestScoringCandidateTest()
    local controls = { {id="a", numDetents=2}, {id="b", numDetents=2} }
    local captured = { ["a=0,b=0"] = true }
    local function scoreFn(candidate)
        if candidate.b == 1 then return 2 end
        return 1
    end
    local suggestion = ModelSuggest.suggestTargetedSnapshot(controls, captured, scoreFn)
    return suggestion.signature
end

-- A scoreFn that never returns a truthy score (every candidate is
-- genuinely useless to the caller's own goal) must yield nil, not an
-- arbitrary untested neighbor -- the caller (main.lua's AI panel) relies
-- on nil to know it should fall back to plain suggestNextSnapshot instead.
function suggestTargetedSnapshotNilWhenScoreFnNeverScoresTest()
    local controls = { {id="a", numDetents=2}, {id="b", numDetents=2} }
    local captured = { ["a=0,b=0"] = true }
    local suggestion = ModelSuggest.suggestTargetedSnapshot(controls, captured, function() return nil end)
    if suggestion == nil then return "nil" end
    return suggestion.signature
end

-- incrsMinRHTopTimer/incrsSecRHTopTimer must never push timer.t past 59:59
-- -- the timerTopRight display container is sized for exactly that (see
-- format_time's own 3599s test) and silently clips/overflows past it.
function timerIncrsMin_clampsAt5959Test()
    timer.t = 3599
    incrsMinRHTopTimer()
    local afterMin = timer.t
    timer.t = 3599
    incrsSecRHTopTimer()
    local afterSec = timer.t
    return afterMin, afterSec
end

-- Bumping the timer back above the <=3s warning window with +1 min must
-- re-arm blink.navSent, so a countdown that re-enters that window a
-- second time still gets the early warning navigation (see love.update's
-- COUNT DOWN branch and _rearmPreAlarmNavIfAboveWindow's own comment).
function timerIncrsMin_rearmsPreAlarmNavTest()
    timer.t = 2
    blink.navSent = true
    incrsMinRHTopTimer()
    return blink.navSent
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
    --  _formatRequiredFPM
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="formatRequiredFPM_normal",
        ["funcName"]={"_formatRequiredFPM"},
        ["funcParameters"]={1000, 5},
        ["funcExpctOutput"]={"REQ FPM:\n200"}}

    -- time = 0 with a nonzero altitude change is undefined, not "no rate
    -- needed" -- must read "N/A", not a plain "0".
    gdsGui_dev_testExecute {["id"]="formatRequiredFPM_zeroTime_nonzeroAltitude_isNA",
        ["funcName"]={"_formatRequiredFPM"},
        ["funcParameters"]={1000, 0},
        ["funcExpctOutput"]={"REQ FPM:\nN/A"}}

    gdsGui_dev_testExecute {["id"]="formatRequiredFPM_zeroTime_zeroAltitude_isZero",
        ["funcName"]={"_formatRequiredFPM"},
        ["funcParameters"]={0, 0},
        ["funcExpctOutput"]={"REQ FPM:\n0"}}

    --------------------------------------------------------------------------
    --  timer +1 min / +1 sec (clamp + pre-alarm nav re-arm)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="timerIncrsMin_clampsAt5959",
        ["funcName"]={"timerIncrsMin_clampsAt5959Test"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={3599, 3599}}

    gdsGui_dev_testExecute {["id"]="timerIncrsMin_rearmsPreAlarmNav",
        ["funcName"]={"timerIncrsMin_rearmsPreAlarmNavTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={false}}

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

    --------------------------------------------------------------------------
    --  inference model (model/graph.lua, model/solver.lua) — Phase 1
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="modelSolver_closedGate_powersSink",
        ["funcName"]={"modelSolverClosedGatePowersSinkTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"powered"}}

    gdsGui_dev_testExecute {["id"]="modelSolver_openGate_blocksSink",
        ["funcName"]={"modelSolverOpenGateBlocksSinkTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"unpowered"}}

    gdsGui_dev_testExecute {["id"]="modelGraph_hasAltPath_findsBypassAroundGate",
        ["funcName"]={"modelGraphHasAltPathTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true}}

    gdsGui_dev_testExecute {["id"]="modelSolver_offSource_reachedButBlocksPast",
        ["funcName"]={"modelSolverOffSourceReachedButBlocksPastTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"powered", "unpowered"}}

    gdsGui_dev_testExecute {["id"]="modelGraph_diodeDirection_derivedFromRotationNotDrawOrder",
        ["funcName"]={"modelGraphDiodeDirectionFromRotationTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"powered", "unpowered"}}

    gdsGui_dev_testExecute {["id"]="modelGraph_diodeDirection_resolvesPerpendicularBendBySiblingRanking",
        ["funcName"]={"modelGraphDiodeDirectionIgnoresPerpendicularBendTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"powered", "unpowered"}}

    gdsGui_dev_testExecute {["id"]="modelGraph_diodeToDiode_contradictionFallsBackToDrawOrder",
        ["funcName"]={"modelGraphDiodeToDiodeContradictionFallsBackToDrawOrderTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"d1", "d2"}}

    gdsGui_dev_testExecute {["id"]="schematic_diodeCathodeWire_followsIndependentlyPoweredBus",
        ["funcName"]={"schematicDiodeCathodeWireFollowsBusTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"unpowered", true}}

    gdsGui_dev_testExecute {["id"]="schematic_componentType_propagatesWithoutPaintedSnapshot",
        ["funcName"]={"schematicComponentTypePropagationTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1}}

    --------------------------------------------------------------------------
    --  inference model (model/learner.lua) — Phase 2
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="modelLearner_inferGate_closedFromBothSidesPowered",
        ["funcName"]={"modelLearnerInferGateClosedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"closed"}}

    gdsGui_dev_testExecute {["id"]="modelLearner_inferGate_openFromUnpoweredSink",
        ["funcName"]={"modelLearnerInferGateOpenTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"open"}}

    gdsGui_dev_testExecute {["id"]="modelLearner_inferGate_unknownWhenGateUnreached",
        ["funcName"]={"modelLearnerInferGateUnknownWhenUnreachedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"unknown"}}

    gdsGui_dev_testExecute {["id"]="schematic_deducedGateStates_matchPaintedSnapshots",
        ["funcName"]={"schematicDeducedGateStatesFromSnapshotsTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true}}

    --------------------------------------------------------------------------
    --  rule learner (model/learner.lua's findSimplestRule) — Phase 3
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="modelLearner_findSimplestRule_singleCondition",
        ["funcName"]={"modelLearnerFindRuleSingleConditionTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"cond", "closed"}}

    gdsGui_dev_testExecute {["id"]="modelLearner_findSimplestRule_contradictionYieldsNoRule",
        ["funcName"]={"modelLearnerFindRuleContradictionTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"noRule"}}

    gdsGui_dev_testExecute {["id"]="modelLearner_findSimplestRule_fallsThroughToPairCondition",
        ["funcName"]={"modelLearnerFindRulePairConditionTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={2}}

    gdsGui_dev_testExecute {["id"]="schematic_gateRule_learnedFromSnapshots",
        ["funcName"]={"schematicGateRuleLearnedFromSnapshotsTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"closed"}}

    --------------------------------------------------------------------------
    --  feedback-loop solving (model/solver.lua's solveWithRules) — Phase 4
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="modelSolver_solveWithRules_convergesOnIndependentCondition",
        ["funcName"]={"modelSolverSolveWithRulesConvergesTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, "closed"}}

    gdsGui_dev_testExecute {["id"]="modelSolver_solveWithRules_detectsSelfReferentialOscillation",
        ["funcName"]={"modelSolverSolveWithRulesDetectsOscillationTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={false}}

    --------------------------------------------------------------------------
    --  rule text / lock / suggest-next-snapshot — Phase 5 (logic layer only;
    --  no dock tool, menu entry, or badge UI wired up yet)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="formatRuleText_learnedSingleCondition",
        ["funcName"]={"formatRuleTextLearnedSingleConditionTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"RELAY 1 is closed when BUS A is powered"}}

    gdsGui_dev_testExecute {["id"]="formatRuleText_noRuleYet",
        ["funcName"]={"formatRuleTextNoRuleYetTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"RELAY 1: no rule learned yet"}}

    gdsGui_dev_testExecute {["id"]="schematic_formatRuleText_usesCanvasLabels",
        ["funcName"]={"schematicFormatRuleTextUsesCanvasLabelsTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"RELAY 1 is closed when BUS A is powered"}}

    gdsGui_dev_testExecute {["id"]="schematic_lockGateRule_locksLearnedLeavesNoRuleAlone",
        ["funcName"]={"schematicLockGateRuleTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"locked", "noRule"}}

    gdsGui_dev_testExecute {["id"]="suggestNextSnapshot_noCapturesYet_baseline",
        ["funcName"]={"suggestNextSnapshotNoCapturesYetTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"a=0,b=0"}}

    gdsGui_dev_testExecute {["id"]="suggestNextSnapshot_oneFlipFromCaptured",
        ["funcName"]={"suggestNextSnapshotOneFlipFromCapturedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"a=1,b=0", "a"}}

    gdsGui_dev_testExecute {["id"]="suggestNextSnapshot_nilWhenFullyCaptured",
        ["funcName"]={"suggestNextSnapshotNilWhenFullyCapturedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"nil"}}

    gdsGui_dev_testExecute {["id"]="suggestTargetedSnapshot_picksHighestScoringCandidate",
        ["funcName"]={"suggestTargetedSnapshotPicksHighestScoringCandidateTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"a=0,b=1"}}

    gdsGui_dev_testExecute {["id"]="suggestTargetedSnapshot_nilWhenScoreFnNeverScores",
        ["funcName"]={"suggestTargetedSnapshotNilWhenScoreFnNeverScoresTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"nil"}}

    --------------------------------------------------------------------------
    --  user-configurable ELECTRICAL powered/unpowered colors
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="schematic_getColorPaletteEntry_green",
        ["funcName"]={"schematicGetColorPaletteEntryTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0, 1, 0, "GREEN"}}

    gdsGui_dev_testExecute {["id"]="schematic_electricalColorOverride_stateForColorTracksCurrentStyle",
        ["funcName"]={"schematicElectricalColorOverride_stateForColorTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, false}}

    --------------------------------------------------------------------------
    --  systemType -> medium registry (model/media/registry.lua)
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="mediaRegistry_currentMediumFallbackAndRoundTrip",
        ["funcName"]={"mediaRegistryCurrentMediumTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, true, true}}

    --------------------------------------------------------------------------
    --  voltage-keyed powered colors + voltage tie-break
    --------------------------------------------------------------------------
    gdsGui_dev_testExecute {["id"]="colorForPoweredNode_singleSourceOwnColor",
        ["funcName"]={"colorForPoweredNode_singleSourceOwnColorTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1, 0, 0}}

    gdsGui_dev_testExecute {["id"]="colorForPoweredNode_singleSourceNoColorFallsBack",
        ["funcName"]={"colorForPoweredNode_singleSourceNoColorFallsBackTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0.9, 0.9, 0.9}}

    gdsGui_dev_testExecute {["id"]="colorForPoweredNode_tieHigherVoltageWins",
        ["funcName"]={"colorForPoweredNode_tieHigherVoltageWinsTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1, 1, 0}}

    gdsGui_dev_testExecute {["id"]="colorForPoweredNode_tieNoVoltageDashes",
        ["funcName"]={"colorForPoweredNode_tieNoVoltageDashesTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={2}}

    gdsGui_dev_testExecute {["id"]="colorForPoweredNode_tieEqualVoltageSameColor",
        ["funcName"]={"colorForPoweredNode_tieEqualVoltageSameColorTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1, 0, 0}}

    gdsGui_dev_testExecute {["id"]="schematic_voltageTieBreak_integration",
        ["funcName"]={"schematicVoltageTieBreakIntegrationTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1, 1, 0}}

    gdsGui_dev_testExecute {["id"]="schematic_openGate_showsUnpoweredColor",
        ["funcName"]={"schematicOpenGateShowsUnpoweredColorTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, true, "powered"}}

    gdsGui_dev_testExecute {["id"]="schematic_attributionRule_learnedAndApplied",
        ["funcName"]={"schematicAttributionRuleLearnedAndAppliedTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, true, true, true}}

    gdsGui_dev_testExecute {["id"]="schematic_tiedVoltage_attributionConfidence",
        ["funcName"]={"schematicTiedVoltageAttributionConfidenceTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, true, true}}

    gdsGui_dev_testExecute {["id"]="schematic_voltageDominance_generalizesAcrossNodes",
        ["funcName"]={"schematicVoltageDominanceGeneralizesAcrossNodesTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true, true}}

    gdsGui_dev_testExecute {["id"]="unlockSchematicFeature_setsEntitlementFlag",
        ["funcName"]={"unlockSchematicFeatureTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={true}}

    gdsGui_dev_testExecute {["id"]="schematic_annunciatorEditMenu_deletesViaConfirm",
        ["funcName"]={"schematicAnnunciatorDeleteTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0}}

    gdsGui_dev_testExecute {["id"]="schematic_annunciatorEditMenu_renames",
        ["funcName"]={"schematicAnnunciatorRenameTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"FIRE WARN"}}

    gdsGui_dev_testExecute {["id"]="schematic_annunciatorEditMenu_recolors",
        ["funcName"]={"schematicAnnunciatorColorEditTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={0.95}}

    gdsGui_dev_testExecute {["id"]="schematic_annunciatorRename_rejectsDuplicateLabel",
        ["funcName"]={"schematicAnnunciatorRenameRejectsDuplicateTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={"MASTER WARNING"}}

    gdsGui_dev_testExecute {["id"]="schematicStore_loadSafely_corruptPrimaryRestoresBackup",
        ["funcName"]={"schematicLoadSafely_corruptPrimary_restoresFromBackupTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1}}

    gdsGui_dev_testExecute {["id"]="schematicStore_repair_dedupesElementIds",
        ["funcName"]={"schematicRepair_dedupesElementIdsTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1}}

    gdsGui_dev_testExecute {["id"]="schematicStore_compatNotice_gatesOncePerVersion",
        ["funcName"]={"schematicCompatNotice_gatesOncePerVersionTest"},
        ["funcParameters"]={0},
        ["funcExpctOutput"]={1}}

end)

-- Build the unit-test table widget now that both "gui" and "app" suites are registered.
gdsGui_dev_createUnitTestObjects()
