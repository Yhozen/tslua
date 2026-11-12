-- Package spanmap provides bidirectional span-aware mapping between a content mapper's virtual text
-- and its original, untransformed source. Unlike a source map, which records
-- point correspondences and leaves spans and "no origin" implicit, a SpanMap records explicit segments
-- for the parts of the virtual text that correspond to the original; positions not covered by any
-- segment are synthesized (virtual content with no original counterpart). All positions are absolute
-- offsets (core.TextPos), matching the compiler's TextRange model.
local spanmap = require("tslua.spanmap")
local core = require("tslua.core")
local json = require("tslua.json")

-- Keep this in sync with spanMap.ts

local Kind = spanmap.Kind
local Feature = spanmap.Feature
local Fidelity = spanmap.Fidelity
local MappingErrorKind = spanmap.MappingErrorKind

local featureMask = Feature.All

-- IsExact reports whether the mapping was fully faithful — the input fell within a single verbatim span —
-- so the result maps 1:1 and can host a text edit written back to the original.
function spanmap.Fidelity_IsExact(f)
    return f == Fidelity.Exact
end

-- IsSingleSegment reports whether the input fell within one segment, verbatim or atom, so the result is a
-- concrete location rather than a best-effort approximation across boundaries or a synthesized gap.
function spanmap.Fidelity_IsSingleSegment(f)
    return f == Fidelity.Exact or f == Fidelity.Atom
end

-- IsNone reports whether the input had no original counterpart, meaning the mapped result is a synthesized
-- gap that does not correspond to any location in the original text.
function spanmap.Fidelity_IsNone(f)
    return f == Fidelity.None
end

-- Segment maps the half-open virtual range [VirtualStart, VirtualEnd) to the half-open original range
-- [OriginalStart, OriginalEnd). Features controls language-service participation; diagnostics and exact edit mapping
-- deliberately bypass it.
-- Segment is a Go value struct: an immutable table
-- { virtualStart, virtualEnd, originalStart, originalEnd, kind, features }.
-- NewSegment builds one from a (partial) Go struct literal; omitted fields take their zero value.
function spanmap.NewSegment(t)
    t = t or {}
    return {
        virtualStart = t.virtualStart or 0,
        virtualEnd = t.virtualEnd or 0,
        originalStart = t.originalStart or 0,
        originalEnd = t.originalEnd or 0,
        kind = t.kind or Kind.Verbatim,
        features = t.features or Feature.None,
    }
end

-- MappedPosition is one virtual projection of an original position and its mapping fidelity:
-- { position, fidelity }.
local function newMappedPosition(position, fidelity)
    return { position = position, fidelity = fidelity }
end

-- MappedSpan is one virtual projection of an original range and its mapping fidelity: { span, fidelity }.
local function newMappedSpan(span, fidelity)
    return { span = span, fidelity = fidelity }
end

-- SpanMap is a sparse, ordered set of segments over a content mapper's virtual text. Segments do not
-- need to cover the whole text: any virtual position not inside a segment is synthesized (it has no
-- original counterpart). An empty SpanMap therefore describes fully synthesized virtual text.
-- Methods that Go defines on a possibly-nil *SpanMap are also callable as spanmap.SpanMap.Method(nil, ...).
local SpanMap = {}
SpanMap.__index = SpanMap
spanmap.SpanMap = SpanMap

-- Validation failures. A content mapper is required to provide a valid span map; these describe the
-- ways a map can be malformed, so the compiler can attribute the failure to the mapper precisely and
-- point the mapper's author at the offending location.

-- MappingError describes a single span map validation failure, including the offsets involved so the mapper's
-- author can locate it. VirtualPos is an offset into the virtual text; OriginalPos is an offset into the
-- original content. Either may be unused (zero) depending on Kind.
local MappingError = {}
MappingError.__index = MappingError
spanmap.MappingError = MappingError

