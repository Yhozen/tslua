local autoimport = {}
package.loaded["tslua.ls.autoimport"] = autoimport
for k, v in pairs(require("tslua.ls.autoimport.consts_generated")) do
    autoimport[k] = v
end
-- Files defining struct tables (View, Registry, registryBuilder, ...) load before the files that
-- add methods to them.
require("tslua.ls.autoimport.export")
require("tslua.ls.autoimport.export_stringer_generated")
require("tslua.ls.autoimport.index")
require("tslua.ls.autoimport.view")
require("tslua.ls.autoimport.registry")
require("tslua.ls.autoimport.aliasresolver")
require("tslua.ls.autoimport.extract")
require("tslua.ls.autoimport.fix")
require("tslua.ls.autoimport.import_adder")
require("tslua.ls.autoimport.specifiers")
require("tslua.ls.autoimport.util")
return autoimport
