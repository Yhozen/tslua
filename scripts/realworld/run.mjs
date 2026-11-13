#!/usr/bin/env node
// Differential test of bin/tslua against tsgo on public real-world projects.
//
//   go build -o /tmp/tsgo ./cmd/tsgo          (in vendor/typescript-go)
//   node scripts/realworld/run.mjs [--work DIR] [--tsgo PATH] [--jobs N] [--setup-only] [label-or-project ...]
//
// Clones each project at a pinned commit into the work directory (default
// .context/scratch/realworld), installs its dependencies without running scripts, writes the
// extra tsconfigs below into <work>/configs, then runs every job with both compilers in the same
// cwd and compares stdout+stderr, exit codes and every emitted file byte for byte. `@OUT@` in the
// arguments is replaced by a per-compiler output directory (<work>/out/<label>/{go,lua}, siblings,
// so relative paths in source maps and .tsbuildinfo match). `build` jobs copy the project (cp -a,
// not hard links: outputs are rewritten in place) per compiler and run `-b` three times: clean,
// no-op, after editing a file.
// The projects are never modified. Results: <work>/out/<label>.result.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../..");
const argv = process.argv.slice(2);
const opt = (name, def) => {
    const i = argv.indexOf(name);
    if (i < 0) return def;
    const v = argv[i + 1];
    argv.splice(i, 2);
    return v;
};
const flag = (name) => {
    const i = argv.indexOf(name);
    if (i < 0) return false;
    argv.splice(i, 1);
    return true;
};
const work = path.resolve(opt("--work", path.join(repoRoot, ".context/scratch/realworld")));
const tsgo = opt("--tsgo", "/tmp/tsgo");
const lanes = Number(opt("--jobs", "2"));
const setupOnly = flag("--setup-only");
const only = argv;

const npm = "npm install --ignore-scripts --no-audit --no-fund --legacy-peer-deps";
const pnpm = "pnpm install --ignore-scripts";

// name: [git url, commit, install command]
const projects = {
    "ms": ["https://github.com/vercel/ms", "4ff48cec099f0514c3e9bbca18706c9c21122bfb", npm],
    "tiny-invariant": ["https://github.com/alexreardon/tiny-invariant", "b5587cf4ba45e257bce49053c3345b6614324252", npm],
    "mitt": ["https://github.com/developit/mitt", "6b41670516ed8e8b738612f60491995470aa63b3", npm],
    "neverthrow": ["https://github.com/supermacro/neverthrow", "5ef3a018bda74fb960e44b68fc3672635ee8037d", npm],
    "superstruct": ["https://github.com/ianstormtaylor/superstruct", "e414c8afd3b69f6bc0173b8ee25f71d8e5694f01", npm],
    "cac": ["https://github.com/cacjs/cac", "12a5e8278719dfd9a4b7197a6690e7bf01b20b07", npm],
    "zod": ["https://github.com/colinhacks/zod", "ca42965df46b2f7e2747db29c40a26bcb32a51d5", npm], // v3.23.8
    "date-fns": ["https://github.com/date-fns/date-fns", "a9739fb3e5384a810e90d7376446f6d84ecc5029", pnpm],
    "inversify": ["https://github.com/inversify/InversifyJS", "fdd9186891e777884012984c64c271e576155f08", npm],
    "ts-pattern": ["https://github.com/gvergnaud/ts-pattern", "f11be73acb18e1d653d4f252e7d75981d873a2e6", npm],
    "type-fest": ["https://github.com/sindresorhus/type-fest", "8d73897400eb8d1420ea7a870caf62d10548a858", npm],
    "zustand": ["https://github.com/pmndrs/zustand", "9fed2eb2f3af672da9f7bf694b996df3831fc207", npm],
    "chalk": ["https://github.com/chalk/chalk", "72110019e147683f60e13fa0ff5c14a0c27cd9fe", npm],
    "ky": ["https://github.com/sindresorhus/ky", "3541888878c4d303a8bc2ad61815f4e048f55a5d", npm],
    "preact": ["https://github.com/preactjs/preact", "a2e03dbc6a4a239552d43edb6580ecf86886cc39", pnpm],
    "p-queue": ["https://github.com/sindresorhus/p-queue", "7f272ab5ff2254c0dc2537b7977e88ede1cd55e8", npm],
    "rxjs7": ["https://github.com/ReactiveX/rxjs", "72bc92191ab959e27a969dc4476e14d95416573f", npm + " --omit=dev"], // 7.8.1
    // TypeScript 5.x's own src/compiler, copied from the vendored submodule (plus its generated
    // diagnostics file and @types/node).
    "ts-compiler": null,
};

