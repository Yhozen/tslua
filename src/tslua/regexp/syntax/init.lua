local syntax = {}
package.loaded["tslua.regexp.syntax"] = syntax
for k, v in pairs(require("tslua.regexp.syntax.consts_generated")) do
    syntax[k] = v
end
require("tslua.regexp.syntax.regexp") -- first: defines opPseudo, used by parse.lua at load time
require("tslua.regexp.syntax.compile")
require("tslua.regexp.syntax.op_string")
require("tslua.regexp.syntax.parse")
require("tslua.regexp.syntax.perl_groups")
require("tslua.regexp.syntax.prog")
require("tslua.regexp.syntax.simplify")
return syntax
