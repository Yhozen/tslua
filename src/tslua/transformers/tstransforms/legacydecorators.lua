local tstransforms = require("tslua.transformers.tstransforms")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")
local printer = require("tslua.printer")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local EF = printer.EmitFlags

-- Fields: languageVersion, referenceResolver,
-- classAliases (A map that keeps track of aliases created for classes with decorators to avoid issues
-- with the double-binding behavior of classes; node -> alias, nil outside a source file),
-- enclosingClasses (array of ClassDeclaration).
local LegacyDecoratorsTransformer = transformers.NewTransformerType()
tstransforms.LegacyDecoratorsTransformer = LegacyDecoratorsTransformer

function tstransforms.NewLegacyDecoratorsTransformer(opt)
    local tx = setmetatable({
        languageVersion = opt.compilerOptions:GetEmitScriptTarget(),
        referenceResolver = opt.resolver,
        classAliases = nil,
        enclosingClasses = {},
    }, LegacyDecoratorsTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opt.context)
end

function LegacyDecoratorsTransformer:visit(node)
    -- we have to visit all identifiers in classes, just in case they require substitution
    if (node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsDecorators) == 0 and #self.enclosingClasses == 0 then
        return node
    end

    local kind = node.kind
    if kind == Kind.Identifier then
        return self:visitIdentifier(node:AsIdentifier())
    elseif kind == Kind.PropertyAccessExpression then
        return self:visitPropertyAccessExpression(node:AsPropertyAccessExpression())
    elseif kind == Kind.Decorator then
        -- Decorators are elided. They will be emitted as part of `visitClassDeclaration`.
        return nil
    elseif kind == Kind.ClassDeclaration then
        return self:visitClassDeclaration(node:AsClassDeclaration())
    elseif kind == Kind.ClassExpression then
        return self:visitClassExpression(node:AsClassExpression())
    elseif kind == Kind.Constructor then
        return self:visitConstructorDeclaration(node:AsConstructorDeclaration())
    elseif kind == Kind.MethodDeclaration then
        return self:visitMethodDeclaration(node:AsMethodDeclaration())
    elseif kind == Kind.SetAccessor then
        return self:visitSetAccessorDeclaration(node:AsSetAccessorDeclaration())
    elseif kind == Kind.GetAccessor then
        return self:visitGetAccessorDeclaration(node:AsGetAccessorDeclaration())
    elseif kind == Kind.PropertyDeclaration then
        return self:visitPropertyDeclaration(node:AsPropertyDeclaration())
    elseif kind == Kind.Parameter then
        return self:visitParamerDeclaration(node:AsParameterDeclaration())
    elseif kind == Kind.SourceFile then
        self.classAliases = {}
        self.enclosingClasses = {}
        local result = self:Visitor():VisitEachChild(node)
        self:EmitContext():AddEmitHelper(result, table.unpack(self:EmitContext():ReadEmitHelpers()))
        self.classAliases = nil
        self.enclosingClasses = {}
        return result
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function LegacyDecoratorsTransformer:visitIdentifier(node)
    -- takes the place of `substituteIdentifier` in the strada transform
    for _, d in ipairs(self.enclosingClasses) do
        if self.classAliases ~= nil and self.classAliases[d:AsNode()] ~= nil and self.referenceResolver:GetReferencedValueDeclaration(self:EmitContext():MostOriginal(node:AsNode())) == self:EmitContext():MostOriginal(d:AsNode()) then
            return self.classAliases[d:AsNode()]
        end
    end
    return node:AsNode()
end

function LegacyDecoratorsTransformer:visitPropertyAccessExpression(node)
    -- Visit the expression but not the name, since property access names should not be substituted.
    -- Strada's onSubstituteNode only fires for EmitHint.Expression, which excludes the
    -- .name of PropertyAccessExpression.
    local expression = self:Visitor():VisitNode(node.expression)
    if expression ~= node.expression then
        return self:Factory():UpdatePropertyAccessExpression(node, expression, node.questionDotToken, node:Name(), node.flags)
    end
    return node:AsNode()
end

function tstransforms.elideNodes(f, nodes)
    if nodes == nil then
        return nil
    end
    if core.Len(nodes.nodes) == 0 then
        return nodes
    end
    local replacement = f:NewNodeList({})
    replacement.loc = nodes.loc
    return replacement
end

function tstransforms.elideModifiers(f, nodes)
    if nodes == nil then
        return nil
    end
    if core.Len(nodes.nodes) == 0 then
        return nodes
    end
    local replacement = f:NewModifierList({})
    replacement.loc = nodes.loc
    return replacement
end

function LegacyDecoratorsTransformer:finishClassElement(updated, original)
    if updated ~= original then
        -- While we emit the source map for the node after skipping decorators and modifiers,
        -- we need to emit the comments for the original range.
        self:EmitContext():SetCommentRange(updated, original.loc)
        self:EmitContext():SetSourceMapRange(updated, transformers.MoveRangePastModifiers(original))
    end
    return updated
