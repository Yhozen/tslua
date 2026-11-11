local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local core = require("tslua.core")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")

local TypeFlags = checker.TypeFlags
local TypeFormatFlags = checker.TypeFormatFlags
local SymbolFormatFlags = checker.SymbolFormatFlags
local SignatureFlags = checker.SignatureFlags
local Kind = ast.Kind
local Flags = nodebuilder.Flags
local InternalFlags = nodebuilder.InternalFlags

-- TODO: Memoize once per checker to retain threadsafety
function checker.createPrinterWithDefaults(emitContext)
    return printer.NewPrinter({}, {}, emitContext)
end

function checker.createPrinterWithRemoveComments(emitContext)
    return printer.NewPrinter({ removeComments = true }, {}, emitContext)
end

function checker.createPrinterWithRemoveCommentsOmitTrailingSemicolon(emitContext)
    return printer.NewPrinter({
        removeComments = true,
        omitTrailingSemicolon = true,
    }, {}, emitContext)
end

function checker.createPrinterWithRemoveCommentsOmitTrailingSemicolonNeverAsciiEscape(emitContext)
    return printer.NewPrinter({
        removeComments = true,
        omitTrailingSemicolon = true,
        neverAsciiEscape = true,
    }, {}, emitContext)
end

function checker.createPrinterWithRemoveCommentsNeverAsciiEscape(emitContext)
    return printer.NewPrinter({
        removeComments = true,
        neverAsciiEscape = true,
    }, {}, emitContext)
end

function Checker:TypeToString(t)
    return self:typeToString(t, nil)
end

function Checker:typeToString(t, enclosingDeclaration)
    return self:typeToStringEx(t, enclosingDeclaration, TypeFormatFlags.AllowUniqueESSymbolType | TypeFormatFlags.UseAliasDefinedOutsideCurrentScope, nil)
end

function checker.toNodeBuilderFlags(flags)
    return flags & TypeFormatFlags.NodeBuilderFlagsMask
end

function Checker:TypeToStringEx(t, enclosingDeclaration, flags, vc)
    return self:typeToStringEx(t, enclosingDeclaration, flags, vc)
end

