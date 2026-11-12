local api = require("tslua.api")
local ast = require("tslua.ast")
local autoimport = require("tslua.ls.autoimport")
local checker = require("tslua.checker")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local encoder = require("tslua.api.encoder")
local format = require("tslua.format")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local lsconv = require("tslua.ls.lsconv")
local printer = require("tslua.printer")
local sourcemap = require("tslua.sourcemap")

local Session = api.Session
local clientError = api.clientError
local formatDocumentIdentifier = api.formatDocumentIdentifier

function Session:handleGetParentOfSymbol(_, params)
    return self:resolveSymbolPropertyOfSymbol(params, function(sym)
        return sym.parent
    end)
end

function Session:handleGetMembersOfSymbol(ctx, params)
    return self:resolveSymbolTablePropertyOfSymbol(ctx, params, function(symbol)
        return symbol.members
    end)
end

function Session:handleGetExportsOfSymbol(ctx, params)
    return self:resolveSymbolTablePropertyOfSymbol(ctx, params, function(symbol)
        return symbol.exports
    end)
end

function Session:handleGetExportSymbolOfSymbol(_, params)
    return self:resolveSymbolPropertyOfSymbol(params, function(sym)
        return sym.exportSymbol
    end)
end

function Session:handleGetSymbolOfType(_, params)
    return self:resolveSymbolPropertyOfType(params, function(t)
        return t:Symbol()
    end)
end

function Session:handleGetTargetOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:Target()
    end)
end

function Session:handleGetFreshTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsLiteralType():FreshType()
    end)
end

function Session:handleGetRegularTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsLiteralType():RegularType()
    end)
end

function Session:handleGetTypesOfType(_, params)
    return self:resolveTypeArrayPropertyOfType(params, function(t)
        return t:Types()
    end)
end

function Session:handleGetTypeParametersOfType(_, params)
    return self:resolveTypeArrayPropertyOfType(params, function(t)
        return t:AsInterfaceType():TypeParameters()
    end)
end

function Session:handleGetOuterTypeParametersOfType(_, params)
    return self:resolveTypeArrayPropertyOfType(params, function(t)
        return t:AsInterfaceType():OuterTypeParameters()
    end)
end

function Session:handleGetLocalTypeParametersOfType(_, params)
    return self:resolveTypeArrayPropertyOfType(params, function(t)
        return t:AsInterfaceType():LocalTypeParameters()
    end)
end

function Session:handleGetAliasTypeArgumentsOfType(_, params)
    return self:resolveTypeArrayPropertyOfType(params, function(t)
        if t:Alias() == nil then
            return nil
        end
        return t:Alias():TypeArguments()
    end)
end

function Session:handleGetAliasSymbolOfType(_, params)
    return self:resolveSymbolPropertyOfType(params, function(t)
        if t:Alias() == nil then
            return nil
        end
        return t:Alias():Symbol()
    end)
end

function Session:handleGetObjectTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsIndexedAccessType():ObjectType()
    end)
end

function Session:handleGetIndexTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsIndexedAccessType():IndexType()
    end)
end

function Session:handleGetCheckTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsConditionalType():CheckType()
    end)
end

function Session:handleGetExtendsTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsConditionalType():ExtendsType()
    end)
end

function Session:handleGetBaseTypeOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsSubstitutionType():BaseType()
    end)
end

-- handleGetConstraintOfType returns the constraint of a substitution type.
-- Type parameter constraints are handled by handleGetConstraintOfTypeParameter.
function Session:handleGetConstraintOfType(_, params)
    return self:resolveTypePropertyOfType(params, function(t)
        return t:AsSubstitutionType():SubstConstraint()
    end)
end

function Session:handleGetTypeParametersOfSignature(_, params)
    return self:resolveTypeArrayPropertyOfSignature(params, function(sig)
        return sig:TypeParameters()
    end)
end

function Session:handleGetParametersOfSignature(_, params)
    return self:resolveSymbolArrayPropertyOfSignature(params, function(sig)
        return sig:Parameters()
    end)
end

