local autoimport = require("tslua.ls.autoimport")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ExportSyntax = autoimport.ExportSyntax

-- Go iterates symbol tables (maps) in random order; iterate them sorted by name for determinism.
local function sortedSymbols(symbols)
    local names = autoimport.sortedKeys(symbols)
    local i = 0
    return function()
        i = i + 1
        local name = names[i]
        if name == nil then
            return nil
        end
        return name, symbols[name]
    end
end

-- symbolExtractor { packageName, stats, localNameResolver, checker, toPath,
--   realpath: if set, is used to resolve symlinks for ModuleID generation.
--     This ensures that symlinked packages use their realpath as ModuleID,
--     deduplicating exports from files that appear via multiple symlink paths. }
local symbolExtractor = {}
symbolExtractor.__index = symbolExtractor
autoimport.symbolExtractor = symbolExtractor

-- exportExtractor embeds *symbolExtractor (flattened) and adds moduleResolver.
local exportExtractor = setmetatable({}, { __index = symbolExtractor })
exportExtractor.__index = exportExtractor
autoimport.exportExtractor = exportExtractor

-- extractorStats { exports, usedChecker } (Go atomic.Int32 counters -> plain numbers).

function exportExtractor:Stats()
    return self.stats
end

-- checkerLease { used, checker }
local checkerLease = {}
checkerLease.__index = checkerLease
autoimport.checkerLease = checkerLease

function autoimport.newCheckerLease(ch)
    return setmetatable({ used = false, checker = ch }, checkerLease)
end

function checkerLease:GetChecker()
    self.used = true
    return self.checker
end

function checkerLease:TryChecker()
    if self.used then
        return self.checker
    end
    return nil
end

function autoimport.newSymbolExtractor(packageName, ch, toPath, realpath)
    return setmetatable({
        packageName = packageName,
        checker = ch,
        localNameResolver = setmetatable({
            compilerOptions = core.EmptyCompilerOptions,
        }, binder.NameResolver),
        stats = { exports = 0, usedChecker = 0 },
        toPath = toPath,
        realpath = realpath,
    }, symbolExtractor)
end

function autoimport.registryBuilder:newExportExtractor(packageName, ch, moduleResolver, realpath)
    local e = autoimport.newSymbolExtractor(packageName, ch, self.base.toPath, realpath)
    e.moduleResolver = moduleResolver
    return setmetatable(e, exportExtractor)
end

-- getModuleID returns the ModuleID for a file, using realpath if available.
function symbolExtractor:getModuleID(file)
    if self.realpath ~= nil and self.toPath ~= nil then
        local realpath = self.realpath(file:FileName())
        return self.toPath(realpath)
    end
    return file:Path()
end

-- getModuleIDForSymbol returns the ModuleID for a module symbol, using realpath
-- normalization when available for source files. Returns (moduleID, ok).
function symbolExtractor:getModuleIDForSymbol(symbol)
    local moduleID, fileName, ok = autoimport.tryGetModuleIDAndFileNameOfModuleSymbol(symbol)
    if not ok then
        return "", false
    end
    -- If fileName is set, this is a source file that may need realpath normalization
    if fileName ~= "" and self.realpath ~= nil then
        local decl = ast.GetNonAugmentationDeclaration(symbol)
        if decl ~= nil and decl.kind == Kind.SourceFile then
            return self:getModuleID(decl:AsSourceFile()), true
        end
    end
    return moduleID, true
end

function exportExtractor:extractFromFile(file)
    if file.symbol ~= nil then
        return self:extractFromModule(file)
    end
    if core.Len(file.ambientModuleNames) > 0 then
        local exports = {}
        for _, statement in ipairs(file.statements.nodes) do
            if ast.IsModuleWithStringLiteralName(statement) and autoimport.isNonPatternAmbientModuleDeclaration(file, statement:AsModuleDeclaration()) then
                self:extractFromModuleDeclaration(statement:AsModuleDeclaration(), file, statement:Name():Text(), "", exports)
            end
        end
        return exports
    end
    return nil
end

function autoimport.isNonPatternAmbientModuleDeclaration(file, decl)
    for _, mod in ipairs(file.patternAmbientModules or {}) do
        if mod.symbol == decl.symbol then
            return false
        end
    end
    return true
end

