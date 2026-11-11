local packagejson = {}
package.loaded["tslua.packagejson"] = packagejson
require("tslua.packagejson.jsonvalue")
require("tslua.packagejson.expected")
require("tslua.packagejson.exportsorimports")
require("tslua.packagejson.packagejson")
require("tslua.packagejson.cache")
-- validated.go only declares the TypeValidatedField interface (IsPresent, IsValid,
-- ExpectedJSONType, ActualJSONType); Expected implements it.
return packagejson
