rockspec_format = "3.0"
package = "tslua"
version = "dev-1"
source = {
   url = "git+https://github.com/Yhozen/tslua.git",
}
description = {
   summary = "A faithful Lua port of the TypeScript 7 (typescript-go) compiler",
   detailed = [[
tslua is a mechanical port of microsoft/typescript-go to Lua 5.4: scanner, parser,
binder, type checker and emitter, validated against the upstream baseline test suite.
]],
   homepage = "https://github.com/Yhozen/tslua",
   license = "Apache-2.0",
}
dependencies = {
   "lua >= 5.4",
}
test_dependencies = {
   "busted",
}
test = {
   type = "busted",
}
build = {
   type = "builtin",
   -- Modules are auto-detected from src/.
   install = {
      bin = { tslua = "bin/tslua" },
   },
}
