local format = require("tslua.format")
local ast = require("tslua.ast")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")

local Kind = ast.Kind
local ruleAction = format.ruleAction
local ruleFlags = format.ruleFlags

-- Go slices.Contains
local function slicesContains(xs, v)
    for _, x in ipairs(xs) do
        if x == v then
            return true
        end
    end
    return false
end

function format.getAllRules()
    local allTokens = {}
    for token = Kind.FirstToken, Kind.LastToken do
        if token ~= Kind.EndOfFile then
            allTokens[#allTokens + 1] = token
        end
    end

    local function anyTokenExcept(...)
        local tokens = { ... }
        local newTokens = {}
        for _, token in ipairs(allTokens) do
            if not slicesContains(tokens, token) then
                newTokens[#newTokens + 1] = token
            end
        end
        return {
            isSpecific = false,
            tokens = newTokens,
        }
    end

    local anyToken = {
        isSpecific = false,
        tokens = allTokens,
    }

    -- Go's `append(allTokens, ...)` in tokenRangeFromEx writes into the spare capacity of allTokens
    -- (allocated for every token including EndOfFile), so both ranges below share one backing array
    -- and the second append overwrites the element written by the first: both end in EndOfFile.
    local anyTokenIncludingMultilineComments = format.tokenRangeFromEx(allTokens, Kind.EndOfFile)
    local anyTokenIncludingEOF = format.tokenRangeFromEx(allTokens, Kind.EndOfFile)
    local keywords = format.tokenRangeFromRange(Kind.FirstKeyword, Kind.LastKeyword)
    local binaryOperators = format.tokenRangeFromRange(Kind.FirstBinaryOperator, Kind.LastBinaryOperator)
    local binaryKeywordOperators = {
        Kind.InKeyword,
        Kind.InstanceOfKeyword,
        Kind.OfKeyword,
        Kind.AsKeyword,
        Kind.IsKeyword,
        Kind.SatisfiesKeyword,
    }
    local unaryPrefixOperators = {Kind.PlusPlusToken, Kind.MinusToken, Kind.TildeToken, Kind.ExclamationToken}
    local unaryPrefixExpressions = {
        Kind.NumericLiteral,
        Kind.BigIntLiteral,
        Kind.Identifier,
        Kind.OpenParenToken,
        Kind.OpenBracketToken,
        Kind.OpenBraceToken,
        Kind.ThisKeyword,
        Kind.NewKeyword,
    }
    local unaryPreincrementExpressions = {Kind.Identifier, Kind.OpenParenToken, Kind.ThisKeyword, Kind.NewKeyword}
    local unaryPostincrementExpressions = {Kind.Identifier, Kind.CloseParenToken, Kind.CloseBracketToken, Kind.NewKeyword}
    local unaryPredecrementExpressions = {Kind.Identifier, Kind.OpenParenToken, Kind.ThisKeyword, Kind.NewKeyword}
    local unaryPostdecrementExpressions = {Kind.Identifier, Kind.CloseParenToken, Kind.CloseBracketToken, Kind.NewKeyword}
    local comments = {Kind.SingleLineCommentTrivia, Kind.MultiLineCommentTrivia}
    local typeKeywords = {
        Kind.AnyKeyword,
        Kind.AssertsKeyword,
        Kind.BigIntKeyword,
        Kind.BooleanKeyword,
        Kind.FalseKeyword,
        Kind.InferKeyword,
        Kind.KeyOfKeyword,
        Kind.NeverKeyword,
        Kind.NullKeyword,
        Kind.NumberKeyword,
        Kind.ObjectKeyword,
        Kind.ReadonlyKeyword,
        Kind.StringKeyword,
        Kind.SymbolKeyword,
        Kind.TypeOfKeyword,
        Kind.TrueKeyword,
        Kind.VoidKeyword,
        Kind.UndefinedKeyword,
        Kind.UniqueKeyword,
        Kind.UnknownKeyword,
    }
    local typeNames = core.Concatenate({ Kind.Identifier }, typeKeywords)

    -- Place a space before open brace in a function declaration
    -- TypeScript: Function can have return types, which can be made of tons of different token kinds
    local functionOpenBraceLeftTokenRange = anyTokenIncludingMultilineComments

    -- Place a space before open brace in a TypeScript declaration that has braces as children (class, module, enum, etc)
    local typeScriptOpenBraceLeftTokenRange = format.tokenRangeFrom(Kind.Identifier, Kind.GreaterThanToken, Kind.MultiLineCommentTrivia, Kind.ClassKeyword, Kind.ExportKeyword, Kind.ImportKeyword)

    -- Place a space before open brace in a control flow construct
    local controlOpenBraceLeftTokenRange = format.tokenRangeFrom(Kind.CloseParenToken, Kind.MultiLineCommentTrivia, Kind.DoKeyword, Kind.TryKeyword, Kind.FinallyKeyword, Kind.ElseKeyword, Kind.CatchKeyword)

    -- These rules are higher in priority than user-configurable
    local highPriorityCommonRules = {
        -- Leave comments alone
        format.rule("IgnoreBeforeComment", anyToken, comments, format.anyContext, ruleAction.StopProcessingSpaceActions),
        format.rule("IgnoreAfterLineComment", Kind.SingleLineCommentTrivia, anyToken, format.anyContext, ruleAction.StopProcessingSpaceActions),

        format.rule("NotSpaceBeforeColon", anyToken, Kind.ColonToken, {format.isNonJsxSameLineTokenContext, format.isNotBinaryOpContext, format.isNotTypeAnnotationContext}, ruleAction.DeleteSpace),
        format.rule("SpaceAfterColon", Kind.ColonToken, anyToken, {format.isNonJsxSameLineTokenContext, format.isNotBinaryOpContext, format.isNextTokenParentNotJsxNamespacedName}, ruleAction.InsertSpace),
        format.rule("NoSpaceBeforeQuestionMark", anyToken, Kind.QuestionToken, {format.isNonJsxSameLineTokenContext, format.isNotBinaryOpContext, format.isNotTypeAnnotationContext}, ruleAction.DeleteSpace),
        -- insert space after '?' only when it is used in conditional operator
        format.rule("SpaceAfterQuestionMarkInConditionalOperator", Kind.QuestionToken, anyToken, {format.isNonJsxSameLineTokenContext, format.isConditionalOperatorContext}, ruleAction.InsertSpace),

        -- in other cases there should be no space between '?' and next token
        format.rule("NoSpaceAfterQuestionMark", Kind.QuestionToken, anyToken, {format.isNonJsxSameLineTokenContext, format.isNonOptionalPropertyContext}, ruleAction.DeleteSpace),

        format.rule("NoSpaceBeforeDot", anyToken, {Kind.DotToken, Kind.QuestionDotToken}, {format.isNonJsxSameLineTokenContext, format.isNotPropertyAccessOnIntegerLiteral}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterDot", {Kind.DotToken, Kind.QuestionDotToken}, anyToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        format.rule("NoSpaceBetweenImportParenInImportType", Kind.ImportKeyword, Kind.OpenParenToken, {format.isNonJsxSameLineTokenContext, format.isImportTypeContext}, ruleAction.DeleteSpace),

        -- Special handling of unary operators.
        -- Prefix operators generally shouldn't have a space between
        -- them and their target unary expression.
        format.rule("NoSpaceAfterUnaryPrefixOperator", unaryPrefixOperators, unaryPrefixExpressions, {format.isNonJsxSameLineTokenContext, format.isNotBinaryOpContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterUnaryPreincrementOperator", Kind.PlusPlusToken, unaryPreincrementExpressions, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterUnaryPredecrementOperator", Kind.MinusMinusToken, unaryPredecrementExpressions, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeUnaryPostincrementOperator", unaryPostincrementExpressions, Kind.PlusPlusToken, {format.isNonJsxSameLineTokenContext, format.isNotStatementConditionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeUnaryPostdecrementOperator", unaryPostdecrementExpressions, Kind.MinusMinusToken, {format.isNonJsxSameLineTokenContext, format.isNotStatementConditionContext}, ruleAction.DeleteSpace),

        -- More unary operator special-casing.
        -- DevDiv 181814: Be careful when removing leading whitespace
        -- around unary operators.  Examples:
        --      1 - -2  --X--> 1--2
        --      a + ++b --X--> a+++b
        format.rule("SpaceAfterPostincrementWhenFollowedByAdd", Kind.PlusPlusToken, Kind.PlusToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterAddWhenFollowedByUnaryPlus", Kind.PlusToken, Kind.PlusToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterAddWhenFollowedByPreincrement", Kind.PlusToken, Kind.PlusPlusToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterPostdecrementWhenFollowedBySubtract", Kind.MinusMinusToken, Kind.MinusToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterSubtractWhenFollowedByUnaryMinus", Kind.MinusToken, Kind.MinusToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterSubtractWhenFollowedByPredecrement", Kind.MinusToken, Kind.MinusMinusToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),

        format.rule("NoSpaceAfterCloseBrace", Kind.CloseBraceToken, {Kind.CommaToken, Kind.SemicolonToken}, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        -- For functions and control block place } on a new line {multi-line rule}
        format.rule("NewLineBeforeCloseBraceInBlockContext", anyTokenIncludingMultilineComments, Kind.CloseBraceToken, {format.isMultilineBlockContext}, ruleAction.InsertNewLine),

        -- Space/new line after }.
        format.rule("SpaceAfterCloseBrace", Kind.CloseBraceToken, anyTokenExcept(Kind.CloseParenToken), {format.isNonJsxSameLineTokenContext, format.isAfterCodeBlockContext}, ruleAction.InsertSpace),
        -- Special case for (}, else) and (}, while) since else & while tokens are not part of the tree which makes SpaceAfterCloseBrace rule not applied
        -- Also should not apply to })
        format.rule("SpaceBetweenCloseBraceAndElse", Kind.CloseBraceToken, Kind.ElseKeyword, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceBetweenCloseBraceAndWhile", Kind.CloseBraceToken, Kind.WhileKeyword, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBetweenEmptyBraceBrackets", Kind.OpenBraceToken, Kind.CloseBraceToken, {format.isNonJsxSameLineTokenContext, format.isObjectContext}, ruleAction.DeleteSpace),

        -- Add a space after control dec context if the next character is an open bracket ex: 'if (false){a, b} = {1, 2};' -> 'if (false) {a, b} = {1, 2};'
        format.rule("SpaceAfterConditionalClosingParen", Kind.CloseParenToken, Kind.OpenBracketToken, {format.isControlDeclContext}, ruleAction.InsertSpace),

        format.rule("NoSpaceBetweenFunctionKeywordAndStar", Kind.FunctionKeyword, Kind.AsteriskToken, {format.isFunctionDeclarationOrFunctionExpressionContext}, ruleAction.DeleteSpace),
        format.rule("SpaceAfterStarInGeneratorDeclaration", Kind.AsteriskToken, Kind.Identifier, {format.isFunctionDeclarationOrFunctionExpressionContext}, ruleAction.InsertSpace),

        format.rule("SpaceAfterFunctionInFuncDecl", Kind.FunctionKeyword, anyToken, {format.isFunctionDeclContext}, ruleAction.InsertSpace),
        -- Insert new line after { and before } in multi-line contexts.
        format.rule("NewLineAfterOpenBraceInBlockContext", Kind.OpenBraceToken, anyToken, {format.isMultilineBlockContext}, ruleAction.InsertNewLine),

        -- For get/set members, we check for (identifier,identifier) since get/set don't have tokens and they are represented as just an identifier token.
        -- Though, we do extra check on the context to make sure we are dealing with get/set node. Example:
        --      get x() {}
        --      set x(val) {}
        format.rule("SpaceAfterGetSetInMember", {Kind.GetKeyword, Kind.SetKeyword}, Kind.Identifier, {format.isFunctionDeclContext}, ruleAction.InsertSpace),

        format.rule("NoSpaceBetweenYieldKeywordAndStar", Kind.YieldKeyword, Kind.AsteriskToken, {format.isNonJsxSameLineTokenContext, format.isYieldOrYieldStarWithOperand}, ruleAction.DeleteSpace),
        format.rule("SpaceBetweenYieldOrYieldStarAndOperand", {Kind.YieldKeyword, Kind.AsteriskToken}, anyToken, {format.isNonJsxSameLineTokenContext, format.isYieldOrYieldStarWithOperand}, ruleAction.InsertSpace),

        format.rule("NoSpaceBetweenReturnAndSemicolon", Kind.ReturnKeyword, Kind.SemicolonToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("SpaceAfterCertainKeywords", {Kind.VarKeyword, Kind.ThrowKeyword, Kind.NewKeyword, Kind.DeleteKeyword, Kind.ReturnKeyword, Kind.TypeOfKeyword, Kind.AwaitKeyword}, anyToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterLetConstInVariableDeclaration", {Kind.LetKeyword, Kind.ConstKeyword}, anyToken, {format.isNonJsxSameLineTokenContext, format.isStartOfVariableDeclarationList}, ruleAction.InsertSpace),
        format.rule("NoSpaceBeforeOpenParenInFuncCall", anyToken, Kind.OpenParenToken, {format.isNonJsxSameLineTokenContext, format.isFunctionCallOrNewContext, format.isPreviousTokenNotComma}, ruleAction.DeleteSpace),

        -- Special case for binary operators (that are keywords). For these we have to add a space and shouldn't follow any user options.
        format.rule("SpaceBeforeBinaryKeywordOperator", anyToken, binaryKeywordOperators, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterBinaryKeywordOperator", binaryKeywordOperators, anyToken, {format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),

        format.rule("SpaceAfterVoidOperator", Kind.VoidKeyword, anyToken, {format.isNonJsxSameLineTokenContext, format.isVoidOpContext}, ruleAction.InsertSpace),

        -- Async-await
        format.rule("SpaceBetweenAsyncAndOpenParen", Kind.AsyncKeyword, Kind.OpenParenToken, {format.isArrowFunctionContext, format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceBetweenAsyncAndFunctionKeyword", Kind.AsyncKeyword, {Kind.FunctionKeyword, Kind.Identifier}, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),

        -- Template string
        format.rule("NoSpaceBetweenTagAndTemplateString", {Kind.Identifier, Kind.CloseParenToken}, {Kind.NoSubstitutionTemplateLiteral, Kind.TemplateHead}, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- JSX opening elements
        format.rule("SpaceBeforeJsxAttribute", anyToken, Kind.Identifier, {format.isNextTokenParentJsxAttribute, format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceBeforeSlashInJsxOpeningElement", anyToken, Kind.SlashToken, {format.isJsxSelfClosingElementContext, format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBeforeGreaterThanTokenInJsxOpeningElement", Kind.SlashToken, Kind.GreaterThanToken, {format.isJsxSelfClosingElementContext, format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeEqualInJsxAttribute", anyToken, Kind.EqualsToken, {format.isJsxAttributeContext, format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterEqualInJsxAttribute", Kind.EqualsToken, anyToken, {format.isJsxAttributeContext, format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeJsxNamespaceColon", Kind.Identifier, Kind.ColonToken, {format.isNextTokenParentJsxNamespacedName}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterJsxNamespaceColon", Kind.ColonToken, Kind.Identifier, {format.isNextTokenParentJsxNamespacedName}, ruleAction.DeleteSpace),

        -- TypeScript-specific rules
        -- Use of module as a function call. e.g.: import m2 = module("m2");
        format.rule("NoSpaceAfterModuleImport", {Kind.ModuleKeyword, Kind.RequireKeyword}, Kind.OpenParenToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        -- Add a space around certain TypeScript keywords
        format.rule(
            "SpaceAfterCertainTypeScriptKeywords",
            {
                Kind.AbstractKeyword,
                Kind.AccessorKeyword,
                Kind.ClassKeyword,
                Kind.DeclareKeyword,
                Kind.DefaultKeyword,
                Kind.EnumKeyword,
                Kind.ExportKeyword,
                Kind.ExtendsKeyword,
                Kind.GetKeyword,
                Kind.ImplementsKeyword,
                Kind.ImportKeyword,
                Kind.InterfaceKeyword,
                Kind.ModuleKeyword,
                Kind.NamespaceKeyword,
                Kind.OverrideKeyword,
                Kind.PrivateKeyword,
                Kind.PublicKeyword,
                Kind.ProtectedKeyword,
                Kind.ReadonlyKeyword,
                Kind.SetKeyword,
                Kind.StaticKeyword,
                Kind.TypeKeyword,
                Kind.FromKeyword,
                Kind.KeyOfKeyword,
                Kind.InferKeyword,
            },
            anyToken,
            {format.isNonJsxSameLineTokenContext},
            ruleAction.InsertSpace
        ),
        format.rule(
            "SpaceBeforeCertainTypeScriptKeywords",
            anyToken,
            {Kind.ExtendsKeyword, Kind.ImplementsKeyword, Kind.FromKeyword},
            {format.isNonJsxSameLineTokenContext},
            ruleAction.InsertSpace
        ),
        -- Treat string literals in module names as identifiers, and add a space between the literal and the opening Brace braces, e.g.: module "m2" {
        format.rule("SpaceAfterModuleName", Kind.StringLiteral, Kind.OpenBraceToken, {format.isModuleDeclContext}, ruleAction.InsertSpace),

        -- Lambda expressions
        format.rule("SpaceBeforeArrow", anyToken, Kind.EqualsGreaterThanToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterArrow", Kind.EqualsGreaterThanToken, anyToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),

        -- Optional parameters and let args
        format.rule("NoSpaceAfterEllipsis", Kind.DotDotDotToken, Kind.Identifier, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterOptionalParameters", Kind.QuestionToken, {Kind.CloseParenToken, Kind.CommaToken}, {format.isNonJsxSameLineTokenContext, format.isNotBinaryOpContext}, ruleAction.DeleteSpace),

        -- Remove spaces in empty interface literals. e.g.: x: {}
        format.rule("NoSpaceBetweenEmptyInterfaceBraceBrackets", Kind.OpenBraceToken, Kind.CloseBraceToken, {format.isNonJsxSameLineTokenContext, format.isObjectTypeContext}, ruleAction.DeleteSpace),

        -- generics and type assertions
        format.rule("NoSpaceBeforeOpenAngularBracket", typeNames, Kind.LessThanToken, {format.isNonJsxSameLineTokenContext, format.isTypeArgumentOrParameterOrAssertionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBetweenCloseParenAndAngularBracket", Kind.CloseParenToken, Kind.LessThanToken, {format.isNonJsxSameLineTokenContext, format.isTypeArgumentOrParameterOrAssertionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterOpenAngularBracket", Kind.LessThanToken, anyToken, {format.isNonJsxSameLineTokenContext, format.isTypeArgumentOrParameterOrAssertionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeCloseAngularBracket", anyToken, Kind.GreaterThanToken, {format.isNonJsxSameLineTokenContext, format.isTypeArgumentOrParameterOrAssertionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterCloseAngularBracket", Kind.GreaterThanToken, {Kind.OpenParenToken, Kind.OpenBracketToken, Kind.GreaterThanToken, Kind.CommaToken}, {
            format.isNonJsxSameLineTokenContext,
            format.isTypeArgumentOrParameterOrAssertionContext,
            format.isNotFunctionDeclContext, --[[To prevent an interference with the SpaceBeforeOpenParenInFuncDecl rule]]
            format.isNonTypeAssertionContext,
        }, ruleAction.DeleteSpace),

        -- decorators
        format.rule("SpaceBeforeAt", {Kind.CloseParenToken, Kind.Identifier}, Kind.AtToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterAt", Kind.AtToken, anyToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        -- Insert space after @ in decorator
        format.rule(
            "SpaceAfterDecorator",
            anyToken,
            {
                Kind.AbstractKeyword,
                Kind.Identifier,
                Kind.ExportKeyword,
                Kind.DefaultKeyword,
                Kind.ClassKeyword,
                Kind.StaticKeyword,
                Kind.PublicKeyword,
                Kind.PrivateKeyword,
                Kind.ProtectedKeyword,
                Kind.GetKeyword,
                Kind.SetKeyword,
                Kind.OpenBracketToken,
                Kind.AsteriskToken,
            },
            {format.isEndOfDecoratorContextOnSameLine},
            ruleAction.InsertSpace
        ),

        format.rule("NoSpaceBeforeNonNullAssertionOperator", anyToken, Kind.ExclamationToken, {format.isNonJsxSameLineTokenContext, format.isNonNullAssertionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterNewKeywordOnConstructorSignature", Kind.NewKeyword, Kind.OpenParenToken, {format.isNonJsxSameLineTokenContext, format.isConstructorSignatureContext}, ruleAction.DeleteSpace),
        format.rule("SpaceLessThanAndNonJSXTypeAnnotation", Kind.LessThanToken, Kind.LessThanToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
    }

    -- These rules are applied after high priority
    local userConfigurableRules = {
        -- Treat constructor as an identifier in a function declaration, and remove spaces between constructor and following left parentheses
        format.rule("SpaceAfterConstructor", Kind.ConstructorKeyword, Kind.OpenParenToken, {format.isOptionEnabled(format.insertSpaceAfterConstructorOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterConstructor", Kind.ConstructorKeyword, Kind.OpenParenToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterConstructorOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        format.rule("SpaceAfterComma", Kind.CommaToken, anyToken, {format.isOptionEnabled(format.insertSpaceAfterCommaDelimiterOption), format.isNonJsxSameLineTokenContext, format.isNonJsxElementOrFragmentContext, format.isNextTokenNotCloseBracket, format.isNextTokenNotCloseParen}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterComma", Kind.CommaToken, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterCommaDelimiterOption), format.isNonJsxSameLineTokenContext, format.isNonJsxElementOrFragmentContext}, ruleAction.DeleteSpace),

        -- Insert space after function keyword for anonymous functions
        format.rule("SpaceAfterAnonymousFunctionKeyword", {Kind.FunctionKeyword, Kind.AsteriskToken}, Kind.OpenParenToken, {format.isOptionEnabled(format.insertSpaceAfterFunctionKeywordForAnonymousFunctionsOption), format.isFunctionDeclContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterAnonymousFunctionKeyword", {Kind.FunctionKeyword, Kind.AsteriskToken}, Kind.OpenParenToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterFunctionKeywordForAnonymousFunctionsOption), format.isFunctionDeclContext}, ruleAction.DeleteSpace),

        -- Insert space after keywords in control flow statements
        format.rule("SpaceAfterKeywordInControl", keywords, Kind.OpenParenToken, {format.isOptionEnabled(format.insertSpaceAfterKeywordsInControlFlowStatementsOption), format.isControlDeclContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterKeywordInControl", keywords, Kind.OpenParenToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterKeywordsInControlFlowStatementsOption), format.isControlDeclContext}, ruleAction.DeleteSpace),

        -- Insert space after opening and before closing nonempty parenthesis
        format.rule("SpaceAfterOpenParen", Kind.OpenParenToken, anyToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesisOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceBeforeCloseParen", anyToken, Kind.CloseParenToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesisOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceBetweenOpenParens", Kind.OpenParenToken, Kind.OpenParenToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesisOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBetweenParens", Kind.OpenParenToken, Kind.CloseParenToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterOpenParen", Kind.OpenParenToken, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesisOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeCloseParen", anyToken, Kind.CloseParenToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesisOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- Insert space after opening and before closing nonempty brackets
        format.rule("SpaceAfterOpenBracket", Kind.OpenBracketToken, anyToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracketsOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("SpaceBeforeCloseBracket", anyToken, Kind.CloseBracketToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracketsOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBetweenBrackets", Kind.OpenBracketToken, Kind.CloseBracketToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterOpenBracket", Kind.OpenBracketToken, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracketsOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeCloseBracket", anyToken, Kind.CloseBracketToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracketsOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- Insert a space after { and before } in single-line contexts, but remove space from empty object literals {}.
        format.rule("SpaceAfterOpenBrace", Kind.OpenBraceToken, anyToken, {format.isOptionEnabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracesOption), format.isBraceWrappedContext}, ruleAction.InsertSpace),
        format.rule("SpaceBeforeCloseBrace", anyToken, Kind.CloseBraceToken, {format.isOptionEnabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracesOption), format.isBraceWrappedContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBetweenEmptyBraceBrackets", Kind.OpenBraceToken, Kind.CloseBraceToken, {format.isNonJsxSameLineTokenContext, format.isObjectContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterOpenBrace", Kind.OpenBraceToken, anyToken, {format.isOptionDisabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracesOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeCloseBrace", anyToken, Kind.CloseBraceToken, {format.isOptionDisabled(format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBracesOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- Insert a space after opening and before closing empty brace brackets
        format.rule("SpaceBetweenEmptyBraceBrackets", Kind.OpenBraceToken, Kind.CloseBraceToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingEmptyBracesOption)}, ruleAction.InsertSpace),
        format.rule("NoSpaceBetweenEmptyBraceBrackets", Kind.OpenBraceToken, Kind.CloseBraceToken, {format.isOptionDisabled(format.insertSpaceAfterOpeningAndBeforeClosingEmptyBracesOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- Insert space after opening and before closing template string braces
        format.rule("SpaceAfterTemplateHeadAndMiddle", {Kind.TemplateHead, Kind.TemplateMiddle}, anyToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBracesOption), format.isNonJsxTextContext}, ruleAction.InsertSpace, ruleFlags.CanDeleteNewLines),
        format.rule("SpaceBeforeTemplateMiddleAndTail", anyToken, {Kind.TemplateMiddle, Kind.TemplateTail}, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBracesOption), format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterTemplateHeadAndMiddle", {Kind.TemplateHead, Kind.TemplateMiddle}, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBracesOption), format.isNonJsxTextContext}, ruleAction.DeleteSpace, ruleFlags.CanDeleteNewLines),
        format.rule("NoSpaceBeforeTemplateMiddleAndTail", anyToken, {Kind.TemplateMiddle, Kind.TemplateTail}, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBracesOption), format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- No space after { and before } in JSX expression
        format.rule("SpaceAfterOpenBraceInJsxExpression", Kind.OpenBraceToken, anyToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBracesOption), format.isNonJsxSameLineTokenContext, format.isJsxExpressionContext}, ruleAction.InsertSpace),
        format.rule("SpaceBeforeCloseBraceInJsxExpression", anyToken, Kind.CloseBraceToken, {format.isOptionEnabled(format.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBracesOption), format.isNonJsxSameLineTokenContext, format.isJsxExpressionContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterOpenBraceInJsxExpression", Kind.OpenBraceToken, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBracesOption), format.isNonJsxSameLineTokenContext, format.isJsxExpressionContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceBeforeCloseBraceInJsxExpression", anyToken, Kind.CloseBraceToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBracesOption), format.isNonJsxSameLineTokenContext, format.isJsxExpressionContext}, ruleAction.DeleteSpace),

        -- Insert space after semicolon in for statement
        format.rule("SpaceAfterSemicolonInFor", Kind.SemicolonToken, anyToken, {format.isOptionEnabled(format.insertSpaceAfterSemicolonInForStatementsOption), format.isNonJsxSameLineTokenContext, format.isForContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterSemicolonInFor", Kind.SemicolonToken, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterSemicolonInForStatementsOption), format.isNonJsxSameLineTokenContext, format.isForContext}, ruleAction.DeleteSpace),

        -- Insert space before and after binary operators
        format.rule("SpaceBeforeBinaryOperator", anyToken, binaryOperators, {format.isOptionEnabled(format.insertSpaceBeforeAndAfterBinaryOperatorsOption), format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("SpaceAfterBinaryOperator", binaryOperators, anyToken, {format.isOptionEnabled(format.insertSpaceBeforeAndAfterBinaryOperatorsOption), format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBeforeBinaryOperator", anyToken, binaryOperators, {format.isOptionDisabledOrUndefined(format.insertSpaceBeforeAndAfterBinaryOperatorsOption), format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterBinaryOperator", binaryOperators, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceBeforeAndAfterBinaryOperatorsOption), format.isNonJsxSameLineTokenContext, format.isBinaryOpContext}, ruleAction.DeleteSpace),

        format.rule("SpaceBeforeOpenParenInFuncDecl", anyToken, Kind.OpenParenToken, {format.isOptionEnabled(format.insertSpaceBeforeFunctionParenthesisOption), format.isNonJsxSameLineTokenContext, format.isFunctionDeclContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBeforeOpenParenInFuncDecl", anyToken, Kind.OpenParenToken, {format.isOptionDisabledOrUndefined(format.insertSpaceBeforeFunctionParenthesisOption), format.isNonJsxSameLineTokenContext, format.isFunctionDeclContext}, ruleAction.DeleteSpace),

        -- Open Brace braces after control block
        format.rule("NewLineBeforeOpenBraceInControl", controlOpenBraceLeftTokenRange, Kind.OpenBraceToken, {format.isOptionEnabled(format.placeOpenBraceOnNewLineForControlBlocksOption), format.isControlDeclContext, format.isBeforeMultilineBlockContext}, ruleAction.InsertNewLine, ruleFlags.CanDeleteNewLines),

        -- Open Brace braces after function
        -- TypeScript: Function can have return types, which can be made of tons of different token kinds
        format.rule("NewLineBeforeOpenBraceInFunction", functionOpenBraceLeftTokenRange, Kind.OpenBraceToken, {format.isOptionEnabled(format.placeOpenBraceOnNewLineForFunctionsOption), format.isFunctionDeclContext, format.isBeforeMultilineBlockContext}, ruleAction.InsertNewLine, ruleFlags.CanDeleteNewLines),
        -- Open Brace braces after TypeScript module/class/interface
        format.rule("NewLineBeforeOpenBraceInTypeScriptDeclWithBlock", typeScriptOpenBraceLeftTokenRange, Kind.OpenBraceToken, {format.isOptionEnabled(format.placeOpenBraceOnNewLineForFunctionsOption), format.isTypeScriptDeclWithBlockContext, format.isBeforeMultilineBlockContext}, ruleAction.InsertNewLine, ruleFlags.CanDeleteNewLines),

        format.rule("SpaceAfterTypeAssertion", Kind.GreaterThanToken, anyToken, {format.isOptionEnabled(format.insertSpaceAfterTypeAssertionOption), format.isNonJsxSameLineTokenContext, format.isTypeAssertionContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceAfterTypeAssertion", Kind.GreaterThanToken, anyToken, {format.isOptionDisabledOrUndefined(format.insertSpaceAfterTypeAssertionOption), format.isNonJsxSameLineTokenContext, format.isTypeAssertionContext}, ruleAction.DeleteSpace),

        format.rule("SpaceBeforeTypeAnnotation", anyToken, {Kind.QuestionToken, Kind.ColonToken}, {format.isOptionEnabled(format.insertSpaceBeforeTypeAnnotationOption), format.isNonJsxSameLineTokenContext, format.isTypeAnnotationContext}, ruleAction.InsertSpace),
        format.rule("NoSpaceBeforeTypeAnnotation", anyToken, {Kind.QuestionToken, Kind.ColonToken}, {format.isOptionDisabledOrUndefined(format.insertSpaceBeforeTypeAnnotationOption), format.isNonJsxSameLineTokenContext, format.isTypeAnnotationContext}, ruleAction.DeleteSpace),

        format.rule("NoOptionalSemicolon", Kind.SemicolonToken, anyTokenIncludingEOF, {format.optionEquals(format.semicolonOption, lsutil.SemicolonPreference.Remove), format.isSemicolonDeletionContext}, ruleAction.DeleteToken),
        format.rule("OptionalSemicolon", anyToken, anyTokenIncludingEOF, {format.optionEquals(format.semicolonOption, lsutil.SemicolonPreference.Insert), format.isSemicolonInsertionContext}, ruleAction.InsertTrailingSemicolon),
    }

    -- These rules are lower in priority than user-configurable. Rules earlier in this list have priority over rules later in the list.
    local lowPriorityCommonRules = {
        -- Space after keyword but not before ; or : or ?
        format.rule("NoSpaceBeforeSemicolon", anyToken, Kind.SemicolonToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        format.rule("SpaceBeforeOpenBraceInControl", controlOpenBraceLeftTokenRange, Kind.OpenBraceToken, {format.isOptionDisabledOrUndefinedOrTokensOnSameLine(format.placeOpenBraceOnNewLineForControlBlocksOption), format.isControlDeclContext, format.isNotFormatOnEnter, format.isSameLineTokenOrBeforeBlockContext}, ruleAction.InsertSpace, ruleFlags.CanDeleteNewLines),
        format.rule("SpaceBeforeOpenBraceInFunction", functionOpenBraceLeftTokenRange, Kind.OpenBraceToken, {format.isOptionDisabledOrUndefinedOrTokensOnSameLine(format.placeOpenBraceOnNewLineForFunctionsOption), format.isFunctionDeclContext, format.isBeforeBlockContext, format.isNotFormatOnEnter, format.isSameLineTokenOrBeforeBlockContext}, ruleAction.InsertSpace, ruleFlags.CanDeleteNewLines),
        format.rule("SpaceBeforeOpenBraceInTypeScriptDeclWithBlock", typeScriptOpenBraceLeftTokenRange, Kind.OpenBraceToken, {format.isOptionDisabledOrUndefinedOrTokensOnSameLine(format.placeOpenBraceOnNewLineForFunctionsOption), format.isTypeScriptDeclWithBlockContext, format.isNotFormatOnEnter, format.isSameLineTokenOrBeforeBlockContext}, ruleAction.InsertSpace, ruleFlags.CanDeleteNewLines),

        format.rule("NoSpaceBeforeComma", anyToken, Kind.CommaToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- No space before and after indexer `x{}`
        format.rule("NoSpaceBeforeOpenBracket", anyTokenExcept(Kind.AsyncKeyword, Kind.CaseKeyword), Kind.OpenBracketToken, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),
        format.rule("NoSpaceAfterCloseBracket", Kind.CloseBracketToken, anyToken, {format.isNonJsxSameLineTokenContext, format.isNotBeforeBlockInFunctionDeclarationContext}, ruleAction.DeleteSpace),
        format.rule("SpaceAfterSemicolon", Kind.SemicolonToken, anyToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),

        -- Remove extra space between for and await
        format.rule("SpaceBetweenForAndAwaitKeyword", Kind.ForKeyword, Kind.AwaitKeyword, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),

        -- Remove extra spaces between ... and type name in tuple spread
        format.rule("SpaceBetweenDotDotDotAndTypeName", Kind.DotDotDotToken, typeNames, {format.isNonJsxSameLineTokenContext}, ruleAction.DeleteSpace),

        -- Add a space between statements. All keywords except (do,else,case) has open/close parens after them.
        -- So, we have a rule to add a space for {),Any}, {do,Any}, {else,Any}, and {case,Any}
        format.rule(
            "SpaceBetweenStatements",
            {Kind.CloseParenToken, Kind.DoKeyword, Kind.ElseKeyword, Kind.CaseKeyword},
            anyToken,
            {format.isNonJsxSameLineTokenContext, format.isNonJsxElementOrFragmentContext, format.isNotForContext},
            ruleAction.InsertSpace
        ),
        -- This low-pri rule takes care of "try {", "catch {" and "finally {" in case the rule SpaceBeforeOpenBraceInControl didn't execute on FormatOnEnter.
        format.rule("SpaceAfterTryCatchFinally", {Kind.TryKeyword, Kind.CatchKeyword, Kind.FinallyKeyword}, Kind.OpenBraceToken, {format.isNonJsxSameLineTokenContext}, ruleAction.InsertSpace),
    }

    local result = {}
    core.AppendAll(result, highPriorityCommonRules)
    core.AppendAll(result, userConfigurableRules)
    core.AppendAll(result, lowPriorityCommonRules)
    return result
end

function format.tokenRangeFrom(...)
    return {
        isSpecific = true,
        tokens = { ... },
    }
end

function format.tokenRangeFromEx(prefix, ...)
    local tokens = core.Concatenate(prefix, { ... })
    return {
        isSpecific = true,
        tokens = tokens,
    }
end

function format.tokenRangeFromRange(start, end_)
    local tokens = {}
    for token = start, end_ do
        tokens[#tokens + 1] = token
    end

    return format.tokenRangeFrom(table.unpack(tokens))
end
