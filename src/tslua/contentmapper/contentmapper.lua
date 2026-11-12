-- Package contentmapper defines the types describing an external content mapper: a plugin that
-- transforms otherwise unsupported file content (e.g. .vue) into virtual TypeScript during program construction.
--
-- A mapper is declared in tsconfig (Definition), its implementation is described by fields in its npm
-- package's package.json (Manifest), and the two are combined once the package is resolved (Mapper).
-- Resolution itself lives in the tsoptions package (it needs node module resolution).
--
-- The package also drives the configured content mappers at build time (Host): it spawns each mapper's
-- package as a child process and talks to it over a JSON-RPC connection (reusing internal/ipc), turning
-- content-mapped source files into virtual TypeScript. Processes are consolidated by mapper identity, so many projects
-- that use the same mapper version share a single process.
--
-- Errors follow the tslua.jsonrpc conventions (tables with Error(); wrapped errors in `unwrap`); the
-- typed Go errors of this package are tables whose metatable is the Go type, matched with
-- contentmapper.ErrorsAsType(err, contentmapper.TransformError) for errors.AsType.
local contentmapper = require("tslua.contentmapper")
local collections = require("tslua.collections")
local core = require("tslua.core")
local json = require("tslua.json")
local jsonrpc = require("tslua.jsonrpc")
local xxh3 = require("tslua.xxh3")

contentmapper.ErrProjectUnavailable = jsonrpc.NewError("content mapper project is unavailable")

-- ErrorsAsType is errors.AsType[*T](err) for a typed error whose metatable is T. Returns (value, ok).
function contentmapper.ErrorsAsType(err, T)
    local found = jsonrpc.ErrorsFind(err, function(e)
        return type(e) == "table" and getmetatable(e) == T
    end)
    return found, found ~= nil
end

-- Definition is a content mapper as declared in a tsconfig's "contentMappers": the npm package that
-- implements the mapper and the otherwise unsupported file extensions it registers.
--   { package = string, extensions = []string, options = raw JSON text (json.Value; nil or "" when absent) }

