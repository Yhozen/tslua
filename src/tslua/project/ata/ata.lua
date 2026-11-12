local ata = require("tslua.project.ata")
local core = require("tslua.core")
local collections = require("tslua.collections")

-- TypingsInfo: { typeAcquisition, compilerOptions, unresolvedImports (collections.Set) }
local TypingsInfo = {}
TypingsInfo.__index = TypingsInfo
ata.TypingsInfo = TypingsInfo

function ata.NewTypingsInfo(fields)
    return setmetatable({
        typeAcquisition = fields.typeAcquisition,
        compilerOptions = fields.compilerOptions,
        unresolvedImports = fields.unresolvedImports,
    }, TypingsInfo)
end

function TypingsInfo:Equals(other)
    return core.TypeAcquisition.Equals(self.typeAcquisition, other.typeAcquisition) and
        self.compilerOptions:GetAllowJS() == other.compilerOptions:GetAllowJS() and
        collections.Set.Equals(self.unresolvedImports, other.unresolvedImports)
end

-- TypingsInstallerOptions: { typingsLocation, throttleLimit }
-- NpmExecutor: { NpmInstall(cwd, args) -> (output, error) }
-- TypingsInstallRequest: { projectID, typingsInfo, fileNames, projectRootPath, compilerOptions,
--   currentDirectory, getScriptKind, fs, logger }
-- TypingsInstallResult: { typingsFiles, filesToWatch }

local TypingsInstaller = {}
TypingsInstaller.__index = TypingsInstaller
ata.TypingsInstaller = TypingsInstaller

function ata.NewTypingsInstaller(options, host)
    return setmetatable({
        typingsLocation = options.typingsLocation,
        host = host,
    }, TypingsInstaller)
end

local errNotSupported = {}
errNotSupported.__index = errNotSupported

function errNotSupported:Error()
    return "automatic type acquisition is not supported"
end

ata.ErrNotSupported = setmetatable({}, errNotSupported)

-- InstallTypings never installs typings in the Lua port: it reports ErrNotSupported, which the
-- session logs like any other installation failure.
function TypingsInstaller:InstallTypings(request)
    return nil, ata.ErrNotSupported
end
