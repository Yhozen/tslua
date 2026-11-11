local tsbaseline = {}
package.loaded["tslua.testutil.tsbaseline"] = tsbaseline
for k, v in pairs(require("tslua.testutil.tsbaseline.consts_generated")) do
    tsbaseline[k] = v
end
require("tslua.testutil.tsbaseline.util")
require("tslua.testutil.tsbaseline.contentmapper_baseline")
require("tslua.testutil.tsbaseline.error_baseline")
require("tslua.testutil.tsbaseline.js_emit_baseline")
require("tslua.testutil.tsbaseline.module_resolution_baseline")
require("tslua.testutil.tsbaseline.sourcemap_baseline")
require("tslua.testutil.tsbaseline.sourcemap_record_baseline")
require("tslua.testutil.tsbaseline.type_symbol_baseline")
return tsbaseline
