local compiler = require("tslua.compiler")
local checker = require("tslua.checker")
local core = require("tslua.core")

-- CheckerPool is implemented by the project system to provide checkers with
-- request-scoped lifetime and reclamation. It is a table with
-- GetChecker(ctx, file) -> (*checker.Checker, release func).

local checkerPool = {}
checkerPool.__index = checkerPool
compiler.checkerPool = checkerPool

--[[
Checker association is a balanced graph-partitioning problem:

  - A vertex is a source file.
  - An undirected edge connects two files for each resolved, in-program import
    entry between them. Multiple entries may connect the same pair and therefore
    strengthen their affinity. Self-imports and unresolved or external targets do
    not create edges.
  - A partition is a checker with its own symbol, type, and instantiation caches.

We use weighted FENNEL to trade off affinity against load:

  affinity(partition) - alpha * incrementalLoadPenalty(partition)

See Tsourakakis et al., "FENNEL: Streaming Graph Partitioning for Massive Scale
Graphs", WSDM 2014. Stream order is part of the policy below. The constants are
empirical safety factors (see the Go source for the calibration notes).
]]
compiler.checkerAssociationTextWeightDivisor = 100
compiler.checkerAssociationSourceFileWeightMultiplier = 4
compiler.checkerAssociationBalancePenaltyMultiplier = 16
compiler.checkerAssociationPrioritizedSourcePenalty = 12
compiler.checkerAssociationStrongBalanceMinCheckerCount = 4

-- checkerAssociationPolicy: { prioritizeSourceFiles, sourceFileWeightMultiplier, balancePenaltyMultiplier }

--[[
getCheckerAssociationPolicy selects one of three calibrated regimes:

 1. Source-dominated, any checker count:
    source files first by descending weight; unmodified source-file weight;
    checkerAssociationPrioritizedSourcePenalty.
 2. Declaration-heavy, at least checkerAssociationStrongBalanceMinCheckerCount:
    program order; checkerAssociationSourceFileWeightMultiplier;
    checkerAssociationBalancePenaltyMultiplier.
 3. Declaration-heavy, fewer checkers:
    program order; unmodified source-file weight; unscaled adapted FENNEL
    penalty.
]]
function compiler.getCheckerAssociationPolicy(totalWeight, declarationWeight, checkerCount)
    if compiler.shouldPrioritizeSourceFiles(totalWeight, declarationWeight, checkerCount) then
        return {
            prioritizeSourceFiles = true,
            sourceFileWeightMultiplier = 1,
            balancePenaltyMultiplier = compiler.checkerAssociationPrioritizedSourcePenalty,
        }
    end
    if checkerCount >= compiler.checkerAssociationStrongBalanceMinCheckerCount then
        return {
            prioritizeSourceFiles = false,
            sourceFileWeightMultiplier = compiler.checkerAssociationSourceFileWeightMultiplier,
            balancePenaltyMultiplier = compiler.checkerAssociationBalancePenaltyMultiplier,
        }
    end
    return {
        prioritizeSourceFiles = false,
        sourceFileWeightMultiplier = 1,
        balancePenaltyMultiplier = 1,
    }
end

