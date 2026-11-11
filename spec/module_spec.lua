-- Module resolution scenarios (ported from typescript-go internal/module/resolver_test.go plus
-- scenarios mirroring the upstream moduleResolution compiler tests).
local core = require("tslua.core")
local module = require("tslua.module")
local vfstest = require("tslua.vfs.vfstest")

local ModuleKind = core.ModuleKind
local ModuleResolutionKind = core.ModuleResolutionKind
local Tristate = core.Tristate

local function newHost(files, cwd)
    local fs = vfstest.FromMap(files, true)
    return {
        FS = function() return fs end,
        GetCurrentDirectory = function() return cwd end,
    }
end

local function resolve(files, options, name, containingFile, mode)
    local host = newHost(files, "/repo")
    local resolver = module.NewResolver(host, core.NewCompilerOptions(options), "", "", nil)
    local r = resolver:ResolveModuleName(name, containingFile, mode or ModuleKind.None, nil)
    return r, resolver
end

describe("module resolution", function()
    it("TestResolveModuleNameTrailingSlash", function()
        local files = {
            ["/repo/node_modules/pkg/package.json"] = '{"name":"pkg","main":"main.js","types":"main.d.ts"}',
            ["/repo/node_modules/pkg/main.d.ts"] = "export const x: number;",
            ["/repo/node_modules/pkg/main.js"] = "exports.x = 1;",
            ["/repo/src/file.ts"] = "",
        }
        local host = newHost(files, "/repo")
        local resolver = module.NewResolver(host, core.NewCompilerOptions({
            moduleResolution = ModuleResolutionKind.Bundler,
            module = ModuleKind.ESNext,
            target = core.ScriptTarget.ESNext,
        }), "", "", nil)
        for _, name in ipairs({ "pkg", "pkg/" }) do
            local r = resolver:ResolveModuleName(name, "/repo/src/file.ts", ModuleKind.ESNext, nil)
            assert.is_true(r:IsResolved(), name)
            assert.are.equal("/repo/node_modules/pkg/main.d.ts", r.resolvedFileName)
            assert.are.equal(".d.ts", r.extension)
            assert.is_true(r.isExternalLibraryImport)
        end
    end)

    it("resolves relative imports with extension substitution", function()
        local files = {
            ["/repo/src/a.ts"] = "",
            ["/repo/src/b.ts"] = "",
            ["/repo/src/dir/index.ts"] = "",
        }
        local options = { moduleResolution = ModuleResolutionKind.Bundler }
        local r = resolve(files, options, "./b", "/repo/src/a.ts")
        assert.are.equal("/repo/src/b.ts", r.resolvedFileName)
        assert.is_false(r.resolvedUsingTsExtension)
        r = resolve(files, options, "./b.js", "/repo/src/a.ts")
        assert.are.equal("/repo/src/b.ts", r.resolvedFileName)
        r = resolve(files, options, "./b.ts", "/repo/src/a.ts")
        assert.are.equal("/repo/src/b.ts", r.resolvedFileName)
        assert.is_true(r.resolvedUsingTsExtension)
        r = resolve(files, options, "./dir", "/repo/src/a.ts")
        assert.are.equal("/repo/src/dir/index.ts", r.resolvedFileName)
        r = resolve(files, options, "./missing", "/repo/src/a.ts")
        assert.is_false(r:IsResolved())
    end)

    it("does not do directory lookups for ESM relative imports in node16", function()
        local files = {
            ["/repo/src/a.ts"] = "",
            ["/repo/src/dir/index.ts"] = "",
        }
        local options = { moduleResolution = ModuleResolutionKind.Node16, module = ModuleKind.Node16 }
        local r = resolve(files, options, "./dir", "/repo/src/a.ts", ModuleKind.ESNext)
        assert.is_false(r:IsResolved())
        r = resolve(files, options, "./dir", "/repo/src/a.ts", ModuleKind.CommonJS)
        assert.are.equal("/repo/src/dir/index.ts", r.resolvedFileName)
        r = resolve(files, options, "./dir/index.js", "/repo/src/a.ts", ModuleKind.ESNext)
        assert.are.equal("/repo/src/dir/index.ts", r.resolvedFileName)
    end)

    it("resolves package exports with conditions", function()
        local files = {
            ["/repo/node_modules/pkg/package.json"] = [[{
                "name": "pkg", "version": "1.2.3",
                "exports": {
                    ".": { "import": "./esm/index.js", "require": "./cjs/index.js" },
                    "./feature/*": "./features/*.js"
                }
            }]],
            ["/repo/node_modules/pkg/esm/index.d.ts"] = "",
            ["/repo/node_modules/pkg/cjs/index.d.ts"] = "",
            ["/repo/node_modules/pkg/features/x.d.ts"] = "",
            ["/repo/src/a.ts"] = "",
        }
        local options = { moduleResolution = ModuleResolutionKind.NodeNext, module = ModuleKind.NodeNext }
        local r = resolve(files, options, "pkg", "/repo/src/a.ts", ModuleKind.ESNext)
        assert.are.equal("/repo/node_modules/pkg/esm/index.d.ts", r.resolvedFileName)
        assert.are.equal("pkg", r.packageId.name)
        assert.are.equal("1.2.3", r.packageId.version)
        assert.are.equal("esm/index.d.ts", r.packageId.subModuleName)
        assert.are.equal("pkg/esm/index.d.ts@1.2.3", r.packageId:String())
        r = resolve(files, options, "pkg", "/repo/src/a.ts", ModuleKind.CommonJS)
        assert.are.equal("/repo/node_modules/pkg/cjs/index.d.ts", r.resolvedFileName)
        r = resolve(files, options, "pkg/feature/x", "/repo/src/a.ts", ModuleKind.ESNext)
        assert.are.equal("/repo/node_modules/pkg/features/x.d.ts", r.resolvedFileName)
        r = resolve(files, options, "pkg/esm/index.js", "/repo/src/a.ts", ModuleKind.ESNext)
        assert.is_false(r:IsResolved())
    end)

    it("resolves package imports", function()
        local files = {
            ["/repo/package.json"] = '{ "name": "self", "imports": { "#util": "./src/util.js" } }',
            ["/repo/src/util.ts"] = "",
            ["/repo/src/a.ts"] = "",
        }
        local options = { moduleResolution = ModuleResolutionKind.NodeNext, module = ModuleKind.NodeNext }
        local r = resolve(files, options, "#util", "/repo/src/a.ts", ModuleKind.ESNext)
        assert.are.equal("/repo/src/util.ts", r.resolvedFileName)
    end)

    it("falls back to @types and typesVersions", function()
        local files = {
            ["/repo/node_modules/untyped/package.json"] = '{ "name": "untyped", "main": "index.js" }',
            ["/repo/node_modules/untyped/index.js"] = "",
            ["/repo/node_modules/@types/untyped/index.d.ts"] = "",
            ["/repo/node_modules/tv/package.json"] = '{ "name": "tv", "typesVersions": { ">=3.1": { "*": ["ts3.1/*"] } } }',
            ["/repo/node_modules/tv/ts3.1/sub.d.ts"] = "",
            ["/repo/src/a.ts"] = "",
        }
        local options = { moduleResolution = ModuleResolutionKind.Bundler }
        local r = resolve(files, options, "untyped", "/repo/src/a.ts")
        assert.are.equal("/repo/node_modules/@types/untyped/index.d.ts", r.resolvedFileName)
        r = resolve(files, options, "tv/sub", "/repo/src/a.ts")
        assert.are.equal("/repo/node_modules/tv/ts3.1/sub.d.ts", r.resolvedFileName)
    end)

    it("resolves paths mappings and records traces", function()
        local paths = require("tslua.collections").NewOrderedMap()
        paths:Set("@lib/*", { "./lib/*" })
        local files = {
            ["/repo/lib/thing.ts"] = "",
            ["/repo/src/a.ts"] = "",
        }
        local host = newHost(files, "/repo")
        local resolver = module.NewResolver(host, core.NewCompilerOptions({
            moduleResolution = ModuleResolutionKind.Bundler,
            paths = paths,
            pathsBasePath = "/repo",
            traceResolution = Tristate.TSTrue,
        }), "", "", nil)
        local r, traces = resolver:ResolveModuleName("@lib/thing", "/repo/src/a.ts", ModuleKind.None, nil)
        assert.are.equal("/repo/lib/thing.ts", r.resolvedFileName)
        assert.is_true(#traces > 0)
        assert.are.equal(require("tslua.diagnostics").Resolving_module_0_from_1, traces[1].message)
    end)

    it("resolves type reference directives", function()
        local files = {
            ["/repo/node_modules/@types/node/index.d.ts"] = "",
            ["/repo/src/a.ts"] = "",
        }
        local host = newHost(files, "/repo")
        local resolver = module.NewResolver(host, core.NewCompilerOptions({ moduleResolution = ModuleResolutionKind.Bundler }), "", "", nil)
        local r = resolver:ResolveTypeReferenceDirective("node", "/repo/src/a.ts", ModuleKind.None, nil)
        assert.are.equal("/repo/node_modules/@types/node/index.d.ts", r.resolvedFileName)
        assert.is_true(r.primary)
    end)

    it("resolves extended tsconfig packages", function()
        local files = {
            ["/repo/node_modules/@tsconfig/base/tsconfig.json"] = "{}",
            ["/repo/node_modules/cfg/package.json"] = '{ "name": "cfg", "tsconfig": "./x.json" }',
            ["/repo/node_modules/cfg/x.json"] = "{}",
        }
        local host = newHost(files, "/repo")
        local r = module.ResolveConfig("@tsconfig/base", "/repo/tsconfig.json", host)
        assert.are.equal("/repo/node_modules/@tsconfig/base/tsconfig.json", r.resolvedFileName)
        r = module.ResolveConfig("cfg", "/repo/tsconfig.json", host)
        assert.are.equal("/repo/node_modules/cfg/x.json", r.resolvedFileName)
    end)

    it("util functions", function()
        assert.are.same({ "@scope/pkg", "sub/path" }, { module.ParsePackageName("@scope/pkg/sub/path") })
        assert.are.same({ "pkg", "" }, { module.ParsePackageName("pkg") })
        assert.are.equal("scope__pkg", module.MangleScopedPackageName("@scope/pkg"))
        assert.are.equal("@scope/pkg", module.UnmangleScopedPackageName("scope__pkg"))
        assert.are.equal("@types/scope__pkg", module.GetTypesPackageName("@scope/pkg"))
        assert.are.equal("/a/node_modules/@s/p", module.ParseNodeModuleFromPath("/a/node_modules/@s/p/index.d.ts", false))
        assert.are.equal(-1, module.ComparePatternKeys("./a/*", "./*"))
        assert.is_true(module.IsApplicableVersionedTypesKey("types@>=4"))
    end)
end)

describe("symlinks", function()
    it("ProcessResolution records file and directory links", function()
        local symlinks = require("tslua.symlinks")
        local k = symlinks.NewKnownSymlink("/", true)
        k:ProcessResolution("/app/node_modules/lib/index.d.ts", "/packages/lib/index.d.ts")
        assert.is_true(k:HasDirectory("/app/node_modules/lib"))
        assert.are.equal("/packages/lib/index.d.ts", (k:Files():Load("/app/node_modules/lib/index.d.ts")))
        local link = k:Directories():Load("/app/node_modules/lib/")
        assert.are.equal("/packages/lib/", link.real)
        assert.is_true(k:FilesByRealpath():Load("/packages/lib/index.d.ts"):Has("/app/node_modules/lib/index.d.ts"))
    end)
end)
