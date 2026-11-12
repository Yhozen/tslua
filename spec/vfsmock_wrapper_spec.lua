-- Port of typescript-go internal/vfs/vfsmock/wrapper_test.go.
local vfsmock = require("tslua.vfs.vfsmock")
local vfstest = require("tslua.vfs.vfstest")

-- The exported fields of the Go FSMock struct (Go reflects over them).
local fsMockExportedFields = {
    "AppendFileFunc",
    "ChtimesFunc",
    "DirectoryExistsFunc",
    "FileExistsFunc",
    "GetAccessibleEntriesFunc",
    "ReadFileFunc",
    "RealpathFunc",
    "RemoveFunc",
    "StatFunc",
    "UseCaseSensitiveFileNamesFunc",
    "WalkDirFunc",
    "WriteFileFunc",
}

describe("TestWrap", function()
    it("TestWrap", function()
        local wrapper = vfsmock.Wrap(vfstest.FromMap({}, true))

        for _, name in ipairs(fsMockExportedFields) do
            local field = string.lower(string.sub(name, 1, 1)) .. string.sub(name, 2)
            assert.is_true(wrapper[field] ~= nil, "field " .. name .. " should not be zero; update Wrap")
        end
    end)
end)
