local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local FindAncestorResult = ast.FindAncestorResult
local KeywordCompletionFilters = ls.KeywordCompletionFilters
local CompletionKind = ls.CompletionKind
local SortText = ls.SortText

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

-- Go &CompletionList{IsIncomplete: ..., ItemDefaults: ..., Items: ...}
local function newCompletionList(isIncomplete, itemDefaults, items)
    return setmetatable({
        isIncomplete = isIncomplete,
        itemDefaults = itemDefaults,
        items = items,
    }, ls.CompletionList)
end

function ls.CompareCompletionEntries(a, b)
    local compareStrings = stringutil.CompareStringsCaseInsensitiveThenSensitive
    local result = compareStrings(a.sortText, b.sortText)
    if result == stringutil.ComparisonEqual then
        result = compareStrings(a.label, b.label)
    end
    return result
end

-- Go collections.SyncMap[KeywordCompletionFilters, []*lsproto.CompletionItem]
ls.keywordCompletionsCache = {}

-- Go sync.OnceValue
function ls.allKeywordCompletions()
    if ls.allKeywordCompletionsValue == nil then
        local result = {}
        for i = Kind.FirstKeyword, Kind.LastKeyword do
            result[#result + 1] = {
                label = scanner.TokenToString(i),
                kind = lsproto.CompletionItemKind.Keyword,
                sortText = SortText.GlobalsOrKeywords,
            }
        end
        ls.allKeywordCompletionsValue = result
    end
    return ls.allKeywordCompletionsValue
end

function ls.cloneItems(items)
    if items == nil then
        return nil
    end
    local entries = {}
    for i, item in ipairs(items) do
        local itemClone = {}
        for k, v in pairs(item) do
            itemClone[k] = v
        end
        entries[i] = ls.NewCompletionItem(itemClone, nil)
    end
    return entries
end

function ls.getKeywordCompletions(keywordFilter, filterOutTsOnlyKeywords)
    if not filterOutTsOnlyKeywords then
        return ls.cloneItems(ls.getTypescriptKeywordCompletions(keywordFilter))
    end

    local index = keywordFilter + KeywordCompletionFilters.Last + 1
    local cached = ls.keywordCompletionsCache[index]
    if cached ~= nil then
        return ls.cloneItems(cached)
    end
    local result = core.Filter(
        ls.getTypescriptKeywordCompletions(keywordFilter),
        function(ci)
            return not ls.isTypeScriptOnlyKeyword(scanner.StringToToken(ci.label))
        end
    )
    ls.keywordCompletionsCache[index] = result
    return ls.cloneItems(result)
end

function ls.getTypescriptKeywordCompletions(keywordFilter)
    local cached = ls.keywordCompletionsCache[keywordFilter]
    if cached ~= nil then
        return cached
    end
    local result = core.Filter(ls.allKeywordCompletions(), function(entry)
        local kind = scanner.StringToToken(entry.label)
        if keywordFilter == KeywordCompletionFilters.None then
            return false
        elseif keywordFilter == KeywordCompletionFilters.All then
            return ls.isFunctionLikeBodyKeyword(kind) or
                kind == Kind.DeclareKeyword or
                kind == Kind.ModuleKeyword or
                kind == Kind.TypeKeyword or
                kind == Kind.NamespaceKeyword or
                kind == Kind.AbstractKeyword or
                ls.isTypeKeyword(kind) and kind ~= Kind.UndefinedKeyword
        elseif keywordFilter == KeywordCompletionFilters.FunctionLikeBodyKeywords then
            return ls.isFunctionLikeBodyKeyword(kind)
        elseif keywordFilter == KeywordCompletionFilters.ClassElementKeywords then
            return ls.isClassMemberCompletionKeyword(kind)
        elseif keywordFilter == KeywordCompletionFilters.InterfaceElementKeywords then
            return ls.isInterfaceOrTypeLiteralCompletionKeyword(kind)
        elseif keywordFilter == KeywordCompletionFilters.ConstructorParameterKeywords then
            return ast.IsParameterPropertyModifier(kind)
        elseif keywordFilter == KeywordCompletionFilters.TypeAssertionKeywords then
            return ls.isTypeKeyword(kind) or kind == Kind.ConstKeyword
        elseif keywordFilter == KeywordCompletionFilters.TypeKeywords then
            return ls.isTypeKeyword(kind)
        elseif keywordFilter == KeywordCompletionFilters.TypeKeyword then
            return kind == Kind.TypeKeyword
        else
            error("Unknown keyword filter: " .. tostring(keywordFilter), 0)
        end
    end)

    ls.keywordCompletionsCache[keywordFilter] = result
    return result
end

local typeScriptOnlyKeywords = ast.kindSet(
    Kind.AbstractKeyword,
    Kind.AnyKeyword,
    Kind.BigIntKeyword,
    Kind.BooleanKeyword,
    Kind.DeclareKeyword,
    Kind.EnumKeyword,
    Kind.GlobalKeyword,
    Kind.ImplementsKeyword,
    Kind.InferKeyword,
    Kind.InterfaceKeyword,
    Kind.IsKeyword,
    Kind.KeyOfKeyword,
    Kind.ModuleKeyword,
    Kind.NamespaceKeyword,
    Kind.NeverKeyword,
    Kind.NumberKeyword,
    Kind.ObjectKeyword,
    Kind.OverrideKeyword,
    Kind.PrivateKeyword,
    Kind.ProtectedKeyword,
    Kind.PublicKeyword,
    Kind.ReadonlyKeyword,
    Kind.StringKeyword,
    Kind.SymbolKeyword,
    Kind.TypeKeyword,
    Kind.UniqueKeyword,
    Kind.UnknownKeyword
)

function ls.isTypeScriptOnlyKeyword(kind)
    return typeScriptOnlyKeywords[kind] == true
end

function ls.isFunctionLikeBodyKeyword(kind)
    return kind == Kind.AsyncKeyword or
        kind == Kind.AwaitKeyword or
        kind == Kind.UsingKeyword or
        kind == Kind.AsKeyword or
        kind == Kind.SatisfiesKeyword or
        kind == Kind.TypeKeyword or
        not ast.IsContextualKeyword(kind) and not ls.isClassMemberCompletionKeyword(kind)
end

function ls.isClassMemberCompletionKeyword(kind)
    if kind == Kind.AbstractKeyword or kind == Kind.AccessorKeyword or kind == Kind.ConstructorKeyword or
        kind == Kind.GetKeyword or kind == Kind.SetKeyword or kind == Kind.AsyncKeyword or
        kind == Kind.DeclareKeyword or kind == Kind.OverrideKeyword then
        return true
    end
    return ast.IsClassMemberModifier(kind)
end

function ls.isInterfaceOrTypeLiteralCompletionKeyword(kind)
    return kind == Kind.ReadonlyKeyword
end

function ls.isContextualKeywordInAutoImportableExpressionSpace(keyword)
    return keyword == "abstract" or
        keyword == "async" or
        keyword == "await" or
        keyword == "declare" or
        keyword == "module" or
        keyword == "namespace" or
        keyword == "type" or
        keyword == "satisfies" or
        keyword == "as"
end

function ls.getContextualKeywords(file, contextToken, position)
    local entries = nil
    -- An `AssertClause` can come after an import declaration:
    --  import * from "foo" |
    --  import "foo" |
    -- or after a re-export declaration that has a module specifier:
    --  export { foo } from "foo" |
    -- Source: https://tc39.es/proposal-import-assertions/
    if contextToken ~= nil then
        local parent = contextToken.parent
        local tokenLine = scanner.GetECMALineOfPosition(file, contextToken:End())
        local currentLine = scanner.GetECMALineOfPosition(file, position)
        if (ast.IsImportDeclaration(parent) or
                ast.IsExportDeclaration(parent) and parent:ModuleSpecifier() ~= nil) and
            contextToken == parent:ModuleSpecifier() and
            tokenLine == currentLine then
            entries = core.Append(entries, {
                label = scanner.TokenToString(Kind.AssertKeyword),
                kind = lsproto.CompletionItemKind.Keyword,
                sortText = SortText.GlobalsOrKeywords,
            })
        end
    end
    return entries
