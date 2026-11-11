local core = require("tslua.core")
local collections = require("tslua.collections")

local MaxInt64 = math.maxinteger

-- BreadthFirstSearchResult: { stopped = bool, path = array }

local BreadthFirstSearchLevel = {}
BreadthFirstSearchLevel.__index = BreadthFirstSearchLevel
core.BreadthFirstSearchLevel = BreadthFirstSearchLevel

function BreadthFirstSearchLevel:Has(key)
    return self.jobs:Has(key)
end

function BreadthFirstSearchLevel:Delete(key)
    self.jobs:Delete(key)
end

function BreadthFirstSearchLevel:Range(f)
    for job in self.jobs:Values() do
        if not f(job.node) then
            return
        end
    end
end

-- BreadthFirstSearchOptions: { visited = collections.SyncSet or nil, preprocessLevel = function or nil }

-- BreadthFirstSearchParallel performs a breadth-first search on a graph
-- starting from the given node. It processes nodes (sequentially in Lua) and returns the path
-- from the first node that satisfies the `visit` function back to the start node.
-- visit returns (isResult, stop).
function core.BreadthFirstSearchParallel(start, neighbors, visit)
    return core.BreadthFirstSearchParallelEx(start, neighbors, visit, {}, core.Identity)
end

-- BreadthFirstSearchParallelEx is an extension of BreadthFirstSearchParallel that allows
-- the caller to pass a pre-seeded set of already-visited nodes and a preprocessing function
-- that can be used to remove nodes from each level before processing.
function core.BreadthFirstSearchParallelEx(start, neighbors, visit, options, getKey)
    options = options or {}
    local visited = options.visited
    if visited == nil then
        visited = collections.NewSyncSet()
    end

    local fallback = nil
    -- processLevel processes each node at the current level.
    -- It produces either a list of jobs to be processed in the next level,
    -- or a result if the visit function returns true for any node.
    local function processLevel(index, jobs)
        local lowestFallback = MaxInt64
        local lowestGoal = MaxInt64
        if options.preprocessLevel ~= nil then
            options.preprocessLevel(setmetatable({ jobs = jobs }, BreadthFirstSearchLevel))
        end
        local next_ = {}
        local i = 0
        for j in jobs:Values() do
            local idx = i
            repeat
                if idx >= lowestGoal then
                    break -- Stop processing if we already found a lower result
                end

                -- If we have already visited this node, skip it.
                if not visited:AddIfAbsent(getKey(j.node)) then
                    -- Note that if we are here, we already visited this node at a
                    -- previous *level*, which means `visit` must have returned false,
                    -- so we don't need to update our result indices. This holds true
                    -- because we deduplicated jobs before queuing the level.
                    break
                end

                local isResult, stop = visit(j.node)
                if isResult then
                    -- We found a result, so we will stop at this level, but an
                    -- earlier job may still find a true result at a lower index.
                    if stop then
                        if idx < lowestGoal then
                            lowestGoal = idx
                        end
                        break
                    end
                    if fallback == nil then
                        if idx < lowestFallback then
                            lowestFallback = idx
                        end
                    end
                end

                if idx >= lowestGoal then
                    break
                end
                -- Add the next level jobs
                local neighborNodes = neighbors(j.node)
                if core.Len(neighborNodes) > 0 then
                    next_[idx + 1] = core.Map(neighborNodes, function(child)
                        return { node = child, parent = j }
                    end)
                end
            until true
            i = i + 1
        end
        if lowestGoal ~= MaxInt64 then
            -- If we found a result, return it immediately.
            local _, job = jobs:EntryAt(lowestGoal)
            return { stop = true, job = job }
        end
        if fallback == nil then
            if lowestFallback ~= MaxInt64 then
                local _
                _, fallback = jobs:EntryAt(lowestFallback)
            end
        end
        local nextJobs = collections.NewOrderedMapWithSizeHint(0)
        for k = 1, i do
            local levelJobs = next_[k]
            if levelJobs ~= nil then
                for _, j in ipairs(levelJobs) do
                    if not nextJobs:Has(getKey(j.node)) then
                        -- Deduplicate synchronously to avoid messy locks and spawning
                        -- unnecessary goroutines.
                        nextJobs:Set(getKey(j.node), j)
                    end
                end
            end
        end
        return { stop = false, next = nextJobs }
    end

    local function createPath(job)
        local path = nil
        while job ~= nil do
            path = path or {}
            path[#path + 1] = job.node
            job = job.parent
        end
        return path
    end

    local levelIndex = 0
    local level = collections.NewOrderedMapFromList({
        { key = getKey(start), value = { node = start } },
    })
    while level:Size() > 0 do
        local result = processLevel(levelIndex, level)
        if result.stop then
            return { stopped = true, path = createPath(result.job) }
        elseif result.job ~= nil and fallback == nil then
            fallback = result.job
        end
        level = result.next
        levelIndex = levelIndex + 1
    end
    return { stopped = false, path = createPath(fallback) }
end
