local sourcemap = require("tslua.sourcemap")

local ECMALineInfo = {}
ECMALineInfo.__index = ECMALineInfo
sourcemap.ECMALineInfo = ECMALineInfo

-- lineStarts: array of 0-based line start positions (core.ECMALineStarts).
function sourcemap.CreateECMALineInfo(text, lineStarts)
    return setmetatable({
        text = text,
        lineStarts = lineStarts,
    }, ECMALineInfo)
end

function ECMALineInfo:LineCount()
    return #self.lineStarts
end

function ECMALineInfo:LineText(line)
    local pos = self.lineStarts[line + 1]
    local end_
    if line + 1 < #self.lineStarts then
        end_ = self.lineStarts[line + 2]
    else
        end_ = #self.text
    end
    return string.sub(self.text, pos + 1, end_)
end
