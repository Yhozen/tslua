-- Port of typescript-go internal/vfs/iovfs/iofs_test.go.
local vfs = require("tslua.vfs")
local iovfs = require("tslua.vfs.iovfs")

local fstest = vfs.iofs.fstest

describe("TestIOFS", function()
    local testfs = fstest.NewMapFS({
        ["foo.ts"] = fstest.NewMapFile({
            data = "hello, world",
        }),
        ["dir1/file1.ts"] = fstest.NewMapFile({
            data = "export const foo = 42;",
        }),
        ["dir1/file2.ts"] = fstest.NewMapFile({
            data = "export const foo = 42;",
        }),
        ["dir2/file1.ts"] = fstest.NewMapFile({
            data = "export const foo = 42;",
        }),
    })

    local fs = iovfs.From(testfs, true)

    it("ReadFile", function()
        local content, ok = fs:ReadFile("/foo.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/does/not/exist.ts")
        assert.is_false(ok)
        assert.are.equal("", content)
    end)

    it("ReadFileUnrooted", function()
        assert.has_error(function() fs:ReadFile("bar") end, 'vfs: path "bar" is not absolute')
    end)

    it("FileExists", function()
        assert.is_true(fs:FileExists("/foo.ts"))
        assert.is_false(fs:FileExists("/bar"))
    end)

    it("DirectoryExists", function()
        assert.is_true(fs:DirectoryExists("/"))
        assert.is_true(fs:DirectoryExists("/dir1"))
        assert.is_true(fs:DirectoryExists("/dir1/"))
        assert.is_true(fs:DirectoryExists("/dir1/./"))
        assert.is_false(fs:DirectoryExists("/bar"))
    end)

    it("GetAccessibleEntries", function()
        local entries = fs:GetAccessibleEntries("/")
        assert.are.same({ "dir1", "dir2" }, entries.directories)
        assert.are.same({ "foo.ts" }, entries.files)
    end)

    it("WalkDir", function()
        local files = {}
        local err = fs:WalkDir("/", function(path, d, err)
            if err ~= nil then
                return err
            end
            if not d:IsDir() then
                files[#files + 1] = path
            end
            return nil
        end)
        assert.is_nil(err)

        table.sort(files)

        assert.are.same({ "/dir1/file1.ts", "/dir1/file2.ts", "/dir2/file1.ts", "/foo.ts" }, files)
    end)

    it("WalkDirSkip", function()
        local files = {}
        local err = fs:WalkDir("/", function(path, d, err)
            if err ~= nil then
                return err
            end
            if not d:IsDir() then
                files[#files + 1] = path
            end

            if path == "/" then
                return nil
            end

            return vfs.SkipDir
        end)
        assert.is_nil(err)

        table.sort(files)

        assert.are.same({ "/foo.ts" }, files)
    end)

    it("Realpath", function()
        local realpath = fs:Realpath("/foo.ts")
        assert.are.equal("/foo.ts", realpath)
    end)

    it("UseCaseSensitiveFileNames", function()
        assert.is_true(fs:UseCaseSensitiveFileNames())
    end)
end)
