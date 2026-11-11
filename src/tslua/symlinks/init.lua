local symlinks = {}
package.loaded["tslua.symlinks"] = symlinks
require("tslua.symlinks.knownsymlinks")
return symlinks
