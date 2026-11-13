-- Port of the Go standard library package regexp (RE2 syntax and semantics).
-- Strings are UTF-8 byte strings; all indices are 0-based byte offsets like Go.
-- Go []byte arguments and results are Lua strings too; inside result arrays a nil Go []byte
-- (an unmatched submatch) is `false`, so arrays have no holes.
-- An io.RuneReader is any table with a ReadRune() method returning rune, size, err.
local regexp = {}
package.loaded["tslua.regexp"] = regexp
require("tslua.regexp.regexp")
require("tslua.regexp.backtrack")
require("tslua.regexp.exec")
require("tslua.regexp.onepass")
return regexp
