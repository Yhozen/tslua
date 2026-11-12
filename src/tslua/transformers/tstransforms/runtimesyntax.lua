-- !!! SourceMaps and Comments need to be validated
local tstransforms = require("tslua.transformers.tstransforms")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")
local printer = require("tslua.printer")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local EF = printer.EmitFlags

-- Transforms TypeScript-specific runtime syntax into JavaScript-compatible syntax.
local RuntimeSyntaxTransformer = transformers.NewTransformerType()
tstransforms.RuntimeSyntaxTransformer = RuntimeSyntaxTransformer

function tstransforms.NewRuntimeSyntaxTransformer(opt)
    local compilerOptions = opt.compilerOptions
    local emitContext = opt.context
    local tx = setmetatable({
        compilerOptions = compilerOptions,
        parentNode = nil,
        currentNode = nil,
        currentSourceFile = nil,
        currentScope = nil, -- SourceFile | Block | ModuleBlock | CaseBlock
        currentScopeFirstDeclarationsOfName = nil,
        currentEnum = nil,
        currentNamespace = nil,
        resolver = opt.resolver,
        emitResolver = opt.emitResolver,
    }, RuntimeSyntaxTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
end

-- Pushes a new child node onto the ancestor tracking stack, returning the grandparent node to be restored later via `popNode`.
function RuntimeSyntaxTransformer:pushNode(node)
    local grandparentNode = self.parentNode
    self.parentNode = self.currentNode
    self.currentNode = node
    return grandparentNode
end

-- Pops the last child node off the ancestor tracking stack, restoring the grandparent node.
function RuntimeSyntaxTransformer:popNode(grandparentNode)
    self.currentNode = self.parentNode
    self.parentNode = grandparentNode
end

function RuntimeSyntaxTransformer:pushScope(node)
    local savedCurrentScope = self.currentScope
    local savedCurrentScopeFirstDeclarationsOfName = self.currentScopeFirstDeclarationsOfName
    local kind = node.kind
    if kind == Kind.SourceFile then
        self.currentScope = node
        self.currentSourceFile = node
        self.currentScopeFirstDeclarationsOfName = nil
    elseif kind == Kind.CaseBlock or kind == Kind.ModuleBlock or kind == Kind.Block then
        self.currentScope = node
        self.currentScopeFirstDeclarationsOfName = nil
    elseif kind == Kind.FunctionDeclaration or kind == Kind.ClassDeclaration or kind == Kind.VariableStatement then
        self:recordDeclarationInScope(node)
    end
    return savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName
end

function RuntimeSyntaxTransformer:popScope(savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName)
    if self.currentScope ~= savedCurrentScope then
        -- only reset the first declaration for a name if we are exiting the scope in which it was declared
        self.currentScopeFirstDeclarationsOfName = savedCurrentScopeFirstDeclarationsOfName
    end

    self.currentScope = savedCurrentScope
end

-- The body of Go's visit after the pushes (Go defers popScope and popNode).
local function visitWorker(tx, node)
    if node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsTypeScript == 0 and (tx.currentNamespace == nil and tx.currentEnum == nil or node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsIdentifier == 0) then
        return node
    end

    local kind = node.kind
    -- TypeScript parameter property modifiers are elided
    if kind == Kind.PublicKeyword or
        kind == Kind.PrivateKeyword or
        kind == Kind.ProtectedKeyword or
        kind == Kind.ReadonlyKeyword or
        kind == Kind.OverrideKeyword then
        node = nil
    elseif kind == Kind.EnumDeclaration then
        node = tx:visitEnumDeclaration(node:AsEnumDeclaration())
    elseif kind == Kind.ModuleDeclaration then
        node = tx:visitModuleDeclaration(node:AsModuleDeclaration())
    elseif kind == Kind.ClassDeclaration then
        node = tx:visitClassDeclaration(node:AsClassDeclaration())
    elseif kind == Kind.ClassExpression then
        node = tx:visitClassExpression(node:AsClassExpression())
    elseif kind == Kind.Constructor then
        node = tx:visitConstructorDeclaration(node:AsConstructorDeclaration())
    elseif kind == Kind.FunctionDeclaration then
        node = tx:visitFunctionDeclaration(node:AsFunctionDeclaration())
    elseif kind == Kind.VariableStatement then
        node = tx:visitVariableStatement(node:AsVariableStatement())
    elseif kind == Kind.ExportDeclaration or kind == Kind.ImportDeclaration or kind == Kind.ImportClause then
        if tx.currentNamespace ~= nil and tx.currentScope ~= nil and tx.currentScope.kind ~= Kind.Block then
            -- do not emit ES6 imports and exports since they are illegal inside a namespace
            node = nil
        else
            node = tx:Visitor():VisitEachChild(node)
        end
    elseif kind == Kind.ImportEqualsDeclaration then
        if tx.currentNamespace ~= nil and tx.currentScope ~= nil and tx.currentScope.kind ~= Kind.Block and node:AsImportEqualsDeclaration().moduleReference.kind == Kind.ExternalModuleReference then
            -- do not emit ES6 imports and exports since they are illegal inside a namespace
            node = nil
        elseif tx.currentNamespace ~= nil and tx.currentScope ~= nil and tx.currentScope.kind == Kind.Block and node:AsImportEqualsDeclaration().moduleReference.kind ~= Kind.ExternalModuleReference then
            -- inside a block within a namespace, elide internal import aliases
            node = nil
        else
            node = tx:visitImportEqualsDeclaration(node:AsImportEqualsDeclaration())
        end
    elseif kind == Kind.Identifier then
        node = tx:visitIdentifier(node)
    elseif kind == Kind.ShorthandPropertyAssignment then
        node = tx:visitShorthandPropertyAssignment(node:AsShorthandPropertyAssignment())
    else
        node = tx:Visitor():VisitEachChild(node)
    end
    return node
end

-- Visits each node in the AST
function RuntimeSyntaxTransformer:visit(node)
    local grandparentNode = self:pushNode(node)
    local savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName = self:pushScope(node)
    local result = visitWorker(self, node)
    self:popScope(savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName)
    self:popNode(grandparentNode)
    return result
end

-- Records that a declaration was emitted in the current scope, if it was the first declaration for the provided symbol.
function RuntimeSyntaxTransformer:recordDeclarationInScope(node)
    local kind = node.kind
    if kind == Kind.VariableStatement then
        self:recordDeclarationInScope(node:AsVariableStatement().declarationList)
        return
    elseif kind == Kind.VariableDeclarationList then
        for _, decl in ipairs(node:AsVariableDeclarationList().declarations.nodes or {}) do
            self:recordDeclarationInScope(decl)
        end
        return
    elseif kind == Kind.ArrayBindingPattern or kind == Kind.ObjectBindingPattern then
        for _, element in ipairs(node:Elements() or {}) do
            self:recordDeclarationInScope(element)
        end
        return
    end
    local name = node:Name()
    if name ~= nil then
        if ast.IsIdentifier(name) then
            if self.currentScopeFirstDeclarationsOfName == nil then
                self.currentScopeFirstDeclarationsOfName = {}
            end
            local text = name:Text()
            if self.currentScopeFirstDeclarationsOfName[text] == nil then
                self.currentScopeFirstDeclarationsOfName[text] = node
            end
        elseif ast.IsBindingPattern(name) then
            self:recordDeclarationInScope(name)
        end
    end
end

-- Determines whether a declaration is the first declaration with the same name emitted in the current scope.
function RuntimeSyntaxTransformer:isFirstDeclarationInScope(node)
    local name = node:Name()
    if name ~= nil and ast.IsIdentifier(name) then
        local text = name:Text()
        local firstDeclaration
        if self.currentScopeFirstDeclarationsOfName ~= nil then
            firstDeclaration = self.currentScopeFirstDeclarationsOfName[text]
        end
        if firstDeclaration ~= nil then
            return firstDeclaration == node
        end
    end
    return false
end

function RuntimeSyntaxTransformer:isExportOfNamespace(node)
    return self.currentNamespace ~= nil and (self.currentScope == nil or self.currentScope.kind ~= Kind.Block) and node:ModifierFlags() & ModifierFlags.Export ~= 0
end

-- Gets an expression that represents a property name, such as `"foo"` for the identifier `foo`.
function RuntimeSyntaxTransformer:getExpressionForPropertyName(member)
    local name = member:Name()
    local kind = name.kind
    if kind == Kind.PrivateIdentifier then
        return self:Factory():NewIdentifier("")
    elseif kind == Kind.ComputedPropertyName then
        local n = name:AsComputedPropertyName()
        -- enums don't support computed properties so we always generate the 'expression' part of the name as-is.
        return self:Visitor():VisitNode(n.expression)
    elseif kind == Kind.Identifier then
        return self:Factory():NewStringLiteral(name:Text(), ast.TokenFlags.None)
    elseif kind == Kind.StringLiteral then -- !!! propagate token flags (will produce new diffs)
        return self:Factory():NewStringLiteral(name:Text(), ast.TokenFlags.None)
    elseif kind == Kind.NumericLiteral then
        return self:Factory():NewNumericLiteral(name:Text(), ast.TokenFlags.None)
    else
        return name
    end
end

-- Gets an expression like `E["A"]` that references an enum member.
function RuntimeSyntaxTransformer:getEnumQualifiedElement(enum, member)
    local prop = self:getNamespaceQualifiedElement(self:getNamespaceContainerName(enum:AsNode()), self:getExpressionForPropertyName(member))
    self:EmitContext():AddEmitFlags(prop, EF.EFNoComments | EF.EFNoNestedComments | EF.EFNoSourceMap | EF.EFNoNestedSourceMaps)
    return prop
end

-- Gets an expression used to refer to a namespace or enum from within the body of its declaration.
function RuntimeSyntaxTransformer:getNamespaceContainerName(node)
    return self:Factory():NewGeneratedNameForNode(node)
end

-- Gets an expression used to refer to an export of a namespace or a member of an enum by property name.
function RuntimeSyntaxTransformer:getNamespaceQualifiedProperty(ns, name)
    return self:Factory():GetNamespaceMemberName(ns, name, { allowSourceMaps = true })
end

-- Gets an expression used to refer to an export of a namespace or a member of an enum by indexed access.
function RuntimeSyntaxTransformer:getNamespaceQualifiedElement(ns, expression)
    local qualifiedName = self:EmitContext().factory:NewElementAccessExpression(ns, nil --[[questionDotToken]], expression, NodeFlags.None)
    self:EmitContext():AssignCommentAndSourceMapRanges(qualifiedName, expression)
    return qualifiedName
end

-- Gets an expression used within the provided node's container for any exported references.
function RuntimeSyntaxTransformer:getExportQualifiedReferenceToDeclaration(node)
    if self:isExportOfNamespace(node:AsNode()) then
        return self:Factory():GetExternalModuleOrNamespaceExportName(self:getNamespaceContainerName(self.currentNamespace), node, false --[[allowComments]], true --[[allowSourceMaps]])
    end
    return self:Factory():GetDeclarationNameEx(node:AsNode(), { allowSourceMaps = true })
end

function RuntimeSyntaxTransformer:addVarForDeclaration(statements, node)
    self:recordDeclarationInScope(node)
    if not self:isFirstDeclarationInScope(node) then
        return statements, false
    end

    -- var name;
    local name = self:Factory():GetLocalNameEx(node, { allowSourceMaps = true })
    local varDecl = self:Factory():NewVariableDeclaration(name, nil, nil, nil)
    local varFlags = core.IfElse(self.currentScope == self.currentSourceFile, NodeFlags.None, NodeFlags.Let)
    local varDecls = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), varFlags)
    -- Replicate modifierVisitor: strip decorators, TypeScript modifiers, and export when in namespace.
    local modifierMask = ~(ModifierFlags.TypeScriptModifier | ModifierFlags.Decorator)
    if self.currentNamespace ~= nil then
        modifierMask = modifierMask & ~ModifierFlags.Export
    end
    local modifiers = transformers.ExtractModifiers(self:EmitContext(), node:Modifiers(), modifierMask)
    local varStatement = self:Factory():NewVariableStatement(modifiers, varDecls)

    self:EmitContext():SetOriginal(varDecl, node)
    -- !!! synthetic comments
    self:EmitContext():SetOriginal(varStatement, node)

    -- Adjust the source map emit to match the old emitter.
    if ast.IsEnumDeclaration(node) then
        self:EmitContext():SetSourceMapRange(varDecls, node.loc)
    else
        self:EmitContext():SetSourceMapRange(varStatement, node.loc)
    end

    -- Trailing comments for enum declaration should be emitted after the function closure
    -- instead of the variable statement:
    --
    --     /** Leading comment*/
    --     enum E {
    --         A
    --     } // trailing comment
    --
    -- Should emit:
    --
    --     /** Leading comment*/
    --     var E;
    --     (function (E) {
    --         E[E["A"] = 0] = "A";
    --     })(E || (E = {})); // trailing comment
    --
    self:EmitContext():SetCommentRange(varStatement, node.loc)
    self:EmitContext():AddEmitFlags(varStatement, EF.EFNoTrailingComments)
    statements[#statements + 1] = varStatement

    return statements, true
end

function RuntimeSyntaxTransformer:visitEnumDeclaration(node)
    if not self:shouldEmitEnumDeclaration(node) then
        return self:EmitContext():NewNotEmittedStatement(node:AsNode())
    end

    local statements = {}

    -- If needed, we should emit a variable declaration for the enum:
    --  var name;
    local varAdded
    statements, varAdded = self:addVarForDeclaration(statements, node:AsNode())

    -- If we emit a leading variable declaration, we should not emit leading comments for the enum body, but we should
    -- still emit the comments if we are emitting to a System module.
    local emitFlags = EF.EFNone
    if varAdded and (self.compilerOptions:GetEmitModuleKind() ~= core.ModuleKind.System or self.currentScope ~= self.currentSourceFile) then
        emitFlags = emitFlags | EF.EFNoLeadingComments
    end

    --  x || (x = {})
    --  exports.x || (exports.x = {})
    local enumArg = self:Factory():NewLogicalORExpression(
        self:getExportQualifiedReferenceToDeclaration(node:AsNode()),
        self:Factory():NewAssignmentExpression(
            self:getExportQualifiedReferenceToDeclaration(node:AsNode()),
            self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({}), false)
        )
    )

    if self:isExportOfNamespace(node:AsNode()) then
        -- `localName` is the expression used within this node's containing scope for any local references.
        local localName = self:Factory():GetLocalNameEx(node:AsNode(), { allowSourceMaps = true })

        --  x = (exports.x || (exports.x = {}))
        enumArg = self:Factory():NewAssignmentExpression(localName, enumArg)
    end

    -- (function (name) { ... })(name || (name = {}))
    local enumParamName = self:Factory():NewGeneratedNameForNode(node:AsNode())
    self:EmitContext():SetSourceMapRange(enumParamName, node:Name().loc)

    local enumParam = self:Factory():NewParameterDeclaration(nil, nil, enumParamName, nil, nil, nil)
    local enumBody = self:transformEnumBody(node)
    local enumFunc = self:Factory():NewFunctionExpression(nil, nil, nil, nil, self:Factory():NewNodeList({ enumParam }), nil, nil, enumBody)
    local enumCall = self:Factory():NewCallExpression(self:Factory():NewParenthesizedExpression(enumFunc), nil, nil, self:Factory():NewNodeList({ enumArg }), NodeFlags.None)
    local enumStatement = self:Factory():NewExpressionStatement(enumCall)
    self:EmitContext():SetOriginal(enumStatement, node:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(enumStatement, node:AsNode())
    self:EmitContext():AddEmitFlags(enumStatement, emitFlags)
    statements[#statements + 1] = enumStatement
    return self:Factory():NewSyntaxList(statements)
end

-- Transforms the body of an enum declaration.
function RuntimeSyntaxTransformer:transformEnumBody(node)
    local savedCurrentEnum = self.currentEnum
    self.currentEnum = node:AsNode()

    -- visit the children of `node` in advance to capture any references to enum members
    node = self:Visitor():VisitEachChild(node:AsNode()):AsEnumDeclaration()

    local statements = {}
    for i = 0, core.Len(node.members.nodes) - 1 do
        --  E[E["A"] = 0] = "A";
        statements = self:transformEnumMember(
            statements,
            node,
            i
        )
    end

    local statementList = self:Factory():NewNodeList(statements)
    statementList.loc = node.members.loc

    self.currentEnum = savedCurrentEnum
    return self:Factory():NewBlock(statementList, true --[[multiline]])
end

-- Transforms an enum member into a statement. It is expected that `enum` has already been visited.
function RuntimeSyntaxTransformer:transformEnumMember(statements, enum, index)
    local memberNode = enum.members.nodes[index + 1]
    local member = memberNode:AsEnumMember()

    local savedParent = self.parentNode
    self.parentNode = self.currentNode
    self.currentNode = memberNode

    --  E[E["A"] = x] = "A";
    --             ^
    local expression = member.initializer -- NOTE: already visited

    local useExplicitReverseMapping = false

    local parseNode = self:EmitContext():ParseNode(memberNode)
    local result = self.emitResolver:GetEnumMemberValue(parseNode)
    local value = result.value
    if type(value) == "number" then
        expression = core.Coalesce(tstransforms.constantExpression(value, self:Factory()), expression)
        useExplicitReverseMapping = true
    elseif type(value) == "string" then
        expression = core.Coalesce(tstransforms.constantExpression(value, self:Factory()), expression)
    else
        if expression == nil then
            expression = self:Factory():NewVoidZeroExpression()
        end
        useExplicitReverseMapping = not result.isSyntacticallyString
    end

    -- Define the enum member property:
    --  E[E["A"] = 0] = "A";
    --    ^^^^^^^^--_____
    expression = self:Factory():NewAssignmentExpression(
        self:getEnumQualifiedElement(enum, member),
        expression
    )

    if useExplicitReverseMapping then
        --  E[E["A"] = 0] = "A";
        --  ^^--------------^^^^^
        expression = self:Factory():NewAssignmentExpression(
            self:Factory():NewElementAccessExpression(
                self:getNamespaceContainerName(enum:AsNode()),
                nil, --[[questionDotToken]]
                expression,
                NodeFlags.None
            ),
            self:getExpressionForPropertyName(member)
        )
    end

    local memberStatement = self:Factory():NewExpressionStatement(expression)
    self:EmitContext():AssignCommentAndSourceMapRanges(expression, member:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(memberStatement, member:AsNode())
    statements[#statements + 1] = memberStatement

    self.currentNode = self.parentNode
    self.parentNode = savedParent
    return statements
end

function RuntimeSyntaxTransformer:visitModuleDeclaration(node)
    if not self:shouldEmitModuleDeclaration(node) then
        return self:EmitContext():NewNotEmittedStatement(node:AsNode())
    end

    local statements = {}

    -- If needed, we should emit a variable declaration for the module:
    --  var name;
    local varAdded
    statements, varAdded = self:addVarForDeclaration(statements, node:AsNode())

    -- If we emit a leading variable declaration, we should not emit leading comments for the module body, but we should
    -- still emit the comments if we are emitting to a System module.
    local emitFlags = EF.EFNone
    if varAdded and (self.compilerOptions:GetEmitModuleKind() ~= core.ModuleKind.System or self.currentScope ~= self.currentSourceFile) then
        emitFlags = emitFlags | EF.EFNoLeadingComments
    end

    --  x || (x = {})
    --  exports.x || (exports.x = {})
    local moduleArg = self:Factory():NewLogicalORExpression(
        self:getExportQualifiedReferenceToDeclaration(node:AsNode()),
        self:Factory():NewAssignmentExpression(
            self:getExportQualifiedReferenceToDeclaration(node:AsNode()),
            self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({}), false)
        )
    )

    if self:isExportOfNamespace(node:AsNode()) then
        -- `localName` is the expression used within this node's containing scope for any local references.
        local localName = self:Factory():GetLocalNameEx(node:AsNode(), { allowSourceMaps = true })

        --  x = (exports.x || (exports.x = {}))
        moduleArg = self:Factory():NewAssignmentExpression(localName, moduleArg)
    end

    -- (function (name) { ... })(name || (name = {}))
    local moduleParamName = self:Factory():NewGeneratedNameForNode(node:AsNode())
    self:EmitContext():SetSourceMapRange(moduleParamName, node:Name().loc)

    local moduleParam = self:Factory():NewParameterDeclaration(nil, nil, moduleParamName, nil, nil, nil)
    local moduleBody = self:transformModuleBody(node, self:getNamespaceContainerName(node:AsNode()))
    local moduleFunc = self:Factory():NewFunctionExpression(nil, nil, nil, nil, self:Factory():NewNodeList({ moduleParam }), nil, nil, moduleBody)
    local moduleCall = self:Factory():NewCallExpression(self:Factory():NewParenthesizedExpression(moduleFunc), nil, nil, self:Factory():NewNodeList({ moduleArg }), NodeFlags.None)
    local moduleStatement = self:Factory():NewExpressionStatement(moduleCall)
    self:EmitContext():SetOriginal(moduleStatement, node:AsNode())
    self:EmitContext():AssignCommentAndSourceMapRanges(moduleStatement, node:AsNode())
    self:EmitContext():AddEmitFlags(moduleStatement, emitFlags)
    statements[#statements + 1] = moduleStatement
    return self:Factory():NewSyntaxList(statements)
end

function RuntimeSyntaxTransformer:transformModuleBody(node, namespaceLocalName) -- luacheck: ignore 212/namespaceLocalName
    local savedCurrentNamespace = self.currentNamespace
    local savedCurrentScope = self.currentScope
    local savedCurrentScopeFirstDeclarationsOfName = self.currentScopeFirstDeclarationsOfName

    self.currentNamespace = node:AsNode()
    self.currentScopeFirstDeclarationsOfName = nil

    local statements
    self:EmitContext():StartVariableEnvironment()

    local statementsLocation = core.NewTextRange(0, 0)
    local blockLocation = core.NewTextRange(0, 0)
    if node.body ~= nil then
        if node.body.kind == Kind.ModuleBlock then
            -- visit the children of `node` in advance to capture any references to namespace members
            node = self:Visitor():VisitEachChild(node:AsNode()):AsModuleDeclaration()
            local body = node.body:AsModuleBlock()
            statements = body.statements.nodes
            statementsLocation = body.statements.loc
            blockLocation = body.loc
        else -- node.body.kind == Kind.ModuleDeclaration
            -- !!! Strada didn't do this; why?
            -- tx.currentScope = node.AsNode()
            statements = self:Visitor():VisitSlice({ node.body })
            local moduleBlock = tstransforms.getInnermostModuleDeclarationFromDottedModule(node).body:AsModuleBlock()
            statementsLocation = moduleBlock.statements.loc:WithPos(-1)
        end
    end

    self.currentNamespace = savedCurrentNamespace
    self.currentScope = savedCurrentScope
    self.currentScopeFirstDeclarationsOfName = savedCurrentScopeFirstDeclarationsOfName

    statements = self:EmitContext():EndAndMergeVariableEnvironment(statements)
    local statementList = self:Factory():NewNodeList(statements)
    statementList.loc = statementsLocation
    local block = self:Factory():NewBlock(statementList, true --[[multiline]])
    block.loc = blockLocation

    --  namespace hello.hi.world {
    --       function foo() {}
    --
    --       // TODO, blah
    --  }
    --
    -- should be emitted as
    --
    --  var hello;
    --  (function (hello) {
    --      var hi;
    --      (function (hi) {
    --          var world;
    --          (function (world) {
    --              function foo() { }
    --              // TODO, blah
    --          })(world = hi.world || (hi.world = {}));
    --      })(hi = hello.hi || (hello.hi = {}));
    --  })(hello || (hello = {}));
    --
    -- We only want to emit comment on the namespace which contains block body itself, not the containing namespaces.
    if node.body == nil or node.body.kind ~= Kind.ModuleBlock then
        self:EmitContext():AddEmitFlags(block, EF.EFNoComments)
    end
    return block
end

function RuntimeSyntaxTransformer:visitImportEqualsDeclaration(node)
    if node.moduleReference.kind == Kind.ExternalModuleReference then
        return self:Visitor():VisitEachChild(node:AsNode())
    end

    local moduleReference = self:Factory():CreateExpressionFromEntityName(node.moduleReference)
    self:EmitContext():SetEmitFlags(moduleReference, EF.EFNoComments | EF.EFNoNestedComments)
    if not self:isExportOfNamespace(node:AsNode()) then
        --  export var ${name} = ${moduleReference};
        --  var ${name} = ${moduleReference};
        local varDecl = self:Factory():NewVariableDeclaration(node:Name(), nil --[[exclamationToken]], nil --[[type]], moduleReference)
        self:EmitContext():SetOriginal(varDecl, node:AsNode())
        local varList = self:Factory():NewVariableDeclarationList(self:Factory():NewNodeList({ varDecl }), NodeFlags.None)
        local varModifiers = transformers.ExtractModifiers(self:EmitContext(), node:Modifiers(), ModifierFlags.Export)
        local varStatement = self:Factory():NewVariableStatement(varModifiers, varList)
        self:EmitContext():SetOriginal(varStatement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(varStatement, node:AsNode())
        return varStatement
    else
        -- exports.${name} = ${moduleReference};
        local statement = self:createExportStatement(node:Name(), moduleReference, node.loc, node.loc, node:AsNode())
        statement.loc = node.loc
        return statement
    end
end

function RuntimeSyntaxTransformer:visitVariableStatement(node)
    if self:isExportOfNamespace(node:AsNode()) then
        local expressions = {}
        for _, declaration in ipairs(node.declarationList:AsVariableDeclarationList().declarations.nodes or {}) do
            local v = declaration:AsVariableDeclaration()
            if v.initializer == nil then
                goto continue
            end
            if ast.IsBindingPattern(v:Name()) then
                local expression = transformers.FlattenDestructuringAssignment(
                    self,
                    self:Visitor():VisitNode(declaration),
                    false, --[[needsValue]]
                    transformers.FlattenLevel.All,
                    function(exportName, exportValue, location) return self:createNamespaceExportExpression(exportName, exportValue, location) end
                )
                if expression ~= nil then
                    expressions[#expressions + 1] = expression
                end
            else
                local expression = transformers.ConvertVariableDeclarationToAssignmentExpression(self:EmitContext(), v)
                if expression ~= nil then
                    expressions[#expressions + 1] = expression
                end
            end
            ::continue::
        end
        if #expressions == 0 then
            return nil
        end
        local expression = self:Factory():InlineExpressions(expressions)
        local statement = self:Factory():NewExpressionStatement(expression)
        self:EmitContext():SetOriginal(statement, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(statement, node:AsNode())

        -- re-visit as the new node
        local savedCurrent = self.currentNode
        self.currentNode = statement
        statement = self:Visitor():VisitEachChild(statement)
        self.currentNode = savedCurrent
        return statement
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- createNamespaceExportExpression creates an assignment to a namespace member for use as a
-- callback during destructuring flattening.
function RuntimeSyntaxTransformer:createNamespaceExportExpression(exportName, exportValue, location)
    local memberName = self:getNamespaceQualifiedProperty(self:getNamespaceContainerName(self.currentNamespace), exportName)
    local expression = self:Factory():NewAssignmentExpression(memberName, exportValue)
    if location ~= nil then
        expression.loc = location
    end
    return expression
end

function RuntimeSyntaxTransformer:visitFunctionDeclaration(node)
    if self:isExportOfNamespace(node:AsNode()) then
        local updated = self:Factory():UpdateFunctionDeclaration(
            node,
            self:Visitor():VisitModifiers(transformers.ExtractModifiers(self:EmitContext(), node:Modifiers(), ~ModifierFlags.Export)),
            node.asteriskToken,
            self:Visitor():VisitNode(node:Name()),
            nil, --[[typeParameters]]
            self:Visitor():VisitNodes(node.parameters),
            nil, --[[returnType]]
            nil, --[[fullSignature]]
            self:Visitor():VisitNode(node.body)
        )
        local export = self:createExportStatementForDeclaration(node:AsNode())
        if export ~= nil then
            return self:Factory():NewSyntaxList({ updated, export })
        end
        return updated
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function RuntimeSyntaxTransformer:getParameterProperties(constructor)
    local parameterProperties
    if constructor ~= nil then
        for _, parameter in ipairs(constructor:Parameters() or {}) do
            if ast.IsParameterPropertyDeclaration(parameter, constructor) then
                parameterProperties = core.Append(parameterProperties, parameter:AsParameterDeclaration())
            end
        end
    end
    return parameterProperties
end

function RuntimeSyntaxTransformer:visitClassDeclaration(node)
    local exported = self:isExportOfNamespace(node:AsNode())
    local modifiers
    if exported then
        modifiers = self:Visitor():VisitModifiers(transformers.ExtractModifiers(self:EmitContext(), node:Modifiers(), ~ModifierFlags.ExportDefault))
    else
        modifiers = self:Visitor():VisitModifiers(node:Modifiers())
    end

    local name = self:Visitor():VisitNode(node:Name())
    if name == nil and (exported or ast.ChildIsDecorated(core.Tristate_IsTrue(self.compilerOptions.experimentalDecorators), node:AsNode(), nil)) then
        name = self:Factory():NewGeneratedNameForNode(node:AsNode())
    end
    local heritageClauses = self:Visitor():VisitNodes(node.heritageClauses)
    local members = self:Visitor():VisitNodes(node.members)
    local parameterProperties = self:getParameterProperties(core.Find(node.members.nodes, ast.IsConstructorDeclaration))

    if core.Len(parameterProperties) > 0 then
        local newMembers
        for _, parameter in ipairs(parameterProperties) do
            if ast.IsIdentifier(parameter:Name()) then
                local parameterProperty = self:Factory():NewPropertyDeclaration(
                    nil, --[[modifiers]]
                    parameter:Name():Clone(self:Factory()),
                    nil, --[[questionOrExclamationToken]]
                    nil, --[[type]]
                    nil --[[initializer]]
                )
                self:EmitContext():SetOriginal(parameterProperty, parameter:AsNode())
                newMembers = core.Append(newMembers, parameterProperty)
            end
        end
        if core.Len(newMembers) > 0 then
            newMembers = core.AppendAll(newMembers, members.nodes)
            members = self:Factory():NewNodeList(newMembers)
            members.loc = node.members.loc
        end
    end

    local updated = self:Factory():UpdateClassDeclaration(node, modifiers, name, nil --[[typeParameters]], heritageClauses, members)
    if exported then
        local export = self:createExportStatementForDeclaration(node:AsNode())
        if export ~= nil then
            return self:Factory():NewSyntaxList({ updated, export })
        end
    end
    return updated
end

function RuntimeSyntaxTransformer:visitClassExpression(node)
    local modifiers = self:Visitor():VisitModifiers(transformers.ExtractModifiers(self:EmitContext(), node:Modifiers(), ~ModifierFlags.ExportDefault))
    local name = self:Visitor():VisitNode(node:Name())
    local heritageClauses = self:Visitor():VisitNodes(node.heritageClauses)
    local members = self:Visitor():VisitNodes(node.members)
    local parameterProperties = self:getParameterProperties(core.Find(node.members.nodes, ast.IsConstructorDeclaration))

    if core.Len(parameterProperties) > 0 then
        local newMembers
        for _, parameter in ipairs(parameterProperties) do
            if ast.IsIdentifier(parameter:Name()) then
                local parameterProperty = self:Factory():NewPropertyDeclaration(
                    nil, --[[modifiers]]
                    parameter:Name():Clone(self:Factory()),
                    nil, --[[questionOrExclamationToken]]
                    nil, --[[type]]
                    nil --[[initializer]]
                )
                self:EmitContext():SetOriginal(parameterProperty, parameter:AsNode())
                newMembers = core.Append(newMembers, parameterProperty)
            end
        end
        if core.Len(newMembers) > 0 then
            newMembers = core.AppendAll(newMembers, members.nodes)
            members = self:Factory():NewNodeList(newMembers)
            members.loc = node.members.loc
        end
    end

    return self:Factory():UpdateClassExpression(node, modifiers, name, nil --[[typeParameters]], heritageClauses, members)
end

function RuntimeSyntaxTransformer:visitConstructorDeclaration(node)
    local modifiers = self:Visitor():VisitModifiers(node:Modifiers())
    local parameters = self:EmitContext():VisitParameters(node:ParameterList(), self:Visitor())
    local body = self:visitConstructorBody(node.body:AsBlock(), node:AsNode())
    return self:Factory():UpdateConstructorDeclaration(node, modifiers, nil --[[typeParameters]], parameters, nil --[[returnType]], nil --[[fullSignature]], body)
end

function RuntimeSyntaxTransformer:visitConstructorBody(body, constructor)
    local parameterProperties = self:getParameterProperties(constructor)
    if core.Len(parameterProperties) == 0 then
        return self:EmitContext():VisitFunctionBody(body:AsNode(), self:Visitor())
    end

    local grandparentOfBody = self:pushNode(body:AsNode())
    local savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName = self:pushScope(body:AsNode())

    self:EmitContext():StartVariableEnvironment()
    local prologue, rest = self:Factory():SplitStandardPrologue(body.statements.nodes)
    local statements = core.AppendAll({}, prologue)

    -- Transform parameters into property assignments. Transforms this:
    --
    --  constructor (public x, public y) {
    --  }
    --
    -- Into this:
    --
    --  constructor (x, y) {
    --      this.x = x;
    --      this.y = y;
    --  }
    --

    local parameterPropertyAssignments
    for _, parameter in ipairs(parameterProperties) do
        if ast.IsIdentifier(parameter:Name()) then
            local propertyName = parameter:Name():Clone(self:Factory())
            propertyName.parent = parameter:Name().parent -- .Parent set to get node to printback using text from original file instead of processed text; TODO: this should be achievable via EmitFlags instead
            self:EmitContext():AddEmitFlags(propertyName, EF.EFNoComments | EF.EFNoSourceMap)

            local localName = parameter:Name():Clone(self:Factory())
            localName.parent = parameter:Name().parent -- .Parent set to get node to printback using text from original file instead of processed text; TODO: this should be achievable via EmitFlags instead
            self:EmitContext():AddEmitFlags(localName, EF.EFNoComments)

            local parameterProperty = self:Factory():NewExpressionStatement(
                self:Factory():NewAssignmentExpression(
                    self:Factory():NewPropertyAccessExpression(
                        self:Factory():NewThisExpression(),
                        nil, --[[questionDotToken]]
                        propertyName,
                        NodeFlags.None
                    ),
                    localName
                )
            )
            self:EmitContext():SetOriginal(parameterProperty, parameter:AsNode())
            self:EmitContext():AddEmitFlags(parameterProperty, EF.EFStartOnNewLine)
            parameterPropertyAssignments = core.Append(parameterPropertyAssignments, parameterProperty)
        end
    end

    local superPath = transformers.FindSuperStatementIndexPath(rest, 0)

    if core.Len(superPath) > 0 then
        statements = core.AppendAll(statements, self:transformConstructorBodyWorker(rest, superPath, parameterPropertyAssignments))
    else
        statements = core.AppendAll(statements, parameterPropertyAssignments)
        statements = core.AppendAll(statements, (self:Visitor():VisitSlice(rest)))
    end

    statements = self:EmitContext():EndAndMergeVariableEnvironment(statements)
    local statementList = self:Factory():NewNodeList(statements)
    statementList.loc = body.statements.loc

    self:popScope(savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName)
    self:popNode(grandparentOfBody)
    local updated = self:Factory():NewBlock(statementList --[[multiline]], true)
    self:EmitContext():SetOriginal(updated, body:AsNode())
    updated.loc = body.loc
    return updated
end

-- Go slice expression s[a:b] (0-based, half-open) as a fresh Lua array.
local function subslice(s, a, b)
    local out = {}
    for i = a + 1, b do
        out[#out + 1] = s[i]
    end
    return out
end

function RuntimeSyntaxTransformer:transformConstructorBodyWorker(statementsIn, superPath, initializerStatements)
    local statementsOut = nil
    local superStatementIndex = superPath[1]
    local superStatement = statementsIn[superStatementIndex + 1]

    -- visit up to the statement containing `super`
    statementsOut = core.AppendAll(statementsOut, (self:Visitor():VisitSlice(subslice(statementsIn, 0, superStatementIndex))))

    -- if the statement containing `super` is a `try` statement, transform the body of the `try` block
    if ast.IsTryStatement(superStatement) then
        local tryStatement = superStatement:AsTryStatement()
        local tryBlock = tryStatement.tryBlock:AsBlock()

        -- keep track of hierarchy as we descend
        local grandparentOfTryStatement = self:pushNode(tryStatement:AsNode())
        local grandparentOfTryBlock = self:pushNode(tryBlock:AsNode())
        local savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName = self:pushScope(tryBlock:AsNode())

        -- visit the `try` block
        local tryBlockStatements = self:transformConstructorBodyWorker(
            tryBlock.statements.nodes,
            subslice(superPath, 1, #superPath),
            initializerStatements
        )

        -- restore hierarchy as we ascend to the `try` statement
        self:popScope(savedCurrentScope, savedCurrentScopeFirstDeclarationsOfName)
        self:popNode(grandparentOfTryBlock)

        local tryBlockStatementList = self:Factory():NewNodeList(tryBlockStatements)
        tryBlockStatementList.loc = tryBlock.statements.loc
        statementsOut = core.Append(statementsOut, self:Factory():UpdateTryStatement(
            tryStatement,
            self:Factory():UpdateBlock(tryBlock, tryBlockStatementList, tryBlock.multiLine),
            self:Visitor():VisitNode(tryStatement.catchClause),
            self:Visitor():VisitNode(tryStatement.finallyBlock)
        ))

        -- restore hierarchy as we ascend to the parent of the `try` statement
        self:popNode(grandparentOfTryStatement)
    else
        -- visit the statement containing `super`
        statementsOut = core.AppendAll(statementsOut, (self:Visitor():VisitSlice(subslice(statementsIn, superStatementIndex, superStatementIndex + 1))))

        -- insert the initializer statements
        statementsOut = core.AppendAll(statementsOut, initializerStatements)
    end

    -- visit the statements after `super`
    statementsOut = core.AppendAll(statementsOut, (self:Visitor():VisitSlice(subslice(statementsIn, superStatementIndex + 1, #statementsIn))))
    return statementsOut
end

function RuntimeSyntaxTransformer:visitShorthandPropertyAssignment(node)
    local name = node:Name()
    local exportedOrImportedName = self:visitExpressionIdentifier(name)
    if exportedOrImportedName ~= name then
        local expression = exportedOrImportedName
        if node.objectAssignmentInitializer ~= nil then
            local equalsToken = node.equalsToken
            if equalsToken == nil then
                equalsToken = self:Factory():NewToken(Kind.EqualsToken)
            end
            expression = self:Factory():NewBinaryExpression(
                nil, --[[modifiers]]
                expression,
                nil, --[[typeNode]]
                equalsToken,
                self:Visitor():VisitNode(node.objectAssignmentInitializer)
            )
        end

        local updated = self:Factory():NewPropertyAssignment(nil --[[modifiers]], node:Name(), nil --[[postfixToken]], nil --[[typeNode]], expression)
        updated.loc = node.loc
        self:EmitContext():SetOriginal(updated, node:AsNode())
        self:EmitContext():AssignCommentAndSourceMapRanges(updated, node:AsNode())
        return updated
    end
    return self:Factory():UpdateShorthandPropertyAssignment(
        node,
        nil, --[[modifiers]]
        exportedOrImportedName,
        nil, --[[postfixToken]]
        nil, --[[typeNode]]
        node.equalsToken,
        self:Visitor():VisitNode(node.objectAssignmentInitializer)
    )
end

function RuntimeSyntaxTransformer:visitIdentifier(node)
    if transformers.IsIdentifierReference(node, self.parentNode) then
        return self:visitExpressionIdentifier(node)
    end
    return node
end

function RuntimeSyntaxTransformer:visitExpressionIdentifier(node)
    if (self.currentEnum ~= nil or self.currentNamespace ~= nil) and not transformers.IsGeneratedIdentifier(self:EmitContext(), node) and not transformers.IsLocalName(self:EmitContext(), node) then
        local location = self:EmitContext():MostOriginal(node:AsNode())
        local container = self.resolver:GetReferencedExportContainer(location, false --[[prefixLocals]])
        if container ~= nil and (ast.IsEnumDeclaration(container) or ast.IsModuleDeclaration(container)) then
            local containerName = self:getNamespaceContainerName(container)

            local memberName = node:Clone(self:Factory())
            self:EmitContext():SetEmitFlags(memberName, EF.EFNoComments | EF.EFNoSourceMap)

            local expression = self:Factory():GetNamespaceMemberName(containerName, memberName, { allowSourceMaps = true })
            self:EmitContext():AssignCommentAndSourceMapRanges(expression, node:AsNode())
            return expression
        end
    end
    return node
end

function RuntimeSyntaxTransformer:createExportStatementForDeclaration(node)
    local exportName = self:Factory():GetExternalModuleOrNamespaceExportName(self:getNamespaceContainerName(self.currentNamespace), node, false --[[allowComments]], true --[[allowSourceMaps]])
    local localName = self:Factory():GetLocalName(node)
    local expression = self:Factory():NewAssignmentExpression(exportName, localName)
    local exportAssignmentSourceMapRange = node.loc
    if node:Name() ~= nil then
        exportAssignmentSourceMapRange = exportAssignmentSourceMapRange:WithPos(node:Name():Pos())
    end
    self:EmitContext():SetSourceMapRange(expression, exportAssignmentSourceMapRange)

    local statement = self:Factory():NewExpressionStatement(expression)
    local exportStatementSourceMapRange = node.loc:WithPos(-1)
    self:EmitContext():SetSourceMapRange(statement, exportStatementSourceMapRange)
    return statement
end

function RuntimeSyntaxTransformer:createExportAssignment(name, expression, exportAssignmentSourceMapRange, original)
    local exportName = self:getNamespaceQualifiedProperty(self:getNamespaceContainerName(self.currentNamespace), name)
    local exportAssignment = self:Factory():NewAssignmentExpression(exportName, expression)
    self:EmitContext():SetOriginal(exportAssignment, original)
    self:EmitContext():SetSourceMapRange(exportAssignment, exportAssignmentSourceMapRange)
    return exportAssignment
end

function RuntimeSyntaxTransformer:createExportStatement(name, expression, exportAssignmentSourceMapRange, exportStatementSourceMapRange, original)
    local exportStatement = self:Factory():NewExpressionStatement(self:createExportAssignment(name, expression, exportAssignmentSourceMapRange, original))
    self:EmitContext():SetOriginal(exportStatement, original)
    self:EmitContext():SetSourceMapRange(exportStatement, exportStatementSourceMapRange)
    return exportStatement
end

function RuntimeSyntaxTransformer:shouldEmitEnumDeclaration(node)
    return not ast.IsEnumConst(node:AsNode()) or self.compilerOptions:ShouldPreserveConstEnums()
end

function RuntimeSyntaxTransformer:shouldEmitModuleDeclaration(node)
    local pn = self:EmitContext():ParseNode(node:AsNode())
    if pn == nil then
        -- If we can't find a parse tree node, assume the node is instantiated.
        return true
    end
    return ast.IsInstantiatedModule(pn, self.compilerOptions:ShouldPreserveConstEnums())
end

function tstransforms.getInnermostModuleDeclarationFromDottedModule(moduleDeclaration)
    while moduleDeclaration.body ~= nil and moduleDeclaration.body.kind == Kind.ModuleDeclaration do
        moduleDeclaration = moduleDeclaration.body:AsModuleDeclaration()
    end
    return moduleDeclaration
end
