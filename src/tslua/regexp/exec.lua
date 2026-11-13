local regexp = require("tslua.regexp")
local syntax = require("tslua.regexp.syntax")

local InstOp = syntax.InstOp
local EmptyOp = syntax.EmptyOp

-- A queue is a 'sparse array' holding pending threads of execution.
-- See https://research.swtch.com/2008/03/using-uninitialized-memory-for-fun-and.html
-- (Fields: sparse (pc -> dense index; missing entries read as garbage), dense (array of
-- entries, reused beyond the length n), n (Go len(dense)).)
local function newQueue()
    return { sparse = {}, dense = {}, n = 0 }
end

-- An entry is an entry on a queue.
-- It holds both the instruction pc and the actual thread.
-- Some queue entries are just place holders so that the machine
-- knows it has considered that pc. Such entries have t == nil.
-- (Fields: pc, t.)

-- A thread is the state of a single path through the machine:
-- an instruction and a corresponding capture array.
-- See https://swtch.com/~rsc/regexp/regexp2.html
-- (Fields: inst, cap.)

-- A machine holds all the state during an NFA simulation for p.
local machine = {}
machine.__index = machine
regexp.machine = machine

function regexp.newMachine()
    return setmetatable({
        re = nil, -- corresponding Regexp
        p = nil, -- compiled program
        q0 = newQueue(), -- two queues for runq, nextq
        q1 = newQueue(),
        pool = {}, -- pool of available threads
        matched = false, -- whether a match was found
        matchcap = {}, -- capture information for the match
        inputs = regexp.newInputs(),
    }, machine)
end

local inputs = {}
inputs.__index = inputs
regexp.inputs = inputs

function regexp.newInputs()
    return setmetatable({
        -- cached inputs, to avoid allocation
        bytes = regexp.newInputBytes(nil),
        string = regexp.newInputString(""),
        reader = regexp.newInputReader(nil),
    }, inputs)
end

function inputs:newBytes(b)
    self.bytes.str = b
    return self.bytes
end

function inputs:newString(s)
    self.string.str = s
    return self.string
end

function inputs:newReader(r)
    self.reader.r = r
    self.reader.atEOT = false
    self.reader.pos = 0
    return self.reader
end

function inputs:clear()
    -- We need to clear 1 of these.
    -- Avoid the expense of clearing the others (pointer write barrier).
    if self.bytes.str ~= nil then
        self.bytes.str = nil
    elseif self.reader.r ~= nil then
        self.reader.r = nil
    else
        self.string.str = ""
    end
end

function inputs:init(r, b, s)
    if r ~= nil then
        return self:newReader(r), 0
    end
    if b ~= nil then
        return self:newBytes(b), #b
    end
    return self:newString(s), #s
end

-- Resize the Lua array xs to n elements (Go xs[:n] within capacity).
local function resize(xs, n)
    for i = #xs, n + 1, -1 do
        xs[i] = nil
    end
    for i = #xs + 1, n do
        xs[i] = 0
    end
end

function machine:init(ncap)
    for _, t in ipairs(self.pool) do
        resize(t.cap, ncap)
    end
    resize(self.matchcap, ncap)
end

-- alloc allocates a new thread with the given instruction.
-- It uses the free pool if possible.
function machine:alloc(i)
    local t
    local n = #self.pool
    if n > 0 then
        t = self.pool[n]
        self.pool[n] = nil
    else
        t = { inst = nil, cap = {} }
        for k = 1, #self.matchcap do
            t.cap[k] = 0
        end
    end
    t.inst = i
    return t
end

-- A lazyFlag is a lazily-evaluated syntax.EmptyOp,
-- for checking zero-width flags like ^ $ \A \z \B \b.
-- It records the pair of relevant runes and does not
-- determine the implied flags until absolutely necessary
-- (most of the time, that means never).
function regexp.newLazyFlag(r1, r2)
    return (r1 << 32) | (r2 & 0xFFFFFFFF)
end

-- Go rune(x) for the low 32 bits of x.
local function toRune(x)
    x = x & 0xFFFFFFFF
    if x >= 0x80000000 then
        return x - 0x100000000
    end
    return x
end

