local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")

local supplementalModuleHandler = contentmappertest.defineHandler()
contentmappertest.supplementalModuleHandler = supplementalModuleHandler

function contentmappertest.newSupplementalModuleHandler()
    return setmetatable({}, supplementalModuleHandler)
end

function supplementalModuleHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local _, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = "export default 1;",
            extension = ".ts",
            supplemental = { contentmapper.NewSupplementalOutput({ text = [[export const privateValue: number = "wrong";]], extension = ".ts" }) },
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
