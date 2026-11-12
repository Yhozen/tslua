local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local jsonrpc = require("tslua.jsonrpc")

local supplementalGlobalsHandler = contentmappertest.defineHandler()
contentmappertest.supplementalGlobalsHandler = supplementalGlobalsHandler

function contentmappertest.newSupplementalGlobalsHandler()
    return setmetatable({}, supplementalGlobalsHandler)
end

function supplementalGlobalsHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local supplemental
        if contentmappertest.hasSuffix(p.fileName, "/a.vue") then
            supplemental = "/// <reference path=\"./extra.d.ts\" />\ninterface Shared extends Extra { value: string }"
        elseif contentmappertest.hasSuffix(p.fileName, "/b.vue") then
            supplemental = "declare const shared: Shared;"
        else
            return nil, jsonrpc.NewError("contentmappertest: unexpected supplemental global input " .. jsonrpc.goQuote(p.fileName))
        end
        return contentmapper.NewTransformResult({
            text = "export default shared.value;",
            extension = ".ts",
            supplemental = { contentmapper.NewSupplementalOutput({ text = supplemental, extension = ".ts" }) },
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
