--[[ Main.lua
    Author: Jonathan Pazmino
    Description: Core entry file for LÖVE app with timer and GUI integration
]]

-------------------------------------------------------------------------------
-- LIBRARIES LOAD
-------------------------------------------------------------------------------
require("Libraries.jp_GUI_library.loader_gdsGuiLib")

APP_VERSION = "1.0.0"

-- Original orientation the app was designed for; used by the GUI library to
-- establish the reference container width at first finalize (portrait = 1 col).
globApp.appOriginalOrientation = "portrait"

-- Create base pages
globApp.appColor = {.2, .2, .2, 1} --initializes bg color
gdsGui_page_create(3, "MainMenu",           false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(4, "TermsAndConditions", false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(5, "Learn",              false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")
gdsGui_page_create(6, "Settings",           false, false, globApp.appColor, 12, 0, {.5, 1, .6, .6, "LT"}, "max")

-------------------------------------------------------------------------------
-- GLOBAL STATE
-------------------------------------------------------------------------------
local utc = {}
local utcPrintString = ""
local lastUtcSec = -1 -- Add a variable to track the last updated second
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

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------


-- Syncs all footer nav buttons so the button matching activeDest is PRESSED
-- and all others are RELEASED, across every page that has a footer.
local function _navSyncAll(activeDest)
    for _, pfx in ipairs({"mainMenu", "learn", "settings"}) do
        gdsGui_button_setState(pfx .. "_navMainMenu", activeDest == "MainMenu" and "pushed" or "released")
        gdsGui_button_setState(pfx .. "_navLearn",    activeDest == "Learn"    and "pushed" or "released")
        gdsGui_button_setState(pfx .. "_navSettings", activeDest == "Settings" and "pushed" or "released")
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
    app    = {0.20, 0.20, 0.20, 1},
    bg     = {0.18, 0.18, 0.18, 1},
    header = {0.25, 0.25, 0.25, 1},
    border = {0.35, 0.35, 0.35, 1},
    text   = {1.00, 1.00, 1.00, 1},
}
local _THEME_LIGHT = {
    app    = {0.88, 0.88, 0.88, 1},
    bg     = {0.82, 0.82, 0.82, 1},
    header = {0.72, 0.72, 0.72, 1},
    border = {0.55, 0.55, 0.55, 1},
    text   = {0.05, 0.10, 0.25, 1},
}

-- Learn textbox segment data (text + subtitle flag; colors resolved per theme).
local _LEARN_TIMER_RAW = {
    {text="UTC CLOCK", sub=true},
    {text="Shows current UTC date and time, updated each second. Sourced from the device system clock; verify against a certified time source for time-critical operations.\n"},
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
    {text="This calculator uses a simplified single-flight model. It does not account for FAR Part 117, Part 135, rest requirements, cumulative hour limits, or your operator's ops specs. Always verify against applicable regulations and your operator's operations specifications.\n"},
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
    {text="Enable or disable vibration on button taps and at timer alarm."},
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

local function _applyTheme(isDark)
    local t = isDark and _THEME_DARK or _THEME_LIGHT
    for i = 1, 4 do globApp.appColor[i] = t.app[i] end
    globApp.themeTextColor = { t.text[1], t.text[2], t.text[3], t.text[4] }
    for _, cont in ipairs(globApp.objects.containers) do
        cont.bgColor     = { t.bg[1],     t.bg[2],     t.bg[3],     t.bg[4] }
        cont.headerColor = { t.header[1], t.header[2], t.header[3], t.header[4] }
        cont.borderColor = { t.border[1], t.border[2], t.border[3], t.border[4] }
    end
    for _, obj in ipairs(globApp.objects.outputTextBox) do
        obj.text.color = { t.text[1], t.text[2], t.text[3], t.text[4] }
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
    -- SHARED HEADER / FOOTER LAYOUT VALUES
    ---------------------------------------------------------------------------
    local pageHdrH  = math.floor(globApp.safeScreenArea.h * 0.10)
    local pageFootH = pageHdrH
    local hdrCX     = math.floor(globApp.safeScreenArea.w * 0.5)
    local hdrCY     = math.floor(pageHdrH * 0.5)
    local footBtnW  = 50
    local footBtnH  = 50
    local footBtnY  = math.floor(pageFootH * 0.50)
    local footBtnX1 = math.floor(globApp.safeScreenArea.w * (1/6))
    local footBtnX2 = math.floor(globApp.safeScreenArea.w * (3/6))
    local footBtnX3 = math.floor(globApp.safeScreenArea.w * (5/6))

    -- Creates the shared header + footer for one app page.
    local function createPageHeaderFooter(pageName, titleText, prefix)
        -- Header
        gdsGui_pageHeader_create(prefix .. "_header", pageName, pageHdrH, {0.15, 0.15, 0.20, 1})
        gdsGui_outputTxtBox_create(prefix .. "_pageTitle", pageName, nil,
            hdrCX, hdrCY, "CC",
            math.floor(globApp.safeScreenArea.w * 0.70), math.floor(pageHdrH * 0.5),
            {1, 1, 1, 1}, titleText, 16, prefix .. "_header"
        )
        -- Footer with 3 navigation buttons: mainMenu | learn | settings
        gdsGui_pageFooter_create(prefix .. "_footer", pageName, pageFootH, {0.15, 0.15, 0.20, 1})
        gdsGui_button_create(prefix .. "_navMainMenu", pageName, "stickyToggle",
            "Sprites/button_calculator_pressed.png", "Sprites/button_calculator_released.png",
            "Sprites/button_calculator_deactivated.png",
            footBtnX1, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToMainMenu", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
        gdsGui_button_create(prefix .. "_navLearn", pageName, "stickyToggle",
            "Sprites/button_learn_pressed.png", "Sprites/button_learn_released.png",
            "Sprites/button_learn_deactivated.png",
            footBtnX2, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToLearn", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
        gdsGui_button_create(prefix .. "_navSettings", pageName, "stickyToggle",
            "Sprites/button_settings_pressed.png", "Sprites/button_settings_released.png",
            "Sprites/button_settings_deactivated.png",
            footBtnX3, footBtnY, "CC", footBtnW, footBtnH,
            "navGoToSettings", globApp.BUTTON_STATES.RELEASED, false, prefix .. "_footer"
        )
    end

    createPageHeaderFooter("MainMenu", "MAIN MENU", "mainMenu")
    createPageHeaderFooter("Learn",    "LEARN",     "learn")
    createPageHeaderFooter("Settings", "SETTINGS",  "settings")


    ---------------------------------------------------------------------------
    -- TIMER PANEL
    -- Pixel positions are relative to the container's scroll-rect origin.
    -- Design canvas: 320 px wide, 585 px tall (portrait, 32 px header stripped).
    ---------------------------------------------------------------------------
    gdsGui_container_create("timerPanel", "MainMenu", "UTC / TIMER", 32, 0)

    -- Buttons (26×26 px square)
    gdsGui_button_create("resetRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_reset_pressed.png", "Sprites/button_reset_released.png",
        "Sprites/button_reset_deactivated.png", 269, 90, "RT",
        33, 33,
        "resetRHTopTimer", globApp.BUTTON_STATES.RELEASED, true, "timerPanel"
    )
    gdsGui_button_create("pauseRHTopTimer", "MainMenu", "toggle",
        "Sprites/button_pause_play_pressed.png", "Sprites/button_pause_play_released.png",
        "Sprites/button_pause_play_deactivated.png", 215, 90, "CT",
        33, 33,
        "pauseRHTopTimer", globApp.BUTTON_STATES.RELEASED, true, "timerPanel"
    )
    gdsGui_button_create("modeSelectRHTopTimer", "MainMenu", "toggle",
        "Sprites/button_timer_mode_pressed.png", "Sprites/button_timer_mode_released.png",
        "Sprites/button_timer_mode_deactivated.png", 160, 90, "LT",
        33, 33,
        "modeSelectRHTopTimer", globApp.BUTTON_STATES.RELEASED, true, "timerPanel"
    )
    gdsGui_button_create("incrsMinRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_min_increase_pressed.png", "Sprites/button_min_increase_released.png",
        nil, 120, 50, "LT",
        33, 33,
        "incrsMinRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )
    gdsGui_button_create("dcrsMinRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_min_decrease_pressed.png", "Sprites/button_min_decrease_released.png",
        nil, 120, 90, "LT",
        33, 33,
        "dcrsMinRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )
    gdsGui_button_create("incrsSecRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_sec_increase_pressed.png", "Sprites/button_sec_increase_released.png",
        nil, 274, 50, "LT",
        33, 33,
        "incrsSecRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )
    gdsGui_button_create("dcrsSecRHTopTimer", "MainMenu", "pushonoff",
        "Sprites/button_sec_decrease_pressed.png", "Sprites/button_sec_decrease_released.png",
        nil, 274, 90, "LT",
        33, 33,
        "dcrsSecRHTopTimer", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )
    gdsGui_button_create("acknowlegeAlarm", "MainMenu", "pushonoff",
        nil, nil,
        nil, 300, 30, "RT",
        190, 95,
        "acknowlegeAlarm", globApp.BUTTON_STATES.DEACTIVATED, true, "timerPanel"
    )

    -- Text boxes
    gdsGui_outputTxtBox_create("utcData", "MainMenu", nil,
        6, 30, "LT",
        128, 59,
        colorYellow, utcPrintString, 12, "timerPanel"
    )
    local text = timer.mode .. "\nTIMER:\nM " .. format_time(timer.t) .. " S"
    gdsGui_outputTxtBox_create("timerTopRight", "MainMenu", nil,
        283, 30, "RT",
        120, 59,
        colorYellow, text, 12, "timerPanel"
    )

    ---------------------------------------------------------------------------
    -- WIND PANEL
    ---------------------------------------------------------------------------
    gdsGui_container_create("windPanel", "MainMenu", "RUNWAY / WIND", 32, 0)

    -- Compass background: inserted first so it renders under the knob
    gdsGui_outputTxtBox_create("compassBg", "MainMenu", "Sprites/bg_compass_visible.png",
        160, 180, "CC",
        208, 208,
        {1, 1, 1, 1}, "", 1, "windPanel"
    )

    -- Rotary knob (150×150 px square)
    gdsGui_rotaryKnob_createDual(
        "runwayKnob", "MainMenu",
        80, 100, "LT",
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
        160, 10, "CT",
        200, 90,
        colorYellow, "WIND: 36000KT", 12, "windPanel"
    )
    gdsGui_outputTxtBox_create("windSpeedLabel", "MainMenu", nil,
        30, 10, "CT",
        60, 40,
        colorYellow, "WIND\nSPD", 12, "windPanel"
    )
    gdsGui_outputTxtBox_create("windGustLabel", "MainMenu", nil,
        290, 10, "CT",
        60, 40,
        colorYellow, "WIND\nGST", 12, "windPanel"
    )

    -- Scrollbars (30×176 px): speed left of knob, gust right of knob
    gdsGui_scrollBar_create("windSpeed", "MainMenu",
        30, 55, 30, 176, "CT", 5, 46, 1,
        "independent", "vertical", 46, "windSpeedChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "windPanel")
    gdsGui_scrollBar_create("windGust", "MainMenu",
        290, 55, 30, 176, "CT", 5, 61, 1,
        "independent", "vertical", 61, "windGustChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "windPanel")

    ---------------------------------------------------------------------------
    -- CALCULATIONS PANEL
    ---------------------------------------------------------------------------
    gdsGui_container_create("calcPanel", "MainMenu", "ASCEND / DESCEND", 32, 0)

    -- Text boxes
    local textAltSlctd = "SLCTD ALT:\n" .. selectedAltitude .. " FT"
    gdsGui_outputTxtBox_create("selectedAltitudeBox", "MainMenu", nil,
        164, 47, "CC",
        110, 47,
        colorYellow, textAltSlctd, 12, "calcPanel"
    )
    local textTimeSlctd = "SLCTD TIME:\n" .. selectedTime .. " min"
    gdsGui_outputTxtBox_create("selectedTimeBox", "MainMenu", nil,
        52, 47, "CC",
        110, 47,
        colorYellow, textTimeSlctd, 12, "calcPanel"
    )
    local textDegreeSlctd = "SLCTD DEG:\n" .. string.format("%.2f", selectedDegree) .. "°"
    gdsGui_outputTxtBox_create("selectedDegreeBox", "MainMenu", nil,
        267, 47, "CC",
        110, 47,
        colorYellow, textDegreeSlctd, 12, "calcPanel"
    )
    local requiredFPM = 0
    if selectedTime > 0 then
        requiredFPM = math.ceil(selectedAltitude / selectedTime)
    end
    local requiredFPMtext = "REQ FPM:\n" .. requiredFPM
    gdsGui_outputTxtBox_create("requiredFPM", "MainMenu", nil,
        110, 146, "CC",
        80, 59,
        colorYellow, requiredFPMtext, 12, "calcPanel"
    )
    local requiredDistance = 0
    if selectedDegree > 0 and selectedAltitude > 0 then
        requiredDistance = math.floor(selectedAltitude / (math.tan(math.rad(selectedDegree)) * 6076.115) + 0.5)
    end
    local requiredDistText = "REQ DIST:\n" .. requiredDistance .. " nm"
    gdsGui_outputTxtBox_create("requiredDistance", "MainMenu", nil,
        211, 146, "CC",
        80, 59,
        colorYellow, requiredDistText, 12, "calcPanel"
    )

    -- Scrollbars (30×185 px)
    gdsGui_scrollBar_create("timeScale", "MainMenu",
        51, 70, 30, 185, "CT", 5, 26, 1,
        "independent", "vertical", 26, "roundSelectedTime",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "calcPanel")
    gdsGui_scrollBar_create("altScale", "MainMenu",
        160, 70, 30, 185, "CT", 5, 52, 1,
        "independent", "vertical", 52, "roundSelectedAltitude",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "calcPanel")
    gdsGui_scrollBar_create("deg", "MainMenu",
        262, 70, 30, 185, "CT", 5, 33, 1,
        "independent", "vertical", 33, "roundSelectedDegree",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "calcPanel")

    ---------------------------------------------------------------------------
    -- DUTY / FLIGHT TIME PANEL
    ---------------------------------------------------------------------------
    gdsGui_container_create("dutyPanel", "MainMenu", "DUTY / FLIGHT TIME", 32, 0)

    gdsGui_outputTxtBox_create("dutyStartBox",    "MainMenu", nil,
        160,  8, "CT", 270, 25, colorYellow, "DUTY START: 00:00Z", 12, "dutyPanel")
    gdsGui_outputTxtBox_create("dutyMaxHoursBox", "MainMenu", nil,
        160, 80, "CT", 270, 25, colorYellow, "MAX DUTY: 1 HR",     12, "dutyPanel")
    gdsGui_outputTxtBox_create("lastFlightBox",   "MainMenu", nil,
        160,152, "CT", 270, 25, colorYellow, "LAST FLT BLOCK TIME: 0.0 HRS", 12, "dutyPanel")

    gdsGui_scrollBar_create("dutyStartScale", "MainMenu",
        160,  35, 270, 30, "CT", 32, 289, 0,
        "independent", "horizontal", 289, "dutyStartChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "dutyPanel")
    gdsGui_scrollBar_create("dutyHoursScale", "MainMenu",
        160, 107, 270, 30, "CT", 5, 20, 0,
        "independent", "horizontal", 20, "dutyHoursChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "dutyPanel")
    gdsGui_scrollBar_create("lastFlightScale", "MainMenu",
        160, 179, 270, 30, "CT", 20, 181, 0,
        "independent", "horizontal", 181, "lastFlightChanged",
        {frame = "Sprites/scrollbar_bg.png", thumb = "Sprites/scrollbar_thumb.png"}, true, "dutyPanel")

    gdsGui_outputTxtBox_create("dutyOutBox",  "MainMenu", nil,
         80, 225, "CT", 120, 50, colorYellow, "DUTY OUT\n--:--Z",  12, "dutyPanel")
    gdsGui_outputTxtBox_create("departByBox", "MainMenu", nil,
        240, 225, "CT", 120, 50, colorYellow, "DEPART BY\n--:--Z", 12, "dutyPanel")
    gdsGui_outputTxtBox_create("dutyWarningBox", "MainMenu", nil,
        160, 285, "CT", 270, 22, colorWarning,
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
    local _learnFont  = love.graphics.newFont(learnFontSize)
    local _learnTxtW  = (learnTxtW - 10) * 0.8
    local _learnLineH = _learnFont:getHeight()
    local function learnH(rawSegs)
        local n = 0
        for _, s in ipairs(rawSegs) do
            local _, wrapped = _learnFont:getWrap(s.text, _learnTxtW)
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
    -- RT anchor: right edge sits 12 px from the container's right edge at 320 px reference
    local settingsBtnX     = 300
    local settingsRowY     = 12
    local settingsLabelW   = 200
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
    gdsGui_container_finalise("TermsAndConditions")

    gdsGui_saveLoad_loadFileContents("appSettings.lua")

    if appSettings.darkMode       == nil then appSettings.darkMode       = true end
    if appSettings.soundEnabled   == nil then appSettings.soundEnabled   = true end
    if appSettings.hapticsEnabled == nil then appSettings.hapticsEnabled = true end

    _applyTheme(appSettings.darkMode)
    gdsGui_button_setState("darkModeToggle", appSettings.darkMode       and "pushed" or "released")
    gdsGui_button_setState("soundToggle",    appSettings.soundEnabled   and "pushed" or "released")
    gdsGui_button_setState("hapticsToggle",  appSettings.hapticsEnabled and "pushed" or "released")

    _navSyncAll("MainMenu")

    local showTC = (appSettings.tcAcceptedVersion ~= APP_VERSION)
    gdsGui_page_switch("IntialBooting", showTC and 4 or 3, 2, false)

    font = love.graphics.newFont(20)
    love.graphics.setFont(font)

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
    -- Update UTC clock string only when the second changes
    utc = os.date("!*t")
    if utc.sec ~= lastUtcSec then
        utcPrintString = string.format(
            "UTC:\n%04d-%02d-%02d\n%02d:%02d:%02d",
            utc.year, utc.month, utc.day, utc.hour, utc.min, utc.sec
        )
        lastUtcSec = utc.sec
        gdsGui_outputTxtBox_setText("utcData", utcPrintString)
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
                gdsGui_page_switch("LoadingMainMenu", 3, 0.5, false)
            end

            if timer.t == 0 then
                timer.running = false
                blink.active  = true
                gdsGui_button_setState("acknowlegeAlarm", "released")
                alarmButtonsDeactivation()
                if gdsGui_page_currentName() ~= "MainMenu" and globApp.currentPageIndex ~= 2 then
                    blink.navigatingToMain = true
                    _navSyncAll("MainMenu")
                    gdsGui_page_switch("LoadingMainMenu", 3, 0.5, false)
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
    drawAlarmOverlay()
    gdsGui_page_drawUnsafeAreaOverlay()
    gdsGui_container_drawFixed(gdsGui_page_currentName())
end

-------------------------------------------------------------------------------
-- PAGE DRAWING
-------------------------------------------------------------------------------
function drawPages()
    gdsGui_page_drawBackground()
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

-------------------------------------------------------------------------------
-- TERMS AND CONDITIONS PAGE
-------------------------------------------------------------------------------

function createTermsAndConditionsObjects()
    local thisPageName = "TermsAndConditions"
    local tcText     = love.filesystem.read("terms.txt") or "Terms and Conditions text not found."
    tcText = tcText:gsub("{{APP_VERSION}}", APP_VERSION)
    local libSprites = "Libraries/jp_GUI_library/librarySprites/"

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
    gdsGui_page_switch("LoadingMainMenu", 3, 1, false)
end

-------------------------------------------------------------------------------
-- FOOTER NAVIGATION CALLBACKS
-------------------------------------------------------------------------------

function navGoToMainMenu()
    _navSyncAll("MainMenu")
    gdsGui_page_switch("LoadingMainMenu", 3, 0.5, false)
end

function navGoToLearn()
    _navSyncAll("Learn")
    gdsGui_page_switch("LoadingLearn", 5, 0.5, false)
end

function navGoToSettings()
    _navSyncAll("Settings")
    gdsGui_page_switch("LoadingSettings", 6, 0.5, false)
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

end)

-- Build the unit-test table widget now that both "gui" and "app" suites are registered.
gdsGui_dev_createUnitTestObjects()

