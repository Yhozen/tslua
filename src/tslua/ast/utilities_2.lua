local ast = require("tslua.ast")
local core = require("tslua.core")
local tspath = require("tslua.tspath")
local debug = require("tslua.debug")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SymbolFlags = ast.SymbolFlags
local TokenFlags = ast.TokenFlags
local SubtreeFacts = ast.SubtreeFacts
local JSDeclarationKind = ast.JSDeclarationKind
local ModuleInstanceState = ast.ModuleInstanceState
local OuterExpressionKinds = ast.OuterExpressionKinds
local kindSet = ast.kindSet

function ast.IsBreakOrContinueStatement(node)
    return ast.NodeKindIs(node, Kind.BreakStatement, Kind.ContinueStatement)
end

-- GetModuleInstanceState is used during binding as well as in transformations and tests, and therefore may be invoked
-- with a node that does not yet have its `Parent` pointer set. In this case, an `ancestors` represents a stack of
-- virtual `Parent` pointers that can be used to walk up the tree. Since `getModuleInstanceStateForAliasTarget` may
-- potentially walk up out of the provided `Node`, merely setting the parent pointers for a given `ModuleDeclaration`
-- prior to invoking `GetModuleInstanceState` is not sufficient. It is, however, necessary that the `Parent` pointers
-- for all ancestors of the `Node` provided to `GetModuleInstanceState` have been set.
--
-- In Lua the `ancestors` stack is an immutable persistent list { parent = node, rest = list } (or nil), so that
-- pushing never aliases a sibling's stack the way Go's append might not either.

-- Push a virtual parent pointer onto `ancestors` and return it.
function ast.pushAncestor(ancestors, parent)
    return { parent = parent, rest = ancestors }
end

-- If a virtual `Parent` exists on the stack, returns the previous stack entry and the virtual `Parent`.
-- Otherwise, we return `nil` and the value of `node.Parent`.
function ast.popAncestor(ancestors, node)
    if ancestors == nil then
        return nil, node.parent
    end
    return ancestors.rest, ancestors.parent
end

function ast.GetModuleInstanceState(node)
    return ast.getModuleInstanceState(node, nil, nil)
end

function ast.getModuleInstanceState(node, ancestors, visited)
    local module = node:AsModuleDeclaration()
    if module.body ~= nil then
        return ast.getModuleInstanceStateCached(module.body, ast.pushAncestor(ancestors, node), visited)
    else
        return ModuleInstanceState.Instantiated
    end
end

-- visited: table keyed by NodeId
function ast.getModuleInstanceStateCached(node, ancestors, visited)
    if visited == nil then
        visited = {}
    end
    local nodeId = ast.GetNodeId(node)
    local cached = visited[nodeId]
    if cached ~= nil then
        if cached ~= ModuleInstanceState.Unknown then
            return cached
        end
        return ModuleInstanceState.NonInstantiated
    end
    visited[nodeId] = ModuleInstanceState.Unknown
    local result = ast.getModuleInstanceStateWorker(node, ancestors, visited)
    visited[nodeId] = result
    return result
end

function ast.getModuleInstanceStateWorker(node, ancestors, visited)
    -- A module is uninstantiated if it contains only
    local kind = node.kind
    if kind == Kind.InterfaceDeclaration or kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration then
        return ModuleInstanceState.NonInstantiated
    elseif kind == Kind.EnumDeclaration then
        if ast.IsEnumConst(node) then
            return ModuleInstanceState.ConstEnumOnly
        end
    elseif kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration or kind == Kind.ImportEqualsDeclaration then
        if not ast.HasSyntacticModifier(node, ModifierFlags.Export) then
            return ModuleInstanceState.NonInstantiated
        end
    elseif kind == Kind.ExportDeclaration then
        local decl = node:AsExportDeclaration()
        if decl.moduleSpecifier == nil and decl.exportClause ~= nil and decl.exportClause.kind == Kind.NamedExports then
            local state = ModuleInstanceState.NonInstantiated
            ancestors = ast.pushAncestor(ancestors, node)
            ancestors = ast.pushAncestor(ancestors, decl.exportClause)
            for _, specifier in ipairs(decl.exportClause:Elements()) do
                local specifierState = ast.getModuleInstanceStateForAliasTarget(specifier, ancestors, visited)
                if specifierState > state then
                    state = specifierState
                end
                if state == ModuleInstanceState.Instantiated then
                    return state
                end
            end
            return state
        end
    elseif kind == Kind.ModuleBlock then
        local state = ModuleInstanceState.NonInstantiated
        ancestors = ast.pushAncestor(ancestors, node)
        node:ForEachChild(function(n)
            local childState = ast.getModuleInstanceStateCached(n, ancestors, visited)
            if childState == ModuleInstanceState.NonInstantiated then
                return false
            elseif childState == ModuleInstanceState.ConstEnumOnly then
                state = ModuleInstanceState.ConstEnumOnly
                return false
            elseif childState == ModuleInstanceState.Instantiated then
                state = ModuleInstanceState.Instantiated
                return true
            end
            error("Unhandled case in getModuleInstanceStateWorker")
        end)
        return state
    elseif kind == Kind.ModuleDeclaration then
        return ast.getModuleInstanceState(node, ancestors, visited)
    end
    return ModuleInstanceState.Instantiated
end

function ast.getModuleInstanceStateForAliasTarget(node, ancestors, visited)
    local name = node:PropertyNameOrName()
    if name.kind ~= Kind.Identifier then
        -- Skip for invalid syntax like this: export { "x" }
        return ModuleInstanceState.Instantiated
    end
    local p
    ancestors, p = ast.popAncestor(ancestors, node)
    while p ~= nil do
        if ast.IsBlock(p) or ast.IsModuleBlock(p) or ast.IsSourceFile(p) then
            local found = ModuleInstanceState.Unknown
            local statementsAncestors = ast.pushAncestor(ancestors, p)
            for _, statement in ipairs(p:Statements()) do
                if ast.NodeHasName(statement, name) then
                    local state = ast.getModuleInstanceStateCached(statement, statementsAncestors, visited)
                    if found == ModuleInstanceState.Unknown or state > found then
                        found = state
                    end
                    if found == ModuleInstanceState.Instantiated then
                        return found
                    end
                    if statement.kind == Kind.ImportEqualsDeclaration then
                        -- Treat re-exports of import aliases as instantiated since they're ambiguous. This is consistent
                        -- with `export import x = mod.x` being treated as instantiated:
                        --   import x = mod.x;
                        --   export { x };
                        found = ModuleInstanceState.Instantiated
                    end
                end
            end
            if found ~= ModuleInstanceState.Unknown then
                return found
            end
        end
        ancestors, p = ast.popAncestor(ancestors, p)
    end
    -- Couldn't locate, assume could refer to a value
    return ModuleInstanceState.Instantiated
end

function ast.IsInstantiatedModule(node, preserveConstEnums)
    local moduleState = ast.GetModuleInstanceState(node)
    return moduleState == ModuleInstanceState.Instantiated or
        (preserveConstEnums and moduleState == ModuleInstanceState.ConstEnumOnly)
end

function ast.NodeHasName(statement, id)
    local name = statement:Name()
    if name ~= nil then
        return ast.IsIdentifier(name) and name:Text() == id:Text()
    end
    if ast.IsVariableStatement(statement) then
        local declarations = statement.declarationList.declarations.nodes
        return core.Some(declarations, function(d) return ast.NodeHasName(d, id) end)
    end
    return false
end

function ast.IsInternalModuleImportEqualsDeclaration(node)
    return ast.IsImportEqualsDeclaration(node) and node.moduleReference.kind ~= Kind.ExternalModuleReference
end

function ast.IsConstAssertion(node)
    if node.kind == Kind.AsExpression or node.kind == Kind.TypeAssertionExpression then
        return ast.IsConstTypeReference(node:Type())
    end
    return false
end

function ast.IsConstTypeReference(node)
    return ast.IsTypeReferenceNode(node) and core.Len(node:TypeArguments()) == 0 and ast.IsIdentifier(node.typeName) and
        node.typeName:Text() == "const"
end

function ast.IsGlobalSourceFile(node)
    return node.kind == Kind.SourceFile and not ast.IsExternalOrCommonJSModule(node:AsSourceFile())
end

function ast.IsParameterLike(node)
    return node.kind == Kind.Parameter or node.kind == Kind.TypeParameter
end

function ast.GetDeclarationOfKind(symbol, kind)
    if symbol.declarations ~= nil then
        for _, declaration in ipairs(symbol.declarations) do
            if declaration.kind == kind then
                return declaration
            end
        end
    end
    return nil
end

function ast.FindConstructorDeclaration(node)
    for _, member in ipairs(node:Members()) do
        if ast.IsConstructorDeclaration(member) and ast.NodeIsPresent(member:Body()) then
            return member
        end
    end
    return nil
end

function ast.GetFirstIdentifier(node)
    local kind = node.kind
    if kind == Kind.Identifier then
        return node
    elseif kind == Kind.QualifiedName then
        return ast.GetFirstIdentifier(node.left)
    elseif kind == Kind.PropertyAccessExpression then
        return ast.GetFirstIdentifier(node.expression)
    end
    error("Unhandled case in GetFirstIdentifier")
end

function ast.GetNamespaceDeclarationNode(node)
    local kind = node.kind
    if kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration then
        local importClause = node:ImportClause()
        if importClause ~= nil and importClause.namedBindings ~= nil and ast.IsNamespaceImport(importClause.namedBindings) then
            return importClause.namedBindings
        end
    elseif kind == Kind.ImportEqualsDeclaration then
        return node
    elseif kind == Kind.ExportDeclaration then
        local exportClause = node.exportClause
        if exportClause ~= nil and ast.IsNamespaceExport(exportClause) then
            return exportClause
        end
    else
        error("Unhandled case in getNamespaceDeclarationNode")
    end
    return nil
end

function ast.ModuleExportNameIsDefault(node)
    return node:Text() == ast.InternalSymbolNameDefault
end

function ast.IsDefaultImport(node --[[ImportDeclaration | ImportEqualsDeclaration | ExportDeclaration]])
    if node.kind == Kind.ImportDeclaration or node.kind == Kind.JSImportDeclaration then
        local importClause = node:ImportClause()
        return importClause ~= nil and importClause.name ~= nil
    end
    return false
end

