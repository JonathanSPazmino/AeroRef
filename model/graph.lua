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
--                         conduct in the direction they were drawn
--   "sink"             -- load/consumer: terminal, no special behavior
-- A node with no componentType tag (nil) is excluded from the graph
-- entirely, so schematics saved before this feature existed, or elements
-- the user hasn't tagged yet, simply don't participate in solving.

local function buildGraph(elements, controls, wires, componentTypes)
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
    -- the graph yet. Direction (for an edge touching a directionalGate
    -- node) is the wire's own drawn fromElementId -> toElementId order --
    -- a placement convention, not a separate stored field (see the plan's
    -- "diode polarity" open question).
    local edges = {}
    for _, w in ipairs(wires or {}) do
        local fromNode, toNode = nodes[w.fromElementId], nodes[w.toElementId]
        if fromNode and toNode then
            local directional = (fromNode.role == "directionalGate") or (toNode.role == "directionalGate")
            table.insert(edges, { id = w.id, fromId = w.fromElementId, toId = w.toElementId, directional = directional })
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
