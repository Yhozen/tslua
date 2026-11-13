local regexp = require("tslua.regexp")
local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")
local utf8 = require("tslua.regexp.utf8")

local InstOp = syntax.InstOp
local EmptyOp = syntax.EmptyOp
local Flags = syntax.Flags

-- "One-pass" regexp execution.
-- Some regexps can be analyzed to determine that they never need
-- backtracking: they are guaranteed to run in one pass over the string
-- without bothering to save all the usual NFA state.
-- Detect those and execute them more quickly.

-- A onePassProg is a compiled one-pass regular expression program.
-- It is the same as syntax.Prog except for the use of onePassInst.
-- (Fields: inst (array; pc i is inst[i + 1]), start, numCap.)

-- A onePassInst is a single instruction in a one-pass regular expression program.
-- It is the same as syntax.Inst except for the new 'Next' field.
-- (syntax.Inst is embedded: the fields op, out, arg, rune live on the table and the
-- syntax.Inst methods are inherited.)
local onePassInst = setmetatable({}, { __index = syntax.Inst })
onePassInst.__index = onePassInst
regexp.onePassInst = onePassInst

-- Go onePassInst{Inst: inst}.
function regexp.newOnePassInst(inst)
    return setmetatable({ op = inst.op, out = inst.out, arg = inst.arg, rune = inst.rune, next = nil }, onePassInst)
end

