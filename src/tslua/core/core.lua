local core = require("tslua.core")
local debug = require("tslua.debug")
local json = require("tslua.json")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local ScriptKind = core.ScriptKind

function core.ApplyDebugStackLimit()
end

function core.Filter(slice, f)
    if slice == nil then
        return nil
    end
    local n = #slice
    for i = 1, n do
        local value = slice[i]
        if not f(value) then
            local result = {}
            for k = 1, i - 1 do
                result[k] = slice[k]
            end
            local m = i - 1
            for j = i + 1, n do
                value = slice[j]
                if f(value) then
                    m = m + 1
                    result[m] = value
                end
            end
            return result
        end
    end
    return slice
end

-- Returns a Lua iterator.
function core.FilterSeq(slice, f)
    local i = 0
    local n = core.Len(slice)
    return function()
        while i < n do
            i = i + 1
            local value = slice[i]
            if f(value) then
                return value
            end
        end
        return nil
    end
end

-- f receives (value, 0-based index, slice).
function core.FilterIndex(slice, f)
    if slice == nil then
        return nil
    end
    local n = #slice
    for i = 1, n do
        local value = slice[i]
        if not f(value, i - 1, slice) then
            local result = {}
            for k = 1, i - 1 do
                result[k] = slice[k]
            end
            local m = i - 1
            for j = i + 1, n do
                value = slice[j]
                if f(value, j - 1, slice) then
                    m = m + 1
                    result[m] = value
                end
            end
            return result
        end
    end
    return slice
end

function core.Map(slice, f)
    if slice == nil then
        return nil
    end
    local result = {}
    for i = 1, #slice do
        result[i] = f(slice[i])
    end
    return result
end

-- f returns (value, err). Returns (result, err).
function core.TryMap(slice, f)
    if slice == nil or #slice == 0 then
        return nil, nil
    end
    local result = {}
    for i = 1, #slice do
        local mapped, err = f(slice[i])
        if err ~= nil then
            return nil, err
        end
        result[i] = mapped
    end
    return result, nil
end

-- f receives (value, 0-based index).
function core.MapIndex(slice, f)
    if slice == nil then
        return nil
    end
    local result = {}
    for i = 1, #slice do
        result[i] = f(slice[i], i - 1)
    end
    return result
end

