local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local JSDeclarationKind = ast.JSDeclarationKind
local SymbolKind = lsproto.SymbolKind

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

local function rangeKey(r)
    return r.start.line .. ":" .. r.start.character .. "-" .. r.end_.line .. ":" .. r.end_.character
end

local function stringsCompare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

function LanguageService:ProvideDocumentSymbols(ctx, documentURI)
    local _, file = self:getProgramAndFile(documentURI)
    local projections = core.AppendAll({ file }, file:SupplementalSourceFiles())
    local symbols = nil
    -- seen: Set[struct{ name, kind, rng }]
    local seen = collections.NewSet()
    for _, projection in ipairs(projections) do
        for _, symbol in ipairs(self:getDocumentSymbolsForChildren(ctx, projection:AsNode(), projection) or {}) do
            local key = symbol.name .. "\0" .. tostring(symbol.kind) .. "\0" .. rangeKey(symbol.range)
            if seen:AddIfAbsent(key) then
                symbols = core.Append(symbols, symbol)
            end
        end
    end
    if lsproto.GetClientCapabilities(ctx).textDocument.documentSymbol.hierarchicalDocumentSymbolSupport then
        return { documentSymbols = symbols or {} }, nil
    end
    -- Client doesn't support hierarchical document symbols, return flat SymbolInformation array
    local symbolInfos = ls.flattenDocumentSymbols(symbols, documentURI)
    local symbolInfoPtrs = {}
    for i, info in ipairs(symbolInfos or {}) do
        symbolInfoPtrs[i] = info
    end
    return { symbolInformations = symbolInfoPtrs }, nil
end

-- getDocumentSymbolInformations converts hierarchical DocumentSymbols to a flat SymbolInformation array
function LanguageService:getDocumentSymbolInformations(ctx, file, documentURI)
    -- First get hierarchical symbols
    local docSymbols = self:getDocumentSymbolsForChildren(ctx, file:AsNode(), file)
    return ls.flattenDocumentSymbols(docSymbols, documentURI)
end

function ls.flattenDocumentSymbols(docSymbols, documentURI)
    -- Flatten the hierarchy
    local result = nil
    local flatten
    flatten = function(symbols, containerName)
        for _, symbol in ipairs(symbols or {}) do
            local info = {
                name = symbol.name,
                kind = symbol.kind,
                location = {
                    uri = documentURI,
                    range = symbol.range,
                },
                containerName = containerName,
                tags = symbol.tags,
                deprecated = symbol.deprecated,
            }
            result = core.Append(result, info)

            -- Recursively flatten children with this symbol as container
            if symbol.children ~= nil and #symbol.children > 0 then
                flatten(symbol.children, symbol.name)
            end
        end
    end
    flatten(docSymbols, nil)
    return result
end

