local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local EF = printer.EmitFlags

function transformers.IsGeneratedIdentifier(emitContext, name)
    return emitContext:HasAutoGenerateInfo(name)
end

function transformers.IsHelperName(emitContext, name)
    return emitContext:EmitFlags(name) & EF.EFHelperName ~= 0
end

function transformers.IsLocalName(emitContext, name)
    return emitContext:EmitFlags(name) & EF.EFLocalName ~= 0
end

function transformers.IsExportName(emitContext, name)
    return emitContext:EmitFlags(name) & EF.EFExportName ~= 0
end

local identifierReferenceAnyChildKinds = ast.kindSet(
    Kind.BinaryExpression,
    Kind.PrefixUnaryExpression,
    Kind.PostfixUnaryExpression,
    Kind.YieldExpression,
    Kind.AsExpression,
    Kind.SatisfiesExpression,
    Kind.ElementAccessExpression,
    Kind.NonNullExpression,
    Kind.SpreadElement,
    Kind.SpreadAssignment,
    Kind.ParenthesizedExpression,
    Kind.ArrayLiteralExpression,
    Kind.DeleteExpression,
    Kind.TypeOfExpression,
    Kind.VoidExpression,
    Kind.AwaitExpression,
    Kind.TypeAssertionExpression,
    Kind.ExpressionWithTypeArguments,
    Kind.JsxSelfClosingElement,
    Kind.JsxSpreadAttribute,
    Kind.JsxExpression,
    Kind.PartiallyEmittedExpression
)

local identifierReferenceExpressionKinds = ast.kindSet(
    Kind.ComputedPropertyName,
    Kind.Decorator,
    Kind.IfStatement,
    Kind.DoStatement,
    Kind.WhileStatement,
    Kind.WithStatement,
    Kind.ReturnStatement,
    Kind.SwitchStatement,
    Kind.CaseClause,
    Kind.ThrowStatement,
    Kind.ExpressionStatement,
    Kind.ExportAssignment,
    Kind.PropertyAccessExpression,
    Kind.TemplateSpan
)

local identifierReferenceInitializerKinds = ast.kindSet(
    Kind.VariableDeclaration,
    Kind.Parameter,
    Kind.BindingElement,
    Kind.PropertyDeclaration,
    Kind.PropertySignature,
    Kind.PropertyAssignment,
    Kind.EnumMember,
    Kind.JsxAttribute
)

local function containsNode(nodes, node)
    for _, n in ipairs(nodes or {}) do
        if n == node then
            return true
        end
    end
    return false
end

function transformers.IsIdentifierReference(name, parent)
    local kind = parent.kind
    if identifierReferenceAnyChildKinds[kind] then
        -- all immediate children that can be `Identifier` would be instances of `IdentifierReference`
        return true
    elseif identifierReferenceExpressionKinds[kind] then
        -- only an `Expression()` child that can be `Identifier` would be an instance of `IdentifierReference`
        return parent:Expression() == name
    elseif identifierReferenceInitializerKinds[kind] then
        -- only an `Initializer()` child that can be `Identifier` would be an instance of `IdentifierReference`
        return parent:Initializer() == name
    elseif kind == Kind.ShorthandPropertyAssignment then
        return parent:AsShorthandPropertyAssignment().objectAssignmentInitializer == name
    elseif kind == Kind.ForStatement then
        return parent:Initializer() == name or
            parent:AsForStatement().condition == name or
            parent:AsForStatement().incrementor == name
    elseif kind == Kind.ForInStatement or kind == Kind.ForOfStatement then
        return parent:Initializer() == name or
            parent:Expression() == name
    elseif kind == Kind.ImportEqualsDeclaration then
        return parent:AsImportEqualsDeclaration().moduleReference == name
    elseif kind == Kind.ArrowFunction then
        return parent:Body() == name
    elseif kind == Kind.ConditionalExpression then
        return parent:AsConditionalExpression().condition == name or
            parent:AsConditionalExpression().whenTrue == name or
            parent:AsConditionalExpression().whenFalse == name
    elseif kind == Kind.CallExpression or kind == Kind.NewExpression then
        return parent:Expression() == name or
            containsNode(parent:Arguments(), name)
    elseif kind == Kind.TaggedTemplateExpression then
        return parent:AsTaggedTemplateExpression().tag == name
    elseif kind == Kind.ImportAttribute then
        return parent:AsImportAttribute().value == name
    elseif kind == Kind.JsxOpeningElement or kind == Kind.JsxClosingElement then
        return parent:TagName() == name
    else
        return false
    end
