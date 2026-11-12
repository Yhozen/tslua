-- Port of internal/parser/parser_test.go (BenchmarkParse and FuzzParser skipped)
local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")
local scanner = require("tslua.scanner")

local Kind = ast.Kind

local function parseOptions(fileName)
    return { fileName = fileName, path = fileName, externalModuleIndicatorOptions = { jsx = false, force = false } }
end

-- Go strings.Index (0-based byte index, -1 if absent)
local function stringsIndex(s, sub)
    local i = string.find(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

describe("TestHeritageClauseElementKinds", function()
    it("TestHeritageClauseElementKinds", function()
        local sourceText = [[

class C extends Base<number> implements Contract<string> {}
interface I extends Parent<boolean> {}
interface Invalid implements Recovery {}
interface MissingExtends extends A. {}
class MissingImplements implements B. {}
]]
        local file = parser.ParseSourceFile(parseOptions("/index.ts"), sourceText, core.ScriptKind.TS)

        local classDecl = file.statements.nodes[1]:AsClassDeclaration()
        assert.are.equal(Kind.ExpressionWithTypeArguments, classDecl.heritageClauses.nodes[1]:AsHeritageClause().types.nodes[1].kind)
        assert.are.equal(Kind.TypeReference, classDecl.heritageClauses.nodes[2]:AsHeritageClause().types.nodes[1].kind)

        local interfaceDecl = file.statements.nodes[2]:AsInterfaceDeclaration()
        assert.are.equal(Kind.TypeReference, interfaceDecl.heritageClauses.nodes[1]:AsHeritageClause().types.nodes[1].kind)

        local invalidInterfaceDecl = file.statements.nodes[3]:AsInterfaceDeclaration()
        assert.are.equal(Kind.ExpressionWithTypeArguments, invalidInterfaceDecl.heritageClauses.nodes[1]:AsHeritageClause().types.nodes[1].kind)

        local missingExtendsDecl = file.statements.nodes[4]:AsInterfaceDeclaration()
        assert.are.equal(Kind.ExpressionWithTypeArguments, missingExtendsDecl.heritageClauses.nodes[1]:AsHeritageClause().types.nodes[1].kind)

        local missingImplementsDecl = file.statements.nodes[5]:AsClassDeclaration()
        assert.are.equal(Kind.ExpressionWithTypeArguments, missingImplementsDecl.heritageClauses.nodes[1]:AsHeritageClause().types.nodes[1].kind)
    end)
end)

describe("TestJSDocImportTypeParentChain", function()
    it("TestJSDocImportTypeParentChain", function()
        local sourceText = [[
test("", async function () {
  ;(/** @type {typeof import("a")} */ ({}))
})

test("", async function () {
  ;(/** @type {typeof import("a")} */ a)
})

test("", async function () {
  (/** @type {typeof import("a")} */ ({}))
  ;(/** @type {typeof import("a")} */ ({}))
})

test("", async function () {
  (/** @type {typeof import("a")} */ a)
  ;(/** @type {typeof import("a")} */ a)
})

test("", async function () {
  (/** @type {typeof import("a")} */ ({}))
  ;(/** @type {typeof import("a")} */ ({}))
})
]]
        local file = parser.ParseSourceFile(parseOptions("/index.js"), sourceText, core.ScriptKind.JS)

        local clones = file.reparsedClones or {}
        for i = 1, #clones - 1 do
            local a, b = clones[i - 1 + 1], clones[i + 1]
            assert.is_false(a:Pos() == b:Pos() and a:End() == b:End() and a.kind == b.kind,
                string.format("duplicate ReparsedClones at [%d] and [%d]: %s pos=%d end=%d", i - 1, i, ast.Kind_String(a.kind), a:Pos(), a:End()))
        end

        for _, imp in ipairs(file:Imports() or {}) do
            local reparsed = ast.GetReparsedNodeForNode(imp)
            assert.is_not_nil(ast.GetSourceFileOfNode(reparsed), string.format("reparsed import at pos=%d has broken parent chain", imp:Pos()))
        end
    end)
end)

describe("TestJSDocTypeSourceSurvivesReparse", function()
    local sourceText = [[
/**
 * @typedef {(
 *   "a" |
 *   "b"
 * )[]} T
 */
const value = 0;]]
    local file = parser.ParseSourceFile(parseOptions("/index.js"), sourceText, core.ScriptKind.JS)
    local typeAlias
    for _, statement in ipairs(file.statements.nodes) do
        if ast.IsJSTypeAliasDeclaration(statement) then
            typeAlias = statement
            break
        end
    end
    local jsDocs = typeAlias and typeAlias:JSDoc(file)
    local typeExpression = jsDocs and jsDocs[1] and jsDocs[1]:AsJSDoc().tags and jsDocs[1]:AsJSDoc().tags.nodes[1] and jsDocs[1]:AsJSDoc().tags.nodes[1]:TypeExpression()

    it("TestJSDocTypeSourceSurvivesReparse", function()
        assert.is_not_nil(typeAlias)
        assert.are.equal(1, #jsDocs)
        assert.is_not_nil(jsDocs[1]:AsJSDoc().tags)
        assert.are.equal(1, #jsDocs[1]:AsJSDoc().tags.nodes)
        assert.is_not_nil(typeExpression)
    end)

    local expected = table.concat({ "(", [["a" |]], [["b"]], ")[]" }, core.NewLineKind_GetNewLineCharacter(core.NewLineKind.LF))
    local tests = {
        { name = "original", node = function() return typeExpression:Type() end },
        { name = "reparsed", node = function() return typeAlias:Type() end },
    }
    for _, test in ipairs(tests) do
        it(test.name, function()
            assert.are.equal(expected, scanner.GetTextOfNode(test.node()))
        end)
    end
end)

describe("TestJSDocTypeSourcePropagatesToConstructedReparse", function()
    it("TestJSDocTypeSourcePropagatesToConstructedReparse", function()
        local sourceText = [[
/**
 * @param {{
 *   value: string
 * }} options
 */
function foo(options) {}]]
        local file = parser.ParseSourceFile(parseOptions("/index.js"), sourceText, core.ScriptKind.JS)
        local function_ = file.statements.nodes[1]
        assert.is_true(ast.IsFunctionDeclaration(function_))
        assert.are.equal(1, #function_:Parameters())

        local typeNode = function_:Parameters()[1]:Type()
        assert.is_not_nil(typeNode)
        assert.is_true(typeNode.flags & ast.NodeFlags.Reparsed ~= 0)

        local expected = table.concat({ "{", "value: string", "}" }, core.NewLineKind_GetNewLineCharacter(core.NewLineKind.LF))
        assert.are.equal(expected, scanner.GetTextOfNode(typeNode))
        assert.are.equal(stringsIndex(sourceText, "{{") + 1, scanner.GetTokenPosOfNode(typeNode, file, false --[[includeJSDoc]]))
    end)
end)

describe("TestSourceFilePositionMapWithNonASCIIStringLiteral", function()
    it("TestSourceFilePositionMapWithNonASCIIStringLiteral", function()
        local sourceText = [[
const x = "─";

namespace N {
  export const y = x;
}
]]
        local file = parser.ParseSourceFile(parseOptions("/index.ts"), sourceText, core.ScriptKind.TS)

        local positionMap = file:GetPositionMap()
        assert.is_false(positionMap:IsAsciiOnly())
        local afterBoxDrawingCharacter = stringsIndex(sourceText, "─") + #"─"
        assert.are.equal(afterBoxDrawingCharacter - 2, positionMap:UTF8ToUTF16(afterBoxDrawingCharacter))
        assert.are.equal(#sourceText - 2, positionMap:UTF8ToUTF16(#sourceText))
    end)
end)
