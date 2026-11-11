# Generators

All generated files carry a `Code generated ... DO NOT EDIT.` header. Regenerate with
`make generate` after bumping `UPSTREAM_COMMIT`.

- `goconsts/` (Go): evaluates every constant of the ported typescript-go packages with
  `go/types` and writes `src/tslua/<pkg>/consts_generated.lua`.
- `diagnostics.mjs` (Node): writes `src/tslua/diagnostics/messages_generated.lua` from
  `internal/diagnostics/diagnostics_generated.go`.
- `ast.mjs` (Node): writes `src/tslua/ast/ast_generated.lua` from `_scripts/ast.json`.
