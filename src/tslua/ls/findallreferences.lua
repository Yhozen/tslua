local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local binder = require("tslua.binder")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local CheckFlags = ast.CheckFlags
local SemanticMeaning = ast.SemanticMeaning
local ImpExpKind = ls.ImpExpKind
local ExportKind = ls.ExportKind
local ModuleReferenceKind = ls.ModuleReferenceKind

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

local function cmpCompare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

local function slicesIndex(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end

local function slicesContains(xs, v)
    return slicesIndex(xs, v) >= 0
end

-- === types for settings ===
-- referenceUse (unexported Go enum)
ls.referenceUseNone = 0
ls.referenceUseOther = 1
ls.referenceUseReferences = 2
ls.referenceUseRename = 3

-- refOptions: { findInStrings, findInComments, use, implementations, useAliasesForRename }
-- useAliasesForRename is renamed from providePrefixAndSuffixTextForRename. default: true
function ls.newRefOptions(fields)
    local o = {
        findInStrings = false,
        findInComments = false,
        use = ls.referenceUseNone,
        implementations = false,
        useAliasesForRename = false,
    }
    for k, v in pairs(fields or {}) do
        o[k] = v
    end
    return o
end

-- === types for results ===

-- refInfo: { file, fileName, reference, unverified }

local SymbolAndEntries = {}
SymbolAndEntries.__index = SymbolAndEntries
ls.SymbolAndEntries = SymbolAndEntries

function ls.NewSymbolAndEntries(kind, node, symbol, references)
    return setmetatable({
        definition = {
            kind = kind,
            node = node,
            symbol = symbol,
        },
        references = references,
    }, SymbolAndEntries)
end

-- DefinitionKind (constants are unexported in Go)
ls.definitionKindSymbol = 0
ls.definitionKindLabel = 1
ls.definitionKindKeyword = 2
ls.definitionKindThis = 3
ls.definitionKindString = 4
ls.definitionKindTripleSlashReference = 5

-- Definition: { kind, symbol, node, tripleSlashFileRef }
-- tripleSlashDefinition: { reference, file }

-- entryKind (unexported Go enum)
ls.entryKindNone = 0
ls.entryKindRange = 1
ls.entryKindNode = 2
ls.entryKindStringLiteral = 3
ls.entryKindSearchedLocalFoundProperty = 4
ls.entryKindSearchedPropertyFoundLocal = 5

-- ReferenceEntry: { kind, node, context, sourceFile, textRange, lspRange, unmappable }
-- context is !!! ContextWithStartAndEndNode, optional
local ReferenceEntry = {}
ReferenceEntry.__index = ReferenceEntry
ls.ReferenceEntry = ReferenceEntry

function ls.newReferenceEntry(fields)
    local e = setmetatable({
        kind = ls.entryKindNone,
        unmappable = false,
    }, ReferenceEntry)
    for k, v in pairs(fields or {}) do
        e[k] = v
    end
    return e
end

-- Node returns the AST node for this reference entry.
function ReferenceEntry:Node()
    return self.node
end

-- IsNodeEntry returns true if this is a node-backed reference entry.
function ReferenceEntry:IsNodeEntry()
    return self.node ~= nil
end

-- References returns the reference entries for this symbol.
function SymbolAndEntries:References()
    return self.references
end

-- DefinitionNode returns the defining AST node for this symbol, if any.
function SymbolAndEntries:DefinitionNode()
    if self.definition == nil then
        return nil
    end
    if self.definition.node ~= nil then
        return self.definition.node
    end
    if self.definition.symbol ~= nil and core.Len(self.definition.symbol.declarations) > 0 then
        return self.definition.symbol.declarations[1]
    end
    return nil
end

function SymbolAndEntries:DefinitionSymbol()
    if self.definition == nil then
        return nil
    end
    return self.definition.symbol
end

function SymbolAndEntries:canUseDefinitionSymbol()
    if self.definition == nil then
        return false
    end

    local k = self.definition.kind
    if k == ls.definitionKindSymbol or k == ls.definitionKindThis then
        return self.definition.symbol ~= nil
    elseif k == ls.definitionKindTripleSlashReference then
        -- !!! TODO : need to find file reference instead?
        -- May need to return true to indicate this to be file search instead and might need to do for import stuff as well
        -- For now
        return false
    else
        return false
    end
end

local function newSymbolAndEntries(definition, references)
    return setmetatable({ definition = definition, references = references }, SymbolAndEntries)
end

function LanguageService:getRangeOfEntry(entry)
    return self:resolveEntry(entry).lspRange.range
end

function LanguageService:getRangeOfEntryForFeature(entry, feature)
    local location, ok = self:getLocationOfEntryForFeature(entry, feature)
    return location.range, ok
end

function LanguageService:getFileNameOfEntry(entry)
    return self:resolveEntry(entry).lspRange.uri
end

function LanguageService:getLocationOfEntry(entry)
    local resolved = self:resolveEntry(entry)
    return resolved.lspRange, not resolved.unmappable
end

function LanguageService:getLocationOfEntryForFeature(entry, feature)
    self:resolveEntrySource(entry)
    local location, fidelity = self:sourceFileRangeToLSPLocationForFeature(entry.sourceFile, entry.textRange, feature)
    return location, spanmap.Fidelity_IsSingleSegment(fidelity)
end

function LanguageService:resolveEntrySource(entry)
    if entry.sourceFile == nil then
        debug.Assert(entry.node ~= nil, "reference entry must have a node or source file")
        entry.sourceFile = ast.GetSourceFileOfNode(entry.node)
    end
    if entry.textRange == nil then
        entry.textRange = ls.getRangeOfNode(entry.node, entry.sourceFile, nil --[[endNode]])
    end
end

function LanguageService:resolveEntry(entry)
    self:resolveEntrySource(entry)
    if entry.lspRange == nil then
        local location, fidelity = self:sourceFileRangeToLSPLocation(entry.sourceFile, entry.textRange)
        entry.lspRange = location
        entry.unmappable = not spanmap.Fidelity_IsSingleSegment(fidelity)
    end
    return entry
end

function ls.newNodeEntryWithKind(node, kind)
    local e = ls.newNodeEntry(node)
    e.kind = kind
    return e
end

function ls.newNodeEntry(node)
    -- creates nodeEntry with `kind == entryKindNode`
    return ls.newReferenceEntry({
        kind = ls.entryKindNode,
        node = core.OrElse(node:Name(), node),
        context = ls.getContextNodeForNodeEntry(node),
    })
end

function ls.getContextNodeForNodeEntry(node)
    if ast.IsDeclaration(node) then
        return ls.getContextNode(node)
    end

    if node.parent == nil then
        return nil
    end

    if not ast.IsDeclaration(node.parent) and not ast.IsExportAssignment(node.parent) then
        -- Special property assignment in javascript
        if ast.IsInJSFile(node) then
            -- !!! jsdoc: check if branch still needed
            local binaryExpression
            if ast.IsBinaryExpression(node.parent) then
                binaryExpression = node.parent
            elseif ast.IsAccessExpression(node.parent) and ast.IsBinaryExpression(node.parent.parent) and node.parent.parent:AsBinaryExpression().left == node.parent then
                binaryExpression = node.parent.parent
            end
            if binaryExpression ~= nil and ast.GetAssignmentDeclarationKind(binaryExpression) ~= ast.JSDeclarationKind.None then
                return ls.getContextNode(binaryExpression)
            end
        end

        -- Jsx Tags
        local pk = node.parent.kind
        if pk == Kind.JsxOpeningElement or pk == Kind.JsxClosingElement then
            return node.parent.parent
        elseif pk == Kind.JsxSelfClosingElement or pk == Kind.LabeledStatement or pk == Kind.BreakStatement or pk == Kind.ContinueStatement then
            return node.parent
        elseif pk == Kind.StringLiteral or pk == Kind.NoSubstitutionTemplateLiteral then
            local validImport = ast.TryGetImportFromModuleSpecifier(node)
            if validImport ~= nil then
                local declOrStatement = ast.FindAncestor(validImport, function(_)
                    return ast.IsDeclaration(node) or ast.IsStatement(node) or ast.IsJSDocTag(node)
                end)
                if ast.IsDeclaration(declOrStatement) then
                    return ls.getContextNode(declOrStatement)
                end
                return declOrStatement
            end
        end

        -- Handle computed property name
        local propertyName = ast.FindAncestor(node, ast.IsComputedPropertyName)
        if propertyName ~= nil then
            return ls.getContextNode(propertyName.parent)
        end
        return nil
    end

    if node.parent:Name() == node or -- node is name of declaration, use parent
        node.parent.kind == Kind.Constructor or
        node.parent.kind == Kind.ExportAssignment or
        -- Property name of the import export specifier or binding pattern, use parent
        ((ast.IsImportOrExportSpecifier(node.parent) or node.parent.kind == Kind.BindingElement) and node.parent:PropertyName() == node) or
        -- Is default export
        (node.kind == Kind.DefaultKeyword and ast.HasSyntacticModifier(node.parent, ModifierFlags.ExportDefault)) then
        return ls.getContextNode(node.parent)
    end

    return nil
end

function ls.getContextNode(node)
    if node == nil then
        return nil
    end
    local k = node.kind
    if k == Kind.VariableDeclaration then
        if not ast.IsVariableDeclarationList(node.parent) or #node.parent:AsVariableDeclarationList().declarations.nodes ~= 1 then
            return node
        elseif ast.IsVariableStatement(node.parent.parent) then
            return node.parent.parent
        elseif ast.IsForInOrOfStatement(node.parent.parent) then
            return ls.getContextNode(node.parent.parent)
        end
        return node.parent
    elseif k == Kind.BindingElement then
        return ls.getContextNode(node.parent.parent)
    elseif k == Kind.ImportSpecifier then
        return node.parent.parent.parent
    elseif k == Kind.ExportSpecifier or k == Kind.NamespaceImport then
        return node.parent.parent
    elseif k == Kind.ImportClause or k == Kind.NamespaceExport then
        return node.parent
    elseif k == Kind.BinaryExpression then
        return core.IfElse(node.parent.kind == Kind.ExpressionStatement, node.parent, node)
    elseif k == Kind.ForOfStatement or k == Kind.ForInStatement then
        -- !!! not implemented
        return nil
    elseif k == Kind.PropertyAssignment or k == Kind.ShorthandPropertyAssignment then
        if ast.IsArrayLiteralOrObjectLiteralDestructuringPattern(node.parent) then
            return ls.getContextNode(ast.FindAncestor(node.parent, function(n)
                return n.kind == Kind.BinaryExpression or ast.IsForInOrOfStatement(n)
            end))
        end
        return node
    elseif k == Kind.SwitchStatement then
        -- !!! not implemented
        return nil
    else
        return node
    end
end

function ls.getRangeOfNode(node, sourceFile, endNode)
    if sourceFile == nil then
        sourceFile = ast.GetSourceFileOfNode(node)
    end
    local start = scanner.GetTokenPosOfNode(node, sourceFile, false --[[includeJsDoc]])
    local end_ = core.IfElse(endNode ~= nil, endNode, node):End()
    if ast.IsStringLiteralLike(node) and (end_ - start) > 2 then
        if endNode ~= nil then
            error("endNode is not nil for stringLiteralLike", 0)
        end
        start = start + 1
        end_ = end_ - 1
    end
    if endNode ~= nil and endNode.kind == Kind.CaseBlock then
        end_ = endNode:Pos()
    end
    return core.NewTextRange(start, end_)
end

function ls.isValidReferencePosition(node, searchSymbolName)
    local k = node.kind
    if k == Kind.PrivateIdentifier then
        -- !!!
        -- if (isJSDocMemberName(node.Parent)) {
        -- 	return true;
        -- }
        return #node:Text() == #searchSymbolName
    elseif k == Kind.Identifier then
        return #node:Text() == #searchSymbolName
    elseif k == Kind.NoSubstitutionTemplateLiteral or k == Kind.StringLiteral then
        return #node:Text() == #searchSymbolName and (ls.isLiteralNameOfPropertyDeclarationOrIndexAccess(node) or
            ls.isNameOfModuleDeclaration(node) or
            ls.isExpressionOfExternalModuleImportEqualsDeclaration(node) or
            ast.IsCallExpression(node.parent) and ast.IsBindableObjectDefinePropertyCall(node.parent) and node.parent:Arguments()[2] == node or
            ast.IsImportOrExportSpecifier(node.parent))
    elseif k == Kind.NumericLiteral then
        return ls.isLiteralNameOfPropertyDeclarationOrIndexAccess(node) and #node:Text() == #searchSymbolName
    elseif k == Kind.DefaultKeyword then
        return #"default" == #searchSymbolName
    end
    return false
end

function ls.isForRenameWithPrefixAndSuffixText(options)
    return options.use == ls.referenceUseRename and options.useAliasesForRename
end

function ls.skipPastExportOrImportSpecifierOrUnion(symbol, node, c, useLocalSymbolForExportSpecifier)
    if node == nil then
        return nil
    end
    local parent = node.parent
    if parent.kind == Kind.ExportSpecifier and useLocalSymbolForExportSpecifier then
        return ls.getLocalSymbolForExportSpecifier(node, symbol, parent:AsExportSpecifier(), c)
    end
    -- If the symbol is declared as part of a declaration like `{ type: "a" } | { type: "b" }`, use the property on the union type to get more references.
    return core.FirstNonNil(symbol.declarations, function(decl)
        if decl.parent == nil then
            -- Ignore UMD module and global merge and CJS module end exports symbols
            if symbol.flags & (SymbolFlags.Transient | SymbolFlags.ModuleExports) ~= 0 then
                return nil
            end
            -- Assertions for GH#21814. We should be handling SourceFile symbols in `getReferencedSymbolsForModule` instead of getting here.
            error(string.format("Unexpected symbol at %s: %s", ast.Kind_String(node.kind), symbol.name), 0)
        end
        if decl.parent.kind == Kind.TypeLiteral and decl.parent.parent.kind == Kind.UnionType then
            return c:GetPropertyOfType(c:GetTypeFromTypeNode(decl.parent.parent), symbol.name)
        end
        return nil
    end)
