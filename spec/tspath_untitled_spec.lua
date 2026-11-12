-- Port of internal/tspath/untitled_test.go.
local tspath = require("tslua.tspath")

describe("TestUntitledPathHandling", function()
    it("TestUntitledPathHandling", function()
        -- Test that untitled paths are treated as rooted
        local untitledPath = "^/untitled/ts-nul-authority/Untitled-2"

        -- GetEncodedRootLength should return 2 for "^/"
        assert.are.equal(2, tspath.GetEncodedRootLength(untitledPath),
            "GetEncodedRootLength should return 2 for untitled paths")

        -- IsRootedDiskPath should return true
        assert.is_true(tspath.IsRootedDiskPath(untitledPath), "IsRootedDiskPath should return true for untitled paths")

        -- ToPath should not resolve untitled paths against current directory
        local currentDir = "/home/user/project"
        local path = tspath.ToPath(untitledPath, currentDir, true)
        -- The path should be the original untitled path
        assert.are.equal("^/untitled/ts-nul-authority/Untitled-2", path,
            "ToPath should not resolve untitled paths against current directory")

        -- Test GetNormalizedAbsolutePath doesn't resolve untitled paths
        local normalized = tspath.GetNormalizedAbsolutePath(untitledPath, currentDir)
        assert.are.equal("^/untitled/ts-nul-authority/Untitled-2", normalized,
            "GetNormalizedAbsolutePath should not resolve untitled paths")
    end)
end)

describe("TestUntitledPathEdgeCases", function()
    -- Test edge cases
    local testCases = {
        { "^/", 2, true }, -- Minimal untitled path
        { "^/untitled/ts-nul-authority/test", 2, true }, -- Normal untitled path
        { "^", 0, false }, -- Just ^ is not rooted
        { "^x", 0, false }, -- ^x is not untitled
        { "^^/", 0, false }, -- ^^/ is not untitled
        { "x^/", 0, false }, -- x^/ is not untitled (doesn't start with ^)
        { "^/untitled/ts-nul-authority/path/with/deeper/structure", 2, true }, -- Deeper path
    }

    for _, tc in ipairs(testCases) do
        it(tc[1], function()
            assert.are.equal(tc[2], tspath.GetEncodedRootLength(tc[1]), "GetEncodedRootLength for path " .. tc[1])
            assert.are.equal(tc[3], tspath.IsRootedDiskPath(tc[1]), "IsRootedDiskPath for path " .. tc[1])
        end)
    end
end)
