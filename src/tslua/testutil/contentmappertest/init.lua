-- Package contentmappertest provides realistic content mapper implementations used by tests.
local contentmappertest = {}
package.loaded["tslua.testutil.contentmappertest"] = contentmappertest
require("tslua.testutil.contentmappertest.protocol")
require("tslua.testutil.contentmappertest.registry")
require("tslua.testutil.contentmappertest.manifest")
require("tslua.testutil.contentmappertest.spawner")
require("tslua.testutil.contentmappertest.transforming")
require("tslua.testutil.contentmappertest.verbatim")
require("tslua.testutil.contentmappertest.dynamic_verbatim")
require("tslua.testutil.contentmappertest.diagnostic_code_collision")
require("tslua.testutil.contentmappertest.failing")
require("tslua.testutil.contentmappertest.synthesizing")
require("tslua.testutil.contentmappertest.component")
require("tslua.testutil.contentmappertest.duplicate")
require("tslua.testutil.contentmappertest.lisp")
require("tslua.testutil.contentmappertest.supplemental")
require("tslua.testutil.contentmappertest.supplemental_diagnostics")
require("tslua.testutil.contentmappertest.supplemental_globals")
require("tslua.testutil.contentmappertest.supplemental_module")
require("tslua.testutil.contentmappertest.editing")
return contentmappertest
