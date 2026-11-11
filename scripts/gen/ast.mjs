// Generates src/tslua/ast/ast_generated.lua from typescript-go's _scripts/ast.json.
// This is the Lua analogue of _scripts/generate-go-ast.ts (same traversal, same output order),
// reusing the shared schema API from _scripts/schema.ts.
// Usage: node scripts/gen/ast.mjs <typescript-go dir>
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(process.argv[2] ?? "vendor/typescript-go");
const { api, kindGuardName } = await import(pathToFileURL(path.join(root, "_scripts/schema.ts")).href);

// ── Naming ────────────────────────────────────────────────────────────────

const LUA_KEYWORDS = new Set([
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
]);

function luaName(name) {
    return LUA_KEYWORDS.has(name) ? name + "_" : name;
}

// lowerCamelCase of a Go field name: the leading run of capitals is lowered
// (Text -> text, ID -> id, JSDoc -> jsDoc, URLPath -> urlPath).
function lowerCamel(name) {
    const m = /^[A-Z]+/.exec(name);
    if (!m) return name;
    const run = m[0];
    if (run.length === name.length) return name.toLowerCase();
    if (run.length === 1) return run.toLowerCase() + name.slice(1);
    return run.slice(0, -1).toLowerCase() + name.slice(run.length - 1);
}

function fieldName(m) {
    return luaName(lowerCamel(m.name));
}

function paramName(m) {
    return luaName(m.goParamName());
}

// Go constant names (as used by the Go generator) -> Lua constant references.
const CONST_GROUPS = ["NodeFlags", "TokenFlags", "ModifierFlags", "SubtreeFacts", "Kind"];
function luaConst(goName) {
    for (const g of CONST_GROUPS) {
        if (goName.startsWith(g)) return `${g}.${goName.slice(g.length)}`;
    }
    throw new Error(`unknown constant ${goName}`);
}

function kindConst(kindType) {
    // kindType.formatGoConstant() is "Kind<Name>"
    return luaConst(kindType.formatGoConstant());
}

// ── Helpers mirrored from generate-go-ast.ts ──────────────────────────────

function schemaMembers(node) {
    return node.members.filter(m => !m.noFactory);
}

function isTextContentType(type) {
    if (type.kind === "primitive") {
        return type.name === "string";
    }
    if (type.kind === "list" && type.listKind === "raw") {
        return type.elementType.kind === "primitive" && type.elementType.name === "string";
    }
    return false;
}

function hasTextContent(node) {
    if (node.members.length === 0) return false;
    return schemaMembers(node).some(m => isTextContentType(m.type));
}

function isNodeFlagsMember(m) {
    const type = m.type;
    return type.kind === "primitive" && type.name === "NodeFlags";
}

function isZeroSizeBase(key) {
    const base = api.getBase(key);
    return !!base && base.extendsKeys.length === 0 && base.fields.length === 0;
}

function goEmbeds(extendsKeys) {
    const zeroSized = [];
    const nonZeroSized = [];
    for (const key of extendsKeys) {
        if (isZeroSizeBase(key)) zeroSized.push(key);
        else nonZeroSized.push(key);
    }
    return [...zeroSized, ...nonZeroSized];
}

const HAND_WRITTEN_BASES = new Set(["NodeBase"]);

// Zero value of a Go field type, or undefined when the Go zero value is nil.
function zeroValue(rawType) {
    if (Array.isArray(rawType)) return undefined;
    switch (rawType) {
        case "int":
        case "NodeFlags":
        case "TokenFlags":
        case "ModifierFlags":
        case "Kind":
        case "atomic.Uint32":
            return "0";
        case "bool":
            return "false";
        case "string":
            return '""';
    }
    return undefined;
}

// All Go struct fields of a node struct (own members and fields of embedded bases), as
// { name, rawType, kindParam } entries. Used to initialize Go zero values.
function structFields(node) {
    const result = new Map();
    const addBase = key => {
        if (key === "NodeBase") return; // Kind/Flags/Loc/Parent live on Node; set by newNode
        const base = api.getBase(key);
        if (!base) return;
        for (const ext of goEmbeds(base.extendsKeys)) addBase(ext);
        for (const f of base.fields) {
            if (f.noGo) continue;
            const isKind = typeof f.rawType === "string" && (f.rawType === "Kind" || f.rawType.startsWith("SyntaxKind."));
            result.set(f.name, { name: f.name, rawType: f.rawType, isKind });
        }
    };
    for (const ext of goEmbeds(node.extendsKeys)) addBase(ext);
    for (const m of node.members) {
        if (m.noGo) continue;
        if (m.isKindParam()) continue;
        const raw = m.goOnly ? m.rawType : m.rawType;
        const declared = m.declaredType;
        let rawType = raw;
        if (!m.goOnly) {
            if (declared.kind === "kind" || (declared.kind === "alias" && declared.baseKind() === "kind") || declared.kind === "union" && declared.baseKind() === "kind") rawType = "Kind";
            else if (declared.kind === "primitive") rawType = declared.name;
            if (m.listKind) rawType = "list";
        }
        result.set(m.name, { name: m.name, rawType });
    }
    return [...result.values()];
}

