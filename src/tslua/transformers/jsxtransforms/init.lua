local jsxtransforms = {}
package.loaded["tslua.transformers.jsxtransforms"] = jsxtransforms
for k, v in pairs(require("tslua.transformers.jsxtransforms.consts_generated")) do
    jsxtransforms[k] = v
end
require("tslua.transformers.jsxtransforms.jsx")
return jsxtransforms
