local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local scanner = require("tslua.scanner")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SubtreeFacts = ast.SubtreeFacts
local TokenFlags = ast.TokenFlags

-- Go: strings.NewReplacer("\r\n", "\n", "\r", "\n")
estransforms.newlineNormalizer = {
    Replace = function(_, s)
        return (string.gsub(string.gsub(s, "\r\n", "\n"), "\r", "\n"))
    end,
}

-- Fields: currentSourceFile, taggedTemplateStringDeclarations
local taggedTemplateTransformer = transformers.NewTransformerType()
estransforms.taggedTemplateTransformer = taggedTemplateTransformer

function estransforms.newTaggedTemplateLiftRestrictionTransformer(opts)
    local tx = setmetatable({}, taggedTemplateTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end

function taggedTemplateTransformer:visit(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsInvalidTemplateEscape == 0 then
        return node
    end
    local k = node.kind
    if k == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.TaggedTemplateExpression then
        return self:visitTaggedTemplateExpression(node:AsTaggedTemplateExpression())
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function taggedTemplateTransformer:visitSourceFile(node)
    self.currentSourceFile = node
    self.taggedTemplateStringDeclarations = nil
    local visited = self:Visitor():VisitEachChild(node:AsNode())

    if #(self.taggedTemplateStringDeclarations or {}) > 0 then
        local visitedSourceFile = visited:AsSourceFile()
        local statements = {}
        for i, s in ipairs(visitedSourceFile.statements.nodes) do
            statements[i] = s
        end
        statements[#statements + 1] = self:Factory():NewVariableStatement(
            nil, --[[modifiers]]
            self:Factory():NewVariableDeclarationList(
                self:Factory():NewNodeList(self.taggedTemplateStringDeclarations),
                NodeFlags.None
            )
        )
        local stmtList = self:Factory():NewNodeList(statements)
        stmtList.loc = node.statements.loc
        visited = self:Factory():UpdateSourceFile(visitedSourceFile, stmtList, visitedSourceFile.endOfFileToken)
    end

    self:EmitContext():AddEmitHelper(visited, table.unpack(self:EmitContext():ReadEmitHelpers()))
    return visited
end

function taggedTemplateTransformer:visitTaggedTemplateExpression(node)
    return self:processTaggedTemplateExpression(node)
end

function taggedTemplateTransformer:processTaggedTemplateExpression(node)
    local tag = self:Visitor():VisitNode(node.tag)
    local template = node.template

    if not estransforms.hasInvalidEscape(template) then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local f = self:Factory()

    -- Build up the template arguments and the raw and cooked strings for the template.
    local templateArguments = { false } -- placeholder for the template object
    local cookedStrings = {}
    local rawStrings = {}

    if ast.IsNoSubstitutionTemplateLiteral(template) then
        cookedStrings[#cookedStrings + 1] = estransforms.createTemplateCooked(f, template:TemplateLiteralLikeData())
        rawStrings[#rawStrings + 1] = estransforms.getRawLiteral(f, template)
    else
        local te = template:AsTemplateExpression()
        cookedStrings[#cookedStrings + 1] = estransforms.createTemplateCooked(f, te.head:TemplateLiteralLikeData())
        rawStrings[#rawStrings + 1] = estransforms.getRawLiteral(f, te.head)
        for _, span in ipairs(te.templateSpans.nodes) do
            local ts = span:AsTemplateSpan()
            cookedStrings[#cookedStrings + 1] = estransforms.createTemplateCooked(f, ts.literal:TemplateLiteralLikeData())
            rawStrings[#rawStrings + 1] = estransforms.getRawLiteral(f, ts.literal)
            templateArguments[#templateArguments + 1] = self:Visitor():VisitNode(ts.expression)
        end
    end

    local helperCall = f:NewTemplateObjectHelper(
        f:NewArrayLiteralExpression(f:NewNodeList(cookedStrings), false),
        f:NewArrayLiteralExpression(f:NewNodeList(rawStrings), false)
    )

    -- Create a variable to cache the template object if we're in a module.
    -- Do not do this in the global scope, as any variable we currently generate could conflict with
    -- variables from outside of the current compilation. In the future, we can revisit this behavior.
    if ast.IsExternalModule(self.currentSourceFile) then
        local tempVar = f:NewUniqueName("templateObject")
        self.taggedTemplateStringDeclarations = self.taggedTemplateStringDeclarations or {}
        self.taggedTemplateStringDeclarations[#self.taggedTemplateStringDeclarations + 1] =
            f:NewVariableDeclaration(tempVar, nil, nil, nil)
        templateArguments[1] = f:NewLogicalORExpression(
            tempVar,
            f:NewAssignmentExpression(tempVar, helperCall)
        )
    else
        templateArguments[1] = helperCall
    end

    local call = f:NewCallExpression(tag, nil --[[questionDotToken]], nil --[[typeArguments]], f:NewNodeList(templateArguments), NodeFlags.None)
    call.loc = node.loc
    return call
end

function estransforms.createTemplateCooked(f, template)
    if template.templateFlags & TokenFlags.IsInvalid ~= 0 then
        return f:NewVoidZeroExpression()
    end
    return f:NewStringLiteral(template.text, TokenFlags.None)
end

function estransforms.getRawLiteral(f, node)
    local text = node:TemplateLiteralLikeData().rawText
    if text == "" then
        text = scanner.GetSourceTextOfNodeFromSourceFile(ast.GetSourceFileOfNode(node), node, false --[[includeTrivia]])
        -- text contains the original source, it will also contain quotes ("`"), dollar signs and braces ("${" and "}"),
        -- thus we need to remove those characters.
        -- First template piece starts with "`", others with "}"
        -- Last template piece ends with "`", others with "${"
        local isLast = node.kind == Kind.NoSubstitutionTemplateLiteral or node.kind == Kind.TemplateTail
        local endLen = 2
        if isLast then
            endLen = 1
        end
        text = string.sub(text, 2, #text - endLen)
    end

    -- Newline normalization:
    -- ES6 Spec 11.8.6.1 - Static Semantics of TV's and TRV's
    -- <CR><LF> and <CR> LineTerminatorSequences are normalized to <LF> for both TV and TRV.
    text = estransforms.newlineNormalizer:Replace(text)

    local result = f:NewStringLiteral(text, TokenFlags.None)
    result.loc = node.loc
    return result
end

function estransforms.hasInvalidEscape(template)
    if ast.IsNoSubstitutionTemplateLiteral(template) then
        return template:TemplateLiteralLikeData().templateFlags & TokenFlags.ContainsInvalidEscape ~= 0
    end
    local te = template:AsTemplateExpression()
    if te.head:TemplateLiteralLikeData().templateFlags & TokenFlags.ContainsInvalidEscape ~= 0 then
        return true
    end
    for _, span in ipairs(te.templateSpans.nodes) do
        if span:AsTemplateSpan().literal:TemplateLiteralLikeData().templateFlags & TokenFlags.ContainsInvalidEscape ~= 0 then
            return true
        end
    end
    return false
end
