local incremental = require("tslua.execute.incremental")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local Tristate = core.Tristate
local isTrue = core.Tristate_IsTrue

local toBuildInfo = {}
toBuildInfo.__index = toBuildInfo
incremental.toBuildInfo = toBuildInfo

-- Returns (buildInfo, err).
function incremental.snapshotToBuildInfo(snapshot, program, buildInfoFileName)
    local contentMapperIdentities, err = incremental.ContentMapperIdentities(program:ContentMapperProject())
    if err ~= nil then
        return nil, err
    end
    local buildInfo = incremental.NewBuildInfo({
        version = core.Version(),
        contentMapperIdentities = contentMapperIdentities,
    })
    local to = setmetatable({
        snapshot = snapshot,
        program = program,
        buildInfo = buildInfo,
        buildInfoDirectory = tspath.GetDirectoryPath(buildInfoFileName),
        comparePathsOptions = tspath.NewComparePathsOptions(program:UseCaseSensitiveFileNames(), program:GetCurrentDirectory()),
        fileNameToFileId = {},
        fileNamesToFileIdListId = {},
        roots = {}, -- *ast.SourceFile -> tspath.Path
    }, toBuildInfo)

    if snapshot.options:IsIncremental() then
        to:collectRootFiles()
        to:setFileInfoAndEmitSignatures()
        to:setRootOfIncrementalProgram()
        to:setCompilerOptions()
        to:setReferencedMap()
        to:setChangeFileSet()
        to:setSemanticDiagnostics()
        to:setEmitDiagnostics()
        to:setAffectedFilesPendingEmit()
        if snapshot.latestChangedDtsFile ~= "" then
            buildInfo.latestChangedDtsFile = to:relativeToBuildInfo(snapshot.latestChangedDtsFile)
        end
    else
        to:setRootOfNonIncrementalProgram()
    end
    buildInfo.errors = core.Tristate_IsTrue(snapshot.hasErrors)
    buildInfo.semanticErrors = snapshot.hasSemanticErrors
    buildInfo.checkPending = snapshot.checkPending
    to:setPackageJsons()
    return buildInfo, nil
end

function toBuildInfo:relativeToBuildInfo(path)
    return tspath.EnsurePathIsNonModuleName(tspath.GetRelativePathFromDirectory(self.buildInfoDirectory, path, self.comparePathsOptions))
end

