// Generates src/tslua/execute/tsctests/scenarios_*.lua from the scenario definitions in
// internal/execute/tsctests/{tsc,tscbuild,tscwatch,showconfig}_test.go.
//
// The scenarios are Go code (helper closures, fmt.Sprintf, loops), so instead of translating the Go
// source, the real test functions are run with `go test -overlay` and a patched runner: every
// tscInput.run(t, scenario) call dumps the evaluated input (files, command line, cwd, env, ...) as JSON,
// and every edit closure is executed against a recording TestSys that logs the TestSys helper calls
// (writeFileNoError, replaceFileText, ...) instead of performing them. The dump is then written out as
// Lua: one tscInput per scenario, one `function(sys) ... end` per edit replaying the recorded calls.
//
// usage: node scripts/gen/tsctests/gen.mjs [vendor/typescript-go]

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../..");
const upstream = path.resolve(process.argv[2] ?? path.join(root, "vendor/typescript-go"));
const pkgDir = path.join(upstream, "internal/execute/tsctests");
const outDir = path.join(root, "src/tslua/execute/tsctests");

const SOURCES = [
    { goFile: "tsc_test.go", luaFile: "scenarios_tsc.lua" },
    { goFile: "tscbuild_test.go", luaFile: "scenarios_tscbuild.lua" },
    { goFile: "tscwatch_test.go", luaFile: "scenarios_tscwatch.lua" },
    { goFile: "showconfig_test.go", luaFile: "scenarios_showconfig.lua" },
];

function replaceOrThrow(text, from, to) {
    if (!text.includes(from)) {
        throw new Error("patch target not found: " + JSON.stringify(from.slice(0, 80)));
    }
    return text.replace(from, () => to);
}

// ---- 1. Patched overlay of the tsctests package.

function patchRunner(text) {
    return replaceOrThrow(
        text,
        "func (test *tscInput) run(t *testing.T, scenario string) {\n\tt.Helper()\n",
        "func (test *tscInput) run(t *testing.T, scenario string) {\n\tt.Helper()\n\tif dumpScenario(t, test, scenario) {\n\t\treturn\n\t}\n",
    );
}

const RECORDED_HELPERS = [
    "writeFileNoError(path string, content string)",
    "removeNoError(path string)",
    "readFileNoError(path string) string",
    "renameFileNoError(oldPath string, newPath string)",
    "replaceFileText(path string, oldText string, newText string)",
    "replaceFileTextAll(path string, oldText string, newText string)",
    "appendFile(path string, text string)",
    "prependFile(path string, text string)",
];

function patchSys(text) {
    text = replaceOrThrow(text, "\t\"maps\"\n", "\t\"maps\"\n\t\"os\"\n");
    text = replaceOrThrow(text, "\tclock              *TestClock\n}", "\tclock              *TestClock\n\trecorder           *recorder\n}");
    text = replaceOrThrow(text, "func (s *TestSys) Now() time.Time {\n", "func (s *TestSys) Now() time.Time {\n\tif s.recorder != nil {\n\t\treturn recordNowTime\n\t}\n");
    text = replaceOrThrow(text, "func (s *TestSys) FS() vfs.FS {\n", "func (s *TestSys) FS() vfs.FS {\n\tif s.recorder != nil {\n\t\treturn &recordingFs{testFs: s.fs, r: s.recorder}\n\t}\n");
    const fileMapWithBuild = "func GetFileMapWithBuild(files FileMap, commandLineArgs []string) FileMap {\n";
    text = replaceOrThrow(text, fileMapWithBuild, fileMapWithBuild + "\tif os.Getenv(\"TSCTESTS_DUMP\") != \"\" {\n\t\tclone := maps.Clone(files)\n\t\tclone[fromBuildKey] = append([]string{}, commandLineArgs...)\n\t\treturn clone\n\t}\n");
    for (const sig of RECORDED_HELPERS) {
        const name = sig.slice(0, sig.indexOf("("));
        const params = sig.slice(sig.indexOf("(") + 1, sig.indexOf(")")).split(",").map(p => p.trim().split(" ")[0]);
        const returns = sig.endsWith(") string");
        const header = "func (s *TestSys) " + sig + " {\n";
        const call = `s.recorder.call("${name}", ${params.join(", ")})`;
        const body = returns
            ? `\tif s.recorder != nil {\n\t\treturn ${call}\n\t}\n`
            : `\tif s.recorder != nil {\n\t\t${call}\n\t\treturn\n\t}\n`;
        text = replaceOrThrow(text, header, header + body);
    }
    return text;
}

