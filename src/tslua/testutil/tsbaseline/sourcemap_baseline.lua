local tsbaseline = require("tslua.testutil.tsbaseline")
local baseline = require("tslua.testutil.baseline")
local core = require("tslua.core")
local json = require("tslua.json")
local tspath = require("tslua.tspath")

function tsbaseline.DoSourcemapBaseline(t, baselinePath, header, options, result, harnessSettings, opts)
    local declMaps = options:GetAreDeclarationMapsEnabled()
    if core.Tristate_IsTrue(options.inlineSourceMap) then
        if result.maps:Size() > 0 and not declMaps then
            t:Fatal("No sourcemap files should be generated if inlineSourceMaps was set.")
        end
        return
    elseif core.Tristate_IsTrue(options.sourceMap) or declMaps then
        local expectedMapCount = 0
        if core.Tristate_IsTrue(options.sourceMap) then
            expectedMapCount = expectedMapCount + result:GetNumberOfJSFiles(false --[[includeJSON]])
        end
        if declMaps then
            expectedMapCount = expectedMapCount + result:GetNumberOfJSFiles(true --[[includeJSON]])
        end
        if result.maps:Size() ~= expectedMapCount then
            t:Fatal("Number of sourcemap files should be same as js files.")
        end

        local sourceMapCode
        if core.Tristate_IsTrue(options.noEmitOnError) and core.Len(result.diagnostics) ~= 0 or result.maps:Size() == 0 then
            sourceMapCode = baseline.NoContent
        else
            local sourceMapCodeBuilder = core.NewStringBuilder()
            for sourceMap in result.maps:Values() do
                if sourceMapCodeBuilder:Len() > 0 then
                    sourceMapCodeBuilder:WriteString("\r\n")
                end
                sourceMapCodeBuilder:WriteString(tsbaseline.fileOutput(sourceMap, harnessSettings))
                if not core.Tristate_IsTrue(options.inlineSourceMap) then
                    sourceMapCodeBuilder:WriteString(tsbaseline.createSourceMapPreviewLink(sourceMap, result))
                end
            end
            sourceMapCode = sourceMapCodeBuilder:String()
        end

        if tspath.FileExtensionIsOneOf(baselinePath, { tspath.ExtensionTs, tspath.ExtensionTsx }) then
            baselinePath = tspath.ChangeExtension(baselinePath, tspath.ExtensionJs .. ".map")
        end

        baseline.Run(t, baselinePath, sourceMapCode, opts)
    end
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

function tsbaseline.createSourceMapPreviewLink(sourceMap, result)
    local sourcemapJSON, err = json.Unmarshal(sourceMap.content)
    if err ~= nil then
        error(err, 0)
    end
    local file = sourcemapJSON.file or ""
    local sources = sourcemapJSON.sources or {}

    local outputJSFile = core.Find(result:Outputs(), function(td)
        return hasSuffix(td.unitName, file)
    end)

    -- !!! Strada uses a fallible approach to associating inputs and outputs derived from a source map output. The
    -- !!! commented logic below should be used after the Strada migration is complete:

    ----inputsAndOutputs := result.GetInputsAndOutputsForFile(sourceMap.UnitName)
    ----outputJSFile := inputsAndOutputs.Js

    if outputJSFile == nil then
        return ""
    end

    local sourceTDs = {}
    for i, s in ipairs(sources) do
        local td = core.Find(result:Inputs(), function(x)
            return hasSuffix(x.unitName, s)
        end)
        if td == nil then
            return ""
        end
        sourceTDs[i] = td
    end

    local hash = core.NewStringBuilder()
    hash:WriteString("\n//// https://sokra.github.io/source-map-visualization#base64,")
    hash:WriteString(tsbaseline.base64EncodeChunk(outputJSFile.content))
    hash:WriteString(",")
    hash:WriteString(tsbaseline.base64EncodeChunk(sourceMap.content))
    for _, td in ipairs(sourceTDs) do
        hash:WriteString(",")
        hash:WriteString(tsbaseline.base64EncodeChunk(td.content))
    end
    hash:WriteString("\n")
    return hash:String()
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- base64.StdEncoding.EncodeToString
local function base64Encode(s)
    local out = {}
    local n = #s
    for i = 1, n, 3 do
        local a, b, c = string.byte(s, i, i + 2)
        local v = (a << 16) | ((b or 0) << 8) | (c or 0)
        local c1 = (v >> 18) & 63
        local c2 = (v >> 12) & 63
        local c3 = (v >> 6) & 63
        local c4 = v & 63
        out[#out + 1] = string.sub(b64chars, c1 + 1, c1 + 1) .. string.sub(b64chars, c2 + 1, c2 + 1) ..
            (b ~= nil and string.sub(b64chars, c3 + 1, c3 + 1) or "=") ..
            (c ~= nil and string.sub(b64chars, c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end
tsbaseline.base64Encode = base64Encode

-- Go: url.QueryUnescape(url.QueryEscape(s)) (an identity) followed by base64.
function tsbaseline.base64EncodeChunk(s)
    return base64Encode(s)
end

return tsbaseline
