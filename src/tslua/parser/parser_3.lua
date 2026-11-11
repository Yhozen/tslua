local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local PC = parser.ParsingContext
local ParseFlags = parser.ParseFlags
local Parser = parser.Parser

function Parser:parseJsxElementOrSelfClosingElementOrFragment(inExpressionContext, topInvalidNodePosition, openingTag, mustBeUnary)
    local p = self
    local pos = p:nodePos()
    local opening = p:parseJsxOpeningOrSelfClosingElementOrOpeningFragment(inExpressionContext)
    local result
    if opening.kind == Kind.JsxOpeningElement then
        local children = p:parseJsxChildren(opening)
        local closingElement
        local lastChild = children.nodes[#children.nodes]
        if lastChild ~= nil and lastChild.kind == Kind.JsxElement and
            not ast.TagNamesAreEquivalent(lastChild:AsJsxElement().openingElement:TagName(), lastChild:AsJsxElement().closingElement:TagName()) and
            ast.TagNamesAreEquivalent(opening:TagName(), lastChild:AsJsxElement().closingElement:TagName()) then
            -- when an unclosed JsxOpeningElement incorrectly parses its parent's JsxClosingElement,
            -- restructure (<div>(...<span>...</div>)) --> (<div>(...<span>...</>)</div>)
            -- (no need to error; the parent will error)
            local end_ = lastChild:Children():End()
            local missingIdentifier = p:finishNodeWithEnd(p:newIdentifier(""), end_, end_)
            local newClosingElement = p:finishNodeWithEnd(p.factory:NewJsxClosingElement(missingIdentifier), end_, end_)
            local newLast = p:finishNodeWithEnd(
                p.factory:NewJsxElement(lastChild:AsJsxElement().openingElement, lastChild:Children(), newClosingElement),
                lastChild:AsJsxElement().openingElement:Pos(),
                end_
            )
            -- force reset parent pointers from discarded parse result
            if lastChild:AsJsxElement().openingElement ~= nil then
                lastChild:AsJsxElement().openingElement.parent = newLast
            end
            if lastChild:Children() ~= nil then
                for _, c in ipairs(lastChild:Children().nodes) do
                    c.parent = newLast
                end
            end
            newClosingElement.parent = newLast
            local newNodes = {}
            for i = 1, #children.nodes - 1 do
                newNodes[i] = children.nodes[i]
            end
            newNodes[#newNodes + 1] = newLast
            children = p:newNodeList(core.NewTextRange(children:Pos(), newLast:End()), newNodes)
            closingElement = lastChild:AsJsxElement().closingElement
        else
            closingElement = p:parseJsxClosingElement(opening, inExpressionContext)
            if not ast.TagNamesAreEquivalent(opening:TagName(), closingElement:TagName()) then
                if openingTag ~= nil and ast.IsJsxOpeningElement(openingTag) and ast.TagNamesAreEquivalent(closingElement:TagName(), openingTag:TagName()) then
                    -- opening incorrectly matched with its parent's closing -- put error on opening
                    p:parseErrorAtRange(opening:TagName().loc, diagnostics.JSX_element_0_has_no_corresponding_closing_tag, scanner.GetTextOfNodeFromSourceText(p.sourceText, opening:TagName(), false --[[includeTrivia]]))
                else
                    -- other opening/closing mismatches -- put error on closing
                    p:parseErrorAtRange(closingElement:TagName().loc, diagnostics.Expected_corresponding_JSX_closing_tag_for_0, scanner.GetTextOfNodeFromSourceText(p.sourceText, opening:TagName(), false --[[includeTrivia]]))
                end
            end
        end
        result = p:finishNode(p.factory:NewJsxElement(opening, children, closingElement), pos)
        closingElement.parent = result -- force reset parent pointers from possibly discarded parse result
    elseif opening.kind == Kind.JsxOpeningFragment then
        result = p:finishNode(p.factory:NewJsxFragment(opening, p:parseJsxChildren(opening), p:parseJsxClosingFragment(inExpressionContext)), pos)
    elseif opening.kind == Kind.JsxSelfClosingElement then
        -- Nothing else to do for self-closing elements
        result = opening
    else
        error("Unhandled case in parseJsxElementOrSelfClosingElementOrFragment", 0)
    end
    -- If the user writes the invalid code '<div></div><div></div>' in an expression context (i.e. not wrapped in
    -- an enclosing tag), we'll naively try to parse   ^ this as a 'less than' operator and the remainder of the tag
    -- as garbage, which will cause the formatter to badly mangle the JSX. Perform a speculative parse of a JSX
    -- element if we see a < token so that we can wrap it in a synthetic binary expression so the formatter
    -- does less damage and we can report a better error.
    -- Since JSX elements are invalid < operands anyway, this lookahead parse will only occur in error scenarios
    -- of one sort or another.
    -- If we are in a unary context, we can't do this recovery; the binary expression we return here is not
    -- a valid UnaryExpression and will cause problems later.
    if not mustBeUnary and inExpressionContext and p.token == Kind.LessThanToken then
        local topBadPos = topInvalidNodePosition
        if topBadPos < 0 then
            topBadPos = result:Pos()
        end
        local invalidElement = p:parseJsxElementOrSelfClosingElementOrFragment(true --[[inExpressionContext]], topBadPos, nil, false)
        local operatorToken = p.factory:NewToken(Kind.CommaToken)
        operatorToken.loc = core.NewTextRange(invalidElement:Pos(), invalidElement:Pos())
        p:parseErrorAt(scanner.SkipTrivia(p.sourceText, topBadPos), invalidElement:End(), diagnostics.JSX_expressions_must_have_one_parent_element)
        result = p:finishNode(p.factory:NewBinaryExpression(nil --[[modifiers]], result, nil --[[typeNode]], operatorToken, invalidElement), pos)
    end
    return result
end

function Parser:parseJsxChildren(openingTag)
    local p = self
    local pos = p:nodePos()
    local saveParsingContexts = p.parsingContexts
    p.parsingContexts = p.parsingContexts | (1 << PC.PCJsxChildren)
    local list = {}
    while true do
        local currentToken = p.scanner:ReScanJsxToken(true --[[allowMultilineJsxText]])
        local child = p:parseJsxChild(openingTag, currentToken)
        if child == nil then
            break
        end
        list[#list + 1] = child
        if ast.IsJsxOpeningElement(openingTag) and child.kind == Kind.JsxElement and
            not ast.TagNamesAreEquivalent(child:AsJsxElement().openingElement:TagName(), child:AsJsxElement().closingElement:TagName()) and
            ast.TagNamesAreEquivalent(openingTag:TagName(), child:AsJsxElement().closingElement:TagName()) then
            -- stop after parsing a mismatched child like <div>...(<span></div>) in order to reattach the </div> higher
            break
        end
    end
    p.parsingContexts = saveParsingContexts
    return p:newNodeList(core.NewTextRange(pos, p:nodePos()), list)
end

function Parser:parseJsxChild(openingTag, token)
    local p = self
    if token == Kind.EndOfFile then
        -- If we hit EOF, issue the error at the tag that lacks the closing element
        -- rather than at the end of the file (which is useless)
        if ast.IsJsxOpeningFragment(openingTag) then
            p:parseErrorAtRange(openingTag.loc, diagnostics.JSX_fragment_has_no_corresponding_closing_tag)
        else
            -- We want the error span to cover only 'Foo.Bar' in < Foo.Bar >
            -- or to cover only 'Foo' in < Foo >
            local tag = openingTag:TagName()
            local start = math.min(scanner.SkipTrivia(p.sourceText, tag:Pos()), tag:End())
            p:parseErrorAt(start, tag:End(), diagnostics.JSX_element_0_has_no_corresponding_closing_tag,
                scanner.GetTextOfNodeFromSourceText(p.sourceText, openingTag:TagName(), false --[[includeTrivia]]))
        end
        return nil
    elseif token == Kind.LessThanSlashToken or token == Kind.ConflictMarkerTrivia then
        return nil
    elseif token == Kind.JsxText or token == Kind.JsxTextAllWhiteSpaces then
        return p:parseJsxText()
    elseif token == Kind.OpenBraceToken then
        return p:parseJsxExpression(false --[[inExpressionContext]])
    elseif token == Kind.LessThanToken then
        return p:parseJsxElementOrSelfClosingElementOrFragment(false --[[inExpressionContext]], -1 --[[topInvalidNodePosition]], openingTag, false)
    end
    error("Unhandled case in parseJsxChild", 0)
end

function Parser:parseJsxText()
    local pos = self:nodePos()
    local result = self.factory:NewJsxText(self.scanner:TokenValue(), self.token == Kind.JsxTextAllWhiteSpaces)
    self:scanJsxText()
    return self:finishNode(result, pos)
end

function Parser:parseJsxExpression(inExpressionContext)
    local p = self
    local pos = p:nodePos()
    if not p:parseExpected(Kind.OpenBraceToken) then
        return nil
    end
    local dotDotDotToken = nil
    local expression = nil
    if p.token ~= Kind.CloseBraceToken then
        if not inExpressionContext then
            dotDotDotToken = p:parseOptionalToken(Kind.DotDotDotToken)
        end
        -- Only an AssignmentExpression is valid here per the JSX spec,
        -- but we can unambiguously parse a comma sequence and provide
        -- a better error message in grammar checking.
        expression = p:parseExpression()
    end
    if inExpressionContext then
        p:parseExpected(Kind.CloseBraceToken)
    elseif p:parseExpectedWithoutAdvancing(Kind.CloseBraceToken) then
        p:scanJsxText()
    end
    return p:finishNode(p.factory:NewJsxExpression(dotDotDotToken, expression), pos)
end

function Parser:scanJsxText()
    self.token = self.scanner:ScanJsxToken()
    return self.token
end

function Parser:scanJsxIdentifier()
    self.token = self.scanner:ScanJsxIdentifier()
    return self.token
end

function Parser:scanJsxAttributeValue()
    self.token = self.scanner:ScanJsxAttributeValue()
    return self.token
end

function Parser:parseJsxClosingElement(open, inExpressionContext)
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.LessThanSlashToken)
    local tagName = p:parseJsxElementName()
    if p:parseExpectedWithDiagnostic(Kind.GreaterThanToken, nil --[[diagnosticMessage]], false --[[shouldAdvance]]) then
        -- manually advance the scanner in order to look for jsx text inside jsx
        if inExpressionContext or not ast.TagNamesAreEquivalent(open:TagName(), tagName) then
            p:nextToken()
        else
            p:scanJsxText()
        end
    end
    return p:finishNode(p.factory:NewJsxClosingElement(tagName), pos)
end

function Parser:parseJsxOpeningOrSelfClosingElementOrOpeningFragment(inExpressionContext)
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.LessThanToken)
    if p.token == Kind.GreaterThanToken then
        -- See below for explanation of scanJsxText
        p:scanJsxText()
        return p:finishNode(p.factory:NewJsxOpeningFragment(), pos)
    end
    local tagName = p:parseJsxElementName()
    local typeArguments = nil
    if p.contextFlags & NodeFlags.JavaScriptFile == 0 then
        typeArguments = p:parseTypeArguments()
    end
    local attributes = p:parseJsxAttributes()
    local result
    if p.token == Kind.GreaterThanToken then
        -- Closing tag, so scan the immediately-following text with the JSX scanning instead
        -- of regular scanning to avoid treating illegal characters (e.g. '#') as immediate
        -- scanning errors
        p:scanJsxText()
        result = p.factory:NewJsxOpeningElement(tagName, typeArguments, attributes)
    else
        p:parseExpected(Kind.SlashToken)
        if p:parseExpectedWithoutAdvancing(Kind.GreaterThanToken) then
            if inExpressionContext then
                p:nextToken()
            else
                p:scanJsxText()
            end
        end
        result = p.factory:NewJsxSelfClosingElement(tagName, typeArguments, attributes)
    end
    return p:finishNode(result, pos)
end

function Parser:parseJsxElementName()
    local p = self
    local pos = p:nodePos()
    -- JsxElement can have name in the form of
    --      propertyAccessExpression
    --      primaryExpression in the form of an identifier and "this" keyword
    -- We can't just simply use parseLeftHandSideExpressionOrHigher because then we will start consider class,function etc as a keyword
    -- We only want to consider "this" as a primaryExpression
    local initialExpression = p:parseJsxTagName()
    if ast.IsJsxNamespacedName(initialExpression) then
        return initialExpression -- `a:b.c` is invalid syntax, don't even look for the `.` if we parse `a:b`, and let `parseAttribute` report "unexpected :" instead.
    end
    local expression = initialExpression
    while p:parseOptional(Kind.DotToken) do
        expression = p:finishNode(p.factory:NewPropertyAccessExpression(expression, nil, p:parseRightSideOfDot(true --[[allowIdentifierNames]], false --[[allowPrivateIdentifiers]], false --[[allowUnicodeEscapeSequenceInIdentifierName]]), NodeFlags.None), pos)
    end
    return expression
end

function Parser:parseJsxTagName()
    local p = self
    local pos = p:nodePos()
    p:scanJsxIdentifier()
    local isThis = p.token == Kind.ThisKeyword
    local tagName = p:parseIdentifierNameErrorOnUnicodeEscapeSequence()
    if p:parseOptional(Kind.ColonToken) then
        p:scanJsxIdentifier()
        return p:finishNode(p.factory:NewJsxNamespacedName(tagName, p:parseIdentifierNameErrorOnUnicodeEscapeSequence()), pos)
    end
    if isThis then
        local result = p.factory:NewKeywordExpression(Kind.ThisKeyword)
        return p:finishNode(result, pos)
    end
    return tagName
end

function Parser:parseJsxAttributes()
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewJsxAttributes(self:parseList(PC.PCJsxAttributes, Parser.parseJsxAttribute)), pos)
end

