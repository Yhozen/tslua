local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local spanmap = require("tslua.spanmap")

local synthesizedOutput = "export const el = jsxRuntime(Widget);\n"

local synthesizingHandler = contentmappertest.defineHandler()
contentmappertest.synthesizingHandler = synthesizingHandler

function contentmappertest.newSynthesizingHandler()
    return setmetatable({}, synthesizingHandler)
end

function synthesizingHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local _, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local mappings
        mappings, err = spanmap.New(nil):Marshal()
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = synthesizedOutput,
            extension = ".ts",
            mappings = mappings,
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
