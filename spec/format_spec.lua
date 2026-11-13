local ast = require("tslua.ast")
local core = require("tslua.core")
local format = require("tslua.format")
local lsutil = require("tslua.ls.lsutil")
local parser = require("tslua.parser")
local repo = require("tslua.repo")

local Kind = ast.Kind
local T = core.Tristate

local function parse(fileName, text, scriptKind)
    local opts = ast.NewSourceFileParseOptions(fileName, fileName, nil)
    return parser.ParseSourceFile(opts, text, scriptKind)
end

local function applyBulkEdits(text, edits)
    local b = {}
    local lastEnd = 0
    for _, e in ipairs(edits or {}) do
        local start = e:Pos()
        if start ~= lastEnd then
            b[#b + 1] = string.sub(text, lastEnd + 1, e:Pos())
        end
        b[#b + 1] = e.newText
        lastEnd = e:End()
    end
    b[#b + 1] = string.sub(text, lastEnd + 1)
    return table.concat(b)
end

local function settings(init)
    return lsutil.FormatCodeSettings_new(init)
end

local function contains(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

describe("format TestFormatNoTrailingSpace #slow", function()
    local testCases = {
        { "simple statement without trailing newline", "1;" },
        { "function call without trailing newline", "console.log('hello');" },
        { "if block on single line", "if (true) { }" },
        { "class declaration", "class A {\n    // Class Contents Go Here\n}" },
        { "class declaration with trailing newline", "class A {\n    // Class Contents Go Here\n}\n" },
        { "empty block", "if (true) {}" },
        { "module declaration", "module M { }" },
        { "enum declaration", "enum E { A, B }" },
    }
    for _, tc in ipairs(testCases) do
        it(tc[1], function()
            local ctx = format.WithFormatCodeSettings(nil, settings({
                tabSize = 4,
                indentSize = 4,
                newLineCharacter = "\n",
                convertTabsToSpaces = T.TSTrue,
                indentStyle = lsutil.IndentStyle.Smart,
                trimTrailingWhitespace = T.TSTrue,
            }), "\n")
            local sourceFile = parse("/test.ts", tc[2], core.ScriptKind.TS)
            local edits = format.FormatDocument(ctx, sourceFile)
            local newText = applyBulkEdits(tc[2], edits)
            -- Formatting should not add trailing whitespace at end of file
            for line in (newText .. "\n"):gmatch("(.-)\n") do
                local trimmed = line:gsub("[ \t]+$", "")
                assert.are.equal(trimmed, line)
            end
        end)
    end
end)

describe("format TestFormat #slow", function()
    it("format checker.ts", function()
        local ctx = format.WithFormatCodeSettings(nil, settings({
            tabSize = 4,
            indentSize = 4,
            baseIndentSize = 4,
            newLineCharacter = "\n",
            convertTabsToSpaces = T.TSTrue,
            indentStyle = lsutil.IndentStyle.Smart,
            trimTrailingWhitespace = T.TSTrue,
            insertSpaceBeforeTypeAnnotation = T.TSTrue,
        }), "\n")
        local f = io.open(repo.TypeScriptSubmodulePath() .. "/src/compiler/checker.ts", "rb")
        if f == nil then
            pending("TypeScript submodule not available")
            return
        end
        local text = f:read("a")
        f:close()
        local sourceFile = parse("/checker.ts", text, core.ScriptKind.TS)
        local edits = format.FormatDocument(ctx, sourceFile)
        local newText = applyBulkEdits(text, edits)
        assert.is_true(#newText > 0)
        assert.is_true(text ~= newText)
    end)
end)

describe("format TestGetContainingList_NamedImports #slow", function()
    it("returns the named imports list", function()
        local text = 'import type {\n    AAA,\n    BBB,\n} from "./bar";'
        local sourceFile = parse("/test.ts", text, core.ScriptKind.TS)

        local importSpecifiers = {}
        local function forEachDescendantOfKind(node, kind, action)
            node:ForEachChild(function(child)
                if child.kind == kind then
                    action(child)
                end
                forEachDescendantOfKind(child, kind, action)
                return false
            end)
        end
        forEachDescendantOfKind(sourceFile:AsNode(), Kind.ImportSpecifier, function(node)
            importSpecifiers[#importSpecifiers + 1] = node
        end)

        assert.are.equal(2, #importSpecifiers)
        for _, specifier in ipairs(importSpecifiers) do
            local list = format.GetContainingList(specifier, sourceFile)
            assert.is_not_nil(list)
            assert.are.equal(2, #list.nodes)
        end
    end)
end)

describe("format TestGetIndentationForNamedImportsPosition #slow", function()
    it("indents named import specifiers", function()
        local text = 'import {\n    type SomeInterface,\n} from "./exports.js";'
        local sourceFile = parse("/test.ts", text, core.ScriptKind.TS)
        local options = lsutil.GetDefaultFormatCodeSettings()
        local lineStart = format.GetLineStartPositionForPosition(14, sourceFile) -- 14 is somewhere in "    type"
        local indent = format.GetIndentation(lineStart, sourceFile, options, true)
        assert.are.equal(4, indent)
    end)
end)

local function tabSettings(extra)
    local init = {
        tabSize = 4,
        indentSize = 4,
        baseIndentSize = 0,
        newLineCharacter = "\n",
        convertTabsToSpaces = T.TSFalse, -- Use tabs
        indentStyle = lsutil.IndentStyle.Smart,
        trimTrailingWhitespace = T.TSTrue,
    }
    for k, v in pairs(extra or {}) do
        init[k] = v
    end
    return format.WithFormatCodeSettings(nil, settings(init), "\n")
end

local function formatDocument(ctx, text, fileName, scriptKind)
    local sourceFile = parse(fileName or "/test.ts", text, scriptKind or core.ScriptKind.TS)
    return applyBulkEdits(text, format.FormatDocument(ctx, sourceFile))
end

describe("format TestCommentFormatting #slow", function()
    it("format comment issue reproduction", function()
        local ctx = format.WithFormatCodeSettings(nil, settings({
            tabSize = 4,
            indentSize = 4,
            baseIndentSize = 4,
            newLineCharacter = "\n",
            convertTabsToSpaces = T.TSTrue,
            indentStyle = lsutil.IndentStyle.Smart,
            trimTrailingWhitespace = T.TSTrue,
            insertSpaceBeforeTypeAnnotation = T.TSTrue,
        }), "\n")

        -- Original code that causes the bug
        local originalText = "class C {\n    /**\n     *\n    */\n    async x() {}\n}"

        -- Apply formatting once
        local firstFormatted = formatDocument(ctx, originalText)

        -- Check that the asterisk is not corrupted
        assert.is_false(contains(firstFormatted, "*/\n   /"), "should not corrupt */ to /")
        assert.is_true(contains(firstFormatted, "*/"), "should preserve */ token")
        assert.is_true(contains(firstFormatted, "async"), "should preserve async keyword")

        -- Apply formatting a second time to test stability
        local secondFormatted = formatDocument(ctx, firstFormatted)

        -- Check that second formatting doesn't introduce corruption
        assert.is_false(contains(secondFormatted, " sync x()"), "should not corrupt async to sync")
        assert.is_true(contains(secondFormatted, "async"), "should preserve async keyword on second pass")
    end)

    it("format JSDoc with tab indentation", function()
        local ctx = tabSettings({ insertSpaceBeforeTypeAnnotation = T.TSTrue })
        local originalText = "class Foo {\n\t/**\n\t * @param {string} argument - This is a param description.\n\t */\n\texample(argument) {\nconsole.log(argument);\n\t}\n}"
        local formatted = formatDocument(ctx, originalText)
        assert.is_false(contains(formatted, " \t*"), "should not have space before tab before asterisk")
        assert.is_true(contains(formatted, "\t *"), "should have tab before space before asterisk")
        assert.is_true(contains(formatted, "\t\tconsole.log"), "console.log should be indented with two tabs")
    end)

    it("format comment inside multi-line argument list", function()
        local ctx = tabSettings({ insertSpaceBeforeTypeAnnotation = T.TSTrue })
        local originalText = "console.log(\n\t\"a\",\n\t// the second arg\n\t\"b\"\n);"
        local formatted = formatDocument(ctx, originalText)
        assert.is_true(contains(formatted, "\t// the second arg"), "comment should be indented with tab")
        assert.is_false(contains(formatted, "\n// the second arg"), "comment should not lose indentation")
    end)

    it("format comment in chained method calls", function()
        local ctx = tabSettings({ insertSpaceBeforeTypeAnnotation = T.TSTrue })
        local originalText = "foo\n\t.bar()\n\t// A second call\n\t.baz();"
        local formatted = formatDocument(ctx, originalText)
        assert.is_true(contains(formatted, "\t// A second call") or contains(formatted, "   // A second call"),
            "comment should be indented")
        assert.is_false(contains(formatted, "\n// A second call"), "comment should not lose indentation")
    end)

    -- Regression test for issue #1928 - panic when formatting chained method call with comment
    it("format chained method call with comment (issue #1928)", function()
        local ctx = tabSettings({ insertSpaceBeforeTypeAnnotation = T.TSTrue })
        -- This code previously caused a panic with "strings: negative Repeat count"
        -- because tokenIndentation was -1 and was being used directly for indentation
        local originalText = "foo\n\t.bar()\n\t// A second call\n\t.baz();"
        local formatted = formatDocument(ctx, originalText)
        assert.is_true(contains(formatted, "\t// A second call") or contains(formatted, "   // A second call"),
            "comment should be indented")
        assert.is_false(contains(formatted, "\n// A second call"), "comment should not be at column 0")
    end)

    it("multiline comment inside block that opens on first line (issue #2649)", function()
        local ctx = tabSettings()
        local originalText = "document.addEventListener('DOMContentLoaded', () => {\n" ..
            "    /** @type {NodeListOf<HTMLSpanElement>} */\n" ..
            "    const elements = document.querySelectorAll('.test')\n" ..
            "});"
        local formatted = formatDocument(ctx, originalText, "/test.js", core.ScriptKind.JS)
        assert.is_true(#formatted > 0, "formatted text should not be empty")
    end)

    it("single-line comment inside block that opens on first line (issue #2649)", function()
        local ctx = tabSettings()
        local originalText = "document.addEventListener('DOMContentLoaded', () => {\n    // a comment\n    const x = 1\n});"
        local formatted = formatDocument(ctx, originalText)
        assert.is_true(#formatted > 0, "formatted text should not be empty")
    end)
end)

describe("format TestFormatSelectionPreservesComments #slow", function()
    local function spaceSettings(extra)
        local init = {
            tabSize = 4,
            indentSize = 4,
            baseIndentSize = 0,
            newLineCharacter = "\n",
            convertTabsToSpaces = T.TSTrue,
            indentStyle = lsutil.IndentStyle.Smart,
            trimTrailingWhitespace = T.TSTrue,
        }
        for k, v in pairs(extra or {}) do
            init[k] = v
        end
        return format.WithFormatCodeSettings(nil, settings(init), "\n")
    end
    local originalText = "const test/* comment */=5;"
    local commentStart = string.find(originalText, "/*", 1, true) - 1

    it("format selection should not delete block comment when selection ends inside comment", function()
        local ctx = spaceSettings()
        local sourceFile = parse("/test.ts", originalText, core.ScriptKind.TS)
        local selectionEnd = commentStart + #"/* comment" -- ends inside the comment, before the closing `*/`
        local edits = format.FormatSelection(ctx, sourceFile, 0, selectionEnd)
        assert.are.equal(originalText, applyBulkEdits(originalText, edits))
    end)

    it("format selection should not delete block comment when selection starts inside comment", function()
        local ctx = spaceSettings()
        local sourceFile = parse("/test.ts", originalText, core.ScriptKind.TS)
        local selectionStart = commentStart + 3 -- inside the comment
        local edits = format.FormatSelection(ctx, sourceFile, selectionStart, #originalText)
        assert.are.equal(originalText, applyBulkEdits(originalText, edits))
    end)

    it("full document format should preserve block comment and add spaces", function()
        local ctx = spaceSettings({ insertSpaceBeforeAndAfterBinaryOperators = T.TSTrue })
        assert.are.equal("const test/* comment */ = 5;", formatDocument(ctx, originalText))
    end)
end)

describe("format TestSliceBoundsPanic #slow", function()
    it("format code with trailing semicolon should not panic", function()
        local ctx = format.WithFormatCodeSettings(nil, settings({
            tabSize = 4,
            indentSize = 4,
            baseIndentSize = 4,
            newLineCharacter = "\n",
            convertTabsToSpaces = T.TSTrue,
            indentStyle = lsutil.IndentStyle.Smart,
            trimTrailingWhitespace = T.TSTrue,
            insertSpaceBeforeTypeAnnotation = T.TSTrue,
        }), "\n")
        local originalText = "const _enableDisposeWithListenerWarning = false\n" ..
            "\t// || Boolean(\"TRUE\") // causes a linter warning so that it cannot be pushed\n" ..
            "\t;\n"
        local formatted = formatDocument(ctx, originalText)
        assert.is_true(#formatted > 0, "formatted text should not be empty")
        assert.is_true(contains(formatted, "_enableDisposeWithListenerWarning"), "should preserve variable name")
    end)
end)
