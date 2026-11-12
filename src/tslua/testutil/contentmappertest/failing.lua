local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local jsonrpc = require("tslua.jsonrpc")

local failingHandler = contentmappertest.defineHandler()
contentmappertest.failingHandler = failingHandler

function contentmappertest.newFailingHandler()
    return setmetatable({}, failingHandler)
end

function failingHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        return nil, jsonrpc.NewError("content mapper failed to transform the file")
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
