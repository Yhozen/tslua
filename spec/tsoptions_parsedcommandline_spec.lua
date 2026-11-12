-- Port of internal/tsoptions/parsedcommandline_test.go.
local core = require("tslua.core")
local tsoptions = require("tslua.tsoptions")
local tsoptionstest = require("tslua.tsoptions.tsoptionstest")
local vfstest = require("tslua.vfs.vfstest")

describe("TestParsedCommandLine", function()
    describe("PossiblyMatchesFileName", function()
        local noFiles = {}
        local noFilesFS = vfstest.FromMap(noFiles, true)

        local files = {
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
        }

        local function contains(xs, x)
            for _, v in ipairs(xs) do
                if v == x then
                    return true
                end
            end
            return false
        end

        local function assertMatches(parsedCommandLine, files_, matches)
            for fileName in pairs(files_) do
                local actual = parsedCommandLine:PossiblyMatchesFileName(fileName)
                local expected = contains(matches, fileName)
                assert.are.equal(expected, actual, "fileName: " .. fileName)
            end
            for _, fileName in ipairs(matches) do
                if files_[fileName] == nil then
                    local actual = parsedCommandLine:PossiblyMatchesFileName(fileName)
                    assert.are.equal(true, actual, "fileName: " .. fileName)
                end
            end
        end

        describe("with literal file list", function()
            it("without exclude", function()
                local parsedCommandLine = tsoptionstest.GetParsedCommandLine(
                    nil,
                    [[{
						"files": [
							"a.ts",
							"b.ts"
						]
					}]],
                    files,
                    "/dev",
                    true --[[useCaseSensitiveFileNames]]
                )

                assertMatches(parsedCommandLine, files, {
                    "/dev/a.ts",
                    "/dev/b.ts",
                })
            end)

            it("are not removed due to excludes", function()
                local parsedCommandLine = tsoptionstest.GetParsedCommandLine(
                    nil,
                    [[{
						"files": [
							"a.ts",
							"b.ts"
						],
						"exclude": [
							"b.ts"
						]
					}]],
                    files,
                    "/dev",
                    true --[[useCaseSensitiveFileNames]]
                )

                assertMatches(parsedCommandLine, files, {
                    "/dev/a.ts",
                    "/dev/b.ts",
                })

                local emptyParsedCommandLine = parsedCommandLine:ReloadFileNamesOfParsedCommandLine(noFilesFS)
                assertMatches(emptyParsedCommandLine, noFiles, {
                    "/dev/a.ts",
                    "/dev/b.ts",
                })
            end)

            it("duplicates", function()
                local parsedCommandLine = tsoptionstest.GetParsedCommandLine(
                    nil,
                    [[{
						"files": [
							"a.ts",
							"a.ts",
							"b.ts",
						]
					}]],
                    files,
                    "/dev",
                    true --[[useCaseSensitiveFileNames]]
                )

                assert.are.same({
                    "/dev/a.ts",
                    "/dev/b.ts",
                }, parsedCommandLine:LiteralFileNames())
            end)
        end)

        describe("with literal include list", function()
            it("without exclude", function()
                local parsedCommandLine = tsoptionstest.GetParsedCommandLine(
                    nil,
                    [[{
						"include": [
							"a.ts",
							"b.ts"
						]
					}]],
                    files,
                    "/dev",
                    true --[[useCaseSensitiveFileNames]]
                )

                assertMatches(parsedCommandLine, files, {
                    "/dev/a.ts",
                    "/dev/b.ts",
                })

                local emptyParsedCommandLine = parsedCommandLine:ReloadFileNamesOfParsedCommandLine(noFilesFS)
                assertMatches(emptyParsedCommandLine, noFiles, {
                    "/dev/a.ts",
                    "/dev/b.ts",
                })
            end)
        end)

        it("PossiblyMatchesFileName with content mapper extensions", function()
            local host = tsoptionstest.NewVFSParseConfigHost({
                ["/dev/node_modules/mapper/package.json"] = [[{ "name": "mapper", "version": "1.0.0", "typescript": { "contentMapper": { "exec": ["mapper"] } } }]],
            }, "/dev", true)
            local configFileName = "/dev/tsconfig.json"
            local jsonText = [[{
			"include": ["src"],
			"contentMappers": [ { "package": "mapper", "extensions": [".box"] } ]
		}]]
            local tsconfigSourceFile = tsoptions.NewTsconfigSourceFileFromFilePath(configFileName, "/dev/tsconfig.json", jsonText)
            local parsedCommandLine = tsoptions.ParseJsonSourceFileConfigFileContent(
                tsconfigSourceFile,
                host,
                "/dev",
                core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
                nil,
                configFileName,
                nil,
                nil
            )

            -- A created content-mapped file under an included directory must be recognized as a
            -- possible root file, or the config's root files are never reloaded for it.
            assert.is_true(parsedCommandLine:PossiblyMatchesFileName("/dev/src/new.box"))
            assert.is_true(parsedCommandLine:PossiblyMatchesFileName("/dev/src/new.ts"))
            assert.is_true(not parsedCommandLine:PossiblyMatchesFileName("/dev/src/new.vue"))
            assert.is_true(not parsedCommandLine:PossiblyMatchesFileName("/dev/other/new.box"))

            local insensitiveHost = tsoptionstest.NewVFSParseConfigHost({
                ["/dev/node_modules/mapper/package.json"] = [[{ "name": "mapper", "version": "1.0.0", "typescript": { "contentMapper": { "exec": ["mapper"] } } }]],
            }, "/dev", false)
            local insensitiveCommandLine = tsoptions.ParseJsonSourceFileConfigFileContent(
                tsconfigSourceFile,
                insensitiveHost,
                "/dev",
                core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
                nil,
                configFileName,
                nil,
                nil
            )
            assert.is_true(insensitiveCommandLine:PossiblyMatchesFileName("/dev/src/new.BOX"))
        end)

        it("WithFileNames preserves config identity", function()
            local configFileName = "/dev/tsconfig.json"
            local tsconfigSourceFile = tsoptions.NewTsconfigSourceFileFromFilePath(configFileName, configFileName, "{}")
            local parsedCommandLine = tsoptions.ParseJsonSourceFileConfigFileContent(
                tsconfigSourceFile,
                tsoptionstest.NewVFSParseConfigHost({}, "/dev", true),
                "/dev",
                nil,
                nil,
                configFileName,
                nil,
                nil
            )

            local withTypings = parsedCommandLine:WithFileNames({ "/dev/index.ts", "/cache/@types/pkg/index.d.ts" })
            assert.are.equal(configFileName, withTypings:ConfigName())
            assert.are.same({ "/dev/index.ts", "/cache/@types/pkg/index.d.ts" }, withTypings:FileNames())
        end)
    end)
end)
