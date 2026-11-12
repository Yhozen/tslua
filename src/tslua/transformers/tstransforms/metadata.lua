local tstransforms = require("tslua.transformers.tstransforms")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind

-- USE_NEW_TYPE_METADATA_FORMAT comes from consts_generated.

local MetadataTransformer = transformers.NewTransformerType()
tstransforms.MetadataTransformer = MetadataTransformer

function tstransforms.NewMetadataTransformer(opt)
    local tx = setmetatable({
        legacyDecorators = core.Tristate_IsTrue(opt.compilerOptions.experimentalDecorators),
        resolver = opt.emitResolver,
        serializer = nil,
        languageVersion = opt.compilerOptions:GetEmitScriptTarget(),
        strictNullChecks = opt.compilerOptions:GetStrictOptionValue(opt.compilerOptions.strictNullChecks),
        parent = nil,
        currentLexicalScope = nil,
    }, MetadataTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opt.context)
end

function MetadataTransformer:visit(node)
    if (node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsDecorators) == 0 then
        return node
    end

    local kind = node.kind
    if kind == Kind.ClassDeclaration then
        return self:visitClassDeclaration(node:AsClassDeclaration())
    elseif kind == Kind.ClassExpression then
        return self:visitClassExpression(node:AsClassExpression())
    elseif kind == Kind.PropertyDeclaration then
        return self:visitPropertyDeclaration(node:AsPropertyDeclaration())
    elseif kind == Kind.MethodDeclaration then
        return self:visitMethodDeclaration(node:AsMethodDeclaration())
    elseif kind == Kind.SetAccessor then
        return self:visitSetAccessor(node:AsSetAccessorDeclaration())
    elseif kind == Kind.GetAccessor then
        return self:visitGetAccessor(node:AsGetAccessorDeclaration())
    elseif kind == Kind.SourceFile then
        self.parent = nil
        self.currentLexicalScope = node
        self.serializer = tstransforms.newMetadataSerializer(self.resolver, self:Factory(), self:EmitContext(), self.languageVersion, self.strictNullChecks)
        local updated = self:Visitor():VisitEachChild(node)
        self:EmitContext():AddEmitHelper(updated, table.unpack(self:EmitContext():ReadEmitHelpers()))
        self:setCurrentLexicalScope(nil)
        self:setParent(nil)
        return updated
    elseif kind == Kind.ModuleBlock or kind == Kind.Block or kind == Kind.CaseBlock then
        local oldScope = self.currentLexicalScope
        self.currentLexicalScope = node
        local result = self:Visitor():VisitEachChild(node)
        self:setCurrentLexicalScope(oldScope)
        return result
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function MetadataTransformer:setParent(node)
    self.parent = node
end

function MetadataTransformer:setCurrentLexicalScope(node)
    self.currentLexicalScope = node
end

function MetadataTransformer:visitClassExpression(node)
    local oldParent = self.parent
    self.parent = node:AsNode()

    local result
    if not ast.ClassOrConstructorParameterIsDecorated(self.legacyDecorators, node:AsNode()) then
        result = self:Visitor():VisitEachChild(node:AsNode())
    else
        local modifiers = self:injectClassTypeMetadata(self:Visitor():VisitModifiers(node:Modifiers()), node:AsNode())
        result = self:Factory():UpdateClassExpression(
            node,
            modifiers,
            self:Visitor():VisitNode(node:Name()),
            self:Visitor():VisitNodes(node.typeParameters),
            self:Visitor():VisitNodes(node.heritageClauses),
            self:Visitor():VisitNodes(node.members)
        )
    end
    self:setParent(oldParent)
    return result
end

