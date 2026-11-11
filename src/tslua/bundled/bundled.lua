-- Package bundled provides access to files bundled with TypeScript.
local bundled = require("tslua.bundled")
local tspath = require("tslua.tspath")

-- Embedded is true if the bundled files are implemented through an embedded FS.
-- (bundled.Embedded comes from the generated constants: the Lua port always serves the libs
-- through the bundled:/// scheme, reading src/tslua/bundled/libs lazily.)

-- WrapFS returns an FS which redirects embedded paths to the embedded file system.
-- If the embedded file system is not available, it returns the original FS.
function bundled.WrapFS(fs)
    return bundled.wrapFS(fs)
end

-- LibPath returns the path to the directory containing the bundled lib.d.ts files.
-- If embedding is not enabled, this is a path on disk, and must be accessed through
-- a real OS filesystem.
function bundled.LibPath()
    return bundled.libPath()
end

local bundledSourceDirValue = nil

-- The directory of this source file (Go: runtime.Caller(0)), made absolute.
function bundled.bundledSourceDir()
    if bundledSourceDirValue == nil then
        local src = debug.getinfo(1, "S").source
        if string.sub(src, 1, 1) ~= "@" then
            error("bundled: could not get current filename", 0)
        end
        local filename = tspath.NormalizeSlashes(string.sub(src, 2))
        if not tspath.PathIsAbsolute(filename) then
            local cwd = os.getenv("PWD")
            if cwd == nil or cwd == "" then
                local p = io.popen("pwd")
                cwd = p and p:read("l") or "."
                if p then
                    p:close()
                end
            end
            filename = tspath.CombinePaths(tspath.NormalizeSlashes(cwd), filename)
        end
        bundledSourceDirValue = tspath.GetDirectoryPath(tspath.NormalizePath(filename))
    end
    return bundledSourceDirValue
end

-- TestingLibPath returns the path to the source bundled libs directory.
-- It's only valid to use in tests where the source code is available.
function bundled.TestingLibPath()
    return tspath.NormalizeSlashes(tspath.CombinePaths(bundled.bundledSourceDir(), "libs"))
end

return bundled