// ── Code writer ───────────────────────────────────────────────────────────

class CodeWriter {
    lines = [];
    indent = 0;
    write(line = "") {
        if (line === "") this.lines.push("");
        else this.lines.push("    ".repeat(this.indent) + line);
    }
    push() { this.indent++; }
    pop() { this.indent--; }
    toString() { return this.lines.join("\n"); }
}

// ── Sections ──────────────────────────────────────────────────────────────

function generateHeader(w) {
    w.write("-- Code generated by scripts/gen/ast.mjs from typescript-go _scripts/ast.json. DO NOT EDIT.");
    w.write("-- Mirrors internal/ast/ast_generated.go (see docs/AST.md).");
    w.write("local ast = require(\"tslua.ast\")");
    w.write("local core = require(\"tslua.core\")");
    w.write("local Kind = ast.Kind");
    w.write("local NodeFlags = ast.NodeFlags");
    w.write("local TokenFlags = ast.TokenFlags");
    w.write("");
    w.write("ast.Node = ast.Node or {}");
    w.write("ast.Node.__index = ast.Node");
    w.write("ast.Node.__name = \"Node\"");
    w.write("");
    w.write("-- luacheck: no max line length");
    w.write("");
}

// Lua-side model of Go struct embedding. Every Go struct (node data structs and their embedded
// bases) gets a method table. ast.FinalizeStructs (called by init.lua after every file of the
// package is loaded) copies promoted methods into each table following Go's selector rules:
// a method defined at a shallower embedding depth wins.
function generateStructInfrastructure(w) {
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("-- Struct embedding");
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("");
    w.write("ast.structEmbeds = {}");
    w.write("ast.structNames = {}");
    w.write("");
    w.write("function ast.DefineStruct(name, embeds)");
    w.push();
    w.write("local t = ast[name]");
    w.write("if t == nil then");
    w.push();
    w.write("t = {}");
    w.write("ast[name] = t");
    w.pop();
    w.write("end");
    w.write("t.__index = t");
    w.write("t.__name = name");
    w.write("if ast.structEmbeds[name] == nil then");
    w.push();
    w.write("ast.structNames[#ast.structNames + 1] = name");
    w.pop();
    w.write("end");
    w.write("ast.structEmbeds[name] = embeds");
    w.write("return t");
    w.pop();
    w.write("end");
    w.write("");
    w.write("local function collectPromoted(name, depth, out, seen)");
    w.push();
    w.write("local embeds = ast.structEmbeds[name]");
    w.write("if embeds == nil then");
    w.push();
    w.write("return");
    w.pop();
    w.write("end");
    w.write("for _, base in ipairs(embeds) do");
    w.push();
    w.write("local t = ast[base]");
    w.write("for k, v in pairs(t) do");
    w.push();
    w.write("if type(v) == \"function\" and k ~= \"__index\" then");
    w.push();
    w.write("local prev = seen[k]");
    w.write("if prev == nil or prev > depth then");
    w.push();
    w.write("seen[k] = depth");
    w.write("out[k] = v");
    w.pop();
    w.write("end");
    w.pop();
    w.write("end");
    w.pop();
    w.write("end");
    w.write("collectPromoted(base, depth + 1, out, seen)");
    w.pop();
    w.write("end");
    w.pop();
    w.write("end");
    w.write("");
    w.write("function ast.FinalizeStructs()");
    w.push();
    w.write("for _, name in ipairs(ast.structNames) do");
    w.push();
    w.write("local t = ast[name]");
    w.write("local out, seen = {}, {}");
    w.write("collectPromoted(name, 1, out, seen)");
    w.write("for k, v in pairs(out) do");
    w.push();
    w.write("if rawget(t, k) == nil then");
    w.push();
    w.write("t[k] = v");
    w.pop();
    w.write("end");
    w.pop();
    w.write("end");
    w.write("if getmetatable(t) == nil and name ~= \"Node\" then");
    w.push();
    w.write("setmetatable(t, { __index = ast.Node })");
    w.pop();
    w.write("end");
    w.pop();
    w.write("end");
    w.pop();
    w.write("end");
    w.write("");
    w.write("function ast.badCast(node, name)");
    w.push();
    w.write("error(\"interface conversion: node is \" .. tostring(getmetatable(node) and getmetatable(node).__name) .. \", not \" .. name, 2)");
    w.pop();
    w.write("end");
    w.write("");
}

