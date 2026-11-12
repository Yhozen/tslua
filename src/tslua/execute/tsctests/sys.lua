local tsctests = require("tslua.execute.tsctests")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local execute = require("tslua.execute")
local fsbaselineutil = require("tslua.testutil.fsbaselineutil")
local harnessutil = require("tslua.testutil.harnessutil")
local locale = require("tslua.locale")
local stringtestutil = require("tslua.testutil.stringtestutil")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

-- FileMap: a Lua table path -> string contents or fstest MapFile (vfstest.Symlink(target)).

tsctests.tscLibPath = "/home/src/tslibs/TS/Lib"

tsctests.tscDefaultLibContent = stringtestutil.Dedent([[
/// <reference no-default-lib="true"/>
interface Boolean {}
interface Function {}
interface CallableFunction {}
interface NewableFunction {}
interface IArguments {}
interface Number { toExponential: any; }
interface Object {}
interface RegExp {}
interface String { charAt: any; }
interface Array<T> { length: number; [n: number]: T; }
interface ReadonlyArray<T> {}
interface SymbolConstructor {
    (desc?: string | number): symbol;
    for(name: string): symbol;
    readonly toStringTag: symbol;
}
declare var Symbol: SymbolConstructor;
interface Symbol {
    readonly [Symbol.toStringTag]: string;
}
declare const console: { log(msg: any): void; };
]])

function tsctests.getTestLibPathFor(libName)
    local libFile
    local value, ok = tsoptions.LibMap:Get(libName)
    if ok then
        libFile = value
    else
        libFile = "lib." .. libName .. ".d.ts"
    end
    return tsctests.tscLibPath .. "/" .. libFile
end

-- Times are integer seconds (time.Time{} is 0); durations are seconds.
local TestClock = {}
TestClock.__index = TestClock
tsctests.TestClock = TestClock

function TestClock:Now()
    if self.now == 0 then
        self.now = self.start
    end
    self.now = self.now + 1 -- Simulate some time passing
    return self.now
end

function TestClock:SinceStart()
    return self:Now() - self.start
end

-- io.Writer over a strings.Builder (Go *strings.Builder implements both Write and WriteString).
local builderWriter = {}
builderWriter.__index = builderWriter

function tsctests.newBuilder()
    return setmetatable({ sb = core.NewStringBuilder() }, builderWriter)
end

function builderWriter:WriteString(s)
    return self.sb:WriteString(s)
end

function builderWriter:Write(s)
    return self.sb:WriteString(s)
end

function builderWriter:String()
    return self.sb:String()
end

function builderWriter:Len()
    return self.sb:Len()
end

function builderWriter:Reset()
    self.sb:Reset()
end

local function fprintln(w, s)
    w:WriteString(s .. "\n")
end

function tsctests.NewTscSystem(files, useCaseSensitiveFileNames, cwd)
    local clock = setmetatable({ start = os.time(), now = 0 }, TestClock)
    return setmetatable({
        fs = tsctests.newTestFs(vfstest.FromMapWithClock(files, useCaseSensitiveFileNames, clock)),
        cwd = cwd,
        clock = clock,
        defaultLibraryPath = "",
        forIncrementalCorrectness = false,
        programBaselines = tsctests.newBuilder(),
        programIncludeBaselines = tsctests.newBuilder(),
    }, tsctests.TestSys)
end

function tsctests.GetFileMapWithBuild(files, commandLineArgs)
    local clone = {}
    for k, v in pairs(files) do
        clone[k] = v
    end
    local sys = tsctests.newTestSys(tsctests.newTscInput({
        files = clone,
    }), false)
    execute.CommandLine(nil, sys, commandLineArgs, sys)
    sys.fs.writtenFiles:Range(function(key)
        local text, ok = sys:fsFromFileMap():ReadFile(key)
        if ok then
            files[key] = text
        end
        return true
    end)
    return files
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