function goTestNames(goFile) {
    const text = fs.readFileSync(path.join(pkgDir, goFile), "utf8");
    return [...text.matchAll(/^func (Test\w+)\(t \*testing\.T\)/gm)].map(m => m[1]);
}

function dumpScenarios() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tsctests-gen-"));
    const runner = path.join(tmp, "runner.go");
    const sys = path.join(tmp, "sys.go");
    const dump = path.join(tmp, "dump.go");
    fs.writeFileSync(runner, patchRunner(fs.readFileSync(path.join(pkgDir, "runner.go"), "utf8")));
    fs.writeFileSync(sys, patchSys(fs.readFileSync(path.join(pkgDir, "sys.go"), "utf8")));
    fs.copyFileSync(path.join(here, "overlay_dump.go"), dump);
    const overlay = path.join(tmp, "overlay.json");
    fs.writeFileSync(overlay, JSON.stringify({
        Replace: {
            [path.join(pkgDir, "runner.go")]: runner,
            [path.join(pkgDir, "sys.go")]: sys,
            [path.join(pkgDir, "zz_dump.go")]: dump,
        },
    }));
    const names = SOURCES.flatMap(s => goTestNames(s.goFile));
    const out = path.join(tmp, "scenarios.json");
    execFileSync("go", ["test", "-overlay", overlay, "-count=1", "-run", `^(${names.join("|")})$`, "./internal/execute/tsctests"], {
        cwd: upstream,
        env: { ...process.env, TSCTESTS_DUMP: out },
        stdio: ["ignore", "inherit", "inherit"],
    });
    const scenarios = JSON.parse(fs.readFileSync(out, "utf8"));
    fs.rmSync(tmp, { recursive: true, force: true });
    return scenarios;
}

// ---- 2. Lua emission.

function luaString(s, indent) {
    if (s.includes("\n") && !s.includes("\r")) {
        let level = 0;
        while (s.includes("]" + "=".repeat(level) + "]") || s.endsWith("]" + "=".repeat(level))) {
            level++;
        }
        const eq = "=".repeat(level);
        // The newline right after the opening bracket is skipped by Lua.
        return `[${eq}[\n${s}]${eq}]`;
    }
    let out = "\"";
    for (const ch of s) {
        const c = ch.codePointAt(0);
        if (ch === "\\") out += "\\\\";
        else if (ch === "\"") out += "\\\"";
        else if (ch === "\n") out += "\\n";
        else if (ch === "\r") out += "\\r";
        else if (ch === "\t") out += "\\t";
        else if (c < 0x20 || c === 0x7f) out += "\\" + String(c).padStart(3, "0");
        else out += ch;
    }
    return out + "\"";
}

function luaStringArray(arr) {
    return "{ " + arr.map(a => luaString(a)).join(", ") + (arr.length ? " }" : "}");
}

function luaArg(a) {
    if (typeof a === "string") return luaString(a);
    if (a.read !== undefined) return `sys:readFileNoError(${luaString(a.read)})`;
    if (a.zeroTime) return "0";
    if (a.now) return "sys:Now()";
    throw new Error("unknown arg " + JSON.stringify(a));
}

function emitOps(ops, ind) {
    const lines = [];
    for (const op of ops) {
        const [name, ...args] = op;
        if (name === "readFileNoError") {
            // only ever used as the argument of the following call
            continue;
        }
        if (name === "FS().Chtimes") {
            lines.push(`${ind}local err = sys:FS():Chtimes(${args.map(luaArg).join(", ")})`);
            lines.push(`${ind}if err ~= nil then`);
            lines.push(`${ind}    error(err, 0)`);
            lines.push(`${ind}end`);
            continue;
        }
        lines.push(`${ind}sys:${name}(${args.map(luaArg).join(", ")})`);
    }
    return lines;
}

function emitFiles(files, ind) {
    if (!files || files.length === 0) return "{}";
    const lines = ["{"];
    for (const f of files) {
        const value = f.symlink ? `vfstest.Symlink(${luaString(f.data)})` : luaString(f.data);
        lines.push(`${ind}    [${luaString(f.path)}] = ${value},`);
    }
    lines.push(`${ind}}`);
    return lines.join("\n");
}

