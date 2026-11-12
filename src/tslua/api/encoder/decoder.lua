local encoder = require("tslua.api.encoder")
local ast = require("tslua.ast")
local core = require("tslua.core")
local jsonrpc = require("tslua.jsonrpc")

local Kind = ast.Kind
local NodeSize = encoder.NodeSize

-- Errors are strings (Go fmt.Errorf / errors.New without wrapping).

-- astDecoder reconstructs real *ast.Node objects from binary-encoded data (a Lua string).
-- nodes and nodeLists are Lua arrays indexed by node index + 1 (holes are nil).
local astDecoder = {}
astDecoder.__index = astDecoder
encoder.astDecoder = astDecoder

-- DecodeSourceFile decodes binary-encoded data into an *ast.SourceFile. Returns (sourceFile, err).
function encoder.DecodeSourceFile(data)
    local node, err = encoder.DecodeNodes(data)
    if err ~= nil then
        return nil, err
    end
    if node.kind ~= Kind.SourceFile then
        return nil, "expected SourceFile root, got " .. ast.Kind_String(node.kind)
    end
    return node, nil
end

-- DecodeNodes decodes binary-encoded AST data into a tree of *ast.Node objects. Returns (node, err).
function encoder.DecodeNodes(data)
    local d, err = encoder.newASTDecoder(data)
    if err ~= nil then
        return nil, err
    end
    return d:decode()
end

