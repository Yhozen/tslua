// Groups baseline-run failures for triage.
// Usage: node scripts/triage.mjs [tests/out] [run-log]
// Prints crash signatures (error message with numbers stripped) by frequency, plus, for
// .errors.txt diffs, the diagnostic codes that are missing or extra compared to the reference.
import fs from "node:fs";
import path from "node:path";

const outDir = process.argv[2] ?? "tests/out";
const log = process.argv[3] ?? ".context/run-all.txt";

function walk(dir, acc = []) {
    if (!fs.existsSync(dir)) return acc;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, acc);
        else acc.push(p);
    }
    return acc;
}

const files = walk(outDir);
const crashes = new Map();
for (const f of files.filter(f => f.endsWith(".crash.txt"))) {
    const lines = fs.readFileSync(f, "utf8").split("\n");
    const msg = (lines[1] ?? "").replace(/^.*?src\/tslua\//, "").trim();
    const sig = msg.replace(/:\d+:/, ":N:");
    const e = crashes.get(sig) ?? { n: 0, examples: [] };
    e.n++;
    if (e.examples.length < 3) e.examples.push(path.basename(f).replace(/\.crash\.txt$/, ""));
    crashes.set(sig, e);
}
console.log(`== crash signatures (${[...crashes.values()].reduce((a, e) => a + e.n, 0)} crashed cases)`);
for (const [sig, e] of [...crashes].sort((a, b) => b[1].n - a[1].n).slice(0, 60)) {
    console.log(String(e.n).padStart(5), sig, "  e.g.", e.examples.join(", "));
}

const missing = new Map(), extra = new Map();
const refRoot = process.env.TSLUA_REFERENCE ?? "vendor/typescript-go/testdata/baselines/reference";
const codeRe = /^!!! error TS(\d+):/;
const count = text => {
    const m = new Map();
    for (const line of text.split("\n")) {
        const c = codeRe.exec(line.trim());
        if (c) m.set(c[1], (m.get(c[1]) ?? 0) + 1);
    }
    return m;
};
const add = (map, code, n, name) => {
    const e = map.get(code) ?? { n: 0, cases: 0, examples: new Set() };
    e.n += n;
    e.cases++;
    if (e.examples.size < 3) e.examples.add(name);
    map.set(code, e);
};
for (const f of files.filter(f => f.endsWith(".errors.txt"))) {
    const rel = path.relative(outDir, f);
    const ref = path.join(refRoot, rel);
    const actual = count(fs.readFileSync(f, "utf8"));
    const expected = fs.existsSync(ref) ? count(fs.readFileSync(ref, "utf8")) : new Map();
    const name = path.basename(f, ".errors.txt");
    for (const [code, n] of expected) if ((actual.get(code) ?? 0) < n) add(missing, code, n - (actual.get(code) ?? 0), name);
    for (const [code, n] of actual) if ((expected.get(code) ?? 0) < n) add(extra, code, n - (expected.get(code) ?? 0), name);
}
const show = (title, map) => {
    console.log(`== ${title}`);
    for (const [code, e] of [...map].sort((a, b) => b[1].n - a[1].n).slice(0, 40)) {
        console.log(String(e.cases).padStart(5), "cases", String(e.n).padStart(5), "TS" + code, "  e.g.", [...e.examples].join(", "));
    }
};
show("diagnostics present in reference but missing in tslua (-)", missing);
show("diagnostics produced by tslua but not in reference (+)", extra);

if (fs.existsSync(log)) {
    const summary = fs.readFileSync(log, "utf8").split("\n").filter(l => /^(baseline|errors|js|types|symbols|sourcemap)\s/.test(l) || /case files in/.test(l));
    console.log("== summary\n" + summary.join("\n"));
}