function toBuildInfo:toFileId(path)
    local fileId = self.fileNameToFileId[path] or 0
    if fileId == 0 then
        local libFile = self.program:GetDefaultLibFile(path)
        self.buildInfo.fileNames = self.buildInfo.fileNames or {}
        if libFile ~= nil and not libFile.replaced then
            self.buildInfo.fileNames[#self.buildInfo.fileNames + 1] = libFile.name
        else
            self.buildInfo.fileNames[#self.buildInfo.fileNames + 1] = self:relativeToBuildInfo(path)
        end
        fileId = #self.buildInfo.fileNames
        self.fileNameToFileId[path] = fileId
    end
    return fileId
end

function toBuildInfo:toFileIdListId(set)
    local fileIds = core.Map(incremental.sortedKeys(set:Keys()), function(p) return self:toFileId(p) end)
    table.sort(fileIds)
    local key = table.concat(core.Map(fileIds, function(id)
        return string.format("%d", id)
    end), ",")

    local fileIdListId = self.fileNamesToFileIdListId[key] or 0
    if fileIdListId == 0 then
        self.buildInfo.fileIdsList = core.Append(self.buildInfo.fileIdsList, fileIds)
        fileIdListId = #self.buildInfo.fileIdsList
        self.fileNamesToFileIdListId[key] = fileIdListId
    end
    return fileIdListId
end

function toBuildInfo:toRelativeToBuildInfoCompilerOptionValue(option, v)
    if option.kind == "list" then
        if option:Elements().isFilePath then
            if type(v) == "table" and getmetatable(v) ~= collections.OrderedMap then
                return core.Map(v, function(p) return self:relativeToBuildInfo(p) end)
            end
        end
    elseif option.isFilePath then
        if type(v) == "string" and v ~= "" then
            return self:relativeToBuildInfo(v)
        end
    end
    return v
end

function toBuildInfo:toBuildInfoDiagnosticsFromFileNameDiagnostics(diags)
    return core.Map(diags, function(d)
        local file = 0
        if d.file ~= "" then
            file = self:toFileId(d.file)
        end
        return incremental.NewBuildInfoDiagnostic({
            file = file,
            noFile = d.noFile,
            pos = d.pos,
            end_ = d.end_,
            code = d.code,
            category = d.category,
            source = d.source,
            messageText = d.messageText,
            messageKey = d.messageKey,
            messageArgs = d.messageArgs,
            messageChain = self:toBuildInfoDiagnosticsFromFileNameDiagnostics(d.messageChain),
            relatedInformation = self:toBuildInfoDiagnosticsFromFileNameDiagnostics(d.relatedInformation),
            reportsUnnecessary = d.reportsUnnecessary,
            reportsDeprecated = d.reportsDeprecated,
            skippedOnNoEmit = d.skippedOnNoEmit,
            repopulateInfo = incremental.toBuildInfoRepopulateInfo(d.repopulateInfo),
        })
    end)
end

-- Go nil and empty slices of diagnostics/args are not distinguished by the Lua diagnostic
-- structures; both are encoded as Go nil (omitted).
local function nilIfEmpty(xs)
    if xs == nil or #xs == 0 then
        return nil
    end
    return xs
end

function toBuildInfo:toBuildInfoDiagnosticsFromDiagnostics(filePath, diags)
    return core.Map(nilIfEmpty(diags), function(d)
        local file = 0
        local noFile = false
        if d:File() == nil then
            noFile = true
        elseif d:File():Path() ~= filePath then
            file = self:toFileId(d:File():Path())
        end
        return incremental.NewBuildInfoDiagnostic({
            file = file,
            noFile = noFile,
            pos = d:Loc():Pos(),
            end_ = d:Loc():End(),
            code = d:Code(),
            category = d:Category(),
            source = d:Source(),
            messageText = d:MessageText(),
            messageKey = d:MessageKey(),
            messageArgs = nilIfEmpty(d:MessageArgs()),
            messageChain = self:toBuildInfoDiagnosticsFromDiagnostics(filePath, d:MessageChain()),
            relatedInformation = self:toBuildInfoDiagnosticsFromDiagnostics(filePath, d:RelatedInformation()),
            reportsUnnecessary = d:ReportsUnnecessary(),
            reportsDeprecated = d:ReportsDeprecated(),
            skippedOnNoEmit = d:SkippedOnNoEmit(),
            repopulateInfo = incremental.toBuildInfoRepopulateInfo(d:RepopulateInfo()),
        })
    end)
end

function incremental.toBuildInfoRepopulateInfo(info)
    if info == nil then
        return nil
    end
    return incremental.NewBuildInfoRepopulateInfo({
        kind = info.kind,
        moduleReference = info.moduleReference,
        mode = info.mode,
        packageName = info.packageName,
    })
end

function toBuildInfo:toBuildInfoDiagnosticsOfFile(filePath, diags)
    if core.Len(diags.diagnostics) > 0 then
        return incremental.NewBuildInfoDiagnosticsOfFile(
            self:toFileId(filePath),
            self:toBuildInfoDiagnosticsFromDiagnostics(filePath, diags.diagnostics)
        )
    end
    if core.Len(diags.buildInfoDiagnostics) > 0 then
        return incremental.NewBuildInfoDiagnosticsOfFile(
            self:toFileId(filePath),
            self:toBuildInfoDiagnosticsFromFileNameDiagnostics(diags.buildInfoDiagnostics)
        )
    end
    return nil
end

function toBuildInfo:collectRootFiles()
    for _, fileName in ipairs(self.program:CommandLine():FileNames() or {}) do
        local file
        local redirect = self.program:GetParseFileRedirect(fileName)
        if redirect ~= "" then
            file = self.program:GetSourceFile(redirect)
        else
            file = self.program:GetSourceFile(fileName)
        end
        if file ~= nil then
            self.roots[file] = tspath.ToPath(fileName, self.comparePathsOptions.currentDirectory, self.comparePathsOptions.useCaseSensitiveFileNames)
        end
    end
end

function toBuildInfo:setFileInfoAndEmitSignatures()
    self.buildInfo.fileInfos = core.Map(self.program:GetSourceFiles(), function(file)
        local info = self.snapshot.fileInfos:Load(file:Path())
        local fileId = self:toFileId(file:Path())
        --  tryAddRoot(key, fileId);
        if self.buildInfo.fileNames[fileId] ~= self:relativeToBuildInfo(file:Path()) then
            local libFile = self.program:GetDefaultLibFile(file:Path())
            if libFile == nil or libFile.replaced or self.buildInfo.fileNames[fileId] ~= libFile.name then
                error(string.format("File name at index %d does not match expected relative path or libName: %s != %s", fileId - 1, self.buildInfo.fileNames[fileId], self:relativeToBuildInfo(file:Path())), 0)
            end
        end
        if isTrue(self.snapshot.options.composite) then
            if not ast.IsJsonSourceFile(file) and self.program:SourceFileMayBeEmitted(file, false) then
                local emitSignature, loaded = self.snapshot.emitSignatures:Load(file:Path())
                if not loaded then
                    self.buildInfo.emitSignatures = core.Append(self.buildInfo.emitSignatures, incremental.NewBuildInfoEmitSignature({
                        fileId = fileId,
                    }))
                elseif emitSignature.signature ~= info.signature then
                    local incrementalEmitSignature = incremental.NewBuildInfoEmitSignature({
                        fileId = fileId,
                    })
                    if emitSignature.signature ~= "" then
                        incrementalEmitSignature.signature = emitSignature.signature
                    elseif emitSignature.signatureWithDifferentOptions[1] == info.signature then
                        incrementalEmitSignature.differsOnlyInDtsMap = true
                    else
                        incrementalEmitSignature.signature = emitSignature.signatureWithDifferentOptions[1]
                        incrementalEmitSignature.differsInOptions = true
                    end
                    self.buildInfo.emitSignatures = core.Append(self.buildInfo.emitSignatures, incrementalEmitSignature)
                end
            end
        end
        return incremental.newBuildInfoFileInfo(info)
    end)
end

function toBuildInfo:setRootOfIncrementalProgram()
    local keys = {}
    for file in pairs(self.roots) do
        keys[#keys + 1] = file
    end
    table.sort(keys, function(a, b)
        return self:toFileId(a:Path()) < self:toFileId(b:Path())
    end)
    for _, file in ipairs(keys) do
        local root = self:toFileId(self.roots[file])
        local resolved = self:toFileId(file:Path())
        if self.buildInfo.root == nil then
            -- First fileId as is
            self.buildInfo.root = { incremental.NewBuildInfoRoot({ start = resolved }) }
        else
            local last = self.buildInfo.root[#self.buildInfo.root]
            if last.end_ == resolved - 1 then
                -- If its [..., last = [start, end = fileId - 1]], update last to [start, fileId]
                last.end_ = resolved
            elseif last.end_ == 0 and last.start == resolved - 1 then
                -- If its [..., last = start = fileId - 1 ], update last to [start, fileId]
                last.end_ = resolved
            else
                self.buildInfo.root[#self.buildInfo.root + 1] = incremental.NewBuildInfoRoot({ start = resolved })
            end
        end
        if root ~= resolved then
            self.buildInfo.resolvedRoot = core.Append(self.buildInfo.resolvedRoot, incremental.NewBuildInfoResolvedRoot(resolved, root))
        end
    end
end

-- Go reflect.Value.Interface() of a CompilerOptions field, as a JSON-ready Lua value.
local function optionJSONValue(fieldInfo, value)
    if fieldInfo.kind == "tristate" then
        if value == Tristate.TSTrue then
            return true
        elseif value == Tristate.TSFalse then
            return false
        end
        return nil
    end
    return value
end

local function optionValueIsZero(fieldInfo, value)
    if value == nil or value == tsoptions.NilSlice then
        return true
    end
    local kind = fieldInfo.kind
    if kind == "tristate" or string.sub(kind, 1, 5) == "enum:" then
        return value == 0
    elseif kind == "string" then
        return value == ""
    end
    return false
end

function toBuildInfo:setCompilerOptions()
    tsoptions.ForEachCompilerOptionValue(
        self.snapshot.options,
        function(option)
            return option.affectsBuildInfo
        end,
        function(option, value, i)
            local fieldInfo = core.CompilerOptions.Fields[i + 1]
            if optionValueIsZero(fieldInfo, value) then
                return false
            end
            -- Make it relative to buildInfo directory if file path
            if self.buildInfo.options == nil then
                self.buildInfo.options = collections.NewOrderedMap()
            end
            self.buildInfo.options:Set(option.name, optionJSONValue(fieldInfo, self:toRelativeToBuildInfoCompilerOptionValue(option, value)))
            return false
        end
    )
end

function toBuildInfo:setReferencedMap()
    local keys = self.snapshot.referencedMap:getPathsWithReferences()
    table.sort(keys)
    if #keys == 0 then
        keys = nil
    end
    self.buildInfo.referencedMap = core.Map(keys, function(filePath)
        local references = self.snapshot.referencedMap:getReferences(filePath)
        return incremental.NewBuildInfoReferenceMapEntry(
            self:toFileId(filePath),
            self:toFileIdListId(references)
        )
    end)
end

function toBuildInfo:setChangeFileSet()
    local files = {}
    for k in self.snapshot.changedFilesSet:Keys() do
        files[#files + 1] = k
    end
    table.sort(files)
    if #files == 0 then
        files = nil
    end
    self.buildInfo.changeFileSet = core.Map(files, function(p) return self:toFileId(p) end)
end

function toBuildInfo:setSemanticDiagnostics()
    for _, file in ipairs(self.program:GetSourceFiles()) do
        local value, ok = self.snapshot.semanticDiagnosticsPerFile:Load(file:Path())
        if not ok then
            if not self.snapshot.changedFilesSet:Has(file:Path()) then
                self.buildInfo.semanticDiagnosticsPerFile = core.Append(self.buildInfo.semanticDiagnosticsPerFile, incremental.NewBuildInfoSemanticDiagnostic(
                    self:toFileId(file:Path()),
                    nil
                ))
            end
        else
            local diags = self:toBuildInfoDiagnosticsOfFile(file:Path(), value)
            if diags ~= nil then
                self.buildInfo.semanticDiagnosticsPerFile = core.Append(self.buildInfo.semanticDiagnosticsPerFile, incremental.NewBuildInfoSemanticDiagnostic(
                    0,
                    diags
                ))
            end
        end
    end
end

function toBuildInfo:setEmitDiagnostics()
    local files = {}
    for k in self.snapshot.emitDiagnosticsPerFile:Keys() do
        files[#files + 1] = k
    end
    table.sort(files)
    if #files == 0 then
        files = nil
    end
    self.buildInfo.emitDiagnosticsPerFile = core.Map(files, function(filePath)
        local value = self.snapshot.emitDiagnosticsPerFile:Load(filePath)
        return self:toBuildInfoDiagnosticsOfFile(filePath, value)
    end)
end

function toBuildInfo:setAffectedFilesPendingEmit()
    local files = {}
    for k in self.snapshot.affectedFilesPendingEmit:Keys() do
        files[#files + 1] = k
    end
    table.sort(files)
    local fullEmitKind = incremental.GetFileEmitKind(self.snapshot.options)
    for _, filePath in ipairs(files) do
        local file = self.program:GetSourceFileByPath(filePath)
        if file ~= nil and self.program:SourceFileMayBeEmitted(file, false) then
            local pendingEmit = self.snapshot.affectedFilesPendingEmit:Load(filePath)
            self.buildInfo.affectedFilesPendingEmit = core.Append(self.buildInfo.affectedFilesPendingEmit, incremental.NewBuildInfoFilePendingEmit(
                self:toFileId(filePath),
                core.IfElse(pendingEmit == fullEmitKind, 0, pendingEmit)
            ))
        end
    end
end

function toBuildInfo:setRootOfNonIncrementalProgram()
    self.buildInfo.root = core.Map(self.program:CommandLine():FileNames(), function(fileName)
        return incremental.NewBuildInfoRoot({
            nonIncremental = self:relativeToBuildInfo(tspath.ToPath(fileName, self.comparePathsOptions.currentDirectory, self.comparePathsOptions.useCaseSensitiveFileNames)),
        })
    end)
end

function toBuildInfo:setPackageJsons()
    if core.Len(self.snapshot.packageJsons) > 0 then
        self.buildInfo.packageJsons = core.Map(self.snapshot.packageJsons, function(p) return self:relativeToBuildInfo(p) end)
    end
    if core.Len(self.snapshot.missingPackageJsons) > 0 then
        self.buildInfo.missingPackageJsons = core.Map(self.snapshot.missingPackageJsons, function(p) return self:relativeToBuildInfo(p) end)
    end
end
