local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local spanmap = require("tslua.spanmap")

local prefixedSupplementalHandler = contentmappertest.defineHandler()
contentmappertest.prefixedSupplementalHandler = prefixedSupplementalHandler

function contentmappertest.newPrefixedSupplementalHandler()
    return setmetatable({}, prefixedSupplementalHandler)
end

function prefixedSupplementalHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local prefix = "/* generated */\n"
        local mappings
        mappings, err = spanmap.New({ spanmap.NewSegment({
            virtualStart = #prefix,
            virtualEnd = #prefix + #p.content,
            originalStart = 0,
            originalEnd = #p.content,
            kind = spanmap.Kind.Verbatim,
            features = spanmap.Feature.All,
        }) }):Marshal()
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = "export {};",
            extension = ".ts",
            supplemental = { contentmapper.NewSupplementalOutput({
                text = prefix .. p.content,
                extension = ".ts",
                mappings = mappings,
            }) },
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end

local unmappedFoldingHandler = contentmappertest.defineHandler()
contentmappertest.unmappedFoldingHandler = unmappedFoldingHandler

function contentmappertest.newUnmappedFoldingHandler()
    return setmetatable({}, unmappedFoldingHandler)
end

function unmappedFoldingHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local mappings, err = spanmap.New(nil):Marshal()
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = "import \"a\";\nimport \"b\";\n/*\n * generated\n */\nexport {};",
            extension = ".ts",
            mappings = mappings,
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
