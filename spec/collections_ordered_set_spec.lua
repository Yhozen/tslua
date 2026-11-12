-- Port of internal/collections/ordered_set_test.go.
local collections = require("tslua.collections")

describe("TestOrderedSet", function()
    it("TestOrderedSet", function()
        local s = collections.NewOrderedSet()

        s:Add(1)
        s:Add(2)
        s:Add(3)

        assert.is_true(s:Has(1))
        assert.is_true(s:Has(2))
        assert.is_true(s:Has(3))

        assert.is_true(s:Delete(2))

        local values = {}
        for v in s:Values() do
            values[#values + 1] = v
        end
        assert.are.equal(2, #values)
        assert.is_true(values[1] <= values[2])

        s:Clear()

        assert.are.equal(0, s:Size())
        assert.is_true(not s:Has(1))
        assert.is_true(not s:Has(2))
        assert.is_true(not s:Has(3))

        local s2 = s:Clone()
        assert.is_true(s ~= s2)
        assert.are.equal(0, s2:Size())
    end)
end)

-- TestOrderedSetWithSizeHint measures Go allocations (testing.AllocsPerRun); it has no Lua
-- equivalent. The size-hint constructor is exercised for behavior only.
describe("TestOrderedSetWithSizeHint", function()
    it("TestOrderedSetWithSizeHint", function()
        local N = 1024
        local m = collections.NewOrderedSetWithSizeHint(N)
        for i = 0, N - 1 do
            m:Add(i)
        end
        assert.are.equal(N, m:Size())
    end)
end)
