local collections = require("tslua.collections")

-- OrderedSet an insertion ordered set.
local OrderedSet = {}
OrderedSet.__index = OrderedSet
collections.OrderedSet = OrderedSet

-- NewOrderedSetWithSizeHint creates a new OrderedSet with a hint for the number of elements it will contain.
function collections.NewOrderedSetWithSizeHint(hint)
    return setmetatable({ m = collections.newMapWithSizeHint(hint) }, OrderedSet)
end

-- Zero value (Go `collections.OrderedSet[T]{}`).
function collections.NewOrderedSet()
    return collections.NewOrderedSetWithSizeHint(0)
end

-- Add adds a value to the set.
function OrderedSet:Add(value)
    self.m:Set(value, true)
end

-- Has returns true if the set contains the value.
function OrderedSet:Has(value)
    return self.m:Has(value)
end

-- Delete removes a value from the set.
function OrderedSet:Delete(value)
    local _, ok = self.m:Delete(value)
    return ok
end

-- Values returns an iterator over the values in the set.
function OrderedSet:Values()
    return self.m:Keys()
end

-- Clear removes all elements from the set.
function OrderedSet:Clear()
    self.m:Clear()
end

-- Size returns the number of elements in the set.
function OrderedSet:Size()
    return self.m:Size()
end

-- Clone returns a shallow copy of the set.
function OrderedSet:Clone()
    return setmetatable({ m = self.m:clone() }, OrderedSet)
end
