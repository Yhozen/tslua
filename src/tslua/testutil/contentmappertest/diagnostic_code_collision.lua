local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local diagnostics = require("tslua.diagnostics")

local diagnosticCodeCollisionHandler = contentmappertest.defineHandler()
contentmappertest.diagnosticCodeCollisionHandler = diagnosticCodeCollisionHandler

function contentmappertest.newDiagnosticCodeCollisionHandler()
    return setmetatable({}, diagnosticCodeCollisionHandler)
end

function diagnosticCodeCollisionHandler:HandleRequest(ctx, method, params)
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
        local start = contentmappertest.index(p.content, "foo")
        local result = contentmapper.NewTransformResult(mappedOutput)
        result.diagnostics = { contentmapper.NewDiagnostic({
            messageText = "Mapper diagnostic with a colliding code.",
            start = start,
            length = #"foo",
            code = diagnostics.Function_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations:Code(),
        }) }
        return result, nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end
