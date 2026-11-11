local ast = {}
package.loaded["tslua.ast"] = ast
for k, v in pairs(require("tslua.ast.consts_generated")) do
    ast[k] = v
end
require("tslua.ast.ast_generated")
require("tslua.ast.ast")
require("tslua.ast.kind_stringer_generated")
require("tslua.ast.deepclone")
require("tslua.ast.diagnostic")
require("tslua.ast.flow")
require("tslua.ast.functionflags")
require("tslua.ast.parseoptions")
require("tslua.ast.positionmap")
require("tslua.ast.precedence")
require("tslua.ast.subtreefacts")
require("tslua.ast.symbol")
require("tslua.ast.utilities_1")
require("tslua.ast.utilities_2")
require("tslua.ast.visitor")
-- Resolve promoted methods of embedded structs (Go method sets) once every file is loaded.
ast.FinalizeStructs()
return ast
