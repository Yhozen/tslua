-- Port of internal/tsoptions/wildcarddirectories_test.go.
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

describe("TestGetWildcardDirectories_DotPrefixedIncludeWithDotDirExclude", function()
    it("TestGetWildcardDirectories_DotPrefixedIncludeWithDotDirExclude", function()
        -- https://github.com/microsoft/typescript-go/issues/3733
        -- "./"-prefixed include specs must be fully normalized before being tested
        -- against exclude patterns; otherwise the leftover literal "." path segment
        -- matches dot-directory excludes like "**/.*/", silently dropping every
        -- wildcard directory (and with them, root file watching for the config).
        local result = tsoptions.getWildcardDirectories(
            { "./app/**/*.ts", "./app/**/*.tsx" },
            { "**/node_modules", "**/.*/", "./build" },
            tspath.NewComparePathsOptions(true, "/home/projects/monorepo/apps/web")
        )
        assert.are.same({ ["/home/projects/monorepo/apps/web/app"] = true }, result)
    end)
end)

describe("TestGetWildcardDirectories_NonASCIICharacters", function()
    local tests = {
        {
            name = "Norwegian character æ in path",
            include = { "src/**/*.test.ts", "src/**/*.stories.ts", "src/**/*.mdx" },
            exclude = { "node_modules" },
            currentDirectory = "C:/Users/TobiasLægreid/dev/app/frontend/packages/react",
            useCaseSensitiveFileNames = false,
        },
        {
            name = "Japanese characters in path",
            include = { "src/**/*.ts" },
            exclude = { "テスト" },
            currentDirectory = "/Users/ユーザー/プロジェクト",
            useCaseSensitiveFileNames = true,
        },
        {
            name = "Chinese characters in path",
            include = { "源代码/**/*.js" },
            exclude = { "节点模块" },
            currentDirectory = "/home/用户/项目",
            useCaseSensitiveFileNames = true,
        },
        {
            name = "Various Unicode characters",
            include = { "src/**/*.ts" },
            exclude = { "node_modules" },
            currentDirectory = "/Users/Müller/café/naïve/résumé",
            useCaseSensitiveFileNames = false,
        },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            local comparePathsOptions = tspath.NewComparePathsOptions(tt.useCaseSensitiveFileNames, tt.currentDirectory)

            local result = tsoptions.getWildcardDirectories(tt.include, tt.exclude, comparePathsOptions)

            assert.is_true(result ~= nil, "expected non-nil result")
        end)
    end
end)
