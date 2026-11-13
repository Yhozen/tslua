-- Regression tests for problems found by comparing bin/tslua with tsgo on real-world projects
-- (scripts/realworld/). Output differences get a repro here; the problems found so far were
-- Lua-only quadratic costs (the output was already identical), so these pin the semantics of
-- the faster code and a deterministic proxy of its cost.
local core = require("tslua.core")
local parser = require("tslua.parser")
local printer = require("tslua.printer")

describe("realworld regressions", function()
    -- textWriter:GetColumn joined the whole output on every call (once per source map mapping):
    -- minified-style long lines with --sourceMap took minutes.
    it("StringsBuilder:Suffix is String()[pos:] and joins only the tail", function()
        local b = printer.newStringsBuilder()
        local ref = ""
        local seed = 7
        for i = 1, 400 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            local w = string.rep(string.char(97 + i % 26), seed % 5)
            b:WriteString(w)
            ref = ref .. w
            local pos = seed % (#ref + 1)
            assert.are.equal(string.sub(ref, pos + 1), b:Suffix(pos))
            assert.are.equal(#ref, b:Len())
        end
        assert.are.equal(ref, b:String())
    end)

    it("textWriter:GetColumn on one long line", function()
        local w = printer.NewTextWriter("\n", 4)
        w:Write("é😀")
        for i = 1, 20000 do
            w:Write(tostring(i % 10))
            w:Write(",")
        end
        assert.are.equal(3 + 40000, w:GetColumn())
        assert.are.equal(3 + 40000, w:GetColumn())
        -- parts covering the line were joined: the next GetColumn walks only the new writes
        assert.is_true(w.builder.n <= 2)
        w:WriteLine()
        w:Write("ab")
        assert.are.equal(2, w:GetColumn())
    end)

    it("core.UTF16Len", function()
        assert.are.equal(0, core.UTF16Len(""))
        assert.are.equal(3, core.UTF16Len("abc"))
        assert.are.equal(2, core.UTF16Len("aé"))
        assert.are.equal(4, core.UTF16Len("a😀b"))
        -- invalid bytes count as one RuneError each, like Go's utf8.DecodeRuneInString
        assert.are.equal(2, core.UTF16Len("\xff\xfe"))
        assert.are.equal(4, core.UTF16Len("ab\xe2\x82"))
    end)

    -- parseJSDocComment copied the text before and after every comment and scanned all
    -- newlines from the start of the file: checking lib.dom.d.ts (6k JSDoc comments) cost ~20 s.
    it("JSDoc initial indent after the last newline", function()
        local text = "let a;\n    /**\n     * x\n     *   indented\n     */\n    function f() {}\n/** @deprecated y */\nvar v;"
        local file = parser.ParseSourceFile({ fileName = "/a.ts", path = "/a.ts", externalModuleIndicatorOptions = { jsx = false, force = false } }, text, core.ScriptKind.TS)
        local f = file.statements.nodes[2]
        local jsdoc = f:JSDoc(file)
        assert.are.equal(1, #jsdoc)
        assert.are.equal("x\n  indented", table.concat(jsdoc[1].comment.nodes[1].text))
        local v = file.statements.nodes[3]
        local tags = v:JSDoc(file)[1].tags.nodes
        assert.are.equal("y", table.concat(tags[1].comment.nodes[1].text))
    end)
end)