end

function transformers.convertBindingElementToArrayAssignmentElement(emitContext, element)
    if element:Name() == nil then
        local elision = emitContext.factory:NewOmittedExpression()
        emitContext:SetOriginal(elision, element:AsNode())
        emitContext:AssignCommentAndSourceMapRanges(elision, element:AsNode())
        return elision
    end
    if element.dotDotDotToken ~= nil then
        local spread = emitContext.factory:NewSpreadElement(element:Name())
        emitContext:SetOriginal(spread, element:AsNode())
        emitContext:AssignCommentAndSourceMapRanges(spread, element:AsNode())
        return spread
    end
    local expression = transformers.convertBindingNameToAssignmentElementTarget(emitContext, element:Name())
    if element.initializer ~= nil then
        local assignment = emitContext.factory:NewAssignmentExpression(expression, element.initializer)
        emitContext:SetOriginal(assignment, element:AsNode())
        emitContext:AssignCommentAndSourceMapRanges(assignment, element:AsNode())
        return assignment
    end
    return expression
end

function transformers.convertBindingElementToObjectAssignmentElement(emitContext, element)
    if element.dotDotDotToken ~= nil then
        local spread = emitContext.factory:NewSpreadAssignment(element:Name())
        emitContext:SetOriginal(spread, element:AsNode())
        emitContext:AssignCommentAndSourceMapRanges(spread, element:AsNode())
        return spread
    end
    if element.propertyName ~= nil then
        local expression = transformers.convertBindingNameToAssignmentElementTarget(emitContext, element:Name())
        if element.initializer ~= nil then
            expression = emitContext.factory:NewAssignmentExpression(expression, element.initializer)
        end
        local assignment = emitContext.factory:NewPropertyAssignment(nil --[[modifiers]], element.propertyName, nil --[[postfixToken]], nil --[[typeNode]], expression)
        emitContext:SetOriginal(assignment, element:AsNode())
        emitContext:AssignCommentAndSourceMapRanges(assignment, element:AsNode())
        return assignment
    end
    local equalsToken
    if element.initializer ~= nil then
        equalsToken = emitContext.factory:NewToken(Kind.EqualsToken)
    end
    local assignment = emitContext.factory:NewShorthandPropertyAssignment(
        nil, --[[modifiers]]
        element:Name(),
        nil, --[[postfixToken]]
        nil, --[[typeNode]]
        equalsToken,
        element.initializer
    )
    emitContext:SetOriginal(assignment, element:AsNode())
    emitContext:AssignCommentAndSourceMapRanges(assignment, element:AsNode())
    return assignment
end

function transformers.ConvertBindingPatternToAssignmentPattern(emitContext, element)
    if element.kind == Kind.ArrayBindingPattern then
        return transformers.convertBindingElementToArrayAssignmentPattern(emitContext, element)
    elseif element.kind == Kind.ObjectBindingPattern then
        return transformers.convertBindingElementToObjectAssignmentPattern(emitContext, element)
    else
        error("Unknown binding pattern", 0)
    end
end

