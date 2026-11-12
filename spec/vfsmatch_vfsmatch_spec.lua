-- Port of typescript-go internal/vfs/vfsmatch/vfsmatch_test.go.
local vfsmatch = require("tslua.vfs.vfsmatch")
local vfstest = require("tslua.vfs.vfstest")

-- Go len/slices.Contains/range accept nil slices.
local function len(xs)
    if xs == nil then
        return 0
    end
    return #xs
end

local function slicesContains(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

local function containsAt(s, substr)
    for i = 0, #s - #substr do
        if string.sub(s, i + 1, i + #substr) == substr then
            return true
        end
    end
    return false
end

local function contains(s, substr)
    return #s >= #substr and (s == substr or #substr == 0 or
        (#s > #substr and containsAt(s, substr)))
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

-- Test cases modeled after TypeScript's matchFiles tests in
-- _submodules/TypeScript/src/testRunner/unittests/config/matchFiles.ts

-- caseInsensitiveHost simulates a Windows-like file system
local function caseInsensitiveHost()
    return vfstest.FromMap({
        ["/dev/a.ts"] = "",
        ["/dev/a.d.ts"] = "",
        ["/dev/a.js"] = "",
        ["/dev/b.ts"] = "",
        ["/dev/b.js"] = "",
        ["/dev/c.d.ts"] = "",
        ["/dev/z/a.ts"] = "",
        ["/dev/z/abz.ts"] = "",
        ["/dev/z/aba.ts"] = "",
        ["/dev/z/b.ts"] = "",
        ["/dev/z/bbz.ts"] = "",
        ["/dev/z/bba.ts"] = "",
        ["/dev/x/a.ts"] = "",
        ["/dev/x/aa.ts"] = "",
        ["/dev/x/b.ts"] = "",
        ["/dev/x/y/a.ts"] = "",
        ["/dev/x/y/b.ts"] = "",
        ["/dev/js/a.js"] = "",
        ["/dev/js/b.js"] = "",
        ["/dev/js/d.min.js"] = "",
        ["/dev/js/ab.min.js"] = "",
        ["/ext/ext.ts"] = "",
        ["/ext/b/a..b.ts"] = "",
    }, false)
end

-- caseSensitiveHost simulates a Unix-like case-sensitive file system
local function caseSensitiveHost()
    return vfstest.FromMap({
        ["/dev/a.ts"] = "",
        ["/dev/a.d.ts"] = "",
        ["/dev/a.js"] = "",
        ["/dev/b.ts"] = "",
        ["/dev/b.js"] = "",
        ["/dev/A.ts"] = "",
        ["/dev/B.ts"] = "",
        ["/dev/c.d.ts"] = "",
        ["/dev/z/a.ts"] = "",
        ["/dev/z/abz.ts"] = "",
        ["/dev/z/aba.ts"] = "",
        ["/dev/z/b.ts"] = "",
        ["/dev/z/bbz.ts"] = "",
        ["/dev/z/bba.ts"] = "",
        ["/dev/x/a.ts"] = "",
        ["/dev/x/b.ts"] = "",
        ["/dev/x/y/a.ts"] = "",
        ["/dev/x/y/b.ts"] = "",
        ["/dev/q/a/c/b/d.ts"] = "",
        ["/dev/js/a.js"] = "",
        ["/dev/js/b.js"] = "",
        ["/dev/js/d.MIN.js"] = "",
    }, true)
end

-- commonFoldersHost includes node_modules, bower_components, jspm_packages
local function commonFoldersHost()
    return vfstest.FromMap({
        ["/dev/a.ts"] = "",
        ["/dev/a.d.ts"] = "",
        ["/dev/a.js"] = "",
        ["/dev/b.ts"] = "",
        ["/dev/x/a.ts"] = "",
        ["/dev/node_modules/a.ts"] = "",
        ["/dev/bower_components/a.ts"] = "",
        ["/dev/jspm_packages/a.ts"] = "",
    }, false)
end

-- dottedFoldersHost includes files and folders starting with a dot
local function dottedFoldersHost()
    return vfstest.FromMap({
        ["/dev/x/d.ts"] = "",
        ["/dev/x/y/d.ts"] = "",
        ["/dev/x/y/.e.ts"] = "",
        ["/dev/x/.y/a.ts"] = "",
        ["/dev/.z/.b.ts"] = "",
        ["/dev/.z/c.ts"] = "",
        ["/dev/w/.u/e.ts"] = "",
        ["/dev/g.min.js/.g/g.ts"] = "",
    }, false)
end

-- mixedExtensionHost has various file extensions
local function mixedExtensionHost()
    return vfstest.FromMap({
        ["/dev/a.ts"] = "",
        ["/dev/a.d.ts"] = "",
        ["/dev/a.js"] = "",
        ["/dev/b.tsx"] = "",
        ["/dev/b.d.ts"] = "",
        ["/dev/b.jsx"] = "",
        ["/dev/c.tsx"] = "",
        ["/dev/c.js"] = "",
        ["/dev/d.js"] = "",
        ["/dev/e.jsx"] = "",
        ["/dev/f.other"] = "",
    }, false)
end

-- sameNamedDeclarationsHost has files with same names but different extensions
local function sameNamedDeclarationsHost()
    return vfstest.FromMap({
        ["/dev/a.tsx"] = "",
        ["/dev/a.d.ts"] = "",
        ["/dev/b.tsx"] = "",
        ["/dev/b.ts"] = "",
        ["/dev/c.tsx"] = "",
        ["/dev/m.ts"] = "",
        ["/dev/m.d.ts"] = "",
        ["/dev/n.tsx"] = "",
        ["/dev/n.ts"] = "",
        ["/dev/n.d.ts"] = "",
        ["/dev/o.ts"] = "",
        ["/dev/x.d.ts"] = "",
    }, false)
end


local function runReadDirectoryCase(tc)
    local currentDir = tc.currentDir or ""
    if currentDir == "" then
        currentDir = "/"
    end
    local path = tc.path or ""
    if path == "" then
        path = "/dev"
    end
    local depth = tc.depth or 0
    if depth == 0 then
        depth = vfsmatch.UnlimitedDepth
    end
    local host = tc.host()
    local got = vfsmatch.matchFiles(path, tc.extensions, tc.excludes, tc.includes, host:UseCaseSensitiveFileNames(), currentDir, depth, host)
    tc.expect(got)
end

describe("TestReadDirectory", function()

    local cases = {
        {
            name = "defaults include common package folders",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/b.ts"))
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/node_modules/a.ts"))
                assert.is_true(slicesContains(got, "/dev/bower_components/a.ts"))
                assert.is_true(slicesContains(got, "/dev/jspm_packages/a.ts"))
            end,
        },
        {
            name = "literal includes without exclusions",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"a.ts", "b.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/a.ts", "/dev/b.ts"})
            end,
        },
        {
            name = "literal includes with non ts extensions excluded",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"a.js", "b.js"},
            expect = function(got)
                assert.are.equal(len(got), 0)
            end,
        },
        {
            name = "literal includes missing files excluded",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"z.ts", "x.ts"},
            expect = function(got)
                assert.are.equal(len(got), 0)
            end,
        },
        {
            name = "literal includes with literal excludes",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"b.ts"},
            includes = {"a.ts", "b.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/a.ts"})
            end,
        },
        {
            name = "literal includes with wildcard excludes",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"*.ts", "z/??z.ts", "*/b.ts"},
            includes = {"a.ts", "b.ts", "z/a.ts", "z/abz.ts", "z/aba.ts", "x/b.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/z/a.ts", "/dev/z/aba.ts"})
            end,
        },
        {
            name = "literal includes with recursive excludes",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**/b.ts"},
            includes = {"a.ts", "b.ts", "x/a.ts", "x/b.ts", "x/y/a.ts", "x/y/b.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/a.ts", "/dev/x/a.ts", "/dev/x/y/a.ts"})
            end,
        },
        {
            name = "case sensitive exclude is respected",
            host = caseSensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**/b.ts"},
            includes = {"B.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/B.ts"})
            end,
        },
        {
            name = "explicit includes keep common package folders",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"a.ts", "b.ts", "node_modules/a.ts", "bower_components/a.ts", "jspm_packages/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/b.ts"))
                assert.is_true(slicesContains(got, "/dev/node_modules/a.ts"))
                assert.is_true(slicesContains(got, "/dev/bower_components/a.ts"))
                assert.is_true(slicesContains(got, "/dev/jspm_packages/a.ts"))
            end,
        },
        {
            name = "wildcard include sorted order",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"z/*.ts", "x/*.ts"},
            expect = function(got)
                local expected = {
                    "/dev/z/a.ts", "/dev/z/aba.ts", "/dev/z/abz.ts", "/dev/z/b.ts", "/dev/z/bba.ts", "/dev/z/bbz.ts",
                    "/dev/x/a.ts", "/dev/x/aa.ts", "/dev/x/b.ts",
                }
                assert.are.same(got, expected)
            end,
        },
        {
            name = "wildcard include same named declarations excluded",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/b.ts"))
                assert.is_true(slicesContains(got, "/dev/a.d.ts"))
                assert.is_true(slicesContains(got, "/dev/c.d.ts"))
            end,
        },
        {
            name = "wildcard star matches only ts files",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(contains(f, ".ts") or contains(f, ".tsx") or contains(f, ".d.ts"), "unexpected file: %s", f)
                end
                assert.is_true(not slicesContains(got, "/dev/a.js"))
                assert.is_true(not slicesContains(got, "/dev/b.js"))
            end,
        },
        {
            name = "wildcard question mark single character",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/?.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/x/a.ts", "/dev/x/b.ts"})
            end,
        },
        {
            name = "wildcard recursive directory",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/z/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/a.ts"))
            end,
        },
        {
            name = "double asterisk matches zero-or-more directories",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/**/a.ts"},
            expect = function(got)
                assert.are.equal(len(got), 2)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/a.ts"))
            end,
        },
        {
            name = "wildcard multiple recursive directories",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/y/**/a.ts", "x/**/a.ts", "z/**/a.ts"},
            expect = function(got)
                assert.is_true(len(got) > 0)
            end,
        },
        {
            name = "wildcard case sensitive matching",
            host = caseSensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/A.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/A.ts"})
            end,
        },
        {
            name = "wildcard missing files excluded",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*/z.ts"},
            expect = function(got) assert.are.equal(len(got), 0) end,
        },
        {
            name = "exclude folders with wildcards",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"z", "x"},
            includes = {"**/*"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(not contains(f, "/z/") and not contains(f, "/x/"), "should not contain z or x: %s", f)
                end
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/b.ts"))
            end,
        },
        {
            name = "include paths outside project absolute",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*", "/ext/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/ext/ext.ts"))
            end,
        },
        {
            name = "include paths outside project relative",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**"},
            includes = {"*", "../ext/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/ext/ext.ts"))
            end,
        },
        {
            name = "include files containing double dots",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**"},
            includes = {"/ext/b/a..b.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/ext/b/a..b.ts"))
            end,
        },
        {
            name = "exclude files containing double dots",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"/ext/b/a..b.ts"},
            includes = {"/ext/**/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/ext/ext.ts"))
                assert.is_true(not slicesContains(got, "/ext/b/a..b.ts"))
            end,
        },
        {
            name = "common package folders implicitly excluded",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/node_modules/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/bower_components/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/jspm_packages/a.ts"))
            end,
        },
        {
            name = "common package folders explicit recursive include",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/a.ts", "**/node_modules/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/node_modules/a.ts"))
            end,
        },
        {
            name = "common package folders wildcard include",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/node_modules/a.ts"))
            end,
        },
        {
            name = "common package folders explicit wildcard include",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*/a.ts", "node_modules/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/node_modules/a.ts"))
            end,
        },
        {
            name = "dotted folders not implicitly included",
            host = dottedFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/**/*", "w/*/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/d.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/d.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/.y/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/y/.e.ts"))
                assert.is_true(not slicesContains(got, "/dev/w/.u/e.ts"))
            end,
        },
        {
            name = "dotted folders explicitly included",
            host = dottedFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/.y/a.ts", "/dev/.z/.b.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/.y/a.ts"))
                assert.is_true(slicesContains(got, "/dev/.z/.b.ts"))
            end,
        },
        {
            name = "dotted folders recursive wildcard matches directories",
            host = dottedFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/.*/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/.y/a.ts"))
                assert.is_true(slicesContains(got, "/dev/.z/c.ts"))
                assert.is_true(slicesContains(got, "/dev/w/.u/e.ts"))
            end,
        },
        {
            name = "trailing recursive include returns empty",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**"},
            expect = function(got) assert.are.equal(len(got), 0) end,
        },
        {
            name = "trailing recursive exclude removes everything",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**"},
            includes = {"**/*"},
            expect = function(got) assert.are.equal(len(got), 0) end,
        },
        {
            name = "multiple recursive directory patterns in includes",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/x/**/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/a.ts"))
            end,
        },
        {
            name = "multiple recursive directory patterns in excludes",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**/x/**"},
            includes = {"**/a.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/z/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/y/a.ts"))
            end,
        },
        {
            name = "implicit globbification expands directory",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"z"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/z/a.ts"))
                assert.is_true(slicesContains(got, "/dev/z/aba.ts"))
                assert.is_true(slicesContains(got, "/dev/z/b.ts"))
            end,
        },
        {
            name = "exclude patterns starting with starstar",
            host = caseSensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**/x"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(not contains(f, "/x/"), "should not contain /x/: %s", f)
                end
            end,
        },
        {
            name = "include patterns starting with starstar",
            host = caseSensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/x", "**/a/**/b"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/q/a/c/b/d.ts"))
            end,
        },
        {
            name = "depth limit one",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            depth = 1,
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    local suffix = string.sub(f, #"/dev/" + 1)
                    assert.is_true(not contains(suffix, "/"), "depth 1 should not include nested files: %s", f)
                end
            end,
        },
        {
            name = "depth limit two",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            depth = 2,
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/z/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/y/a.ts"))
            end,
        },
        {
            name = "mixed extensions only ts",
            host = mixedExtensionHost,
            extensions = {".ts"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(hasSuffix(f, ".ts"), "should only have .ts files: %s", f)
                end
            end,
        },
        {
            name = "mixed extensions ts and tsx",
            host = mixedExtensionHost,
            extensions = {".ts", ".tsx"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(hasSuffix(f, ".ts") or hasSuffix(f, ".tsx"), "should only have .ts or .tsx files: %s", f)
                end
            end,
        },
        {
            name = "mixed extensions js and jsx",
            host = mixedExtensionHost,
            extensions = {".js", ".jsx"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(hasSuffix(f, ".js") or hasSuffix(f, ".jsx"), "should only have .js or .jsx files: %s", f)
                end
            end,
        },
        {
            name = "min js files excluded by wildcard",
            host = caseInsensitiveHost,
            extensions = {".js"},
            includes = {"js/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/js/a.js"))
                assert.is_true(slicesContains(got, "/dev/js/b.js"))
                assert.is_true(not slicesContains(got, "/dev/js/d.min.js"))
                assert.is_true(not slicesContains(got, "/dev/js/ab.min.js"))
            end,
        },
        {
            name = "min js exclusion is case-sensitive on case-sensitive FS",
            host = caseSensitiveHost,
            extensions = {".js"},
            includes = {"js/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/js/a.js"))
                assert.is_true(slicesContains(got, "/dev/js/b.js"))
                -- Legacy behavior: only lowercase ".min.js" is excluded by default when matching is case-sensitive.
                assert.is_true(slicesContains(got, "/dev/js/d.MIN.js"))
            end,
        },
        {
            name = "min js files explicitly included",
            host = caseInsensitiveHost,
            extensions = {".js"},
            includes = {"js/*.min.js"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/js/d.min.js"))
                assert.is_true(slicesContains(got, "/dev/js/ab.min.js"))
            end,
        },
        {
            name = "min js files included when pattern mentions .min.",
            host = caseInsensitiveHost,
            extensions = {".js"},
            includes = {"js/*.min.*"},
            expect = function(got)
                assert.are.equal(len(got), 2)
                assert.is_true(slicesContains(got, "/dev/js/d.min.js"))
                assert.is_true(slicesContains(got, "/dev/js/ab.min.js"))
            end,
        },
        {
            name = "exclude literal node_modules folder",
            host = commonFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"node_modules"},
            includes = {"**/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/node_modules/a.ts"))
            end,
        },
        {
            name = "same named declarations include ts",
            host = sameNamedDeclarationsHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*.ts"},
            expect = function(got) assert.is_true(len(got) > 0) end,
        },
        {
            name = "same named declarations include tsx",
            host = sameNamedDeclarationsHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*.tsx"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(hasSuffix(f, ".tsx"), "should only have .tsx files: %s", f)
                end
            end,
        },
        {
            name = "empty includes returns all matching files",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            expect = function(got)
                assert.is_true(len(got) > 0)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
            end,
        },
        {
            name = "nil extensions returns all files",
            host = caseInsensitiveHost,
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/a.js"))
            end,
        },
        {
            name = "empty extensions slice returns all files",
            host = caseInsensitiveHost,
            extensions = {},
            expect = function(got) assert.is_true(len(got) > 0, "expected files to be returned") end,
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            runReadDirectoryCase(tc)
        end)
    end
end)

