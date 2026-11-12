-- Port of typescript-go internal/vfs/osvfs/realpath_test.go (with the helpers_test.go helper).
-- The os package calls used for setup (os.MkdirAll, os.WriteFile, os.Symlink, t.TempDir) go
-- through the shell, like the pure-Lua osvfs port itself.
local osvfs = require("tslua.vfs.osvfs")
local tspath = require("tslua.tspath")

local shellQuote = osvfs.shellQuote

local function run(cmd)
    return os.execute(cmd) == true
end

-- t.TempDir: removed after the test.
local tempDirs = {}

local function tempDir()
    local p = assert(io.popen("mktemp -d /tmp/tslua-osvfs-XXXXXX"))
    local dir = p:read("l")
    p:close()
    assert(dir ~= nil and dir ~= "", "mktemp failed")
    tempDirs[#tempDirs + 1] = dir
    return dir
end

local function removeTempDirs()
    for _, dir in ipairs(tempDirs) do
        os.execute("rm -rf -- " .. shellQuote(dir))
    end
    tempDirs = {}
end

local function mkdirAll(path)
    return run("mkdir -p -- " .. shellQuote(path))
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if f == nil then
        return false
    end
    f:write(data)
    f:close()
    return true
end

local function readFile(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local data = f:read("a")
    f:close()
    return data
end

-- mklink (helpers_test.go); the port is POSIX-only, so this is always os.Symlink.
local function mklink(target, link, isDir) -- luacheck: no unused args
    assert.is_true(run("ln -s -- " .. shellQuote(target) .. " " .. shellQuote(link)))
end

local function setupSymlinks()
    local tmp = tempDir()

    local target = tmp .. "/target"
    local targetFile = target .. "/file"

    local link = tmp .. "/link"
    local linkFile = link .. "/file"

    assert.is_true(mkdirAll(target))
    assert.is_true(writeFile(targetFile, "hello"))

    mklink(target, link, true)

    return targetFile, linkFile
end

describe("TestSymlinkRealpath", function()
    after_each(removeTempDirs)

    it("TestSymlinkRealpath", function()
        local targetFile, linkFile = setupSymlinks()

        local gotContents = readFile(linkFile)
        assert.are.equal("hello", gotContents)

        local fs = osvfs.FS()

        local targetRealpath = fs:Realpath(tspath.NormalizePath(targetFile))
        local linkRealpath = fs:Realpath(tspath.NormalizePath(linkFile))

        assert.are.equal(targetRealpath, linkRealpath,
            "expected realpath of target and link to be equal")
    end)
end)

describe("TestGetAccessibleEntries", function()
    after_each(removeTempDirs)

    it("TestGetAccessibleEntries", function()
        local tmp = tempDir()
        local target = tmp .. "/target"
        local link = tmp .. "/link"

        assert.is_true(mkdirAll(target))
        assert.is_true(mkdirAll(link))

        local targetFile1 = target .. "/file1"
        local targetFile2 = target .. "/file2"

        assert.is_true(writeFile(targetFile1, "hello"))
        assert.is_true(writeFile(targetFile2, "world"))

        local targetDir1 = target .. "/dir1"
        local targetDir2 = target .. "/dir2"

        assert.is_true(mkdirAll(targetDir1))
        assert.is_true(mkdirAll(targetDir2))

        mklink(targetFile1, link .. "/file1", false)
        mklink(targetFile2, link .. "/file2", false)
        mklink(targetDir1, link .. "/dir1", true)
        mklink(targetDir2, link .. "/dir2", true)

        local fs = osvfs.FS()

        local function mapLen(m)
            local n = 0
            for _ in pairs(m) do
                n = n + 1
            end
            return n
        end

        local entries = fs:GetAccessibleEntries(tspath.NormalizePath(link))

        assert.are.same({ "dir1", "dir2" }, entries.directories)
        assert.are.same({ "file1", "file2" }, entries.files)
        assert.is_true(entries.symlinks ~= nil, "expected Symlinks to be set for directory with symlinks")
        assert.are.equal(4, mapLen(entries.symlinks))
        for _, name in ipairs({ "file1", "file2", "dir1", "dir2" }) do
            assert.is_true(entries.symlinks[name] ~= nil, "expected " .. name .. " to be in Symlinks")
        end

        -- Non-symlink directory should have empty Symlinks.
        entries = fs:GetAccessibleEntries(tspath.NormalizePath(target))
        assert.are.same({ "dir1", "dir2" }, entries.directories)
        assert.are.same({ "file1", "file2" }, entries.files)
        assert.is_true(entries.symlinks ~= nil, "expected Symlinks to be non-nil for directory without symlinks")
        assert.are.equal(0, mapLen(entries.symlinks))
    end)
end)
