local encoder = require("tslua.api.encoder")
local ast = require("tslua.ast")
local core = require("tslua.core")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local NodeSize = encoder.NodeSize
local NodeOffsetNext = encoder.NodeOffsetNext

-- Lua representation notes:
--   * Encoded data ([]byte) is a Lua string.
--   * The nodes section and the extended data section only ever contain uint32 values, so while
--     encoding they are kept as arrays of uint32 words (byte offset = 4 * word index); the
--     structured data section is an encoder.ByteBuf.

if ast.Kind.LastUnaryOperator > 0x3f then
    error("KindLastUnaryOperator (" .. tostring(ast.Kind.LastUnaryOperator) .. ") exceeds the 6-bit commonData capacity (max 63)", 0)
end

-- Source File Binary Format: see the Go source (internal/api/encoder/encoder.go) for the full
-- description of the header, string offsets, string data, extended node data, structured data and
-- nodes sections.

-- SourceFileHash returns the 128-bit content hash for a source file as a hex string.
function encoder.SourceFileHash(sourceFile)
    local h = sourceFile.hash
    local hi, lo = 0, 0
    if h ~= nil then
        hi, lo = h.hi, h.lo
    end
    return string.format("%016x%016x", hi, lo)
end

-- encodeParseOptions encodes the per-file ExternalModuleIndicatorOptions as a uint32 bitmask.
function encoder.encodeParseOptions(opts)
    local bits = 0
    if opts.jsx then
        bits = bits | 1
    end
    if opts.force then
        bits = bits | 2
    end
    return bits
end

-- NodeIndexTable maps between AST nodes and their encoder indices for O(1) node handle resolution.
-- nodes is a Lua array holding Go's Nodes slice (index 0 = nil sentinel, stored as false since Lua
-- arrays cannot hold nil; NodeLists are false too).
local NodeIndexTable = {}
NodeIndexTable.__index = NodeIndexTable
encoder.NodeIndexTable = NodeIndexTable

function encoder.newNodeIndexTable(nodes)
    return setmetatable({ nodes = nodes, sortedOnce = false, sortedIdx = nil }, NodeIndexTable)
end

-- Node returns Go's Nodes[i] (nil for the sentinel and NodeLists, or when out of range).
function NodeIndexTable:Node(i)
    local n = self.nodes[i + 1]
    if n == false then
        return nil
    end
    return n
end

-- Len returns len(Nodes).
function NodeIndexTable:Len()
    return #self.nodes
end

local nodeIndexTableKey = ast.NewSourceFileDataKey()
encoder.nodeIndexTableKey = nodeIndexTableKey

