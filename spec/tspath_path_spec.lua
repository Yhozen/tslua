-- Port of the internal/tspath/path_test.go tests not already in spec/tspath_spec.lua
-- (TestGetLongestExtensionFromPath, TestPathIsRelative). Benchmarks and fuzz tests are skipped.
local tspath = require("tslua.tspath")

describe("TestGetLongestExtensionFromPath", function()
    it("TestGetLongestExtensionFromPath", function()
        local extensions = { ".z", ".y.z", ".other" }
        assert.are.equal(".y.z", tspath.GetLongestExtensionFromPath("/src/Component.y.z", extensions, false))
        assert.are.equal(".z", tspath.GetLongestExtensionFromPath("/src/Component.z", extensions, false))
        assert.are.equal("", tspath.GetLongestExtensionFromPath("/src/Component.y.Z", extensions, false))
        assert.are.equal(".y.Z", tspath.GetLongestExtensionFromPath("/src/Component.y.Z", extensions, true))
    end)
end)

local pathIsRelativeTests = {
    -- relative
    { ".", true, false },
    { "..", true, false },
    { "./", true, false },
    { "../", true, false },
    { "./foo/bar", true, true },
    { "../foo/bar", true, true },
    { "../" .. string.rep("foo/", 100), true, true },
    -- non-relative
    { "", false, false },
    { "foo", false, false },
    { "foo/bar", false, false },
    { "/foo/bar", false, false },
    { "c:/foo/bar", false, false },
}

do
    local old = {}
    for i, t in ipairs(pathIsRelativeTests) do
        old[i] = t
    end
    for _, t in ipairs(old) do
        pathIsRelativeTests[#pathIsRelativeTests + 1] = { (string.gsub(t[1], "/", "\\")), t[2], t[3] }
    end
end

local function shortenName(name)
    if #name > 20 then
        return string.sub(name, 1, 20) .. "...etc"
    end
    return name
end

describe("TestPathIsRelative", function()
    for _, tt in ipairs(pathIsRelativeTests) do
        it(shortenName(tt[1]), function()
            assert.are.equal(tt[2], tspath.PathIsRelative(tt[1]))
        end)
    end
end)
