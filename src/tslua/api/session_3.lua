local api = require("tslua.api")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local encoder = require("tslua.api.encoder")
local json = require("tslua.json")
local ls = require("tslua.ls")
local project = require("tslua.project")
local tspath = require("tslua.tspath")

local Session = api.Session
local snapshotData = api.snapshotData
local clientError = api.clientError
local formatDocumentIdentifier = api.formatDocumentIdentifier

-- handleIsContextSensitive returns whether a node is context-sensitive.
function Session:handleIsContextSensitive(ctx, params)
    return self:withCheckerBool(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return false, err
        end
        if node == nil then
            return false, nil
        end

        return setup.checker:IsContextSensitive(node), nil
    end)
end

-- handleGetReturnTypeOfSignature returns the return type of a signature.
function Session:handleGetReturnTypeOfSignature(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sig, err = setup:resolveSignatureHandle(params.signature)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetReturnTypeOfSignature(sig)), nil
    end)
end

-- handleGetRestTypeOfSignature returns the rest type of a signature.
function Session:handleGetRestTypeOfSignature(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sig, err = setup:resolveSignatureHandle(params.signature)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetRestTypeOfSignature(sig)), nil
    end)
end

-- handleGetTypePredicateOfSignature returns the type predicate of a signature.
function Session:handleGetTypePredicateOfSignature(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local sig, err = setup:resolveSignatureHandle(params.signature)
        if err ~= nil then
            return nil, err
        end

        local pred = setup.checker:GetTypePredicateOfSignature(sig)
        if pred == nil then
            return nil, nil
        end

        local resp = setmetatable({
            kind = pred:Kind(),
            parameterIndex = pred:ParameterIndex(),
            parameterName = pred:ParameterName(),
        }, api.TypePredicateResponse)
        if pred:Type() ~= nil then
            resp.type = setup:newTypeResponse(pred:Type())
        end

        return resp, nil
    end)
end

-- handleIsArrayType returns whether a type is Array<T> or ReadonlyArray<T>.
function Session:handleIsArrayType(ctx, params)
    return self:withCheckerBool(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return false, err
        end

        return setup.checker:IsArrayType(t), nil
    end)
end

-- handleIsTupleType returns whether a type is a tuple type.
function Session:handleIsTupleType(ctx, params)
    return self:withCheckerBool(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return false, err
        end

        return checker.IsTupleType(t), nil
    end)
end

-- handleGetBaseTypes returns the base types of an interface/class type.
function Session:handleGetBaseTypes(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local baseTypes = setup.checker:GetBaseTypes(t)
        if core.Len(baseTypes) == 0 then
            return nil, nil
        end

        local results = {}
        for i, bt in ipairs(baseTypes) do
            results[i] = setup:newTypeResponse(bt)
        end

        return results, nil
    end)
end

-- handleGetPropertiesOfType returns the properties of a type.
function Session:handleGetPropertiesOfType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local props = setup.checker:GetPropertiesOfType(t)
        if core.Len(props) == 0 then
            return nil, nil
        end

        local results = {}
        for i, prop in ipairs(props) do
            results[i] = setup:newSymbolResponse(prop)
        end

        return results, nil
    end)
end

-- handleGetApparentPropertiesOfType returns the apparent properties of a type,
-- including CallableFunction or NewableFunction members where applicable.
function Session:handleGetApparentPropertiesOfType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local props = setup.checker:GetApparentProperties(t)
        local results = {}
        for i, prop in ipairs(props or {}) do
            results[i] = setup:newSymbolResponse(prop)
        end
        return results, nil
    end)
end

-- handleGetApparentType returns the apparent type of a type.
function Session:handleGetApparentType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetApparentType(t)), nil
    end)
end

-- handleGetIndexInfosOfType returns the index infos of a type.
function Session:handleGetIndexInfosOfType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local infos = setup.checker:GetIndexInfosOfType(t)
        if core.Len(infos) == 0 then
            return nil, nil
        end

        local results = {}
        for i, info in ipairs(infos) do
            results[i] = setmetatable({
                keyType = setup:newTypeResponse(info:KeyType()),
                valueType = setup:newTypeResponse(info:ValueType()),
                isReadonly = info:IsReadonly(),
            }, api.IndexInfoResponse)
            if info:Declaration() ~= nil then
                results[i].declaration = setup.sd:nodeHandleFrom(info:Declaration())
            end
        end

        return results, nil
    end)
end