function generateNodeFactoryStruct(w) {
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("-- NodeFactory");
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("");
    w.write("local NodeFactory = ast.NodeFactory or {}");
    w.write("NodeFactory.__index = NodeFactory");
    w.write("NodeFactory.__name = \"NodeFactory\"");
    w.write("ast.NodeFactory = NodeFactory");
    w.write("");
}

function generateBaseStructDefs(w) {
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("-- Base struct definitions");
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("");
    for (const base of api.bases()) {
        if (HAND_WRITTEN_BASES.has(base.key)) continue;
        const exts = goEmbeds(base.extendsKeys).map(e => JSON.stringify(e)).join(", ");
        w.write(`ast.DefineStruct(${JSON.stringify(base.key)}, { ${exts} })`);
    }
    w.write("");
}

function generateStructDef(w, node) {
    const exts = goEmbeds(node.extendsKeys).map(e => JSON.stringify(e)).join(", ");
    w.write(`ast.DefineStruct(${JSON.stringify(node.name)}, { ${exts} })`);
    w.write("");
}

function goSubtreeFactsTerm(m) {
    const access = `self.${fieldName(m)}`;
    if (m.listKind === "ModifierList") {
        return `ast.propagateModifierListSubtreeFacts(${access})`;
    }
    if (m.type.kind === "list") {
        return `ast.propagateNodeListSubtreeFacts(${access}, ast.propagateSubtreeFacts)`;
    }
    return `ast.propagateSubtreeFacts(${access})`;
}

function generateSubtreeFacts(w, node) {
    if (!node.generateSubtreeFacts) return;
    const childMembers = schemaMembers(node).filter(m => m.isChild());
    w.write(`function ast.${node.name}:computeSubtreeFacts()`);
    w.push();
    if (childMembers.length === 0) {
        w.write("return ast.SubtreeFacts.None");
    }
    else {
        for (let index = 0; index < childMembers.length; index++) {
            const term = goSubtreeFactsTerm(childMembers[index]);
            if (index === 0) {
                const suffix = childMembers.length > 1 ? " |" : "";
                w.write(`return ${term}${suffix}`);
            }
            else {
                const suffix = index < childMembers.length - 1 ? " |" : "";
                w.write(`    ${term}${suffix}`);
            }
        }
    }
    w.pop();
    w.write("end");
    w.write("");
}

function generateAsCast(w, name) {
    w.write(`function ast.Node:As${name}()`);
    w.push();
    w.write(`if getmetatable(self) ~= ast.${name} then`);
    w.push();
    w.write(`ast.badCast(self, ${JSON.stringify(name)})`);
    w.pop();
    w.write("end");
    w.write("return self");
    w.pop();
    w.write("end");
    w.write("");
}

function emitNewFactory(w, funcName, kindName, node, members, kindMember, nodeFlagsMembers) {
    const params = members.map(m => paramName(m)).join(", ");
    w.write(`function NodeFactory:${funcName}(${params})`);
    w.push();

    // Go zero values of struct fields not assigned below.
    const assigned = new Set(members.filter(m => !m.isKindParam() && !isNodeFlagsMember(m)).map(m => m.name));
    const entries = [];
    for (const f of structFields(node)) {
        if (assigned.has(f.name)) continue;
        if (f.name === "Flags") continue;
        const z = zeroValue(f.rawType);
        if (z !== undefined) entries.push(`${luaName(lowerCamel(f.name))} = ${z}`);
    }
    for (const m of members) {
        if (m.isKindParam()) continue;
        if (isNodeFlagsMember(m)) continue;
        const value = m.bitmask ? `${paramName(m)} & ${luaConst(m.bitmask)}` : paramName(m);
        entries.push(`${fieldName(m)} = ${value}`);
    }
    if (entries.length === 0) {
        w.write(`local data = setmetatable({}, ast.${node.name})`);
    }
    else {
        w.write(`local data = setmetatable({`);
        w.push();
        for (const e of entries) w.write(`${e},`);
        w.pop();
        w.write(`}, ast.${node.name})`);
    }

    if (hasTextContent(node)) {
        w.write("self.textCount = self.textCount + 1");
    }

    const kindArg = kindMember ? paramName(kindMember) : `Kind.${kindName}`;

    if (nodeFlagsMembers.length > 0) {
        w.write(`local node = self:newNode(${kindArg}, data)`);
        for (const m of nodeFlagsMembers) {
            const param = paramName(m);
            if (m.bitmask) {
                w.write(`node.flags = node.flags | (${param} & ${luaConst(m.bitmask)})`);
            }
            else {
                w.write(`node.flags = ${param}`);
            }
        }
        w.write("return node");
    }
    else {
        w.write(`return self:newNode(${kindArg}, data)`);
    }
    w.pop();
    w.write("end");
    w.write("");
}