function ast.GetImpliedNodeFormatForFile(path, packageJsonType)
    local impliedNodeFormat = core.ModuleKind.ResolutionModeNone
    if tspath.FileExtensionIsOneOf(path, { tspath.ExtensionDmts, tspath.ExtensionMts, tspath.ExtensionMjs }) then
        impliedNodeFormat = core.ModuleKind.ResolutionModeESM
    elseif tspath.FileExtensionIsOneOf(path, { tspath.ExtensionDcts, tspath.ExtensionCts, tspath.ExtensionCjs }) then
        impliedNodeFormat = core.ModuleKind.ResolutionModeCommonJS
    elseif tspath.FileExtensionIsOneOf(path, { tspath.ExtensionDts, tspath.ExtensionTs, tspath.ExtensionTsx, tspath.ExtensionJs, tspath.ExtensionJsx }) then
        if packageJsonType == "module" then
            impliedNodeFormat = core.ModuleKind.ResolutionModeESM
        else
            impliedNodeFormat = core.ModuleKind.ResolutionModeCommonJS
        end
    end

    return impliedNodeFormat
end

function ast.GetEmitModuleFormatOfFileWorker(fileName, options, sourceFileMetaData)
    local result = ast.GetImpliedNodeFormatForEmitWorker(fileName, options:GetEmitModuleKind(), sourceFileMetaData)
    if result ~= core.ModuleKind.None then
        return result
    end
    return options:GetEmitModuleKind()
end

-- sourceFileMetaData: { packageJsonType, packageJsonDirectory, impliedNodeFormat }
function ast.GetImpliedNodeFormatForEmitWorker(fileName, emitModuleKind, sourceFileMetaData)
    if core.ModuleKind.Node16 <= emitModuleKind and emitModuleKind <= core.ModuleKind.NodeNext then
        return sourceFileMetaData.impliedNodeFormat
    end
    if sourceFileMetaData.impliedNodeFormat == core.ModuleKind.CommonJS and
        (sourceFileMetaData.packageJsonType == "commonjs" or
            tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionCjs, tspath.ExtensionCts })) then
        return core.ModuleKind.CommonJS
    end
    if sourceFileMetaData.impliedNodeFormat == core.ModuleKind.ESNext and
        (sourceFileMetaData.packageJsonType == "module" or
            tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionMjs, tspath.ExtensionMts })) then
        return core.ModuleKind.ESNext
    end
    return core.ModuleKind.None
end

local declarationContainerSkipKinds = kindSet(Kind.VariableDeclaration, Kind.VariableDeclarationList,
    Kind.ImportSpecifier, Kind.NamedImports, Kind.NamespaceImport, Kind.ImportClause)

function ast.GetDeclarationContainer(node)
    return ast.FindAncestor(ast.GetRootDeclaration(node), function(n)
        return not declarationContainerSkipKinds[n.kind]
    end).parent
end

-- Indicates that a symbol is an alias that does not merge with a local declaration.
-- OR Is a JSContainer which may merge an alias with a local declaration
function ast.IsNonLocalAlias(symbol, excludes)
    if symbol == nil then
        return false
    end
    return symbol.flags & (SymbolFlags.Alias | excludes) == SymbolFlags.Alias or
        symbol.flags & SymbolFlags.Alias ~= 0 and symbol.flags & SymbolFlags.Assignment ~= 0
end

local aliasSymbolDeclarationKinds = kindSet(Kind.ImportEqualsDeclaration, Kind.NamespaceExportDeclaration,
    Kind.NamespaceImport, Kind.NamespaceExport, Kind.ImportSpecifier, Kind.ExportSpecifier)

-- An alias symbol is created by one of the following declarations:
--
--	import <symbol> = ...
--	const <symbol> = ... (JS only)
--	const { <symbol>, ... } = ... (JS only)
--	import <symbol> from ...
--	import * as <symbol> from ...
--	import { x as <symbol> } from ...
--	export { x as <symbol> } from ...
--	export * as ns <symbol> from ...
--	export = <EntityNameExpression>
--	export default <EntityNameExpression>
--	module.exports = <EntityNameExpression> (JS only)
--	module.exports.<symbol> = <EntityNameExpression> (JS only)
--	exports.<symbol> = <EntityNameExpression> (JS only)
function ast.IsAliasSymbolDeclaration(node)
    local kind = node.kind
    if aliasSymbolDeclarationKinds[kind] then
        return true
    elseif kind == Kind.ImportClause then
        return node:AsImportClause():Name() ~= nil
    elseif kind == Kind.ExportAssignment then
        return ast.ExpressionIsAlias(node:Expression())
    elseif kind == Kind.VariableDeclaration or kind == Kind.BindingElement then
        return ast.IsVariableDeclarationInitializedToRequire(node)
    elseif kind == Kind.BinaryExpression then
        local k = ast.GetAssignmentDeclarationKind(node)
        if k == JSDeclarationKind.ModuleExports or k == JSDeclarationKind.ExportsProperty then
            return ast.ExpressionIsAlias(node.right)
        end
    end
    return false
end

function ast.IsParseTreeNode(node)
    return node.flags & NodeFlags.Synthesized == 0
end

-- Returns a token if position is in [start-of-leading-trivia, end), includes JSDoc only if requested
function ast.GetNodeAtPosition(file, position, includeJSDoc)
    local current = file
    while true do
        local child = nil
        if includeJSDoc then
            local jsdocs = current:JSDoc(file)
            if jsdocs ~= nil then
                for _, jsdoc in ipairs(jsdocs) do
                    if ast.nodeContainsPosition(jsdoc, position) then
                        child = jsdoc
                        break
                    end
                end
            end
        end
        if child == nil then
            current:ForEachChild(function(node)
                if ast.nodeContainsPosition(node, position) then
                    child = node
                    return true
                end
                return false
            end)
        end
        if child == nil or ast.IsMetaProperty(child) then
            return current
        end
        current = child
    end
end

function ast.nodeContainsPosition(node, position)
    return node.kind >= Kind.FirstNode and node:Pos() <= position and
        (position < node:End() or position == node:End() and node.kind == Kind.EndOfFile)
end

-- Returns index, size (index is a 0-based byte offset, or -1).
function ast.findImportOrRequire(text, start)
    local index = math.max(start, 0)
    local size = 0
    local n = #text
    while index < n do
        -- strings.IndexAny(text[index:], "ir")
        local found = string.find(text, "[ir]", index + 1)
        if found == nil then
            break
        end
        index = found - 1

        local expected
        if string.byte(text, index + 1) == 105 then -- 'i'
            size = 6
            expected = "import"
        else
            size = 7
            expected = "require"
        end
        if index + size <= n and string.sub(text, index + 1, index + size) == expected then
            return index, size
        end
        index = index + 1
    end

    return -1, 0
end

function ast.ForEachDynamicImportOrRequireCall(file, includeTypeSpaceImports, requireStringLiteralLikeArgument, cb)
    local isJavaScriptFile = ast.IsInJSFile(file)
    local lastIndex, size = ast.findImportOrRequire(file:Text(), 0)
    while lastIndex >= 0 do
        local node = ast.GetNodeAtPosition(file, lastIndex, isJavaScriptFile and includeTypeSpaceImports)
        if isJavaScriptFile and ast.IsRequireCall(node, requireStringLiteralLikeArgument) then
            if cb(node, node:Arguments()[1]) then
                return true
            end
        elseif ast.IsImportCall(node) and core.Len(node:Arguments()) > 0 and
            (not requireStringLiteralLikeArgument or ast.IsStringLiteralLike(node:Arguments()[1])) then
            if cb(node, node:Arguments()[1]) then
                return true
            end
        elseif includeTypeSpaceImports and ast.IsLiteralImportTypeNode(node) then
            if cb(node, node.argument:AsLiteralTypeNode().literal) then
                return true
            end
        end
        -- skip past import/require
        lastIndex = lastIndex + size
        lastIndex, size = ast.findImportOrRequire(file:Text(), lastIndex)
    end
    return false
end

-- Returns true if the node is a CallExpression to the identifier 'require' with
-- exactly one argument (of the form 'require("name")').
-- This function does not test if the node is in a JavaScript file or not.
function ast.IsRequireCall(node, requireStringLiteralLikeArgument)
    if not ast.IsCallExpression(node) then
        return false
    end
    local call = node:AsCallExpression()
    if not ast.IsIdentifier(call.expression) or call.expression:Text() ~= "require" then
        return false
    end
    if #call.arguments.nodes ~= 1 then
        return false
    end
    return not requireStringLiteralLikeArgument or ast.IsStringLiteralLike(call.arguments.nodes[1])
end

function ast.IsRequireVariableStatement(node)
    if ast.IsVariableStatement(node) then
        local declarations = node.declarationList.declarations.nodes
        if #declarations > 0 then
            return core.Every(declarations, ast.IsVariableDeclarationInitializedToRequire)
        end
    end
    return false
end

function ast.GetJSXImplicitImportBase(compilerOptions, file)
    local jsxImportSourcePragma = ast.GetPragmaFromSourceFile(file, "jsximportsource")
    local jsxRuntimePragma = ast.GetPragmaFromSourceFile(file, "jsxruntime")
    if ast.GetPragmaArgument(jsxRuntimePragma, "factory") == "classic" then
        return ""
    end
    if compilerOptions.jsx == core.JsxEmit.ReactJSX or
        compilerOptions.jsx == core.JsxEmit.ReactJSXDev or
        compilerOptions.jsxImportSource ~= "" or
        jsxImportSourcePragma ~= nil or
        ast.GetPragmaArgument(jsxRuntimePragma, "factory") == "automatic" then
        local result = ast.GetPragmaArgument(jsxImportSourcePragma, "factory")
        if result == "" then
            result = compilerOptions.jsxImportSource
        end
        if result == "" or result == nil then
            result = "react"
        end
        return result
    end
    return ""
end

function ast.GetJSXRuntimeImport(base, options)
    if base == "" then
        return base
    end
    return base .. "/" .. (options.jsx == core.JsxEmit.ReactJSXDev and "jsx-dev-runtime" or "jsx-runtime")
end

function ast.GetPragmaFromSourceFile(file, name)
    local result = nil
    if file ~= nil and file.pragmas ~= nil then
        for _, pragma in ipairs(file.pragmas) do
            if pragma.name == name then
                result = pragma -- Last one wins
            end
        end
    end
    return result
end

function ast.GetPragmaArgument(pragma, name)
    if pragma ~= nil and pragma.args ~= nil then
        local arg = pragma.args[name]
        if arg ~= nil then
            return arg.value
        end
    end
    return ""
end

-- Of the form: `const x = require("x")` or `const { x } = require("x")` or with `var` or `let`
-- The variable must not be exported and must not have a type annotation, even a jsdoc one.
-- The initializer must be a call to `require` with a string literal or a string literal-like argument.
function ast.IsVariableDeclarationInitializedToRequire(node)
    if node.kind == Kind.BindingElement then
        node = node.parent.parent
    end
    return ast.isVariableDeclarationInitializedWithRequireHelper(node, false --[[allowAccessedRequire]])
