-- Port of the internal/printer/printer_test.go tests not covered by spec/printer_spec.lua:
-- TestParenthesizeBinary, TestPartiallyEmittedExpression,
-- TestParenthesizeBinaryExpressionMixingNullishCoalescing and the full TestOmitTrailingSemicolon
-- (spec/printer_spec.lua only checks its last assertion).
local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")
local printer = require("tslua.printer")
local tstransforms = require("tslua.transformers.tstransforms")

local Kind = ast.Kind

-- parsetestutil.ParseTypeScript
local function parseTypeScript(text, jsx)
    local fileName = jsx and "/main.tsx" or "/main.ts"
    return parser.ParseSourceFile({ fileName = fileName, path = fileName, externalModuleIndicatorOptions = { jsx = false, force = false } }, text, core.GetScriptKindFromFileName(fileName))
end

-- parsetestutil.MarkSyntheticRecursive
local function markSyntheticRecursive(node)
    local v
    v = ast.NewNodeVisitor(function(n)
        return v:VisitEachChild(n)
    end, ast.NewNodeFactory({}), {
        visitNode = function(n, vv)
            if n ~= nil then
                n.loc = core.UndefinedTextRange()
            end
            return vv:VisitNode(n)
        end,
        visitToken = function(n, vv)
            if n ~= nil then
                n.loc = core.UndefinedTextRange()
            end
            return vv:VisitNode(n)
        end,
        visitNodes = function(nodes, vv)
            if nodes ~= nil then
                nodes.loc = core.UndefinedTextRange()
            end
            return vv:VisitNodes(nodes)
        end,
        visitModifiers = function(nodes, vv)
            if nodes ~= nil then
                nodes.loc = core.UndefinedTextRange()
            end
            return vv:VisitModifiers(nodes)
        end,
    })
    v:VisitNode(node)
end

local function trimSuffixNewLine(text)
    if text:sub(-1) == "\n" then
        return text:sub(1, -2)
    end
    return text
end

