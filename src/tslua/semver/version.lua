local semver = require("tslua.semver")

-- The Go regular expressions of this file are implemented by hand-written matchers below
-- (Go RE2 semantics: (?i), ASCII \d).

-- https://semver.org/#spec-item-2
-- > A normal version number MUST take the form X.Y.Z where X, Y, and Z are non-negative
-- > integers, and MUST NOT contain leading zeroes. X is the major version, Y is the minor
-- > version, and Z is the patch version. Each element MUST increase numerically.
--
-- NOTE: We differ here in that we allow X and X.Y, with missing parts having the default
-- value of `0`.
--
-- versionRegexp: (?i)^(0|[1-9]\d*)(?:\.(0|[1-9]\d*)(?:\.(0|[1-9]\d*)(?:-([a-z0-9-.]+))?(?:\+([a-z0-9-.]+))?)?)?$
-- partialRegExp (version_range.go) is the same with [x*0] instead of 0 (allowWildcard).
-- Returns the 5 submatches ("" when absent) or nil.
function semver.matchVersionLike(text, allowWildcard)
    local pos = 1
    local n = #text
    local function readNumber()
        local c = string.sub(text, pos, pos)
        if allowWildcard and (c == "x" or c == "X" or c == "*" or c == "0") then
            pos = pos + 1
            return c
        elseif not allowWildcard and c == "0" then
            pos = pos + 1
            return c
        end
        local s, e = string.find(text, "^[1-9]%d*", pos)
        if s == nil then
            return nil
        end
        pos = e + 1
        return string.sub(text, s, e)
    end
    local m = { "", "", "", "", "" }
    m[1] = readNumber()
    if m[1] == nil then
        return nil
    end
    if pos > n then
        return m
    end
    if string.sub(text, pos, pos) ~= "." then
        return nil
    end
    pos = pos + 1
    m[2] = readNumber()
    if m[2] == nil then
        return nil
    end
    if pos > n then
        return m
    end
    if string.sub(text, pos, pos) ~= "." then
        return nil
    end
    pos = pos + 1
    m[3] = readNumber()
    if m[3] == nil then
        return nil
    end
    if string.sub(text, pos, pos) == "-" then
        local s, e = string.find(text, "^[%w%-%.]+", pos + 1)
        if s ~= nil then
            m[4] = string.sub(text, s, e)
            pos = e + 1
        end
    end
    if string.sub(text, pos, pos) == "+" then
        local s, e = string.find(text, "^[%w%-%.]+", pos + 1)
        if s ~= nil then
            m[5] = string.sub(text, s, e)
            pos = e + 1
        end
    end
    if pos <= n then
        return nil
    end
    return m
end

