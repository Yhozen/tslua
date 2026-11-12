local stringtestutil = require("tslua.testutil.stringtestutil")
local stringutil = require("tslua.stringutil")

-- Go unicode.IsSpace.
local function isSpace(r)
    if r <= 0xFF then
        return r == 0x09 or r == 0x0A or r == 0x0B or r == 0x0C or r == 0x0D or r == 0x20 or r == 0x85 or r == 0xA0
    end
    return r == 0x1680 or (r >= 0x2000 and r <= 0x200A) or r == 0x2028 or r == 0x2029 or r == 0x202F or r == 0x205F or r == 0x3000
end

-- Go strings.TrimSpace.
function stringtestutil.trimSpace(s)
    local start = 0
    while start < #s do
        local r, size = stringutil.DecodeRune(s, start)
        if not isSpace(r) then
            break
        end
        start = start + size
    end
    local stop = #s
    while stop > start do
        -- find the start of the last rune
        local i = stop - 1
        while i > start and (string.byte(s, i + 1) & 0xC0) == 0x80 do
            i = i - 1
        end
        local r = stringutil.DecodeRune(s, i)
        if not isSpace(r) then
            break
        end
        stop = i
    end
    return string.sub(s, start + 1, stop)
end

-- Go strings.Split(s, "\n").
local function splitLines(s)
    local lines = {}
    local start = 1
    while true do
        local i = string.find(s, "\n", start, true)
        if i == nil then
            lines[#lines + 1] = string.sub(s, start)
            return lines
        end
        lines[#lines + 1] = string.sub(s, start, i - 1)
        start = i + 1
    end
end

function stringtestutil.Dedent(text)
    local lines = splitLines(text)
    -- Remove blank lines in the beginning and end
    -- and convert all tabs in the beginning of line to spaces
    local startLine = -1
    local lastLine = 0
    for i1, line in ipairs(lines) do
        local i = i1 - 1
        local firstNonWhite = -1
        do
            local pos = 0
            while pos < #line do
                local r, size = stringutil.DecodeRune(line, pos)
                if not stringutil.IsWhiteSpaceLike(r) then
                    firstNonWhite = pos
                    break
                end
                pos = pos + size
            end
        end
        if firstNonWhite > 0 then
            line = string.gsub(string.sub(line, 1, firstNonWhite), "\t", "    ") .. string.sub(line, firstNonWhite + 1)
            lines[i + 1] = line
        end
        line = stringtestutil.trimSpace(line)
        if line ~= "" then
            if startLine == -1 then
                startLine = i
            end
            lastLine = i
        end
    end
    local kept = {}
    for i = startLine, lastLine do
        kept[#kept + 1] = lines[i + 1]
    end
    lines = kept
    local mappedLines = {}
    for i, line in ipairs(lines) do
        if stringtestutil.trimSpace(line) == "" then
            mappedLines[i] = ""
        else
            mappedLines[i] = line
        end
    end
    local indentation = stringutil.GuessIndentation(mappedLines)
    if indentation > 0 then
        for i = 1, #lines do
            if #lines[i] > indentation then
                lines[i] = string.sub(lines[i], indentation + 1)
            else
                lines[i] = ""
            end
        end
    end
    return table.concat(lines, "\n")
end
