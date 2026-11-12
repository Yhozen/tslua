-- Port of internal/execute/tsc/emit_test.go.
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local incremental = require("tslua.execute.incremental")
local jsonrpc = require("tslua.jsonrpc")
local tsc = require("tslua.execute.tsc")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

-- time.Duration and time.Time values are seconds.
local second = 1

-- io.Discard
local discard = { WriteString = function(_, s) return #s end, Write = function(_, s) return #s end }

-- bytes.Buffer
local function newBuffer()
    local b = { parts = {} }
    function b:WriteString(s)
        self.parts[#self.parts + 1] = s
        return #s
    end
    b.Write = b.WriteString
    function b:String()
        return table.concat(self.parts)
    end
    return b
end

local controlledClock = {}
controlledClock.__index = controlledClock

local fileClock = {}
fileClock.__index = fileClock

function fileClock:Now()
    self.now = self.now + second
    return self.now
end

function fileClock:SinceStart()
    return 0
end

function controlledClock:Now()
    return self.now
end

function controlledClock:NestedEmitNow()
    self.nestedEmitCalls = self.nestedEmitCalls + 1
    if self.nestedEmitInProgress then
        self.now = self.now + second
    end
    self.nestedEmitInProgress = not self.nestedEmitInProgress
    return self.now
end

function controlledClock:NestedEmitCalls()
    return self.nestedEmitCalls
end

function controlledClock:SinceStart()
    return 0
end

local timingTestSystem = {}
timingTestSystem.__index = timingTestSystem

function timingTestSystem:Writer() return discard end
function timingTestSystem:ErrorWriter() return discard end
function timingTestSystem:FS() return self.fs end
function timingTestSystem:DefaultLibraryPath() return "/lib" end
function timingTestSystem:GetCurrentDirectory() return "/project" end
function timingTestSystem:WriteOutputIsTTY() return false end
function timingTestSystem:GetWidthOfTerminal() return 0 end
function timingTestSystem:GetEnvironmentVariable(_) return "" end
function timingTestSystem:Now() return self.clock:Now() end
function timingTestSystem:SinceStart() return self.clock:SinceStart() end

function timingTestSystem:Spawn(_, _, _)
    return nil, jsonrpc.NewError("spawn not implemented in timingTestSystem")
end

-- contentMapperLoggingTestSystem embeds *timingTestSystem.
local contentMapperLoggingTestSystem = setmetatable({}, { __index = timingTestSystem })
contentMapperLoggingTestSystem.__index = contentMapperLoggingTestSystem

function contentMapperLoggingTestSystem:GetEnvironmentVariable(name)
    if name == "TS_CONTENT_MAPPER_DEBUG" and self.enabled then
        return "1"
    end
    return ""
end

function contentMapperLoggingTestSystem:ErrorWriter()
    return self.stderr
end

describe("TestContentMapperLoggerEnvironmentVariable", function()
    it("TestContentMapperLoggerEnvironmentVariable", function()
        local sys = setmetatable({ enabled = false, stderr = newBuffer() }, contentMapperLoggingTestSystem)
        assert.is_true(tsc.newContentMapperLogger(sys) == nil)
        sys.enabled = true
        local logger = tsc.newContentMapperLogger(sys)
        assert.is_true(logger ~= nil)
        -- The goroutines of the Go test run sequentially.
        for _ = 1, 10 do
            logger("mapper log")
        end
        assert.are.equal(string.rep("mapper log\n", 10), sys.stderr:String())
    end)
end)

describe("TestIncrementalDeclarationEmitTimeIsExcludedFromCheckTime", function()
    it("TestIncrementalDeclarationEmitTimeIsExcludedFromCheckTime", function()
        local files = {
            ["/lib/lib.d.ts"] = [[

interface Array<T> {}
interface Boolean {}
interface CallableFunction {}
interface Function {}
interface IArguments {}
interface NewableFunction {}
interface Number {}
interface Object {}
interface RegExp {}
interface String {}
]],
            ["/project/hub.ts"] = [[

export interface Box {
    value: string;
}
export const make = (): Box => ({ value: "ok" });
]],
            ["/project/spoke.ts"] = 'import { make, type Box } from "./hub"; export const value: Box = make();',
        }
        local clock = setmetatable({ now = 0, nestedEmitInProgress = false, nestedEmitCalls = 0 }, controlledClock)
        local sys = setmetatable({
            fs = vfstest.FromMapWithClock(files, true, setmetatable({ now = 0 }, fileClock)),
            clock = clock,
        }, timingTestSystem)
        local options = core.NewCompilerOptions({
            declaration = core.Tristate.TSTrue,
            incremental = core.Tristate.TSTrue,
            module = core.ModuleKind.ESNext,
            noEmit = core.Tristate.TSTrue,
            tsBuildInfoFile = "/project/tsconfig.tsbuildinfo",
        })
        local config = tsoptions.NewParsedCommandLine(options, { "/lib/lib.d.ts", "/project/hub.ts", "/project/spoke.ts" },
            tspath.NewComparePathsOptions(true, "/project"))

        local function compile(oldProgram)
            local host = compiler.NewCachedFSCompilerHost(sys:GetCurrentDirectory(), sys:FS(), sys:DefaultLibraryPath(), nil, nil, nil)
            local program = compiler.NewProgram(compiler.NewProgramOptions({
                config = config,
                host = host,
            }))
            if program:GetSourceFile("/lib/lib.d.ts") == nil then
                error("default library was not loaded")
            end
            local incrementalProgram = incremental.NewProgram(program, oldProgram, incremental.CreateHost(host), function()
                return clock:NestedEmitNow()
            end, false)
            local times = tsc.NewCompileTimes()
            tsc.EmitFilesAndReportErrors({
                sys = sys,
                programLike = incrementalProgram,
                program = program,
                config = config,
                reportDiagnostic = tsc.QuietDiagnosticReporter,
                reportErrorSummary = tsc.QuietDiagnosticsReporter,
                writer = discard,
                writeFile = function(fileName, text, _)
                    return sys.fs:WriteFile(fileName, text)
                end,
                compileTimes = times,
            })
            return incrementalProgram, times
        end
        local oldProgram = compile(nil)
        local err = sys.fs:WriteFile("/project/hub.ts", files["/project/hub.ts"] .. "\n// comment only change\n")
        assert.is_nil(err)
        local _, times = compile(oldProgram)

        assert.are.equal(0, times.checkTime, "check time")
        assert.are.equal(2 * second, times.emitTime, "emit time")
        assert.are.equal(4, clock:NestedEmitCalls(), "nested clock calls")
    end)
end)
