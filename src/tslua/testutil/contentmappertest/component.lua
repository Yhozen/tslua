local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local jsonrpc = require("tslua.jsonrpc")
local spanmap = require("tslua.spanmap")

local componentHandler = contentmappertest.defineHandler()
contentmappertest.componentHandler = componentHandler

function contentmappertest.newComponentHandler()
    return setmetatable({}, componentHandler)
end

function componentHandler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult("mapper"), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local text, mappings
        text, mappings, err = contentmappertest.transformComponent(p.content)
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({ text = text, extension = ".ts", mappings = mappings }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end

-- transformComponent returns (text, mappings json.Value, err).
function contentmappertest.transformComponent(content)
    local index = contentmappertest.index
    local virtual = {}
    local virtualLen = 0
    local segments = {}

    local function writeSynthesized(text)
        virtual[#virtual + 1] = text
        virtualLen = virtualLen + #text
    end
    local function writeMapped(text, originalStart, originalEnd, kind)
        local virtualStart = virtualLen
        virtual[#virtual + 1] = text
        virtualLen = virtualLen + #text
        segments[#segments + 1] = spanmap.NewSegment({
            virtualStart = virtualStart,
            virtualEnd = virtualLen,
            originalStart = originalStart,
            originalEnd = originalEnd,
            kind = kind,
            features = spanmap.Feature.All,
        })
    end
    local function sub(from, to)
        return string.sub(content, from + 1, to)
    end

    local scriptOpen = index(content, "<script")
    if scriptOpen >= 0 then
        local openEndRel = index(sub(scriptOpen, #content), ">")
        if openEndRel < 0 then
            return "", nil, jsonrpc.NewError("contentmappertest: unclosed <script> tag")
        end
        local scriptStart = scriptOpen + openEndRel + 1
        local closeRel = index(sub(scriptStart, #content), "</script>")
        if closeRel < 0 then
            return "", nil, jsonrpc.NewError("contentmappertest: missing </script> tag")
        end
        local scriptEnd = scriptStart + closeRel
        writeMapped(sub(scriptStart, scriptEnd), scriptStart, scriptEnd, spanmap.Kind.Verbatim)
    end

    writeSynthesized("\nfunction __render() {\n")
    local searchStart = 0
    while searchStart < #content do
        local openRel = index(sub(searchStart, #content), "{{")
        if openRel < 0 then
            break
        end
        local exprStart = searchStart + openRel + #"{{"
        local closeRel = index(sub(exprStart, #content), "}}")
        if closeRel < 0 then
            return "", nil, jsonrpc.NewError("contentmappertest: unclosed template expression")
        end
        local exprEnd = exprStart + closeRel
        writeSynthesized("  void (")
        local pos = exprStart
        while pos < exprEnd do
            if not contentmappertest.isIdentifierStart(string.byte(content, pos + 1)) then
                writeSynthesized(sub(pos, pos + 1))
                pos = pos + 1
            else
                local end_ = pos + 1
                while end_ < exprEnd and contentmappertest.isIdentifierPart(string.byte(content, end_ + 1)) do
                    end_ = end_ + 1
                end
                writeMapped(sub(pos, end_), pos, end_, spanmap.Kind.Atom)
                pos = end_
            end
        end
        writeSynthesized(");\n")
        searchStart = exprEnd + #"}}"
    end
    writeSynthesized("}\n")
    local nameStart, nameEnd, ok = contentmappertest.componentNameRange(content)
    if ok then
        writeSynthesized("export class ")
        writeMapped(sub(nameStart, nameEnd), nameStart, nameEnd, spanmap.Kind.Atom)
        writeSynthesized(" {}\n")
    end
    writeSynthesized("export default {};\n")

    local mappings, err = spanmap.New(segments):Marshal()
    if err ~= nil then
        return "", nil, err
    end
    return table.concat(virtual), mappings, nil
end

-- componentNameRange returns (start, end, ok).
function contentmappertest.componentNameRange(content)
    local index = contentmappertest.index
    local componentStart = index(content, "<component")
    if componentStart < 0 then
        return 0, 0, false
    end
    local tagEndRel = index(string.sub(content, componentStart + 1), ">")
    if tagEndRel < 0 then
        return 0, 0, false
    end
    local tag = string.sub(content, componentStart + 1, componentStart + tagEndRel)
    local nameRel = index(tag, [[name="]])
    if nameRel < 0 then
        return 0, 0, false
    end
    local start = componentStart + nameRel + #[[name="]]
    local endRel = index(string.sub(content, start + 1), '"')
    if endRel < 0 then
        return 0, 0, false
    end
    return start, start + endRel, true
end

function contentmappertest.isIdentifierStart(ch)
    return ch == 0x5F or ch == 0x24 or ch >= 0x41 and ch <= 0x5A or ch >= 0x61 and ch <= 0x7A
end

function contentmappertest.isIdentifierPart(ch)
    return contentmappertest.isIdentifierStart(ch) or ch >= 0x30 and ch <= 0x39
end
