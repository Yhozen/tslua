local ast = require("tslua.ast")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SubtreeFacts = ast.SubtreeFacts
local TokenFlags = ast.TokenFlags
local AccessKind = ast.AccessKind
local JSDeclarationKind = ast.JSDeclarationKind

local Node = ast.Node
local NodeFactory = ast.NodeFactory

-- parseJSDocForNode is the package-level function for lazily parsing JSDoc.
-- It is set by the parser package.
ast.parseJSDocForNode = nil

-- SetParseJSDocForNode registers the lazy JSDoc parse function.
function ast.SetParseJSDocForNode(fn)
    ast.parseJSDocForNode = fn
end

-- Visitor

-- ast.Visitor is a plain function(node) -> bool.

function ast.visit(v, node)
    if node ~= nil then
        return v(node)
    end
    return false
end

function ast.visitNodes(v, nodes)
    if nodes == nil then
        return false
    end
    for i = 1, #nodes do
        if v(nodes[i]) then
            return true
        end
    end
    return false
end

function ast.visitNodeList(v, nodeList)
    if nodeList ~= nil then
        return ast.visitNodes(v, nodeList.nodes)
    end
    return false
end

function ast.visitModifiers(v, modifiers)
    if modifiers ~= nil then
        return ast.visitNodes(v, modifiers.nodes)
    end
    return false
end

-- NodeFactoryHooks is a plain table { onCreate = fn(node), onUpdate = fn(node, original),
-- onClone = fn(node, original) }; every hook is optional.

function ast.NewNodeFactory(hooks)
    return setmetatable({ hooks = hooks or {}, nodeCount = 0, textCount = 0 }, NodeFactory)
end

function ast.newNode(kind, data, hooks)
    local n = data
    n.loc = core.UndefinedTextRange()
    n.kind = kind
    if n.flags == nil then
        n.flags = 0
    end
    if hooks.onCreate ~= nil then
        hooks.onCreate(n)
    end
    return n
end

function NodeFactory:newNode(kind, data)
    self.nodeCount = self.nodeCount + 1
    return ast.newNode(kind, data, self.hooks)
end

function NodeFactory:NodeCount()
    return self.nodeCount
end

function NodeFactory:TextCount()
    return self.textCount
end

function NodeFactory:AsNodeFactory()
    return self
end

function ast.updateNode(updated, original, hooks)
    if updated ~= original then
        updated.flags = original.flags
        updated.loc = original.loc
        if hooks.onUpdate ~= nil then
            hooks.onUpdate(updated, original)
        end
    end
    return updated
end

function ast.cloneNode(updated, original, hooks)
    ast.updateNode(updated, original, hooks)
    if updated ~= original and hooks.onClone ~= nil then
        hooks.onClone(updated, original)
    end
    return updated
end

-- NodeList

local NodeList = {}
NodeList.__index = NodeList
NodeList.__name = "NodeList"
ast.NodeList = NodeList

function NodeFactory:NewNodeList(nodes)
    return setmetatable({ loc = core.UndefinedTextRange(), nodes = nodes }, NodeList)
end

function NodeList:Pos() return self.loc.pos end
function NodeList:End() return self.loc.end_ end

function NodeList:HasTrailingComma()
    local nodes = self.nodes
    if nodes == nil or #nodes == 0 then
        return false
    end
    local last = nodes[#nodes]
    return last:End() < self:End()
end

function NodeList:Clone(f)
    local result = f:AsNodeFactory():NewNodeList(self.nodes)
    result.loc = self.loc
    return result
end

-- ModifierList

local ModifierList = setmetatable({}, { __index = NodeList })
ModifierList.__index = ModifierList
ModifierList.__name = "ModifierList"
ast.ModifierList = ModifierList

function NodeFactory:NewModifierList(nodes)
    return setmetatable({
        loc = core.UndefinedTextRange(),
        nodes = nodes,
        modifierFlags = ast.ModifiersToFlags(nodes),
    }, ModifierList)
end

function ModifierList:Clone(f)
    return setmetatable({ loc = self.loc, nodes = self.nodes, modifierFlags = self.modifierFlags }, ModifierList)
end

-- AST Node
-- A node is a single flat table: kind, flags, loc, parent, id (lazily assigned) and the fields of
-- its Go data struct (see docs/AST.md). Its metatable is the method table of its data struct.

function Node:AsNode() return self end
function Node:Pos() return self.loc.pos end
function Node:End() return self.loc.end_ end

-- Go returns an iter.Seq; in Lua this returns an iterator for a generic for.
function Node:IterChildren()
    local children = {}
    self:ForEachChild(function(child)
        children[#children + 1] = child
        return false
    end)
    local i = 0
    return function()
        i = i + 1
        return children[i]
    end
end

-- Clone, VisitEachChild, Name, Modifiers, FlowNodeData, DeclarationData, ExportableData,
-- LocalsContainerData, FunctionLikeData, ClassLikeData, BodyData, SubtreeFacts,
-- propagateSubtreeFacts, LiteralLikeData, TemplateLiteralLikeData and ForEachChild forward to
-- the data struct in Go. In Lua the node is its own data, so those resolve directly through the
-- struct method table (NodeDefault provides the defaults).

function Node:ParameterList() return self:FunctionLikeData().parameters end
function Node:Parameters() return self:ParameterList().nodes end

function Node:KindString() return ast.Kind_String(self.kind) end
function Node:KindValue() return self.kind end

function Node:Decorators()
    if self:Modifiers() == nil then
        return nil
    end
    return core.Filter(self:Modifiers().nodes, ast.IsDecorator)
end

-- MutableNode: Go `(*MutableNode)(n)` is the node itself.
function Node:AsMutable() return self end
function Node:SetModifiers(modifiers) self:setModifiers(modifiers) end

function Node:Symbol()
    local data = self:DeclarationData()
    if data ~= nil then
        return data.symbol
    end
    return nil
end

function Node:LocalSymbol()
    local data = self:ExportableData()
    if data ~= nil then
        return data.localSymbol
    end
    return nil
end

function Node:Locals()
    local data = self:LocalsContainerData()
    if data ~= nil then
        return data.locals
    end
    return nil
end

function Node:Body()
    local data = self:BodyData()
    if data ~= nil then
        return data.body
    end
    return nil
end

local function kindSet(...)
    local s = {}
    for _, k in ipairs({ ... }) do
        s[k] = true
    end
    return s
end
ast.kindSet = kindSet

local function joinStrings(list)
    if list == nil then
        return ""
    end
    return table.concat(list, "")
end

local textFieldKinds = kindSet(Kind.Identifier, Kind.PrivateIdentifier, Kind.StringLiteral, Kind.NumericLiteral,
    Kind.BigIntLiteral, Kind.NoSubstitutionTemplateLiteral, Kind.TemplateHead, Kind.TemplateMiddle, Kind.TemplateTail,
    Kind.RegularExpressionLiteral)
local textListKinds = kindSet(Kind.JSDocText, Kind.JSDocLink, Kind.JSDocLinkCode, Kind.JSDocLinkPlain)

function Node:Text()
    local kind = self.kind
    if textFieldKinds[kind] then
        return self.text
    elseif kind == Kind.MetaProperty then
        return self:AsMetaProperty():Name():Text()
    elseif kind == Kind.JsxNamespacedName then
        return self.namespace:Text() .. ":" .. self.name:Text()
    elseif textListKinds[kind] then
        return joinStrings(self.text)
    end
    error("Unhandled case in Node.Text: " .. tostring(getmetatable(self) and getmetatable(self).__name))
end

local expressionKinds = kindSet(Kind.PropertyAccessExpression, Kind.ElementAccessExpression,
    Kind.ParenthesizedExpression, Kind.CallExpression, Kind.NewExpression, Kind.ExpressionWithTypeArguments,
    Kind.ComputedPropertyName, Kind.NonNullExpression, Kind.TypeAssertionExpression, Kind.AsExpression,
    Kind.SatisfiesExpression, Kind.TypeOfExpression, Kind.SpreadAssignment, Kind.SpreadElement, Kind.TemplateSpan,
    Kind.DeleteExpression, Kind.VoidExpression, Kind.AwaitExpression, Kind.YieldExpression,
    Kind.PartiallyEmittedExpression, Kind.IfStatement, Kind.DoStatement, Kind.WhileStatement, Kind.WithStatement,
    Kind.ForInStatement, Kind.ForOfStatement, Kind.SwitchStatement, Kind.CaseClause, Kind.ExpressionStatement,
    Kind.ReturnStatement, Kind.ThrowStatement, Kind.ExternalModuleReference, Kind.ExportAssignment, Kind.Decorator,
    Kind.JsxExpression, Kind.JsxSpreadAttribute)

function Node:Expression()
    if expressionKinds[self.kind] then
        return self.expression
    end
    error("Unhandled case in Node.Expression: " .. ast.Kind_String(self.kind))
end

local rawTextKinds = kindSet(Kind.TemplateHead, Kind.TemplateMiddle, Kind.TemplateTail)

function Node:RawText()
    if rawTextKinds[self.kind] then
        return self.rawText
    end
    error("Unhandled case in Node.RawText: " .. ast.Kind_String(self.kind))
end

function Node:SetExpression(expr)
    if expressionKinds[self.kind] then
        self.expression = expr
    else
        error("Unhandled case in mutableNode.SetExpression: " .. ast.Kind_String(self.kind))
    end
end

local callOrNewKinds = kindSet(Kind.CallExpression, Kind.NewExpression)

function Node:ArgumentList()
    if callOrNewKinds[self.kind] then
        return self.arguments
    end
    error("Unhandled case in Node.Arguments: " .. ast.Kind_String(self.kind))
end

function Node:Arguments()
    local list = self:ArgumentList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local typeArgumentKinds = kindSet(Kind.CallExpression, Kind.NewExpression, Kind.TaggedTemplateExpression,
    Kind.TypeReference, Kind.ExpressionWithTypeArguments, Kind.ImportType, Kind.TypeQuery, Kind.JsxOpeningElement,
    Kind.JsxSelfClosingElement)

function Node:TypeArgumentList()
    if typeArgumentKinds[self.kind] then
        return self.typeArguments
    end
    error("Unhandled case in Node.TypeArguments")
end

function Node:TypeArguments()
    local list = self:TypeArgumentList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local typeParameterKinds = kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.JSDocTemplateTag)

function Node:TypeParameterList()
    if typeParameterKinds[self.kind] then
        return self.typeParameters
    end
    local funcLike = self:FunctionLikeData()
    if funcLike ~= nil then
        return funcLike.typeParameters
    end
    error("Unhandled case in Node.TypeParameterList")
end

function Node:TypeParameters()
    local list = self:TypeParameterList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local memberKinds = kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.EnumDeclaration, Kind.TypeLiteral, Kind.MappedType)

