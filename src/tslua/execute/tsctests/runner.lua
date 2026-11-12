local tsctests = require("tslua.execute.tsctests")
local baseline = require("tslua.testutil.baseline")
local execute = require("tslua.execute")
local tsc = require("tslua.execute.tsc")
local tspath = require("tslua.tspath")

local ExitStatus = tsc.ExitStatus

-- tscEdit: { caption = "", commandLineArgs = []string or nil, edit = func(sys) or nil, expectedDiff = "" }
function tsctests.newTscEdit(fields)
    return {
        caption = fields.caption or "",
        commandLineArgs = fields.commandLineArgs,
        edit = fields.edit,
        expectedDiff = fields.expectedDiff or "",
    }
end

tsctests.noChange = tsctests.newTscEdit({
    caption = "no change",
})

tsctests.noChangeOnlyEdit = {
    tsctests.noChange,
}

-- tscInput: { subScenario, commandLineArgs ([]string or nil), files (FileMap), cwd, edits ([]*tscEdit),
--   env (map or nil), ignoreCase, windowsStyleRoot }
local tscInput = {}
tscInput.__index = tscInput
tsctests.tscInput = tscInput

function tsctests.newTscInput(fields)
    return setmetatable({
        subScenario = fields.subScenario or "",
        commandLineArgs = fields.commandLineArgs,
        files = fields.files or {},
        cwd = fields.cwd or "",
        edits = fields.edits,
        env = fields.env,
        ignoreCase = fields.ignoreCase or false,
        windowsStyleRoot = fields.windowsStyleRoot or "",
    }, tscInput)
end

function tscInput:executeCommand(ctx, sys, baselineBuilder, commandLineArgs)
    baselineBuilder:WriteString("tsgo " .. table.concat(commandLineArgs or {}, " ") .. "\n")
    local result = execute.CommandLine(ctx, sys, commandLineArgs or {}, sys)
    local status = result.status
    if status == ExitStatus.Success then
        baselineBuilder:WriteString("ExitStatus:: Success")
    elseif status == ExitStatus.DiagnosticsPresent_OutputsSkipped then
        baselineBuilder:WriteString("ExitStatus:: DiagnosticsPresent_OutputsSkipped")
    elseif status == ExitStatus.DiagnosticsPresent_OutputsGenerated then
        baselineBuilder:WriteString("ExitStatus:: DiagnosticsPresent_OutputsGenerated")
    elseif status == ExitStatus.InvalidProject_OutputsSkipped then
        baselineBuilder:WriteString("ExitStatus:: InvalidProject_OutputsSkipped")
    elseif status == ExitStatus.ProjectReferenceCycle_OutputsSkipped then
        baselineBuilder:WriteString("ExitStatus:: ProjectReferenceCycle_OutputsSkipped")
    elseif status == ExitStatus.NotImplemented then
        baselineBuilder:WriteString("ExitStatus:: NotImplemented")
    else
        error(string.format("UnknownExitStatus %s", tostring(status)), 0)
    end
    return result
end

