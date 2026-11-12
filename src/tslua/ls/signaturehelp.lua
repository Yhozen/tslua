local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local CheckFlags = ast.CheckFlags
local SymbolFlags = ast.SymbolFlags
local SignatureKind = checker.SignatureKind
local ElementFlags = checker.ElementFlags
local SymbolFormatFlags = checker.SymbolFormatFlags

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function containsValue(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

-- SignatureHelpTriggerCharacters and SignatureHelpRetriggerCharacters are the characters that trigger and
-- re-trigger signature help. They are advertised both in the static server capabilities and in the dynamic
-- content-mapper registration, so they live here to keep those two declarations in sync.
ls.SignatureHelpTriggerCharacters = { "(", ",", "<" }
ls.SignatureHelpRetriggerCharacters = { ")" }

-- callInvocation: { node }
-- typeArgsInvocation: { called }
-- contextualInvocation: { signature, node (just for enclosingDeclaration for printing types), symbol }
-- invocation: { callInvocation, typeArgsInvocation, contextualInvocation }

function LanguageService:ProvideSignatureHelp(ctx, documentURI, position, context)
    local program, sourceFile = self:getProgramAndFile(documentURI)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, position, spanmap.Feature.SignatureHelp)
    if core.Len(positions) == 0 or not spanmap.Fidelity_IsSingleSegment(positions[1].fidelity) then
        return {}, nil
    end
    sourceFile = positions[1].script
    local pos = positions[1].position
    local items = self:GetSignatureHelpItems(
        ctx,
        pos,
        program,
        sourceFile,
        context
    )
    return { signatureHelp = items }, nil
end

ls.signatureHelpTriggerReasonKind = {
    None = 0, -- was undefined
    Invoked = 1, -- was "invoked"
    CharacterTyped = 2, -- was "characterTyped"
    Retriggered = 3, -- was "retrigger"
}

function LanguageService:GetSignatureHelpItems(ctx, position, program, sourceFile, context)
    local typeChecker, done = program:GetTypeCheckerForFile(ctx, sourceFile)
    -- Decide whether to show signature help
    local startingToken = astnav.FindPrecedingToken(sourceFile, position)
    if startingToken == nil then
        -- We are at the beginning of the file
        done()
        return nil
    end

    local signatureHelpTriggerReasonKind = ls.signatureHelpTriggerReasonKind

    -- Emulate VS Code's toTsTriggerReason.
    local triggerReasonKind = signatureHelpTriggerReasonKind.None
    if context ~= nil then
        local triggerKind = context.triggerKind
        if triggerKind == lsproto.SignatureHelpTriggerKind.TriggerCharacter then
            if context.triggerCharacter ~= nil then
                if context.isRetrigger then
                    triggerReasonKind = signatureHelpTriggerReasonKind.Retriggered
                else
                    triggerReasonKind = signatureHelpTriggerReasonKind.CharacterTyped
                end
            else
                triggerReasonKind = signatureHelpTriggerReasonKind.Invoked
            end
        elseif triggerKind == lsproto.SignatureHelpTriggerKind.ContentChange then
            if context.isRetrigger then
                triggerReasonKind = signatureHelpTriggerReasonKind.Retriggered
            else
                triggerReasonKind = signatureHelpTriggerReasonKind.CharacterTyped
            end
        elseif triggerKind == lsproto.SignatureHelpTriggerKind.Invoked then
            triggerReasonKind = signatureHelpTriggerReasonKind.Invoked
        else
            triggerReasonKind = signatureHelpTriggerReasonKind.Invoked
        end
    end

    -- Only need to be careful if the user typed a character and signature help wasn't showing.
    local onlyUseSyntacticOwners = triggerReasonKind == signatureHelpTriggerReasonKind.CharacterTyped

    -- Bail out quickly in the middle of a string or comment, don't provide signature help unless the user explicitly requested it.
    if onlyUseSyntacticOwners and (ls.IsInString(sourceFile, position, startingToken) or ls.isInComment(sourceFile, position, startingToken) ~= nil) then
        done()
        return nil
    end

    local isManuallyInvoked = triggerReasonKind == signatureHelpTriggerReasonKind.Invoked
    local argumentInfo = ls.getContainingArgumentInfo(startingToken, sourceFile, typeChecker, isManuallyInvoked, position)
    if argumentInfo == nil then
        done()
        return nil
    end

    if ctxErr(ctx) then
        done()
        return nil
    end

    -- Extra syntactic and semantic filtering of signature help
    local candidateInfo = ls.getCandidateOrTypeInfo(argumentInfo, typeChecker, sourceFile, startingToken, onlyUseSyntacticOwners)

    if ctxErr(ctx) then
        done()
        return nil
    end

    if candidateInfo == nil then
        -- For JS files, try a fallback that searches all source files for declarations
        -- with matching names that have call signatures. This is a heuristic for untyped JS code.
        if ast.IsSourceFileJS(sourceFile) then
            local r = self:createJSSignatureHelpItems(ctx, argumentInfo, program, typeChecker)
            done()
            return r
        end
        done()
        return nil
    end

    -- return typeChecker.runWithCancellationToken(cancellationToken, typeChecker =>
    if candidateInfo.candidateInfo ~= nil then
        local r = self:createSignatureHelpItems(ctx, candidateInfo.candidateInfo.candidates, candidateInfo.candidateInfo.resolvedSignature, argumentInfo, sourceFile, typeChecker, onlyUseSyntacticOwners)
        done()
        return r
    end
    local r = ls.createTypeHelpItems(ctx, candidateInfo.typeInfo, argumentInfo, sourceFile, typeChecker)
    done()
    return r
end

function ls.createTypeHelpItems(ctx, symbol, argumentInfo, sourceFile, c)
    local typeParameters = c:GetLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    if typeParameters == nil then
        return nil
    end
    local item = ls.getTypeHelpItem(symbol, typeParameters, ls.getEnclosingDeclarationFromInvocation(argumentInfo.invocation), sourceFile, c)

    -- Check client capabilities for activeParameter handling
    local caps = lsproto.GetClientCapabilities(ctx)
    local sigInfoCaps = caps.textDocument.signatureHelp.signatureInformation
    local supportsPerSignatureActiveParam = sigInfoCaps.activeParameterSupport

    -- Converting signatureHelpParameter to *lsproto.ParameterInformation
    local parameters = {}
    for i1, param in ipairs(item.parameters) do
        parameters[i1] = param.parameterInfo
    end

    local sigInfo = {
        label = item.label,
        documentation = nil,
        parameters = parameters,
    }

    -- If client supports per-signature activeParameter, set it on SignatureInformation
    if supportsPerSignatureActiveParam and #item.parameters > 0 then
        sigInfo.activeParameter = { uinteger = argumentInfo.argumentIndex }
    end

    local help = {
        signatures = { sigInfo },
        activeSignature = 0,
    }

    -- If client doesn't support per-signature activeParameter, set it on the top-level SignatureHelp
    if not supportsPerSignatureActiveParam and #item.parameters > 0 then
        help.activeParameter = { uinteger = argumentInfo.argumentIndex }
    end

    return help
end

function ls.getTypeHelpItem(symbol, typeParameter, enclosingDeclaration, sourceFile, c)
    local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, nil)

    local parameters = {}
    for i1, typeParam in ipairs(typeParameter) do
        parameters[i1] = ls.createSignatureHelpParameterForTypeParameter(typeParam, sourceFile, enclosingDeclaration, c, p)
    end

    -- Creating display label
    local displayParts = core.NewStringBuilder()
    displayParts:WriteString(c:SymbolToString(symbol))
    if #parameters ~= 0 then
        displayParts:WriteString(scanner.TokenToString(Kind.LessThanToken))
        for i1, tp in ipairs(parameters) do
            if i1 > 1 then
                displayParts:WriteString(", ")
            end
            displayParts:WriteString(tp.parameterInfo.label.string)
        end
        displayParts:WriteString(scanner.TokenToString(Kind.GreaterThanToken))
    end

    return {
        label = displayParts:String(),
        documentation = nil,
        parameters = parameters,
        isVariadic = false,
        colorizedRuns = nil,
    }
