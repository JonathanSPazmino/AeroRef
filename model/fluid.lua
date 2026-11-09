-- model/fluid.lua
--
-- Pure-Lua, love.*-free gravity drain model over a model/graph.lua graph, for
-- the liquid systems. A pipe marked with a gravity direction moves fluid that
-- way (w.gravityDirection: "forward" is the wire's from -> to, "reverse" to ->
-- from; nil is a level run that moves nothing). A store loses fluid only while
-- an unbroken run of such pipes, every one pointing downstream, leads from it to
-- somewhere the fluid can actually go:
--   "sink"                    -- an engine or reservoir takes it
--   another store with room   -- a tank downhill of it, gaining what this one loses
--   an open pipe end          -- a valve, check valve, or manifold with no other
--                                pipe on it, so it leaks: spills out into the open
--                                air rather than reaching any enclosure -- see
--                                w.leaking below
-- and passes through on the way there:
--   "path"                    -- a manifold, carrying along whatever reaches it
--   an open "gate"/"gatePole" -- a valve (conducting says which are open)
--   "directionalGate"         -- a check valve, only the way it conducts
-- Anything else blocks the run, another source (a pump, never a store) included.
-- A receiving store only ever ends a run — gravity doesn't pour through a tank
-- into whatever's beyond it, even downhill; that leg waits for the tank's own
-- level, as its own source, to lead somewhere next tick. A full receiving store
-- blocks the run exactly like any other sealed end, holding its supplier back.
--
-- Rates are constant, by design of the request rather than from head pressure,
-- and capacities are read as US gallons (the app stores no unit). A store with
-- no capacity entered can't be a receiver — see _storeState — so it still
-- blocks a run reaching it, same as before capacities existed at all.
--
-- A running pump is separate from all of that: it ignores gravity markings and
-- moves fluid from whatever its inlet can draw on to whatever its outlet can
-- deliver to, another tank included, along the same valves, manifolds and check
-- valves. See _pumpRoutes.
--
-- An ejector (a jet pump) has no moving parts and no power of its own. Fluid a
-- running pump pushes in through its motive port draws more in through its suction
-- port, and both leave through its discharge, which can be the very tank that pump
-- draws from: the usual layout, scavenging a wing tank into the collector tank
-- feeding the pump. Only a driven ejector moves fluid into another tank. To gravity
-- it is an open check valve, suction port included, so a gravity-marked run through
-- it still drains its suction tank to a sink or an open line end, pump or not.

