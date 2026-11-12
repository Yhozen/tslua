local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local jsonrpc = require("tslua.jsonrpc")
local spanmap = require("tslua.spanmap")

local lispHandler = contentmappertest.defineHandler()
contentmappertest.lispHandler = lispHandler

function contentmappertest.newLispHandler()
    return setmetatable({}, lispHandler)
end

function lispHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("lisp"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local content = p.content
        if string.sub(content, -1) == "\n" then
            content = string.sub(content, 1, -2)
        end
        if content ~= [[(+ 1 2 "oops")]] then
            return nil, jsonrpc.NewError("contentmappertest: unsupported Lisp expression " .. jsonrpc.goQuote(p.content))
        end
        local mappings
        mappings, err = spanmap.New({
            spanmap.NewSegment({ virtualStart = 0, virtualEnd = 3, originalStart = 1, originalEnd = 2, kind = spanmap.Kind.Alias, features = spanmap.Feature.All }),
            spanmap.NewSegment({ virtualStart = 4, virtualEnd = 5, originalStart = 3, originalEnd = 4, kind = spanmap.Kind.Verbatim, features = spanmap.Feature.All }),
            spanmap.NewSegment({ virtualStart = 7, virtualEnd = 8, originalStart = 5, originalEnd = 6, kind = spanmap.Kind.Verbatim, features = spanmap.Feature.All }),
            spanmap.NewSegment({ virtualStart = 10, virtualEnd = 16, originalStart = 7, originalEnd = 13, kind = spanmap.Kind.Verbatim, features = spanmap.Feature.All }),
        }):Marshal()
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = [[add(1, 2, "oops");]],
            extension = ".ts",
            mappings = mappings,
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
