local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function zeroRange()
    return { start = { line = 0, character = 0 }, end_ = { line = 0, character = 0 } }
end

local function locationKey(uri, r)
    return tostring(uri) .. "\0" .. r.start.line .. ":" .. r.start.character .. "-" .. r.end_.line .. ":" .. r.end_.character
end

function LanguageService:ProvideDefinition(ctx, documentURI, pos)
    if self:UserPreferences().preferGoToSourceDefinition then
        return self:ProvideSourceDefinition(ctx, documentURI, pos)
    end
    return self:provideDefinitionWorker(ctx, documentURI, pos)
end

function LanguageService:provideDefinitionWorker(ctx, documentURI, pos)
    local caps = lsproto.GetClientCapabilities(ctx)
    local clientSupportsLink = caps.textDocument.definition.linkSupport

    local program, file = self:getProgramAndFile(documentURI)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, pos, spanmap.Feature.Definition)
    local results = {}
    for _, mapped in ipairs(positions or {}) do
        if spanmap.Fidelity_IsSingleSegment(mapped.fidelity) then
            results[#results + 1] = self:provideDefinitionAtPosition(ctx, program, mapped.script, mapped.position, clientSupportsLink)
        end
    end
    return ls.combineDefinitionResponses(results, clientSupportsLink), nil
end

function LanguageService:provideDefinitionAtPosition(ctx, program, file, textPos, clientSupportsLink)
    local pos = textPos
    local node = astnav.GetTouchingPropertyName(file, pos)
    local reference = ls.getReferenceAtPosition(file, pos, program)

    if node.kind == Kind.SourceFile then
        return {}
    end

    local originSelectionRange = self:createLspRangeFromNode(node, file)
    if reference ~= nil and reference.file ~= nil then
        return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, {}, reference, spanmap.Feature.Definition)
    end

    local c, done = program:GetTypeCheckerForFile(ctx, file)
    local result = self:provideDefinitionAtPositionWorker(c, node, originSelectionRange, clientSupportsLink, reference)
    done()
    return result
end

-- Body of provideDefinitionAtPosition after the checker is acquired (split out so `defer done()` runs on every path).
function LanguageService:provideDefinitionAtPositionWorker(c, node, originSelectionRange, clientSupportsLink, reference)
    if node.kind == Kind.OverrideKeyword then
        local sym = ls.getSymbolForOverriddenMember(c, node)
        if sym ~= nil then
            return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, sym.declarations, nil --[[reference]], spanmap.Feature.Definition)
        end
    end

    if ast.IsJumpStatementTarget(node) then
        local label = ls.getTargetLabel(node.parent, node:Text())
        if label ~= nil then
            return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, { label }, nil --[[reference]], spanmap.Feature.Definition)
        end
    end

    if node.kind == Kind.CaseKeyword or node.kind == Kind.DefaultKeyword and ast.IsDefaultClause(node.parent) then
        local stmt = ast.FindAncestor(node.parent, ast.IsSwitchStatement)
        if stmt ~= nil then
            local file = ast.GetSourceFileOfNode(stmt)
            return self:createLocationFromFileAndRange(file, scanner.GetRangeOfTokenAtPosition(file, stmt:Pos()), spanmap.Feature.Definition)
        end
    end

    if node.kind == Kind.ReturnKeyword or node.kind == Kind.YieldKeyword or node.kind == Kind.AwaitKeyword then
        local fn = ast.FindAncestor(node, ast.IsFunctionLikeDeclaration)
        if fn ~= nil then
            return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, { fn }, nil --[[reference]], spanmap.Feature.Definition)
        end
    end

    local declarations = ls.getDeclarationsFromLocation(c, node)
    local calledDeclaration = ls.tryGetSignatureDeclaration(c, node)
    if calledDeclaration ~= nil and not (ast.IsJsxOpeningLikeElement(node.parent) and ls.isJsxConstructorLike(calledDeclaration)) then
        local symbol = c:GetSymbolAtLocation(ls.getDeclarationNameForKeyword(node))
        if symbol ~= nil and core.Some(c:GetRootSymbols(symbol), function(rootSymbol)
            return ls.symbolMatchesSignature(rootSymbol, calledDeclaration)
        end) then
            if not ast.IsConstructorDeclaration(calledDeclaration) then
                declarations = nil
            else
                declarations = core.Filter(declarations, function(n)
                    return n ~= calledDeclaration and (ast.IsClassDeclaration(n) or ast.IsClassExpression(n))
                end)
            end
        else
            declarations = core.Filter(declarations, function(n) return n ~= calledDeclaration end)
        end
        declarations = core.Append(core.Slice(declarations), calledDeclaration)
    end
    return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, declarations, reference, spanmap.Feature.Definition)
