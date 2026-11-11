local tsoptions = {}
package.loaded["tslua.tsoptions"] = tsoptions
for k, v in pairs(require("tslua.tsoptions.consts_generated")) do
    tsoptions[k] = v
end
-- Files are loaded in the dependency order of their package-level vars (Go initializes package
-- vars in dependency order regardless of file).
require("tslua.tsoptions.parsinghelpers")
require("tslua.tsoptions.enummaps")
require("tslua.tsoptions.commandlineoption")
require("tslua.tsoptions.declscompiler")
require("tslua.tsoptions.declsbuild")
require("tslua.tsoptions.declswatch")
require("tslua.tsoptions.tsconfigparsing")
require("tslua.tsoptions.declstypeacquisition")
tsoptions.initTsconfigparsingVars()
require("tslua.tsoptions.namemap")
require("tslua.tsoptions.diagnostics")
require("tslua.tsoptions.commandlineparser")
require("tslua.tsoptions.errors")
require("tslua.tsoptions.parsedoptions")
require("tslua.tsoptions.parsedcommandline")
require("tslua.tsoptions.parsedbuildcommandline")
require("tslua.tsoptions.contentmappers")
require("tslua.tsoptions.wildcarddirectories")
require("tslua.tsoptions.showconfig")
return tsoptions
