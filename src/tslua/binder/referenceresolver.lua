local binder = require("tslua.binder")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags

-- ReferenceResolver (Go interface) methods: GetReferencedExportContainer(node, prefixLocals),
-- GetReferencedImportDeclaration(node), GetReferencedValueDeclaration(node),
-- GetReferencedValueDeclarations(node), GetElementAccessExpressionName(expression),
-- GetReferencedMemberValueDeclaration(node).
--
-- ReferenceResolverHooks is a plain table with optional function fields (called without self):
-- resolveName(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals) -> symbol
-- getResolvedSymbol(node) -> symbol
-- getMergedSymbol(symbol) -> symbol
-- getParentOfSymbol(symbol) -> symbol
-- getSymbolOfDeclaration(declaration) -> symbol
-- getTypeOnlyAliasDeclaration(symbol, include) -> declaration
-- getExportSymbolOfValueSymbolIfExported(symbol) -> symbol
-- getElementAccessExpressionName(expression) -> name, ok

local referenceResolver = {}
referenceResolver.__index = referenceResolver
binder.referenceResolver = referenceResolver

function binder.NewReferenceResolver(options, hooks)
    return setmetatable({
        resolver = nil,
        options = options,
        hooks = hooks or {},
    }, referenceResolver)
end

function referenceResolver:getResolvedSymbol(node)
    if node ~= nil then
        if self.hooks.getResolvedSymbol ~= nil then
            return self.hooks.getResolvedSymbol(node)
        end
    end
    return nil
end

function referenceResolver:getMergedSymbol(symbol)
    if symbol ~= nil then
        if self.hooks.getMergedSymbol ~= nil then
            return self.hooks.getMergedSymbol(symbol)
        end
        return symbol
    end
    return nil
end

function referenceResolver:getParentOfSymbol(symbol)
    if symbol ~= nil then
        if self.hooks.getParentOfSymbol ~= nil then
            return self.hooks.getParentOfSymbol(symbol)
        end
        return symbol.parent
    end
    return nil
end

function referenceResolver:getSymbolOfDeclaration(declaration)
    if declaration ~= nil then
        if self.hooks.getSymbolOfDeclaration ~= nil then
            return self.hooks.getSymbolOfDeclaration(declaration)
        end
        return declaration:Symbol()
    end
    return nil
end

function referenceResolver:getReferencedValueSymbol(reference, startInDeclarationContainer)
    local resolvedSymbol = self:getResolvedSymbol(reference)
    if resolvedSymbol ~= nil then
        return resolvedSymbol
    end

    local location = reference
    if startInDeclarationContainer and reference.parent ~= nil and ast.IsDeclaration(reference.parent) and reference.parent:Name() == reference then
        location = ast.GetDeclarationContainer(reference.parent)
    end

    if self.hooks.resolveName ~= nil then
        return self.hooks.resolveName(location, reference:Text(), SymbolFlags.ExportValue | SymbolFlags.Value | SymbolFlags.Alias, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]])
    end

    if self.resolver == nil then
        self.resolver = setmetatable({
            compilerOptions = self.options,
        }, binder.NameResolver)
    end

    return self.resolver:Resolve(location, reference:Text(), SymbolFlags.ExportValue | SymbolFlags.Value | SymbolFlags.Alias, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]])
end

function referenceResolver:isTypeOnlyAliasDeclaration(symbol)
    if symbol ~= nil then
        if self.hooks.getTypeOnlyAliasDeclaration ~= nil then
            return self.hooks.getTypeOnlyAliasDeclaration(symbol, SymbolFlags.Value) ~= nil
        end

        local node = self:getDeclarationOfAliasSymbol(symbol)
        while node ~= nil do
            local kind = node.kind
            if kind == Kind.ImportEqualsDeclaration or kind == Kind.ExportDeclaration then
                return node:IsTypeOnly()
            elseif kind == Kind.ImportClause or kind == Kind.ImportSpecifier or kind == Kind.ExportSpecifier then
                if node:IsTypeOnly() then
                    return true
                end
                node = node.parent
            elseif kind == Kind.NamedImports or kind == Kind.NamedExports then
                node = node.parent
            else
                break
            end
        end
    end
    return false
end

function referenceResolver:getDeclarationOfAliasSymbol(symbol)
    return core.FindLast(symbol.declarations, ast.IsAliasSymbolDeclaration)
end

function referenceResolver:getExportSymbolOfValueSymbolIfExported(symbol)
    if symbol ~= nil then
        if self.hooks.getExportSymbolOfValueSymbolIfExported ~= nil then
            return self.hooks.getExportSymbolOfValueSymbolIfExported(symbol)
        end
        if symbol.flags & SymbolFlags.ExportValue ~= 0 and symbol.exportSymbol ~= nil then
            symbol = symbol.exportSymbol
        end
        return self:getMergedSymbol(symbol)
    end
    return nil
end

