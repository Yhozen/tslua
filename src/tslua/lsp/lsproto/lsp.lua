local lsproto = require("tslua.lsp.lsproto")
local bundled = require("tslua.bundled")
local core = require("tslua.core")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local tspath = require("tslua.tspath")

-- DocumentUri, URI and Method are Lua strings; their methods are DocumentUri_<Method>(uri, ...).

-- url.PathUnescape. Returns (s, ok).
function lsproto.pathUnescape(s)
    local ok = true
    local out = string.gsub(s, "%%(..?)", function(h)
        if #h == 2 and string.match(h, "^%x%x$") then
            return string.char(tonumber(h, 16))
        end
        ok = false
        return nil
    end)
    return out, ok
end

function lsproto.DocumentUri_FileName(uri)
    if bundled.IsBundled(uri) then
        return uri
    end
    if string.sub(uri, 1, 7) == "file://" then
        -- url.Parse: file://<host><path>[?query][#fragment]
        local rest = string.sub(uri, 8)
        rest = string.gsub(rest, "#.*$", "")
        rest = string.gsub(rest, "%?.*$", "")
        local slash = string.find(rest, "/", 1, true)
        local host, path
        if slash == nil then
            host, path = rest, ""
        else
            host, path = string.sub(rest, 1, slash - 1), string.sub(rest, slash)
        end
        local okHost, okPath
        host, okHost = lsproto.pathUnescape(host)
        path, okPath = lsproto.pathUnescape(path)
        if not okHost or not okPath then
            error("invalid file URI: " .. uri, 0)
        end
        if host ~= "" then
            return "//" .. host .. path
        end
        return lsproto.fixWindowsURIPath(path)
    end

    -- Leave all other URIs escaped so we can round-trip them.

    local colon = string.find(uri, ":", 1, true)
    if colon == nil then
        error("invalid URI: " .. uri, 0)
    end
    local scheme, path = string.sub(uri, 1, colon - 1), string.sub(uri, colon + 1)

    local authority = "ts-nul-authority"
    if string.sub(path, 1, 2) == "//" then
        local rest = string.sub(path, 3)
        local slash = string.find(rest, "/", 1, true)
        if slash == nil then
            error("invalid URI: " .. uri, 0)
        end
        authority, path = string.sub(rest, 1, slash - 1), string.sub(rest, slash + 1)
    end

    return "^/" .. scheme .. "/" .. authority .. "/" .. path
end

function lsproto.DocumentUri_Path(uri, useCaseSensitiveFileNames)
    local fileName = lsproto.DocumentUri_FileName(uri)
    return tspath.ToPath(fileName, "", useCaseSensitiveFileNames)
end

function lsproto.fixWindowsURIPath(path)
    if string.sub(path, 1, 1) == "/" then
        local volume, rest, ok = tspath.SplitVolumePath(string.sub(path, 2))
        if ok then
            return volume .. rest
        end
    end
    return path
end

-- HasTextDocumentURI: values with a TextDocumentURI() method.
-- HasTextDocumentPosition: HasTextDocumentURI plus TextDocumentPosition().
-- HasLocations: values with GetLocations(). HasLocation: values with GetLocation().

lsproto.quoteString = json.QuoteString

function lsproto.kindString(k)
    return jsonrpc.kindName(k)
end

function lsproto.errNotObject(k)
    return "expected object start, but encountered " .. lsproto.kindString(k)
end

function lsproto.errNull(field)
    return "null value is not allowed for field " .. jsonrpc.goQuote(field)
end

function lsproto.errMissing(props)
    return "missing required properties: " .. table.concat(props, ", ")
end

function lsproto.errInvalidKind(typeName, got)
    return "invalid " .. typeName .. ": got " .. lsproto.kindString(got)
end

function lsproto.errInvalidValue(typeName, data)
    return "invalid " .. typeName .. ": " .. data
end

function lsproto.errLiteralMismatch(typeName, expected, got)
    return "expected " .. typeName .. " value " .. expected .. ", got " .. got
end

function lsproto.assertOnlyOne(message, count)
    if count ~= 1 then
        error(message, 0)
    end
end

function lsproto.assertAtMostOne(message, count)
    if count > 1 then
        error(message, 0)
    end
end

-- jsonKeyCheck compares a raw JSON key token (including quotes) against a Go string.
function lsproto.jsonKeyCheck(name, key)
    return #name == #key + 2 and string.sub(name, 1, 1) == '"' and string.sub(name, 2, -2) == key
end

-- jsonObjectRawField scans the top-level keys of a JSON object looking for the
-- given field name, and returns its raw JSON value (e.g. `"full"` with quotes).
-- Returns nil if the field is not found.
function lsproto.jsonObjectRawField(data, field)
    local dec = json.NewDecoder(data)
    if dec:PeekKind() ~= "{" then
        return nil
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil
    end
    while dec:PeekKind() ~= "}" do
        local name
        name, err = dec:ReadValue()
        if err ~= nil then
            return nil
        end
        if lsproto.jsonKeyCheck(name, field) then
            local val
            val, err = dec:ReadValue()
            if err ~= nil then
                return nil
            end
            return val
        end
        if dec:SkipValue() ~= nil then
            return nil
        end
    end
    return nil
end

