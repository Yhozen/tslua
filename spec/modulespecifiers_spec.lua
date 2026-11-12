-- Ported from typescript-go internal/modulespecifiers/specifiers_test.go, plus cases checked
-- against a Go oracle (tryGetModuleNameFromPaths, GetNodeModulePathParts, processEnding, ...).
local core = require("tslua.core")
local collections = require("tslua.collections")
local modulespecifiers = require("tslua.modulespecifiers")
local packagejson = require("tslua.packagejson")
local symlinks = require("tslua.symlinks")
local tspath = require("tslua.tspath")

local ModuleSpecifierEnding = modulespecifiers.ModuleSpecifierEnding
local MatchingMode = modulespecifiers.MatchingMode

local function newMockHost(currentDir, useCaseSensitiveFileNames, symlinkCache)
    local h = {
        currentDir = currentDir or "",
        useCaseSensitiveFileNames = useCaseSensitiveFileNames or false,
        symlinkCache = symlinkCache,
    }
    function h:GetCurrentDirectory() return self.currentDir end
    function h:UseCaseSensitiveFileNames() return self.useCaseSensitiveFileNames end
    function h:GetSymlinkCache() return self.symlinkCache end
    function h:GetGlobalTypingsCacheLocation() return "" end
    function h:CommonSourceDirectory() return self.currentDir end
    function h:ContentMapperExtensions() return nil end
    function h:GetProjectReferenceFromSource() return nil end
    function h:GetRedirectTargets() return nil end
    function h:GetSourceOfProjectReferenceIfOutputIncluded(file) return file:FileName() end
    function h:FileExists() return true end
    function h:GetNearestAncestorDirectoryWithPackageJson() return "" end
    function h:GetPackageJsonInfo() return nil end
    function h:GetDefaultResolutionModeForFile() return core.ModuleKind.ResolutionModeNone end
    function h:GetResolvedModuleFromModuleSpecifier() return nil end
    function h:GetModeForUsageLocation() return core.ModuleKind.ResolutionModeNone end
    return h
end

