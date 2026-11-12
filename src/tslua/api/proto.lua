local api = require("tslua.api")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local jsnum = require("tslua.jsnum")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local locale = require("tslua.locale")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local packagejson = require("tslua.packagejson")
local tspath = require("tslua.tspath")

local Method = api.Method
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags

api.ErrInvalidRequest = jsonrpc.NewError("api: invalid request")
api.ErrClientError = jsonrpc.NewError("api: client error")

-- Handle types (Go named scalar types): SnapshotID uint64, ProjectID string, SymbolID uint64,
-- TypeID uint32, SignatureID uint64, NodeHandle string.
api.defineAlias("Method", "string")
api.defineAlias("SnapshotID", "uint64")
api.defineAlias("ProjectID", "string")
api.defineAlias("SymbolID", "uint64")
api.defineAlias("TypeID", "uint32")
api.defineAlias("SignatureID", "uint64")
api.defineAlias("NodeHandle", "string")
api.defineAlias("tspath.Path", "string")
api.defineAlias("lsproto.DocumentUri", "string")
api.defineAlias("diagnostics.Category", "int32")
api.defineAlias("core.ResolutionMode", "int32")
api.defineAlias("checker.ElementFlags", "uint32")
api.defineAlias("ImportAdderActionKind", "string")

function api.ProjectHandle(p)
    return p:ID()
end

function api.SymbolHandle(symbol)
    return ast.GetSymbolId(symbol)
end

function api.TypeHandle(t)
    return t:Id()
end

function api.SignatureHandle(sig)
    return sig:Id()
end

function api.parseProjectHandle(handle)
    return handle
end

-- InitializeResponse is returned by the initialize method.
api.defineStruct("InitializeResponse", {
    -- UseCaseSensitiveFileNames indicates whether the host file system is case-sensitive.
    { "useCaseSensitiveFileNames", "bool", "useCaseSensitiveFileNames" },
    -- CurrentDirectory is the server's current working directory.
    { "currentDirectory", "string", "currentDirectory" },
})

-- DocumentIdentifier identifies a document by either a file name (plain string) or a URI object.
-- On the wire it is string | { uri: string }.
local DocumentIdentifier = {}
api.DocumentIdentifier = DocumentIdentifier
api.defineStruct("DocumentIdentifier", {
    { "fileName", "string", "fileName,omitempty" },
    { "uri", "lsproto.DocumentUri", "uri,omitempty" },
})

function api.NewDocumentIdentifier(fileName, uri)
    return setmetatable({ fileName = fileName or "", uri = uri or "" }, DocumentIdentifier)
end

-- UnmarshalJSONFrom fills d from the decoder. Returns err.
function DocumentIdentifier:UnmarshalJSONFrom(dec)
    -- Try reading as a plain string first
    local tok, err = dec:ReadToken()
    if err ~= nil then
        return err
    end
    local kind = tok:Kind()
    if kind == '"' then
        self.fileName = tok:String()
        return nil
    elseif kind == "{" then
        -- Read the object fields
        while dec:PeekKind() ~= "}" do
            local key
            key, err = dec:ReadToken()
            if err ~= nil then
                return err
            end
            local isURI = key:String() == "uri"
            local val
            val, err = dec:ReadToken()
            if err ~= nil then
                return err
            end
            if isURI then
                self.uri = val:String()
            end
        end
        -- Consume the closing brace
        local _
        _, err = dec:ReadToken()
        if err ~= nil then
            return err
        end
        return nil
    end
    return "DocumentIdentifier: expected string or object, got " .. jsonrpc.kindName(kind)
end

