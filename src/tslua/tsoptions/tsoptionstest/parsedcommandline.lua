local tsoptionstest = require("tslua.tsoptions.tsoptionstest")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

function tsoptionstest.GetParsedCommandLine(t, jsonText, files, currentDirectory, useCaseSensitiveFileNames)
    local host = tsoptionstest.NewVFSParseConfigHost(files, currentDirectory, useCaseSensitiveFileNames)
    local configFileName = tspath.CombinePaths(currentDirectory, "tsconfig.json")
    local tsconfigSourceFile = tsoptions.NewTsconfigSourceFileFromFilePath(configFileName, tspath.ToPath(configFileName, currentDirectory, useCaseSensitiveFileNames), jsonText)
    return tsoptions.ParseJsonSourceFileConfigFileContent(tsconfigSourceFile, host, currentDirectory, nil, nil, configFileName, nil, nil)
end

return tsoptionstest
