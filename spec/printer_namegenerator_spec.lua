-- Port of internal/printer/namegenerator_test.go
local binder = require("tslua.binder")
local core = require("tslua.core")
local parser = require("tslua.parser")
local printer = require("tslua.printer")

-- parsetestutil.ParseTypeScript
local function parseTypeScript(text, jsx)
    local fileName = jsx and "/main.tsx" or "/main.ts"
    return parser.ParseSourceFile({ fileName = fileName, path = fileName, externalModuleIndicatorOptions = { jsx = false, force = false } }, text, core.GetScriptKindFromFileName(fileName))
end

-- &printer.NameGenerator{Context: ec, GetTextOfNode: getTextOfNode}
local function newNameGenerator(ec, getTextOfNode)
    local g = printer.NewNameGenerator()
    g.context = ec
    g.getTextOfNode = getTextOfNode
    return g
end

-- (*ast.Node).Text
local function nodeText(n)
    return n:Text()
end

describe("TestTempVariable1", function()
    it("TestTempVariable1", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewTempVariable()
        local name2 = ec.factory:NewTempVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("_a", text1)
        assert.are.equal("_b", text2)
    end)
end)

describe("TestTempVariable2", function()
    it("TestTempVariable2", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewTempVariableEx({
            prefix = "A",
            suffix = "B",
        })
        local name2 = ec.factory:NewTempVariableEx({
            prefix = "A",
            suffix = "B",
        })

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("A_aB", text1)
        assert.are.equal("A_bB", text2)
    end)
end)

describe("TestTempVariable3", function()
    it("TestTempVariable3", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewTempVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name1)

        assert.are.equal("_a", text1)
        assert.are.equal("_a", text2)
    end)
end)

describe("TestTempVariableScoped", function()
    it("TestTempVariableScoped", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewTempVariable()
        local name2 = ec.factory:NewTempVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        g:PushScope(false)
        local text2 = g:GenerateName(name2)
        g:PopScope(false)

        assert.are.equal("_a", text1)
        assert.are.equal("_a", text2)
    end)
end)

describe("TestTempVariableScopedReserved", function()
    it("TestTempVariableScopedReserved", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewTempVariableEx({ flags = printer.GeneratedIdentifierFlagsReservedInNestedScopes })
        local name2 = ec.factory:NewTempVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        g:PushScope(false)
        local text2 = g:GenerateName(name2)
        g:PopScope(false)

        assert.are.equal("_a", text1)
        assert.are.equal("_b", text2)
    end)
end)

describe("TestLoopVariable1", function()
    it("TestLoopVariable1", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewLoopVariable()
        local name2 = ec.factory:NewLoopVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("_i", text1)
        assert.are.equal("_a", text2)
    end)
end)

describe("TestLoopVariable2", function()
    it("TestLoopVariable2", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewLoopVariableEx({
            prefix = "A",
            suffix = "B",
        })
        local name2 = ec.factory:NewLoopVariableEx({
            prefix = "A",
            suffix = "B",
        })

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("A_iB", text1)
        assert.are.equal("A_aB", text2)
    end)
end)

describe("TestLoopVariable3", function()
    it("TestLoopVariable3", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewLoopVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name1)

        assert.are.equal("_i", text1)
        assert.are.equal("_i", text2)
    end)
end)

describe("TestLoopVariableScoped", function()
    it("TestLoopVariableScoped", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewLoopVariable()
        local name2 = ec.factory:NewLoopVariable()

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        g:PushScope(false)
        local text2 = g:GenerateName(name2)
        g:PopScope(false)

        assert.are.equal("_i", text1)
        assert.are.equal("_i", text2)
    end)
end)

describe("TestUniqueName1", function()
    it("TestUniqueName1", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewUniqueName("foo")
        local name2 = ec.factory:NewUniqueName("foo")

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("foo_1", text1)
        assert.are.equal("foo_2", text2)
    end)
end)

describe("TestUniqueName2", function()
    it("TestUniqueName2", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewUniqueName("foo")

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name1)

        assert.are.equal("foo_1", text1)
        -- Expected to be same because GenerateName goes off object identity
        assert.are.equal("foo_1", text2)
    end)
end)

describe("TestUniqueNameScoped", function()
    it("TestUniqueNameScoped", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewUniqueName("foo")
        local name2 = ec.factory:NewUniqueName("foo")

        local g = newNameGenerator(ec)
        assert.are.equal("foo_1", g:GenerateName(name1))

        g:PushScope(false)
        assert.are.equal("foo_2", g:GenerateName(name2)) -- Matches Strada, but is incorrect
        g:PopScope(false)
    end)
end)

