local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")
local utf8 = require("tslua.regexp.utf8")

local Op = syntax.Op
local Flags = syntax.Flags
local ErrorCode = syntax.ErrorCode

local sbyte, ssub = string.byte, string.sub

local function len(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

-- Go xs[a:b] for a Lua array (0-based, half-open; returns a new array).
local function slice(xs, a, b)
    local out = {}
    for i = a + 1, b do
        out[#out + 1] = xs[i]
    end
    return out
end

-- Truncate the array xs to n elements in place.
local function truncate(xs, n)
    for i = #xs, n + 1, -1 do
        xs[i] = nil
    end
end

-- An Error describes a failure to parse a regular expression
-- and gives the offending expression.
local Error = {}
Error.__index = Error
syntax.Error = Error

function syntax.newError(code, expr)
    return setmetatable({ code = code, expr = expr }, Error)
end

function Error:Error()
    return "error parsing regexp: " .. syntax.ErrorCode_String(self.code) .. ": `" .. self.expr .. "`"
end

Error.__tostring = Error.Error

function syntax.ErrorCode_String(e)
    return e
end

-- Pseudo-ops for parsing stack.
syntax.opLeftParen = syntax.opPseudo + 0
syntax.opVerticalBar = syntax.opPseudo + 1

-- maxHeight is the maximum height of a regexp parse tree.
-- It is somewhat arbitrarily chosen, but the idea is to be large enough
-- that no one will actually hit in real use but at the same time small enough
-- that recursion on the Regexp tree will not hit the 1GB Go stack limit.
-- As an optimization, we don't even bother calculating heights
-- until we've allocated at least maxHeight Regexp structures.
syntax.maxHeight = 1000

-- maxSize is the maximum size of a compiled regexp in Insts.
syntax.instSize = 5 * 8 -- byte, 2 uint32, slice is 5 64-bit words
syntax.maxSize = (128 << 20) // syntax.instSize

-- maxRunes is the maximum number of runes allowed in a regexp tree
-- counting the runes in all the nodes.
syntax.runeSize = 4 -- rune is int32
syntax.maxRunes = (128 << 20) // syntax.runeSize

local parser = {}
parser.__index = parser
syntax.parser = parser

function syntax.newParser()
    return setmetatable({
        flags = 0, -- parse mode flags
        stack = {}, -- stack of parsed expressions
        free = nil,
        numCap = 0, -- number of capturing groups seen
        wholeRegexp = "",
        tmpClass = nil, -- temporary char class work space
        numRegexp = 0, -- number of regexps allocated
        numRunes = 0, -- number of runes in char classes
        repeats = 0, -- product of all repetitions seen
        height = nil, -- regexp height, for height limit check
        size = nil, -- regexp compiled size, for size limit check
    }, parser)
end

function parser:newRegexp(op)
    local re = self.free
    if re ~= nil then
        self.free = re.sub0
        -- *re = Regexp{}
        for k in pairs(re) do
            re[k] = nil
        end
        re.op = 0
        re.flags = 0
        re.min = 0
        re.max = 0
        re.cap = 0
        re.name = ""
    else
        re = syntax.newRegexpValue(0, 0)
        self.numRegexp = self.numRegexp + 1
    end
    re.op = op
    return re
end

function parser:reuse(re)
    if self.height ~= nil then
        self.height[re] = nil
    end
    re.sub0 = self.free
    self.free = re
end

function parser:checkLimits(re)
    if self.numRunes > syntax.maxRunes then
        error(ErrorCode.ErrLarge, 0)
    end
    self:checkSize(re)
    self:checkHeight(re)
end

function parser:checkSize(re)
    if self.size == nil then
        -- We haven't started tracking size yet.
        -- Do a relatively cheap check to see if we need to start.
        -- Maintain the product of all the repeats we've seen
        -- and don't track if the total number of regexp nodes
        -- we've seen times the repeat product is in budget.
        if self.repeats == 0 then
            self.repeats = 1
        end
        if re.op == Op.Repeat then
            local n = re.max
            if n == -1 then
                n = re.min
            end
            if n <= 0 then
                n = 1
            end
            if n > syntax.maxSize // self.repeats then
                self.repeats = syntax.maxSize
            else
                self.repeats = self.repeats * n
            end
        end
        if self.numRegexp < syntax.maxSize // self.repeats then
            return
        end

        -- We need to start tracking size.
        -- Make the map and belatedly populate it
        -- with info about everything we've constructed so far.
        self.size = {}
        for _, sre in ipairs(self.stack) do
            self:checkSize(sre)
        end
    end

    if self:calcSize(re, true) > syntax.maxSize then
        error(ErrorCode.ErrLarge, 0)
    end
end

function parser:calcSize(re, force)
    if not force then
        local size = self.size[re]
        if size ~= nil then
            return size
        end
    end

    local size = 0
    local op = re.op
    if op == Op.Literal then
        size = len(re.rune)
    elseif op == Op.Capture or op == Op.Star then
        -- star can be 1+ or 2+; assume 2 pessimistically
        size = 2 + self:calcSize(re.sub[1], false)
    elseif op == Op.Plus or op == Op.Quest then
        size = 1 + self:calcSize(re.sub[1], false)
    elseif op == Op.Concat then
        for _, sub in ipairs(re.sub) do
            size = size + self:calcSize(sub, false)
        end
    elseif op == Op.Alternate then
        for _, sub in ipairs(re.sub) do
            size = size + self:calcSize(sub, false)
        end
        if #re.sub > 1 then
            size = size + #re.sub - 1
        end
    elseif op == Op.Repeat then
        local sub = self:calcSize(re.sub[1], false)
        if re.max == -1 then
            if re.min == 0 then
                size = 2 + sub -- x*
            else
                size = 1 + re.min * sub -- xxx+
            end
        else
            -- x{2,5} = xx(x(x(x)?)?)?
            size = re.max * sub + (re.max - re.min)
        end
    end

    size = math.max(1, size)
    self.size[re] = size
    return size
end

function parser:checkHeight(re)
    if self.numRegexp < syntax.maxHeight then
        return
    end
    if self.height == nil then
        self.height = {}
        for _, sre in ipairs(self.stack) do
            self:checkHeight(sre)
        end
    end
    if self:calcHeight(re, true) > syntax.maxHeight then
        error(ErrorCode.ErrNestingDepth, 0)
    end
end

function parser:calcHeight(re, force)
    if not force then
        local h = self.height[re]
        if h ~= nil then
            return h
        end
    end
    local h = 1
    for _, sub in ipairs(re.sub or {}) do
        local hsub = self:calcHeight(sub, false)
        if h < 1 + hsub then
            h = 1 + hsub
        end
    end
    self.height[re] = h
    return h
end

-- Parse stack manipulation.

-- push pushes the regexp re onto the parse stack and returns the regexp.
function parser:push(re)
    self.numRunes = self.numRunes + len(re.rune)
    local rs = re.rune
    if re.op == Op.CharClass and len(rs) == 2 and rs[1] == rs[2] then
        -- Single rune.
        if self:maybeConcat(rs[1], self.flags & ~Flags.FoldCase) then
            return nil
        end
        re.op = Op.Literal
        re.rune = { rs[1] }
        re.flags = self.flags & ~Flags.FoldCase
    elseif re.op == Op.CharClass and len(rs) == 4 and
        rs[1] == rs[2] and rs[3] == rs[4] and
        unicode.SimpleFold(rs[1]) == rs[3] and
        unicode.SimpleFold(rs[3]) == rs[1] or
        re.op == Op.CharClass and len(rs) == 2 and
        rs[1] + 1 == rs[2] and
        unicode.SimpleFold(rs[1]) == rs[2] and
        unicode.SimpleFold(rs[2]) == rs[1] then
        -- Case-insensitive rune like [Aa] or [Δδ].
        if self:maybeConcat(rs[1], self.flags | Flags.FoldCase) then
            return nil
        end

        -- Rewrite as (case-insensitive) literal.
        re.op = Op.Literal
        re.rune = { rs[1] }
        re.flags = self.flags | Flags.FoldCase
    else
        -- Incremental concatenation.
        self:maybeConcat(-1, 0)
    end

    self.stack[#self.stack + 1] = re
    self:checkLimits(re)
    return re
end

-- maybeConcat implements incremental concatenation
-- of literal runes into string nodes. The parser calls this
-- before each push, so only the top fragment of the stack
-- might need processing. Since this is called before a push,
-- the topmost literal is no longer subject to operators like *
-- (Otherwise ab* would turn into (ab)*.)
-- If r >= 0 and there's a node left over, maybeConcat uses it
-- to push r with the given flags.
-- maybeConcat reports whether r was pushed.
function parser:maybeConcat(r, flags)
    local n = #self.stack
    if n < 2 then
        return false
    end

    local re1 = self.stack[n]
    local re2 = self.stack[n - 1]
    if re1.op ~= Op.Literal or re2.op ~= Op.Literal or re1.flags & Flags.FoldCase ~= re2.flags & Flags.FoldCase then
        return false
    end

    -- Push re1 into re2.
    if re2.rune == nil then
        re2.rune = {}
    end
    for _, x in ipairs(re1.rune or {}) do
        re2.rune[#re2.rune + 1] = x
    end

    -- Reuse re1 if possible.
    if r >= 0 then
        re1.rune = { r }
        re1.flags = flags
        return true
    end

    self.stack[n] = nil
    self:reuse(re1)
    return false -- did not push r
end

-- literal pushes a literal regexp for the rune r on the stack.
function parser:literal(r)
    local re = self:newRegexp(Op.Literal)
    re.flags = self.flags
    if self.flags & Flags.FoldCase ~= 0 then
        r = syntax.minFoldRune(r)
    end
    re.rune = { r }
    self:push(re)
end

-- minFoldRune returns the minimum rune fold-equivalent to r.
function syntax.minFoldRune(r)
    if r < syntax.minFold or r > syntax.maxFold then
        return r
    end
    local m = r
    local r0 = r
    r = unicode.SimpleFold(r)
    while r ~= r0 do
        m = math.min(m, r)
        r = unicode.SimpleFold(r)
    end
    return m
end

-- op pushes a regexp with the given op onto the stack
-- and returns that regexp.
function parser:op(op)
    local re = self:newRegexp(op)
    re.flags = self.flags
    return self:push(re)
end

-- repeat replaces the top stack element with itself repeated according to op, min, max.
-- before is the regexp suffix starting at the repetition operator.
-- after is the regexp suffix following after the repetition operator.
-- repeat returns an updated 'after' and an error, if any.
function parser:repeat_(op, min, max, before, after, lastRepeat)
    local flags = self.flags
    if self.flags & Flags.PerlX ~= 0 then
        if #after > 0 and sbyte(after, 1) == 0x3F --[[ '?' ]] then
            after = ssub(after, 2)
            flags = flags ~ Flags.NonGreedy
        end
        if lastRepeat ~= "" then
            -- In Perl it is not allowed to stack repetition operators:
            -- a** is a syntax error, not a doubled star, and a++ means
            -- something else entirely, which we don't support!
            return "", syntax.newError(ErrorCode.ErrInvalidRepeatOp, ssub(lastRepeat, 1, #lastRepeat - #after))
        end
    end
    local n = #self.stack
    if n == 0 then
        return "", syntax.newError(ErrorCode.ErrMissingRepeatArgument, ssub(before, 1, #before - #after))
    end
    local sub = self.stack[n]
    if sub.op >= syntax.opPseudo then
        return "", syntax.newError(ErrorCode.ErrMissingRepeatArgument, ssub(before, 1, #before - #after))
    end

    local re = self:newRegexp(op)
    re.min = min
    re.max = max
    re.flags = flags
    re.sub = { sub }
    self.stack[n] = re
    self:checkLimits(re)

    if op == Op.Repeat and (min >= 2 or max >= 2) and not syntax.repeatIsValid(re, 1000) then
        return "", syntax.newError(ErrorCode.ErrInvalidRepeatSize, ssub(before, 1, #before - #after))
    end

    return after, nil
end

-- repeatIsValid reports whether the repetition re is valid.
-- Valid means that the combination of the top-level repetition
-- and any inner repetitions does not exceed n copies of the
-- innermost thing.
-- This function rewalks the regexp tree and is called for every repetition,
-- so we have to worry about inducing quadratic behavior in the parser.
-- We avoid this by only calling repeatIsValid when min or max >= 2.
-- In that case the depth of any >= 2 nesting can only get to 9 without
-- triggering a parse error, so each subtree can only be rewalked 9 times.
function syntax.repeatIsValid(re, n)
    if re.op == Op.Repeat then
        local m = re.max
        if m == 0 then
            return true
        end
        if m < 0 then
            m = re.min
        end
        if m > n then
            return false
        end
        if m > 0 then
            n = n // m
        end
    end
    for _, sub in ipairs(re.sub or {}) do
        if not syntax.repeatIsValid(sub, n) then
            return false
        end
    end
    return true
end

-- concat replaces the top of the stack (above the topmost '|' or '(') with its concatenation.
function parser:concat()
    self:maybeConcat(-1, 0)

    -- Scan down to find pseudo-operator | or (.
    local i = #self.stack
    while i > 0 and self.stack[i].op < syntax.opPseudo do
        i = i - 1
    end
    local subs = slice(self.stack, i, #self.stack)
    truncate(self.stack, i)

    -- Empty concatenation is special case.
    if #subs == 0 then
        return self:push(self:newRegexp(Op.EmptyMatch))
    end

    return self:push(self:collapse(subs, Op.Concat))
end

-- alternate replaces the top of the stack (above the topmost '(') with its alternation.
function parser:alternate()
    -- Scan down to find pseudo-operator (.
    -- There are no | above (.
    local i = #self.stack
    while i > 0 and self.stack[i].op < syntax.opPseudo do
        i = i - 1
    end
    local subs = slice(self.stack, i, #self.stack)
    truncate(self.stack, i)

    -- Make sure top class is clean.
    -- All the others already are (see swapVerticalBar).
    if #subs > 0 then
        syntax.cleanAlt(subs[#subs])
    end

    -- Empty alternate is special case
    -- (shouldn't happen but easy to handle).
    if #subs == 0 then
        return self:push(self:newRegexp(Op.NoMatch))
    end

    return self:push(self:collapse(subs, Op.Alternate))
end

-- cleanAlt cleans re for eventual inclusion in an alternation.
function syntax.cleanAlt(re)
    if re.op == Op.CharClass then
        re.rune = syntax.cleanClass(re.rune)
        local rs = re.rune
        if len(rs) == 2 and rs[1] == 0 and rs[2] == unicode.MaxRune then
            re.rune = nil
            re.op = Op.AnyChar
            return
        end
        if len(rs) == 4 and rs[1] == 0 and rs[2] == 0x0A - 1 and rs[3] == 0x0A + 1 and rs[4] == unicode.MaxRune then
            re.rune = nil
            re.op = Op.AnyCharNotNL
            return
        end
    end
end

-- collapse returns the result of applying op to sub.
-- If sub contains op nodes, they all get hoisted up
-- so that there is never a concat of a concat or an
-- alternate of an alternate.
function parser:collapse(subs, op)
    if #subs == 1 then
        return subs[1]
    end
    local re = self:newRegexp(op)
    re.sub = {}
    for _, sub in ipairs(subs) do
        if sub.op == op then
            for _, x in ipairs(sub.sub) do
                re.sub[#re.sub + 1] = x
            end
            self:reuse(sub)
        else
            re.sub[#re.sub + 1] = sub
        end
    end
    if op == Op.Alternate then
        re.sub = self:factor(re.sub)
        if #re.sub == 1 then
            local old = re
            re = re.sub[1]
            self:reuse(old)
        end
    end
    return re
end

-- factor factors common prefixes from the alternation list sub.
-- It returns a replacement list that reuses the same storage and
-- frees (passes to p.reuse) any removed *Regexps.
--
-- For example,
--
--	ABC|ABD|AEF|BCX|BCY
--
-- simplifies by literal prefix extraction to
--
--	A(B(C|D)|EF)|BC(X|Y)
--
-- which simplifies by character class introduction to
--
--	A(B[CD]|EF)|BC[XY]
function parser:factor(sub)
    if #sub < 2 then
        return sub
    end

    -- Round 1: Factor out common literal prefixes.
    -- (str is a view of the first strLen runes of a leading literal.)
    local str, strLen = nil, 0
    local strflags = 0
    local start = 0
    local out = {}
    for i = 0, #sub do
        -- Invariant: the Regexps that were in sub[0:start] have been
        -- used or marked for reuse, and the slice space has been reused
        -- for out (len(out) <= start).
        --
        -- Invariant: sub[start:i] consists of regexps that all begin
        -- with str as modified by strflags.
        local istr
        local iflags = 0
        local continue = false
        if i < #sub then
            istr, iflags = self:leadingString(sub[i + 1])
            if iflags == strflags then
                local same = 0
                while same < strLen and same < len(istr) and str[same + 1] == istr[same + 1] do
                    same = same + 1
                end
                if same > 0 then
                    -- Matches at least one rune in current range.
                    -- Keep going around.
                    strLen = same
                    continue = true
                end
            end
        end

        if not continue then
            -- Found end of a run with common leading literal string:
            -- sub[start:i] all begin with str[:len(str)], but sub[i]
            -- does not even begin with str[0].
            --
            -- Factor out common string and append factored expression to out.
            if i == start then
                -- Nothing to do - run of length 0.
            elseif i == start + 1 then
                -- Just one: don't bother factoring.
                out[#out + 1] = sub[start + 1]
            else
                -- Construct factored form: prefix(suffix1|suffix2|...)
                local prefix = self:newRegexp(Op.Literal)
                prefix.flags = strflags
                prefix.rune = slice(str, 0, strLen)

                for j = start, i - 1 do
                    sub[j + 1] = self:removeLeadingString(sub[j + 1], strLen)
                    self:checkLimits(sub[j + 1])
                end
                local suffix = self:collapse(slice(sub, start, i), Op.Alternate) -- recurse

                local re = self:newRegexp(Op.Concat)
                re.sub = { prefix, suffix }
                out[#out + 1] = re
            end

            -- Prepare for next iteration.
            start = i
            str, strLen = istr, len(istr)
            strflags = iflags
        end
    end
    sub = out

    -- Round 2: Factor out common simple prefixes,
    -- just the first piece of each concatenation.
    -- This will be good enough a lot of the time.
    --
    -- Complex subexpressions (e.g. involving quantifiers)
    -- are not safe to factor because that collapses their
    -- distinct paths through the automaton, which affects
    -- correctness in some cases.
    start = 0
    out = {}
    local first
    for i = 0, #sub do
        -- Invariant: the Regexps that were in sub[0:start] have been
        -- used or marked for reuse, and the slice space has been reused
        -- for out (len(out) <= start).
        --
        -- Invariant: sub[start:i] consists of regexps that all begin with ifirst.
        local ifirst
        local continue = false
        if i < #sub then
            ifirst = self:leadingRegexp(sub[i + 1])
            if first ~= nil and first:Equal(ifirst) and
                -- first must be a character class OR a fixed repeat of a character class.
                (syntax.isCharClass(first) or (first.op == Op.Repeat and first.min == first.max and syntax.isCharClass(first.sub[1]))) then
                continue = true
            end
        end

        if not continue then
            -- Found end of a run with common leading regexp:
            -- sub[start:i] all begin with first but sub[i] does not.
            --
            -- Factor out common regexp and append factored expression to out.
            if i == start then
                -- Nothing to do - run of length 0.
            elseif i == start + 1 then
                -- Just one: don't bother factoring.
                out[#out + 1] = sub[start + 1]
            else
                -- Construct factored form: prefix(suffix1|suffix2|...)
                local prefix = first
                for j = start, i - 1 do
                    local reuse = j ~= start -- prefix came from sub[start]
                    sub[j + 1] = self:removeLeadingRegexp(sub[j + 1], reuse)
                    self:checkLimits(sub[j + 1])
                end
                local suffix = self:collapse(slice(sub, start, i), Op.Alternate) -- recurse

                local re = self:newRegexp(Op.Concat)
                re.sub = { prefix, suffix }
                out[#out + 1] = re
            end

            -- Prepare for next iteration.
            start = i
            first = ifirst
        end
    end
    sub = out

    -- Round 3: Collapse runs of single literals into character classes.
    start = 0
    out = {}
    for i = 0, #sub do
        -- Invariant: the Regexps that were in sub[0:start] have been
        -- used or marked for reuse, and the slice space has been reused
        -- for out (len(out) <= start).
        --
        -- Invariant: sub[start:i] consists of regexps that are either
        -- literal runes or character classes.
        if not (i < #sub and syntax.isCharClass(sub[i + 1])) then
            -- sub[i] is not a char or char class;
            -- emit char class for sub[start:i]...
            if i == start then
                -- Nothing to do - run of length 0.
            elseif i == start + 1 then
                out[#out + 1] = sub[start + 1]
            else
                -- Make new char class.
                -- Start with most complex regexp in sub[start].
                local max = start
                for j = start + 1, i - 1 do
                    if sub[max + 1].op < sub[j + 1].op or sub[max + 1].op == sub[j + 1].op and len(sub[max + 1].rune) < len(sub[j + 1].rune) then
                        max = j
                    end
                end
                sub[start + 1], sub[max + 1] = sub[max + 1], sub[start + 1]

                for j = start + 1, i - 1 do
                    syntax.mergeCharClass(sub[start + 1], sub[j + 1])
                    self:reuse(sub[j + 1])
                end
                syntax.cleanAlt(sub[start + 1])
                out[#out + 1] = sub[start + 1]
            end

            -- ... and then emit sub[i].
            if i < #sub then
                out[#out + 1] = sub[i + 1]
            end
            start = i + 1
        end
    end
    sub = out

    -- Round 4: Collapse runs of empty matches into a single empty match.
    out = {}
    for i = 0, #sub - 1 do
        if not (i + 1 < #sub and sub[i + 1].op == Op.EmptyMatch and sub[i + 2].op == Op.EmptyMatch) then
            out[#out + 1] = sub[i + 1]
        end
    end
    sub = out

    return sub
end

-- leadingString returns the leading literal string that re begins with.
-- The string refers to storage in re or its children.
function parser:leadingString(re)
    if re.op == Op.Concat and #re.sub > 0 then
        re = re.sub[1]
    end
    if re.op ~= Op.Literal then
        return nil, 0
    end
    return re.rune, re.flags & Flags.FoldCase
end

-- removeLeadingString removes the first n leading runes
-- from the beginning of re. It returns the replacement for re.
function parser:removeLeadingString(re, n)
    if re.op == Op.Concat and #re.sub > 0 then
        -- Removing a leading string in a concatenation
        -- might simplify the concatenation.
        local sub = re.sub[1]
        sub = self:removeLeadingString(sub, n)
        re.sub[1] = sub
        if sub.op == Op.EmptyMatch then
            self:reuse(sub)
            local nsub = #re.sub
            if nsub == 0 or nsub == 1 then
                -- Impossible but handle.
                re.op = Op.EmptyMatch
                re.sub = nil
            elseif nsub == 2 then
                local old = re
                re = re.sub[2]
                self:reuse(old)
            else
                table.remove(re.sub, 1)
            end
        end
        return re
    end

    if re.op == Op.Literal then
        re.rune = slice(re.rune, n, len(re.rune))
        if #re.rune == 0 then
            re.op = Op.EmptyMatch
        end
    end
    return re
end

-- leadingRegexp returns the leading regexp that re begins with.
-- The regexp refers to storage in re or its children.
function parser:leadingRegexp(re)
    if re.op == Op.EmptyMatch then
        return nil
    end
    if re.op == Op.Concat and #re.sub > 0 then
        local sub = re.sub[1]
        if sub.op == Op.EmptyMatch then
            return nil
        end
        return sub
    end
    return re
end

-- removeLeadingRegexp removes the leading regexp in re.
-- It returns the replacement for re.
-- If reuse is true, it passes the removed regexp (if no longer needed) to p.reuse.
function parser:removeLeadingRegexp(re, reuse)
    if re.op == Op.Concat and #re.sub > 0 then
        if reuse then
            self:reuse(re.sub[1])
        end
        table.remove(re.sub, 1)
        local nsub = #re.sub
        if nsub == 0 then
            re.op = Op.EmptyMatch
            re.sub = nil
        elseif nsub == 1 then
            local old = re
            re = re.sub[1]
            self:reuse(old)
        end
        return re
    end
    if reuse then
        self:reuse(re)
    end
    return self:newRegexp(Op.EmptyMatch)
end

function syntax.literalRegexp(s, flags)
    local re = syntax.newRegexpValue(Op.Literal, flags)
    re.rune = utf8.StringToRunes(s)
    return re
end

-- Parsing.

-- Parse parses a regular expression string s, controlled by the specified
-- Flags, and returns a regular expression parse tree. The syntax is
-- described in the top-level comment.
function syntax.Parse(s, flags)
    return syntax.parse(s, flags)
end

function syntax.parse(s, flags)
    local ok, re, err = pcall(syntax.parseBody, s, flags)
    if not ok then
        local r = re
        if r == ErrorCode.ErrLarge then -- too big
            return nil, syntax.newError(ErrorCode.ErrLarge, s)
        elseif r == ErrorCode.ErrNestingDepth then
            return nil, syntax.newError(ErrorCode.ErrNestingDepth, s)
        end
        error(r, 0)
    end
    return re, err
end

function syntax.parseBody(s, flags)
    if flags & Flags.Literal ~= 0 then
        -- Trivial parser for literal string.
        local err = syntax.checkUTF8(s)
        if err ~= nil then
            return nil, err
        end
        return syntax.literalRegexp(s, flags), nil
    end

    -- Otherwise, must do real work.
    local p = syntax.newParser()
    local c = 0
    local op = 0
    local lastRepeat = ""
    local err
    p.flags = flags
    p.wholeRegexp = s
    local t = s
    while t ~= "" do
        local repeat_ = ""
        local t0 = sbyte(t, 1)
        if t0 == 0x28 --[[ '(' ]] then
            if p.flags & Flags.PerlX ~= 0 and #t >= 2 and sbyte(t, 2) == 0x3F --[[ '?' ]] then
                -- Flag changes and non-capturing groups.
                t, err = p:parsePerlFlags(t)
                if err ~= nil then
                    return nil, err
                end
            else
                p.numCap = p.numCap + 1
                p:op(syntax.opLeftParen).cap = p.numCap
                t = ssub(t, 2)
            end
        elseif t0 == 0x7C --[[ '|' ]] then
            p:parseVerticalBar()
            t = ssub(t, 2)
        elseif t0 == 0x29 --[[ ')' ]] then
            err = p:parseRightParen()
            if err ~= nil then
                return nil, err
            end
            t = ssub(t, 2)
        elseif t0 == 0x5E --[[ '^' ]] then
            if p.flags & Flags.OneLine ~= 0 then
                p:op(Op.BeginText)
            else
                p:op(Op.BeginLine)
            end
            t = ssub(t, 2)
        elseif t0 == 0x24 --[[ '$' ]] then
            if p.flags & Flags.OneLine ~= 0 then
                local re = p:op(Op.EndText)
                re.flags = re.flags | Flags.WasDollar
            else
                p:op(Op.EndLine)
            end
            t = ssub(t, 2)
        elseif t0 == 0x2E --[[ '.' ]] then
            if p.flags & Flags.DotNL ~= 0 then
                p:op(Op.AnyChar)
            else
                p:op(Op.AnyCharNotNL)
            end
            t = ssub(t, 2)
        elseif t0 == 0x5B --[[ '[' ]] then
            t, err = p:parseClass(t)
            if err ~= nil then
                return nil, err
            end
        elseif t0 == 0x2A or t0 == 0x2B or t0 == 0x3F --[[ '*', '+', '?' ]] then
            local before = t
            if t0 == 0x2A then
                op = Op.Star
            elseif t0 == 0x2B then
                op = Op.Plus
            else
                op = Op.Quest
            end
            local after = ssub(t, 2)
            after, err = p:repeat_(op, 0, 0, before, after, lastRepeat)
            if err ~= nil then
                return nil, err
            end
            repeat_ = before
            t = after
        elseif t0 == 0x7B --[[ '{' ]] then
            op = Op.Repeat
            local before = t
            local min, max, after, ok = p:parseRepeat(t)
            if not ok then
                -- If the repeat cannot be parsed, { is a literal.
                p:literal(0x7B)
                t = ssub(t, 2)
            else
                if min < 0 or min > 1000 or max > 1000 or max >= 0 and min > max then
                    -- Numbers were too big, or max is present and min > max.
                    return nil, syntax.newError(ErrorCode.ErrInvalidRepeatSize, ssub(before, 1, #before - #after))
                end
                after, err = p:repeat_(op, min, max, before, after, lastRepeat)
                if err ~= nil then
                    return nil, err
                end
                repeat_ = before
                t = after
            end
        elseif t0 == 0x5C --[[ '\\' ]] then
            local done = false
            if p.flags & Flags.PerlX ~= 0 and #t >= 2 then
                local t1 = sbyte(t, 2)
                if t1 == 0x41 --[[ 'A' ]] then
                    p:op(Op.BeginText)
                    t = ssub(t, 3)
                    done = true
                elseif t1 == 0x62 --[[ 'b' ]] then
                    p:op(Op.WordBoundary)
                    t = ssub(t, 3)
                    done = true
                elseif t1 == 0x42 --[[ 'B' ]] then
                    p:op(Op.NoWordBoundary)
                    t = ssub(t, 3)
                    done = true
                elseif t1 == 0x43 --[[ 'C' ]] then
                    -- any byte; not supported
                    return nil, syntax.newError(ErrorCode.ErrInvalidEscape, ssub(t, 1, 2))
                elseif t1 == 0x51 --[[ 'Q' ]] then
                    -- \Q ... \E: the ... is always literals
                    local lit
                    local rest = ssub(t, 3)
                    local i = string.find(rest, "\\E", 1, true)
                    if i ~= nil then
                        lit, t = ssub(rest, 1, i - 1), ssub(rest, i + 2)
                    else
                        lit, t = rest, ""
                    end
                    while lit ~= "" do
                        local c1, rest1, err1 = syntax.nextRune(lit)
                        if err1 ~= nil then
                            return nil, err1
                        end
                        p:literal(c1)
                        lit = rest1
                    end
                    done = true
                elseif t1 == 0x7A --[[ 'z' ]] then
                    p:op(Op.EndText)
                    t = ssub(t, 3)
                    done = true
                end
            end

            if not done then
                local re = p:newRegexp(Op.CharClass)
                re.flags = p.flags

                -- Look for Unicode character group like \p{Han}
                if #t >= 2 and (sbyte(t, 2) == 0x70 --[[ p ]] or sbyte(t, 2) == 0x50 --[[ P ]]) then
                    local r, rest, err1 = p:parseUnicodeClass(t, {})
                    if err1 ~= nil then
                        return nil, err1
                    end
                    if r ~= nil then
                        re.rune = r
                        t = rest
                        p:push(re)
                        done = true
                    end
                end

                -- Perl character class escape.
                if not done then
                    local r, rest = p:parsePerlClassEscape(t, {})
                    if r ~= nil then
                        re.rune = r
                        t = rest
                        p:push(re)
                        done = true
                    end
                end

                if not done then
                    p:reuse(re)

                    -- Ordinary single-character escape.
                    c, t, err = p:parseEscape(t)
                    if err ~= nil then
                        return nil, err
                    end
                    p:literal(c)
                end
            end
        else
            c, t, err = syntax.nextRune(t)
            if err ~= nil then
                return nil, err
            end
            p:literal(c)
        end
        lastRepeat = repeat_
    end

    p:concat()
    if p:swapVerticalBar() then
        -- pop vertical bar
        p.stack[#p.stack] = nil
    end
    p:alternate()

    local n = #p.stack
    if n ~= 1 then
        return nil, syntax.newError(ErrorCode.ErrMissingParen, s)
    end
    return p.stack[1], nil
end

-- parseRepeat parses {min} (max=min) or {min,} (max=-1) or {min,max}.
-- If s is not of that form, it returns ok == false.
-- If s has the right form but the values are too big, it returns min == -1, ok == true.
function parser:parseRepeat(s)
    local min, max = 0, 0
    if s == "" or sbyte(s, 1) ~= 0x7B --[[ '{' ]] then
        return 0, 0, "", false
    end
    s = ssub(s, 2)
    local ok1
    min, s, ok1 = self:parseInt(s)
    if not ok1 then
        return min, max, "", false
    end
    if s == "" then
        return min, max, "", false
    end
    if sbyte(s, 1) ~= 0x2C --[[ ',' ]] then
        max = min
    else
        s = ssub(s, 2)
        if s == "" then
            return min, max, "", false
        end
        if sbyte(s, 1) == 0x7D --[[ '}' ]] then
            max = -1
        else
            max, s, ok1 = self:parseInt(s)
            if not ok1 then
                return min, max, "", false
            elseif max < 0 then
                -- parseInt found too big a number
                min = -1
            end
        end
    end
    if s == "" or sbyte(s, 1) ~= 0x7D --[[ '}' ]] then
        return min, max, "", false
    end
    return min, max, ssub(s, 2), true
end

-- parsePerlFlags parses a Perl flag setting or non-capturing group or both,
-- like (?i) or (?: or (?i:.  It removes the prefix from s and updates the parse state.
-- The caller must have ensured that s begins with "(?".
function parser:parsePerlFlags(s)
    local t = s

    -- Check for named captures, first introduced in Python's regexp library.
    -- As usual, there are three slightly different syntaxes:
    --
    --   (?P<name>expr)   the original, introduced by Python
    --   (?<name>expr)    the .NET alteration, adopted by Perl 5.10
    --   (?'name'expr)    another .NET alteration, adopted by Perl 5.10
    --
    -- Perl 5.10 gave in and implemented the Python version too,
    -- but they claim that the last two are the preferred forms.
    -- PCRE and languages based on it (specifically, PHP and Ruby)
    -- support all three as well. EcmaScript 4 uses only the Python form.
    --
    -- In both the open source world (via Code Search) and the
    -- Google source tree, (?P<expr>name) and (?<expr>name) are the
    -- dominant forms of named captures and both are supported.
    local startsWithP = #t > 4 and sbyte(t, 3) == 0x50 --[[ 'P' ]] and sbyte(t, 4) == 0x3C --[[ '<' ]]
    local startsWithName = #t > 3 and sbyte(t, 3) == 0x3C --[[ '<' ]]

    if startsWithP or startsWithName then
        -- position of expr start
        local exprStartPos = 4
        if startsWithName then
            exprStartPos = 3
        end

        -- Pull out name.
        local end_ = (string.find(t, ">", 1, true) or 0) - 1
        if end_ < 0 then
            local err = syntax.checkUTF8(t)
            if err ~= nil then
                return "", err
            end
            return "", syntax.newError(ErrorCode.ErrInvalidNamedCapture, s)
        end

        local capture = ssub(t, 1, end_ + 1) -- "(?P<name>" or "(?<name>"
        local name = ssub(t, exprStartPos + 1, end_) -- "name"
        local err = syntax.checkUTF8(name)
        if err ~= nil then
            return "", err
        end
        if not syntax.isValidCaptureName(name) then
            return "", syntax.newError(ErrorCode.ErrInvalidNamedCapture, capture)
        end

        -- Like ordinary capture, but named.
        self.numCap = self.numCap + 1
        local re = self:op(syntax.opLeftParen)
        re.cap = self.numCap
        re.name = name
        return ssub(t, end_ + 2), nil
    end

    -- Non-capturing group. Might also twiddle Perl flags.
    local c, err
    t = ssub(t, 3) -- skip (?
    local flags = self.flags
    local sign = 1
    local sawFlag = false
    while t ~= "" do
        c, t, err = syntax.nextRune(t)
        if err ~= nil then
            return "", err
        end
        if c == 0x69 --[[ 'i' ]] then
            -- Flags.
            flags = flags | Flags.FoldCase
            sawFlag = true
        elseif c == 0x6D --[[ 'm' ]] then
            flags = flags & ~Flags.OneLine
            sawFlag = true
        elseif c == 0x73 --[[ 's' ]] then
            flags = flags | Flags.DotNL
            sawFlag = true
        elseif c == 0x55 --[[ 'U' ]] then
            flags = flags | Flags.NonGreedy
            sawFlag = true
        elseif c == 0x2D --[[ '-' ]] then
            -- Switch to negation.
            if sign < 0 then
                break
            end
            sign = -1
            -- Invert flags so that | above turn into &^ and vice versa.
            -- We'll invert flags again before using it below.
            flags = ~flags & 0xFFFF
            sawFlag = false
        elseif c == 0x3A or c == 0x29 --[[ ':', ')' ]] then
            -- End of flags, starting group or not.
            if sign < 0 then
                if not sawFlag then
                    break
                end
                flags = ~flags & 0xFFFF
            end
            if c == 0x3A then
                -- Open new group
                self:op(syntax.opLeftParen)
            end
            self.flags = flags
            return t, nil
        else
            break
        end
    end

    return "", syntax.newError(ErrorCode.ErrInvalidPerlOp, ssub(s, 1, #s - #t))
end

-- isValidCaptureName reports whether name
-- is a valid capture name: [A-Za-z0-9_]+.
-- PCRE limits names to 32 bytes.
-- Python rejects names starting with digits.
-- We don't enforce either of those.
function syntax.isValidCaptureName(name)
    if name == "" then
        return false
    end
    for _, c in ipairs(utf8.StringToRunes(name)) do
        if c ~= 0x5F --[[ '_' ]] and not syntax.isalnum(c) then
            return false
        end
    end
    return true
end

-- parseInt parses a decimal integer.
function parser:parseInt(s)
    local n = 0
    if s == "" or sbyte(s, 1) < 0x30 or 0x39 < sbyte(s, 1) then
        return 0, "", false
    end
    -- Disallow leading zeros.
    if #s >= 2 and sbyte(s, 1) == 0x30 and 0x30 <= sbyte(s, 2) and sbyte(s, 2) <= 0x39 then
        return 0, "", false
    end
    local t = s
    while s ~= "" and 0x30 <= sbyte(s, 1) and sbyte(s, 1) <= 0x39 do
        s = ssub(s, 2)
    end
    local rest = s
    -- Have digits, compute value.
    t = ssub(t, 1, #t - #s)
    for i = 0, #t - 1 do
        -- Avoid overflow.
        if n >= 1e8 then
            n = -1
            break
        end
        n = n * 10 + sbyte(t, i + 1) - 0x30
    end
    return n, rest, true
end

-- can this be represented as a character class?
-- single-rune literal string, char class, ., and .|\n.
function syntax.isCharClass(re)
    return re.op == Op.Literal and len(re.rune) == 1 or
        re.op == Op.CharClass or
        re.op == Op.AnyCharNotNL or
        re.op == Op.AnyChar
end

-- does re match r?
function syntax.matchRune(re, r)
    local op = re.op
    if op == Op.Literal then
        return len(re.rune) == 1 and re.rune[1] == r
    elseif op == Op.CharClass then
        local rs = re.rune or {}
        for i = 0, #rs - 1, 2 do
            if rs[i + 1] <= r and r <= rs[i + 2] then
                return true
            end
        end
        return false
    elseif op == Op.AnyCharNotNL then
        return r ~= 0x0A
    elseif op == Op.AnyChar then
        return true
    end
    return false
end

-- parseVerticalBar handles a | in the input.
function parser:parseVerticalBar()
    self:concat()

    -- The concatenation we just parsed is on top of the stack.
    -- If it sits above an opVerticalBar, swap it below
    -- (things below an opVerticalBar become an alternation).
    -- Otherwise, push a new vertical bar.
    if not self:swapVerticalBar() then
        self:op(syntax.opVerticalBar)
    end
end

-- mergeCharClass makes dst = dst|src.
-- The caller must ensure that dst.Op >= src.Op,
-- to reduce the amount of copying.
function syntax.mergeCharClass(dst, src)
    local op = dst.op
    if op == Op.AnyChar then
        -- src doesn't add anything.
    elseif op == Op.AnyCharNotNL then
        -- src might add \n
        if syntax.matchRune(src, 0x0A) then
            dst.op = Op.AnyChar
        end
    elseif op == Op.CharClass then
        -- src is simpler, so either literal or char class
        if src.op == Op.Literal then
            dst.rune = syntax.appendLiteral(dst.rune or {}, src.rune[1], src.flags)
        else
            dst.rune = syntax.appendClass(dst.rune or {}, src.rune or {})
        end
    elseif op == Op.Literal then
        -- both literal
        if src.rune[1] == dst.rune[1] and src.flags == dst.flags then
            return
        end
        dst.op = Op.CharClass
        dst.rune = syntax.appendLiteral({}, dst.rune[1], dst.flags)
        dst.rune = syntax.appendLiteral(dst.rune, src.rune[1], src.flags)
    end
end

-- If the top of the stack is an element followed by an opVerticalBar
-- swapVerticalBar swaps the two and returns true.
-- Otherwise it returns false.
function parser:swapVerticalBar()
    -- If above and below vertical bar are literal or char class,
    -- can merge into a single char class.
    local stack = self.stack
    local n = #stack
    if n >= 3 and stack[n - 1].op == syntax.opVerticalBar and syntax.isCharClass(stack[n]) and syntax.isCharClass(stack[n - 2]) then
        local re1 = stack[n]
        local re3 = stack[n - 2]
        -- Make re3 the more complex of the two.
        if re1.op > re3.op then
            re1, re3 = re3, re1
            stack[n - 2] = re3
        end
        syntax.mergeCharClass(re3, re1)
        self:reuse(re1)
        stack[n] = nil
        return true
    end

    if n >= 2 then
        local re1 = stack[n]
        local re2 = stack[n - 1]
        if re2.op == syntax.opVerticalBar then
            if n >= 3 then
                -- Now out of reach.
                -- Clean opportunistically.
                syntax.cleanAlt(stack[n - 2])
            end
            stack[n - 1] = re1
            stack[n] = re2
            return true
        end
    end
    return false
end

-- parseRightParen handles a ) in the input.
function parser:parseRightParen()
    self:concat()
    if self:swapVerticalBar() then
        -- pop vertical bar
        self.stack[#self.stack] = nil
    end
    self:alternate()

    local n = #self.stack
    if n < 2 then
        return syntax.newError(ErrorCode.ErrUnexpectedParen, self.wholeRegexp)
    end
    local re1 = self.stack[n]
    local re2 = self.stack[n - 1]
    self.stack[n] = nil
    self.stack[n - 1] = nil
    if re2.op ~= syntax.opLeftParen then
        return syntax.newError(ErrorCode.ErrUnexpectedParen, self.wholeRegexp)
    end
    -- Restore flags at time of paren.
    self.flags = re2.flags
    if re2.cap == 0 then
        -- Just for grouping.
        self:push(re1)
    else
        re2.op = Op.Capture
        re2.sub = { re1 }
        self:push(re2)
    end
    return nil
end

-- parseEscape parses an escape sequence at the beginning of s
-- and returns the rune.
function parser:parseEscape(s)
    local r = 0
    local t = ssub(s, 2)
    if t == "" then
        return 0, "", syntax.newError(ErrorCode.ErrTrailingBackslash, "")
    end
    local c, err
    c, t, err = syntax.nextRune(t)
    if err ~= nil then
        return 0, "", err
    end

    if c >= 0x31 and c <= 0x37 then
        -- Octal escapes.
        -- Single non-zero digit is a backreference; not supported
        if t == "" or sbyte(t, 1) < 0x30 or sbyte(t, 1) > 0x37 then
            goto invalid
        end
        -- fallthrough
    end
    if c >= 0x30 and c <= 0x37 then
        -- Consume up to three octal digits; already have one.
        r = c - 0x30
        for _ = 1, 2 do
            if t == "" or sbyte(t, 1) < 0x30 or sbyte(t, 1) > 0x37 then
                break
            end
            r = r * 8 + sbyte(t, 1) - 0x30
            t = ssub(t, 2)
        end
        return r, t, nil
    elseif c == 0x78 --[[ 'x' ]] then
        -- Hexadecimal escapes.
        if t == "" then
            goto invalid
        end
        c, t, err = syntax.nextRune(t)
        if err ~= nil then
            return 0, "", err
        end
        if c == 0x7B --[[ '{' ]] then
            -- Any number of digits in braces.
            -- Perl accepts any text at all; it ignores all text
            -- after the first non-hex digit. We require only hex digits,
            -- and at least one.
            local nhex = 0
            r = 0
            while true do
                if t == "" then
                    goto invalid
                end
                c, t, err = syntax.nextRune(t)
                if err ~= nil then
                    return 0, "", err
                end
                if c == 0x7D --[[ '}' ]] then
                    break
                end
                local v = syntax.unhex(c)
                if v < 0 then
                    goto invalid
                end
                r = r * 16 + v
                if r > unicode.MaxRune then
                    goto invalid
                end
                nhex = nhex + 1
            end
            if nhex == 0 then
                goto invalid
            end
            return r, t, nil
        end

        -- Easy case: two hex digits.
        local x = syntax.unhex(c)
        c, t, err = syntax.nextRune(t)
        if err ~= nil then
            return 0, "", err
        end
        local y = syntax.unhex(c)
        if x < 0 or y < 0 then
            goto invalid
        end
        return x * 16 + y, t, nil

        -- C escapes. There is no case 'b', to avoid misparsing
        -- the Perl word-boundary \b as the C backspace \b
        -- when in POSIX mode. In Perl, /\b/ means word-boundary
        -- but /[\b]/ means backspace. We don't support that.
        -- If you want a backspace, embed a literal backspace
        -- character or use \x08.
    elseif c == 0x61 --[[ 'a' ]] then
        return 7, t, err
    elseif c == 0x66 --[[ 'f' ]] then
        return 12, t, err
    elseif c == 0x6E --[[ 'n' ]] then
        return 10, t, err
    elseif c == 0x72 --[[ 'r' ]] then
        return 13, t, err
    elseif c == 0x74 --[[ 't' ]] then
        return 9, t, err
    elseif c == 0x76 --[[ 'v' ]] then
        return 11, t, err
    elseif c < 0x30 or c > 0x37 then
        if c < utf8.RuneSelf and not syntax.isalnum(c) then
            -- Escaped non-word characters are always themselves.
            -- PCRE is not quite so rigorous: it accepts things like
            -- \q, but we don't. We once rejected \_, but too many
            -- programs and people insist on using it, so allow \_.
            return c, t, nil
        end
    end
    ::invalid::
    return 0, "", syntax.newError(ErrorCode.ErrInvalidEscape, ssub(s, 1, #s - #t))
end

-- parseClassChar parses a character class character at the beginning of s
-- and returns it.
function parser:parseClassChar(s, wholeClass)
    if s == "" then
        return 0, "", syntax.newError(ErrorCode.ErrMissingBracket, wholeClass)
    end

    -- Allow regular escape sequences even though
    -- many need not be escaped in this context.
    if sbyte(s, 1) == 0x5C --[[ '\\' ]] then
        return self:parseEscape(s)
    end

    return syntax.nextRune(s)
end

-- parsePerlClassEscape parses a leading Perl character class escape like \d
-- from the beginning of s. If one is present, it appends the characters to r
-- and returns the new slice r and the remainder of the string.
function parser:parsePerlClassEscape(s, r)
    if self.flags & Flags.PerlX == 0 or #s < 2 or sbyte(s, 1) ~= 0x5C then
        return nil, ""
    end
    local g = syntax.perlGroup[ssub(s, 1, 2)]
    if g == nil then
        return nil, ""
    end
    return self:appendGroup(r, g), ssub(s, 3)
end

-- parseNamedClass parses a leading POSIX named character class like [:alnum:]
-- from the beginning of s. If one is present, it appends the characters to r
-- and returns the new slice r and the remainder of the string.
function parser:parseNamedClass(s, r)
    if #s < 2 or sbyte(s, 1) ~= 0x5B or sbyte(s, 2) ~= 0x3A then
        return nil, "", nil
    end

    local i = string.find(ssub(s, 3), ":]", 1, true)
    if i == nil then
        return nil, "", nil
    end
    i = i - 1 + 2
    local name
    name, s = ssub(s, 1, i + 2), ssub(s, i + 3)
    local g = syntax.posixGroup[name]
    if g == nil then
        return nil, "", syntax.newError(ErrorCode.ErrInvalidCharRange, name)
    end
    return self:appendGroup(r, g), s, nil
end

function parser:appendGroup(r, g)
    if self.flags & Flags.FoldCase == 0 then
        if g.sign < 0 then
            r = syntax.appendNegatedClass(r, g.class)
        else
            r = syntax.appendClass(r, g.class)
        end
    else
        local tmp = syntax.appendFoldedClass({}, g.class)
        self.tmpClass = tmp
        tmp = syntax.cleanClass(self.tmpClass)
        if g.sign < 0 then
            r = syntax.appendNegatedClass(r, tmp)
        else
            r = syntax.appendClass(r, tmp)
        end
    end
    return r
end

syntax.anyTable = {
    r16 = { 0, (1 << 16) - 1, 1 },
    r32 = { 1 << 16, unicode.MaxRune, 1 },
}

syntax.asciiTable = {
    r16 = { 0, 0x7F, 1 },
    r32 = {},
}

syntax.asciiFoldTable = {
    r16 = {
        0, 0x7F, 1,
        0x017F, 0x017F, 1, -- Old English long s (ſ), folds to S/s.
        0x212A, 0x212A, 1, -- Kelvin K, folds to K/k.
    },
    r32 = {},
}

-- categoryAliases is a lazily constructed copy of unicode.CategoryAliases
-- but with the keys passed through canonicalName, to support inexact matches.
syntax.categoryAliases = { m = nil }

-- initCategoryAliases initializes categoryAliases by canonicalizing unicode.CategoryAliases.
function syntax.initCategoryAliases()
    syntax.categoryAliases.m = {}
    for name, actual in pairs(unicode.CategoryAliases) do
        syntax.categoryAliases.m[syntax.canonicalName(name)] = actual
    end
end

-- canonicalName returns the canonical lookup string for name.
-- The canonical name has a leading uppercase letter and then lowercase letters,
-- and it omits all underscores, spaces, and hyphens.
-- (We could have used all lowercase, but this way most package unicode
-- map keys are already canonical.)
function syntax.canonicalName(name)
    local b = {}
    local first = true
    for i = 1, #name do
        local c = sbyte(name, i)
        if c == 0x5F or c == 0x2D or c == 0x20 then
            c = 0x20
        elseif first then
            if 0x61 <= c and c <= 0x7A then
                c = c - (0x61 - 0x41)
            end
            first = false
        else
            if 0x41 <= c and c <= 0x5A then
                c = c + (0x61 - 0x41)
            end
        end
        if c ~= 0x20 then
            b[#b + 1] = string.char(c)
        end
    end
    return table.concat(b)
end

-- unicodeTable returns the unicode.RangeTable identified by name
-- and the table of additional fold-equivalent code points.
-- If sign < 0, the result should be inverted.
function syntax.unicodeTable(name)
    name = syntax.canonicalName(name)

    -- Special cases: Any, Assigned, and ASCII.
    -- Also LC is the only non-canonical Categories key, so handle it here.
    if name == "Any" then
        return syntax.anyTable, syntax.anyTable, 1
    elseif name == "Assigned" then
        return unicode.Cn, unicode.Cn, -1 -- invert Cn (unassigned)
    elseif name == "Ascii" then
        return syntax.asciiTable, syntax.asciiFoldTable, 1
    elseif name == "Lc" then
        return unicode.Categories["LC"], unicode.FoldCategory["LC"], 1
    end
    local t = unicode.Categories[name]
    if t ~= nil then
        return t, unicode.FoldCategory[name], 1
    end
    t = unicode.Scripts[name]
    if t ~= nil then
        return t, unicode.FoldScript[name], 1
    end

    -- unicode.CategoryAliases makes liberal use of underscores in its names
    -- (they are defined that way by Unicode), but we want to match ignoring
    -- the underscores, so make our own map with canonical names.
    if syntax.categoryAliases.m == nil then
        syntax.initCategoryAliases()
    end
    local actual = syntax.categoryAliases.m[name]
    if actual ~= nil and actual ~= "" then
        t = unicode.Categories[actual]
        return t, unicode.FoldCategory[actual], 1
    end
    return nil, nil, 0
end

-- parseUnicodeClass parses a leading Unicode character class like \p{Han}
-- from the beginning of s. If one is present, it appends the characters to r
-- and returns the new slice r and the remainder of the string.
function parser:parseUnicodeClass(s, r)
    if self.flags & Flags.UnicodeGroups == 0 or #s < 2 or sbyte(s, 1) ~= 0x5C or sbyte(s, 2) ~= 0x70 and sbyte(s, 2) ~= 0x50 then
        return nil, "", nil
    end

    -- Committed to parse or return error.
    local sign = 1
    if sbyte(s, 2) == 0x50 --[[ 'P' ]] then
        sign = -1
    end
    local t = ssub(s, 3)
    local c, err
    c, t, err = syntax.nextRune(t)
    if err ~= nil then
        return nil, "", err
    end
    local seq, name
    if c ~= 0x7B --[[ '{' ]] then
        -- Single-letter name.
        seq = ssub(s, 1, #s - #t)
        name = ssub(seq, 3)
    else
        -- Name is in braces.
        local end_ = (string.find(s, "}", 1, true) or 0) - 1
        if end_ < 0 then
            err = syntax.checkUTF8(s)
            if err ~= nil then
                return nil, "", err
            end
            return nil, "", syntax.newError(ErrorCode.ErrInvalidCharRange, s)
        end
        seq, t = ssub(s, 1, end_ + 1), ssub(s, end_ + 2)
        name = ssub(s, 4, end_)
        err = syntax.checkUTF8(name)
        if err ~= nil then
            return nil, "", err
        end
    end

    -- Group can have leading negation too.  \p{^Han} == \P{Han}, \P{^Han} == \p{Han}.
    if name ~= "" and sbyte(name, 1) == 0x5E --[[ '^' ]] then
        sign = -sign
        name = ssub(name, 2)
    end

    local tab, fold, tsign = syntax.unicodeTable(name)
    if tab == nil then
        return nil, "", syntax.newError(ErrorCode.ErrInvalidCharRange, seq)
    end
    if tsign < 0 then
        sign = -sign
    end

    if self.flags & Flags.FoldCase == 0 or fold == nil then
        if sign > 0 then
            r = syntax.appendTable(r, tab)
        else
            r = syntax.appendNegatedTable(r, tab)
        end
    else
        -- Merge and clean tab and fold in a temporary buffer.
        -- This is necessary for the negative case and just tidy
        -- for the positive case.
        local tmp = syntax.appendTable({}, tab)
        tmp = syntax.appendTable(tmp, fold)
        self.tmpClass = tmp
        tmp = syntax.cleanClass(self.tmpClass)
        if sign > 0 then
            r = syntax.appendClass(r, tmp)
        else
            r = syntax.appendNegatedClass(r, tmp)
        end
    end
    return r, t, nil
end

-- parseClass parses a character class at the beginning of s
-- and pushes it onto the parse stack.
function parser:parseClass(s)
    local t = ssub(s, 2) -- chop [
    local re = self:newRegexp(Op.CharClass)
    re.flags = self.flags
    re.rune = {}

    local sign = 1
    if t ~= "" and sbyte(t, 1) == 0x5E --[[ '^' ]] then
        sign = -1
        t = ssub(t, 2)

        -- If character class does not match \n, add it here,
        -- so that negation later will do the right thing.
        if self.flags & Flags.ClassNL == 0 then
            re.rune[#re.rune + 1] = 0x0A
            re.rune[#re.rune + 1] = 0x0A
        end
    end

    local class = re.rune
    local first = true -- ] and - are okay as first char in class
    local err
    while t == "" or sbyte(t, 1) ~= 0x5D --[[ ']' ]] or first do
        -- POSIX: - is only okay unescaped as first or last in class.
        -- Perl: - is okay anywhere.
        if t ~= "" and sbyte(t, 1) == 0x2D and self.flags & Flags.PerlX == 0 and not first and (#t == 1 or sbyte(t, 2) ~= 0x5D) then
            local _, size = utf8.DecodeRuneInString(t, 1)
            return "", syntax.newError(ErrorCode.ErrInvalidCharRange, ssub(t, 1, 1 + size))
        end
        first = false

        -- Look for POSIX [:alnum:] etc.
        if #t > 2 and sbyte(t, 1) == 0x5B and sbyte(t, 2) == 0x3A then
            local nclass, nt, err1 = self:parseNamedClass(t, class)
            if err1 ~= nil then
                return "", err1
            end
            if nclass ~= nil then
                class, t = nclass, nt
                goto continue
            end
        end

        do
            -- Look for Unicode character group like \p{Han}.
            local nclass, nt, err1 = self:parseUnicodeClass(t, class)
            if err1 ~= nil then
                return "", err1
            end
            if nclass ~= nil then
                class, t = nclass, nt
                goto continue
            end
        end

        do
            -- Look for Perl character class symbols (extension).
            local nclass, nt = self:parsePerlClassEscape(t, class)
            if nclass ~= nil then
                class, t = nclass, nt
                goto continue
            end
        end

        do
            -- Single character or simple range.
            local rng = t
            local lo, hi
            lo, t, err = self:parseClassChar(t, s)
            if err ~= nil then
                return "", err
            end
            hi = lo
            -- [a-] means (a|-) so check for final ].
            if #t >= 2 and sbyte(t, 1) == 0x2D and sbyte(t, 2) ~= 0x5D then
                t = ssub(t, 2)
                hi, t, err = self:parseClassChar(t, s)
                if err ~= nil then
                    return "", err
                end
                if hi < lo then
                    rng = ssub(rng, 1, #rng - #t)
                    return "", syntax.newError(ErrorCode.ErrInvalidCharRange, rng)
                end
            end
            if self.flags & Flags.FoldCase == 0 then
                class = syntax.appendRange(class, lo, hi)
            else
                class = syntax.appendFoldedRange(class, lo, hi)
            end
        end
        ::continue::
    end
    t = ssub(t, 2) -- chop ]

    -- Use &re.Rune instead of &class to avoid allocation.
    re.rune = class
    class = syntax.cleanClass(re.rune)
    if sign < 0 then
        class = syntax.negateClass(class)
    end
    re.rune = class
    self:push(re)
    return t, nil
end

-- cleanClass sorts the ranges (pairs of elements of r),
-- merges them, and eliminates duplicates.
-- (Sorts and truncates the array r in place and returns it.)
function syntax.cleanClass(r)
    -- Sort by lo increasing, hi decreasing to break ties.
    syntax.sortRanges(r)

    if #r < 2 then
        return r
    end

    -- Merge abutting, overlapping.
    local w = 2 -- write index
    for i = 2, #r - 1, 2 do
        local lo, hi = r[i + 1], r[i + 2]
        if lo <= r[w] + 1 then
            -- merge with previous range
            if hi > r[w] then
                r[w] = hi
            end
        else
            -- new disjoint range
            r[w + 1] = lo
            r[w + 2] = hi
            w = w + 2
        end
    end

    truncate(r, w)
    return r
end

-- inCharClass reports whether r is in the class.
-- It assumes the class has been cleaned by cleanClass.
function syntax.inCharClass(r, class)
    local lo, hi = 0, #class // 2
    while lo < hi do
        local m = (lo + hi) // 2
        if r > class[2 * m + 2] then
            lo = m + 1
        else
            hi = m
        end
    end
    return lo < #class // 2 and class[2 * lo + 1] <= r and r <= class[2 * lo + 2]
end

-- appendLiteral returns the result of appending the literal x to the class r.
function syntax.appendLiteral(r, x, flags)
    if flags & Flags.FoldCase ~= 0 then
        return syntax.appendFoldedRange(r, x, x)
    end
    return syntax.appendRange(r, x, x)
end

-- appendRange returns the result of appending the range lo-hi to the class r.
function syntax.appendRange(r, lo, hi)
    -- Expand last range or next to last range if it overlaps or abuts.
    -- Checking two ranges helps when appending case-folded
    -- alphabets, so that one range can be expanding A-Z and the
    -- other expanding a-z.
    local n = #r
    for i = 2, 4, 2 do -- twice, using i=2, i=4
        if n >= i then
            local rlo, rhi = r[n - i + 1], r[n - i + 2]
            if lo <= rhi + 1 and rlo <= hi + 1 then
                if lo < rlo then
                    r[n - i + 1] = lo
                end
                if hi > rhi then
                    r[n - i + 2] = hi
                end
                return r
            end
        end
    end

    r[n + 1] = lo
    r[n + 2] = hi
    return r
end

-- minimum and maximum runes involved in folding.
-- checked during test.
syntax.minFold = 0x0041
syntax.maxFold = 0x1e943

-- appendFoldedRange returns the result of appending the range lo-hi
-- and its case folding-equivalent runes to the class r.
function syntax.appendFoldedRange(r, lo, hi)
    -- Optimizations.
    if lo <= syntax.minFold and hi >= syntax.maxFold then
        -- Range is full: folding can't add more.
        return syntax.appendRange(r, lo, hi)
    end
    if hi < syntax.minFold or lo > syntax.maxFold then
        -- Range is outside folding possibilities.
        return syntax.appendRange(r, lo, hi)
    end
    if lo < syntax.minFold then
        -- [lo, minFold-1] needs no folding.
        r = syntax.appendRange(r, lo, syntax.minFold - 1)
        lo = syntax.minFold
    end
    if hi > syntax.maxFold then
        -- [maxFold+1, hi] needs no folding.
        r = syntax.appendRange(r, syntax.maxFold + 1, hi)
        hi = syntax.maxFold
    end

    -- Brute force. Depend on appendRange to coalesce ranges on the fly.
    for c = lo, hi do
        r = syntax.appendRange(r, c, c)
        local f = unicode.SimpleFold(c)
        while f ~= c do
            r = syntax.appendRange(r, f, f)
            f = unicode.SimpleFold(f)
        end
    end
    return r
end

-- appendClass returns the result of appending the class x to the class r.
-- It assume x is clean.
function syntax.appendClass(r, x)
    for i = 0, #x - 1, 2 do
        r = syntax.appendRange(r, x[i + 1], x[i + 2])
    end
    return r
end

-- appendFoldedClass returns the result of appending the case folding of the class x to the class r.
function syntax.appendFoldedClass(r, x)
    for i = 0, #x - 1, 2 do
        r = syntax.appendFoldedRange(r, x[i + 1], x[i + 2])
    end
    return r
end

-- appendNegatedClass returns the result of appending the negation of the class x to the class r.
-- It assumes x is clean.
function syntax.appendNegatedClass(r, x)
    local nextLo = 0
    for i = 0, #x - 1, 2 do
        local lo, hi = x[i + 1], x[i + 2]
        if nextLo <= lo - 1 then
            r = syntax.appendRange(r, nextLo, lo - 1)
        end
        nextLo = hi + 1
    end
    if nextLo <= unicode.MaxRune then
        r = syntax.appendRange(r, nextLo, unicode.MaxRune)
    end
    return r
end

-- appendTable returns the result of appending x to the class r.
function syntax.appendTable(r, x)
    for _, xs in ipairs({ x.r16, x.r32 }) do
        for k = 1, #xs, 3 do
            local lo, hi, stride = xs[k], xs[k + 1], xs[k + 2]
            if stride == 1 then
                r = syntax.appendRange(r, lo, hi)
            else
                for c = lo, hi, stride do
                    r = syntax.appendRange(r, c, c)
                end
            end
        end
    end
    return r
end

-- appendNegatedTable returns the result of appending the negation of x to the class r.
function syntax.appendNegatedTable(r, x)
    local nextLo = 0 -- lo end of next class to add
    for _, xs in ipairs({ x.r16, x.r32 }) do
        for k = 1, #xs, 3 do
            local lo, hi, stride = xs[k], xs[k + 1], xs[k + 2]
            if stride == 1 then
                if nextLo <= lo - 1 then
                    r = syntax.appendRange(r, nextLo, lo - 1)
                end
                nextLo = hi + 1
            else
                for c = lo, hi, stride do
                    if nextLo <= c - 1 then
                        r = syntax.appendRange(r, nextLo, c - 1)
                    end
                    nextLo = c + 1
                end
            end
        end
    end
    if nextLo <= unicode.MaxRune then
        r = syntax.appendRange(r, nextLo, unicode.MaxRune)
    end
    return r
end

-- negateClass overwrites r and returns r's negation.
-- It assumes the class r is already clean.
function syntax.negateClass(r)
    local nextLo = 0 -- lo end of next class to add
    local w = 0 -- write index
    for i = 0, #r - 1, 2 do
        local lo, hi = r[i + 1], r[i + 2]
        if nextLo <= lo - 1 then
            r[w + 1] = nextLo
            r[w + 2] = lo - 1
            w = w + 2
        end
        nextLo = hi + 1
    end
    truncate(r, w)
    if nextLo <= unicode.MaxRune then
        -- It's possible for the negation to have one more
        -- range - this one - than the original class, so use append.
        r[#r + 1] = nextLo
        r[#r + 1] = unicode.MaxRune
    end
    return r
end

-- ranges implements sort.Interface on a []rune (sortRanges sorts the pairs of r in place
-- by lo increasing, hi decreasing; equal pairs are identical, so stability does not matter).
function syntax.sortRanges(r)
    local n = #r // 2
    if n < 2 then
        return
    end
    local pairs_ = {}
    for i = 0, n - 1 do
        pairs_[i + 1] = { r[2 * i + 1], r[2 * i + 2] }
    end
    table.sort(pairs_, function(a, b)
        return a[1] < b[1] or a[1] == b[1] and a[2] > b[2]
    end)
    for i = 0, n - 1 do
        r[2 * i + 1] = pairs_[i + 1][1]
        r[2 * i + 2] = pairs_[i + 1][2]
    end
end

function syntax.checkUTF8(s)
    local pos, n = 0, #s
    while pos < n do
        local rune, size = utf8.DecodeRuneInString(s, pos)
        if rune == utf8.RuneError and size == 1 then
            return syntax.newError(ErrorCode.ErrInvalidUTF8, ssub(s, pos + 1))
        end
        pos = pos + size
    end
    return nil
end

function syntax.nextRune(s)
    local c, size = utf8.DecodeRuneInString(s, 0)
    if c == utf8.RuneError and size == 1 then
        return 0, "", syntax.newError(ErrorCode.ErrInvalidUTF8, s)
    end
    return c, ssub(s, size + 1), nil
end

function syntax.isalnum(c)
    return 0x30 <= c and c <= 0x39 or 0x41 <= c and c <= 0x5A or 0x61 <= c and c <= 0x7A
end

function syntax.unhex(c)
    if 0x30 <= c and c <= 0x39 then
        return c - 0x30
    end
    if 0x61 <= c and c <= 0x66 then
        return c - 0x61 + 10
    end
    if 0x41 <= c and c <= 0x46 then
        return c - 0x41 + 10
    end
    return -1
end
