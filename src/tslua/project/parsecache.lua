local project = require("tslua.project")
local core = require("tslua.core")
local locale = require("tslua.locale")
local parser = require("tslua.parser")
local xxh3 = require("tslua.xxh3")

-- parseOptionsKey encodes ast.SourceFileParseOptions for use in a cache key string.
local function parseOptionsKey(options)
    local emi = options.externalModuleIndicatorOptions
    return options.fileName .. "\0" .. options.path .. "\0" ..
        ((emi ~= nil and emi.jsx) and "1" or "0") .. ((emi ~= nil and emi.force) and "1" or "0")
end

-- ParseCacheKey: the embedded ast.SourceFileParseOptions fields are flattened (fileName, path,
-- externalModuleIndicatorOptions) and the original options table is kept as
-- sourceFileParseOptions; cacheKey is the comparable string encoding used by the caches.
function project.NewParseCacheKey(options, hash, scriptKind)
    if scriptKind == core.ScriptKind.Unknown then
        scriptKind = core.EnsureScriptKindFromFileName(options.fileName)
    end
    return {
        sourceFileParseOptions = options,
        fileName = options.fileName,
        path = options.path,
        externalModuleIndicatorOptions = options.externalModuleIndicatorOptions,
        hash = hash,
        scriptKind = scriptKind,
        cacheKey = parseOptionsKey(options) .. "\0" .. tostring(scriptKind) .. "\0" .. hash,
    }
end

local function newContentMappedParseCacheKey(options, hash)
    return {
        sourceFileParseOptions = options,
        fileName = options.fileName,
        path = options.path,
        externalModuleIndicatorOptions = options.externalModuleIndicatorOptions,
        hash = hash,
        cacheKey = parseOptionsKey(options) .. "\0" .. hash,
    }
end

-- ContentMappedParseCacheKey identifies the complete output bundle for one mapped input. Hash folds the
-- original content, mapper transform identity, and diagnostic locale together.
function project.contentMappedParseCacheKey(options, rawHash, transformIdentity, diagnosticLocale)
    local buf = project.hashLittleEndianBytes(rawHash) .. project.hashLittleEndianBytes(transformIdentity) ..
        locale.Locale_String(diagnosticLocale)
    return newContentMappedParseCacheKey(options, xxh3.Hash128(buf):Hex())
end

-- parseCacheKeyForFile reconstructs the ordinary parse-cache key for a source file held by a program.
function project.parseCacheKeyForFile(file)
    return project.NewParseCacheKey(file:ParseOptions(), file.hash or "", file.scriptKind)
end

function project.contentMappedParseCacheKeyForFile(file)
    return newContentMappedParseCacheKey(file:ContentMapperParseOptions(), file.hash or "")
end

-- parseCacheKeyForDuplicate reconstructs an ordinary parse-cache key for a deduplicated source file.
function project.parseCacheKeyForDuplicate(file)
    return project.NewParseCacheKey(file.parseOptions, file.hash or "", file.scriptKind)
end

function project.contentMappedParseCacheKeyForDuplicate(file)
    return newContentMappedParseCacheKey(file.contentMapperParseOptions, file.hash or "")
end

-- ParseCache = RefCountCache[ParseCacheKey, *ast.SourceFile, FileHandle]
function project.NewParseCache(options)
    return project.NewRefCountCache(
        options,
        function(key, fh)
            local file = parser.ParseSourceFile(key.sourceFileParseOptions, fh:Content(), key.scriptKind)
            file.hash = fh:Hash()
            return file
        end
    )
end

-- ContentMappedParseCache embeds a RefCountCache[ContentMappedParseCacheKey, contentmapper.SourceFiles, struct{}].
-- One reference owns the canonical file and all supplemental files as a bundle. Callers ref and
-- deref the canonical file only.
function project.NewContentMappedParseCache(options)
    return project.NewRefCountCache(options, function(key, args)
        error("content-mapped source files must be produced with AcquireOrError", 0)
    end)
end
