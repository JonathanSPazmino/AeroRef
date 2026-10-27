-- model/learner.lua
--
-- Pure-Lua, love.*-free rule-learning layer (inference-schematic-assistance
-- plan, Phase 2). This phase only deduces a gate's actual open/closed
-- state from ONE already-captured snapshot's own observed node states --
-- not from whatever control the app thinks drives it (model/solver.lua's
-- gateStates), but from what the surrounding power graph proves the gate
-- must have been for the snapshot's painted colors to make sense. This is
-- what lets a relay -- gated by something the user never sets directly,
-- only ever revealed by the resulting colors -- eventually get a rule
-- (Phase 3) without anyone touching it.

local Graph = require("model.graph")

local UNKNOWN, OPEN, CLOSED = "unknown", "open", "closed"

-- gateId: a "gate"-role node's id in graph.
-- nodeStates: {id -> "powered"|"unpowered"} observed for ONE snapshot (see
-- the main.lua adapter's _snapshotToNodeStates) -- NOT a solver() result;
-- the whole point is to recover the gate's position FROM these, not feed
-- it one.
--
-- A gate not itself reached in this snapshot is UNKNOWN -- no evidence
-- either way. Otherwise, each neighbor other than a "source" (a source is
-- definitionally upstream and powered regardless of this gate, so it's
-- never informative) is evidence:
--   neighbor unpowered                                -> OPEN evidence
--   neighbor powered AND has no alternate route to a
--     source that avoids this gate's edge               -> CLOSED evidence
--   neighbor powered but DOES have an alternate route   -> no evidence
--     (its power can't be attributed to this gate)
-- Seeing both kinds of evidence on one gate is a contradiction (shouldn't
-- happen for a well-formed series gate) -- rather than guess, return
-- UNKNOWN, matching the "never a wrong guess" rule Phase 3's learner also
-- follows.
local function inferGate(gateId, nodeStates, graph)
    local node = graph.nodes[gateId]
    if not node or node.role ~= "gate" then return UNKNOWN end
    if nodeStates[gateId] ~= "powered" then return UNKNOWN end

    local sawOpenEvidence, sawClosedEvidence = false, false
    for _, e in ipairs(graph.edges) do
        local neighborId
        if e.fromId == gateId then neighborId = e.toId
        elseif e.toId == gateId then neighborId = e.fromId end
        local neighborNode = neighborId and graph.nodes[neighborId]
        if neighborNode and neighborNode.role ~= "source" then
            local neighborState = nodeStates[neighborId]
            if neighborState == "unpowered" then
                sawOpenEvidence = true
            elseif neighborState == "powered" then
                if not Graph.hasAltPath(graph, neighborId, e.id) then sawClosedEvidence = true end
            end
        end
    end

    if sawOpenEvidence and sawClosedEvidence then return UNKNOWN end
    if sawOpenEvidence then return OPEN end
    if sawClosedEvidence then return CLOSED end
    return UNKNOWN
end

-- Runs inferGate over every "gate"-role node in graph. Entries are never
-- omitted (a gate with no evidence still gets an explicit "unknown" entry,
-- not a missing key) so a caller counting examples-per-gate can tell "no
-- evidence yet" apart from "haven't looked at this gate at all".
local function deduceAllGates(graph, nodeStates)
    local result = {}
    for id, node in pairs(graph.nodes) do
        if node.role == "gate" then
            result[id] = inferGate(id, nodeStates, graph)
        end
    end
    return result
end

-- Phase 3: given 2+ deduced examples for ONE gate (each {nodeStates, result}
-- -- result is inferGate's own "open"/"closed" output for some snapshot,
-- nodeStates is that SAME snapshot's full _snapshotToNodeStates map, used
-- here as the pool of candidate explanatory conditions), searches
-- candidateConditionIds (every other graph node id, typically sense-linked
-- ones ordered first by the caller per the plan's R4) for the simplest set
-- of conditions whose exact states always predict the gate's result.
--
-- A condition set only counts if EVERY example has a known state for every
-- condition in it ("consistent with every example" taken literally) and
-- that mapping from condition-states to result is a true function (no
-- state combination maps to two different results) -- a condition set that
-- contradicts even one example is never a near-miss, it's just wrong, and
-- is skipped exactly like a condition set with no coverage at all.
--
-- Checked single-condition sets first, then pairs (triple+ is a
-- deliberately deferred v2 scope per the plan) -- the FIRST one found
-- "wins", so candidate order controls which equally-valid explanation gets
-- picked when more than one fits.
-- Shared key format for "this set of conditions, in this exact set of
-- states" -- used both to build a rule's mapping below (keyed off each
-- training example's own nodeStates) and, at apply time, to look a rule's
-- mapping up against whatever combination is live now (main.lua's
-- _colorForPoweredNode, via findAttributionRule's own rule.mapping). nil
-- if any conditionId's state is missing from nodeStates (not applicable --
-- the caller can't evaluate this condition set at all).
local function buildConditionKey(conditionIds, nodeStates)
    local keyParts = {}
    for i, conditionId in ipairs(conditionIds) do
        local state = nodeStates[conditionId]
        if state == nil then return nil end
        keyParts[i] = state
    end
    return table.concat(keyParts, "|"), keyParts
end

local function _tryConditionSet(conditionIds, examples)
    local mapping = {}
    for _, ex in ipairs(examples) do
        local key, keyParts = buildConditionKey(conditionIds, ex.nodeStates)
        if not key then return nil end -- not covered by every example
        local entry = mapping[key]
        if not entry then
            mapping[key] = { states = keyParts, result = ex.result }
        elseif entry.result ~= ex.result then
            return nil -- contradiction: same condition states, different results
        end
    end
    return mapping
end

-- Picks the lexicographically-smallest mapping entry whose result is
-- CLOSED. Since inferGate's examples are only ever "open"/"closed" (a
-- binary vocabulary), a single "closed when conditions are exactly these
-- states" clause fully determines the complementary "open otherwise" case
-- too -- so one clause is enough to describe the whole rule, no
-- disjunction needed for v1 (deliberately deferred, see the plan).
local function _buildLearnedRule(conditionIds, mapping, exampleCount)
    local bestKey, bestEntry
    for key, entry in pairs(mapping) do
        if entry.result == CLOSED and (not bestKey or key < bestKey) then
            bestKey, bestEntry = key, entry
        end
    end
    if not bestEntry then return nil end
    local conditionStates = {}
    for i, conditionId in ipairs(conditionIds) do conditionStates[conditionId] = bestEntry.states[i] end
    return {
        status = "learned",
        conditionIds = conditionIds,
        conditionStates = conditionStates,
        resultState = CLOSED,
        confidence = exampleCount,
        exampleCount = exampleCount,
    }
end

-- examples: array of {nodeStates = {id -> state}, result = "open"|"closed"}
-- -- one entry per already-deduced snapshot for this one gate (see the
-- main.lua adapter's _recomputeGateRules). candidateConditionIds: ordered
-- array of other graph node ids to try as the explanation (gateId itself
-- excluded by the caller -- a gate can't be its own condition).
-- Returns a learned rule (see _buildLearnedRule above), or
-- {status = "noRule", reason, exampleCount} -- reason is one of:
--   "insufficient_examples" -- fewer than 2 examples at all.
--   "no_variation"          -- 2+ examples, but every one agrees already
--                              (nothing to explain yet).
--   "no_consistent_explanation" -- real variation exists, but no single/
--                              pair condition set explains it (existing
--                              evidence contradicts itself under every
--                              candidate tried).
-- exampleCount is always included (even for a learned rule, redundantly
-- with .confidence) so a caller can report "N example(s) so far" without
-- re-counting. Never a guessed rule.
local function findSimplestRule(gateId, examples, candidateConditionIds)
    examples = examples or {}
    candidateConditionIds = candidateConditionIds or {}
    if #examples < 2 then
        return { status = "noRule", reason = "insufficient_examples", exampleCount = #examples }
    end

    local sawOpen, sawClosed = false, false
    for _, ex in ipairs(examples) do
        if ex.result == OPEN then sawOpen = true end
        if ex.result == CLOSED then sawClosed = true end
    end
    -- Every example agreeing so far means there's no variation yet to
    -- explain -- any condition would "fit" purely by coincidence.
    if not (sawOpen and sawClosed) then
        return { status = "noRule", reason = "no_variation", exampleCount = #examples }
    end

    for _, conditionId in ipairs(candidateConditionIds) do
        local mapping = _tryConditionSet({ conditionId }, examples)
        if mapping then
            local rule = _buildLearnedRule({ conditionId }, mapping, #examples)
            if rule then return rule end
        end
    end

    for i = 1, #candidateConditionIds do
        for j = i + 1, #candidateConditionIds do
            local pair = { candidateConditionIds[i], candidateConditionIds[j] }
            local mapping = _tryConditionSet(pair, examples)
            if mapping then
                local rule = _buildLearnedRule(pair, mapping, #examples)
                if rule then return rule end
            end
        end
    end

    return { status = "noRule", reason = "no_consistent_explanation", exampleCount = #examples }
end

-- Attribution rules: like findSimplestRule above, but for choosing WHICH
-- of two or more sources reaching an ambiguous node (one with no single
-- unambiguous explanation -- see model/solver.lua's solveSourceAttribution)
-- actually accounts for it, not for a gate's own open/closed position.
-- The result vocabulary here isn't binary the way open/closed is -- an
-- ambiguous node can have more than two contending sources -- so unlike
-- findSimplestRule's single "closed" clause with open left as the
-- implicit complement, this stores the FULL condition-state -> winner
-- mapping explicitly: a combination whose condition states were never
-- seen in training simply isn't covered by the rule at all, and the
-- caller falls back to its own default (main.lua's _colorForPoweredNode
-- falls back to its existing highest-voltage heuristic). Reuses
-- _tryConditionSet as-is -- it already builds a condition-state -> result
-- mapping generically, with no open/closed assumption baked in; only the
-- final reduction step (_buildLearnedRule's "pick the CLOSED entry")
-- needed a sibling instead of a shared function.
--
-- examples: array of {nodeStates = {id -> state}, result = sourceId} --
-- one entry per already-captured snapshot where this node was ambiguous
-- AND its painted color exactly matched one contributing source's
-- registered color (see main.lua's _deduceAttributionWinnersForSnapshot).
-- candidateConditionIds: same ordered-id-pool convention as
-- findSimplestRule (the ambiguous node's own id excluded by the caller).
-- Returns {status="learned", conditionIds, mapping={conditionStateKey ->
-- sourceId}, confidence=exampleCount, exampleCount}, or {status="noRule",
-- reason, exampleCount} -- reason is the same vocabulary findSimplestRule
-- uses ("insufficient_examples" | "no_variation" | "no_consistent_
-- explanation", see that function's own comment) — never a guessed rule.
local function findAttributionRule(examples, candidateConditionIds)
    examples = examples or {}
    candidateConditionIds = candidateConditionIds or {}
    if #examples < 2 then
        return { status = "noRule", reason = "insufficient_examples", exampleCount = #examples }
    end

    local winnersSeen, distinctWinners = {}, 0
    for _, ex in ipairs(examples) do
        if not winnersSeen[ex.result] then
            winnersSeen[ex.result] = true
            distinctWinners = distinctWinners + 1
        end
    end
    -- Every example agreeing on the same winner already means there's no
    -- variation yet to explain -- any condition would "fit" purely by
    -- coincidence, same reasoning findSimplestRule's own sawOpen/sawClosed
    -- check uses.
    if distinctWinners < 2 then
        return { status = "noRule", reason = "no_variation", exampleCount = #examples }
    end

    local function _tryConditions(conditionIds)
        local mapping = _tryConditionSet(conditionIds, examples)
        if not mapping then return nil end
        local conditionStateMap = {}
        for key, entry in pairs(mapping) do conditionStateMap[key] = entry.result end
        return { status = "learned", conditionIds = conditionIds, mapping = conditionStateMap,
            confidence = #examples, exampleCount = #examples }
    end

    for _, conditionId in ipairs(candidateConditionIds) do
        local rule = _tryConditions({ conditionId })
        if rule then return rule end
    end

    for i = 1, #candidateConditionIds do
        for j = i + 1, #candidateConditionIds do
            local rule = _tryConditions({ candidateConditionIds[i], candidateConditionIds[j] })
            if rule then return rule end
        end
    end

    return { status = "noRule", reason = "no_consistent_explanation", exampleCount = #examples }
end

-- Generalizes findAttributionRule's winner-picking ACROSS every ambiguous
-- node in the system at once, rather than teaching one specific node id in
-- isolation. findAttributionRule's per-node rule only ever answers "what
-- wins at THIS node" — a freshly-added battery elsewhere on the same bus
-- starts from zero confidence even after a structurally identical backfeed
-- has already been captured and confirmed at some OTHER node. This instead
-- tests a single, system-wide hypothesis: does "the single highest-voltage
-- contributor wins" (the unverified fallback _colorForPoweredNode already
-- applies by default) actually hold, anywhere, ever, in this particular
-- system?
--
-- examples: an array of plain booleans, one per CAPTURED SNAPSHOT that
-- resolved at least one ambiguous node's winner against a well-defined
-- single highest-voltage contributor (same "painted color uniquely
-- matches one contributor's registered voltage color" discipline
-- findAttributionRule's own caller applies, AND exactly one contributor
-- strictly the highest-voltage one — the caller's job, same condition
-- _isGenuinelyColorAmbiguous checks) — true if every such node in that
-- snapshot agreed the highest-voltage contributor won, false if even one
-- disagreed, i.e. proof the heuristic does NOT hold uniformly on this
-- system (e.g. an isolating diode/relay the model doesn't otherwise
-- know about). One boolean per SNAPSHOT, not per node: a single capture
-- routinely resolves several ambiguous nodes at once (a bus, the battery
-- it backfeeds, the switch between them...) that are really the same one
-- real-world event, not independent trials — the caller (main.lua's
-- _recomputeAttributionRules) collapses them before calling this.
--
-- Unlike findAttributionRule, there's no condition set to search for: the
-- "condition" is just the ambiguity itself, already guaranteed by the
-- caller to have exactly one well-defined highest-voltage pick, so this is
-- really a single yes/no hypothesis test, not a multi-candidate search —
-- one confirming instance is real (if generic) evidence FOR it, unlike a
-- per-node rule's own >=2-examples floor (there, 2+ is needed only because
-- a single example can't distinguish WHICH of many candidate conditions
-- actually explains it; here there's only ever the one hypothesis being
-- tested at all). A single contradiction anywhere is still fatal and
-- permanent, though — same "never a wrong guess" discipline as every other
-- rule here, just with no fallback condition set left to retry once the
-- one and only explanation is disproved.
--
-- confidence here is kept only for shape-parity with findSimplestRule/
-- findAttributionRule's own {confidence, exampleCount} pair (both equal
-- #examples) — the caller (_aiColorAttributionConfidence) does NOT scale
-- it against the fixed _AI_CONFIDENT_EXAMPLE_COUNT the way a per-node
-- rule's confidence is; it instead divides exampleCount by the actual
-- count of every OTHER combination that could have tested this same
-- global hypothesis (canvas.voltageDominanceRule.teachableTotal, a
-- separate field the caller attaches after calling this), since a single
-- universal constant can't mean the same thing across wildly different
-- circuit sizes the way a real "fraction of all possible tests" can.
local function findVoltageDominanceRule(examples)
    examples = examples or {}
    if #examples == 0 then
        return { status = "noRule", reason = "insufficient_examples", exampleCount = 0 }
    end
    for _, confirmed in ipairs(examples) do
        if not confirmed then
            return { status = "noRule", reason = "no_consistent_explanation", exampleCount = #examples }
        end
    end
    return { status = "learned", confidence = #examples, exampleCount = #examples }
end

return {
    inferGate = inferGate, deduceAllGates = deduceAllGates, findSimplestRule = findSimplestRule,
    findAttributionRule = findAttributionRule, findVoltageDominanceRule = findVoltageDominanceRule,
    buildConditionKey = buildConditionKey,
    OPEN = OPEN, CLOSED = CLOSED, UNKNOWN = UNKNOWN,
}