function spanmap.NewMappingError(kind, virtualPos, originalPos)
    return setmetatable({ kind = kind, virtualPos = virtualPos or 0, originalPos = originalPos or 0 }, MappingError)
end

-- Error describes the invalid mapping and the coordinate at which it was detected.
function MappingError:Error()
    local k = self.kind
    if k == MappingErrorKind.Overlap then
        return string.format("content mapper position mappings overlap or are out of order near virtual offset %d", self.virtualPos)
    elseif k == MappingErrorKind.OutOfBounds then
        return string.format("content mapper position mapping points outside the original content at original offset %d", self.originalPos)
    elseif k == MappingErrorKind.VerbatimMismatch then
        return string.format("content mapper verbatim mapping does not match the original content at virtual offset %d, original offset %d", self.virtualPos, self.originalPos)
    elseif k == MappingErrorKind.Kind then
        return string.format("content mapper position mapping has an invalid kind at virtual offset %d", self.virtualPos)
    elseif k == MappingErrorKind.OriginalOverlap then
        return string.format("content mapper position mappings partially overlap in the original content near offset %d", self.originalPos)
    elseif k == MappingErrorKind.Feature then
        return string.format("content mapper position mappings have invalid features near original offset %d", self.originalPos)
    end
    return "content mapper produced an invalid position mapping"
end

-- Validate enforces the content-mapper span map contract against the virtual and original text: the
-- segments must be ordered and disjoint in virtual space and stay within the virtual text, every
-- original span must lie within the original text, and every verbatim segment's text must match the
-- original exactly. Gaps are allowed (they map as synthesized) and an empty map is valid. It returns the
-- first violation found, or nil if the map is valid.
function SpanMap.Validate(m, virtual, original)
    if m == nil then
        return nil
    end
    local virtualLen = #virtual
    local origLen = #original
    local previousVirtualEnd = 0
    for _, s in ipairs(m.segments) do
        if s.virtualStart < previousVirtualEnd or s.virtualEnd < s.virtualStart or s.virtualEnd > virtualLen then
            return spanmap.NewMappingError(MappingErrorKind.Overlap, s.virtualStart, 0)
        end
        previousVirtualEnd = s.virtualEnd
        if s.originalStart < 0 or s.originalEnd < s.originalStart or s.originalEnd > origLen then
            return spanmap.NewMappingError(MappingErrorKind.OutOfBounds, s.virtualStart, s.originalEnd)
        end
        if s.kind ~= Kind.Verbatim and s.kind ~= Kind.Atom and s.kind ~= Kind.Alias then
            return spanmap.NewMappingError(MappingErrorKind.Kind, s.virtualStart, s.originalStart)
        end
        if s.kind == Kind.Verbatim then
            if s.virtualEnd - s.virtualStart ~= s.originalEnd - s.originalStart or
                string.sub(virtual, s.virtualStart + 1, s.virtualEnd) ~= string.sub(original, s.originalStart + 1, s.originalEnd) then
                return spanmap.NewMappingError(MappingErrorKind.VerbatimMismatch, s.virtualStart, s.originalStart)
            end
        end
        if s.features & ~featureMask ~= 0 then
            return spanmap.NewMappingError(MappingErrorKind.Feature, s.virtualStart, s.originalStart)
        end
    end
    local originalSegments = m:origIndex()
    local i = 0
    while i < #originalSegments do
        local groupEnd = i + 1
        while groupEnd < #originalSegments and originalSegments[groupEnd + 1].originalStart == originalSegments[i + 1].originalStart and originalSegments[groupEnd + 1].originalEnd == originalSegments[i + 1].originalEnd do
            groupEnd = groupEnd + 1
        end
        if i > 0 and originalSegments[i + 1].originalStart < originalSegments[i].originalEnd then
            return spanmap.NewMappingError(MappingErrorKind.OriginalOverlap, originalSegments[i + 1].virtualStart, originalSegments[i + 1].originalStart)
        end
        i = groupEnd
    end
    return nil
end