-- The struct spec registered above is used for marshaling; unmarshaling goes through
-- UnmarshalJSONFrom, like Go's json.UnmarshalerFrom.
api.structSpecs["DocumentIdentifier"] = nil
api.defineCustom("DocumentIdentifier", {
    encode = function(buf, v)
        local s, err = api.MarshalAs("DocumentIdentifierStruct", v)
        if err ~= nil then
            return err
        end
        buf[#buf + 1] = s
        return nil
    end,
    decode = function(dec)
        local d = api.NewDocumentIdentifier()
        local err = d:UnmarshalJSONFrom(dec)
        if err ~= nil then
            return nil, err
        end
        return d, nil
    end,
    isZero = function(v)
        return (v.fileName or "") == "" and (v.uri or "") == ""
    end,
    zero = function()
        return api.NewDocumentIdentifier()
    end,
})
api.defineStruct("DocumentIdentifierStruct", {
    { "fileName", "string", "fileName,omitempty" },
    { "uri", "lsproto.DocumentUri", "uri,omitempty" },
})
DocumentIdentifier.__index = DocumentIdentifier
DocumentIdentifier.__name = "api.DocumentIdentifier"
DocumentIdentifier.MarshalJSON = function(self)
    return api.MarshalAs("DocumentIdentifier", self)
end

function DocumentIdentifier:ToFileName()
    if self.uri ~= "" then
        return lsproto.DocumentUri_FileName(self.uri)
    end
    return self.fileName
end

-- ToURI returns the document URI for this identifier. An explicitly provided URI
-- is returned as-is; a file name is first normalized to an absolute path against
-- cwd before being converted to a URI.
function DocumentIdentifier:ToURI(cwd)
    if self.uri ~= "" then
        return self.uri
    end
    return lsconv.FileNameToDocumentURI(tspath.GetNormalizedAbsolutePath(self.fileName, cwd))
end

function DocumentIdentifier:ToAbsoluteFileName(cwd)
    if self.uri ~= "" then
        return lsproto.DocumentUri_FileName(self.uri)
    end
    return tspath.GetNormalizedAbsolutePath(self.fileName, cwd)
end

function DocumentIdentifier:String()
    if self.uri ~= "" then
        return self.uri
    end
    return self.fileName
end

-- APIFileChangeSummary lists documents that have been changed, created, or deleted.
api.defineStruct("APIFileChangeSummary", {
    { "changed", "[]DocumentIdentifier", "changed,omitempty" },
    { "created", "[]DocumentIdentifier", "created,omitempty" },
    { "deleted", "[]DocumentIdentifier", "deleted,omitempty" },
})

-- APIFileChanges describes file changes to apply when updating a snapshot.
-- Either InvalidateAll is true (discard all caches) or Changed/Created/Deleted
-- list individual documents.
api.defineStruct("APIFileChanges", {
    { "invalidateAll", "bool", "invalidateAll,omitempty" },
    { "changed", "[]DocumentIdentifier", "changed,omitempty" },
    { "created", "[]DocumentIdentifier", "created,omitempty" },
    { "deleted", "[]DocumentIdentifier", "deleted,omitempty" },
})

-- UpdateSnapshotParams are the parameters for creating a new snapshot.
-- All fields are optional. With no fields set, the server adopts the latest LSP state.
api.defineStruct("UpdateSnapshotParams", {
    -- OpenProjects lists tsconfig.json files to open/load in the new snapshot.
    -- Opens are ref-counted and persist across snapshots until closed.
    { "openProjects", "[]DocumentIdentifier", "openProjects,omitempty" },
    -- CloseProjects lists tsconfig.json files to release in the new snapshot.
    -- A project is only unloaded once every API client that opened it closes it.
    { "closeProjects", "[]DocumentIdentifier", "closeProjects,omitempty" },
    -- FileChanges describes file system changes since the last snapshot.
    { "fileChanges", "*APIFileChanges", "fileChanges,omitempty" },
    -- OpenFiles lists files to keep open for the API client, mirroring LSP's
    -- textDocument/didOpen. For each file, ancestor directories are searched for a
    -- tsconfig that contains it; if found, that configured project is loaded and
    -- becomes the file's default project. Otherwise the file is loaded into the
    -- inferred project (e.g. a node_modules d.ts not in any project's import graph).
    -- Opens persist across snapshots until the file is closed.
    { "openFiles", "[]DocumentIdentifier", "openFiles,omitempty" },
    -- CloseFiles lists files to release in the new snapshot. A file is only fully
    -- closed once every API client that opened it closes it.
    { "closeFiles", "[]DocumentIdentifier", "closeFiles,omitempty" },
})

-- UpdateTemporarySnapshotParams are the parameters for creating a temporary
-- snapshot that overrides a single file's content.
api.defineStruct("UpdateTemporarySnapshotParams", {
    -- Snapshot is the current client snapshot on which to layer the temporary update.
    { "snapshot", "SnapshotID", "snapshot" },
    -- File identifies the file whose content is temporarily overridden.
    { "file", "DocumentIdentifier", "file" },
    -- NewText is the temporary content for the file.
    { "newText", "string", "newText" },
})

-- ProjectFileChanges describes what source files changed within a single project.
api.defineStruct("ProjectFileChanges", {
    -- ChangedFiles lists source file paths whose content differs.
    { "changedFiles", "[]tspath.Path", "changedFiles,omitempty" },
    -- DeletedFiles lists source file paths removed from the project's program.
    { "deletedFiles", "[]tspath.Path", "deletedFiles,omitempty" },
})

-- SnapshotChanges describes what changed between the previous latest snapshot
-- and the newly created snapshot. Changes are reported per-project so clients
-- can track cache refs at the (snapshot, project) level.
api.defineStruct("SnapshotChanges", {
    -- ChangedProjects maps project handles to the file changes within that project.
    -- Projects not listed here (and not in RemovedProjects) are unchanged.
    { "changedProjects", "map[string]*ProjectFileChanges", "changedProjects,omitempty" },
    -- RemovedProjects lists project handles that were present in the previous
    -- snapshot but absent from the new one.
    { "removedProjects", "[]ProjectID", "removedProjects,omitempty" },
})

-- UpdateSnapshotResponse is returned by updateSnapshot.
api.defineStruct("UpdateSnapshotResponse", {
    -- Snapshot is the handle for the newly created snapshot.
    { "snapshot", "SnapshotID", "snapshot" },
    -- Projects is the list of projects in the snapshot.
    { "projects", "[]*ProjectResponse", "projects" },
    -- Changes describes source file differences from the previous snapshot.
    -- Nil for the first snapshot in a session.
    { "changes", "*SnapshotChanges", "changes,omitempty" },
})

-- Params structs are defined before the unmarshalers table, which references them by name.

api.defineStruct("ParseConfigFileParams", {
    { "file", "DocumentIdentifier", "file" },
})

api.defineStruct("ParseCommandLineParams", {
    { "commandLine", "[]string", "commandLine" },
})

api.defineStruct("ReadConfigFileParams", {
    { "file", "DocumentIdentifier", "file" },
})

api.defineCustom("packagejson.JSONValue", {
    encode = function(buf, v)
        local s, err = json.Marshal(api.jsonValueToAny(v))
        if err ~= nil then
            return err
        end
        buf[#buf + 1] = s
        return nil
    end,
    decode = function(dec)
        local decoded, err = json.UnmarshalDecode(dec, { ordered = true })
        if err ~= nil then
            return nil, err
        end
        return packagejson.unmarshalJSONValue(packagejson.JSONValue, decoded), nil
    end,
    isZero = function(v)
        return v.type == packagejson.JSONValueType.NotPresent
    end,
    zero = function()
        return packagejson.NewJSONValue(packagejson.JSONValueType.NotPresent, nil)
    end,
})

api.defineStruct("ParseJsonConfigFileContentParams", {
    { "json", "packagejson.JSONValue", "json" },
    { "configDirectory", "*string", "configDirectory,omitempty" },
    { "configFileName", "*DocumentIdentifier", "configFileName,omitempty" },
})

function api.jsonValueToAny(value)
    local t = value.type
    local JSONValueType = packagejson.JSONValueType
    if t == JSONValueType.NotPresent or t == JSONValueType.Null then
        return nil
    elseif t == JSONValueType.String or t == JSONValueType.Number or t == JSONValueType.Boolean then
        return value.value
    elseif t == JSONValueType.Array then
        local array = value:AsArray()
        local result = {}
        for i, child in ipairs(array) do
            local v = api.jsonValueToAny(child)
            if v == nil then
                v = json.Null
            end
            result[i] = v
        end
        return result
    elseif t == JSONValueType.Object then
        local object = value:AsObject()
        local result = collections.NewOrderedMapWithSizeHint(object:Size())
        for key, child in object:Entries() do
            result:Set(key, api.jsonValueToAny(child))
        end
        return result
    end
    error("unexpected JSON value type " .. tostring(t), 0)
end

api.defineStruct("TranspileOptions", {
    { "compilerOptions", "*core.CompilerOptions", "compilerOptions,omitempty" },
    { "fileName", "string", "fileName,omitempty" },
    { "reportDiagnostics", "bool", "reportDiagnostics,omitempty" },
})

api.defineStruct("TranspileParams", {
    { "input", "string", "input" },
    { "options", "TranspileOptions", "options" },
})

api.defineStruct("TranspileFromFileParams", {
    { "fileName", "string", "fileName" },
    { "options", "TranspileOptions", "options" },
})

api.defineStruct("DiagnosticResponse", {
    -- FileName is the path of the file this diagnostic belongs to, if any.
    { "fileName", "string", "fileName,omitempty" },
    -- Pos is the start position of the diagnostic in the source file.
    { "pos", "int", "pos" },
    -- End is the end position of the diagnostic in the source file.
    { "end_", "int", "end" },
    -- Code is the diagnostic error code.
    { "code", "int32", "code" },
    -- Category is the diagnostic category (error, warning, suggestion, message).
    { "category", "diagnostics.Category", "category" },
    -- Text is the localized diagnostic message text.
    { "text", "string", "text" },
    -- ReportsUnnecessary indicates this diagnostic highlights unnecessary code.
    { "reportsUnnecessary", "bool", "reportsUnnecessary,omitzero" },
    -- ReportsDeprecated indicates this diagnostic highlights deprecated code.
    { "reportsDeprecated", "bool", "reportsDeprecated,omitzero" },
    -- MessageChain contains chained diagnostic messages, if any.
    { "messageChain", "[]*DiagnosticResponse", "messageChain,omitempty" },
    -- RelatedInformation contains related diagnostic information, if any.
    { "relatedInformation", "[]*DiagnosticResponse", "relatedInformation,omitempty" },
})

api.defineStruct("TranspileOutputResponse", {
    { "outputText", "string", "outputText" },
    { "diagnostics", "[]*DiagnosticResponse", "diagnostics,omitempty" },
    { "sourceMapText", "string", "sourceMapText,omitempty" },
})

-- ReleaseParams are the parameters for the release method.
api.defineStruct("ReleaseParams", {
    { "snapshot", "SnapshotID", "snapshot" },
})

api.defineStruct("ProfileParams", {
    { "dir", "string", "dir" },
})

api.defineStruct("ProfileResult", {
    { "file", "string", "file" },
})

api.defineStruct("ConfigFileResponse", {
    { "fileNames", "[]string", "fileNames" },
    { "options", "*core.CompilerOptions", "options" },
    { "projectReferences", "[]*core.ProjectReference", "projectReferences,omitempty" },
    { "typeAcquisition", "*core.TypeAcquisition", "typeAcquisition,omitempty" },
    { "compileOnSave", "*bool", "compileOnSave,omitempty" },
    { "raw", "anyValue", "raw,omitempty" },
    { "errors", "[]*DiagnosticResponse", "errors" },
})

api.defineStruct("ReadConfigFileResponse", {
    { "config", "anyValue", "config" },
    { "error_", "*DiagnosticResponse", "error,omitempty" },
})

api.defineStruct("GetDefaultProjectForFileParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "file", "DocumentIdentifier", "file" },
})

api.defineStruct("ProjectResponse", {
    { "id", "ProjectID", "id" },
    { "configFileName", "string", "configFileName" },
    { "parsedCommandLine", "*ConfigFileResponse", "parsedCommandLine" },
    -- Deprecated: Use parsedCommandLine.fileNames.
    { "rootFiles", "[]string", "rootFiles" },
    -- Deprecated: Use parsedCommandLine.options.
    { "compilerOptions", "*core.CompilerOptions", "compilerOptions" },
})

function api.NewConfigFileResponse(parsedCommandLine)
    if parsedCommandLine == nil then
        return nil
    end
    local compileOnSave = parsedCommandLine.compileOnSave
    if compileOnSave == nil then
        local rawConfig = parsedCommandLine.raw
        if rawConfig ~= nil and getmetatable(rawConfig) == collections.OrderedMap then
            local value = rawConfig:GetOrZero("compileOnSave")
            if type(value) == "boolean" then
                compileOnSave = value
            end
        end
    end
    local compilerOptions = parsedCommandLine:CompilerOptions()
    local errors = api.NewDiagnosticResponses(parsedCommandLine.errors)
    if errors == nil then
        errors = {}
    end
    return setmetatable({
        fileNames = parsedCommandLine:FileNames(),
        options = compilerOptions,
        projectReferences = parsedCommandLine:ProjectReferences(),
        typeAcquisition = parsedCommandLine:TypeAcquisition(),
        compileOnSave = compileOnSave,
        raw = api.toProtocolJSONValue(parsedCommandLine.raw),
        errors = errors,
    }, api.ConfigFileResponse)
end

-- Go also converts core.WatchFileKind / WatchDirectoryKind / PollingKind values (int(value) - 1).
-- Lua numbers carry no Go type, so those enum values cannot be told apart from plain numbers in
-- the raw config and pass through unchanged (known deviation).
function api.toProtocolJSONValue(value)
    if type(value) == "table" and value ~= json.Null then
        local mt = getmetatable(value)
        if mt == collections.OrderedMap then
            local result = collections.NewOrderedMapWithSizeHint(value:Size())
            for key, child in value:Entries() do
                result:Set(key, api.toProtocolJSONValue(child))
            end
            return result
        elseif mt == nil then
            local result = {}
            for i, child in ipairs(value) do
                result[i] = api.toProtocolJSONValue(child)
            end
            return result
        end
    end
    return value
end

function api.NewProjectResponse(p)
    if p == nil or p.commandLine == nil then
        error("NewProjectResponse called with unloaded project", 0)
    end
    return setmetatable({
        id = api.ProjectHandle(p),
        configFileName = p:Name(),
        parsedCommandLine = api.NewConfigFileResponse(p.commandLine),
        rootFiles = p.commandLine:FileNames(),
        compilerOptions = p.commandLine:CompilerOptions(),
    }, api.ProjectResponse)
end

api.defineStruct("GetSymbolAtPositionParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "position", "uint32", "position" },
})

api.defineStruct("GetSymbolsAtPositionsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "positions", "[]uint32", "positions" },
})

api.defineStruct("GetSymbolOfSourceFileParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
})

api.defineStruct("GetSymbolsOfSourceFilesParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "files", "[]DocumentIdentifier", "files" },
})

api.defineStruct("GetSymbolAtLocationParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location" },
})

api.defineStruct("GetSymbolsAtLocationsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "locations", "[]NodeHandle", "locations" },
})

api.defineStruct("SymbolResponse", {
    { "id", "SymbolID", "id" },
    -- Project is the project in which the symbol was first observed. It is the
    -- default project for follow-up lookups whose results can vary by project.
    { "project", "ProjectID", "project" },
    { "name", "string", "name" },
    { "flags", "uint32", "flags" },
    { "checkFlags", "uint32", "checkFlags" },
    { "declarations", "[]NodeHandle", "declarations,omitempty" },
    { "valueDeclaration", "NodeHandle", "valueDeclaration,omitempty" },
    { "parent", "SymbolID", "parent,omitzero" },
    { "exportSymbol", "SymbolID", "exportSymbol,omitzero" },
})

function api.symbolHandles(symbols)
    if core.Len(symbols) == 0 then
        return nil
    end
    local handles = {}
    for i, t in ipairs(symbols) do
        handles[i] = api.SymbolHandle(t)
    end
    return handles
end

api.defineStruct("GetTypeOfSymbolParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "symbol", "SymbolID", "symbol" },
})

api.defineStruct("GetTypesOfSymbolsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "symbols", "[]SymbolID", "symbols" },
})