function Node:MemberList()
    if memberKinds[self.kind] then
        return self.members
    end
    error("Unhandled case in Node.MemberList: " .. ast.Kind_String(self.kind))
end

function Node:Members()
    local list = self:MemberList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local statementListKinds = kindSet(Kind.SourceFile, Kind.Block, Kind.ModuleBlock, Kind.CaseClause, Kind.DefaultClause)

function Node:StatementList()
    if statementListKinds[self.kind] then
        return self.statements
    end
    error("Unhandled case in Node.StatementList: " .. ast.Kind_String(self.kind))
end

function Node:Statements()
    local list = self:StatementList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

function Node:CanHaveStatements()
    return statementListKinds[self.kind] == true
end

function Node:ModifierFlags()
    local modifiers = self:Modifiers()
    if modifiers ~= nil then
        return modifiers.modifierFlags
    end
    return ModifierFlags.None
end

function Node:ModifierNodes()
    local modifiers = self:Modifiers()
    if modifiers ~= nil then
        return modifiers.nodes
    end
    return nil
end

local typeKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.PropertySignature, Kind.PropertyDeclaration,
    Kind.PropertyAssignment, Kind.ShorthandPropertyAssignment, Kind.TypePredicate, Kind.ParenthesizedType,
    Kind.TypeOperator, Kind.MappedType, Kind.TypeAssertionExpression, Kind.AsExpression, Kind.SatisfiesExpression,
    Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.NamedTupleMember, Kind.OptionalType, Kind.RestType,
    Kind.TemplateLiteralTypeSpan, Kind.JSDocTypeExpression, Kind.JSDocNullableType, Kind.JSDocNonNullableType,
    Kind.JSDocOptionalType, Kind.ExportAssignment, Kind.BinaryExpression)
local jsdocParameterOrPropertyTagKinds = kindSet(Kind.JSDocParameterTag, Kind.JSDocPropertyTag)

function Node:Type()
    local kind = self.kind
    if typeKinds[kind] then
        return self.type
    elseif jsdocParameterOrPropertyTagKinds[kind] then
        return self.typeExpression
    end
    local funcLike = self:FunctionLikeData()
    if funcLike ~= nil then
        return funcLike.type
    end
    return nil
end

function Node:SetType(t)
    local kind = self.kind
    if typeKinds[kind] then
        self.type = t
    elseif jsdocParameterOrPropertyTagKinds[kind] then
        self.typeExpression = t
    else
        local funcLike = self:FunctionLikeData()
        if funcLike ~= nil then
            funcLike.type = t
        else
            error("Unhandled case in mutableNode.SetType: " .. ast.Kind_String(kind))
        end
    end
end

local initializerKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.BindingElement,
    Kind.PropertyDeclaration, Kind.PropertySignature, Kind.PropertyAssignment, Kind.EnumMember, Kind.ForStatement,
    Kind.ForInStatement, Kind.ForOfStatement, Kind.JsxAttribute)

function Node:Initializer()
    if initializerKinds[self.kind] then
        return self.initializer
    end
    error("Unhandled case in Node.Initializer")
end

function Node:SetInitializer(initializer)
    if initializerKinds[self.kind] then
        self.initializer = initializer
    else
        error("Unhandled case in mutableNode.SetInitializer")
    end
end

local tagNameKinds = kindSet(Kind.JsxOpeningElement, Kind.JsxClosingElement, Kind.JsxSelfClosingElement,
    Kind.JSDocUnknownTag, Kind.JSDocAugmentsTag, Kind.JSDocImplementsTag, Kind.JSDocDeprecatedTag,
    Kind.JSDocPublicTag, Kind.JSDocPrivateTag, Kind.JSDocProtectedTag, Kind.JSDocReadonlyTag, Kind.JSDocOverrideTag,
    Kind.JSDocCallbackTag, Kind.JSDocOverloadTag, Kind.JSDocParameterTag, Kind.JSDocPropertyTag, Kind.JSDocReturnTag,
    Kind.JSDocThisTag, Kind.JSDocTypeTag, Kind.JSDocTemplateTag, Kind.JSDocTypedefTag, Kind.JSDocSeeTag,
    Kind.JSDocSatisfiesTag, Kind.JSDocThrowsTag, Kind.JSDocImportTag)

function Node:TagName()
    if tagNameKinds[self.kind] then
        return self.tagName
    end
    error("Unhandled case in Node.TagName: " .. ast.Kind_String(self.kind))
end

local propertyNameKinds = kindSet(Kind.ImportSpecifier, Kind.ExportSpecifier, Kind.BindingElement)

function Node:PropertyName()
    if propertyNameKinds[self.kind] then
        return self.propertyName
    end
    return nil
end

function Node:PropertyNameOrName()
    local name = self:PropertyName()
    if name == nil then
        name = self:Name()
    end
    return name
end

function Node:IsTypeOnly()
    local kind = self.kind
    if kind == Kind.ImportEqualsDeclaration or kind == Kind.ImportSpecifier or kind == Kind.ExportDeclaration or
        kind == Kind.ExportSpecifier then
        return self.isTypeOnly
    elseif kind == Kind.ImportClause then
        return self.phaseModifier == Kind.TypeKeyword
    end
    return false
end

local commentListKinds = kindSet(Kind.JSDoc, Kind.JSDocUnknownTag, Kind.JSDocAugmentsTag, Kind.JSDocImplementsTag,
    Kind.JSDocDeprecatedTag, Kind.JSDocPublicTag, Kind.JSDocPrivateTag, Kind.JSDocProtectedTag, Kind.JSDocReadonlyTag,
    Kind.JSDocOverrideTag, Kind.JSDocCallbackTag, Kind.JSDocOverloadTag, Kind.JSDocParameterTag,
    Kind.JSDocPropertyTag, Kind.JSDocReturnTag, Kind.JSDocThisTag, Kind.JSDocTypeTag, Kind.JSDocTemplateTag,
    Kind.JSDocTypedefTag, Kind.JSDocSeeTag, Kind.JSDocSatisfiesTag, Kind.JSDocThrowsTag, Kind.JSDocImportTag)

-- If updating this function, also update `hasComment`.
function Node:CommentList()
    if commentListKinds[self.kind] then
        return self.comment
    end
    error("Unhandled case in Node.CommentList: " .. ast.Kind_String(self.kind))
end

function Node:Comments()
    local list = self:CommentList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local labelKinds = kindSet(Kind.LabeledStatement, Kind.BreakStatement, Kind.ContinueStatement)

function Node:Label()
    if labelKinds[self.kind] then
        return self.label
    end
    error("Unhandled case in Node.Label: " .. ast.Kind_String(self.kind))
end

local jsxOpeningLikeKinds = kindSet(Kind.JsxOpeningElement, Kind.JsxSelfClosingElement)

function Node:Attributes()
    if jsxOpeningLikeKinds[self.kind] then
        return self.attributes
    end
    error("Unhandled case in Node.Attributes: " .. ast.Kind_String(self.kind))
end

local jsxChildrenKinds = kindSet(Kind.JsxElement, Kind.JsxFragment)

function Node:Children()
    if jsxChildrenKinds[self.kind] then
        return self.children
    end
    error("Unhandled case in Node.Children: " .. ast.Kind_String(self.kind))
end

local moduleSpecifierKinds = kindSet(Kind.ImportDeclaration, Kind.JSImportDeclaration, Kind.ExportDeclaration,
    Kind.JSDocImportTag)

function Node:ModuleSpecifier()
    if moduleSpecifierKinds[self.kind] then
        return self.moduleSpecifier
    end
    error("Unhandled case in Node.ModuleSpecifier: " .. ast.Kind_String(self.kind))
end

local importClauseKinds = kindSet(Kind.ImportDeclaration, Kind.JSImportDeclaration, Kind.JSDocImportTag)

function Node:ImportClause()
    if importClauseKinds[self.kind] then
        return self.importClause
    end
    error("Unhandled case in Node.ImportClause: " .. ast.Kind_String(self.kind))
end

local statementKinds = kindSet(Kind.DoStatement, Kind.WhileStatement, Kind.ForStatement, Kind.ForInStatement,
    Kind.ForOfStatement, Kind.WithStatement, Kind.LabeledStatement)

function Node:Statement()
    if statementKinds[self.kind] then
        return self.statement
    end
    error("Unhandled case in Node.Statement: " .. ast.Kind_String(self.kind))
end

local propertyListKinds = kindSet(Kind.ObjectLiteralExpression, Kind.JsxAttributes)

function Node:PropertyList()
    if propertyListKinds[self.kind] then
        return self.properties
    end
    error("Unhandled case in Node.PropertyList: " .. ast.Kind_String(self.kind))
end

function Node:Properties()
    local list = self:PropertyList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local elementListKinds = kindSet(Kind.NamedImports, Kind.NamedExports, Kind.ObjectBindingPattern,
    Kind.ArrayBindingPattern, Kind.ArrayLiteralExpression, Kind.TupleType)

function Node:ElementList()
    if elementListKinds[self.kind] then
        return self.elements
    end
    error("Unhandled case in Node.ElementList: " .. ast.Kind_String(self.kind))
end

function Node:Elements()
    local list = self:ElementList()
    if list ~= nil then
        return list.nodes
    end
    return nil
end

local postfixTokenKinds = kindSet(Kind.MethodDeclaration, Kind.ShorthandPropertyAssignment, Kind.MethodSignature,
    Kind.PropertySignature, Kind.PropertyAssignment, Kind.PropertyDeclaration, Kind.EnumMember, Kind.GetAccessor,
    Kind.SetAccessor)

function Node:PostfixToken()
    if postfixTokenKinds[self.kind] then
        return self.postfixToken
    end
    return nil
end

local questionTokenKinds = kindSet(Kind.Parameter, Kind.ConditionalExpression, Kind.MappedType, Kind.NamedTupleMember)

function Node:QuestionToken()
    if questionTokenKinds[self.kind] then
        return self.questionToken
    end
    local postfix = self:PostfixToken()
    if postfix ~= nil and postfix.kind == Kind.QuestionToken then
        return postfix
    end
    return nil
end

local questionDotTokenKinds = kindSet(Kind.ElementAccessExpression, Kind.PropertyAccessExpression,
    Kind.CallExpression, Kind.TaggedTemplateExpression)

function Node:QuestionDotToken()
    if questionDotTokenKinds[self.kind] then
        return self.questionDotToken
    end
    error("Unhandled case in Node.QuestionDotToken: " .. ast.Kind_String(self.kind))