end

function ast.IsVariableDeclarationInitializedToBareOrAccessedRequire(node)
    return ast.isVariableDeclarationInitializedWithRequireHelper(node, true --[[allowAccessedRequire]])
end

function ast.isVariableDeclarationInitializedWithRequireHelper(node, allowAccessedRequire)
    if not ast.IsInJSFile(node) then
        return false
    end
    if node.kind ~= Kind.VariableDeclaration then
        return false
    end
    local initializer = node:Initializer()
    if initializer == nil then
        return false
    end
    if allowAccessedRequire then
        initializer = ast.GetLeftmostAccessExpression(initializer)
    end

    return node.parent.parent:ModifierFlags() & ModifierFlags.Export == 0 and
        node:Type() == nil and
        ast.IsRequireCall(initializer, true --[[requireStringLiteralLikeArgument]])
end

function ast.GetModuleSpecifierOfBareOrAccessedRequire(node)
    if ast.isVariableDeclarationInitializedWithRequireHelper(node, false --[[allowAccessedRequire]]) then
        return node:Initializer():Arguments()[1]
    end
    if ast.isVariableDeclarationInitializedWithRequireHelper(node, true --[[allowAccessedRequire]]) then
        local leftmost = ast.GetLeftmostAccessExpression(node:Initializer())
        if ast.IsRequireCall(leftmost, true --[[requireStringLiteralLikeArgument]]) then
            return leftmost:Arguments()[1]
        end
    end
    return nil
end

function ast.IsModuleExportsAccessExpression(node)
    if ast.IsAccessExpression(node) and ast.IsModuleIdentifier(node:Expression()) then
        local name = ast.GetElementOrPropertyAccessName(node)
        if name ~= nil then
            return name:Text() == "exports"
        end
    end
    return false
end

function ast.IsModuleExportsQualifiedName(node)
    return ast.IsQualifiedName(node) and ast.IsModuleIdentifier(node.left) and node.right:Text() == "exports"
end

function ast.IsCheckJSEnabledForFile(sourceFile, compilerOptions)
    if sourceFile.checkJsDirective ~= nil then
        return sourceFile.checkJsDirective.enabled
    end
    return compilerOptions.checkJs == core.Tristate.TSTrue
end

function ast.IsPlainJSFile(file, checkJs)
    return file ~= nil and (file.scriptKind == core.ScriptKind.JS or file.scriptKind == core.ScriptKind.JSX) and
        file.checkJsDirective == nil and checkJs == core.Tristate.TSUnknown
end

function ast.GetLeftmostAccessExpression(expr)
    while ast.IsAccessExpression(expr) do
        expr = expr:Expression()
    end
    return expr
end

function ast.IsTypeOnlyImportDeclaration(node)
    local kind = node.kind
    if kind == Kind.ImportSpecifier then
        return node:IsTypeOnly() or node.parent.parent:IsTypeOnly()
    elseif kind == Kind.NamespaceImport then
        return node.parent:IsTypeOnly()
    elseif kind == Kind.ImportClause or kind == Kind.ImportEqualsDeclaration then
        return node:IsTypeOnly()
    end
    return false
end

function ast.isTypeOnlyExportDeclaration(node)
    local kind = node.kind
    if kind == Kind.ExportSpecifier then
        return node:IsTypeOnly() or node.parent.parent:IsTypeOnly()
    elseif kind == Kind.ExportDeclaration then
        local d = node:AsExportDeclaration()
        return d.isTypeOnly and d.moduleSpecifier ~= nil and d.exportClause == nil
    elseif kind == Kind.NamespaceExport then
        return node.parent:IsTypeOnly()
    end
    return false
end

function ast.IsTypeOnlyImportOrExportDeclaration(node)
    return ast.IsTypeOnlyImportDeclaration(node) or ast.isTypeOnlyExportDeclaration(node)
end

function ast.IsExclusivelyTypeOnlyImportOrExport(node)
    local kind = node.kind
    if kind == Kind.ExportDeclaration then
        return node:IsTypeOnly()
    elseif kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration or kind == Kind.JSDocImportTag then
        local importClause = node:ImportClause()
        if importClause ~= nil then
            return importClause:AsImportClause():IsTypeOnly()
        end
    end
    return false
end

function ast.GetClassLikeDeclarationOfSymbol(symbol)
    return core.Find(symbol.declarations, ast.IsClassLike)
end

local callLikeExpressionKinds = kindSet(Kind.JsxOpeningElement, Kind.JsxSelfClosingElement, Kind.JsxOpeningFragment,
    Kind.CallExpression, Kind.NewExpression, Kind.TaggedTemplateExpression, Kind.Decorator)

function ast.IsCallLikeExpression(node)
    if callLikeExpressionKinds[node.kind] then
        return true
    elseif node.kind == Kind.BinaryExpression then
        return node.operatorToken.kind == Kind.InstanceOfKeyword
    end
    return false
end

local jsxCallLikeKinds = kindSet(Kind.JsxOpeningElement, Kind.JsxSelfClosingElement, Kind.JsxOpeningFragment)

function ast.IsJsxCallLike(node)
    return jsxCallLikeKinds[node.kind] == true
end

function ast.IsCallLikeOrFunctionLikeExpression(node)
    return ast.IsCallLikeExpression(node) or ast.IsFunctionExpressionOrArrowFunction(node)
end

function ast.NodeHasKind(node, kind)
    if node == nil then
        return false
    end
    return node.kind == kind
end

function ast.IsContextualKeyword(token)
    return Kind.FirstContextualKeyword <= token and token <= Kind.LastContextualKeyword
end

function ast.IsThisInTypeQuery(node)
    if not ast.IsThisIdentifier(node) then
        return false
    end
    while ast.IsQualifiedName(node.parent) and node.parent.left == node do
        node = node.parent
    end
    return node.parent.kind == Kind.TypeQuery
end

-- Gets whether a bound `VariableDeclaration` or `VariableDeclarationList` is part of a `let` declaration.
function ast.IsLet(node)
    return ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped == NodeFlags.Let
end

function ast.IsClassMemberModifier(token)
    return ast.IsParameterPropertyModifier(token) or token == Kind.StaticKeyword or
        token == Kind.OverrideKeyword or token == Kind.AccessorKeyword
end

function ast.IsParameterPropertyModifier(kind)
    return ast.ModifierToFlag(kind) & ModifierFlags.ParameterPropertyModifier ~= 0
end

function ast.ForEachChildAndJSDoc(node, sourceFile, v)
    if ast.visitNodes(v, node:JSDoc(sourceFile)) then
        return true
    end
    return node:ForEachChild(v)
end

local hasTypeArgumentsKinds = kindSet(Kind.CallExpression, Kind.NewExpression, Kind.TaggedTemplateExpression,
    Kind.TypeReference, Kind.ExpressionWithTypeArguments, Kind.ImportType, Kind.TypeQuery, Kind.JsxOpeningElement,
    Kind.JsxSelfClosingElement)

function ast.HasTypeArguments(node)
    return hasTypeArgumentsKinds[node.kind] == true
end

function ast.IsTypeReferenceType(node)
    return node.kind == Kind.TypeReference or node.kind == Kind.ExpressionWithTypeArguments
end

local variableLikeKinds = kindSet(Kind.BindingElement, Kind.EnumMember, Kind.Parameter, Kind.PropertyAssignment,
    Kind.PropertyDeclaration, Kind.PropertySignature, Kind.ShorthandPropertyAssignment, Kind.VariableDeclaration)

function ast.IsVariableLike(node)
    return variableLikeKinds[node.kind] == true
end

local hasInitializerKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.BindingElement,
    Kind.PropertyDeclaration, Kind.PropertyAssignment, Kind.EnumMember, Kind.ForStatement, Kind.ForInStatement,
    Kind.ForOfStatement, Kind.JsxAttribute)

function ast.HasInitializer(node)
    if hasInitializerKinds[node.kind] then
        return node:Initializer() ~= nil
    end
    return false
end

local variableParameterOrPropertyKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.PropertySignature,
    Kind.PropertyDeclaration)

function ast.IsVariableParameterOrProperty(node)
    return variableParameterOrPropertyKinds[node.kind] == true
end

local typeAnnotationKinds = kindSet(Kind.VariableDeclaration, Kind.Parameter, Kind.PropertySignature,
    Kind.PropertyDeclaration, Kind.TypePredicate, Kind.ParenthesizedType, Kind.TypeOperator, Kind.MappedType,
    Kind.TypeAssertionExpression, Kind.AsExpression, Kind.SatisfiesExpression, Kind.TypeAliasDeclaration,
    Kind.JSTypeAliasDeclaration, Kind.NamedTupleMember, Kind.OptionalType, Kind.RestType, Kind.TemplateLiteralTypeSpan,
    Kind.JSDocTypeExpression, Kind.JSDocPropertyTag, Kind.JSDocNullableType, Kind.JSDocNonNullableType,
    Kind.JSDocOptionalType)

function ast.GetTypeAnnotationNode(node)
    if typeAnnotationKinds[node.kind] then
        return node:Type()
    end
    local funcLike = node:FunctionLikeData()
    if funcLike ~= nil then
        return funcLike.type
    end
    return nil
end

function ast.IsObjectTypeDeclaration(node)
    return ast.IsClassLike(node) or ast.IsInterfaceDeclaration(node) or ast.IsTypeLiteralNode(node)
end

function ast.IsClassOrTypeElement(node)
    return ast.IsClassElement(node) or ast.IsTypeElement(node)
end

function ast.GetClassExtendsHeritageElement(node)
    local heritageElements = ast.GetHeritageElements(node, Kind.ExtendsKeyword)
    if core.Len(heritageElements) > 0 then
        return heritageElements[1]
    end
    return nil
end

function ast.IsTypeKeywordToken(node)
    return node.kind == Kind.TypeKeyword
end

-- See `IsJSDocSingleCommentNode`.
function ast.IsJSDocSingleCommentNodeList(nodeList)
    if nodeList == nil or core.Len(nodeList.nodes) == 0 then
        return false
    end
    local parent = nodeList.nodes[1].parent
    if parent == nil then
        return false
    end
    return ast.IsJSDocSingleCommentNode(parent) and nodeList == parent:CommentList()
end

-- See `IsJSDocSingleCommentNode`.
function ast.IsJSDocSingleCommentNodeComment(node)
    if node == nil or node.parent == nil then
        return false
    end
    return ast.IsJSDocSingleCommentNode(node.parent) and node == node.parent:CommentList().nodes[1]
end

