local lsutil = require("tslua.ls.lsutil")
local core = require("tslua.core")
local json = require("tslua.json")
local modulespecifiers = require("tslua.modulespecifiers")
local vfsmatch = require("tslua.vfs.vfsmatch")
local strings = require("tslua.module").strings

local Tristate = core.Tristate
local QuotePreference = lsutil.QuotePreference
local JsxAttributeCompletionStyle = lsutil.JsxAttributeCompletionStyle
local IncludeInlayParameterNameHints = lsutil.IncludeInlayParameterNameHints
local OrganizeImportsSort = lsutil.OrganizeImportsSort
local OrganizeImportsCollation = lsutil.OrganizeImportsCollation
local OrganizeImportsCaseFirst = lsutil.OrganizeImportsCaseFirst
local OrganizeImportsTypeOrder = lsutil.OrganizeImportsTypeOrder
local WorkspaceSymbolsScope = lsutil.WorkspaceSymbolsScope
local ImportModuleSpecifierPreference = modulespecifiers.ImportModuleSpecifierPreference
local ImportModuleSpecifierEndingPreference = modulespecifiers.ImportModuleSpecifierEndingPreference

-- UserPreferences, InlayHintsPreferences and CodeLensUserPreferences are Go value structs: Lua
-- tables with every field set (zero values filled in by the *_new constructors). Treat them as
-- immutable and copy with Clone() before changing a field.

local UserPreferences = {}
UserPreferences.__index = UserPreferences
lsutil.UserPreferences = UserPreferences

local InlayHintsPreferences = {}
InlayHintsPreferences.__index = InlayHintsPreferences
lsutil.InlayHintsPreferences = InlayHintsPreferences

local CodeLensUserPreferences = {}
CodeLensUserPreferences.__index = CodeLensUserPreferences
lsutil.CodeLensUserPreferences = CodeLensUserPreferences

function lsutil.NewDefaultUserPreferences()
    return lsutil.UserPreferences_new({
        formatCodeSettings = lsutil.GetDefaultFormatCodeSettings(),

        includeCompletionsForModuleExports = Tristate.TSTrue,
        includeCompletionsForImportStatements = Tristate.TSTrue,
        enableAutoClosingTags = Tristate.TSTrue,
        enableJSDocCompletions = Tristate.TSTrue,
        generateReturnInDocTemplate = Tristate.TSTrue,

        allowRenameOfImportPath = Tristate.TSTrue,
        provideRefactorNotApplicableReason = Tristate.TSTrue,
        enableFormatting = Tristate.TSTrue,
        enableValidation = Tristate.TSTrue,
        displayPartsForJSDoc = Tristate.TSTrue,
        disableLineTextInReferences = Tristate.TSTrue,
        reportStyleChecksAsWarnings = Tristate.TSTrue,

        excludeLibrarySymbolsInNavTo = Tristate.TSTrue,
        workspaceSymbolsScope = WorkspaceSymbolsScope.AllOpenProjects,
    })
end

