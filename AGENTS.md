# Notes for coding agents

Read `docs/PORTING.md` (porting rules, Lua conventions, test workflow) and `docs/AST.md` (the AST
contract) before writing code. The Go source in `vendor/typescript-go/internal/` (run
`make upstream` if missing) is the specification; upstream baselines are the oracle.

- Lua 5.4. `make lint` (luacheck) must pass for files you touch.
- Load a package: `lua -e 'package.path="src/?.lua;src/?/init.lua;"..package.path; require("tslua.ast")'`.
- Write scripts in JavaScript (Node) or Lua, not Python.
- Commit only your own paths; never `git add -A`.
