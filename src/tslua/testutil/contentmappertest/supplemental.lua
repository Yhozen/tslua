local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")

local supplementalHandler = contentmappertest.defineHandler()
contentmappertest.supplementalHandler = supplementalHandler

function contentmappertest.newSupplementalHandler()
    return setmetatable({}, supplementalHandler)
end

function supplementalHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local mappedOutput
        mappedOutput, err = contentmappertest.identityMappedOutput(p.content)
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = "export {};",
            extension = ".ts",
            supplemental = { mappedOutput },
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
