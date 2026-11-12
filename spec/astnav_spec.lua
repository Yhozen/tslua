local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local parser = require("tslua.parser")
local repo = require("tslua.repo")

local Kind = ast.Kind

local function parse(fileName, text, scriptKind)
    local opts = ast.NewSourceFileParseOptions(fileName, fileName, nil)
    return parser.ParseSourceFile(opts, text, scriptKind)
end

local function readFile(path)
    local f = io.open(path, "rb")
    if f == nil then
        return nil
    end
    local s = f:read("a")
    f:close()
    return s
end

local function toTokenInfo(node)
    if node == nil then
        return nil
    end
    local kind = ast.Kind_names[node.kind]
    if kind == "EndOfFile" then
        kind = "EndOfFileToken"
    end
    return { kind = kind, pos = node:Pos(), end_ = node:End() }
end

-- Port of baselineGoTokensJSON: runs of positions that map to the same token.
local function goTokensJSON(file, text, getGoToken)
    local runs = {}
    local current = nil
    for pos = 0, #text - 1 do
        local token = getGoToken(file, pos)
        if current ~= nil and token ~= nil and current.kind == token.kind and current.nodePos == token.pos and
            current.nodeEnd == token.end_ then
            current.endPos = pos
        else
            if current ~= nil then
                runs[#runs + 1] = current
            end
            if token ~= nil then
                current = { startPos = pos, endPos = pos, kind = token.kind, nodePos = token.pos, nodeEnd = token.end_ }
            else
                current = nil
            end
        end
    end
    if current ~= nil then
        runs[#runs + 1] = current
    end
    local out = {}
    for i, r in ipairs(runs) do
        out[#out + 1] = string.format(
            '  {\n    "startPos": %d,\n    "endPos": %d,\n    "kind": "%s",\n    "nodePos": %d,\n    "nodeEnd": %d\n  }%s',
            r.startPos, r.endPos, r.kind, r.nodePos, r.nodeEnd, i < #runs and "," or "")
    end
    if #out == 0 then
        return "[]"
    end
    return "[\n" .. table.concat(out, "\n") .. "\n]"
end

local function trimTrailing(s)
    return (s:gsub("%s+$", ""))
end

local testFiles = { "src/services/mapCode.ts" }

local function baselineGoTokensJSON(testName, getGoToken)
    for _, rel in ipairs(testFiles) do
        local path = repo.TypeScriptSubmodulePath() .. "/" .. rel
        local baseName = rel:match("([^/]+)$")
        local refPath = repo.TestDataPath() .. "/baselines/reference/astnav/" .. testName .. "." .. baseName ..
            ".baseline.json"
        it(testName .. " go baseline json " .. baseName, function()
            local text = readFile(path)
            local expected = readFile(refPath)
            if text == nil or expected == nil then
                pending("missing TypeScript submodule or reference baseline")
                return
            end
            local file = parse("/file.ts", text, core.ScriptKind.TS)
            local actual = goTokensJSON(file, text, getGoToken)
            assert.are.equal(trimTrailing(expected), trimTrailing(actual))
        end)
    end
end

describe("astnav GetTokenAtPosition", function()
    baselineGoTokensJSON("GetTokenAtPosition", function(file, pos)
        return toTokenInfo(astnav.GetTokenAtPosition(file, pos))
    end)

    it("JSDoc type assertion", function()
        local fileText = "function foo(x) {\n    const s = /**@type {string}*/(x)\n}"
        local file = parse("/test.js", fileText, core.ScriptKind.JS)
        -- Position of 'x' inside the parenthesized expression (position 52)
        local token = astnav.GetTouchingPropertyName(file, 52)
        assert.is_not_nil(token)
        assert.is_true(token.kind == Kind.Identifier or token.kind == Kind.ParenthesizedExpression)
    end)

    it("JSDoc type assertion with comment", function()
        local fileText = "function foo(x) {\n    const s = /**@type {string}*/(x)  // Go-to-definition on x causes panic\n}"
        local file = parse("/test.js", fileText, core.ScriptKind.JS)
        local token = astnav.GetTouchingPropertyName(file, 52)
        assert.is_not_nil(token)
    end)

    it("pointer equality", function()
        local fileText = "\n\t\t\tfunction foo() {\n\t\t\t\treturn 0;\n\t\t\t}\n\t\t"
        local file = parse("/file.ts", fileText, core.ScriptKind.TS)
        assert.are.equal(astnav.GetTokenAtPosition(file, 0), astnav.GetTokenAtPosition(file, 0))
    end)
end)

describe("astnav GetTouchingPropertyName", function()
    baselineGoTokensJSON("GetTouchingPropertyName", function(file, pos)
        return toTokenInfo(astnav.GetTouchingPropertyName(file, pos))
    end)
end)

describe("astnav FindPrecedingToken", function()
    baselineGoTokensJSON("FindPrecedingToken", function(file, pos)
        return toTokenInfo(astnav.FindPrecedingToken(file, pos))
    end)
end)

describe("astnav FindNextToken", function()
    baselineGoTokensJSON("FindNextToken", function(file, pos)
        -- FindNextToken panics (like Go's assert) when the scanner finds trivia between
        -- previousToken.End() and the next syntactic token. Those positions are absent from the baseline.
        local ok, result = pcall(function()
            local token = astnav.GetTokenAtPosition(file, pos)
            local next_ = astnav.FindNextToken(token, file:AsNode(), file)
            return toTokenInfo(next_)
        end)
        if not ok then
            return nil
        end
        return result
    end)
end)

describe("astnav unit FindPrecedingToken", function()
    local testCases = {
        {
            name = "after dot in jsdoc",
            fileContent = [[
import {
    CharacterCodes,
    compareStringsCaseInsensitive,
    compareStringsCaseSensitive,
    compareValues,
    Comparison,
    Debug,
    endsWith,
    equateStringsCaseInsensitive,
    equateStringsCaseSensitive,
    GetCanonicalFileName,
    getDeclarationFileExtension,
    getStringComparer,
    identity,
    lastOrUndefined,
    Path,
    some,
    startsWith,
} from "./_namespaces/ts.js";

/**
 * Internally, we represent paths as strings with '/' as the directory separator.
 * When we make system calls (eg: LanguageServiceHost.getDirectory()),
 * we expect the host to correctly handle paths in our specified format.
 *
 * @internal
 */
export const directorySeparator = "/";
/** @internal */
export const altDirectorySeparator = "\\";
const urlSchemeSeparator = "://";
const backslashRegExp = /\\/g;


backslashRegExp.

//Path Tests

/**
 * Determines whether a charCode corresponds to '/' or '\'.
 *
 * @internal
 */
export function isAnyDirectorySeparator(charCode: number): boolean {
    return charCode === CharacterCodes.slash || charCode === CharacterCodes.backslash;
}]],
            position = 839,
            expectedKind = Kind.DotToken,
        },
        {
            name = "after comma in parameter list",
            fileContent = "takesCb((n, s, ))",
            position = 15,
            expectedKind = Kind.CommaToken,
        },
    }
    for _, testCase in ipairs(testCases) do
        it(testCase.name, function()
            local file = parse("/file.ts", testCase.fileContent, core.ScriptKind.TS)
            local token = astnav.FindPrecedingToken(file, testCase.position)
            assert.are.equal(testCase.expectedKind, token.kind)
        end)
    end
end)