-- New builds a SpanMap from segments, sorted by virtual start. Segments describe only the parts of the
-- virtual text that correspond to the original; anything not covered maps as synthesized.
function spanmap.New(segments)
    local sorted = core.Slice(segments, 0)
    core.SortFunc(sorted, function(a, b)
        return a.virtualStart - b.virtualStart
    end)
    return setmetatable({ segments = sorted, origSorted = nil }, SpanMap)
end

-- Segments returns the map's segments ordered by virtual start.
function SpanMap.Segments(m)
    if m == nil then
        return nil
    end
    return core.Slice(m.segments, 0)
end

-- VirtualToOriginalSpan maps a virtual range to an original range, along with the fidelity of the result. A virtual
-- range that lies entirely in a gap between segments (or in an empty map) is synthesized: it maps to the
-- insertion point in the original with FidelityNone. A nil SpanMap maps identically.
-- Returns (core.TextRange, Fidelity).
function SpanMap.VirtualToOriginalSpan(m, r)
    if m == nil then
        return r, Fidelity.Exact
    end
    local virtualStart = r:Pos()
    local virtualEnd = math.max(r:End(), virtualStart)

    local startIdx, startIn = m:segmentIndexAt(virtualStart)
    local endProbe = virtualEnd
    if virtualEnd > virtualStart then
        endProbe = virtualEnd - 1
    end
    local endIdx, endIn = m:segmentIndexAt(endProbe)

    if startIdx == endIdx and startIn == endIn then
        if startIn then
            local seg = m.segments[startIdx + 1]
            if seg.kind == Kind.Verbatim then
                local origStart = spanmap.clamp(seg.originalStart + (virtualStart - seg.virtualStart), seg.originalStart, seg.originalEnd)
                local origEnd = spanmap.clamp(seg.originalStart + (virtualEnd - seg.virtualStart), origStart, seg.originalEnd)
                return core.NewTextRange(origStart, origEnd), Fidelity.Exact
            end
            return core.NewTextRange(seg.originalStart, seg.originalEnd), Fidelity.Atom
        end
        -- Entirely within a single synthesized gap.
        local pos = m:insertionPoint(startIdx)
        return core.NewTextRange(pos, pos), Fidelity.None
    end

    local origStart = m:mapLow(virtualStart, startIdx, startIn)
    local origEnd = math.max(m:mapHigh(virtualEnd, endIdx, endIn), origStart)
    return core.NewTextRange(origStart, origEnd), Fidelity.Approximate
end

-- VirtualToOriginalSpanForFeature maps r only when every virtual position in the non-empty range is
-- covered by contiguous segments participating in feature. A zero-length range requires its containing
-- segment to participate. Diagnostics and edit write-back intentionally use VirtualToOriginalSpan instead.
function SpanMap.VirtualToOriginalSpanForFeature(m, r, feature)
    local mapped, fidelity = SpanMap.VirtualToOriginalSpan(m, r)
    if m == nil or m:virtualSpanSupportsFeature(r, feature) then
        return mapped, fidelity
    end
    return mapped, Fidelity.None
end

function SpanMap:virtualSpanSupportsFeature(r, feature)
    local start = r:Pos()
    local end_ = math.max(r:End(), start)
    if start == end_ then
        local index, inside = self:segmentIndexAt(start)
        return inside and spanmap.supportsFeature(self.segments[index + 1], feature)
    end
    local index, inside = self:segmentIndexAt(start)
    if not inside then
        return false
    end
    local coveredThrough = start
    while index < #self.segments and coveredThrough < end_ do
        local segment = self.segments[index + 1]
        if segment.virtualStart > coveredThrough or segment.virtualEnd <= coveredThrough or not spanmap.supportsFeature(segment, feature) then
            return false
        end
        coveredThrough = segment.virtualEnd
        index = index + 1
    end
    return coveredThrough >= end_
end

