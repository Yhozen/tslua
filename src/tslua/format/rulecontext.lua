local format = require("tslua.format")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local kindSet = ast.kindSet

---
--- Contexts
---

-- optionSelector = fn(options lsutil.FormatCodeSettings) core.Tristate
-- anyOptionSelector[T] = fn(options lsutil.FormatCodeSettings) T

function format.semicolonOption(options)
    return options.semicolons
end

function format.insertSpaceAfterCommaDelimiterOption(options)
    return options.insertSpaceAfterCommaDelimiter
end

function format.insertSpaceAfterSemicolonInForStatementsOption(options)
    return options.insertSpaceAfterSemicolonInForStatements
end

function format.insertSpaceBeforeAndAfterBinaryOperatorsOption(options)
    return options.insertSpaceBeforeAndAfterBinaryOperators
end

function format.insertSpaceAfterConstructorOption(options)
    return options.insertSpaceAfterConstructor
end

function format.insertSpaceAfterKeywordsInControlFlowStatementsOption(options)
    return options.insertSpaceAfterKeywordsInControlFlowStatements
end

function format.insertSpaceAfterFunctionKeywordForAnonymousFunctionsOption(options)
    return options.insertSpaceAfterFunctionKeywordForAnonymousFunctions
end

function format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesisOption(options)
    return options.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis
end

function format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracketsOption(options)
    return options.insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets
end

function format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracesOption(options)
    return options.insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces
end

function format.insertSpaceAfterOpeningAndBeforeClosingEmptyBracesOption(options)
    return options.insertSpaceAfterOpeningAndBeforeClosingEmptyBraces
end

function format.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBracesOption(options)
    return options.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces
end

function format.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBracesOption(options)
    return options.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces
end

function format.insertSpaceAfterTypeAssertionOption(options)
    return options.insertSpaceAfterTypeAssertion
end

function format.insertSpaceBeforeFunctionParenthesisOption(options)
    return options.insertSpaceBeforeFunctionParenthesis
end

function format.placeOpenBraceOnNewLineForFunctionsOption(options)
    return options.placeOpenBraceOnNewLineForFunctions
end

function format.placeOpenBraceOnNewLineForControlBlocksOption(options)
    return options.placeOpenBraceOnNewLineForControlBlocks
end

function format.insertSpaceBeforeTypeAnnotationOption(options)
    return options.insertSpaceBeforeTypeAnnotation
end

function format.indentMultiLineObjectLiteralBeginningOnBlankLineOption(options)
    return options.indentMultiLineObjectLiteralBeginningOnBlankLine
end

function format.indentSwitchCaseOption(options)
    return options.indentSwitchCase
end

function format.optionEquals(optionName, optionValue)
    return function(context)
        return optionName(context.options) == optionValue
    end
end

function format.isOptionEnabled(optionName)
    return function(context)
        return core.Tristate_IsTrue(optionName(context.options))
    end
end

function format.isOptionDisabled(optionName)
    return function(context)
        return core.Tristate_IsFalse(optionName(context.options))
    end
end

function format.isOptionDisabledOrUndefined(optionName)
    return function(context)
        return core.Tristate_IsFalseOrUnknown(optionName(context.options))
    end
end

function format.isOptionDisabledOrUndefinedOrTokensOnSameLine(optionName)
    return function(context)
        return core.Tristate_IsFalseOrUnknown(optionName(context.options)) or context:TokensAreOnSameLine()
    end
end

function format.isOptionEnabledOrUndefined(optionName)
    return function(context)
        return core.Tristate_IsTrueOrUnknown(optionName(context.options))
    end
end

function format.isForContext(context)
    return context.contextNode.kind == Kind.ForStatement
end

function format.isNotForContext(context)
    return not format.isForContext(context)
end

local binaryOpAlwaysKinds = kindSet(Kind.ConditionalExpression, Kind.ConditionalType, Kind.AsExpression,
    Kind.ExportSpecifier, Kind.ImportSpecifier, Kind.TypePredicate, Kind.UnionType, Kind.IntersectionType,
    Kind.SatisfiesExpression)
