local autoimport = require("tslua.ls.autoimport")
local stringutil = require("tslua.stringutil")

local RuneError = 0xFFFD

-- Named is a constraint for types that can provide their name (entries have a Name() method).

-- Index stores entries with an index mapping uppercase letters to entries whose name
-- starts with that letter, and lowercase letters to entries whose name contains a
-- word starting with that letter.
-- Fields: entries (array of T), index (map rune -> array of 0-based entry indices).
local Index = {}
Index.__index = Index
autoimport.Index = Index

-- Go `&Index[T]{}`.
function autoimport.NewIndex()
    return setmetatable({ entries = nil, index = nil }, Index)
end

local function len(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

function Index:Find(name, caseSensitive)
    if len(self.entries) == 0 or #name == 0 then
        return nil
    end
    local firstRune = stringutil.DecodeRune(name, 0)
    if firstRune == RuneError then
        return nil
    end
    local firstRuneUpper = stringutil.UnicodeToUpper(firstRune)
    local candidates = self.index[firstRuneUpper]
    if candidates == nil then
        return nil
    end

    local results = nil
    for _, entryIndex in ipairs(candidates) do
        local entry = self.entries[entryIndex + 1]
        local entryName = entry:Name()
        if (caseSensitive and entryName == name) or (not caseSensitive and stringutil.EqualFold(entryName, name)) then
            results = results or {}
            results[#results + 1] = entry
        end
    end

    return results
end

-- SearchWordPrefix returns each entry whose name contains a word beginning with
-- the first character of 'prefix', and whose name contains all characters
-- of 'prefix' in order (case-insensitive). If 'filter' is provided, only entries
-- for which filter(entry) returns true are included.
function Index:SearchWordPrefix(prefix)
    if len(self.entries) == 0 then
        return nil
    end

    if #prefix == 0 then
        return self.entries
    end

    prefix = stringutil.StringsToLower(prefix)
    local firstRune = stringutil.DecodeRune(prefix, 0)
    if firstRune == RuneError then
        return nil
    end

    local firstRuneUpper = stringutil.UnicodeToUpper(firstRune)
    local firstRuneLower = stringutil.UnicodeToLower(firstRune)

    -- Look up entries that have words starting with this letter
    local wordStarts = nil
    local nameStarts = self.index[firstRuneUpper]
    if firstRuneUpper ~= firstRuneLower then
        wordStarts = self.index[firstRuneLower]
    end
    local count = len(nameStarts) + len(wordStarts)
    if count == 0 then
        return nil
    end

    -- Filter entries by checking if they contain all characters in order
    local results = {}
    for _, starts in ipairs({ nameStarts or {}, wordStarts or {} }) do
        for _, i in ipairs(starts) do
            local entry = self.entries[i + 1]
            if autoimport.containsCharsInOrder(entry:Name(), prefix) then
                results[#results + 1] = entry
            end
        end
    end
    return results
end

-- containsCharsInOrder checks if str contains all characters from pattern in order (case-insensitive).
function autoimport.containsCharsInOrder(str, pattern)
    str = stringutil.StringsToLower(str)
    pattern = stringutil.StringsToLower(pattern)

    local patternIdx = 0
    local pos = 0
    local n = #str
    while pos < n do
        local ch, chSize = stringutil.DecodeRune(str, pos)
        pos = pos + chSize
        if patternIdx < #pattern then
            local patternRune, size = stringutil.DecodeRune(pattern, patternIdx)
            if ch == patternRune then
                patternIdx = patternIdx + size
            end
        end
    end
    return patternIdx == #pattern
end

-- insertAsWords adds a value to the index keyed by the first letter of each word in its name.
function Index:insertAsWords(value)
    if self.index == nil then
        self.index = {}
    end

    local name = value:Name()
    if #name == 0 then
        error("Cannot index entry with empty name", 0)
    end
    if self.entries == nil then
        self.entries = {}
    end
    local entryIndex = #self.entries
    self.entries[entryIndex + 1] = value

    local indices = autoimport.wordIndices(name)
    local seenRunes = {}

    for i1, start in ipairs(indices) do
        local i = i1 - 1
        local firstRune = stringutil.DecodeRune(name, start)
        if firstRune ~= RuneError then
            if i == 0 then
                -- Name start keyed by uppercase
                firstRune = stringutil.UnicodeToUpper(firstRune)
                local list = self.index[firstRune]
                if list == nil then
                    list = {}
                    self.index[firstRune] = list
                end
                list[#list + 1] = entryIndex
                seenRunes[firstRune] = true -- (Still set seenRunes in case first character is non-alphabetic)
            else
                -- Subsequent word starts keyed by lowercase
                firstRune = stringutil.UnicodeToLower(firstRune)
                if not seenRunes[firstRune] then
                    local list = self.index[firstRune]
                    if list == nil then
                        list = {}
                        self.index[firstRune] = list
                    end
                    list[#list + 1] = entryIndex
                    seenRunes[firstRune] = true
                end
            end
        end
    end
end

-- Clone creates a new Index containing only entries for which filter returns true.
-- Callable as autoimport.Index.Clone(idx, filter) when idx may be nil.
function Index:Clone(filter)
    if self == nil then
        return nil
    end

    local newIdx = setmetatable({
        entries = {},
        index = {},
    }, Index)

    -- Build mapping from old index to new index for filtered entries
    local oldToNew = {}
    for oldIndex1, entry in ipairs(self.entries or {}) do
        if filter(entry) then
            local newIndex = #newIdx.entries
            newIdx.entries[newIndex + 1] = entry
            oldToNew[oldIndex1 - 1] = newIndex
        end
    end

    -- Rebuild the index with remapped indices
    for r, oldIndices in pairs(self.index or {}) do
        local newIndices = {}
        for _, oldIndex in ipairs(oldIndices) do
            local newIndex = oldToNew[oldIndex]
            if newIndex ~= nil then
                newIndices[#newIndices + 1] = newIndex
            end
        end
        if #newIndices > 0 then
            newIdx.index[r] = newIndices
        end
    end

    return newIdx
end
