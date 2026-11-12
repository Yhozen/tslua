local lsutil = require("tslua.ls.lsutil")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local FindAncestorResult = ast.FindAncestorResult
local ScriptElementKind = lsutil.ScriptElementKind
local ScriptElementKindModifier = lsutil.ScriptElementKindModifier

lsutil.scriptElementKindModifierNames = {
    { flag = ScriptElementKindModifier.Public, name = "public" },
    { flag = ScriptElementKindModifier.Private, name = "private" },
    { flag = ScriptElementKindModifier.Protected, name = "protected" },
    { flag = ScriptElementKindModifier.Exported, name = "export" },
    { flag = ScriptElementKindModifier.Ambient, name = "declare" },
    { flag = ScriptElementKindModifier.Static, name = "static" },
    { flag = ScriptElementKindModifier.Abstract, name = "abstract" },
    { flag = ScriptElementKindModifier.Optional, name = "optional" },
    { flag = ScriptElementKindModifier.Deprecated, name = "deprecated" },
    { flag = ScriptElementKindModifier.Dts, name = ".d.ts" },
    { flag = ScriptElementKindModifier.Ts, name = ".ts" },
    { flag = ScriptElementKindModifier.Tsx, name = ".tsx" },
    { flag = ScriptElementKindModifier.Js, name = ".js" },
    { flag = ScriptElementKindModifier.Jsx, name = ".jsx" },
    { flag = ScriptElementKindModifier.Json, name = ".json" },
    { flag = ScriptElementKindModifier.Dmts, name = ".d.mts" },
    { flag = ScriptElementKindModifier.Mts, name = ".mts" },
    { flag = ScriptElementKindModifier.Mjs, name = ".mjs" },
    { flag = ScriptElementKindModifier.Dcts, name = ".d.cts" },
    { flag = ScriptElementKindModifier.Cts, name = ".cts" },
    { flag = ScriptElementKindModifier.Cjs, name = ".cjs" },
}

-- Go ScriptElementKindModifier.Strings(): returns a collections.Set of names.
function lsutil.ScriptElementKindModifier_Strings(m)
    local result = collections.NewSet()
    for _, entry in ipairs(lsutil.scriptElementKindModifierNames) do
        if m & entry.flag ~= 0 then
            result:Add(entry.name)
        end
    end
    return result
end

lsutil.FileExtensionKindModifiers = ScriptElementKindModifier.Dts |
    ScriptElementKindModifier.Ts |
    ScriptElementKindModifier.Tsx |
    ScriptElementKindModifier.Js |
    ScriptElementKindModifier.Jsx |
    ScriptElementKindModifier.Json |
    ScriptElementKindModifier.Dmts |
    ScriptElementKindModifier.Mts |
    ScriptElementKindModifier.Mjs |
    ScriptElementKindModifier.Dcts |
    ScriptElementKindModifier.Cts |
    ScriptElementKindModifier.Cjs

function lsutil.GetSymbolKind(typeChecker, symbol, location)
    local result = lsutil.getSymbolKindOfConstructorPropertyMethodAccessorFunctionOrVar(typeChecker, symbol, location)
    if result ~= ScriptElementKind.Unknown then
        return result
    end
    local flags = symbol:CombinedLocalAndExportSymbolFlags()
    if flags & SymbolFlags.Class ~= 0 then
        local decl = ast.GetDeclarationOfKind(symbol, Kind.ClassExpression)
        if decl ~= nil then
            return ScriptElementKind.LocalClassElement
        end
        return ScriptElementKind.ClassElement
    end
    if flags & SymbolFlags.Enum ~= 0 then
        return ScriptElementKind.EnumElement
    end
    if flags & SymbolFlags.TypeAlias ~= 0 then
        return ScriptElementKind.TypeElement
    end
    if flags & SymbolFlags.Interface ~= 0 then
        return ScriptElementKind.InterfaceElement
    end
    if flags & SymbolFlags.TypeParameter ~= 0 then
        return ScriptElementKind.TypeParameterElement
    end
    if flags & SymbolFlags.EnumMember ~= 0 then
        return ScriptElementKind.EnumMemberElement
    end
    if flags & SymbolFlags.Alias ~= 0 then
        return ScriptElementKind.Alias
    end
    if flags & SymbolFlags.Module ~= 0 then
        return ScriptElementKind.ModuleElement
    end

    return ScriptElementKind.Unknown
end

