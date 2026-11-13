local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")
local utf8 = require("tslua.regexp.utf8")
local strconv = require("tslua.regexp.strconv")

local Flags = syntax.Flags
local InstOp = syntax.InstOp
local EmptyOp = syntax.EmptyOp

-- Compiled program.
-- May not belong in this package, but convenient for now.

-- A Prog is a compiled regular expression program.
-- Fields: inst (array; pc i is inst[i + 1]), start (index of start instruction),
-- numCap (number of InstCapture insts in re).
local Prog = {}
Prog.__index = Prog
syntax.Prog = Prog

function syntax.newProg()
    return setmetatable({ inst = {}, start = 0, numCap = 0 }, Prog)
end

syntax.instOpNames = {
    "InstAlt",
    "InstAltMatch",
    "InstCapture",
    "InstEmptyWidth",
    "InstMatch",
    "InstFail",
    "InstNop",
    "InstRune",
    "InstRune1",
    "InstRuneAny",
    "InstRuneAnyNotNL",
}

function syntax.InstOp_String(i)
    if i < 0 or i >= #syntax.instOpNames then
        return ""
    end
    return syntax.instOpNames[i + 1]
end

-- EmptyOpContext returns the zero-width assertions
-- satisfied at the position between the runes r1 and r2.
-- Passing r1 == -1 indicates that the position is
-- at the beginning of the text.
-- Passing r2 == -1 indicates that the position is
-- at the end of the text.
function syntax.EmptyOpContext(r1, r2)
    local op = EmptyOp.EmptyNoWordBoundary
    local boundary = 0
    if syntax.IsWordChar(r1) then
        boundary = 1
    elseif r1 == 0x0A then
        op = op | EmptyOp.EmptyBeginLine
    elseif r1 < 0 then
        op = op | EmptyOp.EmptyBeginText | EmptyOp.EmptyBeginLine
    end
    if syntax.IsWordChar(r2) then
        boundary = boundary ~ 1
    elseif r2 == 0x0A then
        op = op | EmptyOp.EmptyEndLine
    elseif r2 < 0 then
        op = op | EmptyOp.EmptyEndText | EmptyOp.EmptyEndLine
    end
    if boundary ~= 0 then -- IsWordChar(r1) != IsWordChar(r2)
        op = op ~ (EmptyOp.EmptyWordBoundary | EmptyOp.EmptyNoWordBoundary)
    end
    return op
end

-- IsWordChar reports whether r is considered a “word character”
-- during the evaluation of the \b and \B zero-width assertions.
-- These assertions are ASCII-only: the word characters are [A-Za-z0-9_].
function syntax.IsWordChar(r)
    -- Test for lowercase letters first, as these occur more
    -- frequently than uppercase letters in common cases.
    return 0x61 <= r and r <= 0x7A or 0x41 <= r and r <= 0x5A or 0x30 <= r and r <= 0x39 or r == 0x5F
end

-- An Inst is a single instruction in a regular expression program.
-- Fields: op, out (all but InstMatch, InstFail), arg (InstAlt, InstAltMatch, InstCapture,
-- InstEmptyWidth), rune (array of runes or nil).
local Inst = {}
Inst.__index = Inst
syntax.Inst = Inst

function syntax.newInst(op)
    return setmetatable({ op = op or 0, out = 0, arg = 0, rune = nil }, Inst)
end

function Prog:String()
    local b = {}
    syntax.dumpProg(b, self)
    return table.concat(b)
end

Prog.__tostring = Prog.String

-- skipNop follows any no-op or capturing instructions.
function Prog:skipNop(pc)
    local i = self.inst[pc + 1]
    while i.op == InstOp.InstNop or i.op == InstOp.InstCapture do
        i = self.inst[i.out + 1]
    end
    return i
end

-- op returns i.Op but merges all the rune special cases into InstRune
function Inst:op_()
    local op = self.op
    if op == InstOp.InstRune1 or op == InstOp.InstRuneAny or op == InstOp.InstRuneAnyNotNL then
        op = InstOp.InstRune
    end
    return op
end