end

function LanguageService:getJSCompletionEntries(ctx, file, position, uniqueNames, sortedEntries)
    local _ = ctx
    local nameTable = file:GetNameTable()
    -- Go iterates the map in random order; iterate names sorted for determinism.
    local names = {}
    for name in pairs(nameTable) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local pos = nameTable[name]
        -- Skip identifiers produced only from the current location
        if pos ~= position then
            if not uniqueNames:Has(name) and scanner.IsIdentifierText(name, core.LanguageVariant.Standard) then
                uniqueNames:Add(name)
                sortedEntries = core.Append(sortedEntries, ls.NewCompletionItem({
                    label = name,
                    kind = lsproto.CompletionItemKind.Text,
                    sortText = SortText.JavascriptIdentifiers,
                    commitCharacters = {},
                }, nil))
            end
        end
    end
    return sortedEntries
end

function LanguageService:getOptionalReplacementSpan(location, file)
    -- StringLiteralLike locations are handled separately in stringCompletions.ts
    if location ~= nil and (location.kind == Kind.Identifier or location.kind == Kind.PrivateIdentifier) then
        local start = astnav.GetStartOfNode(location, file, false --[[includeJSDoc]])
        local lspRange, fidelity = self:createLspRangeFromBounds(start, location:End(), file)
        if spanmap.Fidelity_IsExact(fidelity) then
            return lspRange
        end
    end
    return nil
end

function ls.isMemberCompletionKind(kind)
    return kind == CompletionKind.ObjectPropertyDeclaration or
        kind == CompletionKind.MemberLike or
        kind == CompletionKind.PropertyAccess
end

function ls.tryGetFunctionLikeBodyCompletionContainer(contextToken)
    if contextToken == nil then
        return nil
    end

    local prev = nil
    local container = ast.FindAncestorOrQuit(contextToken, function(node)
        if ast.IsClassLike(node) then
            return FindAncestorResult.FindAncestorQuit
        end
        if ast.IsFunctionLikeDeclaration(node) and prev == node:Body() then
            return FindAncestorResult.FindAncestorTrue
        end
        prev = node
        return FindAncestorResult.FindAncestorFalse
    end)
    return container
end

