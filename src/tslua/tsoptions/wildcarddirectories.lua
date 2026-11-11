local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfsmatch = require("tslua.vfs.vfsmatch")

local strings = require("tslua.module").strings

-- Returns map[string]bool as a Lua table (directory -> recursive), or nil.
function tsoptions.getWildcardDirectories(include, exclude, comparePathsOptions)
    -- We watch a directory recursively if it contains a wildcard anywhere in a directory segment
    -- of the pattern:
    --
    --  /a/b/**/d   - Watch /a/b recursively to catch changes to any d in any subfolder recursively
    --  /a/b/*/d    - Watch /a/b recursively to catch any d in any immediate subfolder, even if a new subfolder is added
    --  /a/b        - Watch /a/b recursively to catch changes to anything in any recursive subfoler
    --
    -- We watch a directory without recursion if it contains a wildcard in the file segment of
    -- the pattern:
    --
    --  /a/b/*      - Watch /a/b directly to catch any new file
    --  /a/b/a?z    - Watch /a/b directly to catch any new file matching a?z

    if include == nil or #include == 0 then
        return nil
    end

    local excludeMatcher = vfsmatch.NewSpecMatcher(exclude, comparePathsOptions.currentDirectory, vfsmatch.Usage.Exclude, comparePathsOptions.useCaseSensitiveFileNames)

    local wildcardDirectories = {}
    local wildCardKeyToPath = {}

    local recursiveKeys = {}

    for _, file in ipairs(include) do
        local spec = tspath.NormalizePath(tspath.CombinePaths(comparePathsOptions.currentDirectory, file))
        if excludeMatcher ~= nil and excludeMatcher:MatchString(spec) then
            goto continue
        end

        do
            local match = tsoptions.getWildcardDirectoryFromSpec(spec, comparePathsOptions.useCaseSensitiveFileNames)
            if match ~= nil then
                local key = match.key
                local path = match.path
                local recursive = match.recursive

                local existingPath = wildCardKeyToPath[key]
                local existsPath = existingPath ~= nil
                local existingRecursive = false

                if existsPath then
                    existingRecursive = wildcardDirectories[existingPath] or false
                end

                if not existsPath or (not existingRecursive and recursive) then
                    local pathToUse = path
                    if existsPath then
                        pathToUse = existingPath
                    end
                    wildcardDirectories[pathToUse] = recursive

                    if not existsPath then
                        wildCardKeyToPath[key] = path
                    end

                    if recursive then
                        recursiveKeys[#recursiveKeys + 1] = key
                    end
                end
            end

            -- Remove any subpaths under an existing recursively watched directory
            local paths = {}
            for path in pairs(wildcardDirectories) do
                paths[#paths + 1] = path
            end
            for _, path in ipairs(paths) do
                for _, recursiveKey in ipairs(recursiveKeys) do
                    local key = tsoptions.toCanonicalKey(path, comparePathsOptions.useCaseSensitiveFileNames)
                    if key ~= recursiveKey and tspath.ContainsPath(recursiveKey, key, comparePathsOptions) then
                        wildcardDirectories[path] = nil
                    end
                end
            end
        end
        ::continue::
    end

    return wildcardDirectories
end

function tsoptions.toCanonicalKey(path, useCaseSensitiveFileNames)
    if useCaseSensitiveFileNames then
        return path
    end
    return strings.ToLower(path)
end

-- wildcardDirectoryMatch represents the result of a wildcard directory match: { key, path, recursive }

function tsoptions.getWildcardDirectoryFromSpec(spec, useCaseSensitiveFileNames)
    -- Find the first occurrence of a wildcard character
    local firstWildcard = strings.IndexAny(spec, "*?")
    if firstWildcard ~= -1 then
        -- Find the last directory separator before the wildcard
        local lastSepBeforeWildcard = strings.LastIndex(string.sub(spec, 1, firstWildcard), "/")
        if lastSepBeforeWildcard ~= -1 then
            local path = string.sub(spec, 1, lastSepBeforeWildcard)
            local lastDirectorySeparatorIndex = strings.LastIndex(spec, "/")

            -- Determine if this should be watched recursively:
            -- recursive if the wildcard appears in a directory segment (not just the final file segment)
            local recursive = firstWildcard < lastDirectorySeparatorIndex

            return {
                key = tsoptions.toCanonicalKey(path, useCaseSensitiveFileNames),
                path = path,
                recursive = recursive,
            }
        end
    end

    local lastSepIndex = strings.LastIndex(spec, "/")
    if lastSepIndex ~= -1 then
        local lastSegment = string.sub(spec, lastSepIndex + 2)
        if vfsmatch.IsImplicitGlob(lastSegment) then
            local path = tspath.RemoveTrailingDirectorySeparator(spec)
            return {
                key = tsoptions.toCanonicalKey(path, useCaseSensitiveFileNames),
                path = path,
                recursive = true,
            }
        end
    end

    return nil
end
