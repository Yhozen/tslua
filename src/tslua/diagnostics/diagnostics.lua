local diagnostics = require("tslua.diagnostics")
local localepkg = require("tslua.locale")

local Category = diagnostics.Category

function diagnostics.Category_Name(category)
    if category == Category.Warning then
        return "warning"
    elseif category == Category.Error then
        return "error"
    elseif category == Category.Suggestion then
        return "suggestion"
    elseif category == Category.Message then
        return "message"
    end
    error("Unhandled diagnostic category", 0)
end

local Message = {}
Message.__index = Message
diagnostics.Message = Message

-- Constructor used by messages_generated.lua (Go struct literal &Message{...}).
function Message.new(fields)
    local m = setmetatable({}, Message)
    m.code = fields.code or 0
    m.category = fields.category or Category.Warning
    m.key = fields.key or ""
    m.text = fields.text or ""
    m.reportsUnnecessary = fields.reportsUnnecessary or false
    m.elidedInCompatibilityPyramid = fields.elidedInCompatibilityPyramid or false
    m.reportsDeprecated = fields.reportsDeprecated or false
    return m
end

function Message:Code() return self.code end
function Message:Category() return self.category end
function Message:Key() return self.key end
function Message:ReportsUnnecessary() return self.reportsUnnecessary end
function Message:ElidedInCompatibilityPyramid() return self.elidedInCompatibilityPyramid end
function Message:ReportsDeprecated() return self.reportsDeprecated end

-- For debugging only.
function Message:String()
    return self.text
end

function Message:Localize(locale, ...)
    local args = diagnostics.StringifyArgs(table.pack(...))
    return diagnostics.Localize(locale, self, "", table.unpack(args or {}))
end

-- keyToMessage mirrors the generated Go switch; the lookup table is built on first use.
local keyToMessageMap = nil

function diagnostics.keyToMessage(key)
    if keyToMessageMap == nil then
        keyToMessageMap = {}
        for _, v in pairs(diagnostics) do
            if getmetatable(v) == Message then
                keyToMessageMap[v.key] = v
            end
        end
    end
    return keyToMessageMap[key]
end

function diagnostics.Localize(locale, message, key, ...)
    if message == nil then
        message = diagnostics.keyToMessage(key)
    end
    if message == nil then
        error("Unknown diagnostic message: " .. tostring(key), 0)
    end

    local text = message.text
    local localized = diagnostics.getLocalizedMessages(locale)
    if localized ~= nil and localized[message.key] ~= nil then
        text = localized[message.key]
    end

    return diagnostics.Format(text, { ... })
end

-- map[language.Tag]map[Key]string; false caches Go nil (no localization for the tag).
diagnostics.localizedMessagesCache = {}

function diagnostics.getLocalizedMessages(loc)
    if loc == nil or loc == localepkg.Default then
        return nil
    end

    -- Check cache first
    local cached = diagnostics.localizedMessagesCache[loc]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end

    local messages = nil

    local _, index, confidence = diagnostics.matcher:Match(loc)
    if confidence >= localepkg.Confidence.Low and index >= 0 and index < #diagnostics.localeFuncs then
        local fn = diagnostics.localeFuncs[index + 1]
        if fn then
            messages = fn()
        end
    end

    diagnostics.localizedMessagesCache[loc] = messages or false
    return messages
end

