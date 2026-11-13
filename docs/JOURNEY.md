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
  were showConfig, localization and generateTrace, brought into scope next (see below). Scenarios were
  extracted by running the upstream Go tests with a patched runner that dumps each evaluated
  scenario (they are Go code, not data) — another case of letting Go produce the Lua inputs.
- LSP: protocol types generated from the same metaModel upstream uses; JSON codec matched a Go
  oracle on ~50k random/mutated messages; `bin/tslua --lsp --stdio` serves requests.

### 2026-11-12 — showConfig, localization, tracing

- `--showConfig` (`tsoptions/showconfig.go`): the Go code walks `core.CompilerOptions` with
  reflection; the Lua port walks `core.CompilerOptions.Fields` (declaration order, field kinds),
  which is exactly the information reflection gave Go. All 17 showConfig scenarios pass.
- Localization: `scripts/gen/loctables` (Go) turns the locale `.json.gz` files Go embeds into
  Lua tables, and precomputes what `golang.org/x/text/language` would do for the one matcher the
  compiler builds (match results per language / language-region / language-script, the subtag
  registry, aliases). Verified against x/text on ~17k tags (parse results, including Go's
  partial-tag-on-error behavior, and match indices): 0 mismatches.
- Tracing: `internal/tracing` + `checker/tracer.go`, and every tracer call the earlier waves had
  dropped (checker, relater, flow, file loader, emitter, program, tsc emit, incremental). Go's
  `defer tr.Push(...)()` becomes a `pop` local called on every return path (or a closure body
  when a function has many returns). Thread ids hash with xxh3-64, so `tslua.xxh3` gained
  `HashString`/`New`/`Sum64` (checked against zeebo/xxh3 for lengths 0..3000). The
  baselines run Go's deterministic mode (a counter instead of wall-clock time, sampled events
  dropped), so trace output is byte-identical; the 2 generateTrace scenarios pass.

### 2026-11-13 — repo health: CI, rock

- `.github/workflows/ci.yml`: lint + `luarocks make` smoke test, busted (default and `#slow`),
  and the three regression gates sharded with the new `--shard I/N` runner option (8 compiler,
  2 tsc, 8 fourslash jobs); the upstream checkout is cached by `UPSTREAM_COMMIT`.
- `luarocks make` installs the modules, `bin/tslua` and the lib `.d.ts` files next to
  `tslua/bundled`; an installed `tslua` compiles outside the checkout.

### 2026-11-13 — real-world projects

`scripts/realworld/run.mjs` clones 18 public projects at pinned commits, installs their
dependencies (`--ignore-scripts`), and runs `tsgo` (built from `vendor/typescript-go`) and
`bin/tslua` in the same cwd: stdout, exit code and every emitted file are compared byte for byte.
Where TypeScript 7 rejects a project's config (`baseUrl`, `moduleResolution: node`, `target:
es5`, removed options) an equivalent tsconfig outside the project is used; the TS 7 config
errors themselves were compared too. All 40 jobs are identical:

| project | own files / lines (program files) | jobs (options) | diagnostics | emit |
| --- | --- | --- | --- | --- |
| ms | 8 / 1.3k (285) | as-is, `--types`, js+d.ts+maps, `--emitDeclarationOnly` (isolatedDeclarations) | = | = |
| tiny-invariant | 7 / 0.2k (32) | as-is, es2015 cjs | = | = |
| mitt | 4 / 0.4k (90) | as-is, emit, `--traceResolution`, `--watch` with two edits | = | = |
| cac | 18 / 1.4k (295) | emit, `--explainFiles` | = | = |
| ts-pattern | 20 / 4.2k (114) | emit + maps, es2017 cjs, `--listFiles` | = | = |
| p-queue | 5 / 1.6k (197) | esnext, es2015 cjs (`#private` lowering) | = | = |
| ky | 31 / 4.9k (95) | emit, es2015, es2022 `useDefineForClassFields: false` | = | = |
| chalk (JS, checkJs) | 7 / 1.1k (64) | js + d.ts from JS, `--locale ja --pretty` | = | = |
| neverthrow | 8 / 5.5k (460) | esnext, es2015 cjs (async downlevel) | = | = |
| inversify | 30 / 7.1k (218) | legacy decorators + metadata (cjs), ES decorators (esm) | = | = |
| zustand (tsx) | 32 / 10.4k (291) | react-jsx, react-jsxdev cjs, classic react | = | = |
| preact (JS, checkJs, jsx) | 17 / 6.2k (32) | js + d.ts + maps, `--pretty` | = | = |
| superstruct | 249 / 6.0k (506) | emit `--pretty`, `--incremental` + inline maps/sources | = | = |
| zod 3.23 | 82 / 15.3k (239) | es2018 d.ts + maps, es2016 cjs `--removeComments` | = | = |
| rxjs 7.8 | 251 / 21.4k (340) | es2015, importHelpers, stripInternal, d.ts + maps | = | = |
| type-fest (subset) | 117 / 11.1k (188) | check of the closure of 3 files (all of source/ is ~40 s in Go) | = | — |
| TypeScript 5.x src/compiler | 78 / 195k (225) | composite, d.ts + declarationMap, isolatedDeclarations | = | = |
| date-fns 4 | 1,229 / 71k (1,316) | core src emit; `-b` of 4 composite projects: clean, no-op, after an edit | = | = |

