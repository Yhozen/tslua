local autoimport = require("tslua.ls.autoimport")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local tspath = require("tslua.tspath")

-- ModuleID uniquely identifies a module across multiple declarations.
-- If the export is from an ambient module declaration, this is the module name.
-- If the export is from a module augmentation, this is the Path() of the resolved module file.
-- Otherwise this is the Path() of the exporting source file.
-- (Go `type ModuleID string`: a plain Lua string.)

-- ExportID is a Go value struct { moduleID, exportName }. Treat instances as immutable.
function autoimport.ExportID_new(moduleID, exportName)
    return { moduleID = moduleID or "", exportName = exportName or "" }
end

-- Go `a == b` on ExportID values.
function autoimport.ExportID_Equal(a, b)
    return a.moduleID == b.moduleID and a.exportName == b.exportName
end

-- Go `id == (ExportID{})`.
function autoimport.ExportID_IsZero(id)
    return id.moduleID == "" and id.exportName == ""
end

-- Go string key for maps keyed by ExportID.
function autoimport.ExportID_Key(id)
    return id.moduleID .. "\0" .. id.exportName
end

-- Export embeds ExportID: its fields moduleID and exportName are flattened onto the export.
-- Go `e.ExportID` (the embedded value) is autoimport.Export.ExportID(e).
local Export = {}
Export.__index = Export
autoimport.Export = Export

function autoimport.newExport(init)
    local e = setmetatable({
        moduleID = "",
        exportName = "",
        moduleFileName = "",
        syntax = autoimport.ExportSyntax.None,
        flags = ast.SymbolFlags.None,
        localName = "",
        -- through is the name of the module symbol's export that this export was found on,
        -- either 'export=', InternalSymbolNameExportStar, or empty string.
        through = "",

        -- Checker-set fields

        target = autoimport.ExportID_new("", ""),
        isTypeOnly = false,
        scriptElementKind = lsutil.ScriptElementKind.Unknown,
        scriptElementKindModifiers = lsutil.ScriptElementKindModifier.None,

        -- The file where the export was found.
        path = "",

        packageName = "",
    }, Export)
    if init ~= nil then
        for k, v in pairs(init) do
            e[k] = v
        end
    end
    return e
end

function Export:ExportID()
    return autoimport.ExportID_new(self.moduleID, self.exportName)
end

function Export:Name()
    if self.localName ~= "" then
        return self.localName
    end
    if self.exportName == ast.InternalSymbolNameExportEquals then
        return self.target.exportName
    end
    return self.exportName
end

function Export:IsRenameable()
    return self.exportName == ast.InternalSymbolNameExportEquals or self.exportName == ast.InternalSymbolNameDefault
end

function Export:AmbientModuleName()
    if not tspath.IsExternalModuleNameRelative(self.moduleID) then
        return self.moduleID
    end
    return ""
end

function Export:IsUnresolvedAlias()
    return self.flags == ast.SymbolFlags.Alias
end

function autoimport.SymbolToExport(symbol, ch)
    if symbol.parent ~= nil and checker.IsExternalModuleSymbol(symbol.parent) then
        local moduleID, moduleFileName, ok = autoimport.tryGetModuleIDAndFileNameOfModuleSymbol(symbol.parent)
        if ok then
            return autoimport.extractFirstExport(symbol, ch, moduleID, moduleFileName, ast.GetSourceFileOfModule(symbol.parent))
        end
        return nil
    end

    local declaration = core.FirstOrNil(symbol.declarations)
    if declaration == nil then
        return nil
    end

    local file = ast.GetSourceFileOfNode(declaration)
    if file.symbol == nil then
        return nil
    end

    local moduleSymbol = ch:GetMergedSymbol(file.symbol)
    local moduleID = file:Path()
    local moduleFileName = file:FileName()
    local target = ch:GetMergedSymbol(ch:SkipAlias(symbol))

    local export = autoimport.tryGetModuleExport(ast.InternalSymbolNameDefault, target, moduleSymbol, ch, moduleID, moduleFileName, file)
    if export ~= nil then
        return export
    end
    export = autoimport.tryGetModuleExport(ast.InternalSymbolNameExportEquals, target, moduleSymbol, ch, moduleID, moduleFileName, file)
    if export ~= nil then
        return export
    end
    return autoimport.tryGetModuleExport(symbol.name, target, moduleSymbol, ch, moduleID, moduleFileName, file)
end

function autoimport.tryGetModuleExport(exportName, target, moduleSymbol, ch, moduleID, moduleFileName, file)
    local exported = ch:TryGetMemberInModuleExportsAndProperties(exportName, moduleSymbol)
    if exported ~= nil and ch:GetMergedSymbol(ch:SkipAlias(exported)) == target then
        return autoimport.extractFirstExport(exported, ch, moduleID, moduleFileName, file)
    end
    return nil
end

function autoimport.extractFirstExport(symbol, ch, moduleID, moduleFileName, file)
    local exports = {}
    local extractor = autoimport.newSymbolExtractor("", ch, nil, nil)
    extractor:extractFromSymbol(symbol.name, symbol, moduleID, moduleFileName, file, exports)
    return core.FirstOrNil(exports)
end
