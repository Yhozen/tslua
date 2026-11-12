# Journey log

A running record of how the port is going: what was done, what we learned, and what got in
the way. Newest entries go at the bottom of each section's timeline. Agents: put
package-specific details in `.context/progress/<agent>.md`; anything that would help the next
person (a convention, a trap, a tool that worked) belongs here.

## Timeline

### 2026-11-11 — bootstrap

- Read the Cloudflare/VoidZero post on porting TypeScript to Rust (tsrs) and the tsrs repo
  (`docs/PORTING.md`, `AGENTS.md`). Adopted its method wholesale: a **mechanical, faithful
  port** of typescript-go, the Go source as the specification, upstream baselines as the oracle,
  one target file per Go file, Go names kept.
- Set up Lua 5.4 + LuaRocks + busted + luacheck, the rockspec, Makefile, `.luacheckrc`,
  `.stylua.toml`, and pinned upstream (`UPSTREAM_COMMIT`, `scripts/fetch-upstream.sh`).
- Generators instead of hand-copying data:
  - `scripts/gen/goconsts` (Go): evaluates **every** constant of the ported packages with
    `go/types` and writes `consts_generated.lua` — no enum value is ever typed by hand.
  - `scripts/gen/diagnostics.mjs`: the 2,206 diagnostic messages.
  - `scripts/gen/ast.mjs`: the AST factory, visitors and `ForEachChild` from upstream's
    `_scripts/ast.json` (the same schema Go's `ast_generated.go` comes from).
- Wrote `docs/PORTING.md` (Lua conventions) and `docs/AST.md` (node contract) *before* starting
  any agent, so ten agents could code against each other's not-yet-written APIs.

### 2026-11-11 — wave 1 (10 agents): foundations

core/collections/tspath/stringutil/jsnum, ast, scanner+diagnostics, parser, binder+evaluator,
test harness+vfs, tsoptions+module resolution, compiler+CLI, printer+sourcemap, checker
foundation. Results checked against Go per package:

- scanner: 57/59 Go fixture streams identical (the two others waited on jsnum).
- binder: identical symbol tables/flags/diagnostics on ~12,800 upstream files.
- parser: identical AST + diagnostics on 14,719/14,719 inputs.
- printer: byte-identical on 12,826 inputs, source maps on 3,206.
- tsoptions/module: identical on 593 cases / 2,018 resolutions.

### 2026-11-11/12 — wave 2: checker (60k Go lines) and transformers (24k)

`checker.go` (32k lines) split into nine ~3.6k-line ranges at function boundaries
(`docs/CHECKER.md`), plus one agent each for relater, flow+inference, grammar+jsx, emit
resolver, nodebuilder; five transformer agents. Transformers were byte-identical with Go
oracles on tens of thousands of input × option combinations.

### 2026-11-12 — integration

- First end-to-end run (`bin/tslua-test --all`): **13,084 of ~13,200** compiler/conformance
  configurations passed byte-for-byte (errors, js, types, symbols) on the first try. 2,120
  configurations are skipped exactly like Go's harness (AMD/UMD/System, ES5, outFile, baseUrl —
  features TypeScript 7 removed).
- After a round of crash fixes: **13,171** pass; `tests/passing/*.txt` record them and act as the
  regression gate.

### 2026-11-12 — wave 3 (15 agents): beyond `tsc`

Widened scope to what tsrs covers: incremental (`.tsbuildinfo` byte-identical with tsgo),
`--build` and watch (168/171 build, 39/39 watch scenarios), the tsc scenario runner (484
passing), content mappers, and the language server (astnav, format, lsproto/LSP, project
system, language service split across five agents, fourslash harness with 3,795 converted
tests, API server).

- tsc scenario runner (`bin/tslua-tsctest`): **483/504** upstream command-line scenarios
  byte-identical (tsbuild 192/192, tscWatch 42/42, tsbuildWatch 65/65, tsc 184/205); the rest
  are showConfig, localization and generateTrace, now being brought into scope. Scenarios were
  extracted by running the upstream Go tests with a patched runner that dumps each evaluated
  scenario (they are Go code, not data) — another case of letting Go produce the Lua inputs.
- LSP: protocol types generated from the same metaModel upstream uses; JSON codec matched a Go
  oracle on ~50k random/mutated messages; `bin/tslua --lsp --stdio` serves requests.

## Learnings