end

function LanguageService:ProvideTypeDefinition(ctx, documentURI, pos)
    local caps = lsproto.GetClientCapabilities(ctx)
    local clientSupportsLink = caps.textDocument.typeDefinition.linkSupport

    local program, file = self:getProgramAndFile(documentURI)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, pos, spanmap.Feature.TypeDefinition)
    local results = {}
    for _, mapped in ipairs(positions or {}) do
        if spanmap.Fidelity_IsSingleSegment(mapped.fidelity) then
            results[#results + 1] = self:provideTypeDefinitionAtPosition(ctx, program, mapped.script, mapped.position, clientSupportsLink)
        end
    end
    return ls.combineDefinitionResponses(results, clientSupportsLink), nil
end

function LanguageService:provideTypeDefinitionAtPosition(ctx, program, file, textPos, clientSupportsLink)
    local pos = textPos
    local node = astnav.GetTouchingPropertyName(file, pos)
    if node.kind == Kind.SourceFile then
        return {}
    end
    local originSelectionRange = self:createLspRangeFromNode(node, file)

    local c, done = program:GetTypeCheckerForFile(ctx, file)

    node = ls.getDeclarationNameForKeyword(node)

    local symbol = c:GetSymbolAtLocation(node)
    if symbol ~= nil then
        local symbolType = ls.getTypeOfSymbolAtLocation(c, symbol, node)
        local declarations = ls.getDeclarationsFromType(symbolType)
        local typeArgument = c:GetFirstTypeArgumentFromKnownType(symbolType)
        if typeArgument ~= nil then
            declarations = core.Concatenate(ls.getDeclarationsFromType(typeArgument), declarations)
        end
        if core.Len(declarations) ~= 0 then
            local result = self:createDefinitionLocations(originSelectionRange, clientSupportsLink, declarations, nil --[[reference]], spanmap.Feature.TypeDefinition)
            done()
            return result
        end
        if symbol.flags & SymbolFlags.Value == 0 and symbol.flags & SymbolFlags.Type ~= 0 then
            local result = self:createDefinitionLocations(originSelectionRange, clientSupportsLink, symbol.declarations, nil --[[reference]], spanmap.Feature.TypeDefinition)
            done()
            return result
        end
    end

    done()
    return {}
end

function ls.combineDefinitionResponses(results, links)
    local locations = {}
    local definitionLinks = {}
    local seen = collections.NewSet()
    for _, result in ipairs(results or {}) do
        if result.definitionLinks ~= nil then
            for _, link in ipairs(result.definitionLinks) do
                local location = { uri = link.targetUri, range = link.targetSelectionRange }
                if seen:AddIfAbsent(locationKey(location.uri, location.range)) then
                    definitionLinks[#definitionLinks + 1] = link
                    locations[#locations + 1] = location
                end
            end
        end
        if result.location ~= nil and seen:AddIfAbsent(locationKey(result.location.uri, result.location.range)) then
            locations[#locations + 1] = result.location
            definitionLinks[#definitionLinks + 1] = { targetUri = result.location.uri, targetRange = result.location.range, targetSelectionRange = result.location.range }
        end
        if result.locations ~= nil then
            for _, location in ipairs(result.locations) do
                if seen:AddIfAbsent(locationKey(location.uri, location.range)) then
                    locations[#locations + 1] = location
                    definitionLinks[#definitionLinks + 1] = { targetUri = location.uri, targetRange = location.range, targetSelectionRange = location.range }
                end
            end
        end
    end
    if links then
        return { definitionLinks = definitionLinks }
    end
    return { locations = locations }
end

function ls.getDeclarationNameForKeyword(node)
    if node.kind >= Kind.FirstKeyword and node.kind <= Kind.LastKeyword then
        if ast.IsVariableDeclarationList(node.parent) then
            local decl = core.FirstOrNil(node.parent:AsVariableDeclarationList().declarations.nodes)
            if decl ~= nil and decl:Name() ~= nil then
                return decl:Name()
            end
        elseif node.parent:DeclarationData() ~= nil and node.parent:Name() ~= nil and node:Pos() < node.parent:Name():Pos() then
            return node.parent:Name()
        end
    end
    return node
end

-- fileRange: { file, fileRange } (used as a set key: file table -> "pos:end")

function LanguageService:createDefinitionLocations(
    originSelectionRange,
    clientSupportsLink,
    declarations,
    reference,
    feature
)
    local locations = {}
    local locationRanges = {}
    local concreteTargets = collections.NewSet()
    local fileFallbacks = nil

    if reference ~= nil then
        local targetRange = {
            start = {
                line = 0,
                character = 0,
            },
            end_ = {
                line = 0,
                character = 0,
            },
        }
        locations[#locations + 1] = {
            originSelectionRange = originSelectionRange,
            targetUri = lsconv.FileNameToDocumentURI(reference.fileName),
            targetRange = targetRange,
            targetSelectionRange = targetRange,
        }
    end

    for _, decl in ipairs(declarations or {}) do
        local file = ast.GetSourceFileOfNode(decl)
        local name = core.OrElse(ast.GetNameOfDeclaration(decl), decl)
        local nameRange
        if name.kind == Kind.EmptyStatement then
            nameRange = core.NewTextRange(name:Pos(), name:Pos())
        else
            nameRange = ls.createRangeFromNode(name, file)
        end
        local rangesForFile = locationRanges[file]
        if rangesForFile == nil then
            rangesForFile = {}
            locationRanges[file] = rangesForFile
        end
        local rangeKey = nameRange:Pos() .. ":" .. nameRange:End()
        if not rangesForFile[rangeKey] then
            rangesForFile[rangeKey] = true
            local contextNode = core.OrElse(ls.getContextNode(decl), decl)
            local contextRange = core.OrElse(ls.toContextRange(nameRange, file, contextNode), nameRange)
            if not nameRange:ContainedBy(contextRange) then
                contextRange = core.NewTextRange(math.min(nameRange:Pos(), contextRange:Pos()), math.max(nameRange:End(), contextRange:End()))
            end
            local targetSelectionLoc, selectionFidelity = self:sourceFileRangeToLSPLocationForFeature(file, nameRange, feature)
            if not spanmap.Fidelity_IsSingleSegment(selectionFidelity) then
                local zr = zeroRange()
                fileFallbacks = core.Append(fileFallbacks, {
                    originSelectionRange = originSelectionRange,
                    targetSelectionRange = zr,
                    targetUri = targetSelectionLoc.uri,
                    targetRange = zr,
                })
                goto continue
            end
            do
                local targetLoc, contextFidelity = self:sourceFileRangeToLSPLocation(file, contextRange)
                if spanmap.Fidelity_IsNone(contextFidelity) or targetLoc.uri ~= targetSelectionLoc.uri or not ls.lspRangeContains(targetLoc.range, targetSelectionLoc.range) then
                    targetLoc = targetSelectionLoc
                end
                concreteTargets:Add(targetSelectionLoc.uri)
                locations[#locations + 1] = {
                    originSelectionRange = originSelectionRange,
                    targetSelectionRange = targetSelectionLoc.range,
                    targetUri = targetLoc.uri,
                    targetRange = targetLoc.range,
                }
            end
        end
        ::continue::
    end
    for _, fallback in ipairs(fileFallbacks or {}) do
        if not concreteTargets:Has(fallback.targetUri) then
            concreteTargets:Add(fallback.targetUri)
            locations[#locations + 1] = fallback
        end
    end

    if clientSupportsLink then
        return { definitionLinks = locations }
    end
    return ls.createLocationsFromLinks(locations)
end

function ls.lspRangeContains(outer, inner)
    return lsproto.ComparePositions(outer.start, inner.start) <= 0 and
        lsproto.ComparePositions(inner.end_, outer.end_) <= 0
end

function ls.createLocationsFromLinks(links)
    local locations = core.Map(links, function(link)
        return {
            uri = link.targetUri,
            range = link.targetSelectionRange,
        }
    end)
    return { locations = locations }
end

function LanguageService:createLocationFromFileAndRange(file, textRange, feature)
    local mappedLocation, fidelity = self:sourceFileRangeToLSPLocationForFeature(file, textRange, feature)
    if spanmap.Fidelity_IsNone(fidelity) then
        mappedLocation = { uri = mappedLocation.uri, range = zeroRange() }
    end
    return {
        location = mappedLocation,
    }
end

function ls.getDeclarationsFromLocation(c, node)
    if ast.IsIdentifier(node) and ast.IsShorthandPropertyAssignment(node.parent) then
        -- Because name in short-hand property assignment has two different meanings: property name and property value,
        -- using go-to-definition at such position should go to the variable declaration of the property value rather than
        -- go to the declaration of the property name (in this case stay at the same position). However, if go-to-definition
        -- is performed at the location of property access, we would like to go to definition of the property in the short-hand
        -- assignment. This case and others are handled by the following code.
        -- and the contextual type's property declarations
        local shorthandSymbol = c:GetResolvedSymbol(node)
        local declarations = nil
        if shorthandSymbol ~= nil then
            declarations = shorthandSymbol.declarations
        end
        local contextualDeclarations = ls.getDeclarationsFromObjectLiteralElement(c, node)
        return core.Concatenate(declarations, contextualDeclarations)
    end

    if ast.IsPropertyName(node) and ast.IsBindingElement(node.parent) and ast.IsObjectBindingPattern(node.parent.parent) then
        -- If the node is the name of a BindingElement within an ObjectBindingPattern instead of just returning the
        -- declaration of the symbol (which is itself), we should try to get to the original type of the
        -- ObjectBindingPattern and return the property declaration for the referenced property.
        -- For example:
        --      import('./foo').then(({ bar }) => undefined); => should navigate to the declaration in file "./foo"
        --
        --      function bar<T>(onfulfilled: (value: T) => void) { }
        --      interface Test { prop1: number }
        --      bar<Test>(({ prop1 }) => {});  => should navigate to prop1 in Test
        local bindingEl = node.parent:AsBindingElement()
        if bindingEl.dotDotDotToken == nil and node == core.OrElse(bindingEl.propertyName, node.parent:Name()) then
            local name, ok = ast.TryGetTextOfPropertyName(node)
            if ok then
                local t = c:GetTypeAtLocation(node.parent.parent)
                local types = { t }
                if t:IsUnion() then
                    types = t:Types()
                end
                local result = nil
                for _, unionType in ipairs(types) do
                    local prop = c:GetPropertyOfType(unionType, name)
                    if prop ~= nil then
                        result = core.AppendAll(result, prop.declarations)
                    end
                end
                return result
            end
        end
    end

    node = ls.getDeclarationNameForKeyword(node)
    local symbol = c:GetSymbolAtLocation(node)
    if symbol ~= nil then
        if symbol.flags & SymbolFlags.Class ~= 0 and symbol.flags & (SymbolFlags.Function | SymbolFlags.Variable) == 0 and node.kind == Kind.ConstructorKeyword then
            local constructor = symbol.members ~= nil and symbol.members[ast.InternalSymbolNameConstructor] or nil
            if constructor ~= nil then
                symbol = constructor
            end
        end
        if symbol.flags & SymbolFlags.Alias ~= 0 then
            local resolved, ok = c:ResolveAlias(symbol)
            if ok then
                symbol = resolved
            end
        end
        local objectLiteralElementDeclarations = ls.getDeclarationsFromObjectLiteralElement(c, node)
        if core.Len(objectLiteralElementDeclarations) > 0 then
            return objectLiteralElementDeclarations
        end
        if core.Len(symbol.declarations) > 0 then
            return symbol.declarations
        end
    end
    local indexInfos = c:GetIndexSignaturesAtLocation(node)
    if core.Len(indexInfos) ~= 0 then
        return indexInfos
    end
    return nil
end

-- getDeclarationsFromObjectLiteralElement returns declarations from the contextual type
-- of an object literal element, if available.
function ls.getDeclarationsFromObjectLiteralElement(c, node)
    local element = ls.getContainingObjectLiteralElement(node)
    if element == nil then
        return nil
    end

    local contextualType = c:GetContextualType(element.parent, checker.ContextFlags.None)
    if contextualType == nil then
        return nil
    end

    local properties = c:GetPropertySymbolsFromContextualType(element, contextualType, false --[[unionSymbolOk]])
    if core.Some(properties, function(p)
        return p.valueDeclaration ~= nil and ast.IsObjectLiteralExpression(p.valueDeclaration.parent) and ast.IsObjectLiteralElement(p.valueDeclaration) and p.valueDeclaration:Name() == node
    end) then
        local withoutNodeInferencesType = c:GetContextualType(element.parent, checker.ContextFlags.IgnoreNodeInferences)
        if withoutNodeInferencesType ~= nil then
            local withoutNodeInferencesProperties = c:GetPropertySymbolsFromContextualType(element, withoutNodeInferencesType, false --[[unionSymbolOk]])
            if core.Len(withoutNodeInferencesProperties) > 0 then
                properties = withoutNodeInferencesProperties
            end
        end
    end

    local result = nil
    for _, prop in ipairs(properties or {}) do
        result = core.AppendAll(result, prop.declarations)
    end
    return result
end

-- Returns a CallLikeExpression where `node` is the target being invoked.
function ls.getAncestorCallLikeExpression(node)
    local target = ast.FindAncestor(node, function(n)
        return not ast.IsRightSideOfPropertyAccess(n)
    end)
    local callLike = target.parent
    if callLike ~= nil and ast.IsCallLikeExpression(callLike) and ast.GetInvokedExpression(callLike) == target then
        return callLike
    end
    return nil
end

function ls.tryGetSignatureDeclaration(typeChecker, node)
    local signature = nil
    local callLike = ls.getAncestorCallLikeExpression(node)
    if callLike ~= nil then
        signature = typeChecker:GetResolvedSignature(callLike)
    end
    -- Don't go to a function type, go to the value having that type.
    if signature ~= nil and signature:Declaration() ~= nil then
        local declaration = signature:Declaration()
        if ast.IsFunctionLike(declaration) and not ast.IsFunctionTypeNode(declaration) then
            return declaration
        end
    end
    return nil
end

function ls.isJsxConstructorLike(node)
    if ast.IsConstructorDeclaration(node) or
        ast.IsConstructorTypeNode(node) or
        ast.IsCallSignatureDeclaration(node) or
        ast.IsConstructSignatureDeclaration(node) then
        return true
    else
        return false
    end
end

function ls.symbolMatchesSignature(symbol, calledDeclaration)
    if symbol == nil or calledDeclaration == nil then
        return false
    end
    local calledSymbol = calledDeclaration:Symbol()
    if symbol == calledSymbol or calledSymbol ~= nil and symbol == calledSymbol.parent then
        return true
    end
    local parent = calledDeclaration.parent
    return parent ~= nil and (ast.IsAssignmentExpression(parent, false --[[excludeCompoundAssignment]]) or
        not ast.IsCallLikeExpression(parent) and ast.CanHaveSymbol(parent) and symbol == parent:Symbol())
end

function ls.getSymbolForOverriddenMember(typeChecker, node)
    local classElement = ast.FindAncestor(node, ast.IsClassElement)
    if classElement == nil or classElement:Name() == nil then
        return nil
    end
    local baseDeclaration = ast.FindAncestor(classElement, ast.IsClassLike)
    if baseDeclaration == nil then
        return nil
    end
    local baseTypeNode = ast.GetClassExtendsHeritageElement(baseDeclaration)
    if baseTypeNode == nil then
        return nil
    end
    local expression = ast.SkipParentheses(baseTypeNode:Expression())
    local base
    if ast.IsClassExpression(expression) then
        base = expression:Symbol()
    else
        base = typeChecker:GetSymbolAtLocation(expression)
    end
    if base == nil then
        return nil
    end
    local name = ast.GetTextOfPropertyName(classElement:Name())
    if ast.HasStaticModifier(classElement) then
        return typeChecker:GetPropertyOfType(typeChecker:GetTypeOfSymbol(base), name)
    end
    return typeChecker:GetPropertyOfType(typeChecker:GetDeclaredTypeOfSymbol(base), name)
end

function ls.getTypeOfSymbolAtLocation(c, symbol, node)
    local t = c:GetTypeOfSymbolAtLocation(symbol, node)
    -- If the type is just a function's inferred type, go-to-type should go to the return type instead since
    -- go-to-definition takes you to the function anyway.
    if t:Symbol() == symbol or t:Symbol() ~= nil and symbol.valueDeclaration ~= nil and ast.IsVariableDeclaration(symbol.valueDeclaration) and symbol.valueDeclaration:Initializer() == t:Symbol().valueDeclaration then
        local sigs = c:GetCallSignatures(t)
        if core.Len(sigs) == 1 then
            return c:GetReturnTypeOfSignature(sigs[1])
        end
    end
    return t
end

function ls.getDeclarationsFromType(t)
    local result = nil
    for _, dt in ipairs(t:Distributed() or {}) do
        if dt:Symbol() ~= nil then
            for _, decl in ipairs(dt:Symbol().declarations or {}) do
                result = core.AppendIfUnique(result, decl)
            end
        end
    end
    return result
end