function MetadataTransformer:visitClassDeclaration(node)
    local oldParent = self.parent
    self.parent = node:AsNode()

    local result
    if not ast.ClassOrConstructorParameterIsDecorated(self.legacyDecorators, node:AsNode()) then
        result = self:Visitor():VisitEachChild(node:AsNode())
    else
        local modifiers = self:injectClassTypeMetadata(self:Visitor():VisitModifiers(node:Modifiers()), node:AsNode())
        result = self:Factory():UpdateClassDeclaration(
            node,
            modifiers,
            self:Visitor():VisitNode(node:Name()),
            self:Visitor():VisitNodes(node.typeParameters),
            self:Visitor():VisitNodes(node.heritageClauses),
            self:Visitor():VisitNodes(node.members)
        )
    end
    self:setParent(oldParent)
    return result
end

function MetadataTransformer:visitPropertyDeclaration(node)
    if not ast.HasDecorators(node:AsNode()) then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local modifiers = self:injectClassElementTypeMetadata(self:Visitor():VisitModifiers(node:Modifiers()), node:AsNode(), self.parent)
    return self:Factory():UpdatePropertyDeclaration(
        node,
        modifiers,
        self:Visitor():VisitNode(node:Name()),
        self:Visitor():VisitNode(node.postfixToken),
        self:Visitor():VisitNode(node.type),
        self:Visitor():VisitNode(node.initializer)
    )
end

function MetadataTransformer:visitMethodDeclaration(node)
    if not ast.HasDecorators(node:AsNode()) and core.Len(tstransforms.getDecoratorsOfParameters(node:AsNode())) == 0 then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local modifiers = self:injectClassElementTypeMetadata(self:Visitor():VisitModifiers(node:Modifiers()), node:AsNode(), self.parent)
    return self:Factory():UpdateMethodDeclaration(
        node,
        modifiers,
        self:Visitor():VisitNode(node.asteriskToken),
        self:Visitor():VisitNode(node:Name()),
        self:Visitor():VisitNode(node.postfixToken),
        self:Visitor():VisitNodes(node.typeParameters),
        self:Visitor():VisitNodes(node.parameters),
        self:Visitor():VisitNode(node.type),
        self:Visitor():VisitNode(node.fullSignature),
        self:Visitor():VisitNode(node.body)
    )
end

function MetadataTransformer:visitSetAccessor(node)
    if not ast.HasDecorators(node:AsNode()) and core.Len(tstransforms.getDecoratorsOfParameters(node:AsNode())) == 0 then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local modifiers = self:injectClassElementTypeMetadata(self:Visitor():VisitModifiers(node:Modifiers()), node:AsNode(), self.parent)
    return self:Factory():UpdateSetAccessorDeclaration(
        node,
        modifiers,
        self:Visitor():VisitNode(node:Name()),
        self:Visitor():VisitNodes(node.typeParameters),
        self:Visitor():VisitNodes(node.parameters),
        self:Visitor():VisitNode(node.type),
        self:Visitor():VisitNode(node.fullSignature),
        self:Visitor():VisitNode(node.body)
    )
end

function MetadataTransformer:visitGetAccessor(node)
    if not ast.HasDecorators(node:AsNode()) then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local modifiers = self:injectClassElementTypeMetadata(self:Visitor():VisitModifiers(node:Modifiers()), node:AsNode(), self.parent)
    return self:Factory():UpdateGetAccessorDeclaration(
        node,
        modifiers,
        self:Visitor():VisitNode(node:Name()),
        self:Visitor():VisitNodes(node.typeParameters),
        self:Visitor():VisitNodes(node.parameters),
        self:Visitor():VisitNode(node.type),
        self:Visitor():VisitNode(node.fullSignature),
        self:Visitor():VisitNode(node.body)
    )
end

