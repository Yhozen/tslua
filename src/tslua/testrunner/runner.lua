local testrunner = require("tslua.testrunner")

-- Runner interface: EnumerateTestFiles() -> []string, RunTests(t).

function testrunner.runTests(t, runners)
    for _, runner in ipairs(runners) do
        runner:RunTests(t)
    end
end

return testrunner
