-- Port of typescript-go internal/vfs/osvfs/os_test.go.
local osvfs = require("tslua.vfs.osvfs")
local repo = require("tslua.repo")
local tspath = require("tslua.tspath")

-- os.ReadFile
local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("a")
    f:close()
    return data
end

describe("TestOS", function()
    local fs = osvfs.FS()

    it("ReadFile", function()
        local goMod = repo.RootPath() .. "/go.mod"
        local goModPath = tspath.NormalizePath(goMod)

        local expected = readFile(goMod)

        local contents, ok = fs:ReadFile(goModPath)
        assert.is_true(ok)
        assert.are.equal(expected, contents)
    end)

    local home = os.getenv("HOME") -- os.UserHomeDir on Unix
    if home == nil or home == "" then
        pending("Realpath: $HOME is not defined")
    else
        it("Realpath", function()
            home = tspath.NormalizePath(home)

            local expected = home
            local realpath = fs:Realpath(home)
            assert.are.equal(expected, realpath)
        end)
    end

    it("UseCaseSensitiveFileNames", function()
        -- Just check that it works.
        fs:UseCaseSensitiveFileNames()

        -- The port is POSIX-only (runtime.GOOS "linux" case).
        assert.is_true(fs:UseCaseSensitiveFileNames())
    end)
end)
