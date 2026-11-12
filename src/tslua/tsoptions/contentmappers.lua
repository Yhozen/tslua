local tsoptions = require("tslua.tsoptions")
local ast = require("tslua.ast")
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local module = require("tslua.module")
local packagejson = require("tslua.packagejson")
local tspath = require("tslua.tspath")

local function emptyManifest()
    return contentmapper.NewManifest()
end

-- resolveContentMapperManifest locates packageName in node_modules (walking up from the directory of
-- containingFile via node module resolution) and reads its package.json to produce the mapper's manifest
-- and package directory. It never executes the package. On failure it returns a diagnostic describing why
-- the mapper could not be resolved; on success the diagnostic is nil.
-- Returns manifest, packageDirectory, diagnostic.
function tsoptions.resolveContentMapperManifest(host, containingFile, packageName)
    local resolver = module.NewResolver(host, core.NewCompilerOptions({ moduleResolution = core.ModuleResolutionKind.Bundler }), "", "", nil)
    local resolved = resolver:ResolvePackageDirectory(packageName, containingFile, core.ModuleKind.ResolutionModeNone, nil)
    if resolved == nil or resolved.resolvedFileName == "" then
        return emptyManifest(), "", ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_package_0_could_not_be_resolved, packageName)
    end
    local packageDirectory = resolved.resolvedFileName

    local packageJsonPath = tspath.CombinePaths(packageDirectory, "package.json")
    local contents, ok = host:FS():ReadFile(packageJsonPath)
    if not ok then
        return emptyManifest(), packageDirectory, ast.NewCompilerDiagnostic(diagnostics.The_content_mapper_package_0_could_not_be_resolved, packageName)
    end
    local fields, err = packagejson.Parse(contents)
    if err ~= nil then
        return emptyManifest(), packageDirectory, ast.NewCompilerDiagnostic(diagnostics.The_package_json_of_the_content_mapper_package_0_could_not_be_parsed, packageName)
    end
    local name = fields.name:GetValue()
    if name == nil or name == "" then
        return emptyManifest(), packageDirectory, ast.NewCompilerDiagnostic(diagnostics.The_package_json_of_the_content_mapper_package_0_does_not_specify_a_name, packageName)
    end
    local version = fields.version:GetValue()

    -- A content mapper package must declare how to run it: a "typescript.contentMapper" object with a non-empty
    -- "exec" array of strings.
    local cm
    cm, ok = fields.contentMapper:GetValue()
    if not ok then
        return emptyManifest(), packageDirectory, ast.NewCompilerDiagnostic(diagnostics.The_package_json_of_the_content_mapper_package_0_does_not_declare_a_typescript_contentMapper_object, packageName)
    end
    local exec
    exec, ok = cm.exec:GetValue()
    if not ok or core.Len(exec) == 0 then
        return emptyManifest(), packageDirectory, ast.NewCompilerDiagnostic(diagnostics.The_typescript_contentMapper_exec_of_the_content_mapper_package_0_must_be_a_non_empty_array_of_strings, packageName)
    end
    local compilerOptions = cm.compilerOptions:GetValue()
    local dynamicConfig = cm.dynamicConfig:GetValue()
    return contentmapper.NewManifest({ name = name, version = version, exec = exec, compilerOptions = compilerOptions, dynamicConfig = dynamicConfig }), packageDirectory, nil
end