end

function LegacyDecoratorsTransformer:visitParamerDeclaration(node)
    local updated = self:Factory():UpdateParameterDeclaration(
        node,
        tstransforms.elideModifiers(self:Factory(), node:Modifiers()),
        node.dotDotDotToken,
        self:Visitor():VisitNode(node:Name()),
        nil,
        nil,
        self:Visitor():VisitNode(node.initializer)
    )
    if updated ~= node:AsNode() then
        -- While we emit the source map for the node after skipping decorators and modifiers,
        -- we need to emit the comments for the original range.
        self:EmitContext():SetCommentRange(updated, node.loc)
        local newLoc = transformers.MoveRangePastModifiers(node:AsNode())
        updated.loc = newLoc
        self:EmitContext():SetSourceMapRange(updated, newLoc)
        self:EmitContext():SetEmitFlags(updated:Name(), EF.EFNoTrailingSourceMap)
    end
    return updated
end

-- visitPropertyNameOfClassElement visits the property name of a class element,
-- for use when emitting property initializers. For a computed property on a node
-- with decorators, a temporary value is stored for later use.
function LegacyDecoratorsTransformer:visitPropertyNameOfClassElement(member)
    local name = member:Name()
    if ast.IsComputedPropertyName(name) and ast.HasDecorators(member) then
        local expression = self:Visitor():VisitNode(name:AsComputedPropertyName().expression)
        local innerExpression = ast.SkipPartiallyEmittedExpressions(expression)
        if not transformers.IsSimpleInlineableExpression(innerExpression) then
            local generatedName = self:Factory():NewGeneratedNameForNode(name)
            self:EmitContext():AddVariableDeclaration(generatedName)
            return self:Factory():UpdateComputedPropertyName(name:AsComputedPropertyName(), self:Factory():NewAssignmentExpression(generatedName:AsNode(), expression))
        end
    end
    return self:Visitor():VisitNode(name)
end

function LegacyDecoratorsTransformer:visitPropertyDeclaration(node)
    if (node.flags & NodeFlags.Ambient) ~= 0 then
        return nil
    end
    if ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Ambient | ModifierFlags.Abstract) then
        return nil
    end

    return self:finishClassElement(
        self:Factory():UpdatePropertyDeclaration(
            node,
            self:Visitor():VisitModifiers(node:Modifiers()),
            self:visitPropertyNameOfClassElement(node:AsNode()),
            nil,
            nil,
            self:Visitor():VisitNode(node.initializer)
        ),
        node:AsNode()
    )
end

function LegacyDecoratorsTransformer:visitGetAccessorDeclaration(node)
    return self:finishClassElement(
        self:Factory():UpdateGetAccessorDeclaration(
            node,
            self:Visitor():VisitModifiers(node:Modifiers()),
            self:visitPropertyNameOfClassElement(node:AsNode()),
            nil,
            self:Visitor():VisitNodes(node.parameters),
            nil,
            nil,
            self:Visitor():VisitNode(node.body)
        ),
        node:AsNode()
    )
end

function LegacyDecoratorsTransformer:visitSetAccessorDeclaration(node)
    return self:finishClassElement(
        self:Factory():UpdateSetAccessorDeclaration(
            node,
            self:Visitor():VisitModifiers(node:Modifiers()),
            self:visitPropertyNameOfClassElement(node:AsNode()),
            nil,
            self:Visitor():VisitNodes(node.parameters),
            nil,
            nil,
            self:Visitor():VisitNode(node.body)
        ),
        node:AsNode()
    )
end

function LegacyDecoratorsTransformer:visitMethodDeclaration(node)
    return self:finishClassElement(
        self:Factory():UpdateMethodDeclaration(
            node,
            self:Visitor():VisitModifiers(node:Modifiers()),
            node.asteriskToken,
            self:visitPropertyNameOfClassElement(node:AsNode()),
            nil,
            nil,
            self:Visitor():VisitNodes(node.parameters),
            nil,
            nil,
            self:Visitor():VisitNode(node.body)
        ),
        node:AsNode()
    )
end

function LegacyDecoratorsTransformer:visitConstructorDeclaration(node)
    return self:Factory():UpdateConstructorDeclaration(
        node,
        self:Visitor():VisitModifiers(node:Modifiers()),
        nil,
        self:Visitor():VisitNodes(node.parameters),
        nil,
        nil,
        self:Visitor():VisitNode(node.body)
    )
end

function LegacyDecoratorsTransformer:visitClassExpression(node)
    -- Legacy decorators were not supported on class expressions
    return self:Factory():UpdateClassExpression(
        node,
        self:Visitor():VisitModifiers(node:Modifiers()),
        node:Name(),
        nil,
        self:Visitor():VisitNodes(node.heritageClauses),
        self:Visitor():VisitNodes(node.members)
    )
end