-- equals in binding elements func foo([[x, y] = [1, 2]])
-- equals in type X = ...
-- equal in import a = module('a');
-- equal in export = 1
-- equal in let a = 0
-- equal in p = 0
local binaryOpEqualsKinds = kindSet(Kind.BindingElement, Kind.TypeAliasDeclaration, Kind.ImportEqualsDeclaration,
    Kind.ExportAssignment, Kind.VariableDeclaration, Kind.Parameter, Kind.EnumMember, Kind.PropertyDeclaration,
    Kind.PropertySignature)

function format.isBinaryOpContext(context)
    local k = context.contextNode.kind
    if k == Kind.BinaryExpression then
        return context.contextNode:AsBinaryExpression().operatorToken.kind ~= Kind.CommaToken
    elseif binaryOpAlwaysKinds[k] then
        return true
    elseif binaryOpEqualsKinds[k] then
        return context.currentTokenSpan.kind == Kind.EqualsToken or context.nextTokenSpan.kind == Kind.EqualsToken
    -- "in" keyword in for (let x in []) { }
    -- "in" keyword in [P in keyof T] T[P]
    elseif k == Kind.ForInStatement or k == Kind.TypeParameter then
        return context.currentTokenSpan.kind == Kind.InKeyword or context.nextTokenSpan.kind == Kind.InKeyword or
            context.currentTokenSpan.kind == Kind.EqualsToken or context.nextTokenSpan.kind == Kind.EqualsToken
    -- Technically, "of" is not a binary operator, but format it the same way as "in"
    elseif k == Kind.ForOfStatement then
        return context.currentTokenSpan.kind == Kind.OfKeyword or context.nextTokenSpan.kind == Kind.OfKeyword
    end
    return false
end

function format.isNotBinaryOpContext(context)
    return not format.isBinaryOpContext(context)
end

function format.isNotTypeAnnotationContext(context)
    return not format.isTypeAnnotationContext(context)
end

function format.isTypeAnnotationContext(context)
    local contextKind = context.contextNode.kind
    return contextKind == Kind.PropertyDeclaration or
        contextKind == Kind.PropertySignature or
        contextKind == Kind.Parameter or
        contextKind == Kind.VariableDeclaration or
        ast.IsFunctionLikeKind(contextKind)
end

function format.isOptionalPropertyContext(context)
    return ast.IsPropertyDeclaration(context.contextNode) and ast.HasQuestionToken(context.contextNode)
end

function format.isNonOptionalPropertyContext(context)
    return not format.isOptionalPropertyContext(context)
end

function format.isConditionalOperatorContext(context)
    return context.contextNode.kind == Kind.ConditionalExpression or
        context.contextNode.kind == Kind.ConditionalType
end

function format.isSameLineTokenOrBeforeBlockContext(context)
    return context:TokensAreOnSameLine() or format.isBeforeBlockContext(context)
end

function format.isBraceWrappedContext(context)
    return context.contextNode.kind == Kind.ObjectBindingPattern or
        context.contextNode.kind == Kind.MappedType or
        format.isSingleLineBlockContext(context)
end

-- This check is done before an open brace in a control construct, a function, or a typescript block declaration
function format.isBeforeMultilineBlockContext(context)
    return format.isBeforeBlockContext(context) and
        not (context:NextNodeAllOnSameLine() or context:NextNodeBlockIsOnOneLine())
end

function format.isMultilineBlockContext(context)
    return format.isBlockContext(context) and
        not (context:ContextNodeAllOnSameLine() or context:ContextNodeBlockIsOnOneLine())
end

function format.isSingleLineBlockContext(context)
    return format.isBlockContext(context) and
        (context:ContextNodeAllOnSameLine() or context:ContextNodeBlockIsOnOneLine())
end

function format.isBlockContext(context)
    return format.nodeIsBlockContext(context.contextNode)
end

function format.isBeforeBlockContext(context)
    return format.nodeIsBlockContext(context.nextTokenParent)
end

