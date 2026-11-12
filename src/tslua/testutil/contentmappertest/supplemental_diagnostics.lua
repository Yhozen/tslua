local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local spanmap = require("tslua.spanmap")

local supplementalDiagnosticsHandler = contentmappertest.defineHandler()
contentmappertest.supplementalDiagnosticsHandler = supplementalDiagnosticsHandler

function contentmappertest.newSupplementalDiagnosticsHandler()
    return setmetatable({}, supplementalDiagnosticsHandler)
end

function supplementalDiagnosticsHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local prefix = "missingSupplementalGlobal;\n"
        local mappings
        mappings, err = spanmap.New({ spanmap.NewSegment({
            virtualStart = #prefix,
            virtualEnd = #prefix + #p.content,
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
            supplemental = { contentmapper.NewSupplementalOutput({ text = prefix .. p.content, extension = ".ts", mappings = mappings }) },
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
