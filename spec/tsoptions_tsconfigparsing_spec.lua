-- Port of internal/tsoptions/tsconfigparsing_test.go.
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local diagnosticwriter = require("tslua.diagnosticwriter")
local json = require("tslua.json")
local locale = require("tslua.locale")
local parser = require("tslua.parser")
local repo = require("tslua.repo")
local scanner = require("tslua.scanner")
local baseline = require("tslua.testutil.baseline")
local testutil = require("tslua.testutil")
local tsoptions = require("tslua.tsoptions")
local tsoptionstest = require("tslua.tsoptions.tsoptionstest")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")
local osvfs = require("tslua.vfs.osvfs")

local iofs = vfs.iofs

-- runT runs fn(t) with a Go-style testing.T and fails the busted test if t failed.
local function runT(fn)
    local t = testutil.NewT("test", nil)
    testutil.runProtected(t, fn)
    if t.failed then
        error(table.concat(t.messages, "\n"), 0)
    end
end

local function copyMap(m)
    local result = {}
    for k, v in pairs(m) do
        result[k] = v
    end
    return result
end

local function contains(xs, x)
    for _, v in ipairs(xs or {}) do
        if v == x then
            return true
        end
    end
    return false
end

local function writeJsonReadableText(output, input)
    local s, err = json.MarshalIndent(input, "", "  ")
    if err ~= nil then
        return err
    end
    output:WriteString(s)
    return nil
end

local function printFS(output, files, root)
    return files:WalkDir(root, function(path, d, err)
        if err ~= nil then
            return err
        end
        if iofs.FileMode_IsRegular(d:Type()) then
            local content, ok = files:ReadFile(path)
            if not ok then
                return "failed to read file " .. path
            end
            output:WriteString("//// [" .. path .. "]\r\n" .. content .. "\r\n\r\n")
        end
        return nil
    end)
end

-- testConfig: { jsonText, configFileName, basePath, allFileList, existingOptions }

local parseConfigFileTextToJsonTests = {
    {
        title = "returns empty config for file with only whitespaces",
        input = {
            "",
            " ",
        },
    },
    {
        title = "returns empty config for file with comments only",
        input = {
            "// Comment",
            "/* Comment*/",
        },
    },
    {
        title = "returns empty config when config is empty object",
        input = {
            [[{}]],
        },
    },
    {
        title = "returns config object without comments",
        input = {
            [[{ // Excluded files
            "exclude": [
                // Exclude d.ts
                "file.d.ts"
            ]
        }]],
            [[{
            /* Excluded
                    Files
            */
            "exclude": [
                /* multiline comments can be in the middle of a line */"file.d.ts"
            ]
        }]],
        },
    },
    {
        title = "keeps string content untouched",
        input = {
            [[{
            "exclude": [
                "xx//file.d.ts"
            ]
        }]],
            [[{
            "exclude": [
                "xx/*file.d.ts*/"
            ]
        }]],
        },
    },
    {
        title = "handles escaped characters in strings correctly",
        input = {
            [[{
            "exclude": [
                "xx\"//files"
            ]
        }]],
            [[{
            "exclude": [
                "xx\\" // end of line comment
            ]
        }]],
        },
    },
    {
        title = "returns object when users correctly specify library",
        input = {
            [[{
            "compilerOptions": {
                "lib": ["es5"]
            }
        }]],
            [[{
            "compilerOptions": {
                "lib": ["es5", "es6"]
            }
        }]],
        },
    },
}

-- luacheck: push ignore 621
local tsconfigWithExtends = [[{
  "files": ["/src/index.ts", "/src/app.ts"],
  "include": ["/src/**/*"],
  "exclude": [],
  "ts-node": {
    "compilerOptions": {
      "module": "commonjs"
    },
    "transpileOnly": true
  }
}]]

local tsconfigWithoutConfigDir = [[{
  "compilerOptions": {
    "outDir": "bin"
  }
}]]

local tsconfigWithConfigDir = [[{
  "compilerOptions": {
    "outDir": "${configDir}/bin"
  }
}]]

local tsconfigWithExtendsAndConfigDir = [[{
  "compilerOptions": {
    "outFile": "${configDir}/outFile",
    "outDir": "${configDir}/outDir",
    "rootDir": "${configDir}/rootDir",
    "tsBuildInfoFile": "${configDir}/tsBuildInfoFile",
    "baseUrl": "${configDir}/baseUrl",
    "declarationDir": "${configDir}/declarationDir",
  }
}]]

