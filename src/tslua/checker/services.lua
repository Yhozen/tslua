local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureKind = checker.SignatureKind
local CheckMode = checker.CheckMode
local ContextFlags = checker.ContextFlags
local IterationUse = checker.IterationUse
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

-- Go slices.Index (0-based, -1 if absent)
local function slicesIndex(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end

function Checker:GetSymbolsInScope(location, meaning)
    return self:getSymbolsInScope(location, meaning)
end

function Checker:getSymbolsInScope(location, meaning)
    if location.flags & NodeFlags.InWithStatement ~= 0 then
        -- We cannot answer semantic questions within a with block, do not proceed any further
        return nil
    end

    local symbols = ast.NewSymbolTable()
    local isStaticSymbol = false

    -- Copy the given symbol into symbol tables if the symbol has the given meaning
    -- and it doesn't already exists in the symbol table.
    local function copySymbol(symbol, meaning_)
        if symbol:CombinedLocalAndExportSymbolFlags() & meaning_ ~= 0 then
            local id = symbol.name
            -- We will copy all symbol regardless of its reserved name because
            -- symbolsToArray will check whether the key is a reserved name and
            -- it will not copy symbol with reserved name to the array
            if symbols[id] == nil then
                symbols[id] = symbol
            end
        end
    end

    local function copySymbols(source, meaning_)
        if meaning_ ~= 0 then
            for _, symbol in pairs(source or {}) do
                copySymbol(symbol, meaning_)
            end
        end
    end

    local function copyLocallyVisibleExportSymbols(source, meaning_)
        if meaning_ ~= 0 then
            for _, symbol in pairs(source or {}) do
                -- Similar condition as in `resolveNameHelper`
                if ast.GetDeclarationOfKind(symbol, Kind.ExportSpecifier) == nil and
                    ast.GetDeclarationOfKind(symbol, Kind.NamespaceExport) == nil and
                    symbol.name ~= ast.InternalSymbolNameDefault then
                    copySymbol(symbol, meaning_)
                end
            end
        end
    end

    local function populateSymbols()
        while location ~= nil do
            if checker.canHaveLocals(location) and location:Locals() ~= nil and not ast.IsGlobalSourceFile(location) then
                copySymbols(location:Locals(), meaning)
            end

            local kind = location.kind
            if (kind == Kind.SourceFile and ast.IsExternalModule(location:AsSourceFile())) or kind == Kind.ModuleDeclaration then
                copyLocallyVisibleExportSymbols(self:getSymbolOfDeclaration(location).exports, meaning & SymbolFlags.ModuleMember)
            elseif kind == Kind.EnumDeclaration then
                copySymbols(self:getSymbolOfDeclaration(location).exports, meaning & SymbolFlags.EnumMember)
            elseif kind == Kind.ClassExpression or kind == Kind.ClassDeclaration or kind == Kind.InterfaceDeclaration then
                if kind == Kind.ClassExpression then
                    local className = location:AsClassExpression():Name()
                    if className ~= nil then
                        copySymbol(location:Symbol(), meaning)
                    end
                    -- this fall-through is necessary because we would like to handle
                    -- type parameter inside class expression similar to how we handle it in classDeclaration and interface Declaration.
                end
                -- If we didn't come from static member of class or interface,
                -- add the type parameters into the symbol table
                -- (type parameters of classDeclaration/classExpression and interface are in member property of the symbol.
                -- Note: that the memberFlags come from previous iteration.
                if not isStaticSymbol then
                    copySymbols(self:getMembersOfSymbol(self:getSymbolOfDeclaration(location)), meaning & SymbolFlags.Type)
                end
            elseif kind == Kind.FunctionExpression then
                local funcName = location:Name()
                if funcName ~= nil then
                    copySymbol(location:Symbol(), meaning)
                end
            end

            if checker.introducesArgumentsExoticObject(location) then
                copySymbol(self.argumentsSymbol, meaning)
            end

            isStaticSymbol = ast.IsStatic(location)
            location = location.parent
        end

        copySymbols(self.globals, meaning)
    end

    populateSymbols()

    symbols[ast.InternalSymbolNameThis] = nil -- Not a symbol, a keyword
    return checker.symbolsToArray(symbols)
end

function Checker:GetExportsOfModule(symbol)
    return checker.symbolsToArray(self:getExportsOfModule(symbol))
end

function Checker:ForEachExportAndPropertyOfModule(moduleSymbol, cb)
    for key, exportedSymbol in pairs(self:getExportsOfModule(moduleSymbol) or {}) do
        if not checker.isReservedMemberName(key) then
            cb(exportedSymbol, key)
        end
    end

    local exportEquals = self:resolveExternalModuleSymbol(moduleSymbol, false --[[dontResolveAlias]])
    if exportEquals == moduleSymbol then
        return
    end

    local typeOfSymbol = self:getTypeOfSymbol(exportEquals)
    if not self:shouldTreatPropertiesOfExternalModuleAsExports(typeOfSymbol) then
        return
    end

    -- forEachPropertyOfType
    local reducedType = self:getReducedApparentType(typeOfSymbol)
    if reducedType.flags & TypeFlags.StructuredType == 0 then
        return
    end
    for name, symbol in pairs(self:resolveStructuredTypeMembers(reducedType).members or {}) do
        if self:isNamedMember(symbol, name) then
            cb(symbol, name)
        end
    end
end

function Checker:IsValidPropertyAccess(node, propertyName)
    return self:isValidPropertyAccess(node, propertyName)
end

function Checker:isValidPropertyAccess(node, propertyName)
    local kind = node.kind
    if kind == Kind.PropertyAccessExpression then
        return self:isValidPropertyAccessWithType(node, node:Expression().kind == Kind.SuperKeyword, propertyName, self:getWidenedType(self:checkExpression(node:Expression())))
    elseif kind == Kind.QualifiedName then
        return self:isValidPropertyAccessWithType(node, false --[[isSuper]], propertyName, self:getWidenedType(self:checkExpression(node:AsQualifiedName().left)))
    elseif kind == Kind.ImportType then
        return self:isValidPropertyAccessWithType(node, false --[[isSuper]], propertyName, self:getTypeFromTypeNode(node))
    end
    error("Unexpected node kind in isValidPropertyAccess: " .. ast.Kind_String(node.kind), 0)
end

function Checker:isValidPropertyAccessWithType(node, isSuper, propertyName, t)
    -- Short-circuiting for improved performance.
    if checker.IsTypeAny(t) then
        return true
    end

    local prop = self:getPropertyOfType(t, propertyName)
    return prop ~= nil and self:isPropertyAccessible(node, isSuper, false --[[isWrite]], t, prop)
end

-- Checks if an existing property access is valid for completions purposes.
-- node: a property access-like node where we want to check if we can access a property.
-- This node does not need to be an access of the property we are checking.
-- e.g. in completions, this node will often be an incomplete property access node, as in `foo.`.
-- Besides providing a location (i.e. scope) used to check property accessibility, we use this node for
-- computing whether this is a `super` property access.
-- type: the type whose property we are checking.
-- property: the accessed property's symbol.
function Checker:IsValidPropertyAccessForCompletions(node, t, property)
    return self:isPropertyAccessible(
        node,
        node.kind == Kind.PropertyAccessExpression and node:Expression().kind == Kind.SuperKeyword,
        false, --[[isWrite]]
        t,
        property
    )
    -- Previously we validated the 'this' type of methods but this adversely affected performance. See #31377 for more context.
end

function Checker:GetAllPossiblePropertiesOfTypes(types)
    local unionType = self:getUnionType(types)
    if unionType.flags & TypeFlags.Union == 0 then
        return self:getAugmentedPropertiesOfType(unionType)
    end

    -- Go collects the map values in random order; Lua keeps insertion order.
    local props = ast.NewSymbolTable()
    local result = {}
    for _, memberType in ipairs(types or {}) do
        local augmentedProps = self:getAugmentedPropertiesOfType(memberType)
        for _, p in ipairs(augmentedProps or {}) do
            if props[p.name] == nil then
                local prop = self:createUnionOrIntersectionProperty(unionType, p.name, false --[[skipObjectFunctionPropertyAugment]])
                -- May be undefined if the property is private
                if prop ~= nil then
                    props[p.name] = prop
                    result[#result + 1] = prop
                end
            end
        end
    end
    return result
end

function Checker:IsUnknownSymbol(symbol)
    return symbol == self.unknownSymbol
end

function Checker:IsUndefinedSymbol(symbol)
    return symbol == self.undefinedSymbol
end

function Checker:IsArgumentsSymbol(symbol)
    return symbol == self.argumentsSymbol
end

-- Originally from services.ts
function Checker:GetNonOptionalType(t)
    return self:removeOptionalTypeMarker(t)
end

function Checker:GetStringIndexType(t)
    return self:getIndexTypeOfType(t, self.stringType)
end

function Checker:GetNumberIndexType(t)
    return self:getIndexTypeOfType(t, self.numberType)
end

function Checker:GetElementTypeOfArrayType(t)
    return self:getElementTypeOfArrayType(t)
end

function Checker:GetCallSignatures(t)
    return self:getSignaturesOfType(t, SignatureKind.Call)
end

function Checker:GetConstructSignatures(t)
    return self:getSignaturesOfType(t, SignatureKind.Construct)
end

function Checker:GetApparentProperties(t)
    return self:getAugmentedPropertiesOfType(t)
end

function Checker:getAugmentedPropertiesOfType(t)
    t = self:getApparentType(t)
    local propsByName = checker.createSymbolTable(self:getPropertiesOfType(t))
    local functionType
    if core.Len(self:getSignaturesOfType(t, SignatureKind.Call)) > 0 then
        functionType = self.globalCallableFunctionType
    elseif core.Len(self:getSignaturesOfType(t, SignatureKind.Construct)) > 0 then
        functionType = self.globalNewableFunctionType
    end

    if propsByName == nil then
        propsByName = ast.NewSymbolTable()
    end
    if functionType ~= nil then
        for _, p in ipairs(self:getPropertiesOfType(functionType) or {}) do
            if propsByName[p.name] == nil then
                propsByName[p.name] = p
            end
        end
    end
    return self:getNamedMembers(propsByName, nil)
end

function Checker:TryGetMemberInModuleExportsAndProperties(memberName, moduleSymbol)
    local symbol = self:TryGetMemberInModuleExports(memberName, moduleSymbol)
    if symbol ~= nil then
        return symbol
    end

    local exportEquals = self:resolveExternalModuleSymbol(moduleSymbol, false --[[dontResolveAlias]])
    if exportEquals == moduleSymbol then
        return nil
    end

    local t = self:getTypeOfSymbol(exportEquals)
    if self:shouldTreatPropertiesOfExternalModuleAsExports(t) then
        return self:getPropertyOfType(t, memberName)
    end
    return nil
end

function Checker:TryGetMemberInModuleExports(memberName, moduleSymbol)
    local symbolTable = self:getExportsOfModule(moduleSymbol)
    if symbolTable == nil then
        return nil
    end
    return symbolTable[memberName]
end

function Checker:shouldTreatPropertiesOfExternalModuleAsExports(resolvedExternalModuleType)
    return resolvedExternalModuleType.flags & TypeFlags.Primitive == 0 or
        resolvedExternalModuleType.objectFlags & ObjectFlags.Class ~= 0 or
        -- `isArrayOrTupleLikeType` is too expensive to use in this auto-imports hot path.
        self:isArrayType(resolvedExternalModuleType) or
        checker.isTupleType(resolvedExternalModuleType)
end

function Checker:GetContextualType(node, contextFlags)
    if contextFlags & ContextFlags.IgnoreNodeInferences ~= 0 then
        return checker.runWithInferenceBlockedFromSourceNode(self, node, function()
            return self:getContextualType(node, contextFlags)
        end)
    end
    return self:getContextualType(node, contextFlags)
end

function checker.runWithInferenceBlockedFromSourceNode(c, node, fn)
    local containingCall = ast.FindAncestor(node, function(n) return ast.IsCallLikeExpression(n) end)
    if containingCall ~= nil then
        local toMarkSkip = node
        while true do
            c.skipDirectInferenceNodes:Add(toMarkSkip)
            toMarkSkip = toMarkSkip.parent
            if toMarkSkip == nil or toMarkSkip == containingCall then
                break
            end
        end
    end

    c.isInferencePartiallyBlocked = true
    local result = checker.runWithoutResolvedSignatureCaching(c, node, fn)
    c.isInferencePartiallyBlocked = false

    c.skipDirectInferenceNodes:Clear()
    return result
end

-- Returns signature, candidates.
function checker.GetResolvedSignatureForSignatureHelp(node, argumentCount, c)
    local res = checker.runWithoutResolvedSignatureCaching(c, node, function()
        local signature, candidates = c:getResolvedSignatureWorker(node, CheckMode.IsForSignatureHelp, argumentCount)
        return { signature = signature, candidates = candidates }
    end)
    return res.signature, res.candidates
end

function checker.runWithoutResolvedSignatureCaching(c, node, fn)
    local ancestorNode = ast.FindAncestor(node, function(n) return ast.IsCallLikeOrFunctionLikeExpression(n) end)
    if ancestorNode ~= nil then
        -- Go maps keyed by the links; values may be nil, so they are kept as (links, value) lists.
        local cachedResolvedSignatures = {}
        local cachedTypes = {}
        while ancestorNode ~= nil do
            local signatureLinks = c.signatureLinks:Get(ancestorNode)
            cachedResolvedSignatures[#cachedResolvedSignatures + 1] = { signatureLinks, signatureLinks.resolvedSignature }
            signatureLinks.resolvedSignature = nil
            if ast.IsFunctionExpressionOrArrowFunction(ancestorNode) then
                local symbolLinks = c.valueSymbolLinks:Get(c:getSymbolOfDeclaration(ancestorNode))
                local resolvedType = symbolLinks.resolvedType
                cachedTypes[#cachedTypes + 1] = { symbolLinks, resolvedType }
                symbolLinks.resolvedType = nil
            end
            ancestorNode = ast.FindAncestor(ancestorNode.parent, function(n) return ast.IsCallLikeOrFunctionLikeExpression(n) end)
        end
        local result = fn()
        for _, entry in ipairs(cachedResolvedSignatures) do
            entry[1].resolvedSignature = entry[2]
        end
        for _, entry in ipairs(cachedTypes) do
            entry[1].resolvedType = entry[2]
        end
        return result
    end
    return fn()
end

function Checker:SkipAlias(symbol)
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        return self:GetAliasedSymbol(symbol)
    end
    return symbol
end

function Checker:GetRootSymbols(symbol)
    local roots = self:getImmediateRootSymbols(symbol)
    if core.Len(roots) == 0 then
        return { symbol }
    end
    local result
    for _, root in ipairs(roots) do
        result = core.AppendAll(result, self:GetRootSymbols(root))
    end
    return result
end

function Checker:GetMappedTypeSymbolOfProperty(symbol)
    local valueLinks = self.valueSymbolLinks:TryGet(symbol)
    if valueLinks ~= nil then
        return valueLinks.containingType.symbol
    end
    return nil
end

function Checker:getImmediateRootSymbols(symbol)
    if symbol.checkFlags & CheckFlags.Synthetic ~= 0 then
        return core.MapNonNil(
            self.valueSymbolLinks:Get(symbol).containingType:Types(),
            function(t)
                return self:getPropertyOfType(t, symbol.name)
            end
        )
    end
    if symbol.flags & SymbolFlags.Transient ~= 0 then
        if self.spreadLinks:Has(symbol) then
            local leftSpread = self.spreadLinks:Get(symbol).leftSpread
            local rightSpread = self.spreadLinks:Get(symbol).rightSpread
            if leftSpread ~= nil then
                return { leftSpread, rightSpread }
            end
        end
        if self.mappedSymbolLinks:Has(symbol) then
            local syntheticOrigin = self.mappedSymbolLinks:Get(symbol).syntheticOrigin
            if syntheticOrigin ~= nil then
                return { syntheticOrigin }
            end
        end
        local target = self:tryGetTarget(symbol)
        if target ~= nil then
            return { target }
        end
    end
    return nil
end

function Checker:tryGetTarget(symbol)
    local target
    local next_ = symbol
    while true do
        if self.valueSymbolLinks:Has(next_) then
            next_ = self.valueSymbolLinks:Get(next_).target
        elseif self.exportTypeLinks:Has(next_) then
            next_ = self.exportTypeLinks:Get(next_).target
        else
            next_ = nil
        end
        if next_ == nil then
            break
        end
        target = next_
    end
    return target
end

function Checker:GetExportSymbolOfSymbol(symbol)
    return self:getMergedSymbol(core.IfElse(symbol.exportSymbol ~= nil, symbol.exportSymbol, symbol))
end

function Checker:GetExportSpecifierLocalTargetSymbol(node)
    -- node should be ExportSpecifier | Identifier
    if node.kind == Kind.ExportSpecifier then
        if node.parent.parent:ModuleSpecifier() ~= nil then
            return self:getExternalModuleMember(node.parent.parent, node, false --[[dontResolveAlias]])
        end
        local name = node:PropertyNameOrName()
        if name.kind == Kind.StringLiteral then
            -- Skip for invalid syntax like this: export { "x" }
            return nil
        end
        return self:resolveEntityName(name, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, true --[[ignoreErrors]], false, nil)
    elseif node.kind == Kind.Identifier then
        return self:resolveEntityName(node, SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, true --[[ignoreErrors]], false, nil)
    end
    error("Unhandled case in getExportSpecifierLocalTargetSymbol, node should be ExportSpecifier | Identifier", 0)
end

function Checker:GetShorthandAssignmentValueSymbol(location)
    if location ~= nil and location.kind == Kind.ShorthandPropertyAssignment then
        return self:resolveEntityName(location:Name(), SymbolFlags.Value | SymbolFlags.Alias, true --[[ignoreErrors]], false, nil)
    end
    return nil
end

--[[*
* Get symbols that represent parameter-property-declaration as parameter and as property declaration
* @param parameter a parameterDeclaration node
* @param parameterName a name of the parameter to get the symbols for.
* @return a tuple of two symbols
 ]]
function Checker:GetSymbolsOfParameterPropertyDeclaration(parameter, parameterName)
    local constructorDeclaration = parameter.parent
    local classDeclaration = parameter.parent.parent

    local parameterSymbol = self:getSymbol(constructorDeclaration:Locals(), parameterName, SymbolFlags.Value)
    local propertySymbol = self:getSymbol(self:getMembersOfSymbol(classDeclaration:Symbol()), parameterName, SymbolFlags.Value)

    if parameterSymbol ~= nil and propertySymbol ~= nil then
        return parameterSymbol, propertySymbol
    end

    error("There should exist two symbols, one as property declaration and one as parameter declaration", 0)
end

-- IsDeclarationUsed checks if an import declaration identifier is used in the source file.
-- This is primarily used for organizing imports to determine which imports can be removed.
function Checker:IsDeclarationUsed(sourceFile, identifier, jsxElementsPresent, jsxModeNeedsExplicitImport)
    if jsxElementsPresent and jsxModeNeedsExplicitImport then
        local jsxNamespace = self:getJsxNamespace(sourceFile:AsNode())
        local jsxFragmentFactory = self:GetJsxFragmentFactory(sourceFile:AsNode())
        local identifierText = identifier.text
        if identifierText == jsxNamespace then
            return true
        end
        if jsxFragmentFactory ~= "" and identifierText == jsxFragmentFactory then
            return true
        end
    end

    local symbol = self:GetSymbolAtLocation(identifier:AsNode())
    if symbol == nil then
        return true
    end

    return self:IsSymbolReferencedInFile(sourceFile, identifier, symbol)
end

-- IsSymbolReferencedInFile checks if a symbol is referenced in the source file (besides its definition).
-- This is used as a quick check for whether a symbol is used at all in a file.
function Checker:IsSymbolReferencedInFile(sourceFile, definition, symbol)
    local identifierText = definition.text
    for _, token in ipairs(checker.getPossibleSymbolReferenceNodes(sourceFile, identifierText, sourceFile:AsNode()) or {}) do
        if not ast.IsIdentifier(token) then
            goto continue
        end
        do
            local id = token:AsIdentifier()
            if id == definition or id.text ~= identifierText then
                goto continue
            end
            local refSymbol = self:GetSymbolAtLocation(token)
            if refSymbol == symbol then
                return true
            end
            if token.parent ~= nil and token.parent.kind == Kind.ShorthandPropertyAssignment then
                local shorthandSymbol = self:GetShorthandAssignmentValueSymbol(token.parent)
                if shorthandSymbol == symbol then
                    return true
                end
            end
            if token.parent ~= nil and ast.IsExportSpecifier(token.parent) then
                local localSymbol = self:getLocalSymbolForExportSpecifier(token:AsIdentifier(), refSymbol, token.parent:AsExportSpecifier())
                if localSymbol == symbol then
                    return true
                end
            end
        end
        ::continue::
    end
    return false
end

-- GetReferencesToSymbolInFile returns all identifier nodes in the file that reference the given symbol.
function Checker:GetReferencesToSymbolInFile(sourceFile, symbol)
    local identifierText = symbol.name
    local result
    for _, token in ipairs(checker.getPossibleSymbolReferenceNodes(sourceFile, identifierText, sourceFile:AsNode()) or {}) do
        if not ast.IsIdentifier(token) then
            goto continue
        end
        do
            local id = token:AsIdentifier()
            if id.text ~= identifierText then
                goto continue
            end
            local refSymbol = self:GetSymbolAtLocation(token)
            if refSymbol == symbol then
                result = core.Append(result, token)
                goto continue
            end
            if token.parent ~= nil and token.parent.kind == Kind.ShorthandPropertyAssignment then
                local shorthandSymbol = self:GetShorthandAssignmentValueSymbol(token.parent)
                if shorthandSymbol == symbol then
                    result = core.Append(result, token)
                    goto continue
                end
            end
            if token.parent ~= nil and ast.IsExportSpecifier(token.parent) then
                local localSymbol = self:getLocalSymbolForExportSpecifier(token:AsIdentifier(), refSymbol, token.parent:AsExportSpecifier())
                if localSymbol == symbol then
                    result = core.Append(result, token)
                    goto continue
                end
            end
        end
        ::continue::
    end
    return result
end

function Checker:getLocalSymbolForExportSpecifier(referenceLocation, referenceSymbol, exportSpecifier)
    if checker.isExportSpecifierAlias(referenceLocation, exportSpecifier) then
        local symbol = self:GetExportSpecifierLocalTargetSymbol(exportSpecifier:AsNode())
        if symbol ~= nil then
            return symbol
        end
    end
    return referenceSymbol
end

function checker.isExportSpecifierAlias(referenceLocation, exportSpecifier)
    debug.Assert(exportSpecifier.propertyName == referenceLocation:AsNode() or exportSpecifier:Name() == referenceLocation:AsNode(), "referenceLocation is not export specifier name or property name")
    local propertyName = exportSpecifier.propertyName
    if propertyName ~= nil then
        -- Given `export { foo as bar } [from "someModule"]`: It's an alias at `foo`, but at `bar` it's a new symbol.
        return propertyName == referenceLocation:AsNode()
    else
        -- `export { foo } from "foo"` is a re-export.
        -- `export { foo };` is not a re-export, it creates an alias for the local variable `foo`.
        return exportSpecifier.parent.parent:ModuleSpecifier() == nil
    end
end

function checker.getPossibleSymbolReferenceNodes(sourceFile, symbolName, container)
    -- astnav is required lazily: it is a separate package that is not needed by the compiler
    -- pipeline (only by these language-service helpers).
    local astnav = require("tslua.astnav")
    return core.MapNonNil(checker.getPossibleSymbolReferencePositions(sourceFile, symbolName, container), function(pos)
        local referenceLocation = astnav.GetTouchingPropertyName(sourceFile, pos)
        if referenceLocation ~= sourceFile:AsNode() then
            return referenceLocation
        end
        return nil
    end)
end

-- Go strings.Index(s, sub) (0-based, -1 if absent)
local function stringsIndex(s, sub)
    local i = string.find(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

function checker.getPossibleSymbolReferencePositions(sourceFile, symbolName, container)
    local positions = {}

    -- TODO: Cache symbol existence for files to save text search
    -- Also, need to make this work for unicode escapes.

    -- Be resilient in the face of a symbol with no name or zero length name
    if symbolName == "" then
        return positions
    end

    local text = sourceFile:Text()
    local sourceLength = #text
    local symbolNameLength = #symbolName

    if container == nil then
        container = sourceFile:AsNode()
    end

    local position = stringsIndex(string.sub(text, container:Pos() + 1), symbolName)
    local endPos = container:End()
    while position >= 0 and position < endPos do
        -- We found a match.  Make sure it's not part of a larger word (i.e. the char
        -- before and after it have to be a non-identifier char).
        local endPosition = position + symbolNameLength

        if (position == 0 or not scanner.IsIdentifierPart(string.byte(text, position))) and
            (endPosition == sourceLength or not scanner.IsIdentifierPart(string.byte(text, endPosition + 1))) then
            -- Found a real match.  Keep searching.
            positions[#positions + 1] = position
        end
        local startIndex = position + symbolNameLength + 1
        if startIndex > #text then
            break
        end
        local foundIndex = stringsIndex(string.sub(text, startIndex + 1), symbolName)
        if foundIndex ~= -1 then
            position = startIndex + foundIndex
        else
            break
        end
    end

    return positions
end

function Checker:GetTypeArgumentConstraint(node)
    if not ast.IsTypeNode(node) then
        return nil
    end
    return self:getTypeArgumentConstraint(node)
end

-- getUninstantiatedSignatures gets generic signatures from the function's/constructor's type.
function Checker:getUninstantiatedSignatures(node)
    local kind = node.kind
    if kind == Kind.CallExpression or kind == Kind.Decorator then
        return self:getSignaturesOfType(self:getTypeOfExpression(node:Expression()), SignatureKind.Call)
    elseif kind == Kind.NewExpression then
        return self:getSignaturesOfType(self:getTypeOfExpression(node:Expression()), SignatureKind.Construct)
    elseif kind == Kind.JsxSelfClosingElement or kind == Kind.JsxOpeningElement then
        if checker.isJsxIntrinsicTagName(node:TagName()) then
            return nil
        end
        return self:getSignaturesOfType(self:getTypeOfExpression(node:TagName()), SignatureKind.Call)
    elseif kind == Kind.TaggedTemplateExpression then
        return self:getSignaturesOfType(self:getTypeOfExpression(node:AsTaggedTemplateExpression().tag), SignatureKind.Call)
    elseif kind == Kind.BinaryExpression or kind == Kind.JsxOpeningFragment then
        return nil
    end
    return nil
end

function Checker:getTypeParameterConstraintForPositionAcrossSignatures(signatures, position)
    local relevantConstraints
    for _, signature in ipairs(signatures or {}) do
        if position < core.Len(signature.typeParameters) then
            local relevantTypeParameter = signature.typeParameters[position + 1]
            local relevantConstraint = self:getConstraintOfTypeParameter(relevantTypeParameter)
            if relevantConstraint ~= nil then
                relevantConstraints = core.Append(relevantConstraints, relevantConstraint)
            end
        end
    end
    return self:getUnionType(relevantConstraints)
end

function Checker:getTypeArgumentConstraint(node)
    local typeArgumentPosition = -1
    if ast.HasTypeArguments(node.parent) then
        local typeArgs = node.parent:TypeArguments()
        for i1, arg in ipairs(typeArgs or {}) do
            if arg == node then
                typeArgumentPosition = i1 - 1
                break
            end
        end
    end

    if typeArgumentPosition >= 0 then
        -- The node could be a type argument of a call, a `new` expression, a decorator, an
        -- instantiation expression, or a generic type instantiation.

        if ast.IsCallLikeExpression(node.parent) then
            return self:getTypeParameterConstraintForPositionAcrossSignatures(
                self:getUninstantiatedSignatures(node.parent),
                typeArgumentPosition
            )
        end

        if ast.IsDecorator(node.parent.parent) then
            return self:getTypeParameterConstraintForPositionAcrossSignatures(
                self:getUninstantiatedSignatures(node.parent.parent),
                typeArgumentPosition
            )
        end

        if ast.IsExpressionWithTypeArguments(node.parent) and ast.IsExpressionStatement(node.parent.parent) then
            local uninstantiatedType = self:checkExpression(node.parent:Expression())

            local callConstraint = self:getTypeParameterConstraintForPositionAcrossSignatures(
                self:getSignaturesOfType(uninstantiatedType, SignatureKind.Call),
                typeArgumentPosition
            )
            local constructConstraint = self:getTypeParameterConstraintForPositionAcrossSignatures(
                self:getSignaturesOfType(uninstantiatedType, SignatureKind.Construct),
                typeArgumentPosition
            )

            -- An instantiation expression instantiates both call and construct signatures, so
            -- if both exist type arguments must be assignable to both constraints.
            if constructConstraint.flags & TypeFlags.Never ~= 0 then
                return callConstraint
            end
            if callConstraint.flags & TypeFlags.Never ~= 0 then
                return constructConstraint
            end
            return self:getIntersectionType({ callConstraint, constructConstraint })
        end

        if ast.IsTypeReferenceType(node.parent) then
            local typeParameters = self:getTypeParametersForTypeReferenceOrImport(node.parent)
            if core.Len(typeParameters) == 0 then
                return nil
            end
            if typeArgumentPosition >= #typeParameters then
                return nil
            end
            local relevantTypeParameter = typeParameters[typeArgumentPosition + 1]
            local constraint = self:getConstraintOfTypeParameter(relevantTypeParameter)
            if constraint ~= nil then
                return self:instantiateType(
                    constraint,
                    checker.newTypeMapper(typeParameters, self:getEffectiveTypeArguments(node.parent, typeParameters))
                )
            end
        end
    end
    return nil
end

function Checker:IsTypeInvalidDueToUnionDiscriminant(contextualType, obj)
    local properties = obj:Properties()
    return core.Some(properties, function(property)
        local nameType
        local propertyName = property:Name()
        if propertyName ~= nil then
            if ast.IsJsxNamespacedName(propertyName) then
                nameType = self:getStringLiteralType(propertyName:Text())
            else
                nameType = self:getLiteralTypeFromPropertyName(propertyName)
            end
        end
        local name = ""
        if nameType ~= nil and checker.isTypeUsableAsPropertyName(nameType) then
            name = checker.getPropertyNameFromType(nameType)
        end
        local expected
        if name ~= "" then
            expected = self:getTypeOfPropertyOfType(contextualType, name)
        end
        return expected ~= nil and checker.isLiteralType(expected) and not self:isTypeAssignableTo(self:getTypeOfNode(property), expected)
    end)
end

-- Unlike `getExportsOfModule`, this includes properties of an `export =` value.
function Checker:GetExportsAndPropertiesOfModule(moduleSymbol)
    local exports = self:getExportsOfModuleAsArray(moduleSymbol)
    local exportEquals = self:resolveExternalModuleSymbol(moduleSymbol, false --[[dontResolveAlias]])
    if exportEquals ~= moduleSymbol then
        local t = self:getTypeOfSymbol(exportEquals)
        if self:shouldTreatPropertiesOfExternalModuleAsExports(t) then
            local props = self:getPropertiesOfType(t)
            if props ~= nil then
                exports = core.AppendAll(exports, props)
            end
        end
    end
    return exports
end

function Checker:getExportsOfModuleAsArray(moduleSymbol)
    return checker.symbolsToArray(self:getExportsOfModule(moduleSymbol))
end

-- Returns all the properties of the Jsx.IntrinsicElements interface.
function Checker:GetJsxIntrinsicTagNamesAt(location)
    local intrinsics = self:getJsxType(checker.JsxNames.intrinsicElements, location)
    if intrinsics == nil then
        return nil
    end
    return self:GetPropertiesOfType(intrinsics)
end

function Checker:GetContextualTypeForJsxAttribute(attribute)
    return self:getContextualTypeForJsxAttribute(attribute, ContextFlags.None)
end

function Checker:GetConstantValue(node)
    if node.kind == Kind.EnumMember then
        return self:getEnumMemberValue(node).value
    end

    if self.symbolNodeLinks:Get(node).resolvedSymbol == nil then
        self:checkExpressionCached(node) -- ensure cached resolved symbol is set
    end
    local symbol = self.symbolNodeLinks:Get(node).resolvedSymbol
    if symbol == nil and ast.IsEntityNameExpression(node) then
        symbol = self:resolveEntityName(
            node,
            SymbolFlags.Value,
            true, --[[ignoreErrors]]
            false, --[[dontResolveAlias]]
            nil --[[location]]
        )
    end
    if symbol ~= nil and symbol.flags & SymbolFlags.EnumMember ~= 0 then
        -- inline property\index accesses only for const enums
        local member = symbol.valueDeclaration
        if ast.IsEnumConst(member.parent) then
            return self:getEnumMemberValue(member).value
        end
    end

    return nil
end

-- Returns signature, candidates.
function Checker:getResolvedSignatureWorker(node, checkMode, argumentCount)
    local parsedNode = printer.NewEmitContext():ParseNode(node)
    self.apparentArgumentCount = argumentCount
    local candidatesOutArray = {}
    local res
    if parsedNode ~= nil then
        res = self:getResolvedSignature(parsedNode, candidatesOutArray, checkMode)
    end
    self.apparentArgumentCount = nil
    return res, candidatesOutArray
end

function Checker:GetCandidateSignaturesForStringLiteralCompletions(call, editingArgument)
    -- first, get candidates when inference is blocked from the source node.
    local candidates = checker.runWithInferenceBlockedFromSourceNode(self, editingArgument, function()
        local _, blockedInferenceCandidates = self:getResolvedSignatureWorker(call, CheckMode.Normal, 0)
        return blockedInferenceCandidates
    end)
    local candidatesSet = {}
    for _, candidate in ipairs(candidates or {}) do
        candidatesSet[candidate] = true
    end

    -- next, get candidates where the source node is considered for inference.
    local otherCandidates = checker.runWithoutResolvedSignatureCaching(self, editingArgument, function()
        local _, inferenceCandidates = self:getResolvedSignatureWorker(call, CheckMode.Normal, 0)
        return inferenceCandidates
    end)

    for _, candidate in ipairs(otherCandidates or {}) do
        if not candidatesSet[candidate] then
            candidates = core.Append(candidates, candidate)
        end
    end

    return candidates
end

-- GetTypeAtPosition returns the type of a parameter at a given index in a signature.
function Checker:GetTypeAtPosition(s, pos)
    return self:getTypeAtPosition(s, pos)
end

function Checker:GetTypeParameterAtPosition(s, pos)
    local t = self:getTypeAtPosition(s, pos)
    if t:IsIndex() and checker.isThisTypeParameter(t:AsIndexType().target) then
        local constraint = self:getBaseConstraintOfType(t:AsIndexType().target)
        if constraint ~= nil then
            return self:getIndexType(constraint)
        end
    end
    return t
end

-- GetContextualTypeForArrayLiteralAtPosition returns the contextual type for an element at the given position
-- in an array with the given contextual type.
function Checker:GetContextualTypeForArrayLiteralAtPosition(contextualArrayType, arrayLiteral, position)
    if contextualArrayType == nil then
        return nil
    end
    local firstSpreadIndex, lastSpreadIndex = -1, -1
    local elementIndex = 0
    local elements = arrayLiteral:Elements()
    for i1, elem in ipairs(elements or {}) do
        local i = i1 - 1
        if elem:Pos() < position then
            elementIndex = elementIndex + 1
        end
        if ast.IsSpreadElement(elem) then
            if firstSpreadIndex == -1 then
                firstSpreadIndex = i
            end
            lastSpreadIndex = i
        end
    end
    -- The array may be incomplete, so we don't know its final length.
    return self:getContextualTypeForElementExpression(
        contextualArrayType,
        elementIndex,
        -1, --[[length]]
        firstSpreadIndex,
        lastSpreadIndex
    )
end

checker.knownGenericTypeNames = {
    ["Array"] = true,
    ["ArrayLike"] = true,
    ["ReadonlyArray"] = true,
    ["Promise"] = true,
    ["PromiseLike"] = true,
    ["Iterable"] = true,
    ["IterableIterator"] = true,
    ["AsyncIterable"] = true,
    ["Set"] = true,
    ["WeakSet"] = true,
    ["ReadonlySet"] = true,
    ["Map"] = true,
    ["WeakMap"] = true,
    ["ReadonlyMap"] = true,
    ["Partial"] = true,
    ["Required"] = true,
    ["Readonly"] = true,
    ["Pick"] = true,
    ["Omit"] = true,
    ["NonNullable"] = true,
}

function checker.isKnownGenericTypeName(name)
    return checker.knownGenericTypeNames[name] ~= nil
end

function Checker:GetFirstTypeArgumentFromKnownType(t)
    if t.objectFlags & ObjectFlags.Reference ~= 0 and t.symbol ~= nil and checker.isKnownGenericTypeName(t.symbol.name) then
        local symbol = self:getGlobalSymbol(t.symbol.name, SymbolFlags.Type, nil)
        if symbol ~= nil and symbol == t:Target().symbol then
            return core.FirstOrNil(self:getTypeArguments(t))
        end
    end
    if t.alias ~= nil and checker.isKnownGenericTypeName(t.alias.symbol.name) then
        local symbol = self:getGlobalSymbol(t.alias.symbol.name, SymbolFlags.Type, nil)
        if symbol ~= nil and symbol == t.alias.symbol then
            return core.FirstOrNil(t.alias.typeArguments)
        end
    end
    return nil
end

-- Gets all symbols for one property. Does not get symbols for every property.
function Checker:GetPropertySymbolsFromContextualType(node, contextualType, unionSymbolOk)
    local name = ast.GetTextOfPropertyName(node:Name())
    if name == "" then
        return nil
    end
    if contextualType.flags & TypeFlags.Union == 0 then
        local symbol = self:getPropertyOfType(contextualType, name)
        if symbol ~= nil then
            return { symbol }
        end
        return nil
    end
    local filteredTypes = contextualType:Types()
    if ast.IsObjectLiteralExpression(node.parent) or ast.IsJsxAttributes(node.parent) then
        filteredTypes = core.Filter(filteredTypes, function(t)
            return not self:IsTypeInvalidDueToUnionDiscriminant(t, node.parent)
        end)
    end
    local discriminatedPropertySymbols = core.MapNonNil(filteredTypes, function(t)
        return self:getPropertyOfType(t, name)
    end)
    if unionSymbolOk and (core.Len(discriminatedPropertySymbols) == 0 or core.Len(discriminatedPropertySymbols) == core.Len(contextualType:Types())) then
        local symbol = self:getPropertyOfType(contextualType, name)
        if symbol ~= nil then
            return { symbol }
        end
    end
    if core.Len(filteredTypes) == 0 and core.Len(discriminatedPropertySymbols) == 0 then
        -- Bad discriminant -- do again without discriminating
        return core.MapNonNil(contextualType:Types(), function(t)
            return self:getPropertyOfType(t, name)
        end)
    end
    -- by eliminating duplicates we might even end up with a single symbol
    -- that helps with displaying better quick infos on properties of union types
    return core.Deduplicate(discriminatedPropertySymbols)
end

-- Gets the property symbol corresponding to the property in destructuring assignment
-- 'property1' from
--
--	for ( { property1: a } of elems) {
--	}
--
-- 'property1' at location 'a' from:
--
--	[a] = [ property1, property2 ]
function Checker:GetPropertySymbolOfDestructuringAssignment(location)
    if ast.IsArrayLiteralOrObjectLiteralDestructuringPattern(location.parent.parent) then
        -- Get the type of the object or array literal and then look for property of given name in the type
        local typeOfObjectLiteral = self:getTypeOfAssignmentPattern(location.parent.parent)
        if typeOfObjectLiteral ~= nil then
            return self:getPropertyOfType(typeOfObjectLiteral, location:Text())
        end
    end
    return nil
end

-- Gets the type of object literal or array literal of destructuring assignment.
-- { a } from
--
--	for ( { a } of elems) {
--	}
--
-- [ a ] from
--
--	[a] = [ some array ...]
function Checker:getTypeOfAssignmentPattern(expr)
    -- If this is from "for of"
    --     for ( { a } of elems) {
    --     }
    if ast.IsForOfStatement(expr.parent) then
        local iteratedType = self:checkRightHandSideOfForOf(expr.parent)
        return self:checkDestructuringAssignment(expr, core.OrElse(iteratedType, self.errorType), CheckMode.Normal, false)
    end
    -- If this is from "for" initializer
    --     for ({a } = elems[0];.....) { }
    if ast.IsBinaryExpression(expr.parent) then
        local iteratedType = self:getTypeOfExpression(expr.parent:AsBinaryExpression().right)
        return self:checkDestructuringAssignment(expr, core.OrElse(iteratedType, self.errorType), CheckMode.Normal, false)
    end
    -- If this is from nested object binding pattern
    --     for ({ skills: { primary, secondary } } = multiRobot, i = 0; i < 1; i++) {
    if ast.IsPropertyAssignment(expr.parent) then
        local node = expr.parent.parent
        local typeOfParentObjectLiteral = core.OrElse(self:getTypeOfAssignmentPattern(node), self.errorType)
        local propertyIndex = slicesIndex(node:Properties(), expr.parent)
        return self:checkObjectLiteralDestructuringPropertyAssignment(node, typeOfParentObjectLiteral, propertyIndex, nil, false)
    end
    -- Array literal assignment - array destructuring pattern
    local node = expr.parent
    --    [{ property1: p1, property2 }] = elems;
    local typeOfArrayLiteral = core.OrElse(self:getTypeOfAssignmentPattern(node), self.errorType)
    local elementType = core.OrElse(self:checkIteratedTypeOrElementType(IterationUse.Destructuring, typeOfArrayLiteral, self.undefinedType, expr.parent), self.errorType)
    return self:checkArrayLiteralDestructuringElementAssignment(node, typeOfArrayLiteral, slicesIndex(node:Elements(), expr), elementType, CheckMode.Normal)
end

function Checker:GetSignatureFromDeclaration(node)
    return self:getSignatureFromDeclaration(node)
end

-- IsLibSymbolForHoverVerbosity returns true if a symbol is declared in a lib file.
function Checker:IsLibSymbolForHoverVerbosity(symbol)
    if symbol == nil then
        return false
    end
    for _, decl in ipairs(symbol.declarations or {}) do
        local sf = ast.GetSourceFileOfNode(decl)
        if sf ~= nil and self.program:IsSourceFileDefaultLibrary(sf:Path()) then
            return true
        end
    end
    return false
end

-- IsLibTypeForHoverVerbosity returns true if a type is declared in a lib file.
-- Don't expand types like Array or Promise, instead treating them as opaque.
function Checker:IsLibTypeForHoverVerbosity(t)
    local symbol
    if t.objectFlags & ObjectFlags.Reference ~= 0 then
        symbol = t:Target():Symbol()
    else
        symbol = t:Symbol()
    end
    if self:IsLibSymbolForHoverVerbosity(symbol) then
        return true
    end
    return checker.isTupleType(t)
end