end

local typeExpressionKinds = kindSet(Kind.JSDocParameterTag, Kind.JSDocPropertyTag, Kind.JSDocReturnTag,
    Kind.JSDocTypeTag, Kind.JSDocTypedefTag, Kind.JSDocCallbackTag, Kind.JSDocSatisfiesTag, Kind.JSDocThrowsTag)

function Node:TypeExpression()
    if typeExpressionKinds[self.kind] then
        return self.typeExpression
    end
    error("Unhandled case in Node.TypeExpression: " .. ast.Kind_String(self.kind))
end

local classNameKinds = kindSet(Kind.JSDocAugmentsTag, Kind.JSDocImplementsTag)

function Node:ClassName()
    if classNameKinds[self.kind] then
        return self.className
    end
    error("Unhandled case in Node.ClassName: " .. ast.Kind_String(self.kind))
end

-- Determines if `n` contains `descendant` by walking up the `Parent` pointers from `descendant`. This method panics if
-- `descendant` or one of its ancestors is not parented except when that node is a `SourceFile`.
function Node:Contains(descendant)
    while descendant ~= nil do
        if descendant == self then
            return true
        end
        local parent = descendant.parent
        if parent == nil and not ast.IsSourceFile(descendant) then
            error("descendant is not parented")
        end
        descendant = parent
    end
    return false
end

-- Node casts

function Node:AsFlowSwitchClauseData()
    if getmetatable(self) ~= ast.FlowSwitchClauseData then
        ast.badCast(self, "FlowSwitchClauseData")
    end
    return self
end

function Node:AsFlowReduceLabelData()
    if getmetatable(self) ~= ast.FlowReduceLabelData then
        ast.badCast(self, "FlowReduceLabelData")
    end
    return self
end

-- NodeDefault

local NodeDefault = ast.DefineStruct("NodeDefault", { "Node" })

function NodeDefault:AsNode() return self end
function NodeDefault:ForEachChild(v) return false end
function NodeDefault:VisitEachChild(v) return self end
function NodeDefault:Clone(v) return nil end
function NodeDefault:Name() return nil end
function NodeDefault:Modifiers() return nil end
function NodeDefault:setModifiers(modifiers) end
function NodeDefault:FlowNodeData() return nil end
function NodeDefault:DeclarationData() return nil end
function NodeDefault:ExportableData() return nil end
function NodeDefault:LocalsContainerData() return nil end
function NodeDefault:FunctionLikeData() return nil end
function NodeDefault:ClassLikeData() return nil end
function NodeDefault:BodyData() return nil end
function NodeDefault:LiteralLikeData() return nil end
function NodeDefault:TemplateLiteralLikeData() return nil end

function NodeDefault:SubtreeFacts()
    return self:subtreeFactsWorker(self)
end

function NodeDefault:subtreeFactsWorker(self_)
    -- To avoid excessive conditional checks, the default implementation of subtreeFactsWorker directly invokes
    -- computeSubtreeFacts. More complex nodes should implement CompositeNodeBase, which overrides this
    -- method to cache the result.
    return self_:computeSubtreeFacts()
end

function NodeDefault:computeSubtreeFacts()
    return SubtreeFacts.None
end

function NodeDefault:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsNode
end

-- NodeBase

ast.DefineStruct("NodeBase", { "NodeDefault" })

function ast.IsWriteOnlyAccess(node)
    return ast.accessKind(node) == AccessKind.Write
end

function ast.IsWriteAccess(node)
    return ast.accessKind(node) ~= AccessKind.Read
end

function ast.IsWriteAccessForReference(node)
    local decl = ast.GetDeclarationFromName(node)
    return (decl ~= nil and ast.declarationIsWriteAccess(decl)) or node.kind == Kind.DefaultKeyword or
        ast.IsWriteAccess(node)
end

function ast.GetDeclarationFromName(name)
    if name == nil or name.parent == nil then
        return nil
    end
    local parent = name.parent
    local kind = name.kind
    if kind == Kind.StringLiteral or kind == Kind.NoSubstitutionTemplateLiteral or kind == Kind.NumericLiteral or
        kind == Kind.Identifier then
        if kind ~= Kind.Identifier then
            if ast.IsComputedPropertyName(parent) then
                return parent.parent
            end
        end
        -- fallthrough
        if ast.IsDeclaration(parent) then
            if parent:Name() == name then
                return parent
            end
            return nil
        end
        if ast.IsQualifiedName(parent) then
            local tag = parent.parent
            if ast.IsJSDocParameterTag(tag) and tag:Name() == parent then
                return tag
            end
            return nil
        end
        local binExp = parent.parent
        if ast.IsBinaryExpression(binExp) and ast.GetAssignmentDeclarationKind(binExp) ~= JSDeclarationKind.None then
            -- (binExp.left as BindableStaticNameExpression).symbol || binExp.symbol
            local leftHasSymbol = false
            if binExp.left ~= nil and binExp.left:Symbol() ~= nil then
                leftHasSymbol = true
            end
            if leftHasSymbol or binExp:Symbol() ~= nil then
                if ast.GetNameOfDeclaration(binExp) == name then
                    return binExp
                end
            end
        end
    elseif kind == Kind.PrivateIdentifier then
        if ast.IsDeclaration(parent) and parent:Name() == name then
            return parent
        end
    end
    return nil
end

local writeAccessDeclarationKinds = kindSet(Kind.BinaryExpression, Kind.BindingElement, Kind.ClassDeclaration,
    Kind.ClassExpression, Kind.DefaultKeyword, Kind.EnumDeclaration, Kind.EnumMember, Kind.ExportSpecifier,
    Kind.ImportClause, Kind.ImportEqualsDeclaration, Kind.ImportSpecifier, Kind.InterfaceDeclaration,
    Kind.JSDocCallbackTag, Kind.JSDocTypedefTag, Kind.JsxAttribute, Kind.ModuleDeclaration,
    Kind.NamespaceExportDeclaration, Kind.NamespaceImport, Kind.NamespaceExport, Kind.Parameter,
    Kind.ShorthandPropertyAssignment, Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.TypeParameter)
local functionWithBodyKinds = kindSet(Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.Constructor,
    Kind.MethodDeclaration, Kind.GetAccessor, Kind.SetAccessor)

function ast.declarationIsWriteAccess(decl)
    if decl == nil then
        return false
    end
    -- Consider anything in an ambient declaration to be a write access since it may be coming from JS.
    if decl.flags & NodeFlags.Ambient ~= 0 then
        return true
    end

    local kind = decl.kind
    if writeAccessDeclarationKinds[kind] then
        return true
    elseif kind == Kind.PropertyAssignment then
        -- In `({ x: y } = 0);`, `x` is not a write access.
        return not ast.IsArrayLiteralOrObjectLiteralDestructuringPattern(decl.parent)
    elseif functionWithBodyKinds[kind] then
        -- functions considered write if they provide a value (have a body)
        return decl.body ~= nil
    elseif kind == Kind.VariableDeclaration or kind == Kind.PropertyDeclaration then
        -- variable/property write if initializer present or is in catch clause
        local hasInit = decl.initializer ~= nil
        return hasInit or ast.IsCatchClause(decl.parent)
    elseif kind == Kind.MethodSignature or kind == Kind.PropertySignature or kind == Kind.JSDocPropertyTag or
        kind == Kind.JSDocParameterTag then
        return false
    end
    -- preserve TS behavior: crash on unexpected kinds
    error("Unhandled case in declarationIsWriteAccess")
end

function ast.IsArrayLiteralOrObjectLiteralDestructuringPattern(node)
    if not (ast.IsArrayLiteralExpression(node) or ast.IsObjectLiteralExpression(node)) then
        return false
    end
    local parent = node.parent
    -- [a,b,c] from:
    -- [a, b, c] = someExpression;
    if ast.IsBinaryExpression(parent) and parent.left == node and parent.operatorToken.kind == Kind.EqualsToken then
        return true
    end
    -- [a, b, c] from:
    -- for([a, b, c] of expression)
    if ast.IsForOfStatement(parent) and parent:Initializer() == node then
        return true
    end
    -- {x, a: {a, b, c} } = someExpression
    if ast.IsPropertyAssignment(parent) then
        return ast.IsArrayLiteralOrObjectLiteralDestructuringPattern(parent.parent)
    end
    -- [a, b, c] of
    -- [x, [a, b, c] ] = someExpression
    return ast.IsArrayLiteralOrObjectLiteralDestructuringPattern(parent)
end

function ast.accessKind(node)
    local parent = node.parent
    if parent == nil then
        return AccessKind.Read
    end
    local kind = parent.kind
    if kind == Kind.ParenthesizedExpression then
        return ast.accessKind(parent)
    elseif kind == Kind.PrefixUnaryExpression or kind == Kind.PostfixUnaryExpression then
        local operator = parent.operator
        if operator == Kind.PlusPlusToken or operator == Kind.MinusMinusToken then
            return AccessKind.ReadWrite
        end
        return AccessKind.Read
    elseif kind == Kind.BinaryExpression then
        if parent.left == node then
            local operator = parent.operatorToken
            if ast.IsAssignmentOperator(operator.kind) then
                if operator.kind == Kind.EqualsToken then
                    return AccessKind.Write
                end
                return AccessKind.ReadWrite
            end
        end
        return AccessKind.Read
    elseif kind == Kind.PropertyAccessExpression then
        if parent:Name() ~= node then
            return AccessKind.Read
        end
        return ast.accessKind(parent)
    elseif kind == Kind.PropertyAssignment then
        local parentAccess = ast.accessKind(parent.parent)
        -- In `({ x: varname }) = { x: 1 }`, the left `x` is a read, the right `x` is a write.
        if node == parent:Name() then
            return ast.reverseAccessKind(parentAccess)
        end
        return parentAccess
    elseif kind == Kind.ShorthandPropertyAssignment then
        -- Assume it's the local variable being accessed, since we don't check public properties for --noUnusedLocals.
        if node == parent.objectAssignmentInitializer then
            return AccessKind.Read
        end
        return ast.accessKind(parent.parent)
    elseif kind == Kind.ArrayLiteralExpression then
        return ast.accessKind(parent)
    elseif kind == Kind.ForInStatement or kind == Kind.ForOfStatement then
        if node == parent.initializer then
            return AccessKind.Write
        end
        return AccessKind.Read
    end
    return AccessKind.Read
end

function ast.reverseAccessKind(a)
    if a == AccessKind.Read then
        return AccessKind.Write
    elseif a == AccessKind.Write then
        return AccessKind.Read
    elseif a == AccessKind.ReadWrite then
        return AccessKind.ReadWrite
    end
    error("Unhandled case in reverseAccessKind")
