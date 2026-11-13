local semver = require("tslua.semver")
local regexp = require("tslua.regexp")

-- https://github.com/npm/node-semver#range-grammar
--
-- range-set    ::= range ( logical-or range ) *
-- range        ::= hyphen | simple ( ' ' simple ) * | ”
-- logical-or   ::= ( ' ' ) * '||' ( ' ' ) *
semver.logicalOrRegExp = regexp.MustCompile("\\|\\|")
semver.whitespaceRegExp = regexp.MustCompile("\\s+")

-- https://github.com/npm/node-semver#range-grammar
--
-- partial      ::= xr ( '.' xr ( '.' xr qualifier ? )? )?
-- xr           ::= 'x' | 'X' | '*' | nr
-- nr           ::= '0' | ['1'-'9'] ( ['0'-'9'] ) *
-- qualifier    ::= ( '-' pre )? ( '+' build )?
-- pre          ::= parts
-- build        ::= parts
-- parts        ::= part ( '.' part ) *
-- part         ::= nr | [-0-9A-Za-z]+
semver.partialRegExp = regexp.MustCompile("(?i)^([x*0]|[1-9]\\d*)(?:\\.([x*0]|[1-9]\\d*)(?:\\.([x*0]|[1-9]\\d*)(?:-([a-z0-9-.]+))?(?:\\+([a-z0-9-.]+))?)?)?$")

-- https://github.com/npm/node-semver#range-grammar
--
-- hyphen       ::= partial ' - ' partial
semver.hyphenRegExp = regexp.MustCompile("(?i)^\\s*([a-z0-9-+.*]+)\\s+-\\s+([a-z0-9-+.*]+)\\s*$")

-- https://github.com/npm/node-semver#range-grammar
--
-- simple       ::= primitive | partial | tilde | caret
-- primitive    ::= ( '<' | '>' | '>=' | '<=' | '=' ) partial
-- tilde        ::= '~' partial
-- caret        ::= '^' partial
semver.rangeRegExp = regexp.MustCompile("(?i)^([~^<>=]|<=|>=)?\\s*([a-z0-9-+.*]+)$")

-- VersionRange: { alternatives = array of arrays of versionComparator }
-- versionComparator: { operator = string, operand = semver.Version }
local VersionRange = {}
VersionRange.__index = VersionRange
semver.VersionRange = VersionRange

semver.rangeLessThan = "<"
semver.rangeLessThanEqual = "<="
semver.rangeEqual = "="
semver.rangeGreaterThanEqual = ">="
semver.rangeGreaterThan = ">"

local function comparator(operator, operand)
    return { operator = operator, operand = operand }
end

function VersionRange:String()
    local sb = {}
    semver.formatDisjunction(sb, self.alternatives)
    return table.concat(sb)
end

VersionRange.__tostring = VersionRange.String

