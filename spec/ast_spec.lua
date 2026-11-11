local ast = require("tslua.ast")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local SubtreeFacts = ast.SubtreeFacts

local function kinds(node)
    local result = {}
    node:ForEachChild(function(child)
        result[#result + 1] = ast.Kind_String(child.kind)
        return false
    end)
    return result
end

describe("ast factory", function()
    local f = ast.NewNodeFactory({})

    it("creates nodes with Go zero values", function()
        local id = f:NewIdentifier("x")
        assert.are.equal(Kind.Identifier, id.kind)
        assert.are.equal(0, id.flags)
        assert.are.equal(-1, id:Pos())
        assert.are.equal(-1, id:End())
        assert.is_nil(id.parent)
        assert.are.equal("x", id:Text())
        assert.are.equal(id, id:AsIdentifier())
        assert.has_error(function() id:AsStringLiteral() end)
        assert.are.equal(1, f:NodeCount())
        assert.are.equal(1, f:TextCount())
    end)

    it("applies NodeFlags bitmasks and keeps Go parameter order", function()
        local pa = f:NewPropertyAccessExpression(f:NewIdentifier("a"), nil, f:NewIdentifier("b"),
            NodeFlags.OptionalChain | NodeFlags.Ambient)
        assert.are.equal(NodeFlags.OptionalChain, pa.flags)
        assert.are.equal("a", pa:Expression():Text())
        assert.are.equal("b", pa:Name():Text())
        assert.is_true(ast.IsPropertyAccessExpression(pa))
        assert.is_true(ast.IsOptionalChain(pa))
    end)

    it("Update returns the same node when nothing changed, a new one otherwise", function()
        local left, right = f:NewIdentifier("a"), f:NewIdentifier("b")
        local op = f:NewToken(Kind.PlusToken)
        local bin = f:NewBinaryExpression(nil, left, nil, op, right)
        bin.flags = NodeFlags.Synthesized
        assert.are.equal(bin, f:UpdateBinaryExpression(bin, nil, left, nil, op, right))
        local updated = f:UpdateBinaryExpression(bin, nil, left, nil, op, f:NewIdentifier("c"))
        assert.are_not.equal(bin, updated)
        assert.are.equal(NodeFlags.Synthesized, updated.flags)
        assert.are.equal(bin.loc, updated.loc)
    end)

    it("calls hooks", function()
        local created, updated = 0, 0
        local hf = ast.NewNodeFactory({
            onCreate = function() created = created + 1 end,
            onUpdate = function() updated = updated + 1 end,
        })
        local e = hf:NewExpressionStatement(hf:NewIdentifier("x"))
        hf:UpdateExpressionStatement(e, hf:NewIdentifier("y"))
        assert.are.equal(4, created)
        assert.are.equal(1, updated)
    end)

    it("builds modifier lists with flags", function()
        local mods = f:NewModifierList({ f:NewModifier(Kind.ExportKeyword), f:NewModifier(Kind.AsyncKeyword) })
        assert.are.equal(ModifierFlags.Export | ModifierFlags.Async, mods.modifierFlags)
        local fn = f:NewFunctionDeclaration(mods, nil, f:NewIdentifier("g"), nil, f:NewNodeList({}), nil, nil,
            f:NewBlock(f:NewNodeList({}), false))
        assert.are.equal(mods, fn:Modifiers())
        assert.are.equal(ModifierFlags.Export | ModifierFlags.Async, fn:ModifierFlags())
        assert.is_true(ast.HasSyntacticModifier(fn, ModifierFlags.Async))
    end)
end)

describe("ast struct method promotion", function()
    local f = ast.NewNodeFactory({})

    it("resolves embedded base data accessors like Go", function()
        local fn = f:NewFunctionDeclaration(nil, nil, f:NewIdentifier("g"), nil, f:NewNodeList({}), nil, nil,
            f:NewBlock(f:NewNodeList({}), false))
        assert.are.equal(fn, fn:DeclarationData())
        assert.are.equal(fn, fn:LocalsContainerData())
        assert.are.equal(fn, fn:FunctionLikeData())
        assert.are.equal(fn, fn:BodyData())
        assert.are.equal(fn, fn:FlowNodeData())
        assert.is_nil(fn:ClassLikeData())
        assert.are.same({}, fn:Parameters())
        local id = f:NewIdentifier("x")
        assert.is_nil(id:DeclarationData())
        assert.is_nil(id:Name())
        assert.is_nil(id:Modifiers())
        assert.are.equal(id, id:FlowNodeData())
        assert.is_true(ast.IsLocalsContainer(f:NewBlock(f:NewNodeList({}), true)))
    end)

    it("computes subtree facts", function()
        local id = f:NewIdentifier("x")
        assert.are.equal(SubtreeFacts.SubtreeContainsIdentifier, id:SubtreeFacts())
        local as = f:NewAsExpression(f:NewIdentifier("x"), f:NewKeywordTypeNode(Kind.NumberKeyword))
        assert.are_not.equal(0, as:SubtreeFacts() & SubtreeFacts.SubtreeContainsTypeScript)
        local stmt = f:NewExpressionStatement(as)
        assert.are_not.equal(0, stmt:SubtreeFacts() & SubtreeFacts.SubtreeContainsTypeScript)
    end)
end)

describe("ast ForEachChild", function()
    local f = ast.NewNodeFactory({})

    it("visits children in Go order and stops early", function()
        local cond = f:NewConditionalExpression(f:NewIdentifier("a"), f:NewToken(Kind.QuestionToken),
            f:NewIdentifier("b"), f:NewToken(Kind.ColonToken), f:NewIdentifier("c"))
        assert.are.same({ "KindIdentifier", "KindQuestionToken", "KindIdentifier", "KindColonToken", "KindIdentifier" },
            kinds(cond))
        local seen = 0
        local stopped = cond:ForEachChild(function()
            seen = seen + 1
            return seen == 2
        end)
        assert.is_true(stopped)
        assert.are.equal(2, seen)
    end)

    it("visits node lists and skips nil children", function()
        local call = f:NewCallExpression(f:NewIdentifier("f"), nil, nil,
            f:NewNodeList({ f:NewIdentifier("x"), f:NewNumericLiteral("1", 0) }), 0)
        assert.are.same({ "KindIdentifier", "KindIdentifier", "KindNumericLiteral" }, kinds(call))
        assert.is_false(f:NewIdentifier("leaf"):ForEachChild(function() return true end))
    end)

    it("sets parents", function()
        local x = f:NewIdentifier("x")
        local stmt = f:NewExpressionStatement(f:NewParenthesizedExpression(x))
        ast.SetParentInChildren(stmt)
        assert.are.equal(stmt, x.parent.parent)
        assert.are.equal(stmt, ast.WalkUpParenthesizedExpressions(x.parent))
    end)

    it("iterates children with IterChildren", function()
        local bin = f:NewBinaryExpression(nil, f:NewIdentifier("a"), nil, f:NewToken(Kind.PlusToken), f:NewIdentifier("b"))
        local n = 0
        for child in bin:IterChildren() do
            assert.is_not_nil(child)
            n = n + 1
        end
        assert.are.equal(3, n)
    end)
end)

describe("ast visitor", function()
    local f = ast.NewNodeFactory({})

    it("VisitEachChild rebuilds only changed nodes", function()
        local a, b = f:NewIdentifier("a"), f:NewIdentifier("b")
        local bin = f:NewBinaryExpression(nil, a, nil, f:NewToken(Kind.PlusToken), b)
        local v = ast.NewNodeVisitor(function(n) return n end, f, {})
        assert.are.equal(bin, v:VisitEachChild(bin))
        local renamer = ast.NewNodeVisitor(function(n)
            if ast.IsIdentifier(n) and n:Text() == "b" then
                return f:NewIdentifier("c")
            end
            return n
        end, f, {})
        local out = renamer:VisitEachChild(bin)
        assert.are_not.equal(bin, out)
        assert.are.equal(a, out.left)
        assert.are.equal("c", out.right:Text())
    end)

    it("deep clones with synthetic locations", function()
        local stmt = f:NewExpressionStatement(f:NewIdentifier("x"))
        local clone = f:DeepCloneNode(stmt)
        assert.are_not.equal(stmt, clone)
        assert.are_not.equal(stmt.expression, clone.expression)
        assert.are.equal("x", clone.expression:Text())
        assert.are.equal(-1, clone:Pos())
    end)
end)

describe("ast symbols and misc", function()
    it("symbol helpers", function()
        local s = ast.NewSymbol(ast.SymbolFlags.ValueModule, "\"mod\"")
        assert.is_true(s:IsExternalModule())
        local id1 = ast.GetSymbolId(s)
        assert.are.equal(id1, ast.GetSymbolId(s))
        assert.is_true(ast.GetSymbolId(ast.NewSymbol(0, "a")) > id1)
        assert.are.equal("__call", ast.EscapeSymbolName(ast.InternalSymbolNameCall))
        assert.are.equal("___x", ast.EscapeSymbolName("__x"))
        assert.are.same({}, ast.GetMembers(s))
    end)

    it("Kind_String matches the Go stringer", function()
        assert.are.equal("KindIdentifier", ast.Kind_String(Kind.Identifier))
        assert.are.equal("KindUnknown", ast.Kind_String(0))
        assert.are.equal("Kind(9999)", ast.Kind_String(9999))
    end)

    it("precedence", function()
        local OperatorPrecedence = ast.OperatorPrecedence
        assert.are.equal(OperatorPrecedence.Multiplicative, ast.GetBinaryOperatorPrecedence(Kind.AsteriskToken))
        assert.are.equal(OperatorPrecedence.Invalid, ast.GetBinaryOperatorPrecedence(Kind.Identifier))
    end)

    it("position map", function()
        local pm = ast.ComputePositionMap("a\u{e9}b\u{1F600}c")
        assert.is_false(pm:IsAsciiOnly())
        assert.are.equal(2, pm:UTF8ToUTF16(3))
        assert.are.equal(5, pm:UTF8ToUTF16(8))
        assert.are.equal(8, pm:UTF16ToUTF8(5))
    end)
end)