-- strings.ToValidUTF8(s, "�"): each run of invalid bytes becomes one U+FFFD.
local function toValidUTF8(s)
    if utf8.len(s) ~= nil then
        return s
    end
    local out = {}
    local i = 1
    local n = #s
    local invalid = false
    while i <= n do
        local c = string.byte(s, i)
        local size = 0
        if c < 0x80 then
            size = 1
        elseif c >= 0xC2 and c <= 0xDF then
            size = 2
        elseif c >= 0xE0 and c <= 0xEF then
            size = 3
        elseif c >= 0xF0 and c <= 0xF4 then
            size = 4
        end
        local ok = size > 0 and i + size - 1 <= n
        if ok and size > 1 then
            local c2 = string.byte(s, i + 1)
            local lo, hi = 0x80, 0xBF
            if c == 0xE0 then
                lo = 0xA0
            elseif c == 0xED then
                hi = 0x9F
            elseif c == 0xF0 then
                lo = 0x90
            elseif c == 0xF4 then
                hi = 0x8F
            end
            if c2 < lo or c2 > hi then
                ok = false
            else
                for j = i + 2, i + size - 1 do
                    local cj = string.byte(s, j)
                    if cj < 0x80 or cj > 0xBF then
                        ok = false
                        break
                    end
                end
            end
        end
        if ok then
            out[#out + 1] = string.sub(s, i, i + size - 1)
            invalid = false
            i = i + size
        else
            if not invalid then
                out[#out + 1] = "\u{FFFD}"
            end
            invalid = true
            i = i + 1
        end
    end
    return table.concat(out)
end

function diagnostics.Format(text, args)
    if args == nil or #args == 0 then
        return text
    end

    -- Replace invalid UTF-8 with Unicode replacement character
    local valid = {}
    for i, arg in ipairs(args) do
        valid[i] = toValidUTF8(arg)
    end

    return (string.gsub(text, "{(%d+)}", function(digits)
        local index = math.tointeger(tonumber(digits))
        if index == nil or index >= #valid then
            error("Invalid formatting placeholder", 0)
        end
        return valid[index + 1]
    end))
end

-- Go fmt "%v" for a float64 (strconv.FormatFloat(f, 'g', -1, 64)).
local function formatGoFloat(f)
    if f ~= f then
        return "NaN"
    elseif f == math.huge then
        return "+Inf"
    elseif f == -math.huge then
        return "-Inf"
    elseif f == 0 then
        if 1 / f < 0 then
            return "-0"
        end
        return "0"
    end
    local repr
    for prec = 1, 17 do
        repr = string.format("%." .. (prec - 1) .. "e", f)
        if tonumber(repr) == f then
            break
        end
    end
    local sign, mant, exp = string.match(repr, "^(-?)([%d%.]+)e([-+]%d+)$")
    local digits = string.gsub(mant, "%.", "")
    digits = string.gsub(digits, "0+$", "")
    if digits == "" then
        digits = "0"
    end
    local x = math.tointeger(tonumber(exp))
    local nd = #digits
    if x < -4 or x >= 6 then
        -- %e form (shortest precision uses eprec = 6)
        local m = string.sub(digits, 1, 1)
        if nd > 1 then
            m = m .. "." .. string.sub(digits, 2)
        end
        local es = x < 0 and "-" or "+"
        local ax = math.abs(x)
        local ed = ax < 10 and ("0" .. ax) or tostring(ax)
        return sign .. m .. "e" .. es .. ed
    end
    -- %f form
    local dp = x + 1
    local res
    if dp <= 0 then
        res = "0." .. string.rep("0", -dp) .. digits
    elseif dp >= nd then
        res = digits .. string.rep("0", dp - nd)
    else
        res = string.sub(digits, 1, dp) .. "." .. string.sub(digits, dp + 1)
    end
    return sign .. res
end
diagnostics.formatGoFloat = formatGoFloat

-- Go fmt.Sprintf("%v", arg) for the argument kinds diagnostics receive.
local function sprintV(arg)
    local t = type(arg)
    if t == "number" then
        if math.type(arg) == "integer" then
            return string.format("%d", arg)
        end
        return formatGoFloat(arg)
    elseif t == "boolean" then
        return arg and "true" or "false"
    elseif t == "nil" then
        return "<nil>"
    elseif t == "table" then
        local mt = getmetatable(arg)
        if mt ~= nil and type(arg.String) == "function" then
            return arg:String()
        end
    end
    return tostring(arg)
end

-- args: a Lua array (or table.pack result with .n, which may contain nils).
function diagnostics.StringifyArgs(args)
    local n = args and (args.n or #args) or 0
    if n == 0 then
        return nil
    end

    local result = {}
    for i = 1, n do
        local arg = args[i]
        if type(arg) == "string" then
            result[i] = arg
        else
            result[i] = sprintV(arg)
        end
    end
    return result
end

function diagnostics.NewAdHocMessage(message)
    return Message.new({
        code = -1,
        category = Category.Error,
        key = "-1",
        text = message,
    })
end
