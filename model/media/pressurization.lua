-- model/media/pressurization.lua
--
-- The PRESSURIZATION domain's "medium" plug-in -- see model/media/hydraulic.lua's
-- own header comment for why style's keys stay the literal "unpowered"/
-- "powered" words regardless of medium, and model/media/electrical.lua's
-- for the overall shape every medium follows. Registered under the exact
-- "PRESSURIZATION" systemType string SCHEMATIC_CATALOG already uses in
-- main.lua. Before this file existed, a PRESSURIZATION system fell back to
-- ELECTRICAL_MEDIUM (see main.lua's _currentMedium() comment on that
-- fallback) -- this gives it its own style/flow data instead, same as every
-- other DUCT/PIPE system already has.
local Registry = require("model.media.registry")

local PRESSURIZATION = {
    name = "PRESSURIZATION",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 0.55, 0.80, 0.70, 1 }, -- cabin air, pale green-cyan
    },
    -- See model/media/hydraulic.lua's own comment on magnitudeLabel.
    magnitudeLabel = "PRESSURE",
    -- See model/media/electrical.lua's own comment on magnitudeUnit.
    magnitudeUnit = "PSI",
    -- Same "shimmer" kind as model/media/bleedAir.lua (a compressible gas,
    -- not discrete dashes), just slower/fainter -- cabin outflow through the
    -- OUTFLOW VALVE is a trickle next to engine bleed air duct flow. Stays
    -- smooth (no wiggleAmp -- see that medium's own comment on its heat-haze
    -- jitter) -- cooled cabin air settled behind CONTROLLER/OUTFLOW VALVE
    -- has none of the hot-off-the-engine distortion bleed air duct flow
    -- does, so the two don't just read as the same shimmer at two dial
    -- settings any more.
    --
    -- speedPxPerSec here is only the FALLBACK -- the pacing a system with no
    -- CONTROLLER placed yet (or one whose RATE property is blank/non-
    -- numeric) shimmers at. Once a CONTROLLER exists with a numeric RATE
    -- (cabin altitude's own climb/descent rate, fpm) typed into it,
    -- main.lua's _refreshPressurizationFlowPace overwrites canvas.flowStyle's
    -- speedPxPerSec every time the canvas changes -- faster cabin-altitude
    -- rate reads as a quicker-pulsing shimmer, the literal "cabin-altitude-
    -- tied pacing" this medium's own TODO bullet asked for, with no new
    -- flow-table field needed here (same speedPxPerSec drawFlowShimmer
    -- already reads, just recomputed instead of fixed).
    flow = { kind = "shimmer", speedPxPerSec = 16, bandPx = 14, alpha = 0.22 },
    -- RATE's own placement/properties row accepts numeric-only keystrokes
    -- (main.lua's _openSystemIntoCanvas feeds this straight to
    -- schematic_gdsGuiLib.lua's gdsGui_schematic_setNumericPropertyKeys) --
    -- CABIN ALT stays plain free text like every other defaultProperties
    -- row (ACTUATOR's PSI REQUIREMENT, ENGINE's FUEL FLOW, ...); only RATE
    -- is ever actually read back as a number (_pressurizationControllerRateFPM).
    numericPropertyKeys = { RATE = true },
}

Registry.register(PRESSURIZATION.name, PRESSURIZATION)

return PRESSURIZATION
