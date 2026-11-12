-- Port of internal/compiler/contentmapper_test.go.
local bundled = require("tslua.bundled")
local compiler = require("tslua.compiler")
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local jsonrpc = require("tslua.jsonrpc")
local locale = require("tslua.locale")
local spanmap = require("tslua.spanmap")
local tsoptions = require("tslua.tsoptions")
local vfstest = require("tslua.vfs.vfstest")

-- fakeContentMapperHost implements contentmapper.Project.
local fakeContentMapperHost = {}
fakeContentMapperHost.__index = fakeContentMapperHost

local function newFakeContentMapperHost(transform)
    return setmetatable({ transform = transform }, fakeContentMapperHost)
end

function fakeContentMapperHost:Refresh() return nil end
function fakeContentMapperHost:Identities() return nil, nil end
function fakeContentMapperHost:Identity(_) return "test", nil end
function fakeContentMapperHost:WatchedFiles() return nil, nil end
function fakeContentMapperHost:Diagnostics()
    return nil
end
function fakeContentMapperHost:Close() return nil end

function fakeContentMapperHost:Transform(_, request)
    return self.transform(request.fileName, request.content)
end

local function newContentMapperProgramWithOptions(contentMapperProject, files, rootFiles, options)
    if not bundled.Embedded then
        error("bundled files are not embedded")
    end
    local fs = vfstest.FromMap(nil, false --[[useCaseSensitiveFileNames]])
    fs = bundled.WrapFS(fs)
    for name, content in pairs(files) do
        fs:WriteFile(name, content)
    end

    local config = tsoptions.newParsedCommandLineStruct({
        parsedConfig = tsoptions.NewParsedOptions({
            fileNames = rootFiles,
            compilerOptions = options,
            contentMappers = { contentmapper.NewMapper({ package = "vue", extensions = { ".vue" }, name = "vue-mapper", version = "1.0.0" }) },
        }),
    })
    return compiler.NewProgram(compiler.NewProgramOptions({
        config = config,
        host = compiler.NewCompilerHost("/src", fs, bundled.LibPath(), nil, nil, contentMapperProject),
        -- Load files on the calling goroutine for deterministic diagnostics ordering.
        singleThreaded = core.Tristate.TSTrue,
    }))
end

local function newContentMapperProgram(contentMapperProject, files, rootFiles)
    return newContentMapperProgramWithOptions(contentMapperProject, files, rootFiles, core.NewCompilerOptions({
        skipLibCheck = core.Tristate.TSTrue,
        module = core.ModuleKind.ESNext,
        moduleResolution = core.ModuleResolutionKind.Bundler,
    }))
end

