-- Lua-only support code for the incremental package (no Go counterpart).
--
--   * Go iterates SyncMaps/SyncSets/maps keyed by tspath.Path in random order; the port iterates
--     them in sorted key order so that runs are reproducible:
--     incremental.rangeSorted(syncMap, fn(k, v) -> bool), incremental.rangeSortedSet(syncSet, fn(k) -> bool),
--     incremental.sortedKeys(t) (array of the keys of a plain table),
--     incremental.sortedKeysIter(t) (iterator over the sorted keys of a plain table).
--   * Go context cancellation: incremental.ctxErr(ctx) (ctx is nil or a table with Err()).
local incremental = require("tslua.execute.incremental")

function incremental.sortedKeys(t)
    local keys = {}
    if t ~= nil then
        for k in pairs(t) do
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    return keys
end

function incremental.sortedKeysIter(t)
    local keys = incremental.sortedKeys(t)
    local i = 0
    return function()
        i = i + 1
        return keys[i]
    end
end

-- Snapshot of the keys first, so that fn may modify the map (like Go's Range).
function incremental.rangeSorted(m, fn)
    local keys = {}
    for k in m:Keys() do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v, ok = m:Load(k)
        if ok then
            if not fn(k, v) then
                return
            end
        end
    end
end

function incremental.rangeSortedSet(s, fn)
    local keys = {}
    for k in s:Keys() do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        if s:Has(k) then
            if not fn(k) then
                return
            end
        end
    end
end

function incremental.ctxErr(ctx)
    if ctx ~= nil and type(ctx) == "table" and ctx.Err ~= nil then
        return ctx:Err()
    end
    return nil
end
