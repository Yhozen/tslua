local tsc = {}
package.loaded["tslua.execute.tsc"] = tsc
require("tslua.execute.tsc.compile")
require("tslua.execute.tsc.diagnostics")
require("tslua.execute.tsc.emit")
require("tslua.execute.tsc.extendedconfigcache")
require("tslua.execute.tsc.help")
require("tslua.execute.tsc.init_")
require("tslua.execute.tsc.statistics")
return tsc
