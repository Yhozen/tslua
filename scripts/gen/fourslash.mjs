#!/usr/bin/env node
// Converts the Go fourslash tests of typescript-go into Lua test files:
//
//   internal/fourslash/tests/gen/*_test.go     -> tests/fourslash/gen/*_test.lua
//   internal/fourslash/tests/manual/*_test.go  -> tests/fourslash/manual/*_test.lua
//   internal/fourslash/tests/*_test.go         -> tests/fourslash/tests/*_test.lua
//   internal/fourslash/tests/util/util.go      -> src/tslua/fourslash/tests/util/util.lua
//   (+ src/tslua/fourslash/tests/zero_generated.lua, zero-value constructors of the Go structs
//   the tests build)
//
// The Go tests are themselves generated from the TypeScript fourslash sources by
// internal/fourslash/_scripts/convertFourslash.mts, plus hand-written (manual) ones; converting the
// Go code keeps exactly the upstream expectations, skip lists (fourslash.SkipIfFailing reads
// _scripts/failingTests.txt at run time) and t.Skip calls. The translation is type-directed, so
// it is done by a Go program (scripts/gen/fourslash/, go/types) that this script drives.
//
// Usage: node scripts/gen/fourslash.mjs [vendor/typescript-go] [file filter]
import { execFileSync } from "node:child_process";
import path from "node:path";
import url from "node:url";

const here = path.dirname(url.fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const upstream = path.resolve(process.argv[2] ?? path.join(repo, "vendor", "typescript-go"));
const args = ["run", ".", upstream, repo];
if (process.argv[3]) args.push(process.argv[3]);

execFileSync("go", args, { cwd: path.join(here, "fourslash"), stdio: "inherit" });
