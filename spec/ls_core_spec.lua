-- Ports of internal/ls/lsconv/converters_test.go (FileNameToDocumentURI, invalid UTF-8) and
-- internal/ls/lsutil/utilities_test.go (ProbablyUsesSemicolons, ResolveOrganizeImportsSort).
local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local spanmap = require("tslua.spanmap")

describe("lsconv.FileNameToDocumentURI", function()
    local tests = {
        { "/path/to/file.ts", "file:///path/to/file.ts" },
        { "//server/share/file.ts", "file://server/share/file.ts" },
        { "d:/work/tsgo932/lib/utils.ts", "file:///d%3A/work/tsgo932/lib/utils.ts" },
        { "d:/work/tsgo932/app/(test)/comp/comp-test.tsx", "file:///d%3A/work/tsgo932/app/%28test%29/comp/comp-test.tsx" },
        { "c:/test/me", "file:///c%3A/test/me" },
        { "//shares/files/c#/p.cs", "file://shares/files/c%23/p.cs" },
        { "c:/Source/Zürich or Zurich (ˈzjʊərɪk,/Code/resources/app/plugins/c#/plugin.json", "file:///c%3A/Source/Z%C3%BCrich%20or%20Zurich%20%28%CB%88zj%CA%8A%C9%99r%C9%AAk%2C/Code/resources/app/plugins/c%23/plugin.json" },
        { "c:/test %/path", "file:///c%3A/test%20%25/path" },
        { "/", "file:///" },
        { "/_:/path", "file:///_%3A/path" },
        { "/users/me/c#-projects/", "file:///users/me/c%23-projects/" },
        { "//localhost/c$/GitDevelopment/express", "file://localhost/c%24/GitDevelopment/express" },
        { "c:/test with %25/c#code", "file:///c%3A/test%20with%20%2525/c%23code" },
        { "^/untitled/ts-nul-authority/Untitled-1", "untitled:Untitled-1" },
        { "^/untitled/ts-nul-authority/c:/Users/jrieken/Code/abc.txt", "untitled:c:/Users/jrieken/Code/abc.txt" },
        { "^/untitled/ts-nul-authority///wsl%2Bubuntu/home/jabaile/work/TypeScript-go/newfile.ts", "untitled://wsl%2Bubuntu/home/jabaile/work/TypeScript-go/newfile.ts" },
    }
    for _, t in ipairs(tests) do
        it(t[1], function()
            assert.are.equal(t[2], lsconv.FileNameToDocumentURI(t[1]))
        end)
    end
end)

describe("lsconv converters", function()
    local function newTestConverters(text)
        local script = {
            FileName = function() return "test.ts" end,
            OriginalFileName = function() return "test.ts" end,
            Text = function() return text end,
            OriginalText = function() return text end,
            SpanMap = function() return nil end,
        }
        local lineMap = lsconv.ComputeLSPLineStarts(text)
        local conv = lsconv.NewConverters(lsproto.PositionEncodingKind.UTF16, function() return lineMap end)
        return conv, script
    end

    it("handles invalid UTF-8", function()
        local text = "a\x80b\ncd"
        local conv, script = newTestConverters(text)
        local mappings = { { 0, 0, 0 }, { 0, 1, 1 }, { 0, 2, 2 }, { 0, 3, 3 }, { 1, 0, 4 }, { 1, 1, 5 }, { 1, 2, 6 } }
        for _, m in ipairs(mappings) do
            local lc = { line = m[1], character = m[2] }
            local positions = lsconv.FromLSPPosition(conv, script, lc, spanmap.Feature.All)
            assert.are.equal(1, #positions)
            assert.are.equal(m[3], positions[1].position)
            local lspPosition = conv:ToLSPPosition(script, m[3])
            assert.are.same(lc, lspPosition)
        end
        for bytePos = 0, #text do
            local lc = conv:ToLSPPosition(script, bytePos)
            local positions = lsconv.FromLSPPosition(conv, script, lc, spanmap.Feature.All)
            assert.are.equal(1, #positions)
            assert.are.equal(bytePos, positions[1].position)
        end
    end)

    it("counts UTF-16 code units", function()
        local text = "x😀y\r\né\rz"
        local conv, script = newTestConverters(text)
        assert.are.same({ line = 0, character = 3 }, conv:ToLSPPosition(script, 5))
        assert.are.same({ line = 1, character = 1 }, conv:ToLSPPosition(script, 10))
        assert.are.same({ line = 2, character = 0 }, conv:ToLSPPosition(script, 11))
        assert.are.equal(5, lsconv.FromLSPPosition(conv, script, { line = 0, character = 3 }, spanmap.Feature.All)[1].position)
    end)
end)

describe("lsutil", function()
    local function parseTS(text)
        return parser.ParseSourceFile(ast.NewSourceFileParseOptions("/test.ts", "/test.ts"), text, core.ScriptKind.TS)
    end

    it("ProbablyUsesSemicolons", function()
        assert.is_true(lsutil.ProbablyUsesSemicolons(parseTS("let a = 1;\nlet b = 2;\nlet c = 3\nlet d = 4\nlet e = 5\n")))
        assert.is_false(lsutil.ProbablyUsesSemicolons(parseTS("let a = 1\nlet b = 2\nlet c = 3\n")))
        assert.is_true(lsutil.ProbablyUsesSemicolons(parseTS("let a = 1;\nlet b = 2;\nlet c = 3;\n")))
    end)

    it("ResolveOrganizeImportsSort", function()
        local S, C, T = lsutil.OrganizeImportsSort, lsutil.OrganizeImportsCollation, core.Tristate
        local P = lsutil.UserPreferences_new
        assert.are.equal(S.Ordinal, lsutil.ResolveOrganizeImportsSort(P({ organizeImportsSort = S.Ordinal, organizeImportsCollation = C.Unicode, organizeImportsIgnoreCase = T.TSTrue })))
        assert.are.equal(S.Natural, lsutil.ResolveOrganizeImportsSort(P({ organizeImportsCollation = C.Unicode, organizeImportsIgnoreCase = T.TSFalse })))
        assert.are.equal(S.NaturalIgnoreCase, lsutil.ResolveOrganizeImportsSort(P({ organizeImportsCollation = C.Unicode, organizeImportsIgnoreCase = T.TSTrue })))
        assert.are.equal(S.Auto, lsutil.ResolveOrganizeImportsSort(P({ organizeImportsCollation = C.Unicode })))
        assert.are.equal(S.OrdinalIgnoreCase, lsutil.ResolveOrganizeImportsSort(P({ organizeImportsIgnoreCase = T.TSTrue })))
        assert.are.equal(S.Ordinal, lsutil.ResolveOrganizeImportsSort(P({ organizeImportsIgnoreCase = T.TSFalse })))
    end)
end)
