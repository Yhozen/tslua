local locale = require("tslua.locale")

-- Locale is a BCP 47 language tag (Go `type Locale language.Tag`), represented by its canonical
-- string; see language.lua for the golang.org/x/text/language emulation.

-- The zero Locale (language.Und).
locale.Default = ""

function locale.Locale_String(l)
    if l == nil or l == locale.Default then
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

-- Parse gracefully fails. Returns (Locale, ok).
function locale.Parse(localeStr)
    local tag, ok = locale.ParseTag(localeStr)
    return tag, ok
end