end

-- DeclarationBase

function ast.DeclarationBase:DeclarationData() return self end

function ast.IsDeclarationNode(node)
    return node:DeclarationData() ~= nil
end

-- ExportableBase

function ast.ExportableBase:ExportableData() return self end

-- ModifiersBase

function ast.ModifiersBase:Modifiers() return self.modifiers end
function ast.ModifiersBase:setModifiers(modifiers) self.modifiers = modifiers end

-- LocalsContainerBase

function ast.LocalsContainerBase:LocalsContainerData() return self end

function ast.IsLocalsContainer(node)
    return node:LocalsContainerData() ~= nil
end

-- FunctionLikeBase

function ast.FunctionLikeBase:LocalsContainerData() return self end
function ast.FunctionLikeBase:FunctionLikeData() return self end

-- BodyBase

function ast.BodyBase:BodyData() return self end

-- FunctionLikeWithBodyBase

function ast.FunctionLikeWithBodyBase:LocalsContainerData() return self end
function ast.FunctionLikeWithBodyBase:FunctionLikeData() return self end
function ast.FunctionLikeWithBodyBase:BodyData() return self end

-- FlowNodeBase

function ast.FlowNodeBase:FlowNodeData() return self end

-- if you provide nil for file, this code will walk to the root of the tree to find the file
function Node:JSDoc(file)
    if self.flags & NodeFlags.HasJSDoc == 0 then
        return nil
    end
    if file == nil then
        file = ast.GetSourceFileOfNode(self)
        if file == nil then
            return nil
        end
    end
    if file.hasLazyJSDoc then
        return file:resolveJSDoc(self)
    end
    local cache = file.jsdocCache
    return cache and cache[self]
end

-- EagerJSDoc returns JSDoc nodes that have already been parsed and cached,
-- without triggering lazy JSDoc parsing.
function Node:EagerJSDoc(file)
    if self.flags & NodeFlags.HasJSDoc == 0 then
        return nil
    end
    if file == nil then
        file = ast.GetSourceFileOfNode(self)
        if file == nil then
            return nil
        end
    end
    local cache = file.jsdocCache
    return cache and cache[self]
end

-- CompositeBase

function ast.CompositeBase:subtreeFactsWorker(self_)
    -- computeSubtreeFacts() is expected to be idempotent.
    local facts = self.facts
    if facts & SubtreeFacts.Computed == 0 then
        facts = facts | self_:computeSubtreeFacts() | SubtreeFacts.Computed
        self.facts = facts
    end
    return facts & ~SubtreeFacts.Computed
end

function ast.CompositeBase:computeSubtreeFacts()
    -- This method must be implemented by the concrete node type.
    error("not implemented")
end

-- TypeSyntaxBase

function ast.TypeSyntaxBase:computeSubtreeFacts() return SubtreeFacts.SubtreeContainsTypeScript end

function ast.TypeSyntaxBase:propagateSubtreeFacts() return SubtreeFacts.SubtreeContainsTypeScript end

local tokenTypeScriptKinds = kindSet(Kind.PublicKeyword, Kind.PrivateKeyword, Kind.ProtectedKeyword,
    Kind.ReadonlyKeyword, Kind.AbstractKeyword, Kind.DeclareKeyword, Kind.ConstKeyword, Kind.AnyKeyword,
    Kind.NumberKeyword, Kind.BigIntKeyword, Kind.NeverKeyword, Kind.ObjectKeyword, Kind.InKeyword, Kind.OutKeyword,
    Kind.OverrideKeyword, Kind.StringKeyword, Kind.BooleanKeyword, Kind.SymbolKeyword, Kind.VoidKeyword,
    Kind.UnknownKeyword, Kind.UndefinedKeyword, Kind.ExportKeyword)

function ast.Token:computeSubtreeFacts()
    local kind = self.kind
    if kind == Kind.UsingKeyword then
        return SubtreeFacts.SubtreeContainsUsing
    elseif tokenTypeScriptKinds[kind] then
        return SubtreeFacts.SubtreeContainsTypeScript
    elseif kind == Kind.AccessorKeyword then
        return SubtreeFacts.SubtreeContainsClassFields
    elseif kind == Kind.AsyncKeyword then
        return SubtreeFacts.SubtreeContainsAnyAwait
    elseif kind == Kind.SuperKeyword then
        return SubtreeFacts.SubtreeContainsLexicalSuper
    elseif kind == Kind.ThisKeyword then
        return SubtreeFacts.SubtreeContainsLexicalThis
    elseif kind == Kind.AsteriskAsteriskToken or kind == Kind.AsteriskAsteriskEqualsToken then
        return SubtreeFacts.SubtreeContainsExponentiationOperator
    elseif kind == Kind.QuestionQuestionToken then
        return SubtreeFacts.SubtreeContainsNullishCoalescing
    elseif kind == Kind.QuestionDotToken then
        return SubtreeFacts.SubtreeContainsOptionalChaining
    elseif kind == Kind.QuestionQuestionEqualsToken or kind == Kind.BarBarEqualsToken or
        kind == Kind.AmpersandAmpersandEqualsToken then
        return SubtreeFacts.SubtreeContainsLogicalAssignments
    end
    return SubtreeFacts.None
end

function ast.PrivateIdentifier:computeSubtreeFacts()
    return SubtreeFacts.SubtreeContainsClassFields
end

function NodeFactory:NewModifier(kind)
    return self:NewToken(kind)
end

local None = SubtreeFacts.None

function ast.Decorator:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) |
        SubtreeFacts.SubtreeContainsTypeScript |
        SubtreeFacts.SubtreeContainsDecorators
end

function ast.ForInOrOfStatement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.initializer) |
        ast.propagateSubtreeFacts(self.expression) |
        ast.propagateSubtreeFacts(self.statement) |
        (self.awaitModifier ~= nil and SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator or None)
end

function ast.ReturnStatement:computeSubtreeFacts()
    -- return in an ES2018 async generator must be awaited
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator
end

function ast.CatchClause:computeSubtreeFacts()
    local res = ast.propagateSubtreeFacts(self.variableDeclaration) |
        ast.propagateSubtreeFacts(self.block)
    if self.variableDeclaration == nil then
        res = res | SubtreeFacts.SubtreeContainsMissingCatchClauseVariable
    end
    return res
end

function ast.CatchClause:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsCatchClause
end

function ast.VariableStatement:computeSubtreeFacts()
    if self.modifiers ~= nil and self.modifiers.modifierFlags & ModifierFlags.Ambient ~= 0 then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.declarationList)
    end
end

function ast.VariableDeclaration:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.name) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.exclamationToken) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
        ast.propagateSubtreeFacts(self.initializer)
end

function ast.VariableDeclarationList:computeSubtreeFacts()
    return ast.propagateNodeListSubtreeFacts(self.declarations, ast.propagateSubtreeFacts) |
        (self.flags & NodeFlags.Using ~= 0 and SubtreeFacts.SubtreeContainsUsing or None)
end

function ast.VariableDeclarationList:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsVariableDeclarationList
end

function ast.BindingPattern:computeSubtreeFacts()
    if self.kind == Kind.ObjectBindingPattern then
        return ast.propagateNodeListSubtreeFacts(self.elements, ast.propagateObjectBindingElementSubtreeFacts)
    elseif self.kind == Kind.ArrayBindingPattern then
        return ast.propagateNodeListSubtreeFacts(self.elements, ast.propagateBindingElementSubtreeFacts)
    end
    return None
end

function ast.BindingPattern:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsBindingPattern
end

function ast.ParameterDeclaration:computeSubtreeFacts()
    if self.name ~= nil and ast.IsThisIdentifier(self.name) then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.questionToken) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
            ast.propagateSubtreeFacts(self.initializer)
    end
end

function ast.ParameterDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsParameter
end

function ast.BindingElement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.propertyName) |
        ast.propagateSubtreeFacts(self.name) |
        ast.propagateSubtreeFacts(self.initializer) |
        (self.dotDotDotToken ~= nil and SubtreeFacts.SubtreeContainsRestOrSpread or None)
end

function ast.FunctionDeclaration:computeSubtreeFacts()
    if self.body == nil or self:ModifierFlags() & ModifierFlags.Ambient ~= 0 then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        local isAsync = self:ModifierFlags() & ModifierFlags.Async ~= 0
        local isGenerator = self.asteriskToken ~= nil
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.asteriskToken) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
            ast.propagateNodeListSubtreeFacts(self.parameters, ast.propagateSubtreeFacts) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.fullSignature) |
            ast.propagateSubtreeFacts(self.body) |
            ((isAsync and isGenerator) and SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator or None) |
            ((isAsync and not isGenerator) and SubtreeFacts.SubtreeContainsAnyAwait or None)
    end
end

function ast.FunctionDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsFunction
end

-- ClassLikeBase

function ast.ClassLikeBase:Name() return self.name end

function ast.ClassLikeBase:ClassLikeData() return self end

function ast.ClassLikeBase:computeSubtreeFacts()
    if self.modifiers ~= nil and self.modifiers.modifierFlags & ModifierFlags.Ambient ~= 0 then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
            ast.propagateNodeListSubtreeFacts(self.heritageClauses, ast.propagateSubtreeFacts) |
            ast.propagateNodeListSubtreeFacts(self.members, ast.propagateSubtreeFacts)
    end
end

function ast.ClassDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsClass
end

function ast.ClassExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsClass
end

function ast.HeritageClause:computeSubtreeFacts()
    if self.token == Kind.ExtendsKeyword then
        return ast.propagateNodeListSubtreeFacts(self.types, ast.propagateSubtreeFacts)
    elseif self.token == Kind.ImplementsKeyword then
        return SubtreeFacts.SubtreeContainsTypeScript
    end
    return None
end

function ast.IsTypeOrJSTypeAliasDeclaration(node)
    return node.kind == Kind.TypeAliasDeclaration or node.kind == Kind.JSTypeAliasDeclaration
end

function ast.EnumMember:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.name) |
        ast.propagateSubtreeFacts(self.initializer) |
        SubtreeFacts.SubtreeContainsTypeScript
end

function ast.EnumDeclaration:computeSubtreeFacts()
    if self.modifiers ~= nil and self.modifiers.modifierFlags & ModifierFlags.Ambient ~= 0 then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateNodeListSubtreeFacts(self.members, ast.propagateSubtreeFacts) |
            SubtreeFacts.SubtreeContainsTypeScript
    end
end

