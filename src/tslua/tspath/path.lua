local tspath = require("tslua.tspath")
local stringutil = require("tslua.stringutil")

local sbyte, ssub, sfind = string.byte, string.sub, string.find

-- Path is a plain Lua string (Go `type Path string`). Methods on Path are package functions
-- tspath.Path_<Method>(p, ...).

local CH_SLASH = 0x2F -- '/'
local CH_BACKSLASH = 0x5C -- '\\'
local CH_DOT = 0x2E -- '.'
local CH_COLON = 0x3A -- ':'

-- Internally, we represent paths as strings with '/' as the directory separator.
-- When we make system calls (eg: LanguageServiceHost.getDirectory()),
-- we expect the host to correctly handle paths in our specified format.
-- tspath.DirectorySeparator is the byte value of '/' (generated constant).
tspath.urlSchemeSeparator = "://"

local function hasPrefix(s, prefix)
    return ssub(s, 1, #prefix) == prefix
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and ssub(s, #s - #suffix + 1) == suffix
end

-- 0-based index of the last occurrence of the plain string sub, or -1.
local function lastIndex(s, sub)
    local n, m = #s, #sub
    for i = n - m + 1, 1, -1 do
        if ssub(s, i, i + m - 1) == sub then
            return i - 1
        end
    end
    return -1
end

-- 0-based index of the first occurrence of the plain string sub at or after 0-based init, or -1.
local function index(s, sub, init)
    local i = sfind(s, sub, (init or 0) + 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

local function split(s, sep)
    local result = {}
    local start = 1
    while true do
        local i = sfind(s, sep, start, true)
        if i == nil then
            result[#result + 1] = ssub(s, start)
            return result
        end
        result[#result + 1] = ssub(s, start, i - 1)
        start = i + #sep
    end
end

local function count(s, sub)
    local c = 0
    local start = 1
    while true do
        local i = sfind(s, sub, start, true)
        if i == nil then
            return c
        end
        c = c + 1
        start = i + #sub
    end
end

local function compareInts(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

local function sliceArray(xs, a, b)
    local result = {}
    for i = a + 1, b do
        result[#result + 1] = xs[i]
    end
    return result
end

---- Path Tests

-- Determines whether a byte corresponds to `/` or `\`.
function tspath.isAnyDirectorySeparator(char)
    return char == CH_SLASH or char == CH_BACKSLASH
end

-- Determines whether a path starts with a URL scheme (e.g. starts with `http://`, `ftp://`, `file://`, etc.).
function tspath.IsUrl(path)
    return tspath.GetEncodedRootLength(path) < 0
end

-- Determines whether a path is an absolute disk path (e.g. starts with `/`, or a dos path
-- like `c:`, `c:\` or `c:/`).
function tspath.IsRootedDiskPath(path)
    return tspath.GetEncodedRootLength(path) > 0
end

-- Determines whether a path consists only of a path root.
function tspath.IsDiskPathRoot(path)
    local rootLength = tspath.GetEncodedRootLength(path)
    return rootLength > 0 and rootLength == #path
end

-- IsDynamicFileName returns true if the file name represents a dynamic/virtual file
-- that doesn't exist on disk (e.g., untitled files with paths like "^/untitled/...").
function tspath.IsDynamicFileName(fileName)
    return hasPrefix(fileName, "^/")
end

-- Determines whether a path starts with an absolute path component (i.e. `/`, `c:/`, `file://`, etc.).
--
--	// POSIX
--	PathIsAbsolute("/path/to/file.ext") === true
--	// DOS
--	PathIsAbsolute("c:/path/to/file.ext") === true
--	// URL
--	PathIsAbsolute("file:///path/to/file.ext") === true
--	// Non-absolute
--	PathIsAbsolute("path/to/file.ext") === false
--	PathIsAbsolute("./path/to/file.ext") === false
function tspath.PathIsAbsolute(path)
    return tspath.GetEncodedRootLength(path) ~= 0
end

function tspath.HasTrailingDirectorySeparator(path)
    return #path > 0 and tspath.isAnyDirectorySeparator(sbyte(path, #path))
end

-- Combines paths. If a path is absolute, it replaces any previous path. Relative paths are not simplified.
--
--	// Non-rooted
--	CombinePaths("path", "to", "file.ext") === "path/to/file.ext"
--	CombinePaths("path", "dir", "..", "to", "file.ext") === "path/dir/../to/file.ext"
--	// POSIX
--	CombinePaths("/path", "to", "file.ext") === "/path/to/file.ext"
--	CombinePaths("/path", "/to", "file.ext") === "/to/file.ext"
--	// DOS
--	CombinePaths("c:/path", "to", "file.ext") === "c:/path/to/file.ext"
--	CombinePaths("c:/path", "c:/to", "file.ext") === "c:/to/file.ext"
--	// URL
--	CombinePaths("file:///path", "to", "file.ext") === "file:///path/to/file.ext"
--	CombinePaths("file:///path", "file:///to", "file.ext") === "file:///to/file.ext"
function tspath.CombinePaths(firstPath, ...)
    local result = tspath.NormalizeSlashes(firstPath)
    for i = 1, select("#", ...) do
        local trailingPath = select(i, ...)
        if trailingPath ~= "" then
            trailingPath = tspath.NormalizeSlashes(trailingPath)
            if result == "" or tspath.GetRootLength(trailingPath) ~= 0 then
                -- `trailingPath` is absolute.
                result = trailingPath
            else
                if not tspath.HasTrailingDirectorySeparator(result) then
                    result = result .. "/"
                end
                result = result .. trailingPath
            end
        end
    end
    return result
end

function tspath.GetPathComponents(path, currentDirectory)
    path = tspath.CombinePaths(currentDirectory, path)
    return tspath.pathComponents(path, tspath.GetRootLength(path))
end

function tspath.pathComponents(path, rootLength)
    local root = ssub(path, 1, rootLength)
    local rest = split(ssub(path, rootLength + 1), "/")
    if #rest > 0 and rest[#rest] == "" then
        rest[#rest] = nil
    end
    local result = { root }
    for i = 1, #rest do
        result[i + 1] = rest[i]
    end
    return result
end

function tspath.IsVolumeCharacter(char)
    return char >= 0x61 and char <= 0x7A or char >= 0x41 and char <= 0x5A
end

function tspath.getFileUrlVolumeSeparatorEnd(url, start)
    if #url <= start then
        return -1
    end
    local ch0 = sbyte(url, start + 1)
    if ch0 == CH_COLON then
        return start + 1
    end
    if ch0 == 0x25 --[['%']] and #url > start + 2 and sbyte(url, start + 2) == 0x33 --[['3']] then
        local ch2 = sbyte(url, start + 3)
        if ch2 == 0x61 or ch2 == 0x41 then
            return start + 3
        end
    end
    return -1
end

function tspath.GetEncodedRootLength(path)
    local ln = #path
    if ln == 0 then
        return 0
    end
    local ch0 = sbyte(path, 1)

    -- POSIX or UNC
    if ch0 == CH_SLASH or ch0 == CH_BACKSLASH then
        if ln == 1 or sbyte(path, 2) ~= ch0 then
            return 1 -- POSIX: "/" (or non-normalized "\")
        end

        local offset = 2
        local p1 = sfind(path, string.char(ch0), offset + 1, true)
        if p1 == nil then
            return ln -- UNC: "//server" or "\\server"
        end

        return p1 -- UNC: "//server/" or "\\server\"
    end

    -- DOS
    if tspath.IsVolumeCharacter(ch0) and ln > 1 and sbyte(path, 2) == CH_COLON then
        if ln == 2 then
            return 2 -- DOS: "c:" (but not "c:d")
        end
        local ch2 = sbyte(path, 3)
        if ch2 == CH_SLASH or ch2 == CH_BACKSLASH then
            return 3 -- DOS: "c:/" or "c:\"
        end
    end

    -- Untitled paths (e.g., "^/untitled/ts-nul-authority/Untitled-1")
    if ch0 == 0x5E --[['^']] and ln > 1 and sbyte(path, 2) == CH_SLASH then
        return 2 -- Untitled: "^/"
    end

    -- URL
    local schemeEnd = index(path, tspath.urlSchemeSeparator)
    if schemeEnd ~= -1 then
        local authorityStart = schemeEnd + #tspath.urlSchemeSeparator
        local authorityLength = index(ssub(path, authorityStart + 1), "/")
        if authorityLength ~= -1 then -- URL: "file:///", "file://server/", "file://server/path"
            local authorityEnd = authorityStart + authorityLength

            -- For local "file" URLs, include the leading DOS volume (if present).
            -- Per https://www.ietf.org/rfc/rfc1738.txt, a host of "" or "localhost" is a
            -- special case interpreted as "the machine from which the URL is being interpreted".
            local scheme = ssub(path, 1, schemeEnd)
            local authority = ssub(path, authorityStart + 1, authorityEnd)
            if scheme == "file" and (authority == "" or authority == "localhost") and (#path > authorityEnd + 2) and tspath.IsVolumeCharacter(sbyte(path, authorityEnd + 2)) then
                local volumeSeparatorEnd = tspath.getFileUrlVolumeSeparatorEnd(path, authorityEnd + 2)
                if volumeSeparatorEnd ~= -1 then
                    if volumeSeparatorEnd == #path then
                        -- URL: "file:///c:", "file://localhost/c:", "file:///c$3a", "file://localhost/c%3a"
                        -- but not "file:///c:d" or "file:///c%3ad"
                        return ~volumeSeparatorEnd
                    end
                    if sbyte(path, volumeSeparatorEnd + 1) == CH_SLASH then
                        -- URL: "file:///c:/", "file://localhost/c:/", "file:///c%3a/", "file://localhost/c%3a/"
                        return ~(volumeSeparatorEnd + 1)
                    end
                end
            end
            return ~(authorityEnd + 1) -- URL: "file://server/", "http://server/"
        end
        return ~ln -- URL: "file://server", "http://server"
    end

    -- relative
    return 0
end

function tspath.GetRootLength(path)
    local rootLength = tspath.GetEncodedRootLength(path)
    if rootLength < 0 then
        return ~rootLength
    end
    return rootLength
end

function tspath.GetDirectoryPath(path)
    path = tspath.NormalizeSlashes(path)

    -- If the path provided is itself a root, then return it.
    local rootLength = tspath.GetRootLength(path)
    if rootLength == #path then
        return path
    end

    -- return the leading portion of the path up to the last (non-terminal) directory separator
    -- but not including any trailing directory separator.
    path = tspath.RemoveTrailingDirectorySeparator(path)
    return ssub(path, 1, math.max(rootLength, lastIndex(path, "/")))
end

function tspath.Path_GetDirectoryPath(p)
    return tspath.GetDirectoryPath(p)
end

function tspath.GetPathFromPathComponents(pathComponents)
    if pathComponents == nil or #pathComponents == 0 then
        return ""
    end

    local root = pathComponents[1]
    if root ~= "" then
        root = tspath.EnsureTrailingDirectorySeparator(root)
    end

    return root .. table.concat(pathComponents, "/", 2)
end

function tspath.NormalizeSlashes(path)
    if not sfind(path, "\\", 1, true) then
        return path
    end
    return (string.gsub(path, "\\", "/"))
end

function tspath.reducePathComponents(components)
    if components == nil or #components == 0 then
        return {}
    end
    local reduced = { components[1] }
    for i = 2, #components do
        local component = components[i]
        if component == "" then
            goto continue
        end
        if component == "." then
            goto continue
        end
        if component == ".." then
            if #reduced > 1 then
                if reduced[#reduced] ~= ".." then
                    reduced[#reduced] = nil
                    goto continue
                end
            elseif reduced[1] ~= "" then
                goto continue
            end
        end
        reduced[#reduced + 1] = component
        ::continue::
    end
    return reduced
end

-- Combines and resolves paths. If a path is absolute, it replaces any previous path. Any
-- `.` and `..` path components are resolved. Trailing directory separators are preserved.
--
-- resolvePath("/path", "to", "file.ext") == "path/to/file.ext"
-- resolvePath("/path", "to", "file.ext/") == "path/to/file.ext/"
-- resolvePath("/path", "dir", "..", "to", "file.ext") == "path/to/file.ext"
function tspath.ResolvePath(path, ...)
    local combinedPath
    if select("#", ...) > 0 then
        combinedPath = tspath.CombinePaths(path, ...)
    else
        combinedPath = tspath.NormalizeSlashes(path)
    end
    return tspath.NormalizePath(combinedPath)
end

function tspath.ResolveTripleslashReference(moduleName, containingFile)
    local basePath = tspath.GetDirectoryPath(containingFile)
    if tspath.IsRootedDiskPath(moduleName) then
        return tspath.NormalizePath(moduleName)
    end
    return tspath.NormalizePath(tspath.CombinePaths(basePath, moduleName))
end

function tspath.GetNormalizedPathComponents(path, currentDirectory)
    local combined = tspath.CombinePaths(currentDirectory, path)
    return tspath.getNormalizedPathComponentsFromCombined(combined)
end

function tspath.getNormalizedPathComponentsFromCombined(path)
    local rootLength = tspath.GetRootLength(path)
    -- Always include the root component (empty string for relative paths).
    local components = { ssub(path, 1, rootLength) }

    local n = #path
    local i = rootLength
    while i < n do
        -- Skip directory separators (handles consecutive separators and trailing '/').
        while i < n and sbyte(path, i + 1) == CH_SLASH do
            i = i + 1
        end
        if i >= n then
            break
        end

        local start = i
        while i < n and sbyte(path, i + 1) ~= CH_SLASH do
            i = i + 1
        end
        local component = ssub(path, start + 1, i)

        if component == "" or component == "." then
            goto continue
        end
        if component == ".." then
            if #components > 1 then
                if components[#components] ~= ".." then
                    components[#components] = nil
                    goto continue
                end
            elseif components[1] ~= "" then
                -- If this is an absolute path, we can't go above the root.
                goto continue
            end
        end

        components[#components + 1] = component
        ::continue::
    end

    return components
end

function tspath.GetNormalizedAbsolutePathWithoutRoot(fileName, currentDirectory)
    local absolutePath = tspath.GetNormalizedAbsolutePath(fileName, currentDirectory)
    local rootLength = tspath.GetRootLength(absolutePath)
    return ssub(absolutePath, rootLength + 1)
end

function tspath.GetNormalizedAbsolutePath(fileName, currentDirectory)
    local rootLength = tspath.GetRootLength(fileName)
    if rootLength == 0 and currentDirectory ~= "" then
        fileName = tspath.CombinePaths(currentDirectory, fileName)
    else
        -- CombinePaths normalizes slashes, so not necessary in other branch
        fileName = tspath.NormalizeSlashes(fileName)
    end
    rootLength = tspath.GetRootLength(fileName)

    local simpleNormalized, ok = tspath.simpleNormalizePath(fileName)
    if ok then
        local length = #simpleNormalized
        if length > rootLength then
            return tspath.RemoveTrailingDirectorySeparator(simpleNormalized)
        end
        if length == rootLength and rootLength ~= 0 then
            return tspath.EnsureTrailingDirectorySeparator(simpleNormalized)
        end
        return simpleNormalized
    end

    local length = #fileName
    local root = ssub(fileName, 1, rootLength)
    -- `normalized` is only initialized once `fileName` is determined to be non-normalized.
    -- `changed` is set at the same time.
    local changed = false
    local normalized = ""
    local segmentStart = 0
    local idx = rootLength
    local normalizedUpTo = idx
    local seenNonDotDotSegment = rootLength ~= 0
    while idx < length do
        -- At beginning of segment
        segmentStart = idx
        local ch = sbyte(fileName, idx + 1)
        while ch == CH_SLASH do
            idx = idx + 1
            if idx < length then
                ch = sbyte(fileName, idx + 1)
            else
                break
            end
        end
        if idx > segmentStart then
            -- Seen superfluous separator
            if not changed then
                normalized = ssub(fileName, 1, math.max(rootLength, segmentStart - 1))
                changed = true
            end
            if idx == length then
                break
            end
            segmentStart = idx
        end
        -- Past any superfluous separators
        local segmentEnd = index(fileName, "/", idx + 1)
        if segmentEnd == -1 then
            segmentEnd = length
        end
        local segmentLength = segmentEnd - segmentStart
        if segmentLength == 1 and sbyte(fileName, idx + 1) == CH_DOT then
            -- "." segment (skip)
            if not changed then
                normalized = ssub(fileName, 1, normalizedUpTo)
                changed = true
            end
        elseif segmentLength == 2 and sbyte(fileName, idx + 1) == CH_DOT and sbyte(fileName, idx + 2) == CH_DOT then
            -- ".." segment
            if not seenNonDotDotSegment then
                if changed then
                    if #normalized == rootLength then
                        normalized = normalized .. ".."
                    else
                        normalized = normalized .. "/.."
                    end
                else
                    normalizedUpTo = idx + 2
                end
            elseif not changed then
                if normalizedUpTo - 1 >= 0 then
                    normalized = ssub(fileName, 1, math.max(rootLength, lastIndex(ssub(fileName, 1, normalizedUpTo - 1), "/")))
                else
                    normalized = ssub(fileName, 1, normalizedUpTo)
                end
                changed = true
                seenNonDotDotSegment = (#normalized ~= rootLength or rootLength ~= 0) and normalized ~= ".." and not hasSuffix(normalized, "/..")
            else
                local lastSlash = lastIndex(normalized, "/")
                if lastSlash ~= -1 then
                    normalized = ssub(normalized, 1, math.max(rootLength, lastSlash))
                else
                    normalized = root
                end
                seenNonDotDotSegment = (#normalized ~= rootLength or rootLength ~= 0) and normalized ~= ".." and not hasSuffix(normalized, "/..")
            end
        elseif changed then
            if #normalized ~= rootLength then
                normalized = normalized .. "/"
            end
            seenNonDotDotSegment = true
            normalized = normalized .. ssub(fileName, segmentStart + 1, segmentEnd)
        else
            seenNonDotDotSegment = true
            normalizedUpTo = segmentEnd
        end
        idx = segmentEnd + 1
    end
    if changed then
        return normalized
    end
    if length > rootLength then
        return tspath.RemoveTrailingDirectorySeparators(fileName)
    end
    if length == rootLength then
        return tspath.EnsureTrailingDirectorySeparator(fileName)
    end
    return fileName
end

-- Returns (string, ok).
function tspath.simpleNormalizePath(path)
    -- Most paths don't require normalization
    if not tspath.hasRelativePathSegment(path) then
        return path, true
    end
    -- Some paths only require cleanup of `/./` or leading `./`
    local simplified = path
    if sfind(simplified, "/./", 1, true) then
        -- strings.ReplaceAll (non-overlapping, left to right)
        local parts = {}
        local start = 1
        while true do
            local i = sfind(simplified, "/./", start, true)
            if i == nil then
                parts[#parts + 1] = ssub(simplified, start)
                break
            end
            parts[#parts + 1] = ssub(simplified, start, i - 1)
            parts[#parts + 1] = "/"
            start = i + 3
        end
        simplified = table.concat(parts)
    end
    local trimmed = simplified
    if hasPrefix(trimmed, "./") then
        trimmed = ssub(trimmed, 3)
    end
    if trimmed ~= path and not tspath.hasRelativePathSegment(trimmed) and not (trimmed ~= simplified and hasPrefix(trimmed, "/")) then
        -- If we trimmed a leading "./" and the path now starts with "/", we changed the meaning
        path = trimmed
        return path, true
    end
    return "", false
end

-- hasRelativePathSegment reports whether p contains ".", "..", "./", "../", "/.", "/..", "//", "/./", or "/../".
function tspath.hasRelativePathSegment(p)
    local n = #p
    if n == 0 then
        return false
    end

    if p == "." or p == ".." then
        return true
    end

    -- Leading "./" OR "../"
    if sbyte(p, 1) == CH_DOT then
        if n >= 2 and sbyte(p, 2) == CH_SLASH then
            return true
        end
        -- Leading "../"
        if n >= 3 and sbyte(p, 2) == CH_DOT and sbyte(p, 3) == CH_SLASH then
            return true
        end
    end
    -- Trailing "/." OR "/.."
    if sbyte(p, n) == CH_DOT then
        if n >= 2 and sbyte(p, n - 1) == CH_SLASH then
            return true
        end
        if n >= 3 and sbyte(p, n - 1) == CH_DOT and sbyte(p, n - 2) == CH_SLASH then
            return true
        end
    end

    -- Now look for any `//` or `/./` or `/../`

    local prevSlash = false
    local segLen = 0 -- length of current segment since last slash
    local dotCount = 0 -- consecutive dots at start of the current segment; -1 => not only dots

    for i = 1, n do
        local c = sbyte(p, i)
        if c == CH_SLASH then
            -- "//"
            if prevSlash then
                return true
            end
            -- "/./" or "/../"
            if (segLen == 1 and dotCount == 1) or (segLen == 2 and dotCount == 2) then
                return true
            end
            prevSlash = true
            segLen = 0
            dotCount = 0
        else
            if c == CH_DOT then
                if dotCount >= 0 then
                    dotCount = dotCount + 1
                end
            else
                dotCount = -1
            end
            segLen = segLen + 1
            prevSlash = false
        end
    end

    -- Trailing "/." or "/.."
    return (segLen == 1 and dotCount == 1) or (segLen == 2 and dotCount == 2)
end

function tspath.NormalizePath(path)
    path = tspath.NormalizeSlashes(path)
    local normalized, ok = tspath.simpleNormalizePath(path)
    if ok then
        return normalized
    end
    normalized = tspath.GetNormalizedAbsolutePath(path, "")
    if normalized ~= "" and tspath.HasTrailingDirectorySeparator(path) then
        normalized = tspath.EnsureTrailingDirectorySeparator(normalized)
    end
    return normalized
end

function tspath.GetCanonicalFileName(fileName, useCaseSensitiveFileNames)
    if useCaseSensitiveFileNames then
        return fileName
    end
    return tspath.ToFileNameLowerCase(fileName)
end

-- TrimFilePathPrefix removes prefix from the start of path, honoring
-- useCaseSensitiveFileNames the same way GetCanonicalFileName does. It returns
-- the remainder of path and true if path starts with prefix; otherwise it
-- returns path unchanged and false.
--
-- This must not slice path using len(prefix): case-folding (as performed by
-- GetCanonicalFileName) can change a string's UTF-8 byte length without
-- changing its rune count (e.g. the Kelvin sign '\u212A' case-folds to the
-- single-byte 'k'), so path and prefix can disagree in byte length even when
-- one is (a case-insensitive match for) a prefix of the other.
function tspath.TrimFilePathPrefix(path, prefix, useCaseSensitiveFileNames)
    if useCaseSensitiveFileNames then
        if hasPrefix(path, prefix) then
            return ssub(path, #prefix + 1), true
        end
        return path, false
    end
    local canonicalPrefix = tspath.GetCanonicalFileName(prefix, false --[[useCaseSensitiveFileNames]])
    if not hasPrefix(tspath.GetCanonicalFileName(path, false --[[useCaseSensitiveFileNames]]), canonicalPrefix) then
        return path, false
    end
    local runeCount = 0
    local i = 0
    while i < #canonicalPrefix do
        local _, size = stringutil.DecodeRune(canonicalPrefix, i)
        i = i + size
        runeCount = runeCount + 1
    end
    return tspath.trimRuneCount(path, runeCount), true
end

-- trimRuneCount returns the suffix of s after skipping up to runeCount runes,
-- clamping to the end of s if it has fewer runes than runeCount.
function tspath.trimRuneCount(s, runeCount)
    local i = 0
    for _ = 1, runeCount do
        if i >= #s then
            break
        end
        local _, size = stringutil.DecodeRune(s, i)
        i = i + size
    end
    return ssub(s, i + 1)
end

-- We convert the file names to lower case as key for file name on case insensitive file system
-- While doing so we need to handle special characters (eg \u0130) to ensure that we dont convert
-- it to lower case, fileName with its lowercase form can exist along side it.
-- Handle special characters and make those case sensitive instead
--
-- |-#--|-Unicode--|-Char code-|-Desc-------------------------------------------------------------------|
-- | 1. | i        | 105       | Ascii i                                                                |
-- | 2. | I        | 73        | Ascii I                                                                |
-- |-------- Special characters ------------------------------------------------------------------------|
-- | 3. | \u0130   | 304       | Upper case I with dot above                                            |
-- | 4. | i,\u0307 | 105,775   | i, followed by 775: Lower case of (3rd item)                           |
-- | 5. | I,\u0307 | 73,775    | I, followed by 775: Upper case of (4th item), lower case is (4th item) |
-- | 6. | \u0131   | 305       | Lower case i without dot, upper case is I (2nd item)                   |
-- | 7. | \u00DF   | 223       | Lower case sharp s                                                     |
--
-- Because item 3 is special where in its lowercase character has its own
-- upper case form we cant convert its case.
-- Rest special characters are either already in lower case format or
-- they have corresponding upper case character so they dont need special handling
function tspath.ToFileNameLowerCase(fileName)
    local IWithDot = 0x0130

    if not sfind(fileName, "[\128-\255]") then
        if not sfind(fileName, "[A-Z]") then
            return fileName
        end
        return (string.gsub(fileName, "[A-Z]", function(c)
            return string.char(sbyte(c) + 32)
        end))
    end

    -- strings.Map: invalid UTF-8 bytes become U+FFFD.
    local parts = {}
    local pos = 0
    local n = #fileName
    while pos < n do
        local r, size = stringutil.DecodeRune(fileName, pos)
        pos = pos + size
        if r ~= IWithDot then
            r = stringutil.UnicodeToLower(r)
        end
        parts[#parts + 1] = stringutil.EncodeRune(r)
    end
    return table.concat(parts)
end

function tspath.ToPath(fileName, basePath, useCaseSensitiveFileNames)
    local nonCanonicalizedPath
    if tspath.IsRootedDiskPath(fileName) then
        nonCanonicalizedPath = tspath.NormalizePath(fileName)
    else
        nonCanonicalizedPath = tspath.GetNormalizedAbsolutePath(fileName, basePath)
    end
    return tspath.GetCanonicalFileName(nonCanonicalizedPath, useCaseSensitiveFileNames)
end

function tspath.RemoveTrailingDirectorySeparator(path)
    if tspath.HasTrailingDirectorySeparator(path) then
        return ssub(path, 1, #path - 1)
    end
    return path
end

function tspath.Path_RemoveTrailingDirectorySeparator(p)
    return tspath.RemoveTrailingDirectorySeparator(p)
end

function tspath.RemoveTrailingDirectorySeparators(path)
    while tspath.HasTrailingDirectorySeparator(path) do
        path = tspath.RemoveTrailingDirectorySeparator(path)
    end
    return path
end

function tspath.EnsureTrailingDirectorySeparator(path)
    if not tspath.HasTrailingDirectorySeparator(path) then
        return path .. "/"
    end

    return path
end

function tspath.Path_EnsureTrailingDirectorySeparator(p)
    return tspath.EnsureTrailingDirectorySeparator(p)
end

---- Relative Paths

function tspath.GetPathComponentsRelativeTo(from, to, options)
    local currentDirectory = options.currentDirectory or ""
    local fromComponents = tspath.reducePathComponents(tspath.GetPathComponents(from, currentDirectory))
    local toComponents = tspath.reducePathComponents(tspath.GetPathComponents(to, currentDirectory))

    local start = 0
    local maxCommonComponents = math.min(#fromComponents, #toComponents)
    local stringEqualer = tspath.ComparePathsOptions.getEqualityComparer(options)
    while start < maxCommonComponents do
        local fromComponent = fromComponents[start + 1]
        local toComponent = toComponents[start + 1]
        if start == 0 then
            if not stringutil.EquateStringCaseInsensitive(fromComponent, toComponent) then
                break
            end
        else
            if not stringEqualer(fromComponent, toComponent) then
                break
            end
        end
        start = start + 1
    end

    if start == 0 then
        return toComponents
    end

    local numDotDotSlashes = #fromComponents - start
    local result = { "" }
    -- Add all the relative components until we hit a common directory.
    for _ = 1, numDotDotSlashes do
        result[#result + 1] = ".."
    end
    -- Now add all the remaining components of the "to" path.
    for i = start + 1, #toComponents do
        result[#result + 1] = toComponents[i]
    end

    return result
end

function tspath.GetRelativePathFromDirectory(fromDirectory, to, options)
    if (tspath.GetRootLength(fromDirectory) > 0) ~= (tspath.GetRootLength(to) > 0) then
        error("paths must either both be absolute or both be relative", 0)
    end
    local pathComponents = tspath.GetPathComponentsRelativeTo(fromDirectory, to, options)
    return tspath.GetPathFromPathComponents(pathComponents)
end

function tspath.GetRelativePathFromFile(from, to, options)
    return tspath.EnsurePathIsNonModuleName(tspath.GetRelativePathFromDirectory(tspath.GetDirectoryPath(from), to, options))
end

function tspath.ConvertToRelativePath(absoluteOrRelativePath, options)
    if not tspath.IsRootedDiskPath(absoluteOrRelativePath) then
        return absoluteOrRelativePath
    end

    return tspath.GetRelativePathToDirectoryOrUrl(options.currentDirectory or "", absoluteOrRelativePath, false --[[isAbsolutePathAnUrl]], options)
end

function tspath.GetRelativePathToDirectoryOrUrl(directoryPathOrUrl, relativeOrAbsolutePath, isAbsolutePathAnUrl, options)
    local pathComponents = tspath.GetPathComponentsRelativeTo(
        directoryPathOrUrl,
        relativeOrAbsolutePath,
        options
    )

    local firstComponent = pathComponents[1]
    if isAbsolutePathAnUrl and tspath.IsRootedDiskPath(firstComponent) then
        local prefix
        if sbyte(firstComponent, 1) == CH_SLASH then
            prefix = "file://"
        else
            prefix = "file:///"
        end
        pathComponents[1] = prefix .. firstComponent
    end

    return tspath.GetPathFromPathComponents(pathComponents)
end

-- Gets the portion of a path following the last (non-terminal) separator (`/`).
-- Semantics align with NodeJS's `path.basename` except that we support URL's as well.
-- If the base name has any one of the provided extensions, it is removed.
--
--	// POSIX
--	GetBaseFileName("/path/to/file.ext") == "file.ext"
--	GetBaseFileName("/path/to/") == "to"
--	GetBaseFileName("/") == ""
--	// DOS
--	GetBaseFileName("c:/path/to/file.ext") == "file.ext"
--	GetBaseFileName("c:/path/to/") == "to"
--	GetBaseFileName("c:/") == ""
--	GetBaseFileName("c:") == ""
--	// URL
--	GetBaseFileName("http://typescriptlang.org/path/to/file.ext") == "file.ext"
--	GetBaseFileName("http://typescriptlang.org/path/to/") == "to"
--	GetBaseFileName("http://typescriptlang.org/") == ""
--	GetBaseFileName("http://typescriptlang.org") == ""
--	GetBaseFileName("file://server/path/to/file.ext") == "file.ext"
--	GetBaseFileName("file://server/path/to/") == "to"
--	GetBaseFileName("file://server/") == ""
--	GetBaseFileName("file://server") == ""
--	GetBaseFileName("file:///path/to/file.ext") == "file.ext"
--	GetBaseFileName("file:///path/to/") == "to"
--	GetBaseFileName("file:///") == ""
--	GetBaseFileName("file://") == ""
function tspath.GetBaseFileName(path)
    path = tspath.NormalizeSlashes(path)

    -- if the path provided is itself the root, then it has no file name.
    local rootLength = tspath.GetRootLength(path)
    if rootLength == #path then
        return ""
    end

    -- return the trailing portion of the path starting after the last (non-terminal) directory
    -- separator but not including any trailing directory separator.
    path = tspath.RemoveTrailingDirectorySeparator(path)
    return ssub(path, math.max(tspath.GetRootLength(path), lastIndex(path, "/") + 1) + 1)
end

-- Gets the file extension for a path.
-- If extensions are provided, gets the file extension for a path, provided it is one of the provided extensions.
--
--	GetAnyExtensionFromPath("/path/to/file.ext", nil, false) == ".ext"
--	GetAnyExtensionFromPath("/path/to/file.ext/", nil, false) == ".ext"
--	GetAnyExtensionFromPath("/path/to/file", nil, false) == ""
--	GetAnyExtensionFromPath("/path/to.ext/file", nil, false) == ""
--	GetAnyExtensionFromPath("/path/to/file.ext", ".ext", true) === ".ext"
--	GetAnyExtensionFromPath("/path/to/file.js", ".ext", true) === ""
--	GetAnyExtensionFromPath("/path/to/file.js", [".ext", ".js"], true) === ".js"
--	GetAnyExtensionFromPath("/path/to/file.ext", ".EXT", false) === ""
function tspath.GetAnyExtensionFromPath(path, extensions, ignoreCase)
    -- Retrieves any string from the final "." onwards from a base file name.
    -- Unlike extensionFromPath, which throws an exception on unrecognized extensions.
    if extensions ~= nil and #extensions > 0 then
        return tspath.getAnyExtensionFromPathWorker(tspath.RemoveTrailingDirectorySeparator(path), extensions, stringutil.GetStringEqualityComparer(ignoreCase))
    end

    local baseFileName = tspath.GetBaseFileName(path)
    local extensionIndex = lastIndex(baseFileName, ".")
    if extensionIndex >= 0 then
        return ssub(baseFileName, extensionIndex + 1)
    end
    return ""
end

function tspath.GetLongestExtensionFromPath(path, extensions, ignoreCase)
    path = tspath.RemoveTrailingDirectorySeparator(path)
    local comparer = stringutil.GetStringEqualityComparer(ignoreCase)
    local longest = ""
    for _, extension in ipairs(extensions or {}) do
        if #extension > #longest then
            local matched = tspath.tryGetExtensionFromPath(path, extension, comparer)
            if matched ~= "" then
                longest = matched
            end
        end
    end
    return longest
end

function tspath.getAnyExtensionFromPathWorker(path, extensions, stringEqualityComparer)
    for _, extension in ipairs(extensions) do
        local result = tspath.tryGetExtensionFromPath(path, extension, stringEqualityComparer)
        if result ~= "" then
            return result
        end
    end
    return ""
end

function tspath.tryGetExtensionFromPath(path, extension, stringEqualityComparer)
    if not hasPrefix(extension, ".") then
        extension = "." .. extension
    end
    if #path >= #extension and sbyte(path, #path - #extension + 1) == CH_DOT then
        local pathExtension = ssub(path, #path - #extension + 1)
        if stringEqualityComparer(pathExtension, extension) then
            return pathExtension
        end
    end
    return ""
end

function tspath.PathIsRelative(path)
    -- True if path is ".", "..", or starts with "./", "../", ".\\", or "..\\".

    if path == "." or path == ".." then
        return true
    end

    local c0, c1, c2 = sbyte(path, 1, 3)
    if #path >= 2 and c0 == CH_DOT and (c1 == CH_SLASH or c1 == CH_BACKSLASH) then
        return true
    end

    if #path >= 3 and c0 == CH_DOT and c1 == CH_DOT and (c2 == CH_SLASH or c2 == CH_BACKSLASH) then
        return true
    end

    return false
end

-- EnsurePathIsNonModuleName ensures a path is either absolute (prefixed with `/` or `c:`) or dot-relative (prefixed
-- with `./` or `../`) so as not to be confused with an unprefixed module name.
function tspath.EnsurePathIsNonModuleName(path)
    if not tspath.PathIsAbsolute(path) and not tspath.PathIsRelative(path) then
        return "./" .. path
    end
    return path
end

function tspath.IsExternalModuleNameRelative(moduleName)
    -- TypeScript 1.0 spec (April 2014): 11.2.1
    -- An external module name is "relative" if the first term is "." or "..".
    -- Update: We also consider a path like `C:\foo.ts` "relative" because we do not search for it in `node_modules` or treat it as an ambient module.
    return tspath.PathIsRelative(moduleName) or tspath.IsRootedDiskPath(moduleName)
end

-- ComparePathsOptions: { useCaseSensitiveFileNames = bool, currentDirectory = string }.
-- A plain table literal works everywhere (missing fields mean false / ""); methods are called
-- as tspath.ComparePathsOptions.GetComparer(o) or o:GetComparer() on tables built with
-- tspath.NewComparePathsOptions.
local ComparePathsOptions = {}
ComparePathsOptions.__index = ComparePathsOptions
tspath.ComparePathsOptions = ComparePathsOptions

function tspath.NewComparePathsOptions(useCaseSensitiveFileNames, currentDirectory)
    return setmetatable({
        useCaseSensitiveFileNames = useCaseSensitiveFileNames == true,
        currentDirectory = currentDirectory or "",
    }, ComparePathsOptions)
end

function ComparePathsOptions.GetComparer(o)
    return stringutil.GetStringComparer(not o.useCaseSensitiveFileNames)
end

function ComparePathsOptions.getEqualityComparer(o)
    return stringutil.GetStringEqualityComparer(not o.useCaseSensitiveFileNames)
end

function tspath.ComparePaths(a, b, options)
    local currentDirectory = options.currentDirectory or ""
    a = tspath.CombinePaths(currentDirectory, a)
    b = tspath.CombinePaths(currentDirectory, b)

    if a == b then
        return 0
    end
    if a == "" then
        return -1
    end
    if b == "" then
        return 1
    end

    -- NOTE: Performance optimization - shortcut if the root segments differ as there would be no
    --       need to perform path reduction.
    local aRoot = ssub(a, 1, tspath.GetRootLength(a))
    local bRoot = ssub(b, 1, tspath.GetRootLength(b))
    local result = stringutil.CompareStringsCaseInsensitive(aRoot, bRoot)
    if result ~= 0 then
        return result
    end

    -- NOTE: Performance optimization - shortcut if there are no relative path segments in
    --       the non-root portion of the path
    local aRest = ssub(a, #aRoot + 1)
    local bRest = ssub(b, #bRoot + 1)
    if not tspath.hasRelativePathSegment(aRest) and not tspath.hasRelativePathSegment(bRest) then
        return ComparePathsOptions.GetComparer(options)(aRest, bRest)
    end

    -- The path contains a relative path segment. Normalize the paths and perform a slower component
    -- by component comparison.
    local aComponents = tspath.reducePathComponents(tspath.GetPathComponents(a, ""))
    local bComponents = tspath.reducePathComponents(tspath.GetPathComponents(b, ""))
    local sharedLength = math.min(#aComponents, #bComponents)
    for i = 1, sharedLength - 1 do
        local r = ComparePathsOptions.GetComparer(options)(aComponents[i + 1], bComponents[i + 1])
        if r ~= 0 then
            return r
        end
    end
    return compareInts(#aComponents, #bComponents)
end

function tspath.ComparePathsCaseSensitive(a, b, currentDirectory)
    return tspath.ComparePaths(a, b, { useCaseSensitiveFileNames = true, currentDirectory = currentDirectory })
end

function tspath.ComparePathsCaseInsensitive(a, b, currentDirectory)
    return tspath.ComparePaths(a, b, { useCaseSensitiveFileNames = false, currentDirectory = currentDirectory })
end

function tspath.ContainsPath(parent, child, options)
    local currentDirectory = options.currentDirectory or ""
    parent = tspath.CombinePaths(currentDirectory, parent)
    child = tspath.CombinePaths(currentDirectory, child)
    if parent == "" or child == "" then
        return false
    end
    if parent == child then
        return true
    end
    local parentComponents = tspath.reducePathComponents(tspath.GetPathComponents(parent, ""))
    local childComponents = tspath.reducePathComponents(tspath.GetPathComponents(child, ""))
    if #childComponents < #parentComponents then
        return false
    end

    local componentComparer = ComparePathsOptions.getEqualityComparer(options)
    for i, parentComponent in ipairs(parentComponents) do
        local comparer
        if i == 1 then
            comparer = stringutil.EquateStringCaseInsensitive
        else
            comparer = componentComparer
        end
        if not comparer(parentComponent, childComponents[i]) then
            return false
        end
    end

    return true
end

-- ContainsPath checks whether child is contained within or equal to p.
-- Since Path values are already rooted, reduced, and case-canonicalized,
-- this is a simple string prefix check.
function tspath.Path_ContainsPath(p, child)
    if #p == 0 then
        return false
    end
    return p == child or #child > #p and hasPrefix(child, p) and (sbyte(p, #p) == CH_SLASH or sbyte(child, #p + 1) == CH_SLASH)
end

function tspath.FileExtensionIs(path, extension)
    return #path > #extension and hasSuffix(path, extension)
end

-- Calls `callback` on `directory` and every ancestor directory it has, returning the first defined result.
-- Stops at global cache location
-- callback returns (result, stop).
function tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(globalCacheLocation, directory, callback)
    local result = tspath.ForEachAncestorDirectory(directory, function(ancestorDirectory)
        local r, stop = callback(ancestorDirectory)
        if stop or ancestorDirectory == globalCacheLocation then
            return r, true
        end
        return r, false
    end)
    return result
end

-- callback returns (result, stop). Returns (result, ok). When no callback stops, the result is
-- the Go zero value inferred from the last callback result ("" for strings, 0, false, else nil).
function tspath.ForEachAncestorDirectory(directory, callback)
    while true do
        local result, stop = callback(directory)
        if stop then
            return result, true
        end

        local parentPath = tspath.GetDirectoryPath(directory)
        if parentPath == directory then
            local tr = type(result)
            if tr == "string" then
                return "", false
            elseif tr == "number" then
                return 0, false
            elseif tr == "boolean" then
                return false, false
            end
            return nil, false
        end

        directory = parentPath
    end
end

function tspath.ForEachAncestorDirectoryPath(directory, callback)
    return tspath.ForEachAncestorDirectory(directory, callback)
end

function tspath.HasExtension(fileName)
    return sfind(tspath.GetBaseFileName(fileName), ".", 1, true) ~= nil
end

-- Returns (volume, rest, ok).
function tspath.SplitVolumePath(path)
    if #path >= 2 and tspath.IsVolumeCharacter(sbyte(path, 1)) and sbyte(path, 2) == CH_COLON then
        return string.lower(ssub(path, 1, 2)), ssub(path, 3), true
    end
    return "", path, false
end

-- GetCommonParents returns the smallest set of directories that are parents of all paths with
-- at least `minComponents` directory components. Any path that has fewer than `minComponents` directory components
-- will be returned in the second return value (a set: path -> true). Examples:
--
--	/a/b/c/d, /a/b/c/e, /a/b/f/g  =>  /a/b
--	/a/b/c/d, /a/b/c/e, /a/b/f/g, /x/y  =>  /
--	/a/b/c/d, /a/b/c/e, /a/b/f/g, /x/y  (minComponents: 2)	=>  /a/b, /x/y
--	c:/a/b/c/d, d:/a/b/c/d =>	c:/a/b/c/d, d:/a/b/c/d
function tspath.GetCommonParents(paths, minComponents, getPathComponents, options)
    if minComponents < 1 then
        error("minComponents must be at least 1", 0)
    end
    local currentDirectory = options.currentDirectory or ""
    if paths == nil or #paths == 0 then
        return nil, nil
    end
    if #paths == 1 then
        if #tspath.reducePathComponents(getPathComponents(paths[1], currentDirectory)) < minComponents then
            return nil, { [paths[1]] = true }
        end
        return paths, nil
    end

    local ignored = {}
    local pathComponents = {}
    for _, path in ipairs(paths) do
        local components = tspath.reducePathComponents(getPathComponents(path, currentDirectory))
        if #components < minComponents then
            ignored[path] = true
        else
            pathComponents[#pathComponents + 1] = components
        end
    end

    local results = tspath.getCommonParentsWorker(pathComponents, minComponents, options)
    local resultPaths = {}
    for i, comps in ipairs(results or {}) do
        resultPaths[i] = tspath.GetPathFromPathComponents(comps)
    end

    return resultPaths, ignored
end

function tspath.getCommonParentsWorker(componentGroups, minComponents, options)
    if #componentGroups == 0 then
        return nil
    end
    -- Determine the maximum depth we can consider
    local maxDepth = #componentGroups[1]
    for k = 2, #componentGroups do
        local l = #componentGroups[k]
        if l < maxDepth then
            maxDepth = l
        end
    end

    local equality = ComparePathsOptions.getEqualityComparer(options)
    for lastCommonIndex = 0, maxDepth - 1 do
        local candidate = componentGroups[1][lastCommonIndex + 1]
        for k = 2, #componentGroups do
            local comps = componentGroups[k]
            if not equality(candidate, comps[lastCommonIndex + 1]) then -- divergence
                if lastCommonIndex < minComponents then
                    -- Not enough components, we need to fan out
                    local orderedGroups = {}
                    local newGroups = {}
                    for _, g in ipairs(componentGroups) do
                        local key = tspath.ToPath(g[lastCommonIndex + 1], options.currentDirectory or "", options.useCaseSensitiveFileNames == true)
                        local existing = newGroups[key]
                        if existing == nil then
                            orderedGroups[#orderedGroups + 1] = key
                        end
                        local tails = existing and existing.tails or {}
                        tails[#tails + 1] = sliceArray(g, lastCommonIndex + 1, #g)
                        newGroups[key] = {
                            head = sliceArray(g, 0, lastCommonIndex + 1),
                            tails = tails,
                        }
                    end
                    table.sort(orderedGroups)
                    local result = {}
                    for _, key in ipairs(orderedGroups) do
                        local group = newGroups[key]
                        local subResults = tspath.getCommonParentsWorker(group.tails, minComponents - (lastCommonIndex + 1), options)
                        for _, sr in ipairs(subResults or {}) do
                            local combined = {}
                            for _, c in ipairs(group.head) do
                                combined[#combined + 1] = c
                            end
                            for _, c in ipairs(sr) do
                                combined[#combined + 1] = c
                            end
                            result[#result + 1] = combined
                        end
                    end
                    return result
                end
                return { sliceArray(componentGroups[1], 0, lastCommonIndex) }
            end
        end
    end

    return { sliceArray(componentGroups[1], 0, maxDepth) }
end

function tspath.StartsWithDirectory(fileName, directoryName, useCaseSensitiveFileNames)
    if directoryName == "" then
        return false
    end

    local canonicalFileName = tspath.GetCanonicalFileName(fileName, useCaseSensitiveFileNames)
    local canonicalDirectoryName = tspath.GetCanonicalFileName(directoryName, useCaseSensitiveFileNames)
    if hasSuffix(canonicalDirectoryName, "/") then
        canonicalDirectoryName = ssub(canonicalDirectoryName, 1, #canonicalDirectoryName - 1)
    end
    if hasSuffix(canonicalDirectoryName, "\\") then
        canonicalDirectoryName = ssub(canonicalDirectoryName, 1, #canonicalDirectoryName - 1)
    end

    return hasPrefix(canonicalFileName, canonicalDirectoryName .. "/") or
        hasPrefix(canonicalFileName, canonicalDirectoryName .. "\\")
end

function tspath.CompareNumberOfDirectorySeparators(path1, path2)
    return compareInts(count(path1, "/"), count(path2, "/"))
end