function emitInput(s, ind) {
    const i1 = ind + "    ";
    const lines = [`${ind}tsctests.newTscInput({`];
    lines.push(`${i1}subScenario = ${luaString(s.subScenario)},`);
    if (s.commandLineArgs != null) lines.push(`${i1}commandLineArgs = ${luaStringArray(s.commandLineArgs)},`);
    if (s.filesFromBuild) {
        lines.push(`${i1}-- GetFileMapWithBuild runs a build: deferred until the scenario runs`);
        lines.push(`${i1}files = function()`);
        lines.push(`${i1}    return tsctests.GetFileMapWithBuild(${emitFiles(s.files, i1 + "    ")}, ${luaStringArray(s.filesFromBuild)})`);
        lines.push(`${i1}end,`);
    } else {
        lines.push(`${i1}files = ${emitFiles(s.files, i1)},`);
    }
    if (s.cwd) lines.push(`${i1}cwd = ${luaString(s.cwd)},`);
    if (s.env && Object.keys(s.env).length) {
        lines.push(`${i1}env = {`);
        for (const k of Object.keys(s.env).sort()) lines.push(`${i1}    [${luaString(k)}] = ${luaString(s.env[k])},`);
        lines.push(`${i1}},`);
    }
    if (s.ignoreCase) lines.push(`${i1}ignoreCase = true,`);
    if (s.windowsStyleRoot) lines.push(`${i1}windowsStyleRoot = ${luaString(s.windowsStyleRoot)},`);
    if (s.edits) {
        lines.push(`${i1}edits = {`);
        for (const e of s.edits) {
            const i2 = i1 + "    ";
            if (e.noChange) {
                lines.push(`${i2}tsctests.noChange,`);
                continue;
            }
            lines.push(`${i2}tsctests.newTscEdit({`);
            const i3 = i2 + "    ";
            lines.push(`${i3}caption = ${luaString(e.caption)},`);
            if (e.commandLineArgs) lines.push(`${i3}commandLineArgs = ${luaStringArray(e.commandLineArgs)},`);
            if (e.expectedDiff) lines.push(`${i3}expectedDiff = ${luaString(e.expectedDiff)},`);
            if (e.ops) {
                const body = emitOps(e.ops, i3 + "    ");
                if (body.length === 0) {
                    lines.push(`${i3}edit = function(sys) end,`);
                } else {
                    lines.push(`${i3}edit = function(sys)`);
                    lines.push(...body);
                    lines.push(`${i3}end,`);
                }
            }
            lines.push(`${i2}}),`);
        }
        lines.push(`${i1}},`);
    }
    lines.push(`${ind}}),`);
    return lines.join("\n");
}

function emitFile(source, tests) {
    const out = [];
    out.push(`-- Code generated by scripts/gen/tsctests/gen.mjs from internal/execute/tsctests/${source.goFile}; DO NOT EDIT.`);
    out.push("--");
    out.push("-- One entry per Go test function, in source order: { name, scenario, cases = function() -> []*tscInput }.");
    out.push("-- Each case is run with tscInput:run(t, scenario), like the Go test function does.");
    out.push("-- luacheck: ignore 611 612 613 614 (file contents keep their whitespace)");
    out.push("local tsctests = require(\"tslua.execute.tsctests\")");
    if (tests.some(t => t.cases.some(c => c.files?.some(f => f.symlink)))) {
        out.push("local vfstest = require(\"tslua.vfs.vfstest\")");
    }
    out.push("");
    out.push("local tests = {}");
    for (const t of tests) {
        out.push("");
        out.push("tests[#tests + 1] = {");
        out.push(`    name = ${luaString(t.name)},`);
        out.push(`    scenario = ${luaString(t.scenario)},`);
        out.push("    cases = function()");
        out.push("        return {");
        for (const c of t.cases) out.push(emitInput(c, "            "));
        out.push("        }");
        out.push("    end,");
        out.push("}");
    }
    out.push("");
    out.push("return tests");
    out.push("");
    return out.join("\n");
}

const scenarios = dumpScenarios();
for (const source of SOURCES) {
    const tests = [];
    for (const name of goTestNames(source.goFile)) {
        const cases = scenarios.filter(s => s.goTest === name);
        if (cases.length === 0) continue;
        const scenarioNames = [...new Set(cases.map(c => c.scenario))];
        if (scenarioNames.length !== 1) throw new Error(`${name}: several scenarios ${scenarioNames}`);
        tests.push({ name, scenario: scenarioNames[0], cases });
    }
    fs.writeFileSync(path.join(outDir, source.luaFile), emitFile(source, tests));
    console.log(`${source.luaFile}: ${tests.length} test functions, ${tests.reduce((n, t) => n + t.cases.length, 0)} scenarios`);
}
