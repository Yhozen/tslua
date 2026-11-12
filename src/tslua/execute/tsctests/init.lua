local tsctests = {}
package.loaded["tslua.execute.tsctests"] = tsctests
require("tslua.execute.tsctests.fs")
require("tslua.execute.tsctests.mock_watch_backend")
require("tslua.execute.tsctests.readablebuildinfo")
require("tslua.execute.tsctests.runner")
require("tslua.execute.tsctests.sys")
return tsctests
