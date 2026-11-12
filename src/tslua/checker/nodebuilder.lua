local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local core = require("tslua.core")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local Flags = nodebuilder.Flags
local InternalFlags = nodebuilder.InternalFlags

-- NodeBuilder: { ctxStack, host, impl, verbosity (nil for non-hover callers) }
local NodeBuilder = checker.defineStruct("NodeBuilder", nil, nil)

-- VerbosityContext controls hover-expansion behavior in the node builder.
-- A nil VerbosityContext means no expansion (non-hover callers).
-- Level 0 = default hover (maxExpansionDepth = 0; detects expandability without expanding).
-- Level 1+ = expansion enabled (maxExpansionDepth = Level).
checker.defineStruct("VerbosityContext", nil, {
    level = 0, -- 0 = default (no expansion), 1+ = expansion depth
    maxTruncationLength = 0, -- 0 = use default
    canIncreaseVerbosity = false, -- output: whether increasing Level would reveal more
    truncated = false, -- output: whether output was truncated
})

-- EmitContext implements NodeBuilderInterface.
function NodeBuilder:EmitContext()
    return self.impl.e
end

function NodeBuilder:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    local verbosityLevel = -1
    local maxTruncationLength = 0
    if self.verbosity ~= nil then
        verbosityLevel = self.verbosity.level
        maxTruncationLength = self.verbosity.maxTruncationLength
    end
    self.ctxStack[#self.ctxStack + 1] = self.impl.ctx or false
    self.impl.ctx = checker.NodeBuilderContext_new({
        host = self.host,
        tracker = tracker,
        flags = flags,
        internalFlags = internalFlags,
        maxExpansionDepth = verbosityLevel,
        maxTruncationLength = maxTruncationLength,
        enclosingDeclaration = enclosingDeclaration,
        enclosingFile = ast.GetSourceFileOfNode(enclosingDeclaration),
        inferTypeParameters = {},
        symbolDepth = {},
        trackedSymbols = {},
        reverseMappedStack = {},
        enclosingSymbolTypes = {},
        remappedSymbolReferences = {},
    })
    tracker = checker.NewSymbolTrackerImpl(self.impl.ctx, tracker)
    self.impl.ctx.tracker = tracker
end

-- propagateVerbosityOut copies expansion signals from the context to the VerbosityContext output.
function NodeBuilder:propagateVerbosityOut()
    if self.verbosity ~= nil then
        -- Only set to true, never clear — multiple calls share the same VerbosityContext
        if self.impl.ctx.canIncreaseExpansionDepth then
            self.verbosity.canIncreaseVerbosity = true
        end
        if self.impl.ctx.expansionTruncated then
            self.verbosity.truncated = true
        end
    end
end

function NodeBuilder:popContext()
    local stackSize = #self.ctxStack
    if stackSize == 0 then
        self.impl.ctx = nil
    else
        local ctx = self.ctxStack[stackSize]
        if ctx == false then
            ctx = nil
        end
        self.impl.ctx = ctx
        self.ctxStack[stackSize] = nil
    end
end

function NodeBuilder:exitContext(result)
    self:propagateVerbosityOut()
    self:exitContextCheck()
    local encounteredError = self.impl.ctx.encounteredError
    self:popContext()
    if encounteredError then
        return nil
    end
    return result
end

function NodeBuilder:exitContextSlice(result)
    self:propagateVerbosityOut()
    self:exitContextCheck()
    local encounteredError = self.impl.ctx.encounteredError
    self:popContext()
    if encounteredError then
        return nil
    end
    return result
end

function NodeBuilder:exitContextCheck()
    if self.impl.ctx.truncating and self.impl.ctx.flags & Flags.NoTruncation ~= 0 then
        self.impl.ctx.tracker:ReportTruncationError()
    end
end

-- IndexInfoToIndexSignatureDeclaration implements NodeBuilderInterface.
function NodeBuilder:IndexInfoToIndexSignatureDeclaration(info, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:indexInfoToIndexSignatureDeclarationHelper(info, nil))
end

-- SerializeReturnTypeForSignature implements NodeBuilderInterface.
function NodeBuilder:SerializeReturnTypeForSignature(signatureDeclaration, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    local signature = self.impl.ch:getSignatureFromDeclaration(signatureDeclaration)
    local _, cleanup = self.impl:enterSignatureScope(signature)
    local result = self.impl:serializeReturnTypeForSignature(signature, true)
    cleanup()
    return self:exitContext(result)
end

function NodeBuilder:SerializeTypeParametersForSignature(signatureDeclaration, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    local symbol = self.impl.ch:getSymbolOfDeclaration(signatureDeclaration)
    local typeParams = self:SymbolToTypeParameterDeclarations(symbol, enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContextSlice(typeParams)
end

-- SerializeTypeForDeclaration implements NodeBuilderInterface.
function NodeBuilder:SerializeTypeForDeclaration(declaration, symbol, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:serializeTypeForDeclaration(declaration, nil, symbol, true))
end

-- SerializeTypeForExpression implements NodeBuilderInterface.
function NodeBuilder:SerializeTypeForExpression(expr, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:serializeTypeForExpression(expr))
end

-- SignatureToSignatureDeclaration implements NodeBuilderInterface.
function NodeBuilder:SignatureToSignatureDeclaration(signature, kind, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:signatureToSignatureDeclarationHelper(signature, kind, nil))
end

-- ExpandSymbolForHover produces declaration nodes for a symbol with verbosity level support.
function NodeBuilder:ExpandSymbolForHover(symbol, meaning)
    self:enterContext(nil, Flags.IgnoreErrors | Flags.MultilineObjectLiterals | Flags.UseAliasDefinedOutsideCurrentScope, InternalFlags.None, nil)

    -- Push the declared type onto the type stack to prevent re-expansion.
    -- We push a nil sentinel after the real type so that isTypeOnStack
    -- (which skips the last element) still checks declaredType.
    local declaredType = self.impl.ch:getDeclaredTypeOfSymbol(symbol)
    local typeStack = self.impl.ctx.typeStack or {}
    self.impl.ctx.typeStack = typeStack
    typeStack[#typeStack + 1] = declaredType or false
    typeStack[#typeStack + 1] = false

    local nodes = self.impl:expandSymbolForHover(symbol)

    typeStack = self.impl.ctx.typeStack
    typeStack[#typeStack] = nil
    typeStack[#typeStack] = nil

    self:propagateVerbosityOut()

    -- Simplify declarations by applying original modifiers
    local result = {}
    for _, node in ipairs(nodes or {}) do
        if node.kind == Kind.ClassDeclaration then
            result[#result + 1] = checker.simplifyClassDeclaration(self.impl.f, node, symbol)
        elseif node.kind == Kind.EnumDeclaration then
            result[#result + 1] = checker.simplifyModifiers(self.impl.f, node, ast.IsEnumDeclaration, symbol)
        elseif node.kind == Kind.InterfaceDeclaration then
            if meaning & SymbolFlags.Interface ~= 0 then
                result[#result + 1] = checker.simplifyModifiers(self.impl.f, node, ast.IsInterfaceDeclaration, symbol)
            end
        elseif node.kind == Kind.ModuleDeclaration then
            result[#result + 1] = checker.simplifyModifiers(self.impl.f, node, ast.IsModuleDeclaration, symbol)
        end
    end

    return self:exitContextSlice(result)
end

function checker.simplifyClassDeclaration(f, classDecl, symbol)
    local classDeclarations = core.Filter(symbol.declarations, ast.IsClassLike)
    local originalClassDecl
    if core.Len(classDeclarations) > 0 then
        originalClassDecl = classDeclarations[1]
    else
        originalClassDecl = classDecl
    end
    local modifiers = originalClassDecl:ModifierFlags() & ~(ModifierFlags.Export | ModifierFlags.Ambient)
    local isAnonymous = ast.IsClassExpression(originalClassDecl)
    if isAnonymous then
        local cd = classDecl:AsClassDeclaration()
        classDecl = f:UpdateClassDeclaration(
            cd,
            classDecl:Modifiers(),
            nil,
            cd.typeParameters,
            cd.heritageClauses,
            cd.members
        )
    end
    return ast.ReplaceModifiers(f, classDecl, f:NewModifierList(ast.CreateModifiersFromModifierFlags(modifiers, function(kind) return f:NewModifier(kind) end)))
end

function checker.simplifyModifiers(f, newDecl, isDeclKind, symbol)
    local decls = core.Filter(symbol.declarations, isDeclKind)
    local declWithModifiers
    if core.Len(decls) > 0 then
        declWithModifiers = decls[1]
    else
        declWithModifiers = newDecl
    end
    local modifiers = declWithModifiers:ModifierFlags() & ~(ModifierFlags.Export | ModifierFlags.Ambient)
    return ast.ReplaceModifiers(f, newDecl, f:NewModifierList(ast.CreateModifiersFromModifierFlags(modifiers, function(kind) return f:NewModifier(kind) end)))
end

-- SymbolToEntityName implements NodeBuilderInterface.
function NodeBuilder:SymbolToEntityName(symbol, meaning, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:symbolToName(symbol, meaning, false))
end

-- SymbolToExpression implements NodeBuilderInterface.
function NodeBuilder:SymbolToExpression(symbol, meaning, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:symbolToExpression(symbol, meaning))
end

-- SymbolToNode implements NodeBuilderInterface.
function NodeBuilder:SymbolToNode(symbol, meaning, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:symbolToNode(symbol, meaning))
end

-- SymbolToParameterDeclaration implements NodeBuilderInterface.
-- (Go uses a value receiver here; the ctxStack append is lost on return but impl is shared.)
function NodeBuilder:SymbolToParameterDeclaration(symbol, enclosingDeclaration, flags, internalFlags, tracker)
    local b = checker.NodeBuilder_new({ ctxStack = core.Slice(self.ctxStack, 0), host = self.host, impl = self.impl, verbosity = self.verbosity })
    b:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return b:exitContext(b.impl:symbolToParameterDeclaration(symbol, false))
end

-- SymbolToTypeParameterDeclarations implements NodeBuilderInterface.
function NodeBuilder:SymbolToTypeParameterDeclarations(symbol, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContextSlice(self.impl:symbolToTypeParameterDeclarations(symbol))
end

-- TypeParameterToDeclaration implements NodeBuilderInterface.
function NodeBuilder:TypeParameterToDeclaration(parameter, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:typeParameterToDeclaration(parameter))
end

-- TypePredicateToTypePredicateNode implements NodeBuilderInterface.
function NodeBuilder:TypePredicateToTypePredicateNode(predicate, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:typePredicateToTypePredicateNode(predicate))
end

-- TypeToTypeNode implements NodeBuilderInterface.
function NodeBuilder:TypeToTypeNode(typ, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:typeToTypeNode(typ))
end

function NodeBuilder:TryJSTypeNodeToTypeNode(node, enclosingDeclaration, flags, internalFlags, tracker)
    self:enterContext(enclosingDeclaration, flags, internalFlags, tracker)
    return self:exitContext(self.impl:tryJSTypeNodeToTypeNode(node))
end

-- var _ NodeBuilderInterface = NewNodeBuilderAPI(nil, nil)

function checker.NewNodeBuilder(ch, e)
    return checker.NewNodeBuilderEx(ch, e, nil --[[idToSymbol]])
end

function checker.NewNodeBuilderEx(ch, e, idToSymbol)
    local impl = checker.newNodeBuilderImpl(ch, e, idToSymbol)
    return checker.NodeBuilder_new({ impl = impl, ctxStack = {}, host = ch.program })
end

function Checker:getNodeBuilder()
    -- Go releases the factory's node arenas here; Lua nodes are garbage collected.
    local releaseNodes = function() end
    if self.typeToStringNodebuilder ~= nil then
        return self.typeToStringNodebuilder, releaseNodes
    end
    self.typeToStringNodebuilder = self:getNodeBuilderEx(nil --[[idToSymbol]])
    return self.typeToStringNodebuilder, releaseNodes
end

function Checker:getNodeBuilderEx(idToSymbol)
    local b = checker.NewNodeBuilderEx(self, printer.NewEmitContext(), idToSymbol)
    return b
end

return checker
