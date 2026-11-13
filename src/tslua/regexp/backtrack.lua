-- backtrack is a regular expression search with submatch
-- tracking for small regular expressions and texts. It allocates
-- a bit vector with (length of input) * (length of prog) bits,
-- to make sure it never explores the same (character position, instruction)
-- state multiple times. This limits the search to run in time linear in
-- the length of the test.
--
-- backtrack is a fast replacement for the NFA code on small
-- regexps when onepass cannot be used.
local regexp = require("tslua.regexp")
local syntax = require("tslua.regexp.syntax")

local InstOp = syntax.InstOp
local EmptyOp = syntax.EmptyOp

-- A job is an entry on the backtracker's job stack. It holds
-- the instruction pc and the position in the input.
-- (The job stack is stored as parallel arrays jobsPc, jobsArg, jobsPos of length njobs.)

regexp.visitedBits = 32
regexp.maxBacktrackProg = 500 -- len(prog.Inst) <= max
regexp.maxBacktrackVector = 256 * 1024 -- bit vector size <= max (bits)

-- bitState holds state for the backtracker.
local bitState = {}
bitState.__index = bitState
regexp.bitState = bitState

-- (Go's sync.Pool may always return a fresh value; this port always does.)
function regexp.newBitState()
    return setmetatable({
        end_ = 0,
        cap = {},
        matchcap = {},
        jobsPc = {},
        jobsArg = {},
        jobsPos = {},
        njobs = 0,
        visited = {}, -- missing words are 0
        inputs = regexp.newInputs(),
    }, bitState)
end

function regexp.freeBitState(b)
    b.inputs:clear()
end

-- maxBitStateLen returns the maximum length of a string to search with
-- the backtracker using prog.
function regexp.maxBitStateLen(prog)
    if not regexp.shouldBacktrack(prog) then
        return 0
    end
    return regexp.maxBacktrackVector // #prog.inst
end

-- shouldBacktrack reports whether the program is too
-- long for the backtracker to run.
function regexp.shouldBacktrack(prog)
    return #prog.inst <= regexp.maxBacktrackProg
end

-- reset resets the state of the backtracker.
-- end is the end position in the input.
-- ncap is the number of captures.
function bitState:reset(prog, end_, ncap)
    self.end_ = end_
    self.njobs = 0
    self.visited = {}

    self.cap = {}
    for i = 1, ncap do
        self.cap[i] = -1
    end
    self.matchcap = {}
    for i = 1, ncap do
        self.matchcap[i] = -1
    end
end

-- shouldVisit reports whether the combination of (pc, pos) has not
-- been visited yet.
function bitState:shouldVisit(pc, pos)
    local n = pc * (self.end_ + 1) + pos
    local w = n // regexp.visitedBits + 1
    local bit = 1 << (n & (regexp.visitedBits - 1))
    local word = self.visited[w] or 0
    if word & bit ~= 0 then
        return false
    end
    self.visited[w] = word | bit
    return true
end

-- push pushes (pc, pos, arg) onto the job stack if it should be
-- visited.
function bitState:push(re, pc, pos, arg)
    -- Only check shouldVisit when arg is false.
    -- When arg is true, we are continuing a previous visit.
    if re.prog.inst[pc + 1].op ~= InstOp.InstFail and (arg or self:shouldVisit(pc, pos)) then
        local n = self.njobs + 1
        self.jobsPc[n] = pc
        self.jobsArg[n] = arg
        self.jobsPos[n] = pos
        self.njobs = n
    end
end

-- tryBacktrack runs a backtracking search starting at pos.
function regexp.Regexp:tryBacktrack(b, i, pc, pos)
    local re = self
    local longest = re.longest
    local inst_ = re.prog.inst

    b:push(re, pc, pos, false)
    while b.njobs > 0 do
        local l = b.njobs
        -- Pop job off the stack.
        pc = b.jobsPc[l]
        pos = b.jobsPos[l]
        local arg = b.jobsArg[l]
        b.njobs = l - 1

        -- Optimization: rather than push and pop,
        -- code that is going to Push and continue
        -- the loop simply updates ip, p, and arg
        -- and jumps to CheckAndLoop. We have to
        -- do the ShouldVisit check that Push
        -- would have, but we avoid the stack
        -- manipulation.
        local skip = true -- goto Skip
        while true do
            -- CheckAndLoop:
            if not skip and not b:shouldVisit(pc, pos) then
                break -- continue
            end
            skip = false
            -- Skip:
            local inst = inst_[pc + 1]

            local op = inst.op
            if op == InstOp.InstFail then
                error("unexpected InstFail", 0)
            elseif op == InstOp.InstAlt then
                -- Cannot just
                --   b.push(inst.Out, pos, false)
                --   b.push(inst.Arg, pos, false)
                -- If during the processing of inst.Out, we encounter
                -- inst.Arg via another path, we want to process it then.
                -- Pushing it here will inhibit that. Instead, re-push
                -- inst with arg==true as a reminder to push inst.Arg out
                -- later.
                if arg then
                    -- Finished inst.Out; try inst.Arg.
                    arg = false
                    pc = inst.arg
                else
                    b:push(re, pc, pos, true)
                    pc = inst.out
                end
            elseif op == InstOp.InstAltMatch then
                -- One opcode consumes runes; the other leads to match.
                local outOp = inst_[inst.out + 1].op
                if outOp == InstOp.InstRune or outOp == InstOp.InstRune1 or outOp == InstOp.InstRuneAny or outOp == InstOp.InstRuneAnyNotNL then
                    -- inst.Arg is the match.
                    b:push(re, inst.arg, pos, false)
                    pc = inst.arg
                    pos = b.end_
                else
                    -- inst.Out is the match - non-greedy
                    b:push(re, inst.out, b.end_, false)
                    pc = inst.out
                end
            elseif op == InstOp.InstRune then
                local r, width = i:step(pos)
                if not inst:MatchRune(r) then
                    break -- continue
                end
                pos = pos + width
                pc = inst.out
            elseif op == InstOp.InstRune1 then
                local r, width = i:step(pos)
                if r ~= inst.rune[1] then
                    break -- continue
                end
                pos = pos + width
                pc = inst.out
            elseif op == InstOp.InstRuneAnyNotNL then
                local r, width = i:step(pos)
                if r == 0x0A or r == regexp.endOfText then
                    break -- continue
                end
                pos = pos + width
                pc = inst.out
            elseif op == InstOp.InstRuneAny then
                local r, width = i:step(pos)
                if r == regexp.endOfText then
                    break -- continue
                end
                pos = pos + width
                pc = inst.out
            elseif op == InstOp.InstCapture then
                if arg then
                    -- Finished inst.Out; restore the old value.
                    b.cap[inst.arg + 1] = pos
                    break -- continue
                else
                    if inst.arg < #b.cap then
                        -- Capture pos to register, but save old value.
                        b:push(re, pc, b.cap[inst.arg + 1], true) -- come back when we're done.
                        b.cap[inst.arg + 1] = pos
                    end
                    pc = inst.out
                end
            elseif op == InstOp.InstEmptyWidth then
                local flag = i:context(pos)
                if not regexp.lazyFlag_match(flag, inst.arg & 0xFF) then
                    break -- continue
                end
                pc = inst.out
            elseif op == InstOp.InstNop then
                pc = inst.out
            elseif op == InstOp.InstMatch then
                -- We found a match. If the caller doesn't care
                -- where the match is, no point going further.
                if #b.cap == 0 then
                    return true
                end

                -- Record best match so far.
                -- Only need to check end point, because this entire
                -- call is only considering one start position.
                if #b.cap > 1 then
                    b.cap[2] = pos
                end
                local old = b.matchcap[2]
                if old == -1 or (longest and pos > 0 and pos > old) then
                    for k = 1, math.min(#b.matchcap, #b.cap) do
                        b.matchcap[k] = b.cap[k]
                    end
                end

                -- If going for first match, we're done.
                if not longest then
                    return true
                end

                -- If we used the entire text, no longer match is possible.
                if pos == b.end_ then
                    return true
                end

                -- Otherwise, continue on in hope of a longer match.
                break -- continue
            else
                error("bad inst", 0)
            end
        end
    end

    return longest and #b.matchcap > 1 and b.matchcap[2] >= 0
end

-- backtrack runs a backtracking search of prog on the input starting at pos.
function regexp.Regexp:backtrack(ib, is, pos, ncap, dstCap)
    local re = self
    local startCond = re.cond
    if startCond == 0xFF then -- impossible
        return nil
    end
    if startCond & EmptyOp.EmptyBeginText ~= 0 and pos ~= 0 then
        -- Anchored match, past beginning of text.
        return nil
    end

    local b = regexp.newBitState()
    local i, end_ = b.inputs:init(nil, ib, is)
    b:reset(re.prog, end_, ncap)

    -- Anchored search must start at the beginning of the input
    if startCond & EmptyOp.EmptyBeginText ~= 0 then
        if #b.cap > 0 then
            b.cap[1] = pos
        end
        if not re:tryBacktrack(b, i, re.prog.start, pos) then
            regexp.freeBitState(b)
            return nil
        end
    else
        -- Unanchored search, starting from each possible text position.
        -- Notice that we have to try the empty string at the end of
        -- the text, so the loop condition is pos <= end, not pos < end.
        -- This looks like it's quadratic in the size of the text,
        -- but we are not clearing visited between calls to TrySearch,
        -- so no work is duplicated and it ends up still being linear.
        local width = -1
        local found = false
        while pos <= end_ and width ~= 0 do
            if #re.prefix > 0 then
                -- Match requires literal prefix; fast search for it.
                local advance = i:index(re, pos)
                if advance < 0 then
                    regexp.freeBitState(b)
                    return nil
                end
                pos = pos + advance
            end

            if #b.cap > 0 then
                b.cap[1] = pos
            end
            if re:tryBacktrack(b, i, re.prog.start, pos) then
                -- Match must be leftmost; done.
                found = true
                break
            end
            local _
            _, width = i:step(pos)
            pos = pos + width
        end
        if not found then
            regexp.freeBitState(b)
            return nil
        end
    end

    for _, v in ipairs(b.matchcap) do
        dstCap[#dstCap + 1] = v
    end
    regexp.freeBitState(b)
    return dstCap
end
