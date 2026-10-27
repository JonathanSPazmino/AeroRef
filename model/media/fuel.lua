-- model/media/fuel.lua
--
-- The FUEL domain's "medium" plug-in -- see model/media/hydraulic.lua's own
-- header comment for why style's keys stay the literal "unpowered"/
-- "powered" words regardless of medium (model/solver.lua and
-- model/learner.lua both hardcode that exact vocabulary) and
-- model/media/electrical.lua's for the overall shape every medium follows.
local Registry = require("model.media.registry")

local FUEL = {
    name = "FUEL",
    states = { "unpowered", "powered" },
    default = "unpowered",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 0.80, 0.60, 0.15, 1 }, -- flowing fuel, amber
    },
    -- See model/media/hydraulic.lua's own comment on magnitudeLabel --
    -- same per-source scalar, "PRESSURE" here (a boost pump's discharge
    -- pressure) in place of ELECTRICAL's "VOLTAGE".
    magnitudeLabel = "PRESSURE",
    -- See model/media/electrical.lua's own comment on magnitudeUnit.
    magnitudeUnit = "PSI",
}

Registry.register(FUEL.name, FUEL)

return FUEL
