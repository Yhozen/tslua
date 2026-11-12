local logging = {}
package.loaded["tslua.project.logging"] = logging
for k, v in pairs(require("tslua.project.logging.consts_generated")) do
    logging[k] = v
end
require("tslua.project.logging.logger")
require("tslua.project.logging.logcollector")
require("tslua.project.logging.logtree")
return logging
