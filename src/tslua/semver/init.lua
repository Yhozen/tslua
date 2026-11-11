local semver = {}
package.loaded["tslua.semver"] = semver
require("tslua.semver.version")
require("tslua.semver.version_range")
return semver