function transformers.convertBindingElementToObjectAssignmentPattern(emitContext, element)
    local properties
    for _, e in ipairs(element.elements.nodes or {}) do
        properties = properties or {}
        properties[#properties + 1] = transformers.convertBindingElementToObjectAssignmentElement(emitContext, e:AsBindingElement())
    end
    local propertyList = emitContext.factory:NewNodeList(properties)
    propertyList.loc = element.elements.loc
    local object = emitContext.factory:NewObjectLiteralExpression(propertyList, false --[[multiLine]])
    emitContext:SetOriginal(object, element:AsNode())
    emitContext:AssignCommentAndSourceMapRanges(object, element:AsNode())
    return object
end

function transformers.convertBindingElementToArrayAssignmentPattern(emitContext, element)
    local elements
    for _, e in ipairs(element.elements.nodes or {}) do
        elements = elements or {}
        elements[#elements + 1] = transformers.convertBindingElementToArrayAssignmentElement(emitContext, e:AsBindingElement())
    end
    local elementList = emitContext.factory:NewNodeList(elements)
    elementList.loc = element.elements.loc
    local object = emitContext.factory:NewArrayLiteralExpression(elementList, false --[[multiLine]])
    emitContext:SetOriginal(object, element:AsNode())
    emitContext:AssignCommentAndSourceMapRanges(object, element:AsNode())
    return object
end

function transformers.convertBindingNameToAssignmentElementTarget(emitContext, element)
    if ast.IsBindingPattern(element) then
        return transformers.ConvertBindingPatternToAssignmentPattern(emitContext, element:AsBindingPattern())
    end
    return element
end

function transformers.ConvertVariableDeclarationToAssignmentExpression(emitContext, element)
    if element.initializer == nil then
        return nil
    end
    local expression = transformers.convertBindingNameToAssignmentElementTarget(emitContext, element:Name())
    local assignment = emitContext.factory:NewAssignmentExpression(expression, element.initializer)
    emitContext:SetOriginal(assignment, element:AsNode())
    emitContext:AssignCommentAndSourceMapRanges(assignment, element:AsNode())
    return assignment
end

function transformers.SingleOrMany(nodes, factory)
    if nodes == nil then
        return nil
    end
    if #nodes == 1 then
        return nodes[1]
    end
    return factory:NewSyntaxList(nodes)
end

-- Used in the module transformer to check if an expression is reasonably without sideeffect,
--
--	and thus better to copy into multiple places rather than to cache in a temporary variable
--	- this is mostly subjective beyond the requirement that the expression not be sideeffecting
--
-- Also used by the logical assignment downleveling transform to skip temp variables when they're
-- not needed.
function transformers.IsSimpleCopiableExpression(expression)
    return ast.IsStringLiteralLike(expression) or
        ast.IsNumericLiteral(expression) or
        ast.IsKeywordKind(expression.kind) or
        ast.IsIdentifier(expression)
end

function transformers.IsOriginalNodeSingleLine(emitContext, node)
    if node == nil then
        return false
    end
    local original = emitContext:MostOriginal(node)
    if original == nil then
        return false
    end
    local source = ast.GetSourceFileOfNode(original)
    if source == nil then
        return false
    end
    local startLine = scanner.GetECMALineOfPosition(source, original.loc:Pos())
    local endLine = scanner.GetECMALineOfPosition(source, original.loc:End())
    return startLine == endLine
end

--[[*
 * A simple inlinable expression is an expression which can be copied into multiple locations
 * without risk of repeating any sideeffects and whose value could not possibly change between
 * any such locations
 ]]
function transformers.IsSimpleInlineableExpression(expression)
    return not ast.IsIdentifier(expression) and transformers.IsSimpleCopiableExpression(expression)
end

-- FindSuperStatementIndexPath finds a path of indices to a statement containing a `super()` call.
-- Indices are 0-based like Go.
function transformers.FindSuperStatementIndexPath(statements, start)
    local indices = transformers.findSuperStatementIndexPathWorker(statements, start, nil)
    if indices ~= nil then
        local n = #indices
        for i = 1, n // 2 do
            indices[i], indices[n - i + 1] = indices[n - i + 1], indices[i]
        end
    end
    return indices
end

function transformers.findSuperStatementIndexPathWorker(statements, start, indices)
    local n = core.Len(statements)
    for i = start, n - 1 do
        local statement = statements[i + 1]
        if transformers.GetSuperCallFromStatement(statement) ~= nil then
            return core.Append(indices, i)
        elseif ast.IsTryStatement(statement) then
            local result = transformers.findSuperStatementIndexPathWorker(statement:AsTryStatement().tryBlock:Statements(), 0, indices)
            if result ~= nil then
                return core.Append(result, i)
            end
        end
    end
    return nil
end

-- GetSuperCallFromStatement extracts the super() call expression from an expression statement, if any.
function transformers.GetSuperCallFromStatement(statement)
    if not ast.IsExpressionStatement(statement) then
        return nil
    end
    local expression = ast.SkipParentheses(statement:Expression())
    if ast.IsSuperCall(expression) then
        return expression
    end
    return nil
end

-- MoveRangePastModifiers returns a text range that starts past any modifiers on the node.
function transformers.MoveRangePastModifiers(node)
    if ast.IsPropertyDeclaration(node) or ast.IsMethodDeclaration(node) then
        return core.NewTextRange(node:Name():Pos(), node:End())
    end

    local lastModifier
    if ast.CanHaveModifiers(node) then
        lastModifier = core.LastOrNil(node:ModifierNodes())
    end

    if lastModifier ~= nil and not ast.PositionIsSynthesized(lastModifier:End()) then
        return core.NewTextRange(lastModifier:End(), node:End())
    end
    return transformers.MoveRangePastDecorators(node)
end

-- MoveRangePastDecorators returns a text range that starts past any decorators on the node.
function transformers.MoveRangePastDecorators(node)
    local lastDecorator
    if ast.CanHaveModifiers(node) then
        local nodes = node:ModifierNodes()
        if nodes ~= nil then
            lastDecorator = core.FindLast(nodes, ast.IsDecorator)
        end
    end

    if lastDecorator ~= nil and not ast.PositionIsSynthesized(lastDecorator:End()) then
        return core.NewTextRange(lastDecorator:End(), node:End())
    end
    return node.loc
end

local nonAssignmentOperatorForCompoundAssignment = {
    [Kind.PlusEqualsToken] = Kind.PlusToken,
    [Kind.MinusEqualsToken] = Kind.MinusToken,
    [Kind.AsteriskEqualsToken] = Kind.AsteriskToken,
    [Kind.AsteriskAsteriskEqualsToken] = Kind.AsteriskAsteriskToken,
    [Kind.SlashEqualsToken] = Kind.SlashToken,
    [Kind.PercentEqualsToken] = Kind.PercentToken,
    [Kind.LessThanLessThanEqualsToken] = Kind.LessThanLessThanToken,
    [Kind.GreaterThanGreaterThanEqualsToken] = Kind.GreaterThanGreaterThanToken,
    [Kind.GreaterThanGreaterThanGreaterThanEqualsToken] = Kind.GreaterThanGreaterThanGreaterThanToken,
    [Kind.AmpersandEqualsToken] = Kind.AmpersandToken,
    [Kind.BarEqualsToken] = Kind.BarToken,
    [Kind.CaretEqualsToken] = Kind.CaretToken,
    [Kind.BarBarEqualsToken] = Kind.BarBarToken,
    [Kind.AmpersandAmpersandEqualsToken] = Kind.AmpersandAmpersandToken,
    [Kind.QuestionQuestionEqualsToken] = Kind.QuestionQuestionToken,
}

-- GetNonAssignmentOperatorForCompoundAssignment returns the non-assignment operator for a compound assignment.
function transformers.GetNonAssignmentOperatorForCompoundAssignment(kind)
    local result = nonAssignmentOperatorForCompoundAssignment[kind]
    if result ~= nil then
        return result
    end
    return kind
end
