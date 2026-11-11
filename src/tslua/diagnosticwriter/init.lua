local diagnosticwriter = {}
package.loaded["tslua.diagnosticwriter"] = diagnosticwriter
for k, v in pairs(require("tslua.diagnosticwriter.consts_generated")) do
    diagnosticwriter[k] = v
end
require("tslua.diagnosticwriter.diagnosticwriter")
return diagnosticwriter
