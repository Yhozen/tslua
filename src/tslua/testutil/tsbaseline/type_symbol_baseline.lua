local tsbaseline = require("tslua.testutil.tsbaseline")
local ast = require("tslua.ast")
local baseline = require("tslua.testutil.baseline")
local checker = require("tslua.checker")
local core = require("tslua.core")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local testutil = require("tslua.testutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local TypeFormatFlags = checker.TypeFormatFlags

-- codeLinesRegexp = regexp.MustCompile("[\r  ]|\r?\n")
tsbaseline.codeLinesRegexp = {
    nextMatch = function(s, i)
        local n = #s
        local j = i
        while j <= n do
            local b = string.byte(s, j)
            if b == 13 then
                -- leftmost-first: `[\r  ]` is tried before `\r?\n`, so "\r\n" splits twice
                return j, j + 1
            elseif b == 10 then
                return j, j + 1
            elseif b == 0xE2 and string.byte(s, j + 1) == 0x80 then
                local c = string.byte(s, j + 2)
                if c == 0xA8 or c == 0xA9 then
                    return j, j + 3
                end
            end
            j = j + 1
        end
        return nil
    end,
    Split = function(self, s)
        return tsbaseline.splitByMatcher(s, self.nextMatch)
    end,
}

-- bracketLineRegex = regexp.MustCompile(`^\s*[{|}]\s*$`)
tsbaseline.bracketLineRegex = {
    MatchString = function(self, s)
        local i, n = 1, #s
        while i <= n and tsbaseline.isRE2Space(string.byte(s, i)) do
            i = i + 1
        end
        local c = string.sub(s, i, i)
        if c ~= "{" and c ~= "|" and c ~= "}" then
            return false
        end
        i = i + 1
        while i <= n and tsbaseline.isRE2Space(string.byte(s, i)) do
            i = i + 1
        end
        return i > n
    end,
}

-- strings.TrimSpace (deviation: ASCII white space only)
local function trimSpace(s)
    return (string.match(s, "^%s*(.-)%s*$"))
end

local function joinRange(xs, a, b, sep)
    -- xs[a:b] joined (0-based, half-open)
    return table.concat(xs, sep, a + 1, b)
end

function tsbaseline.DoTypeAndSymbolBaseline(t, baselinePath, header, program, allFiles, opts, skipTypeBaselines, skipSymbolBaselines, hasErrorBaseline)
    -- The full walker simulates the types that you would get from doing a full
    -- compile.  The pull walker simulates the types you get when you just do
    -- a type query for a random node (like how the LS would do it).  Most of the
    -- time, these will be the same.  However, occasionally, they can be different.
    -- Specifically, when the compiler internally depends on symbol IDs to order
    -- things, then we may see different results because symbols can be created in a
    -- different order with 'pull' operations, and thus can produce slightly differing
    -- output.
    --
    -- For example, with a full type check, we may see a type displayed as: number | string
    -- But with a pull type check, we may see it as:                        string | number
    --
    -- These types are equivalent, but depend on what order the compiler observed
    -- certain parts of the program.

    local fullWalker = tsbaseline.newTypeWriterWalker(program, hasErrorBaseline)

    t:Run("type", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating type baseline for test " .. header, function()
            -- !!! Remove once the type baselines print node reuse lines
            local typesOpts = {}
            for k, v in pairs(opts) do
                typesOpts[k] = v
            end
            typesOpts.diffFixupOld = function(s)
                local sb = {}

                local perfStats = false
                for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
                    if tsbaseline.isTypeBaselineNodeReuseLine(line) then
                        goto continue
                    end

                    if not perfStats and string.sub(line, 1, #"=== Performance Stats ===") == "=== Performance Stats ===" then
                        perfStats = true
                        goto continue
                    elseif perfStats then
                        if string.sub(line, 1, 4) == "=== " then
                            perfStats = false
                        else
                            goto continue
                        end
                    end

                    do
                        local relativePrefixNew = "=== "
                        local relativePrefixOld = relativePrefixNew .. "./"
                        if string.sub(line, 1, #relativePrefixOld) == relativePrefixOld then
                            line = relativePrefixNew .. string.sub(line, #relativePrefixOld + 1)
                        end

                        sb[#sb + 1] = line
                        sb[#sb + 1] = "\n"
                    end
                    ::continue::
                end

                local joined = table.concat(sb)
                return string.sub(joined, 1, #joined - 1)
            end

            tsbaseline.checkBaselines(t1, baselinePath, allFiles, fullWalker, header, typesOpts, false --[[isSymbolBaseline]])
        end)
    end)
    t:Run("symbol", function(t1)
        testutil.RecoverAndFail(t1, "Panic on creating symbol baseline for test " .. header, function()
            tsbaseline.checkBaselines(t1, baselinePath, allFiles, fullWalker, header, opts, true --[[isSymbolBaseline]])
        end)
    end)
end

function tsbaseline.isTypeBaselineNodeReuseLine(line)
    if string.sub(line, 1, 1) ~= ">" then
        return false
    end
    line = string.sub(line, 2)
    -- line[1:] then TrimLeft " "
    line = string.sub(line, 2)
    line = string.gsub(line, "^ +", "")
    if string.sub(line, 1, 1) ~= ":" then
        return false
    end
    line = string.sub(line, 2)

    for i = 1, #line do
        local c = string.sub(line, i, i)
        if c ~= " " and c ~= "^" and c ~= "\r" then
            return false
        end
    end
    return true
end

function tsbaseline.checkBaselines(t, baselinePath, allFiles, fullWalker, header, opts, isSymbolBaseline)
    local fullExtension = core.IfElse(isSymbolBaseline, ".symbols", ".types")
    local outputFileName = tsbaseline.tsExtension:ReplaceAllString(baselinePath, fullExtension)
    local fullBaseline = tsbaseline.generateBaseline(allFiles, fullWalker, header, isSymbolBaseline)
    baseline.Run(t, outputFileName, fullBaseline, opts)
end

function tsbaseline.generateBaseline(allFiles, fullWalker, header, isSymbolBaseline)
    local result = core.NewStringBuilder()
    -- !!! Perf baseline
    local perfLines = {}
    -- prePerformanceValues := getPerformanceBaselineValues()
    local baselines = tsbaseline.iterateBaseline(allFiles, fullWalker, isSymbolBaseline)
    for _, value in ipairs(baselines) do
        result:WriteString(value)
    end
    -- postPerformanceValues := getPerformanceBaselineValues()

    -- !!! Perf baselines (not ported upstream either)

    if result:Len() > 0 then
        return "//// [" .. header .. "] ////\r\n\r\n" .. table.concat(perfLines, "\n") .. result:String()
    end
    return baseline.NoContent
end

function tsbaseline.iterateBaseline(allFiles, fullWalker, isSymbolBaseline)
    local baselines = {}

    for _, file in ipairs(allFiles or {}) do
        local unitName = file.unitName
        local typeLines = core.NewStringBuilder()
        typeLines:WriteString("=== ")
        typeLines:WriteString(unitName)
        typeLines:WriteString(" ===\r\n")
        local codeLines = tsbaseline.codeLinesRegexp:Split(file.content, -1)
        local results
        if isSymbolBaseline then
            results = fullWalker:getSymbols(unitName)
        else
            results = fullWalker:getTypes(unitName)
        end
        local lastIndexWritten = -1
        for _, result in ipairs(results) do
            if isSymbolBaseline and result.symbol == "" then
                return baselines
            end
            if lastIndexWritten == -1 then
                typeLines:WriteString(joinRange(codeLines, 0, result.line + 1, "\r\n"))
                typeLines:WriteString("\r\n")
            elseif lastIndexWritten ~= result.line then
                if not (lastIndexWritten + 1 < #codeLines and
                    (tsbaseline.bracketLineRegex:MatchString(codeLines[lastIndexWritten + 2]) or trimSpace(codeLines[lastIndexWritten + 2]) == "")) then
                    typeLines:WriteString("\r\n")
                end
                typeLines:WriteString(joinRange(codeLines, lastIndexWritten + 1, result.line + 1, "\r\n"))
                typeLines:WriteString("\r\n")
            end
            lastIndexWritten = result.line
            local typeOrSymbolString = core.IfElse(isSymbolBaseline, result.symbol, result.typ)
            local lineText = tsbaseline.lineDelimiter:ReplaceAllString(result.sourceText, "")
            typeLines:WriteString(">")
            typeLines:WriteString(lineText .. " : " .. typeOrSymbolString)
            typeLines:WriteString("\r\n")
            if result.underline ~= "" then
                typeLines:WriteString(">")
                typeLines:WriteString(string.rep(" ", #lineText))
                typeLines:WriteString(" : ")
                typeLines:WriteString(result.underline)
                typeLines:WriteString("\r\n")
            end
        end

        if lastIndexWritten + 1 < #codeLines then
            if not (lastIndexWritten + 1 < #codeLines and
                (tsbaseline.bracketLineRegex:MatchString(codeLines[lastIndexWritten + 2]) or trimSpace(codeLines[lastIndexWritten + 2]) == "")) then
                typeLines:WriteString("\r\n")
            end
            typeLines:WriteString(joinRange(codeLines, lastIndexWritten + 1, #codeLines, "\r\n"))
        end
        typeLines:WriteString("\r\n")

        baselines[#baselines + 1] = tsbaseline.removeTestPathPrefixes(typeLines:String(), false --[[retainTrailingDirectorySeparator]])
    end

    return baselines
end

local typeWriterWalker = {}
typeWriterWalker.__index = typeWriterWalker
tsbaseline.typeWriterWalker = typeWriterWalker

function tsbaseline.newTypeWriterWalker(program, hadErrorBaseline)
    return setmetatable({
        program = program,
        hadErrorBaseline = hadErrorBaseline,
        currentSourceFile = nil,
        declarationTextCache = {},
    }, typeWriterWalker)
end

function typeWriterWalker:getTypeCheckerForCurrentFile()
    -- If we don't use the right checker for the file, its contents won't be up to date
    -- since the types/symbols baselines appear to depend on files having been checked.
    return self.program:Program():GetTypeCheckerForFile(nil --[[context.Background()]], self.currentSourceFile)
end

-- typeWriterResult: { line = 0, sourceText = "", symbol = "", typ = "", underline = "" }

function typeWriterWalker:getTypes(filename)
    local sourceFile = self.program:GetSourceFile(filename)
    self.currentSourceFile = sourceFile
    return self:visitNode(sourceFile, false --[[isSymbolWalk]])
end

function typeWriterWalker:getSymbols(filename)
    local sourceFile = self.program:GetSourceFile(filename)
    self.currentSourceFile = sourceFile
    return self:visitNode(sourceFile, true --[[isSymbolWalk]])
end

function typeWriterWalker:visitNode(node, isSymbolWalk)
    local nodes = tsbaseline.forEachASTNode(node)
    local results = {}
    for _, n in ipairs(nodes) do
        if ast.IsExpressionNode(n) or n.kind == Kind.Identifier or ast.IsDeclarationName(n) or
            ast.IsQualifiedName(n) and ast.IsNameOfHeritageClauseTypeReference(n) and (isSymbolWalk or ast.IsQualifiedName(n.parent)) then
            local result = self:writeTypeOrSymbol(n, isSymbolWalk)
            if result ~= nil then
                results[#results + 1] = result
            end
        end
    end
    return results
end

function tsbaseline.forEachASTNode(node)
    local result = {}
    local work = { node }

    local resChildren = {}
    local function addChild(child)
        resChildren[#resChildren + 1] = child
        return false
    end

    while #work > 0 do
        local elem = work[#work]
        work[#work] = nil
        if elem.flags & NodeFlags.Reparsed == 0 or elem.kind == Kind.AsExpression or elem.kind == Kind.SatisfiesExpression or
            ((elem.parent.kind == Kind.SatisfiesExpression or elem.parent.kind == Kind.AsExpression) and elem == elem.parent:Expression()) then
            if elem.flags & NodeFlags.Reparsed == 0 or elem.parent.kind == Kind.AsExpression or elem.parent.kind == Kind.SatisfiesExpression then
                result[#result + 1] = elem
            end
            elem:ForEachChild(addChild)
            for i = #resChildren, 1, -1 do
                work[#work + 1] = resChildren[i]
            end
            resChildren = {}
        end
    end
    return result
end

function typeWriterWalker:writeTypeOrSymbol(node, isSymbolWalk)
    local actualPos = scanner.SkipTrivia(self.currentSourceFile:Text(), node:Pos())
    local line = scanner.GetECMALineOfPosition(self.currentSourceFile, actualPos)
    local sourceText = scanner.GetSourceTextOfNodeFromSourceFile(self.currentSourceFile, node, false --[[includeTrivia]])
    local fileChecker, done = self:getTypeCheckerForCurrentFile()

    local ctx, putCtx = printer.GetEmitContext()

    local function finish(result)
        if putCtx ~= nil then
            putCtx()
        end
        if done ~= nil then
            done()
        end
        return result
    end

    if not isSymbolWalk then
        -- Don't try to get the type of something that's already a type.
        -- Exception for `T` in `type T = something` because that may evaluate to some interesting type.
        if ast.IsPartOfTypeNode(node) or
            (node.kind == Kind.AsExpression or node.kind == Kind.SatisfiesExpression) and node:Type().flags & NodeFlags.Reparsed ~= 0 or
            ast.IsIdentifier(node) and
            (ast.GetMeaningFromDeclaration(node.parent) & ast.SemanticMeaning.Value) == 0 and
            not (ast.IsTypeOrJSTypeAliasDeclaration(node.parent) and node == node.parent:Name()) then
            return finish(nil)
        end

        if ast.IsOmittedExpression(node) then
            return finish(nil)
        end

        local t = nil
        -- Workaround to ensure we output 'C' instead of 'typeof C' for base class expressions
        if ast.IsExpressionWithTypeArgumentsInClassExtendsClause(node.parent) then
            t = fileChecker:GetTypeAtLocation(node.parent)
        end
        if t == nil or checker.IsTypeAny(t) then
            t = fileChecker:GetTypeAtLocation(node)
        end
        local typeString
        if not self.hadErrorBaseline and
            checker.IsTypeAny(t) and
            not ast.IsBindingElement(node.parent) and
            not ast.IsPropertyAccessOrQualifiedName(node.parent) and
            not ast.IsLabelName(node) and
            not ast.IsGlobalScopeAugmentation(node.parent) and
            not ast.IsMetaProperty(node.parent) and
            not tsbaseline.isImportStatementName(node) and
            not tsbaseline.isExportStatementName(node) and
            not tsbaseline.isIntrinsicJsxTag(node, self.currentSourceFile) then
            typeString = t:AsIntrinsicType():IntrinsicName()
        else
            ctx:Reset()
            local builder = checker.NewNodeBuilder(fileChecker, ctx)
            local typeFormatFlags = TypeFormatFlags.NoTruncation | TypeFormatFlags.AllowUniqueESSymbolType | TypeFormatFlags.GenerateNamesForShadowedTypeParams
            local typeNode = builder:TypeToTypeNode(t, node.parent, (typeFormatFlags & TypeFormatFlags.NodeBuilderFlagsMask) | nodebuilder.Flags.IgnoreErrors, nodebuilder.InternalFlags.AllowUnresolvedNames, nil)
            if ast.IsIdentifier(node) and ast.IsTypeAliasDeclaration(node.parent) and node.parent:Name() == node and ast.IsIdentifier(typeNode) and typeNode:Text() == node:Text() then
                -- for a complex type alias `type T = ...`, showing "T : T" isn't very helpful for type tests. When the type produced is the same as
                -- the name of the type alias, recreate the type string without reusing the alias name
                typeNode = builder:TypeToTypeNode(t, node.parent, ((typeFormatFlags | TypeFormatFlags.InTypeAlias) & TypeFormatFlags.NodeBuilderFlagsMask) | nodebuilder.Flags.IgnoreErrors, nodebuilder.InternalFlags.AllowUnresolvedNames, nil)
            end

            -- !!! TODO: port underline printer, memoize
            local writer = printer.NewTextWriter("", 0)
            local p = printer.NewPrinter({ removeComments = true }, {}, ctx)
            p:Write(typeNode, self.currentSourceFile, writer, nil)
            typeString = writer:String()
        end
        return finish({
            line = line,
            sourceText = sourceText,
            symbol = "",
            typ = typeString,
            underline = "", -- !!! TODO: underline
        })
    end

    local symbol = fileChecker:GetSymbolAtLocation(node)
    if symbol == nil then
        return finish(nil)
    end

    local symbolString = core.NewStringBuilder()
    symbolString:WriteString("Symbol(")
    symbolString:WriteString(ast.EscapeAllInternalSymbolNames(fileChecker:SymbolToStringEx(symbol, node.parent, ast.SymbolFlags.None, checker.SymbolFormatFlags.AllowAnyNodeKind)))
    local count = 0
    local declarations = symbol.declarations or {}
    for _, declaration in ipairs(declarations) do
        if count >= 5 then
            symbolString:WriteString(" ... and " .. tostring(#declarations - count) .. " more")
            break
        end
        count = count + 1
        symbolString:WriteString(", ")
        local declText = self.declarationTextCache[declaration]
        if declText ~= nil then
            symbolString:WriteString(declText)
            goto continue
        end

        do
            local declSourceFile = ast.GetSourceFileOfNode(declaration)
            local declLine, declChar = scanner.GetECMALineAndUTF16CharacterOfPosition(declSourceFile, declaration:Pos())
            local fileName = tspath.GetBaseFileName(declSourceFile:FileName())
            symbolString:WriteString("Decl(")
            symbolString:WriteString(fileName)
            symbolString:WriteString(", ")
            if tsbaseline.isDefaultLibraryFile(fileName) then
                symbolString:WriteString("--, --)")
            else
                symbolString:WriteString(tostring(declLine) .. ", " .. tostring(declChar) .. ")")
            end
        end
        ::continue::
    end
    symbolString:WriteString(")")
    return finish({
        line = line,
        sourceText = sourceText,
        symbol = symbolString:String(),
        typ = "",
        underline = "",
    })
end

function tsbaseline.isImportStatementName(node)
    if ast.IsImportSpecifier(node.parent) and (node == node.parent:Name() or node == node.parent:PropertyName()) then
        return true
    end
    if ast.IsImportClause(node.parent) and node == node.parent:Name() then
        return true
    end
    if ast.IsImportEqualsDeclaration(node.parent) and node == node.parent:Name() then
        return true
    end
    return false
end

function tsbaseline.isExportStatementName(node)
    if ast.IsExportAssignment(node.parent) and node == node.parent:Expression() then
        return true
    end
    if ast.IsExportSpecifier(node.parent) and (node == node.parent:Name() or node == node.parent:PropertyName()) then
        return true
    end
    return false
end

function tsbaseline.isIntrinsicJsxTag(node, sourceFile)
    if not (ast.IsJsxOpeningElement(node.parent) or ast.IsJsxClosingElement(node.parent) or ast.IsJsxSelfClosingElement(node.parent)) then
        return false
    end
    if node.parent:TagName() ~= node then
        return false
    end
    local text = scanner.GetSourceTextOfNodeFromSourceFile(sourceFile, node, false --[[includeTrivia]])
    return scanner.IsIntrinsicJsxName(text)
end

return tsbaseline
