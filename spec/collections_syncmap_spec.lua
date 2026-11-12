-- Port of internal/collections/syncmap_test.go.
local collections = require("tslua.collections")

describe("TestSyncMapWithNil", function()
    it("TestSyncMapWithNil", function()
        local m = collections.NewSyncMap()

        local got1, ok = m:Load("foo")
        assert.is_true(not ok)
        assert.is_nil(got1)

        m:Store("foo", nil)

        local got2
        got2, ok = m:Load("foo")
        assert.is_true(ok)
        assert.is_nil(got2)

        local too, loaded = m:LoadOrStore("too", nil)
        assert.is_true(not loaded)
        assert.is_nil(too)

        m:Range(function(k, v)
            return true
        end)
    end)
end)
