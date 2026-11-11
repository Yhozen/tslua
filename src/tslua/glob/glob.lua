-- Copyright 2023 The Go Authors. All rights reserved.
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file.
local glob = require("tslua.glob")

-- A Glob is an LSP-compliant glob pattern, as defined by the spec:
-- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#documentFilter
--
-- NOTE: this implementation is currently only intended for testing.
--
-- Quoting from the spec:
-- Glob patterns can have the following syntax:
--   - `*` to match one or more characters in a path segment
--   - `?` to match on one character in a path segment
--   - `**` to match any number of path segments, including none
--   - `{}` to group sub patterns into an OR expression. (e.g. `**/*.{ts,js}`
--     matches all TypeScript and JavaScript files)
--   - `[]` to declare a range of characters to match in a path segment
--     (e.g., `example.[0-9]` to match on `example.0`, `example.1`, …)
--   - `[!...]` to negate a range of characters to match in a path segment
--     (e.g., `example.[!0-9]` to match on `example.a`, `example.b`, but
--     not `example.0`)
--
-- Expanding on this:
--   - '/' matches one or more literal slashes.
--   - any other character matches itself literally.
--
-- Elements are tables with a kind field: { kind = "slash" }, { kind = "literal", value = string },
-- { kind = "star" }, { kind = "anyChar" }, { kind = "starStar" }, { kind = "group", globs = array },
-- { kind = "charRange", negate = bool, low = rune, high = rune }.
local Glob = {}
Glob.__index = Glob
glob.Glob = Glob

local SLASH = { kind = "slash" }
local STAR = { kind = "star" }
local ANYCHAR = { kind = "anyChar" }
local STARSTAR = { kind = "starStar" }

local function decodeRune(s)
    -- utf8.DecodeRuneInString
    local n = #s
    if n == 0 then
        return 0xFFFD, 0
    end
    local c0 = string.byte(s, 1)
    if c0 < 0x80 then
        return c0, 1
    end
    local ok, cp = pcall(utf8.codepoint, s, 1)
    if not ok then
        return 0xFFFD, 1
    end
    local size = (cp < 0x800 and 2) or (cp < 0x10000 and 3) or 4
    if (cp >= 0xD800 and cp <= 0xDFFF) or utf8.char(cp) ~= string.sub(s, 1, size) then
        return 0xFFFD, 1
    end
    return cp, size
end

-- Parse builds a Glob for the given pattern, returning an error if the pattern
-- is invalid. Returns (glob, err).
function glob.Parse(pattern)
    local g, _, err = glob.parse(pattern, false)
    return g, err
end

