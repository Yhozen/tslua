-- Hand-written compiler.Program smoke tests. The Go tests of internal/compiler/*_test.go are
-- ported in spec/compiler_<file>_spec.lua.
local ast = require("tslua.ast")
local bundled = require("tslua.bundled")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

local Tristate = core.Tristate

local function newProgram(files, rootNames, options)
    local fs = bundled.WrapFS(vfstest.FromMap(files, true))
    local host = compiler.NewCompilerHost("/", fs, bundled.LibPath(), nil, nil, nil)
    local config = tsoptions.NewParsedCommandLine(
        core.NewCompilerOptions(options or { noLib = Tristate.TSTrue }),
        rootNames,
        tspath.NewComparePathsOptions(true, "/")
    )
    return compiler.NewProgram(compiler.NewProgramOptions({
        config = config,
        host = host,
        singleThreaded = Tristate.TSTrue,
    }))
end

describe("compiler.Program", function()
    it("loads root files and their references in order", function()
        local program = newProgram({
            ["/src/a.ts"] = '/// <reference path="c.ts" />\nimport { b } from "./b";\nexport const a = b;\n',
            ["/src/b.ts"] = "export const b = 1;\n",
            ["/src/c.ts"] = "declare const c: number;\n",
        }, { "/src/a.ts" })
        local names = {}
        for i, file in ipairs(program:GetSourceFiles()) do
            names[i] = file:FileName()
        end
        assert.are.same({ "/src/c.ts", "/src/b.ts", "/src/a.ts" }, names)
        assert.is_not_nil(program:GetSourceFile("/src/b.ts"))
        local a = program:GetSourceFile("/src/a.ts")
        local resolved = program:GetResolvedModuleFromModuleSpecifier(a, a:Imports()[1])
        assert.are.equal("/src/b.ts", resolved.resolvedFileName)
    end)

    it("reports syntactic diagnostics", function()
        local program = newProgram({
            ["/a.ts"] = "let x = ;\n",
            ["/b.ts"] = "let y = 1;\n",
        }, { "/a.ts", "/b.ts" })
        local diags = program:GetSyntacticDiagnostics(nil, nil)
        assert.are.equal(1, #diags)
        assert.are.equal(diagnostics.Expression_expected:Code(), diags[1]:Code())
        assert.are.equal("/a.ts", diags[1]:File():FileName())
        assert.are.equal(8, diags[1]:Pos())
        assert.are.same({}, program:GetSyntacticDiagnostics(nil, program:GetSourceFile("/b.ts")))
    end)

    it("reports missing root files and removed options", function()
        local program = newProgram({
            ["/a.ts"] = "export {};\n",
        }, { "/a.ts", "/missing.ts" }, { noLib = Tristate.TSTrue, outFile = "/out.js" })
        local diags = program:GetProgramDiagnostics()
        local codes = {}
        for i, d in ipairs(diags) do
            codes[i] = d:Code()
        end
        table.sort(codes)
        assert.are.same({ diagnostics.Option_0_has_been_removed_Please_remove_it_from_your_configuration:Code(), diagnostics.File_0_not_found:Code() }, codes)
    end)

    it("sorts and deduplicates diagnostics", function()
        local d1 = ast.NewCompilerDiagnostic(diagnostics.File_0_not_found, "b")
        local d2 = ast.NewCompilerDiagnostic(diagnostics.File_0_not_found, "a")
        local d3 = ast.NewCompilerDiagnostic(diagnostics.File_0_not_found, "a")
        local result = compiler.SortAndDeduplicateDiagnostics({ d1, d2, d3 })
        assert.are.equal(2, #result)
    end)
end)
