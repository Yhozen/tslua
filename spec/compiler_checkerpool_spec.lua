-- Port of internal/compiler/checkerpool_test.go.
local compiler = require("tslua.compiler")

-- make([][]int, n): n nil (empty) adjacency lists.
local function makeAdjacency(n)
    local result = {}
    for i = 1, n do
        result[i] = {}
    end
    return result
end

local function format(xs)
    if xs == nil then
        return "nil"
    end
    local parts = {}
    for i, x in ipairs(xs) do
        parts[i] = tostring(x)
    end
    return "[" .. table.concat(parts, " ") .. "]"
end

describe("TestGetCheckerAssociationBaseWeight", function()
    it("TestGetCheckerAssociationBaseWeight", function()
        local got = compiler.getCheckerAssociationBaseWeight(100, 2500)
        assert.are.equal(125, got, "getCheckerAssociationBaseWeight() = " .. tostring(got) .. ", want 125")
    end)
end)

describe("TestShouldPrioritizeSourceFiles", function()
    it("TestShouldPrioritizeSourceFiles", function()
        assert.is_true(compiler.shouldPrioritizeSourceFiles(1000, 100, 4), "shouldPrioritizeSourceFiles() = false, want true")
        assert.is_true(compiler.shouldPrioritizeSourceFiles(1000, 125, 4), "shouldPrioritizeSourceFiles() = false at boundary, want true")
        assert.is_false(compiler.shouldPrioritizeSourceFiles(1000, 126, 4), "shouldPrioritizeSourceFiles() = true, want false")
    end)
end)

describe("TestGetCheckerAssociationPolicy", function()
    local tests = {
        {
            name = "source dominated at any checker count",
            totalWeight = 1000,
            declarationWeight = 100,
            checkerCount = 2,
            want = {
                prioritizeSourceFiles = true,
                sourceFileWeightMultiplier = 1,
                balancePenaltyMultiplier = compiler.checkerAssociationPrioritizedSourcePenalty,
            },
        },
        {
            name = "declaration heavy with few checkers",
            totalWeight = 1000,
            declarationWeight = 400,
            checkerCount = 2,
            want = {
                prioritizeSourceFiles = false,
                sourceFileWeightMultiplier = 1,
                balancePenaltyMultiplier = 1,
            },
        },
        {
            name = "source dominated with many checkers",
            totalWeight = 1000,
            declarationWeight = 50,
            checkerCount = 8,
            want = {
                prioritizeSourceFiles = true,
                sourceFileWeightMultiplier = 1,
                balancePenaltyMultiplier = compiler.checkerAssociationPrioritizedSourcePenalty,
            },
        },
        {
            name = "declaration heavy with many checkers",
            totalWeight = 1000,
            declarationWeight = 400,
            checkerCount = 4,
            want = {
                prioritizeSourceFiles = false,
                sourceFileWeightMultiplier = compiler.checkerAssociationSourceFileWeightMultiplier,
                balancePenaltyMultiplier = compiler.checkerAssociationBalancePenaltyMultiplier,
            },
        },
    }
    for _, test in ipairs(tests) do
        it(test.name, function()
            local got = compiler.getCheckerAssociationPolicy(test.totalWeight, test.declarationWeight, test.checkerCount)
            assert.are.same(test.want, got)
        end)
    end
end)

describe("TestGetCheckerAssociationOrder", function()
    it("TestGetCheckerAssociationOrder", function()
        local got = compiler.getCheckerAssociationOrder({ 5, 10, 7, 2 }, { true, false, false, true }, true)
        assert.are.same({ 1, 2, 0, 3 }, got, "getCheckerAssociationOrder() = " .. format(got) .. ", want [1 2 0 3]")
        got = compiler.getCheckerAssociationOrder({ 5 }, { false }, false)
        assert.is_true(got == nil, "getCheckerAssociationOrder() = " .. format(got) .. ", want nil")
    end)
end)

describe("TestGetCheckerAssociationWeights", function()
    local tests = {
        {
            name = "normalizes import work to syntax work",
            baseWeights = { 100, 50, 25 },
            importCounts = { 0, 1, 3 },
            want = { 100, 93, 154 },
        },
        {
            name = "no imports preserves base weights",
            baseWeights = { 100, 50, 25 },
            importCounts = { 0, 0, 0 },
            want = { 100, 50, 25 },
        },
    }

    for _, test in ipairs(tests) do
        it(test.name, function()
            local got = compiler.getCheckerAssociationWeights(test.baseWeights, test.importCounts)
            assert.are.same(test.want, got)
        end)
    end
end)

describe("TestGetCheckerAssociations", function()
    it("empty", function()
        local got = compiler.getCheckerAssociationsInOrder(nil, nil, nil, 4, compiler.checkerAssociationBalancePenaltyMultiplier)
        assert.is_true(got == nil, "getCheckerAssociationsInOrder() = " .. format(got) .. ", want nil")
    end)

    it("balances disconnected files", function()
        local got = compiler.getCheckerAssociationsInOrder(
            { 1, 1, 1, 1, 1, 1 },
            makeAdjacency(6),
            nil,
            3,
            1
        )
        assert.are.same({ 0, 1, 2, 0, 1, 2 }, got)
    end)

    it("uses program order", function()
        local got = compiler.getCheckerAssociationsInOrder(
            { 1, 3, 2 },
            makeAdjacency(3),
            nil,
            2,
            1
        )
        assert.are.same({ 0, 1, 0 }, got)
    end)

    it("keeps dense components together", function()
        local got = compiler.getCheckerAssociationsInOrder(
            { 1, 1, 1, 1, 1, 1 },
            {
                { 1, 2 },
                { 0, 2 },
                { 0, 1 },
                { 4, 5 },
                { 3, 5 },
                { 3, 4 },
            },
            nil,
            2,
            1
        )
        assert.are.same({ 0, 0, 0, 1, 1, 1 }, got)
    end)

    it("respects weighted balance cap", function()
        local weights = { 8, 7, 6, 5, 4, 3, 2, 1 }
        local got = compiler.getCheckerAssociationsInOrder(weights, makeAdjacency(#weights), nil, 3, 1)
        local loads = { 0, 0, 0 }
        for i, checkerIndex in ipairs(got) do
            loads[checkerIndex + 1] = loads[checkerIndex + 1] + weights[i]
        end
        for i, load in ipairs(loads) do
            assert.is_true(load <= 13, "checker " .. (i - 1) .. " load = " .. load .. ", want at most 13; associations = " .. format(got))
        end
    end)
end)