function generateNewFactory(w, node) {
    const members = schemaMembers(node);
    const kindMember = members.find(m => m.isKindParam());
    const nodeFlagsMembers = members.filter(m => isNodeFlagsMember(m));
    emitNewFactory(w, `New${node.name}`, node.syntaxKindName, node, members, kindMember, nodeFlagsMembers);
    for (const alias of node.kindAliases) {
        emitNewFactory(w, `New${alias}`, alias, node, members, kindMember, nodeFlagsMembers);
    }
}

function generateUpdateFactory(w, node) {
    const members = schemaMembers(node);
    const updateMembers = members.filter(m => !m.isKindParam());
    if (updateMembers.length === 0) return;
    if (!updateMembers.some(m => m.isChild())) return;

    const params = ["node", ...updateMembers.map(m => paramName(m))].join(", ");
    w.write(`function NodeFactory:Update${node.name}(${params})`);
    w.push();

    const comparisons = updateMembers.map(m => {
        const type = m.type;
        if (type.kind === "list" && type.listKind === "raw") {
            return `not core.Same(${paramName(m)}, node.${fieldName(m)})`;
        }
        return `${paramName(m)} ~= node.${fieldName(m)}`;
    });
    w.write(`if ${comparisons.join(" or ")} then`);
    w.push();

    const newArgs = members.map(m => (m.isKindParam() ? "node.kind" : paramName(m))).join(", ");

    if (node.kindAliases.length > 0) {
        w.write(`if node.kind == ${kindConst(api.kindType(`SyntaxKind.${node.syntaxKindName}`))} then`);
        w.push();
        w.write(`return ast.updateNode(self:New${node.name}(${newArgs}), node, self.hooks)`);
        w.pop();
        for (const alias of node.kindAliases) {
            w.write(`elseif node.kind == Kind.${alias} then`);
            w.push();
            w.write(`return ast.updateNode(self:New${alias}(${newArgs}), node, self.hooks)`);
            w.pop();
        }
        w.write("else");
        w.push();
        w.write(`error("unexpected kind in Update${node.name}: " .. ast.Kind_String(node.kind))`);
        w.pop();
        w.write("end");
    }
    else {
        w.write(`return ast.updateNode(self:New${node.name}(${newArgs}), node, self.hooks)`);
    }
    w.pop();
    w.write("end");
    w.write("return node");
    w.pop();
    w.write("end");
    w.write("");
}

function generateForEachChild(w, node) {
    const members = schemaMembers(node);
    const childMembers = members.filter(m => m.isChild());
    if (childMembers.length === 0) return;

    w.write(`function ast.${node.name}:ForEachChild(v)`);
    w.push();
    if (node.handWrittenVisitor) {
        w.write(`return ast.forEachChild_${node.name}(self, v)`);
        w.pop();
        w.write("end");
        w.write("");
        return;
    }
    const parts = childMembers.map(m => {
        const access = `self.${fieldName(m)}`;
        const listKind = m.listKind;
        if (listKind === "raw") return `ast.visitNodes(v, ${access})`;
        if (listKind === "ModifierList") return `ast.visitModifiers(v, ${access})`;
        if (listKind === "NodeList") return `ast.visitNodeList(v, ${access})`;
        return `ast.visit(v, ${access})`;
    });
    if (parts.length <= 3) {
        w.write(`return ${parts.join(" or ")}`);
    }
    else {
        w.write(`return ${parts[0]} or`);
        for (let i = 1; i < parts.length - 1; i++) {
            w.write(`    ${parts[i]} or`);
        }
        w.write(`    ${parts[parts.length - 1]}`);
    }
    w.pop();
    w.write("end");
    w.write("");
}

