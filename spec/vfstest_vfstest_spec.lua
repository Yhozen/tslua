-- Port of typescript-go internal/vfs/vfstest/vfstest_test.go.
local vfs = require("tslua.vfs")
local vfstest = require("tslua.vfs.vfstest")

local iofs = vfs.iofs
local fstest = iofs.fstest

local function mapFile(fields)
    return fstest.NewMapFile(fields)
end

local function assertErrorContains(err, substr)
    assert.is_true(err ~= nil, "expected an error containing " .. substr)
    local msg = err:Error()
    assert.is_true(string.find(msg, substr, 1, true) ~= nil, "expected error " .. msg .. " to contain " .. substr)
end

local function dirEntriesToNames(entries)
    local names = {}
    for i, entry in ipairs(entries) do
        names[i] = entry:Name()
    end
    return names
end

-- fstest.TestFS (the Go standard library's fs.FS conformance checker) has no Lua port; the
-- assert.NilError(t, fstest.TestFS(...)) lines are omitted below.

describe("TestInsensitive", function()
    it("TestInsensitive", function()
        local contents = "bar"

        local vfs_ = vfstest.convertMapFS({
            ["foo/bar/baz"] = mapFile({
                data = contents,
                sys = 1234,
            }),
            ["foo/bar2/baz2"] = mapFile({
                data = contents,
                sys = 1234,
            }),
            ["foo/bar3/baz3"] = mapFile({
                data = contents,
                sys = 1234,
            }),
        }, false --[[useCaseSensitiveFileNames]], nil)

        local sensitive, err = iofs.ReadFile(vfs_, "foo/bar/baz")
        assert.is_nil(err)
        assert.are.same(contents, sensitive)
        local sensitiveInfo
        sensitiveInfo, err = iofs.Stat(vfs_, "foo/bar/baz")
        assert.is_nil(err)
        assert.are.equal(1234, sensitiveInfo:Sys())
        local sensitiveRealPath
        sensitiveRealPath, err = vfs_:Realpath("foo/bar/baz")
        assert.is_nil(err)
        assert.are.equal("foo/bar/baz", sensitiveRealPath)
        local entries
        entries, err = iofs.ReadDir(vfs_, "foo")
        assert.is_nil(err)
        assert.are.same({ "bar", "bar2", "bar3" }, dirEntriesToNames(entries))

        local _
        _, err = vfs_:Realpath("does/not/exist")
        assertErrorContains(err, "file does not exist")
        _, err = iofs.Stat(vfs_, "does/not/exist")
        assertErrorContains(err, "file does not exist")

        local insensitive
        insensitive, err = iofs.ReadFile(vfs_, "Foo/Bar/Baz")
        assert.is_nil(err)
        assert.are.same(contents, insensitive)
        local insensitiveInfo
        insensitiveInfo, err = iofs.Stat(vfs_, "Foo/Bar/Baz")
        assert.is_nil(err)
        assert.are.equal(1234, insensitiveInfo:Sys())
        local insensitiveRealPath
        insensitiveRealPath, err = vfs_:Realpath("Foo/Bar/Baz")
        assert.is_nil(err)
        assert.are.equal("foo/bar/baz", insensitiveRealPath)
        entries, err = iofs.ReadDir(vfs_, "Foo")
        assert.is_nil(err)
        assert.are.same({ "bar", "bar2", "bar3" }, dirEntriesToNames(entries))

        _, err = vfs_:Realpath("Does/Not/Exist")
        assertErrorContains(err, "file does not exist")
        _, err = iofs.Stat(vfs_, "Does/Not/Exist")
        assertErrorContains(err, "file does not exist")

        -- TODO: TestFS doesn't understand case-insensitive file systems.
        -- This same thing would happen with an os.Dir on Windows.
        -- assert.NilError(t, fstest.TestFS(vfs, "Foo/Bar/Baz"))
    end)
end)

describe("TestInsensitiveUpper", function()
    it("TestInsensitiveUpper", function()
        local contents = "bar"

        local vfs_ = vfstest.convertMapFS({
            ["Foo/Bar/Baz"] = mapFile({
                data = contents,
                sys = 1234,
            }),
            ["Foo/Bar2/Baz2"] = mapFile({
                data = contents,
                sys = 1234,
            }),
            ["Foo/Bar3/Baz3"] = mapFile({
                data = contents,
                sys = 1234,
            }),
        }, false --[[useCaseSensitiveFileNames]], nil)

        local sensitive, err = iofs.ReadFile(vfs_, "foo/bar/baz")
        assert.is_nil(err)
        assert.are.same(contents, sensitive)
        local sensitiveInfo
        sensitiveInfo, err = iofs.Stat(vfs_, "foo/bar/baz")
        assert.is_nil(err)
        assert.are.equal(1234, sensitiveInfo:Sys())
        local entries
        entries, err = iofs.ReadDir(vfs_, "foo")
        assert.is_nil(err)
        assert.are.same({ "Bar", "Bar2", "Bar3" }, dirEntriesToNames(entries))

        -- assert.NilError(t, fstest.TestFS(vfs, "foo/bar/baz"))

        local insensitive
        insensitive, err = iofs.ReadFile(vfs_, "Foo/Bar/Baz")
        assert.is_nil(err)
        assert.are.same(contents, insensitive)
        local insensitiveInfo
        insensitiveInfo, err = iofs.Stat(vfs_, "Foo/Bar/Baz")
        assert.is_nil(err)
        assert.are.equal(1234, insensitiveInfo:Sys())
        entries, err = iofs.ReadDir(vfs_, "Foo")
        assert.is_nil(err)
        assert.are.same({ "Bar", "Bar2", "Bar3" }, dirEntriesToNames(entries))
    end)
end)

describe("TestSensitive", function()
    it("TestSensitive", function()
        local contents = "bar"

        local vfs_ = vfstest.convertMapFS({
            ["foo/bar/baz"] = mapFile({
                data = contents,
                sys = 1234,
            }),
            ["foo/bar2/baz2"] = mapFile({
                data = contents,
                sys = 1234,
            }),
            ["foo/bar3/baz3"] = mapFile({
                data = contents,
                sys = 1234,
            }),
        }, true --[[useCaseSensitiveFileNames]], nil)

        local sensitive, err = iofs.ReadFile(vfs_, "foo/bar/baz")
        assert.is_nil(err)
        assert.are.same(contents, sensitive)
        local sensitiveInfo
        sensitiveInfo, err = iofs.Stat(vfs_, "foo/bar/baz")
        assert.is_nil(err)
        assert.are.equal(1234, sensitiveInfo:Sys())

        local _
        _, err = iofs.ReadFile(vfs_, "Foo/Bar/Baz")
        assertErrorContains(err, "file does not exist")
    end)
end)

describe("TestSensitiveDuplicatePath", function()
    it("TestSensitiveDuplicatePath", function()
        local testfs = {
            ["foo"] = mapFile({
                data = "bar",
            }),
            ["Foo"] = mapFile({
                data = "baz",
            }),
        }

        assert.has_error(function()
            vfstest.convertMapFS(testfs, false --[[useCaseSensitiveFileNames]], nil)
        end, 'duplicate path: "Foo" and "foo" have the same canonical path')
    end)
end)

describe("TestInsensitiveDuplicatePath", function()
    it("TestInsensitiveDuplicatePath", function()
        local testfs = {
            ["foo"] = mapFile({
                data = "bar",
            }),
            ["Foo"] = mapFile({
                data = "baz",
            }),
        }

        vfstest.convertMapFS(testfs, true --[[useCaseSensitiveFileNames]], nil)
    end)
end)

describe("TestWritableFS", function()
    it("TestWritableFS", function()
        local fs = vfstest.FromMap(nil, false)

        local err = fs:WriteFile("/foo/bar/baz", "hello, world")
        assert.is_nil(err)

        local content, ok = fs:ReadFile("/foo/bar/baz")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        err = fs:WriteFile("/foo/bar/baz", "goodbye, world")
        assert.is_nil(err)

        content, ok = fs:ReadFile("/foo/bar/baz")
        assert.is_true(ok)
        assert.are.equal("goodbye, world", content)

        err = fs:WriteFile("/foo/bar/baz/oops", "goodbye, world")
        assertErrorContains(err, 'mkdir "foo/bar/baz": path exists but is not a directory')
    end)
end)

describe("TestWritableFSDelete", function()
    it("TestWritableFSDelete", function()
        local fs = vfstest.FromMap(nil, false)

        fs:WriteFile("/foo/bar/file.ts", "remove")
        assert.is_true(fs:FileExists("/foo/bar/file.ts"))
        local err = fs:Remove("/foo/bar/file.ts")
        assert.is_nil(err)
        assert.is_true(not fs:FileExists("/foo/bar/file.ts"))

        fs:WriteFile("/foo/bar/test/remove2.ts", "remove2")
        assert.is_true(fs:DirectoryExists("/foo/bar/test"))
        err = fs:Remove("/foo/bar/test")
        assert.is_nil(err)
        assert.is_true(not fs:FileExists("/foo/bar/test/remove2.ts"))
        assert.is_true(not fs:DirectoryExists("/foo/bar/test"))

        -- no errors when removing file/dir that does not exist
        err = fs:Remove("/foo/bar/test")
        assert.is_nil(err)
        err = fs:Remove("/foo/bar/file.ts")
        assert.is_nil(err)

        fs:WriteFile("/foo/barbar", "remove2")
        fs:Remove("/foo/bar")
        assert.is_true(fs:FileExists("/foo/barbar"))
    end)
end)

describe("TestStress", function()
    -- Go runs the shuffled ops on runtime.GOMAXPROCS(0) goroutines to shake out data races; the
    -- port is single-threaded, so one worker runs them sequentially (the test still checks that
    -- interleaving the ops never fails).
    it("TestStress", function()
        local fs = vfstest.FromMap(nil, false)

        local ops = {
            function() fs:WriteFile("/foo/bar/baz.txt", "hello, world") end,
            function() fs:ReadFile("/foo/bar/baz.txt") end,
            function() fs:DirectoryExists("/foo/bar") end,
            function() fs:FileExists("/foo/bar") end,
            function() fs:FileExists("/foo/bar/baz.txt") end,
            function() fs:GetAccessibleEntries("/foo/bar") end,
            function() fs:Realpath("/foo/bar/baz.txt") end,
            function()
                fs:WalkDir("/", function(_, d, err)
                    if err ~= nil then
                        return err
                    end
                    _, err = d:Info()
                    return err
                end)
            end,
        }

        local randomOps = {}
        for i, op in ipairs(ops) do
            randomOps[i] = op
        end
        for i = #randomOps, 2, -1 do
            local j = math.random(i)
            randomOps[i], randomOps[j] = randomOps[j], randomOps[i]
        end

        for i = 0, 10000 - 1 do
            randomOps[i % #randomOps + 1]()
        end
    end)
end)

describe("TestParentDirFile", function()
    it("TestParentDirFile", function()
        local testfs = {
            ["foo"] = mapFile({
                data = "bar",
            }),
            ["foo/oops"] = mapFile({
                data = "baz",
            }),
        }

        assert.has_error(function()
            vfstest.convertMapFS(testfs, false --[[useCaseSensitiveFileNames]], nil)
        end, 'failed to create intermediate directories for "foo/oops": mkdir "foo": path exists but is not a directory')
    end)
end)

describe("TestFromMap", function()
    -- Go []byte file contents are Lua strings too.
    it("POSIX", function()
        local fs = vfstest.FromMap({
            ["/string"] = "hello, world",
            ["/bytes"] = "hello, world",
            ["/mapfile"] = mapFile({
                data = "hello, world",
            }),
        }, false)

        local content, ok = fs:ReadFile("/string")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/bytes")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/mapfile")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)
    end)

    it("Windows", function()
        local fs = vfstest.FromMap({
            ["c:/string"] = "hello, world",
            ["d:/bytes"] = "hello, world",
            ["e:/mapfile"] = mapFile({
                data = "hello, world",
            }),
        }, false)

        local content, ok = fs:ReadFile("c:/string")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("d:/bytes")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("e:/mapfile")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)
    end)

    it("Mixed", function()
        assert.has_error(function()
            vfstest.FromMap({
                ["/string"] = "hello, world",
                ["c:/bytes"] = "hello, world",
            }, false)
        end, "mixed posix and windows paths")
    end)

    it("NonRooted", function()
        assert.has_error(function()
            vfstest.FromMap({
                ["string"] = "hello, world",
            }, false)
        end, 'non-rooted path "string"')
    end)

    it("NonNormalized", function()
        assert.has_error(function()
            vfstest.FromMap({
                ["/string/"] = "hello, world",
            }, false)
        end, 'non-normalized path "/string/"')
    end)

    it("NonNormalized2", function()
        assert.has_error(function()
            vfstest.FromMap({
                ["/string/../foo"] = "hello, world",
            }, false)
        end, 'non-normalized path "/string/../foo"')
    end)

    it("InvalidFile", function()
        assert.has_error(function()
            vfstest.FromMap({
                ["/string"] = 1234,
            }, false)
        end, "invalid file type int")
    end)
