local background = {}
package.loaded["tslua.project.background"] = background
for k, v in pairs(require("tslua.project.background.consts_generated")) do
    background[k] = v
end
require("tslua.project.background.queue")
return background
