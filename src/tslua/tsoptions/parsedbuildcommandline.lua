local tsoptions = require("tslua.tsoptions")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

-- ParsedBuildCommandLine: { buildOptions, compilerOptions, watchOptions, projects, errors, raw,
--   comparePathsOptions, resolvedProjectPaths, resolvedProjectPathsOnce, locale, localeOnce }
local ParsedBuildCommandLine = {}
ParsedBuildCommandLine.__index = ParsedBuildCommandLine
tsoptions.ParsedBuildCommandLine = ParsedBuildCommandLine

function ParsedBuildCommandLine:ResolvedProjectPaths()
    if not self.resolvedProjectPathsOnce then
        self.resolvedProjectPathsOnce = true
        self.resolvedProjectPaths = core.Map(self.projects, function(project)
            return core.ResolveConfigFileNameOfProjectReference(
                tspath.ResolvePath(self.comparePathsOptions.currentDirectory, project)
            )
        end)
    end
    return self.resolvedProjectPaths
end

function ParsedBuildCommandLine:Locale()
    if not self.localeOnce then
        self.localeOnce = true
        self.locale = require("tslua.locale").Parse(self.compilerOptions.locale)
    end
    return self.locale
end