api.defineStruct("TypeResponse", {
    { "id", "TypeID", "id" },
    { "flags", "uint32", "flags" },
    { "objectFlags", "uint32", "objectFlags,omitempty" },

    -- Value is literal type data. BigInt literals are encoded as signed decimal
    -- strings because JSON cannot represent bigint; absent values are null.
    { "value", "any", "value" },

    -- ObjectType / TypeReference / StringMappingType / IndexType target
    { "target", "TypeID", "target,omitzero" },

    -- InterfaceType type parameters
    { "typeParameters", "[]TypeID", "typeParameters,omitempty" },
    { "outerTypeParameters", "[]TypeID", "outerTypeParameters,omitempty" },
    { "localTypeParameters", "[]TypeID", "localTypeParameters,omitempty" },

    -- TupleType data
    { "elementFlags", "[]checker.ElementFlags", "elementFlags,omitempty" },
    { "fixedLength", "*int", "fixedLength,omitempty" },
    { "tupleReadonly", "*bool", "readonly,omitempty" },

    -- IndexedAccessType data
    { "objectType", "TypeID", "objectType,omitzero" },
    { "indexType", "TypeID", "indexType,omitzero" },

    -- ConditionalType data
    { "checkType", "TypeID", "checkType,omitzero" },
    { "extendsType", "TypeID", "extendsType,omitzero" },

    -- SubstitutionType data
    { "baseType", "TypeID", "baseType,omitzero" },
    { "substConstraint", "TypeID", "substConstraint,omitzero" },

    -- TemplateLiteralType text segments
    { "texts", "[]string", "texts,omitempty" },

    -- FreshableType data (LiteralType and computed enum types)
    { "freshType", "TypeID", "freshType,omitzero" },
    { "regularType", "TypeID", "regularType,omitzero" },

    -- TypeParameter data
    { "isThisType", "bool", "isThisType,omitempty" },

    -- IntrinsicType data
    { "intrinsicName", "string", "intrinsicName,omitempty" },

    -- TypeAlias data
    { "aliasTypeArguments", "[]TypeID", "aliasTypeArguments,omitempty" },
    { "aliasSymbol", "SymbolID", "aliasSymbol,omitzero" },

    -- Symbol associated with structured types
    { "symbol", "SymbolID", "symbol,omitzero" },
})

function api.newTypeResponse(t, id)
    local resp = setmetatable({
        id = id,
        flags = t:Flags() & 0xFFFFFFFF,
    }, api.TypeResponse)

    if t:Symbol() ~= nil then
        resp.symbol = api.SymbolHandle(t:Symbol())
    end

    if t:Alias() ~= nil then
        resp.aliasTypeArguments = api.typeHandles(t:Alias():TypeArguments())
        if t:Alias():Symbol() ~= nil then
            resp.aliasSymbol = api.SymbolHandle(t:Alias():Symbol())
        end
    end

    local flags = t:Flags()
    if flags & TypeFlags.Freshable ~= 0 then
        local lit = t:AsLiteralType()
        if flags & TypeFlags.Literal ~= 0 then
            resp.value = api.literalValueToJSON(lit:Value())
        end
        if lit:FreshType() ~= nil then
            resp.freshType = api.TypeHandle(lit:FreshType())
        end
        if lit:RegularType() ~= nil then
            resp.regularType = api.TypeHandle(lit:RegularType())
        end
    elseif flags & TypeFlags.Object ~= 0 then
        resp.objectFlags = t:ObjectFlags() & 0xFFFFFFFF
        local objectFlags = t:ObjectFlags()
        if objectFlags & ObjectFlags.Reference ~= 0 then
            local ref
            if objectFlags & ObjectFlags.Tuple ~= 0 then
                local tuple = t:AsTupleType()
                ref = tuple:AsTypeReference()
                resp.elementFlags = tuple:ElementFlags()
                local fixedLen = tuple:FixedLength()
                resp.fixedLength = fixedLen
                local isReadonly = tuple:IsReadonly()
                resp.tupleReadonly = isReadonly
            else
                ref = t:AsTypeReference()
            end
            if ref:Target() ~= nil then
                resp.target = api.TypeHandle(ref:Target())
            end
        end
        if objectFlags & ObjectFlags.ClassOrInterface ~= 0 then
            local iface = t:AsInterfaceType()
            resp.typeParameters = api.typeHandles(iface:TypeParameters())
            resp.outerTypeParameters = api.typeHandles(iface:OuterTypeParameters())
            resp.localTypeParameters = api.typeHandles(iface:LocalTypeParameters())
        end
    elseif flags & TypeFlags.UnionOrIntersection ~= 0 then
        -- types omitted; fetched via separate request
    elseif flags & TypeFlags.Index ~= 0 then
        resp.target = api.TypeHandle(t:AsIndexType():Target())
    elseif flags & TypeFlags.IndexedAccess ~= 0 then
        local data = t:AsIndexedAccessType()
        resp.objectType = api.TypeHandle(data:ObjectType())
        resp.indexType = api.TypeHandle(data:IndexType())
    elseif flags & TypeFlags.Conditional ~= 0 then
        local data = t:AsConditionalType()
        resp.checkType = api.TypeHandle(data:CheckType())
        resp.extendsType = api.TypeHandle(data:ExtendsType())
    elseif flags & TypeFlags.Substitution ~= 0 then
        local data = t:AsSubstitutionType()
        resp.baseType = api.TypeHandle(data:BaseType())
        resp.substConstraint = api.TypeHandle(data:SubstConstraint())
    elseif flags & TypeFlags.TemplateLiteral ~= 0 then
        local tl = t:AsTemplateLiteralType()
        resp.texts = tl:Texts()
        -- types omitted; fetched via separate request
    elseif flags & TypeFlags.StringMapping ~= 0 then
        resp.target = api.TypeHandle(t:AsStringMappingType():Target())
    elseif flags & TypeFlags.TypeParameter ~= 0 then
        resp.isThisType = t:AsTypeParameter():IsThisType()
    elseif flags & TypeFlags.Intrinsic ~= 0 then
        resp.intrinsicName = t:AsIntrinsicType():IntrinsicName()
    end

    return resp
end

function api.typeHandles(types)
    if core.Len(types) == 0 then
        return nil
    end
    local handles = {}
    for i, t in ipairs(types) do
        handles[i] = api.TypeHandle(t)
    end
    return handles
end

-- literalValueToJSON: Go switches on the dynamic type of the literal value (string,
-- jsnum.Number, bool, jsnum.PseudoBigInt).
function api.literalValueToJSON(value)
    local tv = type(value)
    if tv == "string" then
        return value
    elseif tv == "number" then
        return value + 0.0
    elseif tv == "boolean" then
        return value
    elseif tv == "table" and getmetatable(value) == jsnum.PseudoBigInt then
        -- Encode bigint literals as a signed decimal string (e.g. "-123"); the
        -- API client decodes this back into a real bigint. JSON has no bigint.
        return value:String()
    end
    return nil