local function rlen(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

-- Prefix returns a literal string that all matches for the
-- regexp must start with. Complete is true if the prefix
-- is the entire match.
function Prog:Prefix()
    local i = self:skipNop(self.start)

    -- Avoid allocation of buffer if prefix is empty.
    if i:op_() ~= InstOp.InstRune or rlen(i.rune) ~= 1 then
        return "", i.op == InstOp.InstMatch
    end

    -- Have prefix; gather characters.
    local buf = {}
    while i:op_() == InstOp.InstRune and rlen(i.rune) == 1 and i.arg & Flags.FoldCase == 0 and i.rune[1] ~= utf8.RuneError do
        buf[#buf + 1] = utf8.EncodeRune(i.rune[1])
        i = self:skipNop(i.out)
    end
    return table.concat(buf), i.op == InstOp.InstMatch
end

-- StartCond returns the leading empty-width conditions that must
-- be true in any match. It returns ^EmptyOp(0) if no matches are possible.
function Prog:StartCond()
    local flag = 0
    local pc = self.start
    local i = self.inst[pc + 1]
    while true do
        local op = i.op
        if op == InstOp.InstEmptyWidth then
            flag = flag | (i.arg & 0xFF)
        elseif op == InstOp.InstFail then
            return 0xFF
        elseif op == InstOp.InstCapture or op == InstOp.InstNop then
            -- skip
        else
            break
        end
        pc = i.out
        i = self.inst[pc + 1]
    end
    return flag
end

syntax.noMatch = -1

-- MatchRune reports whether the instruction matches (and consumes) r.
-- It should only be called when i.Op == [InstRune].
function Inst:MatchRune(r)
    return self:MatchRunePos(r) ~= syntax.noMatch
end

-- MatchRunePos checks whether the instruction matches (and consumes) r.
-- If so, MatchRunePos returns the index of the matching rune pair
-- (or, when len(i.Rune) == 1, rune singleton).
-- If not, MatchRunePos returns -1.
-- MatchRunePos should only be called when i.Op == [InstRune].
function Inst:MatchRunePos(r)
    local rune = self.rune
    local n = rlen(rune)

    if n == 0 then
        return syntax.noMatch
    elseif n == 1 then
        -- Special case: single rune.
        local r0 = rune[1]
        if r == r0 then
            return 0
        end
        if self.arg & Flags.FoldCase ~= 0 then
            local r1 = unicode.SimpleFold(r0)
            while r1 ~= r0 do
                if r == r1 then
                    return 0
                end
                r1 = unicode.SimpleFold(r1)
            end
        end
        return syntax.noMatch
    elseif n == 2 then
        if r >= rune[1] and r <= rune[2] then
            return 0
        end
        return syntax.noMatch
    elseif n == 4 or n == 6 or n == 8 then
        -- Linear search for a few pairs.
        -- Should handle ASCII well.
        for j = 0, n - 1, 2 do
            if r < rune[j + 1] then
                return syntax.noMatch
            end
            if r <= rune[j + 2] then
                return j // 2
            end
        end
        return syntax.noMatch
    end

    -- Otherwise binary search.
    local lo = 0
    local hi = n // 2
    while lo < hi do
        local m = (lo + hi) >> 1
        local c = rune[2 * m + 1]
        if c <= r then
            if r <= rune[2 * m + 2] then
                return m
            end
            lo = m + 1
        else
            hi = m
        end
    end
    return syntax.noMatch
end

-- MatchEmptyWidth reports whether the instruction matches
-- an empty string between the runes before and after.
-- It should only be called when i.Op == [InstEmptyWidth].
function Inst:MatchEmptyWidth(before, after)
    local op = self.arg & 0xFF
    if op == EmptyOp.EmptyBeginLine then
        return before == 0x0A or before == -1
    elseif op == EmptyOp.EmptyEndLine then
        return after == 0x0A or after == -1
    elseif op == EmptyOp.EmptyBeginText then
        return before == -1
    elseif op == EmptyOp.EmptyEndText then
        return after == -1
    elseif op == EmptyOp.EmptyWordBoundary then
        return syntax.IsWordChar(before) ~= syntax.IsWordChar(after)
    elseif op == EmptyOp.EmptyNoWordBoundary then
        return syntax.IsWordChar(before) == syntax.IsWordChar(after)
    end
    error("unknown empty width arg", 0)
end

function Inst:String()
    local b = {}
    syntax.dumpInst(b, self)
    return table.concat(b)
end

function syntax.bw(b, ...)
    for _, s in ipairs({ ... }) do
        b[#b + 1] = s
    end
end

function syntax.dumpProg(b, p)
    for j1, i in ipairs(p.inst) do
        local j = j1 - 1
        local pc = strconv.Itoa(j)
        if #pc < 3 then
            b[#b + 1] = string.sub("   ", #pc + 1)
        end
        if j == p.start then
            pc = pc .. "*"
        end
        syntax.bw(b, pc, "\t")
        syntax.dumpInst(b, i)
        syntax.bw(b, "\n")
    end
end

function syntax.u32(i)
    return strconv.FormatUint(i, 10)
end

function syntax.dumpInst(b, i)
    local op = i.op
    if op == InstOp.InstAlt then
        syntax.bw(b, "alt -> ", syntax.u32(i.out), ", ", syntax.u32(i.arg))
    elseif op == InstOp.InstAltMatch then
        syntax.bw(b, "altmatch -> ", syntax.u32(i.out), ", ", syntax.u32(i.arg))
    elseif op == InstOp.InstCapture then
        syntax.bw(b, "cap ", syntax.u32(i.arg), " -> ", syntax.u32(i.out))
    elseif op == InstOp.InstEmptyWidth then
        syntax.bw(b, "empty ", syntax.u32(i.arg), " -> ", syntax.u32(i.out))
    elseif op == InstOp.InstMatch then
        syntax.bw(b, "match")
    elseif op == InstOp.InstFail then
        syntax.bw(b, "fail")
    elseif op == InstOp.InstNop then
        syntax.bw(b, "nop -> ", syntax.u32(i.out))
    elseif op == InstOp.InstRune then
        if i.rune == nil then
            -- shouldn't happen
            syntax.bw(b, "rune <nil>")
        end
        syntax.bw(b, "rune ", strconv.QuoteToASCII(utf8.RunesToString(i.rune)))
        if i.arg & Flags.FoldCase ~= 0 then
            syntax.bw(b, "/i")
        end
        syntax.bw(b, " -> ", syntax.u32(i.out))
    elseif op == InstOp.InstRune1 then
        syntax.bw(b, "rune1 ", strconv.QuoteToASCII(utf8.RunesToString(i.rune)), " -> ", syntax.u32(i.out))
    elseif op == InstOp.InstRuneAny then
        syntax.bw(b, "any -> ", syntax.u32(i.out))
    elseif op == InstOp.InstRuneAnyNotNL then
        syntax.bw(b, "anynotnl -> ", syntax.u32(i.out))
    end
end
