local incremental = require("tslua.execute.incremental")

-- BuildInfoReader interface: ReadBuildInfo(config) -> *BuildInfo.
local buildInfoReader = {}
buildInfoReader.__index = buildInfoReader
incremental.buildInfoReader = buildInfoReader

function buildInfoReader:ReadBuildInfo(config)
    local buildInfoFileName = config:GetBuildInfoFileName()
    if buildInfoFileName == "" then
        return nil
    end

    -- Read build info file
    local data, ok = self.host:FS():ReadFile(buildInfoFileName)
    if not ok then
        return nil
    end
    local buildInfo, err = incremental.UnmarshalBuildInfo(data)
    if err ~= nil then
        return nil
    end
    return buildInfo
end

function incremental.NewBuildInfoReader(host)
    return setmetatable({ host = host }, buildInfoReader)
end

function incremental.ReadBuildInfoProgram(config, reader, host)
    -- Read buildInfo file
    local buildInfo = reader:ReadBuildInfo(config)
    if buildInfo == nil or not buildInfo:IsValidVersion() or not buildInfo:IsIncremental() then
        return nil
    end
    -- If any configured content mapper's identity has changed, files it produced may be stale, so the
    -- old program cannot be reused.
    local contentMapperIdentities, err = incremental.ContentMapperIdentities(host:ContentMapperProject())
    if err ~= nil or not buildInfo:ContentMapperIdentitiesMatch(contentMapperIdentities) then
        return nil
    end

    -- Convert to information that can be used to create incremental program
    local incrementalProgram = incremental.newProgramStruct({
        snapshot = incremental.buildInfoToSnapshot(buildInfo, config, host),
    })
    return incrementalProgram
end