end

api.defineStruct("SignatureResponse", {
    { "id", "SignatureID", "id" },
    { "flags", "uint32", "flags" },
    { "declaration", "NodeHandle", "declaration,omitempty" },
    { "typeParameters", "[]TypeID", "typeParameters,omitempty" },
    { "parameters", "[]SymbolID", "parameters,omitempty" },
    { "thisParameter", "SymbolID", "thisParameter,omitzero" },
    { "target", "SignatureID", "target,omitzero" },
})

api.defineStruct("GetSourceFileParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
})

api.defineStruct("GetSourceFileNamesParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
})

-- SourceFileMetadata carries program-stored metadata about a single source file.
api.defineStruct("SourceFileMetadata", {
    { "isDefaultLibrary", "bool", "isDefaultLibrary" },
    { "isFromExternalLibrary", "bool", "isFromExternalLibrary" },
    { "packageJsonType", "string", "packageJsonType" },
    { "packageJsonDirectory", "string", "packageJsonDirectory" },
    { "impliedNodeFormat", "core.ResolutionMode", "impliedNodeFormat" },
})

api.defineStruct("ResolveNameParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "name", "string", "name" },
    { "location", "NodeHandle", "location,omitempty" }, -- Optional: node handle for location context
    { "file", "*DocumentIdentifier", "file,omitempty" }, -- Optional: file for location context (alternative to Location)
    { "position", "*uint32", "position,omitempty" }, -- Optional: position in file for location context (with File)
    { "meaning", "uint32", "meaning" }, -- SymbolFlags for what kind of symbol to find
    { "excludeGlobals", "bool", "excludeGlobals,omitempty" }, -- Whether to exclude global symbols
})

-- GetSymbolsInScopeParams are parameters for getSymbolsInScope, which returns
-- all symbols visible at a given location.
api.defineStruct("GetSymbolsInScopeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location,omitempty" }, -- Optional: node handle for location context
    { "file", "*DocumentIdentifier", "file,omitempty" }, -- Optional: file for location context (alternative to Location)
    { "position", "*uint32", "position,omitempty" }, -- Optional: position in file for location context (with File)
    { "meaning", "uint32", "meaning" }, -- SymbolFlags for what kind of symbols to find
})

-- GetTypePropertyParams is used for all type sub-property endpoints.
api.defineStruct("GetTypePropertyParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "objectId" },
})

-- GetSymbolPropertyParams is used for all symbol sub-property endpoints.
api.defineStruct("GetSymbolPropertyParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "symbol", "SymbolID", "objectId" },
})

-- GetSignaturePropertyParams is used for all signature sub-property endpoints.
api.defineStruct("GetSignaturePropertyParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "signature", "SignatureID", "objectId" },
})

-- GetContextualTypeParams returns the contextual type for a node.
api.defineStruct("GetContextualTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location" },
})

-- GetTypeOfSymbolAtLocationParams returns the narrowed type of a symbol at a specific location.
api.defineStruct("GetTypeOfSymbolAtLocationParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "symbol", "SymbolID", "symbol" },
    { "location", "NodeHandle", "location" },
})

-- GetReferencesToSymbolInFileParams are the parameters for the getReferencesToSymbolInFile method.
api.defineStruct("GetReferencesToSymbolInFileParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "symbol", "SymbolID", "symbol" },
})

-- GetReferencedSymbolsForNodeParams are the parameters for the getReferencedSymbolsForNode method.
api.defineStruct("GetReferencedSymbolsForNodeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "node", "NodeHandle", "node" },
    { "position", "int", "position" },
})

-- ReferencedSymbolEntry represents a symbol definition and its references.
api.defineStruct("ReferencedSymbolEntry", {
    { "definition", "NodeHandle", "definition" },
    { "symbol", "*SymbolResponse", "symbol,omitempty" },
    { "references", "[]NodeHandle", "references" },
})

-- GetSignatureUsagesParams are the parameters for the getSignatureUsages method.
api.defineStruct("GetSignatureUsagesParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "signatureDecl", "NodeHandle", "signatureDecl" },
})

-- SignatureUsageResponse represents a single usage of a signature as a name-call pair.
api.defineStruct("SignatureUsageResponse", {
    { "name", "NodeHandle", "name" },
    { "call", "NodeHandle", "call,omitempty" },
})

-- GetCompletionsAtPositionParams are the parameters for the getCompletionsAtPosition method.
api.defineStruct("GetCompletionsAtPositionParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "position", "uint32", "position" },
    { "triggerCharacter", "*string", "triggerCharacter,omitempty" },
    { "includeSymbol", "bool", "includeSymbol,omitempty" },
})

-- CompletionEntryLabelDetailsResponse holds additional label display text for a completion entry.
api.defineStruct("CompletionEntryLabelDetailsResponse", {
    { "detail", "*string", "detail,omitempty" },
    { "description", "*string", "description,omitempty" },
})

-- CompletionEntryResponse represents a single completion item.
api.defineStruct("CompletionEntryResponse", {
    { "name", "string", "name" },
    { "kind", "uint32", "kind,omitempty" },
    { "sortText", "*string", "sortText,omitempty" },
    { "insertText", "*string", "insertText,omitempty" },
    { "filterText", "*string", "filterText,omitempty" },
    { "detail", "*string", "detail,omitempty" },
    { "labelDetails", "*CompletionEntryLabelDetailsResponse", "labelDetails,omitempty" },
    { "symbol", "*SymbolResponse", "symbol,omitempty" },
})

-- CompletionInfoResponse wraps a list of completion entries.
api.defineStruct("CompletionInfoResponse", {
    { "isIncomplete", "bool", "isIncomplete" },
    { "entries", "[]*CompletionEntryResponse", "entries" },
})

-- GetIntrinsicTypeParams is used for intrinsic type getters (anyType, stringType, etc.).
api.defineStruct("GetIntrinsicTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
})

-- WellKnownSymbolsResponse carries the handle ids of the per-checker singleton
-- symbols (unknown, undefined, arguments) so the client can identify them by id
-- without a round-trip on every check.
api.defineStruct("WellKnownSymbolsResponse", {
    { "unknown", "SymbolID", "unknown" },
    { "undefined", "SymbolID", "undefined" },
    { "arguments", "SymbolID", "arguments" },
})

-- WellKnownSignaturesResponse carries the handle id of the per-checker singleton
-- unknown signature (the signature the checker yields when a call cannot be
-- resolved) so the client can identify it by id without a round-trip on every check.
api.defineStruct("WellKnownSignaturesResponse", {
    { "unknown", "SignatureID", "unknown" },
})

-- GetBaseTypeOfLiteralTypeParams returns the base type of a literal type.
api.defineStruct("GetBaseTypeOfLiteralTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
})

-- GetNonNullableTypeParams are the parameters for the getNonNullableType method.
api.defineStruct("GetNonNullableTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
})

