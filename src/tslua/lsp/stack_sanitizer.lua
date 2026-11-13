local lsp = require("tslua.lsp")
local regexp = require("tslua.regexp")

-- VS Code's telemetry pipeline redacts any string matching
-- /(key|token|sig|secret|signature|password|passwd|pwd|android:value)[^a-zA-Z0-9]/i
-- as `<REDACTED: Generic Secret>`, which trips on innocuous Go frames like
-- `getSignatureHelp(`. Insert `X_X` after each trigger keyword that we know
-- can appear in our sanitized output, when followed by punctuation we
-- actually emit (`(`, `[`, `.`, `|`); reverse by removing the marker (replace
-- `X_X` with the empty string) on the dashboard.
lsp.genericSecretKeywordRegex = regexp.MustCompile("(?i)(key|token|signature|sig|pwd)([(\\[.|])")

function lsp.defeatGenericSecretRegex(s)
    return lsp.genericSecretKeywordRegex:ReplaceAllString(s, "${1}X_X${2}")
end

-- strings.Lines: the lines of s, each including its terminating "\n".
local function lines(s)
    local result = {}
    local pos = 1
    while pos <= #s do
        local nl = string.find(s, "\n", pos, true)
        if nl == nil then
            result[#result + 1] = string.sub(s, pos)
            break
        end
        result[#result + 1] = string.sub(s, pos, nl)
        pos = nl + 1
    end
    return result
end

function lsp.sanitizeStackTrace(stack)
    -- TODO: should we just look for the first '(' and
    -- just strip everything before the prior newline?
    local startIndex = string.find(stack, "runtime/debug.Stack()", 1, true)
    if startIndex == nil then
        return ""
    end
    stack = string.sub(stack, startIndex)

    local result = {}

    for lineNum1, line in ipairs(lines(stack)) do
        if lineNum1 > 1 then
            result[#result + 1] = "\n"
        end

        local i = 0
        -- Skip whitespace
        while i < #line do
            local c = string.sub(line, i + 1, i + 1)
            if c ~= " " and c ~= "\t" then
                break
            end
            i = i + 1
        end

        result[#result + 1] = string.sub(line, 1, i)

        line = string.sub(line, i + 1)

        local ourModuleIndex = string.find(line, "typescript-go/internal", 1, true)
        if ourModuleIndex ~= nil then
            line = string.sub(line, ourModuleIndex)
            lsp.writeSanitizedModuleOrPath(line, result)
        else
            result[#result + 1] = "(REDACTED FRAME)"
        end
    end

    return lsp.defeatGenericSecretRegex(table.concat(result))
end

local function lastIndex(s, sub)
    local last = nil
    local pos = 1
    while true do
        local i = string.find(s, sub, pos, true)
        if i == nil then
            return last
        end
        last = i
        pos = i + 1
    end
end

function lsp.writeSanitizedModuleOrPath(line, result)
    -- We don't expect things like \r, but it doesn't hurt to trim just in case.
    line = string.gsub(string.gsub(line, "^%s+", ""), "%s+$", "")

    local plusHex = string.find(line, " +0x", 1, true)
    if plusHex ~= nil then
        line = string.sub(line, 1, plusHex - 1)
    else
        local inGoroutine = lastIndex(line, " in goroutine ")
        if inGoroutine ~= nil then
            line = string.sub(line, 1, inGoroutine - 1)
        end
    end

    local segmentIndex = 0
    for segment in string.gmatch(line .. "/", "([^/]*)/") do
        if segmentIndex > 0 then
            result[#result + 1] = "|>"
        end
        segmentIndex = segmentIndex + 1

        -- See if the string ends with ), and strip out all the arguments.
        if string.sub(segment, -1) == ")" then
            local openParenIndex = lastIndex(segment, "(")
            if openParenIndex == nil then
                -- Closing parenthesis, but no opening - bail out.
                result[#result + 1] = "???"
            else
                segment = string.sub(segment, 1, openParenIndex - 1)
                result[#result + 1] = segment
                result[#result + 1] = "()"
            end
        else
            result[#result + 1] = segment
        end
    end
end