function referenceResolver:GetReferencedExportContainer(node, prefixLocals) --[[SourceFile|ModuleDeclaration|EnumDeclaration]]
    -- When resolving the export for the name of a module or enum
    -- declaration, we need to start resolution at the declaration's container.
    -- Otherwise, we could incorrectly resolve the export as the
    -- declaration if it contains an exported member with the same name.
    local startInDeclarationContainer = node.parent ~= nil and (node.parent.kind == Kind.ModuleDeclaration or node.parent.kind == Kind.EnumDeclaration) and node == node.parent:Name()
    local symbol = self:getReferencedValueSymbol(node, startInDeclarationContainer)
    if symbol ~= nil then
        if symbol.flags & SymbolFlags.ExportValue ~= 0 then
            -- If we reference an exported entity within the same module declaration, then whether
            -- we prefix depends on the kind of entity. SymbolFlags.ExportHasLocal encompasses all the
            -- kinds that we do NOT prefix.
            local exportSymbol = self:getMergedSymbol(symbol.exportSymbol)
            if not prefixLocals and exportSymbol.flags & SymbolFlags.ExportHasLocal ~= 0 and exportSymbol.flags & SymbolFlags.Variable == 0 then
                return nil
            end
            symbol = exportSymbol
        end
        local parentSymbol = self:getParentOfSymbol(symbol)
        if parentSymbol ~= nil then
            if parentSymbol.flags & SymbolFlags.ValueModule ~= 0 and parentSymbol.valueDeclaration ~= nil and parentSymbol.valueDeclaration.kind == Kind.SourceFile then
                local symbolFile = parentSymbol.valueDeclaration
                local referenceFile = ast.GetSourceFileOfNode(node)
                -- If `node` accesses an export and that export isn't in the same file, then symbol is a namespace export, so return nil.
                local symbolIsUmdExport = symbolFile ~= referenceFile
                if symbolIsUmdExport then
                    return nil
                end
                return symbolFile
            end
            local isMatchingContainer = function(n)
                return (n.kind == Kind.ModuleDeclaration or n.kind == Kind.EnumDeclaration) and self:getSymbolOfDeclaration(n) == parentSymbol
            end
            return ast.FindAncestor(node.parent, isMatchingContainer)
        end
    end

    return nil
end

function referenceResolver:GetReferencedImportDeclaration(node)
    local symbol = self:getReferencedValueSymbol(node, false --[[startInDeclarationContainer]])
    if symbol ~= nil then
        -- We should only get the declaration of an alias if there isn't a local value
        -- declaration for the symbol
        if ast.IsNonLocalAlias(symbol, SymbolFlags.Value --[[excludes]]) and not self:isTypeOnlyAliasDeclaration(symbol) then
            return self:getDeclarationOfAliasSymbol(symbol)
        end
    end

    return nil
end

function referenceResolver:GetReferencedValueDeclaration(node)
    local symbol = self:getReferencedValueSymbol(node, false --[[startInDeclarationContainer]])
    if symbol ~= nil then
        return self:getExportSymbolOfValueSymbolIfExported(symbol).valueDeclaration
    end
    return nil
end

local valueDeclarationKinds = {
    [Kind.VariableDeclaration] = true,
    [Kind.Parameter] = true,
    [Kind.BindingElement] = true,
    [Kind.PropertyDeclaration] = true,
    [Kind.PropertyAssignment] = true,
    [Kind.ShorthandPropertyAssignment] = true,
    [Kind.EnumMember] = true,
    [Kind.ObjectLiteralExpression] = true,
    [Kind.FunctionDeclaration] = true,
    [Kind.FunctionExpression] = true,
    [Kind.ArrowFunction] = true,
    [Kind.ClassDeclaration] = true,
    [Kind.ClassExpression] = true,
    [Kind.EnumDeclaration] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.GetAccessor] = true,
    [Kind.SetAccessor] = true,
    [Kind.ModuleDeclaration] = true,
}

function referenceResolver:GetReferencedValueDeclarations(node)
    local declarations
    local symbol = self:getReferencedValueSymbol(node, false --[[startInDeclarationContainer]])
    if symbol ~= nil then
        symbol = self:getExportSymbolOfValueSymbolIfExported(symbol)
        for _, declaration in ipairs(symbol.declarations or {}) do
            if valueDeclarationKinds[declaration.kind] then
                declarations = declarations or {}
                declarations[#declarations + 1] = declaration
            end
        end
    end
    return declarations
end

function referenceResolver:GetElementAccessExpressionName(expression)
    if expression ~= nil then
        if self.hooks.getElementAccessExpressionName ~= nil then
            local name, ok = self.hooks.getElementAccessExpressionName(expression)
            if ok then
                return name
            end
        end
    end
    return ""
end

function referenceResolver:GetReferencedMemberValueDeclaration(node)
    -- member references are `this.something` or `this[something]`, so should always simply have a resolved symbol
    local s = self:getResolvedSymbol(node)
    if s == nil and node:Symbol() ~= nil then
        -- might be a declaration instead of a ref, get the merged declaration symbol
        s = self:getMergedSymbol(node:Symbol())
    end
    if s == nil then
        return nil
    end
    return self:getExportSymbolOfValueSymbolIfExported(s).valueDeclaration
end
