local compiler = {}
package.loaded["tslua.compiler"] = compiler
for k, v in pairs(require("tslua.compiler.consts_generated")) do
    compiler[k] = v
end
require("tslua.compiler.luahelpers")
require("tslua.compiler.checkerpool")
require("tslua.compiler.emitHost")
require("tslua.compiler.emitter")
require("tslua.compiler.fileInclude")
require("tslua.compiler.fileloader")
require("tslua.compiler.filesparser")
require("tslua.compiler.host")
require("tslua.compiler.includeprocessor")
require("tslua.compiler.processingDiagnostic")
require("tslua.compiler.program")
require("tslua.compiler.projectreferencedtsfakinghost")
require("tslua.compiler.projectreferencefilemapper")
require("tslua.compiler.projectreferenceparser")
return compiler
