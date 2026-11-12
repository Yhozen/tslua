-- Port of internal/ast/diagnostic_test.go
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")

-- Go &SourceFile{parseOptions: SourceFileParseOptions{FileName: fileName, Path: path}}
local function newBareSourceFile(fileName, path)
    return setmetatable({
        kind = ast.Kind.SourceFile,
        flags = 0,
        loc = core.NewTextRange(0, 0),
        parseOptions = { fileName = fileName, path = path },
    }, ast.SourceFile)
end

describe("TestDiagnosticsCollectionDeduplicatesExactDiagnosticsOnAdd", function()
    it("TestDiagnosticsCollectionDeduplicatesExactDiagnosticsOnAdd", function()
        local collection = ast.NewDiagnosticsCollection()
        local first = ast.NewCompilerDiagnostic(diagnostics.Cannot_find_name_0, "x")
            :AddRelatedInfo(ast.NewCompilerDiagnostic(diagnostics.X_0_is_declared_here, "first"))
        local second = ast.NewCompilerDiagnostic(diagnostics.Cannot_find_name_0, "x")
            :AddRelatedInfo(ast.NewCompilerDiagnostic(diagnostics.X_0_is_declared_here, "first"))
        local different = ast.NewCompilerDiagnostic(diagnostics.Cannot_find_name_0, "x")
            :AddRelatedInfo(ast.NewCompilerDiagnostic(diagnostics.X_0_is_declared_here, "second"))

        assert.are.equal(first, collection:Add(first), "first Add()")
        local canonical = collection:Add(second)
        assert.are.equal(first, canonical, "second Add() should return canonical")
        assert.are.equal(different, collection:Add(different), "different Add()")

        canonical:AddRelatedInfo(ast.NewCompilerDiagnostic(diagnostics.X_0_is_declared_here, "third"))
        local collected = collection:GetGlobalDiagnostics()
        assert.are.equal(2, #collected, "GetGlobalDiagnostics()")
        assert.are.equal(2, #first:RelatedInformation(), "canonical diagnostic related diagnostics")
    end)
end)

describe("TestDiagnosticsCollectionPreservesDistinctAdHocMessages", function()
    it("TestDiagnosticsCollectionPreservesDistinctAdHocMessages", function()
        local collection = ast.NewDiagnosticsCollection()
        local first = ast.NewCompilerDiagnostic(diagnostics.NewAdHocMessage("first"))
        local second = ast.NewCompilerDiagnostic(diagnostics.NewAdHocMessage("second"))

        collection:Add(first)
        collection:Add(second)
        local collected = collection:GetGlobalDiagnostics()
        assert.are.equal(2, #collected, "GetGlobalDiagnostics()")
    end)
end)

describe("TestDiagnosticsCollectionGetsDiagnosticsForEquivalentSourceFile", function()
    it("TestDiagnosticsCollectionGetsDiagnosticsForEquivalentSourceFile", function()
        local path = "/src/file.ts"
        local diagnosticFile = newBareSourceFile(path, path)
        local requestedFile = newBareSourceFile(path, path)
        local diagnostic = ast.NewDiagnostic(diagnosticFile, core.NewTextRange(0, 0), diagnostics.Cannot_find_name_0, "x")

        local collection = ast.NewDiagnosticsCollection()
        collection:Add(diagnostic)

        local collected = collection:GetDiagnosticsForFile(requestedFile)
        assert.is_true(#collected == 1 and collected[1] == diagnostic, "GetDiagnosticsForFile() should return diagnostic for equivalent source file")
    end)
end)

describe("TestExternalDiagnosticIdentity", function()
    it("TestExternalDiagnosticIdentity", function()
        local file = newBareSourceFile("/src/file.vue", "/src/file.vue")
        local loc = core.NewTextRange(1, 2)
        local first = ast.NewExternalDiagnostic(file, loc, "mapper-a", diagnostics.Category.Error, 0, "first")
        local diags = {
            first,
            ast.NewExternalDiagnostic(file, loc, "mapper-a", diagnostics.Category.Error, 0, "second"),
            ast.NewExternalDiagnostic(file, loc, "mapper-b", diagnostics.Category.Error, 0, "first"),
            ast.NewExternalDiagnostic(file, loc, "mapper-a", diagnostics.Category.Warning, 0, "first"),
        }

        local collection = ast.NewDiagnosticsCollection()
        for _, diagnostic in ipairs(diags) do
            assert.is_true(not ast.EqualDiagnosticsNoRelatedInfo(first, diagnostic) or diagnostic == first)
            assert.is_true(ast.CompareDiagnostics(first, diagnostic) ~= 0 or diagnostic == first)
            collection:Add(diagnostic)
        end
        assert.are.equal(#diags, #collection:GetDiagnostics())
    end)
end)