function Parser:parseJsxAttribute()
    if self.token == Kind.OpenBraceToken then
        return self:parseJsxSpreadAttribute()
    end
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewJsxAttribute(self:parseJsxAttributeName(), self:parseJsxAttributeValue()), pos)
end

function Parser:parseJsxSpreadAttribute()
    local pos = self:nodePos()
    self:parseExpected(Kind.OpenBraceToken)
    self:parseExpected(Kind.DotDotDotToken)
    local expression = self:parseExpression()
    self:parseExpected(Kind.CloseBraceToken)
    return self:finishNode(self.factory:NewJsxSpreadAttribute(expression), pos)
end

function Parser:parseJsxAttributeName()
    local p = self
    local pos = p:nodePos()
    p:scanJsxIdentifier()
    local attrName = p:parseIdentifierNameErrorOnUnicodeEscapeSequence()
    if p:parseOptional(Kind.ColonToken) then
        p:scanJsxIdentifier()
        return p:finishNode(p.factory:NewJsxNamespacedName(attrName, p:parseIdentifierNameErrorOnUnicodeEscapeSequence()), pos)
    end
    return attrName
end

function Parser:parseJsxAttributeValue()
    local p = self
    if p.token == Kind.EqualsToken then
        if p:scanJsxAttributeValue() == Kind.StringLiteral then
            return p:parseLiteralExpression()
        end
        if p.token == Kind.OpenBraceToken then
            return p:parseJsxExpression(true --[[inExpressionContext]])
        end
        if p.token == Kind.LessThanToken then
            return p:parseJsxElementOrSelfClosingElementOrFragment(true --[[inExpressionContext]], -1, nil, false)
        end
        p:parseErrorAtCurrentToken(diagnostics.X_or_JSX_element_expected)
    end
    return nil
end

function Parser:parseJsxClosingFragment(inExpressionContext)
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.LessThanSlashToken)
    if p:parseExpectedWithDiagnostic(Kind.GreaterThanToken, diagnostics.Expected_corresponding_closing_tag_for_JSX_fragment, false --[[shouldAdvance]]) then
        -- manually advance the scanner in order to look for jsx text inside jsx
        if inExpressionContext then
            p:nextToken()
        else
            p:scanJsxText()
        end
    end
    return p:finishNode(p.factory:NewJsxClosingFragment(), pos)
end

function Parser:parseSimpleUnaryExpression()
    local p = self
    local t = p.token
    if t == Kind.PlusToken or t == Kind.MinusToken or t == Kind.TildeToken or t == Kind.ExclamationToken then
        return p:parsePrefixUnaryExpression()
    elseif t == Kind.DeleteKeyword then
        return p:parseDeleteExpression()
    elseif t == Kind.TypeOfKeyword then
        return p:parseTypeOfExpression()
    elseif t == Kind.VoidKeyword then
        return p:parseVoidExpression()
    elseif t == Kind.LessThanToken then
        -- Just like in parseUpdateExpression, we need to avoid parsing type assertions when
        -- in JSX and we see an expression like "+ <foo> bar".
        if p.languageVariant == core.LanguageVariant.JSX then
            return p:parseJsxElementOrSelfClosingElementOrFragment(true --[[inExpressionContext]], -1 --[[topInvalidNodePosition]], nil --[[openingTag]], true --[[mustBeUnary]])
        end
        -- // This is modified UnaryExpression grammar in TypeScript
        -- //  UnaryExpression (modified):
        -- //      < type > UnaryExpression
        return p:parseTypeAssertion()
    elseif t == Kind.AwaitKeyword and p:isAwaitExpression() then
        return p:parseAwaitExpression()
    end
    return p:parseUpdateExpression()
end

function Parser:parsePrefixUnaryExpression()
    local pos = self:nodePos()
    local operator = self.token
    self:nextToken()
    return self:finishNode(self.factory:NewPrefixUnaryExpression(operator, self:parseSimpleUnaryExpression()), pos)
end

function Parser:parseDeleteExpression()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewDeleteExpression(self:parseSimpleUnaryExpression()), pos)
end

function Parser:parseTypeOfExpression()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewTypeOfExpression(self:parseSimpleUnaryExpression()), pos)
end

function Parser:parseVoidExpression()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewVoidExpression(self:parseSimpleUnaryExpression()), pos)
end

function Parser:isAwaitExpression()
    if self.token == Kind.AwaitKeyword then
        if self:inAwaitContext() then
            return true
        end
        -- here we are using similar heuristics as 'isYieldExpression'
        return self:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOrLiteralOnSameLine)
    end
    return false
end

function Parser:parseAwaitExpression()
    local pos = self:nodePos()
    self:nextToken()
    return self:finishNode(self.factory:NewAwaitExpression(self:parseSimpleUnaryExpression()), pos)
end

function Parser:parseTypeAssertion()
    local p = self
    assert(p.languageVariant ~= core.LanguageVariant.JSX, "Type assertions should never be parsed in JSX; they should be parsed as comparisons or JSX elements/fragments.")
    local pos = p:nodePos()
    p:parseExpected(Kind.LessThanToken)
    local typeNode = p:parseType()
    p:parseExpected(Kind.GreaterThanToken)
    local expression = p:parseSimpleUnaryExpression()
    return p:finishNode(p.factory:NewTypeAssertion(typeNode, expression), pos)
end

