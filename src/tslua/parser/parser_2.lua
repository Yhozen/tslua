local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local PC = parser.ParsingContext
local ParseFlags = parser.ParseFlags
local Parser = parser.Parser
local Tristate = core.Tristate

-- TYPES

function Parser:parseType()
    local p = self
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.TypeExcludesFlags, false)
    local typeNode
    if p:isStartOfFunctionTypeOrConstructorType() then
        typeNode = p:parseFunctionOrConstructorType()
    else
        local pos = p:nodePos()
        typeNode = p:parseUnionTypeOrHigher()
        if not p:inDisallowConditionalTypesContext() and not p:hasPrecedingLineBreak() and p:parseOptional(Kind.ExtendsKeyword) then
            -- The type following 'extends' is not permitted to be another conditional type
            local extendsType = parser.doInContext(p, NodeFlags.DisallowConditionalTypesContext, true, Parser.parseType)
            p:parseExpected(Kind.QuestionToken)
            local trueType = parser.doInContext(p, NodeFlags.DisallowConditionalTypesContext, false, Parser.parseType)
            p:parseExpected(Kind.ColonToken)
            local falseType = parser.doInContext(p, NodeFlags.DisallowConditionalTypesContext, false, Parser.parseType)
            local conditionalType = p.factory:NewConditionalTypeNode(typeNode, extendsType, trueType, falseType)
            p:finishNode(conditionalType, pos)
            typeNode = conditionalType
        end
    end
    p.contextFlags = saveContextFlags
    return typeNode
end

function Parser:parseUnionTypeOrHigher()
    return self:parseUnionOrIntersectionType(Kind.BarToken, Parser.parseIntersectionTypeOrHigher)
end

function Parser:parseIntersectionTypeOrHigher()
    return self:parseUnionOrIntersectionType(Kind.AmpersandToken, Parser.parseTypeOperatorOrHigher)
end

function Parser:parseUnionOrIntersectionType(operator, parseConstituentType)
    local p = self
    local pos = p:nodePos()
    local isUnionType = operator == Kind.BarToken
    local hasLeadingOperator = p:parseOptional(operator)
    local typeNode
    if hasLeadingOperator then
        typeNode = p:parseFunctionOrConstructorTypeToError(isUnionType, parseConstituentType)
    else
        typeNode = parseConstituentType(p)
    end
    if p.token == operator or hasLeadingOperator then
        local types = { typeNode }
        while p:parseOptional(operator) do
            types[#types + 1] = p:parseFunctionOrConstructorTypeToError(isUnionType, parseConstituentType)
        end
        typeNode = p:createUnionOrIntersectionTypeNode(operator, p:newNodeList(core.NewTextRange(pos, p:nodePos()), types))
        p:finishNode(typeNode, pos)
    end
    return typeNode
end

function Parser:createUnionOrIntersectionTypeNode(operator, types)
    if operator == Kind.BarToken then
        return self.factory:NewUnionTypeNode(types)
    elseif operator == Kind.AmpersandToken then
        return self.factory:NewIntersectionTypeNode(types)
    else
        error("Unhandled case in createUnionOrIntersectionType", 0)
    end
end

function Parser:parseTypeOperatorOrHigher()
    local operator = self.token
    if operator == Kind.KeyOfKeyword or operator == Kind.UniqueKeyword or operator == Kind.ReadonlyKeyword then
        return self:parseTypeOperator(operator)
    elseif operator == Kind.InferKeyword then
        return self:parseInferType()
    end
    return parser.doInContext(self, NodeFlags.DisallowConditionalTypesContext, false, Parser.parsePostfixTypeOrHigher)
end

function Parser:parseTypeOperator(operator)
    local pos = self:nodePos()
    self:parseExpected(operator)
    return self:finishNode(self.factory:NewTypeOperatorNode(operator, self:parseTypeOperatorOrHigher()), pos)
end

function Parser:parseInferType()
    local pos = self:nodePos()
    self:parseExpected(Kind.InferKeyword)
    return self:finishNode(self.factory:NewInferTypeNode(self:parseTypeParameterOfInferType()), pos)
end

function Parser:parseTypeParameterOfInferType()
    local pos = self:nodePos()
    local name = self:parseIdentifier()
    local constraint = self:tryParseConstraintOfInferType()
    return self:finishNode(self.factory:NewTypeParameterDeclaration(nil --[[modifiers]], name, constraint, nil --[[expression]], nil --[[defaultType]]), pos)
end

function Parser:tryParseConstraintOfInferType()
    local p = self
    local state = p:mark()
    if p:parseOptional(Kind.ExtendsKeyword) then
        local constraint = parser.doInContext(p, NodeFlags.DisallowConditionalTypesContext, true, Parser.parseType)
        if p:inDisallowConditionalTypesContext() or p.token ~= Kind.QuestionToken then
            return constraint
        end
    end
    p:rewind(state)
    return nil
end

function Parser:parsePostfixTypeOrHigher()
    local p = self
    local pos = p:nodePos()
    local typeNode = p:parseNonArrayType()
    while not p:hasPrecedingLineBreak() do
        local t = p.token
        if t == Kind.ExclamationToken then
            p:nextToken()
            typeNode = p:finishNode(p.factory:NewJSDocNonNullableType(typeNode), pos)
        elseif t == Kind.QuestionToken then
            -- If next token is start of a type we have a conditional type
            if p:lookAhead(Parser.nextIsStartOfType) then
                return typeNode
            end
            p:nextToken()
            typeNode = p:finishNode(p.factory:NewJSDocNullableType(typeNode), pos)
        elseif t == Kind.OpenBracketToken then
            p:parseExpected(Kind.OpenBracketToken)
            if p:isStartOfType(false --[[isStartOfParameter]]) then
                local indexType = p:parseType()
                p:parseExpected(Kind.CloseBracketToken)
                typeNode = p:finishNode(p.factory:NewIndexedAccessTypeNode(typeNode, indexType), pos)
            else
                p:parseExpected(Kind.CloseBracketToken)
                typeNode = p:finishNode(p.factory:NewArrayTypeNode(typeNode), pos)
            end
        else
            return typeNode
        end
    end
    return typeNode
end

function Parser:nextIsStartOfType()
    self:nextToken()
    return self:isStartOfType(false --[[inStartOfParameter]])
end

function Parser:parseNonArrayType()
    local p = self
    local t = p.token
    if t == Kind.AnyKeyword or t == Kind.UnknownKeyword or t == Kind.StringKeyword or t == Kind.NumberKeyword or t == Kind.BigIntKeyword or
        t == Kind.SymbolKeyword or t == Kind.BooleanKeyword or t == Kind.UndefinedKeyword or t == Kind.NeverKeyword or t == Kind.ObjectKeyword then
        local state = p:mark()
        local keywordTypeNode = p:parseKeywordTypeNode()
        -- If these are followed by a dot then parse these out as a dotted type reference instead
        if p.token ~= Kind.DotToken then
            return keywordTypeNode
        end
        p:rewind(state)
        return p:parseTypeReference()
    elseif t == Kind.AsteriskEqualsToken or t == Kind.AsteriskToken then
        if t == Kind.AsteriskEqualsToken then
            -- If there is '*=', treat it as * followed by postfix =
            p.scanner:ReScanAsteriskEqualsToken()
        end
        return p:parseJSDocAllType()
    elseif t == Kind.QuestionQuestionToken or t == Kind.QuestionToken then
        if t == Kind.QuestionQuestionToken then
            -- If there is '??', treat it as prefix-'?' in JSDoc type.
            p.scanner:ReScanQuestionToken()
        end
        return p:parseJSDocNullableType()
    elseif t == Kind.ExclamationToken then
        return p:parseJSDocNonNullableType()
    elseif t == Kind.NoSubstitutionTemplateLiteral or t == Kind.StringLiteral or t == Kind.NumericLiteral or t == Kind.BigIntLiteral or t == Kind.TrueKeyword or
        t == Kind.FalseKeyword or t == Kind.NullKeyword then
        return p:parseLiteralTypeNode(false --[[negative]])
    elseif t == Kind.MinusToken then
        if p:lookAhead(Parser.nextTokenIsNumericOrBigIntLiteral) then
            return p:parseLiteralTypeNode(true --[[negative]])
        end
        return p:parseTypeReference()
    elseif t == Kind.VoidKeyword then
        return p:parseKeywordTypeNode()
    elseif t == Kind.ThisKeyword then
        local thisKeyword = p:parseThisTypeNode()
        if p.token == Kind.IsKeyword and not p:hasPrecedingLineBreak() then
            return p:parseThisTypePredicate(thisKeyword)
        end
        return thisKeyword
    elseif t == Kind.TypeOfKeyword then
        if p:lookAhead(Parser.nextIsStartOfTypeOfImportType) then
            return p:parseImportType()
        end
        return p:parseTypeQuery()
    elseif t == Kind.OpenBraceToken then
        if p:lookAhead(Parser.nextIsStartOfMappedType) then
            return p:parseMappedType()
        end
        return p:parseTypeLiteral()
    elseif t == Kind.OpenBracketToken then
        return p:parseTupleType()
    elseif t == Kind.OpenParenToken then
        return p:parseParenthesizedType()
    elseif t == Kind.ImportKeyword then
        return p:parseImportType()
    elseif t == Kind.AssertsKeyword then
        if p:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOnSameLine) then
            return p:parseAssertsTypePredicate()
        end
        return p:parseTypeReference()
    elseif t == Kind.TemplateHead then
        return p:parseTemplateType()
    else
        return p:parseTypeReference()
    end
end

function Parser:parseKeywordTypeNode()
    local pos = self:nodePos()
    local result = self.factory:NewKeywordTypeNode(self.token)
    self:nextToken()
    return self:finishNode(result, pos)
end

function Parser:parseThisTypeNode()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewThisTypeNode(), pos)
end

function Parser:parseThisTypePredicate(lhs)
    self:nextToken()
    return self:finishNode(self.factory:NewTypePredicateNode(nil --[[assertsModifier]], lhs, self:parseType()), lhs:Pos())
end

function Parser:parseJSDocAllType()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewJSDocAllType(), pos)
end

function Parser:parseJSDocNonNullableType()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewJSDocNonNullableType(self:parseTypeOperatorOrHigher()), pos)
end

function Parser:parseJSDocNullableType()
    local pos = self:nodePos()
    -- skip the ?
    self:nextToken()
    return self:finishNode(self.factory:NewJSDocNullableType(self:parseTypeOperatorOrHigher()), pos)
end

function Parser:parseJSDocType()
    local p = self
    p.scanner:SetSkipJSDocLeadingAsterisks(true)
    local pos = p:nodePos()

    local hasDotDotDot = p:parseOptional(Kind.DotDotDotToken)
    local t = p:parseTypeOrTypePredicate()
    p.scanner:SetSkipJSDocLeadingAsterisks(false)
    if hasDotDotDot then
        t = p:finishNode(p.factory:NewJSDocVariadicType(t), pos)
    end
    if p.token == Kind.EqualsToken then
        p:nextToken()
        return p:finishNode(p.factory:NewJSDocOptionalType(t), pos)
    end
    return t
end

function Parser:parseLiteralTypeNode(negative)
    local p = self
    local pos = p:nodePos()
    if negative then
        p:nextToken()
    end
    local expression
    if p.token == Kind.TrueKeyword or p.token == Kind.FalseKeyword or p.token == Kind.NullKeyword then
        expression = p:parseKeywordExpression()
    else
        expression = p:parseLiteralExpression()
    end
    if negative then
        expression = p:finishNode(p.factory:NewPrefixUnaryExpression(Kind.MinusToken, expression), pos)
    end
    return p:finishNode(p.factory:NewLiteralTypeNode(expression), pos)
