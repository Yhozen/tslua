local lsutil = require("tslua.ls.lsutil")
local core = require("tslua.core")
local printer = require("tslua.printer")

local Tristate = core.Tristate
local IndentStyle = lsutil.IndentStyle
local SemicolonPreference = lsutil.SemicolonPreference

function lsutil.parseIndentStyle(v)
    if type(v) == "string" then
        local s = string.lower(v)
        if s == "none" then
            return IndentStyle.None
        elseif s == "block" then
            return IndentStyle.Block
        elseif s == "smart" then
            return IndentStyle.Smart
        end
    elseif math.type(v) == "float" then
        -- Go IndentStyle(int(s)): truncation toward zero
        local i = math.tointeger(v < 0 and math.ceil(v) or math.floor(v))
        if i ~= nil then
            return i
        end
    elseif math.type(v) == "integer" then
        return v
    end
    return IndentStyle.Smart
end

function lsutil.parseSemicolonPreference(v)
    if type(v) == "string" then
        local s = string.lower(v)
        if s == "ignore" then
            return SemicolonPreference.Ignore
        elseif s == "insert" then
            return SemicolonPreference.Insert
        elseif s == "remove" then
            return SemicolonPreference.Remove
        end
    end
    return SemicolonPreference.Ignore
end

-- EditorSettings is embedded in FormatCodeSettings; its fields are flattened onto
-- FormatCodeSettings tables (Go value structs: treat as immutable, copy with Clone()).
--
-- Fields describes every field of the Go struct in declaration order (the Lua stand-in for
-- reflection over the struct tags): name is the Lua field, type the Go field type, raw/config/
-- fallbackConfig the Go struct tags.
lsutil.EditorSettingsFields = {
    { name = "baseIndentSize", type = "int", raw = "baseIndentSize", config = "format.baseIndentSize" },
    { name = "indentSize", type = "int", raw = "indentSize", config = "format.indentSize" },
    { name = "tabSize", type = "int", raw = "tabSize", config = "format.tabSize" },
    { name = "newLineCharacter", type = "string", raw = "newLineCharacter", config = "format.newLineCharacter" },
    { name = "convertTabsToSpaces", type = "Tristate", raw = "convertTabsToSpaces", config = "format.convertTabsToSpaces" },
    { name = "indentStyle", type = "IndentStyle", raw = "indentStyle", config = "format.indentStyle" },
    { name = "trimTrailingWhitespace", type = "Tristate", raw = "trimTrailingWhitespace", config = "format.trimTrailingWhitespace" },
}

local FormatCodeSettings = {}
FormatCodeSettings.__index = FormatCodeSettings
lsutil.FormatCodeSettings = FormatCodeSettings

FormatCodeSettings.Fields = {
    { name = "EditorSettings", type = "EditorSettings", embedded = true },
    { name = "insertSpaceAfterCommaDelimiter", type = "Tristate", raw = "insertSpaceAfterCommaDelimiter", config = "format.insertSpaceAfterCommaDelimiter" },
    { name = "insertSpaceAfterSemicolonInForStatements", type = "Tristate", raw = "insertSpaceAfterSemicolonInForStatements", config = "format.insertSpaceAfterSemicolonInForStatements" },
    { name = "insertSpaceBeforeAndAfterBinaryOperators", type = "Tristate", raw = "insertSpaceBeforeAndAfterBinaryOperators", config = "format.insertSpaceBeforeAndAfterBinaryOperators" },
    { name = "insertSpaceAfterConstructor", type = "Tristate", raw = "insertSpaceAfterConstructor", config = "format.insertSpaceAfterConstructor" },
    { name = "insertSpaceAfterKeywordsInControlFlowStatements", type = "Tristate", raw = "insertSpaceAfterKeywordsInControlFlowStatements", config = "format.insertSpaceAfterKeywordsInControlFlowStatements" },
    { name = "insertSpaceAfterFunctionKeywordForAnonymousFunctions", type = "Tristate", raw = "insertSpaceAfterFunctionKeywordForAnonymousFunctions", config = "format.insertSpaceAfterFunctionKeywordForAnonymousFunctions" },
    { name = "insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis", type = "Tristate", raw = "insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis", config = "format.insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis" },
    { name = "insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets", type = "Tristate", raw = "insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets", config = "format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets" },
    { name = "insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces", type = "Tristate", raw = "insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces", config = "format.insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces" },
    { name = "insertSpaceAfterOpeningAndBeforeClosingEmptyBraces", type = "Tristate", raw = "insertSpaceAfterOpeningAndBeforeClosingEmptyBraces", config = "format.insertSpaceAfterOpeningAndBeforeClosingEmptyBraces" },
    { name = "insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces", type = "Tristate", raw = "insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces", config = "format.insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces" },
    { name = "insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces", type = "Tristate", raw = "insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces", config = "format.insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces" },
    { name = "insertSpaceAfterTypeAssertion", type = "Tristate", raw = "insertSpaceAfterTypeAssertion", config = "format.insertSpaceAfterTypeAssertion" },
    { name = "insertSpaceBeforeFunctionParenthesis", type = "Tristate", raw = "insertSpaceBeforeFunctionParenthesis", config = "format.insertSpaceBeforeFunctionParenthesis" },
    { name = "placeOpenBraceOnNewLineForFunctions", type = "Tristate", raw = "placeOpenBraceOnNewLineForFunctions", config = "format.placeOpenBraceOnNewLineForFunctions" },
    { name = "placeOpenBraceOnNewLineForControlBlocks", type = "Tristate", raw = "placeOpenBraceOnNewLineForControlBlocks", config = "format.placeOpenBraceOnNewLineForControlBlocks" },
    { name = "insertSpaceBeforeTypeAnnotation", type = "Tristate", raw = "insertSpaceBeforeTypeAnnotation", config = "format.insertSpaceBeforeTypeAnnotation" },
    { name = "indentMultiLineObjectLiteralBeginningOnBlankLine", type = "Tristate", raw = "indentMultiLineObjectLiteralBeginningOnBlankLine", config = "format.indentMultiLineObjectLiteralBeginningOnBlankLine" },
    { name = "semicolons", type = "SemicolonPreference", raw = "semicolons", config = "format.semicolons" },
    { name = "indentSwitchCase", type = "Tristate", raw = "indentSwitchCase", config = "format.indentSwitchCase" },
}

