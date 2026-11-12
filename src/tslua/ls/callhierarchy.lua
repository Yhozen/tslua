local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function rangeEqual(a, b)
    return a.start.line == b.start.line and a.start.character == b.start.character and
        a.end_.line == b.end_.line and a.end_.character == b.end_.character
end

local function locationKey(uri, r)
    return tostring(uri) .. "\0" .. r.start.line .. ":" .. r.start.character .. "-" .. r.end_.line .. ":" .. r.end_.character
end

local function stringsCompare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- CallHierarchyDeclaration = *ast.Node

-- Indictates whether a node is named function or class expression.
function ls.isNamedExpression(node)
    if node == nil then
        return false
    end
    if not ast.IsFunctionExpression(node) and not ast.IsClassExpression(node) then
        return false
    end
    local name = node:Name()
    return name ~= nil and ast.IsIdentifier(name)
end

function ls.isVariableLike(node)
    if node == nil then
        return false
    end
    return ast.IsPropertyDeclaration(node) or ast.IsVariableDeclaration(node)
end

-- Indicates whether a node is a function, arrow, or class expression assigned to a constant variable or class property.
function ls.isAssignedExpression(node)
    if node == nil then
        return false
    end
    if not (ast.IsFunctionExpression(node) or ast.IsArrowFunction(node) or ast.IsClassExpression(node)) then
        return false
    end
    if node:Name() ~= nil then
        return false
    end
    local parent = node.parent
    if not ls.isVariableLike(parent) then
        return false
    end

    if parent:Initializer() ~= node then
        return false
    end

    local name = parent:Name()
    if not ast.IsIdentifier(name) then
        return false
    end

    return (ast.GetCombinedNodeFlags(parent) & NodeFlags.Const) ~= 0 or ast.IsPropertyDeclaration(parent)
end

-- Indicates whether a node could possibly be a call hierarchy declaration.
--
-- See `resolveCallHierarchyDeclaration` for the specific rules.
function ls.isPossibleCallHierarchyDeclaration(node)
    if node == nil then
        return false
    end
    return ast.IsSourceFile(node) or
        ast.IsModuleDeclaration(node) or
        ast.IsFunctionDeclaration(node) or
        ast.IsFunctionExpression(node) or
        ast.IsClassDeclaration(node) or
        ast.IsClassExpression(node) or
        ast.IsClassStaticBlockDeclaration(node) or
        ast.IsMethodDeclaration(node) or
        ast.IsMethodSignatureDeclaration(node) or
        ast.IsGetAccessorDeclaration(node) or
        ast.IsSetAccessorDeclaration(node)
end

-- Indicates whether a node is a valid a call hierarchy declaration.
--
-- See `resolveCallHierarchyDeclaration` for the specific rules.
function ls.isValidCallHierarchyDeclaration(node)
    if node == nil then
        return false
    end

    if ast.IsSourceFile(node) then
        return true
    end

    if ast.IsModuleDeclaration(node) then
        return ast.IsIdentifier(node:Name())
    end

    return ast.IsFunctionDeclaration(node) or
        ast.IsClassDeclaration(node) or
        ast.IsClassStaticBlockDeclaration(node) or
        ast.IsMethodDeclaration(node) or
        ast.IsMethodSignatureDeclaration(node) or
        ast.IsGetAccessorDeclaration(node) or
        ast.IsSetAccessorDeclaration(node) or
        ls.isNamedExpression(node) or
        ls.isAssignedExpression(node)
end

-- Gets the node that can be used as a reference to a call hierarchy declaration.
function ls.getCallHierarchyDeclarationReferenceNode(node)
    if node == nil then
        return nil
    end

    if ast.IsSourceFile(node) then
        return node
    end

    local name = node:Name()
    if name ~= nil then
        return name
    end

    if ls.isAssignedExpression(node) then
        return node.parent:Name()
    end

    local modifiers = node:Modifiers()
    if modifiers ~= nil then
        for _, mod in ipairs(modifiers.nodes or {}) do
            if mod.kind == Kind.DefaultKeyword then
                return mod
            end
        end
    end

    return nil
end

-- Gets the symbol for a call hierarchy declaration.
function ls.getSymbolOfCallHierarchyDeclaration(c, node)
    if ast.IsClassStaticBlockDeclaration(node) then
        return nil
    end
    local location = ls.getCallHierarchyDeclarationReferenceNode(node)
    if location == nil then
        return nil
    end
    return c:GetSymbolAtLocation(location)
end

