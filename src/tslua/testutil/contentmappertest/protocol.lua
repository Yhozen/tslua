local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local spanmap = require("tslua.spanmap")
local jsonrpc = require("tslua.jsonrpc")

-- Handlers implement the ipc.Handler contract: HandleRequest(ctx, method, params) -> (result, err) with
-- params a jsonrpc.Value, and HandleNotification(ctx, method, params) -> err.

-- noNotifications provides the HandleNotification method shared by every test mapper.
function contentmappertest.noNotifications(T)
    function T.HandleNotification(_, ctx, method, params)
        return nil
    end
    return T
end

-- defineHandler creates a handler type (a class whose instances are the Go handler values).
function contentmappertest.defineHandler()
    local T = {}
    T.__index = T
    return contentmappertest.noNotifications(T)
end

-- rawParams returns the raw JSON text of request params.
function contentmappertest.rawParams(params)
    if params == nil then
        return ""
    end
    return params.data
end

-- unexpectedMethod is fmt.Errorf("contentmappertest: unexpected method %q", method).
function contentmappertest.unexpectedMethod(method)
    return jsonrpc.NewError("contentmappertest: unexpected method " .. jsonrpc.goQuote(method))
end

function contentmappertest.initializeResult(source)
    return contentmapper.NewInitializeResult({
        protocolVersion = contentmapper.ProtocolVersion,
        positionEncoding = contentmapper.PositionEncoding.UTF8,
        diagnosticSource = source,
    })
end

-- identityMappedOutput returns (MappedOutput, err).
function contentmappertest.identityMappedOutput(content)
    local mappings, err = spanmap.New({ spanmap.NewSegment({
        virtualEnd = #content,
        originalEnd = #content,
        kind = spanmap.Kind.Verbatim,
        features = spanmap.Feature.All,
    }) }):Marshal()
    if err ~= nil then
        return contentmapper.NewMappedOutput(), err
    end
    return contentmapper.NewMappedOutput({ text = content, extension = ".ts", mappings = mappings }), nil
end

-- staticProjectHandler embeds an ipc.Handler and answers the project lifecycle requests itself.
local staticProjectHandler = {}
staticProjectHandler.__index = staticProjectHandler
contentmappertest.staticProjectHandler = staticProjectHandler

function contentmappertest.newStaticProjectHandler(handler)
    return setmetatable({ handler = handler }, staticProjectHandler)
end

function staticProjectHandler:HandleNotification(ctx, method, params)
    return self.handler:HandleNotification(ctx, method, params)
end

-- projectLifecycleHandler interface: OpenProject(params) -> err, CloseProject(params).
local function isProjectLifecycleHandler(h)
    return type(h.OpenProject) == "function" and type(h.CloseProject) == "function"
end

function staticProjectHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodOpenProject then
        local p, err = contentmapper.UnmarshalOpenProjectParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        if isProjectLifecycleHandler(self.handler) then
            err = self.handler:OpenProject(p)
            if err ~= nil then
                return nil, err
            end
        end
        local diagnostics = nil
        if p.options == [[{"plugins":[{"name":1}]}]] then
            diagnostics = { contentmapper.NewOptionDiagnosticResult({
                path = { [["plugins"]], [[0]], [["name"]] },
                messageText = "Option 'name' requires a string.",
                code = 123,
            }) }
        end
        return contentmapper.NewOpenProjectResult({ optionDiagnostics = diagnostics }), nil
    elseif method == contentmapper.MethodCloseProject then
        local p, err = contentmapper.UnmarshalCloseProjectParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        if isProjectLifecycleHandler(self.handler) then
            self.handler:CloseProject(p)
        end
        return nil, nil
    end
    return self.handler:HandleRequest(ctx, method, params)
end

-- Go strings helpers used by the test mappers.
function contentmappertest.hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function contentmappertest.hasSuffix(s, suffix)
    return #suffix <= #s and string.sub(s, #s - #suffix + 1) == suffix
end

function contentmappertest.contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

function contentmappertest.trimSpace(s)
    return (string.gsub(string.gsub(s, "^[ \t\r\n\v\f]+", ""), "[ \t\r\n\v\f]+$", ""))
end

-- index is strings.Index (0-based, -1 when absent).
function contentmappertest.index(s, sub)
    local i = string.find(s, sub, 1, true)
    if i == nil then
        return -1
    end
    return i - 1
end
