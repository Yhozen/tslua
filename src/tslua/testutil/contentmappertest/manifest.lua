local contentmappertest = require("tslua.testutil.contentmappertest")
local jsonrpc = require("tslua.jsonrpc")

contentmappertest.PackageName = "mapper"

-- PackageJSON returns a package manifest selecting the requested mapper.
function contentmappertest.PackageJSON(mapper)
    local compilerOptions = ""
    local dynamicConfig = ""
    if mapper == contentmappertest.TransformingMapper then
        compilerOptions = [=[, "compilerOptions": ["target", "jsx"]]=]
    end
    if mapper == contentmappertest.DynamicVerbatimMapper then
        dynamicConfig = [[, "dynamicConfig": true]]
    end
    return "{\n\t\"name\": " .. jsonrpc.goQuote(contentmappertest.PackageName) .. ",\n\t\"version\": \"1.0.0\",\n\t\"typescript\": { \"contentMapper\": { \"exec\": [" ..
        jsonrpc.goQuote(mapper) .. "]" .. compilerOptions .. dynamicConfig .. " } }\n}"
end
