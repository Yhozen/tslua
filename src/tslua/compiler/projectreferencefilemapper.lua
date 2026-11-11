local compiler = require("tslua.compiler")
local core = require("tslua.core")
local module = require("tslua.module")

local projectReferenceFileMapper = {}
projectReferenceFileMapper.__index = projectReferenceFileMapper
compiler.projectReferenceFileMapper = projectReferenceFileMapper

function compiler.newProjectReferenceFileMapper(opts, host)
    return setmetatable({
        opts = opts,
        host = host,
        loader = nil, -- Only present during populating the mapper and parsing, released after that

        configToProjectReference = nil, -- All the resolved references needed
        configToProjectReferencePresent = nil,
        referencesInConfigFile = nil, -- Map of config file to its references
        sourceToProjectReference = nil,
        outputDtsToProjectReference = nil,

        -- Store all the realpath from dts in node_modules to source file from project reference needed during parsing so it can be used later
        realpathDtsToSource = {},
        realpathDtsToSourcePresent = {},
    }, projectReferenceFileMapper)
end

function projectReferenceFileMapper:getParseFileRedirect(file)
    if self.opts:canUseProjectReferenceSource() then
        -- Map to source file from project reference
        local source = self:getProjectReferenceFromOutputDts(file:Path())
        if source == nil then
            source = self:getSourceToDtsIfSymlink(file)
        end
        if source ~= nil then
            return source.source
        end
    else
        -- Map to dts file from project reference
        local output = self:getProjectReferenceFromSource(file:Path())
        if output ~= nil and output.outputDts ~= "" then
            return output.outputDts
        end
    end
    return ""
end

function projectReferenceFileMapper:getResolvedProjectReferences()
    if self.opts.config.configFile == nil then
        return nil
    end
    local refs = self.referencesInConfigFile ~= nil and self.referencesInConfigFile[self.opts.config.configFile.sourceFile:Path()] or nil
    local result = nil
    if refs ~= nil then
        result = {}
        for _, refPath in ipairs(refs) do
            local refConfig = self.configToProjectReference[refPath]
            -- a nil ParsedCommandLine is kept as false so the slice has no holes
            result[#result + 1] = refConfig or false
        end
    end
    return result
end

function projectReferenceFileMapper:getProjectReferenceFromSource(path)
    if self.sourceToProjectReference == nil then
        return nil
    end
    return self.sourceToProjectReference[path]
end

function projectReferenceFileMapper:getProjectReferenceFromOutputDts(path)
    if self.outputDtsToProjectReference == nil then
        return nil
    end
    return self.outputDtsToProjectReference[path]
end

function projectReferenceFileMapper:isSourceFromProjectReference(path)
    return self.opts:canUseProjectReferenceSource() and self:getProjectReferenceFromSource(path) ~= nil
end

function projectReferenceFileMapper:getCompilerOptionsForFile(file)
    local redirect = self:getRedirectParsedCommandLineForResolution(file)
    return module.GetCompilerOptionsWithRedirect(self.opts.config:CompilerOptions(), redirect)
end

function projectReferenceFileMapper:getRedirectParsedCommandLineForResolution(file)
    local redirect = self:getRedirectForResolution(file)
    return redirect
end

-- Returns (*tsoptions.ParsedCommandLine, string).
function projectReferenceFileMapper:getRedirectForResolution(file)
    local path = file:Path()
    -- Check if outputdts of source file from project reference
    local output = self:getProjectReferenceFromSource(path)
    if output ~= nil then
        return output.resolved, output.source
    end

    -- Source file from project reference
    local resultFromDts = self:getProjectReferenceFromOutputDts(path)
    if resultFromDts ~= nil then
        return resultFromDts.resolved, resultFromDts.source
    end

    local realpathDtsToSource = self:getSourceToDtsIfSymlink(file)
    if realpathDtsToSource ~= nil then
        return realpathDtsToSource.resolved, realpathDtsToSource.source
    end
    return nil, file:FileName()
end

-- Returns (*tsoptions.ParsedCommandLine, bool).
function projectReferenceFileMapper:getResolvedReferenceFor(path)
    if self.configToProjectReference == nil then
        return nil, false
    end
    return self.configToProjectReference[path], self.configToProjectReferencePresent[path] == true
end

function projectReferenceFileMapper:rangeResolvedProjectReference(f)
    if self.opts.config.configFile == nil then
        return false
    end
    local seenRef = {}
    local configPath = self.opts.config.configFile.sourceFile:Path()
    seenRef[configPath] = true
    local refs = self.referencesInConfigFile ~= nil and self.referencesInConfigFile[configPath] or nil
    return self:rangeResolvedReferenceWorker(refs, f, self.opts.config, seenRef)
end

function projectReferenceFileMapper:rangeResolvedReferenceWorker(references, f, parent, seenRef)
    for index1, path in ipairs(references or {}) do
        if seenRef[path] then
            goto continue
        end
        seenRef[path] = true
        do
            local config = self.configToProjectReference[path]
            if not f(path, config, parent, index1 - 1) then
                return false
            end
            if not self:rangeResolvedReferenceWorker(self.referencesInConfigFile[path], f, config, seenRef) then
                return false
            end
        end
        ::continue::
    end
    return true
end

function projectReferenceFileMapper:rangeResolvedProjectReferenceInChildConfig(childConfig, f)
    if childConfig == nil or childConfig.configFile == nil then
        return false
    end
    local seenRef = {}
    local childPath = childConfig.configFile.sourceFile:Path()
    seenRef[childPath] = true
    local refs = self.referencesInConfigFile ~= nil and self.referencesInConfigFile[childPath] or nil
    return self:rangeResolvedReferenceWorker(refs, f, self.opts.config, seenRef)
end

function projectReferenceFileMapper:getSourceToDtsIfSymlink(file)
    -- If preserveSymlinks is true, module resolution wont jump the symlink
    -- but the resolved real path may be the .d.ts from project reference
    -- Note:: Currently we try the real path only if the
    -- file is from node_modules to avoid having to run real path on all file paths
    local path = file:Path()
    if self.realpathDtsToSourcePresent[path] then
        return self.realpathDtsToSource[path]
    end
    if self.loader ~= nil and self.opts.config:CompilerOptions().preserveSymlinks == core.Tristate.TSTrue then
        local fileName = file:FileName()
        if not compiler.contains(fileName, "/node_modules/") then
            self.realpathDtsToSourcePresent[path] = true
        else
            local realDeclarationPath = self.loader:toPath(self.host:FS():Realpath(fileName))
            if realDeclarationPath == path then
                self.realpathDtsToSourcePresent[path] = true
            else
                local realpathDtsToSource = self:getProjectReferenceFromOutputDts(realDeclarationPath)
                if realpathDtsToSource ~= nil then
                    self.realpathDtsToSourcePresent[path] = true
                    self.realpathDtsToSource[path] = realpathDtsToSource
                    return realpathDtsToSource
                end
                self.realpathDtsToSourcePresent[path] = true
            end
        end
    end
    return nil
end