-- Manifest is the content-mapper information read from a package's package.json: its name and version
-- (which form the mapper's identity), the argv used to run it, and the compiler options it declares it
-- depends on.
--   { name = string, version = string, exec = []string, compilerOptions = []string, dynamicConfig = bool }
function contentmapper.NewManifest(t)
    t = t or {}
    return {
        name = t.name or "",
        version = t.version or "",
        exec = t.exec,
        compilerOptions = t.compilerOptions,
        dynamicConfig = t.dynamicConfig or false,
    }
end

-- Mapper is a resolved content mapper: its tsconfig Definition combined with the Manifest resolved from
-- the package's package.json, plus the package directory used as the mapper's working directory.
-- Both embedded structs are flattened onto the Mapper table:
--   package, extensions, options (Definition); name, version, exec, compilerOptions, dynamicConfig
--   (Manifest); packageDirectory; contributionID (provided by an LSP client extension for inferred
--   project content mappers).
local Mapper = {}
Mapper.__index = Mapper
contentmapper.Mapper = Mapper

-- NewMapper is the Go struct literal &contentmapper.Mapper{...}: omitted fields take their zero value.
function contentmapper.NewMapper(t)
    t = t or {}
    return setmetatable({
        package = t.package or "",
        extensions = t.extensions,
        options = t.options,
        name = t.name or "",
        version = t.version or "",
        exec = t.exec,
        compilerOptions = t.compilerOptions,
        dynamicConfig = t.dynamicConfig or false,
        packageDirectory = t.packageDirectory or "",
        contributionID = t.contributionID or "",
    }, Mapper)
end

-- SetManifest is the Go assignment mapper.Manifest = manifest.
function Mapper:SetManifest(manifest)
    self.name = manifest.name or ""
    self.version = manifest.version or ""
    self.exec = manifest.exec
    self.compilerOptions = manifest.compilerOptions
    self.dynamicConfig = manifest.dynamicConfig or false
end

-- Manifest returns the embedded Manifest value.
function Mapper:Manifest()
    return contentmapper.NewManifest(self)
end

-- MarshalJSON marshals the embedded Definition (the Manifest and the other fields are `json:"-"`).
function Mapper:MarshalJSON()
    local b = contentmapper.codec.NewObject()
    b:String("package", self.package)
    b:Array("extensions", self.extensions, contentmapper.codec.EncodeString)
    if self.options ~= nil and self.options ~= "" then
        b:Raw("options", self.options)
    end
    return b:Result()
end

contentmapper.supportedVirtualExtensions = collections.NewSetFromItems(
    ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".json"
)

function contentmapper.IsSupportedVirtualExtension(extension)
    return contentmapper.supportedVirtualExtensions:Has(extension)
end

-- DiagnosticName returns the best available user-facing name, including when manifest resolution failed.
function Mapper:DiagnosticName()
    if self.name ~= "" then
        return self.name
    elseif self.package ~= "" then
        return self.package
    end
    return self.contributionID
end

-- Identity returns the mapper's "name@version" identity, or just the name when it declares no version,
-- or an empty string when the mapper has not been resolved to a name.
function Mapper:Identity()
    if self.contributionID ~= "" then
        return self.contributionID .. " (" .. self:manifestIdentity() .. ")"
    end
    return self:manifestIdentity()
end

function Mapper:manifestIdentity()
    if self.name == "" then
        return ""
    elseif self.version == "" then
        return self.name
    end
    return self.name .. "@" .. self.version
end

-- TransformIdentity returns a fingerprint of everything besides a file's content that determines the
-- output of transforming it with this mapper under the given options: the mapper's identity and the
-- values of the compiler options it declared it depends on. Folding it into a cache key means a change to
-- the mapper version or a relevant compiler option invalidates cached results. It is a pure function of
-- the mapper and options — the declared options come from the manifest, so it never starts the mapper
-- process. Returns an xxh3.Uint128.
function Mapper:TransformIdentity(options)
    local declared = self:MarshalDeclaredOptions(options)
    local optionsJSON = json.Marshal(declared) or ""
    local buf = { self:Identity(), "\0", self.options or "", "\0", optionsJSON }
    return xxh3.Hash128(table.concat(buf))
end

-- MarshalDeclaredOptions marshals just the compiler options this mapper declared it depends on, in the
-- declared order, skipping any that are unset. Marshaling only the declared fields avoids serializing the
-- whole CompilerOptions when a mapper depends on few options (or none).
-- Returns (*collections.OrderedMap[string, json.Value] with jsonrpc.Value values, err).
function Mapper:MarshalDeclaredOptions(options)
    local out = collections.NewOrderedMapWithSizeHint(core.Len(self.compilerOptions))
    if options == nil or core.Len(self.compilerOptions) == 0 then
        return out, nil
    end
    local fields = contentmapper.compilerOptionFields()
    for _, name in ipairs(self.compilerOptions) do
        local field = fields[name]
        if field ~= nil then
            local v = options[field.name]
            local isZero = v == nil or v == field.zero
            if not isZero then
                local raw, err
                if field.kind == "tristate" then
                    raw, err = core.Tristate_MarshalJSON(v)
                elseif field.kind == "string" then
                    raw = json.QuoteString(v)
                else
                    raw, err = json.Marshal(v)
                end
                if err ~= nil then
                    return nil, err
                end
                out:Set(name, jsonrpc.NewValue(raw))
            end
        end
    end
    return out, nil
end

-- compilerOptionFields maps each CompilerOptions option name (its json tag) to its field descriptor
-- (core.CompilerOptions.Fields entry).
function contentmapper.compilerOptionFields()
    if contentmapper.compilerOptionFieldsValue == nil then
        local fields = {}
        for _, field in ipairs(core.CompilerOptions.Fields) do
            local name = field.json
            if name ~= nil and name ~= "" and name ~= "-" then
                fields[name] = field
            end
        end
        contentmapper.compilerOptionFieldsValue = fields
    end
    return contentmapper.compilerOptionFieldsValue
end
