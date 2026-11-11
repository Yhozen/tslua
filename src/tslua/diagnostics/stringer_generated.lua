local diagnostics = require("tslua.diagnostics")

local _Category_name = "CategoryWarningCategoryErrorCategorySuggestionCategoryMessage"

local _Category_index = { 0, 15, 28, 46, 61 }

function diagnostics.Category_String(i)
    local idx = i - 0
    if i < 0 or idx >= #_Category_index - 1 then
        return "Category(" .. string.format("%d", i) .. ")"
    end
    return string.sub(_Category_name, _Category_index[idx + 1] + 1, _Category_index[idx + 2])
end
