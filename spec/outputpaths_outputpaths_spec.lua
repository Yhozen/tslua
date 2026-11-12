-- Port of internal/outputpaths/outputpaths_test.go.
local outputpaths = require("tslua.outputpaths")

describe("TestGetSourceFilePathInNewDirSourceMatchesCommonDirectory", function()
    it("TestGetSourceFilePathInNewDirSourceMatchesCommonDirectory", function()
        local actual = outputpaths.GetSourceFilePathInNewDir("/project/src", "/project/out", "/project", "/project/src/", true)
        assert.are.equal("/project/src", actual)
    end)
end)

describe("TestGetSourceFilePathInNewDirCanonicalizationShrinksCommonDirectory", function()
    it("TestGetSourceFilePathInNewDirCanonicalizationShrinksCommonDirectory", function()
        -- Each Kelvin sign 'K' case-folds to the single-byte 'k', so the raw
        -- (non-canonicalized) commonSourceDirectory is longer, in bytes, than the source
        -- file path it's a case-insensitive prefix of, even though the file path itself
        -- is longer overall once its own (already-lowercase) suffix is included.
        -- Slicing sourceFilePath by len(commonSourceDirectory) bytes would still panic
        -- here ([14:11]); this must clamp per-rune instead, like the reference
        -- implementation's substring does.
        local actual = outputpaths.GetSourceFilePathInNewDir("/kkkk/a.ts", "/out", "/", "/\u{212A}\u{212A}\u{212A}\u{212A}/", false)
        assert.are.equal("/out/a.ts", actual)
    end)
end)
