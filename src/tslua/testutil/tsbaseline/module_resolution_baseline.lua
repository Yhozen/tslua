local tsbaseline = require("tslua.testutil.tsbaseline")
local baseline = require("tslua.testutil.baseline")

function tsbaseline.DoModuleResolutionBaseline(t, baselinePath, trace, opts)
    baselinePath = tsbaseline.tsExtension:ReplaceAllString(baselinePath, ".trace.json")
    local errorBaseline
    if trace ~= "" then
        errorBaseline = trace
    else
        errorBaseline = baseline.NoContent
    end
    baseline.Run(t, baselinePath, errorBaseline, opts)
end

return tsbaseline