function LegacyDecoratorsTransformer:visitClassDeclaration(node)
    local decorated = ast.ClassOrConstructorParameterIsDecorated(true, node:AsNode())
    if not (decorated or ast.ChildIsDecorated(true, node:AsNode(), nil)) then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    if decorated then
        return self:transformClassDeclarationWithClassDecorators(node, node:Name())
    end
    return self:transformClassDeclarationWithoutClassDecorators(node, node:Name())
end

--[[*
* Transforms a non-decorated class declaration.
*
* @param node A ClassDeclaration node.
* @param name The name of the class.
 ]]
function LegacyDecoratorsTransformer:transformClassDeclarationWithoutClassDecorators(node, name)
    --  ${modifiers} class ${name} ${heritageClauses} {
    --      ${members}
    --  }
    local modifiers = self:Visitor():VisitModifiers(node:Modifiers())
    local heritageClauses = self:Visitor():VisitNodes(node.heritageClauses)
    local initialMembers = self:Visitor():VisitNodes(node.members)
    local members, decorationStatements = self:transformDecoratorsOfClassElements(node, initialMembers)

    if name == nil and core.Len(decorationStatements) > 0 then
        name = self:Factory():NewGeneratedNameForNode(node:AsNode())
    end

    local updated = self:Factory():UpdateClassDeclaration(
        node,
        modifiers,
        name,
        nil,
        heritageClauses,
        members
    )

    if core.Len(decorationStatements) == 0 then
        return updated
    end
    return self:Factory():NewSyntaxList(core.AppendAll({ updated }, decorationStatements))
end

