-- model/graph.lua
--
-- Pure-Lua, love.*-free graph model shared by solver.lua/learner.lua/
-- suggest.lua (see the inference-schematic-assistance plan). Takes plain
-- data the app layer has already pulled off the live schematic canvas and
-- builds a domain-agnostic node/edge graph: elements and controls become
-- nodes, wires become edges. Nothing here knows about love2d, globApp, or
-- canvas tables -- the main.lua adapter owns that translation.
--
-- Node roles (an app-supplied componentType string, opaque to the GUI
-- library -- see schematic_gdsGuiLib.lua's addElement/addControl):
--   "source"          -- generator, battery: can be switched on/off
--   "path"             -- bus, wire run: just carries whatever reaches it
--   "gate"             -- switch, breaker, contactor: blocks propagation
--                         past itself (both directions) unless closed
--   "directionalGate"  -- diode, check valve: edges touching it only
--                         conduct ONE way -- see _resolveDirectionalEdges
--                         below for how that way is decided
--   "sink"             -- load/consumer: terminal, no special behavior
-- A node with no componentType tag (nil) is excluded from the graph
-- entirely, so schematics saved before this feature existed, or elements
-- the user hasn't tagged yet, simply don't participate in solving.

-- A directionalGate's own rotation (degrees) as a unit "which way does it
-- conduct" vector -- at rotation 0 a diode's artwork points +x (see
-- schematic_gdsGuiLib.lua's own _drawDiodeSymbol: triangle tip + cathode
-- bar both sit on the right), so (1,0) is the matching baseline here, with
-- the other 3 cardinal rotations following the same clockwise-in-screen-
-- space convention love.graphics.rotate uses (+90 -> +y, i.e. "down" once
-- the app layer's y axis points down same as love2d's). Looked up exactly
-- for the 4 rotations _snapRotationDegrees ever actually produces (every
-- rotatable schematic item is snapped to one of these) to avoid a stray
-- cos(90)=6.1e-17-style float residue flipping a dot product's sign below;
-- math.cos/sin is still a perfectly fine fallback for anything off-grid.
local _CARDINAL_FORWARD = { [0] = {1, 0}, [90] = {0, 1}, [180] = {-1, 0}, [270] = {0, -1} }
local function _directionalGateForwardVector(rotationDeg)
    local v = _CARDINAL_FORWARD[rotationDeg % 360]
    if v then return v[1], v[2] end
    local rad = math.rad(rotationDeg)
    return math.cos(rad), math.sin(rad)
end

-- Cosine of the angle between gateNode's own forward axis and the
-- straight line from gateNode's center to otherNode's center: 1.0 dead
-- ahead (the cathode/exit side), -1.0 dead behind (the anode/entry side),
-- 0 exactly perpendicular, nil when positions is nil, either node's entry
-- is missing, or the two centers coincide (nothing to measure an angle
-- against). Normalized by distance (not a raw dot product) so two
-- candidate neighbors at very different distances from the gate still
-- compare on ANGLE alone in _resolveDirectionalEdges below, not on which
-- one happens to sit closer.
local function _directionalCosine(gateNode, otherNode, positions)
    local gatePos, otherPos = positions and positions[gateNode.id], positions and positions[otherNode.id]
    if not gatePos or not otherPos then return nil end
    local fx, fy = _directionalGateForwardVector(gatePos.rotation or 0)
    local dx, dy = otherPos.x - gatePos.x, otherPos.y - gatePos.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1e-9 then return nil end
    return (dx * fx + dy * fy) / dist
end

