local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local nodebuilder = require("tslua.nodebuilder")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local SemanticMeaning = ast.SemanticMeaning
local TypeFlags = checker.TypeFlags
local TypeFormatFlags = checker.TypeFormatFlags
local SymbolFormatFlags = checker.SymbolFormatFlags
local SignatureFlags = checker.SignatureFlags
local SignatureKind = checker.SignatureKind

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

local function contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

-- Go strings.Index (0-based, -1 if absent)
local function indexOf(s, sub)
    local i = string.find(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end

local function isInSet(set, b)
    for i = 1, #set do
        if string.byte(set, i) == b then
            return true
        end
    end
    return false
end

-- Go strings.TrimLeft(s, cutset) for an ASCII cutset
local function trimLeftSet(s, set)
    local i = 1
    while i <= #s and isInSet(set, string.byte(s, i)) do
        i = i + 1
    end
    return string.sub(s, i)
end

-- Go strings.TrimRight(s, cutset) for an ASCII cutset
local function trimRightSet(s, set)
    local j = #s
    while j >= 1 and isInSet(set, string.byte(s, j)) do
        j = j - 1
    end
    return string.sub(s, 1, j)
end

local function containsValue(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

ls.symbolFormatFlags = SymbolFormatFlags.WriteTypeParametersOrArguments | SymbolFormatFlags.UseOnlyExternalAliasing | SymbolFormatFlags.AllowAnyNodeKind | SymbolFormatFlags.UseAliasDefinedOutsideCurrentScope
ls.typeFormatFlags = TypeFormatFlags.UseAliasDefinedOutsideCurrentScope | TypeFormatFlags.UseInstantiationExpressions

function LanguageService:ProvideHover(ctx, params)
    local caps = lsproto.GetClientCapabilities(ctx)
    local contentFormat = lsproto.PreferredMarkupKind(caps.textDocument.hover.contentFormat)

    local verbosityLevel = 0
    if params.verbosityLevel ~= nil then
        verbosityLevel = params.verbosityLevel
    end

    local program, file = self:getProgramAndFile(params.textDocument.uri)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, params.position, spanmap.Feature.Hover)
    if core.Len(positions) == 0 or not spanmap.Fidelity_IsSingleSegment(positions[1].fidelity) then
        return {}, nil
    end
    file = positions[1].script
    local position = positions[1].position
    local node = astnav.GetTouchingPropertyName(file, position)
    if ast.IsSourceFile(node) or ast.IsPropertyAccessOrQualifiedName(node) and ls.isInComment(file, position, node) == nil then
        -- Avoid giving quickInfo for the sourceFile as a whole or inside the comment of a/**/.b
        return {}, nil
    end
    local c, done = program:GetTypeCheckerForFile(ctx, file)
    local rangeNode = ls.getNodeForQuickInfo(node)
    local symbol = ls.getSymbolAtLocationForQuickInfo(c, rangeNode)

    -- Always create VerbosityContext for hover so that canExpandSymbol can signal
    -- canIncreaseVerbosity even at Level 0. The nodebuilder also detects expandable
    -- types at Level 0 via shouldExpandType (maxExpansionDepth = 0).
    local maxTruncLen = self:UserPreferences().maximumHoverLength
    if maxTruncLen <= 0 then
        maxTruncLen = 500
    end
    local vc = checker.VerbosityContext_new({
        level = verbosityLevel,
        maxTruncationLength = maxTruncLen,
    })

    local vsCapability = caps.vsSupportsVisualStudioExtensions
    local quickInfo, documentation, vsDocumentation, quickInfoRuns = self:getQuickInfoAndDocumentationForSymbol(c, symbol, rangeNode, contentFormat, vc, vsCapability)
    if quickInfo == "" then
        done()
        return {}, nil
    end
    local rangeFile = ast.GetSourceFileOfNode(rangeNode)
    local textRange = ls.getRangeOfNode(rangeNode, rangeFile, nil --[[endNode]])
    local hoverRange, hoverFidelity = self.converters:ToLSPRangeForFeature(rangeFile, textRange, spanmap.Feature.Hover)

    local content
    if contentFormat == lsproto.MarkupKind.Markdown then
        content = ls.formatQuickInfo(quickInfo) .. documentation
    else
        content = quickInfo .. documentation
    end

    local hover = {
        contents = {
            markupContent = {
                kind = contentFormat,
                value = content,
            },
        },
        canIncreaseVerbosity = false,
    }
    if spanmap.Fidelity_IsSingleSegment(hoverFidelity) then
        hover.range = hoverRange
    end

    if caps.experimental.hoverVerbosityLevel then
        hover.canIncreaseVerbosity = vc.canIncreaseVerbosity and not vc.truncated
    end

    -- Clients that support Visual Studio extensions (e.g. VS itself, when Corsa/Native TS Preview is
    -- enabled) render `_vs_rawContent` in place of `contents`. Without it, VS shows plain markdown
    -- with no symbol icon and no syntax coloring, unlike the legacy TSServer-backed hover path.
    if vsCapability and core.Len(quickInfoRuns) > 0 then
        local kind = lsutil.ScriptElementKind.Keyword
        local modifiers = 0
        if symbol ~= nil then
            -- Resolve aliases to their target before computing the icon kind, so e.g. `import { x }`
            -- shows the icon for whatever `x` actually is (const, function, ...) rather than a
            -- generic alias icon. GetSymbolModifiers already accounts for the alias target itself.
            local iconSymbol = symbol
            if symbol.flags & SymbolFlags.Alias ~= 0 then
                local resolved = c:GetAliasedSymbol(symbol)
                if resolved ~= nil and resolved ~= symbol then
                    iconSymbol = resolved
                end
            end
            kind = lsutil.GetSymbolKind(c, iconSymbol, rangeNode)
            modifiers = lsutil.GetSymbolModifiers(c, symbol)
        end
        local imageId = ls.getVSHoverImageId(kind, modifiers)
        local documentationRuns
        local docText = trimLeftSet(vsDocumentation, "\n")
        if docText ~= "" then
            documentationRuns = { { classificationTypeName = lsproto.ClassificationTypeName.Text, text = docText } }
        end
        hover.vsRawContent = ls.buildVSHoverRawContent(imageId, quickInfoRuns, documentationRuns)
    end

    done()
    return { hover = hover }, nil
end

function LanguageService:getQuickInfoAndDocumentationForSymbol(c, symbol, node, contentFormat, vc, vsCapability)
    local info = ls.getQuickInfoAndDeclarationAtLocation(c, symbol, node, vc, vsCapability, ls.getMeaningFromLocation(node))
    local quickInfo = info.displayParts:String()
    if quickInfo == "" then
        return "", "", "", nil
    end
    local quickInfoRuns = info.displayParts:GetRuns()

    local documentation = ls.getDocumentationForSymbol(self:documentationLocationMapper(spanmap.Feature.Hover), c, symbol, node, info.declaration, contentFormat, false --[[commentOnly]])

    -- VS's rich hover (_vs_rawContent) renders documentation as plain colorized text with no Markdown
    -- parser, so it can't use the tag section (@param/@returns/@example/@see, etc.) that
    -- getDocumentationFromDeclaration renders with '*@tag*' bolding and ```-fenced @example blocks --
    -- those would show up as literal asterisks/backticks. This also matches the legacy TSServer-backed
    -- VS hover (TypeScript-VS's HoverService.cs), which only ever surfaced the JSDoc summary
    -- (TSServer's quickinfo `documentation`) and never included the tag section at all (TSServer
    -- exposes tags via a separate `tags` field that legacy VS hover never read). So request
    -- comment-only, plain-text documentation for the VS path instead of reusing `documentation`.
    local vsDocumentation = ""
    if vsCapability then
        vsDocumentation = ls.getDocumentationForSymbol(self:documentationLocationMapper(spanmap.Feature.Hover), c, symbol, node, info.declaration, lsproto.MarkupKind.PlainText, true --[[commentOnly]])
    end

    return quickInfo, documentation, vsDocumentation, quickInfoRuns
end

-- getDocumentationForSymbol tries each documentation source in turn (call-signature documentation,
-- declaration JSDoc, root-symbol JSDoc, alias target JSDoc) and returns the first non-empty result,
-- formatted for contentFormat. commentOnly restricts the result to the JSDoc summary, excluding the
-- @tag section.
-- documentationLocationMapper: function(file, fileRange) -> lsproto.Location, spanmap.Fidelity

function LanguageService:documentationLocationMapper(feature)
    return function(file, fileRange)
        return self:sourceFileRangeToLSPLocationForFeature(file, fileRange, feature)
    end
end

function ls.getDocumentationForSymbol(getMappedLocation, c, symbol, node, declaration, contentFormat, commentOnly)
    local documentation = ls.documentationFromSignature(getMappedLocation, c, symbol, ls.getCallOrNewExpression(node), node, contentFormat, commentOnly)
    if documentation ~= "" then
        return documentation
    end

    documentation = ls.documentationFromRootSymbols(getMappedLocation, c, symbol, node, contentFormat, commentOnly)
    if documentation ~= "" then
        return documentation
    end

    documentation = ls.getDocumentationFromDeclaration(getMappedLocation, c, symbol, declaration, node, contentFormat, commentOnly)
    if documentation ~= "" then
        return documentation
    end

    return ls.documentationFromAlias(getMappedLocation, c, symbol, node, contentFormat, commentOnly)
end

function ls.documentationFromSignature(getMappedLocation, c, symbol, node, location, contentFormat, commentOnly)
    if node == nil then
        return ""
    end
    local signature = c:GetResolvedSignature(node)
    if signature == nil then
        return ""
    end
    local declaration = signature:Declaration()
    if declaration == nil then
        return ""
    end
    if ast.IsCallSignatureDeclaration(declaration) or ast.IsConstructSignatureDeclaration(declaration) then
        return ls.getDocumentationFromDeclaration(getMappedLocation, c, symbol, declaration, location, contentFormat, commentOnly)
    end
    return ""
end

function ls.documentationFromAlias(getMappedLocation, c, symbol, node, contentFormat, commentOnly)
    if symbol == nil or symbol.flags & SymbolFlags.Alias == 0 then
        return ""
    end

    local aliasedSymbol = c:GetAliasedSymbol(symbol)
    if aliasedSymbol == nil or aliasedSymbol == c:GetUnknownSymbol() then
        return ""
    end

    local candidates = { aliasedSymbol }
    if aliasedSymbol.exportSymbol ~= nil then
        candidates[#candidates + 1] = aliasedSymbol.exportSymbol
    end

    for _, candidate in ipairs(candidates) do
        local aliasedDeclaration = core.OrElse(candidate.valueDeclaration, core.FirstOrNil(candidate.declarations))
        if aliasedDeclaration ~= nil then
            local documentation = ls.getDocumentationFromDeclaration(getMappedLocation, c, candidate, aliasedDeclaration, node, contentFormat, commentOnly)
            if documentation ~= "" then
                return documentation
            end
        end
    end

    return ""
end

function ls.documentationFromRootSymbols(getMappedLocation, c, symbol, node, contentFormat, commentOnly)
    if symbol == nil then
        return ""
    end

    local rootSymbols = c:GetRootSymbols(symbol)
    if core.Len(rootSymbols) <= 1 then
        return ""
    end

    local docs
    for _, rootSymbol in ipairs(rootSymbols) do
        local declarations = rootSymbol.declarations
        if core.Len(declarations) == 0 and rootSymbol.valueDeclaration ~= nil then
            declarations = { rootSymbol.valueDeclaration }
        end
        for _, declaration in ipairs(declarations or {}) do
            local documentation = ls.getDocumentationFromDeclaration(getMappedLocation, c, rootSymbol, declaration, node, contentFormat, commentOnly)
            if documentation ~= "" then
                docs = core.AppendIfUnique(docs, documentation)
            end
        end
    end
    return table.concat(docs or {}, "\n")
end

function ls.getDocumentationFromDeclaration(getMappedLocation, c, symbol, declaration, location, contentFormat, commentOnly)
    if declaration == nil then
        return ""
    end
    local isMarkdown = contentFormat == lsproto.MarkupKind.Markdown
    local b = core.NewStringBuilder()
    local jsdoc = ls.getJSDocOrTag(c, declaration, collections.NewSet())
    if jsdoc ~= nil and not (declaration.flags & NodeFlags.Reparsed == 0 and ls.containsTypedefTag(jsdoc)) then
        ls.writeComments(getMappedLocation, b, c, jsdoc:Comments(), isMarkdown)
        if jsdoc.kind == Kind.JSDoc and not commentOnly then
            local tags = jsdoc:AsJSDoc().tags
            if tags ~= nil then
                for _, tag in ipairs(tags.nodes) do
                    if tag.kind == Kind.JSDocTypeTag or tag.kind == Kind.JSDocTypedefTag or tag.kind == Kind.JSDocCallbackTag then
                        goto continue
                    end
                    b:WriteString("\n\n")
                    if isMarkdown then
                        b:WriteString("*@")
                        b:WriteString(tag:TagName():Text())
                        b:WriteString("*")
                    else
                        b:WriteString("@")
                        b:WriteString(tag:TagName():Text())
                    end
                    if tag.kind == Kind.JSDocParameterTag or tag.kind == Kind.JSDocPropertyTag then
                        ls.writeOptionalEntityName(b, tag:Name())
                    elseif tag.kind == Kind.JSDocAugmentsTag then
                        ls.writeOptionalEntityName(b, tag:ClassName())
                    elseif tag.kind == Kind.JSDocTemplateTag then
                        for i1, tp in ipairs(tag:TypeParameters() or {}) do
                            if i1 ~= 1 then
                                b:WriteString(",")
                            end
                            ls.writeOptionalEntityName(b, tp:Name())
                        end
                    end
                    do
                        local comments = tag:Comments()
                        if tag.kind == Kind.JSDocUnknownTag and tag:TagName():Text() == "example" then
                            local commentText = scanner.GetTextOfJSDocComment(tag:CommentList())
                            if hasPrefix(commentText, "<caption>") then
                                local captionEnd = indexOf(commentText, "</caption>")
                                if captionEnd > 0 then
                                    b:WriteString(" — ")
                                    b:WriteString(string.sub(commentText, #"<caption>" + 1, captionEnd))
                                    commentText = string.sub(commentText, captionEnd + #"</caption>" + 1)
                                    -- Trim leading blank lines from commentText
                                    while true do
                                        local s1 = trimLeftSet(commentText, " \t")
                                        local s2 = trimLeftSet(s1, "\r\n")
                                        if #s1 == #s2 then
                                            break
                                        end
                                        commentText = s2
                                    end
                                end
                            end
                            b:WriteString("\n")
                            if #commentText > 6 and hasPrefix(commentText, "```") and hasSuffix(commentText, "```") and contains(commentText, "\n") then
                                b:WriteString(commentText)
                                b:WriteString("\n")
                            else
                                ls.writeCode(b, "tsx", commentText)
                            end
                        elseif tag.kind == Kind.JSDocSeeTag and tag.nameExpression ~= nil then
                            b:WriteString(" — ")
                            ls.writeNameLink(getMappedLocation, b, c, tag.nameExpression:Name(), "", false --[[quote]], isMarkdown)
                            if core.Len(comments) ~= 0 then
                                b:WriteString(" ")
                                ls.writeComments(getMappedLocation, b, c, comments, isMarkdown)
                            end
                        elseif tag.kind == Kind.JSDocThrowsTag and tag.typeExpression ~= nil then
                            b:WriteString(" — ")
                            b:WriteString(scanner.GetTextOfNode(tag.typeExpression))
                            if core.Len(comments) ~= 0 then
                                b:WriteString(" ")
                                ls.writeComments(getMappedLocation, b, c, comments, isMarkdown)
                            end
                        elseif core.Len(comments) ~= 0 then
                            b:WriteString(" ")
                            if comments[1].kind ~= Kind.JSDocText or not hasPrefix(comments[1]:Text(), "-") then
                                b:WriteString("— ")
                            end
                            ls.writeComments(getMappedLocation, b, c, comments, isMarkdown)
                        end
                    end
                    ::continue::
                end
            end
        end
    end
    return b:String()
end

function ls.formatQuickInfo(quickInfo)
    local b = core.NewStringBuilder()
    b:Grow(32)
    ls.writeCode(b, "typescript", quickInfo)
    return b:String()
end

function ls.shouldGetType(node)
    local kind = node.kind
    if kind == Kind.Identifier then
        -- If we're in a JSDoc node with no associated symbol, no binding has taken place for the node and
        -- we can't answer questions about types of declaration nodes (such as property declarations).
        return not (node.flags & NodeFlags.JSDoc ~= 0 and ast.IsDeclarationName(node)) and not ast.IsLabelName(node) and not ast.IsTagName(node) and not ast.IsConstTypeReference(node.parent)
    elseif kind == Kind.ThisKeyword or kind == Kind.ThisType or kind == Kind.SuperKeyword or kind == Kind.NamedTupleMember then
        return true
    elseif kind == Kind.MetaProperty then
        return ast.IsImportMeta(node)
    else
        return false
    end
end

-- symbolDisplayInfo holds the result of getSymbolDisplayPartsDocumentationAndSymbolKind.
-- symbolDisplayInfo: { displayParts, declaration }

-- getQuickInfoAndDeclarationAtLocation builds classified display parts using displayPartsWriter when vsCapability is true.
-- When vsCapability is false, it still builds the plain text string but skips classification runs.
function ls.getQuickInfoAndDeclarationAtLocation(c, symbol, node, vc, vsCapability, meaning)
    local container = ls.getContainerNode(node)
    if vc == nil then
        vc = checker.VerbosityContext_new(nil)
    end
    local dpw = ls.newDisplayPartsWriter(vsCapability)

    -- Source file for printer context
    local sourceFile
    if node ~= nil then
        sourceFile = ast.GetSourceFileOfNode(node)
    end

    -- nodeBuilderFlags for classified output (same as signatureHelpNodeBuilderFlags)
    local classifiedNodeBuilderFlags = nodebuilder.Flags.IgnoreErrors | nodebuilder.Flags.UseAliasDefinedOutsideCurrentScope | nodebuilder.Flags.WriteTypeParametersInQualifiedName

    -- writeTypeClassified writes a type to dpw with proper classification (punctuation, symbols, keywords).
    -- Falls back to flat text when vsCapability is false or when TypeToTypeNode fails.
    local function writeTypeClassified(t, enclosing, flags)
        flags = flags | TypeFormatFlags.MultilineObjectLiterals
        if not vsCapability then
            dpw:Write(c:TypeToStringEx(t, enclosing, flags, vc))
            return
        end
        local emitContext = printer.NewEmitContext()
        local idToSymbol = {}
        local nb = checker.NewNodeBuilderEx(c, emitContext, idToSymbol)
        local combinedFlags = (flags & TypeFormatFlags.NodeBuilderFlagsMask) | classifiedNodeBuilderFlags
        local typeNode = nb:TypeToTypeNode(t, enclosing, combinedFlags, nodebuilder.InternalFlags.None, nil)
        if typeNode == nil then
            dpw:Write(c:TypeToStringEx(t, enclosing, flags, vc))
            return
        end
        local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, emitContext)
        p.idToSymbol = idToSymbol
        local tempDpw = ls.newDisplayPartsWriter(true)
        p:Write(typeNode, sourceFile, tempDpw, nil)
        dpw:WriteFrom(tempDpw)
    end

    -- writeSignatureClassified writes a signature to dpw with proper classification.
    local function writeSignatureClassified(sig, enclosing, flags)
        flags = flags | TypeFormatFlags.MultilineObjectLiterals
        if not vsCapability then
            dpw:Write(c:SignatureToStringEx(sig, enclosing, flags, vc))
            return
        end
        local isConstructor = sig:Flags() & SignatureFlags.Construct ~= 0 and flags & TypeFormatFlags.WriteCallStyleSignature == 0
        local sigOutput
        if flags & TypeFormatFlags.WriteArrowStyleSignature ~= 0 then
            if isConstructor then
                sigOutput = Kind.ConstructorType
            else
                sigOutput = Kind.FunctionType
            end
        else
            if isConstructor then
                sigOutput = Kind.ConstructSignature
            else
                sigOutput = Kind.CallSignature
            end
        end
        local emitContext = printer.NewEmitContext()
        local idToSymbol = {}
        local nb = checker.NewNodeBuilderEx(c, emitContext, idToSymbol)
        local combinedFlags = (flags & TypeFormatFlags.NodeBuilderFlagsMask) | classifiedNodeBuilderFlags
        local sigNode = nb:SignatureToSignatureDeclaration(sig, sigOutput, enclosing, combinedFlags, nodebuilder.InternalFlags.None, nil)
        if sigNode == nil then
            dpw:Write(c:SignatureToStringEx(sig, enclosing, flags, vc))
            return
        end
        local p = printer.NewPrinter({ newLine = core.NewLineKind.LF }, {}, emitContext)
        p.idToSymbol = idToSymbol
        local tempDpw = ls.newDisplayPartsWriter(true)
        p:Write(sigNode, sourceFile, tempDpw, nil)
        dpw:WriteFrom(tempDpw)
    end

    -- writeSymbolClassified writes a symbol name to dpw with proper classification based on symbol flags.
    local function writeSymbolClassified(sym, enclosing, symbolMeaning, flags)
        if not vsCapability then
            dpw:Write(c:SymbolToStringEx(sym, enclosing, symbolMeaning, flags))
            return
        end
        -- Use WriteSymbol which calls classificationForSymbol to determine the correct classification
        local text = c:SymbolToStringEx(sym, enclosing, symbolMeaning, flags)
        dpw:WriteSymbol(text, sym)
    end
    if node.kind == Kind.ThisKeyword and ast.IsInExpressionContext(node) or ast.IsThisInTypeQuery(node) then
        dpw:WriteKeyword("this")
        dpw:WritePunctuation(": ")
        writeTypeClassified(c:GetTypeAtLocation(node), container, ls.typeFormatFlags)
        return { displayParts = dpw }
    end
    if symbol == nil then
        if ls.shouldGetType(node) then
            writeTypeClassified(c:GetTypeAtLocation(node), container, ls.typeFormatFlags)
        end
        return { displayParts = dpw }
    end
    local visitedAliases = collections.NewSet()
    local aliasLevel = 0
    local firstDeclaration
    local function setDeclaration(declaration)
        if firstDeclaration == nil then
            firstDeclaration = declaration
        end
    end
    local function writeNewLine()
        if dpw:String() ~= "" then
            dpw:Write("\n")
        end
        if aliasLevel ~= 0 then
            dpw:WritePunctuation("(")
            dpw:Write("alias")
            dpw:WritePunctuation(") ")
        end
    end
    local function writeSignatures(signatures, prefix, parenthesized, sym)
        for i1, sig in ipairs(signatures) do
            local i = i1 - 1
            writeNewLine()
            if i == 3 and #signatures >= 5 then
                dpw:WriteComment(string.format("// +%d more overloads", #signatures - 3))
                break
            end
            if parenthesized then
                dpw:WritePunctuation("(")
                dpw:Write(prefix)
                dpw:WritePunctuation(") ")
            else
                dpw:WriteKeyword(prefix)
            end
            writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
            if sym.flags & SymbolFlags.Optional ~= 0 then
                dpw:WritePunctuation("?")
            end
            writeSignatureClassified(sig, container, ls.typeFormatFlags | TypeFormatFlags.WriteCallStyleSignature | TypeFormatFlags.WriteTypeArgumentsOfSignature)
        end
    end
    local function writeTypeParams(params)
        if core.Len(params) > 0 then
            dpw:WritePunctuation("<")
            for i1, tp in ipairs(params) do
                if i1 ~= 1 then
                    dpw:WritePunctuation(", ")
                end
                writeSymbolClassified(tp:Symbol(), nil, SymbolFlags.None, ls.symbolFormatFlags)
                local cons = c:GetConstraintOfTypeParameter(tp)
                if cons ~= nil then
                    dpw:WriteKeyword(" extends ")
                    writeTypeClassified(cons, nil, ls.typeFormatFlags)
                end
                local def = c:GetDefaultFromTypeParameter(tp)
                if def ~= nil then
                    dpw:WriteOperator(" = ")
                    writeTypeClassified(def, nil, ls.typeFormatFlags)
                end
            end
            dpw:WritePunctuation(">")
        end
    end
    local symbolWasExpanded = false
    local function canExpandSymbol(sym)
        if vc == nil then
            return false
        end
        -- Only offer symbol-level expansion for types that tryExpandSymbol handles:
        -- class, interface, enum, namespace/module. For functions/variables/properties,
        -- the node builder's probeTypeExpandability detects expandable type components.
        if sym.flags & (SymbolFlags.Class | SymbolFlags.Interface | SymbolFlags.Namespace) == 0 then
            return false
        end
        local t
        if sym.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
            t = c:GetDeclaredTypeOfSymbol(sym)
        else
            t = c:GetTypeOfSymbolAtLocation(sym, node)
        end
        if t == nil or c:IsLibTypeForHoverVerbosity(t) then
            return false
        end
        if vc.level > 0 then
            return true
        end
        -- At level 0, signal that expansion is possible but don't expand
        vc.canIncreaseVerbosity = true
        return false
    end
    -- tryExpandSymbol checks if a symbol can be expanded at the current verbosity level.
    local function tryExpandSymbol(sym, symbolMeaning)
        if symbolWasExpanded then
            return true
        end
        if canExpandSymbol(sym) then
            local expandVC = checker.VerbosityContext_new({
                level = vc.level - 1,
                maxTruncationLength = vc.maxTruncationLength,
            })
            local expanded = c:ExpandSymbolForHover(sym, symbolMeaning, expandVC)
            if expanded ~= "" then
                vc.canIncreaseVerbosity = vc.canIncreaseVerbosity or expandVC.canIncreaseVerbosity
                vc.truncated = vc.truncated or expandVC.truncated
                dpw:Write(expanded)
                symbolWasExpanded = true
                return true
            end
        end
        return false
    end
    local writeSymbol
    writeSymbol = function(sym)
        -- Recursively write all meanings of alias
        if sym.flags & SymbolFlags.Alias ~= 0 and visitedAliases:AddIfAbsent(sym) then
            local aliasedSymbol = c:GetAliasedSymbol(sym)
            if aliasedSymbol ~= c:GetUnknownSymbol() then
                aliasLevel = aliasLevel + 1
                writeSymbol(aliasedSymbol)
                aliasLevel = aliasLevel - 1
            end
        end
        local flags
        if meaning == SemanticMeaning.Value then
            flags = sym.flags & (SymbolFlags.Value | SymbolFlags.Signature)
        elseif meaning == SemanticMeaning.Type then
            flags = sym.flags & SymbolFlags.Type
        elseif meaning == SemanticMeaning.Namespace then
            flags = sym.flags & SymbolFlags.Namespace
        else
            flags = sym.flags & (SymbolFlags.Value | SymbolFlags.Signature | SymbolFlags.Type | SymbolFlags.Namespace)
        end
        if flags == 0 then
            if aliasLevel ~= 0 or dpw:String() ~= "" then
                return
            end
            flags = sym.flags & (SymbolFlags.Value | SymbolFlags.Signature | SymbolFlags.Type | SymbolFlags.Namespace)
            if flags == 0 then
                return
            end
        end
        if flags & SymbolFlags.Property ~= 0 and sym.valueDeclaration ~= nil and ast.IsMethodDeclaration(sym.valueDeclaration) then
            flags = SymbolFlags.Method
        end
        if flags & (SymbolFlags.Variable | SymbolFlags.Property | SymbolFlags.Accessor) ~= 0 then
            writeNewLine()
            if sym.checkFlags & CheckFlags.IndexSymbol == 0 then
                if flags & SymbolFlags.Property ~= 0 then
                    dpw:WritePunctuation("(")
                    dpw:Write("property")
                    dpw:WritePunctuation(") ")
                elseif flags & SymbolFlags.Accessor ~= 0 then
                    dpw:WritePunctuation("(")
                    dpw:Write("accessor")
                    dpw:WritePunctuation(") ")
                else
                    local decl = sym.valueDeclaration
                    if decl ~= nil then
                        decl = ast.GetRootDeclaration(decl)
                        if ast.IsParameterDeclaration(decl) then
                            dpw:WritePunctuation("(")
                            dpw:Write("parameter")
                            dpw:WritePunctuation(") ")
                        elseif ast.IsVarLet(decl) then
                            dpw:WriteKeyword("let ")
                        elseif ast.IsVarConst(decl) then
                            dpw:WriteKeyword("const ")
                        elseif ast.IsVarUsing(decl) then
                            dpw:WriteKeyword("using ")
                        elseif ast.IsVarAwaitUsing(decl) then
                            dpw:WriteKeyword("await ")
                            dpw:WriteKeyword("using ")
                        else
                            dpw:WriteKeyword("var ")
                        end
                    end
                end
                if sym.name == ast.InternalSymbolNameExportEquals and sym.parent ~= nil and sym.parent.flags & SymbolFlags.Module ~= 0 then
                    dpw:Write("exports")
                else
                    writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
                end
                if sym.flags & SymbolFlags.Optional ~= 0 then
                    dpw:WritePunctuation("?")
                end
                dpw:WritePunctuation(": ")
            end
            local callNode = ls.getCallOrNewExpression(node)
            if callNode ~= nil then
                local sigFlags = ls.typeFormatFlags | TypeFormatFlags.WriteTypeArgumentsOfSignature | TypeFormatFlags.WriteArrowStyleSignature
                if ast.IsCallExpression(callNode) then
                    sigFlags = sigFlags | TypeFormatFlags.WriteCallStyleSignature
                end
                writeSignatureClassified(c:GetResolvedSignature(callNode), container, sigFlags)
            else
                local t = c:GetTypeOfSymbolAtLocation(sym, node)
                -- If the type is a constrained type parameter, support expansion:
                -- Level 0: show just "T", signal canIncreaseVerbosity
                -- Level 1+: show "T extends Constraint" with the constraint expanded at level-1
                if vc ~= nil and t:Symbol() ~= nil and t:Symbol().flags & SymbolFlags.TypeParameter ~= 0 and c:GetConstraintOfTypeParameter(t) ~= nil then
                    if vc.level > 0 then
                        local expandVC = checker.VerbosityContext_new({
                            level = vc.level - 1,
                            maxTruncationLength = vc.maxTruncationLength,
                        })
                        dpw:Write(ls.typeParameterToString(c, t, container, expandVC))
                        vc.canIncreaseVerbosity = vc.canIncreaseVerbosity or expandVC.canIncreaseVerbosity
                        vc.truncated = vc.truncated or expandVC.truncated
                    else
                        writeTypeClassified(t, container, ls.typeFormatFlags)
                        vc.canIncreaseVerbosity = true
                    end
                else
                    writeTypeClassified(t, container, ls.typeFormatFlags)
                end
            end
            setDeclaration(core.OrElse(sym.valueDeclaration, core.FirstOrNil(sym.declarations)))
        end
        if flags & SymbolFlags.EnumMember ~= 0 then
            writeNewLine()
            dpw:WritePunctuation("(")
            dpw:Write("enum member")
            dpw:WritePunctuation(") ")
            local t = c:GetTypeOfSymbol(sym)
            writeTypeClassified(t, container, ls.typeFormatFlags)
            if t:Flags() & TypeFlags.Literal ~= 0 then
                dpw:WriteOperator(" = ")
                dpw:WriteLiteral(t:AsLiteralType():String())
            end
            setDeclaration(sym.valueDeclaration)
        end
        if flags & (SymbolFlags.Function | SymbolFlags.Method) ~= 0 then
            local isMethod = flags & SymbolFlags.Method ~= 0
            local prefix = core.IfElse(isMethod, "method", "function ")
            if ast.IsIdentifier(node) and (ast.IsFunctionLikeDeclaration(node.parent) or ast.IsMethodSignatureDeclaration(node.parent)) and node.parent:Name() == node and containsValue(sym.declarations, node.parent) then
                setDeclaration(node.parent)
                local signatures = { c:GetSignatureFromDeclaration(node.parent) }
                writeSignatures(signatures, prefix, isMethod, sym)
            else
                local signatures = ls.getSignaturesAtLocation(c, sym, SignatureKind.Call, node)
                if core.Len(signatures) == 1 then
                    local d = signatures[1]:Declaration()
                    if d ~= nil and d.flags & NodeFlags.JSDoc == 0 then
                        setDeclaration(d)
                    end
                end
                writeSignatures(signatures or {}, prefix, isMethod, sym)
            end
            setDeclaration(sym.valueDeclaration)
        end
        if flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
            if node.kind == Kind.ThisKeyword or ast.IsThisInTypeQuery(node) then
                writeNewLine()
                dpw:WriteKeyword("this")
            elseif node.kind == Kind.ConstructorKeyword and (ast.IsConstructorDeclaration(node.parent) or ast.IsConstructSignatureDeclaration(node.parent)) then
                setDeclaration(node.parent)
                local signatures = { c:GetSignatureFromDeclaration(node.parent) }
                writeSignatures(signatures, "constructor ", false, sym)
            else
                local signatures
                if flags & SymbolFlags.Class ~= 0 and ls.getCallOrNewExpression(node) ~= nil then
                    signatures = ls.getSignaturesAtLocation(c, sym, SignatureKind.Construct, node)
                end
                if core.Len(signatures) == 1 then
                    local d = signatures[1]:Declaration()
                    if d ~= nil and d.flags & NodeFlags.JSDoc == 0 then
                        setDeclaration(d)
                    end
                    writeSignatures(signatures, "constructor ", false, sym)
                else
                    writeNewLine()
                    if flags & SymbolFlags.Class ~= 0 then
                        local classExpression = ast.GetDeclarationOfKind(sym, Kind.ClassExpression)
                        if classExpression ~= nil then
                            -- Local class expression: show "(local class)" prefix
                            dpw:WritePunctuation("(")
                            dpw:Write("local class")
                            dpw:WritePunctuation(") ")
                        end
                        if not tryExpandSymbol(sym, flags) then
                            if classExpression == nil then
                                if core.Some(sym.declarations, function(d)
                                    return ast.IsClassDeclaration(d) and ast.HasAbstractModifier(d)
                                end) then
                                    dpw:WriteKeyword("abstract ")
                                end
                                dpw:WriteKeyword("class ")
                            end
                            writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
                            local params = c:GetDeclaredTypeOfSymbol(sym):AsInterfaceType():LocalTypeParameters()
                            writeTypeParams(params)
                        end
                    else
                        if not tryExpandSymbol(sym, flags) then
                            dpw:WriteKeyword("interface ")
                            writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
                            local params = c:GetDeclaredTypeOfSymbol(sym):AsInterfaceType():LocalTypeParameters()
                            writeTypeParams(params)
                        end
                    end
                end
            end
            if flags & SymbolFlags.Class ~= 0 then
                setDeclaration(sym.valueDeclaration)
            else
                setDeclaration(core.Find(sym.declarations, ast.IsInterfaceDeclaration))
            end
        end
        if flags & SymbolFlags.Enum ~= 0 then
            writeNewLine()
            if not tryExpandSymbol(sym, flags) then
                if core.Some(sym.declarations, function(d)
                    return ast.IsEnumDeclaration(d) and ast.IsEnumConst(d)
                end) then
                    dpw:WriteKeyword("const ")
                end
                dpw:WriteKeyword("enum ")
                writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
            end
            setDeclaration(core.Find(sym.declarations, ast.IsEnumDeclaration))
        end
        if flags & SymbolFlags.Module ~= 0 then
            writeNewLine()
            if not tryExpandSymbol(sym, flags) then
                local isModule = sym.valueDeclaration ~= nil and (ast.IsSourceFile(sym.valueDeclaration) or ast.IsAmbientModule(sym.valueDeclaration))
                dpw:WriteKeyword(core.IfElse(isModule, "module ", "namespace "))
                writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
            end
            setDeclaration(core.Find(sym.declarations, ast.IsModuleDeclaration))
        end
        if flags & SymbolFlags.TypeParameter ~= 0 then
            writeNewLine()
            dpw:WritePunctuation("(")
            dpw:Write("type parameter")
            dpw:WritePunctuation(") ")
            local tp = c:GetDeclaredTypeOfSymbol(sym)
            writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
            local cons = c:GetConstraintOfTypeParameter(tp)
            if cons ~= nil then
                dpw:WriteKeyword(" extends ")
                writeTypeClassified(cons, container, ls.typeFormatFlags)
            end
            -- Show context: "in ClassName<T>" or "in funcName<T>(...)"
            if sym.parent ~= nil then
                -- Class/Interface type parameter
                dpw:WriteKeyword(" in ")
                writeSymbolClassified(sym.parent, container, SymbolFlags.None, ls.symbolFormatFlags)
                local parentType = c:GetDeclaredTypeOfSymbol(sym.parent)
                if parentType:AsInterfaceType() ~= nil then
                    local parentParams = parentType:AsInterfaceType():LocalTypeParameters()
                    writeTypeParams(parentParams)
                end
            else
                -- Method/function type parameter
                local decl = ast.GetDeclarationOfKind(sym, Kind.TypeParameter)
                if decl ~= nil and decl.parent ~= nil then
                    local declaration = decl.parent
                    if ast.IsFunctionLike(declaration) then
                        dpw:WriteKeyword(" in ")
                        if declaration.kind == Kind.ConstructSignature then
                            dpw:WriteKeyword("new ")
                        elseif declaration.kind ~= Kind.CallSignature and declaration:Name() ~= nil then
                            writeSymbolClassified(declaration:Symbol(), container, SymbolFlags.None, ls.symbolFormatFlags)
                        end
                        local sig = c:GetSignatureFromDeclaration(declaration)
                        if sig ~= nil then
                            writeSignatureClassified(sig, container, ls.typeFormatFlags | TypeFormatFlags.WriteTypeArgumentsOfSignature)
                        end
                    elseif ast.IsTypeAliasDeclaration(declaration) then
                        dpw:WriteKeyword(" in ")
                        dpw:WriteKeyword("type ")
                        writeSymbolClassified(declaration:Symbol(), container, SymbolFlags.None, ls.symbolFormatFlags)
                        local declSymbol = declaration:Symbol()
                        if declSymbol ~= nil then
                            local taParams = c:GetTypeAliasTypeParameters(declSymbol)
                            writeTypeParams(taParams)
                        end
                    end
                end
            end
            setDeclaration(core.Find(sym.declarations, ast.IsTypeParameterDeclaration))
        end
        if flags & SymbolFlags.TypeAlias ~= 0 then
            writeNewLine()
            dpw:WriteKeyword("type ")
            writeSymbolClassified(sym, container, SymbolFlags.None, ls.symbolFormatFlags)
            writeTypeParams(c:GetTypeAliasTypeParameters(sym))
            dpw:WriteOperator(" = ")
            local typeAliasType
            if node.parent ~= nil and ast.IsConstTypeReference(node.parent) then
                typeAliasType = c:GetTypeAtLocation(node.parent)
            else
                typeAliasType = c:GetDeclaredTypeOfSymbol(sym)
            end
            writeTypeClassified(typeAliasType, container, ls.typeFormatFlags | TypeFormatFlags.InTypeAlias)
            setDeclaration(core.Find(sym.declarations, ast.IsTypeOrJSTypeAliasDeclaration))
        end
        if flags & SymbolFlags.Signature ~= 0 then
            writeNewLine()
            writeTypeClassified(c:GetTypeOfSymbol(sym), container, ls.typeFormatFlags)
        end
    end
    writeSymbol(symbol)

    return { displayParts = dpw, declaration = firstDeclaration }
end

-- typeParameterToString renders a type parameter declaration (e.g., "T extends FooType").
function ls.typeParameterToString(c, t, enclosingDeclaration, vc)
    return c:TypeParameterToStringEx(t, enclosingDeclaration, vc)
end

function ls.getNodeForQuickInfo(node)
    if node.parent == nil then
        return node
    end
    if ast.IsNewExpression(node.parent) and node:Pos() == node.parent:Pos() then
        return node.parent:Expression()
    end
    if ast.IsNamedTupleMember(node.parent) and node:Pos() == node.parent:Pos() then
        return node.parent
    end
    if ast.IsImportMeta(node.parent) and node.parent:Name() == node then
        return node.parent
    end
    if ast.IsJsxNamespacedName(node.parent) then
        return node.parent
    end
    return node
end

function ls.getSymbolAtLocationForQuickInfo(c, node)
    local objectElement = ls.getContainingObjectLiteralElement(node)
    if objectElement ~= nil then
        local contextualType = c:GetContextualType(objectElement.parent, checker.ContextFlags.None)
        if contextualType ~= nil then
            local properties = c:GetPropertySymbolsFromContextualType(objectElement, contextualType, false --[[unionSymbolOk]])
            if core.Len(properties) == 1 then
                return properties[1]
            end
        end
    end
    return c:GetSymbolAtLocation(node)
end

function ls.getSignaturesAtLocation(c, symbol, kind, node)
    local signatures = c:GetSignaturesOfType(c:RemoveMissingOrUndefinedType(c:GetTypeOfSymbol(symbol)), kind)
    if core.Len(signatures) > 1 or core.Len(signatures) == 1 and core.Len(signatures[1]:TypeParameters()) ~= 0 then
        local callNode = ls.getCallOrNewExpression(node)
        if callNode ~= nil then
            -- We have a call or new expression, return the resolved signature
            return { c:GetResolvedSignature(callNode) }
        end
    end
    return signatures
end

function ls.getCallOrNewExpression(node)
    if ast.IsSourceFile(node) then
        return nil
    end
    if ast.IsPropertyAccessExpression(node.parent) and node.parent:Name() == node then
        node = node.parent
    end
    if (ast.IsCallExpression(node.parent) or ast.IsNewExpression(node.parent)) and node.parent:Expression() == node then
        return node.parent
    end
    return nil
end

function ls.containsTypedefTag(jsdoc)
    if jsdoc.kind == Kind.JSDoc then
        local tags = jsdoc:AsJSDoc().tags
        if tags ~= nil then
            for _, tag in ipairs(tags.nodes) do
                if tag.kind == Kind.JSDocTypedefTag or tag.kind == Kind.JSDocCallbackTag then
                    return true
                end
            end
        end
    end
    return false
end

function ls.writeCode(b, lang, code)
    if code == "" then
        return
    end
    local ticks = 3
    while contains(code, string.rep("`", ticks)) do
        ticks = ticks + 1
    end
    b:WriteString(string.rep("`", ticks))
    b:WriteString(lang)
    b:WriteString("\n")
    b:WriteString(code)
    b:WriteString("\n")
    b:WriteString(string.rep("`", ticks))
    b:WriteString("\n")
end

function ls.writeComments(getMappedLocation, b, c, comments, isMarkdown)
    for _, comment in ipairs(comments or {}) do
        if comment.kind == Kind.JSDocText then
            b:WriteString(comment:Text())
        elseif comment.kind == Kind.JSDocLink or comment.kind == Kind.JSDocLinkPlain then
            ls.writeJSDocLink(getMappedLocation, b, c, comment, false --[[quote]], isMarkdown)
        elseif comment.kind == Kind.JSDocLinkCode then
            ls.writeJSDocLink(getMappedLocation, b, c, comment, true --[[quote]], isMarkdown)
        end
    end
end

function ls.writeJSDocLink(getMappedLocation, b, c, link, quote, isMarkdown)
    local name = link:Name()
    local text = trimRightSet(trimLeftSet(link:Text(), " "), " ")
    if name == nil then
        ls.writeQuotedString(b, text, quote and isMarkdown)
        return
    end
    if ast.IsIdentifier(name) and (name:Text() == "http" or name:Text() == "https") and hasPrefix(text, "://") then
        local linkText = name:Text() .. text
        local linkUri = linkText
        local commentPos = string.find(linkText, "[ |]")
        if commentPos ~= nil then
            linkUri = string.sub(linkText, 1, commentPos - 1)
            linkText = ls.trimCommentPrefix(string.sub(linkText, commentPos))
            if linkText == "" then
                linkText = linkUri
            end
        end
        if isMarkdown then
            ls.writeMarkdownLink(b, linkText, linkUri, quote)
        else
            ls.writeQuotedString(b, linkText, false)
            if linkText ~= linkUri then
                b:WriteString(" (")
                b:WriteString(linkUri)
                b:WriteString(")")
            end
        end
        return
    end
    ls.writeNameLink(getMappedLocation, b, c, name, text, quote, isMarkdown)
end

function ls.writeNameLink(getMappedLocation, b, c, name, text, quote, isMarkdown)
    local declarations = ls.getDeclarationsFromLocation(c, name)
    if core.Len(declarations) ~= 0 then
        local declaration = declarations[1]
        local file = ast.GetSourceFileOfNode(declaration)
        local node = core.OrElse(ast.GetNameOfDeclaration(declaration), declaration)
        local loc, fidelity = getMappedLocation(file, ls.createRangeFromNode(node, file))
        local prefixLen = core.IfElse(hasPrefix(text, "()"), 2, 0)
        local linkText = ls.trimCommentPrefix(string.sub(text, prefixLen + 1))
        if linkText == "" then
            linkText = ls.getEntityNameString(name) .. string.sub(text, 1, prefixLen)
        end
        if isMarkdown and spanmap.Fidelity_IsSingleSegment(fidelity) then
            local linkUri = string.format("%s#%d,%d-%d,%d", loc.uri, loc.range.start.line + 1, loc.range.start.character + 1, loc.range.end_.line + 1, loc.range.end_.character + 1)
            ls.writeMarkdownLink(b, linkText, linkUri, quote)
        else
            ls.writeQuotedString(b, linkText, false)
        end
        return
    end
    ls.writeQuotedString(b, ls.getEntityNameString(name) .. core.IfElse(#text ~= 0, " ", "") .. text, quote and isMarkdown)
end

function ls.trimCommentPrefix(text)
    local s = trimLeftSet(text, " ")
    if hasPrefix(s, "|") then
        s = string.sub(s, 2)
    end
    return trimLeftSet(s, " ")
end

function ls.writeMarkdownLink(b, text, uri, quote)
    b:WriteString("[")
    ls.writeQuotedString(b, text, quote)
    b:WriteString("](")
    b:WriteString(uri)
    b:WriteString(")")
end

function ls.writeOptionalEntityName(b, name)
    if name ~= nil then
        b:WriteString(" ")
        ls.writeQuotedString(b, ls.getEntityNameString(name), true --[[quote]])
    end
end

function ls.writeQuotedString(b, str, quote)
    if quote and not contains(str, "`") then
        b:WriteString("`")
        b:WriteString(str)
        b:WriteString("`")
    else
        b:WriteString(str)
    end
end

function ls.getEntityNameString(name)
    local b = core.NewStringBuilder()
    ls.writeEntityNameParts(b, name)
    return b:String()
end

function ls.writeEntityNameParts(b, node)
    local kind = node.kind
    if kind == Kind.Identifier then
        b:WriteString(node:Text())
    elseif kind == Kind.QualifiedName then
        ls.writeEntityNameParts(b, node.left)
        b:WriteString(".")
        ls.writeEntityNameParts(b, node.right)
    elseif kind == Kind.PropertyAccessExpression then
        ls.writeEntityNameParts(b, node:Expression())
        b:WriteString(".")
        ls.writeEntityNameParts(b, node:Name())
    elseif kind == Kind.ParenthesizedExpression or kind == Kind.ExpressionWithTypeArguments then
        ls.writeEntityNameParts(b, node:Expression())
    elseif kind == Kind.JSDocNameReference then
        ls.writeEntityNameParts(b, node:Name())
    end
end