function tsctests.newTestSys(tscInput, forIncrementalCorrectness)
    local cwd = tscInput.cwd
    if cwd == "" then
        cwd = "/home/src/workspaces/project"
    end
    local libPath = tsctests.tscLibPath
    if tscInput.windowsStyleRoot ~= "" then
        libPath = tscInput.windowsStyleRoot .. string.sub(libPath, 2)
    end
    local currentWrite = tsctests.newBuilder()
    local sys = tsctests.NewTscSystem(tscInput.files, not tscInput.ignoreCase, cwd)
    sys.defaultLibraryPath = libPath
    sys.currentWrite = currentWrite
    sys.tracer = harnessutil.NewTracerForBaselining({
        useCaseSensitiveFileNames = not tscInput.ignoreCase,
        currentDirectory = cwd,
    }, currentWrite)
    sys.env = tscInput.env
    sys.forIncrementalCorrectness = forIncrementalCorrectness
    sys.mockWatchBackend = tsctests.NewMockWatchBackend()
    local underlying = sys.fs.fs
    sys.mockWatchBackend.directoryExists = function(p)
        return underlying:DirectoryExists(p)
    end
    sys.mockWatchBackend.useCaseSensitiveFileNames = not tscInput.ignoreCase
    sys.fsDiffer = fsbaselineutil.NewFSDiffer({
        fs = sys.fs.fs,
        defaultLibs = function()
            return sys.fs.defaultLibs
        end,
        writtenFiles = sys.fs.writtenFiles,
    })

    -- Ensure the default library file is present
    sys:ensureLibPathExists("lib.d.ts")
    -- Go ranges over a map here; any order is fine, use a sorted one
    local targetLibs = {}
    for _, libFile in pairs(tsoptions.TargetToLibMap()) do
        targetLibs[#targetLibs + 1] = libFile
    end
    table.sort(targetLibs)
    for _, libFile in ipairs(targetLibs) do
        sys:ensureLibPathExists(libFile)
    end
    for _, libFile in ipairs(sortedKeys(tsoptions.LibFilesSet:Keys() or {})) do
        sys:ensureLibPathExists(libFile)
    end
    return sys
end

-- TestSys implements tsc.System and tsc.CommandLineTesting.
local TestSys = {}
TestSys.__index = TestSys
tsctests.TestSys = TestSys

function TestSys:Now()
    return self.clock:Now()
end

function TestSys:SinceStart()
    return self.clock:SinceStart()
end

function TestSys:FS()
    return self.fs
end

function TestSys:fsFromFileMap()
    return self.fsDiffer.fs
end

function TestSys:mapFs()
    return self.fsDiffer:MapFs()
end

function TestSys:ensureLibPathExists(path)
    path = self.defaultLibraryPath .. "/" .. path
    local _, ok = self:fsFromFileMap():ReadFile(path)
    if not ok then
        if self.fs.defaultLibs == nil then
            self.fs.defaultLibs = collections.NewSyncSet()
        end
        self.fs.defaultLibs:Add(path)
        local err = self:fsFromFileMap():WriteFile(path, tsctests.tscDefaultLibContent)
        if err ~= nil then
            error("Failed to write default library file: " .. tostring(err), 0)
        end
    end
end

function TestSys:DefaultLibraryPath()
    return self.defaultLibraryPath
end

function TestSys:GetCurrentDirectory()
    return self.cwd
end

function TestSys:Writer()
    return self.currentWrite
end

function TestSys:ErrorWriter()
    return self.currentWrite
end

function TestSys:WriteOutputIsTTY()
    return true
end

function TestSys:GetWidthOfTerminal()
    local widthStr = self:GetEnvironmentVariable("TS_TEST_TERMINAL_WIDTH")
    if widthStr ~= "" then
        local n = math.tointeger(tonumber(widthStr))
        if n == nil then
            error("strconv.Atoi: parsing " .. string.format("%q", widthStr) .. ": invalid syntax", 0)
        end
        return n
    end
    return 0
end

function TestSys:GetEnvironmentVariable(name)
    if self.env == nil then
        return ""
    end
    return self.env[name] or ""
end

-- Spawn serves the fake content mappers in-process, selecting the implementation by the exec command the
-- mapper package declares (see internal/testutil/contentmappertest), so tests exercise the full IPC stack
-- without spawning a subprocess.
function TestSys:Spawn(command, dir, stderr)
    local contentmappertest = require("tslua.testutil.contentmappertest")
    return contentmappertest.NewSpawner():Spawn(command, dir, stderr)
end

function TestSys:OnEmittedFiles(result, mTimesCache)
    if result ~= nil then
        for _, file in ipairs(result.emittedFiles or {}) do
            local modTime = self:mapFs():GetModTime(file)
            local serializedDiff = self.fsDiffer:SerializedDiff()
            if serializedDiff ~= nil then
                local diff = serializedDiff.snap[file]
                if diff ~= nil and diff.mTime == modTime then
                    -- Even though written, timestamp was reverted
                    goto continue
                end
            end

            do
                -- Ensure that the timestamp for emitted files is in the order
                local now = self:Now()
                local err = self:fsFromFileMap():Chtimes(file, 0, now)
                if err ~= nil then
                    error("Failed to change time for emitted file: " .. file .. ": " .. tostring(err), 0)
                end
                -- Update the mTime cache in --b mode to store the updated timestamp so tests will behave deteministically when finding newest output
                if mTimesCache ~= nil then
                    local path = tspath.ToPath(file, self:GetCurrentDirectory(), self:FS():UseCaseSensitiveFileNames())
                    local _, found = mTimesCache:Load(path)
                    if found then
                        mTimesCache:Store(path, now)
                    end
                end
            end
            ::continue::
        end
    end
end

-- Go fmt.Fprintln(w, listFileStart) etc.
function TestSys:OnListFilesStart(w)
    fprintln(w, tsctests.listFileStart)
end

function TestSys:OnListFilesEnd(w)
    fprintln(w, tsctests.listFileEnd)
end

function TestSys:OnStatisticsStart(w)
    fprintln(w, tsctests.statisticsStart)
end

function TestSys:OnStatisticsEnd(w)
    fprintln(w, tsctests.statisticsEnd)
end

function TestSys:OnBuildStatusReportStart(w)
    fprintln(w, tsctests.buildStatusReportStart)
end

function TestSys:OnBuildStatusReportEnd(w)
    fprintln(w, tsctests.buildStatusReportEnd)
end

function TestSys:OnWatchStatusReportStart()
    fprintln(self:Writer(), tsctests.watchStatusReportStart)
end

function TestSys:OnWatchStatusReportEnd()
    fprintln(self:Writer(), tsctests.watchStatusReportEnd)
end

function TestSys:GetTrace(w, loc)
    return function(msg, ...)
        fprintln(w, tsctests.traceStart)
        -- With tsc -b building projects in parallel we cannot serialize the package.json lookup trace
        -- so trace as if it wasnt cached
        local str = msg:Localize(loc, ...)
        self.tracer:TraceWithWriter(w, str, w == self:Writer())
        fprintln(w, tsctests.traceEnd)
    end
end

function TestSys:writeHeaderToBaseline(builder, program)
    if builder:Len() ~= 0 then
        builder:WriteString("\n")
    end

    local configFilePath = program:Options().configFilePath
    if configFilePath ~= nil and configFilePath ~= "" then
        builder:WriteString(tspath.GetRelativePathFromDirectory(self.cwd, configFilePath, {
            useCaseSensitiveFileNames = self:FS():UseCaseSensitiveFileNames(),
            currentDirectory = self:GetCurrentDirectory(),
        }))
        builder:WriteString("::\n")
    end
end

function TestSys:WatchBackend()
    return self.mockWatchBackend
end

function TestSys:OnProgram(program)
    self:writeHeaderToBaseline(self.programBaselines, program)

    local testingData = program:GetTestingData()
    self.programBaselines:WriteString("SemanticDiagnostics::\n")
    for _, file in ipairs(program:GetProgram():GetSourceFiles()) do
        local diags, ok = testingData.semanticDiagnosticsPerFile:Load(file:Path())
        if ok then
            local oldDiagnostics, ok2 = testingData.oldProgramSemanticDiagnosticsPerFile:Load(file:Path())
            if not ok2 or oldDiagnostics ~= diags then
                self.programBaselines:WriteString("*refresh*    ")
                self.programBaselines:WriteString(file:FileName())
                self.programBaselines:WriteString("\n")
            end
        else
            self.programBaselines:WriteString("*not cached* ")
            self.programBaselines:WriteString(file:FileName())
            self.programBaselines:WriteString("\n")
        end
    end

    -- Write signature updates
    self.programBaselines:WriteString("Signatures::\n")
    local incremental = require("tslua.execute.incremental")
    for _, file in ipairs(program:GetProgram():GetSourceFiles()) do
        local kind = testingData.updatedSignatureKinds ~= nil and testingData.updatedSignatureKinds[file:Path()] or nil
        if kind ~= nil then
            if kind == incremental.SignatureUpdateKind.ComputedDts then
                self.programBaselines:WriteString("(computed .d.ts) ")
                self.programBaselines:WriteString(file:FileName())
                self.programBaselines:WriteString("\n")
            elseif kind == incremental.SignatureUpdateKind.StoredAtEmit then
                self.programBaselines:WriteString("(stored at emit) ")
                self.programBaselines:WriteString(file:FileName())
                self.programBaselines:WriteString("\n")
            elseif kind == incremental.SignatureUpdateKind.UsedVersion then
                self.programBaselines:WriteString("(used version)   ")
                self.programBaselines:WriteString(file:FileName())
                self.programBaselines:WriteString("\n")
            end
        end
    end

    local filesWithoutIncludeReason = {}
    local fileNotInProgramWithIncludeReason = {}
    local includeReasons = program:GetProgram():GetIncludeReasons() or {}
    for _, file in ipairs(program:GetProgram():GetSourceFiles()) do
        if includeReasons[file:Path()] == nil then
            filesWithoutIncludeReason[#filesWithoutIncludeReason + 1] = file:Path()
        end
    end
    -- Go ranges over a map; sort for determinism
    for _, path in ipairs(sortedKeys(includeReasons)) do
        if program:GetProgram():GetSourceFileByPath(path) == nil and not program:GetProgram():IsMissingPath(path) then
            fileNotInProgramWithIncludeReason[#fileNotInProgramWithIncludeReason + 1] = path
        end
    end
    if #filesWithoutIncludeReason > 0 or #fileNotInProgramWithIncludeReason > 0 then
        self:writeHeaderToBaseline(self.programIncludeBaselines, program)
        self.programIncludeBaselines:WriteString("!!! Expected all files to have include reasons\nfilesWithoutIncludeReason::\n")
        for _, file in ipairs(filesWithoutIncludeReason) do
            self.programIncludeBaselines:WriteString("  ")
            self.programIncludeBaselines:WriteString(file)
            self.programIncludeBaselines:WriteString("\n")
        end
        self.programIncludeBaselines:WriteString("filesNotInProgramWithIncludeReason::\n")
        for _, file in ipairs(fileNotInProgramWithIncludeReason) do
            self.programIncludeBaselines:WriteString("  ")
            self.programIncludeBaselines:WriteString(file)
            self.programIncludeBaselines:WriteString("\n")
        end
    end
end

function TestSys:baselinePrograms(baseline, header)
    baseline:WriteString(self.programBaselines:String())
    self.programBaselines:Reset()
    local result = ""
    if self.programIncludeBaselines:Len() > 0 then
        result = result .. "\n\n" .. header .. "\n!!! Include reasons expectations don't match pls review!!!\n"
        result = result .. self.programIncludeBaselines:String()
        self.programIncludeBaselines:Reset()
        baseline:WriteString(result)
    end
    return result
end

function TestSys:serializeState(baseline)
    self:baselineOutput(baseline)
    self:baselineFSwithDiff(baseline)
    -- todo watch
    -- this.serializeWatches(baseline);
    -- this.timeoutCallbacks.serialize(baseline);
    -- this.immediateCallbacks.serialize(baseline);
    -- this.pendingInstalls.serialize(baseline);
    -- this.service?.baseline();
end

tsctests.fakeTimeStamp = "HH:MM:SS AM"
tsctests.fakeDuration = "d.ddds"

tsctests.buildStartingAt = "build starting at "
tsctests.buildFinishedIn = "build finished in "
tsctests.listFileStart = "!!! List files start"
tsctests.listFileEnd = "!!! List files end"
tsctests.statisticsStart = "!!! Statistics start"
tsctests.statisticsEnd = "!!! Statistics end"
tsctests.buildStatusReportStart = "!!! Build Status Report Start"
tsctests.buildStatusReportEnd = "!!! Build Status Report End"
tsctests.watchStatusReportStart = "!!! Watch Status Report Start"
tsctests.watchStatusReportEnd = "!!! Watch Status Report End"
tsctests.traceStart = "!!! Trace start"
tsctests.traceEnd = "!!! Trace end"

function TestSys:baselineOutput(baseline)
    baseline:WriteString("\nOutput::\n")
    local output = self:getOutput(false)
    baseline:WriteString(output)
end

-- outputSanitizer: { forComparing = bool, lines = []string, index = 0-based, outputLines = []string }
local outputSanitizer = {}
outputSanitizer.__index = outputSanitizer
tsctests.outputSanitizer = outputSanitizer

-- Localization is English only, so the Czech version strings are the English ones.
tsctests.englishVersion = diagnostics.Version_0:Localize(locale.Default, core.Version())
tsctests.fakeEnglishVersion = diagnostics.Version_0:Localize(locale.Default, harnessutil.FakeTSVersion)
tsctests.czechVersion = diagnostics.Version_0:Localize("cs", core.Version())
tsctests.fakeCzechVersion = diagnostics.Version_0:Localize("cs", harnessutil.FakeTSVersion)

-- strings.ReplaceAll
local function replaceAll(s, old, new)
    if old == "" then
        error("replaceAll: empty old string", 0)
    end
    local out = {}
    local pos = 1
    while true do
        local i = string.find(s, old, pos, true)
        if i == nil then
            break
        end
        out[#out + 1] = string.sub(s, pos, i - 1)
        out[#out + 1] = new
        pos = i + #old
    end
    if pos == 1 then
        return s
    end
    out[#out + 1] = string.sub(s, pos)
    return table.concat(out)
end
tsctests.replaceAll = replaceAll

-- strings.Replace(s, old, new, 1)
local function replaceOnce(s, old, new)
    local i = string.find(s, old, 1, true)
    if i == nil then
        return s
    end
    return string.sub(s, 1, i - 1) .. new .. string.sub(s, i + #old)
end
tsctests.replaceOnce = replaceOnce

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function outputSanitizer:addOutputLine(s)
    s = replaceAll(s, "'" .. core.Version() .. "'", "'" .. harnessutil.FakeTSVersion .. "'")
    s = replaceAll(s, tsctests.englishVersion, tsctests.fakeEnglishVersion)
    s = replaceAll(s, tsctests.czechVersion, tsctests.fakeCzechVersion)
    s = fsbaselineutil.SanitizeInternalSymbolName(s)
    self.outputLines[#self.outputLines + 1] = s
end

function outputSanitizer:sanitizeBuildStatusTimeStamp()
    local statusLine = self.lines[self.index + 1]
    local hhSeparator = (string.find(statusLine, ":", 1, true) or 0) - 1
    if hhSeparator < 2 then
        error("Expected timestamp", 0)
    end
    return string.sub(statusLine, 1, hhSeparator - 2) .. tsctests.fakeTimeStamp .. string.sub(statusLine, hhSeparator + #tsctests.fakeTimeStamp - 2 + 1)
end

function outputSanitizer:transformLines()
    while self.index < #self.lines do
        local line = self.lines[self.index + 1]
        if hasPrefix(line, tsctests.buildStartingAt) then
            if not self.forComparing then
                self:addOutputLine(tsctests.buildStartingAt .. tsctests.fakeTimeStamp)
            end
            goto continue
        end
        if hasPrefix(line, tsctests.buildFinishedIn) then
            if not self.forComparing then
                self:addOutputLine(tsctests.buildFinishedIn .. tsctests.fakeDuration)
            end
            goto continue
        end
        if not self:addOrSkipLinesForComparing(tsctests.listFileStart, tsctests.listFileEnd, false, nil)
            and not self:addOrSkipLinesForComparing(tsctests.statisticsStart, tsctests.statisticsEnd, true, nil)
            and not self:addOrSkipLinesForComparing(tsctests.traceStart, tsctests.traceEnd, false, nil)
            and not self:addOrSkipLinesForComparing(tsctests.buildStatusReportStart, tsctests.buildStatusReportEnd, false, self.sanitizeBuildStatusTimeStamp)
            and not self:addOrSkipLinesForComparing(tsctests.watchStatusReportStart, tsctests.watchStatusReportEnd, false, self.sanitizeBuildStatusTimeStamp) then
            self:addOutputLine(line)
        end
        ::continue::
        self.index = self.index + 1
    end
    return table.concat(self.outputLines, "\n")
end

-- sanitizeFirstLine is a method of outputSanitizer (Go method value o.sanitizeBuildStatusTimeStamp) or nil.
function outputSanitizer:addOrSkipLinesForComparing(lineStart, lineEnd, skipEvenIfNotComparing, sanitizeFirstLine)
    if self.lines[self.index + 1] ~= lineStart then
        return false
    end
    self.index = self.index + 1
    local isFirstLine = true
    while self.index < #self.lines do
        if self.lines[self.index + 1] == lineEnd then
            return true
        end
        if not self.forComparing and not skipEvenIfNotComparing then
            local line = self.lines[self.index + 1]
            if isFirstLine and sanitizeFirstLine ~= nil then
                line = sanitizeFirstLine(self)
                isFirstLine = false
            end
            self:addOutputLine(line)
        end
        self.index = self.index + 1
    end
    error("Expected lineEnd" .. lineEnd .. " not found after " .. lineStart, 0)
end

-- strings.Split(s, "\n")
local function splitNewline(s)
    local lines = {}
    local start = 1
    while true do
        local i = string.find(s, "\n", start, true)
        if i == nil then
            lines[#lines + 1] = string.sub(s, start)
            return lines
        end
        lines[#lines + 1] = string.sub(s, start, i - 1)
        start = i + 1
    end
end

function TestSys:getOutput(forComparing)
    local lines = splitNewline(self.currentWrite:String())
    local transformer = setmetatable({
        forComparing = forComparing,
        lines = lines,
        index = 0,
        outputLines = {},
    }, outputSanitizer)
    return transformer:transformLines()
end

function TestSys:clearOutput()
    self.currentWrite:Reset()
    self.tracer:Reset()
end

function TestSys:baselineFSwithDiff(baseline)
    self.fsDiffer:BaselineFSwithDiff(baseline)
end

function TestSys:writeFileNoError(path, content)
    local err = self:fsFromFileMap():WriteFile(path, content)
    if err ~= nil then
        error(err, 0)
    end
end

function TestSys:removeNoError(path)
    local err = self:fsFromFileMap():Remove(path)
    if err ~= nil then
        error(err, 0)
    end
end

function TestSys:readFileNoError(path)
    local content, ok = self:fsFromFileMap():ReadFile(path)
    if not ok then
        error("File not found: " .. path, 0)
    end
    return content
end

function TestSys:renameFileNoError(oldPath, newPath)
    self:writeFileNoError(newPath, self:readFileNoError(oldPath))
    self:removeNoError(oldPath)
end

function TestSys:replaceFileText(path, oldText, newText)
    local content = self:readFileNoError(path)
    content = replaceOnce(content, oldText, newText)
    self:writeFileNoError(path, content)
end

function TestSys:replaceFileTextAll(path, oldText, newText)
    local content = self:readFileNoError(path)
    content = replaceAll(content, oldText, newText)
    self:writeFileNoError(path, content)
end

function TestSys:appendFile(path, text)
    local content = self:readFileNoError(path)
    self:writeFileNoError(path, content .. text)
end

function TestSys:prependFile(path, text)
    local content = self:readFileNoError(path)
    self:writeFileNoError(path, text .. content)
end