Also identical: `--showConfig` and `--listFilesOnly` of every project, synthetic CRLF/BOM/
non-ASCII and deeply nested inputs. Lua takes 25-45x Go's time (type-fest: 16 min vs 23 s, the
TypeScript compiler 6 min vs 13 s). No output difference was found; profiling the slow runs
found three Lua-only quadratic costs, fixed and pinned in `spec/regressions_spec.lua`:
`textWriter:GetColumn` joined the whole output for every source map mapping;
`parseJSDocComment` copied the file before and after each comment and scanned every newline from
the start of the file (checking `lib.dom.d.ts`, 6k JSDoc comments: 44 s -> 26 s); `UTF16Len`
looped in Lua over ASCII text. `ComputePositionMap` copied the rest of the text per non-ASCII
character.

Trap for the next person: `--noEmit` on a `composite`/`incremental` project still writes its
`.tsbuildinfo` into the project, and compilers rewrite existing outputs in place, so per-compiler
copies of a project for `-b` comparisons must be real copies (`cp -a --reflink=auto`), not hard
links: a stale buildinfo shared through a hard link made the two builds disagree.

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
- **Goroutines talking over a pipe → coroutines.** The in-process content mappers (Go: `net.Pipe`
  plus a goroutine running the server connection) became an in-memory pipe whose reader resumes the
  serving coroutine when its buffer is empty; the client's background `Run` loop is advanced from
  inside `Call`. Deadlock (both sides waiting to read) is detected instead of hanging.
- **Upstream unit tests as specs.** The Go `*_test.go` files of the compiler packages are ported
  one-to-one as `spec/<pkg>_<file>_spec.lua` (same test and subtest names). Table expressions that
  Go evaluates (`math.Inf`, `-0.0`, `%v` of a `Number`) are dumped by a Go oracle via
  `go test -overlay` instead of being translated by hand. Race tests that gate goroutines on
  channels run as coroutines under a small cooperative scheduler. These caught a real bug:
  `x + 0.0` as an "int to float" conversion turns `-0` into `+0` (`-0 ** -3` came out `+Inf`).
- **Translate Go tests with go/types, not regexes.** The 4,343 fourslash test files (+ the
  tests/util package) are converted by a type-directed Go->Lua translator
  (scripts/gen/fourslash/): types decide struct vs map vs slice literals, constant naming, methods
  on scalar types (`<Type>_<Method>`), zero-filled struct literals and Go copy semantics. The same
  translator in package mode produced a first draft of the 8k-line tslua.fourslash harness, which
  was then fixed by hand: much faster and more faithful than hand-porting.
- **Emulate Go `append` capacity.** Appending in place to every array mutates shared slice
  literals (package-level expectation lists); always copying is quadratic. The goruntime shim
  appends in place only to arrays it created through append (tracked weakly), like the spare
  capacity of Go slices grown by append.

- **Lint what you think you lint.** `luacheck <dir>` only checks `*.lua` files, so the
  extensionless `bin/*` scripts were never linted; the Makefile lists them explicitly.
- **Nil receivers, static form.** When a Go method handles a nil receiver, call the Lua method
  through its table (`autoimport.Registry.IsPreparedForImportingFile(registry, ...)`) instead of
  `registry:IsPreparedForImportingFile(...)`, so the nil check inside the port actually runs.
  Likewise, constructors of Go structs built from literals with missing fields
  (`&PackageJson{Parseable: false}`) should zero-fill every field themselves.
- **Non-Lua files in a rock.** LuaRocks' builtin `install.lua` maps a key `a.b.c` to the directory
  `a/b/` and keeps a non-`.lua` file's own name, which is how the lib `.d.ts` files land next
  to `tslua/bundled` (where it looks for them). Set `copy_directories = {}`, or `tests/`
  (thousands of files) is copied into the rock.