local parseJsonConfigFileTests = {
    {
        title = "ignore dotted files and folders",
        input = {{
            jsonText =       [[{}]],
            configFileName = "tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/test.ts"] = "", ["/apath/.git/a.ts"] = "", ["/apath/.b.ts"] = "", ["/apath/..c.ts"] = ""},
        }},
    },
    {
        title = "allow dotted files and folders when explicitly requested",
        input = {{
            jsonText = [[{
                    "files": ["/apath/.git/a.ts", "/apath/.b.ts", "/apath/..c.ts"]
                }]],
            configFileName = "tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/test.ts"] = "", ["/apath/.git/a.ts"] = "", ["/apath/.b.ts"] = "", ["/apath/..c.ts"] = ""},
        }},
    },
    {
        title = "implicitly exclude common package folders",
        input = {{
            jsonText =       [[{}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/node_modules/a.ts"] = "", ["/bower_components/b.ts"] = "", ["/jspm_packages/c.ts"] = "", ["/d.ts"] = "", ["/folder/e.ts"] = ""},
        }},
    },
    {
        title = "generates errors for empty files list",
        input = {{
            jsonText = [[{
                "files": []
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "generates errors for empty files list when no references are provided",
        input = {{
            jsonText = [[{
                "files": [],
                "references": []
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "generates errors for directory with no .ts files",
        input = {{
            jsonText = [[{
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.js"] = ""},
        }},
    },
    {
        title = "generates errors for empty include",
        input = {{
            jsonText = [[{
                "include": []
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "tests/cases/unittests",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "generates errors for include with parent directory after recursive wildcard",
        input = {{
            jsonText = [[{
                "include": ["**/../*.ts"]
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/main.ts"] = ""},
        }},
    },
    {
        title =               "parses tsconfig with compilerOptions, files, include, and exclude",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "compilerOptions": {
    "outDir": "./dist",
    "strict": true,
    "noImplicitAny": true,
    "target": "ES2017",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "moduleDetection": "auto",
    "jsx": "react",
	"maxNodeModuleJsDepth": 1,
	"paths": {
      "jquery": ["./vendor/jquery/dist/jquery"]
    }
  },
  "files": ["/apath/src/index.ts", "/apath/src/app.ts"],
  "include": ["/apath/src/**/*"],
  "exclude": ["/apath/node_modules", "/apath/dist"]
}]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/src/index.ts"] = "", ["/apath/src/app.ts"] = "", ["/apath/node_modules/module.ts"] = "", ["/apath/dist/output.js"] = ""},
        }},
    },
    {
        title = "generates errors when commandline option is in tsconfig",
        input = {{
            jsonText = [[{
  "compilerOptions": {
    "help": true
  }
}]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "does not generate errors for empty files list when one or more references are provided",
        input = {{
            jsonText = [[{
                "files": [],
                "references": [{ "path": "/apath" }]
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "exclude outDir unless overridden",
        input = {{
            jsonText = [[{
                "compilerOptions": {
                    "outDir": "bin"
                }
            }]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/bin/a.ts"] = "", ["/b.ts"] = ""},
        }, {
            jsonText = [[{
                "compilerOptions": {
                    "outDir": "bin"
                },
                "exclude": [ "obj" ]
            }]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/bin/a.ts"] = "", ["/b.ts"] = ""},
        }},
    },
    {
        title = "exclude declarationDir unless overridden",
        input = {{
            jsonText = [[{
                "compilerOptions": {
                    "declarationDir": "declarations"
                }
            }]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/declarations/a.d.ts"] = "", ["/a.ts"] = ""},
        }, {
            jsonText = [[{
                "compilerOptions": {
                    "declarationDir": "declarations"
                },
                "exclude": [ "types" ]
            }]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/declarations/a.d.ts"] = "", ["/a.ts"] = ""},
        }},
    },
    {
        title = "generates errors for empty directory",
        input = {{
            jsonText = [[{
                "compilerOptions": {
                    "allowJs": true
                }
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {},
        }},
    },
    {
        title = "generates errors for includes with outDir",
        input = {{
            jsonText = [[{
                "compilerOptions": {
                    "outDir": "./"
                },
                "include": ["**/*"]
            }]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "generates errors when include is not string",
        input = {{
            jsonText = [[{
  "include": [
    [
      "./**/*.ts"
    ]
  ]
}]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "generates errors when files is not string",
        input = {{
            jsonText = [[{
  "files": [
    {
      "compilerOptions": {
        "experimentalDecorators": true,
        "allowJs": true
      }
    }
  ]
}]],
            configFileName = "/apath/tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/a.ts"] = ""},
        }},
    },
    {
        title = "with outDir from base tsconfig",
        input = {
            {
                jsonText = [[{
  "extends": "./tsconfigWithoutConfigDir.json"
}]],
                configFileName = "tsconfig.json",
                basePath =       "/",
                allFileList = {
                    ["/tsconfigWithoutConfigDir.json"] = tsconfigWithoutConfigDir,
                    ["/bin/a.ts"] =                      "",
                    ["/b.ts"] =                          "",
                },
            },
            {
                jsonText = [[{
  "extends": "./tsconfigWithConfigDir.json"
}]],
                configFileName = "tsconfig.json",
                basePath =       "/",
                allFileList = {
                    ["/tsconfigWithConfigDir.json"] = tsconfigWithConfigDir,
                    ["/bin/a.ts"] =                   "",
                    ["/b.ts"] =                       "",
                },
            },
        },
    },
    {
        title = "returns error when tsconfig have excludes",
        input = {{
            jsonText = [[{
                    "compilerOptions": {
                        "lib": ["es5"]
                    },
                    "excludes": [
                        "foge.ts"
                    ]
                }]],
            configFileName = "tsconfig.json",
            basePath =       "/apath",
            allFileList =    {["/apath/test.ts"] = "", ["/apath/foge.ts"] = ""},
        }},
    },
    {
        title =               "parses tsconfig with extends, files, include and other options",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
				"extends": "./tsconfigWithExtends.json",
				"compilerOptions": {
				    "outDir": "./dist",
    				"strict": true,
    				"noImplicitAny": true,
					"baseUrl": "",
				},
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/tsconfigWithExtends.json"] = tsconfigWithExtends, ["/src/index.ts"] = "", ["/src/app.ts"] = "", ["/node_modules/module.ts"] = "", ["/dist/output.js"] = ""},
        }},
    },
    {
        title =               "parses tsconfig with extends and configDir",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
				"extends": "./tsconfig.base.json"
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/tsconfig.base.json"] = tsconfigWithExtendsAndConfigDir, ["/src/index.ts"] = "", ["/src/app.ts"] = "", ["/node_modules/module.ts"] = "", ["/dist/output.js"] = ""},
        }},
    },
    {
        title = "reports error for an unknown option",
        input = {{
            jsonText = [[{
			    "compilerOptions": {
				"unknown": true
			    }
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/app.ts"] = ""},
        }},
    },
    {
        title = "reports spelling suggestion for an unknown option",
        input = {{
            jsonText = [[{
			    "compilerOptions": {
				"targt": 1
			    }
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/app.ts"] = ""},
        }},
    },
    {
        title = "reports errors for wrong type option and invalid enum value",
        input = {{
            jsonText = [[{
			    "compilerOptions": {
				"target": "invalid value",
				"removeComments": "should be a boolean",
				"moduleResolution": "invalid value"
			    }
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/app.ts"] = ""},
        }},
    },
    {
        title =               "reports errors for incorrectly cased option names",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
			    "compilerOptions": {
				"sourcemap": true,
				"declarationmap": true,
				"nouncheckedindexedaccess": true,
				"exactoptionalpropertytypes": true,
				"verbatimmodulesyntax": true,
				"isolatedmodules": true,
				"nouncheckedsideeffectimports": true,
				"moduledetection": "force",
				"skiplibcheck": true,
				"checkjs": true
			    }
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/app.ts"] = ""},
        }},
    },
    {
        title =               "handles empty types array",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
			    "compilerOptions": {
					"types": []
				}
			}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList =    {["/app.ts"] = ""},
        }},
    },
    {
        title =               "issue 1267 scenario - extended files not picked up",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "extends": "./tsconfig-base/backend.json",
  "compilerOptions": {
    "baseUrl": "./",
    "outDir": "dist",
    "rootDir": "src",
    "resolveJsonModule": true
  },
  "exclude": ["node_modules", "dist"],
  "include": ["src/**/*"]
}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList = {
                ["/tsconfig-base/backend.json"] = [[{
  "$schema": "https://json.schemastore.org/tsconfig",
  "display": "Backend",
  "compilerOptions": {
    "allowJs": true,
    "module": "nodenext",
    "removeComments": true,
    "emitDecoratorMetadata": true,
    "experimentalDecorators": true,
    "allowSyntheticDefaultImports": true,
    "target": "esnext",
    "lib": ["ESNext"],
    "incremental": false,
    "esModuleInterop": true,
    "noImplicitAny": true,
    "moduleResolution": "nodenext",
    "types": ["node", "vitest/globals"],
    "sourceMap": true,
    "strictPropertyInitialization": false
  },
  "files": [
    "types/ical2json.d.ts",
    "types/express.d.ts",
    "types/multer.d.ts",
    "types/reset.d.ts",
    "types/stripe-custom-typings.d.ts",
    "types/nestjs-modules.d.ts",
    "types/luxon.d.ts",
    "types/nestjs-pino.d.ts"
  ],
  "ts-node": {
    "files": true
  }
}]],
                ["/tsconfig-base/types/ical2json.d.ts"] =             "export {}",
                ["/tsconfig-base/types/express.d.ts"] =               "export {}",
                ["/tsconfig-base/types/multer.d.ts"] =                "export {}",
                ["/tsconfig-base/types/reset.d.ts"] =                 "export {}",
                ["/tsconfig-base/types/stripe-custom-typings.d.ts"] = "export {}",
                ["/tsconfig-base/types/nestjs-modules.d.ts"] =        "export {}",
                ["/tsconfig-base/types/luxon.d.ts"] = [[declare module 'luxon' {
  interface TSSettings {
    throwOnInvalid: true
  }
}
export {}]],
                ["/tsconfig-base/types/nestjs-pino.d.ts"] = "export {}",
                ["/src/main.ts"] =                          "export {}",
                ["/src/utils.ts"] =                         "export {}",
            },
        }},
    },
    {
        title =               "null overrides in extended tsconfig - array fields",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "extends": "./tsconfig-base.json",
  "compilerOptions": {
    "types": null,
    "lib": null,
    "typeRoots": null
  }
}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList = {
                ["/tsconfig-base.json"] = [[{
  "compilerOptions": {
    "types": ["node", "@types/jest"],
    "lib": ["es2020", "dom"],
    "typeRoots": ["./types", "./node_modules/@types"]
  }
}]],
                ["/app.ts"] = "",
            },
        }},
    },
    {
        title =               "null overrides in extended tsconfig - string fields",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "extends": "./tsconfig-base.json",
  "compilerOptions": {
    "outDir": null,
    "baseUrl": null,
    "rootDir": null
  }
}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList = {
                ["/tsconfig-base.json"] = [[{
  "compilerOptions": {
    "outDir": "./dist",
    "baseUrl": "./src",
    "rootDir": "./src"
  }
}]],
                ["/app.ts"] = "",
            },
        }},
    },
    {
        title =               "null overrides in extended tsconfig - mixed field types",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "extends": "./tsconfig-base.json",
  "compilerOptions": {
    "types": null,
    "outDir": null,
    "strict": false,
    "lib": ["es2022"],
    "allowJs": null
  }
}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList = {
                ["/tsconfig-base.json"] = [[{
  "compilerOptions": {
    "types": ["node"],
    "lib": ["es2020", "dom"],
    "outDir": "./dist",
    "strict": true,
    "allowJs": true,
    "target": "es2020"
  }
}]],
                ["/app.ts"] = "",
            },
        }},
    },
    {
        title =               "null overrides with multiple extends levels",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "extends": "./tsconfig-middle.json",
  "compilerOptions": {
    "types": null,
    "lib": null
  }
}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList = {
                ["/tsconfig-middle.json"] = [[{
  "extends": "./tsconfig-base.json",
  "compilerOptions": {
    "types": ["jest"],
    "outDir": "./build"
  }
}]],
                ["/tsconfig-base.json"] = [[{
  "compilerOptions": {
    "types": ["node"],
    "lib": ["es2020"],
    "outDir": "./dist",
    "strict": true
  }
}]],
                ["/app.ts"] = "",
            },
        }},
    },
    {
        title =               "null overrides in middle level of extends chain",
        noSubmoduleBaseline = true,
        input = {{
            jsonText = [[{
  "extends": "./tsconfig-middle.json",
  "compilerOptions": {
    "outDir": "./final"
  }
}]],
            configFileName = "tsconfig.json",
            basePath =       "/",
            allFileList = {
                ["/tsconfig-middle.json"] = [[{
  "extends": "./tsconfig-base.json",
  "compilerOptions": {
    "types": null,
    "lib": null,
    "outDir": "./middle"
  }
}]],
                ["/tsconfig-base.json"] = [[{
  "compilerOptions": {
    "types": ["node"],
    "lib": ["es2020"],
    "outDir": "./base",
    "strict": true
  }
}]],
                ["/app.ts"] = "",
            },
        }},
    },
}
-- luacheck: pop

local function getParsedWithJsonApi(config, host, basePath)
    local configFileName = tspath.GetNormalizedAbsolutePath(config.configFileName, basePath)
    local path = tspath.ToPath(config.configFileName, basePath, host:FS():UseCaseSensitiveFileNames())
    local parsed = tsoptions.ParseConfigFileTextToJson(configFileName, path, config.jsonText)
    return tsoptions.ParseJsonConfigFileContent(
        parsed,
        host,
        basePath,
        config.existingOptions,
        configFileName,
        nil, -- resolutionStack
        nil -- extendedConfigCache
    )
end

local function getParsedWithJsonSourceFileApi(config, host, basePath)
    local configFileName = tspath.GetNormalizedAbsolutePath(config.configFileName, basePath)
    local path = tspath.ToPath(config.configFileName, basePath, host:FS():UseCaseSensitiveFileNames())
    local parsed = parser.ParseSourceFile(ast.NewSourceFileParseOptions(configFileName, path), config.jsonText, core.ScriptKind.JSON)
    local tsConfigSourceFile = tsoptions.NewTsConfigSourceFile(parsed)
    return tsoptions.ParseJsonSourceFileConfigFileContent(
        tsConfigSourceFile,
        host,
        host:GetCurrentDirectory(),
        config.existingOptions,
        nil,
        configFileName,
        nil, -- resolutionStack
        nil -- extendedConfigCache
    )
end

-- Go iterates a map of the two APIs (random order); the subtests are independent.
local parseApis = {
    { name = "json api", getParsed = getParsedWithJsonApi },
    { name = "jsonSourceFile api", getParsed = getParsedWithJsonSourceFileApi },
}

local function baselineParseConfigWith(t, baselineFileName, noSubmoduleBaseline, input, getParsed) -- luacheck: ignore 312
    noSubmoduleBaseline = true
    local baselineContent = core.NewStringBuilder()
    for i, config in ipairs(input) do
        local basePath = config.basePath
        if basePath == "" then
            basePath = tspath.GetNormalizedAbsolutePath(tspath.GetDirectoryPath(config.configFileName), "")
        end
        local configFileName = tspath.CombinePaths(basePath, config.configFileName)
        local allFileLists = copyMap(config.allFileList)
        allFileLists[configFileName] = config.jsonText
        local host = tsoptionstest.NewVFSParseConfigHost(allFileLists, config.basePath, true --[[useCaseSensitiveFileNames]])
        local parsedConfigFileContent = getParsed(config, host, basePath)

        baselineContent:WriteString("Fs::\n")
        local err = printFS(baselineContent, host:FS(), "/")
        if err ~= nil then
            t:Fatal(err)
        end
        baselineContent:WriteString("\n")
        baselineContent:WriteString("configFileName:: ")
        baselineContent:WriteString(config.configFileName)
        baselineContent:WriteString("\n")
        if noSubmoduleBaseline then
            baselineContent:WriteString("CompilerOptions::\n")
            testutil.Assert(t, writeJsonReadableText(baselineContent, parsedConfigFileContent.parsedConfig.compilerOptions) == nil)
            baselineContent:WriteString("\n")
            baselineContent:WriteString("\n")

            if parsedConfigFileContent.parsedConfig.typeAcquisition ~= nil then
                baselineContent:WriteString("TypeAcquisition::\n")
                testutil.Assert(t, writeJsonReadableText(baselineContent, parsedConfigFileContent.parsedConfig.typeAcquisition) == nil)
                baselineContent:WriteString("\n")
                baselineContent:WriteString("\n")
            end
        end
        baselineContent:WriteString("FileNames::\n")
        baselineContent:WriteString(table.concat(parsedConfigFileContent.parsedConfig.fileNames or {}, ","))
        baselineContent:WriteString("\n")
        baselineContent:WriteString("Errors::\n")
        diagnosticwriter.FormatDiagnosticsWithColorAndContext(baselineContent, diagnosticwriter.FromASTDiagnostics(parsedConfigFileContent.errors), {
            newLine = "\r\n",
            currentDirectory = basePath,
            useCaseSensitiveFileNames = true,
        })
        baselineContent:WriteString("\n")
        if i ~= #input then
            baselineContent:WriteString("\n")
        end
    end
    if noSubmoduleBaseline then
        baseline.Run(t, baselineFileName, baselineContent:String(), { subfolder = "config/tsconfigParsing" })
    else
        baseline.RunAgainstSubmodule(t, baselineFileName, baselineContent:String(), { subfolder = "config/tsconfigParsing" })
    end
end

describe("TestParseConfigFileTextToJson", function()
    for _, rec in ipairs(parseConfigFileTextToJsonTests) do
        it(rec.title, function()
            runT(function(t)
                repo.SkipIfNoTypeScriptSubmodule(t)
                local baselineContent = core.NewStringBuilder()
                for i, jsonText in ipairs(rec.input) do
                    baselineContent:WriteString("Input::\n")
                    baselineContent:WriteString(jsonText)
                    baselineContent:WriteString("\n")
                    local parsed, errors = tsoptions.ParseConfigFileTextToJson("/apath/tsconfig.json", "/apath", jsonText)
                    baselineContent:WriteString("Config::\n")
                    testutil.Assert(t, writeJsonReadableText(baselineContent, parsed) == nil, "Failed to write JSON text")
                    baselineContent:WriteString("\n")
                    baselineContent:WriteString("Errors::\n")
                    diagnosticwriter.FormatDiagnosticsWithColorAndContext(baselineContent, diagnosticwriter.FromASTDiagnostics(errors), {
                        newLine = "\n",
                        currentDirectory = "/",
                        useCaseSensitiveFileNames = true,
                    })
                    baselineContent:WriteString("\n")
                    if i ~= #rec.input then
                        baselineContent:WriteString("\n")
                    end
                end
                baseline.RunAgainstSubmodule(t, rec.title .. " jsonParse.js", baselineContent:String(), { subfolder = "config/tsconfigParsing" })
            end)
        end)
    end
end)

describe("TestParseJsonConfigFileContent", function()
    for _, rec in ipairs(parseJsonConfigFileTests) do
        it(rec.title .. " with json api", function()
            runT(function(t)
                repo.SkipIfNoTypeScriptSubmodule(t)
                baselineParseConfigWith(t, rec.title .. " with json api.js", rec.noSubmoduleBaseline, rec.input, getParsedWithJsonApi)
            end)
        end)
    end
end)

describe("TestParseJsonConfigFileContentAcceptsJsonRepresentations", function()
    local host = tsoptionstest.NewVFSParseConfigHost({
        ["/project/index.ts"] = "export {};",
    }, "/project", true --[[useCaseSensitiveFileNames]])

    -- Each subtest builds its own input: ParseJsonConfigFileContent normalizes ordered maps in place.
    local tests = {
        {
            "ordered map",
            function()
                local orderedMap, parseErrors = tsoptions.ParseConfigFileTextToJson(
                    "/project/tsconfig.json",
                    "/project/tsconfig.json",
                    [[{"compilerOptions":{"strict":true},"files":["index.ts"]}]]
                )
                assert.are.equal(0, core.Len(parseErrors))
                return orderedMap
            end,
        },
        {
            "ordered map with typed slices",
            function()
                local orderedMapWithTypedSlices = collections.NewOrderedMap()
                orderedMapWithTypedSlices:Set("compilerOptions", { strict = true })
                orderedMapWithTypedSlices:Set("files", { "index.ts" })
                return orderedMapWithTypedSlices
            end,
        },
        {
            "plain map",
            function()
                return {
                    compilerOptions = { strict = true },
                    files = { "index.ts" },
                }
            end,
        },
        {
            "typed slices",
            function()
                return {
                    compilerOptions = { strict = true },
                    files = { "index.ts" },
                }
            end,
        },
    }
    for _, test in ipairs(tests) do
        it(test[1], function()
            local parsed = tsoptions.ParseJsonConfigFileContent(
                test[2](),
                host,
                "/project",
                nil,
                "/project/tsconfig.json",
                nil, -- resolutionStack
                nil -- extendedConfigCache
            )
            assert.are.same({ "/project/index.ts" }, parsed:FileNames())
            assert.is_true(core.Tristate_IsTrue(parsed:CompilerOptions().strict))
            assert.are.equal(0, core.Len(parsed.errors))
        end)
    end
end)

describe("TestParseJsonConfigFileContentPreservesRaw", function()
    it("TestParseJsonConfigFileContentPreservesRaw", function()
        local host = tsoptionstest.NewVFSParseConfigHost({
            ["/project/index.ts"] = "export {};",
        }, "/project", true --[[useCaseSensitiveFileNames]])

        local parsed = tsoptions.ParseJsonConfigFileContent(
            {
                files = { "index.ts" },
                customSetting = { enabled = true },
                compileOnSave = true,
            },
            host,
            "/project",
            nil,
            "/project/tsconfig.json",
            nil, -- resolutionStack
            nil -- extendedConfigCache
        )

        assert.are.equal(0, core.Len(parsed.errors))
        assert.is_true(parsed.compileOnSave ~= nil and parsed.compileOnSave)

        local raw = parsed.raw
        assert.are.same({ "compileOnSave", "customSetting", "files" }, core.Collect(raw:Keys()))
        assert.is_true(raw:Has("customSetting"))
    end)
end)

describe("TestParseJsonConfigFileContentHandlesNullArrayElements", function()
    local host = tsoptionstest.NewVFSParseConfigHost({
        ["/project/index.ts"] = "export {};",
    }, "/project", true --[[useCaseSensitiveFileNames]])
    for _, property in ipairs({ "files", "include", "exclude" }) do
        it(property, function()
            local parsed = tsoptions.ParseJsonConfigFileContent(
                { [property] = { json.Null } },
                host,
                "/project",
                nil,
                "/project/tsconfig.json",
                nil, -- resolutionStack
                nil -- extendedConfigCache
            )
            assert.is_true(core.Len(parsed.errors) > 0)
            assert.are.equal(diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(), parsed.errors[1]:Code())
        end)
    end
end)

describe("TestParseJsonConfigFileContentDefaultsCompileOnSaveToFalse", function()
    it("TestParseJsonConfigFileContentDefaultsCompileOnSaveToFalse", function()
        local host = tsoptionstest.NewVFSParseConfigHost({
            ["/project/index.ts"] = "export {};",
        }, "/project", true --[[useCaseSensitiveFileNames]])
        local parsed = tsoptions.ParseJsonConfigFileContent(
            { files = { "index.ts" } },
            host,
            "/project",
            nil,
            "/project/tsconfig.json",
            nil, -- resolutionStack
            nil -- extendedConfigCache
        )
        assert.is_true(parsed.compileOnSave ~= nil)
        assert.are.equal(false, parsed.compileOnSave)
    end)
end)

describe("TestParseJsonSourceFileConfigFileContent", function()
    for _, rec in ipairs(parseJsonConfigFileTests) do
        it(rec.title .. " with jsonSourceFile api", function()
            runT(function(t)
                repo.SkipIfNoTypeScriptSubmodule(t)
                baselineParseConfigWith(t, rec.title .. " with jsonSourceFile api.js", rec.noSubmoduleBaseline, rec.input, getParsedWithJsonSourceFileApi)
            end)
        end)
    end
end)

describe("TestParseJsonSourceFileConfigFileContentReportsInvalidExtendedConfig", function()
    it("TestParseJsonSourceFileConfigFileContentReportsInvalidExtendedConfig", function()
        local files = {
            ["/project/tsconfig.json"] = '{\n  "extends": "./bad.json"\n}',
            -- The parser recovers from this as object-like JSON, producing expected-token errors for ':', ',', ',', and '}'.
            ["/project/bad.json"] = "{ this is not json",
            ["/project/main.ts"] = "export const x = 1;",
        }
        local host = tsoptionstest.NewVFSParseConfigHost(files, "/project", true --[[useCaseSensitiveFileNames]])
        local configFileName = "/project/tsconfig.json"
        local configFile = tsoptions.NewTsconfigSourceFileFromFilePath(
            configFileName,
            tspath.ToPath(configFileName, host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames()),
            files[configFileName]
        )

        local parsed = tsoptions.ParseJsonSourceFileConfigFileContent(
            configFile,
            host,
            host:GetCurrentDirectory(),
            nil,
            nil,
            configFileName,
            nil,
            nil
        )

        local parseErrors = core.Filter(parsed.errors, function(diagnostic)
            return diagnostic:Code() == diagnostics.X_0_expected:Code()
        end)
        local expectedParseErrorMessages = { ":", ",", ",", "}" }
        local expectedParseErrorPositions = { 7, 10, 14, 18 }
        assert.are.equal(#expectedParseErrorMessages, core.Len(parseErrors))
        assert.are.same(expectedParseErrorMessages, core.Map(parseErrors, function(diagnostic)
            return diagnostic:MessageArgs()[1]
        end))
        assert.are.same(expectedParseErrorPositions, core.Map(parseErrors, function(diagnostic)
            return diagnostic:Pos()
        end))
        for _, diagnostic in ipairs(parseErrors) do
            assert.are.equal("/project/bad.json", diagnostic:File():FileName())
        end
    end)
end)

-- Extending an empty config file used to panic on nil Statements (#4265).
describe("TestParseJsonSourceFileConfigFileContentWithEmptyExtendedConfig", function()
    it("TestParseJsonSourceFileConfigFileContentWithEmptyExtendedConfig", function()
        local files = {
            ["/project/tsconfig.json"] = '{\n  "extends": "./base.json"\n}',
            ["/project/base.json"] = "",
            ["/project/main.ts"] = "export const x = 1;",
        }
        local host = tsoptionstest.NewVFSParseConfigHost(files, "/project", true --[[useCaseSensitiveFileNames]])
        local configFileName = "/project/tsconfig.json"
        local configFile = tsoptions.NewTsconfigSourceFileFromFilePath(
            configFileName,
            tspath.ToPath(configFileName, host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames()),
            files[configFileName]
        )

        local parsed = tsoptions.ParseJsonSourceFileConfigFileContent(
            configFile,
            host,
            host:GetCurrentDirectory(),
            nil,
            nil,
            configFileName,
            nil,
            nil
        )

        assert.is_not_nil(parsed)
        assert.are.same({ "/project/main.ts" }, parsed:FileNames())
    end)
end)

describe("TestParseJsonSourceFileConfigFileContentDoesNotDuplicateUnquotedKeyDiagnostics", function()
    it("TestParseJsonSourceFileConfigFileContentDoesNotDuplicateUnquotedKeyDiagnostics", function()
        local parsed = tsoptionstest.GetParsedCommandLine(nil, "{\n  compilerOptions: {\n    strict: true\n  }\n}",
            { ["/main.ts"] = "export const x = 1;" }, "/", true --[[useCaseSensitiveFileNames]])

        local diags = parsed:GetConfigFileParsingDiagnostics()
        assert.are.equal(2, core.Len(diags))
        local expectedLocations = {
            { line = 1, character = 2 },
            { line = 2, character = 4 },
        }
        for index, diagnostic in ipairs(diags) do
            assert.are.equal(diagnostics.String_literal_with_double_quotes_expected:Code(), diagnostic:Code())
            local line, character = scanner.GetECMALineAndUTF16CharacterOfPosition(diagnostic:File(), diagnostic:Pos())
            assert.are.equal(expectedLocations[index].line, line)
            assert.are.equal(expectedLocations[index].character, character)
        end
    end)
end)

describe("TestParseJsonSourceFileConfigFileContentReportsQuestionTokenDiagnostics", function()
    it("TestParseJsonSourceFileConfigFileContentReportsQuestionTokenDiagnostics", function()
        local parsed = tsoptionstest.GetParsedCommandLine(nil, "{\n  compilerOptions?: {\n    strict?: true\n  }\n}",
            { ["/main.ts"] = "export const x = 1;" }, "/", true --[[useCaseSensitiveFileNames]])

        local questionTokenDiagnostics = {}
        for _, diagnostic in ipairs(parsed:GetConfigFileParsingDiagnostics() or {}) do
            if diagnostic:Code() == diagnostics.The_0_modifier_can_only_be_used_in_TypeScript_files:Code() then
                questionTokenDiagnostics[#questionTokenDiagnostics + 1] = diagnostic
            end
        end
        assert.are.equal(2, #questionTokenDiagnostics)
        local expectedLocations = {
            { line = 1, character = 17 },
            { line = 2, character = 10 },
        }
        for index, diagnostic in ipairs(questionTokenDiagnostics) do
            local line, character = scanner.GetECMALineAndUTF16CharacterOfPosition(diagnostic:File(), diagnostic:Pos())
            assert.are.equal(expectedLocations[index].line, line)
            assert.are.equal(expectedLocations[index].character, character)
        end
    end)
end)

describe("TestParseNullEnumCompilerOptions", function()
    local config = {
        jsonText = '{\n\t\t\t"compilerOptions": {\n\t\t\t\t"target": null,\n\t\t\t\t"module": null\n\t\t\t}\n\t\t}',
        configFileName = "tsconfig.json",
        basePath = "/",
        allFileList = { ["/app.ts"] = "" },
    }
    for _, api in ipairs(parseApis) do
        it(api.name, function()
            local allFileLists = copyMap(config.allFileList)
            allFileLists["/tsconfig.json"] = config.jsonText
            local host = tsoptionstest.NewVFSParseConfigHost(allFileLists, config.basePath, true --[[useCaseSensitiveFileNames]])
            local parsedConfigFileContent = api.getParsed(config, host, config.basePath)
            assert.are.equal(0, core.Len(parsedConfigFileContent.errors))
        end)
    end
end)

describe("TestContentMappers", function()
    local config = {
        jsonText = [[{
			"contentMappers": [
				{ "package": "vue-mapper", "extensions": [".vue"], "options": { "strictTemplates": true } }
			],
			"include": ["src"]
		}]],
        configFileName = "tsconfig.json",
        basePath = "/",
        allFileList = {
            ["/src/app.ts"] = "export {}",
            ["/src/Component.vue"] = "<template></template>",
            ["/node_modules/vue-mapper/package.json"] = [[{ "name": "vue-mapper", "version": "1.2.3", "typescript": { "contentMapper": { "exec": ["node", "./mapper.js"], "dynamicConfig": true } } }]],
        },
        existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
    }
    for _, api in ipairs(parseApis) do
        it(api.name, function()
            local allFileLists = copyMap(config.allFileList)
            allFileLists["/tsconfig.json"] = config.jsonText
            local host = tsoptionstest.NewVFSParseConfigHost(allFileLists, config.basePath, true --[[useCaseSensitiveFileNames]])
            local parsed = api.getParsed(config, host, config.basePath)

            assert.are.equal(0, core.Len(parsed.errors))

            local mappers = parsed:ContentMappers()
            assert.are.equal(1, core.Len(mappers))
            assert.are.equal("vue-mapper", mappers[1].package)
            assert.are.same({ ".vue" }, mappers[1].extensions)
            assert.are.equal('{"strictTemplates":true}', mappers[1].options)
            assert.are.same({ ".vue" }, parsed:ContentMapperExtensions())

            -- The package.json is resolved during parsing, populating name, version, and exec.
            assert.are.equal("vue-mapper", mappers[1].name)
            assert.are.equal("1.2.3", mappers[1].version)
            assert.are.same({ "node", "./mapper.js" }, mappers[1].exec)
            assert.is_true(mappers[1].dynamicConfig)
            assert.are.equal("/node_modules/vue-mapper", mappers[1].packageDirectory)

            -- The .vue file is picked up by the include glob because its extension is registered.
            assert.is_true(contains(parsed:FileNames(), "/src/Component.vue"), "expected /src/Component.vue in " .. table.concat(parsed:FileNames(), ","))
            assert.is_true(contains(parsed:FileNames(), "/src/app.ts"), "expected /src/app.ts in " .. table.concat(parsed:FileNames(), ","))
        end)
    end
end)

describe("TestContentMapperOptionDiagnosticLocation", function()
    it("TestContentMapperOptionDiagnosticLocation", function()
        local config = {
            jsonText = [[{
			"contentMappers": [{
				"package": "mapper",
				"extensions": [".vue"],
				"options": { "plugins": [{ "name": 1 }] }
			}]
		}]],
            configFileName = "tsconfig.json",
            basePath = "/",
            allFileList = {
                ["/index.ts"] = "export {};",
                ["/node_modules/mapper/package.json"] = [[{ "name": "mapper", "version": "1.0.0", "typescript": { "contentMapper": { "exec": ["mapper"] } } }]],
            },
            existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
        }
        local host = tsoptionstest.NewVFSParseConfigHost(config.allFileList, config.basePath, true --[[useCaseSensitiveFileNames]])
        local parsed = getParsedWithJsonSourceFileApi(config, host, config.basePath)
        local file, loc = tsoptions.GetContentMapperOptionDiagnosticLocation(parsed, parsed:ContentMappers()[1], {
            { property = "plugins", index = 0, isIndex = false },
            { property = "", index = 0, isIndex = true },
            { property = "name", index = 0, isIndex = false },
        })
        assert.are.equal("1", string.sub(file:Text(), loc:Pos() + 1, loc:End()))
    end)
end)

describe("TestContentMappersAreInheritedFromExtendedConfig", function()
    local config = {
        jsonText = [[{ "extends": "./base.json" }]],
        configFileName = "tsconfig.json",
        basePath = "/project",
        allFileList = {
            ["/project/base.json"] = [[{ "contentMappers": [{ "package": "vue-mapper", "extensions": [".vue"] }], "include": ["src"] }]],
            ["/project/src/index.ts"] = "export {};",
            ["/project/src/component.vue"] = "<template></template>",
            ["/project/node_modules/vue-mapper/package.json"] = [[{ "name": "vue-mapper", "version": "1.2.3", "typescript": { "contentMapper": { "exec": ["node", "./mapper.js"] } } }]],
        },
        existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
    }
    for _, api in ipairs(parseApis) do
        it(api.name, function()
            local host = tsoptionstest.NewVFSParseConfigHost(config.allFileList, config.basePath, true --[[useCaseSensitiveFileNames]])
            local parsed = api.getParsed(config, host, config.basePath)
            assert.are.equal(0, core.Len(parsed.errors))
            assert.are.equal(1, core.Len(parsed:ContentMappers()))
            assert.are.equal("vue-mapper", parsed:ContentMappers()[1].package)
            assert.are.same({ ".vue" }, parsed:ContentMapperExtensions())
            assert.is_true(contains(parsed:FileNames(), "/project/src/component.vue"))
        end)
    end
end)

describe("TestContentMappersRequireFlag", function()
    local config = {
        jsonText = [[{ "contentMappers": [{ "package": "vue-mapper", "extensions": [".vue"] }] }]],
        configFileName = "tsconfig.json",
        basePath = "/",
        allFileList = { ["/app.ts"] = "export {}" },
        -- existingOptions omitted: --runExternalCode is not set.
    }
    local expectedCode = diagnostics.Content_mappers_require_the_runExternalCode_command_line_flag_to_be_enabled:Code()
    for _, api in ipairs(parseApis) do
        it(api.name, function()
            local allFileLists = { ["/tsconfig.json"] = config.jsonText }
            for k, v in pairs(config.allFileList) do
                allFileLists[k] = v
            end
            local host = tsoptionstest.NewVFSParseConfigHost(allFileLists, config.basePath, true --[[useCaseSensitiveFileNames]])
            local parsed = api.getParsed(config, host, config.basePath)
            local found = core.Some(parsed.errors, function(d)
                return d:Code() == expectedCode
            end)
            assert.is_true(found, "expected diagnostic " .. expectedCode)
        end)
    end
end)

describe("TestUnresolvedContentMapperDoesNotRegisterExtensions", function()
    local config = {
        jsonText = [[{ "contentMappers": [{ "package": "missing-mapper", "extensions": [".vue"] }], "include": ["src"] }]],
        configFileName = "tsconfig.json",
        basePath = "/",
        allFileList = { ["/src/app.ts"] = "export {}", ["/src/Component.vue"] = "<template />" },
        existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
    }
    for _, api in ipairs(parseApis) do
        it(api.name, function()
            local host = tsoptionstest.NewVFSParseConfigHost(config.allFileList, config.basePath, true)
            local parsed = api.getParsed(config, host, config.basePath)

            assert.are.equal(0, core.Len(parsed:ContentMappers()))
            assert.are.equal(0, core.Len(parsed:ContentMapperExtensions()))
            assert.is_false(contains(parsed:FileNames(), "/src/Component.vue"))
            assert.is_true(contains(parsed:FileNames(), "/src/app.ts"))
        end)
    end
end)


local contentMappersValidationTests = {
    {
        name =           "extension without leading dot",
        contentMappers = [=[[{ "package": "vue-mapper", "extensions": ["vue"] }]]=],
        expectedCode =   diagnostics.Content_mapper_file_extension_0_must_begin_with_a:Code(),
    },
    {
        name =           "built-in extension",
        contentMappers = [=[[{ "package": "x", "extensions": [".ts"] }]]=],
        expectedCode =   diagnostics.Content_mapper_file_extension_0_is_a_built_in_extension_and_cannot_be_registered_by_a_content_mapper:Code(),
    },
    {
        name =           "missing extensions",
        contentMappers = [=[[{ "package": "x" }]]=],
        expectedCode =   diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(),
    },
    {
        name =           "duplicate extension across mappers",
        contentMappers = [=[[{ "package": "a", "extensions": [".vue"] }, { "package": "b", "extensions": [".vue"] }]]=],
        expectedCode =   diagnostics.Content_mapper_file_extension_0_is_registered_by_more_than_one_content_mapper:Code(),
    },
    {
        name =           "extensions is not an array",
        contentMappers = [=[[{ "package": "x", "extensions": ".vue" }]]=],
        expectedCode =   diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(),
    },
    {
        name =           "extensions contains a non-string",
        contentMappers = [=[[{ "package": "x", "extensions": [".vue", 1] }]]=],
        expectedCode =   diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(),
    },
    {
        name =           "package is not a string",
        contentMappers = [=[[{ "package": ["x"], "extensions": [".vue"] }]]=],
        expectedCode =   diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(),
    },
    {
        name =           "missing package",
        contentMappers = [=[[{ "extensions": [".vue"] }]]=],
        expectedCode =   diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(),
    },
    {
        name =           "options is not an object",
        contentMappers = [=[[{ "package": "x", "extensions": [".vue"], "options": ["strict"] }]]=],
        expectedCode =   diagnostics.Compiler_option_0_requires_a_value_of_type_1:Code(),
    },
}


describe("TestContentMappersValidation", function()
    for _, test in ipairs(contentMappersValidationTests) do
        describe(test.name, function()
            local config = {
                jsonText = "{ \"contentMappers\": " .. test.contentMappers .. " }",
                configFileName = "tsconfig.json",
                basePath = "/",
                allFileList = { ["/app.ts"] = "export {}" },
                existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue }),
            }
            if test.name == "duplicate extension across mappers" then
                config.allFileList["/node_modules/a/package.json"] = [[{ "name": "a", "version": "1.0.0", "typescript": { "contentMapper": { "exec": ["a"] } } }]]
                config.allFileList["/node_modules/b/package.json"] = [[{ "name": "b", "version": "1.0.0", "typescript": { "contentMapper": { "exec": ["b"] } } }]]
            end
            for _, api in ipairs(parseApis) do
                local apiName = api.name
                it(apiName, function()
                    local allFileLists = { ["/tsconfig.json"] = config.jsonText }
                    for k, v in pairs(config.allFileList) do
                        allFileLists[k] = v
                    end
                    local host = tsoptionstest.NewVFSParseConfigHost(allFileLists, config.basePath, true --[[useCaseSensitiveFileNames]])
                    local parsed = api.getParsed(config, host, config.basePath)
                    local diagnostic = core.Find(parsed.errors, function(d)
                        return d:Code() == test.expectedCode
                    end)
                    assert.is_true(diagnostic ~= nil, "expected diagnostic " .. test.expectedCode)
                    local name = test.name
                    if name == "built-in extension" then
                        assert.are.equal(0, core.Len(parsed:ContentMappers()))
                        assert.are.equal(0, core.Len(parsed:ContentMapperExtensions()))
                    elseif name == "duplicate extension across mappers" then
                        assert.are.equal(2, core.Len(parsed:ContentMappers()))
                        assert.are.same({ ".vue" }, parsed:ContentMappers()[1].extensions)
                        assert.are.equal(0, core.Len(parsed:ContentMappers()[2].extensions))
                        assert.are.same({ ".vue" }, parsed:ContentMapperExtensions())
                    elseif name == "missing extensions" or name == "extensions is not an array" or name == "extensions contains a non-string"
                        or name == "package is not a string" or name == "missing package" or name == "options is not an object" then
                        assert.are.equal(0, core.Len(parsed:ContentMappers()))
                    end

                    -- With the jsonSourceFile API the diagnostic is located at the offending tsconfig syntax.
                    if apiName == "jsonSourceFile api" then
                        assert.is_true(diagnostic:File() ~= nil, "expected diagnostic " .. test.expectedCode .. " to have a source file")
                        assert.is_true(diagnostic:Len() > 0, "expected diagnostic " .. test.expectedCode .. " to have a non-empty location")
                    end
                end)
            end
        end)
    end
end)

local typeAcquisitionCases = {
    {
        title = "Convert correctly format tsconfig.json to typeAcquisition ",
        config = [[{
	"typeAcquisition": {
		"enable": true,
		"include": ["0.d.ts", "1.d.ts"],
		"exclude": ["0.js", "1.js"],
	},
}]],
        configName = "tsconfig.json",
    },
    {
        title = "Convert incorrect format tsconfig.json to typeAcquisition ",
        config = [[{
	"typeAcquisition": {
		"enableAutoDiscovy": true,
	}
}]], configName = "tsconfig.json",
    },
    {
        title =  "Convert default tsconfig.json to typeAcquisition ",
        config = [[{}]], configName = "tsconfig.json",
    },
    {
        title = "Convert tsconfig.json with only enable property to typeAcquisition ",
        config = [[{
	"typeAcquisition": {
		"enable": true,
	},
}]], configName = "tsconfig.json",
    },

    -- jsconfig.json
    {
        title = "Convert jsconfig.json to typeAcquisition ",
        config = [[{
	"typeAcquisition": {
		"enable": false,
		"include": ["0.d.ts"],
		"exclude": ["0.js"],
	},
}]],
        configName = "jsconfig.json",
    },
    {title = "Convert default jsconfig.json to typeAcquisition ", config = [[{}]], configName = "jsconfig.json"},
    {
        title = "Convert incorrect format jsconfig.json to typeAcquisition ",
        config = [[{
	"typeAcquisition": {
		"enableAutoDiscovy": true,
	},
}]],
        configName = "jsconfig.json",
    },
    {
        title = "Convert jsconfig.json with only enable property to typeAcquisition ",
        config = [[{
	"typeAcquisition": {
		"enable": false,
	},
}]],
        configName = "jsconfig.json",
    },
}

describe("TestParseTypeAcquisition", function()
    -- repo.SkipIfNoTypeScriptSubmodule(t)
    for _, test in ipairs(typeAcquisitionCases) do
        local withJsonApiName = test.title .. " with json api"
        local input = {
            {
                jsonText = test.config,
                configFileName = test.configName,
                basePath = "/apath",
                allFileList = {
                    ["/apath/a.ts"] = "",
                    ["/apath/b.ts"] = "",
                },
            },
        }
        it(withJsonApiName, function()
            runT(function(t)
                baselineParseConfigWith(t, withJsonApiName .. ".js", true, input, getParsedWithJsonApi)
            end)
        end)
        local withJsonSourceFileApiName = test.title .. " with jsonSourceFile api"
        it(withJsonSourceFileApiName, function()
            runT(function(t)
                baselineParseConfigWith(t, withJsonSourceFileApiName .. ".js", true, input, getParsedWithJsonSourceFileApi)
            end)
        end)
    end
end)

describe("TestParseSrcCompiler", function()
    it("TestParseSrcCompiler", function()
        runT(function(t)
            repo.SkipIfNoTypeScriptSubmodule(t)

            local compilerDir = tspath.NormalizeSlashes(repo.TypeScriptSubmodulePath() .. "/src/compiler")
            local tsconfigFileName = tspath.CombinePaths(compilerDir, "tsconfig.json")

            local fs = osvfs.FS()
            local host = setmetatable({
                vfs = fs,
                currentDirectory = compilerDir,
            }, tsoptionstest.VfsParseConfigHost)

            local jsonText, ok = fs:ReadFile(tsconfigFileName)
            testutil.Assert(t, ok)
            local tsconfigPath = tspath.ToPath(tsconfigFileName, compilerDir, fs:UseCaseSensitiveFileNames())
            local parsed = parser.ParseSourceFile(ast.NewSourceFileParseOptions(tsconfigFileName, tsconfigPath), jsonText, core.ScriptKind.JSON)

            if core.Len(parsed:Diagnostics()) > 0 then
                for _, e in ipairs(parsed:Diagnostics()) do
                    t:Log(e:Localize(locale.Default))
                end
                t:FailNow()
            end

            local tsConfigSourceFile = tsoptions.NewTsConfigSourceFile(parsed)

            local parseConfigFileContent = tsoptions.ParseJsonSourceFileConfigFileContent(
                tsConfigSourceFile,
                host,
                host:GetCurrentDirectory(),
                nil,
                nil,
                tsconfigFileName,
                nil, -- resolutionStack
                nil -- extendedConfigCache
            )

            if core.Len(parseConfigFileContent.errors) > 0 then
                for _, e in ipairs(parseConfigFileContent.errors) do
                    t:Log(e:Localize(locale.Default))
                end
                t:FailNow()
            end

            local opts = parseConfigFileContent:CompilerOptions()
            local expected = core.NewCompilerOptions({
                lib = { "lib.es2020.d.ts" },
                module = core.ModuleKind.NodeNext,
                moduleResolution = core.ModuleResolutionKind.NodeNext,
                newLine = core.NewLineKind.LF,
                outDir = tspath.NormalizeSlashes(repo.TypeScriptSubmodulePath() .. "/built/local"),
                target = core.ScriptTarget.ES2020,
                types = { "node" },
                configFilePath = tsconfigFileName,
                declaration = core.Tristate.TSTrue,
                declarationMap = core.Tristate.TSTrue,
                emitDeclarationOnly = core.Tristate.TSTrue,
                alwaysStrict = core.Tristate.TSTrue,
                composite = core.Tristate.TSTrue,
                isolatedDeclarations = core.Tristate.TSTrue,
                noImplicitOverride = core.Tristate.TSTrue,
                preserveConstEnums = core.Tristate.TSTrue,
                rootDir = tspath.NormalizeSlashes(repo.TypeScriptSubmodulePath() .. "/src"),
                skipLibCheck = core.Tristate.TSTrue,
                strict = core.Tristate.TSTrue,
                strictBindCallApply = core.Tristate.TSFalse,
                sourceMap = core.Tristate.TSTrue,
                useUnknownInCatchVariables = core.Tristate.TSFalse,
                pretty = core.Tristate.TSTrue,
            })
            for _, field in ipairs(core.CompilerOptions.Fields) do
                assert.are.same(expected[field.name], opts[field.name], "CompilerOptions." .. field.name)
            end

            local fileNames = parseConfigFileContent.parsedConfig.fileNames
            local relativePaths = {}
            for _, fileName in ipairs(fileNames) do
                if not string.find(fileName, ".generated.", 1, true) then
                    relativePaths[#relativePaths + 1] = tspath.ConvertToRelativePath(fileName, tspath.NewComparePathsOptions(fs:UseCaseSensitiveFileNames(), compilerDir))
                end
            end

            assert.are.same({
                "binder.ts",
                "builder.ts",
                "builderPublic.ts",
                "builderState.ts",
                "builderStatePublic.ts",
                "checker.ts",
                "commandLineParser.ts",
                "core.ts",
                "corePublic.ts",
                "debug.ts",
                "emitter.ts",
                "executeCommandLine.ts",
                "expressionToTypeNode.ts",
                "moduleNameResolver.ts",
                "moduleSpecifiers.ts",
                "parser.ts",
                "path.ts",
                "performance.ts",
                "performanceCore.ts",
                "program.ts",
                "programDiagnostics.ts",
                "resolutionCache.ts",
                "scanner.ts",
                "semver.ts",
                "sourcemap.ts",
                "symbolWalker.ts",
                "sys.ts",
                "tracing.ts",
                "transformer.ts",
                "tsbuild.ts",
                "tsbuildPublic.ts",
                "types.ts",
                "utilities.ts",
                "utilitiesPublic.ts",
                "visitorPublic.ts",
                "watch.ts",
                "watchPublic.ts",
                "watchUtilities.ts",
                "_namespaces/ts.moduleSpecifiers.ts",
                "_namespaces/ts.performance.ts",
                "_namespaces/ts.ts",
                "factory/baseNodeFactory.ts",
                "factory/emitHelpers.ts",
                "factory/emitNode.ts",
                "factory/nodeChildren.ts",
                "factory/nodeConverters.ts",
                "factory/nodeFactory.ts",
                "factory/nodeTests.ts",
                "factory/parenthesizerRules.ts",
                "factory/utilities.ts",
                "factory/utilitiesPublic.ts",
                "transformers/classFields.ts",
                "transformers/classThis.ts",
                "transformers/declarations.ts",
                "transformers/destructuring.ts",
                "transformers/es2015.ts",
                "transformers/es2016.ts",
                "transformers/es2017.ts",
                "transformers/es2018.ts",
                "transformers/es2019.ts",
                "transformers/es2020.ts",
                "transformers/es2021.ts",
                "transformers/esDecorators.ts",
                "transformers/esnext.ts",
                "transformers/generators.ts",
                "transformers/jsx.ts",
                "transformers/legacyDecorators.ts",
                "transformers/namedEvaluation.ts",
                "transformers/taggedTemplate.ts",
                "transformers/ts.ts",
                "transformers/typeSerializer.ts",
                "transformers/utilities.ts",
                "transformers/declarations/diagnostics.ts",
                "transformers/module/esnextAnd2015.ts",
                "transformers/module/impliedNodeFormatDependent.ts",
                "transformers/module/module.ts",
                "transformers/module/system.ts",
            }, relativePaths)
        end)
    end)
end)

-- memoCache is a minimal memoizing ExtendedConfigCache used by tests to simulate
-- cache hits across multiple parses of configs that extend a common base.
local memoCache = {}
memoCache.__index = memoCache

local function newMemoCache()
    return setmetatable({ m = nil }, memoCache)
end

function memoCache:GetExtendedConfig(fileName, path, resolutionStack, host)
    if self.m == nil then
        self.m = {}
    end
    local e = self.m[path]
    if e ~= nil then
        return e
    end
    e = tsoptions.ParseExtendedConfig(fileName, path, resolutionStack, host, self)
    self.m[path] = e
    return e
end

-- TestExtendedConfigErrorsAppearOnCacheHit verifies that diagnostics produced while parsing an
-- extended config are still reported when the extended config comes from the cache.
describe("TestExtendedConfigErrorsAppearOnCacheHit", function()
    local function makeParseConfig(host)
        return function(configFileName, cache)
            local cfgPath = tspath.ToPath(configFileName, host:GetCurrentDirectory(), host:FS():UseCaseSensitiveFileNames())
            local jsonText, ok = host:FS():ReadFile(configFileName)
            assert.is_true(ok, "missing " .. configFileName .. " in test fs")
            local tsConfigSourceFile = tsoptions.NewTsConfigSourceFile(
                parser.ParseSourceFile(ast.NewSourceFileParseOptions(configFileName, cfgPath), jsonText, core.ScriptKind.JSON)
            )
            return tsoptions.ParseJsonSourceFileConfigFileContent(
                tsConfigSourceFile,
                host,
                host:GetCurrentDirectory(),
                nil,
                nil,
                configFileName,
                nil,
                cache
            )
        end
    end

    it("single config parsed twice", function()
        local files = {
            ["/tsconfig.json"] = '{\n  "extends": "./base.json"\n}',
            -- 'excludes' instead of 'exclude' triggers diagnostic
            ["/base.json"] = '{\n  "excludes": ["**/*.ts"]\n}',
            ["/app.ts"] = "export {}",
        }

        local host = tsoptionstest.NewVFSParseConfigHost(files, "/", true --[[useCaseSensitiveFileNames]])
        local parseConfig = makeParseConfig(host)

        local cache = newMemoCache()
        local first = parseConfig("/tsconfig.json", cache)
        assert.is_true(core.Len(first.errors) > 0, "expected diagnostics on first parse, got 0")
        local second = parseConfig("/tsconfig.json", cache)
        assert.is_true(core.Len(second.errors) > 0, "expected diagnostics on second parse (cache hit), got 0")
    end)

    it("two configs share same base", function()
        local files = {
            ["/base.json"] = '{\n  "excludes": ["**/*.ts"]\n}',
            ["/projA/tsconfig.json"] = '{\n  "extends": "../base.json"\n}',
            ["/projB/tsconfig.json"] = '{\n  "extends": "../base.json"\n}',
            ["/projA/app.ts"] = "export {}",
            ["/projB/app.ts"] = "export {}",
        }

        local host = tsoptionstest.NewVFSParseConfigHost(files, "/", true --[[useCaseSensitiveFileNames]])
        local parseConfig = makeParseConfig(host)

        local cache = newMemoCache()
        local first = parseConfig("/projA/tsconfig.json", cache)
        assert.is_true(core.Len(first.errors) > 0, "expected diagnostics for projA parse, got 0")
        local second = parseConfig("/projB/tsconfig.json", cache)
        assert.is_true(core.Len(second.errors) > 0, "expected diagnostics for projB parse (cache hit on base), got 0")
    end)
end)

describe("TestExtendedConfigConfigDirPathsAreNotCached", function()
    it("TestExtendedConfigConfigDirPathsAreNotCached", function()
        local files = {
            ["/tsconfig.base.json"] = '{\n  "compilerOptions": {\n    "paths": {\n      "@pkg/*": ["${configDir}/src/*"]\n    }\n  }\n}',
            ["/packages/a/tsconfig.json"] = '{\n  "extends": "../../tsconfig.base.json"\n}',
            ["/packages/b/tsconfig.json"] = '{\n  "extends": "../../tsconfig.base.json"\n}',
            ["/packages/a/index.ts"] = "export {}",
            ["/packages/b/index.ts"] = "export {}",
        }

        local host = tsoptionstest.NewVFSParseConfigHost(files, "/", true --[[useCaseSensitiveFileNames]])
        local cache = newMemoCache()

        local function parseConfig(configFileName)
            local parsed, errors = tsoptions.GetParsedCommandLineOfConfigFile(configFileName, nil, nil, host, cache)
            assert.is_true(core.Len(errors) == 0, "unexpected errors parsing " .. configFileName)
            return parsed
        end

        parseConfig("/packages/a/tsconfig.json")
        local paths = parseConfig("/packages/b/tsconfig.json"):CompilerOptions().paths
        assert.are.same({ "/packages/b/src/*" }, paths:GetOrZero("@pkg/*"))
    end)
end)