function LegacyDecoratorsTransformer:popEnclosingClass()
    self.enclosingClasses[#self.enclosingClasses] = nil
end

function LegacyDecoratorsTransformer:pushEnclosingClass(cls)
    self.enclosingClasses[#self.enclosingClasses + 1] = cls
end

--[[*
* Transforms a decorated class declaration and appends the resulting statements. If
* the class requires an alias to avoid issues with double-binding, the alias is returned.
 ]]
function LegacyDecoratorsTransformer:transformClassDeclarationWithClassDecorators(node, name)
    -- When we emit an ES6 class that has a class decorator, we must tailor the
    -- emit to certain specific cases.
    --
    -- In the simplest case, we emit the class declaration as a let declaration, and
    -- evaluate decorators after the close of the class body:
    --
    --  [Example 1]
    --  ---------------------------------------------------------------------
    --  TypeScript                      | Javascript
    --  ---------------------------------------------------------------------
    --  @dec                            | let C = class C {
    --  class C {                       | }
    --  }                               | C = __decorate([dec], C);
    --  ---------------------------------------------------------------------
    --  @dec                            | let C = class C {
    --  export class C {                | }
    --  }                               | C = __decorate([dec], C);
    --                                  | export { C };
    --  ---------------------------------------------------------------------
    --
    -- If a class declaration contains a reference to itself *inside* of the class body,
    -- this introduces two bindings to the class: One outside of the class body, and one
    -- inside of the class body. If we apply decorators as in [Example 1] above, there
    -- is the possibility that the decorator `dec` will return a new value for the
    -- constructor, which would result in the binding inside of the class no longer
    -- pointing to the same reference as the binding outside of the class.
    --
    -- As a result, we must instead rewrite all references to the class *inside* of the
    -- class body to instead point to a local temporary alias for the class:
    --
    --  [Example 2]
    --  ---------------------------------------------------------------------
    --  TypeScript                      | Javascript
    --  ---------------------------------------------------------------------
    --  @dec                            | let C = C_1 = class C {
    --  class C {                       |   static x() { return C_1.y; }
    --    static x() { return C.y; }    | }
    --    static y = 1;                 | C.y = 1;
    --  }                               | C = C_1 = __decorate([dec], C);
    --                                  | var C_1;
    --  ---------------------------------------------------------------------
    --  @dec                            | let C = class C {
    --  export class C {                |   static x() { return C_1.y; }
    --    static x() { return C.y; }    | }
    --    static y = 1;                 | C.y = 1;
    --  }                               | C = C_1 = __decorate([dec], C);
    --                                  | export { C };
    --                                  | var C_1;
    --  ---------------------------------------------------------------------
    --
    -- If a class declaration is the default export of a module, we instead emit
    -- the export after the decorated declaration:
    --
    --  [Example 3]
    --  ---------------------------------------------------------------------
    --  TypeScript                      | Javascript
    --  ---------------------------------------------------------------------
    --  @dec                            | let default_1 = class {
    --  export default class {          | }
    --  }                               | default_1 = __decorate([dec], default_1);
    --                                  | export default default_1;
    --  ---------------------------------------------------------------------
    --  @dec                            | let C = class C {
    --  export default class C {        | }
    --  }                               | C = __decorate([dec], C);
    --                                  | export default C;
    --  ---------------------------------------------------------------------
    --
    -- If the class declaration is the default export and a reference to itself
    -- inside of the class body, we must emit both an alias for the class *and*
    -- move the export after the declaration:
    --
    --  [Example 4]
    --  ---------------------------------------------------------------------
    --  TypeScript                      | Javascript
    --  ---------------------------------------------------------------------
    --  @dec                            | let C = class C {
    --  export default class C {        |   static x() { return C_1.y; }
    --    static x() { return C.y; }    | }
    --    static y = 1;                 | C.y = 1;
    --  }                               | C = C_1 = __decorate([dec], C);
    --                                  | export default C;
    --                                  | var C_1;
    --  ---------------------------------------------------------------------
    --

    local isExport = ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Export)
    local isDefault = ast.HasSyntacticModifier(node:AsNode(), ModifierFlags.Default)
    local modifiers
    if node:Modifiers() ~= nil and core.Len(node:Modifiers().nodes) > 0 then
        local modifierNodes = core.Filter(node:Modifiers().nodes, tstransforms.isNotExportOrDefaultOrDecorator)
        if core.Len(modifierNodes) ~= core.Len(node:Modifiers().nodes) then
            modifiers = self:Factory():NewModifierList(modifierNodes)
            modifiers.loc = node:Modifiers().loc
        else
            modifiers = node:Modifiers()
        end
    end

    local location = transformers.MoveRangePastModifiers(node:AsNode())
    local classAlias = self:getClassAliasIfNeeded(node)
    if classAlias ~= nil then
        self:pushEnclosingClass(node)
    end

    -- When we used to transform to ES5/3 this would be moved inside an IIFE and should reference the name
    -- without any block-scoped variable collision handling - but we don't support that anymore, so we always
    -- use the local name for the class
    local declName = self:Factory():GetLocalNameEx(node:AsNode(), { allowComments = false, allowSourceMaps = true })

    --  ... = class ${name} ${heritageClauses} {
    --      ${members}
    --  }
    local heritageClauses = self:Visitor():VisitNodes(node.heritageClauses)
    local members = self:Visitor():VisitNodes(node.members)

    local decorationStatements = nil
    members, decorationStatements = self:transformDecoratorsOfClassElements(node, members)

    -- If we're emitting to ES2022 or later then we need to reassign the class alias before
    -- static initializers are evaluated.
    local assignClassAliasInStaticBlock = self.languageVersion >= core.ScriptTarget.ES2022 and classAlias ~= nil and members ~= nil and core.Len(members.nodes) > 0 and core.Some(members.nodes, tstransforms.isClassStaticBlockDeclarationOrStaticProperty)
    if assignClassAliasInStaticBlock then
        local memberList = {}
        memberList[#memberList + 1] = self:Factory():NewClassStaticBlockDeclaration(nil, self:Factory():NewBlock(
            self:Factory():NewNodeList({ self:Factory():NewExpressionStatement(
                self:Factory():NewAssignmentExpression(classAlias, self:Factory():NewKeywordExpression(Kind.ThisKeyword))
            ) }),
            false
        ))
        memberList = core.AppendAll(memberList, members.nodes)
        local newList = self:Factory():NewNodeList(memberList)
        newList.loc = members.loc
        members = newList
    end

    local exprName = name
    if name ~= nil and transformers.IsGeneratedIdentifier(self:EmitContext(), name) then
        exprName = nil
    end
    local classExpression = self:Factory():NewClassExpression(
        modifiers,
        exprName,
        nil,
        heritageClauses,
        members
    )

    self:EmitContext():SetOriginal(classExpression, node:AsNode())
    classExpression.loc = location

    --  let ${name} = ${classExpression} where name is either declaredName if the class doesn't contain self-reference
    --                                         or decoratedClassAlias if the class contain self-reference.
    local varInitializer = classExpression
    if classAlias ~= nil and not assignClassAliasInStaticBlock then
        varInitializer = self:Factory():NewAssignmentExpression(classAlias, classExpression)
    end
    local varDecl = self:Factory():NewVariableDeclaration(
        declName,
        nil,
        nil,
        varInitializer
    )
    self:EmitContext():SetOriginal(varDecl, node:AsNode())

    local varDeclList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.Let)
    local varStatement = self:Factory():NewVariableStatement(nil, varDeclList)
    self:EmitContext():SetOriginal(varStatement, node:AsNode())
    varStatement.loc = location
    self:EmitContext():SetCommentRange(varStatement, node.loc)

    local statements = { varStatement }
    statements = core.AppendAll(statements, decorationStatements)
    -- Go appends the (possibly nil) constructor decoration statement; Lua arrays cannot hold nil.
    local constructorDecorationStatement = self:getConstructorDecorationStatement(node)
    if constructorDecorationStatement ~= nil then
        statements[#statements + 1] = constructorDecorationStatement
    end

    if isExport then
        local exportStatement
        if isDefault then
            exportStatement = self:Factory():NewExportDefault(declName)
        else
            exportStatement = self:Factory():NewExternalModuleExport(self:Factory():GetDeclarationName(node:AsNode()))
        end
        statements[#statements + 1] = exportStatement
    end

    if classAlias ~= nil then
        self:popEnclosingClass()
    end

    if #statements == 1 then
        return statements[1]
    end
    return self:Factory():NewSyntaxList(statements)
end

function LegacyDecoratorsTransformer:hasInternalStaticReference(node)
    local classNode = self:EmitContext():MostOriginal(node:AsNode())
    local isOrContainsStaticSelfReference
    isOrContainsStaticSelfReference = function(n)
        if ast.IsIdentifier(n) and self.referenceResolver:GetReferencedValueDeclaration(self:EmitContext():MostOriginal(n)) == classNode then
            return true
        end
        -- For PropertyAccessExpression, only check the expression, not the name.
        -- The .Name() is a property access name, not a value reference to the class.
        if ast.IsPropertyAccessExpression(n) then
            return isOrContainsStaticSelfReference(n:Expression())
        end
        return n:ForEachChild(isOrContainsStaticSelfReference)
    end
    for _, member in ipairs(node.members.nodes or {}) do
        if member:ForEachChild(isOrContainsStaticSelfReference) then
            return true
        end
    end
    return false
end

--[[*
* Gets a local alias for a class declaration if it is a decorated class with an internal
* reference to the static side of the class. This is necessary to avoid issues with
* double-binding semantics for the class name.
 ]]
function LegacyDecoratorsTransformer:getClassAliasIfNeeded(node)
    if not self:hasInternalStaticReference(node) then
        return nil
    end
    local nameText = "default"
    if node:Name() ~= nil and not transformers.IsGeneratedIdentifier(self:EmitContext(), node:Name()) then
        nameText = node:Name():Text()
    end

    local classAlias = self:Factory():NewUniqueName(nameText)
    self:EmitContext():AddVariableDeclaration(classAlias)
    self.classAliases[node:AsNode()] = classAlias

    return classAlias
end

--[[*
* Generates a __decorate helper call for a class constructor.
*
* @param node The class node.
 ]]
function LegacyDecoratorsTransformer:getConstructorDecorationStatement(node)
    local expression = self:generateConstructorDecorationExpression(node)
    if expression ~= nil then
        local result = self:Factory():NewExpressionStatement(expression)
        self:EmitContext():SetOriginal(result, node:AsNode())
        return result
    end
    return nil
end

--[[*
* Generates a __decorate helper call for a class constructor.
*
* @param node The class node.
 ]]
function LegacyDecoratorsTransformer:generateConstructorDecorationExpression(node)
    local allDecorators = tstransforms.getAllDecoratorsOfClass(node, true)
    -- Decorator expressions are evaluated outside the class body, so references to the
    -- class name should use the original binding, not the class alias. In Strada, this is
    -- handled by NodeCheckFlags.ConstructorReference which is only set for identifiers
    -- inside the class body. Since Corsa lacks per-node flags, we temporarily pop the
    -- enclosing class to prevent alias substitution during decorator expression visiting.
    local hasAlias = #self.enclosingClasses > 0 and self.enclosingClasses[#self.enclosingClasses] == node
    if hasAlias then
        self:popEnclosingClass()
    end
    local decoratorExpressions = self:transformAllDecoratorsOfDeclaration(allDecorators)
    if hasAlias then
        self:pushEnclosingClass(node)
    end
    if core.Len(decoratorExpressions) == 0 then
        return nil
    end

    local classAlias
    if self.classAliases ~= nil then
        classAlias = self.classAliases[node:AsNode()]
    end

    -- When we used to transform to ES5/3 this would be moved inside an IIFE and should reference the name
    -- without any block-scoped variable collision handling - but we don't support that anymore, so we always
    -- use the local name for the class
    local localName = self:Factory():GetDeclarationNameEx(node:AsNode(), { allowComments = false, allowSourceMaps = true })
    local decorate = self:Factory():NewDecorateHelper(decoratorExpressions, localName, nil, nil)
    local assignmentTarget = decorate
    if classAlias ~= nil then
        assignmentTarget = self:Factory():NewAssignmentExpression(classAlias, decorate)
    end
    local expression = self:Factory():NewAssignmentExpression(localName, assignmentTarget)
    self:EmitContext():SetEmitFlags(expression, EF.EFNoComments)
    self:EmitContext():SetSourceMapRange(expression, transformers.MoveRangePastModifiers(node:AsNode()))
    return expression
end

function tstransforms.isClassStaticBlockDeclarationOrStaticProperty(node)
    return ast.IsClassStaticBlockDeclaration(node) or (ast.IsPropertyDeclaration(node) and ast.HasStaticModifier(node))
end

function tstransforms.isNotExportOrDefaultOrDecorator(node)
    return not (ast.IsDecorator(node) or node.kind == Kind.ExportKeyword or node.kind == Kind.DefaultKeyword)
end

function tstransforms.decoratorContainsPrivateIdentifierInExpression(decorator)
    return (decorator:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsPrivateIdentifierInExpression) ~= 0
end

function tstransforms.parameterDecoratorsContainPrivateIdentifierInExpression(parameterDecorators)
    return core.Some(parameterDecorators, tstransforms.decoratorContainsPrivateIdentifierInExpression)
end

function tstransforms.hasClassElementWithDecoratorContainingPrivateIdentifierInExpression(node)
    if node.members == nil or core.Len(node.members.nodes) == 0 then
        return false
    end
    for _, member in ipairs(node.members.nodes) do
        if not ast.CanHaveDecorators(member) then
            goto continue
        end
        do
            local allDecorators = tstransforms.getAllDecoratorsOfClassElement(member, node, true)
            if allDecorators == nil then
                goto continue
            end
            if core.Some(allDecorators.decorators, tstransforms.decoratorContainsPrivateIdentifierInExpression) then
                return true
            end
            if core.Some(allDecorators.parameters, tstransforms.parameterDecoratorsContainPrivateIdentifierInExpression) then
                return true
            end
        end
        ::continue::
    end
    return false
end

-- allDecorators: { decorators = []Node or nil, parameters = [][]Node or nil }
-- (entries of `parameters` for undecorated parameters are empty arrays; Go has nil slices there)

--[[*
 * Gets an allDecorators object containing the decorators for the class and the decorators for the
 * parameters of the constructor of the class.
 *
 * @param node The class node.
 *
 * @internal
 ]]
function tstransforms.getAllDecoratorsOfClass(node, useLegacyDecorators)
    local decorators = node:Decorators()
    local parameters
    if useLegacyDecorators then
        parameters = tstransforms.getDecoratorsOfParameters(ast.GetFirstConstructorWithBody(node:AsNode()))
    end
    if core.Len(decorators) == 0 and core.Len(parameters) == 0 then
        return nil
    end
    return { decorators = decorators, parameters = parameters }
end

--[[*
 * Gets an allDecorators object containing the decorators for the member and its parameters.
 *
 * @param parent The class node that contains the member.
 * @param member The class member.
 *
 * @internal
 ]]
function tstransforms.getAllDecoratorsOfClassElement(member, parent, useLegacyDecorators)
    local kind = member.kind
    if kind == Kind.GetAccessor or kind == Kind.SetAccessor then
        if not useLegacyDecorators then
            return tstransforms.getAllDecoratorsOfMethod(member, false)
        end
        return tstransforms.getAllDecoratorsOfAccessors(member, parent, true)
    elseif kind == Kind.MethodDeclaration then
        return tstransforms.getAllDecoratorsOfMethod(member, useLegacyDecorators)
    elseif kind == Kind.PropertyDeclaration then
        return tstransforms.getAllDecoratorsOfProperty(member)
    else
        return nil
    end
end

--[[*
 * Gets an allDecorators object containing the decorators for the accessor and its parameters.
 *
 * @param parent The class node that contains the accessor.
 * @param accessor The class accessor member.
 ]]
function tstransforms.getAllDecoratorsOfAccessors(accessor, parent, useLegacyDecorators)
    if accessor:Body() == nil then
        return nil
    end
    local decls = ast.GetAllAccessorDeclarations(parent.members.nodes, accessor)
    local firstAccessorWithDecorators
    if ast.HasDecorators(decls.firstAccessor) then
        firstAccessorWithDecorators = decls.firstAccessor
    elseif decls.secondAccessor ~= nil and ast.HasDecorators(decls.secondAccessor) then
        firstAccessorWithDecorators = decls.secondAccessor
    end

    if firstAccessorWithDecorators == nil or accessor ~= firstAccessorWithDecorators then
        return nil
    end

    local decorators = firstAccessorWithDecorators:Decorators()
    local parameters
    if useLegacyDecorators and decls.setAccessor ~= nil then
        parameters = tstransforms.getDecoratorsOfParameters(decls.setAccessor:AsNode())
    end

    if core.Len(decorators) == 0 and core.Len(parameters) == 0 then
        return nil
    end

    return {
        decorators = decorators,
        parameters = parameters,
    }
end

function tstransforms.getAllDecoratorsOfProperty(property)
    local decorators = property:Decorators()
    if core.Len(decorators) == 0 then
        return nil
    end
    return { decorators = decorators }
end

function tstransforms.getAllDecoratorsOfMethod(method, useLegacyDecorators)
    if method:Body() == nil then
        return nil
    end
    local decorators = method:Decorators()
    local parameters
    if useLegacyDecorators then
        parameters = tstransforms.getDecoratorsOfParameters(method)
    end
    if core.Len(decorators) == 0 and core.Len(parameters) == 0 then
        return nil
    end
    return { decorators = decorators, parameters = parameters }
end

--[[*
 * Gets an array of arrays of decorators for the parameters of a function-like node.
 * The offset into the result array should correspond to the offset of the parameter.
 *
 * @param node The function-like node.
 ]]
function tstransforms.getDecoratorsOfParameters(node)
    local decorators
    if node ~= nil then
        local parameters = node:Parameters() or {}
        local firstParameterIsThis = #parameters > 0 and ast.IsThisParameter(parameters[1])
        local firstParameterOffset = 0
        local numParameters = #parameters
        if firstParameterIsThis then
            firstParameterOffset = 1
            numParameters = numParameters - 1
        end
        for i = 0, numParameters - 1 do
            local p = parameters[i + firstParameterOffset + 1]
            if core.Len(decorators) > 0 or ast.HasDecorators(p) then
                if core.Len(decorators) == 0 then
                    decorators = {}
                    for j = 1, numParameters do
                        decorators[j] = {}
                    end
                end
                decorators[i + 1] = p:Decorators() or {}
            end
        end
    end
    return decorators
end

function LegacyDecoratorsTransformer:transformDecoratorsOfClassElements(node, members)
    local decorationStatements = nil
    decorationStatements = core.AppendAll(decorationStatements, self:getClassElementDecorationStatements(node, false))
    decorationStatements = core.AppendAll(decorationStatements, self:getClassElementDecorationStatements(node, true))
    if tstransforms.hasClassElementWithDecoratorContainingPrivateIdentifierInExpression(node) then
        local memberNodes
        if members ~= nil and core.Len(members.nodes) > 0 then
            memberNodes = members.nodes
        end
        local list = core.AppendAll({}, memberNodes)
        list[#list + 1] = self:Factory():NewClassStaticBlockDeclaration(nil, self:Factory():NewBlock(self:Factory():NewNodeList(decorationStatements), true))
        members = self:Factory():NewNodeList(list)
        decorationStatements = nil
    end

    return members, decorationStatements
end

--[[*
* Generates statements used to apply decorators to either the static or instance members
* of a class.
*
* @param node The class node.
* @param isStatic A value indicating whether to generate statements for static or
*                 instance members.
 ]]
function LegacyDecoratorsTransformer:getClassElementDecorationStatements(node, isStatic)
    local exprs = self:generateClassElementDecorationExpressions(node, isStatic)
    local statements
    for _, e in ipairs(exprs or {}) do
        statements = core.Append(statements, self:Factory():NewExpressionStatement(e))
    end
    return statements
end

--[[*
* Determines whether a class member is either a static or an instance member of a class
* that is decorated, or has parameters that are decorated.
*
* @param member The class member.
 ]]
function tstransforms.isDecoratedClassElement(member, isStaticElement, parent)
    return isStaticElement == ast.IsStatic(member) and ast.NodeOrChildIsDecorated(true, member, parent:AsNode(), nil)
end

--[[*
* Gets either the static or instance members of a class that are decorated, or have
* parameters that are decorated.
*
* @param node The class containing the member.
* @param isStatic A value indicating whether to retrieve static or instance members of
*                 the class.
 ]]
function tstransforms.getDecoratedClassElements(node, isStatic)
    if node.members == nil or core.Len(node.members.nodes) == 0 then
        return nil
    end
    local members
    for _, member in ipairs(node.members.nodes) do
        if tstransforms.isDecoratedClassElement(member, isStatic, node) then
            members = core.Append(members, member)
        end
    end
    return members
end

--[[*
* Generates expressions used to apply decorators to either the static or instance members
* of a class.
*
* @param node The class node.
* @param isStatic A value indicating whether to generate expressions for static or
*                 instance members.
 ]]
function LegacyDecoratorsTransformer:generateClassElementDecorationExpressions(node, isStatic)
    local members = tstransforms.getDecoratedClassElements(node, isStatic)
    local expressions
    for _, member in ipairs(members or {}) do
        local expr = self:generateClassElementDecorationExpression(node, member)
        if expr ~= nil then
            expressions = core.Append(expressions, expr)
        end
    end
    return expressions
end

--[[*
* Generates an expression used to evaluate class element decorators at runtime.
*
* @param node The class node that contains the member.
* @param member The class member.
 ]]
function LegacyDecoratorsTransformer:generateClassElementDecorationExpression(node, member)
    local allDecorators = tstransforms.getAllDecoratorsOfClassElement(member, node, true)
    local decoratorExpressions = self:transformAllDecoratorsOfDeclaration(allDecorators)
    if core.Len(decoratorExpressions) == 0 then
        return nil
    end

    -- Emit the call to __decorate. Given the following:
    --
    --   class C {
    --     @dec method(@dec2 x) {}
    --     @dec get accessor() {}
    --     @dec prop;
    --   }
    --
    -- The emit for a method is:
    --
    --   __decorate([
    --       dec,
    --       __param(0, dec2),
    --       __metadata("design:type", Function),
    --       __metadata("design:paramtypes", [Object]),
    --       __metadata("design:returntype", void 0)
    --   ], C.prototype, "method", null);
    --
    -- The emit for an accessor is:
    --
    --   __decorate([
    --       dec
    --   ], C.prototype, "accessor", null);
    --
    -- The emit for a property is:
    --
    --   __decorate([
    --       dec
    --   ], C.prototype, "prop");
    --

    local prefix = self:getClassMemberPrefix(node, member)
    local memberName = self:getExpressionForPropertyName(member, member.flags & NodeFlags.Ambient == 0)
    local descriptor
    if ast.IsPropertyDeclaration(member) and not ast.HasAccessorModifier(member) then
        -- We emit `void 0` here to indicate to `__decorate` that it can invoke `Object.defineProperty` directly, but that it
        -- should not invoke `Object.getOwnPropertyDescriptor`.
        descriptor = self:Factory():NewVoidZeroExpression()
    else
        -- We emit `null` here to indicate to `__decorate` that it can invoke `Object.getOwnPropertyDescriptor` directly.
        -- We have this extra argument here so that we can inject an explicit property descriptor at a later date.
        descriptor = self:Factory():NewKeywordExpression(Kind.NullKeyword)
    end

    local helper = self:Factory():NewDecorateHelper(
        decoratorExpressions,
        prefix,
        memberName,
        descriptor
    )

    self:EmitContext():SetEmitFlags(helper, EF.EFNoComments)
    self:EmitContext():SetSourceMapRange(helper, transformers.MoveRangePastModifiers(member))
    return helper
end

function LegacyDecoratorsTransformer:isSyntheticMetadataDecorator(node)
    return self:EmitContext():IsCallToHelper(node:Expression(), "__metadata")
end

--[[*
* Transforms all of the decorators for a declaration into an array of expressions.
*
* @param allDecorators An object containing all of the decorators for the declaration.
 ]]
function LegacyDecoratorsTransformer:transformAllDecoratorsOfDeclaration(allDecorators)
    if allDecorators == nil then
        return nil
    end

    -- ensure that metadata decorators are last
    -- (Go: collections.GroupBy(allDecorators.decorators, tx.isSyntheticMetadataDecorator))
    local metadata
    local decorators
    for _, d in ipairs(allDecorators.decorators or {}) do
        if self:isSyntheticMetadataDecorator(d) then
            metadata = core.Append(metadata, d)
        else
            decorators = core.Append(decorators, d)
        end
    end

    local decoratorExpressions = nil
    decoratorExpressions = core.AppendAll(decoratorExpressions, self:transformDecorators(decorators))
    decoratorExpressions = core.AppendAll(decoratorExpressions, self:transformDecoratorsOfParameters(allDecorators.parameters))
    decoratorExpressions = core.AppendAll(decoratorExpressions, self:transformDecorators(metadata))
    return decoratorExpressions
end

function LegacyDecoratorsTransformer:transformDecoratorsOfParameters(parameters)
    local results
    for i0, decorators in ipairs(parameters or {}) do
        local i = i0 - 1
        if core.Len(decorators) > 0 then
            for _, decorator in ipairs(decorators) do
                local helper = self:Factory():NewParamHelper(
                    self:Visitor():VisitNode(decorator:Expression()),
                    i,
                    decorator:Expression().loc
                )
                self:EmitContext():SetEmitFlags(helper, EF.EFNoComments)
                results = core.Append(results, helper)
            end
        end
    end
    return results
end

--[[*
* Transforms a list of decorators into an expression.
*
* @param decorator The decorator node.
 ]]
function LegacyDecoratorsTransformer:transformDecorators(decorators)
    local results
    for _, d in ipairs(decorators or {}) do
        results = core.Append(results, self:Visitor():VisitNode(d:Expression()))
    end
    return results
end

function LegacyDecoratorsTransformer:getClassMemberPrefix(node, member)
    if ast.IsStatic(member) then
        return self:Factory():GetDeclarationName(node:AsNode())
    end
    return self:getClassPrototype(node)
end

function LegacyDecoratorsTransformer:getClassPrototype(node)
    return self:Factory():NewPropertyAccessExpression(
        self:Factory():GetDeclarationName(node:AsNode()),
        nil,
        self:Factory():NewIdentifier("prototype"),
        NodeFlags.None
    )
end

function LegacyDecoratorsTransformer:getExpressionForPropertyName(member, generateNameForComputedPropertyName)
    local name = member:Name()
    if ast.IsPrivateIdentifier(name) then
        return self:Factory():NewIdentifier("")
    elseif ast.IsComputedPropertyName(name) then
        if generateNameForComputedPropertyName and not transformers.IsSimpleInlineableExpression(name:AsComputedPropertyName().expression) then
            return self:Factory():NewGeneratedNameForNode(name)
        end
        return name:AsComputedPropertyName().expression
    elseif ast.IsIdentifier(name) then
        return self:Factory():NewStringLiteral(name:Text(), ast.TokenFlags.None)
    else
        return self:Factory():DeepCloneNode(name)
    end
end