end

-- createJSSignatureHelpItems is a fallback for JavaScript files when normal signature help
-- doesn't produce results. It searches all source files for declarations with matching names
-- that have call signatures.
function LanguageService:createJSSignatureHelpItems(ctx, argumentInfo, program, c)
    if argumentInfo.invocation.contextualInvocation ~= nil then
        return nil
    end
    -- See if we can find some symbol with the call expression name that has call signatures.
    local expression = ls.getExpressionFromInvocation(argumentInfo)
    if not ast.IsPropertyAccessExpression(expression) then
        return nil
    end
    local name = expression:Name():Text()
    if name == "" then
        return nil
    end

    for _, sf in ipairs(program:GetSourceFiles() or {}) do
        local result = self:findSignatureHelpFromNamedDeclarations(ctx, sf, name, argumentInfo, c)
        if result ~= nil then
            return result
        end
    end
    return nil
end

function LanguageService:findSignatureHelpFromNamedDeclarations(ctx, sourceFile, name, argumentInfo, c)
    local result
    local visit
    visit = function(node)
        if result ~= nil then
            return true
        end
        if ast.GetDeclarationName(node) == name then
            local symbol = node:Symbol()
            if symbol ~= nil then
                local t = c:GetTypeOfSymbolAtLocation(symbol, node)
                if t ~= nil then
                    local callSignatures = c:GetCallSignatures(t)
                    if core.Len(callSignatures) > 0 then
                        result = self:createSignatureHelpItems(ctx, callSignatures, callSignatures[1], argumentInfo, sourceFile, c, true --[[useFullPrefix]])
                        if result ~= nil then
                            return true
                        end
                    end
                end
            end
        end
        node:ForEachChild(function(child)
            return visit(child)
        end)
        return result ~= nil
    end
    visit(sourceFile)
    return result
end

