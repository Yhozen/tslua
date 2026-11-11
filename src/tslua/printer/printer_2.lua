local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local OP = ast.OperatorPrecedence
local EF = printer.EmitFlags
local LF = printer.ListFormat
local WriteKind = printer.WriteKind

local Printer = printer.Printer

function Printer:emitKeywordExpression(node)
    self:emitKeywordNode(node)
end

function Printer:emitArrayLiteralExpressionElement(node)
    self:emitExpression(node, OP.Spread)
end

function Printer:emitArrayLiteralExpression(node)
    local state = self:enterNode(node)
    self:emitList(Printer.emitArrayLiteralExpressionElement, node, node.elements, LF.LFArrayLiteralExpressionElements | (node.multiLine and LF.LFPreferNewLine or LF.LFNone))
    self:exitNode(node, state)
end

function Printer:emitObjectLiteralExpression(node)
    local state = self:enterNode(node)
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:generateAllMemberNames(node.properties)
    self:emitList(Printer.emitObjectLiteralElement, node, node.properties, LF.LFObjectLiteralExpressionProperties |
        (node.multiLine and LF.LFPreferNewLine or LF.LFNone) |
        (self:shouldAllowTrailingComma(node, node.properties) and LF.LFAllowTrailingComma or LF.LFNone))
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

-- 1..toString is a valid property access, emit a dot after the literal
-- Also emit a dot if expression is a integer const enum value - it will appear in generated code as numeric literal
function Printer:mayNeedDotDotForPropertyAccess(expression)
    expression = ast.SkipPartiallyEmittedExpressions(expression)
    if ast.IsNumericLiteral(expression) then
        -- check if numeric literal is a decimal literal that was originally written with a dot
        local text = self:getLiteralTextOfNode(expression, nil --[[sourceFile]], printer.getLiteralTextFlagsNeverAsciiEscape)
        -- If the number will be printed verbatim and it doesn't already contain a dot or an exponent indicator, add one
        -- if the expression doesn't have any comments that will be emitted.
        return expression.tokenFlags & ast.TokenFlags.WithSpecifier == 0 and
            string.find(text, scanner.TokenToString(Kind.DotToken), 1, true) == nil and
            string.find(text, "E", 1, true) == nil and
            string.find(text, "e", 1, true) == nil
    end
    return false
end

function Printer:emitPropertyAccessExpression(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, ast.IsOptionalChain(node) and OP.OptionalChain or OP.Member)
    local token = node.questionDotToken
    if token == nil then
        token = self.emitContext.factory:NewToken(Kind.DotToken)
        token.loc = core.NewTextRange(node.expression:End(), node:Name():Pos())
        self.emitContext:AddEmitFlags(token, EF.EFNoSourceMap)
    end
    local linesBeforeDot = self:getLinesBetweenNodes(node, node.expression, token)
    self:writeLineRepeat(linesBeforeDot)
    self:increaseIndentIf(linesBeforeDot > 0)
    local shouldEmitDotDot = token.kind ~= Kind.QuestionDotToken and
        self:mayNeedDotDotForPropertyAccess(node.expression) and
        not self.writer:HasTrailingComment() and
        not self.writer:HasTrailingWhitespace()
    if shouldEmitDotDot then
        self:writePunctuation(".")
    end
    if node.questionDotToken ~= nil then
        self:emitTokenNode(token)
    else
        self:emitToken(Kind.DotToken, node.expression:End(), WriteKind.Punctuation, node)
    end
    local linesAfterDot = self:getLinesBetweenNodes(node, token, node:Name())
    self:writeLineRepeat(linesAfterDot)
    self:increaseIndentIf(linesAfterDot > 0)
    self:emitMemberName(node:Name())
    self:decreaseIndentIf(linesAfterDot > 0)
    self:decreaseIndentIf(linesBeforeDot > 0)
    self:exitNode(node, state)
end

function Printer:emitElementAccessExpression(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, ast.IsOptionalChain(node) and OP.OptionalChain or OP.Member)
    self:emitTokenNode(node.questionDotToken)
    self:emitToken(Kind.OpenBracketToken, printer.greatestEnd(-1, node.expression, node.questionDotToken), WriteKind.Punctuation, node)
    self:emitExpression(node.argumentExpression, OP.Comma)
    self:emitToken(Kind.CloseBracketToken, node.argumentExpression:End(), WriteKind.Punctuation, node)
    self:exitNode(node, state)
end

function Printer:emitArgument(node)
    self:emitExpression(node, OP.Spread)
end

function Printer:emitCallee(callee, parentNode)
    if self:shouldEmitIndirectCall(parentNode) then
        self:writePunctuation("(")
        self:writeLiteral("0")
        self:writePunctuation(",")
        self:writeSpace()
        self:emitExpression(callee, OP.Comma)
        self:writePunctuation(")")
    elseif parentNode.kind == Kind.CallExpression and printer.isNewExpressionWithoutArguments(ast.SkipPartiallyEmittedExpressions(callee)) then
        -- Parenthesize `new C` inside of a CallExpression so it is treated as `(new C)()` and not `new C()`
        self:emitExpression(callee, OP.Parentheses)
    else
        self:emitExpression(callee, ast.IsOptionalChain(parentNode) and OP.OptionalChain or OP.Member)
    end
end

function Printer:emitCallExpression(node)
    local state = self:enterNode(node)
    self:emitCallee(node.expression, node)
    self:emitTokenNode(node.questionDotToken)
    self:emitTypeArguments(node, node.typeArguments)
    self:emitList(Printer.emitArgument, node, node.arguments, LF.LFCallExpressionArguments)
    self:exitNode(node, state)
end

