-- luacheck: ignore 211 421 423 431 432
local fourslash = require("tslua.fourslash")
local tspath = require("tslua.tspath")
local fsbaselineutil = require("tslua.testutil.fsbaselineutil")
local json = require("tslua.json")
local lsproto = require("tslua.lsp.lsproto")
local lsconv = require("tslua.ls.lsconv")
local lsptestutil = require("tslua.testutil.lsptestutil")
local collections = require("tslua.collections")
local gort = require("tslua.fourslash.goruntime")

local diffTable = {}
diffTable.__index = diffTable
fourslash.diffTable = diffTable

local diffTableWriter = {}
diffTableWriter.__index = diffTableWriter
fourslash.diffTableWriter = diffTableWriter

local FourslashTest = fourslash.FourslashTest

-- Go calls these *project.ConfigFileRegistry methods on a nil registry (they check c != nil).
local nilConfigFileRegistry = {
    GetTestConfigEntry = function() return nil end,
    GetTestConfigFileNamesEntry = function() return nil end,
    ForEachTestConfigEntry = function() end,
    ForEachTestConfigFileNamesEntry = function() end,
}

function fourslash.newStateBaseline(fsFromMap)
    local stateBaseline = {
        fsDiffer = fsbaselineutil.NewFSDiffer({
            fs = fsFromMap,
            writtenFiles = collections.NewSyncSet(),
        }),
        baseline = gort.NewBuilder(),
        isInitialized = false,
    }
    gort.fmt.Fprintf(stateBaseline.baseline, "UseCaseSensitiveFileNames: %v\n", fsFromMap:UseCaseSensitiveFileNames())
    stateBaseline.fsDiffer:BaselineFSwithDiff(stateBaseline.baseline)
    return stateBaseline
end

function FourslashTest:baselineRequestOrNotification(t, method, params)
    t:Helper()
    if not self.testData:isStateBaseliningEnabled() then
        return
    end
    local res, _ = json.MarshalIndent({ method = method, params = params }, "", "  ")
    self.stateBaseline.baseline:WriteString("\n")
    self.stateBaseline.baseline:WriteString(res)
    self.stateBaseline.baseline:WriteString("\n")
    self.stateBaseline.isInitialized = true
end

function FourslashTest:baselineProjectsAfterNotification(t, fileName)
    t:Helper()
    if not self.testData:isStateBaseliningEnabled() then
        return
    end
    local _, _, resultOk = lsptestutil.SendRequest(t, self.client, lsproto.TextDocumentHoverInfo, lsproto.HoverParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(fileName) }),
        position = lsproto.Position({ line = 0, character = 0 }),
    }))
    gort.assert.Assert(t, resultOk)
    self:baselineState(t)
end

function FourslashTest:baselineState(t)
    t:Helper()
    if not self.testData:isStateBaseliningEnabled() then
        return
    end
    local serialized = self:serializedState(t)
    if serialized ~= "" then
        self.stateBaseline.baseline:WriteString("\n")
        self.stateBaseline.baseline:WriteString(serialized)
    end
end

function FourslashTest:serializedState(t)
    t:Helper()
    local builder = gort.NewBuilder()
    self.stateBaseline.fsDiffer:BaselineFSwithDiff(builder)
    if gort.strings.TrimSpace(builder:String()) == "" then
        builder:Reset()
    end
    self:printStateDiff(t, builder)
    return builder:String()
end

function diffTable:add(key, value)
    self.diff:Set(key, value)
end

