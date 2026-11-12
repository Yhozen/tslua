local declarations = require("tslua.transformers.declarations")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags

function declarations.needsScopeMarker(result)
    return not ast.IsAnyImportOrReExport(result) and not ast.IsExportAssignment(result) and not ast.HasSyntacticModifier(result, ModifierFlags.Export) and not ast.IsAmbientModule(result)
end

function declarations.canHaveLiteralInitializer(host, node)
    local kind = node.kind
    if kind == Kind.PropertyDeclaration or kind == Kind.PropertySignature then
        return host:GetEffectiveDeclarationFlags(node, ModifierFlags.Private) == 0
    elseif kind == Kind.Parameter or kind == Kind.VariableDeclaration then
        return true
    end
    return false
end

function declarations.canProduceDiagnostics(node)
    return ast.IsVariableDeclaration(node) or
        ast.IsPropertyDeclaration(node) or
        ast.IsPropertySignatureDeclaration(node) or
        ast.IsBindingElement(node) or
        ast.IsSetAccessorDeclaration(node) or
        ast.IsGetAccessorDeclaration(node) or
        ast.IsConstructSignatureDeclaration(node) or
        ast.IsCallSignatureDeclaration(node) or
        ast.IsMethodDeclaration(node) or
        ast.IsMethodSignatureDeclaration(node) or
        ast.IsFunctionDeclaration(node) or
        ast.IsParameterDeclaration(node) or
        ast.IsTypeParameterDeclaration(node) or
        ast.IsExpressionWithTypeArguments(node) or
        ast.IsImportEqualsDeclaration(node) or
        ast.IsTypeAliasDeclaration(node) or
        ast.IsJSTypeAliasDeclaration(node) or
        ast.IsConstructorDeclaration(node) or
        ast.IsIndexSignatureDeclaration(node) or
        ast.IsPropertyAccessExpression(node) or
        ast.IsElementAccessExpression(node) or
        ast.IsBinaryExpression(node) or
        ast.IsCallExpression(node) -- || // !!! TODO: JSDoc support
    -- ast.IsJSDocTypeAlias(node);
end

function declarations.canReuseModifierNodes(nodes)
    for _, node in ipairs(nodes or {}) do
        if ast.IsModifier(node) and node.flags & NodeFlags.Reparsed ~= 0 then
            return false
        end
    end
    return true
end

local declarationAndNotVisibleKinds = ast.kindSet(
    Kind.FunctionDeclaration,
    Kind.ModuleDeclaration,
    Kind.InterfaceDeclaration,
    Kind.ClassDeclaration,
    Kind.TypeAliasDeclaration,
    Kind.JSTypeAliasDeclaration,
    Kind.EnumDeclaration
)

local alwaysVisibleKinds = ast.kindSet(
    Kind.ImportEqualsDeclaration,
    Kind.ImportDeclaration,
    Kind.JSImportDeclaration,
    Kind.ExportDeclaration,
    Kind.ExportAssignment
)

function declarations.isDeclarationAndNotVisible(emitContext, resolver, node)
    node = emitContext:ParseNode(node)
    local kind = node.kind
    if declarationAndNotVisibleKinds[kind] then
        return not resolver:IsDeclarationVisible(node)
    -- The following should be doing their own visibility checks based on filtering their members
    elseif kind == Kind.VariableDeclaration then
        return not declarations.getBindingNameVisible(resolver, node)
    elseif alwaysVisibleKinds[kind] then
        return false
    elseif kind == Kind.ClassStaticBlockDeclaration then
        return true
    end
    return false
end

function declarations.getBindingNameVisible(resolver, elem)
    if ast.IsOmittedExpression(elem) then
        return false
    end
    -- TODO: parseArrayBindingElement _never_ parses out an OmittedExpression anymore, instead producing a nameless binding element
    -- Audit if OmittedExpression should be removed
    if elem:Name() == nil then
        return false
    end
    if ast.IsBindingPattern(elem:Name()) then
        -- If any child binding pattern element has been marked visible (usually by collect linked aliases), then this is visible
        for _, e in ipairs(elem:Name():Elements() or {}) do
            if declarations.getBindingNameVisible(resolver, e) then
                return true
            end
        end
        return false
    else
        return resolver:IsDeclarationVisible(elem)
    end
end

function declarations.isEnclosingDeclaration(node)
    return ast.IsSourceFile(node) or
        ast.IsTypeAliasDeclaration(node) or
        ast.IsJSTypeAliasDeclaration(node) or
        ast.IsModuleDeclaration(node) or
        ast.IsClassDeclaration(node) or
        ast.IsInterfaceDeclaration(node) or
        ast.IsFunctionLike(node) or
        ast.IsIndexSignatureDeclaration(node) or
        ast.IsMappedTypeNode(node) or
        ast.IsVariableDeclaration(node)
end

function declarations.isAlwaysType(node)
    if node.kind == Kind.InterfaceDeclaration then
        return true
    end
    return false
end

function declarations.maskModifierFlags(node, modifierMask, modifierAdditions)
    local flags = (ast.GetCombinedModifierFlags(node) & modifierMask) | modifierAdditions
    if flags & ModifierFlags.Default ~= 0 and (flags & ModifierFlags.Export == 0) then
        -- A non-exported default is a nonsequitor - we usually try to remove all export modifiers
        -- from statements in ambient declarations; but a default export must retain its export modifier to be syntactically valid
        flags = flags ~ ModifierFlags.Export
    end
    if flags & ModifierFlags.Default ~= 0 and flags & ModifierFlags.Ambient ~= 0 then
        flags = flags ~ ModifierFlags.Ambient -- `declare` is never required alongside `default` (and would be an error if printed)
    end
    return flags
end

function declarations.unwrapParenthesizedExpression(o)
    while o.kind == Kind.ParenthesizedExpression do
        o = o:Expression()
    end
    return o
end

function declarations.isPrivateMethodTypeParameter(host, node)
    return node.parent.kind == Kind.MethodDeclaration and host:GetEffectiveDeclarationFlags(node.parent, ModifierFlags.Private) ~= 0
end

-- Returns true if expando properties should be emitted for this function.
-- Properties are emitted if any overload in the symbol has a body (implementation).
function declarations.shouldEmitFunctionProperties(input)
    if input.body ~= nil then
        return true
    end
    return not core.Every(input.symbol.declarations, function(decl)
        return not ast.IsFunctionDeclaration(decl) or decl:AsFunctionDeclaration().body == nil
    end)
end

function declarations.getEffectiveBaseTypeNode(node)
    local baseType = ast.GetClassExtendsHeritageElement(node)
    -- !!! TODO: JSDoc support
    -- if (baseType && isInJSFile(node)) {
    --     // Prefer an @augments tag because it may have type parameters.
    --     const tag = getJSDocAugmentsTag(node);
    --     if (tag) {
    --         return tag.class;
    --     }
    -- }
    return baseType
end

function declarations.isScopeMarker(node)
    return ast.IsExportAssignment(node) or ast.IsExportDeclaration(node)
end

function declarations.hasScopeMarker(statements)
    if statements == nil then
        return false
    end
    return core.Some(statements.nodes, declarations.isScopeMarker)
end
