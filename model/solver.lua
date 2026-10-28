-- model/solver.lua
--
-- Pure-Lua, love.*-free power-propagation solver over a model/graph.lua
-- graph (see the inference-schematic-assistance plan). Phase 1 scope: a
-- plain flood-fill from powered sources through closed gates and
-- forward-biased directional gates, with gate states supplied directly
-- rather than derived from the result -- the feedback loop that lets a
-- gate's own learned rule react to the states it helped produce is Phase
-- 4's solveWithRules, layered on top of solve() below, not a change to it.
--
-- States are hardcoded to the electrical vocabulary ("powered"/
-- "unpowered") for this phase's electrical-only scope; parameterizing the
-- solver per medium is one of the plan's named, deliberately-deferred
-- Phase 6 seams, not built now.

local POWERED, UNPOWERED = "powered", "unpowered"

-- graph: {nodes = {id -> {id, role}}, edges = {{id, fromId, toId, directional}}}
-- sourceStates: {id -> truthy} -- which "source" nodes are currently on.
-- gateStates: {id -> "open" | "closed"} -- consulted only for "gate" nodes;
-- a gate with no entry here is treated as open (the safe default -- never
-- silently conduct a gate the caller didn't say was closed).
-- Returns {nodeId -> "powered" | "unpowered"} for every node in the graph.
local function solve(graph, sourceStates, gateStates)
    sourceStates = sourceStates or {}
    gateStates = gateStates or {}

    -- fromId -> toId only for a directional edge (blocks the reverse walk
    -- outright, by simply never adding it) -- both directions otherwise.
    local adjacency = {}
    local function link(a, b)
        adjacency[a] = adjacency[a] or {}
        table.insert(adjacency[a], b)
    end
    for _, e in ipairs(graph.edges) do
        link(e.fromId, e.toId)
        if not e.directional then link(e.toId, e.fromId) end
    end

    local powered = {}
    local queue, head = {}, 1
    for id, node in pairs(graph.nodes) do
        if node.role == "source" and sourceStates[id] then
            powered[id] = true
            table.insert(queue, id)
        end
    end

    while head <= #queue do
        local currentId = queue[head]; head = head + 1
        local node = graph.nodes[currentId]
        -- A gate that isn't closed is itself reached (still powered -- the
        -- real switch's input terminal does see voltage, which is what
        -- lets a wire feeding it from a live source still read hot) but
        -- blocks propagation past it in either direction, exactly like
        -- the real component does. Whether the switch's OWN body displays
        -- that as "powered" is a separate, display-layer decision (see
        -- main.lua's isOpenGate override) -- this is purely about
        -- reachability.
        local blocksOnward = node.role == "gate" and gateStates[currentId] ~= "closed"
        if not blocksOnward then
            for _, neighborId in ipairs(adjacency[currentId] or {}) do
                local neighborNode = graph.nodes[neighborId]
                -- A source models its own internal diode / reverse-current
                -- relay: when it's switched off it still gets entered by a
                -- path arriving from elsewhere -- its terminal/the wire
                -- feeding it from a live bus genuinely is hot, exactly like
                -- a gate's own input terminal above -- but, same as a gate
                -- blocking onward propagation, an off source never PASSES
                -- that power on to anything only reachable THROUGH it
                -- (another source feeding the same bus can light up
                -- everything up to and including an off generator's own
                -- node, but never anything past it) -- regardless of which
                -- direction the wire to it happens to be drawn, unlike
                -- directionalGate's draw-order convention above. Whether
                -- the generator's OWN body displays that as "powered" is a
                -- separate, display-layer decision (see main.lua's
                -- isOffSource override), same split as the gate case.
                local isOffSource = neighborNode.role == "source" and not sourceStates[neighborId]
                if not powered[neighborId] then
                    powered[neighborId] = true
                    if not isOffSource then
                        table.insert(queue, neighborId)
                    end
                end
            end
        end
    end

    local states = {}
    for id in pairs(graph.nodes) do
        states[id] = powered[id] and POWERED or UNPOWERED
    end
    return states
end

-- Phase 4: true only for a rule (model/learner.lua's findSimplestRule
-- output) that is actually "learned"/"locked" and CLOSED, and whose every
-- condition matches nodeStates exactly -- anything else (no rule, a
-- "noRule" status, a mismatched condition) leaves the gate at solve()'s
-- own safe default, open.
local function _ruleSaysClosed(rule, nodeStates)
    if not rule then return false end
    if rule.status ~= "learned" and rule.status ~= "locked" then return false end
    if rule.resultState ~= "closed" then return false end
    for _, conditionId in ipairs(rule.conditionIds) do
        if nodeStates[conditionId] ~= rule.conditionStates[conditionId] then return false end
    end
    return true
end

local function _gateStatesSignature(gateStates)
    local ids = {}
    for id in pairs(gateStates) do table.insert(ids, id) end
    table.sort(ids)
    local parts = {}
    for i, id in ipairs(ids) do parts[i] = id .. "=" .. tostring(gateStates[id]) end
    return table.concat(parts, ",")
end

-- Feedback-loop solving for a gate whose true position isn't set directly
-- (a relay) but is instead governed by a learned/locked rule that reads
-- OTHER nodes' states -- states which may themselves depend on this same
-- gate (a bus-tie relay gated by the very bus it helps feed). Repeatedly
-- re-solves with each ruled gate's position updated from its rule's
-- verdict against the PREVIOUS solve, until a full pass changes nothing
-- (a stable fixed point) or the same set of gate positions recurs (a
-- genuine oscillation with no fixed point -- see the plan's "Phase 4"
-- framing) or maxIterations is hit, whichever comes first.
--
-- graph/sourceStates: same as solve() above.
-- lockedGateStates: {id -> "open"|"closed"} for a gate the user sets
-- directly (e.g. an ordinary switch) -- always wins over any rule for that
-- same gate, every iteration (a user's own control is ground truth, never
-- second-guessed by a learned rule).
-- rulesByGate: {id -> ruleTable}, consulted only for a gate with NO entry
-- in lockedGateStates.
-- Returns {converged, nodeStates, gateStates, iterations, oscillating}.
-- oscillating (only present when converged is false and a repeat was
-- actually detected, otherwise empty) names the gates whose position
-- flipped on the very iteration the repeat was caught -- enough for a
-- caller (see main.lua's _solveCurrentSchematic) to withhold a predicted
-- color for exactly the nodes a stable answer couldn't be found for,
-- rather than show an arbitrary guess.
local function solveWithRules(graph, sourceStates, lockedGateStates, rulesByGate, maxIterations)
    lockedGateStates = lockedGateStates or {}
    rulesByGate = rulesByGate or {}
    maxIterations = maxIterations or 20

    local gateStates = {}
    for id, state in pairs(lockedGateStates) do gateStates[id] = state end

    local nodeStates = solve(graph, sourceStates, gateStates)
    local seenSignatures = { [_gateStatesSignature(gateStates)] = true }

    local iterations = 0
    while iterations < maxIterations do
        iterations = iterations + 1
        local previousGateStates = {}
        for id, state in pairs(gateStates) do previousGateStates[id] = state end

        local changed = false
        for gateId, rule in pairs(rulesByGate) do
            if not lockedGateStates[gateId] then
                local newState = _ruleSaysClosed(rule, nodeStates) and "closed" or "open"
                if gateStates[gateId] ~= newState then
                    gateStates[gateId] = newState
                    changed = true
                end
            end
        end

        if not changed then
            return { converged = true, nodeStates = nodeStates, gateStates = gateStates, iterations = iterations, oscillating = {} }
        end

        local signature = _gateStatesSignature(gateStates)
        if seenSignatures[signature] then
            local oscillating = {}
            for id, state in pairs(gateStates) do
                if previousGateStates[id] ~= state then table.insert(oscillating, id) end
            end
            return { converged = false, nodeStates = nodeStates, gateStates = gateStates, iterations = iterations, oscillating = oscillating }
        end
        seenSignatures[signature] = true
        nodeStates = solve(graph, sourceStates, gateStates)
    end

    return { converged = false, nodeStates = nodeStates, gateStates = gateStates, iterations = iterations, oscillating = {} }
end

-- Per-source color provenance: which ACTIVE source(s) actually reach each
-- node under the current gate configuration, not just whether ANY source
-- does. Reuses solve() once per active source (every other source forced
-- off, gateStates unchanged -- a gate's own conducting state never
-- depends on WHICH source is upstream of it, only on its own
-- open/closed position) rather than reimplementing the flood-fill.
--
-- This is monotonic by construction: running with a SUBSET of sources
-- active can only reach a SUBSET of what the full set reaches (turning on
-- more sources never un-powers anything), so the union of every
-- individual per-source run exactly equals solve()'s own combined
-- powered/unpowered verdict -- this never disagrees with solve(), it only
-- adds WHICH source(s) are responsible for each powered node. Purely a
-- display/coloring concern (see the plan's own "teach it a color per
-- source" follow-on) -- the logical powered/unpowered vocabulary
-- everything else (deduction, rule learning, solveWithRules) reasons in
-- is completely unaffected.
--
-- Returns {nodeId -> {sourceId -> true}} -- a node reached by zero active
-- sources has no entry at all, same "absence means no evidence"
-- convention as the rest of this model layer.
local function solveSourceAttribution(graph, sourceStates, gateStates)
    local attribution = {}
    for sourceId, isOn in pairs(sourceStates or {}) do
        if isOn then
            local states = solve(graph, { [sourceId] = true }, gateStates)
            for nodeId, state in pairs(states) do
                if state == POWERED then
                    attribution[nodeId] = attribution[nodeId] or {}
                    attribution[nodeId][sourceId] = true
                end
            end
        end
    end
    return attribution
end

return {
    solve = solve, solveWithRules = solveWithRules, solveSourceAttribution = solveSourceAttribution,
    POWERED = POWERED,
}