-- In Strada, if a JSDoc node has a single comment, that comment is represented as a string property
-- as a simplification, and therefore that comment is not visited by `forEachChild`.
function ast.IsJSDocSingleCommentNode(node)
    return ast.hasComment(node.kind) and node:CommentList() ~= nil and #node:CommentList().nodes == 1
end

function ast.IsValidTypeOnlyAliasUseSite(useSite)
    return useSite.flags & (NodeFlags.Ambient | NodeFlags.JSDoc) ~= 0 or
        ast.IsPartOfTypeQuery(useSite) or
        ast.isIdentifierInNonEmittingHeritageClause(useSite) or
        ast.isPartOfPossiblyValidTypeOrAbstractComputedPropertyName(useSite) or
        not (ast.IsExpressionNode(useSite) or ast.isShorthandPropertyNameUseSite(useSite))
end

function ast.isIdentifierInNonEmittingHeritageClause(node)
    if not ast.IsIdentifier(node) then
        return false
    end
    local parent = node.parent
    while ast.IsPropertyAccessExpression(parent) or ast.IsExpressionWithTypeArguments(parent) do
        parent = parent.parent
    end
    return ast.IsHeritageClause(parent) and
        (parent.token == Kind.ImplementsKeyword or ast.IsInterfaceDeclaration(parent.parent))
end

function ast.isPartOfPossiblyValidTypeOrAbstractComputedPropertyName(node)
    while ast.NodeKindIs(node, Kind.Identifier, Kind.PropertyAccessExpression) do
        node = node.parent
    end
    if node.kind ~= Kind.ComputedPropertyName then
        return false
    end
    if ast.HasSyntacticModifier(node.parent, ModifierFlags.Abstract) then
        return true
    end
    return ast.NodeKindIs(node.parent.parent, Kind.InterfaceDeclaration, Kind.TypeLiteral)
end

function ast.isShorthandPropertyNameUseSite(useSite)
    return ast.IsIdentifier(useSite) and ast.IsShorthandPropertyAssignment(useSite.parent) and
        useSite.parent:Name() == useSite
end

local propertyNameTextKinds = kindSet(Kind.Identifier, Kind.PrivateIdentifier, Kind.StringLiteral,
    Kind.NoSubstitutionTemplateLiteral, Kind.NumericLiteral, Kind.BigIntLiteral, Kind.JsxNamespacedName)

function ast.GetPropertyNameForPropertyNameNode(name)
    if propertyNameTextKinds[name.kind] then
        return name:Text()
    elseif name.kind == Kind.ComputedPropertyName then
        local nameExpression = name:Expression()
        if ast.IsStringOrNumericLiteralLike(nameExpression) then
            return nameExpression:Text()
        end
        if ast.IsSignedNumericLiteral(nameExpression) then
            local text = nameExpression.operand:Text()
            if nameExpression.operator == Kind.MinusToken then
                text = "-" .. text
            end
            return text
        end
        return ast.InternalSymbolNameMissing
    end
    error("Unhandled case in getPropertyNameForPropertyNameNode")
end

function ast.IsPartOfTypeOnlyImportOrExportDeclaration(node)
    return ast.FindAncestor(node, ast.IsTypeOnlyImportOrExportDeclaration) ~= nil
end

function ast.IsPartOfExclusivelyTypeOnlyImportOrExportDeclaration(node)
    return ast.FindAncestor(node, ast.IsExclusivelyTypeOnlyImportOrExport) ~= nil
end

function ast.IsEmittableImport(node)
    local kind = node.kind
    if kind == Kind.ImportDeclaration then
        return node:ImportClause() ~= nil and not node:ImportClause():IsTypeOnly()
    elseif kind == Kind.ExportDeclaration or kind == Kind.ImportEqualsDeclaration then
        return not node:IsTypeOnly()
    elseif kind == Kind.CallExpression then
        return ast.IsImportCall(node)
    end
    return false
end

local resolutionModeOverrideHostKinds = kindSet(Kind.ImportType, Kind.ExportDeclaration, Kind.ImportDeclaration,
    Kind.JSImportDeclaration)

function ast.IsResolutionModeOverrideHost(node)
    if node == nil then
        return false
    end
    return resolutionModeOverrideHostKinds[node.kind] == true
end

function ast.HasResolutionModeOverride(node)
    if node == nil then
        return false
    end
    local attributes = nil
    local kind = node.kind
    if kind == Kind.ImportType or kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration or
        kind == Kind.ExportDeclaration then
        attributes = node.attributes
    end
    if attributes ~= nil then
        local _, ok = ast.Node.GetResolutionModeOverride(attributes)
        return ok
    end
    return false
end

function ast.IsStringTextContainingNode(node)
    return node.kind == Kind.StringLiteral or ast.IsTemplateLiteralKind(node.kind)
end

function ast.IsTemplateLiteralKind(kind)
    return Kind.FirstTemplateToken <= kind and kind <= Kind.LastTemplateToken
end

function ast.IsTemplateLiteralToken(node)
    return ast.IsTemplateLiteralKind(node.kind)
end

function ast.GetExternalModuleImportEqualsDeclarationExpression(node)
    debug.Assert(ast.IsExternalModuleImportEqualsDeclaration(node))
    return node.moduleReference:Expression()
end

function ast.CreateModifiersFromModifierFlags(flags, createModifier)
    local result = nil
    local function add(kind)
        result = core.Append(result, createModifier(kind))
    end
    if flags & ModifierFlags.Export ~= 0 then
        add(Kind.ExportKeyword)
    end
    if flags & ModifierFlags.Ambient ~= 0 then
        add(Kind.DeclareKeyword)
    end
    if flags & ModifierFlags.Default ~= 0 then
        add(Kind.DefaultKeyword)
    end
    if flags & ModifierFlags.Const ~= 0 then
        add(Kind.ConstKeyword)
    end
    if flags & ModifierFlags.Public ~= 0 then
        add(Kind.PublicKeyword)
    end
    if flags & ModifierFlags.Private ~= 0 then
        add(Kind.PrivateKeyword)
    end
    if flags & ModifierFlags.Protected ~= 0 then
        add(Kind.ProtectedKeyword)
    end
    if flags & ModifierFlags.Abstract ~= 0 then
        add(Kind.AbstractKeyword)
    end
    if flags & ModifierFlags.Static ~= 0 then
        add(Kind.StaticKeyword)
    end
    if flags & ModifierFlags.Override ~= 0 then
        add(Kind.OverrideKeyword)
    end
    if flags & ModifierFlags.Readonly ~= 0 then
        add(Kind.ReadonlyKeyword)
    end
    if flags & ModifierFlags.Accessor ~= 0 then
        add(Kind.AccessorKeyword)
    end
    if flags & ModifierFlags.Async ~= 0 then
        add(Kind.AsyncKeyword)
    end
    if flags & ModifierFlags.In ~= 0 then
        add(Kind.InKeyword)
    end
    if flags & ModifierFlags.Out ~= 0 then
        add(Kind.OutKeyword)
    end
    return result
end

function ast.GetThisParameter(signature)
    -- callback tags do not currently support this parameters
    local parameters = signature:Parameters()
    if core.Len(parameters) ~= 0 then
        local thisParameter = parameters[1]
        if ast.IsThisParameter(thisParameter) then
            return thisParameter
        end
    end
    return nil
end

function ast.ReplaceModifiers(factory, node, modifierArray)
    local kind = node.kind
    if kind == Kind.TypeParameter then
        return factory:UpdateTypeParameterDeclaration(
            node:AsTypeParameterDeclaration(),
            modifierArray,
            node:Name(),
            node.constraint,
            node.expression,
            node.defaultType
        )
    elseif kind == Kind.Parameter then
        return factory:UpdateParameterDeclaration(
            node:AsParameterDeclaration(),
            modifierArray,
            node.dotDotDotToken,
            node:Name(),
            node:QuestionToken(),
            node:Type(),
            node:Initializer()
        )
    elseif kind == Kind.ConstructorType then
        return factory:UpdateConstructorTypeNode(
            node:AsConstructorTypeNode(),
            modifierArray,
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type()
        )
    elseif kind == Kind.PropertySignature then
        return factory:UpdatePropertySignatureDeclaration(
            node:AsPropertySignatureDeclaration(),
            modifierArray,
            node:Name(),
            node:PostfixToken(),
            node:Type(),
            node:Initializer()
        )
    elseif kind == Kind.PropertyDeclaration then
        return factory:UpdatePropertyDeclaration(
            node:AsPropertyDeclaration(),
            modifierArray,
            node:Name(),
            node:PostfixToken(),
            node:Type(),
            node:Initializer()
        )
    elseif kind == Kind.MethodSignature then
        return factory:UpdateMethodSignatureDeclaration(
            node:AsMethodSignatureDeclaration(),
            modifierArray,
            node:Name(),
            node:PostfixToken(),
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type()
        )
    elseif kind == Kind.MethodDeclaration then
        return factory:UpdateMethodDeclaration(
            node:AsMethodDeclaration(),
            modifierArray,
            node.asteriskToken,
            node:Name(),
            node:PostfixToken(),
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node:Body()
        )
    elseif kind == Kind.Constructor then
        return factory:UpdateConstructorDeclaration(
            node:AsConstructorDeclaration(),
            modifierArray,
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node:Body()
        )
    elseif kind == Kind.GetAccessor then
        return factory:UpdateGetAccessorDeclaration(
            node:AsGetAccessorDeclaration(),
            modifierArray,
            node:Name(),
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node:Body()
        )
    elseif kind == Kind.SetAccessor then
        return factory:UpdateSetAccessorDeclaration(
            node:AsSetAccessorDeclaration(),
            modifierArray,
            node:Name(),
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node:Body()
        )
    elseif kind == Kind.IndexSignature then
        return factory:UpdateIndexSignatureDeclaration(
            node:AsIndexSignatureDeclaration(),
            modifierArray,
            node:ParameterList(),
            node:Type()
        )
    elseif kind == Kind.FunctionExpression then
        return factory:UpdateFunctionExpression(
            node:AsFunctionExpression(),
            modifierArray,
            node.asteriskToken,
            node:Name(),
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node:Body()
        )
    elseif kind == Kind.ArrowFunction then
        return factory:UpdateArrowFunction(
            node:AsArrowFunction(),
            modifierArray,
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node.equalsGreaterThanToken,
            node:Body()
        )
    elseif kind == Kind.ClassExpression then
        return factory:UpdateClassExpression(
            node:AsClassExpression(),
            modifierArray,
            node:Name(),
            node:TypeParameterList(),
            node.heritageClauses,
            node:MemberList()
        )
    elseif kind == Kind.VariableStatement then
        return factory:UpdateVariableStatement(
            node:AsVariableStatement(),
            modifierArray,
            node.declarationList
        )
    elseif kind == Kind.FunctionDeclaration then
        return factory:UpdateFunctionDeclaration(
            node:AsFunctionDeclaration(),
            modifierArray,
            node.asteriskToken,
            node:Name(),
            node:TypeParameterList(),
            node:ParameterList(),
            node:Type(),
            node.fullSignature,
            node:Body()
        )
    elseif kind == Kind.ClassDeclaration then
        return factory:UpdateClassDeclaration(
            node:AsClassDeclaration(),
            modifierArray,
            node:Name(),
            node:TypeParameterList(),
            node.heritageClauses,
            node:MemberList()
        )
    elseif kind == Kind.InterfaceDeclaration then
        return factory:UpdateInterfaceDeclaration(
            node:AsInterfaceDeclaration(),
            modifierArray,
            node:Name(),
            node:TypeParameterList(),
            node.heritageClauses,
            node:MemberList()
        )
    elseif kind == Kind.TypeAliasDeclaration then
        return factory:UpdateTypeAliasDeclaration(
            node:AsTypeAliasDeclaration(),
            modifierArray,
            node:Name(),
            node:TypeParameterList(),
            node:Type()
        )
    elseif kind == Kind.EnumDeclaration then
        return factory:UpdateEnumDeclaration(
            node:AsEnumDeclaration(),
            modifierArray,
            node:Name(),
            node:MemberList()
        )
    elseif kind == Kind.ModuleDeclaration then
        return factory:UpdateModuleDeclaration(
            node:AsModuleDeclaration(),
            modifierArray,
            node.keyword,
            node:Name(),
            node:Body()
        )
    elseif kind == Kind.ImportEqualsDeclaration then
        return factory:UpdateImportEqualsDeclaration(
            node:AsImportEqualsDeclaration(),
            modifierArray,
            node:IsTypeOnly(),
            node:Name(),
            node.moduleReference
        )
    elseif kind == Kind.ImportDeclaration then
        return factory:UpdateImportDeclaration(
            node:AsImportDeclaration(),
            modifierArray,
            node:ImportClause(),
            node:ModuleSpecifier(),
            node.attributes
        )
    elseif kind == Kind.ExportAssignment then
        return factory:UpdateExportAssignment(
            node:AsExportAssignment(),
            modifierArray,
            node.isExportEquals,
            node:Type(),
            node:Expression()
        )
    elseif kind == Kind.ExportDeclaration then
        return factory:UpdateExportDeclaration(
            node:AsExportDeclaration(),
            modifierArray,
            node:IsTypeOnly(),
            node.exportClause,
            node:ModuleSpecifier(),
            node.attributes
        )
    end
    error(string.format("Node that does not have modifiers tried to have modifier replaced: %d", node.kind))
