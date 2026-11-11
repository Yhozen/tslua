-- Lua-only: port of the third-party Go module github.com/peter-evans/patience v0.3.0
-- (patience.go, lcs.go, unified.go, format.go), used by baseline.DiffText.
local baseline = require("tslua.testutil.baseline")

local patience = {}
baseline.patience = patience

-- DiffType defines the type of a diff element.
patience.Delete = -1 -- Delete represents a diff delete operation.
patience.Insert = 1  -- Insert represents a diff insert operation.
patience.Equal = 0   -- Equal represents no diff.

local Delete, Insert, Equal = patience.Delete, patience.Insert, patience.Equal

-- DiffLine represents a single line and its diff type: { text = string, type = DiffType }.

-- toDiffLines converts xs[a+1..b] to DiffLines with the specified diff type.
local function toDiffLines(xs, a, b, t, out)
    for i = a + 1, b do
        out[#out + 1] = { text = xs[i], type = t }
    end
    return out
end

-- uniqueElements returns the unique elements of xs[a+1..b], and their original (0-based,
-- relative to a) indices.
local function uniqueElements(xs, a, b)
    local m = {}
    for i = a + 1, b do
        local e = xs[i]
        m[e] = (m[e] or 0) + 1
    end
    local elements = {}
    local indices = {}
    for i = a + 1, b do
        local e = xs[i]
        if m[e] == 1 then
            elements[#elements + 1] = e
            indices[#indices + 1] = i - 1 - a
        end
    end
    return elements, indices
end

-- LCS computes the longest common subsequence of two string
-- arrays and returns the (0-based) index pairs of the LCS.
function patience.LCS(a, b)
    local na, nb = #a, #b
    -- Initialize the LCS table.
    local lcs = {}
    for i = 0, na do
        local row = {}
        for j = 0, nb do
            row[j] = 0
        end
        lcs[i] = row
    end

    -- Populate the LCS table.
    for i = 1, na do
        local row, prev = lcs[i], lcs[i - 1]
        local ai = a[i]
        for j = 1, nb do
            if ai == b[j] then
                row[j] = prev[j - 1] + 1
            else
                local x, y = prev[j], row[j - 1]
                row[j] = x > y and x or y
            end
        end
    end

    -- Backtrack to find the LCS.
    local i, j = na, nb
    local s = {}
    while i > 0 and j > 0 do
        if a[i] == b[j] then
            s[#s + 1] = { i - 1, j - 1 }
            i = i - 1
            j = j - 1
        elseif lcs[i - 1][j] > lcs[i][j - 1] then
            i = i - 1
        else
            j = j - 1
        end
    end

    -- Reverse the backtracked LCS.
    local n = #s
    for k = 1, n // 2 do
        s[k], s[n - k + 1] = s[n - k + 1], s[k]
    end

    return s
end

-- diff appends the patience diff of a[a0+1..a1] and b[b0+1..b1] to out.
local function diff(a, a0, a1, b, b0, b1, out)
    local la, lb = a1 - a0, b1 - b0
    if la == 0 and lb == 0 then
        return out
    elseif la == 0 then
        return toDiffLines(b, b0, b1, Insert, out)
    elseif lb == 0 then
        return toDiffLines(a, a0, a1, Delete, out)
    end

    -- Find equal elements at the head of slices a and b.
    local i = 0
    while i < la and i < lb and a[a0 + i + 1] == b[b0 + i + 1] do
        i = i + 1
    end
    if i > 0 then
        toDiffLines(a, a0, a0 + i, Equal, out)
        return diff(a, a0 + i, a1, b, b0 + i, b1, out)
    end

    -- Find equal elements at the tail of slices a and b.
    local j = 0
    while j < la and j < lb and a[a1 - j] == b[b1 - j] do
        j = j + 1
    end
    if j > 0 then
        diff(a, a0, a1 - j, b, b0, b1 - j, out)
        return toDiffLines(a, a1 - j, a1, Equal, out)
    end

    -- Find the longest common subsequence of unique elements in a and b.
    local ua, idxa = uniqueElements(a, a0, a1)
    local ub, idxb = uniqueElements(b, b0, b1)
    local lcs = patience.LCS(ua, ub)

    -- If the LCS is empty, the diff is all deletions and insertions.
    if #lcs == 0 then
        toDiffLines(a, a0, a1, Delete, out)
        return toDiffLines(b, b0, b1, Insert, out)
    end

    -- Lookup the original indices of slices a and b.
    for _, x in ipairs(lcs) do
        x[1] = idxa[x[1] + 1]
        x[2] = idxb[x[2] + 1]
    end

    local ga, gb = 0, 0
    for _, ip in ipairs(lcs) do
        -- Diff the gaps between the lcs elements.
        diff(a, a0 + ga, a0 + ip[1], b, b0 + gb, b0 + ip[2], out)
        -- Append the LCS elements to the diff.
        out[#out + 1] = { type = Equal, text = a[a0 + ip[1] + 1] }
        ga = ip[1] + 1
        gb = ip[2] + 1
    end
    -- Diff the remaining elements of a and b after the final LCS element.
    return diff(a, a0 + ga, a1, b, b0 + gb, b1, out)
end

-- Diff returns the patience diff of two arrays of strings.
function patience.Diff(a, b)
    return diff(a, 0, #a, b, 0, #b, {})
end

-- Hunk represents a subsection of a diff: { diffs, srcStart, srcLines, dstStart, dstLines }.

local function sliceDiffs(diffs, a, b)
    local out = {}
    for i = a + 1, b do
        out[#out + 1] = diffs[i]
    end
    return out
end

local function appendAll(xs, ys)
    for _, y in ipairs(ys) do
        xs[#xs + 1] = y
    end
end

-- makeHunks returns the hunks of a diff.
function patience.makeHunks(diffs, precontext, postcontext)
    if #diffs == 0 then
        return nil
    end

    local hunks = {}

    -- Update hunks with a diff block.
    local function updateHunks(block, lastBlock)
        local curHunk = hunks[#hunks]
        local n = #block.diffs
        if block.diffs[1].type == Equal then
            -- Unmodified block.
            if #hunks == 0 then
                -- Start a new hunk with the tail of the block.
                local ctxLen = math.min(precontext, n)
                hunks[#hunks + 1] = {
                    diffs = sliceDiffs(block.diffs, n - ctxLen, n),
                    srcStart = n - ctxLen + block.srcStart,
                    srcLines = ctxLen,
                    dstStart = n - ctxLen + block.dstStart,
                    dstLines = ctxLen,
                }
            else
                -- Update the current hunk.
                local maxNonContext = precontext + postcontext
                if lastBlock then
                    maxNonContext = postcontext
                end
                if n <= maxNonContext then
                    -- Block is small enough to be appended to the current hunk.
                    appendAll(curHunk.diffs, block.diffs)
                    curHunk.srcLines = curHunk.srcLines + n
                    curHunk.dstLines = curHunk.dstLines + n
                else
                    -- Append the head of the block to the current hunk.
                    appendAll(curHunk.diffs, sliceDiffs(block.diffs, 0, postcontext))
                    curHunk.srcLines = curHunk.srcLines + postcontext
                    curHunk.dstLines = curHunk.dstLines + postcontext
                    if not lastBlock then
                        -- Start a new hunk with the tail of the block.
                        hunks[#hunks + 1] = {
                            diffs = sliceDiffs(block.diffs, n - precontext, n),
                            srcStart = n - precontext + block.srcStart,
                            srcLines = precontext,
                            dstStart = n - precontext + block.dstStart,
                            dstLines = precontext,
                        }
                    end
                end
                -- Update starting line numbers if the current hunk had no source or destination diff.
                if curHunk.srcStart == 0 then
                    curHunk.srcStart = block.srcStart
                end
                if curHunk.dstStart == 0 then
                    curHunk.dstStart = block.dstStart
                end
            end
        else
            -- Modified block.
            if #hunks > 0 then
                appendAll(curHunk.diffs, block.diffs)
                curHunk.srcLines = curHunk.srcLines + block.srcLines
                curHunk.dstLines = curHunk.dstLines + block.dstLines
            else
                hunks[#hunks + 1] = {
                    diffs = block.diffs,
                    srcStart = block.srcStart,
                    srcLines = block.srcLines,
                    dstStart = block.dstStart,
                    dstLines = block.dstLines,
                }
            end
        end
    end

    -- Aggregate blocks of modified and unmodified diff lines, creating
    -- or updating hunks after each block.
    local block = { diffs = {}, srcStart = 0, srcLines = 0, dstStart = 0, dstLines = 0 }
    local modifiedLines = 0
    local srcLineNum, dstLineNum = 0, 0
    for _, l in ipairs(diffs) do
        local first = block.diffs[1]
        if first == nil or first.type == l.type or (first.type ~= l.type and first.type ~= Equal and l.type ~= Equal) then
            block.diffs[#block.diffs + 1] = l
        else
            updateHunks(block, false)
            block = { diffs = { l }, srcStart = 0, srcLines = 0, dstStart = 0, dstLines = 0 }
        end

        if l.type == Delete then
            srcLineNum = srcLineNum + 1
            block.srcLines = block.srcLines + 1
            modifiedLines = modifiedLines + 1
        elseif l.type == Insert then
            dstLineNum = dstLineNum + 1
            block.dstLines = block.dstLines + 1
            modifiedLines = modifiedLines + 1
        elseif l.type == Equal then
            srcLineNum = srcLineNum + 1
            dstLineNum = dstLineNum + 1
            block.srcLines = block.srcLines + 1
            block.dstLines = block.dstLines + 1
        end

        if block.srcStart == 0 and (l.type == Equal or l.type == Delete) then
            block.srcStart = srcLineNum
        end
        if block.dstStart == 0 and (l.type == Equal or l.type == Insert) then
            block.dstStart = dstLineNum
        end
    end
    updateHunks(block, true)

    -- Return no hunks if the diffs contain only equal lines.
    if modifiedLines == 0 then
        return nil
    end

    return hunks
end

-- typeSymbol returns the associated symbol of a DiffType.
function patience.typeSymbol(t)
    if t == Equal then
        return " "
    elseif t == Insert then
        return "+"
    elseif t == Delete then
        return "-"
    end
    error("unknown DiffType", 0)
end

-- UnifiedDiffOptions: { precontext, postcontext, srcHeader, dstHeader }.

-- UnifiedDiffTextWithOptions returns the diff text in unidiff format.
function patience.UnifiedDiffTextWithOptions(diffs, opts)
    local hunks = patience.makeHunks(diffs, opts.precontext or 0, opts.postcontext or 0)
    local s = {}
    if opts.srcHeader ~= nil and #opts.srcHeader > 0 then
        s[#s + 1] = "--- " .. opts.srcHeader
    end
    if opts.dstHeader ~= nil and #opts.dstHeader > 0 then
        s[#s + 1] = "+++ " .. opts.dstHeader
    end
    for _, h in ipairs(hunks or {}) do
        s[#s + 1] = "@@ -" .. h.srcStart .. "," .. h.srcLines .. " +" .. h.dstStart .. "," .. h.dstLines .. " @@"
        for _, l in ipairs(h.diffs) do
            if l.type == Equal and #l.text == 0 then
                s[#s + 1] = ""
            else
                s[#s + 1] = patience.typeSymbol(l.type) .. l.text
            end
        end
    end
    return table.concat(s, "\n")
end

-- UnifiedDiffText returns the diff text in unidiff format with a context of 3 lines.
function patience.UnifiedDiffText(diffs)
    return patience.UnifiedDiffTextWithOptions(diffs, { precontext = 3, postcontext = 3 })
end

return baseline
