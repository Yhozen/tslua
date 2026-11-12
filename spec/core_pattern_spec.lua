-- Port of internal/core/pattern_test.go.
local core = require("tslua.core")

describe("TestPatternOverlappingMatch", function()
    it("TestPatternOverlappingMatch", function()
        local p = core.TryParsePattern("ab*ab")
        assert.is_false(p:Matches("ab"), "expected 'ab' not to match 'ab*ab'")
        assert.is_true(p:Matches("abXab"), "expected 'abXab' to match 'ab*ab'")
        assert.are.equal("X", p:MatchedText("abXab"))
        assert.is_true(p:Matches("abab"), "expected 'abab' to match 'ab*ab'")
        assert.are.equal("", p:MatchedText("abab"))
    end)
end)
