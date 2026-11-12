local checker = require("tslua.checker")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local jsnum = require("tslua.jsnum")
local nodebuilder = require("tslua.nodebuilder")
local scanner = require("tslua.scanner")

local NodeBuilderImpl = checker.NodeBuilderImpl
local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local SignatureFlags = checker.SignatureFlags
local SignatureKind = checker.SignatureKind

-- Go method value `b.f.NewModifier`.
local function newModifierFn(b)
    return function(kind) return b.f:NewModifier(kind) end
end

-- isExpanding returns whether the node builder context is operating in hover-expansion mode.
function checker.isExpanding(ctx)
    return ctx.maxExpansionDepth ~= -1
end

-- expandSymbolForHover produces declaration nodes (class, interface, enum, module) for a symbol
-- for expandable hover. This is a focused alternative to the full symbolTableToDeclarationStatements
-- machinery used by declaration emit — it directly builds the declaration nodes hover needs
-- without the declaration-emit scaffolding (deferred privates, symbol name remapping, export
-- modifier computation, alias resolution, visited symbols tracking).
function NodeBuilderImpl:expandSymbolForHover(symbol)
    local results = nil
    if symbol.flags & SymbolFlags.Enum ~= 0 then
        local node = self:expandEnumDecl(symbol)
        if node ~= nil then
            results = core.Append(results, node)
        end
    end
    if symbol.flags & SymbolFlags.Class ~= 0 then
        local node = self:expandClassDecl(symbol)
        if node ~= nil then
            results = core.Append(results, node)
        end
    end
    -- Module/namespace before interface (matching Strada ordering for merged declarations)
    if symbol.flags & (SymbolFlags.ValueModule | SymbolFlags.NamespaceModule) ~= 0 then
        local node = self:expandModuleDecl(symbol)
        if node ~= nil then
            results = core.Append(results, node)
        end
    end
    if symbol.flags & SymbolFlags.Interface ~= 0 and symbol.flags & SymbolFlags.Class == 0 then
        local node = self:expandInterfaceDecl(symbol)
        if node ~= nil then
            results = core.Append(results, node)
        end
    end
    return results
end