function exportExtractor:extractFromModule(file)
    local moduleAugmentations = core.MapNonNil(file.moduleAugmentations, function(name)
        local decl = name.parent
        if ast.IsGlobalScopeAugmentation(decl) then
            return nil
        end
        return decl:AsModuleDeclaration()
    end)
    local moduleID = self:getModuleID(file)
    local exports = {}
    for name, symbol in sortedSymbols(file.symbol.exports) do
        self:extractFromSymbol(name, symbol, moduleID, file:FileName(), file, exports)
    end
    for _, decl in ipairs(moduleAugmentations or {}) do
        local name = decl:Name():AsStringLiteral().text
        local augModuleID = name
        local moduleFileName = ""
        if tspath.IsExternalModuleNameRelative(name) then
            local resolved = self.moduleResolver:ResolveModuleName(name, file:FileName(), core.ModuleKind.CommonJS, nil)
            if resolved:IsResolved() then
                moduleFileName = resolved.resolvedFileName
                augModuleID = self.toPath(moduleFileName)
            else
                -- :shrug:
                moduleFileName = tspath.ResolvePath(tspath.GetDirectoryPath(file:FileName()), name)
                augModuleID = self.toPath(moduleFileName)
            end
        end
        self:extractFromModuleDeclaration(decl, file, augModuleID, moduleFileName, exports)
    end
    return exports
end

function exportExtractor:extractFromModuleDeclaration(decl, file, moduleID, moduleFileName, exports)
    for name, symbol in sortedSymbols(decl.symbol.exports) do
        self:extractFromSymbol(name, symbol, moduleID, moduleFileName, file, exports)
    end
end

