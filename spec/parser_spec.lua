local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

local function parse(text, fileName)
    fileName = fileName or "/test.ts"
    local opts = ast.NewSourceFileParseOptions(fileName, fileName, nil)
    return parser.ParseSourceFile(opts, text, core.GetScriptKindFromFileName(fileName))
end

-- Renders the tree as nested "Kind pos-end" lines (2-space indentation).
local function shape(node)
    local out = {}
    local function walk(n, depth)
        out[#out + 1] = string.rep("  ", depth) .. ast.Kind_names[n.kind] .. " " .. n.loc.pos .. "-" .. n.loc.end_
        n:ForEachChild(function(c)
            walk(c, depth + 1)
            return false
        end)
    end
    walk(node, 0)
    return table.concat(out, "\n")
end

local function diags(file)
    local result = {}
    for _, d in ipairs(file:Diagnostics() or {}) do
        result[#result + 1] = { code = d:Code(), pos = d:Pos(), end_ = d:End() }
    end
    return result
end

local function checkParents(node)
    local ok = true
    node:ForEachChild(function(c)
        if c.parent ~= node then
            ok = false
            return true
        end
        if not checkParents(c) then
            ok = false
            return true
        end
        return false
    end)
    return ok
end

describe("parser", function()
    it("parses a variable statement with a binary expression", function()
        local file = parse("let x: number = 1 + 2 * 3;")
        assert.are.equal([[
SourceFile 0-26
  VariableStatement 0-26
    VariableDeclarationList 0-25
      VariableDeclaration 3-25
        Identifier 3-5
        NumberKeyword 6-13
        BinaryExpression 15-25
          NumericLiteral 15-17
          PlusToken 17-19
          BinaryExpression 19-25
            NumericLiteral 19-21
            AsteriskToken 21-23
            NumericLiteral 23-25
  EndOfFile 26-26]], shape(file))
        assert.are.same({}, diags(file))
        assert.is_true(file.statements.nodes[1].declarationList.flags & NodeFlags.Let ~= 0)
        assert.is_true(checkParents(file))
    end)

    it("parses arrow functions speculatively and rewinds on failure", function()
        local file = parse("const f = (a, b) => a; const g = (a, b);")
        local f = file.statements.nodes[1].declarationList.declarations.nodes[1].initializer
        local g = file.statements.nodes[2].declarationList.declarations.nodes[1].initializer
        assert.are.equal(Kind.ArrowFunction, f.kind)
        assert.are.equal(2, #f.parameters.nodes)
        assert.are.equal(Kind.ParenthesizedExpression, g.kind)
        assert.are.equal(Kind.BinaryExpression, g.expression.kind)
        assert.are.same({}, diags(file))
    end)

    it("distinguishes type arguments from comparisons", function()
        local file = parse("f<number>(1); a < b > c;")
        local call = file.statements.nodes[1].expression
        assert.are.equal(Kind.CallExpression, call.kind)
        assert.are.equal(1, #call.typeArguments.nodes)
        local cmp = file.statements.nodes[2].expression
        assert.are.equal(Kind.BinaryExpression, cmp.kind)
        assert.are.equal(Kind.GreaterThanToken, cmp.operatorToken.kind)
    end)

    it("parses classes, interfaces and types", function()
        local file = parse([[
export default class Foo<T> extends Bar implements I {
    private x?: number = 1;
    constructor(public z: string) { super(); }
    get v(): T { return this.x as any; }
}
interface I { (x: number): string; readonly [k: string]: any }
type M<T> = { [K in keyof T]?: T[K] } | (T extends string ? 1 : 2);
]])
        local kinds = {}
        for i, s in ipairs(file.statements.nodes) do
            kinds[i] = ast.Kind_names[s.kind]
        end
        assert.are.same({ "ClassDeclaration", "InterfaceDeclaration", "TypeAliasDeclaration" }, kinds)
        local class = file.statements.nodes[1]
        assert.are.equal(3, #class.members.nodes)
        assert.are.equal(Kind.Constructor, class.members.nodes[2].kind)
        assert.are.equal(Kind.UnionType, file.statements.nodes[3].type.kind)
        assert.are.same({}, diags(file))
        assert.is_true(checkParents(file))
        assert.is_not_nil(file.externalModuleIndicator)
    end)

    it("reports missing tokens", function()
        local file = parse("if (x { }")
        assert.are.same({ { code = 1005, pos = 6, end_ = 7 } }, diags(file))
    end)

    it("leaves empty declaration lists to the checker", function()
        local file = parse("var")
        assert.are.same({}, diags(file))
        assert.are.equal(0, #file.statements.nodes[1].declarationList.declarations.nodes)
    end)

    it("reports unknown keywords with a suggestion", function()
        local file = parse("functon f() {}")
        local d = diags(file)
        assert.are.equal(1435, d[1].code) -- Unknown keyword or identifier. Did you mean 'function'?
        assert.are.equal(0, d[1].pos)
        assert.are.equal(7, d[1].end_)
    end)

    it("reports one diagnostic per position", function()
        local file = parse("let = ;")
        local d = diags(file)
        for i = 2, #d do
            assert.are_not.equal(d[i - 1].pos, d[i].pos)
        end
    end)

    it("parses JSX in tsx files", function()
        local file = parse("let a = <div className='x'>hi {name}<br/></div>;", "/test.tsx")
        local init = file.statements.nodes[1].declarationList.declarations.nodes[1].initializer
        assert.are.equal(Kind.JsxElement, init.kind)
        assert.are.equal(3, #init.children.nodes)
        assert.are.same({}, diags(file))
    end)

    it("reports mismatched JSX closing tags", function()
        local file = parse("let a = <div></span>;", "/test.tsx")
        assert.are.same({ { code = 17002, pos = 15, end_ = 19 } }, diags(file)) -- Expected corresponding JSX closing tag for div.
    end)

    it("parses JSON files and validates values", function()
        local file = parse('{ "a": [1, -2, true, null], b: \'x\' }', "/test.json")
        local d = diags(file)
        local codes = {}
        for i, x in ipairs(d) do
            codes[i] = x.code
        end
        assert.are.same({ 1327, 1327 }, codes) -- String literal with double quotes expected.
    end)

    it("reparses top-level await in modules", function()
        local file = parse("export {}; await (x);")
        local stmt = file.statements.nodes[2]
        assert.are.equal(Kind.ExpressionStatement, stmt.kind)
        assert.are.equal(Kind.AwaitExpression, stmt.expression.kind)
        assert.are.equal(file, stmt.parent)
        local script = parse("await (x);")
        assert.are.equal(Kind.CallExpression, script.statements.nodes[1].expression.kind)
    end)

    it("reparses JSDoc tags in JavaScript files", function()
        local file = parse([[
/** @typedef {{a: number}} T */
/**
 * @param {string} s
 * @returns {number}
 */
function f(s) { return 1; }
]], "/test.js")
        local kinds = {}
        for i, s in ipairs(file.statements.nodes) do
            kinds[i] = ast.Kind_names[s.kind]
        end
        assert.are.same({ "JSTypeAliasDeclaration", "FunctionDeclaration" }, kinds)
        local fn = file.statements.nodes[2]
        assert.are.equal(Kind.StringKeyword, fn.parameters.nodes[1].type.kind)
        assert.are.equal(Kind.NumberKeyword, fn.type.kind)
        assert.is_true(fn.flags & NodeFlags.HasJSDoc ~= 0)
        local jsdoc = fn:JSDoc(file)
        assert.are.equal(2, #jsdoc)
        assert.are.equal(2, #jsdoc[2].tags.nodes)
    end)

    it("lazily parses JSDoc in TypeScript files", function()
        local file = parse("/** Doc @deprecated */\nfunction f() {}")
        local fn = file.statements.nodes[1]
        assert.is_true(fn.flags & NodeFlags.HasJSDoc ~= 0)
        local jsdoc = fn:JSDoc(file)
        assert.are.equal(1, #jsdoc)
        assert.are.equal(Kind.JSDocDeprecatedTag, jsdoc[1].tags.nodes[1].kind)
    end)

    it("reports TypeScript-only syntax in JavaScript files", function()
        local file = parse("let x: number = 1; interface I {}", "/test.js")
        local codes = {}
        for i, d in ipairs(file:JSDiagnostics()) do
            codes[i] = d:Code()
        end
        assert.are.same({ 8010, 8006 }, codes)
    end)

    it("collects pragmas and reference directives", function()
        local file = parse('/// <reference path="a.ts" />\n/// <reference types="node" />\n// @ts-nocheck\nlet x;')
        assert.are.equal(1, #file.referencedFiles)
        assert.are.equal("a.ts", file.referencedFiles[1].fileName)
        assert.are.equal(1, #file.typeReferenceDirectives)
        assert.are.equal("node", file.typeReferenceDirectives[1].fileName)
        assert.is_false(file.checkJsDirective.enabled)
    end)

    it("collects imports", function()
        local file = parse('import a from "a"; export * from "b"; declare module "c" { import d from "./d"; }')
        local names = {}
        for i, n in ipairs(file:Imports()) do
            names[i] = n:Text()
        end
        assert.are.same({ "a", "b" }, names)
    end)

    it("parses isolated entity names", function()
        local name = parser.ParseIsolatedEntityName("a.b.c")
        assert.are.equal(Kind.QualifiedName, name.kind)
        assert.is_nil(parser.ParseIsolatedEntityName("a.b c"))
    end)
end)
