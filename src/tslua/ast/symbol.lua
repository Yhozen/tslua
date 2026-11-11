local ast = require("tslua.ast")

local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags

-- Symbol

local Symbol = {}
Symbol.__index = Symbol
Symbol.__name = "Symbol"
ast.Symbol = Symbol

-- Lua constructor for the Go struct literal &ast.Symbol{Flags: flags, Name: name}.
function ast.NewSymbol(flags, name)
    return setmetatable({
        flags = flags or 0,
        checkFlags = 0, -- Non-zero only in transient symbols created by Checker
        name = name or "",
        declarations = nil,
        valueDeclaration = nil,
        members = nil,
        exports = nil,
        id = 0,
        parent = nil,
        exportSymbol = nil,
    }, Symbol)
end

function Symbol:IsExternalModule()
    return self.flags & SymbolFlags.Module ~= 0 and #self.name > 0 and string.byte(self.name, 1) == 34 -- '"'
end

function Symbol:IsStatic()
    if self.valueDeclaration == nil then
        return false
    end
    local modifierFlags = self.valueDeclaration:ModifierFlags()
    return modifierFlags & ModifierFlags.Static ~= 0
end

-- See comment on `declareModuleMember` in `binder.go`.
function Symbol:CombinedLocalAndExportSymbolFlags()
    if self.exportSymbol ~= nil then
        return self.flags | self.exportSymbol.flags
    end
    return self.flags
end

-- SymbolTable is Go map[string]*Symbol: a plain Lua table name -> symbol.
function ast.NewSymbolTable()
    return {}
end

function ast.SymbolName(symbol)
    if symbol.valueDeclaration ~= nil and ast.IsPrivateIdentifierClassElementDeclaration(symbol.valueDeclaration) then
        return symbol.valueDeclaration:Name():Text()
    end
    return symbol.name
end

local prefix = ast.InternalSymbolNamePrefix

-- EscapeAllInternalSymbolNames replaces internal symbol name markers ("\xFE") with "__".
function ast.EscapeAllInternalSymbolNames(name)
    return (string.gsub(name, prefix, "__"))
end

function ast.EscapeInternalSymbolName(name)
    if string.sub(name, 1, #prefix) == prefix then
        return "__" .. string.sub(name, #prefix + 1)
    end
    return name
end

-- EscapeSymbolName converts a binder symbol name into its escaped "__String"
-- form. Internal names (prefixed with the "\xFE" sentinel) become "__"-prefixed,
-- and user names that already begin with "__" gain an extra leading underscore
-- so they can be distinguished from internal names.
function ast.EscapeSymbolName(name)
    if string.sub(name, 1, #prefix) == prefix then
        return "__" .. string.sub(name, #prefix + 1)
    end
    if #name >= 2 and string.byte(name, 1) == 95 and string.byte(name, 2) == 95 then
        return "_" .. name
    end
    return name
end
