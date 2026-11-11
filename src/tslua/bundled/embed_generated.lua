-- Lua counterpart of the generated embed_generated.go: instead of go:embed, the contents of
-- src/tslua/bundled/libs/<name> are read from disk on first access and cached.
local bundled = require("tslua.bundled")

local isLibName = nil

local function readLib(key)
    if isLibName == nil then
        isLibName = {}
        for _, name in ipairs(bundled.LibNames) do
            isLibName["libs/" .. name] = true
        end
    end
    if not isLibName[key] then
        return nil
    end
    local path = bundled.TestingLibPath() .. "/" .. string.sub(key, 6)
    local f = io.open(path, "rb")
    if f == nil then
        error("bundled: could not read " .. path, 0)
    end
    local contents = f:read("a")
    f:close()
    return contents
end

-- embeddedContents maps "libs/<name>" to the file contents.
bundled.embeddedContents = setmetatable({}, {
    __index = function(t, key)
        if type(key) ~= "string" then
            return nil
        end
        local contents = readLib(key)
        if contents ~= nil then
            rawset(t, key, contents)
        end
        return contents
    end,
})

local libsEntriesValue = nil

-- libsEntries is a function (Go: a package var) so that the sizes are only computed, by reading
-- the files, when a walk needs them.
function bundled.libsEntries()
    if libsEntriesValue == nil then
        libsEntriesValue = {}
        for i, name in ipairs(bundled.LibNames) do
            libsEntriesValue[i] = bundled.newFileInfo(name, 0, #bundled.embeddedContents["libs/" .. name])
        end
    end
    return libsEntriesValue
end

return bundled