-- IMPORTANT!!! This method must return true ONLY for nodes with open and close braces as immediate children
function format.nodeIsBlockContext(node)
    if format.nodeIsTypeScriptDeclWithBlockContext(node) then
        -- This means we are in a context that looks like a block to the user, but in the grammar is actually not a node (it's a class, module, enum, object type literal, etc).
        return true
    end

    local k = node.kind
    if k == Kind.Block or
        k == Kind.CaseBlock or
        k == Kind.ObjectLiteralExpression or
        k == Kind.ModuleBlock then
        return true
    end

    return false
end

-- case ast.KindMemberFunctionDeclaration:
-- case ast.KindMethodSignature:
-- case ast.KindConstructorDeclaration:
-- case ast.KindSimpleArrowFunctionExpression:
-- case ast.KindParenthesizedArrowFunctionExpression:
local functionDeclContextKinds = kindSet(Kind.FunctionDeclaration, Kind.MethodDeclaration, Kind.MethodSignature,
    Kind.GetAccessor, Kind.SetAccessor, Kind.CallSignature, Kind.FunctionExpression, Kind.Constructor,
    Kind.ArrowFunction,
    Kind.InterfaceDeclaration) -- This one is not truly a function, but for formatting purposes, it acts just like one

function format.isFunctionDeclContext(context)
    return functionDeclContextKinds[context.contextNode.kind] == true
end

function format.isNotFunctionDeclContext(context)
    return not format.isFunctionDeclContext(context)
end

function format.isFunctionDeclarationOrFunctionExpressionContext(context)
    return context.contextNode.kind == Kind.FunctionDeclaration or context.contextNode.kind == Kind.FunctionExpression
end

function format.isTypeScriptDeclWithBlockContext(context)
    return format.nodeIsTypeScriptDeclWithBlockContext(context.contextNode)
end

local typeScriptDeclWithBlockContextKinds = kindSet(Kind.ClassDeclaration, Kind.ClassExpression,
    Kind.InterfaceDeclaration, Kind.EnumDeclaration, Kind.TypeLiteral, Kind.ModuleDeclaration, Kind.ExportDeclaration,
    Kind.NamedExports, Kind.ImportDeclaration, Kind.NamedImports)

function format.nodeIsTypeScriptDeclWithBlockContext(node)
    return typeScriptDeclWithBlockContextKinds[node.kind] == true
end

local afterCodeBlockContextKinds = kindSet(Kind.ClassDeclaration, Kind.ModuleDeclaration, Kind.EnumDeclaration,
    Kind.CatchClause, Kind.ModuleBlock, Kind.SwitchStatement)

function format.isAfterCodeBlockContext(context)
    local k = context.currentTokenParent.kind
    if afterCodeBlockContextKinds[k] then
        return true
    elseif k == Kind.Block then
        local blockParent = context.currentTokenParent.parent
        -- In a codefix scenario, we can't rely on parents being set. So just always return true.
        if blockParent == nil or blockParent.kind ~= Kind.ArrowFunction and blockParent.kind ~= Kind.FunctionExpression then
            return true
        end
    end
    return false
end

-- TODO
-- case ast.KindElseClause:
local controlDeclContextKinds = kindSet(Kind.IfStatement, Kind.SwitchStatement, Kind.ForStatement,
    Kind.ForInStatement, Kind.ForOfStatement, Kind.WhileStatement, Kind.TryStatement, Kind.DoStatement,
    Kind.WithStatement, Kind.CatchClause)

function format.isControlDeclContext(context)
    return controlDeclContextKinds[context.contextNode.kind] == true
end

function format.isObjectContext(context)
    return context.contextNode.kind == Kind.ObjectLiteralExpression
end

function format.isFunctionCallContext(context)
    return context.contextNode.kind == Kind.CallExpression
end

function format.isNewContext(context)
    return context.contextNode.kind == Kind.NewExpression
end

function format.isFunctionCallOrNewContext(context)
    return format.isFunctionCallContext(context) or format.isNewContext(context)
end

function format.isPreviousTokenNotComma(context)
    return context.currentTokenSpan.kind ~= Kind.CommaToken
end

function format.isNextTokenNotCloseBracket(context)
    return context.nextTokenSpan.kind ~= Kind.CloseBracketToken
end

function format.isNextTokenNotCloseParen(context)
    return context.nextTokenSpan.kind ~= Kind.CloseParenToken
end

function format.isArrowFunctionContext(context)
    return context.contextNode.kind == Kind.ArrowFunction
end

function format.isImportTypeContext(context)
    return context.contextNode.kind == Kind.ImportType
end

function format.isNonJsxSameLineTokenContext(context)
    return context:TokensAreOnSameLine() and context.contextNode.kind ~= Kind.JsxText
end

function format.isNonJsxTextContext(context)
    return context.contextNode.kind ~= Kind.JsxText
end

function format.isNonJsxElementOrFragmentContext(context)
    return context.contextNode.kind ~= Kind.JsxElement and context.contextNode.kind ~= Kind.JsxFragment
end

function format.isJsxExpressionContext(context)
    return context.contextNode.kind == Kind.JsxExpression or context.contextNode.kind == Kind.JsxSpreadAttribute
end

function format.isNextTokenParentJsxAttribute(context)
    return context.nextTokenParent.kind == Kind.JsxAttribute or
        (context.nextTokenParent.kind == Kind.JsxNamespacedName and
            context.nextTokenParent.parent.kind == Kind.JsxAttribute)
end

function format.isJsxAttributeContext(context)
    return context.contextNode.kind == Kind.JsxAttribute
end

function format.isNextTokenParentNotJsxNamespacedName(context)
    return context.nextTokenParent.kind ~= Kind.JsxNamespacedName
end

function format.isNextTokenParentJsxNamespacedName(context)
    return context.nextTokenParent.kind == Kind.JsxNamespacedName
end

function format.isJsxSelfClosingElementContext(context)
    return context.contextNode.kind == Kind.JsxSelfClosingElement
end

function format.isNotBeforeBlockInFunctionDeclarationContext(context)
    return not format.isFunctionDeclContext(context) and not format.isBeforeBlockContext(context)
end

function format.isEndOfDecoratorContextOnSameLine(context)
    return context:TokensAreOnSameLine() and
        ast.HasDecorators(context.contextNode) and
        format.nodeIsInDecoratorContext(context.currentTokenParent) and
        not format.nodeIsInDecoratorContext(context.nextTokenParent)
end

function format.nodeIsInDecoratorContext(node)
    while node ~= nil and ast.IsExpression(node) do
        node = node.parent
    end
    return node ~= nil and node.kind == Kind.Decorator
end

function format.isStartOfVariableDeclarationList(context)
    return context.currentTokenParent.kind == Kind.VariableDeclarationList and
        scanner.GetTokenPosOfNode(context.currentTokenParent, context.sourceFile, false) ==
        context.currentTokenSpan.loc:Pos()
end

function format.isNotFormatOnEnter(context)
    return context.formattingRequestKind ~= format.FormatRequestKind.FormatOnEnter
end

function format.isModuleDeclContext(context)
    return context.contextNode.kind == Kind.ModuleDeclaration
end

function format.isObjectTypeContext(context)
    return context.contextNode.kind == Kind.TypeLiteral -- && context.contextNode.parent.Kind != ast.KindInterfaceDeclaration;
end

function format.isConstructorSignatureContext(context)
    return context.contextNode.kind == Kind.ConstructSignature
end

local typeArgumentOrParameterOrAssertionKinds = kindSet(Kind.TypeReference, Kind.TypeAssertionExpression,
    Kind.TypeAliasDeclaration, Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ArrowFunction, Kind.MethodDeclaration,
    Kind.MethodSignature, Kind.CallSignature, Kind.ConstructSignature, Kind.CallExpression, Kind.NewExpression,
    Kind.ExpressionWithTypeArguments)

function format.isTypeArgumentOrParameterOrAssertion(token, parent)
    if token.kind ~= Kind.LessThanToken and token.kind ~= Kind.GreaterThanToken then
        return false
    end
    return typeArgumentOrParameterOrAssertionKinds[parent.kind] == true
end

function format.isTypeArgumentOrParameterOrAssertionContext(context)
    return format.isTypeArgumentOrParameterOrAssertion(context.currentTokenSpan, context.currentTokenParent) or
        format.isTypeArgumentOrParameterOrAssertion(context.nextTokenSpan, context.nextTokenParent)
end

function format.isTypeAssertionContext(context)
    return context.contextNode.kind == Kind.TypeAssertionExpression
end

function format.isNonTypeAssertionContext(context)
    return not format.isTypeAssertionContext(context)
end

function format.isVoidOpContext(context)
    return context.currentTokenSpan.kind == Kind.VoidKeyword and context.currentTokenParent.kind == Kind.VoidExpression
end

function format.isYieldOrYieldStarWithOperand(context)
    return context.contextNode.kind == Kind.YieldExpression and context.contextNode:Expression() ~= nil
end

function format.isNonNullAssertionContext(context)
    return context.contextNode.kind == Kind.NonNullExpression
end

function format.isNotStatementConditionContext(context)
    return not format.isStatementConditionContext(context)
end

local statementConditionContextKinds = kindSet(Kind.IfStatement, Kind.ForStatement, Kind.ForInStatement,
    Kind.ForOfStatement, Kind.DoStatement, Kind.WhileStatement)

function format.isStatementConditionContext(context)
    return statementConditionContextKinds[context.contextNode.kind] == true
end

function format.isSemicolonDeletionContext(context)
    local nextTokenKind = context.nextTokenSpan.kind
    local nextTokenStart = context.nextTokenSpan.loc:Pos()
    if ast.IsTrivia(nextTokenKind) then
        local nextRealToken
        if context.nextTokenParent == context.currentTokenParent then
            -- !!! TODO: very different from strada, but strada's logic here is wonky - find the first ancestor without a parent? that's just the source file.
            nextRealToken = astnav.FindNextToken(context.nextTokenParent, context.sourceFile:AsNode(), context.sourceFile)
        else
            nextRealToken = lsutil.GetFirstToken(context.nextTokenParent, context.sourceFile)
        end

        if nextRealToken == nil then
            return true
        end
        nextTokenKind = nextRealToken.kind
        nextTokenStart = scanner.GetTokenPosOfNode(nextRealToken, context.sourceFile, false)
    end

    local startLine = scanner.GetECMALineOfPosition(context.sourceFile, context.currentTokenSpan.loc:Pos())
    local endLine = scanner.GetECMALineOfPosition(context.sourceFile, nextTokenStart)
    if startLine == endLine then
        return nextTokenKind == Kind.CloseBraceToken or nextTokenKind == Kind.EndOfFile
    end

    if nextTokenKind == Kind.SemicolonToken and
        context.currentTokenSpan.kind == Kind.SemicolonToken then
        return true
    end

    if nextTokenKind == Kind.SemicolonClassElement or
        nextTokenKind == Kind.SemicolonToken then
        return false
    end

    if context.contextNode.kind == Kind.InterfaceDeclaration or
        context.contextNode.kind == Kind.TypeAliasDeclaration then
        -- Can't remove semicolon after `foo`; it would parse as a method declaration:
        --
        -- interface I {
        --   foo;
        --   () void
        -- }
        return context.currentTokenParent.kind ~= Kind.PropertySignature or
            context.currentTokenParent:Type() ~= nil or
            nextTokenKind ~= Kind.OpenParenToken
    end

    if ast.IsPropertyDeclaration(context.currentTokenParent) then
        return context.currentTokenParent:Initializer() == nil
    end

    return context.currentTokenParent.kind ~= Kind.ForStatement and
        context.currentTokenParent.kind ~= Kind.EmptyStatement and
        context.currentTokenParent.kind ~= Kind.SemicolonClassElement and
        nextTokenKind ~= Kind.OpenBracketToken and
        nextTokenKind ~= Kind.OpenParenToken and
        nextTokenKind ~= Kind.PlusToken and
        nextTokenKind ~= Kind.MinusToken and
        nextTokenKind ~= Kind.SlashToken and
        nextTokenKind ~= Kind.RegularExpressionLiteral and
        nextTokenKind ~= Kind.CommaToken and
        nextTokenKind ~= Kind.TemplateExpression and
        nextTokenKind ~= Kind.TemplateHead and
        nextTokenKind ~= Kind.NoSubstitutionTemplateLiteral and
        nextTokenKind ~= Kind.DotToken
end

function format.isSemicolonInsertionContext(context)
    return lsutil.PositionIsASICandidate(context.currentTokenSpan.loc:End(), context.currentTokenParent,
        context.sourceFile)
end

function format.isNotPropertyAccessOnIntegerLiteral(context)
    return not ast.IsPropertyAccessExpression(context.contextNode) or
        not ast.IsNumericLiteral(context.contextNode:Expression()) or
        string.find(context.contextNode:Expression():Text(), ".", 1, true) ~= nil
end
