local contentmappertest = require("tslua.testutil.contentmappertest")
local contentmapper = require("tslua.contentmapper")
local core = require("tslua.core")
local jsonrpc = require("tslua.jsonrpc")
local spanmap = require("tslua.spanmap")

local preamble = "const __VERSION = \"1.0.0\";\n"

contentmappertest.DeclaredOptions = { "target", "jsx" }

local diagnosticSource = "box"
local unclosedInterpolationCode = 1000

local trimSpace = contentmappertest.trimSpace
local index = contentmappertest.index

-- Handler implements the transforming content mapper protocol: { compilerOptions = map[projectHandle]*OrderedMap }.
local Handler = contentmappertest.defineHandler()
contentmappertest.Handler = Handler

function contentmappertest.NewHandler()
    return setmetatable({ compilerOptions = nil }, Handler)
end

function Handler:OpenProject(p)
    local options, err = contentmapper.codec.DecodeOrderedMapOfRaw(p.compilerOptions)
    if err ~= nil then
        return err
    end
    if self.compilerOptions == nil then
        self.compilerOptions = {}
    end
    self.compilerOptions[p.projectHandle] = options or false
    return nil
end

function Handler:CloseProject(p)
    if self.compilerOptions ~= nil then
        self.compilerOptions[p.projectHandle] = nil
    end
end

function Handler:HandleRequest(ctx, method, params)
    if method == contentmapper.MethodInitialize then
        return contentmappertest.initializeResult(diagnosticSource), nil
    elseif method == contentmapper.MethodTransform then
        local p, err = contentmapper.UnmarshalTransformParams(contentmappertest.rawParams(params))
        if err ~= nil then
            return nil, err
        end
        local options = nil
        if self.compilerOptions ~= nil then
            options = self.compilerOptions[p.projectHandle]
        end
        if not options then
            return nil, jsonrpc.NewError("contentmappertest: project " .. jsonrpc.goQuote(p.projectHandle) .. " is not open")
        end
        local text, mappings, diagnostics, diagnosticDirectives
        text, mappings, diagnostics, diagnosticDirectives, err = contentmappertest.transform(p.content, options)
        if err ~= nil then
            return nil, err
        end
        return contentmapper.NewTransformResult({
            text = text,
            extension = contentmappertest.mappedExtension(p.content),
            mappings = mappings,
            diagnosticDirectives = diagnosticDirectives,
            diagnostics = diagnostics,
        }), nil
    end
    return nil, contentmappertest.unexpectedMethod(method)
end

