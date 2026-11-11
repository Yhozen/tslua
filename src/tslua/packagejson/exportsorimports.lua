local packagejson = require("tslua.packagejson")

local JSONValueType = packagejson.JSONValueType

packagejson.objectKindUnknown = 0
packagejson.objectKindSubpaths = 1
packagejson.objectKindConditions = 2
packagejson.objectKindImports = 3
packagejson.objectKindInvalid = 4

-- ExportsOrImports embeds JSONValue; objects hold ExportsOrImports values.
local ExportsOrImports = setmetatable({}, { __index = packagejson.JSONValue })
ExportsOrImports.__index = ExportsOrImports
packagejson.ExportsOrImports = ExportsOrImports

function packagejson.NewExportsOrImports()
    return setmetatable({ type = JSONValueType.NotPresent, value = nil, objectKind = packagejson.objectKindUnknown }, ExportsOrImports)
end

-- UnmarshalJSONFrom. objectKind is computed lazily (nil means objectKindUnknown).
function packagejson.unmarshalExportsOrImports(decoded)
    return packagejson.unmarshalJSONValue(ExportsOrImports, decoded)
end

function ExportsOrImports:AsObject()
    if self.type ~= JSONValueType.Object then
        error("expected object", 0)
    end
    return self.value
end

function ExportsOrImports:AsArray()
    if self.type ~= JSONValueType.Array then
        error("expected array", 0)
    end
    return self.value
end

function ExportsOrImports:IsSubpaths()
    self:initObjectKind()
    return self.objectKind == packagejson.objectKindSubpaths
end

function ExportsOrImports:IsImports()
    self:initObjectKind()
    return self.objectKind == packagejson.objectKindImports
end

function ExportsOrImports:IsConditions()
    self:initObjectKind()
    return self.objectKind == packagejson.objectKindConditions
end

function ExportsOrImports:initObjectKind()
    if (self.objectKind or packagejson.objectKindUnknown) == packagejson.objectKindUnknown and self.type == JSONValueType.Object then
        local obj = self:AsObject()
        if obj:Size() > 0 then
            local seenDot, seenHash, seenOther = false, false, false
            for k in obj:Keys() do
                if #k > 0 then
                    local c = string.sub(k, 1, 1)
                    seenDot = seenDot or c == "."
                    seenHash = seenHash or c == "#"
                    seenOther = seenOther or (c ~= "." and c ~= "#")
                    if seenOther and (seenDot or seenHash) then
                        self.objectKind = packagejson.objectKindInvalid
                        return
                    end
                end
            end
            if seenDot then
                self.objectKind = packagejson.objectKindSubpaths
                return
            end
            if seenHash then
                self.objectKind = packagejson.objectKindImports
                return
            end
        end
        self.objectKind = packagejson.objectKindConditions
    end
end