-- VirtualToOriginalPosition maps a single virtual position to the corresponding original position, along with the
-- fidelity of the result. It is the single-position analog of VirtualToOriginalSpan: a position in a gap (or in an empty
-- map) is synthesized and maps to the insertion point with FidelityNone. A nil SpanMap maps identically.
function SpanMap.VirtualToOriginalPosition(m, pos)
    if m == nil then
        return pos, Fidelity.Exact
    end
    local idx, in_ = m:segmentIndexAt(pos)
    if not in_ then
        return m:insertionPoint(idx), Fidelity.None
    end
    local seg = m.segments[idx + 1]
    if seg.kind == Kind.Verbatim then
        return spanmap.clamp(seg.originalStart + (pos - seg.virtualStart), seg.originalStart, seg.originalEnd), Fidelity.Exact
    end
    return seg.originalStart, Fidelity.Atom
end

-- VirtualToOriginalPositionForFeature maps pos only when its virtual segment participates in feature.
-- Diagnostics and edit write-back intentionally use VirtualToOriginalPosition instead.
function SpanMap.VirtualToOriginalPositionForFeature(m, pos, feature)
    local mapped, fidelity = SpanMap.VirtualToOriginalPosition(m, pos)
    if m == nil then
        return mapped, fidelity
    end
    local index, inside = m:segmentIndexAt(pos)
    if not inside or not spanmap.supportsFeature(m.segments[index + 1], feature) then
        return mapped, Fidelity.None
    end
    return mapped, fidelity
end

-- AliasForVirtualSpan returns the alias segment exactly covering r. Partial overlap does not qualify:
-- diagnostic text may be substituted only when the diagnostic identifies the complete virtual alias.
function SpanMap.AliasForVirtualSpan(m, r)
    if m == nil then
        return spanmap.NewSegment(), false
    end
    local index, inside = m:segmentIndexAt(r:Pos())
    if not inside then
        return spanmap.NewSegment(), false
    end
    local segment = m.segments[index + 1]
    return segment, segment.kind == Kind.Alias and r:Pos() == segment.virtualStart and r:End() == segment.virtualEnd
end

-- binarySearchFunc is Go's slices.BinarySearchFunc: the 0-based position where target would be
-- inserted (the first element e with cmp(e, target) >= 0), and whether cmp(e, target) == 0 there.
function spanmap.binarySearchFunc(xs, target, cmp)
    local n = #xs
    local i, j = 0, n
    while i < j do
        local h = (i + j) >> 1
        if cmp(xs[h + 1], target) < 0 then
            i = h + 1
        else
            j = h
        end
    end
    return i, i < n and cmp(xs[i + 1], target) == 0
end

-- segmentIndexAt returns the index of the segment containing pos and true, or, when pos lies in a gap,
-- the index of the segment immediately before pos (-1 if none) and false.
function SpanMap:segmentIndexAt(pos)
    local idx, found = spanmap.binarySearchFunc(self.segments, pos, function(s, p)
        return s.virtualStart - p
    end)
    if found then
        return idx, true
    end
    local prev = idx - 1
    if prev >= 0 and pos < self.segments[prev + 1].virtualEnd then
        return prev, true
    end
    return prev, false
end

-- insertionPoint returns the original offset where synthesized content following segment prev sits: the
-- original end of that segment, or 0 before the first segment.
function SpanMap:insertionPoint(prev)
    if prev < 0 then
        return 0
    end
    return self.segments[prev + 1].originalEnd
end

-- mapLow maps a virtual lower range boundary to original coordinates. A boundary in a synthesized
-- gap uses that gap's insertion point; an atom uses its original start.
function SpanMap:mapLow(pos, idx, in_)
    if not in_ then
        return self:insertionPoint(idx)
    end
    local seg = self.segments[idx + 1]
    if seg.kind == Kind.Verbatim then
        return spanmap.clamp(seg.originalStart + (pos - seg.virtualStart), seg.originalStart, seg.originalEnd)
    end
    return seg.originalStart
end