function LanguageService:createSignatureHelpItems(ctx, candidates, resolvedSignature, argumentInfo, sourceFile, c, useFullPrefix)
    local caps = lsproto.GetClientCapabilities(ctx)
    local docFormat = lsproto.PreferredMarkupKind(caps.textDocument.signatureHelp.signatureInformation.documentationFormat)
    local vsCapability = caps.vsSupportsVisualStudioExtensions

    local enclosingDeclaration = ls.getEnclosingDeclarationFromInvocation(argumentInfo.invocation)
    if enclosingDeclaration == nil then
        return nil
    end
    local callTargetSymbol
    if argumentInfo.invocation.contextualInvocation ~= nil then
        callTargetSymbol = argumentInfo.invocation.contextualInvocation.symbol
    else
        callTargetSymbol = c:GetSymbolAtLocation(ls.getExpressionFromInvocation(argumentInfo))
        if callTargetSymbol == nil and useFullPrefix and resolvedSignature:Declaration() ~= nil then
            callTargetSymbol = resolvedSignature:Declaration():Symbol()
        end
    end

    local callTargetDisplayParts = core.NewStringBuilder()
    -- A contextual signature for an anonymous inline function type (e.g. a callback
    -- argument) has a synthetic symbol whose name is an internal marker such as
    -- "\xFEtype". There is no meaningful name to show, so render the signature with
    -- no prefix (as we already do when there is no call target symbol) rather than
    -- leaking the internal name.
    if callTargetSymbol ~= nil and not hasPrefix(callTargetSymbol.name, ast.InternalSymbolNamePrefix) then
        if useFullPrefix then
            callTargetDisplayParts:WriteString(c:SymbolToStringEx(callTargetSymbol, sourceFile, SymbolFlags.None, SymbolFormatFlags.UseAliasDefinedOutsideCurrentScope))
        else
            callTargetDisplayParts:WriteString(c:SymbolToString(callTargetSymbol))
        end
    end
    local items = {}
    for i1, candidateSignature in ipairs(candidates) do
        items[i1] = self:getSignatureHelpItem(candidateSignature, argumentInfo.isTypeParameterList, callTargetDisplayParts:String(), callTargetSymbol, enclosingDeclaration, sourceFile, c, docFormat, vsCapability)
    end

    local selectedItemIndex = 0
    local itemSeen = 0
    for i1 = 1, #items do
        local item = items[i1]
        if candidates[i1] == resolvedSignature then
            selectedItemIndex = itemSeen
            if #item > 1 then
                local count = 0
                for _, j in ipairs(item) do
                    if j.isVariadic or #j.parameters >= argumentInfo.argumentCount then
                        selectedItemIndex = itemSeen + count
                        break
                    end
                    count = count + 1
                end
            end
        end
        itemSeen = itemSeen + #item
    end

    debug.Assert(selectedItemIndex ~= -1)
    local flattenedSignatures = {}
    for _, item in ipairs(items) do
        for _, x in ipairs(item) do
            flattenedSignatures[#flattenedSignatures + 1] = x
        end
    end
    if #flattenedSignatures == 0 then
        return nil
    end

    -- Check client capabilities for activeParameter handling
    local sigInfoCaps = caps.textDocument.signatureHelp.signatureInformation
    local supportsPerSignatureActiveParam = sigInfoCaps.activeParameterSupport
    local supportsNullActiveParam = sigInfoCaps.noActiveParameterSupport

    -- Converting []signatureInformation to []*lsproto.SignatureInformation
    local signatureInformation = {}
    for i1, item in ipairs(flattenedSignatures) do
        local parameters = {}
        for j1, param in ipairs(item.parameters) do
            parameters[j1] = param.parameterInfo
        end
        local documentation
        if item.documentation ~= nil then
            documentation = {
                markupContent = {
                    kind = docFormat,
                    value = item.documentation,
                },
            }
        end
        local sigInfo = {
            label = item.label,
            documentation = documentation,
            parameters = parameters,
        }

        -- Set VS-specific colorized label if we have classified runs
        if core.Len(item.colorizedRuns) > 0 then
            sigInfo.vsColorizedLabel = {
                runs = item.colorizedRuns,
            }
        end

        -- If client supports per-signature activeParameter, set it on each SignatureInformation
        if supportsPerSignatureActiveParam then
            sigInfo.activeParameter = self:computeActiveParameter(item, argumentInfo.argumentIndex, supportsNullActiveParam)
        end

        signatureInformation[i1] = sigInfo
    end

    local help = {
        signatures = signatureInformation,
        activeSignature = selectedItemIndex,
    }

    -- If client doesn't support per-signature activeParameter, set it on the top-level SignatureHelp
    if not supportsPerSignatureActiveParam then
        local activeSignature = flattenedSignatures[selectedItemIndex + 1]
        help.activeParameter = self:computeActiveParameter(activeSignature, argumentInfo.argumentIndex, supportsNullActiveParam)
    end

    return help
end

-- computeActiveParameter calculates the active parameter index for a signature,
-- handling variadic signatures and null support appropriately.
function LanguageService:computeActiveParameter(sig, argumentIndex, supportsNull)
    local paramCount = #sig.parameters
    if paramCount == 0 then
        -- No parameters, return nil (omit the field)
        return nil
    end

    local activeParam = argumentIndex

    if sig.isVariadic then
        local firstRest = core.FindIndex(sig.parameters, function(p)
            return p.isRest
        end)
        if -1 < firstRest and firstRest < paramCount - 1 then
            -- Middle rest parameter - we can't accurately highlight, so indicate "no active parameter"
            if supportsNull then
                return {} -- null means "no parameter is active"
            end
            -- Client doesn't support null, use out-of-range index (defaults to 0 per LSP spec)
            return { uinteger = paramCount }
        end
        -- Clamp to last parameter for trailing rest parameters
        if activeParam > paramCount - 1 then
            activeParam = paramCount - 1
        end
    end

    return { uinteger = activeParam }
end

function LanguageService:getSignatureHelpItem(candidate, isTypeParameterList, callTargetSymbol, callTargetSym, enclosingDeclaration, sourceFile, c, docFormat, vsCapability)
    local infos
    if isTypeParameterList then
        infos = self:itemInfoForTypeParameters(candidate, c, enclosingDeclaration, sourceFile, docFormat, vsCapability)
    else
        infos = self:itemInfoForParameters(candidate, c, enclosingDeclaration, sourceFile, docFormat, vsCapability)
    end

    local suffixDpw = ls.returnTypeToDisplayParts(candidate, c, enclosingDeclaration, sourceFile, vsCapability)

    -- Generate documentation from the signature's declaration
    local documentation
    local declaration = candidate:Declaration()
    if declaration ~= nil then
        local doc = ls.getDocumentationFromDeclaration(self:documentationLocationMapper(spanmap.Feature.SignatureHelp), c, nil, declaration, nil, docFormat, true --[[commentOnly]])
        if doc ~= "" then
            documentation = doc
        end
    end

    local result = {}
    for i1, info in ipairs(infos) do
        local labelDpw = ls.newDisplayPartsWriter(vsCapability)
        if callTargetSymbol ~= "" then
            labelDpw:WriteSymbol(callTargetSymbol, callTargetSym)
        end
        labelDpw:WriteFrom(info.writer)
        labelDpw:WriteFrom(suffixDpw)

        result[i1] = {
            label = labelDpw:String(),
            documentation = documentation,
            parameters = info.parameters,
            isVariadic = info.isVariadic,
            colorizedRuns = labelDpw:GetRuns(),
        }
    end
    return result
end

function ls.returnTypeToDisplayParts(candidateSignature, c, enclosingDeclaration, sourceFile, vsCapability)
    local dpw = ls.newDisplayPartsWriter(vsCapability)

    -- Add ": " prefix
    dpw:WritePunctuation(": ")

    local predicate = c:GetTypePredicateOfSignature(candidateSignature)
    if predicate ~= nil then
        dpw:Write(c:TypePredicateToString(predicate))
    else
        local returnType = c:GetReturnTypeOfSignature(candidateSignature)
        local typeNode = c:TypeToTypeNode(returnType, enclosingDeclaration, ls.signatureHelpNodeBuilderFlags, nil)
        if typeNode ~= nil then
            local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, printer.NewEmitContext())
            -- Use a temporary writer for p.Write since the printer calls Clear() on its writer
            local tempDpw = ls.newDisplayPartsWriter(vsCapability)
            p:Write(typeNode, sourceFile, tempDpw, nil)
            dpw:WriteFrom(tempDpw)
        else
            dpw:Write(c:TypeToString(returnType))
        end
    end
    return dpw
end

