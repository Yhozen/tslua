-- Automatic type acquisition is out of scope for the Lua port (see docs/PORTING.md). Only the
-- types the project package needs are ported; the typings installer never installs anything.
local ata = {}
package.loaded["tslua.project.ata"] = ata
for k, v in pairs(require("tslua.project.ata.consts_generated")) do
    ata[k] = v
end
require("tslua.project.ata.ata")
return ata