-- mapHigh maps a virtual upper range boundary to original coordinates. A boundary in a synthesized
-- gap uses that gap's insertion point; an atom uses its original end.
function SpanMap:mapHigh(pos, idx, in_)
    if not in_ then
        return self:insertionPoint(idx)
    end
    local seg = self.segments[idx + 1]
    if seg.kind == Kind.Verbatim then
        return spanmap.clamp(seg.originalStart + (pos - seg.virtualStart), seg.originalStart, seg.originalEnd)
    end
    return seg.originalEnd
end

-- OriginalToVirtualPositions returns every virtual projection of an original position whose segment
-- participates in feature. Segment ends are inclusive for point mapping, so a position shared by adjacent
-- original spans returns projections from both sides. Results are ordered by virtual position. It returns
-- no results for an uncovered position or when all touching segments reject feature. A nil SpanMap maps identically.
function SpanMap.OriginalToVirtualPositions(m, pos, feature)
    if m == nil then
        return { newMappedPosition(pos, Fidelity.Exact) }
    end
    local groups = spanmap.segmentGroupsAtOriginalPosition(m:origIndex(), pos)
    if #groups == 0 then
        return nil
    end
    local results = nil
    for _, group in ipairs(groups) do
        for _, segment in ipairs(group.segments) do
            if spanmap.supportsFeature(segment, feature) then
                local position = 0
                local fidelity = Fidelity.Atom
                if segment.kind == Kind.Verbatim then
                    position = spanmap.clamp(segment.virtualStart + (pos - segment.originalStart), segment.virtualStart, segment.virtualEnd)
                    fidelity = Fidelity.Exact
                elseif group.atEnd then
                    position = segment.virtualEnd
                else
                    position = segment.virtualStart
                end
                local contains = false
                for _, r in ipairs(results or {}) do
                    if r.position == position and r.fidelity == fidelity then
                        contains = true
                        break
                    end
                end
                if not contains then
                    results = core.Append(results, newMappedPosition(position, fidelity))
                end
            end
        end
    end
    core.SortFunc(results, function(a, b)
        return a.position - b.position
    end)
    return results
end

