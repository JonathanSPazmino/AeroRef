-- model/media/electrical.lua
--
-- The ELECTRICAL domain's "medium" plug-in for the inference-schematic
-- model layer. The propagation engine (model/solver.lua) is domain-blind;
-- only the state vocabulary and each state's display color are
-- domain-specific, kept here as plain data so restyling never touches
-- solving/learning logic. Selected by the app layer via a system's existing
-- systemType field (e.g. "ELECTRICAL") against model/media/registry.lua's
-- {systemType -> medium} registry -- the same seam model/media/hydraulic.lua,
-- model/media/fuel.lua, and model/media/bleedAir.lua now plug into.
--
-- Colors match this app's existing convention: {0.55,0.55,0.55,1} is the
-- flat gray already used throughout main.lua's demo/seed data for an
-- unpowered element, and {1,1,0,1} is the same yellow already used for an
-- energized annunciator (e.g. MASTER CAUTION).
local Registry = require("model.media.registry")

local ELECTRICAL = {
    name = "ELECTRICAL",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 1, 1, 0, 1 },
    },
    -- See model/media/hydraulic.lua's own comment on magnitudeLabel.
    magnitudeLabel = "VOLTAGE",
    -- Unit suffix shown alongside a source's own magnitude number (PER-
    -- SOURCE SETTINGS' own list, the PROPERTIES menu's read-only row, the
    -- per-voltage color picker's prompt) — see main.lua's own callers.
    magnitudeUnit = "V",
}

Registry.register(ELECTRICAL.name, ELECTRICAL)

return ELECTRICAL