describe("TestGetEachFileNameOfModule", function()
    local tests = {
        { name = "basic file path", importingFile = "/project/src/main.ts", importedFile = "/project/lib/utils.ts", preferSymlinks = false, expectedCount = 1, expectedPaths = { "/project/lib/utils.ts" } },
        { name = "symlink preference false", importingFile = "/project/src/main.ts", importedFile = "/project/lib/utils.ts", preferSymlinks = false, expectedCount = 1 },
        { name = "symlink preference true", importingFile = "/project/src/main.ts", importedFile = "/project/lib/utils.ts", preferSymlinks = true, expectedCount = 1 },
        -- Should return 1 because there's no better option (all paths are ignored)
        { name = "ignored path with no alternatives", importingFile = "/project/src/main.ts", importedFile = "/project/node_modules/.pnpm/file.ts", preferSymlinks = false, expectedCount = 1 },
    }
    for _, tt in ipairs(tests) do
        it(tt.name, function()
            local host = newMockHost("/project", true, symlinks.NewKnownSymlink("/project", true))
            local result = modulespecifiers.GetEachFileNameOfModule(tt.importingFile, tt.importedFile, host, tt.preferSymlinks)
            assert.are.equal(tt.expectedCount, #result)
            for i, expectedPath in ipairs(tt.expectedPaths or {}) do
                assert.are.equal(expectedPath, result[i].fileName)
            end
            for _, path in ipairs(result) do
                assert.are_not.equal("", path.fileName)
            end
        end)
    end
end)

describe("TestGetEachFileNameOfModuleWithSymlinks", function()
    it("finds the symlink path", function()
        local host = newMockHost("/project", true, symlinks.NewKnownSymlink("/project", true))
        local symlinkPath = tspath.Path_EnsureTrailingDirectorySeparator(tspath.ToPath("/project/symlink", "/project", true))
        local realDirectory = symlinks.NewKnownDirectoryLink(
            "/real/path/",
            tspath.Path_EnsureTrailingDirectorySeparator(tspath.ToPath("/real/path", "/project", true))
        )
        host.symlinkCache:SetDirectory("/project/symlink", symlinkPath, realDirectory)

        local result = modulespecifiers.GetEachFileNameOfModule("/project/src/main.ts", "/real/path/file.ts", host, true)

        local found = false
        for _, path in ipairs(result) do
            if path.fileName == "/project/symlink/file.ts" then
                found = true
                break
            end
        end
        assert.is_true(found)
    end)
end)

describe("TestContainsNodeModules", function()
    local tests = {
        { "contains node_modules", "/project/node_modules/lodash/index.js", true },
        { "does not contain node_modules", "/project/src/utils.ts", false },
        { "node_modules in middle", "/project/packages/node_modules/pkg/file.js", true },
        { "empty path", "", false },
    }
    for _, tt in ipairs(tests) do
        it(tt[1], function()
            assert.are.equal(tt[3], modulespecifiers.ContainsNodeModules(tt[2]))
        end)
    end
end)

describe("TestContainsIgnoredPath", function()
    it("ignored path", function()
        assert.is_true(modulespecifiers.containsIgnoredPath("/project/node_modules/.pnpm/file.ts"))
    end)
    it("not ignored path", function()
        assert.is_false(modulespecifiers.containsIgnoredPath("/project/src/file.ts"))
    end)
end)

describe("TestTryGetRealFileNameForNonJSDeclarationFileName", function()
    local tests = {
        { "json declaration file", "/project/foo.d.json.ts", "/project/foo.json" },
        { "multi-dot source extension declaration file", "/project/foo.module.d.css.ts", "/project/foo.module.css" },
        { "plain dts file ignored", "/project/foo.d.ts", "" },
    }
    for _, tt in ipairs(tests) do
        it(tt[1], function()
            assert.are.equal(tt[3], modulespecifiers.TryGetRealFileNameForNonJSDeclarationFileName(tt[2]))
        end)
    end
end)

local function stringExports(value)
    return setmetatable({ type = packagejson.JSONValueType.String, value = value, objectKind = 0 }, packagejson.ExportsOrImports)
end

describe("TestTryGetModuleNameFromExportsOrImports", function()
    local tests = {
        { "match", "/pkg/src/things/thing1/index.ts", "./src/things/thing1" },
        { "mismatch with matching leading and trailing strings", "/pkg/src/things/index.ts", "" },
    }
    for _, tt in ipairs(tests) do
        it("with exports pattern: " .. tt[1], function()
            local result = modulespecifiers.tryGetModuleNameFromExportsOrImports(
                core.NewCompilerOptions({}),
                newMockHost(),
                tt[2],
                "/pkg",
                "./src/things/*",
                stringExports("./src/things/*/index.js"),
                {},
                MatchingMode.Pattern,
                false,
                false
            )
            assert.are.equal(tt[3], result)
        end)
    end

    -- Expected values produced by the Go implementation.
    local oracle = {
        { "/pkg/src/things/thing1/index.ts", "./src/*", "#internal/*", MatchingMode.Pattern, true, false, "#internal/things/thing1/index.js" },
        { "/pkg/src/things/thing1/index.ts", "./src/*.js", "#internal/*", MatchingMode.Pattern, true, false, "#internal/things/thing1/index" },
        { "/pkg/src/things/index.ts", "./src/", "pkg", MatchingMode.Directory, false, false, "pkg/src/things/index.js", { outDir = "/out", declaration = core.Tristate.TSTrue } },
        { "/pkg/dist/a.d.ts", "./dist/*", "./src/things/*", MatchingMode.Pattern, false, false, "./src/things/a.js" },
        { "/pkg/dist/a.d.ts", "./dist/", "./src/things/*", MatchingMode.Directory, true, true, "src/things/*/dist/a.js" },
        { "/pkg/src/a.mts", "./src/*", "#internal/*", MatchingMode.Pattern, true, false, "#internal/a.mjs", { jsx = core.JsxEmit.Preserve } },
        { "/pkg/src/a.mts", "./src/a.mjs", "./src/things/*", MatchingMode.Pattern, true, true, "./src/things/", { outDir = "/out", declaration = core.Tristate.TSTrue } },
    }
    for i, o in ipairs(oracle) do
        it("matches Go oracle case " .. i, function()
            local result = modulespecifiers.tryGetModuleNameFromExportsOrImports(
                core.NewCompilerOptions(o[8] or {}),
                newMockHost("/", true),
                o[1], "/pkg", o[3], stringExports(o[2]), {}, o[4], o[5], o[6]
            )
            assert.are.equal(o[7], result)
        end)
    end
end)

describe("tryGetModuleNameFromPaths", function()
    local function pathsMap(pairs_)
        local om = collections.NewOrderedMapWithSizeHint(#pairs_)
        for _, kv in ipairs(pairs_) do
            om:Set(kv[1], { kv[2] })
        end
        return om
    end
    local E = ModuleSpecifierEnding
    local cases = {
        { { { "@app/*", "./src/app/*" } }, "src/app/foo.ts", { E.Minimal, E.Index, E.JsExtension }, "@app/foo" },
        { { { "@app/*", "./src/app/*" } }, "src/app/foo.ts", { E.JsExtension, E.Minimal, E.Index }, "@app/foo.js" },
        { { { "@app/*", "./src/app/*" } }, "src/app/foo.ts", { E.TsExtension, E.Minimal, E.JsExtension, E.Index }, "@app/foo.ts" },
        { { { "@app/*", "./src/app/*" } }, "src/app/c.d.mts", { E.Minimal, E.Index, E.JsExtension }, "@app/c.mjs" },
        { { { "@app/*", "./dist/*.d.ts" } }, "dist/foo/index.d.ts", { E.Minimal, E.Index, E.JsExtension }, "@app/foo/index" },
        { { { "@app/*", "./dist/*" } }, "dist/haha.d.ts", { E.JsExtension, E.Minimal, E.Index }, "@app/haha.js" },
        { { { "@x/*", "../outside/*" } }, "dist/haha.d.ts", { E.Minimal, E.Index, E.JsExtension }, "" },
    }
    for i, c in ipairs(cases) do
        it("matches Go oracle case " .. i, function()
            local result = modulespecifiers.tryGetModuleNameFromPaths(c[2], pathsMap(c[1]), c[3], "/proj", newMockHost("/", true), core.NewCompilerOptions({}))
            assert.are.equal(c[4], result)
        end)
    end
end)

describe("path helpers", function()
    it("GetNodeModulePathParts", function()
        local p = modulespecifiers.GetNodeModulePathParts("/base/path/node_modules/@scope/pkg/sub/file.js")
        assert.are.same({ topLevelNodeModulesIndex = 10, topLevelPackageNameIndex = 23, packageRootIndex = 34, fileNameIndex = 38 }, p)
        assert.is_nil(modulespecifiers.GetNodeModulePathParts("/base/path/file.js"))
    end)
    it("GetPackageNameFromDirectory", function()
        assert.are.equal("@s/p", modulespecifiers.GetPackageNameFromDirectory("/a/node_modules/@s/p/x"))
        assert.are.equal("pkg", modulespecifiers.GetPackageNameFromDirectory("/a/node_modules/pkg/lib/index.js"))
        assert.are.equal("", modulespecifiers.GetPackageNameFromDirectory("/a/node_modules/.bin/x"))
        assert.are.equal("", modulespecifiers.GetPackageNameFromDirectory("/a/b"))
    end)
    it("CountPathComponents", function()
        assert.are.equal(2, modulespecifiers.CountPathComponents("./a/b/c"))
        assert.are.equal(3, modulespecifiers.CountPathComponents("../a/b/c"))
    end)
    it("processEnding", function()
        local opts = core.NewCompilerOptions({})
        assert.are.equal("./a/b", modulespecifiers.processEnding("./a/b/index.ts", { ModuleSpecifierEnding.Minimal }, opts, nil))
        assert.are.equal("./a/b/index", modulespecifiers.processEnding("./a/b/index.ts", { ModuleSpecifierEnding.Index }, opts, nil))
        assert.are.equal("./a/b/index.js", modulespecifiers.processEnding("./a/b/index.ts", { ModuleSpecifierEnding.JsExtension }, opts, nil))
        assert.are.equal("./x.mjs", modulespecifiers.processEnding("./x.d.mts", { ModuleSpecifierEnding.Minimal }, opts, nil))
        assert.are.equal("./foo.json", modulespecifiers.processEnding("./foo.d.json.ts", { ModuleSpecifierEnding.Minimal }, opts, nil))
    end)
end)
