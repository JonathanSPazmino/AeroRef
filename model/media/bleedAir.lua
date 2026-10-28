-- model/media/bleedAir.lua
--
-- The BLEED AIR domain's "medium" plug-in -- see model/media/hydraulic.lua's
-- own header comment for why style's keys stay the literal "unpowered"/
-- "powered" words regardless of medium, and model/media/electrical.lua's
-- for the overall shape every medium follows. Registered under the exact
-- "BLEED AIR" systemType string SCHEMATIC_CATALOG/SYSTEM_THUMBNAILS already
-- use in main.lua (the space is part of the key, same as everywhere else
-- that string appears).
local Registry = require("model.media.registry")

local BLEED_AIR = {
    name = "BLEED AIR",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 0.35, 0.70, 0.90, 1 }, -- flowing bleed air, pneumatic-schematic light blue
    },
    -- See model/media/hydraulic.lua's own comment on magnitudeLabel --
    -- same per-source scalar, "PRESSURE" here (bleed duct pressure, psi) in
    -- place of ELECTRICAL's "VOLTAGE".
    magnitudeLabel = "PRESSURE",
    -- See model/media/electrical.lua's own comment on magnitudeUnit.
    magnitudeUnit = "PSI",
}

Registry.register(BLEED_AIR.name, BLEED_AIR)

return BLEED_AIR