end

local lateVisibilityPaintedStatementKinds = kindSet(Kind.ImportDeclaration, Kind.JSImportDeclaration,
    Kind.ImportEqualsDeclaration, Kind.VariableStatement, Kind.ClassDeclaration, Kind.FunctionDeclaration,
    Kind.ModuleDeclaration, Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.InterfaceDeclaration,
    Kind.EnumDeclaration)

function ast.IsLateVisibilityPaintedStatement(node)
    return lateVisibilityPaintedStatementKinds[node.kind] == true
end

function ast.IsExternalModuleAugmentation(node)
    return ast.IsAmbientModule(node) and ast.IsModuleAugmentationExternal(node)
end

function ast.GetSourceFileOfModule(module)
    local declaration = module.valueDeclaration
    if declaration == nil then
        declaration = ast.GetNonAugmentationDeclaration(module)
    end
    return ast.GetSourceFileOfNode(declaration)
end

function ast.GetNonAugmentationDeclaration(symbol)
    return core.Find(symbol.declarations, function(d)
        return not ast.IsExternalModuleAugmentation(d) and not ast.IsGlobalScopeAugmentation(d)
    end)
end

local typeDeclarationKinds = kindSet(Kind.TypeParameter, Kind.ClassDeclaration, Kind.InterfaceDeclaration,
    Kind.TypeAliasDeclaration, Kind.JSTypeAliasDeclaration, Kind.EnumDeclaration)

function ast.IsTypeDeclaration(node)
    local kind = node.kind
    if typeDeclarationKinds[kind] then
        return true
    elseif kind == Kind.ImportClause then
        return node:IsTypeOnly()
    elseif kind == Kind.ImportSpecifier or kind == Kind.ExportSpecifier then
        return node.parent.parent:IsTypeOnly()
    end
    return false
end

function ast.IsTypeDeclarationName(name)
    return name.kind == Kind.Identifier and
        ast.IsTypeDeclaration(name.parent) and
        ast.GetNameOfDeclaration(name.parent) == name
end

function ast.IsRightSideOfPropertyAccess(node)
    return node.parent.kind == Kind.PropertyAccessExpression and node.parent:Name() == node
end

function ast.IsArgumentExpressionOfElementAccess(node)
    return node.parent ~= nil and node.parent.kind == Kind.ElementAccessExpression and
        node.parent.argumentExpression == node
end

function ast.ClimbPastPropertyAccess(node)
    if ast.IsRightSideOfPropertyAccess(node) then
        return node.parent
    end
    return node
end

function ast.climbPastPropertyOrElementAccess(node)
    if ast.IsRightSideOfPropertyAccess(node) or ast.IsArgumentExpressionOfElementAccess(node) then
        return node.parent
    end
    return node
end

function ast.selectExpressionOfCallOrNewExpressionOrDecorator(node)
    if ast.IsCallExpression(node) or ast.IsNewExpression(node) or ast.IsDecorator(node) then
        return node:Expression()
    end
    return nil
end

function ast.selectTagOfTaggedTemplateExpression(node)
    if ast.IsTaggedTemplateExpression(node) then
        return node.tag
    end
    return nil
end

function ast.selectTagNameOfJsxOpeningLikeElement(node)
    if ast.IsJsxOpeningElement(node) or ast.IsJsxSelfClosingElement(node) then
        return node:TagName()
    end
    return nil
end

function ast.IsCallExpressionTarget(node, includeElementAccess, skipPastOuterExpressions)
    return ast.isCalleeWorker(node, ast.IsCallExpression, ast.selectExpressionOfCallOrNewExpressionOrDecorator,
        includeElementAccess, skipPastOuterExpressions)
end

function ast.IsNewExpressionTarget(node, includeElementAccess, skipPastOuterExpressions)
    return ast.isCalleeWorker(node, ast.IsNewExpression, ast.selectExpressionOfCallOrNewExpressionOrDecorator,
        includeElementAccess, skipPastOuterExpressions)
end

function ast.IsCallOrNewExpressionTarget(node, includeElementAccess, skipPastOuterExpressions)
    return ast.isCalleeWorker(node, ast.IsCallOrNewExpression, ast.selectExpressionOfCallOrNewExpressionOrDecorator,
        includeElementAccess, skipPastOuterExpressions)
end

function ast.IsTaggedTemplateTag(node, includeElementAccess, skipPastOuterExpressions)
    return ast.isCalleeWorker(node, ast.IsTaggedTemplateExpression, ast.selectTagOfTaggedTemplateExpression,
        includeElementAccess, skipPastOuterExpressions)
end

function ast.IsDecoratorTarget(node, includeElementAccess, skipPastOuterExpressions)
    return ast.isCalleeWorker(node, ast.IsDecorator, ast.selectExpressionOfCallOrNewExpressionOrDecorator,
        includeElementAccess, skipPastOuterExpressions)
end

function ast.IsJsxOpeningLikeElementTagName(node, includeElementAccess, skipPastOuterExpressions)
    return ast.isCalleeWorker(node, ast.IsJsxOpeningLikeElement, ast.selectTagNameOfJsxOpeningLikeElement,
        includeElementAccess, skipPastOuterExpressions)
end

function ast.isCalleeWorker(node, pred, calleeSelector, includeElementAccess, skipPastOuterExpressions)
    local target
    if includeElementAccess then
        target = ast.climbPastPropertyOrElementAccess(node)
    else
        target = ast.ClimbPastPropertyAccess(node)
    end
    if skipPastOuterExpressions then
        -- Only skip outer expressions if the target is actually an expression node
        if ast.IsExpression(target) then
            target = ast.SkipOuterExpressions(target, OuterExpressionKinds.OEKAll)
        end
    end
    return target ~= nil and target.parent ~= nil and pred(target.parent) and calleeSelector(target.parent) == target
end

function ast.IsRightSideOfQualifiedNameOrPropertyAccess(node)
    local parent = node.parent
    local kind = parent.kind
    if kind == Kind.QualifiedName then
        return parent.right == node
    elseif kind == Kind.PropertyAccessExpression then
        return parent:Name() == node
    elseif kind == Kind.MetaProperty then
        return parent:Name() == node
    end
    return false
end

function ast.ShouldTransformImportCall(fileName, options, impliedNodeFormatForEmit)
    local moduleKind = options:GetEmitModuleKind()
    if core.ModuleKind.Node16 <= moduleKind and moduleKind <= core.ModuleKind.NodeNext or
        moduleKind == core.ModuleKind.Preserve then
        return false
    end
    return impliedNodeFormatForEmit < core.ModuleKind.ES2015
end

function ast.HasQuestionToken(node)
    return ast.IsQuestionToken(node:QuestionToken())
end

function ast.IsJsxOpeningLikeElement(node)
    return ast.IsJsxOpeningElement(node) or ast.IsJsxSelfClosingElement(node)
end

function ast.GetInvokedExpression(node)
    local kind = node.kind
    if kind == Kind.TaggedTemplateExpression then
        return node.tag
    elseif kind == Kind.JsxOpeningElement or kind == Kind.JsxSelfClosingElement then
        return node:TagName()
    elseif kind == Kind.BinaryExpression then
        return node.right
    elseif kind == Kind.JsxOpeningFragment then
        return node
    end
    return node:Expression()
end

function ast.IsCallOrNewExpression(node)
    return ast.IsCallExpression(node) or ast.IsNewExpression(node)
end

-- slices.BinarySearchFunc: returns the 0-based insertion index and whether target was found.
function ast.binarySearchNodes(nodes, target, cmp)
    local lo, hi = 0, core.Len(nodes)
    while lo < hi do
        local mid = (lo + hi) // 2
        if cmp(nodes[mid + 1], target) < 0 then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo, lo < core.Len(nodes) and cmp(nodes[lo + 1], target) == 0
end

function ast.IndexOfNode(nodes, node)
    local index, ok = ast.binarySearchNodes(nodes, node, ast.CompareNodePositions)
    if ok then
        return index
    end
    return -1
end

