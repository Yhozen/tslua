-- Port of Go's regexp tests (all_test.go, find_test.go, onepass_test.go).
-- The test tables are dumped from the Go test files into spec/regexp_testdata/tables.lua.
local regexp = require("tslua.regexp")
local syntax = require("tslua.regexp.syntax")

local T = dofile("spec/regexp_testdata/tables.lua")

local function check(failures)
    if #failures > 0 then
        error(#failures .. " failures:\n" .. table.concat(failures, "\n", 1, math.min(#failures, 50)), 2)
    end
end

local function show(v)
    if v == nil then
        return "nil"
    elseif type(v) == "table" then
        local parts = {}
        for i, x in ipairs(v) do
            parts[i] = show(x)
        end
        return "[" .. table.concat(parts, " ") .. "]"
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

local function testName(test)
    return string.format("pat: %q text: %q", test.pat, test.text)
end

local function sub(s, a, b)
    return string.sub(s, a + 1, b)
end

-- strings.NewReader as an io.RuneReader.
local function newReader(s)
    local utf8 = require("tslua.regexp.utf8")
    local r = { s = s, pos = 0 }
    function r:ReadRune()
        if self.pos >= #self.s then
            return 0, 0, "EOF"
        end
        local c, size = utf8.DecodeRuneInString(self.s, self.pos)
        self.pos = self.pos + size
        return c, size, nil
    end
    return r
end

local function compileTest(failures, expr, err)
    local re, e = regexp.Compile(expr)
    if err == "" and e ~= nil then
        failures[#failures + 1] = "compiling `" .. expr .. "`; unexpected error: " .. e:Error()
    end
    if err ~= "" and e == nil then
        failures[#failures + 1] = "compiling `" .. expr .. "`; missing error"
    elseif err ~= "" and not string.find(e:Error(), err, 1, true) then
        failures[#failures + 1] = "compiling `" .. expr .. "`; wrong error: " .. e:Error() .. "; want " .. err
    end
    return re
end

local function nmatches(test)
    return test.matches and #test.matches or 0
end

describe("regexp all_test", function()
    it("TestGoodCompile", function()
        local failures = {}
        for _, re in ipairs(T.goodRe) do
            compileTest(failures, re, "")
        end
        check(failures)
    end)

    it("TestBadCompile", function()
        local failures = {}
        for _, bad in ipairs(T.badRe) do
            compileTest(failures, bad.re, bad.err)
        end
        -- {strings.Repeat(`\pL`, 27000), "expression too large"} (not in the dumped table to keep it small)
        compileTest(failures, string.rep("\\pL", 27000), "expression too large")
        check(failures)
    end)

    it("TestMatch / TestMatchFunction / TestCopyMatch", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            local re = compileTest(failures, test.pat, "")
            if re ~= nil then
                local want = nmatches(test) > 0
                if re:MatchString(test.text) ~= want then
                    failures[#failures + 1] = "MatchString failure on " .. testName(test)
                end
                if re:Match(test.text) ~= want then
                    failures[#failures + 1] = "Match failure on " .. testName(test)
                end
                local m, err = regexp.MatchString(test.pat, test.text)
                if err ~= nil or m ~= want then
                    failures[#failures + 1] = "Match function failure on " .. testName(test)
                end
                if re:Copy():MatchString(test.text) ~= want then
                    failures[#failures + 1] = "Copied Regexp match failure on " .. testName(test)
                end
            end
        end
        check(failures)
    end)

    it("TestReplaceAll", function()
        local failures = {}
        for _, tc in ipairs(T.replaceTests) do
            local re, err = regexp.Compile(tc.pattern)
            if err ~= nil then
                failures[#failures + 1] = string.format("Unexpected error compiling %q: %s", tc.pattern, err:Error())
            else
                local actual = re:ReplaceAllString(tc.input, tc.replacement)
                if actual ~= tc.output then
                    failures[#failures + 1] = string.format("%q.ReplaceAllString(%q,%q) = %q; want %q", tc.pattern, tc.input, tc.replacement, actual, tc.output)
                end
                actual = re:ReplaceAll(tc.input, tc.replacement)
                if actual ~= tc.output then
                    failures[#failures + 1] = string.format("%q.ReplaceAll(%q,%q) = %q; want %q", tc.pattern, tc.input, tc.replacement, actual, tc.output)
                end
            end
        end
        check(failures)
    end)

    it("TestReplaceAllLiteral", function()
        local failures = {}
        local function run(tc)
            local re, err = regexp.Compile(tc.pattern)
            if err ~= nil then
                failures[#failures + 1] = string.format("Unexpected error compiling %q: %s", tc.pattern, err:Error())
                return
            end
            local actual = re:ReplaceAllLiteralString(tc.input, tc.replacement)
            if actual ~= tc.output then
                failures[#failures + 1] = string.format("%q.ReplaceAllLiteralString(%q,%q) = %q; want %q", tc.pattern, tc.input, tc.replacement, actual, tc.output)
            end
            actual = re:ReplaceAllLiteral(tc.input, tc.replacement)
            if actual ~= tc.output then
                failures[#failures + 1] = string.format("%q.ReplaceAllLiteral(%q,%q) = %q; want %q", tc.pattern, tc.input, tc.replacement, actual, tc.output)
            end
        end
        for _, tc in ipairs(T.replaceTests) do
            if not string.find(tc.replacement, "$", 1, true) then
                run(tc)
            end
        end
        for _, tc in ipairs(T.replaceLiteralTests) do
            run(tc)
        end
        check(failures)
    end)

    it("TestReplaceAllFunc", function()
        local function f(s)
            return "x" .. s .. "y"
        end
        local replaceFuncTests = {
            { "[a-c]", f, "defabcdef", "defxayxbyxcydef" },
            { "[a-c]+", f, "defabcdef", "defxabcydef" },
            { "[a-c]*", f, "defabcdef", "xydxyexyfxabcydxyexyfxy" },
        }
        for _, tc in ipairs(replaceFuncTests) do
            local re = regexp.MustCompile(tc[1])
            assert.are.equal(tc[4], re:ReplaceAllStringFunc(tc[3], tc[2]))
            assert.are.equal(tc[4], re:ReplaceAllFunc(tc[3], tc[2]))
        end
    end)

    it("TestQuoteMeta", function()
        local failures = {}
        for _, tc in ipairs(T.metaTests) do
            local quoted = regexp.QuoteMeta(tc.pattern)
            if quoted ~= tc.output then
                failures[#failures + 1] = string.format("QuoteMeta(`%s`) = `%s`; want `%s`", tc.pattern, quoted, tc.output)
            elseif tc.pattern ~= "" then
                local re, err = regexp.Compile(quoted)
                if err ~= nil then
                    failures[#failures + 1] = "Unexpected error compiling QuoteMeta(`" .. tc.pattern .. "`)"
                else
                    local src = "abc" .. tc.pattern .. "def"
                    local replaced = re:ReplaceAllString(src, "xyz")
                    if replaced ~= "abcxyzdef" then
                        failures[#failures + 1] = string.format("QuoteMeta(`%s`).Replace(`%s`,`xyz`) = `%s`; want `abcxyzdef`", tc.pattern, src, replaced)
                    end
                end
            end
        end
        check(failures)
    end)

    it("TestLiteralPrefix", function()
        local failures = {}
        local tests = {}
        for _, tc in ipairs(T.metaTests) do
            tests[#tests + 1] = tc
        end
        for _, tc in ipairs(T.literalPrefixTests) do
            tests[#tests + 1] = tc
        end
        for _, tc in ipairs(tests) do
            local re = regexp.MustCompile(tc.pattern)
            local str, complete = re:LiteralPrefix()
            if complete ~= tc.isLiteral then
                failures[#failures + 1] = string.format("LiteralPrefix(`%s`) = %s; want %s", tc.pattern, tostring(complete), tostring(tc.isLiteral))
            end
            if str ~= tc.literal then
                failures[#failures + 1] = string.format("LiteralPrefix(`%s`) = `%s`; want `%s`", tc.pattern, str, tc.literal)
            end
        end
        check(failures)
    end)

    it("TestSubexp", function()
        local failures = {}
        for _, c in ipairs(T.subexpCases) do
            local re = regexp.MustCompile(c.input)
            local n = re:NumSubexp()
            if n ~= c.num then
                failures[#failures + 1] = string.format("%q: NumSubexp = %d, want %d", c.input, n, c.num)
                goto continue
            end
            do
                local names = re:SubexpNames()
                if #names ~= 1 + n then
                    failures[#failures + 1] = string.format("%q: len(SubexpNames) = %d, want %d", c.input, #names, n)
                    goto continue
                end
                if c.names ~= nil then
                    for i = 1, 1 + n do
                        if names[i] ~= c.names[i] then
                            failures[#failures + 1] = string.format("%q: SubexpNames[%d] = %q, want %q", c.input, i - 1, names[i], c.names[i])
                        end
                    end
                end
                for _, subexp in ipairs(c.indices) do
                    local index = re:SubexpIndex(subexp.name)
                    if index ~= subexp.index then
                        failures[#failures + 1] = string.format("%q: SubexpIndex(%q) = %d, want %d", c.input, subexp.name, index, subexp.index)
                    end
                end
            end
            ::continue::
        end
        check(failures)
    end)

    it("TestSplit", function()
        local failures = {}
        for i, test in ipairs(T.splitTests) do
            local re, err = regexp.Compile(test.r)
            if err ~= nil then
                failures[#failures + 1] = string.format("#%d: %q: compile error: %s", i - 1, test.r, err:Error())
            else
                local split = re:Split(test.s, test.n)
                if show(split) ~= show(test.out) then
                    failures[#failures + 1] = string.format("#%d: %q: got %s; want %s", i - 1, test.r, show(split), show(test.out))
                end
            end
        end
        check(failures)
    end)

    it("TestParseAndCompile", function()
        local expr = "a$"
        local s = "a\nb"
        for _, tc in ipairs({
            { syntax.Flags.Perl | syntax.Flags.OneLine, false },
            { syntax.Flags.Perl & ~syntax.Flags.OneLine, true },
        }) do
            local parsed = assert(syntax.Parse(expr, tc[1]))
            local re = assert(regexp.Compile(parsed:String()))
            assert.are.equal(tc[2], re:MatchString(s))
        end
    end)

    it("TestOnePassCutoff", function()
        local re = assert(syntax.Parse("^x{1,1000}y{1,1000}$", syntax.Flags.Perl))
        local p = assert(syntax.Compile(re:Simplify()))
        assert.is_nil(regexp.compileOnePass(p))
    end)

    it("TestSwitchBacktrack", function()
        local re = regexp.MustCompile("a|b")
        local long = string.rep("\0", regexp.maxBacktrackVector + 1)
        assert.is_false(re:Match(long)) -- triggers standard matcher
        assert.is_false(re:Match(string.sub(long, 1, 1))) -- triggers backtracker
    end)

    it("TestMinInputLen", function()
        local failures = {}
        for _, tt in ipairs(T.minInputLenTests) do
            local re = syntax.Parse(tt.Regexp, syntax.Flags.Perl)
            local m = regexp.minInputLen(re)
            if m ~= tt.min then
                failures[#failures + 1] = string.format("regexp %q has minInputLen %d, should be %d", tt.Regexp, m, tt.min)
            end
        end
        check(failures)
    end)

    it("TestUnmarshalText", function()
        local unmarshaled = setmetatable({}, regexp.Regexp)
        for _, good in ipairs(T.goodRe) do
            local re = regexp.MustCompile(good)
            local marshaled = re:MarshalText()
            assert.is_nil(unmarshaled:UnmarshalText(marshaled))
            assert.are.equal(good, unmarshaled:String())
            local marshalAppend = re:AppendText("abcd")
            assert.is_nil(unmarshaled:UnmarshalText(string.sub(marshalAppend, 5)))
            assert.are.equal(good, unmarshaled:String())
        end
        assert.is_not_nil(setmetatable({}, regexp.Regexp):UnmarshalText("\\"))
    end)

    it("MustCompile panics with Go's message", function()
        local ok, err = pcall(regexp.MustCompile, "a(b")
        assert.is_false(ok)
        assert.are.equal("regexp: Compile(`a(b`): error parsing regexp: missing closing ): `a(b`", err)
    end)
end)

describe("regexp find_test", function()
    it("TestFind / TestFindString", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            local re = regexp.MustCompile(test.pat)
            if re:String() ~= test.pat then
                failures[#failures + 1] = string.format("re.String() = %q, want %q", re:String(), test.pat)
            end
            local result = re:Find(test.text)
            if nmatches(test) == 0 and (result == nil or #result == 0) then
                -- ok
            elseif test.matches == nil and result ~= nil then
                failures[#failures + 1] = "Find: got match, want none: " .. testName(test)
            elseif test.matches ~= nil and result == nil then
                failures[#failures + 1] = "Find: got no match, want one: " .. testName(test)
            else
                local want = sub(test.text, test.matches[1][1], test.matches[1][2])
                if want ~= result then
                    failures[#failures + 1] = string.format("Find: got %q, want %q: %s", result, want, testName(test))
                end
            end
            local sresult = re:FindString(test.text)
            if nmatches(test) == 0 and #sresult == 0 then
                -- ok
            elseif test.matches == nil and sresult ~= "" then
                failures[#failures + 1] = "FindString: got match, want none: " .. testName(test)
            elseif test.matches ~= nil and sresult == "" then
                if test.matches[1][1] ~= test.matches[1][2] then
                    failures[#failures + 1] = "FindString: got no match, want one: " .. testName(test)
                end
            else
                local want = sub(test.text, test.matches[1][1], test.matches[1][2])
                if want ~= sresult then
                    failures[#failures + 1] = string.format("FindString: got %q, want %q: %s", sresult, want, testName(test))
                end
            end
        end
        check(failures)
    end)

    local function testFindIndex(failures, what, test, result)
        if nmatches(test) == 0 and (result == nil or #result == 0) then
            return
        elseif test.matches == nil and result ~= nil then
            failures[#failures + 1] = what .. ": got match " .. show(result) .. ", want none: " .. testName(test)
        elseif test.matches ~= nil and result == nil then
            failures[#failures + 1] = what .. ": got no match, want one: " .. testName(test)
        else
            local want = test.matches[1]
            if want[1] ~= result[1] or want[2] ~= result[2] then
                failures[#failures + 1] = what .. ": got " .. show(result) .. ", want " .. show(want) .. ": " .. testName(test)
            end
        end
    end

    it("TestFindIndex / TestFindStringIndex / TestFindReaderIndex", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            testFindIndex(failures, "FindIndex", test, regexp.MustCompile(test.pat):FindIndex(test.text))
            testFindIndex(failures, "FindStringIndex", test, regexp.MustCompile(test.pat):FindStringIndex(test.text))
            testFindIndex(failures, "FindReaderIndex", test, regexp.MustCompile(test.pat):FindReaderIndex(newReader(test.text)))
        end
        check(failures)
    end)

    it("TestFindAll / TestFindAllString", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            for _, which in ipairs({ "FindAll", "FindAllString" }) do
                local re = regexp.MustCompile(test.pat)
                local result = re[which](re, test.text, -1)
                if test.matches == nil and result == nil then
                    -- ok
                elseif test.matches == nil and result ~= nil then
                    failures[#failures + 1] = which .. ": got match, want none: " .. testName(test)
                elseif test.matches ~= nil and result == nil then
                    failures[#failures + 1] = which .. ": got no match, want one: " .. testName(test)
                elseif #test.matches ~= #result then
                    failures[#failures + 1] = string.format("%s: got %d matches, want %d: %s", which, #result, #test.matches, testName(test))
                else
                    for k, e in ipairs(test.matches) do
                        local want = sub(test.text, e[1], e[2])
                        if want ~= result[k] then
                            failures[#failures + 1] = string.format("%s: match %d: got %q, want %q: %s", which, k - 1, result[k], want, testName(test))
                        end
                    end
                end
            end
        end
        check(failures)
    end)

    local function testFindAllIndex(failures, what, test, result)
        if test.matches == nil and result == nil then
            return
        elseif test.matches == nil and result ~= nil then
            failures[#failures + 1] = what .. ": got match " .. show(result) .. ", want none: " .. testName(test)
        elseif test.matches ~= nil and result == nil then
            failures[#failures + 1] = what .. ": got no match, want one: " .. testName(test)
        elseif #test.matches ~= #result then
            failures[#failures + 1] = string.format("%s: got %d matches, want %d: %s", what, #result, #test.matches, testName(test))
        else
            for k, e in ipairs(test.matches) do
                if e[1] ~= result[k][1] or e[2] ~= result[k][2] then
                    failures[#failures + 1] = what .. ": match " .. (k - 1) .. ": got " .. show(result[k]) .. ", want " .. show(e) .. ": " .. testName(test)
                end
            end
        end
    end

    it("TestFindAllIndex / TestFindAllStringIndex", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            testFindAllIndex(failures, "FindAllIndex", test, regexp.MustCompile(test.pat):FindAllIndex(test.text, -1))
            testFindAllIndex(failures, "FindAllStringIndex", test, regexp.MustCompile(test.pat):FindAllStringIndex(test.text, -1))
        end
        check(failures)
    end)

    local function testSubmatch(failures, what, test, n, submatches, result, unmatched)
        if #submatches ~= #result * 2 then
            failures[#failures + 1] = string.format("%s: match %d: got %d submatches, want %d: %s", what, n, #result, #submatches // 2, testName(test))
            return
        end
        for k = 0, #submatches - 1, 2 do
            if submatches[k + 1] == -1 then
                if result[k // 2 + 1] ~= unmatched then
                    failures[#failures + 1] = string.format("%s: match %d: got %s, want unmatched: %s", what, n, show(result), testName(test))
                end
            else
                local want = sub(test.text, submatches[k + 1], submatches[k + 2])
                if want ~= result[k // 2 + 1] then
                    failures[#failures + 1] = string.format("%s: match %d: got %s, want %q: %s", what, n, show(result[k // 2 + 1]), want, testName(test))
                    return
                end
            end
        end
    end

    it("TestFindSubmatch / TestFindStringSubmatch", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            for _, which in ipairs({ "FindSubmatch", "FindStringSubmatch" }) do
                local re = regexp.MustCompile(test.pat)
                local result = re[which](re, test.text)
                if test.matches == nil and result == nil then
                    -- ok
                elseif test.matches == nil and result ~= nil then
                    failures[#failures + 1] = which .. ": got match, want none: " .. testName(test)
                elseif test.matches ~= nil and result == nil then
                    failures[#failures + 1] = which .. ": got no match, want one: " .. testName(test)
                else
                    testSubmatch(failures, which, test, 0, test.matches[1], result, (which ~= "FindSubmatch") and "")
                end
            end
        end
        check(failures)
    end)

    local function testSubmatchIndices(failures, what, test, n, want, result)
        if #want ~= #result then
            failures[#failures + 1] = string.format("%s: match %d: got %d matches, want %d: %s", what, n, #result // 2, #want // 2, testName(test))
            return
        end
        for k, e in ipairs(want) do
            if e ~= result[k] then
                failures[#failures + 1] = string.format("%s: match %d: submatch error: got %s, want %s: %s", what, n, show(result), show(want), testName(test))
                return
            end
        end
    end

    local function testFindSubmatchIndex(failures, what, test, result)
        if test.matches == nil and result == nil then
            return
        elseif test.matches == nil and result ~= nil then
            failures[#failures + 1] = what .. ": got match " .. show(result) .. ", want none: " .. testName(test)
        elseif test.matches ~= nil and result == nil then
            failures[#failures + 1] = what .. ": got no match, want one: " .. testName(test)
        else
            testSubmatchIndices(failures, what, test, 0, test.matches[1], result)
        end
    end

    it("TestFindSubmatchIndex / TestFindStringSubmatchIndex / TestFindReaderSubmatchIndex", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            local re = regexp.MustCompile(test.pat)
            testFindSubmatchIndex(failures, "FindSubmatchIndex", test, re:FindSubmatchIndex(test.text))
            testFindSubmatchIndex(failures, "FindStringSubmatchIndex", test, re:FindStringSubmatchIndex(test.text))
            testFindSubmatchIndex(failures, "FindReaderSubmatchIndex", test, re:FindReaderSubmatchIndex(newReader(test.text)))
        end
        check(failures)
    end)

    it("TestFindAllSubmatch / TestFindAllStringSubmatch", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            for _, which in ipairs({ "FindAllSubmatch", "FindAllStringSubmatch" }) do
                local re = regexp.MustCompile(test.pat)
                local result = re[which](re, test.text, -1)
                if test.matches == nil and result == nil then
                    -- ok
                elseif test.matches == nil and result ~= nil then
                    failures[#failures + 1] = which .. ": got match, want none: " .. testName(test)
                elseif test.matches ~= nil and result == nil then
                    failures[#failures + 1] = which .. ": got no match, want one: " .. testName(test)
                elseif #test.matches ~= #result then
                    failures[#failures + 1] = string.format("%s: got %d matches, want %d: %s", which, #result, #test.matches, testName(test))
                else
                    for k, match in ipairs(test.matches) do
                        testSubmatch(failures, which, test, k - 1, match, result[k], (which ~= "FindAllSubmatch") and "")
                    end
                end
            end
        end
        check(failures)
    end)

    it("TestFindAllSubmatchIndex / TestFindAllStringSubmatchIndex", function()
        local failures = {}
        for _, test in ipairs(T.findTests) do
            for _, which in ipairs({ "FindAllSubmatchIndex", "FindAllStringSubmatchIndex" }) do
                local re = regexp.MustCompile(test.pat)
                local result = re[which](re, test.text, -1)
                if test.matches == nil and result == nil then
                    -- ok
                elseif test.matches == nil and result ~= nil then
                    failures[#failures + 1] = which .. ": got match, want none: " .. testName(test)
                elseif test.matches ~= nil and result == nil then
                    failures[#failures + 1] = which .. ": got no match, want one: " .. testName(test)
                elseif #test.matches ~= #result then
                    failures[#failures + 1] = string.format("%s: got %d matches, want %d: %s", which, #result, #test.matches, testName(test))
                else
                    for k, match in ipairs(test.matches) do
                        testSubmatchIndices(failures, which, test, k - 1, match, result[k])
                    end
                end
            end
        end
        check(failures)
    end)
end)

describe("regexp onepass_test", function()
    it("TestMergeRuneSet", function()
        local failures = {}
        for ix, test in ipairs(T.runeMergeTests) do
            local merged, next = regexp.mergeRuneSets(test.left, test.right, test.leftPC, test.rightPC)
            if show(merged) ~= show(test.merged) then
                failures[#failures + 1] = string.format("mergeRuneSet :%d(%s, %s) merged have %s want %s", ix - 1, show(test.left), show(test.right), show(merged), show(test.merged))
            end
            if show(next) ~= show(test.next) then
                failures[#failures + 1] = string.format("mergeRuneSet :%d(%s, %s) next have %s want %s", ix - 1, show(test.left), show(test.right), show(next), show(test.next))
            end
        end
        check(failures)
    end)

    it("TestCompileOnePass", function()
        local failures = {}
        local tests = {}
        for _, test in ipairs(T.onePassTests) do
            tests[#tests + 1] = test
        end
        for _, test in ipairs(tests) do
            local re, err = syntax.Parse(test.re, syntax.Flags.Perl)
            if err ~= nil then
                failures[#failures + 1] = string.format("Parse(%q) got err:%s, want success", test.re, err:Error())
            else
                -- needs to be done before compile...
                re = re:Simplify()
                local p = syntax.Compile(re)
                local isOnePass = regexp.compileOnePass(p) ~= nil
                if isOnePass ~= test.isOnePass then
                    failures[#failures + 1] = string.format("CompileOnePass(%q) got isOnePass=%s, expected %s", test.re, tostring(isOnePass), tostring(test.isOnePass))
                end
            end
        end
        check(failures)
    end)

    it("TestRunOnePass", function()
        for _, test in ipairs(T.onePassTests1) do
            local re = assert(regexp.Compile(test.re))
            assert.is_not_nil(re.onepass)
            assert.is_true(re:MatchString(test.match))
        end
    end)
end)
