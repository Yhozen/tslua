local fourslash = require("tslua.fourslash")
local repo = require("tslua.repo")

-- Go reads _scripts/failingTests.txt relative to its own source file (runtime.Caller(0)); the
-- Lua port reads it from the upstream checkout (repo.RootPath() is vendor/typescript-go).
local failingTestsSet = nil

function fourslash.failingTests()
    if failingTestsSet ~= nil then
        return failingTestsSet
    end
    failingTestsSet = {}

    local failingTestsPath = repo.RootPath() .. "/internal/fourslash/_scripts/failingTests.txt"

    local file = io.open(failingTestsPath, "rb")
    if file == nil then
        return failingTestsSet
    end

    for line in file:lines() do
        line = string.match(line, "^%s*(.-)%s*$")
        if line ~= "" then
            failingTestsSet[line] = true
        end
    end
    file:close()
    return failingTestsSet
end

-- SkipIfFailing checks if the current test is in the failingTests.txt file
-- and skips it unless the TSGO_FOURSLASH_IGNORE_FAILING environment variable is set.
-- This allows tests to be marked as failing without modifying the test files themselves.
function fourslash.SkipIfFailing(t)
    t:Helper()

    local ignore = os.getenv("TSGO_FOURSLASH_IGNORE_FAILING")
    if ignore ~= nil and ignore ~= "" then
        return
    end

    if fourslash.failingTests()[t:Name()] then
        t:Skip("Test is in failingTests.txt")
    end
end
