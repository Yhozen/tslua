local dirty = require("tslua.project.dirty")

-- Box holds a Cloneable value (a table with a Clone method, or nil).
local Box = {}
Box.__index = Box
dirty.Box = Box

function dirty.NewBox(original)
    return setmetatable({ original = original, value = original, dirty = false, delete = false }, Box)
end

function Box:Value()
    if self.delete then
        return nil
    end
    return self.value
end

function Box:Original()
    return self.original
end

function Box:Dirty()
    return self.dirty
end

function Box:Set(value)
    self.value = value
    self.delete = false
    self.dirty = true
end

function Box:Change(apply)
    if not self.dirty then
        self.value = self.value:Clone()
        self.dirty = true
    end
    apply(self.value)
end

function Box:ChangeIf(cond, apply)
    if cond(self.value) then
        self:Change(apply)
        return true
    end
    return false
end

function Box:Delete()
    self.delete = true
end

function Box:Locked(fn)
    fn(self)
end

-- Finalize returns (value, changed).
function Box:Finalize()
    return self:Value(), self.dirty or self.delete
end