-- OriginalToVirtualSpans returns every feature-compatible virtual projection of an original range.
-- A range contained by one duplicate group produces one exact or atom result per matching group member.
--
-- A range that starts in one group and ends in another can have several possible virtual ranges. For
-- example, suppose two original segments are each copied twice into the virtual text:
--
--	original:   [ A ][ B ]
--	               [---)       range from inside A to inside B
--
--	virtual:    [ A ][ B ]      [ A ][ B ]
--	               ^   ^          ^   ^
--	             start end      start end
--	               1   3          11  13
--
-- The map says that the range may start at 1 or 11 and end at 3 or 13, but it does not say which copy of A
-- belongs with which copy of B. We choose the smallest range around each possible location, producing [1,3)
-- and [11,13). We do not return [1,13), because it contains both smaller candidates and would include code
-- that may be unrelated to the original range. These cross-group results have approximate fidelity.
-- If either boundary is uncovered or disabled for feature, there are no results. A nil SpanMap maps identically.
function SpanMap.OriginalToVirtualSpans(m, r, feature)
    if m == nil then
        return { newMappedSpan(r, Fidelity.Exact) }
    end
    local start = r:Pos()
    local end_ = math.max(r:End(), start)
    local lastCharacter = end_
    if end_ > start then
        lastCharacter = lastCharacter - 1
    end
    local originalSegments = m:origIndex()
    local startSegments, startInside = spanmap.segmentsAtOriginalPosition(originalSegments, start)
    local endSegments, endInside = spanmap.segmentsAtOriginalPosition(originalSegments, lastCharacter)
    if not startInside or not endInside then
        return nil
    end
    if spanmap.sameOriginalRange(startSegments[1], endSegments[1]) then
        return spanmap.originalToVirtualSpansInGroup(startSegments, start, end_, feature)
    end
    local starts = spanmap.originalStartProjections(startSegments, start, feature)
    local ends = spanmap.originalEndProjections(endSegments, end_, feature)
    if #starts == 0 or #ends == 0 then
        return nil
    end
    local results = {}
    for i1, virtualStart in ipairs(starts) do
        local i = i1 - 1
        local endIndex = spanmap.binarySearchFunc(ends, virtualStart, function(e, t)
            return e - t
        end)
        if not (endIndex == #ends or i + 1 < #starts and starts[i + 2] <= ends[endIndex + 1]) then
            results[#results + 1] = newMappedSpan(core.NewTextRange(virtualStart, ends[endIndex + 1]), Fidelity.Approximate)
        end
    end
    return results
end

-- OriginalToVirtualIntersectingSpans maps every feature-enabled segment intersection with r.
-- Unlike OriginalToVirtualSpans, uncovered range endpoints do not suppress covered interior segments.
function SpanMap.OriginalToVirtualIntersectingSpans(m, r, feature)
    if m == nil then
        return { newMappedSpan(r, Fidelity.Exact) }
    end
    if r:Pos() == r:End() then
        return m:OriginalToVirtualSpans(r, feature)
    end
    local results = {}
    for _, segment in ipairs(m.segments) do
        if spanmap.supportsFeature(segment, feature) then
            local start = math.max(r:Pos(), segment.originalStart)
            local end_ = math.min(r:End(), segment.originalEnd)
            if start < end_ then
                if segment.kind == Kind.Verbatim then
                    results[#results + 1] = newMappedSpan(core.NewTextRange(
                        segment.virtualStart + (start - segment.originalStart),
                        segment.virtualStart + (end_ - segment.originalStart)
                    ), Fidelity.Exact)
                else
                    results[#results + 1] = newMappedSpan(core.NewTextRange(segment.virtualStart, segment.virtualEnd), Fidelity.Atom)
                end
            end
        end
    end
    return results
end

-- originalStartProjections maps the inclusive start of an original range through every matching segment.
-- Verbatim segments preserve the offset within the segment; atoms map to their virtual start.
--
-- For duplicate verbatim segments, the start keeps the same relative offset in every copy:
--
--	original:       [---------)
--	                   ^ start
--
--	virtual:    [---------)   [---------)
--	               ^             ^
--	             result        result
function spanmap.originalStartProjections(segments, start, feature)
    local results = {}
    for _, segment in ipairs(segments) do
        if spanmap.supportsFeature(segment, feature) then
            if segment.kind == Kind.Verbatim then
                results[#results + 1] = spanmap.clamp(segment.virtualStart + (start - segment.originalStart), segment.virtualStart, segment.virtualEnd)
            else
                results[#results + 1] = segment.virtualStart
            end
        end
    end
    return results
end

-- originalEndProjections maps the exclusive end of an original range through every matching segment.
-- The caller uses end-1 to find the segment containing the final character, while this helper maps the end
-- boundary itself. Verbatim segments preserve that boundary; atoms map to their virtual end.
--
-- The lookup uses end-1 so an end at a segment boundary selects the segment on its left, not the next one:
--
--	original:       [---------)[ next segment )
--	                         ^`-- end
--	                         `--- end-1
--
--	virtual:    [---------)   [---------)
--	                      ^             ^
--	                    result        result
function spanmap.originalEndProjections(segments, end_, feature)
    local results = {}
    for _, segment in ipairs(segments) do
        if spanmap.supportsFeature(segment, feature) then
            if segment.kind == Kind.Verbatim then
                results[#results + 1] = spanmap.clamp(segment.virtualStart + (end_ - segment.originalStart), segment.virtualStart, segment.virtualEnd)
            else
                results[#results + 1] = segment.virtualEnd
            end
        end
    end
    return results
end

-- originalToVirtualSpansInGroup maps a range whose boundaries are known to lie in segments.
function spanmap.originalToVirtualSpansInGroup(segments, start, end_, feature)
    local results = {}
    for _, segment in ipairs(segments) do
        if spanmap.supportsFeature(segment, feature) then
            if segment.kind == Kind.Verbatim then
                local virtualStart = spanmap.clamp(segment.virtualStart + (start - segment.originalStart), segment.virtualStart, segment.virtualEnd)
                local virtualEnd = spanmap.clamp(segment.virtualStart + (end_ - segment.originalStart), virtualStart, segment.virtualEnd)
                results[#results + 1] = newMappedSpan(core.NewTextRange(virtualStart, virtualEnd), Fidelity.Exact)
            else
                results[#results + 1] = newMappedSpan(core.NewTextRange(segment.virtualStart, segment.virtualEnd), Fidelity.Atom)
            end
        end
    end
    return results
end

-- sameOriginalRange reports whether two segments belong to the same duplicate group.
function spanmap.sameOriginalRange(left, right)
    return left.originalStart == right.originalStart and left.originalEnd == right.originalEnd
end

-- origIndex returns the segments ordered by OriginalStart, building it once on first use.
function SpanMap:origIndex()
    if self.origSorted == nil then
        local sorted = core.Slice(self.segments, 0)
        core.SortFunc(sorted, function(a, b)
            local c = a.originalStart - b.originalStart
            if c ~= 0 then
                return c
            end
            c = a.originalEnd - b.originalEnd
            if c ~= 0 then
                return c
            end
            return a.virtualStart - b.virtualStart
        end)
        self.origSorted = sorted
    end
    return self.origSorted
end

-- segmentsAtOriginalPosition returns the complete duplicate group of mapping segments containing the
-- original-text position pos. segments must be ordered by original start, original end, and virtual start.
-- Segment ends are exclusive; a segment start, including a zero-length segment, is considered contained.
-- It finds a candidate in O(log n), then scans only the duplicate group. The boolean reports whether any
-- group contains pos.
function spanmap.segmentsAtOriginalPosition(segments, pos)
    local index, found = spanmap.binarySearchFunc(segments, pos, function(segment, position)
        return segment.originalStart - position
    end)
    if not found then
        index = index - 1
    end
    if index < 0 or not (segments[index + 1].originalStart == pos or pos < segments[index + 1].originalEnd) then
        return nil, false
    end
    local start = index
    while start > 0 and spanmap.sameOriginalRange(segments[start], segments[index + 1]) do
        start = start - 1
    end
    local end_ = start + 1
    while end_ < #segments and spanmap.sameOriginalRange(segments[end_ + 1], segments[start + 1]) do
        end_ = end_ + 1
    end
    return core.Slice(segments, start, end_), true
end

-- segmentGroupsAtOriginalPosition returns groups of mapping segments containing or touching the original-text
-- position pos. Interior positions return one group. At a boundary between adjacent groups, both the group ending
-- at pos and the group starting at pos are returned. segments must be ordered by original start, original end,
-- then virtual start.
--
-- At a shared boundary, segments ending at pos and segments starting there form separate groups:
--
--	original:  [--- A ---)[--- B ---)
--	                      ^ pos
--
--	virtual:   [ A1 ) [ A2 )    [ B1 ) [ B2 )
--	             left group       right group
--	             atEnd: true      atEnd: false
--
-- Each group is { segments = []Segment, atEnd = bool }.
function spanmap.segmentGroupsAtOriginalPosition(segments, pos)
    local index, startsAtPosition = spanmap.binarySearchFunc(segments, pos, function(segment, position)
        return segment.originalStart - position
    end)
    if startsAtPosition then
        local right = spanmap.segmentsAtOriginalPosition(segments, pos)
        local groups = {}
        if index > 0 then
            local leftIndex = index - 1
            if segments[leftIndex + 1].originalEnd == pos then
                local leftStart = leftIndex
                while leftStart > 0 and spanmap.sameOriginalRange(segments[leftStart], segments[leftIndex + 1]) do
                    leftStart = leftStart - 1
                end
                groups[#groups + 1] = { segments = core.Slice(segments, leftStart, index), atEnd = true }
            end
        end
        groups[#groups + 1] = { segments = right, atEnd = false }
        return groups
    end
    if index == 0 then
        return {}
    end
    local leftIndex = index - 1
    local segment = segments[leftIndex + 1]
    if pos > segment.originalEnd then
        return {}
    end
    local start = leftIndex
    while start > 0 and spanmap.sameOriginalRange(segments[start], segment) do
        start = start - 1
    end
    return { { segments = core.Slice(segments, start, index), atEnd = pos == segment.originalEnd } }
end

-- supportsFeature reports whether segment participates in feature.
function spanmap.supportsFeature(segment, feature)
    return segment.features & feature ~= 0
end

-- clamp confines v to the inclusive interval [lo, hi].
function spanmap.clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi))
end

-- decodeInt32 converts a decoded JSON value to a Go int32 like json.Unmarshal into an int32 field
-- (JSON null leaves the zero value). Returns (value, err).
local function decodeInt32(v)
    if v == json.Null or v == nil then
        return 0, nil
    end
    if type(v) ~= "number" then
        return 0, "json: cannot unmarshal JSON " .. type(v) .. " into Go int32"
    end
    if v ~= math.floor(v) or v < -2147483648 or v > 2147483647 then
        return 0, "json: cannot unmarshal JSON number " .. json.formatNumber(v) .. " into Go int32"
    end
    return math.tointeger(v), nil
end

-- Unmarshal decodes a SpanMap from the JSON tuple form produced by an out-of-process content mapper.
-- Five-element tuples omit features and are normalized to FeatureAll; six-element tuples preserve the
-- explicit feature mask, including FeatureNone. Returns (*SpanMap, err).
function spanmap.Unmarshal(data)
    local tuples, err = json.Unmarshal(data)
    if err ~= nil then
        return nil, err
    end
    if tuples == nil then
        tuples = {}
    end
    if type(tuples) ~= "table" or getmetatable(tuples) ~= nil then
        return nil, "json: cannot unmarshal JSON value into Go [][]int32"
    end
    local segments = {}
    for i1, t in ipairs(tuples) do
        local values = {}
        if t ~= json.Null then
            if type(t) ~= "table" or getmetatable(t) ~= nil then
                return nil, "json: cannot unmarshal JSON value into Go []int32"
            end
            for j, v in ipairs(t) do
                local n, verr = decodeInt32(v)
                if verr ~= nil then
                    return nil, verr
                end
                values[j] = n
            end
        end
        if #values ~= 5 and #values ~= 6 then
            return nil, string.format("span map segment %d: expected 5 or 6 values, got %d", i1 - 1, #values)
        end
        local features = Feature.All
        if #values == 6 then
            features = values[6]
        end
        segments[i1] = spanmap.NewSegment({
            virtualStart = values[1],
            virtualEnd = values[1] + values[2],
            originalStart = values[3],
            originalEnd = values[3] + values[4],
            kind = values[5],
            features = features,
        })
    end
    return spanmap.New(segments), nil
end

-- Marshal encodes a SpanMap into the JSON tuple form. FeatureAll uses the backward-compatible five-element
-- tuple; every other feature mask is emitted as a sixth element. Returns (string, err).
function SpanMap:Marshal()
    local tuples = {}
    for i, s in ipairs(self.segments) do
        local tuple = {
            s.virtualStart,
            s.virtualEnd - s.virtualStart,
            s.originalStart,
            s.originalEnd - s.originalStart,
            s.kind,
        }
        if s.features ~= Feature.All then
            tuple[#tuple + 1] = s.features
        end
        local parts = {}
        for j, v in ipairs(tuple) do
            parts[j] = string.format("%d", v)
        end
        tuples[i] = "[" .. table.concat(parts, ",") .. "]"
    end
    return "[" .. table.concat(tuples, ",") .. "]", nil
end
