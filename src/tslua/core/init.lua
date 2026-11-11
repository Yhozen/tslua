local core = {}
package.loaded["tslua.core"] = core
for k, v in pairs(require("tslua.core.consts_generated")) do
    core[k] = v
end
require("tslua.core.helpers")
require("tslua.core.arena")
require("tslua.core.bfs")
require("tslua.core.binarysearch")
require("tslua.core.buildoptions")
require("tslua.core.compileroptions")
require("tslua.core.context")
require("tslua.core.core")
require("tslua.core.languagevariant")
require("tslua.core.languagevariant_stringer_generated")
require("tslua.core.linkstore")
require("tslua.core.modulekind_stringer_generated")
require("tslua.core.nodemodules")
require("tslua.core.pattern")
require("tslua.core.projectreference")
require("tslua.core.scriptkind")
require("tslua.core.scriptkind_stringer_generated")
require("tslua.core.scripttarget_stringer_generated")
require("tslua.core.semaphore")
require("tslua.core.stack")
require("tslua.core.text")
require("tslua.core.textchange")
require("tslua.core.tristate")
require("tslua.core.tristate_stringer_generated")
require("tslua.core.typeacquisition")
require("tslua.core.version")
require("tslua.core.watchoptions")
require("tslua.core.workgroup")
return core
