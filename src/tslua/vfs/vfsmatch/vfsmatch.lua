local vfsmatch = require("tslua.vfs.vfsmatch")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

local Usage = vfsmatch.Usage

-- This file implements the glob matching algorithm specified in MATCHING_ALGORITHM.md.

local function containsAny(s, chars)
    for i = 1, #chars do
        if string.find(s, string.sub(chars, i, i), 1, true) then
            return true
        end
    end
    return false
end

-- strings.EqualFold (deviation: ASCII case folding only)
local function equalFold(a, b)
    return a == b or string.lower(a) == string.lower(b)
end

function vfsmatch.ReadDirectory(host, currentDir, path, extensions, excludes, includes, depth)
    return vfsmatch.matchFiles(path, extensions, excludes, includes, host:UseCaseSensitiveFileNames(), currentDir, depth, host)
end

-- IsImplicitGlob checks if a path component is implicitly a glob.
-- An "includes" path "foo" is implicitly a glob "foo/** /*" (without the space) if its last component has no extension,
-- and does not contain any glob characters itself.
function vfsmatch.IsImplicitGlob(lastPathComponent)
    return not containsAny(lastPathComponent, ".*?")
end

vfsmatch.wildcardCharCodes = "*?"

function vfsmatch.getIncludeBasePath(absolute)
    local wildcardOffset = string.find(absolute, "[*?]")
    if wildcardOffset == nil then
        -- No "*" or "?" in the path
        if not tspath.HasExtension(absolute) then
            return absolute
        else
            return tspath.RemoveTrailingDirectorySeparator(tspath.GetDirectoryPath(absolute))
        end
    end
    local before = string.sub(absolute, 1, wildcardOffset - 1)
    local last = string.match(before, "^.*()/")
    local idx = 0
    if last ~= nil then
        idx = last - 1
    end
    return string.sub(absolute, 1, math.max(idx, 0))
end

