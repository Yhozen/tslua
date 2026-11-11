local module = require("tslua.module")
local packagejson = require("tslua.packagejson")

-- ModeAwareCache[T] is a Lua table keyed by module.ModeAwareCacheKeyString(name, mode).

local function moduleResolutionCacheKey(containingDirectory, moduleName, resolutionMode, redirectConfigName)
    return table.concat({ containingDirectory, moduleName, tostring(resolutionMode), redirectConfigName }, "\0")
end
module.moduleResolutionCacheKey = moduleResolutionCacheKey

local moduleResolutionCache = {}
moduleResolutionCache.__index = moduleResolutionCache
module.moduleResolutionCache = moduleResolutionCache

function module.newModuleResolutionCache()
    return setmetatable({ cache = {} }, moduleResolutionCache)
end

function moduleResolutionCache:Get(key)
    local value = self.cache[key]
    return value, value ~= nil
end

function moduleResolutionCache:Set(key, value)
    if self.cache[key] == nil then
        self.cache[key] = value
    end
end

local function typeRefDirectiveResolutionCacheKey(containingDirectory, typeReferenceName, resolutionMode, redirectConfigName, fromInferredTypesContainingFile)
    return table.concat({ containingDirectory, typeReferenceName, tostring(resolutionMode), redirectConfigName, tostring(fromInferredTypesContainingFile) }, "\0")
end
module.typeRefDirectiveResolutionCacheKey = typeRefDirectiveResolutionCacheKey

local typeRefDirectiveResolutionCache = {}
typeRefDirectiveResolutionCache.__index = typeRefDirectiveResolutionCache
module.typeRefDirectiveResolutionCache = typeRefDirectiveResolutionCache

function module.newTypeRefDirectiveResolutionCache()
    return setmetatable({ cache = {} }, typeRefDirectiveResolutionCache)
end

function typeRefDirectiveResolutionCache:Get(key)
    local value = self.cache[key]
    return value, value ~= nil
end

function typeRefDirectiveResolutionCache:Set(key, value)
    self.cache[key] = value
end

-- caches is embedded in Resolver; newCaches returns the fields to flatten onto it.
function module.newCaches(currentDirectory, useCaseSensitiveFileNames, options)
    return {
        packageJsonInfoCache = packagejson.NewInfoCache(currentDirectory, useCaseSensitiveFileNames),
        moduleResolutionCache = module.newModuleResolutionCache(),
        typeRefDirectiveResolutionCache = module.newTypeRefDirectiveResolutionCache(),
        -- Cached representation for `core.CompilerOptions.paths`.
        -- Doesn't handle other path patterns like in `typesVersions`.
        parsedPatternsForPathsOnce = false,
        parsedPatternsForPaths = nil,
    }
end

function module.getRedirectConfigName(redirect)
    if redirect == nil then
        return ""
    end
    return redirect:ConfigName()
end
