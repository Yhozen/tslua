local harnessutil = require("tslua.testutil.harnessutil")

-- OutputRecorderFS embeds a vfs.FS (field FS; its methods are promoted through __index).
local OutputRecorderFS = {}
harnessutil.OutputRecorderFS = OutputRecorderFS
OutputRecorderFS.__index = function(self, key)
    local m = OutputRecorderFS[key]
    if m ~= nil then
        return m
    end
    local inner = rawget(self, "FS")
    local v = inner[key]
    if type(v) == "function" then
        return function(_, ...)
            return v(inner, ...)
        end
    end
    return v
end

function harnessutil.NewOutputRecorderFS(fs)
    return setmetatable({ FS = fs, outputsMap = nil, outputs = {} }, OutputRecorderFS)
end

function OutputRecorderFS:WriteFile(path, data)
    local err = self.FS:WriteFile(path, data)
    if err ~= nil then
        return err
    end
    path = self:Realpath(path)
    local index = self.outputsMap and self.outputsMap[path]
    if index ~= nil then
        self.outputs[index + 1] = harnessutil.NewTestFile(path, data)
    else
        index = #self.outputs
        if self.outputsMap == nil then
            self.outputsMap = {}
        end
        self.outputsMap[path] = index
        self.outputs[#self.outputs + 1] = harnessutil.NewTestFile(path, data)
    end
    return nil
end

function OutputRecorderFS:Outputs()
    local result = {}
    for i, o in ipairs(self.outputs) do
        result[i] = o
    end
    return result
end

return harnessutil
