local regexp = require("tslua.regexp")
local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")
local utf8 = require("tslua.regexp.utf8")
local strconv = require("tslua.regexp.strconv")

local Op = syntax.Op

local sbyte, ssub = string.byte, string.sub

-- Regexp is the representation of a compiled regular expression.
local Regexp = {}
Regexp.__index = Regexp
regexp.Regexp = Regexp

-- String returns the source text used to compile the regular expression.
function Regexp:String()
    return self.expr
end

Regexp.__tostring = Regexp.String

-- Copy returns a new [Regexp] object copied from re.
-- Calling [Regexp.Longest] on one copy does not affect another.
--
-- Deprecated: In earlier releases, when using a [Regexp] in multiple goroutines,
-- giving each goroutine its own copy helped to avoid lock contention.
-- As of Go 1.12, using Copy is no longer necessary to avoid lock contention.
-- Copy may still be appropriate if the reason for its use is to make
-- two copies with different [Regexp.Longest] settings.
function Regexp:Copy()
    local re2 = setmetatable({}, Regexp)
    for k, v in pairs(self) do
        re2[k] = v
    end
    return re2
end

-- Compile parses a regular expression and returns, if successful,
-- a [Regexp] object that can be used to match against text.
--
-- When matching against text, the regexp returns a match that
-- begins as early as possible in the input (leftmost), and among those
-- it chooses the one that a backtracking implementation would have
-- chosen. This so-called leftmost-first matching is the same semantics
-- that Perl, Python, and other implementations use, although this
-- package implements it without the expense of backtracking.
-- For POSIX leftmost-longest matching, see [CompilePOSIX].
function regexp.Compile(expr)
    return regexp.compile(expr, syntax.Flags.Perl, false)
end

-- CompilePOSIX is like [Compile] but restricts the regular expression
-- to POSIX ERE (egrep) syntax and changes the match semantics to
-- leftmost-longest.
function regexp.CompilePOSIX(expr)
    return regexp.compile(expr, syntax.Flags.POSIX, true)
end

-- Longest makes future searches prefer leftmost-longest matches.
-- In searches with leftmost-longest semantics,
-- the regexp returns a match that begins as early as possible in the input (leftmost),
-- and among those it chooses a match that is as long as possible.
-- This method modifies the [Regexp] and may not be called concurrently
-- with any other methods.
function Regexp:Longest()
    self.longest = true
end

function regexp.compile(expr, mode, longest)
    local re, err = syntax.Parse(expr, mode)
    if err ~= nil then
        return nil, err
    end
    local maxCap = re:MaxCap()
    local capNames = re:CapNames()

    re = re:Simplify()
    local prog
    prog, err = syntax.Compile(re)
    if err ~= nil then
        return nil, err
    end
    local matchcap = prog.numCap
    if matchcap < 2 then
        matchcap = 2
    end
    local r = setmetatable({
        expr = expr,
        prog = prog,
        onepass = regexp.compileOnePass(prog),
        numSubexp = maxCap,
        maxBitStateLen = 0,
        subexpNames = capNames,
        prefix = "",
        prefixBytes = nil,
        prefixRune = 0,
        prefixEnd = 0,
        mpool = 0,
        matchcap = matchcap,
        prefixComplete = false,
        cond = prog:StartCond(),
        minInputLen = regexp.minInputLen(re),
        longest = longest,
    }, Regexp)
    if r.onepass == nil then
        r.prefix, r.prefixComplete = prog:Prefix()
        r.maxBitStateLen = regexp.maxBitStateLen(prog)
    else
        r.prefix, r.prefixComplete, r.prefixEnd = regexp.onePassPrefix(prog)
    end
    if r.prefix ~= "" then
        -- TODO(rsc): Remove this allocation by adding
        -- IndexString to package bytes.
        r.prefixBytes = r.prefix
        r.prefixRune = utf8.DecodeRuneInString(r.prefix)
    end

    local n = #prog.inst
    local i = 0
    while regexp.matchSize[i + 1] ~= 0 and regexp.matchSize[i + 1] < n do
        i = i + 1
    end
    r.mpool = i

    return r, nil
end

