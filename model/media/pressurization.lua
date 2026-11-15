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
    -- OUTFLOW VALVE is a trickle next to engine bleed air duct flow.
    flow = { kind = "shimmer", speedPxPerSec = 16, bandPx = 14, alpha = 0.22 },
}

Registry.register(PRESSURIZATION.name, PRESSURIZATION)

return PRESSURIZATION
