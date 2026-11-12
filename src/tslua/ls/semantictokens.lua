local ls = require("tslua.ls")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local SemanticMeaning = ast.SemanticMeaning
local TypeFlags = checker.TypeFlags
local SignatureKind = checker.SignatureKind

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

local function compare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

local function containsString(xs, s)
    for _, x in ipairs(xs or {}) do
        if x == s then
            return true
        end
    end
    return false
end

local SemanticTokenType = lsproto.SemanticTokenType
local SemanticTokenModifier = lsproto.SemanticTokenModifier

-- tokenTypes defines the order of token types for encoding
ls.tokenTypes = {
    SemanticTokenType.Namespace,
    SemanticTokenType.Class,
    SemanticTokenType.Enum,
    SemanticTokenType.Interface,
    SemanticTokenType.Struct,
    SemanticTokenType.TypeParameter,
    SemanticTokenType.Type,
    SemanticTokenType.Parameter,
    SemanticTokenType.Variable,
    SemanticTokenType.Property,
    SemanticTokenType.EnumMember,
    SemanticTokenType.Decorator,
    SemanticTokenType.Event,
    SemanticTokenType.Function,
    SemanticTokenType.Method,
    SemanticTokenType.Macro,
    SemanticTokenType.Label,
    SemanticTokenType.Comment,
    SemanticTokenType.String,
    SemanticTokenType.Keyword,
    SemanticTokenType.Number,
    SemanticTokenType.Regexp,
    SemanticTokenType.Operator,
}

-- tokenModifiers defines the order of token modifiers for encoding
ls.tokenModifiers = {
    SemanticTokenModifier.Declaration,
    SemanticTokenModifier.Definition,
    SemanticTokenModifier.Readonly,
    SemanticTokenModifier.Static,
    SemanticTokenModifier.Deprecated,
    SemanticTokenModifier.Abstract,
    SemanticTokenModifier.Async,
    SemanticTokenModifier.Modification,
    SemanticTokenModifier.Documentation,
    SemanticTokenModifier.DefaultLibrary,
    "local",
}

ls.tokenType = {
    Namespace = 0,
    Class = 1,
    Enum = 2,
    Interface = 3,
    Struct = 4,
    TypeParameter = 5,
    Type = 6,
    Parameter = 7,
    Variable = 8,
    Property = 9,
    EnumMember = 10,
    Decorator = 11,
    Event = 12,
    Function = 13,
    Method = 14, -- Previously called "member" in TypeScript
    Macro = 15,
    Label = 16,
    Comment = 17,
    String = 18,
    Keyword = 19,
    Number = 20,
    Regexp = 21,
    Operator = 22,
}
local tokenType = ls.tokenType

ls.tokenModifier = {
    Declaration = 1 << 0,
    Definition = 1 << 1,
    Readonly = 1 << 2,
    Static = 1 << 3,
    Deprecated = 1 << 4,
    Abstract = 1 << 5,
    Async = 1 << 6,
    Modification = 1 << 7,
    Documentation = 1 << 8,
    DefaultLibrary = 1 << 9,
    Local = 1 << 10,
}
local tokenModifier = ls.tokenModifier