function regexp.lazyFlag_match(f, op)
    if op == 0 then
        return true
    end
    local r1 = toRune(f >> 32)
    if op & EmptyOp.EmptyBeginLine ~= 0 then
        if r1 ~= 0x0A and r1 >= 0 then
            return false
        end
        op = op & ~EmptyOp.EmptyBeginLine
    end
    if op & EmptyOp.EmptyBeginText ~= 0 then
        if r1 >= 0 then
            return false
        end
        op = op & ~EmptyOp.EmptyBeginText
    end
    if op == 0 then
        return true
    end
    local r2 = toRune(f)
    if op & EmptyOp.EmptyEndLine ~= 0 then
        if r2 ~= 0x0A and r2 >= 0 then
            return false
        end
        op = op & ~EmptyOp.EmptyEndLine
    end
    if op & EmptyOp.EmptyEndText ~= 0 then
        if r2 >= 0 then
            return false
        end
        op = op & ~EmptyOp.EmptyEndText
    end
    if op == 0 then
        return true
    end
    if syntax.IsWordChar(r1) ~= syntax.IsWordChar(r2) then
        op = op & ~EmptyOp.EmptyWordBoundary
    else
        op = op & ~EmptyOp.EmptyNoWordBoundary
    end
    return op == 0
end

-- match runs the machine over the input starting at pos.
-- It reports whether a match was found.
-- If so, m.matchcap holds the submatch information.
function machine:match(i, pos)
    local startCond = self.re.cond
    if startCond == 0xFF then -- impossible
        return false
    end
    self.matched = false
    for k = 1, #self.matchcap do
        self.matchcap[k] = -1
    end
    local runq, nextq = self.q0, self.q1
    local r, r1 = regexp.endOfText, regexp.endOfText
    local width, width1 = 0, 0
    r, width = i:step(pos)
    if r ~= regexp.endOfText then
        r1, width1 = i:step(pos + width)
    end
    local flag
    if pos == 0 then
        flag = regexp.newLazyFlag(-1, r)
    else
        flag = i:context(pos)
    end
    while true do
        if runq.n == 0 then
            if startCond & EmptyOp.EmptyBeginText ~= 0 and pos ~= 0 then
                -- Anchored match, past beginning of text.
                break
            end
            if self.matched then
                -- Have match; finished exploring alternatives.
                break
            end
            if #self.re.prefix > 0 and r1 ~= self.re.prefixRune and i:canCheckPrefix() then
                -- Match requires literal prefix; fast search for it.
                local advance = i:index(self.re, pos)
                if advance < 0 then
                    break
                end
                pos = pos + advance
                r, width = i:step(pos)
                r1, width1 = i:step(pos + width)
            end
        end
        if not self.matched then
            if #self.matchcap > 0 then
                self.matchcap[1] = pos
            end
            self:add(runq, self.p.start, pos, self.matchcap, flag, nil)
        end
        flag = regexp.newLazyFlag(r, r1)
        self:step(runq, nextq, pos, pos + width, r, flag)
        if width == 0 then
            break
        end
        if #self.matchcap == 0 and self.matched then
            -- Found a match and not paying attention
            -- to where it is, so any match will do.
            break
        end
        pos = pos + width
        r, width = r1, width1
        if r ~= regexp.endOfText then
            r1, width1 = i:step(pos + width)
        end
        runq, nextq = nextq, runq
    end
    self:clear(nextq)
    return self.matched
end

