local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local printer = require("tslua.printer")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local SymbolFormatFlags = checker.SymbolFormatFlags
local SymbolFlags = ast.SymbolFlags
local Kind = ast.Kind
local SymbolAccessibility = printer.SymbolAccessibility

-- Go slices.Contains
local function slicesContains(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

-- SymbolAccessibilityResult value with Go zero values filled in.
local function newResult(accessibility, errorSymbolName, errorNode, errorModuleName)
    return {
        accessibility = accessibility,
        aliasesToMakeVisible = nil,
        errorSymbolName = errorSymbolName or "",
        errorNode = errorNode,
        errorModuleName = errorModuleName or "",
    }
end

function Checker:IsTypeSymbolAccessible(typeSymbol, enclosingDeclaration)
    local access = self:isSymbolAccessibleWorker(typeSymbol, enclosingDeclaration, SymbolFlags.Type, false --[[shouldComputeAliasesToMakeVisible]], true --[[allowModules]])
    return access.accessibility == SymbolAccessibility.Accessible
end

function Checker:IsValueSymbolAccessible(symbol, enclosingDeclaration)
    local access = self:isSymbolAccessibleWorker(symbol, enclosingDeclaration, SymbolFlags.Value, false --[[shouldComputeAliasesToMakeVisible]], true --[[allowModules]])
    return access.accessibility == SymbolAccessibility.Accessible
end

function Checker:IsSymbolAccessibleByFlags(symbol, enclosingDeclaration, flags)
    local access = self:isSymbolAccessibleWorker(symbol, enclosingDeclaration, flags, false --[[shouldComputeAliasesToMakeVisible]], false --[[allowModules]]) -- TODO: Strada bug? Why is this allowModules: false?
    return access.accessibility == SymbolAccessibility.Accessible
end

function Checker:IsAnySymbolAccessible(symbols, enclosingDeclaration, initialSymbol, meaning, shouldComputeAliasesToMakeVisible, allowModules)
    if core.Len(symbols) == 0 then
        return nil
    end

    local hadAccessibleChain
    local earlyModuleBail = false
    for _, symbol in ipairs(symbols) do
        -- Symbol is accessible if it by itself is accessible
        local accessibleSymbolChain = self:getAccessibleSymbolChain(symbol, enclosingDeclaration, meaning, false --[[useOnlyExternalAliasing]])
        if core.Len(accessibleSymbolChain) > 0 then
            hadAccessibleChain = symbol
            -- TODO: going through emit resolver here is weird. Relayer these APIs.
            local hasAccessibleDeclarations = self:GetEmitResolver():hasVisibleDeclarations(accessibleSymbolChain[1], shouldComputeAliasesToMakeVisible)
            if hasAccessibleDeclarations ~= nil then
                return hasAccessibleDeclarations
            end
        end
        if allowModules then
            if core.Some(symbol.declarations, function(d) return checker.hasNonGlobalAugmentationExternalModuleSymbol(d) end) then
                if shouldComputeAliasesToMakeVisible then
                    earlyModuleBail = true
                    -- Generally speaking, we want to use the aliases that already exist to refer to a module, if present
                    -- In order to do so, we need to find those aliases in order to retain them in declaration emit; so
                    -- if we are in declaration emit, we cannot use the fast path for module visibility until we've exhausted
                    -- all other visibility options (in order to capture the possible aliases used to reference the module)
                    goto continue
                end
                -- Any meaning of a module symbol is always accessible via an `import` type
                return newResult(SymbolAccessibility.Accessible)
            end
        end

        -- If we haven't got the accessible symbol, it doesn't mean the symbol is actually inaccessible.
        -- It could be a qualified symbol and hence verify the path
        -- e.g.:
        -- module m {
        --     export class c {
        --     }
        -- }
        -- const x: typeof m.c
        -- In the above example when we start with checking if typeof m.c symbol is accessible,
        -- we are going to see if c can be accessed in scope directly.
        -- But it can't, hence the accessible is going to be undefined, but that doesn't mean m.c is inaccessible
        -- It is accessible if the parent m is accessible because then m.c can be accessed through qualification

        do
            local containers = self:getContainersOfSymbol(symbol, enclosingDeclaration, meaning)
            local nextMeaning = meaning
            if initialSymbol == symbol then
                nextMeaning = checker.getQualifiedLeftMeaning(meaning)
            end
            local parentResult = self:IsAnySymbolAccessible(containers, enclosingDeclaration, initialSymbol, nextMeaning, shouldComputeAliasesToMakeVisible, allowModules)
            if parentResult ~= nil then
                return parentResult
            end
        end
        ::continue::
    end

    if earlyModuleBail then
        return newResult(SymbolAccessibility.Accessible)
    end

    if hadAccessibleChain ~= nil then
        local moduleName = ""
        if hadAccessibleChain ~= initialSymbol then
            moduleName = self:symbolToStringEx(hadAccessibleChain, enclosingDeclaration, SymbolFlags.Namespace, SymbolFormatFlags.AllowAnyNodeKind)
        end
        return newResult(
            SymbolAccessibility.NotAccessible,
            self:symbolToStringEx(initialSymbol, enclosingDeclaration, meaning, SymbolFormatFlags.AllowAnyNodeKind),
            nil,
            moduleName
        )
    end
    return nil
end

function checker.hasNonGlobalAugmentationExternalModuleSymbol(declaration)
    return ast.IsModuleWithStringLiteralName(declaration) or (declaration.kind == Kind.SourceFile and ast.IsExternalOrCommonJSModule(declaration:AsSourceFile()))
end

function checker.getQualifiedLeftMeaning(rightMeaning)
    -- If we are looking in value space, the parent meaning is value, other wise it is namespace
    if rightMeaning == SymbolFlags.Value then
        return SymbolFlags.Value
    end
    return SymbolFlags.Namespace
end

function Checker:getWithAlternativeContainers(container, symbol, enclosingDeclaration, meaning)
    local additionalContainers = core.MapNonNil(container.declarations, function(d)
        return self:getFileSymbolIfFileSymbolExportEqualsContainer(d, container)
    end)
    local reexportContainers
    if enclosingDeclaration ~= nil then
        reexportContainers = self:getAlternativeContainingModules(symbol, enclosingDeclaration)
    end
    local objectLiteralContainer = self:getVariableDeclarationOfObjectLiteral(container, meaning)
    local leftMeaning = checker.getQualifiedLeftMeaning(meaning)
    if enclosingDeclaration ~= nil and
        container.flags & leftMeaning ~= 0 and
        core.Len(self:getAccessibleSymbolChain(container, enclosingDeclaration, SymbolFlags.Namespace, false --[[useOnlyExternalAliasing]])) > 0 then
        -- This order expresses a preference for the real container if it is in scope
        local res = { container }
        core.AppendAll(res, additionalContainers)
        core.AppendAll(res, reexportContainers)
        if objectLiteralContainer ~= nil then
            res[#res + 1] = objectLiteralContainer
        end
        return res
    end
    -- we potentially have a symbol which is a member of the instance side of something - look for a variable in scope with the container's type
    -- which may be acting like a namespace (eg, `Symbol` acts like a namespace when looking up `Symbol.toStringTag`)
    local variableMatches
    if (meaning == SymbolFlags.Value and
            container.flags & leftMeaning == 0) and
        container.flags & SymbolFlags.Type ~= 0 and
        self:getDeclaredTypeOfSymbol(container).flags & TypeFlags.Object ~= 0 then
        self:someSymbolTableInScope(enclosingDeclaration, function(t, _, _, _, _)
            local found = false
            for _, s in pairs(t) do
                if s.flags & leftMeaning ~= 0 and self:getTypeOfSymbol(s) == self:getDeclaredTypeOfSymbol(container) then
                    variableMatches = core.Append(variableMatches, s)
                    found = true
                end
            end
            return found
        end)
        self:sortSymbols(variableMatches)
    end

    local res = {}
    core.AppendAll(res, variableMatches)
    core.AppendAll(res, additionalContainers)
    res[#res + 1] = container
    if objectLiteralContainer ~= nil then
        res[#res + 1] = objectLiteralContainer
    end
    core.AppendAll(res, reexportContainers)
    return res
end

function Checker:getAlternativeContainingModules(symbol, enclosingDeclaration)
    if enclosingDeclaration == nil then
        return nil
    end
    local containingFile = ast.GetSourceFileOfNode(enclosingDeclaration)
    local id = ast.GetNodeId(containingFile:AsNode())
    local links = self.symbolContainerLinks:Get(symbol)
    if links.extendedContainersByFile == nil then
        links.extendedContainersByFile = {}
    end
    local existing = links.extendedContainersByFile[id]
    if existing ~= nil then
        return existing
    end
    local results
    if core.Len(containingFile:Imports()) > 0 then
        -- Try to make an import using an import already in the enclosing file, if possible
        for _, importRef in ipairs(containingFile:Imports()) do
            if ast.NodeIsSynthesized(importRef) then
                -- Synthetic names can't be resolved by `resolveExternalModuleName` - they'll cause a debug assert if they error
                goto continue
            end
            do
                local resolvedModule = self:resolveExternalModuleName(enclosingDeclaration, importRef, true --[[ignoreErrors]])
                if resolvedModule == nil then
                    goto continue
                end
                local ref = self:getAliasForSymbolInContainer(resolvedModule, symbol)
                if ref == nil then
                    goto continue
                end
                results = core.Append(results, resolvedModule)
            end
            ::continue::
        end
        if core.Len(results) > 0 then
            links.extendedContainersByFile[id] = results
            return results
        end
    end

    -- Go stores a pointer to the (possibly nil) slice; Lua stores the slice, using {} for nil.
    if links.extendedContainers ~= nil then
        return links.extendedContainers
    end
    -- No results from files already being imported by this file - expand search (expensive, but not location-specific, so cached)
    local otherFiles = self.program:SourceFiles()
    for _, file in ipairs(otherFiles or {}) do
        if not ast.IsExternalModule(file) then
            goto continue
        end
        do
            local sym = self:getSymbolOfDeclaration(file:AsNode())
            local ref = self:getAliasForSymbolInContainer(sym, symbol)
            if ref == nil then
                goto continue
            end
            results = core.Append(results, sym)
        end
        ::continue::
    end
    links.extendedContainers = results or {}
    return results
end

function Checker:getVariableDeclarationOfObjectLiteral(symbol, meaning)
    -- If we're trying to reference some object literal in, eg `var a = { x: 1 }`, the symbol for the literal, `__object`, is distinct
    -- from the symbol of the declaration it is being assigned to. Since we can use the declaration to refer to the literal, however,
    -- we'd like to make that connection here - potentially causing us to paint the declaration's visibility, and therefore the literal.
    if meaning & SymbolFlags.Value == 0 then
        return nil
    end
    if core.Len(symbol.declarations) == 0 then
        return nil
    end
    local firstDecl = symbol.declarations[1]
    if firstDecl.parent == nil then
        return nil
    end
    if not ast.IsVariableDeclaration(firstDecl.parent) then
        return nil
    end
    if ast.IsObjectLiteralExpression(firstDecl) and firstDecl == firstDecl.parent:Initializer() or ast.IsTypeLiteralNode(firstDecl) and firstDecl == firstDecl.parent:Type() then
        return self:getSymbolOfDeclaration(firstDecl.parent)
    end
    return nil
end

function checker.hasExternalModuleSymbol(declaration)
    return ast.IsAmbientModule(declaration) or (declaration.kind == Kind.SourceFile and ast.IsExternalOrCommonJSModule(declaration:AsSourceFile()))
end

function Checker:getExternalModuleContainer(declaration)
    local node = ast.FindAncestor(declaration, function(n) return checker.hasExternalModuleSymbol(n) end)
    if node == nil then
        return nil
    end
    return self:getSymbolOfDeclaration(node)
end

function Checker:getFileSymbolIfFileSymbolExportEqualsContainer(d, container)
    local fileSymbol = self:getExternalModuleContainer(d)
    if fileSymbol == nil or fileSymbol.exports == nil then
        return nil
    end
    local exported = fileSymbol.exports[ast.InternalSymbolNameExportEquals]
    if exported == nil then
        return nil
    end
    if self:getSymbolIfSameReference(exported, container) ~= nil then
        return fileSymbol
    end
    return nil
end

--[[*
* Attempts to find the symbol corresponding to the container a symbol is in - usually this
* is just its' `.parent`, but for locals, this value is `undefined`
 ]]
function Checker:getContainersOfSymbol(symbol, enclosingDeclaration, meaning)
    local container = self:getParentOfSymbol(symbol)
    -- Type parameters end up in the `members` lists but are not externally visible
    if container ~= nil and (symbol.flags & SymbolFlags.TypeParameter == 0) then
        return self:getWithAlternativeContainers(container, symbol, enclosingDeclaration, meaning)
    end
    local candidates
    for _, d in ipairs(symbol.declarations or {}) do
        if not ast.IsAmbientModule(d) and d.parent ~= nil then
            -- direct children of a module
            if checker.hasNonGlobalAugmentationExternalModuleSymbol(d.parent) then
                local sym = self:getSymbolOfDeclaration(d.parent)
                if sym ~= nil and not slicesContains(candidates, sym) then
                    candidates = core.Append(candidates, sym)
                end
                goto continue
            end
            -- export ='d member of an ambient module
            if ast.IsModuleBlock(d.parent) and d.parent.parent ~= nil and self:resolveExternalModuleSymbol(self:getSymbolOfDeclaration(d.parent.parent), false) == symbol then
                local sym = self:getSymbolOfDeclaration(d.parent.parent)
                if sym ~= nil and not slicesContains(candidates, sym) then
                    candidates = core.Append(candidates, sym)
                end
                goto continue
            end
        end
        if ast.IsClassExpression(d) and ast.IsBinaryExpression(d.parent) and d.parent:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken and ast.IsAccessExpression(d.parent:AsBinaryExpression().left) and ast.IsEntityNameExpression(d.parent:AsBinaryExpression().left:Expression()) then
            if ast.IsModuleExportsAccessExpression(d.parent:AsBinaryExpression().left) or ast.IsExportsIdentifier(d.parent:AsBinaryExpression().left:Expression()) then
                local sym = self:getSymbolOfDeclaration(ast.GetSourceFileOfNode(d):AsNode())
                if sym ~= nil and not slicesContains(candidates, sym) then
                    candidates = core.Append(candidates, sym)
                end
                goto continue
            end
            self:checkExpressionCached(d.parent:AsBinaryExpression().left:Expression())
            local sym = self.symbolNodeLinks:Get(d.parent:AsBinaryExpression().left:Expression()).resolvedSymbol
            if sym ~= nil and not slicesContains(candidates, sym) then
                candidates = core.Append(candidates, sym)
            end
            goto continue
        end
        ::continue::
    end
    if core.Len(candidates) == 0 then
        return nil
    end

    local bestContainers
    local alternativeContainers
    for _, c in ipairs(candidates) do
        if self:getAliasForSymbolInContainer(c, symbol) == nil then
            goto continue
        end
        do
            local allAlts = self:getWithAlternativeContainers(c, symbol, enclosingDeclaration, meaning)
            if core.Len(allAlts) == 0 then
                goto continue
            end
            bestContainers = core.Append(bestContainers, allAlts[1])
            for i = 2, #allAlts do
                alternativeContainers = core.Append(alternativeContainers, allAlts[i])
            end
        end
        ::continue::
    end
    local result = bestContainers
    if alternativeContainers ~= nil then
        result = core.AppendAll(result or {}, alternativeContainers)
    end
    return result
end

function Checker:getAliasForSymbolInContainer(container, symbol)
    if container == self:getParentOfSymbol(symbol) then
        -- fast path, `symbol` is either already the alias or isn't aliased
        return symbol
    end
    -- Check if container is a thing with an `export=` which points directly at `symbol`, and if so, return
    -- the container itself as the alias for the symbol
    if container.exports ~= nil then
        local exportEquals = container.exports[ast.InternalSymbolNameExportEquals]
        if exportEquals ~= nil and self:getSymbolIfSameReference(exportEquals, symbol) ~= nil then
            return container
        end
    end
    local exports = self:getExportsOfSymbol(container)
    local quick = exports ~= nil and exports[symbol.name] or nil
    if quick ~= nil and self:getSymbolIfSameReference(quick, symbol) ~= nil then
        return quick
    end
    local candidates
    for _, exported in pairs(exports or {}) do
        if self:getSymbolIfSameReference(exported, symbol) ~= nil then
            candidates = core.Append(candidates, exported)
        end
    end
    if core.Len(candidates) > 0 then
        self:sortSymbols(candidates) -- _must_ sort exports for stable results - symbol table is randomly iterated
        return candidates[1]
    end
    return nil
end

-- accessibleSymbolChainContext is a plain table
-- { symbol, enclosingDeclaration, meaning, useOnlyExternalAliasing, visitedSymbolTablesMap }.
local function newAccessibleSymbolChainContext(symbol, enclosingDeclaration, meaning, useOnlyExternalAliasing, visitedSymbolTablesMap)
    return {
        symbol = symbol,
        enclosingDeclaration = enclosingDeclaration,
        meaning = meaning,
        useOnlyExternalAliasing = useOnlyExternalAliasing,
        visitedSymbolTablesMap = visitedSymbolTablesMap,
    }
end

function Checker:getAccessibleSymbolChain(symbol, enclosingDeclaration, meaning, useOnlyExternalAliasing)
    return self:getAccessibleSymbolChainEx(newAccessibleSymbolChainContext(symbol, enclosingDeclaration, meaning, useOnlyExternalAliasing, {}))
end

function Checker:GetAccessibleSymbolChain(symbol, enclosingDeclaration, meaning, useOnlyExternalAliasing)
    return self:getAccessibleSymbolChain(symbol, enclosingDeclaration, meaning, useOnlyExternalAliasing)
end

-- symbolTableID uniquely identifies a symbol table by encoding its source.
-- The high 3 bits encode the kind, and the remaining bits encode the
-- NodeId or SymbolId of the source. (A Lua integer; Go's uint64 bit patterns are kept.)

checker.stKindShift = 61

checker.stKindLocals = 0 << checker.stKindShift
checker.stKindExports = 1 << checker.stKindShift
checker.stKindMembers = 2 << checker.stKindShift
checker.stKindGlobals = 3 << checker.stKindShift
checker.stKindResolvedExports = 4 << checker.stKindShift -- resolved/derived exports from getExportsOfSymbol, distinct from raw sym.Exports

-- stKindMask extracts the kind bits from a symbolTableID.
checker.stKindMask = (5 - 1) << checker.stKindShift

function checker.symbolTableIDFromLocals(node)
    return checker.stKindLocals | ast.GetNodeId(node)
end

function checker.symbolTableIDFromExports(sym)
    return checker.stKindExports | ast.GetSymbolId(sym)
end

-- symbolTableIDFromResolvedExports returns an ID for resolved/derived export tables
-- (e.g. from getExportsOfSymbol/getExportsOfModule which may include export * resolution
-- and late-bound members). This is distinct from symbolTableIDFromExports to prevent
-- cache collisions with raw sym.Exports tables passed by someSymbolTableInScope.
function checker.symbolTableIDFromResolvedExports(sym)
    return checker.stKindResolvedExports | ast.GetSymbolId(sym)
end

function checker.symbolTableIDFromMembers(sym)
    return checker.stKindMembers | ast.GetSymbolId(sym)
end

function checker.symbolTableIDFromGlobals()
    return checker.stKindGlobals
end

function Checker:getAccessibleSymbolChainEx(ctx)
    if ctx.symbol == nil then
        return nil
    end
    if checker.isPropertyOrMethodDeclarationSymbol(ctx.symbol) then
        return nil
    end
    -- Go from enclosingDeclaration to the first scope we check, so the cache is keyed off the scope and thus shared more
    local firstRelevantLocation
    self:someSymbolTableInScope(ctx.enclosingDeclaration, function(_, _, _, _, node)
        firstRelevantLocation = node
        return true
    end)
    local links = self.symbolContainerLinks:Get(ctx.symbol)
    local linkKey = checker.accessibleChainCacheKey(ctx.useOnlyExternalAliasing, firstRelevantLocation, ctx.meaning)
    if links.accessibleChainCache == nil then
        links.accessibleChainCache = {}
    end
    -- A cached nil result is stored as false.
    local existing = links.accessibleChainCache[linkKey]
    if existing ~= nil then
        return existing or nil
    end

    local result

    self:someSymbolTableInScope(ctx.enclosingDeclaration, function(t, tableId, ignoreQualification, isLocalNameLookup, _)
        local res = self:getAccessibleSymbolChainFromSymbolTable(ctx, t, tableId, ignoreQualification, isLocalNameLookup)
        if core.Len(res) > 0 then
            result = res
            return true
        end
        return false
    end)
    links.accessibleChainCache[linkKey] = result or false
    return result
end

--[[*
* @param {ignoreQualification} boolean Set when a symbol is being looked for through the exports of another symbol (meaning we have a route to qualify it already)
 ]]
function Checker:getAccessibleSymbolChainFromSymbolTable(ctx, t, tableId, ignoreQualification, isLocalNameLookup)
    local symId = ast.GetSymbolId(ctx.symbol)
    local visitedSymbolTables = ctx.visitedSymbolTablesMap[symId]
    if visitedSymbolTables == nil then
        visitedSymbolTables = {}
        ctx.visitedSymbolTablesMap[symId] = visitedSymbolTables
    end

    if visitedSymbolTables[tableId] then
        return nil
    end
    visitedSymbolTables[tableId] = true

    local res = self:trySymbolTable(ctx, t, tableId, ignoreQualification, isLocalNameLookup)

    visitedSymbolTables[tableId] = nil
    return res
end

-- getSymbolTableAliases returns only the alias symbols from a symbol table,
-- caching the result by tableId to avoid repeated iteration over large tables.
-- Members tables are skipped entirely since someSymbolTableInScope filters them
-- to SymbolFlagsType & ^SymbolFlagsAssignment, which never includes aliases.
function Checker:getSymbolTableAliases(symbols, tableId)
    local kind = tableId & checker.stKindMask
    -- Members tables never contain alias symbols; skip entirely.
    if kind == checker.stKindMembers then
        return nil
    end
    local cacheable = kind == checker.stKindGlobals or kind == checker.stKindExports or kind == checker.stKindResolvedExports
    -- Cache globals and exports tables (which are large and revisited often).
    -- Locals tables are small and per-scope, so they are filtered but not cached.
    if cacheable then
        if self.symbolTableAliasCache ~= nil then
            -- A cached nil result is stored as false.
            local aliases = self.symbolTableAliasCache[tableId]
            if aliases ~= nil then
                return aliases or nil
            end
        end
    end
    local aliases
    for _, sym in pairs(symbols) do
        if sym.flags & SymbolFlags.Alias ~= 0 then
            aliases = core.Append(aliases, sym)
        end
    end
    if cacheable then
        if self.symbolTableAliasCache == nil then
            self.symbolTableAliasCache = {}
        end
        self.symbolTableAliasCache[tableId] = aliases or false
    end
    return aliases
end

function Checker:trySymbolTable(ctx, symbols, tableId, ignoreQualification, isLocalNameLookup)
    local isGlobals = tableId == checker.stKindGlobals
    -- If symbol is directly available by its name in the symbol table
    local res = symbols[ctx.symbol.name]
    if res ~= nil and self:isAccessible(ctx, res, nil --[[resolvedAliasSymbol]], ignoreQualification) then
        return { ctx.symbol }
    end

    local candidateChains = nil

    -- Check for ExportSymbol by direct name lookup rather than discovering it during
    -- the alias iteration below (where it would never match, since only alias-flagged
    -- symbols are iterated).
    if res ~= nil and res.exportSymbol ~= nil then
        if self:isAccessible(ctx, self:getMergedSymbol(res.exportSymbol), nil --[[resolvedAliasSymbol]], ignoreQualification) then
            candidateChains = core.Append(candidateChains, { ctx.symbol })
        end
    end

    -- Iterate only alias symbols from the table (cached per tableId).
    -- This avoids iterating thousands of non-alias symbols in large tables like globals.
    for _, symbolFromSymbolTable in ipairs(self:getSymbolTableAliases(symbols, tableId) or {}) do
        -- for every non-default, non-export= alias symbol in scope, check if it refers to or can chain to the target symbol
        if symbolFromSymbolTable.name ~= ast.InternalSymbolNameExportEquals and
            symbolFromSymbolTable.name ~= ast.InternalSymbolNameDefault and
            not (checker.isUMDExportSymbol(symbolFromSymbolTable) and ctx.enclosingDeclaration ~= nil and ast.IsExternalModule(ast.GetSourceFileOfNode(ctx.enclosingDeclaration))) and
            -- If `!useOnlyExternalAliasing`, we can use any type of alias to get the name
            (not ctx.useOnlyExternalAliasing or core.Some(symbolFromSymbolTable.declarations, function(d) return ast.IsExternalModuleImportEqualsDeclaration(d) end)) and
            -- If we're looking up a local name to reference directly, omit namespace reexports, otherwise when we're trawling through an export list to make a dotted name, we can keep it
            (isLocalNameLookup and not core.Some(symbolFromSymbolTable.declarations, function(d) return checker.isNamespaceReexportDeclaration(d) end) or not isLocalNameLookup) and
            -- While exports are generally considered to be in scope, export-specifier declared symbols are _not_
            -- See similar comment in `resolveName` for details
            (ignoreQualification or core.Len(checker.getDeclarationsOfKind(symbolFromSymbolTable, Kind.ExportSpecifier)) == 0) then
            local resolvedImportedSymbol = self:resolveAlias(symbolFromSymbolTable)
            local candidate = self:getCandidateListForSymbol(ctx, symbolFromSymbolTable, resolvedImportedSymbol, ignoreQualification)
            if core.Len(candidate) > 0 then
                candidateChains = core.Append(candidateChains, candidate)
            end
        end
    end

    if core.Len(candidateChains) > 0 then
        -- pick first, shortest
        core.SortStableFunc(candidateChains, self.compareSymbolChains)
        return candidateChains[1]
    end

    -- If there's no result and we're looking at the global symbol table, treat `globalThis` like an alias and try to lookup thru that
    if isGlobals then
        return self:getCandidateListForSymbol(ctx, self.globalThisSymbol, self.globalThisSymbol, ignoreQualification)
    end
    return nil
end

function Checker:compareSymbolChainsWorker(a, b)
    local chainLen = #a - #b
    if chainLen ~= 0 then
        return chainLen
    end

    local idx = 0
    while idx < #a do
        local comparison = self.compareSymbols(a[idx + 1], b[idx + 1])
        if comparison ~= 0 then
            return comparison
        end
        idx = idx + 1
    end
    return 0
end

function checker.isUMDExportSymbol(symbol)
    return symbol ~= nil and core.Len(symbol.declarations) > 0 and symbol.declarations[1] ~= nil and ast.IsNamespaceExportDeclaration(symbol.declarations[1])
end

function checker.isNamespaceReexportDeclaration(node)
    return ast.IsNamespaceExport(node) and node.parent:ModuleSpecifier() ~= nil
end

function Checker:getCandidateListForSymbol(ctx, symbolFromSymbolTable, resolvedImportedSymbol, ignoreQualification)
    if self:isAccessible(ctx, symbolFromSymbolTable, resolvedImportedSymbol, ignoreQualification) then
        return { symbolFromSymbolTable }
    end

    -- Look in the exported members, if we can find accessibleSymbolChain, symbol is accessible using this chain
    -- but only if the symbolFromSymbolTable can be qualified
    local candidateTable = self:getExportsOfSymbol(resolvedImportedSymbol)
    if candidateTable == nil then
        return nil
    end
    local candidateTableId = checker.symbolTableIDFromResolvedExports(resolvedImportedSymbol)
    local accessibleSymbolsFromExports = self:getAccessibleSymbolChainFromSymbolTable(ctx, candidateTable, candidateTableId, true --[[ignoreQualification]], false)
    if core.Len(accessibleSymbolsFromExports) == 0 then
        return nil
    end
    if not self:canQualifySymbol(ctx, symbolFromSymbolTable, checker.getQualifiedLeftMeaning(ctx.meaning)) then
        return nil
    end
    local result = { symbolFromSymbolTable }
    core.AppendAll(result, accessibleSymbolsFromExports)
    return result
end

function Checker:isAccessible(ctx, symbolFromSymbolTable, resolvedAliasSymbol, ignoreQualification)
    local likeSymbols = false
    if ctx.symbol == resolvedAliasSymbol then
        likeSymbols = true
    end
    if ctx.symbol == symbolFromSymbolTable then
        likeSymbols = true
    end
    local symbol = self:getMergedSymbol(ctx.symbol)
    if symbol == self:getMergedSymbol(resolvedAliasSymbol) then
        likeSymbols = true
    end
    if symbol == self:getMergedSymbol(symbolFromSymbolTable) then
        likeSymbols = true
    end
    if not likeSymbols then
        return false
    end
    -- if the symbolFromSymbolTable is not external module (it could be if it was determined as ambient external module and would be in globals table)
    -- and if symbolFromSymbolTable or alias resolution matches the symbol,
    -- check the symbol can be qualified, it is only then this symbol is accessible
    return not core.Some(symbolFromSymbolTable.declarations, function(d) return checker.hasNonGlobalAugmentationExternalModuleSymbol(d) end) and
        (ignoreQualification or self:canQualifySymbol(ctx, self:getMergedSymbol(symbolFromSymbolTable), ctx.meaning))
end

function Checker:canQualifySymbol(ctx, symbolFromSymbolTable, meaning)
    -- If the symbol is equivalent and doesn't need further qualification, this symbol is accessible
    return not self:needsQualification(symbolFromSymbolTable, ctx.enclosingDeclaration, meaning) or
        -- If symbol needs qualification, make sure that parent is accessible, if it is then this symbol is accessible too
        core.Len(self:getAccessibleSymbolChainEx(newAccessibleSymbolChainContext(symbolFromSymbolTable.parent, ctx.enclosingDeclaration, checker.getQualifiedLeftMeaning(meaning), ctx.useOnlyExternalAliasing, ctx.visitedSymbolTablesMap))) > 0
end

function Checker:needsQualification(symbol, enclosingDeclaration, meaning)
    local qualify = false
    self:someSymbolTableInScope(enclosingDeclaration, function(symbolTable, _, _, _, _)
        -- If symbol of this name is not available in the symbol table we are ok
        local res = symbolTable[symbol.name]
        if res == nil then
            return false
        end
        local symbolFromSymbolTable = self:getMergedSymbol(res)
        if symbolFromSymbolTable == nil then
            -- Continue to the next symbol table
            return false
        end
        -- If the symbol with this name is present it should refer to the symbol
        if symbolFromSymbolTable == symbol then
            -- No need to qualify
            return true
        end

        -- Qualify if the symbol from symbol table has same meaning as expected
        local shouldResolveAlias = symbolFromSymbolTable.flags & SymbolFlags.Alias ~= 0 and ast.GetDeclarationOfKind(symbolFromSymbolTable, Kind.ExportSpecifier) == nil
        if shouldResolveAlias then
            symbolFromSymbolTable = self:resolveAlias(symbolFromSymbolTable)
        end
        local flags = symbolFromSymbolTable.flags
        if shouldResolveAlias then
            flags = self:getSymbolFlags(symbolFromSymbolTable)
        end
        if flags & meaning ~= 0 then
            qualify = true
            return true
        end

        -- Continue to the next symbol table
        return false
    end)

    return qualify
end

function checker.isPropertyOrMethodDeclarationSymbol(symbol)
    if core.Len(symbol.declarations) > 0 then
        for _, declaration in ipairs(symbol.declarations) do
            local kind = declaration.kind
            if not (kind == Kind.PropertyDeclaration or
                    kind == Kind.MethodDeclaration or
                    kind == Kind.GetAccessor or
                    kind == Kind.SetAccessor) then
                return false
            end
        end
        return true
    end
    return false
end

function Checker:someSymbolTableInScope(enclosingDeclaration, callback)
    local location = enclosingDeclaration
    while location ~= nil do
        -- Locals of a source file are not in scope (because they get merged into the global symbol table)
        if checker.canHaveLocals(location) and location:Locals() ~= nil and not ast.IsGlobalSourceFile(location) then
            if callback(location:Locals(), checker.symbolTableIDFromLocals(location:AsNode()), false, true, location) then
                return true
            end
        end
        local kind = location.kind
        if kind == Kind.SourceFile or kind == Kind.ModuleDeclaration then
            if not (ast.IsSourceFile(location) and not ast.IsExternalOrCommonJSModule(location:AsSourceFile())) then
                local sym = self:getSymbolOfDeclaration(ast.GetReparsedNodeForNode(location))
                if callback(sym.exports, checker.symbolTableIDFromExports(sym), false, true, location) then
                    return true
                end
            end
        elseif kind == Kind.ClassDeclaration or kind == Kind.ClassExpression or kind == Kind.InterfaceDeclaration then
            -- Type parameters are bound into `members` lists so they can merge across declarations
            -- This is troublesome, since in all other respects, they behave like locals :cries:
            -- TODO: the below is shared with similar code in `resolveName` - in fact, rephrasing all this symbol
            -- lookup logic in terms of `resolveName` would be nice
            -- The below is used to lookup type parameters within a class or interface, as they are added to the class/interface locals
            -- These can never be latebound, so the symbol's raw members are sufficient. `getMembersOfNode` cannot be used, as it would
            -- trigger resolving late-bound names, which we may already be in the process of doing while we're here!
            local table_
            local sym = self:getSymbolOfDeclaration(location)
            -- TODO: Should this filtered table be cached in some way?
            for key, memberSymbol in pairs(sym.members or {}) do
                if memberSymbol.flags & (SymbolFlags.Type & ~SymbolFlags.Assignment) ~= 0 then
                    if table_ == nil then
                        table_ = ast.NewSymbolTable()
                    end
                    table_[key] = memberSymbol
                end
            end
            if table_ ~= nil and callback(table_, checker.symbolTableIDFromMembers(sym), false, false, location) then
                return true
            end
            -- Class expression names (e.g., `B` in `class B {}`) are not stored in any
            -- scope table — the binder uses bindAnonymousDeclaration. Expose the name
            -- binding here so getAccessibleSymbolChain can resolve self-references.
            -- This mirrors the special casing of class expression names in
            -- (*NameResolver).Resolve; if class names are ever bound differently
            -- (e.g., via class-local type aliases), both sites should be updated.
            if ast.IsClassExpression(location) and location:AsClassExpression():Name() ~= nil then
                local nameTable = self:getClassExpressionNameTable(location)
                if nameTable ~= nil and callback(nameTable, checker.symbolTableIDFromLocals(location:AsNode()), false, true, location) then
                    return true
                end
            end
        end
        location = location.parent
    end

    return callback(self.globals, checker.symbolTableIDFromGlobals(), false, true, nil)
end

-- getClassExpressionNameTable returns a cached symbol table containing the class
-- expression's name binding. Class expression names are bound via
-- bindAnonymousDeclaration and aren't stored in any container's locals, so this
-- synthesized table lets someSymbolTableInScope expose them during accessibility checks.
function Checker:getClassExpressionNameTable(location)
    local nodeId = ast.GetNodeId(location)
    if self.classExpressionNameTables ~= nil then
        local t = self.classExpressionNameTables[nodeId]
        if t ~= nil then
            return t
        end
    end
    local classSymbol = self:getSymbolOfDeclaration(location)
    local nameText = location:AsClassExpression():Name():Text()
    if #nameText == 0 or classSymbol == nil then
        return nil
    end
    local t = { [nameText] = classSymbol }
    if self.classExpressionNameTables == nil then
        self.classExpressionNameTables = {}
    end
    self.classExpressionNameTables[nodeId] = t
    return t
end

--[[*
 * Check if the given symbol in given enclosing declaration is accessible and mark all associated alias to be visible if requested
 *
 * @param symbol a Symbol to check if accessible
 * @param enclosingDeclaration a Node containing reference to the symbol
 * @param meaning a SymbolFlags to check if such meaning of the symbol is accessible
 * @param shouldComputeAliasToMakeVisible a boolean value to indicate whether to return aliases to be mark visible in case the symbol is accessible
 ]]

function Checker:IsSymbolAccessible(symbol, enclosingDeclaration, meaning, shouldComputeAliasesToMakeVisible)
    return self:isSymbolAccessibleWorker(symbol, enclosingDeclaration, meaning, shouldComputeAliasesToMakeVisible, true --[[allowModules]])
end

function Checker:isSymbolAccessibleWorker(symbol, enclosingDeclaration, meaning, shouldComputeAliasesToMakeVisible, allowModules)
    if symbol ~= nil and enclosingDeclaration ~= nil then
        local result = self:IsAnySymbolAccessible({ symbol }, enclosingDeclaration, symbol, meaning, shouldComputeAliasesToMakeVisible, allowModules)
        if result ~= nil then
            return result
        end

        -- This could be a symbol that is not exported in the external module
        -- or it could be a symbol from different external module that is not aliased and hence cannot be named
        local symbolExternalModule = core.FirstNonNil(symbol.declarations, function(d) return self:getExternalModuleContainer(d) end)
        if symbolExternalModule ~= nil then
            local enclosingExternalModule = self:getExternalModuleContainer(enclosingDeclaration)
            if symbolExternalModule ~= enclosingExternalModule then
                -- name from different external module that is not visible
                return newResult(
                    SymbolAccessibility.CannotBeNamed,
                    self:symbolToStringEx(symbol, enclosingDeclaration, meaning, SymbolFormatFlags.AllowAnyNodeKind),
                    core.IfElse(ast.IsInJSFile(enclosingDeclaration), enclosingDeclaration, nil),
                    self:symbolToString(symbolExternalModule)
                )
            end
        end

        -- Just a local name that is not accessible
        return newResult(
            SymbolAccessibility.NotAccessible,
            self:symbolToStringEx(symbol, enclosingDeclaration, meaning, SymbolFormatFlags.AllowAnyNodeKind)
        )
    end

    return newResult(SymbolAccessibility.Accessible)
end
