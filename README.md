# tslua

A faithful port of the TypeScript 7 compiler ([microsoft/typescript-go](https://github.com/microsoft/typescript-go))
to Lua 5.4.

The port is mechanical: same algorithms, same function decomposition, same diagnostics. It follows
the approach of [tsrs](https://github.com/oxc-project/tsrs): the Go source is the specification and
the upstream baseline suite (`tests/cases/{compiler,conformance}`) is the oracle. Performance is not a
goal.

## Layout

- `src/tslua/<package>/` — one Lua package per Go package of `internal/`, one Lua file per Go file.
- `src/tslua/bundled/libs/` — the `lib.*.d.ts` files.
- `bin/tslua` — the `tsc`-like command line; `bin/tslua-test` — the baseline runner.
- `scripts/gen/` — generators for constants, diagnostic messages and the AST.
- `docs/PORTING.md`, `docs/AST.md` — conventions; `docs/STATUS.md` — progress.

## Development

```sh
make upstream     # fetch typescript-go at UPSTREAM_COMMIT into vendor/
make lint spec    # luacheck + busted
make baselines    # run the upstream suites
```

Requires Lua 5.4, LuaRocks, `busted`, `luacheck`; Go and Node only for the generators.

## License

Apache-2.0, like TypeScript. See `LICENSE` and `NOTICE`.
