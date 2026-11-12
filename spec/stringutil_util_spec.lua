-- Port of internal/stringutil/util_test.go.
local stringutil = require("tslua.stringutil")

describe("TestEncodeURI", function()
    local tests = {
        { name = "encodes spaces as percent20", input = "a b", expected = "a%20b" },
        { name = "preserves reserved uri characters", input = ";/?:@&=+$,#", expected = ";/?:@&=+$,#" },
        {
            name = "encodes brackets and unicode using utf8 bytes",
            input = "①Ⅻㄨㄩ U1[abc]",
            expected = "%E2%91%A0%E2%85%AB%E3%84%A8%E3%84%A9%20U1%5Babc%5D",
        },
    }

    for _, tt in ipairs(tests) do
        it(tt.name, function()
            assert.are.equal(tt.expected, stringutil.EncodeURI(tt.input))
        end)
    end
end)
