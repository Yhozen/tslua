-- Port of typescript-go internal/vfs/cachedvfs/cachedvfs_test.go.
local cachedvfs = require("tslua.vfs.cachedvfs")
local vfsmock = require("tslua.vfs.vfsmock")
local vfstest = require("tslua.vfs.vfstest")

local function createMockFS()
    return vfsmock.Wrap(vfstest.FromMap({
        ["/some/path/file.txt"] = "hello world",
    }, true))
end

describe("TestDirectoryExists", function()
    it("TestDirectoryExists", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:DirectoryExists("/some/path")
        assert.are.equal(1, #underlying:DirectoryExistsCalls())

        cached:DirectoryExists("/some/path")
        assert.are.equal(1, #underlying:DirectoryExistsCalls())

        cached:ClearCache()
        cached:DirectoryExists("/some/path")
        assert.are.equal(2, #underlying:DirectoryExistsCalls())

        cached:DirectoryExists("/other/path")
        assert.are.equal(3, #underlying:DirectoryExistsCalls())

        cached:DisableAndClearCache()
        cached:DirectoryExists("/some/path")
        assert.are.equal(4, #underlying:DirectoryExistsCalls())

        cached:DirectoryExists("/some/path")
        assert.are.equal(5, #underlying:DirectoryExistsCalls())

        cached:Enable()
        cached:DirectoryExists("/some/path")
        assert.are.equal(6, #underlying:DirectoryExistsCalls())

        cached:DirectoryExists("/some/path")
        assert.are.equal(6, #underlying:DirectoryExistsCalls())
    end)
end)

describe("TestFileExists", function()
    it("TestFileExists", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:FileExists("/some/path/file.txt")
        assert.are.equal(1, #underlying:FileExistsCalls())

        cached:FileExists("/some/path/file.txt")
        assert.are.equal(1, #underlying:FileExistsCalls())

        cached:ClearCache()
        cached:FileExists("/some/path/file.txt")
        assert.are.equal(2, #underlying:FileExistsCalls())

        cached:FileExists("/other/path/file.txt")
        assert.are.equal(3, #underlying:FileExistsCalls())

        cached:DisableAndClearCache()
        cached:FileExists("/some/path/file.txt")
        assert.are.equal(4, #underlying:FileExistsCalls())

        cached:FileExists("/some/path/file.txt")
        assert.are.equal(5, #underlying:FileExistsCalls())

        cached:Enable()
        cached:FileExists("/some/path/file.txt")
        assert.are.equal(6, #underlying:FileExistsCalls())

        cached:FileExists("/some/path/file.txt")
        assert.are.equal(6, #underlying:FileExistsCalls())
    end)
end)

describe("TestGetAccessibleEntries", function()
    it("TestGetAccessibleEntries", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(1, #underlying:GetAccessibleEntriesCalls())

        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(1, #underlying:GetAccessibleEntriesCalls())

        cached:ClearCache()
        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(2, #underlying:GetAccessibleEntriesCalls())

        cached:GetAccessibleEntries("/other/path")
        assert.are.equal(3, #underlying:GetAccessibleEntriesCalls())

        cached:DisableAndClearCache()
        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(4, #underlying:GetAccessibleEntriesCalls())

        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(5, #underlying:GetAccessibleEntriesCalls())

        cached:Enable()
        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(6, #underlying:GetAccessibleEntriesCalls())

        cached:GetAccessibleEntries("/some/path")
        assert.are.equal(6, #underlying:GetAccessibleEntriesCalls())
    end)
end)

describe("TestRealpath", function()
    it("TestRealpath", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:Realpath("/some/path")
        assert.are.equal(1, #underlying:RealpathCalls())

        cached:Realpath("/some/path")
        assert.are.equal(1, #underlying:RealpathCalls())

        cached:ClearCache()
        cached:Realpath("/some/path")
        assert.are.equal(2, #underlying:RealpathCalls())

        cached:Realpath("/other/path")
        assert.are.equal(3, #underlying:RealpathCalls())

        cached:DisableAndClearCache()
        cached:Realpath("/some/path")
        assert.are.equal(4, #underlying:RealpathCalls())

        cached:Realpath("/some/path")
        assert.are.equal(5, #underlying:RealpathCalls())

        cached:Enable()
        cached:Realpath("/some/path")
        assert.are.equal(6, #underlying:RealpathCalls())

        cached:Realpath("/some/path")
        assert.are.equal(6, #underlying:RealpathCalls())
    end)
end)

describe("TestStat", function()
    it("TestStat", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:Stat("/some/path")
        assert.are.equal(1, #underlying:StatCalls())

        cached:Stat("/some/path")
        assert.are.equal(1, #underlying:StatCalls())

        cached:ClearCache()
        cached:Stat("/some/path")
        assert.are.equal(2, #underlying:StatCalls())

        cached:Stat("/other/path")
        assert.are.equal(3, #underlying:StatCalls())

        cached:DisableAndClearCache()
        cached:Stat("/some/path")
        assert.are.equal(4, #underlying:StatCalls())

        cached:Stat("/some/path")
        assert.are.equal(5, #underlying:StatCalls())

        cached:Enable()
        cached:Stat("/some/path")
        assert.are.equal(6, #underlying:StatCalls())

        cached:Stat("/some/path")
        assert.are.equal(6, #underlying:StatCalls())
    end)
end)

describe("TestReadFile", function()
    it("TestReadFile", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(1, #underlying:ReadFileCalls())

        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(2, #underlying:ReadFileCalls())

        cached:ClearCache()
        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(3, #underlying:ReadFileCalls())

        cached:DisableAndClearCache()
        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(4, #underlying:ReadFileCalls())

        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(5, #underlying:ReadFileCalls())

        cached:Enable()
        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(6, #underlying:ReadFileCalls())

        cached:ReadFile("/some/path/file.txt")
        assert.are.equal(7, #underlying:ReadFileCalls())
    end)
end)

describe("TestUseCaseSensitiveFileNames", function()
    it("TestUseCaseSensitiveFileNames", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:UseCaseSensitiveFileNames()
        assert.are.equal(1, #underlying:UseCaseSensitiveFileNamesCalls())

        cached:UseCaseSensitiveFileNames()
        assert.are.equal(2, #underlying:UseCaseSensitiveFileNamesCalls())

        cached:ClearCache()
        cached:UseCaseSensitiveFileNames()
        assert.are.equal(3, #underlying:UseCaseSensitiveFileNamesCalls())

        cached:DisableAndClearCache()
        cached:UseCaseSensitiveFileNames()
        assert.are.equal(4, #underlying:UseCaseSensitiveFileNamesCalls())

        cached:UseCaseSensitiveFileNames()
        assert.are.equal(5, #underlying:UseCaseSensitiveFileNamesCalls())

        cached:Enable()
        cached:UseCaseSensitiveFileNames()
        assert.are.equal(6, #underlying:UseCaseSensitiveFileNamesCalls())

        cached:UseCaseSensitiveFileNames()
        assert.are.equal(7, #underlying:UseCaseSensitiveFileNamesCalls())
    end)
end)

describe("TestWalkDir", function()
    it("TestWalkDir", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        local walkFn = function(path, info, err) -- luacheck: no unused args
            return nil
        end

        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(1, #underlying:WalkDirCalls())

        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(2, #underlying:WalkDirCalls())

        cached:ClearCache()
        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(3, #underlying:WalkDirCalls())

        cached:DisableAndClearCache()
        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(4, #underlying:WalkDirCalls())

        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(5, #underlying:WalkDirCalls())

        cached:Enable()
        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(6, #underlying:WalkDirCalls())

        cached:WalkDir("/some/path", walkFn)
        assert.are.equal(7, #underlying:WalkDirCalls())
    end)
end)

describe("TestRemove", function()
    it("TestRemove", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:Remove("/some/path/file.txt")
        assert.are.equal(1, #underlying:RemoveCalls())

        cached:Remove("/some/path/file.txt")
        assert.are.equal(2, #underlying:RemoveCalls())

        cached:ClearCache()
        cached:Remove("/some/path/file.txt")
        assert.are.equal(3, #underlying:RemoveCalls())

        cached:DisableAndClearCache()
        cached:Remove("/some/path/file.txt")
        assert.are.equal(4, #underlying:RemoveCalls())

        cached:Remove("/some/path/file.txt")
        assert.are.equal(5, #underlying:RemoveCalls())

        cached:Enable()
        cached:Remove("/some/path/file.txt")
        assert.are.equal(6, #underlying:RemoveCalls())

        cached:Remove("/some/path/file.txt")
        assert.are.equal(7, #underlying:RemoveCalls())
    end)
end)

describe("TestWriteFile", function()
    it("TestWriteFile", function()
        local underlying = createMockFS()
        local cached = cachedvfs.From(underlying)

        cached:WriteFile("/some/path/file.txt", "new content")
        assert.are.equal(1, #underlying:WriteFileCalls())

        cached:WriteFile("/some/path/file.txt", "another content")
        assert.are.equal(2, #underlying:WriteFileCalls())

        cached:ClearCache()
        cached:WriteFile("/some/path/file.txt", "third content")
        assert.are.equal(3, #underlying:WriteFileCalls())

        local call = underlying:WriteFileCalls()[2 + 1]
        assert.are.equal("/some/path/file.txt", call.path)
        assert.are.equal("third content", call.data)

        cached:DisableAndClearCache()
        cached:WriteFile("/some/path/file.txt", "fourth content")
        assert.are.equal(4, #underlying:WriteFileCalls())

        cached:WriteFile("/some/path/file.txt", "fifth content")
        assert.are.equal(5, #underlying:WriteFileCalls())

        cached:Enable()
        cached:WriteFile("/some/path/file.txt", "sixth content")
        assert.are.equal(6, #underlying:WriteFileCalls())

        cached:WriteFile("/some/path/file.txt", "seventh content")
        assert.are.equal(7, #underlying:WriteFileCalls())
    end)
end)
