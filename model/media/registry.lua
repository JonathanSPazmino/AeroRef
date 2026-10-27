-- model/media/registry.lua
--
-- {systemType -> medium} lookup — the seam model/media/electrical.lua's own
-- header comment anticipates for a future hydraulic.lua/fuel.lua: the
-- propagation engine (model/solver.lua) and rule search (model/learner.lua)
-- stay domain-blind, and the app layer (main.lua) picks which medium's
-- state vocabulary/display style applies by looking up the CURRENT
-- system's systemType here instead of hardcoding one medium module by name.
--
-- A medium self-registers by requiring this module and calling register()
-- with its own .name as the systemType key (see model/media/electrical.lua)
-- rather than this module requiring every medium up front — so adding a
-- new medium is purely additive: drop a new model/media/*.lua file in,
-- require it once from wherever mediums get loaded, and every existing
-- get() caller picks it up with no change.

local _media = {}

local function register(systemType, medium)
    _media[systemType] = medium
end

-- Returns the registered medium for systemType, or nil when systemType is
-- nil/unregistered (e.g. a system whose medium plug-in doesn't exist yet) —
-- callers decide their own fallback, same "absence means no evidence"
-- convention the rest of the model layer uses rather than this module
-- guessing a default.
local function get(systemType)
    return systemType and _media[systemType] or nil
end

return { register = register, get = get }
