-- Port of internal/sourcemap/generator_test.go (mechanically transformed by
-- .context/scratch/go-unit-tests/sourcemap/gen.mjs). Go nil *string entries of SourcesContent are
-- `false` in the Lua port; Go errors are message strings.
local sourcemap = require("tslua.sourcemap")
local tspath = require("tslua.tspath")

local function rawSourceMap(t)
    return setmetatable(t, sourcemap.RawSourceMap)
end

describe("TestSourceMapGenerator_Empty", function()
    it("TestSourceMapGenerator_Empty", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = {},
            mappings = "",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_Empty_Serialized", function()
    it("TestSourceMapGenerator_Empty_Serialized", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local actual = gen:String()
        local expected = [[{"version":3,"file":"main.js","sourceRoot":"/","sources":[],"names":[],"mappings":""}]]
        assert.are.equal(expected, actual)
    end)
end)

describe("TestSourceMapGenerator_AddSource", function()
    it("TestSourceMapGenerator_AddSource", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        local sourceMap = gen:RawSourceMap()
        assert.are.equal(0, sourceIndex)
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_SetSourceContent", function()
    it("TestSourceMapGenerator_SetSourceContent", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        local sourceContent = "foo"
        assert.is_nil(gen:SetSourceContent(sourceIndex, sourceContent))
        local sourceMap = gen:RawSourceMap()
        assert.are.equal(0, sourceIndex)
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "",
            names = {},
            sourcesContent = { sourceContent },
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_SetSourceContent_ForSecondSourceOnly", function()
    it("TestSourceMapGenerator_SetSourceContent_ForSecondSourceOnly", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        gen:AddSource("/skipped.ts")
        local sourceIndex = gen:AddSource("/main.ts")
        local sourceContent = "foo"
        assert.is_nil(gen:SetSourceContent(sourceIndex, sourceContent))
        local sourceMap = gen:RawSourceMap()
        assert.are.equal(1, sourceIndex)
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "skipped.ts", "main.ts" },
            mappings = "",
            names = {},
            sourcesContent = { false, sourceContent },
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_SetSourceContent_SourceIndexOutOfRange", function()
    it("TestSourceMapGenerator_SetSourceContent_SourceIndexOutOfRange", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        assert.are.equal("sourceIndex is out of range", gen:SetSourceContent(-1, ""))
        assert.are.equal("sourceIndex is out of range", gen:SetSourceContent(0, ""))
    end)
end)

describe("TestSourceMapGenerator_SetSourceContent_ForSecondSourceOnly_Serialized", function()
    it("TestSourceMapGenerator_SetSourceContent_ForSecondSourceOnly_Serialized", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        gen:AddSource("/skipped.ts")
        local sourceIndex = gen:AddSource("/main.ts")
        local sourceContent = "foo"
        assert.is_nil(gen:SetSourceContent(sourceIndex, sourceContent))
        local actual = gen:String()
        local expected = [[{"version":3,"file":"main.js","sourceRoot":"/","sources":["skipped.ts","main.ts"],"names":[],"mappings":"","sourcesContent":[null,"foo"]}]]
        assert.are.equal(expected, actual)
    end)
end)

describe("TestSourceMapGenerator_AddName", function()
    it("TestSourceMapGenerator_AddName", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local nameIndex = gen:AddName("foo")
        local sourceMap = gen:RawSourceMap()
        assert.are.equal(0, nameIndex)
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = {},
            mappings = "",
            names = { "foo" },
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddGeneratedMapping", function()
    it("TestSourceMapGenerator_AddGeneratedMapping", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        assert.is_nil(gen:AddGeneratedMapping(0, 0))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = {},
            mappings = "A",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddGeneratedMapping_OnSecondLineOnly", function()
    it("TestSourceMapGenerator_AddGeneratedMapping_OnSecondLineOnly", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        assert.is_nil(gen:AddGeneratedMapping(1, 0))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = {},
            mappings = ";A",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping", function()
    it("TestSourceMapGenerator_AddSourceMapping", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(0, 0, sourceIndex, 0, 0))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAA",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_NextGeneratedCharacter", function()
    it("TestSourceMapGenerator_AddSourceMapping_NextGeneratedCharacter", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(0, 0, sourceIndex, 0, 0))
        assert.is_nil(gen:AddSourceMapping(0, 1, sourceIndex, 0, 0))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAA,CAAA",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_NextGeneratedAndSourceCharacter", function()
    it("TestSourceMapGenerator_AddSourceMapping_NextGeneratedAndSourceCharacter", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(0, 0, sourceIndex, 0, 0))
        assert.is_nil(gen:AddSourceMapping(0, 1, sourceIndex, 0, 1))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAA,CAAC",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_NextGeneratedLine", function()
    it("TestSourceMapGenerator_AddSourceMapping_NextGeneratedLine", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(0, 0, sourceIndex, 0, 0))
        assert.is_nil(gen:AddSourceMapping(1, 0, sourceIndex, 0, 0))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAA;AAAA",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_PreviousSourceCharacter", function()
    it("TestSourceMapGenerator_AddSourceMapping_PreviousSourceCharacter", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(0, 0, sourceIndex, 0, 1))
        assert.is_nil(gen:AddSourceMapping(0, 1, sourceIndex, 0, 0))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAC,CAAD",
            names = {},
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        local nameIndex = gen:AddName("foo")
        assert.is_nil(gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, 0, nameIndex))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAAA",
            names = { "foo" },
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_WithPreviousName", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_WithPreviousName", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        local nameIndex1 = gen:AddName("foo")
        local nameIndex2 = gen:AddName("bar")
        assert.is_nil(gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, 0, nameIndex2))
        assert.is_nil(gen:AddNamedSourceMapping(0, 1, sourceIndex, 0, 0, nameIndex1))
        local sourceMap = gen:RawSourceMap()
        assert.are.same(rawSourceMap({
            version = 3,
            file = "main.js",
            sourceRoot = "/",
            sources = { "main.ts" },
            mappings = "AAAAC,CAAAD",
            names = { "foo", "bar" },
            sourcesContent = nil,
        }), sourceMap)
    end)
end)

describe("TestSourceMapGenerator_AddGeneratedMapping_GeneratedLineCannotBacktrack", function()
    it("TestSourceMapGenerator_AddGeneratedMapping_GeneratedLineCannotBacktrack", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        assert.is_nil(gen:AddGeneratedMapping(1, 0))
        assert.are.equal("generatedLine cannot backtrack", gen:AddGeneratedMapping(0, 0))
    end)
end)

describe("TestSourceMapGenerator_AddGeneratedMapping_GeneratedCharacterCannotBeNegative", function()
    it("TestSourceMapGenerator_AddGeneratedMapping_GeneratedCharacterCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        assert.is_nil(gen:AddGeneratedMapping(0, 0))
        assert.are.equal("generatedCharacter cannot be negative", gen:AddGeneratedMapping(0, -1))
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_GeneratedLineCannotBacktrack", function()
    it("TestSourceMapGenerator_AddSourceMapping_GeneratedLineCannotBacktrack", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(1, 0, sourceIndex, 0, 0))
        assert.are.equal("generatedLine cannot backtrack", gen:AddSourceMapping(0, 0, sourceIndex, 0, 0))
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_GeneratedCharacterCannotBeNegative", function()
    it("TestSourceMapGenerator_AddSourceMapping_GeneratedCharacterCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.is_nil(gen:AddSourceMapping(0, 0, sourceIndex, 0, 0))
        assert.are.equal("generatedCharacter cannot be negative", gen:AddSourceMapping(0, -1, sourceIndex, 0, 0))
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_SourceIndexIsOutOfRange", function()
    it("TestSourceMapGenerator_AddSourceMapping_SourceIndexIsOutOfRange", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        assert.are.equal("sourceIndex is out of range", gen:AddSourceMapping(0, 0, -1, 0, 0))
        assert.are.equal("sourceIndex is out of range", gen:AddSourceMapping(0, 0, 0, 0, 0))
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_SourceLineCannotBeNegative", function()
    it("TestSourceMapGenerator_AddSourceMapping_SourceLineCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.are.equal("sourceLine cannot be negative", gen:AddSourceMapping(0, 0, sourceIndex, -1, 0))
    end)
end)

describe("TestSourceMapGenerator_AddSourceMapping_SourceCharacterCannotBeNegative", function()
    it("TestSourceMapGenerator_AddSourceMapping_SourceCharacterCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.are.equal("sourceCharacter cannot be negative", gen:AddSourceMapping(0, 0, sourceIndex, 0, -1))
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_GeneratedLineCannotBacktrack", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_GeneratedLineCannotBacktrack", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        local nameIndex = gen:AddName("foo")
        assert.is_nil(gen:AddNamedSourceMapping(1, 0, sourceIndex, 0, 0, nameIndex))
        assert.are.equal("generatedLine cannot backtrack", gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, 0, nameIndex))
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_GeneratedCharacterCannotBeNegative", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_GeneratedCharacterCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        local nameIndex = gen:AddName("foo")
        assert.is_nil(gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, 0, nameIndex))
        assert.are.equal("generatedCharacter cannot be negative", gen:AddNamedSourceMapping(0, -1, sourceIndex, 0, 0, nameIndex))
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_SourceIndexIsOutOfRange", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_SourceIndexIsOutOfRange", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local nameIndex = gen:AddName("foo")
        assert.are.equal("sourceIndex is out of range", gen:AddNamedSourceMapping(0, 0, -1, 0, 0, nameIndex))
        assert.are.equal("sourceIndex is out of range", gen:AddNamedSourceMapping(0, 0, 0, 0, 0, nameIndex))
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_SourceLineCannotBeNegative", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_SourceLineCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local nameIndex = gen:AddName("foo")
        local sourceIndex = gen:AddSource("/main.ts")
        assert.are.equal("sourceLine cannot be negative", gen:AddNamedSourceMapping(0, 0, sourceIndex, -1, 0, nameIndex))
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_SourceCharacterCannotBeNegative", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_SourceCharacterCannotBeNegative", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local nameIndex = gen:AddName("foo")
        local sourceIndex = gen:AddSource("/main.ts")
        assert.are.equal("sourceCharacter cannot be negative", gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, -1, nameIndex))
    end)
end)

describe("TestSourceMapGenerator_AddNamedSourceMapping_NameIndexIsOutOfRange", function()
    it("TestSourceMapGenerator_AddNamedSourceMapping_NameIndexIsOutOfRange", function()
        local gen = sourcemap.NewGenerator("main.js", "/", "/", tspath.NewComparePathsOptions(false, ""))
        local sourceIndex = gen:AddSource("/main.ts")
        assert.are.equal("nameIndex is out of range", gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, 0, -1))
        assert.are.equal("nameIndex is out of range", gen:AddNamedSourceMapping(0, 0, sourceIndex, 0, 0, 0))
    end)
end)