-- UserPreferences represents TypeScript language service preferences.
--
-- Fields are populated using two tags:
--   - `raw:"name"` or `raw:"name,invert"` - TypeScript/raw name for unstable section lookup
--   - `config:"path.to.setting"` or `config:"path.to.setting,invert"` - VS Code nested config path
--
-- At least one tag must be present on each preference field.
-- The `,invert` modifier inverts boolean values (e.g., VS Code's "suppress" -> our "include").
--
-- Fields lists the Go struct fields in declaration order with their types and tags (the Lua
-- stand-in for reflection).
UserPreferences.Fields = {
    { name = "formatCodeSettings", type = "FormatCodeSettings" },

    { name = "quotePreference", type = "QuotePreference", raw = "quotePreference", config = "preferences.quoteStyle" },
    { name = "lazyConfiguredProjectsFromExternalProject", type = "Tristate", raw = "lazyConfiguredProjectsFromExternalProject" },

    -- A positive integer indicating the maximum length of a hover text before it is truncated.
    --
    -- Default: `500`
    { name = "maximumHoverLength", type = "int", raw = "maximumHoverLength" },

    -- ------- Completions -------

    { name = "includeCompletionsForModuleExports", type = "Tristate", raw = "includeCompletionsForModuleExports", config = "suggest.autoImports" },
    { name = "includeCompletionsForImportStatements", type = "Tristate", raw = "includeCompletionsForImportStatements", config = "suggest.includeCompletionsForImportStatements" },
    { name = "includeAutomaticOptionalChainCompletions", type = "Tristate", raw = "includeAutomaticOptionalChainCompletions", config = "suggest.includeAutomaticOptionalChainCompletions" },
    { name = "includeCompletionsWithClassMemberSnippets", type = "Tristate", raw = "includeCompletionsWithClassMemberSnippets", config = "suggest.classMemberSnippets.enabled" },
    { name = "includeCompletionsWithObjectLiteralMethodSnippets", type = "Tristate", raw = "includeCompletionsWithObjectLiteralMethodSnippets", config = "suggest.objectLiteralMethodSnippets.enabled" },
    { name = "jsxAttributeCompletionStyle", type = "JsxAttributeCompletionStyle", raw = "jsxAttributeCompletionStyle", config = "preferences.jsxAttributeCompletionStyle" },
    { name = "enableAutoClosingTags", type = "Tristate", raw = "autoClosingTags", config = "autoClosingTags.enabled", fallbackConfig = "autoClosingTags" },
    { name = "enableJSDocCompletions", type = "Tristate", raw = "completeJSDocs", config = "suggest.jsdoc.enabled", fallbackConfig = "suggest.completeJSDocs" },
    { name = "generateReturnInDocTemplate", type = "Tristate", raw = "generateReturnInDocTemplate", config = "suggest.jsdoc.generateReturns" },

    -- ------- AutoImports --------

    { name = "importModuleSpecifierPreference", type = "ImportModuleSpecifierPreference", raw = "importModuleSpecifierPreference", config = "preferences.importModuleSpecifier" },
    -- Determines whether we import `foo/index.ts` as "foo", "foo/index", or "foo/index.js"
    { name = "importModuleSpecifierEnding", type = "ImportModuleSpecifierEndingPreference", raw = "importModuleSpecifierEnding", config = "preferences.importModuleSpecifierEnding" },
    { name = "autoImportSpecifierExcludeRegexes", type = "[]string", raw = "autoImportSpecifierExcludeRegexes", config = "preferences.autoImportSpecifierExcludeRegexes" },
    { name = "autoImportFileExcludePatterns", type = "[]string", raw = "autoImportFileExcludePatterns", config = "preferences.autoImportFileExcludePatterns" },
    { name = "autoImportEntrypointDirectorySearch", type = "Tristate", raw = "autoImportEntrypointDirectorySearch", config = "preferences.autoImportEntrypointDirectorySearch" },
    { name = "preferTypeOnlyAutoImports", type = "Tristate", raw = "preferTypeOnlyAutoImports", config = "preferences.preferTypeOnlyAutoImports" },

    -- ------- OrganizeImports -------

    { name = "organizeImportsSort", type = "OrganizeImportsSort", raw = "organizeImportsSort", config = "preferences.organizeImports.sort" },
    { name = "organizeImportsIgnoreCase", type = "Tristate", raw = "organizeImportsIgnoreCase", config = "preferences.organizeImports.caseSensitivity" },
    { name = "organizeImportsCollation", type = "OrganizeImportsCollation", raw = "organizeImportsCollation", config = "preferences.organizeImports.unicodeCollation" },
    { name = "organizeImportsLocale", type = "string", raw = "organizeImportsLocale", config = "preferences.organizeImports.locale" },
    { name = "organizeImportsNumericCollation", type = "Tristate", raw = "organizeImportsNumericCollation", config = "preferences.organizeImports.numericCollation" },
    { name = "organizeImportsAccentCollation", type = "Tristate", raw = "organizeImportsAccentCollation", config = "preferences.organizeImports.accentCollation" },
    { name = "organizeImportsCaseFirst", type = "OrganizeImportsCaseFirst", raw = "organizeImportsCaseFirst", config = "preferences.organizeImports.caseFirst" },
    { name = "organizeImportsTypeOrder", type = "OrganizeImportsTypeOrder", raw = "organizeImportsTypeOrder", config = "preferences.organizeImports.typeOrder" },

    -- ------- MoveToFile -------

    { name = "allowTextChangesInNewFiles", type = "Tristate", raw = "allowTextChangesInNewFiles" },

    -- ------- Rename -------

    { name = "useAliasesForRename", type = "Tristate", raw = "providePrefixAndSuffixTextForRename", config = "preferences.useAliasesForRenames" },
    { name = "allowRenameOfImportPath", type = "Tristate", raw = "allowRenameOfImportPath" },

    -- ------- CodeFixes/Refactors -------

    { name = "provideRefactorNotApplicableReason", type = "Tristate", raw = "provideRefactorNotApplicableReason" },

    -- ------- InlayHints -------

    { name = "inlayHints", type = "InlayHintsPreferences" },

    -- ------- CodeLens -------

    { name = "codeLens", type = "CodeLensUserPreferences" },

    -- ------- Definition -------

    { name = "preferGoToSourceDefinition", type = "bool", raw = "preferGoToSourceDefinition" },

    -- ------- Symbols -------

    { name = "excludeLibrarySymbolsInNavTo", type = "Tristate", raw = "excludeLibrarySymbolsInNavTo", config = "workspaceSymbols.excludeLibrarySymbols" },
    { name = "workspaceSymbolsScope", type = "WorkspaceSymbolsScope", config = "workspaceSymbols.scope" },

    -- ------- Misc -------

    { name = "enableFormatting", type = "Tristate", raw = "formatEnabled", config = "format.enabled", fallbackConfig = "format.enable" },
    { name = "enableValidation", type = "Tristate", raw = "validateEnabled", config = "validate.enabled", fallbackConfig = "validate.enable" },
    { name = "disableSuggestions", type = "Tristate", raw = "disableSuggestions" },
    { name = "disableLineTextInReferences", type = "Tristate", raw = "disableLineTextInReferences" },
    { name = "displayPartsForJSDoc", type = "Tristate", raw = "displayPartsForJSDoc" },
    { name = "reportStyleChecksAsWarnings", type = "Tristate", raw = "reportStyleChecksAsWarnings", config = "reportStyleChecksAsWarnings" },
    { name = "locale", type = "string", config = "locale" },

    -- ------- ATA -------

    -- DisableAutomaticTypeAcquisition is the deprecated setting from typescript.disableAutomaticTypeAcquisition.
    { name = "disableAutomaticTypeAcquisition", type = "Tristate", raw = "disableAutomaticTypeAcquisition", config = "disableAutomaticTypeAcquisition" },
    -- AutomaticTypeAcquisitionEnabled is the unified setting from tsserver.automaticTypeAcquisition.enabled under the js/ts section.
    -- When set, it takes precedence over DisableAutomaticTypeAcquisition.
    { name = "automaticTypeAcquisitionEnabled", type = "Tristate", raw = "automaticTypeAcquisitionEnabled", config = "tsserver.automaticTypeAcquisition.enabled" },

    -- ------- Project Configuration -------

    -- CustomConfigFileName specifies a custom config file name to use before defaulting to tsconfig.json/jsconfig.json.
    { name = "customConfigFileName", type = "string", raw = "customConfigFileName", config = "customConfigFileName" },
}

InlayHintsPreferences.Fields = {
    { name = "includeInlayParameterNameHints", type = "IncludeInlayParameterNameHints", raw = "includeInlayParameterNameHints", config = "inlayHints.parameterNames.enabled" },
    { name = "includeInlayParameterNameHintsWhenArgumentMatchesName", type = "Tristate", raw = "includeInlayParameterNameHintsWhenArgumentMatchesName", config = "inlayHints.parameterNames.suppressWhenArgumentMatchesName,invert" },
    { name = "includeInlayFunctionParameterTypeHints", type = "Tristate", raw = "includeInlayFunctionParameterTypeHints", config = "inlayHints.parameterTypes.enabled" },
    { name = "includeInlayVariableTypeHints", type = "Tristate", raw = "includeInlayVariableTypeHints", config = "inlayHints.variableTypes.enabled" },
    { name = "includeInlayVariableTypeHintsWhenTypeMatchesName", type = "Tristate", raw = "includeInlayVariableTypeHintsWhenTypeMatchesName", config = "inlayHints.variableTypes.suppressWhenTypeMatchesName,invert" },
    { name = "includeInlayPropertyDeclarationTypeHints", type = "Tristate", raw = "includeInlayPropertyDeclarationTypeHints", config = "inlayHints.propertyDeclarationTypes.enabled" },
    { name = "includeInlayFunctionLikeReturnTypeHints", type = "Tristate", raw = "includeInlayFunctionLikeReturnTypeHints", config = "inlayHints.functionLikeReturnTypes.enabled" },
    { name = "includeInlayEnumMemberValueHints", type = "Tristate", raw = "includeInlayEnumMemberValueHints", config = "inlayHints.enumMemberValues.enabled" },
}

CodeLensUserPreferences.Fields = {
    { name = "referencesCodeLensEnabled", type = "Tristate", raw = "referencesCodeLensEnabled", config = "referencesCodeLens.enabled" },
    { name = "implementationsCodeLensEnabled", type = "Tristate", raw = "implementationsCodeLensEnabled", config = "implementationsCodeLens.enabled" },
    { name = "referencesCodeLensShowOnAllFunctions", type = "Tristate", raw = "referencesCodeLensShowOnAllFunctions", config = "referencesCodeLens.showOnAllFunctions" },
    { name = "implementationsCodeLensShowOnInterfaceMethods", type = "Tristate", raw = "implementationsCodeLensShowOnInterfaceMethods", config = "implementationsCodeLens.showOnInterfaceMethods" },
    { name = "implementationsCodeLensShowOnAllClassMethods", type = "Tristate", raw = "implementationsCodeLensShowOnAllClassMethods", config = "implementationsCodeLens.showOnAllClassMethods" },
}

-- Struct-typed fields: Go type name -> { fields, constructor }.
local structTypes = {
    FormatCodeSettings = function()
        return lsutil.FormatCodeSettings.Fields, lsutil.FormatCodeSettings_new
    end,
    EditorSettings = function()
        return lsutil.EditorSettingsFields, nil
    end,
    InlayHintsPreferences = function()
        return InlayHintsPreferences.Fields, lsutil.InlayHintsPreferences_new
    end,
    CodeLensUserPreferences = function()
        return CodeLensUserPreferences.Fields, lsutil.CodeLensUserPreferences_new
    end,
}

local function newStruct(mt, fields, init)
    local p = {}
    if init ~= nil then
        for k, v in pairs(init) do
            p[k] = v
        end
    end
    for _, f in ipairs(fields) do
        if p[f.name] == nil then
            local st = structTypes[f.type]
            if st ~= nil then
                local _, ctor = st()
                p[f.name] = ctor()
            else
                local z = lsutil.fieldZeroValues[f.type]
                if z ~= nil then
                    p[f.name] = z
                end
            end
        end
    end
    return setmetatable(p, mt)
end

-- UserPreferences_new(init) is Go's `UserPreferences{...}` (zero values filled in; nested struct
-- fields given in init may be plain tables and are completed too).
function lsutil.UserPreferences_new(init)
    if init ~= nil then
        local copy = {}
        for k, v in pairs(init) do
            copy[k] = v
        end
        if copy.formatCodeSettings ~= nil and getmetatable(copy.formatCodeSettings) ~= lsutil.FormatCodeSettings then
            copy.formatCodeSettings = lsutil.FormatCodeSettings_new(copy.formatCodeSettings)
        end
        if copy.inlayHints ~= nil and getmetatable(copy.inlayHints) ~= InlayHintsPreferences then
            copy.inlayHints = lsutil.InlayHintsPreferences_new(copy.inlayHints)
        end
        if copy.codeLens ~= nil and getmetatable(copy.codeLens) ~= CodeLensUserPreferences then
            copy.codeLens = lsutil.CodeLensUserPreferences_new(copy.codeLens)
        end
        init = copy
    end
    return newStruct(UserPreferences, UserPreferences.Fields, init)