-- Pools of *machine for use during (*Regexp).doExecute,
-- split up by the size of the execution queues.
-- matchPool[i] machines have queue size matchSize[i].
-- On a 64-bit system each queue entry is 16 bytes,
-- so matchPool[0] has 16*2*128 = 4kB queues, etc.
-- The final matchPool is a catch-all for very large queues.
-- (Go's sync.Pool may always return a fresh value; this port always does.)
regexp.matchSize = { 128, 512, 2048, 16384, 0 }

-- get returns a machine to use for matching re.
-- It uses the re's machine cache if possible, to avoid
-- unnecessary allocation.
function Regexp:get()
    local m = regexp.newMachine()
    m.re = self
    m.p = self.prog
    m.matchcap = {}
    for i = 1, self.matchcap do
        m.matchcap[i] = 0
    end
    return m
end

-- put returns a machine to the correct machine pool.
function Regexp:put(m)
    m.re = nil
    m.p = nil
    m.inputs:clear()
end

-- minInputLen walks the regexp to find the minimum length of any matchable input.
function regexp.minInputLen(re)
    local op = re.op
    if op == Op.AnyChar or op == Op.AnyCharNotNL or op == Op.CharClass then
        return 1
    elseif op == Op.Literal then
        local l = 0
        for _, r in ipairs(re.rune or {}) do
            if r == utf8.RuneError then
                l = l + 1
            else
                l = l + utf8.RuneLen(r)
            end
        end
        return l
    elseif op == Op.Capture or op == Op.Plus then
        return regexp.minInputLen(re.sub[1])
    elseif op == Op.Repeat then
        return re.min * regexp.minInputLen(re.sub[1])
    elseif op == Op.Concat then
        local l = 0
        for _, sub in ipairs(re.sub) do
            l = l + regexp.minInputLen(sub)
        end
        return l
    elseif op == Op.Alternate then
        local l = regexp.minInputLen(re.sub[1])
        local lnext
        for k = 2, #re.sub do
            lnext = regexp.minInputLen(re.sub[k])
            if lnext < l then
                l = lnext
            end
        end
        return l
    end
    return 0
end

-- MustCompile is like [Compile] but panics if the expression cannot be parsed.
-- It simplifies safe initialization of global variables holding compiled regular
-- expressions.
function regexp.MustCompile(str)
    local r, err = regexp.Compile(str)
    if err ~= nil then
        error("regexp: Compile(" .. regexp.quote(str) .. "): " .. err:Error(), 0)
    end
    return r
end

-- MustCompilePOSIX is like [CompilePOSIX] but panics if the expression cannot be parsed.
-- It simplifies safe initialization of global variables holding compiled regular
-- expressions.
function regexp.MustCompilePOSIX(str)
    local r, err = regexp.CompilePOSIX(str)
    if err ~= nil then
        error("regexp: CompilePOSIX(" .. regexp.quote(str) .. "): " .. err:Error(), 0)
    end
    return r
end

function regexp.quote(s)
    if strconv.CanBackquote(s) then
        return "`" .. s .. "`"
    end
    return strconv.Quote(s)
end

-- NumSubexp returns the number of parenthesized subexpressions in this [Regexp].
function Regexp:NumSubexp()
    return self.numSubexp
end

-- SubexpNames returns the names of the parenthesized subexpressions
-- in this [Regexp]. The name for the first sub-expression is names[1],
-- so that if m is a match slice, the name for m[i] is SubexpNames()[i].
-- Since the Regexp as a whole cannot be named, names[0] is always
-- the empty string. The slice should not be modified.
function Regexp:SubexpNames()
    return self.subexpNames
end

-- SubexpIndex returns the index of the first subexpression with the given name,
-- or -1 if there is no subexpression with that name.
--
-- Note that multiple subexpressions can be written using the same name, as in
-- (?P<bob>a+)(?P<bob>b+), which declares two subexpressions named "bob".
-- In this case, SubexpIndex returns the index of the leftmost such subexpression
-- in the regular expression.
function Regexp:SubexpIndex(name)
    if name ~= "" then
        for i1, s in ipairs(self.subexpNames) do
            if name == s then
                return i1 - 1
            end
        end
    end
    return -1
end

regexp.endOfText = -1

-- input abstracts different representations of the input text. It provides
-- one-character lookahead.
-- (Methods: step(pos) -> rune, width; canCheckPrefix(); hasPrefix(re); index(re, pos);
-- context(pos) -> lazyFlag.)

-- inputString scans a string.
local inputString = {}
inputString.__index = inputString
regexp.inputString = inputString

function regexp.newInputString(s)
    return setmetatable({ str = s or "" }, inputString)
end

function inputString:step(pos)
    if pos < #self.str then
        local c = sbyte(self.str, pos + 1)
        if c < utf8.RuneSelf then
            return c, 1
        end
        return utf8.DecodeRuneInString(self.str, pos)
    end
    return regexp.endOfText, 0
end

function inputString:canCheckPrefix()
    return true
end

function inputString:hasPrefix(re)
    return ssub(self.str, 1, #re.prefix) == re.prefix
end

function inputString:index(re, pos)
    local i = string.find(self.str, re.prefix, pos + 1, true)
    if i == nil then
        return -1
    end
    return i - 1 - pos
end

function inputString:context(pos)
    local r1, r2 = regexp.endOfText, regexp.endOfText
    -- 0 < pos && pos <= len(i.str)
    if pos - 1 >= 0 and pos - 1 < #self.str then
        r1 = utf8.DecodeLastRuneInString(self.str, pos)
    end
    -- 0 <= pos && pos < len(i.str)
    if pos >= 0 and pos < #self.str then
        r2 = utf8.DecodeRuneInString(self.str, pos)
    end
    return regexp.newLazyFlag(r1, r2)
end

-- inputBytes scans a byte slice (a Lua string in this port).
local inputBytes = {}
inputBytes.__index = inputBytes
regexp.inputBytes = inputBytes

function regexp.newInputBytes(b)
    return setmetatable({ str = b }, inputBytes)
end

function inputBytes:step(pos)
    if pos < #self.str then
        local c = sbyte(self.str, pos + 1)
        if c < utf8.RuneSelf then
            return c, 1
        end
        return utf8.DecodeRune(self.str, pos)
    end
    return regexp.endOfText, 0
end

function inputBytes:canCheckPrefix()
    return true
end

function inputBytes:hasPrefix(re)
    return ssub(self.str, 1, #re.prefixBytes) == re.prefixBytes
end

function inputBytes:index(re, pos)
    local i = string.find(self.str, re.prefixBytes, pos + 1, true)
    if i == nil then
        return -1
    end
    return i - 1 - pos
end

function inputBytes:context(pos)
    local r1, r2 = regexp.endOfText, regexp.endOfText
    -- 0 < pos && pos <= len(i.str)
    if pos - 1 >= 0 and pos - 1 < #self.str then
        r1 = utf8.DecodeLastRune(self.str, pos)
    end
    -- 0 <= pos && pos < len(i.str)
    if pos >= 0 and pos < #self.str then
        r2 = utf8.DecodeRune(self.str, pos)
    end
    return regexp.newLazyFlag(r1, r2)
end

-- inputReader scans a RuneReader.
local inputReader = {}
inputReader.__index = inputReader
regexp.inputReader = inputReader

function regexp.newInputReader(r)
    return setmetatable({ r = r, atEOT = false, pos = 0 }, inputReader)
end

function inputReader:step(pos)
    if not self.atEOT and pos ~= self.pos then
        return regexp.endOfText, 0
    end
    local r, w, err = self.r:ReadRune()
    if err ~= nil then
        self.atEOT = true
        return regexp.endOfText, 0
    end
    self.pos = self.pos + w
    return r, w
end

function inputReader:canCheckPrefix()
    return false
end

function inputReader:hasPrefix(re)
    return false
end

function inputReader:index(re, pos)
    return -1
end

function inputReader:context(pos)
    return 0 -- not used
end

-- LiteralPrefix returns a literal string that must begin any match
-- of the regular expression re. It returns the boolean true if the
-- literal string comprises the entire regular expression.
function Regexp:LiteralPrefix()
    return self.prefix, self.prefixComplete
end

-- MatchReader reports whether the text returned by the [io.RuneReader]
-- contains any match of the regular expression re.
function Regexp:MatchReader(r)
    return self:doMatch(r, nil, "")
end

-- MatchString reports whether the string s
-- contains any match of the regular expression re.
function Regexp:MatchString(s)
    return self:doMatch(nil, nil, s)
end

-- Match reports whether the byte slice b
-- contains any match of the regular expression re.
function Regexp:Match(b)
    return self:doMatch(nil, b, "")
end

-- MatchReader reports whether the text returned by the [io.RuneReader]
-- contains any match of the regular expression pattern.
-- More complicated queries need to use [Compile] and the full [Regexp] interface.
function regexp.MatchReader(pattern, r)
    local re, err = regexp.Compile(pattern)
    if err ~= nil then
        return false, err
    end
    return re:MatchReader(r), nil
end

-- MatchString reports whether the string s
-- contains any match of the regular expression pattern.
-- More complicated queries need to use [Compile] and the full [Regexp] interface.
function regexp.MatchString(pattern, s)
    local re, err = regexp.Compile(pattern)
    if err ~= nil then
        return false, err
    end
    return re:MatchString(s), nil
end

-- Match reports whether the byte slice b
-- contains any match of the regular expression pattern.
-- More complicated queries need to use [Compile] and the full [Regexp] interface.
function regexp.Match(pattern, b)
    local re, err = regexp.Compile(pattern)
    if err ~= nil then
        return false, err
    end
    return re:Match(b), nil
end

-- ReplaceAllString returns a copy of src, replacing matches of the [Regexp]
-- with the replacement string repl.
-- Inside repl, $ signs are interpreted as in [Regexp.Expand].
function Regexp:ReplaceAllString(src, repl)
    local n = 2
    if string.find(repl, "$", 1, true) ~= nil then
        n = 2 * (self.numSubexp + 1)
    end
    local b = self:replaceAll(nil, src, n, function(dst, match)
        return self:expand(dst, repl, nil, src, match)
    end)
    return b
end

-- ReplaceAllLiteralString returns a copy of src, replacing matches of the [Regexp]
-- with the replacement string repl. The replacement repl is substituted directly,
-- without using [Regexp.Expand].
function Regexp:ReplaceAllLiteralString(src, repl)
    return self:replaceAll(nil, src, 2, function(dst, match)
        dst[#dst + 1] = repl
        return dst
    end)
end

-- ReplaceAllStringFunc returns a copy of src in which all matches of the
-- [Regexp] have been replaced by the return value of function repl applied
-- to the matched substring. The replacement returned by repl is substituted
-- directly, without using [Regexp.Expand].
function Regexp:ReplaceAllStringFunc(src, repl)
    return self:replaceAll(nil, src, 2, function(dst, match)
        dst[#dst + 1] = repl(ssub(src, match[1] + 1, match[2]))
        return dst
    end)
end

-- replaceAll returns the replaced text (a Lua string); repl(dst, m) appends to the
-- string buffer dst (a Lua array of strings) and returns it.
function Regexp:replaceAll(bsrc, src, nmatch, repl)
    local lastMatchEnd = 0 -- end position of the most recent match
    local searchPos = 0 -- position where we next look for a match
    local buf = {}
    local endPos
    if bsrc ~= nil then
        endPos = #bsrc
    else
        endPos = #src
    end
    if nmatch > self.prog.numCap then
        nmatch = self.prog.numCap
    end

    local text = bsrc or src
    while searchPos <= endPos do
        local a = self:doExecute(nil, bsrc, src, searchPos, nmatch, {})
        if a == nil or #a == 0 then
            break -- no more matches
        end

        -- Copy the unmatched characters before this match.
        buf[#buf + 1] = ssub(text, lastMatchEnd + 1, a[1])

        -- Now insert a copy of the replacement string, but not for a
        -- match of the empty string immediately after another match.
        -- (Otherwise, we get double replacement for patterns that
        -- match both empty and nonempty strings.)
        if a[2] > lastMatchEnd or a[1] == 0 then
            buf = repl(buf, a)
        end
        lastMatchEnd = a[2]

        -- Advance past this match; always advance at least one character.
        local _, width = utf8.DecodeRuneInString(text, searchPos)
        if searchPos + width > a[2] then
            searchPos = searchPos + width
        elseif searchPos + 1 > a[2] then
            -- This clause is only needed at the end of the input
            -- string. In that case, DecodeRuneInString returns width=0.
            searchPos = searchPos + 1
        else
            searchPos = a[2]
        end
    end

    -- Copy the unmatched characters after the last match.
    buf[#buf + 1] = ssub(text, lastMatchEnd + 1)

    return table.concat(buf)
end

-- ReplaceAll returns a copy of src, replacing matches of the [Regexp]
-- with the replacement text repl.
-- Inside repl, $ signs are interpreted as in [Regexp.Expand].
function Regexp:ReplaceAll(src, repl)
    local n = 2
    if string.find(repl, "$", 1, true) ~= nil then
        n = 2 * (self.numSubexp + 1)
    end
    return self:replaceAll(src, "", n, function(dst, match)
        return self:expand(dst, repl, src, "", match)
    end)
end

-- ReplaceAllLiteral returns a copy of src, replacing matches of the [Regexp]
-- with the replacement bytes repl. The replacement repl is substituted directly,
-- without using [Regexp.Expand].
function Regexp:ReplaceAllLiteral(src, repl)
    return self:replaceAll(src, "", 2, function(dst, match)
        dst[#dst + 1] = repl
        return dst
    end)
end

-- ReplaceAllFunc returns a copy of src in which all matches of the
-- [Regexp] have been replaced by the return value of function repl applied
-- to the matched byte slice. The replacement returned by repl is substituted
-- directly, without using [Regexp.Expand].
function Regexp:ReplaceAllFunc(src, repl)
    return self:replaceAll(src, "", 2, function(dst, match)
        dst[#dst + 1] = repl(ssub(src, match[1] + 1, match[2]))
        return dst
    end)
end

-- Bitmap used by func special to check whether a character needs to be escaped.
regexp.specialBytes = {}
for i = 1, 16 do
    regexp.specialBytes[i] = 0
end

-- special reports whether byte b needs to be escaped by QuoteMeta.
function regexp.special(b)
    return b < utf8.RuneSelf and regexp.specialBytes[b % 16 + 1] & (1 << (b // 16)) ~= 0
end

do
    local s = "\\.+*?()|[]{}^$"
    for i = 1, #s do
        local b = sbyte(s, i)
        regexp.specialBytes[b % 16 + 1] = regexp.specialBytes[b % 16 + 1] | (1 << (b // 16))
    end
end

-- QuoteMeta returns a string that escapes all regular expression metacharacters
-- inside the argument text; the returned string is a regular expression matching
-- the literal text.
function regexp.QuoteMeta(s)
    -- A byte loop is correct because all metacharacters are ASCII.
    local i = 0
    while i < #s do
        if regexp.special(sbyte(s, i + 1)) then
            break
        end
        i = i + 1
    end
    -- No meta characters found, so return original string.
    if i >= #s then
        return s
    end

    local b = { ssub(s, 1, i) }
    while i < #s do
        local c = sbyte(s, i + 1)
        if regexp.special(c) then
            b[#b + 1] = "\\"
        end
        b[#b + 1] = string.char(c)
        i = i + 1
    end
    return table.concat(b)
end

-- The number of capture values in the program may correspond
-- to fewer capturing expressions than are in the regexp.
-- For example, "(a){0}" turns into an empty program, so the
-- maximum capture in the program is 0 but we need to return
-- an expression for \1.  Pad appends -1s to the slice a as needed.
function Regexp:pad(a)
    if a == nil then
        -- No match.
        return nil
    end
    local n = (1 + self.numSubexp) * 2
    while #a < n do
        a[#a + 1] = -1
    end
    return a
end

-- allMatches calls deliver at most n times
-- with the location of successive matches in the input text.
-- The input text is b if non-nil, otherwise s.
function Regexp:allMatches(s, b, n, deliver)
    local end_
    if b == nil then
        end_ = #s
    else
        end_ = #b
    end

    local pos, i, prevMatchEnd = 0, 0, -1
    while i < n and pos <= end_ do
        local matches = self:doExecute(nil, b, s, pos, self.prog.numCap, nil)
        if matches == nil or #matches == 0 then
            break
        end

        local accept = true
        if matches[2] == pos then
            -- We've found an empty match.
            if matches[1] == prevMatchEnd then
                -- We don't allow an empty match right
                -- after a previous match, so ignore it.
                accept = false
            end
            -- Move to next matching position
            local width
            if b == nil then
                local is = regexp.newInputString(s)
                local _
                _, width = is:step(pos)
            else
                local ib = regexp.newInputBytes(b)
                local _
                _, width = ib:step(pos)
            end
            if width > 0 then
                pos = pos + width
            else
                pos = end_ + 1
            end
        else
            pos = matches[2]
        end
        prevMatchEnd = matches[2]

        if accept then
            deliver(self:pad(matches))
            i = i + 1
        end
    end
end

-- Find returns a slice holding the text of the leftmost match in b of the regular expression.
-- A return value of nil indicates no match.
function Regexp:Find(b)
    local a = self:doExecute(nil, b, "", 0, 2, {})
    if a == nil then
        return nil
    end
    return ssub(b or "", a[1] + 1, a[2])
end

-- FindIndex returns a two-element slice of integers defining the location of
-- the leftmost match in b of the regular expression. The match itself is at
-- b[loc[0]:loc[1]].
-- A return value of nil indicates no match.
function Regexp:FindIndex(b)
    local a = self:doExecute(nil, b, "", 0, 2, nil)
    if a == nil then
        return nil
    end
    return { a[1], a[2] }
end

-- FindString returns a string holding the text of the leftmost match in s of the regular
-- expression. If there is no match, the return value is an empty string,
-- but it will also be empty if the regular expression successfully matches
-- an empty string. Use [Regexp.FindStringIndex] or [Regexp.FindStringSubmatch] if it is
-- necessary to distinguish these cases.
function Regexp:FindString(s)
    local a = self:doExecute(nil, nil, s, 0, 2, {})
    if a == nil then
        return ""
    end
    return ssub(s, a[1] + 1, a[2])
end

-- FindStringIndex returns a two-element slice of integers defining the
-- location of the leftmost match in s of the regular expression. The match
-- itself is at s[loc[0]:loc[1]].
-- A return value of nil indicates no match.
function Regexp:FindStringIndex(s)
    local a = self:doExecute(nil, nil, s, 0, 2, nil)
    if a == nil then
        return nil
    end
    return { a[1], a[2] }
end

-- FindReaderIndex returns a two-element slice of integers defining the
-- location of the leftmost match of the regular expression in text read from
-- the [io.RuneReader]. The match text was found in the input stream at
-- byte offset loc[0] through loc[1]-1.
-- A return value of nil indicates no match.
function Regexp:FindReaderIndex(r)
    local a = self:doExecute(r, nil, "", 0, 2, nil)
    if a == nil then
        return nil
    end
    return { a[1], a[2] }
end

-- FindSubmatch returns a slice of slices holding the text of the leftmost
-- match of the regular expression in b and the matches, if any, of its
-- subexpressions, as defined by the 'Submatch' descriptions in the package
-- comment.
-- A return value of nil indicates no match.
-- (Unmatched subexpressions, nil in Go, are false.)
function Regexp:FindSubmatch(b)
    local a = self:doExecute(nil, b, "", 0, self.prog.numCap, {})
    if a == nil then
        return nil
    end
    local ret = {}
    for i = 0, self.numSubexp do
        if 2 * i < #a and a[2 * i + 1] >= 0 then
            ret[i + 1] = ssub(b, a[2 * i + 1] + 1, a[2 * i + 2])
        else
            ret[i + 1] = false
        end
    end
    return ret
end

-- Expand appends template to dst and returns the result; during the
-- append, Expand replaces variables in the template with corresponding
-- matches drawn from src. The match slice should have been returned by
-- [Regexp.FindSubmatchIndex].
--
-- In the template, a variable is denoted by a substring of the form
-- $name or ${name}, where name is a non-empty sequence of letters,
-- digits, and underscores. A purely numeric name like $1 refers to
-- the submatch with the corresponding index; other names refer to
-- capturing parentheses named with the (?P<name>...) syntax. A
-- reference to an out of range or unmatched index or a name that is not
-- present in the regular expression is replaced with an empty slice.
--
-- In the $name form, name is taken to be as long as possible: $1x is
-- equivalent to ${1x}, not ${1}x, and, $10 is equivalent to ${10}, not ${1}0.
--
-- To insert a literal $ in the output, use $$ in the template.
-- (dst, template and src are Lua strings; dst may be nil.)
function Regexp:Expand(dst, template, src, match)
    return table.concat(self:expand({ dst or "" }, template, src, "", match))
end

-- ExpandString is like [Regexp.Expand] but the template and source are strings.
-- It appends to and returns a byte slice in order to give the calling
-- code control over allocation.
function Regexp:ExpandString(dst, template, src, match)
    return table.concat(self:expand({ dst or "" }, template, nil, src, match))
end

-- expand appends to the string buffer dst (a Lua array of strings) and returns it.
function Regexp:expand(dst, template, bsrc, src, match)
    while #template > 0 do
        local k = string.find(template, "$", 1, true)
        if k == nil then
            break
        end
        local before, after = ssub(template, 1, k - 1), ssub(template, k + 1)
        dst[#dst + 1] = before
        template = after
        if template ~= "" and sbyte(template, 1) == 0x24 --[[ '$' ]] then
            -- Treat $$ as $.
            dst[#dst + 1] = "$"
            template = ssub(template, 2)
        else
            local name, num, rest, ok = regexp.extract(template)
            if not ok then
                -- Malformed; treat $ as raw text.
                dst[#dst + 1] = "$"
            else
                template = rest
                local text = bsrc or src
                if num >= 0 then
                    if 2 * num + 1 < #match and match[2 * num + 1] >= 0 then
                        dst[#dst + 1] = ssub(text, match[2 * num + 1] + 1, match[2 * num + 2])
                    end
                else
                    for i1, namei in ipairs(self.subexpNames) do
                        local i = i1 - 1
                        if name == namei and 2 * i + 1 < #match and match[2 * i + 1] >= 0 then
                            dst[#dst + 1] = ssub(text, match[2 * i + 1] + 1, match[2 * i + 2])
                            break
                        end
                    end
                end
            end
        end
    end
    dst[#dst + 1] = template
    return dst
end

-- extract returns the name from a leading "name" or "{name}" in str.
-- (The $ has already been removed by the caller.)
-- If it is a number, extract returns num set to that number; otherwise num = -1.
function regexp.extract(str)
    if str == "" then
        return "", 0, "", false
    end
    local brace = false
    if sbyte(str, 1) == 0x7B --[[ '{' ]] then
        brace = true
        str = ssub(str, 2)
    end
    local i = 0
    while i < #str do
        local rune, size = utf8.DecodeRuneInString(str, i)
        if not unicode.IsLetter(rune) and not unicode.IsDigit(rune) and rune ~= 0x5F --[[ '_' ]] then
            break
        end
        i = i + size
    end
    if i == 0 then
        -- empty name is not okay
        return "", 0, "", false
    end
    local name = ssub(str, 1, i)
    if brace then
        if i >= #str or sbyte(str, i + 1) ~= 0x7D --[[ '}' ]] then
            -- missing closing brace
            return "", 0, "", false
        end
        i = i + 1
    end

    -- Parse number.
    local num = 0
    for k = 1, #name do
        local c = sbyte(name, k)
        if c < 0x30 or 0x39 < c or num >= 1e8 then
            num = -1
            break
        end
        num = num * 10 + c - 0x30
    end
    -- Disallow leading zeros.
    if sbyte(name, 1) == 0x30 and #name > 1 then
        num = -1
    end

    return name, num, ssub(str, i + 1), true
end

-- FindSubmatchIndex returns a slice holding the index pairs identifying the
-- leftmost match of the regular expression in b and the matches, if any, of
-- its subexpressions, as defined by the 'Submatch' and 'Index' descriptions
-- in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindSubmatchIndex(b)
    return self:pad(self:doExecute(nil, b, "", 0, self.prog.numCap, nil))
end

-- FindStringSubmatch returns a slice of strings holding the text of the
-- leftmost match of the regular expression in s and the matches, if any, of
-- its subexpressions, as defined by the 'Submatch' description in the
-- package comment.
-- A return value of nil indicates no match.
function Regexp:FindStringSubmatch(s)
    local a = self:doExecute(nil, nil, s, 0, self.prog.numCap, {})
    if a == nil then
        return nil
    end
    local ret = {}
    for i = 0, self.numSubexp do
        ret[i + 1] = ""
        if 2 * i < #a and a[2 * i + 1] >= 0 then
            ret[i + 1] = ssub(s, a[2 * i + 1] + 1, a[2 * i + 2])
        end
    end
    return ret
end

-- FindStringSubmatchIndex returns a slice holding the index pairs
-- identifying the leftmost match of the regular expression in s and the
-- matches, if any, of its subexpressions, as defined by the 'Submatch' and
-- 'Index' descriptions in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindStringSubmatchIndex(s)
    return self:pad(self:doExecute(nil, nil, s, 0, self.prog.numCap, nil))
end

-- FindReaderSubmatchIndex returns a slice holding the index pairs
-- identifying the leftmost match of the regular expression of text read by
-- the [io.RuneReader], and the matches, if any, of its subexpressions, as defined
-- by the 'Submatch' and 'Index' descriptions in the package comment. A
-- return value of nil indicates no match.
function Regexp:FindReaderSubmatchIndex(r)
    return self:pad(self:doExecute(r, nil, "", 0, self.prog.numCap, nil))
end

regexp.startSize = 10 -- The size at which to start a slice in the 'All' routines.

-- FindAll is the 'All' version of [Regexp.Find]; it returns a slice of all successive
-- matches of the expression, as defined by the 'All' description in the
-- package comment.
-- A return value of nil indicates no match.
function Regexp:FindAll(b, n)
    if n < 0 then
        n = #b + 1
    end
    local result
    self:allMatches("", b, n, function(match)
        if result == nil then
            result = {}
        end
        result[#result + 1] = ssub(b, match[1] + 1, match[2])
    end)
    return result
end

-- FindAllIndex is the 'All' version of [Regexp.FindIndex]; it returns a slice of all
-- successive matches of the expression, as defined by the 'All' description
-- in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllIndex(b, n)
    if n < 0 then
        n = #b + 1
    end
    local result
    self:allMatches("", b, n, function(match)
        if result == nil then
            result = {}
        end
        result[#result + 1] = { match[1], match[2] }
    end)
    return result
end

-- FindAllString is the 'All' version of [Regexp.FindString]; it returns a slice of all
-- successive matches of the expression, as defined by the 'All' description
-- in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllString(s, n)
    if n < 0 then
        n = #s + 1
    end
    local result
    self:allMatches(s, nil, n, function(match)
        if result == nil then
            result = {}
        end
        result[#result + 1] = ssub(s, match[1] + 1, match[2])
    end)
    return result
end

-- FindAllStringIndex is the 'All' version of [Regexp.FindStringIndex]; it returns a
-- slice of all successive matches of the expression, as defined by the 'All'
-- description in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllStringIndex(s, n)
    if n < 0 then
        n = #s + 1
    end
    local result
    self:allMatches(s, nil, n, function(match)
        if result == nil then
            result = {}
        end
        result[#result + 1] = { match[1], match[2] }
    end)
    return result
end

-- FindAllSubmatch is the 'All' version of [Regexp.FindSubmatch]; it returns a slice
-- of all successive matches of the expression, as defined by the 'All'
-- description in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllSubmatch(b, n)
    if n < 0 then
        n = #b + 1
    end
    local result
    self:allMatches("", b, n, function(match)
        if result == nil then
            result = {}
        end
        local slice = {}
        for j = 0, #match // 2 - 1 do
            if match[2 * j + 1] >= 0 then
                slice[j + 1] = ssub(b, match[2 * j + 1] + 1, match[2 * j + 2])
            else
                slice[j + 1] = false
            end
        end
        result[#result + 1] = slice
    end)
    return result
end

-- FindAllSubmatchIndex is the 'All' version of [Regexp.FindSubmatchIndex]; it returns
-- a slice of all successive matches of the expression, as defined by the
-- 'All' description in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllSubmatchIndex(b, n)
    if n < 0 then
        n = #b + 1
    end
    local result
    self:allMatches("", b, n, function(match)
        if result == nil then
            result = {}
        end
        result[#result + 1] = match
    end)
    return result
end

-- FindAllStringSubmatch is the 'All' version of [Regexp.FindStringSubmatch]; it
-- returns a slice of all successive matches of the expression, as defined by
-- the 'All' description in the package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllStringSubmatch(s, n)
    if n < 0 then
        n = #s + 1
    end
    local result
    self:allMatches(s, nil, n, function(match)
        if result == nil then
            result = {}
        end
        local slice = {}
        for j = 0, #match // 2 - 1 do
            slice[j + 1] = ""
            if match[2 * j + 1] >= 0 then
                slice[j + 1] = ssub(s, match[2 * j + 1] + 1, match[2 * j + 2])
            end
        end
        result[#result + 1] = slice
    end)
    return result
end

-- FindAllStringSubmatchIndex is the 'All' version of
-- [Regexp.FindStringSubmatchIndex]; it returns a slice of all successive
-- matches of the expression, as defined by the 'All' description in the
-- package comment.
-- A return value of nil indicates no match.
function Regexp:FindAllStringSubmatchIndex(s, n)
    if n < 0 then
        n = #s + 1
    end
    local result
    self:allMatches(s, nil, n, function(match)
        if result == nil then
            result = {}
        end
        result[#result + 1] = match
    end)
    return result
end

-- Split slices s into substrings separated by the expression and returns a slice of
-- the substrings between those expression matches.
--
-- The slice returned by this method consists of all the substrings of s
-- not contained in the slice returned by [Regexp.FindAllString]. When called on an expression
-- that contains no metacharacters, it is equivalent to [strings.SplitN].
--
-- Example:
--
--	s := regexp.MustCompile("a*").Split("abaabaccadaaae", 5)
--	// s: ["", "b", "b", "c", "cadaaae"]
--
-- The count determines the number of substrings to return:
--   - n > 0: at most n substrings; the last substring will be the unsplit remainder;
--   - n == 0: the result is nil (zero substrings);
--   - n < 0: all substrings.
function Regexp:Split(s, n)
    if n == 0 then
        return nil
    end

    if #self.expr > 0 and #s == 0 then
        return { "" }
    end

    local matches = self:FindAllStringIndex(s, n)
    local strings = {}

    local beg = 0
    local end_ = 0
    for _, match in ipairs(matches or {}) do
        if n > 0 and #strings >= n - 1 then
            break
        end

        end_ = match[1]
        if match[2] ~= 0 then
            strings[#strings + 1] = ssub(s, beg + 1, end_)
        end
        beg = match[2]
    end

    if end_ ~= #s then
        strings[#strings + 1] = ssub(s, beg + 1)
    end

    return strings
end

-- AppendText implements [encoding.TextAppender]. The output
-- matches that of calling the [Regexp.String] method.
--
-- Note that the output is lossy in some cases: This method does not indicate
-- POSIX regular expressions (i.e. those compiled by calling [CompilePOSIX]), or
-- those for which the [Regexp.Longest] method has been called.
function Regexp:AppendText(b)
    return (b or "") .. self:String(), nil
end

-- MarshalText implements [encoding.TextMarshaler]. The output
-- matches that of calling the [Regexp.AppendText] method.
--
-- See [Regexp.AppendText] for more information.
function Regexp:MarshalText()
    return self:AppendText(nil)
end

-- UnmarshalText implements [encoding.TextUnmarshaler] by calling
-- [Compile] on the encoded value.
function Regexp:UnmarshalText(text)
    local newRE, err = regexp.Compile(text)
    if err ~= nil then
        return err
    end
    for k in pairs(self) do
        self[k] = nil
    end
    for k, v in pairs(newRE) do
        self[k] = v
    end
    return nil
end

