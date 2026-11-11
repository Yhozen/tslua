local testrunner = {}
package.loaded["tslua.testrunner"] = testrunner
for k, v in pairs(require("tslua.testrunner.consts_generated")) do
    testrunner[k] = v
end
require("tslua.testrunner.compiler_runner")
require("tslua.testrunner.runner")
require("tslua.testrunner.test_case_parser")
require("tslua.testrunner.transpile_runner")
return testrunner