function LanguageService:itemInfoForTypeParameters(candidateSignature, c, enclosingDeclaration, sourceFile, docFormat, vsCapability)
    local emitContext = printer.NewEmitContext()
    local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, emitContext)

    local typeParameters
    if candidateSignature:Target() ~= nil then
        typeParameters = candidateSignature:Target():TypeParameters()
    else
        typeParameters = candidateSignature:TypeParameters()
    end
    local signatureHelpTypeParameters = {}
    for i1, typeParameter in ipairs(typeParameters or {}) do
        signatureHelpTypeParameters[i1] = ls.createSignatureHelpParameterForTypeParameter(typeParameter, sourceFile, enclosingDeclaration, c, p)
    end

    local thisParameter = {}
    if candidateSignature:ThisParameter() ~= nil then
        thisParameter = { self:createSignatureHelpParameterForParameter(candidateSignature:ThisParameter(), enclosingDeclaration, p, sourceFile, c, docFormat) }
    end

    -- Creating type parameter display label
    local dpw = ls.newDisplayPartsWriter(vsCapability)

    local lessThanToken = scanner.TokenToString(Kind.LessThanToken)
    dpw:WritePunctuation(lessThanToken)
    for i1, typeParameter in ipairs(signatureHelpTypeParameters) do
        if i1 > 1 then
            dpw:WritePunctuation(", ")
        end
        local label = typeParameter.parameterInfo.label.string
        dpw:WriteClassified(label, lsproto.ClassificationTypeName.TypeParameterName)
    end
    local greaterThanToken = scanner.TokenToString(Kind.GreaterThanToken)
    dpw:WritePunctuation(greaterThanToken)

    -- Creating display label for parameters like, (a: string, b: number)
    local lists = c:GetExpandedParameters(candidateSignature, false)
    if core.Len(lists) ~= 0 then
        local openParen = scanner.TokenToString(Kind.OpenParenToken)
        dpw:WritePunctuation(openParen)
    end

    local result = {}
    for i1, parameterList in ipairs(lists or {}) do
        local paramDpw = ls.newDisplayPartsWriter(vsCapability)
        paramDpw:WriteFrom(dpw)

        local parameters = core.Slice(thisParameter, 0)
        for j1, param in ipairs(parameterList) do
            local paramNode = checker.NewNodeBuilder(c, emitContext):SymbolToParameterDeclaration(param, enclosingDeclaration, ls.signatureHelpNodeBuilderFlags, nodebuilder.InternalFlags.None, nil)

            if j1 > 1 then
                paramDpw:WritePunctuation(", ")
            end
            -- Use a temporary writer for p.Write since the printer calls Clear() on its writer
            local tempDpw = ls.newDisplayPartsWriter(vsCapability)
            p:Write(paramNode, sourceFile, tempDpw, nil)
            local paramLabel = tempDpw:String()
            paramDpw:WriteFrom(tempDpw)

            local parameter = self:createSignatureHelpParameterFromLabel(param, paramLabel, c, docFormat)
            parameters[#parameters + 1] = parameter
        end
        local closeParen = scanner.TokenToString(Kind.CloseParenToken)
        paramDpw:WritePunctuation(closeParen)

        result[i1] = {
            isVariadic = false,
            parameters = signatureHelpTypeParameters,
            writer = paramDpw,
        }
    end
    return result
end

function LanguageService:itemInfoForParameters(candidateSignature, c, enclosingDeclaratipn, sourceFile, docFormat, vsCapability)
    local emitContext = printer.NewEmitContext()
    local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, emitContext)

    local signatureHelpTypeParameters = {}
    if core.Len(candidateSignature:TypeParameters()) ~= 0 then
        for i1, typeParameter in ipairs(candidateSignature:TypeParameters()) do
            signatureHelpTypeParameters[i1] = ls.createSignatureHelpParameterForTypeParameter(typeParameter, sourceFile, enclosingDeclaratipn, c, p)
        end
    end

    -- Creating display label for type parameters like, <T, U>
    local dpw = ls.newDisplayPartsWriter(vsCapability)

    if #signatureHelpTypeParameters ~= 0 then
        local lessThanToken = scanner.TokenToString(Kind.LessThanToken)
        dpw:WritePunctuation(lessThanToken)
        for i1, typeParameter in ipairs(signatureHelpTypeParameters) do
            if i1 > 1 then
                dpw:WritePunctuation(", ")
            end
            local label = typeParameter.parameterInfo.label.string
            dpw:WriteClassified(label, lsproto.ClassificationTypeName.TypeParameterName)
        end
        local greaterThanToken = scanner.TokenToString(Kind.GreaterThanToken)
        dpw:WritePunctuation(greaterThanToken)
    end

    -- Creating display parts for parameters. For example, (a: string, b: number)
    local lists = c:GetExpandedParameters(candidateSignature, false)
    if core.Len(lists) ~= 0 then
        local openParen = scanner.TokenToString(Kind.OpenParenToken)
        dpw:WritePunctuation(openParen)
    end

    local function isVariadic(parameterList)
        if not c:HasEffectiveRestParameter(candidateSignature) then
            return false
        end
        if #lists == 1 then
            return true
        end
        return #parameterList ~= 0 and parameterList[#parameterList] ~= nil and (parameterList[#parameterList].checkFlags & CheckFlags.RestParameter ~= 0)
    end

    local result = {}
    for i1, parameterList in ipairs(lists or {}) do
        local parameters = {}
        local paramDpw = ls.newDisplayPartsWriter(vsCapability)
        paramDpw:WriteFrom(dpw)

        for j1, param in ipairs(parameterList) do
            local paramNode = checker.NewNodeBuilder(c, emitContext):SymbolToParameterDeclaration(param, enclosingDeclaratipn, ls.signatureHelpNodeBuilderFlags, nodebuilder.InternalFlags.None, nil)

            if j1 > 1 then
                paramDpw:WritePunctuation(", ")
            end
            -- Use a temporary writer for p.Write since the printer calls Clear() on its writer
            local tempDpw = ls.newDisplayPartsWriter(vsCapability)
            p:Write(paramNode, sourceFile, tempDpw, nil)
            local paramLabel = tempDpw:String()
            paramDpw:WriteFrom(tempDpw)

            local parameter = self:createSignatureHelpParameterFromLabel(param, paramLabel, c, docFormat)
            parameters[j1] = parameter
        end
        local closeParen = scanner.TokenToString(Kind.CloseParenToken)
        paramDpw:WritePunctuation(closeParen)

        result[i1] = {
            isVariadic = isVariadic(parameterList),
            parameters = parameters,
            writer = paramDpw,
        }
    end
    return result
end

ls.signatureHelpNodeBuilderFlags = nodebuilder.Flags.OmitParameterModifiers | nodebuilder.Flags.IgnoreErrors | nodebuilder.Flags.UseAliasDefinedOutsideCurrentScope

-- createSignatureHelpParameterFromLabel creates a signatureHelpParameter from a pre-computed label string.
function LanguageService:createSignatureHelpParameterFromLabel(parameter, label, c, docFormat)
    local isOptional = parameter.checkFlags & CheckFlags.OptionalParameter ~= 0
    local isRest = parameter.checkFlags & CheckFlags.RestParameter ~= 0
    local documentation
    if parameter.valueDeclaration ~= nil then
        local doc = ls.getDocumentationFromDeclaration(self:documentationLocationMapper(spanmap.Feature.SignatureHelp), c, nil, parameter.valueDeclaration, nil, docFormat, true --[[commentOnly]])
        if doc ~= "" then
            documentation = {
                markupContent = {
                    kind = docFormat,
                    value = doc,
                },
            }
        end
    end
    return {
        parameterInfo = {
            label = { string = label },
            documentation = documentation,
        },
        isRest = isRest,
        isOptional = isOptional,
    }
end

function LanguageService:createSignatureHelpParameterForParameter(parameter, enclosingDeclaratipn, p, sourceFile, c, docFormat)
    local display = p:Emit(checker.NewNodeBuilder(c, printer.NewEmitContext()):SymbolToParameterDeclaration(parameter, enclosingDeclaratipn, ls.signatureHelpNodeBuilderFlags, nodebuilder.InternalFlags.None, nil), sourceFile)
    return self:createSignatureHelpParameterFromLabel(parameter, display, c, docFormat)
end

