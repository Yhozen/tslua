local stringutil = require("tslua.stringutil")

function stringutil.ToLowerJS(str)
    local ascii, ok = stringutil.toLowerASCII(str)
    if ok then
        return ascii
    end

    local parts = {}
    local k = 0
    -- casedBefore tracks whether the most recent non-Case_Ignorable code point is
    -- "cased", which is the backward half of the Final_Sigma context. We
    -- accumulate it as we stream so we never have to scan (or decode) backwards.
    local casedBefore = false
    local i = 0
    local n = #str
    while i < n do
        local r, size = stringutil.DecodeJSStringRune(str, i)
        i = i + size
        k = k + 1
        if stringutil.IsSurrogate(r) then
            -- A lone surrogate has no case mapping; preserve it verbatim, matching
            -- String.prototype.toLowerCase. EncodeJSStringRune restores the sentinel
            -- bytes because WriteRune would re-encode the surrogate as U+FFFD.
            parts[k] = stringutil.EncodeJSStringRune(r)
        else
            local mapping = stringutil.specialCasingMappings[r]
            if mapping ~= nil then
                if mapping.condition == stringutil.specialCasingConditionFinalSigma and stringutil.isFinalSigmaContext(casedBefore, str, i) then
                    parts[k] = mapping.conditionalLower
                else
                    parts[k] = mapping.lower
                end
            else
                parts[k] = stringutil.EncodeRune(r)
            end
        end
        if not stringutil.isUnicodeCaseIgnorable(r) then
            casedBefore = stringutil.isSigmaCased(r)
        end
    end
    return table.concat(parts)
end

function stringutil.ToUpperJS(str)
    local ascii, ok = stringutil.toUpperASCII(str)
    if ok then
        return ascii
    end

    local parts = {}
    local k = 0
    local i = 0
    local n = #str
    while i < n do
        local r, size = stringutil.DecodeJSStringRune(str, i)
        k = k + 1
        if stringutil.IsSurrogate(r) then
            -- A lone surrogate has no case mapping; preserve it verbatim, matching
            -- String.prototype.toUpperCase. Copy the sentinel bytes directly because
            -- WriteRune would re-encode the surrogate as U+FFFD.
            parts[k] = string.sub(str, i + 1, i + size)
        else
            local mapping = stringutil.specialCasingMappings[r]
            if mapping ~= nil then
                parts[k] = mapping.upper
            else
                parts[k] = stringutil.EncodeRune(r)
            end
        end
        i = i + size
    end

    return table.concat(parts)
end

-- Returns (string, ok).
function stringutil.toLowerASCII(str)
    if string.find(str, "[\128-\255]") then
        return "", false
    end
    if not string.find(str, "[A-Z]") then
        return str, true
    end
    return (string.gsub(str, "[A-Z]", function(c)
        return string.char(string.byte(c) + 32)
    end)), true
end

-- Returns (string, ok).
function stringutil.toUpperASCII(str)
    if string.find(str, "[\128-\255]") then
        return "", false
    end
    if not string.find(str, "[a-z]") then
        return str, true
    end
    return (string.gsub(str, "[a-z]", function(c)
        return string.char(string.byte(c) - 32)
    end)), true
end

-- isFinalSigmaContext reports whether a sigma at the current position is in
-- Final_Sigma context: it is preceded by a cased code point and not followed by
-- one. casedBefore carries the backward half (tracked incrementally by the
-- caller so we never scan backwards); afterOffset is the byte offset just past
-- the sigma, from which we scan forward.
--
-- ECMAScript points at Unicode Default Case Conversion for toLowerCase, and
-- modern V8 reaches that behavior through Intl::ConvertToLower, which uses
-- ICU root-locale lowercasing for non-Latin1 strings like Greek sigma.
-- We model the exposed V8/ICU behavior directly here: skip Case_Ignorable code
-- points and then look for a Cased code point, exactly as Unicode Table 3-17
-- defines the Final_Sigma condition.
function stringutil.isFinalSigmaContext(casedBefore, str, afterOffset)
    return casedBefore and not stringutil.hasSigmaCasedAfter(str, afterOffset)
end

function stringutil.hasSigmaCasedAfter(str, start)
    local i = start
    local n = #str
    while i < n do
        local r, size = stringutil.DecodeJSStringRune(str, i)
        i = i + size
        if not stringutil.isUnicodeCaseIgnorable(r) then
            return stringutil.isSigmaCased(r)
        end
    end
    return false
end

function stringutil.isSigmaCased(r)
    return stringutil.unicodeIs(stringutil.unicodeCasedRanges, r)
end

function stringutil.isUnicodeCaseIgnorable(r)
    return stringutil.unicodeIs(stringutil.unicodeCaseIgnorableRanges, r)
end
