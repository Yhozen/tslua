local stringutil = {}
package.loaded["tslua.stringutil"] = stringutil
for k, v in pairs(require("tslua.stringutil.consts_generated")) do
    stringutil[k] = v
end
require("tslua.stringutil.helpers")
require("tslua.stringutil.compare")
require("tslua.stringutil.identifier")
require("tslua.stringutil.identifier_parts_generated")
require("tslua.stringutil.js_case")
require("tslua.stringutil.js_case_generated")
require("tslua.stringutil.util")
return stringutil
