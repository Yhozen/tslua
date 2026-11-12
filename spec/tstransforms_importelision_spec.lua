-- Port of internal/transformers/tstransforms/importelision_test.go
local binder = require("tslua.binder")
local checker = require("tslua.checker")
local core = require("tslua.core")
local module = require("tslua.module")
local parser = require("tslua.parser")
local printer = require("tslua.printer")
local tstransforms = require("tslua.transformers.tstransforms")
local tspath = require("tslua.tspath")

-- parsetestutil.ParseTypeScript
local function parseTypeScript(text, jsx)
    local fileName = jsx and "/main.tsx" or "/main.ts"
    return parser.ParseSourceFile({ fileName = fileName, path = fileName, externalModuleIndicatorOptions = { jsx = false, force = false } }, text, core.GetScriptKindFromFileName(fileName))
end

-- parsetestutil.CheckDiagnostics
local function checkDiagnostics(file)
    assert.are.equal(0, #file:Diagnostics(), "parse diagnostics")
end

-- emittestutil.CheckEmit
local function checkEmit(emitContext, file, expected)
    local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, emitContext)
    local text = p:EmitSourceFile(file)
    local actual = text
    if actual:sub(-1) == "\n" then
        actual = actual:sub(1, -2)
    end
    assert.are.equal(expected, actual)
    local file2 = parseTypeScript(text, file.languageVariant == core.LanguageVariant.JSX)
    assert.are.equal(0, #file2:Diagnostics(), "error on reparse")
end

local fakeProgram = {}
fakeProgram.__index = fakeProgram

-- Go &fakeProgram{...}
local function newFakeProgram(fields)
    return setmetatable({
        singleThreaded = fields.singleThreaded or false,
        compilerOptions = fields.compilerOptions,
        files = fields.files,
        getEmitModuleFormatOfFile = fields.getEmitModuleFormatOfFile,
        getImpliedNodeFormatForEmit = fields.getImpliedNodeFormatForEmit,
        getResolvedModule = fields.getResolvedModule,
        getSourceFile = fields.getSourceFile,
        getSourceFileForResolvedModule = fields.getSourceFileForResolvedModule,
    }, fakeProgram)
end

-- GetRedirectForResolution implements checker.Program.
function fakeProgram:GetRedirectForResolution(file)
    error("unimplemented", 0)
end

-- SourceFileMayBeEmitted implements checker.Program.
function fakeProgram:SourceFileMayBeEmitted(sourceFile, forceDtsEmit)
    error("unimplemented", 0)
end

-- GetEmitSyntaxForUsageLocation implements checker.Program.
function fakeProgram:GetEmitSyntaxForUsageLocation(sourceFile, usageLocation)
    error("unimplemented", 0)
end

-- CommonSourceDirectory implements checker.Program.
function fakeProgram:CommonSourceDirectory()
    error("unimplemented", 0)
end

function fakeProgram:ContentMapperExtensions()
    return nil
end

function fakeProgram:GetResolvedModuleFromModuleSpecifier(file, moduleSpecifier)
    error("unimplemented", 0)
end

function fakeProgram:FileExists(path)
    return false
end

function fakeProgram:GetCurrentDirectory()
    return ""
end

function fakeProgram:GetGlobalTypingsCacheLocation()
    return ""
end

function fakeProgram:GetNearestAncestorDirectoryWithPackageJson(dirname)
    return ""
end

function fakeProgram:GetSymlinkCache()
    return nil
end

function fakeProgram:ResolveModuleName(moduleName, containingFile, resolutionMode)
    return nil
end

function fakeProgram:GetPackageJsonInfo(pkgJsonPath)
    return nil
end

function fakeProgram:GetRedirectTargets(path)
    return nil
end

function fakeProgram:GetSourceOfProjectReferenceIfOutputIncluded(file)
    return ""
end

function fakeProgram:GetProjectReferenceFromSource(path)
    return nil
end

function fakeProgram:IsSourceFromProjectReference(path)
    return false
end

function fakeProgram:GetPackagesMap()
    return nil
end

function fakeProgram:GetProjectReferenceFromOutputDts(path)
    return nil
end

function fakeProgram:UseCaseSensitiveFileNames()
    return true
end

function fakeProgram:Options()
    return self.compilerOptions
end

function fakeProgram:SourceFiles()
    return self.files
end

function fakeProgram:BindSourceFiles()
    local wg = core.NewWorkGroup(self.singleThreaded)
    for _, file in ipairs(self.files) do
        if not file:IsBound() then
            wg:Queue(function()
                binder.BindSourceFile(file)
            end)
        end
    end
    wg:RunAndWait()
end

function fakeProgram:GetEmitModuleFormatOfFile(sourceFile)
    return self.getEmitModuleFormatOfFile(sourceFile)
end

function fakeProgram:GetImpliedNodeFormatForEmit(sourceFile)
    return self.getImpliedNodeFormatForEmit(sourceFile)
end

function fakeProgram:GetDefaultResolutionModeForFile(sourceFile)
    return self.getEmitModuleFormatOfFile(sourceFile)
end

function fakeProgram:GetModeForUsageLocation(sourceFile, location)
    return self.getEmitModuleFormatOfFile(sourceFile)
end

function fakeProgram:GetResolvedModule(currentSourceFile, moduleReference, mode)
    return self.getResolvedModule(currentSourceFile, moduleReference, mode)
end

function fakeProgram:GetSourceFile(fileName)
    return self.getSourceFile(fileName)
end

function fakeProgram:GetSourceFileForResolvedModule(fileName)
    return self.getSourceFileForResolvedModule(fileName)
end

function fakeProgram:GetSourceFileMetaData(path)
    -- ast.SourceFileMetaData{}
    return { packageJsonType = "", packageJsonDirectory = "", impliedNodeFormat = core.ModuleKind.ResolutionModeNone }
end

function fakeProgram:GetImportHelpersImportSpecifier(path)
    return nil
end

function fakeProgram:GetJSXRuntimeImportSpecifier(path)
    return "", nil
end

function fakeProgram:GetResolvedModules()
    error("unimplemented", 0)
end

function fakeProgram:IsSourceFileDefaultLibrary(path)
    return false
end

describe("TestImportElision", function()
    local data = {
        { title = "ImportEquals#1", input = "import x = require(\"other\"); x;", output = "import x = require(\"other\");\nx;" },
        { title = "ImportEquals#2", input = "import x = require(\"other\");", output = "" },
        { title = "ImportDeclaration#1", input = [[import "m";]], output = [[import "m";]] },
        { title = "ImportDeclaration#2", input = "import * as x from \"other\"; x;", output = "import * as x from \"other\";\nx;" },
        { title = "ImportDeclaration#3", input = "import x from \"other\"; x;", output = "import x from \"other\";\nx;" },
        { title = "ImportDeclaration#4", input = "import { x } from \"other\"; x;", output = "import { x } from \"other\";\nx;" },
        { title = "ImportDeclaration#5", input = "import * as x from \"other\";", output = "" },
        { title = "ImportDeclaration#6", input = "import x from \"other\";", output = "" },
        { title = "ImportDeclaration#7", input = "import { x } from \"other\";", output = "" },
        { title = "ExportDeclaration#1", input = "export * from \"other\";", other = "export let x;", output = "export * from \"other\";" },
        { title = "ExportDeclaration#2", input = "export * as x from \"other\";", other = "export let x;", output = "export * as x from \"other\";" },
        { title = "ExportDeclaration#3", input = "export * from \"other\";", other = "export let x;", output = "export * from \"other\";" },
        { title = "ExportDeclaration#4", input = "export * as x from \"other\";", other = "export let x;", output = "export * as x from \"other\";" },
        { title = "ExportDeclaration#5", input = "export { x } from \"other\";", other = "export let x;", output = "export { x } from \"other\";" },
        { title = "ExportDeclaration#6", input = "export { x } from \"other\";", other = "export type x = any;", output = "" },
        { title = "ExportDeclaration#7", input = "export { x }; let x;", output = "export { x };\nlet x;" },
        { title = "ExportDeclaration#8", input = "export { x }; type x = any;", output = "" },
        { title = "ExportDeclaration#9", input = "import { x } from \"other\"; export { x };", other = "export type x = any;", output = "" },
        { title = "ExportAssignment#1", input = "let x; export default x;", output = "let x;\nexport default x;" },
        { title = "ExportAssignment#2", input = "type x = any; export default x;", output = "" },
    }

    for _, rec in ipairs(data) do
        it(rec.title, function()
            local jsx = rec.jsx or false
            local file = parseTypeScript(rec.input, jsx)
            checkDiagnostics(file)
            local files = { file }

            local other
            if #(rec.other or "") > 0 then
                other = parseTypeScript(rec.other, jsx)
                checkDiagnostics(other)
                files[#files + 1] = other
            end

            local compilerOptions = core.NewCompilerOptions({})

            local c = checker.NewChecker(newFakeProgram({
                singleThreaded = true,
                compilerOptions = compilerOptions,
                files = files,
                getEmitModuleFormatOfFile = function(sourceFile)
                    return core.ModuleKind.ESNext
                end,
                getImpliedNodeFormatForEmit = function(sourceFile)
                    return core.ModuleKind.ESNext
                end,
                getSourceFile = function(fileName)
                    if fileName == "other.ts" then
                        return other
                    end
                    return nil
                end,
                getSourceFileForResolvedModule = function(fileName)
                    if fileName == "other.ts" then
                        return other
                    end
                    return nil
                end,
                getResolvedModule = function(currentSourceFile, moduleReference, mode)
                    if currentSourceFile == file and moduleReference == "other" then
                        local resolved = module.NewResolvedModule()
                        resolved.resolvedFileName = "other.ts"
                        resolved.extension = tspath.ExtensionTs
                        return resolved
                    end
                    return nil
                end,
            }), nil)

            local emitResolver = c:GetEmitResolver()

            local opts = { compilerOptions = compilerOptions, context = printer.NewEmitContext(), emitResolver = emitResolver, resolver = emitResolver }
            file = tstransforms.NewTypeEraserTransformer(opts):TransformSourceFile(file)
            file = tstransforms.NewImportElisionTransformer(opts):TransformSourceFile(file)
            checkEmit(nil, file, rec.output)
        end)
    end
end)
