-- Lua-only support code (no Go counterpart file): the parts of Go's errors/fmt/io packages the
-- JSON-RPC and LSP packages are built on.
--
-- Contracts (Go -> Lua):
--   * An error is nil, a string, a number (a Go integer type implementing error, such as
--     lsproto.ErrorCode), or a table with an Error() method. Tables made by jsonrpc.NewError keep
--     the wrapped errors (fmt.Errorf %w operands, Unwrap() []error) in `unwrapAll`; `unwrap` is the
--     first of them, compatible with tslua.vfs.iofs errors.
--   * errors.Is -> jsonrpc.ErrorsIs(err, target) (walks unwrap / unwrapAll depth first, like Go).
--   * err.Error() -> jsonrpc.ErrorString(err).
--   * io.EOF -> jsonrpc.EOF.
local jsonrpc = require("tslua.jsonrpc")

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
    return e:Error()
end
jsonrpc.Error = Error

-- fmt.Errorf with %w operands: message is the formatted text, the rest are the wrapped errors.
function jsonrpc.NewError(message, ...)
    local wrapped = table.pack(...)
    local all = {}
    for i = 1, wrapped.n do
        if wrapped[i] ~= nil then
            all[#all + 1] = wrapped[i]
        end
    end
    return setmetatable({ message = message, unwrap = all[1], unwrapAll = all }, Error)
end

function Error:Error()
    return self.message
end

-- Stringer for number-valued errors; packages with integer error types (lsproto.ErrorCode)
-- register theirs here.
jsonrpc.numberErrorStrings = {}

function jsonrpc.ErrorString(err)
    if err == nil then
        return "<nil>"
    end
    local t = type(err)
    if t == "string" then
        return err
    elseif t == "number" then
        for _, f in ipairs(jsonrpc.numberErrorStrings) do
            local s = f(err)
            if s ~= nil then
                return s
            end
        end
        return tostring(err)
    elseif t == "table" and err.Error ~= nil then
        return err:Error()
    end
    return tostring(err)
end

function jsonrpc.ErrorsIs(err, target)
    if err == nil then
        return target == nil
    end
    if err == target then
        return true
    end
    if type(err) ~= "table" then
        return false
    end
    if err.Is ~= nil and type(err.Is) == "function" and err:Is(target) then
        return true
    end
    if err.unwrapAll ~= nil then
        for _, e in ipairs(err.unwrapAll) do
            if jsonrpc.ErrorsIs(e, target) then
                return true
            end
        end
        return false
    end
    if err.unwrap ~= nil then
        return jsonrpc.ErrorsIs(err.unwrap, target)
    end
    return false
end

-- errors.As / errors.AsType: the first error in the tree for which pred(e) is true.
function jsonrpc.ErrorsFind(err, pred)
    if err == nil then
        return nil
    end
    if pred(err) then
        return err
    end
    if type(err) ~= "table" then
        return nil
    end
    if err.unwrapAll ~= nil then
        for _, e in ipairs(err.unwrapAll) do
            local found = jsonrpc.ErrorsFind(e, pred)
            if found ~= nil then
                return found
            end
        end
        return nil
    end
    if err.unwrap ~= nil then
        return jsonrpc.ErrorsFind(err.unwrap, pred)
    end
    return nil
end

jsonrpc.EOF = setmetatable({ message = "EOF" }, Error)