end

function ls.getSymbolScope(symbol)
    -- If this is the symbol of a named function expression or named class expression,
    -- then named references are limited to its own scope.
    local valueDeclaration = symbol.valueDeclaration
    if valueDeclaration ~= nil and (valueDeclaration.kind == Kind.FunctionExpression or valueDeclaration.kind == Kind.ClassExpression) then
        return valueDeclaration
    end

    if core.Len(symbol.declarations) == 0 then
        return nil
    end

    local declarations = symbol.declarations
    -- If this is private property or method, the scope is the containing class
    if symbol.flags & (SymbolFlags.Property | SymbolFlags.Method) ~= 0 then
        local privateDeclaration = core.Find(declarations, function(d)
            return ast.HasModifier(d, ModifierFlags.Private) or ast.IsPrivateIdentifierClassElementDeclaration(d)
        end)
        if privateDeclaration ~= nil then
            return ast.FindAncestorKind(privateDeclaration, Kind.ClassDeclaration)
        end
        -- Else this is a public property and could be accessed from anywhere.
        return nil
    end

    -- If symbol is of object binding pattern element without property name we would want to
    -- look for property too and that could be anywhere
    if core.Some(declarations, ls.isObjectBindingElementWithoutPropertyName) then
        return nil
    end

    --[[
        If the symbol has a parent, it's globally visible unless:
        - It's a private property (handled above).
        - It's a type parameter.
        - The parent is an external module: then we should only search in the module (and recurse on the export later).
        - But if the parent has `export as namespace`, the symbol is globally visible through that namespace.
    ]]
    local exposedByParent = symbol.parent ~= nil and symbol.flags & SymbolFlags.TypeParameter == 0
    if exposedByParent and not (checker.IsExternalModuleSymbol(symbol.parent) and not ls.isSourceFileWithGlobalExports(symbol.parent.valueDeclaration)) then
        return nil
    end

    local scope = nil
    for _, declaration in ipairs(declarations) do
        local container = ls.getContainerNode(declaration)
        if scope ~= nil and scope ~= container then
            -- Different declarations have different containers, bail out
            return nil
        end

        if container == nil or (container.kind == Kind.SourceFile and not ast.IsExternalOrCommonJSModule(container:AsSourceFile())) then
            -- This is a global variable and not an external module, any declaration defined
            -- within this scope is visible outside the file
            return nil
        end

        scope = container
    end

    -- If symbol.parent, this means we are in an export of an external module. (Otherwise we would have returned `undefined` above.)
    -- For an export of a module, we may be in a declaration file, and it may be accessed elsewhere. E.g.:
    --     declare module "a" { export type T = number; }
    --     declare module "b" { import { T } from "a"; export const x: T; }
    -- So we must search the whole source file. (Because we will mark the source file as seen, we we won't return to it when searching for imports.)
    if exposedByParent then
        return ast.GetSourceFileOfNode(scope):AsNode()
    end
    return scope -- TODO: GH#18217
end

-- === functions on (*ls) ===

-- position: { uri, pos } implementing lsproto.HasTextDocumentPosition
local position = {}
position.__index = position
ls.position = position

function ls.newPosition(uri, pos)
    return setmetatable({ uri = uri, pos = pos }, position)
end

function position:TextDocumentURI() return self.uri end
function position:TextDocumentPosition() return self.pos end

-- nonLocalDefinition embeds position; getSourcePosition / getGeneratedPosition are function fields
-- (Go `GetSourcePosition func() lsproto.HasTextDocumentPosition`), called as `d.getSourcePosition()`.
local nonLocalDefinition = setmetatable({}, { __index = position })
nonLocalDefinition.__index = nonLocalDefinition
ls.nonLocalDefinition = nonLocalDefinition

function ls.getFileAndStartPosFromDeclaration(declaration)
    local file = ast.GetSourceFileOfNode(declaration)
    local name = core.OrElse(ast.GetNameOfDeclaration(declaration), declaration)
    local textRange = ls.getRangeOfNode(name, file, nil --[[endNode]])

    return file, textRange:Pos()
end

-- Go sync.OnceValue
local function onceValue(f)
    local done = false
    local value = nil
    return function()
        if not done then
            done = true
            value = f()
        end
        return value
    end
end

function LanguageService:getNonLocalDefinition(ctx, entry)
    if not entry:canUseDefinitionSymbol() then
        return nil
    end

    local program = self:GetProgram()
    local c, done = program:GetTypeChecker(ctx)
    local emitResolver = c:GetEmitResolver()
    for _, d in ipairs(entry.definition.symbol.declarations or {}) do
        if ls.isDefinitionVisible(emitResolver, d) then
            local file, startPos = ls.getFileAndStartPosFromDeclaration(d)
            local fileName = file:FileName()
            local lspPosition, fidelity = self.converters:ToLSPPosition(file, startPos)
            if spanmap.Fidelity_IsNone(fidelity) then
                goto continue
            end
            do
                local result = setmetatable({
                    uri = lsconv.FileNameToDocumentURI(fileName),
                    pos = lspPosition,
                    getSourcePosition = onceValue(function()
                        local mapped = self:tryGetSourcePosition(fileName, startPos)
                        if mapped ~= nil then
                            local mappedPosition, mappedFidelity = self.converters:ToLSPPosition(self:getScript(mapped.fileName), mapped.pos)
                            if spanmap.Fidelity_IsNone(mappedFidelity) then
                                return nil
                            end
                            return ls.newPosition(lsconv.FileNameToDocumentURI(mapped.fileName), mappedPosition)
                        end
                        return nil
                    end),
                    getGeneratedPosition = onceValue(function()
                        local mapped = self:tryGetGeneratedPosition(fileName, startPos)
                        if mapped ~= nil then
                            local mappedPosition, mappedFidelity = self.converters:ToLSPPosition(self:getScript(mapped.fileName), mapped.pos)
                            if spanmap.Fidelity_IsNone(mappedFidelity) then
                                return nil
                            end
                            return ls.newPosition(lsconv.FileNameToDocumentURI(mapped.fileName), mappedPosition)
                        end
                        return nil
                    end),
                }, nonLocalDefinition)
                done()
                return result
            end
        end
        ::continue::
    end
    done()
    return nil
end

-- This is special handling to determine if we should load up more projects and find location in other projects
-- By default arrows (and such other ast kinds) are not visible as declaration emitter doesnt need them
-- But we want to handle them specially so that they are visible if their parent is visible
function ls.isDefinitionVisible(emitResolver, declaration)
    if emitResolver:IsDeclarationVisible(declaration) then
        return true
    end
    if declaration.parent == nil then
        return false
    end

    -- Variable initializers are visible if variable is visible
    if ast.HasInitializer(declaration.parent) and declaration.parent:Initializer() == declaration then
        return ls.isDefinitionVisible(emitResolver, declaration.parent)
    end

    -- Handle some exceptions here like arrow function, members of class and object literal expression which are technically not visible but we want the definition to be determined by its parent
    local k = declaration.kind
    if k == Kind.PropertyDeclaration or
        k == Kind.GetAccessor or
        k == Kind.SetAccessor or
        k == Kind.MethodDeclaration then
        -- Private/protected properties/methods are not visible
        if ast.HasModifier(declaration, ModifierFlags.Private) or ast.IsPrivateIdentifier(declaration:Name()) then
            return false
        end
        -- Public properties/methods are visible if its parents are visible, so:
        -- falls through
        return ls.isDefinitionVisible(emitResolver, declaration.parent)
    elseif k == Kind.Constructor or
        k == Kind.PropertyAssignment or
        k == Kind.ShorthandPropertyAssignment or
        k == Kind.ObjectLiteralExpression or
        k == Kind.ClassExpression or
        k == Kind.ArrowFunction or
        k == Kind.FunctionExpression then
        return ls.isDefinitionVisible(emitResolver, declaration.parent)
    else
        return false
    end
end

function LanguageService:forEachOriginalDefinitionLocation(ctx, entry, cb)
    if not entry:canUseDefinitionSymbol() then
        return
    end

    local program = self:GetProgram()
    for _, d in ipairs(entry.definition.symbol.declarations or {}) do
        local file, startPos = ls.getFileAndStartPosFromDeclaration(d)
        local fileName = file:FileName()
        if tspath.IsDeclarationFileName(fileName) then
            -- Map to ts position
            local mapped = self:tryGetSourcePosition(file:FileName(), startPos)
            if mapped ~= nil then
                local lspPosition, fidelity = self.converters:ToLSPPosition(self:getScript(mapped.fileName), mapped.pos)
                if not spanmap.Fidelity_IsNone(fidelity) then
                    cb(lsconv.FileNameToDocumentURI(mapped.fileName), lspPosition)
                end
            end
        elseif program:IsSourceFromProjectReference(self:toPath(fileName)) then
            local lspPosition, fidelity = self.converters:ToLSPPosition(file, startPos)
            if not spanmap.Fidelity_IsNone(fidelity) then
                cb(lsconv.FileNameToDocumentURI(fileName), lspPosition)
            end
        end
    end
end

-- symbolEntryTransformOptions: { requireLocationsResult, dropOriginNodes }
--   requireLocationsResult: Force the result to be Location objects.
--   dropOriginNodes: Omit node(s) containing the original position.
function ls.newSymbolEntryTransformOptions(requireLocationsResult, dropOriginNodes)
    return { requireLocationsResult = requireLocationsResult or false, dropOriginNodes = dropOriginNodes or false }
end

-- SymbolAndEntriesData: { originalNode, symbolsAndEntries, position }
local function newSymbolAndEntriesData(originalNode, symbolsAndEntries, pos)
    return { originalNode = originalNode, symbolsAndEntries = symbolsAndEntries, position = pos or 0 }
end

function LanguageService:provideSymbolsAndEntries(ctx, uri, documentPosition, isRename, implementations)
    -- `findReferencedSymbols` except only computes the information needed to return reference locations
    local program, sourceFile = self:getProgramAndFile(uri)
    local feature = spanmap.Feature.References
    if implementations then
        feature = spanmap.Feature.Implementation
    elseif isRename then
        feature = spanmap.Feature.Rename
    end
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, documentPosition, feature)
    if core.Len(positions) == 0 then
        return newSymbolAndEntriesData(), false
    end
    local combined = newSymbolAndEntriesData()
    local ok = false
    for _, mapped in ipairs(positions) do
        if not spanmap.Fidelity_IsSingleSegment(mapped.fidelity) then
            goto continue
        end
        do
            local data, found = self:provideSymbolsAndEntriesAtPosition(ctx, program, mapped.script, mapped.position, isRename, implementations)
            if not found then
                goto continue
            end
            if not ok then
                combined.originalNode = data.originalNode
                combined.position = data.position
                ok = true
            end
            combined.symbolsAndEntries = core.AppendAll(combined.symbolsAndEntries, data.symbolsAndEntries)
        end
        ::continue::
    end
    return combined, ok
end

