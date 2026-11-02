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
--
-- A running pump is separate from all of that: it ignores gravity markings and
-- moves fluid from whatever its inlet can draw on to whatever its outlet can
-- deliver to, another tank included, along the same valves, manifolds and check
-- valves. See _pumpRoutes.
--
-- An ejector (a jet pump) has no moving parts and no power of its own. Fluid a
-- running pump pushes in through its motive port draws more in through its suction
-- port, and both leave through its discharge. So its suction tank only drains while
-- a pump drives it, and its discharge can be the very tank that pump draws from: the
-- usual layout, scavenging a wing tank into the collector tank feeding the pump.

-- Gallons a second: about 6 gallons a minute, a half-inch line draining under
-- gravity alone. One rate per store, however many routes lead away from it.
local DRAIN_RATE = 0.1
-- Gallons per grid unit of pipe, reading a grid unit as a foot of half-inch line.
local PIPE_VOLUME_PER_UNIT = 0.01
-- Gallons a second per PSI of pump pressure: 30 PSI moves 600 gallons a minute.
local PUMP_RATE_PER_PSI = 1 / 3
-- Gallons an ejector draws per gallon of the motive flow driving it.
local EJECTOR_ENTRAINMENT = 1

local function _conducts(node, conducting)
    if node.role == "path" or node.role == "directionalGate" then return true end
    if node.role == "gate" or node.role == "gatePole" then return conducting[node.gateOf or node.id] == true end
    return false
end

-- Every node reachable from starts over links, where links[id] is a list of
-- {edge, from, to} and nextKey says which end to walk to. Only passes(id) nodes
-- are walked on from (starts always are). allowed (optional) limits the walk to
-- those links. Returns the reached nodes and the links used, both as sets.
local function _walk(starts, links, nextKey, passes, allowed)
    local reached, isStart, used, stack = {}, {}, {}, {}
    for _, id in ipairs(starts) do
        reached[id], isStart[id] = true, true
        table.insert(stack, id)
    end
    while #stack > 0 do
        local id = table.remove(stack)
        if isStart[id] or passes(id) then
            for _, link in ipairs(links[id] or {}) do
                if not allowed or allowed[link] then
                    used[link] = true
                    local nextId = link[nextKey]
                    if not reached[nextId] then
                        reached[nextId] = true
                        table.insert(stack, nextId)
                    end
                end
            end
        end
    end
    return reached, used
end

-- The running pumps and what each can reach. A pump is a source with a pipe on
-- its inlet port; one with nothing on its inlet has nothing to draw. A pump
-- feeding another pump counts once, as the first in line, so a series pair
-- doesn't move twice the fluid. pressures: {pumpId -> PSI}.
local function _pumpRoutes(graph, conducting, offSources, pressures)
    local isPump, isEjector, downstream, upstream = {}, {}, {}, {}
    local function addLink(edge, from, to)
        local link = { edge = edge, from = from, to = to }
        downstream[from] = downstream[from] or {}
        table.insert(downstream[from], link)
        upstream[to] = upstream[to] or {}
        table.insert(upstream[to], link)
    end
    for _, e in ipairs(graph.edges) do
        if not e.blocked then
            addLink(e, e.fromId, e.toId)
            if not e.directional then addLink(e, e.toId, e.fromId) end
            if e.inletOf and not (offSources and offSources[e.inletOf]) then isPump[e.inletOf] = true end
            if e.suctionOf then isEjector[e.suctionOf] = true end
        end
    end

    local function passes(id)
        return isPump[id] or _conducts(graph.nodes[id], conducting)
    end

    -- What one ejector can draw on through its suction port (and not its motive
    -- port), and what its discharge can reach.
    local function ejectorRoute(id)
        local suctionOnly = {}
        for _, links in pairs(upstream) do
            for _, link in ipairs(links) do
                if link.to ~= id or link.edge.suctionOf == id then suctionOnly[link] = true end
            end
        end
        local draws, suction = _walk({ id }, upstream, "from", passes, suctionOnly)
        local serves, discharge = _walk({ id }, downstream, "to", passes)
        return { id = id, draws = draws, suction = suction, serves = serves, discharge = discharge }
    end

    local pumps = {}
    for id in pairs(isPump) do
        local inlets, suction = _walk({ id }, upstream, "from", passes)
        local leads = true
        for otherId in pairs(isPump) do
            if otherId ~= id and inlets[otherId] then leads = false end
        end
        if leads then
            local outlets, delivery = _walk({ id }, downstream, "to", passes)
            -- Driven only by a pipe into the motive port: a pump on the suction
            -- port is just feeding it, and draws nothing else along.
            local ejectors, driven = {}, {}
            for link in pairs(delivery) do
                if isEjector[link.to] and link.edge.suctionOf ~= link.to and not driven[link.to] then
                    driven[link.to] = true
                    table.insert(ejectors, ejectorRoute(link.to))
                end
            end
            table.insert(pumps, {
                id = id, psi = tonumber(pressures and pressures[id]) or 0,
                inlets = inlets, suction = suction, outlets = outlets, delivery = delivery,
                ejectors = ejectors,
            })
        end
    end
    return pumps, downstream, upstream, passes
