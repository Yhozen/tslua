local autoimport = require("tslua.ls.autoimport")
local collections = require("tslua.collections")
local modulespecifiers = require("tslua.modulespecifiers")

local View = autoimport.View
local ResultKind = modulespecifiers.ResultKind

function View:GetModuleSpecifier(export, userPreferences)
    -- Ambient module
    if modulespecifiers.PathIsBareSpecifier(export.moduleID) then
        local specifier = export.moduleID
        if modulespecifiers.IsExcludedByRegex(specifier, userPreferences.autoImportSpecifierExcludeRegexes) then
            return "", ResultKind.None
        end
        return export.moduleID, ResultKind.Ambient
    end

    if export.packageName ~= "" then
        local entrypoints = self.registry.entrypoints and self.registry.entrypoints[export.path]
        if entrypoints ~= nil then
            for _, entrypoint in ipairs(entrypoints) do
                if collections.Set.IsSubsetOf(entrypoint.includeConditions, self.conditions) and not collections.Set.Intersects(self.conditions, entrypoint.excludeConditions) then
                    local specifier = modulespecifiers.ProcessEntrypointEnding(
                        entrypoint,
                        userPreferences,
                        self.program,
                        self.program:Options(),
                        self.importingFile,
                        self:getAllowedEndings()
                    )

                    if not modulespecifiers.IsExcludedByRegex(specifier, userPreferences.autoImportSpecifierExcludeRegexes) then
                        return specifier, ResultKind.NodeModules
                    end
                end
            end
            return "", ResultKind.None
        end
    end

    local cache = self.registry.specifierCache and self.registry.specifierCache[self.importingFilePath]
    if export.packageName == "" then
        if cache ~= nil then
            local specifier, ok = cache:Load(export.path)
            if ok then
                if specifier == "" then
                    return "", ResultKind.None
                end
                return specifier, ResultKind.Relative
            end
        end
    end

    local specifiers, kind = modulespecifiers.GetModuleSpecifiersForFileWithInfo(
        self.importingFile,
        export.moduleFileName,
        self.program:Options(),
        self.program,
        userPreferences,
        modulespecifiers.ModuleSpecifierOptions_new({}),
        true
    )
    -- !!! unsure when this could return multiple specifiers combined with the
    --     new node_modules code. Possibly with local symlinks, which should be
    --     very rare.
    for _, specifier in ipairs(specifiers or {}) do
        if string.find(specifier, "/node_modules/", 1, true) == nil then
            if cache ~= nil then
                cache:Store(export.path, specifier)
            end
            return specifier, kind
        end
    end
    if cache ~= nil then
        cache:Store(export.path, "")
    end
    return "", ResultKind.None
end
