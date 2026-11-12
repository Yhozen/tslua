local transformers = {}
package.loaded["tslua.transformers"] = transformers
for k, v in pairs(require("tslua.transformers.consts_generated")) do
    transformers[k] = v
end
-- transformer.lua first: the other files create struct tables embedding transformers.Transformer at load time.
require("tslua.transformers.transformer")
require("tslua.transformers.chain")
require("tslua.transformers.destructuring")
require("tslua.transformers.modifiervisitor")
require("tslua.transformers.utilities")
return transformers
