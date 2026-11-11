local internal = require("tslua.vfs.internal")
local tspath = require("tslua.tspath")
local vfs = require("tslua.vfs")

local iofs = vfs.iofs

-- Common has the fields rootFor(root) -> fs.FS and isReparsePoint(path) -> bool (may be nil).
local Common = {}
Common.__index = Common
internal.Common = Common

function internal.NewCommon(rootFor, isReparsePoint)
    return setmetatable({ rootFor = rootFor, isReparsePoint = isReparsePoint }, Common)
end

function internal.RootLength(p)
    local l = tspath.GetEncodedRootLength(p)
    if l == 0 then
        error(string.format("vfs: path %q is not absolute", p), 0)
    elseif l < 0 then
        return ~l
    end
    return l
end

function internal.SplitPath(p)
    p = tspath.NormalizePath(p)
    local l = internal.RootLength(p)
    local rootName, rest = string.sub(p, 1, l), string.sub(p, l + 1)
    rest = tspath.RemoveTrailingDirectorySeparator(rest)
    return rootName, rest
end

function Common:RootAndPath(path)
    local rootName, rest = internal.SplitPath(path)
    if rest == "" then
        rest = "."
    end
    return self.rootFor(rootName), rootName, rest
end

function Common:Stat(path)
    local fsys, _, rest = self:RootAndPath(path)
    if fsys == nil then
        return nil
    end
    local stat, err = iofs.Stat(fsys, rest)
    if err ~= nil then
        return nil
    end
    return stat
end

function Common:FileExists(path)
    local stat = self:Stat(path)
    return stat ~= nil and not stat:IsDir()
end

function Common:DirectoryExists(path)
    local stat = self:Stat(path)
    return stat ~= nil and stat:IsDir()
end

function Common:GetAccessibleEntries(path)
    -- files/directories are always arrays (possibly empty), never nil, so callers can ipairs them.
    local result = { files = {}, directories = {}, symlinks = {} }

    local function addToResult(name, mode, isLink)
        if iofs.FileMode_IsDir(mode) then
            result.directories[#result.directories + 1] = name
        elseif iofs.FileMode_IsRegular(mode) then
            result.files[#result.files + 1] = name
        else
            return false
        end

        if isLink then
            result.symlinks[name] = true
        end
        return true
    end

    for _, entry in ipairs(self:getEntries(path) or {}) do
        local entryType = entry:Type()

        if addToResult(entry:Name(), entryType, false) then
            goto continue
        end

        if entryType & iofs.ModeSymlink ~= 0 then
            -- Easy case; UNIX-like system will clearly mark symlinks.
            local stat = self:Stat(path .. "/" .. entry:Name())
            if stat ~= nil then
                addToResult(entry:Name(), stat:Mode(), true)
            end
            goto continue
        end

        if entryType & iofs.ModeIrregular ~= 0 and self.isReparsePoint ~= nil then
            -- Could be a Windows junction or other reparse point.
            -- Check using the OS-specific helper.
            local fullPath = path .. "/" .. entry:Name()
            if self.isReparsePoint(fullPath) then
                local stat = self:Stat(fullPath)
                if stat ~= nil then
                    addToResult(entry:Name(), stat:Mode(), true)
                end
            end
            goto continue
        end
        ::continue::
    end

    return result
end

function Common:getEntries(path)
    local fsys, _, rest = self:RootAndPath(path)
    if fsys == nil then
        return nil
    end

    local entries, err = iofs.ReadDir(fsys, rest)
    if err ~= nil then
        return nil
    end

    return entries
end

function Common:WalkDir(root, walkFn)
    local fsys, rootName, rest = self:RootAndPath(root)
    if fsys == nil then
        return nil
    end
    return iofs.WalkDir(fsys, rest, function(path, d, err)
        if path == "." then
            path = ""
        end
        return walkFn(rootName .. path, d, err)
    end)
end

function Common:ReadFile(path)
    local fsys, _, rest = self:RootAndPath(path)
    if fsys == nil then
        return "", false
    end

    local b, err = iofs.ReadFile(fsys, rest)
    if err ~= nil then
        return "", false
    end

    if #b == 0 then
        return "", true
    end

    return internal.decodeBytes(b)
end

function internal.decodeBytes(s)
    if #s >= 2 then
        local b0, b1 = string.byte(s, 1, 2)
        if b0 == 0xFF and b1 == 0xFE then
            return internal.decodeUtf16(string.sub(s, 3), false), true
        elseif b0 == 0xFE and b1 == 0xFF then
            return internal.decodeUtf16(string.sub(s, 3), true), true
        end
    end
    if #s >= 3 then
        local b0, b1, b2 = string.byte(s, 1, 3)
        if b0 == 0xEF and b1 == 0xBB and b2 == 0xBF then
            s = string.sub(s, 4)
        end
    end

    return s, true
end

-- utf16.Decode + string(runes): unpaired surrogates become U+FFFD.
function internal.decodeUtf16(s, bigEndian)
    local n = #s // 2
    local units = {}
    for i = 0, n - 1 do
        local a, b = string.byte(s, 2 * i + 1, 2 * i + 2)
        if bigEndian then
            units[i + 1] = (a << 8) | b
        else
            units[i + 1] = (b << 8) | a
        end
    end
    local out = {}
    local i = 1
    while i <= n do
        local u = units[i]
        if u >= 0xD800 and u < 0xDC00 and i < n and units[i + 1] >= 0xDC00 and units[i + 1] < 0xE000 then
            local r = ((u - 0xD800) << 10 | (units[i + 1] - 0xDC00)) + 0x10000
            out[#out + 1] = utf8.char(r)
            i = i + 2
        else
            if u >= 0xD800 and u < 0xE000 then
                u = 0xFFFD
            end
            out[#out + 1] = utf8.char(u)
            i = i + 1
        end
    end
    return table.concat(out)
end

return internal