function ls.createSignatureHelpParameterForTypeParameter(t, sourceFile, enclosingDeclaration, c, p)
    local display = p:Emit(checker.NewNodeBuilder(c, printer.NewEmitContext()):TypeParameterToDeclaration(t, enclosingDeclaration, ls.signatureHelpNodeBuilderFlags, nodebuilder.InternalFlags.None, nil), sourceFile)
    return {
        parameterInfo = {
            label = { string = display },
        },
        isRest = false,
        isOptional = false,
    }
end

-- Represents the signature of something callable. A signature
-- can have a label, like a function-name, a doc-comment, and
-- a set of parameters.
-- signatureInformation: {
--     label         -- The Label of this signature. Will be shown in the UI.
--     documentation -- The human-readable doc-comment of this signature (string or nil).
--     parameters    -- The Parameters of this signature ([]signatureHelpParameter).
--     isVariadic    -- Needed only here, not in lsp
--     colorizedRuns -- Classified text runs for VS colorized label
-- }
-- signatureHelpItemInfo: { isVariadic, parameters, writer }
-- signatureHelpParameter: { parameterInfo, isRest, isOptional }

function ls.getEnclosingDeclarationFromInvocation(invocation)
    if invocation.callInvocation ~= nil then
        return invocation.callInvocation.node
    elseif invocation.typeArgsInvocation ~= nil then
        return invocation.typeArgsInvocation.called
    else
        return invocation.contextualInvocation.node
    end
end

function ls.getExpressionFromInvocation(argumentInfo)
    if argumentInfo.invocation.callInvocation ~= nil then
        return ast.GetInvokedExpression(argumentInfo.invocation.callInvocation.node)
    end
    return argumentInfo.invocation.typeArgsInvocation.called
end

-- candidateInfo: { candidates, resolvedSignature }
-- CandidateOrTypeInfo: { candidateInfo, typeInfo }

function ls.getCandidateOrTypeInfo(info, c, sourceFile, startingToken, onlyUseSyntacticOwners)
    if info.invocation.callInvocation ~= nil then
        if onlyUseSyntacticOwners and not ls.isSyntacticOwner(startingToken, info.invocation.callInvocation.node, sourceFile) then
            return nil
        end

        local resolvedSignature, candidates = checker.GetResolvedSignatureForSignatureHelp(info.invocation.callInvocation.node, info.argumentCount, c)
        if core.Len(candidates) == 0 then
            return nil
        end

        return {
            candidateInfo = {
                candidates = candidates,
                resolvedSignature = resolvedSignature,
            },
        }
    end
    if info.invocation.typeArgsInvocation ~= nil then
        local called = info.invocation.typeArgsInvocation.called
        local container = called
        if ast.IsIdentifier(called) then
            container = called.parent
        end

        if onlyUseSyntacticOwners and not ls.containsPrecedingToken(startingToken, sourceFile, container) then
            return nil
        end

        local candidates = ls.getPossibleGenericSignatures(called, info.argumentCount, c)
        if core.Len(candidates) ~= 0 then
            return {
                candidateInfo = {
                    candidates = candidates,
                    resolvedSignature = candidates[1],
                },
            }
        end

        local symbol = c:GetSymbolAtLocation(called)
        if symbol ~= nil then
            return {
                typeInfo = symbol,
            }
        end

        -- This can happen in the case of an unresolved symbol.
        return nil
    end

    if info.invocation.contextualInvocation ~= nil then
        return {
            candidateInfo = {
                candidates = { info.invocation.contextualInvocation.signature },
                resolvedSignature = info.invocation.contextualInvocation.signature,
            },
        }
    end
    debug.AssertNever(info.invocation)
    return nil
end

function ls.isSyntacticOwner(startingToken, node, sourceFile)
    if not ast.IsCallOrNewExpression(node) then
        return false
    end
    local invocationChildren = ls.getChildrenFromNonJSDocNode(node, sourceFile)
    local kind = startingToken.kind
    if kind == Kind.OpenParenToken or kind == Kind.CommaToken then
        return containsValue(invocationChildren, startingToken)
    elseif kind == Kind.LessThanToken then
        return ls.containsPrecedingToken(startingToken, sourceFile, node:Expression())
    else
        return false
    end
end

function ls.containsPrecedingToken(startingToken, sourceFile, container)
    local pos = startingToken:Pos()
    -- There's a possibility that `startingToken.parent` contains only `startingToken` and
    -- missing nodes, none of which are valid to be returned by `findPrecedingToken`. In that
    -- case, the preceding token we want is actually higher up the tree—almost definitely the
    -- next parent, but theoretically the situation with missing nodes might be happening on
    -- multiple nested levels.
    local currentParent = startingToken.parent
    while currentParent ~= nil do
        local precedingToken = astnav.FindPrecedingTokenEx(sourceFile, pos, currentParent, true --[[excludeJSDoc]])
        if precedingToken ~= nil then
            return ls.RangeContainsRange(container.loc, precedingToken.loc)
        end
        currentParent = currentParent.parent
    end
    return false
end

function ls.getContainingArgumentInfo(node, sourceFile, c, isManuallyInvoked, position)
    local firstArgumentInfo
    local n = node
    while not ast.IsSourceFile(n) and (isManuallyInvoked or not ast.IsBlock(n)) do
        -- If the node is not a subspan of its parent, this is a big problem.
        -- There have been crashes that might be caused by this violation.
        debug.Assert(ls.RangeContainsRange(n.parent.loc, n.loc), "Not a subspan. Child: ", n:KindString(), ", parent: ", n.parent:KindString())
        local argumentInfo = ls.getImmediatelyContainingArgumentOrContextualParameterInfo(n, position, sourceFile, c)
        if argumentInfo ~= nil then
            -- For contextual invocations (e.g., arrow functions with contextual types),
            -- always return immediately without checking the position.
            -- This ensures that when inside a callback's parameter list, we show the callback's
            -- signature, not the outer call's signature.
            if argumentInfo.invocation.contextualInvocation ~= nil then
                return argumentInfo
            end

            -- Remember the first (innermost) argument info we find
            if firstArgumentInfo == nil then
                firstArgumentInfo = argumentInfo
            end

            -- If the position is at the end boundary of an argument list, keep the
            -- innermost call. This covers cases like foo(bar("x"|)) where the cursor is
            -- still inside the inner invocation, just before its closing paren.
            if argumentInfo.argumentsSpan:End() == position then
                return argumentInfo
            end

            -- If any call's span contains the position, return it.
            -- We walk from inner to outer, so this naturally prefers the innermost call
            -- when multiple calls contain the position.
            if argumentInfo.argumentsSpan:Contains(position) then
                return argumentInfo
            end
        end
        n = n.parent
    end

    -- No call's span contains the position. Fall back to the innermost call we found.
    -- This covers boundary positions that are still syntactically associated with that
    -- invocation, such as being at the end of the argument list or on the close paren.
    return firstArgumentInfo