function semver.formatDisjunction(sb, alternatives)
    local origLen = #sb

    for i, alternative in ipairs(alternatives or {}) do
        if i > 1 then
            sb[#sb + 1] = " || "
        end
        semver.formatAlternative(sb, alternative)
    end

    if #table.concat(sb, "", origLen + 1) == 0 then
        sb[#sb + 1] = "*"
    end
end

function semver.formatAlternative(sb, comparators)
    for i, c in ipairs(comparators or {}) do
        if i > 1 then
            sb[#sb + 1] = " "
        end
        semver.formatComparator(sb, c)
    end
end

function semver.formatComparator(sb, c)
    sb[#sb + 1] = c.operator
    sb[#sb + 1] = c.operand:String()
end

function VersionRange:Test(version)
    return semver.testDisjunction(self.alternatives, version)
end

function semver.testDisjunction(alternatives, version)
    -- an empty disjunction is treated as "*" (all versions)
    if alternatives == nil or #alternatives == 0 then
        return true
    end

    for _, alternative in ipairs(alternatives) do
        if semver.testAlternative(alternative, version) then
            return true
        end
    end

    return false
end

function semver.testAlternative(alternative, version)
    for _, c in ipairs(alternative or {}) do
        if not semver.testComparator(c, version) then
            return false
        end
    end
    return true
end

function semver.testComparator(c, version)
    local cmp = semver.Version.Compare(version, c.operand)
    local op = c.operator
    if op == semver.rangeLessThan then
        return cmp < 0
    elseif op == semver.rangeLessThanEqual then
        return cmp <= 0
    elseif op == semver.rangeEqual then
        return cmp == 0
    elseif op == semver.rangeGreaterThanEqual then
        return cmp >= 0
    elseif op == semver.rangeGreaterThan then
        return cmp > 0
    else
        error("Unexpected operator: " .. op, 0)
    end
end

-- Returns (VersionRange, ok).
function semver.TryParseVersionRange(text)
    local alternatives, ok = semver.parseAlternatives(text)
    return setmetatable({ alternatives = alternatives }, VersionRange), ok
end

-- strings.TrimSpace
local function trimSpace(s)
    return (string.gsub(string.gsub(s, "^[\t\n\v\f\r \133\160]+", ""), "[\t\n\v\f\r \133\160]+$", ""))
end

-- Returns (alternatives, ok).
function semver.parseAlternatives(text)
    local alternatives = nil

    text = trimSpace(text)
    local ranges = semver.logicalOrRegExp:Split(text, -1)
    for _, r in ipairs(ranges) do
        r = trimSpace(r)
        if r == "" then
            goto continue
        end

        do
            local comparators = {}

            local hyphenMatch = semver.hyphenRegExp:FindStringSubmatch(r)
            if hyphenMatch ~= nil then
                local parsedComparators, ok = semver.parseHyphen(hyphenMatch[2], hyphenMatch[3])
                if ok then
                    for _, c in ipairs(parsedComparators or {}) do
                        comparators[#comparators + 1] = c
                    end
                else
                    return nil, false
                end
            else
                for _, simple in ipairs(semver.whitespaceRegExp:Split(r, -1)) do
                    local match = semver.rangeRegExp:FindStringSubmatch(trimSpace(simple))
                    if match == nil then
                        return nil, false
                    end

                    local parsedComparators, ok = semver.parseComparator(match[2], match[3])
                    if ok then
                        for _, c in ipairs(parsedComparators or {}) do
                            comparators[#comparators + 1] = c
                        end
                    else
                        return nil, false
                    end
                end
            end

            alternatives = alternatives or {}
            alternatives[#alternatives + 1] = comparators
        end
        ::continue::
    end

    return alternatives, true
end

-- Returns (comparators, ok).
function semver.parseHyphen(left, right)
    local leftResult, leftOk = semver.parsePartial(left)
    if not leftOk then
        return nil, false
    end

    local rightResult, rightOk = semver.parsePartial(right)
    if not rightOk then
        return nil, false
    end

    local comparators = {}
    if not semver.isWildcard(leftResult.majorStr) then
        -- `MAJOR.*.*-...` gives us `>=MAJOR.0.0 ...`
        comparators[#comparators + 1] = comparator(semver.rangeGreaterThanEqual, leftResult.version)
    end

    if not semver.isWildcard(rightResult.majorStr) then
        local operator
        local operand = rightResult.version

        if semver.isWildcard(rightResult.minorStr) then
            -- `...-MAJOR.*.*` gives us `... <(MAJOR+1).0.0`
            operand = operand:incrementMajor()
            operator = semver.rangeLessThan
        elseif semver.isWildcard(rightResult.patchStr) then
            -- `...-MAJOR.MINOR.*` gives us `... <MAJOR.(MINOR+1).0`
            operand = operand:incrementMinor()
            operator = semver.rangeLessThan
        else
            -- `...-MAJOR.MINOR.PATCH` gives us `... <=MAJOR.MINOR.PATCH`
            operator = semver.rangeLessThanEqual
        end

        comparators[#comparators + 1] = comparator(operator, operand)
    end

    return comparators, true
end

-- partialVersion: { version = Version, majorStr, minorStr, patchStr }
-- Produces a "partial" version. Returns (partialVersion, ok).
function semver.parsePartial(text)
    local match = semver.partialRegExp:FindStringSubmatch(text)
    if match == nil then
        return { version = semver.NewVersion(), majorStr = "", minorStr = "", patchStr = "" }, false
    end

    local majorStr = match[2]
    local minorStr = match[3]
    local patchStr = match[4]
    local prereleaseStr = match[5]
    local buildStr = match[6]

    if minorStr == "" then
        minorStr = "*"
    end
    if patchStr == "" then
        patchStr = "*"
    end

    local majorNumeric, minorNumeric, patchNumeric = 0, 0, 0
    local err
    local zero = { version = semver.NewVersion(), majorStr = "", minorStr = "", patchStr = "" }

    if semver.isWildcard(majorStr) then
        majorNumeric = 0
        minorNumeric = 0
        patchNumeric = 0
    else
        majorNumeric, err = semver.getUintComponent(majorStr)
        if err ~= nil then
            return zero, false
        end

        if semver.isWildcard(minorStr) then
            minorNumeric = 0
            patchNumeric = 0
        else
            minorNumeric, err = semver.getUintComponent(minorStr)
            if err ~= nil then
                return zero, false
            end

            if semver.isWildcard(patchStr) then
                patchNumeric = 0
            else
                patchNumeric, err = semver.getUintComponent(patchStr)
                if err ~= nil then
                    return zero, false
                end
            end
        end
    end

    local prerelease = nil
    if prereleaseStr ~= "" then
        prerelease = semver.splitDots(prereleaseStr)
    end

    local build = nil
    if buildStr ~= "" then
        build = semver.splitDots(buildStr)
    end

    local result = {
        version = semver.NewVersion({
            major = majorNumeric,
            minor = minorNumeric,
            patch = patchNumeric,
            prerelease = prerelease,
            build = build,
        }),
        majorStr = majorStr,
        minorStr = minorStr,
        patchStr = patchStr,
    }

    return result, true
end

-- Returns (comparators, ok).
function semver.parseComparator(op, text)
    local operator = op

    local result, ok = semver.parsePartial(text)
    if not ok then
        return nil, false
    end

    local comparatorsResult = nil

    if not semver.isWildcard(result.majorStr) then
        if operator == "~" then
            local first = comparator(semver.rangeGreaterThanEqual, result.version)

            local secondVersion
            if semver.isWildcard(result.minorStr) then
                secondVersion = result.version:incrementMajor()
            else
                secondVersion = result.version:incrementMinor()
            end

            local second = comparator(semver.rangeLessThan, secondVersion)
            comparatorsResult = { first, second }
        elseif operator == "^" then
            local first = comparator(semver.rangeGreaterThanEqual, result.version)

            local secondVersion
            if result.version.major > 0 or semver.isWildcard(result.minorStr) then
                secondVersion = result.version:incrementMajor()
            elseif result.version.minor > 0 or semver.isWildcard(result.patchStr) then
                secondVersion = result.version:incrementMinor()
            else
                secondVersion = result.version:incrementPatch()
            end
            local second = comparator(semver.rangeLessThan, secondVersion)
            comparatorsResult = { first, second }
        elseif operator == "<" or operator == ">=" then
            local version = result.version:copy()
            if semver.isWildcard(result.minorStr) or semver.isWildcard(result.patchStr) then
                version.prerelease = { "0" }
            end
            comparatorsResult = {
                comparator(operator, version),
            }
        elseif operator == "<=" or operator == ">" then
            local version = result.version:copy()
            if semver.isWildcard(result.minorStr) then
                if operator == semver.rangeLessThanEqual then
                    operator = semver.rangeLessThan
                else
                    operator = semver.rangeGreaterThanEqual
                end

                version = version:incrementMajor()
                version.prerelease = { "0" }
            elseif semver.isWildcard(result.patchStr) then
                if operator == semver.rangeLessThanEqual then
                    operator = semver.rangeLessThan
                else
                    operator = semver.rangeGreaterThanEqual
                end

                version = version:incrementMinor()
                version.prerelease = { "0" }
            end

            comparatorsResult = {
                comparator(operator, version),
            }
        elseif operator == "=" or operator == "" then
            -- normalize empty string to `=`
            operator = semver.rangeEqual

            if semver.isWildcard(result.minorStr) or semver.isWildcard(result.patchStr) then
                local originalVersion = result.version

                local firstVersion = originalVersion:copy()
                firstVersion.prerelease = { "0" }

                local secondVersion
                if semver.isWildcard(result.minorStr) then
                    secondVersion = originalVersion:incrementMajor()
                else
                    secondVersion = originalVersion:incrementMinor()
                end
                secondVersion.prerelease = { "0" }

                comparatorsResult = {
                    comparator(semver.rangeGreaterThanEqual, firstVersion),
                    comparator(semver.rangeLessThan, secondVersion),
                }
            else
                comparatorsResult = {
                    comparator(operator, result.version),
                }
            end
        else
            error("Unexpected operator: " .. operator, 0)
        end
    else
        if operator == "<" or operator == ">" then
            comparatorsResult = {
                -- < 0.0.0-0
                comparator(semver.rangeLessThan, semver.versionZero),
            }
        end
    end

    return comparatorsResult, true
end

function semver.isWildcard(text)
    return text == "*" or text == "x" or text == "X"
end