-- Go slice expression s[a:] (0-based) as a fresh Lua array.
local function sliceFrom(s, a)
    local out = {}
    for i = a + 1, #s do
        out[#out + 1] = s[i]
    end
    return out
end

function MetadataTransformer:injectClassTypeMetadata(list, node)
    local metadata = self:getTypeMetadata(node, node)
    if core.Len(metadata) > 0 then
        local originalNodes
        if list ~= nil then
            originalNodes = list.nodes
        end
        if core.Len(originalNodes) == 0 then
            local res = self:Factory():NewModifierList(metadata)
            if list ~= nil then
                res.loc = list.loc
            end
            return res
        end
        local modifiersArray = {}
        if ast.IsModifier(originalNodes[1]) and (originalNodes[1].kind == Kind.DefaultKeyword or originalNodes[1].kind == Kind.ExportKeyword) then
            modifiersArray[#modifiersArray + 1] = originalNodes[1]
            if #originalNodes > 1 and (originalNodes[2].kind == Kind.DefaultKeyword or originalNodes[2].kind == Kind.ExportKeyword) then
                modifiersArray[#modifiersArray + 1] = originalNodes[2]
            end
        end
        local restStart = #modifiersArray
        local decos = core.Filter(originalNodes, ast.IsDecorator)
        modifiersArray = core.AppendAll(modifiersArray, decos)
        modifiersArray = core.AppendAll(modifiersArray, metadata)
        local otherModifiers = core.Filter(sliceFrom(originalNodes, restStart), ast.IsModifier)
        modifiersArray = core.AppendAll(modifiersArray, otherModifiers)
        local res = self:Factory():NewModifierList(modifiersArray)
        res.loc = list.loc
        return res
    end
    return list
end

function MetadataTransformer:injectClassElementTypeMetadata(list, node, container)
    if not ast.IsClassLike(container) then
        return list
    end
    if not ast.ClassElementOrClassElementParameterIsDecorated(self.legacyDecorators, node, container) then
        return list
    end
    local metadata = self:getTypeMetadata(node, container)
    if core.Len(metadata) > 0 then
        local originalNodes
        if list ~= nil then
            originalNodes = list.nodes
        end
        if core.Len(originalNodes) == 0 then
            local res = self:Factory():NewModifierList(metadata)
            if list ~= nil then
                res.loc = list.loc
            end
            return res
        end
        local modifiersArray = {}
        local decos = core.Filter(originalNodes, ast.IsDecorator)
        modifiersArray = core.AppendAll(modifiersArray, decos)
        modifiersArray = core.AppendAll(modifiersArray, metadata)
        local modifiers = core.Filter(originalNodes, ast.IsModifier)
        modifiersArray = core.AppendAll(modifiersArray, modifiers)
        local res = self:Factory():NewModifierList(modifiersArray)
        res.loc = list.loc
        return res
    end
    return list
end

--[[*
 * Gets optional type metadata for a declaration.
 *
 * @param node The declaration node.
 ]]
function MetadataTransformer:getTypeMetadata(node, container)
    -- Decorator metadata is not yet supported for ES decorators.
    if not self.legacyDecorators then
        return nil
    end
    if tstransforms.USE_NEW_TYPE_METADATA_FORMAT then
        return self:getNewTypeMetadata(node, container)
    end
    return self:getOldTypeMetadata(node, container)
end

function MetadataTransformer:getOldTypeMetadata(node, container)
    local decorators = nil
    if self:shouldAddTypeMetadata(node) then
        local typeMetadata = self:Factory():NewMetadataHelper("design:type", self.serializer:SerializeTypeOfNode({ currentLexicalScope = self.currentLexicalScope, currentNameScope = container, serializingConditionalTypeBranch = false }, node, container))
        decorators = core.Append(decorators, self:Factory():NewDecorator(typeMetadata))
    end
    if self:shouldAddParamTypesMetadata(node) then
        local paramTypesMetadata = self:Factory():NewMetadataHelper("design:paramtypes", self.serializer:SerializeParameterTypesOfNode({ currentLexicalScope = self.currentLexicalScope, currentNameScope = container, serializingConditionalTypeBranch = false }, node, container))
        decorators = core.Append(decorators, self:Factory():NewDecorator(paramTypesMetadata))
    end
    if self:shouldAddReturnTypeMetadata(node) then
        local returnTypeMetadata = self:Factory():NewMetadataHelper("design:returntype", self.serializer:SerializeReturnTypeOfNode({ currentLexicalScope = self.currentLexicalScope, currentNameScope = container, serializingConditionalTypeBranch = false }, node))
        decorators = core.Append(decorators, self:Factory():NewDecorator(returnTypeMetadata))
    end
    return decorators
end

function MetadataTransformer:getNewTypeMetadata(node, container)
    local properties = nil
    if self:shouldAddTypeMetadata(node) then
        properties = core.Append(properties, self:Factory():NewPropertyAssignment(
            nil,
            self:Factory():NewIdentifier("type"),
            nil,
            nil,
            self:Factory():NewArrowFunction(
                nil,
                nil,
                self:Factory():NewNodeList({}),
                nil,
                nil,
                self:Factory():NewToken(Kind.EqualsGreaterThanToken),
                self.serializer:SerializeTypeOfNode({ currentLexicalScope = self.currentLexicalScope, currentNameScope = container, serializingConditionalTypeBranch = false }, node, container)
            )
        ))
    end
    if self:shouldAddParamTypesMetadata(node) then
        properties = core.Append(properties, self:Factory():NewPropertyAssignment(
            nil,
            self:Factory():NewIdentifier("paramTypes"),
            nil,
            nil,
            self:Factory():NewArrowFunction(
                nil,
                nil,
                self:Factory():NewNodeList({}),
                nil,
                nil,
                self:Factory():NewToken(Kind.EqualsGreaterThanToken),
                self.serializer:SerializeParameterTypesOfNode({ currentLexicalScope = self.currentLexicalScope, currentNameScope = container, serializingConditionalTypeBranch = false }, node, container)
            )
        ))
    end
    if self:shouldAddReturnTypeMetadata(node) then
        properties = core.Append(properties, self:Factory():NewPropertyAssignment(
            nil,
            self:Factory():NewIdentifier("returnType"),
            nil,
            nil,
            self:Factory():NewArrowFunction(
                nil,
                nil,
                self:Factory():NewNodeList({}),
                nil,
                nil,
                self:Factory():NewToken(Kind.EqualsGreaterThanToken),
                self.serializer:SerializeReturnTypeOfNode({ currentLexicalScope = self.currentLexicalScope, currentNameScope = container, serializingConditionalTypeBranch = false }, node)
            )
        ))
    end
    if core.Len(properties) > 0 then
        local typeInfoMetadata = self:Factory():NewMetadataHelper("design:typeinfo", self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList(properties), true))
        return { self:Factory():NewDecorator(typeInfoMetadata) }
    end
    return nil
end

--[[*
* Determines whether to emit the "design:type" metadata based on the node's kind.
* The caller should have already tested whether the node has decorators and whether the
* emitDecoratorMetadata compiler option is set.
*
* @param node The node to test.
 ]]
function MetadataTransformer:shouldAddTypeMetadata(node)
    local kind = node.kind
    if kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.PropertyDeclaration then
        return true
    end
    return false
end

--[[*
* Determines whether to emit the "design:returntype" metadata based on the node's kind.
* The caller should have already tested whether the node has decorators and whether the
* emitDecoratorMetadata compiler option is set.
*
* @param node The node to test.
 ]]
function MetadataTransformer:shouldAddReturnTypeMetadata(node)
    return node.kind == Kind.MethodDeclaration
end

--[[*
* Determines whether to emit the "design:paramtypes" metadata based on the node's kind.
* The caller should have already tested whether the node has decorators and whether the
* emitDecoratorMetadata compiler option is set.
*
* @param node The node to test.
 ]]
function MetadataTransformer:shouldAddParamTypesMetadata(node)
    local kind = node.kind
    if kind == Kind.ClassDeclaration or kind == Kind.ClassExpression then
        return ast.GetFirstConstructorWithBody(node) ~= nil
    elseif kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor then
        return true
    end
    return false
end