function ast.ModuleDeclaration:computeSubtreeFacts()
    if self:ModifierFlags() & ModifierFlags.Ambient ~= 0 then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateSubtreeFacts(self.body) |
            SubtreeFacts.SubtreeContainsTypeScript
    end
end

function ast.ModuleDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsModule
end

function ast.ImportEqualsDeclaration:computeSubtreeFacts()
    if self.isTypeOnly or not ast.IsExternalModuleReference(self.moduleReference) then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateSubtreeFacts(self.moduleReference)
    end
end

function ast.IsImportDeclarationOrJSImportDeclaration(node)
    return node.kind == Kind.ImportDeclaration or node.kind == Kind.JSImportDeclaration
end

function ast.ImportSpecifier:computeSubtreeFacts()
    if self.isTypeOnly then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateSubtreeFacts(self.propertyName) |
            ast.propagateSubtreeFacts(self.name)
    end
end

function ast.ImportClause:computeSubtreeFacts()
    if self.phaseModifier == Kind.TypeKeyword then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateSubtreeFacts(self.name) |
            ast.propagateSubtreeFacts(self.namedBindings)
    end
end

function ast.ExportAssignment:computeSubtreeFacts()
    return ast.propagateModifierListSubtreeFacts(self.modifiers) | ast.propagateSubtreeFacts(self.type) |
        ast.propagateSubtreeFacts(self.expression) |
        (self.isExportEquals and SubtreeFacts.SubtreeContainsTypeScript or None)
end

function ast.IsAnyExportAssignment(node)
    return node.kind == Kind.ExportAssignment
end

function ast.ExportDeclaration:computeSubtreeFacts()
    return ast.propagateModifierListSubtreeFacts(self.modifiers) |
        ast.propagateSubtreeFacts(self.exportClause) |
        ast.propagateSubtreeFacts(self.moduleSpecifier) |
        ast.propagateSubtreeFacts(self.attributes) |
        (self.isTypeOnly and SubtreeFacts.SubtreeContainsTypeScript or None)
end

function ast.ExportSpecifier:computeSubtreeFacts()
    if self.isTypeOnly then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateSubtreeFacts(self.propertyName) |
            ast.propagateSubtreeFacts(self.name)
    end
end

-- NamedMemberBase

function ast.NamedMemberBase:Modifiers() return self.modifiers end
function ast.NamedMemberBase:setModifiers(modifiers) self.modifiers = modifiers end
function ast.NamedMemberBase:Name() return self.name end

function ast.ConstructorDeclaration:computeSubtreeFacts()
    if self.body == nil then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
            ast.propagateNodeListSubtreeFacts(self.parameters, ast.propagateSubtreeFacts) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.fullSignature) |
            ast.propagateSubtreeFacts(self.body)
    end
end

function ast.ConstructorDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsConstructor
end

function ast.AccessorDeclarationBase:IsAccessorDeclaration() end

function ast.AccessorDeclarationBase:computeSubtreeFacts()
    if self.body == nil then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
            ast.propagateNodeListSubtreeFacts(self.parameters, ast.propagateSubtreeFacts) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.fullSignature) |
            ast.propagateSubtreeFacts(self.body)
    end
end

function ast.AccessorDeclarationBase:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsAccessor |
        ast.propagateSubtreeFacts(self.name)
end

function ast.MethodDeclaration:computeSubtreeFacts()
    if self.body == nil then
        return SubtreeFacts.SubtreeContainsTypeScript
    else
        local isAsync = self.modifiers ~= nil and self.modifiers.modifierFlags & ModifierFlags.Async ~= 0
        local isGenerator = self.asteriskToken ~= nil
        return ast.propagateModifierListSubtreeFacts(self.modifiers) |
            ast.propagateSubtreeFacts(self.asteriskToken) |
            ast.propagateSubtreeFacts(self.name) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.postfixToken) |
            ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
            ast.propagateNodeListSubtreeFacts(self.parameters, ast.propagateSubtreeFacts) |
            ast.propagateSubtreeFacts(self.body) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
            ast.propagateEraseableSyntaxSubtreeFacts(self.fullSignature) |
            ((isAsync and isGenerator) and SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator or None) |
            ((isAsync and not isGenerator) and SubtreeFacts.SubtreeContainsAnyAwait or None)
    end
end

function ast.MethodDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsMethod |
        ast.propagateSubtreeFacts(self.name)
end

function ast.PropertyDeclaration:computeSubtreeFacts()
    return ast.propagateModifierListSubtreeFacts(self.modifiers) |
        ast.propagateSubtreeFacts(self.name) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.postfixToken) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
        ast.propagateSubtreeFacts(self.initializer) |
        SubtreeFacts.SubtreeContainsClassFields
end

function ast.PropertyDeclaration:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsProperty |
        ast.propagateSubtreeFacts(self.name)
end

function ast.ClassStaticBlockDeclaration:computeSubtreeFacts()
    return ast.propagateModifierListSubtreeFacts(self.modifiers) |
        ast.propagateSubtreeFacts(self.body) |
        SubtreeFacts.SubtreeContainsClassFields
end

function ast.KeywordExpression:computeSubtreeFacts()
    if self.kind == Kind.ThisKeyword then
        return SubtreeFacts.SubtreeContainsLexicalThis
    elseif self.kind == Kind.SuperKeyword then
        return SubtreeFacts.SubtreeContainsLexicalSuper
    end
    return None
end

-- TemplateLiteralLikeBase

function ast.LiteralLikeNodeBase:LiteralLikeData() return self end

function ast.BigIntLiteral:computeSubtreeFacts()
    return None -- `bigint` is not downleveled in any way
end

function ast.Identifier:computeSubtreeFacts()
    return SubtreeFacts.SubtreeContainsIdentifier
end

function ast.NoSubstitutionTemplateLiteral:computeSubtreeFacts()
    if self.templateFlags & TokenFlags.ContainsInvalidEscape ~= 0 then
        return SubtreeFacts.SubtreeContainsInvalidTemplateEscape
    end
    return None
end

function ast.BinaryExpression:computeSubtreeFacts()
    local facts = ast.propagateModifierListSubtreeFacts(self.modifiers) |
        ast.propagateSubtreeFacts(self.left) |
        ast.propagateSubtreeFacts(self.type) |
        ast.propagateSubtreeFacts(self.operatorToken) |
        ast.propagateSubtreeFacts(self.right) |
        ((self.operatorToken.kind == Kind.InKeyword and ast.IsPrivateIdentifier(self.left)) and
            (SubtreeFacts.SubtreeContainsClassFields | SubtreeFacts.SubtreeContainsPrivateIdentifierInExpression) or None)
    if self.operatorToken.kind == Kind.EqualsToken then
        if (ast.IsObjectLiteralExpression(self.left) or ast.IsArrayLiteralExpression(self.left)) and
            ast.ContainsObjectRestOrSpread(self.left) then
            facts = facts | SubtreeFacts.SubtreeContainsObjectRestOrSpread
        end
    end
    return facts
end

function ast.BinaryExpression:setModifiers(modifiers) self.modifiers = modifiers end

function ast.YieldExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator
end

function ast.ArrowFunction:computeSubtreeFacts()
    return ast.propagateModifierListSubtreeFacts(self.modifiers) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
        ast.propagateNodeListSubtreeFacts(self.parameters, ast.propagateSubtreeFacts) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.fullSignature) |
        ast.propagateSubtreeFacts(self.body) |
        (self:ModifierFlags() & ModifierFlags.Async ~= 0 and SubtreeFacts.SubtreeContainsAnyAwait or None)
end

function ast.ArrowFunction:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsArrowFunction
end

function ast.FunctionExpression:computeSubtreeFacts()
    local isAsync = self.modifiers ~= nil and self.modifiers.modifierFlags & ModifierFlags.Async ~= 0
    local isGenerator = self.asteriskToken ~= nil
    return ast.propagateModifierListSubtreeFacts(self.modifiers) |
        ast.propagateSubtreeFacts(self.asteriskToken) |
        ast.propagateSubtreeFacts(self.name) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeParameters) |
        ast.propagateNodeListSubtreeFacts(self.parameters, ast.propagateSubtreeFacts) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.type) |
        ast.propagateEraseableSyntaxSubtreeFacts(self.fullSignature) |
        ast.propagateSubtreeFacts(self.body) |
        ((isAsync and isGenerator) and SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator or None) |
        ((isAsync and not isGenerator) and SubtreeFacts.SubtreeContainsAnyAwait or None)
end

function ast.FunctionExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsFunction
end

function ast.AsExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsTypeScript
end

function ast.AsExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsOuterExpression
end

function ast.SatisfiesExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsTypeScript
end

function ast.SatisfiesExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsOuterExpression
end

function ast.PropertyAccessExpression:computeSubtreeFacts()
    local privateName = None
    if not ast.IsIdentifier(self.name) then
        privateName = SubtreeFacts.SubtreeContainsPrivateIdentifierInExpression
    end
    return ast.propagateSubtreeFacts(self.expression) |
        ast.propagateSubtreeFacts(self.questionDotToken) |
        ast.propagateSubtreeFacts(self.name) | privateName
end

function ast.PropertyAccessExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsPropertyAccess
end

function ast.ElementAccessExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsElementAccess
end

function ast.CallExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) |
        ast.propagateSubtreeFacts(self.questionDotToken) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeArguments) |
        ast.propagateNodeListSubtreeFacts(self.arguments, ast.propagateSubtreeFacts) |
        (self.expression.kind == Kind.ImportKeyword and SubtreeFacts.SubtreeContainsDynamicImport or None)
end

function ast.CallExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsCall
end

function ast.NewExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeArguments) |
        ast.propagateNodeListSubtreeFacts(self.arguments, ast.propagateSubtreeFacts)
end

function ast.NewExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsNew
end

function ast.MetaProperty:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.name) & ~SubtreeFacts.SubtreeContainsIdentifier
end

function ast.NonNullExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsTypeScript
end

function ast.SpreadElement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsRestOrSpread
end

function ast.TaggedTemplateExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.tag) |
        ast.propagateSubtreeFacts(self.questionDotToken) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeArguments) |
        ast.propagateSubtreeFacts(self.template)
end

-- Hand-written subtree facts for nontrivial generated nodes.

function ast.ArrayLiteralExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsArrayLiteral
end

function ast.ObjectLiteralExpression:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsObjectLiteral
end

function ast.SpreadAssignment:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsESObjectRestOrSpread |
        SubtreeFacts.SubtreeContainsObjectRestOrSpread
end

