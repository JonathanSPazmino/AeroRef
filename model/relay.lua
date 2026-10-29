-- model/relay.lua
--
-- Pure-Lua, love.*-free logic for a RELAY gate: a "gate"-role node nobody
-- operates directly (a BUS TIE contactor), whose open/closed position is
-- decided by logic that is learned entirely from painted snapshots. Its
-- inputs are:
--   gear    -- the aircraft's global gear position ("DOWN" = on the ground,
--              "UP" = airborne), or NO_GEAR when the system has none.
--   command -- the position label of the pilot switch wired to the relay's
--              signal terminal (e.g. "OPEN"/"CLOSED"), or NO_COMMAND when
--              nothing is wired there.
--   senseA/senseB -- the voltage each power terminal sees with the relay
--              itself held OPEN (so the relay's own position can never feed
--              back into what it senses -- "is there a live source on my
--              side?", the question a real bus power control unit asks).
--              A voltage string ("28"), "0" for no voltage, or POWERED_UNKNOWN
--              for a source reaching it with no voltage assigned yet.
-- The rule is a plain lookup table from that input combination to a
-- position, set by the user for every combination when the relay is placed
-- (main.lua's SET BUS TIE LOGIC grid); anything it doesn't cover leaves the
-- relay at the safe default, open.

local Solver = require("model.solver")

local OPEN, CLOSED = "open", "closed"
local NO_COMMAND, NO_GEAR, POWERED_UNKNOWN = "NONE", "NONE", "PWR"

-- The voltage nodeId sees: the highest voltage among the sources reaching it
-- in `attribution` (see model/solver.lua's solveSourceAttribution), "0" when
-- none do. sourceVoltages: {sourceId -> number or nil}.
local function senseVoltage(attribution, nodeId, sourceVoltages)
    local contributing = nodeId and attribution[nodeId]
    if not contributing or next(contributing) == nil then return "0" end
    local best
    for sourceId in pairs(contributing) do
        local v = sourceVoltages[sourceId]
        if not v then return POWERED_UNKNOWN end
        if not best or v > best then best = v end
    end
    return tostring(best)
end

local function buildKey(gear, command, senseA, senseB)
    return (gear or NO_GEAR) .. "|" .. (command or NO_COMMAND) .. "|" .. senseA .. "|" .. senseB
end

-- buildKey's parts back out: gear, command, senseA, senseB (nil if malformed).
local function parseKey(key)
    return key:match("^(.-)|(.-)|(.-)|(.-)$")
end

-- The same inputs with the two power terminals swapped. A bus tie is
-- physically symmetric, so a combination only ever taught mirror-image still
-- counts as seen (an exact match always wins over its mirror).
local function mirrorKey(key)
    local gear, command, a, b = parseKey(key)
    if not gear then return nil end
    return buildKey(gear, command, b, a)
end

-- What logic ({key -> OPEN|CLOSED}, as the user set it) says for key: its
-- exact entry, else its mirror's, else nil (not covered -- the caller falls
-- back to OPEN).
local function predict(logic, key)
    if not logic then return nil end
    if logic[key] then return logic[key] end
    local mirrored = mirrorKey(key)
    return mirrored and logic[mirrored] or nil
end

-- One snapshot's evidence for a relay's position, from how its own body was
-- painted -- an open gate's body always reads unpowered gray, a closed one
-- carries power (the same display convention main.lua's solver output
-- follows). bodyState: "powered"|"unpowered"|nil (unrecognized color).
-- Gray with no voltage on either side is no evidence at all: an open and a
-- closed relay look identical when nothing is live around them.
local function deduce(bodyState, senseA, senseB)
    if bodyState == "powered" then return CLOSED end
    if bodyState == "unpowered" and (senseA ~= "0" or senseB ~= "0") then return OPEN end
    return nil
end

local function _copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- The sensed inputs for one relay under gateStates (its own entry is forced
-- open first -- see this file's header).
local function senseInputs(graph, sourceStates, gateStates, relay, sourceVoltages)
    local states = _copy(gateStates)
    states[relay.id] = OPEN
    local attribution = Solver.solveSourceAttribution(graph, sourceStates, states)
    return senseVoltage(attribution, relay.terminalNodeIds[1], sourceVoltages),
           senseVoltage(attribution, relay.terminalNodeIds[2], sourceVoltages)
end

-- Resolves every relay's position for one combination.
-- relays: array of {id, terminalNodeIds = {idA, idB}, gear, command}.
-- baseGateStates: every directly-operated gate's position (left untouched).
-- rules: {relayId -> logic table, see predict}. knownStates (optional): {relayId ->
-- OPEN|CLOSED} for relays whose position this combination's own snapshot
-- already shows -- used as-is, never re-predicted.
-- Each relay's verdict can change what ANOTHER relay senses, so this
-- re-evaluates until nothing changes (or maxIterations).
-- Returns a copy of baseGateStates with every relay's position added, and
-- converged (false if the relays never settled).
local function resolve(graph, sourceStates, baseGateStates, relays, rules, sourceVoltages, knownStates, maxIterations)
    knownStates = knownStates or {}
    maxIterations = maxIterations or 10
    local gateStates = _copy(baseGateStates or {})
    for _, relay in ipairs(relays) do gateStates[relay.id] = knownStates[relay.id] or OPEN end

    for _ = 1, maxIterations do
        local changed = false
        for _, relay in ipairs(relays) do
            if not knownStates[relay.id] then
                local senseA, senseB = senseInputs(graph, sourceStates, gateStates, relay, sourceVoltages)
                local verdict = predict(rules[relay.id], buildKey(relay.gear, relay.command, senseA, senseB)) or OPEN
                if gateStates[relay.id] ~= verdict then
                    gateStates[relay.id] = verdict
                    changed = true
                end
            end
        end
        if not changed then return gateStates, true end
    end
    return gateStates, false
end

return {
    OPEN = OPEN, CLOSED = CLOSED, NO_COMMAND = NO_COMMAND, NO_GEAR = NO_GEAR, POWERED_UNKNOWN = POWERED_UNKNOWN,
    senseVoltage = senseVoltage, buildKey = buildKey, parseKey = parseKey, mirrorKey = mirrorKey,
    predict = predict, deduce = deduce,
    senseInputs = senseInputs, resolve = resolve,
}
