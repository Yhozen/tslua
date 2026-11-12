-- Port of internal/collections/ordered_map_test.go.
-- luacheck: ignore 512
-- Generic zero values: Lua generic containers return nil where Go returns the zero value of V.
local collections = require("tslua.collections")
local json = require("tslua.json")

local function padInt(n)
    return string.format("%10d", n)
end

local function collect(iter)
    local out = {}
    for v in iter do
        out[#out + 1] = v
    end
    return out
end

local function isSorted(xs)
    for i = 2, #xs do
        if xs[i] < xs[i - 1] then
            return false
        end
    end
    return true
end

describe("TestOrderedMap", function()
    it("TestOrderedMap", function()
        local m = collections.NewOrderedMap()

        assert.is_true(not m:Has(1))

        local N = 1000
        local start = 1
        local end_ = start + N

        -- Seed the map with ascending keys and values for easier testing.
        for i = start, end_ - 1 do
            m:Set(i, padInt(i))
        end

        assert.are.equal(N, m:Size())

        -- Attempt to overwrite existing keys in reverse order.
        for i = end_ - 1, start, -1 do
            m:Set(i, padInt(i))
        end

        assert.are.equal(N, m:Size())

        for i = start, end_ - 1 do
            local v, ok = m:Get(i)
            assert.is_true(ok)
            assert.are.equal(padInt(i), v)
        end

        for k, v in m:Entries() do
            assert.are.equal(padInt(k), v)
        end

        local keys = collect(m:Keys())
        assert.are.equal(N, #keys)
        assert.is_true(isSorted(keys))

        local values = collect(m:Values())
        assert.are.equal(N, #values)
        assert.is_true(isSorted(values))

        local firstKey = 0
        for k in m:Keys() do
            firstKey = k
            break
        end
        assert.are.equal(start, firstKey)

        local firstValue = ""
        for v in m:Values() do
            firstValue = v
            break
        end
        assert.are.equal(padInt(start), firstValue)

        for k, v in m:Entries() do
            firstKey = k
            firstValue = v
            break
        end

        assert.are.equal(start, firstKey)
        assert.are.equal(padInt(start), firstValue)

        for i = start + 1, end_ - 1 do
            local v, ok = m:Delete(i)
            assert.is_true(ok)
            assert.are.equal(padInt(i), v)
            assert.is_true(not m:Has(i))

            v, ok = m:Get(i)
            assert.is_true(not ok)
            assert.is_nil(v) -- Go: "" (zero value of V)

            v, ok = m:Delete(i)
            assert.is_true(not ok)
            assert.is_nil(v) -- Go: "" (zero value of V)
        end

        assert.are.equal(1, m:Size())
        assert.is_true(m:Has(start))

        local v, ok = m:Delete(start)
        assert.is_true(ok)
        assert.are.equal(padInt(start), v)

        assert.are.equal(0, m:Size())
    end)
end)

describe("TestOrderedMapClone", function()
    it("TestOrderedMapClone", function()
        local m = collections.NewOrderedMap()
        m:Set(1, "one")
        m:Set(2, "two")

        local clone = m:Clone()

        assert.is_true(clone ~= m)
        assert.are.equal(2, clone:Size())
        assert.are.same({ 1, 2 }, collect(clone:Keys()))
        assert.are.same({ "one", "two" }, collect(clone:Values()))

        local v, ok = clone:Get(1)
        assert.is_true(ok)
        assert.are.equal("one", v)

        m:Delete(1)

        assert.are.equal(1, m:Size())
        assert.are.equal(2, clone:Size())
        assert.are.same({ 1, 2 }, collect(clone:Keys()))
        assert.are.same({ "one", "two" }, collect(clone:Values()))
    end)
end)

describe("TestOrderedMapClear", function()
    it("TestOrderedMapClear", function()
        local m = collections.NewOrderedMap()
        m:Set(1, "one")
        m:Set(2, "two")

        m:Clear()

        assert.are.equal(0, m:Size())
    end)
end)

-- TestOrderedMapWithSizeHint measures Go allocations (testing.AllocsPerRun); it has no Lua
-- equivalent. The size-hint constructor is exercised for behavior only.
describe("TestOrderedMapWithSizeHint", function()
    it("TestOrderedMapWithSizeHint", function()
        local N = 1024
        local m = collections.NewOrderedMapWithSizeHint(N)
        for i = 0, N - 1 do
            m:Set(i, i)
        end
        assert.are.equal(N, m:Size())
    end)
end)

local function testOrderedMapUnmarshalJSON(unmarshal)
    local m = collections.NewOrderedMap()
    local err = unmarshal('{"a": 1, "b": "two", "c": { "d": 4 } }', m)
    assert.is_nil(err)

    assert.are.equal(3, m:Size())
    assert.are.equal(1.0, m:GetOrZero("a"))
    assert.are.equal("float", math.type(m:GetOrZero("a")))

    err = unmarshal("null", m)
    assert.is_nil(err)

    err = unmarshal('"foo"', m)
    assert.is_truthy(err ~= nil and string.find(err, "cannot unmarshal non-object JSON value into Map", 1, true))

    -- The Go test also unmarshals into an OrderedMap[int, any] and expects a key type error;
    -- Lua maps are untyped, so there is no key type to violate.
end

describe("TestOrderedMapUnmarshalJSON", function()
    it("UnmarshalJSONV2", function()
        testOrderedMapUnmarshalJSON(function(input, out)
            return out:UnmarshalJSONFrom(json.NewDecoder(input))
        end)
    end)
end)
