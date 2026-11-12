local ls = require("tslua.ls")
local lsproto = require("tslua.lsp.lsproto")
local lsutil = require("tslua.ls.lsutil")

local ScriptElementKind = lsutil.ScriptElementKind
local ScriptElementKindModifier = lsutil.ScriptElementKindModifier

-- vsImageCatalogGuid is the GUID of the shared VS image catalog (see
-- Microsoft.VisualStudio.Imaging.KnownImageIds), mirroring the constant duplicated in
-- TypeScript-VS's ImageIdMapping.cs (which avoids taking an assembly reference just for this GUID).
ls.vsImageCatalogGuid = "ae27a6b0-e345-4288-96df-5eaf394ee369"

-- Known image IDs from Microsoft.VisualStudio.Imaging.KnownImageIds, restricted to the subset
-- consumed by TypeScript-VS's ImageIdMapping.cs for hover tooltips. Corsa (this LSP server) has no
-- TSServer/Roslyn dependency to reuse that mapping from, so the values are duplicated here.
ls.imageIdWarning = 0x00000637
ls.imageIdKeyword = 0x00000635
ls.imageIdModulePrivate = 0x0000077D
ls.imageIdModuleProtected = 0x0000077E
ls.imageIdModulePublic = 0x0000077F
ls.imageIdType = 0x00000CA1
ls.imageIdNamespace = 0x0000079F
ls.imageIdClassPrivate = 0x000001D7
ls.imageIdClassProtected = 0x000001D8
ls.imageIdClassPublic = 0x000001D9
ls.imageIdInterfacePrivate = 0x00000646
ls.imageIdInterfaceProtected = 0x00000647
ls.imageIdInterfacePublic = 0x00000648
ls.imageIdEnumPrivate = 0x00000469
ls.imageIdEnumProtected = 0x0000046A
ls.imageIdEnumPublic = 0x0000046B
ls.imageIdEnumMember = 0x00000465
ls.imageIdLocalVariable = 0x000006D3
ls.imageIdPropertyPrivate = 0x00000982
ls.imageIdPropertyProtected = 0x00000983
ls.imageIdPropertyPublic = 0x00000984
ls.imageIdMethodPrivate = 0x00000756
ls.imageIdMethodProtected = 0x00000757
ls.imageIdMethodPublic = 0x00000758
ls.imageIdLabel = 0x0000067D
ls.imageIdAssembly = 0x000000C4
ls.imageIdConstantPrivate = 0x0000026A
ls.imageIdConstantProtected = 0x0000026B
ls.imageIdConstantPublic = 0x0000026C

function ls.newVSImageId(id)
    return { guid = ls.vsImageCatalogGuid, id = id }
end

local classKinds = {
    [ScriptElementKind.ConstructorImplementationElement] = true,
    [ScriptElementKind.ClassElement] = true,
    [ScriptElementKind.LocalClassElement] = true,
    [ScriptElementKind.TypeElement] = true,
}
local localVariableKinds = {
    [ScriptElementKind.ParameterElement] = true,
    [ScriptElementKind.VariableElement] = true,
    [ScriptElementKind.LocalVariableElement] = true,
    [ScriptElementKind.VariableUsingElement] = true,
    [ScriptElementKind.VariableAwaitUsingElement] = true,
    [ScriptElementKind.LetElement] = true,
    [ScriptElementKind.String] = true,
}
local propertyKinds = {
    [ScriptElementKind.MemberGetAccessorElement] = true,
    [ScriptElementKind.MemberSetAccessorElement] = true,
    [ScriptElementKind.MemberVariableElement] = true,
    [ScriptElementKind.MemberAccessorVariableElement] = true,
}
local methodKinds = {
    [ScriptElementKind.FunctionElement] = true,
    [ScriptElementKind.LocalFunctionElement] = true,
    [ScriptElementKind.MemberFunctionElement] = true,
    [ScriptElementKind.CallSignatureElement] = true,
    [ScriptElementKind.IndexSignatureElement] = true,
    [ScriptElementKind.ConstructSignatureElement] = true,
}

