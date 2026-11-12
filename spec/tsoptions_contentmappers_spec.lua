-- Port of internal/tsoptions/contentmappers_test.go.
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

-- resolveContentMapperHost implements tsoptions.ParseConfigHost.
local resolveContentMapperHost = {}
resolveContentMapperHost.__index = resolveContentMapperHost

function resolveContentMapperHost:FS() return self.fs end
function resolveContentMapperHost:GetCurrentDirectory() return "/home/project" end

describe("TestGetContentMapperForFileNameUsesLongestExtension", function()
    it("TestGetContentMapperForFileNameUsesLongestExtension", function()
        local zMapper = contentmapper.NewMapper({ package = "z", extensions = { ".z" } })
        local yzMapper = contentmapper.NewMapper({ package = "yz", extensions = { ".y.z" } })
        local commandLine = tsoptions.newParsedCommandLineStruct({
            parsedConfig = tsoptions.NewParsedOptions({ contentMappers = { zMapper, yzMapper } }),
        })

        assert.are.equal(yzMapper, commandLine:GetContentMapperForFileName("/src/Component.y.z"))
        assert.are.equal(zMapper, commandLine:GetContentMapperForFileName("/src/Component.z"))
    end)
end)

describe("TestGetContentMapperForFileNameUsesHostCaseSensitivity", function()
    it("TestGetContentMapperForFileNameUsesHostCaseSensitivity", function()
        local mapper = contentmapper.NewMapper({ extensions = { ".vue" } })
        local insensitive = tsoptions.newParsedCommandLineStruct({
            parsedConfig = tsoptions.NewParsedOptions({ contentMappers = { mapper } }),
            comparePathsOptions = tspath.NewComparePathsOptions(false, ""),
        })
        local sensitive = tsoptions.newParsedCommandLineStruct({
            parsedConfig = tsoptions.NewParsedOptions({ contentMappers = { mapper } }),
            comparePathsOptions = tspath.NewComparePathsOptions(true, ""),
        })

        assert.are.equal(mapper, insensitive:GetContentMapperForFileName("/src/Component.VUE"))
        assert.is_true(sensitive:GetContentMapperForFileName("/src/Component.VUE") == nil)
    end)
end)

describe("TestGetOutputFileNamesExcludesMapperOwnedOutputs", function()
    it("TestGetOutputFileNamesExcludesMapperOwnedOutputs", function()
        local mapper = contentmapper.NewMapper({ extensions = { ".vue" } })
        local commandLine = tsoptions.NewParsedCommandLine(
            core.NewCompilerOptions({
                outDir = "/dist",
                declaration = core.Tristate.TSTrue,
                declarationMap = core.Tristate.TSTrue,
                sourceMap = core.Tristate.TSTrue,
            }),
            { "/src/Component.vue" },
            tspath.NewComparePathsOptions(true, "/")
        )
        commandLine.parsedConfig.contentMappers = { mapper }

        assert.are.same({ "/dist/Component.d.vue.ts" }, core.Collect(commandLine:GetOutputFileNames()))
    end)
end)

describe("TestResolveContentMapperManifest", function()
    it("TestResolveContentMapperManifest", function()
        local host = setmetatable({ fs = vfstest.FromMap({
            ["/home/project/node_modules/vue-ts-mapper/package.json"] = [[{
			"name": "vue-ts-mapper",
			"version": "1.2.3",
			"typescript": { "contentMapper": { "exec": ["node", "./dist/mapper.js"], "compilerOptions": ["target", "jsx"] } }
		}]],
            ["/home/node_modules/@scope/noversion/package.json"] = [[{
			"name": "@scope/noversion",
			"typescript": { "contentMapper": { "exec": ["run"] } }
		}]],
            ["/home/project/node_modules/no-name/package.json"] = [[{
			"version": "1.0.0"
		}]],
            ["/home/project/node_modules/no-manifest/package.json"] = [[{
			"name": "no-manifest"
		}]],
            ["/home/project/node_modules/no-exec/package.json"] = [[{
			"name": "no-exec",
			"typescript": { "contentMapper": {} }
		}]],
            ["/home/project/node_modules/bad-exec/package.json"] = [[{
			"name": "bad-exec",
			"typescript": { "contentMapper": { "exec": "node ./mapper.js" } }
		}]],
        }, true --[[useCaseSensitiveFileNames]]) }, resolveContentMapperHost)

        -- Name, version, and the verbatim exec argv are preserved.
        local _
        local manifest, packageDirectory, diagnostic = tsoptions.resolveContentMapperManifest(host, "/home/project/tsconfig.json", "vue-ts-mapper")
        assert.is_true(diagnostic == nil)
        assert.are.equal("vue-ts-mapper", manifest.name)
        assert.are.equal("1.2.3", manifest.version)
        assert.are.equal("/home/project/node_modules/vue-ts-mapper", packageDirectory)
        assert.are.same({ "node", "./dist/mapper.js" }, manifest.exec)
        assert.are.same({ "target", "jsx" }, manifest.compilerOptions)

        -- Resolution walks up node_modules; a package with no version resolves to a name and empty version.
        manifest, _, diagnostic = tsoptions.resolveContentMapperManifest(host, "/home/project/src/tsconfig.json", "@scope/noversion")
        assert.is_true(diagnostic == nil)
        assert.are.equal("@scope/noversion", manifest.name)
        assert.are.equal("", manifest.version)

        -- A package that is not installed reports a resolution diagnostic.
        _, _, diagnostic = tsoptions.resolveContentMapperManifest(host, "/home/project/tsconfig.json", "missing-mapper")
        assert.is_true(diagnostic ~= nil)
        assert.are.equal(diagnostics.The_content_mapper_package_0_could_not_be_resolved:Code(), diagnostic:Code())

        -- A package whose package.json has no name reports a diagnostic.
        _, packageDirectory, diagnostic = tsoptions.resolveContentMapperManifest(host, "/home/project/tsconfig.json", "no-name")
        assert.is_true(diagnostic ~= nil)
        assert.are.equal("/home/project/node_modules/no-name", packageDirectory)
        assert.are.equal(diagnostics.The_package_json_of_the_content_mapper_package_0_does_not_specify_a_name:Code(), diagnostic:Code())

        -- A package that does not declare a "typescript.contentMapper" object reports a diagnostic.
        _, _, diagnostic = tsoptions.resolveContentMapperManifest(host, "/home/project/tsconfig.json", "no-manifest")
        assert.is_true(diagnostic ~= nil)
        assert.are.equal(diagnostics.The_package_json_of_the_content_mapper_package_0_does_not_declare_a_typescript_contentMapper_object:Code(), diagnostic:Code())

        -- A "typescript.contentMapper" with no "exec", or an "exec" of the wrong type, reports a diagnostic.
        for _, pkg in ipairs({ "no-exec", "bad-exec" }) do
            _, _, diagnostic = tsoptions.resolveContentMapperManifest(host, "/home/project/tsconfig.json", pkg)
            assert.is_true(diagnostic ~= nil, "expected a diagnostic for " .. pkg)
            assert.are.equal(diagnostics.The_typescript_contentMapper_exec_of_the_content_mapper_package_0_must_be_a_non_empty_array_of_strings:Code(), diagnostic:Code())
        end
    end)
end)
