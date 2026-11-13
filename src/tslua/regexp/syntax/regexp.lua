local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")
local utf8 = require("tslua.regexp.utf8")
local strconv = require("tslua.regexp.strconv")

local Op = syntax.Op
local Flags = syntax.Flags

-- A Regexp is a node in a regular expression syntax tree.
-- Fields: op, flags, sub (array of *Regexp or nil), rune (array of runes or nil), min, max,
-- cap, name. Go's Sub0/Rune0 inline storage is not needed in Lua, except that the parser's
-- free list links nodes through Sub0[0] (field sub0).
local Regexp = {}
Regexp.__index = Regexp
syntax.Regexp = Regexp

-- Go &Regexp{Op: op, Flags: flags}.
function syntax.newRegexpValue(op, flags)
    return setmetatable({
        op = op or 0,
        flags = flags or 0,
        sub = nil,
        sub0 = nil,
        rune = nil,
        min = 0,
        max = 0,
        cap = 0,
        name = "",
    }, Regexp)
end

syntax.opPseudo = 128 -- where pseudo-ops start

local function len(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

local function runesEqual(a, b)
    if len(a) ~= len(b) then
        return false
    end
    for i = 1, len(a) do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Equal reports whether x and y have identical structure.
function Regexp.Equal(x, y)
    if x == nil or y == nil then
        return x == y
    end
    if x.op ~= y.op then
        return false
    end
    local op = x.op
    if op == Op.EndText then
        -- The parse flags remember whether this is \z or \Z.
        if x.flags & Flags.WasDollar ~= y.flags & Flags.WasDollar then
            return false
        end
    elseif op == Op.Literal or op == Op.CharClass then
        return x.flags & Flags.FoldCase == y.flags & Flags.FoldCase and runesEqual(x.rune, y.rune)
    elseif op == Op.Alternate or op == Op.Concat then
        if len(x.sub) ~= len(y.sub) then
            return false
        end
        for i = 1, len(x.sub) do
            if not x.sub[i]:Equal(y.sub[i]) then
                return false
            end
        end
        return true
    elseif op == Op.Star or op == Op.Plus or op == Op.Quest then
        if x.flags & Flags.NonGreedy ~= y.flags & Flags.NonGreedy or not x.sub[1]:Equal(y.sub[1]) then
            return false
        end
    elseif op == Op.Repeat then
        if x.flags & Flags.NonGreedy ~= y.flags & Flags.NonGreedy or x.min ~= y.min or x.max ~= y.max or not x.sub[1]:Equal(y.sub[1]) then
            return false
        end
    elseif op == Op.Capture then
        if x.cap ~= y.cap or x.name ~= y.name or not x.sub[1]:Equal(y.sub[1]) then
            return false
        end
    end
    return true
end

-- printFlags is a bit set indicating which flags (including non-capturing parens) to print around a regexp.
syntax.flagI = 1 -- (?i:
syntax.flagM = 2 -- (?m:
syntax.flagS = 4 -- (?s:
syntax.flagOff = 8 -- )
syntax.flagPrec = 16 -- (?: )
syntax.negShift = 5 -- flagI<<negShift is (?-i:

local flagI, flagM, flagS, flagOff, flagPrec, negShift =
    syntax.flagI, syntax.flagM, syntax.flagS, syntax.flagOff, syntax.flagPrec, syntax.negShift

-- addSpan enables the flags f around start..last,
-- by setting flags[start] = f and flags[last] = flagOff.
function syntax.addSpan(start, last, f, flags)
    if flags.m == nil then
        flags.m = {}
    end
    flags.m[start] = f
    flags.m[last] = (flags.m[last] or 0) | flagOff -- maybe start==last
end

-- calcFlags calculates the flags to print around each subexpression in re,
-- storing that information in (*flags)[sub] for each affected subexpression.
-- The first time an entry needs to be written to *flags, calcFlags allocates the map.
-- calcFlags also calculates the flags that must be active or can't be active
-- around re and returns those flags.
-- (flags is a box { m = map or nil }, standing in for Go's *map[*Regexp]printFlags.)
function syntax.calcFlags(re, flags)
    local op = re.op
    if op == Op.Literal then
        -- If literal is fold-sensitive, return (flagI, 0) or (0, flagI)
        -- according to whether (?i) is active.
        -- If literal is not fold-sensitive, return 0, 0.
        for _, r in ipairs(re.rune or {}) do
            if syntax.minFold <= r and r <= syntax.maxFold and unicode.SimpleFold(r) ~= r then
                if re.flags & Flags.FoldCase ~= 0 then
                    return flagI, 0
                else
                    return 0, flagI
                end
            end
        end
        return 0, 0
    elseif op == Op.CharClass then
        -- If literal is fold-sensitive, return 0, flagI - (?i) has been compiled out.
        -- If literal is not fold-sensitive, return 0, 0.
        local rs = re.rune or {}
        for i = 0, #rs - 1, 2 do
            local lo = math.max(syntax.minFold, rs[i + 1])
            local hi = math.min(syntax.maxFold, rs[i + 2])
            for r = lo, hi do
                local f = unicode.SimpleFold(r)
                while f ~= r do
                    if not (lo <= f and f <= hi) and not syntax.inCharClass(f, rs) then
                        return 0, flagI
                    end
                    f = unicode.SimpleFold(f)
                end
            end
        end
        return 0, 0
    elseif op == Op.AnyCharNotNL then -- (?-s).
        return 0, flagS
    elseif op == Op.AnyChar then -- (?s).
        return flagS, 0
    elseif op == Op.BeginLine or op == Op.EndLine then -- (?m)^ (?m)$
        return flagM, 0
    elseif op == Op.EndText then
        if re.flags & Flags.WasDollar ~= 0 then -- (?-m)$
            return 0, flagM
        end
        return 0, 0
    elseif op == Op.Capture or op == Op.Star or op == Op.Plus or op == Op.Quest or op == Op.Repeat then
        return syntax.calcFlags(re.sub[1], flags)
    elseif op == Op.Concat or op == Op.Alternate then
        -- Gather the must and cant for each subexpression.
        -- When we find a conflicting subexpression, insert the necessary
        -- flags around the previously identified span and start over.
        local must, cant, allCant = 0, 0, 0
        local start = 0
        local last = 0
        local did = false
        for i1, sub in ipairs(re.sub) do
            local i = i1 - 1
            local subMust, subCant = syntax.calcFlags(sub, flags)
            if must & subCant ~= 0 or subMust & cant ~= 0 then
                if must ~= 0 then
                    syntax.addSpan(re.sub[start + 1], re.sub[last + 1], must, flags)
                end
                must = 0
                cant = 0
                start = i
                did = true
            end
            must = must | subMust
            cant = cant | subCant
            allCant = allCant | subCant
            if subMust ~= 0 then
                last = i
            end
            if must == 0 and start == i then
                start = start + 1
            end
        end
        if not did then
            -- No conflicts: pass the accumulated must and cant upward.
            return must, cant
        end
        if must ~= 0 then
            -- Conflicts found; need to finish final span.
            syntax.addSpan(re.sub[start + 1], re.sub[last + 1], must, flags)
        end
        return 0, allCant
    end
    return 0, 0
end

-- writeRegexp writes the Perl syntax for the regular expression re to b.
function syntax.writeRegexp(b, re, f, flags)
    f = f | (flags[re] or 0)
    if f & flagPrec ~= 0 and f & ~(flagOff | flagPrec) ~= 0 and f & flagOff ~= 0 then
        -- flagPrec is redundant with other flags being added and terminated
        f = f & ~flagPrec
    end
    if f & ~(flagOff | flagPrec) ~= 0 then
        b[#b + 1] = "(?"
        if f & flagI ~= 0 then
            b[#b + 1] = "i"
        end
        if f & flagM ~= 0 then
            b[#b + 1] = "m"
        end
        if f & flagS ~= 0 then
            b[#b + 1] = "s"
        end
        if f & ((flagM | flagS) << negShift) ~= 0 then
            b[#b + 1] = "-"
            if f & (flagM << negShift) ~= 0 then
                b[#b + 1] = "m"
            end
            if f & (flagS << negShift) ~= 0 then
                b[#b + 1] = "s"
            end
        end
        b[#b + 1] = ":"
    end
    if f & flagPrec ~= 0 then
        b[#b + 1] = "(?:"
    end

    local op = re.op
    if op == Op.NoMatch then
        b[#b + 1] = "[^\\x00-\\x{10FFFF}]"
    elseif op == Op.EmptyMatch then
        b[#b + 1] = "(?:)"
    elseif op == Op.Literal then
        for _, r in ipairs(re.rune or {}) do
            syntax.escape(b, r, false)
        end
    elseif op == Op.CharClass then
        local rs = re.rune or {}
        if #rs % 2 ~= 0 then
            b[#b + 1] = "[invalid char class]"
        else
            b[#b + 1] = "["
            if #rs == 0 then
                b[#b + 1] = "^\\x00-\\x{10FFFF}"
            elseif rs[1] == 0 and rs[#rs] == unicode.MaxRune and #rs > 2 then
                -- Contains 0 and MaxRune. Probably a negated class.
                -- Print the gaps.
                b[#b + 1] = "^"
                for i = 1, #rs - 2, 2 do
                    local lo, hi = rs[i + 1] + 1, rs[i + 2] - 1
                    syntax.escape(b, lo, lo == 0x2D)
                    if lo ~= hi then
                        if hi ~= lo + 1 then
                            b[#b + 1] = "-"
                        end
                        syntax.escape(b, hi, hi == 0x2D)
                    end
                end
            else
                for i = 0, #rs - 1, 2 do
                    local lo, hi = rs[i + 1], rs[i + 2]
                    syntax.escape(b, lo, lo == 0x2D)
                    if lo ~= hi then
                        if hi ~= lo + 1 then
                            b[#b + 1] = "-"
                        end
                        syntax.escape(b, hi, hi == 0x2D)
                    end
                end
            end
            b[#b + 1] = "]"
        end
    elseif op == Op.AnyCharNotNL or op == Op.AnyChar then
        b[#b + 1] = "."
    elseif op == Op.BeginLine then
        b[#b + 1] = "^"
    elseif op == Op.EndLine then
        b[#b + 1] = "$"
    elseif op == Op.BeginText then
        b[#b + 1] = "\\A"
    elseif op == Op.EndText then
        if re.flags & Flags.WasDollar ~= 0 then
            b[#b + 1] = "$"
        else
            b[#b + 1] = "\\z"
        end
    elseif op == Op.WordBoundary then
        b[#b + 1] = "\\b"
    elseif op == Op.NoWordBoundary then
        b[#b + 1] = "\\B"
    elseif op == Op.Capture then
        if re.name ~= "" then
            b[#b + 1] = "(?P<"
            b[#b + 1] = re.name
            b[#b + 1] = ">"
        else
            b[#b + 1] = "("
        end
        if re.sub[1].op ~= Op.EmptyMatch then
            syntax.writeRegexp(b, re.sub[1], flags[re.sub[1]] or 0, flags)
        end
        b[#b + 1] = ")"
    elseif op == Op.Star or op == Op.Plus or op == Op.Quest or op == Op.Repeat then
        local p = 0
        local sub = re.sub[1]
        if sub.op > Op.Capture or sub.op == Op.Literal and len(sub.rune) > 1 then
            p = flagPrec
        end
        syntax.writeRegexp(b, sub, p, flags)

        if op == Op.Star then
            b[#b + 1] = "*"
        elseif op == Op.Plus then
            b[#b + 1] = "+"
        elseif op == Op.Quest then
            b[#b + 1] = "?"
        elseif op == Op.Repeat then
            b[#b + 1] = "{"
            b[#b + 1] = strconv.Itoa(re.min)
            if re.max ~= re.min then
                b[#b + 1] = ","
                if re.max >= 0 then
                    b[#b + 1] = strconv.Itoa(re.max)
                end
            end
            b[#b + 1] = "}"
        end
        if re.flags & Flags.NonGreedy ~= 0 then
            b[#b + 1] = "?"
        end
    elseif op == Op.Concat then
        for _, sub in ipairs(re.sub) do
            local p = 0
            if sub.op == Op.Alternate then
                p = flagPrec
            end
            syntax.writeRegexp(b, sub, p, flags)
        end
    elseif op == Op.Alternate then
        for i, sub in ipairs(re.sub) do
            if i > 1 then
                b[#b + 1] = "|"
            end
            syntax.writeRegexp(b, sub, 0, flags)
        end
    else
        b[#b + 1] = "<invalid op" .. strconv.Itoa(op) .. ">"
    end

    -- Go defers these two writes; they run in reverse order on return.
    if f & flagPrec ~= 0 then
        b[#b + 1] = ")"
    end
    if f & flagOff ~= 0 then
        b[#b + 1] = ")"
    end
end

function Regexp:String()
    local b = {}
    local flags = { m = nil }
    local must, cant = syntax.calcFlags(self, flags)
    must = must | ((cant & ~flagI) << negShift)
    if must ~= 0 then
        must = must | flagOff
    end
    syntax.writeRegexp(b, self, must, flags.m or {})
    return table.concat(b)
end

Regexp.__tostring = Regexp.String

syntax.meta = "\\.+*?()|[]{}^$"

function syntax.escape(b, r, force)
    if unicode.IsPrint(r) then
        if (r < 0x80 and string.find(syntax.meta, string.char(r), 1, true) ~= nil) or force then
            b[#b + 1] = "\\"
        end
        b[#b + 1] = utf8.EncodeRune(r)
        return
    end

    if r == 7 then
        b[#b + 1] = "\\a"
    elseif r == 12 then
        b[#b + 1] = "\\f"
    elseif r == 10 then
        b[#b + 1] = "\\n"
    elseif r == 13 then
        b[#b + 1] = "\\r"
    elseif r == 9 then
        b[#b + 1] = "\\t"
    elseif r == 11 then
        b[#b + 1] = "\\v"
    else
        if r < 0x100 then
            b[#b + 1] = "\\x"
            local s = strconv.FormatInt(r, 16)
            if #s == 1 then
                b[#b + 1] = "0"
            end
            b[#b + 1] = s
            return
        end
        b[#b + 1] = "\\x{"
        b[#b + 1] = strconv.FormatInt(r, 16)
        b[#b + 1] = "}"
    end
end

-- MaxCap walks the regexp to find the maximum capture index.
function Regexp:MaxCap()
    local m = 0
    if self.op == Op.Capture then
        m = self.cap
    end
    for _, sub in ipairs(self.sub or {}) do
        local n = sub:MaxCap()
        if m < n then
            m = n
        end
    end
    return m
end

-- CapNames walks the regexp to find the names of capturing groups.
-- (A Go []string of length MaxCap()+1; unnamed entries are "".)
function Regexp:CapNames()
    local names = {}
    for i = 1, self:MaxCap() + 1 do
        names[i] = ""
    end
    self:capNames(names)
    return names
end

function Regexp:capNames(names)
    if self.op == Op.Capture then
        names[self.cap + 1] = self.name
    end
    for _, sub in ipairs(self.sub or {}) do
        sub:capNames(names)
    end
end