end

function ls.getImmediatelyContainingArgumentOrContextualParameterInfo(node, position, sourceFile, c)
    local result = ls.tryGetParameterInfo(node, sourceFile, c)
    if result == nil then
        return ls.getImmediatelyContainingArgumentInfo(node, position, sourceFile, c)
    end
    return result
end

-- argumentListInfo: { isTypeParameterList, invocation, argumentsSpan, argumentIndex,
--   argumentCount (the *apparent* number of arguments) }

-- Returns relevant information for the argument list and the current argument if we are
-- in the argument of an invocation; returns undefined otherwise.
function ls.getImmediatelyContainingArgumentInfo(node, position, sourceFile, c)
    local parent = node.parent
    if ast.IsCallOrNewExpression(parent) then
        -- There are 3 cases to handle:
        --   1. The token introduces a list, and should begin a signature help session
        --   2. The token is either not associated with a list, or ends a list, so the session should end
        --   3. The token is buried inside a list, and should give signature help
        --
        -- The following are examples of each:
        --
        --    Case 1:
        --          foo<#T, U>(#a, b)    -> The token introduces a list, and should begin a signature help session
        --    Case 2:
        --          fo#o<T, U>#(a, b)#   -> The token is either not associated with a list, or ends a list, so the session should end
        --    Case 3:
        --          foo<T#, U#>(a#, #b#) -> The token is buried inside a list, and should give signature help
        -- Find out if 'node' is an argument, a type argument, or neither
        local info = ls.getArgumentOrParameterListInfo(node, sourceFile, c)
        if info == nil then
            return nil
        end
        local list = info.list
        local argumentIndex = info.argumentIndex
        local argumentCount = info.argumentCount
        local argumentsSpan = info.argumentsSpan
        local isTypeParameterList = false
        local parentTypeArgumentList = parent:TypeArgumentList()
        if parentTypeArgumentList ~= nil then
            if parentTypeArgumentList:Pos() == list:Pos() then
                isTypeParameterList = true
            end
        end
        return {
            isTypeParameterList = isTypeParameterList,
            invocation = { callInvocation = { node = parent } },
            argumentsSpan = argumentsSpan,
            argumentIndex = argumentIndex,
            argumentCount = argumentCount,
        }
    elseif ls.isNoSubstitutionTemplateLiteral(node) and ls.isTaggedTemplateExpression(parent) then
        -- Check if we're actually inside the template;
        -- otherwise we'll fall out and return undefined.
        if ls.isInsideTemplateLiteral(node, position, sourceFile) then
            return ls.getArgumentListInfoForTemplate(parent, 0, sourceFile)
        end
        return nil
    elseif ls.isTemplateHead(node) and parent.parent.kind == Kind.TaggedTemplateExpression then
        local templateExpression = parent
        local tagExpression = templateExpression.parent

        local argumentIndex = 1
        if ls.isInsideTemplateLiteral(node, position, sourceFile) then
            argumentIndex = 0
        end
        return ls.getArgumentListInfoForTemplate(tagExpression, argumentIndex, sourceFile)
    elseif ast.IsTemplateSpan(parent) and ls.isTaggedTemplateExpression(parent.parent.parent) then
        local templateSpan = parent
        local tagExpression = parent.parent.parent

        -- If we're just after a template tail, don't show signature help.
        if ls.isTemplateTail(node) and not ls.isInsideTemplateLiteral(node, position, sourceFile) then
            return nil
        end

        local spanIndex = ast.IndexOfNode(templateSpan.parent.templateSpans.nodes, templateSpan)
        local argumentIndex = ls.getArgumentIndexForTemplatePiece(spanIndex, node, position, sourceFile)

        return ls.getArgumentListInfoForTemplate(tagExpression, argumentIndex, sourceFile)
    elseif ast.IsJsxOpeningLikeElement(parent) then
        -- Provide a signature help for JSX opening element or JSX self-closing element.
        -- This is not guarantee that JSX tag-name is resolved into stateless function component. (that is done in "getSignatureHelpItems")
        -- i.e
        --      export function MainButton(props: ButtonProps, context: any): JSX.Element { ... }
        --      <MainButton /*signatureHelp*/
        local attributeSpanStart = parent:Attributes().loc:Pos()
        local attributeSpanEnd = scanner.SkipTrivia(sourceFile:Text(), parent:Attributes():End())
        return {
            isTypeParameterList = false,
            invocation = { callInvocation = { node = parent } },
            argumentsSpan = core.NewTextRange(attributeSpanStart, attributeSpanEnd - attributeSpanStart),
            argumentIndex = 0,
            argumentCount = 1,
        }
    else
        local typeArgInfo = ls.getPossibleTypeArgumentsInfo(node, sourceFile)
        if typeArgInfo ~= nil then
            local called = typeArgInfo.called
            local nTypeArguments = typeArgInfo.nTypeArguments
            local invoc = { called = called:AsIdentifier() }
            local argumentRange = core.NewTextRange(called.loc:Pos(), node:End())
            return {
                isTypeParameterList = true,
                invocation = {
                    typeArgsInvocation = invoc,
                },
                argumentsSpan = argumentRange,
                argumentIndex = nTypeArguments,
                argumentCount = nTypeArguments + 1,
            }
        end
    end
    return nil
end

-- spanIndex is either the index for a given template span.
-- This does not give appropriate results for a NoSubstitutionTemplateLiteral
function ls.getArgumentIndexForTemplatePiece(spanIndex, node, position, sourceFile)
    -- Because the TemplateStringsArray is the first argument, we have to offset each substitution expression by 1.
    -- There are three cases we can encounter:
    --      1. We are precisely in the template literal (argIndex = 0).
    --      2. We are in or to the right of the substitution expression (argIndex = spanIndex + 1).
    --      3. We are directly to the right of the template literal, but because we look for the token on the left,
    --          not enough to put us in the substitution expression; we should consider ourselves part of
    --          the *next* span's expression by offsetting the index (argIndex = (spanIndex + 1) + 1).
    --
    -- Example: f  `# abcd $#{#  1 + 1#  }# efghi ${ #"#hello"#  }  #  `
    --              ^       ^ ^       ^   ^          ^ ^      ^     ^
    -- Case:        1       1 3       2   1          3 2      2     1
    debug.Assert(position >= node.loc:Pos(), "Assumed 'position' could not occur before node.")
    if ast.IsTemplateLiteralToken(node) then
        if ls.isInsideTemplateLiteral(node, position, sourceFile) then
            return 0
        end
        return spanIndex + 2
    end
    return spanIndex + 1
end