-- Additional tests for helper functions

describe("TestIsImplicitGlob", function()

    local tests = {
        { name = "simple", input = "foo", expected = true },
        { name = "folder", input = "src", expected = true },
        { name = "with extension", input = "foo.ts", expected = false },
        { name = "trailing dot", input = "foo.", expected = false },
        { name = "star", input = "*", expected = false },
        { name = "question", input = "?", expected = false },
        { name = "star suffix", input = "foo*", expected = false },
        { name = "question suffix", input = "foo?", expected = false },
        { name = "dot name", input = "foo.bar", expected = false },
        { name = "empty", input = "", expected = true },
    }

    for _, tt in ipairs(tests) do
        local tc = tt
        it(tc.name, function()
            local result = vfsmatch.IsImplicitGlob(tc.input)
            assert.are.equal(result, tc.expected)
        end)
    end
end)

-- Edge case tests for various pattern scenarios
describe("TestReadDirectoryEdgeCases", function()

    local cases = {
        {
            name = "rooted include path",
            host = caseInsensitiveHost,
            extensions = {".ts"},
            includes = {"/dev/a.ts"},
            expect = function(got) assert.is_true(slicesContains(got, "/dev/a.ts")) end,
        },
        {
            name = "include with extension in path",
            host = caseInsensitiveHost,
            extensions = {".ts"},
            includes = {"a.ts"},
            expect = function(got) assert.is_true(slicesContains(got, "/dev/a.ts")) end,
        },
        {
            name = "special regex characters in path",
            host = function()
                return vfstest.FromMap({
                    ["/dev/file+test.ts"] = "",
                    ["/dev/file[0].ts"] = "",
                    ["/dev/file(1).ts"] = "",
                    ["/dev/file$money.ts"] = "",
                    ["/dev/file^start.ts"] = "",
                    ["/dev/file|pipe.ts"] = "",
                    ["/dev/file#hash.ts"] = "",
                }, false)
            end,
            extensions = {".ts"},
            includes = {"file+test.ts"},
            expect = function(got) assert.is_true(slicesContains(got, "/dev/file+test.ts")) end,
        },
        {
            name = "include pattern starting with question mark",
            host = caseInsensitiveHost,
            extensions = {".ts"},
            includes = {"?.ts"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/b.ts"))
            end,
        },
        {
            name = "include pattern starting with star",
            host = caseInsensitiveHost,
            extensions = {".ts"},
            includes = {"*b.ts"},
            expect = function(got) assert.is_true(slicesContains(got, "/dev/b.ts")) end,
        },
        {
            name = "case insensitive file matching",
            host = function()
                return vfstest.FromMap({
                    ["/dev/File.ts"] = "",
                    ["/dev/FILE.ts"] = "",
                }, true)
            end,
            extensions = {".ts"},
            includes = {"*.ts"},
            expect = function(got) assert.is_true(len(got) == 2) end,
        },
        {
            name = "nested subdirectory base path",
            host = caseSensitiveHost,
            extensions = {".ts"},
            includes = {"q/a/c/b/d.ts"},
            expect = function(got) assert.is_true(slicesContains(got, "/dev/q/a/c/b/d.ts")) end,
        },
        {
            name = "current directory differs from path",
            host = caseInsensitiveHost,
            extensions = {".ts"},
            includes = {"z/*.ts"},
            expect = function(got) assert.is_true(len(got) > 0) end,
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            runReadDirectoryCase(tc)
        end)
    end
end)

describe("TestReadDirectoryEmptyIncludes", function()
    local cases = {
        {
            name = "empty includes slice behavior",
            host = function()
                return vfstest.FromMap({
                    ["/root/a.ts"] = "",
                }, true)
            end,
            path = "/root",
            currentDir = "/",
            extensions = {".ts"},
            includes = {},
            expect = function(got)
                if len(got) == 0 then
                    return
                end
                assert.is_true(slicesContains(got, "/root/a.ts"))
            end,
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            runReadDirectoryCase(tc)
        end)
    end
end)

-- TestReadDirectorySymlinkCycle tests that cyclic symlinks don't cause infinite loops.
-- The cycle is detected by the vfs package using Realpath for cycle detection.
-- This means directories with cyclic symlinks will be skipped during traversal.
describe("TestReadDirectorySymlinkCycle", function()
    local cases = {
        {
            name = "detects and skips symlink cycles",
            host = function()
                return vfstest.FromMap({
                    ["/root/file.ts"] = "",
                    ["/root/a/file.ts"] = "",
                    ["/root/a/b"] = vfstest.Symlink("/root/a"),
                }, true)
            end,
            path = "/root",
            currentDir = "/",
            extensions = {".ts"},
            includes = {"**/*"},
            expect = function(got)
                local expected = {"/root/file.ts", "/root/a/file.ts"}
                assert.are.same(got, expected)
            end,
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            runReadDirectoryCase(tc)
        end)
    end
end)

-- TestReadDirectoryMatchesTypeScriptBaselines contains tests that verify the Go implementation
-- matches the TypeScript baseline outputs from _submodules/TypeScript/tests/baselines/reference/config/matchFiles/
describe("TestReadDirectoryMatchesTypeScriptBaselines", function()

    local cases = {
        {
            name = "sorted in include order then alphabetical",
            host = function()
                return vfstest.FromMap({
                    ["/dev/z/a.ts"] = "",
                    ["/dev/z/aba.ts"] = "",
                    ["/dev/z/abz.ts"] = "",
                    ["/dev/z/b.ts"] = "",
                    ["/dev/z/bba.ts"] = "",
                    ["/dev/z/bbz.ts"] = "",
                    ["/dev/x/a.ts"] = "",
                    ["/dev/x/aa.ts"] = "",
                    ["/dev/x/b.ts"] = "",
                }, false)
            end,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"z/*.ts", "x/*.ts"},
            expect = function(got)
                local expected = {
                    "/dev/z/a.ts", "/dev/z/aba.ts", "/dev/z/abz.ts", "/dev/z/b.ts", "/dev/z/bba.ts", "/dev/z/bbz.ts",
                    "/dev/x/a.ts", "/dev/x/aa.ts", "/dev/x/b.ts",
                }
                assert.are.same(got, expected)
            end,
        },
        {
            name = "recursive wildcards match dotted directories",
            host = function()
                return vfstest.FromMap({
                    ["/dev/x/d.ts"] = "",
                    ["/dev/x/y/d.ts"] = "",
                    ["/dev/x/y/.e.ts"] = "",
                    ["/dev/x/.y/a.ts"] = "",
                    ["/dev/.z/.b.ts"] = "",
                    ["/dev/.z/c.ts"] = "",
                    ["/dev/w/.u/e.ts"] = "",
                    ["/dev/g.min.js/.g/g.ts"] = "",
                }, false)
            end,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/.*/*"},
            expect = function(got)
                local expected = {"/dev/.z/c.ts", "/dev/g.min.js/.g/g.ts", "/dev/w/.u/e.ts", "/dev/x/.y/a.ts"}
                assert.are.equal(len(got), len(expected))
                for _, want in ipairs(expected) do
                    assert.is_true(slicesContains(got, want))
                end
            end,
        },
        {
            name = "common package folders implicitly excluded with wildcard",
            host = function()
                return vfstest.FromMap({
                    ["/dev/a.ts"] = "",
                    ["/dev/a.d.ts"] = "",
                    ["/dev/a.js"] = "",
                    ["/dev/b.ts"] = "",
                    ["/dev/x/a.ts"] = "",
                    ["/dev/node_modules/a.ts"] = "",
                    ["/dev/bower_components/a.ts"] = "",
                    ["/dev/jspm_packages/a.ts"] = "",
                }, false)
            end,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/a.ts"},
            expect = function(got) assert.are.same(got, {"/dev/a.ts", "/dev/x/a.ts"}) end,
        },
        {
            name = "js wildcard excludes min js files",
            host = function()
                return vfstest.FromMap({
                    ["/dev/js/a.js"] = "",
                    ["/dev/js/b.js"] = "",
                    ["/dev/js/d.min.js"] = "",
                    ["/dev/js/ab.min.js"] = "",
                }, false)
            end,
            extensions = {".js"},
            includes = {"js/*"},
            expect = function(got) assert.are.same(got, {"/dev/js/a.js", "/dev/js/b.js"}) end,
        },
        {
            name = "explicit min js pattern includes min files",
            host = function()
                return vfstest.FromMap({
                    ["/dev/js/a.js"] = "",
                    ["/dev/js/b.js"] = "",
                    ["/dev/js/d.min.js"] = "",
                    ["/dev/js/ab.min.js"] = "",
                }, false)
            end,
            extensions = {".js"},
            includes = {"js/*.min.js"},
            expect = function(got)
                local expected = {"/dev/js/ab.min.js", "/dev/js/d.min.js"}
                assert.are.equal(len(got), len(expected))
                for _, want in ipairs(expected) do
                    assert.is_true(slicesContains(got, want))
                end
            end,
        },
        {
            name = "literal excludes baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"b.ts"},
            includes = {"a.ts", "b.ts"},
            expect = function(got) assert.are.same(got, {"/dev/a.ts"}) end,
        },
        {
            name = "wildcard excludes baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"*.ts", "z/??z.ts", "*/b.ts"},
            includes = {"a.ts", "b.ts", "z/a.ts", "z/abz.ts", "z/aba.ts", "x/b.ts"},
            expect = function(got) assert.are.same(got, {"/dev/z/a.ts", "/dev/z/aba.ts"}) end,
        },
        {
            name = "recursive excludes baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**/b.ts"},
            includes = {"a.ts", "b.ts", "x/a.ts", "x/b.ts", "x/y/a.ts", "x/y/b.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/a.ts", "/dev/x/a.ts", "/dev/x/y/a.ts"})
            end,
        },
        {
            name = "question mark baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/?.ts"},
            expect = function(got) assert.are.same(got, {"/dev/x/a.ts", "/dev/x/b.ts"}) end,
        },
        {
            name = "recursive directory pattern baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/a.ts"},
            expect = function(got)
                assert.are.same(got, {"/dev/a.ts", "/dev/x/a.ts", "/dev/x/y/a.ts", "/dev/z/a.ts"})
            end,
        },
        {
            name = "case sensitive baseline",
            host = caseSensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/A.ts"},
            expect = function(got) assert.are.same(got, {"/dev/A.ts"}) end,
        },
        {
            name = "exclude folders baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"z", "x"},
            includes = {"**/*"},
            expect = function(got)
                for _, f in ipairs(got or {}) do
                    assert.is_true(not contains(f, "/z/") and not contains(f, "/x/"), "should not contain z or x: %s", f)
                end
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/dev/b.ts"))
            end,
        },
        {
            name = "implicit glob expansion baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"z"},
            expect = function(got)
                assert.are.same(got, {"/dev/z/a.ts", "/dev/z/aba.ts", "/dev/z/abz.ts", "/dev/z/b.ts", "/dev/z/bba.ts", "/dev/z/bbz.ts"})
            end,
        },
        {
            name = "trailing recursive directory baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**"},
            expect = function(got) assert.are.equal(len(got), 0) end,
        },
        {
            name = "exclude trailing recursive directory baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**"},
            includes = {"**/*"},
            expect = function(got) assert.are.equal(len(got), 0) end,
        },
        {
            name = "multiple recursive directory patterns baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/x/**/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/aa.ts"))
                assert.is_true(slicesContains(got, "/dev/x/b.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/b.ts"))
            end,
        },
        {
            name = "include dirs with starstar prefix baseline",
            host = caseSensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"**/x", "**/a/**/b"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/a.ts"))
                assert.is_true(slicesContains(got, "/dev/x/b.ts"))
                assert.is_true(slicesContains(got, "/dev/q/a/c/b/d.ts"))
            end,
        },
        {
            name = "dotted folders not implicitly included baseline",
            host = dottedFoldersHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"x/**/*", "w/*/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/x/d.ts"))
                assert.is_true(slicesContains(got, "/dev/x/y/d.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/.y/a.ts"))
                assert.is_true(not slicesContains(got, "/dev/x/y/.e.ts"))
                assert.is_true(not slicesContains(got, "/dev/w/.u/e.ts"))
            end,
        },
        {
            name = "include paths outside project baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            includes = {"*", "/ext/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/dev/a.ts"))
                assert.is_true(slicesContains(got, "/ext/ext.ts"))
            end,
        },
        {
            name = "include files with double dots baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"**"},
            includes = {"/ext/b/a..b.ts"},
            expect = function(got) assert.is_true(slicesContains(got, "/ext/b/a..b.ts")) end,
        },
        {
            name = "exclude files with double dots baseline",
            host = caseInsensitiveHost,
            extensions = {".ts", ".tsx", ".d.ts"},
            excludes = {"/ext/b/a..b.ts"},
            includes = {"/ext/**/*"},
            expect = function(got)
                assert.is_true(slicesContains(got, "/ext/ext.ts"))
                assert.is_true(not slicesContains(got, "/ext/b/a..b.ts"))
            end,
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            runReadDirectoryCase(tc)
        end)
    end
