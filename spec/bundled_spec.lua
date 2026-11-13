-- tslua.bundled: the bundled:/// file system serving src/tslua/bundled/libs, and the rockspec that
-- installs those libs next to the module. (The Go tests of internal/vfs/** are ported in
-- spec/{vfstest_vfstest,cachedvfs_cachedvfs,vfsmatch_vfsmatch,osvfs_os,...}_spec.lua.)
local bundled = require("tslua.bundled")
local vfstest = require("tslua.vfs.vfstest")

describe("bundled", function()
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

    it("is installed with every lib by the rockspec", function()
        local env = {}
        local chunk = assert(loadfile("tslua-dev-1.rockspec", "t", env))
        chunk()
        local installed = {}
        for key, file in pairs(env.build.install.lua) do
            local name = string.match(file, "^src/tslua/bundled/libs/(.+)$")
            assert.is_not_nil(name, file)
            assert.are.equal("tslua.bundled.libs.", string.sub(key, 1, 19))
            installed[#installed + 1] = name
        end
        table.sort(installed)
        local expected = {}
        for i, name in ipairs(bundled.LibNames) do
            expected[i] = name
        end
        table.sort(expected)
        assert.are.same(expected, installed)
    end)
end)
