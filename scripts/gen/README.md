# Generators

All generated files carry a `Code generated ... DO NOT EDIT.` header. Regenerate with
`make generate` after bumping `UPSTREAM_COMMIT`.

- `goconsts/` (Go): evaluates every constant of the ported typescript-go packages with
  `go/types` and writes `src/tslua/<pkg>/consts_generated.lua`.
- `diagnostics.mjs` (Node): writes `src/tslua/diagnostics/messages_generated.lua` from
  `internal/diagnostics/diagnostics_generated.go`.
- `ast.mjs` (Node): writes `src/tslua/ast/ast_generated.lua` from `_scripts/ast.json`.
- `lsproto.mjs` (Node): writes `src/tslua/lsp/lsproto/lsp_generated.lua` (LSP structures, unions,
  literal types, request/notification infos) from the vendored LSP metaModel
  (`lsproto/metaModel.json`), reusing the model logic of upstream's
  `internal/lsp/lsproto/_generate/generate.mts`.