function Checker:typeToStringEx(t, enclosingDeclaration, flags, vc)
    -- Serialization of types can lead to (lazy) resolution of members, which can cause diagnostics that again require
    -- serialization of types. This can potentially result in infinite recursion and stack overflows. To prevent that,
    -- after a certain number of recursive invocations the function simply returns "?".
    if self.serializationLevel >= checker.maxSerializationLevel then
        return "?"
    end
    local newLine = ""
    if flags & TypeFormatFlags.MultilineObjectLiterals ~= 0 then
        newLine = "\n"
    end
    local writer = printer.NewTextWriter(newLine, 0)
    local noTruncation = ((vc == nil or vc.maxTruncationLength == 0) and self.compilerOptions.noErrorTruncation == core.Tristate.TSTrue) or (flags & TypeFormatFlags.NoTruncation ~= 0)
    local combinedFlags = checker.toNodeBuilderFlags(flags) | Flags.IgnoreErrors
    if noTruncation then
        combinedFlags = combinedFlags | Flags.NoTruncation
    end
    local nodeBuilder, release = self:getNodeBuilder()
    local oldVerbosity = nodeBuilder.verbosity
    nodeBuilder.verbosity = vc
    self.serializationLevel = self.serializationLevel + 1
    local typeNode = nodeBuilder:TypeToTypeNode(t, enclosingDeclaration, combinedFlags, InternalFlags.None, nil)
    self.serializationLevel = self.serializationLevel - 1
    if typeNode == nil then
        error("should always get typenode", 0)
    end
    -- The unresolved type gets a synthesized comment on `any` to hint to users that it's not a plain `any`.
    -- Otherwise, we always strip comments out.
    local p
    if t == self.unresolvedType then
        p = checker.createPrinterWithDefaults(nodeBuilder:EmitContext())
    else
        p = checker.createPrinterWithRemoveComments(nodeBuilder:EmitContext())
    end
    local sourceFile
    if enclosingDeclaration ~= nil then
        sourceFile = ast.GetSourceFileOfNode(enclosingDeclaration)
    end
    p:Write(typeNode, sourceFile, writer, nil)
    local result = writer:String()
    nodeBuilder.verbosity = oldVerbosity
    release()

    local maxLength = checker.defaultMaximumTruncationLength * 2
    if vc ~= nil and vc.maxTruncationLength > 0 then
        maxLength = vc.maxTruncationLength * 10 -- hard cutoff matching Strada's absoluteMaximumLength
    end
    if noTruncation then
        maxLength = checker.noTruncationMaximumTruncationLength * 2
    end
    if maxLength > 0 and result ~= "" and #result >= maxLength then
        if vc ~= nil then
            vc.truncated = true
        end
        return string.sub(result, 1, maxLength - #"...") .. "..."
    end
    return result
end

function Checker:SymbolToString(s)
    return self:symbolToString(s)
end

function Checker:symbolToString(symbol)
    return self:symbolToStringEx(symbol, nil, ast.SymbolFlags.All, SymbolFormatFlags.AllowAnyNodeKind)
end

function Checker:SymbolToStringEx(symbol, enclosingDeclaration, meaning, flags)
    return self:symbolToStringEx(symbol, enclosingDeclaration, meaning, flags)
end

function Checker:symbolToStringEx(symbol, enclosingDeclaration, meaning, flags)
    local writer, putWriter = printer.GetSingleLineStringWriter()

    local nodeFlags = Flags.IgnoreErrors
    local internalNodeFlags = InternalFlags.None
    if flags & SymbolFormatFlags.UseOnlyExternalAliasing ~= 0 then
        nodeFlags = nodeFlags | Flags.UseOnlyExternalAliasing
    end
    if flags & SymbolFormatFlags.WriteTypeParametersOrArguments ~= 0 then
        nodeFlags = nodeFlags | Flags.WriteTypeParametersInQualifiedName
    end
    if flags & SymbolFormatFlags.UseAliasDefinedOutsideCurrentScope ~= 0 then
        nodeFlags = nodeFlags | Flags.UseAliasDefinedOutsideCurrentScope
    end
    if flags & SymbolFormatFlags.DoNotIncludeSymbolChain ~= 0 then
        internalNodeFlags = internalNodeFlags | InternalFlags.DoNotIncludeSymbolChain
    end
    if flags & SymbolFormatFlags.WriteComputedProps ~= 0 then
        internalNodeFlags = internalNodeFlags | InternalFlags.WriteComputedProps
    end

    local nodeBuilder, release = self:getNodeBuilder()
    local sourceFile
    if enclosingDeclaration ~= nil then
        sourceFile = ast.GetSourceFileOfNode(enclosingDeclaration)
    end
    local printer_
    -- add neverAsciiEscape for GH#39027
    if enclosingDeclaration ~= nil and enclosingDeclaration.kind == Kind.SourceFile then
        printer_ = checker.createPrinterWithRemoveCommentsOmitTrailingSemicolonNeverAsciiEscape(nodeBuilder:EmitContext())
    else
        printer_ = checker.createPrinterWithRemoveCommentsOmitTrailingSemicolon(nodeBuilder:EmitContext())
    end

    local builder
    if flags & SymbolFormatFlags.AllowAnyNodeKind ~= 0 then
        builder = function(...)
            return nodeBuilder:SymbolToNode(...)
        end
    else
        builder = function(...)
            return nodeBuilder:SymbolToEntityName(...)
        end
    end
    local entity = builder(symbol, meaning, enclosingDeclaration, nodeFlags, internalNodeFlags, nil) -- TODO: GH#18217
    printer_:Write(entity --[[sourceFile]], sourceFile, writer, nil) -- TODO: GH#18217
    local result = writer:String()
    release()
    putWriter()
    return result
end

function Checker:signatureToString(signature)
    return self:signatureToStringEx(signature, nil, TypeFormatFlags.None, nil)
end

function Checker:SignatureToStringEx(signature, enclosingDeclaration, flags, vc)
    return self:signatureToStringEx(signature, enclosingDeclaration, flags, vc)
end

function Checker:signatureToStringEx(signature, enclosingDeclaration, flags, vc)
    local isConstructor = signature.flags & SignatureFlags.Construct ~= 0 and flags & TypeFormatFlags.WriteCallStyleSignature == 0
    local sigOutput
    if flags & TypeFormatFlags.WriteArrowStyleSignature ~= 0 then
        if isConstructor then
            sigOutput = Kind.ConstructorType
        else
            sigOutput = Kind.FunctionType
        end
    else
        if isConstructor then
            sigOutput = Kind.ConstructSignature
        else
            sigOutput = Kind.CallSignature
        end
    end

    local nodeBuilder, release = self:getNodeBuilder()
    local oldVerbosity = nodeBuilder.verbosity
    nodeBuilder.verbosity = vc
    local combinedFlags = checker.toNodeBuilderFlags(flags) | Flags.IgnoreErrors | Flags.WriteTypeParametersInQualifiedName
    local sig = nodeBuilder:SignatureToSignatureDeclaration(signature, sigOutput, enclosingDeclaration, combinedFlags, InternalFlags.None, nil)
    local p = checker.createPrinterWithRemoveCommentsOmitTrailingSemicolonNeverAsciiEscape(nodeBuilder:EmitContext())
    local sourceFile
    if enclosingDeclaration ~= nil then
        sourceFile = ast.GetSourceFileOfNode(enclosingDeclaration)
    end
    local result
    if flags & TypeFormatFlags.MultilineObjectLiterals ~= 0 then
        local writer = printer.NewTextWriter("\n", 0)
        p:Write(sig, sourceFile, writer, nil)
        result = writer:String()
    else
        local writer, putWriter = printer.GetSingleLineStringWriter()
        p:Write(sig, sourceFile, writer, nil)
        result = writer:String()
        putWriter()
    end
    nodeBuilder.verbosity = oldVerbosity
    release()
    return result
end

function Checker:typePredicateToString(typePredicate)
    return self:typePredicateToStringEx(typePredicate, nil, TypeFormatFlags.UseAliasDefinedOutsideCurrentScope)
end

function Checker:typePredicateToStringEx(typePredicate, enclosingDeclaration, flags)
    local writer, putWriter = printer.GetSingleLineStringWriter()
    local nodeBuilder, release = self:getNodeBuilder()
    local combinedFlags = checker.toNodeBuilderFlags(flags) | Flags.IgnoreErrors | Flags.WriteTypeParametersInQualifiedName
    local predicate = nodeBuilder:TypePredicateToTypePredicateNode(typePredicate, enclosingDeclaration, combinedFlags, InternalFlags.None, nil) -- TODO: GH#18217
    local printer_ = checker.createPrinterWithRemoveComments(nodeBuilder:EmitContext())
    local sourceFile
    if enclosingDeclaration ~= nil then
        sourceFile = ast.GetSourceFileOfNode(enclosingDeclaration)
    end
    printer_:Write(predicate --[[sourceFile]], sourceFile, writer, nil)
    local result = writer:String()
    release()
    putWriter()
    return result
end

function Checker:valueToString(value)
    return checker.ValueToString(value)
end

function Checker:formatUnionTypes(types, expandingEnum)
    local result
    local flags = 0
    local i = 0
    while i < #types do
        local t = types[i + 1]
        flags = flags | t.flags
        if t.flags & TypeFlags.Nullable == 0 then
            if t.flags & TypeFlags.BooleanLiteral ~= 0 or (not expandingEnum and t.flags & TypeFlags.EnumLike ~= 0) then
                local baseType
                if t.flags & TypeFlags.BooleanLiteral ~= 0 then
                    baseType = self.booleanType
                else
                    baseType = self:getBaseTypeOfEnumLikeType(t)
                end
                if baseType.flags & TypeFlags.Union ~= 0 then
                    local count = #baseType:AsUnionType().types
                    if i + count <= #types and self:getRegularTypeOfLiteralType(types[i + count - 1 + 1]) == self:getRegularTypeOfLiteralType(baseType:AsUnionType().types[count - 1 + 1]) then
                        result = core.Append(result, baseType)
                        i = i + count - 1
                        goto continue
                    end
                end
            end
            result = core.Append(result, t)
        end
        ::continue::
        i = i + 1
    end
    if flags & TypeFlags.Null ~= 0 then
        result = core.Append(result, self.nullType)
    end
    if flags & TypeFlags.Undefined ~= 0 then
        result = core.Append(result, self.undefinedType)
    end
    return result
end

function Checker:TypeToTypeNode(t, enclosingDeclaration, flags, idToSymbol)
    local nodeBuilder = self:getNodeBuilderEx(idToSymbol)
    return nodeBuilder:TypeToTypeNode(t, enclosingDeclaration, flags, InternalFlags.None, nil)
end

function Checker:SignatureToSignatureDeclaration(signature, kind, enclosingDeclaration, flags)
    local nodeBuilder, release = self:getNodeBuilder()
    local result = nodeBuilder:SignatureToSignatureDeclaration(signature, kind, enclosingDeclaration, flags, InternalFlags.None, nil)
    release()
    return result
end

-- ExpandSymbolForHover produces declaration strings for a symbol with verbosity support for expandable hover.
function Checker:ExpandSymbolForHover(symbol, meaning, vc)
    local nodeBuilder, release = self:getNodeBuilder()
    local oldVerbosity = nodeBuilder.verbosity
    nodeBuilder.verbosity = vc
    local function done(result)
        nodeBuilder.verbosity = oldVerbosity
        release()
        return result
    end
    local nodes = nodeBuilder:ExpandSymbolForHover(symbol, meaning)
    if core.Len(nodes) == 0 then
        return done("")
    end
    local p = checker.createPrinterWithRemoveComments(nodeBuilder:EmitContext())
    local sourceFile
    if symbol.valueDeclaration ~= nil then
        sourceFile = ast.GetSourceFileOfNode(symbol.valueDeclaration)
    end
    local b = {}
    for i1, node in ipairs(nodes) do
        if i1 > 1 then
            b[#b + 1] = "\n"
        end
        b[#b + 1] = p:Emit(node, sourceFile)
    end
    return done(table.concat(b))
end

-- TypeParameterToStringEx renders a type parameter declaration (e.g. "T extends Foo") with optional verbosity support.
function Checker:TypeParameterToStringEx(t, enclosingDeclaration, vc)
    local nodeBuilder, release = self:getNodeBuilder()
    local oldVerbosity = nodeBuilder.verbosity
    nodeBuilder.verbosity = vc
    local function done(result)
        nodeBuilder.verbosity = oldVerbosity
        release()
        return result
    end
    local typeParamNode = nodeBuilder:TypeParameterToDeclaration(t, enclosingDeclaration, Flags.IgnoreErrors, InternalFlags.None, nil)
    if typeParamNode == nil then
        return done(self:TypeToString(t))
    end
    local p = checker.createPrinterWithRemoveComments(nodeBuilder:EmitContext())
    local sourceFile
    if enclosingDeclaration ~= nil then
        sourceFile = ast.GetSourceFileOfNode(enclosingDeclaration)
    end
    return done(p:Emit(typeParamNode, sourceFile))
end

function Checker:TypeToTypeNodeEx(t, enclosingDeclaration, flags, internalFlags, idToSymbol)
    local nodeBuilder = self:getNodeBuilderEx(idToSymbol)
    return nodeBuilder:TypeToTypeNode(t, enclosingDeclaration, flags, internalFlags, nil)
end

function Checker:TypePredicateToTypePredicateNode(t, enclosingDeclaration, flags, idToSymbol)
    local nodeBuilder = self:getNodeBuilderEx(idToSymbol)
    return nodeBuilder:TypePredicateToTypePredicateNode(t, enclosingDeclaration, flags, InternalFlags.None, nil)
end
