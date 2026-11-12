local tstransforms = require("tslua.transformers.tstransforms")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags

local TypeEraserTransformer = transformers.NewTransformerType()
tstransforms.TypeEraserTransformer = TypeEraserTransformer

function tstransforms.NewTypeEraserTransformer(opt)
    local compilerOptions = opt.compilerOptions
    local emitContext = opt.context
    local tx = setmetatable({ compilerOptions = compilerOptions, parentNode = nil, currentNode = nil }, TypeEraserTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
end

-- Pushes a new child node onto the ancestor tracking stack, returning the grandparent node to be restored later via `popNode`.
function TypeEraserTransformer:pushNode(node)
    local grandparentNode = self.parentNode
    self.parentNode = self.currentNode
    self.currentNode = node
    return grandparentNode
end

-- Pops the last child node off the ancestor tracking stack, restoring the grandparent node.
function TypeEraserTransformer:popNode(grandparentNode)
    self.currentNode = self.parentNode
    self.parentNode = grandparentNode
end

function TypeEraserTransformer:elide(node)
    return self:EmitContext():NewNotEmittedStatement(node:AsNode())
end

local elidedKinds = ast.kindSet(
    -- TypeScript accessibility and readonly modifiers are elided
    Kind.PublicKeyword,
    Kind.PrivateKeyword,
    Kind.ProtectedKeyword,
    Kind.AbstractKeyword,
    Kind.OverrideKeyword,
    Kind.ConstKeyword,
    Kind.DeclareKeyword,
    Kind.ReadonlyKeyword,
    -- TypeScript type nodes are elided.
    Kind.ArrayType,
    Kind.TupleType,
    Kind.OptionalType,
    Kind.RestType,
    Kind.TypeLiteral,
    Kind.TypePredicate,
    Kind.TypeParameter,
    Kind.AnyKeyword,
    Kind.UnknownKeyword,
    Kind.BooleanKeyword,
    Kind.StringKeyword,
    Kind.NumberKeyword,
    Kind.NeverKeyword,
    Kind.VoidKeyword,
    Kind.SymbolKeyword,
    Kind.ConstructorType,
    Kind.FunctionType,
    Kind.TypeQuery,
    Kind.TypeReference,
    Kind.UnionType,
    Kind.IntersectionType,
    Kind.ConditionalType,
    Kind.ParenthesizedType,
    Kind.ThisType,
    Kind.TypeOperator,
    Kind.IndexedAccessType,
    Kind.MappedType,
    Kind.LiteralType,
    -- TypeScript index signatures are elided.
    Kind.IndexSignature
)

-- The body of Go's visit switch (after pushNode; Go defers popNode).
local function visitWorker(tx, node)
    local kind = node.kind
    if elidedKinds[kind] then
        return nil
    elseif kind == Kind.InKeyword or kind == Kind.OutKeyword then
        -- TypeScript `in`/`out` variance modifiers are elided. These keywords are only
        -- meaningful as modifiers on type parameters (which are themselves elided), but they may
        -- appear as a grammar error on other declarations and must not leak into the emitted JS.
        -- The `in` binary operator shares this token kind, so only elide when used as a modifier.
        if tx.parentNode == nil or not ast.IsBinaryExpression(tx.parentNode) then
            return nil
        end
        return tx:Visitor():VisitEachChild(node)
    elseif kind == Kind.JSImportDeclaration then
        -- reparsed commonjs are elided
        return nil
    elseif kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration or kind == Kind.InterfaceDeclaration then
        -- TypeScript type-only declarations are elided.
        return tx:elide(node)
    elseif kind == Kind.NamespaceExportDeclaration then
        -- TypeScript namespace export declarations are elided.
        return nil
    elseif kind == Kind.ModuleDeclaration then
        if not ast.IsIdentifier(node:Name()) or
            not ast.IsInstantiatedModule(node, tx.compilerOptions:ShouldPreserveConstEnums()) or
            tstransforms.getInnermostModuleDeclarationFromDottedModule(node:AsModuleDeclaration()).body == nil then
            -- TypeScript module declarations are elided if they are not instantiated or have no body
            return tx:elide(node)
        end
        return tx:Visitor():VisitEachChild(node)
    elseif kind == Kind.ExpressionWithTypeArguments then
        local n = node:AsExpressionWithTypeArguments()
        return tx:Factory():UpdateExpressionWithTypeArguments(n, tx:Visitor():VisitNode(n.expression), nil)
    elseif kind == Kind.PropertyDeclaration then
        if core.Tristate_IsTrue(tx.compilerOptions.experimentalDecorators) and ast.HasSyntacticModifier(node, ModifierFlags.Ambient | ModifierFlags.Abstract) and ast.HasDecorators(node) then
            -- declare/abstract props with decorators must be preserved until the decorator transform can process them and remove them
            local n = node:AsPropertyDeclaration()
            return tx:Factory():UpdatePropertyDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), tx:Visitor():VisitNode(n:Name()), nil, nil, tx:Visitor():VisitNode(n.initializer))
        end
        if ast.HasSyntacticModifier(node, ModifierFlags.Ambient | ModifierFlags.Abstract) then
            -- TypeScript `declare` fields are elided
            return nil
        end
        local n = node:AsPropertyDeclaration()
        return tx:Factory():UpdatePropertyDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), tx:Visitor():VisitNode(n:Name()), nil, nil, tx:Visitor():VisitNode(n.initializer))
    elseif kind == Kind.Constructor then
        local n = node:AsConstructorDeclaration()
        if ast.NodeIsMissing(n.body) then
            -- TypeScript overloads are elided
            return nil
        end
        return tx:Factory():UpdateConstructorDeclaration(n, nil, nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, tx:Visitor():VisitNode(n.body))
    elseif kind == Kind.MethodDeclaration then
        local n = node:AsMethodDeclaration()
        if ast.NodeIsMissing(n.body) then
            -- TypeScript overloads are elided
            return nil
        end
        return tx:Factory():UpdateMethodDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), n.asteriskToken, tx:Visitor():VisitNode(n:Name()), nil, nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, tx:Visitor():VisitNode(n.body))
    elseif kind == Kind.GetAccessor then
        local n = node:AsGetAccessorDeclaration()
        if ast.NodeIsMissing(n.body) and ast.HasSyntacticModifier(node, ModifierFlags.Abstract) then
            -- Abstract accessors are elided
            return nil
        end
        local body = tx:Visitor():VisitNode(n.body)
        if body == nil then
            body = tx:Factory():NewBlock(tx:Factory():NewNodeList(nil), false)
        end
        return tx:Factory():UpdateGetAccessorDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), tx:Visitor():VisitNode(n:Name()), nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, body)
    elseif kind == Kind.SetAccessor then
        local n = node:AsSetAccessorDeclaration()
        if ast.NodeIsMissing(n.body) and ast.HasSyntacticModifier(node, ModifierFlags.Abstract) then
            -- Abstract accessors are elided
            return nil
        end
        local body = tx:Visitor():VisitNode(n.body)
        if body == nil then
            body = tx:Factory():NewBlock(tx:Factory():NewNodeList(nil), false)
        end
        return tx:Factory():UpdateSetAccessorDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), tx:Visitor():VisitNode(n:Name()), nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, body)
    elseif kind == Kind.VariableDeclaration then
        local n = node:AsVariableDeclaration()
        local updated = tx:Factory():UpdateVariableDeclaration(n, tx:Visitor():VisitNode(n:Name()), nil, nil, tx:Visitor():VisitNode(n.initializer))
        if n.type ~= nil then
            tx:EmitContext():SetTypeNode(updated:AsVariableDeclaration():Name(), n.type)
        end
        return updated
    elseif kind == Kind.HeritageClause then
        local n = node:AsHeritageClause()
        if n.token == Kind.ImplementsKeyword then
            -- TypeScript `implements` clauses are elided
            return nil
        end
        return tx:Factory():UpdateHeritageClause(n, n.token, tx:Visitor():VisitNodes(n.types))
    elseif kind == Kind.ClassDeclaration then
        local n = node:AsClassDeclaration()
        return tx:Factory():UpdateClassDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), tx:Visitor():VisitNode(n:Name()), nil, tx:Visitor():VisitNodes(n.heritageClauses), tx:Visitor():VisitNodes(n.members))
    elseif kind == Kind.ClassExpression then
        local n = node:AsClassExpression()
        return tx:Factory():UpdateClassExpression(n, tx:Visitor():VisitModifiers(n:Modifiers()), tx:Visitor():VisitNode(n:Name()), nil, tx:Visitor():VisitNodes(n.heritageClauses), tx:Visitor():VisitNodes(n.members))
    elseif kind == Kind.FunctionDeclaration then
        local n = node:AsFunctionDeclaration()
        if ast.NodeIsMissing(n.body) then
            -- TypeScript overloads are elided
            return tx:elide(node)
        end
        return tx:Factory():UpdateFunctionDeclaration(n, tx:Visitor():VisitModifiers(n:Modifiers()), n.asteriskToken, tx:Visitor():VisitNode(n:Name()), nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, tx:Visitor():VisitNode(n.body))
    elseif kind == Kind.FunctionExpression then
        local n = node:AsFunctionExpression()
        return tx:Factory():UpdateFunctionExpression(n, tx:Visitor():VisitModifiers(n:Modifiers()), n.asteriskToken, tx:Visitor():VisitNode(n:Name()), nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, tx:Visitor():VisitNode(n.body))
    elseif kind == Kind.ArrowFunction then
        local n = node:AsArrowFunction()
        return tx:Factory():UpdateArrowFunction(n, tx:Visitor():VisitModifiers(n:Modifiers()), nil, tx:Visitor():VisitNodes(n.parameters), nil, nil, n.equalsGreaterThanToken, tx:Visitor():VisitNode(n.body))
    elseif kind == Kind.Parameter then
        if ast.IsThisParameter(node) then
            -- TypeScript `this` parameters are elided
            return nil
        end
        local n = node:AsParameterDeclaration()
        -- preserve parameter property modifiers to be handled by the runtime transformer
        local modifiers
        if ast.IsParameterPropertyDeclaration(node, tx.parentNode) then
            modifiers = transformers.ExtractModifiers(tx:EmitContext(), n:Modifiers(), ModifierFlags.ParameterPropertyModifier)
        end
        -- preserve decorators for the decorator transforms
        if ast.HasDecorators(node) then
            local decorators = node:Decorators()
            local visited = tx:Visitor():VisitSlice(decorators)
            if modifiers == nil then
                modifiers = tx:Factory():NewModifierList(visited)
            else
                modifiers = tx:Factory():NewModifierList(core.AppendAll(core.AppendAll({}, modifiers.nodes), visited))
            end
        end
        return tx:Factory():UpdateParameterDeclaration(n, modifiers, n.dotDotDotToken, tx:Visitor():VisitNode(n:Name()), nil, nil, tx:Visitor():VisitNode(n.initializer))
    elseif kind == Kind.CallExpression then
        local n = node:AsCallExpression()
        return tx:Factory():UpdateCallExpression(n, tx:Visitor():VisitNode(n.expression), n.questionDotToken, nil, tx:Visitor():VisitNodes(n.arguments), n.flags)
    elseif kind == Kind.NewExpression then
        local n = node:AsNewExpression()
        return tx:Factory():UpdateNewExpression(n, tx:Visitor():VisitNode(n.expression), nil, tx:Visitor():VisitNodes(n.arguments))
    elseif kind == Kind.TaggedTemplateExpression then
        local n = node:AsTaggedTemplateExpression()
        return tx:Factory():UpdateTaggedTemplateExpression(n, tx:Visitor():VisitNode(n.tag), n.questionDotToken, nil, tx:Visitor():VisitNode(n.template), n.flags)
    elseif kind == Kind.NonNullExpression or kind == Kind.TypeAssertionExpression or kind == Kind.AsExpression or kind == Kind.SatisfiesExpression then
        local partial = tx:Factory():NewPartiallyEmittedExpression(tx:Visitor():VisitNode(node:Expression()))
        tx:EmitContext():SetOriginal(partial, node)
        partial.loc = node.loc
        return partial
    elseif kind == Kind.ParenthesizedExpression then
        if not ast.IsJSDocTypeAssertion(node) then
            local n = node:AsParenthesizedExpression()
            local expression = ast.SkipOuterExpressions(n.expression, ast.OuterExpressionKinds.OEKAllExceptAssertionsOrExpressionsWithTypeArguments)
            if ast.IsAssertionExpression(expression) or ast.IsSatisfiesExpression(expression) then
                local partial = tx:Factory():NewPartiallyEmittedExpression(tx:Visitor():VisitNode(n.expression))
                tx:EmitContext():SetOriginal(partial, node)
                partial.loc = node.loc
                return partial
            end
        end
        return tx:Visitor():VisitEachChild(node)
    elseif kind == Kind.JsxSelfClosingElement then
        local n = node:AsJsxSelfClosingElement()
        return tx:Factory():UpdateJsxSelfClosingElement(n, tx:Visitor():VisitNode(n.tagName), nil, tx:Visitor():VisitNode(n.attributes))
    elseif kind == Kind.JsxOpeningElement then
        local n = node:AsJsxOpeningElement()
        return tx:Factory():UpdateJsxOpeningElement(n, tx:Visitor():VisitNode(n.tagName), nil, tx:Visitor():VisitNode(n.attributes))
    elseif kind == Kind.ImportEqualsDeclaration then
        local n = node:AsImportEqualsDeclaration()
        if n.isTypeOnly then
            -- elide type-only imports
            return nil
        end
        return tx:Visitor():VisitEachChild(node)
    elseif kind == Kind.ImportDeclaration then
        local n = node:AsImportDeclaration()
        if n.importClause == nil then
            -- Do not elide a side-effect only import declaration.
            --  import "foo";
            return node
        end
        local importClause = tx:Visitor():VisitNode(n.importClause)
        if importClause == nil then
            return nil
        end
        return tx:Factory():UpdateImportDeclaration(n, n:Modifiers(), importClause, n.moduleSpecifier, n.attributes)
    elseif kind == Kind.ImportClause then
        local n = node:AsImportClause()
        if n:IsTypeOnly() then
            -- Always elide type-only imports
            return nil
        end
        local name = n:Name()
        local namedBindings = tx:Visitor():VisitNode(n.namedBindings)
        if name == nil and namedBindings == nil then
            -- all import bindings were elided
            return nil
        end
        return tx:Factory():UpdateImportClause(n, n.phaseModifier, name, namedBindings)
    elseif kind == Kind.NamedImports then
        local n = node:AsNamedImports()
        if core.Len(n.elements.nodes) == 0 then
            -- Do not elide a side-effect only import declaration.
            return node
        end
        local elements = tx:Visitor():VisitNodes(n.elements)
        if not core.Tristate_IsTrue(tx.compilerOptions.verbatimModuleSyntax) and core.Len(elements.nodes) == 0 then
            -- all import specifiers were elided
            return nil
        end
        return tx:Factory():UpdateNamedImports(n, elements)
    elseif kind == Kind.ImportSpecifier then
        local n = node:AsImportSpecifier()
        if n.isTypeOnly then
            -- elide type-only or unused imports
            return nil
        end
        return node
    elseif kind == Kind.ExportDeclaration then
        local n = node:AsExportDeclaration()
        if n.isTypeOnly then
            -- elide type-only exports
            return nil
        end
        local exportClause
        if n.exportClause ~= nil then
            exportClause = tx:Visitor():VisitNode(n.exportClause)
            if exportClause == nil then
                -- all export bindings were elided
                return nil
            end
        end
        return tx:Factory():UpdateExportDeclaration(n, nil --[[modifiers]], false --[[isTypeOnly]], exportClause, tx:Visitor():VisitNode(n.moduleSpecifier), tx:Visitor():VisitNode(n.attributes))
    elseif kind == Kind.NamedExports then
        local n = node:AsNamedExports()
        if core.Len(n.elements.nodes) == 0 then
            -- Do not elide an empty export declaration.
            return node
        end

        local elements = tx:Visitor():VisitNodes(n.elements)
        if not core.Tristate_IsTrue(tx.compilerOptions.verbatimModuleSyntax) and core.Len(elements.nodes) == 0 then
            -- all export specifiers were elided
            return nil
        end
        return tx:Factory():UpdateNamedExports(n, elements)
    elseif kind == Kind.ExportSpecifier then
        local n = node:AsExportSpecifier()
        if n.isTypeOnly then
            -- elide unused export
            return nil
        end
        return node
    elseif kind == Kind.EnumDeclaration then
        if ast.IsEnumConst(node) then
            return node
        end
        return tx:Visitor():VisitEachChild(node)
    else
        return tx:Visitor():VisitEachChild(node)
    end
end

function TypeEraserTransformer:visit(node)
    if node:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsTypeScript == 0 then
        return node
    end

    if ast.IsStatement(node) and ast.HasSyntacticModifier(node, ModifierFlags.Ambient) then
        return self:elide(node)
    end

    local grandparentNode = self:pushNode(node)
    local result = visitWorker(self, node)
    self:popNode(grandparentNode)
    return result
end