-- Returns (glob, rest, err).
function glob.parse(pattern, nested)
    local g = setmetatable({ elems = {} }, Glob)
    while #pattern > 0 do
        local c = string.sub(pattern, 1, 1)
        if c == "/" then
            pattern = string.sub(pattern, 2)
            g.elems[#g.elems + 1] = SLASH
        elseif c == "*" then
            if #pattern > 1 and string.sub(pattern, 2, 2) == "*" then
                if (#g.elems > 0 and g.elems[#g.elems] ~= SLASH) or (#pattern > 2 and string.sub(pattern, 3, 3) ~= "/") then
                    return nil, "", "** may only be adjacent to '/'"
                end
                pattern = string.sub(pattern, 3)
                g.elems[#g.elems + 1] = STARSTAR
            else
                pattern = string.sub(pattern, 2)
                g.elems[#g.elems + 1] = STAR
            end
        elseif c == "?" then
            pattern = string.sub(pattern, 2)
            g.elems[#g.elems + 1] = ANYCHAR
        elseif c == "{" then
            local gs = {}
            while string.sub(pattern, 1, 1) ~= "}" do
                pattern = string.sub(pattern, 2)
                local groupG, pat, err = glob.parse(pattern, true)
                if err ~= nil then
                    return nil, "", err
                end
                if #pat == 0 then
                    return nil, "", "unmatched '{'"
                end
                pattern = pat
                gs[#gs + 1] = groupG
            end
            pattern = string.sub(pattern, 2)
            g.elems[#g.elems + 1] = { kind = "group", globs = gs }
        elseif c == "}" or c == "," then
            if nested then
                return g, pattern, nil
            end
            pattern = g:parseLiteral(pattern, false)
        elseif c == "[" then
            pattern = string.sub(pattern, 2)
            if #pattern == 0 then
                return nil, "", glob.errBadRange
            end
            local negate = false
            if string.sub(pattern, 1, 1) == "!" then
                pattern = string.sub(pattern, 2)
                negate = true
            end
            local low, sz, err = glob.readRangeRune(pattern)
            if err ~= nil then
                return nil, "", err
            end
            pattern = string.sub(pattern, sz + 1)
            if #pattern == 0 or string.sub(pattern, 1, 1) ~= "-" then
                return nil, "", glob.errBadRange
            end
            pattern = string.sub(pattern, 2)
            local high
            high, sz, err = glob.readRangeRune(pattern)
            if err ~= nil then
                return nil, "", err
            end
            pattern = string.sub(pattern, sz + 1)
            if #pattern == 0 or string.sub(pattern, 1, 1) ~= "]" then
                return nil, "", glob.errBadRange
            end
            pattern = string.sub(pattern, 2)
            g.elems[#g.elems + 1] = { kind = "charRange", negate = negate, low = low, high = high }
        else
            pattern = g:parseLiteral(pattern, nested)
        end
    end
    return g, "", nil
end

-- helper for decoding a rune in range elements, e.g. [a-z]. Returns (rune, size, err).
function glob.readRangeRune(input)
    local r, sz = decodeRune(input)
    local err = nil
    if r == 0xFFFD then
        -- See the documentation for DecodeRuneInString.
        if sz == 0 then
            err = glob.errBadRange
        elseif sz == 1 then
            err = glob.errInvalidUTF8
        end
    end
    return r, sz, err
end

glob.errBadRange = "'[' patterns must be of the form [x-y]"
glob.errInvalidUTF8 = "invalid UTF-8 encoding"

function Glob:parseLiteral(pattern, nested)
    local specialChars
    if nested then
        specialChars = "[%*%?{%[/},]"
    else
        specialChars = "[%*%?{%[/]"
    end
    local end_ = string.find(pattern, specialChars)
    if end_ == nil then
        end_ = #pattern + 1
    end
    self.elems[#self.elems + 1] = { kind = "literal", value = string.sub(pattern, 1, end_ - 1) }
    return string.sub(pattern, end_)
end

function glob.elementString(e)
    local k = e.kind
    if k == "slash" then
        return "/"
    elseif k == "literal" then
        return e.value
    elseif k == "star" then
        return "*"
    elseif k == "anyChar" then
        return "?"
    elseif k == "starStar" then
        return "**"
    elseif k == "group" then
        local parts = {}
        for i, g in ipairs(e.globs) do
            parts[i] = g:String()
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif k == "charRange" then
        return "[" .. utf8.char(e.low) .. "-" .. utf8.char(e.high) .. "]"
    end
    error("unknown glob element " .. tostring(k), 0)
end

function Glob:String()
    local b = {}
    for i, e in ipairs(self.elems) do
        b[i] = glob.elementString(e)
    end
    return table.concat(b)
end

-- Match reports whether the input string matches the glob pattern.
function Glob:Match(input)
    return glob.match(self.elems, 1, input)
end

local function sliceFrom(xs, i)
    local r = {}
    for k = i, #xs do
        r[#r + 1] = xs[k]
    end
    return r
end

-- elems[i:] are the remaining pattern elements (i is 1-based).
function glob.match(elems, i, input)
    while i <= #elems do
        local elem = elems[i]
        i = i + 1
        local k = elem.kind
        if k == "slash" then
            if #input == 0 or string.sub(input, 1, 1) ~= "/" then
                return false
            end
            while string.sub(input, 1, 1) == "/" do
                input = string.sub(input, 2)
            end
        elseif k == "starStar" then
            -- Special cases:
            --  - **/a matches "a"
            --  - **/ matches everything
            --
            -- Note that if ** is followed by anything, it must be '/' (this is
            -- enforced by Parse).
            if i <= #elems then
                i = i + 1
            end

            -- A trailing ** matches anything.
            if i > #elems then
                return true
            end

            -- Backtracking: advance pattern segments until the remaining pattern
            -- elements match.
            while #input ~= 0 do
                if glob.match(elems, i, input) then
                    return true
                end
                local _
                _, input = glob.split(input)
            end
            return false
        elseif k == "literal" then
            if string.sub(input, 1, #elem.value) ~= elem.value then
                return false
            end
            input = string.sub(input, #elem.value + 1)
        elseif k == "star" then
            local segInput
            segInput, input = glob.split(input)

            local elemEnd = #elems + 1
            for j = i, #elems do
                if elems[j] == SLASH then
                    elemEnd = j
                    break
                end
            end
            local segElems = {}
            for j = i, elemEnd - 1 do
                segElems[#segElems + 1] = elems[j]
            end
            i = elemEnd

            -- A trailing * matches the entire segment.
            if #segElems > 0 then
                -- Backtracking: advance characters until remaining subpattern elements
                -- match.
                local matched = false
                for j = 0, #segInput - 1 do
                    if glob.match(segElems, 1, string.sub(segInput, j + 1)) then
                        matched = true
                        break
                    end
                end
                if not matched then
                    return false
                end
            end
        elseif k == "anyChar" then
            if #input == 0 or string.sub(input, 1, 1) == "/" then
                return false
            end
            input = string.sub(input, 2)
        elseif k == "group" then
            -- Append remaining pattern elements to each group member looking for a
            -- match.
            local rest = sliceFrom(elems, i)
            for _, m in ipairs(elem.globs) do
                local branch = {}
                for _, e in ipairs(m.elems) do
                    branch[#branch + 1] = e
                end
                for _, e in ipairs(rest) do
                    branch[#branch + 1] = e
                end
                if glob.match(branch, 1, input) then
                    return true
                end
            end
            return false
        elseif k == "charRange" then
            if #input == 0 or string.sub(input, 1, 1) == "/" then
                return false
            end
            local c, sz = decodeRune(input)
            if c < elem.low or c > elem.high then
                return false
            end
            input = string.sub(input, sz + 1)
        else
            error("segment type " .. tostring(k) .. " not implemented", 0)
        end
    end

    return #input == 0
end

-- split returns the portion before and after the first slash
-- (or sequence of consecutive slashes). If there is no slash
-- it returns (input, "").
function glob.split(input)
    local i = string.find(input, "/", 1, true)
    if i == nil then
        return input, ""
    end
    local first = string.sub(input, 1, i - 1)
    for j = i, #input do
        if string.sub(input, j, j) ~= "/" then
            return first, string.sub(input, j)
        end
    end
    return first, ""
end
