local parser = require("tslua.parser")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local PC = parser.ParsingContext
local Parser = parser.Parser

function Parser:finishReparsedNode(node, locationNode)
    node.flags = self.contextFlags | NodeFlags.Reparsed
    node.loc = locationNode.loc
    self:overrideParentInImmediateChildren(node)
end

function Parser:finishMutatedNode(node)
    self:overrideParentInImmediateChildren(node)
end

-- Deep-clone the given node and add the clone to the reparsed clone list. The list is used by ast.GetReparsedNodeForNode
-- to locate reparsed clones of JSDoc nodes. Since the binder attaches symbols to reparsed nodes and not to JSDoc nodes, we
-- need the mapping when obtaining symbols and types from JSDoc nodes.
function Parser:addDeepCloneReparse(node)
    local clone = self.factory:DeepCloneReparse(node)
    if clone ~= nil then
        self.reparsedClones[#self.reparsedClones + 1] = clone
    end
    return clone
end

function Parser:addTransformedReparse(newNode, old)
    self:finishReparsedNode(newNode, old)
    newNode.flags = newNode.flags | NodeFlags.ReparserTransformedLiteral
    self.reparsedClones[#self.reparsedClones + 1] = newNode
    return newNode
end

function Parser:checkNonIdentifierName(name)
    if ast.IsIdentifier(name) and not scanner.IsValidIdentifier(name:AsIdentifier().text) then
        local errLoc = name.loc
        if errLoc:Len() == 0 then -- missing name, emit error on the character before the missing name node
            errLoc = core.NewTextRange(name.loc:Pos() - 1, name.loc:Pos())
        end
        self:parseErrorAtRange(errLoc, diagnostics.Identifier_expected)
    end
    return name
end

-- Hosted tags find a host and add their children to the correct location under the host.
-- Unhosted tags add synthetic nodes to the reparse list.
function Parser:reparseTags(parent, jsDoc)
    for _, j in ipairs(jsDoc) do
        local isLast = j == jsDoc[#jsDoc]
        local tags = j:AsJSDoc().tags
        if tags ~= nil then
            for _, tag in ipairs(tags.nodes) do
                self:reparseUnhosted(tag, parent, j)
                if isLast then
                    self:reparseHosted(tag, parent, j)
                end
            end
        end
    end
end

function Parser:reparseUnhosted(tag, parent, jsDoc)
    local p = self
    local k = tag.kind
    if k == Kind.JSDocTypedefTag then
        local typeExpression = tag:TypeExpression()
        if typeExpression == nil then
            return
        end
        local fullName = tag:Name()
        local isNamespace = fullName ~= nil and ast.IsModuleDeclaration(fullName)
        local modifiers = nil
        if isNamespace then
            modifiers = p:createExportModifier(tag)
        end
        local typeAlias = p.factory:NewJSTypeAliasDeclaration(modifiers, p:addDeepCloneReparse(p:checkNonIdentifierName(p:getInnermostNameOfJSDocNamespace(fullName))), nil, nil)
        typeAlias:AsTypeAliasDeclaration().typeParameters = p:gatherTypeParameters(jsDoc, true --[[typedefOrCallback]])
        local t
        if typeExpression.kind == Kind.JSDocTypeExpression then
            t = p:addDeepCloneReparse(typeExpression:Type())
        elseif typeExpression.kind == Kind.JSDocTypeLiteral then
            t = p:reparseJSDocTypeLiteral(typeExpression)
        else
            error("typedef tag type expression should be a name reference or a type expression" .. ast.Kind_names[typeExpression.kind], 0)
        end
        typeAlias:AsTypeAliasDeclaration().type = t
        p:finishReparsedNode(typeAlias, tag)
        p.jsdocInfos[#p.jsdocInfos + 1] = { parent = typeAlias, jsDocs = { jsDoc } }
        typeAlias.flags = typeAlias.flags | NodeFlags.HasJSDoc
        local result = p:wrapInJSDocNamespace(fullName, typeAlias, false --[[nested]])
        p.reparseList = parser.append(p.reparseList, result)
    elseif k == Kind.JSDocCallbackTag then
        local typeExpression = tag:TypeExpression()
        if typeExpression == nil then
            return
        end
        local fullName = tag:Name()
        local isNamespace = fullName ~= nil and ast.IsModuleDeclaration(fullName)
        local modifiers = nil
        if isNamespace then
            modifiers = p:createExportModifier(tag)
        end
        local functionType = p:reparseJSDocSignature(typeExpression, tag, jsDoc, tag, nil)
        local typeAlias = p.factory:NewJSTypeAliasDeclaration(modifiers, p:addDeepCloneReparse(p:getInnermostNameOfJSDocNamespace(fullName)), nil, functionType)
        typeAlias:AsTypeAliasDeclaration().typeParameters = p:gatherTypeParameters(jsDoc, true --[[typedefOrCallback]])
        p:finishReparsedNode(typeAlias, tag)
        p.jsdocInfos[#p.jsdocInfos + 1] = { parent = typeAlias, jsDocs = { jsDoc } }
        typeAlias.flags = typeAlias.flags | NodeFlags.HasJSDoc
        local result = p:wrapInJSDocNamespace(fullName, typeAlias, false --[[nested]])
        p.reparseList = parser.append(p.reparseList, result)
    elseif k == Kind.JSDocImportTag then
        local importTag = tag:AsJSDocImportTag()
        if importTag.importClause == nil then
            return
        end
        local importClause = p:addDeepCloneReparse(importTag.importClause)
        importClause:AsImportClause().phaseModifier = Kind.TypeKeyword
        local importDeclaration = p.factory:NewJSImportDeclaration(
            p.factory:DeepCloneReparseModifiers(importTag:Modifiers()),
            importClause,
            p:addDeepCloneReparse(importTag.moduleSpecifier),
            p:addDeepCloneReparse(importTag.attributes)
        )
        p:finishReparsedNode(importDeclaration, tag)
        p.reparseList = parser.append(p.reparseList, importDeclaration)
    elseif k == Kind.JSDocOverloadTag then
        -- Create overload signatures only for function, method, and constructor declarations outside object literals
        if (ast.IsFunctionDeclaration(parent) or ast.IsMethodDeclaration(parent) or ast.IsConstructorDeclaration(parent)) and p.parsingContexts & (1 << PC.PCObjectLiteralMembers) == 0 then
            p.reparseList = parser.append(p.reparseList, p:reparseJSDocSignature(tag:AsJSDocOverloadTag().typeExpression, parent, jsDoc, tag, parent:Modifiers()))
        end
    end
end

local function sanitizeParameterName(text, pi)
    -- drop invalid chars for _, if empty, write _0, etc., so we have a valid param name to emit later
    local result = {}
    local pos = 0
    local first = true
    while pos < #text do
        local ch, size = stringutil.DecodeRune(text, pos)
        if first then
            first = false
            if not scanner.IsIdentifierStart(ch) then
                result[#result + 1] = "_"
            else
                result[#result + 1] = utf8.char(ch)
            end
        elseif not scanner.IsIdentifierPart(ch) then
            result[#result + 1] = "_"
        else
            result[#result + 1] = utf8.char(ch)
        end
        pos = pos + size
    end
    if #result == 0 then
        result[#result + 1] = "_"
        result[#result + 1] = tostring(pi)
    end
    return table.concat(result)
end

function Parser:reparseJSDocSignature(jsSignature, fun, jsDoc, tag, modifiers)
    local p = self
    local signature
    local clonedModifiers = p.factory:DeepCloneReparseModifiers(modifiers)
    local fk = fun.kind
    if fk == Kind.FunctionDeclaration then
        signature = p.factory:NewFunctionDeclaration(clonedModifiers, nil, p.factory:DeepCloneReparse(p:checkNonIdentifierName(fun:Name())), nil, nil, nil, nil, nil)
    elseif fk == Kind.MethodDeclaration then
        signature = p.factory:NewMethodDeclaration(clonedModifiers, nil, p.factory:DeepCloneReparse(p:checkNonIdentifierName(fun:Name())), nil, nil, nil, nil, nil, nil)
    elseif fk == Kind.Constructor then
        signature = p.factory:NewConstructorDeclaration(clonedModifiers, nil, nil, nil, nil, nil)
    elseif fk == Kind.JSDocCallbackTag then
        signature = p.factory:NewFunctionTypeNode(nil, nil, p.factory:NewKeywordTypeNode(Kind.AnyKeyword))
    else
        error("Unexpected kind " .. ast.Kind_names[fk], 0)
    end

    if tag.kind ~= Kind.JSDocCallbackTag then
        signature.typeParameters = p:gatherTypeParameters(jsDoc, false --[[typedefOrCallback]])
    end
    local parameters = {}
    for pi1, param in ipairs(jsSignature:Parameters()) do
        local pi = pi1 - 1
        local parameter
        if param.kind == Kind.JSDocThisTag then
            local thisTag = param:AsJSDocThisTag()
            local thisIdent = p.factory:NewIdentifier("this")
            thisIdent.loc = thisTag.loc
            thisIdent.flags = p.contextFlags | NodeFlags.Reparsed
            parameter = p.factory:NewParameterDeclaration(nil, nil, thisIdent, nil, nil, nil)
            if thisTag.typeExpression ~= nil then
                parameter:AsParameterDeclaration().type = p:addDeepCloneReparse(thisTag.typeExpression:Type())
            end
        elseif param.kind == Kind.JSDocParameterTag or param.kind == Kind.JSDocPropertyTag then
            local jsparam = param:AsJSDocParameterOrPropertyTag()
            -- Skip sub-property parameters (e.g., @param x.y) - these have QualifiedNames
            -- and describe properties of a parent parameter, not standalone parameters.
            if ast.IsQualifiedName(jsparam:Name()) then
                goto continue
            end
            local dotDotDotToken = nil
            local paramType = nil

            if jsparam.typeExpression ~= nil then
                if jsparam.typeExpression:Type().kind == Kind.JSDocVariadicType then
                    dotDotDotToken = p.factory:NewToken(Kind.DotDotDotToken)
                    dotDotDotToken.loc = jsparam.loc
                    dotDotDotToken.flags = p.contextFlags | NodeFlags.Reparsed

                    local variadicType = jsparam.typeExpression:Type():AsJSDocVariadicType()
                    paramType = p:reparseJSDocTypeLiteral(variadicType.type)
                else
                    paramType = p:reparseJSDocTypeLiteral(jsparam.typeExpression:Type())
                end
            end
            local name = jsparam:Name()
            if ast.IsIdentifier(name) and not scanner.IsValidIdentifier(name:AsIdentifier().text) then
                name = p:addTransformedReparse(p.factory:NewIdentifier(sanitizeParameterName(name:AsIdentifier().text, pi)), name)
            else
                name = p:addDeepCloneReparse(name)
            end
            parameter = p.factory:NewParameterDeclaration(nil, dotDotDotToken, name, p:makeQuestionIfOptional(jsparam), paramType, nil)
        end
        p:finishReparsedNode(parameter, param)
        parameters[#parameters + 1] = parameter
        p:reparseJSDocComment(parameter, param)
        ::continue::
    end
    signature.parameters = p:newNodeList(jsSignature:AsJSDocSignature().parameters.loc, parameters)

    if jsSignature:Type() ~= nil and jsSignature:Type():TypeExpression() ~= nil then
        signature.type = p:addDeepCloneReparse(jsSignature:Type():TypeExpression():Type())
    end
    local loc = jsSignature
    if tag.kind == Kind.JSDocOverloadTag then
        loc = tag:TagName()
    end
    p:finishReparsedNode(signature, loc)
    return signature
end

function Parser:reparseJSDocTypeLiteral(t)
    local p = self
    if t == nil then
        return nil
    end
    if t.kind == Kind.JSDocTypeLiteral then
        local jstypeliteral = t:AsJSDocTypeLiteral()
        local isArrayType = jstypeliteral.isArrayType
        local properties = {}
        for _, prop in ipairs(jstypeliteral.jsDocPropertyTags or {}) do
            if prop.kind == Kind.JSDocPropertyTag or prop.kind == Kind.JSDocParameterTag then
                local jsprop = prop:AsJSDocParameterOrPropertyTag()
                local name = prop:Name()
                if name.kind == Kind.QualifiedName then
                    name = name:AsQualifiedName().right
                end
                if ast.IsIdentifier(name) and not scanner.IsValidIdentifier(name:AsIdentifier().text) then
                    name = p:addTransformedReparse(p.factory:NewStringLiteral(name:AsIdentifier().text, ast.TokenFlags.None), name)
                else
                    name = p:addDeepCloneReparse(name)
                end
                local property = p.factory:NewPropertySignatureDeclaration(nil, name, p:makeQuestionIfOptional(jsprop), nil, nil)
                if jsprop.typeExpression ~= nil then
                    property:AsPropertySignatureDeclaration().type = p:reparseJSDocTypeLiteral(jsprop.typeExpression:Type())
                end
                p:finishReparsedNode(property, prop)
                properties[#properties + 1] = property
                p:reparseJSDocComment(property, prop)
            end
        end
        t = p.factory:NewTypeLiteralNode(p:newNodeList(jstypeliteral.loc, properties))
        if isArrayType then
            p:finishReparsedNode(t, jstypeliteral)
            t = p.factory:NewArrayTypeNode(t)
        end
        p:finishReparsedNode(t, jstypeliteral)
        return t
    end
    return p:addDeepCloneReparse(t)
end

function Parser:reparseJSDocComment(node, tag)
    local p = self
    local comment = tag:CommentList()
    if comment ~= nil then
        local clonedNodes = {}
        for i, c in ipairs(comment.nodes) do
            clonedNodes[i] = p.factory:DeepCloneReparse(c)
        end
        local newComment = p.factory:NewNodeList(clonedNodes)
        newComment.loc = comment.loc
        local propJSDoc = p.factory:NewJSDoc(newComment, nil)
        p:finishReparsedNode(propJSDoc, tag)
        propJSDoc.parent = node
        p.jsdocInfos[#p.jsdocInfos + 1] = { parent = node, jsDocs = { propJSDoc } }
        node.flags = node.flags | NodeFlags.HasJSDoc
    end
end

function Parser:gatherTypeParameters(j, typedefOrCallback)
    local p = self
    local typeParameters = nil
    local pos = -1
    local endPos = -1
    local firstTemplate = true
    for _, tag in ipairs(j:AsJSDoc().tags.nodes) do
        -- When a JSDoc comment contains an `@typedef` or `@callback` tag, `@template` type parameter
        -- declarations apply to the type being defined.
        if not typedefOrCallback and (ast.IsJSDocTypedefTag(tag) or ast.IsJSDocCallbackTag(tag)) then
            return nil
        end
        if ast.IsJSDocTemplateTag(tag) then
            if firstTemplate then
                pos = tag:Pos()
                firstTemplate = false
            end
            endPos = tag:End()
            local constraint = tag:AsJSDocTemplateTag().constraint
            local firstTypeParameter = true
            for _, tp in ipairs(tag:TypeParameters()) do
                local reparse
                if constraint ~= nil and firstTypeParameter then
                    reparse = p.factory:NewTypeParameterDeclaration(
                        p.factory:DeepCloneReparseModifiers(tp:Modifiers()),
                        p:addDeepCloneReparse(p:checkNonIdentifierName(tp:Name())),
                        p:addDeepCloneReparse(constraint:Type()),
                        nil, -- expression
                        p:addDeepCloneReparse(tp:AsTypeParameterDeclaration().defaultType)
                    )
                    p:finishReparsedNode(reparse, tp)
                else
                    reparse = p:addDeepCloneReparse(tp)
                end
                typeParameters = parser.append(typeParameters, reparse)
                firstTypeParameter = false
            end
        end
    end
    if typeParameters == nil or #typeParameters == 0 then
        return nil
    else
        return p:newNodeList(core.NewTextRange(pos, endPos), typeParameters)
    end
end

local typeTagHostKinds = {
    [Kind.VariableDeclaration] = true, [Kind.ExportAssignment] = true, [Kind.PropertyDeclaration] = true,
    [Kind.PropertyAssignment] = true, [Kind.ShorthandPropertyAssignment] = true, [Kind.GetAccessor] = true,
}

local function isImplementsClause(node)
    return node:AsHeritageClause().token == Kind.ImplementsKeyword
end

local function isExtendsClause(node)
    return node:AsHeritageClause().token == Kind.ExtendsKeyword
end

local function hasNoType(param)
    return param:Type() == nil
end

function Parser:reparseHosted(tag, parent, jsDoc)
    local p = self
    local k = tag.kind
    if k == Kind.JSDocTypeTag then
        local pk = parent.kind
        if pk == Kind.VariableStatement then
            if parent:AsVariableStatement().declarationList ~= nil then
                for _, declaration in ipairs(parent:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes) do
                    if declaration:Type() == nil and tag:TypeExpression() ~= nil then
                        declaration:AsMutable():SetType(p:addDeepCloneReparse(tag:TypeExpression():Type()))
                        p:finishMutatedNode(declaration)
                        return
                    end
                end
            end
        elseif typeTagHostKinds[pk] then
            if parent:Type() == nil and tag:TypeExpression() ~= nil then
                parent:AsMutable():SetType(p:addDeepCloneReparse(tag:TypeExpression():Type()))
                p:finishMutatedNode(parent)
                return
            end
        elseif pk == Kind.Parameter then
            if parent:Type() == nil and tag:TypeExpression() ~= nil then
                parent:AsMutable():SetType(p:reparseJSDocTypeLiteral(tag:TypeExpression():Type()))
                p:finishMutatedNode(parent)
                return
            end
        elseif pk == Kind.ExpressionStatement then
            if parent:Expression().kind == Kind.BinaryExpression then
                local bin = parent:Expression():AsBinaryExpression()
                local kind = ast.GetAssignmentDeclarationKind(bin)
                if kind ~= ast.JSDeclarationKind.None and tag:TypeExpression() ~= nil then
                    bin:AsMutable():SetType(p:addDeepCloneReparse(tag:TypeExpression():Type()))
                    p:finishMutatedNode(bin)
                    return
                end
            end
        elseif pk == Kind.ReturnStatement or pk == Kind.ParenthesizedExpression then
            if parent:Expression() ~= nil and tag:TypeExpression() ~= nil then
                parent:AsMutable():SetExpression(p:makeNewCast(
                    p:addDeepCloneReparse(tag:TypeExpression():Type()),
                    parent:Expression(),
                    true --[[isAssertion]]
                ))
                p:finishMutatedNode(parent)
                return
            end
        end
        local fun = parser.getFunctionLikeHost(parent)
        if fun ~= nil then
            local noTypedParams = core.Every(fun:Parameters(), hasNoType)
            if fun:TypeParameterList() == nil and fun:Type() == nil and noTypedParams and tag:TypeExpression() ~= nil then
                fun.fullSignature = p:addDeepCloneReparse(tag:TypeExpression():Type())
                p:finishMutatedNode(fun)
            end
        end
    elseif k == Kind.JSDocSatisfiesTag then
        local pk = parent.kind
        if pk == Kind.VariableStatement then
            if parent:AsVariableStatement().declarationList ~= nil then
                for _, declaration in ipairs(parent:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes) do
                    if declaration:Initializer() ~= nil and tag:TypeExpression() ~= nil then
                        declaration:AsMutable():SetInitializer(p:makeNewCast(
                            p:addDeepCloneReparse(tag:TypeExpression():Type()),
                            declaration:Initializer(),
                            false --[[isAssertion]]
                        ))
                        p:finishMutatedNode(declaration)
                        break
                    end
                end
            end
        elseif pk == Kind.VariableDeclaration or pk == Kind.PropertyDeclaration or pk == Kind.PropertyAssignment then
            if parent:Initializer() ~= nil and tag:TypeExpression() ~= nil then
                parent:AsMutable():SetInitializer(p:makeNewCast(
                    p:addDeepCloneReparse(tag:TypeExpression():Type()),
                    parent:Initializer(),
                    false --[[isAssertion]]
                ))
                p:finishMutatedNode(parent)
            end
        elseif pk == Kind.ShorthandPropertyAssignment then
            local shorthand = parent:AsShorthandPropertyAssignment()
            if shorthand.objectAssignmentInitializer ~= nil and tag:AsJSDocSatisfiesTag().typeExpression ~= nil then
                shorthand.objectAssignmentInitializer = p:makeNewCast(
                    p:addDeepCloneReparse(tag:AsJSDocSatisfiesTag().typeExpression:Type()),
                    shorthand.objectAssignmentInitializer,
                    false --[[isAssertion]]
                )
                p:finishMutatedNode(parent)
            end
        elseif pk == Kind.ReturnStatement or pk == Kind.ParenthesizedExpression or pk == Kind.ExportAssignment then
            if parent:Expression() ~= nil and tag:TypeExpression() ~= nil then
                parent:AsMutable():SetExpression(p:makeNewCast(
                    p:addDeepCloneReparse(tag:TypeExpression():Type()),
                    parent:Expression(),
                    false --[[isAssertion]]
                ))
                p:finishMutatedNode(parent)
            end
        elseif pk == Kind.ExpressionStatement then
            if parent:Expression().kind == Kind.BinaryExpression then
                local bin = parent:Expression():AsBinaryExpression()
                local kind = ast.GetAssignmentDeclarationKind(bin)
                if kind ~= ast.JSDeclarationKind.None and tag:TypeExpression() ~= nil then
                    bin.right = p:makeNewCast(
                        p:addDeepCloneReparse(tag:TypeExpression():Type()),
                        bin.right,
                        false --[[isAssertion]]
                    )
                    p:finishMutatedNode(bin)
                end
            end
        end
    elseif k == Kind.JSDocTemplateTag then
        local fun = parser.getFunctionLikeHost(parent)
        if fun ~= nil then
            if fun:TypeParameters() == nil and fun.fullSignature == nil then
                fun.typeParameters = p:gatherTypeParameters(jsDoc, false --[[typedefOrCallback]])
                p:finishMutatedNode(fun)
            end
        elseif parent.kind == Kind.ClassDeclaration then
            local class = parent:AsClassDeclaration()
            if class.typeParameters == nil then
                class.typeParameters = p:gatherTypeParameters(jsDoc, false --[[typedefOrCallback]])
                p:finishMutatedNode(parent)
            end
        elseif parent.kind == Kind.ClassExpression then
            local class = parent:AsClassExpression()
            if class.typeParameters == nil then
                class.typeParameters = p:gatherTypeParameters(jsDoc, false --[[typedefOrCallback]])
                p:finishMutatedNode(parent)
            end
        end
    elseif k == Kind.JSDocParameterTag then
        local fun = parser.getFunctionLikeHost(parent)
        if fun ~= nil and fun.fullSignature == nil then
            local parameterTag = tag:AsJSDocParameterOrPropertyTag()
            local param, ok = parser.findMatchingParameter(fun, parameterTag, jsDoc)
            if ok then
                if param.type == nil and parameterTag.typeExpression ~= nil then
                    param:AsParameterDeclaration().type = p:reparseJSDocTypeLiteral(parameterTag.typeExpression:Type())
                end
                if param.questionToken == nil then
                    local question = p:makeQuestionIfOptional(parameterTag)
                    if question ~= nil then
                        param.questionToken = question
                    end
                end
                p:finishMutatedNode(param)
            end
        end
    elseif k == Kind.JSDocThisTag then
        local fun = parser.getFunctionLikeHost(parent)
        if fun ~= nil then
            local params = fun:Parameters()
            if #params == 0 or (params[1]:Name().kind ~= Kind.ThisKeyword and not ast.IsThisIdentifier(params[1]:Name())) then
                local thisParam = p.factory:NewParameterDeclaration(
                    nil, --[[ decorators ]]
                    nil, --[[ modifiers ]]
                    p.factory:NewIdentifier("this"),
                    nil, --[[ questionToken ]]
                    nil, --[[ type ]]
                    nil --[[ initializer ]]
                )
                if tag:AsJSDocThisTag().typeExpression ~= nil then
                    thisParam:AsParameterDeclaration().type = p:addDeepCloneReparse(tag:AsJSDocThisTag().typeExpression:Type())
                end
                p:finishReparsedNode(thisParam, tag:TagName())

                local newParams = { thisParam }
                for i, param in ipairs(params) do
                    newParams[i + 1] = param
                end

                fun.parameters = p:newNodeList(fun:ParameterList().loc, newParams)
                p:finishMutatedNode(fun)
            end
        end
    elseif k == Kind.JSDocReturnTag then
        local fun = parser.getFunctionLikeHost(parent)
        if fun ~= nil and fun.fullSignature == nil then
            if fun:Type() == nil and tag:TypeExpression() ~= nil then
                fun.type = p:addDeepCloneReparse(tag:TypeExpression():Type())
                p:finishMutatedNode(fun)
            end
        end
    elseif k == Kind.JSDocReadonlyTag or k == Kind.JSDocPrivateTag or k == Kind.JSDocPublicTag or k == Kind.JSDocProtectedTag or k == Kind.JSDocOverrideTag then
        if parent.kind == Kind.ExpressionStatement then
            parent = parent:Expression()
        end
        local pk = parent.kind
        if pk == Kind.MethodDeclaration or pk == Kind.GetAccessor or pk == Kind.SetAccessor then
            -- In object literals these aren't class-like members, so JSDoc modifiers like @override
            -- or @readonly aren't real modifiers there; reparsing them produces spurious grammar errors (#4437).
            if p.parsingContexts & (1 << PC.PCObjectLiteralMembers) ~= 0 then
                return
            end
        end
        if pk == Kind.MethodDeclaration or pk == Kind.GetAccessor or pk == Kind.SetAccessor or
            pk == Kind.PropertyDeclaration or pk == Kind.Constructor or pk == Kind.BinaryExpression then
            local keyword
            if k == Kind.JSDocReadonlyTag then
                keyword = Kind.ReadonlyKeyword
            elseif k == Kind.JSDocPrivateTag then
                keyword = Kind.PrivateKeyword
            elseif k == Kind.JSDocPublicTag then
                keyword = Kind.PublicKeyword
            elseif k == Kind.JSDocProtectedTag then
                keyword = Kind.ProtectedKeyword
            elseif k == Kind.JSDocOverrideTag then
                keyword = Kind.OverrideKeyword
            end
            local modifier = p.factory:NewModifier(keyword)
            modifier.loc = tag.loc
            modifier.flags = p.contextFlags | NodeFlags.Reparsed
            local nodes
            local loc
            if parent:Modifiers() == nil then
                nodes = { modifier }
                loc = tag.loc
            else
                nodes = {}
                for i, m in ipairs(parent:ModifierNodes()) do
                    nodes[i] = m
                end
                nodes[#nodes + 1] = modifier
                loc = parent:Modifiers().loc
            end
            parent:AsMutable():SetModifiers(p:newModifierList(loc, nodes))
            p:finishMutatedNode(parent)
        end
    elseif k == Kind.JSDocImplementsTag then
        local class = parser.getClassLikeData(parent)
        if class ~= nil then
            local implementsTag = tag:AsJSDocImplementsTag()

            if class.heritageClauses ~= nil then
                local implementsClause = core.Find(class.heritageClauses.nodes, isImplementsClause)
                if implementsClause ~= nil then
                    local types = implementsClause:AsHeritageClause().types
                    types.nodes[#types.nodes + 1] = p:addDeepCloneReparse(implementsTag.className)
                    p:finishMutatedNode(implementsClause)
                    return
                end
            end
            local typesList = p:newNodeList(implementsTag.className.loc, { p:addDeepCloneReparse(implementsTag.className) })

            local heritageClause = p.factory:NewHeritageClause(Kind.ImplementsKeyword, typesList)
            p:finishReparsedNode(heritageClause, implementsTag.className)

            if class.heritageClauses == nil then
                local heritageClauses = p:newNodeList(implementsTag.className.loc, { heritageClause })
                class.heritageClauses = heritageClauses
            else
                class.heritageClauses.nodes[#class.heritageClauses.nodes + 1] = heritageClause
            end
            p:finishMutatedNode(parent)
        end
    elseif k == Kind.JSDocAugmentsTag then
        local class = parser.getClassLikeData(parent)
        if class ~= nil and class.heritageClauses ~= nil then
            local extendsClause = core.Find(class.heritageClauses.nodes, isExtendsClause)
            if extendsClause ~= nil and #extendsClause:AsHeritageClause().types.nodes == 1 then
                local target = extendsClause:AsHeritageClause().types.nodes[1]:AsExpressionWithTypeArguments()
                local source = tag:ClassName():AsExpressionWithTypeArguments()
                if ast.HasSamePropertyAccessName(target.expression, source.expression) then
                    if target.typeArguments == nil and source.typeArguments ~= nil then
                        local newArguments = {}
                        for i, arg in ipairs(source.typeArguments.nodes) do
                            newArguments[i] = p:addDeepCloneReparse(arg)
                        end
                        target.typeArguments = p:newNodeList(source.typeArguments.loc, newArguments)
                        p:finishMutatedNode(target)
                    end
                end
            end
        end
    end
end

function Parser:makeQuestionIfOptional(parameter)
    local questionToken = nil
    if parameter.isBracketed or parameter.typeExpression ~= nil and parameter.typeExpression:Type().kind == Kind.JSDocOptionalType then
        questionToken = self.factory:NewToken(Kind.QuestionToken)
        questionToken.loc = parameter.loc
        questionToken.flags = self.contextFlags | NodeFlags.Reparsed
    end
    return questionToken
end

function parser.findMatchingParameter(fun, parameterTag, jsDoc)
    local tagIndex = -1
    local paramCount = -1
    for _, tag in ipairs(jsDoc:AsJSDoc().tags.nodes) do
        if tag.kind == Kind.JSDocParameterTag then
            paramCount = paramCount + 1
            if tag:AsJSDocParameterOrPropertyTag() == parameterTag then
                tagIndex = paramCount
                break
            end
        end
    end
    for parameterIndex1, parameter in ipairs(fun:Parameters()) do
        local parameterIndex = parameterIndex1 - 1
        if parameter:Name().kind == Kind.Identifier then
            if parameterTag:Name().kind == Kind.Identifier and
                ((parameter:Name():Text() == parameterTag:Name():Text()) or (parameterIndex == tagIndex and #parameterTag:Name():Text() == 0)) then
                return parameter:AsParameterDeclaration(), true
            end
        elseif parameterIndex == tagIndex then
            return parameter:AsParameterDeclaration(), true
        end
    end
    return nil, false
end

function parser.skipSatisfiesExpressions(node)
    while node ~= nil and node.kind == Kind.SatisfiesExpression do
        node = node:Expression()
    end
    return node
end

function parser.getFunctionLikeHost(host)
    local fun = host
    local k = host.kind
    if k == Kind.VariableStatement then
        local nodes = host:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes
        if #nodes ~= 0 then
            fun = nodes[1]:Initializer()
        end
    elseif k == Kind.PropertyAssignment or k == Kind.PropertyDeclaration then
        fun = host:Initializer()
    elseif k == Kind.ExportAssignment or k == Kind.ReturnStatement then
        fun = host:Expression()
    elseif k == Kind.ExpressionStatement then
        fun = ast.GetRightMostAssignedExpression(host:Expression())
    end
    fun = parser.skipSatisfiesExpressions(fun)
    if ast.IsFunctionLike(fun) then
        return fun
    end
    return nil
end

function Parser:makeNewCast(t, e, isAssertion)
    local assert_
    if isAssertion then
        assert_ = self.factory:NewAsExpression(e, t)
    else
        assert_ = self.factory:NewSatisfiesExpression(e, t)
    end
    self:finishNodeWithEnd(assert_, e:Pos(), e:End())
    return assert_
end

-- Go *ast.ClassLikeBase: class-like data is flattened onto the node itself.
function parser.getClassLikeData(parent)
    local class = nil
    if parent.kind == Kind.ClassDeclaration then
        class = parent:AsClassDeclaration()
    elseif parent.kind == Kind.ClassExpression then
        class = parent:AsClassExpression()
    end
    return class
end

function Parser:createExportModifier(locationNode)
    local exportModifier = self.factory:NewModifier(Kind.ExportKeyword)
    exportModifier.loc = locationNode.loc
    exportModifier.flags = self.contextFlags | NodeFlags.Reparsed
    local nodes = { exportModifier }
    return self:newModifierList(locationNode.loc, nodes)
end

-- getInnermostNameOfJSDocNamespace returns the innermost identifier from a
-- JSDoc namespace chain (ModuleDeclaration). For a simple identifier, it returns
-- the identifier itself. For "A.B.C", it returns the identifier "C".
function Parser:getInnermostNameOfJSDocNamespace(fullName)
    if fullName == nil then
        return nil
    end
    while fullName.kind == Kind.ModuleDeclaration do
        local body = fullName:AsModuleDeclaration().body
        if body == nil then
            return fullName:Name()
        end
        fullName = body
    end
    return fullName
end

-- wrapInJSDocNamespace wraps a statement (typically a type alias) in namespace
-- declarations corresponding to a JSDoc dotted name. For example, given name
-- "A.B.C" and a type alias for C, this produces:
--
--	namespace A { namespace B { type C = ... } }
--
-- If the name is a simple identifier (not a ModuleDeclaration), it returns the
-- statement as-is.
function Parser:wrapInJSDocNamespace(fullName, statement, nested)
    local p = self
    if fullName == nil or not ast.IsModuleDeclaration(fullName) then
        return statement
    end
    -- Recursively wrap from outermost to innermost. Inner namespaces always get an export modifier
    -- so members are accessible via dotted access from outside. The outermost namespace is treated as
    -- exported only in module files via IsImplicitlyExportedJSDocDeclaration (in the binder), so it
    -- does not get an explicit export modifier here.
    local wrapped = p:wrapInJSDocNamespace(fullName:Body(), statement, true --[[nested]])
    local block = p.factory:NewModuleBlock(p:newNodeList(fullName.loc, { wrapped }))
    p:finishReparsedNode(block, fullName)
    local modifiers = nil
    if nested then
        modifiers = p:createExportModifier(fullName)
    end
    local result = p.factory:NewModuleDeclaration(modifiers, Kind.NamespaceKeyword, p:addDeepCloneReparse(fullName:Name()), block)
    p:finishReparsedNode(result, fullName)
    p.reparsedClones[#p.reparsedClones + 1] = result
    return result
end
