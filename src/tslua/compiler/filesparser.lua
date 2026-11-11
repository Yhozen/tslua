local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local ModuleKind = core.ModuleKind

local parseTask = {}
parseTask.__index = parseTask
compiler.parseTask = parseTask

function compiler.newParseTask(fields)
    return setmetatable({
        normalizedFilePath = fields.normalizedFilePath or "",
        path = fields.path or "",
        file = fields.file,
        libFile = fields.libFile,
        redirectedParseTask = nil,
        subTasks = nil,
        loaded = false,
        startedSubTasks = false,
        isForAutomaticTypeDirective = fields.isForAutomaticTypeDirective or false,
        isContentMapperSupplemental = fields.isContentMapperSupplemental or false,
        failedLookup = false,
        includeReason = fields.includeReason,
        packageId = fields.packageId,

        metadata = compiler.newSourceFileMetaData(),
        resolutionsInFile = nil,
        resolutionsTrace = nil,
        typeResolutionsInFile = nil,
        typeResolutionsTrace = nil,
        resolutionDiagnostics = nil,
        processingDiagnostics = nil,
        importHelpersImportSpecifier = nil,
        jsxRuntimeImportSpecifier = nil,

        increaseDepth = fields.increaseDepth or false,
        elideOnDepth = fields.elideOnDepth or false,

        loadedTask = nil,
        allIncludeReasons = nil,
    }, parseTask)
end

function parseTask:FileName()
    return self.normalizedFilePath
end

function parseTask:Path()
    return self.path
end

