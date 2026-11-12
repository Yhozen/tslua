local ls = require("tslua.ls")
local ast = require("tslua.ast")
local autoimport = require("tslua.ls.autoimport")
local checker = require("tslua.checker")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local lsutil = require("tslua.ls.lsutil")
local nodebuilder = require("tslua.nodebuilder")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local TokenFlags = ast.TokenFlags
local NBFlags = nodebuilder.Flags
local NBInternalFlags = nodebuilder.InternalFlags

-- type preserveOptionalFlags int
ls.preserveOptionalFlagsMethod = 1 << 0
ls.preserveOptionalFlagsProperty = 1 << 1
ls.preserveOptionalFlagsAll = ls.preserveOptionalFlagsMethod | ls.preserveOptionalFlagsProperty

local missingMemberFixer = {}
missingMemberFixer.__index = missingMemberFixer
ls.missingMemberFixer = missingMemberFixer

function ls.newMissingMemberFixer(changeTracker, program, typeChecker, preferences, importAdder, loc)
    return setmetatable({
        changeTracker = changeTracker,
        typeChecker = typeChecker,
        program = program,
        preferences = preferences,
        importAdder = importAdder,
        locale = loc,
    }, missingMemberFixer)
end

function missingMemberFixer:createNodeBuilder()
    local idToSymbol = {}
    local nodeBuilder = checker.NewNodeBuilderEx(self.typeChecker, self.changeTracker.emitContext, idToSymbol)
    return nodeBuilder, idToSymbol
end

