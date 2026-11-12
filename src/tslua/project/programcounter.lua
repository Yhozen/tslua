local project = require("tslua.project")

-- programCounter: refs maps *compiler.Program -> count.
local programCounter = {}
programCounter.__index = programCounter
project.programCounter = programCounter

function project.newProgramCounter()
    return setmetatable({ refs = nil }, programCounter)
end

-- Ref increments the reference count for a program. If the program is not
-- yet tracked, it is added with a reference count of 1.
function programCounter:Ref(program)
    if self.refs == nil then
        self.refs = {}
    end
    self.refs[program] = (self.refs[program] or 0) + 1
end

function programCounter:Deref(program)
    local count = self.refs ~= nil and self.refs[program] or nil
    if count == nil then
        return false
    end
    count = count - 1
    if count < 0 then
        error("program reference count went below zero", 0)
    end
    if count == 0 then
        self.refs[program] = nil
        return true
    end
    self.refs[program] = count
    return false
end

function programCounter:Len()
    return project.mapLen(self.refs)
end