function LanguageService:getDocumentSymbolsForChildren(ctx, node, file)
    local symbols = nil
    local expandoTargets = collections.NewSet()
    local function addSymbolForNode(n, name, children)
        if n.flags & NodeFlags.Reparsed == 0 then
            local symbol = self:newDocumentSymbol(n, name, children)
            if symbol ~= nil then
                symbols = core.Append(symbols, symbol)
            end
        end
    end
    local visit
    local function getSymbolsForChildren(n)
        local result = nil
        if n ~= nil then
            local saveExpandoTargets = expandoTargets
            expandoTargets = collections.NewSet()
            local saveSymbols = symbols
            symbols = nil
            n:ForEachChild(visit)
            result = symbols
            symbols = saveSymbols
            expandoTargets = saveExpandoTargets
        end
        return result
    end
    local function startNode(n, name)
        if n == nil then
            return function() end
        end
        local saveExpandoTargets = expandoTargets
        expandoTargets = collections.NewSet()
        local saveSymbols = symbols
        symbols = nil
        return function()
            local result = symbols
            symbols = saveSymbols
            expandoTargets = saveExpandoTargets
            addSymbolForNode(n, name, result)
        end
    end
    local function getSymbolsForNode(n)
        local result = nil
        if n ~= nil then
            local saveSymbols = symbols
            symbols = nil
            visit(n)
            result = symbols
            symbols = saveSymbols
        end
        return result
    end
    visit = function(n)
        if ctxErr(ctx) then
            return true
        end
        if n.flags & NodeFlags.Reparsed == 0 then
            local jsdocs = n:JSDoc(file)
            if core.Len(jsdocs) > 0 then
                for _, jsdoc in ipairs(jsdocs) do
                    local tagList = jsdoc:AsJSDoc().tags
                    if tagList ~= nil then
                        for _, tag in ipairs(tagList.nodes or {}) do
                            if ast.IsJSDocTypedefTag(tag) or ast.IsJSDocCallbackTag(tag) then
                                addSymbolForNode(tag, nil --[[name]], nil --[[children]])
                            end
                        end
                    end
                end
            end
        end
        local k = n.kind
        if k == Kind.ClassDeclaration or k == Kind.ClassExpression or k == Kind.InterfaceDeclaration or k == Kind.EnumDeclaration then
            if ast.IsClassLike(n) and ast.GetDeclarationName(n) ~= "" then
                expandoTargets:Add(ast.GetDeclarationName(n))
            end
            addSymbolForNode(n, nil --[[name]], getSymbolsForChildren(n))
        elseif k == Kind.ModuleDeclaration then
            addSymbolForNode(n, nil --[[name]], getSymbolsForChildren(ls.getInteriorModule(n)))
        elseif k == Kind.Constructor then
            addSymbolForNode(n, nil --[[name]], getSymbolsForChildren(n:Body()))
            for _, param in ipairs(n:Parameters() or {}) do
                if ast.IsParameterPropertyDeclaration(param, n) then
                    addSymbolForNode(param, nil --[[name]], nil --[[children]])
                end
            end
        elseif k == Kind.FunctionDeclaration or k == Kind.FunctionExpression or k == Kind.ArrowFunction or k == Kind.MethodDeclaration or k == Kind.GetAccessor or
            k == Kind.SetAccessor then
            local declName = ast.GetDeclarationName(n)
            if declName ~= "" then
                expandoTargets:Add(declName)
            end
            addSymbolForNode(n, nil --[[name]], getSymbolsForChildren(n:Body()))
        elseif k == Kind.VariableDeclaration or k == Kind.BindingElement or k == Kind.PropertyAssignment or k == Kind.PropertyDeclaration then
            local nodeName = n:Name()
            if nodeName ~= nil then
                if ast.IsBindingPattern(nodeName) then
                    visit(nodeName)
                else
                    addSymbolForNode(n, nil --[[name]], getSymbolsForChildren(n:Initializer()))
                end
            end
        elseif k == Kind.SpreadAssignment then
            addSymbolForNode(n, n:Expression(), nil --[[children]])
        elseif k == Kind.MethodSignature or k == Kind.PropertySignature or k == Kind.CallSignature or k == Kind.ConstructSignature or k == Kind.IndexSignature or
            k == Kind.EnumMember or k == Kind.ShorthandPropertyAssignment or k == Kind.TypeAliasDeclaration or k == Kind.ImportEqualsDeclaration or k == Kind.ExportSpecifier then
            addSymbolForNode(n, nil --[[name]], nil --[[children]])
        elseif k == Kind.ImportClause then
            -- Handle default import case e.g.:
            --    import d from "mod";
            if n:Name() ~= nil then
                addSymbolForNode(n:Name(), n:Name(), nil --[[children]])
            end
            -- Handle named bindings in imports e.g.:
            --    import * as NS from "mod";
            --    import {a, b as B} from "mod";
            local namedBindings = n:AsImportClause().namedBindings
            if namedBindings ~= nil then
                if namedBindings.kind == Kind.NamespaceImport then
                    addSymbolForNode(namedBindings, nil --[[name]], nil --[[children]])
                else
                    for _, element in ipairs(namedBindings:Elements() or {}) do
                        addSymbolForNode(element, nil --[[name]], nil --[[children]])
                    end
                end
            end
        elseif k == Kind.BinaryExpression or k == Kind.CallExpression then
            local assignmentKind = ast.GetAssignmentDeclarationKind(n)
            -- `module.exports = ...`` should be reparsed into a JSExportAssignment,
            -- and `exports.a = ...`` into a CommonJSExport.
            if assignmentKind == JSDeclarationKind.None or assignmentKind == JSDeclarationKind.ThisProperty or
                assignmentKind == JSDeclarationKind.ModuleExports or assignmentKind == JSDeclarationKind.ExportsProperty or
                assignmentKind == JSDeclarationKind.ObjectDefinePropertyExports then
                n:ForEachChild(visit)
            elseif assignmentKind == JSDeclarationKind.Property or assignmentKind == JSDeclarationKind.ObjectDefinePropertyValue then
                local target
                local targetFunction
                local definition
                local propertyName
                -- `A.b = ... ` or `A.prototype.b = ...`
                if ast.IsBinaryExpression(n) then
                    local binaryExpr = n:AsBinaryExpression()
                    target = binaryExpr.left
                    targetFunction = target:Expression()
                    definition = binaryExpr.right
                    -- `A.b` or `A.prototype.b`
                    if ast.IsPropertyAccessExpression(target) then
                        propertyName = target:AsPropertyAccessExpression():Name()
                    else -- `A["b"]` or `A.prototype["b"]`
                        propertyName = target:AsElementAccessExpression().argumentExpression
                    end
                else -- `Object.defineProperty(A, "b", {...})`
                    local args = n:Arguments()
                    targetFunction = args[1]
                    target = args[2]
                    propertyName = target
                    definition = args[3]
                end
                if ls.isPrototypeExpando(targetFunction) then
                    targetFunction = targetFunction:Expression()
                    -- If we see a prototype assignment, start tracking the target as an expando target.
                    if ast.IsIdentifier(targetFunction) then
                        expandoTargets:Add(targetFunction:Text())
                    end
                end
                if ast.IsIdentifier(targetFunction) and
                    expandoTargets:Has(targetFunction:Text()) then
                    local endNode = startNode(n, targetFunction)
                    addSymbolForNode(target, propertyName, getSymbolsForNode(definition))
                    endNode()
                else
                    n:ForEachChild(visit)
                end
            end
        elseif k == Kind.ExportAssignment then
            if n:AsExportAssignment().isExportEquals then
                addSymbolForNode(n, nil --[[name]], getSymbolsForNode(n:Expression()))
            else
                n:ForEachChild(visit)
            end
        else
            n:ForEachChild(visit)
        end
        return false
    end
    node:ForEachChild(visit)
    return ls.mergeExpandos(symbols)