function ast.CompareNodePositions(n1, n2)
    return core.CompareTextRanges(n1.loc, n2.loc)
end

function ast.IsUnterminatedLiteral(node)
    return ast.IsLiteralKind(node.kind) and node:LiteralLikeData().tokenFlags & TokenFlags.Unterminated ~= 0 or
        ast.IsTemplateLiteralKind(node.kind) and node:TemplateLiteralLikeData().templateFlags & TokenFlags.Unterminated ~= 0
end

-- Gets a value indicating whether a class element is either a static or an instance property declaration with an initializer.
function ast.IsInitializedProperty(member)
    return member.kind == Kind.PropertyDeclaration and
        member:Initializer() ~= nil
end

function ast.IsTrivia(token)
    return Kind.FirstTriviaToken <= token and token <= Kind.LastTriviaToken
end

function ast.HasDecorators(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Decorator)
end

local hasFileNameImpl = {}
hasFileNameImpl.__index = hasFileNameImpl
hasFileNameImpl.__name = "hasFileNameImpl"
ast.hasFileNameImpl = hasFileNameImpl

function ast.NewHasFileName(fileName, path)
    return setmetatable({
        fileName = fileName,
        path = path,
    }, hasFileNameImpl)
end

function hasFileNameImpl:FileName()
    return self.fileName
end

function hasFileNameImpl:Path()
    return self.path
end

function ast.GetSemanticJsxChildren(children)
    return core.Filter(children, function(i)
        if i.kind == Kind.JsxExpression then
            return i:Expression() ~= nil
        elseif i.kind == Kind.JsxText then
            return not i:AsJsxText().containsOnlyTriviaWhiteSpaces
        end
        return true
    end)
end

local hasCommentKinds = kindSet(Kind.JSDoc, Kind.JSDocUnknownTag, Kind.JSDocAugmentsTag, Kind.JSDocImplementsTag,
    Kind.JSDocDeprecatedTag, Kind.JSDocPublicTag, Kind.JSDocPrivateTag, Kind.JSDocProtectedTag,
    Kind.JSDocReadonlyTag, Kind.JSDocOverrideTag, Kind.JSDocCallbackTag, Kind.JSDocOverloadTag,
    Kind.JSDocParameterTag, Kind.JSDocPropertyTag, Kind.JSDocReturnTag, Kind.JSDocThisTag,
    Kind.JSDocTypeTag, Kind.JSDocTemplateTag, Kind.JSDocTypedefTag, Kind.JSDocSeeTag,
    Kind.JSDocThrowsTag, Kind.JSDocSatisfiesTag, Kind.JSDocImportTag)

-- Returns true if the node kind has a comment property.
function ast.hasComment(kind)
    return hasCommentKinds[kind] == true
end

function ast.IsAssignmentPattern(node)
    return node.kind == Kind.ArrayLiteralExpression or node.kind == Kind.ObjectLiteralExpression
end

function ast.GetElementsOfBindingOrAssignmentPattern(name)
    local kind = name.kind
    if kind == Kind.ObjectBindingPattern or kind == Kind.ArrayBindingPattern or kind == Kind.ArrayLiteralExpression then
        -- `a` in `{a}`
        -- `a` in `[a]`
        return name:Elements()
    elseif kind == Kind.ObjectLiteralExpression then
        -- `a` in `{a}`
        return name:Properties()
    end
    return nil
end

function ast.IsDeclarationBindingElement(bindingElement)
    local kind = bindingElement.kind
    return kind == Kind.VariableDeclaration or kind == Kind.Parameter or kind == Kind.BindingElement
end

--[[
 * Gets the name of an BindingOrAssignmentElement.
]]
function ast.GetTargetOfBindingOrAssignmentElement(bindingElement)
    if ast.IsDeclarationBindingElement(bindingElement) then
        -- `a` in `let { a } = ...`
        -- `a` in `let { a = 1 } = ...`
        -- `b` in `let { a: b } = ...`
        -- `b` in `let { a: b = 1 } = ...`
        -- `a` in `let { ...a } = ...`
        -- `{b}` in `let { a: {b} } = ...`
        -- `{b}` in `let { a: {b} = 1 } = ...`
        -- `[b]` in `let { a: [b] } = ...`
        -- `[b]` in `let { a: [b] = 1 } = ...`
        -- `a` in `let [a] = ...`
        -- `a` in `let [a = 1] = ...`
        -- `a` in `let [...a] = ...`
        -- `{a}` in `let [{a}] = ...`
        -- `{a}` in `let [{a} = 1] = ...`
        -- `[a]` in `let [[a]] = ...`
        -- `[a]` in `let [[a] = 1] = ...`
        return bindingElement:Name()
    end

    if ast.IsObjectLiteralElement(bindingElement) then
        local kind = bindingElement.kind
        if kind == Kind.PropertyAssignment then
            -- `b` in `({ a: b } = ...)`
            -- `b` in `({ a: b = 1 } = ...)`
            -- `{b}` in `({ a: {b} } = ...)`
            -- `{b}` in `({ a: {b} = 1 } = ...)`
            -- `[b]` in `({ a: [b] } = ...)`
            -- `[b]` in `({ a: [b] = 1 } = ...)`
            -- `b.c` in `({ a: b.c } = ...)`
            -- `b.c` in `({ a: b.c = 1 } = ...)`
            -- `b[0]` in `({ a: b[0] } = ...)`
            -- `b[0]` in `({ a: b[0] = 1 } = ...)`
            return ast.GetTargetOfBindingOrAssignmentElement(bindingElement:Initializer())
        elseif kind == Kind.ShorthandPropertyAssignment then
            -- `a` in `({ a } = ...)`
            -- `a` in `({ a = 1 } = ...)`
            return bindingElement:Name()
        elseif kind == Kind.SpreadAssignment then
            -- `a` in `({ ...a } = ...)`
            return ast.GetTargetOfBindingOrAssignmentElement(bindingElement:Expression())
        end

        -- no target
        return nil
    end

    if ast.IsAssignmentExpression(bindingElement, true --[[excludeCompoundAssignment]]) then
        -- `a` in `[a = 1] = ...`
        -- `{a}` in `[{a} = 1] = ...`
        -- `[a]` in `[[a] = 1] = ...`
        -- `a.b` in `[a.b = 1] = ...`
        -- `a[0]` in `[a[0] = 1] = ...`
        return ast.GetTargetOfBindingOrAssignmentElement(bindingElement.left)
    end

    if ast.IsSpreadElement(bindingElement) then
        -- `a` in `[...a] = ...`
        return ast.GetTargetOfBindingOrAssignmentElement(bindingElement:Expression())
    end

    -- `a` in `[a] = ...`
    -- `{a}` in `[{a}] = ...`
    -- `[a]` in `[[a]] = ...`
    -- `a.b` in `[a.b] = ...`
    -- `a[0]` in `[a[0]] = ...`
    return bindingElement
end

function ast.TryGetPropertyNameOfBindingOrAssignmentElement(bindingElement)
    local kind = bindingElement.kind
    if kind == Kind.BindingElement then
        -- `a` in `let { a: b } = ...`
        -- `[a]` in `let { [a]: b } = ...`
        -- `"a"` in `let { "a": b } = ...`
        -- `1` in `let { 1: b } = ...`
        if bindingElement:PropertyName() ~= nil then
            local propertyName = bindingElement:PropertyName()
            if ast.IsComputedPropertyName(propertyName) and ast.IsStringOrNumericLiteralLike(propertyName:Expression()) then
                return propertyName:Expression()
            end
            return propertyName
        end
    elseif kind == Kind.PropertyAssignment then
        -- `a` in `({ a: b } = ...)`
        -- `[a]` in `({ [a]: b } = ...)`
        -- `"a"` in `({ "a": b } = ...)`
        -- `1` in `({ 1: b } = ...)`
        if bindingElement:Name() ~= nil then
            local propertyName = bindingElement:Name()
            if ast.IsComputedPropertyName(propertyName) and ast.IsStringOrNumericLiteralLike(propertyName:Expression()) then
                return propertyName:Expression()
            end
            return propertyName
        end
    elseif kind == Kind.SpreadAssignment then
        -- `a` in `({ ...a } = ...)`
        return bindingElement:Name()
    end

    local target = ast.GetTargetOfBindingOrAssignmentElement(bindingElement)
    if target ~= nil and ast.IsPropertyName(target) then
        return target
    end
    return nil
end

--[[
 * Walk an AssignmentPattern to determine if it contains object rest (`...`) syntax. We cannot rely on
 * propagation of `TransformFlags.ContainsObjectRestOrSpread` since it isn't propagated by default in
 * ObjectLiteralExpression and ArrayLiteralExpression since we do not know whether they belong to an
 * AssignmentPattern at the time the nodes are parsed.
]]
function ast.ContainsObjectRestOrSpread(node)
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
        return true
    end
    if node:SubtreeFacts() & SubtreeFacts.SubtreeContainsESObjectRestOrSpread ~= 0 then
        -- check for nested spread assignments, otherwise '{ x: { a, ...b } = foo } = c'
        -- will not be correctly interpreted by the rest/spread transformer
        local elements = ast.GetElementsOfBindingOrAssignmentPattern(node)
        if elements ~= nil then
            for _, element in ipairs(elements) do
                local target = ast.GetTargetOfBindingOrAssignmentElement(element)
                if target ~= nil and ast.IsAssignmentPattern(target) then
                    if target:SubtreeFacts() & SubtreeFacts.SubtreeContainsObjectRestOrSpread ~= 0 then
                        return true
                    end
                    if target:SubtreeFacts() & SubtreeFacts.SubtreeContainsESObjectRestOrSpread ~= 0 then
                        if ast.ContainsObjectRestOrSpread(target) then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

function ast.IsEmptyObjectLiteral(expression)
    return ast.IsObjectLiteralExpression(expression) and core.Len(expression:Properties()) == 0
end

function ast.IsEmptyArrayLiteral(expression)
    return ast.IsArrayLiteralExpression(expression) and core.Len(expression:Elements()) == 0
end

function ast.GetRestIndicatorOfBindingOrAssignmentElement(bindingElement)
    local kind = bindingElement.kind
    if kind == Kind.Parameter or kind == Kind.BindingElement then
        return bindingElement.dotDotDotToken
    elseif kind == Kind.SpreadElement or kind == Kind.SpreadAssignment then
        return bindingElement
    end
    return nil
end

function ast.IsJSDocNameReferenceContext(node)
    return node.flags & NodeFlags.JSDoc ~= 0 and ast.FindAncestor(node, function(n)
        return ast.IsJSDocNameReference(n) or ast.IsJSDocLinkLike(n)
    end) ~= nil
end