// Extra tsconfigs (TypeScript 7 removed baseUrl, moduleResolution node10, target es5, ...; these
// keep the projects' settings otherwise). Paths are relative to <work>/configs.
const configs = {
    neverthrow: { compilerOptions: { target: "es2015", module: "ESNext", moduleResolution: "bundler", strict: false, noImplicitAny: true, noUnusedLocals: true, noUnusedParameters: true, strictNullChecks: true, strictFunctionTypes: true, declaration: true, lib: ["dom", "es2016", "es2017.object"], skipLibCheck: true, esModuleInterop: true, types: ["node"], typeRoots: ["../neverthrow/node_modules/@types"], rootDir: "../neverthrow" }, include: ["../neverthrow/src/**/*.ts", "../neverthrow/tests/**/*.ts"] },
    superstruct: { compilerOptions: { allowSyntheticDefaultImports: true, declaration: true, declarationMap: true, esModuleInterop: true, lib: ["esnext"], module: "esnext", moduleResolution: "bundler", sourceMap: true, strict: true, target: "es2020", types: ["node"], typeRoots: ["../superstruct/node_modules/@types"], rootDir: "../superstruct" }, include: ["../superstruct/src/**/*.ts", "../superstruct/test/**/*.ts"] },
    zod: { compilerOptions: { lib: ["es5", "es6", "es7", "esnext", "dom"], target: "es2018", removeComments: false, esModuleInterop: true, moduleResolution: "bundler", module: "esnext", resolveJsonModule: true, strict: true, skipLibCheck: true, strictPropertyInitialization: false, noUnusedLocals: true, noUnusedParameters: true, noImplicitReturns: true, noFallthroughCasesInSwitch: true, isolatedModules: true, types: ["node", "jest"], typeRoots: ["../zod/node_modules/@types"], rootDir: "../zod/src" }, include: ["../zod/src/**/*"] },
    datefns: { compilerOptions: { sourceMap: true, skipLibCheck: true, declaration: true, strict: true, target: "esnext", module: "nodenext", moduleResolution: "nodenext", isolatedModules: true, moduleDetection: "force", allowImportingTsExtensions: true, rewriteRelativeImportExtensions: true, verbatimModuleSyntax: true, lib: ["esnext"], noImplicitOverride: true, types: [], rootDir: "../date-fns/pkgs/core/src" }, include: ["../date-fns/pkgs/core/src/**/*.ts"], exclude: ["**/test.ts", "**/*.test.ts", "**/test.tp.ts", "**/tests.ts", "**/_lib/test/**", "**/*.tp.ts", "**/tp/**"].map((p) => "../date-fns/pkgs/core/src/" + p) },
    preact: { compilerOptions: { allowJs: true, checkJs: true, jsx: "react", jsxFactory: "createElement", jsxFragmentFactory: "Fragment", lib: ["dom", "es2015"], target: "es2015", module: "esnext", moduleResolution: "bundler", skipLibCheck: false, types: [], rootDir: "../preact/src", declaration: true }, include: ["../preact/src/**/*"] },
    chalk: { compilerOptions: { allowJs: true, checkJs: true, lib: ["es2022"], target: "es2022", module: "nodenext", moduleResolution: "nodenext", types: [], rootDir: "../chalk/source", declaration: true, strict: true }, include: ["../chalk/source/**/*.js"] },
    // type-fest checks all of source/ with skipLibCheck false: ~40 s in Go, too slow for Lua; a
    // subset (the closure of three files, ~190 files) instead.
    typefest: { extends: "../type-fest/tsconfig.json", compilerOptions: { rootDir: "../type-fest" }, include: ["camel-case", "split", "join"].map((f) => `../type-fest/source/${f}.d.ts`) },
    rxjs: { compilerOptions: { removeComments: true, preserveConstEnums: true, sourceMap: true, strict: true, noImplicitReturns: true, moduleResolution: "bundler", module: "esnext", stripInternal: true, lib: ["esnext", "dom"], target: "es2015", importHelpers: true, declaration: true, types: [], rootDir: "../rxjs7/src", paths: Object.fromEntries(Object.entries({ "rxjs": "index", "rxjs/operators": "operators/index", "rxjs/testing": "testing/index", "rxjs/ajax": "ajax/index", "rxjs/webSocket": "webSocket/index", "rxjs/fetch": "fetch/index", "rxjs/internal/*": "internal/*" }).map(([k, v]) => [k, ["../rxjs7/src/" + v]])) }, include: ["../rxjs7/src/**/*.ts"] },
};

