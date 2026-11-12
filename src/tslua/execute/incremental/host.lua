local incremental = require("tslua.execute.incremental")

-- Host interface: FS(), GetMTime(fileName), SetMTime(fileName, mTime).
local host = {}
host.__index = host
incremental.host = host

function host:FS()
    return self.host:FS()
end

function host:GetMTime(fileName)
    return incremental.GetMTime(self.host, fileName)
end

function host:SetMTime(fileName, mTime)
    return self.host:FS():Chtimes(fileName, 0, mTime)
end

function incremental.CreateHost(compilerHost)
    return setmetatable({ host = compilerHost }, host)
end

-- time.Time values are numbers; the zero time is 0.
function incremental.GetMTime(host_, fileName)
    local stat = host_:FS():Stat(fileName)
    local mTime = 0
    if stat ~= nil then
        mTime = stat:ModTime()
    end
    return mTime
end