-- handleGetConstraintOfTypeParameter returns the constraint of a type parameter.
function Session:handleGetConstraintOfTypeParameter(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local constraint = setup.checker:GetConstraintOfTypeParameter(t)
        if constraint == nil then
            return nil, nil
        end

        return setup:newTypeResponse(constraint), nil
    end)
end

-- handleGetDefaultFromTypeParameter returns the default type of a type parameter.
function Session:handleGetDefaultFromTypeParameter(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        return setup:newTypeResponse(setup.checker:GetDefaultFromTypeParameter(t)), nil
    end)
end

-- handleGetBaseConstraintOfType returns the base constraint of an instantiable type.
function Session:handleGetBaseConstraintOfType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local constraint = setup.checker:GetBaseConstraintOfType(t)
        if constraint == nil then
            return nil, nil
        end

        return setup:newTypeResponse(constraint), nil
    end)
end

-- handleGetPropertyOfType returns a named property symbol of a type.
function Session:handleGetPropertyOfType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local prop = setup.checker:GetPropertyOfType(t, params.name)
        if prop == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(prop), nil
    end)
end

-- handleGetConstantValue returns the constant value of an enum member or const enum access.
function Session:handleGetConstantValue(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end
        if node == nil then
            return nil, nil
        end

        return api.literalValueToJSON(setup.checker:GetConstantValue(node)), nil
    end)
end

-- handleGetSignatureFromDeclaration returns the signature of a function-like declaration.
function Session:handleGetSignatureFromDeclaration(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end

        return setup:newSignatureResponse(setup.checker:GetSignatureFromDeclaration(node)), nil
    end)
end

-- handleGetExportSpecifierLocalTargetSymbol returns the local target symbol of an export specifier.
function Session:handleGetExportSpecifierLocalTargetSymbol(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local node, err = setup.sd:resolveNodeHandle(setup.program, params.location)
        if err ~= nil then
            return nil, err
        end
        if node == nil then
            return nil, nil
        end

        local symbol = setup.checker:GetExportSpecifierLocalTargetSymbol(node)
        if symbol == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(symbol), nil
    end)
end

-- handleGetAliasedSymbol resolves an alias symbol to its target.
function Session:handleGetAliasedSymbol(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end

        return setup:newSymbolResponse(setup.checker:GetAliasedSymbol(symbol)), nil
    end)
end

-- handleGetFullyQualifiedName returns the fully qualified name of a symbol
-- (e.g. `"/path/to/module".Namespace.Name`).
function Session:handleGetFullyQualifiedName(ctx, params)
    local setup, err = self:setupChecker(ctx, params.snapshot, params.project)
    if err ~= nil then
        return "", err
    end
    return setup:run(function()
        local symbol, serr = setup:resolveSymbolHandle(params.symbol)
        if serr ~= nil then
            return "", serr
        end
        if symbol == nil then
            return "", nil
        end

        return setup.checker:GetFullyQualifiedName(symbol), nil
    end)
end

-- handleGetImmediateAliasedSymbol resolves one level of alias indirection.
function Session:handleGetImmediateAliasedSymbol(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end
        if symbol == nil then
            return nil, nil
        end

        local aliased = setup.checker:GetImmediateAliasedSymbol(symbol)
        if aliased == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(aliased), nil
    end)
end

-- handleGetExportsOfModule returns the resolved exports of a module symbol,
-- including those introduced by `export *` and re-exports.
function Session:handleGetExportsOfModule(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end
        if symbol == nil then
            return nil, nil
        end

        local exports = setup.checker:GetExportsOfModule(symbol)
        if core.Len(exports) == 0 then
            return nil, nil
        end
        table.sort(exports, function(a, b)
            return setup.checker:CompareSymbols(a, b) < 0
        end)

        local results = {}
        for i, exp in ipairs(exports) do
            results[i] = setup:newSymbolResponse(exp)
        end

        return results, nil
    end)
end

-- handleGetMemberInModuleExports returns an export by name from a module symbol.
function Session:handleGetMemberInModuleExports(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end
        if symbol == nil then
            return nil, nil
        end

        local member = setup.checker:TryGetMemberInModuleExports(params.name, symbol)
        if member == nil then
            return nil, nil
        end

        return setup:newSymbolResponse(member), nil
    end)
end