describe("TestUniquePrivateName1", function()
    it("TestUniquePrivateName1", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewUniquePrivateName("#foo")
        local name2 = ec.factory:NewUniquePrivateName("#foo")

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("#foo_1", text1)
        assert.are.equal("#foo_2", text2)
    end)
end)

describe("TestUniquePrivateName2", function()
    it("TestUniquePrivateName2", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewUniquePrivateName("#foo")

        local g = newNameGenerator(ec)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name1)

        assert.are.equal("#foo_1", text1)
        assert.are.equal("#foo_1", text2)
    end)
end)

describe("TestUniquePrivateNameScoped", function()
    it("TestUniquePrivateNameScoped", function()
        local ec = printer.NewEmitContext()
        local name1 = ec.factory:NewUniquePrivateName("#foo")
        local name2 = ec.factory:NewUniquePrivateName("#foo")

        local g = newNameGenerator(ec)
        assert.are.equal("#foo_1", g:GenerateName(name1))

        g:PushScope(false) -- private names are always reserved in nested scopes
        assert.are.equal("#foo_2", g:GenerateName(name2))
        g:PopScope(false)
    end)
end)

describe("TestGeneratedNameForIdentifier1", function()
    it("TestGeneratedNameForIdentifier1", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("function f() {}", false --[[jsx]])
        binder.BindSourceFile(file)

        local n = file.statements.nodes[1]:Name()
        local name1 = ec.factory:NewGeneratedNameForNode(n)

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name1)

        assert.are.equal("f_1", text1)
    end)
end)

describe("TestGeneratedNameForIdentifier2", function()
    it("TestGeneratedNameForIdentifier2", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("function f() {}", false --[[jsx]])
        binder.BindSourceFile(file)

        local n = file.statements.nodes[1]:Name()
        local name1 = ec.factory:NewGeneratedNameForNodeEx(n, {
            prefix = "a",
            suffix = "b",
        })

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name1)

        assert.are.equal("afb", text1)
    end)
end)

describe("TestGeneratedNameForIdentifier3", function()
    it("TestGeneratedNameForIdentifier3", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("function f() {}", false --[[jsx]])
        binder.BindSourceFile(file)

        local n = file.statements.nodes[1]:Name()
        local name1 = ec.factory:NewGeneratedNameForNodeEx(n, {
            prefix = "a",
            suffix = "b",
        })
        local name2 = ec.factory:NewGeneratedNameForNode(name1)

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name2)

        assert.are.equal("afb_1", text1)
    end)
end)

-- namespace reuses name if it does not collide with locals
describe("TestGeneratedNameForNamespace1", function()
    it("TestGeneratedNameForNamespace1", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("namespace foo { }", false --[[jsx]])
        binder.BindSourceFile(file)

        local ns1 = file.statements.nodes[1]
        local name1 = ec.factory:NewGeneratedNameForNode(ns1)

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name1)

        assert.are.equal("foo", text1)
    end)
end)

-- namespace uses generated name if it collides with locals
describe("TestGeneratedNameForNamespace2", function()
    it("TestGeneratedNameForNamespace2", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("namespace foo { var foo; }", false --[[jsx]])
        binder.BindSourceFile(file)

        local ns1 = file.statements.nodes[1]
        local name1 = ec.factory:NewGeneratedNameForNode(ns1)

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name1)

        assert.are.equal("foo_1", text1)
    end)
end)

-- avoids collisions when unscoped
describe("TestGeneratedNameForNamespace3", function()
    it("TestGeneratedNameForNamespace3", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("namespace ns1 { namespace foo { var foo; } } namespace ns2 { namespace foo { var foo; } }", false --[[jsx]])
        binder.BindSourceFile(file)

        local ns1 = file.statements.nodes[1]:Body():Statements()[1]
        local ns2 = file.statements.nodes[2]:Body():Statements()[1]
        local name1 = ec.factory:NewGeneratedNameForNode(ns1)
        local name2 = ec.factory:NewGeneratedNameForNode(ns2)

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("foo_1", text1)
        assert.are.equal("foo_2", text2)
    end)
end)

-- reuse name when scoped
describe("TestGeneratedNameForNamespace4", function()
    it("TestGeneratedNameForNamespace4", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("namespace ns1 { namespace foo { var foo; } } namespace ns2 { namespace foo { var foo; } }", false --[[jsx]])
        binder.BindSourceFile(file)

        local ns1 = file.statements.nodes[1]:Body():Statements()[1]
        local ns2 = file.statements.nodes[2]:Body():Statements()[1]
        local name1 = ec.factory:NewGeneratedNameForNode(ns1)
        local name2 = ec.factory:NewGeneratedNameForNode(ns2)

        local g = newNameGenerator(ec, nodeText)
        g:PushScope(false)
        local text1 = g:GenerateName(name1)
        g:PopScope(false)

        g:PushScope(false)
        local text2 = g:GenerateName(name2)
        g:PopScope(false)

        assert.are.equal("foo_1", text1)
        assert.are.equal("foo_2", text2) -- Matches Strada, but is incorrect
    end)
end)

