local lsconv = require("tslua.ls.lsconv")
local core = require("tslua.core")

-- LSPLineMap: { lineStarts (array of 0-based byte offsets), asciiOnly }
local LSPLineMap = {}
LSPLineMap.__index = LSPLineMap
lsconv.LSPLineMap = LSPLineMap

function lsconv.ComputeLSPLineStarts(text)
    -- This is like core.ComputeLineStarts, but only considers "\n", "\r", and "\r\n" as line breaks,
    -- and reports when the text is ASCII-only.
    local lineStarts = {}
    local asciiOnly = true

    local textLen = #text
    local pos = 0
    local lineStart = 0
    while pos < textLen do
        local b = string.byte(text, pos + 1)
        if b < 0x80 then
            pos = pos + 1
            if b == 0x0D then
                if pos < textLen and string.byte(text, pos + 1) == 0x0A then
                    pos = pos + 1
                end
                lineStarts[#lineStarts + 1] = lineStart
                lineStart = pos
            elseif b == 0x0A then
                lineStarts[#lineStarts + 1] = lineStart
                lineStart = pos
            end
        else
            local _, size = core.DecodeRune(text, pos)
            pos = pos + size
            asciiOnly = false
        end
    end
    lineStarts[#lineStarts + 1] = lineStart

    return setmetatable({
        lineStarts = lineStarts,
        asciiOnly = asciiOnly,
    }, LSPLineMap)
end

-- Go slices.BinarySearch over sorted ints: returns (0-based index, found).
function lsconv.binarySearchInts(xs, target)
    local lo, hi = 0, #xs
    while lo < hi do
        local mid = (lo + hi) // 2
        if xs[mid + 1] < target then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo, lo < #xs and xs[lo + 1] == target
end

function LSPLineMap:ComputeIndexOfLineStart(targetPos)
    -- port of computeLineOfPosition(lineStarts: readonly number[], position: number, lowerBound?: number): number {
    local lineNumber, ok = lsconv.binarySearchInts(self.lineStarts, targetPos)
    if not ok and lineNumber > 0 then
        -- If the actual position was not found, the binary search returns where the target line start would be inserted
        -- if the target was in the slice.
        -- e.g. if the line starts at [5, 10, 23, 80] and the position requested was 20
        -- then the search will return (3, false).
        --
        -- We want the index of the previous line start, so we subtract 1.
        lineNumber = lineNumber - 1
    end
    return lineNumber
end
