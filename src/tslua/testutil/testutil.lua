local testutil = require("tslua.testutil")

function testutil.AssertPanics(tb, fn, expected, ...)
    tb:Helper()

    local ok, got = pcall(fn)
    if ok then
        got = nil
    end

    testutil.Assert(tb, got ~= nil, ...)
    testutil.AssertEqual(tb, got, expected, ...)
end

-- Go: `defer testutil.RecoverAndFail(t, msg)` at the top of a function body. Lua has no defer,
-- so the body is passed as fn and run protected: a panic (any Lua error that is not a testing
-- signal from t:Fatal/t:Skip) fails the test with the message, the error and its stack.
function testutil.RecoverAndFail(t, msg, fn)
    local stack = nil
    local ok, r = xpcall(fn, function(err)
        if not testutil.IsTestingSignal(err) then
            stack = debug.traceback("", 2)
        end
        return err
    end)
    if ok then
        return
    end
    if testutil.IsTestingSignal(r) then
        error(r, 0)
    end
    local text = r
    if type(r) == "table" and r.Error ~= nil then
        text = r:Error()
    end
    t.panicked = { err = r, traceback = tostring(text) .. "\n" .. tostring(stack) }
    t:Fatalf("%s:\n%v\n%s", msg, tostring(text), stack)
end

-- Leave Program in SingleThreaded mode unless explicitly configured (the Lua port is always
-- single-threaded; there is no race mode).
local testProgramIsSingleThreadedValue = nil

function testutil.TestProgramIsSingleThreaded()
    if testProgramIsSingleThreadedValue == nil then
        testProgramIsSingleThreadedValue = true
        local v = os.getenv("TS_TEST_PROGRAM_SINGLE_THREADED")
        if v ~= nil and v ~= "" then
            v = string.lower(v)
            if v == "1" or v == "t" or v == "true" then
                testProgramIsSingleThreadedValue = true
            elseif v == "0" or v == "f" or v == "false" then
                testProgramIsSingleThreadedValue = false
            end
        end
    end
    return testProgramIsSingleThreadedValue
end

return testutil