-- GetTypeFromTypeNodeParams are the parameters for the getTypeFromTypeNode method.
api.defineStruct("GetTypeFromTypeNodeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location" },
})

-- GetWidenedTypeParams are the parameters for the getWidenedType method.
api.defineStruct("GetWidenedTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
})

-- GetParameterTypeParams are the parameters for the getParameterType method.
api.defineStruct("GetParameterTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "signature", "SignatureID", "signature" },
    { "index", "int32", "index" },
})

-- IsArrayLikeTypeParams checks whether a type is array-like.
api.defineStruct("IsArrayLikeTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
})

-- IsTypeAssignableToParams checks assignability between two types.
api.defineStruct("IsTypeAssignableToParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "source", "TypeID", "source" },
    { "target", "TypeID", "target" },
})

api.defineStruct("GetSignaturesOfTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
    { "kind", "int32", "kind" },
})

api.defineStruct("GetResolvedSignatureParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location" },
})

api.defineStruct("GetTypeAtLocationParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location" },
})

api.defineStruct("GetTypeAtLocationsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "locations", "[]NodeHandle", "locations" },
})

api.defineStruct("GetTypeAtPositionParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "position", "uint32", "position" },
})

api.defineStruct("GetTypesAtPositionsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "positions", "[]uint32", "positions" },
})

api.defineStruct("ImportAdderAction", {
    { "kind", "ImportAdderActionKind", "kind" },
    { "symbol", "SymbolID", "symbol,omitempty" },
    { "isValidTypeOnlyUseSite", "*bool", "isValidTypeOnlyUseSite,omitempty" },
})

api.defineStruct("GetImportAdderEditsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" },
    { "actions", "[]ImportAdderAction", "actions" },
})

api.defineStruct("TextEdit", {
    { "pos", "int", "pos" },
    { "end_", "int", "end" },
    { "newText", "string", "newText" },
})

-- TypeToTypeNodeParams are the parameters for the typeToTypeNode method.
api.defineStruct("TypeToTypeNodeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
    { "location", "NodeHandle", "location,omitempty" },
    { "flags", "int32", "flags,omitempty" },
})

-- SignatureToSignatureDeclarationParams are the parameters for the signatureToSignatureDeclaration method.
api.defineStruct("SignatureToSignatureDeclarationParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "signature", "SignatureID", "signature" },
    { "kind", "int32", "kind" },
    { "location", "NodeHandle", "location,omitempty" },
    { "flags", "int32", "flags,omitempty" },
})

-- PrintNodeParams are the parameters for the printNode method.
api.defineStruct("PrintNodeParams", {
    { "data", "string", "data" }, -- base64-encoded binary AST data
    { "preserveSourceNewlines", "bool", "preserveSourceNewlines,omitempty" },
    { "neverAsciiEscape", "bool", "neverAsciiEscape,omitempty" },
    { "terminateUnterminatedLiterals", "bool", "terminateUnterminatedLiterals,omitempty" },
})

api.defineStruct("EmitParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "emitOnly", "*uint32", "emitOnly,omitempty" },
})

api.defineStruct("SelectedFilesEmitParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "files", "[]DocumentIdentifier", "files" },
})

api.defineStruct("EmitResponse", {
    { "emitSkipped", "bool", "emitSkipped" },
    { "diagnostics", "[]*DiagnosticResponse", "diagnostics" },
    { "emittedFiles", "[]string", "emittedFiles" },
})

api.defineStruct("EmitOutputFile", {
    { "fileName", "string", "fileName" },
    { "text", "string", "text" },
    { "sourceFileName", "*string", "sourceFileName,omitempty" },
})

api.defineStruct("EmitOutputResponse", {
    { "emitSkipped", "bool", "emitSkipped" },
    { "diagnostics", "[]*DiagnosticResponse", "diagnostics" },
    { "outputFiles", "[]*EmitOutputFile", "outputFiles" },
})

-- FormatNodeForInsertionParams are the parameters for the formatNodeForInsertion method.
api.defineStruct("FormatNodeForInsertionParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "file", "DocumentIdentifier", "file" }, -- target file where the node will be inserted
    { "position", "uint32", "position" }, -- UTF-16 code-unit offset of the insertion position in the target file
    { "data", "string", "data" }, -- base64-encoded binary AST data for the synthesized node
})

-- CheckerTypeParams are parameters for checker methods that operate on a type.
api.defineStruct("CheckerTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
})

-- GetPropertyOfTypeParams are parameters for getPropertyOfType (a named property of a type).
api.defineStruct("GetPropertyOfTypeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "type", "TypeID", "type" },
    { "name", "string", "name" },
})

-- GetMemberInModuleExportsParams are parameters for getMemberInModuleExports.
api.defineStruct("GetMemberInModuleExportsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "symbol", "SymbolID", "symbol" },
    { "name", "string", "name" },
})

-- CheckerNodeParams are parameters for checker methods that operate on a node location.
api.defineStruct("CheckerNodeParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "location", "NodeHandle", "location" },
})

-- CheckerSymbolParams are parameters for checker methods that operate on a symbol.
api.defineStruct("CheckerSymbolParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "symbol", "SymbolID", "symbol" },
})

-- JSDocTagInfo is a single JSDoc tag, mirroring Strada's JSDocTagInfo but with the tag text
-- rendered as a plain string rather than SymbolDisplayPart[].
api.defineStruct("JSDocTagInfo", {
    { "name", "string", "name" },
    { "text", "string", "text,omitempty" },
})

-- CheckerSignatureParams are parameters for checker methods that operate on a signature.
api.defineStruct("CheckerSignatureParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "signature", "SignatureID", "signature" },
})

-- TypePredicateResponse is the response for getTypePredicateOfSignature.
api.defineStruct("TypePredicateResponse", {
    { "kind", "int32", "kind" },
    { "parameterIndex", "int32", "parameterIndex" },
    { "parameterName", "string", "parameterName,omitempty" },
    { "type", "*TypeResponse", "type,omitempty" },
})

-- IndexInfoResponse represents a single index signature.
api.defineStruct("IndexInfoResponse", {
    { "keyType", "TypeResponse", "keyType" },
    { "valueType", "TypeResponse", "valueType" },
    { "isReadonly", "bool", "isReadonly,omitempty" },
    { "declaration", "NodeHandle", "declaration,omitempty" },
})

-- SourceFileResponse contains the binary-encoded AST data for a source file.
-- The Data field is base64-encoded binary data in the encoder's format.
api.defineStruct("SourceFileResponse", {
    -- Data is the base64-encoded binary AST data in the encoder's format.
    { "data", "string", "data" },
})

-- GetDiagnosticsParams are parameters for per-file diagnostic methods.
api.defineStruct("GetDiagnosticsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
    { "files", "[]DocumentIdentifier", "files,omitempty" },
})

