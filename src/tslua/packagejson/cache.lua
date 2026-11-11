local packagejson = require("tslua.packagejson")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local semver = require("tslua.semver")
local tspath = require("tslua.tspath")

local JSONValueType = packagejson.JSONValueType

packagejson.typeScriptVersion = semver.MustParse(core.Version())

-- PackageJson embeds Fields (flattened) and adds parseable, versionPaths, versionTraces.
local PackageJson = setmetatable({}, { __index = packagejson.Fields })
PackageJson.__index = PackageJson
packagejson.PackageJson = PackageJson

-- NewPackageJson builds &PackageJson{Fields: fields, Parseable: parseable}.
function packagejson.NewPackageJson(fields, parseable)
    local p = setmetatable({}, PackageJson)
    for k, v in pairs(fields) do
        p[k] = v
    end
    p.parseable = parseable or false
    p.versionPaths = packagejson.newVersionPaths()
    p.versionTraces = nil
    p.once = false
    return p
end

-- diagnosticAndArgs: { message = *diagnostics.Message, args = {...} }

function PackageJson:GetVersionPaths(trace)
    if not self.once then
        self.once = true
        local function add(message, args)
            self.versionTraces = core.Append(self.versionTraces, { message = message, args = args })
        end
        repeat
            if self.typesVersions.type == JSONValueType.NotPresent then
                add(diagnostics.X_package_json_does_not_have_a_0_field, { "typesVersions" })
                break
            end
            if self.typesVersions.type ~= JSONValueType.Object then
                add(diagnostics.Expected_type_of_0_field_in_package_json_to_be_1_got_2, { "typesVersions", "object", packagejson.JSONValueType_String(self.typesVersions.type) })
                break
            end
            add(diagnostics.X_package_json_has_a_typesVersions_field_with_version_specific_path_mappings, { "typesVersions" })
            local done = false
            for key, value in self.typesVersions:AsObject():Entries() do
                local keyRange, ok = semver.TryParseVersionRange(key)
                if not ok then
                    add(diagnostics.X_package_json_has_a_typesVersions_entry_0_that_is_not_a_valid_semver_range, { key })
                elseif keyRange:Test(packagejson.typeScriptVersion) then
                    if value.type ~= JSONValueType.Object then
                        add(diagnostics.Expected_type_of_0_field_in_package_json_to_be_1_got_2, { "typesVersions['" .. key .. "']", "object", packagejson.JSONValueType_String(value.type) })
                        done = true
                        break
                    end
                    self.versionPaths = packagejson.newVersionPaths(key, value:AsObject())
                    done = true
                    break
                end
            end
            if done then
                break
            end
            add(diagnostics.X_package_json_does_not_have_a_typesVersions_entry_that_matches_version_0, { core.VersionMajorMinor() })
        until true
    end
    if trace ~= nil then
        for _, msg in ipairs(self.versionTraces or {}) do
            trace(msg.message, table.unpack(msg.args))
        end
    end
    return self.versionPaths
end

local VersionPaths = {}
VersionPaths.__index = VersionPaths
packagejson.VersionPaths = VersionPaths

function packagejson.newVersionPaths(version, pathsJSON)
    return setmetatable({ version = version or "", pathsJSON = pathsJSON, paths = nil }, VersionPaths)
end

function VersionPaths:Exists()
    return self ~= nil and self.version ~= "" and self.pathsJSON ~= nil
end

function VersionPaths:GetPaths()
    if not self:Exists() then
        return nil
    end
    if self.paths ~= nil then
        return self.paths
    end
    local paths = collections.NewOrderedMapWithSizeHint(self.pathsJSON:Size())
    for key, value in self.pathsJSON:Entries() do
        if value.type == JSONValueType.Array then
            local arr = value:AsArray()
            local slice = {}
            for i, path in ipairs(arr) do
                if path.type ~= JSONValueType.String then
                    slice[i] = ""
                else
                    slice[i] = path.value
                end
            end
            paths:Set(key, slice)
        end
    end
    self.paths = paths
    return self.paths
end

local InfoCacheEntry = {}
InfoCacheEntry.__index = InfoCacheEntry
packagejson.InfoCacheEntry = InfoCacheEntry

function packagejson.NewInfoCacheEntry(packageDirectory, directoryExists, contents)
    return setmetatable({
        packageDirectory = packageDirectory or "",
        directoryExists = directoryExists or false,
        contents = contents,
    }, InfoCacheEntry)
end

-- The nil-receiver-safe methods are also exposed as package functions taking a possibly-nil entry.
function InfoCacheEntry:Exists()
    return self ~= nil and self.contents ~= nil
end

function InfoCacheEntry:GetContents()
    if self == nil or self.contents == nil then
        return nil
    end
    return self.contents
end

function InfoCacheEntry:GetDirectory()
    if self == nil then
        return ""
    end
    return self.packageDirectory
end

-- WithPackageDirectory returns an entry whose PackageDirectory matches the
-- caller's value. The package.json info cache is keyed by the canonical
-- path of the package.json file, but multiple callers may look up the same
-- package.json using directory paths that differ only by a trailing
-- separator (e.g. "node_modules/preact/compat" vs
-- "node_modules/preact/compat/"). Because the cache uses first-writer-wins
-- semantics, a later caller may receive an entry whose PackageDirectory
-- doesn't match its own candidate path. Downstream code compares the
-- candidate against PackageDirectory, so we must return a corrected
-- shallow copy when they diverge.
-- See https://github.com/microsoft/TypeScript/pull/50740.
function InfoCacheEntry:WithPackageDirectory(packageDirectory)
    if self.packageDirectory == packageDirectory then
        return self
    end
    return packagejson.NewInfoCacheEntry(packageDirectory, self.directoryExists, self.contents)
end

local InfoCache = {}
InfoCache.__index = InfoCache
packagejson.InfoCache = InfoCache

function packagejson.NewInfoCache(currentDirectory, useCaseSensitiveFileNames)
    return setmetatable({
        cache = {},
        currentDirectory = currentDirectory,
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
    }, InfoCache)
end

function InfoCache:Get(packageJsonPath)
    local key = tspath.ToPath(packageJsonPath, self.currentDirectory, self.useCaseSensitiveFileNames)
    return self.cache[key]
end

function InfoCache:Set(packageJsonPath, info)
    local key = tspath.ToPath(packageJsonPath, self.currentDirectory, self.useCaseSensitiveFileNames)
    local actual = self.cache[key]
    if actual == nil then
        self.cache[key] = info
        actual = info
    end
    return actual
end

function InfoCache:Range(f)
    for key, value in pairs(self.cache) do
        if not f(key, value) then
            return
        end
    end
end
