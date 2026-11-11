local repo = require("tslua.repo")

-- Go's repo package finds the typescript-go checkout (the directory with go.mod) from its own
-- source location. In the Lua port the checkout is vendor/typescript-go inside the tslua
-- repository (overridable with TSLUA_UPSTREAM); TsluaRootPath is the tslua repository root.

local function cwd()
    local d = os.getenv("PWD")
    if d == nil or d == "" then
        local p = io.popen("pwd")
        d = p and p:read("l") or "."
        if p then
            p:close()
        end
    end
    return d
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f == nil then
        return false
    end
    f:close()
    return true
end

local function dirname(p)
    return string.match(p, "^(.*)/[^/]*$") or "/"
end

local tsluaRootPath = nil

-- TsluaRootPath (Lua-only) returns the tslua repository root (the directory containing src/tslua).
function repo.TsluaRootPath()
    if tsluaRootPath == nil then
        local src = debug.getinfo(1, "S").source
        if string.sub(src, 1, 1) ~= "@" then
            error("could not get current filename", 0)
        end
        local filename = string.sub(src, 2)
        if string.sub(filename, 1, 1) ~= "/" then
            filename = cwd() .. "/" .. filename
        end
        -- Resolve "." and ".." segments.
        local parts = {}
        for part in string.gmatch(filename, "[^/]+") do
            if part == ".." then
                parts[#parts] = nil
            elseif part ~= "." then
                parts[#parts + 1] = part
            end
        end
        filename = "/" .. table.concat(parts, "/")
        -- <root>/src/tslua/repo/paths.lua
        tsluaRootPath = dirname(dirname(dirname(dirname(filename))))
    end
    return tsluaRootPath
end

local rootPath = nil

function repo.RootPath()
    if rootPath == nil then
        local env = os.getenv("TSLUA_UPSTREAM")
        if env ~= nil and env ~= "" then
            rootPath = env
        else
            rootPath = repo.TsluaRootPath() .. "/vendor/typescript-go"
        end
        if not fileExists(rootPath .. "/go.mod") then
            error("could not find go.mod in " .. rootPath .. " (run `make upstream`)", 0)
        end
    end
    return rootPath
end

function repo.TypeScriptSubmodulePath()
    return repo.RootPath() .. "/_submodules/TypeScript"
end

function repo.TestDataPath()
    return repo.RootPath() .. "/testdata"
end

local typeScriptSubmoduleExists = nil

function repo.TypeScriptSubmoduleExists()
    if typeScriptSubmoduleExists == nil then
        typeScriptSubmoduleExists = fileExists(repo.TypeScriptSubmodulePath() .. "/package.json")
    end
    return typeScriptSubmoduleExists
end

-- SkippableTest interface: Helper(), Skipf(format, ...).

function repo.SkipIfNoTypeScriptSubmodule(t)
    t:Helper()
    if not repo.TypeScriptSubmoduleExists() then
        t:Skipf("TypeScript submodule does not exist")
    end
end

return repo
