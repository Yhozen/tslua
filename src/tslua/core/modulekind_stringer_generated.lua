local core = require("tslua.core")

local names = {
    [0] = "None",
    [1] = "CommonJS",
    [2] = "AMD",
    [3] = "UMD",
    [4] = "System",
    [5] = "ES2015",
    [6] = "ES2020",
    [7] = "ES2022",
    [99] = "ESNext",
    [100] = "Node16",
    [101] = "Node18",
    [102] = "Node20",
    [199] = "NodeNext",
    [200] = "Preserve",
}

function core.ModuleKind_String(i)
    local name = names[i]
    if name == nil then
        return "ModuleKind(" .. string.format("%d", i) .. ")"
    end
    return name
end