function encoder.newASTDecoder(data)
    if #data < encoder.HeaderSize then
        return nil, "data too short for header: " .. tostring(#data) .. " bytes"
    end
    local version = string.byte(data, encoder.HeaderOffsetMetadata + 3 + 1)
    if version ~= encoder.ProtocolVersion then
        return nil, "unsupported protocol version " .. tostring(version) .. " (expected " .. tostring(encoder.ProtocolVersion) .. ")"
    end

    local strTable = encoder.readLE32(data, encoder.HeaderOffsetStringOffsets)
    local strData = encoder.readLE32(data, encoder.HeaderOffsetStringData)
    local extData = encoder.readLE32(data, encoder.HeaderOffsetExtendedData)
    local nodeOff = encoder.readLE32(data, encoder.HeaderOffsetNodes)

    local dataLen = #data

    -- Validate that all offsets are within the buffer.
    if strTable > dataLen or strData > dataLen or extData > dataLen or nodeOff > dataLen then
        return nil, "invalid AST header offsets: offsets exceed data length (" .. tostring(dataLen) .. ")"
    end

    -- Validate monotonic non-decreasing order of regions.
    if not (strTable <= strData and strData <= extData and extData <= nodeOff) then
        return nil, "invalid AST header offsets: expected strTable <= strData <= extData <= nodeOff (got " ..
            tostring(strTable) .. ", " .. tostring(strData) .. ", " .. tostring(extData) .. ", " .. tostring(nodeOff) .. ")"
    end

    local d = setmetatable({
        raw = data,
        strTable = strTable,
        strData = strData,
        extData = extData,
        nodeOff = nodeOff,
        nodeCount = 0,
        factory = ast.NewNodeFactory({}),
        childBuf = {},
        allStringData = "",
        nodes = nil,
        nodeLists = nil,
    }, astDecoder)

    d.nodeCount = core.IntDiv(#data - d.nodeOff, NodeSize)

    -- Convert entire string data region to a single string upfront.
    d.allStringData = string.sub(data, d.strData + 1)

    return d, nil
end

-- allocNodeSlice returns a zero-length slice with the given capacity (Go backs it by a
-- pre-allocated arena; Lua tables grow on demand).
function astDecoder:allocNodeSlice(capacity)
    return {}
end

-- nodeField reads a uint32 field from node i at the given field offset.
function astDecoder:nodeField(i, field)
    return encoder.readLE32(self.raw, self.nodeOff + i * NodeSize + field)
end

function astDecoder:getString(idx)
    local offBase = self.strTable + idx * 4
    local start = encoder.readLE32(self.raw, offBase)
    local end_ = encoder.readLE32(self.raw, offBase + 4)
    return string.sub(self.allStringData, start + 1, end_)
end

-- collectChildren returns indices of direct children of node i.
-- The returned slice is reused across calls; callers must not retain it.
function astDecoder:collectChildren(i)
    local buf = {}
    self.childBuf = buf
    if i + 1 >= self.nodeCount then
        return buf
    end
    local firstChild = i + 1
    if self:nodeField(firstChild, encoder.NodeOffsetParent) ~= i then
        return buf
    end
    buf[#buf + 1] = firstChild
    local next_ = self:nodeField(firstChild, encoder.NodeOffsetNext)
    while next_ ~= 0 do
        buf[#buf + 1] = next_
        next_ = self:nodeField(next_, encoder.NodeOffsetNext)
    end
    return buf
end

function astDecoder:decode()
    if self.nodeCount < 2 then
        return nil, "no nodes to decode"
    end

    self.nodes = {}
    self.nodeLists = {}

    -- Process bottom-up so children exist before parents.
    for i = self.nodeCount - 1, 1, -1 do
        local kind = self:nodeField(i, encoder.NodeOffsetKind)
        local pos = self:nodeField(i, encoder.NodeOffsetPos)
        local end_ = self:nodeField(i, encoder.NodeOffsetEnd)
        local data = self:nodeField(i, encoder.NodeOffsetData)
        local childIndices = self:collectChildren(i)

        if kind == encoder.SyntaxKindNodeList then
            local childNodes = self:allocNodeSlice(#childIndices)
            for _, ci in ipairs(childIndices) do
                if self.nodes[ci + 1] ~= nil then
                    childNodes[#childNodes + 1] = self.nodes[ci + 1]
                end
            end
            local nl = self.factory:NewNodeList(childNodes)
            nl.loc = core.NewTextRange(pos, end_)
            self.nodeLists[i + 1] = nl
        else
            local node, err = self:createNode(kind, data, childIndices)
            if err ~= nil then
                return nil, jsonrpc.NewError("at node " .. tostring(i) .. " (kind " .. ast.Kind_String(kind) .. "): " .. jsonrpc.ErrorString(err), err)
            end
            node.loc = core.NewTextRange(pos, end_)
            node.flags = self:nodeField(i, encoder.NodeOffsetFlags)
            self.nodes[i + 1] = node
        end
    end

    return self.nodes[2], nil
end

-- getModifierList creates a *ast.ModifierList from a child index that is a NodeList.
function astDecoder:getModifierList(ci)
    local nl = self.nodeLists[ci + 1]
    if nl == nil then
        return nil
    end
    local ml = self.factory:NewModifierList(nl.nodes)
    ml.loc = nl.loc
    return ml
end

-- childIterator helps walk through children based on a bitmask.
local childIterator = {}
childIterator.__index = childIterator
encoder.childIterator = childIterator

function encoder.newChildIter(indices)
    return setmetatable({ indices = indices, pos = 0 }, childIterator)
end

-- next returns the index of the next child, advancing the position.
function childIterator:next()
    if self.pos >= #self.indices then
        return 0
    end
    local ci = self.indices[self.pos + 1]
    self.pos = self.pos + 1
    return ci
end

-- nextIf returns the index of the next child if the corresponding mask bit is set.
function childIterator:nextIf(mask, bit)
    if mask & (1 << bit) == 0 then
        return 0
    end
    return self:next()
end

function astDecoder:nodeAt(ci)
    if ci == 0 then
        return nil
    end
    return self.nodes[ci + 1]
end

function astDecoder:nodeListAt(ci)
    if ci == 0 then
        return nil
    end
    return self.nodeLists[ci + 1]
end

function astDecoder:modifierListAt(ci)
    if ci == 0 then
        return nil
    end
    return self:getModifierList(ci)
end

function astDecoder:createNode(kind, data, childIndices)
    local dataType = data & encoder.NodeDataTypeMask
    local commonData = (data >> 24) & 0x3f

    if dataType == encoder.NodeDataTypeString then
        return self:createStringNode(kind, data, commonData)
    elseif dataType == encoder.NodeDataTypeExtendedData then
        return self:createExtendedNode(kind, data, childIndices, commonData)
    end
    return self:createChildrenNode(kind, data, childIndices, commonData)
end

function astDecoder:decodeExtendedData_SourceFile(data, childIndices, commonData)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)

    local textIdx = encoder.readLE32(self.raw, extOff)
    local fileNameIdx = encoder.readLE32(self.raw, extOff + 4)
    local pathIdx = encoder.readLE32(self.raw, extOff + 8)
    local text = self:getString(textIdx)
    local fileName = self:getString(fileNameIdx)
    local path = self:getString(pathIdx)

    -- Recover parse options from header.
    local parseOpts = encoder.readLE32(self.raw, encoder.HeaderOffsetParseOptions)
    local opts = ast.NewSourceFileParseOptions(fileName, path, ast.NewExternalModuleIndicatorOptions(parseOpts & 1 ~= 0, parseOpts & 2 ~= 0))

    -- Collect children: first is statements NodeList, second is EndOfFile.
    local stmts
    local endOfFile
    for _, ci in ipairs(childIndices) do
        if self:nodeField(ci, encoder.NodeOffsetKind) == encoder.SyntaxKindNodeList then
            stmts = self:nodeListAt(ci)
        elseif self.nodes[ci + 1] ~= nil and self.nodes[ci + 1].kind == Kind.EndOfFile then
            endOfFile = self.nodes[ci + 1]
        end
    end
    if endOfFile == nil then
        endOfFile = self.factory:NewToken(Kind.EndOfFile)
    end
    return self.factory:NewSourceFile(opts, text, stmts, endOfFile), nil
end

function astDecoder:decodeExtendedData_TemplateHead(data, childIndices, commonData)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local rawTextIdx = encoder.readLE32(self.raw, extOff + 4)
    local flags = encoder.readLE32(self.raw, extOff + 8)
    return self.factory:NewTemplateHead(self:getString(textIdx), self:getString(rawTextIdx), flags), nil
end

function astDecoder:decodeExtendedData_TemplateMiddle(data, childIndices, commonData)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local rawTextIdx = encoder.readLE32(self.raw, extOff + 4)
    local flags = encoder.readLE32(self.raw, extOff + 8)
    return self.factory:NewTemplateMiddle(self:getString(textIdx), self:getString(rawTextIdx), flags), nil
end

function astDecoder:decodeExtendedData_TemplateTail(data, childIndices, commonData)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local rawTextIdx = encoder.readLE32(self.raw, extOff + 4)
    local flags = encoder.readLE32(self.raw, extOff + 8)
    return self.factory:NewTemplateTail(self:getString(textIdx), self:getString(rawTextIdx), flags), nil
end

function astDecoder:singleChild(childIndices)
    if #childIndices == 0 then
        return nil
    end
    return self.nodes[childIndices[1] + 1]
end

function astDecoder:singleNodeListChild(childIndices)
    if #childIndices == 0 then
        return nil
    end
    return self.nodeLists[childIndices[1] + 1]
end

-- readLE32 reads a little-endian uint32 at the 0-based byte offset (0 when out of range).
function encoder.readLE32(data, offset)
    if offset < 0 or offset + 4 > #data then
        return 0
    end
    return (string.unpack("<I4", data, offset + 1))
end

-- Hand-written commonData decoding functions. Each extracts the original values
-- from the 6-bit commonData that were packed by the corresponding
-- getNodeCommonData_* function.

function encoder.decodeNodeCommonData_SyntheticExpression(_)
    error("SyntheticExpression should never be decoded", 0)
end

-- Hand-written extended data decoding functions for literal nodes.

function astDecoder:decodeExtendedData_StringLiteral(data, _, _)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local flags = encoder.readLE32(self.raw, extOff + 4)
    return self.factory:NewStringLiteral(self:getString(textIdx), flags), nil
end

function astDecoder:decodeExtendedData_NumericLiteral(data, _, _)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local flags = encoder.readLE32(self.raw, extOff + 4)
    return self.factory:NewNumericLiteral(self:getString(textIdx), flags), nil
end

function astDecoder:decodeExtendedData_BigIntLiteral(data, _, _)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local flags = encoder.readLE32(self.raw, extOff + 4)
    return self.factory:NewBigIntLiteral(self:getString(textIdx), flags), nil
end

function astDecoder:decodeExtendedData_RegularExpressionLiteral(data, _, _)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local flags = encoder.readLE32(self.raw, extOff + 4)
    return self.factory:NewRegularExpressionLiteral(self:getString(textIdx), flags), nil
end

function astDecoder:decodeExtendedData_NoSubstitutionTemplateLiteral(data, _, _)
    local extOff = self.extData + (data & encoder.NodeDataStringIndexMask)
    local textIdx = encoder.readLE32(self.raw, extOff)
    local flags = encoder.readLE32(self.raw, extOff + 4)
    return self.factory:NewNoSubstitutionTemplateLiteral(self:getString(textIdx), flags), nil
end