-- Gets the text and range for the name of a call hierarchy declaration.
-- Returns text, pos, end.
function ls.getCallHierarchyItemName(program, node)
    if ast.IsSourceFile(node) then
        local sourceFile = node:AsSourceFile()
        return sourceFile:FileName(), 0, 0
    end

    if (ast.IsFunctionDeclaration(node) or ast.IsClassDeclaration(node)) and node:Name() == nil then
        local modifiers = node:Modifiers()
        if modifiers ~= nil then
            for _, mod in ipairs(modifiers.nodes or {}) do
                if mod.kind == Kind.DefaultKeyword then
                    local sourceFile = ast.GetSourceFileOfNode(node)
                    local start = scanner.SkipTrivia(sourceFile:Text(), mod:Pos())
                    return "default", start, mod:End()
                end
            end
        end
    end

    if ast.IsClassStaticBlockDeclaration(node) then
        local sourceFile = ast.GetSourceFileOfNode(node)
        local pos = scanner.SkipTrivia(sourceFile:Text(), ls.moveRangePastModifiers(node):Pos())
        local end_ = pos + 6 -- "static".length
        local c, done = program:GetTypeCheckerForFile(nil, sourceFile)
        local symbol = c:GetSymbolAtLocation(node.parent)
        local prefix = ""
        if symbol ~= nil then
            prefix = c:SymbolToString(symbol) .. " "
        end
        done()
        return prefix .. "static {}", pos, end_
    end

    local declName
    if ls.isAssignedExpression(node) then
        declName = node.parent:Name()
    else
        declName = ast.GetNameOfDeclaration(node)
    end

    if declName == nil or not ast.NodeIsPresent(declName) then
        local sourceFile = ast.GetSourceFileOfNode(node)
        if ast.IsFunctionDeclaration(node) or ast.IsFunctionExpression(node) then
            local kwPos = scanner.SkipTrivia(sourceFile:Text(), ls.moveRangePastModifiers(node):Pos())
            return "(anonymous)", kwPos, kwPos + 8 -- "function".length
        elseif ast.IsClassDeclaration(node) or ast.IsClassExpression(node) then
            local kwPos = scanner.SkipTrivia(sourceFile:Text(), ls.moveRangePastModifiers(node):Pos())
            return "(anonymous)", kwPos, kwPos + 5 -- "class".length
        end
        debug.Assert(declName ~= nil, "Expected call hierarchy item to have a name")
    end

    local text = ls.getTextOfCallHierarchyName(program, node, declName, node)

    local sourceFile = ast.GetSourceFileOfNode(node)
    local namePos = scanner.SkipTrivia(sourceFile:Text(), declName:Pos())

    return text, namePos, declName:End()
end

function ls.getTextOfCallHierarchyName(program, sourceNode, name, printNode)
    if ast.IsIdentifier(name) or ast.IsStringOrNumericLiteralLike(name) then
        return name:Text()
    end
    if ast.IsComputedPropertyName(name) then
        local expr = name:Expression()
        if ast.IsStringOrNumericLiteralLike(expr) then
            return expr:Text()
        end
    end

    local c, done = program:GetTypeCheckerForFile(nil, ast.GetSourceFileOfNode(sourceNode))
    local symbol = c:GetSymbolAtLocation(name)
    if symbol ~= nil then
        local text = c:SymbolToString(symbol)
        if text ~= "" then
            done()
            return text
        end
    end

    local sourceFile = ast.GetSourceFileOfNode(sourceNode)
    local writer, putWriter = printer.GetSingleLineStringWriter()
    local p = printer.NewPrinter({ removeComments = true }, {}, nil)
    p:Write(printNode, sourceFile, writer, nil)
    local result = writer:String()
    putWriter()
    done()
    return result
end

function ls.getCallHierarchyItemContainerName(program, node)
    if ls.isAssignedExpression(node) then
        local parent = node.parent
        if ast.IsPropertyDeclaration(parent) and ast.IsClassLike(parent.parent) then
            if ast.IsClassExpression(parent.parent) then
                local assignedName = ast.GetAssignedName(parent.parent)
                if assignedName ~= nil then
                    return ls.getTextOfCallHierarchyName(program, node, assignedName, assignedName)
                end
            else
                local name = parent.parent:Name()
                if name ~= nil then
                    return ls.getTextOfCallHierarchyName(program, node, name, name)
                end
            end
        end
        if parent.parent.parent ~= nil and parent.parent.parent.parent ~= nil and ast.IsModuleBlock(parent.parent.parent.parent) then
            local modParent = parent.parent.parent.parent.parent
            if ast.IsModuleDeclaration(modParent) then
                local name = modParent:Name()
                if name ~= nil and ast.IsIdentifier(name) then
                    return name:Text()
                end
            end
        end
        return ""
    end

    local k = node.kind
    if k == Kind.GetAccessor or k == Kind.SetAccessor or k == Kind.MethodDeclaration then
        if node.parent.kind == Kind.ObjectLiteralExpression then
            local assignedName = ast.GetAssignedName(node.parent)
            if assignedName ~= nil then
                return ls.getTextOfCallHierarchyName(program, node, assignedName, assignedName)
            end
        end
        local name = ast.GetNameOfDeclaration(node.parent)
        if name ~= nil then
            return ls.getTextOfCallHierarchyName(program, node, name, name)
        end
    elseif k == Kind.FunctionDeclaration or k == Kind.ClassDeclaration or k == Kind.ModuleDeclaration then
        if ast.IsModuleBlock(node.parent) then
            if ast.IsModuleDeclaration(node.parent.parent) then
                local name = node.parent.parent:Name()
                if name ~= nil and ast.IsIdentifier(name) then
                    return name:Text()
                end
            end
        end
    end

    return ""
