local testutil = {}
package.loaded["tslua.testutil"] = testutil
for k, v in pairs(require("tslua.testutil.consts_generated")) do
    testutil[k] = v
end
require("tslua.testutil.testing")
require("tslua.testutil.testutil")
return testutil