-- clear frees all threads on the thread queue.
function machine:clear(q)
    for k = 1, q.n do
        local d = q.dense[k]
        if d.t ~= nil then
            self.pool[#self.pool + 1] = d.t
        end
    end
    q.n = 0
end

-- step executes one step of the machine, running each of the threads
-- on runq and appending new threads to nextq.
-- The step processes the rune c (which may be endOfText),
-- which starts at position pos and ends at nextPos.
-- nextCond gives the setting for the empty-width flags after c.
function machine:step(runq, nextq, pos, nextPos, c, nextCond)
    local longest = self.re.longest
    local j = 0
    while j < runq.n do
        local d = runq.dense[j + 1]
        local t = d.t
        if t ~= nil then
            if longest and self.matched and #t.cap > 0 and self.matchcap[1] < t.cap[1] then
                self.pool[#self.pool + 1] = t
                goto continue
            end
            local i = t.inst
            local add = false
            local op = i.op
            if op == InstOp.InstMatch then
                if #t.cap > 0 and (not longest or not self.matched or self.matchcap[2] < pos) then
                    t.cap[2] = pos
                    for k = 1, math.min(#self.matchcap, #t.cap) do
                        self.matchcap[k] = t.cap[k]
                    end
                end
                if not longest then
                    -- First-match mode: cut off all lower-priority threads.
                    for k = j + 2, runq.n do
                        local d2 = runq.dense[k]
                        if d2.t ~= nil then
                            self.pool[#self.pool + 1] = d2.t
                        end
                    end
                    runq.n = 0
                end
                self.matched = true
            elseif op == InstOp.InstRune then
                add = i:MatchRune(c)
            elseif op == InstOp.InstRune1 then
                add = c == i.rune[1]
            elseif op == InstOp.InstRuneAny then
                add = true
            elseif op == InstOp.InstRuneAnyNotNL then
                add = c ~= 0x0A
            else
                error("bad inst", 0)
            end
            if add then
                t = self:add(nextq, i.out, nextPos, t.cap, nextCond, t)
            end
            if t ~= nil then
                self.pool[#self.pool + 1] = t
            end
        end
        ::continue::
        j = j + 1
    end
    runq.n = 0
end

-- add adds an entry to q for pc, unless the q already has such an entry.
-- It also recursively adds an entry for all instructions reachable from pc by following
-- empty-width conditions satisfied by cond.  pos gives the current position
-- in the input.
function machine:add(q, pc, pos, cap, cond, t)
    while true do
        if pc == 0 then
            return t
        end
        local j = q.sparse[pc]
        if j ~= nil and j < q.n and q.dense[j + 1].pc == pc then
            return t
        end

        j = q.n
        q.n = j + 1
        local d = q.dense[j + 1]
        if d == nil then
            d = { pc = 0, t = nil }
            q.dense[j + 1] = d
        end
        d.t = nil
        d.pc = pc
        q.sparse[pc] = j

        local i = self.p.inst[pc + 1]
        local op = i.op
        if op == InstOp.InstFail then
            -- nothing
            return t
        elseif op == InstOp.InstAlt or op == InstOp.InstAltMatch then
            t = self:add(q, i.out, pos, cap, cond, t)
            pc = i.arg
            -- goto Again
        elseif op == InstOp.InstEmptyWidth then
            if regexp.lazyFlag_match(cond, i.arg & 0xFF) then
                pc = i.out
                -- goto Again
            else
                return t
            end
        elseif op == InstOp.InstNop then
            pc = i.out
            -- goto Again
        elseif op == InstOp.InstCapture then
            if i.arg < #cap then
                local opos = cap[i.arg + 1]
                cap[i.arg + 1] = pos
                self:add(q, i.out, pos, cap, cond, nil)
                cap[i.arg + 1] = opos
                return t
            else
                pc = i.out
                -- goto Again
            end
        elseif op == InstOp.InstMatch or op == InstOp.InstRune or op == InstOp.InstRune1 or op == InstOp.InstRuneAny or op == InstOp.InstRuneAnyNotNL then
            if t == nil then
                t = self:alloc(i)
            else
                t.inst = i
            end
            if #cap > 0 and t.cap ~= cap then
                for k = 1, math.min(#t.cap, #cap) do
                    t.cap[k] = cap[k]
                end
            end
            d.t = t
            t = nil
            return t
        else
            error("unhandled", 0)
        end
    end
end

-- doOnePass implements r.doExecute using the one-pass execution engine.
function regexp.Regexp:doOnePass(ir, ib, is, pos, ncap, dstCap)
    local re = self
    local startCond = re.cond
    if startCond == 0xFF then -- impossible
        return nil
    end

    -- (onePassMachine: Go's sync.Pool may always return a fresh value; this port always does.)
    local m = { inputs = regexp.newInputs(), matchcap = {} }
    for k = 1, ncap do
        m.matchcap[k] = -1
    end

    local matched = false

    local i = m.inputs:init(ir, ib, is)

    local r, r1 = regexp.endOfText, regexp.endOfText
    local width, width1 = 0, 0
    r, width = i:step(pos)
    if r ~= regexp.endOfText then
        r1, width1 = i:step(pos + width)
    end
    local flag
    if pos == 0 then
        flag = regexp.newLazyFlag(-1, r)
    else
        flag = i:context(pos)
    end
    local pc = re.onepass.start
    local inst = re.onepass.inst[pc + 1]
    -- If there is a simple literal prefix, skip over it.
    if pos == 0 and regexp.lazyFlag_match(flag, inst.arg & 0xFF) and
        #re.prefix > 0 and i:canCheckPrefix() then
        -- Match requires literal prefix; fast search for it.
        if not i:hasPrefix(re) then
            goto Return
        end
        pos = pos + #re.prefix
        r, width = i:step(pos)
        r1, width1 = i:step(pos + width)
        flag = i:context(pos)
        pc = re.prefixEnd
    end
    while true do
        inst = re.onepass.inst[pc + 1]
        pc = inst.out
        local op = inst.op
        if op == InstOp.InstMatch then
            matched = true
            if #m.matchcap > 0 then
                m.matchcap[1] = 0
                m.matchcap[2] = pos
            end
            goto Return
        elseif op == InstOp.InstRune then
            if not inst:MatchRune(r) then
                goto Return
            end
        elseif op == InstOp.InstRune1 then
            if r ~= inst.rune[1] then
                goto Return
            end
        elseif op == InstOp.InstRuneAny then
            -- Nothing
        elseif op == InstOp.InstRuneAnyNotNL then
            if r == 0x0A then
                goto Return
            end
            -- peek at the input rune to see which branch of the Alt to take
        elseif op == InstOp.InstAlt or op == InstOp.InstAltMatch then
            pc = regexp.onePassNext(inst, r)
            goto continue
        elseif op == InstOp.InstFail then
            goto Return
        elseif op == InstOp.InstNop then
            goto continue
        elseif op == InstOp.InstEmptyWidth then
            if not regexp.lazyFlag_match(flag, inst.arg & 0xFF) then
                goto Return
            end
            goto continue
        elseif op == InstOp.InstCapture then
            if inst.arg < #m.matchcap then
                m.matchcap[inst.arg + 1] = pos
            end
            goto continue
        else
            error("bad inst", 0)
        end
        if width == 0 then
            break
        end
        flag = regexp.newLazyFlag(r, r1)
        pos = pos + width
        r, width = r1, width1
        if r ~= regexp.endOfText then
            r1, width1 = i:step(pos + width)
        end
        ::continue::
    end

    ::Return::
    if not matched then
        m.inputs:clear()
        return nil
    end

    for _, v in ipairs(m.matchcap) do
        dstCap[#dstCap + 1] = v
    end
    m.inputs:clear()
    return dstCap
end


-- doMatch reports whether either r, b or s match the regexp.
function regexp.Regexp:doMatch(r, b, s)
    return self:doExecute(r, b, s, 0, 0, nil) ~= nil
end

-- doExecute finds the leftmost match in the input, appends the position
-- of its subexpressions to dstCap and returns dstCap.
--
-- nil is returned if no matches are found and non-nil if matches are found.
function regexp.Regexp:doExecute(r, b, s, pos, ncap, dstCap)
    if dstCap == nil then
        -- Make sure 'return dstCap' is non-nil.
        dstCap = {}
    end

    if r == nil and #(b or "") + #s < self.minInputLen then
        return nil
    end

    if self.onepass ~= nil then
        return self:doOnePass(r, b, s, pos, ncap, dstCap)
    end
    if r == nil and #(b or "") + #s < self.maxBitStateLen then
        return self:backtrack(b, s, pos, ncap, dstCap)
    end

    local m = self:get()
    local i = m.inputs:init(r, b, s)

    m:init(ncap)
    if not m:match(i, pos) then
        self:put(m)
        return nil
    end

    for _, v in ipairs(m.matchcap) do
        dstCap[#dstCap + 1] = v
    end
    self:put(m)
    return dstCap
end
