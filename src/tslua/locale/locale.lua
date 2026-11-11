local locale = require("tslua.locale")

-- Locale is a BCP 47 language tag string (Go `type Locale language.Tag`). Localization is out of
-- scope (English only): tags are only parsed and carried around.

locale.Default = ""

function locale.Locale_String(l)
    if l == locale.Default then
        return ""
    end
    return l
end

-- Contexts use the same representation as tslua.core (nil or { parent, key, value }).
locale.contextKey = "locale.contextKey"

function locale.WithLocale(ctx, l)
    return { parent = ctx, key = locale.contextKey, value = l }
end

function locale.FromContext(ctx)
    while ctx ~= nil do
        if ctx.key == locale.contextKey then
            return ctx.value
        end
        ctx = ctx.parent
    end
    return locale.Default
end

-- Parse gracefully fails. Returns (Locale, ok). Well-formed tags are canonicalized like
-- language.Tag.String for the common language[-script][-region] shapes.
function locale.Parse(localeStr)
    local s = string.gsub(localeStr, "_", "-")
    local parts = {}
    for part in string.gmatch(s .. "-", "([^-]*)-") do
        parts[#parts + 1] = part
    end
    local lang = parts[1]
    if lang == nil or not string.find(lang, "^%a%a%a?$") and not string.find(lang, "^%a%a%a%a%a%a?%a?%a?$") then
        return locale.Default, false
    end
    local out = { string.lower(lang) }
    for i = 2, #parts do
        local p = parts[i]
        if not string.find(p, "^%w+$") or #p > 8 then
            return locale.Default, false
        end
        if #p == 4 and string.find(p, "^%a+$") then
            p = string.upper(string.sub(p, 1, 1)) .. string.lower(string.sub(p, 2))
        elseif #p == 2 and string.find(p, "^%a+$") then
            p = string.upper(p)
        else
            p = string.lower(p)
        end
        out[#out + 1] = p
    end
    return table.concat(out, "-"), true
end