end

-- Target is `f.prototype`.
function ls.isPrototypeExpando(target)
    if ast.IsAccessExpression(target) then
        local accessName = ast.GetElementOrPropertyAccessName(target)
        return accessName ~= nil and accessName:Text() == "prototype"
    end
    return false
end

ls.maxLength = 150

function LanguageService:newDocumentSymbol(node, name, children)
    local result = {}
    local file = ast.GetSourceFileOfNode(node)
    local nodeStartPos = scanner.SkipTrivia(file:Text(), node:Pos())
    if name == nil then
        name = ast.GetNameOfDeclaration(node)
    end
    local text = ""
    local nameStartPos, nameEndPos = 0, 0
    if ast.IsModuleDeclaration(node) and not ast.IsAmbientModule(node) then
        text = ls.getModuleName(node)
        nameStartPos = scanner.SkipTrivia(file:Text(), name:Pos())
        nameEndPos = ls.getInteriorModule(node):Name():End()
    elseif ast.IsAnyExportAssignment(node) and node:AsExportAssignment().isExportEquals then
        text = "export="
        if not ast.NodeIsMissing(name) then
            nameStartPos = scanner.SkipTrivia(file:Text(), name:Pos())
            nameEndPos = name:End()
        else
            nameStartPos = nodeStartPos
            nameEndPos = node:End()
        end
    elseif name ~= nil then
        text = ls.getTextOfName(name)
        nameStartPos = math.max(scanner.SkipTrivia(file:Text(), name:Pos()), nodeStartPos)
        nameEndPos = math.max(name:End(), nodeStartPos)
    else
        text = ls.getUnnamedNodeLabel(node)
        nameStartPos = nodeStartPos
        nameEndPos = nodeStartPos
    end
    if text == "" then
        return nil
    end
    local truncatedText = stringutil.TruncateByRunes(text, ls.maxLength)
    if #truncatedText < #text then
        text = truncatedText .. "..."
    end
    result.name = text
    result.kind = ls.getSymbolKindFromNode(node)
    local selectionRange, selectionFidelity = self.converters:ToLSPRangeForFeature(file, core.NewTextRange(nameStartPos, nameEndPos), spanmap.Feature.DocumentSymbols)
    if not spanmap.Fidelity_IsSingleSegment(selectionFidelity) then
        return nil
    end
    local symbolRange, rangeFidelity = self.converters:ToLSPRangeForFeature(file, core.NewTextRange(nodeStartPos, node:End()), spanmap.Feature.DocumentSymbols)
    if spanmap.Fidelity_IsNone(rangeFidelity) then
        symbolRange = selectionRange
    end
    result.range = symbolRange
    result.selectionRange = selectionRange
    if children == nil then
        children = {}
    end
    result.children = children
    return result
