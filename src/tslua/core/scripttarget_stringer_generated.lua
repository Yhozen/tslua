local core = require("tslua.core")

local names = {
    [0] = "None",
    [1] = "ES5",
    [2] = "ES2015",
    [3] = "ES2016",
    [4] = "ES2017",
    [5] = "ES2018",
    [6] = "ES2019",
    [7] = "ES2020",
    [8] = "ES2021",
    [9] = "ES2022",
    [10] = "ES2023",
    [11] = "ES2024",
    [12] = "ES2025",
    [99] = "ESNext",
    [100] = "JSON",
}

function core.ScriptTarget_String(i)
    local name = names[i]
    if name == nil then
        return "ScriptTarget(" .. string.format("%d", i) .. ")"
    end
    return name
end
