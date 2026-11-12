local estransforms = {}
package.loaded["tslua.transformers.estransforms"] = estransforms
for k, v in pairs(require("tslua.transformers.estransforms.consts_generated")) do
    estransforms[k] = v
end
require("tslua.transformers.estransforms.async")
require("tslua.transformers.estransforms.classfields")
require("tslua.transformers.estransforms.classthis")
require("tslua.transformers.estransforms.esdecorator")
require("tslua.transformers.estransforms.exponentiation")
require("tslua.transformers.estransforms.forawait")
require("tslua.transformers.estransforms.logicalassignment")
require("tslua.transformers.estransforms.namedevaluation")
require("tslua.transformers.estransforms.nullishcoalescing")
require("tslua.transformers.estransforms.objectrestspread")
require("tslua.transformers.estransforms.optionalcatch")
require("tslua.transformers.estransforms.optionalchain")
require("tslua.transformers.estransforms.taggedtemplate")
require("tslua.transformers.estransforms.usestrict")
require("tslua.transformers.estransforms.using")
require("tslua.transformers.estransforms.utilities")
require("tslua.transformers.estransforms.definitions")
return estransforms