function lsutil.getSymbolKindOfConstructorPropertyMethodAccessorFunctionOrVar(typeChecker, symbol, location)
    local roots
    if typeChecker ~= nil then
        roots = typeChecker:GetRootSymbols(symbol)
    else
        roots = { symbol }
    end

    -- If this is a method from a mapped type, leave as a method so long as it still has a call signature, as opposed to e.g.
    -- `{ [K in keyof I]: number }`.
    if core.Len(roots) == 1 and
        roots[1].flags & SymbolFlags.Method ~= 0 and
        (typeChecker == nil or core.Len(typeChecker:GetCallSignatures(typeChecker:GetNonNullableType(typeChecker:GetTypeOfSymbolAtLocation(symbol, location)))) > 0) then
        return ScriptElementKind.MemberFunctionElement
    end

    if typeChecker ~= nil then
        if typeChecker:IsUndefinedSymbol(symbol) then
            return ScriptElementKind.VariableElement
        end
        if typeChecker:IsArgumentsSymbol(symbol) then
            return ScriptElementKind.LocalVariableElement
        end
        if location.kind == Kind.ThisKeyword and ast.IsExpression(location) or
            ast.IsThisInTypeQuery(location) then
            return ScriptElementKind.ParameterElement
        end
    end

    local flags = symbol:CombinedLocalAndExportSymbolFlags()
    if flags & SymbolFlags.Variable ~= 0 then
        if lsutil.isFirstDeclarationOfSymbolParameter(symbol) then
            return ScriptElementKind.ParameterElement
        elseif symbol.valueDeclaration ~= nil and ast.IsVarConst(symbol.valueDeclaration) then
            return ScriptElementKind.ConstElement
        elseif symbol.valueDeclaration ~= nil and ast.IsVarUsing(symbol.valueDeclaration) then
            return ScriptElementKind.VariableUsingElement
        elseif symbol.valueDeclaration ~= nil and ast.IsVarAwaitUsing(symbol.valueDeclaration) then
            return ScriptElementKind.VariableAwaitUsingElement
        elseif core.Some(symbol.declarations, ast.IsLet) then
            return ScriptElementKind.LetElement
        end
        if lsutil.isLocalVariableOrFunction(symbol) then
            return ScriptElementKind.LocalVariableElement
        end
        return ScriptElementKind.VariableElement
    end
    if flags & SymbolFlags.Function ~= 0 then
        if lsutil.isLocalVariableOrFunction(symbol) then
            return ScriptElementKind.LocalFunctionElement
        end
        return ScriptElementKind.FunctionElement
    end
    -- FIXME: getter and setter use the same symbol. And it is rare to use only setter without getter, so in most cases the symbol always has getter flag.
    -- So, even when the location is just on the declaration of setter, this function returns getter.
    if flags & SymbolFlags.GetAccessor ~= 0 then
        return ScriptElementKind.MemberGetAccessorElement
    end
    if flags & SymbolFlags.SetAccessor ~= 0 then
        return ScriptElementKind.MemberSetAccessorElement
    end
    if flags & SymbolFlags.Method ~= 0 then
        return ScriptElementKind.MemberFunctionElement
    end
    if flags & SymbolFlags.Constructor ~= 0 then
        return ScriptElementKind.ConstructorImplementationElement
    end
    if flags & SymbolFlags.Signature ~= 0 then
        return ScriptElementKind.IndexSignatureElement
    end

    if flags & SymbolFlags.Property ~= 0 then
        if typeChecker ~= nil and flags & SymbolFlags.Transient ~= 0 and symbol.checkFlags & ast.CheckFlags.Synthetic ~= 0 then
            -- If union property is result of union of non method (property/accessors/variables), it is labeled as property
            local unionPropertyKind = ScriptElementKind.Unknown
            for _, rootSymbol in ipairs(roots) do
                if rootSymbol.flags & (SymbolFlags.PropertyOrAccessor | SymbolFlags.Variable) ~= 0 then
                    unionPropertyKind = ScriptElementKind.MemberVariableElement
                    break
                end
            end
            if unionPropertyKind == ScriptElementKind.Unknown then
                -- If this was union of all methods,
                -- make sure it has call signatures before we can label it as method.
                local typeOfUnionProperty = typeChecker:GetTypeOfSymbolAtLocation(symbol, location)
                if core.Len(typeChecker:GetCallSignatures(typeOfUnionProperty)) > 0 then
                    return ScriptElementKind.MemberFunctionElement
                end
                return ScriptElementKind.MemberVariableElement
            end
            return unionPropertyKind
        end

        return ScriptElementKind.MemberVariableElement
    end

    return ScriptElementKind.Unknown
end

function lsutil.isFirstDeclarationOfSymbolParameter(symbol)
    local declaration
    if core.Len(symbol.declarations) > 0 then
        declaration = symbol.declarations[1]
    end
    local result = ast.FindAncestorOrQuit(declaration, function(n)
        if ast.IsParameterDeclaration(n) then
            return FindAncestorResult.FindAncestorTrue
        end
        if ast.IsBindingElement(n) or ast.IsObjectBindingPattern(n) or ast.IsArrayBindingPattern(n) then
            return FindAncestorResult.FindAncestorFalse
        end
        return FindAncestorResult.FindAncestorQuit
    end)

    return result ~= nil