-- jsonObjectHasKey scans the top-level keys of a JSON object looking for any of the
-- given keys. Returns the index of the first key found, or -1 if none match.
-- Bails early on first match without decoding any values.
function lsproto.jsonObjectHasKey(data, ...)
    local keys = { ... }
    local dec = json.NewDecoder(data)
    if dec:PeekKind() ~= "{" then
        return -1
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return -1
    end
    while dec:PeekKind() ~= "}" do
        local name
        name, err = dec:ReadValue()
        if err ~= nil then
            return -1
        end
        for i, key in ipairs(keys) do
            if lsproto.jsonKeyCheck(name, key) then
                return i - 1
            end
        end
        if dec:SkipValue() ~= nil then
            return -1
        end
    end
    return -1
end

-- Inspired by https://www.youtube.com/watch?v=dab3I-HcTVk
--
-- RequestInfo[Params, Resp] keeps the Go type strings of its type parameters in paramsType and
-- resultType; NotificationInfo[Params] in paramsType.

local RequestInfo = {}
RequestInfo.__index = RequestInfo
lsproto.RequestInfo = RequestInfo

function lsproto.NewRequestInfo(method, paramsType, resultType)
    return setmetatable({ Method = method, paramsType = paramsType, resultType = resultType }, RequestInfo)
end

-- Returns (Resp, err).
function RequestInfo:UnmarshalResult(result)
    if type(result) ~= "table" or getmetatable(result) ~= jsonrpc.Value then
        return lsproto.Zero(self.resultType), "expected json.Value, got " .. type(result)
    end
    local r, err = lsproto.UnmarshalAs(self.resultType, result.data)
    if err ~= nil then
        return lsproto.Zero(self.resultType), err
    end
    return r, nil
end

function RequestInfo:NewRequestMessage(id, params)
    return lsproto.NewRequestMessage(id, self.Method, params, self.paramsType)
end

local NotificationInfo = {}
NotificationInfo.__index = NotificationInfo
lsproto.NotificationInfo = NotificationInfo

function lsproto.NewNotificationInfo(method, paramsType)
    return setmetatable({ Method = method, paramsType = paramsType }, NotificationInfo)
end

function NotificationInfo:NewNotificationMessage(params)
    return lsproto.NewRequestMessage(nil, self.Method, params, self.paramsType)
end

-- UnmarshalParams decodes the params of an inbound request or notification
-- message into the requested type (a Go type string, usually info.paramsType). Inbound messages
-- store their params as a raw json.Value (see Message:UnmarshalJSON); decoding is deferred to the
-- point of dispatch.
--
-- A NoParams method must be given no params; every other method must be given
-- params as an object or array. A violation returns ErrorCode.InvalidParams.
-- Returns (params, err).
function lsproto.UnmarshalParams(paramsType, req)
    local raw
    if req.params ~= nil then
        if type(req.params) ~= "table" or getmetatable(req.params) ~= jsonrpc.Value then
            return lsproto.Zero(paramsType), lsproto.newCodeError(lsproto.ErrorCode.InvalidParams, "unexpected params type " .. type(req.params))
        end
        raw = req.params
    end

    -- params is the zero value of T; this asserts on its type, i.e. whether the
    -- method was declared with NoParams.
    if paramsType == "NoParams" then
        if raw ~= nil and #raw.data ~= 0 then
            return lsproto.NoParams, lsproto.newCodeError(lsproto.ErrorCode.InvalidParams, "expected no params, got " .. raw.data)
        end
        return lsproto.NoParams, nil
    end

    -- The base protocol defines params as `array | object`; reject anything else
    -- (absent, null, or a scalar).
    local k = raw ~= nil and raw:Kind() or 0
    if k ~= "{" and k ~= "[" then
        return lsproto.Zero(paramsType), lsproto.newCodeError(lsproto.ErrorCode.InvalidParams, "params must be an object or array")
    end
    local params, err = lsproto.UnmarshalAs(paramsType, raw.data)
    if err ~= nil then
        return lsproto.Zero(paramsType), lsproto.newCodeError(lsproto.ErrorCode.InvalidParams, jsonrpc.ErrorString(err), err)
    end
    return params, nil
end

-- fmt.Errorf("%w: <message>", code[, err]): an error wrapping an ErrorCode.
function lsproto.newCodeError(code, message, err)
    return jsonrpc.NewError(lsproto.ErrorCode_String(code) .. ": " .. message, code, err)
end

-- Null marshals as JSON null and only unmarshals from null.
local NullClass = {
    __name = "Null",
    MarshalJSON = function()
        return "null", nil
    end,
}
NullClass.__index = NullClass
lsproto.Null = setmetatable({}, {
    __index = NullClass,
    __call = function(self)
        return self
    end,
})

-- NoParams is always zero (omitted from messages).
lsproto.NoParams = setmetatable({}, {
    __call = function(self)
        return self
    end,
})

function lsproto.NoParams_IsZero()
    return true
end

lsproto.clientCapabilitiesKey = "lsproto.clientCapabilitiesKey"

function lsproto.WithClientCapabilities(ctx, caps)
    return core.contextWithValue(ctx, lsproto.clientCapabilitiesKey, caps)
end

function lsproto.GetClientCapabilities(ctx)
    local caps = core.contextValue(ctx, lsproto.clientCapabilitiesKey)
    if caps ~= nil then
        return caps
    end
    return lsproto.ClientCapabilities.Resolve(nil)
end

-- PreferredMarkupKind returns the first (most preferred) markup kind from the given formats,
-- or MarkupKind.PlainText if the slice is empty.
function lsproto.PreferredMarkupKind(formats)
    if formats ~= nil and #formats > 0 then
        return formats[1]
    end
    return lsproto.MarkupKind.PlainText
end

-- CodeActionKind.SourceRemoveUnusedImports / SourceSortImports are in consts_generated.lua.