function ast.PropertyAssignment:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.name) |
        ast.propagateSubtreeFacts(self.type) |
        ast.propagateSubtreeFacts(self.initializer)
end

function ast.ShorthandPropertyAssignment:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.name) |
        ast.propagateSubtreeFacts(self.type) |
        ast.propagateSubtreeFacts(self.objectAssignmentInitializer) |
        SubtreeFacts.SubtreeContainsTypeScript
end

function ast.AwaitExpression:computeSubtreeFacts()
    -- await in an ES2018 async generator must use `yield __await(expr)`
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsAwait |
        SubtreeFacts.SubtreeContainsAnyAwait | SubtreeFacts.SubtreeContainsForAwaitOrAsyncGenerator
end

function ast.TypeAssertion:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsTypeScript
end

function ast.TypeAssertion:propagateSubtreeFacts()
    return self:SubtreeFacts() & ~SubtreeFacts.SubtreeExclusionsOuterExpression
end

function ast.ExpressionWithTypeArguments:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeArguments)
end

-- Go: (node *ImportAttributesNode) GetResolutionModeOverride, callable on a nil node. In Lua call
-- it as ast.Node.GetResolutionModeOverride(node) when node may be nil. Returns mode, ok.
function Node.GetResolutionModeOverride(node)
    if node == nil then
        return core.ModuleKind.ResolutionModeNone, false
    end

    local attributes = node:AsImportAttributes().attributes

    if #attributes.nodes ~= 1 then
        -- !!!
        -- grammarErrorOnNode?.(
        --     node,
        --     node.token === SyntaxKind.WithKeyword
        --         ? Diagnostics.Type_import_attributes_should_have_exactly_one_key_resolution_mode_with_value_import_or_require
        --         : Diagnostics.Type_import_assertions_should_have_exactly_one_key_resolution_mode_with_value_import_or_require,
        -- );
        return core.ModuleKind.ResolutionModeNone, false
    end

    local elem = attributes.nodes[1]:AsImportAttribute()
    if not ast.IsStringLiteralLike(elem:Name()) then
        return core.ModuleKind.ResolutionModeNone, false
    end
    if elem:Name():Text() ~= "resolution-mode" then
        -- !!!
        return core.ModuleKind.ResolutionModeNone, false
    end
    if not ast.IsStringLiteralLike(elem.value) then
        return core.ModuleKind.ResolutionModeNone, false
    end
    if elem.value:Text() ~= "import" and elem.value:Text() ~= "require" then
        -- !!!
        -- grammarErrorOnNode?.(elem.value, Diagnostics.resolution_mode_should_be_either_require_or_import);
        return core.ModuleKind.ResolutionModeNone, false
    end
    if elem.value:Text() == "import" then
        return core.ModuleKind.ResolutionModeESM, true
    else
        return core.ModuleKind.CommonJS, true
    end
end

-- FunctionOrConstructorTypeNodeBase

function ast.TemplateLiteralLikeNodeBase:LiteralLikeData()
    return self
end

function ast.TemplateLiteralLikeNodeBase:TemplateLiteralLikeData()
    return self
end

function ast.TemplateHead:computeSubtreeFacts()
    if self.templateFlags & TokenFlags.ContainsInvalidEscape ~= 0 then
        return SubtreeFacts.SubtreeContainsInvalidTemplateEscape
    end
    return None
end

function ast.TemplateMiddle:computeSubtreeFacts()
    if self.templateFlags & TokenFlags.ContainsInvalidEscape ~= 0 then
        return SubtreeFacts.SubtreeContainsInvalidTemplateEscape
    end
    return None
end

function ast.TemplateTail:computeSubtreeFacts()
    if self.templateFlags & TokenFlags.ContainsInvalidEscape ~= 0 then
        return SubtreeFacts.SubtreeContainsInvalidTemplateEscape
    end
    return None
end

function ast.JsxElement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.openingElement) |
        ast.propagateNodeListSubtreeFacts(self.children, ast.propagateSubtreeFacts) |
        ast.propagateSubtreeFacts(self.closingElement) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxAttributes:computeSubtreeFacts()
    return ast.propagateNodeListSubtreeFacts(self.properties, ast.propagateSubtreeFacts) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxNamespacedName:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.namespace) |
        ast.propagateSubtreeFacts(self.name) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxOpeningElement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.tagName) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeArguments) |
        ast.propagateSubtreeFacts(self.attributes) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxSelfClosingElement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.tagName) |
        ast.propagateEraseableSyntaxListSubtreeFacts(self.typeArguments) |
        ast.propagateSubtreeFacts(self.attributes) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxFragment:computeSubtreeFacts()
    return ast.propagateNodeListSubtreeFacts(self.children, ast.propagateSubtreeFacts) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxOpeningFragment:computeSubtreeFacts()
    return SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxClosingFragment:computeSubtreeFacts()
    return SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxAttribute:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.name) |
        ast.propagateSubtreeFacts(self.initializer) |
        SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxSpreadAttribute:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxClosingElement:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.tagName) | SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxExpression:computeSubtreeFacts()
    return ast.propagateSubtreeFacts(self.expression) | SubtreeFacts.SubtreeContainsJsx
end

function ast.JsxText:computeSubtreeFacts()
    return SubtreeFacts.SubtreeContainsJsx
end

--- JSDoc nodes ///

-- JSDoc

function Node:IsJSDoc()
    return self.kind == Kind.JSDoc
end

-- JSDocText

-- PatternAmbientModule: { pattern = core.Pattern, symbol = Symbol }

function ast.NewPatternAmbientModule(pattern, symbol)
    return { pattern = pattern, symbol = symbol }
end

-- CommentDirective: { loc = core.TextRange, kind = CommentDirectiveKind }

-- SourceFile

-- SourceFileMetaData: { packageJsonType = "", packageJsonDirectory = "", impliedNodeFormat = core.ResolutionMode }

-- SourceFileDataKey identifies lazily-computed data attached to a SourceFile by
-- another package. Prefer regular SourceFile fields for ast-owned data.
ast.sourceFileDataKeyCounter = 0

function ast.NewSourceFileDataKey()
    ast.sourceFileDataKeyCounter = ast.sourceFileDataKeyCounter + 1
    return { key = ast.sourceFileDataKeyCounter }
end

function ast.GetOrComputeSourceFileData(file, key, compute)
    local cell = ast.getSourceFileDataCell(file, key)
    if not cell.once then
        cell.once = true
        cell.value = compute(file)
    end
    return cell.value
end

function ast.getSourceFileDataCell(file, key)
    if key == nil or key.key == 0 then
        error("invalid SourceFileDataKey; use NewSourceFileDataKey")
    end
    if file.data == nil then
        file.data = {}
    end
    local cell = file.data[key.key]
    if cell ~= nil then
        return cell
    end
    cell = { once = false, value = nil }
    file.data[key.key] = cell
    return cell
end

-- CheckJsDirective: { enabled = bool, range = CommentRange }

-- HasFileName: any table with FileName() and Path() methods.

-- TokenCacheKey {parent, loc}: SourceFile.tokenCache is keyed by parent node, then by "pos:end".

local SourceFile = ast.DefineStruct("SourceFile", { "NodeBase", "DeclarationBase", "LocalsContainerBase", "CompositeBase" })

function NodeFactory:NewSourceFile(opts, text, statements, endOfFileToken)
    if tspath.GetEncodedRootLength(opts.fileName) == 0 or opts.fileName ~= tspath.NormalizePath(opts.fileName) then
        error(string.format("fileName should be normalized and absolute: %q", opts.fileName))
    end
    local data = setmetatable({
        facts = 0,
        -- Fields set by NewSourceFile
        fileName = opts.fileName, -- For debugging convenience
        parseOptions = opts,
        text = text,
        contentMapperInfo = nil,
        statements = statements,
        endOfFileToken = endOfFileToken,
        -- Fields for lazily-computed data owned by packages outside ast.
        data = nil,
        -- Fields set by parser
        diagnostics = nil,
        jsDiagnostics = nil,
        jsdocDiagnostics = nil,
        languageVariant = core.LanguageVariant.Standard,
        scriptKind = core.ScriptKind.Unknown,
        isDeclarationFile = false,
        usesUriStyleNodeCoreModules = core.Tristate.Unknown,
        identifierCount = 0,
        imports = nil,
        moduleAugmentations = nil,
        ambientModuleNames = nil,
        commentDirectives = nil,
        jsdocCache = nil,
        hasLazyJSDoc = false,
        identifiersOnce = false,
        identifiers = nil,
        reparsedClones = nil,
        pragmas = nil,
        referencedFiles = nil,
        typeReferenceDirectives = nil,
        libReferenceDirectives = nil,
        checkJsDirective = nil,
        nodeCount = 0,
        textCount = 0,
        commonJSModuleIndicator = nil,
        -- If this is the SourceFile itself, then this module was "forced"
        -- to be an external module (previously "true").
        externalModuleIndicator = nil,
        -- Fields set by binder
        isBound = false,
        bindOnce = false,
        bindDiagnostics = nil,
        symbolCount = 0,
        patternAmbientModules = nil,
        globalExports = nil,
        -- Fields set by ECMALineMap
        ecmaLineMap = nil,
        -- Fields set by language service
        tokenCache = nil,
        tokenFactory = nil,
        declarationMap = nil,
        nameTableOnce = false,
        nameTable = nil,
        -- Fields for UTF-8 to UTF-16 position mapping
        positionMapOnce = false,
        positionMap = nil,
    }, SourceFile)
    return self:newNode(Kind.SourceFile, data)
end

function SourceFile:ParseOptions()
    return self.parseOptions
end

function SourceFile:Text()
    return self.text
end

-- OriginalText returns the untransformed source text for content-mapped files, or Text() otherwise.
function SourceFile:OriginalText()
    if self:ContentMapper() ~= "" then
        return self.contentMapperInfo.originalText
    end
    return self.text
end

-- OriginalFileName returns the canonical filename associated with a supplemental source file, or FileName() otherwise.
function SourceFile:OriginalFileName()
    local canonical = self:CanonicalSourceFile()
    if canonical ~= nil then
        return canonical:FileName()
    end
    return self:FileName()
end

-- SpanMap returns the span map that maps positions in this file's transformed Text() back to its
-- original, untransformed content, or nil if the file is not content-mapped (or is a failure stub).
function SourceFile:SpanMap()
    if self.contentMapperInfo == nil then
        return nil
    end
    return self.contentMapperInfo.spanMap
end

-- ContentMapper returns the identity of the content mapper that produced this file, or "" if the file
-- was not produced by a content mapper (or the mapper did not identify itself).
function SourceFile:ContentMapper()
    if self.contentMapperInfo == nil then
        return ""
    end
    return self.contentMapperInfo.contentMapper
