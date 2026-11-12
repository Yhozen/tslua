-- Port of internal/checker/checker_test.go (BenchmarkNewChecker skipped)
local bundled = require("tslua.bundled")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local tsoptions = require("tslua.tsoptions")
local vfstest = require("tslua.vfs.vfstest")

describe("TestGetSymbolAtLocation", function()
    it("TestGetSymbolAtLocation", function()
        local content = [[
interface Foo {
  bar: string;
}
declare const foo: Foo;
foo.bar;]]
        local fs = vfstest.FromMap({
            ["/foo.ts"] = content,
            ["/tsconfig.json"] = [[

				{
					"compilerOptions": {},
					"files": ["foo.ts"]
				}
			]],
        }, false --[[useCaseSensitiveFileNames]])
        fs = bundled.WrapFS(fs)

        local cd = "/"
        local host = compiler.NewCompilerHost(cd, fs, bundled.LibPath(), nil, nil, nil)

        local parsed, errors = tsoptions.GetParsedCommandLineOfConfigFile("/tsconfig.json", core.NewCompilerOptions({}), nil, host, nil)
        assert.are.equal(0, #(errors or {}), "Expected no errors in parsed command line")

        local p = compiler.NewProgram(compiler.NewProgramOptions({
            config = parsed,
            host = host,
        }))
        p:BindSourceFiles()
        local c, done = p:GetTypeChecker(nil)
        local ok, err = pcall(function()
            local file = p:GetSourceFile("/foo.ts")
            local interfaceId = file.statements.nodes[1]:Name()
            local varId = file.statements.nodes[2]:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes[1]:Name()
            local propAccess = file.statements.nodes[3]:Expression()
            local nodes = { interfaceId, varId, propAccess }
            for _, node in ipairs(nodes) do
                local symbol = c:GetSymbolAtLocation(node)
                assert.is_not_nil(symbol, "Expected symbol to be non-nil")
            end
        end)
        done()
        if not ok then
            error(err, 0)
        end
    end)
end)
