-- model/media/electrical.lua
--
-- The ELECTRICAL domain's "medium" plug-in for the inference-schematic
-- model layer. The propagation engine (model/solver.lua) is domain-blind;
-- only the state vocabulary and each state's display color are
-- domain-specific, kept here as plain data so restyling never touches
-- solving/learning logic. Selected by the app layer via a system's existing
-- systemType field (e.g. "ELECTRICAL") -- a {systemType -> medium} registry
-- is the seam a future hydraulic.lua/fuel.lua would plug into the same way
-- (see the plan's deferred Phase 6).
--
-- Colors match this app's existing convention: {0.55,0.55,0.55,1} is the
-- flat gray already used throughout main.lua's demo/seed data for an
-- unpowered element, and {1,1,0,1} is the same yellow already used for an
-- energized annunciator (e.g. MASTER CAUTION).
return {
    name = "ELECTRICAL",
    states = { "unpowered", "powered" },
    default = "unpowered",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 1, 1, 0, 1 },
    },
}