end

function Parser:parseTypeReference()
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewTypeReferenceNode(self:parseEntityNameOfTypeReference(), self:parseTypeArgumentsOfTypeReference()), pos)
end

function Parser:parseEntityNameOfTypeReference()
    return self:parseEntityName(true --[[allowReservedWords]], false --[[allowPrivateName]], diagnostics.Type_expected)
end

function Parser:parseEntityName(allowReservedWords, allowPrivateName, diagnosticMessage)
    local p = self
    local pos = p:nodePos()
    local entity
    if allowReservedWords then
        entity = p:parseIdentifierNameWithDiagnostic(diagnosticMessage)
    else
        entity = p:parseIdentifierWithDiagnostic(diagnosticMessage, nil)
    end
    while p:parseOptional(Kind.DotToken) do
        if p.token == Kind.LessThanToken then
            -- The entity is part of a JSDoc-style generic. We will use the gap between `typeName` and
            -- `typeArguments` to report it as a grammar error in the checker.
            break
        end
        entity = p:finishNode(p.factory:NewQualifiedName(entity, p:parseRightSideOfDot(allowReservedWords, allowPrivateName, true --[[allowUnicodeEscapeSequenceInIdentifierName]])), pos)
    end
    return entity
end

function Parser:parseRightSideOfDot(allowIdentifierNames, allowPrivateIdentifiers, allowUnicodeEscapeSequenceInIdentifierName)
    local p = self
    -- Technically a keyword is valid here as all identifiers and keywords are identifier names.
    -- However, often we'll encounter this in error situations when the identifier or keyword
    -- is actually starting another valid construct.
    --
    -- So, we check for the following specific case:
    --
    --      name.
    --      identifierOrKeyword identifierNameOrKeyword
    --
    -- Note: the newlines are important here.  For example, if that above code
    -- were rewritten into:
    --
    --      name.identifierOrKeyword
    --      identifierNameOrKeyword
    --
    -- Then we would consider it valid.  That's because ASI would take effect and
    -- the code would be implicitly: "name.identifierOrKeyword; identifierNameOrKeyword".
    -- In the first case though, ASI will not take effect because there is not a
    -- line terminator after the identifier or keyword.
    if p:hasPrecedingLineBreak() and parser.tokenIsIdentifierOrKeyword(p.token) and p:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOnSameLine) then
        -- Report that we need an identifier.  However, report it right after the dot,
        -- and not on the next token.  This is because the next token might actually
        -- be an identifier and the error would be quite confusing.
        p:parseErrorAt(p:nodePos(), p:nodePos(), diagnostics.Identifier_expected)
        return p:createMissingIdentifier()
    end
    if p.token == Kind.PrivateIdentifier then
        local node = p:parsePrivateIdentifier()
        if allowPrivateIdentifiers then
            return node
        end
        p:parseErrorAt(p:nodePos(), p:nodePos(), diagnostics.Identifier_expected)
        return p:createMissingIdentifier()
    end
    if allowIdentifierNames then
        if allowUnicodeEscapeSequenceInIdentifierName then
            return p:parseIdentifierName()
        end
        return p:parseIdentifierNameErrorOnUnicodeEscapeSequence()
    end
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    local id = p:parseIdentifier()
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return id
end

function Parser:newIdentifier(text)
    self.identifierCount = self.identifierCount + 1
    local id = self.factory:NewIdentifier(text)
    if text == "await" then
        self.statementHasAwaitIdentifier = true
    end
    return id
end

function Parser:createMissingIdentifier()
    return self:finishNode(self:newIdentifier(""), self:nodePos())
end

function Parser:parsePrivateIdentifier()
    local pos = self:nodePos()
    local text = self.scanner:TokenValue()
    self:nextToken()
    return self:finishNode(self.factory:NewPrivateIdentifier(text), pos)
end

function Parser:reScanLessThanToken()
    self.token = self.scanner:ReScanLessThanToken()
    return self.token
end

function Parser:reScanGreaterThanToken()
    self.token = self.scanner:ReScanGreaterThanToken()
    return self.token
end

function Parser:reScanSlashToken()
    self.token = self.scanner:ReScanSlashToken()
    return self.token
end

function Parser:reScanTemplateToken(isTaggedTemplate)
    self.token = self.scanner:ReScanTemplateToken(isTaggedTemplate)
    return self.token
end

function Parser:parseTypeArgumentsOfTypeReference()
    if not self:hasPrecedingLineBreak() and self:reScanLessThanToken() == Kind.LessThanToken then
        return self:parseTypeArguments()
    end
    return nil
end

function Parser:parseTypeArguments()
    if self.token == Kind.LessThanToken then
        return self:parseBracketedList(PC.PCTypeArguments, Parser.parseType, Kind.LessThanToken, Kind.GreaterThanToken)
    end
    return nil
end

function Parser:nextIsStartOfTypeOfImportType()
    self:nextToken()
    return self.token == Kind.ImportKeyword
end

function Parser:parseImportType()
    local p = self
    p.sourceFlags = p.sourceFlags | NodeFlags.PossiblyContainsDynamicImport
    local pos = p:nodePos()
    local isTypeOf = p:parseOptional(Kind.TypeOfKeyword)
    p:parseExpected(Kind.ImportKeyword)
    p:parseExpected(Kind.OpenParenToken)
    local typeNode = p:parseType()
    local attributes = nil
    if p:parseOptional(Kind.CommaToken) then
        local openBracePosition = p.scanner:TokenStart()
        p:parseExpected(Kind.OpenBraceToken)
        local currentToken = p.token
        if currentToken == Kind.WithKeyword or currentToken == Kind.AssertKeyword then
            if currentToken == Kind.AssertKeyword then
                p:parseErrorAtCurrentToken(diagnostics.Import_assertions_have_been_replaced_by_import_attributes_Use_with_instead_of_assert)
            end
            p:nextToken()
        else
            p:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(Kind.WithKeyword))
        end
        p:parseExpected(Kind.ColonToken)
        attributes = p:parseImportAttributes(currentToken, true --[[skipKeyword]])
        p:parseOptional(Kind.CommaToken)
        if not p:parseExpected(Kind.CloseBraceToken) then
            if #p.diagnostics ~= 0 then
                local lastDiagnostic = p.diagnostics[#p.diagnostics]
                if lastDiagnostic:Code() == diagnostics.X_0_expected:Code() then
                    local related = ast.NewDiagnostic(nil, core.NewTextRange(openBracePosition, openBracePosition), diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here, "{", "}")
                    lastDiagnostic:AddRelatedInfo(related)
                end
            end
        end
    end
    p:parseExpected(Kind.CloseParenToken)
    local qualifier = nil
    if p:parseOptional(Kind.DotToken) then
        qualifier = p:parseEntityNameOfTypeReference()
    end
    local typeArguments = p:parseTypeArgumentsOfTypeReference()
    return p:finishNode(p.factory:NewImportTypeNode(isTypeOf, typeNode, attributes, qualifier, typeArguments), pos)
end

function Parser:parseImportAttribute()
    local p = self
    local pos = p:nodePos()
    local name = nil
    if parser.tokenIsIdentifierOrKeyword(p.token) then
        name = p:parseIdentifierName()
    elseif p.token == Kind.StringLiteral then
        name = p:parseLiteralExpression()
    end
    if name ~= nil then
        p:parseExpected(Kind.ColonToken)
    else
        p:parseErrorAtCurrentToken(diagnostics.Identifier_or_string_literal_expected)
    end
    local value = p:parseAssignmentExpressionOrHigher()
    return p:finishNode(p.factory:NewImportAttribute(name, value), pos)
end

function Parser:parseImportAttributes(token, skipKeyword)
    local p = self
    local pos = p:nodePos()
    if not skipKeyword then
        p:parseExpected(token)
    end
    local elements
    local multiLine = false
    local openBracePosition = p.scanner:TokenStart()
    if p:parseExpected(Kind.OpenBraceToken) then
        multiLine = p:hasPrecedingLineBreak()
        elements = p:parseDelimitedList(PC.PCImportAttributes, Parser.parseImportAttribute)
        if not p:parseExpected(Kind.CloseBraceToken) then
            if #p.diagnostics ~= 0 then
                local lastDiagnostic = p.diagnostics[#p.diagnostics]
                if lastDiagnostic:Code() == diagnostics.X_0_expected:Code() then
                    local related = ast.NewDiagnostic(nil, core.NewTextRange(openBracePosition, openBracePosition), diagnostics.The_parser_expected_to_find_a_1_to_match_the_0_token_here, "{", "}")
                    lastDiagnostic:AddRelatedInfo(related)
                end
            end
        end
    else
        elements = p:parseEmptyNodeList()
    end
    return p:finishNode(p.factory:NewImportAttributes(token, elements, multiLine), pos)
end

function Parser:parseTypeQuery()
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.TypeOfKeyword)
    local entityName = p:parseEntityName(true --[[allowReservedWords]], true --[[allowPrivateName]], nil)
    -- Make sure we perform ASI to prevent parsing the next line's type arguments as part of an instantiation expression
    local typeArguments = nil
    if not p:hasPrecedingLineBreak() then
        typeArguments = p:parseTypeArguments()
    end
    return p:finishNode(p.factory:NewTypeQueryNode(entityName, typeArguments), pos)
end

function Parser:nextIsStartOfMappedType()
    local p = self
    p:nextToken()
    if p.token == Kind.PlusToken or p.token == Kind.MinusToken then
        return p:nextToken() == Kind.ReadonlyKeyword
    end
    if p.token == Kind.ReadonlyKeyword then
        p:nextToken()
    end
    return p.token == Kind.OpenBracketToken and p:nextTokenIsIdentifier() and p:nextToken() == Kind.InKeyword
end

function Parser:parseMappedType()
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.OpenBraceToken)
    local readonlyToken = nil -- ReadonlyKeyword | PlusToken | MinusToken
    if p.token == Kind.ReadonlyKeyword or p.token == Kind.PlusToken or p.token == Kind.MinusToken then
        readonlyToken = p:parseTokenNode()
        if readonlyToken.kind ~= Kind.ReadonlyKeyword then
            p:parseExpected(Kind.ReadonlyKeyword)
        end
    end
    p:parseExpected(Kind.OpenBracketToken)
    local typeParameter = p:parseMappedTypeParameter()
    local nameType = nil
    if p:parseOptional(Kind.AsKeyword) then
        nameType = p:parseType()
    end
    p:parseExpected(Kind.CloseBracketToken)
    local questionToken = nil -- QuestionToken | PlusToken | MinusToken
    if p.token == Kind.QuestionToken or p.token == Kind.PlusToken or p.token == Kind.MinusToken then
        questionToken = p:parseTokenNode()
        if questionToken.kind ~= Kind.QuestionToken then
            p:parseExpected(Kind.QuestionToken)
        end
    end
    local typeNode = p:parseTypeAnnotation()
    p:parseSemicolon()
    local members = p:parseList(PC.PCTypeMembers, Parser.parseTypeMember)
    p:parseExpected(Kind.CloseBraceToken)
    return p:finishNode(p.factory:NewMappedTypeNode(readonlyToken, typeParameter, nameType, questionToken, typeNode, members), pos)
end

