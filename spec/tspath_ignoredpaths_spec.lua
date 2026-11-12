-- Port of internal/tspath/ignoredpaths_test.go.
local tspath = require("tslua.tspath")

describe("TestContainsIgnoredPath", function()
    local tests = {
        { name = "node_modules dot path", path = "/project/node_modules/.pnpm/file.ts", expected = true },
        { name = "git directory", path = "/project/.git/hooks/pre-commit", expected = true },
        { name = "emacs lock file", path = "/project/src/file.ts.#", expected = true },
        { name = "regular file path", path = "/project/src/file.ts", expected = false },
        { name = "node_modules without dot", path = "/project/node_modules/lodash/index.js", expected = false },
        { name = "empty path", path = "", expected = false },
        { name = "path with multiple ignored patterns", path = "/project/node_modules/.pnpm/.git/.#file.ts", expected = true },
        { name = "case sensitive test", path = "/project/NODE_MODULES/.PNPM/file.ts", expected = false }, -- Should be case sensitive
        { name = "path with ignored pattern in middle", path = "/project/src/node_modules/.pnpm/dist/file.js", expected = true },
        { name = "path with ignored pattern at end", path = "/project/src/file.ts.#", expected = true },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            assert.are.equal(tt.expected, tspath.ContainsIgnoredPath(tt.path))
        end)
    end
end)

describe("TestIgnoredPathsPatterns", function()
    it("TestIgnoredPathsPatterns", function()
        -- Test that all expected patterns are present
        local expectedPatterns = { "/node_modules/.", "/.git", ".#" }

        for _, pattern in ipairs(expectedPatterns) do
            local testPath = "/test" .. pattern .. "/file.ts"
            assert.is_true(tspath.ContainsIgnoredPath(testPath),
                "Expected pattern '" .. pattern .. "' to be detected in path '" .. testPath .. "'")
        end
    end)
end)

describe("TestIgnoredPathsEdgeCases", function()
    local tests = {
        { name = "pattern at start", path = "/node_modules./file.ts", expected = false }, -- Pattern is "/node_modules/." not "/node_modules."
        { name = "pattern at end", path = "/project/file.ts.#", expected = true },
        { name = "multiple occurrences", path = "/project/.git/node_modules./.git/file.ts", expected = true },
        { name = "no slashes", path = "node_modules.file.ts", expected = false },
        { name = "single slash", path = "/file.ts", expected = false },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            assert.are.equal(tt.expected, tspath.ContainsIgnoredPath(tt.path))
        end)
    end
end)