function core.MapNonNil(slice, f)
    local result = nil
    if slice == nil then
        return result
    end
    for i = 1, #slice do
        local mapped = f(slice[i])
        if not core.IsZero(mapped) then
            if result == nil then
                result = {}
            end
            result[#result + 1] = mapped
        end
    end
    return result
end

-- f returns (value, ok).
function core.MapFiltered(slice, f)
    local result = nil
    if slice == nil then
        return result
    end
    for i = 1, #slice do
        local mapped, ok = f(slice[i])
        if ok then
            if result == nil then
                result = {}
            end
            result[#result + 1] = mapped
        end
    end
    return result
end

function core.FlatMap(slice, f)
    local result = nil
    if slice == nil then
        return result
    end
    for i = 1, #slice do
        local mapped = f(slice[i])
        if mapped ~= nil and #mapped ~= 0 then
            if result == nil then
                result = {}
            end
            local n = #result
            for j = 1, #mapped do
                result[n + j] = mapped[j]
            end
        end
    end
    return result
end

function core.SameMap(slice, f)
    if slice == nil then
        return nil
    end
    local n = #slice
    for i = 1, n do
        local value = slice[i]
        local mapped = f(value)
        if mapped ~= value then
            local result = {}
            for k = 1, i - 1 do
                result[k] = slice[k]
            end
            result[i] = mapped
            for j = i + 1, n do
                result[j] = f(slice[j])
            end
            return result
        end
    end
    return slice
end

-- f receives (value, 0-based index).
function core.SameMapIndex(slice, f)
    if slice == nil then
        return nil
    end
    local n = #slice
    for i = 1, n do
        local value = slice[i]
        local mapped = f(value, i - 1)
        if mapped ~= value then
            local result = {}
            for k = 1, i - 1 do
                result[k] = slice[k]
            end
            result[i] = mapped
            for j = i + 1, n do
                result[j] = f(slice[j], j - 1)
            end
            return result
        end
    end
    return slice
end

-- Go compares the address of the first element; in Lua slices are tables, so identity is used.
function core.Same(s1, s2)
    local n1, n2 = core.Len(s1), core.Len(s2)
    if n1 == n2 then
        return n1 == 0 or s1 == s2
    end
    return false
end

function core.Some(slice, f)
    if slice == nil then
        return false
    end
    for i = 1, #slice do
        if f(slice[i]) then
            return true
        end
    end
    return false
end

function core.Every(slice, f)
    if slice == nil then
        return true
    end
    for i = 1, #slice do
        if not f(slice[i]) then
            return false
        end
    end
    return true
end

function core.Or(...)
    local funcs = { ... }
    return function(input)
        for _, f in ipairs(funcs) do
            if f(input) then
                return true
            end
        end
        return false
    end
end

function core.Find(slice, f)
    if slice == nil then
        return nil
    end
    for i = 1, #slice do
        local value = slice[i]
        if f(value) then
            return value
        end
    end
    return core.zeroLike(slice[1])
end

function core.FindLast(slice, f)
    if slice == nil then
        return nil
    end
    for i = #slice, 1, -1 do
        local value = slice[i]
        if f(value) then
            return value
        end
    end
    return core.zeroLike(slice[1])
end

-- Returns a 0-based index or -1.
function core.FindIndex(slice, f)
    if slice == nil then
        return -1
    end
    for i = 1, #slice do
        if f(slice[i]) then
            return i - 1
        end
    end
    return -1
end

-- Returns a 0-based index or -1.
function core.FindLastIndex(slice, f)
    if slice == nil then
        return -1
    end
    for i = #slice, 1, -1 do
        if f(slice[i]) then
            return i - 1
        end
    end
    return -1
end

function core.FirstOrNil(slice)
    if slice ~= nil and #slice ~= 0 then
        return slice[1]
    end
    return nil
end

function core.LastOrNil(slice)
    if slice ~= nil and #slice ~= 0 then
        return slice[#slice]
    end
    return nil
end

-- index is 0-based.
function core.ElementOrNil(slice, index)
    if index < core.Len(slice) then
        return slice[index + 1]
    end
    return core.zeroLike(slice and slice[1])
end

-- seq is an array (iter.Seq parameter).
function core.FirstOrNilSeq(seq)
    if seq ~= nil then
        return seq[1]
    end
    return nil
end

function core.FirstNonNil(slice, f)
    if slice == nil then
        return nil
    end
    local zero = nil
    for i = 1, #slice do
        local mapped = f(slice[i])
        if not core.IsZero(mapped) then
            return mapped
        end
        zero = mapped
    end
    return zero
end

-- Returns the first argument that is not a Go zero value (nil, false, 0, ""); otherwise the
-- zero value of the last argument's kind (or nil).
function core.FirstNonZero(...)
    local n = select("#", ...)
    local last = nil
    for i = 1, n do
        local value = select(i, ...)
        if not core.IsZero(value) then
            return value
        end
        if value ~= nil then
            last = value
        end
    end
    return last
end

function core.Concatenate(s1, s2)
    if core.Len(s2) == 0 then
        return s1
    end
    if core.Len(s1) == 0 then
        return s2
    end
    local result = {}
    local n = #s1
    for i = 1, n do
        result[i] = s1[i]
    end
    for i = 1, #s2 do
        result[n + i] = s2[i]
    end
    return result
end

-- start is 0-based (negative counts from the end, like Go's port of JS splice).
function core.Splice(s1, start, deleteCount, ...)
    local items = { ... }
    local n = core.Len(s1)
    if start < 0 then
        start = n + start
    end
    if start < 0 then
        start = 0
    end
    if start > n then
        start = n
    end
    if deleteCount < 0 then
        deleteCount = 0
    end
    local end_ = math.min(start + math.max(deleteCount, 0), n)
    if start == end_ and #items == 0 then
        return s1
    end
    local result = {}
    local k = 0
    for i = 1, start do
        k = k + 1
        result[k] = s1[i]
    end
    for i = 1, #items do
        k = k + 1
        result[k] = items[i]
    end
    for i = end_ + 1, n do
        k = k + 1
        result[k] = s1[i]
    end
    return result
end

function core.CountWhere(slice, f)
    local count = 0
    if slice == nil then
        return count
    end
    for i = 1, #slice do
        if f(slice[i]) then
            count = count + 1
        end
    end
    return count
end

-- i is 0-based.
function core.ReplaceElement(slice, i, t)
    local result = {}
    for k = 1, #slice do
        result[k] = slice[k]
    end
    result[i + 1] = t
    return result
end

-- Mirrors slices.BinarySearchFunc + slices.Insert; returns a new array.
function core.InsertSorted(slice, element, cmp)
    local n = core.Len(slice)
    local lo, hi = 0, n
    while lo < hi do
        local h = (lo + hi) >> 1
        if cmp(slice[h + 1], element) < 0 then
            lo = h + 1
        else
            hi = h
        end
    end
    local result = {}
    for k = 1, lo do
        result[k] = slice[k]
    end
    result[lo + 1] = element
    for k = lo + 1, n do
        result[k + 1] = slice[k]
    end
    return result
end

-- MinAllFunc returns all minimum elements from xs according to the comparison function cmp.
function core.MinAllFunc(xs, cmp)
    if core.Len(xs) == 0 then
        return nil
    end

    local m = xs[1]
    local mins = { m }

    for i = 2, #xs do
        local x = xs[i]
        local c = cmp(x, m)
        if c < 0 then
            m = x
            mins = { x }
        elseif c == 0 then
            mins[#mins + 1] = x
        end
    end

    return mins
end

function core.AppendIfUnique(slice, element)
    if slice ~= nil then
        for i = 1, #slice do
            if slice[i] == element then
                return slice
            end
        end
    else
        slice = {}
    end
    slice[#slice + 1] = element
    return slice
end

function core.Memoize(create)
    local value = nil
    return function()
        if create ~= nil then
            value = create()
            create = nil
        end
        return value
    end
end

-- Returns whenTrue if b is true; otherwise, returns whenFalse. IfElse should only be used when branches are either
-- constant or precomputed as both branches will be evaluated regardless as to the value of b.
function core.IfElse(b, whenTrue, whenFalse)
    if b then
        return whenTrue
    end
    return whenFalse
end

-- Returns value if value is not the zero value of T; Otherwise, returns defaultValue. OrElse should only be used when
-- defaultValue is constant or precomputed as its argument will be evaluated regardless as to the content of value.
function core.OrElse(value, defaultValue)
    if not core.IsZero(value) then
        return value
    end
    return defaultValue
end

-- Returns `a` if `a` is not `nil`; Otherwise, returns `b`. Coalesce is roughly analogous to `??` in JS, except that it
-- non-shortcutting, so it is advised to only use a constant or precomputed value for `b`
function core.Coalesce(a, b)
    if a == nil then
        return b
    else
        return a
    end
end

-- ECMALineStarts is an array of 0-based byte offsets.
function core.ComputeECMALineStarts(text)
    return core.Collect(core.ComputeECMALineStartsSeq(text))
end

-- Returns a Lua iterator over 0-based line start offsets.
function core.ComputeECMALineStartsSeq(text)
    local textLen = #text
    local pos = 0
    local lineStart = 0
    local done = false
    return function()
        if done then
            return nil
        end
        while pos < textLen do
            local b = string.byte(text, pos + 1)
            if b < 0x80 then
                pos = pos + 1
                if b == 13 then -- '\r'
                    if pos < textLen and string.byte(text, pos + 1) == 10 then
                        pos = pos + 1
                    end
                    local result = lineStart
                    lineStart = pos
                    return result
                elseif b == 10 then -- '\n'
                    local result = lineStart
                    lineStart = pos
                    return result
                end
            else
                local ch, size = core.DecodeRune(text, pos)
                pos = pos + size
                if stringutil.IsLineBreak(ch) then
                    local result = lineStart
                    lineStart = pos
                    return result
                end
            end
        end
        done = true
        return lineStart
    end
end

-- PositionToLineAndByteOffset returns the 0-based line and byte offset from the
-- start of that line for the given byte position, using the provided line starts.
-- The byte offset is a raw UTF-8 byte offset from the line start, not a UTF-16 code unit count.
function core.PositionToLineAndByteOffset(position, lineStarts)
    -- sort.Search(len(lineStarts), func(i) bool { return lineStarts[i] > position })
    local lo, hi = 0, #lineStarts
    while lo < hi do
        local h = (lo + hi) >> 1
        if lineStarts[h + 1] <= position then
            lo = h + 1
        else
            hi = h
        end
    end
    local line = math.max(lo - 1, 0)
    return line, position - lineStarts[line + 1]
end

-- UTF16Len returns the number of UTF-16 code units needed to
-- represent the given UTF-8 encoded string.
function core.UTF16Len(s)
    local n = #s
    for i = 1, n do
        if string.byte(s, i) >= 0x80 then
            local count = i - 1
            local pos = i - 1
            while pos < n do
                local r, size = core.DecodeRune(s, pos)
                pos = pos + size
                if r >= 0x10000 then
                    count = count + 2
                else
                    count = count + 1
                end
            end
            return count
        end
    end
    return n
end

function core.Flatten(array)
    local result = nil
    if array == nil then
        return result
    end
    for _, subArray in ipairs(array) do
        if subArray ~= nil and #subArray > 0 then
            if result == nil then
                result = {}
            end
            local n = #result
            for j = 1, #subArray do
                result[n + j] = subArray[j]
            end
        end
    end
    return result
end

function core.Must(v, err)
    if err ~= nil then
        error(err, 0)
    end
    return v
end

-- Extracts the first value of a multi-value return.
function core.FirstResult(t1)
    return t1
end

-- Returns (string, err).
function core.StringifyJson(input, prefix, indent)
    local output, err = json.MarshalIndent(input, prefix, indent)
    return output, err
end

function core.GetScriptKindFromFileName(fileName)
    local dotPos = -1
    for i = #fileName, 1, -1 do
        if string.byte(fileName, i) == 46 then
            dotPos = i - 1
            break
        end
    end
    if dotPos >= 0 then
        local ext = stringutil.StringsToLower(string.sub(fileName, dotPos + 1))
        if ext == tspath.ExtensionJs or ext == tspath.ExtensionCjs or ext == tspath.ExtensionMjs then
            return ScriptKind.JS
        elseif ext == tspath.ExtensionJsx then
            return ScriptKind.JSX
        elseif ext == tspath.ExtensionTs or ext == tspath.ExtensionCts or ext == tspath.ExtensionMts then
            return ScriptKind.TS
        elseif ext == tspath.ExtensionTsx then
            return ScriptKind.TSX
        elseif ext == tspath.ExtensionJson then
            return ScriptKind.JSON
        end
    end
    return ScriptKind.Unknown
end

function core.GetDefaultExtensionForScriptKind(scriptKind)
    if scriptKind == ScriptKind.JS then
        return tspath.ExtensionJs
    elseif scriptKind == ScriptKind.JSX then
        return tspath.ExtensionJsx
    elseif scriptKind == ScriptKind.TSX then
        return tspath.ExtensionTsx
    elseif scriptKind == ScriptKind.JSON then
        return tspath.ExtensionJson
    else
        return tspath.ExtensionTs
    end
end

-- EnsureScriptKindFromFileName is like GetScriptKindFromFileName, but defaults to
-- ScriptKindTS when the file name has no recognized extension (e.g. files included
-- with allowNonTsExtensions), so the result is always safe to hand to the parser.
function core.EnsureScriptKindFromFileName(fileName)
    local kind = core.GetScriptKindFromFileName(fileName)
    if kind ~= ScriptKind.Unknown then
        return kind
    end
    return ScriptKind.TS
end

-- Given a name and a list of names that are *not* equal to the name, return a spelling suggestion if there is one that is close enough.
-- Names less than length 3 only check for case-insensitive equality.
--
-- find the candidate with the smallest Levenshtein distance,
--
--	except for candidates:
--	  * With no name
--	  * Whose length differs from the target name by more than 0.34 of the length of the name.
--	  * Whose levenshtein distance is more than 0.4 of the length of the name
--	    (0.4 allows 1 substitution/transposition for every 5 characters,
--	     and 1 insertion/deletion at 3 characters)
--
-- candidates is an array (iter.Seq parameter).
function core.GetSpellingSuggestion(name, candidates, getName, compare)
    return core.getSpellingSuggestion(name, candidates, getName, compare, 0 --[[maxCandidates]])
end

function core.GetSpellingSuggestionWithMaxCandidateCount(name, candidates, getName, compare, maxCandidates)
    return core.getSpellingSuggestion(name, candidates, getName, compare, maxCandidates)
end

function core.getSpellingSuggestion(name, candidates, getName, compare, maxCandidates)
    local runeName = core.StringToRunes(name)
    local maximumLengthDifference = math.max(2, math.floor(#runeName * 0.34))
    local bestDistance = math.floor(#runeName * 0.4) + 0.9 -- If the best result is worse than this, don't bother.
    local buffers = { previous = {}, current = {} }
    local bestCandidate = nil
    local hasBest = false
    local checkedCandidates = 0
    if candidates == nil then
        return nil
    end
    for _, candidate in ipairs(candidates) do
        checkedCandidates = checkedCandidates + 1
        if maxCandidates > 0 and checkedCandidates > maxCandidates then
            return core.zeroLike(candidate)
        end
        local candidateName = getName(candidate)
        -- Go compares the byte length of the candidate with the rune length of the name.
        local maxLen = math.max(#candidateName, #runeName)
        local minLen = math.min(#candidateName, #runeName)
        if candidateName ~= "" and maxLen - minLen <= maximumLengthDifference then
            if candidateName == name then
                goto continue
            end
            -- Only consider candidates less than 3 characters long when they differ by case.
            -- Otherwise, don't bother, since a user would usually notice differences of a 2-character name.
            if #candidateName < 3 and not stringutil.EqualFold(candidateName, name) then
                goto continue
            end
            local distance = core.levenshteinWithMax(buffers, runeName, core.StringToRunes(candidateName), bestDistance)
            if distance < 0 then
                goto continue
            end
            debug.Assert(distance <= bestDistance) -- Else `levenshteinWithMax` should return undefined
            if distance < bestDistance then
                bestDistance = distance
                bestCandidate = candidate
                hasBest = true
            elseif not hasBest or compare(candidate, bestCandidate) < 0 then
                bestCandidate = candidate
                hasBest = true
            end
        end
        ::continue::
    end
    if bestCandidate == nil then
        return core.zeroLike(candidates[1])
    end
    return bestCandidate
end

local function compareStrings(a, b)
    if a == b then
        return 0
    elseif a < b then
        return -1
    end
    return 1
end

-- candidates is an array of strings. Returns "" (the Go zero value) when there is no suggestion.
function core.GetSpellingSuggestionForStrings(name, candidates)
    return core.GetSpellingSuggestion(name, candidates, core.Identity, compareStrings) or ""
end

function core.levenshteinWithMax(buffers, s1, s2, maxValue)
    local bufferSize = #s2 + 1
    local previous = {}
    local current = {}
    for i = 1, bufferSize do
        previous[i] = 0.0
        current[i] = 0.0
    end
    buffers.previous = previous
    buffers.current = current

    local big = maxValue + 0.01
    for i = 0, bufferSize - 1 do
        previous[i + 1] = i + 0.0
    end
    for i = 1, #s1 do
        local c1 = s1[i]
        local minJ = math.max(math.ceil(i - maxValue), 1)
        local maxJ = math.min(math.floor(maxValue + i), #s2)
        local colMin = i + 0.0
        current[1] = colMin
        for j = 1, minJ - 1 do
            current[j + 1] = big
        end
        for j = minJ, maxJ do
            local substitutionDistance, dist
            if stringutil.UnicodeToLower(s1[i]) == stringutil.UnicodeToLower(s2[j]) then
                substitutionDistance = previous[j] + 0.1
            else
                substitutionDistance = previous[j] + 2
            end
            if c1 == s2[j] then
                dist = previous[j]
            else
                dist = math.min(previous[j + 1] + 1, math.min(current[j] + 1, substitutionDistance))
            end
            current[j + 1] = dist
            colMin = math.min(colMin, dist)
        end
        for j = maxJ + 1, #s2 do
            current[j + 1] = big
        end
        if colMin > maxValue then
            -- Give up -- everything in this column is > max and it can't get better in future columns.
            return -1
        end
        previous, current = current, previous
    end
    local res = previous[#s2 + 1]
    if res > maxValue then
        return -1
    end
    return res
end

function core.Identity(t)
    return t
end

function core.CheckEachDefined(s, msg)
    -- Lua arrays cannot hold nil holes; the length operator stops at the first nil.
    return s
end

-- startIndex is 0-based; returns a 0-based index or -1.
function core.IndexAfter(s, pattern, startIndex)
    local matched = string.find(s, pattern, startIndex + 1, true)
    if matched == nil then
        return -1
    else
        return matched - 1
    end
end

function core.ShouldRewriteModuleSpecifier(specifier, compilerOptions)
    return core.Tristate_IsTrue(compilerOptions.rewriteRelativeImportExtensions) and tspath.PathIsRelative(specifier) and not tspath.IsDeclarationFileName(specifier) and tspath.HasTSFileExtension(specifier)
end

function core.SingleElementSlice(element)
    if element == nil then
        return nil
    end
    return { element }
end

-- seqs are arrays; returns a Lua iterator.
function core.ConcatenateSeq(...)
    local seqs = { ... }
    local nseqs = select("#", ...)
    local si = 1
    local i = 0
    return function()
        while si <= nseqs do
            local seq = seqs[si]
            if seq ~= nil then
                i = i + 1
                local v = seq[i]
                if v ~= nil then
                    return v
                end
            end
            si = si + 1
            i = 0
        end
        return nil
    end
end

-- Enumerate returns a sequence of (index, value) pairs from the input sequence.
-- seq is an array; returns a Lua iterator yielding (0-based index, value).
function core.Enumerate(seq)
    local i = 0
    return function()
        if seq == nil then
            return nil
        end
        local v = seq[i + 1]
        if v == nil then
            return nil
        end
        local idx = i
        i = i + 1
        return idx, v
    end
end

function core.comparableValuesEqual(a, b)
    return a == b
end

-- DiffMaps compares two maps m1 and m2 and calls the provided callbacks for added, removed, and changed entries.
-- onAdded is called for each key-value pair that is in m2 but not in m1.
-- onRemoved is called for each key-value pair that is in m1 but not in m2.
-- onChanged is called for each key where the value in m1 differs from the value in m2.
function core.DiffMaps(m1, m2, onAdded, onRemoved, onChanged)
    core.DiffMapsFunc(m1, m2, core.comparableValuesEqual, onAdded, onRemoved, onChanged)
end

-- DiffMapsFunc compares two maps m1 and m2 and calls the provided callbacks for added, removed, and changed entries.
function core.DiffMapsFunc(m1, m2, equalValues, onAdded, onRemoved, onChanged)
    m1 = m1 or {}
    m2 = m2 or {}
    if onAdded ~= nil then
        for k, v2 in pairs(m2) do
            if m1[k] == nil then
                onAdded(k, v2)
            end
        end
    end
    if onChanged == nil and onRemoved == nil then
        return
    end
    for k, v1 in pairs(m1) do
        local v2 = m2[k]
        if v2 ~= nil then
            if onChanged ~= nil and not equalValues(v1, v2) then
                onChanged(k, v1, v2)
            end
        else
            onRemoved(k, v1)
        end
    end
end

-- CopyMapInto is maps.Copy, unless dst is nil, in which case it clones and returns src.
-- Use CopyMapInto anywhere you would use maps.Copy preceded by a nil check and map initialization.
function core.CopyMapInto(dst, src)
    if dst == nil then
        if src == nil then
            return nil
        end
        dst = {}
    end
    if src ~= nil then
        for k, v in pairs(src) do
            dst[k] = v
        end
    end
    return dst
end

-- UnorderedEqual returns true if s1 and s2 contain the same elements, regardless of order.
function core.UnorderedEqual(s1, s2)
    if core.Len(s1) ~= core.Len(s2) then
        return false
    end
    if s1 == nil then
        return true
    end
    local counts = {}
    for _, v in ipairs(s1) do
        counts[v] = (counts[v] or 0) + 1
    end
    for _, v in ipairs(s2) do
        counts[v] = (counts[v] or 0) - 1
        if counts[v] < 0 then
            return false
        end
    end
    return true
end

local function containsIn(slice, n, value)
    for i = 1, n do
        if slice[i] == value then
            return true
        end
    end
    return false
end

function core.Deduplicate(slice)
    if core.Len(slice) > 1 then
        local n = #slice
        for i = 1, n do
            local value = slice[i]
            if containsIn(slice, i - 1, value) then
                local result = {}
                for k = 1, i - 1 do
                    result[k] = slice[k]
                end
                for j = i + 1, n do
                    value = slice[j]
                    if not containsIn(result, #result, value) then
                        result[#result + 1] = value
                    end
                end
                return result
            end
        end
    end
    return slice
end

-- Go reuses the backing array of slice; this returns a new array.
function core.DeduplicateSorted(slice, isEqual)
    if core.Len(slice) == 0 then
        return slice
    end
    local last = slice[1]
    local deduplicated = { last }
    for i = 2, #slice do
        local next_ = slice[i]
        if not isEqual(last, next_) then
            deduplicated[#deduplicated + 1] = next_
            last = next_
        end
    end

    return deduplicated
end

-- CompareBooleans treats true as greater than false.
function core.CompareBooleans(a, b)
    if a and not b then
        return 1
    elseif not a and b then
        return -1
    end
    return 0
end
