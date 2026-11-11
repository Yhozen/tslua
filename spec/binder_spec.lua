local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")
local binder = require("tslua.binder")
local evaluator = require("tslua.evaluator")
local diagnostics = require("tslua.diagnostics")

local SymbolFlags = ast.SymbolFlags
local NodeFlags = ast.NodeFlags

local function parse(text, fileName)
    fileName = fileName or "/test.ts"
    local opts = {
        fileName = fileName,
        path = fileName,
        externalModuleIndicatorOptions = { jsx = false, force = false },
    }
    return parser.ParseSourceFile(opts, text, core.GetScriptKindFromFileName(fileName))
end

local function bind(text, fileName)
    local file = parse(text, fileName)
    binder.BindSourceFile(file)
    return file
end

local function codes(file)
    local result = {}
    for _, d in ipairs(file:BindDiagnostics() or {}) do
        result[#result + 1] = d:Code()
    end
    return result
end

local function has(flags, f)
    return flags & f ~= 0
end

describe("binder", function()
    it("declares script locals", function()
        local file = bind("var x = 1; function f() {} let y; class C {} interface I {} type T = number;")
        local locals = file.locals
        assert.is_not_nil(locals)
        assert.is_true(has(locals.x.flags, SymbolFlags.FunctionScopedVariable))
        assert.is_true(has(locals.f.flags, SymbolFlags.Function))
        assert.is_true(has(locals.y.flags, SymbolFlags.BlockScopedVariable))
        assert.is_true(has(locals.C.flags, SymbolFlags.Class))
        assert.is_true(has(locals.I.flags, SymbolFlags.Interface))
        assert.is_true(has(locals.T.flags, SymbolFlags.TypeAlias))
        assert.is_nil(file.symbol)
        assert.are.same({}, codes(file))
        assert.are.equal(locals.f, file.statements.nodes[2].symbol)
        assert.are.equal(file.statements.nodes[2].symbol.valueDeclaration, file.statements.nodes[2])
    end)

    it("binds module exports with local and export symbols", function()
        local file = bind("export const y = 1; export function g() {} const z = 2; export default class {}")
        assert.is_not_nil(file.symbol)
        assert.is_true(has(file.symbol.flags, SymbolFlags.ValueModule))
        assert.are.equal("\"/test\"", file.symbol.name)
        local exports = file.symbol.exports
        assert.is_true(has(exports.y.flags, SymbolFlags.BlockScopedVariable))
        assert.is_true(has(exports.g.flags, SymbolFlags.Function))
        assert.is_not_nil(exports.default)
        assert.is_true(has(exports.default.flags, SymbolFlags.Class))
        assert.is_nil(exports.z)
        local localY = file.locals.y
        assert.are.equal(SymbolFlags.ExportValue, localY.flags)
        assert.are.equal(exports.y, localY.exportSymbol)
        assert.are.equal(file.symbol, exports.y.parent)
        assert.is_true(has(file.locals.z.flags, SymbolFlags.BlockScopedVariable))
    end)

    it("binds class members and the prototype property", function()
        local file = bind("class C { x: number; static s = 1; m() {} constructor(public p: string) {} get a() { return 1 } }")
        local sym = file.locals.C
        assert.is_true(has(sym.members.x.flags, SymbolFlags.Property))
        assert.is_true(has(sym.members.m.flags, SymbolFlags.Method))
        assert.is_true(has(sym.members.p.flags, SymbolFlags.Property))
        assert.is_true(has(sym.members.a.flags, SymbolFlags.GetAccessor))
        assert.is_not_nil(sym.members[ast.InternalSymbolNameConstructor])
        assert.is_true(has(sym.exports.s.flags, SymbolFlags.Property))
        assert.is_true(has(sym.exports.prototype.flags, SymbolFlags.Prototype))
        assert.are.equal(sym, sym.exports.prototype.parent)
    end)

    it("reports duplicate block-scoped declarations", function()
        local file = bind("let a = 1;\nlet a = 2;")
        assert.are.same({ 2451, 2451 }, codes(file))
        local d = file:BindDiagnostics()[1]
        assert.are.equal(4, d:Pos())
        assert.are.equal(1, d:Len())
    end)

    it("reports duplicate identifiers and enum merge errors", function()
        assert.are.same({ 2300, 2300 }, codes(bind("class D {}\nclass D {}")))
        assert.are.same({ 2567, 2567 }, codes(bind("enum E { A }\nvar E;")))
    end)

    it("reports multiple default exports with related info", function()
        local file = bind("export default class A {}\nexport default class B {}")
        assert.are.same({ 2528, 2528 }, codes(file))
        assert.are.equal(1, #file:BindDiagnostics()[1]:RelatedInformation())
    end)

    it("reports strict mode errors", function()
        assert.are.same({ 1102 }, codes(bind("export {}; var x; delete x;")))
        assert.are.same({ 1215 }, codes(bind("export {}; var eval = 1;")))
        assert.are.same({ 1213 }, codes(bind("class K { m() { var implements = 1; } }")))
        assert.are.same({ 1101 }, codes(bind("with (x) {}")))
    end)

    it("binds parameters, block scopes and type parameters", function()
        local file = bind("function f<T>(a: T, [b, c]: number[]) { let x; { let y; } }")
        local fn = file.statements.nodes[1]
        assert.is_true(has(fn.locals.T.flags, SymbolFlags.TypeParameter))
        assert.is_true(has(fn.locals.a.flags, SymbolFlags.FunctionScopedVariable))
        assert.is_true(has(fn.locals.b.flags, SymbolFlags.FunctionScopedVariable))
        assert.is_true(has(fn.locals.x.flags, SymbolFlags.BlockScopedVariable))
        assert.is_nil(fn.locals.y)
        assert.are.equal("__1", fn.parameters.nodes[2].symbol.name)
        local inner = fn.body.statements.nodes[2]
        assert.is_true(has(inner.locals.y.flags, SymbolFlags.BlockScopedVariable))
    end)

    it("builds the control flow graph", function()
        local file = bind("function f(x: string | number) { if (typeof x === 'string') { return x; } return x; x; }")
        local fn = file.statements.nodes[1]
        assert.is_false(has(fn.flags, NodeFlags.HasExplicitReturn))
        local stmts = fn.body.statements.nodes
        assert.is_true(has(stmts[3].flags, NodeFlags.Unreachable))
        assert.is_false(has(stmts[1].flags, NodeFlags.Unreachable))
        local ret = stmts[1].thenStatement.statements.nodes[1]
        local id = ret.expression
        assert.is_not_nil(id.flowNode)
        assert.is_true(has(id.flowNode.flags, ast.FlowFlags.TrueCondition))
        local g = bind("function g() { let a = 1; }").statements.nodes[1]
        assert.is_true(has(g.flags, NodeFlags.HasImplicitReturn))
        assert.is_not_nil(g.endFlowNode)
    end)

    it("binds namespaces and const-enum-only modules", function()
        local file = bind("namespace N { export const enum E { A } }\nnamespace M { export var v = 1; }\nnamespace T { export type X = 1; }")
        assert.is_true(has(file.locals.N.flags, SymbolFlags.ConstEnumOnlyModule))
        assert.is_true(has(file.locals.N.flags, SymbolFlags.ValueModule))
        assert.is_true(has(file.locals.M.flags, SymbolFlags.ValueModule))
        assert.is_true(has(file.locals.T.flags, SymbolFlags.NamespaceModule))
        assert.is_false(has(file.locals.T.flags, SymbolFlags.ValueModule))
        assert.is_true(has(file.locals.M.exports.v.flags, SymbolFlags.FunctionScopedVariable))
    end)

    it("binds ambient modules and pattern ambient modules", function()
        local file = bind("declare module \"foo\" { export const a: number; }\ndeclare module \"*.css\" {}\ndeclare module \"a*b*\" {}", "/test.d.ts")
        assert.is_not_nil(file.locals["\"foo\""])
        assert.is_not_nil(file.locals["\"foo\""].exports.a)
        assert.are.equal(1, #file.patternAmbientModules)
        assert.are.same({ 5061 }, codes(file))
    end)

    it("binds CommonJS modules in JS files", function()
        local file = bind("const fs = require('fs');\nmodule.exports.x = 1;\nexports.y = 2;", "/test.js")
        assert.is_not_nil(file.commonJSModuleIndicator)
        assert.is_not_nil(file.symbol)
        assert.is_true(has(file.locals.fs.flags, SymbolFlags.Alias))
        assert.is_not_nil(file.locals.module)
        assert.is_not_nil(file.locals.exports)
        assert.is_not_nil(file.symbol.exports.y)
    end)

    it("binds expando assignments", function()
        local file = bind("function f() {}\nf.prop = 1;")
        assert.is_true(has(file.locals.f.exports.prop.flags, SymbolFlags.Assignment))
    end)

    it("binds only once", function()
        local file = bind("let a; let a;")
        local count = file.symbolCount
        binder.BindSourceFile(file)
        assert.are.equal(count, file.symbolCount)
        assert.are.equal(2, #file:BindDiagnostics())
    end)

    it("formats private identifier symbol names", function()
        local file = bind("class P { #x = 1; }")
        local sym = file.locals.P
        local found = false
        for name in pairs(sym.members) do
            if string.find(name, "#x", 1, true) then
                found = true
                assert.are.equal(binder.GetSymbolNameForPrivateIdentifier(sym, "#x"), name)
            end
        end
        assert.is_true(found)
    end)
end)

describe("NameResolver", function()
    it("resolves names through scopes", function()
        local file = bind("var g = 1; function f(p) { let l; l; p; g; }")
        local fn = file.statements.nodes[2]
        local exprStmt = fn.body.statements.nodes[2]
        local resolver = setmetatable({
            compilerOptions = core.NewCompilerOptions and core.NewCompilerOptions() or {},
            globals = file.locals,
        }, binder.NameResolver)
        local l = resolver:Resolve(exprStmt.expression, "l", SymbolFlags.Value, nil, false, false)
        assert.are.equal(fn.locals.l, l)
        local p = resolver:Resolve(exprStmt.expression, "p", SymbolFlags.Value, nil, false, false)
        assert.are.equal(fn.locals.p, p)
        local g = resolver:Resolve(exprStmt.expression, "g", SymbolFlags.Value, nil, false, false)
        assert.are.equal(file.locals.g, g)
        assert.is_nil(resolver:Resolve(exprStmt.expression, "nope", SymbolFlags.Value, nil, false, false))
        local args = resolver:Resolve(exprStmt.expression, "arguments", SymbolFlags.Value, nil, false, false)
        assert.are.equal("arguments", args.name)
    end)

    it("reports failures through the hook", function()
        local file = bind("function f() { x; }")
        local stmt = file.statements.nodes[1].body.statements.nodes[1]
        local failed
        local resolver = setmetatable({
            compilerOptions = {},
            globals = {},
            onFailedToResolveSymbol = function(location, name, meaning, message)
                failed = { name, message }
            end,
        }, binder.NameResolver)
        assert.is_nil(resolver:Resolve(stmt.expression, "x", SymbolFlags.Value, diagnostics.Cannot_find_name_0, true, false))
        assert.are.same({ "x", diagnostics.Cannot_find_name_0 }, failed)
    end)
end)

describe("ReferenceResolver", function()
    it("finds referenced value declarations", function()
        local file = bind("export {}; var v = 1; function f() { v; }")
        local ref = file.statements.nodes[3].body.statements.nodes[1].expression
        local rr = binder.NewReferenceResolver({}, {})
        assert.are.equal(file.statements.nodes[2].declarationList.declarations.nodes[1], rr:GetReferencedValueDeclaration(ref))
        assert.are.equal(1, #rr:GetReferencedValueDeclarations(ref))
        assert.is_nil(rr:GetReferencedImportDeclaration(ref))
    end)
end)

describe("evaluator", function()
    local function evalExpr(text)
        local file = parse("x = " .. text .. ";")
        local expr = file.statements.nodes[1].expression.right
        local ev = evaluator.NewEvaluator(function(e, loc)
            return evaluator.NewResult(nil, false, false, false)
        end, ast.OuterExpressionKinds.OEKParentheses)
        return ev(expr, nil)
    end

    it("evaluates constant expressions", function()
        assert.are.equal(7, evalExpr("1 + 2 * 3").value)
        assert.are.equal(-1, evalExpr("~0").value)
        assert.are.equal(8, evalExpr("1 << 3").value)
        assert.are.equal(1, evalExpr("7 % 3").value)
        assert.are.equal(8, evalExpr("2 ** 3").value)
        assert.are.equal("a1", evalExpr("'a' + 1").value)
        assert.is_true(evalExpr("'a' + 1").isSyntacticallyString)
        assert.are.equal("x2y", evalExpr("`x${1 + 1}y`").value)
        assert.is_nil(evalExpr("foo").value)
        assert.are.equal(0.5, evalExpr("(1) / 2").value)
    end)

    it("converts values", function()
        assert.are.equal("1.5", evaluator.AnyToString(1.5))
        assert.are.equal("true", evaluator.AnyToString(true))
        assert.is_false(evaluator.IsTruthy(""))
        assert.is_false(evaluator.IsTruthy(0.0))
        assert.is_false(evaluator.IsTruthy(0 / 0))
        assert.is_true(evaluator.IsTruthy("a"))
    end)
end)