end

-- Where gravity can move fluid right now. conducting: {gateControlId -> true}
-- for each open valve. offSources (optional): {sourceId -> true} for each source
-- switched off, such as a pump, which moves nothing. Returns the table step()
-- takes: runs (every pipe's upstream/downstream, as {wire, up, down}), incoming
-- (runs by downstream node), and feeding ({storeOrSourceId -> {wireId -> true}},
-- the pipes fluid is leaving that one through). A pipe in no feeding set isn't
-- draining at all. pressures (optional): {pumpId -> PSI}, what drives each pump.
local function computeFlow(graph, wires, conducting, offSources, pressures)
    local edgeById, pipesOnNode = {}, {}
    for _, e in ipairs(graph.edges) do
        edgeById[e.id] = e
        pipesOnNode[e.fromId] = (pipesOnNode[e.fromId] or 0) + 1
        pipesOnNode[e.toId] = (pipesOnNode[e.toId] or 0) + 1
    end

    local runs, incoming, outgoing = {}, {}, {}
    for _, w in ipairs(wires) do
        local ends, edge = graph.wireEnds and graph.wireEnds[w.id], edgeById[w.id]
        if w.gravityDirection and ends and edge and not edge.blocked then
            local up = (w.gravityDirection == "reverse") and ends.toId or ends.fromId
            local down = (w.gravityDirection == "reverse") and ends.fromId or ends.toId
            -- Gravity against a check valve or a pump's ports doesn't pass it.
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
        if node.role == "source" and not (offSources and offSources[id]) then
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
    local pumps, downstream, upstream, passes = _pumpRoutes(graph, conducting, offSources, pressures)
    return { graph = graph, wires = wires, runs = runs, incoming = incoming, feeding = feeding,
        conducting = conducting, pipesOnNode = pipesOnNode, pumps = pumps,
        downstream = downstream, upstream = upstream, passes = passes }
end

-- Runs every pump for dt seconds, changing the fill of the stores it moves fluid
-- between. Returns {wireId -> "forward"|"reverse"}, the pipes it moved fluid
-- through and which way relative to the wire's own from -> to, and whether any
-- store changed.
local function _stepPumps(flow, stores, dt)
    local graph = flow.graph
    local pumped, changed = {}, false

    local function storeState(id)
        -- nil for a store with no capacity entered, which never fills or empties.
        local store = stores[id]
        local capacity = store and tonumber(store.tankMaxCapacity)
        if not capacity or capacity <= 0 then return nil end
        local gallons = capacity * (store.fillPercent or 100) / 100
        return store, capacity, gallons
    end

    -- The stores among reached with anything to give.
    local function suppliersIn(reached)
        local suppliers, supplierSet = {}, {}
        for id in pairs(reached) do
            -- Only a store holds anything to draw: a pump upstream, on or off, doesn't.
            if stores[id] then
                local store, _, gallons = storeState(id)
                if not store or gallons > 0 then
                    table.insert(suppliers, id)
                    supplierSet[id] = true
                end
            end
        end
        return suppliers, supplierSet
    end

    -- Whatever among reached can take more, other than the suppliers themselves.
    local function receiversIn(reached, supplierSet)
        local receivers = {}
        for id in pairs(reached) do
            local node = graph.nodes[id]
            if not supplierSet[id] then
                local accepts = node.role == "sink"
                if stores[id] then
                    local store, capacity, gallons = storeState(id)
                    accepts = not store or gallons < capacity
                elseif node.role ~= "path" and _conducts(node, flow.conducting) and flow.pipesOnNode[id] == 1 then
                    accepts = true -- an open valve at the end of the line spills
                end
                if accepts then table.insert(receivers, id) end
            end
        end
        return receivers
    end

    -- Split evenly and capped by the emptiest supplier and the fullest receiver,
    -- so what leaves always equals what arrives.
    local function transfer(suppliers, receivers, amount)
        for _, id in ipairs(suppliers) do
            local store, _, gallons = storeState(id)
            if store then amount = math.min(amount, gallons * #suppliers) end
        end
        for _, id in ipairs(receivers) do
            local store, capacity, gallons = storeState(id)
            if store then amount = math.min(amount, (capacity - gallons) * #receivers) end
        end
        for _, id in ipairs(suppliers) do
            local store, capacity, gallons = storeState(id)
            if store then
                store.fillPercent = math.max(0, (gallons - amount / #suppliers) / capacity * 100)
                changed = true
            end
        end
        for _, id in ipairs(receivers) do
            local store, capacity, gallons = storeState(id)
            if store then
                store.fillPercent = math.min(100, (gallons + amount / #receivers) / capacity * 100)
                changed = true
            end
        end
    end

    local function markMoving(used)
        for link in pairs(used) do
            local ends = graph.wireEnds[link.edge.id]
            pumped[link.edge.id] = (ends and ends.toId == link.from) and "reverse" or "forward"
        end
    end

    for _, pump in ipairs(flow.pumps) do
        local suppliers, supplierSet = suppliersIn(pump.inlets)
        if #suppliers > 0 and pump.psi > 0 then
            local gallons = pump.psi * PUMP_RATE_PER_PSI * dt
            local receivers = receiversIn(pump.outlets, supplierSet)
            -- Only the pipes actually between a supplier and a receiver.
            local _, drawing = _walk(suppliers, flow.downstream, "to", flow.passes, pump.suction)
            if #receivers > 0 then
                transfer(suppliers, receivers, gallons)
                local _, delivering = _walk(receivers, flow.upstream, "from", flow.passes, pump.delivery)
                markMoving(drawing)
                markMoving(delivering)
            end

            for _, ejector in ipairs(pump.ejectors) do
                local drawn, drawnSet = suppliersIn(ejector.draws)
                local served = receiversIn(ejector.serves, drawnSet)
                if #served > 0 then
                    if #drawn > 0 then
                        transfer(drawn, served, gallons * EJECTOR_ENTRAINMENT / #pump.ejectors)
                        markMoving(select(2, _walk(drawn, flow.downstream, "to", flow.passes, ejector.suction)))
                    end
                    -- The motive flow runs whether or not there's anything left to
                    -- draw, even when it only circles back to the pump's own tank.
                    markMoving(drawing)
                    markMoving(select(2, _walk({ ejector.id }, flow.upstream, "from", flow.passes, pump.delivery)))
                    markMoving(select(2, _walk(served, flow.upstream, "from", flow.passes, ejector.discharge)))
                end
            end
        end
    end
    return pumped, changed
end

-- Advances everything by dt seconds, writing store.fillPercent (nil reads as
-- full), w.fluidPercent (nil reads as full), w.fluidMoving (whether fluid is
-- running through that pipe right now) and w.pumpedDirection (which way a pump
-- is driving it, "forward"/"reverse", else nil). stores: {nodeId -> entity with
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

    local pumped, pumpChanged = _stepPumps(flow, stores, dt)
    changed = changed or pumpChanged

    for _, w in ipairs(flow.wires) do
        w.pumpedDirection = pumped[w.id]
        -- A pipe a pump is pushing through is full, whatever gravity left in it.
        if pumped[w.id] and w.fluidPercent then
            w.fluidPercent = nil
            changed = true
        end
        w.fluidMoving = (pumped[w.id] ~= nil) or (fedAnywhere[w.id] and (w.fluidPercent or 100) > 0) or false
    end

    local stillFeeding = {}
    for id, fed in pairs(flow.feeding) do
        for _, run in ipairs(flow.runs) do
            if fed[run.wire.id] and (run.wire.fluidPercent or 100) > 0 then stillFeeding[id] = true end
        end
    end
    return changed, stillFeeding
end

return { computeFlow = computeFlow, step = step, DRAIN_RATE = DRAIN_RATE, PIPE_VOLUME_PER_UNIT = PIPE_VOLUME_PER_UNIT,
    PUMP_RATE_PER_PSI = PUMP_RATE_PER_PSI, EJECTOR_ENTRAINMENT = EJECTOR_ENTRAINMENT }
