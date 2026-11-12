local autoimport = require("tslua.ls.autoimport")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local module = require("tslua.module")
local modulespecifiers = require("tslua.modulespecifiers")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local QueryKind = autoimport.QueryKind

local View = {}
View.__index = View
autoimport.View = View

function autoimport.NewView(registry, importingFile, projectKey, program, preferences)
    local importingFilePath = importingFile:Path()
    local canonical = importingFile:CanonicalSourceFile()
    if canonical ~= nil then
        importingFilePath = canonical:Path()
    end
    return setmetatable({
        registry = registry,
        importingFile = importingFile,
        importingFilePath = importingFilePath,
        program = program,
        projectKey = projectKey,
        preferences = preferences,
        allowedEndings = nil,
        conditions = collections.NewSetFromItems(table.unpack(
            module.GetConditions(program:Options(),
                program:GetDefaultResolutionModeForFile(importingFile)) or {}
        )),
        shouldUseUriStyleNodeCoreModules = lsutil.ShouldUseUriStyleNodeCoreModules(importingFile, program),
        existingImports = nil,
        shouldUseRequireForFixes = nil,
    }, View)
end

function View:getAllowedEndings()
    if self.allowedEndings == nil then
        local resolutionMode = self.program:GetDefaultResolutionModeForFile(self.importingFile)
        self.allowedEndings = modulespecifiers.GetAllowedEndingsInPreferredOrder(
            self.preferences,
            self.program,
            self.program:Options(),
            self.importingFile,
            "",
            resolutionMode
        )
    end
    return self.allowedEndings
end

function View:Search(query, kind)
    local searchFn = function(bucket)
        if kind == QueryKind.WordPrefix then
            return bucket.index:SearchWordPrefix(query)
        elseif kind == QueryKind.ExactMatch then
            return bucket.index:Find(query, true)
        elseif kind == QueryKind.CaseInsensitiveMatch then
            return bucket.index:Find(query, false)
        else
            error("unreachable", 0)
        end
    end

    return self:search(searchFn)
end

function View:SearchByExportID(id)
    local search = function(bucket)
        return core.Filter(bucket.index.entries, function(e)
            return e.moduleID == id.moduleID and e.exportName == id.exportName
        end)
    end

    return self:search(search)
end