end

-- IsContentMapperFailureStub reports whether this file is the empty placeholder produced when a content
-- mapper's transform failed.
function SourceFile:IsContentMapperFailureStub()
    return self:ContentMapper() ~= "" and self:SpanMap() == nil
end

function SourceFile:ContentMapperTransformIdentity()
    if self.contentMapperInfo == nil then
        return ""
    end
    return self.contentMapperInfo.transformIdentity
end

function SourceFile:VirtualFileName()
    if self.contentMapperInfo == nil then
        return ""
    end
    return self.contentMapperInfo.virtualFileName
end

-- MappedDiagnosticDirective: { originalRange, virtualRange, policy, unusedCode, unusedMessageText, source }
-- ContentMapperSourceFileInfo: { contentMapper, transformIdentity, parseOptions, virtualFileName,
--   originalText, spanMap, diagnosticDirectives, supplementalSourceFiles, canonicalSourceFile }

-- ContentMapperParseOptions returns the parse options used to acquire this file from the mapped parse cache.
function SourceFile:ContentMapperParseOptions()
    if self.contentMapperInfo == nil then
        return ast.NewSourceFileParseOptions()
    end
    return self.contentMapperInfo.parseOptions
end

-- SetContentMapperInfo initializes all content-mapper metadata before the source file is published.
function SourceFile:SetContentMapperInfo(info)
    if self.contentMapperInfo ~= nil then
        error("content mapper source file info already set")
    end
    local copy = {}
    for k, v in pairs(info) do
        copy[k] = v
    end
    self.contentMapperInfo = copy
end

function SourceFile:DiagnosticDirectives()
    if self.contentMapperInfo == nil then
        return nil
    end
    return self.contentMapperInfo.diagnosticDirectives
end

-- SupplementalSourceFiles returns the additional outputs produced from this canonical source file.
function SourceFile:SupplementalSourceFiles()
    if self.contentMapperInfo == nil then
        return nil
    end
    return self.contentMapperInfo.supplementalSourceFiles
end

-- CanonicalSourceFile returns the canonical output associated with this supplemental source file.
function SourceFile:CanonicalSourceFile()
    if self.contentMapperInfo == nil then
        return nil
    end
    return self.contentMapperInfo.canonicalSourceFile
end

-- IsContentMapperSupplemental reports whether this is an unnamed supplemental mapper output.
function SourceFile:IsContentMapperSupplemental()
    return self:CanonicalSourceFile() ~= nil
end

function SourceFile:HasIdentifier(name)
    if not self.identifiersOnce then
        self.identifiersOnce = true
        self.identifiers = ast.collectIdentifiersForSourceFile(self)
    end
    return self.identifiers[name] == true
end

function ast.collectIdentifiersForSourceFile(sourceFile)
    -- collections.Set[string] -> a Lua set table
    local identifiers = {}
    local collect
    collect = function(node)
        local kind = node.kind
        if kind == Kind.Identifier or kind == Kind.PrivateIdentifier or kind == Kind.StringLiteral or
            kind == Kind.NumericLiteral or kind == Kind.BigIntLiteral or kind == Kind.NoSubstitutionTemplateLiteral then
            identifiers[node:Text()] = true
        end
        node:ForEachChild(collect)
        return false
    end
    collect(sourceFile)
    return identifiers
end

function SourceFile:FileName()
    return self.parseOptions.fileName
end

function SourceFile:Path()
    return self.parseOptions.path
end

function SourceFile:Imports()
    return self.imports
end

function SourceFile:Diagnostics()
    return self.diagnostics
end

function SourceFile:SetDiagnostics(diags)
    self.diagnostics = diags
end

function SourceFile:JSDiagnostics()
    return self.jsDiagnostics
end

function SourceFile:SetJSDiagnostics(diags)
    self.jsDiagnostics = diags
end

function SourceFile:JSDocDiagnostics()
    return self.jsdocDiagnostics
end

function SourceFile:SetJSDocDiagnostics(diags)
    self.jsdocDiagnostics = diags
end

-- cache: a table keyed by node, values are arrays of JSDoc nodes.
function SourceFile:SetJSDocCache(cache)
    self.jsdocCache = cache
end

function SourceFile:SetHasLazyJSDoc(lazy)
    self.hasLazyJSDoc = lazy
end

function SourceFile:resolveJSDoc(n)
    if ast.parseJSDocForNode == nil then
        error("resolveJSDoc called but parseJSDocForNode is not registered; ensure the parser package is imported")
    end
    local cache = self.jsdocCache
    if cache ~= nil then
        local jsdocs = cache[n]
        if jsdocs ~= nil then
            return jsdocs
        end
    end
    local jsdocs = ast.parseJSDocForNode(self, n)
    if self.jsdocCache == nil then
        self.jsdocCache = {}
    end
    -- A Go map stores nil slices as present entries; store an empty array so the lookup above hits.
    self.jsdocCache[n] = jsdocs or {}
    return jsdocs
end

function SourceFile:BindDiagnostics()
    return self.bindDiagnostics
end

function SourceFile:SetBindDiagnostics(diags)
    self.bindDiagnostics = diags
end

function SourceFile:ForEachChild(v)
    return ast.visitNodeList(v, self.statements) or ast.visit(v, self.endOfFileToken)
end

function SourceFile:VisitEachChild(v)
    return v.factory:UpdateSourceFile(self, v:visitTopLevelStatements(self.statements), v:visitToken(self.endOfFileToken))
end

function SourceFile:IsJS()
    return ast.IsSourceFileJS(self)
end

function SourceFile:copyFrom(other)
    -- Do not copy fields set by NewSourceFile (Text, FileName, Path, or Statements)
    if other.contentMapperInfo ~= nil then
        self:SetContentMapperInfo(other.contentMapperInfo)
    end
    self.languageVariant = other.languageVariant
    self.scriptKind = other.scriptKind
    self.isDeclarationFile = other.isDeclarationFile
    self.usesUriStyleNodeCoreModules = other.usesUriStyleNodeCoreModules
    self.imports = other.imports
    self.moduleAugmentations = other.moduleAugmentations
    self.ambientModuleNames = other.ambientModuleNames
    self.commentDirectives = other.commentDirectives
    self.pragmas = other.pragmas
    self.referencedFiles = other.referencedFiles
    self.typeReferenceDirectives = other.typeReferenceDirectives
    self.libReferenceDirectives = other.libReferenceDirectives
    self.commonJSModuleIndicator = other.commonJSModuleIndicator
    self.externalModuleIndicator = other.externalModuleIndicator
    self.flags = self.flags | other.flags
end

function SourceFile:Clone(f)
    local updated = f:AsNodeFactory():NewSourceFile(self.parseOptions, self.text, self.statements, self.endOfFileToken)
    local newFile = updated:AsSourceFile()
    newFile:copyFrom(self)
    return ast.cloneNode(updated, self, f:AsNodeFactory().hooks)
end

function SourceFile:computeSubtreeFacts()
    return ast.propagateNodeListSubtreeFacts(self.statements, ast.propagateSubtreeFacts)
end

function NodeFactory:UpdateSourceFile(node, statements, endOfFileToken)
    if statements ~= node.statements or endOfFileToken ~= node.endOfFileToken then
        local updated = self:NewSourceFile(node.parseOptions, node.text, statements, endOfFileToken):AsSourceFile()
        updated:copyFrom(node)
        return ast.updateNode(updated, node, self.hooks)
    end
    return node
end

function SourceFile:ECMALineMap()
    local lineMap = self.ecmaLineMap
    if lineMap == nil then
        lineMap = core.ComputeECMALineStarts(self:Text())
        self.ecmaLineMap = lineMap
    end
    return lineMap
end

-- GetNameTable returns a map of all names in the file to their positions.
-- If the name appears more than once, the value is -1.
function SourceFile:GetNameTable()
    if not self.nameTableOnce then
        self.nameTableOnce = true
        local file = self
        local nameTable = {}

        local walk
        walk = function(node)
            if ast.IsIdentifier(node) and not ast.IsTagName(node) and node:Text() ~= "" or
                ast.IsStringOrNumericLiteralLike(node) and ast.literalIsName(node) or
                ast.IsPrivateIdentifier(node) then
                local text = node:Text()
                if nameTable[text] ~= nil then
                    nameTable[text] = -1
                else
                    nameTable[text] = node:Pos()
                end
            end

            node:ForEachChild(walk)
            local jsdocNodes = node:JSDoc(file)
            if jsdocNodes ~= nil then
                for _, jsdoc in ipairs(jsdocNodes) do
                    jsdoc:ForEachChild(walk)
                end
            end
            return false
        end
        file:ForEachChild(walk)

        file.nameTable = nameTable
    end
    return self.nameTable
end

function SourceFile:IsBound()
    return self.isBound
end

-- GetPositionMap returns the PositionMap for this source file, computing it lazily.
function SourceFile:GetPositionMap()
    if not self.positionMapOnce then
        self.positionMapOnce = true
        self.positionMap = ast.ComputePositionMap(self:Text())
    end
    return self.positionMap
end

function SourceFile:BindOnce(bind)
    if not self.bindOnce then
        self.bindOnce = true
        bind()
        self.isBound = true
    end
end

-- Gets a token from the file's token cache, or creates it if it does not already exist.
-- This function should NOT be used for creating synthetic tokens that are not in the file in the first place.
function SourceFile:GetOrCreateToken(kind, pos, end_, parent, flags)
    local loc = core.NewTextRange(pos, end_)
    local key = pos .. ":" .. end_
    local byParent = self.tokenCache ~= nil and self.tokenCache[parent] or nil
    if byParent ~= nil then
        local token = byParent[key]
        if token ~= nil then
            if token.kind ~= kind then
                error(string.format("Token cache mismatch: %s != %s", ast.Kind_String(token.kind), ast.Kind_String(kind)))
            end
            return token
        end
    end
    if parent.flags & NodeFlags.Reparsed ~= 0 then
        error(string.format("Cannot create token from reparsed node of kind %s", ast.Kind_String(parent.kind)))
    end
    if self.tokenCache == nil then
        self.tokenCache = {}
    end
    if byParent == nil then
        byParent = {}
        self.tokenCache[parent] = byParent
    end
    local token = ast.createToken(kind, self, pos, end_, flags)
    token.loc = loc
    token.parent = parent
    byParent[key] = token
    return token
end