-- getCheckerAssociationsInOrder partitions the import graph using a weighted adaptation
-- of FENNEL's streaming graph-partitioning objective with gamma = 3/2. Each file
-- is placed where it has the most already-placed neighbors, minus the incremental
-- convex load penalty. A nil order means stable program order. File indices and the
-- returned checker indices are 0-based.
function compiler.getCheckerAssociationsInOrder(fileWeights, adjacentFiles, fileOrder, checkerCount, penaltyMultiplier)
    if #fileWeights == 0 then
        return nil
    end

    local totalWeight = 0
    local maxFileWeight = 0
    local edgeCount = 0
    for i, weight in ipairs(fileWeights) do
        totalWeight = totalWeight + weight
        maxFileWeight = math.max(maxFileWeight, weight)
        edgeCount = edgeCount + core.Len(adjacentFiles[i])
    end

    local associations = {}
    for i = 1, #fileWeights do
        associations[i] = -1
    end
    local checkerWeights = {}
    for i = 1, checkerCount do
        checkerWeights[i] = 0
    end
    local averageCheckerWeight = (totalWeight + checkerCount - 1) // checkerCount
    local maxCheckerWeight = math.max(maxFileWeight, averageCheckerWeight + averageCheckerWeight // 100)
    local totalWeightFloat = totalWeight + 0.0
    local alpha = (penaltyMultiplier + 0.0) * ((edgeCount // 2) + 0.0) * math.sqrt(checkerCount + 0.0) / (totalWeightFloat * math.sqrt(totalWeightFloat))
    local neighborCounts = {}

    for position = 0, #fileWeights - 1 do
        local fileIndex = position
        if fileOrder ~= nil then
            fileIndex = fileOrder[position + 1]
        end

        for i = 1, checkerCount do
            neighborCounts[i] = 0
        end
        for _, adjacentFile in ipairs(adjacentFiles[fileIndex + 1] or {}) do
            local checkerIndex = associations[adjacentFile + 1]
            if checkerIndex >= 0 then
                neighborCounts[checkerIndex + 1] = neighborCounts[checkerIndex + 1] + 1
            end
        end

        local bestChecker = -1
        local bestScore = -math.huge
        local fileWeight = fileWeights[fileIndex + 1]
        for checkerIndex1, checkerWeight in ipairs(checkerWeights) do
            local checkerIndex = checkerIndex1 - 1
            if checkerWeight + fileWeight > maxCheckerWeight then
                goto continue
            end
            do
                local oldWeight = checkerWeight + 0.0
                local newWeight = (checkerWeight + fileWeight) + 0.0
                local penalty = alpha * (newWeight * math.sqrt(newWeight) - oldWeight * math.sqrt(oldWeight))
                local score = neighborCounts[checkerIndex1] - penalty
                if score > bestScore or score == bestScore and (bestChecker < 0 or checkerWeight < checkerWeights[bestChecker + 1]) then
                    bestChecker = checkerIndex
                    bestScore = score
                end
            end
            ::continue::
        end
        if bestChecker < 0 then
            bestChecker = 0
            for checkerIndex1 = 2, #checkerWeights do
                if checkerWeights[checkerIndex1] < checkerWeights[bestChecker + 1] then
                    bestChecker = checkerIndex1 - 1
                end
            end
        end
        associations[fileIndex + 1] = bestChecker
        checkerWeights[bestChecker + 1] = checkerWeights[bestChecker + 1] + fileWeight
    end
    return associations
end

-- getCheckerAssociationOrder places source files before declarations and
-- orders each group by descending estimated work. Returning nil preserves
-- program order. The returned order holds 0-based file indices.
function compiler.getCheckerAssociationOrder(fileWeights, isDeclarationFile, prioritizeSourceFiles)
    if not prioritizeSourceFiles then
        return nil
    end
    local fileOrder = {}
    for i = 1, #fileWeights do
        fileOrder[i] = i - 1
    end
    table.sort(fileOrder, function(left, right)
        if isDeclarationFile[left + 1] ~= isDeclarationFile[right + 1] then
            return not isDeclarationFile[left + 1]
        end
        if fileWeights[left + 1] ~= fileWeights[right + 1] then
            return fileWeights[left + 1] > fileWeights[right + 1]
        end
        return left < right
    end)
    return fileOrder
end

function compiler.getCheckerAssociationBaseWeight(nodeCount, textLength)
    return math.max(nodeCount + textLength // compiler.checkerAssociationTextWeightDivisor, 1)
end

-- shouldPrioritizeSourceFiles reports whether all declaration-file base work is at
-- most half of one average checker load:
--
--	declarationWeight <= totalWeight / (2 * checkerCount)
function compiler.shouldPrioritizeSourceFiles(totalWeight, declarationWeight, checkerCount)
    return declarationWeight * checkerCount * 2 <= totalWeight
end

-- getCheckerAssociationWeights combines local syntax work with syntactic import
-- fanout. One import unit is totalBaseWeight / totalImports, so imports collectively
-- contribute approximately the same vertex weight as syntax.
function compiler.getCheckerAssociationWeights(baseWeights, importCounts)
    local totalBaseWeight = 0
    local totalImports = 0
    for i, baseWeight in ipairs(baseWeights) do
        totalBaseWeight = totalBaseWeight + baseWeight
        totalImports = totalImports + importCounts[i]
    end
    local importWeight = 0
    if totalImports > 0 then
        importWeight = math.max(totalBaseWeight // totalImports, 1)
    end
    local fileWeights = {}
    for i, baseWeight in ipairs(baseWeights) do
        fileWeights[i] = baseWeight + importCounts[i] * importWeight
    end
    return fileWeights
end

function compiler.newCheckerPool(program)
    return compiler.newCheckerPoolWithTracing(program, nil)
end

function compiler.newCheckerPoolWithTracing(program, tr)
    local checkerCount = 4
    if program:SingleThreaded() then
        checkerCount = 1
    elseif program:Options().checkers ~= nil then
        checkerCount = program:Options().checkers
    end

    checkerCount = math.max(math.min(checkerCount, #program.files, 256), 1)

    local pool = setmetatable({
        program = program,
        tracing = tr,
        createCheckersDone = false,
        checkerCount = checkerCount,
        checkers = {},
        fileAssociations = nil,
    }, checkerPool)

    return pool
end

local function noop() end
compiler.noop = noop

-- GetChecker implements CheckerPool. When file is non-nil, returns the checker
-- associated with that file; otherwise returns the first checker.
function checkerPool:GetChecker(ctx, file)
    if file ~= nil then
        return self:getCheckerForFileExclusive(ctx, file)
    end
    self:createCheckers()
    return self.checkers[1], noop
end

-- getCheckerForFileNonExclusive returns the checker for the given file without locking.
function checkerPool:getCheckerForFileNonExclusive(file)
    self:createCheckers()
    return self.fileAssociations[file], noop
end

function checkerPool:getCheckerForFileExclusive(ctx, file)
    self:createCheckers()
    return self.fileAssociations[file], noop
end

-- getCheckerNonExclusive returns the first checker without locking.
function checkerPool:getCheckerNonExclusive()
    self:createCheckers()
    return self.checkers[1], noop
end

function checkerPool:createCheckers()
    if self.createCheckersDone then
        return
    end
    self.createCheckersDone = true
    local checkerCount = self.checkerCount
    local program = self.program
    local wg = core.NewWorkGroup(program:SingleThreaded())
    for i = 1, checkerCount do
        wg:Queue(function()
            self.checkers[i] = checker.NewChecker(program, nil)
        end)
    end

    wg:RunAndWait()

    local files = program.files
    local associations = {}
    for i = 1, #files do
        associations[i] = 0
    end
    if checkerCount > 1 then
        local baseWeights = {}
        local importCounts = {}
        local isDeclarationFile = {}
        local totalBaseWeight = 0
        local declarationBaseWeight = 0
        for i, file in ipairs(files) do
            local baseWeight = compiler.getCheckerAssociationBaseWeight(file.nodeCount, #file:Text())
            totalBaseWeight = totalBaseWeight + baseWeight
            if file.isDeclarationFile then
                declarationBaseWeight = declarationBaseWeight + baseWeight
            end
            baseWeights[i] = baseWeight
            importCounts[i] = core.Len(file:Imports())
            isDeclarationFile[i] = file.isDeclarationFile
        end
        local policy = compiler.getCheckerAssociationPolicy(totalBaseWeight, declarationBaseWeight, checkerCount)
        if policy.sourceFileWeightMultiplier ~= 1 then
            -- Apply this before import normalization. The policy intentionally
            -- increases both source-file work and the normalized import unit.
            for i, declaration in ipairs(isDeclarationFile) do
                if not declaration then
                    baseWeights[i] = baseWeights[i] * policy.sourceFileWeightMultiplier
                end
            end
        end
        local fileWeights = compiler.getCheckerAssociationWeights(baseWeights, importCounts)
        local adjacentFiles = self:getImportAdjacency()
        local fileOrder = compiler.getCheckerAssociationOrder(fileWeights, isDeclarationFile, policy.prioritizeSourceFiles)
        associations = compiler.getCheckerAssociationsInOrder(fileWeights, adjacentFiles, fileOrder, checkerCount, policy.balancePenaltyMultiplier) or associations
    end
    self.fileAssociations = {}
    for i, file in ipairs(files) do
        self.fileAssociations[file] = self.checkers[associations[i] + 1]
    end
end

-- getImportAdjacency returns an undirected import graph represented by file
-- index (0-based). A directed import from A to B makes both files adjacent because either
-- file can benefit from sharing checker caches with the other.
function checkerPool:getImportAdjacency()
    local program = self.program
    local fileIndices = {}
    for i, file in ipairs(program.files) do
        fileIndices[file] = i - 1
    end
    local adjacentFiles = {}
    for i = 1, #program.files do
        adjacentFiles[i] = {}
    end
    for fileIndex1, file in ipairs(program.files) do
        local fileIndex = fileIndex1 - 1
        local resolvedModules = program.resolvedModules[file:Path()]
        for _, _, resolved in compiler.modeAwareCachePairs(resolvedModules) do
            if resolved == nil or not resolved:IsResolved() then
                goto continue
            end
            do
                local importedFile = program:GetSourceFileForResolvedModule(resolved.resolvedFileName)
                local importedIndex = importedFile ~= nil and fileIndices[importedFile] or nil
                if importedIndex == nil or importedIndex == fileIndex then
                    goto continue
                end
                local a = adjacentFiles[fileIndex + 1]
                a[#a + 1] = importedIndex
                local b = adjacentFiles[importedIndex + 1]
                b[#b + 1] = fileIndex
            end
            ::continue::
        end
    end
    return adjacentFiles
end

-- Runs `cb` for each checker in the pool.
function checkerPool:forEachCheckerParallel(cb)
    self:createCheckers()
    local wg = core.NewWorkGroup(self.program:SingleThreaded())
    for idx1, c in ipairs(self.checkers) do
        wg:Queue(function()
            cb(idx1 - 1, c)
        end)
    end
    wg:RunAndWait()
end

function checkerPool:GetGlobalDiagnostics()
    self:createCheckers()
    local globalDiagnostics = {}
    self:forEachCheckerParallel(function(idx, c)
        globalDiagnostics[idx + 1] = c:GetGlobalDiagnostics()
    end)
    local all = {}
    for i = 1, #self.checkers do
        core.AppendAll(all, globalDiagnostics[i])
    end
    return compiler.SortAndDeduplicateDiagnostics(all)
end

-- forEachCheckerGroupDo runs one task per checker. Each task iterates
-- the provided files, processing only those assigned to its checker. Within each
-- checker's set, files are visited in their original order. fileIndex is 0-based.
function checkerPool:forEachCheckerGroupDo(ctx, files, singleThreaded, cb)
    self:createCheckers()

    local checkerCount = #self.checkers
    local wg = core.NewWorkGroup(singleThreaded)
    for checkerIdx = 1, checkerCount do
        wg:Queue(function()
            local c = self.checkers[checkerIdx]
            for i1, file in ipairs(files) do
                if c == self.fileAssociations[file] then
                    cb(c, i1 - 1, file)
                end
            end
        end)
    end
    wg:RunAndWait()
end