-- expandEnumDecl produces an EnumDeclaration node with all members.
function NodeBuilderImpl:expandEnumDecl(symbol)
    local b = self
    local name = ast.SymbolName(symbol)
    b.ctx.approximateLength = b.ctx.approximateLength + 9 + #name
    local memberProps = core.Filter(b.ch:getPropertiesOfType(b.ch:getTypeOfSymbol(symbol)), function(p)
        return p.flags & SymbolFlags.EnumMember ~= 0
    end) or {}
    local members = {}
    for i1, p in ipairs(memberProps) do
        local i = i1 - 1
        if b:checkTruncationLengthIfExpanding() and i + 3 < #memberProps - 1 then
            b.ctx.expansionTruncated = true
            members[#members + 1] = b.f:NewEnumMember(b.f:NewStringLiteral(string.format(" ... %d more ... ", #memberProps - i - 1), 0), nil)
            local last = memberProps[#memberProps]
            members[#members + 1] = b.f:NewEnumMember(b.f:NewIdentifier(last.name), b:enumMemberInitializer(last))
            break
        end
        local memberDecl = core.Find(p.declarations, ast.IsEnumMember)
        local initializer
        if memberDecl ~= nil and memberDecl:AsEnumMember().initializer ~= nil then
            initializer = b.f:DeepCloneNode(memberDecl:AsEnumMember().initializer)
        else
            initializer = b:enumMemberInitializer(p)
        end
        b.ctx.approximateLength = b.ctx.approximateLength + 4 + #p.name
        if initializer ~= nil then
            b.ctx.approximateLength = b.ctx.approximateLength + 5 -- " = " + value estimate
        end
        members[#members + 1] = b.f:NewEnumMember(b.f:NewIdentifier(p.name), initializer)
    end

    local constModifier = ModifierFlags.None
    if checker.isConstEnumSymbol(symbol) then
        constModifier = ModifierFlags.Const
    end
    local mods
    if constModifier ~= 0 then
        mods = b.f:NewModifierList(ast.CreateModifiersFromModifierFlags(constModifier, newModifierFn(b)))
    end
    return b.f:NewEnumDeclaration(mods, b.f:NewIdentifier(name), b.f:NewNodeList(members))
end

function NodeBuilderImpl:enumMemberInitializer(p)
    local memberDecl = core.Find(p.declarations, ast.IsEnumMember)
    if memberDecl == nil then
        return nil
    end
    local val = self.ch:GetConstantValue(memberDecl)
    if val == nil then
        return nil
    end
    if type(val) == "string" then
        return self.f:NewStringLiteral(val, 0)
    elseif type(val) == "number" then
        return self.f:NewNumericLiteral(jsnum.Number_String(val), 0)
    end
    return nil
end

-- expandClassDecl produces a ClassDeclaration node with heritage clauses and members.
function NodeBuilderImpl:expandClassDecl(symbol)
    local b = self
    local name = ast.SymbolName(symbol)
    b.ctx.approximateLength = b.ctx.approximateLength + 9 + #name

    local classLikeDeclarations = core.Filter(symbol.declarations, ast.IsClassLike)
    local originalDecl = core.FirstOrNil(classLikeDeclarations)
    local oldEnclosing = b.ctx.enclosingDeclaration
    if originalDecl ~= nil then
        b.ctx.enclosingDeclaration = originalDecl
    end

    local localParams = b.ch:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    local typeParamDecls = core.Map(localParams, function(p) return b:typeParameterToDeclaration(p) end)

    local declaredType = b.ch:getDeclaredTypeOfClassOrInterface(symbol)
    local classType = b.ch:getTypeWithThisArgument(declaredType, nil, false)
    local baseTypes = b.ch:getBaseTypes(b.ch:getTargetType(classType))
    local staticType = b.ch:getTypeOfSymbol(symbol)
    local isClass = staticType.symbol ~= nil and staticType.symbol.valueDeclaration ~= nil and ast.IsClassLike(staticType.symbol.valueDeclaration)
    local staticBaseType
    if isClass then
        staticBaseType = b.ch:getBaseConstructorTypeOfClass(declaredType)
    else
        staticBaseType = b.ch.anyType
    end

    -- Heritage clauses
    local heritageClauses = b:hoverHeritageClauses(classLikeDeclarations)

    -- Instance members via addPropertyToElementList (reusing existing serialization),
    -- then convert TypeElements to ClassElements and add class-specific modifiers
    local allProps = b.ch:getPropertiesOfType(classType)
    local symbolProps = b:filterInheritedProperties(classType, baseTypes, allProps)
    local publicProps = core.Filter(symbolProps, function(s) return not checker.isHashPrivate(s) end)
    local hasPrivate = core.Some(symbolProps, checker.isHashPrivate)

    local instanceMembers = nil
    instanceMembers = b:serializePropertiesWithTruncation(publicProps, instanceMembers)
    instanceMembers = checker.typeElementsToClassElements(b.f, instanceMembers)
    instanceMembers = b:addClassModifiers(instanceMembers, false)

    -- Static members
    local staticProps = core.Filter(b.ch:getPropertiesOfType(staticType), function(p)
        return p.flags & SymbolFlags.Prototype == 0 and p.name ~= "prototype" and not b:isNamespaceMember(p)
    end)
    local staticMembers = nil
    staticMembers = b:serializePropertiesWithTruncation(staticProps, staticMembers)
    staticMembers = checker.typeElementsToClassElements(b.f, staticMembers)
    staticMembers = b:addClassModifiers(staticMembers, true)

    -- Hash-private members
    local privateMembers = nil
    if hasPrivate then
        privateMembers = b:serializePropertiesWithTruncation(core.Filter(symbolProps, checker.isHashPrivate), privateMembers)
        privateMembers = checker.typeElementsToClassElements(b.f, privateMembers)
    end

    -- Constructors
    local constructors = b:serializeConstructors(staticType, staticBaseType, isClass, symbol)

    -- Index signatures
    local indexSigs = b:serializeIndexSignaturesOfType(classType, core.FirstOrNil(baseTypes))

    local allMembers = {}
    core.AppendAll(allMembers, indexSigs)
    core.AppendAll(allMembers, staticMembers)
    core.AppendAll(allMembers, constructors)
    core.AppendAll(allMembers, instanceMembers)
    core.AppendAll(allMembers, privateMembers)

    local result = b.f:NewClassDeclaration(nil, b.f:NewIdentifier(name), b.f:NewNodeList(typeParamDecls), b.f:NewNodeList(heritageClauses), b.f:NewNodeList(allMembers))
    b.ctx.enclosingDeclaration = oldEnclosing
    return result
end

-- addClassModifiers post-processes class member nodes to add class-specific modifiers
-- (private, protected, public, abstract, static) based on the original symbol declarations.
function NodeBuilderImpl:addClassModifiers(members, isStatic)
    local b = self
    for i, m in ipairs(members or {}) do
        -- Find the symbol for this member by matching the property name
        local memberSymbol
        local memberName = m:Name()
        if memberName ~= nil then
            local sym = b.idToSymbol[memberName]
            if sym ~= nil then
                memberSymbol = sym
            end
        end
        if memberSymbol ~= nil then
            local modFlags = checker.getDeclarationModifierFlagsFromSymbol(memberSymbol) & ~ModifierFlags.Async
            if isStatic then
                modFlags = modFlags | ModifierFlags.Static
            end
            if modFlags ~= 0 and ast.CanHaveModifiers(m) then
                local existing = m:ModifierFlags()
                if modFlags ~= existing then
                    members[i] = ast.ReplaceModifiers(b.f, m, b.f:NewModifierList(ast.CreateModifiersFromModifierFlags(modFlags | existing, newModifierFn(b))))
                end
            end
        end
    end
    return members
end

-- typeElementsToClassElements converts TypeElement nodes (PropertySignature, MethodSignature)
-- to their ClassElement equivalents (PropertyDeclaration, MethodDeclaration) so they can be
-- used as members of a ClassDeclaration. Nodes that are already ClassElements pass through unchanged.
function checker.typeElementsToClassElements(f, members)
    for i, m in ipairs(members or {}) do
        if m.kind == Kind.PropertySignature then
            local ps = m:AsPropertySignatureDeclaration()
            members[i] = f:NewPropertyDeclaration(m:Modifiers(), ps:Name(), ps:QuestionToken(), ps.type, nil)
        elseif m.kind == Kind.MethodSignature then
            local ms = m:AsMethodSignatureDeclaration()
            members[i] = f:NewMethodDeclaration(m:Modifiers(), nil, ms:Name(), ms:QuestionToken(), ms.typeParameters, ms.parameters, ms.type, nil, nil)
        end
    end
    return members
end

-- expandInterfaceDecl produces an InterfaceDeclaration with members.
-- Reuses addPropertyToElementList for property serialization and
-- signatureToSignatureDeclarationHelper for signatures.
function NodeBuilderImpl:expandInterfaceDecl(symbol)
    local b = self
    local name = ast.SymbolName(symbol)
    b.ctx.approximateLength = b.ctx.approximateLength + 14 + #name

    local interfaceType = b.ch:getDeclaredTypeOfClassOrInterface(symbol)
    local interfaceDeclarations = core.Filter(symbol.declarations, ast.IsInterfaceDeclaration)
    local localParams = b.ch:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    local typeParamDecls = core.Map(localParams, function(p) return b:typeParameterToDeclaration(p) end)
    local baseTypes = b.ch:getBaseTypes(interfaceType)
    local baseType
    if core.Len(baseTypes) > 0 then
        baseType = b.ch:getIntersectionType(baseTypes)
    end

    -- Members: reuse existing serialization functions
    local resolved = b.ch:resolveStructuredTypeMembers(interfaceType)
    local members = nil

    -- Index signatures, filtering those identical to base
    members = core.AppendAll(members, b:serializeIndexSignaturesOfType(interfaceType, baseType))
    -- Construct signatures (skip abstract)
    for _, sig in ipairs(resolved:ConstructSignatures() or {}) do
        if sig.flags & SignatureFlags.Abstract == 0 then
            members = core.Append(members, b:signatureToSignatureDeclarationHelper(sig, Kind.ConstructSignature, nil))
        end
    end
    -- Call signatures
    for _, sig in ipairs(resolved:CallSignatures() or {}) do
        members = core.Append(members, b:signatureToSignatureDeclarationHelper(sig, Kind.CallSignature, nil))
    end
    -- Properties, filtering inherited
    local filteredProps = b:filterInheritedProperties(interfaceType, baseTypes, resolved.properties)
    members = b:serializePropertiesWithTruncation(filteredProps, members)

    -- Heritage clauses
    local heritageClauses = b:hoverHeritageClauses(interfaceDeclarations)

    return b.f:NewInterfaceDeclaration(nil, b.f:NewIdentifier(name), b.f:NewNodeList(typeParamDecls), b.f:NewNodeList(heritageClauses), b.f:NewNodeList(members))
end

function NodeBuilderImpl:hoverHeritageClauses(declarations)
    local b = self
    local extendsTypes = nil
    local implementsTypes = nil
    for _, declaration in ipairs(declarations or {}) do
        for _, heritageElement in ipairs(ast.GetExtendsHeritageClauseElements(declaration) or {}) do
            extendsTypes = core.Append(extendsTypes, b.f:DeepCloneNode(heritageElement))
        end
        for _, heritageElement in ipairs(ast.GetImplementsHeritageClauseElements(declaration) or {}) do
            implementsTypes = core.Append(implementsTypes, b.f:DeepCloneNode(heritageElement))
        end
    end

    local heritageClauses = nil
    if core.Len(extendsTypes) > 0 then
        heritageClauses = core.Append(heritageClauses, b.f:NewHeritageClause(Kind.ExtendsKeyword, b.f:NewNodeList(extendsTypes)))
    end
    if core.Len(implementsTypes) > 0 then
        heritageClauses = core.Append(heritageClauses, b.f:NewHeritageClause(Kind.ImplementsKeyword, b.f:NewNodeList(implementsTypes)))
    end
    return heritageClauses
end

-- serializePropertiesWithTruncation iterates properties using addPropertyToElementList,
-- with truncation checks matching Strada's createTypeNodesFromResolvedType behavior.
function NodeBuilderImpl:serializePropertiesWithTruncation(properties, elements)
    local b = self
    properties = core.Filter(properties, function(p)
        return p.flags & SymbolFlags.Prototype == 0
    end) or {}
    for i1, p in ipairs(properties) do
        local i = i1 - 1
        if b:checkTruncationLengthIfExpanding() and (i + 3 < #properties - 1) then
            b.ctx.expansionTruncated = true
            local text = string.format("... %d more ...", #properties - i - 1)
            elements = core.Append(elements, b.f:NewPropertySignatureDeclaration(nil, b.f:NewIdentifier(text), nil, nil, nil))
            elements = b:addPropertyToElementList(properties[#properties], elements)
            break
        end
        elements = b:addPropertyToElementList(p, elements)
    end
    return elements
end

local function allSignaturesHaveNoParameters(signatures)
    return core.Every(signatures, function(sig) return core.Len(sig.parameters) == 0 end)
end

-- serializeConstructors builds constructor signature(s) for a class, with base type filtering.
function NodeBuilderImpl:serializeConstructors(staticType, staticBaseType, isClass, symbol)
    local b = self
    local isNonConstructable = not isClass and
        symbol.valueDeclaration ~= nil and
        ast.IsInJSFile(symbol.valueDeclaration) and
        core.Len(b.ch:getSignaturesOfType(staticType, SignatureKind.Construct)) == 0
    if isNonConstructable then
        b.ctx.approximateLength = b.ctx.approximateLength + 21
        local modifiers = ast.CreateModifiersFromModifierFlags(ModifierFlags.Private, newModifierFn(b))
        return { b.f:NewConstructorDeclaration(b.f:NewModifierList(modifiers), nil, b.f:NewNodeList(nil), nil, nil, nil) }
    end
    local signatures = b.ch:getSignaturesOfType(staticType, SignatureKind.Construct)
    if staticBaseType ~= nil then
        local baseSigs = b.ch:getSignaturesOfType(staticBaseType, SignatureKind.Construct)
        if core.Len(baseSigs) == 0 and allSignaturesHaveNoParameters(signatures) then
            return nil
        end
        if core.Len(baseSigs) == core.Len(signatures) then
            local allMatch = true
            for i = 1, core.Len(baseSigs) do
                if b.ch:compareSignaturesIdentical(signatures[i], baseSigs[i], false, false, true, function(s, t) return b.ch:compareTypesIdentical(s, t) end) ~= checker.Ternary.True then
                    allMatch = false
                    break
                end
            end
            if allMatch then
                return nil
            end
        end
        local privateProtected = 0
        for _, sig in ipairs(signatures or {}) do
            if sig.declaration ~= nil then
                privateProtected = privateProtected | (sig.declaration:ModifierFlags() & (ModifierFlags.Private | ModifierFlags.Protected))
            end
        end
        if privateProtected ~= 0 then
            return { b.f:NewConstructorDeclaration(
                b.f:NewModifierList(ast.CreateModifiersFromModifierFlags(privateProtected, newModifierFn(b))),
                nil, b.f:NewNodeList(nil), nil, nil, nil
            ) }
        end
    elseif allSignaturesHaveNoParameters(signatures) then
        return nil
    end
    local result = nil
    for _, sig in ipairs(signatures or {}) do
        b.ctx.approximateLength = b.ctx.approximateLength + 1
        result = core.Append(result, b:signatureToSignatureDeclarationHelper(sig, Kind.Constructor, nil))
    end
    return result
end

-- serializeIndexSignaturesOfType builds index signature declarations, filtering those identical to baseType.
function NodeBuilderImpl:serializeIndexSignaturesOfType(input, baseType)
    local b = self
    local result = nil
    for _, info in ipairs(b.ch:getIndexInfosOfType(input) or {}) do
        local skip = false
        if baseType ~= nil then
            local baseInfo = b.ch:getIndexInfoOfType(baseType, info.keyType)
            if baseInfo ~= nil and b.ch:isTypeIdenticalTo(info.valueType, baseInfo.valueType) then
                skip = true
            end
        end
        if not skip then
            result = core.Append(result, b:indexInfoToIndexSignatureDeclarationHelper(info, nil))
        end
    end
    return result
end

-- serializeNamespaceMember produces the appropriate declaration node for a namespace member
-- based on its symbol flags (type alias, enum, class, interface, nested namespace, or variable).
function NodeBuilderImpl:serializeNamespaceMember(resolved, name)
    local b = self
    if resolved.flags & SymbolFlags.TypeAlias ~= 0 then
        return b:serializeTypeAliasForNamespace(resolved, name)
    elseif resolved.flags & SymbolFlags.Enum ~= 0 then
        return b:expandEnumDecl(resolved)
    elseif resolved.flags & SymbolFlags.Class ~= 0 then
        return b:expandClassDecl(resolved)
    elseif resolved.flags & SymbolFlags.Interface ~= 0 then
        return b:expandInterfaceDecl(resolved)
    elseif resolved.flags & (SymbolFlags.ValueModule | SymbolFlags.NamespaceModule) ~= 0 then
        return b:expandModuleDecl(resolved)
    else
        local t = b.ch:getWidenedType(b.ch:getTypeOfSymbol(resolved))
        b.ctx.approximateLength = b.ctx.approximateLength + #name + 5
        return b.f:NewVariableStatement(
            nil,
            b.f:NewVariableDeclarationList(
                b.f:NewNodeList({
                    b.f:NewVariableDeclaration(b.f:NewIdentifier(name), nil, b:serializeTypeForDeclaration(nil, t, resolved, true), nil),
                }),
                NodeFlags.Let
            )
        )
    end
end

-- expandModuleDecl produces a ModuleDeclaration with exported members.
function NodeBuilderImpl:expandModuleDecl(symbol)
    local b = self
    local exports = b.ch:getExportsOfSymbol(symbol)
    local members = {}
    for _, sym in pairs(exports or {}) do
        -- Filter to namespace-relevant members
        if b:isNamespaceMember(sym) and scanner.IsIdentifierText(sym.name, core.LanguageVariant.Standard) then
            members[#members + 1] = sym
        end
    end
    b.ch:sortSymbols(members)
    b.ctx.approximateLength = b.ctx.approximateLength + 14

    -- Use the same name as symbol display.
    local oldFlags = b.ctx.flags
    b.ctx.flags = b.ctx.flags | nodebuilder.Flags.WriteTypeParametersInQualifiedName | checker.SymbolFormatFlags.UseOnlyExternalAliasing
    local localName = b:symbolToNode(symbol, SymbolFlags.All)
    b.ctx.flags = oldFlags

    -- hoverStatement: { node, isLocal } (local declarations (e.g. alias targets) should not get export modifier)
    local bodyStmts = {}
    local emittedLocals = collections.NewSet()
    local i = 0
    while i < #members do
        local m = members[i + 1]
        if b:checkTruncationLengthIfExpanding() and i + 3 < #members - 1 then
            b.ctx.expansionTruncated = true
            bodyStmts[#bodyStmts + 1] = { node = b.f:NewExpressionStatement(b.f:NewIdentifier(string.format("... (%d more) ...", #members - i - 1))), isLocal = false }
            i = #members - 2 -- skip to last member after i++ at end of iteration
            goto continue
        end

        -- Handle alias/re-export symbols
        if m.flags & SymbolFlags.Alias ~= 0 then
            local aliasDecl = b.ch:getDeclarationOfAliasSymbol(m)
            local target = b.ch:getMergedSymbol(b.ch:getTargetOfAliasDeclaration(aliasDecl))
            if target ~= nil then
                -- If the alias target is a local symbol (not itself an export), emit its declaration first
                if target.flags & (SymbolFlags.BlockScopedVariable | SymbolFlags.FunctionScopedVariable | SymbolFlags.Property) ~= 0 then
                    if emittedLocals:AddIfAbsent(target) then
                        local localType = b.ch:getWidenedType(b.ch:getTypeOfSymbol(target))
                        b.ctx.approximateLength = b.ctx.approximateLength + #target.name + 5
                        local localStmt = b.f:NewVariableStatement(nil,
                            b.f:NewVariableDeclarationList(b.f:NewNodeList({
                                b.f:NewVariableDeclaration(b.f:NewIdentifier(target.name), nil, b:serializeTypeForDeclaration(nil, localType, target, true), nil),
                            }), NodeFlags.Let))
                        bodyStmts[#bodyStmts + 1] = { node = localStmt, isLocal = true }
                    end
                end
                local targetName = target.name
                b.ctx.approximateLength = b.ctx.approximateLength + 16 + #m.name
                local propertyName
                if m.name ~= targetName then
                    propertyName = b.f:NewIdentifier(targetName)
                end
                local stmt = b.f:NewExportDeclaration(
                    nil, false,
                    b.f:NewNamedExports(b.f:NewNodeList({
                        b.f:NewExportSpecifier(false, propertyName, b.f:NewIdentifier(m.name)),
                    })),
                    nil, nil
                )
                bodyStmts[#bodyStmts + 1] = { node = stmt, isLocal = false }
                goto continue
            end
        end

        do
            local resolved = b.ch:resolveSymbol(m)

            -- Handle functions as function declarations
            if resolved.flags & (SymbolFlags.Function | SymbolFlags.Method) ~= 0 then
                local t = b.ch:getTypeOfSymbol(resolved)
                local sigs = b.ch:getSignaturesOfType(t, SignatureKind.Call)
                for _, sig in ipairs(sigs or {}) do
                    b.ctx.approximateLength = b.ctx.approximateLength + 1
                    local decl = b:signatureToSignatureDeclarationHelper(sig, Kind.FunctionDeclaration, checker.SignatureToSignatureDeclarationOptions_new({
                        name = b.f:NewIdentifier(m.name),
                    }))
                    bodyStmts[#bodyStmts + 1] = { node = decl, isLocal = false }
                end
                -- If the function also has namespace characteristics, emit an empty namespace.
                local merged = b.ch:getMergedSymbol(resolved)
                local hasModuleExports = merged.flags & (SymbolFlags.ValueModule | SymbolFlags.NamespaceModule) ~= 0 and merged.exports ~= nil and next(merged.exports) ~= nil
                if not hasModuleExports then
                    bodyStmts[#bodyStmts + 1] = { node = b.f:NewModuleDeclaration(nil, Kind.NamespaceKeyword, b.f:NewIdentifier(m.name), b.f:NewModuleBlock(b.f:NewNodeList(nil))), isLocal = false }
                end
                goto continue
            end

            -- Handle remaining member kinds (type alias, enum, class, interface, namespace, variable)
            local node = b:serializeNamespaceMember(resolved, m.name)
            if node ~= nil then
                bodyStmts[#bodyStmts + 1] = { node = node, isLocal = false }
            end
        end
        ::continue::
        i = i + 1
    end

    -- Add export modifier to exported statements (skip local declarations and ExportDeclarations).
    for _, s in ipairs(bodyStmts) do
        if not (s.isLocal or ast.IsExportDeclaration(s.node)) then
            if ast.CanHaveModifiers(s.node) then
                local mf = s.node:ModifierFlags() | ModifierFlags.Export
                s.node = ast.ReplaceModifiers(b.f, s.node, b.f:NewModifierList(ast.CreateModifiersFromModifierFlags(mf, newModifierFn(b))))
            end
        end
    end

    -- Collect nodes, stripping export if all statements are exported.
    local bodyStatements = {}
    for idx, s in ipairs(bodyStmts) do
        bodyStatements[idx] = s.node
    end
    local allExported = #bodyStatements > 0 and core.Every(bodyStatements, function(d)
        return ast.HasSyntacticModifier(d, ModifierFlags.Export)
    end)
    if allExported then
        for idx, stmt in ipairs(bodyStatements) do
            if ast.CanHaveModifiers(stmt) then
                local mf = stmt:ModifierFlags() & ~ModifierFlags.Export
                bodyStatements[idx] = ast.ReplaceModifiers(b.f, stmt, b.f:NewModifierList(ast.CreateModifiersFromModifierFlags(mf, newModifierFn(b))))
            end
        end
    end

    local keyword = Kind.NamespaceKeyword
    if not ast.IsIdentifier(localName) then
        keyword = Kind.ModuleKeyword
    end
    return b.f:NewModuleDeclaration(nil, keyword, localName, b.f:NewModuleBlock(b.f:NewNodeList(bodyStatements)))
end

-- serializeTypeAliasForNamespace produces a TypeAliasDeclaration for a type alias inside a namespace body.
function NodeBuilderImpl:serializeTypeAliasForNamespace(symbol, name)
    local b = self
    local aliasType = b.ch:getDeclaredTypeOfTypeAlias(symbol)
    local typeParams = b.ch:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    local typeParamDecls = core.Map(typeParams, function(p) return b:typeParameterToDeclaration(p) end)
    local restoreFlags = b:saveRestoreFlags()
    b.ctx.flags = b.ctx.flags | nodebuilder.Flags.InTypeAlias
    local typeNode = b:typeToTypeNode(aliasType)
    restoreFlags()
    b.ctx.approximateLength = b.ctx.approximateLength + 8 + #name
    return b.f:NewTypeAliasDeclaration(nil, b.f:NewIdentifier(name), b.f:NewNodeList(typeParamDecls), typeNode)
end

-- filterInheritedProperties removes properties already present in base types.
function NodeBuilderImpl:filterInheritedProperties(t, baseTypes, properties)
    local b = self
    if core.Len(baseTypes) == 0 then
        return properties
    end
    -- Build a lookup from property name to symbol for parent-identity comparison.
    local propsByName = {}
    for _, p in ipairs(properties or {}) do
        propsByName[p.name] = p
    end
    -- Collect names of properties inherited unchanged from base types.
    local inherited = collections.NewSet()
    for _, base in ipairs(baseTypes) do
        local baseWithThis = b.ch:getTypeWithThisArgument(base, b.ch:getTargetType(t):AsInterfaceType().thisType, false)
        for _, prop in ipairs(b.ch:getPropertiesOfType(baseWithThis) or {}) do
            local existing = propsByName[prop.name]
            if existing ~= nil and prop.parent == existing.parent then
                inherited:Add(prop.name)
            end
        end
    end
    if inherited:Len() == 0 then
        return properties
    end
    return core.Filter(properties, function(p)
        return not inherited:Has(p.name)
    end)
end

function NodeBuilderImpl:isNamespaceMember(p)
    return p.flags & (SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias) ~= 0 or
        not (p.flags & SymbolFlags.Prototype ~= 0 or p.name == "prototype" or (p.valueDeclaration ~= nil and ast.HasStaticModifier(p.valueDeclaration) and ast.IsClassLike(p.valueDeclaration.parent)))
end

function checker.isHashPrivate(s)
    return s.valueDeclaration ~= nil and s.valueDeclaration:Name() ~= nil and ast.IsPrivateIdentifier(s.valueDeclaration:Name())
end

return checker
