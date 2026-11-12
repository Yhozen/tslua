local jsxtransforms = require("tslua.transformers.jsxtransforms")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local TokenFlags = ast.TokenFlags
local EF = printer.EmitFlags
local JsxEmit = core.JsxEmit
local ScriptTarget = core.ScriptTarget

-- Fields: compilerOptions, emitResolver, importSpecifier, filenameDeclaration,
-- utilizedImplicitRuntimeImports (OrderedMap importSource -> table name -> ImportSpecifier),
-- inJsxChild, currentSourceFile.
local JSXTransformer = transformers.NewTransformerType()
jsxtransforms.JSXTransformer = JSXTransformer

function jsxtransforms.NewJSXTransformer(opts)
    local compilerOptions = opts.compilerOptions
    local emitContext = opts.context
    local tx = setmetatable({
        compilerOptions = compilerOptions,
        emitResolver = opts.emitResolver,
        importSpecifier = "",
        filenameDeclaration = nil,
        utilizedImplicitRuntimeImports = collections.NewOrderedMap(),
        inJsxChild = false,
        currentSourceFile = nil,
    }, JSXTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
end

function JSXTransformer:getCurrentFileNameExpression()
    if self.filenameDeclaration ~= nil then
        return self.filenameDeclaration:AsVariableDeclaration():Name()
    end
    local d = self:Factory():NewVariableDeclaration(
        self:Factory():NewUniqueNameEx("_jsxFileName", {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
        }),
        nil,
        nil,
        self:Factory():NewStringLiteral(self.currentSourceFile:FileName(), TokenFlags.None)
    )
    self.filenameDeclaration = d
    return d:AsVariableDeclaration():Name()
end

function JSXTransformer:getJsxFactoryCalleePrimitive(isStaticChildren)
    if self.compilerOptions.jsx == JsxEmit.ReactJSXDev then
        return "jsxDEV"
    end
    if isStaticChildren then
        return "jsxs"
    end
    return "jsx"
end

function JSXTransformer:getJsxFactoryCallee(isStaticChildren)
    local t = self:getJsxFactoryCalleePrimitive(isStaticChildren)
    return self:getImplicitImportForName(t)
end

function JSXTransformer:getImplicitJsxFragmentReference()
    return self:getImplicitImportForName("Fragment")
end

function JSXTransformer:getImplicitImportForName(name)
    local importSource = self.importSpecifier
    if name ~= "createElement" then
        importSource = ast.GetJSXRuntimeImport(importSource, self.compilerOptions)
    end
    local existing, ok = self.utilizedImplicitRuntimeImports:Get(importSource)
    if ok then
        local elem = existing[name]
        if elem ~= nil then
            return elem:AsImportSpecifier():Name()
        end
    else
        existing = {}
        self.utilizedImplicitRuntimeImports:Set(importSource, existing)
    end

    local generatedName = self:Factory():NewUniqueNameEx("_" .. name, {
        flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel |
            printer.GeneratedIdentifierFlagsAllowNameSubstitution,
    })
    local specifier = self:Factory():NewImportSpecifier(false, self:Factory():NewIdentifier(name), generatedName)
    self.emitResolver:SetReferencedImportDeclaration(generatedName, specifier)
    existing[name] = specifier
    return specifier:Name()
end

function JSXTransformer:setInChild(v)
    self.inJsxChild = v
end

function JSXTransformer:visit(node)
    if node == nil then
        return nil
    end
    if node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsJsx == 0 then
        return node
    end
    local kind = node.kind
    if kind == Kind.SourceFile then
        self:setInChild(false)
        return self:visitSourceFile(node:AsSourceFile())
    elseif kind == Kind.JsxElement then
        return self:visitJsxElement(node:AsJsxElement())
    elseif kind == Kind.JsxSelfClosingElement then
        return self:visitJsxSelfClosingElement(node:AsJsxSelfClosingElement())
    elseif kind == Kind.JsxFragment then
        return self:visitJsxFragment(node:AsJsxFragment())
    elseif kind == Kind.JsxOpeningElement then
        error("JsxOpeningElement should not be visited, handled in visitJsxElement", 0)
    elseif kind == Kind.JsxOpeningFragment then
        error("JsxOpeningFragment should not be visited, handled in visitJsxFragment", 0)
    elseif kind == Kind.JsxText then
        self:setInChild(false)
        return self:visitJsxText(node:AsJsxText())
    elseif kind == Kind.JsxExpression then
        self:setInChild(false)
        return self:visitJsxExpression(node:AsJsxExpression())
    end
    self:setInChild(false)
    return self:Visitor():VisitEachChild(node) -- by default, do nothing
end

--[[*
 * The react jsx/jsxs transform falls back to `createElement` when an explicit `key` argument comes after a spread
 ]]
function jsxtransforms.hasKeyAfterPropsSpread(node)
    local spread = false
    local opener = node
    if node.kind == Kind.JsxElement then
        opener = node:AsJsxElement().openingElement
    end -- otherwise self-closing
    for _, elem in ipairs(opener:Attributes():Properties() or {}) do
        if ast.IsJsxSpreadAttribute(elem) and (not ast.IsObjectLiteralExpression(elem:Expression()) or core.Some(elem:Expression():Properties(), ast.IsSpreadAssignment)) then
            spread = true
        elseif spread and ast.IsJsxAttribute(elem) and ast.IsIdentifier(elem:Name()) and elem:Name():Text() == "key" then
            return true
        end
    end
    return false
end

function JSXTransformer:shouldUseCreateElement(node)
    return #self.importSpecifier == 0 or jsxtransforms.hasKeyAfterPropsSpread(node)
end

function jsxtransforms.insertStatementAfterPrologue(to, statement, isPrologueDirective, callee)
    if statement == nil then
        return to
    end
    local statementIdx = 0
    -- skip all prologue directives to insert at the correct position
    while statementIdx < core.Len(to) do
        if not isPrologueDirective(callee, to[statementIdx + 1]) then
            break
        end
        statementIdx = statementIdx + 1
    end
    -- slices.Insert
    local result = {}
    for i = 1, statementIdx do
        result[#result + 1] = to[i]
    end
    result[#result + 1] = statement
    for i = statementIdx + 1, core.Len(to) do
        result[#result + 1] = to[i]
    end
    return result
end

function JSXTransformer:isAnyPrologueDirective(node)
    return ast.IsPrologueDirective(node) or (self:EmitContext():EmitFlags(node) & EF.EFCustomPrologue ~= 0)
end

function JSXTransformer:insertStatementAfterCustomPrologue(to, statement)
    return jsxtransforms.insertStatementAfterPrologue(to, statement, JSXTransformer.isAnyPrologueDirective, self)
end

function jsxtransforms.sortImportSpecifiers(a, b)
    local res = stringutil.CompareStringsCaseSensitive(a:PropertyName():Text(), b:PropertyName():Text())
    if res ~= 0 then
        return res
    end
    return stringutil.CompareStringsCaseSensitive(a:AsImportSpecifier():Name():Text(), b:AsImportSpecifier():Name():Text())
end

function jsxtransforms.getSortedSpecifiers(m)
    local res = {}
    for _, v in pairs(m) do
        res[#res + 1] = v
    end
    core.SortFunc(res, jsxtransforms.sortImportSpecifiers)
    return res
end

function JSXTransformer:visitSourceFile(file)
    if file.isDeclarationFile then
        return file:AsNode()
    end

    self.currentSourceFile = file
    self.importSpecifier = ast.GetJSXImplicitImportBase(self.compilerOptions, file)
    self.filenameDeclaration = nil
    self.utilizedImplicitRuntimeImports:Clear()

    local visited = self:Visitor():VisitEachChild(file:AsNode())
    self:EmitContext():AddEmitHelper(visited:AsNode(), table.unpack(self:EmitContext():ReadEmitHelpers()))
    local statements = visited:Statements()
    local statementsUpdated = false
    if self.filenameDeclaration ~= nil then
        statements = self:insertStatementAfterCustomPrologue(statements, self:Factory():NewVariableStatement(nil, self:Factory():NewVariableDeclarationList(
            self:Factory():NewNodeList({ self.filenameDeclaration }),
            NodeFlags.Const
        )))
        statementsUpdated = true
    end

    if self.utilizedImplicitRuntimeImports:Size() > 0 then
        if ast.IsExternalModule(file) then
            statementsUpdated = true
            local newStatements = {}
            for importSource, importSpecifiersMap in self.utilizedImplicitRuntimeImports:Entries() do
                local s = self:Factory():NewImportDeclaration(
                    nil,
                    self:Factory():NewImportClause(Kind.Unknown, nil, self:Factory():NewNamedImports(self:Factory():NewNodeList(jsxtransforms.getSortedSpecifiers(importSpecifiersMap)))),
                    self:Factory():NewStringLiteral(importSource, TokenFlags.None),
                    nil
                )
                ast.SetParentInChildren(s)
                newStatements[#newStatements + 1] = s
            end
            for _, e in ipairs(newStatements) do
                statements = self:insertStatementAfterCustomPrologue(statements, e)
            end
        elseif ast.IsExternalOrCommonJSModule(file) then
            statementsUpdated = true
            local newStatements = {}
            for importSource, importSpecifiersMap in self.utilizedImplicitRuntimeImports:Entries() do
                local sorted = jsxtransforms.getSortedSpecifiers(importSpecifiersMap)
                local asBindingElems = {}
                for _, elem in ipairs(sorted) do
                    asBindingElems[#asBindingElems + 1] = self:Factory():NewBindingElement(nil, elem:PropertyName(), elem:AsImportSpecifier():Name(), nil)
                end
                local s = self:Factory():NewVariableStatement(nil, self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ self:Factory():NewVariableDeclaration(
                    self:Factory():NewBindingPattern(Kind.ObjectBindingPattern, self:Factory():NewNodeList(asBindingElems)),
                    nil,
                    nil,
                    self:Factory():NewCallExpression(
                        self:Factory():NewIdentifier("require"),
                        nil,
                        nil,
                        self:Factory():NewNodeList({ self:Factory():NewStringLiteral(importSource, TokenFlags.None) }), NodeFlags.None
                    )
                ) }), NodeFlags.Const))
                ast.SetParentInChildren(s)
                newStatements[#newStatements + 1] = s
            end
            for _, e in ipairs(newStatements) do
                statements = self:insertStatementAfterCustomPrologue(statements, e)
            end
        else -- luacheck: ignore 542
            -- Do nothing (script file) - consider an error in the checker?
        end
    end

    if statementsUpdated then
        visited = self:Factory():UpdateSourceFile(file, self:Factory():NewNodeList(statements), file.endOfFileToken)
    end

    self.currentSourceFile = nil
    self.importSpecifier = ""
    self.filenameDeclaration = nil
    self.utilizedImplicitRuntimeImports:Clear()

    return visited
end

function JSXTransformer:visitJsxElement(element)
    local tagTransform = JSXTransformer.visitJsxOpeningLikeElementJSX
    if self:shouldUseCreateElement(element:AsNode()) then
        tagTransform = JSXTransformer.visitJsxOpeningLikeElementCreateElement
    end
    local location = core.NewTextRange(scanner.SkipTrivia(self.currentSourceFile:Text(), element:Pos()), element:End())
    return tagTransform(self, element.openingElement, element.children, location)
end

function JSXTransformer:visitJsxSelfClosingElement(element)
    local tagTransform = JSXTransformer.visitJsxOpeningLikeElementJSX
    if self:shouldUseCreateElement(element:AsNode()) then
        tagTransform = JSXTransformer.visitJsxOpeningLikeElementCreateElement
    end
    local location = core.NewTextRange(scanner.SkipTrivia(self.currentSourceFile:Text(), element:Pos()), element:End())
    return tagTransform(self, element:AsNode(), nil, location)
end

function JSXTransformer:visitJsxFragment(fragment)
    local tagTransform = JSXTransformer.visitJsxOpeningFragmentJSX
    if #self.importSpecifier == 0 then
        tagTransform = JSXTransformer.visitJsxOpeningFragmentCreateElement
    end
    local location = core.NewTextRange(scanner.SkipTrivia(self.currentSourceFile:Text(), fragment:Pos()), fragment:End())
    return tagTransform(self, fragment.openingFragment:AsJsxOpeningFragment(), fragment.children, location)
end

function JSXTransformer:convertJsxChildrenToChildrenPropObject(children)
    local prop = self:convertJsxChildrenToChildrenPropAssignment(children)
    if prop == nil then
        return nil
    end
    return self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({ prop }), false)
end

function JSXTransformer:transformJsxChildToExpression(node)
    local prev = self.inJsxChild
    self:setInChild(true)
    local result = self:Visitor().visit(node)
    self:setInChild(prev)
    return result
end

function JSXTransformer:convertJsxChildrenToChildrenPropAssignment(children)
    local nonWhitespceChildren = ast.GetSemanticJsxChildren(children)
    if #nonWhitespceChildren == 1 and (nonWhitespceChildren[1].kind ~= Kind.JsxExpression or nonWhitespceChildren[1]:AsJsxExpression().dotDotDotToken == nil) then
        local result = self:transformJsxChildToExpression(nonWhitespceChildren[1])
        if result == nil then
            return nil
        end
        return self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("children"), nil, nil, result)
    end
    -- For multiple children in the children property array, don't set StartOnNewLine
    -- on child elements — the array literal is single-line.
    local results = {}
    for _, child in ipairs(nonWhitespceChildren) do
        local res = self:transformJsxChildToExpression(child)
        if res ~= nil then
            self:EmitContext():SetEmitFlags(res, self:EmitContext():EmitFlags(res) & ~EF.EFStartOnNewLine)
            results[#results + 1] = res
        end
    end
    if #results == 0 then
        return nil
    end
    return self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("children"), nil, nil, self:Factory():NewArrayLiteralExpression(self:Factory():NewNodeList(results), false))
end

function JSXTransformer:getTagName(node)
    if node.kind == Kind.JsxElement then
        return self:getTagName(node:AsJsxElement().openingElement)
    elseif ast.IsJsxOpeningLikeElement(node) then
        local tagName = node:TagName()
        if ast.IsIdentifier(tagName) and scanner.IsIntrinsicJsxName(tagName:Text()) then
            return self:Factory():NewStringLiteral(tagName:Text(), TokenFlags.None)
        elseif ast.IsJsxNamespacedName(tagName) then
            return self:Factory():NewStringLiteral(
                tagName:AsJsxNamespacedName().namespace:Text() .. ":" .. tagName:AsJsxNamespacedName():Name():Text(), TokenFlags.None
            )
        else
            return self:Factory():CreateExpressionFromEntityName(tagName)
        end
    else
        error("unhandled node kind passed to getTagName: " .. ast.Kind_String(node.kind), 0)
    end
end

function JSXTransformer:visitJsxOpeningLikeElementJSX(element, children, location)
    local tagName = self:getTagName(element)
    local childrenProp = nil
    if children ~= nil and core.Len(children.nodes) > 0 then
        childrenProp = self:convertJsxChildrenToChildrenPropAssignment(children.nodes)
    end
    local keyAttr = nil
    local attrs = element:Attributes():Properties() or {}
    for i1, p in ipairs(attrs) do
        if p.kind == Kind.JsxAttribute and p:AsJsxAttribute():Name() ~= nil and ast.IsIdentifier(p:AsJsxAttribute():Name()) and p:AsJsxAttribute():Name():Text() == "key" then
            keyAttr = p
            local cloned = {}
            for j, a in ipairs(attrs) do
                if j ~= i1 then
                    cloned[#cloned + 1] = a
                end
            end
            attrs = cloned
            break
        end
    end
    local object
    if #attrs > 0 then
        object = self:transformJsxAttributesToObjectProps(attrs, childrenProp)
    else
        local objectChildren = {}
        if childrenProp ~= nil then
            objectChildren[#objectChildren + 1] = childrenProp
        end
        object = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(objectChildren), false) -- When there are no attributes, React wants {}
    end
    return self:visitJsxOpeningLikeElementOrFragmentJSX(
        tagName,
        object,
        keyAttr,
        children,
        location
    )
end

function JSXTransformer:transformJsxAttributesToObjectProps(attrs, childrenProp)
    local target = self.compilerOptions:GetEmitScriptTarget()
    if target >= ScriptTarget.ES2018 then
        -- target has object spreads, can keep as-is
        return self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(self:transformJsxAttributesToProps(attrs, childrenProp)), false)
    end
    return self:transformJsxAttributesToExpression(attrs, childrenProp)
end

function JSXTransformer:transformJsxAttributesToExpression(attrs, childrenProp)
    local expressions = {}
    local properties = {}

    for _, attr in ipairs(attrs) do
        if ast.IsJsxSpreadAttribute(attr) then
            -- as an optimization we try to flatten the first level of spread inline object
            -- as if its props would be passed as JSX attributes
            if ast.IsObjectLiteralExpression(attr:Expression()) and not jsxtransforms.hasProto(attr:Expression():AsObjectLiteralExpression()) then
                for _, prop in ipairs(attr:Expression():Properties() or {}) do
                    if ast.IsSpreadAssignment(prop) then
                        expressions, properties = self:combinePropertiesIntoNewExpression(expressions, properties)
                        expressions[#expressions + 1] = self:Visitor().visit(prop:Expression())
                    else
                        properties[#properties + 1] = self:Visitor().visit(prop)
                    end
                end
            else
                expressions, properties = self:combinePropertiesIntoNewExpression(expressions, properties)
                expressions[#expressions + 1] = self:Visitor().visit(attr:Expression())
            end
        else
            properties[#properties + 1] = self:transformJsxAttributeToObjectLiteralElement(attr:AsJsxAttribute())
        end
    end

    if childrenProp ~= nil then
        properties[#properties + 1] = childrenProp
    end

    expressions = self:combinePropertiesIntoNewExpression(expressions, properties)

    if #expressions > 0 and not ast.IsObjectLiteralExpression(expressions[1]) then
        -- We must always emit at least one object literal before a spread attribute
        -- as the JSX always factory expects a fresh object, so we need to make a copy here
        -- we also avoid mutating an external reference by doing this (first expression is used as assign's target)
        table.insert(expressions, 1, self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({}), false))
    end

    if #expressions == 1 then
        return expressions[1]
    end
    return self:Factory():NewAssignHelper(expressions, self.compilerOptions:GetEmitScriptTarget())
end

-- Returns (expressions, props); Go returns a nil props slice after combining, here an empty array.
function JSXTransformer:combinePropertiesIntoNewExpression(expressions, props)
    if #props == 0 then
        return expressions, props
    end
    local newObj = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(props), false)
    expressions[#expressions + 1] = newObj
    return expressions, {}
end

function JSXTransformer:transformJsxAttributesToProps(attrs, childrenProp)
    local props = {}
    for _, attr in ipairs(attrs) do
        if attr.kind == Kind.JsxSpreadAttribute then
            local res = self:transformJsxSpreadAttributesToProps(attr:AsJsxSpreadAttribute())
            for _, r in ipairs(res or {}) do
                props[#props + 1] = r
            end
        else
            props[#props + 1] = self:transformJsxAttributeToObjectLiteralElement(attr:AsJsxAttribute())
        end
    end
    if childrenProp ~= nil then
        props[#props + 1] = childrenProp
    end
    return props
end

function jsxtransforms.hasProto(obj)
    for _, p in ipairs(obj.properties.nodes) do
        if ast.IsPropertyAssignment(p) and (ast.IsStringLiteral(p:Name()) or ast.IsIdentifier(p:Name())) and p:Name():Text() == "__proto__" then
            return true
        end
    end
    return false
end

function JSXTransformer:transformJsxSpreadAttributesToProps(node)
    if ast.IsObjectLiteralExpression(node.expression) and not jsxtransforms.hasProto(node.expression:AsObjectLiteralExpression()) then
        local res = self:Visitor():VisitSlice(node.expression:Properties())
        return res
    end
    return { self:Factory():NewSpreadAssignment(self:Visitor().visit(node.expression)) }
end

function JSXTransformer:transformJsxAttributeToObjectLiteralElement(node)
    local name = self:getAttributeName(node)
    local expression = self:transformJsxAttributeInitializer(node.initializer)
    return self:Factory():NewPropertyAssignment(nil, name, nil, nil, expression)
end

--[[*
* Emit an attribute name, which is quoted if it needs to be quoted. Because
* these emit into an object literal property name, we don't need to be worried
* about keywords, just non-identifier characters
 ]]
function JSXTransformer:getAttributeName(node)
    local name = node:Name()
    if ast.IsIdentifier(name) then
        local text = name:Text()
        if scanner.IsIdentifierText(text, core.LanguageVariant.Standard) then
            return name
        end
        return self:Factory():NewStringLiteral(text, TokenFlags.None)
    end
    -- must be jsx namespace
    return self:Factory():NewStringLiteral(
        name:AsJsxNamespacedName().namespace:Text() .. ":" .. name:AsJsxNamespacedName():Name():Text(), TokenFlags.None
    )
end

function JSXTransformer:transformJsxAttributeInitializer(node)
    if node == nil then
        return self:Factory():NewTrueExpression()
    end
    if node.kind == Kind.StringLiteral then
        -- Always recreate the literal to escape any escape sequences or newlines which may be in the original jsx string and which
        -- Need to be escaped to be handled correctly in a normal string
        local res = self:Factory():NewStringLiteral(jsxtransforms.decodeEntities(node:Text()), node:AsStringLiteral().tokenFlags)
        res.loc = node.loc
        -- Preserve the original quote style (single vs double quotes)
        res:AsStringLiteral().tokenFlags = node:AsStringLiteral().tokenFlags
        return res
    end
    if node.kind == Kind.JsxExpression then
        if node:Expression() == nil then
            return self:Factory():NewTrueExpression()
        end
        return self:Visitor().visit(node:Expression())
    end
    if ast.IsJsxElement(node) or ast.IsJsxSelfClosingElement(node) or ast.IsJsxFragment(node) then
        self:setInChild(false)
        return self:Visitor().visit(node)
    end
    error("Unhandled node kind found in jsx initializer: " .. ast.Kind_String(node.kind), 0)
end

function JSXTransformer:visitJsxOpeningLikeElementOrFragmentJSX(tagName, object, keyAttr, children, location)
    local nonWhitespaceChildren = nil
    if children ~= nil then
        nonWhitespaceChildren = ast.GetSemanticJsxChildren(children.nodes)
    end
    local n = core.Len(nonWhitespaceChildren)
    local isStaticChildren = n > 1 or (n == 1 and ast.IsJsxExpression(nonWhitespaceChildren[1]) and nonWhitespaceChildren[1]:AsJsxExpression().dotDotDotToken ~= nil)
    local args = {}
    args[#args + 1] = tagName
    args[#args + 1] = object
    -- function jsx(type, config, maybeKey) {}
    -- "maybeKey" is optional. It is acceptable to use "_jsx" without a third argument
    if keyAttr ~= nil then
        args[#args + 1] = self:transformJsxAttributeInitializer(keyAttr:Initializer())
    end

    if self.compilerOptions.jsx == JsxEmit.ReactJSXDev then
        local originalFile = self:EmitContext():MostOriginal(self.currentSourceFile:AsNode())
        if originalFile ~= nil and ast.IsSourceFile(originalFile) then
            -- "maybeKey" has to be replaced with "void 0" to not break the jsxDEV signature
            if keyAttr == nil then
                args[#args + 1] = self:Factory():NewVoidZeroExpression()
            end
            -- isStaticChildren development flag
            if isStaticChildren then
                args[#args + 1] = self:Factory():NewTrueExpression()
            else
                args[#args + 1] = self:Factory():NewFalseExpression()
            end
            -- __source development flag
            local line, col = scanner.GetECMALineAndUTF16CharacterOfPosition(originalFile:AsSourceFile(), location.pos)
            args[#args + 1] = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({
                self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("fileName"), nil, nil, self:getCurrentFileNameExpression()),
                self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("lineNumber"), nil, nil, self:Factory():NewNumericLiteral(string.format("%d", line + 1), TokenFlags.None)),
                self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("columnNumber"), nil, nil, self:Factory():NewNumericLiteral(string.format("%d", col + 1), TokenFlags.None)),
            }), false)
            -- __self development flag
            args[#args + 1] = self:Factory():NewThisExpression()
        end
    end

    local element = self:Factory():NewCallExpression(self:getJsxFactoryCallee(isStaticChildren), nil, nil, self:Factory():NewNodeList(args), NodeFlags.None)
    element.loc = location

    if self.inJsxChild then
        self:EmitContext():AddEmitFlags(element, EF.EFStartOnNewLine)
    end

    return element
end

function JSXTransformer:visitJsxOpeningFragmentJSX(fragment, children, location)
    local childrenProps = nil
    if children ~= nil and core.Len(children.nodes) > 0 then
        local result = self:convertJsxChildrenToChildrenPropObject(children.nodes)
        if result ~= nil then
            childrenProps = result
        end
    end
    if childrenProps == nil then
        childrenProps = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({}), false)
    end
    return self:visitJsxOpeningLikeElementOrFragmentJSX(
        self:getImplicitJsxFragmentReference(),
        childrenProps,
        nil,
        children,
        location
    )
end

function JSXTransformer:createReactNamespace(reactNamespace, parent)
    -- To ensure the emit resolver can properly resolve the namespace, we need to
    -- treat this identifier as if it were a source tree node by clearing the `Synthesized`
    -- flag and setting a parent node. TODO: Is this still true? The emit resolver is supposed to be
    -- hardened aginast this, so long as the node retains original node pointers back to a parsed node
    if #reactNamespace == 0 then
        reactNamespace = "React"
    end
    local react = self:Factory():NewIdentifier(reactNamespace)
    react.flags = react.flags & ~NodeFlags.Synthesized

    -- Set the parent that is in parse tree
    -- this makes sure that parent chain is intact for checker to traverse complete scope tree
    react.parent = self:EmitContext():ParseNode(parent)

    -- If the identifier refers to an exported member of a namespace, substitute with
    -- a qualified namespace property access (e.g., `React` -> `M.React`).
    -- See also: RuntimeSyntaxTransformer.visitExpressionIdentifier in runtimesyntax.go
    local container = self.emitResolver:GetReferencedExportContainer(react, false --[[prefixLocals]])
    if container ~= nil and ast.IsModuleDeclaration(container) then
        local containerName = self:Factory():NewGeneratedNameForNode(container)
        return self:Factory():NewPropertyAccessExpression(containerName, nil, react, NodeFlags.None)
    end

    return react
end

function JSXTransformer:createJsxFactoryExpressionFromEntityName(e, parent)
    if ast.IsQualifiedName(e) then
        local left = self:createJsxFactoryExpressionFromEntityName(e:AsQualifiedName().left, parent)
        local right = self:Factory():NewIdentifier(e:AsQualifiedName().right:Text())
        return self:Factory():NewPropertyAccessExpression(left, nil, right, NodeFlags.None)
    end
    return self:createReactNamespace(e:Text(), parent)
end

function JSXTransformer:createJsxPseudoFactoryExpression(parent, e, target)
    if e ~= nil then
        return self:createJsxFactoryExpressionFromEntityName(e, parent)
    end
    return self:Factory():NewPropertyAccessExpression(
        self:createReactNamespace(self.compilerOptions.reactNamespace, parent),
        nil,
        self:Factory():NewIdentifier(target),
        NodeFlags.None
    )
end

function JSXTransformer:createJsxFactoryExpression(parent)
    local e = self.emitResolver:GetJsxFactoryEntity(self.currentSourceFile:AsNode())
    return self:createJsxPseudoFactoryExpression(parent, e, "createElement")
end

function JSXTransformer:createJsxFragmentFactoryExpression(parent)
    local e = self.emitResolver:GetJsxFragmentFactoryEntity(self.currentSourceFile:AsNode())
    return self:createJsxPseudoFactoryExpression(parent, e, "Fragment")
end

function JSXTransformer:visitJsxOpeningLikeElementCreateElement(element, children, location)
    local tagName = self:getTagName(element)
    local attrs = element:Attributes():Properties() or {}
    local objectProperties
    if #attrs > 0 then
        objectProperties = self:transformJsxAttributesToObjectProps(attrs, nil)
    else
        objectProperties = self:Factory():NewKeywordExpression(Kind.NullKeyword) -- When there are no attributes, React wants "null"
    end

    local callee
    if #self.importSpecifier == 0 then
        callee = self:createJsxFactoryExpression(element)
    else
        callee = self:getImplicitImportForName("createElement")
    end

    local newChildren = {}
    if children ~= nil and core.Len(children.nodes) > 0 then
        for _, c in ipairs(children.nodes) do
            local res = self:transformJsxChildToExpression(c)
            if res ~= nil then
                newChildren[#newChildren + 1] = res
            end
        end
    end

    -- Add StartOnNewLine flag only if there are multiple actual children (after filtering)
    if #newChildren > 1 then
        for _, child in ipairs(newChildren) do
            self:EmitContext():AddEmitFlags(child, EF.EFStartOnNewLine)
        end
    end

    local args = {}
    args[#args + 1] = tagName
    args[#args + 1] = objectProperties
    for _, c in ipairs(newChildren) do
        args[#args + 1] = c
    end

    local result = self:Factory():NewCallExpression(
        callee,
        nil,
        nil,
        self:Factory():NewNodeList(args),
        NodeFlags.None
    )
    result.loc = location

    if self.inJsxChild then
        self:EmitContext():AddEmitFlags(result, EF.EFStartOnNewLine)
    end
    return result
end

function JSXTransformer:visitJsxOpeningFragmentCreateElement(fragment, children, location)
    local tagName = self:createJsxFragmentFactoryExpression(fragment:AsNode())
    local callee = self:createJsxFactoryExpression(fragment:AsNode())

    local newChildren = {}
    if children ~= nil and core.Len(children.nodes) > 0 then
        for _, c in ipairs(children.nodes) do
            local res = self:transformJsxChildToExpression(c)
            if res ~= nil then
                newChildren[#newChildren + 1] = res
            end
        end
    end

    -- Add StartOnNewLine flag only if there are multiple actual children (after filtering)
    if #newChildren > 1 then
        for _, child in ipairs(newChildren) do
            self:EmitContext():AddEmitFlags(child, EF.EFStartOnNewLine)
        end
    end

    local args = {}
    args[#args + 1] = tagName
    args[#args + 1] = self:Factory():NewKeywordExpression(Kind.NullKeyword)
    for _, c in ipairs(newChildren) do
        args[#args + 1] = c
    end

    local result = self:Factory():NewCallExpression(
        callee,
        nil,
        nil,
        self:Factory():NewNodeList(args),
        NodeFlags.None
    )
    result.loc = location

    if self.inJsxChild then
        self:EmitContext():AddEmitFlags(result, EF.EFStartOnNewLine)
    end
    return result
end

function JSXTransformer:visitJsxText(text)
    local fixed = jsxtransforms.fixupWhitespaceAndDecodeEntities(text.text)
    if #fixed == 0 then
        return nil
    end
    return self:Factory():NewStringLiteral(fixed, TokenFlags.None)
end

-- b is a buffer table (Go *strings.Builder).
function jsxtransforms.addLineOfJsxText(b, trimmedLine, isInitial)
    -- We do not escape the string here as that is handled by the printer
    -- when it emits the literal. We do, however, need to decode JSX entities.
    local decoded = jsxtransforms.decodeEntities(trimmedLine)
    if not isInitial then
        b[#b + 1] = " "
    end
    b[#b + 1] = decoded
end

--[[*
* JSX trims whitespace at the end and beginning of lines, except that the
* start/end of a tag is considered a start/end of a line only if that line is
* on the same line as the closing tag. See examples in
* tests/cases/conformance/jsx/tsxReactEmitWhitespace.tsx
* See also https://www.w3.org/TR/html4/struct/text.html#h-9.1 and https://www.w3.org/TR/CSS2/text.html#white-space-model
*
* An equivalent algorithm would be:
* - If there is only one line, return it.
* - If there is only whitespace (but multiple lines), return `undefined`.
* - Split the text into lines.
* - 'trimRight' the first line, 'trimLeft' the last line, 'trim' middle lines.
* - Decode entities on each line (individually).
* - Remove empty lines and join the rest with " ".
 ]]
function jsxtransforms.fixupWhitespaceAndDecodeEntities(text)
    local acc = {}
    local initial = true
    -- First non-whitespace character on this line.
    local firstNonWhitespace = 0
    -- End byte position of the last non-whitespace character on this line.
    local lastNonWhitespaceEnd = -1
    -- These initial values are special because the first line is:
    -- firstNonWhitespace = 0 to indicate that we want leading whitespace,
    -- but lastNonWhitespaceEnd = -1 as a special flag to indicate that we *don't* include the line if it's all whitespace.
    local i = 0
    while i < #text do
        local c, size = core.DecodeRune(text, i)
        if stringutil.IsLineBreak(c) then
            -- If we've seen any non-whitespace characters on this line, add the 'trim' of the line.
            -- (lastNonWhitespaceEnd === -1 is a special flag to detect whether the first line is all whitespace.)
            if firstNonWhitespace ~= -1 and lastNonWhitespaceEnd ~= -1 then
                jsxtransforms.addLineOfJsxText(acc, string.sub(text, firstNonWhitespace + 1, lastNonWhitespaceEnd + 1), initial)
                initial = false
            end

            -- Reset firstNonWhitespace for the next line.
            -- Don't bother to reset lastNonWhitespaceEnd because we ignore it if firstNonWhitespace = -1.
            firstNonWhitespace = -1
        elseif not stringutil.IsWhiteSpaceSingleLine(c) then
            lastNonWhitespaceEnd = i + size - 1 -- Store the end byte position of the character
            if firstNonWhitespace == -1 then
                firstNonWhitespace = i
            end
        end

        if size > 1 then
            i = i + (size - 1)
        end
        i = i + 1
    end

    if firstNonWhitespace ~= -1 then
        -- Last line had a non-whitespace character. Emit the 'trimLeft', meaning keep trailing whitespace.
        jsxtransforms.addLineOfJsxText(acc, string.sub(text, firstNonWhitespace + 1), initial)
    end
    return table.concat(acc)
end

function JSXTransformer:visitJsxExpression(expression)
    local e = self:Visitor().visit(expression.expression)
    if expression.dotDotDotToken ~= nil then
        return self:Factory():NewSpreadElement(e)
    end
    return e
end

-- Go strings.IndexByte: 0-based index or -1.
local function indexByte(s, c)
    local p = string.find(s, c, 1, true)
    if p == nil then
        return -1
    end
    return p - 1
end

--[[*
* Replace entities like "&nbsp;", "&#123;", and "&#xDEADBEEF;" with the characters they encode.
* See https://en.wikipedia.org/wiki/List_of_XML_and_HTML_character_entity_references
 ]]
function jsxtransforms.decodeEntities(text)
    local i = indexByte(text, "&")
    if i < 0 then
        return text
    end

    local result = {}
    while true do
        result[#result + 1] = string.sub(text, 1, i)
        text = string.sub(text, i + 1)

        local semi = indexByte(text, ";")
        if semi < 0 then
            break
        end

        -- Skip past any intervening '&' characters between the current '&'
        -- and the ';'. Each such '&' is not part of a valid entity, so emit
        -- it (and any text before the next '&') as literals.
        while true do
            local nextAmp = indexByte(string.sub(text, 2, semi), "&")
            if nextAmp < 0 then
                break
            end
            result[#result + 1] = string.sub(text, 1, nextAmp + 1)
            text = string.sub(text, nextAmp + 2)
            semi = semi - (nextAmp + 1)
        end

        local entity = string.sub(text, 2, semi)
        local decoded, ok = jsxtransforms.decodeEntity(entity)
        if ok then
            -- Use the JS-string encoder so lone surrogates (e.g. "&#xD800;")
            -- are preserved rather than being lost to U+FFFD by WriteRune.
            result[#result + 1] = stringutil.EncodeJSStringRune(decoded)
        else
            result[#result + 1] = string.sub(text, 1, semi + 1)
        end
        text = string.sub(text, semi + 2)

        i = indexByte(text, "&")
        if i < 0 then
            break
        end
    end
    result[#result + 1] = text
    return table.concat(result)
end

-- Go strconv.ParseInt(s, base, 32) for a string of digits valid in base (no sign); returns (value, ok).
local function parseInt32(s, base)
    local v = 0
    for k = 1, #s do
        local c = string.byte(s, k)
        local d
        if c >= 0x30 and c <= 0x39 then
            d = c - 0x30
        elseif c >= 0x61 and c <= 0x66 then
            d = c - 0x61 + 10
        else
            d = c - 0x41 + 10
        end
        v = v * base + d
        if v > 0x7FFFFFFF then
            return 0, false
        end
    end
    return v, true
end

-- Returns (rune, ok).
function jsxtransforms.decodeEntity(entity)
    if #entity == 0 then
        return 0, false
    end

    if string.byte(entity, 1) == 0x23 --[[ '#' ]] then
        entity = string.sub(entity, 2)
        if #entity == 0 then
            return 0, false
        end

        local base = 10
        if string.byte(entity, 1) == 0x78 --[[ 'x' ]] then
            base = 16
            entity = string.sub(entity, 2)
        end

        if #entity == 0 then
            return 0, false
        end

        local pos = 0
        while pos < #entity do
            local c, size = core.DecodeRune(entity, pos)
            if base == 16 and not stringutil.IsHexDigit(c) then
                return 0, false
            end
            if base == 10 and not stringutil.IsDigit(c) then
                return 0, false
            end
            pos = pos + size
        end

        local parsed, ok = parseInt32(entity, base)
        if not ok then
            return 0, false
        end
        return parsed, true
    end

    local r = jsxtransforms.entities[entity]
    if r == nil then
        return 0, false
    end
    return r, true
end

jsxtransforms.entities = {
    quot = 0x0022,
    amp = 0x0026,
    apos = 0x0027,
    lt = 0x003C,
    gt = 0x003E,
    nbsp = 0x00A0,
    iexcl = 0x00A1,
    cent = 0x00A2,
    pound = 0x00A3,
    curren = 0x00A4,
    yen = 0x00A5,
    brvbar = 0x00A6,
    sect = 0x00A7,
    uml = 0x00A8,
    copy = 0x00A9,
    ordf = 0x00AA,
    laquo = 0x00AB,
    ["not"] = 0x00AC,
    shy = 0x00AD,
    reg = 0x00AE,
    macr = 0x00AF,
    deg = 0x00B0,
    plusmn = 0x00B1,
    sup2 = 0x00B2,
    sup3 = 0x00B3,
    acute = 0x00B4,
    micro = 0x00B5,
    para = 0x00B6,
    middot = 0x00B7,
    cedil = 0x00B8,
    sup1 = 0x00B9,
    ordm = 0x00BA,
    raquo = 0x00BB,
    frac14 = 0x00BC,
    frac12 = 0x00BD,
    frac34 = 0x00BE,
    iquest = 0x00BF,
    Agrave = 0x00C0,
    Aacute = 0x00C1,
    Acirc = 0x00C2,
    Atilde = 0x00C3,
    Auml = 0x00C4,
    Aring = 0x00C5,
    AElig = 0x00C6,
    Ccedil = 0x00C7,
    Egrave = 0x00C8,
    Eacute = 0x00C9,
    Ecirc = 0x00CA,
    Euml = 0x00CB,
    Igrave = 0x00CC,
    Iacute = 0x00CD,
    Icirc = 0x00CE,
    Iuml = 0x00CF,
    ETH = 0x00D0,
    Ntilde = 0x00D1,
    Ograve = 0x00D2,
    Oacute = 0x00D3,
    Ocirc = 0x00D4,
    Otilde = 0x00D5,
    Ouml = 0x00D6,
    times = 0x00D7,
    Oslash = 0x00D8,
    Ugrave = 0x00D9,
    Uacute = 0x00DA,
    Ucirc = 0x00DB,
    Uuml = 0x00DC,
    Yacute = 0x00DD,
    THORN = 0x00DE,
    szlig = 0x00DF,
    agrave = 0x00E0,
    aacute = 0x00E1,
    acirc = 0x00E2,
    atilde = 0x00E3,
    auml = 0x00E4,
    aring = 0x00E5,
    aelig = 0x00E6,
    ccedil = 0x00E7,
    egrave = 0x00E8,
    eacute = 0x00E9,
    ecirc = 0x00EA,
    euml = 0x00EB,
    igrave = 0x00EC,
    iacute = 0x00ED,
    icirc = 0x00EE,
    iuml = 0x00EF,
    eth = 0x00F0,
    ntilde = 0x00F1,
    ograve = 0x00F2,
    oacute = 0x00F3,
    ocirc = 0x00F4,
    otilde = 0x00F5,
    ouml = 0x00F6,
    divide = 0x00F7,
    oslash = 0x00F8,
    ugrave = 0x00F9,
    uacute = 0x00FA,
    ucirc = 0x00FB,
    uuml = 0x00FC,
    yacute = 0x00FD,
    thorn = 0x00FE,
    yuml = 0x00FF,
    OElig = 0x0152,
    oelig = 0x0153,
    Scaron = 0x0160,
    scaron = 0x0161,
    Yuml = 0x0178,
    fnof = 0x0192,
    circ = 0x02C6,
    tilde = 0x02DC,
    Alpha = 0x0391,
    Beta = 0x0392,
    Gamma = 0x0393,
    Delta = 0x0394,
    Epsilon = 0x0395,
    Zeta = 0x0396,
    Eta = 0x0397,
    Theta = 0x0398,
    Iota = 0x0399,
    Kappa = 0x039A,
    Lambda = 0x039B,
    Mu = 0x039C,
    Nu = 0x039D,
    Xi = 0x039E,
    Omicron = 0x039F,
    Pi = 0x03A0,
    Rho = 0x03A1,
    Sigma = 0x03A3,
    Tau = 0x03A4,
    Upsilon = 0x03A5,
    Phi = 0x03A6,
    Chi = 0x03A7,
    Psi = 0x03A8,
    Omega = 0x03A9,
    alpha = 0x03B1,
    beta = 0x03B2,
    gamma = 0x03B3,
    delta = 0x03B4,
    epsilon = 0x03B5,
    zeta = 0x03B6,
    eta = 0x03B7,
    theta = 0x03B8,
    iota = 0x03B9,
    kappa = 0x03BA,
    lambda = 0x03BB,
    mu = 0x03BC,
    nu = 0x03BD,
    xi = 0x03BE,
    omicron = 0x03BF,
    pi = 0x03C0,
    rho = 0x03C1,
    sigmaf = 0x03C2,
    sigma = 0x03C3,
    tau = 0x03C4,
    upsilon = 0x03C5,
    phi = 0x03C6,
    chi = 0x03C7,
    psi = 0x03C8,
    omega = 0x03C9,
    thetasym = 0x03D1,
    upsih = 0x03D2,
    piv = 0x03D6,
    ensp = 0x2002,
    emsp = 0x2003,
    thinsp = 0x2009,
    zwnj = 0x200C,
    zwj = 0x200D,
    lrm = 0x200E,
    rlm = 0x200F,
    ndash = 0x2013,
    mdash = 0x2014,
    lsquo = 0x2018,
    rsquo = 0x2019,
    sbquo = 0x201A,
    ldquo = 0x201C,
    rdquo = 0x201D,
    bdquo = 0x201E,
    dagger = 0x2020,
    Dagger = 0x2021,
    bull = 0x2022,
    hellip = 0x2026,
    permil = 0x2030,
    prime = 0x2032,
    Prime = 0x2033,
    lsaquo = 0x2039,
    rsaquo = 0x203A,
    oline = 0x203E,
    frasl = 0x2044,
    euro = 0x20AC,
    image = 0x2111,
    weierp = 0x2118,
    real = 0x211C,
    trade = 0x2122,
    alefsym = 0x2135,
    larr = 0x2190,
    uarr = 0x2191,
    rarr = 0x2192,
    darr = 0x2193,
    harr = 0x2194,
    crarr = 0x21B5,
    lArr = 0x21D0,
    uArr = 0x21D1,
    rArr = 0x21D2,
    dArr = 0x21D3,
    hArr = 0x21D4,
    forall = 0x2200,
    part = 0x2202,
    exist = 0x2203,
    empty = 0x2205,
    nabla = 0x2207,
    isin = 0x2208,
    notin = 0x2209,
    ni = 0x220B,
    prod = 0x220F,
    sum = 0x2211,
    minus = 0x2212,
    lowast = 0x2217,
    radic = 0x221A,
    prop = 0x221D,
    infin = 0x221E,
    ang = 0x2220,
    ["and"] = 0x2227,
    ["or"] = 0x2228,
    cap = 0x2229,
    cup = 0x222A,
    int = 0x222B,
    there4 = 0x2234,
    sim = 0x223C,
    cong = 0x2245,
    asymp = 0x2248,
    ne = 0x2260,
    equiv = 0x2261,
    le = 0x2264,
    ge = 0x2265,
    sub = 0x2282,
    sup = 0x2283,
    nsub = 0x2284,
    sube = 0x2286,
    supe = 0x2287,
    oplus = 0x2295,
    otimes = 0x2297,
    perp = 0x22A5,
    sdot = 0x22C5,
    lceil = 0x2308,
    rceil = 0x2309,
    lfloor = 0x230A,
    rfloor = 0x230B,
    lang = 0x2329,
    rang = 0x232A,
    loz = 0x25CA,
    spades = 0x2660,
    clubs = 0x2663,
    hearts = 0x2665,
    diams = 0x2666,
}