-- GetProjectDiagnosticsParams are parameters for project-wide diagnostic methods.
api.defineStruct("GetProjectDiagnosticsParams", {
    { "snapshot", "SnapshotID", "snapshot" },
    { "project", "ProjectID", "project" },
})

-- NewDiagnosticResponse converts an ast.Diagnostic to a DiagnosticResponse.
function api.NewDiagnosticResponse(d)
    local pos = d:Pos()
    local end_ = d:End()
    local file = d:File()
    if file ~= nil then
        local positionMap = file:GetPositionMap()
        pos = positionMap:UTF8ToUTF16(pos)
        end_ = positionMap:UTF8ToUTF16(end_)
    end
    local resp = setmetatable({
        fileName = "",
        pos = pos,
        end_ = end_,
        code = d:Code(),
        category = d:Category(),
        text = d:Localize(locale.Default),
        reportsUnnecessary = d:ReportsUnnecessary(),
        reportsDeprecated = d:ReportsDeprecated(),
    }, api.DiagnosticResponse)

    if file ~= nil then
        resp.fileName = file:FileName()
    end

    local chain = d:MessageChain()
    if core.Len(chain) > 0 then
        resp.messageChain = {}
        for i, c in ipairs(chain) do
            resp.messageChain[i] = api.NewDiagnosticResponse(c)
        end
    end

    local related = d:RelatedInformation()
    if core.Len(related) > 0 then
        resp.relatedInformation = {}
        for i, r in ipairs(related) do
            resp.relatedInformation[i] = api.NewDiagnosticResponse(r)
        end
    end

    return resp
end

-- NewDiagnosticResponses converts a slice of ast.Diagnostics to DiagnosticResponses.
function api.NewDiagnosticResponses(diags)
    if core.Len(diags) == 0 then
        return nil
    end
    local result = {}
    for i, d in ipairs(diags) do
        result[i] = api.NewDiagnosticResponse(d)
    end
    return result
end

