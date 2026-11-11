local module = require("tslua.module")
local tspath = require("tslua.tspath")

-- ResolutionHost interface: host:FS() (vfs.FS), host:GetCurrentDirectory().
-- ResolvedProjectReference interface: ref:ConfigName(), ref:CompilerOptions().

-- ModeAwareCacheKey { name, mode } is used as a table key through module.ModeAwareCacheKeyString.
function module.ModeAwareCacheKeyString(name, mode)
    return tostring(mode) .. "|" .. name
end

local PackageId = {}
PackageId.__index = PackageId
module.PackageId = PackageId

function module.NewPackageId(name, subModuleName, version, peerDependencies)
    return setmetatable({
        name = name or "",
        subModuleName = subModuleName or "",
        version = version or "",
        peerDependencies = peerDependencies or "",
    }, PackageId)
end

function PackageId:String()
    return self:PackageName() .. "@" .. self.version .. self.peerDependencies
end

function PackageId:PackageName()
    if self.subModuleName ~= "" then
        return self.name .. "/" .. self.subModuleName
    end
    return self.name
end

local ResolvedModule = {}
ResolvedModule.__index = ResolvedModule
module.ResolvedModule = ResolvedModule

function module.NewResolvedModule()
    return setmetatable({
        resolutionDiagnostics = nil,
        resolvedFileName = "",
        originalPath = "",
        extension = "",
        resolvedUsingTsExtension = false,
        resolvedUsingExtraExtensions = false,
        packageId = module.NewPackageId(),
        isExternalLibraryImport = false,
        alternateResult = "",
    }, ResolvedModule)
end

-- Call as module.ResolvedModule.IsResolved(r) when r may be nil.
function ResolvedModule:IsResolved()
    return self ~= nil and self.resolvedFileName ~= ""
end

local ResolvedTypeReferenceDirective = {}
ResolvedTypeReferenceDirective.__index = ResolvedTypeReferenceDirective
module.ResolvedTypeReferenceDirective = ResolvedTypeReferenceDirective

function module.NewResolvedTypeReferenceDirective()
    return setmetatable({
        resolutionDiagnostics = nil,
        primary = false,
        resolvedFileName = "",
        originalPath = "",
        packageId = module.NewPackageId(),
        isExternalLibraryImport = false,
    }, ResolvedTypeReferenceDirective)
end

function ResolvedTypeReferenceDirective:IsResolved()
    return self.resolvedFileName ~= ""
end

-- extensions (unexported Go flags type, not in the generated constants)
module.extensionsTypeScript = 1 << 0
module.extensionsJavaScript = 1 << 1
module.extensionsDeclaration = 1 << 2
module.extensionsJson = 1 << 3
module.extensionsImplementationFiles = module.extensionsTypeScript | module.extensionsJavaScript

function module.extensions_String(e)
    local result = {}
    if e & module.extensionsTypeScript ~= 0 then
        result[#result + 1] = "TypeScript"
    end
    if e & module.extensionsJavaScript ~= 0 then
        result[#result + 1] = "JavaScript"
    end
    if e & module.extensionsDeclaration ~= 0 then
        result[#result + 1] = "Declaration"
    end
    if e & module.extensionsJson ~= 0 then
        result[#result + 1] = "JSON"
    end
    return table.concat(result, ", ")
end

function module.extensions_Array(e)
    local result = {}
    local function appendAll(xs)
        for _, x in ipairs(xs) do
            result[#result + 1] = x
        end
    end
    if e & module.extensionsTypeScript ~= 0 then
        appendAll(tspath.SupportedTSImplementationExtensions)
    end
    if e & module.extensionsJavaScript ~= 0 then
        appendAll(tspath.SupportedJSExtensionsFlat)
    end
    if e & module.extensionsDeclaration ~= 0 then
        appendAll(tspath.SupportedDeclarationExtensions)
    end
    if e & module.extensionsJson ~= 0 then
        result[#result + 1] = tspath.ExtensionJson
    end
    return result
end