-- handleGetJSDocTags returns the JSDoc tags of a symbol as structured name/text pairs.
function Session:handleGetJSDocTags(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end
        if symbol == nil then
            return nil, nil
        end

        local tags = ls.GetSymbolJSDocTags(symbol)
        if core.Len(tags) == 0 then
            return nil, nil
        end
        local results = {}
        for i, tag in ipairs(tags) do
            results[i] = setmetatable({ name = tag.name, text = tag.text }, api.JSDocTagInfo)
        end
        return results, nil
    end)
end

-- handleGetDocumentationComment returns the rendered documentation comment of a symbol as plain text.
function Session:handleGetDocumentationComment(ctx, params)
    local setup, err = self:setupChecker(ctx, params.snapshot, params.project)
    if err ~= nil then
        return "", err
    end
    return setup:run(function()
        local symbol, serr = setup:resolveSymbolHandle(params.symbol)
        if serr ~= nil then
            return "", serr
        end
        if symbol == nil then
            return "", nil
        end

        return ls.GetSymbolDocumentationComment(setup.checker, symbol), nil
    end)
end

-- handleGetTypeArguments returns the type arguments of a type reference.
function Session:handleGetTypeArguments(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup:resolveTypeHandle(params.type)
        if err ~= nil then
            return nil, err
        end

        local typeArgs = setup.checker:GetTypeArguments(t)
        if core.Len(typeArgs) == 0 then
            return nil, nil
        end

        local results = {}
        for i, ta in ipairs(typeArgs) do
            results[i] = setup:newTypeResponse(ta)
        end

        return results, nil
    end)
end

function Session:handleGetTrueTypeOfConditionalType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup.sd:resolveTypeHandle(params.project, params.type)
        if err ~= nil then
            return nil, err
        end

        return setup.sd:newTypeResponse(params.project, setup.checker:GetTrueTypeOfConditionalType(t)), nil
    end)
end

function Session:handleGetFalseTypeOfConditionalType(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local t, err = setup.sd:resolveTypeHandle(params.project, params.type)
        if err ~= nil then
            return nil, err
        end

        return setup.sd:newTypeResponse(params.project, setup.checker:GetFalseTypeOfConditionalType(t)), nil
    end)
end

-- Returns (node, err).
function snapshotData:resolveNodeHandle(program, handle)
    local s = handle
    -- Format: "index.kind.path" — we need index and path, kind is informational only.
    local firstDot = string.find(s, ".", 1, true)
    if firstDot == nil then
        return nil, clientError("invalid node handle " .. json.QuoteString(handle))
    end
    local secondDot = string.find(s, ".", firstDot + 1, true)
    if secondDot == nil then
        return nil, clientError("invalid node handle " .. json.QuoteString(handle))
    end

    local idxText = string.sub(s, 1, firstDot - 1)
    local idx = nil
    if string.match(idxText, "^%d+$") then
        idx = math.tointeger(tonumber(idxText))
        if idx ~= nil and idx > 4294967295 then
            idx = nil
        end
    end
    if idx == nil then
        local reason = "invalid syntax"
        if string.match(idxText, "^%d+$") then
            reason = "value out of range"
        end
        local numErr = "strconv.ParseUint: parsing " .. json.QuoteString(idxText) .. ": " .. reason
        return nil, clientError("invalid node handle " .. json.QuoteString(handle) .. ": " .. numErr, numErr)
    end
    local path = string.sub(s, secondDot + 1)

    local sourceFile = program:GetSourceFileByPath(path)
    if sourceFile == nil then
        return nil, clientError("node handle " .. json.QuoteString(handle) .. " could not be resolved (file may not be loaded or handle may be stale)")
    end
    local tbl = encoder.GetNodeIndexTable(sourceFile)

    if tbl ~= nil and idx < tbl:Len() then
        local node = tbl:Node(idx)
        if node ~= nil then
            return node, nil
        end
    end
    return nil, clientError("node handle " .. json.QuoteString(handle) .. " could not be resolved (file may not be loaded or handle may be stale)")
end