- **Port the standard library when Go leans on it.** `tslua.regexp` is Go's `regexp` +
  `regexp/syntax` (RE2: parser, simplifier, compiler, onepass/backtrack/NFA engines) ported file by
  file; the Unicode tables (`unicode.Categories`/`Scripts`/fold tables, and `SimpleFold`/`IsPrint`
  precomputed over all runes) come from `scripts/gen/regexptables`, the constants from
  `scripts/gen/goconsts` run on `$(go env GOROOT)/src`. Go's own tests are the oracle: the test
  tables are dumped to Lua by a `go test` in a scratch copy of the package (reflection-based
  serializer), and re2-search.txt / the AT&T .dat files run as specs (re2-exhaustive, 5.8M lines, is
  `#slow`). Go slice aliasing in the parser (`re.Rune0[:0]`, `sub[:0]` reuse) never leaked, so fresh
  arrays were fine; `sync.Pool`s became fresh allocations (a pool may always return a new value).
  Hand-written stand-ins hid Unicode case folding differences: `(?i)[a-z]` also matches U+017F and
  U+212A, `\x{FFFD}` matches an invalid byte.
- **Keep hot-path stand-ins, but check them.** The NFA costs ~3us/byte in Lua, so the test
  harness's per-line regexps (`\r?\n` splits, the `// @option:` matcher, `\S`, diagnostics'
  `{(\d+)}`) stay hand-written; `spec/regexp_standins_spec.lua` diffs them against `tslua.regexp`
  on real test files.

- **Go slicing is O(1), `string.sub` copies.** `text[start:]`, `text[:end]` and
  `builder.String()[pos:]` are free in Go; the literal Lua translation copies, and inside a loop
  over a file or an output it becomes quadratic. The upstream baselines never notice (small files,
  the harness caches parsed libs); real projects with `lib.dom.d.ts` or long lines with
  `--sourceMap` do. Pass bounds (`string.sub(s, i, i + 3)`, a `pos` argument) or search
  backward instead of materializing the slice.
- **Real-world parity checks are cheap to set up and found nothing the suites missed** (for
  output). Most time went to finding configs TypeScript 7 still accepts; a tsconfig outside the
  project with `rootDir`/`typeRoots` pointing back keeps the clone untouched.

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
- **Renamed closure parameters.** Go closures often shadow an outer variable (`func(node *ast.Node)`
  inside a function that has `node`); the Lua port renamed the parameter (`function(n)`) but left
  some uses of `node`, which then silently refer to the outer value. Found two such checker bugs
  (`isInPropertyInitializerOrClassStaticBlock`, `getInstantiationExpressionType`) with a scan that
  flags Lua closures referencing a name that is a closure parameter in the Go original.
- **Append aliasing.** Go `append` never changes the length of the slice the caller still holds;
  Lua `core.Append`/`AppendIfUnique` grow the array in place. `getDeclaredTypeOfClassOrInterface`
  read `len(outerTypeParameters)` after appending the local type parameters to it, so classes
  declared inside generic functions lost their own type parameters. Take lengths before appending.
- **Nil receivers.** Go methods may handle a nil receiver (`func (r *ResolvedModule) IsResolved()
  bool { return r != nil && ... }`); in Lua `r:IsResolved()` on nil crashes. Guard the call site.
- **Some upstream cases are just heavy.** relationComplexityError, templateLiteralTypes1,
  declarationEmitPrivatePromiseLikeInterface need 2.5-10 s of CPU in Go and 115-170+ s in Lua
  (no loops; diffuse cost in the relater and template literal inference), so they hit the 120 s
  per-case limit while producing correct baselines when run with `--timeout 0`.
- **Go struct field order in JSON.** Lua tables have no field order and tslua.json sorts keys, so
  baselines that JSON-encode Go structs (fourslash markers, `markerAndItem`) need Lua-only
  `MarshalJSON` methods writing fields in Go declaration order (and `null` for nil pointers).
- **Nil map values.** Go `m[k] = nil` (e.g. a nil `*Program` per project) is an entry; in Lua it
  deletes the key, so "is it new?" checks flip. Store a sentinel.
- **A statement starting with `(`** right after a multi-line call is parsed by Lua as a call of
  the previous expression (`f(...)` newline `(x or y):m()`). Prefix such statements with `;`.
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
- **Bidirectional child-process pipes.** `io.popen` is one-way, so content mapper processes are
  started through `sh` with two FIFOs (`mkfifo`): popen's stdin is forwarded with `cat` under
  `trap '' PIPE` (and then drained), so writing to a dead mapper never SIGPIPEs the Lua process;
  stdout is a FIFO opened for blocking reads; stderr is collected from a temp file at close.
  Blocking reads cannot time out, so the 5 s initialize timeout is not enforced
  (`src/tslua/ipc/process.lua`).
