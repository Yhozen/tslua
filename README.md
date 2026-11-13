# tslua

A faithful port of the TypeScript 7 compiler ([microsoft/typescript-go](https://github.com/microsoft/typescript-go))
to Lua 5.4.

The port is mechanical: same algorithms, same function decomposition, same diagnostics. It follows
the approach of [tsrs](https://github.com/oxc-project/tsrs): the Go source is the specification and
the upstream test suites are the oracle. Performance is not a goal.

## Status

Every package of typescript-go's `internal/` is ported except `nativepath`, `osutil` and `pprof`:
scanner, parser, binder, checker, transformers/emitter, module resolution, `tsoptions`,
`compiler`, incremental builds (`.tsbuildinfo`), `tsc -b` and `--watch`, the language service,
LSP server, project system, formatter and API server.

| Suite (gate)                                   | Passing (byte-identical with Go's reference baselines)                  |
| ---------------------------------------------- | ----------------------------------------------------------------------- |
| Compiler + conformance baselines (`tslua-test`) | 13,173 configurations: errors, types, symbols; 13,165 js (of ~13,200 run; Go's harness skips the rest) |
| `tsc` / `tsc -b` / `--watch` scenarios (`tslua-tsctest`) | 504 / 504                                                     |
| Fourslash language-service tests (`tslua-fourslash`) | 4,086 of 4,510 converted tests (420 skipped exactly as Go skips them) |
| Go unit tests (`busted`, `spec/`)              | all pass (a few are pending for the same reasons Go skips them)         |

The numbers are the line counts of `tests/passing/*.txt`, which every gate checks for regressions.

## Layout

- `src/tslua/<package>/` — one Lua package per Go package of `internal/`, one Lua file per Go file.
- `src/tslua/bundled/libs/` — the `lib.*.d.ts` files.
- `spec/` — busted ports of the Go `_test.go` files (`<pkg>_<file>_spec.lua`) plus a few smoke tests.
- `tests/passing/` — regression lists; `tests/fourslash/` — fourslash tests converted to Lua.
- `scripts/gen/` — generators for constants, diagnostic messages, the AST, LSP types and fourslash tests.
- `docs/PORTING.md`, `docs/AST.md`, `docs/CHECKER.md` — conventions; `docs/JOURNEY.md` — log of progress, learnings and roadblocks.

## Usage

```sh
bin/tslua -p tsconfig.json     # tsc; also -b/--build, -w/--watch, --showConfig, ...
bin/tslua --lsp --stdio        # language server
luarocks make                  # install the modules, the libs and `tslua` (or: make rock)
```

## Development

Requires Lua 5.4, LuaRocks, `busted` and `luacheck`; Go and Node only for the generators.

```sh
make upstream          # fetch typescript-go at UPSTREAM_COMMIT (with the TypeScript submodule) into vendor/
make lint              # luacheck src spec tests bin/*
make spec              # busted, skipping specs tagged #slow; `make spec-all` runs everything
lua bin/tslua-test --passing --jobs 4 --batch 100 -q  # compiler/conformance gate (make baselines-passing)
lua bin/tslua-tsctest --passing --jobs 4 -q           # tsc scenario gate (make tsctests-passing)
lua bin/tslua-fourslash --passing --jobs 4 -q         # fourslash gate (make fourslash-passing)
```

Each runner takes case names or `--filter <pattern>` to run a slice, `--shard I/N` to run one of N
disjoint slices (CI runs them as a job matrix), `-v` to print failure details and `--update-passing`
to record newly passing cases; differing outputs are written to `tests/out/`.
`lua bin/tslua-test --all` runs the full upstream suites. See `--help` of each runner.

## License

Apache-2.0, like TypeScript. See `LICENSE` and `NOTICE`.
