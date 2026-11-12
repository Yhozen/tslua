local declarations = {}
package.loaded["tslua.transformers.declarations"] = declarations
for k, v in pairs(require("tslua.transformers.declarations.consts_generated")) do
    declarations[k] = v
end
-- transform.lua first: it creates the DeclarationTransformer struct table embedding transformers.Transformer at load time.
require("tslua.transformers.declarations.transform")
require("tslua.transformers.declarations.diagnostics")
require("tslua.transformers.declarations.supplementalreferences")
require("tslua.transformers.declarations.tracker")
require("tslua.transformers.declarations.util")
return declarations