local function flattenExtensions(groups)
    local flat = {}
    for _, group in ipairs(groups) do
        for _, ext in ipairs(group) do
            flat[#flat + 1] = ext
        end
    end
    return flat
end

function parseTask:load(loader)
    self.loaded = true
    if self.isForAutomaticTypeDirective then
        self:loadAutomaticTypeDirectives(loader)
        return
    end
    if self.failedLookup then
        -- The root file name did not resolve to a supported extension; the task
        -- exists only to carry its processing diagnostic, so nothing is parsed.
        return
    end
    local redirect = loader.projectReferenceFileMapper:getParseFileRedirect(self)
    if redirect ~= "" then
        self:redirect(loader, redirect)
        return
    end

    if not self.isContentMapperSupplemental and tspath.HasExtension(self.normalizedFilePath) then
        local compilerOptions = loader.opts.config:CompilerOptions()
        local allowNonTsExtensions = core.Tristate_IsTrue(compilerOptions.allowNonTsExtensions)
        if not allowNonTsExtensions then
            local canonicalFileName = tspath.GetCanonicalFileName(self.normalizedFilePath, loader.opts.host:FS():UseCaseSensitiveFileNames())
            if not loader:isSupportedExtension(canonicalFileName) then
                if tspath.HasJSFileExtension(canonicalFileName) then
                    self.processingDiagnostics = core.Append(self.processingDiagnostics, compiler.newProcessingDiagnostic(
                        compiler.processingDiagnosticKindExplainingFileInclude,
                        compiler.newIncludeExplainingDiagnostic({
                            diagnosticReason = self.includeReason,
                            message = diagnostics.File_0_is_a_JavaScript_file_Did_you_mean_to_enable_the_allowJs_option,
                            args = { self.normalizedFilePath },
                        })
                    ))
                else
                    self.processingDiagnostics = core.Append(self.processingDiagnostics, compiler.newProcessingDiagnostic(
                        compiler.processingDiagnosticKindExplainingFileInclude,
                        compiler.newIncludeExplainingDiagnostic({
                            diagnosticReason = self.includeReason,
                            message = diagnostics.File_0_has_an_unsupported_extension_The_only_supported_extensions_are_1,
                            args = { self.normalizedFilePath, "'" .. table.concat(flattenExtensions(loader.supportedExtensions), "', '") .. "'" },
                        })
                    ))
                end
                return
            end
        end
    end

    loader.totalFileCount = loader.totalFileCount + 1
    if self.libFile ~= nil then
        loader.libFileCount = loader.libFileCount + 1
        -- Default lib files are all scripts; we can safely skip looking up their package.json
        -- to avoid adding spurious lookups to file watcher tracking.
        self.metadata = compiler.newSourceFileMetaData("", "", ModuleKind.ResolutionModeCommonJS)
    else
        self.metadata = loader:loadSourceFileMetaData(self.normalizedFilePath)
    end

    local file = self.file
    if file == nil then
        file = loader:parseSourceFile(self)
    end
    if file == nil then
        return
    end

    self.file = file
    local virtualFileName = file:VirtualFileName()
    if virtualFileName ~= "" then
        self.metadata = compiler.newSourceFileMetaData(
            self.metadata.packageJsonType,
            self.metadata.packageJsonDirectory,
            ast.GetImpliedNodeFormatForFile(virtualFileName, self.metadata.packageJsonType)
        )
    end
    self.subTasks = {}

    local compilerOptions = loader.opts.config:CompilerOptions()
    if not core.Tristate_IsTrue(compilerOptions.noResolve) then
        for index1, ref in ipairs(file.referencedFiles or {}) do
            local resolvedRef, processingDiagnostic = loader:resolveTripleslashPathReference(ref.fileName, file:FileName(), index1 - 1)
            if processingDiagnostic ~= nil then
                self.processingDiagnostics = core.Append(self.processingDiagnostics, processingDiagnostic)
            else
                self:addSubTask(resolvedRef, nil)
            end
        end

        loader:resolveTypeReferenceDirectives(self)
    end

    if compilerOptions.noLib ~= core.Tristate.TSTrue then
        for index1, lib in ipairs(file.libReferenceDirectives or {}) do
            local includeReason = compiler.newFileIncludeReason(
                compiler.fileIncludeKindLibReferenceDirective,
                compiler.newReferencedFileData(self.path, index1 - 1, nil)
            )
            local name, ok = tsoptions.GetLibFileName(lib.fileName)
            if ok then
                local libFile = loader:pathForLibFile(name)
                self:addSubTask(compiler.newResolvedRef({
                    fileName = libFile.path,
                    includeReason = includeReason,
                }), libFile)
            else
                self.processingDiagnostics = core.Append(self.processingDiagnostics, compiler.newProcessingDiagnostic(
                    compiler.processingDiagnosticKindUnknownReference,
                    includeReason
                ))
            end
        end
    end

    loader:resolveImportsAndModuleAugmentations(self)
    for _, supplemental in ipairs(file:SupplementalSourceFiles() or {}) do
        self.subTasks[#self.subTasks + 1] = compiler.newParseTask({
            normalizedFilePath = supplemental:FileName(),
            file = supplemental,
            isContentMapperSupplemental = true,
            includeReason = compiler.newFileIncludeReason(compiler.fileIncludeKindContentMapperSupplemental, self.path),
        })
    end
end

function parseTask:redirect(loader, fileName)
    self.redirectedParseTask = compiler.newParseTask({
        normalizedFilePath = tspath.NormalizePath(fileName),
        libFile = self.libFile,
        includeReason = self.includeReason,
    })
    -- increaseDepth and elideOnDepth are not copied to redirects, otherwise their depth would be double counted.
    self.subTasks = { self.redirectedParseTask }
end

function parseTask:loadAutomaticTypeDirectives(loader)
    local toParseTypeRefs, typeResolutionsInFile, typeResolutionsTrace, pDiagnostics = loader:resolveAutomaticTypeDirectives(self.normalizedFilePath)
    self.typeResolutionsInFile = typeResolutionsInFile
    self.typeResolutionsTrace = typeResolutionsTrace
    self.processingDiagnostics = core.AppendAll(self.processingDiagnostics, pDiagnostics)
    for _, typeResolution in ipairs(toParseTypeRefs or {}) do
        self:addSubTask(typeResolution, nil)
    end
