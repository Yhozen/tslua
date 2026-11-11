local tsbaseline = require("tslua.testutil.tsbaseline")
local baseline = require("tslua.testutil.baseline")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

function tsbaseline.DoSourcemapRecordBaseline(t, baselinePath, header, options, result, harnessSettings, opts)
    local actual = baseline.NoContent
    if core.Tristate_IsTrue(options.sourceMap) or core.Tristate_IsTrue(options.inlineSourceMap) or core.Tristate_IsTrue(options.declarationMap) then
        local record = tsbaseline.removeTestPathPrefixes(result:GetSourceMapRecord(), false --[[retainTrailingDirectorySeparator]])
        if not (core.Tristate_IsTrue(options.noEmitOnError) and core.Len(result.diagnostics) > 0) and #record > 0 then
            actual = record
        end
    end

    if tspath.FileExtensionIsOneOf(baselinePath, { tspath.ExtensionTs, tspath.ExtensionTsx }) then
        baselinePath = tspath.ChangeExtension(baselinePath, ".sourcemap.txt")
    end

    baseline.Run(t, baselinePath, actual, opts)
end

return tsbaseline
