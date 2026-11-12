local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local debug = require("tslua.debug")
local lsconv = require("tslua.ls.lsconv")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

-- allow the client to match more than valid tag names. This allows linked editing when typing is in progress or tag name is incomplete
ls.jsxTagWordPattern = "[a-zA-Z0-9:\\-\\._$]*"

function LanguageService:ProvideLinkedEditingRange(ctx, params)
    local _, sourceFile = self:getProgramAndFile(params.textDocument.uri)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, params.position, spanmap.Feature.LinkedEditing)
    if core.Len(positions) ~= 1 or not spanmap.Fidelity_IsExact(positions[1].fidelity) then
        return {}, nil
    end
    sourceFile = positions[1].script
    local position = positions[1].position
    local token = astnav.FindPrecedingToken(sourceFile, position)

    if token == nil or token.parent.kind == Kind.SourceFile then
        return {}, nil
    end

    if ast.IsJsxFragment(token.parent.parent) then
        local fragment = token.parent.parent:AsJsxFragment()
        local openFragment = fragment.openingFragment
        local closeFragment = fragment.closingFragment
        if openFragment.flags & NodeFlags.ThisNodeOrAnySubNodesHasError ~= 0 or closeFragment.flags & NodeFlags.ThisNodeOrAnySubNodesHasError ~= 0 then
            return {}, nil
        end

        local openPos = astnav.GetStartOfNode(openFragment, sourceFile, false) + #"<"
        local closePos = astnav.GetStartOfNode(closeFragment, sourceFile, false) + #"</"

        -- only allows linked editing right after opening bracket: <| ></| >
        if (position ~= openPos) and (position ~= closePos) then
            return {}, nil
        end

        local openLineChar, openFidelity = self.converters:ToLSPPositionForFeature(sourceFile, openPos, spanmap.Feature.LinkedEditing)
        local closeLineChar, closeFidelity = self.converters:ToLSPPositionForFeature(sourceFile, closePos, spanmap.Feature.LinkedEditing)
        if not spanmap.Fidelity_IsExact(openFidelity) or not spanmap.Fidelity_IsExact(closeFidelity) then
            return {}, nil
        end
        return {
            linkedEditingRanges = {
                ranges = {
                    { start = openLineChar, end_ = openLineChar }, -- only return start position for opening tag since the length of a fragment is always 3 and it is unlikely user will type in the middle of a fragment tag
                    { start = closeLineChar, end_ = closeLineChar },
                },
                wordPattern = ls.jsxTagWordPattern,
            },
        }, nil
    else
        -- determines if the cursor is in an element tag
        local tag = ast.FindAncestor(token.parent, function(n)
            if ast.IsJsxOpeningElement(n) or ast.IsJsxClosingElement(n) then
                return true
            end
            return false
        end)
        if tag == nil then
            return {}, nil
        end
        debug.Assert(ast.IsJsxOpeningElement(tag) or ast.IsJsxClosingElement(tag), "tag should be opening or closing element")

        local jsxElement = tag.parent:AsJsxElement()
        local openTag = jsxElement.openingElement
        local closeTag = jsxElement.closingElement

        local openTagNameStart = astnav.GetStartOfNode(openTag:TagName(), sourceFile, false)
        local openTagNameEnd = openTag:TagName():End()
        local closeTagNameStart = astnav.GetStartOfNode(closeTag:TagName(), sourceFile, false)
        local closeTagNameEnd = closeTag:TagName():End()
        -- do not return linked cursors if tags are not well-formed
        if openTagNameStart == astnav.GetStartOfNode(openTag, sourceFile, false) or closeTagNameStart == astnav.GetStartOfNode(closeTag, sourceFile, false) or
            openTagNameEnd == openTag:End() or closeTagNameEnd == closeTag:End() then
            return {}, nil
        end
        -- only return linked cursors if the cursor is within a tag name
        local positionInt = position
        if not (openTagNameStart <= positionInt and positionInt <= openTagNameEnd or closeTagNameStart <= positionInt and positionInt <= closeTagNameEnd) then
            return {}, nil
        end

        -- only return linked cursors if text in both tags is identical
        local openingTagText = scanner.GetTextOfNode(openTag:TagName())
        if openingTagText ~= scanner.GetTextOfNode(closeTag:TagName()) then
            return {}, nil
        end

        local openRange, openFidelity = self.converters:ToLSPRangeForFeature(sourceFile, core.NewTextRange(openTagNameStart, openTagNameEnd), spanmap.Feature.LinkedEditing)
        local closeRange, closeFidelity = self.converters:ToLSPRangeForFeature(sourceFile, core.NewTextRange(closeTagNameStart, closeTagNameEnd), spanmap.Feature.LinkedEditing)
        if not spanmap.Fidelity_IsExact(openFidelity) or not spanmap.Fidelity_IsExact(closeFidelity) then
            return {}, nil
        end

        return {
            linkedEditingRanges = {
                ranges = {
                    openRange,
                    closeRange,
                },
                wordPattern = ls.jsxTagWordPattern,
            },
        }, nil
    end
end