// [label, cwd (relative to work), args]; `cfg:<name>` -> `-p <relative path to configs/name.json>`.
const jobs = [
    ["ms-noemit", "ms", "--noEmit"],
    ["tiny-noemit", "tiny-invariant", "--noEmit"],
    ["mitt-noemit", "mitt", "--noEmit"],
    ["ms-check", "ms", "--noEmit --types node,jest"],
    ["ms-emit", "ms", "--types node,jest --outDir @OUT@ --declaration --sourceMap --declarationMap"],
    ["ms-isolated", "ms", "--types node,jest --rootDir src --outDir @OUT@ --emitDeclarationOnly"],
    ["tiny-emit", "tiny-invariant", "--target es2015 --moduleResolution bundler --types node,jest --outDir @OUT@ --sourceMap --declaration"],
    ["mitt-emit", "mitt", "--moduleResolution bundler --module esnext --types mocha --noEmit false --outDir @OUT@ --declaration --sourceMap"],
    ["mitt-trace", "mitt", "--traceResolution --noEmit --moduleResolution bundler --module esnext --types mocha"],
    ["ts-pattern-emit", "ts-pattern", "--outDir @OUT@ --sourceMap --declarationMap"],
    ["ts-pattern-emit2", "ts-pattern", "--rootDir src --outDir @OUT@ --sourceMap --declarationMap --target es2017 --module commonjs"],
    ["ts-pattern-listfiles", "ts-pattern", "--listFiles --noEmit"],
    ["neverthrow-emit", "neverthrow", "cfg:neverthrow --outDir @OUT@ --sourceMap --declarationMap"],
    ["neverthrow-es2015-cjs", "neverthrow", "cfg:neverthrow --module commonjs --target es2015 --outDir @OUT@"],
    ["cac-emit", "cac", "--types node --noEmit false --outDir @OUT@"],
    ["cac-explain", "cac", "--explainFiles --noEmit --types node"],
    ["superstruct-emit-pretty", "superstruct", "cfg:superstruct --outDir @OUT@ --pretty"],
    ["superstruct-incremental", "superstruct", "cfg:superstruct --incremental --tsBuildInfoFile @OUT@/x.tsbuildinfo --outDir @OUT@ --inlineSourceMap --sourceMap false --inlineSources"],
    ["inversify-cjs", "inversify", "-p tsconfig.cjs.json --outDir @OUT@"],
    ["inversify-esdec", "inversify", "-p tsconfig.esm.json --experimentalDecorators false --emitDecoratorMetadata false --outDir @OUT@"],
    ["zod-emit", "zod", "cfg:zod --outDir @OUT@ --declaration --sourceMap"],
    ["zod-es2016-cjs", "zod", "cfg:zod --target es2016 --module commonjs --outDir @OUT@ --removeComments"],
    ["datefns-emit", "date-fns/pkgs/core", "cfg:datefns --outDir @OUT@"],
    ["preact-emit", "preact", "cfg:preact --outDir @OUT@ --sourceMap"],
    ["preact-pretty", "preact", "cfg:preact --noEmit --pretty"],
    ["chalk-emit", "chalk", "cfg:chalk --outDir @OUT@"],
    ["chalk-locale", "chalk", "cfg:chalk --noEmit --locale ja --pretty"],
    ["zustand-emit", "zustand", "--noEmit false --rewriteRelativeImportExtensions --outDir @OUT@ --rootDir ."],
    ["zustand-jsxdev", "zustand", "--noEmit false --rewriteRelativeImportExtensions --outDir @OUT@ --rootDir . --jsx react-jsxdev --target es2017 --module commonjs --verbatimModuleSyntax false"],
    ["zustand-jsx-classic", "zustand", "--noEmit false --rewriteRelativeImportExtensions --outDir @OUT@ --rootDir . --jsx react --target es2020 --isolatedDeclarations false"],
    ["ky-emit", "ky", "--outDir @OUT@ --declarationMap --sourceMap"],
    ["ky-emit2", "ky", "--rootDir source --outDir @OUT@ --declarationMap --sourceMap"],
    ["ky-es2015", "ky", "--rootDir source --outDir @OUT@ --target es2015 --sourceMap --noEmitOnError false"],
    ["ky-es2022-nodefine", "ky", "--rootDir source --outDir @OUT@ --target es2022 --useDefineForClassFields false --module commonjs --moduleResolution bundler --noEmitOnError false"],
    ["p-queue-es2015", "p-queue", "--outDir @OUT@ --target es2015 --module commonjs --moduleResolution bundler --noEmitOnError false --declarationMap"],
    ["p-queue-esnext", "p-queue", "--outDir @OUT@ --sourceMap --declarationMap"],
    ["rxjs7-esm2015", "rxjs7", "cfg:rxjs --outDir @OUT@"],
    ["typefest-subset", "type-fest", "cfg:typefest --noEmit"],
    ["ts-compiler", "ts-compiler/src/compiler", "-p . --outDir @OUT@"],
    // composite project references: -b clean / no-op / after an edit
    ["datefns-b", "date-fns", "build pkgs/utc pkgs/tz pkgs/docs pkgs/core --verbose", "pkgs/utc/src/index.ts"],
];