-- Resolves every directionalGate-touching wire's real conducting
-- direction, keyed by its index in `wires` -- only entries that got a
-- positive geometric resolution are present; buildGraph falls back to
-- that wire's own originally-drawn fromElementId/toElementId order (the
-- ONLY rule this module had before positions existed) for every wire
-- missing from this map, so positions == nil (every hand-built test graph
-- in this file) reproduces the old behavior exactly.
--
-- A gate with EXACTLY two directional neighbors with a known cosine is
-- resolved RELATIVE TO EACH OTHER: whichever leans further toward the
-- gate's own forward axis is the exit/cathode side, the other the entry/
-- anode side -- rather than each judged independently against zero. A
-- wire that bends around a corner before reaching its far element
-- routinely leaves that element's STRAIGHT-LINE bearing from the gate
-- nowhere near the gate's own forward axis (e.g. a generator wired in
-- from dead below a diode that then jogs sideways toward its bus -- that
-- bearing is perpendicular, cosine ~0, even though the connection is
-- perfectly correctly drawn) -- there, an absolute sign-of-cosine test is
-- just measuring routing noise, not which side the neighbor is really on,
-- while comparing the gate's two actual neighbors against EACH OTHER
-- still reads correctly (whichever one leans more forward wins the exit
-- side, however close to perpendicular both actually are). Any OTHER
-- neighbor count (0, 1, or 3+, plus a both-ends-are-gates edge, excluded
-- from pairing on either side -- see buildGraph's own comment) falls back
-- to the plain "ahead if cosine > 0" sign test per wire, same as a single
-- isolated gate always had no sibling to rank against.
local function _resolveDirectionalEdges(wires, nodes, positions)
    local info = {}   -- wireIndex -> {gateNode, otherNode, cosine} or {bothGates, fromNode, toNode, fromCosine, toCosine}
    local byGate = {} -- gateNodeId -> array of wireIndex (only entries with a known cosine)
    for i, w in ipairs(wires) do
        local fromNode, toNode = nodes[w.fromElementId], nodes[w.toElementId]
        if fromNode and toNode then
            local fromIsGate, toIsGate = fromNode.role == "directionalGate", toNode.role == "directionalGate"
            if fromIsGate and toIsGate then
                -- A wire connecting two diodes directly: neither end's rotation
                -- alone decides this edge (the old behavior always deferred to
                -- whichever end happened to be fromElementId) -- both are
                -- consulted below so a direct diode-to-diode wire honors
                -- whichever diode's own orientation actually agrees with it.
                info[i] = {
                    bothGates = true, fromNode = fromNode, toNode = toNode,
                    fromCosine = _directionalCosine(fromNode, toNode, positions),
                    toCosine = _directionalCosine(toNode, fromNode, positions),
                }
            elseif fromIsGate or toIsGate then
                local gateNode = fromIsGate and fromNode or toNode
                local otherNode = (gateNode == fromNode) and toNode or fromNode
                local cosine = _directionalCosine(gateNode, otherNode, positions)
                info[i] = { gateNode = gateNode, otherNode = otherNode, cosine = cosine }
                if cosine then
                    byGate[gateNode.id] = byGate[gateNode.id] or {}
                    table.insert(byGate[gateNode.id], i)
                end
            end
        end
    end

    local resolved = {}
    for i, entry in pairs(info) do
        if entry.bothGates then
            local fromCosine, toCosine = entry.fromCosine, entry.toCosine
            local isAhead -- true: fromNode exits into toNode, false: toNode exits into fromNode
            -- fromNode facing toNode (fromCosine > 0) and toNode facing away from
            -- fromNode (toCosine < 0) agree: fromNode's cathode feeds toNode's
            -- anode. The mirror image agrees the other way. Both landing on the
            -- SAME side (both > 0: each thinks it's exiting into the other: both
            -- < 0: each thinks it's receiving from the other) is a genuine
            -- contradiction -- two diodes wired directly whose rotations disagree
            -- about which one feeds the other -- left unresolved (falls back to
            -- the wire's own draw order) rather than silently trusting either one.
            if fromCosine and fromCosine ~= 0 and toCosine and toCosine ~= 0 then
                if (fromCosine > 0) ~= (toCosine > 0) then isAhead = fromCosine > 0 end
            elseif fromCosine and fromCosine ~= 0 then
                isAhead = fromCosine > 0
            elseif toCosine and toCosine ~= 0 then
                isAhead = toCosine <= 0
            end
            if isAhead == true then
                resolved[i] = { fromId = entry.fromNode.id, toId = entry.toNode.id }
            elseif isAhead == false then
                resolved[i] = { fromId = entry.toNode.id, toId = entry.fromNode.id }
            end
        else
            local gateNode, otherNode, cosine = entry.gateNode, entry.otherNode, entry.cosine
            local isAhead
            local group = byGate[gateNode.id]
            if group and #group == 2 and cosine then
                local otherIndex = (group[1] == i) and group[2] or group[1]
                local otherCosine = info[otherIndex].cosine
                if cosine ~= otherCosine then isAhead = cosine > otherCosine end
            elseif cosine and cosine ~= 0 then
                isAhead = cosine > 0
            end
            if isAhead == true then
                resolved[i] = { fromId = gateNode.id, toId = otherNode.id }
            elseif isAhead == false then
                resolved[i] = { fromId = otherNode.id, toId = gateNode.id }
            end
        end
    end
    return resolved
end

-- positions (optional): {id -> {x, y, rotation}} for every node, in any
-- consistent unit (the main.lua adapter passes fraction-of-canvas
-- centers) -- see _resolveDirectionalEdges above, the only consumer. Omit
-- entirely (every hand-built pure-logic test here does) to get the old
-- wire-draw-order-only behavior unconditionally.
local function buildGraph(elements, controls, wires, componentTypes, positions)
    componentTypes = componentTypes or {}
    local nodes = {}
    for _, e in ipairs(elements or {}) do
        local role = componentTypes[e.id]
        if role then nodes[e.id] = { id = e.id, role = role } end
    end
    for _, c in ipairs(controls or {}) do
        local role = componentTypes[c.id]
        if role then nodes[c.id] = { id = c.id, role = role } end
    end

    -- An edge only matters to the solver once both endpoints are tagged
    -- graph nodes; a wire touching an untyped element just isn't part of
    -- the graph yet.
    wires = wires or {}
    local resolvedDirections = _resolveDirectionalEdges(wires, nodes, positions)
    local edges = {}
    for i, w in ipairs(wires) do
        local fromNode, toNode = nodes[w.fromElementId], nodes[w.toElementId]
        if fromNode and toNode then
            local directional = (fromNode.role == "directionalGate") or (toNode.role == "directionalGate")
            local r = resolvedDirections[i]
            local fromId = (r and r.fromId) or w.fromElementId
            local toId   = (r and r.toId) or w.toElementId
            table.insert(edges, { id = w.id, fromId = fromId, toId = toId, directional = directional })
        end
    end

    return { nodes = nodes, edges = edges }
end

-- True if some source node can still reach nodeId without using the edge
-- whose id is excludeGateId -- i.e. an alternate route exists that doesn't
-- depend on that one gate. Used by the learner (model/learner.lua) to tell
-- "this gate must be closed" apart from "downstream is powered some other
-- way". Edges are walked the same direction rule buildGraph assigned them.
local function hasAltPath(graph, nodeId, excludeGateId)
    local adjacency = {}
    for _, e in ipairs(graph.edges) do
        if e.id ~= excludeGateId then
            adjacency[e.fromId] = adjacency[e.fromId] or {}
            table.insert(adjacency[e.fromId], e.toId)
            if not e.directional then
                adjacency[e.toId] = adjacency[e.toId] or {}
                table.insert(adjacency[e.toId], e.fromId)
            end
        end
    end

    local visited = { [nodeId] = true }
    local queue, head = { nodeId }, 1
    while head <= #queue do
        local currentId = queue[head]; head = head + 1
        for _, nextId in ipairs(adjacency[currentId] or {}) do
            if not visited[nextId] then
                visited[nextId] = true
                local node = graph.nodes[nextId]
                if node and node.role == "source" then return true end
                table.insert(queue, nextId)
            end
        end
    end
    return false
end

return { buildGraph = buildGraph, hasAltPath = hasAltPath }
