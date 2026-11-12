-- Port of internal/tspath/startsWithDirectory_test.go: TestStartsWithDirectoryEdgeCases
-- (TestStartsWithDirectory is in spec/tspath_spec.lua).
local tspath = require("tslua.tspath")

describe("TestStartsWithDirectoryEdgeCases", function()
    local tests = {
        {
            name = "file name shorter than directory",
            fileName = "/proj",
            directoryName = "/project",
            useCaseSensitiveFileNames = true,
            expected = false,
        },
        {
            name = "file name starts with directory but no separator",
            fileName = "/projectsrc/file.ts",
            directoryName = "/project",
            useCaseSensitiveFileNames = true,
            expected = false,
        },
        {
            name = "relative paths",
            fileName = "src/file.ts",
            directoryName = "src",
            useCaseSensitiveFileNames = true,
            expected = true,
        },
        {
            name = "absolute vs relative",
            fileName = "/project/src/file.ts",
            directoryName = "project/src",
            useCaseSensitiveFileNames = true,
            expected = false,
        },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            assert.are.equal(tt.expected,
                tspath.StartsWithDirectory(tt.fileName, tt.directoryName, tt.useCaseSensitiveFileNames))
        end)
    end
end)
