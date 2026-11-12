local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local transformers = require("tslua.transformers")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SubtreeFacts = ast.SubtreeFacts
local OEK = ast.OuterExpressionKinds
local EF = printer.EmitFlags
local PrivateIdentifierKind = printer.PrivateIdentifierKind

-- classFacts tracks various facts about a class being transformed.
local classFacts = {
    None = 0,
    ClassWasDecorated = 1 << 0,
    NeedsClassConstructorReference = 1 << 1,
    NeedsClassSuperReference = 1 << 2,
    NeedsSubstitutionForThisInClassStaticField = 1 << 3,
    WillHoistInitializersToConstructor = 1 << 4,
}
estransforms.classFacts = classFacts

-- privateIdentifierInfo stores information about a private identifier during transformation.
-- Fields:
--   kind: printer.PrivateIdentifierKind
--   brandCheckIdentifier can contain:
--    - For instance field: The WeakMap that will be the storage for the field.
--    - For instance methods or accessors: The WeakSet that will be used for brand checking.
--    - For static members: The constructor that will be used for brand checking.
--   isStatic stores if the identifier is static or not.
--   isValid stores if the identifier declaration is valid or not. Reserved names (e.g. #constructor)
--   or duplicate identifiers are considered invalid.
--   variableName contains the variable that will serve as the storage for a static field.
--   methodName is the identifier for a variable that will contain the private method implementation.
--   getterName is the identifier for a variable that will contain the private get accessor implementation, if any.
--   setterName is the identifier for a variable that will contain the private set accessor implementation, if any.
function estransforms.newPrivateIdentifierInfo(fields)
    local info = {
        kind = "",
        brandCheckIdentifier = nil,
        isStatic = false,
        isValid = false,
        variableName = nil,
        methodName = nil,
        getterName = nil,
        setterName = nil,
    }
    for k, v in pairs(fields or {}) do
        info[k] = v
    end
    return info
end

-- privateEnvironmentData stores class-scoped environment data for private identifiers:
--   { className (used for prefixing generated variable names), weakSetName (used for brand check on private methods) }
--
-- privateEnvironment stores a map of private identifier names to their transform info.
-- Like Strada, it uses two separate maps: one for non-generated identifiers (keyed by text)
-- and one for generated identifiers (keyed by original AST node). This prevents collisions
-- when different auto-accessors produce generated backing field names with the same text.
--   { data = privateEnvironmentData, members = { [string] = privateIdentifierInfo },
--     generatedIdentifiers = { [node] = privateIdentifierInfo } }
--
-- classLexicalEnvironment stores information about the lexical environment of a class:
--   { facts = classFacts, classConstructor (used for brand checks on static members, and `this`
--     references in static initializers), classThis, superClassReference (used for `super`
--     references in static initializers) }
function estransforms.newClassLexicalEnvironment()
    return { facts = classFacts.None, classConstructor = nil, classThis = nil, superClassReference = nil }
end

-- classLexicalEnv is a linked list of class lexical environments:
--   { previous = classLexicalEnv, data = classLexicalEnvironment, privateEnv = privateEnvironment }

local classFieldsTransformer = transformers.NewTransformerType()
estransforms.classFieldsTransformer = classFieldsTransformer

function estransforms.newClassFieldsTransformer(opts)
    local languageVersion = opts.compilerOptions:GetEmitScriptTarget()
    local useDefineForClassFields = opts.compilerOptions:GetUseDefineForClassFields()

    -- When targeting ESNext+ with useDefineForClassFields (the default), there are no class
    -- field transformations to perform and no prior transform sets EFTransformPrivateStaticElements,
    -- so every node would be returned unchanged. Skip entirely.
    if languageVersion >= core.ScriptTarget.ESNext and useDefineForClassFields then
        return nil
    end

    local tx = setmetatable({
        compilerOptions = opts.compilerOptions,
        resolver = opts.resolver,

        -- Computed configuration flags
        shouldTransformInitializersUsingSet = false,
        shouldTransformInitializersUsingDefine = false,
        shouldTransformInitializers = false,
        shouldTransformPrivateElementsOrClassStaticBlocks = false,
        shouldTransformAutoAccessors = false,
        shouldTransformThisInStaticInitializers = false,
        shouldTransformSuperInStaticInitializers = false,
        shouldTransformPrivateStaticElementsInFile = false,
        legacyDecorators = core.Tristate_IsTrue(opts.compilerOptions.experimentalDecorators),

        -- pendingExpressions tracks what computed name expressions originating from elided names
        -- must be inlined at the next execution site, in document order.
        pendingExpressions = nil,
        -- pendingStatements tracks what computed name expression statements and static property
        -- initializers must be emitted at the next execution site, in document order (for decorated classes).
        pendingStatements = nil,
        lexicalEnvironment = nil,
        currentClassContainer = nil,
        currentClassElement = nil,
        -- classAliases maps class declarations to alias identifiers for substituting class name
        -- references in static initializers. Replaces Strada's onSubstituteNode/trySubstituteClassAlias.
        classAliases = nil,
        enclosingClassDeclarations = collections.NewSet(),
        inIterationStatement = false,
        -- insideComputedPropertyName replaces Strada's onEmitNode for ComputedPropertyName, which
        -- switches to the outer lexical environment. Used by visitThisExpression() to apply
        -- the outer environment's substitution without requiring currentClassElement to be static.
        insideComputedPropertyName = false,
        parentNode = nil,
        currentNode = nil,
    }, classFieldsTransformer)

    -- Always transform field initializers using Set semantics when `useDefineForClassFields: false`.
    tx.shouldTransformInitializersUsingSet = not useDefineForClassFields

    -- Transform field initializers using Define semantics when `useDefineForClassFields: true` and target < ES2022.
    tx.shouldTransformInitializersUsingDefine = useDefineForClassFields and languageVersion < core.ScriptTarget.ES2022

    tx.shouldTransformInitializers = tx.shouldTransformInitializersUsingSet or tx.shouldTransformInitializersUsingDefine

    -- We need to transform private members and class static blocks when target < ES2022.
    tx.shouldTransformPrivateElementsOrClassStaticBlocks = languageVersion < core.ScriptTarget.ES2022

    -- We need to transform `accessor` fields when target < ESNext.
    -- We may need to transform `accessor` fields when `useDefineForClassFields: false`
    tx.shouldTransformAutoAccessors = languageVersion < core.ScriptTarget.ESNext

    -- We need to transform `this` in a static initializer into a reference to the class
    -- when target < ES2022 since the assignment will be moved outside of the class body.
    tx.shouldTransformThisInStaticInitializers = languageVersion < core.ScriptTarget.ES2022

    -- Since target is always >= ES2015, this is always the same as
    -- shouldTransformThisInStaticInitializers.
    tx.shouldTransformSuperInStaticInitializers = tx.shouldTransformThisInStaticInitializers

    local result = tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
    local ec = tx:EmitContext()
    tx.modifierVisitor = ec:NewNodeVisitor(function(node) return tx:visitModifier(node) end)
    tx.discardedValueVisitor = ec:NewNodeVisitor(function(node) return tx:visitDiscardedValue(node) end)
    tx.heritageClauseVisitor = ec:NewNodeVisitor(function(node) return tx:visitHeritageClause(node) end)
    tx.assignmentTargetVisitor = ec:NewNodeVisitor(function(node) return tx:visitAssignmentTarget(node) end)
    tx.classElementVisitor = ec:NewNodeVisitor(function(node) return tx:visitClassElement(node) end)
    tx.accessorFieldResultVisitor = ec:NewNodeVisitor(function(node) return tx:visitAccessorFieldResult(node) end)
    tx.arrayAssignmentElementVisitor = ec:NewNodeVisitor(function(node) return tx:visitArrayAssignmentElement(node) end)
    tx.objectAssignmentElementVisitor = ec:NewNodeVisitor(function(node) return tx:visitObjectAssignmentElement(node) end)
    tx.substitutionVisitor = ec:NewNodeVisitor(function(node) return tx:visitForSubstitution(node) end)
    tx.isAnonymousClassNeedingAssignedName = function(node) return tx:isAnonymousClassNeedingAssignedNameWorker(node) end

    return result
end

-- requiresBlockScopedVar returns true when private field temp variables should be
-- declared as block-scoped (let) rather than function-scoped (var). This occurs when
-- a class expression is directly inside a loop body.
-- Replaces Strada's resolver.hasNodeCheckFlag(node, NodeCheckFlags.BlockScopedBindingInLoop).
function classFieldsTransformer:requiresBlockScopedVar()
    return self.inIterationStatement and self.currentClassContainer ~= nil and ast.IsClassExpression(self.currentClassContainer)
end

-- classExpressionNeedsBlockScopedTemp returns true when the class expression's temp variable
-- must be block-scoped. This is more specific than requiresBlockScopedVar: the class temp only
-- needs to be block-scoped when the class expression has a non-static property with a computed
-- property name inside a loop (matching the checker's BlockScopedBindingInLoop on the class node).
function classFieldsTransformer:classExpressionNeedsBlockScopedTemp()
    if not self:requiresBlockScopedVar() then
        return false
    end
    for _, member in ipairs(self.currentClassContainer:Members() or {}) do
        if ast.IsPropertyDeclaration(member) and not ast.HasStaticModifier(member) and
            member:Name() ~= nil and ast.IsComputedPropertyName(member:Name()) then
            return true
        end
    end
    return false
end

function classFieldsTransformer:visitSourceFile(node)
    if node.isDeclarationFile then
        return node:AsNode()
    end
    self.lexicalEnvironment = nil
    self.shouldTransformPrivateStaticElementsInFile = self:EmitContext():EmitFlags(node:AsNode()) & EF.EFTransformPrivateStaticElements ~= 0
    self.classAliases = {}
    self.enclosingClassDeclarations:Clear()
    local visited = self:Visitor():VisitEachChild(node:AsNode())
    self:EmitContext():AddEmitHelper(visited, table.unpack(self:EmitContext():ReadEmitHelpers() or {}))
    self.classAliases = nil
    self.enclosingClassDeclarations:Clear()
    return visited
end

function classFieldsTransformer:visitModifier(node)
    if node.kind == Kind.AccessorKeyword then
        if self:shouldTransformAutoAccessorsInCurrentClass() then
            return nil
        end
        return node
    end
    if ast.IsModifier(node) then
        return node
    end
    return nil
end

function classFieldsTransformer:pushNode(node)
    local grandparentNode = self.parentNode
    self.parentNode = self.currentNode
    self.currentNode = node
    return grandparentNode
end

function classFieldsTransformer:popNode(grandparentNode)
    self.currentNode = self.parentNode
    self.parentNode = grandparentNode
end

-- visitForSubstitution visits nodes solely for class alias substitution in subtrees
-- that don't contain class field or lexical this/super transforms. It substitutes
-- identifiers that reference class declarations with their aliases, while skipping
-- the .Name() of PropertyAccessExpressions since Strada's onSubstituteNode only
-- fires for EmitHint.Expression, which excludes property access names.
function classFieldsTransformer:visitForSubstitution(node)
    if node.kind == Kind.Identifier then
        return self:visitIdentifier(node:AsIdentifier())
    end
    if node.kind == Kind.PropertyAccessExpression and ast.IsIdentifier(node:AsPropertyAccessExpression():Name()) then
        return self:visitPropertyAccessExpressionForSubstitution(node:AsPropertyAccessExpression())
    end
    return self.substitutionVisitor:VisitEachChild(node)
end

-- visit is the main visitor.
function classFieldsTransformer:visit(node)
    local grandparentNode = self:pushNode(node)
    local result = self:visitWorker(node)
    self:popNode(grandparentNode)
    return result
end

-- Lua helper: body of visit (Go's deferred popNode runs after it).
function classFieldsTransformer:visitWorker(node)
    if node:SubtreeFacts() & (SubtreeFacts.SubtreeContainsClassFields | SubtreeFacts.SubtreeContainsLexicalThisOrSuper) == 0 then
        if self.currentClassContainer ~= nil and self.classAliases ~= nil and next(self.classAliases) ~= nil then
            -- Continue visiting for alias substitution even in non-class-field subtrees.
            return self:visitForSubstitution(node)
        end
        return node
    end

    local k = node.kind
    if k == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    elseif k == Kind.ClassDeclaration then
        return self:visitClassDeclaration(node:AsClassDeclaration())
    elseif k == Kind.ClassExpression then
        return self:visitClassExpression(node:AsClassExpression())
    elseif k == Kind.ClassStaticBlockDeclaration or k == Kind.PropertyDeclaration then
        error("Use `classElementVisitor` instead.", 0)
    elseif k == Kind.PropertyAssignment then
        return self:visitPropertyAssignment(node:AsPropertyAssignment())
    elseif k == Kind.VariableStatement then
        return self:visitVariableStatement(node:AsVariableStatement())
    elseif k == Kind.VariableDeclaration then
        return self:visitVariableDeclaration(node:AsVariableDeclaration())
    elseif k == Kind.Parameter then
        return self:visitParameterDeclaration(node:AsParameterDeclaration())
    elseif k == Kind.BindingElement then
        return self:visitBindingElement(node:AsBindingElement())
    elseif k == Kind.ExportAssignment then
        return self:visitExportAssignment(node:AsExportAssignment())
    elseif k == Kind.PrivateIdentifier then
        return self:visitPrivateIdentifier(node)
    elseif k == Kind.PropertyAccessExpression then
        return self:visitPropertyAccessExpression(node:AsPropertyAccessExpression())
    elseif k == Kind.ElementAccessExpression then
        return self:visitElementAccessExpression(node:AsElementAccessExpression())
    elseif k == Kind.PrefixUnaryExpression or k == Kind.PostfixUnaryExpression then
        return self:visitPreOrPostfixUnaryExpression(node, false)
    elseif k == Kind.BinaryExpression then
        return self:visitBinaryExpression(node:AsBinaryExpression(), false)
    elseif k == Kind.ParenthesizedExpression then
        return self:visitParenthesizedExpression(node:AsParenthesizedExpression(), false)
    elseif k == Kind.CallExpression then
        return self:visitCallExpression(node:AsCallExpression())
    elseif k == Kind.ExpressionStatement then
        return self:visitExpressionStatement(node:AsExpressionStatement())
    elseif k == Kind.TaggedTemplateExpression then
        return self:visitTaggedTemplateExpression(node:AsTaggedTemplateExpression())
    elseif k == Kind.ForStatement then
        return self:visitForStatement(node:AsForStatement())
    elseif k == Kind.ForInStatement or k == Kind.ForOfStatement or k == Kind.DoStatement or k == Kind.WhileStatement then
        return self:setInIterationStatementAnd(true, classFieldsTransformer.visitEachChildOfNode, node)
    elseif k == Kind.ThisKeyword then
        return self:visitThisExpression(node)
    elseif k == Kind.FunctionDeclaration or k == Kind.FunctionExpression then
        return self:setInIterationStatementAnd(false, classFieldsTransformer.visitFunctionExpressionOrDeclaration, node)
    elseif k == Kind.Constructor or k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
        return self:setInIterationStatementAnd(false, classFieldsTransformer.setClassElementAndVisitEachChild, node)
    else
        return self:Visitor():VisitEachChild(node)
    end
end

-- visitDiscardedValue visits a node in an expression whose result is discarded.
function classFieldsTransformer:visitDiscardedValue(node)
    local k = node.kind
    if k == Kind.PrefixUnaryExpression or k == Kind.PostfixUnaryExpression then
        return self:visitPreOrPostfixUnaryExpression(node, true)
    elseif k == Kind.BinaryExpression then
        return self:visitBinaryExpression(node:AsBinaryExpression(), true)
    elseif k == Kind.ParenthesizedExpression then
        return self:visitParenthesizedExpression(node:AsParenthesizedExpression(), true)
    else
        return self:visit(node)
    end
end

-- visitHeritageClause visits a node in a HeritageClause.
function classFieldsTransformer:visitHeritageClause(node)
    local k = node.kind
    if k == Kind.HeritageClause then
        return self.heritageClauseVisitor:VisitEachChild(node)
    elseif k == Kind.ExpressionWithTypeArguments then
        return self:visitExpressionWithTypeArgumentsInHeritageClause(node:AsExpressionWithTypeArguments())
    else
        return self:visit(node)
    end
end

-- visitAssignmentTarget visits the assignment target of a destructuring assignment.
function classFieldsTransformer:visitAssignmentTarget(node)
    local k = node.kind
    if k == Kind.ObjectLiteralExpression or k == Kind.ArrayLiteralExpression then
        return self:visitAssignmentPattern(node)
    else
        return self:visit(node)
    end
end

function classFieldsTransformer:visitDestructuringAssignmentTarget(node)
    if ast.IsObjectLiteralExpression(node) or ast.IsArrayLiteralExpression(node) then
        return self:visitAssignmentPattern(node)
    end
    if ast.IsPropertyAccessExpression(node) and ast.IsPrivateIdentifier(node:AsPropertyAccessExpression():Name()) then
        return self:wrapPrivateIdentifierForDestructuringTarget(node)
    end
    if self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
        ast.IsSuperProperty(node) and
        estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
        local data = self.lexicalEnvironment.data
        if data.facts & classFacts.ClassWasDecorated ~= 0 then
            return self:visitInvalidSuperProperty(node)
        end
        if data.classConstructor ~= nil and data.superClassReference ~= nil then
            local name
            if ast.IsElementAccessExpression(node) then
                name = self:Visitor():VisitNode(node:AsElementAccessExpression().argumentExpression)
            elseif ast.IsPropertyAccessExpression(node) and ast.IsIdentifier(node:AsPropertyAccessExpression():Name()) then
                name = self:Factory():NewStringLiteralFromNode(node:AsPropertyAccessExpression():Name())
            end
            if name ~= nil then
                local temp = self:Factory():NewTempVariable()
                local setExpr = self:Factory():NewReflectSetCall(
                    data.superClassReference,
                    name,
                    temp,
                    data.classConstructor
                )
                return self:Factory():NewAssignmentTargetWrapper(temp, setExpr)
            end
        end
    end
    return self:Visitor():VisitEachChild(node)
end

-- visitClassElement visits a member of a class.
function classFieldsTransformer:visitClassElement(node)
    local k = node.kind
    if k == Kind.Constructor then
        return self:setCurrentClassElementAnd(node, classFieldsTransformer.visitConstructorDeclaration, node)
    elseif k == Kind.GetAccessor or k == Kind.SetAccessor or k == Kind.MethodDeclaration then
        return self:setCurrentClassElementAnd(node, classFieldsTransformer.visitMethodOrAccessorDeclaration, node)
    elseif k == Kind.PropertyDeclaration then
        return self:setCurrentClassElementAnd(node, classFieldsTransformer.visitPropertyDeclaration, node)
    elseif k == Kind.ClassStaticBlockDeclaration then
        return self:setCurrentClassElementAnd(node, classFieldsTransformer.visitClassStaticBlockDeclaration, node)
    elseif k == Kind.ComputedPropertyName then
        return self:visitComputedPropertyName(node:AsComputedPropertyName())
    elseif k == Kind.SemicolonClassElement then
        return node
    else
        if ast.IsModifierLike(node) then
            return self:visitModifier(node)
        end
        return self:visit(node)
    end
end

-- visitPropertyName visits a property name of a class member.
function classFieldsTransformer:visitPropertyName(name)
    if ast.IsComputedPropertyName(name) then
        return self:visitComputedPropertyName(name:AsComputedPropertyName())
    end
    return self:Visitor():VisitNode(name)
end

-- visitAccessorFieldResult visits the results of an auto-accessor field transformation in a second pass.
function classFieldsTransformer:visitAccessorFieldResult(node)
    local k = node.kind
    if k == Kind.PropertyDeclaration then
        return self:transformFieldInitializer(node:AsPropertyDeclaration())
    elseif k == Kind.GetAccessor or k == Kind.SetAccessor then
        return self:visitClassElement(node)
    else
        debug.FailBadSyntaxKind(node, "Expected node to either be a PropertyDeclaration, GetAccessorDeclaration, or SetAccessorDeclaration")
        return nil
    end
end

-- visitIdentifier replaces Strada's onSubstituteNode/trySubstituteClassAlias. Instead of
-- substituting at emit time using NodeCheckFlags.ConstructorReference, we resolve the
-- identifier to its declaration and check if that declaration has a registered alias.
function classFieldsTransformer:visitIdentifier(node)
    local declaration = self.resolver:GetReferencedValueDeclaration(self:EmitContext():MostOriginal(node:AsNode()))
    if declaration ~= nil then
        local alias = self.classAliases ~= nil and self.classAliases[declaration] or nil
        if alias ~= nil and self.enclosingClassDeclarations:Has(declaration) then
            local clone = alias:Clone(self:Factory())
            self:EmitContext():SetSourceMapRange(clone, node.loc)
            self:EmitContext():SetCommentRange(clone, node.loc)
            return clone
        end
    end
    return node:AsNode()
end

-- visitPrivateIdentifier handles an undeclared private name. Replace it with an empty
-- identifier to indicate a problem with the code.
-- Note: private identifiers in statement position (e.g., `#;`) are intercepted earlier
-- by visitExpressionStatement, which preserves them so the runtime throws a SyntaxError.
function classFieldsTransformer:visitPrivateIdentifier(node)
    if not self.shouldTransformPrivateElementsOrClassStaticBlocks then
        return node
    end
    if self.parentNode ~= nil and ast.IsStatement(self.parentNode) then
        return node
    end
    local result = self:Factory():NewIdentifier("")
    self:EmitContext():SetOriginal(result, node)
    return result
end

-- transformPrivateIdentifierInInExpression visits `#id in expr`.
function classFieldsTransformer:transformPrivateIdentifierInInExpression(node)
    local info = self:accessPrivateIdentifier(node.left)
    if info ~= nil then
        local receiver = self:Visitor():VisitNode(node.right)
        local result = self:Factory():NewClassPrivateFieldInHelper(info.brandCheckIdentifier, receiver)
        self:EmitContext():SetOriginal(result, node:AsNode())
        return result
    end
    -- Private name has not been declared. Subsequent transformers will handle this error
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitPropertyAssignment(node)
    -- 13.2.5.5 RS: PropertyDefinitionEvaluation
    --   PropertyAssignment : PropertyName `:` AssignmentExpression
    --     ...
    --     5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and _isProtoSetter_ is *false*, then
    --        a. Let _popValue_ be ? NamedEvaluation of |AssignmentExpression| with argument _propKey_.
    --     ...

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), false, ""):AsPropertyAssignment()
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitVariableStatement(node)
    local savedPendingStatements = self.pendingStatements
    self.pendingStatements = nil

    local visitedNode = self:Visitor():VisitEachChild(node:AsNode())

    if core.Len(self.pendingStatements) > 0 then
        local result = { visitedNode }
        for _, s in ipairs(self.pendingStatements) do
            result[#result + 1] = s
        end
        self.pendingStatements = savedPendingStatements
        return self:Factory():NewSyntaxList(result)
    end

    self.pendingStatements = savedPendingStatements
    return visitedNode
end

function classFieldsTransformer:visitVariableDeclaration(node)
    -- 14.3.1.2 RS: Evaluation
    --   LexicalBinding : BindingIdentifier Initializer
    --     ...
    --     3. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...
    --
    -- 14.3.2.1 RS: Evaluation
    --   VariableDeclaration : BindingIdentifier Initializer
    --     ...
    --     3. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), false, ""):AsVariableDeclaration()
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitParameterDeclaration(node)
    -- 8.6.3 RS: IteratorBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     5. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...
    --
    -- 14.3.3.3 RS: KeyedBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     4. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), false, ""):AsParameterDeclaration()
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitBindingElement(node)
    -- 8.6.3 RS: IteratorBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     5. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...
    --
    -- 14.3.3.3 RS: KeyedBindingInitialization
    --   SingleNameBinding : BindingIdentifier Initializer?
    --     ...
    --     4. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
    --     ...

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), false, ""):AsBindingElement()
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitExportAssignment(node)
    -- 16.2.3.7 RS: Evaluation
    --   ExportDeclaration : `export` `default` AssignmentExpression `;`
    --     1. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |AssignmentExpression| with argument `"default"`.
    --     ...

    -- NOTE: Since emit for `export =` translates to `module.exports = ...`, the assigned name of the class
    -- is `""`.

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        local assignedName = ""
        if not node.isExportEquals then
            assignedName = "default"
        end
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), true, assignedName):AsExportAssignment()
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:injectPendingExpressions(expression)
    if core.Len(self.pendingExpressions) > 0 then
        if ast.IsParenthesizedExpression(expression) then
            self.pendingExpressions[#self.pendingExpressions + 1] = expression:Expression()
            expression = self:Factory():UpdateParenthesizedExpression(
                expression:AsParenthesizedExpression(),
                self:Factory():InlineExpressions(self.pendingExpressions)
            )
        else
            local exprs = core.Concatenate(self.pendingExpressions, { expression })
            expression = self:Factory():InlineExpressions(exprs)
        end
        self.pendingExpressions = nil
    end
    return expression
end

function classFieldsTransformer:visitComputedPropertyName(node)
    -- Computed property names are evaluated in the enclosing scope, not the current class.
    -- Replaces Strada's onEmitNode for ComputedPropertyName which switches to
    -- lexicalEnvironment?.previous. We do this explicitly during transformation.
    local savedLexicalEnvironment = self.lexicalEnvironment
    local savedInsideComputedPropertyName = self.insideComputedPropertyName
    self.insideComputedPropertyName = true
    if self.lexicalEnvironment ~= nil and self.lexicalEnvironment.previous ~= nil then
        self.lexicalEnvironment = self.lexicalEnvironment.previous
    end
    local expression = self:Visitor():VisitNode(node.expression)
    self.lexicalEnvironment = savedLexicalEnvironment
    self.insideComputedPropertyName = savedInsideComputedPropertyName
    return self:Factory():UpdateComputedPropertyName(node, self:injectPendingExpressions(expression))
end

function classFieldsTransformer:visitConstructorDeclaration(node)
    if self.currentClassContainer ~= nil then
        return self:transformConstructor(node:AsConstructorDeclaration(), self.currentClassContainer)
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:shouldTransformClassElementToWeakMap(node)
    if self.shouldTransformPrivateElementsOrClassStaticBlocks then
        return true
    end
    return self:shouldAlwaysTransformPrivateStaticElements(node)
end

function classFieldsTransformer:shouldAlwaysTransformPrivateStaticElements(node)
    return ast.HasStaticModifier(node) and self:EmitContext():EmitFlags(node) & EF.EFTransformPrivateStaticElements ~= 0
end

-- nodeHasTransformPrivateStaticElementsFlag checks the emit flag on a class node (not a member).
-- Unlike shouldAlwaysTransformPrivateStaticElements, this does not check HasStaticModifier,
-- since class nodes themselves don't have a static modifier.
function classFieldsTransformer:nodeHasTransformPrivateStaticElementsFlag(node)
    return self:EmitContext():EmitFlags(node) & EF.EFTransformPrivateStaticElements ~= 0
end

function classFieldsTransformer:visitMethodOrAccessorDeclaration(node)
    debug.Assert(not ast.HasDecorators(node))

    if not ast.IsPrivateIdentifierClassElementDeclaration(node) or not self:shouldTransformClassElementToWeakMap(node) then
        return self.classElementVisitor:VisitEachChild(node)
    end

    -- leave invalid code untransformed
    local info = self:accessPrivateIdentifier(node:Name())
    debug.Assert(info ~= nil, "Undeclared private name for property declaration.")
    if not info.isValid then
        return node
    end

    local functionName = self:getHoistedFunctionName(node)
    if functionName ~= nil then
        local modifiers = self:extractNonStaticNonAccessorModifiers(node)
        self:EmitContext():StartVariableEnvironment()
        local saved = self.inIterationStatement
        self.inIterationStatement = false
        local body = self:EmitContext():VisitFunctionBody(node:Body(), self:Visitor())
        local params = self:Visitor():VisitNodes(node:ParameterList())
        self.inIterationStatement = saved

        local funcExpr = self:Factory():NewFunctionExpression(modifiers, node:BodyData().asteriskToken, functionName, nil, params, nil, nil, body)
        local assignment = self:Factory():NewAssignmentExpression(functionName, funcExpr)
        self:addPendingExpressions(assignment)
    end

    -- remove method declaration from class
    return nil
end

function classFieldsTransformer:extractNonStaticNonAccessorModifiers(node)
    return transformers.ExtractModifiers(self:EmitContext(), node:Modifiers(), ~(ModifierFlags.Static | ModifierFlags.Accessor))
end

function classFieldsTransformer:setCurrentClassElementAnd(classElement, visitor, node)
    if classElement ~= self.currentClassElement then
        local saved = self.currentClassElement
        self.currentClassElement = classElement
        local result = visitor(self, node)
        self.currentClassElement = saved
        return result
    end
    return visitor(self, node)
end

-- visitEachChildOfNode just calls Visitor.VisitEachChild, but is necessary to avoid repeated closure allocations when passing as a callback.
function classFieldsTransformer:visitEachChildOfNode(node)
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:setInIterationStatementAnd(inIteration, visitor, node)
    if self.inIterationStatement ~= inIteration then
        local saved = self.inIterationStatement
        self.inIterationStatement = inIteration
        local result = visitor(self, node)
        self.inIterationStatement = saved
        return result
    end
    return visitor(self, node)
end

function classFieldsTransformer:clearClassElementAndVisitEachChild(node)
    return self:setCurrentClassElementAnd(nil, classFieldsTransformer.visitEachChildOfNode, node)
end

-- visitFunctionExpressionOrDeclaration handles lexical environment scoping for function
-- expressions and declarations, mirroring Strada's onEmitNode behavior.
--
-- In Strada, onEmitNode checks whether a FunctionExpression has been registered in
-- lexicalEnvironmentMap (via its original node). If found, the lexical environment is
-- restored; otherwise it is cleared (since regular functions create a new `this` scope).
--
-- Since Corsa performs substitution eagerly (no emit-time hooks), we replicate this by
-- preserving currentClassElement for function expressions whose original node is a class
-- member of the current class. This allows visitThisExpression to correctly substitute
-- `this` -> `_classThis` inside synthesized functions (e.g., ES decorator descriptor
-- methods for static private auto-accessors).
function classFieldsTransformer:visitFunctionExpressionOrDeclaration(node)
    if self.currentClassElement ~= nil then
        local original = self:EmitContext():MostOriginal(node)
        if original ~= node and self.currentClassContainer ~= nil then
            for _, member in ipairs(self.currentClassContainer:Members() or {}) do
                if self:EmitContext():MostOriginal(member) == original and ast.IsStatic(member) then
                    -- The function expression originates from a static class member (e.g., a
                    -- descriptor method synthesized by the ES decorator transformer for a
                    -- static private auto-accessor). Preserve the current class element so
                    -- that visitThisExpression can substitute `this` with `_classThis`.
                    -- Non-static members must NOT preserve the class element because `this`
                    -- inside their descriptor functions should remain dynamic.
                    return self:visitEachChildOfNode(node)
                end
            end
        end
    end
    return self:setCurrentClassElementAnd(nil, classFieldsTransformer.visitEachChildOfNode, node)
end

function classFieldsTransformer:setClassElementAndVisitEachChild(node)
    return self:setCurrentClassElementAnd(node, classFieldsTransformer.visitEachChildOfNode, node)
end

function classFieldsTransformer:getHoistedFunctionName(node)
    debug.Assert(node:Name() ~= nil and ast.IsPrivateIdentifier(node:Name()))
    local info = self:accessPrivateIdentifier(node:Name())
    debug.Assert(info ~= nil, "Undeclared private name for property declaration.")
    if info.kind == PrivateIdentifierKind.Method then
        return info.methodName
    end
    if info.kind == PrivateIdentifierKind.Accessor then
        if ast.IsGetAccessorDeclaration(node) then
            return info.getterName
        end
        if ast.IsSetAccessorDeclaration(node) then
            return info.setterName
        end
    end
    return nil
end

function classFieldsTransformer:tryGetClassThis()
    local classThis = self:tryGetClassThisNoContainer()
    if classThis ~= nil then
        return classThis
    end
    if self.currentClassContainer ~= nil then
        return self.currentClassContainer:Name()
    end
    return nil
end

function classFieldsTransformer:tryGetClassThisNoContainer()
    local lex = self:getClassLexicalEnvironment()
    if lex.classThis ~= nil then
        return lex.classThis
    end
    if lex.classConstructor ~= nil then
        return lex.classConstructor
    end
    return nil
end

-- transformAutoAccessor transforms an auto-accessor property:
--
--	accessor x = 1;
--
-- into:
--
--	#x = 1;
--	get x() { return this.#x; }
--	set x(value) { this.#x = value; }
function classFieldsTransformer:transformAutoAccessor(node)
    local commentRange = self:EmitContext():CommentRange(node:AsNode())
    local sourceMapRange = self:EmitContext():SourceMapRange(node:AsNode())

    -- Since we're creating two declarations where there was previously one, cache
    -- the expression for any computed property names.
    local name = node:Name()
    local getterName = name
    local setterName = name
    if ast.IsComputedPropertyName(name) and not transformers.IsSimpleInlineableExpression(name:Expression()) then
        local cacheAssignment = estransforms.findComputedPropertyNameCacheAssignment(self:EmitContext(), name)
        if cacheAssignment ~= nil then
            getterName = self:Factory():UpdateComputedPropertyName(name:AsComputedPropertyName(), self:Visitor():VisitNode(name:Expression()))
            setterName = self:Factory():UpdateComputedPropertyName(name:AsComputedPropertyName(), cacheAssignment.left)
        else
            local temp = self:Factory():NewTempVariable()
            self:EmitContext():SetSourceMapRange(temp, name:Expression().loc)
            self:EmitContext():AddVariableDeclaration(temp)
            local expression = self:Visitor():VisitNode(name:Expression())
            local assignment = self:Factory():NewAssignmentExpression(temp, expression)
            self:EmitContext():SetSourceMapRange(assignment, name:Expression().loc)
            getterName = self:Factory():UpdateComputedPropertyName(name:AsComputedPropertyName(), assignment)
            setterName = self:Factory():UpdateComputedPropertyName(name:AsComputedPropertyName(), temp)
        end
    end

    local modifiers = self.modifierVisitor:VisitModifiers(node:Modifiers())
    local backingField = estransforms.createAccessorPropertyBackingField(self:Factory(), node, modifiers, node.initializer)
    self:EmitContext():SetOriginal(backingField, node:AsNode())
    self:EmitContext():AddEmitFlags(backingField, EF.EFNoComments)
    self:EmitContext():SetSourceMapRange(backingField, sourceMapRange)

    local receiver
    if ast.IsStatic(node:AsNode()) then
        receiver = self:tryGetClassThis()
        if receiver == nil then
            receiver = self:Factory():NewThisExpression()
        end
    else
        receiver = self:Factory():NewThisExpression()
    end

    local getter = self:createAccessorPropertyGetRedirector(node, modifiers, getterName, receiver)
    self:EmitContext():SetOriginal(getter, node:AsNode())
    self:EmitContext():SetCommentRange(getter, commentRange)
    self:EmitContext():SetSourceMapRange(getter, sourceMapRange)

    -- create a fresh copy of the modifiers so that we don't duplicate comments
    local setterModifiers
    if modifiers ~= nil then
        local f = self:Factory()
        setterModifiers = f:NewModifierList(ast.CreateModifiersFromModifierFlags(modifiers.modifierFlags, function(kind) return f:NewModifier(kind) end))
    end
    local setter = self:createAccessorPropertySetRedirector(node, setterModifiers, setterName, receiver)
    self:EmitContext():SetOriginal(setter, node:AsNode())
    self:EmitContext():AddEmitFlags(setter, EF.EFNoComments)
    self:EmitContext():SetSourceMapRange(setter, sourceMapRange)

    -- Visit the results in a second pass
    local visited = self.accessorFieldResultVisitor:VisitSlice({ backingField, getter, setter })
    return self:Factory():NewSyntaxList(visited)
end

function classFieldsTransformer:transformPrivateFieldInitializer(node)
    if self:shouldTransformClassElementToWeakMap(node:AsNode()) then
        -- If we are transforming private elements into WeakMap/WeakSet, we should elide the node.
        local info = self:accessPrivateIdentifier(node:Name())
        debug.Assert(info ~= nil, "Undeclared private name for property declaration.")

        -- Leave invalid code untransformed
        if not info.isValid then
            return node:AsNode()
        end

        -- If we encounter a valid private static field and we're not transforming
        -- class static blocks, convert to a static block initializer.
        if info.isStatic and not self.shouldTransformPrivateElementsOrClassStaticBlocks then
            -- TODO: fix
            local statement = self:transformPropertyOrClassStaticBlock(node:AsNode(), self:Factory():NewThisExpression())
            if statement ~= nil then
                return self:Factory():NewClassStaticBlockDeclaration(
                    nil, -- modifiers
                    self:Factory():NewBlock(self:Factory():NewNodeList({ statement }), true)
                )
            end
        end

        return nil
    end

    if self.shouldTransformInitializersUsingSet and not ast.HasStaticModifier(node:AsNode()) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil and
        self.lexicalEnvironment.data.facts & classFacts.WillHoistInitializersToConstructor ~= 0 then
        return self:Factory():UpdatePropertyDeclaration(
            node,
            self:Visitor():VisitModifiers(node:Modifiers()),
            node:Name(),
            nil, -- postfixToken
            nil, -- typeNode
            nil -- initializer
        )
    end

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), false, ""):AsPropertyDeclaration()
    end

    return self:Factory():UpdatePropertyDeclaration(
        node,
        self.modifierVisitor:VisitModifiers(node:Modifiers()),
        self:visitPropertyName(node:Name()),
        nil, -- postfixToken
        nil, -- typeNode
        self:Visitor():VisitNode(node.initializer)
    )
end

function classFieldsTransformer:transformPublicFieldInitializer(node)
    if self.shouldTransformInitializers and not ast.IsAutoAccessorPropertyDeclaration(node:AsNode()) then
        -- Elide the property declaration; the initializer will be moved to the constructor.
        -- For computed property names, we still need to emit the expression.
        local expr = self:getPropertyNameExpressionIfNeeded(node:Name(), node.initializer ~= nil or self.compilerOptions:GetUseDefineForClassFields())
        if expr ~= nil then
            for _, e in ipairs(estransforms.flattenCommaList(expr)) do
                self:addPendingExpressions(e)
            end
        end

        -- When target >= ES2022 (i.e., !shouldTransformPrivateElementsOrClassStaticBlocks) and we
        -- still need to transform initializers (useDefineForClassFields: false), static property
        -- initializers must be converted into `static { this.x = ...; }` blocks so that `this`
        -- refers to the class constructor inside the static block.
        if ast.IsStatic(node:AsNode()) and not self.shouldTransformPrivateElementsOrClassStaticBlocks then
            local initializerStatement = self:transformPropertyOrClassStaticBlock(node:AsNode(), self:Factory():NewThisExpression())
            if initializerStatement ~= nil then
                local staticBlock = self:Factory():NewClassStaticBlockDeclaration(
                    nil, -- modifiers
                    self:Factory():NewBlock(self:Factory():NewNodeList({ initializerStatement }), false)
                )

                self:EmitContext():SetOriginal(staticBlock, node:AsNode())
                self:EmitContext():SetCommentRange(staticBlock, node.loc)

                self:EmitContext():AddEmitFlags(initializerStatement, EF.EFNoComments)
                return staticBlock
            end
        end

        return nil
    end

    return self:Factory():UpdatePropertyDeclaration(
        node,
        self.modifierVisitor:VisitModifiers(node:Modifiers()),
        self:visitPropertyName(node:Name()),
        nil, -- postfixToken
        nil, -- typeNode
        self:Visitor():VisitNode(node.initializer)
    )
end

function classFieldsTransformer:transformFieldInitializer(node)
    debug.Assert(not ast.HasDecorators(node:AsNode()), "Decorators should already have been transformed and elided.")
    if ast.IsPrivateIdentifierClassElementDeclaration(node:AsNode()) then
        return self:transformPrivateFieldInitializer(node)
    end
    return self:transformPublicFieldInitializer(node)
end

function classFieldsTransformer:shouldTransformAutoAccessorsInCurrentClass()
    if self.shouldTransformAutoAccessors then
        return true
    end
    -- When targeting ESNext with useDefineForClassFields: false, auto-accessors are only
    -- transformed if the current class will hoist initializers to the constructor.
    return self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil and
        self.lexicalEnvironment.data.facts & classFacts.WillHoistInitializersToConstructor ~= 0
end

function classFieldsTransformer:visitPropertyDeclaration(node)
    -- If this is an auto-accessor, we defer to `transformAutoAccessor`. That function
    -- will in turn call `transformFieldInitializer` as needed.
    local propDecl = node:AsPropertyDeclaration()
    if ast.IsAutoAccessorPropertyDeclaration(node) and (self:shouldTransformAutoAccessorsInCurrentClass() or
        ast.HasStaticModifier(node) and self:shouldAlwaysTransformPrivateStaticElements(node)) then
        return self:transformAutoAccessor(propDecl)
    end
    return self:transformFieldInitializer(propDecl)
end

function classFieldsTransformer:createPrivateIdentifierAccess(info, receiver)
    receiver = self:Visitor():VisitNode(receiver)
    return self:createPrivateIdentifierAccessHelper(info, receiver)
end

function classFieldsTransformer:createPrivateIdentifierAccessHelper(info, receiver)
    self:EmitContext():SetCommentRange(receiver, core.NewTextRange(-1, receiver:End()))

    local k = info.kind
    if k == PrivateIdentifierKind.Accessor then
        return self:Factory():NewClassPrivateFieldGetHelper(
            receiver,
            info.brandCheckIdentifier,
            info.kind,
            info.getterName
        )
    elseif k == PrivateIdentifierKind.Method then
        return self:Factory():NewClassPrivateFieldGetHelper(
            receiver,
            info.brandCheckIdentifier,
            info.kind,
            info.methodName
        )
    elseif k == PrivateIdentifierKind.Field then
        local f
        if info.isStatic then
            f = info.variableName
        end
        return self:Factory():NewClassPrivateFieldGetHelper(
            receiver,
            info.brandCheckIdentifier,
            info.kind,
            f
        )
    elseif k == PrivateIdentifierKind.Untransformed then
        debug.Fail("Access helpers should not be created for untransformed private elements")
        return nil
    end
    debug.AssertNever(info, "Unknown private element type")
    return nil
end

function classFieldsTransformer:visitPropertyAccessExpression(node)
    if ast.IsPrivateIdentifier(node:Name()) then
        local info = self:accessPrivateIdentifier(node:Name())
        if info ~= nil then
            local result = self:createPrivateIdentifierAccess(info, node.expression)
            self:EmitContext():SetOriginal(result, node:AsNode())
            result.loc = node.loc
            return result
        end
    end
    if self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
        ast.IsSuperProperty(node:AsNode()) and ast.IsIdentifier(node:Name()) and
        estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
        local data = self.lexicalEnvironment.data
        if data.facts & classFacts.ClassWasDecorated ~= 0 then
            return self:visitInvalidSuperProperty(node:AsNode())
        end
        if data.classConstructor ~= nil and data.superClassReference ~= nil then
            -- converts `super.x` into `Reflect.get(_baseTemp, "x", _classTemp)`
            local superProperty = self:Factory():NewReflectGetCall(
                data.superClassReference,
                self:Factory():NewStringLiteralFromNode(node:Name()),
                data.classConstructor
            )
            self:EmitContext():SetOriginal(superProperty, node.expression)
            superProperty.loc = node.expression.loc
            return superProperty
        end
    end
    -- Visit only the expression, not the name (when it's a regular identifier), to prevent
    -- substitution of property names. Strada's onSubstituteNode only fires for
    -- EmitHint.Expression, which excludes the .name of PropertyAccessExpression.
    -- Private identifier names are still visited through VisitEachChild so they can be
    -- transformed by visitPrivateIdentifier.
    if ast.IsIdentifier(node:Name()) then
        return self:visitPropertyAccessExpressionForSubstitution(node)
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

-- visitPropertyAccessExpressionForSubstitution visits only the expression of a PropertyAccessExpression,
-- leaving the name unchanged. This prevents the name from being treated as a standalone identifier
-- reference and incorrectly substituted with a class alias.
function classFieldsTransformer:visitPropertyAccessExpressionForSubstitution(node)
    local expression = self:Visitor():VisitNode(node.expression)
    if expression ~= node.expression then
        return self:Factory():UpdatePropertyAccessExpression(node, expression, node.questionDotToken, node:Name(), node.flags)
    end
    return node:AsNode()
end

function classFieldsTransformer:visitElementAccessExpression(node)
    if self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
        ast.IsSuperProperty(node:AsNode()) and
        estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
        local data = self.lexicalEnvironment.data
        if data.facts & classFacts.ClassWasDecorated ~= 0 then
            return self:visitInvalidSuperProperty(node:AsNode())
        end
        if data.classConstructor ~= nil and data.superClassReference ~= nil then
            -- converts `super[x]` into `Reflect.get(_baseTemp, x, _classTemp)`
            local superProperty = self:Factory():NewReflectGetCall(
                data.superClassReference,
                self:Visitor():VisitNode(node.argumentExpression),
                data.classConstructor
            )
            self:EmitContext():SetOriginal(superProperty, node.expression)
            superProperty.loc = node.expression.loc
            return superProperty
        end
    end
    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitPreOrPostfixUnaryExpression(node, discarded)
    local operator
    local operand
    if ast.IsPrefixUnaryExpression(node) then
        operator = node:AsPrefixUnaryExpression().operator
        operand = node:AsPrefixUnaryExpression().operand
    else
        operator = node:AsPostfixUnaryExpression().operator
        operand = node:AsPostfixUnaryExpression().operand
    end

    if operator == Kind.PlusPlusToken or operator == Kind.MinusMinusToken then
        local operandSkipped = ast.SkipParentheses(operand)

        -- Private identifier property access
        if ast.IsPropertyAccessExpression(operandSkipped) and ast.IsPrivateIdentifier(operandSkipped:Name()) then
            local info = self:accessPrivateIdentifier(operandSkipped:Name())
            if info ~= nil then
                local receiver = self:Visitor():VisitNode(operandSkipped:Expression())
                local readExpression, initializeExpression = self:createCopiableReceiverExpr(receiver)

                local expression = self:createPrivateIdentifierAccessHelper(info, readExpression)
                local temp
                if not ast.IsPrefixUnaryExpression(node) and not discarded then
                    temp = self:Factory():NewTempVariable()
                    self:EmitContext():AddVariableDeclaration(temp)
                end
                expression = estransforms.expandPreOrPostfixIncrementOrDecrementExpression(self:Factory(), self:EmitContext(), node, expression, temp)
                local assignReceiver = readExpression
                if initializeExpression ~= nil then
                    assignReceiver = initializeExpression
                end
                expression = self:createPrivateIdentifierAssignment(info, assignReceiver, expression, Kind.EqualsToken)
                self:EmitContext():SetOriginal(expression, node)
                expression.loc = node.loc
                if temp ~= nil then
                    expression = self:Factory():NewCommaExpression(expression, temp)
                    expression.loc = node.loc
                end
                return expression
            end
        elseif self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
            ast.IsSuperProperty(operandSkipped) and
            estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
            self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
            -- converts `++super.a` into `(Reflect.set(_baseTemp, "a", (_a = Reflect.get(_baseTemp, "a", _classTemp), _b = ++_a), _classTemp), _b)`
            -- converts `++super[f()]` into `(Reflect.set(_baseTemp, _a = f(), (_b = Reflect.get(_baseTemp, _a, _classTemp), _c = ++_b), _classTemp), _c)`
            -- converts `--super.a` into `(Reflect.set(_baseTemp, "a", (_a = Reflect.get(_baseTemp, "a", _classTemp), _b = --_a), _classTemp), _b)`
            -- converts `--super[f()]` into `(Reflect.set(_baseTemp, _a = f(), (_b = Reflect.get(_baseTemp, _a, _classTemp), _c = --_b), _classTemp), _c)`
            -- converts `super.a++` into `(Reflect.set(_baseTemp, "a", (_a = Reflect.get(_baseTemp, "a", _classTemp), _b = _a++), _classTemp), _b)`
            -- converts `super[f()]++` into `(Reflect.set(_baseTemp, _a = f(), (_b = Reflect.get(_baseTemp, _a, _classTemp), _c = _b++), _classTemp), _c)`
            -- converts `super.a--` into `(Reflect.set(_baseTemp, "a", (_a = Reflect.get(_baseTemp, "a", _classTemp), _b = _a--), _classTemp), _b)`
            -- converts `super[f()]--` into `(Reflect.set(_baseTemp, _a = f(), (_b = Reflect.get(_baseTemp, _a, _classTemp), _c = _b--), _classTemp), _c)`
            local data = self.lexicalEnvironment.data
            if data.facts & classFacts.ClassWasDecorated ~= 0 then
                local visitedExpr = self:visitInvalidSuperProperty(operandSkipped)
                if ast.IsPrefixUnaryExpression(node) then
                    return self:Factory():UpdatePrefixUnaryExpression(node:AsPrefixUnaryExpression(), node:AsPrefixUnaryExpression().operator, visitedExpr)
                end
                return self:Factory():UpdatePostfixUnaryExpression(node:AsPostfixUnaryExpression(), visitedExpr, node:AsPostfixUnaryExpression().operator)
            end
            if data.classConstructor ~= nil and data.superClassReference ~= nil then
                local setterName
                local getterName
                if ast.IsPropertyAccessExpression(operandSkipped) then
                    if ast.IsIdentifier(operandSkipped:Name()) then
                        getterName = self:Factory():NewStringLiteralFromNode(operandSkipped:Name())
                        setterName = getterName
                    end
                elseif ast.IsElementAccessExpression(operandSkipped) then
                    if transformers.IsSimpleInlineableExpression(operandSkipped:AsElementAccessExpression().argumentExpression) then
                        getterName = operandSkipped:AsElementAccessExpression().argumentExpression
                        setterName = getterName
                    else
                        getterName = self:Factory():NewTempVariable()
                        self:EmitContext():AddVariableDeclaration(getterName)
                        setterName = self:Factory():NewAssignmentExpression(getterName, self:Visitor():VisitNode(operandSkipped:AsElementAccessExpression().argumentExpression))
                    end
                end
                if setterName ~= nil and getterName ~= nil then
                    local expression = self:Factory():NewReflectGetCall(data.superClassReference, getterName, data.classConstructor)
                    expression.loc = operandSkipped.loc

                    local temp
                    if not discarded then
                        temp = self:Factory():NewTempVariable()
                        self:EmitContext():AddVariableDeclaration(temp)
                    end
                    expression = estransforms.expandPreOrPostfixIncrementOrDecrementExpression(self:Factory(), self:EmitContext(), node, expression, temp)
                    expression = self:Factory():NewReflectSetCall(data.superClassReference, setterName, expression, data.classConstructor)
                    self:EmitContext():SetOriginal(expression, node)
                    expression.loc = node.loc
                    if temp ~= nil then
                        expression = self:Factory():NewCommaExpression(expression, temp)
                        expression.loc = node.loc
                    end
                    return expression
                end
            end
        end
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitForStatement(node)
    local initializer = self.discardedValueVisitor:VisitNode(node.initializer)
    local condition = self:Visitor():VisitNode(node.condition)
    local incrementor = self.discardedValueVisitor:VisitNode(node.incrementor)
    local saved = self.inIterationStatement
    self.inIterationStatement = true
    local body = self:EmitContext():VisitIterationBody(node.statement, self:Visitor())
    self.inIterationStatement = saved
    return self:Factory():UpdateForStatement(node, initializer, condition, incrementor, body)
end

function classFieldsTransformer:visitExpressionStatement(node)
    -- Preserve private identifiers that appear directly as the expression of an
    -- ExpressionStatement (e.g., `#;`). This is error-recovery output from the parser
    -- for invalid syntax. Keeping it ensures the runtime throws a SyntaxError rather
    -- than silently succeeding with an empty statement.
    if ast.IsPrivateIdentifier(node.expression) and self.shouldTransformPrivateElementsOrClassStaticBlocks then
        return node:AsNode()
    end
    return self:Factory():UpdateExpressionStatement(
        node,
        self.discardedValueVisitor:VisitNode(node.expression)
    )
end

-- Returns readExpression, initializeExpression.
function classFieldsTransformer:createCopiableReceiverExpr(receiver)
    local clone = receiver
    if not ast.NodeIsSynthesized(receiver) then
        clone = receiver:Clone(self:Factory())
    end
    if transformers.IsSimpleInlineableExpression(receiver) then
        return clone, nil
    end
    local readExpression = self:Factory():NewTempVariable()
    self:EmitContext():AddVariableDeclaration(readExpression)
    local initializeExpression = self:Factory():NewAssignmentExpression(readExpression, clone)
    return readExpression, initializeExpression
end

function classFieldsTransformer:visitCallExpression(node)
    if ast.IsPropertyAccessExpression(node.expression) and ast.IsPrivateIdentifier(node.expression:AsPropertyAccessExpression():Name()) and
        self:accessPrivateIdentifier(node.expression:AsPropertyAccessExpression():Name()) ~= nil then
        -- obj.#x()

        -- Transform call expressions of private names to properly bind the `this` parameter.
        local thisArg, target = self:createCallBinding(node.expression)
        local visitedTarget = self:Visitor():VisitNode(target)
        local visitedThisArg = self:Visitor():VisitNode(thisArg)
        local visitedArgs = self:Visitor():VisitNodes(node.arguments)
        local allArgs = { visitedThisArg }
        for _, a in ipairs(visitedArgs.nodes or {}) do
            allArgs[#allArgs + 1] = a
        end
        if node.flags & NodeFlags.OptionalChain ~= 0 then
            return self:Factory():UpdateCallExpression(
                node,
                self:Factory():NewPropertyAccessExpression(visitedTarget, node.questionDotToken, self:Factory():NewIdentifier("call"), NodeFlags.OptionalChain),
                nil, -- questionDotToken
                nil, -- typeArguments
                self:Factory():NewNodeList(allArgs),
                node.flags
            )
        end
        return self:Factory():UpdateCallExpression(
            node,
            self:Factory():NewPropertyAccessExpression(visitedTarget, nil, self:Factory():NewIdentifier("call"), NodeFlags.None),
            nil, -- questionDotToken
            nil, -- typeArguments
            self:Factory():NewNodeList(allArgs),
            node.flags
        )
    end

    if self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
        ast.IsSuperProperty(node.expression) and
        estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil and
        self.lexicalEnvironment.data.classConstructor ~= nil then
        -- super.x()
        -- super[x]()

        -- converts `super.f(...)` into `Reflect.get(_baseTemp, "f", _classTemp).call(_classTemp, ...)`
        local invocation = self:Factory():NewFunctionCallCall(
            self:Visitor():VisitNode(node.expression),
            self.lexicalEnvironment.data.classConstructor,
            self:Visitor():VisitNodes(node.arguments).nodes
        )
        self:EmitContext():SetOriginal(invocation, node:AsNode())
        invocation.loc = node.loc
        return invocation
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitTaggedTemplateExpression(node)
    if ast.IsPropertyAccessExpression(node.tag) and ast.IsPrivateIdentifier(node.tag:AsPropertyAccessExpression():Name()) and
        self:accessPrivateIdentifier(node.tag:AsPropertyAccessExpression():Name()) ~= nil then
        -- Bind the `this` correctly for tagged template literals when the tag is a private identifier property access.
        local thisArg, target = self:createCallBinding(node.tag)
        local bindExpr = self:Factory():NewCallExpression(
            self:Factory():NewPropertyAccessExpression(self:Visitor():VisitNode(target), nil, self:Factory():NewIdentifier("bind"), NodeFlags.None),
            nil, -- questionDotToken
            nil, -- typeArguments
            self:Factory():NewNodeList({ self:Visitor():VisitNode(thisArg) }),
            NodeFlags.None
        )
        return self:Factory():UpdateTaggedTemplateExpression(
            node,
            bindExpr,
            nil, -- questionDotToken
            nil, -- typeArguments
            self:Visitor():VisitNode(node.template),
            node.flags
        )
    end

    if self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
        ast.IsSuperProperty(node.tag) and
        estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil and
        self.lexicalEnvironment.data.classConstructor ~= nil then
        -- converts `` super.f`x` `` into `` Reflect.get(_baseTemp, "f", _classTemp).bind(_classTemp)`x` ``
        local invocation = self:Factory():NewFunctionBindCall(
            self:Visitor():VisitNode(node.tag),
            self.lexicalEnvironment.data.classConstructor,
            nil
        )
        self:EmitContext():SetOriginal(invocation, node:AsNode())
        invocation.loc = node.loc
        return self:Factory():UpdateTaggedTemplateExpression(
            node,
            invocation,
            nil, -- questionDotToken
            nil, -- typeArguments
            self:Visitor():VisitNode(node.template),
            node.flags
        )
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:transformClassStaticBlockDeclaration(node)
    if self.shouldTransformPrivateElementsOrClassStaticBlocks then
        if estransforms.isClassThisAssignmentBlock(self:EmitContext(), node) then
            local result = self:Visitor():VisitNode(node:AsClassStaticBlockDeclaration().body:AsBlock().statements.nodes[1]:Expression())
            -- If the generated `_classThis` assignment is a noop (i.e., `_classThis = _classThis`), we can
            -- eliminate the expression
            if ast.IsAssignmentExpression(result, true) then
                local binary = result:AsBinaryExpression()
                if binary.left == binary.right then
                    return nil
                end
            end
            return result
        end

        if estransforms.isClassNamedEvaluationHelperBlock(self:EmitContext(), node) then
            return self:Visitor():VisitNode(node:AsClassStaticBlockDeclaration().body:AsBlock().statements.nodes[1]:Expression())
        end

        self:EmitContext():StartVariableEnvironment()
        local statements = self:setCurrentClassElementAndVisitStatements(node, node:AsClassStaticBlockDeclaration().body:AsBlock().statements.nodes)
        statements = self:EmitContext():EndAndMergeVariableEnvironment(statements)

        local iife = self:Factory():NewImmediatelyInvokedArrowFunction(statements)
        local arrowFunction = ast.SkipParentheses(iife:Expression())
        self:EmitContext():SetOriginal(arrowFunction, node)
        self:EmitContext():AddEmitFlags(arrowFunction, EF.EFNoLexicalArguments)
        -- Preserve the statement list source range so the printer can emit detached comments
        -- (e.g., `// do` inside an otherwise empty static block)
        arrowFunction:AsArrowFunction().body:AsBlock().statements.loc = node:AsClassStaticBlockDeclaration().body:AsBlock().statements.loc
        self:EmitContext():SetOriginal(iife, node)
        self:EmitContext():AssignSourceMapRange(iife, node)
        self:EmitContext():AddEmitFlags(arrowFunction, EF.EFNoLexicalThis)
        return iife
    end
    return nil
end

function classFieldsTransformer:setCurrentClassElementAndVisitStatements(classElement, statements)
    local savedCurrentClassElement = self.currentClassElement
    self.currentClassElement = classElement
    local result = self:Visitor():VisitSlice(statements)
    self.currentClassElement = savedCurrentClassElement
    return result
end

function classFieldsTransformer:isAnonymousClassNeedingAssignedNameWorker(node)
    if ast.IsClassExpression(node) and node:Name() == nil then
        local staticPropertiesOrClassStaticBlocks = self:getStaticPropertiesAndClassStaticBlock(node)
        if core.Some(staticPropertiesOrClassStaticBlocks, function(n)
            return estransforms.isClassNamedEvaluationHelperBlock(self:EmitContext(), n)
        end) then
            return false
        end
        local hasTransformableStatics = (self.shouldTransformPrivateElementsOrClassStaticBlocks or
            self:nodeHasTransformPrivateStaticElementsFlag(node)) and
            core.Some(staticPropertiesOrClassStaticBlocks, function(n)
                return ast.IsClassStaticBlockDeclaration(n) or
                    ast.IsPrivateIdentifierClassElementDeclaration(n) or
                    self.shouldTransformInitializers and ast.IsInitializedProperty(n)
            end)
        return hasTransformableStatics
    end
    return false
end

function classFieldsTransformer:visitBinaryExpression(node, discarded)
    if ast.IsDestructuringAssignment(node:AsNode()) then
        -- ({ x: obj.#x } = ...)
        -- ({ x: super.x } = ...)
        -- ({ x: super[x] } = ...)
        local savedPendingExpressions = self.pendingExpressions
        self.pendingExpressions = nil
        local updated = self:Factory():UpdateBinaryExpression(
            node,
            nil,
            self.assignmentTargetVisitor:VisitNode(node.left),
            nil,
            node.operatorToken,
            self:Visitor():VisitNode(node.right)
        )
        local result
        if core.Len(self.pendingExpressions) > 0 then
            local exprs = core.Concatenate(self.pendingExpressions, { updated })
            result = self:Factory():InlineExpressions(exprs)
        else
            result = updated
        end
        self.pendingExpressions = savedPendingExpressions
        return result
    end

    if ast.IsAssignmentExpression(node:AsNode(), false) then
        -- 13.15.2 RS: Evaluation
        --   AssignmentExpression : LeftHandSideExpression `=` AssignmentExpression
        --     1. If |LeftHandSideExpression| is neither an |ObjectLiteral| nor an |ArrayLiteral|, then
        --        a. Let _lref_ be ? Evaluation of |LeftHandSideExpression|.
        --        b. If IsAnonymousFunctionDefinition(|AssignmentExpression|) and IsIdentifierRef of |LeftHandSideExpression| are both *true*, then
        --           i. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
        --     ...
        --
        --   AssignmentExpression : LeftHandSideExpression `&&=` AssignmentExpression
        --     ...
        --     5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and IsIdentifierRef of |LeftHandSideExpression| is *true*, then
        --        a. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
        --     ...
        --
        --   AssignmentExpression : LeftHandSideExpression `||=` AssignmentExpression
        --     ...
        --     5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and IsIdentifierRef of |LeftHandSideExpression| is *true*, then
        --        a. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
        --     ...
        --
        --   AssignmentExpression : LeftHandSideExpression `??=` AssignmentExpression
        --     ...
        --     4. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and IsIdentifierRef of |LeftHandSideExpression| is *true*, then
        --        a. Let _rval_ be ? NamedEvaluation of |AssignmentExpression| with argument _lref_.[[ReferencedName]].
        --     ...

        if estransforms.isNamedEvaluationAnd(self:EmitContext(), node:AsNode(), self.isAnonymousClassNeedingAssignedName) then
            node = estransforms.transformNamedEvaluation(self:EmitContext(), node:AsNode(), false, ""):AsBinaryExpression()
            debug.Assert(node:AsNode() ~= nil and ast.IsAssignmentExpression(node:AsNode(), false))
        end

        local left = ast.SkipOuterExpressions(node.left, OEK.OEKPartiallyEmittedExpressions | OEK.OEKParentheses)
        if ast.IsPropertyAccessExpression(left) and ast.IsPrivateIdentifier(left:Name()) then
            -- obj.#x = ...
            local info = self:accessPrivateIdentifier(left:Name())
            if info ~= nil then
                local result = self:createPrivateIdentifierAssignment(info, left:Expression(), node.right, node.operatorToken.kind)
                self:EmitContext():SetOriginal(result, node:AsNode())
                result.loc = node.loc
                return result
            end
        elseif self.shouldTransformSuperInStaticInitializers and self.currentClassElement ~= nil and
            ast.IsSuperProperty(node.left) and
            estransforms.isStaticPropertyDeclarationOrClassStaticBlock(self.currentClassElement) and
            self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
            -- super.x = ...
            -- super[x] = ...
            -- super.x += ...
            -- super.x -= ...
            local data = self.lexicalEnvironment.data
            if data.facts & classFacts.ClassWasDecorated ~= 0 then
                return self:Factory():UpdateBinaryExpression(
                    node,
                    nil,
                    self:visitInvalidSuperProperty(node.left),
                    nil,
                    node.operatorToken,
                    self:Visitor():VisitNode(node.right)
                )
            end
            if data.classConstructor ~= nil and data.superClassReference ~= nil then
                local setterName
                if ast.IsElementAccessExpression(node.left) then
                    setterName = self:Visitor():VisitNode(node.left:AsElementAccessExpression().argumentExpression)
                elseif ast.IsPropertyAccessExpression(node.left) and ast.IsIdentifier(node.left:AsPropertyAccessExpression():Name()) then
                    setterName = self:Factory():NewStringLiteralFromNode(node.left:AsPropertyAccessExpression():Name())
                end
                if setterName ~= nil then
                    -- converts `super.x = 1` into `(Reflect.set(_baseTemp, "x", _a = 1, _classTemp), _a)`
                    -- converts `super[f()] = 1` into `(Reflect.set(_baseTemp, f(), _a = 1, _classTemp), _a)`
                    -- converts `super.x += 1` into `(Reflect.set(_baseTemp, "x", _a = Reflect.get(_baseTemp, "x", _classtemp) + 1, _classTemp), _a)`
                    -- converts `super[f()] += 1` into `(Reflect.set(_baseTemp, _a = f(), _b = Reflect.get(_baseTemp, _a, _classtemp) + 1, _classTemp), _b)`

                    local expression = self:Visitor():VisitNode(node.right)
                    if ast.IsCompoundAssignment(node.operatorToken.kind) then
                        local getterName = setterName
                        if not transformers.IsSimpleInlineableExpression(setterName) then
                            getterName = self:Factory():NewTempVariable()
                            self:EmitContext():AddVariableDeclaration(getterName)
                            setterName = self:Factory():NewAssignmentExpression(getterName, setterName)
                        end
                        local superPropertyGet = self:Factory():NewReflectGetCall(
                            data.superClassReference,
                            getterName,
                            data.classConstructor
                        )
                        self:EmitContext():SetOriginal(superPropertyGet, node.left)
                        superPropertyGet.loc = node.left.loc
                        expression = self:Factory():NewBinaryExpression(
                            nil,
                            superPropertyGet,
                            nil,
                            self:Factory():NewToken(transformers.GetNonAssignmentOperatorForCompoundAssignment(node.operatorToken.kind)),
                            expression
                        )
                        expression.loc = node.loc
                    end

                    local temp
                    if not discarded then
                        temp = self:Factory():NewTempVariable()
                        self:EmitContext():AddVariableDeclaration(temp)
                    end
                    if temp ~= nil then
                        expression = self:Factory():NewAssignmentExpression(temp, expression)
                        expression.loc = node.loc
                    end

                    expression = self:Factory():NewReflectSetCall(
                        data.superClassReference,
                        setterName,
                        expression,
                        data.classConstructor
                    )
                    self:EmitContext():SetOriginal(expression, node:AsNode())
                    expression.loc = node.loc

                    if temp ~= nil then
                        expression = self:Factory():NewCommaExpression(expression, temp)
                        expression.loc = node.loc
                    end
                    return expression
                end
            end
        end
    end

    if node.operatorToken.kind == Kind.InKeyword and ast.IsPrivateIdentifier(node.left) then
        -- #x in obj
        return self:transformPrivateIdentifierInInExpression(node)
    end

    return self:Visitor():VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitParenthesizedExpression(node, discarded)
    -- 8.4.5 RS: NamedEvaluation
    --   ParenthesizedExpression : `(` Expression `)`
    --     ...
    --     2. Return ? NamedEvaluation of |Expression| with argument _name_.
    if discarded then
        local expression = self.discardedValueVisitor:VisitNode(node.expression)
        return self:Factory():UpdateParenthesizedExpression(node, expression)
    end
    local expression = self:Visitor():VisitNode(node.expression)
    return self:Factory():UpdateParenthesizedExpression(node, expression)
end

function classFieldsTransformer:createPrivateIdentifierAssignment(info, receiver, right, operator)
    receiver = self:Visitor():VisitNode(receiver)
    right = self:Visitor():VisitNode(right)

    if ast.IsCompoundAssignment(operator) then
        local readExpression, initializeExpression = self:createCopiableReceiverExpr(receiver)
        if initializeExpression ~= nil then
            receiver = initializeExpression
        else
            receiver = readExpression
        end
        right = self:Factory():NewBinaryExpression(
            nil,
            self:createPrivateIdentifierAccessHelper(info, readExpression),
            nil,
            self:Factory():NewToken(transformers.GetNonAssignmentOperatorForCompoundAssignment(operator)),
            right
        )
    end

    self:EmitContext():SetCommentRange(receiver, core.NewTextRange(-1, receiver:End()))

    local k = info.kind
    if k == PrivateIdentifierKind.Accessor then
        return self:Factory():NewClassPrivateFieldSetHelper(
            receiver,
            info.brandCheckIdentifier,
            right,
            info.kind,
            info.setterName
        )
    elseif k == PrivateIdentifierKind.Method then
        return self:Factory():NewClassPrivateFieldSetHelper(
            receiver,
            info.brandCheckIdentifier,
            right,
            info.kind,
            nil
        )
    elseif k == PrivateIdentifierKind.Field then
        local f
        if info.isStatic then
            f = info.variableName
        end
        return self:Factory():NewClassPrivateFieldSetHelper(
            receiver,
            info.brandCheckIdentifier,
            right,
            info.kind,
            f
        )
    elseif k == PrivateIdentifierKind.Untransformed then
        debug.Fail("Access helpers should not be created for untransformed private elements")
        return nil
    end
    debug.AssertNever(info, "Unknown private element type")
    return nil
end

function classFieldsTransformer:getPrivateInstanceMethodsAndAccessors(node)
    return core.Filter(node:Members(), function(n) return estransforms.isNonStaticMethodOrAccessorWithPrivateName(n) end)
end

-- memberContainsConstructorReference checks if a class member's body contains an identifier
-- that resolves to the class declaration. Replaces Strada's resolver.hasNodeCheckFlag(member,
-- NodeCheckFlags.ContainsConstructorReference) by walking the AST with the EmitResolver.
-- Only checks member bodies (not computed property names), since computed property names
-- are evaluated during class definition when the binding is still correct.
function classFieldsTransformer:memberContainsConstructorReference(member, classDecl)
    local classOriginal = self:EmitContext():MostOriginal(classDecl)
    local className = ast.GetNameOfDeclaration(classDecl)
    local check
    check = function(n)
        if ast.IsIdentifier(n) and n ~= className then
            local decl = self.resolver:GetReferencedValueDeclaration(n)
            if decl == classOriginal then
                return true
            end
        end
        -- For PropertyAccessExpression, only check the expression, not the name.
        -- The .Name() is a property access name, not a value reference to the class.
        if ast.IsPropertyAccessExpression(n) then
            return check(n:Expression())
        end
        return n:ForEachChild(check)
    end
    -- Check only the body/initializer of the member, not the name (which may be
    -- a computed property name that shouldn't trigger alias substitution).
    if ast.IsClassStaticBlockDeclaration(member) then
        local body = member:AsClassStaticBlockDeclaration().body
        if body ~= nil and check(body:AsNode()) then
            return true
        end
    else
        local body = member:Body()
        if body ~= nil and check(body) then
            return true
        end
    end
    if ast.IsPropertyDeclaration(member) then
        local init = member:Initializer()
        if init ~= nil and check(init) then
            return true
        end
    end
    return false
end

-- classContainsConstructorReference checks if any member of a class contains
-- references to the class's own constructor. Replaces Strada's
-- resolver.hasNodeCheckFlag(node, NodeCheckFlags.ContainsConstructorReference).
function classFieldsTransformer:classContainsConstructorReference(node)
    for _, member in ipairs(node:Members() or {}) do
        if self:memberContainsConstructorReference(member, node) then
            return true
        end
    end
    return false
end

function classFieldsTransformer:getClassFacts(node)
    local facts = classFacts.None

    local original = self:EmitContext():MostOriginal(node)
    if ast.IsClassLike(original) and ast.ClassOrConstructorParameterIsDecorated(self.legacyDecorators, original) then
        facts = facts | classFacts.ClassWasDecorated
    end

    if self.shouldTransformPrivateElementsOrClassStaticBlocks and
        (estransforms.classHasClassThisAssignment(self:EmitContext(), node) or estransforms.classHasExplicitlyAssignedName(self:EmitContext(), node)) then
        facts = facts | classFacts.NeedsClassConstructorReference
    end

    local containsPublicInstanceFields = false
    local containsInitializedPublicInstanceFields = false
    local containsInstancePrivateElements = false
    local containsInstanceAutoAccessors = false

    for _, member in ipairs(node:Members() or {}) do
        if ast.IsStatic(member) then
            if member:Name() ~= nil and (ast.IsPrivateIdentifier(member:Name()) or ast.IsAutoAccessorPropertyDeclaration(member)) and
                self.shouldTransformPrivateElementsOrClassStaticBlocks then
                facts = facts | classFacts.NeedsClassConstructorReference
            elseif ast.IsAutoAccessorPropertyDeclaration(member) and self.shouldTransformAutoAccessors and
                node:Name() == nil and self:EmitContext():ClassThis(node) == nil then
                facts = facts | classFacts.NeedsClassConstructorReference
            end
            if ast.IsPropertyDeclaration(member) or ast.IsClassStaticBlockDeclaration(member) then
                if self.shouldTransformThisInStaticInitializers and member:SubtreeFacts() & SubtreeFacts.SubtreeContainsLexicalThis ~= 0 then
                    facts = facts | classFacts.NeedsSubstitutionForThisInClassStaticField
                    if facts & classFacts.ClassWasDecorated == 0 then
                        facts = facts | classFacts.NeedsClassConstructorReference
                    end
                end
                if self.shouldTransformSuperInStaticInitializers and member:SubtreeFacts() & SubtreeFacts.SubtreeContainsLexicalSuper ~= 0 then
                    if facts & classFacts.ClassWasDecorated == 0 then
                        facts = facts | classFacts.NeedsClassConstructorReference | classFacts.NeedsClassSuperReference
                    end
                end
            end
        elseif not ast.HasAbstractModifier(self:EmitContext():MostOriginal(member)) then
            if ast.IsAutoAccessorPropertyDeclaration(member) then
                containsInstanceAutoAccessors = true
                containsInstancePrivateElements = containsInstancePrivateElements or ast.IsPrivateIdentifierClassElementDeclaration(member)
            elseif ast.IsPrivateIdentifierClassElementDeclaration(member) then
                containsInstancePrivateElements = true
                if self:memberContainsConstructorReference(member, node) then
                    facts = facts | classFacts.NeedsClassConstructorReference
                end
            elseif ast.IsPropertyDeclaration(member) then
                containsPublicInstanceFields = true
                containsInitializedPublicInstanceFields = containsInitializedPublicInstanceFields or member:Initializer() ~= nil
            end
        end
    end

    local willHoistInitializersToConstructor = (self.shouldTransformInitializersUsingDefine and containsPublicInstanceFields) or
        (self.shouldTransformInitializersUsingSet and containsInitializedPublicInstanceFields) or
        (self.shouldTransformPrivateElementsOrClassStaticBlocks and containsInstancePrivateElements) or
        (self.shouldTransformPrivateElementsOrClassStaticBlocks and containsInstanceAutoAccessors and self.shouldTransformAutoAccessors)

    if willHoistInitializersToConstructor then
        facts = facts | classFacts.WillHoistInitializersToConstructor
    end

    return facts
end

function classFieldsTransformer:visitExpressionWithTypeArgumentsInHeritageClause(node)
    local facts = classFacts.None
    if self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
        facts = self.lexicalEnvironment.data.facts
    end
    if facts & classFacts.NeedsClassSuperReference ~= 0 then
        local temp = self:Factory():NewTempVariableEx({
            flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes,
        })
        self:EmitContext():AddVariableDeclaration(temp)
        self:getClassLexicalEnvironment().superClassReference = temp
        return self:Factory():UpdateExpressionWithTypeArguments(
            node,
            self:Factory():NewAssignmentExpression(temp, self:Visitor():VisitNode(node.expression)),
            nil -- typeArguments
        )
    end
    return self.heritageClauseVisitor:VisitEachChild(node:AsNode())
end

function classFieldsTransformer:visitInNewClassLexicalEnvironment(node, visitor)
    local savedCurrentClassContainer = self.currentClassContainer
    local savedPendingExpressions = self.pendingExpressions
    local savedLexicalEnvironment = self.lexicalEnvironment
    self.currentClassContainer = node
    self.pendingExpressions = nil
    self:startClassLexicalEnvironment()
    local original = self:EmitContext():MostOriginal(node)
    self.enclosingClassDeclarations:Add(original)

    if self.shouldTransformPrivateElementsOrClassStaticBlocks or self:nodeHasTransformPrivateStaticElementsFlag(node) then
        local name = ast.GetNameOfDeclaration(node)
        local assignedName = self:EmitContext():AssignedName(node)
        if name ~= nil and ast.IsIdentifier(name) then
            self:getPrivateIdentifierEnvironment().data.className = name
        elseif assignedName ~= nil then
            if ast.IsStringLiteral(assignedName) then
                -- If the assigned name has a textSourceNode that is an identifier, use it directly.
                local textSourceNode = self:EmitContext():TextSource(assignedName)
                if textSourceNode ~= nil and ast.IsIdentifier(textSourceNode) then
                    self:getPrivateIdentifierEnvironment().data.className = textSourceNode
                elseif scanner.IsIdentifierText(assignedName:Text(), core.LanguageVariant.Standard) then
                    -- If the text is a valid identifier, create an identifier from it.
                    local prefixName = self:Factory():NewIdentifier(assignedName:Text())
                    self:getPrivateIdentifierEnvironment().data.className = prefixName
                end
            end
        end
    end

    if self.shouldTransformPrivateElementsOrClassStaticBlocks then
        local privateInstanceMethodsAndAccessors = self:getPrivateInstanceMethodsAndAccessors(node)
        if core.Len(privateInstanceMethodsAndAccessors) > 0 then
            self:getPrivateIdentifierEnvironment().data.weakSetName = self:createHoistedVariableForClass(
                "instances",
                privateInstanceMethodsAndAccessors[1]:Name(),
                ""
            )
        end
    end

    local facts = self:getClassFacts(node)
    if facts ~= classFacts.None then
        self:getClassLexicalEnvironment().facts = facts
    end

    local result = visitor(self, node, facts)
    self.enclosingClassDeclarations:Delete(original)
    self:endClassLexicalEnvironment()
    debug.Assert(self.lexicalEnvironment == savedLexicalEnvironment)
    self.currentClassContainer = savedCurrentClassContainer
    self.pendingExpressions = savedPendingExpressions
    self.lexicalEnvironment = savedLexicalEnvironment
    return result
end

function classFieldsTransformer:visitClassDeclaration(node)
    return self:visitInNewClassLexicalEnvironment(node:AsNode(), classFieldsTransformer.visitClassDeclarationInNewClassLexicalEnvironment)
end

function classFieldsTransformer:visitClassDeclarationInNewClassLexicalEnvironment(node, facts)
    local classDecl = node:AsClassDeclaration()
    -- If a class has private static fields, or a static field has a `this` or `super` reference,
    -- then we need to allocate a temp variable to hold on to that reference.
    local pendingClassReferenceAssignment
    if facts & classFacts.NeedsClassConstructorReference ~= 0 then
        -- If we aren't transforming class static blocks, then we can't reuse `_classThis` since in
        -- `class C { ... static { _classThis = ... } }; _classThis = C` the outer assignment would occur *after*
        -- class static blocks evaluate and would overwrite the replacement constructor produced by class
        -- decorators.

        -- If we are transforming class static blocks, then we can reuse `_classThis` since the assignment
        -- will be evaluated *before* the transformed static blocks are evaluated and thus won't overwrite
        -- the replacement constructor.

        if self.shouldTransformPrivateElementsOrClassStaticBlocks and self:EmitContext():ClassThis(node) ~= nil then
            local classThis = self:EmitContext():ClassThis(node)
            self:getClassLexicalEnvironment().classConstructor = classThis
            pendingClassReferenceAssignment = self:Factory():NewAssignmentExpression(
                classThis,
                self:Factory():GetLocalName(node)
            )
        else
            local temp = self:Factory():NewTempVariableEx({
                flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes,
            })
            self:EmitContext():AddVariableDeclaration(temp)
            self:getClassLexicalEnvironment().classConstructor = temp:Clone(self:Factory())
            pendingClassReferenceAssignment = self:Factory():NewAssignmentExpression(
                temp,
                self:Factory():GetLocalName(node)
            )
        end
    end

    if self:EmitContext():ClassThis(node) ~= nil then
        self:getClassLexicalEnvironment().classThis = self:EmitContext():ClassThis(node)
    end

    local isClassWithConstructorReference = self:classContainsConstructorReference(node)

    -- Register class alias BEFORE visiting members (Strada registers after, since its
    -- onSubstituteNode runs at emit time; we substitute eagerly during transformation).
    local alias = self:getClassLexicalEnvironment().classConstructor
    if isClassWithConstructorReference and alias ~= nil then
        self.classAliases[self:EmitContext():MostOriginal(node)] = alias
    end

    local modifiers = self.modifierVisitor:VisitModifiers(classDecl:Modifiers())
    local heritageClauses = self.heritageClauseVisitor:VisitNodes(classDecl.heritageClauses)
    local members, membersPrologue = self:transformClassMembers(node)

    local statements = {}

    if pendingClassReferenceAssignment ~= nil then
        self.pendingExpressions = core.Concatenate({ pendingClassReferenceAssignment }, self.pendingExpressions)
    end

    -- Write any pending expressions from elided or moved computed property names
    if core.Len(self.pendingExpressions) > 0 then
        statements[#statements + 1] = self:Factory():NewExpressionStatement(self:Factory():InlineExpressions(self.pendingExpressions))
    end

    -- A class declaration without a name needs a generated name if it has static
    -- initialized properties, since those will be moved outside the class body and
    -- need to reference the class by name.
    local name = classDecl:Name()

    if self.shouldTransformInitializersUsingSet or self.shouldTransformPrivateElementsOrClassStaticBlocks then
        -- Emit static property assignment. Because classDeclaration is lexically evaluated,
        -- it is safe to emit static property assignment after classDeclaration
        -- From ES6 specification:
        --   HasLexicalDeclaration (N) : Determines if the argument identifier has a binding in this environment record that was created using
        --                               a lexical declaration such as a LexicalDeclaration or a ClassDeclaration.
        local staticProperties = self:getStaticPropertiesAndClassStaticBlock(node)
        if core.Len(staticProperties) > 0 then
            if name == nil then
                name = self:Factory():NewGeneratedNameForNode(node)
            end
            statements = self:addPropertyOrClassStaticBlockStatements(statements, staticProperties, self:Factory():GetLocalName(node))
        end
    end

    local isExport = ast.HasSyntacticModifier(node, ModifierFlags.Export)
    local isDefault = ast.HasSyntacticModifier(node, ModifierFlags.Default)

    if #statements > 0 and isExport and isDefault then
        modifiers = transformers.ExtractModifiers(self:EmitContext(), modifiers, ~ModifierFlags.ExportDefault)
        local exportAssignment = self:Factory():NewExportAssignment(nil, false, nil, self:Factory():GetLocalName(node))
        statements[#statements + 1] = exportAssignment
    end

    local updatedClass = self:Factory():UpdateClassDeclaration(
        classDecl,
        modifiers,
        name,
        nil, -- typeParameters
        heritageClauses,
        members
    )

    local result = {}
    if membersPrologue ~= nil then
        result[#result + 1] = self:Factory():NewExpressionStatement(membersPrologue)
    end
    result[#result + 1] = updatedClass
    for _, s in ipairs(statements) do
        result[#result + 1] = s
    end
    return self:Factory():NewSyntaxList(result)
end

function classFieldsTransformer:visitClassExpression(node)
    return self:visitInNewClassLexicalEnvironment(node:AsNode(), classFieldsTransformer.visitClassExpressionInNewClassLexicalEnvironment)
end

function classFieldsTransformer:visitClassExpressionInNewClassLexicalEnvironment(node, facts)
    local classExpr = node:AsClassExpression()

    -- If this class expression is a transformation of a decorated class declaration,
    -- then we want to output the pendingExpressions as statements, not as inlined
    -- expressions with the class statement.
    --
    -- In this case, we use pendingStatements to produce the same output as the
    -- class declaration transformation. The VariableStatement visitor will insert
    -- these statements after the class expression variable statement.
    local isDecoratedClassDeclaration = facts & classFacts.ClassWasDecorated ~= 0

    if self:EmitContext():ClassThis(node) ~= nil then
        self:getClassLexicalEnvironment().classThis = self:EmitContext():ClassThis(node)
    end

    local temp
    if facts & classFacts.NeedsClassConstructorReference ~= 0 then
        if (self.shouldTransformPrivateElementsOrClassStaticBlocks or self:nodeHasTransformPrivateStaticElementsFlag(node)) and self:EmitContext():ClassThis(node) ~= nil then
            local classThis = self:EmitContext():ClassThis(node)
            self:getClassLexicalEnvironment().classConstructor = classThis
            temp = classThis
        else
            temp = self:Factory():NewTempVariableEx({
                flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes,
            })
            if self:classExpressionNeedsBlockScopedTemp() then
                self:EmitContext():AddLexicalDeclaration(temp)
            else
                self:EmitContext():AddVariableDeclaration(temp)
            end
            self:getClassLexicalEnvironment().classConstructor = temp:Clone(self:Factory())
        end
    end

    local staticPropertiesOrClassStaticBlocks = self:getStaticPropertiesAndClassStaticBlock(node)

    -- Pre-compute whether the class expression will need a temp variable wrapper.
    -- Strada registers class aliases AFTER transformClassMembers (since onSubstituteNode runs
    -- at emit time), but we must predict this before visiting members since we substitute
    -- eagerly. This requires pre-detecting willHavePrivatePendingExpressions.
    local isClassWithConstructorReference = false
    local hasTransformableStatics = false
    local deferTempDeclaration = false
    if not isDecoratedClassDeclaration then
        isClassWithConstructorReference = self:classContainsConstructorReference(node)
        hasTransformableStatics = (self.shouldTransformPrivateElementsOrClassStaticBlocks or
            self:nodeHasTransformPrivateStaticElementsFlag(node)) and
            core.Some(staticPropertiesOrClassStaticBlocks, function(n)
                return ast.IsClassStaticBlockDeclaration(n) or
                    ast.IsPrivateIdentifierClassElementDeclaration(n) or
                    (self.shouldTransformInitializers and ast.IsInitializedProperty(n))
            end)

        -- Private instance elements (fields, methods, accessors) transformed to
        -- WeakMap/WeakSet will add initialization expressions to pendingExpressions
        -- during transformClassMembers. Pre-detect this so we know whether the class
        -- will be wrapped with a temp variable.
        local willHavePrivatePendingExpressions = self.shouldTransformPrivateElementsOrClassStaticBlocks and
            core.Some(node:Members(), function(n)
                return ast.IsPrivateIdentifierClassElementDeclaration(n) and not ast.HasStaticModifier(n) and self:shouldTransformClassElementToWeakMap(n)
            end)
        local willNeedTempWrapper = hasTransformableStatics or willHavePrivatePendingExpressions

        -- Register class alias BEFORE visiting members (Strada registers after, since its
        -- onSubstituteNode runs at emit time). Only register when the class will be wrapped
        -- with a temp, matching Strada's conditional registration.
        if isClassWithConstructorReference and willNeedTempWrapper and self:getClassLexicalEnvironment().classConstructor == nil then
            -- Create temp early so the alias is available during member visiting, even though in the Strada
            -- reference the temp would be created later in the pendingExpressions branch.
            temp = self:Factory():NewTempVariableEx({
                flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes,
            })
            -- Defer AddVariableDeclaration to preserve Strada's variable declaration ordering.
            deferTempDeclaration = true
            self:getClassLexicalEnvironment().classConstructor = temp:Clone(self:Factory())
        end
        local alias = self:getClassLexicalEnvironment().classConstructor
        if isClassWithConstructorReference and willNeedTempWrapper and alias ~= nil then
            self.classAliases[self:EmitContext():MostOriginal(node)] = alias
        end
    end

    local modifiers = self.modifierVisitor:VisitModifiers(classExpr:Modifiers())
    local heritageClauses = self.heritageClauseVisitor:VisitNodes(classExpr.heritageClauses)
    local members, membersPrologue = self:transformClassMembers(node)

    if deferTempDeclaration then
        if self:classExpressionNeedsBlockScopedTemp() then
            self:EmitContext():AddLexicalDeclaration(temp)
        else
            self:EmitContext():AddVariableDeclaration(temp)
        end
    end

    local classExpression = self:Factory():UpdateClassExpression(
        classExpr,
        modifiers,
        classExpr:Name(),
        nil, -- typeParameters
        heritageClauses,
        members
    )

    local expressions = {}
    if membersPrologue ~= nil then
        expressions[#expressions + 1] = membersPrologue
    end

    if not isDecoratedClassDeclaration then
        if hasTransformableStatics or core.Len(self.pendingExpressions) > 0 then
            if temp == nil then
                temp = self:Factory():NewTempVariableEx({
                    flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes,
                })
                if self:classExpressionNeedsBlockScopedTemp() then
                    self:EmitContext():AddLexicalDeclaration(temp)
                else
                    self:EmitContext():AddVariableDeclaration(temp)
                end
                self:getClassLexicalEnvironment().classConstructor = temp:Clone(self:Factory())
                if isClassWithConstructorReference then
                    self.classAliases[self:EmitContext():MostOriginal(node)] = self:getClassLexicalEnvironment().classConstructor
                end
            end

            expressions[#expressions + 1] = self:Factory():NewAssignmentExpression(temp, classExpression)

            -- Add any pending expressions leftover from elided or relocated computed property names
            for _, e in ipairs(self.pendingExpressions or {}) do
                expressions[#expressions + 1] = e
            end

            for _, e in ipairs(self:generateInitializedPropertyExpressionsOrClassStaticBlock(staticPropertiesOrClassStaticBlocks, temp) or {}) do
                expressions[#expressions + 1] = e
            end
            expressions[#expressions + 1] = temp:Clone(self:Factory())
        else
            expressions[#expressions + 1] = classExpression
        end
    else
        -- Decorated class declaration path: emit static properties as separate statements
        -- via pendingStatements, matching the class declaration output structure.

        -- Write any pending expressions from elided or moved computed property names
        if core.Len(self.pendingExpressions) > 0 then
            for _, expr in ipairs(self.pendingExpressions) do
                self.pendingStatements = core.Append(self.pendingStatements, self:Factory():NewExpressionStatement(expr))
            end
        end

        -- Emit static properties as statements (via pendingStatements) using the class's
        -- internal name as the receiver, matching the class declaration output structure.
        if core.Len(staticPropertiesOrClassStaticBlocks) > 0 then
            local classThisOrName = self:EmitContext():ClassThis(node)
            if classThisOrName == nil then
                classThisOrName = self:Factory():GetLocalName(node)
            end
            self.pendingStatements = self:addPropertyOrClassStaticBlockStatements(self.pendingStatements, staticPropertiesOrClassStaticBlocks, classThisOrName)
        end

        if temp ~= nil then
            expressions[#expressions + 1] = self:Factory():NewAssignmentExpression(temp, classExpression)
        elseif self.shouldTransformPrivateElementsOrClassStaticBlocks and self:EmitContext():ClassThis(node) ~= nil then
            expressions[#expressions + 1] = self:Factory():NewAssignmentExpression(self:EmitContext():ClassThis(node), classExpression)
        else
            expressions[#expressions + 1] = classExpression
        end
    end

    if #expressions > 1 then
        self:EmitContext():AddEmitFlags(classExpression, EF.EFIndented)
        for _, expr in ipairs(expressions) do
            self:EmitContext():AddEmitFlags(expr, EF.EFStartOnNewLine)
        end
    end
    return self:Factory():InlineExpressions(expressions)
end

function classFieldsTransformer:visitClassStaticBlockDeclaration(node)
    if not self.shouldTransformPrivateElementsOrClassStaticBlocks then
        return self:Visitor():VisitEachChild(node)
    end
    -- ClassStaticBlockDeclaration for classes are transformed in visitClassDeclaration/visitClassExpression.
    return nil
end

-- visitThisExpression replaces Strada's substituteThisExpression / onSubstituteNode.
-- Strada substitutes `this` at emit time; we do it eagerly during transformation.
--
-- The Strada noSubstitution set (ensureDynamicThisIfNeeded) is not needed because
-- transformAutoAccessor() passes the receiver directly rather than emitting `this`.
function classFieldsTransformer:visitThisExpression(node)
    if self.insideComputedPropertyName and self.shouldTransformThisInStaticInitializers and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
        -- Don't replace `this` in computed property names for ES-decorated classes.
        -- The esDecorator transformer wraps them in an arrow IIFE where `this` already
        -- refers to the correct outer scope.
        if self.lexicalEnvironment.data.facts & classFacts.ClassWasDecorated == 0 or self.legacyDecorators then
            local classThis = self:tryGetClassThisNoContainer()
            if classThis ~= nil then
                return classThis
            end
        end
    end
    if self.shouldTransformThisInStaticInitializers and self.currentClassElement ~= nil and
        (ast.IsClassStaticBlockDeclaration(self.currentClassElement) or
            (ast.IsPropertyDeclaration(self.currentClassElement) and ast.HasStaticModifier(self.currentClassElement))) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil then
        local classThis = self:tryGetClassThisNoContainer()
        if classThis ~= nil then
            return classThis
        end
        -- When the class was decorated with legacy decorators and no class constructor
        -- reference is available, the decorator may replace the constructor, so `this`
        -- cannot reliably point to the class. Use `(void 0)` instead.
        if self.lexicalEnvironment.data.facts & classFacts.ClassWasDecorated ~= 0 and self.legacyDecorators then
            return self:Factory():NewParenthesizedExpression(self:Factory():NewVoidZeroExpression())
        end
    end
    return node
end

-- Returns members (NodeList), prologue (Expression).
function classFieldsTransformer:transformClassMembers(node)
    local shouldTransformPrivateStaticElementsInClass = self:EmitContext():EmitFlags(node) & EF.EFTransformPrivateStaticElements ~= 0
    local prologue

    -- Declare private names
    if self.shouldTransformPrivateElementsOrClassStaticBlocks or self.shouldTransformPrivateStaticElementsInFile then
        for _, member in ipairs(node:Members() or {}) do
            if ast.IsPrivateIdentifierClassElementDeclaration(member) then
                if self:shouldTransformClassElementToWeakMap(member) then
                    self:addPrivateIdentifierToEnvironment(member)
                else
                    local env = self:getPrivateIdentifierEnvironment()
                    self:setPrivateIdentifier(env, member:Name(), estransforms.newPrivateIdentifierInfo({
                        kind = PrivateIdentifierKind.Untransformed,
                    }))
                end
            end
        end

        if self.shouldTransformPrivateElementsOrClassStaticBlocks then
            if core.Len(self:getPrivateInstanceMethodsAndAccessors(node)) > 0 then
                self:createBrandCheckWeakSetForPrivateMethods()
            end
        end

        if self:shouldTransformAutoAccessorsInCurrentClass() then
            for _, member in ipairs(node:Members() or {}) do
                if ast.IsAutoAccessorPropertyDeclaration(member) then
                    local storageName = self:Factory():NewGeneratedPrivateNameForNodeEx(member:Name(), { flags = 0, prefix = "", suffix = "_accessor_storage" })
                    if self.shouldTransformPrivateElementsOrClassStaticBlocks or
                        shouldTransformPrivateStaticElementsInClass and ast.HasStaticModifier(member) then
                        self:addPrivateIdentifierPropertyDeclarationToEnvironment(member, storageName)
                    else
                        local env = self:getPrivateIdentifierEnvironment()
                        -- Only register as untransformed if it hasn't already been registered
                        -- by the first loop (e.g., if esDecorators expanded a private auto-accessor
                        -- into a backing field with the same generated name).
                        local _, ok = self:getPrivateIdentifier(env, storageName)
                        if not ok then
                            self:setPrivateIdentifier(env, storageName, estransforms.newPrivateIdentifierInfo({
                                kind = PrivateIdentifierKind.Untransformed,
                            }))
                        end
                    end
                end
            end
        end
    end

    local members = self.classElementVisitor:VisitNodes(node:MemberList())

    -- Create a synthetic constructor if necessary
    local syntheticConstructor
    if not core.Some(members.nodes, function(n) return ast.IsConstructorDeclaration(n) end) then
        syntheticConstructor = self:transformConstructor(nil, node)
    end

    -- If there are pending expressions create a class static block in which to evaluate them, but only if
    -- class static blocks are not also being transformed. This block will be injected at the top of the class
    -- to ensure that expressions from computed property names are evaluated before any other static
    -- initializers.
    local syntheticStaticBlock
    if not self.shouldTransformPrivateElementsOrClassStaticBlocks and core.Len(self.pendingExpressions) > 0 then
        local statement = self:Factory():NewExpressionStatement(self:Factory():InlineExpressions(self.pendingExpressions))
        if statement:SubtreeFacts() & SubtreeFacts.SubtreeContainsLexicalThisOrSuper ~= 0 then
            -- If there are `this` or `super` references from computed property names, shift the expression
            -- into an arrow function to be evaluated in the outer scope so that `this` and `super` are
            -- properly captured.
            local temp = self:Factory():NewTempVariable()
            self:EmitContext():AddVariableDeclaration(temp)
            local arrow = self:Factory():NewArrowFunction(
                nil, -- modifiers
                nil, -- typeParameters
                self:Factory():NewNodeList(nil), -- parameters
                nil, -- returnType
                nil, -- fullSignature
                self:Factory():NewToken(Kind.EqualsGreaterThanToken), -- equalsGreaterThanToken
                self:Factory():NewBlock(self:Factory():NewNodeList({ statement }), false)
            )
            prologue = self:Factory():NewAssignmentExpression(temp, arrow)
            statement = self:Factory():NewExpressionStatement(
                self:Factory():NewCallExpression(temp, nil, nil, self:Factory():NewNodeList(nil), NodeFlags.None)
            )
        end

        local block = self:Factory():NewBlock(self:Factory():NewNodeList({ statement }), false)
        syntheticStaticBlock = self:Factory():NewClassStaticBlockDeclaration(nil, block)
        self.pendingExpressions = nil
    end

    -- If we created a synthetic constructor or class static block, add them to the visited members
    if syntheticConstructor ~= nil or syntheticStaticBlock ~= nil then
        local membersArray = {}

        -- Find and preserve classThis assignment block and named evaluation helper block at the top
        local classThisIdx = core.FindIndex(members.nodes, function(n)
            return estransforms.isClassThisAssignmentBlock(self:EmitContext(), n)
        end)
        local namedEvalIdx = core.FindIndex(members.nodes, function(n)
            return estransforms.isClassNamedEvaluationHelperBlock(self:EmitContext(), n)
        end)

        if classThisIdx >= 0 then
            membersArray[#membersArray + 1] = members.nodes[classThisIdx + 1]
        end
        if namedEvalIdx >= 0 then
            membersArray[#membersArray + 1] = members.nodes[namedEvalIdx + 1]
        end
        if syntheticConstructor ~= nil then
            membersArray[#membersArray + 1] = syntheticConstructor
        end
        if syntheticStaticBlock ~= nil then
            membersArray[#membersArray + 1] = syntheticStaticBlock
        end

        for i1, member in ipairs(members.nodes or {}) do
            local i = i1 - 1
            if i ~= classThisIdx and i ~= namedEvalIdx then
                membersArray[#membersArray + 1] = member
            end
        end
        members = self:Factory():NewNodeList(membersArray)
        members.loc = node:MemberList().loc
    end

    return members, prologue
end

function classFieldsTransformer:createBrandCheckWeakSetForPrivateMethods()
    local env = self:getPrivateIdentifierEnvironment()
    local weakSetName = env.data.weakSetName
    debug.Assert(weakSetName ~= nil, "weakSetName should be set in private identifier environment")

    self:addPendingExpressions(
        self:Factory():NewAssignmentExpression(
            weakSetName,
            self:Factory():NewNewExpression(
                self:Factory():NewIdentifier("WeakSet"),
                nil, -- typeArguments
                self:Factory():NewNodeList(nil)
            )
        )
    )
end

function classFieldsTransformer:transformConstructor(constructor, container)
    -- NOTE: The Strada reference pre-visits the constructor via `visitNode(constructor, visitor)` before
    -- checking WillHoistInitializersToConstructor. This is not done here because Go's variable environment
    -- (StartVariableEnvironment/EndAndMergeVariableEnvironment) is scoped inside transformConstructorBody.
    -- Pre-visiting would hoist variables outside that scope, causing them to appear after field initializers
    -- instead of before. Instead, we visit parameters and body separately within the correct scopes.
    if self.lexicalEnvironment == nil or self.lexicalEnvironment.data == nil or
        self.lexicalEnvironment.data.facts & classFacts.WillHoistInitializersToConstructor == 0 then
        if constructor ~= nil then
            return self:Visitor():VisitEachChild(constructor:AsNode())
        end
        return nil
    end

    local extendsClauseElement = ast.GetClassExtendsHeritageElement(container)
    local isDerivedClass = extendsClauseElement ~= nil and ast.SkipOuterExpressions(extendsClauseElement:Expression(), OEK.OEKAll).kind ~= Kind.NullKeyword

    local parameters
    if constructor ~= nil then
        parameters = self:Visitor():VisitNodes(constructor.parameters)
    end

    local body = self:transformConstructorBody(container, constructor, isDerivedClass)
    if body == nil then
        if constructor ~= nil then
            return self:Visitor():VisitEachChild(constructor:AsNode())
        end
        return nil
    end

    if constructor ~= nil then
        debug.Assert(parameters ~= nil)
        return self:Factory():UpdateConstructorDeclaration(
            constructor,
            nil, -- modifiers
            nil, -- typeParameters
            parameters,
            nil, -- returnType
            nil, -- fullSignature
            body
        )
    end

    if parameters == nil then
        parameters = self:Factory():NewNodeList(nil)
    end

    local result = self:Factory():NewConstructorDeclaration(
        nil, -- modifiers
        nil, -- typeParameters
        parameters,
        nil, -- returnType
        nil, -- fullSignature
        body
    )
    result.loc = container.loc
    return result
end

function classFieldsTransformer:transformConstructorBodyWorker(statementsOut, statementsIn, statementOffset, superPath, superPathDepth, initializerStatements, constructor)
    statementsOut = statementsOut or {}
    local superStatementIndex = superPath[superPathDepth + 1]
    local superStatement = statementsIn[superStatementIndex + 1]

    -- Visit statements before super
    local visited = self:Visitor():VisitSlice(core.Slice(statementsIn, statementOffset, superStatementIndex))
    core.AppendAll(statementsOut, visited)
    statementOffset = superStatementIndex + 1

    if ast.IsTryStatement(superStatement) then
        local tryBlock = superStatement:AsTryStatement().tryBlock:AsBlock()
        local tryBlockStatements = self:transformConstructorBodyWorker(
            nil,
            tryBlock.statements.nodes,
            0, -- statementOffset
            superPath,
            superPathDepth + 1,
            initializerStatements,
            constructor
        )
        local tryStatementList = self:Factory():NewNodeList(tryBlockStatements)
        tryStatementList.loc = tryBlock.statements.loc

        local catchClause = self:Visitor():VisitNode(superStatement:AsTryStatement().catchClause)
        local finallyBlock = self:Visitor():VisitNode(superStatement:AsTryStatement().finallyBlock)

        local updated = self:Factory():UpdateTryStatement(
            superStatement:AsTryStatement(),
            self:Factory():UpdateBlock(tryBlock, tryStatementList, tryBlock.multiLine),
            catchClause,
            finallyBlock
        )
        statementsOut[#statementsOut + 1] = updated
    else
        local visitedSuper = self:Visitor():VisitSlice(core.Slice(statementsIn, superStatementIndex, superStatementIndex + 1))
        core.AppendAll(statementsOut, visitedSuper)

        -- Add the property initializers. Transforms this:
        --
        --  public x = 1;
        --
        -- Into this:
        --
        --  constructor() {
        --      this.x = 1;
        --  }
        --
        -- If we do useDefineForClassFields, they'll be converted elsewhere.
        -- We instead *remove* them from the transformed output at this stage.

        -- parameter-property assignments should occur immediately after the prologue and `super()`,
        -- so only count the statements that immediately follow.
        while statementOffset < #statementsIn do
            local stmt = statementsIn[statementOffset + 1]
            local orig = self:EmitContext():MostOriginal(stmt)
            if ast.IsParameterPropertyDeclaration(orig, constructor:AsNode()) then
                statementOffset = statementOffset + 1
            else
                break
            end
        end

        core.AppendAll(statementsOut, initializerStatements)
    end

    -- Visit remaining statements
    local visited2 = self:Visitor():VisitSlice(core.Slice(statementsIn, statementOffset))
    core.AppendAll(statementsOut, visited2)
    return statementsOut
end

function classFieldsTransformer:transformConstructorBody(container, constructor, isDerivedClass)
    local instanceProperties = self:getProperties(container, false, false)
    local properties = instanceProperties
    if not self.compilerOptions:GetUseDefineForClassFields() then
        properties = core.Filter(properties, function(prop)
            return prop:Initializer() ~= nil or ast.IsPrivateIdentifier(prop:Name()) or ast.HasAccessorModifier(prop)
        end)
    end

    local privateMethodsAndAccessors = self:getPrivateInstanceMethodsAndAccessors(container)
    local needsConstructorBody = core.Len(properties) > 0 or core.Len(privateMethodsAndAccessors) > 0

    -- Only generate synthetic constructor when there are property initializers to move.
    if constructor == nil and not needsConstructorBody then
        return self:EmitContext():VisitFunctionBody(nil, self:Visitor())
    end

    self:EmitContext():StartVariableEnvironment()

    local needsSyntheticConstructor = constructor == nil and isDerivedClass
    local statements = {}

    -- Add the property initializers. Transforms this:
    --
    --  public x = 1;
    --
    -- Into this:
    --
    --  constructor() {
    --      this.x = 1;
    --  }
    --
    local initializerStatements = {}
    local receiver = self:Factory():NewThisExpression()

    -- private methods can be called in property initializers, they should execute first
    initializerStatements = self:addInstanceMethodStatements(initializerStatements, privateMethodsAndAccessors, receiver)

    if constructor ~= nil then
        local parameterProperties = core.Filter(instanceProperties, function(prop)
            return ast.IsParameterPropertyDeclaration(self:EmitContext():MostOriginal(prop), constructor:AsNode())
        end)
        local nonParameterProperties = core.Filter(properties, function(prop)
            return not ast.IsParameterPropertyDeclaration(self:EmitContext():MostOriginal(prop), constructor:AsNode())
        end)
        initializerStatements = self:addPropertyOrClassStaticBlockStatements(initializerStatements, parameterProperties, receiver)
        initializerStatements = self:addPropertyOrClassStaticBlockStatements(initializerStatements, nonParameterProperties, receiver)
    else
        initializerStatements = self:addPropertyOrClassStaticBlockStatements(initializerStatements, properties, receiver)
    end

    if constructor ~= nil and constructor.body ~= nil then
        local body = constructor.body:AsBlock()

        -- Copy prologue
        for _, stmt in ipairs(body.statements.nodes or {}) do
            if ast.IsPrologueDirective(stmt) then
                statements[#statements + 1] = stmt
            else
                break
            end
        end
        local statementOffset = #statements

        local superPath = transformers.FindSuperStatementIndexPath(body.statements.nodes, statementOffset)
        if core.Len(superPath) > 0 then
            statements = self:transformConstructorBodyWorker(statements, body.statements.nodes, statementOffset, superPath, 0, initializerStatements, constructor)
        else
            -- parameter-property assignments should occur immediately after the prologue and `super()`,
            -- so only count the statements that immediately follow.
            while statementOffset < core.Len(body.statements.nodes) do
                local stmt = body.statements.nodes[statementOffset + 1]
                local orig = self:EmitContext():MostOriginal(stmt)
                if ast.IsParameterPropertyDeclaration(orig, constructor:AsNode()) then
                    statementOffset = statementOffset + 1
                else
                    break
                end
            end
            core.AppendAll(statements, initializerStatements)
            local visited = self:Visitor():VisitSlice(core.Slice(body.statements.nodes, statementOffset))
            core.AppendAll(statements, visited)
        end
    else
        if needsSyntheticConstructor then
            -- Add a synthetic `super` call:
            --
            --  super(...arguments);
            --
            local superCall = self:Factory():NewExpressionStatement(
                self:Factory():NewCallExpression(
                    self:Factory():NewKeywordExpression(Kind.SuperKeyword),
                    nil, -- typeArguments
                    nil, -- questionDotToken
                    self:Factory():NewNodeList({
                        self:Factory():NewSpreadElement(self:Factory():NewIdentifier("arguments")),
                    }),
                    NodeFlags.None
                )
            )
            statements[#statements + 1] = superCall
        end
        core.AppendAll(statements, initializerStatements)
    end

    statements = self:EmitContext():EndAndMergeVariableEnvironment(statements)

    if core.Len(statements) == 0 and constructor == nil then
        return nil
    end

    local multiLine
    if constructor ~= nil and constructor.body ~= nil and
        core.Len(constructor.body:AsBlock().statements.nodes) >= core.Len(statements) then
        multiLine = constructor.body:AsBlock().multiLine
    else
        multiLine = core.Len(statements) > 0
    end

    local statementList = self:Factory():NewNodeList(statements)
    if constructor ~= nil and constructor.body ~= nil then
        statementList.loc = constructor.body:AsBlock().statements.loc
    else
        statementList.loc = core.NewTextRange(container:MemberList().loc:Pos(), container:MemberList().loc:End())
    end

    local block = self:Factory():NewBlock(statementList, multiLine)
    if constructor ~= nil and constructor.body ~= nil then
        block.loc = constructor.body.loc
    end
    return block
end

-- addPropertyOrClassStaticBlockStatements generates assignment statements for property initializers.
function classFieldsTransformer:addPropertyOrClassStaticBlockStatements(statements, properties, receiver)
    for _, property in ipairs(properties or {}) do
        if ast.IsStatic(property) and not self.shouldTransformPrivateElementsOrClassStaticBlocks then
            goto continue
        end
        do
            local statement = self:transformPropertyOrClassStaticBlock(property, receiver)
            if statement ~= nil then
                statements = core.Append(statements, statement)
            end
        end
        ::continue::
    end
    return statements
end

function classFieldsTransformer:transformPropertyOrClassStaticBlock(property, receiver)
    local expression
    if ast.IsClassStaticBlockDeclaration(property) then
        expression = self:setCurrentClassElementAnd(property, classFieldsTransformer.transformClassStaticBlockDeclaration, property)
    else
        expression = self:transformProperty(property:AsPropertyDeclaration(), receiver)
    end
    if expression == nil then
        return nil
    end

    local statement = self:Factory():NewExpressionStatement(expression)
    self:EmitContext():SetOriginal(statement, property)
    self:EmitContext():AddEmitFlags(statement, self:EmitContext():EmitFlags(property) & EF.EFNoComments)
    self:EmitContext():SetCommentRange(statement, property.loc)

    local propertyOriginalNode = self:EmitContext():MostOriginal(property)
    if ast.IsParameterDeclaration(propertyOriginalNode) then
        self:EmitContext():SetSourceMapRange(statement, propertyOriginalNode.loc)
        self:EmitContext():AddEmitFlags(statement, EF.EFNoComments)
    else
        self:EmitContext():SetSourceMapRange(statement, transformers.MoveRangePastModifiers(property))
    end

    -- `setOriginalNode` *copies* the `emitNode` from `property`, so now both
    -- `statement` and `expression` have a copy of the synthesized comments.
    -- Drop the comments from expression to avoid printing them twice.
    self:EmitContext():SetSyntheticLeadingComments(expression, nil)
    self:EmitContext():SetSyntheticTrailingComments(expression, nil)

    -- If the property was originally an auto-accessor, don't emit comments here since they will be attached to
    -- the synthesized getter.
    if ast.HasAccessorModifier(propertyOriginalNode) then
        self:EmitContext():AddEmitFlags(statement, EF.EFNoComments)
    end

    return statement
end

-- generateInitializedPropertyExpressionsOrClassStaticBlock generates assignment expressions for property initializers.
function classFieldsTransformer:generateInitializedPropertyExpressionsOrClassStaticBlock(propertiesOrClassStaticBlocks, receiver)
    local expressions
    for _, property in ipairs(propertiesOrClassStaticBlocks or {}) do
        local expression
        if ast.IsClassStaticBlockDeclaration(property) then
            expression = self:setCurrentClassElementAnd(property, classFieldsTransformer.transformClassStaticBlockDeclaration, property)
        else
            expression = self:transformProperty(property:AsPropertyDeclaration(), receiver)
        end
        if expression ~= nil then
            self:EmitContext():SetOriginalEx(expression, property, true)
            self:EmitContext():AssignCommentAndSourceMapRanges(expression, property)
            expressions = core.Append(expressions, expression)
        end
    end
    return expressions
end

-- transformProperty transforms a property initializer into an assignment expression.
function classFieldsTransformer:transformProperty(property, receiver)
    local savedCurrentClassElement = self.currentClassElement
    local transformed = self:transformPropertyWorker(property, receiver)
    if transformed ~= nil and ast.HasStaticModifier(property:AsNode()) then
        self:EmitContext():AddEmitFlags(transformed, EF.EFNoLexicalThis)
    end
    if transformed ~= nil and ast.HasStaticModifier(property:AsNode()) and
        self.lexicalEnvironment ~= nil and self.lexicalEnvironment.data ~= nil and self.lexicalEnvironment.data.facts ~= 0 then
        -- capture the lexical environment for the member
        self:EmitContext():SetOriginal(transformed, property:AsNode())
        self:EmitContext():SetSourceMapRange(transformed, self:EmitContext():SourceMapRange(property:Name()))
    end
    self.currentClassElement = savedCurrentClassElement
    return transformed
end

function classFieldsTransformer:transformPropertyWorker(property, receiver)
    -- We generate a name here in order to reuse the value cached by the relocated computed name expression (which uses the same generated name)
    local emitAssignment = not self.compilerOptions:GetUseDefineForClassFields()

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), property:AsNode(), self.isAnonymousClassNeedingAssignedName) then
        property = estransforms.transformNamedEvaluation(self:EmitContext(), property:AsNode(), false, ""):AsPropertyDeclaration()
    end

    local propertyName = property:Name()
    if ast.HasAccessorModifier(property:AsNode()) then
        propertyName = self:Factory():NewGeneratedPrivateNameForNodeEx(property:Name(), { flags = 0, prefix = "", suffix = "_accessor_storage" })
    elseif ast.IsComputedPropertyName(propertyName) and not transformers.IsSimpleInlineableExpression(propertyName:Expression()) then
        propertyName = self:Factory():UpdateComputedPropertyName(
            propertyName:AsComputedPropertyName(),
            self:Factory():NewGeneratedNameForNode(propertyName)
        )
    end

    if ast.HasStaticModifier(property:AsNode()) then
        self.currentClassElement = property:AsNode()
    end

    if ast.IsPrivateIdentifier(propertyName) and self:shouldTransformClassElementToWeakMap(property:AsNode()) then
        local info = self:accessPrivateIdentifier(propertyName)
        if info ~= nil then
            if info.kind == PrivateIdentifierKind.Field then
                if not info.isStatic then
                    return estransforms.createPrivateInstanceFieldInitializer(
                        self:Factory(),
                        receiver,
                        self:Visitor():VisitNode(property.initializer),
                        info.brandCheckIdentifier
                    )
                end
                return estransforms.createPrivateStaticFieldInitializer(
                    self:Factory(),
                    info.variableName,
                    self:Visitor():VisitNode(property.initializer)
                )
            end
            return nil
        else
            debug.Fail("Undeclared private name for property declaration.")
        end
    end

    if (ast.IsPrivateIdentifier(propertyName) or ast.HasStaticModifier(property:AsNode())) and property.initializer == nil then
        return nil
    end

    -- TODO: can we get rid of this original checking and better coordinate with runtimesyntax?
    if ast.HasAbstractModifier(self:EmitContext():MostOriginal(property:AsNode())) then
        return nil
    end

    local initializer = self:Visitor():VisitNode(property.initializer)
    local propertyOriginalNode = self:EmitContext():MostOriginal(property:AsNode())
    if ast.IsParameterPropertyDeclaration(propertyOriginalNode, propertyOriginalNode.parent) and ast.IsIdentifier(propertyName) then
        -- A parameter-property declaration always overrides the initializer. The only time a parameter-property
        -- declaration *should* have an initializer is when decorators have added initializers that need to run before
        -- any other initializer
        local localName = propertyName:Clone(self:Factory())
        if initializer ~= nil then
            -- unwrap `(__runInitializers(this, _instanceExtraInitializers), void 0)`
            if ast.IsParenthesizedExpression(initializer) and
                ast.IsCommaExpression(initializer:Expression()) and
                self:EmitContext():IsCallToHelper(initializer:Expression():AsBinaryExpression().left, "__runInitializers") and
                ast.IsVoidExpression(initializer:Expression():AsBinaryExpression().right) and
                ast.IsNumericLiteral(initializer:Expression():AsBinaryExpression().right:Expression()) then
                initializer = initializer:Expression():AsBinaryExpression().left
            end
            initializer = self:Factory():InlineExpressions({ initializer, localName })
        else
            initializer = localName
        end
        self:EmitContext():AddEmitFlags(propertyName, EF.EFNoComments | EF.EFNoSourceMap)
        self:EmitContext():SetSourceMapRange(localName, propertyOriginalNode:Name().loc)
        self:EmitContext():AddEmitFlags(localName, EF.EFNoComments)
    elseif initializer == nil then
        initializer = self:Factory():NewVoidZeroExpression()
    end

    if emitAssignment or ast.IsPrivateIdentifier(propertyName) then
        local memberAccess = estransforms.createMemberAccessForPropertyName(self:Factory(), self:EmitContext(), receiver, propertyName, propertyName)
        self:EmitContext():AddEmitFlags(memberAccess, EF.EFNoLeadingComments)
        return self:Factory():NewAssignmentExpression(memberAccess, initializer)
    end

    -- useDefineForClassFields: Object.defineProperty
    local name
    if ast.IsComputedPropertyName(propertyName) then
        name = propertyName:Expression()
    elseif ast.IsIdentifier(propertyName) then
        name = self:Factory():NewStringLiteral(propertyName:Text(), ast.TokenFlags.None)
    else
        name = propertyName
    end
    local descriptor = self:Factory():NewObjectLiteralExpression(self:Factory():NewNodeList({
        self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("enumerable"), nil, nil, self:Factory():NewTrueExpression()),
        self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("configurable"), nil, nil, self:Factory():NewTrueExpression()),
        self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("writable"), nil, nil, self:Factory():NewTrueExpression()),
        self:Factory():NewPropertyAssignment(nil, self:Factory():NewIdentifier("value"), nil, nil, initializer),
    }), true)
    return self:Factory():NewObjectDefinePropertyCall(receiver, name, descriptor)
end

-- addInstanceMethodStatements generates brand-check initializer for private methods.
function classFieldsTransformer:addInstanceMethodStatements(statements, methods, receiver)
    if not self.shouldTransformPrivateElementsOrClassStaticBlocks or core.Len(methods) == 0 then
        return statements
    end

    local env = self:getPrivateIdentifierEnvironment()
    local weakSetName = env.data.weakSetName
    debug.Assert(weakSetName ~= nil, "weakSetName should be set in private identifier environment")

    return core.Append(
        statements,
        self:Factory():NewExpressionStatement(
            estransforms.createPrivateInstanceMethodInitializer(self:Factory(), receiver, weakSetName)
        )
    )
end

function classFieldsTransformer:visitInvalidSuperProperty(node)
    if ast.IsPropertyAccessExpression(node) then
        return self:Factory():UpdatePropertyAccessExpression(
            node:AsPropertyAccessExpression(),
            self:Factory():NewVoidZeroExpression(),
            nil,
            node:Name(),
            node.flags
        )
    end
    return self:Factory():UpdateElementAccessExpression(
        node:AsElementAccessExpression(),
        self:Factory():NewVoidZeroExpression(),
        nil,
        self:Visitor():VisitNode(node:AsElementAccessExpression().argumentExpression),
        node.flags
    )
end

-- getPropertyNameExpressionIfNeeded transforms a computed property name, then either returns an expression
-- which caches the value of the result or the expression itself if the value is either unused or safe to
-- inline into multiple locations.
-- shouldHoist indicates whether the expression needs to be reused (i.e., for an initializer or a decorator).
function classFieldsTransformer:getPropertyNameExpressionIfNeeded(name, shouldHoist)
    if not ast.IsComputedPropertyName(name) then
        return nil
    end
    local cacheAssignment = estransforms.findComputedPropertyNameCacheAssignment(self:EmitContext(), name)
    -- Switch to outer lex env for computed property name expressions, matching
    -- Strada reference's onEmitNode behavior for ComputedPropertyName.
    local savedLexicalEnvironment = self.lexicalEnvironment
    local savedInsideComputedPropertyName = self.insideComputedPropertyName
    self.insideComputedPropertyName = true
    if self.lexicalEnvironment ~= nil and self.lexicalEnvironment.previous ~= nil then
        self.lexicalEnvironment = self.lexicalEnvironment.previous
    end
    local expression = self:Visitor():VisitNode(name:Expression())
    self.lexicalEnvironment = savedLexicalEnvironment
    self.insideComputedPropertyName = savedInsideComputedPropertyName
    local innerExpression = ast.SkipPartiallyEmittedExpressions(expression)
    local inlinable = transformers.IsSimpleInlineableExpression(innerExpression)
    local alreadyTransformed = cacheAssignment ~= nil or (ast.IsAssignmentExpression(innerExpression, true) and ast.IsIdentifier(innerExpression:AsBinaryExpression().left) and transformers.IsGeneratedIdentifier(self:EmitContext(), innerExpression:AsBinaryExpression().left))
    if not alreadyTransformed and not inlinable and shouldHoist then
        local generatedName = self:Factory():NewGeneratedNameForNode(name)
        if self:requiresBlockScopedVar() then
            self:EmitContext():AddLexicalDeclaration(generatedName)
        else
            self:EmitContext():AddVariableDeclaration(generatedName)
        end
        return self:Factory():NewAssignmentExpression(generatedName, expression)
    end
    if inlinable or ast.IsIdentifier(innerExpression) then
        return nil
    end
    return expression
end

function classFieldsTransformer:startClassLexicalEnvironment()
    self.lexicalEnvironment = { previous = self.lexicalEnvironment, data = nil, privateEnv = nil }
end

function classFieldsTransformer:endClassLexicalEnvironment()
    self.lexicalEnvironment = self.lexicalEnvironment.previous
end

function classFieldsTransformer:getClassLexicalEnvironment()
    debug.Assert(self.lexicalEnvironment ~= nil)
    if self.lexicalEnvironment.data == nil then
        self.lexicalEnvironment.data = estransforms.newClassLexicalEnvironment()
    end
    return self.lexicalEnvironment.data
end

function classFieldsTransformer:getPrivateIdentifierEnvironment()
    debug.Assert(self.lexicalEnvironment ~= nil)
    if self.lexicalEnvironment.privateEnv == nil then
        self.lexicalEnvironment.privateEnv = {
            data = { className = nil, weakSetName = nil },
            members = {},
            generatedIdentifiers = nil,
        }
    end
    return self.lexicalEnvironment.privateEnv
end

function classFieldsTransformer:addPendingExpressions(...)
    self.pendingExpressions = core.Append(self.pendingExpressions, ...)
end

function classFieldsTransformer:addPrivateIdentifierPropertyDeclarationToEnvironment(node, name)
    local lex = self:getClassLexicalEnvironment()
    local env = self:getPrivateIdentifierEnvironment()
    local isStatic = ast.HasStaticModifier(node)
    local previousInfo = self:getPrivateIdentifier(env, name)
    local isValid = not self:isReservedPrivateName(name) and previousInfo == nil

    if isStatic then
        local brandCheckIdentifier = lex.classThis
        if brandCheckIdentifier == nil then
            brandCheckIdentifier = lex.classConstructor
        end
        local variableName = self:createHoistedVariableForPrivateName(name, "")
        self:setPrivateIdentifier(env, name, estransforms.newPrivateIdentifierInfo({
            kind = PrivateIdentifierKind.Field,
            isStatic = true,
            brandCheckIdentifier = brandCheckIdentifier,
            variableName = variableName,
            isValid = isValid,
        }))
    else
        local weakMapName = self:createHoistedVariableForPrivateName(name, "")
        self:setPrivateIdentifier(env, name, estransforms.newPrivateIdentifierInfo({
            kind = PrivateIdentifierKind.Field,
            isStatic = false,
            brandCheckIdentifier = weakMapName,
            isValid = isValid,
        }))
        self:addPendingExpressions(
            self:Factory():NewAssignmentExpression(
                weakMapName,
                self:Factory():NewNewExpression(
                    self:Factory():NewIdentifier("WeakMap"),
                    nil, -- typeArguments
                    self:Factory():NewNodeList(nil)
                )
            )
        )
    end
end

function classFieldsTransformer:addPrivateIdentifierMethodToEnvironment(name, lex, env, isStatic, isValid)
    local methodName = self:createHoistedVariableForPrivateName(name, "")
    local brandCheckIdentifier
    if isStatic then
        brandCheckIdentifier = lex.classThis
        if brandCheckIdentifier == nil then
            brandCheckIdentifier = lex.classConstructor
        end
        debug.Assert(brandCheckIdentifier ~= nil, "classConstructor should be set in private identifier environment")
    else
        brandCheckIdentifier = env.data.weakSetName
    end
    self:setPrivateIdentifier(env, name, estransforms.newPrivateIdentifierInfo({
        kind = PrivateIdentifierKind.Method,
        methodName = methodName,
        brandCheckIdentifier = brandCheckIdentifier,
        isStatic = isStatic,
        isValid = isValid,
    }))
end

function classFieldsTransformer:addPrivateIdentifierGetAccessorToEnvironment(name, lex, env, isStatic, isValid, previousInfo)
    local getterName = self:createHoistedVariableForPrivateName(name, "_get")
    local brandCheckIdentifier
    if isStatic then
        brandCheckIdentifier = lex.classThis
        if brandCheckIdentifier == nil then
            brandCheckIdentifier = lex.classConstructor
        end
        debug.Assert(brandCheckIdentifier ~= nil, "classConstructor should be set in private identifier environment")
    else
        brandCheckIdentifier = env.data.weakSetName
        debug.Assert(brandCheckIdentifier ~= nil, "weakSetName should be set in private identifier environment")
    end

    if previousInfo ~= nil and previousInfo.kind == PrivateIdentifierKind.Accessor and previousInfo.isStatic == isStatic and previousInfo.getterName == nil then
        previousInfo.getterName = getterName
    else
        self:setPrivateIdentifier(env, name, estransforms.newPrivateIdentifierInfo({
            kind = PrivateIdentifierKind.Accessor,
            getterName = getterName,
            brandCheckIdentifier = brandCheckIdentifier,
            isStatic = isStatic,
            isValid = isValid,
        }))
    end
end

function classFieldsTransformer:addPrivateIdentifierSetAccessorToEnvironment(name, lex, env, isStatic, isValid, previousInfo)
    local setterName = self:createHoistedVariableForPrivateName(name, "_set")
    local brandCheckIdentifier
    if isStatic then
        brandCheckIdentifier = lex.classThis
        if brandCheckIdentifier == nil then
            brandCheckIdentifier = lex.classConstructor
        end
        debug.Assert(brandCheckIdentifier ~= nil, "classConstructor should be set in private identifier environment")
    else
        brandCheckIdentifier = env.data.weakSetName
        debug.Assert(brandCheckIdentifier ~= nil, "weakSetName should be set in private identifier environment")
    end

    if previousInfo ~= nil and previousInfo.kind == PrivateIdentifierKind.Accessor and previousInfo.isStatic == isStatic and previousInfo.setterName == nil then
        previousInfo.setterName = setterName
    else
        self:setPrivateIdentifier(env, name, estransforms.newPrivateIdentifierInfo({
            kind = PrivateIdentifierKind.Accessor,
            setterName = setterName,
            brandCheckIdentifier = brandCheckIdentifier,
            isStatic = isStatic,
            isValid = isValid,
        }))
    end
end

function classFieldsTransformer:addPrivateIdentifierAutoAccessorToEnvironment(node, name, lex, env, isStatic, isValid)
    local getterName = self:createHoistedVariableForPrivateName(name, "_get")
    local setterName = self:createHoistedVariableForPrivateName(name, "_set")
    local brandCheckIdentifier
    if isStatic then
        brandCheckIdentifier = lex.classThis
        if brandCheckIdentifier == nil then
            brandCheckIdentifier = lex.classConstructor
        end
        debug.Assert(brandCheckIdentifier ~= nil, "classConstructor should be set in private identifier environment")
    else
        brandCheckIdentifier = env.data.weakSetName
        debug.Assert(brandCheckIdentifier ~= nil, "weakSetName should be set in private identifier environment")
    end

    self:setPrivateIdentifier(env, name, estransforms.newPrivateIdentifierInfo({
        kind = PrivateIdentifierKind.Accessor,
        getterName = getterName,
        setterName = setterName,
        brandCheckIdentifier = brandCheckIdentifier,
        isStatic = isStatic,
        isValid = isValid,
    }))
end

function classFieldsTransformer:addPrivateIdentifierToEnvironment(node)
    local lex = self:getClassLexicalEnvironment()
    local env = self:getPrivateIdentifierEnvironment()
    local name = node:Name()
    local isStatic = ast.HasStaticModifier(node)
    local previousInfo = self:getPrivateIdentifier(env, name)
    local isValid = not self:isReservedPrivateName(name) and previousInfo == nil

    if ast.IsAutoAccessorPropertyDeclaration(node) then
        self:addPrivateIdentifierAutoAccessorToEnvironment(node, name, lex, env, isStatic, isValid)
    elseif ast.IsPropertyDeclaration(node) then
        self:addPrivateIdentifierPropertyDeclarationToEnvironment(node, name)
    elseif ast.IsMethodDeclaration(node) then
        self:addPrivateIdentifierMethodToEnvironment(name, lex, env, isStatic, isValid)
    elseif ast.IsGetAccessorDeclaration(node) then
        self:addPrivateIdentifierGetAccessorToEnvironment(name, lex, env, isStatic, isValid, previousInfo)
    elseif ast.IsSetAccessorDeclaration(node) then
        self:addPrivateIdentifierSetAccessorToEnvironment(name, lex, env, isStatic, isValid, previousInfo)
    end
end

function classFieldsTransformer:setPrivateIdentifier(env, name, info)
    if self:EmitContext():HasAutoGenerateInfo(name) then
        if env.generatedIdentifiers == nil then
            env.generatedIdentifiers = {}
        end
        env.generatedIdentifiers[self:EmitContext():GetNodeForGeneratedName(name)] = info
    else
        env.members[name:Text()] = info
    end
end

-- Returns info, ok.
function classFieldsTransformer:getPrivateIdentifier(env, name)
    if self:EmitContext():HasAutoGenerateInfo(name) then
        local info
        if env.generatedIdentifiers ~= nil then
            info = env.generatedIdentifiers[self:EmitContext():GetNodeForGeneratedName(name)]
        end
        return info, info ~= nil
    end
    local info = env.members[name:Text()]
    return info, info ~= nil
end

function classFieldsTransformer:createHoistedVariableForClass(nameText, node, suffix)
    local env = self:getPrivateIdentifierEnvironment()
    local identifier
    if env.data.className ~= nil then
        local prefix = "_" .. env.data.className:Text() .. "_"
        identifier = self:Factory():NewUniqueNameEx(prefix .. nameText, {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsReservedInNestedScopes,
            prefix = "",
            suffix = suffix,
        })
    else
        identifier = self:Factory():NewUniqueNameEx("_" .. nameText, {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsReservedInNestedScopes,
            prefix = "",
            suffix = suffix,
        })
    end
    if self:requiresBlockScopedVar() then
        self:EmitContext():AddLexicalDeclaration(identifier)
    else
        self:EmitContext():AddVariableDeclaration(identifier)
    end
    return identifier
end

function classFieldsTransformer:createHoistedVariableForClassFromNode(name, suffix)
    local env = self:getPrivateIdentifierEnvironment()
    local prefix
    if env.data.className ~= nil then
        prefix = "_" .. env.data.className:Text() .. "_"
    else
        prefix = "_"
    end
    local identifier = self:Factory():NewGeneratedNameForNodeEx(name, {
        flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsReservedInNestedScopes,
        prefix = prefix,
        suffix = suffix,
    })
    if self:requiresBlockScopedVar() then
        self:EmitContext():AddLexicalDeclaration(identifier)
    else
        self:EmitContext():AddVariableDeclaration(identifier)
    end
    return identifier
end

function classFieldsTransformer:createHoistedVariableForPrivateName(name, suffix)
    -- If the name is a generated identifier (e.g., auto-accessor backing field),
    -- use node-based name generation so the emitter can resolve the name properly.
    if self:EmitContext():HasAutoGenerateInfo(name) then
        return self:createHoistedVariableForClassFromNode(name, suffix)
    end
    local text = name:Text()
    if #text >= 1 and string.byte(text, 1) == 35 then -- '#'
        text = string.sub(text, 2) -- strip leading '#'
    end
    return self:createHoistedVariableForClass(text, name, suffix)
end

-- accessPrivateIdentifier accesses an already defined PrivateIdentifier in the current
-- PrivateIdentifierEnvironment.
function classFieldsTransformer:accessPrivateIdentifier(name)
    local env = self.lexicalEnvironment
    while env ~= nil do
        if env.privateEnv ~= nil then
            local info, ok = self:getPrivateIdentifier(env.privateEnv, name)
            if ok then
                if info.kind == PrivateIdentifierKind.Untransformed then
                    return nil
                end
                return info
            end
        end
        env = env.previous
    end
    return nil
end

function classFieldsTransformer:wrapPrivateIdentifierForDestructuringTarget(node)
    local prop = node:AsPropertyAccessExpression()
    local parameter = self:Factory():NewGeneratedNameForNode(node)
    local info = self:accessPrivateIdentifier(prop:Name())
    if info == nil then
        return self:Visitor():VisitEachChild(node)
    end
    local receiver = prop.expression
    -- We cannot copy `this` or `super` into the function because they will be bound
    -- differently inside the function.
    local isThisOrSuperProperty = prop.expression.kind == Kind.ThisKeyword or prop.expression.kind == Kind.SuperKeyword
    if isThisOrSuperProperty or not transformers.IsSimpleCopiableExpression(prop.expression) then
        receiver = self:Factory():NewTempVariableEx({
            flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes,
        })
        self:EmitContext():AddVariableDeclaration(receiver)
        self.pendingExpressions = core.Append(
            self.pendingExpressions,
            self:Factory():NewAssignmentExpression(receiver, self:Visitor():VisitNode(prop.expression))
        )
    end
    local assignExpr = self:createPrivateIdentifierAssignment(info, receiver, parameter, Kind.EqualsToken)
    return self:Factory():NewAssignmentTargetWrapper(parameter, assignExpr)
end

function classFieldsTransformer:visitAssignmentElement(node)
    -- 13.15.5.5 RS: IteratorDestructuringAssignmentEvaluation
    --   AssignmentElement : DestructuringAssignmentTarget Initializer?
    --     ...
    --     4. If |Initializer| is present and _value_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) and IsIdentifierRef of |DestructuringAssignmentTarget| are both *true*, then
    --           i. Let _v_ be ? NamedEvaluation of |Initializer| with argument _lref_.[[ReferencedName]].
    --     ...

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node, self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node, false, "")
    end
    if ast.IsAssignmentExpression(node, true) then
        local left = self:visitDestructuringAssignmentTarget(node:AsBinaryExpression().left)
        local right = self:Visitor():VisitNode(node:AsBinaryExpression().right)
        return self:Factory():UpdateBinaryExpression(
            node:AsBinaryExpression(),
            nil,
            left,
            nil,
            node:AsBinaryExpression().operatorToken,
            right
        )
    end
    return self:visitDestructuringAssignmentTarget(node)
end

function classFieldsTransformer:visitAssignmentRestElement(node)
    local spread = node:AsSpreadElement()
    if ast.IsLeftHandSideExpression(spread.expression) then
        local expr = self:visitDestructuringAssignmentTarget(spread.expression)
        return self:Factory():UpdateSpreadElement(spread, expr)
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitArrayAssignmentElement(node)
    if ast.IsArrayBindingOrAssignmentElement(node) then
        if ast.IsSpreadElement(node) then
            return self:visitAssignmentRestElement(node)
        end
        if node.kind ~= Kind.OmittedExpression then
            return self:visitAssignmentElement(node)
        end
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitAssignmentProperty(node)
    -- AssignmentProperty : PropertyName `:` AssignmentElement
    -- AssignmentElement : DestructuringAssignmentTarget Initializer?

    -- 13.15.5.6 RS: KeyedDestructuringAssignmentEvaluation
    --   AssignmentElement : DestructuringAssignmentTarget Initializer?
    --     ...
    --     3. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousfunctionDefinition(|Initializer|) and IsIdentifierRef of |DestructuringAssignmentTarget| are both *true*, then
    --           i. Let _rhsValue_ be ? NamedEvaluation of |Initializer| with argument _lref_.[[ReferencedName]].
    --     ...

    local prop = node:AsPropertyAssignment()
    local name = self:Visitor():VisitNode(prop:Name())
    local init = prop.initializer
    if ast.IsAssignmentExpression(init, true) then
        local assignElem = self:visitAssignmentElement(init)
        return self:Factory():UpdatePropertyAssignment(prop, nil, name, nil, nil, assignElem)
    end
    if ast.IsLeftHandSideExpression(init) then
        local target = self:visitDestructuringAssignmentTarget(init)
        return self:Factory():UpdatePropertyAssignment(prop, nil, name, nil, nil, target)
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitShorthandAssignmentProperty(node)
    -- AssignmentProperty : IdentifierReference Initializer?

    -- 13.15.5.3 RS: PropertyDestructuringAssignmentEvaluation
    --   AssignmentProperty : IdentifierReference Initializer?
    --     ...
    --     4. If |Initializer?| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _P_.
    --     ...

    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node, self.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node, false, "")
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitAssignmentRestProperty(node)
    local spread = node:AsSpreadAssignment()
    if ast.IsLeftHandSideExpression(spread.expression) then
        local expr = self:visitDestructuringAssignmentTarget(spread.expression)
        return self:Factory():UpdateSpreadAssignment(spread, expr)
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitObjectAssignmentElement(node)
    debug.Assert(node ~= nil and ast.IsObjectBindingOrAssignmentElement(node))
    if ast.IsSpreadAssignment(node) then
        return self:visitAssignmentRestProperty(node)
    end
    if ast.IsShorthandPropertyAssignment(node) then
        return self:visitShorthandAssignmentProperty(node)
    end
    if ast.IsPropertyAssignment(node) then
        return self:visitAssignmentProperty(node)
    end
    return self:Visitor():VisitEachChild(node)
end

function classFieldsTransformer:visitAssignmentPattern(node)
    if ast.IsArrayLiteralExpression(node) then
        -- Transforms private names in destructuring assignment array bindings.
        -- Transforms SuperProperty assignments in destructuring assignment array bindings in static initializers.
        --
        -- Source:
        -- ([ this.#myProp ] = [ "hello" ]);
        --
        -- Transformation:
        -- [ { set value(x) { this.#myProp = x; } }.value ] = [ "hello" ];
        return self:Factory():UpdateArrayLiteralExpression(
            node:AsArrayLiteralExpression(),
            self.arrayAssignmentElementVisitor:VisitNodes(node:AsArrayLiteralExpression().elements),
            node:AsArrayLiteralExpression().multiLine
        )
    end
    -- Transforms private names in destructuring assignment object bindings.
    -- Transforms SuperProperty assignments in destructuring assignment object bindings in static initializers.
    --
    -- Source:
    -- ({ stringProperty: this.#myProp } = { stringProperty: "hello" });
    --
    -- Transformation:
    -- ({ stringProperty: { set value(x) { this.#myProp = x; } }.value }) = { stringProperty: "hello" };
    return self:Factory():UpdateObjectLiteralExpression(
        node:AsObjectLiteralExpression(),
        self.objectAssignmentElementVisitor:VisitNodes(node:AsObjectLiteralExpression().properties),
        node:AsObjectLiteralExpression().multiLine
    )
end

function estransforms.createPrivateStaticFieldInitializer(factory, variableName, initializer)
    if initializer == nil then
        initializer = factory:NewVoidZeroExpression()
    end
    return factory:NewAssignmentExpression(
        variableName,
        factory:NewObjectLiteralExpression(
            factory:NewNodeList({
                factory:NewPropertyAssignment(nil, factory:NewIdentifier("value"), nil, nil, initializer),
            }),
            false
        )
    )
end

function estransforms.createPrivateInstanceFieldInitializer(factory, receiver, initializer, weakMapName)
    if initializer == nil then
        initializer = factory:NewVoidZeroExpression()
    end
    return factory:NewMethodCall(weakMapName, factory:NewIdentifier("set"), { receiver, initializer })
end

function estransforms.createPrivateInstanceMethodInitializer(factory, receiver, weakSetName)
    return factory:NewMethodCall(weakSetName, factory:NewIdentifier("add"), { receiver })
end

function classFieldsTransformer:isReservedPrivateName(node)
    return not (ast.IsPrivateIdentifier(node) and self:EmitContext():HasAutoGenerateInfo(node)) and node:Text() == "#constructor"
end

function estransforms.isStaticPropertyDeclarationOrClassStaticBlock(node)
    return ast.IsClassStaticBlockDeclaration(node) or
        (ast.IsPropertyDeclaration(node) and ast.HasStaticModifier(node))
end

function classFieldsTransformer:getProperties(node, requireInitializer, isStatic)
    local result
    for _, member in ipairs(node:Members() or {}) do
        if ast.IsPropertyDeclaration(member) and
            (not requireInitializer or member:Initializer() ~= nil) and
            ast.HasStaticModifier(member) == isStatic then
            result = core.Append(result, member)
        end
    end
    return result
end

function classFieldsTransformer:getStaticPropertiesAndClassStaticBlock(node)
    local result
    for _, member in ipairs(node:Members() or {}) do
        if ast.IsClassStaticBlockDeclaration(member) or (ast.IsPropertyDeclaration(member) and ast.HasStaticModifier(member)) then
            result = core.Append(result, member)
        end
    end
    return result
end

-- classHasClassThisAssignment checks if a class has a static block that is a class-this assignment.
function estransforms.classHasClassThisAssignment(emitContext, node)
    for _, member in ipairs(node:Members() or {}) do
        if estransforms.isClassThisAssignmentBlock(emitContext, member) then
            return true
        end
    end
    return false
end

function estransforms.isNonStaticMethodOrAccessorWithPrivateName(member)
    return not ast.IsStatic(member) and
        (ast.IsMethodOrAccessor(member) or ast.IsAutoAccessorPropertyDeclaration(member)) and
        ast.IsPrivateIdentifier(member:Name())
end

function estransforms.createMemberAccessForPropertyName(factory, emitContext, receiver, name, location)
    if ast.IsComputedPropertyName(name) then
        local expression = factory:NewElementAccessExpression(receiver, nil, name:Expression(), NodeFlags.None)
        expression.loc = location.loc
        return expression
    end
    local expression
    if ast.IsIdentifier(name) or ast.IsPrivateIdentifier(name) then
        expression = factory:NewPropertyAccessExpression(receiver, nil, name, NodeFlags.None)
    else
        -- string or numeric literal
        expression = factory:NewElementAccessExpression(receiver, nil, name, NodeFlags.None)
    end
    emitContext:SetCommentRange(expression, name.loc)
    emitContext:SetSourceMapRange(expression, name.loc)
    emitContext:AddEmitFlags(expression, EF.EFNoNestedSourceMaps)
    return expression
end

-- Returns thisArg, target.
function classFieldsTransformer:createCallBinding(node)
    if ast.IsSuperProperty(node) then
        return self:Factory():NewThisExpression(), node
    end
    if ast.IsPropertyAccessExpression(node) then
        local expr = node:AsPropertyAccessExpression()
        if estransforms.shouldBeCapturedInTempVariable(expr.expression) then
            local thisArg = self:Factory():NewTempVariable()
            self:EmitContext():AddVariableDeclaration(thisArg)
            local target = self:Factory():NewPropertyAccessExpression(
                self:Factory():NewParenthesizedExpression( -- TODO: do we even need these?
                    self:Factory():NewAssignmentExpression(thisArg, expr.expression)
                ),
                nil,
                expr:Name(),
                NodeFlags.None
            )
            return thisArg, target
        end
        return expr.expression, node
    end
    local thisArg = self:Factory():NewVoidZeroExpression()
    local target = node
    return thisArg, target
end

function estransforms.shouldBeCapturedInTempVariable(node)
    local target = ast.SkipParentheses(node)
    local k = target.kind
    if k == Kind.Identifier or k == Kind.ThisKeyword or k == Kind.NumericLiteral or k == Kind.BigIntLiteral or k == Kind.StringLiteral then
        return false
    else
        return true
    end
end

function classFieldsTransformer:createAccessorPropertyGetRedirector(node, modifiers, name, receiver)
    local backingFieldName = self:Factory():NewGeneratedPrivateNameForNodeEx(node:Name(), { flags = 0, prefix = "", suffix = "_accessor_storage" })
    local returnExpr = self:Factory():NewPropertyAccessExpression(
        receiver,
        nil,
        backingFieldName,
        NodeFlags.None
    )
    local returnStmt = self:Factory():NewReturnStatement(returnExpr)
    local body = self:Factory():NewBlock(self:Factory():NewNodeList({ returnStmt }), false)
    return self:Factory():NewGetAccessorDeclaration(
        modifiers,
        name,
        nil, -- typeParameters
        self:Factory():NewNodeList({}),
        nil, -- returnType
        nil, -- fullSignature
        body
    )
end

function classFieldsTransformer:createAccessorPropertySetRedirector(node, modifiers, name, receiver)
    local backingFieldName = self:Factory():NewGeneratedPrivateNameForNodeEx(node:Name(), { flags = 0, prefix = "", suffix = "_accessor_storage" })
    local valueParam = self:Factory():NewParameterDeclaration(
        nil, -- modifiers
        nil, -- dotDotDotToken
        self:Factory():NewIdentifier("value"),
        nil, -- questionToken
        nil, -- typeNode
        nil -- initializer
    )
    local assignExpr = self:Factory():NewAssignmentExpression(
        self:Factory():NewPropertyAccessExpression(
            receiver,
            nil,
            backingFieldName,
            NodeFlags.None
        ),
        self:Factory():NewIdentifier("value")
    )
    local exprStmt = self:Factory():NewExpressionStatement(assignExpr)
    local body = self:Factory():NewBlock(self:Factory():NewNodeList({ exprStmt }), false)
    return self:Factory():NewSetAccessorDeclaration(
        modifiers,
        name,
        nil, -- typeParameters
        self:Factory():NewNodeList({ valueParam }),
        nil, -- returnType
        nil, -- fullSignature
        body
    )
end

-- flattenCommaList decomposes a comma expression tree into a sequence of expressions.
-- Returns a materialized array (Go: iter.Seq).
function estransforms.flattenCommaList(node)
    local result = {}
    estransforms.flattenCommaListWorker(node, function(e)
        result[#result + 1] = e
        return true
    end)
    return result
end

function estransforms.flattenCommaListWorker(node, yield)
    if ast.IsParenthesizedExpression(node) and ast.NodeIsSynthesized(node) then
        return estransforms.flattenCommaListWorker(node:Expression(), yield)
    elseif ast.IsCommaExpression(node:AsNode()) then
        return estransforms.flattenCommaListWorker(node:AsBinaryExpression().left, yield) and
            estransforms.flattenCommaListWorker(node:AsBinaryExpression().right, yield)
    else
        return yield(node)
    end
end

function estransforms.findComputedPropertyNameCacheAssignment(emitContext, name)
    local node = name:Expression()
    while true do
        node = ast.SkipOuterExpressions(node, 0)
        if ast.IsBinaryExpression(node) and node:AsBinaryExpression().operatorToken.kind == Kind.CommaToken then
            node = node:AsBinaryExpression().right
        elseif ast.IsAssignmentExpression(node, true) and ast.IsIdentifier(node:AsBinaryExpression().left) then
            return node:AsBinaryExpression()
        else
            break
        end
    end
    return nil
end

function estransforms.expandPreOrPostfixIncrementOrDecrementExpression(factory, emitContext, node, expression, resultVariable)
    local operator
    local operand
    if ast.IsPrefixUnaryExpression(node) then
        operator = node:AsPrefixUnaryExpression().operator
        operand = node:AsPrefixUnaryExpression().operand
    else
        operator = node:AsPostfixUnaryExpression().operator
        operand = node:AsPostfixUnaryExpression().operand
    end

    local temp = factory:NewTempVariable()
    emitContext:AddVariableDeclaration(temp)
    expression = factory:NewAssignmentExpression(temp, expression)
    expression.loc = operand.loc

    local operation
    if ast.IsPrefixUnaryExpression(node) then
        operation = factory:NewPrefixUnaryExpression(operator, temp)
    else
        operation = factory:NewPostfixUnaryExpression(temp, operator)
    end
    operation.loc = node.loc

    if resultVariable ~= nil then
        operation = factory:NewAssignmentExpression(resultVariable, operation)
        operation.loc = node.loc
    end

    expression = factory:NewCommaExpression(expression, operation)
    expression.loc = node.loc

    if ast.IsPostfixUnaryExpression(node) then
        expression = factory:NewCommaExpression(expression, temp)
        expression.loc = node.loc
    end

    return expression
end