function Printer:emitNewExpression(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.NewKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    if ast.SkipPartiallyEmittedExpressions(node.expression).kind == Kind.CallExpression then
        -- Parenthesize `C()` inside of a NewExpression so it is treated as `new (C())` and not `new C()`
        self:emitExpression(node.expression, OP.Parentheses)
    else
        self:emitExpression(node.expression, OP.Member)
    end
    self:emitTypeArguments(node, node.typeArguments)
    self:emitList(Printer.emitArgument, node, node.arguments, LF.LFNewExpressionArguments)
    self:exitNode(node, state)
end

function Printer:emitTemplateLiteral(node)
    if node.kind == Kind.NoSubstitutionTemplateLiteral then
        self:emitNoSubstitutionTemplateLiteral(node)
    elseif node.kind == Kind.TemplateExpression then
        self:emitTemplateExpression(node)
    else
        error("unhandled TemplateLiteral: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitTaggedTemplateExpression(node)
    local state = self:enterNode(node)
    self:emitCallee(node.tag, node)
    self:emitTypeArguments(node, node.typeArguments)
    self:writeSpace()
    self:emitTemplateLiteral(node.template)
    self:exitNode(node, state)
end

function Printer:emitTypeAssertionExpression(node)
    local state = self:enterNode(node)
    self:writePunctuation("<")
    self:emitTypeNodeOutsideExtends(node.type)
    self:writePunctuation(">")
    self:emitExpression(node.expression, OP.Update)
    self:exitNode(node, state)
end

function Printer:emitParenthesizedExpression(node)
    local state = self:enterNode(node)
    local openParenPos = self:emitToken(Kind.OpenParenToken, node:Pos(), WriteKind.Punctuation, node)
    local indented = self:writeLineSeparatorsAndIndentBefore(node.expression, node)
    self:emitExpression(node.expression, OP.Comma)
    self:writeLineSeparatorsAfter(node.expression, node)
    self:decreaseIndentIf(indented)
    local closeParenPos = openParenPos
    if node.expression ~= nil then
        closeParenPos = node.expression:End()
    end
    self:emitToken(Kind.CloseParenToken, closeParenPos, WriteKind.Punctuation, node)
    self:exitNode(node, state)
end

function Printer:emitFunctionExpression(node)
    local state = self:enterNode(node)
    self:generateNameIfNeeded(node:Name())
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("function")
    self:emitTokenNode(node.asteriskToken)
    self:writeSpace()
    self:emitIdentifierNameNode(node:Name())
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:emitFunctionBodyNode(node.body)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitConciseBody(node)
    if ast.IsBlock(node) then
        self:emitFunctionBody(node)
    elseif ast.IsObjectLiteralExpression(ast.GetLeftmostExpression(node, false --[[stopAtCallExpressions]])) then
        -- Wrap in ParenthesizedExpression to ensure parens are emitted after any leading
        -- PartiallyEmittedExpression comments, matching TypeScript's factory-time wrapping
        -- via parenthesizeConciseBodyOfArrowFunction.
        local paren = self.emitContext.factory:NewParenthesizedExpression(node)
        paren.loc = node.loc
        self:emitExpression(paren, OP.Lowest)
    elseif ast.IsExpression(node) then
        self:emitExpression(node, OP.Yield)
    else
        error("unexpected ConciseBody: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitArrowFunction(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitTypeParameters(node, node.typeParameters)
    self:emitParametersForArrow(node, node.parameters)
    self:emitTypeAnnotation(node.type)
    self:writeSpace()
    self:emitTokenNode(node.equalsGreaterThanToken)
    self:writeSpace()
    self:emitConciseBody(node.body)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitDeleteExpression(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.DeleteKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Unary)
    self:exitNode(node, state)
end

function Printer:emitTypeOfExpression(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.TypeOfKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Unary)
    self:exitNode(node, state)
end

function Printer:emitVoidExpression(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.VoidKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Unary)
    self:exitNode(node, state)
end

function Printer:emitAwaitExpression(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.AwaitKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Unary)
    self:exitNode(node, state)
end

function Printer:emitPrefixUnaryExpression(node)
    local state = self:enterNode(node)
    local operator = node.operator
    local operand = node.operand
    self:emitToken(operator, node:Pos(), WriteKind.Operator, node)

    -- In some cases, we need to emit a space between the operator and the operand. One obvious case
    -- is when the operator is an identifier, like delete or typeof. We also need to do this for plus
    -- and minus expressions in certain cases. Specifically, consider the following two cases (parens
    -- are just for clarity of exposition, and not part of the source code):
    --
    --  (+(+1))
    --  (+(++1))
    --
    -- We need to emit a space in both cases. In the first case, the absence of a space will make
    -- the resulting expression a prefix increment operation. And in the second, it will make the resulting
    -- expression a prefix increment whose operand is a plus expression - (++(+x))
    -- The same is true of minus of course.
    if operand.kind == Kind.PrefixUnaryExpression then
        local inner = operand.operator
        if (operator == Kind.PlusToken and (inner == Kind.PlusToken or inner == Kind.PlusPlusToken)) or
            (operator == Kind.MinusToken and (inner == Kind.MinusToken or inner == Kind.MinusMinusToken)) then
            self:writeSpace()
        end
    end

    self:emitExpression(node.operand, OP.Unary)
    self:exitNode(node, state)
end

function Printer:emitPostfixUnaryExpression(node)
    local state = self:enterNode(node)
    self:emitExpression(node.operand, OP.LeftHandSide)
    self:emitToken(node.operator, node.operand:End(), WriteKind.Operator, node)
    self:exitNode(node, state)
end

-- This function determines whether an expression consists of a homogeneous set of
-- literal expressions or binary plus expressions that all share the same literal kind.
-- It is used to determine whether the right-hand operand of a binary plus expression can be
-- emitted without parentheses.
function Printer:getLiteralKindOfBinaryPlusOperand(node)
    node = ast.SkipPartiallyEmittedExpressions(node)

    if ast.IsLiteralKind(node.kind) then
        return node.kind
    end

    if node.kind == Kind.BinaryExpression then
        local n = node
        if n.operatorToken.kind == Kind.PlusToken then
            -- !!! Determine if caching this is worthwhile over recomputing
            local leftKind = self:getLiteralKindOfBinaryPlusOperand(n.left)
            local literalKind = Kind.Unknown
            if ast.IsLiteralKind(leftKind) and leftKind == self:getLiteralKindOfBinaryPlusOperand(n.right) then
                literalKind = leftKind
            end
            return literalKind
        end
    end

    return Kind.Unknown
end

function Printer:getBinaryExpressionPrecedence(node)
    local precedence = ast.GetExpressionPrecedence(node)
    local leftPrec = precedence
    local rightPrec = precedence
    if precedence == OP.Comma then
        -- No need to parenthesize the right operand when the binary operator and
        -- operand are both ,:
        --  x,(a,b)     => x,a,b
    elseif precedence == OP.Assignment then
        -- assignment is right-associative
        leftPrec = OP.Conditional
        rightPrec = OP.Yield
    elseif precedence == OP.LogicalOR then
        rightPrec = OP.LogicalAND
    elseif precedence == OP.LogicalAND then
        rightPrec = OP.BitwiseOR
    elseif precedence == OP.BitwiseOR then
        -- No need to parenthesize the right operand when the binary operator and
        -- operand are both | due to the associative property of mathematics:
        --  x|(a|b)     => x|a|b
    elseif precedence == OP.BitwiseXOR then
        -- No need to parenthesize the right operand when the binary operator and
        -- operand are both ^ due to the associative property of mathematics:
        --  x^(a^b)     => x^a^b
    elseif precedence == OP.BitwiseAND then
        -- No need to parenthesize the right operand when the binary operator and
        -- operand are both & due to the associative property of mathematics:
        --  x&(a&b)     => x&a&b
    elseif precedence == OP.Equality then
        rightPrec = OP.Relational
    elseif precedence == OP.Relational then
        rightPrec = OP.Shift
    elseif precedence == OP.Shift then
        rightPrec = OP.Additive
    elseif precedence == OP.Additive then
        local skip = false
        if node.operatorToken.kind == Kind.PlusToken and printer.isBinaryOperation(node.right, Kind.PlusToken) then
            local leftKind = self:getLiteralKindOfBinaryPlusOperand(node.left)
            if ast.IsLiteralKind(leftKind) and leftKind == self:getLiteralKindOfBinaryPlusOperand(node.right) then
                -- No need to parenthesize the right operand when the binary operator
                -- is plus (+) if both the left and right operands consist solely of either
                -- literals of the same kind or binary plus (+) expressions for literals of
                -- the same kind (recursively).
                --  "a"+(1+2)       => "a"+(1+2)
                --  "a"+("b"+"c")   => "a"+"b"+"c"
                skip = true
            end
        end
        if not skip then
            rightPrec = OP.Multiplicative
        end
    elseif precedence == OP.Multiplicative then
        if node.operatorToken.kind == Kind.AsteriskToken and printer.isBinaryOperation(node.right, Kind.AsteriskToken) then
            -- No need to parenthesize the right operand when the binary operator and
            -- operand are both * due to the associative property of mathematics:
            --  x*(a*b)     => x*a*b
        else
            rightPrec = OP.Exponentiation
        end
    elseif precedence == OP.Exponentiation then
        -- exponentiation is right-associative
        leftPrec = OP.Update
    else
        error("unhandled precedence: " .. tostring(precedence), 0)
    end
    return leftPrec, rightPrec
end

function Printer:emitBinaryExpression(node)
    local leftPrec, rightPrec = self:getBinaryExpressionPrecedence(node)
    local emittedLeft = ast.SkipPartiallyEmittedExpressions(node.left)
    if ast.NodeIsSynthesized(emittedLeft) and emittedLeft.kind == Kind.BinaryExpression and printer.mixingBinaryOperatorsRequiresParentheses(node.operatorToken.kind, emittedLeft.operatorToken.kind) then
        leftPrec = OP.Highest
    end
    local emittedRight = ast.SkipPartiallyEmittedExpressions(node.right)
    if ast.NodeIsSynthesized(emittedRight) and emittedRight.kind == Kind.BinaryExpression and printer.mixingBinaryOperatorsRequiresParentheses(node.operatorToken.kind, emittedRight.operatorToken.kind) then
        rightPrec = OP.Highest
    end
    local state = self:enterNode(node)
    self:emitExpression(node.left, leftPrec)
    local linesBeforeOperator = self:getLinesBetweenNodes(node, node.left, node.operatorToken)
    local linesAfterOperator = self:getLinesBetweenNodes(node, node.operatorToken, node.right)
    self:writeLinesAndIndent(linesBeforeOperator, node.operatorToken.kind ~= Kind.CommaToken --[[writeSpaceIfNotIndenting]])
    self:emitTokenNodeEx(node.operatorToken, printer.tefNoSourceMaps)
    self:writeLinesAndIndent(linesAfterOperator, true --[[writeSpaceIfNotIndenting]]) -- Binary operators should have a space before the comment starts
    self:emitExpression(node.right, rightPrec)
    self:decreaseIndentIf(linesAfterOperator > 0)
    self:decreaseIndentIf(linesBeforeOperator > 0)
    self:exitNode(node, state)
end

function Printer:emitShortCircuitExpression(node)
    if printer.isBinaryOperation(ast.SkipPartiallyEmittedExpressions(node), Kind.QuestionQuestionToken) then
        self:emitExpression(node, OP.Coalesce)
    else
        self:emitExpression(node, OP.LogicalOR)
    end
end

function Printer:emitConditionalExpression(node)
    local state = self:enterNode(node)
    local linesBeforeQuestion = self:getLinesBetweenNodes(node, node.condition, node.questionToken)
    local linesAfterQuestion = self:getLinesBetweenNodes(node, node.questionToken, node.whenTrue)
    local linesBeforeColon = self:getLinesBetweenNodes(node, node.whenTrue, node.colonToken)
    local linesAfterColon = self:getLinesBetweenNodes(node, node.colonToken, node.whenFalse)
    self:emitShortCircuitExpression(node.condition)
    self:writeLinesAndIndent(linesBeforeQuestion, true --[[writeSpaceIfNotIndenting]])
    self:emitPunctuationNode(node.questionToken)
    self:writeLinesAndIndent(linesAfterQuestion, true --[[writeSpaceIfNotIndenting]])
    self:emitExpression(node.whenTrue, OP.Yield)
    self:decreaseIndentIf(linesAfterQuestion > 0)
    self:decreaseIndentIf(linesBeforeQuestion > 0)
    self:writeLinesAndIndent(linesBeforeColon, true --[[writeSpaceIfNotIndenting]])
    self:emitPunctuationNode(node.colonToken)
    self:writeLinesAndIndent(linesAfterColon, true --[[writeSpaceIfNotIndenting]])
    self:emitExpression(node.whenFalse, OP.Yield)
    self:decreaseIndentIf(linesAfterColon > 0)
    self:decreaseIndentIf(linesBeforeColon > 0)
    self:exitNode(node, state)
end

function Printer:emitTemplateExpression(node)
    local state = self:enterNode(node)
    self:emitTemplateHead(node.head)
    self:emitList(Printer.emitTemplateSpanNode, node, node.templateSpans, LF.LFTemplateExpressionSpans)
    self:exitNode(node, state)
end

function Printer:emitYieldExpression(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.YieldKeyword, node:Pos(), WriteKind.Keyword, node)
    self:emitPunctuationNode(node.asteriskToken)
    if node.expression ~= nil then
        self:writeSpace()
        self:emitExpressionNoASI(node.expression, OP.DisallowComma)
    end
    self:exitNode(node, state)
end

function Printer:emitSpreadElement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.DotDotDotToken, node:Pos(), WriteKind.Punctuation, node)
    self:emitExpression(node.expression, OP.DisallowComma)
    self:exitNode(node, state)
end

function Printer:emitClassExpression(node)
    local state = self:enterNode(node)
    self:generateNameIfNeeded(node:Name())

    local pos = self:emitModifierList(node, node:Modifiers(), true --[[allowDecorators]])
    self:emitToken(Kind.ClassKeyword, pos, WriteKind.Keyword, node)

    if node:Name() ~= nil then
        self:writeSpace()
        self:emitIdentifierName(node:Name())
    end

    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)

    self:emitTypeParameters(node, node.typeParameters)
    self:emitList(Printer.emitHeritageClauseNode, node, node.heritageClauses, LF.LFClassHeritageClauses)
    self:writeSpace()
    self:writePunctuation("{")
    self:pushNameGenerationScope(node)
    self:generateAllMemberNames(node.members)
    self:emitList(Printer.emitClassElement, node, node.members, LF.LFClassMembers)
    self:popNameGenerationScope(node)
    self:writePunctuation("}")

    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitOmittedExpression(node)
    self:exitNode(node, self:enterNode(node))
end

function Printer:emitExpressionWithTypeArguments(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, OP.Member)
    self:emitTypeArguments(node, node.typeArguments)
    self:exitNode(node, state)
end

function Printer:emitAsExpression(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, OP.Relational)
    self:writeSpace()
    self:writeKeyword("as")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.type)
    self:exitNode(node, state)
