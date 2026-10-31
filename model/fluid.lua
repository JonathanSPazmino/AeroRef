-- model/fluid.lua
--
-- Pure-Lua, love.*-free gravity drain model over a model/graph.lua graph, for
-- the liquid systems. A pipe marked with a gravity direction moves fluid that
-- way (w.gravityDirection: "forward" is the wire's from -> to, "reverse" to ->
-- from; nil is a level run that moves nothing). A store loses fluid only while
-- an unbroken run of such pipes, every one pointing downstream, leads from it to
-- somewhere the fluid can actually go:
--   "sink"                    -- an engine or reservoir takes it
--   an open valve or check valve with no other pipe on it -- it spills out
-- and passes through on the way there:
--   "path"                    -- a manifold, which is sealed if nothing leads on
--   an open "gate"/"gatePole" -- a valve (conducting says which are open)
--   "directionalGate"         -- a check valve, only the way it conducts
-- Anything else blocks the run, another store or source included: a tank piped
-- to a tank loses nothing.
--
-- Rates are constant, by design of the request rather than from head pressure,
-- and capacities are read as US gallons (the app stores no unit).

-- Gallons a second: about 6 gallons a minute, a half-inch line draining under
-- gravity alone. One rate per store, however many routes lead away from it.
local DRAIN_RATE = 0.1
-- Gallons per grid unit of pipe, reading a grid unit as a foot of half-inch line.
local PIPE_VOLUME_PER_UNIT = 0.01

local function _conducts(node, conducting)
    if node.role == "path" or node.role == "directionalGate" then return true end
    if node.role == "gate" or node.role == "gatePole" then return conducting[node.gateOf or node.id] == true end
    return false
end

-- Where gravity can move fluid right now. conducting: {gateControlId -> true}
-- for each open valve. Returns the table step() takes: runs (every pipe's
-- upstream/downstream, as {wire, up, down}), incoming (runs by downstream node),
-- and feeding ({storeOrSourceId -> {wireId -> true}}, the pipes fluid is leaving
-- that one through). A pipe in no feeding set isn't draining at all.
local function computeFlow(graph, wires, conducting)
    local edgeById, pipesOnNode = {}, {}
    for _, e in ipairs(graph.edges) do
        edgeById[e.id] = e
        pipesOnNode[e.fromId] = (pipesOnNode[e.fromId] or 0) + 1
        pipesOnNode[e.toId] = (pipesOnNode[e.toId] or 0) + 1
    end

    local runs, incoming, outgoing = {}, {}, {}
    for _, w in ipairs(wires) do
        local ends, edge = graph.wireEnds and graph.wireEnds[w.id], edgeById[w.id]
        if w.gravityDirection and ends and edge then
            local up = (w.gravityDirection == "reverse") and ends.toId or ends.fromId
            local down = (w.gravityDirection == "reverse") and ends.fromId or ends.toId
            -- Gravity against a check valve doesn't pass it.
            if not (edge.directional and edge.fromId ~= up) then
                local run = { wire = w, up = up, down = down }
                table.insert(runs, run)
                incoming[down] = incoming[down] or {}
                table.insert(incoming[down], run)
                outgoing[up] = outgoing[up] or {}
                table.insert(outgoing[up], run)
            end
        end
    end

    -- Walks back up from every outlet to find the runs that lead to one.
    local leadsOut, nodeLeadsOut, queue, head = {}, {}, {}, 1
    for id in pairs(incoming) do
        local node = graph.nodes[id]
        if node.role == "sink" or (node.role ~= "path" and _conducts(node, conducting) and pipesOnNode[id] == 1) then
            nodeLeadsOut[id] = true
            table.insert(queue, id)
        end
    end
    while head <= #queue do
        local id = queue[head]; head = head + 1
        for _, run in ipairs(incoming[id] or {}) do
            leadsOut[run] = true
            if not nodeLeadsOut[run.up] and _conducts(graph.nodes[run.up], conducting) then
                nodeLeadsOut[run.up] = true
                table.insert(queue, run.up)
            end
        end
    end

    -- Then down from each source, so a run only counts for one it's fed from.
    local feeding = {}
    for id, node in pairs(graph.nodes) do
        if node.role == "source" then
            local fed, stack = {}, { id }
            while #stack > 0 do
                for _, run in ipairs(outgoing[table.remove(stack)] or {}) do
                    if leadsOut[run] and not fed[run.wire.id] then
                        fed[run.wire.id] = true
                        table.insert(stack, run.down)
                    end
                end
            end
            if next(fed) then feeding[id] = fed end
        end
    end
    return { graph = graph, runs = runs, incoming = incoming, feeding = feeding }
end

-- Advances everything by dt seconds, writing store.fillPercent (nil reads as
-- full) and w.fluidPercent (nil reads as full). stores: {nodeId -> entity with
-- tankMaxCapacity}; a store with no capacity can't be worked out as a percent,
-- so it neither loses fluid nor runs dry. pipeUnits: {wireId -> length in grid
-- units}. A pipe stays full while what feeds it has fluid, then empties at the
-- same flow rate from its upstream end. Returns whether anything changed, and
-- {sourceId -> true} for each source with fluid still leaving through its pipes.
local function step(flow, stores, pipeUnits, dt)
    local changed = false
    local fedAnywhere = {}
    for id, fed in pairs(flow.feeding) do
        for wireId in pairs(fed) do fedAnywhere[wireId] = true end
        local store = stores[id]
        local capacity = store and tonumber(store.tankMaxCapacity)
        if capacity and capacity > 0 and (store.fillPercent or 100) > 0 then
            store.fillPercent = math.max(0, (store.fillPercent or 100) - DRAIN_RATE * dt / capacity * 100)
            changed = true
        end
    end

    local function hasFluid(id)
        if flow.graph.nodes[id].role == "source" then
            local store = stores[id]
            local capacity = store and tonumber(store.tankMaxCapacity)
            return not store or not capacity or capacity <= 0 or (store.fillPercent or 100) > 0
        end
        for _, run in ipairs(flow.incoming[id] or {}) do
            if (run.wire.fluidPercent or 100) > 0 then return true end
        end
        return false
    end

    for _, run in ipairs(flow.runs) do
        local w = run.wire
        if hasFluid(run.up) then
            if w.fluidPercent then
                w.fluidPercent = nil
                changed = true
            end
        elseif fedAnywhere[w.id] and (w.fluidPercent or 100) > 0 then
            local seconds = math.max(pipeUnits[w.id] or 1, 1) * PIPE_VOLUME_PER_UNIT / DRAIN_RATE
            w.fluidPercent = math.max(0, (w.fluidPercent or 100) - dt / seconds * 100)
            changed = true
        end
    end

    local stillFeeding = {}
    for id, fed in pairs(flow.feeding) do
        for _, run in ipairs(flow.runs) do
            if fed[run.wire.id] and (run.wire.fluidPercent or 100) > 0 then stillFeeding[id] = true end
        end
    end
    return changed, stillFeeding
end

return { computeFlow = computeFlow, step = step, DRAIN_RATE = DRAIN_RATE, PIPE_VOLUME_PER_UNIT = PIPE_VOLUME_PER_UNIT }