function LanguageService:provideSymbolsAndEntriesAtPosition(ctx, program, sourceFile, pos, isRename, implementations)
    local node = astnav.GetTouchingPropertyName(sourceFile, pos)
    if isRename then
        -- Adjust modifier/keyword nodes to the declaration name, matching Strada's findRenameLocations.
        node = ls.getAdjustedLocation(node, true --[[forRename]], sourceFile)
    end
    if isRename and not ls.nodeIsEligibleForRename(node) or implementations and ast.IsSourceFile(node) then
        return newSymbolAndEntriesData(node, nil, pos), false
    end

    local entries = self:getSymbolAndEntries(ctx, pos, node, program, isRename, implementations)
    if not implementations then
        return newSymbolAndEntriesData(node, entries, pos), true
    end

    local implementationEntries = nil
    local queue = {}
    local queueHead = 1
    local seenNodes = collections.NewSet()
    local seenDefinitions = collections.NewSet()
    local function addToQueue(symbolAndEntries)
        for _, s in ipairs(symbolAndEntries or {}) do
            local newReferences = nil
            for _, ref in ipairs(s.references or {}) do
                -- Go adds nil nodes too (a nil key); Lua tables cannot hold a nil key.
                local key = ref.node
                if key == nil then
                    key = seenNodes
                end
                if seenNodes:AddIfAbsent(key) then
                    queue[#queue + 1] = ref
                    newReferences = core.Append(newReferences, ref)
                end
            end
            local defKey = s.definition ~= nil and s.definition.symbol or seenDefinitions
            if core.Len(newReferences) > 0 or s.definition == nil or seenDefinitions:AddIfAbsent(defKey) then
                implementationEntries = core.Append(implementationEntries, newSymbolAndEntries(s.definition, newReferences))
            end
        end
    end

    addToQueue(entries)
    while queueHead <= #queue do
        if ctxErr(ctx) then
            return newSymbolAndEntriesData(), false
        end

        local entry = queue[queueHead]
        queueHead = queueHead + 1
        if entry.node ~= nil then
            addToQueue(self:getSymbolAndEntries(ctx, entry.node:Pos(), entry.node, program, isRename, implementations))
        end
    end
    return newSymbolAndEntriesData(node, implementationEntries, pos), true
end

function LanguageService:getSymbolAndEntries(ctx, pos, node, program, isRename, implementations)
    local options = ls.newRefOptions()
    if not isRename then
        options.use = ls.referenceUseReferences
        if implementations then
            options.implementations = true
        end
    else
        options.use = ls.referenceUseRename
        options.useAliasesForRename = core.Tristate_IsTrueOrUnknown(self:UserPreferences().useAliasesForRename)
    end
    return self:getReferencedSymbolsForNode(ctx, pos, node, program, program:GetSourceFiles(), options)
end

function LanguageService:ProvideReferences(ctx, params, orchestrator)
    return ls.handleCrossProject(
        self,
        ctx,
        params,
        orchestrator,
        LanguageService.symbolAndEntriesToReferences,
        ls.combineReferences,
        false, --[[isRename]]
        false, --[[implementations]]
        ls.newSymbolEntryTransformOptions()
    )
end

function LanguageService:ProvideVSReferences(ctx, params, orchestrator)
    return ls.handleCrossProject(
        self,
        ctx,
        params,
        orchestrator,
        LanguageService.symbolAndEntriesToVSReferences,
        ls.combineVSReferences,
        false, --[[isRename]]
        false, --[[implementations]]
        ls.newSymbolEntryTransformOptions()
    )
end

function LanguageService:symbolAndEntriesToReferences(ctx, params, data, options)
    -- `findReferencedSymbols` except only computes the information needed to return reference locations
    local locations = nil
    local seenLocations = collections.NewSet()
    for _, symbol in ipairs(data.symbolsAndEntries or {}) do
        local symbolLocations = self:convertSymbolAndEntriesToLocations(symbol, params.context.includeDeclaration, spanmap.Feature.References)
        locations = ls.combineLocationArray(locations, symbolLocations, seenLocations)
    end
    return { locations = locations or {} }, nil
end

function LanguageService:symbolAndEntriesToVSReferences(ctx, params, data, options)
    local caps = lsproto.GetClientCapabilities(ctx)
    local vsCapability = caps.vsSupportsVisualStudioExtensions
    local items = {}
    local id = 0
    local projectName = tostring(self.projectPath or "")

    for _, s in ipairs(data.symbolsAndEntries or {}) do
        if s.definition == nil then
            goto continue
        end

        do
            -- Convert definition to info
            local defInfo = self:definitionToReferencedSymbolDefinitionInfo(ctx, s.definition, data.originalNode, vsCapability)
            if defInfo == nil then
                goto continue
            end

            -- Create the definition item
            local definitionId = id
            local defItem = {
                vsId = definitionId,
                vsLocation = defInfo.location,
                vsDefinitionText = defInfo.displayText,
                vsKind = { lsproto.VSReferenceKind.Unknown },
                vsProjectName = projectName,
                vsContainingType = "",
            }
            items[#items + 1] = defItem
            id = id + 1

            -- Create reference items grouped under the definition
            for _, ref in ipairs(s.references or {}) do
                -- Skip the declaration itself (already represented by the definition item)
                if s.definition.symbol ~= nil and ls.isDeclarationOfSymbol(ref.node, s.definition.symbol) then
                    goto continueRef
                end

                do
                    local refLocation, ok = self:getLocationOfEntry(ref)
                    if not ok then
                        goto continueRef
                    end

                    -- Determine read/write kind
                    local kind = lsproto.VSReferenceKind.Read
                    if ref.kind ~= ls.entryKindRange and ref.node ~= nil and ast.IsWriteAccessForReference(ref.node) then
                        kind = lsproto.VSReferenceKind.Write
                    end

                    local refItem = {
                        vsId = id,
                        vsDefinitionId = definitionId,
                        vsLocation = refLocation,
                        vsKind = { kind },
                        vsProjectName = projectName,
                    }
                    items[#items + 1] = refItem
                    id = id + 1
                end
                ::continueRef::
            end
        end
        ::continue::
    end

    return { vsReferenceItems = items }, nil
end

-- referencedSymbolDefinitionInfo holds the computed info for a definition: { node, location, displayText }

local function textElement(text, classificationTypeName)
    return { runs = { { text = text, classificationTypeName = classificationTypeName } } }
end

-- definitionToReferencedSymbolDefinitionInfo converts a Definition to display info
function LanguageService:definitionToReferencedSymbolDefinitionInfo(ctx, def, originalNode, vsCapability)
    local k = def.kind
    if k == ls.definitionKindSymbol then
        local symbol = def.symbol
        if symbol == nil then
            return nil
        end
        -- Get display parts
        local element = self:getDefinitionKindAndDisplayParts(ctx, symbol, originalNode, vsCapability)

        -- Get the definition node
        local node
        if core.Len(symbol.declarations) > 0 then
            local decl = symbol.declarations[1]
            node = core.OrElse(decl:Name(), decl)
        else
            node = originalNode
        end

        local loc, ok = self:getLocationOfEntry(ls.newReferenceEntry({ kind = ls.entryKindNode, node = node }))
        if not ok then
            return nil
        end
        return {
            node = node,
            location = loc,
            displayText = element,
        }
    elseif k == ls.definitionKindLabel then
        local node = def.node
        if node == nil then
            return nil
        end
        local loc, ok = self:getLocationOfEntry(ls.newReferenceEntry({ kind = ls.entryKindNode, node = node }))
        if not ok then
            return nil
        end
        return {
            node = node,
            location = loc,
            displayText = textElement(node:Text(), lsproto.ClassificationTypeName.Text),
        }
    elseif k == ls.definitionKindKeyword then
        local node = def.node
        if node == nil then
            return nil
        end
        local name = scanner.TokenToString(node.kind)
        local loc, ok = self:getLocationOfEntry(ls.newReferenceEntry({ kind = ls.entryKindNode, node = node }))
        if not ok then
            return nil
        end
        return {
            node = node,
            location = loc,
            displayText = textElement(name, lsproto.ClassificationTypeName.Keyword),
        }
    elseif k == ls.definitionKindThis then
        local node = def.node
        if node == nil then
            return nil
        end
        local symbol = def.symbol
        if symbol == nil then
            return nil
        end
        local element = self:getDefinitionKindAndDisplayParts(ctx, symbol, node, vsCapability)
        local loc, ok = self:getLocationOfEntry(ls.newReferenceEntry({ kind = ls.entryKindNode, node = node }))
        if not ok then
            return nil
        end
        return {
            node = node,
            location = loc,
            displayText = element,
        }
    elseif k == ls.definitionKindString then
        local node = def.node
        if node == nil then
            return nil
        end
        local loc, ok = self:getLocationOfEntry(ls.newReferenceEntry({ kind = ls.entryKindNode, node = node }))
        if not ok then
            return nil
        end
        return {
            node = node,
            location = loc,
            displayText = textElement(node:Text(), lsproto.ClassificationTypeName.String),
        }
    elseif k == ls.definitionKindTripleSlashReference then
        if def.tripleSlashFileRef == nil or def.tripleSlashFileRef.file == nil then
            return nil
        end
        local node = def.tripleSlashFileRef.file:AsNode()
        local loc, ok = self:getLocationOfEntry(ls.newReferenceEntry({ kind = ls.entryKindNode, node = node }))
        if not ok then
            return nil
        end
        return {
            node = node,
            location = loc,
            displayText = textElement("\"" .. def.tripleSlashFileRef.reference.fileName .. "\"", lsproto.ClassificationTypeName.String),
        }
    else
        return nil
    end
end

-- getDefinitionKindAndDisplayParts returns the classified display text for a symbol definition.
function LanguageService:getDefinitionKindAndDisplayParts(ctx, symbol, originalNode, vsCapability)
    local program = self:GetProgram()
    local c, done = program:GetTypeChecker(ctx)

    local meaning = ls.getIntersectingMeaningFromDeclarations(originalNode, symbol, SemanticMeaning.All)

    local info = ls.getQuickInfoAndDeclarationAtLocation(c, symbol, originalNode, nil, vsCapability, meaning)

    local result
    if vsCapability then
        result = { runs = info.displayParts:GetRuns() }
    else
        -- Fallback: single unclassified run with the full text
        local text = info.displayParts:String()
        result = textElement(text, lsproto.ClassificationTypeName.Text)
    end
    done()
    return result
end

function LanguageService:ProvideImplementations(ctx, params, orchestrator)
    return self:provideImplementationsEx(ctx, params, ls.newSymbolEntryTransformOptions(), orchestrator)
end

function LanguageService:provideImplementationsEx(ctx, params, options, orchestrator)
    return ls.handleCrossProject(
        self,
        ctx,
        params,
        orchestrator,
        LanguageService.symbolAndEntriesToImplementations,
        ls.combineImplementations,
        false, --[[isRename]]
        true, --[[implementations]]
        options
    )
end

function LanguageService:symbolAndEntriesToImplementations(ctx, params, data, options)
    local seenNodes = collections.NewSet()
    local entries = nil
    for _, entry in ipairs(data.symbolsAndEntries or {}) do
        for _, ref in ipairs(entry.references or {}) do
            if seenNodes:AddIfAbsent(ref.node or seenNodes) and (not options.dropOriginNodes or not ref.node.loc:ContainsInclusive(data.position)) then
                entries = core.Append(entries, ref)
            end
        end
    end

    if not options.requireLocationsResult and lsproto.GetClientCapabilities(ctx).textDocument.implementation.linkSupport then
        local links = self:convertEntriesToLocationLinks(entries, spanmap.Feature.Implementation)
        return { definitionLinks = links }, nil
    end
    local locations = self:convertEntriesToLocations(entries, nil --[[definitionSymbol]], spanmap.Feature.Implementation)
    return { locations = locations }, nil
end

-- == functions for conversions ==
function LanguageService:convertSymbolAndEntriesToLocations(s, includeDeclarations, feature)
    local references = s.references

    -- !!! includeDeclarations
    if not includeDeclarations and s.definition ~= nil then
        references = core.Filter(references, function(entry)
            return not ls.isDeclarationOfSymbol(entry.node, s.definition.symbol)
        end)
    end

    local definitionSymbol = nil
    if includeDeclarations and s.definition ~= nil then
        definitionSymbol = s.definition.symbol
    end
    return self:convertEntriesToLocations(references, definitionSymbol, feature)
end

function ls.isDeclarationOfSymbol(node, target)
    if node == nil or target == nil then
        return false
    end

    local source = nil
    local decl = ast.GetDeclarationFromName(node)
    if decl ~= nil then
        source = decl
    elseif node.kind == Kind.DefaultKeyword then
        source = node.parent
    elseif ast.IsLiteralComputedPropertyDeclarationName(node) then
        source = node.parent.parent
    elseif node.kind == Kind.ConstructorKeyword and ast.IsConstructorDeclaration(node.parent) then
        source = node.parent.parent
    end

    -- !!!
    -- const commonjsSource = source && isBinaryExpression(source) ? source.left as unknown as Declaration : undefined;

    return source ~= nil and core.Some(target.declarations, function(d)
        return d == source
    end)
end

function LanguageService:convertEntriesToLocations(entries, definitionSymbol, feature)
    -- A synthesized declaration has no source span, but it still represents the symbol's definition in
    -- that file. Mirror go-to-definition's file-level fallback while continuing to omit synthesized uses.
    local concreteFiles = collections.NewSet()
    for _, entry in ipairs(entries or {}) do
        local location, ok = self:getLocationOfEntryForFeature(entry, feature)
        if ok then
            concreteFiles:Add(location.uri)
        end
    end

    local locations = {}
    for _, entry in ipairs(entries or {}) do
        local location, ok = self:getLocationOfEntryForFeature(entry, feature)
        if ok then
            locations[#locations + 1] = location
        elseif ls.isDeclarationOfSymbol(entry.node, definitionSymbol) and not concreteFiles:Has(location.uri) then
            location = { uri = location.uri, range = { start = { line = 0, character = 0 }, end_ = { line = 0, character = 0 } } }
            locations[#locations + 1] = location
            concreteFiles:Add(location.uri)
        end
    end
    return locations
end

function LanguageService:convertEntriesToLocationLinks(entries, feature)
    local links = {}
    for _, entry in ipairs(entries or {}) do
        -- Get the selection range (the actual reference)
        local loc, ok = self:getLocationOfEntryForFeature(entry, feature)
        if not ok then
            goto continue
        end
        do
            local targetSelectionRange = loc.range
            local targetRange = targetSelectionRange

            -- For entries with nodes, compute ranges directly from the node
            if entry.node ~= nil then
                -- Get the context range (broader scope including declaration context)
                local contextTextRange = ls.toContextRange(entry.textRange, entry.sourceFile, entry.context)
                if contextTextRange ~= nil then
                    local contextLocation, fidelity = self:sourceFileRangeToLSPLocationForFeature(entry.sourceFile, contextTextRange, feature)
                    if not spanmap.Fidelity_IsNone(fidelity) and contextLocation.uri == loc.uri then
                        targetRange = contextLocation.range
                    end
                end
            end

            links[#links + 1] = {
                targetUri = lsconv.FileNameToDocumentURI(entry.sourceFile:OriginalFileName()),
                targetRange = targetRange,
                targetSelectionRange = targetSelectionRange,
            }
        end
        ::continue::
    end
    return links
end

function LanguageService:mergeReferences(program, ...)
    local referencesToMerge = table.pack(...)
    local result = {}
    local function getSourceFileIndexOfEntry(entry)
        self:resolveEntrySource(entry)
        return slicesIndex(program:SourceFiles(), entry.sourceFile)
    end

    for i = 1, referencesToMerge.n do
        local references = referencesToMerge[i]
        if core.Len(references) == 0 then
            goto continue
        end
        if #result == 0 then
            result = references
            goto continue
        end
        for _, entry in ipairs(references) do
            if entry.definition == nil or entry.definition.kind ~= ls.definitionKindSymbol then
                result[#result + 1] = entry
                goto continueEntry
            end
            do
                local symbol = entry.definition.symbol
                local refIndex = core.FindIndex(result, function(ref)
                    return ref.definition ~= nil and
                        ref.definition.kind == ls.definitionKindSymbol and
                        ref.definition.symbol == symbol
                end)
                if refIndex == -1 then
                    result[#result + 1] = entry
                    goto continueEntry
                end

                local reference = result[refIndex + 1]
                local sortedRefs = core.AppendAll(core.Slice(reference.references), entry.references)
                core.SortStableFunc(sortedRefs, function(entry1, entry2)
                    local entry1File = getSourceFileIndexOfEntry(entry1)
                    local entry2File = getSourceFileIndexOfEntry(entry2)
                    if entry1File ~= entry2File then
                        return cmpCompare(entry1File, entry2File)
                    end

                    return lsproto.CompareRanges(self:getRangeOfEntry(entry1), self:getRangeOfEntry(entry2))
                end)
                result[refIndex + 1] = newSymbolAndEntries(reference.definition, sortedRefs)
            end
            ::continueEntry::
        end
        ::continue::
    end
    return result
end

-- GetReferencedSymbolsForNode returns all referenced symbols and their reference entries for the given node.
-- It returns all referenced symbols and their reference entries for the given node across the provided source files.
function LanguageService:GetReferencedSymbolsForNode(ctx, pos, node, sourceFiles)
    return self:getReferencedSymbolsForNode(ctx, pos, node, self.program, sourceFiles, ls.newRefOptions({
        use = ls.referenceUseReferences,
    }))
end

-- SignatureUsage represents a single usage of a signature declaration,
-- pairing the reference name node with its containing call expression (if any).
-- { name = <identifier reference node>, call = <containing call expression or nil> }

-- GetSignatureUsages returns all usages of a signature declaration as name-call pairs.
-- For each reference to the signature's name, it returns the reference node and
-- the call expression it appears in (nil if the reference is not in a call position).
function LanguageService:GetSignatureUsages(ctx, signatureDecl)
    local name = signatureDecl:Name()
    if name == nil or not ast.IsIdentifier(name) then
        return nil
    end

    local sourceFiles = self.program:GetSourceFiles()
    local entries = self:GetReferencedSymbolsForNode(ctx, name:Pos(), name, sourceFiles)

    -- Collect all declaration name nodes for the target symbol so we can
    -- filter them out — the caller wants usages, not declarations.
    local declNames = {}
    for _, entry in ipairs(entries or {}) do
        if entry.definition ~= nil and entry.definition.symbol ~= nil then
            for _, decl in ipairs(entry.definition.symbol.declarations or {}) do
                local n = decl:Name()
                if n ~= nil then
                    declNames[n] = true
                end
            end
        end
    end

    local result = nil
    for _, entry in ipairs(entries or {}) do
        for _, ref in ipairs(entry:References() or {}) do
            if not ref:IsNodeEntry() then
                goto continue
            end
            do
                local node = ref:Node()
                if node == nil or declNames[node] then
                    goto continue
                end

                local called = ast.ClimbPastPropertyAccess(node)

                local callExpr = nil
                if called.parent ~= nil and ast.IsCallExpression(called.parent) and called.parent:Expression() == called then
                    callExpr = called.parent
                end

                result = core.Append(result, {
                    name = node,
                    call = callExpr,
                })
            end
            ::continue::
        end
    end
    return result
end

-- === functions for find all ref implementation ===

function LanguageService:getReferencedSymbolsForNode(ctx, pos, node, program, sourceFiles, options)
    -- !!! cancellationToken
    local sourceFilesSet = collections.NewSetWithSizeHint(core.Len(sourceFiles))
    for _, file in ipairs(sourceFiles or {}) do
        sourceFilesSet:Add(file:FileName())
    end

    if options.use == ls.referenceUseReferences or options.use == ls.referenceUseRename then
        node = ls.getAdjustedLocation(node, options.use == ls.referenceUseRename, ast.GetSourceFileOfNode(node))
    end

    local c, done = program:GetTypeChecker(ctx)
    local result = self:getReferencedSymbolsForNodeWorker(ctx, pos, node, program, sourceFiles, options, sourceFilesSet, c)
    done()
    return result
end

-- Body of getReferencedSymbolsForNode after the checker is acquired (split out so `defer done()` runs on every path).
function LanguageService:getReferencedSymbolsForNodeWorker(ctx, pos, node, program, sourceFiles, options, sourceFilesSet, c)
    if node.kind == Kind.SourceFile then
        local resolvedRef = ls.getReferenceAtPosition(node:AsSourceFile(), pos, program)
        if resolvedRef == nil or resolvedRef.file == nil then
            return nil
        end

        local moduleSymbol = c:GetMergedSymbol(resolvedRef.file.symbol)
        if moduleSymbol ~= nil then
            return self:getReferencedSymbolsForModule(ctx, program, moduleSymbol, false --[[excludeImportTypeOfExportEquals]], sourceFiles, sourceFilesSet)
        end

        -- !!! not implemented
        -- fileIncludeReasons := program.getFileIncludeReasons();
        -- if (!fileIncludeReasons) {
        -- 	return nil
        -- }
        return { newSymbolAndEntries(
            { kind = ls.definitionKindTripleSlashReference, tripleSlashFileRef = { reference = resolvedRef.reference } },
            ls.getReferencesForNonModule(resolvedRef.file, program --[[fileIncludeReasons,]])
        ) }
    end

    if not options.implementations then
        -- !!! cancellationToken
        local special = ls.getReferencedSymbolsSpecial(node, sourceFiles)
        if special ~= nil then
            return special
        end
    end

    -- constructors should use the class symbol, detected by name, if present
    local symbol = c:GetSymbolAtLocation(core.IfElse(node.kind == Kind.Constructor and node.parent:Name() ~= nil, node.parent:Name(), node))
    -- Could not find a symbol e.g. unknown identifier
    if symbol == nil then
        -- String literal might be a property (and thus have a symbol), so do this here rather than in getReferencedSymbolsSpecial.
        if not options.implementations and ast.IsStringLiteralLike(node) then
            if ls.isModuleSpecifierLike(node) then -- luacheck: ignore 542
                -- !!! not implemented
                -- fileIncludeReasons := program.GetFileIncludeReasons()
                -- if referencedFile := program.GetResolvedModuleFromModuleSpecifier(node, nil /*sourceFile*/); referencedFile != nil {
                -- return []*SymbolAndEntries{{
                -- 	definition: &Definition{Kind: definitionKindString, node: node},
                -- 	references: getReferencesForNonModule(referencedFile, program /*fileIncludeReasons,*/),
                -- }}
                -- }
                -- Fall through to string literal references. This is not very likely to return
                -- anything useful, but I guess it's better than nothing, and there's an existing
                -- test that expects this to happen (fourslash/cases/untypedModuleImport.ts).
            end
            return self:getReferencesForStringLiteral(ctx, node, sourceFiles, c)
        end
        return nil
    end

    if symbol.name == ast.InternalSymbolNameExportEquals then
        if symbol.parent == nil then
            return nil
        end
        return self:getReferencedSymbolsForModule(ctx, program, symbol.parent, false --[[excludeImportTypeOfExportEquals]], sourceFiles, sourceFilesSet)
    end

    local moduleReferences = self:getReferencedSymbolsForModuleIfDeclaredBySourceFile(ctx, symbol, program, sourceFiles, c, options, sourceFilesSet)
    if moduleReferences ~= nil and symbol.flags & SymbolFlags.Transient == 0 then
        return moduleReferences
    end

    local aliasedSymbol = ls.getMergedAliasedSymbolOfNamespaceExportDeclaration(node, symbol, c)
    local moduleReferencesOfExportTarget = self:getReferencedSymbolsForModuleIfDeclaredBySourceFile(ctx, aliasedSymbol, program, sourceFiles, c, options, sourceFilesSet)

    local references = ls.getReferencedSymbolsForSymbol(ctx, program, symbol, node, sourceFiles, sourceFilesSet, c, options)
    return self:mergeReferences(program, moduleReferences, references, moduleReferencesOfExportTarget)
end

function LanguageService:getReferencesForStringLiteral(ctx, node, sourceFiles, c)
    local t = ls.getContextualTypeFromParentOrAncestorTypeNode(node, c)
    local references = core.FlatMap(sourceFiles, function(sourceFile)
        if ctxErr(ctx) then
            return nil
        end
        local entries = nil
        local possibleReferences = ls.getPossibleSymbolReferenceNodes(sourceFile, node:Text(), nil --[[container]])
        for _, ref in ipairs(possibleReferences or {}) do
            if ast.IsStringLiteralLike(ref) and ref:Text() == node:Text() then
                if t ~= nil then
                    local refType = ls.getContextualTypeFromParentOrAncestorTypeNode(ref, c)
                    if t ~= c:GetStringType() and
                        (t == refType or ls.isStringLiteralPropertyReference(ref, c)) then
                        entries = core.Append(entries, ls.newNodeEntryWithKind(ref, ls.entryKindStringLiteral))
                    end
                else
                    if ast.IsNoSubstitutionTemplateLiteral(ref) and not printer.RangeIsOnSingleLine(ref.loc, sourceFile) then
                        goto continue
                    end
                    entries = core.Append(entries, ls.newNodeEntryWithKind(ref, ls.entryKindStringLiteral))
                end
            end
            ::continue::
        end
        return entries
    end)

    return {
        newSymbolAndEntries({ kind = ls.definitionKindString, node = node }, references),
    }
end

function ls.isStringLiteralPropertyReference(node, c)
    if ast.IsPropertySignatureDeclaration(node.parent) then
        return c:GetPropertyOfType(c:GetTypeAtLocation(node.parent.parent), node:Text()) ~= nil
    end
    return false
end

function LanguageService:getReferencedSymbolsForModuleIfDeclaredBySourceFile(ctx, symbol, program, sourceFiles, c, options, sourceFilesSet)
    local moduleSourceFileName = ""
    if symbol == nil or not ((symbol.flags & SymbolFlags.Module ~= 0) and core.Len(symbol.declarations) ~= 0) then
        return nil
    end
    local moduleSourceFile = core.Find(symbol.declarations, ast.IsSourceFile)
    if moduleSourceFile ~= nil then
        moduleSourceFileName = moduleSourceFile:AsSourceFile():FileName()
    else
        return nil
    end
    local exportEquals = symbol.exports ~= nil and symbol.exports[ast.InternalSymbolNameExportEquals] or nil
    -- If exportEquals != nil, we're about to add references to `import("mod")` anyway, so don't double-count them.
    local moduleReferences = self:getReferencedSymbolsForModule(ctx, program, symbol, exportEquals ~= nil, sourceFiles, sourceFilesSet)
    if exportEquals == nil or exportEquals.flags & SymbolFlags.Alias == 0 or not sourceFilesSet:Has(moduleSourceFileName) then
        return moduleReferences
    end
    symbol = c:ResolveAlias(exportEquals)
    return self:mergeReferences(program, moduleReferences, ls.getReferencedSymbolsForSymbol(ctx, program, symbol, nil --[[node]], sourceFiles, sourceFilesSet, c --[[, cancellationToken]], options))
end

function ls.getReferencedSymbolsSpecial(node, sourceFiles)
    if ls.isTypeKeyword(node.kind) then
        -- A void expression (i.e., `void foo()`) is not special, but the `void` type is.
        if node.kind == Kind.VoidKeyword and node.parent.kind == Kind.VoidExpression then
            return nil
        end

        -- A modifier readonly (like on a property declaration) is not special;
        -- a readonly type keyword (like `readonly string[]`) is.
        if node.kind == Kind.ReadonlyKeyword and not ls.isReadonlyTypeOperator(node) then
            return nil
        end
        -- Likewise, when we *are* looking for a special keyword, make sure we
        -- *don't* include readonly member modifiers.
        return ls.getAllReferencesForKeyword(
            sourceFiles,
            node.kind,
            -- cancellationToken,
            node.kind == Kind.ReadonlyKeyword
        )
    end

    if ast.IsImportMeta(node.parent) and node.parent:Name() == node then
        return ls.getAllReferencesForImportMeta(sourceFiles)
    end

    if node.kind == Kind.StaticKeyword and node.parent.kind == Kind.ClassStaticBlockDeclaration then
        return { newSymbolAndEntries({ kind = ls.definitionKindKeyword, node = node }, { ls.newNodeEntry(node) }) }
    end

    -- Labels
    if ls.isJumpStatementTarget(node) then
        -- if we have a label definition, look within its statement for references, if not, then
        -- the label is undefined and we have no results..
        local labelDefinition = ls.getTargetLabel(node.parent, node:Text())
        if labelDefinition ~= nil then
            return ls.getLabelReferencesInNode(labelDefinition.parent, labelDefinition)
        end
        return nil
    end

    if ls.isLabelOfLabeledStatement(node) then
        -- it is a label definition and not a target, search within the parent labeledStatement
        return ls.getLabelReferencesInNode(node.parent, node)
    end

    if ls.isThis(node) then
        return ls.getReferencesForThisKeyword(node, sourceFiles --[[, cancellationToken]])
    end

    if node.kind == Kind.SuperKeyword then
        return ls.getReferencesForSuperKeyword(node)
    end

    return nil
end

function ls.getLabelReferencesInNode(container, targetLabel)
    local sourceFile = ast.GetSourceFileOfNode(container)
    local labelName = targetLabel:Text()
    local references = core.MapNonNil(ls.getPossibleSymbolReferenceNodes(sourceFile, labelName, container), function(node)
        -- Only pick labels that are either the target label, or have a target that is the target label
        if node == targetLabel or (ls.isJumpStatementTarget(node) and ls.getTargetLabel(node, labelName) == targetLabel) then
            return ls.newNodeEntry(node)
        end
        return nil
    end)
    return { ls.NewSymbolAndEntries(ls.definitionKindLabel, targetLabel, nil, references) }
end

function ls.getReferencesForThisKeyword(thisOrSuperKeyword, sourceFiles)
    local searchSpaceNode = ast.GetThisContainer(thisOrSuperKeyword, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])

    -- Whether 'this' occurs in a static context within a class.
    local staticFlag = ModifierFlags.Static
    local function isParameterName(node)
        return node.kind == Kind.Identifier and node.parent.kind == Kind.Parameter and node.parent:Name() == node
    end

    local sk = searchSpaceNode.kind
    if sk == Kind.MethodDeclaration or sk == Kind.MethodSignature or
        sk == Kind.PropertyDeclaration or sk == Kind.PropertySignature or sk == Kind.Constructor or sk == Kind.GetAccessor or sk == Kind.SetAccessor then
        if (sk == Kind.MethodDeclaration or sk == Kind.MethodSignature) and ast.IsObjectLiteralMethod(searchSpaceNode) then
            staticFlag = staticFlag & searchSpaceNode:ModifierFlags()
            searchSpaceNode = searchSpaceNode.parent -- re-assign to be the owning object literals
        else
            staticFlag = staticFlag & searchSpaceNode:ModifierFlags()
            searchSpaceNode = searchSpaceNode.parent -- re-assign to be the owning class
        end
    elseif sk == Kind.SourceFile then
        if ast.IsExternalModule(searchSpaceNode:AsSourceFile()) or isParameterName(thisOrSuperKeyword) then
            return nil
        end
    elseif sk == Kind.FunctionDeclaration or sk == Kind.FunctionExpression then -- luacheck: ignore 542
        -- Computed properties in classes are not handled here because references to this are illegal,
        -- so there is no point finding references to them.
    else
        return nil
    end

    local filesToSearch = sourceFiles
    if searchSpaceNode.kind ~= Kind.SourceFile then
        filesToSearch = { ast.GetSourceFileOfNode(searchSpaceNode) }
    end
    local references = core.Map(
        core.FlatMap(filesToSearch, function(sourceFile)
            -- cancellationToken.throwIfCancellationRequested();
            return core.Filter(
                ls.getPossibleSymbolReferenceNodes(sourceFile, "this", core.IfElse(searchSpaceNode.kind == Kind.SourceFile, sourceFile:AsNode(), searchSpaceNode)),
                function(node)
                    if not ls.isThis(node) then
                        return false
                    end
                    local container = ast.GetThisContainer(node --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]], false)
                    if not ast.CanHaveSymbol(container) then
                        return false
                    end
                    local k = searchSpaceNode.kind
                    if k == Kind.FunctionExpression or k == Kind.FunctionDeclaration then
                        return searchSpaceNode:Symbol() == container:Symbol()
                    elseif k == Kind.MethodDeclaration or k == Kind.MethodSignature then
                        return ast.IsObjectLiteralMethod(searchSpaceNode) and searchSpaceNode:Symbol() == container:Symbol()
                    elseif k == Kind.ClassExpression or k == Kind.ClassDeclaration or k == Kind.ObjectLiteralExpression then
                        -- Make sure the container belongs to the same class/object literals
                        -- and has the appropriate static modifier from the original container.
                        return container.parent ~= nil and ast.CanHaveSymbol(container.parent) and searchSpaceNode:Symbol() == container.parent:Symbol() and ast.IsStatic(container) == (staticFlag ~= ModifierFlags.None)
                    elseif k == Kind.SourceFile then
                        return container.kind == Kind.SourceFile and not ast.IsExternalModule(container:AsSourceFile()) and not isParameterName(node)
                    end
                    return false
                end
            )
        end),
        function(n) return ls.newNodeEntry(n) end
    )

    local thisParameter = core.FirstNonNil(references, function(ref)
        if ref.node.parent.kind == Kind.Parameter then
            return ref.node
        end
        return nil
    end)
    if thisParameter == nil then
        thisParameter = thisOrSuperKeyword
    end
    return { ls.NewSymbolAndEntries(ls.definitionKindThis, thisParameter, searchSpaceNode:Symbol(), references) }
end

function ls.getReferencesForSuperKeyword(superKeyword)
    local searchSpaceNode = ast.GetSuperContainer(superKeyword, false --[[stopOnFunctions]])
    if searchSpaceNode == nil then
        return nil
    end
    -- Whether 'super' occurs in a static context within a class.
    local staticFlag = ModifierFlags.Static

    local sk = searchSpaceNode.kind
    if sk == Kind.PropertyDeclaration or sk == Kind.PropertySignature or sk == Kind.MethodDeclaration or sk == Kind.MethodSignature or sk == Kind.Constructor or sk == Kind.GetAccessor or sk == Kind.SetAccessor then
        staticFlag = staticFlag & searchSpaceNode:ModifierFlags()
        searchSpaceNode = searchSpaceNode.parent -- re-assign to be the owning class
    else
        return nil
    end

    local sourceFile = ast.GetSourceFileOfNode(searchSpaceNode)
    local references = core.MapNonNil(ls.getPossibleSymbolReferenceNodes(sourceFile, "super", searchSpaceNode), function(node)
        if node.kind ~= Kind.SuperKeyword then
            return nil
        end

        local container = ast.GetSuperContainer(node, false --[[stopOnFunctions]])

        -- If we have a 'super' container, we must have an enclosing class.
        -- Now make sure the owning class is the same as the search-space
        -- and has the same static qualifier as the original 'super's owner.
        if container ~= nil and ast.IsStatic(container) == (staticFlag ~= ModifierFlags.None) and container.parent:Symbol() == searchSpaceNode:Symbol() then
            return ls.newNodeEntry(node)
        end
        return nil
    end)

    return { ls.NewSymbolAndEntries(ls.definitionKindSymbol, nil, searchSpaceNode:Symbol(), references) }
end

function ls.getAllReferencesForImportMeta(sourceFiles)
    local references = core.FlatMap(sourceFiles, function(sourceFile)
        return core.MapNonNil(ls.getPossibleSymbolReferenceNodes(sourceFile, "meta", sourceFile:AsNode()), function(node)
            local parent = node.parent
            if ast.IsImportMeta(parent) then
                return ls.newNodeEntry(parent)
            end
            return nil
        end)
    end)
    if core.Len(references) == 0 then
        return nil
    end
    return { newSymbolAndEntries({ kind = ls.definitionKindKeyword, node = references[1].node }, references) }
end

function ls.getAllReferencesForKeyword(sourceFiles, keywordKind, filterReadOnlyTypeOperator)
    -- references is a list of NodeEntry
    local references = core.FlatMap(sourceFiles, function(sourceFile)
        -- cancellationToken.throwIfCancellationRequested();
        return core.MapNonNil(ls.getPossibleSymbolReferenceNodes(sourceFile, scanner.TokenToString(keywordKind), sourceFile:AsNode()), function(referenceLocation)
            if referenceLocation.kind == keywordKind and (not filterReadOnlyTypeOperator or ls.isReadonlyTypeOperator(referenceLocation)) then
                return ls.newNodeEntry(referenceLocation)
            end
            return nil
        end)
    end)
    if core.Len(references) == 0 then
        return nil
    end
    return { ls.NewSymbolAndEntries(ls.definitionKindKeyword, references[1].node, nil, references) }
end

function ls.getPossibleSymbolReferenceNodes(sourceFile, symbolName, container)
    return core.MapNonNil(ls.getPossibleSymbolReferencePositions(sourceFile, symbolName, container), function(pos)
        local referenceLocation = astnav.GetTouchingPropertyName(sourceFile, pos)
        if referenceLocation ~= sourceFile:AsNode() then
            return referenceLocation
        end
        return nil
    end)
end

-- Go strings.Index(text[from:], s), returned relative to `from` (-1 if absent).
local function stringsIndexFrom(text, s, from)
    local found = string.find(text, s, from + 1, true)
    if found == nil then
        return -1
    end
    return found - 1 - from
end

function ls.getPossibleSymbolReferencePositions(sourceFile, symbolName, container)
    local positions = {}

    --/ TODO: Cache symbol existence for files to save text search
    -- Also, need to make this work for unicode escapes.

    -- Be resilient in the face of a symbol with no name or zero length name
    if symbolName == "" then
        return positions
    end

    local text = sourceFile:Text()
    local sourceLength = #text
    local symbolNameLength = #symbolName

    if container == nil then
        container = sourceFile:AsNode()
    end

    -- Note: like Go, the first index is relative to container.Pos() while later ones are absolute.
    local pos = stringsIndexFrom(text, symbolName, container:Pos())
    local endPos = container:End()
    while pos >= 0 and pos < endPos do
        -- We found a match.  Make sure it's not part of a larger word (i.e. the char
        -- before and after it have to be a non-identifier char).
        local endPosition = pos + symbolNameLength

        if (pos == 0 or not scanner.IsIdentifierPart(string.byte(text, pos))) and
            (endPosition == sourceLength or not scanner.IsIdentifierPart(string.byte(text, endPosition + 1))) then
            -- Found a real match.  Keep searching.
            positions[#positions + 1] = pos
        end
        local startIndex = pos + symbolNameLength + 1
        if startIndex > #text then
            break
        end
        local foundIndex = stringsIndexFrom(text, symbolName, startIndex)
        if foundIndex ~= -1 then
            pos = startIndex + foundIndex
        else
            break
        end
    end

    return positions
end

-- findFirstJsxNode recursively searches for the first JSX element, self-closing element, or fragment
function ls.findFirstJsxNode(root)
    local visit
    visit = function(node)
        -- Check if this is a JSX node we're looking for
        local k = node.kind
        if k == Kind.JsxElement or k == Kind.JsxSelfClosingElement or k == Kind.JsxFragment then
            return node
        end

        -- Skip subtree if it doesn't contain JSX
        if node:SubtreeFacts() & ast.SubtreeContainsJsx == 0 then
            return nil
        end

        -- Traverse children to find JSX node
        local result = nil
        node:ForEachChild(function(child)
            result = visit(child)
            return result ~= nil -- Stop if found
        end)
        return result
    end

    return visit(root)
end

function ls.getReferencesForNonModule(referencedFile, program)
    -- !!! not implemented
    return {}
end

function ls.getMergedAliasedSymbolOfNamespaceExportDeclaration(node, symbol, c)
    if node.parent ~= nil and node.parent.kind == Kind.NamespaceExportDeclaration then
        local aliasedSymbol, ok = c:ResolveAlias(symbol)
        if ok then
            local targetSymbol = c:GetMergedSymbol(aliasedSymbol)
            if aliasedSymbol ~= targetSymbol then
                return targetSymbol
            end
        end
    end
    return nil
end

function LanguageService:getReferencedSymbolsForModule(ctx, program, symbol, excludeImportTypeOfExportEquals, sourceFiles, sourceFilesSet)
    debug.Assert(symbol.valueDeclaration ~= nil)

    local c, done = program:GetTypeChecker(ctx)

    local moduleRefs = ls.findModuleReferences(program, sourceFiles, symbol, c)
    local references = core.MapNonNil(moduleRefs, function(reference)
        if reference.kind == ModuleReferenceKind.Import then
            local parent = reference.literal.parent
            if ast.IsLiteralTypeNode(parent) then
                local importType = parent.parent
                if ast.IsImportTypeNode(importType) then
                    local importTypeNode = importType:AsImportTypeNode()
                    if excludeImportTypeOfExportEquals and importTypeNode.qualifier == nil then
                        return nil
                    end
                end
            end
            -- import("foo") with no qualifier will reference the `export =` of the module, which may be referenced anyway.
            return ls.newNodeEntry(reference.literal)
        elseif reference.kind == ModuleReferenceKind.Implicit then
            -- For implicit references (e.g., JSX runtime imports), return the first JSX node,
            -- the first statement, or the whole file
            local rangeNode = nil

            -- Skip the JSX search for tslib imports
            if reference.literal:Text() ~= "tslib" then
                rangeNode = ls.findFirstJsxNode(reference.referencingFile:AsNode())
            end

            if rangeNode == nil then
                if reference.referencingFile.statements ~= nil and #reference.referencingFile.statements.nodes > 0 then
                    rangeNode = reference.referencingFile.statements.nodes[1]
                else
                    rangeNode = reference.referencingFile:AsNode()
                end
            end
            return ls.newNodeEntry(rangeNode)
        elseif reference.kind == ModuleReferenceKind.Reference then
            return ls.newReferenceEntry({
                kind = ls.entryKindRange,
                sourceFile = reference.referencingFile,
                textRange = core.NewTextRange(reference.ref:Pos(), reference.ref:End()),
            })
        end
        return nil
    end)

    -- Add references to the module declarations themselves
    if core.Len(symbol.declarations) > 0 then
        for _, decl in ipairs(symbol.declarations) do
            if decl.kind == Kind.SourceFile then -- luacheck: ignore 542
                -- Don't include the source file itself. (This may not be ideal behavior, but awkward to include an entire file as a reference.)
            elseif decl.kind == Kind.ModuleDeclaration then
                if sourceFilesSet:Has(ast.GetSourceFileOfNode(decl):FileName()) then
                    references = core.Append(references, ls.newNodeEntry(decl:AsModuleDeclaration():Name()))
                end
            else -- luacheck: ignore 542
                -- This may be merged with something (e.g. a class merged with a namespace).
            end
        end
    end

    -- Handle export equals declarations
    local exported = symbol.exports ~= nil and symbol.exports[ast.InternalSymbolNameExportEquals] or nil
    if exported ~= nil and core.Len(exported.declarations) > 0 then
        for _, decl in ipairs(exported.declarations) do
            local sourceFile = ast.GetSourceFileOfNode(decl)
            if sourceFilesSet:Has(sourceFile:FileName()) then
                local node
                -- At `module.exports = ...`, reference node is `module`
                if ast.IsBinaryExpression(decl) and ast.IsPropertyAccessExpression(decl:AsBinaryExpression().left) then
                    node = decl:AsBinaryExpression().left:Expression()
                elseif ast.IsExportAssignment(decl) then
                    -- Find the export keyword
                    node = astnav.FindChildOfKind(decl, Kind.ExportKeyword, sourceFile)
                    debug.Assert(node ~= nil, "Expected to find export keyword")
                else
                    node = ast.GetNameOfDeclaration(decl)
                    if node == nil then
                        node = decl
                    end
                end
                references = core.Append(references, ls.newNodeEntry(node))
            end
        end
    end

    done()
    if core.Len(references) > 0 then
        return { newSymbolAndEntries({ kind = ls.definitionKindSymbol, symbol = symbol }, references) }
    end
    return {}
end

-- -- Core algorithm for find all references --
function ls.getSpecialSearchKind(node)
    if node == nil then
        return "none"
    end
    local k = node.kind
    if k == Kind.Constructor or k == Kind.ConstructorKeyword then
        return "constructor"
    elseif k == Kind.Identifier then
        if ast.IsClassLike(node.parent) then
            debug.Assert(node.parent:Name() == node)
            return "class"
        end
        return "none"
    else
        return "none"
    end
end

function ls.getReferencedSymbolsForSymbol(ctx, program, originalSymbol, node, sourceFiles, sourceFilesSet, c, options)
    -- Core find-all-references algorithm for a normal symbol.

    local symbol = core.Coalesce(ls.skipPastExportOrImportSpecifierOrUnion(originalSymbol, node, c --[[useLocalSymbolForExportSpecifier]], not ls.isForRenameWithPrefixAndSuffixText(options)), originalSymbol)

    -- Compute the meaning from the location and the symbol it references
    local searchMeaning = SemanticMeaning.All
    if options.use ~= ls.referenceUseRename then
        searchMeaning = ls.getIntersectingMeaningFromDeclarations(node, symbol, SemanticMeaning.All)
    end
    local state = ls.newState(ctx, program, sourceFiles, sourceFilesSet, node, c, searchMeaning, options)

    local exportSpecifier = nil
    if ls.isForRenameWithPrefixAndSuffixText(options) and core.Len(symbol.declarations) ~= 0 then
        exportSpecifier = core.Find(symbol.declarations, ast.IsExportSpecifier)
    end
    if exportSpecifier ~= nil then
        -- When renaming at an export specifier, rename the export and not the thing being exported.
        state:getReferencesAtExportSpecifier(exportSpecifier:Name(), symbol, exportSpecifier:AsExportSpecifier(), state:createSearch(node, originalSymbol, ImpExpKind.Unknown --[[comingFrom]], "", nil), true --[[addReferencesHere]], true --[[alwaysGetReferences]])
    elseif node ~= nil and node.kind == Kind.DefaultKeyword and symbol.name == ast.InternalSymbolNameDefault and symbol.parent ~= nil then
        state:addReference(node, symbol, ls.entryKindNode)
        state:searchForImportsOfExport(node, symbol, { exportingModuleSymbol = symbol.parent, exportKind = ExportKind.Default })
    else
        local search = state:createSearch(node, symbol, ImpExpKind.Unknown --[[comingFrom]], "", state:populateSearchSymbolSet(symbol, node, options.use == ls.referenceUseRename, options.useAliasesForRename, options.implementations))
        state:getReferencesInContainerOrFiles(symbol, search)
    end

    return state.result
end

-- Symbol that is currently being searched for.
-- This will be replaced if we find an alias for the symbol.
-- refSearch: {
--   comingFrom,       -- If coming from an export, we will not recursively search for the imported symbol (since that's where we came from).
--   symbol, text, escapedText,
--   parents,          -- Only set if `options.implementations` is true. These are the symbols checked to get the implementations of a property access.
--   allSearchSymbols,
--   includes,         -- Whether a symbol is in the search set.
--                     -- Do not compare directly to `symbol` because there may be related symbols to search for. See `populateSearchSymbolSet`.
-- }

-- inheritKey { symbol, parent } is modeled as a two-level table (inheritsFromCache[symbol][parent]).

local refState = {}
refState.__index = refState
ls.refState = refState

function ls.newState(ctx, program, sourceFiles, sourceFilesSet, node, c, searchMeaning, options)
    return setmetatable({
        sourceFiles = sourceFiles,
        sourceFilesSet = sourceFilesSet,
        specialSearchKind = ls.getSpecialSearchKind(node), -- "none", "constructor", or "class"
        checker = c,
        ctx = ctx,
        program = program,
        searchMeaning = searchMeaning,
        options = options,
        result = nil,
        inheritsFromCache = {},
        seenContainingTypeReferences = collections.NewSet(), -- node seen tracker
        seenReExportRHS = collections.NewSet(), -- node seen tracker
        importTracker = nil,
        symbolToReferences = {},
        sourceFileToSeenSymbols = {},
    }, refState)
end

function refState:includesSourceFile(sourceFile)
    return self.sourceFilesSet:Has(sourceFile:FileName())
end

function refState:getImportSearches(exportSymbol, exportInfo)
    if self.importTracker == nil then
        self.importTracker = ls.createImportTracker(self.ctx, self.program, self.sourceFiles, self.sourceFilesSet, self.checker)
    end
    return self.importTracker(exportSymbol, exportInfo, self.options.use == ls.referenceUseRename)
end

-- @param allSearchSymbols set of additional symbols for use by `includes`
function refState:createSearch(location, symbol, comingFrom, text, allSearchSymbols)
    -- Note: if this is an external module symbol, the name doesn't include quotes.
    -- Note: getLocalSymbolForExportDefault handles `export default class C {}`, but not `export default C` or `export { C as default }`.
    -- The other two forms seem to be handled downstream (e.g. in `skipPastExportOrImportSpecifier`), so special-casing the first form
    -- here appears to be intentional).
    if text == "" then
        local s = binder.GetLocalSymbolForExportDefault(symbol)
        if s == nil then
            s = ls.getNonModuleSymbolOfMergedModuleSymbol(symbol)
            if s == nil then
                s = symbol
            end
        end
        text = stringutil.StripQuotes(ast.SymbolName(s))
    end
    if core.Len(allSearchSymbols) == 0 then
        allSearchSymbols = { symbol }
    end
    local search = {
        symbol = symbol,
        comingFrom = comingFrom,
        text = text,
        escapedText = text,
        allSearchSymbols = allSearchSymbols,
        includes = function(sym) return slicesContains(allSearchSymbols, sym) end,
    }
    if self.options.implementations and location ~= nil then
        search.parents = ls.getParentSymbolsOfPropertyAccess(location, symbol, self.checker)
    end
    return search
end

function refState:referenceAdder(searchSymbol)
    local symbolAndEntries = self.symbolToReferences[searchSymbol]
    if symbolAndEntries == nil then
        symbolAndEntries = ls.NewSymbolAndEntries(ls.definitionKindSymbol, nil, searchSymbol, nil)
        self.symbolToReferences[searchSymbol] = symbolAndEntries
        self.result = core.Append(self.result, symbolAndEntries)
    end
    return function(node, kind)
        symbolAndEntries.references = core.Append(symbolAndEntries.references, ls.newNodeEntryWithKind(node, kind))
    end
end

function refState:addReference(referenceLocation, symbol, kind)
    -- if rename symbol from default export anonymous function, for example `export default function() {}`, we do not need to add reference
    if self.options.use == ls.referenceUseRename and referenceLocation.kind == Kind.DefaultKeyword then
        return
    end

    local addRef = self:referenceAdder(symbol)
    if self.options.implementations then
        self:addImplementationReferences(referenceLocation, function(n) addRef(n, kind) end)
    else
        addRef(referenceLocation, kind)
    end
end

function ls.getReferenceEntriesForShorthandPropertyAssignment(node, c, addReference)
    local refSymbol = c:GetSymbolAtLocation(node)
    if refSymbol == nil or refSymbol.valueDeclaration == nil then
        return
    end
    local shorthandSymbol = c:GetShorthandAssignmentValueSymbol(refSymbol.valueDeclaration)
    if shorthandSymbol ~= nil and core.Len(shorthandSymbol.declarations) > 0 then
        for _, declaration in ipairs(shorthandSymbol.declarations) do
            if ast.GetMeaningFromDeclaration(declaration) & SemanticMeaning.Value ~= 0 then
                addReference(declaration)
            end
        end
    end
end

function ls.isMethodOrAccessor(node)
    return node.kind == Kind.MethodDeclaration or node.kind == Kind.GetAccessor or node.kind == Kind.SetAccessor
end

function ls.tryGetClassByExtendingIdentifier(node)
    return ast.TryGetClassExtendingExpressionWithTypeArguments(ast.ClimbPastPropertyAccess(node).parent)
end

function ls.getClassConstructorSymbol(classSymbol)
    if classSymbol.members == nil then
        return nil
    end
    return classSymbol.members[ast.InternalSymbolNameConstructor]
end

function ls.hasOwnConstructor(classDeclaration)
    return ls.getClassConstructorSymbol(classDeclaration:Symbol()) ~= nil
end

function ls.findOwnConstructorReferences(classSymbol, sourceFile, addNode)
    local constructorSymbol = ls.getClassConstructorSymbol(classSymbol)
    if constructorSymbol ~= nil and core.Len(constructorSymbol.declarations) > 0 then
        for _, decl in ipairs(constructorSymbol.declarations) do
            if decl.kind == Kind.Constructor then
                local ctrKeyword = astnav.FindChildOfKind(decl, Kind.ConstructorKeyword, sourceFile)
                if ctrKeyword ~= nil then
                    addNode(ctrKeyword)
                end
            end
        end
    end

    if classSymbol.exports ~= nil then
        -- Go iterates the exports map in random order.
        for _, member in pairs(classSymbol.exports) do
            local decl = member.valueDeclaration
            if decl ~= nil and decl.kind == Kind.MethodDeclaration then
                local body = decl:Body()
                if body ~= nil then
                    ls.forEachDescendantOfKind(body, Kind.ThisKeyword, function(thisKeyword)
                        if ast.IsNewExpressionTarget(thisKeyword, false, false) then
                            addNode(thisKeyword)
                        end
                    end)
                end
            end
        end
    end
end

function ls.findSuperConstructorAccesses(classDeclaration, addNode)
    local constructorSymbol = ls.getClassConstructorSymbol(classDeclaration:Symbol())
    if constructorSymbol == nil or core.Len(constructorSymbol.declarations) == 0 then
        return
    end

    for _, decl in ipairs(constructorSymbol.declarations) do
        if decl.kind == Kind.Constructor then
            local body = decl:Body()
            if body ~= nil then
                ls.forEachDescendantOfKind(body, Kind.SuperKeyword, function(node)
                    if ast.IsCallExpressionTarget(node, false, false) then
                        addNode(node)
                    end
                end)
            end
        end
    end
end

function ls.forEachDescendantOfKind(node, kind, action)
    node:ForEachChild(function(child)
        if child.kind == kind then
            action(child)
        end
        ls.forEachDescendantOfKind(child, kind, action)
        return false
    end)
end

function refState:addImplementationReferences(refNode, addRef)
    -- Check if we found a function/propertyAssignment/method with an implementation or initializer
    if ast.IsDeclarationName(refNode) and ls.isImplementation(refNode.parent) then
        addRef(refNode)
        return
    end

    if refNode.kind ~= Kind.Identifier then
        return
    end

    if refNode.parent.kind == Kind.ShorthandPropertyAssignment then
        -- Go ahead and dereference the shorthand assignment by going to its definition
        ls.getReferenceEntriesForShorthandPropertyAssignment(refNode, self.checker, addRef)
    end

    -- Check if the node is within an extends or implements clause

    local containingNode = ls.getContainingNodeIfInHeritageClause(refNode)
    if containingNode ~= nil then
        addRef(containingNode)
        return
    end

    -- If we got a type reference, try and see if the reference applies to any expressions that can implement an interface
    -- Find the first node whose parent isn't a type node -- i.e., the highest type node.
    local typeNode = ast.FindAncestor(refNode, function(a)
        return not ast.IsQualifiedName(a.parent) and not ast.IsTypeNode(a.parent) and not ast.IsTypeElement(a.parent)
    end)

    if typeNode == nil or typeNode.parent:Type() == nil then
        return
    end

    local typeHavingNode = typeNode.parent
    if typeHavingNode:Type() == typeNode and self.seenContainingTypeReferences:AddIfAbsent(typeHavingNode) then
        local function addIfImplementation(e)
            if ls.isImplementationExpression(e) then
                addRef(e)
            end
        end
        if ast.HasInitializer(typeHavingNode) then
            addIfImplementation(typeHavingNode:Initializer())
        elseif ast.IsFunctionLike(typeHavingNode) and typeHavingNode:Body() ~= nil then
            local body = typeHavingNode:Body()
            if body.kind == Kind.Block then
                ast.ForEachReturnStatement(body, function(returnStatement)
                    local expr = returnStatement:Expression()
                    if expr ~= nil then
                        addIfImplementation(expr)
                    end
                    return false
                end)
            else
                addIfImplementation(body)
            end
        elseif ast.IsAssertionExpression(typeHavingNode) or ast.IsSatisfiesExpression(typeHavingNode) then
            addIfImplementation(typeHavingNode:Expression())
        end
    end
end

function refState:getReferencesInContainerOrFiles(symbol, search)
    -- Try to get the smallest valid scope that we can limit our search to;
    -- otherwise we'll need to search globally (i.e. include each file).
    local scope = ls.getSymbolScope(symbol)
    if scope ~= nil then
        local addReferencesHere = scope.kind ~= Kind.SourceFile or slicesContains(self.sourceFiles, scope:AsSourceFile())
        self:getReferencesInContainer(scope, ast.GetSourceFileOfNode(scope), search, addReferencesHere)
    else
        -- Global search
        for _, sourceFile in ipairs(self.sourceFiles or {}) do
            -- state.cancellationToken.throwIfCancellationRequested();
            self:searchForName(sourceFile, search)
        end
    end
end

function refState:getReferencesInSourceFile(sourceFile, search, addReferencesHere)
    -- state.cancellationToken.throwIfCancellationRequested();
    self:getReferencesInContainer(sourceFile:AsNode(), sourceFile, search, addReferencesHere)
end

function refState:getReferencesInContainer(container, sourceFile, search, addReferencesHere)
    -- Search within node "container" for references for a search value, where the search value is defined as a
    --     tuple of (searchSymbol, searchText, searchLocation, and searchMeaning).
    -- searchLocation: a node where the search value
    if not self:markSearchedSymbols(sourceFile, search.allSearchSymbols) then
        return
    end

    for _, pos in ipairs(ls.getPossibleSymbolReferencePositions(sourceFile, search.text, container)) do
        self:getReferencesAtLocation(sourceFile, pos, search, addReferencesHere)
    end
end

function refState:markSearchedSymbols(sourceFile, symbols)
    local seenSymbols = self.sourceFileToSeenSymbols[sourceFile]
    if seenSymbols == nil then
        seenSymbols = collections.NewSet()
        self.sourceFileToSeenSymbols[sourceFile] = seenSymbols
    end
    local anyNewSymbols = false
    for _, sym in ipairs(symbols or {}) do
        if seenSymbols:AddIfAbsent(sym) then
            anyNewSymbols = true
        end
    end
    return anyNewSymbols
end

function refState:getReferencesAtLocation(sourceFile, pos, search, addReferencesHere)
    local referenceLocation = astnav.GetTouchingPropertyName(sourceFile, pos)

    if not ls.isValidReferencePosition(referenceLocation, search.text) then
        -- This wasn't the start of a token.  Check to see if it might be a
        -- match in a comment or string if that's what the caller is asking
        -- for.

        -- !!! not implemented
        -- if (!state.options.implementations && (state.options.findInStrings && isInString(sourceFile, position) || state.options.findInComments && isInNonReferenceComment(sourceFile, position))) {
        -- 	// In the case where we're looking inside comments/strings, we don't have
        -- 	// an actual definition.  So just use 'undefined' here.  Features like
        -- 	// 'Rename' won't care (as they ignore the definitions), and features like
        -- 	// 'FindReferences' will just filter out these results.
        -- 	state.addStringOrCommentReference(sourceFile.FileName, createTextSpan(position, search.text.length));
        -- }

        return
    end

    if ls.getMeaningFromLocation(referenceLocation) & self.searchMeaning == 0 then
        return
    end

    local referenceSymbol = self.checker:GetSymbolAtLocation(referenceLocation)
    if referenceSymbol == nil then
        return
    end

    local parent = referenceLocation.parent
    if parent.kind == Kind.ImportSpecifier and parent:PropertyName() == referenceLocation then
        -- This is added through `singleReferences` in ImportsResult. If we happen to see it again, don't add it again.
        return
    end

    if parent.kind == Kind.ExportSpecifier then
        self:getReferencesAtExportSpecifier(referenceLocation, referenceSymbol, parent:AsExportSpecifier(), search, addReferencesHere, false --[[alwaysGetReferences]])
        return
    end

    local relatedSymbol, relatedSymbolKind = self:getRelatedSymbol(search, referenceSymbol, referenceLocation)
    if relatedSymbol == nil then
        self:getReferenceForShorthandProperty(referenceSymbol, search)
        return
    end

    local ssk = self.specialSearchKind
    if ssk == "none" then
        if addReferencesHere then
            self:addReference(referenceLocation, relatedSymbol, relatedSymbolKind)
        end
    elseif ssk == "constructor" then
        self:addConstructorReferences(referenceLocation, relatedSymbol, search, addReferencesHere)
    elseif ssk == "class" then
        self:addClassStaticThisReferences(referenceLocation, relatedSymbol, search, addReferencesHere)
    end

    -- Use the parent symbol if the location is commonjs require syntax on javascript files only.
    if ast.IsInJSFile(referenceLocation) and referenceLocation.parent.kind == Kind.BindingElement and
        ast.IsVariableDeclarationInitializedToBareOrAccessedRequire(referenceLocation.parent.parent.parent) then
        referenceSymbol = referenceLocation.parent:Symbol()
        -- The parent will not have a symbol if it's an ObjectBindingPattern (when destructuring is used).  In
        -- this case, just skip it, since the bound identifiers are not an alias of the import.
        if referenceSymbol == nil then
            return
        end
    end

    self:getImportOrExportReferences(referenceLocation, referenceSymbol, search)
end

function refState:addConstructorReferences(referenceLocation, symbol, search, addReferencesHere)
    if ast.IsNewExpressionTarget(referenceLocation, false, false) and addReferencesHere then
        self:addReference(referenceLocation, symbol, ls.entryKindNode)
    end

    local function pusher()
        return self:referenceAdder(search.symbol)
    end

    if ast.IsClassLike(referenceLocation.parent) then
        -- This is the class declaration containing the constructor.
        local sourceFile = ast.GetSourceFileOfNode(referenceLocation)
        ls.findOwnConstructorReferences(search.symbol, sourceFile, function(n)
            pusher()(n, ls.entryKindNode)
        end)
    else
        -- If this class appears in `extends C`, then the extending class' "super" calls are references.
        local classExtending = ls.tryGetClassByExtendingIdentifier(referenceLocation)
        if classExtending ~= nil then
            ls.findSuperConstructorAccesses(classExtending, function(n)
                pusher()(n, ls.entryKindNode)
            end)
            self:findInheritedConstructorReferences(classExtending)
        end
    end
end

function refState:addClassStaticThisReferences(referenceLocation, symbol, search, addReferencesHere)
    if addReferencesHere then
        self:addReference(referenceLocation, symbol, ls.entryKindNode)
    end

    local classLike = referenceLocation.parent
    if self.options.use == ls.referenceUseRename or not ast.IsClassLike(classLike) then
        return
    end

    local addRef = self:referenceAdder(search.symbol)
    local members = classLike:Members()
    if members == nil then
        return
    end
    for _, member in ipairs(members) do
        if not (ls.isMethodOrAccessor(member) and ast.HasStaticModifier(member)) then
            goto continue
        end
        do
            local body = member:Body()
            if body ~= nil then
                local cb
                cb = function(node)
                    if node.kind == Kind.ThisKeyword then
                        addRef(node, ls.entryKindNode)
                    elseif not ast.IsFunctionLike(node) and not ast.IsClassLike(node) then
                        node:ForEachChild(function(child)
                            cb(child)
                            return false
                        end)
                    end
                end
                cb(body)
            end
        end
        ::continue::
    end
end

function refState:findInheritedConstructorReferences(classDeclaration)
    if ls.hasOwnConstructor(classDeclaration) then
        return
    end
    local classSymbol = classDeclaration:Symbol()
    local search = self:createSearch(nil, classSymbol, ImpExpKind.Unknown, "", nil)
    self:getReferencesInContainerOrFiles(classSymbol, search)
end

function refState:getImportOrExportReferences(referenceLocation, referenceSymbol, search)
    local importOrExport = ls.getImportOrExportSymbol(referenceLocation, referenceSymbol, self.checker, search.comingFrom == ImpExpKind.Export)
    if importOrExport == nil then
        return
    end
    if importOrExport.kind == ImpExpKind.Import then
        if not ls.isForRenameWithPrefixAndSuffixText(self.options) then
            self:searchForImportedSymbol(importOrExport.symbol)
        end
    else
        self:searchForImportsOfExport(referenceLocation, importOrExport.symbol, importOrExport.exportInfo)
    end
end

function refState:markSeenReExportRHS(node)
    return self.seenReExportRHS:AddIfAbsent(node)
end

function refState:getReferencesAtExportSpecifier(
    referenceLocation,
    referenceSymbol,
    exportSpecifier,
    search,
    addReferencesHere,
    alwaysGetReferences
)
    debug.Assert(not alwaysGetReferences or self.options.useAliasesForRename, "If alwaysGetReferences is true, then prefix/suffix text must be enabled")

    local exportDeclaration = exportSpecifier.parent.parent:AsExportDeclaration()
    local propertyName = exportSpecifier.propertyName
    local name = exportSpecifier:Name()
    local localSymbol = ls.getLocalSymbolForExportSpecifier(referenceLocation, referenceSymbol, exportSpecifier, self.checker)

    if not alwaysGetReferences and not search.includes(localSymbol) then
        return
    end

    local function addRef()
        if addReferencesHere then
            self:addReference(referenceLocation, localSymbol, ls.entryKindNode)
        end
    end

    if propertyName == nil then
        -- Don't rename at `export { default } from "m";`. (but do continue to search for imports of the re-export)
        if not (self.options.use == ls.referenceUseRename and ast.ModuleExportNameIsDefault(name)) then
            addRef()
        end
    elseif referenceLocation == propertyName then
        -- For `export { foo as bar } from "baz"`, "`foo`" will be added from the singleReferences for import searches of the original export.
        -- For `export { foo as bar };`, where `foo` is a local, so add it now.
        if exportDeclaration.moduleSpecifier == nil then
            addRef()
        end

        if addReferencesHere and self.options.use ~= ls.referenceUseRename and self:markSeenReExportRHS(name) then
            local exportSymbol = exportSpecifier:AsNode():Symbol()
            debug.Assert(exportSymbol ~= nil, "exportSpecifier.Symbol() should not be nil")
            self:addReference(name, exportSymbol, ls.entryKindNode)
        end
    else
        if self:markSeenReExportRHS(referenceLocation) then
            addRef()
        end
    end

    -- For `export { foo as bar }`, rename `foo`, but not `bar`.
    if not ls.isForRenameWithPrefixAndSuffixText(self.options) or alwaysGetReferences then
        local isDefaultExport = ast.ModuleExportNameIsDefault(referenceLocation) or ast.ModuleExportNameIsDefault(exportSpecifier:Name())
        local exportKind = ExportKind.Named
        if isDefaultExport then
            exportKind = ExportKind.Default
        end
        local exportSymbol = exportSpecifier:AsNode():Symbol()
        debug.Assert(exportSymbol ~= nil, "exportSpecifier.Symbol() should not be nil")
        local exportInfo = ls.getExportInfo(exportSymbol, exportKind, self.checker)
        if exportInfo ~= nil then
            self:searchForImportsOfExport(referenceLocation, exportSymbol, exportInfo)
        end
    end

    -- At `export { x } from "foo"`, also search for the imported symbol `"foo".x`.
    if search.comingFrom ~= ImpExpKind.Export and exportDeclaration.moduleSpecifier ~= nil and propertyName == nil and not ls.isForRenameWithPrefixAndSuffixText(self.options) then
        local imported = self.checker:GetExportSpecifierLocalTargetSymbol(exportSpecifier:AsNode())
        if imported ~= nil then
            self:searchForImportedSymbol(imported)
        end
    end
end

-- Go to the symbol we imported from and find references for it.
function refState:searchForImportedSymbol(symbol)
    for _, declaration in ipairs(symbol.declarations or {}) do
        local exportingFile = ast.GetSourceFileOfNode(declaration)
        -- Need to search in the file even if it's not in the search-file set, because it might export the symbol.
        self:getReferencesInSourceFile(exportingFile, self:createSearch(declaration, symbol, ImpExpKind.Import, "", nil), self:includesSourceFile(exportingFile))
    end
end

-- Search for all imports of a given exported symbol using `State.getImportSearches`. */
function refState:searchForImportsOfExport(exportLocation, exportSymbol, exportInfo)
    local r = self:getImportSearches(exportSymbol, exportInfo)

    -- For `import { foo as bar }` just add the reference to `foo`, and don't otherwise search in the file.
    if core.Len(r.singleReferences) ~= 0 then
        local addRef = self:referenceAdder(exportSymbol)
        for _, singleRef in ipairs(r.singleReferences) do
            if self:shouldAddSingleReference(singleRef) then
                addRef(singleRef, ls.entryKindNode)
            end
        end
    end

    -- For each import, find all references to that import in its source file.
    for _, i in ipairs(r.importSearches or {}) do
        self:getReferencesInSourceFile(ast.GetSourceFileOfNode(i.importLocation), self:createSearch(i.importLocation, i.importSymbol, ImpExpKind.Export, "", nil), true --[[addReferencesHere]])
    end

    if core.Len(r.indirectUsers) ~= 0 then
        local indirectSearch = nil
        if exportInfo.exportKind == ExportKind.Named then
            indirectSearch = self:createSearch(exportLocation, exportSymbol, ImpExpKind.Export, "", nil)
        elseif exportInfo.exportKind == ExportKind.Default then
            -- Search for a property access to '.default'. This can't be renamed.
            if self.options.use ~= ls.referenceUseRename then
                indirectSearch = self:createSearch(exportLocation, exportSymbol, ImpExpKind.Export, "default", nil)
            end
        end
        if indirectSearch ~= nil then
            for _, indirectUser in ipairs(r.indirectUsers) do
                self:searchForName(indirectUser, indirectSearch)
            end
        end
    end
end

function refState:shouldAddSingleReference(singleRef)
    if not self:hasMatchingMeaning(singleRef) then
        return false
    end
    if self.options.use ~= ls.referenceUseRename then
        return true
    end
    -- Don't rename an import type `import("./module-name")` when renaming `name` in `export = name;`
    if not ast.IsIdentifier(singleRef) and not ast.IsImportOrExportSpecifier(singleRef.parent) then
        return false
    end
    -- At `default` in `import { default as x }` or `export { default as x }`, do add a reference, but do not rename.
    return not (ast.IsImportOrExportSpecifier(singleRef.parent) and ast.ModuleExportNameIsDefault(singleRef))
end

function refState:hasMatchingMeaning(referenceLocation)
    return ls.getMeaningFromLocation(referenceLocation) & self.searchMeaning ~= 0
end

function refState:getReferenceForShorthandProperty(referenceSymbol, search)
    if referenceSymbol.flags & SymbolFlags.Transient ~= 0 or referenceSymbol.valueDeclaration == nil then
        return
    end
    local shorthandValueSymbol = self.checker:GetShorthandAssignmentValueSymbol(referenceSymbol.valueDeclaration)
    local name = ast.GetNameOfDeclaration(referenceSymbol.valueDeclaration)

    -- Because in short-hand property assignment, an identifier which stored as name of the short-hand property assignment
    -- has two meanings: property name and property value. Therefore when we do findAllReference at the position where
    -- an identifier is declared, the language service should return the position of the variable declaration as well as
    -- the position in short-hand property assignment excluding property accessing. However, if we do findAllReference at the
    -- position of property accessing, the referenceEntry of such position will be handled in the first case.
    if name ~= nil and search.includes(shorthandValueSymbol) then
        self:addReference(name, shorthandValueSymbol, ls.entryKindNode)
    end
end

-- === search ===
function refState:populateSearchSymbolSet(symbol, location, isForRename, providePrefixAndSuffixText, implementations)
    if location == nil then
        return { symbol }
    end
    local result = {}
    self:forEachRelatedSymbol(
        symbol,
        location,
        isForRename,
        not (isForRename and providePrefixAndSuffixText),
        function(sym, root, base)
            -- static method/property and instance method/property might have the same name. Only include static or only include instance.
            if base ~= nil then
                if ls.isStaticSymbol(symbol) ~= ls.isStaticSymbol(base) then
                    base = nil
                end
            end
            result[#result + 1] = core.OrElse(base, core.OrElse(root, sym))
            return nil
        end, -- when try to find implementation, implementations is true, and not allowed to find base class
        --[[allowBaseTypes]] function(_) return not implementations end
    )
    return result
end

function refState:getRelatedSymbol(search, referenceSymbol, referenceLocation)
    return self:forEachRelatedSymbol(
        referenceSymbol,
        referenceLocation,
        false, --[[isForRenamePopulateSearchSymbolSet]]
        self.options.use ~= ls.referenceUseRename or self.options.useAliasesForRename, --[[onlyIncludeBindingElementAtReferenceLocation]]
        function(sym, rootSymbol, baseSymbol)
            -- check whether the symbol used to search itself is just the searched one.
            if baseSymbol ~= nil then
                -- static method/property and instance method/property might have the same name. Only check static or only check instance.
                if ls.isStaticSymbol(referenceSymbol) ~= ls.isStaticSymbol(baseSymbol) then
                    baseSymbol = nil
                end
            end
            local searchSym = core.Coalesce(baseSymbol, core.Coalesce(rootSymbol, sym))
            if searchSym ~= nil and search.includes(searchSym) then
                if rootSymbol ~= nil and sym.checkFlags & CheckFlags.Synthetic == 0 then
                    return rootSymbol
                end
                return sym
            end
            -- For a base type, use the symbol for the derived type. For a synthetic (e.g. union) property, use the union symbol.
            return nil
        end,
        function(rootSymbol)
            return not (core.Len(search.parents) ~= 0 and not core.Some(search.parents, function(parent)
                return self:explicitlyInheritsFrom(rootSymbol.parent, parent)
            end))
        end
    )
end

function refState:forEachRelatedSymbol(
    symbol,
    location,
    isForRenamePopulateSearchSymbolSet,
    onlyIncludeBindingElementAtReferenceLocation,
    cbSymbol,
    allowBaseTypes
)
    local function fromRoot(sym)
        -- If this is a union property:
        --   - In populateSearchSymbolsSet we will add all the symbols from all its source symbols in all unioned types.
        --   - In findRelatedSymbol, we will just use the union symbol if any source symbol is included in the search.
        -- If the symbol is an instantiation from a another symbol (e.g. widened symbol):
        --   - In populateSearchSymbolsSet, add the root the list
        --   - In findRelatedSymbol, return the source symbol if that is in the search. (Do not return the instantiation symbol.)
        for _, rootSymbol in ipairs(self.checker:GetRootSymbols(sym) or {}) do
            local result = cbSymbol(sym, rootSymbol, nil --[[baseSymbol]])
            if result ~= nil then
                return result
            end
            -- Add symbol of properties/methods of the same name in base classes and implemented interfaces definitions
            if rootSymbol.parent ~= nil and rootSymbol.parent.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 and allowBaseTypes(rootSymbol) then
                result = ls.getPropertySymbolsFromBaseTypes(rootSymbol.parent, rootSymbol.name, self.checker, function(base)
                    return cbSymbol(sym, rootSymbol, base)
                end)
                if result ~= nil then
                    return result
                end
            end
        end
        return nil
    end

    local containingObjectLiteralElement = ls.getContainingObjectLiteralElement(location)
    if containingObjectLiteralElement ~= nil then
        --[[ Because in short-hand property assignment, location has two meaning : property name and as value of the property
         * When we do findAllReference at the position of the short-hand property assignment, we would want to have references to position of
         * property name and variable declaration of the identifier.
         * Like in below example, when querying for all references for an identifier 'name', of the property assignment, the language service
         * should show both 'name' in 'obj' and 'name' in variable declaration
         *      const name = "Foo";
         *      const obj = { name };
         * In order to do that, we will populate the search set with the value symbol of the identifier as a value of the property assignment
         * so that when matching with potential reference symbol, both symbols from property declaration and variable declaration
         * will be included correctly.
         ]]
        local shorthandValueSymbol = self.checker:GetShorthandAssignmentValueSymbol(location.parent)
        -- gets the local symbol
        if shorthandValueSymbol ~= nil and isForRenamePopulateSearchSymbolSet then
            -- When renaming 'x' in `const o = { x }`, just rename the local variable, not the property.
            return cbSymbol(shorthandValueSymbol, nil --[[rootSymbol]], nil --[[baseSymbol]]), ls.entryKindSearchedLocalFoundProperty
        end
        -- If the location is in a context sensitive location (i.e. in an object literal) try
        -- to get a contextual type for it, and add the property symbol from the contextual
        -- type to the search set
        local contextualType = self.checker:GetContextualType(containingObjectLiteralElement.parent, checker.ContextFlags.None)
        if contextualType ~= nil then
            local symbols = self.checker:GetPropertySymbolsFromContextualType(containingObjectLiteralElement, contextualType, true --[[unionSymbolOk]])
            for _, sym in ipairs(symbols or {}) do
                local res = fromRoot(sym)
                if res ~= nil then
                    return res, ls.entryKindSearchedPropertyFoundLocal
                end
            end
        end
        -- If the location is name of property symbol from object literal destructuring pattern
        -- Search the property symbol
        --      for ( { property: p2 } of elems) { }
        local propertySymbol = self.checker:GetPropertySymbolOfDestructuringAssignment(location)
        if propertySymbol ~= nil then
            local res = cbSymbol(propertySymbol, nil --[[rootSymbol]], nil --[[baseSymbol]])
            if res ~= nil then
                return res, ls.entryKindSearchedPropertyFoundLocal
            end
        end
        if shorthandValueSymbol ~= nil then
            local res = cbSymbol(shorthandValueSymbol, nil --[[rootSymbol]], nil --[[baseSymbol]])
            if res ~= nil then
                return res, ls.entryKindSearchedLocalFoundProperty
            end
        end
    end

    local aliasedSymbol = ls.getMergedAliasedSymbolOfNamespaceExportDeclaration(location, symbol, self.checker)
    if aliasedSymbol ~= nil then
        -- In case of UMD module and global merging, search for global as well
        local res = cbSymbol(aliasedSymbol, nil --[[rootSymbol]], nil --[[baseSymbol]])
        if res ~= nil then
            return res, ls.entryKindNode
        end
    end

    do
        local res = fromRoot(symbol)
        if res ~= nil then
            return res, ls.entryKindNode
        end
    end

    if symbol.valueDeclaration ~= nil and ast.IsParameterPropertyDeclaration(symbol.valueDeclaration, symbol.valueDeclaration.parent) then
        local paramProp1, paramProp2 = self.checker:GetSymbolsOfParameterPropertyDeclaration(symbol.valueDeclaration, symbol.name)
        debug.Assert(
            paramProp1.flags & SymbolFlags.FunctionScopedVariable ~= 0 and paramProp2.flags & SymbolFlags.ClassMember ~= 0,
            "GetSymbolsOfParameterPropertyDeclaration must return (parameter, member) pair"
        )
        return fromRoot(core.IfElse(symbol.flags & SymbolFlags.FunctionScopedVariable ~= 0, paramProp2, paramProp1)), ls.entryKindNode
    end

    local exportSpecifier = ast.GetDeclarationOfKind(symbol, Kind.ExportSpecifier)
    if exportSpecifier ~= nil and (not isForRenamePopulateSearchSymbolSet or exportSpecifier:PropertyName() == nil) then
        local localSymbol = self.checker:GetExportSpecifierLocalTargetSymbol(exportSpecifier)
        if localSymbol ~= nil then
            local res = cbSymbol(localSymbol, nil --[[rootSymbol]], nil --[[baseSymbol]])
            if res ~= nil then
                return res, ls.entryKindNode
            end
        end
    end

    -- symbolAtLocation for a binding element is the local symbol. See if the search symbol is the property.
    -- Don't do this when populating search set for a rename when prefix and suffix text will be provided -- just rename the local.
    if not isForRenamePopulateSearchSymbolSet then
        local bindingElementPropertySymbol
        if onlyIncludeBindingElementAtReferenceLocation then
            if not ls.isObjectBindingElementWithoutPropertyName(location.parent) then
                return nil, ls.entryKindNone
            end
            bindingElementPropertySymbol = ls.getPropertySymbolFromBindingElement(self.checker, location.parent)
        else
            bindingElementPropertySymbol = ls.getPropertySymbolOfObjectBindingPatternWithoutPropertyName(symbol, self.checker)
        end
        if bindingElementPropertySymbol == nil then
            return nil, ls.entryKindNone
        end
        return fromRoot(bindingElementPropertySymbol), ls.entryKindSearchedPropertyFoundLocal
    end

    debug.Assert(isForRenamePopulateSearchSymbolSet)

    -- due to the above assert and the arguments at the uses of this function,
    -- (onlyIncludeBindingElementAtReferenceLocation <=> !providePrefixAndSuffixTextForRename) holds
    local includeOriginalSymbolOfBindingElement = onlyIncludeBindingElementAtReferenceLocation

    if includeOriginalSymbolOfBindingElement then
        local bindingElementPropertySymbol = ls.getPropertySymbolOfObjectBindingPatternWithoutPropertyName(symbol, self.checker)
        if bindingElementPropertySymbol ~= nil then
            return fromRoot(bindingElementPropertySymbol), ls.entryKindSearchedPropertyFoundLocal
        end
    end
    return nil, ls.entryKindNone
end

-- Search for all occurrences of an identifier in a source file (and filter out the ones that match).
function refState:searchForName(sourceFile, search)
    if sourceFile:GetNameTable()[search.escapedText] ~= nil then
        self:getReferencesInSourceFile(sourceFile, search, true --[[addReferencesHere]])
    end
end

function refState:explicitlyInheritsFrom(symbol, parent)
    if symbol == parent then
        return true
    end

    -- Check cache first
    local bySymbol = self.inheritsFromCache[symbol]
    if bySymbol == nil then
        bySymbol = {}
        self.inheritsFromCache[symbol] = bySymbol
    end
    local cached = bySymbol[parent]
    if cached ~= nil then
        return cached
    end

    -- Set to false initially to prevent infinite recursion
    bySymbol[parent] = false

    if symbol.declarations == nil then
        return false
    end

    local inherits = core.Some(symbol.declarations, function(declaration)
        local superTypeNodes = ls.getAllSuperTypeNodes(declaration)
        return core.Some(superTypeNodes, function(typeReference)
            local typ = self.checker:GetTypeAtLocation(typeReference:AsNode())
            return typ ~= nil and typ:Symbol() ~= nil and self:explicitlyInheritsFrom(typ:Symbol(), parent)
        end)
    end)

    -- Update cache with the actual result
    bySymbol[parent] = inherits
    return inherits
end