function Parser:parseMappedTypeParameter()
    local pos = self:nodePos()
    local name = self:parseIdentifierName()
    self:parseExpected(Kind.InKeyword)
    local typeNode = self:parseType()
    return self:finishNode(self.factory:NewTypeParameterDeclaration(nil --[[modifiers]], name, typeNode, nil --[[expression]], nil --[[defaultType]]), pos)
end

function Parser:parseTypeMember()
    local p = self
    if p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken then
        return p:parseSignatureMember(Kind.CallSignature)
    end
    if p.token == Kind.NewKeyword and p:lookAhead(Parser.nextTokenIsOpenParenOrLessThan) then
        return p:parseSignatureMember(Kind.ConstructSignature)
    end
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local modifiers = p:parseModifiers()
    if p:parseContextualModifier(Kind.GetKeyword) then
        return p:parseAccessorDeclaration(pos, jsdoc, modifiers, Kind.GetAccessor, ParseFlags.Type)
    end
    if p:parseContextualModifier(Kind.SetKeyword) then
        return p:parseAccessorDeclaration(pos, jsdoc, modifiers, Kind.SetAccessor, ParseFlags.Type)
    end
    if p:isIndexSignature() then
        return p:parseIndexSignatureDeclaration(pos, jsdoc, modifiers)
    end
    return p:parsePropertyOrMethodSignature(pos, jsdoc, modifiers)
end

function Parser:nextTokenIsOpenParenOrLessThan()
    self:nextToken()
    return self.token == Kind.OpenParenToken or self.token == Kind.LessThanToken
end

