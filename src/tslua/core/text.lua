local core = require("tslua.core")

-- TextPos is a plain integer (0-based byte offset).

-- TextRange is an immutable value: { pos = <int>, end_ = <int> }. Never mutate one; build a
-- new one with core.NewTextRange / WithPos / WithEnd.
local TextRange = {}
TextRange.__index = TextRange
core.TextRange = TextRange

TextRange.__eq = function(a, b)
    return a.pos == b.pos and a.end_ == b.end_
end

TextRange.__tostring = function(t)
    return "{" .. tostring(t.pos) .. " " .. tostring(t.end_) .. "}"
end

function core.NewTextRange(pos, end_)
    return setmetatable({ pos = pos, end_ = end_ }, TextRange)
end

local undefinedTextRange = setmetatable({ pos = -1, end_ = -1 }, TextRange)

function core.UndefinedTextRange()
    return undefinedTextRange
end

function TextRange:Pos()
    return self.pos
end

function TextRange:End()
    return self.end_
end

function TextRange:Len()
    return self.end_ - self.pos
end

function TextRange:IsValid()
    return self.pos >= 0 or self.end_ >= 0
end

function TextRange:Contains(pos)
    return pos >= self.pos and pos < self.end_
end

function TextRange:ContainsInclusive(pos)
    return pos >= self.pos and pos <= self.end_
end

function TextRange:ContainsExclusive(pos)
    return self.pos < pos and pos < self.end_
end

function TextRange:WithPos(pos)
    return core.NewTextRange(pos, self.end_)
end

function TextRange:WithEnd(end_)
    return core.NewTextRange(self.pos, end_)
end

function TextRange:ContainedBy(t2)
    return t2.pos <= self.pos and t2.end_ >= self.end_
end

function TextRange:Overlaps(t2)
    local start = math.max(self.pos, t2.pos)
    local end_ = math.min(self.end_, t2.end_)
    return start < end_
end

-- Similar to Overlaps, but treats touching ranges as intersecting.
-- For example, [0, 5) intersects [5, 10).
function TextRange:Intersects(t2)
    local start = math.max(self.pos, t2.pos)
    local end_ = math.min(self.end_, t2.end_)
    return start <= end_
end

function core.CompareTextRanges(r1, r2)
    local c = r1.pos - r2.pos
    if c ~= 0 then
        return c
    end
    return r1.end_ - r2.end_
end