-- getBasePaths computes the unique non-wildcard base paths amongst the provided include patterns.
function vfsmatch.getBasePaths(path, includes, useCaseSensitiveFileNames)
    -- Storage for our results in the form of literal paths (e.g. the paths as written by the user).
    local basePaths = { path }

    if core.Len(includes) > 0 then
        local comparePathsOptions = { currentDirectory = path, useCaseSensitiveFileNames = useCaseSensitiveFileNames }
        local stringComparer = tspath.ComparePathsOptions.GetComparer(comparePathsOptions)

        -- Storage for literal base paths amongst the include patterns.
        local includeBasePaths = {}
        for _, include in ipairs(includes) do
            -- We also need to check the relative paths by converting them to absolute and normalizing
            -- in case they escape the base path (e.g "..\somedirectory")
            local absolute
            if tspath.IsRootedDiskPath(include) then
                absolute = include
            else
                absolute = tspath.NormalizePath(tspath.CombinePaths(path, include))
            end
            -- Append the literal and canonical candidate base paths.
            includeBasePaths[#includeBasePaths + 1] = vfsmatch.getIncludeBasePath(absolute)
        end

        -- Sort the offsets array using either the literal or canonical path representations.
        vfsmatch.sortStableFunc(includeBasePaths, stringComparer)

        -- Iterate over each include base path and include unique base paths that are not a
        -- subpath of an existing base path
        for _, includeBasePath in ipairs(includeBasePaths) do
            if core.Every(basePaths, function(basepath)
                return not tspath.ContainsPath(basepath, includeBasePath, comparePathsOptions)
            end) then
                basePaths[#basePaths + 1] = includeBasePath
            end
        end
    end

    return basePaths
end

-- slices.SortStableFunc (insertion sort keeps equal elements in order).
function vfsmatch.sortStableFunc(xs, cmp)
    for i = 2, #xs do
        local v = xs[i]
        local j = i - 1
        while j >= 1 and cmp(xs[j], v) > 0 do
            xs[j + 1] = xs[j]
            j = j - 1
        end
        xs[j + 1] = v
    end
end

-- globPattern is a compiled glob pattern for matching file paths without regex.
--   components    -- path segments to match (e.g., ["src", "**", "*.ts"])
--   isExclude     -- exclude patterns have different matching rules
--   caseSensitive
--   excludeMinJs  -- for "files" patterns, exclude .min.js by default
local globPattern = {}
globPattern.__index = globPattern
vfsmatch.globPattern = globPattern

-- component is a single path segment in a glob pattern: { kind, literal, segments, skipPackageFolders }.
-- Examples: "src" (literal), "*" (wildcard), "*.ts" (wildcard), "**" (recursive)
vfsmatch.kindLiteral = 0        -- exact match (e.g., "src")
vfsmatch.kindWildcard = 1       -- contains * or ? (e.g., "*.ts")
vfsmatch.kindDoubleAsterisk = 2 -- ** matches zero or more directories

-- segment is a piece of a wildcard component: { kind, literal }.
-- Example: "*.ts" becomes [segStar, segLiteral(".ts")]
vfsmatch.segLiteral = 0  -- exact text
vfsmatch.segStar = 1     -- * matches any chars except /
vfsmatch.segQuestion = 2 -- ? matches single char except /

local kindLiteral, kindWildcard, kindDoubleAsterisk = vfsmatch.kindLiteral, vfsmatch.kindWildcard, vfsmatch.kindDoubleAsterisk
local segLiteral, segStar, segQuestion = vfsmatch.segLiteral, vfsmatch.segStar, vfsmatch.segQuestion

-- compileGlobPattern compiles a glob spec (e.g., "src/**/*.ts") into a pattern.
-- Returns (pattern, false) if the pattern would match nothing.
function vfsmatch.compileGlobPattern(spec, basePath, usage, caseSensitive)
    local parts = tspath.GetNormalizedPathComponents(spec, basePath)

    -- "src/**" without a filename matches nothing (for include patterns)
    if usage ~= Usage.Exclude and core.LastOrNil(parts) == "**" then
        return nil, false
    end

    -- Normalize root: "/home/" -> "/home"
    parts[1] = tspath.RemoveTrailingDirectorySeparator(parts[1])

    -- Directories implicitly match all files: "src" -> "src/**/*"
    if vfsmatch.IsImplicitGlob(core.LastOrNil(parts)) then
        parts[#parts + 1] = "**"
        parts[#parts + 1] = "*"
    end

    local p = setmetatable({
        isExclude = usage == Usage.Exclude,
        caseSensitive = caseSensitive,
        excludeMinJs = usage == Usage.Files,
        components = {},
    }, globPattern)

    for _, part in ipairs(parts) do
        p.components[#p.components + 1] = vfsmatch.parseComponent(part, usage ~= Usage.Exclude)
    end
    return p, true
end

-- parseComponent converts a path segment string into a component.
function vfsmatch.parseComponent(s, isInclude)
    if s == "**" then
        return { kind = kindDoubleAsterisk, literal = "", segments = nil, skipPackageFolders = false }
    end
    if not containsAny(s, "*?") then
        return { kind = kindLiteral, literal = s, segments = nil, skipPackageFolders = false }
    end
    return {
        kind = kindWildcard,
        literal = "",
        segments = vfsmatch.parseSegments(s),
        skipPackageFolders = isInclude,
    }
end

-- parseSegments breaks "*.ts" into [segStar, segLiteral(".ts")]
function vfsmatch.parseSegments(s)
    local result = {}
    local start = 0
    for i = 0, #s - 1 do
        local c = string.byte(s, i + 1)
        if c == 42 or c == 63 then -- '*', '?'
            if i > start then
                result[#result + 1] = { kind = segLiteral, literal = string.sub(s, start + 1, i) }
            end
            if c == 42 then
                result[#result + 1] = { kind = segStar, literal = "" }
            else
                result[#result + 1] = { kind = segQuestion, literal = "" }
            end
            start = i + 1
        end
    end
    if start < #s then
        result[#result + 1] = { kind = segLiteral, literal = string.sub(s, start + 1) }
    end
    return result
end

-- matches returns true if path matches this pattern.
function globPattern:matches(path)
    return self:matchPathParts(path, "", 0, 0, false)
end

-- matchesParts returns true if prefix+suffix matches this pattern.
-- This avoids allocating a combined string for common call sites where prefix ends with '/'.
function globPattern:matchesParts(prefix, suffix)
    return self:matchPathParts(prefix, suffix, 0, 0, false)
end

-- matchesPrefixParts returns true if files under prefix+suffix could match.
function globPattern:matchesPrefixParts(prefix, suffix)
    return self:matchPathParts(prefix, suffix, 0, 0, true)
end

-- matchPathParts is like matchPath, but operates on a virtual path formed by prefix+suffix.
-- Offsets are in the combined string.
function globPattern:matchPathParts(prefix, suffix, pathOffset, compIdx, prefixOnly)
    while true do
        local pathPart, nextOffset, ok = vfsmatch.nextPathPartParts(prefix, suffix, pathOffset)
        if not ok then
            if prefixOnly then
                return true
            end
            return self:patternSatisfied(compIdx)
        end

        if compIdx >= #self.components then
            return self.isExclude and not prefixOnly
        end

        local comp = self.components[compIdx + 1]
        if comp.kind == kindDoubleAsterisk then
            if self:matchPathParts(prefix, suffix, pathOffset, compIdx + 1, prefixOnly) then
                return true
            end
            if not self.isExclude and (vfsmatch.isHiddenPath(pathPart) or vfsmatch.isPackageFolder(pathPart)) then
                return false
            end
            pathOffset = nextOffset
            goto continue
        elseif comp.kind == kindLiteral then
            if comp.skipPackageFolders and vfsmatch.isPackageFolder(pathPart) then
                error("unreachable: literal components never have skipPackageFolders", 0)
            end
            if not self:stringsEqual(comp.literal, pathPart) then
                return false
            end
        elseif comp.kind == kindWildcard then
            if comp.skipPackageFolders and vfsmatch.isPackageFolder(pathPart) then
                return false
            end
            if not self:matchWildcard(comp.segments, pathPart) then
                return false
            end
        end

        pathOffset = nextOffset
        compIdx = compIdx + 1
        ::continue::
    end
end

-- patternSatisfied checks if remaining pattern components can match empty input.
function globPattern:patternSatisfied(compIdx)
    -- A pattern is satisfied when remaining components can match empty input.
    -- For both include and exclude patterns, only trailing "**" components may match nothing.
    for i = compIdx + 1, #self.components do
        if self.components[i].kind ~= kindDoubleAsterisk then
            return false
        end
    end
    return true
end

-- nextPathPart extracts the next path component from path starting at offset.
function vfsmatch.nextPathPartSingle(s, offset)
    if offset >= #s then
        return "", offset, false
    end
    if offset == 0 and #s > 0 and string.byte(s, 1) == 47 then
        return "", 1, true
    end
    while offset < #s and string.byte(s, offset + 1) == 47 do
        offset = offset + 1
    end
    if offset >= #s then
        return "", offset, false
    end
    local idx = string.find(s, "/", offset + 1, true)
    if idx ~= nil then
        return string.sub(s, offset + 1, idx - 1), idx - 1, true
    end
    return string.sub(s, offset + 1), #s, true
end

function vfsmatch.nextPathPartParts(prefix, suffix, offset)
    -- Fast paths: keep the hot single-string scan tight.
    if #suffix == 0 then
        return vfsmatch.nextPathPartSingle(prefix, offset)
    end
    if #prefix == 0 then
        return vfsmatch.nextPathPartSingle(suffix, offset)
    end

    -- For matchFilesNoRegex call sites, prefix is a directory path ending in '/',
    -- and suffix is a single entry name (no '/'). That makes this significantly
    -- simpler than a general-purpose "virtual concatenation" scanner.

    local totalLen = #prefix + #suffix
    if offset >= totalLen then
        return "", offset, false
    end

    -- Handle leading slash (root of absolute path)
    if offset == 0 and string.byte(prefix, 1) == 47 then
        return "", 1, true
    end

    -- Scan within prefix.
    if offset < #prefix then
        while offset < #prefix and string.byte(prefix, offset + 1) == 47 do
            offset = offset + 1
        end
        if offset < #prefix then
            local idx = string.find(prefix, "/", offset + 1, true)
            -- idx is guaranteed >= 0 for the call sites we care about because prefix ends in '/'.
            return string.sub(prefix, offset + 1, idx - 1), idx - 1, true
        end
        -- Fall through into suffix region.
    end

    -- Scan suffix: it's a single component.
    local sOff = offset - #prefix
    if sOff >= #suffix then
        return "", offset, false
    end
    return string.sub(suffix, sOff + 1), totalLen, true
end

-- matchWildcard matches a path component against wildcard segments.
function globPattern:matchWildcard(segs, s)
    -- Include patterns: wildcards at start cannot match hidden files
    if not self.isExclude and #segs > 0 and vfsmatch.isHiddenPath(s) and (segs[1].kind == segStar or segs[1].kind == segQuestion) then
        return false
    end

    -- Fast path: single * followed by literal suffix (e.g., "*.ts")
    if #segs == 2 and segs[1].kind == segStar and segs[2].kind == segLiteral then
        local suffix = segs[2].literal
        if #s < #suffix or not self:stringsEqual(suffix, string.sub(s, #s - #suffix + 1)) then
            return false
        end
        return self:shouldIncludeMinJs(s, segs)
    end

    return self:matchSegments(segs, s) and self:shouldIncludeMinJs(s, segs)
end

local function runeSize(s, i)
    local _, size = core.DecodeRune(s, i)
    return size
end

-- matchSegments matches segments against string s using an iterative algorithm.
-- This avoids exponential backtracking by tracking only the last star position.
-- The algorithm is O(n*m) where n is the string length and m is pattern length.
function globPattern:matchSegments(segs, s)
    local segIdx, sIdx = 0, 0
    local starSegIdx, starSIdx = -1, 0

    while sIdx < #s do
        if segIdx < #segs then
            local seg = segs[segIdx + 1]
            if seg.kind == segLiteral then
                local end_ = sIdx + #seg.literal
                if end_ <= #s and self:stringsEqual(seg.literal, string.sub(s, sIdx + 1, end_)) then
                    sIdx = end_
                    segIdx = segIdx + 1
                    goto continue
                end
            elseif seg.kind == segQuestion then
                if string.byte(s, sIdx + 1) ~= 47 then
                    sIdx = sIdx + runeSize(s, sIdx)
                    segIdx = segIdx + 1
                    goto continue
                end
            elseif seg.kind == segStar then
                -- Record star position for backtracking, then try matching zero chars.
                starSegIdx = segIdx
                starSIdx = sIdx
                segIdx = segIdx + 1
                goto continue
            end
        end

        -- Current segment didn't match. Backtrack to last star if possible.
        if starSegIdx >= 0 and starSIdx < #s and string.byte(s, starSIdx + 1) ~= 47 then
            -- Star consumes one more character (rune), retry from segment after star.
            starSIdx = starSIdx + runeSize(s, starSIdx)
            sIdx = starSIdx
            segIdx = starSegIdx + 1
            goto continue
        end

        do
            return false
        end
        ::continue::
    end

    -- Consume any trailing stars.
    while segIdx < #segs and segs[segIdx + 1].kind == segStar do
        segIdx = segIdx + 1
    end
    return segIdx >= #segs
end

function globPattern:shouldIncludeMinJs(filename, segs)
    if not self.excludeMinJs then
        return true
    end

    -- Preserve legacy behavior:
    -- - When matching is case-sensitive, only the exact ".min.js" suffix is excluded by default.
    -- - When matching is case-insensitive, any casing variant is excluded by default.
    if not self:hasMinJsSuffix(filename) then
        return true
    end
    -- Allow when the user's pattern explicitly references the .min. suffix.
    if self:patternMentionsMinSuffix(segs) then
        return true
    end
    return false
end

function globPattern:hasMinJsSuffix(filename)
    local minJs = ".min.js"
    if self.caseSensitive then
        return string.sub(filename, -#minJs) == minJs and #filename >= #minJs
    end
    if #filename < #minJs then
        return false
    end
    -- Avoid allocating via strings.ToLower; compare suffix case-insensitively.
    return equalFold(string.sub(filename, #filename - #minJs + 1), minJs)
end

function globPattern:patternMentionsMinSuffix(segs)
    for _, seg in ipairs(segs) do
        if seg.kind ~= segLiteral then
            goto continue
        end
        do
            local lit = seg.literal
            if not self.caseSensitive then
                lit = string.lower(lit)
            end
            if string.find(lit, ".min.js", 1, true) or string.find(lit, ".min.", 1, true) then
                return true
            end
        end
        ::continue::
    end
    return false
end

-- stringsEqual compares strings with appropriate case sensitivity.
function globPattern:stringsEqual(a, b)
    if self.caseSensitive then
        return a == b
    end
    return equalFold(a, b)
end

-- isHiddenPath checks if a path component is hidden (starts with dot).
function vfsmatch.isHiddenPath(name)
    return #name > 0 and string.byte(name, 1) == 46
end

-- isPackageFolder checks if name is a common package folder (node_modules, etc.)
function vfsmatch.isPackageFolder(name)
    local n = #name
    if n == #"node_modules" then
        return equalFold(name, "node_modules")
    elseif n == #"jspm_packages" then
        return equalFold(name, "jspm_packages")
    elseif n == #"bower_components" then
        return equalFold(name, "bower_components")
    end
    return false
end

function vfsmatch.ensureTrailingSlash(s)
    if #s > 0 and string.sub(s, -1) ~= "/" then
        return s .. "/"
    end
    return s
end

-- globMatcher combines include and exclude patterns for file matching.
local globMatcher = {}
globMatcher.__index = globMatcher
vfsmatch.globMatcher = globMatcher

function vfsmatch.newGlobMatcher(includeSpecs, excludeSpecs, basePath, caseSensitive, usage)
    local m = setmetatable({
        hadIncludes = core.Len(includeSpecs) > 0,
        includes = {},
        excludes = {},
    }, globMatcher)

    for _, spec in ipairs(includeSpecs or {}) do
        local p, ok = vfsmatch.compileGlobPattern(spec, basePath, usage, caseSensitive)
        if ok then
            m.includes[#m.includes + 1] = p
        end
    end
    for _, spec in ipairs(excludeSpecs or {}) do
        local p, ok = vfsmatch.compileGlobPattern(spec, basePath, Usage.Exclude, caseSensitive)
        if ok then
            m.excludes[#m.excludes + 1] = p
        end
    end
    return m
end

-- matchesFileParts checks if prefix+suffix matches against the glob patterns.
-- Returns the index of the matching include pattern and true if matched, or (0, false) if not.
function globMatcher:matchesFileParts(prefix, suffix)
    for i = 1, #self.excludes do
        if self.excludes[i]:matchesParts(prefix, suffix) then
            return 0, false
        end
    end
    if #self.includes == 0 then
        if self.hadIncludes then
            return 0, false
        end
        return 0, true
    end
    for i = 1, #self.includes do
        if self.includes[i]:matchesParts(prefix, suffix) then
            return i - 1, true
        end
    end
    return 0, false
end

-- matchesDirectoryParts checks if files under the directory prefix+suffix could match any pattern.
function globMatcher:matchesDirectoryParts(prefix, suffix)
    for i = 1, #self.excludes do
        if self.excludes[i]:matchesParts(prefix, suffix) then
            return false
        end
    end
    if #self.includes == 0 then
        return not self.hadIncludes
    end
    for i = 1, #self.includes do
        if self.includes[i]:matchesPrefixParts(prefix, suffix) then
            return true
        end
    end
    return false
end

-- globVisitor traverses directories matching files against glob patterns.
local globVisitor = {}
globVisitor.__index = globVisitor
vfsmatch.globVisitor = globVisitor

-- visit walks a directory tree, collecting files that match the glob patterns.
-- resolvedRealPath, when non-empty, is the already-resolved real path for this
-- directory (computed incrementally from the parent). When empty, Realpath is
-- called to resolve symlinks.
function globVisitor:visit(path, absolutePath, depth, resolvedRealPath)
    -- Detect symlink cycles
    local realPath
    if resolvedRealPath ~= "" then
        realPath = resolvedRealPath
    else
        realPath = self.host:Realpath(absolutePath)
    end
    local canonicalPath = tspath.GetCanonicalFileName(realPath, self.useCaseSensitiveFileNames)
    if self.visited[canonicalPath] then
        return
    end
    self.visited[canonicalPath] = true

    local entries = self.host:GetAccessibleEntries(absolutePath)

    local pathPrefix = vfsmatch.ensureTrailingSlash(path)
    local absPrefix = vfsmatch.ensureTrailingSlash(absolutePath)

    for _, file in ipairs(entries.files or {}) do
        if core.Len(self.extensions) > 0 and not tspath.FileExtensionIsOneOf(file, self.extensions) then
            goto continue
        end
        do
            local idx, ok = self.fileMatcher:matchesFileParts(absPrefix, file)
            if ok then
                local bucket = self.results[idx + 1]
                bucket[#bucket + 1] = pathPrefix .. file
            end
        end
        ::continue::
    end

    if depth ~= vfsmatch.UnlimitedDepth then
        depth = depth - 1
        if depth == 0 then
            return
        end
    end

    for _, dir in ipairs(entries.directories or {}) do
        if not self.directoryMatcher:matchesDirectoryParts(absPrefix, dir) then
            goto continue
        end
        do
            local absDir = absPrefix .. dir
            local childRealPath = ""
            if entries.symlinks ~= nil then
                if not entries.symlinks[dir] then
                    -- Non-symlink directory: compute realpath incrementally.
                    childRealPath = tspath.CombinePaths(realPath, dir)
                end
                -- else: symlink directory; leave childRealPath empty to force Realpath call.
            end
            -- If Symlinks is nil, the FS doesn't track symlinks;
            -- leave childRealPath empty to call Realpath (preserving old behavior).
            self:visit(pathPrefix .. dir, absDir, depth, childRealPath)
        end
        ::continue::
    end
end

function vfsmatch.matchFiles(path, extensions, excludes, includes, useCaseSensitiveFileNames, currentDirectory, depth, host)
    path = tspath.NormalizePath(path)
    currentDirectory = tspath.NormalizePath(currentDirectory)
    local absolutePath = tspath.CombinePaths(currentDirectory, path)

    local fileMatcher = vfsmatch.newGlobMatcher(includes, excludes, absolutePath, useCaseSensitiveFileNames, Usage.Files)
    local directoryMatcher = vfsmatch.newGlobMatcher(includes, excludes, absolutePath, useCaseSensitiveFileNames, Usage.Directories)

    local results = {}
    for i = 1, math.max(#fileMatcher.includes, 1) do
        results[i] = {}
    end
    local v = setmetatable({
        host = host,
        fileMatcher = fileMatcher,
        directoryMatcher = directoryMatcher,
        extensions = extensions,
        useCaseSensitiveFileNames = useCaseSensitiveFileNames,
        visited = {}, -- collections.Set[string]
        results = results,
    }, globVisitor)

    for _, basePath in ipairs(vfsmatch.getBasePaths(path, includes, useCaseSensitiveFileNames)) do
        v:visit(basePath, tspath.CombinePaths(currentDirectory, basePath), depth, "")
    end

    -- Fast path: a single include bucket (or no includes) doesn't need flattening.
    if #v.results == 1 then
        return v.results[1]
    end
    return core.Flatten(v.results)
end

-- SpecMatcher wraps multiple glob patterns for matching paths.
local SpecMatcher = {}
SpecMatcher.__index = SpecMatcher
vfsmatch.SpecMatcher = SpecMatcher

-- MatchString returns true if any pattern matches the path.
function SpecMatcher:MatchString(path)
    for i = 1, #self.patterns do
        if self.patterns[i]:matches(path) then
            return true
        end
    end
    return false
end

-- MatchIndex returns the index of the first matching pattern, or -1.
function SpecMatcher:MatchIndex(path)
    for i = 1, #self.patterns do
        if self.patterns[i]:matches(path) then
            return i - 1
        end
    end
    return -1
end

-- NewSpecMatcher creates a matcher for one or more glob specs.
-- It returns a matcher that can test if paths match any of the patterns.
function vfsmatch.NewSpecMatcher(specs, basePath, usage, useCaseSensitiveFileNames)
    if core.Len(specs) == 0 then
        return nil
    end
    local patterns = {}
    for _, spec in ipairs(specs) do
        local p, ok = vfsmatch.compileGlobPattern(spec, basePath, usage, useCaseSensitiveFileNames)
        if ok then
            patterns[#patterns + 1] = p
        end
    end
    if #patterns == 0 then
        return nil
    end
    return setmetatable({ patterns = patterns }, SpecMatcher)
end

return vfsmatch
