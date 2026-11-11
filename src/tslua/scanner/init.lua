local scanner = {}
package.loaded["tslua.scanner"] = scanner
for k, v in pairs(require("tslua.scanner.consts_generated")) do
    scanner[k] = v
end
require("tslua.scanner.scanner_1")
require("tslua.scanner.scanner_2")
require("tslua.scanner.utilities")
require("tslua.scanner.regexp")
require("tslua.scanner.unicodeproperties")
return scanner
