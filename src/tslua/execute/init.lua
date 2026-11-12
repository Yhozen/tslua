local execute = {}
package.loaded["tslua.execute"] = execute
-- execute/tsc.go (named tsc_.lua because tslua.execute.tsc is the execute/tsc sub-package)
require("tslua.execute.tsc_")
require("tslua.execute.watcher")
return execute