end)

-- TestSpecMatcher tests the SpecMatcher API
describe("TestSpecMatcher", function()

    local cases = {
        {
            name = "simple wildcard",
            specs = {"*.ts"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            matchingPaths = {"/project/a.ts", "/project/b.ts", "/project/foo.ts"},
            nonMatchingPaths = {"/project/a.js", "/project/sub/a.ts"},
        },
        {
            name = "recursive wildcard",
            specs = {"**/*.ts"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            matchingPaths = {"/project/a.ts", "/project/sub/a.ts", "/project/sub/deep/a.ts"},
            nonMatchingPaths = {"/project/a.js"},
        },
        {
            name = "exclude pattern",
            specs = {"node_modules"},
            basePath = "/project",
            usage = vfsmatch.Usage.Exclude,
            useCaseSensitiveFileNames = true,
            matchingPaths = {"/project/node_modules/foo"},
            nonMatchingPaths = {"/project/node_modules", "/project/src"},
        },
        {
            name = "case insensitive",
            specs = {"*.ts"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = false,
            matchingPaths = {"/project/A.TS", "/project/B.Ts"},
            nonMatchingPaths = {"/project/a.js"},
        },
        {
            name = "multiple specs",
            specs = {"*.ts", "*.tsx"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            matchingPaths = {"/project/a.ts", "/project/b.tsx"},
            nonMatchingPaths = {"/project/a.js"},
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local matcher = vfsmatch.NewSpecMatcher(tc.specs, tc.basePath, tc.usage, tc.useCaseSensitiveFileNames)
            if matcher == nil then
                error("matcher should not be nil")
            end
            for _, path in ipairs(tc.matchingPaths or {}) do
                assert.is_true(matcher:MatchString(path), "should match: %s", path)
            end
            for _, path in ipairs(tc.nonMatchingPaths or {}) do
                assert.is_true(not matcher:MatchString(path), "should not match: %s", path)
            end
        end)
    end
end)

describe("TestSpecMatcher_MatchString", function()

    local cases = {
        {
            name = "simple wildcard files",
            specs = {"*.ts"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            paths = {"/project/a.ts", "/project/sub/a.ts", "/project/a.js"},
            expected = {true, false, false},
        },
        {
            name = "recursive wildcard files",
            specs = {"**/*.ts"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            paths = {"/project/a.ts", "/project/sub/a.ts", "/project/a.js"},
            expected = {true, true, false},
        },
        {
            name = "exclude pattern matches prefix",
            specs = {"node_modules"},
            basePath = "/project",
            usage = vfsmatch.Usage.Exclude,
            useCaseSensitiveFileNames = true,
            paths = {"/project/node_modules", "/project/node_modules/foo", "/project/src"},
            expected = {false, true, false},
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            assert.are.equal(len(tc.paths), len(tc.expected))
            local m = vfsmatch.NewSpecMatcher(tc.specs, tc.basePath, tc.usage, tc.useCaseSensitiveFileNames)
            assert.is_true(m ~= nil)
            for i, path in ipairs(tc.paths) do
                assert.are.equal(m:MatchString(path), tc.expected[i], "path: %s", path)
            end
        end)
    end
end)

describe("TestSingleSpecMatcher_MatchString", function()

    local cases = {
        {
            name = "single spec wildcard",
            spec = "*.ts",
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            paths = {"/project/a.ts", "/project/sub/a.ts", "/project/a.js"},
            expected = {true, false, false},
        },
        {
            name = "single spec trailing starstar exclude allowed",
            spec = "**",
            basePath = "/project",
            usage = vfsmatch.Usage.Exclude,
            useCaseSensitiveFileNames = true,
            paths = {"/project/a.ts", "/project/sub/a.ts"},
            expected = {true, true},
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            assert.are.equal(len(tc.paths), len(tc.expected))
            local m = vfsmatch.NewSpecMatcher({tc.spec}, tc.basePath, tc.usage, tc.useCaseSensitiveFileNames)
            assert.is_true(m ~= nil)
            for i, path in ipairs(tc.paths) do
                assert.are.equal(m:MatchString(path), tc.expected[i], "path: %s", path)
            end
        end)
    end
end)

describe("TestSpecMatchers_MatchIndex", function()

    local cases = {
        {
            name = "index lookup prefers first match",
            specs = {"*.ts", "*.tsx"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            paths = {"/project/a.ts", "/project/a.tsx", "/project/a.js"},
            expected = {0, 1, -1},
        },
        {
            name = "exclude index lookup",
            specs = {"node_modules", "bower_components"},
            basePath = "/project",
            usage = vfsmatch.Usage.Exclude,
            useCaseSensitiveFileNames = true,
            paths = {"/project/node_modules", "/project/node_modules/foo", "/project/bower_components", "/project/bower_components/bar", "/project/src"},
            expected = {-1, 0, -1, 1, -1},
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            assert.are.equal(len(tc.paths), len(tc.expected))
            local m = vfsmatch.NewSpecMatcher(tc.specs, tc.basePath, tc.usage, tc.useCaseSensitiveFileNames)
            assert.is_true(m ~= nil)
            for i, path in ipairs(tc.paths) do
                assert.are.equal(m:MatchIndex(path), tc.expected[i], "path: %s", path)
            end
        end)
    end
end)

describe("TestSingleSpecMatcher", function()

    local cases = {
        {
            name = "simple spec",
            spec = "*.ts",
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            matchingPaths = {"/project/a.ts"},
            nonMatchingPaths = {"/project/a.js"},
        },
        {
            name = "trailing ** non-exclude returns nil",
            spec = "**",
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            expectNil = true,
        },
        {
            name = "trailing ** exclude works",
            spec = "**",
            basePath = "/project",
            usage = vfsmatch.Usage.Exclude,
            useCaseSensitiveFileNames = true,
            matchingPaths = {"/project/anything", "/project/deep/path"},
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local matcher = vfsmatch.NewSpecMatcher({tc.spec}, tc.basePath, tc.usage, tc.useCaseSensitiveFileNames)
            if tc.expectNil then
                assert.is_true(matcher == nil, "should be nil")
                return
            end
            if matcher == nil then
                error("matcher should not be nil")
            end
            for _, path in ipairs(tc.matchingPaths or {}) do
                assert.is_true(matcher:MatchString(path), "should match: %s", path)
            end
            for _, path in ipairs(tc.nonMatchingPaths or {}) do
                assert.is_true(not matcher:MatchString(path), "should not match: %s", path)
            end
        end)
    end
end)

describe("TestSpecMatchers", function()

    local cases = {
        {
            name = "multiple specs return correct index",
            specs = {"*.ts", "*.tsx", "*.js"},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            pathToIndex = {
                ["/project/a.ts"] = 0,
                ["/project/b.tsx"] = 1,
                ["/project/c.js"] = 2,
                ["/project/d.css"] = -1, -- no match
            },
        },
        {
            name = "empty specs returns nil",
            specs = {},
            basePath = "/project",
            usage = vfsmatch.Usage.Files,
            useCaseSensitiveFileNames = true,
            expectNil = true,
        },
    }

    for _, tc in ipairs(cases) do
        it(tc.name, function()
            local matchers = vfsmatch.NewSpecMatcher(tc.specs, tc.basePath, tc.usage, tc.useCaseSensitiveFileNames)
            if tc.expectNil then
                assert.is_true(matchers == nil, "should be nil")
                return
            end
            if matchers == nil then
                error("matchers should not be nil")
            end
            for path, expectedIndex in pairs(tc.pathToIndex) do
                local gotIndex = matchers:MatchIndex(path)
                assert.are.equal(gotIndex, expectedIndex, "path: %s", path)
            end
        end)
    end
end)

-- TestGlobPatternInternals tests internal glob pattern matching logic
-- to ensure edge cases are covered that may not be hit by ReadDirectory tests
describe("TestGlobPatternInternals", function()

    it("nextPathPart handles consecutive slashes", function()
        -- Test path with consecutive slashes
        local path = "/dev//foo///bar"

        -- First call - returns empty for root
        local part, offset, ok = vfsmatch.nextPathPartParts(path, "", 0)
        assert.is_true(ok)
        assert.are.equal(part, "")
        assert.are.equal(offset, 1)

        -- Second call - should skip consecutive slashes after /dev
        part, offset, ok = vfsmatch.nextPathPartParts(path, "", 1)
        assert.is_true(ok)
        assert.are.equal(part, "dev")

        -- Third call - should skip the double slashes before foo
        part, offset, ok = vfsmatch.nextPathPartParts(path, "", offset)
        assert.is_true(ok)
        assert.are.equal(part, "foo")

        -- Fourth call - should skip the triple slashes before bar
        local _
        part, _, ok = vfsmatch.nextPathPartParts(path, "", offset)
        assert.is_true(ok)
        assert.are.equal(part, "bar")
    end)

    it("nextPathPart handles path ending with slashes", function()
        local path = "/dev/"

        -- Skip to after "dev"
        local _, offset, ok = vfsmatch.nextPathPartParts(path, "", 0) -- root
        assert.is_true(ok)
        _, offset, ok = vfsmatch.nextPathPartParts(path, "", offset) -- dev
        assert.is_true(ok)
        -- Now at trailing slash, should return not ok
        _, _, ok = vfsmatch.nextPathPartParts(path, "", offset)
        assert.is_true(not ok)
    end)

    it("nextPathPartParts handles empty prefix", function()
        local path = "/dev//foo"

        local part, offset, ok = vfsmatch.nextPathPartParts("", path, 0)
        assert.is_true(ok)
        assert.are.equal(part, "")
        assert.are.equal(offset, 1)

        part, offset, ok = vfsmatch.nextPathPartParts("", path, offset)
        assert.is_true(ok)
        assert.are.equal(part, "dev")

        local _
        part, _, ok = vfsmatch.nextPathPartParts("", path, offset)
        assert.is_true(ok)
        assert.are.equal(part, "foo")
    end)

    it("nextPathPartParts returns not ok when only slashes remain", function()
        local prefix = "/dev/"
        local suffix = "foo"

        local _, offset, ok = vfsmatch.nextPathPartParts(prefix, suffix, 0) -- root
        assert.is_true(ok)

        local part
        part, offset, ok = vfsmatch.nextPathPartParts(prefix, suffix, offset) -- dev
        assert.is_true(ok)
        assert.are.equal(part, "dev")

        part, offset, ok = vfsmatch.nextPathPartParts(prefix, suffix, offset) -- foo
        assert.is_true(ok)
        assert.are.equal(part, "foo")
        assert.are.equal(offset, #prefix+#suffix)

        _, _, ok = vfsmatch.nextPathPartParts(prefix, suffix, offset)
        assert.is_true(not ok)
    end)

    it("nextPathPartParts parses from suffix region", function()
        local prefix = "/"
        local suffix = "a"

        local part, offset, ok = vfsmatch.nextPathPartParts(prefix, suffix, 0) -- root
        assert.is_true(ok)
        assert.are.equal(part, "")
        assert.are.equal(offset, 1)

        local _
        part, _, ok = vfsmatch.nextPathPartParts(prefix, suffix, offset)
        assert.is_true(ok)
        assert.are.equal(part, "a")
    end)

    it("question mark segment at end of string", function()
        -- Create pattern with question mark that should fail when string is exhausted
        local p, ok = vfsmatch.compileGlobPattern("a?", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        -- Should match "ab"
        assert.is_true(p:matches("/ab"))

        -- Should NOT match "a" (question mark requires a character)
        assert.is_true(not p:matches("/a"))
    end)

    it("star segment with complex pattern", function()
        -- Pattern like "a*b*c" requires backtracking in star matching
        local p, ok = vfsmatch.compileGlobPattern("a*b*c", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        -- Should match "abc"
        assert.is_true(p:matches("/abc"))

        -- Should match "aXbYc"
        assert.is_true(p:matches("/aXbYc"))

        -- Should match "aXXXbYYYc"
        assert.is_true(p:matches("/aXXXbYYYc"))

        -- Should NOT match "aXbY" (no trailing c)
        assert.is_true(not p:matches("/aXbY"))
    end)

    it("ensureTrailingSlash with existing slash", function()
        -- Test that ensureTrailingSlash doesn't double-add slashes
        local result = vfsmatch.ensureTrailingSlash("/dev/")
        assert.are.equal(result, "/dev/")

        result = vfsmatch.ensureTrailingSlash("/")
        assert.are.equal(result, "/")
    end)

    it("ensureTrailingSlash with empty string", function()
        local result = vfsmatch.ensureTrailingSlash("")
        assert.are.equal(result, "")
    end)

    it("literal component with package folder in include", function()
        -- When a literal include path goes through a package folder,
        -- the skipPackageFolders flag on literal components should not block it
        -- because literal components in includes don't have skipPackageFolders=true
        local host = vfstest.FromMap({
            ["/dev/node_modules/pkg/index.ts"] = "",
        }, false)

        -- Explicit literal path should work
        local got = vfsmatch.matchFiles("/dev", {".ts"}, nil,
            {"node_modules/pkg/index.ts"}, false, "/", vfsmatch.UnlimitedDepth, host)
        assert.is_true(slicesContains(got, "/dev/node_modules/pkg/index.ts"))
    end)
end)

-- TestMatchSegmentsEdgeCases tests edge cases in the matchSegments function
describe("TestMatchSegmentsEdgeCases", function()

    it("question mark before slash in string", function()
        -- This tests the case where question mark encounters a slash character
        -- which should fail since ? doesn't match /
        local p, ok = vfsmatch.compileGlobPattern("a?b", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        -- "a/b" should not match "a?b" pattern since ? shouldn't match /
        -- But this is a single component pattern, so / wouldn't be in the component
        -- We need to test this within the segment matching

        -- Create a pattern that will exercise question mark matching edge cases
        assert.is_true(p:matches("/aXb")) -- X matches ?
        assert.is_true(not p:matches("/ab")) -- nothing to match ?
        assert.is_true(not p:matches("/aXYb")) -- XY is too many chars for ?
    end)

    it("star with no trailing content", function()
        -- Test that star can match to end of string
        local p, ok = vfsmatch.compileGlobPattern("a*", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(p:matches("/a"))
        assert.is_true(p:matches("/abc"))
        assert.is_true(p:matches("/aXYZ"))
    end)

    it("multiple stars in pattern", function()
        -- Test patterns with multiple stars that require backtracking
        local p, ok = vfsmatch.compileGlobPattern("*a*", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(p:matches("/a"))
        assert.is_true(p:matches("/Xa"))
        assert.is_true(p:matches("/aX"))
        assert.is_true(p:matches("/XaY"))
        assert.is_true(not p:matches("/XYZ")) -- no 'a'
    end)

    it("multiple stars requiring backtracking", function()
        -- These patterns require proper backtracking to match correctly.
        -- A naive greedy algorithm would fail on these.

        -- Pattern: *a*a - must find two 'a' characters
        local p1, ok = vfsmatch.compileGlobPattern("*a*a", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)
        assert.is_true(p1:matches("/aa")) -- minimal: first * matches "", second * matches ""
        assert.is_true(p1:matches("/Xaa")) -- first * matches "X"
        assert.is_true(p1:matches("/aXa")) -- second * matches "X"
        assert.is_true(p1:matches("/XaYa")) -- both * match chars
        assert.is_true(p1:matches("/aaaa")) -- multiple a's
        assert.is_true(not p1:matches("/a")) -- only one 'a'
        assert.is_true(not p1:matches("/Xa")) -- only one 'a'
        assert.is_true(not p1:matches("/aX")) -- only one 'a', doesn't end with 'a'
        assert.is_true(not p1:matches("/XaYaZ")) -- doesn't end with 'a'

        -- Pattern: *a*b*c - must find a, then b, then c in order
        local p2
        p2, ok = vfsmatch.compileGlobPattern("*a*b*c", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)
        assert.is_true(p2:matches("/abc")) -- minimal
        assert.is_true(p2:matches("/XaYbZc")) -- chars between
        assert.is_true(p2:matches("/aXbYc")) -- chars between
        assert.is_true(p2:matches("/aaabbbccc")) -- repeated chars
        assert.is_true(not p2:matches("/ab")) -- missing c
        assert.is_true(not p2:matches("/ac")) -- missing b
        assert.is_true(not p2:matches("/cba")) -- wrong order
        assert.is_true(not p2:matches("/abcX")) -- doesn't end with c

        -- Pattern: *a*a*a - must find three 'a' characters
        local p3
        p3, ok = vfsmatch.compileGlobPattern("*a*a*a", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)
        assert.is_true(p3:matches("/aaa"))
        assert.is_true(p3:matches("/aXaYa"))
        assert.is_true(p3:matches("/XaYaZa"))
        assert.is_true(not p3:matches("/aa")) -- only two 'a's
        assert.is_true(not p3:matches("/aaX")) -- doesn't end with 'a'

        -- Pattern: a*b*a - starts with a, ends with a, has b in middle
        local p4
        p4, ok = vfsmatch.compileGlobPattern("a*b*a", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)
        assert.is_true(p4:matches("/aba"))
        assert.is_true(p4:matches("/aXbYa"))
        assert.is_true(p4:matches("/abba")) -- b appears, ends with a
        assert.is_true(not p4:matches("/ab")) -- doesn't end with a
        assert.is_true(not p4:matches("/aba ")) -- trailing space
        assert.is_true(not p4:matches("/Xaba")) -- doesn't start with a (hidden file rule may affect)
    end)

    it("pathological pattern performance", function()
        -- This pattern could cause exponential backtracking in naive implementations.
        -- Pattern: *a*a*a*a*b against "aaaaaaaaaaaaaaaa" (no b)
        -- Should return false quickly, not hang.
        local p, ok = vfsmatch.compileGlobPattern("*a*a*a*a*b", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        -- These should complete quickly (not hang)
        assert.is_true(not p:matches("/aaaaaaaaaaaaaaaa")) -- no 'b' at end
        assert.is_true(not p:matches("/aaaaaaaaaaaaaaaaX")) -- ends with X not b
        assert.is_true(p:matches("/aaaab")) -- minimal match
        assert.is_true(p:matches("/XaYaZaWab")) -- complex match
    end)

    it("literal segment not matching", function()
        -- Test literal segment that's longer than remaining string
        local p, ok = vfsmatch.compileGlobPattern("abcdefgh.ts", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(not p:matches("/abc.ts")) -- different literal
        assert.is_true(p:matches("/abcdefgh.ts")) -- exact match
    end)

    it("question mark matches multi-byte unicode rune", function()
        -- ? should match one full Unicode codepoint, not one byte.
        -- 'é' is 2 bytes in UTF-8, '🎉' is 4 bytes, '中' is 3 bytes.

        local p1, ok = vfsmatch.compileGlobPattern("?.ts", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(p1:matches("/a.ts")) -- single ASCII char
        assert.is_true(p1:matches("/é.ts")) -- 2-byte rune
        assert.is_true(p1:matches("/中.ts")) -- 3-byte rune
        assert.is_true(p1:matches("/🎉.ts")) -- 4-byte rune (surrogate pair in UTF-16)
        assert.is_true(not p1:matches("/.ts")) -- empty - no char for ? to match
        assert.is_true(not p1:matches("/ab.ts")) -- two chars

        -- Two question marks should match exactly two runes
        local p2
        p2, ok = vfsmatch.compileGlobPattern("??.ts", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(p2:matches("/ab.ts")) -- two ASCII chars
        assert.is_true(p2:matches("/é中.ts")) -- two multi-byte runes
        assert.is_true(p2:matches("/🎉é.ts")) -- 4-byte + 2-byte runes
        assert.is_true(not p2:matches("/a.ts")) -- only one char
        assert.is_true(not p2:matches("/abc.ts")) -- three chars
    end)

    it("star matches multi-byte unicode runes correctly", function()
        -- * should advance by full runes during backtracking.

        -- Pattern: *é.ts - anything ending in é.ts
        local p, ok = vfsmatch.compileGlobPattern("*é.ts", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(p:matches("/é.ts"))
        assert.is_true(p:matches("/café.ts"))
        assert.is_true(not p:matches("/cafe.ts")) -- 'e' != 'é'

        -- Pattern: *🎉* - contains 🎉 somewhere
        local p2
        p2, ok = vfsmatch.compileGlobPattern("*🎉*", "/", vfsmatch.Usage.Files, true)
        assert.is_true(ok)

        assert.is_true(p2:matches("/🎉"))
        assert.is_true(p2:matches("/a🎉b"))
        assert.is_true(not p2:matches("/abc"))
    end)
end)

-- TestReadDirectoryConsecutiveSlashes tests handling of paths with consecutive slashes
describe("TestReadDirectoryConsecutiveSlashes", function()
    it("TestReadDirectoryConsecutiveSlashes", function()
    local host = vfstest.FromMap({
        ["/dev/a.ts"] = "",
        ["/dev/x/b.ts"] = "",
    }, false)

    -- The matchFilesNoRegex function normalizes paths, but we can test internal handling
    local got = vfsmatch.matchFiles("/dev", {".ts"}, nil, {"**/*.ts"}, false, "/", vfsmatch.UnlimitedDepth, host)
    assert.is_true(len(got) >= 2, "should find files")
    assert.is_true(slicesContains(got, "/dev/a.ts"))
    assert.is_true(slicesContains(got, "/dev/x/b.ts"))
    end)
end)

-- TestGlobPatternLiteralWithPackageFolders tests literal component behavior with package folders
describe("TestGlobPatternLiteralWithPackageFolders", function()

    it("wildcard skips package folders", function()
        -- Wildcard patterns should skip node_modules
        local host = vfstest.FromMap({
            ["/dev/a.ts"] = "",
            ["/dev/node_modules/b.ts"] = "",
        }, false)

        local got = vfsmatch.matchFiles("/dev", {".ts"}, nil, {"*/*.ts"}, false, "/", vfsmatch.UnlimitedDepth, host)
        assert.is_true(not slicesContains(got, "/dev/node_modules/b.ts"), "should skip node_modules with wildcard")
    end)

    it("explicit literal includes package folder", function()
        -- Explicit literal paths should include package folders
        local host = vfstest.FromMap({
            ["/dev/node_modules/b.ts"] = "",
        }, false)

        local got = vfsmatch.matchFiles("/dev", {".ts"}, nil, {"node_modules/b.ts"}, false, "/", vfsmatch.UnlimitedDepth, host)
        assert.is_true(slicesContains(got, "/dev/node_modules/b.ts"), "should include explicit node_modules path")
    end)
end)

-- TestGetBasePathsCaseSensitivity verifies that getBasePaths uses the correct
-- case-sensitivity when deduplicating base paths. On a case-sensitive file system,
-- paths that differ only by case (e.g., "/Dev/src" and "/dev/src") are distinct
-- and should not be deduplicated.
describe("TestGetBasePathsCaseSensitivity", function()

    it("case-sensitive does not dedup differently-cased paths", function()
        -- On a case-sensitive file system, /root/src/Dev and /root/src/dev are distinct directories.
        -- When they're both included as base paths, they should not be deduplicated.
        -- Use include patterns that point to directories outside the root path so the root
        -- path doesn't subsume them via containsPath.
        local basePaths = vfsmatch.getBasePaths("/root", {"../Other/**/*.ts", "../other/**/*.ts"}, true --[[caseSensitive]])
        -- Both /Other and /other should appear because they differ by case on a case-sensitive FS.
        assert.is_true(slicesContains(basePaths, "/Other"), "expected /Other in base paths: %v", basePaths)
        assert.is_true(slicesContains(basePaths, "/other"), "expected /other in base paths: %v", basePaths)
    end)

    it("case-insensitive dedups differently-cased paths", function()
        -- On a case-insensitive file system, /Other and /other refer to the same directory;
        -- only one should appear.
        local basePaths = vfsmatch.getBasePaths("/root", {"../Other/**/*.ts", "../other/**/*.ts"}, false --[[caseSensitive]])
        local count = 0
        for _, bp in ipairs(basePaths or {}) do
            if bp == "/Other" or bp == "/other" then
                count = count + 1
            end
        end
        assert.is_true(count <= 1, "expected at most one of /Other or /other in base paths: %v", basePaths)
    end)
end)
