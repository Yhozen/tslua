local core = require("tslua.core")

-- TextChange embeds TextRange: { pos = int, end_ = int, newText = string } with TextRange's methods.
local TextChange = setmetatable({}, { __index = core.TextRange })
TextChange.__index = TextChange
core.TextChange = TextChange

function core.NewTextChange(textRange, newText)
    return setmetatable({ pos = textRange.pos, end_ = textRange.end_, newText = newText }, TextChange)
end

-- Go t.TextRange
function TextChange:GetTextRange()
    return core.NewTextRange(self.pos, self.end_)
end

function TextChange:ApplyTo(text)
    return string.sub(text, 1, self:Pos()) .. self.newText .. string.sub(text, self:End() + 1)
end

function core.ApplyBulkEdits(text, edits)
    local b = core.NewStringBuilder()
    local lastEnd = 0
    for _, e in ipairs(edits or {}) do
        local start = e.pos
        if start ~= lastEnd then
            b:WriteString(string.sub(text, lastEnd + 1, e.pos))
        end
        b:WriteString(e.newText)

        lastEnd = e.end_
    end
    b:WriteString(string.sub(text, lastEnd + 1))

    return b:String()
end
