local inliners = {}
package.loaded["tslua.transformers.inliners"] = inliners
for k, v in pairs(require("tslua.transformers.inliners.consts_generated")) do
    inliners[k] = v
end
require("tslua.transformers.inliners.constenum")
return inliners
