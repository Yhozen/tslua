local build = require("tslua.execute.build")

-- upToDateStatusType (unexported Go enum, values in iota order). Times are numbers (seconds);
-- the zero time is 0.
local upToDateStatusType = {
    -- Errors:

    -- config file was not found
    ConfigFileNotFound = 0,
    -- found errors during build
    BuildErrors = 1,
    -- did not build because upstream project has errors - and we have option to stop build on upstream errors
    UpstreamErrors = 2,

    -- Its all good, no work to do
    UpToDate = 3,

    -- Pseudo-builds - touch timestamps, no actual build:

    -- The project appears out of date because its upstream inputs are newer than its outputs,
    -- but all of its outputs are actually newer than the previous identical outputs of its (.d.ts) inputs.
    -- This means we can Pseudo-build (just touch timestamps), as if we had actually built this project.
    UpToDateWithUpstreamTypes = 4,
    -- The project appears up to date and even though input file changed, its text didnt so just need to update timestamps
    UpToDateWithInputFileText = 5,

    -- Needs build:

    -- input file is missing
    InputFileMissing = 6,
    -- output file is missing
    OutputMissing = 7,
    -- input file is newer than output file
    InputFileNewer = 8,
    -- build info is out of date as we need to emit some files
    OutOfDateBuildInfoWithPendingEmit = 9,
    -- build info indicates that project has errors and they need to be reported
    OutOfDateBuildInfoWithErrors = 10,
    -- build info options indicate there is work to do based on changes in options
    OutOfDateOptions = 11,
    -- file was root when built but not any more
    OutOfDateRoots = 12,
    -- buildInfo.version mismatch with current ts version
    TsVersionOutputOfDate = 13,
    -- build because --force was specified
    ForceBuild = 14,

    -- solution file
    Solution = 15,
}
build.upToDateStatusType = upToDateStatusType

-- The data of an upToDateStatus is a string, or one of the tables below; `dataKind` tells them
-- apart (Go uses a type switch on `any`).

-- inputOutputName: { input = string, output = string }
function build.newInputOutputName(input, output)
    return { dataKind = "inputOutputName", input = input, output = output }
end

-- fileAndTime: { file = string, time = number } (a Go value struct)
function build.newFileAndTime(file, time)
    return { file = file or "", time = time or 0 }
end

-- inputOutputFileAndTime: { input = fileAndTime, output = fileAndTime, buildInfo = string }
function build.newInputOutputFileAndTime(input, output, buildInfo)
    return { dataKind = "inputOutputFileAndTime", input = input, output = output, buildInfo = buildInfo }
end

-- upstreamErrors: { ref = string, refHasUpstreamErrors = bool }
function build.newUpstreamErrors(ref, refHasUpstreamErrors)
    return { dataKind = "upstreamErrors", ref = ref, refHasUpstreamErrors = refHasUpstreamErrors }
end

local upToDateStatus = {}
upToDateStatus.__index = upToDateStatus
build.upToDateStatus = upToDateStatus

-- upToDateStatus: { kind = upToDateStatusType, data = any }
function build.newUpToDateStatus(kind, data)
    return setmetatable({ kind = kind, data = data }, upToDateStatus)
end

function upToDateStatus:isError()
    local k = self.kind
    if k == upToDateStatusType.ConfigFileNotFound or
        k == upToDateStatusType.BuildErrors or
        k == upToDateStatusType.UpstreamErrors then
        return true
    end
    return false
end

function upToDateStatus:isPseudoBuild()
    local k = self.kind
    if k == upToDateStatusType.UpToDateWithUpstreamTypes or
        k == upToDateStatusType.UpToDateWithInputFileText then
        return true
    end
    return false
end

function upToDateStatus:inputOutputFileAndTime()
    local data = self.data
    if type(data) ~= "table" or data.dataKind ~= "inputOutputFileAndTime" then
        return nil
    end
    return data
end

function upToDateStatus:inputOutputName()
    local data = self.data
    if type(data) ~= "table" or data.dataKind ~= "inputOutputName" then
        return nil
    end
    return data
end

function upToDateStatus:oldestOutputFileName()
    if not self:isPseudoBuild() and self.kind ~= upToDateStatusType.UpToDate then
        error("only valid for up to date status of pseudo-build or up to date", 0)
    end

    local inputOutputFileAndTime = self:inputOutputFileAndTime()
    if inputOutputFileAndTime ~= nil then
        return inputOutputFileAndTime.output.file
    end
    local inputOutputName = self:inputOutputName()
    if inputOutputName ~= nil then
        return inputOutputName.output
    end
    if type(self.data) ~= "string" then
        error("interface conversion: interface {} is " .. type(self.data) .. ", not string", 0)
    end
    return self.data
end

function upToDateStatus:upstreamErrors()
    return self.data
end