function sh(cmd, cwd) {
    const r = spawnSync("bash", ["-c", cmd], { cwd, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
    if (r.status !== 0) throw new Error(`${cmd} (in ${cwd}) failed:\n${r.stdout}${r.stderr}`);
}

function setup(name) {
    const dir = path.join(work, name);
    if (fs.existsSync(dir)) return;
    if (name === "ts-compiler") {
        const ts = path.join(repoRoot, "vendor/typescript-go/_submodules/TypeScript");
        fs.mkdirSync(path.join(dir, "src"), { recursive: true });
        fs.cpSync(path.join(ts, "src/compiler"), path.join(dir, "src/compiler"), { recursive: true });
        fs.copyFileSync(path.join(ts, "src/tsconfig-base.json"), path.join(dir, "src/tsconfig-base.json"));
        sh(`node ${path.join(ts, "scripts/processDiagnosticMessages.mjs")} src/compiler/diagnosticMessages.json`, dir);
        sh("npm init -y >/dev/null && " + npm + " @types/node@20", dir);
        return;
    }
    const [url, commit, install] = projects[name];
    console.log(`setup ${name}`);
    fs.mkdirSync(dir, { recursive: true });
    sh(`git init -q && git remote add origin ${url} && git fetch -q --depth 1 origin ${commit} && git checkout -q FETCH_HEAD`, dir);
    sh(install, dir);
}

function walk(d, base = d, acc = []) {
    if (!fs.existsSync(d)) return acc;
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.name === "node_modules" || e.name === ".git") continue;
        if (e.isDirectory()) walk(p, base, acc);
        else if (e.isFile()) acc.push(path.relative(base, p));
    }
    return acc.sort();
}

function run(cmd, args, cwd) {
    return new Promise((resolve) => {
        const t = Date.now();
        const p = spawn(cmd, args, { cwd });
        let out = "";
        p.stdout.on("data", (d) => (out += d));
        p.stderr.on("data", (d) => (out += d));
        p.on("close", (status) => resolve({ out, status, ms: Date.now() - t }));
    });
}

const compilers = { go: [tsgo, []], lua: ["lua", [path.join(repoRoot, "bin/tslua")]] };
const stripTime = (s) => s.replace(/^\d+:\d+:\d+ [AP]M - /gm, "");

function compareTrees(a, b, lines) {
    const fa = walk(a), fb = walk(b);
    let ok = true;
    for (const f of [...new Set([...fa, ...fb])].sort()) {
        const x = path.join(a, f), y = path.join(b, f);
        if (!fs.existsSync(x) || !fs.existsSync(y)) {
            lines.push(`  only ${fs.existsSync(x) ? "go" : "lua"}: ${f}`);
            ok = false;
        } else if (!fs.readFileSync(x).equals(fs.readFileSync(y))) {
            lines.push(`  differs: ${f}`);
            ok = false;
        }
    }
    return [ok, fa.length];
}