-- GetJSDocRoot returns the containing JSDoc node for a node inside a JSDoc comment.
function ast.GetJSDocRoot(node)
    return ast.FindAncestor(node.parent, function(n)
        return n.kind == Kind.JSDoc
    end)
end

-- GetJSDocHost returns the declaration that the JSDoc comment containing the given node is attached to.
function ast.GetJSDocHost(node)
    local jsDoc = ast.GetJSDocRoot(node)
    if jsDoc == nil then
        return nil
    end
    return jsDoc.parent
end

-- GetHostSignatureFromJSDoc returns the function-like declaration that hosts the JSDoc comment
-- containing the given node. This is used to resolve @link references to parameters.
function ast.GetHostSignatureFromJSDoc(node)
    local host = ast.GetJSDocHost(node)
    if host == nil then
        return nil
    end
    -- !!! Strada's getEffectiveJSDocHost applies JS assignment pattern transforms (getSourceOfAssignment, getSourceOfDefaultedAssignment, etc.) not yet ported
    if ast.IsPropertySignatureDeclaration(host) and host:Type() ~= nil and ast.IsFunctionLike(host:Type()) then
        return host:Type()
    end
    if ast.IsFunctionLike(host) then
        return host
    end
    return nil
end

local nextJSDocCommentLocationKinds = kindSet(Kind.PropertyAssignment, Kind.ExportAssignment,
    Kind.PropertyDeclaration, Kind.VariableDeclaration, Kind.SatisfiesExpression, Kind.ReturnStatement,
    Kind.VariableStatement, Kind.ExpressionStatement)

-- Finds the declaration that owns the JSDoc for a function-like node.
-- Keep these hosts aligned with JSDoc parameter reparsing so unmatched @param diagnostics use the same attachment rules.
-- Keep in sync with getNextJSDocCommentLocation in the API's src/ast/jsdoc.ts
function ast.GetNextJSDocCommentLocation(node)
    local parent = node.parent
    if parent ~= nil then
        if nextJSDocCommentLocationKinds[parent.kind] then
            return parent
        elseif parent.kind == Kind.VariableDeclarationList then
            if parent.declarations.nodes[1] == node then
                return parent
            end
        end
    end
    return nil
end

function ast.IsImportOrImportEqualsDeclaration(node)
    return ast.IsImportDeclaration(node) or ast.IsImportEqualsDeclaration(node)
end

local primitiveLiteralValueKinds = kindSet(Kind.TrueKeyword, Kind.FalseKeyword, Kind.NumericLiteral,
    Kind.StringLiteral, Kind.NoSubstitutionTemplateLiteral)

function ast.IsPrimitiveLiteralValue(node, includeBigInt)
    local kind = node.kind
    if primitiveLiteralValueKinds[kind] then
        return true
    elseif kind == Kind.BigIntLiteral then
        return includeBigInt
    elseif kind == Kind.PrefixUnaryExpression then
        if node.operator == Kind.MinusToken then
            return ast.IsNumericLiteral(node.operand) or (includeBigInt and ast.IsBigIntLiteral(node.operand))
        end
        if node.operator == Kind.PlusToken then
            return ast.IsNumericLiteral(node.operand)
        end
        return false
    end
    return false
end

local hasInferredTypeKinds = kindSet(Kind.Parameter, Kind.PropertySignature, Kind.PropertyDeclaration,
    Kind.BindingElement, Kind.PropertyAccessExpression, Kind.ElementAccessExpression, Kind.BinaryExpression,
    Kind.CallExpression, Kind.VariableDeclaration, Kind.ExportAssignment, Kind.PropertyAssignment,
    Kind.ShorthandPropertyAssignment, Kind.JSDocParameterTag, Kind.JSDocPropertyTag)

function ast.HasInferredType(node)
    -- Debug.type<HasInferredType>(node); // !!!
    return hasInferredTypeKinds[node.kind] == true
end

function ast.IsKeyword(token)
    return Kind.FirstKeyword <= token and token <= Kind.LastKeyword
end

function ast.IsNonContextualKeyword(token)
    return ast.IsKeyword(token) and not ast.IsContextualKeyword(token)
end

function ast.HasModifier(node, flags)
    return node:ModifierFlags() & flags ~= 0
end

function ast.IsExpandoInitializer(declaration, initializer)
    if initializer == nil then
        return false
    end
    if ast.IsFunctionExpressionOrArrowFunction(initializer) then
        return true
    end
    if ast.IsInJSFile(initializer) then
        return ast.IsClassExpression(initializer) or
            (ast.IsObjectLiteralExpression(initializer) and core.Len(initializer:Properties()) == 0 and
                declaration:Type() == nil)
    end
    return false
end

function ast.GetContainingFunction(node)
    return ast.FindAncestor(node.parent, ast.IsFunctionLike)
end

function ast.ImportFromModuleSpecifier(node)
    local result = ast.TryGetImportFromModuleSpecifier(node)
    if result ~= nil then
        return result
    end
    debug.FailBadSyntaxKind(node.parent)
    return nil
end

function ast.TryGetImportFromModuleSpecifier(node)
    local kind = node.parent.kind
    if kind == Kind.ImportDeclaration or kind == Kind.JSImportDeclaration or kind == Kind.ExportDeclaration then
        return node.parent
    elseif kind == Kind.ExternalModuleReference then
        return node.parent.parent
    elseif kind == Kind.CallExpression then
        if ast.IsImportCall(node.parent) or ast.IsRequireCall(node.parent, false --[[requireStringLiteralLikeArgument]]) then
            return node.parent
        end
        return nil
    elseif kind == Kind.LiteralType then
        if not ast.IsStringLiteral(node) then
            return nil
        end
        if ast.IsImportTypeNode(node.parent.parent) then
            return node.parent.parent
        end
        return nil
    end
    return nil
end

function ast.IsImplicitlyExportedJSDocDeclaration(node)
    if not ast.IsSourceFile(node.parent) or not ast.IsExternalOrCommonJSModule(node.parent:AsSourceFile()) then
        return false
    end
    if ast.IsJSTypeAliasDeclaration(node) then
        return true
    end
    -- A reparsed ModuleDeclaration synthesized from a JSDoc @typedef/@callback
    -- dotted name should also be treated as implicitly exported in modules.
    return ast.IsModuleDeclaration(node) and node.flags & NodeFlags.Reparsed ~= 0
end

function ast.HasContextSensitiveParameters(node)
    -- Functions with type parameters are not context sensitive.
    if node:TypeParameters() == nil then
        -- Functions with any parameters that lack type annotations are context sensitive.
        if core.Some(node:Parameters(), function(p) return p:Type() == nil end) then
            return true
        end
        if not ast.IsArrowFunction(node) then
            -- If the first parameter is not an explicit 'this' parameter, then the function has
            -- an implicit 'this' parameter which is subject to contextual typing.
            local parameter = core.FirstOrNil(node:Parameters())
            if parameter == nil or not ast.IsThisParameter(parameter) then
                return node.flags & NodeFlags.ContainsThis ~= 0
            end
        end
    end
    return false
end

function ast.IsInfinityOrNaNString(name)
    return name == "Infinity" or name == "-Infinity" or name == "NaN"
end

function ast.GetFirstConstructorWithBody(node)
    for _, member in ipairs(node:Members()) do
        if ast.IsConstructorDeclaration(member) and ast.NodeIsPresent(member:Body()) then
            return member
        end
    end
    return nil
end

-- Returns true for nodes that are considered executable for the purposes of unreachable code detection.
function ast.IsPotentiallyExecutableNode(node)
    if Kind.FirstStatement <= node.kind and node.kind <= Kind.LastStatement then
        if ast.IsVariableStatement(node) then
            local declarationList = node.declarationList
            if ast.GetCombinedNodeFlags(declarationList) & NodeFlags.BlockScoped ~= 0 then
                return true
            end
            local declarations = declarationList.declarations.nodes
            return core.Some(declarations, function(d)
                return d:Initializer() ~= nil
            end)
        end
        return true
    end
    return ast.IsClassDeclaration(node) or ast.IsEnumDeclaration(node) or ast.IsModuleDeclaration(node)
end

function ast.HasAbstractModifier(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Abstract)
end

function ast.HasAmbientModifier(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Ambient)
end

function ast.NodeCanBeDecorated(useLegacyDecorators, node, parent, grandparent)
    -- private names cannot be used with decorators yet
    if useLegacyDecorators and node:Name() ~= nil and ast.IsPrivateIdentifier(node:Name()) then
        return false
    end
    local kind = node.kind
    if kind == Kind.ClassDeclaration then
        -- class declarations are valid targets
        return true
    elseif kind == Kind.ClassExpression then
        -- class expressions are valid targets for native decorators
        return not useLegacyDecorators
    elseif kind == Kind.PropertyDeclaration then
        -- property declarations are valid if their parent is a class declaration.
        return parent ~= nil and (useLegacyDecorators and ast.IsClassDeclaration(parent) or
            not useLegacyDecorators and ast.IsClassLike(parent) and not ast.HasAbstractModifier(node) and
            not ast.HasAmbientModifier(node))
    elseif kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.MethodDeclaration then
        -- if this method has a body and its parent is a class declaration, this is a valid target.
        return parent ~= nil and node:Body() ~= nil and (useLegacyDecorators and ast.IsClassDeclaration(parent) or
            not useLegacyDecorators and ast.IsClassLike(parent))
    elseif kind == Kind.Parameter then
        -- TODO(rbuckton): ParameterDeclaration decorator support for ES decorators must wait until it is standardized
        if not useLegacyDecorators then
            return false
        end
        -- if the parameter's parent has a body and its grandparent is a class declaration, this is a valid target.
        return parent ~= nil and parent:Body() ~= nil and
            (parent.kind == Kind.Constructor or parent.kind == Kind.MethodDeclaration or parent.kind == Kind.SetAccessor) and
            ast.GetThisParameter(parent) ~= node and grandparent ~= nil and grandparent.kind == Kind.ClassDeclaration
    end

    return false
end

function ast.ClassOrConstructorParameterIsDecorated(useLegacyDecorators, node)
    if ast.NodeIsDecorated(useLegacyDecorators, node, nil, nil) then
        return true
    end
    local constructor = ast.GetFirstConstructorWithBody(node)
    return constructor ~= nil and ast.ChildIsDecorated(useLegacyDecorators, constructor, node)
end