local function collectContentMapperDiagnostics(program)
    local result = {}
    for _, list in ipairs({
        program:GetSyntacticDiagnostics(nil, nil),
        program:GetSemanticDiagnostics(nil, nil),
        program:GetProgramDiagnostics(),
    }) do
        for _, d in ipairs(list or {}) do
            result[#result + 1] = d
        end
    end
    return result
end

local function codesOf(diags)
    local codes = {}
    for i, d in ipairs(diags) do
        codes[i] = tostring(d:Code())
    end
    return table.concat(codes, ",")
end

describe("TestContentMapperVirtualExtensionSetsImpliedNodeFormat", function()
    it("TestContentMapperVirtualExtensionSetsImpliedNodeFormat", function()
        local program = newContentMapperProgramWithOptions(
            newFakeContentMapperHost(function(_, _)
                return contentmapper.NewResult({ text = "export {};", virtualExtension = ".mts", mappings = spanmap.New(nil) }), nil
            end),
            { ["/src/Component.vue"] = "<template />" },
            { "/src/Component.vue" },
            core.NewCompilerOptions({
                skipLibCheck = core.Tristate.TSTrue,
                module = core.ModuleKind.NodeNext,
                moduleResolution = core.ModuleResolutionKind.NodeNext,
            })
        )

        local file = program:GetSourceFile("/src/Component.vue")
        assert.is_true(file ~= nil)
        assert.are.equal(core.ModuleKind.ResolutionModeESM, program:GetSourceFileMetaData(file:Path()).impliedNodeFormat)
    end)
end)

describe("TestContentMapperInvalidMappings", function()
    it("TestContentMapperInvalidMappings", function()
        local transformed = "export const x = 1;\n"
        local original = "<template>x</template>\n"
        local mappings = spanmap.New({
            spanmap.NewSegment({ virtualStart = 0, virtualEnd = 10, originalStart = 0, originalEnd = 0, kind = spanmap.Kind.Atom }),
            spanmap.NewSegment({ virtualStart = 5, virtualEnd = #transformed, originalStart = 0, originalEnd = 0, kind = spanmap.Kind.Atom }),
        })
        local files = {
            ["/src/app.ts"] = 'import "./Component.vue";',
            ["/src/Component.vue"] = original,
        }
        local contentMapperHost = newFakeContentMapperHost(function(_, _)
            return contentmapper.NewResult({ text = transformed, virtualExtension = ".ts", mappings = mappings }), nil
        end)
        local program = newContentMapperProgram(contentMapperHost, files, { "/src/app.ts" })
        local programDiagnostics = collectContentMapperDiagnostics(program)
        local found = core.Some(programDiagnostics, function(diagnostic)
            return diagnostic:Code() == diagnostics.The_content_mapper_0_produced_overlapping_or_out_of_order_position_mappings_near_virtual_offset_1:Code()
        end)
        assert.is_true(found, "expected an invalid mapping diagnostic, got: " .. codesOf(programDiagnostics))
    end)
end)

describe("TestContentMapperSourceFileState", function()
    it("successful synthesized empty file", function()
        local program = newContentMapperProgram(newFakeContentMapperHost(function(_, _)
            return contentmapper.NewResult({ text = "export {};", virtualExtension = ".ts", mappings = spanmap.New(nil) }), nil
        end), { ["/src/empty.vue"] = "" }, { "/src/empty.vue" })
        local file = program:GetSourceFile("/src/empty.vue")
        assert.is_true(file ~= nil)
        assert.are.equal("", file:OriginalText())
        assert.are.equal("vue-mapper@1.0.0", file:ContentMapper())
        assert.is_true(not file:IsContentMapperFailureStub())
    end)

    it("failed transform", function()
        local program = newContentMapperProgram(newFakeContentMapperHost(function(_, _)
            return contentmapper.NewResult(), jsonrpc.NewError("failed")
        end), { ["/src/fail.vue"] = "original" }, { "/src/fail.vue" })
        local file = program:GetSourceFile("/src/fail.vue")
        assert.is_true(file ~= nil)
        assert.are.equal("original", file:OriginalText())
        assert.are.equal("vue-mapper@1.0.0", file:ContentMapper())
        assert.is_true(file:IsContentMapperFailureStub())
    end)

    it("project error is localized", function()
        local program = newContentMapperProgram(newFakeContentMapperHost(function(_, _)
            return contentmapper.NewResult(), contentmapper.NewTransformError(
                contentmapper.TransformErrorKind.Project,
                contentmapper.NewProjectError(contentmapper.ProjectErrorKind.MalformedResponse)
            )
        end), { ["/src/fail.vue"] = "original" }, { "/src/fail.vue" })
        local programDiagnostics = collectContentMapperDiagnostics(program)
        local found = core.Some(programDiagnostics, function(diagnostic)
            return core.Some(diagnostic:MessageChain(), function(message)
                return message:Code() == diagnostics.The_content_mapper_returned_a_project_response_that_could_not_be_decoded:Code()
            end)
        end)
        assert.is_true(found, "expected a localized project response diagnostic, got: " .. codesOf(programDiagnostics))
    end)
end)

describe("TestContentMapperProjectErrorDiagnostics", function()
    for _, test in ipairs({
        {
            kind = contentmapper.ProjectErrorKind.MissingConfigIdentity,
            code = diagnostics.The_content_mapper_did_not_return_configIdentity_which_is_required_when_the_content_mapper_has_dynamicConfig_Colon_true_in_its_package_json:Code(),
            message = [[The content mapper did not return 'configIdentity', which is required when the content mapper has '"dynamicConfig": true' in its package.json.]],
        },
        {
            kind = contentmapper.ProjectErrorKind.UnexpectedConfigIdentity,
            code = diagnostics.The_content_mapper_returned_configIdentity_which_is_only_allowed_when_it_declares_dynamicConfig_Colon_true_in_its_package_json:Code(),
            message = [[The content mapper returned 'configIdentity', which is only allowed when it declares '"dynamicConfig": true' in its package.json.]],
        },
        {
            kind = contentmapper.ProjectErrorKind.UnexpectedWatchedFiles,
            code = diagnostics.The_content_mapper_returned_watchedFiles_which_is_only_allowed_when_it_declares_dynamicConfig_Colon_true_in_its_package_json:Code(),
            message = [[The content mapper returned 'watchedFiles', which is only allowed when it declares '"dynamicConfig": true' in its package.json.]],
        },
    }) do
        it(test.message, function()
            local message = compiler.ContentMapperProjectErrorDiagnostic(contentmapper.NewProjectError(test.kind))
            assert.are.equal(test.code, message:Code())
            assert.are.equal(test.message, diagnostics.Localize(locale.Default, message, message:Key()))
        end)
    end
end)
