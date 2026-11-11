local core = require("tslua.core")

-- BinarySearchUniqueFunc works like [slices.BinarySearchFunc], but avoids extra
-- invocations of the comparison function by assuming that only one element
-- in the slice could match the target. Also, unlike [slices.BinarySearchFunc],
-- the comparison function is passed the current index of the element being
-- compared, instead of the target element.
-- cmp receives (0-based index, element). Returns (0-based index, found).
function core.BinarySearchUniqueFunc(x, cmp)
    local n = core.Len(x)
    if n == 0 then
        return 0, false
    end
    local low, high = 0, n - 1
    while low <= high do
        local middle = low + ((high - low) >> 1)
        local value = cmp(middle, x[middle + 1])
        if value < 0 then
            low = middle + 1
        elseif value > 0 then
            high = middle - 1
        else
            return middle, true
        end
    end
    return low, false
end
