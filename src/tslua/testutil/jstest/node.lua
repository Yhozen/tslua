local jstest = require("tslua.testutil.jstest")
local json = require("tslua.json")
local repo = require("tslua.repo")
local tspath = require("tslua.tspath")

-- t is a Go testing.TB stand-in: it needs Helper(), Skip(msg) and Fatal(msg) methods
-- (tslua.testutil's T, or an adapter around busted's pending/error).

local loaderScript = [[import script from "./script.mjs";
process.stdout.write(JSON.stringify(await script(...process.argv.slice(2))));]]

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local nodeExe = nil

function jstest.getNodeExeOnce()
    if nodeExe == nil then
        local exeName = "node"
        local p = io.popen("command -v " .. exeName .. " 2>/dev/null")
        local exe = p and p:read("l") or nil
        if p then
            p:close()
        end
        nodeExe = exe or ""
    end
    return nodeExe
end

-- EvalNodeScript imports a Node.js script that default-exports a single function,
-- calls it with the provided arguments, and unmarshals the JSON-stringified
-- awaited return value. Returns (result, err).
function jstest.EvalNodeScript(t, script, dir, ...)
    return jstest.evalNodeScript(t, script, loaderScript, dir, ...)
end

-- EvalNodeScriptWithTS is like EvalNodeScript, but provides the TypeScript
-- library to the script as the first argument.
function jstest.EvalNodeScriptWithTS(t, script, dir, ...)
    if dir == "" then
        dir = t:TempDir()
    end
    local tsSrc = tspath.NormalizePath(repo.RootPath() .. "/node_modules/typescript/lib/typescript.js")
    if string.sub(tsSrc, 1, 1) == "/" then
        tsSrc = "file://" .. tsSrc
    else
        tsSrc = "file:///" .. tsSrc
    end
    local tsLoaderScript = string.format([[import script from "./script.mjs";
import * as ts from "%s";
process.stdout.write(JSON.stringify(await script(ts, ...process.argv.slice(2))));]], tsSrc)
    return jstest.evalNodeScript(t, script, tsLoaderScript, dir, ...)
end

function jstest.SkipIfNoNodeJS(t)
    t:Helper()
    if jstest.getNodeExeOnce() == "" then
        t:Skip("Node.js not found")
    end
end

local function writeFile(path, contents)
    local f, err = io.open(path, "wb")
    if f == nil then
        return err
    end
    f:write(contents)
    f:close()
    return nil
end

function jstest.evalNodeScript(t, script, loader, dir, ...)
    t:Helper()
    local exe = jstest.getNodeExe(t)
    local scriptPath = dir .. "/script.mjs"
    local err = writeFile(scriptPath, script)
    if err ~= nil then
        return nil, err
    end
    local loaderPath = dir .. "/loader.mjs"
    err = writeFile(loaderPath, loader)
    if err ~= nil then
        return nil, err
    end

    local execArgs = { shellQuote(exe), shellQuote(loaderPath) }
    for _, arg in ipairs({ ... }) do
        execArgs[#execArgs + 1] = shellQuote(arg)
    end
    local p = io.popen("cd " .. shellQuote(dir) .. " && " .. table.concat(execArgs, " ") .. " 2>&1")
    local output = p:read("a")
    local ok = p:close()
    if not ok then
        return nil, "failed to run node: exit status\n" .. output
    end

    local result
    result, err = json.Unmarshal(output)
    if err ~= nil then
        return nil, "failed to unmarshal JSON output: " .. tostring(err)
    end

    return result, nil
end

function jstest.getNodeExe(t)
    local exe = jstest.getNodeExeOnce()
    if exe ~= "" then
        return exe
    end
    t:Fatal("Node.js not found")
    return ""
end
