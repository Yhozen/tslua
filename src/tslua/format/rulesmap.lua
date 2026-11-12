local format = require("tslua.format")
local ast = require("tslua.ast")
local debug = require("tslua.debug")

local Kind = ast.Kind
local ruleAction = format.ruleAction
local RulesPosition = format.RulesPosition

function format.getRules(context, rules)
    local bucket = format.getRulesMap()[format.getRuleBucketIndex(context.currentTokenSpan.kind,
        context.nextTokenSpan.kind) + 1]
    if bucket ~= nil and #bucket > 0 then
        local ruleActionMask = ruleAction.None
        for _, rule in ipairs(bucket) do
            local acceptRuleActions = ~format.getRuleActionExclusion(ruleActionMask)
            if rule:Action() & acceptRuleActions ~= 0 then
                local preds = rule:Context()
                for _, p in ipairs(preds) do
                    if not p(context) then
                        goto outer
                    end
                end
                rules = rules or {}
                rules[#rules + 1] = rule
                ruleActionMask = ruleActionMask | rule:Action()
            end
            ::outer::
        end
        return rules
    end
    return rules
end

function format.getRuleBucketIndex(row, column)
    debug.Assert(row <= Kind.LastKeyword and column <= Kind.LastKeyword, "Must compute formatting context from tokens")
    return (row * format.mapRowLength) + column
end

format.maskBitSize = 5
format.mask = 31 -- MaskBitSize bits
format.mapRowLength = Kind.LastToken + 1

--[[*
 * For a given rule action, gets a mask of other rule actions that
 * cannot be applied at the same position.
 ]]
function format.getRuleActionExclusion(action)
    local mask = ruleAction.None
    if action & ruleAction.StopProcessingSpaceActions ~= 0 then
        mask = mask | ruleAction.ModifySpaceAction
    end
    if action & ruleAction.StopProcessingTokenActions ~= 0 then
        mask = mask | ruleAction.ModifyTokenAction
    end
    if action & ruleAction.ModifySpaceAction ~= 0 then
        mask = mask | ruleAction.ModifySpaceAction
    end
    if action & ruleAction.ModifyTokenAction ~= 0 then
        mask = mask | ruleAction.ModifyTokenAction
    end
    return mask
end

-- sync.OnceValue(buildRulesMap)
function format.getRulesMap()
    if format.rulesMap_ == nil then
        format.rulesMap_ = format.buildRulesMap()
    end
    return format.rulesMap_
end

-- Returns a 1-based Lua array of buckets indexed by bucket index + 1; a nil Go bucket is nil.
function format.buildRulesMap()
    local rules = format.getAllRules()
    -- Map from bucket index to array of rules
    local m = {}
    -- This array is used only during construction of the rulesbucket in the map
    local rulesBucketConstructionStateList = {}
    for _, rule in ipairs(rules) do
        local specificRule = rule.leftTokenRange.isSpecific and rule.rightTokenRange.isSpecific

        for _, left in ipairs(rule.leftTokenRange.tokens) do
            for _, right in ipairs(rule.rightTokenRange.tokens) do
                local index = format.getRuleBucketIndex(left, right)
                m[index + 1] = format.addRule(m[index + 1], rule.rule, specificRule, rulesBucketConstructionStateList,
                    index)
            end
        end
    end
    return m
end

-- The Rules list contains all the inserted rules into a rulebucket in the following order:
--
--	1- Ignore rules with specific token combination
--	2- Ignore rules with any token combination
--	3- Context rules with specific token combination
--	4- Context rules with any token combination
--	5- Non-context rules with specific token combination
--	6- Non-context rules with any token combination
--
-- The member rulesInsertionIndexBitmap is used to describe the number of rules
-- in each sub-bucket (above) hence can be used to know the index of where to insert
-- the next rule. It's a bitmap which contains 6 different sections each is given 5 bits.
--
-- Example:
-- In order to insert a rule to the end of sub-bucket (3), we get the index by adding
-- the values in the bitmap segments 3rd, 2nd, and 1st.
function format.addRule(rules, rule, specificTokens, constructionState, rulesBucketIndex)
    local position
    if rule:Action() & ruleAction.StopAction ~= 0 then
        if specificTokens then
            position = RulesPosition.StopRulesSpecific
        else
            position = RulesPosition.StopRulesAny
        end
    elseif #rule:Context() ~= 0 then
        if specificTokens then
            position = RulesPosition.ContextRulesSpecific
        else
            position = RulesPosition.ContextRulesAny
        end
    else
        if specificTokens then
            position = RulesPosition.NoContextRulesSpecific
        else
            position = RulesPosition.NoContextRulesAny
        end
    end

    local state = constructionState[rulesBucketIndex + 1] or 0

    rules = rules or {}
    table.insert(rules, format.getRuleInsertionIndex(state, position) + 1, rule)
    constructionState[rulesBucketIndex + 1] = format.increaseInsertionIndex(state, position)
    return rules
end

function format.getRuleInsertionIndex(indexBitmap, maskPosition)
    local index = 0
    local pos = 0
    while pos <= maskPosition do
        index = index + (indexBitmap & format.mask)
        indexBitmap = indexBitmap >> format.maskBitSize
        pos = pos + format.maskBitSize
    end
    return index
end

function format.increaseInsertionIndex(indexBitmap, maskPosition)
    local value = ((indexBitmap >> maskPosition) & format.mask) + 1
    debug.Assert((value & format.mask) == value,
        "Adding more rules into the sub-bucket than allowed. Maximum allowed is 32 rules.")
    return (indexBitmap & ~(format.mask << maskPosition)) | (value << maskPosition)
end