end

function lsutil.InlayHintsPreferences_new(init)
    return newStruct(InlayHintsPreferences, InlayHintsPreferences.Fields, init)
end

function lsutil.CodeLensUserPreferences_new(init)
    return newStruct(CodeLensUserPreferences, CodeLensUserPreferences.Fields, init)
end

local function shallowClone(t)
    local c = {}
    for k, v in pairs(t) do
        c[k] = v
    end
    return setmetatable(c, getmetatable(t))
end

-- Go value copy (nested structs are copied too; slices are shared, like Go).
function UserPreferences:Clone()
    local c = shallowClone(self)
    c.formatCodeSettings = self.formatCodeSettings:Clone()
    c.inlayHints = shallowClone(self.inlayHints)
    c.codeLens = shallowClone(self.codeLens)
    return c
end

function InlayHintsPreferences:Clone()
    return shallowClone(self)
end

function CodeLensUserPreferences:Clone()
    return shallowClone(self)
end

-- IsATADisabled returns whether Automatic Type Acquisition is disabled based on user preferences.
-- It checks the unified setting (tsserver.automaticTypeAcquisition.enabled) first,
-- then falls back to the deprecated setting (disableAutomaticTypeAcquisition).
function UserPreferences:IsATADisabled()
    if not core.Tristate_IsUnknown(self.automaticTypeAcquisitionEnabled) then
        return not core.Tristate_IsTrue(self.automaticTypeAcquisitionEnabled)
    end
    return core.Tristate_IsTrue(self.disableAutomaticTypeAcquisition)
