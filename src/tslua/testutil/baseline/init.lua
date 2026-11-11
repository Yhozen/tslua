local baseline = {}
package.loaded["tslua.testutil.baseline"] = baseline
for k, v in pairs(require("tslua.testutil.baseline.consts_generated")) do
    baseline[k] = v
end
require("tslua.testutil.baseline.patience")
require("tslua.testutil.baseline.baseline")
require("tslua.testutil.baseline.testmain")
return baseline
