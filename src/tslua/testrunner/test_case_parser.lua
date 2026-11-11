local testrunner = require("tslua.testrunner")
local ast = require("tslua.ast")
local core = require("tslua.core")
local harnessutil = require("tslua.testutil.harnessutil")
local parser = require("tslua.parser")
local scanner = require("tslua.scanner")
local tsoptions = require("tslua.tsoptions")
local tsoptionstest = require("tslua.tsoptions.tsoptionstest")
local tspath = require("tslua.tspath")

-- The Go regexps of this file are ported as hand-written matchers with the same methods and RE2
-- semantics (\s = [\t\n\f\r ], \w = [0-9A-Za-z_], greedy quantifiers).

local function isSpace(b)
    return b == 32 or b == 9 or b == 10 or b == 12 or b == 13
end

local function isWord(b)
    return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

local function skipSpaces(s, i)
    local n = #s
    while i <= n and isSpace(string.byte(s, i)) do
        i = i + 1
    end
    return i
end

-- [^\r\n]* starting at i; returns the end (exclusive).
local function skipLine(s, i)
    local j = string.find(s, "[\r\n]", i)
    if j == nil then
        return #s + 1
    end
    return j
end

-- lineDelimiter = regexp.MustCompile("\r?\n")
testrunner.lineDelimiter = {
    Split = function(self, s)
        if s == "" then
            return { "" }
        end
        local parts = {}
        local beg = 1
        while true do
            local j = string.find(s, "\n", beg, true)
            if j == nil then
                break
            end
            local e = j
            if j > beg and string.byte(s, j - 1) == 13 then
                e = j - 1
            end
            parts[#parts + 1] = string.sub(s, beg, e - 1)
            beg = j + 1
        end
        parts[#parts + 1] = string.sub(s, beg)
        return parts
    end,
}

-- rawCompilerSettings maps a compiler setting to its value as written in the test file. For example, if a test file contains:
--
--	// @target: esnext, es2015
--
-- Then the map will map "target" to "esnext, es2015"

-- testUnit: all the necessary information to turn a multi file test into useful units for later
-- compilation: { content = "", name = "" }

-- testCaseContent: { testUnitData = []testUnit, tsConfig = *tsoptions.ParsedCommandLine,
-- tsConfigFileUnitData = testUnit, symlinks = map }

-- Regex for parsing options in the format "@Alpha: Value of any sort"
-- optionRegex = regexp.MustCompile(`(?m)^\/{2}\s*@(\w+)\s*:\s*([^\r\n]*)`)
testrunner.optionRegex = {
    -- Tries a match at i (which must be a line start). Returns name, value, end (exclusive) or nil.
    matchAt = function(s, i)
        if string.sub(s, i, i + 1) ~= "//" then
            return nil
        end
        local j = skipSpaces(s, i + 2)
        if string.byte(s, j) ~= 64 then -- '@'
            return nil
        end
        j = j + 1
        local nameStart = j
        while isWord(string.byte(s, j)) do
            j = j + 1
        end
        if j == nameStart then
            return nil
        end
        local name = string.sub(s, nameStart, j - 1)
        j = skipSpaces(s, j)
        if string.byte(s, j) ~= 58 then -- ':'
            return nil
        end
        j = skipSpaces(s, j + 1)
        local valueEnd = skipLine(s, j)
        return name, string.sub(s, j, valueEnd - 1), valueEnd
    end,
    -- Returns { full, name, value } or nil.
    FindStringSubmatch = function(self, s)
        local pos = 1
        local n = #s
        while pos <= n + 1 do
            local name, value, e = self.matchAt(s, pos)
            if name ~= nil then
                return { string.sub(s, pos, e - 1), name, value }
            end
            local nl = string.find(s, "\n", pos, true)
            if nl == nil then
                break
            end
            pos = nl + 1
        end
        return nil
    end,
    FindAllStringSubmatch = function(self, s)
        local result = {}
        local pos = 1
        local n = #s
        local minPos = 1
        while pos <= n do
            if pos >= minPos then
                local name, value, e = self.matchAt(s, pos)
                if name ~= nil then
                    result[#result + 1] = { string.sub(s, pos, e - 1), name, value }
                    minPos = e
                end
            end
            local nl = string.find(s, "\n", pos, true)
            if nl == nil then
                break
            end
            pos = nl + 1
        end
        return result
    end,
}

-- Regex for parsing @link option
-- linkRegex = regexp.MustCompile(`(?m)^\/{2}\s*@link\s*:\s*([^\r\n]*)\s*->\s*([^\r\n]*)`)
testrunner.linkRegex = {
    matchAt = function(s, i)
        if string.sub(s, i, i + 1) ~= "//" then
            return nil
        end
        local j = skipSpaces(s, i + 2)
        if string.sub(s, j, j + 4) ~= "@link" then
            return nil
        end
        j = skipSpaces(s, j + 5)
        if string.byte(s, j) ~= 58 then -- ':'
            return nil
        end
        j = skipSpaces(s, j + 1)
        local g1Start = j
        local lineEnd = skipLine(s, g1Start)
        -- greedy group 1: try the longest prefix first
        for g1End = lineEnd, g1Start, -1 do
            local k = skipSpaces(s, g1End)
            if string.sub(s, k, k + 1) == "->" then
                local g2Start = skipSpaces(s, k + 2)
                local g2End = skipLine(s, g2Start)
                return string.sub(s, g1Start, g1End - 1), string.sub(s, g2Start, g2End - 1), g2End
            end
        end
        return nil
    end,
    -- Returns { full, target, link } or nil.
    FindStringSubmatch = function(self, s)
        local pos = 1
        local n = #s
        while pos <= n + 1 do
            local g1, g2, e = self.matchAt(s, pos)
            if g1 ~= nil then
                return { string.sub(s, pos, e - 1), g1, g2 }
            end
            local nl = string.find(s, "\n", pos, true)
            if nl == nil then
                break
            end
            pos = nl + 1
        end
        return nil
    end,
}

-- File-specific directives used by fourslash tests
testrunner.fourslashDirectives = { "emitthisfile", "noopen" }

local function trimSpace(s)
    return (string.match(s, "^%s*(.-)%s*$"))
end

local function contains(xs, x)
    for _, v in ipairs(xs) do
        if v == x then
            return true
        end
    end
    return false
end

-- Given a test file containing // @FileName directives,
-- return an array of named units of code to be added to an existing compiler instance.
function testrunner.makeUnitsFromTest(code, fileName)
    local testUnits, symlinks, currentDirectory, globalOptions = testrunner.ParseTestFilesAndSymlinks(
        code,
        fileName,
        function(filename, content, fileOptions)
            return { content = content, name = filename }, nil
        end
    )

    if currentDirectory == "" then
        currentDirectory = testrunner.srcFolder
    end

    -- unit tests always list files explicitly
    local allFiles = {}
    for _, data in ipairs(testUnits) do
        allFiles[tspath.GetNormalizedAbsolutePath(data.name, currentDirectory)] = data.content
    end
    local parseConfigHost = tsoptionstest.NewVFSParseConfigHostWithSymlinks(allFiles, symlinks, currentDirectory, true --[[useCaseSensitiveFileNames]])

    -- Content mappers are gated behind --runExternalCode, a command-line-only option. A test
    -- opts in with a top-level `// @runExternalCode: true`, which we surface to the config
    -- parse as an existing option so the gate passes and the mappers register.
    local existingOptions = nil
    if globalOptions["runexternalcode"] == "true" then
        existingOptions = core.NewCompilerOptions({ runExternalCode = core.Tristate.TSTrue })
    end

    -- check if project has tsconfig.json in the list of files
    local tsConfig = nil
    local tsConfigFileUnitData = nil
    for i, data in ipairs(testUnits) do
        if harnessutil.GetConfigNameFromFileName(data.name) ~= "" then
            local configFileName = tspath.GetNormalizedAbsolutePath(data.name, currentDirectory)
            local path = tspath.ToPath(data.name, parseConfigHost:GetCurrentDirectory(), parseConfigHost.vfs:UseCaseSensitiveFileNames())
            local configJson = parser.ParseSourceFile(ast.NewSourceFileParseOptions(configFileName, path), data.content, core.ScriptKind.JSON)
            local tsConfigSourceFile = tsoptions.NewTsConfigSourceFile(configJson)
            local configDir = tspath.GetDirectoryPath(configFileName)
            tsConfig = tsoptions.ParseJsonSourceFileConfigFileContent(
                tsConfigSourceFile,
                parseConfigHost,
                configDir,
                existingOptions,
                nil, --[[existingOptionsRaw]]
                configFileName,
                nil, --[[resolutionStack]]
                nil --[[extendedConfigCache]]
            )
            tsConfigFileUnitData = data

            -- delete tsconfig file entry from the list
            table.remove(testUnits, i)
            break
        end
    end

    return {
        testUnitData = testUnits,
        tsConfig = tsConfig,
        tsConfigFileUnitData = tsConfigFileUnitData,
        symlinks = symlinks,
    }
end

-- ParseTestFilesOptions: { allowImplicitFirstFile = bool }
-- If allowImplicitFirstFile is true, allows test content to appear before the first @Filename
-- directive. In this case, an implicit first file is created using the fileName parameter.
-- This matches the behavior of the TypeScript fourslash test harness.

-- Given a test file containing // @FileName and // @symlink directives,
-- return an array of named units of code to be added to an existing compiler instance,
-- along with a map of symlinks and the current directory.
-- Returns units, symlinks, currentDir, globalOptions, err.
function testrunner.ParseTestFilesAndSymlinks(code, fileName, parseFile)
    return testrunner.ParseTestFilesAndSymlinksWithOptions(code, fileName, parseFile, { allowImplicitFirstFile = false })
end

function testrunner.ParseTestFilesAndSymlinksWithOptions(code, fileName, parseFile, options)
    -- List of all the subfiles we've parsed out
    local testUnits = {}

    local lines = testrunner.lineDelimiter:Split(code, -1)

    -- Stuff related to the subfile we're parsing
    local currentFileContent = core.NewStringBuilder()
    local currentFileName = ""
    local seenContentLine = false
    local hasSeenFile = false
    if options.allowImplicitFirstFile then
        -- For fourslash tests, initialize currentFileName to the fileName parameter
        -- so content before the first @Filename directive goes into an implicit first file
        currentFileName = fileName
    end
    local currentDirectory = ""
    local parseError = nil
    local currentFileOptions = {}
    local symlinks = {}
    local globalOptions = {}

    for _, line in ipairs(lines) do
        local ok = testrunner.parseSymlinkFromTest(line, symlinks)
        if ok then
            goto continue
        end
        do
            local testMetaData = testrunner.optionRegex:FindStringSubmatch(line)
            if testMetaData ~= nil then
                -- Comment line, check for global/file @options and record them
                local metaDataName = string.lower(testMetaData[2])
                local metaDataValue = trimSpace(testMetaData[3])
                if metaDataName == "currentdirectory" then
                    currentDirectory = metaDataValue
                end
                if metaDataName ~= "filename" then
                    if metaDataName == "symlink" and currentFileName ~= "" then
                        for link in string.gmatch(metaDataValue .. ",", "([^,]*),") do
                            link = trimSpace(link)
                            if link ~= "" then
                                symlinks[link] = currentFileName
                            end
                        end
                    elseif contains(testrunner.fourslashDirectives, metaDataName) then
                        -- File-specific option
                        currentFileOptions[metaDataName] = metaDataValue
                    else
                        -- Global option
                        -- (!!! A duplicate global option with a different value would break existing
                        -- submodule tests, so it is not reported.)
                        globalOptions[metaDataName] = metaDataValue
                    end
                    goto continue
                end

                -- New metadata statement after having collected some code to go with the previous metadata
                if currentFileName ~= "" then
                    -- Store result file - always save for regular tests, but skip empty implicit first file for fourslash
                    local shouldSaveFile = not options.allowImplicitFirstFile or currentFileContent:Len() ~= 0 or hasSeenFile
                    if shouldSaveFile then
                        hasSeenFile = true
                        local newTestFile, e = parseFile(currentFileName, currentFileContent:String(), currentFileOptions)
                        if e ~= nil then
                            parseError = e
                            break
                        end
                        testUnits[#testUnits + 1] = newTestFile
                    end

                    -- Reset local data
                    currentFileContent:Reset()
                    seenContentLine = false
                    currentFileName = metaDataValue
                    currentFileOptions = {}
                else
                    -- First metadata marker in the file
                    local content = currentFileContent:String()
                    local hasContentBeforeFirstFilename = #content ~= 0 and scanner.SkipTrivia(content, 0) ~= #content
                    if hasContentBeforeFirstFilename and not options.allowImplicitFirstFile then
                        error("Non-comment test content appears before the first '// @Filename' directive", 0)
                    end

                    -- If we have content before the first @Filename and AllowImplicitFirstFile is true,
                    -- we need to save it as an implicit first file before starting the new file
                    if hasContentBeforeFirstFilename and options.allowImplicitFirstFile and currentFileName ~= "" then
                        -- Store the implicit first file
                        hasSeenFile = true
                        local newTestFile, e = parseFile(currentFileName, content, currentFileOptions)
                        if e ~= nil then
                            parseError = e
                            break
                        end
                        testUnits[#testUnits + 1] = newTestFile
                    end

                    -- Reset for the new file
                    currentFileContent:Reset()
                    seenContentLine = false
                    currentFileName = trimSpace(testMetaData[3])
                    currentFileOptions = {}
                end
            else
                -- Subfile content line
                -- Append to the current subfile content, inserting a newline if needed
                -- For fourslash tests, use seenContentLine to preserve leading blank lines
                -- (matching TS fourslash's //// content markers). For compiler tests, use
                -- Len() != 0 which drops leading blanks (matching TS's harness behavior).
                if options.allowImplicitFirstFile then
                    if seenContentLine then
                        currentFileContent:WriteString("\n")
                    end
                    seenContentLine = true
                else
                    if currentFileContent:Len() ~= 0 then
                        currentFileContent:WriteString("\n")
                    end
                end
                currentFileContent:WriteString(line)
            end
        end
        ::continue::
    end

    -- normalize the fileName for the single file case
    if #testUnits == 0 and #currentFileName == 0 then
        currentFileName = tspath.GetBaseFileName(fileName)
    end

    -- if there are no parse errors so far, parse the rest of the file
    if parseError == nil then
        -- EOF, push whatever remains
        local newTestFile2, e = parseFile(currentFileName, currentFileContent:String(), currentFileOptions)

        parseError = e
        testUnits[#testUnits + 1] = newTestFile2
    end

    return testUnits, symlinks, currentDirectory, globalOptions, parseError
end

local function trimSuffixSemicolon(s)
    if string.sub(s, -1) == ";" then
        return string.sub(s, 1, -2)
    end
    return s
end

function testrunner.extractCompilerSettings(content)
    local opts = {}

    for _, match in ipairs(testrunner.optionRegex:FindAllStringSubmatch(content, -1)) do
        opts[string.lower(match[2])] = trimSuffixSemicolon(trimSpace(match[3]))
    end

    return opts
end

function testrunner.parseSymlinkFromTest(line, symlinks)
    local linkMetaData = testrunner.linkRegex:FindStringSubmatch(line)
    if linkMetaData == nil or #linkMetaData == 0 then
        return false
    end

    symlinks[trimSpace(linkMetaData[3])] = trimSpace(linkMetaData[2])
    return true
end

return testrunner
