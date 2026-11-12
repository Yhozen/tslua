local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local spanmap = require("tslua.spanmap")

local duplicateHandler = contentmappertest.defineHandler()
contentmappertest.duplicateHandler = duplicateHandler

function contentmappertest.newDuplicateHandler()
    return setmetatable({}, duplicateHandler)
end

local function verbatim(virtualStart, length, features)
    return spanmap.NewSegment({
        virtualStart = virtualStart,
        virtualEnd = virtualStart + length,
        originalStart = 0,
        originalEnd = length,
        kind = spanmap.Kind.Verbatim,
        features = features,
    })
end

function duplicateHandler:HandleRequest(ctx, method, params)
    local index = contentmappertest.index
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local content = p.content
        if contentmappertest.contains(p.fileName, "rename-conflict") then
            local virtual = "export const " .. content .. " = 1;\nconst object = { " .. content .. " };\n" .. content .. ";\n"
            local first = index(virtual, content)
            local second = index(string.sub(virtual, first + #content + 1), content) + first + #content
            local third = index(string.sub(virtual, second + #content + 1), content) + second + #content
            local mappings
            mappings, err = spanmap.New({
                verbatim(first, #content, spanmap.Feature.Rename),
                verbatim(second, #content, spanmap.Feature.Rename),
                verbatim(third, #content, spanmap.Feature.Rename),
            }):Marshal()
            if err ~= nil then
                return nil, err
            end
            return contentmapper.NewTransformResult({ text = virtual, extension = ".ts", mappings = mappings }), nil
        end
        local virtual = "export const " .. content .. " = 1;\n" .. content .. ";\n"
        local first = #"export const "
        local second = first + #content + #" = 1;\n"
        local disabled = contentmappertest.contains(p.fileName, "disabled")
        local Feature = spanmap.Feature
        local semanticFeatures = Feature.Hover | Feature.Definition | Feature.References | Feature.Rename
        local navigationFeatures = Feature.Definition | Feature.References | Feature.Rename
        if disabled then
            semanticFeatures = Feature.None
            navigationFeatures = Feature.None
        end
        local mappings
        mappings, err = spanmap.New({
            verbatim(first, #content, semanticFeatures),
            verbatim(second, #content, navigationFeatures),
        }):Marshal()
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({ text = virtual, extension = ".ts", mappings = mappings }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
