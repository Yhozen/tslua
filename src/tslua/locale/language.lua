local locale = require("tslua.locale")

-- Emulation of the parts of golang.org/x/text/language the port uses (language.Parse and
-- language.Matcher). A tag is its canonical BCP 47 string (Go's Tag.String()); language.Und is "".
-- The CLDR data (aliases, likely subtags, language distances) is not ported: the match results
-- for the one matcher the port builds (internal/diagnostics/loc_generated.go) are precomputed by
-- scripts/gen/loctables into language_generated.lua.

local data = nil

local function languageData()
    if data == nil then
        data = require("tslua.locale.language_generated")
    end
    return data
end

-- language.Confidence
locale.Confidence = {
    No = 0,
    Low = 1,
    High = 2,
    Exact = 3,
}

-- splitTag splits a canonical tag into its language, script and region subtags (script and
-- region are nil when absent).
function locale.splitTag(tag)
    local parts = {}
    for part in string.gmatch(tag .. "-", "([^-]*)-") do
        parts[#parts + 1] = part
    end
    local lang = parts[1]
    local script, region = nil, nil
    local i = 2
    if parts[i] ~= nil and #parts[i] == 4 and string.find(parts[i], "^%a+$") then
        script = parts[i]
        i = i + 1
    end
    if parts[i] ~= nil and ((#parts[i] == 2 and string.find(parts[i], "^%a+$")) or (#parts[i] == 3 and string.find(parts[i], "^%d+$"))) then
        region = parts[i]
    end
    return lang, script, region
end

-- Maps each word of text to its 1-based position.
local function wordSet(text)
    local set = {}
    local n = 0
    for w in string.gmatch(text, "%S+") do
        n = n + 1
        set[w] = n
    end
    return set
end

local sets = nil

local function subtagSets()
    if sets == nil then
        local d = languageData()
        sets = {
            languages = wordSet(d.languages),
            scripts = wordSet(d.scripts),
            regions = wordSet(d.regions),
            variants = wordSet(d.variants),
        }
    end
    return sets
end

-- language.Parse. Returns (tag, ok). Handles language[-extlang][-script][-region][-variant...]
-- [-extension...][-x-private] tags with registered subtags and canonicalizes them like Tag.String
-- (subtag case, deprecated/ISO 639-2 language codes, region aliases, variant order). Like Go, a
-- malformed or unregistered subtag is dropped and reported (ok = false) while the rest of the tag is
-- kept ("de-foobar" -> "de", "ac-DE" -> "und-DE", "whoops" -> Und). Not emulated: tags that start
-- with a private use or grandfathered subtag ("x-foo", "i-klingon"), and the canonicalization of
-- variants and -u- extensions ("en-US-POSIX").
function locale.ParseTag(s)
    s = string.gsub(s, "_", "-")
    local parts = {}
    for part in string.gmatch(s .. "-", "([^-]*)-") do
        parts[#parts + 1] = string.lower(part)
    end
    local known = subtagSets()
    local ok = true
    local i = 1
    local lang = "und"
    if string.find(parts[1], "^%a%a%a?$") and known.languages[parts[1]] then
        lang = parts[1]
        i = 2
        -- extended language subtag: "zh-cmn" is "cmn"
        if parts[i] ~= nil and string.find(parts[i], "^%a%a%a$") then
            if known.languages[parts[i]] then
                lang = parts[i]
            else
                ok = false
            end
            i = i + 1
        end
    else
        ok = false
        if string.find(parts[1], "^%a+$") and #parts[1] ~= 4 then
            i = 2
        end
    end
    local script, region = nil, nil
    local alias = languageData().aliases[lang]
    if alias ~= nil then
        lang, script, region = locale.splitTag(alias)
    end
    local variants = {}
    local seenVariant = {}
    local extensions = {}
    -- 1: script allowed, 2: region allowed, 3: variants, 4: extensions
    local state = 1
    while i <= #parts do
        local p = parts[i]
        i = i + 1
        if #p == 1 and string.find(p, "^%w$") then
            local private = p == "x"
            local ext = { p }
            while i <= #parts and (private or #parts[i] > 1) do
                local q = parts[i]
                if #q >= (private and 1 or 2) and #q <= 8 and string.find(q, "^%w+$") then
                    ext[#ext + 1] = q
                else
                    ok = false
                end
                i = i + 1
            end
            if #ext > 1 then
                extensions[#extensions + 1] = table.concat(ext, "-")
            else
                ok = false
            end
            state = 4
        elseif state <= 1 and string.find(p, "^%a%a%a%a$") then
            p = string.upper(string.sub(p, 1, 1)) .. string.sub(p, 2)
            if known.scripts[p] then
                script = p
            else
                ok = false
            end
            state = 2
        elseif state <= 2 and (string.find(p, "^%a%a$") or string.find(p, "^%d%d%d$")) then
            p = string.upper(p)
            if known.regions[p] then
                region = languageData().regionAliases[p] or p
            else
                ok = false
            end
            state = 3
        elseif state <= 3 and ((#p >= 5 and #p <= 8 and string.find(p, "^%w+$")) or string.find(p, "^%d%w%w%w$")) then
            if not known.variants[p] then
                ok = false
            elseif not seenVariant[p] then
                seenVariant[p] = true
                variants[#variants + 1] = p
            end
            state = 3
        else
            ok = false
        end
    end
    table.sort(variants, function(a, b)
        return known.variants[a] < known.variants[b]
    end)
    local out = { lang }
    if script ~= nil then
        out[#out + 1] = script
    end
    if region ~= nil then
        out[#out + 1] = region
    end
    for _, v in ipairs(variants) do
        out[#out + 1] = v
    end
    for _, e in ipairs(extensions) do
        out[#out + 1] = e
    end
    local tag = table.concat(out, "-")
    if tag == "und" then
        tag = ""
    end
    return tag, ok
end

local Matcher = {}
Matcher.__index = Matcher
locale.Matcher = Matcher

-- language.NewMatcher(supported). supported is an array of tags; supported[1] is the default.
function locale.NewMatcher(supported)
    return setmetatable({ supported = supported }, Matcher)
end

-- Matcher.Match(tag) returns (tag, index, confidence), index 0-based like Go. The results come
-- from the precomputed table and are exact for confidence >= Low; when Go reports No confidence,
-- this returns the default tag with index 0 (Go may report another index, which callers ignore).
function Matcher:Match(tag)
    local matches = languageData().matches
    local lang, script, region = locale.splitTag(tag)
    local r
    if script ~= nil then
        r = matches[lang .. "-" .. script]
    else
        if region ~= nil then
            r = matches[lang .. "-" .. region]
        end
        if r == nil then
            r = matches[lang]
        end
    end
    if r == nil or r[2] < locale.Confidence.Low then
        return self.supported[1], 0, locale.Confidence.No
    end
    return self.supported[r[1] + 1], r[1], r[2]
end