-- GetIndex returns the encoder index for the given node.
-- On the first call the sortedIdx array is built (O(n log n) sort on a flat []uint32),
-- then subsequent calls use binary search (O(log n)). This turns out to be much faster than
-- building a map[*ast.Node]uint32 and not significantly slower for lookups.
function NodeIndexTable:GetIndex(node)
    if not self.sortedOnce then
        self.sortedOnce = true
        local idx = {}
        for i, n in ipairs(self.nodes) do
            if n ~= false then
                idx[#idx + 1] = i - 1
            end
        end
        local nodes = self.nodes
        table.sort(idx, function(a, b)
            return ast.GetNodeId(nodes[a + 1]) < ast.GetNodeId(nodes[b + 1])
        end)
        self.sortedIdx = idx
    end
    local target = ast.GetNodeId(node)
    local i, found = core.BinarySearchUniqueFunc(self.sortedIdx, function(_, el)
        local id = ast.GetNodeId(self.nodes[el + 1])
        if id < target then
            return -1
        elseif id > target then
            return 1
        end
        return 0
    end)
    if found then
        return self.sortedIdx[i + 1]
    end
    return 0
end

-- BuildNodeIndexTable walks the AST in the same order as encodeTree and builds
-- a NodeIndexTable without performing the full binary encoding. This is used to
-- eagerly create index tables for files that need node handles before getSourceFile
-- is called. The indices produced are guaranteed to match those from EncodeSourceFile.
function encoder.BuildNodeIndexTable(sourceFile)
    local nodeCount = 0
    local nodeTable = { false } -- index 0 = nil sentinel

    local visitor
    visitor = ast.NewNodeVisitor(nil, nil, {
        visitNodes = function(nodeList, v)
            if nodeList == nil then
                return nodeList
            end
            nodeCount = nodeCount + 1
            nodeTable[#nodeTable + 1] = false -- NodeLists are not *ast.Node
            v:VisitSlice(nodeList.nodes)
            return nodeList
        end,
        visitModifiers = function(modifiers, v)
            if modifiers ~= nil and #modifiers.nodes > 0 then
                v.hooks.visitNodes(modifiers, v)
            end
            return modifiers
        end,
    })
    visitor.visit = function(node)
        nodeCount = nodeCount + 1
        nodeTable[#nodeTable + 1] = node
        visitor:VisitEachChild(node)
        for _, jsdoc in ipairs(node:JSDoc(sourceFile) or {}) do
            visitor.visit(jsdoc)
        end
        return node
    end

    local rootNode = sourceFile
    -- Index 1 = root node (matches encodeTree)
    nodeCount = nodeCount + 1
    nodeTable[#nodeTable + 1] = rootNode

    visitor:VisitEachChild(rootNode)
    for _, jsdoc in ipairs(rootNode:JSDoc(sourceFile) or {}) do
        visitor.visit(jsdoc)
    end

    return encoder.newNodeIndexTable(nodeTable)
end

function encoder.GetNodeIndexTable(sourceFile)
    return ast.GetOrComputeSourceFileData(sourceFile, nodeIndexTableKey, encoder.BuildNodeIndexTable)
end

-- EncodeSourceFile encodes an entire source file AST into the binary format.
-- Returns the encoded bytes and a NodeIndexTable mapping encoder indices to AST nodes.
-- Returns (data, nodeTable, err).
function encoder.EncodeSourceFile(sourceFile)
    local data, nodeTable, err = encoder.encodeTree(sourceFile, sourceFile)
    if err ~= nil then
        return nil, nil, err
    end
    nodeTable = ast.GetOrComputeSourceFileData(sourceFile, nodeIndexTableKey, function()
        return nodeTable
    end)
    return data, nodeTable, nil
end

-- EncodeNode encodes an arbitrary AST node and its descendants into the binary format.
-- The sourceFile is needed to provide the source text for efficient string encoding.
-- When encoding a non-SourceFile node, the header hash and parse options fields will be zero.
-- Returns the encoded bytes and a NodeIndexTable mapping encoder indices to AST nodes.
function encoder.EncodeNode(node, sourceFile)
    return encoder.encodeTree(node, sourceFile)
end

-- Appends uint32 words to a word array.
local function appendWords(words, ...)
    local n = #words
    for i = 1, select("#", ...) do
        words[n + i] = (select(i, ...))
    end
end

function encoder.encodeTree(rootNode, sourceFile)
    local parentIndex, nodeCount, prevIndex = 0, 0, 0
    local extendedData = {} -- uint32 words
    local structuredData = encoder.newByteBuf()
    local strs
    local positionMap
    if rootNode.kind == Kind.SourceFile then
        strs = encoder.newStringTable(sourceFile:Text(), sourceFile.textCount)
        positionMap = sourceFile:GetPositionMap()
    else
        strs = encoder.newStringTable("", 0)
        if sourceFile ~= nil then
            positionMap = sourceFile:GetPositionMap()
        end
    end
    if positionMap == nil then
        positionMap = ast.ComputePositionMap("")
    end
    local function utf16(pos)
        return positionMap:UTF8ToUTF16(pos) & 0xFFFFFFFF
    end
    local nodes = {} -- uint32 words, NodeSize/4 per node

    -- Build node index table for O(1) handle resolution.
    -- Index 0 is a nil sentinel; real nodes start at index 1.
    local nodeTable = { false } -- index 0 = nil sentinel

    -- Build a small map of nodes we need to track indices for (imports + moduleAugmentations).
    -- Values start at 0 and are filled in during the walk.
    local nodeIndexMap
    local sfExtendedDataOffset -- word offset in extendedData where SourceFile fields start
    if rootNode.kind == Kind.SourceFile then
        local sf = rootNode
        local total = core.Len(sf:Imports()) + core.Len(sf.moduleAugmentations)
        if sf.externalModuleIndicator ~= nil and sf.externalModuleIndicator ~= rootNode then
            total = total + 1
        end
        if total > 0 then
            nodeIndexMap = {}
            for _, imp in ipairs(sf:Imports() or {}) do
                nodeIndexMap[imp] = 0
            end
            for _, aug in ipairs(sf.moduleAugmentations or {}) do
                nodeIndexMap[aug] = 0
            end
            if sf.externalModuleIndicator ~= nil and sf.externalModuleIndicator ~= rootNode then
                nodeIndexMap[sf.externalModuleIndicator] = 0
            end
        end
    end

    local nextWord = NodeOffsetNext // 4
    local wordsPerNode = NodeSize // 4

    local visitor
    visitor = ast.NewNodeVisitor(nil, nil, {
        visitNodes = function(nodeList, v)
            if nodeList == nil then
                return nodeList
            end

            nodeCount = nodeCount + 1
            nodeTable[#nodeTable + 1] = false -- NodeLists are not *ast.Node
            if prevIndex ~= 0 then
                -- this is the next sibling of `prevNode`
                nodes[prevIndex * wordsPerNode + nextWord + 1] = nodeCount
            end

            appendWords(nodes, encoder.SyntaxKindNodeList, utf16(nodeList:Pos()), utf16(nodeList:End()), 0, parentIndex, #nodeList.nodes, 0)

            local saveParentIndex = parentIndex

            local currentIndex = nodeCount
            prevIndex = 0
            parentIndex = currentIndex
            v:VisitSlice(nodeList.nodes)
            prevIndex = currentIndex
            parentIndex = saveParentIndex

            return nodeList
        end,
        visitModifiers = function(modifiers, v)
            if modifiers ~= nil and #modifiers.nodes > 0 then
                v.hooks.visitNodes(modifiers, v)
            end
            return modifiers
        end,
    })
    visitor.visit = function(node)
        nodeCount = nodeCount + 1
        nodeTable[#nodeTable + 1] = node
        if prevIndex ~= 0 then
            -- this is the next sibling of `prevNode`
            nodes[prevIndex * wordsPerNode + nextWord + 1] = nodeCount
        end

        appendWords(nodes, node.kind, utf16(node:Pos()), utf16(node:End()), 0, parentIndex, encoder.getNodeData(node, strs, positionMap, extendedData, structuredData), node.flags & 0xFFFFFFFF)

        if nodeIndexMap ~= nil then
            if nodeIndexMap[node] ~= nil then
                nodeIndexMap[node] = nodeCount
            end
        end

        local saveParentIndex = parentIndex

        local currentIndex = nodeCount
        prevIndex = 0
        parentIndex = currentIndex
        visitor:VisitEachChild(node)
        if sourceFile ~= nil then
            for _, jsdoc in ipairs(node:JSDoc(sourceFile) or {}) do
                visitor.visit(jsdoc)
            end
        end
        prevIndex = currentIndex
        parentIndex = saveParentIndex
        return node
    end

    appendWords(nodes, 0, 0, 0, 0, 0, 0, 0)

    nodeCount = nodeCount + 1
    parentIndex = parentIndex + 1
    nodeTable[#nodeTable + 1] = rootNode -- index 1 = root node

    sfExtendedDataOffset = #extendedData
    appendWords(nodes, rootNode.kind, utf16(rootNode:Pos()), utf16(rootNode:End()), 0, 0, encoder.getNodeData(rootNode, strs, positionMap, extendedData, structuredData), rootNode.flags & 0xFFFFFFFF)

    visitor:VisitEachChild(rootNode)
    if sourceFile ~= nil then
        for _, jsdoc in ipairs(rootNode:JSDoc(sourceFile) or {}) do
            visitor.visit(jsdoc)
        end
    end

    local hashLo, hashHi = 0, 0
    local parseOpts = 0
    if rootNode.kind == Kind.SourceFile then
        if sourceFile.hash ~= nil then
            hashLo, hashHi = sourceFile.hash.lo, sourceFile.hash.hi
        end
        parseOpts = encoder.encodeParseOptions(sourceFile:ParseOptions().externalModuleIndicatorOptions)

        -- Encode imports, moduleAugmentations, and ambientModuleNames into structured data,
        -- and patch the placeholder offsets in the SourceFile extended data.
        local sf = rootNode
        local importsOffset = encoder.encodeNodeIndexArray(sf:Imports(), nodeIndexMap, structuredData)
        local moduleAugmentationsOffset = encoder.encodeModuleAugmentations(sf.moduleAugmentations, nodeIndexMap, structuredData)
        local ambientModuleNamesOffset = encoder.encodeStringArray(sf.ambientModuleNames, structuredData)
        -- Patch the 3 placeholder uint32s at sfExtendedDataOffset + 32, 36, 40
        extendedData[sfExtendedDataOffset + 32 // 4 + 1] = importsOffset
        extendedData[sfExtendedDataOffset + 36 // 4 + 1] = moduleAugmentationsOffset
        extendedData[sfExtendedDataOffset + 40 // 4 + 1] = ambientModuleNamesOffset
        -- Patch externalModuleIndicator node index at offset 44
        local externalModuleIndicatorIndex = 0
        if sf.externalModuleIndicator ~= nil then
            if sf.externalModuleIndicator == rootNode then
                externalModuleIndicatorIndex = 1 -- root node index
            else
                externalModuleIndicatorIndex = nodeIndexMap[sf.externalModuleIndicator] or 0
            end
        end
        extendedData[sfExtendedDataOffset + 44 // 4 + 1] = externalModuleIndicatorIndex
    end

    local metadata = encoder.ProtocolVersion << 24
    local offsetStringTableOffsets = encoder.HeaderSize
    local offsetStringTableData = encoder.HeaderSize + #strs.offsets * 4
    local offsetExtendedData = offsetStringTableData + strs:stringLength()
    local offsetStructuredData = offsetExtendedData + #extendedData * 4
    local offsetNodes = offsetStructuredData + structuredData:Len()

    local header = {
        metadata,
        hashLo & 0xFFFFFFFF, (hashLo >> 32) & 0xFFFFFFFF,
        hashHi & 0xFFFFFFFF, (hashHi >> 32) & 0xFFFFFFFF,
        parseOpts,
        offsetStringTableOffsets,
        offsetStringTableData,
        offsetExtendedData,
        offsetStructuredData,
        offsetNodes,
    }

    local out = encoder.newByteBuf()
    encoder.appendUint32s(out, header)
    out:WriteString(strs:encode())
    encoder.appendUint32s(out, extendedData)
    out:WriteString(structuredData:Bytes())
    encoder.appendUint32s(out, nodes)

    return out:Bytes(), encoder.newNodeIndexTable(nodeTable), nil
end

-- appendUint32s appends the uint32 values of the array `values` to the ByteBuf in little-endian order.
function encoder.appendUint32s(buf, values)
    local parts = {}
    local chunk = 512
    for i = 1, #values, chunk do
        local last = math.min(i + chunk - 1, #values)
        local n = last - i + 1
        parts[#parts + 1] = string.pack("<" .. string.rep("I4", n), table.unpack(values, i, last))
    end
    buf:WriteString(table.concat(parts))
    return buf
end

-- extendedData is the word array of the extended data section; structuredData a ByteBuf.
function encoder.getNodeData(node, strs, positionMap, extendedData, structuredData)
    local t = encoder.getNodeDataType(node)
    if t == encoder.NodeDataTypeChildren then
        return t | encoder.getNodeCommonData(node) | encoder.getChildrenPropertyMask(node)
    elseif t == encoder.NodeDataTypeString then
        return t | encoder.getNodeCommonData(node) | encoder.recordNodeStrings(node, strs)
    elseif t == encoder.NodeDataTypeExtendedData then
        return t | encoder.getNodeCommonData(node) | encoder.recordExtendedData(node, strs, positionMap, extendedData, structuredData)
    end
    error("unreachable", 0)
end

local noStructuredData = 0xFFFFFFFF
encoder.noStructuredData = noStructuredData

function encoder.recordExtendedData_SourceFile(node, strs, positionMap, extendedData, structuredData)
    local sf = node
    local textIndex = strs:add(sf:Text(), sf.kind, sf:Pos(), sf:End())
    local originalTextIndex = textIndex
    if sf:OriginalText() ~= sf:Text() then
        originalTextIndex = strs:add(sf:OriginalText(), 0, 0, 0)
    end
    local fileNameIndex = strs:add(sf:FileName(), 0, 0, 0)
    local pathIndex = strs:add(sf:Path(), 0, 0, 0)
    local referencedFilesOffset = encoder.encodeFileReferences(sf.referencedFiles, positionMap, structuredData)
    local typeRefDirectivesOffset = encoder.encodeFileReferences(sf.typeReferenceDirectives, positionMap, structuredData)
    local libRefDirectivesOffset = encoder.encodeFileReferences(sf.libReferenceDirectives, positionMap, structuredData)
    local spanMapOffset = noStructuredData
    local spanMap = sf:SpanMap()
    if spanMap ~= nil then
        spanMapOffset = encoder.encodeSpanMap(spanMap, positionMap, ast.ComputePositionMap(sf:OriginalText()), structuredData)
    end
    local supplementalFileNames = core.Map(sf:SupplementalSourceFiles(), function(file)
        return file:FileName()
    end)
    local supplementalFileNamesOffset = encoder.encodeStringArray(supplementalFileNames, structuredData)
    local canonicalFileNameIndex = noStructuredData
    local canonical = sf:CanonicalSourceFile()
    if canonical ~= nil then
        canonicalFileNameIndex = strs:add(canonical:FileName(), 0, 0, 0)
    end
    local contentMapperIndex = noStructuredData
    local contentMapper = sf:ContentMapper()
    if contentMapper ~= "" then
        contentMapperIndex = strs:add(contentMapper, 0, 0, 0)
    end
    local virtualFileNameIndex = noStructuredData
    local virtualFileName = sf:VirtualFileName()
    if virtualFileName ~= "" then
        virtualFileNameIndex = strs:add(virtualFileName, 0, 0, 0)
    end
    local diagnosticDirectivesOffset = encoder.encodeDiagnosticDirectives(sf:DiagnosticDirectives(), positionMap, ast.ComputePositionMap(sf:OriginalText()), structuredData)
    -- imports, moduleAugmentations, ambientModuleNames offsets are placeholders;
    -- they will be patched after the tree walk when node indices are known.
    appendWords(extendedData, textIndex, fileNameIndex, pathIndex, sf.languageVariant, sf.scriptKind, referencedFilesOffset, typeRefDirectivesOffset, libRefDirectivesOffset, noStructuredData, noStructuredData, noStructuredData, 0, originalTextIndex, spanMapOffset, supplementalFileNamesOffset, canonicalFileNameIndex, contentMapperIndex, virtualFileNameIndex, diagnosticDirectivesOffset)
end

function encoder.recordExtendedData_TemplateHead(node, strs, positionMap, extendedData, structuredData)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    local rawTextIndex = strs:add(n.rawText, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, rawTextIndex, n.templateFlags & 0xFFFFFFFF)
end

function encoder.recordExtendedData_TemplateMiddle(node, strs, positionMap, extendedData, structuredData)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    local rawTextIndex = strs:add(n.rawText, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, rawTextIndex, n.templateFlags & 0xFFFFFFFF)
end

function encoder.recordExtendedData_TemplateTail(node, strs, positionMap, extendedData, structuredData)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    local rawTextIndex = strs:add(n.rawText, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, rawTextIndex, n.templateFlags & 0xFFFFFFFF)
end

function encoder.boolToByte(b)
    if b then
        return 1
    end
    return 0
end

-- hasModifiers returns true if the modifier list is non-nil and has at least one modifier.
function encoder.hasModifiers(modifiers)
    return modifiers ~= nil and #modifiers.nodes > 0
end

-- encodeFileReferences encodes a slice of FileReferences as a msgpack array of tuples
-- into the structured data buffer. Returns the byte offset into the buffer, or
-- noStructuredData (0xFFFFFFFF) if the slice is empty.
function encoder.encodeFileReferences(refs, positionMap, buf)
    if core.Len(refs) == 0 then
        return noStructuredData
    end
    local offset = buf:Len()
    encoder.msgpackWriteArrayHeader(buf, #refs)
    for _, ref in ipairs(refs) do
        -- Each entry is a 5-element tuple: [pos, end, fileName, resolutionMode, preserve]
        encoder.msgpackWriteArrayHeader(buf, 5)
        encoder.msgpackWriteUint(buf, positionMap:UTF8ToUTF16(ref:Pos()) & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, positionMap:UTF8ToUTF16(ref:End()) & 0xFFFFFFFF)
        encoder.msgpackWriteString(buf, ref.fileName)
        encoder.msgpackWriteUint(buf, ref.resolutionMode & 0xFFFFFFFF)
        encoder.msgpackWriteBool(buf, ref.preserve)
    end
    return offset
end

-- encodeNodeIndexArray encodes a slice of LiteralLikeNodes as a msgpack array of
-- uint node indices. Returns the byte offset into the buffer, or noStructuredData
-- if the slice is empty.
function encoder.encodeNodeIndexArray(nodes, indexMap, buf)
    if core.Len(nodes) == 0 then
        return noStructuredData
    end
    local offset = buf:Len()
    encoder.msgpackWriteArrayHeader(buf, #nodes)
    for _, node in ipairs(nodes) do
        encoder.msgpackWriteUint(buf, indexMap ~= nil and indexMap[node] or 0)
    end
    return offset
end

-- encodeModuleAugmentations encodes a slice of ModuleName nodes as a msgpack array
-- of uint node indices. Returns the byte offset into the buffer, or noStructuredData
-- if the slice is empty.
function encoder.encodeModuleAugmentations(nodes, indexMap, buf)
    if core.Len(nodes) == 0 then
        return noStructuredData
    end
    local offset = buf:Len()
    encoder.msgpackWriteArrayHeader(buf, #nodes)
    for _, node in ipairs(nodes) do
        encoder.msgpackWriteUint(buf, indexMap ~= nil and indexMap[node] or 0)
    end
    return offset
end

-- encodeStringArray encodes a slice of strings as a msgpack array of strings.
-- Returns the byte offset into the buffer, or noStructuredData if the slice is empty.
function encoder.encodeStringArray(strs, buf)
    if core.Len(strs) == 0 then
        return noStructuredData
    end
    local offset = buf:Len()
    encoder.msgpackWriteArrayHeader(buf, #strs)
    for _, s in ipairs(strs) do
        encoder.msgpackWriteString(buf, s)
    end
    return offset
end

function encoder.encodeSpanMap(m, virtualPositions, originalPositions, buf)
    if m == nil then
        return noStructuredData
    end
    local segments = m:Segments()
    local offset = buf:Len()
    encoder.msgpackWriteArrayHeader(buf, #segments)
    for _, segment in ipairs(segments) do
        local tupleLength = 5
        if segment.features ~= spanmap.Feature.All then
            tupleLength = 6
        end
        encoder.msgpackWriteArrayHeader(buf, tupleLength)
        local virtualStart = virtualPositions:UTF8ToUTF16(segment.virtualStart)
        local virtualEnd = virtualPositions:UTF8ToUTF16(segment.virtualEnd)
        local originalStart = originalPositions:UTF8ToUTF16(segment.originalStart)
        local originalEnd = originalPositions:UTF8ToUTF16(segment.originalEnd)
        encoder.msgpackWriteUint(buf, virtualStart & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, (virtualEnd - virtualStart) & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, originalStart & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, (originalEnd - originalStart) & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, segment.kind & 0xFFFFFFFF)
        if tupleLength == 6 then
            encoder.msgpackWriteUint(buf, segment.features & 0xFFFFFFFF)
        end
    end
    return offset
end

function encoder.encodeDiagnosticDirectives(directives, virtualPositions, originalPositions, buf)
    if core.Len(directives) == 0 then
        return noStructuredData
    end
    local offset = buf:Len()
    encoder.msgpackWriteArrayHeader(buf, #directives)
    for _, directive in ipairs(directives) do
        encoder.msgpackWriteArrayHeader(buf, 6)
        local originalStart = originalPositions:UTF8ToUTF16(directive.originalRange:Pos())
        local originalEnd = originalPositions:UTF8ToUTF16(directive.originalRange:End())
        local virtualStart = virtualPositions:UTF8ToUTF16(directive.virtualRange:Pos())
        local virtualEnd = virtualPositions:UTF8ToUTF16(directive.virtualRange:End())
        encoder.msgpackWriteUint(buf, originalStart & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, (originalEnd - originalStart) & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, virtualStart & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, (virtualEnd - virtualStart) & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, directive.policy & 0xFFFFFFFF)
        encoder.msgpackWriteUint(buf, directive.unusedCode & 0xFFFFFFFF)
    end
    return offset
end

-- Minimal msgpack writers for the structured data section (buf is a ByteBuf).

function encoder.msgpackWriteArrayHeader(buf, length)
    if length <= 0x0f then
        buf:WriteByte(0x90 | length)
        return buf
    end
    if length <= 0xffff then
        buf:WriteByte(0xdc, (length >> 8) & 0xff, length & 0xff)
        return buf
    end
    buf:WriteByte(0xdd, (length >> 24) & 0xff, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff)
    return buf
end

function encoder.msgpackWriteUint(buf, value)
    if value <= 0x7f then
        buf:WriteByte(value)
        return buf
    end
    if value <= 0xff then
        buf:WriteByte(0xcc, value)
        return buf
    end
    if value <= 0xffff then
        buf:WriteByte(0xcd, (value >> 8) & 0xff, value & 0xff)
        return buf
    end
    buf:WriteByte(0xce, (value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    return buf
end

function encoder.msgpackWriteString(buf, s)
    local n = #s
    if n <= 0x1f then
        buf:WriteByte(0xa0 | n)
    elseif n <= 0xff then
        buf:WriteByte(0xd9, n)
    elseif n <= 0xffff then
        buf:WriteByte(0xda, (n >> 8) & 0xff, n & 0xff)
    else
        buf:WriteByte(0xdb, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
    end
    buf:WriteString(s)
    return buf
end

function encoder.msgpackWriteBool(buf, value)
    if value then
        buf:WriteByte(0xc3)
        return buf
    end
    buf:WriteByte(0xc2)
    return buf
end

-- Hand-written commonData encoding functions for nodes whose non-bool data
-- members cannot be automatically encoded by the generator. Each function
-- packs relevant fields into the 6-bit commonData area (bits 24-29) of the
-- 32-bit node data word.

function encoder.getNodeCommonData_SyntheticExpression(_)
    -- SyntheticExpression is an internal compiler node that is never part of a parsed AST.
    -- It should never be encoded.
    error("SyntheticExpression should never be encoded", 0)
end

-- Hand-written extended data encoding functions for literal nodes that were
-- previously string-type but whose TokenFlags/TemplateFlags cannot fit in 6 bits.

function encoder.recordExtendedData_StringLiteral(node, strs, _, extendedData, _)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, n.tokenFlags & 0xFFFFFFFF)
end

function encoder.recordExtendedData_NumericLiteral(node, strs, _, extendedData, _)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, n.tokenFlags & 0xFFFFFFFF)
end

function encoder.recordExtendedData_BigIntLiteral(node, strs, _, extendedData, _)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, n.tokenFlags & 0xFFFFFFFF)
end

function encoder.recordExtendedData_RegularExpressionLiteral(node, strs, _, extendedData, _)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, n.tokenFlags & 0xFFFFFFFF)
end

function encoder.recordExtendedData_NoSubstitutionTemplateLiteral(node, strs, _, extendedData, _)
    local n = node
    local textIndex = strs:add(n.text, node.kind, node:Pos(), node:End())
    appendWords(extendedData, textIndex, n.templateFlags & 0xFFFFFFFF)
end