-- onePassPrefix returns a literal string that all matches for the
-- regexp must start with. Complete is true if the prefix
-- is the entire match. Pc is the index of the last rune instruction
-- in the string. The onePassPrefix skips over the mandatory
-- EmptyBeginText.
function regexp.onePassPrefix(p)
    local i = p.inst[p.start + 1]
    if i.op ~= InstOp.InstEmptyWidth or (i.arg & 0xFF) & EmptyOp.EmptyBeginText == 0 then
        return "", i.op == InstOp.InstMatch, p.start
    end
    local pc = i.out
    i = p.inst[pc + 1]
    while i.op == InstOp.InstNop do
        pc = i.out
        i = p.inst[pc + 1]
    end
    -- Avoid allocation of buffer if prefix is empty.
    if regexp.iop(i) ~= InstOp.InstRune or #(i.rune or {}) ~= 1 then
        return "", i.op == InstOp.InstMatch, p.start
    end

    -- Have prefix; gather characters.
    local buf = {}
    while regexp.iop(i) == InstOp.InstRune and #(i.rune or {}) == 1 and i.arg & Flags.FoldCase == 0 and i.rune[1] ~= utf8.RuneError do
        buf[#buf + 1] = utf8.EncodeRune(i.rune[1])
        pc, i = i.out, p.inst[i.out + 1]
    end
    local complete = false
    if i.op == InstOp.InstEmptyWidth and
        (i.arg & 0xFF) & EmptyOp.EmptyEndText ~= 0 and
        p.inst[i.out + 1].op == InstOp.InstMatch then
        complete = true
    end
    return table.concat(buf), complete, pc
end

-- onePassNext selects the next actionable state of the prog, based on the input character.
-- It should only be called when i.Op == InstAlt or InstAltMatch, and from the one-pass machine.
-- One of the alternates may ultimately lead without input to end of line. If the instruction
-- is InstAltMatch the path to the InstMatch is in i.Out, the normal node in i.Next.
function regexp.onePassNext(i, r)
    local next = i:MatchRunePos(r)
    if next >= 0 then
        return i.next[next + 1]
    end
    if i.op == InstOp.InstAltMatch then
        return i.out
    end
    return 0
end

function regexp.iop(i)
    local op = i.op
    if op == InstOp.InstRune1 or op == InstOp.InstRuneAny or op == InstOp.InstRuneAnyNotNL then
        op = InstOp.InstRune
    end
    return op
end

-- Sparse Array implementation is used as a queueOnePass.
local queueOnePass = {}
queueOnePass.__index = queueOnePass
regexp.queueOnePass = queueOnePass

function queueOnePass:empty()
    return self.nextIndex >= self.size
end

function queueOnePass:next()
    local n = self.dense[self.nextIndex + 1]
    self.nextIndex = self.nextIndex + 1
    return n
end

function queueOnePass:clear()
    self.size = 0
    self.nextIndex = 0
end

function queueOnePass:contains(u)
    if u >= self.len then
        return false
    end
    local s = self.sparse[u + 1]
    return s < self.size and self.dense[s + 1] == u
end

function queueOnePass:insert(u)
    if not self:contains(u) then
        self:insertNew(u)
    end
end

function queueOnePass:insertNew(u)
    if u >= self.len then
        return
    end
    self.sparse[u + 1] = self.size
    self.dense[self.size + 1] = u
    self.size = self.size + 1
end

function regexp.newQueue(size)
    local q = setmetatable({ sparse = {}, dense = {}, size = 0, nextIndex = 0, len = size }, queueOnePass)
    for i = 1, size do
        q.sparse[i] = 0
        q.dense[i] = 0
    end
    return q
end

-- mergeRuneSets merges two non-intersecting runesets, and returns the merged result,
-- and a NextIp array. The idea is that if a rune matches the OnePassRunes at index
-- i, NextIp[i/2] is the target. If the input sets intersect, an empty runeset and a
-- NextIp array with the single element mergeFailed is returned.
-- The code assumes that both inputs contain ordered and non-intersecting rune pairs.
regexp.mergeFailed = 0xffffffff

regexp.noRune = {}
regexp.noNext = { regexp.mergeFailed }

function regexp.mergeRuneSets(leftRunes, rightRunes, leftPC, rightPC)
    leftRunes = leftRunes or {}
    rightRunes = rightRunes or {}
    local leftLen = #leftRunes
    local rightLen = #rightRunes
    if leftLen & 0x1 ~= 0 or rightLen & 0x1 ~= 0 then
        error("mergeRuneSets odd length []rune", 0)
    end
    local lx, rx = 0, 0
    local merged = {}
    local next = {}
    local ok = true
    local ix = -1
    local function extend(newLow, newArray, pc)
        if ix > 0 and newArray[newLow + 1] <= merged[ix + 1] then
            return false, newLow
        end
        merged[#merged + 1] = newArray[newLow + 1]
        merged[#merged + 1] = newArray[newLow + 2]
        newLow = newLow + 2
        ix = ix + 2
        next[#next + 1] = pc
        return true, newLow
    end

    while lx < leftLen or rx < rightLen do
        if rx >= rightLen then
            ok, lx = extend(lx, leftRunes, leftPC)
        elseif lx >= leftLen then
            ok, rx = extend(rx, rightRunes, rightPC)
        elseif rightRunes[rx + 1] < leftRunes[lx + 1] then
            ok, rx = extend(rx, rightRunes, rightPC)
        else
            ok, lx = extend(lx, leftRunes, leftPC)
        end
        if not ok then
            return regexp.noRune, regexp.noNext
        end
    end
    return merged, next
end

-- cleanupOnePass drops working memory, and restores certain shortcut instructions.
function regexp.cleanupOnePass(prog, original)
    for ix1, instOriginal in ipairs(original.inst) do
        local op = instOriginal.op
        if op == InstOp.InstAlt or op == InstOp.InstAltMatch or op == InstOp.InstRune then
            -- nothing
        elseif op == InstOp.InstCapture or op == InstOp.InstEmptyWidth or op == InstOp.InstNop or op == InstOp.InstMatch or op == InstOp.InstFail then
            prog.inst[ix1].next = nil
        elseif op == InstOp.InstRune1 or op == InstOp.InstRuneAny or op == InstOp.InstRuneAnyNotNL then
            prog.inst[ix1].next = nil
            prog.inst[ix1] = regexp.newOnePassInst(instOriginal)
        end
    end
end

-- onePassCopy creates a copy of the original Prog, as we'll be modifying it.
function regexp.onePassCopy(prog)
    local p = {
        start = prog.start,
        numCap = prog.numCap,
        inst = {},
    }
    for i1, inst in ipairs(prog.inst) do
        p.inst[i1] = regexp.newOnePassInst(inst)
    end

    -- rewrites one or more common Prog constructs that enable some otherwise
    -- non-onepass Progs to be onepass. A:BD (for example) means an InstAlt at
    -- ip A, that points to ips B & C.
    -- A:BC + B:DA => A:BC + B:CD
    -- A:BC + B:DC => A:DC + B:DC
    -- (Go field pointers are { table, key } pairs.)
    local function get(ptr)
        return ptr[1][ptr[2]]
    end
    local function set(ptr, v)
        ptr[1][ptr[2]] = v
    end
    for pc = 0, #p.inst - 1 do
        local op = p.inst[pc + 1].op
        if op == InstOp.InstAlt or op == InstOp.InstAltMatch then
            -- A:Bx + B:Ay
            local p_A_Other = { p.inst[pc + 1], "out" }
            local p_A_Alt = { p.inst[pc + 1], "arg" }
            -- make sure a target is another Alt
            local instAlt = p.inst[get(p_A_Alt) + 1]
            local instAltOp, instAltOut, instAltArg = instAlt.op, instAlt.out, instAlt.arg
            if not (instAltOp == InstOp.InstAlt or instAltOp == InstOp.InstAltMatch) then
                p_A_Alt, p_A_Other = p_A_Other, p_A_Alt
                instAlt = p.inst[get(p_A_Alt) + 1]
                instAltOp, instAltOut, instAltArg = instAlt.op, instAlt.out, instAlt.arg
                if not (instAltOp == InstOp.InstAlt or instAltOp == InstOp.InstAltMatch) then
                    goto continue
                end
            end
            do
                local instOther = p.inst[get(p_A_Other) + 1]
                -- Analyzing both legs pointing to Alts is for another day
                if instOther.op == InstOp.InstAlt or instOther.op == InstOp.InstAltMatch then
                    -- too complicated
                    goto continue
                end
                -- simple empty transition loop
                -- A:BC + B:DA => A:BC + B:DC
                local target = p.inst[get(p_A_Alt) + 1]
                local p_B_Alt = { target, "out" }
                local p_B_Other = { target, "arg" }
                local patch = false
                if instAltOut == pc then
                    patch = true
                elseif instAltArg == pc then
                    patch = true
                    p_B_Alt, p_B_Other = p_B_Other, p_B_Alt
                end
                if patch then
                    set(p_B_Alt, get(p_A_Other))
                end

                -- empty transition to common target
                -- A:BC + B:DC => A:DC + B:DC
                if get(p_A_Other) == get(p_B_Alt) then
                    set(p_A_Alt, get(p_B_Other))
                end
            end
        end
        ::continue::
    end
    return p
end

local function appendAll(dst, src)
    for _, v in ipairs(src or {}) do
        dst[#dst + 1] = v
    end
    return dst
end

local function makeNext(n, out)
    local next = {}
    for i = 1, n do
        next[i] = out
    end
    return next
end

-- makeOnePass creates a onepass Prog, if possible. It is possible if at any alt,
-- the match engine can always tell which branch to take. The routine may modify
-- p if it is turned into a onepass Prog. If it isn't possible for this to be a
-- onepass Prog, the Prog nil is returned. makeOnePass is recursive
-- to the size of the Prog.
function regexp.makeOnePass(p)
    -- If the machine is very long, it's not worth the time to check if we can use one pass.
    if #p.inst >= 1000 then
        return nil
    end

    local instQueue = regexp.newQueue(#p.inst)
    local visitQueue = regexp.newQueue(#p.inst)
    local check
    local onePassRunes = {} -- pc -> []rune (missing entries are nil)
    -- check that paths from each instruction lead to a unique next instruction
    check = function(pc, m)
        local ok = true
        local inst = p.inst[pc + 1]
        if visitQueue:contains(pc) then
            return ok
        end
        visitQueue:insert(pc)
        local op = inst.op
        if op == InstOp.InstAlt or op == InstOp.InstAltMatch then
            ok = check(inst.out, m) and check(inst.arg, m)
            -- check no-input paths to InstMatch
            local matchOut = m[inst.out + 1] == true
            local matchArg = m[inst.arg + 1] == true
            if matchOut and matchArg then
                ok = false
                return ok
            end
            -- Match on empty goes in inst.Out
            if matchArg then
                inst.out, inst.arg = inst.arg, inst.out
                matchOut, matchArg = matchArg, matchOut
            end
            if matchOut then
                m[pc + 1] = true
                inst.op = InstOp.InstAltMatch
            end

            -- build a dispatch operator from the two legs
            onePassRunes[pc + 1], inst.next = regexp.mergeRuneSets(
                onePassRunes[inst.out + 1], onePassRunes[inst.arg + 1], inst.out, inst.arg)
            if #inst.next > 0 and inst.next[1] == regexp.mergeFailed then
                ok = false
                return ok
            end
        elseif op == InstOp.InstCapture or op == InstOp.InstNop then
            ok = check(inst.out, m)
            m[pc + 1] = m[inst.out + 1] == true
            -- pass matching runes back through these no-ops.
            onePassRunes[pc + 1] = appendAll({}, onePassRunes[inst.out + 1])
            inst.next = makeNext(#onePassRunes[pc + 1] // 2 + 1, inst.out)
        elseif op == InstOp.InstEmptyWidth then
            ok = check(inst.out, m)
            m[pc + 1] = m[inst.out + 1] == true
            onePassRunes[pc + 1] = appendAll({}, onePassRunes[inst.out + 1])
            inst.next = makeNext(#onePassRunes[pc + 1] // 2 + 1, inst.out)
        elseif op == InstOp.InstMatch or op == InstOp.InstFail then
            m[pc + 1] = inst.op == InstOp.InstMatch
        elseif op == InstOp.InstRune then
            m[pc + 1] = false
            if #(inst.next or {}) > 0 then
                return ok
            end
            instQueue:insert(inst.out)
            if #(inst.rune or {}) == 0 then
                onePassRunes[pc + 1] = {}
                inst.next = { inst.out }
                return ok
            end
            local runes = {}
            if #inst.rune == 1 and inst.arg & Flags.FoldCase ~= 0 then
                local r0 = inst.rune[1]
                runes[#runes + 1] = r0
                runes[#runes + 1] = r0
                local r1 = unicode.SimpleFold(r0)
                while r1 ~= r0 do
                    runes[#runes + 1] = r1
                    runes[#runes + 1] = r1
                    r1 = unicode.SimpleFold(r1)
                end
                table.sort(runes)
            else
                appendAll(runes, inst.rune)
            end
            onePassRunes[pc + 1] = runes
            inst.next = makeNext(#onePassRunes[pc + 1] // 2 + 1, inst.out)
            inst.op = InstOp.InstRune
        elseif op == InstOp.InstRune1 then
            m[pc + 1] = false
            if #(inst.next or {}) > 0 then
                return ok
            end
            instQueue:insert(inst.out)
            local runes = {}
            -- expand case-folded runes
            if inst.arg & Flags.FoldCase ~= 0 then
                local r0 = inst.rune[1]
                runes[#runes + 1] = r0
                runes[#runes + 1] = r0
                local r1 = unicode.SimpleFold(r0)
                while r1 ~= r0 do
                    runes[#runes + 1] = r1
                    runes[#runes + 1] = r1
                    r1 = unicode.SimpleFold(r1)
                end
                table.sort(runes)
            else
                runes[#runes + 1] = inst.rune[1]
                runes[#runes + 1] = inst.rune[1]
            end
            onePassRunes[pc + 1] = runes
            inst.next = makeNext(#onePassRunes[pc + 1] // 2 + 1, inst.out)
            inst.op = InstOp.InstRune
        elseif op == InstOp.InstRuneAny then
            m[pc + 1] = false
            if #(inst.next or {}) > 0 then
                return ok
            end
            instQueue:insert(inst.out)
            onePassRunes[pc + 1] = appendAll({}, syntax.anyRune)
            inst.next = { inst.out }
        elseif op == InstOp.InstRuneAnyNotNL then
            m[pc + 1] = false
            if #(inst.next or {}) > 0 then
                return ok
            end
            instQueue:insert(inst.out)
            onePassRunes[pc + 1] = appendAll({}, syntax.anyRuneNotNL)
            inst.next = makeNext(#onePassRunes[pc + 1] // 2 + 1, inst.out)
        end
        return ok
    end

    instQueue:clear()
    instQueue:insert(p.start)
    local m = {}
    while not instQueue:empty() do
        visitQueue:clear()
        local pc = instQueue:next()
        if not check(pc, m) then
            p = nil
            break
        end
    end
    if p ~= nil then
        for i = 1, #p.inst do
            p.inst[i].rune = onePassRunes[i]
        end
    end
    return p
end

-- compileOnePass returns a new *syntax.Prog suitable for onePass execution if the original Prog
-- can be recharacterized as a one-pass regexp program, or syntax.nil if the
-- Prog cannot be converted. For a one pass prog, the fundamental condition that must
-- be true is: at any InstAlt, there must be no ambiguity about what branch to  take.
function regexp.compileOnePass(prog)
    if prog.start == 0 then
        return nil
    end
    -- onepass regexp is anchored
    if prog.inst[prog.start + 1].op ~= InstOp.InstEmptyWidth or
        (prog.inst[prog.start + 1].arg & 0xFF) & EmptyOp.EmptyBeginText ~= EmptyOp.EmptyBeginText then
        return nil
    end
    local hasAlt = false
    for _, inst in ipairs(prog.inst) do
        if inst.op == InstOp.InstAlt or inst.op == InstOp.InstAltMatch then
            hasAlt = true
            break
        end
    end
    -- every instruction leading to InstMatch must be EmptyEndText
    for _, inst in ipairs(prog.inst) do
        local opOut = prog.inst[inst.out + 1].op
        local op = inst.op
        if op == InstOp.InstAlt or op == InstOp.InstAltMatch then
            if opOut == InstOp.InstMatch or prog.inst[inst.arg + 1].op == InstOp.InstMatch then
                return nil
            end
        elseif op == InstOp.InstEmptyWidth then
            if opOut == InstOp.InstMatch then
                if (inst.arg & 0xFF) & EmptyOp.EmptyEndText ~= EmptyOp.EmptyEndText then
                    return nil
                end
            end
        else
            if opOut == InstOp.InstMatch and hasAlt then
                return nil
            end
        end
    end
    -- Creates a slightly optimized copy of the original Prog
    -- that cleans up some Prog idioms that block valid onepass programs
    local p = regexp.onePassCopy(prog)
    -- checkAmbiguity on InstAlts, build onepass Prog if possible
    p = regexp.makeOnePass(p)

    if p ~= nil then
        regexp.cleanupOnePass(p, prog)
    end
    return p
end
