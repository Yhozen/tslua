local projecttestutil = {}
package.loaded["tslua.testutil.projecttestutil"] = projecttestutil
for k, v in pairs(require("tslua.testutil.projecttestutil.consts_generated")) do
    projecttestutil[k] = v
end
require("tslua.testutil.projecttestutil.clientmock_generated")
require("tslua.testutil.projecttestutil.npmexecutormock_generated")
require("tslua.testutil.projecttestutil.projecttestutil")
return projecttestutil
