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
local SF = ast.SubtreeFacts
local OEK = ast.OuterExpressionKinds
local EF = printer.EmitFlags

-- Class/Decorator evaluation order, as it pertains to this transformer:
--
-- 1. Class decorators are evaluated outside of the private name scope of the class.
--    - 15.8.20 RS: BindingClassDeclarationEvaluation
--    - 15.8.21 RS: Evaluation
--    - 8.3.5 RS: NamedEvaluation
-- 2. ClassHeritage clause is evaluated outside of the private name scope of the class.
--    - 15.8.19 RS: ClassDefinitionEvaluation, Step 8.c.
-- 3. The name of the class is assigned.
-- 4. For each member:
--    a. Member Decorators are evaluated.
--       - 15.8.19 RS: ClassDefinitionEvaluation, Step 23.
--       - Probably 15.7.13 RS: ClassElementEvaluation, but it's missing from spec text.
--    b. Computed Property name is evaluated
--       - 15.8.19 RS: ClassDefinitionEvaluation, Step 23.
--       - 15.8.15 RS: ClassFieldDefinitionEvaluation, Step 1.
--       - 15.4.5 RS: MethodDefinitionEvaluation, Step 1.
-- 5. Static non-field (method/getter/setter/auto-accessor) element decorators are applied
-- 6. Non-static non-field (method/getter/setter/auto-accessor) element decorators are applied
-- 7. Static field (excl. auto-accessor) element decorators are applied
-- 8. Non-static field (excl. auto-accessor) element decorators are applied
-- 9. Class decorators are applied
-- 10. Class binding is initialized
-- 11. Static method extra initializers are evaluated
-- 12. Static fields are initialized (incl. extra initializers) and static blocks are evaluated
-- 13. Class extra initializers are evaluated
--
-- Class constructor evaluation order, as it pertains to this transformer:
--
-- 1. Instance method extra initializers are evaluated
-- 2. For each instance field/auto-accessor:
--    a. The field is initialized and defined on the instance.
--    b. Extra initializers for the field are evaluated.

-- lexicalEntryKind discriminates the kind of lexical scope entry.
estransforms.lexicalEntryKind = {
    Class = 0,
    ClassElement = 1,
    Name = 2,
    Other = 3,
}
local lexicalEntryKind = estransforms.lexicalEntryKind

-- lexicalEntry represents a single entry in the lexical scope stack used to track
-- nested class declarations and their state during transformation.
-- Fields: kind, next, classInfoData, savedPendingExpressions, classThisData, classSuperData, depth.
local function newLexicalEntry(kind, next_)
    return {
        kind = kind,
        next = next_,
        classInfoData = nil,
        savedPendingExpressions = nil,
        classThisData = nil,
        classSuperData = nil,
        depth = 0,
    }
end

-- memberInfo stores decoration-related data for a single class element:
--   { memberDecoratorsName, memberInitializersName, memberExtraInitializersName, memberDescriptorName }
--
-- classInfo stores all transformation data for a single decorated class:
--   { class, classDecoratorsName, classDescriptorName, classExtraInitializersName, classThis, classSuper,
--     metadataReference, memberInfos (collections.OrderedMap node -> memberInfo),
--     instanceMethodExtraInitializersName, staticMethodExtraInitializersName,
--     staticNonFieldDecorationStatements, nonStaticNonFieldDecorationStatements,
--     staticFieldDecorationStatements, nonStaticFieldDecorationStatements,
--     hasStaticInitializers, hasNonAmbientInstanceFields, hasStaticPrivateClassElements,
--     pendingStaticInitializers, pendingInstanceInitializers }

local esDecoratorTransformer = transformers.NewTransformerType()
estransforms.esDecoratorTransformer = esDecoratorTransformer

function estransforms.newESDecoratorTransformer(opts)
    -- When experimentalDecorators is set, the legacy decorator transformer handles all
    -- decorators. When targeting ESNext with useDefineForClassFields, there's nothing to
    -- transform. In either case every node would be returned unchanged, so skip entirely.
    if core.Tristate_IsTrue(opts.compilerOptions.experimentalDecorators) or
        (opts.compilerOptions:GetEmitScriptTarget() >= core.ScriptTarget.ESNext and opts.compilerOptions:GetUseDefineForClassFields()) then
        return nil
    end
    local tx = setmetatable({
        compilerOptions = opts.compilerOptions,
        top = nil,
        classInfoStack = nil,
        classThis = nil,
        classSuper = nil,
        pendingExpressions = nil,
        outerThis = nil,
        shouldTransformPrivateStaticElementsInFile = false,
    }, esDecoratorTransformer)
    local result = tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
    local ec = tx:EmitContext()
    tx.outerThisVisitor = ec:NewNodeVisitor(function(n) return tx:outerThisVisit(n) end)
    tx.discardedVisitor = ec:NewNodeVisitor(function(n) return tx:discardedValueVisit(n) end)
    tx.modifierVisitor = ec:NewNodeVisitor(function(n) return tx:modifierVisitorVisit(n) end)
    tx.exportStrippingModifierVisitor = ec:NewNodeVisitor(function(n) return tx:exportStrippingModifierVisit(n) end)
    tx.classElementVisitor = ec:NewNodeVisitor(function(n) return tx:classElementVisitorVisit(n) end)
    tx.nonConstructorClassElementVisitor = ec:NewNodeVisitor(function(n) return tx:nonConstructorClassElementVisit(n) end)
    tx.constructorClassElementVisitor = ec:NewNodeVisitor(function(n) return tx:constructorClassElementVisit(n) end)
    tx.arrayAssignmentVisitor = ec:NewNodeVisitor(function(n) return tx:visitArrayAssignmentElement(n) end)
    tx.objectAssignmentVisitor = ec:NewNodeVisitor(function(n) return tx:visitObjectAssignmentElement(n) end)
    tx.staticOnlyModifierVisitor = ec:NewNodeVisitor(function(node)
        if node.kind == Kind.StaticKeyword then
            return node
        end
        return nil
    end)
    tx.asyncOnlyModifierVisitor = ec:NewNodeVisitor(function(node)
        if node.kind == Kind.AsyncKeyword then
            return node
        end
        return nil
    end)
    tx.accessorStrippingModifierVisitor = ec:NewNodeVisitor(function(node)
        if node.kind == Kind.AccessorKeyword then
            return nil
        end
        return node
    end)
    return result
end

function esDecoratorTransformer:updateState()
    self.classInfoStack = nil
    self.classThis = nil
    self.classSuper = nil
    if self.top == nil then
        return
    end
    local k = self.top.kind
    if k == lexicalEntryKind.Class then
        self.classInfoStack = self.top.classInfoData
    elseif k == lexicalEntryKind.ClassElement then
        self.classInfoStack = self.top.next.classInfoData
        self.classThis = self.top.classThisData
        self.classSuper = self.top.classSuperData
    elseif k == lexicalEntryKind.Name then
        local grandparent = self.top.next.next.next
        if grandparent ~= nil and grandparent.kind == lexicalEntryKind.ClassElement then
            self.classInfoStack = grandparent.next.classInfoData
            self.classThis = grandparent.classThisData
            self.classSuper = grandparent.classSuperData
        end
    end
end

local function topKind(tx)
    if tx.top == nil then
        return nil
    end
    return tx.top.kind
end

function esDecoratorTransformer:enterClass(ci)
    local entry = newLexicalEntry(lexicalEntryKind.Class, self.top)
    entry.classInfoData = ci
    entry.savedPendingExpressions = self.pendingExpressions
    self.top = entry
    self.pendingExpressions = nil
    self:updateState()
end

function esDecoratorTransformer:exitClass()
    debug.Assert(self.top ~= nil and self.top.kind == lexicalEntryKind.Class, "Incorrect value for top.kind. Expected top.kind to be 'class' but got '", topKind(self), "' instead.")
    self.pendingExpressions = self.top.savedPendingExpressions
    self.top = self.top.next
    self:updateState()
end

function esDecoratorTransformer:enterClassElement(node)
    debug.Assert(self.top ~= nil and self.top.kind == lexicalEntryKind.Class, "Incorrect value for top.kind. Expected top.kind to be 'class' but got '", topKind(self), "' instead.")
    self.top = newLexicalEntry(lexicalEntryKind.ClassElement, self.top)
    if ast.IsClassStaticBlockDeclaration(node) or ast.IsPropertyDeclaration(node) and ast.HasStaticModifier(node) then
        if self.top.next.classInfoData ~= nil then
            self.top.classThisData = self.top.next.classInfoData.classThis
            self.top.classSuperData = self.top.next.classInfoData.classSuper
        end
    end
    self:updateState()
end

function esDecoratorTransformer:exitClassElement()
    debug.Assert(self.top ~= nil and self.top.kind == lexicalEntryKind.ClassElement, "Incorrect value for top.kind. Expected top.kind to be 'class-element' but got '", topKind(self), "' instead.")
    debug.Assert(self.top.next ~= nil and self.top.next.kind == lexicalEntryKind.Class, "Incorrect value for top.next.kind. Expected top.next.kind to be 'class' but got '", self.top.next and self.top.next.kind, "' instead.")
    self.top = self.top.next
    self:updateState()
end

function esDecoratorTransformer:enterName()
    debug.Assert(self.top ~= nil and self.top.kind == lexicalEntryKind.ClassElement, "Incorrect value for top.kind. Expected top.kind to be 'class-element' but got '", topKind(self), "' instead.")
    self.top = newLexicalEntry(lexicalEntryKind.Name, self.top)
    self:updateState()
end

function esDecoratorTransformer:exitName()
    debug.Assert(self.top ~= nil and self.top.kind == lexicalEntryKind.Name, "Incorrect value for top.kind. Expected top.kind to be 'name' but got '", topKind(self), "' instead.")
    self.top = self.top.next
    self:updateState()
end

function esDecoratorTransformer:enterOther()
    if self.top ~= nil and self.top.kind == lexicalEntryKind.Other then
        debug.Assert(core.Len(self.pendingExpressions) == 0)
        self.top.depth = self.top.depth + 1
    else
        local entry = newLexicalEntry(lexicalEntryKind.Other, self.top)
        entry.savedPendingExpressions = self.pendingExpressions
        self.top = entry
        self.pendingExpressions = nil
        self:updateState()
    end
end

function esDecoratorTransformer:exitOther()
    debug.Assert(self.top ~= nil and self.top.kind == lexicalEntryKind.Other, "Incorrect value for top.kind. Expected top.kind to be 'other' but got '", topKind(self), "' instead.")
    if self.top.depth > 0 then
        debug.Assert(core.Len(self.pendingExpressions) == 0)
        self.top.depth = self.top.depth - 1
    else
        self.pendingExpressions = self.top.savedPendingExpressions
        self.top = self.top.next
        self:updateState()
    end
end

function esDecoratorTransformer:visitSourceFile(node)
    self.top = nil
    self.shouldTransformPrivateStaticElementsInFile = false
    local visited = self:Visitor():VisitEachChild(node:AsNode())
    self:EmitContext():AddEmitHelper(visited, table.unpack(self:EmitContext():ReadEmitHelpers() or {}))
    if self.shouldTransformPrivateStaticElementsInFile then
        self:EmitContext():AddEmitFlags(visited, EF.EFTransformPrivateStaticElements)
        self.shouldTransformPrivateStaticElementsInFile = false
    end
    return visited
end

function esDecoratorTransformer:outerThisVisit(n)
    if n:SubtreeFacts() & SF.SubtreeContainsLexicalThis == 0 and n.kind ~= Kind.ThisKeyword then
        return n
    end
    if n.kind == Kind.ThisKeyword then
        if self.outerThis == nil then
            self.outerThis = self:Factory():NewUniqueNameEx("_outerThis", {
                flags = printer.GeneratedIdentifierFlagsOptimistic,
            })
        end
        return self.outerThis
    end
    return self.outerThisVisitor:VisitEachChild(n)
end

function esDecoratorTransformer:shouldVisitNode(node)
    return node:SubtreeFacts() & SF.SubtreeContainsDecorators ~= 0 or
        (self.classThis ~= nil and node:SubtreeFacts() & SF.SubtreeContainsLexicalThis ~= 0) or
        (self.classThis ~= nil and self.classSuper ~= nil and node:SubtreeFacts() & SF.SubtreeContainsLexicalSuper ~= 0)
end

function esDecoratorTransformer:visit(node)
    if node.kind == Kind.SourceFile then
        return self:visitSourceFile(node:AsSourceFile())
    end
    if not self:shouldVisitNode(node) then
        return node
    end
    local k = node.kind
    if k == Kind.Decorator then
        -- Decorators are elided. In Strada, a separate `modifierVisitor` drops decorators
        -- before they reach `visitor` via visitEachChild. Here, `visit` serves as both
        -- visitors, so decorators from modifier lists reach it directly.
        return nil
    elseif k == Kind.ClassDeclaration then
        return self:visitClassDeclaration(node:AsClassDeclaration())
    elseif k == Kind.ClassExpression then
        return self:visitClassExpression(node:AsClassExpression())
    elseif k == Kind.Constructor or k == Kind.PropertyDeclaration or k == Kind.ClassStaticBlockDeclaration then
        debug.Fail("Not supported outside of a class. Use 'classElementVisitor' instead.")
        return nil
    elseif k == Kind.Parameter then
        return self:visitParameterDeclaration(node:AsParameterDeclaration())
    -- Support NamedEvaluation to ensure the correct class name for class expressions.
    elseif k == Kind.BinaryExpression then
        return self:visitBinaryExpression(node, false)
    elseif k == Kind.PropertyAssignment or k == Kind.VariableDeclaration or k == Kind.BindingElement then
        return self:visitNamedEvaluationSite(node, node:Initializer())
    elseif k == Kind.ExportAssignment then
        return self:visitExportAssignment(node)
    elseif k == Kind.ThisKeyword then
        return self:visitThisExpression(node)
    elseif k == Kind.ForStatement then
        return self:visitForStatement(node)
    elseif k == Kind.ExpressionStatement then
        return self:visitExpressionStatement(node)
    elseif k == Kind.ParenthesizedExpression then
        return self:visitParenthesizedExpression(node, false)
    elseif k == Kind.PartiallyEmittedExpression then
        return self:visitPartiallyEmittedExpression(node, false)
    elseif k == Kind.CallExpression then
        return self:visitCallExpression(node)
    elseif k == Kind.TaggedTemplateExpression then
        return self:visitTaggedTemplateExpression(node)
    elseif k == Kind.PrefixUnaryExpression or k == Kind.PostfixUnaryExpression then
        return self:visitPreOrPostfixUnaryExpression(node, false)
    elseif k == Kind.PropertyAccessExpression then
        return self:visitPropertyAccessExpression(node)
    elseif k == Kind.ElementAccessExpression then
        return self:visitElementAccessExpression(node)
    elseif k == Kind.ComputedPropertyName then
        return self:visitComputedPropertyName(node)
    elseif k == Kind.MethodDeclaration or
        k == Kind.SetAccessor or
        k == Kind.GetAccessor or
        k == Kind.FunctionExpression or
        k == Kind.FunctionDeclaration then
        self:enterOther()
        local result = self:Visitor():VisitEachChild(node)
        self:exitOther()
        return result
    else
        return self:Visitor():VisitEachChild(node)
    end
