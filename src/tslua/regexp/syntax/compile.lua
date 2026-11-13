local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")

local Op = syntax.Op
local Flags = syntax.Flags
local InstOp = syntax.InstOp
local EmptyOp = syntax.EmptyOp

-- A patchList is a list of instruction pointers that need to be filled in (patched).
-- Because the pointers haven't been filled in yet, we can reuse their storage
-- to hold the list. It's kind of sleazy, but works well in practice.
-- See https://swtch.com/~rsc/regexp/regexp1.html for inspiration.
--
-- These aren't really pointers: they're integers, so we can reinterpret them
-- this way without using package unsafe. A value l.head denotes
-- p.inst[l.head>>1].out (l.head&1==0) or .arg (l.head&1==1).
-- head == 0 denotes the empty list, okay because we start every program
-- with a fail instruction, so we'll never want to point at its output link.
-- (patchList is a Go value struct: an immutable { head, tail } table.)
function syntax.makePatchList(n)
    return { head = n, tail = n }
end

function syntax.patchList_patch(l, p, val)
    local head = l.head
    while head ~= 0 do
        local i = p.inst[(head >> 1) + 1]
        if head & 1 == 0 then
            head = i.out
            i.out = val
        else
            head = i.arg
            i.arg = val
        end
    end
end

function syntax.patchList_append(l1, p, l2)
    if l1.head == 0 then
        return l2
    end
    if l2.head == 0 then
        return l1
    end

    local i = p.inst[(l1.tail >> 1) + 1]
    if l1.tail & 1 == 0 then
        i.out = l2.head
    else
        i.arg = l2.head
    end
    return { head = l1.head, tail = l2.tail }
end

-- A frag represents a compiled program fragment.
-- Fields: i (index of first instruction), out (where to record end instruction),
-- nullable (whether fragment can match empty string).
local function newFrag(i, out, nullable)
    return { i = i or 0, out = out or { head = 0, tail = 0 }, nullable = nullable or false }
end

local compiler = {}
compiler.__index = compiler
syntax.compiler = compiler

-- Compile compiles the regexp into a program to be executed.
-- The regexp should have been simplified already (returned from re.Simplify).
function syntax.Compile(re)
    local c = setmetatable({ p = nil }, compiler)
    c:init()
    local f = c:compile(re)
    syntax.patchList_patch(f.out, c.p, c:inst(InstOp.InstMatch).i)
    c.p.start = f.i
    return c.p, nil
end

function compiler:init()
    self.p = syntax.newProg()
    self.p.numCap = 2 -- implicit ( and ) for whole match $0
    self:inst(InstOp.InstFail)
end

syntax.anyRuneNotNL = { 0, 0x0A - 1, 0x0A + 1, unicode.MaxRune }
syntax.anyRune = { 0, unicode.MaxRune }

function compiler:compile(re)
    local op = re.op
    if op == Op.NoMatch then
        return self:fail()
    elseif op == Op.EmptyMatch then
        return self:nop()
    elseif op == Op.Literal then
        local rs = re.rune or {}
        if #rs == 0 then
            return self:nop()
        end
        local f
        for j = 0, #rs - 1 do
            local f1 = self:rune({ rs[j + 1] }, re.flags)
            if j == 0 then
                f = f1
            else
                f = self:cat(f, f1)
            end
        end
        return f
    elseif op == Op.CharClass then
        return self:rune(re.rune or {}, re.flags)
    elseif op == Op.AnyCharNotNL then
        return self:rune(syntax.anyRuneNotNL, 0)
    elseif op == Op.AnyChar then
        return self:rune(syntax.anyRune, 0)
    elseif op == Op.BeginLine then
        return self:empty(EmptyOp.EmptyBeginLine)
    elseif op == Op.EndLine then
        return self:empty(EmptyOp.EmptyEndLine)
    elseif op == Op.BeginText then
        return self:empty(EmptyOp.EmptyBeginText)
    elseif op == Op.EndText then
        return self:empty(EmptyOp.EmptyEndText)
    elseif op == Op.WordBoundary then
        return self:empty(EmptyOp.EmptyWordBoundary)
    elseif op == Op.NoWordBoundary then
        return self:empty(EmptyOp.EmptyNoWordBoundary)
    elseif op == Op.Capture then
        local bra = self:cap(re.cap << 1)
        local sub = self:compile(re.sub[1])
        local ket = self:cap((re.cap << 1) | 1)
        return self:cat(self:cat(bra, sub), ket)
    elseif op == Op.Star then
        return self:star(self:compile(re.sub[1]), re.flags & Flags.NonGreedy ~= 0)
    elseif op == Op.Plus then
        return self:plus(self:compile(re.sub[1]), re.flags & Flags.NonGreedy ~= 0)
    elseif op == Op.Quest then
        return self:quest(self:compile(re.sub[1]), re.flags & Flags.NonGreedy ~= 0)
    elseif op == Op.Concat then
        if #re.sub == 0 then
            return self:nop()
        end
        local f
        for i, sub in ipairs(re.sub) do
            if i == 1 then
                f = self:compile(sub)
            else
                f = self:cat(f, self:compile(sub))
            end
        end
        return f
    elseif op == Op.Alternate then
        local f = newFrag()
        for _, sub in ipairs(re.sub) do
            f = self:alt(f, self:compile(sub))
        end
        return f
    end
    error("regexp: unhandled case in compile", 0)