-- SemanticTokensLegend returns the legend describing the token types and modifiers.
-- It filters the legend to only include types and modifiers that the client supports,
-- as indicated by clientCapabilities.
function ls.SemanticTokensLegend(clientCapabilities)
    local types = {}
    for _, t in ipairs(ls.tokenTypes) do
        if containsString(clientCapabilities.tokenTypes, t) then
            types[#types + 1] = t
        end
    end
    local modifiers = {}
    for _, m in ipairs(ls.tokenModifiers) do
        if containsString(clientCapabilities.tokenModifiers, m) then
            modifiers[#modifiers + 1] = m
        end
    end
    return {
        tokenTypes = types,
        tokenModifiers = modifiers,
    }
end

function LanguageService:ProvideSemanticTokens(ctx, documentURI)
    local program, file = self:getProgramAndFile(documentURI)

    local supplemental = file:SupplementalSourceFiles()
    local files = { file }
    for _, f in ipairs(supplemental or {}) do
        files[#files + 1] = f
    end
    local tokens = {}
    for _, projection in ipairs(files) do
        local c, done = program:GetTypeCheckerForFile(ctx, projection)
        for _, token in ipairs(self:collectSemanticTokens(ctx, c, projection, program) or {}) do
            token.file = projection
            tokens[#tokens + 1] = token
        end
        done()
    end
    ls.sortSemanticTokens(tokens, self.converters)

    if #tokens == 0 then
        return {}, nil
    end

    -- Convert to LSP format (relative encoding)
    local encoded = ls.encodeSemanticTokens(ctx, tokens, self.converters)

    return {
        semanticTokens = {
            data = encoded,
        },
    }, nil
end

local function semanticTokenKey(token)
    return tostring(ast.GetNodeId(token.node)) .. ":" .. tostring(token.file ~= nil and ast.GetNodeId(token.file) or 0) ..
        ":" .. tostring(token.tokenType) .. ":" .. tostring(token.tokenModifier)
end

function LanguageService:ProvideSemanticTokensRange(ctx, documentURI, rng)
    local program, file = self:getProgramAndFile(documentURI)

    local mappedRanges = lsconv.FromLSPRangeIntersectingForSourceFile(self.converters, file, rng, spanmap.Feature.SemanticTokens)
    local tokens = {}
    local seen = collections.NewSet()
    for _, mapped in ipairs(mappedRanges or {}) do
        local projection = mapped.script
        local c, done = program:GetTypeCheckerForFile(ctx, projection)
        for _, token in ipairs(self:collectSemanticTokensInRange(ctx, c, projection, program, mapped.span:Pos(), mapped.span:End()) or {}) do
            token.file = projection
            if seen:AddIfAbsent(semanticTokenKey(token)) then
                tokens[#tokens + 1] = token
            end
        end
        done()
    end
    ls.sortSemanticTokens(tokens, self.converters)

    if #tokens == 0 then
        return {}, nil
    end

    -- Convert to LSP format (relative encoding)
    local encoded = ls.encodeSemanticTokens(ctx, tokens, self.converters)

    return {
        semanticTokens = {
            data = encoded,
        },
    }, nil
end

function ls.sortSemanticTokens(tokens, converters)
    core.SortFunc(tokens, function(a, b)
        local aRange = ls.semanticTokenLSPRange(a, converters)
        local bRange = ls.semanticTokenLSPRange(b, converters)
        local result = compare(aRange.start.line, bRange.start.line)
        if result ~= 0 then
            return result
        end
        result = compare(aRange.start.character, bRange.start.character)
        if result ~= 0 then
            return result
        end
        result = compare(a.file:Path(), b.file:Path())
        if result ~= 0 then
            return result
        end
        return compare(a.node:Pos(), b.node:Pos())
    end)
end

function ls.semanticTokenLSPRange(token, converters)
    local start = scanner.GetTokenPosOfNode(token.node, token.file, false)
    return converters:ToLSPRangeForFeature(token.file, core.NewTextRange(start, token.node:End()), spanmap.Feature.SemanticTokens)
end

-- semanticToken: { node, file, tokenType, tokenModifier }

function LanguageService:collectSemanticTokens(ctx, c, file, program)
    return self:collectSemanticTokensInRange(ctx, c, file, program, file:Pos(), file:End())
end

function LanguageService:collectSemanticTokensInRange(ctx, c, file, program, spanStart, spanEnd)
    local tokens = {}

    local inJSXElement = false

    local visit
    visit = function(node)
        -- Check for cancellation
        if ctxErr(ctx) then
            return false
        end

        if node == nil then
            return false
        end
        if node.flags & NodeFlags.Reparsed ~= 0 then
            return false
        end
        local nodeEnd = node:End()
        if node:Pos() >= spanEnd or nodeEnd <= spanStart then
            return false
        end

        local prevInJSXElement = inJSXElement
        if ast.IsJsxElement(node) or ast.IsJsxSelfClosingElement(node) then
            inJSXElement = true
        elseif ast.IsJsxExpression(node) then
            inJSXElement = false
        end

        if ast.IsIdentifier(node) and node:Text() ~= "" and not inJSXElement and not ls.isInImportClause(node) and not ls.isInfinityOrNaNString(node:Text()) then
            local symbol = c:GetSymbolAtLocation(node)
            if symbol ~= nil then
                -- Resolve aliases
                if symbol.flags & SymbolFlags.Alias ~= 0 then
                    symbol = c:GetAliasedSymbol(symbol)
                end

                local tt, ok = ls.classifySymbol(symbol, ls.getMeaningFromLocation(node))
                if ok then
                    local tm = 0

                    -- Check if this is a declaration
                    local parent = node.parent
                    if parent ~= nil then
                        local parentIsDeclaration = ast.IsBindingElement(parent) or ls.tokenFromDeclarationMapping(parent.kind) == tt
                        if parentIsDeclaration and parent:Name() == node then
                            tm = tm | tokenModifier.Declaration
                        end
                    end

                    -- Property declaration in constructor: reclassify parameters as properties in property access context
                    if tt == tokenType.Parameter and ast.IsRightSideOfQualifiedNameOrPropertyAccess(node) then
                        tt = tokenType.Property
                    end

                    -- Type-based reclassification
                    tt = ls.reclassifyByType(c, node, tt)

                    -- Get the value declaration to check modifiers
                    local decl = symbol.valueDeclaration
                    if decl ~= nil then
                        local modifiers = ast.GetCombinedModifierFlags(decl)
                        local nodeFlags = ast.GetCombinedNodeFlags(decl)

                        if modifiers & ModifierFlags.Static ~= 0 then
                            tm = tm | tokenModifier.Static
                        end
                        if modifiers & ModifierFlags.Async ~= 0 then
                            tm = tm | tokenModifier.Async
                        end
                        if tt ~= tokenType.Class and tt ~= tokenType.Interface then
                            if (modifiers & ModifierFlags.Readonly ~= 0) or (nodeFlags & NodeFlags.Const ~= 0) or (symbol.flags & SymbolFlags.EnumMember ~= 0) then
                                tm = tm | tokenModifier.Readonly
                            end
                        end
                        if (tt == tokenType.Variable or tt == tokenType.Function) and ls.isLocalDeclaration(decl, file) then
                            tm = tm | tokenModifier.Local
                        end
                        local declSourceFile = ast.GetSourceFileOfNode(decl)
                        if declSourceFile ~= nil and program:IsSourceFileDefaultLibrary(declSourceFile:Path()) then
                            tm = tm | tokenModifier.DefaultLibrary
                        end
                    elseif symbol.declarations ~= nil then
                        for _, d in ipairs(symbol.declarations) do
                            local declSourceFile = ast.GetSourceFileOfNode(d)
                            if declSourceFile ~= nil and program:IsSourceFileDefaultLibrary(declSourceFile:Path()) then
                                tm = tm | tokenModifier.DefaultLibrary
                                break
                            end
                        end
                    end

                    tokens[#tokens + 1] = {
                        node = node,
                        file = nil,
                        tokenType = tt,
                        tokenModifier = tm,
                    }
                end
            end
        end

        node:ForEachChild(visit)
        inJSXElement = prevInJSXElement
        return false
    end

    visit(file)

    -- Check for cancellation after collection
    if ctxErr(ctx) then
        return nil
    end

    return tokens
end

function ls.classifySymbol(symbol, meaning)
    local flags = symbol.flags
    if flags & SymbolFlags.Class ~= 0 then
        return tokenType.Class, true
    end
    if flags & SymbolFlags.Enum ~= 0 then
        return tokenType.Enum, true
    end
    if flags & SymbolFlags.TypeAlias ~= 0 then
        return tokenType.Type, true
    end
    if flags & SymbolFlags.Interface ~= 0 then
        if meaning & SemanticMeaning.Type ~= 0 then
            return tokenType.Interface, true
        end
    end
    if flags & SymbolFlags.TypeParameter ~= 0 then
        return tokenType.TypeParameter, true
    end

    -- Check the value declaration
    local decl = symbol.valueDeclaration
    if decl == nil and core.Len(symbol.declarations) > 0 then
        decl = symbol.declarations[1]
    end
    if decl ~= nil then
        if ast.IsBindingElement(decl) then
            decl = ls.getDeclarationForBindingElement(decl)
        end
        local tt = ls.tokenFromDeclarationMapping(decl.kind)
        if tt >= 0 then
            return tt, true
        end
    end

    return 0, false
end

local declarationTokenTypes = {
    [Kind.VariableDeclaration] = tokenType.Variable,
    [Kind.Parameter] = tokenType.Parameter,
    [Kind.PropertyDeclaration] = tokenType.Property,
    [Kind.ModuleDeclaration] = tokenType.Namespace,
    [Kind.EnumDeclaration] = tokenType.Enum,
    [Kind.EnumMember] = tokenType.EnumMember,
    [Kind.ClassDeclaration] = tokenType.Class,
    [Kind.ClassExpression] = tokenType.Class,
    [Kind.MethodDeclaration] = tokenType.Method,
    [Kind.FunctionDeclaration] = tokenType.Function,
    [Kind.FunctionExpression] = tokenType.Function,
    [Kind.MethodSignature] = tokenType.Method,
    [Kind.GetAccessor] = tokenType.Property,
    [Kind.SetAccessor] = tokenType.Property,
    [Kind.PropertySignature] = tokenType.Property,
    [Kind.InterfaceDeclaration] = tokenType.Interface,
    [Kind.TypeAliasDeclaration] = tokenType.Type,
    [Kind.TypeParameter] = tokenType.TypeParameter,
    [Kind.PropertyAssignment] = tokenType.Property,
    [Kind.ShorthandPropertyAssignment] = tokenType.Property,
}

function ls.tokenFromDeclarationMapping(kind)
    local tt = declarationTokenTypes[kind]
    if tt ~= nil then
        return tt
    end
    return -1
end

function ls.reclassifyByType(c, node, tt)
    -- Type-based reclassification for variables, properties, and parameters
    if tt == tokenType.Variable or tt == tokenType.Property or tt == tokenType.Parameter then
        local typ = c:GetTypeAtLocation(node)
        if typ ~= nil then
            local function test(condition)
                if condition(typ) then
                    return true
                end
                if typ:Flags() & TypeFlags.Union ~= 0 then
                    if core.Some(typ:AsUnionType():Types(), condition) then
                        return true
                    end
                end
                return false
            end

            -- Check for constructor signatures (class-like)
            if tt ~= tokenType.Parameter and test(function(t)
                return core.Len(c:GetSignaturesOfType(t, SignatureKind.Construct)) > 0
            end) then
                return tokenType.Class
            end

            -- Check for call signatures (function-like)
            -- Must have call signatures AND (no properties OR be used in call context)
            local hasCallSignatures = test(function(t)
                return core.Len(c:GetSignaturesOfType(t, SignatureKind.Call)) > 0
            end)
            if hasCallSignatures then
                local hasNoProperties = not test(function(t)
                    local objType = t:AsObjectType()
                    return objType ~= nil and core.Len(objType:Properties()) > 0
                end)
                if hasNoProperties or ls.isExpressionInCallExpression(node) then
                    if tt == tokenType.Property then
                        return tokenType.Method
                    end
                    return tokenType.Function
                end
            end
        end
    end
    return tt
end

function ls.isLocalDeclaration(decl, sourceFile)
    if ast.IsBindingElement(decl) then
        decl = ls.getDeclarationForBindingElement(decl)
    end
    if ast.IsVariableDeclaration(decl) then
        local parent = decl.parent
        -- Check if this is a catch clause parameter
        if parent ~= nil and ast.IsCatchClause(parent) then
            return ast.GetSourceFileOfNode(decl) == sourceFile
        end
        if parent ~= nil and ast.IsVariableDeclarationList(parent) then
            local grandparent = parent.parent
            if grandparent ~= nil then
                local greatGrandparent = grandparent.parent
                return (not ast.IsSourceFile(greatGrandparent) or ast.IsCatchClause(grandparent)) and
                    ast.GetSourceFileOfNode(decl) == sourceFile
            end
        end
    elseif ast.IsFunctionDeclaration(decl) then
        local parent = decl.parent
        return parent ~= nil and not ast.IsSourceFile(parent) and ast.GetSourceFileOfNode(decl) == sourceFile
    end
    return false
end

function ls.getDeclarationForBindingElement(element)
    while true do
        local parent = element.parent
        if parent ~= nil and ast.IsBindingPattern(parent) then
            local grandparent = parent.parent
            if grandparent ~= nil and ast.IsBindingElement(grandparent) then
                element = grandparent
                goto continue
            end
            return parent.parent
        end
        do
            return element
        end
        ::continue::
    end
end

function ls.isInImportClause(node)
    local parent = node.parent
    return parent ~= nil and (ast.IsImportClause(parent) or ast.IsImportSpecifier(parent) or ast.IsNamespaceImport(parent))
end

function ls.isExpressionInCallExpression(node)
    while ast.IsRightSideOfQualifiedNameOrPropertyAccess(node) do
        node = node.parent
    end
    local parent = node.parent
    return parent ~= nil and ast.IsCallExpression(parent) and parent:Expression() == node
end

function ls.isInfinityOrNaNString(text)
    return text == "Infinity" or text == "NaN"
end

-- encodeSemanticTokens encodes tokens into the LSP format using relative positioning.
-- It filters tokens based on client capabilities, only including types and modifiers that the client supports.
function ls.encodeSemanticTokens(ctx, tokens, converters)
    -- Build mapping from server token types/modifiers to client indices
    local typeMapping = {}
    local modifierMapping = {}

    local clientCapabilities = lsproto.GetClientCapabilities(ctx).textDocument.semanticTokens

    -- Map server token types to client-supported indices
    local clientIdx = 0
    for i1, serverType in ipairs(ls.tokenTypes) do
        if containsString(clientCapabilities.tokenTypes, serverType) then
            typeMapping[i1 - 1] = clientIdx
            clientIdx = clientIdx + 1
        end
    end

    -- Map server token modifiers to client-supported bit positions
    local clientBit = 0
    for _, serverModifier in ipairs(ls.tokenModifiers) do
        if containsString(clientCapabilities.tokenModifiers, serverModifier) then
            modifierMapping[serverModifier] = clientBit
            clientBit = clientBit + 1
        end
    end

    -- Each token encodes 5 uint32 values: deltaLine, deltaChar, length, tokenType, tokenModifiers
    local encoded = {}
    local prevLine = 0
    local prevChar = 0

    for _, token in ipairs(tokens) do
        -- Skip tokens with types not supported by the client
        local clientTypeIdx = typeMapping[token.tokenType]
        if clientTypeIdx == nil then
            goto continue
        end

        do
            -- Map modifiers to client-supported bit mask
            local clientModifierMask = 0
            for i1, serverModifier in ipairs(ls.tokenModifiers) do
                if token.tokenModifier & (1 << (i1 - 1)) ~= 0 then
                    local bit = modifierMapping[serverModifier]
                    if bit ~= nil then
                        clientModifierMask = clientModifierMask | (1 << bit)
                    end
                end
            end

            -- Semantic tokens must describe one concrete source segment; synthesized and cross-segment
            -- tokens do not identify a coherent token in the original text.
            local lspRange, fidelity = ls.semanticTokenLSPRange(token, converters)
            if not spanmap.Fidelity_IsExact(fidelity) then
                goto continue
            end
            local startPos = lspRange.start
            local endPos = lspRange.end_

            -- Length is the character difference when on the same line
            local tokenLength
            if startPos.line == endPos.line then
                tokenLength = endPos.character - startPos.character
            else
                error(string.format("semantic tokens: token spans multiple lines: start=(%d,%d) end=(%d,%d) for token at offset %d",
                    startPos.line, startPos.character, endPos.line, endPos.character, token.node:Pos()), 0)
            end

            local line = startPos.line
            local char = startPos.character

            -- Multiple virtual projections can describe the same original token; LSP requires one entry per
            -- start position, so retain the first after sorting.
            if #encoded > 0 and line == prevLine and char == prevChar then
                goto continue
            end
            if #encoded > 0 and (line < prevLine or line == prevLine and char < prevChar) then
                error(string.format("semantic tokens: positions must be strictly increasing: prev=(%d,%d) current=(%d,%d) for token at offset %d",
                    prevLine, prevChar, line, char, token.node:Pos()), 0)
            end

            -- Encode as: [deltaLine, deltaChar, length, tokenType, tokenModifiers]
            local deltaLine = line - prevLine
            local deltaChar
            if deltaLine == 0 then
                deltaChar = char - prevChar
            else
                deltaChar = char
            end

            encoded[#encoded + 1] = deltaLine
            encoded[#encoded + 1] = deltaChar
            encoded[#encoded + 1] = tokenLength
            encoded[#encoded + 1] = clientTypeIdx
            encoded[#encoded + 1] = clientModifierMask

            prevLine = line
            prevChar = char
        end
        ::continue::
    end

    return encoded
end
