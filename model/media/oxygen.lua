-- model/media/oxygen.lua
--
-- The OXYGEN domain's "medium" plug-in -- see model/media/hydraulic.lua's
-- own header comment for why style's keys stay the literal "unpowered"/
-- "powered" words regardless of medium, and model/media/electrical.lua's
-- for the overall shape every medium follows. Registered under the exact
-- "OXYGEN" systemType string SCHEMATIC_CATALOG uses in main.lua.
--
-- OXYGEN is the app's one free-tier system (see TODO.md's pricing
-- decision) -- deliberately the simplest catalog of the six (source, path,
-- gate, sink; no defaultProperties on any item), so its own color/flow
-- table doesn't need to do any heavier lifting either: a gas DUCT system
-- like BLEED AIR/PRESSURIZATION, just its own saturated green (the real-
-- world color-coded for medical/aviation oxygen equipment) rather than
-- either of those two's blue/pale-cyan, so the one system every user sees
-- for free reads as its own thing, not a reskin.
local Registry = require("model.media.registry")

local OXYGEN = {
    name = "OXYGEN",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 0.25, 0.75, 0.35, 1 }, -- flowing oxygen, saturated green
    },
    -- See model/media/hydraulic.lua's own comment on magnitudeLabel --
    -- same per-source scalar, "PRESSURE" here (bottle/generator pressure,
    -- psi) in place of ELECTRICAL's "VOLTAGE".
    magnitudeLabel = "PRESSURE",
    -- See model/media/electrical.lua's own comment on magnitudeUnit.
    magnitudeUnit = "PSI",
    -- Same "shimmer" kind as model/media/bleedAir.lua/pressurization.lua (a
    -- compressible gas, not discrete dashes) -- its own speed/band/alpha
    -- sits between the two: crew oxygen flows in a brief, light puff on
    -- mask deployment, not a continuous engine-bleed duct's own energetic
    -- sweep or cabin outflow's slow trickle.
    flow = { kind = "shimmer", speedPxPerSec = 20, bandPx = 12, alpha = 0.3 },
}

Registry.register(OXYGEN.name, OXYGEN)

return OXYGEN
