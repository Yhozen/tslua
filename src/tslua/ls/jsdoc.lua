local ls = require("tslua.ls")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

-- JSDocTagInfo mirrors Strada's `JSDocTagInfo`, but renders the tag's text as a
-- plain string instead of `SymbolDisplayPart[]`.
-- JSDocTagInfo: { name, text }

local function containsString(xs, s)
    for _, x in ipairs(xs or {}) do
        if x == s then
            return true
        end
    end
    return false
end

-- GetSymbolDocumentationComment renders a symbol's documentation comment as plain text.
-- It backs the API's Symbol.getDocumentationComment and mirrors Strada's
-- getJsDocCommentsFromDeclarations: comments are gathered from each unique declaration,
-- deduplicated, and joined with line breaks. Like Strada, it does not resolve aliases —
-- consumers resolve aliases themselves (via getAliasedSymbol) and re-query if desired.
function ls.GetSymbolDocumentationComment(c, symbol)
    if symbol == nil then
        return ""
    end
    local parts = {}
    local seen = collections.NewSet()
    for _, decl in ipairs(symbol.declarations or {}) do
        if seen:AddIfAbsent(decl) then
            local doc = ls.getDocumentationFromDeclaration(ls.noMappedLocation, c, symbol, decl, decl, lsproto.MarkupKind.PlainText, true --[[commentOnly]])
            if doc ~= "" and not containsString(parts, doc) then
                parts[#parts + 1] = doc
            end
        end
    end
    return table.concat(parts, "\n")
end

-- GetSymbolJSDocTags collects a symbol's JSDoc tags. It backs the API's Symbol.getJsDocTags
-- and mirrors Strada's getJsDocTagsFromDeclarations, except each tag's text is rendered as a
-- plain string rather than SymbolDisplayPart[]. Tags with no text have an empty Text field.
function ls.GetSymbolJSDocTags(symbol)
    if symbol == nil then
        return nil
    end
    local infos
    local seen = collections.NewSet()
    for _, decl in ipairs(symbol.declarations or {}) do
        if not seen:AddIfAbsent(decl) then
            goto continue
        end
        do
            local tags = ls.declarationJSDocTags(decl)
            -- Skip comments containing @typedef/@callback since they're not associated with a
            -- particular declaration, unless they also carry @param/@return (treated as local docs).
            local hasTypedef = core.Some(tags, function(t)
                return t.kind == Kind.JSDocTypedefTag or t.kind == Kind.JSDocCallbackTag
            end)
            local hasParamOrReturn = core.Some(tags, function(t)
                return t.kind == Kind.JSDocParameterTag or t.kind == Kind.JSDocReturnTag
            end)
            if hasTypedef and not hasParamOrReturn then
                goto continue
            end
            for _, tag in ipairs(tags or {}) do
                infos = core.Append(infos, { name = tag:TagName():Text(), text = ls.getJSDocTagText(tag) })
            end
        end
        ::continue::
    end
    return infos
end

-- declarationJSDocTags returns the JSDoc tags associated with a declaration, walking the
-- JSDoc comment location chain like the checker's getAllJSDocTags.
function ls.declarationJSDocTags(node)
    if node.flags & NodeFlags.JSDoc == 0 then
        local current = node
        while current ~= nil do
            local jsdocs = current:JSDoc(nil)
            if core.Len(jsdocs) ~= 0 then
                local lastJSDoc = jsdocs[#jsdocs]:AsJSDoc()
                if lastJSDoc.tags ~= nil then
                    return lastJSDoc.tags.nodes
                end
            end
            current = ast.GetNextJSDocCommentLocation(current)
        end
    end
    return nil
end

-- getJSDocTagText renders the text of a single JSDoc tag as a plain string, mirroring
-- Strada's getCommentDisplayParts collapsed from SymbolDisplayPart[] to a string.
function ls.getJSDocTagText(tag)
    local comment = scanner.GetTextOfJSDocComment(tag:CommentList())
    local function addComment(s)
        if comment == "" then
            return s
        end
        return s .. " " .. comment
    end
    local kind = tag.kind
    if kind == Kind.JSDocThrowsTag then
        local te = tag.typeExpression
        if te ~= nil then
            return addComment(scanner.GetTextOfNode(te))
        end
        return comment
    elseif kind == Kind.JSDocImplementsTag then
        return addComment(scanner.GetTextOfNode(tag.className))
    elseif kind == Kind.JSDocAugmentsTag then
        return addComment(scanner.GetTextOfNode(tag.className))
    elseif kind == Kind.JSDocTemplateTag then
        local templateTag = tag
        local b = core.NewStringBuilder()
        if templateTag.constraint ~= nil then
            b:WriteString(scanner.GetTextOfNode(templateTag.constraint))
        end
        if templateTag.typeParameters ~= nil then
            for i1, tp in ipairs(templateTag.typeParameters.nodes) do
                local i = i1 - 1
                if i == 0 and b:Len() ~= 0 then
                    b:WriteString(" ")
                end
                if i ~= 0 then
                    b:WriteString(", ")
                end
                b:WriteString(scanner.GetTextOfNode(tp))
            end
        end
        if comment ~= "" then
            if b:Len() ~= 0 then
                b:WriteString(" ")
            end
            b:WriteString(comment)
        end
        return b:String()
    elseif kind == Kind.JSDocTypeTag then
        return addComment(scanner.GetTextOfNode(tag.typeExpression))
    elseif kind == Kind.JSDocSatisfiesTag then
        return addComment(scanner.GetTextOfNode(tag.typeExpression))
    elseif kind == Kind.JSDocSeeTag then
        local ne = tag.nameExpression
        if ne ~= nil then
            return addComment(scanner.GetTextOfNode(ne))
        end
        return comment
    elseif kind == Kind.JSDocParameterTag or kind == Kind.JSDocPropertyTag then
        local name = tag:Name()
        if name ~= nil then
            return addComment(scanner.GetTextOfNode(name))
        end
        return comment
    else
        return comment
    end
end

function ls.getJSDoc(node)
    return core.LastOrNil(node:JSDoc(nil))
end

function ls.getJSDocOrTag(c, node, seenSymbols)
    if node == nil then
        return nil
    end
    local jsdoc = ls.getJSDoc(node)
    if jsdoc ~= nil then
        return jsdoc
    end
    if ast.IsParameterDeclaration(node) then
        local name = node:Name()
        if ast.IsBindingPattern(name) then
            -- For binding patterns, match JSDoc @param tags by position rather than by name
            return ls.getJSDocParameterTagByPosition(c, node)
        end
        return ls.getMatchingJSDocTag(c, node.parent, name:Text(), ls.isMatchingParameterTag, seenSymbols)
    elseif ast.IsTypeParameterDeclaration(node) then
        return ls.getMatchingJSDocTag(c, node.parent, node:Name():Text(), ls.isMatchingTemplateTag, seenSymbols)
    elseif ast.IsVariableDeclaration(node) and ast.IsVariableDeclarationList(node.parent) and core.FirstOrNil(node.parent.declarations.nodes) == node then
        return ls.getJSDocOrTag(c, node.parent.parent, seenSymbols)
    elseif (ast.IsFunctionExpressionOrArrowFunction(node) or ast.IsClassExpression(node)) and
        (ast.IsVariableDeclaration(node.parent) or ast.IsPropertyDeclaration(node.parent) or ast.IsPropertyAssignment(node.parent)) and node.parent:Initializer() == node then
        return ls.getJSDocOrTag(c, node.parent, seenSymbols)
    elseif ast.IsBindingElement(node) and ast.IsObjectBindingPattern(node.parent) then
        local name = node:PropertyNameOrName()
        if ast.IsIdentifier(name) then
            local objectType = c:GetTypeAtLocation(node.parent)
            if objectType ~= nil then
                local prop = c:GetPropertyOfType(objectType, name:Text())
                if prop ~= nil then
                    for _, d in ipairs(prop.declarations or {}) do
                        local doc = ls.getJSDoc(d)
                        if doc ~= nil then
                            return doc
                        end
                    end
                end
            end
        end
    end
    local symbol = node:Symbol()
    if symbol ~= nil and node.parent ~= nil then
        if ast.IsFunctionDeclaration(node) or ast.IsMethodDeclaration(node) or ast.IsMethodSignatureDeclaration(node) or ast.IsConstructorDeclaration(node) or ast.IsConstructSignatureDeclaration(node) then
            local firstSignature = core.Find(symbol.declarations, ast.IsFunctionLike)
            if firstSignature ~= nil and node ~= firstSignature then
                local jsDoc = ls.getJSDocOrTag(c, firstSignature, seenSymbols)
                if jsDoc ~= nil then
                    return jsDoc
                end
            end
        end
        if ast.IsClassOrInterfaceLike(node.parent) then
            local isStatic = ast.HasStaticModifier(node)
            local classType = c:GetDeclaredTypeOfSymbol(node.parent:Symbol())
            if isStatic then
                -- For static members, use the checker's base constructor type resolution.
                -- This correctly handles intersection constructor types from mixins
                -- (e.g., typeof MixinClass & T) by preserving the full intersection.
                local staticBaseType = c:GetApparentType(c:GetBaseConstructorTypeOfClass(classType))
                local prop = c:GetPropertyOfType(staticBaseType, symbol.name)
                if prop ~= nil and prop.valueDeclaration ~= nil and seenSymbols:AddIfAbsent(prop) then
                    local jsDoc = ls.getJSDocOrTag(c, prop.valueDeclaration, seenSymbols)
                    if jsDoc ~= nil then
                        return jsDoc
                    end
                end
            else
                for _, baseType in ipairs(c:GetBaseTypes(classType) or {}) do
                    local prop = c:GetPropertyOfType(baseType, symbol.name)
                    if prop ~= nil and prop.valueDeclaration ~= nil and seenSymbols:AddIfAbsent(prop) then
                        local jsDoc = ls.getJSDocOrTag(c, prop.valueDeclaration, seenSymbols)
                        if jsDoc ~= nil then
                            return jsDoc
                        end
                    end
                end
            end
        end
    end
    return nil
end

function ls.getMatchingJSDocTag(c, node, name, match, seenSymbols)
    local jsdoc = ls.getJSDocOrTag(c, node, seenSymbols)
    if jsdoc ~= nil and jsdoc.kind == Kind.JSDoc then
        local tags = jsdoc:AsJSDoc().tags
        if tags ~= nil then
            for _, tag in ipairs(tags.nodes) do
                if match(tag, name) then
                    return tag
                end
            end
        end
    end
    return nil
end

-- getJSDocParameterTagByPosition finds a JSDoc @param tag for a binding pattern parameter by position.
-- Since binding patterns don't have a simple name, we match the @param tag at the same index as the parameter.
function ls.getJSDocParameterTagByPosition(c, param)
    local parent = param.parent
    if parent == nil then
        return nil
    end

    -- Find the parameter's index in the parent's parameters list
    local params = parent:Parameters()
    local paramIndex = -1
    for i1, p in ipairs(params or {}) do
        if p == param then
            paramIndex = i1 - 1
            break
        end
    end
    if paramIndex < 0 then
        return nil
    end

    -- Get the JSDoc for the parent function/method
    local jsdoc = ls.getJSDocOrTag(c, parent, collections.NewSet())
    if jsdoc == nil or jsdoc.kind ~= Kind.JSDoc then
        return nil
    end

    -- Collect all @param tags in order
    local tags = jsdoc:AsJSDoc().tags
    if tags == nil then
        return nil
    end

    local paramTagIndex = 0
    for _, tag in ipairs(tags.nodes) do
        if tag.kind == Kind.JSDocParameterTag then
            if paramTagIndex == paramIndex then
                return tag
            end
            paramTagIndex = paramTagIndex + 1
        end
    end
    return nil
end

function ls.isMatchingParameterTag(tag, name)
    return tag.kind == Kind.JSDocParameterTag and ls.isNodeWithName(tag, name)
end

function ls.isMatchingTemplateTag(tag, name)
    return tag.kind == Kind.JSDocTemplateTag and core.Some(tag:TypeParameters(), function(tp) return ls.isNodeWithName(tp, name) end)
end

function ls.isNodeWithName(node, name)
    local nodeName = node:Name()
    return ast.IsIdentifier(nodeName) and nodeName:Text() == name
end

function ls.noMappedLocation(_, _)
    return {
        uri = "",
        range = { start = { line = 0, character = 0 }, end_ = { line = 0, character = 0 } },
    }, spanmap.Fidelity.None
end