function ls.getAdjustedNode(node)
    local kind = node.kind
    if kind == Kind.OpenParenToken or kind == Kind.CommaToken then
        return node
    else
        return ast.FindAncestor(node.parent, function(n)
            if ast.IsParameterDeclaration(n) then
                return true
            elseif ast.IsBindingElement(n) or ast.IsObjectBindingPattern(n) or ast.IsArrayBindingPattern(n) then
                return false
            end
            return false
        end)
    end
end

-- contextualSignatureLocationInfo: { contextualType, argumentIndex, argumentCount, argumentsSpan }

function ls.getSpreadElementCount(node, c)
    local spreadType = c:GetTypeAtLocation(node.expression)
    if checker.IsTupleType(spreadType) then
        local tupleType = spreadType:Target():AsTupleType()
        if tupleType == nil then
            return 0
        end
        local elementFlags = tupleType:ElementFlags()
        local fixedLength = tupleType:FixedLength()
        if fixedLength == 0 then
            return 0
        end

        local firstOptionalIndex = core.FindIndex(elementFlags, function(f)
            return (f & ElementFlags.Required == 0)
        end)
        if firstOptionalIndex < 0 then
            return fixedLength
        end
        return firstOptionalIndex
    end
    return 0
end

function ls.getArgumentIndex(node, arguments, sourceFile, c)
    return ls.getArgumentIndexOrCount(ls.getTokenFromNodeList(arguments, node.parent, sourceFile), node, c)
end

function ls.getArgumentCount(node, arguments, sourceFile, c)
    return ls.getArgumentIndexOrCount(ls.getTokenFromNodeList(arguments, node.parent, sourceFile), nil, c)
end