end

-- --- Reflection-based parsing infrastructure ---

-- typeParsers maps a Go type name to a function that parses a value into that type.
lsutil.typeParsers = {
    Tristate = function(val)
        if type(val) == "boolean" then
            if val then
                return Tristate.TSTrue
            end
            return Tristate.TSFalse
        end
        return Tristate.TSUnknown
    end,
    IndentStyle = function(val)
        return lsutil.parseIndentStyle(val)
    end,
    SemicolonPreference = function(val)
        return lsutil.parseSemicolonPreference(val)
    end,
    QuotePreference = function(val)
        if type(val) == "string" then
            local s = strings.ToLower(val)
            if s == "auto" then
                return QuotePreference.Auto
            elseif s == "double" then
                return QuotePreference.Double
            elseif s == "single" then
                return QuotePreference.Single
            end
        end
        return QuotePreference.Unknown
    end,
    JsxAttributeCompletionStyle = function(val)
        if type(val) == "string" then
            local s = strings.ToLower(val)
            if s == "braces" then
                return JsxAttributeCompletionStyle.Braces
            elseif s == "none" then
                return JsxAttributeCompletionStyle.None
            end
        end
        return JsxAttributeCompletionStyle.Auto
    end,
    IncludeInlayParameterNameHints = function(val)
        if type(val) == "string" then
            if val == "all" then
                return IncludeInlayParameterNameHints.All
            elseif val == "literals" then
                return IncludeInlayParameterNameHints.Literals
            end
        end
        return IncludeInlayParameterNameHints.None
    end,
    OrganizeImportsSort = function(val)
        if type(val) == "string" then
            local s = strings.ToLower(val)
            if s == "ordinal" then
                return OrganizeImportsSort.Ordinal
            elseif s == "ordinalignorecase" then
                return OrganizeImportsSort.OrdinalIgnoreCase
            elseif s == "natural" then
                return OrganizeImportsSort.Natural
            elseif s == "naturalignorecase" then
                return OrganizeImportsSort.NaturalIgnoreCase
            end
        end
        return OrganizeImportsSort.Auto
    end,
    OrganizeImportsCollation = function(val)
        if type(val) == "string" and strings.ToLower(val) == "unicode" then
            return OrganizeImportsCollation.Unicode
        end
        return OrganizeImportsCollation.Ordinal
    end,
    OrganizeImportsCaseFirst = function(val)
        if type(val) == "string" then
            if val == "lower" then
                return OrganizeImportsCaseFirst.Lower
            elseif val == "upper" then
                return OrganizeImportsCaseFirst.Upper
            end
        end
        return OrganizeImportsCaseFirst.False
    end,
    OrganizeImportsTypeOrder = function(val)
        if type(val) == "string" then
            if val == "last" then
                return OrganizeImportsTypeOrder.Last
            elseif val == "inline" then
                return OrganizeImportsTypeOrder.Inline
            elseif val == "first" then
                return OrganizeImportsTypeOrder.First
            end
        end
        return OrganizeImportsTypeOrder.Auto
    end,
    ImportModuleSpecifierPreference = function(val)
        if type(val) == "string" then
            local s = strings.ToLower(val)
            if s == "project-relative" then
                return ImportModuleSpecifierPreference.ProjectRelative
            elseif s == "relative" then
                return ImportModuleSpecifierPreference.Relative
            elseif s == "non-relative" then
                return ImportModuleSpecifierPreference.NonRelative
            end
        end
        return ImportModuleSpecifierPreference.Shortest
    end,
    ImportModuleSpecifierEndingPreference = function(val)
        if type(val) == "string" then
            local s = strings.ToLower(val)
            if s == "minimal" then
                return ImportModuleSpecifierEndingPreference.Minimal
            elseif s == "index" then
                return ImportModuleSpecifierEndingPreference.Index
            elseif s == "js" then
                return ImportModuleSpecifierEndingPreference.Js
            end
        end
        return ImportModuleSpecifierEndingPreference.Auto
    end,
}