end

-- resolvedRef: { fileName, increaseDepth, elideOnDepth, includeReason, packageId }
function compiler.newResolvedRef(fields)
    return {
        fileName = fields.fileName or "",
        increaseDepth = fields.increaseDepth or false,
        elideOnDepth = fields.elideOnDepth or false,
        includeReason = fields.includeReason,
        packageId = fields.packageId,
    }
end

function parseTask:addSubTask(ref, libFile)
    local normalizedFilePath = tspath.NormalizePath(ref.fileName)
    local subTask = compiler.newParseTask({
        normalizedFilePath = normalizedFilePath,
        libFile = libFile,
        increaseDepth = ref.increaseDepth,
        elideOnDepth = ref.elideOnDepth,
        includeReason = ref.includeReason,
        packageId = ref.packageId,
    })
    self.subTasks = core.Append(self.subTasks, subTask)
end

local filesParser = {}
filesParser.__index = filesParser
compiler.filesParser = filesParser

function compiler.newFilesParser(wg, maxDepth)
    return setmetatable({
        wg = wg,
        taskDataByPath = {},
        maxDepth = maxDepth or 0,
    }, filesParser)
end

-- parseTaskData: tasks is a map of tasks by file casing; taskNames keeps insertion order so that
-- iteration over it is deterministic.
function compiler.getParseTaskData(task)
    local td = {
        tasks = {},
        taskNames = {},
        lowestDepth = math.maxinteger,
        startedSubTasks = false,
        packageId = nil,
    }
    td.tasks[task.normalizedFilePath] = task
    td.taskNames[1] = task.normalizedFilePath
    return td
end

function filesParser:parse(loader, tasks)
    self:start(loader, tasks, 0)
    self.wg:RunAndWait()
end

