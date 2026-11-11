local tspath = require("tslua.tspath")

tspath.ignoredPaths = {
    "/node_modules/.",
    "/.git",
    ".#",
}

function tspath.ContainsIgnoredPath(path)
    for _, pattern in ipairs(tspath.ignoredPaths) do
        if string.find(path, pattern, 1, true) then
            return true
        end
    end
    return false
end