function Session:handleGetThisParameterOfSignature(_, params)
    return self:resolveSymbolPropertyOfSignature(params, function(sig)
        return sig:ThisParameter()
    end)
end

function Session:handleGetTargetOfSignature(_, params)
    return self:resolveSignaturePropertyOfSignature(params, function(sig)
        return sig:Target()
    end)
end

function Session:handleGetImportAdderEdits(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local projectPath = api.parseProjectHandle(params.project)
    local workingSnapshot = sd.snapshot
    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end
    local sourceFile = program:GetSourceFile(params.file:ToFileName())
    if sourceFile == nil then
        return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
    end

    local deferred -- Go: defer preparedSnapshot.Deref(...)
    local function finish(...)
        if deferred ~= nil then
            deferred()
        end
        return ...
    end

    local userPreferences = workingSnapshot:UserPreferences()
    local registry = workingSnapshot:AutoImportRegistry()
    if registry == nil or not registry:IsPreparedForImportingFile(sourceFile:FileName(), projectPath, userPreferences) then
        local preparedSnapshot = self.projectSession:GetSnapshotWithAutoImports(ctx, workingSnapshot, params.file:ToURI(self.projectSession:GetCurrentDirectory()))
        deferred = function()
            preparedSnapshot:Deref(self.projectSession)
        end

        workingSnapshot = preparedSnapshot
        local proj = workingSnapshot.projectCollection:GetProjectByPath(projectPath)
        if proj == nil then
            return finish(nil, clientError("project " .. projectPath .. " not found"))
        end
        program = proj:GetProgram()
        if program == nil then
            return finish(nil, clientError("project has no program"))
        end
        sourceFile = program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return finish(nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file)))
        end
        userPreferences = workingSnapshot:UserPreferences()
    end

    registry = workingSnapshot:AutoImportRegistry()
    if registry == nil then
        return finish({}, nil)
    end

    local ch, done = program:GetTypeChecker(ctx)
    local ok, result, resultErr = pcall(function()
        local view = autoimport.NewView(
            registry,
            sourceFile,
            projectPath,
            program,
            userPreferences:ModuleSpecifierPreferences()
        )
        local importAdder = autoimport.NewImportAdder(
            ctx,
            program,
            ch,
            sourceFile,
            view,
            workingSnapshot:GetPreferences(sourceFile:FileName()).formatCodeSettings,
            workingSnapshot:Converters(),
            userPreferences
        )

        for i, action in ipairs(params.actions or {}) do
            if action.kind == api.ImportAdderActionKind.ImportSymbol then
                if action.symbol == 0 then
                    return nil, clientError("import adder action " .. tostring(i - 1) .. " missing symbol")
                end
                local symbol, serr = sd:resolveSymbolHandle(action.symbol)
                if serr ~= nil then
                    return nil, serr
                end
                local isValidTypeOnlyUseSite = true
                if action.isValidTypeOnlyUseSite ~= nil then
                    isValidTypeOnlyUseSite = action.isValidTypeOnlyUseSite
                end
                importAdder:AddImportFromExportedSymbol(symbol, isValidTypeOnlyUseSite)
            else
                return nil, clientError("unknown import adder action kind " .. json.QuoteString(action.kind))
            end
        end

        if not importAdder:HasFixes() then
            return {}, nil
        end
        return api.toAPITextEdits(sourceFile, importAdder:Edits()), nil
    end)
    if done ~= nil then
        done()
    end
    if not ok then
        finish()
        error(result, 0)
    end
    return finish(result, resultErr)
end