function generateVisitEachChild(w, node) {
    const members = schemaMembers(node);
    const childMembers = members.filter(m => m.isChild());
    if (childMembers.length === 0) return;

    w.write(`function ast.${node.name}:VisitEachChild(v)`);
    w.push();
    if (node.handWrittenVisitor) {
        w.write(`return ast.visitEachChild_${node.name}(self, v)`);
        w.pop();
        w.write("end");
        w.write("");
        return;
    }

    const updateMembers = members.filter(m => !m.isKindParam());
    const rawListLocals = new Map();
    for (const m of updateMembers) {
        const type = m.type;
        if (m.isChild() && type.kind === "list" && type.listKind === "raw") {
            const localName = paramName(m);
            rawListLocals.set(m.name, localName);
            w.write(`local ${localName} = core.SameMap(self.${fieldName(m)}, function(n) return v:visitNode(n) end)`);
        }
    }

    const args = updateMembers.map(m => {
        const access = `self.${fieldName(m)}`;
        if (!m.isChild()) return access;
        if (rawListLocals.has(m.name)) return rawListLocals.get(m.name);
        const type = m.type;
        const listKind = m.listKind;
        if (m.visit) return `v:visit${api.capitalize(m.visit)}(${access})`;
        if (listKind === "ModifierList") return `v:visitModifiers(${access})`;
        if (listKind === "NodeList") return `v:visitNodes(${access})`;
        if (type.kind === "primitive" && type.name === "Token") return `v:visitToken(${access})`;
        return `v:visitNode(${access})`;
    }).join(", ");

    w.write(`return v.factory:Update${node.name}(self, ${args})`);
    w.pop();
    w.write("end");
    w.write("");
}

function generateClone(w, node) {
    const members = schemaMembers(node);
    w.write(`function ast.${node.name}:Clone(f)`);
    w.push();
    const args = members.map(m => {
        if (m.isKindParam()) return "self.kind";
        const type = m.declaredType;
        if (m.inherited && type?.kind === "alias" && type.name === "ModifierLike") {
            return "self:Modifiers()";
        }
        return `self.${fieldName(m)}`;
    }).join(", ");

    if (node.kindAliases.length > 0) {
        w.write(`if self.kind == ${kindConst(api.kindType(`SyntaxKind.${node.syntaxKindName}`))} then`);
        w.push();
        w.write(`return ast.cloneNode(f:AsNodeFactory():New${node.name}(${args}), self, f:AsNodeFactory().hooks)`);
        w.pop();
        for (const alias of node.kindAliases) {
            w.write(`elseif self.kind == Kind.${alias} then`);
            w.push();
            w.write(`return ast.cloneNode(f:AsNodeFactory():New${alias}(${args}), self, f:AsNodeFactory().hooks)`);
            w.pop();
        }
        w.write("else");
        w.push();
        w.write(`error("unexpected kind in ${node.name}.Clone: " .. ast.Kind_String(self.kind))`);
        w.pop();
        w.write("end");
    }
    else {
        w.write(`return ast.cloneNode(f:AsNodeFactory():New${node.name}(${args}), self, f:AsNodeFactory().hooks)`);
    }
    w.pop();
    w.write("end");
    w.write("");
}

function writeKindSet(w, funcName, param, kinds) {
    // switch with many cases -> lookup set
    const setName = `ast.${funcName}_kinds`;
    w.write(`${setName} = {`);
    w.push();
    for (const k of kinds) w.write(`[${k}] = true,`);
    w.pop();
    w.write("}");
    w.write(`function ast.${funcName}(${param})`);
    w.push();
    const access = param === "node" ? "node.kind" : param;
    w.write(`return ${setName}[${access}] == true`);
    w.pop();
    w.write("end");
    w.write("");
}