function View:search(searchFn)
    local results = nil

    local bucket = self.registry.projects and self.registry.projects[self.projectKey]
    if bucket ~= nil then
        local exports = searchFn(bucket)
        for _, e in ipairs(exports or {}) do
            -- Don't auto-import from the importing file itself
            if e.moduleID ~= self.importingFile:Path() then
                results = results or {}
                results[#results + 1] = e
            end
        end
    end

    -- Compute the set of packages accessible to the importing file.
    -- This includes packages from package.json dependencies (aggregated from ancestor directories)
    -- plus packages that are directly imported by the project's program files.
    -- If no package.json is found, allowedPackages remains nil and all packages are allowed.
    local allowedPackages = nil
    tspath.ForEachAncestorDirectoryPath(tspath.Path_GetDirectoryPath(self.importingFile:Path()), function(dirPath)
        local dir = self.registry.directories and self.registry.directories[dirPath]
        if dir ~= nil then
            local pj = dir.packageJson
            if pj ~= nil and pj:Exists() and pj.contents.parseable then
                -- Initialize to empty set if this is the first package.json we've seen
                if allowedPackages == nil then
                    allowedPackages = collections.NewSet()
                end
                autoimport.addPackageJsonDependencies(pj.contents, allowedPackages)
            end
        end
        return nil, false
    end)
    -- If we found at least one package.json, also include packages directly imported by the project
    if allowedPackages ~= nil then
        local projectBucket = self.registry.projects and self.registry.projects[self.projectKey]
        if projectBucket ~= nil then
            allowedPackages = allowedPackages:UnionedWith(projectBucket.resolvedPackageNames)
        end
    end

    local excludePackages = collections.NewSet()
    tspath.ForEachAncestorDirectoryPath(tspath.Path_GetDirectoryPath(self.importingFile:Path()), function(dirPath)
        local nodeModulesBucket = self.registry.nodeModules and self.registry.nodeModules[dirPath]
        if nodeModulesBucket ~= nil then
            local exports = searchFn(nodeModulesBucket)
            for _, e in ipairs(exports or {}) do
                -- Exclude packages found in lower node_modules (shadowing)
                if excludePackages:Has(e.packageName) then
                    goto continue
                end
                -- If allowedPackages is nil, no package.json was found, so include all packages.
                -- Otherwise, only include packages that are dependencies or directly imported.
                if allowedPackages ~= nil and not allowedPackages:Has(e.packageName) then
                    goto continue
                end
                results = results or {}
                results[#results + 1] = e
                ::continue::
            end

            -- As we go up the directory tree, exclude packages found in lower node_modules
            for _, pkgName in ipairs(autoimport.sortedKeys(nodeModulesBucket.packageFiles)) do
                excludePackages:Add(pkgName)
            end
        end
        return nil, false
    end)
    return results
end

-- sortedKeys returns the keys of a Lua map in sorted order (deterministic stand-in for Go's
-- random map iteration order).
function autoimport.sortedKeys(m)
    local keys = {}
    if m == nil then
        return keys
    end
    for k in pairs(m) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

-- FixAndExport { fix, export }.
function autoimport.NewFixAndExport(fix, export)
    return { fix = fix, export = export }
end

local function isUpperFirstByte(name)
    -- Go unicode.IsUpper(rune(name[0])): the first byte as a rune.
    return stringutil.UnicodeIsUpper(string.byte(name, 1))
end

function View:GetCompletions(ctx, prefix, position, forJSX, isTypeOnlyLocation)
    local results = self:Search(prefix, QueryKind.WordPrefix)

    -- exportGroupKey { target, name, ambientModuleOrPackageName } is encoded as a string key;
    -- groupOrder keeps the first-seen order of keys.
    local grouped = {}
    local groupOrder = {}
    for _, e in ipairs(results or {}) do
        local name = e:Name()
        if not scanner.IsIdentifierText(name, core.LanguageVariant.Standard) then
            goto outer
        end
        if forJSX and not (isUpperFirstByte(name) or e:IsRenameable()) then
            goto outer
        end
        do
            local target = e:ExportID()
            if not autoimport.ExportID_IsZero(e.target) then
                target = e.target
            end
            local ambientModuleOrPackageName = core.FirstNonZero(e:AmbientModuleName(), e.packageName)
            if e.packageName == "@types/node" or string.find(e.path, "/node_modules/@types/node/", 1, true) ~= nil then
                if core.UnprefixedNodeCoreModules[ambientModuleOrPackageName] ~= nil then
                    -- Group URI-style and non-URI style node core modules together so the ranking logic
                    -- is allowed to drop one if an explicit preference is detected.
                    ambientModuleOrPackageName = "node:" .. ambientModuleOrPackageName
                end
            end
            local key = autoimport.ExportID_Key(target) .. "\0" .. name .. "\0" .. ambientModuleOrPackageName
            local existing = grouped[key]
            if existing ~= nil then
                for i1, ex in ipairs(existing) do
                    if e.moduleID == ex.moduleID and e.exportName == ex.exportName then
                        existing[i1] = autoimport.newExport({
                            moduleID = e.moduleID,
                            exportName = e.exportName,
                            moduleFileName = e.moduleFileName,
                            packageName = e.packageName,
                            isTypeOnly = e.isTypeOnly or ex.isTypeOnly,
                            syntax = math.min(e.syntax, ex.syntax),
                            flags = e.flags | ex.flags,
                            scriptElementKind = math.min(e.scriptElementKind, ex.scriptElementKind),
                            scriptElementKindModifiers = e.scriptElementKindModifiers | ex.scriptElementKindModifiers,
                            localName = e.localName,
                            target = e.target,
                            path = e.path,
                        })
                        goto outer
                    end
                end
            else
                existing = {}
                grouped[key] = existing
                groupOrder[#groupOrder + 1] = key
            end
            existing[#existing + 1] = e
        end
        ::outer::
    end

    local fixes = {}
    local compareFixes = function(a, b)
        return self:CompareFixesForRanking(a.fix, b.fix)
    end

    for _, key in ipairs(groupOrder) do
        local exps = grouped[key]
        local fixesForGroup = {}
        for _, e in ipairs(exps) do
            for _, fix in ipairs(self:GetFixes(ctx, e, forJSX, isTypeOnlyLocation, position) or {}) do
                fixesForGroup[#fixesForGroup + 1] = autoimport.NewFixAndExport(fix, e)
            end
        end
        for _, f in ipairs(core.MinAllFunc(fixesForGroup, compareFixes) or {}) do
            fixes[#fixes + 1] = f
        end
    end

    -- The client will do additional sorting by SortText and Label, so we don't
    -- need to consider the name in our sorting here; we only need to produce a
    -- stable relative ordering between completions that the client will consider
    -- equivalent.
    core.SortFunc(fixes, function(a, b)
        return self:CompareFixesForSorting(a.fix, b.fix)
    end)

    return fixes
end
