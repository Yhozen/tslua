-- Port of Go's regexp exec_test.go: the RE2 search/exhaustive test files and the AT&T POSIX
-- (Fowler) test files in spec/regexp_testdata (copied from Go's src/regexp/testdata).
local regexp = require("tslua.regexp")
local syntax = require("tslua.regexp.syntax")
local utf8 = require("tslua.regexp.utf8")

local function check(failures)
    if #failures > 0 then
        error(#failures .. " failures:\n" .. table.concat(failures, "\n", 1, math.min(#failures, 50)), 2)
    end
end

local function show(v)
    if v == nil then
        return "nil"
    end
    return "[" .. table.concat(v, " ") .. "]"
end

local function equalInts(a, b)
    if a == nil or b == nil then
        return (a == nil or #a == 0) and (b == nil or #b == 0)
    end
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Go strconv.Unquote for a double-quoted Go string literal; returns nil on error.
local function unquote(s)
    if #s < 2 or string.sub(s, 1, 1) ~= '"' or string.sub(s, -1) ~= '"' then
        return nil
    end
    s = string.sub(s, 2, -2)
    local out = {}
    local i = 1
    local simple = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"' }
    while i <= #s do
        local c = string.sub(s, i, i)
        if c == '"' or c == "\n" then
            return nil
        end
        if c ~= "\\" then
            out[#out + 1] = c
            i = i + 1
        else
            local e = string.sub(s, i + 1, i + 1)
            if simple[e] then
                out[#out + 1] = simple[e]
                i = i + 2
            elseif e == "x" then
                out[#out + 1] = string.char(tonumber(string.sub(s, i + 2, i + 3), 16))
                i = i + 4
            elseif e == "u" then
                out[#out + 1] = utf8.EncodeRune(tonumber(string.sub(s, i + 2, i + 5), 16))
                i = i + 6
            elseif e == "U" then
                out[#out + 1] = utf8.EncodeRune(tonumber(string.sub(s, i + 2, i + 9), 16))
                i = i + 10
            elseif e:match("[0-7]") then
                out[#out + 1] = string.char(tonumber(string.sub(s, i + 1, i + 3), 8))
                i = i + 4
            else
                return nil
            end
        end
    end
    return table.concat(out)
end

local function isSingleBytes(s)
    return not string.find(s, "[\128-\255]")
end

local function tryCompile(s)
    local ok, re, err = pcall(regexp.Compile, s)
    if not ok then
        return nil, { Error = function()
            return "panic: " .. tostring(re)
        end }
    end
    return re, err
end

local function parseResult(failures, file, lineno, res)
    -- A single - indicates no match.
    if res == "-" then
        return nil
    end
    -- Otherwise, a space-separated list of pairs.
    local out = {}
    for pair in string.gmatch(res, "[^ ]+") do
        if pair == "-" then
            out[#out + 1] = -1
            out[#out + 1] = -1
        else
            local lo, hi = string.match(pair, "^(%d+)-(%d+)$")
            if lo == nil or tonumber(lo) > tonumber(hi) then
                failures[#failures + 1] = string.format("%s:%d: invalid pair %s", file, lineno, pair)
                return nil
            end
            out[#out + 1] = tonumber(lo)
            out[#out + 1] = tonumber(hi)
        end
    end
    return out
end

local run = {
    function(re, refull, text)
        refull.longest = false
        return refull:FindStringSubmatchIndex(text), "[full]"
    end,
    function(re, refull, text)
        re.longest = false
        return re:FindStringSubmatchIndex(text), ""
    end,
    function(re, refull, text)
        refull.longest = true
        return refull:FindStringSubmatchIndex(text), "[full,longest]"
    end,
    function(re, refull, text)
        re.longest = true
        return re:FindStringSubmatchIndex(text), "[longest]"
    end,
}

local match = {
    function(re, refull, text)
        refull.longest = false
        return refull:MatchString(text), "[full]"
    end,
    function(re, refull, text)
        re.longest = false
        return re:MatchString(text), ""
    end,
    function(re, refull, text)
        refull.longest = true
        return refull:MatchString(text), "[full,longest]"
    end,
    function(re, refull, text)
        re.longest = true
        return re:MatchString(text), "[longest]"
    end,
}

local function testRE2(lines, file)
    local failures = {}
    local str = {}
    local input = {}
    local inputPos = 1
    local inStrings = false
    local re, refull
    local ncase = 0
    local lineno = 0
    for line in lines do
        lineno = lineno + 1
        local c = string.sub(line, 1, 1)
        if line == "" then
            error(string.format("%s:%d: unexpected blank line", file, lineno))
        elseif c == "#" then
            -- comment
        elseif c >= "A" and c <= "Z" then
            -- Test name.
        elseif line == "strings" then
            str = {}
            inStrings = true
        elseif line == "regexps" then
            inStrings = false
        elseif c == '"' then
            local q = unquote(line)
            if q == nil then
                error(string.format("%s:%d: unquote %s", file, lineno, line))
            end
            if inStrings then
                str[#str + 1] = q
            else
                -- Is a regexp.
                if inputPos <= #input then
                    error(string.format("%s:%d: out of sync: have %d strings left before %q", file, lineno, #input - inputPos + 1, q))
                end
                local err
                re, err = tryCompile(q)
                if err ~= nil then
                    if err:Error() ~= "error parsing regexp: invalid escape sequence: `\\C`" then
                        -- We don't and likely never will support \C; keep going.
                        failures[#failures + 1] = string.format("%s:%d: compile %q: %s", file, lineno, q, err:Error())
                    end
                    re = nil
                else
                    local full = "\\A(?:" .. q .. ")\\z"
                    refull, err = tryCompile(full)
                    if err ~= nil then
                        error(string.format("%s:%d: compile full %q: %s", file, lineno, full, err:Error()))
                    end
                    input = str
                    inputPos = 1
                end
            end
        elseif c == "-" or (c >= "0" and c <= "9") then
            -- A sequence of match results.
            ncase = ncase + 1
            if re ~= nil then
                if inputPos > #input then
                    error(string.format("%s:%d: out of sync: no input remaining", file, lineno))
                end
                local text = input[inputPos]
                inputPos = inputPos + 1
                if not isSingleBytes(text) and string.find(re:String(), "\\B", 1, true) then
                    -- RE2's \B considers every byte position,
                    -- so it sees 'not word boundary' in the
                    -- middle of UTF-8 sequences. This package
                    -- only considers the positions between runes,
                    -- so it disagrees. Skip those cases.
                    goto continue
                end
                local res = {}
                for part in string.gmatch(line .. ";", "([^;]*);") do
                    res[#res + 1] = part
                end
                if #res ~= #run then
                    error(string.format("%s:%d: have %d test results, want %d", file, lineno, #res, #run))
                end
                for i = 1, #res do
                    local have, suffix = run[i](re, refull, text)
                    local want = parseResult(failures, file, lineno, res[i])
                    if not equalInts(have, want) then
                        failures[#failures + 1] = string.format("%s:%d: %q%s.FindSubmatchIndex(%q) = %s, want %s", file, lineno, re:String(), suffix, text, show(have), show(want))
                    else
                        local b
                        b, suffix = match[i](re, refull, text)
                        if b ~= (want ~= nil) then
                            failures[#failures + 1] = string.format("%s:%d: %q%s.MatchString(%q) = %s, want %s", file, lineno, re:String(), suffix, text, tostring(b), tostring(not b))
                        end
                    end
                    if #failures >= 100 then
                        check(failures)
                    end
                end
            end
        else
            error(string.format("%s:%d: out of sync: %s", file, lineno, line))
        end
        ::continue::
    end
    if inputPos <= #input then
        error(string.format("%s:%d: out of sync: have %d strings left at EOF", file, lineno, #input - inputPos + 1))
    end
    check(failures)
    return ncase
end

local function parseFowlerResult(s)
    if s == "" then
        -- Match with no position information.
        return true, true, true, nil
    elseif s == "NOMATCH" then
        -- Match failure.
        return true, true, false, nil
    elseif string.match(s, "^[A-Z]") then
        -- All the other error codes are compile errors.
        return true, false, false, nil
    end
    local x = {}
    while s ~= "" do
        local end_ = ")"
        if #x % 2 == 0 then
            if string.sub(s, 1, 1) ~= "(" then
                return false, true, false, nil
            end
            s = string.sub(s, 2)
            end_ = ","
        end
        local i = 0
        while i < #s and string.sub(s, i + 1, i + 1) ~= end_ do
            i = i + 1
        end
        if i == 0 or i == #s then
            return false, true, false, nil
        end
        local v = -1
        if string.sub(s, 1, i) ~= "?" then
            v = tonumber(string.sub(s, 1, i))
            if v == nil or math.type(v) ~= "integer" then
                return false, true, false, nil
            end
        end
        x[#x + 1] = v
        s = string.sub(s, i + 2)
    end
    if #x % 2 ~= 0 then
        return false, true, false, nil
    end
    return true, true, true, x
end

local notab = regexp.MustCompilePOSIX("[^\t]+")

local function testFowler(file)
    local failures = {}
    local lineno = 0
    local lastRegexp = ""
    for line in io.lines(file) do
        lineno = lineno + 1
        if line == "" or string.sub(line, 1, 1) == "#" then
            goto continue
        end
        do
            local field = notab:FindAllString(line, -1) or {}
            for i, f in ipairs(field) do
                if f == "NULL" then
                    field[i] = ""
                end
                if f == "NIL" then
                    goto continue
                end
            end
            if #field == 0 then
                goto continue
            end

            -- Field 1: the regex(3) flags to apply, one character per REG_feature
            -- flag. The test is skipped if REG_feature is not supported by the
            -- implementation. If the first character is not [BEASKLP] then the
            -- specification is a global control line.
            local flag = field[1]
            local f0 = string.sub(flag, 1, 1)
            if string.find("?&|;{}", f0, 1, true) then
                -- Ignore all the control operators.
                -- Just run everything.
                flag = string.sub(flag, 2)
                if flag == "" then
                    goto continue
                end
            elseif f0 == ":" then
                local k = string.find(flag, ":", 2, true)
                if k == nil then
                    goto continue
                end
                flag = string.sub(flag, k + 1)
            elseif string.find("CNT0123456789", f0, 1, true) then
                goto continue
            end

            -- Can check field count now that we've handled the myriad comment formats.
            if #field < 4 then
                failures[#failures + 1] = string.format("%s:%d: too few fields: %s", file, lineno, line)
                goto continue
            end

            -- Expand C escapes (a.k.a. Go escapes).
            if string.find(flag, "$", 1, true) then
                local f = '"' .. field[2] .. '"'
                field[2] = unquote(f)
                if field[2] == nil then
                    failures[#failures + 1] = string.format("%s:%d: cannot unquote %s", file, lineno, f)
                end
                f = '"' .. field[3] .. '"'
                field[3] = unquote(f)
                if field[3] == nil then
                    failures[#failures + 1] = string.format("%s:%d: cannot unquote %s", file, lineno, f)
                end
            end

            -- Field 2: the regular expression pattern; SAME uses the pattern from
            -- the previous specification.
            if field[2] == "SAME" then
                field[2] = lastRegexp
            end
            lastRegexp = field[2]

            -- Field 3: the string to match.
            local text = field[3]

            -- Field 4: the test outcome...
            local ok, shouldCompile, shouldMatch, pos = parseFowlerResult(field[4])
            if not ok then
                failures[#failures + 1] = string.format("%s:%d: cannot parse result %q", file, lineno, field[4])
                goto continue
            end

            -- Field 5: optional comment appended to the report.

            for k = 1, #flag do
                local c = string.sub(flag, k, k)
                local pattern = field[2]
                local syn = syntax.Flags.POSIX | syntax.Flags.ClassNL
                if c == "E" then
                    -- extended regexp (what we support)
                elseif c == "L" then
                    -- literal
                    pattern = regexp.QuoteMeta(pattern)
                else
                    goto testing
                end

                if string.find(flag, "i", 1, true) then
                    syn = syn | syntax.Flags.FoldCase
                end

                do
                    local re, err = regexp.compile(pattern, syn, true)
                    if err ~= nil then
                        if shouldCompile then
                            failures[#failures + 1] = string.format("%s:%d: %q did not compile", file, lineno, pattern)
                        end
                        goto testing
                    end
                    if not shouldCompile then
                        failures[#failures + 1] = string.format("%s:%d: %q should not compile", file, lineno, pattern)
                        goto testing
                    end
                    local m = re:MatchString(text)
                    if m ~= shouldMatch then
                        failures[#failures + 1] = string.format("%s:%d: %q.Match(%q) = %s, want %s", file, lineno, pattern, text, tostring(m), tostring(shouldMatch))
                        goto testing
                    end
                    local have = re:FindStringSubmatchIndex(text)
                    if (have ~= nil and #have > 0) ~= m then
                        failures[#failures + 1] = string.format("%s:%d: %q.Match(%q) = %s, but FindSubmatchIndex = %s", file, lineno, pattern, text, tostring(m), show(have))
                        goto testing
                    end
                    if have ~= nil and pos ~= nil and #have > #pos then
                        local cut = {}
                        for j = 1, #pos do
                            cut[j] = have[j]
                        end
                        have = cut
                    end
                    if not equalInts(have, pos) then
                        failures[#failures + 1] = string.format("%s:%d: %q.FindSubmatchIndex(%q) = %s, want %s", file, lineno, pattern, text, show(have), show(pos))
                    end
                end
                ::testing::
            end
        end
        ::continue::
    end
    check(failures)
end


describe("regexp exec_test", function()
    it("TestRE2Search", function()
        local ncase = testRE2(io.lines("spec/regexp_testdata/re2-search.txt"), "re2-search.txt")
        assert.is_true(ncase > 0)
    end)

    it("TestRE2Exhaustive #slow", function()
        local p = assert(io.popen("bzip2 -dc spec/regexp_testdata/re2-exhaustive.txt.bz2"))
        local ncase = testRE2(p:lines(), "re2-exhaustive.txt")
        p:close()
        assert.is_true(ncase > 0)
    end)

    it("TestFowler", function()
        for _, file in ipairs({ "basic.dat", "nullsubexpr.dat", "repetition.dat" }) do
            testFowler("spec/regexp_testdata/" .. file)
        end
    end)

    it("TestLongest", function()
        local re = assert(regexp.Compile("a(|b)"))
        assert.are.equal("a", re:FindString("ab"))
        re:Longest()
        assert.are.equal("ab", re:FindString("ab"))
    end)

    it("TestProgramTooLongForBacktrack", function()
        local words = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen" }
        local tens = { "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety" }
        local alts = {}
        for _, w in ipairs(words) do
            alts[#alts + 1] = w
        end
        for _, t in ipairs(tens) do
            alts[#alts + 1] = t
            for k = 1, 9 do
                alts[#alts + 1] = t .. words[k]
            end
        end
        alts[#alts + 1] = "onehundred"
        local longRegex = regexp.MustCompile("(" .. table.concat(alts, "|") .. ")")
        assert.is_true(longRegex:MatchString("two"))
        assert.is_false(longRegex:MatchString("xxx"))
    end)
end)
