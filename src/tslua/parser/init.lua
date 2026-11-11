local parser = {}
package.loaded["tslua.parser"] = parser
for k, v in pairs(require("tslua.parser.consts_generated")) do
    parser[k] = v
end
require("tslua.parser.parser_1")
require("tslua.parser.parser_2")
require("tslua.parser.parser_3")
require("tslua.parser.jsdoc")
require("tslua.parser.reparser")
require("tslua.parser.references")
require("tslua.parser.types")
require("tslua.parser.utilities")
return parser