-- Go zero values of the field types used by the preference structs.
lsutil.fieldZeroValues = {
    int = 0,
    bool = false,
    string = "",
    Tristate = Tristate.TSUnknown,
    IndentStyle = IndentStyle.None,
    SemicolonPreference = "",
    QuotePreference = "",
    JsxAttributeCompletionStyle = "",
    IncludeInlayParameterNameHints = "",
    OrganizeImportsSort = 0,
    OrganizeImportsCollation = false,
    OrganizeImportsCaseFirst = 0,
    OrganizeImportsTypeOrder = 0,
    ImportModuleSpecifierPreference = "",
    ImportModuleSpecifierEndingPreference = "",
    WorkspaceSymbolsScope = "",
}

local function fillZero(t, fields)
    for _, f in ipairs(fields) do
        if f.embedded then
            fillZero(t, lsutil.EditorSettingsFields)
        elseif t[f.name] == nil then
            local z = lsutil.fieldZeroValues[f.type]
            if z ~= nil then
                t[f.name] = z
            end
        end
    end
end
lsutil.fillZeroFields = fillZero

-- FormatCodeSettings_new(init) is Go's `FormatCodeSettings{...}` (zero values filled in).
function lsutil.FormatCodeSettings_new(init)
    local s = {}
    if init ~= nil then
        for k, v in pairs(init) do
            s[k] = v
        end
    end
    fillZero(s, FormatCodeSettings.Fields)
    return setmetatable(s, FormatCodeSettings)
end

-- Go value copy.
function FormatCodeSettings:Clone()
    local s = {}
    for k, v in pairs(self) do
        s[k] = v
    end
    return setmetatable(s, FormatCodeSettings)
end

function lsutil.FromLSFormatOptions(f, opt)
    local updatedSettings = f:Clone()
    updatedSettings.tabSize = opt.tabSize
    updatedSettings.indentSize = opt.tabSize
    updatedSettings.convertTabsToSpaces = core.BoolToTristate(opt.insertSpaces)
    if opt.trimTrailingWhitespace ~= nil then
        updatedSettings.trimTrailingWhitespace = core.BoolToTristate(opt.trimTrailingWhitespace)
    end
    return updatedSettings
end

function FormatCodeSettings:ToLSFormatOptions()
    local trimTrailingWhitespace = core.Tristate_IsTrue(self.trimTrailingWhitespace)
    return {
        tabSize = self.tabSize,
        insertSpaces = core.Tristate_IsTrue(self.convertTabsToSpaces),
        trimTrailingWhitespace = trimTrailingWhitespace,
    }
end

function lsutil.GetDefaultFormatCodeSettings()
    return lsutil.FormatCodeSettings_new({
        indentSize = printer.GetDefaultIndentSize(),
        tabSize = printer.GetDefaultIndentSize(),
        newLineCharacter = "\n",
        convertTabsToSpaces = Tristate.TSTrue,
        indentStyle = IndentStyle.Smart,
        trimTrailingWhitespace = Tristate.TSTrue,
        insertSpaceAfterConstructor = Tristate.TSFalse,
        insertSpaceAfterCommaDelimiter = Tristate.TSTrue,
        insertSpaceAfterSemicolonInForStatements = Tristate.TSTrue,
        insertSpaceBeforeAndAfterBinaryOperators = Tristate.TSTrue,
        insertSpaceAfterKeywordsInControlFlowStatements = Tristate.TSTrue,
        insertSpaceAfterFunctionKeywordForAnonymousFunctions = Tristate.TSFalse,
        insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis = Tristate.TSFalse,
        insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets = Tristate.TSFalse,
        insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces = Tristate.TSTrue,
        insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces = Tristate.TSFalse,
        insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces = Tristate.TSFalse,
        insertSpaceBeforeFunctionParenthesis = Tristate.TSFalse,
        placeOpenBraceOnNewLineForFunctions = Tristate.TSFalse,
        placeOpenBraceOnNewLineForControlBlocks = Tristate.TSFalse,
        semicolons = SemicolonPreference.Ignore,
        indentSwitchCase = Tristate.TSTrue,
    })
end
