local fourslash = {}
package.loaded["tslua.fourslash"] = fourslash
for k, v in pairs(require("tslua.fourslash.consts_generated")) do
    fourslash[k] = v
end
-- Go `Ignored = struct{}` and every `struct{}{}` value: one sentinel table (Lua-only).
fourslash.Ignored = setmetatable({}, { __name = "struct{}", __tostring = function() return "{}" end })
require("tslua.fourslash.test_parser")
require("tslua.fourslash.fourslash_1")
require("tslua.fourslash.fourslash_2")
require("tslua.fourslash.baselineutil")
require("tslua.fourslash.statebaseline")
require("tslua.fourslash.semantictokens")
require("tslua.fourslash.skip_if_failing")
return fourslash