end

function compiler:inst(op)
    -- TODO: impose length limit
    local f = newFrag(#self.p.inst, nil, true)
    self.p.inst[#self.p.inst + 1] = syntax.newInst(op)
    return f
end

function compiler:nop()
    local f = self:inst(InstOp.InstNop)
    f.out = syntax.makePatchList(f.i << 1)
    return f
end

function compiler:fail()
    return newFrag()
end

function compiler:cap(arg)
    local f = self:inst(InstOp.InstCapture)
    f.out = syntax.makePatchList(f.i << 1)
    self.p.inst[f.i + 1].arg = arg

    if self.p.numCap < arg + 1 then
        self.p.numCap = arg + 1
    end
    return f
end

function compiler:cat(f1, f2)
    -- concat of failure is failure
    if f1.i == 0 or f2.i == 0 then
        return newFrag()
    end

    -- TODO: elide nop

    syntax.patchList_patch(f1.out, self.p, f2.i)
    return newFrag(f1.i, f2.out, f1.nullable and f2.nullable)
end

function compiler:alt(f1, f2)
    -- alt of failure is other
    if f1.i == 0 then
        return f2
    end
    if f2.i == 0 then
        return f1
    end

    local f = self:inst(InstOp.InstAlt)
    local i = self.p.inst[f.i + 1]
    i.out = f1.i
    i.arg = f2.i
    f.out = syntax.patchList_append(f1.out, self.p, f2.out)
    f.nullable = f1.nullable or f2.nullable
    return f
end

function compiler:quest(f1, nongreedy)
    local f = self:inst(InstOp.InstAlt)
    local i = self.p.inst[f.i + 1]
    if nongreedy then
        i.arg = f1.i
        f.out = syntax.makePatchList(f.i << 1)
    else
        i.out = f1.i
        f.out = syntax.makePatchList((f.i << 1) | 1)
    end
    f.out = syntax.patchList_append(f.out, self.p, f1.out)
    return f
end

-- loop returns the fragment for the main loop of a plus or star.
-- For plus, it can be used after changing the entry to f1.i.
-- For star, it can be used directly when f1 can't match an empty string.
-- (When f1 can match an empty string, f1* must be implemented as (f1+)?
-- to get the priority match order correct.)
function compiler:loop(f1, nongreedy)
    local f = self:inst(InstOp.InstAlt)
    local i = self.p.inst[f.i + 1]
    if nongreedy then
        i.arg = f1.i
        f.out = syntax.makePatchList(f.i << 1)
    else
        i.out = f1.i
        f.out = syntax.makePatchList((f.i << 1) | 1)
    end
    syntax.patchList_patch(f1.out, self.p, f.i)
    return f
end

function compiler:star(f1, nongreedy)
    if f1.nullable then
        -- Use (f1+)? to get priority match order correct.
        -- See golang.org/issue/46123.
        return self:quest(self:plus(f1, nongreedy), nongreedy)
    end
    return self:loop(f1, nongreedy)
end

function compiler:plus(f1, nongreedy)
    return newFrag(f1.i, self:loop(f1, nongreedy).out, f1.nullable)
end

function compiler:empty(op)
    local f = self:inst(InstOp.InstEmptyWidth)
    self.p.inst[f.i + 1].arg = op
    f.out = syntax.makePatchList(f.i << 1)
    return f
end

function compiler:rune(r, flags)
    local f = self:inst(InstOp.InstRune)
    f.nullable = false
    local i = self.p.inst[f.i + 1]
    i.rune = r
    flags = flags & Flags.FoldCase -- only relevant flag is FoldCase
    if #r ~= 1 or unicode.SimpleFold(r[1]) == r[1] then
        -- and sometimes not even that
        flags = flags & ~Flags.FoldCase
    end
    i.arg = flags
    f.out = syntax.makePatchList(f.i << 1)

    -- Special cases for exec machine.
    if flags & Flags.FoldCase == 0 and (#r == 1 or #r == 2 and r[1] == r[2]) then
        i.op = InstOp.InstRune1
    elseif #r == 2 and r[1] == 0 and r[2] == unicode.MaxRune then
        i.op = InstOp.InstRuneAny
    elseif #r == 4 and r[1] == 0 and r[2] == 0x0A - 1 and r[3] == 0x0A + 1 and r[4] == unicode.MaxRune then
        i.op = InstOp.InstRuneAnyNotNL
    end

    return f
end