-- emittestutil.CheckEmit
local function checkEmit(emitContext, file, expected)
    local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, emitContext)
    local text = p:EmitSourceFile(file)
    local actual = trimSuffixNewLine(text)
    assert.are.equal(expected, actual)
    local file2 = parseTypeScript(text, file.languageVariant == core.LanguageVariant.JSX)
    assert.are.equal(0, #file2:Diagnostics(), "error on reparse")
end

local function newFile(factory, statements)
    return factory:NewSourceFile({ fileName = "/file.ts", path = "/file.ts", externalModuleIndicatorOptions = { jsx = false, force = false } }, "", factory:NewNodeList(statements), factory:NewToken(Kind.EndOfFile))
end

local binaryOperators = ast.kindSet(
    Kind.CommaToken,
    Kind.LessThanToken,
    Kind.GreaterThanToken,
    Kind.LessThanEqualsToken,
    Kind.GreaterThanEqualsToken,
    Kind.EqualsEqualsToken,
    Kind.EqualsEqualsEqualsToken,
    Kind.ExclamationEqualsToken,
    Kind.ExclamationEqualsEqualsToken,
    Kind.PlusToken,
    Kind.MinusToken,
    Kind.AsteriskToken,
    Kind.AsteriskAsteriskToken,
    Kind.SlashToken,
    Kind.PercentToken,
    Kind.LessThanLessThanToken,
    Kind.GreaterThanGreaterThanToken,
    Kind.GreaterThanGreaterThanGreaterThanToken,
    Kind.AmpersandToken,
    Kind.BarToken,
    Kind.CaretToken,
    Kind.AmpersandAmpersandToken,
    Kind.BarBarToken,
    Kind.QuestionQuestionToken,
    Kind.EqualsToken,
    Kind.PlusEqualsToken,
    Kind.MinusEqualsToken,
    Kind.AsteriskEqualsToken,
    Kind.AsteriskAsteriskEqualsToken,
    Kind.SlashEqualsToken,
    Kind.PercentEqualsToken,
    Kind.LessThanLessThanEqualsToken,
    Kind.GreaterThanGreaterThanEqualsToken,
    Kind.GreaterThanGreaterThanGreaterThanEqualsToken,
    Kind.AmpersandEqualsToken,
    Kind.BarEqualsToken,
    Kind.BarBarEqualsToken,
    Kind.AmpersandAmpersandEqualsToken,
    Kind.QuestionQuestionEqualsToken,
    Kind.CaretEqualsToken,
    Kind.InKeyword,
    Kind.InstanceOfKeyword
)

local function isBinaryOperator(token)
    return binaryOperators[token] == true
end

local function makeSide(label, kind, factory)
    if kind == Kind.Identifier or kind == Kind.Unknown then
        return factory:NewIdentifier(label)
    elseif kind == Kind.ArrowFunction then
        return factory:NewArrowFunction(
            nil, --[[modifiers]]
            nil, --[[typeParameters]]
            factory:NewNodeList({}),
            nil, --[[returnType]]
            nil, --[[fullSignature]]
            factory:NewToken(Kind.EqualsGreaterThanToken),
            factory:NewBlock(factory:NewNodeList({}), false --[[multiLine]])
        )
    elseif isBinaryOperator(kind) then
        return factory:NewBinaryExpression(
            nil, --[[modifiers]]
            factory:NewIdentifier(label .. "l"),
            nil, --[[typeNode]]
            factory:NewToken(kind),
            factory:NewIdentifier(label .. "r")
        )
    else
        error("unsupported kind", 0)
    end
end

describe("TestParenthesizeBinary", function()
    local data = {
        { operator = Kind.CommaToken, output = "l, r" },
        { operator = Kind.CommaToken, left = Kind.PlusToken, output = "ll + lr, r" },
        { operator = Kind.AsteriskToken, left = Kind.PlusToken, output = "(ll + lr) * r" },
        { operator = Kind.AsteriskToken, right = Kind.PlusToken, output = "l * (rl + rr)" },
        { operator = Kind.PlusToken, left = Kind.AsteriskToken, output = "ll * lr + r" },
        { operator = Kind.PlusToken, right = Kind.AsteriskToken, output = "l + rl * rr" },
        { operator = Kind.SlashToken, left = Kind.AsteriskToken, output = "ll * lr / r" },
        { operator = Kind.SlashToken, left = Kind.AsteriskAsteriskToken, output = "ll ** lr / r" },
        { operator = Kind.AsteriskAsteriskToken, left = Kind.AsteriskToken, output = "(ll * lr) ** r" },
        { operator = Kind.AsteriskAsteriskToken, left = Kind.AsteriskAsteriskToken, output = "(ll ** lr) ** r" },
        { operator = Kind.AsteriskToken, right = Kind.AsteriskToken, output = "l * rl * rr" },
        { operator = Kind.BarToken, right = Kind.BarToken, output = "l | rl | rr" },
        { operator = Kind.AmpersandToken, right = Kind.AmpersandToken, output = "l & rl & rr" },
        { operator = Kind.CaretToken, right = Kind.CaretToken, output = "l ^ rl ^ rr" },
        { operator = Kind.AmpersandAmpersandToken, right = Kind.ArrowFunction, output = "l && (() => { })" },
    }
    for _, rec in ipairs(data) do
        it(rec.output, function()
            local factory = ast.NewNodeFactory({})
            local file = newFile(factory, {
                factory:NewExpressionStatement(
                    factory:NewBinaryExpression(
                        nil, --[[modifiers]]
                        makeSide("l", rec.left or Kind.Unknown, factory),
                        nil, --[[typeNode]]
                        factory:NewToken(rec.operator),
                        makeSide("r", rec.right or Kind.Unknown, factory)
                    )
                ),
            })

            markSyntheticRecursive(file)
            checkEmit(nil, file, rec.output .. ";")
        end)
    end
end)

describe("TestPartiallyEmittedExpression", function()
    it("TestPartiallyEmittedExpression", function()
        local compilerOptions = core.NewCompilerOptions({})

        local file = parseTypeScript([[return ((container.parent
    .left as PropertyAccessExpression)
    .expression as PropertyAccessExpression)
    .expression;]], false --[[jsx]])

        local emitContext = printer.NewEmitContext()
        file = tstransforms.NewTypeEraserTransformer({ compilerOptions = compilerOptions, context = emitContext }):TransformSourceFile(file)
        checkEmit(emitContext, file, [[return container.parent
    .left
    .expression
    .expression;]])
    end)
end)

describe("TestParenthesizeBinaryExpressionMixingNullishCoalescing", function()
    local tests = {
        -- inner ?? on left side of || or &&
        { title = "BarBarWithLeftQuestionQuestion", innerOp = Kind.QuestionQuestionToken, outerOp = Kind.BarBarToken, side = "left", output = "(a ?? b) || c;" },
        { title = "AmpersandAmpersandWithLeftQuestionQuestion", innerOp = Kind.QuestionQuestionToken, outerOp = Kind.AmpersandAmpersandToken, side = "left", output = "(a ?? b) && c;" },
        -- inner ?? on right side of || or &&
        { title = "BarBarWithRightQuestionQuestion", innerOp = Kind.QuestionQuestionToken, outerOp = Kind.BarBarToken, side = "right", output = "a || (b ?? c);" },
        { title = "AmpersandAmpersandWithRightQuestionQuestion", innerOp = Kind.QuestionQuestionToken, outerOp = Kind.AmpersandAmpersandToken, side = "right", output = "a && (b ?? c);" },
        -- inner || or && on left side of ??
        { title = "QuestionQuestionWithLeftBarBar", innerOp = Kind.BarBarToken, outerOp = Kind.QuestionQuestionToken, side = "left", output = "(a || b) ?? c;" },
        { title = "QuestionQuestionWithLeftAmpersandAmpersand", innerOp = Kind.AmpersandAmpersandToken, outerOp = Kind.QuestionQuestionToken, side = "left", output = "(a && b) ?? c;" },
        -- inner || or && on right side of ??
        { title = "QuestionQuestionWithRightBarBar", innerOp = Kind.BarBarToken, outerOp = Kind.QuestionQuestionToken, side = "right", output = "a ?? (b || c);" },
        { title = "QuestionQuestionWithRightAmpersandAmpersand", innerOp = Kind.AmpersandAmpersandToken, outerOp = Kind.QuestionQuestionToken, side = "right", output = "a ?? (b && c);" },
    }

    for _, tt in ipairs(tests) do
        it(tt.title, function()
            local factory = ast.NewNodeFactory({})
            local innerExpr = factory:NewBinaryExpression(
                nil, --[[modifiers]]
                factory:NewIdentifier("a"),
                nil, --[[typeNode]]
                factory:NewToken(tt.innerOp),
                factory:NewIdentifier("b")
            )
            local outerExpr
            if tt.side == "left" then
                outerExpr = factory:NewBinaryExpression(
                    nil, --[[modifiers]]
                    innerExpr, --[[left: (a innerOp b)]]
                    nil, --[[typeNode]]
                    factory:NewToken(tt.outerOp),
                    factory:NewIdentifier("c")
                )
            else
                outerExpr = factory:NewBinaryExpression(
                    nil, --[[modifiers]]
                    factory:NewIdentifier("a"),
                    nil, --[[typeNode]]
                    factory:NewToken(tt.outerOp),
                    innerExpr --[[right: (b innerOp c)]]
                )
                -- adjust identifiers for right side
                innerExpr:AsBinaryExpression().left = factory:NewIdentifier("b")
                innerExpr:AsBinaryExpression().right = factory:NewIdentifier("c")
            end
            local file = newFile(factory, {
                factory:NewExpressionStatement(outerExpr),
            })

            markSyntheticRecursive(file)
            checkEmit(nil, file, tt.output)
        end)
    end
end)

describe("TestOmitTrailingSemicolon", function()
    it("TestOmitTrailingSemicolon", function()
        local factory = ast.NewNodeFactory({})
        local methodSignature = factory:NewMethodSignatureDeclaration(
            nil, --[[modifiers]]
            factory:NewIdentifier("m"),
            nil, --[[postfixToken]]
            nil, --[[typeParameters]]
            factory:NewNodeList(nil),
            factory:NewKeywordTypeNode(Kind.VoidKeyword)
        )
        local file = parseTypeScript("interface I {}", false)

        local defaultPrinter = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, nil)
        assert.are.equal("m(): void;", defaultPrinter:Emit(methodSignature, file), "default Emit()")

        local omitPrinter = printer.NewPrinter({ newLine = core.NewLineKind.LF, omitTrailingSemicolon = true }, {}, nil)
        assert.are.equal("m(): void", omitPrinter:Emit(methodSignature, file), "omit Emit()")

        local forFile = parseTypeScript("for (;;) {}", false)
        local got = trimSuffixNewLine(omitPrinter:EmitSourceFile(forFile))
        assert.are.equal("for (;;) { }", got, "omit EmitSourceFile(for)")
    end)
end)