end

function ls.moveRangePastModifiers(node)
    local modifiers = node:Modifiers()
    if modifiers ~= nil and core.Len(modifiers.nodes) > 0 then
        local lastMod = modifiers.nodes[#modifiers.nodes]
        return core.NewTextRange(lastMod:End(), node:End())
    end
    return core.NewTextRange(node:Pos(), node:End())
end

-- Finds the implementation of a function-like declaration, if one exists.
function ls.findImplementation(c, node)
    if node == nil then
        return nil
    end

    if not ast.IsFunctionLikeDeclaration(node) then
        return node
    end

    if node:Body() ~= nil then
        return node
    end

    if ast.IsConstructorDeclaration(node) then
        return ast.GetFirstConstructorWithBody(node.parent)
    end

    if ast.IsFunctionDeclaration(node) or ast.IsMethodDeclaration(node) then
        local symbol = ls.getSymbolOfCallHierarchyDeclaration(c, node)
        if symbol ~= nil and symbol.valueDeclaration ~= nil then
            if ast.IsFunctionLikeDeclaration(symbol.valueDeclaration) and symbol.valueDeclaration:Body() ~= nil then
                return symbol.valueDeclaration
            end
        end
        return nil
    end

    return node
end

function ls.findAllInitialDeclarations(c, node)
    if ast.IsClassStaticBlockDeclaration(node) then
        return nil
    end

    local symbol = ls.getSymbolOfCallHierarchyDeclaration(c, node)
    if symbol == nil or symbol.declarations == nil then
        return nil
    end

    -- declKey: { file, pos }
    local n = #symbol.declarations
    local indices = {}
    for i = 0, n - 1 do
        indices[i + 1] = i
    end
    local keys = {}
    for i, decl in ipairs(symbol.declarations) do
        keys[i] = {
            file = ast.GetSourceFileOfNode(decl):FileName(),
            pos = decl:Pos(),
        }
    end

    core.SortFunc(indices, function(a, b)
        if keys[a + 1].file ~= keys[b + 1].file then
            return stringsCompare(keys[a + 1].file, keys[b + 1].file)
        end
        return keys[a + 1].pos - keys[b + 1].pos
    end)

    local declarations = nil
    local lastDecl = nil

    for _, i in ipairs(indices) do
        local decl = symbol.declarations[i + 1]
        if ls.isValidCallHierarchyDeclaration(decl) then
            if lastDecl == nil or lastDecl.parent ~= decl.parent or lastDecl:End() ~= decl:Pos() then
                declarations = core.Append(declarations, decl)
            end
            lastDecl = decl
        end
    end

    return declarations
end

-- Find the implementation or the first declaration for a call hierarchy declaration.
-- Returns a node or an array of nodes (Go `any`); arrays have no `kind` field.
function ls.findImplementationOrAllInitialDeclarations(c, node)
    if ast.IsClassStaticBlockDeclaration(node) then
        return node
    end

    if ast.IsFunctionLikeDeclaration(node) then
        local impl = ls.findImplementation(c, node)
        if impl ~= nil then
            return impl
        end
        local decls = ls.findAllInitialDeclarations(c, node)
        if decls ~= nil then
            return decls
        end
        return node
    end

    local decls = ls.findAllInitialDeclarations(c, node)
    if decls ~= nil then
        return decls
    end
    return node
end

-- Resolves the call hierarchy declaration for a node.
-- Returns nil, a node, or an array of nodes.
function ls.resolveCallHierarchyDeclaration(program, location)
    -- A call hierarchy item must refer to either a SourceFile, Module Declaration, Class Static Block, or something intrinsically callable that has a name:
    -- - Class Declarations
    -- - Class Expressions (with a name)
    -- - Function Declarations
    -- - Function Expressions (with a name or assigned to a const variable)
    -- - Arrow Functions (assigned to a const variable)
    -- - Constructors
    -- - Class `static {}` initializer blocks
    -- - Methods
    -- - Accessors
    --
    -- If a call is contained in a non-named callable Node (function expression, arrow function, etc.), then
    -- its containing `CallHierarchyItem` is a containing function or SourceFile that matches the above list.

    local c, done = program:GetTypeChecker(nil)
    local result = ls.resolveCallHierarchyDeclarationWorker(c, location)
    done()
    return result
end

-- Body of resolveCallHierarchyDeclaration after the checker is acquired (split out so `defer done()` runs on every path).
function ls.resolveCallHierarchyDeclarationWorker(c, location)
    local followingSymbol = false

    while location ~= nil do
        if ls.isValidCallHierarchyDeclaration(location) then
            return ls.findImplementationOrAllInitialDeclarations(c, location)
        end

        if ls.isPossibleCallHierarchyDeclaration(location) then
            local ancestor = ast.FindAncestor(location, ls.isValidCallHierarchyDeclaration)
            if ancestor ~= nil then
                return ls.findImplementationOrAllInitialDeclarations(c, ancestor)
            end
        end

        if ast.IsDeclarationName(location) then
            if ls.isValidCallHierarchyDeclaration(location.parent) then
                return ls.findImplementationOrAllInitialDeclarations(c, location.parent)
            end
            if ls.isPossibleCallHierarchyDeclaration(location.parent) then
                local ancestor = ast.FindAncestor(location.parent, ls.isValidCallHierarchyDeclaration)
                if ancestor ~= nil then
                    return ls.findImplementationOrAllInitialDeclarations(c, ancestor)
                end
            end
            if ls.isVariableLike(location.parent) then
                local initializer = location.parent:Initializer()
                if initializer ~= nil and ls.isAssignedExpression(initializer) then
                    return initializer
                end
            end
            return nil
        end

        if ast.IsConstructorDeclaration(location) then
            if ls.isValidCallHierarchyDeclaration(location.parent) then
                return location.parent
            end
            return nil
        end

        if location.kind == Kind.StaticKeyword and ast.IsClassStaticBlockDeclaration(location.parent) then
            location = location.parent
            goto continue
        end

        -- #39453
        if ast.IsVariableDeclaration(location) then
            local initializer = location:Initializer()
            if initializer ~= nil and ls.isAssignedExpression(initializer) then
                return initializer
            end
        end

        if not followingSymbol then
            local symbol = c:GetSymbolAtLocation(location)
            if symbol ~= nil then
                if (symbol.flags & SymbolFlags.Alias) ~= 0 then
                    symbol = c:GetAliasedSymbol(symbol)
                end
                if symbol.valueDeclaration ~= nil then
                    followingSymbol = true
                    location = symbol.valueDeclaration
                    goto continue
                end
            end
        end

        do
            return nil
        end
        ::continue::
    end

    return nil
end

-- Creates a `CallHierarchyItem` for a call hierarchy declaration.
function LanguageService:createCallHierarchyItem(program, node)
    local sourceFile = ast.GetSourceFileOfNode(node)
    local nameText, namePos, nameEnd = ls.getCallHierarchyItemName(program, node)
    local containerName = ls.getCallHierarchyItemContainerName(program, node)

    local kind = ls.getSymbolKindFromNode(node)

    local fullStart = scanner.SkipTriviaEx(sourceFile:Text(), node:Pos(), { stopAtComments = true })
    local span, spanFidelity = self.converters:ToLSPRangeForFeature(sourceFile, core.NewTextRange(fullStart, node:End()), spanmap.Feature.CallHierarchy)
    local selectionSpan, selectionFidelity = self.converters:ToLSPRangeForFeature(sourceFile, core.NewTextRange(namePos, nameEnd), spanmap.Feature.CallHierarchy)
    if not spanmap.Fidelity_IsSingleSegment(selectionFidelity) then
        return nil
    end
    if spanmap.Fidelity_IsNone(spanFidelity) or sourceFile:ContentMapper() ~= "" and not ls.lspRangeContains(span, selectionSpan) then
        span = selectionSpan
    end

    local item = {
        name = nameText,
        kind = kind,
        uri = lsconv.FileNameToDocumentURI(sourceFile:OriginalFileName()),
        range = span,
        selectionRange = selectionSpan,
    }

    if containerName ~= "" then
        item.detail = containerName
    end

    return item
end

-- callSite: { declaration, textRange, sourceFile }

function ls.convertEntryToCallSite(entry)
    if entry.kind ~= ls.entryKindNode then
        return nil
    end

    local node = entry.node
    if not ast.IsCallOrNewExpressionTarget(node, true --[[includeElementAccess]], true --[[skipPastOuterExpressions]]) and
        not ast.IsTaggedTemplateTag(node, true, true) and
        not ast.IsDecoratorTarget(node, true, true) and
        not ast.IsJsxOpeningLikeElementTagName(node, true, true) and
        not ast.IsRightSideOfPropertyAccess(node) and
        not ast.IsArgumentExpressionOfElementAccess(node) then
        return nil
    end

    local sourceFile = ast.GetSourceFileOfNode(node)
    local ancestor = ast.FindAncestor(node, ls.isValidCallHierarchyDeclaration)
    if ancestor == nil then
        ancestor = sourceFile:AsNode()
    end

    local start = scanner.SkipTrivia(sourceFile:Text(), node:Pos())
    return {
        declaration = ancestor,
        textRange = core.NewTextRange(start, node:End()),
        sourceFile = sourceFile:AsNode(),
    }
end

function ls.getCallSiteGroupKey(site)
    return ast.GetNodeId(site.declaration)
end

-- Groups call sites by key. Go uses a map (random iteration order); groups are returned in
-- first-seen order here.
local function groupCallSites(callSites)
    local groups = {}
    local byKey = {}
    for _, site in ipairs(callSites) do
        local key = ls.getCallSiteGroupKey(site)
        local group = byKey[key]
        if group == nil then
            group = {}
            byKey[key] = group
            groups[#groups + 1] = group
        end
        group[#group + 1] = site
    end
    return groups
end

function LanguageService:convertCallSiteGroupToIncomingCall(program, entries)
    local fromRanges = {}
    for _, entry in ipairs(entries) do
        local sourceFile = entry.sourceFile:AsSourceFile()
        local lspRange, fidelity = self.converters:ToLSPRangeForFeature(sourceFile, entry.textRange, spanmap.Feature.CallHierarchy)
        if not spanmap.Fidelity_IsNone(fidelity) then
            fromRanges[#fromRanges + 1] = lspRange
        end
    end
    local from = self:createCallHierarchyItem(program, entries[1].declaration)
    if from == nil or #fromRanges == 0 then
        return nil
    end

    core.SortFunc(fromRanges, lsproto.CompareRanges)

    return {
        from = from,
        fromRanges = fromRanges,
    }
end

-- incomingEntry implements lsproto.HasTextDocumentPosition for a reference node; the Go sync.Once
-- fields are memoized lazily.
local incomingEntry = {}
incomingEntry.__index = incomingEntry
ls.incomingEntry = incomingEntry

function incomingEntry:getSourceFile()
    if not self.sourceFileOnce then
        self.sourceFileOnce = true
        self.sourceFile = ast.GetSourceFileOfNode(self.node)
    end
    return self.sourceFile
end

function incomingEntry:TextDocumentURI()
    if not self.documentUriOnce then
        self.documentUriOnce = true
        self.documentUri = lsconv.FileNameToDocumentURI(self:getSourceFile():OriginalFileName())
    end
    return self.documentUri
end

function incomingEntry:TextDocumentPosition()
    if not self.positionOnce then
        self.positionOnce = true
        local start = scanner.GetTokenPosOfNode(self.node, self:getSourceFile(), false --[[includeJsDoc]])
        self.position = self.ls:createLspPosition(start, self:getSourceFile())
    end
    return self.position
end

-- Gets the call sites that call into the provided call hierarchy declaration.
function LanguageService:getIncomingCalls(ctx, program, declaration, orchestrator)
    -- Source files and modules have no incoming calls.
    if ast.IsSourceFile(declaration) or ast.IsModuleDeclaration(declaration) or ast.IsClassStaticBlockDeclaration(declaration) then
        return {}, nil
    end

    local location = ls.getCallHierarchyDeclarationReferenceNode(declaration)
    if location == nil then
        return {}, nil
    end
    local locationFile = ast.GetSourceFileOfNode(location)
    local locationStart = scanner.GetTokenPosOfNode(location, locationFile, false --[[includeJsDoc]])
    local _, fidelity = self.converters:ToLSPPositionForFeature(locationFile, locationStart, spanmap.Feature.CallHierarchy)
    if spanmap.Fidelity_IsNone(fidelity) then
        return {}, nil
    end

    local entry = setmetatable({
        ls = self,
        node = location,
        sourceFileOnce = false,
        documentUriOnce = false,
        documentUri = "",
        positionOnce = false,
    }, incomingEntry)

    local result, err = ls.handleCrossProject(
        self,
        ctx,
        entry,
        orchestrator,
        LanguageService.symbolAndEntriesToIncomingCalls,
        ls.combineIncomingCalls,
        false,
        false,
        ls.newSymbolEntryTransformOptions()
    )
    if result ~= nil and result.callHierarchyIncomingCalls ~= nil then
        core.SortFunc(result.callHierarchyIncomingCalls, function(a, b)
            local uriComp = stringsCompare(tostring(a.from.uri), tostring(b.from.uri))
            if uriComp ~= 0 then
                return uriComp
            end
            if #a.fromRanges == 0 or #b.fromRanges == 0 then
                return 0
            end
            return lsproto.CompareRanges(a.fromRanges[1], b.fromRanges[1])
        end)
    end
    return result, err
end

function LanguageService:symbolAndEntriesToIncomingCalls(ctx, params, data, options)
    local program = self:GetProgram()
    local refEntries = nil
    for _, symbolAndEntry in ipairs(data.symbolsAndEntries or {}) do
        refEntries = core.AppendAll(refEntries, symbolAndEntry.references)
    end

    local callSites = {}
    for _, entry in ipairs(refEntries or {}) do
        local site = ls.convertEntryToCallSite(entry)
        if site ~= nil then
            callSites[#callSites + 1] = site
        end
    end

    if #callSites == 0 then
        return {}, nil
    end

    local result = {}
    for _, sites in ipairs(groupCallSites(callSites)) do
        local incomingCall = self:convertCallSiteGroupToIncomingCall(program, sites)
        if incomingCall ~= nil then
            result[#result + 1] = incomingCall
        end
    end
    return { callHierarchyIncomingCalls = result }, nil
end

-- callSiteCollector: { program, callSites }
local callSiteCollector = {}
callSiteCollector.__index = callSiteCollector
ls.callSiteCollector = callSiteCollector

function callSiteCollector:recordCallSite(node)
    local target = nil

    if ast.IsTaggedTemplateExpression(node) then
        target = node:AsTaggedTemplateExpression().tag
    elseif ast.IsJsxOpeningElement(node) then
        target = node:TagName()
    elseif ast.IsJsxSelfClosingElement(node) then
        target = node:TagName()
    elseif ast.IsPropertyAccessExpression(node) or ast.IsElementAccessExpression(node) then
        target = node
    elseif ast.IsClassStaticBlockDeclaration(node) then
        target = node
    elseif ast.IsCallExpression(node) then
        target = node:Expression()
    elseif ast.IsNewExpression(node) then
        target = node:Expression()
    elseif ast.IsDecorator(node) then
        target = node:Expression()
    end

    if target == nil then
        return
    end

    local declaration = ls.resolveCallHierarchyDeclaration(self.program, target)
    if declaration == nil then
        return
    end

    local sourceFile = ast.GetSourceFileOfNode(target)
    local start = scanner.SkipTrivia(sourceFile:Text(), target:Pos())
    local textRange = core.NewTextRange(start, target:End())

    if declaration.kind ~= nil then
        self.callSites[#self.callSites + 1] = {
            declaration = declaration,
            textRange = textRange,
            sourceFile = sourceFile:AsNode(),
        }
    else
        for _, d in ipairs(declaration) do
            self.callSites[#self.callSites + 1] = {
                declaration = d,
                textRange = textRange,
                sourceFile = sourceFile:AsNode(),
            }
        end
    end
end

function callSiteCollector:collect(node)
    if node == nil then
        return
    end

    -- do not descend into ambient nodes.
    if (node.flags & NodeFlags.Ambient) ~= 0 then
        return
    end

    -- do not descend into other call site declarations, other than class member names
    if ls.isValidCallHierarchyDeclaration(node) then
        if ast.IsClassLike(node) then
            for _, member in ipairs(node:Members() or {}) do
                if member:Name() ~= nil and ast.IsComputedPropertyName(member:Name()) then
                    self:collect(member:Name():Expression())
                end
            end
        end
        return
    end

    local k = node.kind
    if k == Kind.Identifier or
        k == Kind.ImportEqualsDeclaration or
        k == Kind.ImportDeclaration or
        k == Kind.ExportDeclaration or
        k == Kind.InterfaceDeclaration or
        k == Kind.TypeAliasDeclaration then
        -- do not descend into nodes that cannot contain callable nodes
        return
    elseif k == Kind.ClassStaticBlockDeclaration then
        self:recordCallSite(node)
        return
    elseif k == Kind.TypeAssertionExpression or k == Kind.AsExpression then
        -- do not descend into the type side of an assertion
        self:collect(node:Expression())
        return
    elseif k == Kind.VariableDeclaration or k == Kind.Parameter then
        -- do not descend into the type of a variable or parameter declaration
        self:collect(node:Name())
        self:collect(node:Initializer())
        return
    elseif k == Kind.CallExpression then
        -- do not descend into the type arguments of a call expression
        self:recordCallSite(node)
        self:collect(node:Expression())
        for _, arg in ipairs(node:Arguments() or {}) do
            self:collect(arg)
        end
        return
    elseif k == Kind.NewExpression then
        -- do not descend into the type arguments of a new expression
        self:recordCallSite(node)
        self:collect(node:Expression())
        for _, arg in ipairs(node:Arguments() or {}) do
            self:collect(arg)
        end
        return
    elseif k == Kind.TaggedTemplateExpression then
        -- do not descend into the type arguments of a tagged template expression
        self:recordCallSite(node)
        local taggedTemplate = node:AsTaggedTemplateExpression()
        self:collect(taggedTemplate.tag)
        self:collect(taggedTemplate.template)
        return
    elseif k == Kind.JsxOpeningElement or k == Kind.JsxSelfClosingElement then
        -- do not descend into the type arguments of a JsxOpeningLikeElement
        self:recordCallSite(node)
        self:collect(node:TagName())
        self:collect(node:Attributes())
        return
    elseif k == Kind.Decorator then
        self:recordCallSite(node)
        self:collect(node:Expression())
        return
    elseif k == Kind.PropertyAccessExpression or k == Kind.ElementAccessExpression then
        self:recordCallSite(node)
        node:ForEachChild(function(child)
            self:collect(child)
            return false
        end)
        return
    elseif k == Kind.SatisfiesExpression then
        -- do not descend into the type side of an assertion
        self:collect(node:Expression())
        return
    end

    if ast.IsPartOfTypeNode(node) then
        -- do not descend into types
        return
    end

    node:ForEachChild(function(child)
        self:collect(child)
        return false
    end)
end

function ls.collectCallSites(program, c, node)
    local collector = setmetatable({
        program = program,
        callSites = {},
    }, callSiteCollector)

    local k = node.kind
    if k == Kind.SourceFile then
        for _, stmt in ipairs(node:Statements() or {}) do
            collector:collect(stmt)
        end
    elseif k == Kind.ModuleDeclaration then
        local body = node:Body()
        if not ast.HasSyntacticModifier(node, ModifierFlags.Ambient) and body ~= nil and ast.IsModuleBlock(body) then
            for _, stmt in ipairs(body:Statements() or {}) do
                collector:collect(stmt)
            end
        end
    elseif k == Kind.FunctionDeclaration or k == Kind.FunctionExpression or k == Kind.ArrowFunction or
        k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
        local impl = ls.findImplementation(c, node)
        if impl ~= nil then
            for _, param in ipairs(impl:Parameters() or {}) do
                collector:collect(param)
            end
            collector:collect(impl:Body())
        end
    elseif k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        local modifiers = node:Modifiers()
        if modifiers ~= nil then
            for _, mod in ipairs(modifiers.nodes or {}) do
                collector:collect(mod)
            end
        end

        local heritage = ast.GetClassExtendsHeritageElement(node)
        if heritage ~= nil then
            collector:collect(heritage:Expression())
        end

        for _, member in ipairs(node:Members() or {}) do
            if ast.CanHaveModifiers(member) and member:Modifiers() ~= nil then
                for _, mod in ipairs(member:Modifiers().nodes or {}) do
                    collector:collect(mod)
                end
            end

            if ast.IsPropertyDeclaration(member) then
                collector:collect(member:Initializer())
            elseif ast.IsConstructorDeclaration(member) then
                local body = member:Body()
                if body ~= nil then
                    for _, param in ipairs(member:Parameters() or {}) do
                        collector:collect(param)
                    end
                    collector:collect(body)
                end
            elseif ast.IsClassStaticBlockDeclaration(member) then
                collector:collect(member)
            end
        end
    elseif k == Kind.ClassStaticBlockDeclaration then
        local staticBlock = node:AsClassStaticBlockDeclaration()
        collector:collect(staticBlock.body)
    else
        debug.AssertNever(node)
    end

    return collector.callSites
end

function LanguageService:convertCallSiteGroupToOutgoingCall(program, entries)
    local fromRanges = {}
    for _, entry in ipairs(entries) do
        local sourceFile = entry.sourceFile:AsSourceFile()
        local lspRange, fidelity = self.converters:ToLSPRangeForFeature(sourceFile, entry.textRange, spanmap.Feature.CallHierarchy)
        if not spanmap.Fidelity_IsNone(fidelity) then
            fromRanges[#fromRanges + 1] = lspRange
        end
    end
    local to = self:createCallHierarchyItem(program, entries[1].declaration)
    if to == nil or #fromRanges == 0 then
        return nil
    end

    core.SortFunc(fromRanges, lsproto.CompareRanges)

    return {
        to = to,
        fromRanges = fromRanges,
    }
end

-- Gets the call sites that call out of the provided call hierarchy declaration.
function LanguageService:getOutgoingCalls(program, declaration)
    if (declaration.flags & NodeFlags.Ambient) ~= 0 or ast.IsMethodSignatureDeclaration(declaration) then
        return nil
    end

    local c, done = program:GetTypeChecker(nil)

    local callSites = ls.collectCallSites(program, c, declaration)

    if #callSites == 0 then
        done()
        return nil
    end

    local result = nil
    for _, sites in ipairs(groupCallSites(callSites)) do
        local outgoingCall = self:convertCallSiteGroupToOutgoingCall(program, sites)
        if outgoingCall ~= nil then
            result = core.Append(result, outgoingCall)
        end
    end

    core.SortFunc(result, function(a, b)
        local uriComp = stringsCompare(tostring(a.to.uri), tostring(b.to.uri))
        if uriComp ~= 0 then
            return uriComp
        end
        if #a.fromRanges == 0 or #b.fromRanges == 0 then
            return 0
        end
        return lsproto.CompareRanges(a.fromRanges[1], b.fromRanges[1])
    end)

    done()
    return result
end

function LanguageService:ProvidePrepareCallHierarchy(ctx, documentURI, pos)
    local program, file = self:getProgramAndFile(documentURI)
    local declarations = self:callHierarchyDeclarations(file, pos, program, false)
    local items = nil
    local seen = collections.NewSet()
    for _, declaration in ipairs(declarations or {}) do
        local item = self:createCallHierarchyItem(program, declaration)
        if item ~= nil then
            if seen:AddIfAbsent(locationKey(item.uri, item.selectionRange)) then
                items = core.Append(items, item)
            end
        end
    end

    if items == nil then
        return {}, nil
    end
    return { callHierarchyItems = items }, nil
end

function LanguageService:ProvideCallHierarchyIncomingCalls(ctx, item, orchestrator)
    local program = self:GetProgram()
    local fileName = lsproto.DocumentUri_FileName(item.uri)
    local file = program:GetSourceFile(fileName)
    if file == nil then
        return {}, nil
    end

    local declarations = self:callHierarchyDeclarations(file, item.selectionRange.start, program, true)
    local calls = {}
    local seen = {}
    for _, declaration in ipairs(declarations or {}) do
        local response, err = self:getIncomingCalls(ctx, program, declaration, orchestrator)
        if err ~= nil then
            return {}, err
        end
        if response.callHierarchyIncomingCalls ~= nil then
            for _, call in ipairs(response.callHierarchyIncomingCalls) do
                local key = locationKey(call.from.uri, call.from.selectionRange)
                local existing = seen[key]
                if existing ~= nil then
                    for _, fromRange in ipairs(call.fromRanges) do
                        if not core.Some(existing.fromRanges, function(r) return rangeEqual(r, fromRange) end) then
                            existing.fromRanges[#existing.fromRanges + 1] = fromRange
                        end
                    end
                else
                    seen[key] = call
                    calls[#calls + 1] = call
                end
            end
        end
    end
    if #calls == 0 then
        return {}, nil
    end
    return { callHierarchyIncomingCalls = calls }, nil
end

function LanguageService:ProvideCallHierarchyOutgoingCalls(ctx, item)
    local program = self:GetProgram()
    local fileName = lsproto.DocumentUri_FileName(item.uri)
    local file = program:GetSourceFile(fileName)
    if file == nil then
        return {}, nil
    end

    local declarations = self:callHierarchyDeclarations(file, item.selectionRange.start, program, true)
    local calls = {}
    local seen = {}
    for _, declaration in ipairs(declarations or {}) do
        for _, call in ipairs(self:getOutgoingCalls(program, declaration) or {}) do
            local key = locationKey(call.to.uri, call.to.selectionRange)
            local existing = seen[key]
            if existing ~= nil then
                for _, fromRange in ipairs(call.fromRanges) do
                    if not core.Some(existing.fromRanges, function(r) return rangeEqual(r, fromRange) end) then
                        existing.fromRanges[#existing.fromRanges + 1] = fromRange
                    end
                end
            else
                seen[key] = call
                calls[#calls + 1] = call
            end
        end
    end
    if #calls == 0 then
        return {}, nil
    end
    return { callHierarchyOutgoingCalls = calls }, nil
end

function LanguageService:callHierarchyDeclarations(file, pos, program, allowSourceFile)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, pos, spanmap.Feature.CallHierarchy)
    local declarations = nil
    local seen = collections.NewSet()
    for _, mapped in ipairs(positions or {}) do
        if not spanmap.Fidelity_IsSingleSegment(mapped.fidelity) then
            goto continue
        end
        do
            local script = mapped.script
            local p = mapped.position
            local node = script:AsNode()
            if p ~= 0 then
                node = astnav.GetTouchingPropertyName(script, p)
            end
            if node == nil or not allowSourceFile and node.kind == Kind.SourceFile then
                goto continue
            end
            local declaration = ls.resolveCallHierarchyDeclaration(program, node)
            if declaration ~= nil then
                if declaration.kind ~= nil then
                    if seen:AddIfAbsent(declaration) then
                        declarations = core.Append(declarations, declaration)
                    end
                else
                    for _, d in ipairs(declaration) do
                        if seen:AddIfAbsent(d) then
                            declarations = core.Append(declarations, d)
                        end
                    end
                end
            end
        end
        ::continue::
    end
    return declarations
end
