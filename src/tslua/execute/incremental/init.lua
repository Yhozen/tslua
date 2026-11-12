local incremental = {}
package.loaded["tslua.execute.incremental"] = incremental
for k, v in pairs(require("tslua.execute.incremental.consts_generated")) do
    incremental[k] = v
end
require("tslua.execute.incremental.affectedfileshandler")
require("tslua.execute.incremental.buildInfo")
require("tslua.execute.incremental.buildinfotosnapshot")
require("tslua.execute.incremental.emitfileshandler")
require("tslua.execute.incremental.host")
require("tslua.execute.incremental.incremental")
require("tslua.execute.incremental.luahelpers")
require("tslua.execute.incremental.program")
require("tslua.execute.incremental.programtosnapshot")
require("tslua.execute.incremental.referencemap")
require("tslua.execute.incremental.snapshot")
require("tslua.execute.incremental.snapshottobuildinfo")
return incremental
