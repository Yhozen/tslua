local core = require("tslua.core")

-- Pattern: { text = string, starIndex = int } (starIndex is a 0-based byte offset, -1 for exact match)
local Pattern = {}
Pattern.__index = Pattern
core.Pattern = Pattern

function core.NewPattern(text, starIndex)
    return setmetatable({ text = text or "", starIndex = starIndex or 0 }, Pattern)
end

function core.TryParsePattern(pattern)
    local s = string.find(pattern, "*", 1, true)
    local starIndex = s and (s - 1) or -1
    if starIndex == -1 or not string.find(pattern, "*", starIndex + 2, true) then
        return core.NewPattern(pattern, starIndex)
    end
    return core.NewPattern("", 0)
end

function Pattern:IsValid()
    return self.starIndex == -1 or self.starIndex < #self.text
end

function Pattern:Matches(candidate)
    if self.starIndex == -1 then
        return self.text == candidate
    end
    local prefix = string.sub(self.text, 1, self.starIndex)
    local suffix = string.sub(self.text, self.starIndex + 2)
    return #candidate >= #self.text - 1 and
        string.sub(candidate, 1, #prefix) == prefix and
        (suffix == "" or string.sub(candidate, -#suffix) == suffix)
end

function Pattern:MatchedText(candidate)
    if not self:Matches(candidate) then
        error("candidate does not match pattern", 0)
    end
    if self.starIndex == -1 then
        return ""
    end
    return string.sub(candidate, self.starIndex + 1, #candidate - #self.text + self.starIndex + 1)
end

function core.FindBestPatternMatch(values, getPattern, candidate)
    local bestPattern = nil
    local longestMatchPrefixLength = -1
    if values == nil then
        return nil
    end
    for _, value in ipairs(values) do
        local pattern = getPattern(value)
        if (pattern.starIndex == -1 or pattern.starIndex > longestMatchPrefixLength) and pattern:Matches(candidate) then
            bestPattern = value
            longestMatchPrefixLength = pattern.starIndex
        end
    end
    if bestPattern == nil then
        return core.zeroLike(values[1])
    end
    return bestPattern
end