-- exports is an array that results are appended to (Go *[]*Export).
function symbolExtractor:extractFromSymbol(name, symbol, moduleID, moduleFileName, file, exports)
    if autoimport.shouldIgnoreSymbol(symbol) then
        return
    end

    if name == ast.InternalSymbolNameExportStar then
        local lease = autoimport.newCheckerLease(self.checker)
        local allExports = {}
        for i, s in ipairs(self.checker:GetExportsOfModule(symbol.parent) or {}) do
            allExports[i] = s
        end
        -- allExports includes named exports from the file that will be processed separately;
        -- we want to add only the ones that come from the star
        for exportName, namedExport in sortedSymbols(symbol.parent.exports) do
            if exportName ~= ast.InternalSymbolNameExportStar then
                local idx = -1
                for i, s in ipairs(allExports) do
                    if s == namedExport then
                        idx = i - 1
                        break
                    end
                end
                if idx >= 0 then
                    table.remove(allExports, idx + 1)
                elseif autoimport.shouldIgnoreSymbol(namedExport) then
                    -- Go: slices.Delete(allExports, -1, 0) panics; not reachable in practice.
                    error("slice bounds out of range [-1:]", 0)
                end
            end
        end

        for _, reexportedSymbol in ipairs(allExports) do
            local export = self:createExport(reexportedSymbol, moduleID, moduleFileName, ExportSyntax.Star, file, lease)
            if export ~= nil then
                local parent = lease:GetChecker():GetMergedSymbol(reexportedSymbol.parent)
                if parent ~= nil and parent:IsExternalModule() then
                    local targetModuleID, ok = self:getModuleIDForSymbol(parent)
                    if ok then
                        export.target = autoimport.ExportID_new(targetModuleID, reexportedSymbol.name)
                    end
                end
                export.through = ast.InternalSymbolNameExportStar
                exports[#exports + 1] = export
            end
        end
        return
    end

    local syntax = autoimport.getSyntax(symbol)
    local lease = autoimport.newCheckerLease(self.checker)
    local export, target = self:createExport(symbol, moduleID, moduleFileName, syntax, file, lease)
    if export == nil then
        return
    end

    exports[#exports + 1] = export

    if target ~= nil then
        if syntax == ExportSyntax.Equals and target.flags & SymbolFlags.Namespace ~= 0 then
            for innerName, namedExport in sortedSymbols(target.exports) do
                if innerName ~= ast.InternalSymbolNameExportStar then
                    local innerExport = self:createExport(namedExport, moduleID, moduleFileName, syntax, file, lease)
                    if innerExport ~= nil then
                        innerExport.through = name
                        exports[#exports + 1] = innerExport
                    end
                end
            end
        end
    elseif syntax == ExportSyntax.CommonJSModuleExports then
        local expression = symbol.declarations[1]:AsBinaryExpression().right
        if expression.kind == Kind.ObjectLiteralExpression then
            -- what is actually desirable here? I think it would be reasonable to only treat these as exports
            -- if *every* property is a shorthand property or identifier: identifier
            -- At least, it would be sketchy if there were any methods, computed properties...
            for _, prop in ipairs(expression:AsObjectLiteralExpression().properties.nodes) do
                if ast.IsShorthandPropertyAssignment(prop) or ast.IsPropertyAssignment(prop) and prop:AsPropertyAssignment():Name().kind == Kind.Identifier then
                    local propExport = self:createExport(expression:Symbol().members[prop:Name():Text()], moduleID, moduleFileName, syntax, file, lease)
                    if propExport ~= nil then
                        propExport.through = name
                        exports[#exports + 1] = propExport
                    end
                end
            end
        end
    end
end

-- createExport creates an Export for the given symbol, returning the Export and the target symbol if the export is an alias.
function symbolExtractor:createExport(symbol, moduleID, moduleFileName, syntax, file, lease)
    if autoimport.shouldIgnoreSymbol(symbol) then
        return nil, nil
    end

    local export = autoimport.newExport({
        exportName = symbol.name,
        moduleID = moduleID,
        moduleFileName = moduleFileName,
        syntax = syntax,
        flags = symbol:CombinedLocalAndExportSymbolFlags(),
        path = file:Path(),
        packageName = self.packageName,
    })

    if syntax == ExportSyntax.UMD then
        export.exportName = ast.InternalSymbolNameExportEquals
        export.localName = symbol.name
    end

    local targetSymbol = nil
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        targetSymbol = self:tryResolveSymbol(symbol, syntax, lease)
        if targetSymbol ~= nil then
            local decl = nil
            if core.Len(targetSymbol.declarations) > 0 then
                decl = targetSymbol.declarations[1]
            elseif targetSymbol.checkFlags & ast.CheckFlags.Mapped ~= 0 then
                local mappedDecl = lease:GetChecker():GetMappedTypeSymbolOfProperty(targetSymbol)
                if mappedDecl ~= nil and core.Len(mappedDecl.declarations) > 0 then
                    decl = mappedDecl.declarations[1]
                end
            end
            if decl == nil then
                -- !!! consider GetImmediateAliasedSymbol to go as far as we can
                decl = symbol.declarations[1]
            end
            if decl == nil then
                error("no declaration for aliased symbol", 0)
            end

            local parent = targetSymbol.parent
            local ch = lease:TryChecker()
            if ch ~= nil then
                export.flags = ch:GetSymbolFlags(targetSymbol)
                export.isTypeOnly = ch:GetTypeOnlyAliasDeclaration(symbol) ~= nil
                parent = ch:GetMergedSymbol(parent)
            else
                export.flags = targetSymbol.flags
                export.isTypeOnly = core.Some(symbol.declarations, ast.IsPartOfTypeOnlyImportOrExportDeclaration)
            end
            export.scriptElementKind = lsutil.GetSymbolKind(lease:TryChecker(), targetSymbol, decl)
            export.scriptElementKindModifiers = lsutil.GetSymbolModifiers(lease:TryChecker(), targetSymbol)
            local targetModuleID = ast.GetSourceFileOfNode(decl):Path()
            if parent ~= nil and parent:IsExternalModule() then
                local id, ok = self:getModuleIDForSymbol(parent)
                if ok then
                    targetModuleID = id
                end
            end
            export.target = autoimport.ExportID_new(targetModuleID, targetSymbol.name)
        end
    else
        export.scriptElementKind = lsutil.GetSymbolKind(lease:TryChecker(), symbol, symbol.declarations[1])
        export.scriptElementKindModifiers = lsutil.GetSymbolModifiers(lease:TryChecker(), symbol)
    end

    if symbol.name == ast.InternalSymbolNameDefault or symbol.name == ast.InternalSymbolNameExportEquals then
        local namedSymbol = symbol
        local s = binder.GetLocalSymbolForExportDefault(symbol)
        if s ~= nil then
            namedSymbol = s
        end
        export.localName = autoimport.getDefaultLikeExportNameFromDeclaration(namedSymbol)
        if autoimport.isUnusableName(export.localName) then
            export.localName = export.target.exportName
        end
        if autoimport.isUnusableName(export.localName) then
            if targetSymbol ~= nil then
                namedSymbol = targetSymbol
                s = binder.GetLocalSymbolForExportDefault(targetSymbol)
                if s ~= nil then
                    namedSymbol = s
                end
                export.localName = autoimport.getDefaultLikeExportNameFromDeclaration(namedSymbol)
            end
        end
        if autoimport.isUnusableName(export.localName) then
            -- Last resort: derive identifier from the file name. Use FileName() (original
            -- casing) rather than ModuleID/Path() which is lowercased on case-insensitive
            -- file systems, losing PascalCase.
            export.localName = lsutil.ModuleSpecifierToValidIdentifier(autoimport.fileNameForDefaultExportName(targetSymbol, moduleFileName, moduleID), false)
        end
    end

    if autoimport.isUnusableName(export:Name()) then
        return nil, nil
    end

    self.stats.exports = self.stats.exports + 1
    if lease:TryChecker() ~= nil then
        self.stats.usedChecker = self.stats.usedChecker + 1
    end

    return export, targetSymbol
end

function symbolExtractor:tryResolveSymbol(symbol, syntax, lease)
    if not ast.IsNonLocalAlias(symbol, SymbolFlags.None) then
        return symbol
    end

    local loc = nil
    local name = ""
    if syntax == ExportSyntax.Named then
        local decl = ast.GetDeclarationOfKind(symbol, Kind.ExportSpecifier)
        if decl.parent.parent:AsExportDeclaration().moduleSpecifier == nil then
            local n = core.FirstNonZero(decl:Name(), decl:PropertyName())
            if n.kind == Kind.Identifier then
                loc = n
                name = n:Text()
            end
        end
    -- !!! check if module.exports = foo is marked as an alias
    elseif (syntax == ExportSyntax.Equals and symbol.name == ast.InternalSymbolNameExportEquals) or syntax == ExportSyntax.DefaultDeclaration then
        local decl = ast.GetDeclarationOfKind(symbol, Kind.ExportAssignment)
        if decl:Expression().kind == Kind.Identifier then
            loc = decl:Expression()
            name = loc:Text()
        end
    end

    if loc ~= nil then
        local localSymbol = self.localNameResolver:Resolve(loc, name, SymbolFlags.All, nil, false, false)
        if localSymbol ~= nil and not ast.IsNonLocalAlias(localSymbol, SymbolFlags.None) then
            return localSymbol
        end
    end

    local ch = lease:GetChecker()
    local resolved = ch:GetAliasedSymbol(symbol)
    if not ch:IsUnknownSymbol(resolved) then
        return resolved
    end
    return nil
end

function autoimport.shouldIgnoreSymbol(symbol)
    if symbol.flags & SymbolFlags.Prototype ~= 0 then
        return true
    end
    return false
end

function autoimport.getSyntax(symbol)
    for _, decl in ipairs(symbol.declarations or {}) do
        local kind = decl.kind
        if kind == Kind.ExportSpecifier then
            return ExportSyntax.Named
        elseif kind == Kind.ExportAssignment then
            return core.IfElse(
                decl:AsExportAssignment().isExportEquals,
                ExportSyntax.Equals,
                ExportSyntax.DefaultDeclaration
            )
        elseif kind == Kind.NamespaceExportDeclaration then
            return ExportSyntax.UMD
        elseif kind == Kind.BinaryExpression then
            local assignmentKind = ast.GetAssignmentDeclarationKind(decl)
            if assignmentKind == ast.JSDeclarationKind.ModuleExports then
                return ExportSyntax.CommonJSModuleExports
            elseif assignmentKind == ast.JSDeclarationKind.ExportsProperty then
                return ExportSyntax.CommonJSExportsProperty
            end
        else
            if ast.GetCombinedModifierFlags(decl) & ast.ModifierFlags.Default ~= 0 then
                return ExportSyntax.DefaultModifier
            else
                return ExportSyntax.Modifier
            end
        end
    end
    return ExportSyntax.None
end

function autoimport.isUnusableName(name)
    return name == "" or
        name == "_default" or
        name == ast.InternalSymbolNameExportStar or
        name == ast.InternalSymbolNameDefault or
        name == ast.InternalSymbolNameExportEquals
end

-- fileNameForDefaultExportName returns the best file name to use when deriving
-- a fallback identifier for a default-like export. It prefers the target symbol's
-- source file (closest to the export origin), falls back to the module's original
-- file name, and uses the lowercased moduleID only for ambient modules where no
-- original file name is available.
function autoimport.fileNameForDefaultExportName(targetSymbol, moduleFileName, moduleID)
    if targetSymbol ~= nil and core.Len(targetSymbol.declarations) > 0 then
        local fn = ast.GetSourceFileOfNode(targetSymbol.declarations[1]):FileName()
        if fn ~= "" then
            return fn
        end
    end
    if moduleFileName ~= "" then
        return moduleFileName
    end
    return moduleID
end
