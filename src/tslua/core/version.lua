local core = require("tslua.core")

-- This is a var so it can be overridden by ldflags.
core.version = "7.1.0-dev"

function core.Version()
    return core.version
end

core.versionMajorMinor = (function()
    local version = core.version
    local seenMajor = false
    local i = -1
    for k = 1, #version do
        if string.byte(version, k) == 46 then -- '.'
            if seenMajor then
                i = k - 1
                break
            end
            seenMajor = true
        end
    end
    if i == -1 then
        error("invalid version string: " .. version, 0)
    end
    return string.sub(version, 1, i)
end)()

function core.VersionMajorMinor()
    return core.versionMajorMinor
end