function missingMemberFixer:createMemberFromSymbol(symbol, enclosingDeclaration, sourceFile, body, preserveOptional, abstract)
    local declarations = symbol.declarations
    local declaration = core.FirstOrNil(declarations)
    local factory = self.changeTracker.nodeFactory

    local quotePreference = lsutil.GetQuotePreference(sourceFile, self.preferences)
    local ambient = enclosingDeclaration.flags & NodeFlags.Ambient ~= 0
    local signatureOnly = ambient or abstract
    local optional = symbol.flags & SymbolFlags.Optional ~= 0
    local kind = Kind.PropertySignature
    if declaration ~= nil then
        kind = declaration.kind
    end
    local declarationName = ls.createDeclarationName(factory, self.typeChecker, symbol, declaration)
    local modifiers = self:createModifiers(symbol, declaration)

    local flags = NBFlags.NoTruncation
    if quotePreference == lsutil.QuotePreference.Single then
        flags = flags | NBFlags.UseSingleQuotesForStringLiteralType
    end

    local t = self.typeChecker:GetWidenedType(self.typeChecker:GetTypeOfSymbolAtLocation(symbol, enclosingDeclaration))
    local nodes = nil

    if kind == Kind.PropertySignature or kind == Kind.PropertyDeclaration then
        local nodeBuilder, idToSymbol = self:createNodeBuilder()
        local typeNode = self:createTypeNode(t, enclosingDeclaration, flags, nodeBuilder, idToSymbol)
        local questionToken = nil
        if optional and preserveOptional & ls.preserveOptionalFlagsProperty ~= 0 then
            questionToken = factory:NewToken(Kind.QuestionToken)
        end
        return core.Append(nodes, factory:NewPropertyDeclaration(modifiers, ls.createPropertyName(factory, declarationName, quotePreference), questionToken, typeNode, nil --[[initializer]]))
    elseif kind == Kind.GetAccessor or kind == Kind.SetAccessor then
        local nodeBuilder, idToSymbol = self:createNodeBuilder()
        local accessors = ast.GetAllAccessorDeclarations(symbol.declarations, declaration)
        local orderedAccessors = {}
        if accessors.secondAccessor == nil then
            orderedAccessors[#orderedAccessors + 1] = accessors.firstAccessor
        else
            orderedAccessors[#orderedAccessors + 1] = accessors.firstAccessor
            orderedAccessors[#orderedAccessors + 1] = accessors.secondAccessor
        end

        for _, accessor in ipairs(orderedAccessors) do
            if ast.IsGetAccessorDeclaration(accessor) then
                nodes = core.Append(
                    nodes,
                    factory:NewGetAccessorDeclaration(
                        modifiers, ls.createPropertyName(factory, declarationName, quotePreference),
                        nil --[[typeParameters]], nil --[[parameters]], self:createTypeNode(t, enclosingDeclaration, flags, nodeBuilder, idToSymbol), nil --[[fullSignature]], self:createBody(body, quotePreference, signatureOnly)
                    )
                )
            end

            if ast.IsSetAccessorDeclaration(accessor) then
                local parameter = checker.GetSetAccessorValueParameter(accessor)
                if parameter == nil then
                    error("Expected set accessor to have a parameter.", 0)
                end

                nodes = core.Append(nodes, factory:NewSetAccessorDeclaration(
                    modifiers, ls.createPropertyName(factory, declarationName, quotePreference),
                    nil --[[typeParameters]], ls.createDummyParameters(factory, 1, { parameter:Name():Text() }, { self:createTypeNode(t, enclosingDeclaration, flags, nodeBuilder, idToSymbol) }, 1, ast.IsInJSFile(enclosingDeclaration)),
                    nil --[[type]], nil --[[fullSignature]], self:createBody(body, quotePreference, signatureOnly)
                ))
            end
        end
        return nodes
    elseif kind == Kind.MethodSignature or kind == Kind.MethodDeclaration then
        local signatures = self:getCallSignatures(t)
        local preserveOptionalMethod = optional and preserveOptional & ls.preserveOptionalFlagsMethod ~= 0
        if core.Len(signatures) == 0 then
            return nil
        end

        if core.Len(declarations) == 1 then
            local method = self:createSignatureDeclarationFromSignature(core.FirstOrNil(signatures), Kind.MethodDeclaration, sourceFile, enclosingDeclaration, self:createBody(body, quotePreference, signatureOnly), modifiers, declarationName, preserveOptionalMethod)
            if method ~= nil then
                nodes = core.Append(nodes, method)
            end
            return nodes
        end

        for _, signature in ipairs(signatures) do
            if signature:Declaration() ~= nil and signature:Declaration().flags & NodeFlags.Ambient ~= 0 then
                goto continue
            end

            do
                local method = self:createSignatureDeclarationFromSignature(signature, Kind.MethodDeclaration, sourceFile, enclosingDeclaration, nil --[[body]], modifiers, declarationName, preserveOptionalMethod)
                if method ~= nil then
                    nodes = core.Append(nodes, method)
                end
            end
            ::continue::
        end

        if signatureOnly then
            return nodes
        end

        if core.Len(declarations) > #signatures then
            local signature = self.typeChecker:GetSignatureFromDeclaration(core.LastOrNil(declarations))
            local method = self:createSignatureDeclarationFromSignature(signature, Kind.MethodDeclaration, sourceFile, enclosingDeclaration, self:createBody(body, quotePreference, false --[[signatureOnly]]), modifiers, declarationName, preserveOptionalMethod)
            if method ~= nil then
                nodes = core.Append(nodes, method)
            end
        else
            local method = self:createSignatureDeclarationFromSignatures(signatures, declarationName, preserveOptionalMethod, modifiers, quotePreference, body, enclosingDeclaration)
            if method ~= nil then
                nodes = core.Append(nodes, method)
            end
        end

        return nodes
    end
    return nil
end

function missingMemberFixer:getCallSignatures(t)
    if t:IsUnion() then
        return core.FlatMap(t:Types(), function(member)
            return self.typeChecker:GetCallSignatures(member)
        end)
    end
    return self.typeChecker:GetCallSignatures(t)
end

function missingMemberFixer:createTypeNode(t, enclosingDeclaration, flags, nodeBuilder, idToSymbol)
    return self:importTypeNode(nodeBuilder:TypeToTypeNode(t, enclosingDeclaration, flags, NBInternalFlags.None, nil --[[tracker]]), idToSymbol)
end

function missingMemberFixer:createModifiers(symbol, declaration)
    local modifierFlags = ModifierFlags.None
    if declaration ~= nil then
        local effective = checker.GetDeclarationModifierFlagsFromSymbol(symbol)
        modifierFlags = effective & ModifierFlags.Static
        if effective & ModifierFlags.Public ~= 0 then
            modifierFlags = modifierFlags | ModifierFlags.Public
        elseif effective & ModifierFlags.Protected ~= 0 then
            modifierFlags = modifierFlags | ModifierFlags.Protected
        end
        if ast.IsAutoAccessorPropertyDeclaration(declaration) then
            modifierFlags = modifierFlags | ModifierFlags.Accessor
        end
    end
    if self:shouldAddOverrideKeyword(declaration) then
        modifierFlags = modifierFlags | ModifierFlags.Override
    end
    if modifierFlags == ModifierFlags.None then
        return nil
    end
    local factory = self.changeTracker.nodeFactory
    return factory:NewModifierList(ast.CreateModifiersFromModifierFlags(modifierFlags, function(kind)
        return factory:NewModifier(kind)
    end))
end

function missingMemberFixer:shouldAddOverrideKeyword(declaration)
    return declaration ~= nil and core.Tristate_IsTrue(self.program:Options().noImplicitOverride) and ast.HasAbstractModifier(declaration)
end

function missingMemberFixer:createSignatureDeclarationFromSignature(signature, kind, sourceFile, enclosingDeclaration, body, modifiers, name, optional)
    local factory = self.changeTracker.nodeFactory
    local quotePreference = lsutil.GetQuotePreference(sourceFile, self.preferences)
    local flags = NBFlags.NoTruncation | NBFlags.SuppressAnyReturnType | NBFlags.AllowEmptyTuple
    if quotePreference == lsutil.QuotePreference.Single then
        flags = flags | NBFlags.UseSingleQuotesForStringLiteralType
    end

    local nodeBuilder, idToSymbol = self:createNodeBuilder()
    local signatureDeclaration = nodeBuilder:SignatureToSignatureDeclaration(signature, kind, enclosingDeclaration, flags, NBInternalFlags.AllowUnresolvedNames, nil --[[tracker]])
    if signatureDeclaration == nil then
        return nil
    end

    local isJS = ast.IsInJSFile(enclosingDeclaration)
    local parameters = signatureDeclaration:ParameterList()
    local typeParameters = nil
    local typeNode = nil
    if not isJS then
        typeParameters = signatureDeclaration:TypeParameterList()
        typeNode = signatureDeclaration:Type()
    end

    if typeParameters ~= nil and core.Len(typeParameters.nodes) > 0 then
        local nodes = {}
        for _, tp in ipairs(typeParameters.nodes) do
            if tp == nil then
                goto continue
            end

            if ast.IsTypeParameterDeclaration(tp) then
                local typeParameter = tp:AsTypeParameterDeclaration()

                local constraint = typeParameter.constraint
                if constraint ~= nil then
                    constraint = self:importTypeNode(constraint, idToSymbol)
                end

                local defaultType = typeParameter.defaultType
                if defaultType ~= nil then
                    defaultType = self:importTypeNode(defaultType, idToSymbol)
                end

                nodes[#nodes + 1] = factory:UpdateTypeParameterDeclaration(typeParameter, typeParameter:Modifiers(), typeParameter:Name(), constraint, typeParameter.expression, defaultType)
            else
                nodes[#nodes + 1] = tp
            end
            ::continue::
        end
        typeParameters = factory:NewNodeList(nodes)
    end

    if parameters ~= nil then
        local nodes = {}
        for _, p in ipairs(parameters.nodes or {}) do
            if p == nil then
                goto continue
            end

            do
                local parameter = p:AsParameterDeclaration()
                local parameterTypeNode = parameter.type
                if parameterTypeNode ~= nil then
                    parameterTypeNode = self:importTypeNode(parameterTypeNode, idToSymbol)
                end

                local questionToken = nil
                if not isJS then
                    questionToken = parameter.questionToken
                end
                nodes[#nodes + 1] = factory:UpdateParameterDeclaration(parameter, parameter:Modifiers(), parameter.dotDotDotToken, parameter:Name(), questionToken, parameterTypeNode, parameter.initializer)
            end
            ::continue::
        end
        parameters = factory:NewNodeList(nodes)
    end

    if typeNode ~= nil then
        typeNode = self:importTypeNode(typeNode, idToSymbol)
    end

    local questionToken = nil
    if optional then
        questionToken = factory:NewToken(Kind.QuestionToken)
    end

    local identifierName = nil
    if name ~= nil and ast.IsIdentifier(name) then
        identifierName = name
    end

    if kind == Kind.FunctionExpression then
        local fn = signatureDeclaration:AsFunctionExpression()
        return factory:UpdateFunctionExpression(fn, modifiers, fn.asteriskToken, identifierName, typeParameters, parameters, typeNode, fn.fullSignature, core.OrElse(body, fn.body))
    elseif kind == Kind.ArrowFunction then
        local fn = signatureDeclaration:AsArrowFunction()
        return factory:UpdateArrowFunction(fn, modifiers, typeParameters, parameters, typeNode, fn.fullSignature, fn.equalsGreaterThanToken, core.OrElse(body, fn.body))
    elseif kind == Kind.MethodDeclaration then
        local method = signatureDeclaration:AsMethodDeclaration()
        local methodName
        if name == nil then
            methodName = factory:NewIdentifier("")
        else
            methodName = ls.createPropertyName(factory, name, quotePreference)
        end
        return factory:UpdateMethodDeclaration(method, modifiers, method.asteriskToken, methodName, questionToken, typeParameters, parameters, typeNode, method.fullSignature, body)
    elseif kind == Kind.FunctionDeclaration then
        local fn = signatureDeclaration:AsFunctionDeclaration()
        return factory:UpdateFunctionDeclaration(fn, modifiers, fn.asteriskToken, identifierName, typeParameters, parameters, typeNode, fn.fullSignature, core.OrElse(body, fn.body))
    end

    return nil
end

function missingMemberFixer:createSignatureDeclarationFromSignatures(signatures, name, optional, modifiers, quotePreference, body, enclosingDeclaration)
    if core.Len(signatures) == 0 then
        return nil
    end

    local factory = self.changeTracker.nodeFactory
    local nodeBuilder, idToSymbol = self:createNodeBuilder()
    local maxArgsSignature = signatures[1]
    local minArgumentCount = signatures[1]:MinArgumentCount()

    local hasRestParameter = false
    for _, signature in ipairs(signatures) do
        minArgumentCount = math.min(minArgumentCount, signature:MinArgumentCount())
        if signature:HasRestParameter() then
            hasRestParameter = true
        end
        if core.Len(signature:Parameters()) >= core.Len(maxArgsSignature:Parameters()) and (not signature:HasRestParameter() or maxArgsSignature:HasRestParameter()) then
            maxArgsSignature = signature
        end
    end

    local maxNonRestArgs = core.Len(maxArgsSignature:Parameters()) - (maxArgsSignature:HasRestParameter() and 1 or 0)
    local parameterNames = {}
    for _, symbol in ipairs(maxArgsSignature:Parameters() or {}) do
        parameterNames[#parameterNames + 1] = symbol.name
    end
    local parameters = ls.createDummyParameters(factory, maxNonRestArgs, parameterNames, nil --[[types]], minArgumentCount, ast.IsInJSFile(enclosingDeclaration))

    if hasRestParameter then
        local restParameterName = "rest"
        if maxNonRestArgs < #parameterNames and parameterNames[maxNonRestArgs + 1] ~= "" then
            restParameterName = parameterNames[maxNonRestArgs + 1]
        end

        local questionToken = nil
        if maxNonRestArgs >= minArgumentCount then
            questionToken = factory:NewToken(Kind.QuestionToken)
        end

        parameters.nodes = core.Append(parameters.nodes, factory:NewParameterDeclaration(
            nil --[[modifiers]], factory:NewToken(Kind.DotDotDotToken),
            factory:NewIdentifier(restParameterName), questionToken,
            factory:NewArrayTypeNode(factory:NewKeywordTypeNode(Kind.UnknownKeyword)), nil --[[initializer]]
        ))
    end

    local methodName
    if name == nil then
        methodName = factory:NewIdentifier("")
    else
        methodName = ls.createPropertyName(factory, name, quotePreference)
    end

    local postfixToken = nil
    if optional then
        postfixToken = factory:NewToken(Kind.QuestionToken)
    end

    return factory:NewMethodDeclaration(
        modifiers, nil --[[asteriskToken]], methodName, postfixToken,
        nil --[[typeParameters]], parameters, self:getReturnTypeFromSignatures(signatures, enclosingDeclaration, nodeBuilder, idToSymbol),
        nil --[[fullSignature]], self:createBody(body, quotePreference, false --[[signatureOnly]])
    )
end

function missingMemberFixer:getReturnTypeFromSignatures(signatures, enclosingDeclaration, nodeBuilder, idToSymbol)
    if core.Len(signatures) == 0 then
        return nil
    end

    local returnTypes = {}
    for _, signature in ipairs(signatures) do
        returnTypes[#returnTypes + 1] = self.typeChecker:GetReturnTypeOfSignature(signature)
    end

    local unionType = self.typeChecker:GetUnionType(returnTypes)
    return self:importTypeNode(nodeBuilder:TypeToTypeNode(unionType, enclosingDeclaration, NBFlags.NoTruncation, NBInternalFlags.AllowUnresolvedNames, nil --[[typeArguments]]), idToSymbol)
end

function missingMemberFixer:importTypeNode(typeNode, idToSymbol)
    if typeNode == nil or self.importAdder == nil then
        return typeNode
    end

    local importedTypeNode, symbols = autoimport.TryGetAutoImportableReferenceFromTypeNode(typeNode, idToSymbol)
    if importedTypeNode ~= nil then
        for _, symbol in ipairs(symbols or {}) do
            local exportSymbol = self:getExportedSymbol(symbol)
            if exportSymbol ~= nil then
                self.importAdder:AddImportFromExportedSymbol(exportSymbol, true --[[isValidTypeOnlyUseSite]])
            end
        end
        return importedTypeNode
    end

    -- Go ranges over the idToSymbol map (unordered); visit the identifiers in node id order so the
    -- result does not depend on Lua table order.
    local ids = {}
    for id in pairs(idToSymbol) do
        ids[#ids + 1] = id
    end
    table.sort(ids, function(a, b)
        return ast.GetNodeId(a) < ast.GetNodeId(b)
    end)
    local seen = {}
    for _, id in ipairs(ids) do
        local symbol = idToSymbol[id]
        if symbol == nil or seen[symbol] then
            goto continue
        end
        seen[symbol] = true
        do
            local exportSymbol = self:getExportedSymbol(symbol)
            if exportSymbol ~= nil then
                self.importAdder:AddImportFromExportedSymbol(exportSymbol, true --[[isValidTypeOnlyUseSite]])
            end
        end
        ::continue::
    end
    return typeNode
end

function missingMemberFixer:getExportedSymbol(symbol)
    symbol = self.typeChecker:GetExportSymbolOfSymbol(symbol)
    if symbol == nil or symbol.parent == nil then
        return nil
    end
    return symbol
end

function missingMemberFixer:createIndexSignatureDeclarationFromType(classDeclaration, implementedType, keyType)
    local indexInfo = self.typeChecker:GetIndexInfoOfType(implementedType, keyType)
    if indexInfo == nil then
        return nil
    end

    local builder = checker.NewNodeBuilder(self.typeChecker, self.changeTracker.emitContext)
    return builder:IndexInfoToIndexSignatureDeclaration(indexInfo, classDeclaration, NBFlags.None, NBInternalFlags.None, nil)
end

function missingMemberFixer:createBody(body, quotePreference, signatureOnly)
    if signatureOnly then
        return nil
    end
    body = self.changeTracker.nodeFactory:DeepCloneNode(body)
    if body == nil then
        return self:createStubbedMethodBody(quotePreference)
    end
    return body
end

function missingMemberFixer:createStubbedMethodBody(quotePreference)
    local tokenFlags = TokenFlags.None
    if quotePreference == lsutil.QuotePreference.Single then
        tokenFlags = TokenFlags.SingleQuote
    end

    local factory = self.changeTracker.nodeFactory
    return factory:NewBlock(factory:NewNodeList({
        factory:NewThrowStatement(
            factory:NewNewExpression(
                factory:NewIdentifier("Error"), nil --[[typeArguments]], factory:NewNodeList({
                    factory:NewStringLiteral(diagnostics.Method_not_implemented:Localize(self.locale), tokenFlags),
                })
            )
        ),
    }), true --[[multiLine]])
end

function ls.createDummyParameters(factory, argCount, names, types, minArgumentCount, inJS)
    local parameters = {}
    local parameterNameCounts = {}

    for i = 0, argCount - 1 do
        local parameterName
        if i < core.Len(names) and names[i + 1] ~= "" then
            parameterName = names[i + 1]
        else
            parameterName = "arg" .. tostring(i)
        end

        local count = parameterNameCounts[parameterName] or 0
        parameterNameCounts[parameterName] = count + 1

        if count > 0 then
            parameterName = parameterName .. tostring(count)
        end

        local questionToken = nil
        if i >= minArgumentCount then
            questionToken = factory:NewToken(Kind.QuestionToken)
        end

        local typeNode
        if inJS then
            typeNode = nil
        elseif i < core.Len(types) and types[i + 1] ~= nil then
            typeNode = types[i + 1]
        else
            typeNode = factory:NewKeywordTypeNode(Kind.UnknownKeyword)
        end
        parameters[#parameters + 1] = factory:NewParameterDeclaration(nil --[[modifiers]], nil --[[dotDotDotToken]], factory:NewIdentifier(parameterName), questionToken, typeNode, nil --[[initializer]])
    end
    return factory:NewNodeList(parameters)
end

function ls.createDeclarationName(factory, typeChecker, symbol, declaration)
    if symbol ~= nil and symbol.checkFlags & CheckFlags.Mapped ~= 0 then
        local nameType = typeChecker:GetNameTypeOfSymbol(symbol)
        if nameType ~= nil and checker.IsTypeUsableAsPropertyName(nameType) then
            return factory:NewIdentifier(checker.GetPropertyNameFromType(nameType))
        end
    end
    if declaration ~= nil and declaration:Name() ~= nil then
        return declaration:Name():Clone(factory)
    end
    if symbol ~= nil then
        return factory:NewIdentifier(symbol.name)
    end
    return nil
end

function ls.createPropertyName(factory, node, quotePreference)
    if ast.IsIdentifier(node) and node:Text() == "constructor" then
        local tokenFlags = TokenFlags.None
        if quotePreference == lsutil.QuotePreference.Single then
            tokenFlags = TokenFlags.SingleQuote
        end
        return factory:NewComputedPropertyName(factory:NewStringLiteral(node:Text(), tokenFlags))
    end
    return factory:DeepCloneNode(node)
end