function Parser:parseSignatureMember(kind)
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    if kind == Kind.ConstructSignature then
        p:parseExpected(Kind.NewKeyword)
    end
    local typeParameters = p:parseTypeParameters()
    local parameters = p:parseParameters(ParseFlags.Type)
    local typeNode = p:parseReturnType(Kind.ColonToken, true --[[isType]])
    p:parseTypeMemberSemicolon()
    local result
    if kind == Kind.CallSignature then
        result = p.factory:NewCallSignatureDeclaration(typeParameters, parameters, typeNode)
    else
        result = p.factory:NewConstructSignatureDeclaration(typeParameters, parameters, typeNode)
    end
    p:finishNode(result, pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseTypeParameters()
    if self.token == Kind.LessThanToken then
        return self:parseBracketedList(PC.PCTypeParameters, Parser.parseTypeParameter, Kind.LessThanToken, Kind.GreaterThanToken)
    end
    return nil
end

function Parser:parseTypeParameter()
    local p = self
    local pos = p:nodePos()
    local modifiers = p:parseModifiersEx(false --[[allowDecorators]], true --[[permitConstAsModifier]], false --[[stopOnStartOfClassStaticBlock]])
    local name = p:parseIdentifier()
    local constraint = nil
    local expression = nil
    if p:parseOptional(Kind.ExtendsKeyword) then
        -- It's not uncommon for people to write improper constraints to a generic.  If the
        -- user writes a constraint that is an expression and not an actual type, then parse
        -- it out as an expression (so we can recover well), but report that a type is needed
        -- instead.
        if p:isStartOfType(false --[[inStartOfParameter]]) or not p:isStartOfExpression() then
            constraint = p:parseType()
        else
            -- It was not a type, and it looked like an expression.  Parse out an expression
            -- here so we recover well.  Note: it is important that we call parseUnaryExpression
            -- and not parseExpression here.  If the user has:
            --
            --      <T extends "">
            --
            -- We do *not* want to consume the `>` as we're consuming the expression for "".
            expression = p:parseUnaryExpressionOrHigher()
        end
    end
    local defaultType = nil
    if p:parseOptional(Kind.EqualsToken) then
        defaultType = p:parseType()
    end
    local result = p.factory:NewTypeParameterDeclaration(modifiers, name, constraint, expression, defaultType)
    return p:finishNode(result, pos)
end

function Parser:parseParameters(flags)
    -- FormalParameters [Yield,Await]: (modified)
    --      [empty]
    --      FormalParameterList[?Yield,Await]
    --
    -- FormalParameter[Yield,Await]: (modified)
    --      BindingElement[?Yield,Await]
    --
    -- BindingElement [Yield,Await]: (modified)
    --      SingleNameBinding[?Yield,?Await]
    --      BindingPattern[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
    --
    -- SingleNameBinding [Yield,Await]:
    --      BindingIdentifier[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
    if self:parseExpected(Kind.OpenParenToken) then
        local parameters = self:parseParametersWorker(flags, true --[[allowAmbiguity]])
        self:parseExpected(Kind.CloseParenToken)
        return parameters
    end
    return self:createMissingList()
end

function Parser:parseParametersWorker(flags, allowAmbiguity)
    local p = self
    -- FormalParameters [Yield,Await]: (modified)
    --      [empty]
    --      FormalParameterList[?Yield,Await]
    --
    -- FormalParameter[Yield,Await]: (modified)
    --      BindingElement[?Yield,Await]
    --
    -- BindingElement [Yield,Await]: (modified)
    --      SingleNameBinding[?Yield,?Await]
    --      BindingPattern[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
    --
    -- SingleNameBinding [Yield,Await]:
    --      BindingIdentifier[?Yield,?Await]Initializer [In, ?Yield,?Await] opt
    local inAwaitContext = p.contextFlags & NodeFlags.AwaitContext ~= 0
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.YieldContext, flags & ParseFlags.Yield ~= 0)
    p:setContextFlags(NodeFlags.AwaitContext, flags & ParseFlags.Await ~= 0)
    local parameters = p:parseDelimitedList(PC.PCParameters, function(p2)
        local parameter = p2:parseParameterEx(inAwaitContext, allowAmbiguity)
        if parameter ~= nil and flags & ParseFlags.Type == 0 then
            p2:checkJSSyntax(parameter)
        end
        return parameter
    end)
    p.contextFlags = saveContextFlags
    return parameters
end

function Parser:parseParameter()
    return self:parseParameterEx(false --[[inOuterAwaitContext]], true --[[allowAmbiguity]])
end

function Parser:parseParameterEx(inOuterAwaitContext, allowAmbiguity)
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    -- FormalParameter [Yield,Await]:
    --      BindingElement[?Yield,?Await]
    -- Decorators are parsed in the outer [Await] context, the rest of the parameter is parsed in the function's [Await] context.
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.AwaitContext, inOuterAwaitContext)
    local modifiers = p:parseModifiersEx(true --[[allowDecorators]], false --[[permitConstAsModifier]], false --[[stopOnStartOfClassStaticBlock]])
    p.contextFlags = saveContextFlags
    if p.token == Kind.ThisKeyword then
        local result = p.factory:NewParameterDeclaration(
            modifiers,
            nil, --[[dotDotDotToken]]
            p:createIdentifier(true --[[isIdentifier]]),
            nil, --[[questionToken]]
            p:parseTypeAnnotation(),
            nil --[[initializer]]
        )
        if modifiers ~= nil then
            p:parseErrorAtRange(modifiers.nodes[1].loc, diagnostics.Neither_decorators_nor_modifiers_may_be_applied_to_this_parameters)
        end
        p:withJSDoc(p:finishNode(result, pos), jsdoc)
        return result
    end
    local dotDotDotToken = p:parseOptionalToken(Kind.DotDotDotToken)
    if not allowAmbiguity and not p:isParameterNameStart() then
        return nil
    end
    local result = p.factory:NewParameterDeclaration(
        modifiers,
        dotDotDotToken,
        p:parseNameOfParameter(modifiers),
        p:parseOptionalToken(Kind.QuestionToken),
        p:parseTypeAnnotation(),
        p:parseInitializer()
    )
    p:withJSDoc(p:finishNode(result, pos), jsdoc)
    return result
end

function Parser:isParameterNameStart()
    -- Be permissive about await and yield by calling isBindingIdentifier instead of isIdentifier; disallowing
    -- them during a speculative parse leads to many more follow-on errors than allowing the function to parse then later
    -- complaining about the use of the keywords.
    return self:isBindingIdentifier() or self.token == Kind.OpenBracketToken or self.token == Kind.OpenBraceToken
end

function Parser:parseNameOfParameter(modifiers)
    -- FormalParameter [Yield,Await]:
    --      BindingElement[?Yield,?Await]
    local name = self:parseIdentifierOrPatternWithDiagnostic(diagnostics.Private_identifiers_cannot_be_used_as_parameters)
    if name.loc:Len() == 0 and modifiers == nil and ast.IsModifierKind(self.token) then
        -- in cases like
        -- 'use strict'
        -- function foo(static)
        -- isParameter('static') == true, because of isModifier('static')
        -- however 'static' is not a legal identifier in a strict mode.
        -- so result of this function will be Parameter (flags = 0, name = missing, type = undefined, initializer = undefined)
        -- and current token will not change => parsing of the enclosing parameter list will last till the end of time (or OOM)
        -- to avoid this we'll advance cursor to the next token.
        self:nextToken()
    end
    return name
end

function Parser:parseReturnType(returnToken, isType)
    if self:shouldParseReturnType(returnToken, isType) then
        return parser.doInContext(self, NodeFlags.DisallowConditionalTypesContext, false, Parser.parseTypeOrTypePredicate)
    end
    return nil
end

function Parser:shouldParseReturnType(returnToken, isType)
    if returnToken == Kind.EqualsGreaterThanToken then
        self:parseExpected(returnToken)
        return true
    elseif self:parseOptional(Kind.ColonToken) then
        return true
    elseif isType and self.token == Kind.EqualsGreaterThanToken then
        -- This is easy to get backward, especially in type contexts, so parse the type anyway
        self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(Kind.ColonToken))
        self:nextToken()
        return true
    end
    return false
end

function Parser:parseTypeOrTypePredicate()
    local p = self
    if p:isIdentifier() then
        local state = p:mark()
        local pos = p:nodePos()
        local id = p:parseIdentifier()
        if p.token == Kind.IsKeyword and not p:hasPrecedingLineBreak() then
            p:nextToken()
            return p:finishNode(p.factory:NewTypePredicateNode(nil --[[assertsModifier]], id, p:parseType()), pos)
        end
        p:rewind(state)
    end
    return p:parseType()
end

function Parser:parseTypeMemberSemicolon()
    -- We allow type members to be separated by commas or (possibly ASI) semicolons.
    -- First check if it was a comma.  If so, we're done with the member.
    if self:parseOptional(Kind.CommaToken) then
        return
    end
    -- Didn't have a comma.  We must have a (possible ASI) semicolon.
    self:parseSemicolon()
end

function Parser:parseAccessorDeclaration(pos, jsdoc, modifiers, kind, flags)
    local p = self
    local name = p:parsePropertyName()
    local typeParameters = p:parseTypeParameters()
    local parameters = p:parseParameters(ParseFlags.None)
    local returnType = p:parseReturnType(Kind.ColonToken, false --[[isType]])
    local body = p:parseFunctionBlockOrSemicolon(flags, nil --[[diagnosticMessage]])
    local result
    -- Keep track of `typeParameters` (for both) and `type` (for setters) if they were parsed those indicate grammar errors
    if kind == Kind.GetAccessor then
        result = p.factory:NewGetAccessorDeclaration(modifiers, name, typeParameters, parameters, returnType, nil --[[fullSignature]], body)
    else
        result = p.factory:NewSetAccessorDeclaration(modifiers, name, typeParameters, parameters, returnType, nil --[[fullSignature]], body)
    end
    p:withJSDoc(p:finishNode(result, pos), jsdoc)
    if flags & ParseFlags.Type == 0 then
        p:checkJSSyntax(result)
    end
    return result
end

function Parser:parsePropertyName()
    local saveHasAwaitIdentifier = self.statementHasAwaitIdentifier
    local prop = self:parsePropertyNameWorker(true --[[allowComputedPropertyNames]])
    self.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return prop
end

function Parser:parsePropertyNameWorker(allowComputedPropertyNames)
    local p = self
    if p.token == Kind.StringLiteral or p.token == Kind.NumericLiteral or p.token == Kind.BigIntLiteral then
        return p:parseLiteralExpression()
    end
    if allowComputedPropertyNames and p.token == Kind.OpenBracketToken then
        return p:parseComputedPropertyName()
    end
    if p.token == Kind.PrivateIdentifier then
        return p:parsePrivateIdentifier()
    end
    return p:parseIdentifierName()
end

function Parser:parseComputedPropertyName()
    -- PropertyName [Yield]:
    --      LiteralPropertyName
    --      ComputedPropertyName[?Yield]
    local pos = self:nodePos()
    self:parseExpected(Kind.OpenBracketToken)
    -- We parse any expression (including a comma expression). But the grammar
    -- says that only an assignment expression is allowed, so the grammar checker
    -- will error if it sees a comma expression.
    local expression = self:parseExpressionAllowIn()
    self:parseExpected(Kind.CloseBracketToken)
    return self:finishNode(self.factory:NewComputedPropertyName(expression), pos)
end

function Parser:parseFunctionBlockOrSemicolon(flags, diagnosticMessage)
    if self.token ~= Kind.OpenBraceToken then
        if flags & ParseFlags.Type ~= 0 then
            self:parseTypeMemberSemicolon()
            return nil
        end
        if self:canParseSemicolon() then
            self:parseSemicolon()
            return nil
        end
    end
    return self:parseFunctionBlock(flags, diagnosticMessage)
end

function Parser:parseFunctionBlock(flags, diagnosticMessage)
    local p = self
    local saveContextFlags = p.contextFlags
    local saveHasAwaitIdentifier = p.statementHasAwaitIdentifier
    p:setContextFlags(NodeFlags.YieldContext, flags & ParseFlags.Yield ~= 0)
    p:setContextFlags(NodeFlags.AwaitContext, flags & ParseFlags.Await ~= 0)
    -- We may be in a [Decorator] context when parsing a function expression or
    -- arrow function. The body of the function is not in [Decorator] context.
    p:setContextFlags(NodeFlags.DecoratorContext, false)
    local block = p:parseBlock(flags & ParseFlags.IgnoreMissingOpenBrace ~= 0, diagnosticMessage)
    p.contextFlags = saveContextFlags
    p.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return block
end

function Parser:isIndexSignature()
    return self.token == Kind.OpenBracketToken and self:lookAhead(Parser.nextIsUnambiguouslyIndexSignature)
end

function Parser:nextIsUnambiguouslyIndexSignature()
    local p = self
    -- The only allowed sequence is:
    --
    --   [id:
    --
    -- However, for error recovery, we also check the following cases:
    --
    --   [...
    --   [id,
    --   [id?,
    --   [id?:
    --   [id?]
    --   [public id
    --   [private id
    --   [protected id
    --   []
    --
    p:nextToken()
    if p.token == Kind.DotDotDotToken or p.token == Kind.CloseBracketToken then
        return true
    end
    if ast.IsModifierKind(p.token) then
        p:nextToken()
        if p:isIdentifier() then
            return true
        end
    elseif not p:isIdentifier() then
        return false
    else
        -- Skip the identifier
        p:nextToken()
    end
    -- A colon signifies a well formed indexer
    -- A comma should be a badly formed indexer because comma expressions are not allowed
    -- in computed properties.
    if p.token == Kind.ColonToken or p.token == Kind.CommaToken then
        return true
    end
    -- Question mark could be an indexer with an optional property,
    -- or it could be a conditional expression in a computed property.
    if p.token ~= Kind.QuestionToken then
        return false
    end
    -- If any of the following tokens are after the question mark, it cannot
    -- be a conditional expression, so treat it as an indexer.
    p:nextToken()
    return p.token == Kind.ColonToken or p.token == Kind.CommaToken or p.token == Kind.CloseBracketToken
end

function Parser:parseIndexSignatureDeclaration(pos, jsdoc, modifiers)
    local p = self
    local parameters = p:parseBracketedList(PC.PCParameters, Parser.parseParameter, Kind.OpenBracketToken, Kind.CloseBracketToken)
    local typeNode = p:parseTypeAnnotation()
    p:parseTypeMemberSemicolon()
    local result = p:finishNode(p.factory:NewIndexSignatureDeclaration(modifiers, parameters, typeNode), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parsePropertyOrMethodSignature(pos, jsdoc, modifiers)
    local p = self
    local name = p:parsePropertyName()
    local questionToken = p:parseOptionalToken(Kind.QuestionToken)
    local result
    if p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken then
        -- Method signatures don't exist in expression contexts.  So they have neither
        -- [Yield] nor [Await]
        local typeParameters = p:parseTypeParameters()
        local parameters = p:parseParameters(ParseFlags.Type)
        local returnType = p:parseReturnType(Kind.ColonToken, true --[[isType]])
        result = p.factory:NewMethodSignatureDeclaration(modifiers, name, questionToken, typeParameters, parameters, returnType)
    else
        local typeNode = p:parseTypeAnnotation()
        -- Although type literal properties cannot not have initializers, we attempt
        -- to parse an initializer so we can report in the checker that an interface
        -- property or type literal property cannot have an initializer.
        local initializer = nil
        if p.token == Kind.EqualsToken then
            initializer = p:parseInitializer()
        end
        result = p.factory:NewPropertySignatureDeclaration(modifiers, name, questionToken, typeNode, initializer)
    end
    p:parseTypeMemberSemicolon()
    p:withJSDoc(p:finishNode(result, pos), jsdoc)
    return result
end

function Parser:parseTypeLiteral()
    local pos = self:nodePos()
    local result = self:finishNode(self.factory:NewTypeLiteralNode(self:parseObjectTypeMembers()), pos)
    return result
end

function Parser:parseObjectTypeMembers()
    if self:parseExpected(Kind.OpenBraceToken) then
        local members = self:parseList(PC.PCTypeMembers, Parser.parseTypeMember)
        self:parseExpected(Kind.CloseBraceToken)
        return members
    end
    return self:createMissingList()
end

function Parser:parseTupleType()
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewTupleTypeNode(self:parseBracketedList(PC.PCTupleElementTypes, Parser.parseTupleElementNameOrTupleElementType, Kind.OpenBracketToken, Kind.CloseBracketToken)), pos)
end

function Parser:parseTupleElementNameOrTupleElementType()
    local p = self
    if p:lookAhead(Parser.scanStartOfNamedTupleElement) then
        local pos = p:nodePos()
        local jsdoc = p:jsdocScannerInfo()
        local dotDotDotToken = p:parseOptionalToken(Kind.DotDotDotToken)
        local name = p:parseIdentifierName()
        local questionToken = p:parseOptionalToken(Kind.QuestionToken)
        p:parseExpected(Kind.ColonToken)
        local typeNode = p:parseTupleElementType()
        local result = p:finishNode(p.factory:NewNamedTupleMember(dotDotDotToken, name, questionToken, typeNode), pos)
        p:withJSDoc(result, jsdoc)
        return result
    end
    return p:parseTupleElementType()
end

function Parser:scanStartOfNamedTupleElement()
    if self.token == Kind.DotDotDotToken then
        return parser.tokenIsIdentifierOrKeyword(self:nextToken()) and self:nextTokenIsColonOrQuestionColon()
    end
    return parser.tokenIsIdentifierOrKeyword(self.token) and self:nextTokenIsColonOrQuestionColon()
end

function Parser:nextTokenIsColonOrQuestionColon()
    return self:nextToken() == Kind.ColonToken or self.token == Kind.QuestionToken and self:nextToken() == Kind.ColonToken
end

function Parser:parseTupleElementType()
    local p = self
    local pos = p:nodePos()
    if p:parseOptional(Kind.DotDotDotToken) then
        return p:finishNode(p.factory:NewRestTypeNode(p:parseType()), pos)
    end
    local typeNode = p:parseType()
    if ast.IsJSDocNullableType(typeNode) and typeNode:Pos() == typeNode:Type():Pos() then
        local node = p.factory:NewOptionalTypeNode(typeNode:Type())
        node.flags = typeNode.flags
        node.loc = typeNode.loc
        typeNode:Type().parent = node
        return node
    end
    return typeNode
end

function Parser:parseParenthesizedType()
    local pos = self:nodePos()
    self:parseExpected(Kind.OpenParenToken)
    local typeNode = self:parseType()
    self:parseExpected(Kind.CloseParenToken)
    return self:finishNode(self.factory:NewParenthesizedTypeNode(typeNode), pos)
end

function Parser:parseAssertsTypePredicate()
    local p = self
    local pos = p:nodePos()
    local assertsModifier = p:parseExpectedToken(Kind.AssertsKeyword)
    local parameterName
    if p.token == Kind.ThisKeyword then
        parameterName = p:parseThisTypeNode()
    else
        parameterName = p:parseIdentifier()
    end
    local typeNode = nil
    if p:parseOptional(Kind.IsKeyword) then
        typeNode = p:parseType()
    end
    return p:finishNode(p.factory:NewTypePredicateNode(assertsModifier, parameterName, typeNode), pos)
end

function Parser:parseTemplateType()
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewTemplateLiteralTypeNode(self:parseTemplateHead(false --[[isTaggedTemplate]]), self:parseTemplateTypeSpans()), pos)
end

function Parser:parseTemplateHead(isTaggedTemplate)
    local p = self
    if not isTaggedTemplate and p.scanner:TokenFlags() & ast.TokenFlags.IsInvalid ~= 0 then
        p:reScanTemplateToken(false --[[isTaggedTemplate]])
    end
    local pos = p:nodePos()
    local result = p.factory:NewTemplateHead(p.scanner:TokenValue(), p:getTemplateLiteralRawText(2 --[[endLength]]), p.scanner:TokenFlags())
    p:nextToken()
    return p:finishNode(result, pos)
end

function Parser:getTemplateLiteralRawText(endLength)
    local tokenText = self.scanner:TokenText()
    if self.scanner:TokenFlags() & ast.TokenFlags.Unterminated ~= 0 then
        endLength = 0
    end
    return string.sub(tokenText, 2, #tokenText - endLength)
end

function Parser:parseTemplateTypeSpans()
    local pos = self:nodePos()
    local list = {}
    while true do
        local span = self:parseTemplateTypeSpan()
        list[#list + 1] = span
        if span:AsTemplateLiteralTypeSpan().literal.kind ~= Kind.TemplateMiddle then
            break
        end
    end
    return self:newNodeList(core.NewTextRange(pos, self:nodePos()), list)
end

function Parser:parseTemplateTypeSpan()
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewTemplateLiteralTypeSpan(self:parseType(), self:parseLiteralOfTemplateSpan(false --[[isTaggedTemplate]])), pos)
end

function Parser:parseLiteralOfTemplateSpan(isTaggedTemplate)
    if self.token == Kind.CloseBraceToken then
        self:reScanTemplateToken(isTaggedTemplate)
        return self:parseTemplateMiddleOrTail()
    end
    self:parseErrorAtCurrentToken(diagnostics.X_0_expected, scanner.TokenToString(Kind.CloseBraceToken))
    return self:finishNode(self.factory:NewTemplateTail("", "", ast.TokenFlags.None), self:nodePos())
end

function Parser:parseTemplateMiddleOrTail()
    local p = self
    local pos = p:nodePos()
    local result
    if p.token == Kind.TemplateMiddle then
        result = p.factory:NewTemplateMiddle(p.scanner:TokenValue(), p:getTemplateLiteralRawText(2 --[[endLength]]), p.scanner:TokenFlags())
    else
        result = p.factory:NewTemplateTail(p.scanner:TokenValue(), p:getTemplateLiteralRawText(1 --[[endLength]]), p.scanner:TokenFlags())
    end
    p:nextToken()
    return p:finishNode(result, pos)
end

function Parser:parseFunctionOrConstructorTypeToError(isInUnionType, parseConstituentType)
    local p = self
    -- the function type and constructor type shorthand notation
    -- are not allowed directly in unions and intersections, but we'll
    -- try to parse them gracefully and issue a helpful message.
    if p:isStartOfFunctionTypeOrConstructorType() then
        local typeNode = p:parseFunctionOrConstructorType()
        local diagnostic
        if typeNode.kind == Kind.FunctionType then
            diagnostic = isInUnionType and
                diagnostics.Function_type_notation_must_be_parenthesized_when_used_in_a_union_type or
                diagnostics.Function_type_notation_must_be_parenthesized_when_used_in_an_intersection_type
        else
            diagnostic = isInUnionType and
                diagnostics.Constructor_type_notation_must_be_parenthesized_when_used_in_a_union_type or
                diagnostics.Constructor_type_notation_must_be_parenthesized_when_used_in_an_intersection_type
        end
        p:parseErrorAtRange(typeNode.loc, diagnostic)
        return typeNode
    end
    return parseConstituentType(p)
end

function Parser:isStartOfFunctionTypeOrConstructorType()
    local p = self
    return p.token == Kind.LessThanToken or
        p.token == Kind.OpenParenToken and p:lookAhead(Parser.nextIsUnambiguouslyStartOfFunctionType) or
        p.token == Kind.NewKeyword or
        p.token == Kind.AbstractKeyword and p:lookAhead(Parser.nextTokenIsNewKeyword)
end

function Parser:parseFunctionOrConstructorType()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local modifiers = p:parseModifiersForConstructorType()
    local isConstructorType = p:parseOptional(Kind.NewKeyword)
    assert(modifiers == nil or isConstructorType, "Per isStartOfFunctionOrConstructorType, a function type cannot have modifiers.")
    local typeParameters = p:parseTypeParameters()
    local parameters = p:parseParameters(ParseFlags.Type)
    local returnType = p:parseReturnType(Kind.EqualsGreaterThanToken, false --[[isType]])
    local result
    if isConstructorType then
        result = p.factory:NewConstructorTypeNode(modifiers, typeParameters, parameters, returnType)
    else
        result = p.factory:NewFunctionTypeNode(typeParameters, parameters, returnType)
    end
    p:finishNode(result, pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseModifiersForConstructorType()
    local p = self
    if p.token == Kind.AbstractKeyword then
        local pos = p:nodePos()
        local modifier = p.factory:NewModifier(p.token)
        p:nextToken()
        p:finishNode(modifier, pos)
        return p:newModifierList(modifier.loc, { modifier })
    end
    return nil
end

function Parser:nextTokenIsNewKeyword()
    return self:nextToken() == Kind.NewKeyword
end

function Parser:nextIsUnambiguouslyStartOfFunctionType()
    local p = self
    p:nextToken()
    if p.token == Kind.CloseParenToken or p.token == Kind.DotDotDotToken then
        -- ( )
        -- ( ...
        return true
    end
    if p:skipParameterStart() then
        -- We successfully skipped modifiers (if any) and an identifier or binding pattern,
        -- now see if we have something that indicates a parameter declaration
        if p.token == Kind.ColonToken or p.token == Kind.CommaToken or p.token == Kind.QuestionToken or p.token == Kind.EqualsToken then
            -- ( xxx :
            -- ( xxx ,
            -- ( xxx ?
            -- ( xxx =
            return true
        end
        if p.token == Kind.CloseParenToken and p:nextToken() == Kind.EqualsGreaterThanToken then
            -- ( xxx ) =>
            return true
        end
    end
    return false
end

function Parser:skipParameterStart()
    local p = self
    if ast.IsModifierKind(p.token) then
        -- Skip modifiers
        p:parseModifiers()
    end
    p:parseOptional(Kind.DotDotDotToken)
    if p:isIdentifier() or p.token == Kind.ThisKeyword then
        p:nextToken()
        return true
    end
    if p.token == Kind.OpenBracketToken or p.token == Kind.OpenBraceToken then
        -- Return true if we can parse an array or object binding pattern with no errors
        local previousErrorCount = #p.diagnostics
        p:parseIdentifierOrPattern()
        return previousErrorCount == #p.diagnostics
    end
    return false
end

function Parser:parseModifiers()
    return self:parseModifiersEx(false, false, false)
end

function Parser:parseModifiersEx(allowDecorators, permitConstAsModifier, stopOnStartOfClassStaticBlock)
    local p = self
    local hasLeadingModifier = false
    local hasTrailingDecorator = false
    local hasTrailingModifier = false
    local hasStaticModifier = false
    -- Decorators should be contiguous in a list of modifiers but can potentially appear in two places (i.e., `[...leadingDecorators, ...leadingModifiers, ...trailingDecorators, ...trailingModifiers]`).
    -- The leading modifiers *should* only contain `export` and `default` when trailingDecorators are present, but we'll handle errors for any other leading modifiers in the checker.
    -- It is illegal to have both leadingDecorators and trailingDecorators, but we will report that as a grammar check in the checker.
    -- parse leading decorators
    local pos = p:nodePos()
    local list = {}
    while true do
        if allowDecorators and p.token == Kind.AtToken and not hasTrailingModifier then
            local decorator = p:parseDecorator()
            list[#list + 1] = decorator
            if hasLeadingModifier then
                hasTrailingDecorator = true
            end
        else
            local modifier = p:tryParseModifier(hasStaticModifier, permitConstAsModifier, stopOnStartOfClassStaticBlock)
            if modifier == nil then
                break
            end
            if modifier.kind == Kind.StaticKeyword then
                hasStaticModifier = true
            end
            list[#list + 1] = modifier
            if hasTrailingDecorator then
                hasTrailingModifier = true
            else
                hasLeadingModifier = true
            end
        end
    end
    if #list ~= 0 then
        return p:newModifierList(core.NewTextRange(pos, p:nodePos()), list)
    end
    return nil
end

function Parser:parseDecorator()
    local pos = self:nodePos()
    self:parseExpected(Kind.AtToken)
    local expression = parser.doInContext(self, NodeFlags.DecoratorContext, true, Parser.parseDecoratorExpression)
    return self:finishNode(self.factory:NewDecorator(expression), pos)
end

function Parser:parseDecoratorExpression()
    local p = self
    if p:inAwaitContext() and p.token == Kind.AwaitKeyword then
        -- `@await` is disallowed in an [Await] context, but can cause parsing to go off the rails
        -- This simply parses the missing identifier and moves on.
        local pos = p:nodePos()
        local awaitExpression = p:parseIdentifierWithDiagnostic(diagnostics.Expression_expected, nil)
        p:nextToken()
        local memberExpression = p:parseMemberExpressionRest(pos, awaitExpression, true --[[allowOptionalChain]])
        return p:parseCallExpressionRest(pos, memberExpression)
    end
    return p:parseLeftHandSideExpressionOrHigher()
end

function Parser:tryParseModifier(hasSeenStaticModifier, permitConstAsModifier, stopOnStartOfClassStaticBlock)
    local p = self
    local pos = p:nodePos()
    local kind = p.token
    if p.token == Kind.ConstKeyword and permitConstAsModifier then
        -- We need to ensure that any subsequent modifiers appear on the same line
        -- so that when 'const' is a standalone declaration, we don't issue an error.
        if not p:lookAhead(Parser.nextTokenIsOnSameLineAndCanFollowModifier) then
            return nil
        else
            p:nextToken()
        end
    elseif stopOnStartOfClassStaticBlock and p.token == Kind.StaticKeyword and p:lookAhead(Parser.nextTokenIsOpenBrace) then
        return nil
    elseif hasSeenStaticModifier and p.token == Kind.StaticKeyword then
        return nil
    else
        if not p:parseAnyContextualModifier() then
            return nil
        end
    end
    return p:finishNode(p.factory:NewModifier(kind), pos)
end

function Parser:parseContextualModifier(t)
    local state = self:mark()
    if self.token == t and self:nextTokenCanFollowModifier() then
        return true
    end
    self:rewind(state)
    return false
end

function Parser:parseAnyContextualModifier()
    local state = self:mark()
    if ast.IsModifierKind(self.token) and self:nextTokenCanFollowModifier() then
        return true
    end
    self:rewind(state)
    return false
end

function Parser:nextTokenCanFollowModifier()
    local p = self
    local t = p.token
    if t == Kind.ConstKeyword then
        -- 'const' is only a modifier if followed by 'enum'.
        return p:nextToken() == Kind.EnumKeyword
    elseif t == Kind.ExportKeyword then
        p:nextToken()
        if p.token == Kind.DefaultKeyword then
            return p:lookAhead(Parser.nextTokenCanFollowDefaultKeyword)
        end
        if p.token == Kind.TypeKeyword then
            return p:lookAhead(Parser.nextTokenCanFollowExportModifier)
        end
        return p:canFollowExportModifier()
    elseif t == Kind.DefaultKeyword then
        return p:nextTokenCanFollowDefaultKeyword()
    elseif t == Kind.StaticKeyword then
        p:nextToken()
        return p:canFollowModifier()
    elseif t == Kind.GetKeyword or t == Kind.SetKeyword then
        p:nextToken()
        return p:canFollowGetOrSetKeyword()
    else
        return p:nextTokenIsOnSameLineAndCanFollowModifier()
    end
end

function Parser:nextTokenCanFollowDefaultKeyword()
    local t = self:nextToken()
    if t == Kind.ClassKeyword or t == Kind.FunctionKeyword or t == Kind.InterfaceKeyword or t == Kind.AtToken then
        return true
    elseif t == Kind.AbstractKeyword then
        return self:lookAhead(Parser.nextTokenIsClassKeywordOnSameLine)
    elseif t == Kind.AsyncKeyword then
        return self:lookAhead(Parser.nextTokenIsFunctionKeywordOnSameLine)
    end
    return false
end

function Parser:nextTokenIsIdentifierOrKeyword()
    return parser.tokenIsIdentifierOrKeyword(self:nextToken())
end

function Parser:nextTokenIsIdentifierOrKeywordOrGreaterThan()
    return parser.tokenIsIdentifierOrKeywordOrGreaterThan(self:nextToken())
end

function Parser:nextTokenIsIdentifierOrKeywordOnSameLine()
    return self:nextTokenIsIdentifierOrKeyword() and not self:hasPrecedingLineBreak()
end

function Parser:nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine()
    return (self:nextTokenIsIdentifierOrKeyword() or self.token == Kind.NumericLiteral or self.token == Kind.BigIntLiteral or self.token == Kind.StringLiteral) and not self:hasPrecedingLineBreak()
end

function Parser:nextTokenIsClassKeywordOnSameLine()
    return self:nextToken() == Kind.ClassKeyword and not self:hasPrecedingLineBreak()
end

function Parser:nextTokenIsFunctionKeywordOnSameLine()
    return self:nextToken() == Kind.FunctionKeyword and not self:hasPrecedingLineBreak()
end

function Parser:nextTokenCanFollowExportModifier()
    self:nextToken()
    return self:canFollowExportModifier()
end

function Parser:canFollowExportModifier()
    local t = self.token
    return t == Kind.AtToken or t ~= Kind.AsteriskToken and t ~= Kind.AsKeyword and t ~= Kind.OpenBraceToken and self:canFollowModifier()
end

function Parser:canFollowModifier()
    local t = self.token
    return t == Kind.OpenBracketToken or t == Kind.OpenBraceToken or t == Kind.AsteriskToken or t == Kind.DotDotDotToken or self:isLiteralPropertyName()
end

function Parser:canFollowGetOrSetKeyword()
    return self.token == Kind.OpenBracketToken or self:isLiteralPropertyName()
end

function Parser:nextTokenIsOnSameLineAndCanFollowModifier()
    self:nextToken()
    if self:hasPrecedingLineBreak() then
        return false
    end
    return self:canFollowModifier()
end

function Parser:nextTokenIsOpenBrace()
    return self:nextToken() == Kind.OpenBraceToken
end

function Parser:parseExpression()
    local p = self
    -- Expression[in]:
    --      AssignmentExpression[in]
    --      Expression[in] , AssignmentExpression[in]

    -- clear the decorator context when parsing Expression, as it should be unambiguous when parsing a decorator
    local saveContextFlags = p.contextFlags
    p.contextFlags = p.contextFlags & ~NodeFlags.DecoratorContext
    local pos = p:nodePos()
    local expr = p:parseAssignmentExpressionOrHigher()
    while true do
        local operatorToken = p:parseOptionalToken(Kind.CommaToken)
        if operatorToken == nil then
            break
        end
        expr = p:makeBinaryExpression(expr, operatorToken, p:parseAssignmentExpressionOrHigher(), pos)
    end
    p.contextFlags = saveContextFlags
    return expr
end

function Parser:parseExpressionAllowIn()
    return parser.doInContext(self, NodeFlags.DisallowInContext, false, Parser.parseExpression)
end

function Parser:parseAssignmentExpressionOrHigher()
    return self:parseAssignmentExpressionOrHigherWorker(true --[[allowReturnTypeInArrowFunction]])
end

function Parser:parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction)
    local p = self
    --  AssignmentExpression[in,yield]:
    --      1) ConditionalExpression[?in,?yield]
    --      2) LeftHandSideExpression = AssignmentExpression[?in,?yield]
    --      3) LeftHandSideExpression AssignmentOperator AssignmentExpression[?in,?yield]
    --      4) ArrowFunctionExpression[?in,?yield]
    --      5) AsyncArrowFunctionExpression[in,yield,await]
    --      6) [+Yield] YieldExpression[?In]
    --
    -- Note: for ease of implementation we treat productions '2' and '3' as the same thing.
    -- (i.e. they're both BinaryExpressions with an assignment operator in it).
    -- First, do the simple check if we have a YieldExpression (production '6').
    if p:isYieldExpression() then
        return p:parseYieldExpression()
    end
    -- Then, check if we have an arrow function (production '4' and '5') that starts with a parenthesized
    -- parameter list or is an async arrow function.
    -- AsyncArrowFunctionExpression:
    --      1) async[no LineTerminator here]AsyncArrowBindingIdentifier[?Yield][no LineTerminator here]=>AsyncConciseBody[?In]
    --      2) CoverCallExpressionAndAsyncArrowHead[?Yield, ?Await][no LineTerminator here]=>AsyncConciseBody[?In]
    -- Production (1) of AsyncArrowFunctionExpression is parsed in "tryParseAsyncSimpleArrowFunctionExpression".
    -- And production (2) is parsed in "tryParseParenthesizedArrowFunctionExpression".
    --
    -- If we do successfully parse arrow-function, we must *not* recurse for productions 1, 2 or 3. An ArrowFunction is
    -- not a LeftHandSideExpression, nor does it start a ConditionalExpression.  So we are done
    -- with AssignmentExpression if we see one.
    local arrowExpression = p:tryParseParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction)
    if arrowExpression ~= nil then
        return arrowExpression
    end
    arrowExpression = p:tryParseAsyncSimpleArrowFunctionExpression(allowReturnTypeInArrowFunction)
    if arrowExpression ~= nil then
        return arrowExpression
    end
    -- Now try to see if we're in production '1', '2' or '3'.  A conditional expression can
    -- start with a LogicalOrExpression, while the assignment productions can only start with
    -- LeftHandSideExpressions.
    --
    -- So, first, we try to just parse out a BinaryExpression.  If we get something that is a
    -- LeftHandSide or higher, then we can try to parse out the assignment expression part.
    -- Otherwise, we try to parse out the conditional expression bit.  We want to allow any
    -- binary expression here, so we pass in the 'lowest' precedence here so that it matches
    -- and consumes anything.
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local expr = p:parseBinaryExpressionOrHigher(ast.OperatorPrecedence.Lowest)
    -- To avoid a look-ahead, we did not handle the case of an arrow function with a single un-parenthesized
    -- parameter ('x => ...') above. We handle it here by checking if the parsed expression was a single
    -- identifier and the current token is an arrow.
    if expr.kind == Kind.Identifier and p.token == Kind.EqualsGreaterThanToken then
        return p:parseSimpleArrowFunctionExpression(pos, expr, allowReturnTypeInArrowFunction, jsdoc, nil --[[asyncModifier]])
    end
    -- Now see if we might be in cases '2' or '3'.
    -- If the expression was a LHS expression, and we have an assignment operator, then
    -- we're in '2' or '3'. Consume the assignment and return.
    --
    -- Note: we call reScanGreaterToken so that we get an appropriately merged token
    -- for cases like `> > =` becoming `>>=`
    if ast.IsLeftHandSideExpression(expr) and ast.IsAssignmentOperator(p:reScanGreaterThanToken()) then
        return p:makeBinaryExpression(expr, p:parseTokenNode(), p:parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction), pos)
    end
    -- It wasn't an assignment or a lambda.  This is a conditional expression:
    return p:parseConditionalExpressionRest(expr, pos, allowReturnTypeInArrowFunction)
end

function Parser:isYieldExpression()
    if self.token == Kind.YieldKeyword then
        -- If we have a 'yield' keyword, and this is a context where yield expressions are
        -- allowed, then definitely parse out a yield expression.
        if self:inYieldContext() then
            return true
        end

        -- We're in a context where 'yield expr' is not allowed.  However, if we can
        -- definitely tell that the user was trying to parse a 'yield expr' and not
        -- just a normal expr that start with a 'yield' identifier, then parse out
        -- a 'yield expr'.  We can then report an error later that they are only
        -- allowed in generator expressions.
        --
        -- for example, if we see 'yield(foo)', then we'll have to treat that as an
        -- invocation expression of something called 'yield'.  However, if we have
        -- 'yield foo' then that is not legal as a normal expression, so we can
        -- definitely recognize this as a yield expression.
        --
        -- for now we just check if the next token is an identifier.  More heuristics
        -- can be added here later as necessary.  We just need to make sure that we
        -- don't accidentally consume something legal.
        return self:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine)
    end
    return false
end

function Parser:parseYieldExpression()
    local p = self
    local pos = p:nodePos()
    -- YieldExpression[In] :
    --      yield
    --      yield [no LineTerminator here] [Lexical goal InputElementRegExp]AssignmentExpression[?In, Yield]
    --      yield [no LineTerminator here] * [Lexical goal InputElementRegExp]AssignmentExpression[?In, Yield]
    p:nextToken()
    local result
    if not p:hasPrecedingLineBreak() and (p.token == Kind.AsteriskToken or p:isStartOfExpression()) then
        result = p.factory:NewYieldExpression(p:parseOptionalToken(Kind.AsteriskToken), p:parseAssignmentExpressionOrHigher())
    else
        -- if the next token is not on the same line as yield.  or we don't have an '*' or
        -- the start of an expression, then this is just a simple "yield" expression.
        result = p.factory:NewYieldExpression(nil --[[asteriskToken]], nil --[[expression]])
    end
    return p:finishNode(result, pos)
end

function Parser:isParenthesizedArrowFunctionExpression()
    local p = self
    if p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken or p.token == Kind.AsyncKeyword then
        local state = p:mark()
        local result = p:nextIsParenthesizedArrowFunctionExpression()
        p:rewind(state)
        return result
    end
    if p.token == Kind.EqualsGreaterThanToken then
        -- ERROR RECOVERY TWEAK:
        -- If we see a standalone => try to parse it as an arrow function expression as that's
        -- likely what the user intended to write.
        return Tristate.TSTrue
    end
    -- Definitely not a parenthesized arrow function.
    return Tristate.TSFalse
end

function Parser:nextIsParenthesizedArrowFunctionExpression()
    local p = self
    if p.token == Kind.AsyncKeyword then
        p:nextToken()
        if p:hasPrecedingLineBreak() then
            return Tristate.TSFalse
        end
        if p.token ~= Kind.OpenParenToken and p.token ~= Kind.LessThanToken then
            return Tristate.TSFalse
        end
    end
    local first = p.token
    local second = p:nextToken()
    if first == Kind.OpenParenToken then
        if second == Kind.CloseParenToken then
            -- Simple cases: "() =>", "(): ", and "() {".
            -- This is an arrow function with no parameters.
            -- The last one is not actually an arrow function,
            -- but this is probably what the user intended.
            local third = p:nextToken()
            if third == Kind.EqualsGreaterThanToken or third == Kind.ColonToken or third == Kind.OpenBraceToken then
                return Tristate.TSTrue
            end
            return Tristate.TSFalse
        end
        -- If encounter "([" or "({", this could be the start of a binding pattern.
        -- Examples:
        --      ([ x ]) => { }
        --      ({ x }) => { }
        --      ([ x ])
        --      ({ x })
        if second == Kind.OpenBracketToken or second == Kind.OpenBraceToken then
            return Tristate.TSUnknown
        end
        -- Simple case: "(..."
        -- This is an arrow function with a rest parameter.
        if second == Kind.DotDotDotToken then
            return Tristate.TSTrue
        end
        -- Check for "(xxx yyy", where xxx is a modifier and yyy is an identifier. This
        -- isn't actually allowed, but we want to treat it as a lambda so we can provide
        -- a good error message.
        if ast.IsModifierKind(second) and second ~= Kind.AsyncKeyword and p:lookAhead(Parser.nextTokenIsIdentifier) then
            if p:nextToken() == Kind.AsKeyword then
                -- https://github.com/microsoft/TypeScript/issues/44466
                return Tristate.TSFalse
            end
            return Tristate.TSTrue
        end
        -- If we had "(" followed by something that's not an identifier,
        -- then this definitely doesn't look like a lambda.  "this" is not
        -- valid, but we want to parse it and then give a semantic error.
        if not p:isIdentifier() and second ~= Kind.ThisKeyword then
            return Tristate.TSFalse
        end
        local t = p:nextToken()
        if t == Kind.ColonToken then
            -- If we have something like "(a:", then we must have a
            -- type-annotated parameter in an arrow function expression.
            return Tristate.TSTrue
        elseif t == Kind.QuestionToken then
            p:nextToken()
            -- If we have "(a?:" or "(a?," or "(a?=" or "(a?)" then it is definitely a lambda.
            if p.token == Kind.ColonToken or p.token == Kind.CommaToken or p.token == Kind.EqualsToken or p.token == Kind.CloseParenToken then
                return Tristate.TSTrue
            end
            -- Otherwise it is definitely not a lambda.
            return Tristate.TSFalse
        elseif t == Kind.CommaToken or t == Kind.EqualsToken or t == Kind.CloseParenToken then
            -- If we have "(a," or "(a=" or "(a)" this *could* be an arrow function
            return Tristate.TSUnknown
        end
        -- It is definitely not an arrow function
        return Tristate.TSFalse
    else
        assert(first == Kind.LessThanToken)
        -- If we have "<" not followed by an identifier,
        -- then this definitely is not an arrow function.
        if not p:isIdentifier() and p.token ~= Kind.ConstKeyword then
            return Tristate.TSFalse
        end
        -- JSX overrides
        if p.languageVariant == core.LanguageVariant.JSX then
            local isArrowFunctionInJsx = p:lookAhead(function(p2)
                p2:parseOptional(Kind.ConstKeyword)
                local third = p2:nextToken()
                if third == Kind.ExtendsKeyword then
                    local fourth = p2:nextToken()
                    if fourth == Kind.EqualsToken or fourth == Kind.GreaterThanToken or fourth == Kind.SlashToken then
                        return false
                    end
                    return true
                elseif third == Kind.CommaToken or third == Kind.EqualsToken then
                    return true
                end
                return false
            end)
            if isArrowFunctionInJsx then
                return Tristate.TSTrue
            end
            return Tristate.TSFalse
        end
        -- This *could* be a parenthesized arrow function.
        return Tristate.TSUnknown
    end
end

function Parser:tryParseParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction)
    local p = self
    local tristate = p:isParenthesizedArrowFunctionExpression()
    if tristate == Tristate.TSFalse then
        -- It's definitely not a parenthesized arrow function expression.
        return nil
    end
    -- If we definitely have an arrow function, then we can just parse one, not requiring a
    -- following => or { token. Otherwise, we *might* have an arrow function.  Try to parse
    -- it out, but don't allow any ambiguity, and return 'undefined' if this could be an
    -- expression instead.
    if tristate == Tristate.TSTrue then
        return p:parseParenthesizedArrowFunctionExpression(true --[[allowAmbiguity]], true --[[allowReturnTypeInArrowFunction]])
    end
    local state = p:mark()
    local result = p:parsePossibleParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction)
    if result == nil then
        p:rewind(state)
    end
    return result
end

function Parser:parseParenthesizedArrowFunctionExpression(allowAmbiguity, allowReturnTypeInArrowFunction)
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local modifiers = p:parseModifiersForArrowFunction()
    local isAsync = parser.modifierListHasAsync(modifiers)
    local signatureFlags = isAsync and ParseFlags.Await or ParseFlags.None
    -- Arrow functions are never generators.
    --
    -- If we're speculatively parsing a signature for a parenthesized arrow function, then
    -- we have to have a complete parameter list.  Otherwise we might see something like
    -- a => (b => c)
    -- And think that "(b =>" was actually a parenthesized arrow function with a missing
    -- close paren.
    local typeParameters = p:parseTypeParameters()
    local parameters
    if not p:parseExpected(Kind.OpenParenToken) then
        if not allowAmbiguity then
            return nil
        end
        parameters = p:createMissingList()
    else
        if not allowAmbiguity then
            local maybeParameters = p:parseParametersWorker(signatureFlags, allowAmbiguity)
            if maybeParameters == nil then
                return nil
            end
            parameters = maybeParameters
        else
            parameters = p:parseParametersWorker(signatureFlags, allowAmbiguity)
        end
        if not p:parseExpected(Kind.CloseParenToken) and not allowAmbiguity then
            return nil
        end
    end
    local hasReturnColon = p.token == Kind.ColonToken
    local returnType = p:parseReturnType(Kind.ColonToken, false --[[isType]])
    if returnType ~= nil and not allowAmbiguity and parser.typeHasArrowFunctionBlockingParseError(returnType) then
        return nil
    end
    -- Parsing a signature isn't enough.
    -- Parenthesized arrow signatures often look like other valid expressions.
    -- For instance:
    --  - "(x = 10)" is an assignment expression parsed as a signature with a default parameter value.
    --  - "(x,y)" is a comma expression parsed as a signature with two parameters.
    --  - "a ? (b): c" will have "(b):" parsed as a signature with a return type annotation.
    --  - "a ? (b): function() {}" will too, since function() is a valid JSDoc function type.
    --  - "a ? (b): (function() {})" as well, but inside of a parenthesized type with an arbitrary amount of nesting.
    --
    -- So we need just a bit of lookahead to ensure that it can only be a signature.
    local unwrappedType = returnType
    while unwrappedType ~= nil and unwrappedType.kind == Kind.ParenthesizedType do
        unwrappedType = unwrappedType:Type() -- Skip parens if need be
    end
    if not allowAmbiguity and p.token ~= Kind.EqualsGreaterThanToken and p.token ~= Kind.OpenBraceToken then
        -- Returning undefined here will cause our caller to rewind to where we started from.
        return nil
    end
    -- If we have an arrow, then try to parse the body. Even if not, try to parse if we
    -- have an opening brace, just in case we're in an error state.
    local lastToken = p.token
    local equalsGreaterThanToken = p:parseExpectedToken(Kind.EqualsGreaterThanToken)
    local body
    if lastToken == Kind.EqualsGreaterThanToken or lastToken == Kind.OpenBraceToken then
        body = p:parseArrowFunctionExpressionBody(isAsync, allowReturnTypeInArrowFunction)
    else
        body = p:parseIdentifier()
    end
    -- Given:
    --     x ? y => ({ y }) : z => ({ z })
    -- We try to parse the body of the first arrow function by looking at:
    --     ({ y }) : z => ({ z })
    -- This is a valid arrow function with "z" as the return type.
    --
    -- But, if we're in the true side of a conditional expression, this colon
    -- terminates the expression, so we cannot allow a return type if we aren't
    -- certain whether or not the preceding text was parsed as a parameter list.
    --
    -- For example,
    --     a() ? (b: number, c?: string): void => d() : e
    -- is determined by isParenthesizedArrowFunctionExpression to unambiguously
    -- be an arrow expression, so we allow a return type.
    if not allowReturnTypeInArrowFunction and hasReturnColon then
        -- However, if the arrow function we were able to parse is followed by another colon
        -- as in:
        --     a ? (x): string => x : null
        -- Then allow the arrow function, and treat the second colon as terminating
        -- the conditional expression. It's okay to do this because this code would
        -- be a syntax error in JavaScript (as the second colon shouldn't be there).
        if p.token ~= Kind.ColonToken then
            return nil
        end
    end
    local result = p:finishNode(p.factory:NewArrowFunction(modifiers, typeParameters, parameters, returnType, nil --[[fullSignature]], equalsGreaterThanToken, body), pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseModifiersForArrowFunction()
    if self.token == Kind.AsyncKeyword then
        local pos = self:nodePos()
        self:nextToken()
        local modifier = self:finishNode(self.factory:NewModifier(Kind.AsyncKeyword), pos)
        return self:newModifierList(modifier.loc, { modifier })
    end
    return nil
end

-- If true, we should abort parsing an error function.
function parser.typeHasArrowFunctionBlockingParseError(node)
    local k = node.kind
    if k == Kind.TypeReference then
        return ast.NodeIsMissing(node:AsTypeReferenceNode().typeName)
    elseif k == Kind.FunctionType or k == Kind.ConstructorType then
        return parser.isMissingNodeList(node.parameters) or parser.typeHasArrowFunctionBlockingParseError(node:Type())
    elseif k == Kind.ParenthesizedType then
        return parser.typeHasArrowFunctionBlockingParseError(node:Type())
    end
    return false
end

function Parser:parseArrowFunctionExpressionBody(isAsync, allowReturnTypeInArrowFunction)
    local p = self
    if p.token == Kind.OpenBraceToken then
        return p:parseFunctionBlock(isAsync and ParseFlags.Await or ParseFlags.None, nil --[[diagnosticMessage]])
    end
    if p.token ~= Kind.SemicolonToken and p.token ~= Kind.FunctionKeyword and p.token ~= Kind.ClassKeyword and p:isStartOfStatement() and not p:isStartOfExpressionStatement() then
        -- Check if we got a plain statement (i.e. no expression-statements, no function/class expressions/declarations)
        --
        -- Here we try to recover from a potential error situation in the case where the
        -- user meant to supply a block. For example, if the user wrote:
        --
        --  a =>
        --      let v = 0;
        --  }
        --
        -- they may be missing an open brace.  Check to see if that's the case so we can
        -- try to recover better.  If we don't do this, then the next close curly we see may end
        -- up preemptively closing the containing construct.
        --
        -- Note: even when 'IgnoreMissingOpenBrace' is passed, parseBody will still error.
        return p:parseFunctionBlock(ParseFlags.IgnoreMissingOpenBrace | (isAsync and ParseFlags.Await or ParseFlags.None), nil --[[diagnosticMessage]])
    end
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.AwaitContext, isAsync)
    p:setContextFlags(NodeFlags.YieldContext, false)
    local node = p:parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction)
    p.contextFlags = saveContextFlags
    return node
end

function Parser:isStartOfExpressionStatement()
    -- As per the grammar, none of '{' or 'function' or 'class' can start an expression statement.
    local t = self.token
    return t ~= Kind.OpenBraceToken and t ~= Kind.FunctionKeyword and t ~= Kind.ClassKeyword and t ~= Kind.AtToken and self:isStartOfExpression()
end

function Parser:parsePossibleParenthesizedArrowFunctionExpression(allowReturnTypeInArrowFunction)
    local tokenPos = self.scanner:TokenStart()
    if self.notParenthesizedArrow[tokenPos] then
        return nil
    end
    local result = self:parseParenthesizedArrowFunctionExpression(false --[[allowAmbiguity]], allowReturnTypeInArrowFunction)
    if result == nil then
        self.notParenthesizedArrow[tokenPos] = true
    end
    return result
end

function Parser:tryParseAsyncSimpleArrowFunctionExpression(allowReturnTypeInArrowFunction)
    local p = self
    -- We do a check here so that we won't be doing unnecessarily call to "lookAhead"
    if p.token == Kind.AsyncKeyword and p:lookAhead(Parser.nextIsUnParenthesizedAsyncArrowFunction) then
        local pos = p:nodePos()
        local jsdoc = p:jsdocScannerInfo()
        local asyncModifier = p:parseModifiersForArrowFunction()
        local expr = p:parseBinaryExpressionOrHigher(ast.OperatorPrecedence.Lowest)
        return p:parseSimpleArrowFunctionExpression(pos, expr, allowReturnTypeInArrowFunction, jsdoc, asyncModifier)
    end
    return nil
end

function Parser:nextIsUnParenthesizedAsyncArrowFunction()
    local p = self
    -- AsyncArrowFunctionExpression:
    --      1) async[no LineTerminator here]AsyncArrowBindingIdentifier[?Yield][no LineTerminator here]=>AsyncConciseBody[?In]
    --      2) CoverCallExpressionAndAsyncArrowHead[?Yield, ?Await][no LineTerminator here]=>AsyncConciseBody[?In]
    if p.token == Kind.AsyncKeyword then
        p:nextToken()
        -- If the "async" is followed by "=>" token then it is not a beginning of an async arrow-function
        -- but instead a simple arrow-function which will be parsed inside "parseAssignmentExpressionOrHigher"
        if p:hasPrecedingLineBreak() or p.token == Kind.EqualsGreaterThanToken then
            return false
        end
        -- Check for un-parenthesized AsyncArrowFunction
        if not p:isIdentifier() then
            return false
        end
        p:nextTokenWithoutCheck()
        return not p:hasPrecedingLineBreak() and p.token == Kind.EqualsGreaterThanToken
    end
    return false
end

function Parser:parseSimpleArrowFunctionExpression(pos, identifier, allowReturnTypeInArrowFunction, jsdoc, asyncModifier)
    local p = self
    assert(p.token == Kind.EqualsGreaterThanToken, "parseSimpleArrowFunctionExpression should only have been called if we had a =>")
    local parameter = p:finishNode(p.factory:NewParameterDeclaration(nil --[[modifiers]], nil --[[dotDotDotToken]], identifier, nil --[[questionToken]], nil --[[typeNode]], nil --[[initializer]]), identifier:Pos())
    local parameters = p:newNodeList(parameter.loc, { parameter })
    local equalsGreaterThanToken = p:parseExpectedToken(Kind.EqualsGreaterThanToken)
    local body = p:parseArrowFunctionExpressionBody(asyncModifier ~= nil --[[isAsync]], allowReturnTypeInArrowFunction)
    local result = p:finishNode(p.factory:NewArrowFunction(asyncModifier, nil --[[typeParameters]], parameters, nil --[[returnType]], nil --[[fullSignature]], equalsGreaterThanToken, body), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseConditionalExpressionRest(leftOperand, pos, allowReturnTypeInArrowFunction)
    local p = self
    -- Note: we are passed in an expression which was produced from parseBinaryExpressionOrHigher.
    local questionToken = p:parseOptionalToken(Kind.QuestionToken)
    if questionToken == nil then
        return leftOperand
    end
    -- Note: we explicitly 'allowIn' in the whenTrue part of the condition expression, and
    -- we do not that for the 'whenFalse' part.
    local saveContextFlags = p.contextFlags
    p:setContextFlags(NodeFlags.DisallowInContext, false)
    local trueExpression = p:parseAssignmentExpressionOrHigherWorker(false --[[allowReturnTypeInArrowFunction]])
    p.contextFlags = saveContextFlags
    local colonToken = p:parseExpectedToken(Kind.ColonToken)
    local falseExpression
    if ast.NodeIsPresent(colonToken) then
        falseExpression = p:parseAssignmentExpressionOrHigherWorker(allowReturnTypeInArrowFunction)
    else
        falseExpression = p:createMissingIdentifier()
    end
    return p:finishNode(p.factory:NewConditionalExpression(leftOperand, questionToken, trueExpression, colonToken, falseExpression), pos)
end

function Parser:parseBinaryExpressionOrHigher(precedence)
    local pos = self:nodePos()
    local leftOperand = self:parseUnaryExpressionOrHigher()
    return self:parseBinaryExpressionRest(precedence, leftOperand, pos)
end

-- shouldConsumeBinaryOperator reports whether an operator binds before the operator represented by currentPrecedence.
-- At equal precedence, only the right-associative exponentiation operator binds first.
function parser.shouldConsumeBinaryOperator(operator, operatorPrecedence, currentPrecedence)
    if operatorPrecedence > currentPrecedence then
        return true
    end
    return operatorPrecedence == currentPrecedence and operator == Kind.AsteriskAsteriskToken
end

function Parser:parseBinaryExpressionRest(precedence, leftOperand, pos)
    local p = self
    local lastOperand = leftOperand
    while true do
        -- We either have a binary operator here, or we're finished.  We call
        -- reScanGreaterToken so that we merge token sequences like > and = into >=
        local operator = p:reScanGreaterThanToken()
        local newPrecedence = ast.GetBinaryOperatorPrecedence(operator)
        -- Check the precedence to see if we should "take" this operator
        -- - For left associative operator (all operator but **), consume the operator,
        --   recursively call the function below, and parse binaryExpression as a rightOperand
        --   of the caller if the new precedence of the operator is greater then or equal to the current precedence.
        --   For example:
        --      a - b - c;
        --            ^token; leftOperand = b. Return b to the caller as a rightOperand
        --      a * b - c
        --            ^token; leftOperand = b. Return b to the caller as a rightOperand
        --      a - b * c;
        --            ^token; leftOperand = b. Return b * c to the caller as a rightOperand
        -- - For right associative operator (**), consume the operator, recursively call the function
        --   and parse binaryExpression as a rightOperand of the caller if the new precedence of
        --   the operator is strictly grater than the current precedence
        --   For example:
        --      a ** b ** c;
        --             ^^token; leftOperand = b. Return b ** c to the caller as a rightOperand
        --      a - b ** c;
        --            ^^token; leftOperand = b. Return b ** c to the caller as a rightOperand
        --      a ** b - c
        --             ^token; leftOperand = b. Return b to the caller as a rightOperand
        if not parser.shouldConsumeBinaryOperator(operator, newPrecedence, precedence) then
            break
        end
        if operator == Kind.InKeyword and p:inDisallowInContext() then
            break
        end
        if operator == Kind.AsKeyword or operator == Kind.SatisfiesKeyword then
            -- Make sure we *do* perform ASI for constructs like this:
            --    var x = foo
            --    as (Bar)
            -- This should be parsed as an initialized variable, followed
            -- by a function call to 'as' with the argument 'Bar'
            if p:hasPrecedingLineBreak() then
                break
            else
                p:nextToken()
                -- When we have 'a ## b as SomeType $$ c' or 'a ## b satisfies SomeType $$ c', where ## and $$
                -- are binary operators, we want to stop parsing when $$ would bind before ## after erasing the
                -- assertion. See https://github.com/microsoft/TypeScript/issues/63527.
                local lastPrecedence = ast.OperatorPrecedence.Highest
                if ast.IsBinaryExpression(lastOperand) then
                    lastPrecedence = ast.GetBinaryOperatorPrecedence(lastOperand:AsBinaryExpression().operatorToken.kind)
                end
                if operator == Kind.SatisfiesKeyword then
                    leftOperand = p:makeSatisfiesExpression(leftOperand, p:parseType())
                else
                    leftOperand = p:makeAsExpression(leftOperand, p:parseType())
                end
                -- Stop if the next operator would bind before the last operator when the assertion is erased.
                local nextOperator = p:reScanGreaterThanToken()
                local nextPrecedence = ast.GetBinaryOperatorPrecedence(nextOperator)
                if parser.shouldConsumeBinaryOperator(nextOperator, nextPrecedence, lastPrecedence) then
                    break
                end
            end
        else
            leftOperand = p:makeBinaryExpression(leftOperand, p:parseTokenNode(), p:parseBinaryExpressionOrHigher(newPrecedence), pos)
            lastOperand = leftOperand
        end
    end
    return leftOperand
end

function Parser:makeSatisfiesExpression(expression, typeNode)
    return self:checkJSSyntax(self:finishNode(self.factory:NewSatisfiesExpression(expression, typeNode), expression:Pos()))
end

function Parser:makeAsExpression(left, right)
    return self:checkJSSyntax(self:finishNode(self.factory:NewAsExpression(left, right), left:Pos()))
end

function Parser:makeBinaryExpression(left, operatorToken, right, pos)
    return self:finishNode(self.factory:NewBinaryExpression(nil --[[modifiers]], left, nil --[[typeNode]], operatorToken, right), pos)
end

function Parser:parseUnaryExpressionOrHigher()
    local p = self
    -- ES7 UpdateExpression:
    --      1) LeftHandSideExpression[?Yield]
    --      2) LeftHandSideExpression[?Yield][no LineTerminator here]++
    --      3) LeftHandSideExpression[?Yield][no LineTerminator here]--
    --      4) ++UnaryExpression[?Yield]
    --      5) --UnaryExpression[?Yield]
    if p:isUpdateExpression() then
        local pos = p:nodePos()
        local updateExpression = p:parseUpdateExpression()
        if p.token == Kind.AsteriskAsteriskToken then
            return p:parseBinaryExpressionRest(ast.GetBinaryOperatorPrecedence(p.token), updateExpression, pos)
        end
        return updateExpression
    end
    -- ES7 UnaryExpression:
    --      1) UpdateExpression[?yield]
    --      2) delete UpdateExpression[?yield]
    --      3) void UpdateExpression[?yield]
    --      4) typeof UpdateExpression[?yield]
    --      5) + UpdateExpression[?yield]
    --      6) - UpdateExpression[?yield]
    --      7) ~ UpdateExpression[?yield]
    --      8) ! UpdateExpression[?yield]
    local unaryOperator = p.token
    local simpleUnaryExpression = p:parseSimpleUnaryExpression()
    if p.token == Kind.AsteriskAsteriskToken then
        local pos = scanner.SkipTrivia(p.sourceText, simpleUnaryExpression:Pos())
        local end_ = simpleUnaryExpression:End()
        if simpleUnaryExpression.kind == Kind.TypeAssertionExpression then
            p:parseErrorAt(pos, end_, diagnostics.A_type_assertion_expression_is_not_allowed_in_the_left_hand_side_of_an_exponentiation_expression_Consider_enclosing_the_expression_in_parentheses)
        else
            assert(parser.isKeywordOrPunctuation(unaryOperator))
            p:parseErrorAt(pos, end_, diagnostics.An_unary_expression_with_the_0_operator_is_not_allowed_in_the_left_hand_side_of_an_exponentiation_expression_Consider_enclosing_the_expression_in_parentheses, scanner.TokenToString(unaryOperator))
        end
    end
    return simpleUnaryExpression
