-- Port of internal/api/encoder/encoder_test.go and decoder_test.go.
local encoder = require("tslua.api.encoder")
local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")

local Kind = ast.Kind

local function parseSourceFile(code, fileName)
    fileName = fileName or "/test.ts"
    return parser.ParseSourceFile(ast.NewSourceFileParseOptions(fileName, fileName, ast.NewExternalModuleIndicatorOptions(false, false)), code, core.ScriptKind.TS)
end

local function readUint32(buf, offset)
    return (string.unpack("<I4", buf, offset + 1))
end

local function encodedString(buf, index)
    local stringOffsets = readUint32(buf, encoder.HeaderOffsetStringOffsets)
    local stringData = readUint32(buf, encoder.HeaderOffsetStringData)
    local start = readUint32(buf, stringOffsets + index * 4)
    local end_ = readUint32(buf, stringOffsets + index * 4 + 4)
    return string.sub(buf, stringData + start + 1, stringData + end_)
end

local function formatEncodedSourceFile(encoded)
    local result = {}
    local offsetNodes = readUint32(encoded, encoder.HeaderOffsetNodes)
    local offsetStringOffsets = readUint32(encoded, encoder.HeaderOffsetStringOffsets)
    local offsetStrings = readUint32(encoded, encoder.HeaderOffsetStringData)
    local function getIndent(parentIndex)
        if parentIndex == 0 then
            return ""
        end
        return "  " .. getIndent(readUint32(encoded, offsetNodes + parentIndex * encoder.NodeSize + encoder.NodeOffsetParent))
    end
    local j = 1
    local i = offsetNodes + encoder.NodeSize
    while i < #encoded do
        local kind = readUint32(encoded, i + encoder.NodeOffsetKind)
        local pos = readUint32(encoded, i + encoder.NodeOffsetPos)
        local end_ = readUint32(encoded, i + encoder.NodeOffsetEnd)
        local parentIndex = readUint32(encoded, i + encoder.NodeOffsetParent)
        result[#result + 1] = getIndent(parentIndex)
        if kind == encoder.SyntaxKindNodeList then
            result[#result + 1] = "NodeList"
        else
            result[#result + 1] = ast.Kind_String(kind)
        end
        local data = readUint32(encoded, i + encoder.NodeOffsetData)
        local dataType = data & encoder.NodeDataTypeMask
        if kind == Kind.Identifier or dataType == encoder.NodeDataTypeString then
            local stringIndex = data & encoder.NodeDataStringIndexMask
            local strStart = readUint32(encoded, offsetStringOffsets + stringIndex * 4)
            local strEnd = readUint32(encoded, offsetStringOffsets + stringIndex * 4 + 4)
            result[#result + 1] = ' "' .. string.sub(encoded, offsetStrings + strStart + 1, offsetStrings + strEnd) .. '"'
        end
        result[#result + 1] = string.format(" [%d, %d), i=%d, next=%d", pos, end_, j, string.byte(encoded, i + encoder.NodeOffsetNext + 1))
        result[#result + 1] = "\n"
        j = j + 1
        i = i + encoder.NodeSize
    end
    return table.concat(result)
end

local function readBaseline(name)
    local f = io.open("vendor/typescript-go/testdata/baselines/reference/api/" .. name, "rb")
    if f == nil then
        return nil
    end
    local s = f:read("a")
    f:close()
    return s
end

local B = string.char(92)

describe("api/encoder", function()
    it("TestEncodeSourceFile", function()
        local sourceFile = parseSourceFile('import { bar } from "bar";\nexport function foo<T, U>(a: string, b: string): any {}\nfoo();')
        local buf, _, err = encoder.EncodeSourceFile(sourceFile)
        assert.is_nil(err)
        local want = readBaseline("encodeSourceFile.txt")
        if want ~= nil then
            assert.are.equal(want, formatEncodedSourceFile(buf))
        end
    end)

    it("TestEncodeContentMapperSourceFileMetadata", function()
        assert.are.equal(7, encoder.ProtocolVersion)
        local sourceFile = parseSourceFile("😀virtual", "/component.vue")
        sourceFile:SetContentMapperInfo({
            originalText = "😀original",
            contentMapper = "mapper@1.0.0",
            virtualFileName = "/component.vue.ts",
            diagnosticDirectives = { {
                originalRange = core.NewTextRange(4, 5),
                virtualRange = core.NewTextRange(4, 11),
                policy = ast.MappedDiagnosticDirectivePolicy.Expect,
                unusedCode = 2578,
                unusedMessageText = "Unused framework directive.",
                source = "mapper",
            } },
        })

        local buf, _, err = encoder.EncodeSourceFile(sourceFile)
        assert.is_nil(err)
        local nodesOffset = readUint32(buf, encoder.HeaderOffsetNodes)
        local rootData = readUint32(buf, nodesOffset + encoder.NodeSize + encoder.NodeOffsetData)
        local extendedOffset = readUint32(buf, encoder.HeaderOffsetExtendedData) + (rootData & encoder.NodeDataStringIndexMask)
        assert.is_true(extendedOffset + 76 <= #buf)
        local contentMapperIndex = readUint32(buf, extendedOffset + 64)
        local virtualFileNameIndex = readUint32(buf, extendedOffset + 68)
        local diagnosticDirectivesOffset = readUint32(buf, extendedOffset + 72)
        assert.are.equal("mapper@1.0.0", encodedString(buf, contentMapperIndex))
        assert.are.equal("/component.vue.ts", encodedString(buf, virtualFileNameIndex))
        local structuredDataOffset = readUint32(buf, encoder.HeaderOffsetStructuredData)
        local directiveOffset = structuredDataOffset + diagnosticDirectivesOffset
        assert.are.same({
            0x91, -- one directive
            0x96, -- six-element tuple
            2, 1, -- original range [2, 3) in UTF-16
            2, 7, -- virtual range [2, 9) in UTF-16
            1, -- expect policy
            0xcd, 0x0a, 0x12, -- 2578
        }, { string.byte(buf, directiveOffset + 1, directiveOffset + 10) })
    end)

    it("TestEncodeSourceFileWithUnicodeEscapes", function()
        local sourceFile = parseSourceFile('let a = "😃"; let b = "' .. B .. 'ud83d' .. B .. 'ude03"; let c = "' .. B .. 'udc00' .. B .. 'ud83d' .. B .. 'ude03"; let d = "' .. B .. 'ud83d' .. B .. 'ud83d' .. B .. 'ude03"')
        local buf, _, err = encoder.EncodeSourceFile(sourceFile)
        assert.is_nil(err)
        local want = readBaseline("encodeSourceFileWithUnicodeEscapes.txt")
        if want ~= nil then
            assert.are.equal(want, formatEncodedSourceFile(buf))
        end
    end)

    it("TestBuildNodeIndexTableMatchesEncode", function()
        local sourceFile = parseSourceFile('import { bar } from "bar";\nexport function foo<T, U>(a: string, b: string): any {}\nfoo();')
        local _, encodeTable, err = encoder.EncodeSourceFile(sourceFile)
        assert.is_nil(err)

        local buildTable = encoder.BuildNodeIndexTable(sourceFile)

        -- Both tables should produce identical Nodes slices
        assert.are.equal(encodeTable:Len(), buildTable:Len())

        -- Every index should map to the same node
        for i = 0, encodeTable:Len() - 1 do
            assert.are.equal(encodeTable:Node(i), buildTable:Node(i))
        end

        -- GetIndex on both tables should agree for every non-nil node
        for i = 0, encodeTable:Len() - 1 do
            local node = encodeTable:Node(i)
            if node ~= nil then
                local encIdx = encodeTable:GetIndex(node)
                local buildIdx = buildTable:GetIndex(node)
                assert.are.equal(i, encIdx)
                assert.are.equal(encIdx, buildIdx)
            end
        end
    end)
end)

local function decode(code)
    local sf = parseSourceFile(code)
    local buf, _, err = encoder.EncodeSourceFile(sf)
    assert.is_nil(err)
    local decoded, derr = encoder.DecodeSourceFile(buf)
    assert.is_nil(derr)
    return decoded
end

local function firstDecl(decoded)
    return decoded.statements.nodes[1].declarationList.declarations.nodes[1]
end

describe("api/encoder decoder", function()
    it("TestDecodeSourceFile_Basic", function()
        local decoded = decode("let x = 1;")
        assert.are.equal(Kind.SourceFile, decoded.kind)
        assert.are.equal("/test.ts", decoded:FileName())
        assert.are.equal("let x = 1;", decoded:Text())
        assert.is_not_nil(decoded.statements)
        assert.is_not_nil(decoded.endOfFileToken)
    end)

    it("TestDecodeSourceFile_Statements", function()
        local decoded = decode("let a = 1;\nlet b = 2;\nlet c = 3;")
        assert.are.equal(3, #decoded.statements.nodes)
        for _, stmt in ipairs(decoded.statements.nodes) do
            assert.are.equal(Kind.VariableStatement, stmt.kind)
        end
    end)

    it("TestDecodeSourceFile_VariableDeclaration", function()
        local decoded = decode("let x = 1;")
        local varStmt = decoded.statements.nodes[1]:AsVariableStatement()
        assert.is_not_nil(varStmt.declarationList)
        local declList = varStmt.declarationList:AsVariableDeclarationList()
        assert.is_not_nil(declList.declarations)
        assert.are.equal(1, #declList.declarations.nodes)
        local decl = declList.declarations.nodes[1]:AsVariableDeclaration()
        assert.are.equal(Kind.Identifier, decl:Name().kind)
        assert.are.equal("x", decl:Name().text)
        assert.are.equal(Kind.NumericLiteral, decl.initializer.kind)
        assert.are.equal("1", decl.initializer.text)
    end)

    it("TestDecodeSourceFile_VariableDeclarationListFlags", function()
        local NodeFlags = ast.NodeFlags
        for _, tt in ipairs({
            { "const x = 1;", NodeFlags.Const },
            { "let x = 1;", NodeFlags.Let },
            { "var x = 1;", NodeFlags.None },
        }) do
            local declList = decode(tt[1]).statements.nodes[1].declarationList
            assert.are.equal(tt[2], declList.flags & (NodeFlags.Let | NodeFlags.Const))
        end
    end)

    it("TestDecodeSourceFile_FunctionDeclaration", function()
        local funcDecl = decode("function add(a: number, b: number): number { return a + b; }").statements.nodes[1]:AsFunctionDeclaration()
        assert.are.equal("add", funcDecl:Name().text)
        assert.are.equal(2, #funcDecl.parameters.nodes)
        assert.is_not_nil(funcDecl.type)
        assert.is_not_nil(funcDecl.body)
        local param0 = funcDecl.parameters.nodes[1]:AsParameterDeclaration()
        assert.are.equal("a", param0:Name().text)
        assert.is_not_nil(param0.type)
    end)

    it("TestDecodeSourceFile_ImportDeclaration", function()
        local imp = decode('import { bar } from "bar";').statements.nodes[1]:AsImportDeclaration()
        assert.are.equal("bar", imp.moduleSpecifier.text)
        local namedImports = imp.importClause.namedBindings
        assert.are.equal(1, #namedImports.elements.nodes)
        assert.are.equal("bar", namedImports.elements.nodes[1]:Name().text)
    end)

    it("TestDecodeSourceFile_IfStatement", function()
        local ifStmt = decode("if (true) { } else { }").statements.nodes[1]:AsIfStatement()
        assert.is_not_nil(ifStmt.expression)
        assert.are.equal(Kind.Block, ifStmt.thenStatement.kind)
        assert.are.equal(Kind.Block, ifStmt.elseStatement.kind)
    end)

    it("TestDecodeSourceFile_TemplateExpression", function()
        local tmplExpr = firstDecl(decode("let x = `hello ${name} world`;")).initializer:AsTemplateExpression()
        assert.are.equal("hello ", tmplExpr.head.text)
        assert.are.equal(1, #tmplExpr.templateSpans.nodes)
        local span = tmplExpr.templateSpans.nodes[1]
        assert.are.equal(Kind.Identifier, span.expression.kind)
        assert.are.equal(" world", span.literal.text)
    end)

    it("TestDecodeSourceFile_ExportModifier", function()
        local funcDecl = decode("export function foo() {}").statements.nodes[1]
        assert.are.equal(1, #funcDecl:Modifiers().nodes)
        assert.are.equal(Kind.ExportKeyword, funcDecl:Modifiers().nodes[1].kind)
    end)

    it("TestDecodeSourceFile_Positions", function()
        local code = "let x = 1;"
        local decoded = decode(code)
        assert.are.equal(0, decoded:Pos())
        assert.are.equal(#code, decoded:End())
    end)

    it("TestDecodeSourceFile_ClassDeclaration", function()
        local classDecl = decode("class Foo { bar(): void {} }").statements.nodes[1]:AsClassDeclaration()
        assert.are.equal("Foo", classDecl:Name().text)
        assert.are.equal(1, #classDecl.members.nodes)
        assert.are.equal(Kind.MethodDeclaration, classDecl.members.nodes[1].kind)
    end)

    it("TestDecodeNodes_SubtreeRoundTrip", function()
        local sf = parseSourceFile("function greet(name: string) { return `Hello, ${name}!`; }")
        local funcNode
        local visitor
        visitor = ast.NewNodeVisitor(function(node)
            if node.kind == Kind.FunctionDeclaration and funcNode == nil then
                funcNode = node
            end
            return node
        end, nil, nil)
        visitor:VisitEachChild(sf)
        assert.is_not_nil(funcNode)
        local buf, _, err = encoder.EncodeNode(funcNode, sf)
        assert.is_nil(err)
        local decoded, derr = encoder.DecodeNodes(buf)
        assert.is_nil(derr)
        assert.are.equal(Kind.FunctionDeclaration, decoded.kind)
        assert.are.equal("greet", decoded:Name().text)
        assert.are.equal(1, #decoded.parameters.nodes)
        assert.is_not_nil(decoded.body)
    end)

    it("TestDecodeSourceFile_BinaryExpression", function()
        local binExpr = firstDecl(decode("let x = 1 + 2;")).initializer:AsBinaryExpression()
        assert.is_not_nil(binExpr.operatorToken)
        assert.are.equal(Kind.NumericLiteral, binExpr.left.kind)
        assert.are.equal(Kind.NumericLiteral, binExpr.right.kind)
    end)

    it("TestDecodeSourceFile_KeywordExpressions", function()
        -- "this" must decode as KeywordExpression, not Token, or the printer panics
        local thisExpr = firstDecl(decode("const x = this;")).initializer
        assert.are.equal(Kind.ThisKeyword, thisExpr.kind)
        assert.is_not_nil(thisExpr:AsKeywordExpression())
    end)

    it("TestDecodeSourceFile_EmptyModuleBlock", function()
        local mod = decode("namespace N { }").statements.nodes[1]:AsModuleDeclaration()
        local block = mod.body:AsModuleBlock()
        -- Statements must be non-nil even when empty, otherwise the printer panics
        assert.is_not_nil(block.statements)
        assert.are.equal(0, #block.statements.nodes)
    end)

    it("TestDecodeSourceFile_EmptyBlockAndParams", function()
        local funcDecl = decode("function foo() {}").statements.nodes[1]
        assert.is_not_nil(funcDecl.parameters)
        assert.are.equal(0, #funcDecl.parameters.nodes)
        assert.is_not_nil(funcDecl.body.statements)
        assert.are.equal(0, #funcDecl.body.statements.nodes)
    end)

    it("TestDecodeSourceFile_ArrowFunctionEmptyParams", function()
        local arrow = firstDecl(decode("const f = () => {};")).initializer:AsArrowFunction()
        assert.is_not_nil(arrow.parameters)
        assert.are.equal(0, #arrow.parameters.nodes)
        assert.is_not_nil(arrow.body.statements)
        assert.are.equal(0, #arrow.body.statements.nodes)
    end)

    it("TestDecodeSourceFile_FunctionExpressionEmptyParams", function()
        local funcExpr = firstDecl(decode("const f = function() {};")).initializer:AsFunctionExpression()
        assert.is_not_nil(funcExpr.parameters)
        assert.are.equal(0, #funcExpr.parameters.nodes)
    end)

    it("TestDecodeSourceFile_PostfixUnaryOperator", function()
        local postfix = decode("let i = 0; i++;").statements.nodes[2].expression:AsPostfixUnaryExpression()
        assert.are.equal(Kind.PlusPlusToken, postfix.operator)
        assert.are.equal(Kind.Identifier, postfix.operand.kind)
    end)

    it("TestDecodeSourceFile_PrefixUnaryOperator", function()
        local prefix = decode("let x = true; !x;").statements.nodes[2].expression:AsPrefixUnaryExpression()
        assert.are.equal(Kind.ExclamationToken, prefix.operator)
        assert.are.equal(Kind.Identifier, prefix.operand.kind)
    end)

    it("TestDecodeSourceFile_PostfixDecrement", function()
        local postfix = decode("let n = 5; n--;").statements.nodes[2].expression:AsPostfixUnaryExpression()
        assert.are.equal(Kind.MinusMinusToken, postfix.operator)
    end)
end)