end

function esDecoratorTransformer:modifierVisitorVisit(node)
    if node.kind == Kind.Decorator then
        return nil
    end
    return node
end

function esDecoratorTransformer:classElementVisitorVisit(node)
    local k = node.kind
    if k == Kind.Constructor then
        return self:visitConstructorDeclaration(node)
    elseif k == Kind.MethodDeclaration then
        return self:visitMethodDeclaration(node)
    elseif k == Kind.GetAccessor then
        return self:visitGetAccessorDeclaration(node)
    elseif k == Kind.SetAccessor then
        return self:visitSetAccessorDeclaration(node)
    elseif k == Kind.PropertyDeclaration then
        return self:visitPropertyDeclaration(node)
    elseif k == Kind.ClassStaticBlockDeclaration then
        return self:visitClassStaticBlockDeclaration(node)
    else
        return self:visit(node)
    end
end

function esDecoratorTransformer:discardedValueVisit(node)
    local k = node.kind
    if k == Kind.PrefixUnaryExpression or k == Kind.PostfixUnaryExpression then
        return self:visitPreOrPostfixUnaryExpression(node, true)
    elseif k == Kind.BinaryExpression then
        return self:visitBinaryExpression(node, true)
    elseif k == Kind.ParenthesizedExpression then
        return self:visitParenthesizedExpression(node, true)
    elseif k == Kind.PartiallyEmittedExpression then
        return self:visitPartiallyEmittedExpression(node, true)
    else
        return self:visit(node)
    end
end

function esDecoratorTransformer:nonConstructorClassElementVisit(node)
    if ast.IsConstructorDeclaration(node) then
        return node -- skip constructors in pass 1
    end
    return self:classElementVisitorVisit(node)
end

function esDecoratorTransformer:constructorClassElementVisit(node)
    if ast.IsConstructorDeclaration(node) then
        return self:classElementVisitorVisit(node)
    end
    return node
end

function esDecoratorTransformer:exportStrippingModifierVisit(node)
    if node.kind == Kind.ExportKeyword then
        return nil
    end
    return self:modifierVisitorVisit(node)
end

function estransforms.getHelperVariableName(ec, node)
    local name = node:Name()
    local declarationName = ""
    if name ~= nil and ast.IsIdentifier(name) and not transformers.IsGeneratedIdentifier(ec, name) then
        declarationName = name:Text()
    elseif name ~= nil and ast.IsPrivateIdentifier(name) and not ec:HasAutoGenerateInfo(name) then
        local text = name:Text()
        if #text > 1 then
            declarationName = string.sub(text, 2)
        end
    elseif name ~= nil and ast.IsStringLiteral(name) and scanner.IsIdentifierText(name:Text(), core.LanguageVariant.Standard) then
        declarationName = name:Text()
    elseif ast.IsClassLike(node) then
        declarationName = "class"
    else
        declarationName = "member"
    end

    if ast.IsGetAccessorDeclaration(node) then
        declarationName = "get_" .. declarationName
    end
    if ast.IsSetAccessorDeclaration(node) then
        declarationName = "set_" .. declarationName
    end
    if name ~= nil and ast.IsPrivateIdentifier(name) then
        declarationName = "private_" .. declarationName
    end
    if ast.IsStatic(node) then
        declarationName = "static_" .. declarationName
    end
    return "_" .. declarationName
end

function esDecoratorTransformer:createHelperVariable(node, suffix)
    return self:Factory():NewUniqueNameEx(
        estransforms.getHelperVariableName(self:EmitContext(), node) .. "_" .. suffix,
        { flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsReservedInNestedScopes }
    )
end

function esDecoratorTransformer:createLet(name, initializer)
    return self:Factory():NewVariableStatement(
        nil,
        self:Factory():NewVariableDeclarationList(
            self:Factory():NewNodeList({
                self:Factory():NewVariableDeclaration(name, nil, nil, initializer),
            }),
            NodeFlags.Let
        )
    )
end

function esDecoratorTransformer:createClassInfo(node)
    local f = self:Factory()
    local ci = {
        class = node,
        classDecoratorsName = nil,
        classDescriptorName = nil,
        classExtraInitializersName = nil,
        classThis = nil,
        classSuper = nil,
        metadataReference = f:NewUniqueNameEx("_metadata", {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
        }),
        memberInfos = collections.NewOrderedMap(),
        instanceMethodExtraInitializersName = nil,
        staticMethodExtraInitializersName = nil,
        staticNonFieldDecorationStatements = nil,
        nonStaticNonFieldDecorationStatements = nil,
        staticFieldDecorationStatements = nil,
        nonStaticFieldDecorationStatements = nil,
        hasStaticInitializers = false,
        hasNonAmbientInstanceFields = false,
        hasStaticPrivateClassElements = false,
        pendingStaticInitializers = nil,
        pendingInstanceInitializers = nil,
    }

    -- Before visiting we perform a first pass to collect information we'll need
    -- as we descend.

    -- If the class itself is decorated, create a _classThis binding
    if ast.NodeIsDecorated(false, node, nil, nil) then
        local needsUniqueClassThis = core.Some(node:Members(), function(member)
            return (ast.IsPrivateIdentifierClassElementDeclaration(member) or ast.IsAutoAccessorPropertyDeclaration(member)) and ast.HasStaticModifier(member)
        end)
        -- We do not mark _classThis as FileLevel if it may be reused by class private fields, which requires the
        -- ability access the captured `_classThis` of outer scopes.
        local flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel
        if needsUniqueClassThis then
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsReservedInNestedScopes
        end
        ci.classThis = f:NewUniqueNameEx("_classThis", { flags = flags })
    end

    for _, member in ipairs(node:Members() or {}) do
        if ast.IsMethodOrAccessor(member) and ast.NodeOrChildIsDecorated(false, member, node, nil) then
            if ast.HasStaticModifier(member) then
                if ci.staticMethodExtraInitializersName == nil then
                    ci.staticMethodExtraInitializersName = f:NewUniqueNameEx("_staticExtraInitializers", {
                        flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
                    })
                    local renamedClassThis
                    if ci.classThis ~= nil then
                        renamedClassThis = ci.classThis
                    else
                        renamedClassThis = f:NewThisExpression()
                    end
                    local initializer = f:NewRunInitializersHelper(renamedClassThis, ci.staticMethodExtraInitializersName, nil)
                    local nameRange = node:Name()
                    if nameRange ~= nil then
                        self:EmitContext():SetSourceMapRange(initializer, nameRange.loc)
                    else
                        self:EmitContext():SetSourceMapRange(initializer, transformers.MoveRangePastDecorators(node))
                    end
                    ci.pendingStaticInitializers = core.Append(ci.pendingStaticInitializers, initializer)
                end
            else
                if ci.instanceMethodExtraInitializersName == nil then
                    ci.instanceMethodExtraInitializersName = f:NewUniqueNameEx("_instanceExtraInitializers", {
                        flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
                    })
                    local initializer = f:NewRunInitializersHelper(f:NewThisExpression(), ci.instanceMethodExtraInitializersName, nil)
                    local nameRange = node:Name()
                    if nameRange ~= nil then
                        self:EmitContext():SetSourceMapRange(initializer, nameRange.loc)
                    else
                        self:EmitContext():SetSourceMapRange(initializer, transformers.MoveRangePastDecorators(node))
                    end
                    ci.pendingInstanceInitializers = core.Append(ci.pendingInstanceInitializers, initializer)
                end
            end
        end

        if ast.IsClassStaticBlockDeclaration(member) then
            if not estransforms.isClassNamedEvaluationHelperBlock(self:EmitContext(), member) then
                ci.hasStaticInitializers = true
            end
        elseif ast.IsPropertyDeclaration(member) then
            if ast.HasStaticModifier(member) then
                ci.hasStaticInitializers = ci.hasStaticInitializers or member:Initializer() ~= nil or ast.HasDecorators(member)
            else
                ci.hasNonAmbientInstanceFields = ci.hasNonAmbientInstanceFields or not ast.HasSyntacticModifier(member, ast.ModifierFlags.Ambient)
            end
        end

        if (ast.IsPrivateIdentifierClassElementDeclaration(member) or ast.IsAutoAccessorPropertyDeclaration(member)) and ast.HasStaticModifier(member) then
            ci.hasStaticPrivateClassElements = true
        end

        -- exit early if possible
        if ci.staticMethodExtraInitializersName ~= nil and
            ci.instanceMethodExtraInitializersName ~= nil and
            ci.hasStaticInitializers and
            ci.hasNonAmbientInstanceFields and
            ci.hasStaticPrivateClassElements then
            break
        end
    end

    return ci
end