- **Write the conventions first.** The biggest multiplier was `docs/PORTING.md` + `docs/AST.md`
  existing before any agent started: agents wrote against APIs that didn't exist yet and
  integration mostly just worked, because everyone translated the same Go names the same way.
- **Keep Go names exactly.** Functions/methods keep their Go names, fields are lowerCamel of the
  Go field. Grep works across both code bases, and a reviewer can put Lua and Go side by side.
- **Keep indices 0-based as values.** Only actual array/string access adds 1. Mixing 0- and
  1-based values was the most predictable source of bugs, and this rule removed most of them.
- **Differential testing against a Go oracle is the killer tool.** The scanner agent started
  it: build a tiny Go program against the vendored typescript-go with `go build -overlay`
  (nothing written into `vendor/`), dump the same data from Go and from Lua over thousands of
  upstream inputs, and diff. After that was put into every brief, packages arrived
  pre-verified (parser 14,719/14,719, printer 12,826/12,826, binder ~12,800, ...).
- **Generate, don't transcribe.** Constants via `go/types`, diagnostics, AST factories, Unicode
  tables, LSP protocol types, fourslash tests — all generated from upstream sources.
- **Zero values matter.** Go's zero values (`0`, `""`, `false`) are Lua `nil`. Rule: initialize
  every scalar field in constructors and return Go zero values from functions (`""`, not
  `nil`), since callers port `x != ""` literally.
- **Methods on scalar types** become `<Type>_<Method>(value, ...)` (`jsnum.Number_String(n)`);
  `iter.Seq` returns become Lua iterators.
- **Lua limits shape the code.** 200 locals / 255 upvalues per function → every package-level
  function lives in the package table (`ast.IsIdentifier`), never in file locals; packages
  register in `package.loaded` before loading their files so intra-package references work in
  any order.
- **Performance of the harness, not the port.** Parsing `lib.d.ts` per test made a case take ~4s;
  running 100 cases per worker process with the parsed-source cache took it to ~0.25s, and the
  full suite to ~45 minutes on 4 cores.

## Roadblocks (and what we did)

- **Nil slices and nil maps.** Go reads `len(nil)`, `for range nil`, `m[k]` on a nil map are all
  fine; Lua errors. Also `[][]T` with nil elements → Lua arrays with holes that `ipairs` stops
  at. This was the #1 crash class after integration. Fix pattern: `core.Len(x)`,
  `ipairs(x or {})`, `(m or {})[k]`, `... or {}` when building arrays of slices.
- **Method values.** Go `c.compareTypesIdentical` passed as a function has its receiver bound;
  Lua `self.compareTypesIdentical` does not. Must be `function(s, t) return
  self:compareTypesIdentical(s, t) end`. Found by a scan for `self.<method>` used as a value.
- **`Set.Keys()` returns a map in Go** (`for k := range s.Keys()`), but OrderedMap's is an
  iterator — porting both the same way crashed. Iterate a Set with `pairs(s:Keys())`.
- **Load-order traps.** Caching another file's class table in a file-level local before that
  file is loaded gives `nil` forever (`nodebuilderscopes`, `ls.LanguageService`,
  `change.Tracker`). Rule: define shared class tables in the package `init.lua` before the
  requires, and have the owning file reuse (not replace) them.
- **Go map iteration order** is random; where it influenced output order we use sorted or
  first-seen order, and we never rely on `pairs` order.
- **`$PWD` can be stale** in child processes; `osvfs.Getwd` now trusts it only if it names the
  physical cwd (Go's `os.Getwd` does the same check).
- **No syscalls in pure Lua.** Native file watchers (inotify/FSEvents) are impossible; watch mode
  uses a polling backend (`find -printf`, 0.25 s). Content mappers need subprocess I/O, which
  pure Lua only has through `io.popen`.
- **Shared 4-core machine.** 10–15 agents plus test runs compete for CPU; agents were told to run
  focused test slices and only one full-suite gate at the end.
- **API rate limits.** Running 10–15 agents in parallel hit the 5-hour usage limit twice. The
  agents' work survives (uncommitted files stay in the tree, agents are resumed with a message),
  so the cost is only wall-clock time. Agents commit often for this reason.
- **Misrouted coordination.** Once a message meant for one agent went to another; agents now
  keep strict file ownership and refuse cross-ownership edits, which made the mistake harmless.