function diffTable:print(w, header)
    local count = self.diff:Size()
    if count == 0 then
        return
    end
    if header ~= "" then
        gort.fmt.Fprintf(w, "%s%s\n", self.options.indent, header)
    end
    local diffKeys = gort.makeSlice(0, function() return "" end)
    local keyWidth = 0
    local indent = self.options.indent .. "  "
    for key, _ in gort.seq(self.diff:Keys()) do
        keyWidth = math.max(keyWidth, #key)
        diffKeys = gort.append(diffKeys, key)
    end
    if self.options.sortKeys then
        gort.slices.Sort(diffKeys)
    end
    for i2, key in gort.ipairs(diffKeys) do
        local value = self.diff:GetOrZero(key)
        gort.fmt.Fprintf(w, "%s%-*s %s\n", indent, keyWidth + 1, key, value)
    end
end

function fourslash.newDiffTableWriter(header)
    return setmetatable({ header = header, diffs = {}, hasChange = false }, fourslash.diffTableWriter)
end

function diffTableWriter:setHasChange()
    self.hasChange = true
end

function diffTableWriter:add(key, fn)
    self.diffs[key] = fn
end

function diffTableWriter:print(w)
    if self.hasChange then
        gort.fmt.Fprintf(w, "%s::\n", self.header)
        local keys = gort.slices.Collect(gort.maps.Keys(self.diffs))
        gort.slices.Sort(keys)
        for i4, key in gort.ipairs(keys) do
            self.diffs[key](w)
        end
    end
end

function fourslash.areIterSeqEqual(a, b)
    local aSlice = gort.slices.Collect(a)
    local bSlice = gort.slices.Collect(b)
    gort.slices.Sort(aSlice)
    gort.slices.Sort(bSlice)
    return gort.slices.Equal(aSlice, bSlice)
end

function fourslash.printSlicesWithDiffTable(w, header, newSlice, getOldSlice, options, topChange, isDefault)
    local oldSlice = nil
    if topChange == "*modified*" then
        oldSlice = getOldSlice()
    end
    local table_ = setmetatable({ options = options, diff = collections.NewOrderedMap() }, fourslash.diffTable)
    for i6, entry in gort.ipairs(newSlice) do
        local entryChange = ""
        if (isDefault ~= nil) and isDefault(entry) then
            entryChange = "(default) "
        end
        if (topChange == "*modified*") and (not gort.slices.Contains(oldSlice, entry)) then
            entryChange = "*new*"
        end
        table_:add(entry, entryChange)
    end
    if topChange == "*modified*" then
        for i8, entry in gort.ipairs(oldSlice) do
            if not gort.slices.Contains(newSlice, entry) then
                table_:add(entry, "*deleted*")
            end
        end
    end
    table_:print(w, header)
end

function fourslash.sliceFromIterSeqPath(seq)
    local result = nil
    for path, _ in gort.seq(seq) do
        result = gort.append(result, path)
    end
    gort.slices.Sort(result)
    return result
end

function fourslash.printPathIterSeqWithDiffTable(w, header, newIterSeq, getOldIterSeq, options, topChange)
    fourslash.printSlicesWithDiffTable(w, header, fourslash.sliceFromIterSeqPath(newIterSeq), function()
        return fourslash.sliceFromIterSeqPath(getOldIterSeq())
    end, options, topChange, nil)
end

function FourslashTest:printStateDiff(t, w)
    if not self.stateBaseline.isInitialized then
        return
    end
    local session = self.client.Server:Session()
    local snapshot = session:Snapshot()
    self:printProjectsDiff(t, snapshot, w)
    self:printOpenFilesDiff(t, snapshot, w)
    self:printConfigFileRegistryDiff(t, snapshot, w)
end

function FourslashTest:printProjectsDiff(t, snapshot, w)
    t:Helper()
    local currentProjects = {}
    local options = { indent = "  ", sortKeys = false }
    local projectsDiffTable = fourslash.newDiffTableWriter("Projects")
    for i11, project_ in gort.ipairs(snapshot.projectCollection:Projects()) do
        local program = project_:GetProgram()
        local oldProgram = nil
        currentProjects[project_:Name()] = program
        local projectChange = ""
        do
            local existing, ok = gort.MapLookup(self.stateBaseline.serializedProjects, project_:Name(), nil)
            if ok then
                oldProgram = existing
                if oldProgram ~= program then
                    projectChange = "*modified*"
                    projectsDiffTable:setHasChange()
                else
                    projectChange = ""
                end
            else
                projectChange = "*new*"
                projectsDiffTable:setHasChange()
            end
        end
        projectsDiffTable:add(project_:Name(), function(w)
                gort.fmt.Fprintf(w, "  [%s] %s\n", project_:Name(), projectChange)
                local subDiff = setmetatable({ options = options, diff = collections.NewOrderedMap() }, fourslash.diffTable)
                if program ~= nil then
                    for i13, file in gort.ipairs(program:GetSourceFiles()) do
                        local fileDiff = ""
                        local fileName = file:FileName()
                        if projectChange == "*modified*" then
                            if oldProgram == nil then
                                if not fourslash.isLibFile(fileName) then
                                    fileDiff = "*new*"
                                end
                            else
                                do
                                    local oldFile = oldProgram:GetSourceFileByPath(file:Path())
                                    if oldFile == nil then
                                        fileDiff = "*new*"
                                    elseif oldFile ~= file then
                                        fileDiff = "*modified*"
                                    end
                                end
                            end
                        end
                        if (fileDiff ~= "") or (not fourslash.isLibFile(fileName)) then
                            subDiff:add(fileName, fileDiff)
                        end
                    end
                end
                if (oldProgram ~= program) and (oldProgram ~= nil) then
                    for i15, file in gort.ipairs(oldProgram:GetSourceFiles()) do
                        if (program == nil) or (program:GetSourceFileByPath(file:Path()) == nil) then
                            subDiff:add(file:FileName(), "*deleted*")
                        end
                    end
                end
                subDiff:print(w, "")
            end)
    end
    for projectName, info in gort.pairs(self.stateBaseline.serializedProjects) do
        do
            local _, found = gort.MapLookup(currentProjects, projectName, nil)
            if not found then
                projectsDiffTable:setHasChange()
                projectsDiffTable:add(projectName, function(w)
                        gort.fmt.Fprintf(w, "  [%s] *deleted*\n", projectName)
                        local subDiff = setmetatable({ options = options, diff = collections.NewOrderedMap() }, fourslash.diffTable)
                        if info ~= nil then
                            for i18, file in gort.ipairs(info:GetSourceFiles()) do
                                do
                                    local fileName = file:FileName()
                                    if not fourslash.isLibFile(fileName) then
                                        subDiff:add(fileName, "")
                                    end
                                end
                            end
                        end
                        subDiff:print(w, "")
                    end)
            end
        end
    end
    self.stateBaseline.serializedProjects = currentProjects
    projectsDiffTable:print(w)
end

function FourslashTest:printOpenFilesDiff(t, snapshot, w)
    t:Helper()
    local currentOpenFiles = {}
    local filesDiffTable = fourslash.newDiffTableWriter("Open Files")
    local options = { indent = "  ", sortKeys = true }
    for fileName, _ in gort.pairs(self.openFiles) do
        local path = tspath.ToPath(fileName, "/", self.vfs:UseCaseSensitiveFileNames())
        local defaultProject = snapshot.projectCollection:GetDefaultProject(path)
        local newFileInfo = { defaultProjectName = "" }
        if defaultProject ~= nil then
            newFileInfo.defaultProjectName = defaultProject:Name()
        end
        for i21, project_ in gort.ipairs(snapshot.projectCollection:Projects()) do
            do
                local program = project_:GetProgram()
                if (program ~= nil) and (program:GetSourceFileByPath(path) ~= nil) then
                    newFileInfo.allProjects = gort.append(newFileInfo.allProjects, project_:Name())
                end
            end
        end
        gort.slices.Sort(newFileInfo.allProjects)
        currentOpenFiles[fileName] = newFileInfo
        local openFileChange = ""
        local oldFileInfo = nil
        do
            local existing, ok = gort.MapLookup(self.stateBaseline.serializedOpenFiles, fileName, nil)
            if ok then
                oldFileInfo = existing
                if (existing.defaultProjectName ~= newFileInfo.defaultProjectName) or (not gort.slices.Equal(existing.allProjects, newFileInfo.allProjects)) then
                    openFileChange = "*modified*"
                    filesDiffTable:setHasChange()
                else
                    openFileChange = ""
                end
            else
                openFileChange = "*new*"
                filesDiffTable:setHasChange()
            end
        end
        filesDiffTable:add(fileName, function(w)
                gort.fmt.Fprintf(w, "  [%s] %s\n", fileName, openFileChange)
                fourslash.printSlicesWithDiffTable(w, "", newFileInfo.allProjects, function()
                    return oldFileInfo.allProjects
                end, options, openFileChange, function(projectName)
                    return projectName == newFileInfo.defaultProjectName
                end)
            end)
    end
    for fileName, _ in gort.pairs(self.stateBaseline.serializedOpenFiles) do
        do
            local _, found = gort.MapLookup(currentOpenFiles, fileName, nil)
            if not found then
                filesDiffTable:setHasChange()
                filesDiffTable:add(fileName, function(w)
                        gort.fmt.Fprintf(w, "  [%s] *closed*\n", fileName)
                    end)
            end
        end
    end
    self.stateBaseline.serializedOpenFiles = currentOpenFiles
    filesDiffTable:print(w)
end

function FourslashTest:printConfigFileRegistryDiff(t, snapshot, w)
    t:Helper()
    local configFileRegistry = snapshot.projectCollection:ConfigFileRegistry()
    local configDiffsTable = fourslash.newDiffTableWriter("Config")
    local configFileNamesDiffsTable = fourslash.newDiffTableWriter("Config File Names")
    if self.stateBaseline.serializedConfigFileRegistry == configFileRegistry then
        return
    end
    local options = { indent = "    ", sortKeys = true }
    configFileRegistry:ForEachTestConfigEntry(function(path, entry)
        local configChange = ""
        -- (Go calls GetTestConfigEntry on a possibly nil *ConfigFileRegistry, which returns nil)
        local oldEntry = nil
        if self.stateBaseline.serializedConfigFileRegistry ~= nil then
            oldEntry = (self.stateBaseline.serializedConfigFileRegistry or nilConfigFileRegistry):GetTestConfigEntry(path)
        end
        if oldEntry == nil then
            configChange = "*new*"
            configDiffsTable:setHasChange()
        elseif oldEntry ~= entry then
            if ((not fourslash.areIterSeqEqual(oldEntry.retainingProjects, entry.retainingProjects)) or (not fourslash.areIterSeqEqual(oldEntry.retainingOpenFiles, entry.retainingOpenFiles))) or (not fourslash.areIterSeqEqual(oldEntry.retainingConfigs, entry.retainingConfigs)) then
                configChange = "*modified*"
                configDiffsTable:setHasChange()
            end
        end
        configDiffsTable:add(path, function(w)
            gort.fmt.Fprintf(w, "  [%s] %s\n", entry.fileName, configChange)
            local retainingProjectsModified = ""
            local retainingOpenFilesModified = ""
            local retainingConfigsModified = ""
            if configChange == "*modified*" then
                if not fourslash.areIterSeqEqual(entry.retainingProjects, oldEntry.retainingProjects) then
                    retainingProjectsModified = " *modified*"
                end
                if not fourslash.areIterSeqEqual(entry.retainingOpenFiles, oldEntry.retainingOpenFiles) then
                    retainingOpenFilesModified = " *modified*"
                end
                if not fourslash.areIterSeqEqual(entry.retainingConfigs, oldEntry.retainingConfigs) then
                    retainingConfigsModified = " *modified*"
                end
            end
            fourslash.printPathIterSeqWithDiffTable(w, "RetainingProjects:" .. retainingProjectsModified, entry.retainingProjects, function()
                return oldEntry.retainingProjects
            end, options, configChange)
            fourslash.printPathIterSeqWithDiffTable(w, "RetainingOpenFiles:" .. retainingOpenFilesModified, entry.retainingOpenFiles, function()
                return oldEntry.retainingOpenFiles
            end, options, configChange)
            fourslash.printPathIterSeqWithDiffTable(w, "RetainingConfigs:" .. retainingConfigsModified, entry.retainingConfigs, function()
                return oldEntry.retainingConfigs
            end, options, configChange)
        end)
    end)
    configFileRegistry:ForEachTestConfigFileNamesEntry(function(path, entry)
        local configFileNamesChange = ""
        local oldEntry = (self.stateBaseline.serializedConfigFileRegistry or nilConfigFileRegistry):GetTestConfigFileNamesEntry(path)
        if oldEntry == nil then
            configFileNamesChange = "*new*"
            configFileNamesDiffsTable:setHasChange()
        elseif (oldEntry.nearestConfigFileName ~= entry.nearestConfigFileName) or (not gort.maps.Equal(oldEntry.ancestors, entry.ancestors)) then
            configFileNamesChange = "*modified*"
            configFileNamesDiffsTable:setHasChange()
        end
        configFileNamesDiffsTable:add(path, function(w)
            gort.fmt.Fprintf(w, "  [%s] %s\n", path, configFileNamesChange)
            local nearestConfigFileNameModified = ""
            local ancestorDiffModified = ""
            if configFileNamesChange == "*modified*" then
                if oldEntry.nearestConfigFileName ~= entry.nearestConfigFileName then
                    nearestConfigFileNameModified = " *modified*"
                end
                if not gort.maps.Equal(oldEntry.ancestors, entry.ancestors) then
                    ancestorDiffModified = " *modified*"
                end
            end
            gort.fmt.Fprintf(w, "    NearestConfigFileName: %s%s\n", entry.nearestConfigFileName, nearestConfigFileNameModified)
            local ancestorDiff = setmetatable({ options = options, diff = collections.NewOrderedMap() }, fourslash.diffTable)
            for config, ancestorOfConfig in gort.pairs(entry.ancestors) do
                local ancestorChange = ""
                if configFileNamesChange == "*modified*" then
                    do
                        local oldConfigFileName, ok = gort.MapLookup(oldEntry.ancestors, config, "")
                        if ok then
                            if oldConfigFileName ~= ancestorOfConfig then
                                ancestorChange = "*modified*"
                            end
                        else
                            ancestorChange = "*new*"
                        end
                    end
                end
                ancestorDiff:add(config, gort.fmt.Sprintf("%s %s", ancestorOfConfig, ancestorChange))
            end
            if configFileNamesChange == "*modified*" then
                for ancestorPath, oldConfigFileName in gort.pairs(oldEntry.ancestors) do
                    do
                        local _, ok = gort.MapLookup(entry.ancestors, ancestorPath, "")
                        if not ok then
                            ancestorDiff:add(ancestorPath, oldConfigFileName .. " *deleted*")
                        end
                    end
                end
            end
            ancestorDiff:print(w, "Ancestors:" .. ancestorDiffModified)
        end)
    end)
    ;(self.stateBaseline.serializedConfigFileRegistry or nilConfigFileRegistry):ForEachTestConfigEntry(function(path, entry)
        if configFileRegistry:GetTestConfigEntry(path) == nil then
            configDiffsTable:setHasChange()
            configDiffsTable:add(path, function(w)
                gort.fmt.Fprintf(w, "  [%s] *deleted*\n", entry.fileName)
            end)
        end
    end)
    ;(self.stateBaseline.serializedConfigFileRegistry or nilConfigFileRegistry):ForEachTestConfigFileNamesEntry(function(path, entry)
        if configFileRegistry:GetTestConfigFileNamesEntry(path) == nil then
            configFileNamesDiffsTable:setHasChange()
            configFileNamesDiffsTable:add(path, function(w)
                gort.fmt.Fprintf(w, "  [%s] *deleted*\n", path)
            end)
        end
    end)
    self.stateBaseline.serializedConfigFileRegistry = configFileRegistry
    configDiffsTable:print(w)
    configFileNamesDiffsTable:print(w)
end

