local stringutil = require("tslua.stringutil")

function stringutil.EquateStringCaseInsensitive(a, b)
    -- !!!
    -- return a == b || strings.ToUpper(a) == strings.ToUpper(b)
    return stringutil.EqualFold(a, b)
end

function stringutil.EquateStringCaseSensitive(a, b)
    return a == b
end

function stringutil.GetStringEqualityComparer(ignoreCase)
    if ignoreCase then
        return stringutil.EquateStringCaseInsensitive
    end
    return stringutil.EquateStringCaseSensitive
end

-- Comparison is an int: ComparisonLessThan (-1), ComparisonEqual (0), ComparisonGreaterThan (1).

function stringutil.CompareStringsCaseInsensitive(a, b)
    if a == b then
        return stringutil.ComparisonEqual
    end
    local ia, ib = 0, 0
    while true do
        local ca, sa = stringutil.DecodeRune(a, ia)
        local cb, sb = stringutil.DecodeRune(b, ib)
        if sa == 0 then
            if sb == 0 then
                return stringutil.ComparisonEqual
            end
            return stringutil.ComparisonLessThan
        end
        if sb == 0 then
            return stringutil.ComparisonGreaterThan
        end
        local lca = stringutil.UnicodeToLower(ca)
        local lcb = stringutil.UnicodeToLower(cb)
        if lca ~= lcb then
            if lca < lcb then
                return stringutil.ComparisonLessThan
            end
            return stringutil.ComparisonGreaterThan
        end
        ia = ia + sa
        ib = ib + sb
    end
end

-- Go strings.Compare (bytewise).
function stringutil.CompareStringsCaseSensitive(a, b)
    if a == b then
        return 0
    elseif a < b then
        return -1
    end
    return 1
end

function stringutil.GetStringComparer(ignoreCase)
    if ignoreCase then
        return stringutil.CompareStringsCaseInsensitive
    end
    return stringutil.CompareStringsCaseSensitive
end

function stringutil.HasPrefix(s, prefix, caseSensitive)
    if caseSensitive then
        return string.sub(s, 1, #prefix) == prefix
    end
    if #prefix > #s then
        return false
    end
    return stringutil.EqualFold(string.sub(s, 1, #prefix), prefix)
end

function stringutil.HasSuffix(s, suffix, caseSensitive)
    if caseSensitive then
        return #suffix <= #s and string.sub(s, #s - #suffix + 1) == suffix
    end
    if #suffix > #s then
        return false
    end
    return stringutil.EqualFold(string.sub(s, #s - #suffix + 1), suffix)
end

function stringutil.HasPrefixAndSuffixWithoutOverlap(s, prefix, suffix, caseSensitive)
    if #prefix + #suffix > #s then
        return false
    end

    return stringutil.HasPrefix(s, prefix, caseSensitive) and stringutil.HasSuffix(s, suffix, caseSensitive)
end

function stringutil.CompareStringsCaseInsensitiveThenSensitive(a, b)
    local cmp = stringutil.CompareStringsCaseInsensitive(a, b)
    if cmp ~= stringutil.ComparisonEqual then
        return cmp
    end
    return stringutil.CompareStringsCaseSensitive(a, b)
end

-- CompareStringsCaseInsensitiveEslintCompatible performs a case-insensitive comparison
-- using toLowerCase() instead of toUpperCase() for ESLint compatibility.
--
-- `CompareStringsCaseInsensitive` transforms letters to uppercase for unicode reasons,
-- while eslint's `sort-imports` rule transforms letters to lowercase. Which one you choose
-- affects the relative order of letters and ASCII characters 91-96, of which `_` is a
-- valid character in an identifier. So if we used `CompareStringsCaseInsensitive` for
-- import sorting, TypeScript and eslint would disagree about the correct case-insensitive
-- sort order for `__String` and `Foo`. Since eslint's whole job is to create consistency
-- by enforcing nitpicky details like this, it makes way more sense for us to just adopt
-- their convention so users can have auto-imports without making eslint angry.
function stringutil.CompareStringsCaseInsensitiveEslintCompatible(a, b)
    if a == b then
        return stringutil.ComparisonEqual
    end
    a = stringutil.StringsToLower(a)
    b = stringutil.StringsToLower(b)
    return stringutil.CompareStringsCaseSensitive(a, b)
end