async function runJob([label, cwdRel, argStr, touch]) {
    const outBase = path.join(work, "out", label);
    fs.rmSync(outBase, { recursive: true, force: true });
    fs.mkdirSync(outBase, { recursive: true });
    const cwd = path.join(work, cwdRel);
    const args = argStr.split(" ").flatMap((a) => (a.startsWith("cfg:") ? ["-p", path.relative(cwd, path.join(work, "configs", a.slice(4) + ".json"))] : [a]));
    const lines = [];
    let ok = true;
    const res = {};
    if (args[0] === "build") {
        for (const [k, [cmd, pre]] of Object.entries(compilers)) {
            const copy = path.join(outBase, k);
            sh(`cp -a --reflink=auto ${JSON.stringify(cwd)} ${JSON.stringify(copy)}`, work);
            const runs = [];
            for (let i = 0; i < 3; i++) {
                if (i === 2 && touch) {
                    const f = path.join(copy, touch);
                    const text = fs.readFileSync(f, "utf8");
                    fs.rmSync(f);
                    fs.writeFileSync(f, text + "\nexport const __edited = 1;\n");
                }
                const r = await run(cmd, [...pre, "-b", ...args.slice(1)], copy);
                runs.push(r);
                fs.writeFileSync(path.join(outBase, `${k}.run${i + 1}.stdout`), r.out + `\nexit ${r.status}\n`);
            }
            res[k] = runs;
        }
        lines.push(`${label}: go ${res.go.map((r) => r.ms + "ms").join("/")} lua ${res.lua.map((r) => r.ms + "ms").join("/")}`);
        for (let i = 0; i < 3; i++) {
            if (stripTime(res.go[i].out) !== stripTime(res.lua[i].out) || res.go[i].status !== res.lua[i].status) {
                lines.push(`  run ${i + 1}: output or exit code differs`);
                ok = false;
            }
        }
        const [same, n] = compareTrees(path.join(outBase, "go"), path.join(outBase, "lua"), lines);
        ok = ok && same;
        lines.push(`  files: ${n}; ${ok ? "IDENTICAL" : "DIFF"}`);
    } else {
        for (const [k, [cmd, pre]] of Object.entries(compilers)) {
            const out = path.join(outBase, k);
            res[k] = await run(cmd, [...pre, ...args.map((a) => a.replaceAll("@OUT@", out))], cwd);
            fs.writeFileSync(path.join(outBase, k + ".stdout"), res[k].out);
        }
        const g = res.go, l = res.lua;
        lines.push(`${label}: go ${g.ms}ms exit ${g.status}; lua ${l.ms}ms exit ${l.status}`);
        if (g.status !== l.status) (ok = false), lines.push("  exit codes differ");
        if (g.out !== l.out) (ok = false), lines.push(`  output differs: diff ${outBase}/{go,lua}.stdout`);
        const [same, n] = compareTrees(path.join(outBase, "go"), path.join(outBase, "lua"), lines);
        ok = ok && same;
        const diags = (g.out.match(/error.{0,12}TS\d+/g) || []).length;
        lines.push(`  files emitted: ${n}; diagnostics: ${diags}; ${ok ? "IDENTICAL" : "DIFF"}`);
    }
    const text = lines.join("\n");
    fs.writeFileSync(path.join(work, "out", label + ".result"), text + "\n");
    console.log(text);
    return ok;
}

fs.mkdirSync(path.join(work, "configs"), { recursive: true });
for (const [name, c] of Object.entries(configs)) fs.writeFileSync(path.join(work, "configs", name + ".json"), JSON.stringify(c, null, 2) + "\n");
const selected = jobs.filter(([label, cwd]) => only.length === 0 || only.includes(label) || only.includes(cwd.split("/")[0]));
for (const name of new Set(selected.map(([, cwd]) => cwd.split("/")[0]))) setup(name);
if (!setupOnly) {
    let failed = 0;
    const queue = [...selected];
    await Promise.all(Array.from({ length: Math.max(1, Math.min(lanes, os.cpus().length)) }, async () => {
        while (queue.length) if (!(await runJob(queue.shift()))) failed++;
    }));
    console.log(`${selected.length - failed}/${selected.length} identical`);
    process.exit(failed ? 1 : 0);
}
