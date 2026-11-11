local checker = {}
package.loaded["tslua.checker"] = checker
for k, v in pairs(require("tslua.checker.consts_generated")) do
    checker[k] = v
end

local Checker = {}
Checker.__index = Checker
checker.Checker = Checker

require("tslua.checker.types")
require("tslua.checker.links")
require("tslua.checker.mapper")
require("tslua.checker.stringer_generated")
require("tslua.checker.utilities")
require("tslua.checker.checker_1")
require("tslua.checker.checker_2")
require("tslua.checker.checker_3")
require("tslua.checker.checker_4")
require("tslua.checker.checker_5")
require("tslua.checker.checker_6")
require("tslua.checker.checker_7")
require("tslua.checker.checker_8")
require("tslua.checker.checker_9")
require("tslua.checker.relater_1")
require("tslua.checker.relater_2")
require("tslua.checker.flow")
require("tslua.checker.inference")
require("tslua.checker.grammarchecks")
require("tslua.checker.jsx")
require("tslua.checker.emitresolver")
require("tslua.checker.services")
require("tslua.checker.exports")
require("tslua.checker.printer")
require("tslua.checker.nodebuilder")
require("tslua.checker.nodebuilderimpl")
require("tslua.checker.nodebuilderscopes")
require("tslua.checker.nodebuilder_hover")
require("tslua.checker.nodecopy")
require("tslua.checker.pseudotypenodebuilder")
require("tslua.checker.symbolaccessibility")
require("tslua.checker.symboltracker")
require("tslua.checker.jsdoc")

return checker
