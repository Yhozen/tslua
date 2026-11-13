-- The per-line hot paths of the test harness keep small hand-written matchers for Go regexps
-- (tslua.regexp's NFA costs ~3us/byte in Lua). Check them against tslua.regexp on real test
-- files and edge cases, so they stay behaviorally identical to the Go regexps.
local regexp = require("tslua.regexp")
local testrunner = require("tslua.testrunner")
local tsbaseline = require("tslua.testutil.tsbaseline")
local diagnostics = require("tslua.diagnostics")

local function show(v)
    if v == nil then
        return "nil"
    elseif type(v) == "table" then
        local parts = {}
        for i, x in ipairs(v) do
            parts[i] = show(x)
        end
        return "[" .. table.concat(parts, " ") .. "]"
    end
    return string.format("%q", v)
end

local edgeCases = {
    "", "\n", "\r\n", "\r", "\n\n", "\r\r\n", "a\r\nb\nc\r", "x\u{2028}y\u{2029}z\r\n",
    "// @target: es5\n// @strict:true\r\n//@lib : dom, es6  \n  // @noEmit: true",
    "// @link: a.ts -> b.ts\n// @link : /x -> /y -> /z\n//@link:foo->bar",
    "//  @module:\n// @ : x\n// @a b: c\n/// @x: y\n// @é: no\n",
    "  {  ", "|", "}", " { x", "\t}\t", "{}", "\v{", " \f{ ",
    "héllo wörld\t\xff\xfeend", "a\0b", "{0} {1} {12}", "{x}{01}{",
}

local function corpus()
    local files = {}
    local dir = "vendor/typescript-go/testdata/tests/cases/compiler"
    local p = io.popen("ls " .. dir .. " 2>/dev/null | head -150")
    if p ~= nil then
        for name in p:lines() do
            local f = io.open(dir .. "/" .. name, "rb")
            if f ~= nil then
                files[#files + 1] = f:read("a")
                f:close()
            end
        end
        p:close()
    end
    for _, s in ipairs(edgeCases) do
        files[#files + 1] = s
    end
    return files
end

local function lines(s)
    local out = {}
    for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

describe("regexp stand-ins", function()
    local inputs = corpus()

    it("testrunner lineDelimiter / optionRegex / linkRegex", function()
        local lineDelimiter = regexp.MustCompile("\r?\n")
        local optionRegex = regexp.MustCompile("(?m)^\\/{2}\\s*@(\\w+)\\s*:\\s*([^\\r\\n]*)")
        local linkRegex = regexp.MustCompile("(?m)^\\/{2}\\s*@link\\s*:\\s*([^\\r\\n]*)\\s*->\\s*([^\\r\\n]*)")
        for _, s in ipairs(inputs) do
            assert.are.equal(show(lineDelimiter:Split(s, -1)), show(testrunner.lineDelimiter:Split(s, -1)))
            assert.are.equal(show(optionRegex:FindAllStringSubmatch(s, -1) or {}), show(testrunner.optionRegex:FindAllStringSubmatch(s, -1)))
            for _, line in ipairs(lineDelimiter:Split(s, -1)) do
                assert.are.equal(show(optionRegex:FindStringSubmatch(line)), show(testrunner.optionRegex:FindStringSubmatch(line)))
                assert.are.equal(show(linkRegex:FindStringSubmatch(line)), show(testrunner.linkRegex:FindStringSubmatch(line)))
            end
        end
    end)

    it("tsbaseline lineDelimiter / nonWhitespace / codeLinesRegexp / bracketLineRegex", function()
        local lineDelimiter = regexp.MustCompile("\r?\n")
        local nonWhitespace = regexp.MustCompile("\\S")
        local codeLinesRegexp = regexp.MustCompile("[\r\u{2028}\u{2029}]|\r?\n")
        local bracketLineRegex = regexp.MustCompile("^\\s*[{|}]\\s*$")
        for _, s in ipairs(inputs) do
            assert.are.equal(show(lineDelimiter:Split(s, -1)), show(tsbaseline.lineDelimiter:Split(s, -1)))
            assert.are.equal(show(codeLinesRegexp:Split(s, -1)), show(tsbaseline.codeLinesRegexp:Split(s, -1)))
            for _, line in ipairs(codeLinesRegexp:Split(s, -1)) do
                assert.are.equal(nonWhitespace:ReplaceAllString(line, " "), tsbaseline.nonWhitespace:ReplaceAllString(line, " "))
                assert.are.equal(bracketLineRegex:MatchString(line), tsbaseline.bracketLineRegex:MatchString(line))
            end
            for _, line in ipairs(lines(s)) do
                if #line < 200 then
                    assert.are.equal(lineDelimiter:ReplaceAllString(line .. "\r\nx\ny", ""), tsbaseline.lineDelimiter:ReplaceAllString(line .. "\r\nx\ny", ""))
                end
            end
        end
    end)

    it("diagnostics.Format placeholderRegexp", function()
        local placeholderRegexp = regexp.MustCompile("{(\\d+)}")
        local args = { "zero", "one", "two" }
        for _, text in ipairs({ "Cannot find name '{0}'.", "{1}{0}{2}", "{x} {0}{", "{{0}}", "no placeholders", "{00}{01}" }) do
            local want = placeholderRegexp:ReplaceAllStringFunc(text, function(match)
                return args[tonumber(string.sub(match, 2, -2)) + 1]
            end)
            assert.are.equal(want, diagnostics.Format(text, args))
        end
    end)
end)