function api.toAPITextEdits(sourceFile, edits)
    local originalText = sourceFile:OriginalText()
    local lineMap = lsconv.ComputeLSPLineStarts(originalText)
    local positionMap = ast.ComputePositionMap(originalText)
    local result = {}
    for i, edit in ipairs(edits or {}) do
        local start, ok = api.originalTextOffset(lineMap, edit.range.start, #originalText)
        if not ok then
            return nil
        end
        local end_
        end_, ok = api.originalTextOffset(lineMap, edit.range.end_, #originalText)
        if not ok then
            return nil
        end
        result[i] = setmetatable({
            pos = positionMap:UTF8ToUTF16(start),
            end_ = positionMap:UTF8ToUTF16(end_),
            newText = edit.newText,
        }, api.TextEdit)
    end
    return result
end

-- Returns (offset, ok).
function api.originalTextOffset(lineMap, position, textLength)
    local line = position.line
    if line < 0 or line >= #lineMap.lineStarts then
        return 0, false
    end
    local offset = lineMap.lineStarts[line + 1] + position.character
    if offset < lineMap.lineStarts[line + 1] or offset > textLength then
        return 0, false
    end
    return offset, true
end

-- resolveTypePropertyOfType resolves a type property of type `Type` and returns a type response.
function Session:resolveTypePropertyOfType(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local t
    t, err = sd:resolveTypeHandle(params.project, params.type)
    if err ~= nil then
        return nil, err
    end

    local result = getter(t)
    if result == nil then
        return nil, nil
    end

    return sd:newTypeResponse(params.project, result), nil
end

-- resolveTypeArrayPropertyOfType resolves a type property of an array of types and returns an array of type responses.
function Session:resolveTypeArrayPropertyOfType(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local t
    t, err = sd:resolveTypeHandle(params.project, params.type)
    if err ~= nil then
        return nil, err
    end

    local types = getter(t)
    if core.Len(types) == 0 then
        return nil, nil
    end

    local results = {}
    for i, sub in ipairs(types) do
        results[i] = sd:newTypeResponse(params.project, sub)
    end
    return results, nil
end

-- resolveSymbolPropertyOfType resolves a type property of type `Symbol` and returns a symbol response.
function Session:resolveSymbolPropertyOfType(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local t
    t, err = sd:resolveTypeHandle(params.project, params.type)
    if err ~= nil then
        return nil, err
    end

    local result = getter(t)
    if result == nil then
        return nil, nil
    end
    return sd:newSymbolResponse(result, params.project), nil
end

-- resolveSymbolTablePropertyOfSymbol resolves a symbol property of type `Symbol` and returns a symbol response.
function Session:resolveSymbolPropertyOfSymbol(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local symbol
    symbol, err = sd:resolveSymbolHandle(params.symbol)
    if err ~= nil then
        return nil, err
    end

    local result = getter(symbol)
    if result == nil then
        return nil, nil
    end
    return sd:newSymbolResponse(result, params.project), nil
end

-- resolveSymbolTablePropertyOfSymbol resolves a symbol property of type `SymbolTable` and returns an array of symbol responses.
-- Results are sorted using the checker's canonical symbol ordering so that API consumers receive
-- a stable, deterministic order instead of Go's randomized map iteration order.
function Session:resolveSymbolTablePropertyOfSymbol(ctx, params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local symbol
    symbol, err = sd:resolveSymbolHandle(params.symbol)
    if err ~= nil then
        return nil, err
    end

    local symbolTable = getter(symbol)
    local count = 0
    local only
    for _, sub in pairs(symbolTable or {}) do
        count = count + 1
        only = sub
    end
    if count == 0 then
        return nil, nil
    end
    if count == 1 then
        return { sd:newSymbolResponse(only, params.project) }, nil
    end

    -- More than one symbol, need a checker to sort
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbols = {}
        for _, sub in pairs(symbolTable) do
            symbols[#symbols + 1] = sub
        end
        table.sort(symbols, function(a, b)
            return setup.checker:CompareSymbols(a, b) < 0
        end)

        local results = {}
        for i, sub in ipairs(symbols) do
            results[i] = setup:newSymbolResponse(sub)
        end
        return results, nil
    end)
end

-- resolveSymbolArrayPropertyOfSignature resolves a signature property of an array of symbols and returns an array of symbol responses.
function Session:resolveSymbolArrayPropertyOfSignature(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local sig
    sig, err = sd:resolveSignatureHandle(params.project, params.signature)
    if err ~= nil then
        return nil, err
    end

    local symbols = getter(sig)
    if core.Len(symbols) == 0 then
        return nil, nil
    end

    local results = {}
    for i, sym in ipairs(symbols) do
        results[i] = sd:newSymbolResponse(sym, params.project)
    end
    return results, nil
end

-- resolveSymbolPropertyOfSignature resolves a signature property of type `Symbol` and returns a symbol response.
function Session:resolveSymbolPropertyOfSignature(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local sig
    sig, err = sd:resolveSignatureHandle(params.project, params.signature)
    if err ~= nil then
        return nil, err
    end

    local result = getter(sig)
    if result == nil then
        return nil, nil
    end
    return sd:newSymbolResponse(result, params.project), nil
end

function Session:resolveTypeArrayPropertyOfSignature(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local sig
    sig, err = sd:resolveSignatureHandle(params.project, params.signature)
    if err ~= nil then
        return nil, err
    end

    local types = getter(sig)
    if core.Len(types) == 0 then
        return nil, nil
    end

    local results = {}
    for i, sub in ipairs(types) do
        results[i] = sd:newTypeResponse(params.project, sub)
    end
    return results, nil
end

function Session:resolveSignaturePropertyOfSignature(params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local sig
    sig, err = sd:resolveSignatureHandle(params.project, params.signature)
    if err ~= nil then
        return nil, err
    end

    local result = getter(sig)
    if result == nil then
        return nil, nil
    end
    return sd:newSignatureResponse(params.project, result), nil
end

-- handleGetContextualType returns the contextual type for a node.
function Session:handleGetContextualType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end
        if node == nil then
            return nil, nil
        end

        local t = setup.checker:GetContextualType(node, checker.ContextFlags.None)
        if t == nil then
            return nil, nil
        end

        return setup:newTypeResponse(t), nil
    end)
end

-- handleGetBaseTypeOfLiteralType returns the base type of a literal type (e.g. number for 42).
function Session:handleGetBaseTypeOfLiteralType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetBaseTypeOfLiteralType(t)), nil
    end)
end

-- handleGetNonNullableType returns the type with null and undefined removed.
function Session:handleGetNonNullableType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetNonNullableType(t)), nil
    end)
end

-- handleGetTypeFromTypeNode returns the type for a type node.
function Session:handleGetTypeFromTypeNode(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetTypeFromTypeNode(node)), nil
    end)
end

-- handleGetWidenedType returns the widened type.
function Session:handleGetWidenedType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetWidenedType(t)), nil
    end)
end

-- handleGetParameterType returns the type of a parameter at a given index in a signature.
function Session:handleGetParameterType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sig, err = setup:resolveSignatureHandle(params.signature)
        if err ~= nil then
            return nil, err
        end

        if params.index < 0 then
            return nil, clientError("invalid parameter index")
        end

        return setup:newTypeResponse(setup.checker:GetTypeAtPosition(sig, params.index)), nil
    end)
end

function Session:handleGetTypeParameterAtPosition(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sig, err = setup:resolveSignatureHandle(params.signature)
        if err ~= nil then
            return nil, err
        end
        if params.index < 0 then
            return nil, clientError("invalid parameter index")
        end
        return setup:newTypeResponse(setup.checker:GetTypeParameterAtPosition(sig, params.index)), nil
    end)
end

-- withCheckerBool is withChecker for handlers returning (bool, error): Go returns false with errors.
function Session:withCheckerBool(ctx, snapshot, projectHandle, body)
    local setup, err = self:setupChecker(ctx, snapshot, projectHandle)
    if err ~= nil then
        return false, err
    end
    return setup:run(function()
        return body(setup)
    end)
end

-- handleIsArrayLikeType returns whether a type is array-like.
function Session:handleIsArrayLikeType(ctx, params)
    return self:withCheckerBool(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return false, err
        end

        return setup.checker:IsArrayLikeType(t), nil
    end)
end

-- handleIsTypeAssignableTo returns whether source is assignable to target.
function Session:handleIsTypeAssignableTo(ctx, params)
    return self:withCheckerBool(ctx, params.snapshot, params.project, function(setup)
        local source, err = setup:resolveTypeHandle(params.source)
        if err ~= nil then
            return false, err
        end
        local target
        target, err = setup:resolveTypeHandle(params.target)
        if err ~= nil then
            return false, err
        end

        return setup.checker:IsTypeAssignableTo(source, target), nil
    end)
end

-- handleGetShorthandAssignmentValueSymbol returns the value symbol of a shorthand property assignment.
function Session:handleGetShorthandAssignmentValueSymbol(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end
        if node == nil then
            return nil, nil
        end

        local symbol = setup.checker:GetShorthandAssignmentValueSymbol(node)
        if symbol == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(symbol), nil
    end)
end

-- handleGetTypeOfSymbolAtLocation returns the narrowed type of a symbol at a specific location.
function Session:handleGetTypeOfSymbolAtLocation(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end

        local node
        node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetTypeOfSymbolAtLocation(symbol, node)), nil
    end)
end

-- encodedNodeResponse returns the binary-encoded node as RawBinary or a SourceFileResponse.
function Session:encodedNodeResponse(data)
    if self.useBinaryResponses then
        return api.NewRawBinary(data), nil
    end
    return setmetatable({
        data = sourcemap.base64StdEncode(data),
    }, api.SourceFileResponse), nil
end

-- handleTypeToTypeNode converts a Type to a TypeNode AST and returns it as binary-encoded data.
function Session:handleTypeToTypeNode(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local enclosingDeclaration
        if params.location ~= "" then
            enclosingDeclaration, err = setup.sd:resolveNodeHandle(setup.program, params.location)
            if err ~= nil then
                return nil, err
            end
        end

        local typeNode = setup.checker:TypeToTypeNode(t, enclosingDeclaration, params.flags, nil)
        if typeNode == nil then
            return nil, nil
        end

        local data, _
        data, _, err = encoder.EncodeNode(typeNode, nil)
        if err ~= nil then
            return nil, jsonrpc.NewError("failed to encode type node: " .. jsonrpc.ErrorString(err), err)
        end

        return self:encodedNodeResponse(data)
    end)
end

function Session:handleSignatureToSignatureDeclaration(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sig, err = setup:resolveSignatureHandle(params.signature)
        if err ~= nil then
            return nil, err
        end

        local enclosingDeclaration
        if params.location ~= "" then
            enclosingDeclaration, err = setup.sd:resolveNodeHandle(setup.program, params.location)
            if err ~= nil then
                return nil, err
            end
        end

        local node = setup.checker:SignatureToSignatureDeclaration(sig, params.kind, enclosingDeclaration, params.flags)
        if node == nil then
            return nil, nil
        end

        local data, _
        data, _, err = encoder.EncodeNode(node, nil)
        if err ~= nil then
            return nil, jsonrpc.NewError("failed to encode signature declaration: " .. jsonrpc.ErrorString(err), err)
        end

        return self:encodedNodeResponse(data)
    end)
end

-- handleTypeToString converts a Type to its string representation.
function Session:handleTypeToString(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local enclosingDeclaration
        if params.location ~= "" then
            enclosingDeclaration, err = setup.sd:resolveNodeHandle(setup.program, params.location)
            if err ~= nil then
                return nil, err
            end
        end

        if params.flags ~= 0 then
            return setup.checker:TypeToStringEx(t, enclosingDeclaration, params.flags, nil), nil
        end
        return setup.checker:TypeToStringEx(t, enclosingDeclaration, checker.TypeFormatFlags.AllowUniqueESSymbolType | checker.TypeFormatFlags.UseAliasDefinedOutsideCurrentScope, nil), nil
    end)
end

-- handlePrintNode decodes a binary-encoded AST node and prints it to text.
function Session:handlePrintNode(_, params)
    local data, err = sourcemap.base64StdDecode(params.data)
    if err ~= nil then
        return "", clientError("invalid base64 data: " .. jsonrpc.ErrorString(err), err)
    end

    local node
    node, err = encoder.DecodeNodes(data)
    if err ~= nil then
        return "", clientError("failed to decode AST: " .. jsonrpc.ErrorString(err), err)
    end

    local p = printer.NewPrinter({
        preserveSourceNewlines = params.preserveSourceNewlines,
        neverAsciiEscape = params.neverAsciiEscape,
        terminateUnterminatedLiterals = params.terminateUnterminatedLiterals,
    }, {}, nil)
    return p:Emit(node, nil), nil
end

function Session:handleEmit(ctx, params)
    local program, options, err = self:getEmitOptions(params)
    if err ~= nil then
        return nil, err
    end
    options.writeFile = function(fileName, text, _)
        return self.projectSession:FS():WriteFile(fileName, text)
    end
    local result
    result, err = api.emitProgram(ctx, program, options)
    if err ~= nil then
        return nil, err
    end
    local emittedFiles = {}
    for i, f in ipairs(result.emittedFiles or {}) do
        emittedFiles[i] = f
    end
    return setmetatable({
        emitSkipped = result.emitSkipped,
        diagnostics = api.nonNilDiagnostics(result.diagnostics),
        emittedFiles = emittedFiles,
    }, api.EmitResponse), nil
end

function Session:handleEmitToString(ctx, params)
    local program, options, err = self:getEmitOptions(params)
    if err ~= nil then
        return nil, err
    end
    return api.emitToOutput(ctx, program, options)
end

function Session:handleSelectedFilesEmit(ctx, params, emitOnly)
    local program, err = self:getEmitProgram(params.snapshot, params.project)
    if err ~= nil then
        return nil, err
    end
    if params.files == nil then
        return nil, clientError("files is required")
    end
    local targetSourceFiles = {}
    for _, file in ipairs(params.files) do
        local sourceFile
        sourceFile, err = self:resolveOptionalSourceFile(program, file)
        if err ~= nil then
            return nil, err
        end
        targetSourceFiles[#targetSourceFiles + 1] = sourceFile
    end
    return api.emitToOutput(ctx, program, compiler.NewEmitOptions({
        targetSourceFiles = targetSourceFiles,
        emitOnly = emitOnly,
        forceEmit = true,
    }))
end

function api.emitToOutput(ctx, program, options)
    local outputFiles = {}
    options.writeFile = function(fileName, text, data)
        local sourceFileName
        if data.sourceFile ~= nil then
            sourceFileName = data.sourceFile:FileName()
        end
        outputFiles[#outputFiles + 1] = setmetatable({ fileName = fileName, text = text, sourceFileName = sourceFileName }, api.EmitOutputFile)
        return nil
    end

    local result, err = api.emitProgram(ctx, program, options)
    if err ~= nil then
        return nil, err
    end
    -- slices.SortFunc is not stable; output file names are unique.
    table.sort(outputFiles, function(a, b)
        return a.fileName < b.fileName
    end)
    return setmetatable({
        emitSkipped = result.emitSkipped,
        diagnostics = api.nonNilDiagnostics(result.diagnostics),
        outputFiles = outputFiles,
    }, api.EmitOutputResponse), nil
end

-- Returns (program, options, err).
function Session:getEmitOptions(params)
    local program, err = self:getEmitProgram(params.snapshot, params.project)
    if err ~= nil then
        return nil, compiler.NewEmitOptions({}), err
    end
    local emitOnly
    emitOnly, err = api.getEmitOnly(params.emitOnly)
    if err ~= nil then
        return nil, compiler.NewEmitOptions({}), err
    end
    return program, compiler.NewEmitOptions({
        emitOnly = emitOnly,
    }), nil
end

function Session:getEmitProgram(snapshot, projectID)
    local sd, err = self:getSnapshotData(snapshot)
    if err ~= nil then
        return nil, err
    end
    return sd:getProgram(projectID)
end

-- Returns (EmitOnly, err).
function api.getEmitOnly(value)
    if value == nil then
        return compiler.EmitOnly.EmitAll, nil
    end
    if value > compiler.EmitOnly.Dts then
        return compiler.EmitOnly.EmitAll, clientError("invalid emitOnly value: " .. tostring(value))
    end
    local emitOnly = value
    return emitOnly, nil
end

function api.emitProgram(ctx, program, options)
    local result = program:Emit(ctx, options)
    if result ~= nil then
        return result, nil
    end
    local err = core.ContextErr(ctx)
    if err ~= nil then
        return nil, err
    end
    return nil, jsonrpc.NewError("compiler emit returned nil result")
end

function api.nonNilDiagnostics(diags)
    local result = api.NewDiagnosticResponses(diags)
    if result == nil then
        return {}
    end
    return result
end

-- handleFormatNodeForInsertion formats a synthesized node with the correct indentation
-- for insertion at a specific position in an existing file.
function Session:handleFormatNodeForInsertion(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return "", err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return "", err
    end

    local targetSourceFile
    targetSourceFile, err = self:resolveOptionalSourceFile(program, params.file)
    if err ~= nil then
        return "", err
    end

    local data
    data, err = sourcemap.base64StdDecode(params.data)
    if err ~= nil then
        return "", clientError("invalid base64 data: " .. jsonrpc.ErrorString(err), err)
    end

    local node
    node, err = encoder.DecodeNodes(data)
    if err ~= nil then
        return "", clientError("failed to decode AST: " .. jsonrpc.ErrorString(err), err)
    end

    local pos = targetSourceFile:GetPositionMap():UTF16ToUTF8(params.position)
    local formatOptions = sd.snapshot:UserPreferences().formatCodeSettings
    local newLine = formatOptions.newLineCharacter

    local factory = ast.NewNodeFactory({})
    local text, nodeWithPos = printer.PrintAndPositionNode(factory, node, nil, newLine, formatOptions.indentSize, nil)
    local syntheticFile = printer.CreateSyntheticSourceFile(factory, nodeWithPos, text, targetSourceFile:ParseOptions())

    local isAtLineStart = format.GetLineStartPositionForPosition(pos, targetSourceFile) == pos
    local initialIndentation = format.GetIndentation(pos, targetSourceFile, formatOptions, isAtLineStart)

    local delta = 0
    if formatOptions.indentSize ~= 0 and format.ShouldIndentChildNode(formatOptions, node, nil, nil) then
        delta = formatOptions.indentSize
    end

    ctx = format.WithFormatCodeSettings(ctx, formatOptions, newLine)
    local changes = format.FormatNodeGivenIndentation(ctx, nodeWithPos, syntheticFile, targetSourceFile.languageVariant, initialIndentation, delta)

    return core.ApplyBulkEdits(text, changes), nil
end

-- handleGetIntrinsicType returns an intrinsic type (any, string, number, etc.).
function Session:handleGetIntrinsicType(ctx, params, getter)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t = getter(setup.checker)
        if t == nil then
            return nil, nil
        end

        return setup:newTypeResponse(t), nil
    end)
end

-- handleGetWellKnownSymbols returns the handle ids of the per-checker singleton
-- symbols (unknown, undefined, arguments) so the client can identify them by id.
function Session:handleGetWellKnownSymbols(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local unknown = setup.sd:registerSymbol(setup.checker:GetUnknownSymbol(), setup.projectID)
        local undefined = setup.sd:registerSymbol(setup.checker:GetUndefinedSymbol(), setup.projectID)
        local arguments = setup.sd:registerSymbol(setup.checker:GetArgumentsSymbol(), setup.projectID)
        return setmetatable({
            unknown = unknown,
            undefined = undefined,
            arguments = arguments,
        }, api.WellKnownSymbolsResponse), nil
    end)
end

-- handleGetWellKnownSignatures returns the handle id of the per-checker unknown
-- signature so the client can identify it by id.
function Session:handleGetWellKnownSignatures(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        return setmetatable({
            unknown = setup.sd:registerSignature(setup.projectID, setup.checker:GetUnknownSignature()),
        }, api.WellKnownSignaturesResponse), nil
    end)
end

