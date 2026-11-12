local tstransforms = {}
package.loaded["tslua.transformers.tstransforms"] = tstransforms
for k, v in pairs(require("tslua.transformers.tstransforms.consts_generated")) do
    tstransforms[k] = v
end
require("tslua.transformers.tstransforms.importelision")
require("tslua.transformers.tstransforms.legacydecorators")
require("tslua.transformers.tstransforms.metadata")
require("tslua.transformers.tstransforms.runtimesyntax")
require("tslua.transformers.tstransforms.typeeraser")
require("tslua.transformers.tstransforms.typeserializer")
require("tslua.transformers.tstransforms.utilities")
return tstransforms