function generateIsFunction(w, node) {
    const kindTypes = node.kindTypes();
    if (node.kindType.kind === "typeParameter") {
        writeKindSet(w, `Is${node.name}`, "node", kindTypes.map(kindConst));
        return;
    }
    if (node.isMultiKind()) {
        for (const kind of kindTypes) {
            w.write(`function ast.Is${kind.name}(node)`);
            w.push();
            w.write(`return node.kind == ${kindConst(kind)}`);
            w.pop();
            w.write("end");
            w.write("");
        }
        return;
    }
    w.write(`function ast.Is${node.name}(node)`);
    w.push();
    w.write(`return node.kind == ${kindConst(api.kindType(`SyntaxKind.${node.syntaxKindName}`))}`);
    w.pop();
    w.write("end");
    w.write("");
    for (const alias of node.kindAliases) {
        w.write(`function ast.Is${alias}(node)`);
        w.push();
        w.write(`return node.kind == Kind.${alias}`);
        w.pop();
        w.write("end");
        w.write("");
    }
}

function goKindGuardName(aliasName) {
    const tsName = kindGuardName(aliasName);
    return tsName.charAt(0).toUpperCase() + tsName.slice(1);
}

function generateKindAliasGuards(w) {
    const skipGuards = new Set(["IsJSDocKind"]);
    for (const guard of api.kindGuards()) {
        const funcName = goKindGuardName(guard.aliasName);
        if (skipGuards.has(funcName)) continue;
        if (guard.type === "range") {
            w.write(`function ast.${funcName}(kind)`);
            w.push();
            w.write(`return kind >= Kind.${guard.first} and kind <= Kind.${guard.last}`);
            w.pop();
            w.write("end");
            w.write("");
        }
        else {
            const expanded = api.expandKindAliasMembers(guard.aliasName);
            writeKindSet(w, funcName, "kind", expanded.map(kindConst));
        }
    }
}

function generateNameAccessor(w, node) {
    const members = schemaMembers(node);
    const nameMember = members.find(m => m.name === "name");
    if (!nameMember) return;
    const isPrivate = nameMember.inherited
        ? (nameMember.inheritedField?.private || false)
        : (nameMember.private || false);
    if (!isPrivate) return;
    w.write(`function ast.${node.name}:Name()`);
    w.push();
    w.write("return self.name");
    w.pop();
    w.write("end");
    w.write("");
}

// Field-name collision check (PORTING.md: foo/Foo -> foo/foo_). None exist today; fail loudly if
// the schema ever introduces one so the generator can be taught the rule.
function checkFieldCollisions() {
    const reserved = new Set(["kind", "flags", "loc", "parent", "id"]);
    for (const node of api.nodes()) {
        if (node.handWritten) continue;
        const seen = new Map();
        for (const f of structFields(node)) {
            const n = luaName(lowerCamel(f.name));
            if (seen.has(n) && seen.get(n) !== f.name) {
                throw new Error(`field name collision in ${node.name}: ${seen.get(n)} / ${f.name}`);
            }
            if (reserved.has(n) && f.name !== "Flags") {
                throw new Error(`field ${node.name}.${f.name} collides with a Node field`);
            }
            seen.set(n, f.name);
        }
    }
}

function generate() {
    checkFieldCollisions();
    const w = new CodeWriter();
    generateHeader(w);
    generateStructInfrastructure(w);
    generateNodeFactoryStruct(w);
    generateBaseStructDefs(w);

    for (const node of api.nodes()) {
        w.write("-- ──────────────────────────────────────────────────────────────────────");
        w.write(`-- ${node.name}`);
        w.write("-- ──────────────────────────────────────────────────────────────────────");
        w.write("");
        if (!node.handWritten) {
            generateStructDef(w, node);
            generateNewFactory(w, node);
            generateUpdateFactory(w, node);
            generateForEachChild(w, node);
            generateVisitEachChild(w, node);
            generateClone(w, node);
            generateSubtreeFacts(w, node);
            generateNameAccessor(w, node);
        }
        generateIsFunction(w, node);
        if (node.handWritten) {
            w.write("-- Struct and factory methods hand-written in ./ast.lua");
            w.write("");
        }
    }

    // ForEachChild dispatch: Go's (*Node).ForEachChild switches on Kind to the concrete
    // struct's ForEachChild. In Lua, method lookup through the node's struct metatable is that
    // dispatch; kinds without children resolve to NodeDefault.ForEachChild (returns false).

    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("-- As*() cast methods");
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("");
    for (const node of api.nodes()) {
        generateAsCast(w, node.name);
    }

    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("-- Kind alias guards");
    w.write("-- ──────────────────────────────────────────────────────────────────────");
    w.write("");
    generateKindAliasGuards(w);

    return w.toString();
}

const out = generate() + "\n";
const outPath = path.resolve("src/tslua/ast/ast_generated.lua");
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, out);
console.log(`wrote ${outPath} (${out.split("\n").length} lines)`);
