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
    -- Marching-dash flow cue (schematic_gdsGuiLib.lua's _pipes.drawFlowDashes,
    -- fed via gdsGui_schematic_setFlowStyle) -- slower and longer-dashed than
    -- HYDRAULIC's own flow table, reading as a lower-pressure, more viscous
    -- fluid than hydraulic's fast, tight dashes.
    flow = { kind = "dash", speedPxPerSec = 20, dashPx = 7 },
    -- Tank wave-fill cue (schematic_gdsGuiLib.lua's _shapePoly.drawLevel,
    -- fed via gdsGui_schematic_setWaveStyle) -- overrides that function's own
    -- shared WAVE_* defaults (HYDRAULIC's RESERVOIR still uses those,
    -- unmodified) with a slower, flatter, single-hump ripple instead of the
    -- default's quicker multi-ripple: a real viscous liquid settles into a
    -- lazier, simpler slosh than a thin one, same "more viscous" cue the
    -- flow table above gives the dash animation, just applied to the tank
    -- surface instead of the pipe.
    wave = { speed = 0.22, cycles = 1, amplitude = 0.4 },
}

Registry.register(FUEL.name, FUEL)

return FUEL