end

function Printer:emitSatisfiesExpression(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, OP.Relational)
    self:writeSpace()
    self:writeKeyword("satisfies")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.type)
    self:exitNode(node, state)
end

function Printer:emitNonNullExpression(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, OP.Member)
    self:writeOperator("!")
    self:exitNode(node, state)
end

function Printer:emitMetaProperty(node)
    local state = self:enterNode(node)
    self:emitToken(node.keywordToken, node:Pos(), WriteKind.Punctuation, node)
    self:writePunctuation(".")
    self:emitIdentifierName(node:Name())
    self:exitNode(node, state)
end

function Printer:emitPartiallyEmittedExpression(node)
    -- avoid reprinting parens for nested partially emitted expressions
    local stack = {}
    while true do
        local state = self:enterNode(node)
        local emitFlags = self.emitContext:EmitFlags(node)
        if emitFlags & EF.EFNoLeadingComments == 0 and node:Pos() ~= node.expression:Pos() then
            self:emitTrailingCommentsOfPosition(node.expression:Pos(), false --[[prefixSpace]], false --[[forceNoNewline]])
        end
        stack[#stack + 1] = { node = node, state = state }
        if not ast.IsPartiallyEmittedExpression(node.expression) then
            break
        end
        node = node.expression
    end

    self:emitExpression(node.expression, OP.Lowest)

    -- unwind stack
    while #stack > 0 do
        local entry = stack[#stack]
        stack[#stack] = nil
        local emitFlags = self.emitContext:EmitFlags(node)
        if emitFlags & EF.EFNoTrailingComments == 0 and node:End() ~= node.expression:End() then
            self:emitLeadingCommentsOfPosition(node.expression:End())
        end
        self:exitNode(node, entry.state)
        node = entry.node
    end
end

function Printer:commentWillEmitNewLine(comment)
    return comment.kind == Kind.SingleLineCommentTrivia or comment.hasTrailingNewLine
end

function Printer:syntheticCommentWillEmitNewLine(comment)
    return comment.kind == Kind.SingleLineCommentTrivia or comment.hasTrailingNewLine
end

function Printer:willEmitLeadingNewLine(node)
    if self.currentSourceFile == nil then
        return false
    end
    local hasLeadingCommentRanges = false
    local hasNewLineComment = false
    for comment in scanner.GetLeadingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), node:Pos()) do
        hasLeadingCommentRanges = true
        if self:commentWillEmitNewLine(comment) then
            hasNewLineComment = true
        end
    end
    if hasLeadingCommentRanges then
        local parseNode = self.emitContext:ParseNode(node)
        if parseNode ~= nil and ast.IsParenthesizedExpression(parseNode.parent) then
            return true
        end
    end
    if hasNewLineComment then
        return true
    end
    local synthetic = self.emitContext:GetSyntheticLeadingComments(node)
    if synthetic ~= nil then
        for _, comment in ipairs(synthetic) do
            if self:syntheticCommentWillEmitNewLine(comment) then
                return true
            end
        end
    end
    if ast.IsPartiallyEmittedExpression(node) then
        local pee = node
        if node:Pos() ~= pee.expression:Pos() then
            for comment in scanner.GetTrailingCommentRanges(self.emitContext.factory:AsNodeFactory(), self.currentSourceFile:Text(), pee.expression:Pos()) do
                if self:commentWillEmitNewLine(comment) then
                    return true
                end
            end
        end
        return self:willEmitLeadingNewLine(pee.expression)
    end
    return false
end

-- parenthesizeExpressionForNoAsi wraps an expression in parens if we would emit a leading comment
-- that would introduce a line separator between the node and its parent.
function Printer:parenthesizeExpressionForNoAsi(node)
    if not self.commentsDisabled then
        local factory = self.emitContext.factory
        local kind = node.kind
        if kind == Kind.PartiallyEmittedExpression then
            if self:willEmitLeadingNewLine(node) then
                local pee = node
                local parseNode = self.emitContext:ParseNode(node)
                if parseNode ~= nil and ast.IsParenthesizedExpression(parseNode) then
                    -- If the original node was a parenthesized expression, restore it to preserve comment and source map emit
                    local parens = factory:NewParenthesizedExpression(pee.expression)
                    self.emitContext:SetOriginal(parens, node)
                    parens.loc = parseNode.loc
                    return parens
                end
                return factory:NewParenthesizedExpression(node)
            end
            local pee = node
            return factory:UpdatePartiallyEmittedExpression(
                pee,
                self:parenthesizeExpressionForNoAsi(pee.expression)
            )
        elseif kind == Kind.PropertyAccessExpression then
            local pae = node
            return factory:UpdatePropertyAccessExpression(
                pae,
                self:parenthesizeExpressionForNoAsi(pae.expression),
                pae.questionDotToken,
                pae:Name(),
                pae.flags
            )
        elseif kind == Kind.ElementAccessExpression then
            local eae = node
            return factory:UpdateElementAccessExpression(
                eae,
                self:parenthesizeExpressionForNoAsi(eae.expression),
                eae.questionDotToken,
                eae.argumentExpression,
                eae.flags
            )
        elseif kind == Kind.CallExpression then
            local ce = node
            return factory:UpdateCallExpression(
                ce,
                self:parenthesizeExpressionForNoAsi(ce.expression),
                ce.questionDotToken,
                ce.typeArguments,
                ce.arguments,
                ce.flags
            )
        elseif kind == Kind.TaggedTemplateExpression then
            local tte = node
            return factory:UpdateTaggedTemplateExpression(
                tte,
                self:parenthesizeExpressionForNoAsi(tte.tag),
                tte.questionDotToken,
                tte.typeArguments,
                tte.template,
                tte.flags
            )
        elseif kind == Kind.PostfixUnaryExpression then
            local pue = node
            return factory:UpdatePostfixUnaryExpression(
                pue,
                self:parenthesizeExpressionForNoAsi(pue.operand),
                pue.operator
            )
        elseif kind == Kind.BinaryExpression then
            local be = node
            return factory:UpdateBinaryExpression(
                be,
                be:Modifiers(),
                self:parenthesizeExpressionForNoAsi(be.left),
                be.type,
                be.operatorToken,
                be.right
            )
        elseif kind == Kind.ConditionalExpression then
            local ce = node
            return factory:UpdateConditionalExpression(
                ce,
                self:parenthesizeExpressionForNoAsi(ce.condition),
                ce.questionToken,
                ce.whenTrue,
                ce.colonToken,
                ce.whenFalse
            )
        elseif kind == Kind.AsExpression then
            local ae = node
            return factory:UpdateAsExpression(
                ae,
                self:parenthesizeExpressionForNoAsi(ae.expression),
                ae.type
            )
        elseif kind == Kind.SatisfiesExpression then
            local se = node
            return factory:UpdateSatisfiesExpression(
                se,
                self:parenthesizeExpressionForNoAsi(se.expression),
                se.type
            )
        elseif kind == Kind.NonNullExpression then
            local nne = node
            return factory:UpdateNonNullExpression(
                nne,
                self:parenthesizeExpressionForNoAsi(nne.expression),
                nne.flags
            )
        end
    end
    return node
end

function Printer:emitExpressionNoASI(node, precedence)
    node = self:parenthesizeExpressionForNoAsi(node)
    self:emitExpression(node, precedence)
end

function Printer:emitExpression(node, precedence)
    local parens = ast.GetExpressionPrecedence(ast.SkipPartiallyEmittedExpressions(node)) < precedence
    if parens then
        self:writePunctuation("(")
    end

    local kind = node.kind
    -- Keywords
    if kind == Kind.TrueKeyword or kind == Kind.FalseKeyword or kind == Kind.NullKeyword then
        self:emitTokenNode(node)
    elseif kind == Kind.ThisKeyword or kind == Kind.SuperKeyword or kind == Kind.ImportKeyword then
        self:emitKeywordExpression(node)

    -- Literals
    elseif kind == Kind.NumericLiteral then
        self:emitNumericLiteral(node)
    elseif kind == Kind.BigIntLiteral then
        self:emitBigIntLiteral(node)
    elseif kind == Kind.StringLiteral then
        self:emitStringLiteral(node)
    elseif kind == Kind.RegularExpressionLiteral then
        self:emitRegularExpressionLiteral(node)
    elseif kind == Kind.NoSubstitutionTemplateLiteral then
        self:emitNoSubstitutionTemplateLiteral(node)

    -- Identifiers
    elseif kind == Kind.Identifier then
        self:emitIdentifierReference(node)
    elseif kind == Kind.PrivateIdentifier then
        self:emitPrivateIdentifier(node)

    -- Expressions
    elseif kind == Kind.ArrayLiteralExpression then
        self:emitArrayLiteralExpression(node)
    elseif kind == Kind.ObjectLiteralExpression then
        self:emitObjectLiteralExpression(node)
    elseif kind == Kind.PropertyAccessExpression then
        self:emitPropertyAccessExpression(node)
    elseif kind == Kind.ElementAccessExpression then
        self:emitElementAccessExpression(node)
    elseif kind == Kind.CallExpression then
        self:emitCallExpression(node)
    elseif kind == Kind.NewExpression then
        self:emitNewExpression(node)
    elseif kind == Kind.TaggedTemplateExpression then
        self:emitTaggedTemplateExpression(node)
    elseif kind == Kind.TypeAssertionExpression then
        self:emitTypeAssertionExpression(node)
    elseif kind == Kind.ParenthesizedExpression then
        self:emitParenthesizedExpression(node)
    elseif kind == Kind.FunctionExpression then
        self:emitFunctionExpression(node)
    elseif kind == Kind.ArrowFunction then
        self:emitArrowFunction(node)
    elseif kind == Kind.DeleteExpression then
        self:emitDeleteExpression(node)
    elseif kind == Kind.TypeOfExpression then
        self:emitTypeOfExpression(node)
    elseif kind == Kind.VoidExpression then
        self:emitVoidExpression(node)
    elseif kind == Kind.AwaitExpression then
        self:emitAwaitExpression(node)
    elseif kind == Kind.PrefixUnaryExpression then
        self:emitPrefixUnaryExpression(node)
    elseif kind == Kind.PostfixUnaryExpression then
        self:emitPostfixUnaryExpression(node)
    elseif kind == Kind.BinaryExpression then
        self:emitBinaryExpression(node)
    elseif kind == Kind.ConditionalExpression then
        self:emitConditionalExpression(node)
    elseif kind == Kind.TemplateExpression then
        self:emitTemplateExpression(node)
    elseif kind == Kind.YieldExpression then
        self:emitYieldExpression(node)
    elseif kind == Kind.SpreadElement then
        self:emitSpreadElement(node)
    elseif kind == Kind.ClassExpression then
        self:emitClassExpression(node)
    elseif kind == Kind.OmittedExpression then
        self:emitOmittedExpression(node)
    elseif kind == Kind.AsExpression then
        self:emitAsExpression(node)
    elseif kind == Kind.NonNullExpression then
        self:emitNonNullExpression(node)
    elseif kind == Kind.ExpressionWithTypeArguments then
        self:emitExpressionWithTypeArguments(node)
    elseif kind == Kind.SatisfiesExpression then
        self:emitSatisfiesExpression(node)
    elseif kind == Kind.MetaProperty then
        self:emitMetaProperty(node)
    elseif kind == Kind.SyntheticExpression then
        error("SyntheticExpression should never be printed.", 0)
    elseif kind == Kind.MissingDeclaration then
        -- break

    -- JSX
    elseif kind == Kind.JsxElement then
        self:emitJsxElement(node)
    elseif kind == Kind.JsxSelfClosingElement then
        self:emitJsxSelfClosingElement(node)
    elseif kind == Kind.JsxFragment then
        self:emitJsxFragment(node)

    -- Synthesized list
    elseif kind == Kind.SyntaxList then
        error("SyntaxList should not be printed", 0)

    -- Transformation nodes
    elseif kind == Kind.NotEmittedStatement then
        return
    elseif kind == Kind.PartiallyEmittedExpression then
        self:emitPartiallyEmittedExpression(node)
    elseif kind == Kind.SyntheticReferenceExpression then
        error("SyntheticReferenceExpression should not be printed", 0)
    else
        error("unexpected Expression: " .. tostring(ast.Kind_names[kind]), 0)
    end

    if parens then
        self:writePunctuation(")")
    end
end

--
-- Misc
--

function Printer:emitTemplateSpan(node)
    local state = self:enterNode(node)
    self:emitExpression(node.expression, OP.Comma)
    self:emitTemplateMiddleTail(node.literal)
    self:exitNode(node, state)
end

function Printer:emitTemplateSpanNode(node)
    self:emitTemplateSpan(node)
end

function Printer:emitSemicolonClassElement(node)
    local state = self:enterNode(node)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

--
-- Statements
--

function Printer:isEmptyBlock(block, statements)
    return #statements.nodes == 0 and
        (self.currentSourceFile == nil or printer.rangeEndIsOnSameLineAsRangeStart(block.loc, block.loc, self.currentSourceFile))
end

function Printer:emitBlock(node)
    local state = self:enterNode(node)
    self:generateNames(node)
    self:emitToken(Kind.OpenBraceToken, node:Pos(), WriteKind.Punctuation, node)

    local format
    if not node.multiLine and self:isEmptyBlock(node, node.statements) or self:shouldEmitOnSingleLine(node) then
        format = LF.LFSingleLineBlockStatements
    else
        format = LF.LFMultiLineBlockStatements
    end
    self:emitList(Printer.emitStatement, node, node.statements, format)

    self:emitTokenEx(Kind.CloseBraceToken, node.statements:End(), WriteKind.Punctuation, node, (format & LF.LFMultiLine ~= 0) and printer.tefIndentLeadingComments or printer.tefNone)
    self:exitNode(node, state)
end

function Printer:emitVariableStatement(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:emitVariableDeclarationList(node.declarationList)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitEmptyStatement(node, isEmbeddedStatement)
    local state = self:enterNode(node)

    -- While most trailing semicolons are possibly insignificant, an embedded "empty"
    -- statement is significant and cannot be elided by a trailing-semicolon-omitting writer.
    if isEmbeddedStatement then
        self:writePunctuation(";")
    else
        self:writeTrailingSemicolon()
    end
    self:exitNode(node, state)
end

function Printer:emitExpressionStatement(node)
    local state = self:enterNode(node)

    if self.currentSourceFile ~= nil and self.currentSourceFile.scriptKind == core.ScriptKind.JSON then
        -- !!! In strada, this was handled by an undefined parenthesizerRule, so this is a hack.
        self:emitExpression(node.expression, OP.Comma)
    elseif printer.isImmediatelyInvokedFunctionExpressionOrArrowFunction(node.expression) then
        -- For IIFEs, parenthesize just the callee (not the whole call), matching TypeScript's
        -- parenthesizeExpressionOfExpressionStatement which wraps the function/arrow in parens:
        --   (function() { })()  -- not (function() { }())
        self:emitIIFEWithParenthesizedCallee(node.expression)
    else
        local leftmostKind = ast.GetLeftmostExpression(node.expression, false --[[stopAtCallExpression]]).kind
        if leftmostKind == Kind.FunctionExpression or leftmostKind == Kind.ObjectLiteralExpression then
            self:emitExpression(node.expression, OP.Parentheses)
        else
            self:emitExpression(node.expression, OP.Comma)
        end
    end

    -- Emit semicolon in non json files
    -- or if json file that created synthesized expression(eg.define expression statement when --out and amd code generation)
    if self.currentSourceFile == nil or
        self.currentSourceFile.scriptKind ~= core.ScriptKind.JSON or
        ast.NodeIsSynthesized(node.expression) then
        self:writeTrailingSemicolon()
    end

    self:exitNode(node, state)
end

-- emitIIFEWithParenthesizedCallee emits a call expression that is an IIFE,
-- wrapping just the callee in parens rather than the entire call expression.
-- This matches TypeScript's parenthesizeExpressionOfExpressionStatement behavior:
--
--	(function() { })()   -- parens around callee only
--
-- instead of:
--
--	(function() { }())   -- parens around entire call
function Printer:emitIIFEWithParenthesizedCallee(node)
    -- Walk through PartiallyEmittedExpression wrappers to find the call
    local call = ast.SkipPartiallyEmittedExpressions(node):AsCallExpression()
    local state = self:enterNode(call)
    -- Emit the callee wrapped in parens
    self:writePunctuation("(")
    self:emitExpression(call.expression, OP.Lowest)
    self:writePunctuation(")")
    self:emitTokenNode(call.questionDotToken)
    self:emitTypeArguments(call, call.typeArguments)
    self:emitList(Printer.emitArgument, call, call.arguments, LF.LFCallExpressionArguments)
    self:exitNode(call, state)
end

function Printer:emitIfStatement(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.IfKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitToken(Kind.OpenParenToken, pos, WriteKind.Punctuation, node)
    self:emitExpression(node.expression, OP.Lowest)
    self:emitToken(Kind.CloseParenToken, node.expression:End(), WriteKind.Punctuation, node)
    self:emitEmbeddedStatement(node, node.thenStatement)
    if node.elseStatement ~= nil then
        self:writeLineOrSpace(node, node.thenStatement, node.elseStatement)
        self:emitToken(Kind.ElseKeyword, node.thenStatement:End(), WriteKind.Keyword, node)
        if node.elseStatement.kind == Kind.IfStatement then
            self:writeSpace()
            self:emitIfStatement(node.elseStatement)
        else
            self:emitEmbeddedStatement(node, node.elseStatement)
        end
    end
    self:exitNode(node, state)
end

function Printer:emitWhileClause(node, expression, startPos)
    local pos = self:emitToken(Kind.WhileKeyword, startPos, WriteKind.Keyword, node)
    self:writeSpace()
    self:emitToken(Kind.OpenParenToken, pos, WriteKind.Punctuation, node)
    self:emitExpression(expression, OP.Lowest)
    self:emitToken(Kind.CloseParenToken, expression:End(), WriteKind.Punctuation, node)
end

function Printer:emitDoStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.DoKeyword, node:Pos(), WriteKind.Keyword, node)
    self:emitEmbeddedStatement(node, node.statement)
    if ast.IsBlock(node.statement) and not self.options.preserveSourceNewlines then
        self:writeSpace()
    else
        self:writeLineOrSpace(node, node.statement, node.expression)
    end

    self:emitWhileClause(node, node.expression, node.statement:End())
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitWhileStatement(node)
    local state = self:enterNode(node)
    self:emitWhileClause(node, node.expression, node:Pos())
    self:emitEmbeddedStatement(node, node.statement)
    self:exitNode(node, state)
end

function Printer:emitForInitializer(node)
    if node.kind == Kind.VariableDeclarationList then
        self:emitVariableDeclarationList(node)
    else
        self:emitExpression(node, OP.Lowest)
    end
end

function Printer:emitForStatement(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.ForKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    pos = self:emitToken(Kind.OpenParenToken, pos, WriteKind.Punctuation, node)
    if node.initializer ~= nil then
        self:emitForInitializer(node.initializer)
        pos = node.initializer:End()
    end
    pos = self:emitToken(Kind.SemicolonToken, pos, WriteKind.Punctuation, node)
    if node.condition ~= nil then
        self:writeSpace()
        self:emitExpression(node.condition, OP.Lowest)
        pos = node.condition:End()
    end
    pos = self:emitToken(Kind.SemicolonToken, pos, WriteKind.Punctuation, node)
    if node.incrementor ~= nil then
        self:writeSpace()
        self:emitExpression(node.incrementor, OP.Lowest)
        pos = node.incrementor:End()
    end
    self:emitToken(Kind.CloseParenToken, pos, WriteKind.Punctuation, node)
    self:emitEmbeddedStatement(node, node.statement)
    self:exitNode(node, state)
end

function Printer:emitForInStatement(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.ForKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitToken(Kind.OpenParenToken, pos, WriteKind.Punctuation, node)
    self:emitForInitializer(node.initializer)
    self:writeSpace()
    self:emitToken(Kind.InKeyword, node.initializer:End(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Lowest)
    self:emitToken(Kind.CloseParenToken, node.expression:End(), WriteKind.Punctuation, node)
    self:emitEmbeddedStatement(node, node.statement)
    self:exitNode(node, state)
end

function Printer:emitForOfStatement(node)
    local state = self:enterNode(node)
    local openParenPos = self:emitToken(Kind.ForKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    if node.awaitModifier ~= nil then
        self:emitKeywordNode(node.awaitModifier)
        self:writeSpace()
    end
    self:emitToken(Kind.OpenParenToken, openParenPos, WriteKind.Punctuation, node)
    self:emitForInitializer(node.initializer)
    self:writeSpace()
    self:emitToken(Kind.OfKeyword, node.initializer:End(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Lowest)
    self:emitToken(Kind.CloseParenToken, node.expression:End(), WriteKind.Punctuation, node)
    self:emitEmbeddedStatement(node, node.statement)
    self:exitNode(node, state)
end

function Printer:emitContinueStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.ContinueKeyword, node:Pos(), WriteKind.Keyword, node)
    if node.label ~= nil then
        self:writeSpace()
        self:emitLabelIdentifier(node.label)
    end
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitBreakStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.BreakKeyword, node:Pos(), WriteKind.Keyword, node)
    if node.label ~= nil then
        self:writeSpace()
        self:emitLabelIdentifier(node.label)
    end
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitReturnStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.ReturnKeyword, node:Pos(), WriteKind.Keyword, node)
    if node.expression ~= nil then
        self:writeSpace()
        self:emitExpressionNoASI(node.expression, OP.Lowest)
    end
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitWithStatement(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.WithKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitToken(Kind.OpenParenToken, pos, WriteKind.Punctuation, node)
    self:emitExpression(node.expression, OP.Lowest)
    self:emitToken(Kind.CloseParenToken, node.expression:End(), WriteKind.Punctuation, node)
    self:emitEmbeddedStatement(node, node.statement)
    self:exitNode(node, state)
end

function Printer:emitSwitchStatement(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.SwitchKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitToken(Kind.OpenParenToken, pos, WriteKind.Punctuation, node)
    self:emitExpression(node.expression, OP.Lowest)
    self:emitToken(Kind.CloseParenToken, node.expression:End(), WriteKind.Punctuation, node)
    self:writeSpace()
    self:emitCaseBlock(node.caseBlock)
    self:exitNode(node, state)
end

function Printer:emitLabeledStatement(node)
    local state = self:enterNode(node)
    self:emitLabelIdentifier(node.label)
    self:emitToken(Kind.ColonToken, node.label:End(), WriteKind.Punctuation, node)

    -- TODO: use emitEmbeddedStatement rather than writeSpace/emitStatement here after Strada migration as it is
    --       more consistent with similar emit elsewhere. writeSpace/emitStatement is used here to reduce spurious
    --       diffs when testing the Strada migration.

    self:writeSpace()
    self:emitStatement(node.statement)

    self:exitNode(node, state)
end

function Printer:emitThrowStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.ThrowKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpressionNoASI(node.expression, OP.Lowest)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitTryStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.TryKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitBlock(node.tryBlock)
    if node.catchClause ~= nil then
        self:writeLineOrSpace(node, node.tryBlock, node.catchClause)
        self:emitCatchClause(node.catchClause)
    end
    if node.finallyBlock ~= nil then
        local prev = node.catchClause or node.tryBlock
        self:writeLineOrSpace(node, prev, node.finallyBlock)
        self:emitToken(Kind.FinallyKeyword, prev:End(), WriteKind.Keyword, node)
        self:writeSpace()
        self:emitBlock(node.finallyBlock)
    end
    self:exitNode(node, state)
end

function Printer:emitDebuggerStatement(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.DebuggerKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitNotEmittedStatement(node)
    self:exitNode(node, self:enterNode(node))
end

function Printer:emitNotEmittedTypeElement(node)
    self:exitNode(node, self:enterNode(node))
end

--
-- Declarations
--

function Printer:emitVariableDeclaration(node)
    local state = self:enterNode(node)
    self:emitBindingName(node:Name())
    self:emitPunctuationNode(node.exclamationToken)
    self:emitTypeAnnotation(node.type)
    self:emitInitializer(node.initializer, printer.greatestEnd(node:Name():End(), node.type, self.emitContext:GetTypeNode(node:Name())), node)
    self:exitNode(node, state)
end

function Printer:emitVariableDeclarationNode(node)
    self:emitVariableDeclaration(node)
end

function Printer:emitVariableDeclarationList(node)
    local state = self:enterNode(node)
    if ast.IsVarLet(node) then
        self:writeKeyword("let")
    elseif ast.IsVarConst(node) then
        self:writeKeyword("const")
    elseif ast.IsVarUsing(node) then
        self:writeKeyword("using")
    elseif ast.IsVarAwaitUsing(node) then
        self:writeKeyword("await")
        self:writeSpace()
        self:writeKeyword("using")
    else
        self:writeKeyword("var")
    end
    self:writeSpace()
    self:emitList(Printer.emitVariableDeclarationNode, node, node.declarations, LF.LFVariableDeclarationList)
    self:exitNode(node, state)
end

function Printer:emitFunctionDeclaration(node)
    local state = self:enterNode(node)
    self:generateNameIfNeeded(node:Name())
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("function")
    self:emitTokenNode(node.asteriskToken)
    self:writeSpace()
    local name = node:Name()
    if name ~= nil then
        self:emitIdentifierName(name)
    end
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:pushNameGenerationScope(node)
    self:emitSignature(node)
    self:emitFunctionBodyNode(node.body)
    self:popNameGenerationScope(node)
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitClassDeclaration(node)
    local state = self:enterNode(node)
    self:generateNameIfNeeded(node:Name())
    local pos = self:emitModifierList(node, node:Modifiers(), true --[[allowDecorators]])
    self:emitToken(Kind.ClassKeyword, pos, WriteKind.Keyword, node)
    if node:Name() ~= nil then
        self:writeSpace()
        self:emitIdentifierName(node:Name())
    end
    local indented = self:shouldEmitIndented(node)
    self:increaseIndentIf(indented)
    self:emitTypeParameters(node, node.typeParameters)
    self:emitList(Printer.emitHeritageClauseNode, node, node.heritageClauses, LF.LFClassHeritageClauses)
    self:writeSpace()
    self:writePunctuation("{")
    self:pushNameGenerationScope(node)
    self:generateAllMemberNames(node.members)
    self:emitList(Printer.emitClassElement, node, node.members, LF.LFClassMembers)
    self:popNameGenerationScope(node)
    self:writePunctuation("}")
    self:decreaseIndentIf(indented)
    self:exitNode(node, state)
end

function Printer:emitInterfaceDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("interface")
    self:writeSpace()
    self:emitBindingIdentifier(node:Name())
    self:emitTypeParameters(node, node.typeParameters)
    self:emitList(Printer.emitHeritageClauseNode, node, node.heritageClauses, LF.LFHeritageClauses)
    self:writeSpace()
    self:writePunctuation("{")
    self:pushNameGenerationScope(node)
    self:generateAllMemberNames(node.members)
    self:emitList(Printer.emitTypeElement, node, node.members, LF.LFInterfaceMembers)
    self:popNameGenerationScope(node)
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitTypeAliasDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("type")
    self:writeSpace()
    self:emitBindingIdentifier(node:Name())
    self:emitTypeParameters(node, node.typeParameters)
    self:writeSpace()
    self:writePunctuation("=")
    self:writeSpace()
    self:emitTypeNodeOutsideExtends(node.type)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitEnumDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:writeKeyword("enum")
    self:writeSpace()
    self:emitBindingIdentifier(node:Name())
    self:writeSpace()
    self:writePunctuation("{")
    self:emitList(Printer.emitEnumMemberNode, node, node.members, LF.LFEnumMembers)
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitModuleDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    if node.keyword ~= Kind.GlobalKeyword then
        self:writeKeyword(node.keyword == Kind.NamespaceKeyword and "namespace" or "module")
        self:writeSpace()
    end
    self:emitModuleName(node:Name())
    local body = node.body
    while body ~= nil and ast.IsModuleDeclaration(body) do
        local module = body
        self:writePunctuation(".")
        self:emitNestedModuleName(module:Name())
        body = module.body
    end
    if body == nil then
        self:writeTrailingSemicolon()
    else
        self:writeSpace()
        self:emitModuleBlock(body)
    end
    self:exitNode(node, state)
end

function Printer:emitModuleBlock(node)
    local state = self:enterNode(node)
    self:generateNames(node)
    self:emitToken(Kind.OpenBraceToken, node:Pos(), WriteKind.Punctuation, node)
    local format
    if self:isEmptyBlock(node, node.statements) or self:shouldEmitOnSingleLine(node) then
        format = LF.LFSingleLineBlockStatements
    else
        format = LF.LFMultiLineBlockStatements
    end
    self:emitList(Printer.emitStatement, node, node.statements, format)
    self:emitTokenEx(Kind.CloseBraceToken, node.statements:End(), WriteKind.Punctuation, node, (format & LF.LFMultiLine ~= 0) and printer.tefIndentLeadingComments or printer.tefNone)
    self:exitNode(node, state)
end

function Printer:emitCaseBlock(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.OpenBraceToken, node:Pos(), WriteKind.Punctuation, node)
    self:emitList(Printer.emitCaseOrDefaultClauseNode, node, node.clauses, LF.LFCaseBlockClauses)
    self:emitTokenEx(Kind.CloseBraceToken, node.clauses:End(), WriteKind.Punctuation, node, printer.tefIndentLeadingComments)
    self:exitNode(node, state)
end

function Printer:emitImportEqualsDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    local pos = self:emitToken(Kind.ImportKeyword, printer.greatestEnd(node:Pos(), node:Modifiers()), WriteKind.Keyword, node)
    self:writeSpace()
    if node.isTypeOnly then
        self:emitToken(Kind.TypeKeyword, pos, WriteKind.Keyword, node)
        self:writeSpace()
    end
    self:emitBindingIdentifier(node:Name())
    self:writeSpace()
    self:emitToken(Kind.EqualsToken, node:Name():End(), WriteKind.Punctuation, node)
    self:writeSpace()
    self:emitModuleReference(node.moduleReference)
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitModuleReference(node)
    if node.kind == Kind.Identifier then
        self:emitIdentifierReference(node)
    elseif node.kind == Kind.QualifiedName then
        self:emitQualifiedName(node)
    elseif node.kind == Kind.ExternalModuleReference then
        self:emitExternalModuleReference(node)
    else
        error("unhandled ModuleReference: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitImportDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    self:emitToken(Kind.ImportKeyword, printer.greatestEnd(node:Pos(), node:Modifiers()), WriteKind.Keyword, node)
    self:writeSpace()
    if node.importClause ~= nil then
        self:emitImportClause(node.importClause)
        self:writeSpace()
        self:emitToken(Kind.FromKeyword, node.importClause:End(), WriteKind.Keyword, node)
        self:writeSpace()
    end
    self:emitExpression(node.moduleSpecifier, OP.Lowest)
    if node.attributes ~= nil then
        self:writeSpace()
        self:emitImportAttributes(node.attributes)
    end
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitImportClause(node)
    local state = self:enterNode(node)
    if node.phaseModifier ~= Kind.Unknown then
        self:emitToken(node.phaseModifier, node:Pos(), WriteKind.Keyword, node)
        self:writeSpace()
    end
    local name = node:Name()
    if name ~= nil then
        self:emitBindingIdentifier(node:Name())
        if node.namedBindings ~= nil then
            self:emitToken(Kind.CommaToken, name:End(), WriteKind.Punctuation, node)
            self:writeSpace()
        end
    end
    self:emitNamedImportBindings(node.namedBindings)
    self:exitNode(node, state)
end

function Printer:emitNamespaceImport(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.AsteriskToken, node:Pos(), WriteKind.Punctuation, node)
    self:writeSpace()
    self:emitToken(Kind.AsKeyword, pos, WriteKind.Keyword, node)
    self:writeSpace()
    self:emitBindingIdentifier(node:Name())
    self:exitNode(node, state)
end

function Printer:emitNamedImports(node)
    local state = self:enterNode(node)
    self:writePunctuation("{")
    self:emitList(Printer.emitImportSpecifierNode, node, node.elements, LF.LFNamedImportsOrExportsElements)
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitNamedImportBindings(node)
    if node == nil then
        return
    end
    if node.kind == Kind.NamespaceImport then
        self:emitNamespaceImport(node)
    elseif node.kind == Kind.NamedImports then
        self:emitNamedImports(node)
    else
        error("unhandled NamedImportBindings: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitImportSpecifier(node)
    local state = self:enterNode(node)
    if node.isTypeOnly then
        self:writeKeyword("type")
        self:writeSpace()
    end
    if node.propertyName ~= nil then
        self:emitModuleExportName(node.propertyName)
        self:writeSpace()
        self:emitToken(Kind.AsKeyword, node.propertyName:End(), WriteKind.Keyword, node)
        self:writeSpace()
    end
    self:emitBindingIdentifier(node:Name())
    self:exitNode(node, state)
end

function Printer:emitImportSpecifierNode(node)
    self:emitImportSpecifier(node)
end

function Printer:emitExportAssignment(node)
    local state = self:enterNode(node)
    local nextPos = self:emitToken(Kind.ExportKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    if node.isExportEquals then
        self:emitToken(Kind.EqualsToken, nextPos, WriteKind.Operator, node)
    else
        self:emitToken(Kind.DefaultKeyword, nextPos, WriteKind.Keyword, node)
    end
    self:writeSpace()
    if node.isExportEquals then
        self:emitExpression(node.expression, OP.Assignment)
    else
        -- parenthesize `class` and `function` expressions so as not to conflict with exported `class` and `function` declarations
        local expr = ast.GetLeftmostExpression(node.expression, false --[[stopAtCallExpressions]])
        if ast.IsClassExpression(expr) or ast.IsFunctionExpression(expr) then
            self:emitExpression(node.expression, OP.Parentheses)
        else
            self:emitExpression(node.expression, OP.Assignment)
        end
    end
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitExportDeclaration(node)
    local state = self:enterNode(node)
    self:emitModifierList(node, node:Modifiers(), false --[[allowDecorators]])
    local pos = self:emitToken(Kind.ExportKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    if node.isTypeOnly then
        pos = self:emitToken(Kind.TypeKeyword, pos, WriteKind.Keyword, node)
        self:writeSpace()
    end
    if node.exportClause ~= nil then
        self:emitNamedExportBindings(node.exportClause)
    else
        pos = self:emitToken(Kind.AsteriskToken, pos, WriteKind.Punctuation, node)
    end
    if node.moduleSpecifier ~= nil then
        self:writeSpace()
        self:emitToken(Kind.FromKeyword, printer.greatestEnd(pos, node.exportClause), WriteKind.Keyword, node)
        self:writeSpace()
        self:emitExpression(node.moduleSpecifier, OP.Lowest)
    end
    if node.attributes ~= nil then
        self:writeSpace()
        self:emitImportAttributes(node.attributes)
    end
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitImportAttributes(node)
    local state = self:enterNode(node)
    self:emitToken(node.token, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitList(Printer.emitImportAttributeNode, node, node.attributes, LF.LFImportAttributes)
    self:exitNode(node, state)
end

function Printer:emitImportAttribute(node)
    local state = self:enterNode(node)
    self:emitImportAttributeName(node:Name())
    self:writePunctuation(":")
    self:writeSpace()
    local value = node.value
    if self.emitContext:EmitFlags(node.value) & EF.EFNoLeadingComments == 0 then
        local commentRange = self.emitContext:CommentRange(value)
        self:emitTrailingComments(commentRange:Pos(), printer.commentSeparatorAfter)
    end
    self:emitExpression(value, OP.DisallowComma)
    self:exitNode(node, state)
end

function Printer:emitImportAttributeNode(node)
    self:emitImportAttribute(node)
end

function Printer:emitNamespaceExportDeclaration(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.ExportKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    pos = self:emitToken(Kind.AsKeyword, pos, WriteKind.Keyword, node)
    self:writeSpace()
    self:emitToken(Kind.NamespaceKeyword, pos, WriteKind.Keyword, node)
    self:writeSpace()
    self:emitBindingIdentifier(node:Name())
    self:writeTrailingSemicolon()
    self:exitNode(node, state)
end

function Printer:emitNamespaceExport(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.AsteriskToken, node:Pos(), WriteKind.Punctuation, node)
    self:writeSpace()
    self:emitToken(Kind.AsKeyword, pos, WriteKind.Keyword, node)
    self:writeSpace()
    self:emitModuleExportName(node:Name())
    self:exitNode(node, state)
end

function Printer:emitNamedExports(node)
    local state = self:enterNode(node)
    self:writePunctuation("{")
    self:emitList(Printer.emitExportSpecifierNode, node, node.elements, LF.LFNamedImportsOrExportsElements)
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitNamedExportBindings(node)
    if node.kind == Kind.NamespaceExport then
        self:emitNamespaceExport(node)
    elseif node.kind == Kind.NamedExports then
        self:emitNamedExports(node)
    else
        error("unhandled NamedExportBindings: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitExportSpecifier(node)
    local state = self:enterNode(node)
    if node.isTypeOnly then
        self:writeKeyword("type")
        self:writeSpace()
    end
    if node.propertyName ~= nil then
        self:emitModuleExportName(node.propertyName)
        self:writeSpace()
        self:emitToken(Kind.AsKeyword, node.propertyName:End(), WriteKind.Keyword, node)
        self:writeSpace()
    end
    self:emitModuleExportName(node:Name())
    self:exitNode(node, state)
end

function Printer:emitExportSpecifierNode(node)
    self:emitExportSpecifier(node)
end

function Printer:emitEmbeddedStatement(parentNode, node)
    if ast.IsBlock(node) or
        self:shouldEmitOnSingleLine(parentNode) or
        self.options.preserveSourceNewlines and self:getLeadingLineTerminatorCount(parentNode, node, LF.LFNone) == 0 then
        self:writeSpace()
        self:emitStatement(node)
    else
        self:writeLine()
        self:increaseIndent()
        if node.kind == Kind.EmptyStatement then
            self:emitEmptyStatement(node, true --[[isEmbeddedStatement]])
        else
            self:emitStatement(node)
        end
        self:decreaseIndent()
    end
end

function Printer:emitStatement(node)
    local snippetElement = self.emitContext:SnippetElement(node)
    if snippetElement ~= nil then
        self:emitSnippetNode(node, snippetElement)
        return
    end

    local kind = node.kind
    -- Statements
    if kind == Kind.Block then
        self:emitBlock(node)
    elseif kind == Kind.EmptyStatement then
        self:emitEmptyStatement(node, false --[[isEmbeddedStatement]])
    elseif kind == Kind.VariableStatement then
        self:emitVariableStatement(node)
    elseif kind == Kind.ExpressionStatement then
        self:emitExpressionStatement(node)
    elseif kind == Kind.IfStatement then
        self:emitIfStatement(node)
    elseif kind == Kind.DoStatement then
        self:emitDoStatement(node)
    elseif kind == Kind.WhileStatement then
        self:emitWhileStatement(node)
    elseif kind == Kind.ForStatement then
        self:emitForStatement(node)
    elseif kind == Kind.ForInStatement then
        self:emitForInStatement(node)
    elseif kind == Kind.ForOfStatement then
        self:emitForOfStatement(node)
    elseif kind == Kind.ContinueStatement then
        self:emitContinueStatement(node)
    elseif kind == Kind.BreakStatement then
        self:emitBreakStatement(node)
    elseif kind == Kind.ReturnStatement then
        self:emitReturnStatement(node)
    elseif kind == Kind.WithStatement then
        self:emitWithStatement(node)
    elseif kind == Kind.SwitchStatement then
        self:emitSwitchStatement(node)
    elseif kind == Kind.LabeledStatement then
        self:emitLabeledStatement(node)
    elseif kind == Kind.ThrowStatement then
        self:emitThrowStatement(node)
    elseif kind == Kind.TryStatement then
        self:emitTryStatement(node)
    elseif kind == Kind.DebuggerStatement then
        self:emitDebuggerStatement(node)
    elseif kind == Kind.NotEmittedStatement then
        self:emitNotEmittedStatement(node)

    -- Declaration Statements
    elseif kind == Kind.FunctionDeclaration then
        self:emitFunctionDeclaration(node)
    elseif kind == Kind.ClassDeclaration then
        self:emitClassDeclaration(node)
    elseif kind == Kind.InterfaceDeclaration then
        self:emitInterfaceDeclaration(node)
    elseif kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration then
        self:emitTypeAliasDeclaration(node)
    elseif kind == Kind.EnumDeclaration then
        self:emitEnumDeclaration(node)
    elseif kind == Kind.ModuleDeclaration then
        self:emitModuleDeclaration(node)
    elseif kind == Kind.MissingDeclaration then
        -- break

    -- Import/Export Statements
    elseif kind == Kind.NamespaceExportDeclaration then
        self:emitNamespaceExportDeclaration(node)
    elseif kind == Kind.ImportEqualsDeclaration then
        self:emitImportEqualsDeclaration(node)
    elseif kind == Kind.ImportDeclaration then
        self:emitImportDeclaration(node)
    elseif kind == Kind.ExportAssignment then
        self:emitExportAssignment(node)
    elseif kind == Kind.ExportDeclaration then
        self:emitExportDeclaration(node)
    else
        error("unhandled statement: " .. tostring(ast.Kind_names[kind]), 0)
    end
end

--
-- Module references
--

function Printer:emitExternalModuleReference(node)
    local state = self:enterNode(node)
    self:writeKeyword("require")
    self:writePunctuation("(")
    self:emitExpression(node.expression, OP.DisallowComma)
    self:writePunctuation(")")
    self:exitNode(node, state)
end

--
-- JSX
--

function Printer:emitJsxElement(node)
    local state = self:enterNode(node)
    self:emitJsxOpeningElement(node.openingElement)
    self:emitList(Printer.emitJsxChild, node, node.children, LF.LFJsxElementOrFragmentChildren)
    self:emitJsxClosingElement(node.closingElement)
    self:exitNode(node, state)
end

function Printer:emitJsxSelfClosingElement(node)
    local state = self:enterNode(node)
    self:writePunctuation("<")
    self:emitJsxTagName(node.tagName)
    self:emitTypeArguments(node, node.typeArguments)
    self:writeSpace()
    self:emitJsxAttributes(node.attributes)
    self:writePunctuation("/>")
    self:exitNode(node, state)
end

function Printer:emitJsxFragment(node)
    local state = self:enterNode(node)
    self:emitJsxOpeningFragment(node.openingFragment)
    self:emitList(Printer.emitJsxChild, node, node.children, LF.LFJsxElementOrFragmentChildren)
    self:emitJsxClosingFragment(node.closingFragment)
    self:exitNode(node, state)
end

function Printer:emitJsxOpeningElement(node)
    local state = self:enterNode(node)
    self:writePunctuation("<")
    local indented = self:writeLineSeparatorsAndIndentBefore(node.tagName, node)
    self:emitJsxTagName(node.tagName)
    self:emitTypeArguments(node, node.typeArguments)
    if #node.attributes:Properties() > 0 then
        self:writeSpace()
    end
    self:emitJsxAttributes(node.attributes)
    self:writeLineSeparatorsAfter(node.attributes, node)
    self:decreaseIndentIf(indented)
    self:writePunctuation(">")
    self:exitNode(node, state)
end

function Printer:emitJsxClosingElement(node)
    local state = self:enterNode(node)
    self:writePunctuation("</")
    self:emitJsxTagName(node.tagName)
    self:writePunctuation(">")
    self:exitNode(node, state)
end

function Printer:emitJsxOpeningFragment(node)
    local state = self:enterNode(node)
    self:writePunctuation("<")
    self:writePunctuation(">")
    self:exitNode(node, state)
end

function Printer:emitJsxClosingFragment(node)
    local state = self:enterNode(node)
    self:writePunctuation("</")
    self:writePunctuation(">")
    self:exitNode(node, state)
end

function Printer:emitJsxText(node)
    local state = self:enterNode(node)
    -- TODO(rbuckton): Should this be using `getLiteralTextOfNode` instead?
    self:writeLiteral(node.text)
    self:exitNode(node, state)
end

function Printer:emitJsxAttributes(node)
    local state = self:enterNode(node)
    self:emitList(Printer.emitJsxAttributeLike, node, node.properties, LF.LFJsxElementAttributes)
    self:exitNode(node, state)
end

function Printer:emitJsxAttribute(node)
    local state = self:enterNode(node)
    self:emitJsxAttributeName(node:Name())
    if node.initializer ~= nil then
        self:writePunctuation("=")
        self:emitJsxAttributeValue(node.initializer)
    end
    self:exitNode(node, state)
end

function Printer:emitJsxSpreadAttribute(node)
    local state = self:enterNode(node)
    self:writePunctuation("{...")
    self:emitExpression(node.expression, OP.Lowest)
    self:writePunctuation("}")
    self:exitNode(node, state)
end

function Printer:emitJsxAttributeLike(node)
    if node.kind == Kind.JsxAttribute then
        self:emitJsxAttribute(node)
    elseif node.kind == Kind.JsxSpreadAttribute then
        self:emitJsxSpreadAttribute(node)
    else
        error("unhandled JsxAttributeLike: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitJsxExpression(node)
    local state = self:enterNode(node)
    if node.expression ~= nil or not self.commentsDisabled and not ast.NodeIsSynthesized(node) and self:hasCommentsAtPosition(node:Pos()) then -- preserve empty expressions if they contain comments!
        local indented = self.currentSourceFile ~= nil and not ast.NodeIsSynthesized(node) and printer.GetLinesBetweenPositions(self.currentSourceFile, node:Pos(), node:End()) ~= 0
        self:increaseIndentIf(indented)
        local end_ = self:emitToken(Kind.OpenBraceToken, node:Pos(), WriteKind.Punctuation, node)
        self:emitTokenNode(node.dotDotDotToken)
        if node.expression ~= nil then
            self:emitExpression(node.expression, OP.DisallowComma)
        end
        self:emitToken(Kind.CloseBraceToken, printer.greatestEnd(end_, node.expression, node.dotDotDotToken), WriteKind.Punctuation, node)
        self:decreaseIndentIf(indented)
    end
    self:exitNode(node, state)
end

function Printer:emitJsxNamespacedName(node)
    local state = self:enterNode(node)
    self:emitIdentifierName(node.namespace)
    self:writePunctuation(":")
    self:emitIdentifierName(node:Name())
    self:exitNode(node, state)
end

function Printer:emitJsxChild(node)
    local kind = node.kind
    if kind == Kind.JsxText then
        self:emitJsxText(node)
    elseif kind == Kind.JsxExpression then
        self:emitJsxExpression(node)
    elseif kind == Kind.JsxElement then
        self:emitJsxElement(node)
    elseif kind == Kind.JsxSelfClosingElement then
        self:emitJsxSelfClosingElement(node)
    elseif kind == Kind.JsxFragment then
        self:emitJsxFragment(node)
    else
        error("unhandled JsxChild: " .. tostring(ast.Kind_names[kind]), 0)
    end
end

function Printer:emitJsxTagName(node)
    local kind = node.kind
    if kind == Kind.Identifier then
        self:emitIdentifierReference(node)
    elseif kind == Kind.ThisKeyword then
        self:emitKeywordExpression(node)
    elseif kind == Kind.JsxNamespacedName then
        self:emitJsxNamespacedName(node)
    elseif kind == Kind.PropertyAccessExpression then
        self:emitPropertyAccessExpression(node)
    else
        error("unhandled JsxTagName: " .. tostring(ast.Kind_names[kind]), 0)
    end
end

function Printer:emitJsxAttributeName(node)
    if node.kind == Kind.Identifier then
        self:emitIdentifierName(node)
    elseif node.kind == Kind.JsxNamespacedName then
        self:emitJsxNamespacedName(node)
    else
        error("unhandled JsxAttributeName: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitJsxAttributeValue(node)
    local kind = node.kind
    if kind == Kind.StringLiteral then
        self:emitStringLiteral(node)
    elseif kind == Kind.JsxExpression then
        self:emitJsxExpression(node)
    elseif kind == Kind.JsxElement then
        self:emitJsxElement(node)
    elseif kind == Kind.JsxSelfClosingElement then
        self:emitJsxSelfClosingElement(node)
    elseif kind == Kind.JsxFragment then
        self:emitJsxFragment(node)
    else
        self:emitExpression(node, OP.Lowest)
    end
end

--
-- Clauses
--

function Printer:emitCaseOrDefaultClauseStatements(node, colonPos)
    local statements = node.statements.nodes
    local emitAsSingleStatement = #statements == 1 and
        -- treat synthesized nodes as located on the same line for emit purposes
        (self.currentSourceFile == nil or
            ast.NodeIsSynthesized(node) or
            ast.NodeIsSynthesized(statements[1]) or
            printer.RangeStartPositionsAreOnSameLine(node.loc, statements[1].loc, self.currentSourceFile))

    local format = LF.LFCaseOrDefaultClauseStatements
    if emitAsSingleStatement then
        -- When emitting as a single statement, use writeToken (no comments) for the colon
        -- to avoid duplicating trailing comments that will be picked up by the statement list.
        self:writeTokenText(Kind.ColonToken, WriteKind.Punctuation, colonPos)
        self:writeSpace()
        format = format & ~(LF.LFMultiLine | LF.LFIndented)
    else
        self:emitToken(Kind.ColonToken, colonPos, WriteKind.Punctuation, node)
    end

    self:emitList(Printer.emitStatement, node, node.statements, format)
end

function Printer:emitCaseClause(node)
    local state = self:enterNode(node)
    self:emitToken(Kind.CaseKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitExpression(node.expression, OP.Lowest)
    self:emitCaseOrDefaultClauseStatements(node, node.expression:End())
    self:exitNode(node, state)
end

function Printer:emitDefaultClause(node)
    local state = self:enterNode(node)
    local pos = self:emitToken(Kind.DefaultKeyword, node:Pos(), WriteKind.Keyword, node)
    self:emitCaseOrDefaultClauseStatements(node, pos)
    self:exitNode(node, state)
end

function Printer:emitCaseOrDefaultClauseNode(node)
    if node.kind == Kind.CaseClause then
        self:emitCaseClause(node)
    elseif node.kind == Kind.DefaultClause then
        self:emitDefaultClause(node)
    else
        error("unhandled CaseOrDefaultClause: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitHeritageClause(node)
    local state = self:enterNode(node)
    self:writeSpace()
    self:emitToken(node.token, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()
    self:emitList(Printer.emitHeritageClauseElement, node, node.types, LF.LFHeritageClauseTypes)
    self:exitNode(node, state)
end

function Printer:emitHeritageClauseElement(node)
    if node.kind == Kind.ExpressionWithTypeArguments then
        self:emitExpressionWithTypeArguments(node)
    elseif node.kind == Kind.TypeReference then
        self:emitTypeReference(node)
    else
        error("unhandled HeritageClauseElement: " .. tostring(ast.Kind_names[node.kind]), 0)
    end
end

function Printer:emitHeritageClauseNode(node)
    self:emitHeritageClause(node)
end

function Printer:emitCatchClause(node)
    local state = self:enterNode(node)
    local openParenPos = self:emitToken(Kind.CatchKeyword, node:Pos(), WriteKind.Keyword, node)
    self:writeSpace()

    if node.variableDeclaration ~= nil then
        self:emitToken(Kind.OpenParenToken, openParenPos, WriteKind.Punctuation, node)
        self:emitVariableDeclaration(node.variableDeclaration)
        self:emitToken(Kind.CloseParenToken, node.variableDeclaration:End(), WriteKind.Punctuation, node)
        self:writeSpace()
    end

    self:emitBlock(node.block)
    self:exitNode(node, state)
end

--
-- Property assignments
--

function Printer:emitPropertyAssignment(node)
    local state = self:enterNode(node)
    self:emitPropertyName(node:Name())
    self:writePunctuation(":")
    self:writeSpace()
    -- This is to ensure that we emit comment in the following case:
    --      For example:
    --          obj = {
    --              id: /*comment1*/ ()=>void
    --          }
    -- "comment1" is not considered to be leading comment for node.initializer
    -- but rather a trailing comment on the previous node.
    local initializer = node.initializer
    if self.emitContext:EmitFlags(initializer) & EF.EFNoLeadingComments == 0 then
        local commentRange = self.emitContext:CommentRange(initializer)
        self:emitTrailingComments(commentRange:Pos(), printer.commentSeparatorAfter)
    end
    self:emitExpression(initializer, OP.DisallowComma)
    self:exitNode(node, state)
end

function Printer:emitShorthandPropertyAssignment(node)
    local state = self:enterNode(node)
    self:emitPropertyName(node:Name())
    if node.objectAssignmentInitializer ~= nil then
        self:writeSpace()
        self:writePunctuation("=")
        self:writeSpace()
        self:emitExpression(node.objectAssignmentInitializer, OP.DisallowComma)
    end
    self:exitNode(node, state)
end

function Printer:emitSpreadAssignment(node)
    local state = self:enterNode(node)
    if node.expression ~= nil then
        self:emitToken(Kind.DotDotDotToken, node:Pos(), WriteKind.Punctuation, node)
        self:emitExpression(node.expression, OP.DisallowComma)
    end
    self:exitNode(node, state)
end

--
-- Enum
--

function Printer:emitEnumMember(node)
    local state = self:enterNode(node)
    self:emitPropertyName(node:Name())
    self:emitInitializer(node.initializer, node:Name():End(), node)
    self:exitNode(node, state)
end

function Printer:emitEnumMemberNode(node)
    self:emitEnumMember(node)
end

--
-- JSDoc
--

function Printer:emitJSDocNode(node)
    -- !!!
    error("not implemented", 0)
end
