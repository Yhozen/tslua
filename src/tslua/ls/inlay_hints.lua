local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local core = require("tslua.core")
local debug = require("tslua.debug")
local evaluator = require("tslua.evaluator")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local TypeFlags = checker.TypeFlags
local ElementFlags = checker.ElementFlags
local IncludeInlayParameterNameHints = lsutil.IncludeInlayParameterNameHints

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

local function isTrue(t)
    return core.Tristate_IsTrue(t)
end

-- Go strings.TrimFunc(s, f) where f tests a rune.
local function trimFunc(s, f)
    local i = 0
    while i < #s do
        local r, size = core.DecodeRune(s, i)
        if not f(r) then
            break
        end
        i = i + size
    end
    local j = #s
    while j > i do
        local r, size = core.DecodeLastRune(s, j)
        if not f(r) then
            break
        end
        j = j - size
    end
    return string.sub(s, i + 1, j)
end

function LanguageService:ProvideInlayHint(ctx, params)
    local userPreferences = self:UserPreferences()
    local inlayHintPreferences = userPreferences.inlayHints
    if not ls.isAnyInlayHintEnabled(inlayHintPreferences) then
        return { inlayHints = nil }, nil
    end

    local program, file = self:getProgramAndFile(params.textDocument.uri)
    local quotePreference = lsutil.GetQuotePreference(file, userPreferences)

    local mappedRanges = lsconv.FromLSPRangeIntersectingForSourceFile(self.converters, file, params.range, spanmap.Feature.InlayHints)
    local result = {}
    local dones = {}
    for _, mapped in ipairs(mappedRanges or {}) do
        local projection = mapped.script
        local c, done = program:GetTypeCheckerForFile(ctx, projection)
        dones[#dones + 1] = done
        local state = ls.newInlayHintState({
            ctx = ctx,
            span = mapped.span,
            preferences = inlayHintPreferences,
            quotePreference = quotePreference,
            file = projection,
            checker = c,
            converters = self.converters,
        })
        state:visit(projection)
        for _, hint in ipairs(state.result or {}) do
            result[#result + 1] = hint
        end
    end
    -- Go defers each done() until the function returns (in reverse order).
    for i = #dones, 1, -1 do
        dones[i]()
    end
    return { inlayHints = result }, nil
end

-- inlayHintState: { ctx, span, preferences, quotePreference, file, checker, converters, result }
local inlayHintState = {}
inlayHintState.__index = inlayHintState
ls.inlayHintState = inlayHintState

function ls.newInlayHintState(fields)
    return setmetatable({
        ctx = fields.ctx,
        span = fields.span,
        preferences = fields.preferences,
        quotePreference = fields.quotePreference or "",
        file = fields.file,
        checker = fields.checker,
        converters = fields.converters,
        result = nil,
    }, inlayHintState)
end

local cancellationCheckKinds = ast.kindSet(Kind.ModuleDeclaration, Kind.ClassDeclaration, Kind.InterfaceDeclaration,
    Kind.FunctionDeclaration, Kind.ClassExpression, Kind.FunctionExpression,
    Kind.MethodDeclaration, Kind.ArrowFunction)

function inlayHintState:visit(node)
    if node == nil or node:End() - node:Pos() == 0 or node.flags & NodeFlags.Reparsed ~= 0 then
        return false
    end

    if cancellationCheckKinds[node.kind] then
        if ctxErr(self.ctx) then
            return true
        end
    end

    if not self.span:Intersects(node.loc) then
        return false
    end

    if ast.IsTypeNode(node) and not ast.IsExpressionWithTypeArguments(node) then
        return false
    end

    if isTrue(self.preferences.includeInlayVariableTypeHints) and ast.IsVariableDeclaration(node) then
        self:visitVariableLikeDeclaration(node)
    elseif isTrue(self.preferences.includeInlayPropertyDeclarationTypeHints) and ast.IsPropertyDeclaration(node) then
        self:visitVariableLikeDeclaration(node)
    elseif isTrue(self.preferences.includeInlayEnumMemberValueHints) and ast.IsEnumMember(node) then
        self:visitEnumMember(node)
    elseif ls.shouldShowParameterNameHints(self.preferences) and (ast.IsCallExpression(node) or ast.IsNewExpression(node)) then
        self:visitCallOrNewExpression(node)
    else
        if isTrue(self.preferences.includeInlayFunctionParameterTypeHints) and
            ast.IsFunctionLikeDeclaration(node) and
            ast.HasContextSensitiveParameters(node) then
            self:visitFunctionLikeForParameterType(node)
        end
        if isTrue(self.preferences.includeInlayFunctionLikeReturnTypeHints) and
            ls.isSignatureSupportingReturnAnnotation(node) then
            self:visitFunctionDeclarationLikeForReturnType(node)
        end
    end
    return node:ForEachChild(function(child) return self:visit(child) end)
end

-- FunctionDeclaration | MethodDeclaration | GetAccessor | FunctionExpression | ArrowFunction
function inlayHintState:visitFunctionDeclarationLikeForReturnType(decl)
    if ast.IsArrowFunction(decl) then
        if astnav.FindChildOfKind(decl, Kind.OpenParenToken, self.file) == nil then
            return
        end
    end

    local typeAnnotation = decl:Type()
    if typeAnnotation ~= nil or decl:Body() == nil then
        return
    end

    local signature = self.checker:GetSignatureFromDeclaration(decl)
    if signature == nil then
        return
    end

    local typePredicate = self.checker:GetTypePredicateOfSignature(signature)

    if typePredicate ~= nil and typePredicate:Type() ~= nil then
        local hintParts = self:typePredicateToInlayHintParts(typePredicate)
        self:addTypeHints(hintParts, self:getTypeAnnotationPosition(decl))
        return
    end

    local returnType = self.checker:GetReturnTypeOfSignature(signature)
    if ls.isModuleReferenceType(returnType) then
        return
    end

    local hintParts = self:typeToInlayHintParts(returnType)
    self:addTypeHints(hintParts, self:getTypeAnnotationPosition(decl))
end

function inlayHintState:visitCallOrNewExpression(expr)
    local args = expr:Arguments()
    if core.Len(args) == 0 then
        return
    end

    local signature = self.checker:GetResolvedSignature(expr)
    if signature == nil then
        return
    end

    local signatureParamPos = 0
    for _, originalArg in ipairs(args) do
        local arg = ast.SkipParentheses(originalArg)
        if ls.shouldShowLiteralParameterNameHintsOnly(self.preferences) and not ls.isHintableLiteral(arg) then
            signatureParamPos = signatureParamPos + 1
            goto continue
        end

        do
            local spreadArgs = 0
            if ast.IsSpreadElement(arg) then
                local spreadType = self.checker:GetTypeAtLocation(arg:Expression())
                if spreadType:IsTupleType() then
                    local elementFlags = spreadType:Target():AsTupleType():ElementFlags()
                    local fixedLength = spreadType:Target():AsTupleType():FixedLength()
                    if fixedLength == 0 then
                        goto continue
                    end
                    local firstOptionalIndex = core.FindIndex(elementFlags, function(f)
                        return f & ElementFlags.Required == 0
                    end)
                    local requiredArgs = core.IfElse(firstOptionalIndex < 0, fixedLength, firstOptionalIndex)
                    if requiredArgs > 0 then
                        spreadArgs = requiredArgs
                    end
                end
            end

            local identifierInfo = self:getParameterIdentifierInfoAtPosition(signature, signatureParamPos)
            signatureParamPos = signatureParamPos + core.IfElse(spreadArgs > 0, spreadArgs, 1)
            if identifierInfo == nil then
                return
            end

            local parameter = identifierInfo.parameter
            local parameterName = identifierInfo.name
            local isFirstVariadicArgument = identifierInfo.isRestParameter
            local parameterNameNotSameAsArgument = isTrue(self.preferences.includeInlayParameterNameHintsWhenArgumentMatchesName) or
                not ls.identifierOrAccessExpressionPostfixMatchesParameterName(arg, parameterName)
            if not parameterNameNotSameAsArgument and not isFirstVariadicArgument then
                goto continue
            end

            if self:leadingCommentsContainsParameterName(arg, parameterName) then
                goto continue
            end

            self:addParameterHints(
                parameterName,
                parameter,
                astnav.GetStartOfNode(originalArg, self.file, false --[[includeJSDoc]]),
                isFirstVariadicArgument
            )
        end
        ::continue::
    end
end

function inlayHintState:visitEnumMember(member)
    if member:Initializer() ~= nil then
        return
    end

    local enumValue = self.checker:GetConstantValue(member)
    if enumValue ~= nil then
        self:addEnumMemberValueHints(evaluator.AnyToString(enumValue), member:End())
    end
end

function inlayHintState:visitVariableLikeDeclaration(decl)
    if decl:Initializer() == nil and
        not (ast.IsPropertyDeclaration(decl) and self.checker:GetTypeAtLocation(decl):Flags() & TypeFlags.Any == 0) or
        ast.IsBindingPattern(decl:Name()) or (ast.IsVariableDeclaration(decl) and not ls.isHintableDeclaration(decl)) then
        return
    end

    local typeAnnotation = decl:Type()
    if typeAnnotation ~= nil then
        return
    end

    local declarationType = self.checker:GetTypeAtLocation(decl)
    if ls.isModuleReferenceType(declarationType) then
        return
    end

    local hintParts = self:typeToInlayHintParts(declarationType)
    local hintText = ""
    if hintParts.string ~= nil then
        hintText = hintParts.string
    elseif hintParts.inlayHintLabelParts ~= nil then
        local b = core.NewStringBuilder()
        for _, part in ipairs(hintParts.inlayHintLabelParts) do
            b:WriteString(part.value)
        end
        hintText = b:String()
    end
    if not isTrue(self.preferences.includeInlayVariableTypeHintsWhenTypeMatchesName) and
        not ast.IsComputedPropertyName(decl:Name()) and
        stringutil.EquateStringCaseInsensitive(decl:Name():Text(), hintText) then
        return
    end
    self:addTypeHints(hintParts, decl:Name():End())
end

function inlayHintState:visitFunctionLikeForParameterType(node)
    local signature = self.checker:GetSignatureFromDeclaration(node)
    if signature == nil then
        return
    end

    local pos = 0
    for _, param in ipairs(node:Parameters() or {}) do
        if ls.isHintableDeclaration(param) then
            local symbol
            if ast.IsThisParameter(param) then
                symbol = signature:ThisParameter()
            else
                symbol = signature:Parameters()[pos + 1]
            end
            self:addParameterTypeHint(param, symbol)
        end
        if not ast.IsThisParameter(param) then
            pos = pos + 1
        end
    end
end

function inlayHintState:addParameterTypeHint(node, symbol)
    local typeAnnotation = node:Type()
    if typeAnnotation ~= nil or symbol == nil then
        return
    end
    local typeHints = self:getParameterDeclarationTypeHints(symbol)
    if typeHints == nil then
        return
    end
    local pos
    if node:QuestionToken() ~= nil then
        pos = node:QuestionToken():End()
    else
        pos = node:Name():End()
    end
    self:addTypeHints(typeHints, pos)
end

function inlayHintState:getParameterDeclarationTypeHints(symbol)
    local valueDeclaration = symbol.valueDeclaration
    if valueDeclaration == nil or not ast.IsParameterDeclaration(valueDeclaration) then
        return nil
    end

    local signatureParamType = self.checker:GetTypeOfSymbolAtLocation(symbol, valueDeclaration)
    if ls.isModuleReferenceType(signatureParamType) then
        return nil
    end

    return self:typeToInlayHintParts(signatureParamType)
end

function inlayHintState:typeToInlayHintParts(t)
    local flags = nodebuilder.Flags.IgnoreErrors | nodebuilder.Flags.AllowUniqueESSymbolType |
        nodebuilder.Flags.UseAliasDefinedOutsideCurrentScope
    local idToSymbol = {}
    -- !!! Avoid type node reuse so we collect identifier symbols.
    local typeNode = self.checker:TypeToTypeNode(t, nil --[[enclosingDeclaration]], flags, idToSymbol)
    debug.Assert(typeNode ~= nil, "should always get typenode")
    return {
        inlayHintLabelParts = self:getInlayHintLabelParts(typeNode, idToSymbol) or {},
    }
end

function inlayHintState:typePredicateToInlayHintParts(typePredicate)
    local flags = nodebuilder.Flags.IgnoreErrors | nodebuilder.Flags.AllowUniqueESSymbolType |
        nodebuilder.Flags.UseAliasDefinedOutsideCurrentScope
    local idToSymbol = {}
    -- !!! Avoid type node reuse so we collect identifier symbols.
    local typeNode = self.checker:TypePredicateToTypePredicateNode(typePredicate, nil --[[enclosingDeclaration]], flags, idToSymbol)
    debug.Assert(typeNode ~= nil, "should always get typePredicateNode")
    return {
        inlayHintLabelParts = self:getInlayHintLabelParts(typeNode, idToSymbol) or {},
    }
end

function inlayHintState:addTypeHints(hint, position)
    local lspPosition, fidelity = self.converters:ToLSPPositionForFeature(self.file, position, spanmap.Feature.InlayHints)
    if spanmap.Fidelity_IsNone(fidelity) then
        return
    end
    -- hint is a Go value (StringOrInlayHintLabelParts); build a new one rather than mutating the caller's.
    local label
    if hint.string ~= nil then
        label = { string = ": " .. hint.string }
    else
        local parts = { { value = ": " } }
        for _, part in ipairs(hint.inlayHintLabelParts or {}) do
            parts[#parts + 1] = part
        end
        label = { inlayHintLabelParts = parts }
    end
    self.result = core.Append(self.result, {
        label = label,
        position = lspPosition,
        kind = lsproto.InlayHintKind.Type,
        paddingLeft = true,
    })
end

function inlayHintState:addEnumMemberValueHints(text, position)
    local lspPosition, fidelity = self.converters:ToLSPPositionForFeature(self.file, position, spanmap.Feature.InlayHints)
    if spanmap.Fidelity_IsNone(fidelity) then
        return
    end
    self.result = core.Append(self.result, {
        label = {
            string = "= " .. text,
        },
        position = lspPosition,
        paddingLeft = true,
    })
end

function inlayHintState:addParameterHints(text, parameter, position, isFirstVariadicArgument)
    local lspPosition, fidelity = self.converters:ToLSPPositionForFeature(self.file, position, spanmap.Feature.InlayHints)
    if spanmap.Fidelity_IsNone(fidelity) then
        return
    end
    local hintText = core.IfElse(isFirstVariadicArgument, "...", "") .. text
    local displayParts = {
        self:getNodeDisplayPart(hintText, parameter),
        {
            value = ":",
        },
    }
    local labelParts = { inlayHintLabelParts = displayParts }

    self.result = core.Append(self.result, {
        label = labelParts,
        position = lspPosition,
        kind = lsproto.InlayHintKind.Parameter,
        paddingRight = true,
    })
end

function ls.shouldShowParameterNameHints(preferences)
    return (preferences.includeInlayParameterNameHints == IncludeInlayParameterNameHints.Literals or
        preferences.includeInlayParameterNameHints == IncludeInlayParameterNameHints.All)
end

function ls.shouldShowLiteralParameterNameHintsOnly(preferences)
    return preferences.includeInlayParameterNameHints == IncludeInlayParameterNameHints.Literals
end

-- node is FunctionDeclaration | ArrowFunction | FunctionExpression | MethodDeclaration | GetAccessor
function ls.isSignatureSupportingReturnAnnotation(node)
    return ast.IsArrowFunction(node) or ast.IsFunctionExpression(node) or ast.IsFunctionDeclaration(node) or
        ast.IsMethodDeclaration(node) or ast.IsGetAccessorDeclaration(node)
end

function ls.isHintableDeclaration(node)
    if (ast.IsPartOfParameterDeclaration(node) or ast.IsVariableDeclaration(node) and ast.IsVarConst(node)) and
        node:Initializer() ~= nil then
        local initializer = ast.SkipParentheses(node:Initializer())
        return not (ls.isHintableLiteral(initializer) or ast.IsNewExpression(initializer) or
            ast.IsObjectLiteralExpression(initializer) or ast.IsAssertionExpression(initializer))
    end
    return true
end

function ls.isHintableLiteral(node)
    local kind = node.kind
    if kind == Kind.PrefixUnaryExpression then
        local operand = node.operand
        return ast.IsLiteralExpression(operand) or ast.IsIdentifier(operand) and ast.IsInfinityOrNaNString(operand:Text())
    elseif kind == Kind.TrueKeyword or kind == Kind.FalseKeyword or kind == Kind.NullKeyword or
        kind == Kind.NoSubstitutionTemplateLiteral or kind == Kind.TemplateExpression then
        return true
    elseif kind == Kind.Identifier then
        local name = node:Text()
        return name == "undefined" or ast.IsInfinityOrNaNString(name)
    end
    return ast.IsLiteralExpression(node)
end

function ls.isModuleReferenceType(t)
    local symbol = t:Symbol()
    return symbol ~= nil and symbol.flags & SymbolFlags.Module ~= 0
end

function inlayHintState:getInlayHintLabelParts(node, idToSymbol)
    local parts

    local visitForDisplayParts
    local visitDisplayPartList
    local visitParametersAndTypeParameters

    local function add(value)
        parts = core.Append(parts, { value = value })
    end

    visitForDisplayParts = function(n)
        if n == nil then
            return
        end

        local tokenString = scanner.TokenToString(n.kind)
        if tokenString ~= "" then
            add(tokenString)
            return
        end

        if ast.IsLiteralExpression(n) then
            add(self:getLiteralText(n))
            return
        end

        local kind = n.kind
        if kind == Kind.Identifier then
            local identifierText = n:Text()
            local name
            local symbol = idToSymbol[n]
            if symbol ~= nil and core.Len(symbol.declarations) ~= 0 then
                name = ast.GetNameOfDeclaration(symbol.declarations[1])
            end
            if name ~= nil then
                parts = core.Append(parts, self:getNodeDisplayPart(identifierText, name))
            else
                add(identifierText)
            end
        elseif kind == Kind.QualifiedName then
            visitForDisplayParts(n.left)
            add(".")
            visitForDisplayParts(n.right)
        elseif kind == Kind.TypePredicate then
            if n.assertsModifier ~= nil then
                add("asserts ")
            end
            visitForDisplayParts(n.parameterName)
            if n:Type() ~= nil then
                add(" is ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.TypeReference then
            visitForDisplayParts(n.typeName)
            if core.Len(n:TypeArguments()) > 0 then
                add("<")
                visitDisplayPartList(n:TypeArguments(), ",")
                add(">")
            end
        elseif kind == Kind.TypeParameter then
            if core.Len(n:ModifierNodes()) > 0 then
                visitDisplayPartList(n:ModifierNodes(), "")
            end
            visitForDisplayParts(n:Name())
            if n.constraint ~= nil then
                add(" extends ")
                visitForDisplayParts(n.constraint)
            end
            if n.defaultType ~= nil then
                add(" = ")
                visitForDisplayParts(n.defaultType)
            end
        elseif kind == Kind.Parameter then
            if core.Len(n:ModifierNodes()) > 0 then
                visitDisplayPartList(n:ModifierNodes(), " ")
            end
            if n.dotDotDotToken ~= nil then
                add("...")
            end
            visitForDisplayParts(n:Name())
            if n:QuestionToken() ~= nil then
                add("?")
            end
            if n:Type() ~= nil then
                add(": ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.ConstructorType then
            add("new ")
            visitParametersAndTypeParameters(n)
            add(" => ")
            visitForDisplayParts(n:Type())
        elseif kind == Kind.TypeQuery then
            add("typeof ")
            visitForDisplayParts(n.exprName)
            if core.Len(n:TypeArguments()) > 0 then
                add("<")
                visitDisplayPartList(n:TypeArguments(), ", ")
                add(">")
            end
        elseif kind == Kind.TypeLiteral then
            add("{")
            if core.Len(n:Members()) > 0 then
                add(" ")
                visitDisplayPartList(n:Members(), "; ")
                add(" ")
            end
            add("}")
        elseif kind == Kind.ArrayType then
            visitForDisplayParts(n.elementType)
            add("[]")
        elseif kind == Kind.TupleType then
            add("[")
            visitDisplayPartList(n:Elements(), ", ")
            add("]")
        elseif kind == Kind.NamedTupleMember then
            if n.dotDotDotToken ~= nil then
                add("...")
            end
            visitForDisplayParts(n:Name())
            if n:QuestionToken() ~= nil then
                add("?")
            end
            add(": ")
            visitForDisplayParts(n:Type())
        elseif kind == Kind.OptionalType then
            visitForDisplayParts(n:Type())
            add("?")
        elseif kind == Kind.RestType then
            add("...")
            visitForDisplayParts(n:Type())
        elseif kind == Kind.UnionType then
            if n.types ~= nil then
                visitDisplayPartList(n.types.nodes, " | ")
            end
        elseif kind == Kind.IntersectionType then
            if n.types ~= nil then
                visitDisplayPartList(n.types.nodes, " & ")
            end
        elseif kind == Kind.ConditionalType then
            visitForDisplayParts(n.checkType)
            add(" extends ")
            visitForDisplayParts(n.extendsType)
            add(" ? ")
            visitForDisplayParts(n.trueType)
            add(" : ")
            visitForDisplayParts(n.falseType)
        elseif kind == Kind.InferType then
            add("infer ")
            visitForDisplayParts(n.typeParameter)
        elseif kind == Kind.ParenthesizedType then
            add("(")
            visitForDisplayParts(n:Type())
            add(")")
        elseif kind == Kind.TypeOperator then
            add(scanner.TokenToString(n.operator))
            visitForDisplayParts(n:Type())
        elseif kind == Kind.IndexedAccessType then
            visitForDisplayParts(n.objectType)
            add("[")
            visitForDisplayParts(n.indexType)
            add("]")
        elseif kind == Kind.MappedType then
            add("{ ")
            if n.readonlyToken ~= nil then
                if n.readonlyToken.kind == Kind.PlusToken then
                    add("+")
                elseif n.readonlyToken.kind == Kind.MinusToken then
                    add("-")
                end
                add("readonly ")
            end
            add("[")
            visitForDisplayParts(n.typeParameter)
            if n.nameType ~= nil then
                add(" as ")
                visitForDisplayParts(n.nameType)
            end
            add("]")
            if n:QuestionToken() ~= nil then
                if n:QuestionToken().kind == Kind.PlusToken then
                    add("+")
                elseif n:QuestionToken().kind == Kind.MinusToken then
                    add("-")
                end
                add("?")
            end
            add(": ")
            if n:Type() ~= nil then
                visitForDisplayParts(n:Type())
            end
            add("; }")
        elseif kind == Kind.LiteralType then
            visitForDisplayParts(n.literal)
        elseif kind == Kind.FunctionType then
            visitParametersAndTypeParameters(n)
            add(" => ")
            visitForDisplayParts(n:Type())
        elseif kind == Kind.ImportType then
            if n.isTypeOf then
                add("typeof ")
            end
            add("import(")
            visitForDisplayParts(n.argument)
            add(")")
            if n.qualifier ~= nil then
                add(".")
                visitForDisplayParts(n.qualifier)
            end
            if core.Len(n:TypeArguments()) > 0 then
                add("<")
                visitDisplayPartList(n:TypeArguments(), ", ")
                add(">")
            end
        elseif kind == Kind.PropertySignature then
            if core.Len(n:ModifierNodes()) > 0 then
                visitDisplayPartList(n:ModifierNodes(), " ")
                add(" ")
            end
            visitForDisplayParts(n:Name())
            if n:PostfixToken() ~= nil then
                add(scanner.TokenToString(n:PostfixToken().kind))
            end
            if n:Type() ~= nil then
                add(": ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.IndexSignature then
            add("[")
            visitDisplayPartList(n:Parameters(), ", ")
            add("]")
            if n:Type() ~= nil then
                add(": ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.MethodSignature then
            if core.Len(n:ModifierNodes()) > 0 then
                visitDisplayPartList(n:ModifierNodes(), " ")
                add(" ")
            end
            visitForDisplayParts(n:Name())
            if n:PostfixToken() ~= nil then
                add(scanner.TokenToString(n:PostfixToken().kind))
            end
            visitParametersAndTypeParameters(n)
            if n:Type() ~= nil then
                add(": ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.CallSignature then
            visitParametersAndTypeParameters(n)
            if n:Type() ~= nil then
                add(": ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.ConstructSignature then
            add("new ")
            visitParametersAndTypeParameters(n)
            if n:Type() ~= nil then
                add(": ")
                visitForDisplayParts(n:Type())
            end
        elseif kind == Kind.ArrayBindingPattern then
            add("[")
            visitDisplayPartList(n:Elements(), ", ")
            add("]")
        elseif kind == Kind.ObjectBindingPattern then
            add("{")
            if core.Len(n:Elements()) > 0 then
                add(" ")
                visitDisplayPartList(n:Elements(), ", ")
                add(" ")
            end
            add("}")
        elseif kind == Kind.BindingElement then
            visitForDisplayParts(n:Name())
        elseif kind == Kind.PrefixUnaryExpression then
            add(scanner.TokenToString(n.operator))
            visitForDisplayParts(n.operand)
        elseif kind == Kind.TemplateLiteralType then
            visitForDisplayParts(n.head)
            for _, span in ipairs(n.templateSpans.nodes) do
                visitForDisplayParts(span)
            end
        elseif kind == Kind.TemplateHead then
            add(self:getLiteralText(n))
        elseif kind == Kind.TemplateLiteralTypeSpan then
            visitForDisplayParts(n:Type())
            visitForDisplayParts(n.literal)
        elseif kind == Kind.TemplateMiddle or kind == Kind.TemplateTail then
            add(self:getLiteralText(n))
        elseif kind == Kind.ThisType then
            add("this")
        elseif kind == Kind.ComputedPropertyName then
            add("[")
            visitForDisplayParts(n:Expression())
            add("]")
        elseif kind == Kind.PropertyAccessExpression then
            visitForDisplayParts(n:Expression())
            add(".")
            visitForDisplayParts(n:Name())
        elseif kind == Kind.ElementAccessExpression then
            visitForDisplayParts(n:Expression())
            add("[")
            visitForDisplayParts(n.argumentExpression)
            add("]")
        else
            debug.FailBadSyntaxKind(n)
        end
    end

    visitDisplayPartList = function(nodes, separator)
        for i1, n in ipairs(nodes or {}) do
            if i1 > 1 then
                add(separator)
            end
            visitForDisplayParts(n)
        end
    end

    visitParametersAndTypeParameters = function(n)
        if core.Len(n:TypeParameters()) > 0 then
            add("<")
            visitDisplayPartList(n:TypeParameters(), ", ")
            add(">")
        end
        add("(")
        visitDisplayPartList(n:Parameters(), ", ")
        add(")")
    end

    visitForDisplayParts(node)
    return parts
end

function inlayHintState:getNodeDisplayPart(text, node)
    local file = ast.GetSourceFileOfNode(node)
    local pos = astnav.GetStartOfNode(node, file, false --[[includeJSDoc]])
    local end_ = node:End()
    local part = { value = text }
    -- The location is an optional go-to target for the name. Only attach it when the name maps back to a
    -- single concrete span in the original text; an approximate or synthesized mapping would point the
    -- user somewhere wrong, so it is better to omit the target than to fabricate one.
    local lspRange, fidelity = self.converters:ToLSPRangeForFeature(file, core.NewTextRange(pos, end_), spanmap.Feature.InlayHints)
    if spanmap.Fidelity_IsSingleSegment(fidelity) then
        part.location = {
            uri = lsconv.FileNameToDocumentURI(file:OriginalFileName()),
            range = lspRange,
        }
    end
    return part
end

function inlayHintState:getLiteralText(node)
    local kind = node.kind
    if kind == Kind.StringLiteral then
        if self.quotePreference == lsutil.QuotePreference.Single then
            return "'" .. printer.EscapeString(node:Text(), printer.QuoteChar.SingleQuote) .. "'"
        end
        return "\"" .. printer.EscapeString(node:Text(), printer.QuoteChar.DoubleQuote) .. "\""
    elseif kind == Kind.TemplateHead or kind == Kind.TemplateMiddle or kind == Kind.TemplateTail then
        local rawText = node:RawText()
        if rawText == "" then
            rawText = printer.EscapeString(node:Text(), printer.QuoteChar.Backtick)
        end
        if kind == Kind.TemplateHead then
            return "`" .. rawText .. "${"
        elseif kind == Kind.TemplateMiddle then
            return "}" .. rawText .. "${"
        elseif kind == Kind.TemplateTail then
            return "}" .. rawText .. "`"
        end
    end
    return node:Text()
end

-- parameterInfo: { parameter, name, isRestParameter }

function inlayHintState:getParameterIdentifierInfoAtPosition(signature, pos)
    local parameters = signature:Parameters()
    local paramCount = core.Len(parameters) - core.IfElse(signature:HasRestParameter(), 1, 0)
    if pos < paramCount then
        local param = parameters[pos + 1]
        local paramId = ls.getParameterDeclarationIdentifier(param)
        if paramId == nil then
            return nil
        end
        return {
            parameter = paramId,
            name = paramId:Text(),
            isRestParameter = false,
        }
    end

    local restParameter
    local restId
    if paramCount < core.Len(parameters) then
        restParameter = parameters[paramCount + 1]
        restId = ls.getParameterDeclarationIdentifier(restParameter)
    end
    if restId == nil then
        return nil
    end

    local restType = self.checker:GetTypeOfSymbol(restParameter)
    if restType:IsTupleType() then
        local associatedNames = {}
        for _, elementInfo in ipairs(restType:Target():AsTupleType():ElementInfos() or {}) do
            local labeledElement = elementInfo:LabeledDeclaration()
            -- Go appends nil entries too; keep a placeholder so indices line up.
            associatedNames[#associatedNames + 1] = labeledElement or false
        end
        local index = pos - paramCount
        if index < #associatedNames then
            local associatedName = associatedNames[index + 1]
            if associatedName then
                debug.Assert(ast.IsIdentifier(associatedName:Name()))
                local isRestTupleElement
                if ast.IsNamedTupleMember(associatedName) then
                    isRestTupleElement = associatedName.dotDotDotToken ~= nil
                else
                    isRestTupleElement = associatedName:AsParameterDeclaration().dotDotDotToken ~= nil
                end
                return {
                    parameter = associatedName:Name(),
                    name = associatedName:Name():Text(),
                    isRestParameter = isRestTupleElement,
                }
            end
        end

        return nil
    end

    if pos == paramCount then
        return {
            parameter = restId,
            name = restParameter.name,
            isRestParameter = true,
        }
    end
    return nil
end

function ls.getParameterDeclarationIdentifier(symbol)
    if symbol.valueDeclaration ~= nil and ast.IsParameterDeclaration(symbol.valueDeclaration) and ast.IsIdentifier(symbol.valueDeclaration:Name()) then
        return symbol.valueDeclaration:Name()
    end
    return nil
end

function ls.identifierOrAccessExpressionPostfixMatchesParameterName(expr, parameterName)
    if ast.IsIdentifier(expr) then
        return expr:Text() == parameterName
    end
    if ast.IsPropertyAccessExpression(expr) then
        return expr:Name():Text() == parameterName
    end
    return false
end

function inlayHintState:leadingCommentsContainsParameterName(node, name)
    if not scanner.IsIdentifierText(name, self.file.languageVariant) then
        return false
    end

    local ranges = ls.getLeadingCommentRangesOfNode(node, self.file)
    if ranges == nil then
        return false
    end
    local fileText = self.file:Text()
    for r in ranges do
        local commentText = trimFunc(string.sub(fileText, r:Pos() + 1, r:End()), function(ch)
            return stringutil.UnicodeIsSpace(ch) or ch == 0x2F --[[ '/' ]] or ch == 0x2A --[[ '*' ]]
        end)
        if commentText == name then
            return true
        end
    end

    return false
end

function inlayHintState:getTypeAnnotationPosition(decl)
    local closeParenToken = astnav.FindChildOfKind(decl, Kind.CloseParenToken, self.file)
    if closeParenToken ~= nil then
        return closeParenToken:End()
    end
    return decl:ParameterList():End()
end

function ls.isAnyInlayHintEnabled(preferences)
    return preferences.includeInlayParameterNameHints ~= IncludeInlayParameterNameHints.None or
        isTrue(preferences.includeInlayFunctionParameterTypeHints) or
        isTrue(preferences.includeInlayVariableTypeHints) or
        isTrue(preferences.includeInlayPropertyDeclarationTypeHints) or
        isTrue(preferences.includeInlayFunctionLikeReturnTypeHints) or
        isTrue(preferences.includeInlayEnumMemberValueHints)
end