function ls.getArgumentIndexOrCount(arguments, node, c)
    local argumentIndex = 0
    local skipComma = false
    for _, arg in ipairs(arguments or {}) do
        if node ~= nil and arg == node then
            if not skipComma and arg.kind == Kind.CommaToken then
                argumentIndex = argumentIndex + 1
            end
            return argumentIndex
        end
        if ast.IsSpreadElement(arg) then
            argumentIndex = argumentIndex + ls.getSpreadElementCount(arg:AsSpreadElement(), c)
            skipComma = true
        elseif arg.kind ~= Kind.CommaToken then
            argumentIndex = argumentIndex + 1
            skipComma = true
        elseif skipComma then
            skipComma = false
        else
            argumentIndex = argumentIndex + 1
        end
    end
    if node ~= nil then
        return argumentIndex
    end
    -- The argument count for a list is normally the number of non-comma children it has.
    -- For example, if you have "Foo(a,b)" then there will be three children of the arg
    -- list 'a' '<comma>' 'b'. So, in this case the arg count will be 2. However, there
    -- is a small subtlety. If you have "Foo(a,)", then the child list will just have
    -- 'a' '<comma>'. So, in the case where the last child is a comma, we increase the
    -- arg count by one to compensate.
    local argumentCount = argumentIndex
    if core.Len(arguments) > 0 and arguments[#arguments].kind == Kind.CommaToken then
        argumentCount = argumentIndex + 1
    end
    return argumentCount
end

-- argumentOrParameterListInfo: { list, argumentIndex, argumentCount, argumentsSpan }

function ls.getArgumentOrParameterListInfo(node, sourceFile, c)
    local info = ls.getArgumentOrParameterListAndIndex(node, sourceFile, c)
    if info == nil then
        return nil
    end
    local list = info.list
    local argumentIndex = info.argumentIndex
    local argumentCount = ls.getArgumentCount(node, list, sourceFile, c)
    local argumentsSpan = ls.getApplicableSpanForArguments(list, node, sourceFile)
    return {
        list = list,
        argumentIndex = argumentIndex,
        argumentCount = argumentCount,
        argumentsSpan = argumentsSpan,
    }
end

function ls.getApplicableSpanForArguments(argumentList, node, sourceFile)
    -- We use full start and skip trivia on the end because we want to include trivia on
    -- both sides. For example,
    --
    --    foo(   /*comment */     a, b, c      /*comment*/     )
    --        |                                               |
    --
    -- The applicable span is from the first bar to the second bar (inclusive,
    -- but not including parentheses).
    if argumentList == nil and node ~= nil then
        -- If the user has just opened a list, and there are no arguments.
        -- For example, foo(    )
        --                  |  |
        -- The span should include positions inside the parentheses.
        local spanStart = node:End()
        local spanEnd = scanner.SkipTrivia(sourceFile:Text(), node:End())
        spanEnd = ls.ensureMinimumSpanSize(spanStart, spanEnd)
        return core.NewTextRange(spanStart, spanEnd)
    end
    local applicableSpanStart = argumentList:Pos()
    local applicableSpanEnd = scanner.SkipTrivia(sourceFile:Text(), argumentList:End())

    -- If the argument list is empty (Pos == End), extend the span to include at least
    -- one position. This handles foo(|) where the cursor is right after the opening paren.
    applicableSpanEnd = ls.ensureMinimumSpanSize(applicableSpanStart, applicableSpanEnd)

    return core.NewTextRange(applicableSpanStart, applicableSpanEnd)
end

-- ensureMinimumSpanSize ensures that a span includes at least one position.
-- TextRange.Contains uses a half-open interval, so an empty span would not contain
-- the cursor immediately after typing an opening paren in a call like foo(bar(|)).
function ls.ensureMinimumSpanSize(start, end_)
    if end_ <= start then
        return start + 1
    end
    return end_
end

-- argumentOrParameterListAndIndex: { list, argumentIndex }

function ls.getArgumentOrParameterListAndIndex(node, sourceFile, c)
    if node.kind == Kind.LessThanToken or node.kind == Kind.OpenParenToken then
        -- Find the list that starts right *after* the < or ( token.
        -- If the user has just opened a list, consider this item 0.
        local list = ls.getChildListThatStartsWithOpenerToken(node.parent, node)
        return {
            list = list,
            argumentIndex = 0,
        }
    else
        -- findListItemInfo can return undefined if we are not in parent's argument list
        -- or type argument list. This includes cases where the cursor is:
        --   - To the right of the closing parenthesis, non-substitution template, or template tail.
        --   - Between the type arguments and the arguments (greater than token)
        --   - On the target of the call (parent.func)
        --   - On the 'new' keyword in a 'new' expression
        local list = ls.findContainingList(node, sourceFile)
        if list == nil then
            return nil
        end
        return {
            list = list,
            -- Find the index of the argument that contains the node.
            argumentIndex = ls.getArgumentIndex(node, list, sourceFile, c),
        }
    end
end

function ls.getChildListThatStartsWithOpenerToken(parent, openerToken)
    if ast.IsCallExpression(parent) then
        local parentCallExpression = parent
        if openerToken.kind == Kind.LessThanToken then
            return parentCallExpression:TypeArgumentList()
        end
        return parentCallExpression.arguments
    elseif ast.IsNewExpression(parent) then
        local parentNewExpression = parent
        if openerToken.kind == Kind.LessThanToken then
            return parentNewExpression:TypeArgumentList()
        end
        return parentNewExpression.arguments
    end
    return nil
end

function ls.tryGetParameterInfo(startingToken, sourceFile, c)
    local node = ls.getAdjustedNode(startingToken)
    if node == nil then
        return nil
    end
    local info = ls.getContextualSignatureLocationInfo(node, sourceFile, c)
    if info == nil then
        return nil
    end

    -- for optional function condition
    local nonNullableContextualType = c:GetNonNullableType(info.contextualType)
    if nonNullableContextualType == nil then
        return nil
    end

    local symbol = nonNullableContextualType:Symbol()
    if symbol == nil then
        return nil
    end

    local signatures = c:GetSignaturesOfType(nonNullableContextualType, SignatureKind.Call)
    if core.Len(signatures) == 0 then
        return nil
    end
    local signature = signatures[#signatures]

    local contextualInvocation = {
        signature = signature,
        node = startingToken,
        symbol = ls.chooseBetterSymbol(symbol),
    }
    return {
        isTypeParameterList = false,
        invocation = { contextualInvocation = contextualInvocation },
        argumentsSpan = info.argumentsSpan,
        argumentIndex = info.argumentIndex,
        argumentCount = info.argumentCount,
    }
end

function ls.chooseBetterSymbol(s)
    if s.name == ast.InternalSymbolNameType then
        for _, d in ipairs(s.declarations or {}) do
            if ast.IsFunctionTypeNode(d) and ast.CanHaveSymbol(d.parent) then
                return d.parent:Symbol()
            end
        end
    end
    return s
end

function ls.getContextualSignatureLocationInfo(node, sourceFile, c)
    local parent = node.parent
    local kind = parent.kind
    if kind == Kind.ParenthesizedExpression or kind == Kind.MethodDeclaration or kind == Kind.FunctionExpression or kind == Kind.ArrowFunction then
        local info = ls.getArgumentOrParameterListInfo(node, sourceFile, c)
        if info == nil then
            return nil
        end
        local argumentIndex = info.argumentIndex
        local argumentCount = info.argumentCount
        local argumentsSpan = info.argumentsSpan

        local contextualType
        if ast.IsMethodDeclaration(parent) then
            contextualType = c:GetContextualTypeForObjectLiteralElement(parent, checker.ContextFlags.None)
        else
            contextualType = c:GetContextualType(parent, checker.ContextFlags.None)
        end
        if contextualType ~= nil then
            return {
                contextualType = contextualType,
                argumentIndex = argumentIndex,
                argumentCount = argumentCount,
                argumentsSpan = argumentsSpan,
            }
        end
        return nil
    elseif kind == Kind.BinaryExpression then
        local highestBinary = ls.getHighestBinary(parent)
        local contextualType = c:GetContextualType(highestBinary, checker.ContextFlags.None)
        local argumentIndex = 0
        if node.kind ~= Kind.OpenParenToken then
            argumentIndex = ls.countBinaryExpressionParameters(parent) - 1
            local argumentCount = ls.countBinaryExpressionParameters(highestBinary)
            if contextualType ~= nil then
                return {
                    contextualType = contextualType,
                    argumentIndex = argumentIndex,
                    argumentCount = argumentCount,
                    argumentsSpan = core.NewTextRange(parent:Pos(), parent:End()),
                }
            end
            return nil
        end
    end
    return nil
end

function ls.getHighestBinary(b)
    if ast.IsBinaryExpression(b.parent) then
        return ls.getHighestBinary(b.parent)
    end
    return b
end

function ls.countBinaryExpressionParameters(b)
    if ast.IsBinaryExpression(b.left) then
        return ls.countBinaryExpressionParameters(b.left) + 1
    end
    return 2
end

function ls.getTokenFromNodeList(nodeList, nodeListParent, sourceFile)
    if nodeList == nil or nodeListParent == nil then
        return nil
    end
    local left = nodeList:Pos()
    local nodeListIndex = 0
    local tokens
    while left < nodeList:End() do
        if #nodeList.nodes > nodeListIndex and left == nodeList.nodes[nodeListIndex + 1]:Pos() then
            tokens = core.Append(tokens, nodeList.nodes[nodeListIndex + 1])
            left = nodeList.nodes[nodeListIndex + 1]:End()
            nodeListIndex = nodeListIndex + 1
        else
            local s = scanner.GetScannerForSourceFile(sourceFile, left)
            local token = s:Token()
            local tokenFullStart = s:TokenFullStart()
            local tokenEnd = s:TokenEnd()
            tokens = core.Append(tokens, sourceFile:GetOrCreateToken(token, tokenFullStart, tokenEnd, nodeListParent, s:TokenFlags()))
            left = tokenEnd
        end
    end
    return tokens
end

function ls.getArgumentListInfoForTemplate(tagExpression, argumentIndex, sourceFile)
    -- argumentCount is either 1 or (numSpans + 1) to account for the template strings array argument.
    local argumentCount = 1
    if not ls.isNoSubstitutionTemplateLiteral(tagExpression.template) then
        argumentCount = #tagExpression.template.templateSpans.nodes + 1
    end
    if argumentIndex ~= 0 then
        debug.Assert(argumentIndex < argumentCount)
    end
    return {
        isTypeParameterList = false,
        invocation = { callInvocation = { node = tagExpression } },
        argumentIndex = argumentIndex,
        argumentCount = argumentCount,
        argumentsSpan = ls.getApplicableRangeForTaggedTemplate(tagExpression, sourceFile),
    }
end

function ls.getApplicableRangeForTaggedTemplate(taggedTemplate, sourceFile)
    local template = taggedTemplate.template
    local applicableSpanStart = scanner.GetTokenPosOfNode(template, sourceFile, false)
    local applicableSpanEnd = template:End()

    -- We need to adjust the end position for the case where the template does not have a tail.
    -- Otherwise, we will not show signature help past the expression.
    -- For example,
    --
    --      ` ${ 1 + 1 foo(10)
    --       |       |
    -- This is because a Missing node has no width. However, what we actually want is to include trivia
    -- leading up to the next token in case the user is about to type in a TemplateMiddle or TemplateTail.
    if template.kind == Kind.TemplateExpression then
        local templateSpans = template.templateSpans
        local lastSpan = templateSpans.nodes[#templateSpans.nodes]
        if lastSpan.literal:End() - lastSpan.literal:Pos() == 0 then
            applicableSpanEnd = scanner.SkipTrivia(sourceFile:Text(), applicableSpanEnd)
        end
    end

    return core.NewTextRange(applicableSpanStart, applicableSpanEnd - applicableSpanStart)
end