-- Kinds of the Go field types (reflect.Kind) for types without a custom parser/serializer.
local fieldKinds = {
    int = "int",
    bool = "bool",
    string = "string",
    ["[]string"] = "slice",
    -- string-based enums without a custom parser/serializer
    WorkspaceSymbolsScope = "string",
    SemicolonPreference = "string",
    QuotePreference = "string",
    IncludeInlayParameterNameHints = "string",
    -- int-based enums
    IndentStyle = "int",
}

-- typeSerializers maps a Go type name to a function that serializes a value of that type.
-- For types which do not serialize as-is (tristate, enums, etc).
lsutil.typeSerializers = {
    Tristate = function(val)
        if val == Tristate.TSTrue then
            return true
        elseif val == Tristate.TSFalse then
            return false
        else
            return nil
        end
    end,
    OrganizeImportsSort = function(val)
        if val == OrganizeImportsSort.Ordinal then
            return "ordinal"
        elseif val == OrganizeImportsSort.OrdinalIgnoreCase then
            return "ordinalIgnoreCase"
        elseif val == OrganizeImportsSort.Natural then
            return "natural"
        elseif val == OrganizeImportsSort.NaturalIgnoreCase then
            return "naturalIgnoreCase"
        else
            return "auto"
        end
    end,
    OrganizeImportsCollation = function(val)
        if val == OrganizeImportsCollation.Unicode then
            return "unicode"
        end
        return "ordinal"
    end,
    OrganizeImportsCaseFirst = function(val)
        if val == OrganizeImportsCaseFirst.Lower then
            return "lower"
        elseif val == OrganizeImportsCaseFirst.Upper then
            return "upper"
        else
            return "default"
        end
    end,
    OrganizeImportsTypeOrder = function(val)
        if val == OrganizeImportsTypeOrder.Last then
            return "last"
        elseif val == OrganizeImportsTypeOrder.Inline then
            return "inline"
        elseif val == OrganizeImportsTypeOrder.First then
            return "first"
        else
            return "auto"
        end
    end,
    -- These enums distinguish an unset zero value (e.g. "") from their effective
    -- default (e.g. "auto"): the parser promotes unset/unknown input to the
    -- non-zero default. Plain string serialization would therefore write "" for
    -- an unset field and the parser would read it back as the non-zero default,
    -- breaking round-tripping. Mirror the core.Tristate serializer above and omit
    -- the unset value (return nil) so it decodes back to the zero value. (Enums
    -- whose default already is their zero value, like the OrganizeImports* ones,
    -- round-trip without this.)
    JsxAttributeCompletionStyle = function(val)
        if val ~= JsxAttributeCompletionStyle.Unknown then
            return val
        end
        return nil
    end,
    ImportModuleSpecifierPreference = function(val)
        if val ~= "" then
            return val
        end
        return nil
    end,
    ImportModuleSpecifierEndingPreference = function(val)
        if val ~= "" then
            return val
        end
        return nil
    end,
}