-- getVSHoverImageId maps a symbol's ScriptElementKind/modifiers to the VS image shown next to the
-- symbol name in hover tooltips. This mirrors TypeScript-VS's ImageIdMapping.GetImageId, which the
-- legacy (TSServer-backed) hover path uses; Corsa has no TSServer to source that mapping from, so
-- the LSP hover response must carry the equivalent icon directly.
function ls.getVSHoverImageId(kind, modifiers)
    local isPrivate = modifiers & ScriptElementKindModifier.Private ~= 0
    local isProtected = modifiers & ScriptElementKindModifier.Protected ~= 0

    -- No internal/exported arm: the *Internal VS icons carry a chevron overlay that conveys
    -- C# assembly-scoped visibility, a concept that doesn't apply to TypeScript.
    local function pick(private, protected, public)
        if isPrivate then
            return ls.newVSImageId(private)
        elseif isProtected then
            return ls.newVSImageId(protected)
        else
            return ls.newVSImageId(public)
        end
    end

    if kind == ScriptElementKind.Warning then
        return ls.newVSImageId(ls.imageIdWarning)
    elseif kind == ScriptElementKind.Keyword then
        return ls.newVSImageId(ls.imageIdKeyword)
    elseif kind == ScriptElementKind.ScriptElement then
        return pick(ls.imageIdModulePrivate, ls.imageIdModuleProtected, ls.imageIdModulePublic)
    elseif kind == ScriptElementKind.PrimitiveType then
        return ls.newVSImageId(ls.imageIdType)
    elseif kind == ScriptElementKind.ModuleElement then
        return ls.newVSImageId(ls.imageIdNamespace)
    elseif classKinds[kind] then
        return pick(ls.imageIdClassPrivate, ls.imageIdClassProtected, ls.imageIdClassPublic)
    elseif kind == ScriptElementKind.InterfaceElement then
        return pick(ls.imageIdInterfacePrivate, ls.imageIdInterfaceProtected, ls.imageIdInterfacePublic)
    elseif kind == ScriptElementKind.EnumElement then
        return pick(ls.imageIdEnumPrivate, ls.imageIdEnumProtected, ls.imageIdEnumPublic)
    elseif kind == ScriptElementKind.EnumMemberElement then
        return ls.newVSImageId(ls.imageIdEnumMember)
    elseif localVariableKinds[kind] then
        return ls.newVSImageId(ls.imageIdLocalVariable)
    elseif kind == ScriptElementKind.ConstElement then
        return pick(ls.imageIdConstantPrivate, ls.imageIdConstantProtected, ls.imageIdConstantPublic)
    elseif propertyKinds[kind] then
        return pick(ls.imageIdPropertyPrivate, ls.imageIdPropertyProtected, ls.imageIdPropertyPublic)
    elseif methodKinds[kind] then
        return pick(ls.imageIdMethodPrivate, ls.imageIdMethodProtected, ls.imageIdMethodPublic)
    elseif kind == ScriptElementKind.TypeParameterElement then
        return ls.newVSImageId(ls.imageIdType)
    elseif kind == ScriptElementKind.Label then
        return ls.newVSImageId(ls.imageIdLabel)
    elseif kind == ScriptElementKind.Alias then
        return ls.newVSImageId(ls.imageIdModulePublic)
    else
        return ls.newVSImageId(ls.imageIdAssembly)
    end
end

-- buildVSHoverRawContent assembles the VS-specific rich hover content (symbol icon + colorized
-- declaration line, plus an optional colorized documentation block) matching the shape that
-- TypeScript-VS's legacy HoverService.cs builds from TSServer's quickinfo-full response
-- (ImageElement + ClassifiedTextElement wrapped in a ContainerElement).
function ls.buildVSHoverRawContent(imageId, quickInfoRuns, documentationRuns)
    if quickInfoRuns == nil or #quickInfoRuns == 0 then
        return nil
    end

    local displayLine = {
        style = lsproto.VSContainerElementStyle.Wrapped,
        elements = {
            { imageElement = { imageId = imageId } },
            { classifiedTextElement = { runs = quickInfoRuns } },
        },
    }

    if documentationRuns == nil or #documentationRuns == 0 then
        return displayLine
    end

    return {
        style = lsproto.VSContainerElementStyle.Stacked,
        elements = {
            { containerElement = displayLine },
            { classifiedTextElement = { runs = documentationRuns } },
        },
    }
end