local function appendAll(dst, src)
    for _, v in ipairs(src or {}) do
        dst[#dst + 1] = v
    end
    return dst
end

function esDecoratorTransformer:transformClassLike(node)
    local f = self:Factory()
    local ec = self:EmitContext()

    ec:StartVariableEnvironment()

    -- When a class has class decorators we end up transforming it into a statement that would otherwise give it an
    -- assigned name. If the class doesn't have an assigned name, we'll give it an assigned name of `""`.
    if not estransforms.classHasDeclaredOrExplicitlyAssignedName(ec, node) and ast.ClassOrConstructorParameterIsDecorated(false, node) then
        node = estransforms.injectClassNamedEvaluationHelperBlockIfMissing(ec, node, f:NewStringLiteral("", 0), nil)
    end

    local classReference = f:GetLocalNameEx(node, {})
    local ci = self:createClassInfo(node)
    local classDefinitionStatements = {}
    local leadingBlockStatements = {}
    local trailingBlockStatements = {}
    local syntheticConstructor
    local heritageClauses
    local shouldTransformPrivateStaticElementsInClass = false

    -- 1. Class decorators are evaluated outside the private name scope of the class.
    --
    -- - Since class decorators don't have privileged access to private names defined inside the class,
    --   they must be evaluated outside of the class body.
    -- - Since a class decorator can replace the class constructor, we must define a variable to keep track
    --   of the mutated class.
    -- - Since a class decorator can add extra initializers, we must define a variable to keep track of
    --   extra initializers.
    local classDecorators = self:transformAllDecoratorsOfDeclaration(node:Decorators())
    if core.Len(classDecorators) > 0 then
        debug.Assert(ci.classThis ~= nil)

        ci.classDecoratorsName = f:NewUniqueNameEx("_classDecorators", {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
        })
        ci.classDescriptorName = f:NewUniqueNameEx("_classDescriptor", {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
        })
        ci.classExtraInitializersName = f:NewUniqueNameEx("_classExtraInitializers", {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
        })

        local decoratorsArray = f:NewArrayLiteralExpression(
            f:NewNodeList(classDecorators),
            false
        )
        classDefinitionStatements[#classDefinitionStatements + 1] = self:createLet(ci.classDecoratorsName, decoratorsArray)
        classDefinitionStatements[#classDefinitionStatements + 1] = self:createLet(ci.classDescriptorName, nil)
        classDefinitionStatements[#classDefinitionStatements + 1] = self:createLet(ci.classExtraInitializersName, f:NewArrayLiteralExpression(f:NewNodeList(nil), false))
        classDefinitionStatements[#classDefinitionStatements + 1] = self:createLet(ci.classThis, nil)

        if core.Len(classDecorators) > 0 and ci.hasStaticPrivateClassElements then
            shouldTransformPrivateStaticElementsInClass = true
            self.shouldTransformPrivateStaticElementsInFile = true
        end
    end

    -- 2. ClassHeritage clause is evaluated outside of the private name scope of the class.
    local extendsClause = ast.GetHeritageClause(node, Kind.ExtendsKeyword)
    local extendsElement
    if extendsClause ~= nil then
        local hc = extendsClause:AsHeritageClause()
        if hc.types ~= nil and #hc.types.nodes > 0 then
            extendsElement = hc.types.nodes[1]
        end
    end
    local extendsExpression
    if extendsElement ~= nil then
        extendsExpression = self:Visitor():VisitNode(extendsElement:AsExpressionWithTypeArguments().expression)
    end

    if extendsExpression ~= nil then
        -- Rewrite `super` in static initializers so that we can use the correct `this`.
        ci.classSuper = f:NewUniqueNameEx("_classSuper", {
            flags = printer.GeneratedIdentifierFlagsOptimistic | printer.GeneratedIdentifierFlagsFileLevel,
        })

        -- Ensure we do not give the class or function an assigned name due to the variable by prefixing it
        -- with `0, `.
        local unwrapped = ast.SkipOuterExpressions(extendsExpression, OEK.OEKAll)
        local safeExtendsExpression = extendsExpression
        if (ast.IsClassExpression(unwrapped) and unwrapped:Name() == nil) or
            (ast.IsFunctionExpression(unwrapped) and unwrapped:Name() == nil) or
            ast.IsArrowFunction(unwrapped) then
            safeExtendsExpression = f:NewCommaExpression(
                f:NewNumericLiteral("0", 0),
                extendsExpression
            )
        end
        classDefinitionStatements[#classDefinitionStatements + 1] = self:createLet(ci.classSuper, safeExtendsExpression)

        local updatedExtendsElement = f:UpdateExpressionWithTypeArguments(extendsElement:AsExpressionWithTypeArguments(), ci.classSuper, nil)
        local hc = extendsClause:AsHeritageClause()
        local updatedExtendsClause = f:UpdateHeritageClause(hc, hc.token, f:NewNodeList({ updatedExtendsElement }))
        heritageClauses = f:NewNodeList({ updatedExtendsClause })
    end

    local renamedClassThis
    if ci.classThis ~= nil then
        renamedClassThis = ci.classThis
    else
        renamedClassThis = f:NewThisExpression()
    end

    -- 3. The name of the class is assigned.
    --
    -- If the class did not have a name, the caller should have performed injectClassNamedEvaluationHelperBlockIfMissing
    -- prior to calling this function if a name was needed.

    -- 4. For each member:
    --    a. Member Decorators are evaluated
    --    b. Computed Property Name is evaluated, if present
    --
    -- We visit members in two passes:
    -- - The first pass visits methods, accessors, and fields to collect decorators and computed property names.
    -- - The second pass visits the constructor to add instance initializers.
    --
    -- NOTE: If there are no constructors, but there are instance initializers, a synthetic constructor is added.
    self:enterClass(ci)

    leadingBlockStatements[#leadingBlockStatements + 1] = self:createMetadata(ci.metadataReference, ci.classSuper)

    -- Since the constructor can appear anywhere in the class body and its transform depends on other class elements,
    -- we must first visit all non-constructor members, then visit the constructor, all while maintaining document order.
    local members = self.nonConstructorClassElementVisitor:VisitNodes(node:MemberList())
    members = self.constructorClassElementVisitor:VisitNodes(members)

    -- Handle pending expressions (computed property names and decorator evaluations)
    if core.Len(self.pendingExpressions) > 0 then
        -- If a pending expression contains a lexical `this`, we'll need to capture the lexical `this` of the
        -- container and transform it in the expression. This ensures we use the correct `this` in the resulting
        -- class `static` block. We don't use substitution here because the size of the tree we are visiting
        -- is likely to be small and doesn't justify the complexity of introducing substitution.
        self.outerThis = nil
        for _, expr in ipairs(self.pendingExpressions) do
            -- If a pending expression contains lexical `this`, capture it
            if expr:SubtreeFacts() & SF.SubtreeContainsLexicalThis ~= 0 then
                expr = self.outerThisVisitor:VisitNode(expr)
            end
            local statement = f:NewExpressionStatement(expr)
            leadingBlockStatements[#leadingBlockStatements + 1] = statement
        end
        if self.outerThis ~= nil then
            table.insert(classDefinitionStatements, 1, self:createLet(self.outerThis, f:NewThisExpression()))
        end
        self.pendingExpressions = nil
    end
    self:exitClass()

    -- If there are instance initializers but no constructor, synthesize one
    if core.Len(ci.pendingInstanceInitializers) > 0 and ast.GetFirstConstructorWithBody(node) == nil then
        local initializerStatements = self:prepareConstructor(ci)
        if core.Len(initializerStatements) > 0 then
            local isDerivedClass = extendsElement ~= nil and ast.SkipOuterExpressions(extendsElement:AsExpressionWithTypeArguments().expression, OEK.OEKAll).kind ~= Kind.NullKeyword
            local constructorStatements = {}
            if isDerivedClass then
                local spreadArguments = f:NewSpreadElement(f:NewIdentifier("arguments"))
                local superCall = f:NewCallExpression(f:NewKeywordExpression(Kind.SuperKeyword), nil, nil, f:NewNodeList({ spreadArguments }), NodeFlags.None)
                constructorStatements[#constructorStatements + 1] = f:NewExpressionStatement(superCall)
            end
            appendAll(constructorStatements, initializerStatements)
            local constructorBody = f:NewBlock(f:NewNodeList(constructorStatements), true)
            syntheticConstructor = f:NewConstructorDeclaration(nil, nil, f:NewNodeList(nil), nil, nil, constructorBody)
        end
    end

    -- Used in class definition steps 5,7,11
    if ci.staticMethodExtraInitializersName ~= nil then
        classDefinitionStatements[#classDefinitionStatements + 1] =
            self:createLet(ci.staticMethodExtraInitializersName, f:NewArrayLiteralExpression(f:NewNodeList(nil), false))
    end

    -- Used in class definition steps 6,8, and construction
    if ci.instanceMethodExtraInitializersName ~= nil then
        classDefinitionStatements[#classDefinitionStatements + 1] =
            self:createLet(ci.instanceMethodExtraInitializersName, f:NewArrayLiteralExpression(f:NewNodeList(nil), false))
    end

    -- Used in class definition steps 7, 8, 12, and construction.
    -- Emit member info variable declarations; the reference implementation emits static member vars first, then non-static.
    if ci.memberInfos:Size() > 0 then
        appendAll(classDefinitionStatements, self:emitMemberInfoDeclarations(ci, true))
        appendAll(classDefinitionStatements, self:emitMemberInfoDeclarations(ci, false))
    end

    -- 5. Static non-field element decorators are applied
    appendAll(leadingBlockStatements, ci.staticNonFieldDecorationStatements)

    -- 6. Non-static non-field element decorators are applied
    appendAll(leadingBlockStatements, ci.nonStaticNonFieldDecorationStatements)

    -- 7. Static field element decorators are applied
    appendAll(leadingBlockStatements, ci.staticFieldDecorationStatements)

    -- 8. Non-static field element decorators are applied
    appendAll(leadingBlockStatements, ci.nonStaticFieldDecorationStatements)

    -- 9. Class decorators are applied
    -- 10. Class binding is initialized
    --
    -- produces:
    --   __esDecorate(null, _classDescriptor = { value: this }, _classDecorators, { kind: "class", name: this.name, metadata }, null, _classExtraInitializers);
    if ci.classDescriptorName ~= nil and ci.classDecoratorsName ~= nil and ci.classExtraInitializersName ~= nil and ci.classThis ~= nil then
        local valueProperty = f:NewPropertyAssignment(nil, f:NewIdentifier("value"), nil, nil, renamedClassThis)
        local classDescriptor = f:NewObjectLiteralExpression(f:NewNodeList({ valueProperty }), false)
        local classDescriptorAssignment = f:NewAssignmentExpression(ci.classDescriptorName, classDescriptor)
        local classNameReference = f:NewPropertyAccessExpression(renamedClassThis, nil, f:NewIdentifier("name"), NodeFlags.None)

        local contextObj = f:NewESDecorateClassContextObject(classNameReference, ci.metadataReference)

        local esDecorateHelper = f:NewESDecorateHelper(
            f:NewToken(Kind.NullKeyword),
            classDescriptorAssignment,
            ci.classDecoratorsName,
            contextObj,
            f:NewToken(Kind.NullKeyword),
            ci.classExtraInitializersName
        )
        local esDecorateStatement = f:NewExpressionStatement(esDecorateHelper)
        ec:SetSourceMapRange(esDecorateStatement, transformers.MoveRangePastDecorators(node))
        leadingBlockStatements[#leadingBlockStatements + 1] = esDecorateStatement

        -- produces:
        --   C = _classThis = _classDescriptor.value;
        local classDescriptorValueRef = f:NewPropertyAccessExpression(ci.classDescriptorName, nil, f:NewIdentifier("value"), NodeFlags.None)
        local classThisAssignment = f:NewAssignmentExpression(ci.classThis, classDescriptorValueRef)
        local classReferenceAssignment = f:NewAssignmentExpression(classReference, classThisAssignment)
        leadingBlockStatements[#leadingBlockStatements + 1] = f:NewExpressionStatement(classReferenceAssignment)
    end

    -- produces:
    --   if (metadata) Object.defineProperty(C, Symbol.metadata, { configurable: true, writable: true, value: metadata });
    leadingBlockStatements[#leadingBlockStatements + 1] = self:createSymbolMetadata(renamedClassThis, ci.metadataReference)

    -- 11. Static extra initializers
    -- 12. Static fields are initialized
    if core.Len(ci.pendingStaticInitializers) > 0 then
        for _, initializer in ipairs(ci.pendingStaticInitializers) do
            local initializerStatement = f:NewExpressionStatement(initializer)
            ec:SetSourceMapRange(initializerStatement, ec:SourceMapRange(initializer))
            trailingBlockStatements[#trailingBlockStatements + 1] = initializerStatement
        end
        ci.pendingStaticInitializers = nil
    end

    -- 13. Class extra initializers
    if ci.classExtraInitializersName ~= nil then
        local runClassInitializersHelper = f:NewRunInitializersHelper(renamedClassThis, ci.classExtraInitializersName, nil)
        local runClassInitializersStatement = f:NewExpressionStatement(runClassInitializersHelper)
        if node:Name() ~= nil then
            ec:SetSourceMapRange(runClassInitializersStatement, node:Name().loc)
        else
            ec:SetSourceMapRange(runClassInitializersStatement, transformers.MoveRangePastDecorators(node))
        end
        trailingBlockStatements[#trailingBlockStatements + 1] = runClassInitializersStatement
    end

    -- If there are no other static initializers to run, combine the leading and trailing block statements
    if #leadingBlockStatements > 0 and #trailingBlockStatements > 0 and not ci.hasStaticInitializers then
        appendAll(leadingBlockStatements, trailingBlockStatements)
        trailingBlockStatements = {}
    end

    -- prepare a leading `static {}` block, if necessary
    --
    -- produces:
    --   class C {
    --       static { ... }
    --       ...
    --   }
    local leadingStaticBlock
    if #leadingBlockStatements > 0 then
        leadingStaticBlock = f:NewClassStaticBlockDeclaration(
            nil,
            f:NewBlock(f:NewNodeList(leadingBlockStatements), true)
        )
    end

    if leadingStaticBlock ~= nil and shouldTransformPrivateStaticElementsInClass then
        -- We use EFTransformPrivateStaticElements as a marker on a class static block
        -- to inform the classFields transform that it shouldn't rename `this` to `_classThis` in the
        -- transformed class static block.
        ec:SetEmitFlags(leadingStaticBlock, EF.EFTransformPrivateStaticElements)
    end

    -- prepare a trailing `static {}` block, if necessary
    --
    -- produces:
    --   class C {
    --       ...
    --       static { ... }
    --   }
    local trailingStaticBlock
    if #trailingBlockStatements > 0 then
        trailingStaticBlock = f:NewClassStaticBlockDeclaration(
            nil,
            f:NewBlock(f:NewNodeList(trailingBlockStatements), true)
        )
    end

    -- Assemble new members list
    if leadingStaticBlock ~= nil or syntheticConstructor ~= nil or trailingStaticBlock ~= nil then
        local newMembers = {}
        local memberNodes = members.nodes or {}

        -- Find the existing NamedEvaluation helper block index
        local existingNamedEvaluationHelperBlockIndex = -1
        for i1, m in ipairs(memberNodes) do
            if estransforms.isClassNamedEvaluationHelperBlock(ec, m) then
                existingNamedEvaluationHelperBlockIndex = i1 - 1
                break
            end
        end

        -- add the leading `static {}` block
        if leadingStaticBlock ~= nil then
            -- add the `static {}` block after any existing NamedEvaluation helper block, if one exists.
            for i = 1, existingNamedEvaluationHelperBlockIndex + 1 do
                newMembers[#newMembers + 1] = memberNodes[i]
            end
            newMembers[#newMembers + 1] = leadingStaticBlock
            for i = existingNamedEvaluationHelperBlockIndex + 2, #memberNodes do
                newMembers[#newMembers + 1] = memberNodes[i]
            end
        else
            appendAll(newMembers, memberNodes)
        end

        -- append the synthetic constructor, if necessary
        if syntheticConstructor ~= nil then
            newMembers[#newMembers + 1] = syntheticConstructor
        end

        -- append a trailing `static {}` block, if necessary
        if trailingStaticBlock ~= nil then
            newMembers[#newMembers + 1] = trailingStaticBlock
        end

        local membersList = f:NewNodeList(newMembers)
        membersList.loc = members.loc
        members = membersList
    end

    local lexicalEnvironment = ec:EndVariableEnvironment()

    local classExpression
    if core.Len(classDecorators) > 0 then
        classExpression = f:NewClassExpression(nil, nil, nil, heritageClauses, members)
        ec:SetOriginal(classExpression, node)
        if ci.classThis ~= nil then
            classExpression = estransforms.injectClassThisAssignmentIfMissing(ec, f, classExpression, ci.classThis)
        end

        -- We use `var` instead of `let` so we can leverage NamedEvaluation to define the class name
        -- and still be able to ensure it is initialized prior to any use in `static {}`.

        -- produces:
        --   (() => {
        --       let _classDecorators = [...];
        --       let _classDescriptor;
        --       let _classExtraInitializers = [];
        --       let _classThis;
        --       ...
        --       var C = class {
        --           static {
        --               __esDecorate(null, _classDescriptor = { value: this }, _classDecorators, ...);
        --               C = _classThis = _classDescriptor.value;
        --           }
        --           static x = 1;
        --           static y = C.x; // `C` will already be defined here.
        --           static { ... }
        --       };
        --       return C;
        --   })();

        local classReferenceDeclaration = f:NewVariableDeclaration(classReference, nil, nil, classExpression)
        local classReferenceVarDeclList = f:NewVariableDeclarationList(f:NewNodeList({ classReferenceDeclaration }), NodeFlags.None)
        local returnExpr
        if ci.classThis ~= nil then
            returnExpr = f:NewAssignmentExpression(classReference, ci.classThis)
        else
            returnExpr = classReference
        end
        classDefinitionStatements[#classDefinitionStatements + 1] = f:NewVariableStatement(nil, classReferenceVarDeclList)
        classDefinitionStatements[#classDefinitionStatements + 1] = f:NewReturnStatement(returnExpr)
    else
        -- produces:
        --   return <classExpression>;
        classExpression = f:NewClassExpression(nil, node:Name(), nil, heritageClauses, members)
        ec:SetOriginal(classExpression, node)
        classDefinitionStatements[#classDefinitionStatements + 1] = f:NewReturnStatement(classExpression)
    end

    if shouldTransformPrivateStaticElementsInClass then
        ec:AddEmitFlags(classExpression, EF.EFTransformPrivateStaticElements)
        for _, member in ipairs(classExpression:Members() or {}) do
            if (ast.IsPrivateIdentifierClassElementDeclaration(member) or ast.IsAutoAccessorPropertyDeclaration(member)) and ast.HasStaticModifier(member) then
                ec:AddEmitFlags(member, EF.EFTransformPrivateStaticElements)
            end
        end
    end

    local mergedStatements = ec:MergeEnvironment(classDefinitionStatements, lexicalEnvironment)
    return f:NewImmediatelyInvokedArrowFunction(mergedStatements)
end

-- Generates let declarations for member decorator info variables, filtered by static/non-static.
function esDecoratorTransformer:emitMemberInfoDeclarations(ci, isStatic)
    local f = self:Factory()
    local stmts = {}
    for member, mi in ci.memberInfos:Entries() do
        if ast.IsStatic(member) == isStatic then
            stmts[#stmts + 1] = self:createLet(mi.memberDecoratorsName, nil)
            if mi.memberInitializersName ~= nil then
                stmts[#stmts + 1] = self:createLet(mi.memberInitializersName, f:NewArrayLiteralExpression(f:NewNodeList(nil), false))
            end
            if mi.memberExtraInitializersName ~= nil then
                stmts[#stmts + 1] = self:createLet(mi.memberExtraInitializersName, f:NewArrayLiteralExpression(f:NewNodeList(nil), false))
            end
            if mi.memberDescriptorName ~= nil then
                stmts[#stmts + 1] = self:createLet(mi.memberDescriptorName, nil)
            end
        end
    end
    return stmts
end

function estransforms.isDecoratedClassLike(node)
    return ast.ClassOrConstructorParameterIsDecorated(false, node) or
        ast.ChildIsDecorated(false, node, nil)
end

function esDecoratorTransformer:visitClassDeclaration(node)
    if estransforms.isDecoratedClassLike(node:AsNode()) then
        local f = self:Factory()
        local ec = self:EmitContext()
        local statements = {}

        local originalClass = ec:MostOriginal(node:AsNode())
        if not ast.IsClassLike(originalClass) then
            originalClass = node:AsNode()
        end
        local className
        if originalClass:Name() ~= nil then
            className = f:NewStringLiteralFromNode(originalClass:Name())
        else
            className = f:NewStringLiteral("default", 0)
        end

        local isExport = ast.HasSyntacticModifier(node:AsNode(), ast.ModifierFlags.Export)
        local isDefault = ast.HasSyntacticModifier(node:AsNode(), ast.ModifierFlags.Default)

        local classNode = node:AsNode()
        if node:Name() == nil then
            classNode = estransforms.injectClassNamedEvaluationHelperBlockIfMissing(ec, classNode, className, nil)
        end

        if isExport and isDefault then
            local iife = self:transformClassLike(classNode)
            if classNode:Name() ~= nil then
                -- produces:
                --   let C = (() => { ... })();
                --   export default C;
                local varDecl = f:NewVariableDeclaration(f:GetLocalName(classNode), nil, nil, iife)
                ec:SetOriginal(varDecl, classNode)
                local varDecls = f:NewVariableDeclarationList(f:NewNodeList({ varDecl }), NodeFlags.Let)
                local varStatement = f:NewVariableStatement(nil, varDecls)
                statements[#statements + 1] = varStatement

                local exportStatement = f:NewExportDefault(f:GetDeclarationName(classNode))
                ec:SetOriginal(exportStatement, classNode)
                ec:AssignCommentRange(exportStatement, classNode)
                ec:SetSourceMapRange(exportStatement, transformers.MoveRangePastDecorators(classNode))
                statements[#statements + 1] = exportStatement
            else
                -- produces:
                --   export default (() => { ... })();
                local exportStatement = f:NewExportDefault(iife)
                ec:SetOriginal(exportStatement, classNode)
                ec:AssignCommentRange(exportStatement, classNode)
                ec:SetSourceMapRange(exportStatement, transformers.MoveRangePastDecorators(classNode))
                statements[#statements + 1] = exportStatement
            end
        else
            debug.Assert(classNode:Name() ~= nil, "A class declaration that is not a default export must have a name.")
            -- produces:
            --   let C = (() => { ... })();
            local iife = self:transformClassLike(classNode)
            local modifiers = self.exportStrippingModifierVisitor:VisitModifiers(classNode:Modifiers())

            local declName = f:GetLocalNameEx(classNode, { allowSourceMaps = true })
            local varDecl = f:NewVariableDeclaration(declName, nil, nil, iife)
            ec:SetOriginal(varDecl, classNode)
            local varDecls = f:NewVariableDeclarationList(f:NewNodeList({ varDecl }), NodeFlags.Let)
            local varStatement = f:NewVariableStatement(modifiers, varDecls)
            ec:SetOriginal(varStatement, classNode)
            ec:AssignCommentRange(varStatement, classNode)
            statements[#statements + 1] = varStatement

            if isExport then
                -- produces:
                --   export { C };
                local exportStatement = f:NewExternalModuleExport(declName)
                ec:SetOriginal(exportStatement, classNode)
                statements[#statements + 1] = exportStatement
            end
        end

        return transformers.SingleOrMany(statements, f)
    end

    -- Non-decorated class
    local modifiers = self.modifierVisitor:VisitModifiers(node:Modifiers())
    local heritageClauses = self:Visitor():VisitNodes(node.heritageClauses)
    self:enterClass(nil)
    local members = self.classElementVisitor:VisitNodes(node.members)
    self:exitClass()
    return self:Factory():UpdateClassDeclaration(node, modifiers, node:Name(), nil, heritageClauses, members)
end

function esDecoratorTransformer:visitClassExpression(node)
    if estransforms.isDecoratedClassLike(node:AsNode()) then
        local iife = self:transformClassLike(node:AsNode())
        self:EmitContext():SetOriginal(iife, node:AsNode())
        return iife
    end

    local modifiers = self.modifierVisitor:VisitModifiers(node:Modifiers())
    local heritageClauses = self:Visitor():VisitNodes(node.heritageClauses)
    self:enterClass(nil)
    local members = self.classElementVisitor:VisitNodes(node.members)
    self:exitClass()
    return self:Factory():UpdateClassExpression(node, modifiers, node:Name(), nil, heritageClauses, members)
end

function esDecoratorTransformer:prepareConstructor(ci)
    -- Decorated instance members can add "extra" initializers to the instance. If a class contains any instance
    -- fields, we'll inject the `__runInitializers()` call for these extra initializers into the initializer of
    -- the first class member that will be initialized. However, if the class does not contain any fields that
    -- we can piggyback on, we need to synthesize a `__runInitializers()` call in the constructor instead.
    if core.Len(ci.pendingInstanceInitializers) == 0 then
        return nil
    end
    local f = self:Factory()
    local statements = {
        f:NewExpressionStatement(f:InlineExpressions(ci.pendingInstanceInitializers)),
    }
    ci.pendingInstanceInitializers = nil
    return statements
end

function esDecoratorTransformer:transformConstructorBodyWorker(statementsOut, statementsIn, statementOffset, superPath, superPathDepth, initializerStatements)
    statementsOut = statementsOut or {}
    local superStatementIndex = superPath[superPathDepth + 1]
    -- Visit statements before super
    if superStatementIndex > statementOffset then
        for i = statementOffset, superStatementIndex - 1 do
            statementsOut[#statementsOut + 1] = self:Visitor():VisitNode(statementsIn[i + 1])
        end
    end

    local superStatement = statementsIn[superStatementIndex + 1]
    if ast.IsTryStatement(superStatement) then
        -- Recurse into try block
        local tryBlockNode = superStatement:AsTryStatement().tryBlock
        local tryBlock = tryBlockNode:AsBlock()
        local tryBlockStatements = self:transformConstructorBodyWorker(nil, tryBlock.statements.nodes, 0, superPath, superPathDepth + 1, initializerStatements)

        local newTryBlock = self:Factory():NewBlock(self:Factory():NewNodeList(tryBlockStatements), true)
        -- Use the original try block's range even though the statements may differ due to
        -- injected initializer statements. This preserves source map fidelity for the enclosing
        -- try statement.
        newTryBlock.loc = tryBlockNode.loc

        local catchClause
        if superStatement:AsTryStatement().catchClause ~= nil then
            catchClause = self:Visitor():VisitNode(superStatement:AsTryStatement().catchClause)
        end
        local finallyBlock
        if superStatement:AsTryStatement().finallyBlock ~= nil then
            finallyBlock = self:Visitor():VisitNode(superStatement:AsTryStatement().finallyBlock)
        end
        local updated = self:Factory():UpdateTryStatement(superStatement:AsTryStatement(), newTryBlock, catchClause, finallyBlock)
        statementsOut[#statementsOut + 1] = updated
    else
        statementsOut[#statementsOut + 1] = self:Visitor():VisitNode(superStatement)
        appendAll(statementsOut, initializerStatements)
    end

    -- Visit statements after super
    if superStatementIndex + 1 < #statementsIn then
        for i = superStatementIndex + 1, #statementsIn - 1 do
            statementsOut[#statementsOut + 1] = self:Visitor():VisitNode(statementsIn[i + 1])
        end
    end
    return statementsOut
end

function esDecoratorTransformer:visitConstructorDeclaration(node)
    self:enterClassElement(node)
    local modifiers = self.modifierVisitor:VisitModifiers(node:Modifiers())
    local parameters = self:Visitor():VisitNodes(node:ParameterList())

    local body
    local ctor = node:AsConstructorDeclaration()
    if ctor.body ~= nil and self.classInfoStack ~= nil then
        -- If there are instance extra initializers we need to add them to the body along with any
        -- field initializers
        local initializerStatements = self:prepareConstructor(self.classInfoStack)
        if core.Len(initializerStatements) > 0 then
            local stmts = {}
            local prologue, rest = self:Factory():SplitStandardPrologue(ctor.body:AsBlock().statements.nodes)
            appendAll(stmts, prologue)

            local superStatementIndices = transformers.FindSuperStatementIndexPath(rest, 0)
            if core.Len(superStatementIndices) > 0 then
                stmts = self:transformConstructorBodyWorker(stmts, rest, 0, superStatementIndices, 0, initializerStatements)
            else
                appendAll(stmts, initializerStatements)
                local visited = self:Visitor():VisitSlice(rest)
                appendAll(stmts, visited)
            end

            body = self:Factory():NewBlock(self:Factory():NewNodeList(stmts), true)
            self:EmitContext():SetOriginal(body, ctor.body:AsNode())
            body.loc = ctor.body.loc
        end
    end

    if body == nil then
        body = self:Visitor():VisitNode(ctor.body)
    end
    self:exitClassElement()
    return self:Factory():UpdateConstructorDeclaration(ctor, modifiers, nil, parameters, nil, nil, body)
end

function esDecoratorTransformer:finishClassElement(updated, original)
    if updated ~= original then
        -- While we emit the source map for the node after skipping decorators and modifiers,
        -- we need to emit the comments for the original range.
        self:EmitContext():AssignCommentRange(updated, original)
        self:EmitContext():SetSourceMapRange(updated, transformers.MoveRangePastDecorators(original))
    end
    return updated
end

-- partialResult: { modifiers, referencedName, name, initializersName, extraInitializersName, descriptorName, thisArg }
-- createDescriptorFunc: function(member, modifiers) -> Expression

function esDecoratorTransformer:partialTransformClassElement(member, ci, createDescriptor)
    local f = self:Factory()
    local ec = self:EmitContext()

    if ci == nil then
        local modifiers = self.modifierVisitor:VisitModifiers(member:Modifiers())
        self:enterName()
        local name = self:visitPropertyName(member:Name())
        self:exitName()
        return { modifiers = modifiers, name = name }
    end

    -- Member decorators require privileged access to private names. However, computed property
    -- evaluation occurs interspersed with decorator evaluation. This means that if we encounter
    -- a computed property name we must inline decorator evaluation.

    -- Collect decorators for this member. Decorator expressions evaluate outside the class body,
    -- so `this` should NOT be replaced with `_classThis`.
    local savedClassThis = self.classThis
    self.classThis = nil
    local memberDecorators = self:transformAllDecoratorsOfDeclaration(member:Decorators())
    self.classThis = savedClassThis
    local modifiers = self.modifierVisitor:VisitModifiers(member:Modifiers())

    local result = {}
    result.modifiers = modifiers

    if core.Len(memberDecorators) > 0 then
        local memberDecoratorsName = self:createHelperVariable(member, "decorators")
        local memberDecoratorsArray = f:NewArrayLiteralExpression(
            f:NewNodeList(memberDecorators),
            false
        )
        local memberDecoratorsAssignment = f:NewAssignmentExpression(memberDecoratorsName, memberDecoratorsArray)
        local mi = {
            memberDecoratorsName = memberDecoratorsName,
            memberInitializersName = nil,
            memberExtraInitializersName = nil,
            memberDescriptorName = nil,
        }
        ci.memberInfos:Set(member, mi)
        self.pendingExpressions = core.Append(self.pendingExpressions, memberDecoratorsAssignment)

        -- 5. Static non-field (method/getter/setter/auto-accessor) element decorators are applied
        -- 6. Non-static non-field (method/getter/setter/auto-accessor) element decorators are applied
        -- 7. Static field (excl. auto-accessor) element decorators are applied
        -- 8. Non-static field (excl. auto-accessor) element decorators are applied

        -- Determine decorator kind
        local kind = ""
        if ast.IsGetAccessorDeclaration(member) then
            kind = "getter"
        elseif ast.IsSetAccessorDeclaration(member) then
            kind = "setter"
        elseif ast.IsMethodDeclaration(member) then
            kind = "method"
        elseif ast.IsAutoAccessorPropertyDeclaration(member) then
            kind = "accessor"
        elseif ast.IsPropertyDeclaration(member) then
            kind = "field"
        else
            debug.Fail("Unexpected class element kind.")
        end

        -- Determine the property name for the context
        local propertyNameComputed = false
        local propertyNameExpr
        if member:Name() ~= nil and (ast.IsIdentifier(member:Name()) or ast.IsPrivateIdentifier(member:Name())) then
            propertyNameComputed = false
            propertyNameExpr = member:Name()
        elseif member:Name() ~= nil and ast.IsPropertyNameLiteral(member:Name()) then
            propertyNameComputed = true
            propertyNameExpr = f:NewStringLiteralFromNode(member:Name())
        elseif member:Name() ~= nil and ast.IsComputedPropertyName(member:Name()) then
            local cpn = member:Name():AsComputedPropertyName()
            if ast.IsPropertyNameLiteral(cpn.expression) and not ast.IsIdentifier(cpn.expression) then
                propertyNameComputed = true
                propertyNameExpr = f:NewStringLiteralFromNode(cpn.expression)
            else
                self:enterName()
                result.referencedName, result.name = self:visitReferencedPropertyName(member:Name())
                self:exitName()
                propertyNameComputed = true
                propertyNameExpr = result.referencedName
            end
        end

        local contextObj = f:NewESDecorateClassElementContextObject(
            kind,
            propertyNameComputed,
            propertyNameExpr,
            ast.IsStatic(member),
            member:Name() ~= nil and ast.IsPrivateIdentifier(member:Name()),
            -- 15.7.3 CreateDecoratorAccessObject (kind, name)
            -- 2. If _kind_ is ~field~, ~method~, ~accessor~, or ~getter~, then ...
            ast.IsPropertyDeclaration(member) or ast.IsGetAccessorDeclaration(member) or ast.IsMethodDeclaration(member),
            -- 3. If _kind_ is ~field~, ~accessor~, or ~setter~, then ...
            ast.IsPropertyDeclaration(member) or ast.IsSetAccessorDeclaration(member),
            ci.metadataReference
        )

        if ast.IsMethodOrAccessor(member) then
            -- produces (public elements):
            --   __esDecorate(this, null, _static_member_decorators, { kind: "method", name: "...", static: true, private: false, access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(this, null, _member_decorators, { kind: "method", name: "...", static: false, private: false, access: { ... } }, _instanceExtraInitializers);
            --   __esDecorate(this, null, _static_member_decorators, { kind: "getter", name: "...", static: true, private: false, access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(this, null, _member_decorators, { kind: "getter", name: "...", static: false, private: false, access: { ... } }, _instanceExtraInitializers);
            --   __esDecorate(this, null, _static_member_decorators, { kind: "setter", name: "...", static: true, private: false, access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(this, null, _member_decorators, { kind: "setter", name: "...", static: false, private: false, access: { ... } }, _instanceExtraInitializers);
            --
            -- produces (private elements):
            --   __esDecorate(this, _static_member_descriptor = { value() { ... } }, _static_member_decorators, { kind: "method", name: "...", static: true, private: true, access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(this, _member_descriptor = { value() { ... } }, _member_decorators, { kind: "method", name: "...", static: false, private: true, access: { ... } }, _instanceExtraInitializers);
            --   __esDecorate(this, _static_member_descriptor = { get() { ... } }, _static_member_decorators, { kind: "getter", name: "...", static: true, private: true, access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(this, _member_descriptor = { get() { ... } }, _member_decorators, { kind: "getter", name: "...", static: false, private: true, access: { ... } }, _instanceExtraInitializers);
            --   __esDecorate(this, _static_member_descriptor = { set() { ... } }, _static_member_decorators, { kind: "setter", name: "...", static: true, private: true, access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(this, _member_descriptor = { set() { ... } }, _member_decorators, { kind: "setter", name: "...", static: false, private: true, access: { ... } }, _instanceExtraInitializers);
            local methodExtraInitializersName = ci.instanceMethodExtraInitializersName
            if ast.IsStatic(member) then
                methodExtraInitializersName = ci.staticMethodExtraInitializersName
            end
            debug.Assert(methodExtraInitializersName ~= nil, "methodExtraInitializersName should be defined")

            local descriptorArg
            if ast.IsPrivateIdentifierClassElementDeclaration(member) and createDescriptor ~= nil then
                -- For private members, extract the method/accessor body into a descriptor object.
                -- Filter modifiers to only keep async.
                local asyncMods = self.asyncOnlyModifierVisitor:VisitModifiers(modifiers)
                local descriptor = createDescriptor(member, asyncMods)
                mi.memberDescriptorName = self:createHelperVariable(member, "descriptor")
                result.descriptorName = mi.memberDescriptorName
                descriptorArg = f:NewAssignmentExpression(mi.memberDescriptorName, descriptor)
            else
                descriptorArg = f:NewToken(Kind.NullKeyword)
            end

            local esDecorateExpr = f:NewESDecorateHelper(
                f:NewThisExpression(),
                descriptorArg,
                memberDecoratorsName,
                contextObj,
                f:NewToken(Kind.NullKeyword),
                methodExtraInitializersName
            )
            local esDecorateStatement = f:NewExpressionStatement(esDecorateExpr)
            ec:SetSourceMapRange(esDecorateStatement, transformers.MoveRangePastDecorators(member))
            self:appendDecorationStatement(ci, member, esDecorateStatement)
        elseif ast.IsPropertyDeclaration(member) then
            mi.memberInitializersName = self:createHelperVariable(member, "initializers")
            mi.memberExtraInitializersName = self:createHelperVariable(member, "extraInitializers")
            result.initializersName = mi.memberInitializersName
            result.extraInitializersName = mi.memberExtraInitializersName
            if ast.IsStatic(member) then
                result.thisArg = ci.classThis
            end

            local ctorArg
            if ast.IsAutoAccessorPropertyDeclaration(member) then
                ctorArg = f:NewThisExpression()
            else
                ctorArg = f:NewToken(Kind.NullKeyword)
            end

            local descriptorArg
            if ast.IsPrivateIdentifierClassElementDeclaration(member) and ast.HasAccessorModifier(member) and createDescriptor ~= nil then
                local descriptor = createDescriptor(member, nil)
                mi.memberDescriptorName = self:createHelperVariable(member, "descriptor")
                result.descriptorName = mi.memberDescriptorName
                descriptorArg = f:NewAssignmentExpression(mi.memberDescriptorName, descriptor)
            else
                descriptorArg = f:NewToken(Kind.NullKeyword)
            end

            -- produces:
            --   __esDecorate(null, null, _static_member_decorators, { kind: "field", name: "...", static: true, private: ..., access: { ... } }, _staticExtraInitializers);
            --   __esDecorate(null, null, _member_decorators, { kind: "field", name: "...", static: false, private: ..., access: { ... } }, _instanceExtraInitializers);
            local esDecorateExpr = f:NewESDecorateHelper(
                ctorArg,
                descriptorArg,
                memberDecoratorsName,
                contextObj,
                mi.memberInitializersName,
                mi.memberExtraInitializersName
            )
            local esDecorateStatement = f:NewExpressionStatement(esDecorateExpr)
            ec:SetSourceMapRange(esDecorateStatement, transformers.MoveRangePastDecorators(member))
            self:appendDecorationStatement(ci, member, esDecorateStatement)
        end
    end

    if result.name == nil then
        self:enterName()
        result.name = self:visitPropertyName(member:Name())
        self:exitName()
    end

    if (modifiers == nil or core.Len(modifiers.nodes) == 0) and (ast.IsMethodDeclaration(member) or ast.IsPropertyDeclaration(member)) then
        -- Don't emit leading comments on the name for methods and properties without modifiers, otherwise we
        -- will end up printing duplicate comments.
        ec:SetEmitFlags(result.name, EF.EFNoLeadingComments)
    end

    return result
end

-- appendDecorationStatement appends an __esDecorate statement to the appropriate
-- decoration statement list on classInfo based on the member's kind and static-ness.
function esDecoratorTransformer:appendDecorationStatement(ci, member, stmt)
    if ast.IsMethodOrAccessor(member) or ast.IsAutoAccessorPropertyDeclaration(member) then
        if ast.IsStatic(member) then
            ci.staticNonFieldDecorationStatements = core.Append(ci.staticNonFieldDecorationStatements, stmt)
        else
            ci.nonStaticNonFieldDecorationStatements = core.Append(ci.nonStaticNonFieldDecorationStatements, stmt)
        end
    elseif ast.IsPropertyDeclaration(member) and not ast.IsAutoAccessorPropertyDeclaration(member) then
        if ast.IsStatic(member) then
            ci.staticFieldDecorationStatements = core.Append(ci.staticFieldDecorationStatements, stmt)
        else
            ci.nonStaticFieldDecorationStatements = core.Append(ci.nonStaticFieldDecorationStatements, stmt)
        end
    else
        debug.Fail("Unexpected class element kind.")
    end
end

function esDecoratorTransformer:visitMethodDeclaration(node)
    self:enterClassElement(node)
    local result = self:partialTransformClassElement(node, self.classInfoStack, function(m, mods) return self:createMethodDescriptorObject(m, mods) end)
    if result.descriptorName ~= nil then
        self:exitClassElement()
        return self:finishClassElement(self:createMethodDescriptorForwarder(result.modifiers, result.name, result.descriptorName), node)
    end
    local parameters = self:Visitor():VisitNodes(node:ParameterList())
    local body = self:Visitor():VisitNode(node:Body())
    self:exitClassElement()
    local method = node:AsMethodDeclaration()
    return self:finishClassElement(
        self:Factory():UpdateMethodDeclaration(method, result.modifiers, method.asteriskToken, result.name, nil, nil, parameters, nil, nil, body),
        node
    )
end

function esDecoratorTransformer:visitGetAccessorDeclaration(node)
    self:enterClassElement(node)
    local result = self:partialTransformClassElement(node, self.classInfoStack, function(m, mods) return self:createGetAccessorDescriptorObject(m, mods) end)
    if result.descriptorName ~= nil then
        self:exitClassElement()
        return self:finishClassElement(self:createGetAccessorDescriptorForwarder(result.modifiers, result.name, result.descriptorName), node)
    end
    local parameters = self:Visitor():VisitNodes(node:ParameterList())
    local body = self:Visitor():VisitNode(node:Body())
    self:exitClassElement()
    local accessor = node:AsGetAccessorDeclaration()
    return self:finishClassElement(
        self:Factory():UpdateGetAccessorDeclaration(accessor, result.modifiers, result.name, nil, parameters, nil, nil, body),
        node
    )
end

function esDecoratorTransformer:visitSetAccessorDeclaration(node)
    self:enterClassElement(node)
    local result = self:partialTransformClassElement(node, self.classInfoStack, function(m, mods) return self:createSetAccessorDescriptorObject(m, mods) end)
    if result.descriptorName ~= nil then
        self:exitClassElement()
        return self:finishClassElement(self:createSetAccessorDescriptorForwarder(result.modifiers, result.name, result.descriptorName), node)
    end
    local parameters = self:Visitor():VisitNodes(node:ParameterList())
    local body = self:Visitor():VisitNode(node:Body())
    self:exitClassElement()
    local accessor = node:AsSetAccessorDeclaration()
    return self:finishClassElement(
        self:Factory():UpdateSetAccessorDeclaration(accessor, result.modifiers, result.name, nil, parameters, nil, nil, body),
        node
    )
end

function esDecoratorTransformer:visitClassStaticBlockDeclaration(node)
    self:enterClassElement(node)
    local f = self:Factory()

    local result
    if estransforms.isClassNamedEvaluationHelperBlock(self:EmitContext(), node) then
        result = self:Visitor():VisitEachChild(node)
        -- Transfer AssignedName metadata to the new node so isClassNamedEvaluationHelperBlock
        -- can still find it after visiting (visiting may create a new node when this->_classThis)
        local assignedName = self:EmitContext():AssignedName(node)
        if assignedName ~= nil and result ~= node then
            self:EmitContext():SetAssignedName(result, assignedName)
        end
    elseif estransforms.isClassThisAssignmentBlock(self:EmitContext(), node) then
        local savedClassThis = self.classThis
        self.classThis = nil
        result = self:Visitor():VisitEachChild(node)
        self.classThis = savedClassThis
    else
        -- Use a nested variable environment so temp vars generated during static block
        -- content transformation (e.g., super access temps) stay scoped to the static block.
        local ec = self:EmitContext()
        ec:StartVariableEnvironment()
        result = self:Visitor():VisitEachChild(node)
        local varStatements = ec:EndVariableEnvironment()
        if core.Len(varStatements) > 0 then
            -- Inject var declarations at the start of the static block's body
            local blockBody = result:AsClassStaticBlockDeclaration().body:AsBlock()
            local newStmts = {}
            appendAll(newStmts, varStatements)
            appendAll(newStmts, blockBody.statements.nodes)
            result = f:NewClassStaticBlockDeclaration(nil, f:NewBlock(f:NewNodeList(newStmts), blockBody.multiLine))
        end
        if self.classInfoStack ~= nil then
            self.classInfoStack.hasStaticInitializers = true
            if core.Len(self.classInfoStack.pendingStaticInitializers) > 0 then
                -- If we tried to inject the pending initializers into the current block, we might run into
                -- variable name collisions due to sharing this blocks scope. To avoid this, we inject a new
                -- static block that contains the pending initializers that precedes this block.
                local stmts = {}
                for _, init in ipairs(self.classInfoStack.pendingStaticInitializers) do
                    local initStmt = f:NewExpressionStatement(init)
                    self:EmitContext():SetSourceMapRange(initStmt, self:EmitContext():SourceMapRange(init))
                    stmts[#stmts + 1] = initStmt
                end
                local body = f:NewBlock(f:NewNodeList(stmts), true)
                local staticBlock = f:NewClassStaticBlockDeclaration(nil, body)
                self.classInfoStack.pendingStaticInitializers = nil
                -- Return both the new static block and the original
                self:exitClassElement()
                return transformers.SingleOrMany({ staticBlock, result }, self:Factory())
            end
        end
    end

    self:exitClassElement()
    return result
end

function esDecoratorTransformer:visitPropertyDeclaration(node)
    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node, estransforms.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node, estransforms.canIgnoreEmptyStringLiteralInAssignedName(node:Initializer()), "")
    end

    self:enterClassElement(node)

    -- TODO(rbuckton): We support decorating `declare x` fields with legacyDecorators, but we currently don't
    --                 support them with esDecorators. We need to consider whether we will support them in the
    --                 future, and how. For now, these should be elided by the `ts` transform.
    debug.Assert(not ast.HasSyntacticModifier(node, ast.ModifierFlags.Ambient), "Not yet implemented.")

    -- 10.2.1.3 RS: EvaluateBody
    --   Initializer : `=` AssignmentExpression
    --     ...
    --     3. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _functionObject_.[[ClassFieldInitializerName]].
    --     ...

    local f = self:Factory()
    local ec = self:EmitContext()

    local createDescriptor
    if ast.HasAccessorModifier(node) then
        createDescriptor = function(m, mods) return self:createAccessorPropertyDescriptorObject(m, mods) end
    end
    local result = self:partialTransformClassElement(node, self.classInfoStack, createDescriptor)

    ec:StartVariableEnvironment()

    local initializer = self:Visitor():VisitNode(node:Initializer())
    if result.initializersName ~= nil then
        local thisArg
        if result.thisArg ~= nil then
            thisArg = result.thisArg
        else
            thisArg = f:NewThisExpression()
        end
        if initializer == nil then
            initializer = f:NewVoidZeroExpression()
        end
        initializer = f:NewRunInitializersHelper(thisArg, result.initializersName, initializer)
    end

    if ast.IsStatic(node) and self.classInfoStack ~= nil and initializer ~= nil then
        self.classInfoStack.hasStaticInitializers = true
    end

    local declarations = ec:EndVariableEnvironment()
    if core.Len(declarations) > 0 then
        local stmts = {}
        appendAll(stmts, declarations)
        stmts[#stmts + 1] = f:NewReturnStatement(initializer)
        initializer = f:NewImmediatelyInvokedArrowFunction(stmts)
    end

    if self.classInfoStack ~= nil then
        if ast.IsStatic(node) then
            initializer = self:injectPendingInitializers(self.classInfoStack, true, initializer)
            if result.extraInitializersName ~= nil then
                local thisArg
                if self.classInfoStack.classThis ~= nil then
                    thisArg = self.classInfoStack.classThis
                else
                    thisArg = f:NewThisExpression()
                end
                self.classInfoStack.pendingStaticInitializers = core.Append(
                    self.classInfoStack.pendingStaticInitializers,
                    f:NewRunInitializersHelper(thisArg, result.extraInitializersName, nil)
                )
            end
        else
            initializer = self:injectPendingInitializers(self.classInfoStack, false, initializer)
            if result.extraInitializersName ~= nil then
                self.classInfoStack.pendingInstanceInitializers = core.Append(
                    self.classInfoStack.pendingInstanceInitializers,
                    f:NewRunInitializersHelper(f:NewThisExpression(), result.extraInitializersName, nil)
                )
            end
        end
    end

    self:exitClassElement()

    if ast.HasAccessorModifier(node) and result.descriptorName ~= nil then
        -- given:
        --  accessor #x = 1;
        --
        -- emits:
        --  static {
        --      _esDecorate(null, _private_x_descriptor = { get() { return this.#x_1; }, set(value) { this.#x_1 = value; } }, ...)
        --  }
        --  ...
        --  #x_1 = 1;
        --  get #x() { return _private_x_descriptor.get.call(this); }
        --  set #x(value) { _private_x_descriptor.set.call(this, value); }

        local commentRange = ec:CommentRange(node)
        local sourceMapRange = ec:SourceMapRange(node)

        -- Since we're creating two declarations where there was previously one, cache
        -- the expression for any computed property names.
        local propName = node:Name()
        local getterName = result.name
        local setterName = result.name
        if ast.IsComputedPropertyName(propName) and not transformers.IsSimpleInlineableExpression(propName:Expression()) then
            local cacheAssignment = estransforms.findComputedPropertyNameCacheAssignment(ec, propName)
            if cacheAssignment ~= nil then
                getterName = f:UpdateComputedPropertyName(propName:AsComputedPropertyName(), self:Visitor():VisitNode(propName:Expression()))
                setterName = f:UpdateComputedPropertyName(propName:AsComputedPropertyName(), cacheAssignment.left)
            else
                local temp = f:NewTempVariable()
                ec:SetSourceMapRange(temp, propName:Expression().loc)
                ec:AddVariableDeclaration(temp)
                local expression = self:Visitor():VisitNode(propName:Expression())
                local assignment = f:NewAssignmentExpression(temp, expression)
                ec:SetSourceMapRange(assignment, propName:Expression().loc)
                getterName = f:UpdateComputedPropertyName(propName:AsComputedPropertyName(), assignment)
                setterName = f:UpdateComputedPropertyName(propName:AsComputedPropertyName(), temp)
            end
        end

        local modifiersWithoutAccessor = self.accessorStrippingModifierVisitor:VisitModifiers(result.modifiers)

        local backingField = estransforms.createAccessorPropertyBackingField(f, node:AsPropertyDeclaration(), modifiersWithoutAccessor, initializer)
        ec:SetOriginal(backingField, node)
        ec:SetEmitFlags(backingField, EF.EFNoComments)
        ec:SetSourceMapRange(backingField, sourceMapRange)
        ec:SetSourceMapRange(backingField:AsPropertyDeclaration():Name(), ec:SourceMapRange(node:Name()))

        local getter = self:createGetAccessorDescriptorForwarder(modifiersWithoutAccessor, getterName, result.descriptorName)
        ec:SetOriginal(getter, node)
        ec:SetCommentRange(getter, commentRange)
        ec:SetSourceMapRange(getter, sourceMapRange)

        local setter = self:createSetAccessorDescriptorForwarder(modifiersWithoutAccessor, setterName, result.descriptorName)
        ec:SetOriginal(setter, node)
        ec:SetEmitFlags(setter, EF.EFNoComments)
        ec:SetSourceMapRange(setter, sourceMapRange)

        return transformers.SingleOrMany({ backingField, getter, setter }, f)
    end

    local prop = node:AsPropertyDeclaration()
    return self:finishClassElement(
        f:UpdatePropertyDeclaration(prop, result.modifiers, result.name, nil, nil, initializer),
        node
    )
end

function esDecoratorTransformer:visitThisExpression(node)
    if self.classThis ~= nil then
        return self.classThis
    end
    return node
end

function esDecoratorTransformer:visitCallExpression(node)
    local call = node:AsCallExpression()
    if ast.IsSuperProperty(call.expression) and self.classThis ~= nil then
        local expression = self:Visitor():VisitNode(call.expression)
        local argumentsList = self:Visitor():VisitNodes(call.arguments)
        local invocation = self:Factory():NewFunctionCallCall(expression, self.classThis, argumentsList.nodes)
        self:EmitContext():SetOriginal(invocation, node)
        invocation.loc = node.loc
        return invocation
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitTaggedTemplateExpression(node)
    local tte = node:AsTaggedTemplateExpression()
    if ast.IsSuperProperty(tte.tag) and self.classThis ~= nil then
        local tag = self:Visitor():VisitNode(tte.tag)
        local boundTag = self:Factory():NewFunctionBindCall(tag, self.classThis, {})
        self:EmitContext():SetOriginal(boundTag, node)
        boundTag.loc = node.loc
        local template = self:Visitor():VisitNode(tte.template)
        return self:Factory():UpdateTaggedTemplateExpression(tte, boundTag, nil, nil, template, tte.flags)
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitPropertyAccessExpression(node)
    local pa = node:AsPropertyAccessExpression()
    if ast.IsSuperProperty(node) and ast.IsIdentifier(pa:Name()) and self.classThis ~= nil and self.classSuper ~= nil then
        local propertyName = self:Factory():NewStringLiteralFromNode(pa:Name())
        local superProperty = self:Factory():NewReflectGetCall(self.classSuper, propertyName, self.classThis)
        self:EmitContext():SetOriginal(superProperty, pa.expression)
        superProperty.loc = pa.expression.loc
        return superProperty
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitElementAccessExpression(node)
    local ea = node:AsElementAccessExpression()
    if ast.IsSuperProperty(node) and self.classThis ~= nil and self.classSuper ~= nil then
        local propertyName = self:Visitor():VisitNode(ea.argumentExpression)
        local superProperty = self:Factory():NewReflectGetCall(self.classSuper, propertyName, self.classThis)
        self:EmitContext():SetOriginal(superProperty, ea.expression)
        superProperty.loc = ea.expression.loc
        return superProperty
    end
    return self:Visitor():VisitEachChild(node)
end

-- 8.6.3 RS: IteratorBindingInitialization
--
--	SingleNameBinding : BindingIdentifier Initializer?
--	  ...
--	  5. If |Initializer| is present and _v_ is *undefined*, then
--	     a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
--	        i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
--	  ...
--
-- 14.3.3.3 RS: KeyedBindingInitialization
--
--	SingleNameBinding : BindingIdentifier Initializer?
--	  ...
--	  4. If |Initializer| is present and _v_ is *undefined*, then
--	     a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
--	        i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
--	  ...
function esDecoratorTransformer:visitParameterDeclaration(node)
    local paramNode = node:AsNode()
    if estransforms.isNamedEvaluationAnd(self:EmitContext(), paramNode, estransforms.isAnonymousClassNeedingAssignedName) then
        paramNode = estransforms.transformNamedEvaluation(self:EmitContext(), paramNode, estransforms.canIgnoreEmptyStringLiteralInAssignedName(paramNode:Initializer()), "")
        node = paramNode:AsParameterDeclaration()
    end

    local updated = self:Factory():UpdateParameterDeclaration(
        node,
        nil, -- modifiers - strip all modifiers (including decorators)
        node.dotDotDotToken,
        self:Visitor():VisitNode(node:Name()),
        nil, -- questionToken
        nil, -- type
        self:Visitor():VisitNode(node.initializer)
    )
    if updated ~= paramNode then
        -- While we emit the source map for the node after skipping decorators and modifiers,
        -- we need to emit the comments for the original range.
        self:EmitContext():SetCommentRange(updated, paramNode.loc)
        local newLoc = transformers.MoveRangePastModifiers(paramNode)
        updated.loc = newLoc
        self:EmitContext():SetSourceMapRange(updated, newLoc)
        self:EmitContext():SetEmitFlags(updated:Name(), EF.EFNoTrailingSourceMap)
    end
    return updated
end

-- visitNamedEvaluationSite replaces Strada's visitPropertyAssignment, visitVariableDeclaration,
-- and visitBindingElement, which all share the same logic.
--
-- 13.2.5.5 RS: PropertyDefinitionEvaluation (PropertyAssignment)
--
--	PropertyAssignment : PropertyName `:` AssignmentExpression
--	  ...
--	  5. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true* and _isProtoSetter_ is *false*, then
--	     a. Let _popValue_ be ? NamedEvaluation of |AssignmentExpression| with argument _propKey_.
--	  ...
--
-- 14.3.1.2 RS: Evaluation (VariableDeclaration)
--
--	LexicalBinding : BindingIdentifier Initializer
--	  ...
--	  3. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
--	     a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _bindingId_.
--	  ...
--
-- 14.3.2.1 RS: Evaluation (VariableDeclaration)
--
--	VariableDeclaration : BindingIdentifier Initializer
--	  ...
--	  3. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
--	     a. Let _value_ be ? NamedEvaluation of |Initializer| with argument _bindingId_.
--	  ...
--
-- 8.6.3 RS: IteratorBindingInitialization (BindingElement)
--
--	SingleNameBinding : BindingIdentifier Initializer?
--	  ...
--	  5. If |Initializer| is present and _v_ is *undefined*, then
--	     a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
--	        i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
--	  ...
--
-- 14.3.3.3 RS: KeyedBindingInitialization (BindingElement)
--
--	SingleNameBinding : BindingIdentifier Initializer?
--	  ...
--	  4. If |Initializer| is present and _v_ is *undefined*, then
--	     a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
--	        i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _bindingId_.
--	  ...
function esDecoratorTransformer:visitNamedEvaluationSite(node, classExpr)
    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node, estransforms.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node, estransforms.canIgnoreEmptyStringLiteralInAssignedName(classExpr), "")
    end
    return self:Visitor():VisitEachChild(node)
end

function estransforms.isAnonymousClassNeedingAssignedName(node)
    return ast.IsClassExpression(node) and node:Name() == nil and estransforms.isDecoratedClassLike(node)
end

-- The IIFE produced for `(@dec class {})` will result in an assigned name of the form
-- `var class_1 = class { };`, and thus the empty string cannot be ignored. However, The IIFE
-- produced for `(class { @dec x; })` will not result in an assigned name since it
-- transforms to `return class { };`, and thus the empty string *can* be ignored.
function estransforms.canIgnoreEmptyStringLiteralInAssignedName(node)
    if node == nil then
        return false
    end
    local innerExpression = ast.SkipOuterExpressions(node, OEK.OEKAll)
    return ast.IsClassExpression(innerExpression) and innerExpression:Name() == nil and not ast.ClassOrConstructorParameterIsDecorated(false, innerExpression)
end

function esDecoratorTransformer:visitForStatement(node)
    local f = self:Factory()
    local forStmt = node:AsForStatement()
    return f:UpdateForStatement(
        forStmt,
        self.discardedVisitor:VisitNode(forStmt.initializer),
        self:Visitor():VisitNode(forStmt.condition),
        self.discardedVisitor:VisitNode(forStmt.incrementor),
        self:EmitContext():VisitIterationBody(forStmt.statement, self:Visitor())
    )
end

function esDecoratorTransformer:visitExpressionStatement(node)
    return self.discardedVisitor:VisitEachChild(node)
end

function esDecoratorTransformer:visitBinaryExpression(node, discarded)
    local f = self:Factory()
    local ec = self:EmitContext()
    local bin = node:AsBinaryExpression()

    if ast.IsDestructuringAssignment(node) then
        local left = self:visitAssignmentPattern(bin.left)
        local right = self:Visitor():VisitNode(bin.right)
        return f:UpdateBinaryExpression(bin, nil, left, nil, bin.operatorToken, right)
    end

    if ast.IsAssignmentExpression(node, false) then
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

        if estransforms.isNamedEvaluationAnd(ec, node, estransforms.isAnonymousClassNeedingAssignedName) then
            node = estransforms.transformNamedEvaluation(ec, node, estransforms.canIgnoreEmptyStringLiteralInAssignedName(bin.right), "")
            return self:Visitor():VisitEachChild(node)
        end

        if ast.IsSuperProperty(bin.left) and self.classThis ~= nil and self.classSuper ~= nil then
            local setterName
            if ast.IsElementAccessExpression(bin.left) then
                setterName = self:Visitor():VisitNode(bin.left:AsElementAccessExpression().argumentExpression)
            elseif ast.IsPropertyAccessExpression(bin.left) and ast.IsIdentifier(bin.left:AsPropertyAccessExpression():Name()) then
                setterName = f:NewStringLiteralFromNode(bin.left:AsPropertyAccessExpression():Name())
            end
            if setterName ~= nil then
                -- super.x = ...
                -- super.x += ...
                -- super[x] = ...
                -- super[x] += ...
                local expression = self:Visitor():VisitNode(bin.right)
                if ast.IsCompoundAssignment(bin.operatorToken.kind) then
                    local getterName = setterName
                    if not transformers.IsSimpleInlineableExpression(setterName) then
                        getterName = f:NewTempVariable()
                        ec:AddVariableDeclaration(getterName)
                        setterName = f:NewAssignmentExpression(getterName, setterName)
                    end
                    local superPropertyGet = f:NewReflectGetCall(self.classSuper, getterName, self.classThis)
                    ec:SetOriginal(superPropertyGet, bin.left)
                    superPropertyGet.loc = bin.left.loc
                    expression = f:AsNodeFactory():NewBinaryExpression(
                        nil,
                        superPropertyGet,
                        nil,
                        f:NewToken(transformers.GetNonAssignmentOperatorForCompoundAssignment(bin.operatorToken.kind)),
                        expression
                    )
                    expression.loc = node.loc
                end
                local temp
                if not discarded then
                    temp = f:NewTempVariable()
                    ec:AddVariableDeclaration(temp)
                end
                if temp ~= nil then
                    expression = f:NewAssignmentExpression(temp, expression)
                    expression.loc = node.loc
                end
                expression = f:NewReflectSetCall(self.classSuper, setterName, expression, self.classThis)
                ec:SetOriginal(expression, node)
                expression.loc = node.loc
                if temp ~= nil then
                    expression = f:NewCommaExpression(expression, temp)
                    expression.loc = node.loc
                end
                return expression
            end
        end
    end

    if bin.operatorToken.kind == Kind.CommaToken then
        local left = self.discardedVisitor:VisitNode(bin.left)
        local right
        if discarded then
            right = self.discardedVisitor:VisitNode(bin.right)
        else
            right = self:Visitor():VisitNode(bin.right)
        end
        return f:UpdateBinaryExpression(bin, nil, left, nil, bin.operatorToken, right)
    end

    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitPreOrPostfixUnaryExpression(node, discarded)
    local f = self:Factory()
    local ec = self:EmitContext()

    local operator
    local operandNode
    if ast.IsPrefixUnaryExpression(node) then
        operator = node:AsPrefixUnaryExpression().operator
        operandNode = node:AsPrefixUnaryExpression().operand
    else
        operator = node:AsPostfixUnaryExpression().operator
        operandNode = node:AsPostfixUnaryExpression().operand
    end

    if operator == Kind.PlusPlusToken or operator == Kind.MinusMinusToken then
        local operand = ast.SkipParentheses(operandNode)
        if ast.IsSuperProperty(operand) and self.classThis ~= nil and self.classSuper ~= nil then
            local setterName
            if ast.IsElementAccessExpression(operand) then
                setterName = self:Visitor():VisitNode(operand:AsElementAccessExpression().argumentExpression)
            elseif ast.IsPropertyAccessExpression(operand) and ast.IsIdentifier(operand:AsPropertyAccessExpression():Name()) then
                setterName = f:NewStringLiteralFromNode(operand:AsPropertyAccessExpression():Name())
            end
            if setterName ~= nil then
                local getterName = setterName
                if not transformers.IsSimpleInlineableExpression(setterName) then
                    getterName = f:NewTempVariable()
                    ec:AddVariableDeclaration(getterName)
                    setterName = f:NewAssignmentExpression(getterName, setterName)
                end

                local expression = f:NewReflectGetCall(self.classSuper, getterName, self.classThis)
                ec:SetOriginal(expression, node)
                expression.loc = node.loc

                -- If the result of this expression is discarded (i.e., it's in a position where the result
                -- will be otherwise unused, such as in an expression statement or the left side of a comma), we
                -- don't need to create an extra temp variable to hold the result:
                --
                --  source (discarded):
                --    super.x++;
                --  generated:
                --    _a = Reflect.get(_super, "x"), _a++, Reflect.set(_super, "x", _a);
                --
                -- Above, the temp variable `_a` is used to perform the correct coercion (i.e., number or
                -- bigint). Since the result of the postfix unary is discarded, we don't need to capture the
                -- result of the expression.
                --
                --  source (not discarded):
                --    y = super.x++;
                --  generated:
                --    y = (_a = Reflect.get(_super, "x"), _b = _a++, Reflect.set(_super, "x", _a), _b);
                --
                -- When the result isn't discarded, we introduce a new temp variable (`_b`) to capture the
                -- result of the operation so that we can provide it to `y` when the assignment is complete.
                local temp
                if not discarded then
                    temp = f:NewTempVariable()
                    ec:AddVariableDeclaration(temp)
                end

                expression = estransforms.expandPreOrPostfixIncrementOrDecrementExpression(f, ec, node, expression, temp)

                expression = f:NewReflectSetCall(self.classSuper, setterName, expression, self.classThis)
                ec:SetOriginal(expression, node)
                expression.loc = node.loc

                if temp ~= nil then
                    expression = f:NewCommaExpression(expression, temp)
                    expression.loc = node.loc
                end

                return expression
            end
        end
    end

    return self:Visitor():VisitEachChild(node)
end

-- Returns referencedName, updatedName.
function esDecoratorTransformer:visitReferencedPropertyName(node)
    if ast.IsPropertyNameLiteral(node) or ast.IsPrivateIdentifier(node) then
        return self:Factory():NewStringLiteralFromNode(node), self:Visitor():VisitNode(node)
    end

    local cpn = node:AsComputedPropertyName()
    if ast.IsPropertyNameLiteral(cpn.expression) and not ast.IsIdentifier(cpn.expression) then
        return self:Factory():NewStringLiteralFromNode(cpn.expression), self:Visitor():VisitNode(node)
    end

    local referencedName = self:Factory():NewGeneratedNameForNode(node)
    self:EmitContext():AddVariableDeclaration(referencedName)

    local key = self:Factory():NewPropKeyHelper(self:Visitor():VisitNode(cpn.expression))
    local assignment = self:Factory():NewAssignmentExpression(referencedName, key)
    local updatedName = self:Factory():UpdateComputedPropertyName(cpn, self:injectPendingExpressions(assignment))
    return referencedName, updatedName
end

function esDecoratorTransformer:visitPropertyName(node)
    if ast.IsComputedPropertyName(node) then
        return self:visitComputedPropertyName(node)
    end
    return self:Visitor():VisitNode(node)
end

function esDecoratorTransformer:visitComputedPropertyName(node)
    local cpn = node:AsComputedPropertyName()
    local expression = self:Visitor():VisitNode(cpn.expression)
    if not transformers.IsSimpleInlineableExpression(expression) then
        expression = self:injectPendingExpressions(expression)
    end
    return self:Factory():UpdateComputedPropertyName(cpn, expression)
end

function esDecoratorTransformer:visitDestructuringAssignmentTarget(node)
    if ast.IsObjectLiteralExpression(node) or ast.IsArrayLiteralExpression(node) then
        return self:visitAssignmentPattern(node)
    end

    if ast.IsSuperProperty(node) and self.classThis ~= nil and self.classSuper ~= nil then
        local f = self:Factory()
        local ec = self:EmitContext()
        local propertyName
        if ast.IsElementAccessExpression(node) then
            propertyName = self:Visitor():VisitNode(node:AsElementAccessExpression().argumentExpression)
        elseif ast.IsPropertyAccessExpression(node) and ast.IsIdentifier(node:AsPropertyAccessExpression():Name()) then
            propertyName = f:NewStringLiteralFromNode(node:AsPropertyAccessExpression():Name())
        end
        if propertyName ~= nil then
            local paramName = f:NewTempVariable()
            local expression = f:NewAssignmentTargetWrapper(
                paramName,
                f:NewReflectSetCall(
                    self.classSuper,
                    propertyName,
                    paramName,
                    self.classThis
                )
            )
            ec:SetOriginal(expression, node)
            expression.loc = node.loc
            return expression
        end
    end

    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitAssignmentElement(node)
    -- 13.15.5.5 RS: IteratorDestructuringAssignmentEvaluation
    --   AssignmentElement : DestructuringAssignmentTarget Initializer?
    --     ...
    --     4. If |Initializer| is present and _value_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) and IsIdentifierRef of |DestructuringAssignmentTarget| are both *true*, then
    --           i. Let _v_ be ? NamedEvaluation of |Initializer| with argument _lref_.[[ReferencedName]].
    --     ...
    if ast.IsAssignmentExpression(node, true) then
        local f = self:Factory()
        local bin = node:AsBinaryExpression()
        if estransforms.isNamedEvaluationAnd(self:EmitContext(), node, estransforms.isAnonymousClassNeedingAssignedName) then
            node = estransforms.transformNamedEvaluation(self:EmitContext(), node, estransforms.canIgnoreEmptyStringLiteralInAssignedName(bin.right), "")
            bin = node:AsBinaryExpression()
        end
        local assignmentTarget = self:visitDestructuringAssignmentTarget(bin.left)
        local initializer = self:Visitor():VisitNode(bin.right)
        return f:UpdateBinaryExpression(bin, nil, assignmentTarget, nil, bin.operatorToken, initializer)
    end
    return self:visitDestructuringAssignmentTarget(node)
end

function esDecoratorTransformer:visitAssignmentRestElement(node)
    local se = node:AsSpreadElement()
    if ast.IsLeftHandSideExpression(se.expression) then
        local f = self:Factory()
        local expression = self:visitDestructuringAssignmentTarget(se.expression)
        return f:UpdateSpreadElement(se, expression)
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitArrayAssignmentElement(node)
    debug.Assert(ast.IsArrayBindingOrAssignmentElement(node))
    if ast.IsSpreadElement(node) then
        return self:visitAssignmentRestElement(node)
    end
    if not ast.IsOmittedExpression(node) then
        return self:visitAssignmentElement(node)
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitAssignmentPropertyNode(node)
    -- AssignmentProperty : PropertyName `:` AssignmentElement
    -- AssignmentElement : DestructuringAssignmentTarget Initializer?

    -- 13.15.5.6 RS: KeyedDestructuringAssignmentEvaluation
    --   AssignmentElement : DestructuringAssignmentTarget Initializer?
    --     ...
    --     3. If |Initializer| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousfunctionDefinition(|Initializer|) and IsIdentifierRef of |DestructuringAssignmentTarget| are both *true*, then
    --           i. Let _rhsValue_ be ? NamedEvaluation of |Initializer| with argument _lref_.[[ReferencedName]].
    --     ...

    local f = self:Factory()
    local pa = node:AsPropertyAssignment()
    local name = self:Visitor():VisitNode(pa:Name())
    if ast.IsAssignmentExpression(pa.initializer, true) then
        local assignmentElement = self:visitAssignmentElement(pa.initializer)
        return f:UpdatePropertyAssignment(pa, nil, name, nil, nil, assignmentElement)
    end
    if ast.IsLeftHandSideExpression(pa.initializer) then
        local assignmentElement = self:visitDestructuringAssignmentTarget(pa.initializer)
        return f:UpdatePropertyAssignment(pa, nil, name, nil, nil, assignmentElement)
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitShorthandAssignmentProperty(node)
    -- AssignmentProperty : IdentifierReference Initializer?

    -- 13.15.5.3 RS: PropertyDestructuringAssignmentEvaluation
    --   AssignmentProperty : IdentifierReference Initializer?
    --     ...
    --     4. If |Initializer?| is present and _v_ is *undefined*, then
    --        a. If IsAnonymousFunctionDefinition(|Initializer|) is *true*, then
    --           i. Set _v_ to ? NamedEvaluation of |Initializer| with argument _P_.
    --     ...
    if estransforms.isNamedEvaluationAnd(self:EmitContext(), node, estransforms.isAnonymousClassNeedingAssignedName) then
        node = estransforms.transformNamedEvaluation(self:EmitContext(), node, estransforms.canIgnoreEmptyStringLiteralInAssignedName(node:AsShorthandPropertyAssignment().objectAssignmentInitializer), "")
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitAssignmentRestProperty(node)
    local sa = node:AsSpreadAssignment()
    if ast.IsLeftHandSideExpression(sa.expression) then
        local f = self:Factory()
        local expression = self:visitDestructuringAssignmentTarget(sa.expression)
        return f:UpdateSpreadAssignment(sa, expression)
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitObjectAssignmentElement(node)
    debug.Assert(ast.IsObjectBindingOrAssignmentElement(node))
    if ast.IsSpreadAssignment(node) then
        return self:visitAssignmentRestProperty(node)
    end
    if ast.IsShorthandPropertyAssignment(node) then
        return self:visitShorthandAssignmentProperty(node)
    end
    if ast.IsPropertyAssignment(node) then
        return self:visitAssignmentPropertyNode(node)
    end
    return self:Visitor():VisitEachChild(node)
end

function esDecoratorTransformer:visitAssignmentPattern(node)
    local f = self:Factory()
    if ast.IsArrayLiteralExpression(node) then
        local ale = node:AsArrayLiteralExpression()
        local elements = self.arrayAssignmentVisitor:VisitNodes(ale.elements)
        return f:UpdateArrayLiteralExpression(ale, elements, ale.multiLine)
    end
    local ole = node:AsObjectLiteralExpression()
    local properties = self.objectAssignmentVisitor:VisitNodes(ole.properties)
    return f:UpdateObjectLiteralExpression(ole, properties, ole.multiLine)
end

function esDecoratorTransformer:visitExportAssignment(node)
    -- 16.2.3.7 RS: Evaluation
    --   ExportDeclaration : `export` `default` AssignmentExpression `;`
    --     1. If IsAnonymousFunctionDefinition(|AssignmentExpression|) is *true*, then
    --        a. Let _value_ be ? NamedEvaluation of |AssignmentExpression| with argument `"default"`.
    --     ...
    return self:visitNamedEvaluationSite(node, node:Expression())
end

function esDecoratorTransformer:visitParenthesizedExpression(node, discarded)
    -- 8.4.5 RS: NamedEvaluation
    --   ParenthesizedExpression : `(` Expression `)`
    --     ...
    --     2. Return ? NamedEvaluation of |Expression| with argument _name_.

    local f = self:Factory()
    local pe = node:AsParenthesizedExpression()
    local expression
    if discarded then
        expression = self.discardedVisitor:VisitNode(pe.expression)
    else
        expression = self:Visitor():VisitNode(pe.expression)
    end
    return f:UpdateParenthesizedExpression(pe, expression)
end

function esDecoratorTransformer:visitPartiallyEmittedExpression(node, discarded)
    -- Emulates 8.4.5 RS: NamedEvaluation
    local pe = node:AsPartiallyEmittedExpression()
    local expression
    if discarded then
        expression = self.discardedVisitor:VisitNode(pe.expression)
    else
        expression = self:Visitor():VisitNode(pe.expression)
    end
    return self:Factory():UpdatePartiallyEmittedExpression(pe, expression)
end

-- prependExpressions prepends a list of expressions before a target expression, preserving
-- parenthesization. If expression is nil, the pending expressions are inlined alone.
function esDecoratorTransformer:prependExpressions(pending, expression)
    local f = self:Factory()
    if core.Len(pending) == 0 then
        return expression
    end
    if expression == nil then
        return f:InlineExpressions(pending)
    end
    if ast.IsParenthesizedExpression(expression) then
        local pe = expression:AsParenthesizedExpression()
        local exprs = appendAll({}, pending)
        exprs[#exprs + 1] = pe.expression
        return f:UpdateParenthesizedExpression(pe, f:InlineExpressions(exprs))
    end
    local exprs = appendAll({}, pending)
    exprs[#exprs + 1] = expression
    return f:InlineExpressions(exprs)
end

function esDecoratorTransformer:injectPendingExpressions(expression)
    local result = self:prependExpressions(self.pendingExpressions, expression)
    debug.Assert(result ~= nil)
    if result ~= expression then
        self.pendingExpressions = nil
    end
    return result
end

function esDecoratorTransformer:injectPendingInitializers(ci, isStatic, expression)
    local field
    if isStatic then
        field = "pendingStaticInitializers"
    else
        field = "pendingInstanceInitializers"
    end
    local result = self:prependExpressions(ci[field], expression)
    if result ~= expression then
        ci[field] = nil
    end
    return result
end

-- Transforms all of the decorators for a declaration into an array of expressions.
function esDecoratorTransformer:transformAllDecoratorsOfDeclaration(decorators)
    if core.Len(decorators) == 0 then
        return nil
    end
    local result = {}
    for _, d in ipairs(decorators) do
        result[#result + 1] = self:transformDecorator(d)
    end
    return result
end

-- Transforms a decorator into an expression.
function esDecoratorTransformer:transformDecorator(decorator)
    local expression = self:Visitor():VisitNode(decorator:AsDecorator().expression)
    self:EmitContext():SetEmitFlags(expression, EF.EFNoComments)

    -- preserve the 'this' binding for an access expression
    local innerExpression = ast.SkipOuterExpressions(expression, OEK.OEKAll)
    if ast.IsAccessExpression(innerExpression) then
        local target, thisArg = self:createCallBinding(expression)
        local bindCall = self:Factory():NewFunctionBindCall(target, thisArg, nil)
        return self:Factory():RestoreOuterExpressions(expression, bindCall, OEK.OEKAll)
    end
    return expression
end

-- Returns target, thisArg.
function esDecoratorTransformer:createCallBinding(expression)
    local f = self:Factory()
    local callee = ast.SkipOuterExpressions(expression, OEK.OEKAll)
    if ast.IsSuperProperty(callee) then
        return callee, f:NewThisExpression()
    end
    if callee.kind == Kind.SuperKeyword then
        return callee, f:NewThisExpression()
    end
    if self:EmitContext():EmitFlags(callee) & EF.EFHelperName ~= 0 then
        return callee, f:NewVoidZeroExpression()
    end
    if ast.IsPropertyAccessExpression(callee) then
        local pa = callee:AsPropertyAccessExpression()
        if self:shouldBeCapturedInTempVariable(pa.expression) then
            local thisArg = f:NewTempVariable()
            self:EmitContext():AddVariableDeclaration(thisArg)
            local assign = f:NewAssignmentExpression(thisArg, pa.expression)
            assign.loc = pa.expression.loc
            local target = f:NewPropertyAccessExpression(assign, nil, pa:Name(), NodeFlags.None)
            target.loc = callee.loc
            return target, thisArg
        end
        return callee, pa.expression
    end
    if ast.IsElementAccessExpression(callee) then
        local ea = callee:AsElementAccessExpression()
        if self:shouldBeCapturedInTempVariable(ea.expression) then
            local thisArg = f:NewTempVariable()
            self:EmitContext():AddVariableDeclaration(thisArg)
            local assign = f:NewAssignmentExpression(thisArg, ea.expression)
            assign.loc = ea.expression.loc
            local target = f:NewElementAccessExpression(assign, nil, ea.argumentExpression, NodeFlags.None)
            target.loc = callee.loc
            return target, thisArg
        end
        return callee, ea.expression
    end
    return expression, f:NewVoidZeroExpression()
end

function esDecoratorTransformer:shouldBeCapturedInTempVariable(node)
    -- This is a simplified version of the general shouldBeCapturedInTempVariable from
    -- nodeFactory with cacheIdentifiers=true, since createCallBinding in this transform
    -- always caches identifiers.
    local target = ast.SkipParentheses(node)
    local k = target.kind
    if k == Kind.Identifier then
        -- cacheIdentifiers is always true for this transform's createCallBinding
        return true
    elseif k == Kind.ThisKeyword or
        k == Kind.NumericLiteral or
        k == Kind.BigIntLiteral or
        k == Kind.StringLiteral then
        return false
    else
        return true
    end
end

-- Creates a "value", "get", or "set" method for a pseudo-PropertyDescriptor object created for
-- a private element.
function esDecoratorTransformer:createDescriptorMethod(original, name, modifiers, asteriskToken, kind, parameters, body)
    local f = self:Factory()
    local ec = self:EmitContext()

    if body == nil then
        body = f:NewBlock(f:NewNodeList({}), false)
    end

    local funcExpr = f:NewFunctionExpression(
        modifiers,
        asteriskToken,
        nil, -- name
        nil, -- typeParameters
        parameters,
        nil, -- type
        nil, -- fullSignature
        body
    )
    ec:SetOriginal(funcExpr, original)
    ec:SetSourceMapRange(funcExpr, transformers.MoveRangePastDecorators(original))
    ec:SetEmitFlags(funcExpr, EF.EFNoComments)

    local prefix = ""
    if kind == "get" or kind == "set" then
        prefix = kind
    end
    local functionName = f:NewStringLiteralFromNode(name)
    local namedFunction = f:NewSetFunctionNameHelper(funcExpr, functionName, prefix)

    local method = f:NewPropertyAssignment(nil, f:NewIdentifier(kind), nil, nil, namedFunction)
    ec:SetOriginal(method, original)
    ec:SetSourceMapRange(method, transformers.MoveRangePastDecorators(original))
    ec:SetEmitFlags(method, EF.EFNoComments)
    return method
end

-- Creates a pseudo-PropertyDescriptor object used when decorating a private MethodDeclaration.
function esDecoratorTransformer:createMethodDescriptorObject(member, modifiers)
    local f = self:Factory()
    local parameters = self:Visitor():VisitNodes(member:ParameterList())
    local body = self:Visitor():VisitNode(member:Body())
    local method = member:AsMethodDeclaration()
    return f:NewObjectLiteralExpression(
        f:NewNodeList({
            self:createDescriptorMethod(member, member:Name(), modifiers, method.asteriskToken, "value", parameters, body),
        }),
        false
    )
end

-- Creates a pseudo-PropertyDescriptor object used when decorating a private GetAccessor.
function esDecoratorTransformer:createGetAccessorDescriptorObject(member, modifiers)
    local f = self:Factory()
    local body = self:Visitor():VisitNode(member:Body())
    return f:NewObjectLiteralExpression(
        f:NewNodeList({
            self:createDescriptorMethod(member, member:Name(), modifiers, nil, "get", f:NewNodeList({}), body),
        }),
        false
    )
end

-- Creates a pseudo-PropertyDescriptor object used when decorating a private SetAccessor.
function esDecoratorTransformer:createSetAccessorDescriptorObject(member, modifiers)
    local f = self:Factory()
    local parameters = self:Visitor():VisitNodes(member:ParameterList())
    local body = self:Visitor():VisitNode(member:Body())
    return f:NewObjectLiteralExpression(
        f:NewNodeList({
            self:createDescriptorMethod(member, member:Name(), modifiers, nil, "set", parameters, body),
        }),
        false
    )
end

-- Creates a pseudo-PropertyDescriptor object used when decorating a private auto-accessor PropertyDeclaration.
-- The descriptor contains get/set methods that access the generated backing field.
function esDecoratorTransformer:createAccessorPropertyDescriptorObject(member, _)
    --  {
    --      get() { return this.${privateName}; },
    --      set(value) { this.${privateName} = value; },
    --  }
    local f = self:Factory()
    local backingFieldName = f:NewGeneratedPrivateNameForNodeEx(member:Name(), { flags = 0, prefix = "", suffix = "_accessor_storage" })
    return f:NewObjectLiteralExpression(
        f:NewNodeList({
            self:createDescriptorMethod(
                member, member:Name(), nil, nil, "get",
                f:NewNodeList({}),
                f:NewBlock(f:NewNodeList({
                    f:NewReturnStatement(
                        f:NewPropertyAccessExpression(f:NewThisExpression(), nil, backingFieldName, NodeFlags.None)
                    ),
                }), false)
            ),
            self:createDescriptorMethod(
                member, member:Name(), nil, nil, "set",
                f:NewNodeList({
                    f:NewParameterDeclaration(nil, nil, f:NewIdentifier("value"), nil, nil, nil),
                }),
                f:NewBlock(f:NewNodeList({
                    f:NewExpressionStatement(
                        f:NewAssignmentExpression(
                            f:NewPropertyAccessExpression(f:NewThisExpression(), nil, backingFieldName, NodeFlags.None),
                            f:NewIdentifier("value")
                        )
                    ),
                }), false)
            ),
        }),
        false
    )
end

-- Creates a MethodDeclaration that forwards its invocation to a PropertyDescriptor object.
function esDecoratorTransformer:createMethodDescriptorForwarder(modifiers, name, descriptorName)
    local f = self:Factory()
    local staticOnly = self.staticOnlyModifierVisitor:VisitModifiers(modifiers)
    return f:NewGetAccessorDeclaration(
        staticOnly,
        name,
        nil, -- typeParameters
        f:NewNodeList({}),
        nil, -- type
        nil, -- fullSignature
        f:NewBlock(f:NewNodeList({
            f:NewReturnStatement(
                f:NewPropertyAccessExpression(descriptorName, nil, f:NewIdentifier("value"), NodeFlags.None)
            ),
        }), false)
    )
end

-- Creates a GetAccessor that forwards its invocation to a PropertyDescriptor object.
function esDecoratorTransformer:createGetAccessorDescriptorForwarder(modifiers, name, descriptorName)
    local f = self:Factory()
    local staticOnly = self.staticOnlyModifierVisitor:VisitModifiers(modifiers)
    return f:NewGetAccessorDeclaration(
        staticOnly,
        name,
        nil, -- typeParameters
        f:NewNodeList({}),
        nil, -- type
        nil, -- fullSignature
        f:NewBlock(f:NewNodeList({
            f:NewReturnStatement(
                f:NewFunctionCallCall(
                    f:NewPropertyAccessExpression(descriptorName, nil, f:NewIdentifier("get"), NodeFlags.None),
                    f:NewThisExpression(),
                    nil
                )
            ),
        }), false)
    )
end

-- Creates a SetAccessor that forwards its invocation to a PropertyDescriptor object.
function esDecoratorTransformer:createSetAccessorDescriptorForwarder(modifiers, name, descriptorName)
    local f = self:Factory()
    local staticOnly = self.staticOnlyModifierVisitor:VisitModifiers(modifiers)
    return f:NewSetAccessorDeclaration(
        staticOnly,
        name,
        nil, -- typeParameters
        f:NewNodeList({
            f:NewParameterDeclaration(nil, nil, f:NewIdentifier("value"), nil, nil, nil),
        }),
        nil, -- type
        nil, -- fullSignature
        f:NewBlock(f:NewNodeList({
            f:NewReturnStatement(
                f:NewFunctionCallCall(
                    f:NewPropertyAccessExpression(descriptorName, nil, f:NewIdentifier("set"), NodeFlags.None),
                    f:NewThisExpression(),
                    { f:NewIdentifier("value") }
                )
            ),
        }), false)
    )
end

function esDecoratorTransformer:createMetadata(name, classSuper)
    local f = self:Factory()

    local superMetadata
    if classSuper ~= nil then
        superMetadata = self:createSymbolMetadataReference(classSuper)
    else
        superMetadata = f:NewToken(Kind.NullKeyword)
    end

    local objectCreate = f:NewCallExpression(
        f:NewPropertyAccessExpression(f:NewIdentifier("Object"), nil, f:NewIdentifier("create"), NodeFlags.None),
        nil, nil,
        f:NewNodeList({ superMetadata }),
        NodeFlags.None
    )

    local symbolCheck = f:NewLogicalANDExpression(
        f:NewTypeCheck(f:NewIdentifier("Symbol"), "function"),
        f:NewPropertyAccessExpression(f:NewIdentifier("Symbol"), nil, f:NewIdentifier("metadata"), NodeFlags.None)
    )

    local conditional = f:NewConditionalExpression(
        symbolCheck,
        f:NewToken(Kind.QuestionToken),
        objectCreate,
        f:NewToken(Kind.ColonToken),
        f:NewVoidZeroExpression()
    )

    local varDecl = f:NewVariableDeclaration(name, nil, nil, conditional)
    local varDeclList = f:NewVariableDeclarationList(f:NewNodeList({ varDecl }), NodeFlags.Const)
    return f:NewVariableStatement(nil, varDeclList)
end

function esDecoratorTransformer:createSymbolMetadata(target, value)
    local f = self:Factory()

    -- Object.defineProperty(target, Symbol.metadata, { configurable: true, writable: true, enumerable: true, value })
    local symbolMetadata = f:NewPropertyAccessExpression(f:NewIdentifier("Symbol"), nil, f:NewIdentifier("metadata"), NodeFlags.None)

    local descriptorProps = {
        f:NewPropertyAssignment(nil, f:NewIdentifier("enumerable"), nil, nil, f:NewTrueExpression()),
        f:NewPropertyAssignment(nil, f:NewIdentifier("configurable"), nil, nil, f:NewTrueExpression()),
        f:NewPropertyAssignment(nil, f:NewIdentifier("writable"), nil, nil, f:NewTrueExpression()),
        f:NewPropertyAssignment(nil, f:NewIdentifier("value"), nil, nil, value),
    }
    local descriptor = f:NewObjectLiteralExpression(f:NewNodeList(descriptorProps), false)

    local defineProperty = f:NewCallExpression(
        f:NewPropertyAccessExpression(f:NewIdentifier("Object"), nil, f:NewIdentifier("defineProperty"), NodeFlags.None),
        nil, nil,
        f:NewNodeList({ target, symbolMetadata, descriptor }),
        NodeFlags.None
    )

    local ifStatement = f:NewIfStatement(value, f:NewExpressionStatement(defineProperty), nil)
    self:EmitContext():SetEmitFlags(ifStatement, EF.EFSingleLine)
    return ifStatement
end

function esDecoratorTransformer:createSymbolMetadataReference(classSuper)
    local f = self:Factory()
    local symbolMetadata = f:NewPropertyAccessExpression(f:NewIdentifier("Symbol"), nil, f:NewIdentifier("metadata"), NodeFlags.None)
    local elementAccess = f:NewElementAccessExpression(classSuper, nil, symbolMetadata, NodeFlags.None)
    return f:NewBinaryExpression(nil, elementAccess, nil, f:NewToken(Kind.QuestionQuestionToken), f:NewToken(Kind.NullKeyword))
end

function estransforms.injectClassThisAssignmentIfMissing(ec, f, node, classThis)
    if estransforms.classHasClassThisAssignment(ec, node) then
        return node
    end

    -- Create: static { _classThis = this; }
    local expression = f:NewAssignmentExpression(classThis, f:NewThisExpression())
    local statement = f:NewExpressionStatement(expression)
    local body = f:NewBlock(f:NewNodeList({ statement }), false)
    local staticBlock = f:NewClassStaticBlockDeclaration(nil, body)
    ec:SetClassThis(staticBlock, classThis)

    if node:Name() ~= nil then
        ec:SetSourceMapRange(statement, node:Name().loc)
    end

    local newMembers = { staticBlock }
    appendAll(newMembers, node:Members())
    local membersList = f:NewNodeList(newMembers)
    membersList.loc = node:MemberList().loc

    local updatedNode
    if ast.IsClassDeclaration(node) then
        local cd = node:AsClassDeclaration()
        updatedNode = f:UpdateClassDeclaration(cd, cd:Modifiers(), cd:Name(), nil, cd.heritageClauses, membersList)
    else
        local ce = node:AsClassExpression()
        updatedNode = f:UpdateClassExpression(ce, ce:Modifiers(), ce:Name(), nil, ce.heritageClauses, membersList)
    end
    ec:SetClassThis(updatedNode, classThis)
    return updatedNode
end