-- configPathParsers provides field-specific config value parsers that override the default
-- type-based parser when the VS Code config value format differs from the Go field type.
lsutil.configPathParsers = {
    -- VS Code sends caseSensitivity as a string ("auto"/"caseSensitive"/"caseInsensitive"),
    -- but OrganizeImportsIgnoreCase is a core.Tristate.
    ["preferences.organizeImports.caseSensitivity"] = function(val)
        if type(val) == "string" then
            local s = strings.ToLower(val)
            if s == "caseinsensitive" then
                return Tristate.TSTrue
            elseif s == "casesensitive" then
                return Tristate.TSFalse
            end
        end
        if type(val) == "boolean" then
            if val then
                return Tristate.TSTrue
            end
            return Tristate.TSFalse
        end
        return Tristate.TSUnknown
    end,
}

-- fieldInfo: { rawName, configPath, fallbackConfigPaths, fieldPath (array of Lua field names;
-- embedded structs are flattened so they add no path element), fieldType, rawInvert, configInvert }

local fieldInfoCacheValue
function lsutil.fieldInfoCache()
    if fieldInfoCacheValue == nil then
        fieldInfoCacheValue = lsutil.collectFieldInfos(UserPreferences.Fields, nil)
    end
    return fieldInfoCacheValue
end

-- unstableNameIndex maps raw names to fieldInfo index for unstable section lookup.
local unstableNameIndexValue
function lsutil.unstableNameIndex()
    if unstableNameIndexValue == nil then
        local infos = lsutil.fieldInfoCache()
        local index = {}
        for i1, info in ipairs(infos) do
            if info.rawName ~= "" then
                index[info.rawName] = i1 - 1
            end
        end
        unstableNameIndexValue = index
    end
    return unstableNameIndexValue
end