end

function lsutil.isLocalVariableOrFunction(symbol)
    if symbol.parent ~= nil then
        return false -- This is exported symbol
    end

    for _, decl in ipairs(symbol.declarations or {}) do
        -- Function expressions are local
        if decl.kind == Kind.FunctionExpression then
            return true
        end

        if decl.kind ~= Kind.VariableDeclaration and decl.kind ~= Kind.FunctionDeclaration then
            goto continue
        end

        do
            -- If the parent is not source file or module block, it is a local variable.
            local parent = decl.parent
            while not ast.IsFunctionBlock(parent) do
                -- Reached source file or module block
                if parent.kind == Kind.SourceFile or parent.kind == Kind.ModuleBlock then
                    break
                end
                parent = parent.parent
            end

            if ast.IsFunctionBlock(parent) then
                -- Parent is in function block.
                return true
            end
        end
        ::continue::
    end
    return false
end

function lsutil.GetSymbolModifiers(typeChecker, symbol)
    if symbol == nil then
        return ScriptElementKindModifier.None
    end

    local modifiers = lsutil.getNormalizedSymbolModifiers(typeChecker, symbol)
    if symbol.flags & SymbolFlags.Alias ~= 0 and typeChecker ~= nil then
        local resolvedSymbol = typeChecker:GetAliasedSymbol(symbol)
        if resolvedSymbol ~= symbol then
            modifiers = modifiers | lsutil.getNormalizedSymbolModifiers(typeChecker, resolvedSymbol)
        end
    end
    if symbol.flags & SymbolFlags.Optional ~= 0 then
        modifiers = modifiers | ScriptElementKindModifier.Optional
    end

    return modifiers
end

function lsutil.getNormalizedSymbolModifiers(typeChecker, symbol)
    local modifierSet = ScriptElementKindModifier.None
    if core.Len(symbol.declarations) > 0 then
        local declaration = symbol.declarations[1]
        local declarations = core.Slice(symbol.declarations, 1, #symbol.declarations)
        -- omit deprecated flag if some declarations are not deprecated
        local excludeFlags
        if #declarations > 0 and
            lsutil.isDeprecatedDeclaration(typeChecker, declaration) and -- !!! include jsdoc node flags
            core.Some(declarations, function(d)
                return not lsutil.isDeprecatedDeclaration(typeChecker, d)
            end) then
            excludeFlags = ModifierFlags.Deprecated
        else
            excludeFlags = ModifierFlags.None
        end
        modifierSet = lsutil.getNodeModifiers(typeChecker, declaration, excludeFlags)
    end

    return modifierSet
end

function lsutil.isDeprecatedDeclaration(typeChecker, declaration)
    if typeChecker ~= nil then
        return typeChecker:IsDeprecatedDeclaration(declaration)
    end
    return ast.IsDeprecatedDeclaration(declaration)
end

function lsutil.getNodeModifiers(typeChecker, node, excludeFlags)
    local result = ScriptElementKindModifier.None
    local flags = ModifierFlags.None
    if ast.IsDeclaration(node) then
        flags = ast.GetCombinedModifierFlags(node)
        if lsutil.isDeprecatedDeclaration(typeChecker, node) then
            flags = flags | ModifierFlags.Deprecated
        end
        flags = flags & ~excludeFlags
    end

    if flags & ModifierFlags.Private ~= 0 then
        result = result | ScriptElementKindModifier.Private
    end
    if flags & ModifierFlags.Protected ~= 0 then
        result = result | ScriptElementKindModifier.Protected
    end
    if flags & ModifierFlags.Public ~= 0 then
        result = result | ScriptElementKindModifier.Public
    end
    if flags & ModifierFlags.Static ~= 0 then
        result = result | ScriptElementKindModifier.Static
    end
    if flags & ModifierFlags.Abstract ~= 0 then
        result = result | ScriptElementKindModifier.Abstract
    end
    if flags & ModifierFlags.Export ~= 0 then
        result = result | ScriptElementKindModifier.Exported
    end
    if flags & ModifierFlags.Deprecated ~= 0 then
        result = result | ScriptElementKindModifier.Deprecated
    end
    if flags & ModifierFlags.Ambient ~= 0 then
        result = result | ScriptElementKindModifier.Ambient
    end
    if node.flags & NodeFlags.Ambient ~= 0 then
        result = result | ScriptElementKindModifier.Ambient
    end
    if node.kind == Kind.ExportAssignment then
        result = result | ScriptElementKindModifier.Exported
    end

    return result
end
