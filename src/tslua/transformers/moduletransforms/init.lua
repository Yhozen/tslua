local moduletransforms = {}
package.loaded["tslua.transformers.moduletransforms"] = moduletransforms
for k, v in pairs(require("tslua.transformers.moduletransforms.consts_generated")) do
    moduletransforms[k] = v
end
require("tslua.transformers.moduletransforms.commonjsmodule")
require("tslua.transformers.moduletransforms.esmodule")
require("tslua.transformers.moduletransforms.externalmoduleinfo")
require("tslua.transformers.moduletransforms.impliedmodule")
require("tslua.transformers.moduletransforms.utilities")
return moduletransforms