function tscInput:run(t, scenario)
    t:Helper()
    local test = self
    if type(test.files) == "function" then
        -- Lua-only: a FileMap computed by running a build (GetFileMapWithBuild) is deferred until the
        -- scenario runs (Go evaluates it when the test function builds its case list).
        test.files = test.files()
    end
    t:Run(test:getBaselineSubFolder() .. "/" .. test.subScenario, function(t2)
        t2:Parallel()
        -- ctx is cancelled when the subtest ends, tearing down any content mapper host created during the run.
        local ctx = t2:Context()
        -- initial test tsc compile
        local baselineBuilder = tsctests.newBuilder()
        local sys = tsctests.newTestSys(test, false)
        baselineBuilder:WriteString(
            "currentDirectory::" .. sys:GetCurrentDirectory()
            .. "\nuseCaseSensitiveFileNames::" .. tostring(sys:FS():UseCaseSensitiveFileNames())
            .. "\nInput::\n"
        )
        sys:baselineFSwithDiff(baselineBuilder)
        local result = test:executeCommand(ctx, sys, baselineBuilder, test.commandLineArgs)
        sys:serializeState(baselineBuilder)
        if result.watcher ~= nil and sys.mockWatchBackend:HasWatches() then
            baselineBuilder:WriteString(sys.mockWatchBackend:WatchState())
        end
        local unexpectedDiff = tsctests.newBuilder()
        unexpectedDiff:WriteString(sys:baselinePrograms(baselineBuilder, "Initial build"))

        for index1, do_ in ipairs(test.edits or {}) do
            local index = index1 - 1
            sys:clearOutput()
            local nonIncrementalSys
            local commandLineArgs = do_.commandLineArgs
            if commandLineArgs == nil then
                commandLineArgs = test.commandLineArgs
            end
            -- Go queues these two on a work group; sequentially, in queue order.
            do
                baselineBuilder:WriteString(string.format("\n\nEdit [%d]:: %s\n", index, do_.caption))
                if do_.edit ~= nil then
                    do_.edit(sys)
                end
                local changedPaths = sys.fsDiffer:ChangedPaths()
                sys:baselineFSwithDiff(baselineBuilder)

                if result.watcher == nil then
                    test:executeCommand(ctx, sys, baselineBuilder, commandLineArgs)
                else
                    sys.mockWatchBackend:SendChangedPaths(changedPaths)
                    result.watcher:DoCycle()
                end
                sys:serializeState(baselineBuilder)
                if result.watcher ~= nil and sys.mockWatchBackend:HasWatches() then
                    baselineBuilder:WriteString(sys.mockWatchBackend:WatchState())
                end
                unexpectedDiff:WriteString(sys:baselinePrograms(baselineBuilder, string.format("Edit [%d]:: %s\n", index, do_.caption)))
            end
            do
                -- Compute build with all the edits
                nonIncrementalSys = tsctests.newTestSys(test, true)
                for i = 0, index do
                    if test.edits[i + 1].edit ~= nil then
                        test.edits[i + 1].edit(nonIncrementalSys)
                    end
                end
                execute.CommandLine(ctx, nonIncrementalSys, commandLineArgs or {}, nonIncrementalSys)
            end

            local diff = tsctests.getDiffForIncremental(sys, nonIncrementalSys)
            if diff ~= "" then
                local explanation = do_.expectedDiff
                if explanation == "" then
                    explanation = "!!! Unexpected diff, please review and either fix or write explanation as expectedDiff !!!"
                end
                baselineBuilder:WriteString(string.format("\n\nDiff:: %s\n", explanation))
                baselineBuilder:WriteString(diff)
                if do_.expectedDiff == "" then
                    unexpectedDiff:WriteString(string.format("Edit [%d]:: %s\n!!! Unexpected diff, please review and either fix or write explanation as expectedDiff !!!\n%s\n", index, do_.caption, diff))
                end
            elseif do_.expectedDiff ~= "" then
                baselineBuilder:WriteString(string.format("\n\nDiff:: %s !!! Diff not found but explanation present, please review and remove the explanation !!!\n", do_.expectedDiff))
                unexpectedDiff:WriteString(string.format("Edit [%d]:: %s\n!!! Diff not found but explanation present, please review and remove the explanation !!!\n", index, do_.caption))
            end
        end
        baseline.Run(t2, tsctests.replaceAll(test.subScenario, " ", "-") .. ".js", baselineBuilder:String(), { subfolder = test:getBaselineSubFolder() .. "/" .. scenario })
        if unexpectedDiff:String() ~= "" then
            t2:Errorf("Test %s has unexpected diff %s with incremental build, please review the baseline file", test.subScenario, unexpectedDiff:String())
        end
    end)
end

function tsctests.getDiffForIncremental(incrementalSys, nonIncrementalSys)
    local diffBuilder = tsctests.newBuilder()

    local nonIncrementalOutputs = nonIncrementalSys.fs.writtenFiles:ToSlice()
    table.sort(nonIncrementalOutputs)
    for _, nonIncrementalOutput in ipairs(nonIncrementalOutputs) do
        if tspath.FileExtensionIs(nonIncrementalOutput, tspath.ExtensionTsBuildInfo)
            or string.sub(nonIncrementalOutput, -#".readable.baseline.txt") == ".readable.baseline.txt" then
            -- Just check existence
            if not incrementalSys:fsFromFileMap():FileExists(nonIncrementalOutput) then
                diffBuilder:WriteString(baseline.DiffText("nonIncremental " .. nonIncrementalOutput, "incremental " .. nonIncrementalOutput, "Exists", ""))
                diffBuilder:WriteString("\n")
            end
        else
            local nonIncrementalText, ok = nonIncrementalSys:fsFromFileMap():ReadFile(nonIncrementalOutput)
            if not ok then
                error("Written file not found " .. nonIncrementalOutput, 0)
            end
            local incrementalText, ok2 = incrementalSys:fsFromFileMap():ReadFile(nonIncrementalOutput)
            if not ok2 or incrementalText ~= nonIncrementalText then
                diffBuilder:WriteString(baseline.DiffText("nonIncremental " .. nonIncrementalOutput, "incremental " .. nonIncrementalOutput, nonIncrementalText, incrementalText or ""))
                diffBuilder:WriteString("\n")
            end
        end
    end

    local incrementalOutput = incrementalSys:getOutput(true)
    local nonIncrementalOutput = nonIncrementalSys:getOutput(true)
    if incrementalOutput ~= nonIncrementalOutput then
        diffBuilder:WriteString(baseline.DiffText("nonIncremental.output.txt", "incremental.output.txt", nonIncrementalOutput, incrementalOutput))
    end
    return diffBuilder:String()
end

local function containsAny(args, set)
    for _, arg in ipairs(args or {}) do
        if set[arg] then
            return true
        end
    end
    return false
end

local buildFlags = { ["-b"] = true, ["--b"] = true, ["-build"] = true, ["--build"] = true }
local watchFlags = { ["-w"] = true, ["--w"] = true, ["-watch"] = true, ["--watch"] = true }

function tscInput:getBaselineSubFolder()
    local commandName = "tsc"
    if containsAny(self.commandLineArgs, buildFlags) then
        commandName = "tsbuild"
    end
    local w = ""
    if containsAny(self.commandLineArgs, watchFlags) then
        w = "Watch"
    end
    return commandName .. w
end
