local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsutil = require("tslua.ls.lsutil")
local module = require("tslua.module")
local modulespecifiers = require("tslua.modulespecifiers")
local packagejson = require("tslua.packagejson")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local stringutil = require("tslua.stringutil")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local ContextFlags = checker.ContextFlags
local ScriptElementKind = lsutil.ScriptElementKind
local ScriptElementKindModifier = lsutil.ScriptElementKindModifier
local JSONValueType = packagejson.JSONValueType

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function hasPrefix(s, p)
    return #s >= #p and string.sub(s, 1, #p) == p
end

local function hasSuffix(s, p)
    return #s >= #p and (p == "" or string.sub(s, -#p) == p)
end

local function trimPrefix(s, p)
    if hasPrefix(s, p) then
        return string.sub(s, #p + 1)
    end
    return s
end

local function containsString(s, sub)
    return string.find(s, sub, 1, true) ~= nil
end

local function slicesContains(xs, x)
    for _, v in ipairs(xs or {}) do
        if v == x then
            return true
        end
    end
    return false
end

-- strings.TrimLeftFunc(s, f) over UTF-8 runes.
local function trimLeftFunc(s, f)
    local pos = 0
    while pos < #s do
        local r, size = stringutil.DecodeRune(s, pos)
        if not f(r) then
            break
        end
        pos = pos + size
    end
    return string.sub(s, pos + 1)
end

-- strings.TrimSpace (unicode.IsSpace on both ends).
local function trimSpace(s)
    s = trimLeftFunc(s, stringutil.UnicodeIsSpace)
    local end_ = #s
    while end_ > 0 do
        local r, size = stringutil.DecodeLastRune(s, end_)
        if not stringutil.UnicodeIsSpace(r) then
            break
        end
        end_ = end_ - size
    end
    return string.sub(s, 1, end_)
end

-- Unexported constants of string_completions.go.
ls.moduleCompletionKind = {
    Directory = 0,
    File = 1,
    ExternalModuleName = 2,
}
local moduleCompletionKind = ls.moduleCompletionKind

ls.referenceKind = {
    FileName = 0,
    ModuleSpecifier = 1,
}
local referenceKind = ls.referenceKind

-- completionsFromTypes: { types = []*checker.StringLiteralType, isNewIdentifier = bool }
-- completionsFromProperties: { symbols = []*ast.Symbol, hasIndexSignature = bool }
-- pathCompletion: { name = string, kind = lsutil.ScriptElementKind, extension = string }
-- pathCompletions: { entries = []*pathCompletion, replacementSpan = *lsproto.Range }
-- stringLiteralCompletions: { fromTypes, fromProperties, fromPaths }
-- moduleCompletionNameAndKind: { name = string, kind = moduleCompletionKind, extension = string }
-- extensionOptions: { extensionsToSearch, referenceKind, importingSourceFile, endingPreference, resolutionMode }

local function newModuleCompletionNameAndKind(name, kind, extension)
    return { name = name, kind = kind, extension = extension or "" }
end

function LanguageService:getStringLiteralCompletions(ctx, file, position, contextToken, typeChecker, compilerOptions, includeSymbols)
    if ls.isInReferenceComment(file, position) then
        local completion = self:getTripleSlashReferenceCompletions(file, position, self:GetProgram(), typeChecker)
        return self:convertPathCompletions(ctx, completion, file, position)
    end
    if ls.IsInString(file, position, contextToken) then
        if contextToken == nil or not ast.IsStringLiteralLike(contextToken) then
            return nil
        end
        local entries = self:getStringLiteralCompletionEntries(
            ctx,
            file,
            contextToken,
            position,
            typeChecker
        )
        return self:convertStringLiteralCompletions(
            ctx,
            entries,
            contextToken,
            file,
            position,
            typeChecker,
            compilerOptions,
            includeSymbols
        )
    end
    return nil
end

function LanguageService:convertStringLiteralCompletions(ctx, completion, contextToken, file, position, typeChecker, options, includeSymbols)
    if completion == nil then
        return nil
    end

    local optionalReplacementRange = self:createRangeFromStringLiteralLikeContent(file, contextToken, position)
    if completion.fromPaths ~= nil then
        return self:convertPathCompletions(ctx, completion.fromPaths, file, position)
    elseif completion.fromProperties ~= nil then
        local fromProperties = completion.fromProperties
        local data = setmetatable({
            symbols = fromProperties.symbols,
            autoImports = nil,
            completionKind = ls.CompletionKind.String,
            isInSnippetScope = false,
            propertyAccessToConvert = nil,
            isNewIdentifierLocation = fromProperties.hasIndexSignature,
            location = file:AsNode(),
            keywordFilters = ls.KeywordCompletionFilters.None,
            literals = nil,
            symbolToOriginInfoMap = {},
            symbolToSortTextMap = {},
            recommendedCompletion = nil,
            previousToken = nil,
            contextToken = contextToken,
            jsxInitializer = { isInitializer = false, initializer = nil },
            insideJSDocTagTypeExpression = false,
            isTypeOnlyLocation = false,
            isJsxIdentifierExpected = false,
            isRightOfOpenTag = false,
            isRightOfDotOrQuestionDot = false,
            importStatementCompletion = nil,
            hasUnresolvedAutoImports = false,
            defaultCommitCharacters = nil,
        }, ls.completionDataData)
        local _, items, err = self:getCompletionEntriesFromSymbols(
            ctx,
            typeChecker,
            data,
            contextToken, --[[replacementToken]]
            position,
            file,
            options,
            includeSymbols --[[includeSymbols]]
        )
        if err ~= nil then
            error(err, 0)
        end
        local defaultCommitCharacters = ls.getDefaultCommitCharacters(fromProperties.hasIndexSignature)
        local itemDefaults = self:setItemDefaults(
            ctx,
            position,
            file,
            items,
            defaultCommitCharacters,
            optionalReplacementRange
        )
        return setmetatable({
            isIncomplete = false,
            itemDefaults = itemDefaults,
            items = items,
        }, ls.CompletionList)
    elseif completion.fromTypes ~= nil then
        local fromTypes = completion.fromTypes
        local quoteChar
        if contextToken.kind == Kind.NoSubstitutionTemplateLiteral then
            quoteChar = printer.QuoteChar.Backtick
        elseif hasPrefix(contextToken:Text(), "'") then
            quoteChar = printer.QuoteChar.SingleQuote
        else
            quoteChar = printer.QuoteChar.DoubleQuote
        end
        local items = core.Map(fromTypes.types, function(t)
            local name = printer.EscapeString(t:AsLiteralType():Value(), quoteChar)
            local lspItem = self:createLSPCompletionItem(
                ctx,
                name,
                "", --[[insertText]]
                "", --[[filterText]]
                ls.SortText.LocationPriority,
                ScriptElementKind.String,
                ScriptElementKindModifier.None,
                self:getReplacementRangeForContextToken(file, contextToken, position),
                nil, --[[commitCharacters]]
                nil, --[[labelDetails]]
                file,
                position,
                false, --[[isMemberCompletion]]
                false, --[[isSnippet]]
                false, --[[hasAction]]
                false, --[[preselect]]
                "", --[[source]]
                nil, --[[autoImportEntryData]]
                nil, --[[additionalTextEdits]]
                nil --[[detail]]
            )
            return ls.NewCompletionItem(lspItem, nil)
        end)
        local defaultCommitCharacters = ls.getDefaultCommitCharacters(fromTypes.isNewIdentifier)
        local itemDefaults = self:setItemDefaults(
            ctx,
            position,
            file,
            items,
            defaultCommitCharacters,
            nil --[[optionalReplacementSpan]]
        )
        return setmetatable({
            isIncomplete = false,
            itemDefaults = itemDefaults,
            items = items,
        }, ls.CompletionList)
    else
        return nil
    end
end

function LanguageService:convertPathCompletions(ctx, completion, file, position)
    if completion == nil then
        return nil
    end
    local isNewIdentifierLocation = true -- The user may type in a path that doesn't yet exist, creating a "new identifier" with respect to the collection of identifiers the server is aware of.
    local defaultCommitCharacters = ls.getDefaultCommitCharacters(isNewIdentifierLocation)
    local items = core.Map(completion.entries, function(pathCompletion)
        local detail = pathCompletion.name
        if not hasSuffix(pathCompletion.name, pathCompletion.extension) then
            detail = detail .. pathCompletion.extension
        end
        local lspItem = self:createLSPCompletionItem(
            ctx,
            pathCompletion.name,
            "", --[[insertText]]
            "", --[[filterText]]
            ls.SortText.LocationPriority,
            pathCompletion.kind,
            ls.kindModifiersFromExtension(pathCompletion.extension),
            completion.replacementSpan,
            nil, --[[commitCharacters]]
            nil, --[[labelDetails]]
            file,
            position,
            false, --[[isMemberCompletion]]
            false, --[[isSnippet]]
            false, --[[hasAction]]
            false, --[[preselect]]
            "", --[[source]]
            nil, --[[autoImportEntryData]]
            nil, --[[additionalTextEdits]]
            detail
        )
        return ls.NewCompletionItem(lspItem, nil)
    end)
    local itemDefaults = self:setItemDefaults(
        ctx,
        position,
        file,
        items,
        defaultCommitCharacters,
        nil --[[optionalReplacementSpan]]
    )
    return setmetatable({
        isIncomplete = false,
        itemDefaults = itemDefaults,
        items = items,
    }, ls.CompletionList)
end

local callLikeOrJsxAttributeKinds = ast.kindSet(Kind.CallExpression, Kind.NewExpression, Kind.JsxAttribute)
local moduleSpecifierParentKinds = ast.kindSet(Kind.ImportDeclaration, Kind.ExportDeclaration, Kind.ExternalModuleReference, Kind.JSDocImportTag)

function LanguageService:getStringLiteralCompletionEntries(ctx, file, node, position, typeChecker)
    local parent = ls.walkUpParentheses(node.parent)
    local kind = parent.kind
    if kind == Kind.LiteralType then
        local grandparent = ls.walkUpParentheses(parent.parent)
        if grandparent.kind == Kind.ImportType then
            return self:getStringLiteralCompletionsFromModuleNames(
                file,
                node,
                self:GetProgram(),
                typeChecker
            )
        end
        return ls.fromUnionableLiteralType(grandparent, parent, position, typeChecker)
    elseif kind == Kind.PropertyAssignment then
        if ast.IsObjectLiteralExpression(parent.parent) and parent:Name() == node then
            -- Get quoted name of properties of the object literal expression
            -- i.e. interface ConfigFiles {
            --          'jspm:dev': string
            --      }
            --      let files: ConfigFiles = {
            --          '/*completion position*/'
            --      }
            --
            --      function foo(c: ConfigFiles) {}
            --      foo({
            --          '/*completion position*/'
            --      });
            return {
                fromProperties = ls.stringLiteralCompletionsForObjectLiteral(typeChecker, parent.parent),
            }
        end
        if ast.FindAncestor(parent.parent, ast.IsCallLikeExpression) ~= nil then
            local uniques = collections.NewSet()
            local stringLiteralTypes = core.Concatenate(
                ls.getStringLiteralTypes(typeChecker:GetContextualType(node, ContextFlags.None), uniques, typeChecker),
                ls.getStringLiteralTypes(typeChecker:GetContextualType(node, ContextFlags.IgnoreNodeInferences), uniques, typeChecker)
            )
            return ls.toStringLiteralCompletionsFromTypes(stringLiteralTypes)
        end
        return {
            fromTypes = ls.fromContextualType(ContextFlags.None, node, typeChecker),
        }
    elseif kind == Kind.ElementAccessExpression then
        local expression = parent:Expression()
        local argumentExpression = parent:AsElementAccessExpression().argumentExpression
        if node == ast.SkipParentheses(argumentExpression) then
            -- Get all names of properties on the expression
            -- i.e. interface A {
            --      'prop1': string
            -- }
            -- let a: A;
            -- a['/*completion position*/']
            local t = typeChecker:GetTypeAtLocation(expression)
            return {
                fromProperties = ls.stringLiteralCompletionsFromProperties(t, typeChecker),
            }
        end
        return nil
    elseif callLikeOrJsxAttributeKinds[kind] or moduleSpecifierParentKinds[kind] then
        if callLikeOrJsxAttributeKinds[kind] then
            if not ls.isRequireCallArgument(node) and not ast.IsImportCall(parent) then
                local argumentNode
                if parent.kind == Kind.JsxAttribute then
                    argumentNode = parent.parent
                else
                    argumentNode = node
                end
                local argumentInfo = ls.getArgumentInfoForCompletions(argumentNode, position, file, typeChecker)
                -- Get string literal completions from specialized signatures of the target
                -- i.e. declare function f(a: 'A');
                -- f("/*completion position*/")
                if argumentInfo == nil then
                    return nil
                end

                local result = ls.getStringLiteralCompletionsFromSignature(argumentInfo.invocation, node, argumentInfo, typeChecker)
                if result ~= nil then
                    return {
                        fromTypes = result,
                    }
                end
                return {
                    fromTypes = ls.fromContextualType(ContextFlags.None, node, typeChecker),
                }
            end
            -- fallthrough: is `require("")` or `require(""` or `import("")`
        end
        -- Get all known external module names or complete a path to a module
        -- i.e. import * as ns from "/*completion position*/";
        --      var y = import("/*completion position*/");
        --      import x = require("/*completion position*/");
        --      var y = require("/*completion position*/");
        --      export * from "/*completion position*/";
        return self:getStringLiteralCompletionsFromModuleNames(file, node, self:GetProgram(), typeChecker)
    elseif kind == Kind.CaseClause then
        local tracker = ls.newCaseClauseTracker(typeChecker, parent.parent:AsCaseBlock().clauses.nodes)
        local contextualTypes = ls.fromContextualType(ContextFlags.IgnoreNodeInferences, node, typeChecker)
        if contextualTypes == nil then
            return nil
        end
        local literals = core.Filter(contextualTypes.types, function(t)
            return not tracker:hasValue(t:AsLiteralType():Value())
        end)
        return {
            fromTypes = {
                types = literals,
                isNewIdentifier = false,
            },
        }
    elseif kind == Kind.ImportSpecifier or kind == Kind.ExportSpecifier then
        -- Complete string aliases in `import { "|" } from` and `export { "|" } from`
        local specifier = parent
        local propertyName = specifier:PropertyName()
        if propertyName ~= nil and node ~= propertyName then
            return nil -- Don't complete in `export { "..." as "|" } from`
        end
        local namedImportsOrExports = specifier.parent
        local moduleSpecifier
        if namedImportsOrExports.kind == Kind.NamedImports then
            moduleSpecifier = namedImportsOrExports.parent.parent
        else
            moduleSpecifier = namedImportsOrExports.parent
        end
        if moduleSpecifier == nil then
            return nil
        end
        local moduleSpecifierSymbol = typeChecker:GetSymbolAtLocation(moduleSpecifier)
        if moduleSpecifierSymbol == nil then
            return nil
        end
        local exports = typeChecker:GetExportsAndPropertiesOfModule(moduleSpecifierSymbol)
        local existing = collections.NewSetFromItems(table.unpack(core.Map(namedImportsOrExports:Elements() or {}, function(n)
            return n:PropertyNameOrName():Text()
        end)))
        local uniques = core.Filter(exports, function(e)
            return e.name ~= ast.InternalSymbolNameDefault and not existing:Has(e.name)
        end)
        return {
            fromProperties = {
                symbols = uniques,
                hasIndexSignature = false,
            },
        }
    elseif kind == Kind.BinaryExpression then
        if parent:AsBinaryExpression().operatorToken.kind == Kind.InKeyword then
            local t = typeChecker:GetTypeAtLocation(parent:AsBinaryExpression().right)
            local properties = ls.getPropertiesForCompletion(t, typeChecker)
            return {
                fromProperties = {
                    symbols = core.Filter(properties, function(s)
                        return s.valueDeclaration == nil or not ast.IsPrivateIdentifierClassElementDeclaration(s.valueDeclaration)
                    end),
                    hasIndexSignature = false,
                },
            }
        end
        return {
            fromTypes = ls.fromContextualType(ContextFlags.None, node, typeChecker),
        }
    else
        local result = ls.fromContextualType(ContextFlags.IgnoreNodeInferences, node, typeChecker)
        if result ~= nil then
            return {
                fromTypes = result,
            }
        end
        return {
            fromTypes = ls.fromContextualType(ContextFlags.None, node, typeChecker),
        }
    end
end

function ls.fromContextualType(contextFlags, node, typeChecker)
    -- Get completion for string literal from string literal type
    -- i.e. var x: "hi" | "hello" = "/*completion position*/"
    return ls.toCompletionsFromTypes(ls.getStringLiteralTypes(ls.getContextualTypeFromParent(node, typeChecker, contextFlags), nil, typeChecker))
end

function ls.toCompletionsFromTypes(types)
    if core.Len(types) == 0 then
        return nil
    end
    return {
        types = types,
        isNewIdentifier = false,
    }
end

function ls.toStringLiteralCompletionsFromTypes(types)
    local result = ls.toCompletionsFromTypes(types)
    if result == nil then
        return nil
    end
    return {
        fromTypes = result,
    }
end

local unionableTypeArgumentParentKinds = ast.kindSet(
    Kind.CallExpression,
    Kind.ExpressionWithTypeArguments,
    Kind.JsxOpeningElement,
    Kind.JsxSelfClosingElement,
    Kind.NewExpression,
    Kind.TaggedTemplateExpression,
    Kind.TypeReference
)

function ls.fromUnionableLiteralType(grandparent, parent, position, typeChecker)
    local kind = grandparent.kind
    if unionableTypeArgumentParentKinds[kind] then
        local typeArgument = ast.FindAncestor(parent, function(n) return n.parent == grandparent end)
        if typeArgument ~= nil then
            local t = typeChecker:GetTypeArgumentConstraint(typeArgument)
            return {
                fromTypes = {
                    types = ls.getStringLiteralTypes(t, nil, typeChecker),
                    isNewIdentifier = false,
                },
            }
        end
        return nil
    elseif kind == Kind.IndexedAccessType then
        -- Get all apparent property names
        -- i.e. interface Foo {
        --          foo: string;
        --          bar: string;
        --      }
        --      let x: Foo["/*completion position*/"]
        local indexType = grandparent:AsIndexedAccessTypeNode().indexType
        local objectType = grandparent:AsIndexedAccessTypeNode().objectType
        if not indexType.loc:ContainsInclusive(position) then
            return nil
        end
        local t = typeChecker:GetTypeFromTypeNode(objectType)
        return {
            fromProperties = ls.stringLiteralCompletionsFromProperties(t, typeChecker),
        }
    elseif kind == Kind.UnionType then
        local result = ls.fromUnionableLiteralType(
            ls.walkUpParentheses(grandparent.parent),
            parent,
            position,
            typeChecker
        )
        if result == nil then
            return nil
        end
        local alreadyUsedTypes = ls.getAlreadyUsedTypesInStringLiteralUnion(grandparent, parent)
        if result.fromProperties ~= nil then
            local fromProperties = result.fromProperties
            return {
                fromProperties = {
                    symbols = core.Filter(
                        fromProperties.symbols,
                        function(s) return not slicesContains(alreadyUsedTypes, s.name) end
                    ),
                    hasIndexSignature = fromProperties.hasIndexSignature,
                },
            }
        elseif result.fromTypes ~= nil then
            local fromTypes = result.fromTypes
            return {
                fromTypes = {
                    types = core.Filter(fromTypes.types, function(t)
                        return not slicesContains(alreadyUsedTypes, t:AsLiteralType():Value())
                    end),
                    isNewIdentifier = false,
                },
            }
        else
            return nil
        end
    elseif kind == Kind.PropertySignature then
        return {
            fromTypes = {
                types = ls.getStringLiteralTypes(ls.getConstraintOfTypeArgumentProperty(grandparent, typeChecker), nil, typeChecker),
                isNewIdentifier = false,
            },
        }
    else
        return nil
    end
end

function ls.stringLiteralCompletionsForObjectLiteral(typeChecker, objectLiteralExpression)
    local contextualType = typeChecker:GetContextualType(objectLiteralExpression, ContextFlags.None)
    if contextualType == nil then
        return nil
    end

    local completionsType = typeChecker:GetContextualType(objectLiteralExpression, ContextFlags.IgnoreNodeInferences)
    local symbols = ls.getPropertiesForObjectExpression(
        contextualType,
        completionsType,
        objectLiteralExpression,
        typeChecker
    )

    return {
        symbols = symbols,
        hasIndexSignature = ls.hasIndexSignature(contextualType, typeChecker),
    }
end

function ls.stringLiteralCompletionsFromProperties(t, typeChecker)
    return {
        symbols = core.Filter(typeChecker:GetApparentProperties(t), function(s)
            return not (s.valueDeclaration ~= nil and ast.IsPrivateIdentifierClassElementDeclaration(s.valueDeclaration))
        end),
        hasIndexSignature = ls.hasIndexSignature(t, typeChecker),
    }
end

function LanguageService:getStringLiteralCompletionsFromModuleNames(file, node, program, typeChecker)
    local textStart = astnav.GetStartOfNode(node, file, false --[[includeJSDoc]]) + 1
    local replacementSpan, ok = self:pathCompletionReplacementSpan(file, ls.getDirectoryFragmentRange(node:Text(), textStart))
    if not ok then
        return nil
    end
    local nameAndKinds = self:getStringLiteralCompletionsFromModuleNamesWorker(
        file,
        node,
        program,
        typeChecker
    )
    return {
        fromPaths = {
            entries = ls.toPathCompletions(nameAndKinds),
            replacementSpan = replacementSpan,
        },
    }
end

function ls.toPathCompletions(names)
    return core.Map(names, function(nameAndKind)
        return {
            name = nameAndKind.name,
            kind = ls.moduletToScriptElementKind(nameAndKind.kind),
            extension = nameAndKind.extension,
        }
    end)
end

-- Returns (*lsproto.Range, ok).
function LanguageService:pathCompletionReplacementSpan(file, textRange)
    if textRange == nil then
        return nil, true
    end
    local lspRange, fidelity = self:createLspRangeFromBounds(textRange:Pos(), textRange:End(), file)
    if not spanmap.Fidelity_IsExact(fidelity) then
        return nil, false
    end
    return lspRange, true
end

function ls.moduletToScriptElementKind(kind)
    if kind == moduleCompletionKind.Directory then
        return ScriptElementKind.Directory
    elseif kind == moduleCompletionKind.File then
        return ScriptElementKind.ScriptElement
    elseif kind == moduleCompletionKind.ExternalModuleName then
        return ScriptElementKind.ExternalModuleName
    end
    error(string.format("Unknown moduleCompletionKind: %d", kind), 0)
end

function ls.isAnyDirectorySeparator(r)
    return r == 0x2F --[[ '/' ]] or r == 0x5C --[[ '\\' ]]
end

-- Replace everything after the last directory separator that appears
function ls.getDirectoryFragmentRange(text, textStart)
    local index = -1
    for i = #text, 1, -1 do
        if ls.isAnyDirectorySeparator(string.byte(text, i)) then
            index = i - 1
            break
        end
    end
    local offset = 0
    if index ~= -1 then
        offset = index + 1
    end
    local length = #text - offset
    if length == 0 then
        return nil
    end
    return core.NewTextRange(textStart + offset, textStart + offset + length)
end

function LanguageService:getStringLiteralCompletionsFromModuleNamesWorker(file, node, program, typeChecker)
    local literalValue = tspath.NormalizeSlashes(node:Text())
    local mode = core.ModuleKind.ResolutionModeNone
    if ast.IsStringLiteralLike(node) then
        mode = program:GetModeForUsageLocation(file, node)
    end

    local scriptPath = file:Path()
    local scriptDirectory = tspath.Path_GetDirectoryPath(scriptPath)
    local options = program:Options()
    local extensionOptions = self:getExtensionOptions(options, referenceKind.ModuleSpecifier, file, mode, typeChecker)

    if ls.isPathRelativeToScript(literalValue) or
        (collections.OrderedMap.Size(options.paths) == 0 and (tspath.IsRootedDiskPath(literalValue) or tspath.IsUrl(literalValue))) then
        return self:getCompletionEntriesForRelativeModules(
            literalValue,
            scriptDirectory,
            program,
            scriptPath,
            extensionOptions
        )
    else
        return self:getCompletionEntriesForNonRelativeModules(
            literalValue,
            scriptDirectory,
            mode,
            program,
            typeChecker,
            extensionOptions
        )
    end
end

-- Check all of the declared modules and those in node modules. Possible sources of modules:
--
--	Modules that are found by the type checker
--	Modules found via patterns from "paths" compiler option
--	Modules from node_modules (i.e. those listed in package.json)
--	    This includes all files that are found in node_modules/moduleName/ with acceptable file extensions
function LanguageService:getCompletionEntriesForNonRelativeModules(fragment, scriptPath, mode, program, typeChecker, extensionOptions)
    local compilerOptions = program:Options()
    local paths = compilerOptions.paths

    local result = ls.newModuleCompletionNameAndKindSet()
    local moduleResolution = compilerOptions:GetModuleResolutionKind()

    if paths ~= nil and paths:Size() > 0 then
        local absolute = compilerOptions:GetPathsBasePath(program:GetCurrentDirectory())
        self:addCompletionEntriesFromPaths(result, program, fragment, absolute, extensionOptions, paths)
    end

    local fragmentDirectory = ls.getFragmentDirectory(fragment)
    for _, ambientName in ipairs(ls.getAmbientModuleCompletions(fragment, fragmentDirectory, typeChecker) or {}) do
        result:add(newModuleCompletionNameAndKind(ambientName, moduleCompletionKind.ExternalModuleName, ""))
    end

    self:getCompletionEntriesFromTypings(program, scriptPath, fragmentDirectory, extensionOptions, result)

    if ls.moduleResolutionUsesNodeModules(moduleResolution) then
        -- If looking for a global package name, don't just include everything in `node_modules` because that includes dependencies' own dependencies.
        -- (But do if we didn't find anything, e.g. 'package.json' missing.)
        local foundGlobal = false
        if fragmentDirectory == "" then
            for _, moduleName in ipairs(self:enumerateNodeModulesVisibleToScript(scriptPath) or {}) do
                local moduleResult = newModuleCompletionNameAndKind(moduleName, moduleCompletionKind.ExternalModuleName, "")
                if result.names[moduleResult.name] == nil then
                    foundGlobal = true
                    result:add(moduleResult)
                end
            end
        end
        if not foundGlobal then
            local resolvePackageJsonExports = compilerOptions:GetResolvePackageJsonExports()
            local resolvePackageJsonImports = compilerOptions:GetResolvePackageJsonImports()
            local seenPackageScope = false
            local conditions = module.GetConditions(compilerOptions, mode)

            -- Returns true if the search should stop.
            local function exportsOrImportsLookup(lookupTable, fragment_, baseDirectory, isExports, isImports)
                if lookupTable == nil or lookupTable.type ~= JSONValueType.Object then
                    return lookupTable ~= nil and lookupTable.type ~= JSONValueType.NotPresent
                end
                local keys = lookupTable:AsObject():Keys()
                self:addCompletionEntriesFromPathsOrExportsOrImports(
                    result,
                    program,
                    isExports,
                    isImports,
                    fragment_,
                    baseDirectory,
                    extensionOptions,
                    keys,
                    function(key)
                        local keyValue, ok = lookupTable:AsObject():Get(key)
                        if not ok then
                            return nil
                        end
                        local pattern = ls.getPatternFromFirstMatchingCondition(keyValue, conditions)
                        if pattern == "" then
                            return nil
                        end
                        if hasSuffix(key, "/") and hasSuffix(pattern, "/") then
                            return { pattern .. "*" }
                        end
                        return { pattern }
                    end,
                    module.ComparePatternKeys
                )
                return true
            end

            local function importsLookup(directory)
                if resolvePackageJsonImports and not seenPackageScope then
                    local packageFile = tspath.CombinePaths(directory, "package.json")
                    local packageJsonInfo = program:GetPackageJsonInfo(packageFile)
                    if packageJsonInfo ~= nil and packageJsonInfo:Exists() then
                        seenPackageScope = true
                        exportsOrImportsLookup(packageJsonInfo.contents.imports, fragment, directory, false --[[isExports]], true --[[isImports]])
                    end
                end
            end

            local ancestorLookup = function(ancestor)
                local nodeModules = tspath.CombinePaths(ancestor, "node_modules")
                if self.host:DirectoryExists(nodeModules) then
                    self:getCompletionEntriesForDirectoryFragment(
                        fragment,
                        nodeModules,
                        extensionOptions,
                        program,
                        false, --[[ moduleSpecifierIsRelative ]]
                        "",
                        result
                    )
                end
                importsLookup(ancestor)
                return nil, false
            end

            if fragmentDirectory ~= "" and resolvePackageJsonExports then
                local nodeModulesDirectoryOrImportsLookup = ancestorLookup
                ancestorLookup = function(ancestor)
                    local components = tspath.GetPathComponents(fragment, "")
                    components = core.Slice(components, 1, #components) -- shift off empty root
                    if #components == 0 then
                        nodeModulesDirectoryOrImportsLookup(ancestor)
                        return nil, false
                    end
                    local packagePath = components[1]
                    components = core.Slice(components, 1, #components)
                    if hasPrefix(packagePath, "@") then
                        if #components == 0 then
                            nodeModulesDirectoryOrImportsLookup(ancestor)
                            return nil, false
                        end
                        local subName = components[1]
                        components = core.Slice(components, 1, #components)
                        packagePath = tspath.CombinePaths(packagePath, subName)
                    end
                    if resolvePackageJsonImports and hasPrefix(packagePath, "#") then
                        importsLookup(ancestor)
                        return nil, false
                    end
                    local packageDirectory = tspath.CombinePaths(ancestor, "node_modules", packagePath)
                    local packageFile = tspath.CombinePaths(packageDirectory, "package.json")
                    local packageJsonInfo = program:GetPackageJsonInfo(packageFile)
                    if packageJsonInfo ~= nil and packageJsonInfo:Exists() then
                        local fragmentSubpath = table.concat(components, "/")
                        if #components > 0 and tspath.HasTrailingDirectorySeparator(fragment) then
                            fragmentSubpath = fragmentSubpath .. "/"
                        end
                        if exportsOrImportsLookup(
                            packageJsonInfo.contents.exports,
                            fragmentSubpath,
                            packageDirectory,
                            true, --[[isExports]]
                            false --[[isImports]]
                        ) then
                            return nil, false
                        end
                    end
                    nodeModulesDirectoryOrImportsLookup(ancestor)
                    return nil, false
                end
            end

            local globalCacheLocation = program:GetGlobalTypingsCacheLocation()
            tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(globalCacheLocation, scriptPath, ancestorLookup)
        end
    end

    return result:values()
end

function ls.getFragmentDirectory(fragment)
    if not ls.containsSlash(fragment) then
        return ""
    end
    if tspath.HasTrailingDirectorySeparator(fragment) then
        return fragment
    end
    return tspath.GetDirectoryPath(fragment)
end

function ls.getPatternFromFirstMatchingCondition(target, conditions)
    if target.type == JSONValueType.String then
        return target:AsString()
    end
    if target.type == JSONValueType.Object then
        local obj = target:AsObject()
        for condition in obj:Keys() do
            if condition == "default" or slicesContains(conditions, condition) or
                (slicesContains(conditions, "types") and module.IsApplicableVersionedTypesKey(condition)) then
                local pattern, ok = obj:Get(condition)
                if ok then
                    return ls.getPatternFromFirstMatchingCondition(pattern, conditions)
                end
            end
        end
    end
    return ""
end

function ls.getAmbientModuleCompletions(fragment, fragmentDirectory, typeChecker)
    local ambientModules = typeChecker:GetAmbientModules()
    local nonRelativeModuleNames
    for _, sym in ipairs(ambientModules or {}) do
        local moduleName = stringutil.StripQuotes(sym.name)
        if hasPrefix(moduleName, fragment) and not containsString(moduleName, "*") then
            nonRelativeModuleNames = core.Append(nonRelativeModuleNames, moduleName)
        end
    end

    if fragmentDirectory ~= "" and nonRelativeModuleNames ~= nil then
        local moduleNameWithSeparator = tspath.EnsureTrailingDirectorySeparator(fragmentDirectory)
        for i, moduleName in ipairs(nonRelativeModuleNames) do
            nonRelativeModuleNames[i] = trimPrefix(moduleName, moduleNameWithSeparator)
        end
    end
    return nonRelativeModuleNames
end

function LanguageService:getCompletionEntriesFromTypings(program, scriptPath, fragmentDirectory, extensionOptions, result)
    local options = program:Options()
    local seen = {}

    local typeRoots = options:GetEffectiveTypeRoots(program:GetCurrentDirectory())

    for _, root in ipairs(typeRoots or {}) do
        self:getCompletionEntriesFromTypingsDirectories(root, options, fragmentDirectory, extensionOptions, program, seen, result)
    end

    local globalCacheLocation = program:GetGlobalTypingsCacheLocation()
    tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(globalCacheLocation, scriptPath, function(directory)
        local typesDir = tspath.CombinePaths(directory, "node_modules/@types")
        self:getCompletionEntriesFromTypingsDirectories(typesDir, options, fragmentDirectory, extensionOptions, program, seen, result)
        return nil, false
    end)
end

function LanguageService:getCompletionEntriesFromTypingsDirectories(directory, options, fragmentDirectory, extensionOptions, program, seen, result)
    if not self.host:DirectoryExists(directory) then
        return
    end

    for _, typeDirectoryName in ipairs(self:GetDirectories(directory) or {}) do
        local packageName = module.UnmangleScopedPackageName(typeDirectoryName)
        if core.Len(options.types) > 0 and not slicesContains(options.types, packageName) then
            goto continue
        end

        if fragmentDirectory == "" then
            if not seen[packageName] then
                result:add(newModuleCompletionNameAndKind(packageName, moduleCompletionKind.ExternalModuleName, ""))
                seen[packageName] = true
            end
        else
            local baseDirectory = tspath.CombinePaths(directory, typeDirectoryName)
            local remainingFragment = ls.tryRemoveDirectoryPrefix(fragmentDirectory, packageName, program:UseCaseSensitiveFileNames())
            if remainingFragment ~= nil then
                self:getCompletionEntriesForDirectoryFragment(
                    remainingFragment,
                    baseDirectory,
                    extensionOptions,
                    program,
                    false,
                    "",
                    result
                )
            end
        end
        ::continue::
    end
end

-- Returns a string or nil (Go *string).
function ls.tryRemoveDirectoryPrefix(path, prefix, useCaseSensitiveFileNames)
    local withoutPrefix, ok = tspath.TrimFilePathPrefix(path, prefix, useCaseSensitiveFileNames)
    if not ok then
        return nil
    end
    if hasPrefix(withoutPrefix, "/") or hasPrefix(withoutPrefix, "\\") then
        withoutPrefix = string.sub(withoutPrefix, 2)
    end
    return withoutPrefix
end

function LanguageService:enumerateNodeModulesVisibleToScript(scriptPath)
    local result
    local globalCacheLocation = self.program:GetGlobalTypingsCacheLocation()

    tspath.ForEachAncestorDirectoryStoppingAtGlobalCache(globalCacheLocation, scriptPath, function(directory)
        local packageJsonPath = tspath.CombinePaths(directory, "package.json")
        local packageJsonInfo = self.program:GetPackageJsonInfo(packageJsonPath)
        if packageJsonInfo ~= nil and packageJsonInfo:Exists() and packageJsonInfo.contents ~= nil then
            packageJsonInfo.contents:RangeDependencies(function(name, version, dependencyField)
                if not hasPrefix(name, "@types/") then
                    result = core.Append(result, name)
                end
                return true
            end)
        end
        return nil, false
    end)

    return result
end

function LanguageService:getExtensionOptions(options, referenceKind_, file, mode, typeChecker)
    local extensionsToSearch = ls.getSupportedExtensionsForModuleResolution(options, self:GetProgram():CommandLine():ContentMapperExtensions(), typeChecker)

    return {
        extensionsToSearch = extensionsToSearch,
        referenceKind = referenceKind_,
        importingSourceFile = file,
        endingPreference = self:UserPreferences().importModuleSpecifierEnding,
        resolutionMode = mode,
    }
end

function ls.getSupportedExtensionsForModuleResolution(options, extraExtensions, typeChecker)
    --[[ file extensions from ambient modules declarations e.g. *.css ]]
    local extensions = {}
    if typeChecker ~= nil then
        local ambientModules = typeChecker:GetAmbientModules()
        for _, mod in ipairs(ambientModules or {}) do
            local name = stringutil.StripQuotes(mod.name)
            if not hasPrefix(name, "*.") or containsString(name, "/") then
                goto continue
            end
            extensions[#extensions + 1] = string.sub(name, 2)
            ::continue::
        end
    end
    local supportedExtensions = tsoptions.GetSupportedExtensions(options, extraExtensions)
    for _, ext in ipairs(supportedExtensions or {}) do
        for _, e in ipairs(ext) do
            extensions[#extensions + 1] = e
        end
    end
    local moduleResolution = options:GetModuleResolutionKind()
    if ls.moduleResolutionUsesNodeModules(moduleResolution) then
        return core.Flatten(tsoptions.GetSupportedExtensionsWithJsonIfResolveJsonModule(options, { extensions }))
    end
    return extensions
end

function ls.moduleResolutionUsesNodeModules(moduleResolution)
    return moduleResolution >= core.ModuleResolutionKind.Node16 and moduleResolution <= core.ModuleResolutionKind.NodeNext or
        moduleResolution == core.ModuleResolutionKind.Bundler
end

-- Returns true if the path is explicitly relative (i.e. relative to . or ..)
function ls.isPathRelativeToScript(path)
    return hasPrefix(path, "./") or hasPrefix(path, "../")
end

function LanguageService:getCompletionEntriesForRelativeModules(literalValue, scriptDirectory, program, scriptPath, extensionOptions)
    local options = program:Options()
    if core.Len(options.rootDirs) > 0 then
        return self:getCompletionEntriesForDirectoryFragmentWithRootDirs(
            options.rootDirs,
            literalValue,
            scriptDirectory,
            program,
            scriptPath,
            extensionOptions
        )
    else
        local result = self:getCompletionEntriesForDirectoryFragment(
            literalValue,
            scriptDirectory,
            extensionOptions,
            program,
            true, --[[moduleSpecifierIsRelative]]
            scriptPath,
            ls.newModuleCompletionNameAndKindSet()
        )
        return result:values()
    end
end

function LanguageService:getCompletionEntriesForDirectoryFragmentWithRootDirs(rootDirs, fragment, scriptDirectory, program, exclude, extensionOptions)
    local options = program:Options()
    local basePath
    if options.project ~= "" then
        basePath = options.project
    else
        basePath = program:GetCurrentDirectory()
    end
    local ignoreCase = not program:UseCaseSensitiveFileNames()
    local baseDirectories = ls.getBaseDirectoriesFromRootDirs(rootDirs, basePath, scriptDirectory, ignoreCase)

    local allCompletions
    for _, baseDirectory in ipairs(baseDirectories or {}) do
        local result = self:getCompletionEntriesForDirectoryFragment(
            fragment,
            baseDirectory,
            extensionOptions,
            program,
            true, --[[moduleSpecifierIsRelative]]
            exclude,
            ls.newModuleCompletionNameAndKindSet()
        )
        for _, entry in ipairs(result:values()) do
            allCompletions = core.Append(allCompletions, entry)
        end
    end

    -- Deduplicate based on name, kind, and extension
    return ls.deduplicateModuleCompletions(allCompletions)
end

-- getBaseDirectoriesFromRootDirs takes a script path and returns paths for all potential folders
-- that could be merged with its containing folder via the "rootDirs" compiler option.
function ls.getBaseDirectoriesFromRootDirs(rootDirs, basePath, scriptDirectory, ignoreCase)
    -- Make all paths absolute/normalized if they are not already
    local normalizedRootDirs = {}
    for i, rootDirectory in ipairs(rootDirs) do
        local normalizedPath
        if tspath.IsRootedDiskPath(rootDirectory) then
            normalizedPath = rootDirectory
        else
            normalizedPath = tspath.CombinePaths(basePath, rootDirectory)
        end
        normalizedRootDirs[i] = tspath.EnsureTrailingDirectorySeparator(tspath.NormalizePath(normalizedPath))
    end

    -- Determine the path to the directory containing the script relative to the root directory it is contained within
    local relativeDirectory = ""
    local comparePathsOptions = tspath.NewComparePathsOptions(not ignoreCase, basePath)
    for _, rootDirectory in ipairs(normalizedRootDirs) do
        if tspath.ContainsPath(rootDirectory, scriptDirectory, comparePathsOptions) then
            if #rootDirectory > #scriptDirectory then
                relativeDirectory = ""
            else
                relativeDirectory = string.sub(scriptDirectory, #rootDirectory + 1)
            end
            break
        end
    end

    -- Now find a path for each potential directory that is to be merged with the one containing the script
    local directories = {}
    for _, rootDirectory in ipairs(normalizedRootDirs) do
        directories[#directories + 1] = tspath.RemoveTrailingDirectorySeparator(tspath.CombinePaths(rootDirectory, relativeDirectory))
    end
    directories[#directories + 1] = tspath.RemoveTrailingDirectorySeparator(scriptDirectory)

    return ls.deduplicateStrings(directories)
end

function ls.deduplicateStrings(slice)
    if core.Len(slice) <= 1 then
        return slice
    end
    local seen = {}
    local result
    for _, s in ipairs(slice) do
        if not seen[s] then
            seen[s] = true
            result = core.Append(result, s)
        end
    end
    return result
end

function ls.deduplicateModuleCompletions(completions)
    if core.Len(completions) <= 1 then
        return completions
    end
    local seen = {}
    local result
    for _, c in ipairs(completions) do
        local k = c.name .. "\0" .. tostring(c.kind) .. "\0" .. c.extension
        if not seen[k] then
            seen[k] = true
            result = core.Append(result, c)
        end
    end
    return result
end

-- moduleCompletionNameAndKindSet: Go `{ names map[string]moduleCompletionNameAndKind }`. Go iterates
-- the map in random order (`slices.Collect(maps.Values(result.names))`); the Lua port keeps the keys
-- in first-insertion order so the result is deterministic.
local moduleCompletionNameAndKindSet = {}
moduleCompletionNameAndKindSet.__index = moduleCompletionNameAndKindSet
ls.moduleCompletionNameAndKindSet = moduleCompletionNameAndKindSet

function ls.newModuleCompletionNameAndKindSet()
    return setmetatable({ names = {}, keys = {} }, moduleCompletionNameAndKindSet)
end

function moduleCompletionNameAndKindSet:add(entry)
    local existing = self.names[entry.name]
    if existing == nil or existing.kind < entry.kind then
        if existing == nil then
            self.keys[#self.keys + 1] = entry.name
        end
        self.names[entry.name] = entry
    end
end

-- slices.Collect(maps.Values(s.names))
function moduleCompletionNameAndKindSet:values()
    local result = {}
    for i, key in ipairs(self.keys) do
        result[i] = self.names[key]
    end
    return result
end

-- Given a path ending at a directory, gets the completions for the path.
function LanguageService:getCompletionEntriesForDirectoryFragment(fragment, scriptDirectory, extensionOptions, program, moduleSpecifierIsRelative, exclude, result)
    fragment = tspath.NormalizeSlashes(fragment)

    -- Remove the basename from the path.
    -- We don't use the basename to filter completions: the client is responsible for that filtering.
    if not tspath.HasTrailingDirectorySeparator(fragment) then
        fragment = tspath.GetDirectoryPath(fragment)
    end

    if fragment == "" then
        fragment = "."
    end

    fragment = tspath.EnsureTrailingDirectorySeparator(fragment)

    local baseDirectory = tspath.ResolvePath(scriptDirectory, fragment)
    if not moduleSpecifierIsRelative then
        -- Check for a version redirect.
        local packageJsonDirectory = program:GetNearestAncestorDirectoryWithPackageJson(baseDirectory)
        if packageJsonDirectory ~= "" then
            local packageJsonPath = tspath.CombinePaths(packageJsonDirectory, "package.json")
            local packageJsonInfo = program:GetPackageJsonInfo(packageJsonPath)
            if packageJsonInfo ~= nil and packageJsonInfo.contents ~= nil and
                packageJsonInfo.contents.typesVersions.type == JSONValueType.Object then
                local versionPaths = packageJsonInfo.contents:GetVersionPaths(nil)
                local paths = versionPaths:GetPaths()
                if collections.OrderedMap.Size(paths) > 0 then
                    local pathInPackage = string.sub(baseDirectory, #tspath.EnsureTrailingDirectorySeparator(packageJsonDirectory) + 1)
                    if self:addCompletionEntriesFromPaths(result, program, pathInPackage, packageJsonDirectory, extensionOptions, paths) then
                        -- One of the `versionPaths` was matched, which will block relative resolution
                        -- to files and folders from here.
                        -- All reachable paths given the pattern match are already added.
                        return result
                    end
                end
            end
        end
    end

    if not self.host:DirectoryExists(baseDirectory) then
        return result
    end

    -- Enumerate all available files.
    local files = self:ReadDirectory(
        baseDirectory,
        extensionOptions.extensionsToSearch,
        { "./*" } --[[include]]
    )

    for _, filePath in ipairs(files or {}) do
        if tspath.ComparePaths(exclude, filePath, tspath.NewComparePathsOptions(program:UseCaseSensitiveFileNames(), program:GetCurrentDirectory())) == 0 then
            goto continue -- Avoid self-imports
        end

        do
            local name, extension = ls.getFilenameWithExtensionOption(
                tspath.GetBaseFileName(filePath),
                program,
                extensionOptions,
                false --[[isExportsOrImportsWildcard]]
            )
            result:add(newModuleCompletionNameAndKind(name, moduleCompletionKind.File, extension))
        end
        ::continue::
    end

    -- Get folder completion as well.
    local directories = self:GetDirectories(baseDirectory)

    for _, directory in ipairs(directories or {}) do
        local directoryName = tspath.GetBaseFileName(directory)
        if directoryName ~= "@types" then
            result:add(newModuleCompletionNameAndKind(directoryName, moduleCompletionKind.Directory, ""))
        end
    end

    return result
end

-- Returns true if `fragment` was a match for any `paths`
-- (which should indicate whether any other path completions should be offered).
function LanguageService:addCompletionEntriesFromPaths(result, program, fragment, baseDirectory, extensionOptions, paths)
    local function getPatternsForKeys(key)
        return paths:GetOrZero(key)
    end
    local function comparePaths(a, b)
        local patternA = core.TryParsePattern(a)
        local patternB = core.TryParsePattern(b)
        local lengthA = #a
        if patternA.starIndex ~= -1 then
            lengthA = patternA.starIndex
        end
        local lengthB = #b
        if patternB.starIndex ~= -1 then
            lengthB = patternB.starIndex
        end
        -- cmp.Compare(lengthB, lengthA)
        if lengthB < lengthA then
            return -1
        elseif lengthB > lengthA then
            return 1
        end
        return 0
    end
    return self:addCompletionEntriesFromPathsOrExportsOrImports(
        result,
        program,
        false, --[[isExports]]
        false, --[[isImports]]
        fragment,
        baseDirectory,
        extensionOptions,
        paths:Keys(),
        getPatternsForKeys,
        comparePaths
    )
end

-- Returns true if `fragment` was a match for any `paths`
-- (which should indicate whether any other path completions should be offered).
-- keys is a Lua iterator (Go iter.Seq[string]).
function LanguageService:addCompletionEntriesFromPathsOrExportsOrImports(result, program, isExports, isImports, fragment, baseDirectory, extensionOptions, keys, getPatternsForKey, comparePaths)
    -- pathResult: { results = []moduleCompletionNameAndKind, matched = bool }
    local pathResults = {}
    local matchedPath -- *string
    for key in keys do
        if key == "." then
            goto continue
        end
        do
            local normalizedKey = trimPrefix(key, "./") -- Remove leading "./"
            if (isExports or isImports) and hasSuffix(key, "/") then -- Normalize trailing "/" to "/*"
                normalizedKey = normalizedKey .. "*"
            end
            local patterns = getPatternsForKey(key)
            if core.Len(patterns) > 0 then
                local pathPattern = core.TryParsePattern(normalizedKey)
                if not pathPattern:IsValid() then
                    goto continue
                end
                local isMatch = pathPattern:Matches(fragment)
                local isLongestMatch = false
                if isMatch then
                    if matchedPath == nil then
                        isLongestMatch = true
                    else
                        isLongestMatch = comparePaths(normalizedKey, matchedPath) == stringutil.ComparisonLessThan
                    end
                end
                if isLongestMatch then
                    -- If this is a higher priority match than anything we've seen so far, previous results from matches are invalid, e.g.
                    -- for `import {} from "some-package/|"` with a typesVersions:
                    -- {
                    --   "bar/*": ["bar/*"], // <-- 1. We add 'bar', but 'bar/*' doesn't match yet.
                    --   "*": ["dist/*"],    // <-- 2. We match here and add files from dist. 'bar' is still ok because it didn't come from a match.
                    --   "foo/*": ["foo/*"]  // <-- 3. We matched '*' earlier and added results from dist, but if 'foo/*' also matched,
                    -- }                               results in dist would not be visible. 'bar' still stands because it didn't come from a match.
                    --                                 This is especially important if `dist/foo` is a folder, because if we fail to clear results
                    --                                 added by the '*' match, after typing `"some-package/foo/|"` we would get file results from both
                    --                                 ./dist/foo and ./foo, when only the latter will actually be resolvable.
                    --                                 See pathCompletionsTypesVersionsWildcard6.ts.
                    matchedPath = normalizedKey
                    pathResults = core.Filter(pathResults, function(pr)
                        return not pr.matched
                    end)
                end
                if pathPattern.starIndex == -1 or
                    matchedPath == nil or
                    comparePaths(normalizedKey, matchedPath) ~= stringutil.ComparisonGreaterThan then
                    pathResults[#pathResults + 1] = {
                        matched = isMatch,
                        results = self:getCompletionsForPathMapping(
                            normalizedKey,
                            patterns,
                            fragment,
                            baseDirectory,
                            isExports,
                            isImports,
                            extensionOptions,
                            program
                        ),
                    }
                end
            end
        end
        ::continue::
    end

    for _, pr in ipairs(pathResults) do
        for _, res in ipairs(pr.results or {}) do
            result:add(res)
        end
    end

    return matchedPath ~= nil
end

function LanguageService:getCompletionsForPathMapping(path, patterns, fragment, packageDirectory, isExports, isImports, extensionOptions, program)
    local fragmentDirectory = ls.getFragmentDirectory(fragment)
    if fragmentDirectory ~= "" then
        fragmentDirectory = tspath.EnsureTrailingDirectorySeparator(fragmentDirectory)
    end
    local function justPathMappingName(name, kind, extension)
        if hasPrefix(name, fragment) then
            name = tspath.RemoveTrailingDirectorySeparator(name)
            if fragmentDirectory ~= "" then
                name = trimPrefix(name, fragmentDirectory)
            end
            return { newModuleCompletionNameAndKind(name, kind, extension) }
        end
        return nil
    end

    local parsedPath = core.TryParsePattern(path)
    if not parsedPath:IsValid() then
        return nil
    end
    -- No stars in the pattern.
    if parsedPath.starIndex == -1 then
        -- For a path mapping "foo": ["/x/y/z.ts"], add "foo" itself as a completion.
        local pattern = (patterns or {})[1] or ""
        local extension = ls.getFileExtension(pattern)
        return justPathMappingName(path, moduleCompletionKind.File, extension)
    end

    local pathPrefix = string.sub(parsedPath.text, 1, parsedPath.starIndex)
    local pathSuffix = string.sub(parsedPath.text, parsedPath.starIndex + 2)
    if not hasPrefix(fragment, pathPrefix) then
        -- Fragment doesn't match the path mapping prefix at all:
        -- we cannot extend it via this path.
        if not hasPrefix(pathPrefix, fragment) then
            return nil
        end
        local starIsFullPathComponent = hasSuffix(path, "/*")
        if starIsFullPathComponent then
            return justPathMappingName(pathPrefix, moduleCompletionKind.Directory, "" --[[extension]])
        end
        -- If path is e.g. `foo/bar/*`, and fragment is `foo/b`, then remaining directory prefix is `bar/`,
        local remainingDirectoryPrefix = string.sub(pathPrefix, #fragmentDirectory + 1)
        local completions
        for _, pattern in ipairs(patterns) do
            local modules = self:getModulesForPathsPattern(
                "", --[[fragment]]
                packageDirectory,
                pattern,
                isExports,
                isImports,
                extensionOptions,
                program
            )
            for _, m in ipairs(modules or {}) do
                completions = core.Append(completions, newModuleCompletionNameAndKind(
                    remainingDirectoryPrefix .. m.name .. core.IfElse(m.kind == moduleCompletionKind.File, pathSuffix, ""),
                    m.kind,
                    m.extension
                ))
            end
        end
        return completions
    end
    local remainingFragment = string.sub(fragment, #pathPrefix + 1)
    local remainingDirectoryFragment = ""
    if not hasPrefix(fragmentDirectory, pathPrefix) then
        remainingDirectoryFragment = string.sub(pathPrefix, #fragmentDirectory + 1)
    end
    return core.FlatMap(
        patterns,
        function(pattern)
            local modules = self:getModulesForPathsPattern(
                remainingFragment,
                packageDirectory,
                pattern,
                isExports,
                isImports,
                extensionOptions,
                program
            )
            local renamed = {}
            for i, m in ipairs(modules or {}) do
                renamed[i] = newModuleCompletionNameAndKind(
                    remainingDirectoryFragment .. m.name .. core.IfElse(m.kind == moduleCompletionKind.File, pathSuffix, ""),
                    m.kind,
                    m.extension
                )
            end
            return renamed
        end
    )
end

function ls.getFileExtension(fileName)
    local extension = tspath.TryGetExtensionFromPath(fileName)
    if extension == "" then
        extension = tspath.GetAnyExtensionFromPath(fileName, nil --[[extensions]], false --[[ignoreCase]])
    end
    return extension
end

-- The input fragment is relative to the path pattern's prefix:
-- e.g. if path = "bar/_*/baz", and fragment = "bar/_dir", then fragment is "dir".
-- The names are relative to the path pattern's prefix and fragment directory :
-- e.g. if path = "bar/_*/baz", and fragment = "bar/_dir/a", and we find result "abd",
-- the result should be interpreted as "bar/_dir/abd".
function LanguageService:getModulesForPathsPattern(fragment, packageDirectory, pattern, isExports, isImports, extensionOptions, program)
    local parsed = core.TryParsePattern(pattern)
    if not parsed:IsValid() or parsed.starIndex == -1 then
        return nil
    end

    local prefix = string.sub(parsed.text, 1, parsed.starIndex)
    local suffix = string.sub(parsed.text, parsed.starIndex + 2)

    -- The prefix has two effective parts: the directory path and the base component after the filepath that is not a
    -- full directory component. For example: directory/path/of/prefix/base*
    local normalizedPrefix = tspath.ResolvePath(prefix)
    local normalizedPrefixDirectory
    local normalizedPrefixBase
    if tspath.HasTrailingDirectorySeparator(prefix) then
        normalizedPrefixDirectory = normalizedPrefix
        normalizedPrefixBase = ""
    else
        normalizedPrefixDirectory = tspath.GetDirectoryPath(normalizedPrefix)
        normalizedPrefixBase = tspath.GetBaseFileName(normalizedPrefix)
    end

    local fragmentHasPath = ls.containsSlash(fragment)
    local fragmentDirectory = ""
    if fragmentHasPath then
        if tspath.HasTrailingDirectorySeparator(fragment) then
            fragmentDirectory = fragment
        else
            fragmentDirectory = tspath.GetDirectoryPath(fragment)
        end
    end

    local options = program:Options()
    local ignoreCase = not program:UseCaseSensitiveFileNames()
    local outDir = options.outDir
    local declarationDir = options.declarationDir

    -- Try and expand the prefix to include any path from the fragment so that we can limit the readDirectory call
    local expandedPrefixDirectory
    if fragmentHasPath then
        expandedPrefixDirectory = tspath.CombinePaths(normalizedPrefixDirectory, normalizedPrefixBase .. fragmentDirectory)
    else
        expandedPrefixDirectory = normalizedPrefixDirectory
    end
    -- Need to normalize after combining: If we combinePaths("a", "../b"), we want "b" and not "a/../b".
    local baseDirectory = tspath.NormalizePath(tspath.CombinePaths(packageDirectory, expandedPrefixDirectory))

    local possibleInputBaseDirectoryForOutDir = ""
    local possibleInputBaseDirectoryForDeclarationDir = ""
    local function getCommonSourceDirectory()
        return program:CommonSourceDirectory()
    end
    if isImports then
        if outDir ~= "" then
            possibleInputBaseDirectoryForOutDir = ls.getPossibleOriginalInputPathWithoutChangingExt(
                baseDirectory,
                ignoreCase,
                outDir,
                getCommonSourceDirectory
            )
        end
        if declarationDir ~= "" then
            possibleInputBaseDirectoryForDeclarationDir = ls.getPossibleOriginalInputPathWithoutChangingExt(
                baseDirectory,
                ignoreCase,
                declarationDir,
                getCommonSourceDirectory
            )
        end
    end

    local normalizedSuffix = tspath.NormalizePath(suffix)

    local declarationExtension = ""
    local inputExtensions
    if normalizedSuffix ~= "" then
        declarationExtension = tspath.GetDeclarationEmitExtensionForPath("_" .. normalizedSuffix)
        inputExtensions = tspath.GetPossibleOriginalInputExtensionForExtension("_" .. normalizedSuffix)
    end

    local matchingSuffixes = {}
    if declarationExtension ~= "" then
        matchingSuffixes[#matchingSuffixes + 1] = tspath.ChangeExtension(normalizedSuffix, declarationExtension)
    end
    for _, ext in ipairs(inputExtensions or {}) do
        matchingSuffixes[#matchingSuffixes + 1] = tspath.ChangeExtension(normalizedSuffix, ext)
    end
    matchingSuffixes[#matchingSuffixes + 1] = normalizedSuffix

    -- If we have a suffix, then we read the directory all the way down to avoid returning completions for
    -- directories that don't contain files that would match the suffix. A previous comment here was concerned
    -- about the case where `normalizedSuffix` includes a `?` character, which should be interpreted literally,
    -- but will match any single character as part of the `include` pattern in `tryReadDirectory`. This is not
    -- a problem, because (in the extremely unusual circumstance where the suffix has a `?` in it) a `?`
    -- interpreted as "any character" can only return *too many* results as compared to the literal
    -- interpretation, so we can filter those superfluous results out via `trimPrefixAndSuffix` as we've always
    -- done.
    local includeGlobs
    if normalizedSuffix ~= "" then
        includeGlobs = {}
        for _, s in ipairs(matchingSuffixes) do
            includeGlobs[#includeGlobs + 1] = "**/*" .. s
        end
    else
        includeGlobs = { "./*" }
    end

    local isExportsOrImportsWildcard = (isExports or isImports) and hasSuffix(pattern, "/*")

    local function trimPrefixAndSuffix(path, prefixStr)
        for _, s in ipairs(matchingSuffixes) do
            local inner = ls.withoutStartAndEnd(tspath.NormalizePath(path), prefixStr, s)
            if inner ~= nil then
                return ls.removeLeadingDirectorySeparator(inner)
            end
        end
        return ""
    end

    local function getMatchesWithPrefix(directory)
        local completePrefix
        if fragmentHasPath then
            completePrefix = directory
        else
            completePrefix = tspath.EnsureTrailingDirectorySeparator(directory) .. normalizedPrefixBase
        end

        local matches = self:ReadDirectory(
            directory,
            extensionOptions.extensionsToSearch,
            includeGlobs
        )

        local result
        for _, match in ipairs(matches or {}) do
            local trimmedWithPattern = trimPrefixAndSuffix(match, completePrefix)
            if trimmedWithPattern ~= "" then
                if ls.containsSlash(trimmedWithPattern) then
                    local pathComponents = tspath.GetPathComponents(ls.removeLeadingDirectorySeparator(trimmedWithPattern), "")
                    if #pathComponents > 1 then
                        result = core.Append(result, newModuleCompletionNameAndKind(pathComponents[2], moduleCompletionKind.Directory, ""))
                    end
                else
                    local name, extension = ls.getFilenameWithExtensionOption(
                        trimmedWithPattern,
                        program,
                        extensionOptions,
                        isExportsOrImportsWildcard
                    )
                    if extension == "" then
                        extension = ls.getFileExtension(match)
                    end
                    result = core.Append(result, newModuleCompletionNameAndKind(name, moduleCompletionKind.File, extension))
                end
            end
        end
        return result
    end

    local function getDirectoryMatches(directoryName)
        local directories = self:GetDirectories(directoryName)
        local result
        for _, dir in ipairs(directories or {}) do
            if dir ~= "node_modules" then
                result = core.Append(result, newModuleCompletionNameAndKind(dir, moduleCompletionKind.Directory, ""))
            end
        end
        return result
    end

    local matches = core.AppendAll(nil, getMatchesWithPrefix(baseDirectory))

    if possibleInputBaseDirectoryForOutDir ~= "" then
        matches = core.AppendAll(matches, getMatchesWithPrefix(possibleInputBaseDirectoryForOutDir))
    end
    if possibleInputBaseDirectoryForDeclarationDir ~= "" then
        matches = core.AppendAll(matches, getMatchesWithPrefix(possibleInputBaseDirectoryForDeclarationDir))
    end

    -- If we had a suffix, we already recursively searched for all possible files that could match
    -- it and returned the directories leading to those files. Otherwise, assume any directory could
    -- have something valid to import.
    if normalizedSuffix == "" then
        matches = core.AppendAll(matches, getDirectoryMatches(baseDirectory))
        if possibleInputBaseDirectoryForOutDir ~= "" then
            matches = core.AppendAll(matches, getDirectoryMatches(possibleInputBaseDirectoryForOutDir))
        end
        if possibleInputBaseDirectoryForDeclarationDir ~= "" then
            matches = core.AppendAll(matches, getDirectoryMatches(possibleInputBaseDirectoryForDeclarationDir))
        end
    end

    return matches
end

function ls.containsSlash(fragment)
    return containsString(fragment, string.char(tspath.DirectorySeparator))
end

-- Returns a string or nil (Go *string).
function ls.withoutStartAndEnd(s, start, end_)
    if hasPrefix(s, start) and hasSuffix(s, end_) and #s >= #start + #end_ then
        return string.sub(s, #start + 1, #s - #end_)
    end
    return nil
end

function ls.removeLeadingDirectorySeparator(path)
    return trimPrefix(path, string.char(tspath.DirectorySeparator))
end

function ls.getPossibleOriginalInputPathWithoutChangingExt(filePath, ignoreCase, outputDir, getCommonSourceDirectory)
    if outputDir ~= "" then
        return tspath.ResolvePath(
            getCommonSourceDirectory(),
            tspath.GetRelativePathFromDirectory(outputDir, filePath, tspath.NewComparePathsOptions(not ignoreCase, ""))
        )
    end
    return filePath
end

-- Returns (name, extension).
function ls.getFilenameWithExtensionOption(name, program, extensionOptions, isExportsOrImportsWildcard)
    local nonJSResult = modulespecifiers.TryGetRealFileNameForNonJSDeclarationFileName(name)
    if nonJSResult ~= "" then
        return nonJSResult, tspath.TryGetExtensionFromPath(nonJSResult)
    end
    if extensionOptions.referenceKind == referenceKind.FileName then
        return name, tspath.TryGetExtensionFromPath(name)
    end

    local allowedEndings = modulespecifiers.GetAllowedEndingsInPreferredOrder(
        modulespecifiers.UserPreferences_new({ importModuleSpecifierEnding = extensionOptions.endingPreference }),
        program,
        program:Options(),
        extensionOptions.importingSourceFile,
        "", --[[oldImportSpecifier]]
        extensionOptions.resolutionMode
    )

    local ModuleSpecifierEnding = modulespecifiers.ModuleSpecifierEnding
    if isExportsOrImportsWildcard then
        -- If we're completing `import {} from "foo/|"` and subpaths are available via `"exports": { "./*": "./src/*" }`,
        -- the completion must be a (potentially extension-swapped) file name. Dropping extensions and index files is not allowed.
        allowedEndings = core.Filter(allowedEndings, function(e)
            return e ~= ModuleSpecifierEnding.Minimal and e ~= ModuleSpecifierEnding.Index
        end)
    end

    if core.Len(allowedEndings) > 0 and allowedEndings[1] == ModuleSpecifierEnding.TsExtension then
        if tspath.FileExtensionIsOneOf(name, tspath.SupportedTSImplementationExtensions) then
            return name, tspath.TryGetExtensionFromPath(name)
        end
        local outputExtension = module.TryGetJSExtensionForFile(name, program:Options())
        if outputExtension ~= "" then
            return tspath.ChangeExtension(name, outputExtension), outputExtension
        end
        return name, tspath.TryGetExtensionFromPath(name)
    end

    if not isExportsOrImportsWildcard and
        core.Len(allowedEndings) > 0 and
        (allowedEndings[1] == ModuleSpecifierEnding.Minimal or allowedEndings[1] == ModuleSpecifierEnding.Index) and
        tspath.FileExtensionIsOneOf(name, { tspath.ExtensionJs, tspath.ExtensionJsx, tspath.ExtensionTs, tspath.ExtensionTsx, tspath.ExtensionDts }) then
        return tspath.RemoveFileExtension(name), tspath.TryGetExtensionFromPath(name)
    end

    local outputExtension = module.TryGetJSExtensionForFile(name, program:Options())
    if outputExtension ~= "" then
        return tspath.ChangeExtension(name, outputExtension), outputExtension
    end
    return name, tspath.TryGetExtensionFromPath(name)
end

function ls.walkUpParentheses(node)
    if node.kind == Kind.ParenthesizedType then
        return ast.WalkUpParenthesizedTypes(node)
    elseif node.kind == Kind.ParenthesizedExpression then
        return ast.WalkUpParenthesizedExpressions(node)
    else
        return node
    end
end

-- uniques is a collections.Set or nil.
function ls.getStringLiteralTypes(t, uniques, typeChecker)
    if t == nil then
        return nil
    end
    if uniques == nil then
        uniques = collections.NewSet()
    end
    t = ls.skipConstraint(t, typeChecker)
    if t:IsUnion() then
        local types
        for _, elementType in ipairs(t:Types()) do
            types = core.AppendAll(types, ls.getStringLiteralTypes(elementType, uniques, typeChecker))
        end
        return types
    end
    if t:IsStringLiteral() and not t:IsEnumLiteral() and uniques:AddIfAbsent(t:AsLiteralType():Value()) then
        return { t }
    end
    return nil
end

function ls.getAlreadyUsedTypesInStringLiteralUnion(union, current)
    local typesList = union:AsUnionTypeNode().types
    if typesList == nil then
        return nil
    end
    local values
    for _, typeNode in ipairs(typesList.nodes) do
        if typeNode ~= current and ast.IsLiteralTypeNode(typeNode) and
            ast.IsStringLiteral(typeNode:AsLiteralTypeNode().literal) then
            values = core.Append(values, typeNode:AsLiteralTypeNode().literal:Text())
        end
    end
    return values
end

function ls.hasIndexSignature(t, typeChecker)
    return typeChecker:GetStringIndexType(t) ~= nil or typeChecker:GetNumberIndexType(t) ~= nil
end

-- Matches
--
--	require(""
--	require("")
function ls.isRequireCallArgument(node)
    return ast.IsCallExpression(node.parent) and core.Len(node.parent:Arguments()) > 0 and node.parent:Arguments()[1] == node and
        ast.IsIdentifier(node.parent:Expression()) and node.parent:Expression():Text() == "require"
end

function ls.kindModifiersFromExtension(extension)
    if extension == tspath.ExtensionDts then
        return ScriptElementKindModifier.Dts
    elseif extension == tspath.ExtensionJs then
        return ScriptElementKindModifier.Js
    elseif extension == tspath.ExtensionJson then
        return ScriptElementKindModifier.Json
    elseif extension == tspath.ExtensionJsx then
        return ScriptElementKindModifier.Jsx
    elseif extension == tspath.ExtensionTs then
        return ScriptElementKindModifier.Ts
    elseif extension == tspath.ExtensionTsx then
        return ScriptElementKindModifier.Tsx
    elseif extension == tspath.ExtensionDmts then
        return ScriptElementKindModifier.Dmts
    elseif extension == tspath.ExtensionMjs then
        return ScriptElementKindModifier.Mjs
    elseif extension == tspath.ExtensionMts then
        return ScriptElementKindModifier.Mts
    elseif extension == tspath.ExtensionDcts then
        return ScriptElementKindModifier.Dcts
    elseif extension == tspath.ExtensionCjs then
        return ScriptElementKindModifier.Cjs
    elseif extension == tspath.ExtensionCts then
        return ScriptElementKindModifier.Cts
    elseif extension == tspath.ExtensionTsBuildInfo then
        error(string.format("Extension %s is unsupported.", tspath.ExtensionTsBuildInfo), 0)
    else
        return ScriptElementKindModifier.None
    end
end

function ls.getStringLiteralCompletionsFromSignature(call, arg, argumentInfo, typeChecker)
    local isNewIdentifier = false
    local uniques = collections.NewSet()
    local editingArgument
    if ast.IsJsxOpeningLikeElement(call) then
        editingArgument = ast.FindAncestor(arg.parent, ast.IsJsxAttribute)
        if editingArgument == nil then
            error("Expected jsx opening-like element to have a jsx attribute as ancestor.", 0)
        end
    else
        editingArgument = arg
    end
    local candidates = typeChecker:GetCandidateSignaturesForStringLiteralCompletions(call, editingArgument)
    local types
    for _, candidate in ipairs(candidates or {}) do
        if not candidate:HasRestParameter() and argumentInfo.argumentCount > core.Len(candidate:Parameters()) then
            goto continue
        end
        do
            local t = typeChecker:GetTypeParameterAtPosition(candidate, argumentInfo.argumentIndex)
            if ast.IsJsxOpeningLikeElement(call) then
                local propType = typeChecker:GetTypeOfPropertyOfType(t, editingArgument:AsJsxAttribute():Name():Text())
                if propType ~= nil then
                    t = propType
                end
            end
            isNewIdentifier = isNewIdentifier or t:IsString()
            types = core.AppendAll(types, ls.getStringLiteralTypes(t, uniques, typeChecker))
        end
        ::continue::
    end
    if core.Len(types) > 0 then
        return {
            types = types,
            isNewIdentifier = isNewIdentifier,
        }
    end
    return nil
end

function LanguageService:getStringLiteralCompletionDetails(ctx, typeChecker, item, name, file, position, contextToken, docFormat)
    if contextToken == nil or not ast.IsStringLiteralLike(contextToken) then
        return item
    end
    local completions = self:getStringLiteralCompletionEntries(
        ctx,
        file,
        contextToken,
        position,
        typeChecker
    )
    if completions == nil then
        return item
    end
    return self:stringLiteralCompletionDetails(item, name, contextToken, position, completions, file, typeChecker, docFormat)
end

function LanguageService:stringLiteralCompletionDetails(item, name, location, position, completion, file, typeChecker, docFormat)
    if completion.fromPaths ~= nil then
        -- Path completions have eagerly-resolved details so the client can show an accurate icon
        -- for items of file kind based on the file extension provided in the item detail.
        return item
    elseif completion.fromProperties ~= nil then
        local properties = completion.fromProperties
        for _, symbol in ipairs(properties.symbols or {}) do
            if symbol.name == name then
                return self:createCompletionDetailsForSymbol(item, symbol, typeChecker, location, position, docFormat)
            end
        end
    elseif completion.fromTypes ~= nil then
        local types = completion.fromTypes
        for _, t in ipairs(types.types or {}) do
            if t:AsLiteralType():Value() == name then
                return ls.createCompletionDetails(item, name, "" --[[documentation]], docFormat)
            end
        end
    end
    return item
end

function ls.isInReferenceComment(file, position)
    local commentRange = ls.isInComment(file, position, astnav.GetTokenAtPosition(file, position))
    if commentRange == nil then
        return false
    end
    local commentText = string.sub(file:Text(), commentRange:Pos() + 1, commentRange:End())
    return ls.hasTripleSlashPrefix(commentText)
end

function ls.hasTripleSlashPrefix(commentText)
    return hasPrefix(commentText, "///") and hasPrefix(trimSpace(string.sub(commentText, 4)), "<")
end

-- Matches a triple slash reference directive with an incomplete string literal for its path.
-- Used to determine if the caret is currently within the string literal and capture the literal
-- fragment for completions.
-- For example, this matches
--
-- /// <reference path="fragment
--
-- but not
--
-- /// <reference path="fragment"

-- Returns (prefix, kind, toComplete, ok) where:
--   - prefix is everything up to and including the opening quote
--   - kind is either "path" or "types"
--   - toComplete is the fragment after the opening quote
--   - ok indicates whether the match was successful
function ls.parseTripleSlashDirectiveFragment(text)
    local rest = text
    if not hasPrefix(rest, "///") then
        return "", "", "", false
    end

    rest = string.sub(rest, #"///" + 1)
    rest = trimLeftFunc(rest, stringutil.IsWhiteSpaceLike)

    -- <reference
    if not hasPrefix(rest, "<reference") then
        return "", "", "", false
    end
    rest = string.sub(rest, #"<reference" + 1)

    if #rest == 0 or not stringutil.IsWhiteSpaceLike(string.byte(rest, 1)) then
        return "", "", "", false
    end
    rest = trimLeftFunc(rest, stringutil.IsWhiteSpaceLike)

    -- path or types
    local kind
    if hasPrefix(rest, "path") then
        kind = "path"
        rest = string.sub(rest, #"path" + 1)
    elseif hasPrefix(rest, "types") then
        kind = "types"
        rest = string.sub(rest, #"types" + 1)
    else
        return "", "", "", false
    end

    -- Skip optional whitespace, then must have "="
    rest = trimLeftFunc(rest, stringutil.IsWhiteSpaceLike)
    if not hasPrefix(rest, "=") then
        return "", "", "", false
    end
    rest = string.sub(rest, 2)

    -- Skip optional whitespace, then must have opening quote (' or ")
    rest = trimLeftFunc(rest, stringutil.IsWhiteSpaceLike)
    local c = string.byte(rest, 1)
    if #rest == 0 or (c ~= 0x27 --[[ '\'' ]] and c ~= 0x22 --[[ '"' ]]) then
        return "", "", "", false
    end
    rest = string.sub(rest, 2)

    -- The toComplete part is everything after the opening quote
    if string.find(rest, "['\"]") ~= nil then
        return "", "", "", false
    end
    local toComplete = rest
    local prefix = string.sub(text, 1, #text - #toComplete)
    return prefix, kind, toComplete, true
end

function LanguageService:getTripleSlashReferenceCompletions(file, position, program, typeChecker)
    local compilerOptions = program:Options()
    local token = astnav.GetTokenAtPosition(file, position)

    local foundRange
    for commentRange in scanner.GetLeadingCommentRanges(ast.NewNodeFactory(nil), file:Text(), token:Pos()) do
        if position >= commentRange:Pos() and position <= commentRange:End() then
            foundRange = commentRange
            break
        end
    end
    if foundRange == nil then
        return nil
    end

    local text = string.sub(file:Text(), foundRange:Pos() + 1, position)
    local prefix, kind, toComplete, ok = ls.parseTripleSlashDirectiveFragment(text)
    if not ok then
        return nil
    end
    local replacementSpan, ok2 = self:pathCompletionReplacementSpan(file, ls.getDirectoryFragmentRange(toComplete, foundRange:Pos() + #prefix))
    if not ok2 then
        return nil
    end

    local scriptPath = tspath.GetDirectoryPath(file:Path())

    local names
    if kind == "path" then
        local extensionOptions = self:getExtensionOptions(compilerOptions, referenceKind.FileName, file, core.ModuleKind.ResolutionModeNone, nil --[[checker]])
        local result = self:getCompletionEntriesForDirectoryFragment(
            toComplete,
            scriptPath,
            extensionOptions,
            program,
            true, --[[moduleSpecifierIsRelative]]
            file:Path(),
            ls.newModuleCompletionNameAndKindSet()
        )
        names = result:values()
    elseif kind == "types" then
        local extensionOptions = self:getExtensionOptions(compilerOptions, referenceKind.ModuleSpecifier, file, core.ModuleKind.ResolutionModeNone, nil --[[checker]])
        local result = ls.newModuleCompletionNameAndKindSet()
        self:getCompletionEntriesFromTypings(program, scriptPath, ls.getFragmentDirectory(toComplete), extensionOptions, result)
        names = result:values()
    end

    return {
        entries = ls.toPathCompletions(names),
        replacementSpan = replacementSpan,
    }
end
