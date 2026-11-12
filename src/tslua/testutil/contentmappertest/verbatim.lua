local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")

local verbatimHandler = contentmappertest.defineHandler()
contentmappertest.verbatimHandler = verbatimHandler

local moduleVerbatimHandler = contentmappertest.defineHandler()
contentmappertest.moduleVerbatimHandler = moduleVerbatimHandler

function contentmappertest.newVerbatimHandler()
    return setmetatable({}, verbatimHandler)
end

function contentmappertest.newModuleVerbatimHandler()
    return setmetatable({}, moduleVerbatimHandler)
end

function verbatimHandler:HandleRequest(ctx, method, params)
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
        return contentmapper.NewTransformResult(mappedOutput), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end

function moduleVerbatimHandler:HandleRequest(ctx, method, params)
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
        mappedOutput.extension = ".mts"
        return contentmapper.NewTransformResult(mappedOutput), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
