-- Port of internal/core/bfs_test.go. Goroutines are sequential in the Lua port.
local core = require("tslua.core")
local collections = require("tslua.collections")

describe("TestBreadthFirstSearchParallel", function()
    describe("basic functionality", function()
        -- Test basic functionality with a simple DAG
        -- Graph: A -> B, A -> C, B -> D, C -> D
        local graph = {
            A = { "B", "C" },
            B = { "D" },
            C = { "D" },
            D = {},
        }

        local function children(node)
            return graph[node]
        end

        it("find specific node", function()
            local result = core.BreadthFirstSearchParallel("A", children, function(node)
                return node == "D", true
            end)
            assert.are.equal(true, result.stopped, "Expected search to stop at D")
            assert.are.same({ "D", "B", "A" }, result.path)
        end)

        it("visit all nodes", function()
            local visitedNodes = {}
            local result = core.BreadthFirstSearchParallel("A", children, function(node)
                visitedNodes[#visitedNodes + 1] = node
                return false, false -- Never stop early
            end)

            -- Should return nil since we never return true
            assert.are.equal(false, result.stopped, "Expected search to not stop early")
            assert.is_nil(result.path, "Expected nil path when visit function never returns true")

            -- Should visit all nodes exactly once
            table.sort(visitedNodes)
            assert.are.same({ "A", "B", "C", "D" }, visitedNodes)
        end)
    end)

    it("early termination", function()
        -- Test that nodes below the target level are not visited
        local graph = {
            Root = { "L1A", "L1B" },
            L1A = { "L2A", "L2B" },
            L1B = { "L2C" },
            L2A = { "L3A" },
            L2B = {},
            L2C = {},
            L3A = {},
        }

        local function children(node)
            return graph[node]
        end

        local visited = collections.NewSyncSet()
        core.BreadthFirstSearchParallelEx("Root", children, function(node)
            return node == "L2B", true -- Stop at level 2
        end, { visited = visited }, core.Identity)

        assert.is_true(visited:Has("Root"), "Expected to visit Root")
        assert.is_true(visited:Has("L1A"), "Expected to visit L1A")
        assert.is_true(visited:Has("L1B"), "Expected to visit L1B")
        assert.is_true(visited:Has("L2A"), "Expected to visit L2A")
        assert.is_true(visited:Has("L2B"), "Expected to visit L2B")
        -- L2C is non-deterministic
        assert.is_true(not visited:Has("L3A"), "Expected not to visit L3A")
    end)

    it("returns fallback when no other result found", function()
        -- Test that fallback behavior works correctly
        local graph = {
            A = { "B", "C" },
            B = { "D" },
            C = { "D" },
            D = {},
        }

        local function children(node)
            return graph[node]
        end

        local visited = collections.NewSyncSet()
        local result = core.BreadthFirstSearchParallelEx("A", children, function(node)
            return node == "A", false -- Record A as a fallback, but do not stop
        end, { visited = visited }, core.Identity)

        assert.are.equal(false, result.stopped, "Expected search to not stop early")
        assert.are.same({ "A" }, result.path)
        assert.is_true(visited:Has("B"), "Expected to visit B")
        assert.is_true(visited:Has("C"), "Expected to visit C")
        assert.is_true(visited:Has("D"), "Expected to visit D")
    end)

    it("returns a stop result over a fallback", function()
        -- Test that a stop result is preferred over a fallback
        local graph = {
            A = { "B", "C" },
            B = { "D" },
            C = { "D" },
            D = {},
        }

        local function children(node)
            return graph[node]
        end

        local result = core.BreadthFirstSearchParallel("A", children, function(node)
            if node == "A" then
                return true, false -- Record fallback
            elseif node == "D" then
                return true, true -- Stop at D
            else
                return false, false
            end
        end)

        assert.are.equal(true, result.stopped, "Expected search to stop at D")
        assert.are.same({ "D", "B", "A" }, result.path)
    end)
end)