function filesParser:start(loader, tasks, depth)
    for i1, task in ipairs(tasks or {}) do
        task.path = loader:toPath(task.normalizedFilePath)
        local data = self.taskDataByPath[task.path]
        local loaded = data ~= nil
        if not loaded then
            data = compiler.getParseTaskData(task)
            self.taskDataByPath[task.path] = data
        end

        self.wg:Queue(function()
            local startSubtasks = false
            if loaded then
                local existingTask = data.tasks[task.normalizedFilePath]
                if existingTask ~= nil then
                    tasks[i1].loadedTask = existingTask
                else
                    data.tasks[task.normalizedFilePath] = task
                    data.taskNames[#data.taskNames + 1] = task.normalizedFilePath
                    -- This is new task for file name - so load subtasks if there was loading for any other casing
                    startSubtasks = data.startedSubTasks
                end
            end

            -- Propagate packageId to data if we have one and data doesn't yet
            if compiler.packageIdName(data.packageId) == "" and compiler.packageIdName(task.packageId) ~= "" then
                data.packageId = task.packageId
            end

            local currentDepth = depth
            if task.increaseDepth then
                currentDepth = depth + 1
            end
            if currentDepth < data.lowestDepth then
                -- If we're seeing this task at a lower depth than before,
                -- reprocess its subtasks to ensure they are loaded.
                data.lowestDepth = currentDepth
                startSubtasks = true
                data.startedSubTasks = true
            end

            if task.elideOnDepth and currentDepth > self.maxDepth then
                return
            end

            for _, name in ipairs(data.taskNames) do
                local taskByFileName = data.tasks[name]
                local loadSubTasks = startSubtasks
                if not taskByFileName.loaded then
                    taskByFileName:load(loader)
                    if taskByFileName.redirectedParseTask ~= nil then
                        -- Always load redirected task
                        loadSubTasks = true
                        data.startedSubTasks = true
                    end
                end
                if not taskByFileName.startedSubTasks and loadSubTasks then
                    taskByFileName.startedSubTasks = true
                    self:start(loader, taskByFileName.subTasks, data.lowestDepth)
                end
            end
        end)
    end
end

local function newDuplicateSourceFile(file)
    return {
        parseOptions = file:ParseOptions(),
        contentMapperParseOptions = file:ContentMapperParseOptions(),
        hash = file.hash,
        scriptKind = file.scriptKind,
        contentMapper = file:ContentMapper(),
        isContentMapperFailureStub = file:IsContentMapperFailureStub(),
    }
end

function filesParser:getProcessedFiles(loader)
    local missingFiles = nil
    local duplicateSourceFiles = nil
    local files = {}
    local libFiles = {} -- totalFileCount here since we append files to it later to construct the final list

    local filesByPath = {}
    -- stores 'filename -> file association' ignoring case
    -- used to track cases when two file names differ only in casing
    local tasksSeenByNameIgnoreCase = nil
    if loader.comparePathsOptions.useCaseSensitiveFileNames then
        tasksSeenByNameIgnoreCase = {}
    end

    local includeProcessor = compiler.newIncludeProcessor({}, nil)
    local outputFileToProjectReferenceSource = nil
    if not loader.opts:canUseProjectReferenceSource() then
        outputFileToProjectReferenceSource = {}
    end
    local resolvedModules = {}
    local typeResolutionsInFile = {}
    local sourceFileMetaDatas = {}
    local jsxRuntimeImportSpecifiers = nil
    local importHelpersImportSpecifiers = nil
    local sourceFilesFoundSearchingNodeModules = {}
    local libFilesMap = {}

    local redirectTargetsMap = nil
    local redirectFilesByPath = nil
    local redirectFilesByPathLen = 0
    local packageIdToSourceFile = nil
    if not core.Tristate_IsFalse(loader.opts.config:CompilerOptions().deduplicatePackages) then
        redirectTargetsMap = {}
        packageIdToSourceFile = {}
    end

    local collectFiles
    -- recordedDuplicates tracks, per task data, the set of file-name casings that
    -- have already been recorded in duplicateSourceFiles. A file that is reached
    -- from multiple import sites is walked once per site, but each distinct casing
    -- is only parsed and acquired in the parse cache once. Recording the same casing
    -- as a duplicate more than once would cause it to be released more times than it
    -- was acquired when the snapshot is disposed, leaving a dangling cache entry that
    -- panics the next time it is referenced.
    local recordedDuplicates = nil
    collectFiles = function(tasks, seen)
        for _, task in ipairs(tasks) do
            local includeReason = task.includeReason
            -- Exclude automatic type directive tasks from include reason processing,
            -- as these are internal implementation details and should not contribute
            -- to the reasons for including files.
            if task.redirectedParseTask == nil and not task.isForAutomaticTypeDirective then
                if task.loadedTask ~= nil then
                    task = task.loadedTask
                end
                self:addIncludeReason(includeProcessor, task, includeReason)
            end
            local data = self.taskDataByPath[task.path]
            if not task.loaded then
                goto continue
            end

            -- ensure we only walk each task once
            do
                local checkedName = seen[data]
                if checkedName ~= nil then
                    if task.file ~= nil and checkedName ~= task.normalizedFilePath then
                        if recordedDuplicates == nil then
                            recordedDuplicates = {}
                        end
                        local dups = recordedDuplicates[data]
                        if dups == nil then
                            dups = {}
                            recordedDuplicates[data] = dups
                        end
                        if not dups[task.normalizedFilePath] then
                            dups[task.normalizedFilePath] = true
                            duplicateSourceFiles = core.Append(duplicateSourceFiles, newDuplicateSourceFile(task.file))
                        end
                    end
                    if not core.Tristate_IsFalse(loader.opts.config:CompilerOptions().forceConsistentCasingInFileNames) then
                        -- Check if it differs only in drive letters its ok to ignore that error:
                        local checkedAbsolutePath = tspath.GetNormalizedAbsolutePathWithoutRoot(checkedName, loader.comparePathsOptions.currentDirectory)
                        local inputAbsolutePath = tspath.GetNormalizedAbsolutePathWithoutRoot(task.normalizedFilePath, loader.comparePathsOptions.currentDirectory)
                        if checkedAbsolutePath ~= inputAbsolutePath then
                            includeProcessor:addProcessingDiagnosticsForFileCasing(task.path, checkedName, task.normalizedFilePath, includeReason)
                        end
                    end
                    goto continue
                else
                    seen[data] = task.normalizedFilePath
                end
            end

            if tasksSeenByNameIgnoreCase ~= nil then
                local pathLowerCase = tspath.ToFileNameLowerCase(task.path)
                local taskByIgnoreCase = tasksSeenByNameIgnoreCase[pathLowerCase]
                if taskByIgnoreCase ~= nil then
                    includeProcessor:addProcessingDiagnosticsForFileCasing(taskByIgnoreCase.path, taskByIgnoreCase.normalizedFilePath, task.normalizedFilePath, includeReason)
                else
                    tasksSeenByNameIgnoreCase[pathLowerCase] = task
                end
            end

            for _, trace in ipairs(task.typeResolutionsTrace or {}) do
                loader.opts.host:Trace(trace.message, compiler.unpackArgs(trace.args))
            end
            for _, trace in ipairs(task.resolutionsTrace or {}) do
                loader.opts.host:Trace(trace.message, compiler.unpackArgs(trace.args))
            end

            do
                local file = task.file
                if packageIdToSourceFile ~= nil and compiler.packageIdName(data.packageId) ~= "" then
                    local pkgKey = compiler.packageIdKey(data.packageId)
                    local packageIdFile = packageIdToSourceFile[pkgKey]
                    if packageIdFile ~= nil then
                        if file ~= nil then
                            -- Package deduplication keeps the first package instance in the
                            -- program, but we still parsed this file and acquired it through
                            -- the host, so snapshot disposal must release that extra owner.
                            duplicateSourceFiles = core.Append(duplicateSourceFiles, newDuplicateSourceFile(file))
                        end
                        redirectTargetsMap[packageIdFile:Path()] = core.Append(redirectTargetsMap[packageIdFile:Path()], task.normalizedFilePath)
                        if redirectFilesByPath == nil then
                            redirectFilesByPath = {}
                        end
                        local index = #files + redirectFilesByPathLen
                        if redirectFilesByPath[task.path] == nil then
                            redirectFilesByPathLen = redirectFilesByPathLen + 1
                        end
                        redirectFilesByPath[task.path] = compiler.newRedirectsFile(
                            index,
                            task.normalizedFilePath,
                            task.path,
                            packageIdFile:Path()
                        )
                        filesByPath[task.path] = packageIdFile
                        if data.lowestDepth > 0 then
                            sourceFilesFoundSearchingNodeModules[task.path] = true
                        end
                        goto continue
                    elseif file ~= nil then
                        packageIdToSourceFile[pkgKey] = file
                    end
                end

                if core.Len(task.subTasks) > 0 then
                    collectFiles(task.subTasks, seen)
                end

                -- Exclude automatic type directive tasks from include reason processing,
                -- as these are internal implementation details and should not contribute
                -- to the reasons for including files.
                if task.redirectedParseTask ~= nil then
                    if not loader.opts:canUseProjectReferenceSource() then
                        outputFileToProjectReferenceSource[task.redirectedParseTask.path] = task:FileName()
                    end
                    goto continue
                end

                if task.isForAutomaticTypeDirective then
                    typeResolutionsInFile[task.path] = task.typeResolutionsInFile
                    if core.Len(task.processingDiagnostics) > 0 then
                        includeProcessor.processingDiagnostics = core.AppendAll(includeProcessor.processingDiagnostics, task.processingDiagnostics)
                    end
                    goto continue
                end

                local path = task.path

                if core.Len(task.processingDiagnostics) > 0 then
                    includeProcessor.processingDiagnostics = core.AppendAll(includeProcessor.processingDiagnostics, task.processingDiagnostics)
                end

                if file == nil then
                    missingFiles = core.Append(missingFiles, task.normalizedFilePath)
                    goto continue
                end

                if task.libFile ~= nil then
                    libFiles[#libFiles + 1] = file
                    libFilesMap[path] = task.libFile
                else
                    files[#files + 1] = file
                end
                filesByPath[path] = file
                resolvedModules[path] = task.resolutionsInFile
                typeResolutionsInFile[path] = task.typeResolutionsInFile
                sourceFileMetaDatas[path] = task.metadata

                if task.jsxRuntimeImportSpecifier ~= nil then
                    if jsxRuntimeImportSpecifiers == nil then
                        jsxRuntimeImportSpecifiers = {}
                    end
                    jsxRuntimeImportSpecifiers[path] = task.jsxRuntimeImportSpecifier
                end
                if task.importHelpersImportSpecifier ~= nil then
                    if importHelpersImportSpecifiers == nil then
                        importHelpersImportSpecifiers = {}
                    end
                    importHelpersImportSpecifiers[path] = task.importHelpersImportSpecifier
                end
                if data.lowestDepth > 0 then
                    sourceFilesFoundSearchingNodeModules[path] = true
                end
            end
            ::continue::
        end
    end

    collectFiles(loader.rootTasks, {})
    loader:sortLibs(libFiles)

    local allFiles = libFiles
    for _, f in ipairs(files) do
        allFiles[#allFiles + 1] = f
    end
    if redirectFilesByPath ~= nil then
        for _, redirectFile in pairs(redirectFilesByPath) do
            redirectFile.index = redirectFile.index + (#allFiles - #files)
        end
    end

    local keys = compiler.sortedKeys(loader.pathForLibFileResolutions)
    for _, key in ipairs(keys) do
        local value = loader.pathForLibFileResolutions[key]
        resolvedModules[key] = {
            [compiler.modeAwareCacheKey(value.libraryName, ModuleKind.CommonJS)] = value.resolution,
        }
        for _, trace in ipairs(value.trace or {}) do
            loader.opts.host:Trace(trace.message, compiler.unpackArgs(trace.args))
        end
    end

    return {
        finishedProcessing = true,
        resolver = loader.resolver,
        files = allFiles,
        duplicateSourceFiles = duplicateSourceFiles,
        filesByPath = filesByPath,
        projectReferenceFileMapper = loader.projectReferenceFileMapper,
        resolvedModules = resolvedModules,
        typeResolutionsInFile = typeResolutionsInFile,
        sourceFileMetaDatas = sourceFileMetaDatas,
        jsxRuntimeImportSpecifiers = jsxRuntimeImportSpecifiers,
        importHelpersImportSpecifiers = importHelpersImportSpecifiers,
        sourceFilesFoundSearchingNodeModules = sourceFilesFoundSearchingNodeModules,
        libFiles = libFilesMap,
        missingFiles = missingFiles,
        includeProcessor = includeProcessor,
        outputFileToProjectReferenceSource = outputFileToProjectReferenceSource,
        redirectTargetsMap = redirectTargetsMap,
        redirectFilesByPath = redirectFilesByPath,
        contentMapperDiagnostics = loader.contentMapperDiagnostics,
    }
end

function filesParser:addIncludeReason(includeProcessor, task, reason)
    if task.redirectedParseTask ~= nil then
        self:addIncludeReason(includeProcessor, task.redirectedParseTask, reason)
    elseif task.loaded then
        local existing = includeProcessor.fileIncludeReasons[task.path]
        if existing ~= nil then
            existing[#existing + 1] = reason
        else
            includeProcessor.fileIncludeReasons[task.path] = { reason }
        end
    end
end