function contentmappertest.mappedExtension(content)
    local prefix = "// @box-extension:"
    local nl = string.find(content, "\n", 1, true)
    if nl ~= nil then
        local firstLine = string.sub(content, 1, nl - 1)
        if contentmappertest.hasPrefix(firstLine, prefix) then
            return trimSpace(string.sub(firstLine, #prefix + 1))
        end
    end
    return ".ts"
end

-- transform returns (text, mappings json.Value, []contentmapper.Diagnostic, *DiagnosticDirectives, err).
function contentmappertest.transform(content, options)
    local virtual = {}
    local virtualLen = 0
    local segments = {}
    local diagnostics = nil

    local function write(s)
        virtual[#virtual + 1] = s
        virtualLen = virtualLen + #s
    end

    write(preamble)

    local function writeVerbatim(from, to)
        if to <= from then
            return
        end
        local virtualStart = virtualLen
        write(string.sub(content, from + 1, to))
        segments[#segments + 1] = spanmap.NewSegment({
            virtualStart = virtualStart,
            virtualEnd = virtualLen,
            originalStart = from,
            originalEnd = to,
            kind = spanmap.Kind.Verbatim,
            features = spanmap.Feature.All,
        })
    end

    local function writeAtom(value, from, to)
        local virtualStart = virtualLen
        write(value)
        segments[#segments + 1] = spanmap.NewSegment({
            virtualStart = virtualStart,
            virtualEnd = virtualLen,
            originalStart = from,
            originalEnd = to,
            kind = spanmap.Kind.Atom,
            features = spanmap.Feature.All,
        })
    end

    local pos = 0
    while pos < #content do
        local rel = index(string.sub(content, pos + 1), "#{")
        if rel < 0 then
            writeVerbatim(pos, #content)
            break
        end
        local tokenStart = pos + rel

        local lineEnd = tokenStart + index(string.sub(content, tokenStart + 1), "\n")
        if lineEnd < tokenStart then
            lineEnd = #content
        end
        local closeRel = index(string.sub(content, tokenStart + 1, lineEnd), "}")
        if closeRel < 0 then
            writeVerbatim(pos, tokenStart)
            writeAtom("undefined", tokenStart, lineEnd)
            diagnostics = core.Append(diagnostics, contentmapper.NewDiagnostic({
                messageText = "Unclosed interpolation.",
                start = tokenStart,
                length = lineEnd - tokenStart,
                code = unclosedInterpolationCode,
            }))
            pos = lineEnd
        else
            local tokenEnd = tokenStart + closeRel + 1
            local name = string.sub(content, tokenStart + #"#{" + 1, tokenEnd - #"}")

            writeVerbatim(pos, tokenStart)
            writeAtom(contentmappertest.renderOption(options, name), tokenStart, tokenEnd)
            pos = tokenEnd
        end
    end

    local spanMap = spanmap.New(segments)
    local mappings, err = spanMap:Marshal()
    if err ~= nil then
        return "", nil, nil, nil, err
    end
    return table.concat(virtual), mappings, diagnostics, contentmappertest.diagnosticDirectives(content, spanMap), nil
end

function contentmappertest.diagnosticDirectives(content, mappings)
    local Policy = contentmapper.DiagnosticDirectivePolicy
    local function wrap(directives, ...)
        local unused = table.pack(...)
        local list = nil
        for i = 1, unused.n do
            list = core.Append(list, unused[i])
        end
        return contentmapper.NewDiagnosticDirectives({ unusedExpectDirectiveDiagnostics = list, directives = directives })
    end
    local function directive(t)
        return contentmapper.NewMappedDiagnosticDirective(t)
    end
    local invalidPrefix = "// @box-invalid-directive:"
    if contentmappertest.hasPrefix(content, invalidPrefix) then
        local firstLine = content
        local nl = string.find(content, "\n", 1, true)
        if nl ~= nil then
            firstLine = string.sub(content, 1, nl - 1)
        end
        local kind = trimSpace(string.sub(firstLine, #invalidPrefix + 1))
        if kind == "invalid-range" then
            return wrap({ directive({ virtualStart = -1, policy = Policy.Ignore }) })
        elseif kind == "original-range-out-of-bounds" then
            return wrap({ directive({ originalStart = #content + 1, policy = Policy.Ignore }) })
        elseif kind == "virtual-range-out-of-bounds" then
            return wrap({ directive({ virtualStart = 1 << 20, virtualEnd = 1 << 20, policy = Policy.Ignore }) })
        elseif kind == "invalid-policy" then
            return wrap({ directive({ policy = 2 }) })
        elseif kind == "ignore-with-unused-diagnostic" then
            return wrap({ directive({ policy = Policy.Ignore }) }, contentmapper.NewUnusedExpectDirectiveDiagnostic())
        elseif kind == "expect-without-unused-diagnostic" then
            return wrap({ directive({ policy = Policy.Expect }) })
        elseif kind == "invalid-unused-diagnostic-index" then
            return wrap(
                { directive({ policy = Policy.Expect, unusedExpectDirectiveIndex = 1 }) },
                contentmapper.NewUnusedExpectDirectiveDiagnostic()
            )
        elseif kind == "overlap" then
            return wrap({
                directive({ virtualEnd = 2, policy = Policy.Ignore }),
                directive({ virtualStart = 1, virtualEnd = 3, policy = Policy.Ignore }),
            })
        end
    end
    local ignorePrefix = "// @box-ignore"
    local expectPrefix = "// @box-expect-error"
    local result = nil
    local unusedDiagnostics = nil
    local lineStart = 0
    while lineStart < #content do
        local lineEnd = index(string.sub(content, lineStart + 1), "\n")
        if lineEnd < 0 then
            lineEnd = #content
        else
            lineEnd = lineEnd + lineStart
        end
        local line = string.sub(content, lineStart + 1, lineEnd)
        local trimmed = trimSpace(line)
        local policy = 0
        local hasPolicy = false
        local unusedDiagnosticIndex = -1
        if trimmed == ignorePrefix then
            policy = Policy.Ignore
            hasPolicy = true
        elseif contentmappertest.hasPrefix(trimmed, expectPrefix .. ":") then
            policy = Policy.Expect
            hasPolicy = true
            unusedDiagnosticIndex = core.Len(unusedDiagnostics)
            unusedDiagnostics = core.Append(unusedDiagnostics, contentmapper.NewUnusedExpectDirectiveDiagnostic({
                code = 2578,
                messageText = trimSpace(string.sub(trimmed, #expectPrefix + 2)),
            }))
        end
        if hasPolicy and lineEnd < #content then
            local affectedStart = lineEnd + 1
            local affectedLength = index(string.sub(content, affectedStart + 1), "\n")
            if affectedLength < 0 then
                affectedLength = #content - affectedStart
            end
            local virtualSpans = mappings:OriginalToVirtualSpans(core.NewTextRange(affectedStart, affectedStart + affectedLength), spanmap.Feature.All)
            if core.Len(virtualSpans) == 1 then
                local d = directive({
                    originalStart = lineStart,
                    originalLength = lineEnd - lineStart,
                    virtualStart = virtualSpans[1].span:Pos(),
                    virtualEnd = virtualSpans[1].span:End(),
                    policy = policy,
                })
                if unusedDiagnosticIndex >= 0 then
                    d.unusedExpectDirectiveIndex = unusedDiagnosticIndex
                end
                result = core.Append(result, d)
            end
        end
        if lineEnd == #content then
            break
        end
        lineStart = lineEnd + 1
    end
    if core.Len(unusedDiagnostics) == 1 then
        for _, d in ipairs(result or {}) do
            d.unusedExpectDirectiveIndex = nil
        end
    end
    if core.Len(result) == 0 and core.Len(unusedDiagnostics) == 0 then
        return nil
    end
    return wrap(result, table.unpack(unusedDiagnostics or {}))
end

function contentmappertest.renderOption(options, name)
    if options then
        local value, ok = options:Get(name)
        if ok and value ~= nil and #value > 0 then
            return value
        end
    end
    return "undefined"
end