-- computeSnapshotChanges computes the per-project source file differences between
-- two snapshots. It uses DiffOrderedMaps on projects to find changed/removed projects,
-- then DiffMaps on FilesByPath for each changed project to collect file-level changes.
function api.computeSnapshotChanges(prev, next_)
    local prevProjects = prev.projectCollection:ProjectsByPath()
    local nextProjects = next_.projectCollection:ProjectsByPath()

    local changes = setmetatable({}, api.SnapshotChanges)

    collections.DiffOrderedMaps(
        prevProjects, nextProjects,
        -- onAdded: new project — nothing to retain from previous snapshot.
        function(_, _) end,
        -- onRemoved: project removed entirely.
        function(_, oldProj)
            changes.removedProjects = changes.removedProjects or {}
            changes.removedProjects[#changes.removedProjects + 1] = api.ProjectHandle(oldProj)
        end,
        -- onModified: project changed, diff its files.
        function(_, oldProj, newProj)
            if oldProj:GetProgram() == newProj:GetProgram() then
                return
            end
            local oldFiles, newFiles
            local p = oldProj:GetProgram()
            if p ~= nil then
                oldFiles = p:FilesByPath()
            end
            p = newProj:GetProgram()
            if p ~= nil then
                newFiles = p:FilesByPath()
            end
            local projectChanges = setmetatable({}, api.ProjectFileChanges)
            core.DiffMaps(
                oldFiles, newFiles,
                nil, -- onAdded: new file in project, not a change.
                function(path, _)
                    projectChanges.deletedFiles = projectChanges.deletedFiles or {}
                    projectChanges.deletedFiles[#projectChanges.deletedFiles + 1] = path
                end,
                function(path, _, _)
                    projectChanges.changedFiles = projectChanges.changedFiles or {}
                    projectChanges.changedFiles[#projectChanges.changedFiles + 1] = path
                end
            )
            if core.Len(projectChanges.changedFiles) > 0 or core.Len(projectChanges.deletedFiles) > 0 then
                if changes.changedProjects == nil then
                    changes.changedProjects = {}
                end
                changes.changedProjects[api.ProjectHandle(newProj)] = projectChanges
            end
        end
    )

    return changes
end

-- Close closes the session and releases all active snapshots,
-- regardless of their ref counts.
function Session:Close()
    self:releaseOpenRefs()

    for handleID, sd in pairs(self.snapshots) do
        sd.snapshot:Deref(self.projectSession)
        self.snapshots[handleID] = nil
    end
end

-- releaseOpenRefs releases every project and file ref this session is holding open
-- in the project session. This keeps the API's ref counts balanced when an API
-- session is shut down while sharing a longer-lived project session (e.g. one
-- backing an LSP server), so API-opened projects and files aren't leaked. Only
-- refs the session currently holds are closed, so it never over-releases.
function Session:releaseOpenRefs()
    if self.openProjects:Len() == 0 and self.openFiles:Len() == 0 then
        return
    end

    local apiRequest = {} -- project.APISnapshotRequest
    if self.openProjects:Len() > 0 then
        apiRequest.closeProjects = self.openProjects:Clone()
    end
    if self.openFiles:Len() > 0 then
        apiRequest.closeFiles = self.openFiles:Clone()
    end
    local snapshot, err = self.projectSession:APIUpdate(nil, project.newFileChangeSummary(), apiRequest)
    -- APIUpdate returns a ref'd snapshot even on error; always release it.
    snapshot:Deref(self.projectSession)
    if err ~= nil then
        return
    end

    self.openProjects:Clear()
    self.openFiles:Clear()
end

function api.formatSessionID(id)
    return "api-session-" .. tostring(id)
end

-- toPath converts a file name to a normalized path.
function Session:toPath(fileName)
    return tspath.ToPath(fileName, self.projectSession:GetCurrentDirectory(), self.projectSession:FS():UseCaseSensitiveFileNames())
end

-- toFileChangeSummary converts API file changes to a project.FileChangeSummary.
function Session:toFileChangeSummary(changes)
    if changes == nil then
        return project.newFileChangeSummary()
    end
    local summary = project.newFileChangeSummary()
    if changes.invalidateAll then
        summary.invalidateAll = true
        summary.includesWatchChangeOutsideNodeModules = true
        return summary
    end
    local cwd = self.projectSession:GetCurrentDirectory()
    for _, doc in ipairs(changes.changed or {}) do
        local uri = doc:ToURI(cwd)
        summary.changed:Add(uri)
    end
    for _, doc in ipairs(changes.created or {}) do
        local uri = doc:ToURI(cwd)
        summary.created:Add(uri)
    end
    for _, doc in ipairs(changes.deleted or {}) do
        local uri = doc:ToURI(cwd)
        summary.deleted:Add(uri)
    end
    if summary.changed:Len() + summary.created:Len() + summary.deleted:Len() > 0 then
        summary.includesWatchChangeOutsideNodeModules = true
    end
    return summary
end

-- getter(program, ctx, sourceFile) -> diagnostics. Returns (responses, err).
function Session:getDiagnostics(ctx, params, getter)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    if params.files ~= nil then
        local allDiags = {}
        for _, file in ipairs(params.files) do
            local sourceFile
            sourceFile, err = self:resolveOptionalSourceFile(program, file)
            if err ~= nil then
                return nil, err
            end
            for _, d in ipairs(getter(program, ctx, sourceFile) or {}) do
                allDiags[#allDiags + 1] = d
            end
        end
        return api.NewDiagnosticResponses(allDiags), nil
    end

    return api.NewDiagnosticResponses(getter(program, ctx, nil)), nil
end

function Session:handleGetSyntacticDiagnostics(ctx, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    return self:getDiagnostics(ctx, params, function(p, c, f)
        return p:GetSyntacticDiagnostics(c, f)
    end)
end

function Session:handleGetBindDiagnostics(ctx, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    return self:getDiagnostics(ctx, params, function(p, c, f)
        return p:GetBindDiagnostics(c, f)
    end)
end

function Session:handleGetSemanticDiagnostics(ctx, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    return self:getDiagnostics(ctx, params, function(p, c, f)
        return p:GetSemanticDiagnostics(c, f)
    end)
end

function Session:handleGetSuggestionDiagnostics(ctx, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    return self:getDiagnostics(ctx, params, function(p, c, f)
        return p:GetSuggestionDiagnostics(c, f)
    end)
end

function Session:handleGetDeclarationDiagnostics(ctx, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    return self:getDiagnostics(ctx, params, function(p, c, f)
        return p:GetDeclarationDiagnostics(c, f)
    end)
end

-- handleGetConfigFileParsingDiagnostics returns config file parsing diagnostics.
function Session:handleGetConfigFileParsingDiagnostics(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local diags = program:GetConfigFileParsingDiagnostics()
    return api.NewDiagnosticResponses(diags), nil
end

-- handleGetProgramDiagnostics returns program-wide diagnostics, including options diagnostics.
function Session:handleGetProgramDiagnostics(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local diags = program:GetProgramDiagnostics()
    return api.NewDiagnosticResponses(diags), nil
end

-- handleGetGlobalDiagnostics returns global (non-file-specific) semantic diagnostics.
function Session:handleGetGlobalDiagnostics(ctx, params)
    ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.Diagnostics)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end

    local proj
    proj, err = sd:getProject(params.project)
    if err ~= nil then
        return nil, err
    end

    local program = proj:GetProgram()
    if program == nil then
        return nil, clientError("project has no program")
    end

    -- Global diagnostics are accumulated lazily by the project's checker pool as
    -- files are checked. Force a full semantic pass so any global (non-file-specific)
    -- diagnostics are produced; otherwise this would return an empty result for
    -- projects using an external checker pool (the typical API case), since
    -- compiler.Program.GetGlobalDiagnostics only reports for the internal pool.
    program:GetSemanticDiagnostics(ctx, nil)

    local diags = core.Filter(proj:GetProjectDiagnostics(ctx), function(d)
        return d:File() == nil
    end)
    return api.NewDiagnosticResponses(diags), nil
end

-- resolveOptionalSourceFile resolves an optional DocumentIdentifier to a source file.
-- Returns nil if the identifier is nil (meaning all files). Returns (sourceFile, err).
function Session:resolveOptionalSourceFile(program, file)
    if file == nil then
        return nil, nil
    end
    local sourceFile = program:GetSourceFile(file:ToFileName())
    if sourceFile == nil then
        return nil, clientError("source file not found: &" .. formatDocumentIdentifier(file))
    end
    return sourceFile, nil
end

-- handleGetReferencesToSymbolInFile returns node handles for all identifiers in a file that reference the given symbol.
function Session:handleGetReferencesToSymbolInFile(ctx, params)
    return self:withChecker(ctx, params.snapshot, params.project, function(setup)
        local symbol, err = setup:resolveSymbolHandle(params.symbol)
        if err ~= nil then
            return nil, err
        end
        if symbol == nil then
            return nil, nil
        end

        local sourceFile = setup.program:GetSourceFile(params.file:ToFileName())
        if sourceFile == nil then
            return nil, clientError("source file not found: " .. formatDocumentIdentifier(params.file))
        end

        local nodes = setup.checker:GetReferencesToSymbolInFile(sourceFile, symbol)
        local result = {}
        for i, node in ipairs(nodes or {}) do
            result[i] = setup.sd:nodeHandleFrom(node)
        end
        return result, nil
    end)
end

function Session:handleGetSignatureUsages(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end
    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local signatureDecl
    signatureDecl, err = sd:resolveNodeHandle(program, params.signatureDecl)
    if err ~= nil then
        return nil, err
    end
    if signatureDecl == nil then
        return nil, nil
    end

    local langSvc
    langSvc, err = self:setupLanguageService(sd, program, params.project, "")
    if err ~= nil then
        return nil, err
    end

    local usages = langSvc:GetSignatureUsages(ctx, signatureDecl)
    if usages == nil then
        return nil, nil
    end

    local result = {}
    for _, u in ipairs(usages) do
        local entry = setmetatable({
            name = sd:nodeHandleFrom(u.name),
        }, api.SignatureUsageResponse)
        if u.call ~= nil then
            entry.call = sd:nodeHandleFrom(u.call)
        end
        result[#result + 1] = entry
    end
    return result, nil
end

-- handleGetCompletionsAtPosition returns completions at a position in a document.
function Session:handleGetCompletionsAtPosition(ctx, params)
    if params.includeSymbol then
        ctx = core.WithCheckerLifetime(ctx, core.CheckerLifetime.API)
    end
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end
    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end
    local sourceFile = program:GetSourceFile(params.file:ToFileName())
    if sourceFile == nil then
        return nil, nil
    end
    local langSvc
    langSvc, err = self:setupLanguageService(sd, program, params.project, "")
    if err ~= nil then
        return nil, err
    end
    local positionMap = sourceFile:GetPositionMap()
    local internalPos = positionMap:UTF16ToUTF8(params.position)
    local result
    result, err = langSvc:GetCompletionsAtPosition(ctx, sourceFile, internalPos, params.triggerCharacter, params.includeSymbol == true)
    if err ~= nil or result == nil then
        return nil, err
    end
    local entries = {}
    for _, item in ipairs(result.items or {}) do
        local entry = setmetatable({
            name = item.label,
            sortText = item.sortText,
            insertText = item.insertText,
            filterText = item.filterText,
            detail = item.detail,
        }, api.CompletionEntryResponse)
        if item.kind ~= nil then
            entry.kind = item.kind
        end
        if item.labelDetails ~= nil then
            entry.labelDetails = setmetatable({
                detail = item.labelDetails.detail,
                description = item.labelDetails.description,
            }, api.CompletionEntryLabelDetailsResponse)
        end
        if item.symbol ~= nil then
            entry.symbol = sd:newSymbolResponse(item.symbol, params.project)
        end
        entries[#entries + 1] = entry
    end
    return setmetatable({
        isIncomplete = result.isIncomplete == true,
        entries = entries,
    }, api.CompletionInfoResponse), nil
end

-- handleGetReferencedSymbolsForNode returns node handles for all references found at a node.
function Session:handleGetReferencedSymbolsForNode(ctx, params)
    local sd, err = self:getSnapshotData(params.snapshot)
    if err ~= nil then
        return nil, err
    end
    local program
    program, err = sd:getProgram(params.project)
    if err ~= nil then
        return nil, err
    end

    local node
    node, err = sd:resolveNodeHandle(program, params.node)
    if err ~= nil then
        return nil, err
    end
    if node == nil then
        return nil, nil
    end

    local langSvc
    langSvc, err = self:setupLanguageService(sd, program, params.project, "")
    if err ~= nil then
        return nil, err
    end

    local sourceFiles = program:GetSourceFiles()
    local entries = langSvc:GetReferencedSymbolsForNode(ctx, params.position, node, sourceFiles)
    if entries == nil then
        return nil, nil
    end

    local result
    for _, entry in ipairs(entries) do
        local defNode = entry:DefinitionNode()
        if defNode ~= nil then
            local refs
            for _, ref in ipairs(entry:References() or {}) do
                if ref:IsNodeEntry() then
                    refs = refs or {}
                    refs[#refs + 1] = sd:nodeHandleFrom(ref:Node())
                end
            end
            local re = setmetatable({
                definition = sd:nodeHandleFrom(defNode),
                references = refs,
            }, api.ReferencedSymbolEntry)
            local sym = entry:DefinitionSymbol()
            if sym ~= nil then
                re.symbol = sd:newSymbolResponse(sym, params.project)
            end
            result = result or {}
            result[#result + 1] = re
        end
    end
    return result, nil
end
