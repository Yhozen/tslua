local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

function LanguageService:ProvideOnAutoInsert(ctx, params)
    if core.Tristate_IsFalse(self:UserPreferences().enableAutoClosingTags) then
        return {}, nil
    end
    if params.vsCh ~= ">" then
        return {}, nil
    end

    local _, sourceFile = self:getProgramAndFile(params.vsTextDocument.uri)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, params.vsPosition, spanmap.Feature.AutoInsert)
    if core.Len(positions) ~= 1 or not spanmap.Fidelity_IsExact(positions[1].fidelity) then
        return {}, nil
    end
    sourceFile = positions[1].script
    local position = positions[1].position

    local token = astnav.FindPrecedingToken(sourceFile, position)
    if token == nil then
        return {}, nil
    end

    local closingText = ""
    local element
    if token.kind == Kind.GreaterThanToken and ast.IsJsxOpeningElement(token.parent) then
        element = token.parent.parent
    elseif ast.IsJsxText(token) and ast.IsJsxElement(token.parent) then
        element = token.parent
    end

    if element ~= nil and ls.isUnclosedTag(element:AsJsxElement()) then
        local tagNameNode = element:AsJsxElement().openingElement:TagName()
        -- Slight divergence from Strada - we don't use the verbatim text from the opening tag.
        closingText = "</" .. ast.EntityNameToString(tagNameNode, scanner.GetTextOfNode) .. ">"
    else
        local fragment
        if token.kind == Kind.GreaterThanToken and ast.IsJsxOpeningFragment(token.parent) then
            fragment = token.parent.parent
        elseif ast.IsJsxText(token) and ast.IsJsxFragment(token.parent) then
            fragment = token.parent
        end

        if fragment ~= nil and ls.isUnclosedFragment(fragment:AsJsxFragment()) then
            closingText = "</>"
        end
    end

    if closingText == "" then
        return {}, nil
    end

    return {
        vsOnAutoInsertResponseItem = {
            vsTextEditFormat = lsproto.InsertTextFormat.Snippet,
            vsTextEdit = {
                range = { start = params.vsPosition, end_ = params.vsPosition },
                -- Tag names can contain `$` (valid JSX identifier characters), so
                -- escape the closing text to avoid being interpreted as a snippet
                -- placeholder/variable.
                newText = "$0" .. ls.escapeSnippetText(closingText),
            },
        },
    }, nil
end

function ls.isUnclosedTag(node)
    local openingElement = node.openingElement
    local closingElement = node.closingElement
    if not ast.TagNamesAreEquivalent(openingElement:TagName(), closingElement:TagName()) then
        return true
    end

    local parent = node.parent
    if ast.IsJsxElement(parent) then
        parent = parent:AsJsxElement()
        return ast.TagNamesAreEquivalent(openingElement:TagName(), parent.openingElement:TagName()) and ls.isUnclosedTag(parent)
    end

    return false
end

function ls.isUnclosedFragment(node)
    local closingFragment = node.closingFragment
    if closingFragment.flags & ast.NodeFlags.ThisNodeHasError ~= 0 then
        return true
    end

    local parent = node.parent
    if ast.IsJsxFragment(parent) and ls.isUnclosedFragment(parent:AsJsxFragment()) then
        return true
    end

    return false
end