-- `kind` should be a token kind.
function ast.createToken(kind, file, pos, end_, flags)
    if file.tokenFactory == nil then
        file.tokenFactory = ast.NewNodeFactory({})
    end
    local text = string.sub(file.text, pos + 1, end_)
    local f = file.tokenFactory
    if kind == Kind.NumericLiteral then
        return f:NewNumericLiteral(text, flags)
    elseif kind == Kind.BigIntLiteral then
        return f:NewBigIntLiteral(text, flags)
    elseif kind == Kind.StringLiteral then
        return f:NewStringLiteral(text, flags)
    elseif kind == Kind.JsxText or kind == Kind.JsxTextAllWhiteSpaces then
        return f:NewJsxText(text, kind == Kind.JsxTextAllWhiteSpaces)
    elseif kind == Kind.RegularExpressionLiteral then
        return f:NewRegularExpressionLiteral(text, flags)
    elseif kind == Kind.NoSubstitutionTemplateLiteral then
        return f:NewNoSubstitutionTemplateLiteral(text, flags)
    elseif kind == Kind.TemplateHead then
        return f:NewTemplateHead(text, "" --[[rawText]], flags)
    elseif kind == Kind.TemplateMiddle then
        return f:NewTemplateMiddle(text, "" --[[rawText]], flags)
    elseif kind == Kind.TemplateTail then
        return f:NewTemplateTail(text, "" --[[rawText]], flags)
    elseif kind == Kind.Identifier then
        return f:NewIdentifier(text)
    elseif kind == Kind.PrivateIdentifier then
        return f:NewPrivateIdentifier(text)
    end
    -- Punctuation and keywords
    return f:NewToken(kind)
end

function SourceFile:GetDeclarationMap()
    if self.declarationMap == nil then
        self.declarationMap = self:computeDeclarationMap()
    end
    return self.declarationMap
end

local declarationMapContainerKinds = kindSet(Kind.ClassDeclaration, Kind.ClassExpression, Kind.InterfaceDeclaration,
    Kind.TypeAliasDeclaration, Kind.EnumDeclaration, Kind.ModuleDeclaration, Kind.ImportEqualsDeclaration,
    Kind.ImportClause, Kind.NamespaceImport, Kind.GetAccessor, Kind.SetAccessor, Kind.TypeLiteral)

function SourceFile:computeDeclarationMap()
    local result = {}

    local function addDeclaration(declaration)
        local name = ast.GetDeclarationName(declaration)
        if name ~= "" then
            local list = result[name]
            if list == nil then
                list = {}
                result[name] = list
            end
            list[#list + 1] = declaration
        end
    end

    local visit
    visit = function(node)
        local kind = node.kind
        if kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression or kind == Kind.MethodDeclaration or
            kind == Kind.MethodSignature then
            local declarationName = ast.GetDeclarationName(node)
            if declarationName ~= "" then
                local declarations = result[declarationName]
                local lastDeclaration = nil
                if declarations ~= nil and #declarations ~= 0 then
                    lastDeclaration = declarations[#declarations]
                end
                -- Check whether this declaration belongs to an "overload group".
                if lastDeclaration ~= nil and node.parent == lastDeclaration.parent and node:Symbol() == lastDeclaration:Symbol() then
                    -- Overwrite the last declaration if it was an overload and this one is an implementation.
                    if node:Body() ~= nil and lastDeclaration:Body() == nil then
                        declarations[#declarations] = node
                    end
                else
                    if declarations == nil then
                        declarations = {}
                        result[declarationName] = declarations
                    end
                    declarations[#declarations + 1] = node
                end
            end
            node:ForEachChild(visit)
        elseif declarationMapContainerKinds[kind] then
            addDeclaration(node)
            node:ForEachChild(visit)
        elseif kind == Kind.ImportSpecifier or kind == Kind.ExportSpecifier then
            if node:PropertyName() ~= nil then
                addDeclaration(node)
            end
        elseif kind == Kind.Parameter or kind == Kind.VariableDeclaration or kind == Kind.BindingElement then
            -- Only consider parameter properties
            if kind == Kind.Parameter and not ast.HasSyntacticModifier(node, ModifierFlags.ParameterPropertyModifier) then
                return false
            end
            local name = node:Name()
            if name ~= nil then
                if ast.IsBindingPattern(name) then
                    node:Name():ForEachChild(visit)
                else
                    if node:Initializer() ~= nil then
                        visit(node:Initializer())
                    end
                    addDeclaration(node)
                end
            end
        elseif kind == Kind.EnumMember or kind == Kind.PropertyDeclaration or kind == Kind.PropertySignature then
            addDeclaration(node)
        elseif kind == Kind.ExportDeclaration then
            -- Handle named exports case e.g.:
            --    export {a, b as B} from "mod";
            local exportClause = node.exportClause
            if exportClause ~= nil then
                if ast.IsNamedExports(exportClause) then
                    for _, element in ipairs(exportClause:Elements()) do
                        visit(element)
                    end
                else
                    visit(exportClause:AsNamespaceExport():Name())
                end
            end
        elseif kind == Kind.ImportDeclaration then
            local importClause = node.importClause
            if importClause ~= nil then
                -- Handle default import case e.g.:
                --    import d from "mod";
                if importClause:Name() ~= nil then
                    addDeclaration(importClause:Name())
                end
                -- Handle named bindings in imports e.g.:
                --    import * as NS from "mod";
                --    import {a, b as B} from "mod";
                local namedBindings = importClause.namedBindings
                if namedBindings ~= nil then
                    if namedBindings.kind == Kind.NamespaceImport then
                        addDeclaration(namedBindings)
                    else
                        for _, element in ipairs(namedBindings:Elements()) do
                            visit(element)
                        end
                    end
                end
            end
        elseif kind == Kind.BinaryExpression then
            local k = ast.GetAssignmentDeclarationKind(node)
            if k == JSDeclarationKind.ExportsProperty or k == JSDeclarationKind.ThisProperty or k == JSDeclarationKind.Property then
                addDeclaration(node)
            end
            node:ForEachChild(visit)
        else
            node:ForEachChild(visit)
        end
        return false
    end
    self:ForEachChild(visit)
    return result
end

function ast.GetDeclarationName(declaration)
    local name = ast.GetNonAssignedNameOfDeclaration(declaration)
    if name ~= nil then
        if ast.IsComputedPropertyName(name) then
            if ast.IsStringOrNumericLiteralLike(name:Expression()) then
                return name:Expression():Text()
            end
            if ast.IsPropertyAccessExpression(name:Expression()) then
                return name:Expression():Name():Text()
            end
        elseif ast.IsPropertyName(name) then
            return name:Text()
        end
    end
    return ""
end

-- SourceFileLike: any table with Text() and ECMALineMap() methods.

-- CommentRange embeds core.TextRange: { pos, end_, kind, hasTrailingNewLine }.
local CommentRange = setmetatable({}, { __index = core.TextRange })
CommentRange.__index = CommentRange
CommentRange.__name = "CommentRange"
ast.CommentRange = CommentRange

function ast.NewCommentRangeValue(kind, pos, end_, hasTrailingNewLine)
    return setmetatable({ pos = pos, end_ = end_, kind = kind, hasTrailingNewLine = hasTrailingNewLine }, CommentRange)
end

-- Go t.TextRange
function CommentRange:GetTextRange()
    return core.NewTextRange(self.pos, self.end_)
end

function NodeFactory:NewCommentRange(kind, pos, end_, hasTrailingNewLine)
    return ast.NewCommentRangeValue(kind, pos, end_, hasTrailingNewLine)
end

-- FileReference embeds core.TextRange: { pos, end_, fileName, resolutionMode, preserve }.
local FileReference = setmetatable({}, { __index = core.TextRange })
FileReference.__index = FileReference
FileReference.__name = "FileReference"
ast.FileReference = FileReference

function ast.NewFileReference(pos, end_, fileName, resolutionMode, preserve)
    return setmetatable({
        pos = pos,
        end_ = end_,
        fileName = fileName or "",
        resolutionMode = resolutionMode or core.ModuleKind.ResolutionModeNone,
        preserve = preserve or false,
    }, FileReference)
end

-- PragmaArgument embeds core.TextRange: { pos, end_, name, value }.
local PragmaArgument = setmetatable({}, { __index = core.TextRange })
PragmaArgument.__index = PragmaArgument
PragmaArgument.__name = "PragmaArgument"
ast.PragmaArgument = PragmaArgument

function ast.NewPragmaArgument(pos, end_, name, value)
    return setmetatable({ pos = pos, end_ = end_, name = name or "", value = value or "" }, PragmaArgument)
end

-- Pragma embeds CommentRange: { pos, end_, kind, hasTrailingNewLine, name, args = { [name] = PragmaArgument } }.
local Pragma = setmetatable({}, { __index = CommentRange })
Pragma.__index = Pragma
Pragma.__name = "Pragma"
ast.Pragma = Pragma

function ast.NewPragma(commentRange, name, args)
    return setmetatable({
        pos = commentRange.pos,
        end_ = commentRange.end_,
        kind = commentRange.kind,
        hasTrailingNewLine = commentRange.hasTrailingNewLine,
        name = name or "",
        args = args,
    }, Pragma)
end

-- PragmaArgumentSpecification: { name = "", optional = false, captureSpan = false }

-- PragmaSpecification: { args = { PragmaArgumentSpecification... }, kind = PragmaKindFlags }
local PragmaSpecification = {}
PragmaSpecification.__index = PragmaSpecification
ast.PragmaSpecification = PragmaSpecification

function ast.NewPragmaSpecification(args, kind)
    return setmetatable({ args = args, kind = kind or 0 }, PragmaSpecification)
end

function PragmaSpecification:IsTripleSlash()
    return (self.kind & ast.PragmaKindTripleSlashXML) > 0
end

-- Hand-written visitor implementations for nodes with runtime-dependent
-- child ordering. Generated code in ast_generated.lua delegates to these.

function ast.forEachChild_JSDocParameterOrPropertyTag(node, v)
    return ast.visit(v, node.tagName) or
        (node.isNameFirst and
            (ast.visit(v, node.name) or ast.visit(v, node.typeExpression))) or
        (not node.isNameFirst and
            (ast.visit(v, node.typeExpression) or ast.visit(v, node.name))) or
        ast.visitNodeList(v, node.comment)
end

function ast.visitEachChild_JSDocParameterOrPropertyTag(node, v)
    return v.factory:UpdateJSDocParameterOrPropertyTag(node, v:visitNode(node.tagName), v:visitNode(node.name),
        node.isBracketed, v:visitNode(node.typeExpression), node.isNameFirst, v:visitNodes(node.comment))
end

function NodeFactory:ReleaseArenas()
    -- Arenas do not exist in Lua; nothing to release.
end
