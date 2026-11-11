local printer = {}
package.loaded["tslua.printer"] = printer
for k, v in pairs(require("tslua.printer.consts_generated")) do
    printer[k] = v
end
require("tslua.printer.luahelpers")
require("tslua.printer.emitcontext")
require("tslua.printer.emitflags")
require("tslua.printer.emithost")
require("tslua.printer.emitresolver")
require("tslua.printer.emittextwriter")
require("tslua.printer.factory")
require("tslua.printer.generatedidentifierflags")
require("tslua.printer.helpers")
require("tslua.printer.namegenerator")
require("tslua.printer.printer_1")
require("tslua.printer.printer_2")
require("tslua.printer.printer_3")
require("tslua.printer.semicolon_writer")
require("tslua.printer.singlelinestringwriter")
require("tslua.printer.sourcefilemetadataprovider")
require("tslua.printer.syntheticfile")
require("tslua.printer.textwriter")
require("tslua.printer.utilities")
return printer