end)

describe("TestVFSTestMapFS", function()
    local fs = vfstest.FromMap({
        ["/foo.ts"] = "hello, world",
        ["/dir1/file1.ts"] = "export const foo = 42;",
        ["/dir1/file2.ts"] = "export const foo = 42;",
        ["/dir2/file1.ts"] = "export const foo = 42;",
    }, false --[[useCaseSensitiveFileNames]])

    it("ReadFile", function()
        local content, ok = fs:ReadFile("/foo.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/does/not/exist.ts")
        assert.is_true(not ok)
        assert.are.equal("", content)
    end)

    it("Realpath", function()
        local realpath = fs:Realpath("/foo.ts")
        assert.are.equal("/foo.ts", realpath)

        realpath = fs:Realpath("/Foo.ts")
        assert.are.equal("/foo.ts", realpath)

        realpath = fs:Realpath("/does/not/exist.ts")
        assert.are.equal("/does/not/exist.ts", realpath)
    end)

    it("UseCaseSensitiveFileNames", function()
        assert.is_true(not fs:UseCaseSensitiveFileNames())
    end)
end)

describe("TestVFSTestMapFSWindows", function()
    local fs = vfstest.FromMap({
        ["c:/foo.ts"] = "hello, world",
        ["c:/dir1/file1.ts"] = "export const foo = 42;",
        ["c:/dir1/file2.ts"] = "export const foo = 42;",
        ["c:/dir2/file1.ts"] = "export const foo = 42;",
    }, false)

    it("ReadFile", function()
        local content, ok = fs:ReadFile("c:/foo.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("c:/does/not/exist.ts")
        assert.is_true(not ok)
        assert.are.equal("", content)
    end)

    it("Realpath", function()
        local realpath = fs:Realpath("c:/foo.ts")
        assert.are.equal("c:/foo.ts", realpath)

        realpath = fs:Realpath("c:/Foo.ts")
        assert.are.equal("c:/foo.ts", realpath)

        realpath = fs:Realpath("c:/does/not/exist.ts")
        assert.are.equal("c:/does/not/exist.ts", realpath)
    end)
end)

describe("TestBOM", function()
    local expected = "hello, world"

    -- utf16.AppendRune
    local function appendRune(codePoints, r)
        if r >= 0x10000 then
            r = r - 0x10000
            codePoints[#codePoints + 1] = 0xD800 + (r >> 10)
            codePoints[#codePoints + 1] = 0xDC00 + (r & 0x3FF)
        else
            codePoints[#codePoints + 1] = r
        end
        return codePoints
    end

    -- binary.Append(buf, order, uint16)
    local function appendUint16(buf, bigEndian, v)
        if bigEndian then
            return buf .. string.char(v >> 8, v & 0xFF)
        end
        return buf .. string.char(v & 0xFF, v >> 8)
    end

    local tests = {
        { name = "BigEndian", bigEndian = true, bom = "\xFE\xFF" },
        { name = "LittleEndian", bigEndian = false, bom = "\xFF\xFE" },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            local codePoints = {}

            for _, r in utf8.codes(expected) do
                codePoints = appendRune(codePoints, r)
            end

            local buf = tt.bom

            for _, r in ipairs(codePoints) do
                buf = appendUint16(buf, tt.bigEndian, r)
            end

            local fs = vfstest.FromMap({
                ["/foo.ts"] = buf,
            }, true)

            local content, ok = fs:ReadFile("/foo.ts")
            assert.is_true(ok)
            assert.are.equal(expected, content)
        end)
    end

    it("UTF8", function()
        local fs = vfstest.FromMap({
            ["/foo.ts"] = "\xEF\xBB\xBF" .. expected,
        }, true)

        local content, ok = fs:ReadFile("/foo.ts")
        assert.is_true(ok)
        assert.are.equal(expected, content)
    end)
end)

describe("TestSymlink", function()
    local fs = vfstest.FromMap({
        ["/foo.ts"] = "hello, world",
        ["/symlink.ts"] = vfstest.Symlink("/foo.ts"),
        ["/some/dir/file.ts"] = "hello, world",
        ["/some/dirlink"] = vfstest.Symlink("/some/dir"),
        ["/a"] = vfstest.Symlink("/b"),
        ["/b"] = vfstest.Symlink("/c"),
        ["/c"] = vfstest.Symlink("/d"),
        ["/d/existing.ts"] = "this is existing.ts",
    }, false)

    it("ReadFile", function()
        local content, ok = fs:ReadFile("/symlink.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/some/dirlink/file.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/a/existing.ts")
        assert.is_true(ok)
        assert.are.equal("this is existing.ts", content)
    end)

    it("Realpath", function()
        local realpath = fs:Realpath("/symlink.ts")
        assert.are.equal("/foo.ts", realpath)

        realpath = fs:Realpath("/some/dirlink")
        assert.are.equal("/some/dir", realpath)

        realpath = fs:Realpath("/some/dirlink/file.ts")
        assert.are.equal("/some/dir/file.ts", realpath)
    end)

    it("FileExists", function()
        assert.is_true(fs:FileExists("/symlink.ts"))
        assert.is_true(fs:FileExists("/some/dirlink/file.ts"))
        assert.is_true(fs:FileExists("/a/existing.ts"))
    end)

    it("DirectoryExists", function()
        assert.is_true(fs:DirectoryExists("/some/dirlink"))
        assert.is_true(fs:DirectoryExists("/d"))
        assert.is_true(fs:DirectoryExists("/c"))
        assert.is_true(fs:DirectoryExists("/b"))
        assert.is_true(fs:DirectoryExists("/a"))
    end)
end)

describe("TestWritableFSSymlink", function()
    it("TestWritableFSSymlink", function()
        local fs = vfstest.FromMap({
            ["/some/dir/other.ts"] = "NOTHING",
            ["/other.ts"] = vfstest.Symlink("/some/dir/other.ts"),
            ["/some/dirlink"] = vfstest.Symlink("/some/dir"),
            ["/brokenlink"] = vfstest.Symlink("/does/not/exist"),
            ["/a"] = vfstest.Symlink("/b"),
            ["/b"] = vfstest.Symlink("/c"),
            ["/c"] = vfstest.Symlink("/d"),
            ["/d/existing.ts"] = "hello, world",
        }, false)

        local err = fs:WriteFile("/some/dirlink/file.ts", "hello, world")
        assert.is_nil(err)

        local content, ok = fs:ReadFile("/some/dirlink/file.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/some/dir/file.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        err = fs:WriteFile("/some/dirlink/file.ts", "goodbye, world")
        assert.is_nil(err)

        content, ok = fs:ReadFile("/some/dirlink/file.ts")
        assert.is_true(ok)
        assert.are.equal("goodbye, world", content)

        err = fs:WriteFile("/other.ts", "hello, world")
        assert.is_nil(err)

        content, ok = fs:ReadFile("/other.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        content, ok = fs:ReadFile("/some/dir/other.ts")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)

        err = fs:WriteFile("/some/dirlink", "hello, world")
        assert.are.equal('write "some/dirlink": path exists but is not a regular file', err:Error())

        -- Can't write inside a broken dir symlink
        err = fs:WriteFile("/brokenlink/file.ts", "hello, world")
        assert.are.equal('broken symlink "brokenlink" -> "does/not/exist"', err:Error())

        err = fs:WriteFile("/brokenlink/also/wrong/file.ts", "hello, world")
        assert.are.equal('broken symlink "brokenlink" -> "does/not/exist"', err:Error())

        -- But we can write to a broken file symlink
        err = fs:WriteFile("/brokenlink", "hello, world")
        assert.is_nil(err)
        content, ok = fs:ReadFile("/brokenlink")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)
        content, ok = fs:ReadFile("/does/not/exist")
        assert.is_true(ok)
        assert.are.equal("hello, world", content)
    end)
end)

describe("TestWritableFSSymlinkChain", function()
    it("TestWritableFSSymlinkChain", function()
        local fs = vfstest.FromMap({
            ["/a"] = vfstest.Symlink("/b"),
            ["/b"] = vfstest.Symlink("/c"),
            ["/c"] = vfstest.Symlink("/d"),
            ["/d/existing.ts"] = "hello, world",
        }, false)

        local err = fs:WriteFile("/a/foo/bar/new.ts", "this is new.ts")
        assert.is_nil(err)
        local content, ok = fs:ReadFile("/a/foo/bar/new.ts")
        assert.is_true(ok)
        assert.are.equal("this is new.ts", content)
        content, ok = fs:ReadFile("/b/foo/bar/new.ts")
        assert.is_true(ok)
        assert.are.equal("this is new.ts", content)
        content, ok = fs:ReadFile("/d/foo/bar/new.ts")
        assert.is_true(ok)
        assert.are.equal("this is new.ts", content)
    end)
end)

describe("TestWritableFSSymlinkChainNotDir", function()
    it("TestWritableFSSymlinkChainNotDir", function()
        local fs = vfstest.FromMap({
            ["/a"] = vfstest.Symlink("/b"),
            ["/b"] = vfstest.Symlink("/c"),
            ["/c"] = vfstest.Symlink("/d"),
            ["/d"] = "hello, world",
        }, false)

        local err = fs:WriteFile("/a/foo/bar/new.ts", "this is new.ts")
        assert.are.equal('mkdir "d": path exists but is not a directory', err:Error())
    end)
end)

describe("TestWritableFSSymlinkDelete", function()
    it("TestWritableFSSymlinkDelete", function()
        local fs = vfstest.FromMap({
            ["/some/dir/other.ts"] = "NOTHING",
            ["/other.ts"] = vfstest.Symlink("/some/dir/other.ts"),
            ["/some/dirlink"] = vfstest.Symlink("/some/dir"),
            ["/brokenlink"] = vfstest.Symlink("/does/not/exist"),
            ["/a"] = vfstest.Symlink("/b"),
            ["/b"] = vfstest.Symlink("/c"),
            ["/c"] = vfstest.Symlink("/d"),
            ["/d/existing.ts"] = "hello, world",
        }, false)

        local err = fs:Remove("/a")
        assert.is_nil(err)
        assert.is_true(not fs:DirectoryExists("/a"))
        assert.is_true(fs:DirectoryExists("/b"))
        assert.is_true(fs:DirectoryExists("/c"))
        assert.is_true(fs:FileExists("/d/existing.ts"))

        -- symlinks should still exist even if underlying file/dir is deleted
        err = fs:Remove("/d")
        assert.is_nil(err)
        assert.is_true(not fs:DirectoryExists("/b"))
        assert.is_true(not fs:DirectoryExists("/c"))
        assert.is_true(not fs:DirectoryExists("/d"))
        assert.is_true(not fs:FileExists("/d/again.ts"))
        err = fs:WriteFile("/d/again.ts", "d exists again")
        assert.is_nil(err)
        assert.is_true(fs:DirectoryExists("/b"))
        assert.is_true(fs:DirectoryExists("/c"))
        local content = fs:ReadFile("/b/again.ts")
        assert.are.equal("d exists again", content)

        assert.is_true(not fs:FileExists("/brokenlink"))
        assert.is_true(not fs:DirectoryExists("/brokenlink"))
        err = fs:Remove("/does/not/exist") -- should do nothing
        assert.is_nil(err)
        assert.is_true(not fs:FileExists("/brokenlink"))
        assert.is_true(not fs:DirectoryExists("/brokenlink"))
        err = fs:WriteFile("/does/not/exist", "hello, world")
        assert.is_nil(err)
        assert.is_true(fs:FileExists("/brokenlink"))
    end)
end)