function ls.computeCommitCharactersAndIsNewIdentifier(contextToken, file, position)
    if contextToken == nil then
        return false, ls.allCommitCharacters
    end
    local containingNodeKind = contextToken.parent.kind
    local tokenKind = ls.keywordForNode(contextToken)
    -- Previous token may have been a keyword that was converted to an identifier.
    if tokenKind == Kind.CommaToken then
        -- func( a, |
        -- new C(a, |
        if containingNodeKind == Kind.CallExpression or containingNodeKind == Kind.NewExpression then
            local expression = contextToken.parent:Expression()
            -- func\n(a, |
            if ls.getLineOfPosition(file, expression:End()) ~= ls.getLineOfPosition(file, position) then
                return true, ls.noCommaCommitCharacters
            end
            return true, ls.allCommitCharacters
        -- const x = (a, |
        elseif containingNodeKind == Kind.BinaryExpression then
            return true, ls.noCommaCommitCharacters
        -- constructor( a, | /* public, protected, private keywords are allowed here, so show completion */
        -- var x: (s: string, list|
        -- const obj = { x, |
        elseif containingNodeKind == Kind.Constructor or containingNodeKind == Kind.FunctionType or
            containingNodeKind == Kind.ObjectLiteralExpression then
            return true, ls.emptyCommitCharacters
        -- [a, |
        elseif containingNodeKind == Kind.ArrayLiteralExpression then
            return true, ls.allCommitCharacters
        else
            return false, ls.allCommitCharacters
        end
    elseif tokenKind == Kind.OpenParenToken then
        -- func( |
        -- new C(a|
        if containingNodeKind == Kind.CallExpression or containingNodeKind == Kind.NewExpression then
            local expression = contextToken.parent:Expression()
            -- func\n( |
            if ls.getLineOfPosition(file, expression:End()) ~= ls.getLineOfPosition(file, position) then
                return true, ls.noCommaCommitCharacters
            end
            return true, ls.allCommitCharacters
        -- const x = (a|
        elseif containingNodeKind == Kind.ParenthesizedExpression then
            return true, ls.noCommaCommitCharacters
        -- constructor( |
        -- function F(pred: (a| /* this can become an arrow function, where 'a' is the argument */
        elseif containingNodeKind == Kind.Constructor or containingNodeKind == Kind.ParenthesizedType then
            return true, ls.emptyCommitCharacters
        else
            return false, ls.allCommitCharacters
        end
    elseif tokenKind == Kind.OpenBracketToken then
        -- [ |
        -- [ | : string ]
        -- [ | : string ]
        -- [ |    /* this can become an index signature */
        if containingNodeKind == Kind.ArrayLiteralExpression or containingNodeKind == Kind.IndexSignature or
            containingNodeKind == Kind.TupleType or containingNodeKind == Kind.ComputedPropertyName then
            return true, ls.allCommitCharacters
        else
            return false, ls.allCommitCharacters
        end
    -- module |
    -- namespace |
    -- import |
    elseif tokenKind == Kind.ModuleKeyword or tokenKind == Kind.NamespaceKeyword or tokenKind == Kind.ImportKeyword then
        return true, ls.emptyCommitCharacters
    elseif tokenKind == Kind.DotToken then
        -- module A.|
        if containingNodeKind == Kind.ModuleDeclaration then
            return true, ls.emptyCommitCharacters
        else
            return false, ls.allCommitCharacters
        end
    elseif tokenKind == Kind.OpenBraceToken then
        -- class A { |
        -- const obj = { |
        if containingNodeKind == Kind.ClassDeclaration or containingNodeKind == Kind.ObjectLiteralExpression then
            return true, ls.emptyCommitCharacters
        else
            return false, ls.allCommitCharacters
        end
    elseif tokenKind == Kind.EqualsToken then
        -- const x = a|
        -- x = a|
        if containingNodeKind == Kind.VariableDeclaration or containingNodeKind == Kind.BinaryExpression then
            return true, ls.allCommitCharacters
        else
            return false, ls.allCommitCharacters
        end
    elseif tokenKind == Kind.TemplateHead then
        -- `aa ${|
        return containingNodeKind == Kind.TemplateExpression, ls.allCommitCharacters
    elseif tokenKind == Kind.TemplateMiddle then
        -- `aa ${10} dd ${|
        return containingNodeKind == Kind.TemplateSpan, ls.allCommitCharacters
    elseif tokenKind == Kind.AsyncKeyword then
        -- const obj = { async c|()
        -- const obj = { async c|
        if containingNodeKind == Kind.MethodDeclaration or containingNodeKind == Kind.ShorthandPropertyAssignment then
            return true, ls.emptyCommitCharacters
        end
        return false, ls.allCommitCharacters
    elseif tokenKind == Kind.AsteriskToken then
        -- const obj = { * c|
        if containingNodeKind == Kind.MethodDeclaration then
            return true, ls.emptyCommitCharacters
        end
        return false, ls.allCommitCharacters
    end

    if ls.isClassMemberCompletionKeyword(tokenKind) then
        return true, ls.emptyCommitCharacters
    end

    return false, ls.allCommitCharacters
end

function ls.keywordForNode(node)
    if ast.IsIdentifier(node) then
        return scanner.IdentifierToKeywordKind(node:AsIdentifier())
    end
    return node.kind
end

-- Finds the first node that "embraces" the position, so that one may
-- accurately aggregate locals from the closest containing scope.
function ls.getScopeNode(initialToken, position, file)
    local scope = initialToken
    while scope ~= nil and not ls.positionBelongsToNode(scope, position, file) do
        scope = scope.parent
    end
    return scope
end

function ls.isSnippetScope(scopeNode)
    local k = scopeNode.kind
    if k == Kind.SourceFile or k == Kind.TemplateExpression or k == Kind.JsxExpression or k == Kind.Block then
        return true
    end
    return ast.IsStatement(scopeNode)
end

-- Determines if a type is exactly the same type resolved by the global 'self', 'global', or 'globalThis'.
function ls.isProbablyGlobalType(t, file, typeChecker)
    -- The type of `self` and `window` is the same in lib.dom.d.ts, but `window` does not exist in
    -- lib.webworker.d.ts, so checking against `self` is also a check against `window` when it exists.
    local selfSymbol = typeChecker:GetGlobalSymbol("self", SymbolFlags.Value, nil --[[diagnostic]])
    if selfSymbol ~= nil and typeChecker:GetTypeOfSymbolAtLocation(selfSymbol, file:AsNode()) == t then
        return true
    end
    local globalSymbol = typeChecker:GetGlobalSymbol("global", SymbolFlags.Value, nil --[[diagnostic]])
    if globalSymbol ~= nil and typeChecker:GetTypeOfSymbolAtLocation(globalSymbol, file:AsNode()) == t then
        return true
    end
    local globalThisSymbol = typeChecker:GetGlobalSymbol("globalThis", SymbolFlags.Value, nil --[[diagnostic]])
    if globalThisSymbol ~= nil and typeChecker:GetTypeOfSymbolAtLocation(globalThisSymbol, file:AsNode()) == t then
        return true
    end
    return false
end

function ls.tryGetTypeLiteralNode(node)
    if node == nil then
        return nil
    end

    local parent = node.parent
    if node.kind == Kind.OpenBraceToken then
        if ast.IsTypeLiteralNode(parent) then
            return parent
        end
    elseif node.kind == Kind.SemicolonToken or node.kind == Kind.CommaToken or node.kind == Kind.Identifier then
        if parent.kind == Kind.PropertySignature and ast.IsTypeLiteralNode(parent.parent) then
            return parent.parent
        end
    end

    return nil
end

function ls.getConstraintOfTypeArgumentProperty(node, typeChecker)
    if node == nil then
        return nil
    end

    if ast.IsTypeNode(node) then
        local constraint = typeChecker:GetTypeArgumentConstraint(node)
        if constraint ~= nil then
            return constraint
        end
    end

    local t = ls.getConstraintOfTypeArgumentProperty(node.parent, typeChecker)
    if t == nil then
        return nil
    end

    local k = node.kind
    if k == Kind.PropertySignature then
        -- Try to get the reparsed node first - we may be in JSDoc.
        local reparsed = ast.GetReparsedNodeForNode(node)
        local symbol = reparsed:Symbol()
        if symbol ~= nil then
            return typeChecker:GetTypeOfPropertyOfContextualType(t, symbol.name)
        end

        -- In some cases, we won't have a corresponding symbol
        -- (e.g. JSDoc types that never get re-attached) so we'll use
        -- the name as declared by the property as a best-effort.
        local name, ok = ast.TryGetTextOfPropertyName(reparsed:Name())
        if ok then
            return typeChecker:GetTypeOfPropertyOfContextualType(t, name)
        end

        return nil
    elseif k == Kind.ColonToken then
        if node.parent.kind == Kind.PropertySignature then
            -- The cursor is at a property value location like `Foo<{ x: | }`.
            -- `t` already refers to the appropriate property type.
            return t
        end
    elseif k == Kind.IntersectionType or k == Kind.TypeLiteral or k == Kind.UnionType then
        return t
    elseif k == Kind.OpenBracketToken then
        return typeChecker:GetElementTypeOfArrayType(t)
    end

    return nil
end

function ls.tryGetObjectLikeCompletionContainer(contextToken, position, file)
    if contextToken == nil then
        return nil
    end

    local parent = contextToken.parent
    local k = contextToken.kind
    -- const x = { |
    -- const x = { a: 0, |
    if k == Kind.OpenBraceToken or k == Kind.CommaToken then
        if ast.IsObjectLiteralExpression(parent) or ast.IsObjectBindingPattern(parent) then
            return parent
        end
    elseif k == Kind.AsteriskToken then
        if ast.IsMethodDeclaration(parent) and ast.IsObjectLiteralExpression(parent.parent) then
            return parent.parent
        end
    elseif k == Kind.AsyncKeyword then
        if ast.IsObjectLiteralExpression(parent.parent) then
            return parent.parent
        end
    elseif k == Kind.Identifier then
        if contextToken:Text() == "async" and ast.IsShorthandPropertyAssignment(parent) then
            return parent.parent
        else
            if ast.IsObjectLiteralExpression(parent.parent) and
                (ast.IsSpreadAssignment(parent) or
                    ast.IsShorthandPropertyAssignment(parent) and
                    ls.getLineOfPosition(file, contextToken:End()) ~= ls.getLineOfPosition(file, position)) then
                return parent.parent
            end
            local ancestorNode = ast.FindAncestor(parent, ast.IsPropertyAssignment)
            if ancestorNode ~= nil and lsutil.GetLastToken(ancestorNode, file) == contextToken and
                ast.IsObjectLiteralExpression(ancestorNode.parent) then
                return ancestorNode.parent
            end
        end
    else
        if parent.parent ~= nil and parent.parent.parent ~= nil and
            (ast.IsMethodDeclaration(parent.parent) or
                ast.IsGetAccessorDeclaration(parent.parent) or
                ast.IsSetAccessorDeclaration(parent.parent)) and
            ast.IsObjectLiteralExpression(parent.parent.parent) then
            return parent.parent.parent
        end
        if ast.IsSpreadAssignment(parent) and ast.IsObjectLiteralExpression(parent.parent) then
            return parent.parent
        end
        local ancestorNode = ast.FindAncestor(parent, ast.IsPropertyAssignment)
        if contextToken.kind ~= Kind.ColonToken and
            ancestorNode ~= nil and lsutil.GetLastToken(ancestorNode, file) == contextToken and
            ast.IsObjectLiteralExpression(ancestorNode.parent) then
            return ancestorNode.parent
        end
    end

    return nil
end

function ls.tryGetObjectLiteralContextualType(node, typeChecker)
    local t = typeChecker:GetContextualType(node, checker.ContextFlags.None)
    if t ~= nil then
        return t
    end

    local parent = ast.WalkUpParenthesizedExpressions(node.parent)
    if ast.IsBinaryExpression(parent) and
        parent:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken and
        node == parent:AsBinaryExpression().left then
        -- Object literal is assignment pattern: ({ | } = x)
        return typeChecker:GetTypeAtLocation(parent)
    end
    if ast.IsExpression(parent) then
        -- f(() => (({ | })));
        return typeChecker:GetContextualType(parent, checker.ContextFlags.None)
    end

    return nil
end

function ls.getPropertiesForObjectExpression(contextualType, completionsType, obj, typeChecker)
    local hasCompletionsType = completionsType ~= nil and completionsType ~= contextualType
    local types
    if contextualType:IsUnion() then
        types = contextualType:Types()
    else
        types = { contextualType }
    end
    local promiseFilteredContextualType = typeChecker:GetUnionType(core.Filter(types, function(t)
        return typeChecker:GetPromisedTypeOfPromise(t) == nil
    end))

    local t
    if hasCompletionsType and completionsType:Flags() & checker.TypeFlags.AnyOrUnknown == 0 then
        t = typeChecker:GetUnionType({ promiseFilteredContextualType, completionsType })
    else
        t = promiseFilteredContextualType
    end

    -- Filter out members whose only declaration is the object literal itself to avoid
    -- self-fulfilling completions like:
    --
    -- function f<T>(x: T) {}
    -- f({ abc/**/: "" }) // `abc` is a member of `T` but only because it declares itself
    local function hasDeclarationOtherThanSelf(member)
        if core.Len(member.declarations) == 0 then
            return true
        end
        return core.Some(member.declarations, function(decl) return decl.parent ~= obj end)
    end

    local properties = ls.getApparentProperties(t, obj, typeChecker)
    if t:IsClass() and ls.containsNonPublicProperties(properties) then
        return nil
    elseif hasCompletionsType then
        return core.Filter(properties, hasDeclarationOtherThanSelf)
    else
        return properties
    end
end

function ls.getApparentProperties(t, node, typeChecker)
    if not t:IsUnion() then
        return typeChecker:GetApparentProperties(t)
    end
    return typeChecker:GetAllPossiblePropertiesOfTypes(core.Filter(t:Types(), function(memberType)
        return not (memberType:Flags() & checker.TypeFlags.Primitive ~= 0 or
            typeChecker:IsArrayLikeType(memberType) or
            typeChecker:IsTypeInvalidDueToUnionDiscriminant(memberType, node) or
            typeChecker:TypeHasCallOrConstructSignatures(memberType) or
            memberType:IsClass() and ls.containsNonPublicProperties(typeChecker:GetApparentProperties(memberType)))
    end))
end

function ls.containsNonPublicProperties(props)
    return core.Some(props, function(p)
        return checker.GetDeclarationModifierFlagsFromSymbol(p) & ModifierFlags.NonPublicAccessibilityModifier ~= 0
    end)
end

-- Filters out members that are already declared in the object literal or binding pattern.
-- Also computes the set of existing members declared by spread assignment.
-- Returns filteredMembers, spreadMemberNames.
function ls.filterObjectMembersList(contextualMemberSymbols, existingMembers, file, position, typeChecker)
    if core.Len(existingMembers) == 0 then
        return contextualMemberSymbols, collections.NewSet()
    end

    local membersDeclaredBySpreadAssignment = collections.NewSet()
    local existingMemberNames = collections.NewSet()
    for _, member in ipairs(existingMembers) do
        -- Ignore omitted expressions for missing members.
        if member.kind ~= Kind.PropertyAssignment and
            member.kind ~= Kind.ShorthandPropertyAssignment and
            member.kind ~= Kind.BindingElement and
            member.kind ~= Kind.MethodDeclaration and
            member.kind ~= Kind.GetAccessor and
            member.kind ~= Kind.SetAccessor and
            member.kind ~= Kind.SpreadAssignment then
            goto continue
        end

        -- If this is the current item we are editing right now, do not filter it out.
        if ls.isCurrentlyEditingNode(member, file, position) then
            goto continue
        end

        do
            local existingName = ""

            if ast.IsSpreadAssignment(member) then
                ls.setMemberDeclaredBySpreadAssignment(member, membersDeclaredBySpreadAssignment, typeChecker)
            elseif ast.IsBindingElement(member) and member:PropertyName() ~= nil then
                -- include only identifiers in completion list
                if member:PropertyName().kind == Kind.Identifier then
                    existingName = member:PropertyName():Text()
                end
            else
                -- TODO: Account for computed property name
                -- NOTE: if one only performs this step when m.name is an identifier,
                -- things like '__proto__' are not filtered out.
                local name = ast.GetNameOfDeclaration(member)
                if name ~= nil and ast.IsPropertyNameLiteral(name) then
                    existingName = name:Text()
                end
            end

            if existingName ~= "" then
                existingMemberNames:Add(existingName)
            end
        end
        ::continue::
    end

    local filteredSymbols = core.Filter(contextualMemberSymbols, function(m)
        return not existingMemberNames:Has(m.name)
    end)

    return filteredSymbols, membersDeclaredBySpreadAssignment
end

function ls.isCurrentlyEditingNode(node, file, position)
    local start = astnav.GetStartOfNode(node, file, false --[[includeJSDoc]])
    return start <= position and position <= node:End()
end

function ls.setMemberDeclaredBySpreadAssignment(declaration, members, typeChecker)
    local expression = declaration:Expression()
    local symbol = typeChecker:GetSymbolAtLocation(expression)
    local t
    if symbol ~= nil then
        t = typeChecker:GetTypeOfSymbolAtLocation(symbol, expression)
    end
    local properties
    if t ~= nil and t:Flags() & checker.TypeFlags.StructuredType ~= 0 then
        properties = t:AsStructuredType():Properties()
    end
    for _, property in ipairs(properties or {}) do
        members:Add(property.name)
    end
end

-- Returns the immediate owning class declaration of a context token,
-- on the condition that one exists and that the context implies completion should be given.
function ls.tryGetConstructorLikeCompletionContainer(contextToken)
    if contextToken == nil then
        return nil
    end

    local parent = contextToken.parent
    if contextToken.kind == Kind.OpenParenToken or contextToken.kind == Kind.CommaToken then
        if ast.IsConstructorDeclaration(parent) then
            return parent
        end
        return nil
    else
        if ls.isConstructorParameterCompletion(contextToken) then
            return parent.parent
        end
    end
    return nil
end

function ls.isConstructorParameterCompletion(node)
    return node.parent ~= nil and ast.IsParameterDeclaration(node.parent) and
        ast.IsConstructorDeclaration(node.parent.parent) and
        (ast.IsParameterPropertyModifier(node.kind) or ast.IsDeclarationName(node))
end

-- Returns the immediate owning class declaration of a context token,
-- on the condition that one exists and that the context implies completion should be given.
function ls.tryGetObjectTypeDeclarationCompletionContainer(file, contextToken, location, position)
    -- class c { method() { } | method2() { } }
    local lk = location.kind
    if lk == Kind.SyntaxList then
        if ast.IsObjectTypeDeclaration(location.parent) then
            return location.parent
        end
        return nil
    elseif lk == Kind.EndOfFile then
        local stmtList = location.parent:StatementList()
        if stmtList ~= nil and core.Len(stmtList.nodes) > 0 and
            ast.IsObjectTypeDeclaration(stmtList.nodes[#stmtList.nodes]) then
            local cls = stmtList.nodes[#stmtList.nodes]
            if astnav.FindChildOfKind(cls, Kind.CloseBraceToken, file) == nil then
                return cls
            end
        end
    elseif lk == Kind.PrivateIdentifier then
        if ast.IsPropertyDeclaration(location.parent) then
            return ast.FindAncestor(location, ast.IsClassLike)
        end
    elseif lk == Kind.Identifier then
        local originalKeywordKind = scanner.IdentifierToKeywordKind(location:AsIdentifier())
        if originalKeywordKind ~= Kind.Unknown then
            return nil
        end
        -- class c { public prop = c| }
        if ast.IsPropertyDeclaration(location.parent) and location.parent:Initializer() == location then
            return nil
        end
        -- class c extends React.Component { a: () => 1\n compon| }
        if ls.isFromObjectTypeDeclaration(location) then
            return ast.FindAncestor(location, ast.IsObjectTypeDeclaration)
        end
    end

    if contextToken == nil then
        return nil
    end

    -- class C { blah; constructor/**/ }
    -- or
    -- class C { blah \n constructor/**/ }
    if location.kind == Kind.ConstructorKeyword or
        (ast.IsIdentifier(contextToken) and ast.IsPropertyDeclaration(contextToken.parent) and ast.IsClassLike(location)) then
        return ast.FindAncestor(contextToken, ast.IsClassLike)
    end

    local ck = contextToken.kind
    -- class c { public prop = | /* global completions */ }
    if ck == Kind.EqualsToken then
        return nil
    -- class c {getValue(): number; | }
    -- class c { method() { } | }
    elseif ck == Kind.SemicolonToken or ck == Kind.CloseBraceToken then
        -- class c { method() { } b| }
        if ls.isFromObjectTypeDeclaration(location) and location.parent:Name() == location then
            return location.parent.parent
        end
        if ast.IsObjectTypeDeclaration(location) then
            return location
        end
        return nil
    -- class c { |
    -- class c {getValue(): number, | }
    elseif ck == Kind.OpenBraceToken or ck == Kind.CommaToken then
        if ast.IsObjectTypeDeclaration(contextToken.parent) then
            return contextToken.parent
        end
        return nil
    else
        if ast.IsObjectTypeDeclaration(location) then
            -- class C extends React.Component { a: () => 1\n| }
            -- class C { prop = ""\n | }
            if ls.getLineOfPosition(file, contextToken:End()) ~= ls.getLineOfPosition(file, position) then
                return location
            end
            local isValidKeyword
            if ast.IsClassLike(contextToken.parent.parent) then
                isValidKeyword = ls.isClassMemberCompletionKeyword
            else
                isValidKeyword = ls.isInterfaceOrTypeLiteralCompletionKeyword
            end

            if isValidKeyword(contextToken.kind) or contextToken.kind == Kind.AsteriskToken or
                ast.IsIdentifier(contextToken) and
                isValidKeyword(scanner.IdentifierToKeywordKind(contextToken:AsIdentifier())) then
                return contextToken.parent.parent
            end
        end

        return nil
    end
end

function ls.isFromObjectTypeDeclaration(node)
    return node.parent ~= nil and ast.IsClassOrTypeElement(node.parent) and ast.IsObjectTypeDeclaration(node.parent.parent)
end

-- Filters out completion suggestions for class elements.
function ls.filterClassMembersList(baseSymbols, existingMembers, classElementModifierFlags, file, position)
    local existingMemberNames = collections.NewSet()
    for _, member in ipairs(existingMembers or {}) do
        -- Ignore omitted expressions for missing members.
        if member.kind ~= Kind.PropertyDeclaration and
            member.kind ~= Kind.MethodDeclaration and
            member.kind ~= Kind.GetAccessor and
            member.kind ~= Kind.SetAccessor then
            goto continue
        end

        -- If this is the current item we are editing right now, do not filter it out
        if ls.isCurrentlyEditingNode(member, file, position) then
            goto continue
        end

        -- Don't filter member even if the name matches if it is declared private in the list.
        if member:ModifierFlags() & ModifierFlags.Private ~= 0 then
            goto continue
        end

        -- Do not filter it out if the static presence doesn't match.
        if ast.IsStatic(member) ~= (classElementModifierFlags & ModifierFlags.Static ~= 0) then
            goto continue
        end

        do
            local existingName = ast.GetPropertyNameForPropertyNameNode(member:Name())
            if existingName ~= "" then
                existingMemberNames:Add(existingName)
            end
        end
        ::continue::
    end

    return core.Filter(baseSymbols, function(propertySymbol)
        return not existingMemberNames:Has(ast.SymbolName(propertySymbol)) and
            core.Len(propertySymbol.declarations) > 0 and
            checker.GetDeclarationModifierFlagsFromSymbol(propertySymbol) & ModifierFlags.Private == 0 and
            not (propertySymbol.valueDeclaration ~= nil and
                ast.IsPrivateIdentifierClassElementDeclaration(propertySymbol.valueDeclaration))
    end)
end

function ls.tryGetContainingJsxElement(contextToken, file)
    if contextToken == nil then
        return nil
    end

    local parent = contextToken.parent
    local k = contextToken.kind
    if k == Kind.GreaterThanToken or k == Kind.LessThanSlashToken or k == Kind.SlashToken or k == Kind.Identifier or
        k == Kind.PropertyAccessExpression or k == Kind.JsxNamespacedName or k == Kind.JsxAttributes or
        k == Kind.JsxAttribute or k == Kind.JsxSpreadAttribute then
        if parent ~= nil and (parent.kind == Kind.JsxSelfClosingElement or parent.kind == Kind.JsxOpeningElement) then
            if contextToken.kind == Kind.GreaterThanToken then
                local precedingToken = astnav.FindPrecedingToken(file, contextToken:Pos())
                if core.Len(parent:TypeArguments()) == 0 or
                    precedingToken ~= nil and precedingToken.kind == Kind.SlashToken then
                    return nil
                end
            end
            return parent
        elseif parent ~= nil and ast.IsJsxNamespacedName(parent) and
            parent.parent ~= nil and
            (parent.parent.kind == Kind.JsxSelfClosingElement or parent.parent.kind == Kind.JsxOpeningElement) then
            return parent.parent
        elseif parent ~= nil and parent.kind == Kind.JsxAttribute then
            -- Currently we parse JsxOpeningLikeElement as:
            --      JsxOpeningLikeElement
            --          attributes: JsxAttributes
            --             properties: NodeArray<JsxAttributeLike>
            return parent.parent.parent
        end
    -- The context token is the closing } or " of an attribute, which means
    -- its parent is a JsxExpression, whose parent is a JsxAttribute,
    -- whose parent is a JsxOpeningLikeElement
    elseif k == Kind.StringLiteral then
        if parent ~= nil and (parent.kind == Kind.JsxAttribute or parent.kind == Kind.JsxSpreadAttribute) then
            -- Currently we parse JsxOpeningLikeElement as:
            --      JsxOpeningLikeElement
            --          attributes: JsxAttributes
            --             properties: NodeArray<JsxAttributeLike>
            return parent.parent.parent
        end
    elseif k == Kind.CloseBraceToken then
        if parent ~= nil and parent.kind == Kind.JsxExpression and
            parent.parent ~= nil and parent.parent.kind == Kind.JsxAttribute then
            -- Currently we parse JsxOpeningLikeElement as:
            --      JsxOpeningLikeElement
            --          attributes: JsxAttributes
            --             properties: NodeArray<JsxAttributeLike>
            --                  each JsxAttribute can have initializer as JsxExpression
            return parent.parent.parent.parent
        end
        if parent ~= nil and parent.kind == Kind.JsxSpreadAttribute then
            -- Currently we parse JsxOpeningLikeElement as:
            --      JsxOpeningLikeElement
            --          attributes: JsxAttributes
            --             properties: NodeArray<JsxAttributeLike>
            return parent.parent.parent
        end
    end

    return nil
end

-- Filters out completion suggestions from 'symbols' according to existing JSX attributes.
-- @returns Symbols to be suggested in a JSX element, barring those whose attributes
-- do not occur at the current position and have not otherwise been typed.
-- Returns filteredMembers, spreadMemberNames.
function ls.filterJsxAttributes(symbols, attributes, file, position, typeChecker)
    local existingNames = collections.NewSet()
    local membersDeclaredBySpreadAssignment = collections.NewSet()
    for _, attr in ipairs(attributes or {}) do
        -- If this is the item we are editing right now, do not filter it out.
        if not ls.isCurrentlyEditingNode(attr, file, position) then
            if attr.kind == Kind.JsxAttribute then
                existingNames:Add(attr:Name():Text())
            elseif ast.IsJsxSpreadAttribute(attr) then
                ls.setMemberDeclaredBySpreadAssignment(attr, membersDeclaredBySpreadAssignment, typeChecker)
            end
        end
    end

    return core.Filter(symbols, function(a) return not existingNames:Has(a.name) end),
        membersDeclaredBySpreadAssignment
end

function ls.isTypeKeywordTokenOrIdentifier(node)
    return ast.IsTypeKeywordToken(node) or
        ast.IsIdentifier(node) and scanner.IdentifierToKeywordKind(node:AsIdentifier()) == Kind.TypeKeyword
end

-- Returns the item defaults for completion items, if that capability is supported.
-- Otherwise, if some item default is not supported by client, sets that property on each item.
-- Go takes `defaultCommitCharacters *[]string`; every Go caller passes a non-nil pointer, so here the
-- parameter is the pointed-to slice (nil meaning an empty slice).
function LanguageService:setItemDefaults(ctx, position, file, items, defaultCommitCharacters, optionalReplacementSpan)
    local itemDefaults = nil
    do
        local commitCharacters = defaultCommitCharacters or {}
        local supportsItemCommitCharacters = ls.clientSupportsItemCommitCharacters(ctx)
        if ls.clientSupportsDefaultCommitCharacters(ctx) and supportsItemCommitCharacters then
            itemDefaults = {
                commitCharacters = commitCharacters,
            }
        elseif supportsItemCommitCharacters then
            for _, item in ipairs(items or {}) do
                if item.commitCharacters == nil then
                    item.commitCharacters = commitCharacters
                end
            end
        end
    end
    if optionalReplacementSpan ~= nil then
        -- Ported from vscode ts extension.
        local end_, fidelity = self:createLspPosition(position, file)
        if not spanmap.Fidelity_IsExact(fidelity) then
            return itemDefaults
        end
        local insertRange = {
            start = optionalReplacementSpan.start,
            end_ = end_,
        }
        if ls.clientSupportsDefaultEditRange(ctx) then
            itemDefaults = itemDefaults or {}
            itemDefaults.editRange = {
                editRangeWithInsertReplace = {
                    insert = insertRange,
                    replace = optionalReplacementSpan,
                },
            }
            for _, item in ipairs(items or {}) do
                -- If `editRange` is set, `insertText` is ignored by the client, so we need to
                -- provide `textEdit` instead.
                if item.insertText ~= nil and item.textEdit == nil then
                    item.textEdit = {
                        insertReplaceEdit = {
                            newText = item.insertText,
                            insert = insertRange,
                            replace = optionalReplacementSpan,
                        },
                    }
                    item.insertText = nil
                end
            end
        elseif ls.clientSupportsItemInsertReplace(ctx) then
            for _, item in ipairs(items or {}) do
                if item.textEdit == nil then
                    local newText = item.insertText
                    if newText == nil then
                        newText = item.label
                    end
                    item.textEdit = {
                        insertReplaceEdit = {
                            newText = newText,
                            insert = insertRange,
                            replace = optionalReplacementSpan,
                        },
                    }
                end
            end
        end
    end

    return itemDefaults
end

function LanguageService:specificKeywordCompletionInfo(ctx, position, file, items, isNewIdentifierLocation,
                                                       optionalReplacementSpan)
    local defaultCommitCharacters = ls.getDefaultCommitCharacters(isNewIdentifierLocation)
    local itemDefaults = self:setItemDefaults(
        ctx,
        position,
        file,
        items,
        defaultCommitCharacters,
        optionalReplacementSpan
    )
    return newCompletionList(false, itemDefaults, items)
end

function LanguageService:getJsxClosingTagCompletion(ctx, location, file, position)
    -- We wanna walk up the tree till we find a JSX closing element.
    local jsxClosingElement = ast.FindAncestorOrQuit(location, function(node)
        local k = node.kind
        if k == Kind.JsxClosingElement then
            return FindAncestorResult.FindAncestorTrue
        elseif k == Kind.LessThanSlashToken or k == Kind.GreaterThanToken or k == Kind.Identifier or
            k == Kind.PropertyAccessExpression then
            return FindAncestorResult.FindAncestorFalse
        else
            return FindAncestorResult.FindAncestorQuit
        end
    end)

    if jsxClosingElement == nil then
        return nil
    end

    -- In the TypeScript JSX element, if such element is not defined. When users query for completion at closing tag,
    -- instead of simply giving unknown value, the completion will return the tag-name of an associated opening-element.
    -- For example:
    --     var x = <div> </ /*1*/
    -- The completion list at "1" will contain "div>" with type any
    -- And at `<div> </ /*1*/ >` (with a closing `>`), the completion list will contain "div".
    -- And at property access expressions `<MainComponent.Child> </MainComponent. /*1*/ >` the completion will
    -- return full closing tag with an optional replacement span
    -- For example:
    --     var x = <MainComponent.Child> </     MainComponent /*1*/  >
    --     var y = <MainComponent.Child> </   /*2*/   MainComponent >
    -- the completion list at "1" and "2" will contain "MainComponent.Child" with a replacement span of closing tag name
    local hasClosingAngleBracket = astnav.FindChildOfKind(jsxClosingElement, Kind.GreaterThanToken, file) ~= nil
    local tagName = jsxClosingElement.parent:AsJsxElement().openingElement:TagName()
    local closingTag = scanner.GetTextOfNode(tagName)
    local fullClosingTag = closingTag .. (hasClosingAngleBracket and "" or ">")
    local optionalReplacementSpan, fidelity = self:createLspRangeFromNode(jsxClosingElement:TagName(), file)
    if not spanmap.Fidelity_IsExact(fidelity) then
        return nil
    end
    local defaultCommitCharacters = ls.getDefaultCommitCharacters(false --[[isNewIdentifierLocation]])

    local lspItem = self:createLSPCompletionItem(
        ctx,
        fullClosingTag, --[[name]]
        "", --[[insertText]]
        "", --[[filterText]]
        SortText.LocationPriority,
        lsutil.ScriptElementKind.ClassElement,
        lsutil.ScriptElementKindModifier.None, --[[kindModifiers]]
        nil, --[[replacementSpan]]
        nil, --[[commitCharacters]]
        nil, --[[labelDetails]]
        file,
        position,
        true, --[[isMemberCompletion]]
        false, --[[isSnippet]]
        false, --[[hasAction]]
        false, --[[preselect]]
        "", --[[source]]
        nil, --[[autoImportEntryData]] -- !!! jsx autoimports
        nil, --[[additionalTextEdits]]
        nil --[[detail]]
    )
    local item = ls.NewCompletionItem(lspItem, nil)
    local items = { item }
    local itemDefaults = self:setItemDefaults(
        ctx,
        position,
        file,
        items,
        defaultCommitCharacters,
        optionalReplacementSpan
    )

    return newCompletionList(false, itemDefaults, items)
end

function LanguageService:createLSPCompletionItem(
    ctx,
    name,
    insertText,
    filterText,
    sortText,
    elementKind,
    kindModifiers,
    replacementSpan,
    commitCharacters,
    labelDetails,
    file,
    position,
    isMemberCompletion,
    isSnippet,
    hasAction,
    preselect,
    source,
    autoImportFix,
    additionalTextEdits,
    detail
)
    local _ = ctx
    local kind = ls.getCompletionsSymbolKind(elementKind)
    local data = {
        fileName = file:OriginalFileName(),
        position = position,
        supplementalFileIndex = ls.supplementalFileIndex(file),
        source = source,
        name = name,
        autoImport = autoImportFix,
        isImportStatementCompletion = false,
    }

    -- Text edit
    local textEdit = nil
    if replacementSpan ~= nil then
        textEdit = {
            textEdit = {
                newText = insertText == "" and name or insertText,
                range = replacementSpan,
            },
        }
    end

    -- Filter text

    -- Ported from vscode ts extension.
    local wordSize, wordStart = ls.getWordLengthAndStart(file, position)
    local dotAccessor = ls.getDotAccessor(file, position - wordSize)
    if filterText == "" then
        filterText = ls.getFilterText(file, position, insertText, name, wordStart, dotAccessor)
    end

    -- Adjustements based on kind modifiers.
    local tags = nil
    -- Copied from vscode ts extension: `MyCompletionItem.constructor`.
    if isMemberCompletion and kindModifiers & lsutil.ScriptElementKindModifier.Optional ~= 0 then
        if insertText == "" then
            insertText = name
        end
        if filterText == "" or isSnippet then
            filterText = name
        end
        name = name .. "?"
    end
    if kindModifiers & lsutil.ScriptElementKindModifier.Deprecated ~= 0 then
        tags = { lsproto.CompletionItemTag.Deprecated }
    end

    -- if hasAction && source != "": !!! adjust label like vscode does
    local _ = hasAction

    -- Client assumes plain text by default.
    local insertTextFormat = nil
    if isSnippet then
        insertTextFormat = lsproto.InsertTextFormat.Snippet
    end

    return {
        label = name,
        labelDetails = labelDetails,
        kind = kind,
        tags = tags,
        detail = detail,
        preselect = ls.boolToPtr(preselect),
        sortText = sortText,
        filterText = ls.strPtrTo(filterText),
        insertText = ls.strPtrTo(insertText),
        insertTextFormat = insertTextFormat,
        textEdit = textEdit,
        commitCharacters = commitCharacters,
        additionalTextEdits = additionalTextEdits,
        data = data,
    }
end

function LanguageService:getLabelCompletionsAtPosition(ctx, node, file, position, optionalReplacementSpan)
    local items = self:getLabelStatementCompletions(ctx, node, file, position)
    if core.Len(items) == 0 then
        return nil
    end
    local defaultCommitCharacters = ls.getDefaultCommitCharacters(false --[[isNewIdentifierLocation]])
    local itemDefaults = self:setItemDefaults(
        ctx,
        position,
        file,
        items,
        defaultCommitCharacters,
        optionalReplacementSpan
    )
    return newCompletionList(false, itemDefaults, items)
end

function LanguageService:getLabelStatementCompletions(ctx, node, file, position)
    local uniques = collections.NewSet()
    local items = nil
    local current = node
    while current ~= nil do
        if ast.IsFunctionLike(current) then
            break
        end
        if ast.IsLabeledStatement(current) then
            local name = current:Label():Text()
            if not uniques:Has(name) then
                uniques:Add(name)
                local lspItem = self:createLSPCompletionItem(
                    ctx,
                    name,
                    "", --[[insertText]]
                    "", --[[filterText]]
                    SortText.LocationPriority,
                    lsutil.ScriptElementKind.Label,
                    lsutil.ScriptElementKindModifier.None, --[[kindModifiers]]
                    nil, --[[replacementSpan]]
                    nil, --[[commitCharacters]]
                    nil, --[[labelDetails]]
                    file,
                    position,
                    false, --[[isMemberCompletion]]
                    false, --[[isSnippet]]
                    false, --[[hasAction]]
                    false, --[[preselect]]
                    "", --[[source]]
                    nil, --[[autoImportEntryData]]
                    nil, --[[additionalTextEdits]]
                    nil --[[detail]]
                )
                items = core.Append(items, ls.NewCompletionItem(lspItem, nil))
            end
        end
        current = current.parent
    end
    return items
end

function ls.isCompletionListBlocker(contextToken, previousToken, location, file, position, typeChecker)
    return ls.isInStringOrRegularExpressionOrTemplateLiteral(contextToken, position) or
        ls.isSolelyIdentifierDefinitionLocation(contextToken, previousToken, file, position, typeChecker) or
        ls.isDotOfNumericLiteral(contextToken, file) or
        ls.isInJsxText(contextToken, location) or
        ast.IsBigIntLiteral(contextToken)
end

function ls.isInStringOrRegularExpressionOrTemplateLiteral(contextToken, position)
    -- To be "in" one of these literals, the position has to be:
    --   1. entirely within the token text.
    --   2. at the end position of an unterminated token.
    --   3. at the end of a regular expression (due to trailing flags like '/foo/g').
    return (ast.IsRegularExpressionLiteral(contextToken) or ast.IsStringTextContainingNode(contextToken)) and
        contextToken.loc:ContainsExclusive(position) or
        position == contextToken:End() and
        (ast.IsUnterminatedLiteral(contextToken) or ast.IsRegularExpressionLiteral(contextToken))
end

-- true if we are certain that the currently edited location must define a new location; false otherwise.
function ls.isSolelyIdentifierDefinitionLocation(contextToken, previousToken, file, position, typeChecker)
    local parent = contextToken.parent
    local containingNodeKind = parent.kind
    local ck = contextToken.kind
    if ck == Kind.CommaToken then
        return containingNodeKind == Kind.VariableDeclaration or
            ls.isVariableDeclarationListButNotTypeArgument(contextToken, file, typeChecker) or
            containingNodeKind == Kind.VariableStatement or
            containingNodeKind == Kind.EnumDeclaration or -- enum a { foo, |
            ls.isFunctionLikeButNotConstructor(containingNodeKind) or
            containingNodeKind == Kind.InterfaceDeclaration or -- interface A<T, |
            containingNodeKind == Kind.ArrayBindingPattern or -- var [x, y|
            containingNodeKind == Kind.TypeAliasDeclaration or -- type Map, K, |
            -- class A<T, |
            -- var C = class D<T, |
            (ast.IsClassLike(parent) and parent:TypeParameterList() ~= nil and
                parent:TypeParameterList():End() >= contextToken:Pos())
    elseif ck == Kind.DotToken then
        return containingNodeKind == Kind.ArrayBindingPattern -- var [.|
    elseif ck == Kind.ColonToken then
        return containingNodeKind == Kind.BindingElement -- var {x :html|
    elseif ck == Kind.OpenBracketToken then
        return containingNodeKind == Kind.ArrayBindingPattern -- var [x|
    elseif ck == Kind.OpenParenToken then
        return containingNodeKind == Kind.CatchClause or ls.isFunctionLikeButNotConstructor(containingNodeKind)
    elseif ck == Kind.OpenBraceToken then
        return containingNodeKind == Kind.EnumDeclaration -- enum a { |
    elseif ck == Kind.LessThanToken then
        return containingNodeKind == Kind.ClassDeclaration or -- class A< |
            containingNodeKind == Kind.ClassExpression or -- var C = class D< |
            containingNodeKind == Kind.InterfaceDeclaration or -- interface A< |
            containingNodeKind == Kind.TypeAliasDeclaration or -- type List< |
            ast.IsFunctionLikeKind(containingNodeKind)
    elseif ck == Kind.StaticKeyword then
        return containingNodeKind == Kind.PropertyDeclaration and
            not ast.IsClassLike(parent.parent)
    elseif ck == Kind.DotDotDotToken then
        return containingNodeKind == Kind.Parameter or
            (parent.parent ~= nil and parent.parent.kind == Kind.ArrayBindingPattern) -- var [...z|
    elseif ck == Kind.PublicKeyword or ck == Kind.PrivateKeyword or ck == Kind.ProtectedKeyword then
        return containingNodeKind == Kind.Parameter and not ast.IsConstructorDeclaration(parent.parent)
    elseif ck == Kind.AsKeyword then
        return containingNodeKind == Kind.ImportSpecifier or
            containingNodeKind == Kind.ExportSpecifier or
            containingNodeKind == Kind.NamespaceImport
    elseif ck == Kind.GetKeyword or ck == Kind.SetKeyword then
        return not ls.isFromObjectTypeDeclaration(contextToken)
    elseif ck == Kind.Identifier then
        if (containingNodeKind == Kind.ImportSpecifier or containingNodeKind == Kind.ExportSpecifier) and
            contextToken == parent:Name() and
            contextToken:Text() == "type" then
            -- import { type | }
            return false
        end
        local ancestorVariableDeclaration = ast.FindAncestor(parent, ast.IsVariableDeclaration)
        if ancestorVariableDeclaration ~= nil and ls.getLineEndOfPosition(file, contextToken:End()) < position then
            -- let a
            -- |
            return false
        end
    elseif ck == Kind.ClassKeyword or ck == Kind.EnumKeyword or ck == Kind.InterfaceKeyword or
        ck == Kind.FunctionKeyword or ck == Kind.VarKeyword or ck == Kind.ImportKeyword or
        ck == Kind.LetKeyword or ck == Kind.ConstKeyword or ck == Kind.InferKeyword then
        return true
    elseif ck == Kind.TypeKeyword then
        -- import { type foo| }
        return containingNodeKind ~= Kind.ImportSpecifier
    elseif ck == Kind.AsteriskToken then
        return ast.IsFunctionLike(parent) and not ast.IsMethodDeclaration(parent)
    end

    local tokenKind = ls.keywordForNode(contextToken)
    -- If the previous token is keyword corresponding to class member completion keyword
    -- there will be completion available here
    if ls.isClassMemberCompletionKeyword(tokenKind) and ls.isFromObjectTypeDeclaration(contextToken) then
        return false
    end

    if ls.isConstructorParameterCompletion(contextToken) then
        -- constructor parameter completion is available only if
        -- - its modifier of the constructor parameter or
        -- - its name of the parameter and not being edited
        -- eg. constructor(a |<- this shouldnt show completion
        if not ast.IsIdentifier(contextToken) or
            ast.IsParameterPropertyModifier(tokenKind) or
            ls.isCurrentlyEditingNode(contextToken, file, position) then
            return false
        end
    end

    -- Previous token may have been a keyword that was converted to an identifier.
    local kw = ls.keywordForNode(contextToken)
    if kw == Kind.AbstractKeyword or kw == Kind.ClassKeyword or kw == Kind.DeclareKeyword or
        kw == Kind.EnumKeyword or kw == Kind.FunctionKeyword or kw == Kind.InterfaceKeyword or kw == Kind.LetKeyword or
        kw == Kind.PrivateKeyword or kw == Kind.ProtectedKeyword or kw == Kind.PublicKeyword or
        kw == Kind.StaticKeyword or kw == Kind.VarKeyword then
        return true
    elseif kw == Kind.AsyncKeyword then
        return ast.IsPropertyDeclaration(contextToken.parent)
    end

    -- If we are inside a class declaration, and `constructor` is totally not present,
    -- but we request a completion manually at a whitespace...
    local ancestorClassLike = ast.FindAncestor(parent, ast.IsClassLike)
    if ancestorClassLike ~= nil and contextToken == previousToken and
        ls.isPreviousPropertyDeclarationTerminated(contextToken, file, position) then
        -- Don't block completions.
        return false
    end

    local ancestorPropertyDeclaration = ast.FindAncestor(parent, ast.IsPropertyDeclaration)
    -- If we are inside a class declaration and typing `constructor` after property declaration...
    if ancestorPropertyDeclaration ~= nil and contextToken ~= previousToken and
        ast.IsClassLike(previousToken.parent.parent) and
        -- And the cursor is at the token...
        position <= previousToken:End() then
        -- If we are sure that the previous property declaration is terminated according to newline or semicolon...
        if ls.isPreviousPropertyDeclarationTerminated(contextToken, file, previousToken:End()) then
            -- Don't block completions.
            return false
        elseif contextToken.kind ~= Kind.EqualsToken and
            -- Should not block: `class C { blah = c/**/ }`
            -- But should block: `class C { blah = somewhat c/**/ }` and `class C { blah: SomeType c/**/ }`
            (ast.IsInitializedProperty(ancestorPropertyDeclaration) or ancestorPropertyDeclaration:Type() ~= nil) then
            return true
        end
    end
    if tokenKind == Kind.ConstKeyword then
        return true
    end
    return ast.IsDeclarationName(contextToken) and
        not ast.IsShorthandPropertyAssignment(parent) and
        not ast.IsJsxAttribute(parent) and
        -- Don't block completions if we're in `class C /**/`, `interface I /**/` or `<T /**/>` ,
        -- because we're *past* the end of the identifier and might want to complete `extends`.
        -- If `contextToken !== previousToken`, this is `class C ex/**/`, `interface I ex/**/` or `<T ex/**/>`.
        not ((ast.IsClassLike(parent) or ast.IsInterfaceDeclaration(parent) or ast.IsTypeParameterDeclaration(parent)) and
            (contextToken ~= previousToken or position > previousToken:End()))
end

function ls.isVariableDeclarationListButNotTypeArgument(node, file, typeChecker)
    return node.parent.kind == Kind.VariableDeclarationList and
        not ls.isPossiblyTypeArgumentPosition(node, file, typeChecker)
end

function ls.isFunctionLikeButNotConstructor(kind)
    return ast.IsFunctionLikeKind(kind) and kind ~= Kind.Constructor
end

function ls.isPreviousPropertyDeclarationTerminated(contextToken, file, position)
    return contextToken.kind ~= Kind.EqualsToken and
        (contextToken.kind == Kind.SemicolonToken or
            ls.getLineOfPosition(file, contextToken:End()) ~= ls.getLineOfPosition(file, position))
end

function ls.isDotOfNumericLiteral(contextToken, file)
    if contextToken.kind == Kind.NumericLiteral then
        local text = string.sub(file:Text(), contextToken:Pos() + 1, contextToken:End())
        local r = core.DecodeLastRune(text)
        return r == string.byte(".")
    end

    return false
end

function ls.isInJsxText(contextToken, location)
    if contextToken.kind == Kind.JsxText then
        return true
    end

    if contextToken.kind == Kind.GreaterThanToken and contextToken.parent ~= nil then
        -- <Component<string> /**/ />
        -- <Component<string> /**/ ><Component>
        -- - contextToken: GreaterThanToken (before cursor)
        -- - location: JsxSelfClosingElement or JsxOpeningElement
        -- - contextToken.parent === location
        if location == contextToken.parent and ast.IsJsxOpeningLikeElement(location) then
            return false
        end

        if contextToken.parent.kind == Kind.JsxOpeningElement then
            -- <div>/**/
            -- - contextToken: GreaterThanToken (before cursor)
            -- - location: JSXElement
            -- - different parents (JSXOpeningElement, JSXElement)
            return location.parent.kind ~= Kind.JsxOpeningElement
        end

        if contextToken.parent.kind == Kind.JsxClosingElement or
            contextToken.parent.kind == Kind.JsxSelfClosingElement then
            return contextToken.parent.parent ~= nil and contextToken.parent.parent.kind == Kind.JsxElement
        end
    end

    return false
end

local function completionCapabilities(ctx)
    return lsproto.GetClientCapabilities(ctx).textDocument.completion
end

local function containsString(xs, s)
    for _, x in ipairs(xs or {}) do
        if x == s then
            return true
        end
    end
    return false
end

function ls.clientSupportsItemLabelDetails(ctx)
    return completionCapabilities(ctx).completionItem.labelDetailsSupport == true
end

function ls.clientSupportsItemSnippet(ctx)
    return completionCapabilities(ctx).completionItem.snippetSupport == true
end

function ls.clientSupportsItemCommitCharacters(ctx)
    return completionCapabilities(ctx).completionItem.commitCharactersSupport == true
end

function ls.clientSupportsItemInsertReplace(ctx)
    return completionCapabilities(ctx).completionItem.insertReplaceSupport == true
end

function ls.clientSupportsDefaultCommitCharacters(ctx)
    return containsString(completionCapabilities(ctx).completionList.itemDefaults, "commitCharacters")
end

function ls.clientSupportsDefaultEditRange(ctx)
    return containsString(completionCapabilities(ctx).completionList.itemDefaults, "editRange")
end

-- argumentInfoForCompletions: { invocation, argumentIndex, argumentCount }
function ls.getArgumentInfoForCompletions(node, position, file, typeChecker)
    local info = ls.getImmediatelyContainingArgumentInfo(node, position, file, typeChecker)
    if info == nil or info.isTypeParameterList or info.invocation.callInvocation == nil then
        return nil
    end
    return {
        invocation = info.invocation.callInvocation.node,
        argumentIndex = info.argumentIndex,
        argumentCount = info.argumentCount,
    }
end

-- Special values for `CompletionInfo['source']` used to disambiguate completion items with the same
-- `name` (ls.SourceThisProperty, ls.SourceClassMemberSnippet, ls.SourceTypeOnlyAlias,
-- ls.SourceObjectLiteralMethodSnippet, ls.SourceSwitchCases, ls.SourceObjectLiteralMemberWithComma)
-- come from consts_generated.lua.
