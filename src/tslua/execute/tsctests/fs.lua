local tsctests = require("tslua.execute.tsctests")
local collections = require("tslua.collections")
local core = require("tslua.core")
local fsbaselineutil = require("tslua.testutil.fsbaselineutil")
local harnessutil = require("tslua.testutil.harnessutil")
local tspath = require("tslua.tspath")

-- testFs embeds vfs.FS (field fs); defaultLibs is a SyncSet or nil, writtenFiles a SyncSet.
local testFs = {}
testFs.__index = testFs
tsctests.testFs = testFs

function tsctests.newTestFs(fs)
    return setmetatable({
        fs = fs,
        defaultLibs = nil,
        writtenFiles = collections.NewSyncSet(),
    }, testFs)
end

-- Go json.Unmarshal(contents, &buildInfo) / json.Marshal(&buildInfo) on incremental.BuildInfo.
function tsctests.unmarshalBuildInfo(contents)
    local incremental = require("tslua.execute.incremental")
    return incremental.UnmarshalBuildInfo(contents)
end

function tsctests.marshalBuildInfo(buildInfo)
    local json = require("tslua.json")
    return json.Marshal(buildInfo)
end

-- Embedded vfs.FS methods.
function testFs:UseCaseSensitiveFileNames()
    return self.fs:UseCaseSensitiveFileNames()
end

function testFs:FileExists(path)
    return self.fs:FileExists(path)
end

function testFs:AppendFile(path, data)
    return self.fs:AppendFile(path, data)
end

function testFs:Chtimes(path, aTime, mTime)
    return self.fs:Chtimes(path, aTime, mTime)
end

function testFs:DirectoryExists(path)
    return self.fs:DirectoryExists(path)
end

function testFs:GetAccessibleEntries(path)
    return self.fs:GetAccessibleEntries(path)
end

function testFs:Stat(path)
    return self.fs:Stat(path)
end

function testFs:WalkDir(root, walkFn)
    return self.fs:WalkDir(root, walkFn)
end

function testFs:Realpath(path)
    return self.fs:Realpath(path)
end

function testFs:removeIgnoreLibPath(path)
    if self.defaultLibs ~= nil and self.defaultLibs:Has(path) then
        self.defaultLibs:Delete(path)
    end
end

-- ReadFile reads the file specified by path and returns the content.
-- If the file fails to be read, ok will be false.
function testFs:ReadFile(path)
    self:removeIgnoreLibPath(path)
    return self:readFileHandlingBuildInfo(path)
end

function testFs:readFileHandlingBuildInfo(path)
    local contents, ok = self.fs:ReadFile(path)
    if ok and tspath.FileExtensionIs(path, tspath.ExtensionTsBuildInfo) then
        -- read buildinfo and modify version
        local buildInfo, err = tsctests.unmarshalBuildInfo(contents)
        if err == nil and buildInfo.version == harnessutil.FakeTSVersion then
            buildInfo.version = core.Version()
            local newContents, err2 = tsctests.marshalBuildInfo(buildInfo)
            if err2 ~= nil then
                error("testFs.ReadFile: failed to marshal build info after fixing version: " .. tostring(err2), 0)
            end
            contents = newContents
        end
    end
    return contents, ok
end

function testFs:WriteFile(path, data)
    self:removeIgnoreLibPath(path)
    self.writtenFiles:Add(path)
    return self:writeFileHandlingBuildInfo(path, data)
end

function testFs:writeFileHandlingBuildInfo(path, data)
    if tspath.FileExtensionIs(path, tspath.ExtensionTsBuildInfo) then
        local buildInfo, err = tsctests.unmarshalBuildInfo(data)
        if err == nil then
            if buildInfo.version == core.Version() then
                -- Change it to harnessutil.FakeTSVersion
                buildInfo.version = harnessutil.FakeTSVersion
                local newData, err2 = tsctests.marshalBuildInfo(buildInfo)
                if err2 ~= nil then
                    return "testFs.WriteFile: failed to marshal build info after fixing version: " .. tostring(err2)
                end
                data = newData
            end
            -- Write readable build info version
            local err3 = self:WriteFile(
                path .. ".readable.baseline.txt",
                tsctests.toReadableBuildInfo(buildInfo, fsbaselineutil.SanitizeInternalSymbolName(data))
            )
            if err3 ~= nil then
                return "testFs.WriteFile: failed to write readable build info: " .. tostring(err3)
            end
        else
            error("testFs.WriteFile: failed to unmarshal build info: - use underlying FS's write method if this is intended use for testcase" .. tostring(err), 0)
        end
    end
    return self.fs:WriteFile(path, data)
end

-- Removes `path` and all its contents. Will return the first error it encounters.
function testFs:Remove(path)
    self:removeIgnoreLibPath(path)
    return self.fs:Remove(path)
end
