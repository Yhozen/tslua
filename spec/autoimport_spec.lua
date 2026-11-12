local ast = require("tslua.ast")
local binder = require("tslua.binder")
local checker = require("tslua.checker")
local core = require("tslua.core")
local module = require("tslua.module")
local parser = require("tslua.parser")
local vfstest = require("tslua.vfs.vfstest")
local autoimport = require("tslua.ls.autoimport")

-- index_test.go

local testEntry = {}
testEntry.__index = testEntry

local function newTestEntry(name, package_)
    return setmetatable({ name = name, package_ = package_ }, testEntry)
end

function testEntry:Name()
    return self.name
end

describe("autoimport Index.Clone", function()
    it("filters entries by package", function()
        local idx = autoimport.NewIndex()
        idx:insertAsWords(newTestEntry("fooBar", "pkg-a"))
        idx:insertAsWords(newTestEntry("bazQux", "pkg-b"))
        idx:insertAsWords(newTestEntry("fooQux", "pkg-a"))

        -- Clone excluding pkg-b
        local cloned = idx:Clone(function(e)
            return e.package_ ~= "pkg-b"
        end)

        -- Original should have all 3 entries
        assert.are.equal(3, #idx.entries)

        -- Cloned should have 2 entries (only pkg-a)
        assert.are.equal(2, #cloned.entries)

        -- Search should work on cloned index
        local results = cloned:Find("fooBar", true)
        assert.are.equal(1, core.Len(results))
        assert.are.equal("fooBar", results[1].name)

        -- bazQux should not be in cloned index
        results = cloned:Find("bazQux", true)
        assert.are.equal(0, core.Len(results))

        -- Word prefix search should work
        results = cloned:SearchWordPrefix("foo")
        assert.are.equal(2, core.Len(results))
    end)

    it("handles nil index", function()
        local cloned = autoimport.Index.Clone(nil, function() return true end)
        assert.is_nil(cloned)
    end)

    it("handles empty index", function()
        local idx = autoimport.NewIndex()
        local cloned = idx:Clone(function() return true end)
        assert.are.equal(0, #cloned.entries)
    end)

    it("filters all entries", function()
        local idx = autoimport.NewIndex()
        idx:insertAsWords(newTestEntry("fooBar", "pkg-a"))
        idx:insertAsWords(newTestEntry("bazQux", "pkg-b"))

        local cloned = idx:Clone(function() return false end)
        assert.are.equal(0, #cloned.entries)
        assert.are.equal(nil, next(cloned.index))
    end)
end)

describe("autoimport Index search", function()
    it("finds case-insensitive and word-prefix matches", function()
        local idx = autoimport.NewIndex()
        idx:insertAsWords(newTestEntry("readFileSync", ""))
        idx:insertAsWords(newTestEntry("ReadStream", ""))
        idx:insertAsWords(newTestEntry("createReadStream", ""))
        assert.are.equal(1, core.Len(idx:Find("readfilesync", false)))
        assert.are.equal(0, core.Len(idx:Find("readfilesync", true)))
        local names = {}
        for _, e in ipairs(idx:SearchWordPrefix("rs") or {}) do
            names[#names + 1] = e.name
        end
        assert.are.same({ "readFileSync", "ReadStream", "createReadStream" }, names)
        assert.are.equal(3, core.Len(idx:SearchWordPrefix("")))
    end)
end)

-- util_test.go

describe("autoimport wordIndices", function()
    local tests = {
        -- Basic camelCase
        { input = "camelCase", expectedWords = { "camelCase", "Case" } },
        -- snake_case
        { input = "snake_case", expectedWords = { "snake_case", "case" } },
        -- ParseURL - uppercase sequence followed by lowercase
        { input = "ParseURL", expectedWords = { "ParseURL", "URL" } },
        -- XMLHttpRequest - multiple uppercase sequences
        { input = "XMLHttpRequest", expectedWords = { "XMLHttpRequest", "HttpRequest", "Request" } },
        -- Single word lowercase
        { input = "hello", expectedWords = { "hello" } },
        -- Single word uppercase
        { input = "HELLO", expectedWords = { "HELLO" } },
        -- Mixed with numbers
        { input = "parseHTML5Parser", expectedWords = { "parseHTML5Parser", "HTML5Parser", "Parser" } },
        -- Underscore variations
        { input = "__proto__", expectedWords = { "__proto__", "proto__" } },
        { input = "_private_member", expectedWords = { "_private_member", "member" } },
        -- Single character
        { input = "a", expectedWords = { "a" } },
        { input = "A", expectedWords = { "A" } },
        -- Consecutive underscores
        { input = "test__double__underscore", expectedWords = { "test__double__underscore", "double__underscore", "underscore" } },
    }

    for _, tt in ipairs(tests) do
        it(tt.input, function()
            local indices = autoimport.wordIndices(tt.input)

            -- Convert indices to actual word slices for comparison
            local actualWords = {}
            for _, idx in ipairs(indices) do
                actualWords[#actualWords + 1] = string.sub(tt.input, idx + 1)
            end

            assert.are.same(tt.expectedWords, actualWords)
        end)
    end
end)

-- TestGetPackageRealpathFuncs_FollowsNodeModulesSymlinks tests that toRealpath correctly
-- follows symlinks for files outside the package directory (e.g. node_modules entries).
describe("autoimport getPackageRealpathFuncs", function()
    it("follows node_modules symlinks", function()
        -- Simulate a layout where the package directory is itself a symlink (e.g. Bazel's
        -- convenience symlinks or pnpm's virtual store):
        --   /symlink-bin/pkg/              -> symlink to /real/bin/pkg/
        --   /real/bin/pkg/node_modules/dep -> symlink to /real/dep/
        local fs = vfstest.FromMap({
            ["/symlink-bin/pkg"] = vfstest.Symlink("/real/bin/pkg"),
            ["/real/bin/pkg/index.d.ts"] = "export declare const a: number;",
            ["/real/bin/pkg/node_modules/dep"] = vfstest.Symlink("/real/dep"),
            ["/real/dep/index.d.ts"] = "export declare const b: number;",
            ["/real/dep/src/utils/helper.d.ts"] = "export declare const c: number;",
        }, true)

        local toRealpath = autoimport.getPackageRealpathFuncs(fs, "/symlink-bin/pkg")

        -- Files inside the package should be converted via string replacement (fast path).
        assert.are.equal("/real/bin/pkg/index.d.ts", toRealpath("/symlink-bin/pkg/index.d.ts"))

        -- Files outside the package (e.g. node_modules symlinks) should be resolved via
        -- fs.Realpath so the cache key is the canonical realpath, not the symlink path.
        assert.are.equal("/real/dep/index.d.ts", toRealpath("/real/bin/pkg/node_modules/dep/index.d.ts"))

        -- Files in subdirectories of an already-resolved external package should
        -- use the cached prefix mapping without additional realpath calls.
        assert.are.equal("/real/dep/src/utils/helper.d.ts", toRealpath("/real/bin/pkg/node_modules/dep/src/utils/helper.d.ts"))
    end)

    -- TestGetPackageRealpathFuncs_DuplicateCacheKeys
    it("gives the same cache key to a dependency reached through different symlinks", function()
        local fs = vfstest.FromMap({
            ["/workspace/packages/app-a"] = vfstest.Symlink("/store/app-a"),
            ["/workspace/packages/app-b"] = vfstest.Symlink("/store/app-b"),
            ["/store/app-a/index.d.ts"] = "export declare const a: number;",
            ["/store/app-b/index.d.ts"] = "export declare const b: number;",
            ["/store/app-a/node_modules/shared-lib"] = vfstest.Symlink("/store/shared-lib"),
            ["/store/app-b/node_modules/shared-lib"] = vfstest.Symlink("/store/shared-lib"),
            ["/store/shared-lib/index.d.ts"] = "export declare const shared: string;",
        }, true)

        local toRealpathA = autoimport.getPackageRealpathFuncs(fs, "/workspace/packages/app-a")
        local toRealpathB = autoimport.getPackageRealpathFuncs(fs, "/workspace/packages/app-b")

        local resolvedA = toRealpathA("/store/app-a/node_modules/shared-lib/index.d.ts")
        local resolvedB = toRealpathB("/store/app-b/node_modules/shared-lib/index.d.ts")

        -- Both should resolve to the same canonical realpath so the module resolver
        -- uses a single cache key for the shared dependency, avoiding duplicate loads.
        assert.are.equal("/store/shared-lib/index.d.ts", resolvedA)
        assert.are.equal("/store/shared-lib/index.d.ts", resolvedB)
    end)

    -- TestGetPackageRealpathFuncs_NonSymlinkedPackageWithSymlinkedDeps
    it("follows symlinked deps of a non-symlinked package", function()
        local fs = vfstest.FromMap({
            ["/real/my-pkg/index.d.ts"] = "export declare const a: number;",
            ["/real/my-pkg/node_modules/dep"] = vfstest.Symlink("/real/dep"),
            ["/real/dep/index.d.ts"] = "export declare const b: number;",
        }, true)

        local toRealpath = autoimport.getPackageRealpathFuncs(fs, "/real/my-pkg")

        -- Files inside the (non-symlinked) package should be returned unchanged.
        assert.are.equal("/real/my-pkg/index.d.ts", toRealpath("/real/my-pkg/index.d.ts"))

        -- Files outside the package reached via symlinked node_modules should still be resolved.
        assert.are.equal("/real/dep/index.d.ts", toRealpath("/real/my-pkg/node_modules/dep/index.d.ts"))
    end)
end)

-- aliasresolver_crash_test.go

local fakeCloneHost = {}
fakeCloneHost.__index = fakeCloneHost

function fakeCloneHost:FS() return self.fs end
function fakeCloneHost:GetCurrentDirectory() return "/" end
function fakeCloneHost:GetDefaultProject() return "", nil end
function fakeCloneHost:GetProgramForProject() return nil end
function fakeCloneHost:GetPackageJson() return nil end
function fakeCloneHost:GetSourceFile() return nil end
function fakeCloneHost:Dispose() end

describe("autoimport aliasResolver", function()
    -- Regression test for microsoft/typescript-go#4322.
    --
    -- During auto-import export extraction, the checker is built on top of an
    -- aliasResolver standing in for a real program. This file has a type error, and
    -- extracting exports should still complete without crashing.
    it("GetDiagnostics does not panic", function()
        local fileName = "/pkg/index.ts"
        local text = "declare function f(arg: { a: string }): () => void;\nexport const x = f({ a: 1 });\n"

        local fs = vfstest.FromMap({ [fileName] = text }, true --[[useCaseSensitiveFileNames]])
        local host = setmetatable({ fs = fs }, fakeCloneHost)

        local sourceFile = parser.ParseSourceFile(ast.NewSourceFileParseOptions(fileName, fileName), text, core.ScriptKind.TS)
        binder.BindSourceFile(sourceFile)

        local resolver = module.NewResolver(host, core.EmptyCompilerOptions, "", "", nil)
        local r = autoimport.newAliasResolver(
            { sourceFile },
            nil,
            host,
            resolver,
            function(f) return f end,
            function() end
        )

        local ch = checker.NewChecker(r, nil)

        -- Type-checking this file's diagnostics must not panic.
        ch:GetDiagnostics(nil, sourceFile)
    end)
end)