-- unmarshalers maps each method to the Go type its params decode into ("" = noParams).
api.unmarshalers = {
    [Method.Release] = "ReleaseParams",
    [Method.Initialize] = "",
    [Method.UpdateSnapshot] = "UpdateSnapshotParams",
    [Method.UpdateTemporarySnapshot] = "UpdateTemporarySnapshotParams",
    [Method.ParseCommandLine] = "ParseCommandLineParams",
    [Method.ReadConfigFile] = "ReadConfigFileParams",
    [Method.ParseJsonConfigFile] = "ParseJsonConfigFileContentParams",
    [Method.ParseConfigFile] = "ParseConfigFileParams",
    [Method.TranspileModule] = "TranspileParams",
    [Method.TranspileModuleFromFile] = "TranspileFromFileParams",
    [Method.TranspileDeclaration] = "TranspileParams",
    [Method.TranspileDeclarationFromFile] = "TranspileFromFileParams",
    [Method.GetDefaultProjectForFile] = "GetDefaultProjectForFileParams",
    [Method.GetSourceFile] = "GetSourceFileParams",
    [Method.GetSourceFileNames] = "GetSourceFileNamesParams",
    [Method.GetSourceFileMetadata] = "GetSourceFileParams",
    [Method.GetConfigFileNames] = "GetProjectDiagnosticsParams",
    [Method.GetConfigSourceFile] = "GetSourceFileParams",
    [Method.GetSymbolAtPosition] = "GetSymbolAtPositionParams",
    [Method.GetSymbolsAtPositions] = "GetSymbolsAtPositionsParams",
    [Method.GetSymbolAtLocation] = "GetSymbolAtLocationParams",
    [Method.GetSymbolsAtLocations] = "GetSymbolsAtLocationsParams",
    [Method.GetSymbolOfSourceFile] = "GetSymbolOfSourceFileParams",
    [Method.GetSymbolsOfSourceFiles] = "GetSymbolsOfSourceFilesParams",
    [Method.GetTypeOfSymbol] = "GetTypeOfSymbolParams",
    [Method.GetTypesOfSymbols] = "GetTypesOfSymbolsParams",
    [Method.GetDeclaredTypeOfSymbol] = "GetTypeOfSymbolParams",
    [Method.ResolveName] = "ResolveNameParams",
    [Method.GetSymbolsInScope] = "GetSymbolsInScopeParams",
    [Method.GetSignaturesOfType] = "GetSignaturesOfTypeParams",
    [Method.GetResolvedSignature] = "GetResolvedSignatureParams",
    [Method.GetTypeAtLocation] = "GetTypeAtLocationParams",
    [Method.GetTypeAtLocations] = "GetTypeAtLocationsParams",
    [Method.GetTypeAtPosition] = "GetTypeAtPositionParams",
    [Method.GetTypesAtPositions] = "GetTypesAtPositionsParams",

    [Method.GetParentOfSymbol] = "GetSymbolPropertyParams",
    [Method.GetMembersOfSymbol] = "GetSymbolPropertyParams",
    [Method.GetExportsOfSymbol] = "GetSymbolPropertyParams",
    [Method.GetExportSymbolOfSymbol] = "GetSymbolPropertyParams",

    [Method.GetSymbolOfType] = "GetTypePropertyParams",
    [Method.GetTargetOfType] = "GetTypePropertyParams",
    [Method.GetFreshTypeOfType] = "GetTypePropertyParams",
    [Method.GetRegularTypeOfType] = "GetTypePropertyParams",
    [Method.GetTypesOfType] = "GetTypePropertyParams",
    [Method.GetTypeParametersOfType] = "GetTypePropertyParams",
    [Method.GetOuterTypeParametersOfType] = "GetTypePropertyParams",
    [Method.GetLocalTypeParametersOfType] = "GetTypePropertyParams",
    [Method.GetAliasTypeArgumentsOfType] = "GetTypePropertyParams",
    [Method.GetAliasSymbolOfType] = "GetTypePropertyParams",
    [Method.GetObjectTypeOfType] = "GetTypePropertyParams",
    [Method.GetIndexTypeOfType] = "GetTypePropertyParams",
    [Method.GetCheckTypeOfType] = "GetTypePropertyParams",
    [Method.GetExtendsTypeOfType] = "GetTypePropertyParams",
    [Method.GetBaseTypeOfType] = "GetTypePropertyParams",
    [Method.GetConstraintOfType] = "GetTypePropertyParams",
    [Method.GetTrueTypeOfConditionalType] = "GetTypePropertyParams",
    [Method.GetFalseTypeOfConditionalType] = "GetTypePropertyParams",

    [Method.GetTypeParametersOfSignature] = "GetSignaturePropertyParams",
    [Method.GetParametersOfSignature] = "GetSignaturePropertyParams",
    [Method.GetThisParameterOfSignature] = "GetSignaturePropertyParams",
    [Method.GetTargetOfSignature] = "GetSignaturePropertyParams",

    [Method.GetContextualType] = "GetContextualTypeParams",
    [Method.GetBaseTypeOfLiteralType] = "GetBaseTypeOfLiteralTypeParams",
    [Method.GetNonNullableType] = "GetTypePropertyParams",
    [Method.GetTypeFromTypeNode] = "GetTypeFromTypeNodeParams",
    [Method.GetWidenedType] = "GetWidenedTypeParams",
    [Method.GetParameterType] = "GetParameterTypeParams",
    [Method.GetTypeParameterAtPosition] = "GetParameterTypeParams",
    [Method.IsArrayLikeType] = "IsArrayLikeTypeParams",
    [Method.IsTypeAssignableTo] = "IsTypeAssignableToParams",
    [Method.GetShorthandAssignmentValueSymbol] = "GetTypeAtLocationParams",
    [Method.GetTypeOfSymbolAtLocation] = "GetTypeOfSymbolAtLocationParams",
    [Method.TypeToTypeNode] = "TypeToTypeNodeParams",
    [Method.SignatureToSignatureDeclaration] = "SignatureToSignatureDeclarationParams",
    [Method.TypeToString] = "TypeToTypeNodeParams",
    [Method.IsContextSensitive] = "GetContextualTypeParams",
    [Method.GetReturnTypeOfSignature] = "GetSignaturePropertyParams",
    [Method.GetRestTypeOfSignature] = "CheckerSignatureParams",
    [Method.GetTypePredicateOfSignature] = "CheckerSignatureParams",
    [Method.GetBaseTypes] = "CheckerTypeParams",
    [Method.GetPropertiesOfType] = "CheckerTypeParams",
    [Method.GetApparentPropertiesOfType] = "GetTypePropertyParams",
    [Method.GetApparentType] = "GetTypePropertyParams",
    [Method.GetPropertyOfType] = "GetPropertyOfTypeParams",
    [Method.GetIndexInfosOfType] = "CheckerTypeParams",
    [Method.GetConstraintOfTypeParameter] = "GetTypePropertyParams",
    [Method.GetBaseConstraintOfType] = "CheckerTypeParams",
    [Method.GetDefaultFromTypeParameter] = "GetTypePropertyParams",
    [Method.GetTypeArguments] = "CheckerTypeParams",
    [Method.GetImportAdderEdits] = "GetImportAdderEditsParams",
    [Method.GetConstantValue] = "CheckerNodeParams",
    [Method.GetSignatureFromDeclaration] = "CheckerNodeParams",
    [Method.GetExportSpecifierLocalTarget] = "CheckerNodeParams",
    [Method.GetAliasedSymbol] = "CheckerSymbolParams",
    [Method.GetImmediateAliasedSymbol] = "CheckerSymbolParams",
    [Method.GetFullyQualifiedName] = "CheckerSymbolParams",
    [Method.GetExportsOfModule] = "CheckerSymbolParams",
    [Method.GetMemberInModuleExports] = "GetMemberInModuleExportsParams",
    [Method.GetJSDocTags] = "CheckerSymbolParams",
    [Method.GetDocumentationComment] = "CheckerSymbolParams",
    [Method.IsArrayType] = "CheckerTypeParams",
    [Method.IsTupleType] = "CheckerTypeParams",
    [Method.GetReferencesToSymbolInFile] = "GetReferencesToSymbolInFileParams",
    [Method.GetReferencedSymbolsForNode] = "GetReferencedSymbolsForNodeParams",
    [Method.GetSignatureUsages] = "GetSignatureUsagesParams",
    [Method.GetCompletionsAtPosition] = "GetCompletionsAtPositionParams",
    [Method.PrintNode] = "PrintNodeParams",
    [Method.FormatNodeForInsertion] = "FormatNodeForInsertionParams",
    [Method.Emit] = "EmitParams",
    [Method.EmitToString] = "EmitParams",
    [Method.GetJavaScriptEmit] = "SelectedFilesEmitParams",
    [Method.GetDeclarationEmit] = "SelectedFilesEmitParams",
    [Method.GetAnyType] = "GetIntrinsicTypeParams",
    [Method.GetStringType] = "GetIntrinsicTypeParams",
    [Method.GetNumberType] = "GetIntrinsicTypeParams",
    [Method.GetBooleanType] = "GetIntrinsicTypeParams",
    [Method.GetVoidType] = "GetIntrinsicTypeParams",
    [Method.GetUndefinedType] = "GetIntrinsicTypeParams",
    [Method.GetNullType] = "GetIntrinsicTypeParams",
    [Method.GetNeverType] = "GetIntrinsicTypeParams",
    [Method.GetUnknownType] = "GetIntrinsicTypeParams",
    [Method.GetBigIntType] = "GetIntrinsicTypeParams",
    [Method.GetESSymbolType] = "GetIntrinsicTypeParams",
    [Method.GetNonPrimitiveType] = "GetIntrinsicTypeParams",
    [Method.GetWellKnownSymbols] = "GetIntrinsicTypeParams",
    [Method.GetWellKnownSignatures] = "GetIntrinsicTypeParams",
    [Method.GetSyntacticDiagnostics] = "GetDiagnosticsParams",
    [Method.GetBindDiagnostics] = "GetDiagnosticsParams",
    [Method.GetSemanticDiagnostics] = "GetDiagnosticsParams",
    [Method.GetSuggestionDiagnostics] = "GetDiagnosticsParams",
    [Method.GetDeclarationDiagnostics] = "GetDiagnosticsParams",
    [Method.GetProgramDiagnostics] = "GetProjectDiagnosticsParams",
    [Method.GetGlobalDiagnostics] = "GetProjectDiagnosticsParams",
    [Method.GetConfigFileParsingDiagnostics] = "GetProjectDiagnosticsParams",
    [Method.StartCPUProfile] = "ProfileParams",
    [Method.StopCPUProfile] = "",
    [Method.SaveHeapProfile] = "ProfileParams",
}

-- unmarshalPayload decodes params (a jsonrpc.Value or nil) for the method. Returns (value, err).
function api.unmarshalPayload(method, payload)
    local typeName = api.unmarshalers[method]
    if typeName == nil then
        return nil, "unknown API method " .. json.QuoteString(method)
    end
    if typeName == "" then
        return api.noParams(payload)
    end
    return api.unmarshallerFor(typeName, payload)
end

function api.unmarshallerFor(typeName, data)
    local raw = ""
    if data ~= nil then
        raw = data.data
    end
    local v, err = api.UnmarshalAs(typeName, raw)
    if err ~= nil then
        return nil, jsonrpc.NewError("failed to unmarshal *api." .. typeName .. ": " .. jsonrpc.ErrorString(err), err)
    end
    return v, nil
end

function api.noParams(data)
    return nil, nil
end
