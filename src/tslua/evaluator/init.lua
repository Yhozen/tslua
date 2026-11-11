local evaluator = {}
package.loaded["tslua.evaluator"] = evaluator
for k, v in pairs(require("tslua.evaluator.consts_generated")) do
    evaluator[k] = v
end
require("tslua.evaluator.evaluator")
return evaluator
