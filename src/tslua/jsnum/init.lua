local jsnum = {}
package.loaded["tslua.jsnum"] = jsnum
for k, v in pairs(require("tslua.jsnum.consts_generated")) do
    jsnum[k] = v
end
require("tslua.jsnum.jsnum")
require("tslua.jsnum.pseudobigint")
require("tslua.jsnum.string")
return jsnum
