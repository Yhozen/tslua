local project = require("tslua.project")
local tsoptions = require("tslua.tsoptions")

-- ExtendedConfigParseArgs: { fileName, content, fs (FileSource), resolutionStack, host, cache }

-- ExtendedConfigCacheEntry: { extendedConfigCacheEntry = *tsoptions.ExtendedConfigCacheEntry, hash }

-- ExtendedConfigCache = OwnerCache[tspath.Path, *ExtendedConfigCacheEntry, ExtendedConfigParseArgs]
function project.NewExtendedConfigCache()
    return project.NewOwnerCache(
        function(path, args)
            local result = {
                extendedConfigCacheEntry = tsoptions.ParseExtendedConfig(args.fileName, path, args.resolutionStack, args.host, args.cache),
                hash = "",
            }
            result.hash = project.hash(result.extendedConfigCacheEntry, args)
            return result
        end,
        function(path, entry, args)
            return entry.hash == "" or entry.hash ~= project.hash(entry.extendedConfigCacheEntry, args)
        end
    )
end

function project.hash(entry, args)
    local parts = { args.content }
    for _, fileName in ipairs(entry:ExtendedFileNames() or {}) do
        local fh = args.fs:GetFile(fileName)
        if fh == nil then
            return ""
        end
        parts[#parts + 1] = fh:Content()
    end
    return project.hashString(table.concat(parts))
end