local function splitDots(s)
    local parts = {}
    local start = 1
    while true do
        local i = string.find(s, ".", start, true)
        if i == nil then
            parts[#parts + 1] = string.sub(s, start)
            return parts
        end
        parts[#parts + 1] = string.sub(s, start, i - 1)
        start = i + 1
    end
end
semver.splitDots = splitDots

-- https://semver.org/#spec-item-9
-- > A pre-release version MAY be denoted by appending a hyphen and a series of dot separated
-- > identifiers immediately following the patch version. Identifiers MUST comprise only ASCII
-- > alphanumerics and hyphen [0-9A-Za-z-]. Identifiers MUST NOT be empty. Numeric identifiers
-- > MUST NOT include leading zeroes.
-- prereleaseRegexp: (?i)^(?:0|[1-9]\d*|[a-z-][a-z0-9-]*)(?:\.(?:0|[1-9]\d*|[a-zA-Z-][a-zA-Z0-9-]*))*$
function semver.prereleasePartMatch(part)
    return part == "0" or string.find(part, "^[1-9]%d*$") ~= nil or string.find(part, "^[%a%-][%w%-]*$") ~= nil
end

function semver.prereleaseMatch(s)
    for _, part in ipairs(splitDots(s)) do
        if not semver.prereleasePartMatch(part) then
            return false
        end
    end
    return true
end

-- https://semver.org/#spec-item-10
-- > Build metadata MAY be denoted by appending a plus sign and a series of dot separated
-- > identifiers immediately following the patch or pre-release version. Identifiers MUST
-- > comprise only ASCII alphanumerics and hyphen [0-9A-Za-z-]. Identifiers MUST NOT be empty.
-- buildRegExp: (?i)^[a-z0-9-]+(?:\.[a-z0-9-]+)*$
function semver.buildPartMatch(part)
    return string.find(part, "^[%w%-]+$") ~= nil
end

function semver.buildMatch(s)
    for _, part in ipairs(splitDots(s)) do
        if not semver.buildPartMatch(part) then
            return false
        end
    end
    return true
end

-- https://semver.org/#spec-item-9
-- > Numeric identifiers MUST NOT include leading zeroes.
-- numericIdentifierRegExp: ^(?:0|[1-9]\d*)$
function semver.numericIdentifierMatch(s)
    return s == "0" or string.find(s, "^[1-9]%d*$") ~= nil
end

-- Version: { major = int, minor = int, patch = int, prerelease = nil|array, build = nil|array }
local Version = {}
Version.__index = Version
semver.Version = Version

function semver.NewVersion(init)
    local v = setmetatable({ major = 0, minor = 0, patch = 0, prerelease = nil, build = nil }, Version)
    if init ~= nil then
        for k, val in pairs(init) do
            v[k] = val
        end
    end
    return v
end

semver.versionZero = semver.NewVersion({ prerelease = { "0" } })

-- Go copies Version values on assignment; ported code that mutates a copy uses this.
function Version:copy()
    return semver.NewVersion({ major = self.major, minor = self.minor, patch = self.patch, prerelease = self.prerelease, build = self.build })
end

local function u32(x)
    return x & 0xFFFFFFFF
end

function Version:incrementMajor()
    return semver.NewVersion({ major = u32(self.major + 1) })
end

function Version:incrementMinor()
    return semver.NewVersion({ major = self.major, minor = u32(self.minor + 1) })
end

function Version:incrementPatch()
    return semver.NewVersion({ major = self.major, minor = self.minor, patch = u32(self.patch + 1) })
end

semver.comparisonLessThan = -1
semver.comparisonEqualTo = 0
semver.comparisonGreaterThan = 1

local function compareInts(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- Callable on nil receivers as semver.Version.Compare(a, b).
function Version.Compare(a, b)
    -- https://semver.org/#spec-item-11
    -- > Precedence is determined by the first difference when comparing each of these
    -- > identifiers from left to right as follows: Major, minor, and patch versions are
    -- > always compared numerically.
    --
    -- https://semver.org/#spec-item-11
    -- > Precedence for two pre-release versions with the same major, minor, and patch version
    -- > MUST be determined by comparing each dot separated identifier from left to right until
    -- > a difference is found [...]
    --
    -- https://semver.org/#spec-item-11
    -- > Build metadata does not figure into precedence
    if a == b then
        return semver.comparisonEqualTo
    elseif a == nil then
        return semver.comparisonLessThan
    elseif b == nil then
        return semver.comparisonGreaterThan
    end

    local r = compareInts(a.major, b.major)
    if r ~= 0 then
        return r
    end

    r = compareInts(a.minor, b.minor)
    if r ~= 0 then
        return r
    end

    r = compareInts(a.patch, b.patch)
    if r ~= 0 then
        return r
    end

    return semver.comparePreReleaseIdentifiers(a.prerelease, b.prerelease)
end

function semver.comparePreReleaseIdentifiers(left, right)
    -- https://semver.org/#spec-item-11
    -- > When major, minor, and patch are equal, a pre-release version has lower precedence
    -- > than a normal version.
    local nl, nr = left and #left or 0, right and #right or 0
    if nl == 0 then
        if nr == 0 then
            return semver.comparisonEqualTo
        end
        return semver.comparisonGreaterThan
    elseif nr == 0 then
        return semver.comparisonLessThan
    end

    -- https://semver.org/#spec-item-11
    -- > Precedence for two pre-release versions with the same major, minor, and patch version
    -- > MUST be determined by comparing each dot separated identifier from left to right until
    -- > a difference is found [...]
    -- slices.CompareFunc
    for i = 1, math.min(nl, nr) do
        local c = semver.comparePreReleaseIdentifier(left[i], right[i])
        if c ~= 0 then
            return c
        end
    end
    return compareInts(nl, nr)
end

function semver.comparePreReleaseIdentifier(left, right)
    -- https://semver.org/#spec-item-11
    -- > Precedence for two pre-release versions with the same major, minor, and patch version
    -- > MUST be determined by comparing each dot separated identifier from left to right until
    -- > a difference is found [...]
    local compareResult = 0
    if left < right then
        compareResult = -1
    elseif left > right then
        compareResult = 1
    end
    if compareResult == 0 then
        return compareResult
    end

    local leftIsNumeric = semver.numericIdentifierMatch(left)
    local rightIsNumeric = semver.numericIdentifierMatch(right)

    if leftIsNumeric or rightIsNumeric then
        -- https://semver.org/#spec-item-11
        -- > Numeric identifiers always have lower precedence than non-numeric identifiers.
        if not rightIsNumeric then
            return semver.comparisonLessThan
        end
        if not leftIsNumeric then
            return semver.comparisonGreaterThan
        end

        -- https://semver.org/#spec-item-11
        -- > identifiers consisting of only digits are compared numerically
        local leftAsNumber, leftErr = semver.getUintComponent(left)
        local rightAsNumber, rightErr = semver.getUintComponent(right)
        if leftErr ~= nil or rightErr ~= nil then
            -- This should only happen in the event of an overflow.
            -- If so, use the lengths or fall back to string comparison.
            local lenCompare = compareInts(#left, #right)
            if lenCompare == 0 then
                return compareResult
            else
                return lenCompare
            end
        end
        return compareInts(leftAsNumber, rightAsNumber)
    end

    -- https://semver.org/#spec-item-11
    -- > identifiers with letters or hyphens are compared lexically in ASCII sort order.
    return compareResult
end

function Version:String()
    local parts = { string.format("%d.%d.%d", self.major, self.minor, self.patch) }
    if self.prerelease ~= nil and #self.prerelease > 0 then
        parts[#parts + 1] = "-" .. table.concat(self.prerelease, ".")
    end
    if self.build ~= nil and #self.build > 0 then
        parts[#parts + 1] = "+" .. table.concat(self.build, ".")
    end
    return table.concat(parts)
end

Version.__tostring = Version.String

-- Go %q (for the ASCII/UTF-8 inputs version strings carry).
function semver.goQuote(s)
    local esc = { ['"'] = '\\"', ["\\"] = "\\\\", ["\a"] = "\\a", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\v"] = "\\v" }
    return '"' .. string.gsub(s, '[%c"\\\127]', function(c)
        return esc[c] or string.format("\\x%02x", string.byte(c))
    end) .. '"'
end

local SemverParseError = {}
SemverParseError.__index = SemverParseError
semver.SemverParseError = SemverParseError

function SemverParseError:Error()
    return "Could not parse version string from " .. semver.goQuote(self.origInput)
end

SemverParseError.__tostring = SemverParseError.Error

local function newParseError(text)
    return setmetatable({ origInput = text }, SemverParseError)
end

-- Returns (Version, err).
function semver.TryParseVersion(text)
    local result = semver.NewVersion()

    local match = semver.matchVersionLike(text, false)
    if match == nil then
        return result, newParseError(text)
    end

    local majorStr = match[1]
    local minorStr = match[2]
    local patchStr = match[3]
    local prereleaseStr = match[4]
    local buildStr = match[5]

    local err

    result.major, err = semver.getUintComponent(majorStr)
    if err ~= nil then
        return result, err
    end

    if minorStr ~= "" then
        result.minor, err = semver.getUintComponent(minorStr)
        if err ~= nil then
            return result, err
        end
    end

    if patchStr ~= "" then
        result.patch, err = semver.getUintComponent(patchStr)
        if err ~= nil then
            return result, err
        end
    end

    if prereleaseStr ~= "" then
        if not semver.prereleaseMatch(prereleaseStr) then
            return result, newParseError(text)
        end

        result.prerelease = splitDots(prereleaseStr)
    end
    if buildStr ~= "" then
        if not semver.buildMatch(buildStr) then
            return result, newParseError(text)
        end

        result.build = splitDots(buildStr)
    end

    return result, nil
end

function semver.MustParse(text)
    local v, err = semver.TryParseVersion(text)
    if err ~= nil then
        error(err, 0)
    end
    return v
end

-- strconv.ParseUint(text, 10, 32). Returns (uint32, err); on overflow the value is the max uint32.
function semver.getUintComponent(text)
    local ok = string.find(text, "^%d+$") ~= nil
    if not ok then
        return 0, 'strconv.ParseUint: parsing ' .. semver.goQuote(text) .. ': invalid syntax'
    end
    local stripped = string.gsub(text, "^0+", "")
    if #stripped > 10 or (#stripped == 10 and stripped > "4294967295") then
        return 0xFFFFFFFF, 'strconv.ParseUint: parsing ' .. semver.goQuote(text) .. ': value out of range'
    end
    return tonumber(text) // 1, nil
end
