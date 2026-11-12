local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local jsonrpc = require("tslua.jsonrpc")

local LanguageService = ls.LanguageService

ls.ErrNoSourceFile = jsonrpc.NewError("source file not found")
ls.ErrNoTokenAtPosition = jsonrpc.NewError("no token found at position")

-- Returns (*ast.Symbol, error).
function LanguageService:GetSymbolAtPosition(ctx, fileName, position)
    local program, file = self:tryGetProgramAndFile(fileName)
    if file == nil then
        return nil, jsonrpc.NewError(ls.ErrNoSourceFile:Error() .. ": " .. fileName, ls.ErrNoSourceFile)
    end
    local node = astnav.GetTokenAtPosition(file, position)
    if node == nil then
        return nil, jsonrpc.NewError(ls.ErrNoTokenAtPosition:Error() .. ": " .. fileName .. ":" .. string.format("%d", position), ls.ErrNoTokenAtPosition)
    end
    local c, done = program:GetTypeCheckerForFile(ctx, file)
    local symbol = c:GetSymbolAtLocation(node)
    if done ~= nil then
        done()
    end
    return symbol, nil
end

function LanguageService:GetSymbolAtLocation(ctx, node)
    local program = self:GetProgram()
    local c, done = program:GetTypeCheckerForFile(ctx, ast.GetSourceFileOfNode(node))
    local symbol = c:GetSymbolAtLocation(node)
    if done ~= nil then
        done()
    end
    return symbol
end

function LanguageService:GetTypeOfSymbol(ctx, symbol)
    local program = self:GetProgram()
    local c, done = program:GetTypeChecker(ctx)
    local t = c:GetTypeOfSymbolAtLocation(symbol, nil)
    if done ~= nil then
        done()
    end
    return t
end
