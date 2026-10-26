-- model/suggest.lua
--
-- Pure, love.*-free "what should I paint next" heuristic (inference-
-- schematic-assistance plan, Phase 5). v1 scope only: given the controls
-- on a schematic and the set of combination signatures already captured
-- (gdsGui_schematic_buildSignature's own format -- "id1=d1,id2=d2", sorted
-- by id -- so a caller can diff this directly against canvas.snapshots'
-- keys without translation), suggest a combination that's exactly ONE
-- flipped control away from an existing capture: the minimum extra data
-- needed to isolate whether that one control's position actually matters
-- to anything, rather than guessing a whole new untested combination from
-- scratch. Picking WHICH flip would most help a specific still-unlearned
-- gate (using graph/rule information) is left for a later iteration, not
-- built now -- see the plan's own "v1 heuristic" framing.

local function _buildSignature(detents, controls)
    local parts = {}
    for _, c in ipairs(controls) do
        table.insert(parts, c.id .. "=" .. tostring(detents[c.id]))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function _splitSignature(signature)
    local parsed = {}
    for part in signature:gmatch("[^,]+") do
        local id, detentIndex = part:match("^(.-)=(%-?%d+)$")
        if id then table.insert(parsed, { id = id, detentIndex = tonumber(detentIndex) }) end
    end
    return parsed
end

-- controls: array of {id, numDetents} (numDetents >= 1), any order --
-- iteration order over controls/detents below is exactly the order given,
-- so a caller gets a deterministic suggestion for the same inputs.
-- capturedSignatures: {signatureString -> true} for every combination
-- already captured.
-- Returns {detents = {id -> detentIndex}, signature, flippedControlId} for
-- the first not-yet-captured one-flip neighbor of the first (sorted)
-- captured signature found, or nil when there are no controls, no
-- captures yet to flip from (the all-zero baseline itself is suggested
-- instead -- see below), or every one-flip neighbor of every captured
-- combination is already captured too (nothing left this heuristic can
-- suggest).
local function suggestNextSnapshot(controls, capturedSignatures)
    controls = controls or {}
    capturedSignatures = capturedSignatures or {}
    if #controls == 0 then return nil end

    local baseSignatures = {}
    for signature in pairs(capturedSignatures) do table.insert(baseSignatures, signature) end
    table.sort(baseSignatures)

    -- Nothing captured at all yet -- the all-zero combination is the
    -- natural first thing to paint, not a "flip" of anything.
    if #baseSignatures == 0 then
        local detents = {}
        for _, c in ipairs(controls) do detents[c.id] = 0 end
        return { detents = detents, signature = _buildSignature(detents, controls), flippedControlId = nil }
    end

    for _, baseSignature in ipairs(baseSignatures) do
        local baseDetents = {}
        for _, pair in ipairs(_splitSignature(baseSignature)) do baseDetents[pair.id] = pair.detentIndex end

        for _, c in ipairs(controls) do
            for d = 0, c.numDetents - 1 do
                if d ~= (baseDetents[c.id] or 0) then
                    local candidate = {}
                    for _, c2 in ipairs(controls) do candidate[c2.id] = baseDetents[c2.id] or 0 end
                    candidate[c.id] = d
                    local signature = _buildSignature(candidate, controls)
                    if not capturedSignatures[signature] then
                        return { detents = candidate, signature = signature, flippedControlId = c.id }
                    end
                end
            end
        end
    end

    return nil
end

-- v2: like suggestNextSnapshot above, but scored rather than "first one
-- wins" -- for a caller that actually knows WHICH still-unlearned gate it's
-- trying to help (main.lua's AI panel, once it has a specific low-
-- confidence factor to explain), not just "any untested neighbor at all".
-- Searches every one-flip neighbor of EVERY captured baseline (not just
-- the first baseline with one — unlike suggestNextSnapshot's own shortcut,
-- the useful flip here isn't necessarily nearest alphabetically) and keeps
-- whichever untested one scoreFn scores highest.
--
-- scoreFn(detents) -> a number (higher is better) for a candidate
-- combination, or a falsy value ("this candidate teaches nothing, skip
-- it") -- the caller decides what "useful" means (e.g. "does this
-- introduce a deduced gate state I haven't seen yet", see main.lua's own
-- scorer); this module stays domain-agnostic and never looks inside
-- detents itself.
-- Returns the same {detents, signature, flippedControlId} shape as
-- suggestNextSnapshot, or nil when there's nothing captured yet to flip
-- from, every one-flip neighbor is already captured, or scoreFn never
-- returns a truthy score for any of them (the caller falls back to plain
-- suggestNextSnapshot for that last case, same as it would for nil here).
local function suggestTargetedSnapshot(controls, capturedSignatures, scoreFn)
    controls = controls or {}
    capturedSignatures = capturedSignatures or {}
    if #controls == 0 then return nil end

    local baseSignatures = {}
    for signature in pairs(capturedSignatures) do table.insert(baseSignatures, signature) end
    table.sort(baseSignatures)
    if #baseSignatures == 0 then return nil end -- nothing learned yet to target a gap in

    local best, bestScore, bestSignature = nil, nil, nil
    for _, baseSignature in ipairs(baseSignatures) do
        local baseDetents = {}
        for _, pair in ipairs(_splitSignature(baseSignature)) do baseDetents[pair.id] = pair.detentIndex end

        for _, c in ipairs(controls) do
            for d = 0, c.numDetents - 1 do
                if d ~= (baseDetents[c.id] or 0) then
                    local candidate = {}
                    for _, c2 in ipairs(controls) do candidate[c2.id] = baseDetents[c2.id] or 0 end
                    candidate[c.id] = d
                    local signature = _buildSignature(candidate, controls)
                    if not capturedSignatures[signature] then
                        local score = scoreFn(candidate)
                        if score and (not bestScore or score > bestScore
                                or (score == bestScore and signature < bestSignature)) then
                            best, bestScore, bestSignature =
                                { detents = candidate, signature = signature, flippedControlId = c.id }, score, signature
                        end
                    end
                end
            end
        end
    end

    return best
end

return { suggestNextSnapshot = suggestNextSnapshot, suggestTargetedSnapshot = suggestTargetedSnapshot }
