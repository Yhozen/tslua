local format = {}
package.loaded["tslua.format"] = format
for k, v in pairs(require("tslua.format.consts_generated")) do
    format[k] = v
end
require("tslua.format.api")
require("tslua.format.context")
require("tslua.format.indent")
require("tslua.format.rule")
require("tslua.format.rulecontext")
require("tslua.format.rules")
require("tslua.format.rulesmap")
require("tslua.format.scanner")
require("tslua.format.span")
require("tslua.format.util")
return format
