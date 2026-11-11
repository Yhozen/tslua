-- Lua-only support code (no Go counterpart file): a minimal stand-in for Go's `testing.T` and the
-- gotest.tools `assert` helpers used by the ported test harness.
--
--   t:Run(name, fn)         runs fn(subT) as a subtest; returns true if it passed (or was skipped)
--   t:Error/Errorf          marks the test failed and records the message, continues
--   t:Fatal/Fatalf/FailNow  marks failed and stops the (sub)test (raises a signal caught by Run)
--   t:Skip/Skipf/SkipNow    marks skipped and stops the (sub)test
--   t:Helper(), t:Parallel(), t:Log/Logf, t:Context() (nil, Go context.Background())
--
-- Panics (Lua errors that are not testing signals) inside Run are caught too: the test is marked
-- failed, and `panicked` holds the error value and its traceback (Go would crash the test binary
-- unless the test recovers, which the harness always does through testutil.RecoverAndFail).
--
-- Every T keeps its results: name, failed, skipped, messages (array of strings), children
-- (array of subtests in run order), panicked ({ err, traceback } or nil).
local testutil = require("tslua.testutil")

local T = {}
T.__index = T
testutil.T = T

local signalFatal = { testingSignal = "fatal" }
local signalSkip = { testingSignal = "skip" }
testutil.signalFatal = signalFatal
testutil.signalSkip = signalSkip

function testutil.IsTestingSignal(err)
    return err == signalFatal or err == signalSkip
end

function testutil.NewT(name, parent)
    local fullName = name
    if parent ~= nil and parent.fullName ~= "" then
        fullName = parent.fullName .. "/" .. name
    end
    return setmetatable({
        name = name,
        fullName = fullName,
        parent = parent,
        failed = false,
        skipped = false,
        messages = {},
        children = {},
        panicked = nil,
        -- Lua-only: optional callback(t, message) invoked for every recorded failure message.
        onMessage = parent and parent.onMessage or nil,
    }, T)
end

-- Go fmt.Sprintf for the verbs used by the harness: %s %v %d %q %%. %v of a table with an
-- Error() method prints the error text.
function testutil.Sprintf(format, ...)
    local args = table.pack(...)
    local i = 0
    local result = string.gsub(format, "%%([%-%d%.]*)([%a%%])", function(flags, verb)
        if verb == "%" then
            return "%"
        end
        i = i + 1
        local v = args[i]
        if verb == "q" then
            return string.format("%q", tostring(v))
        elseif verb == "d" then
            if math.type(v) == "float" and v == math.floor(v) then
                v = math.tointeger(v)
            end
            return string.format("%" .. flags .. "d", v)
        end
        local s
        if type(v) == "table" and v.Error ~= nil then
            s = v:Error()
        elseif v == nil then
            s = "<nil>"
        else
            s = tostring(v)
        end
        if flags ~= "" then
            return string.format("%" .. flags .. "s", s)
        end
        return s
    end)
    return result
end

local function sprint(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "table" and v.Error ~= nil then
            parts[i] = v:Error()
        else
            parts[i] = tostring(v)
        end
    end
    return table.concat(parts, " ")
end

function T:Name()
    return self.fullName
end

function T:Helper()
end

function T:Parallel()
end

function T:Context()
    return nil
end

function T:addMessage(msg)
    self.messages[#self.messages + 1] = msg
    if self.onMessage ~= nil then
        self.onMessage(self, msg)
    end
end

function T:Log(...)
    self.messages[#self.messages + 1] = sprint(...)
end

function T:Logf(format, ...)
    self.messages[#self.messages + 1] = testutil.Sprintf(format, ...)
end

function T:Fail()
    self.failed = true
    local p = self.parent
    while p ~= nil do
        p.failed = true
        p = p.parent
    end
end

function T:Failed()
    return self.failed
end

function T:Skipped()
    return self.skipped
end

function T:Error(...)
    self:addMessage(sprint(...))
    self:Fail()
end

function T:Errorf(format, ...)
    self:addMessage(testutil.Sprintf(format, ...))
    self:Fail()
end

function T:FailNow()
    self:Fail()
    error(signalFatal, 0)
end

function T:Fatal(...)
    self:addMessage(sprint(...))
    self:FailNow()
end

function T:Fatalf(format, ...)
    self:addMessage(testutil.Sprintf(format, ...))
    self:FailNow()
end

function T:SkipNow()
    self.skipped = true
    error(signalSkip, 0)
end

function T:Skip(...)
    self.messages[#self.messages + 1] = sprint(...)
    self:SkipNow()
end

function T:Skipf(format, ...)
    self.messages[#self.messages + 1] = testutil.Sprintf(format, ...)
    self:SkipNow()
end

local function traceback(err)
    if testutil.IsTestingSignal(err) then
        return err
    end
    return { err = err, traceback = debug.traceback(tostring(type(err) == "table" and err.Error and err:Error() or err), 2) }
end

-- runProtected runs fn(t) and turns testing signals and panics into results on t.
function testutil.runProtected(t, fn)
    local ok, err = xpcall(fn, traceback, t)
    if ok then
        return
    end
    if testutil.IsTestingSignal(err) then
        return
    end
    t.panicked = err
    t:addMessage("panic: " .. tostring(err.traceback))
    t:Fail()
end

function T:Run(name, fn)
    local sub = testutil.NewT(name, self)
    self.children[#self.children + 1] = sub
    testutil.runProtected(sub, fn)
    return not sub.failed
end

-- gotest.tools assert.Assert: fails and stops the test if cond is false.
function testutil.Assert(t, cond, ...)
    if not cond then
        local msg = "assertion failed"
        if select("#", ...) > 0 then
            msg = msg .. ": " .. testutil.Sprintf(...)
        end
        t:Fatal(msg)
    end
end

-- gotest.tools assert.Check(t, cmp.Equal(x, y), msg): records a failure and continues.
function testutil.CheckEqual(t, x, y, ...)
    if x ~= y then
        local msg = "assertion failed: " .. tostring(x) .. " (x) != " .. tostring(y) .. " (y)"
        if select("#", ...) > 0 then
            msg = msg .. ": " .. testutil.Sprintf(...)
        end
        t:Error(msg)
        return false
    end
    return true
end

-- gotest.tools assert.Equal: fails and stops the test if x ~= y.
function testutil.AssertEqual(t, x, y, ...)
    if not testutil.CheckEqual(t, x, y, ...) then
        t:FailNow()
    end
end

return testutil
