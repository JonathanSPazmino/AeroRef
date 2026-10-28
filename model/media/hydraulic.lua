-- model/media/hydraulic.lua
--
-- The HYDRAULIC domain's "medium" plug-in for the inference-schematic model
-- layer -- see model/media/electrical.lua's own header comment for the
-- shape every medium follows and why it self-registers here rather than
-- being required up front by model/media/registry.lua.
--
-- states/style keys below are still the literal words "unpowered"/
-- "powered", NOT "depressurized"/"pressurized" -- model/solver.lua's own
-- POWERED/UNPOWERED constants and model/learner.lua's inferGate (which
-- still compares against those two literal strings directly, not through
-- any shared constant -- see that file's own TODO-shaped comment) both
-- hardcode this exact vocabulary. Renaming it per medium would silently
-- break deduction for every non-ELECTRICAL system the moment it happened
-- (inferGate would never see a hydraulic node read "powered", so it could
-- never deduce a single gate) -- this medium only ever changes the COLORS
-- a pressurized/depressurized line paints, never the underlying words the
-- model reasons in. Generalizing that vocabulary itself is deliberately
-- left for later, same deferred-scope spirit as model/solver.lua's own
-- header comment.
local Registry = require("model.media.registry")

local HYDRAULIC = {
    name = "HYDRAULIC",
    style = {
        unpowered = { 0.55, 0.55, 0.55, 1 },
        powered   = { 0.85, 0.35, 0.1, 1 }, -- pressurized line, common hydraulic-schematic red/orange
    },
    -- The per-source scalar main.lua's new-source-placement prompt
    -- (schematicSourceElementPlaced) asks for and _colorForPoweredNode's
    -- dominance tie-break reads off each source entity -- "PRESSURE" here
    -- in place of ELECTRICAL's "VOLTAGE". Still stored as entity.voltage
    -- internally (main.lua's own field, unrenamed -- see its comment);
    -- this only changes what the prompt CALLS that number.
    magnitudeLabel = "PRESSURE",
    -- See model/media/electrical.lua's own comment on magnitudeUnit.
    magnitudeUnit = "PSI",
}

Registry.register(HYDRAULIC.name, HYDRAULIC)

return HYDRAULIC
