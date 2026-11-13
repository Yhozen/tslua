local syntax = require("tslua.regexp.syntax")

local Op = syntax.Op
local Flags = syntax.Flags
local Regexp = syntax.Regexp

-- Simplify returns a regexp equivalent to re but without counted repetitions
-- and with various other simplifications, such as rewriting /(?:a+)+/ to /a+/.
-- The resulting regexp will execute correctly but its string representation
-- will not produce the same parse tree, because capturing parentheses
-- may have been duplicated or removed. For example, the simplified form
-- for /(x){1,2}/ is /(x)(x)?/ but both parentheses capture as $1.
-- The returned regexp may share structure with or be the original.
function Regexp:Simplify()
    local re = self
    if re == nil then
        return nil
    end
    local op = re.op
    if op == Op.Capture or op == Op.Concat or op == Op.Alternate then
        -- Simplify children, building new Regexp if children change.
        local nre = re
        for i1, sub in ipairs(re.sub) do
            local i = i1 - 1
            local nsub = sub:Simplify()
            if nre == re and nsub ~= sub then
                -- Start a copy.
                nre = setmetatable({}, Regexp)
                for k, v in pairs(re) do
                    nre[k] = v
                end
                nre.rune = nil
                nre.sub = {}
                for j = 1, i do
                    nre.sub[j] = re.sub[j]
                end
            end
            if nre ~= re then
                nre.sub[#nre.sub + 1] = nsub
            end
        end
        return nre
    elseif op == Op.Star or op == Op.Plus or op == Op.Quest then
        local sub = re.sub[1]:Simplify()
        return syntax.simplify1(re.op, re.flags, sub, re)
    elseif op == Op.Repeat then
        -- Special special case: x{0} matches the empty string
        -- and doesn't even need to consider x.
        if re.min == 0 and re.max == 0 then
            return syntax.newRegexpValue(Op.EmptyMatch, 0)
        end

        -- The fun begins.
        local sub = re.sub[1]:Simplify()

        -- x{n,} means at least n matches of x.
        if re.max == -1 then
            -- Special case: x{0,} is x*.
            if re.min == 0 then
                return syntax.simplify1(Op.Star, re.flags, sub, nil)
            end

            -- Special case: x{1,} is x+.
            if re.min == 1 then
                return syntax.simplify1(Op.Plus, re.flags, sub, nil)
            end

            -- General case: x{4,} is xxxx+.
            local nre = syntax.newRegexpValue(Op.Concat, 0)
            nre.sub = {}
            for _ = 0, re.min - 2 do
                nre.sub[#nre.sub + 1] = sub
            end
            nre.sub[#nre.sub + 1] = syntax.simplify1(Op.Plus, re.flags, sub, nil)
            return nre
        end

        -- Special case x{0} handled above.

        -- Special case: x{1} is just x.
        if re.min == 1 and re.max == 1 then
            return sub
        end

        -- General case: x{n,m} means n copies of x and m copies of x?
        -- The machine will do less work if we nest the final m copies,
        -- so that x{2,5} = xx(x(x(x)?)?)?

        -- Build leading prefix: xx.
        local prefix
        if re.min > 0 then
            prefix = syntax.newRegexpValue(Op.Concat, 0)
            prefix.sub = {}
            for _ = 0, re.min - 1 do
                prefix.sub[#prefix.sub + 1] = sub
            end
        end

        -- Build and attach suffix: (x(x(x)?)?)?
        if re.max > re.min then
            local suffix = syntax.simplify1(Op.Quest, re.flags, sub, nil)
            for _ = re.min + 1, re.max - 1 do
                local nre2 = syntax.newRegexpValue(Op.Concat, 0)
                nre2.sub = { sub, suffix }
                suffix = syntax.simplify1(Op.Quest, re.flags, nre2, nil)
            end
            if prefix == nil then
                return suffix
            end
            prefix.sub[#prefix.sub + 1] = suffix
        end
        if prefix ~= nil then
            return prefix
        end

        -- Some degenerate case like min > max or min < max < 0.
        -- Handle as impossible match.
        return syntax.newRegexpValue(Op.NoMatch, 0)
    end

    return re
end

-- simplify1 implements Simplify for the unary OpStar,
-- OpPlus, and OpQuest operators. It returns the simple regexp
-- equivalent to
--
--	Regexp{Op: op, Flags: flags, Sub: {sub}}
--
-- under the assumption that sub is already simple, and
-- without first allocating that structure. If the regexp
-- to be returned turns out to be equivalent to re, simplify1
-- returns re instead.
--
-- simplify1 is factored out of Simplify because the implementation
-- for other operators generates these unary expressions.
-- Letting them call simplify1 makes sure the expressions they
-- generate are simple.
function syntax.simplify1(op, flags, sub, re)
    -- Special case: repeat the empty string as much as
    -- you want, but it's going to match only once.
    if sub.op == Op.EmptyMatch then
        return sub
    end
    -- The operators are idempotent if the flags match.
    if op == sub.op and flags & Flags.NonGreedy == sub.flags & Flags.NonGreedy then
        return sub
    end
    if re ~= nil and re.op == op and re.flags & Flags.NonGreedy == flags & Flags.NonGreedy and sub == re.sub[1] then
        return re
    end

    re = syntax.newRegexpValue(op, flags)
    re.sub = { sub }
    return re
end