end

-- Merges expando symbols into their target symbols, and namespaces of same name.
-- Modifies the input slice (Go sets merged entries to nil; here they are recorded in `merged`).
function ls.mergeExpandos(symbols)
    local mergedSymbols = {}
    local n = core.Len(symbols)
    local merged = {}
    -- Collect symbols that can be an expando target.
    local nameToExpandoTargetIndex = collections.NewMultiMap()
    -- Collect namespaces.
    local nameToNamespaceIndex = {}
    for i1 = 1, n do
        local i = i1 - 1
        local symbol = symbols[i1]
        if ls.isAnonymousName(symbol.name) then
            goto continue
        end
        if symbol.kind == SymbolKind.Class or symbol.kind == SymbolKind.Function or symbol.kind == SymbolKind.Variable then
            nameToExpandoTargetIndex:Add(symbol.name, i)
        end
        if symbol.kind == SymbolKind.Namespace then
            if nameToNamespaceIndex[symbol.name] == nil then
                nameToNamespaceIndex[symbol.name] = i
            end
        end
        ::continue::
    end
    for i1 = 1, n do
        local i = i1 - 1
        local symbol = symbols[i1]
        if symbol.children ~= nil then
            local children = ls.mergeExpandos(symbol.children)
            symbol.children = children
        end

        -- Anonymous symbols never merge.
        if ls.isAnonymousName(symbol.name) then
            goto continue
        end

        -- Merge expandos.
        if symbol.kind == SymbolKind.Property then
            local symbolsWithSameName = nameToExpandoTargetIndex:Get(symbol.name) or {}
            for j = #symbolsWithSameName, 1, -1 do
                local targetIndex = symbolsWithSameName[j]
                local targetSymbol = symbols[targetIndex + 1]
                ls.mergeChildren(targetSymbol, symbol)
                -- Mark this symbol as merged.
                merged[i1] = true
            end
        end
        -- Merge namespaces.
        if symbol.kind == SymbolKind.Namespace then
            local targetIndex = nameToNamespaceIndex[symbol.name]
            if targetIndex ~= nil and targetIndex ~= i then
                local targetSymbol = symbols[targetIndex + 1]
                ls.mergeChildren(targetSymbol, symbol)
                -- Mark this symbol as merged.
                merged[i1] = true
            end
        end
        ::continue::
    end
    for i1 = 1, n do
        if not merged[i1] then
            mergedSymbols[#mergedSymbols + 1] = symbols[i1]
        end
    end
    return mergedSymbols
end

function ls.mergeChildren(target, source)
    if source.children ~= nil then
        if target.children == nil then
            target.children = source.children
        else
            local children = ls.mergeExpandos(core.AppendAll(core.Slice(target.children), source.children))
            core.SortFunc(children, function(a, b)
                return lsproto.CompareRanges(a.range, b.range)
            end)
            target.children = children
        end
    end
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

-- See `getUnnamedNodeLabel`.
function ls.isAnonymousName(name)
    return name == "<function>" or name == "<class>" or name == "export=" or name == "default" or
        name == "constructor" or name == "()" or name == "new()" or name == "[]" or hasSuffix(name, ") callback")
end

function ls.getTextOfName(node)
    local k = node.kind
    if k == Kind.Identifier or k == Kind.PrivateIdentifier or k == Kind.NumericLiteral then
        return node:Text()
    elseif k == Kind.StringLiteral then
        return "\"" .. printer.EscapeString(node:Text(), printer.QuoteChar.DoubleQuote) .. "\""
    elseif k == Kind.NoSubstitutionTemplateLiteral then
        return "`" .. printer.EscapeString(node:Text(), printer.QuoteChar.Backtick) .. "`"
    elseif k == Kind.ComputedPropertyName then
        if ast.IsStringOrNumericLiteralLike(node:Expression()) then
            return ls.getTextOfName(node:Expression())
        end
    end
    return scanner.GetTextOfNode(node)
end

function ls.getUnnamedNodeLabel(node)
    local parent = ast.WalkUpParenthesizedExpressions(node.parent)
    if parent ~= nil and ast.IsExportAssignment(parent) then
        if parent:AsExportAssignment().isExportEquals then
            return "export="
        end
        return "default"
    end
    local k = node.kind
    if k == Kind.FunctionDeclaration or k == Kind.FunctionExpression or k == Kind.ArrowFunction then
        if node:ModifierFlags() & ModifierFlags.Default ~= 0 then
            return "default"
        end
        if ast.IsCallExpression(node.parent) then
            local name = ls.getCallExpressionName(node.parent:Expression())
            if name ~= "" then
                name = ls.cleanCallbackText(name)
                if #name > ls.maxLength then
                    return name .. " callback"
                end
                local args = ls.cleanCallbackText(ls.getCallExpressionLiteralArgs(node.parent))
                return name .. "(" .. args .. ") callback"
            end
        end
        return "<function>"
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        if node:ModifierFlags() & ModifierFlags.Default ~= 0 then
            return "default"
        end
        return "<class>"
    elseif k == Kind.Constructor then
        return "constructor"
    elseif k == Kind.CallSignature then
        return "()"
    elseif k == Kind.ConstructSignature then
        return "new()"
    elseif k == Kind.IndexSignature then
        return "[]"
    end
    return ""
end

function ls.getCallExpressionName(node)
    local k = node.kind
    if k == Kind.Identifier or k == Kind.PrivateIdentifier then
        return node:Text()
    elseif k == Kind.PropertyAccessExpression then
        local left = ls.getCallExpressionName(node:Expression())
        local right = ls.getCallExpressionName(node:Name())
        if left ~= "" then
            return left .. "." .. right
        end
        return right
    end
    return ""
end

function ls.getCallExpressionLiteralArgs(callExpr)
    local parts = {}
    for _, arg in ipairs(callExpr:Arguments() or {}) do
        if ast.IsStringLiteralLike(arg) or ast.IsTemplateExpression(arg) then
            parts[#parts + 1] = scanner.GetTextOfNode(arg)
        end
    end
    return table.concat(parts, ", ")
end

function ls.cleanCallbackText(text)
    local truncated = stringutil.TruncateByRunes(text, ls.maxLength)
    if #truncated < #text then
        text = truncated .. "..."
    end
    -- Go strings.Map dropping line-break runes (invalid bytes become U+FFFD, like Go).
    local parts = {}
    for _, r in core.Runes(text) do
        if not stringutil.IsLineBreak(r) then
            parts[#parts + 1] = core.EncodeRune(r)
        end
    end
    return table.concat(parts)
end

function ls.getInteriorModule(node)
    while node:Body() ~= nil and ast.IsModuleDeclaration(node:Body()) do
        node = node:Body()
    end
    return node
end

function ls.getModuleName(node)
    local result = node:Name():Text()
    while node:Body() ~= nil and ast.IsModuleDeclaration(node:Body()) do
        node = node:Body()
        result = result .. "." .. node:Name():Text()
    end
    return result
end

-- DeclarationInfo: { name, declaration, matchScore }

function ls.ProvideWorkspaceSymbols(
    ctx,
    programs,
    converters,
    preferences,
    query
)
    local excludeLibrarySymbols = core.Tristate_IsTrue(preferences.excludeLibrarySymbolsInNavTo)
    -- Obtain set of non-declaration source files from all active programs.
    local sourceFiles = {}
    local sourceFileOrder = {}
    for _, program in ipairs(programs or {}) do
        for _, sourceFile in ipairs(program:SourceFiles() or {}) do
            if (program:HasTSFile() or not sourceFile.isDeclarationFile) and
                not ls.shouldExcludeFile(sourceFile, program, excludeLibrarySymbols) then
                local path = sourceFile:Path()
                if sourceFiles[path] == nil then
                    sourceFileOrder[#sourceFileOrder + 1] = path
                end
                sourceFiles[path] = sourceFile
            end
        end
    end
    -- Create DeclarationInfos for all declarations in the source files.
    -- (Go iterates maps in random order; the infos are fully sorted below.)
    local infos = {}
    for _, path in ipairs(sourceFileOrder) do
        local sourceFile = sourceFiles[path]
        if ctxErr(ctx) then
            return {}, nil
        end
        local declarationMap = sourceFile:GetDeclarationMap()
        for name, declarations in pairs(declarationMap or {}) do
            local score = ls.getMatchScore(name, query)
            if score >= 0 then
                for _, declaration in ipairs(declarations) do
                    infos[#infos + 1] = { name = name, declaration = declaration, matchScore = score }
                end
            end
        end
    end
    -- Sort the DeclarationInfos and return the top 256 matches.
    core.SortFunc(infos, ls.compareDeclarationInfos)
    local count = math.min(#infos, 256)
    local symbols = {}
    for idx = 1, count do
        local info = infos[idx]
        local node = info.declaration
        local sourceFile = ast.GetSourceFileOfNode(node)
        local container = ls.getContainerNode(info.declaration)
        local containerName = nil
        if container ~= nil then
            containerName = ls.strPtrTo(ast.GetDeclarationName(container))
        end
        -- Use the name node's span so that VS selects just the symbol name (matching
        -- the TS5 navto behaviour). GetNameOfDeclaration is always non-nil here because
        -- computeDeclarationMap only adds declarations whose GetDeclarationName (string
        -- form) is non-empty, which implies a name node exists.
        local nameNode = ast.GetNameOfDeclaration(node)
        local nameStart = astnav.GetStartOfNode(nameNode, sourceFile, false --[[includeJsDoc]])
        local nameRange = core.NewTextRange(nameStart, nameNode:End())
        local location, fidelity = converters:ToLSPLocationForFeature(sourceFile, nameRange, spanmap.Feature.DocumentSymbols)
        if not spanmap.Fidelity_IsSingleSegment(fidelity) then
            -- The name has no counterpart in the original text, so there is nothing to navigate to.
            goto continue
        end
        do
            local symbol = {}
            symbol.name = info.name
            symbol.kind = ls.getSymbolKindFromNode(info.declaration)
            symbol.location = location
            symbol.containerName = containerName
            symbols[#symbols + 1] = symbol
        end
        ::continue::
    end

    return { symbolInformations = symbols }, nil
end

function ls.shouldExcludeFile(file, program, excludeLibrarySymbols)
    return excludeLibrarySymbols and (ls.isInsideNodeModules(file:FileName()) or program:IsLibFile(file))
end

function ls.isInsideNodeModules(fileName)
    return string.find(fileName, "/node_modules/", 1, true) ~= nil
end

-- Return a score for matching `s` against `pattern`. In order to match, `s` must contain each of the characters in
-- `pattern` in the same order. Upper case characters in `pattern` must match exactly, whereas lower case characters
-- in `pattern` match either case in `s`. If `s` doesn't match, -1 is returned. Otherwise, the returned score is the
-- number of characters in `s` that weren't matched. Thus, zero represents an exact match, and higher values represent
-- increasingly less specific partial matches.
function ls.getMatchScore(s, pattern)
    local score = 0
    local pos = 0
    for _, p in core.Runes(pattern) do
        local exact = stringutil.UnicodeIsUpper(p)
        while true do
            local c, size = core.DecodeRune(s, pos)
            if size == 0 then
                return -1
            end
            pos = pos + size
            if exact and c == p or not exact and stringutil.UnicodeToLower(c) == stringutil.UnicodeToLower(p) then
                break
            end
            score = score + 1
        end
    end
    return score
end

-- Sort DeclarationInfos by ascending match score, then ascending case insensitive name, then
-- ascending case sensitive name, and finally by source file name and position.
function ls.compareDeclarationInfos(d1, d2)
    if d1.matchScore ~= d2.matchScore then
        return d1.matchScore - d2.matchScore
    end
    local c = stringutil.CompareStringsCaseInsensitive(d1.name, d2.name)
    if c ~= 0 then
        return c
    end
    c = stringsCompare(d1.name, d2.name)
    if c ~= 0 then
        return c
    end
    local s1 = ast.GetSourceFileOfNode(d1.declaration)
    local s2 = ast.GetSourceFileOfNode(d2.declaration)
    if s1 ~= s2 then
        return stringsCompare(s1:Path(), s2:Path())
    end
    return d1.declaration:Pos() - d2.declaration:Pos()
end

-- getSymbolKindFromNode converts an AST node to an LSP SymbolKind.
-- Combines getNodeKind with VS Code's fromProtocolScriptElementKind.
function ls.getSymbolKindFromNode(node)
    local k = node.kind
    if k == Kind.SourceFile then
        if ast.IsExternalModule(node:AsSourceFile()) then
            return SymbolKind.Module
        end
        return SymbolKind.File
    elseif k == Kind.ModuleDeclaration then
        return SymbolKind.Namespace
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        return SymbolKind.Class
    elseif k == Kind.InterfaceDeclaration then
        return SymbolKind.Interface
    elseif k == Kind.TypeAliasDeclaration or k == Kind.JSDocTypedefTag or k == Kind.JSDocCallbackTag then
        return SymbolKind.Class
    elseif k == Kind.EnumDeclaration then
        return SymbolKind.Enum
    elseif k == Kind.VariableDeclaration then
        return SymbolKind.Variable
    elseif k == Kind.ArrowFunction or k == Kind.FunctionDeclaration or k == Kind.FunctionExpression then
        return SymbolKind.Function
    elseif k == Kind.GetAccessor or k == Kind.SetAccessor then
        return SymbolKind.Property
    elseif k == Kind.MethodDeclaration or k == Kind.MethodSignature then
        return SymbolKind.Method
    elseif k == Kind.PropertyDeclaration or k == Kind.PropertySignature or k == Kind.PropertyAssignment or
        k == Kind.ShorthandPropertyAssignment or k == Kind.SpreadAssignment or k == Kind.IndexSignature then
        return SymbolKind.Property
    elseif k == Kind.CallSignature then
        return SymbolKind.Method
    elseif k == Kind.ConstructSignature then
        return SymbolKind.Constructor
    elseif k == Kind.Constructor or k == Kind.ClassStaticBlockDeclaration then
        return SymbolKind.Constructor
    elseif k == Kind.TypeParameter then
        return SymbolKind.TypeParameter
    elseif k == Kind.EnumMember then
        return SymbolKind.EnumMember
    elseif k == Kind.Parameter then
        if ast.HasSyntacticModifier(node, ModifierFlags.ParameterPropertyModifier) then
            return SymbolKind.Property
        end
        return SymbolKind.Variable
    elseif k == Kind.BinaryExpression or k == Kind.CallExpression then
        local kind = ast.GetAssignmentDeclarationKind(node)
        if kind == JSDeclarationKind.ThisProperty or kind == JSDeclarationKind.Property or kind == JSDeclarationKind.ObjectDefinePropertyValue then
            return SymbolKind.Property
        end
    elseif k == Kind.StringLiteral or k == Kind.NoSubstitutionTemplateLiteral or k == Kind.NumericLiteral then
        -- String literals used as property names (e.g., in Object.defineProperty)
        return SymbolKind.Property
    end
    return SymbolKind.Variable
end