-- Gallons a second: about 6 gallons a minute, a half-inch line draining under
-- gravity alone. One rate per store, however many routes lead away from it.
local DRAIN_RATE = 0.1
-- Gallons per grid unit of pipe, reading a grid unit as a foot of half-inch line.
local PIPE_VOLUME_PER_UNIT = 0.01
-- Gallons a second per PSI of pump pressure: 30 PSI moves 600 gallons a minute.
local PUMP_RATE_PER_PSI = 1 / 3
-- Gallons an ejector draws per gallon of the motive flow driving it.
local EJECTOR_ENTRAINMENT = 1
-- A gravity-fed line's own "pressure" for the contention check below --
-- fixed at 0 and below any real pump (pump.psi is always > 0 once it's
-- actually running, see _stepPumps' own gate), so a running pump always
-- outranks gravity at a shared junction; two gravity attempts always tie at
-- 0, which is exactly "never reversed" (see _resolveContention).
local GRAVITY_PRESSURE = 0

-- A gravity-only leak's own nominal PSI for the leak-SPRAY animation's own
-- intensity scaling (w.leakPressure, set in step() below) -- deliberately
-- NOT the same as GRAVITY_PRESSURE above (that 0 exists purely so gravity
-- never wins a pressure-contention tie; reused here it would wrongly
-- suppress a gravity-fed leak's spray to nothing).
local GRAVITY_LEAK_BASELINE_PSI = 3

local function _conducts(node, conducting)
    if node.role == "path" or node.role == "directionalGate" then return true end
    if node.role == "gate" or node.role == "gatePole" then return conducting[node.gateOf or node.id] == true end
    return false
end

-- store, capacity, gallons currently held -- or nil for a store with no
-- capacity entered, which never fills or empties and so never receives either.
local function _storeState(stores, id)
    local store = stores and stores[id]
    local capacity = store and tonumber(store.tankMaxCapacity)
    if not capacity or capacity <= 0 then return nil end
    return store, capacity, capacity * (store.fillPercent or 100) / 100
end

local function _storeHasRoom(stores, id)
    local _, capacity, gallons = _storeState(stores, id)
    return capacity ~= nil and gallons < capacity
end

-- Whether a "source" node itself currently holds anything: true for a store
-- with no capacity entered (can't be worked out as a percent, so it neither
-- loses fluid nor runs dry -- same as _storeState's own convention) or one
-- with gallons > 0, same rule step()'s own hasFluid uses for a run's up end.
local function _nodeHasFluid(stores, id)
    local _, capacity, gallons = _storeState(stores, id)
    return capacity == nil or gallons > 0
end

-- The stores among `reached` with anything to give -- hoisted out of
-- _stepPumps (which still has its own thin closure wrapping this) so
-- computeFlow can preview the exact same thing before any pump actually
-- runs, for the pressure-contention check below.
local function _suppliersIn(stores, reached)
    local suppliers, supplierSet = {}, {}
    for id in pairs(reached) do
        if stores and stores[id] then
            local store, _, gallons = _storeState(stores, id)
            if not store or gallons > 0 then
                table.insert(suppliers, id)
                supplierSet[id] = true
            end
        end
    end
    return suppliers, supplierSet
end

-- Whatever among `reached` can take more, other than the suppliers
-- themselves -- same hoist as _suppliersIn above, for the same reason.
local function _receiversIn(graph, stores, conducting, pipesOnNode, reached, supplierSet)
    local receivers, leakReceivers = {}, {}
    for id in pairs(reached) do
        local node = graph.nodes[id]
        if not supplierSet[id] then
            local accepts, isLeak = node.role == "sink", false
            if stores and stores[id] then
                local store, capacity, gallons = _storeState(stores, id)
                accepts = not store or gallons < capacity
            elseif _conducts(node, conducting) and pipesOnNode[id] == 1 then
                accepts, isLeak = true, true -- an open pipe end spills
            end
            if accepts then
                table.insert(receivers, id)
                if isLeak then leakReceivers[id] = true end
            end
        end
    end
    return receivers, leakReceivers
end

-- Resolves pressure contention among `attempts` (nodeId -> array of
-- {wireId, pressure, kind = "gravity"|"pump", down = nodeId, otherEnd =
-- nodeId, sourceId|pumpId}), built while walking gravity's own per-source
-- reach and previewing each pump's own delivery -- see computeFlow's two
-- call sites below. A node reached by 2+ DISTINCT wires (de-duped by wire
-- id first -- the same wire can show up once as a gravity attempt and once
-- as a pump attempt when a pump is pushing through an otherwise gravity-
-- marked pipe, in which case the pump's own pressure wins outright, same
-- as a pump already overriding gravity's own display direction everywhere
-- else in this file) has its single STRICT, UNIQUE lowest-pressure wire
-- marked as having lost; a tie -- gravity vs. gravity (both GRAVITY_
-- PRESSURE), or an exact PSI match between two pumps -- reverses nothing,
-- matching the gravity-vs-gravity case (no head-pressure data here to
-- break a tie -- see this file's header comment). Returns {wireId ->
-- attempt} for exactly the wires that lost.
-- A loop of conducting ("path") nodes puts the SAME non-directional edge
-- into a `used` table (see _walk's own comment) TWICE -- once per
-- direction -- since a walk restricted to non-directional edges can touch
-- either side of one. Only one direction is the walk's own real, as-
-- reached-first direction; _stepPumps' own markMoving already picks it
-- via `used`'s order values for display -- this is the exact same
-- selection, hoisted so the contention preview below can use the same
-- canonical direction per edge a real pump delivery would, instead of
-- treating a merely-touched reverse-direction link as its own attempt.
-- Returns {edgeId -> link}.
local function _deliveryWinners(used)
    local winners = {}
    for link, order in pairs(used) do
        local edgeId = link.edge.id
        if not winners[edgeId] or order < winners[edgeId].order then
            winners[edgeId] = { link = link, order = order }
        end
    end
    local byEdge = {}
    for edgeId, entry in pairs(winners) do byEdge[edgeId] = entry.link end
    return byEdge
end

local function _resolveContention(attempts)
    local losers = {}
    for _, list in pairs(attempts) do
        if #list >= 2 then
            local byWire = {}
            for _, a in ipairs(list) do
                local existing = byWire[a.wireId]
                if not existing or a.kind == "pump" then byWire[a.wireId] = a end
            end
            local distinct = 0
            for _ in pairs(byWire) do distinct = distinct + 1 end
            if distinct >= 2 then
                -- The GLOBAL lowest pressure here, directional (a check
                -- valve's or a pump's own outlet port -- both equally
                -- one-way) wires included: a directional wire's pressure
                -- still has to be genuinely beaten, not just ignored, or an
                -- ordinary wire tied with a protected one at the same low
                -- pressure would wrongly look like a unique minimum on its
                -- own and get reversed against a tie it never actually won.
                local minPressure, minCount = nil, 0
                for _, a in pairs(byWire) do
                    if not minPressure or a.pressure < minPressure then minPressure, minCount = a.pressure, 1
                    elseif a.pressure == minPressure then minCount = minCount + 1 end
                end
                -- Only reverse when that unique global minimum is actually
                -- eligible to -- there's no such thing as reversing
                -- something that already only flows one way. A directional
                -- wire holding the (unique) lowest pressure means nothing
                -- reverses at all: it's already the lowest, so nothing
                -- else here outranks it enough to push it back, and it
                -- can't be pushed back itself either.
                if minCount == 1 then
                    for _, a in pairs(byWire) do
                        if a.pressure == minPressure then
                            if not a.directional then losers[a.wireId] = a end
                            break
                        end
                    end
                end
            end
        end
    end
    return losers
end

-- Every node reachable from starts over links, where links[id] is a list of
-- {edge, from, to} and nextKey says which end to walk to. Only passes(id) nodes
-- are walked on from (starts always are). allowed (optional) limits the walk to
-- those links. Returns the reached nodes (a set) and the links used -- still a
-- set for every existing truthy/membership use (if allowed[link]/for link in
-- pairs(used)), but each value is the order that link was actually touched in
-- (1, 2, 3, ...) rather than a flat `true`, a deterministic tie-break
-- _stepPumps' own markMoving needs: a loop of conducting nodes reaches a
-- non-directional edge from BOTH ends (once as whichever link first
-- discovered a node, once more as the mirror addLink gives every such edge
-- for reachability -- see _pumpRoutes), so the same wire can land in here
-- twice, one entry per direction. Letting pairs() iteration order settle
-- which one "wins" would make the stored order, not either direction's own
-- meaning, decide -- and that order isn't guaranteed stable across rebuilds
-- of this same table, which is exactly what let a looped pipe's displayed
-- flow flip between forward/reverse from one tick to the next. The sequence
-- number here lets a caller that cares (markMoving) always prefer whichever
-- direction this SAME deterministic walk actually reached first, instead.
local function _walk(starts, links, nextKey, passes, allowed)
    local reached, isStart, used, stack, order = {}, {}, {}, {}, 0
    for _, id in ipairs(starts) do
        reached[id], isStart[id] = true, true
        table.insert(stack, id)
    end
    while #stack > 0 do
        local id = table.remove(stack)
        if isStart[id] or passes(id) then
            for _, link in ipairs(links[id] or {}) do
                if not allowed or allowed[link] then
                    order = order + 1
                    used[link] = order
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
-- (runs by downstream node), feeding ({storeOrSourceId -> {wireId -> true}}, the
-- pipes fluid is leaving that one through -- a pipe in no feeding set isn't
-- draining at all), receivingStores ({sourceId -> {storeId -> true}}, which
-- of the stores that source's feeding runs reach actually gain the fluid),
-- and leakingWires ({wireId -> true}, the pipes among those feeding runs whose
-- downstream end is an open pipe end rather than a sink or tank -- see the
-- header comment -- so step() can mark w.leaking on exactly those).
-- pressures (optional): {pumpId -> PSI}, what drives each pump. stores
-- (optional): {id -> entity with tankMaxCapacity/fillPercent}, read here only to
-- tell whether a tank downstream has room to receive gravity flow.
local function computeFlow(graph, wires, conducting, offSources, pressures, stores)
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

    -- Every node a real source's standing fluid could plausibly reach via a
    -- valid, direction-respecting chain of runs (gravity's own up -> down,
    -- never against a check valve/pump port -- the same runs built above) --
    -- regardless of whether that chain actually terminates anywhere useful.
    -- A dead stub off a wet manifold is still wet (step()'s own hasFluid is
    -- the live, tick-over-tick counterpart of this -- see its own comment
    -- on run.up) even though nothing ever drains through it; this is the
    -- one-shot, purely-structural version a static color prediction needs,
    -- with no tick history (w.fluidPercent) to read instead. wetNodes[id]
    -- is left false (not nil) while id is still being resolved, so a cycle
    -- of conducting nodes doesn't recurse forever -- it just isn't wet
    -- through that cycle alone, same as it genuinely wouldn't be.
    local wetNodes = {}
    local function isWet(id)
        local known = wetNodes[id]
        if known ~= nil then return known end
        wetNodes[id] = false
        local node = graph.nodes[id]
        local wet
        if node.role == "source" then
            wet = _nodeHasFluid(stores, id)
        else
            wet = false
            for _, run in ipairs(incoming[id] or {}) do
                if isWet(run.up) then wet = true break end
            end
        end
        wetNodes[id] = wet
        return wet
    end
    local wetWires = {}
    for _, run in ipairs(runs) do
        if isWet(run.up) then wetWires[run.wire.id] = true end
    end

    -- Walks back up from every outlet to find the runs that lead to one. A
    -- conducting node (a valve, check valve, or now a manifold too -- "path"
    -- gets no special exemption here any more, so a manifold with only one
    -- pipe on it leaks exactly like an open valve would) with nothing else on
    -- it has nowhere to send fluid but out into the open air: leakNodes
    -- records those so the per-source walk below can tell which of the pipes
    -- it marks as fed are actually leaking rather than reaching a sink or tank.
    local leadsOut, nodeLeadsOut, leakNodes, queue, head = {}, {}, {}, {}, 1
    for id in pairs(incoming) do
        local node = graph.nodes[id]
        if node.role == "sink" or _storeHasRoom(stores, id) then
            nodeLeadsOut[id] = true
            table.insert(queue, id)
        elseif _conducts(node, conducting) and pipesOnNode[id] == 1 then
            nodeLeadsOut[id] = true
            leakNodes[id] = true
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
    -- A reached store with room ends its branch there (see the header comment
    -- on why gravity doesn't pour through a tank into whatever's past it) and
    -- is recorded into `out.receivingStores` rather than walked further.
    -- Every such fed wire is also recorded as an "attempt" on whichever node
    -- it reaches (reversedWires nil, i.e. the first, discovery-only pass
    -- below) -- for the pressure-contention check once every source's reach
    -- AND every pump's own preview, right after, is known.
    --
    -- Once contention is resolved (reversedWires given, the second, real
    -- pass below), a wire that lost (reversedWires[run.wire.id]) is
    -- redirected to its own one-hop destination instead, and -- since
    -- fluid never actually reached run.down through it this tick -- the
    -- walk does NOT continue past it, so a chain of any length past a
    -- reversed wire correctly stops being "fed" by this source too, not
    -- just the reversed wire itself.
    local attempts = {}
    local function walkSource(id, reversedWires, out)
        local fed, stack = {}, { id }
        while #stack > 0 do
            for _, run in ipairs(outgoing[table.remove(stack)] or {}) do
                if leadsOut[run] and not fed[run.wire.id] then
                    fed[run.wire.id] = true
                    if not reversedWires then
                        attempts[run.down] = attempts[run.down] or {}
                        table.insert(attempts[run.down], { wireId = run.wire.id, pressure = GRAVITY_PRESSURE,
                            kind = "gravity", down = run.down, otherEnd = run.up, sourceId = id,
                            directional = edgeById[run.wire.id].directional })
                    end
                    local lost = reversedWires and reversedWires[run.wire.id]
                    if lost then
                        -- lost.destId was chosen excluding whichever ONE
                        -- source's own attempt happened to "win" the
                        -- gravity-vs-gravity dedup in _resolveContention
                        -- (the same shared wire can be fed by more than
                        -- one source -- see walkSource's own pass-1 call).
                        -- A DIFFERENT source re-walking this same wire here
                        -- could still find that destination IS itself, so
                        -- the self-credit guard is re-checked per source,
                        -- not just once globally.
                        if lost.destId and lost.destId ~= id then
                            out.receivingStores[id] = out.receivingStores[id] or {}
                            out.receivingStores[id][lost.destId] = true
                        elseif lost.leak then
                            out.leakingWires[run.wire.id] = true
                        end
                    elseif run.down ~= id and _storeHasRoom(stores, run.down) then
                        out.receivingStores[id] = out.receivingStores[id] or {}
                        out.receivingStores[id][run.down] = true
                    else
                        if leakNodes[run.down] then out.leakingWires[run.wire.id] = true end
                        table.insert(stack, run.down)
                    end
                end
            end
        end
        return fed
    end

    -- Pass 1: discovery only -- attempts, and which wires this graph's
    -- gravity even structurally reaches at all. receivingStores/
    -- leakingWires here are provisional (contention-unaware) and thrown
    -- away once resolution is known; pass 2 below produces the real ones.
    local discard = { receivingStores = {}, leakingWires = {} }
    for id, node in pairs(graph.nodes) do
        if node.role == "source" and not (offSources and offSources[id]) then
            walkSource(id, nil, discard)
        end
    end

    local pumps, downstream, upstream, passes = _pumpRoutes(graph, conducting, offSources, pressures)

    -- Preview, using this tick's pre-transfer stores snapshot, exactly which
    -- node(s) each running pump would actually deliver into -- the same
    -- computation _stepPumps makes for real, just ahead of time so a pump's
    -- own attempts can be weighed against gravity's (and each other's)
    -- before any fillPercent actually changes. An off/dry/0-PSI pump never
    -- attempts anything, same gate _stepPumps itself uses for a real transfer.
    -- Attempts are recorded at EVERY node the delivery reaches (pump.outlets,
    -- the full walked set), not just its final accepted receivers -- a plain
    -- pass-through junction two pipes meet at is exactly where real backflow
    -- would show up, same as gravity's own attempts above already cover a
    -- bare junction, not just a store. _deliveryWinners picks each edge's
    -- one canonical direction, same as a real delivery's own markMoving
    -- would, so a loop's mirror-direction touch on an edge never counts as
    -- its own separate attempt.
    local pumpSupplierSets = {}
    for _, pump in ipairs(pumps) do
        local _, supplierSet = _suppliersIn(stores, pump.inlets)
        pumpSupplierSets[pump.id] = supplierSet
        if next(supplierSet) and pump.psi > 0 then
            for edgeId, link in pairs(_deliveryWinners(pump.delivery)) do
                local rid = link.to
                attempts[rid] = attempts[rid] or {}
                table.insert(attempts[rid], { wireId = edgeId, pressure = pump.psi,
                    kind = "pump", down = rid, otherEnd = link.from, pumpId = pump.id,
                    directional = edgeById[edgeId].directional })
            end
        end
    end

    -- Where fluid reversed out of `startId` (a losing wire's own other
    -- end) actually ends up: a plain trace back through `incoming` --
    -- exactly the same pipes that would normally feed INTO startId --
    -- until a store with room (a real backflow destination) or a genuine
    -- dead pipe end (a leak) is reached. This is still a single, direct
    -- trace, not a recursive re-solve of whatever else might be
    -- contending further back (see this file's own scope note) -- it
    -- just follows an otherwise-uncontested path to where it actually
    -- goes, the same privilege the forward walk above already has.
    -- exclude: a set of ids ({id -> true}) this trace must never land on
    -- as a destination -- the wire's own source (gravity), or the pump's
    -- own suppliers (pump): redirecting fluid right back into a store
    -- it's simultaneously being drained from/credited into is a real
    -- no-op, but step()'s drain/transfer and receivingStores writes share
    -- that one store table, so crediting and draining it in the same
    -- tick would silently lose fluid instead of cancelling out -- so
    -- those ids are skipped as a destination (the trace just continues
    -- past them looking for anywhere else).
    local function findReversalDestination(startId, exclude)
        local visited, stack = {}, { startId }
        while #stack > 0 do
            local id = table.remove(stack)
            if not visited[id] then
                visited[id] = true
                if not (exclude and exclude[id]) and _storeHasRoom(stores, id) then return id, false end
                if leakNodes[id] then return nil, true end
                for _, run in ipairs(incoming[id] or {}) do
                    table.insert(stack, run.up)
                end
            end
        end
        return nil, false
    end

    -- Resolve contention and give every losing wire a REAL destination,
    -- rather than just blocking it. A loser whose trace finds neither a
    -- store nor a dead end anywhere back up its own chain (it dead-ends
    -- into something else entirely, or loops) keeps today's plain-
    -- delivery behavior instead.
    local reversed = {}
    for wireId, loser in pairs(_resolveContention(attempts)) do
        local exclude = (loser.kind == "gravity") and { [loser.sourceId] = true } or pumpSupplierSets[loser.pumpId]
        local destId, leak = findReversalDestination(loser.otherEnd, exclude)
        if destId or leak then
            local ends = graph.wireEnds[wireId]
            local direction = (ends and ends.fromId == loser.down) and "forward" or "reverse"
            reversed[wireId] = { direction = direction, destId = destId, leak = leak,
                kind = loser.kind, sourceId = loser.sourceId, pumpId = loser.pumpId }
        end
    end

    -- Pass 2: the real, final walk, now contention-aware -- see
    -- walkSource's own comment for why this has to be a fresh walk rather
    -- than a patch of pass 1's output.
    local feeding, receivingStores, leakingWires = {}, {}, {}
    for id, node in pairs(graph.nodes) do
        if node.role == "source" and not (offSources and offSources[id]) then
            local fed = walkSource(id, reversed, { receivingStores = receivingStores, leakingWires = leakingWires })
            if next(fed) then feeding[id] = fed end
        end
    end

    return { graph = graph, wires = wires, runs = runs, incoming = incoming, feeding = feeding,
        receivingStores = receivingStores, leakingWires = leakingWires, wetWires = wetWires, conducting = conducting,
        pipesOnNode = pipesOnNode, pumps = pumps, downstream = downstream, upstream = upstream, passes = passes,
        reversed = reversed }
end

-- Runs every pump for dt seconds, changing the fill of the stores it moves fluid
-- between. Returns {wireId -> "forward"|"reverse"}, the pipes it moved fluid
-- through and which way relative to the wire's own from -> to; whether any
-- store changed; and leaking ({wireId -> true}, the last pipe into any open
-- pipe end a pump (or an ejector it drives) pushed fluid into -- see the
-- header comment on leakNodes/leakingWires in computeFlow, the gravity-side
-- counterpart this mirrors).
local function _stepPumps(flow, stores, dt)
    local graph = flow.graph
    local pumped, changed, leaking = {}, false, {}

    local function storeState(id) return _storeState(stores, id) end

    -- Thin wrappers over the module-scope versions above (hoisted so
    -- computeFlow can preview the exact same thing before any pump
    -- actually runs, for the pressure-contention check -- see its own
    -- comment and _resolveContention).
    local function suppliersIn(reached) return _suppliersIn(stores, reached) end
    local function receiversIn(reached, supplierSet)
        return _receiversIn(graph, stores, flow.conducting, flow.pipesOnNode, reached, supplierSet)
    end

    -- The pipe(s) directly feeding a leaking receiver, among the ones allowed
    -- for this particular delivery (pump.delivery or an ejector's discharge),
    -- marked in `leaking` -- with the real driving PSI (an ejector's own
    -- discharge is driven by its pump's psi too, same as its motive line),
    -- not just a bare true, so step() can scale the leak-spray animation's
    -- own intensity by it. Still truthy everywhere this is already read as
    -- a boolean.
    local function markLeaking(leakReceivers, allowed, psi)
        for id in pairs(leakReceivers) do
            for _, link in ipairs(flow.upstream[id] or {}) do
                if allowed[link] then leaking[link.edge.id] = psi end
            end
        end
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

    -- Marks every wire a delivery walk (used, see _walk's own "used" return)
    -- touched as pumped, and which way. A loop of conducting ("path") nodes
    -- -- two manifolds tied together by more than one pipe, say -- puts the
    -- SAME non-directional wire into `used` TWICE: once as the link that
    -- discovered a node, once more as the mirror _pumpRoutes' own addLink
    -- adds for every non-directional edge (so reachability works walking
    -- either way), picked up again once the walk explores that already-
    -- reached node's own outgoing links. Which of the two actually matches
    -- the real flow depends on the loop's own layout, not on which way
    -- either wire happens to be drawn -- so picking the "natural" (as-drawn)
    -- direction whenever both are present, tried first, got it right for
    -- one of the loop's pipes and backwards for the other, consistently
    -- (stable, but still wrong for that one). _walk's own order (see its
    -- comment) is the real tie-break: whichever direction THIS walk
    -- actually reached that edge through FIRST, by its own deterministic
    -- traversal, is the one that reflects how the flow actually got there --
    -- and unlike pairs() order over a freshly-rebuilt table, that's a
    -- function of the graph alone, identical every time this same shape is
    -- walked, which is what stops the random flip-flopping.
    local function markMoving(used)
        for edgeId, link in pairs(_deliveryWinners(used)) do
            local ends = graph.wireEnds[edgeId]
            pumped[edgeId] = (ends and ends.toId == link.from) and "reverse" or "forward"
        end
    end

    for _, pump in ipairs(flow.pumps) do
        local suppliers, supplierSet = suppliersIn(pump.inlets)
        if #suppliers > 0 and pump.psi > 0 then
            local gallons = pump.psi * PUMP_RATE_PER_PSI * dt
            local receivers, leakReceivers = receiversIn(pump.outlets, supplierSet)
            -- A receiver this pump lost a pressure contention for (see
            -- computeFlow's own preview/_resolveContention) is carved out
            -- of its normal delivery here -- its share instead goes
            -- backward through the losing wire itself, below, so the
            -- pump's remaining, unaffected receivers still split the full
            -- `gallons` among just themselves rather than a smaller cut.
            local originalReceiverCount = #receivers
            local redirected = {}
            for wireId, r in pairs(flow.reversed) do
                if r.pumpId == pump.id then table.insert(redirected, { wireId = wireId, r = r }) end
            end
            if #redirected > 0 then
                local excluded = {}
                for _, item in ipairs(redirected) do excluded[item.r.down] = true end
                local filtered, filteredLeak = {}, {}
                for _, rid in ipairs(receivers) do
                    if not excluded[rid] then table.insert(filtered, rid) end
                end
                for rid in pairs(leakReceivers) do
                    if not excluded[rid] then filteredLeak[rid] = true end
                end
                receivers, leakReceivers = filtered, filteredLeak
            end
            -- Only the pipes actually between a supplier and a receiver.
            local _, drawing = _walk(suppliers, flow.downstream, "to", flow.passes, pump.suction)
            if #receivers > 0 then
                transfer(suppliers, receivers, gallons)
                local _, delivering = _walk(receivers, flow.upstream, "from", flow.passes, pump.delivery)
                markMoving(delivering)
                markLeaking(leakReceivers, pump.delivery, pump.psi)
            end
            if #receivers > 0 or #redirected > 0 then markMoving(drawing) end
            for _, item in ipairs(redirected) do
                local r, wireId = item.r, item.wireId
                local share = gallons / math.max(originalReceiverCount, 1)
                if r.destId then
                    transfer(suppliers, { r.destId }, share)
                elseif r.leak then
                    leaking[wireId] = true
                end
                pumped[wireId] = r.direction
            end

            for _, ejector in ipairs(pump.ejectors) do
                local drawn, drawnSet = suppliersIn(ejector.draws)
                local served, leakServed = receiversIn(ejector.serves, drawnSet)
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
                    markLeaking(leakServed, ejector.discharge, pump.psi)
                end
            end
        end
    end
    return pumped, changed, leaking
end

-- Advances everything by dt seconds, writing store.fillPercent (nil reads as
-- full), w.fluidPercent (nil reads as full), w.fluidMoving (whether fluid is
-- running through that pipe right now), w.pumpedDirection (which way a pump
-- is driving it, "forward"/"reverse", else nil), and w.leaking (true while
-- fluid is moving through that pipe AND its downstream end is an open pipe
-- end rather than a sink or tank -- see the header comment -- purely a cue
-- for the GUI layer's own leak-spray animation; the model has already
-- treated that fluid as gone the moment it's marked fed). stores: {nodeId -> entity with
-- tankMaxCapacity}; a store with no capacity can't be worked out as a percent,
-- so it neither loses fluid nor runs dry. pipeUnits: {wireId -> length in grid
-- units}. A pipe stays full while what feeds it has fluid, then empties at the
-- same flow rate from its upstream end -- or, for a gravity-marked pipe no
-- active source's chain ever structurally reaches at all (an uphill run with
-- no pump behind it to make up the difference -- see the loop below), reads
-- empty outright from the start rather than defaulting to full. Returns
-- whether anything changed, and {sourceId -> true} for each source with
-- fluid still leaving through its pipes.
local function step(flow, stores, pipeUnits, dt)
    local changed = false
    local fedAnywhere = {}
    for id, fed in pairs(flow.feeding) do
        for wireId in pairs(fed) do fedAnywhere[wireId] = true end
        local store, capacity, gallons = _storeState(stores, id)
        if store and gallons > 0 then
            local amount = math.min(DRAIN_RATE * dt, gallons)
            local receivers = flow.receivingStores[id]
            if receivers then
                -- Split evenly, capped by the fullest receiver's own room, so
                -- what leaves this store always equals what arrives in them.
                local ids = {}
                for receiverId in pairs(receivers) do table.insert(ids, receiverId) end
                for _, receiverId in ipairs(ids) do
                    local _, receiverCapacity, receiverGallons = _storeState(stores, receiverId)
                    amount = math.min(amount, (receiverCapacity - receiverGallons) * #ids)
                end
                for _, receiverId in ipairs(ids) do
                    local receiverStore, receiverCapacity, receiverGallons = _storeState(stores, receiverId)
                    receiverStore.fillPercent = math.min(100, (receiverGallons + amount / #ids) / receiverCapacity * 100)
                    changed = true
                end
            end
            store.fillPercent = math.max(0, (gallons - amount) / capacity * 100)
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
        elseif not fedAnywhere[w.id] and w.fluidPercent == nil then
            -- Marked uphill/downhill but never actually fed: no active
            -- source's gravity chain reaches it at all (not even
            -- structurally -- see leakNodes/leakingWires above, a
            -- different case: THAT one's still reached, just with nowhere
            -- to go). Without a pump behind it either (the next block below
            -- would otherwise force this back to full), gravity alone could
            -- never have put fluid in here, so it reads empty outright
            -- rather than the optimistic default "nil reads as full" --
            -- which would otherwise paint this pipe as if it were standing
            -- full of fluid no real, reachable source actually supplied.
            w.fluidPercent = 0
            changed = true
        end
    end

    local pumped, pumpChanged, pumpLeaking = _stepPumps(flow, stores, dt)
    changed = changed or pumpChanged

    for _, w in ipairs(flow.wires) do
        -- A gravity-kind reversal (see computeFlow's own preview/
        -- _resolveContention) never touches `pumped` -- only _stepPumps
        -- does -- so it's read back from flow.reversed directly here. A
        -- pump-kind reversal already set pumped[w.id] itself, same as any
        -- other pump-driven wire, so this is a no-op for that case.
        w.pumpedDirection = pumped[w.id] or (flow.reversed[w.id] and flow.reversed[w.id].direction)
        -- A pipe a pump is pushing through is full, whatever gravity left in it.
        if pumped[w.id] and w.fluidPercent then
            w.fluidPercent = nil
            changed = true
        end
        w.fluidMoving = (pumped[w.id] ~= nil) or (fedAnywhere[w.id] and (w.fluidPercent or 100) > 0) or false
        w.leaking = w.fluidMoving and (pumpLeaking[w.id] or flow.leakingWires[w.id] or false) or false
        -- The real driving PSI behind this leak, for the GUI's own
        -- leak-spray animation to scale its intensity by -- pumpLeaking
        -- now carries a real number (see markLeaking above) when a pump
        -- drives it; anything else leaking (gravity alone) gets the flat
        -- baseline, since gravity has no PSI of its own.
        w.leakPressure = w.leaking and
            ((type(pumpLeaking[w.id]) == "number" and pumpLeaking[w.id]) or GRAVITY_LEAK_BASELINE_PSI) or nil
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