end

function Parser:isUpdateExpression()
    local t = self.token
    if t == Kind.PlusToken or t == Kind.MinusToken or t == Kind.TildeToken or t == Kind.ExclamationToken or t == Kind.DeleteKeyword or t == Kind.TypeOfKeyword or t == Kind.VoidKeyword or t == Kind.AwaitKeyword then
        return false
    elseif t == Kind.LessThanToken then
        return self.languageVariant == core.LanguageVariant.JSX
    end
    return true
end

function Parser:parseUpdateExpression()
    local p = self
    local pos = p:nodePos()
    if p.token == Kind.PlusPlusToken or p.token == Kind.MinusMinusToken then
        local operator = p.token
        p:nextToken()
        return p:finishNode(p.factory:NewPrefixUnaryExpression(operator, p:parseLeftHandSideExpressionOrHigher()), pos)
    elseif p.languageVariant == core.LanguageVariant.JSX and p.token == Kind.LessThanToken and p:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOrGreaterThan) then
        -- JSXElement is part of primaryExpression
        return p:parseJsxElementOrSelfClosingElementOrFragment(true --[[inExpressionContext]], -1 --[[topInvalidNodePosition]], nil --[[openingTag]], false --[[mustBeUnary]])
    end
    local expression = p:parseLeftHandSideExpressionOrHigher()
    if (p.token == Kind.PlusPlusToken or p.token == Kind.MinusMinusToken) and not p:hasPrecedingLineBreak() then
        local operator = p.token
        p:nextToken()
        return p:finishNode(p.factory:NewPostfixUnaryExpression(expression, operator), pos)
    end
    return expression
end
