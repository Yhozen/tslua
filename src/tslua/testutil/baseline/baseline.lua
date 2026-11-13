local baseline = require("tslua.testutil.baseline")
local regexp = require("tslua.regexp")
local repo = require("tslua.repo")
local stringutil = require("tslua.stringutil")

-- Options: { subfolder = "", isSubmodule = false, isSubmoduleAccepted = false,
--   isSubmoduleTriaged = false, diffFixupOld = func(string) string or nil,
--   diffFixupNew = func(string) string or nil, skipDiffWithOld = false }

-- Lua-only: optional observer called as comparisonHook(t, localPath, referencePath, matched)
-- after every comparison, so the CLI can report which baseline files differ.
baseline.comparisonHook = nil

local function join(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        if p ~= nil and p ~= "" then
            parts[#parts + 1] = p
        end
    end
    local s = table.concat(parts, "/")
    s = string.gsub(s, "/+", "/")
    return s
end
baseline.join = join

local function readFile(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local data, _, code = f:read("a")
    f:close()
    if data == nil or code ~= nil then
        return nil
    end
    return data
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f == nil then
        return false
    end
    f:close()
    return true
end

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local madeDirs = {}

local function mkdirAll(dir)
    if madeDirs[dir] then
        return true
    end
    local ok = os.execute("mkdir -p -- " .. shellQuote(dir))
    if ok == true then
        madeDirs[dir] = true
    end
    return ok == true
end

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if f == nil then
        return err
    end
    f:write(data)
    f:close()
    return nil
end

local function dirname(p)
    return string.match(p, "^(.*)/[^/]*$") or "."
end

function baseline.Run(t, fileName, actual, opts)
    local origSubfolder = opts.subfolder or ""

    do
        local subfolder = origSubfolder
        if opts.isSubmodule then
            subfolder = join("submodule", subfolder)
        end

        local localPath = join(baseline.localRoot(), subfolder, fileName)
        local referencePath = join(baseline.referenceRoot(), subfolder, fileName)

        -- Record this baseline for tracking unused baselines
        baseline.recordBaseline(t, join(subfolder, fileName))

        baseline.writeComparison(t, actual, localPath, referencePath, false)
    end

    if not opts.isSubmodule or opts.skipDiffWithOld then
        -- Not a submodule, no diffs.
        return
    end

    local submoduleReference = join(baseline.submoduleReferenceRoot(), fileName)
    local submoduleExpected = baseline.readFileOrNoContent(submoduleReference)

    local submoduleFolder = "submodule"
    local submoduleAcceptedFolder = "submoduleAccepted"
    local submoduleTriagedFolder = "submoduleTriaged"

    local diffFileName = fileName .. ".diff"
    local diffKey = origSubfolder .. "/" .. diffFileName
    local isSubmoduleAccepted = opts.isSubmoduleAccepted or baseline.submoduleAcceptedFileNames()[diffKey] == true
    local isSubmoduleTriaged = opts.isSubmoduleTriaged or baseline.submoduleTriagedFileNames()[diffKey] == true

    if isSubmoduleAccepted and isSubmoduleTriaged then
        t:Fatalf("diff file %s/%s is in both submoduleAccepted and submoduleTriaged; it should only be in one", origSubfolder, diffFileName)
    end

    local outRoot
    if isSubmoduleAccepted then
        outRoot = submoduleAcceptedFolder
    elseif isSubmoduleTriaged then
        outRoot = submoduleTriagedFolder
    else
        outRoot = submoduleFolder
    end

    local allRoots = { submoduleFolder, submoduleAcceptedFolder, submoduleTriagedFolder }

    local diff = baseline.getBaselineDiff(t, actual, submoduleExpected, fileName, opts.diffFixupOld, opts.diffFixupNew)

    for _, root in ipairs(allRoots) do
        local localPath = join(baseline.localRoot(), root, origSubfolder, diffFileName)
        local referencePath = join(baseline.referenceRoot(), root, origSubfolder, diffFileName)

        -- Record this baseline for tracking unused baselines
        baseline.recordBaseline(t, join(root, origSubfolder, diffFileName))

        if root == outRoot then
            baseline.writeComparison(t, diff, localPath, referencePath, false)
        else
            baseline.writeComparison(t, baseline.NoContent, localPath, referencePath, false)
        end
    end
end

local submoduleAcceptedFileNamesValue = nil
local submoduleTriagedFileNamesValue = nil

-- Returns a set (table name -> true), like Go's *collections.Set[string].
function baseline.submoduleAcceptedFileNames()
    if submoduleAcceptedFileNamesValue == nil then
        submoduleAcceptedFileNamesValue = baseline.readFileNameSet(join(repo.TestDataPath(), "submoduleAccepted.txt"))
    end
    return submoduleAcceptedFileNamesValue
end

function baseline.submoduleTriagedFileNames()
    if submoduleTriagedFileNamesValue == nil then
        submoduleTriagedFileNamesValue = baseline.readFileNameSet(join(repo.TestDataPath(), "submoduleTriaged.txt"))
    end
    return submoduleTriagedFileNamesValue
end

function baseline.readFileNameSet(path)
    local set = {}

    local content = readFile(path)
    if content ~= nil then
        for line in string.gmatch(content .. "\n", "([^\n]*)\n") do
            line = string.match(line, "^%s*(.-)%s*$")
            if line == "" or string.sub(line, 1, 1) == "#" then
                goto continue
            end
            set[line] = true
            ::continue::
        end
    else
        error(string.format("failed to read file %s", path), 0)
    end

    return set
end

function baseline.readFileOrNoContent(fileName)
    local content = readFile(fileName)
    if content == nil then
        return baseline.NoContent
    end
    return content
end

function baseline.DiffText(oldName, newName, expected, actual)
    local patience = baseline.patience
    local lines = patience.Diff(stringutil.SplitLines(expected), stringutil.SplitLines(actual))
    return patience.UnifiedDiffTextWithOptions(lines, {
        precontext = 3,
        postcontext = 3,
        srcHeader = oldName,
        dstHeader = newName,
    })
end

function baseline.getBaselineDiff(t, actual, expected, fileName, fixupOld, fixupNew)
    if fixupOld ~= nil then
        expected = fixupOld(expected)
    end
    if fixupNew ~= nil then
        actual = fixupNew(actual)
    end
    if actual == expected then
        return baseline.NoContent
    end
    local s = baseline.DiffText("old." .. fileName, "new." .. fileName, expected, actual)

    -- If the diff is empty (just headers, no hunks), return NoContent
    if not string.find(s, "@@", 1, true) then
        return baseline.NoContent
    end

    -- Remove line numbers from unified diff headers; this avoids adding/deleting
    -- lines in our baselines from causing knock-on header changes later in the diff.

    local aCurLine = 1
    local bCurLine = 1
    s = baseline.fixUnifiedDiff:ReplaceAllStringFunc(s, function(match)
        -- fmt.Sscanf(match, "@@ -%d,%d +%d,%d @@", &aLine, &aLineCount, &bLine, &bLineCount)
        local aLine, _, bLine, _ = string.match(match, "^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@$")
        if aLine == nil then
            error("failed to parse unified diff header: " .. match, 0)
        end
        aLine = math.tointeger(tonumber(aLine))
        bLine = math.tointeger(tonumber(bLine))
        local aDiff = aLine - aCurLine
        local bDiff = bLine - bCurLine
        aCurLine = aLine
        bCurLine = bLine

        -- Keep surrounded by @@, to make GitHub's grammar happy.
        -- https://github.com/textmate/diff.tmbundle/blob/0593bb775eab1824af97ef2172fd38822abd97d7/Syntaxes/Diff.plist#L68
        return "@@= skipped -" .. aDiff .. ", +" .. bDiff .. " lines =@@"
    end)

    return s
end

baseline.fixUnifiedDiff = regexp.MustCompile("@@ -\\d+,\\d+ \\+\\d+,\\d+ @@")

function baseline.RunAgainstSubmodule(t, fileName, actual, opts)
    -- Record this baseline for tracking unused baselines
    baseline.recordBaseline(t, join(opts.subfolder, fileName))

    local localPath = join(baseline.localRoot(), opts.subfolder, fileName)
    local reference = join(baseline.submoduleReferenceRoot(), opts.subfolder, fileName)
    baseline.writeComparison(t, actual, localPath, reference, true)
end

-- Local baselines are only written when they differ from the reference (like Go); references
-- are never written.
function baseline.writeComparison(t, actualContent, localPath, reference, comparingAgainstSubmodule)
    if actualContent == "" then
        error("the generated content was \"\". Return 'baseline.NoContent' if no baselining is required.", 0)
    end

    if not mkdirAll(dirname(localPath)) then
        t:Error(string.format("failed to create directories for the local baseline file %s", localPath))
        return
    end

    if fileExists(localPath) then
        local ok, err = os.remove(localPath)
        if not ok then
            t:Error(string.format("failed to remove the local baseline file %s: %s", localPath, tostring(err)))
            return
        end
    end
    os.remove(localPath .. ".delete")

    local expected = baseline.NoContent
    local foundExpected = false
    local content = readFile(reference)
    if content ~= nil then
        expected = content
        foundExpected = true
    end

    local matched = true
    if expected ~= actualContent or actualContent == baseline.NoContent and foundExpected then
        matched = false
        if actualContent == baseline.NoContent then
            local err = writeFile(localPath .. ".delete", "")
            if err ~= nil then
                t:Error(string.format("failed to write the local baseline file %s: %s", localPath .. ".delete", tostring(err)))
                return
            end
        else
            local err = writeFile(localPath, actualContent)
            if err ~= nil then
                t:Error(string.format("failed to write the local baseline file %s: %s", localPath, tostring(err)))
                return
            end
        end

        if not fileExists(reference) then
            if comparingAgainstSubmodule then
                t:Errorf("the baseline file %s does not exist in the TypeScript submodule", reference)
            else
                t:Errorf("new baseline created at %s.", localPath)
            end
        elseif comparingAgainstSubmodule then
            t:Errorf("the baseline file %s does not match the reference in the TypeScript submodule", reference)
        else
            t:Errorf("the baseline file %s has changed. (Run `hereby baseline-accept` if the new baseline is correct.)", reference)
        end
    end
    if baseline.comparisonHook ~= nil then
        baseline.comparisonHook(t, localPath, reference, matched)
    end
end

-- Go: package vars localRoot, referenceRoot, submoduleReferenceRoot. The local root is the tslua
-- repository's tests/out (overridable with TSLUA_TEST_OUT), not testdata/baselines/local.
function baseline.localRoot()
    local env = os.getenv("TSLUA_TEST_OUT")
    if env ~= nil and env ~= "" then
        return env
    end
    return join(repo.TsluaRootPath(), "tests", "out")
end

function baseline.referenceRoot()
    return join(repo.TestDataPath(), "baselines", "reference")
end

function baseline.submoduleReferenceRoot()
    return join(repo.TypeScriptSubmodulePath(), "tests", "baselines", "reference")
end

return baseline
