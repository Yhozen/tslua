local tsbaseline = require("tslua.testutil.tsbaseline")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

-- The Go regexps of this package are ported as small hand-written matchers with the same
-- methods (Split(s, -1), ReplaceAllString(s, repl), MatchString(s)) and RE2 semantics
-- (leftmost-first alternation, greedy quantifiers, \s = [\t\n\f\r ], \S matches one rune).

local function isRE2Space(b)
    return b == 32 or b == 9 or b == 10 or b == 12 or b == 13
end
tsbaseline.isRE2Space = isRE2Space

-- splitByMatcher splits s at the matches of next(s, i) -> (start, end) (1-based, inclusive
-- start, exclusive end) or nil; like Go regexp.Split(s, -1) for a regexp that never matches "".
local function splitByMatcher(s, nextMatch)
    if s == "" then
        return { "" }
    end
    local parts = {}
    local beg = 1
    local i = 1
    while true do
        local ms, me = nextMatch(s, i)
        if ms == nil then
            break
        end
        parts[#parts + 1] = string.sub(s, beg, ms - 1)
        beg = me
        i = me
    end
    parts[#parts + 1] = string.sub(s, beg)
    return parts
end
tsbaseline.splitByMatcher = splitByMatcher

-- lineDelimiter = regexp.MustCompile("\r?\n")
tsbaseline.lineDelimiter = {
    nextMatch = function(s, i)
        local j = string.find(s, "\n", i, true)
        if j == nil then
            return nil
        end
        if j > i and string.byte(s, j - 1) == 13 then
            return j - 1, j + 1
        end
        return j, j + 1
    end,
    Split = function(self, s)
        return splitByMatcher(s, self.nextMatch)
    end,
    ReplaceAllString = function(self, s, repl)
        return (string.gsub(string.gsub(s, "\r\n", "\n"), "\n", repl))
    end,
}

-- nonWhitespace = regexp.MustCompile(`\S`)
tsbaseline.nonWhitespace = {
    ReplaceAllString = function(self, s, repl)
        -- Each non-space rune (a UTF-8 sequence, or an invalid byte) is replaced as a whole.
        local out = {}
        local pos = 0
        local n = #s
        while pos < n do
            local b = string.byte(s, pos + 1)
            if isRE2Space(b) then
                out[#out + 1] = string.char(b)
                pos = pos + 1
            else
                local _, size = core.DecodeRune(s, pos)
                out[#out + 1] = repl
                pos = pos + size
            end
        end
        return table.concat(out)
    end,
}

-- tsExtension = regexp.MustCompile(`\.tsx?$`)
tsbaseline.tsExtension = {
    ReplaceAllString = function(self, s, repl)
        if string.sub(s, -3) == ".ts" then
            return string.sub(s, 1, -4) .. repl
        elseif string.sub(s, -4) == ".tsx" then
            return string.sub(s, 1, -5) .. repl
        end
        return s
    end,
    MatchString = function(self, s)
        return string.sub(s, -3) == ".ts" or string.sub(s, -4) == ".tsx"
    end,
}

-- testPathCharacters = regexp.MustCompile(`[\^<>:"|?*%]`)
tsbaseline.testPathCharacters = {
    ReplaceAllString = function(self, s, repl)
        return (string.gsub(s, "[%^<>:\"|?*%%]", repl))
    end,
}

-- testPathDotDot = regexp.MustCompile(`\.\.\/`)
tsbaseline.testPathDotDot = {
    ReplaceAllString = function(self, s, repl)
        return (string.gsub(s, "%.%./", repl))
    end,
}

tsbaseline.libFolder = "built/local/"
tsbaseline.builtFolder = "/.ts"

-- strings.NewReplacer(old1, new1, old2, new2, ...): replacements are performed in the order they
-- appear in the target string, without overlapping matches, and comparisons are done in argument
-- order.
local Replacer = {}
Replacer.__index = Replacer
tsbaseline.Replacer = Replacer

function tsbaseline.NewReplacer(...)
    local args = { ... }
    local pairsList = {}
    for i = 1, #args, 2 do
        pairsList[#pairsList + 1] = { old = args[i], new = args[i + 1] }
    end
    return setmetatable({ pairs = pairsList }, Replacer)
end

function Replacer:Replace(s)
    local out = {}
    local pos = 1
    local n = #s
    -- next occurrence of each old string at or after pos (cached)
    local nextAt = {}
    for k, p in ipairs(self.pairs) do
        nextAt[k] = string.find(s, p.old, 1, true) or math.huge
    end
    while pos <= n do
        local best = math.huge
        for k, p in ipairs(self.pairs) do
            if nextAt[k] < pos then
                nextAt[k] = string.find(s, p.old, pos, true) or math.huge
            end
            if nextAt[k] < best then
                best = nextAt[k]
            end
        end
        if best == math.huge then
            break
        end
        -- first pair in argument order that matches at best
        local chosen = nil
        for k, p in ipairs(self.pairs) do
            if nextAt[k] == best then
                chosen = p
                break
            end
        end
        out[#out + 1] = string.sub(s, pos, best - 1)
        out[#out + 1] = chosen.new
        pos = best + #chosen.old
    end
    out[#out + 1] = string.sub(s, pos)
    return table.concat(out)
end

tsbaseline.testPathPrefixReplacer = tsbaseline.NewReplacer(
    "/.ts/", "",
    "/.lib/", "",
    "/.src/", "",
    "bundled:///libs/", "",
    "file:///./ts/", "file:///",
    "file:///./lib/", "file:///",
    "file:///./src/", "file:///"
)
tsbaseline.testPathTrailingReplacerTrailingSeparator = tsbaseline.NewReplacer(
    "/.ts/", "/",
    "/.lib/", "/",
    "/.src/", "/",
    "bundled:///libs/", "/",
    "file:///./ts/", "file:///",
    "file:///./lib/", "file:///",
    "file:///./src/", "file:///"
)

function tsbaseline.removeTestPathPrefixes(text, retainTrailingDirectorySeparator)
    if retainTrailingDirectorySeparator then
        return tsbaseline.testPathTrailingReplacerTrailingSeparator:Replace(text)
    end
    return tsbaseline.testPathPrefixReplacer:Replace(text)
end

function tsbaseline.isDefaultLibraryFile(filePath)
    local fileName = tspath.GetBaseFileName(filePath)
    return string.sub(fileName, 1, 4) == "lib." and string.sub(fileName, -#tspath.ExtensionDts) == tspath.ExtensionDts
end

function tsbaseline.isBuiltFile(filePath)
    local builtPrefix = tspath.EnsureTrailingDirectorySeparator(tsbaseline.builtFolder)
    return string.sub(filePath, 1, #tsbaseline.libFolder) == tsbaseline.libFolder or string.sub(filePath, 1, #builtPrefix) == builtPrefix
end

function tsbaseline.isTsConfigFile(path)
    -- !!! fix to check for just prefixes/suffixes
    return string.find(path, "tsconfig", 1, true) ~= nil and string.find(path, "json", 1, true) ~= nil
end

function tsbaseline.sanitizeTestFilePath(name)
    local path = tsbaseline.testPathCharacters:ReplaceAllString(name, "_")
    path = tspath.NormalizeSlashes(path)
    path = tsbaseline.testPathDotDot:ReplaceAllString(path, "__dotdot/")
    path = tspath.ToPath(path, "", false --[[useCaseSensitiveFileNames]])
    if string.sub(path, 1, 1) == "/" then
        path = string.sub(path, 2)
    end
    return path
end

return tsbaseline