function ast.ClassElementOrClassElementParameterIsDecorated(useLegacyDecorators, node, parent)
    local parameters = nil
    if ast.IsAccessor(node) then
        local decls = ast.GetAllAccessorDeclarations(parent:Members(), node)
        local firstAccessorWithDecorators = nil
        if ast.HasDecorators(decls.firstAccessor) then
            firstAccessorWithDecorators = decls.firstAccessor
        elseif decls.secondAccessor ~= nil and ast.HasDecorators(decls.secondAccessor) then
            firstAccessorWithDecorators = decls.secondAccessor
        end
        if firstAccessorWithDecorators == nil or node ~= firstAccessorWithDecorators then
            return false
        end
        if decls.setAccessor ~= nil then
            parameters = decls.setAccessor.parameters
        end
    elseif ast.IsMethodDeclaration(node) then
        parameters = node:ParameterList()
    end
    if ast.NodeIsDecorated(useLegacyDecorators, node, parent, nil) then
        return true
    end
    if parameters ~= nil and #parameters.nodes > 0 then
        for _, parameter in ipairs(parameters.nodes) do
            if not ast.IsThisParameter(parameter) then
                if ast.NodeIsDecorated(useLegacyDecorators, parameter, node, parent) then
                    return true
                end
            end
        end
    end
    return false
end

function ast.NodeIsDecorated(useLegacyDecorators, node, parent, grandparent)
    return ast.HasDecorators(node) and ast.NodeCanBeDecorated(useLegacyDecorators, node, parent, grandparent)
end

function ast.NodeOrChildIsDecorated(useLegacyDecorators, node, parent, grandparent)
    return ast.NodeIsDecorated(useLegacyDecorators, node, parent, grandparent) or
        ast.ChildIsDecorated(useLegacyDecorators, node, parent)
end

function ast.ChildIsDecorated(useLegacyDecorators, node, parent)
    local kind = node.kind
    if kind == Kind.ClassDeclaration or kind == Kind.ClassExpression then
        return core.Some(node:Members(), function(m)
            return ast.NodeOrChildIsDecorated(useLegacyDecorators, m, node, parent)
        end)
    elseif kind == Kind.MethodDeclaration or kind == Kind.SetAccessor or kind == Kind.Constructor then
        return core.Some(node:Parameters(), function(p)
            return ast.NodeIsDecorated(useLegacyDecorators, p, node, parent)
        end)
    end
    return false
end

-- AllAccessorDeclarations: { firstAccessor, secondAccessor, setAccessor, getAccessor } (Go value struct)

function ast.GetAllAccessorDeclarationsForDeclaration(accessor, declarationsOfSymbol)
    local otherKind
    if accessor.kind == Kind.SetAccessor then
        otherKind = Kind.GetAccessor
    elseif accessor.kind == Kind.GetAccessor then
        otherKind = Kind.SetAccessor
    else
        error(string.format("Unexpected node kind %q", ast.Kind_String(accessor.kind)))
    end
    -- otherAccessor := GetDeclarationOfKind(c.getSymbolOfDeclaration(accessor), otherKind)
    local otherAccessor = nil
    if declarationsOfSymbol ~= nil then
        for _, d in ipairs(declarationsOfSymbol) do
            if d.kind == otherKind then
                otherAccessor = d
                break
            end
        end
    end

    local firstAccessor, secondAccessor
    if otherAccessor ~= nil and (otherAccessor:Pos() < accessor:Pos()) then
        firstAccessor = otherAccessor
        secondAccessor = accessor
    else
        firstAccessor = accessor
        secondAccessor = otherAccessor
    end

    local setAccessor, getAccessor
    if accessor.kind == Kind.SetAccessor then
        setAccessor = accessor:AsSetAccessorDeclaration()
        if otherAccessor ~= nil then
            getAccessor = otherAccessor:AsGetAccessorDeclaration()
        end
    else
        getAccessor = accessor:AsGetAccessorDeclaration()
        if otherAccessor ~= nil then
            setAccessor = otherAccessor:AsSetAccessorDeclaration()
        end
    end

    return {
        firstAccessor = firstAccessor,
        secondAccessor = secondAccessor,
        setAccessor = setAccessor,
        getAccessor = getAccessor,
    }
end

function ast.GetAllAccessorDeclarations(parentDeclarations, accessor)
    if ast.HasDynamicName(accessor) then
        -- dynamic names can only be match up via checker symbol lookup, just return an object with just this accessor
        return ast.GetAllAccessorDeclarationsForDeclaration(accessor, { accessor })
    end

    local accessorName = ast.GetPropertyNameForPropertyNameNode(accessor:Name())
    local accessorStatic = ast.IsStatic(accessor)
    local matches = nil
    if parentDeclarations ~= nil then
        for _, member in ipairs(parentDeclarations) do
            if ast.IsAccessor(member) and ast.IsStatic(member) == accessorStatic then
                local memberName = ast.GetPropertyNameForPropertyNameNode(member:Name())
                if memberName == accessorName then
                    matches = core.Append(matches, member)
                end
            end
        end
    end
    return ast.GetAllAccessorDeclarationsForDeclaration(accessor, matches)
end

local asyncFunctionKinds = kindSet(Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ArrowFunction,
    Kind.MethodDeclaration)

function ast.IsAsyncFunction(node)
    if asyncFunctionKinds[node.kind] then
        local data = node:BodyData()
        return data.body ~= nil and data.asteriskToken == nil and ast.HasSyntacticModifier(node, ModifierFlags.Async)
    end
    return false
end

--[[
 * Gets the most likely element type for a TypeNode. This is not an exhaustive test
 * as it assumes a rest argument can only be an array type (either T[], or Array<T>).
 *
 * @param node The type node.
 *
 * @internal
]]
function ast.GetRestParameterElementType(node)
    if node == nil then
        return node
    end
    if node.kind == Kind.ArrayType then
        return node.elementType
    end
    if node.kind == Kind.TypeReference and node.typeArguments ~= nil then
        return core.FirstOrNil(node.typeArguments.nodes)
    end
    return nil
end

function ast.TagNamesAreEquivalent(lhs, rhs)
    if lhs.kind ~= rhs.kind then
        return false
    end
    local kind = lhs.kind
    if kind == Kind.Identifier then
        return lhs:Text() == rhs:Text()
    elseif kind == Kind.ThisKeyword then
        return true
    elseif kind == Kind.JsxNamespacedName then
        return lhs.namespace:Text() == rhs.namespace:Text() and
            lhs:Name():Text() == rhs:Name():Text()
    elseif kind == Kind.PropertyAccessExpression then
        return lhs:Name():Text() == rhs:Name():Text() and
            ast.TagNamesAreEquivalent(lhs:Expression(), rhs:Expression())
    end
    error("Unhandled case in TagNamesAreEquivalent")
end

function ast.IsTagName(node)
    return node.parent ~= nil and ast.IsJSDocTag(node.parent) and node.parent:TagName() == node
end

-- We want to store any numbers/strings if they were a name that could be
-- related to a declaration.  So, if we have 'import x = require("something")'
-- then we want 'something' to be in the name table.  Similarly, if we have
-- "a['propname']" then we want to store "propname" in the name table.
function ast.literalIsName(node)
    return ast.IsDeclarationName(node) or
        node.parent.kind == Kind.ExternalModuleReference or
        ast.isArgumentOfElementAccessExpression(node) or
        ast.IsLiteralComputedPropertyDeclarationName(node)
end

function ast.isArgumentOfElementAccessExpression(node)
    return node ~= nil and node.parent ~= nil and
        node.parent.kind == Kind.ElementAccessExpression and
        node.parent.argumentExpression == node
end

-- If the given node is part of a subtree of JSDoc nodes that have been cloned into a reparsed construct,
-- return the corresponding reparsed clone in the subtree. Otherwise, just return the node.
function ast.GetReparsedNodeForNode(node)
    if node ~= nil and node.flags & NodeFlags.JSDoc ~= 0 and node.flags & NodeFlags.Reparsed == 0 then
        local file = ast.GetSourceFileOfNode(node)
        if file ~= nil and core.Len(file.reparsedClones) ~= 0 then
            local pos, found = ast.binarySearchNodes(file.reparsedClones, node, ast.CompareNodePositions)
            if not found and pos > 0 then
                pos = pos - 1
            end
            local candidate = file.reparsedClones[pos + 1]
            if node.loc:ContainedBy(candidate.loc) then
                local reparsed = ast.findCloneInNode(candidate, node)
                if reparsed ~= nil then
                    return reparsed
                end
            end
        end
    end
    return node
end

function ast.findCloneInNode(node, original)
    while true do
        if node.kind == original.kind and node.loc == original.loc then
            return node
        end
        local foundContainingChild = node:ForEachChild(function(n)
            if original.loc:ContainedBy(n.loc) then
                node = n
                return true
            end
            return false
        end)
        if not foundContainingChild then
            return nil
        end
    end
end

function ast.IsExpandoPropertyDeclaration(node)
    return node ~= nil and ast.IsBinaryExpression(node)
end

-- IsSuperProperty checks if a node is super.x or super[x].
function ast.IsSuperProperty(node)
    return (ast.IsPropertyAccessExpression(node) or ast.IsElementAccessExpression(node)) and
        node:Expression().kind == Kind.SuperKeyword
end

-- Indicates whether a node is a potential source of an assigned name for a class, function, or arrow function.
function ast.IsNamedEvaluationSource(node)
    local kind = node.kind
    if kind == Kind.PropertyAssignment then
        return not ast.IsProtoSetter(node:Name())
    elseif kind == Kind.ShorthandPropertyAssignment then
        return node.objectAssignmentInitializer ~= nil
    elseif kind == Kind.VariableDeclaration then
        return ast.IsIdentifier(node:Name()) and node:Initializer() ~= nil
    elseif kind == Kind.Parameter then
        return ast.IsIdentifier(node:Name()) and node:Initializer() ~= nil and node.dotDotDotToken == nil
    elseif kind == Kind.BindingElement then
        return ast.IsIdentifier(node:Name()) and node:Initializer() ~= nil and node.dotDotDotToken == nil
    elseif kind == Kind.PropertyDeclaration then
        return node:Initializer() ~= nil
    elseif kind == Kind.BinaryExpression then
        local op = node.operatorToken.kind
        if op == Kind.EqualsToken or op == Kind.AmpersandAmpersandEqualsToken or op == Kind.BarBarEqualsToken or
            op == Kind.QuestionQuestionEqualsToken then
            return ast.IsIdentifier(node.left)
        end
    elseif kind == Kind.ExportAssignment then
        return true
    end
    return false
end

-- Indicates whether a property name is the special `__proto__` property.
-- Per the ECMA-262 spec, this only matters for property assignments whose name is
-- the Identifier `__proto__`, or the string literal `"__proto__"`, but not for
-- computed property names.
function ast.IsProtoSetter(node)
    return (ast.IsIdentifier(node) or ast.IsStringLiteral(node)) and node:Text() == "__proto__"
end