function lsutil.collectFieldInfos(fields, indexPath)
    local infos = {}
    for _, field in ipairs(fields) do
        local currentPath = {}
        for i, p in ipairs(indexPath or {}) do
            currentPath[i] = p
        end
        if not field.embedded then
            currentPath[#currentPath + 1] = field.name
        end

        local rawTag = field.raw or ""
        local configTag = field.config or ""
        local fallbackConfigTag = field.fallbackConfig or ""

        if rawTag == "" and configTag == "" then
            -- Embedded struct without tags - recurse into it
            local st = structTypes[field.type]
            if st ~= nil then
                local subFields = st()
                for _, info in ipairs(lsutil.collectFieldInfos(subFields, currentPath)) do
                    infos[#infos + 1] = info
                end
                goto continue
            end
            error("raw or config tag required for field " .. field.name, 0)
        end

        do
            local info = {
                rawName = "",
                configPath = "",
                fallbackConfigPaths = nil,
                fieldPath = currentPath,
                fieldType = field.type,
                rawInvert = false,
                configInvert = false,
            }

            -- Parse raw tag: "name" or "name,invert"
            if rawTag ~= "" then
                local parts = strings.Split(rawTag, ",")
                info.rawName = parts[1]
                for i = 2, #parts do
                    if parts[i] == "invert" then
                        info.rawInvert = true
                    end
                end
            end

            -- Parse config tag: "path.to.setting" or "path.to.setting,invert"
            if configTag ~= "" then
                local configPath = lsutil.parseConfigPathTag(configTag)
                info.configPath = configPath.path
                info.configInvert = configPath.invert
            end
            if fallbackConfigTag ~= "" then
                info.fallbackConfigPaths = {}
                for _, tag in ipairs(strings.Split(fallbackConfigTag, ";")) do
                    info.fallbackConfigPaths[#info.fallbackConfigPaths + 1] = lsutil.parseConfigPathTag(tag)
                end
            end

            infos[#infos + 1] = info
        end
        ::continue::
    end
    return infos
end

function lsutil.parseConfigPathTag(tag)
    local parts = strings.Split(tag, ",")
    local info = { path = parts[1], invert = false }
    for i = 2, #parts do
        if parts[i] == "invert" then
            info.invert = true
        end
    end
    return info
end

-- Returns (value, ok). config values are decoded JSON: objects are Lua tables.
function lsutil.getNestedValue(config, path)
    local parts = strings.Split(path, ".")
    local current = config
    for _, part in ipairs(parts) do
        if type(current) ~= "table" or getmetatable(current) ~= nil and getmetatable(current) ~= json.Object then
            return nil, false
        end
        local v = current[part]
        if v == nil then
            return nil, false
        end
        current = v
    end
    return current, true
end

function lsutil.setNestedValue(config, path, value)
    local parts = strings.Split(path, ".")
    local current = config
    for i = 1, #parts - 1 do
        local part = parts[i]
        local next_ = current[part]
        if type(next_) ~= "table" then
            next_ = {}
            current[part] = next_
        end
        current = next_
    end
    current[parts[#parts]] = value
end

-- p must be a private copy (see withConfig); settings is a decoded JSON object.
function lsutil.setRawFieldsFromConfig(p, infos, settings)
    local index = lsutil.unstableNameIndex()
    for name, value in pairs(settings) do
        local idx = index[name]
        if idx ~= nil then
            local info = infos[idx + 1]
            if info.rawInvert then
                if type(value) == "boolean" then
                    value = not value
                end
            end
            lsutil.setFieldFromValue(p, info, value)
        end
    end
end

function UserPreferences:withConfig(config)
    local p = self:Clone()
    local infos = lsutil.fieldInfoCache()

    -- Raw UserPreferences can be provided directly, notably via LSP initializationOptions.
    lsutil.setRawFieldsFromConfig(p, infos, config)

    -- Process "unstable" section first - allows any field to be set by raw name.
    -- This mirrors VS Code's behavior: { ...config.get('unstable'), ...stableOptions }
    -- where stable options are spread after and take precedence.
    local unstable = config["unstable"]
    if type(unstable) == "table" then
        lsutil.setRawFieldsFromConfig(p, infos, unstable)
    end

    -- Process path-based config (VS Code style nested paths).
    -- These run after unstable, so stable config values take precedence.
    for _, info in ipairs(infos) do
        if info.configPath == "" then
            goto continue
        end
        do
            local configPath = { path = info.configPath, invert = info.configInvert }
            local val, ok = lsutil.getNestedValue(config, configPath.path)
            if not ok then
                for _, fallbackConfigPath in ipairs(info.fallbackConfigPaths or {}) do
                    val, ok = lsutil.getNestedValue(config, fallbackConfigPath.path)
                    if ok then
                        configPath = fallbackConfigPath
                        break
                    end
                end
            end
            if not ok then
                goto continue
            end

            if configPath.invert then
                if type(val) == "boolean" then
                    val = not val
                end
            end
            local parser = lsutil.configPathParsers[configPath.path]
            if parser ~= nil then
                local container, name = lsutil.getFieldByPath(p, info.fieldPath)
                container[name] = parser(val)
                goto continue
            end
            lsutil.setFieldFromValue(p, info, val)
        end
        ::continue::
    end

    -- Validate CustomConfigFileName for path traversal
    if p.customConfigFileName ~= "" then
        local name = strings.TrimSpace(p.customConfigFileName)
        if string.find(name, "[/\\]") or name == ".." or name == "." then
            p.customConfigFileName = ""
        else
            p.customConfigFileName = name
        end
    end

    return p
end

-- Returns the table holding the field and the field name.
function lsutil.getFieldByPath(v, path)
    for i = 1, #path - 1 do
        v = v[path[i]]
    end
    return v, path[#path]
end

local function truncToInt(v)
    if math.type(v) == "integer" then
        return v
    end
    if v ~= v or v == math.huge or v == -math.huge then
        return nil
    end
    local t = v < 0 and math.ceil(v) or math.floor(v)
    return math.tointeger(t)
end

function lsutil.setFieldFromValue(p, info, val)
    if val == nil or val == json.Null then
        return
    end
    local container, name = lsutil.getFieldByPath(p, info.fieldPath)

    -- Check custom parsers first (for types like Tristate, enums, etc.)
    local parser = lsutil.typeParsers[info.fieldType]
    if parser ~= nil then
        container[name] = parser(val)
        return
    end

    local kind = fieldKinds[info.fieldType]
    if kind == "bool" then
        if type(val) == "boolean" then
            container[name] = val
        end
    elseif kind == "int" then
        if type(val) == "number" then
            local i = truncToInt(val)
            if i ~= nil then
                container[name] = i
            end
        end
    elseif kind == "string" then
        if type(val) == "string" then
            container[name] = val
        end
    elseif kind == "slice" then
        if type(val) == "table" then
            local result = {}
            for _, item in ipairs(val) do
                if type(item) == "string" then
                    result[#result + 1] = item
                end
            end
            container[name] = result
        end
    end
end

-- Returns the JSON-shaped config table Go's MarshalJSONTo encodes.
function UserPreferences:toConfig()
    local config = {}

    for _, info in ipairs(lsutil.fieldInfoCache()) do
        local container, name = lsutil.getFieldByPath(self, info.fieldPath)

        local val = lsutil.serializeField(info.fieldType, container[name])
        if val == nil then
            goto continue
        end

        -- Prefer config path if available, otherwise use unstable section
        if info.configPath ~= "" then
            if info.configInvert then
                if type(val) == "boolean" then
                    val = not val
                end
            end
            lsutil.setNestedValue(config, info.configPath, val)
        elseif info.rawName ~= "" then
            if info.rawInvert then
                if type(val) == "boolean" then
                    val = not val
                end
            end
            lsutil.setNestedValue(config, "unstable." .. info.rawName, val)
        end
        ::continue::
    end
    return config
end

function UserPreferences:MarshalJSONTo(enc)
    return json.MarshalEncode(enc, self:toConfig(), json.Deterministic(true))
end

-- Lua json convention: returns (string, err).
function UserPreferences:MarshalJSON()
    return json.Marshal(self:toConfig())
end

function lsutil.serializeField(fieldType, value)
    -- Check custom serializers first (for types like Tristate, enums, etc.)
    local serializer = lsutil.typeSerializers[fieldType]
    if serializer ~= nil then
        return serializer(value)
    end

    local kind = fieldKinds[fieldType]
    if kind == "bool" then
        return value
    elseif kind == "int" then
        -- Zero means "unset" for these preference fields. Omit it so a partial
        -- config does not clobber defaults with zeros when round-tripped through
        -- withConfig.
        if value == 0 then
            return nil
        end
        return value
    elseif kind == "string" then
        -- Zero ("") means "unset"; omit it for the same reason as int above.
        if value == "" then
            return nil
        end
        return value
    elseif kind == "slice" then
        if value == nil then
            return nil
        end
        local result = {}
        for i, s in ipairs(value) do
            result[i] = s
        end
        return result
    else
        return value
    end
end

-- Replaces the contents of self (Go `*p = ...`). Returns err or nil.
function UserPreferences:UnmarshalJSONFrom(dec)
    local config, err = json.UnmarshalDecode(dec)
    if err ~= nil then
        return err
    end
    -- Start with defaults, then overlay parsed values
    local p = lsutil.NewDefaultUserPreferences():withConfig(config or {})
    for k in pairs(self) do
        self[k] = nil
    end
    for k, v in pairs(p) do
        self[k] = v
    end
    return nil
end

-- --- Helper methods ---

function UserPreferences:ModuleSpecifierPreferences()
    return modulespecifiers.UserPreferences_new({
        importModuleSpecifierPreference = self.importModuleSpecifierPreference,
        importModuleSpecifierEnding = self.importModuleSpecifierEnding,
        autoImportSpecifierExcludeRegexes = self.autoImportSpecifierExcludeRegexes,
    })
end

function UserPreferences:ParsedAutoImportFileExcludePatterns(useCaseSensitiveFileNames)
    return vfsmatch.NewSpecMatcher(self.autoImportFileExcludePatterns, "", vfsmatch.Usage.Exclude, useCaseSensitiveFileNames)
end

function UserPreferences:IsModuleSpecifierExcluded(moduleSpecifier)
    return modulespecifiers.IsExcludedByRegex(moduleSpecifier, self.autoImportSpecifierExcludeRegexes)
end

function lsutil.ParseUserPreferences(items)
    local prefs = lsutil.NewDefaultUserPreferences()
    -- Apply editor settings first (tabSize, indentSize, etc.) as raw-name defaults,
    -- then overlay language-specific settings with increasing precedence:
    -- editor < javascript < typescript < js/ts
    local editorItem = items["editor"]
    if editorItem ~= nil and editorItem ~= json.Null then
        if type(editorItem) == "table" then
            local normalizedSettings = {}
            for k, v in pairs(editorItem) do
                normalizedSettings[k] = v
            end
            local tabSize = normalizedSettings["tabSize"]
            if tabSize ~= nil then
                if normalizedSettings["indentSize"] == nil then
                    normalizedSettings["indentSize"] = tabSize
                end
            end
            local insertSpaces = normalizedSettings["insertSpaces"]
            if insertSpaces ~= nil then
                if normalizedSettings["convertTabsToSpaces"] == nil then
                    normalizedSettings["convertTabsToSpaces"] = insertSpaces
                end
            end
            prefs = prefs:withConfig({ unstable = normalizedSettings })
        end
    end
    -- Apply javascript, then typescript, then js/ts (highest precedence).
    for _, section in ipairs({ "javascript", "typescript", "js/ts" }) do
        local item = items[section]
        if item ~= nil and item ~= json.Null then
            if type(item) == "table" then
                prefs = prefs:withConfig(item)
            end
        end
    end
    return prefs
end
