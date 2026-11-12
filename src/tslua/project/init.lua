local project = {}
package.loaded["tslua.project"] = project
for k, v in pairs(require("tslua.project.consts_generated")) do
    project[k] = v
end
require("tslua.project.luahelpers")
require("tslua.project.api")
require("tslua.project.autoimport")
require("tslua.project.checkerpool")
require("tslua.project.client")
require("tslua.project.compilerhost")
require("tslua.project.configfileregistry")
require("tslua.project.configfileregistrybuilder")
require("tslua.project.extendedconfigcache")
require("tslua.project.filechange")
require("tslua.project.overlayfs")
require("tslua.project.ownercache")
require("tslua.project.parsecache")
require("tslua.project.programcounter")
require("tslua.project.project")
require("tslua.project.project_stringer_generated")
require("tslua.project.projectcollection")
require("tslua.project.projectcollectionbuilder")
require("tslua.project.refcountcache")
require("tslua.project.session")
require("tslua.project.snapshot")
require("tslua.project.snapshotfs")
require("tslua.project.watch")
return project