describe("TestGeneratedNameForNodeCached", function()
    it("TestGeneratedNameForNodeCached", function()
        local ec = printer.NewEmitContext()

        local file = parseTypeScript("namespace foo { var foo; }", false --[[jsx]])
        binder.BindSourceFile(file)

        local ns1 = file.statements.nodes[1]
        local name1 = ec.factory:NewGeneratedNameForNode(ns1)
        local name2 = ec.factory:NewGeneratedNameForNode(ns1)

        local g = newNameGenerator(ec, nodeText)
        local text1 = g:GenerateName(name1)
        local text2 = g:GenerateName(name2)

        assert.are.equal("foo_1", text1)
        assert.are.equal("foo_1", text2)
    end)
end)

-- Tests that parse `input`, bind, take statement 0 (or `select(file)`), call `newName(ec.factory, n)`
-- and check the generated text.
local function checkGeneratedName(input, expected, select, newName)
    local ec = printer.NewEmitContext()

    local file = parseTypeScript(input, false --[[jsx]])
    binder.BindSourceFile(file)

    local n = select and select(file, ec) or file.statements.nodes[1]
    local name1 = newName and newName(ec.factory, n) or ec.factory:NewGeneratedNameForNode(n)

    local g = newNameGenerator(ec, nodeText)
    local text1 = g:GenerateName(name1)

    assert.are.equal(expected, text1)
end

describe("TestGeneratedNameForImport", function()
    it("TestGeneratedNameForImport", function()
        checkGeneratedName("import * as foo from 'foo'", "foo_1")
    end)
end)

describe("TestGeneratedNameForExport", function()
    it("TestGeneratedNameForExport", function()
        checkGeneratedName("export * as foo from 'foo'", "foo_1")
    end)
end)

describe("TestGeneratedNameForFunctionDeclaration1", function()
    it("TestGeneratedNameForFunctionDeclaration1", function()
        checkGeneratedName("export function f() {}", "f_1")
    end)
end)

describe("TestGeneratedNameForFunctionDeclaration2", function()
    it("TestGeneratedNameForFunctionDeclaration2", function()
        checkGeneratedName("export default function () {}", "default_1")
    end)
end)

describe("TestGeneratedNameForClassDeclaration1", function()
    it("TestGeneratedNameForClassDeclaration1", function()
        checkGeneratedName("export class C {}", "C_1")
    end)
end)

describe("TestGeneratedNameForClassDeclaration2", function()
    it("TestGeneratedNameForClassDeclaration2", function()
        checkGeneratedName("export default class {}", "default_1")
    end)
end)

describe("TestGeneratedNameForExportAssignment", function()
    it("TestGeneratedNameForExportAssignment", function()
        checkGeneratedName("export default 0", "default_1")
    end)
end)

describe("TestGeneratedNameForClassExpression", function()
    it("TestGeneratedNameForClassExpression", function()
        checkGeneratedName("(class {})", "class_1", function(file)
            return file.statements.nodes[1]:Expression():Expression()
        end)
    end)
end)

describe("TestGeneratedNameForMethod1", function()
    it("TestGeneratedNameForMethod1", function()
        checkGeneratedName("class C { m() {} }", "m_1", function(file)
            return file.statements.nodes[1]:Members()[1]
        end)
    end)
end)

describe("TestGeneratedNameForMethod2", function()
    it("TestGeneratedNameForMethod2", function()
        checkGeneratedName("class C { 0() {} }", "_a", function(file)
            return file.statements.nodes[1]:Members()[1]
        end)
    end)
end)

describe("TestGeneratedPrivateNameForMethod", function()
    it("TestGeneratedPrivateNameForMethod", function()
        checkGeneratedName("class C { m() {} }", "#m_1", function(file)
            return file.statements.nodes[1]:Members()[1]
        end, function(f, n)
            return f:NewGeneratedPrivateNameForNode(n)
        end)
    end)
end)

describe("TestGeneratedNameForComputedPropertyName", function()
    it("TestGeneratedNameForComputedPropertyName", function()
        checkGeneratedName("class C { [x] }", "_a", function(file)
            return file.statements.nodes[1]:Members()[1]:Name()
        end)
    end)
end)

describe("TestGeneratedNameForOther", function()
    it("TestGeneratedNameForOther", function()
        checkGeneratedName("class C { [x] }", "_a", function(_, ec)
            return ec.factory:NewObjectLiteralExpression(
                ec.factory:NewNodeList({}),
                false --[[multiLine]]
            )
        end)
    end)
end)
