local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local jsonrpc = require("tslua.jsonrpc")
local tspath = require("tslua.tspath")

-- ProjectLifecycle records mapper project protocol calls: { opens = int, closes = int }.
function contentmappertest.NewProjectLifecycle()
    return { opens = 0, closes = 0 }
end

-- dynamicVerbatimHandler embeds verbatimHandler.
local dynamicVerbatimHandler = contentmappertest.defineHandler()
contentmappertest.dynamicVerbatimHandler = dynamicVerbatimHandler

function contentmappertest.newDynamicVerbatimHandler(lifecycle)
    return setmetatable({ verbatimHandler = contentmappertest.newVerbatimHandler(), lifecycle = lifecycle }, dynamicVerbatimHandler)
end

function dynamicVerbatimHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodOpenProject then
        if self.lifecycle ~= nil then
            self.lifecycle.opens = self.lifecycle.opens + 1
        end
        local p, err = contentmapper.UnmarshalOpenProjectParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local identity = p.configFileName .. ":" .. p.options
        local diagnostics = nil
        if p.options == [[{"plugins":[{"name":1}]}]] then
            diagnostics = { contentmapper.NewOptionDiagnosticResult({
                path = { [["plugins"]], [[0]], [["name"]] },
                messageText = "Option 'name' requires a string.",
                code = 123,
            }) }
        end
        local watchDirectory = tspath.GetDirectoryPath(p.configFileName)
        if watchDirectory == "" then
            watchDirectory = "/"
        end
        return contentmapper.NewOpenProjectResult({
            configIdentity = identity,
            watchedFiles = { tspath.CombinePaths(watchDirectory, "mapper.config.json") },
            optionDiagnostics = diagnostics,
        }), nil
    elseif method == contentmapper.MethodCloseProject then
        if self.lifecycle ~= nil then
            self.lifecycle.closes = self.lifecycle.closes + 1
        end
        return nil, nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        if p.projectHandle == "" then
            return nil, jsonrpc.NewError("content mapper transform requires a project handle")
        end
    end
    return self.verbatimHandler:HandleRequest(ctx, method, params)
end
