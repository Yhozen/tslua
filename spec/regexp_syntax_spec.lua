-- Port of Go's regexp/syntax tests (parse_test.go, prog_test.go, simplify_test.go).
-- The test tables are dumped from the Go test files into spec/regexp_testdata/syntax_tables.lua.
local syntax = require("tslua.regexp.syntax")
local unicode = require("tslua.regexp.unicode")
local utf8 = require("tslua.regexp.utf8")

local T = dofile("spec/regexp_testdata/syntax_tables.lua")

local Op = syntax.Op
local Flags = syntax.Flags

local testFlags = Flags.MatchNL | Flags.PerlX | Flags.UnicodeGroups

-- Go's opNames is indexed by Op.
local opNames = T.opNames

local function hex(r)
    return string.format("0x%x", r)
end

-- dumpRegexp writes an encoding of the syntax tree for the regexp re to b.
-- It is used during testing to distinguish between parses that might print
-- the same using re's String method.
local function dumpRegexp(b, re)
    local name = opNames[re.op + 1]
    if name == nil or name == "" then
        b[#b + 1] = "op" .. re.op
    else
        if re.op == Op.Star or re.op == Op.Plus or re.op == Op.Quest or re.op == Op.Repeat then
            if re.flags & Flags.NonGreedy ~= 0 then
                b[#b + 1] = "n"
            end
            b[#b + 1] = name
        elseif re.op == Op.Literal then
            if #re.rune > 1 then
                b[#b + 1] = "str"
            else
                b[#b + 1] = "lit"
            end
            if re.flags & Flags.FoldCase ~= 0 then
                for _, r in ipairs(re.rune) do
                    if unicode.SimpleFold(r) ~= r then
                        b[#b + 1] = "fold"
                        break
                    end
                end
            end
        else
            b[#b + 1] = name
        end
    end
    b[#b + 1] = "{"
    if re.op == Op.EndText then
        if re.flags & Flags.WasDollar == 0 then
            b[#b + 1] = "\\z"
        end
    elseif re.op == Op.Literal then
        for _, r in ipairs(re.rune) do
            b[#b + 1] = utf8.EncodeRune(r)
        end
    elseif re.op == Op.Concat or re.op == Op.Alternate then
        for _, sub in ipairs(re.sub) do
            dumpRegexp(b, sub)
        end
    elseif re.op == Op.Star or re.op == Op.Plus or re.op == Op.Quest then
        dumpRegexp(b, re.sub[1])
    elseif re.op == Op.Repeat then
        b[#b + 1] = re.min .. "," .. re.max .. " "
        dumpRegexp(b, re.sub[1])
    elseif re.op == Op.Capture then
        if re.name ~= "" then
            b[#b + 1] = re.name
            b[#b + 1] = ":"
        end
        dumpRegexp(b, re.sub[1])
    elseif re.op == Op.CharClass then
        local sep = ""
        local rs = re.rune or {}
        for i = 1, #rs, 2 do
            b[#b + 1] = sep
            sep = " "
            local lo, hi = rs[i], rs[i + 1]
            if lo == hi then
                b[#b + 1] = hex(lo)
            else
                b[#b + 1] = hex(lo) .. "-" .. hex(hi)
            end
        end
    end
    b[#b + 1] = "}"
end

local function dump(re)
    local b = {}
    dumpRegexp(b, re)
    return table.concat(b)
end

local function check(failures)
    if #failures > 0 then
        error(#failures .. " failures:\n" .. table.concat(failures, "\n", 1, math.min(#failures, 50)), 2)
    end
end

-- Test Parse -> Dump.
local function testParseDump(tests, flags)
    local failures = {}
    for _, tt in ipairs(tests) do
        local re, err = syntax.Parse(tt.Regexp, flags)
        if err ~= nil then
            failures[#failures + 1] = string.format("Parse(%q): %s", tt.Regexp, err:Error())
        elseif tt.Dump ~= "" then
            local d = dump(re)
            if d ~= tt.Dump then
                failures[#failures + 1] = string.format("Parse(%q).Dump() = %q want %q", tt.Regexp, d, tt.Dump)
            end
        end
    end
    check(failures)
end

describe("regexp/syntax parse", function()
    it("TestParseSimple", function()
        testParseDump(T.parseTests, testFlags)
    end)
    it("TestParseFoldCase", function()
        testParseDump(T.foldcaseTests, Flags.FoldCase)
    end)
    it("TestParseLiteral", function()
        testParseDump(T.literalTests, Flags.Literal)
    end)
    it("TestParseMatchNL", function()
        testParseDump(T.matchnlTests, Flags.MatchNL)
    end)
    it("TestParseNoMatchNL", function()
        testParseDump(T.nomatchnlTests, 0)
    end)

    it("TestFoldConstants", function()
        local last = -1
        local first = -1
        for i = 0, unicode.MaxRune do
            if unicode.SimpleFold(i) ~= i then
                if last == -1 then
                    first = i
                end
                last = i
            end
        end
        assert.are.equal(first, syntax.minFold)
        assert.are.equal(last, syntax.maxFold)
    end)

    it("TestAppendRangeCollapse", function()
        -- AppendRange should collapse each of the new ranges
        -- into the earlier ones (it looks back two ranges), so that
        -- the slice never grows very large.
        -- Note that we are not calling cleanClass.
        local r = {}
        for i = 0x41, 0x5A do
            r = syntax.appendRange(r, i, i)
            r = syntax.appendRange(r, i + 0x61 - 0x41, i + 0x61 - 0x41)
        end
        assert.are.equal("AZaz", utf8.RunesToString(r))
    end)

    it("TestParseInvalidRegexps", function()
        local failures = {}
        for _, regexp in ipairs(T.invalidRegexps) do
            local re, err = syntax.Parse(regexp, Flags.Perl)
            if err == nil then
                failures[#failures + 1] = string.format("Parse(%q, Perl) = %s, should have failed", regexp, dump(re))
            end
            re, err = syntax.Parse(regexp, Flags.POSIX)
            if err == nil then
                failures[#failures + 1] = string.format("Parse(%q, POSIX) = %s, should have failed", regexp, dump(re))
            end
        end
        for _, regexp in ipairs(T.onlyPerl) do
            local _, err = syntax.Parse(regexp, Flags.Perl)
            if err ~= nil then
                failures[#failures + 1] = string.format("Parse(%q, Perl): %s", regexp, err:Error())
            end
            local re
            re, err = syntax.Parse(regexp, Flags.POSIX)
            if err == nil then
                failures[#failures + 1] = string.format("Parse(%q, POSIX) = %s, should have failed", regexp, dump(re))
            end
        end
        for _, regexp in ipairs(T.onlyPOSIX) do
            local re, err = syntax.Parse(regexp, Flags.Perl)
            if err == nil then
                failures[#failures + 1] = string.format("Parse(%q, Perl) = %s, should have failed", regexp, dump(re))
            end
            _, err = syntax.Parse(regexp, Flags.POSIX)
            if err ~= nil then
                failures[#failures + 1] = string.format("Parse(%q, POSIX): %s", regexp, err:Error())
            end
        end
        check(failures)
    end)

    it("TestToStringEquivalentParse", function()
        local failures = {}
        for _, tt in ipairs(T.parseTests) do
            local re, err = syntax.Parse(tt.Regexp, testFlags)
            if err ~= nil then
                failures[#failures + 1] = string.format("Parse(%q): %s", tt.Regexp, err:Error())
                goto continue
            end
            if tt.Dump == "" then
                -- It parsed. That's all we care about.
                goto continue
            end
            do
                local d = dump(re)
                if d ~= tt.Dump then
                    failures[#failures + 1] = string.format("Parse(%q).Dump() = %q want %q", tt.Regexp, d, tt.Dump)
                    goto continue
                end

                local s = re:String()
                if s ~= tt.Regexp then
                    -- If ToString didn't return the original regexp,
                    -- it must have found one with fewer parens.
                    local nre, err2 = syntax.Parse(s, testFlags)
                    if err2 ~= nil then
                        failures[#failures + 1] = string.format("Parse(%q.String() = %q): %s", tt.Regexp, s, err2:Error())
                        goto continue
                    end
                    local nd = dump(nre)
                    if d ~= nd then
                        failures[#failures + 1] = string.format("Parse(%q) -> %q; %q vs %q", tt.Regexp, s, d, nd)
                    end
                    local ns = nre:String()
                    if s ~= ns then
                        failures[#failures + 1] = string.format("Parse(%q) -> %q -> %q", tt.Regexp, s, ns)
                    end
                end
            end
            ::continue::
        end
        check(failures)
    end)

    it("TestString", function()
        local failures = {}
        for _, tt in ipairs(T.stringTests) do
            local re, err = syntax.Parse(tt.re, Flags.Perl)
            if err ~= nil then
                failures[#failures + 1] = string.format("Parse(%q): %s", tt.re, err:Error())
            else
                local out = re:String()
                if out ~= tt.out then
                    failures[#failures + 1] = string.format("Parse(%q).String() = %q, want %q", tt.re, out, tt.out)
                end
            end
        end
        check(failures)
    end)
end)

describe("regexp/syntax prog", function()
    it("TestCompile", function()
        local failures = {}
        for _, tt in ipairs(T.compileTests) do
            local re = syntax.Parse(tt.Regexp, Flags.Perl)
            local p = syntax.Compile(re)
            local s = p:String()
            if s ~= tt.Prog then
                failures[#failures + 1] = string.format("compiled %q:\n--- have\n%s---\n--- want\n%s---", tt.Regexp, s, tt.Prog)
            end
        end
        check(failures)
    end)

    it("EmptyOpContext", function()
        local EmptyOp = syntax.EmptyOp
        assert.are.equal(EmptyOp.EmptyBeginText | EmptyOp.EmptyBeginLine | EmptyOp.EmptyWordBoundary, syntax.EmptyOpContext(-1, 0x61))
        assert.are.equal(EmptyOp.EmptyEndLine | EmptyOp.EmptyNoWordBoundary, syntax.EmptyOpContext(0x20, 0x0A))
        assert.are.equal(EmptyOp.EmptyNoWordBoundary, syntax.EmptyOpContext(0x61, 0x62))
    end)
end)

describe("regexp/syntax simplify", function()
    it("TestSimplify", function()
        local failures = {}
        for _, tt in ipairs(T.simplifyTests) do
            local re, err = syntax.Parse(tt.Regexp, Flags.MatchNL | (Flags.Perl & ~Flags.OneLine))
            if err ~= nil then
                failures[#failures + 1] = string.format("Parse(%q) = error %s", tt.Regexp, err:Error())
            else
                local s = re:Simplify():String()
                if s ~= tt.Simple then
                    failures[#failures + 1] = string.format("Simplify(%q) = %q, want %q", tt.Regexp, s, tt.Simple)
                end
            end
        end
        check(failures)
    end)
end)
