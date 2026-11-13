-- Ports of selected cases from typescript-go internal/vfs/**/*_test.go.
local vfs = require("tslua.vfs")
local vfstest = require("tslua.vfs.vfstest")
local cachedvfs = require("tslua.vfs.cachedvfs")
local wrapvfs = require("tslua.vfs.wrapvfs")
local osvfs = require("tslua.vfs.osvfs")
local internal = require("tslua.vfs.internal")

local iofs = vfs.iofs
local fstest = iofs.fstest

local function names(entries)
    local out = {}
    for i, e in ipairs(entries) do
        out[i] = e:Name()
    end
    return out
end

describe("vfstest", function()
    local function mapFile(data, sys)
        return fstest.NewMapFile({ data = data, sys = sys })
    end

    it("is case-insensitive (TestInsensitive)", function()
        local m = vfstest.convertMapFS({
            ["foo/bar/baz"] = mapFile("bar", 1234),
            ["foo/bar2/baz2"] = mapFile("bar", 1234),
            ["foo/bar3/baz3"] = mapFile("bar", 1234),
        }, false, nil)

        assert.are.equal("bar", (iofs.ReadFile(m, "foo/bar/baz")))
        local info = iofs.Stat(m, "foo/bar/baz")
        assert.are.equal(1234, info:Sys())
        assert.are.equal("foo/bar/baz", (m:Realpath("foo/bar/baz")))
        assert.are.same({ "bar", "bar2", "bar3" }, names((iofs.ReadDir(m, "foo"))))

        local _, err = m:Realpath("does/not/exist")
        assert.truthy(string.find(err:Error(), "file does not exist", 1, true))
        _, err = iofs.Stat(m, "does/not/exist")
        assert.truthy(string.find(err:Error(), "file does not exist", 1, true))

        assert.are.equal("bar", (iofs.ReadFile(m, "Foo/Bar/Baz")))
        assert.are.equal(1234, iofs.Stat(m, "Foo/Bar/Baz"):Sys())
        assert.are.equal("foo/bar/baz", (m:Realpath("Foo/Bar/Baz")))
        assert.are.same({ "bar", "bar2", "bar3" }, names((iofs.ReadDir(m, "Foo"))))
    end)

    it("keeps the original casing (TestInsensitiveUpper)", function()
        local m = vfstest.convertMapFS({
            ["Foo/Bar/Baz"] = mapFile("bar", 1234),
            ["Foo/Bar2/Baz2"] = mapFile("bar", 1234),
            ["Foo/Bar3/Baz3"] = mapFile("bar", 1234),
        }, false, nil)
        assert.are.equal("bar", (iofs.ReadFile(m, "foo/bar/baz")))
        assert.are.same({ "Bar", "Bar2", "Bar3" }, names((iofs.ReadDir(m, "foo"))))
    end)

    it("is case-sensitive (TestSensitive)", function()
        local m = vfstest.convertMapFS({
            ["foo/bar/baz"] = mapFile("bar", 1234),
        }, true, nil)
        assert.are.equal("bar", (iofs.ReadFile(m, "foo/bar/baz")))
        local _, err = iofs.ReadFile(m, "Foo/Bar/Baz")
        assert.truthy(string.find(err:Error(), "file does not exist", 1, true))
    end)

    it("rejects duplicate canonical paths", function()
        assert.has_error(function()
            vfstest.convertMapFS({
                ["Foo/Bar/Baz"] = mapFile("bar"),
                ["foo/bar/baz"] = mapFile("bar"),
            }, false, nil)
        end, 'duplicate path: "Foo/Bar/Baz" and "foo/bar/baz" have the same canonical path')
        assert.has_no.errors(function()
            vfstest.convertMapFS({
                ["Foo/Bar/Baz"] = mapFile("bar"),
                ["foo/bar/baz"] = mapFile("bar"),
            }, true, nil)
        end)
    end)

    it("writes files and creates directories (TestWritableFS)", function()
        local fs = vfstest.FromMap({}, false)
        assert.is_nil(fs:WriteFile("/foo/bar/baz", "hello, world"))
        assert.are.equal("hello, world", (fs:ReadFile("/foo/bar/baz")))
        assert.is_nil(fs:WriteFile("/foo/bar/baz", "goodbye, world"))
        assert.are.equal("goodbye, world", (fs:ReadFile("/foo/bar/baz")))
        assert.is_true(fs:DirectoryExists("/foo/bar"))
        assert.is_nil(fs:AppendFile("/foo/bar/baz", "!"))
        assert.are.equal("goodbye, world!", (fs:ReadFile("/foo/bar/baz")))
        assert.is_nil(fs:Remove("/foo"))
        assert.is_false(fs:FileExists("/foo/bar/baz"))
        assert.is_false(fs:DirectoryExists("/foo"))
    end)

    it("decodes byte order marks (TestBOM)", function()
        local expected = "hello, world"
        local function utf16(bigEndian)
            local out = {}
            for i = 1, #expected do
                local c = string.byte(expected, i)
                out[#out + 1] = bigEndian and ("\0" .. string.char(c)) or (string.char(c) .. "\0")
            end
            return table.concat(out)
        end
        local be = vfstest.FromMap({ ["/foo.ts"] = "\xFE\xFF" .. utf16(true) }, true)
        assert.are.equal(expected, (be:ReadFile("/foo.ts")))
        local le = vfstest.FromMap({ ["/foo.ts"] = "\xFF\xFE" .. utf16(false) }, true)
        assert.are.equal(expected, (le:ReadFile("/foo.ts")))
        local u8 = vfstest.FromMap({ ["/foo.ts"] = "\xEF\xBB\xBF" .. expected }, true)
        assert.are.equal(expected, (u8:ReadFile("/foo.ts")))
        assert.are.equal("\u{1F600}", internal.decodeUtf16("\x3D\xD8\x00\xDE", false))
    end)

    it("follows symlinks (TestSymlink)", function()
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

        assert.are.equal("hello, world", (fs:ReadFile("/symlink.ts")))
        assert.are.equal("hello, world", (fs:ReadFile("/some/dirlink/file.ts")))
        assert.are.equal("this is existing.ts", (fs:ReadFile("/a/existing.ts")))

        assert.are.equal("/foo.ts", fs:Realpath("/symlink.ts"))
        assert.are.equal("/some/dir", fs:Realpath("/some/dirlink"))
        assert.are.equal("/some/dir/file.ts", fs:Realpath("/some/dirlink/file.ts"))

        assert.is_true(fs:FileExists("/symlink.ts"))
        assert.is_true(fs:FileExists("/some/dirlink/file.ts"))
        assert.is_true(fs:FileExists("/a/existing.ts"))

        assert.is_true(fs:DirectoryExists("/some/dirlink"))
        assert.is_true(fs:DirectoryExists("/d"))
        assert.is_true(fs:DirectoryExists("/a"))

        local entries = fs:GetAccessibleEntries("/some")
        assert.are.same({ "dir", "dirlink" }, entries.directories)
        assert.is_true(entries.symlinks["dirlink"])
    end)

    it("writes through symlinks (TestWritableFSSymlink)", function()
        local fs = vfstest.FromMap({
            ["/some/dir/other.ts"] = "NOTHING",
            ["/other.ts"] = vfstest.Symlink("/some/dir/other.ts"),
            ["/some/dirlink"] = vfstest.Symlink("/some/dir"),
            ["/brokenlink"] = vfstest.Symlink("/does/not/exist"),
            ["/d/existing.ts"] = "hello, world",
        }, false)

        assert.is_nil(fs:WriteFile("/some/dirlink/file.ts", "hello, world"))
        assert.are.equal("hello, world", (fs:ReadFile("/some/dirlink/file.ts")))
        assert.are.equal("hello, world", (fs:ReadFile("/some/dir/file.ts")))

        assert.is_nil(fs:WriteFile("/other.ts", "hello, world"))
        assert.are.equal("hello, world", (fs:ReadFile("/some/dir/other.ts")))

        assert.are.equal('write "some/dirlink": path exists but is not a regular file', fs:WriteFile("/some/dirlink", "hello, world"):Error())
        assert.are.equal('broken symlink "brokenlink" -> "does/not/exist"', fs:WriteFile("/brokenlink/file.ts", "hello, world"):Error())
        assert.are.equal('broken symlink "brokenlink" -> "does/not/exist"', fs:WriteFile("/brokenlink/also/wrong/file.ts", "hello, world"):Error())

        assert.is_nil(fs:WriteFile("/brokenlink", "hello, world"))
        assert.are.equal("hello, world", (fs:ReadFile("/brokenlink")))
        assert.are.equal("hello, world", (fs:ReadFile("/does/not/exist")))
    end)

    it("writes through symlink chains (TestWritableFSSymlinkChain*)", function()
        local fs = vfstest.FromMap({
            ["/a"] = vfstest.Symlink("/b"),
            ["/b"] = vfstest.Symlink("/c"),
            ["/c"] = vfstest.Symlink("/d"),
            ["/d/existing.ts"] = "hello, world",
        }, false)
        assert.is_nil(fs:WriteFile("/a/foo/bar/new.ts", "this is new.ts"))
        assert.are.equal("this is new.ts", (fs:ReadFile("/b/foo/bar/new.ts")))
        assert.are.equal("this is new.ts", (fs:ReadFile("/d/foo/bar/new.ts")))

        local fs2 = vfstest.FromMap({
            ["/a"] = vfstest.Symlink("/b"),
            ["/b"] = vfstest.Symlink("/c"),
            ["/c"] = vfstest.Symlink("/d"),
            ["/d"] = "hello, world",
        }, false)
        assert.are.equal('mkdir "d": path exists but is not a directory', fs2:WriteFile("/a/foo/bar/new.ts", "this is new.ts"):Error())
    end)

    it("walks directories in order", function()
        local fs = vfstest.FromMap({
            ["/b/x.ts"] = "",
            ["/a/z.ts"] = "",
            ["/a/y/w.ts"] = "",
        }, true)
        local walked = {}
        assert.is_nil(fs:WalkDir("/", function(path, d, err)
            walked[#walked + 1] = path
            return nil
        end))
        assert.are.same({ "/", "/a", "/a/y", "/a/y/w.ts", "/a/z.ts", "/b", "/b/x.ts" }, walked)

        walked = {}
        fs:WalkDir("/", function(path, d)
            walked[#walked + 1] = path
            if path == "/a" then
                return vfs.SkipDir
            end
            return nil
        end)
        assert.are.same({ "/", "/a", "/b", "/b/x.ts" }, walked)
    end)

    it("rejects non-normalized and mixed paths", function()
        assert.has_error(function() vfstest.FromMap({ ["foo"] = "" }, true) end, 'non-rooted path "foo"')
        assert.has_error(function() vfstest.FromMap({ ["/foo/"] = "" }, true) end, 'non-normalized path "/foo/"')
        assert.has_error(function() vfstest.FromMap({ ["/foo"] = "", ["c:/foo"] = "" }, true) end, "mixed posix and windows paths")
    end)

    it("supports Windows-style roots", function()
        local fs = vfstest.FromMap({ ["c:/foo/bar.ts"] = "x" }, false)
        assert.are.equal("x", (fs:ReadFile("C:/Foo/bar.ts")))
        assert.is_true(fs:DirectoryExists("c:/foo"))
    end)
end)

describe("cachedvfs", function()
    local function counting(fs)
        local calls = {}
        local wrapped = wrapvfs.Wrap(fs, {
            FileExists = function(p)
                calls.FileExists = (calls.FileExists or 0) + 1
                return fs:FileExists(p)
            end,
            DirectoryExists = function(p)
                calls.DirectoryExists = (calls.DirectoryExists or 0) + 1
                return fs:DirectoryExists(p)
            end,
            Stat = function(p)
                calls.Stat = (calls.Stat or 0) + 1
                return fs:Stat(p)
            end,
            ReadFile = function(p)
                calls.ReadFile = (calls.ReadFile or 0) + 1
                return fs:ReadFile(p)
            end,
        })
        return wrapped, calls
    end

    it("caches lookups until cleared or disabled", function()
        local inner, calls = counting(vfstest.FromMap({ ["/a.ts"] = "a" }, true))
        local fs = cachedvfs.From(inner)
        assert.is_true(fs:FileExists("/a.ts"))
        assert.is_true(fs:FileExists("/a.ts"))
        assert.are.equal(1, calls.FileExists)
        assert.is_false(fs:DirectoryExists("/a.ts"))
        assert.is_false(fs:DirectoryExists("/a.ts"))
        assert.are.equal(1, calls.DirectoryExists)
        assert.is_nil(fs:Stat("/missing"))
        assert.is_nil(fs:Stat("/missing"))
        assert.are.equal(1, calls.Stat)
        fs:ReadFile("/a.ts")
        fs:ReadFile("/a.ts")
        assert.are.equal(2, calls.ReadFile)

        fs:ClearCache()
        fs:FileExists("/a.ts")
        assert.are.equal(2, calls.FileExists)

        fs:DisableAndClearCache()
        fs:FileExists("/a.ts")
        fs:FileExists("/a.ts")
        assert.are.equal(4, calls.FileExists)
        fs:Enable()
        fs:FileExists("/a.ts")
        fs:FileExists("/a.ts")
        assert.are.equal(5, calls.FileExists)
    end)
end)

describe("vfsmatch", function()
    local vfsmatch = require("tslua.vfs.vfsmatch")

    local function caseInsensitiveHost()
        return vfstest.FromMap({
            ["/dev/a.ts"] = "", ["/dev/a.d.ts"] = "", ["/dev/a.js"] = "", ["/dev/b.ts"] = "", ["/dev/b.js"] = "",
            ["/dev/c.d.ts"] = "", ["/dev/z/a.ts"] = "", ["/dev/z/abz.ts"] = "", ["/dev/z/aba.ts"] = "",
            ["/dev/z/b.ts"] = "", ["/dev/z/bbz.ts"] = "", ["/dev/z/bba.ts"] = "", ["/dev/x/a.ts"] = "",
            ["/dev/x/aa.ts"] = "", ["/dev/x/b.ts"] = "", ["/dev/x/y/a.ts"] = "", ["/dev/x/y/b.ts"] = "",
            ["/dev/js/a.js"] = "", ["/dev/js/b.js"] = "", ["/dev/js/d.min.js"] = "", ["/dev/js/ab.min.js"] = "",
            ["/ext/ext.ts"] = "", ["/ext/b/a..b.ts"] = "",
        }, false)
    end

    local function run(includes, excludes, extensions)
        local host = caseInsensitiveHost()
        return vfsmatch.matchFiles("/dev", extensions or { ".ts", ".tsx", ".d.ts" }, excludes, includes, host:UseCaseSensitiveFileNames(), "/", vfsmatch.UnlimitedDepth, host)
    end

    it("matches literal includes", function()
        assert.are.same({ "/dev/a.ts", "/dev/b.ts" }, run({ "a.ts", "b.ts" }))
        assert.are.equal(0, #(run({ "a.js", "b.js" }) or {}))
        assert.are.same({ "/dev/a.ts" }, run({ "a.ts", "b.ts" }, { "b.ts" }))
        assert.are.same({ "/dev/z/a.ts", "/dev/z/aba.ts" }, run({ "a.ts", "b.ts", "z/a.ts", "z/abz.ts", "z/aba.ts", "x/b.ts" }, { "*.ts", "z/??z.ts", "*/b.ts" }))
        assert.are.same({ "/dev/a.ts", "/dev/x/a.ts", "/dev/x/y/a.ts" }, run({ "a.ts", "b.ts", "x/a.ts", "x/b.ts", "x/y/a.ts", "x/y/b.ts" }, { "**/b.ts" }))
    end)

    it("matches wildcard includes in include order", function()
        assert.are.same({
            "/dev/z/a.ts", "/dev/z/aba.ts", "/dev/z/abz.ts", "/dev/z/b.ts", "/dev/z/bba.ts", "/dev/z/bbz.ts",
            "/dev/x/a.ts", "/dev/x/aa.ts", "/dev/x/b.ts",
        }, run({ "z/*.ts", "x/*.ts" }))
        assert.are.same({ "/dev/x/a.ts", "/dev/x/b.ts" }, run({ "x/?.ts" }))
        assert.are.same({ "/dev/x/a.ts", "/dev/x/y/a.ts" }, run({ "x/**/a.ts" }))
    end)

    it("excludes .min.js unless mentioned", function()
        assert.are.same({ "/dev/js/a.js", "/dev/js/b.js" }, run({ "js/*" }, nil, { ".js" }))
        assert.are.same({ "/dev/js/ab.min.js", "/dev/js/d.min.js" }, run({ "js/*.min.js" }, nil, { ".js" }))
    end)

    it("SpecMatcher.MatchString", function()
        local m = vfsmatch.NewSpecMatcher({ "*.ts" }, "/project", vfsmatch.Usage.Files, true)
        assert.is_true(m:MatchString("/project/a.ts"))
        assert.is_false(m:MatchString("/project/sub/a.ts"))
        assert.is_false(m:MatchString("/project/a.js"))
        m = vfsmatch.NewSpecMatcher({ "**/*.ts" }, "/project", vfsmatch.Usage.Files, true)
        assert.is_true(m:MatchString("/project/sub/a.ts"))
        m = vfsmatch.NewSpecMatcher({ "node_modules" }, "/project", vfsmatch.Usage.Exclude, true)
        assert.is_false(m:MatchString("/project/node_modules"))
        assert.is_true(m:MatchString("/project/node_modules/foo"))
        assert.is_false(m:MatchString("/project/src"))
        assert.are.equal(-1, m:MatchIndex("/project/src"))
        assert.is_nil(vfsmatch.NewSpecMatcher({}, "/project", vfsmatch.Usage.Files, true))
        assert.are.equal("Exclude", vfsmatch.Usage_String(vfsmatch.Usage.Exclude))
    end)
end)

describe("osvfs", function()
    local fs = osvfs.FS()
    local dir = os.tmpname()
    os.remove(dir)

    it("reads, writes and lists real directories", function()
        assert.is_nil(fs:WriteFile(dir .. "/sub/a.txt", "hello"))
        assert.is_nil(fs:AppendFile(dir .. "/sub/a.txt", ", world"))
        assert.are.equal("hello, world", (fs:ReadFile(dir .. "/sub/a.txt")))
        assert.is_true(fs:FileExists(dir .. "/sub/a.txt"))
        assert.is_false(fs:FileExists(dir .. "/sub"))
        assert.is_true(fs:DirectoryExists(dir .. "/sub"))
        assert.is_false(fs:DirectoryExists(dir .. "/nope"))
        local entries = fs:GetAccessibleEntries(dir)
        assert.are.same({ "sub" }, entries.directories)
        assert.are.same({}, entries.files)
        assert.are.equal(12, fs:Stat(dir .. "/sub/a.txt"):Size())
        assert.are.equal(dir .. "/sub/a.txt", fs:Realpath(dir .. "/sub/../sub/a.txt"))
        local walked = {}
        fs:WalkDir(dir, function(p)
            walked[#walked + 1] = string.sub(p, #dir + 1)
            return nil
        end)
        assert.are.same({ "", "/sub", "/sub/a.txt" }, walked)
        assert.is_nil(fs:Remove(dir))
        assert.is_false(fs:DirectoryExists(dir))
    end)

    it("swaps case", function()
        assert.are.equal("aBc/D", osvfs.swapCase("AbC/d"))
    end)
end)

describe("bundled", function()
    local bundled = require("tslua.bundled")

    it("serves the libs under bundled:///libs", function()
        local fs = bundled.WrapFS(vfstest.FromMap({ ["/a.ts"] = "a" }, true))
        assert.are.equal("bundled:///libs", bundled.LibPath())
        assert.is_true(bundled.IsBundled("bundled:///libs/lib.d.ts"))
        assert.is_true(fs:DirectoryExists("bundled:///libs"))
        assert.is_true(fs:FileExists("bundled:///libs/lib.es5.d.ts"))
        assert.is_false(fs:FileExists("bundled:///libs/lib.nope.d.ts"))
        local text, ok = fs:ReadFile("bundled:///libs/lib.es5.d.ts")
        assert.is_true(ok)
        assert.truthy(string.find(text, "interface Array<T>", 1, true))
        assert.are.equal(#bundled.LibNames, #fs:GetAccessibleEntries("bundled:///libs").files)
        assert.are.equal("lib.d.ts", fs:Stat("bundled:///libs/lib.d.ts"):Name())
        assert.are.equal("a", (fs:ReadFile("/a.ts")))
        assert.are.equal("bundled:///libs/lib.d.ts", fs:Realpath("bundled:///libs/lib.d.ts"))
        assert.has_error(function() fs:WriteFile("bundled:///libs/x.d.ts", "") end, "cannot write to embedded file system")
    end)
end)