function Parser:parseLeftHandSideExpressionOrHigher()
    local p = self
    -- Original Ecma:
    -- LeftHandSideExpression: See 11.2
    --      NewExpression
    --      CallExpression
    --
    -- Our simplification:
    --
    -- LeftHandSideExpression: See 11.2
    --      MemberExpression
    --      CallExpression
    --
    -- See comment in parseMemberExpressionOrHigher on how we replaced NewExpression with
    -- MemberExpression to make our lives easier.
    --
    -- to best understand the below code, it's important to see how CallExpression expands
    -- out into its own productions:
    --
    -- CallExpression:
    --      MemberExpression Arguments
    --      CallExpression Arguments
    --      CallExpression[Expression]
    --      CallExpression.IdentifierName
    --      import (AssignmentExpression)
    --      super Arguments
    --      super.IdentifierName
    --
    -- Because of the recursion in these calls, we need to bottom out first. There are three
    -- bottom out states we can run into: 1) We see 'super' which must start either of
    -- the last two CallExpression productions. 2) We see 'import' which must start import call.
    -- 3)we have a MemberExpression which either completes the LeftHandSideExpression,
    -- or starts the beginning of the first four CallExpression productions.
    local pos = p:nodePos()
    local expression
    if p.token == Kind.ImportKeyword then
        if p:lookAhead(Parser.nextTokenIsOpenParenOrLessThan) then
            -- We don't want to eagerly consume all import keyword as import call expression so we look ahead to find "("
            -- For example:
            --      var foo3 = require("subfolder
            --      import * as foo1 from "module-from-node
            -- We want this import to be a statement rather than import call expression
            p.sourceFlags = p.sourceFlags | NodeFlags.PossiblyContainsDynamicImport
            expression = p:parseKeywordExpression()
        elseif p:lookAhead(Parser.nextTokenIsDot) then
            -- This is an 'import.*' metaproperty (i.e. 'import.meta')
            p:nextToken() -- advance past the 'import'
            p:nextToken() -- advance past the dot
            expression = p:finishNode(p.factory:NewMetaProperty(Kind.ImportKeyword, p:parseIdentifierName()), pos)
            if expression:Text() == "defer" then
                if p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken then
                    p.sourceFlags = p.sourceFlags | NodeFlags.PossiblyContainsDynamicImport
                end
            else
                p.sourceFlags = p.sourceFlags | NodeFlags.PossiblyContainsImportMeta
            end
        else
            expression = p:parseMemberExpressionOrHigher()
        end
    elseif p.token == Kind.SuperKeyword then
        expression = p:parseSuperExpression()
    else
        expression = p:parseMemberExpressionOrHigher()
    end
    -- Now, we *may* be complete.  However, we might have consumed the start of a
    -- CallExpression or OptionalExpression.  As such, we need to consume the rest
    -- of it here to be complete.
    return p:parseCallExpressionRest(pos, expression)
end

function Parser:nextTokenIsDot()
    return self:nextToken() == Kind.DotToken
end

function Parser:parseSuperExpression()
    local p = self
    local pos = p:nodePos()
    local expression = p:parseKeywordExpression()
    if p.token == Kind.LessThanToken then
        local startPos = p:nodePos()
        local typeArguments = p:tryParseTypeArgumentsInExpression()
        if typeArguments ~= nil then
            p:parseErrorAt(startPos, p:nodePos(), diagnostics.X_super_may_not_use_type_arguments)
            if not p:isTemplateStartOfTaggedTemplate() then
                expression = p:finishNode(p.factory:NewExpressionWithTypeArguments(expression, typeArguments), pos)
            end
        end
    end
    if p.token == Kind.OpenParenToken or p.token == Kind.DotToken or p.token == Kind.OpenBracketToken then
        return expression
    end
    -- If we have seen "super" it must be followed by '(' or '.'.
    -- If it wasn't then just try to parse out a '.' and report an error.
    p:parseErrorAtCurrentToken(diagnostics.X_super_must_be_followed_by_an_argument_list_or_member_access)
    -- private names will never work with `super` (`super.#foo`), but that's a semantic error, not syntactic
    return p:finishNode(p.factory:NewPropertyAccessExpression(expression, nil --[[questionDotToken]], p:parseRightSideOfDot(true --[[allowIdentifierNames]], true --[[allowPrivateIdentifiers]], true --[[allowUnicodeEscapeSequenceInIdentifierName]]), NodeFlags.None), pos)
end

function Parser:isTemplateStartOfTaggedTemplate()
    return self.token == Kind.NoSubstitutionTemplateLiteral or self.token == Kind.TemplateHead
end

function Parser:tryParseTypeArgumentsInExpression()
    local p = self
    -- TypeArguments must not be parsed in JavaScript files to avoid ambiguity with binary operators.
    -- Check the cheap preconditions before saving the parser state: unless the current token is `<`
    -- (or `<<`, which reScanLessThanToken would split), there is nothing to speculatively parse and
    -- the mark/rewind would be a no-op.
    if p.contextFlags & NodeFlags.JavaScriptFile ~= 0 or (p.token ~= Kind.LessThanToken and p.token ~= Kind.LessThanLessThanToken) then
        return nil
    end
    local state = p:mark()
    if p:reScanLessThanToken() == Kind.LessThanToken then
        p:nextToken()
        local typeArguments = p:parseDelimitedList(PC.PCTypeArguments, Parser.parseType)
        -- If it doesn't have the closing `>` then it's definitely not an type argument list.
        if p:reScanGreaterThanToken() == Kind.GreaterThanToken then
            p:nextToken()
            -- We successfully parsed a type argument list. The next token determines whether we want to
            -- treat it as such. If the type argument list is followed by `(` or a template literal, as in
            -- `f<number>(42)`, we favor the type argument interpretation even though JavaScript would view
            -- it as a relational expression.
            if p:canFollowTypeArgumentsInExpression() then
                return typeArguments
            end
        end
    end
    p:rewind(state)
    return nil
end

function Parser:canFollowTypeArgumentsInExpression()
    local t = self.token
    -- These tokens can follow a type argument list in a call expression:
    -- foo<x>(
    -- foo<T> `...`
    -- foo<T> `...${100}...`
    if t == Kind.OpenParenToken or t == Kind.NoSubstitutionTemplateLiteral or t == Kind.TemplateHead then
        return true
    -- A type argument list followed by `<` never makes sense, and a type argument list followed
    -- by `>` is ambiguous with a (re-scanned) `>>` operator, so we disqualify both. Also, in
    -- this context, `+` and `-` are unary operators, not binary operators.
    elseif t == Kind.LessThanToken or t == Kind.GreaterThanToken or t == Kind.PlusToken or t == Kind.MinusToken then
        return false
    end
    -- We favor the type argument list interpretation when it is immediately followed by
    -- a line break, a binary operator, or something that can't start an expression.
    return self:hasPrecedingLineBreak() or self:isBinaryOperator() or not self:isStartOfExpression()
end

function Parser:parseMemberExpressionOrHigher()
    -- Note: to make our lives simpler, we decompose the NewExpression productions and
    -- place ObjectCreationExpression and FunctionExpression into PrimaryExpression.
    -- like so:
    --
    --   PrimaryExpression : See 11.1
    --      this
    --      Identifier
    --      Literal
    --      ArrayLiteral
    --      ObjectLiteral
    --      (Expression)
    --      FunctionExpression
    --      new MemberExpression Arguments?
    --
    --   MemberExpression : See 11.2
    --      PrimaryExpression
    --      MemberExpression[Expression]
    --      MemberExpression.IdentifierName
    --
    --   CallExpression : See 11.2
    --      MemberExpression
    --      CallExpression Arguments
    --      CallExpression[Expression]
    --      CallExpression.IdentifierName
    --
    -- Technically this is ambiguous.  i.e. CallExpression defines:
    --
    --   CallExpression:
    --      CallExpression Arguments
    --
    -- If you see: "new Foo()"
    --
    -- Then that could be treated as a single ObjectCreationExpression, or it could be
    -- treated as the invocation of "new Foo".  We disambiguate that in code (to match
    -- the original grammar) by making sure that if we see an ObjectCreationExpression
    -- we always consume arguments if they are there. So we treat "new Foo()" as an
    -- object creation only, and not at all as an invocation.  Another way to think
    -- about this is that for every "new" that we see, we will consume an argument list if
    -- it is there as part of the *associated* object creation node.  Any additional
    -- argument lists we see, will become invocation expressions.
    --
    -- Because there are no other places in the grammar now that refer to FunctionExpression
    -- or ObjectCreationExpression, it is safe to push down into the PrimaryExpression
    -- production.
    --
    -- Because CallExpression and MemberExpression are left recursive, we need to bottom out
    -- of the recursion immediately.  So we parse out a primary expression to start with.
    local pos = self:nodePos()
    local expression = self:parsePrimaryExpression()
    return self:parseMemberExpressionRest(pos, expression, true --[[allowOptionalChain]])
end

function Parser:parseMemberExpressionRest(pos, expression, allowOptionalChain)
    local p = self
    while true do
        local questionDotToken = nil
        local isPropertyAccess = false
        if allowOptionalChain and p:isStartOfOptionalPropertyOrElementAccessChain() then
            questionDotToken = p:parseExpectedToken(Kind.QuestionDotToken)
            isPropertyAccess = parser.tokenIsIdentifierOrKeyword(p.token)
        else
            isPropertyAccess = p:parseOptional(Kind.DotToken)
        end
        if isPropertyAccess then
            expression = p:parsePropertyAccessExpressionRest(pos, expression, questionDotToken)
            goto continue
        end
        -- when in the [Decorator] context, we do not parse ElementAccess as it could be part of a ComputedPropertyName
        if (questionDotToken ~= nil or not p:inDecoratorContext()) and p:parseOptional(Kind.OpenBracketToken) then
            expression = p:parseElementAccessExpressionRest(pos, expression, questionDotToken)
            goto continue
        end
        if p:isTemplateStartOfTaggedTemplate() then
            -- Absorb type arguments into TemplateExpression when preceding expression is ExpressionWithTypeArguments
            if questionDotToken == nil and ast.IsExpressionWithTypeArguments(expression) then
                local original = expression:AsExpressionWithTypeArguments()
                expression = p:parseTaggedTemplateRest(pos, original.expression, questionDotToken, original.typeArguments)
                p:unparseExpressionWithTypeArguments(original.expression, original.typeArguments, expression)
            else
                expression = p:parseTaggedTemplateRest(pos, expression, questionDotToken, nil --[[typeArguments]])
            end
            goto continue
        end
        if questionDotToken == nil then
            if p.token == Kind.ExclamationToken and not p:hasPrecedingLineBreak() then
                p:nextToken()
                expression = p:checkJSSyntax(p:finishNode(p.factory:NewNonNullExpression(expression, NodeFlags.None), pos))
                goto continue
            end
            local typeArguments = p:tryParseTypeArgumentsInExpression()
            if typeArguments ~= nil then
                expression = p:finishNode(p.factory:NewExpressionWithTypeArguments(expression, typeArguments), pos)
                goto continue
            end
        end
        do
            return expression
        end
        ::continue::
    end
end

function Parser:isStartOfOptionalPropertyOrElementAccessChain()
    return self.token == Kind.QuestionDotToken and self:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOrOpenBracketOrTemplate)
end

function Parser:nextTokenIsIdentifierOrKeywordOrOpenBracketOrTemplate()
    self:nextToken()
    return parser.tokenIsIdentifierOrKeyword(self.token) or self.token == Kind.OpenBracketToken or self:isTemplateStartOfTaggedTemplate()
end

function Parser:parsePropertyAccessExpressionRest(pos, expression, questionDotToken)
    local p = self
    local name = p:parseRightSideOfDot(true --[[allowIdentifierNames]], true --[[allowPrivateIdentifiers]], true --[[allowUnicodeEscapeSequenceInIdentifierName]])
    local isOptionalChain = questionDotToken ~= nil or p:tryReparseOptionalChain(expression)
    local propertyAccess = p.factory:NewPropertyAccessExpression(expression, questionDotToken, name, isOptionalChain and NodeFlags.OptionalChain or NodeFlags.None)
    if isOptionalChain and ast.IsPrivateIdentifier(name) then
        p:parseErrorAtRange(p:skipRangeTrivia(name.loc), diagnostics.An_optional_chain_cannot_contain_private_identifiers)
    end
    if ast.IsExpressionWithTypeArguments(expression) then
        local typeArguments = expression:TypeArgumentList()
        if typeArguments ~= nil then
            local loc = core.NewTextRange(typeArguments:Pos() - 1, scanner.SkipTrivia(p.sourceText, typeArguments:End()) + 1)
            p:parseErrorAtRange(loc, diagnostics.An_instantiation_expression_cannot_be_followed_by_a_property_access)
        end
    end
    return p:finishNode(propertyAccess, pos)
end

function Parser:tryReparseOptionalChain(node)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        return true
    end
    -- check for an optional chain in a non-null expression
    if ast.IsNonNullExpression(node) then
        local expr = node:Expression()
        while ast.IsNonNullExpression(expr) and expr.flags & NodeFlags.OptionalChain == 0 do
            expr = expr:Expression()
        end
        if expr.flags & NodeFlags.OptionalChain ~= 0 then
            -- this is part of an optional chain. Walk down from `node` to `expression` and set the flag.
            while ast.IsNonNullExpression(node) do
                node.flags = node.flags | NodeFlags.OptionalChain
                node = node:Expression()
            end
            return true
        end
    end
    return false
end

function Parser:parseElementAccessExpressionRest(pos, expression, questionDotToken)
    local p = self
    local argumentExpression = p:createMissingIdentifier()
    if p.token == Kind.CloseBracketToken then
        p:parseErrorAt(p:nodePos(), p:nodePos(), diagnostics.An_element_access_expression_should_take_an_argument)
    else
        argumentExpression = p:parseExpressionAllowIn()
    end
    p:parseExpected(Kind.CloseBracketToken)
    local isOptionalChain = questionDotToken ~= nil or p:tryReparseOptionalChain(expression)
    return p:finishNode(p.factory:NewElementAccessExpression(expression, questionDotToken, argumentExpression, isOptionalChain and NodeFlags.OptionalChain or NodeFlags.None), pos)
end

function Parser:parseCallExpressionRest(pos, expression)
    local p = self
    while true do
        expression = p:parseMemberExpressionRest(pos, expression, true --[[allowOptionalChain]])
        local typeArguments = nil
        local questionDotToken = p:parseOptionalToken(Kind.QuestionDotToken)
        if questionDotToken ~= nil then
            typeArguments = p:tryParseTypeArgumentsInExpression()
            if p:isTemplateStartOfTaggedTemplate() then
                expression = p:parseTaggedTemplateRest(pos, expression, questionDotToken, typeArguments)
                goto continue
            end
        end
        if typeArguments ~= nil or p.token == Kind.OpenParenToken then
            -- Absorb type arguments into CallExpression when preceding expression is ExpressionWithTypeArguments
            if questionDotToken == nil and expression.kind == Kind.ExpressionWithTypeArguments then
                typeArguments = expression:TypeArgumentList()
                expression = expression:AsExpressionWithTypeArguments().expression
            end
            local inner = expression
            local argumentList = p:parseArgumentList()
            local isOptionalChain = questionDotToken ~= nil or p:tryReparseOptionalChain(expression)
            expression = p:checkJSSyntax(p:finishNode(p.factory:NewCallExpression(expression, questionDotToken, typeArguments, argumentList, isOptionalChain and NodeFlags.OptionalChain or NodeFlags.None), pos))
            p:unparseExpressionWithTypeArguments(inner, typeArguments, expression)
            goto continue
        end
        if questionDotToken ~= nil then
            -- We parsed `?.` but then failed to parse anything, so report a missing identifier here.
            p:parseErrorAtCurrentToken(diagnostics.Identifier_expected)
            local name = p:createMissingIdentifier()
            expression = p:finishNode(p.factory:NewPropertyAccessExpression(expression, questionDotToken, name, NodeFlags.OptionalChain), pos)
        end
        do
            break
        end
        ::continue::
    end
    return expression
end

function Parser:parseArgumentList()
    self:parseExpected(Kind.OpenParenToken)
    local result = self:parseDelimitedList(PC.PCArgumentExpressions, Parser.parseArgumentExpression)
    self:parseExpected(Kind.CloseParenToken)
    return result
end

function Parser:parseArgumentExpression()
    return parser.doInContext(self, NodeFlags.DisallowInContext | NodeFlags.DecoratorContext, false, Parser.parseArgumentOrArrayLiteralElement)
end

function Parser:parseArgumentOrArrayLiteralElement()
    if self.token == Kind.DotDotDotToken then
        return self:parseSpreadElement()
    elseif self.token == Kind.CommaToken then
        return self:finishNode(self.factory:NewOmittedExpression(), self:nodePos())
    end
    return self:parseAssignmentExpressionOrHigher()
end

function Parser:parseSpreadElement()
    local pos = self:nodePos()
    self:parseExpected(Kind.DotDotDotToken)
    local expression = self:parseAssignmentExpressionOrHigher()
    return self:finishNode(self.factory:NewSpreadElement(expression), pos)
end

function Parser:parseTaggedTemplateRest(pos, tag, questionDotToken, typeArguments)
    local p = self
    local template
    if p.token == Kind.NoSubstitutionTemplateLiteral then
        p:reScanTemplateToken(true --[[isTaggedTemplate]])
        template = p:parseLiteralExpression()
    else
        template = p:parseTemplateExpression(true --[[isTaggedTemplate]])
    end
    local isOptionalChain = questionDotToken ~= nil or tag.flags & NodeFlags.OptionalChain ~= 0
    return p:checkJSSyntax(p:finishNode(p.factory:NewTaggedTemplateExpression(tag, questionDotToken, typeArguments, template, isOptionalChain and NodeFlags.OptionalChain or NodeFlags.None), pos))
end

function Parser:parseTemplateExpression(isTaggedTemplate)
    local pos = self:nodePos()
    return self:finishNode(self.factory:NewTemplateExpression(self:parseTemplateHead(isTaggedTemplate), self:parseTemplateSpans(isTaggedTemplate)), pos)
end

function Parser:parseTemplateSpans(isTaggedTemplate)
    local pos = self:nodePos()
    local list = {}
    while true do
        local span = self:parseTemplateSpan(isTaggedTemplate)
        list[#list + 1] = span
        if span:AsTemplateSpan().literal.kind ~= Kind.TemplateMiddle then
            break
        end
    end
    return self:newNodeList(core.NewTextRange(pos, self:nodePos()), list)
end

function Parser:parseTemplateSpan(isTaggedTemplate)
    local pos = self:nodePos()
    local expression = self:parseExpressionAllowIn()
    local literal = self:parseLiteralOfTemplateSpan(isTaggedTemplate)
    return self:finishNode(self.factory:NewTemplateSpan(expression, literal), pos)
end

function Parser:parsePrimaryExpression()
    local p = self
    local t = p.token
    if t == Kind.NoSubstitutionTemplateLiteral or t == Kind.NumericLiteral or t == Kind.BigIntLiteral or t == Kind.StringLiteral then
        if t == Kind.NoSubstitutionTemplateLiteral and p.scanner:TokenFlags() & ast.TokenFlags.IsInvalid ~= 0 then
            p:reScanTemplateToken(false --[[isTaggedTemplate]])
        end
        return p:parseLiteralExpression()
    elseif t == Kind.ThisKeyword or t == Kind.SuperKeyword or t == Kind.NullKeyword or t == Kind.TrueKeyword or t == Kind.FalseKeyword then
        return p:parseKeywordExpression()
    elseif t == Kind.OpenParenToken then
        return p:parseParenthesizedExpression()
    elseif t == Kind.OpenBracketToken then
        return p:parseArrayLiteralExpression()
    elseif t == Kind.OpenBraceToken then
        return p:parseObjectLiteralExpression()
    elseif t == Kind.AsyncKeyword then
        -- Async arrow functions are parsed earlier in parseAssignmentExpressionOrHigher.
        -- If we encounter `async [no LineTerminator here] function` then this is an async
        -- function; otherwise, its an identifier.
        if p:lookAhead(Parser.nextTokenIsFunctionKeywordOnSameLine) then
            return p:parseFunctionExpression()
        end
    elseif t == Kind.AtToken then
        return p:parseDecoratedExpression()
    elseif t == Kind.ClassKeyword then
        return p:parseClassExpression()
    elseif t == Kind.FunctionKeyword then
        return p:parseFunctionExpression()
    elseif t == Kind.NewKeyword then
        return p:parseNewExpressionOrNewDotTarget()
    elseif t == Kind.SlashToken or t == Kind.SlashEqualsToken then
        if p:reScanSlashToken() == Kind.RegularExpressionLiteral then
            return p:parseLiteralExpression()
        end
    elseif t == Kind.TemplateHead then
        return p:parseTemplateExpression(false --[[isTaggedTemplate]])
    elseif t == Kind.PrivateIdentifier then
        return p:parsePrivateIdentifier()
    end
    return p:parseIdentifierWithDiagnostic(diagnostics.Expression_expected, nil)
end

function Parser:parseParenthesizedExpression()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    p:parseExpected(Kind.OpenParenToken)
    local expression = p:parseExpressionAllowIn()
    p:parseExpected(Kind.CloseParenToken)
    local result = p:finishNode(p.factory:NewParenthesizedExpression(expression), pos)
    p:withJSDoc(result, jsdoc)
    return result
end

function Parser:parseArrayLiteralExpression()
    local p = self
    local pos = p:nodePos()
    local openBracketPosition = p.scanner:TokenStart()
    local openBracketParsed = p:parseExpected(Kind.OpenBracketToken)
    local multiLine = p:hasPrecedingLineBreak()
    local elements = p:parseDelimitedList(PC.PCArrayLiteralMembers, Parser.parseArgumentOrArrayLiteralElement)
    p:parseExpectedMatchingBrackets(Kind.OpenBracketToken, Kind.CloseBracketToken, openBracketParsed, openBracketPosition)
    return p:finishNode(p.factory:NewArrayLiteralExpression(elements, multiLine), pos)
end

function Parser:parseObjectLiteralExpression()
    local p = self
    local pos = p:nodePos()
    local openBracePosition = p.scanner:TokenStart()
    local openBraceParsed = p:parseExpected(Kind.OpenBraceToken)
    local multiLine = p:hasPrecedingLineBreak()
    local properties = p:parseDelimitedList(PC.PCObjectLiteralMembers, Parser.parseObjectLiteralElement)
    p:parseExpectedMatchingBrackets(Kind.OpenBraceToken, Kind.CloseBraceToken, openBraceParsed, openBracePosition)
    return p:finishNode(p.factory:NewObjectLiteralExpression(properties, multiLine), pos)
end

function Parser:parseObjectLiteralElement()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    if p:parseOptional(Kind.DotDotDotToken) then
        local expression = p:parseAssignmentExpressionOrHigher()
        local result = p:finishNode(p.factory:NewSpreadAssignment(expression), pos)
        p:withJSDoc(result, jsdoc)
        return result
    end
    local modifiers = p:parseModifiersEx(true --[[allowDecorators]], false --[[permitConstAsModifier]], false --[[stopOnStartOfClassStaticBlock]])
    if p:parseContextualModifier(Kind.GetKeyword) then
        return p:parseAccessorDeclaration(pos, jsdoc, modifiers, Kind.GetAccessor, ParseFlags.None)
    end
    if p:parseContextualModifier(Kind.SetKeyword) then
        return p:parseAccessorDeclaration(pos, jsdoc, modifiers, Kind.SetAccessor, ParseFlags.None)
    end
    local asteriskToken = p:parseOptionalToken(Kind.AsteriskToken)
    local tokenIsIdentifier = p:isIdentifier()
    local name = p:parsePropertyName()
    -- Disallowing of optional property assignments and definite assignment assertion happens in the grammar checker.
    local postfixToken = p:parseOptionalToken(Kind.QuestionToken)
    -- Decorators, Modifiers, questionToken, and exclamationToken are not supported by property assignments and are reported in the grammar checker
    if postfixToken == nil then
        postfixToken = p:parseOptionalToken(Kind.ExclamationToken)
    end
    if asteriskToken ~= nil or p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken then
        return p:parseMethodDeclaration(pos, jsdoc, modifiers, asteriskToken, name, postfixToken, nil --[[diagnosticMessage]])
    end
    -- check if it is short-hand property assignment or normal property assignment
    -- NOTE: if token is EqualsToken it is interpreted as CoverInitializedName production
    -- CoverInitializedName[Yield] :
    --     IdentifierReference[?Yield] Initializer[In, ?Yield]
    -- this is necessary because ObjectLiteral productions are also used to cover grammar for ObjectAssignmentPattern
    local node
    local isShorthandPropertyAssignment = tokenIsIdentifier and p.token ~= Kind.ColonToken
    if isShorthandPropertyAssignment then
        local equalsToken = p:parseOptionalToken(Kind.EqualsToken)
        local initializer = nil
        if equalsToken ~= nil then
            initializer = parser.doInContext(p, NodeFlags.DisallowInContext, false, Parser.parseAssignmentExpressionOrHigher)
        end
        node = p.factory:NewShorthandPropertyAssignment(modifiers, name, postfixToken, nil --[[typeNode]], equalsToken, initializer)
    else
        p:parseExpected(Kind.ColonToken)
        local initializer = parser.doInContext(p, NodeFlags.DisallowInContext, false, Parser.parseAssignmentExpressionOrHigher)
        node = p.factory:NewPropertyAssignment(modifiers, name, postfixToken, nil --[[typeNode]], initializer)
    end
    p:finishNode(node, pos)
    p:withJSDoc(node, jsdoc)
    return node
end

function Parser:parseFunctionExpression()
    local p = self
    -- GeneratorExpression:
    --      function* BindingIdentifier [Yield][opt](FormalParameters[Yield]){ GeneratorBody }
    --
    -- FunctionExpression:
    --      function BindingIdentifier[opt](FormalParameters){ FunctionBody }
    local saveContexFlags = p.contextFlags
    p:setContextFlags(NodeFlags.DecoratorContext, false)
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local modifiers = p:parseModifiers()
    p:parseExpected(Kind.FunctionKeyword)
    local asteriskToken = p:parseOptionalToken(Kind.AsteriskToken)
    local isGenerator = asteriskToken ~= nil
    local isAsync = parser.modifierListHasAsync(modifiers)
    local signatureFlags = (isGenerator and ParseFlags.Yield or ParseFlags.None) | (isAsync and ParseFlags.Await or ParseFlags.None)
    local name
    if isGenerator and isAsync then
        name = parser.doInContext(p, NodeFlags.YieldContext | NodeFlags.AwaitContext, true, Parser.parseOptionalBindingIdentifier)
    elseif isGenerator then
        name = parser.doInContext(p, NodeFlags.YieldContext, true, Parser.parseOptionalBindingIdentifier)
    elseif isAsync then
        name = parser.doInContext(p, NodeFlags.AwaitContext, true, Parser.parseOptionalBindingIdentifier)
    else
        name = p:parseOptionalBindingIdentifier()
    end
    local typeParameters = p:parseTypeParameters()
    local parameters = p:parseParameters(signatureFlags)
    local returnType = p:parseReturnType(Kind.ColonToken, false --[[isType]])
    local body = p:parseFunctionBlock(signatureFlags, nil --[[diagnosticMessage]])
    p.contextFlags = saveContexFlags
    local result = p.factory:NewFunctionExpression(modifiers, asteriskToken, name, typeParameters, parameters, returnType, nil --[[fullSignature]], body)
    p:finishNode(result, pos)
    p:withJSDoc(result, jsdoc)
    p:checkJSSyntax(result)
    return result
end

function Parser:parseOptionalBindingIdentifier()
    if self:isBindingIdentifier() then
        return self:parseBindingIdentifier()
    end
    return nil
end

function Parser:parseDecoratedExpression()
    local p = self
    local pos = p:nodePos()
    local jsdoc = p:jsdocScannerInfo()
    local modifiers = p:parseModifiersEx(true --[[allowDecorators]], false --[[permitConstAsModifier]], false --[[stopOnStartOfClassStaticBlock]])
    if p.token == Kind.ClassKeyword then
        return p:parseClassDeclarationOrExpression(pos, jsdoc, modifiers, Kind.ClassExpression)
    end
    p:parseErrorAt(p:nodePos(), p:nodePos(), diagnostics.Expression_expected)
    return p:finishNode(p.factory:NewMissingDeclaration(modifiers), pos)
end

function Parser:unparseExpressionWithTypeArguments(expression, typeArguments, result)
    -- force overwrite the `.Parent` of the expression and type arguments to erase the fact that they may have originally been parsed as an ExpressionWithTypeArguments and be parented to such
    if expression ~= nil then
        expression.parent = result
    end
    if typeArguments ~= nil then
        for _, a in ipairs(typeArguments.nodes) do
            a.parent = result
        end
    end
end

function Parser:parseNewExpressionOrNewDotTarget()
    local p = self
    local pos = p:nodePos()
    p:parseExpected(Kind.NewKeyword)
    if p:parseOptional(Kind.DotToken) then
        local name = p:parseIdentifierName()
        return p:finishNode(p.factory:NewMetaProperty(Kind.NewKeyword, name), pos)
    end
    local expressionPos = p:nodePos()
    local expression = p:parseMemberExpressionRest(expressionPos, p:parsePrimaryExpression(), false --[[allowOptionalChain]])
    local typeArguments = nil
    -- Absorb type arguments into NewExpression when preceding expression is ExpressionWithTypeArguments
    if expression.kind == Kind.ExpressionWithTypeArguments then
        typeArguments = expression:TypeArgumentList()
        expression = expression:AsExpressionWithTypeArguments().expression
    end
    if p.token == Kind.QuestionDotToken then
        p:parseErrorAtCurrentToken(diagnostics.Invalid_optional_chain_from_new_expression_Did_you_mean_to_call_0, scanner.GetTextOfNodeFromSourceText(p.sourceText, expression, false --[[includeTrivia]]))
    end
    local argumentList = nil
    if p.token == Kind.OpenParenToken then
        argumentList = p:parseArgumentList()
    end
    local result = p:checkJSSyntax(p:finishNode(p.factory:NewNewExpression(expression, typeArguments, argumentList), pos))
    p:unparseExpressionWithTypeArguments(expression, typeArguments, result)
    return result
end

function Parser:parseKeywordExpression()
    local pos = self:nodePos()
    local result = self.factory:NewKeywordExpression(self.token)
    self:nextToken()
    return self:finishNode(result, pos)
end

function Parser:parseLiteralExpression()
    local p = self
    local pos = p:nodePos()
    local text = p.scanner:TokenValue()
    local tokenFlags = p.scanner:TokenFlags()
    local result
    local t = p.token
    if t == Kind.StringLiteral then
        result = p.factory:NewStringLiteral(text, tokenFlags)
    elseif t == Kind.NumericLiteral then
        result = p.factory:NewNumericLiteral(text, tokenFlags)
    elseif t == Kind.BigIntLiteral then
        result = p.factory:NewBigIntLiteral(text, tokenFlags)
    elseif t == Kind.RegularExpressionLiteral then
        result = p.factory:NewRegularExpressionLiteral(text, tokenFlags)
    elseif t == Kind.NoSubstitutionTemplateLiteral then
        result = p.factory:NewNoSubstitutionTemplateLiteral(text, tokenFlags)
    else
        error("Unhandled case in parseLiteralExpression", 0)
    end
    p:nextToken()
    return p:finishNode(result, pos)
end

function Parser:parseIdentifierNameErrorOnUnicodeEscapeSequence()
    if self.scanner:HasUnicodeEscape() or self.scanner:HasExtendedUnicodeEscape() then
        self:parseErrorAtCurrentToken(diagnostics.Unicode_escape_sequence_cannot_appear_here)
    end
    return self:createIdentifier(parser.tokenIsIdentifierOrKeyword(self.token))
end

function Parser:parseBindingIdentifier()
    return self:parseBindingIdentifierWithDiagnostic(nil)
end

function Parser:parseBindingIdentifierWithDiagnostic(privateIdentifierDiagnosticMessage)
    local saveHasAwaitIdentifier = self.statementHasAwaitIdentifier
    local id = self:createIdentifierWithDiagnostic(self:isBindingIdentifier(), nil --[[diagnosticMessage]], privateIdentifierDiagnosticMessage)
    self.statementHasAwaitIdentifier = saveHasAwaitIdentifier
    return id
end

function Parser:parseIdentifierName()
    return self:parseIdentifierNameWithDiagnostic(nil)
end

function Parser:parseIdentifierNameWithDiagnostic(diagnosticMessage)
    return self:createIdentifierWithDiagnostic(parser.tokenIsIdentifierOrKeyword(self.token), diagnosticMessage, nil)
end

function Parser:parseIdentifier()
    return self:parseIdentifierWithDiagnostic(nil, nil)
end

function Parser:parseIdentifierWithDiagnostic(diagnosticMessage, privateIdentifierDiagnosticMessage)
    return self:createIdentifierWithDiagnostic(self:isIdentifier(), diagnosticMessage, privateIdentifierDiagnosticMessage)
end

function Parser:createIdentifier(isIdentifier)
    return self:createIdentifierWithDiagnostic(isIdentifier, nil, nil)
end

function Parser:createIdentifierWithDiagnostic(isIdentifier, diagnosticMessage, privateIdentifierDiagnosticMessage)
    local p = self
    if isIdentifier then
        local pos
        if p.scanner:HasPrecedingJSDocLeadingAsterisks() then
            pos = p.scanner:TokenStart()
        else
            pos = p:nodePos()
        end
        local text = p.scanner:TokenValue()
        p:nextTokenWithoutCheck()
        return p:finishNode(p:newIdentifier(text), pos)
    end
    if p.token == Kind.PrivateIdentifier then
        if privateIdentifierDiagnosticMessage ~= nil then
            p:parseErrorAtCurrentToken(privateIdentifierDiagnosticMessage)
        else
            p:parseErrorAtCurrentToken(diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies)
        end
        return p:createIdentifier(true --[[isIdentifier]])
    end
    -- Only for end of file because the error gets reported incorrectly on embedded script tags.
    local reportAtCurrentPosition = p.token == Kind.EndOfFile
    if diagnosticMessage ~= nil then
        if reportAtCurrentPosition then
            local pos = p.scanner:TokenFullStart()
            p:parseErrorAt(pos, pos, diagnosticMessage)
        else
            p:parseErrorAtCurrentToken(diagnosticMessage)
        end
    elseif parser.isReservedWord(p.token) then
        if reportAtCurrentPosition then
            local pos = p.scanner:TokenFullStart()
            p:parseErrorAt(pos, pos, diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, p.scanner:TokenText())
        else
            p:parseErrorAtCurrentToken(diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, p.scanner:TokenText())
        end
    else
        if reportAtCurrentPosition then
            local pos = p.scanner:TokenFullStart()
            p:parseErrorAt(pos, pos, diagnostics.Identifier_expected)
        else
            p:parseErrorAtCurrentToken(diagnostics.Identifier_expected)
        end
    end
    return p:createMissingIdentifier()
end

function Parser:newNodeList(loc, nodes)
    local list = self.factory:NewNodeList(nodes or {})
    list.loc = loc
    return list
end

function Parser:newModifierList(loc, nodes)
    local list = self.factory:NewModifierList(nodes or {})
    list.loc = loc
    return list
end

function Parser:finishNode(node, pos)
    return self:finishNodeWithEnd(node, pos, self:nodePos())
end

function Parser:finishNodeWithEnd(node, pos, end_)
    node.loc = core.NewTextRange(pos, end_)
    node.flags = node.flags | self.contextFlags
    if self.hasParseError then
        node.flags = node.flags | NodeFlags.ThisNodeHasError
        self.hasParseError = false
    end
    self:overrideParentInImmediateChildren(node)
    return node
end

function Parser:overrideParentInImmediateChildren(node)
    self.currentParent = node
    node:ForEachChild(self.setParentFromContext)
    self.currentParent = nil
end

local function kindSet(...)
    local s = {}
    for _, k in ipairs({ ... }) do
        s[k] = true
    end
    return s
end

function Parser:nextTokenIsSlash()
    return self:nextToken() == Kind.SlashToken
end

function Parser:scanTypeMemberStart()
    local p = self
    -- Return true if we have the start of a signature member
    if p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken or p.token == Kind.GetKeyword or p.token == Kind.SetKeyword then
        return true
    end
    local idToken = false
    -- Eat up all modifiers, but hold on to the last one in case it is actually an identifier
    while ast.IsModifierKind(p.token) do
        idToken = true
        p:nextToken()
    end
    -- Index signatures and computed property names are type members
    if p.token == Kind.OpenBracketToken then
        return true
    end
    -- Try to get the first property-like token following all modifiers
    if p:isLiteralPropertyName() then
        idToken = true
        p:nextToken()
    end
    -- If we were able to get any potential identifier, check that it is
    -- the start of a member declaration
    if idToken then
        return p.token == Kind.OpenParenToken or p.token == Kind.LessThanToken or p.token == Kind.QuestionToken or p.token == Kind.ColonToken or p.token == Kind.CommaToken or p:canParseSemicolon()
    end
    return false
end

local classMemberStartAfterKeyword = kindSet(
    Kind.OpenParenToken, -- Method declaration
    Kind.LessThanToken, -- Generic Method declaration
    Kind.ExclamationToken, -- Non-null assertion on property name
    Kind.ColonToken, -- Type Annotation for declaration
    Kind.EqualsToken, -- Initializer for declaration
    Kind.QuestionToken -- Not valid, but permitted so that it gets caught later on.
)

function Parser:scanClassMemberStart()
    local p = self
    local idToken = Kind.Unknown
    if p.token == Kind.AtToken then
        return true
    end
    -- Eat up all modifiers, but hold on to the last one in case it is actually an identifier.
    while ast.IsModifierKind(p.token) do
        idToken = p.token
        -- If the idToken is a class modifier (protected, private, public, and static), it is
        -- certain that we are starting to parse class member. This allows better error recovery
        -- Example:
        --      public foo() ...     // true
        --      public @dec blah ... // true; we will then report an error later
        --      export public ...    // true; we will then report an error later
        if ast.IsClassMemberModifier(idToken) then
            return true
        end
        p:nextToken()
    end
    if p.token == Kind.AsteriskToken then
        return true
    end
    -- Try to get the first property-like token following all modifiers.
    -- This can either be an identifier or the 'get' or 'set' keywords.
    if p:isLiteralPropertyName() then
        idToken = p.token
        p:nextToken()
    end
    -- Index signatures and computed properties are class members; we can parse.
    if p.token == Kind.OpenBracketToken then
        return true
    end
    -- If we were able to get any potential identifier...
    if idToken ~= Kind.Unknown then
        -- If we have a non-keyword identifier, or if we have an accessor, then it's safe to parse.
        if not ast.IsKeyword(idToken) or idToken == Kind.SetKeyword or idToken == Kind.GetKeyword then
            return true
        end
        -- If it *is* a keyword, but not an accessor, check a little farther along
        -- to see if it should actually be parsed as a class member.
        if classMemberStartAfterKeyword[p.token] then
            return true
        end
        -- Covers
        --  - Semicolons     (declaration termination)
        --  - Closing braces (end-of-class, must be declaration)
        --  - End-of-files   (not valid, but permitted so that it gets caught later on)
        --  - Line-breaks    (enabling *automatic semicolon insertion*)
        return p:canParseSemicolon()
    end
    return false
end

function Parser:canParseSemicolon()
    -- If there's a real semicolon, then we can always parse it out.
    -- We can parse out an optional semicolon in ASI cases in the following cases.
    return self.token == Kind.SemicolonToken or self.token == Kind.CloseBraceToken or self.token == Kind.EndOfFile or self:hasPrecedingLineBreak()
end

function Parser:tryParseSemicolon()
    if not self:canParseSemicolon() then
        return false
    end
    if self.token == Kind.SemicolonToken then
        -- consume the semicolon if it was explicitly provided.
        self:nextToken()
    end
    return true
end

function Parser:parseSemicolon()
    return self:tryParseSemicolon() or self:parseExpected(Kind.SemicolonToken)
end

function Parser:isLiteralPropertyName()
    local t = self.token
    return parser.tokenIsIdentifierOrKeyword(t) or t == Kind.StringLiteral or t == Kind.NumericLiteral or t == Kind.BigIntLiteral
end

-- 'catch' and 'finally' do not actually indicate that the code is part of a statement,
-- however, we say they are here so that we may gracefully parse them and error later.
local startOfStatementAlways = kindSet(Kind.AtToken, Kind.SemicolonToken, Kind.OpenBraceToken, Kind.VarKeyword, Kind.LetKeyword,
    Kind.UsingKeyword, Kind.FunctionKeyword, Kind.ClassKeyword, Kind.EnumKeyword, Kind.IfKeyword,
    Kind.DoKeyword, Kind.WhileKeyword, Kind.ForKeyword, Kind.ContinueKeyword, Kind.BreakKeyword,
    Kind.ReturnKeyword, Kind.WithKeyword, Kind.SwitchKeyword, Kind.ThrowKeyword, Kind.TryKeyword,
    Kind.DebuggerKeyword, Kind.CatchKeyword, Kind.FinallyKeyword)
local startOfStatementIdentifierLike = kindSet(Kind.AsyncKeyword, Kind.DeclareKeyword, Kind.InterfaceKeyword, Kind.ModuleKeyword, Kind.NamespaceKeyword,
    Kind.TypeKeyword, Kind.GlobalKeyword, Kind.DeferKeyword)
local startOfStatementModifierLike = kindSet(Kind.AccessorKeyword, Kind.PublicKeyword, Kind.PrivateKeyword, Kind.ProtectedKeyword, Kind.StaticKeyword,
    Kind.ReadonlyKeyword)

function Parser:isStartOfStatement()
    local p = self
    local t = p.token
    if startOfStatementAlways[t] then
        return true
    elseif t == Kind.ImportKeyword then
        return p:isStartOfDeclaration() or p:isNextTokenOpenParenOrLessThanOrDot()
    elseif t == Kind.ConstKeyword or t == Kind.ExportKeyword then
        return p:isStartOfDeclaration()
    elseif startOfStatementIdentifierLike[t] then
        -- When these don't start a declaration, they're an identifier in an expression statement
        return true
    elseif startOfStatementModifierLike[t] then
        -- When these don't start a declaration, they may be the start of a class member if an identifier
        -- immediately follows. Otherwise they're an identifier in an expression statement.
        return p:isStartOfDeclaration() or not p:lookAhead(Parser.nextTokenIsIdentifierOrKeywordOnSameLine)
    end
    return p:isStartOfExpression()
end

function Parser:isStartOfDeclaration()
    return self:lookAhead(Parser.scanStartOfDeclaration)
end

function Parser:scanStartOfDeclaration()
    local p = self
    while true do
        local t = p.token
        if t == Kind.VarKeyword or t == Kind.LetKeyword or t == Kind.ConstKeyword or t == Kind.FunctionKeyword or t == Kind.ClassKeyword or
            t == Kind.EnumKeyword then
            return true
        elseif t == Kind.UsingKeyword then
            return p:isUsingDeclaration()
        elseif t == Kind.AwaitKeyword then
            return p:isAwaitUsingDeclaration()
        -- 'declare', 'module', 'namespace', 'interface'* and 'type' are all legal JavaScript identifiers;
        -- however, an identifier cannot be followed by another identifier on the same line. This is what we
        -- count on to parse out the respective declarations. For instance, we exploit this to say that
        --
        --    namespace n
        --
        -- can be none other than the beginning of a namespace declaration, but need to respect that JavaScript sees
        --
        --    namespace
        --    n
        --
        -- as the identifier 'namespace' on one line followed by the identifier 'n' on another.
        -- We need to look one token ahead to see if it permissible to try parsing a declaration.
        --
        -- *Note*: 'interface' is actually a strict mode reserved word. So while
        --
        --   "use strict"
        --   interface
        --   I {}
        --
        -- could be legal, it would add complexity for very little gain.
        elseif t == Kind.InterfaceKeyword or t == Kind.TypeKeyword or t == Kind.DeferKeyword then
            return p:nextTokenIsIdentifierOnSameLine()
        elseif t == Kind.ModuleKeyword or t == Kind.NamespaceKeyword then
            return p:nextTokenIsIdentifierOrStringLiteralOnSameLine()
        elseif t == Kind.AbstractKeyword or t == Kind.AccessorKeyword or t == Kind.AsyncKeyword or t == Kind.DeclareKeyword or t == Kind.PrivateKeyword or
            t == Kind.ProtectedKeyword or t == Kind.PublicKeyword or t == Kind.ReadonlyKeyword then
            local previousToken = p.token
            p:nextToken()
            -- ASI takes effect for this modifier.
            if p:hasPrecedingLineBreak() then
                return false
            end
            if previousToken == Kind.DeclareKeyword and p.token == Kind.TypeKeyword then
                -- If we see 'declare type', then commit to parsing a type alias. parseTypeAliasDeclaration will
                -- report Line_break_not_permitted_here if needed.
                return true
            end
            goto continue
        elseif t == Kind.GlobalKeyword then
            p:nextToken()
            return p.token == Kind.OpenBraceToken or p.token == Kind.Identifier or p.token == Kind.ExportKeyword
        elseif t == Kind.ImportKeyword then
            p:nextToken()
            return p.token == Kind.DeferKeyword or p.token == Kind.StringLiteral or p.token == Kind.AsteriskToken or p.token == Kind.OpenBraceToken or parser.tokenIsIdentifierOrKeyword(p.token)
        elseif t == Kind.ExportKeyword then
            p:nextToken()
            if p.token == Kind.EqualsToken or p.token == Kind.AsteriskToken or p.token == Kind.OpenBraceToken or
                p.token == Kind.DefaultKeyword or p.token == Kind.AsKeyword or p.token == Kind.AtToken then
                return true
            end
            if p.token == Kind.TypeKeyword then
                p:nextToken()
                return p.token == Kind.AsteriskToken or p.token == Kind.OpenBraceToken or p:isIdentifier() and not p:hasPrecedingLineBreak()
            end
            goto continue
        elseif t == Kind.StaticKeyword then
            p:nextToken()
            goto continue
        end
        do
            return false
        end
        ::continue::
    end
end

local startOfExpressionTokens = kindSet(Kind.PlusToken, Kind.MinusToken, Kind.TildeToken, Kind.ExclamationToken, Kind.DeleteKeyword,
    Kind.TypeOfKeyword, Kind.VoidKeyword, Kind.PlusPlusToken, Kind.MinusMinusToken, Kind.LessThanToken,
    Kind.AwaitKeyword, Kind.YieldKeyword, Kind.PrivateIdentifier, Kind.AtToken)

function Parser:isStartOfExpression()
    if self:isStartOfLeftHandSideExpression() then
        return true
    end
    if startOfExpressionTokens[self.token] then
        -- Yield/await always starts an expression.  Either it is an identifier (in which case
        -- it is definitely an expression).  Or it's a keyword (either because we're in
        -- a generator or async function, or in strict mode (or both)) and it started a yield or await expression.
        return true
    end
    -- Error tolerance.  If we see the start of some binary operator, we consider
    -- that the start of an expression.  That way we'll parse out a missing identifier,
    -- give a good message about an identifier being missing, and then consume the
    -- rest of the binary expression.
    if self:isBinaryOperator() then
        return true
    end
    return self:isIdentifier()
end

local startOfLeftHandSideExpressionTokens = kindSet(Kind.ThisKeyword, Kind.SuperKeyword, Kind.NullKeyword, Kind.TrueKeyword, Kind.FalseKeyword,
    Kind.NumericLiteral, Kind.BigIntLiteral, Kind.StringLiteral, Kind.NoSubstitutionTemplateLiteral, Kind.TemplateHead,
    Kind.OpenParenToken, Kind.OpenBracketToken, Kind.OpenBraceToken, Kind.FunctionKeyword, Kind.ClassKeyword,
    Kind.NewKeyword, Kind.SlashToken, Kind.SlashEqualsToken, Kind.Identifier)

function Parser:isStartOfLeftHandSideExpression()
    if startOfLeftHandSideExpressionTokens[self.token] then
        return true
    elseif self.token == Kind.ImportKeyword then
        return self:isNextTokenOpenParenOrLessThanOrDot()
    end
    return self:isIdentifier()
end

local startOfTypeTokens = kindSet(Kind.AnyKeyword, Kind.UnknownKeyword, Kind.StringKeyword, Kind.NumberKeyword, Kind.BigIntKeyword,
    Kind.BooleanKeyword, Kind.ReadonlyKeyword, Kind.SymbolKeyword, Kind.UniqueKeyword, Kind.VoidKeyword,
    Kind.UndefinedKeyword, Kind.NullKeyword, Kind.ThisKeyword, Kind.TypeOfKeyword, Kind.NeverKeyword,
    Kind.OpenBraceToken, Kind.OpenBracketToken, Kind.LessThanToken, Kind.BarToken, Kind.AmpersandToken,
    Kind.NewKeyword, Kind.StringLiteral, Kind.NumericLiteral, Kind.BigIntLiteral, Kind.TrueKeyword,
    Kind.FalseKeyword, Kind.ObjectKeyword, Kind.AsteriskToken, Kind.QuestionToken, Kind.ExclamationToken,
    Kind.DotDotDotToken, Kind.InferKeyword, Kind.ImportKeyword, Kind.AssertsKeyword, Kind.NoSubstitutionTemplateLiteral,
    Kind.TemplateHead)

function Parser:isStartOfType(inStartOfParameter)
    local t = self.token
    if startOfTypeTokens[t] then
        return true
    elseif t == Kind.FunctionKeyword then
        return not inStartOfParameter
    elseif t == Kind.MinusToken then
        return not inStartOfParameter and self:lookAhead(Parser.nextTokenIsNumericOrBigIntLiteral)
    elseif t == Kind.OpenParenToken then
        -- Only consider '(' the start of a type if followed by ')', '...', an identifier, a modifier,
        -- or something that starts a type. We don't want to consider things like '(1)' a type.
        return not inStartOfParameter and self:lookAhead(Parser.nextIsParenthesizedOrFunctionType)
    end
    return self:isIdentifier()
end

function Parser:nextTokenIsNumericOrBigIntLiteral()
    self:nextToken()
    return self.token == Kind.NumericLiteral or self.token == Kind.BigIntLiteral
end

function Parser:nextIsParenthesizedOrFunctionType()
    self:nextToken()
    return self.token == Kind.CloseParenToken or self:isStartOfParameter(false --[[isJSDocParameter]]) or self:isStartOfType(false --[[inStartOfParameter]])
end

function Parser:isStartOfParameter(isJSDocParameter)
    return self.token == Kind.DotDotDotToken or
        self:isBindingIdentifierOrPrivateIdentifierOrPattern() or
        ast.IsModifierKind(self.token) or
        self.token == Kind.AtToken or
        self:isStartOfType(not isJSDocParameter --[[inStartOfParameter]])
end

function Parser:isBindingIdentifierOrPrivateIdentifierOrPattern()
    local t = self.token
    return t == Kind.OpenBraceToken or t == Kind.OpenBracketToken or t == Kind.PrivateIdentifier or self:isBindingIdentifier()
end

function Parser:isNextTokenOpenParenOrLessThanOrDot()
    return self:lookAhead(Parser.nextTokenIsOpenParenOrLessThanOrDot)
end

function Parser:nextTokenIsOpenParenOrLessThanOrDot()
    local t = self:nextToken()
    if t == Kind.OpenParenToken or t == Kind.LessThanToken or t == Kind.DotToken then
        return true
    end
    return false
end

function Parser:nextTokenIsIdentifierOnSameLine()
    self:nextToken()
    return self:isIdentifier() and not self:hasPrecedingLineBreak()
end

function Parser:nextTokenIsIdentifierOrStringLiteralOnSameLine()
    self:nextToken()
    return (self:isIdentifier() or self.token == Kind.StringLiteral) and not self:hasPrecedingLineBreak()
end

-- Ignore strict mode flag because we will report an error in type checker instead.
function Parser:isIdentifier()
    local t = self.token
    if t == Kind.Identifier then
        return true
    end
    -- If we have a 'yield' keyword, and we're in the [yield] context, then 'yield' is
    -- considered a keyword and is not an identifier.
    -- If we have a 'await' keyword, and we're in the [Await] context, then 'await' is
    -- considered a keyword and is not an identifier.
    if t == Kind.YieldKeyword and self:inYieldContext() or t == Kind.AwaitKeyword and self:inAwaitContext() then
        return false
    end
    return t > Kind.LastReservedWord
end

function Parser:isBindingIdentifier()
    -- `let await`/`let yield` in [Yield] or [Await] are allowed here and disallowed in the binder.
    return self.token == Kind.Identifier or self.token > Kind.LastReservedWord
end

function Parser:isImportAttributeName()
    return parser.tokenIsIdentifierOrKeyword(self.token) or self.token == Kind.StringLiteral
end

function Parser:isBinaryOperator()
    if self:inDisallowInContext() and self.token == Kind.InKeyword then
        return false
    end
    return ast.GetBinaryOperatorPrecedence(self.token) ~= ast.OperatorPrecedence.Invalid
end

function Parser:isValidHeritageClauseObjectLiteral()
    return self:lookAhead(Parser.nextIsValidHeritageClauseObjectLiteral)
end

function Parser:nextIsValidHeritageClauseObjectLiteral()
    if self:nextToken() == Kind.CloseBraceToken then
        -- if we see "extends {}" then only treat the {} as what we're extending (and not
        -- the class body) if we have:
        --
        --      extends {} {
        --      extends {},
        --      extends {} extends
        --      extends {} implements
        local next_ = self:nextToken()
        return next_ == Kind.CommaToken or next_ == Kind.OpenBraceToken or next_ == Kind.ExtendsKeyword or next_ == Kind.ImplementsKeyword
    end
    return true
end

function Parser:isHeritageClause()
    return self.token == Kind.ExtendsKeyword or self.token == Kind.ImplementsKeyword
end

function Parser:isHeritageClauseExtendsOrImplementsKeyword()
    return self:isHeritageClause() and self:lookAhead(Parser.nextIsStartOfExpression)
end

function Parser:nextIsStartOfExpression()
    self:nextToken()
    return self:isStartOfExpression()
end

function Parser:isUsingDeclaration()
    -- 'using' always starts a lexical declaration if followed by an identifier. We also eagerly parse
    -- |ObjectBindingPattern| so that we can report a grammar error during check. We don't parse out
    -- |ArrayBindingPattern| since it potentially conflicts with element access (i.e., `using[x]`).
    return self:lookAhead(function(p)
        return p:nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine(false --[[disallowOf]])
    end)
end

function Parser:nextTokenIsEqualsOrSemicolonOrColonToken()
    self:nextToken()
    return self.token == Kind.EqualsToken or self.token == Kind.SemicolonToken or self.token == Kind.ColonToken
end

function Parser:nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine(disallowOf)
    self:nextToken()
    if disallowOf and self.token == Kind.OfKeyword then
        return self:lookAhead(Parser.nextTokenIsEqualsOrSemicolonOrColonToken)
    end
    return (self:isBindingIdentifier() or self.token == Kind.OpenBraceToken) and not self:hasPrecedingLineBreak()
end

function Parser:nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLineDisallowOf()
    return self:nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine(true --[[disallowOf]])
end

function Parser:isAwaitUsingDeclaration()
    return self:lookAhead(Parser.nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine)
end

function Parser:nextIsUsingKeywordThenBindingIdentifierOrStartOfObjectDestructuringOnSameLine()
    return self:nextToken() == Kind.UsingKeyword and self:nextTokenIsBindingIdentifierOrStartOfDestructuringOnSameLine(false --[[disallowOf]])
end

function Parser:nextTokenIsTokenStringLiteral()
    return self:nextToken() == Kind.StringLiteral
end

function Parser:setContextFlags(flags, value)
    if value then
        self.contextFlags = self.contextFlags | flags
    else
        self.contextFlags = self.contextFlags & ~flags
    end
end

function parser.doInContext(p, flags, value, f)
    local saveContextFlags = p.contextFlags
    p:setContextFlags(flags, value)
    local result = f(p)
    p.contextFlags = saveContextFlags
    return result
end

function Parser:inYieldContext()
    return self.contextFlags & NodeFlags.YieldContext ~= 0
end

function Parser:inDisallowInContext()
    return self.contextFlags & NodeFlags.DisallowInContext ~= 0
end

function Parser:inDisallowConditionalTypesContext()
    return self.contextFlags & NodeFlags.DisallowConditionalTypesContext ~= 0
end

function Parser:inDecoratorContext()
    return self.contextFlags & NodeFlags.DecoratorContext ~= 0
end

function Parser:inAwaitContext()
    return self.contextFlags & NodeFlags.AwaitContext ~= 0
end

function Parser:skipRangeTrivia(textRange)
    return core.NewTextRange(scanner.SkipTrivia(self.sourceText, textRange:Pos()), textRange:End())
end

function parser.isReservedWord(token)
    return Kind.FirstReservedWord <= token and token <= Kind.LastReservedWord
end

function parser.attachFileToDiagnostics(diags, file)
    for _, d in ipairs(diags) do
        d:SetFile(file)
        for _, r in ipairs(d:RelatedInformation() or {}) do
            r:SetFile(file)
        end
    end
    return diags
end

-- Stable sort (Go slices.SortFunc with a total order is deterministic; keep ties in input order).
function parser.sortFunc(xs, cmp)
    local n = #xs
    for i = 2, n do
        local x = xs[i]
        local j = i - 1
        while j >= 1 and cmp(xs[j], x) > 0 do
            xs[j + 1] = xs[j]
            j = j - 1
        end
        xs[j + 1] = x
    end
end

function parser.getCommentPragmas(f, sourceText)
    local pragmas = nil
    for commentRange in scanner.GetLeadingCommentRanges(f, sourceText, 0) do
        local comment = string.sub(sourceText, commentRange:Pos() + 1, commentRange:End())
        pragmas = parser.appendAll(pragmas, parser.extractPragmas(commentRange, comment))
    end
    return pragmas
end

function parser.extractPragmas(commentRange, text)
    if commentRange.kind == Kind.SingleLineCommentTrivia then
        local pos = 2
        local tripleSlash = parser.match(text, pos, "/")
        if tripleSlash then
            pos = pos + 1
        end
        pos = parser.skipBlanks(text, pos)
        if tripleSlash and parser.match(text, pos, "<") then
            local tagName = parser.extractName(text, pos + 1)
            if tagName ~= "reference" then
                return nil
            end
            pos = pos + 10
            local args = {}
            while true do
                pos = parser.skipBlanks(text, pos)
                if parser.match(text, pos, "/>") then
                    break
                end
                local argName = parser.extractName(text, pos)
                if argName == "" then
                    break
                end
                pos = parser.skipBlanks(text, pos + #argName)
                if not parser.match(text, pos, "=") then
                    break
                end
                pos = parser.skipBlanks(text, pos + 1)
                local value, ok = parser.extractQuotedString(text, pos)
                if not ok then
                    break
                end
                args[argName] = ast.NewPragmaArgument(commentRange:Pos() + pos + 1, commentRange:Pos() + pos + 1 + #value, argName, value)
                pos = pos + #value + 2
            end
            return { ast.NewPragma(commentRange, "reference", args) }
        end
        if parser.match(text, pos, "@") then
            pos = pos + 1
            local pragmaName = parser.extractName(text, pos)
            if not (pragmaName == "ts-check" or pragmaName == "ts-nocheck") then
                return nil
            end
            return { ast.NewPragma(commentRange, pragmaName, nil) }
        end
    end
    if commentRange.kind == Kind.MultiLineCommentTrivia then
        if #text >= 2 and string.sub(text, -2) == "*/" then
            text = string.sub(text, 1, #text - 2)
        end
        local pos = 2
        local pragmas = nil
        while true do
            pos = parser.skipTo(text, pos, "@")
            if pos < 0 then
                break
            end
            -- Mirrors the /@(\S+)(\s+(?:\S.*)?)?$/gm pragma regex used by TypeScript: the '@'
            -- must be immediately followed by a non-whitespace pragma name, and the remainder
            -- of the line is consumed as that pragma's arguments. As a consequence, only the
            -- first '@'-token on a line is considered, so an unrelated '@token' earlier on the
            -- line (e.g. an email address) prevents a later '@jsx' on the same line from being
            -- treated as a pragma.
            local namePos = pos + 1
            local nameEnd = parser.skipNonBlanks(text, namePos)
            if nameEnd == namePos then
                pos = pos + 1
                goto continue
            end
            do
                local lineEnd = parser.lineEndPos(text, pos)
                local pragmaName = stringutil.StringsToLower(string.sub(text, namePos + 1, nameEnd))
                if pragmaName == "jsx" or pragmaName == "jsxfrag" or pragmaName == "jsximportsource" or pragmaName == "jsxruntime" then
                    local start = parser.skipBlanks(text, nameEnd)
                    local argEnd = parser.skipNonBlanks(text, start)
                    if argEnd ~= start then
                        local args = {}
                        args["factory"] = ast.NewPragmaArgument(commentRange:Pos() + start, commentRange:Pos() + argEnd, "factory", string.sub(text, start + 1, argEnd))
                        pragmas = parser.append(pragmas, ast.NewPragma(commentRange, pragmaName, args))
                    end
                end
                pos = lineEnd
            end
            ::continue::
        end
        return pragmas
    end
    return nil
end

function parser.match(text, pos, s)
    return string.sub(text, pos + 1, pos + #s) == s
end

function parser.skipBlanks(text, pos)
    while pos < #text do
        local c = string.byte(text, pos + 1)
        if c ~= 32 and c ~= 9 then
            break
        end
        pos = pos + 1
    end
    return pos
end

function parser.skipNonBlanks(text, pos)
    while pos < #text do
        local c = string.byte(text, pos + 1)
        if c == 32 or c == 9 or c == 13 or c == 10 then
            break
        end
        pos = pos + 1
    end
    return pos
end

function parser.skipTo(text, pos, s)
    if pos >= #text then
        return -1
    end
    local i = string.find(text, s, pos + 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

function parser.lineEndPos(text, pos)
    while pos < #text do
        local ch, size = stringutil.DecodeRune(text, pos)
        if stringutil.IsLineBreak(ch) then
            return pos
        end
        pos = pos + size
    end
    return #text
end

function parser.extractName(text, pos)
    local start = pos
    while pos < #text do
        local c = string.byte(text, pos + 1)
        if not (c >= 65 and c <= 90 or c >= 97 and c <= 122 or c == 45) then
            break
        end
        pos = pos + 1
    end
    return string.lower(string.sub(text, start + 1, pos))
end

function parser.extractQuotedString(text, pos)
    if pos == #text then
        return "", false
    end
    local quote = string.byte(text, pos + 1)
    if quote ~= 39 and quote ~= 34 then
        return "", false
    end
    pos = pos + 1
    local start = pos
    while pos < #text and string.byte(text, pos + 1) ~= quote do
        pos = pos + 1
    end
    if pos == #text then
        return "", false
    end
    return string.sub(text, start + 1, pos), true
end

function Parser:processPragmasIntoFields(context)
    local p = self
    context.checkJsDirective = nil
    context.referencedFiles = nil
    context.typeReferenceDirectives = nil
    context.libReferenceDirectives = nil
    -- context.AmdDependencies = nil
    for _, pragma in ipairs(context.pragmas or {}) do
        local name = pragma.name
        if name == "reference" then
            local args = pragma.args or {}
            local types = args["types"]
            local lib = args["lib"]
            local path = args["path"]
            local resolutionMode = args["resolution-mode"]
            local preserve = args["preserve"]
            local noDefaultLib = args["no-default-lib"]
            local preserveValue = preserve ~= nil and preserve.value == "true"
            if noDefaultLib ~= nil and noDefaultLib.value == "true" then
                -- Ignored.
            elseif types ~= nil then
                local parsed = core.ModuleKind.ResolutionModeNone
                if resolutionMode ~= nil then
                    parsed = p:parseResolutionMode(resolutionMode.value, resolutionMode:Pos(), resolutionMode:End())
                end
                context.typeReferenceDirectives = parser.append(context.typeReferenceDirectives, ast.NewFileReference(types.pos, types.end_, types.value, parsed, preserveValue))
            elseif lib ~= nil then
                context.libReferenceDirectives = parser.append(context.libReferenceDirectives, ast.NewFileReference(lib.pos, lib.end_, lib.value, core.ModuleKind.ResolutionModeNone, preserveValue))
            elseif path ~= nil then
                context.referencedFiles = parser.append(context.referencedFiles, ast.NewFileReference(path.pos, path.end_, path.value, core.ModuleKind.ResolutionModeNone, preserveValue))
            else
                p:parseErrorAtRange(core.NewTextRange(pragma.pos, pragma.end_), diagnostics.Invalid_reference_directive_syntax)
            end
        elseif name == "ts-check" or name == "ts-nocheck" then
            -- _last_ of either nocheck or check in a file is the "winner"
            if context.checkJsDirective == nil or pragma.pos > context.checkJsDirective.range:Pos() then
                context.checkJsDirective = {
                    enabled = name == "ts-check",
                    range = ast.NewCommentRangeValue(pragma.kind, pragma.pos, pragma.end_, pragma.hasTrailingNewLine),
                }
            end
        elseif name == "jsx" or name == "jsxfrag" or name == "jsximportsource" or name == "jsxruntime" then
            -- Nothing to do here
        else
            error("Unhandled pragma kind: " .. name, 0)
        end
    end
end

function Parser:parseResolutionMode(mode, pos, end_)
    if mode == "import" then
        return core.ModuleKind.ESNext
    end
    if mode == "require" then
        return core.ModuleKind.CommonJS
    end
    self:parseErrorAt(pos, end_, diagnostics.X_resolution_mode_should_be_either_require_or_import)
    return core.ModuleKind.ResolutionModeNone
end

function Parser:jsErrorAtRange(loc, message, ...)
    self.jsDiagnostics[#self.jsDiagnostics + 1] = ast.NewDiagnostic(nil, core.NewTextRange(scanner.SkipTrivia(self.sourceText, loc:Pos()), loc:End()), message, ...)
end

local function isDefaultKeywordModifier(m)
    return m.kind == Kind.DefaultKeyword
end

function Parser:checkJSDecoratorSyntax(node)
    local p = self
    local modifiers = node:ModifierNodes()
    if modifiers == nil or #modifiers == 0 then
        return
    end

    if ast.CanHaveIllegalDecorators(node) then
        for _, modifier in ipairs(modifiers) do
            if ast.IsDecorator(modifier) then
                p:jsErrorAtRange(modifier.loc, diagnostics.Decorators_are_not_valid_here)
                break
            end
        end
    elseif ast.CanHaveDecorators(node) then
        local decoratorIndex = core.FindIndex(modifiers, ast.IsDecorator)
        if decoratorIndex >= 0 then
            if ast.IsClassDeclaration(node) then
                local exportIndex = core.FindIndex(modifiers, parser.isExportModifier)
                if exportIndex >= 0 then
                    local defaultIndex = core.FindIndex(modifiers, isDefaultKeywordModifier)
                    if decoratorIndex > exportIndex and defaultIndex >= 0 and decoratorIndex < defaultIndex then
                        -- Decorator between `export` and `default`
                        p:jsErrorAtRange(modifiers[decoratorIndex + 1].loc, diagnostics.Decorators_are_not_valid_here)
                    elseif decoratorIndex < exportIndex then
                        -- Find a trailing decorator after the export keyword
                        local trailingDecoratorIndex = -1
                        for i = exportIndex, #modifiers - 1 do
                            if ast.IsDecorator(modifiers[i + 1]) then
                                trailingDecoratorIndex = i
                                break
                            end
                        end
                        if trailingDecoratorIndex >= 0 then
                            local trailing = modifiers[trailingDecoratorIndex + 1]
                            local leading = modifiers[decoratorIndex + 1]
                            local diag = ast.NewDiagnostic(
                                nil,
                                core.NewTextRange(scanner.SkipTrivia(p.sourceText, trailing.loc:Pos()), trailing.loc:End()),
                                diagnostics.Decorators_may_not_appear_after_export_or_export_default_if_they_also_appear_before_export
                            )
                            diag:AddRelatedInfo(ast.NewDiagnostic(
                                nil,
                                core.NewTextRange(scanner.SkipTrivia(p.sourceText, leading.loc:Pos()), leading.loc:End()),
                                diagnostics.Decorator_used_before_export_here
                            ))
                            p.jsDiagnostics[#p.jsDiagnostics + 1] = diag
                        end
                    end
                end
            end
        end
    end
end

local function isNotReparsed(n)
    return n.flags & NodeFlags.Reparsed == 0
end

local jsCheckFunctionLikeKinds = {
    [Kind.MethodSignature] = true, [Kind.Constructor] = true, [Kind.GetAccessor] = true, [Kind.SetAccessor] = true,
    [Kind.FunctionExpression] = true, [Kind.FunctionDeclaration] = true, [Kind.ArrowFunction] = true,
    [Kind.VariableDeclaration] = true, [Kind.IndexSignature] = true,
}
local jsCheckTypeParameterKinds = {
    [Kind.ClassDeclaration] = true, [Kind.ClassExpression] = true, [Kind.MethodDeclaration] = true, [Kind.Constructor] = true,
    [Kind.GetAccessor] = true, [Kind.SetAccessor] = true, [Kind.FunctionExpression] = true, [Kind.FunctionDeclaration] = true,
    [Kind.ArrowFunction] = true,
}
local jsCheckTypeArgumentKinds = {
    [Kind.CallExpression] = true, [Kind.NewExpression] = true, [Kind.ExpressionWithTypeArguments] = true,
    [Kind.JsxSelfClosingElement] = true, [Kind.JsxOpeningElement] = true, [Kind.TaggedTemplateExpression] = true,
}

function Parser:checkJSSyntax(node)
    local p = self
    if node.flags & NodeFlags.JavaScriptFile == 0 or node.flags & (NodeFlags.JSDoc | NodeFlags.Reparsed) ~= 0 then
        return node
    end
    local k = node.kind
    if k == Kind.Parameter or k == Kind.PropertyDeclaration or k == Kind.MethodDeclaration or jsCheckFunctionLikeKinds[k] then
        if k == Kind.Parameter or k == Kind.PropertyDeclaration or k == Kind.MethodDeclaration then
            local token = node:QuestionToken()
            if token ~= nil and token.flags & NodeFlags.Reparsed == 0 and ast.IsQuestionToken(token) then
                p:jsErrorAtRange(token.loc, diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files, "?")
            end
        end
        local t
        if ast.IsFunctionLike(node) and node:Body() == nil then
            p:jsErrorAtRange(node.loc, diagnostics.Signature_declarations_can_only_be_used_in_TypeScript_files)
        else
            t = node:Type()
            if t ~= nil and t.flags & NodeFlags.Reparsed == 0 then
                p:jsErrorAtRange(t.loc, diagnostics.Type_annotations_can_only_be_used_in_TypeScript_files)
            end
        end
    elseif k == Kind.ImportDeclaration then
        local clause = node:ImportClause()
        if clause ~= nil and clause:IsTypeOnly() then
            p:jsErrorAtRange(node.loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "import type")
        end
    elseif k == Kind.ExportDeclaration then
        if node:IsTypeOnly() then
            p:jsErrorAtRange(node.loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "export type")
        end
    elseif k == Kind.ImportSpecifier then
        if node:IsTypeOnly() then
            p:jsErrorAtRange(node.loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "import...type")
        end
    elseif k == Kind.ExportSpecifier then
        if node:IsTypeOnly() then
            p:jsErrorAtRange(node.loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "export...type")
        end
    elseif k == Kind.ImportEqualsDeclaration then
        p:jsErrorAtRange(node.loc, diagnostics.X_import_can_only_be_used_in_TypeScript_files)
    elseif k == Kind.ExportAssignment then
        if node:AsExportAssignment().isExportEquals then
            p:jsErrorAtRange(node.loc, diagnostics.X_export_can_only_be_used_in_TypeScript_files)
        end
    elseif k == Kind.HeritageClause then
        if node:AsHeritageClause().token == Kind.ImplementsKeyword then
            p:jsErrorAtRange(node.loc, diagnostics.X_implements_clauses_can_only_be_used_in_TypeScript_files)
        end
    elseif k == Kind.InterfaceDeclaration then
        p:jsErrorAtRange(node:Name().loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "interface")
    elseif k == Kind.ModuleDeclaration then
        p:jsErrorAtRange(node:Name().loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, scanner.TokenToString(node:AsModuleDeclaration().keyword))
    elseif k == Kind.TypeAliasDeclaration then
        p:jsErrorAtRange(node:Name().loc, diagnostics.Type_aliases_can_only_be_used_in_TypeScript_files)
    elseif k == Kind.EnumDeclaration then
        p:jsErrorAtRange(node:Name().loc, diagnostics.X_0_declarations_can_only_be_used_in_TypeScript_files, "enum")
    elseif k == Kind.NonNullExpression then
        p:jsErrorAtRange(node.loc, diagnostics.Non_null_assertions_can_only_be_used_in_TypeScript_files)
    elseif k == Kind.AsExpression then
        p:jsErrorAtRange(node:Type().loc, diagnostics.Type_assertion_expressions_can_only_be_used_in_TypeScript_files)
    elseif k == Kind.SatisfiesExpression then
        p:jsErrorAtRange(node:Type().loc, diagnostics.Type_satisfaction_expressions_can_only_be_used_in_TypeScript_files)
    end
    -- Check decorator placement in JS files
    p:checkJSDecoratorSyntax(node)
    -- Check absence of type parameters, type arguments and non-JavaScript modifiers
    if jsCheckTypeParameterKinds[k] or k == Kind.VariableStatement or k == Kind.PropertyDeclaration then
        if jsCheckTypeParameterKinds[k] then
            local list = node:TypeParameterList()
            if list ~= nil and core.Some(list.nodes, isNotReparsed) then
                p:jsErrorAtRange(list.loc, diagnostics.Type_parameter_declarations_can_only_be_used_in_TypeScript_files)
            end
        end
        for _, modifier in ipairs(node:ModifierNodes() or {}) do
            if modifier.flags & NodeFlags.Reparsed == 0 and modifier.kind ~= Kind.Decorator and ast.ModifierToFlag(modifier.kind) & ast.ModifierFlags.JavaScript == 0 then
                p:jsErrorAtRange(modifier.loc, diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files, scanner.TokenToString(modifier.kind))
            end
        end
    elseif k == Kind.Parameter then
        if core.Some(node:ModifierNodes(), ast.IsModifier) then
            p:jsErrorAtRange(node:Modifiers().loc, diagnostics.Parameter_modifiers_can_only_be_used_in_TypeScript_files)
        end
    elseif jsCheckTypeArgumentKinds[k] then
        local list = node:TypeArgumentList()
        if list ~= nil and core.Some(list.nodes, isNotReparsed) then
            p:jsErrorAtRange(list.loc, diagnostics.Type_arguments_can_only_be_used_in_TypeScript_files)
        end
    end
    return node
end
