local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local autoimport = require("tslua.ls.autoimport")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local modulespecifiers = require("tslua.modulespecifiers")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")
local tspath = require("tslua.tspath")

local SymbolFlags = ast.SymbolFlags

ls.importFixErrorCodes = {
    diagnostics.Cannot_find_name_0:Code(),
    diagnostics.Cannot_find_name_0_Did_you_mean_1:Code(),
    diagnostics.Cannot_find_name_0_Did_you_mean_the_instance_member_this_0:Code(),
    diagnostics.Cannot_find_name_0_Did_you_mean_the_static_member_1_0:Code(),
    diagnostics.Cannot_find_namespace_0:Code(),
    diagnostics.X_0_refers_to_a_UMD_global_but_the_current_file_is_a_module_Consider_adding_an_import_instead:Code(),
    diagnostics.X_0_only_refers_to_a_type_but_is_being_used_as_a_value_here:Code(),
    diagnostics.No_value_exists_in_scope_for_the_shorthand_property_0_Either_declare_one_or_provide_an_initializer:Code(),
    diagnostics.X_0_cannot_be_used_as_a_value_because_it_was_imported_using_import_type:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_jQuery_Try_npm_i_save_dev_types_Slashjquery:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_change_your_target_library_Try_changing_the_lib_compiler_option_to_1_or_later:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_change_your_target_library_Try_changing_the_lib_compiler_option_to_include_dom:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_a_test_runner_Try_npm_i_save_dev_types_Slashjest_or_npm_i_save_dev_types_Slashmocha_and_then_add_jest_or_mocha_to_the_types_field_in_your_tsconfig:Code(),
    diagnostics.Cannot_find_name_0_Did_you_mean_to_write_this_in_an_async_function:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_jQuery_Try_npm_i_save_dev_types_Slashjquery_and_then_add_jquery_to_the_types_field_in_your_tsconfig:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_a_test_runner_Try_npm_i_save_dev_types_Slashjest_or_npm_i_save_dev_types_Slashmocha:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_node_Try_npm_i_save_dev_types_Slashnode:Code(),
    diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_node_Try_npm_i_save_dev_types_Slashnode_and_then_add_node_to_the_types_field_in_your_tsconfig:Code(),
    diagnostics.Cannot_find_namespace_0_Did_you_mean_1:Code(),
    diagnostics.Cannot_extend_an_interface_0_Did_you_mean_implements:Code(),
    diagnostics.This_JSX_tag_requires_0_to_be_in_scope_but_it_could_not_be_found:Code(),
}

ls.importFixID = "fixMissingImport"

-- ImportFixProvider is the CodeFixProvider for import-related fixes
ls.ImportFixProvider = {
    errorCodes = ls.importFixErrorCodes,
    getCodeActions = function(ctx, fixContext)
        return ls.getImportCodeActions(ctx, fixContext)
    end,
    fixIds = { ls.importFixID },
    getAllCodeActions = function(ctx, fixContext)
        return ls.getAllImportCodeActions(ctx, fixContext)
    end,
}

-- fixInfo: { fix = autoimport.Fix, symbolName = string, errorIdentifierText = string, isJsxNamespaceFix = bool }
local function newFixInfo(fix, symbolName, errorIdentifierText, isJsxNamespaceFix)
    return {
        fix = fix,
        symbolName = symbolName or "",
        errorIdentifierText = errorIdentifierText or "",
        isJsxNamespaceFix = isJsxNamespaceFix or false,
    }
end

function ls.getImportCodeActions(ctx, fixContext)
    local info, err = ls.getFixInfos(ctx, fixContext, fixContext.errorCode, fixContext.span:Pos())
    if err ~= nil then
        return nil, err
    end
    if core.Len(info) == 0 then
        return nil, nil
    end

    local actions = nil
    for _, fixInfo in ipairs(info) do
        local edits, description, ok = fixInfo.fix:Edits(
            ctx,
            fixContext.sourceFile,
            fixContext.program:Options(),
            fixContext.ls:FormatOptions(),
            fixContext.ls.converters,
            fixContext.ls:UserPreferences()
        )

        if ok then
            actions = core.Append(actions, ls.NewCodeAction({
                description = description,
                changes = edits,
                fixID = ls.importFixID,
                fixAllDescription = diagnostics.Add_all_missing_imports:Localize(locale.FromContext(ctx)),
            }))
        end
    end
    return actions, nil
end

function ls.getAllImportCodeActions(ctx, fixContext)
    if tspath.IsDynamicFileName(fixContext.sourceFile:FileName()) then
        return nil, nil
    end

    local allDiagnostics = fixContext.program:GetSemanticDiagnostics(ctx, fixContext.sourceFile)

    local importDiags = nil
    for _, diag in ipairs(allDiagnostics or {}) do
        if ls.isFixableDiagnostic(diag, ls.importFixErrorCodes) then
            importDiags = core.Append(importDiags, diag)
        end
    end

    if core.Len(importDiags) == 0 then
        return nil, nil
    end

    local view, err = fixContext.ls:getPreparedAutoImportView(fixContext.sourceFile)
    if err ~= nil then
        return nil, err
    end
    if view == nil then
        view = fixContext.ls:getCurrentAutoImportView(fixContext.sourceFile)
    end

    local ch, done = fixContext.program:GetTypeChecker(ctx)

    local importAdder = autoimport.NewImportAdder(
        ctx,
        fixContext.program,
        ch,
        fixContext.sourceFile,
        view,
        fixContext.ls:FormatOptions(),
        fixContext.ls.converters,
        fixContext.ls:UserPreferences()
    )

    for _, diag in ipairs(importDiags) do
        local addErr = ls.addImportFromDiagnostic(ctx, importAdder, diag, fixContext)
        if addErr ~= nil then
            done()
            return nil, addErr
        end
    end

    if not importAdder:HasFixes() then
        done()
        return nil, nil
    end

    local result = {
        description = diagnostics.Add_all_missing_imports:Localize(locale.FromContext(ctx)),
        changes = importAdder:Edits(),
    }
    done()
    return result, nil
end

-- addImportFromDiagnostic finds the best import fix for a diagnostic and adds it to the adder.
function ls.addImportFromDiagnostic(ctx, importAdder, diag, fixContext)
    local diagFixContext = {
        sourceFile = fixContext.sourceFile,
        span = core.NewTextRange(diag:Pos(), diag:End()),
        errorCode = diag:Code(),
        program = fixContext.program,
        ls = fixContext.ls,
    }

    local infos, err = ls.getFixInfos(ctx, diagFixContext, diag:Code(), diag:Pos())
    if err ~= nil then
        return err
    end
    if core.Len(infos) > 0 then
        importAdder:AddImportFix(infos[1].fix)
    end
    return nil
end

function ls.getFixInfos(ctx, fixContext, errorCode, pos)
    -- Can't compute import fixes for dynamic/untitled files since they don't have real file paths
    if tspath.IsDynamicFileName(fixContext.sourceFile:FileName()) then
        return nil, nil
    end

    local symbolToken = astnav.GetTokenAtPosition(fixContext.sourceFile, pos)

    local view = nil
    local info = nil

    if errorCode == diagnostics.X_0_refers_to_a_UMD_global_but_the_current_file_is_a_module_Consider_adding_an_import_instead:Code() then
        view = fixContext.ls:getCurrentAutoImportView(fixContext.sourceFile)
        info = ls.getFixesInfoForUMDImport(ctx, fixContext, symbolToken, view)
    elseif not ast.IsIdentifier(symbolToken) then
        return nil, nil
    elseif errorCode == diagnostics.X_0_cannot_be_used_as_a_value_because_it_was_imported_using_import_type:Code() then
        local ch, done = fixContext.program:GetTypeChecker(ctx)
        local compilerOptions = fixContext.program:Options()
        local symbolNames = ls.getSymbolNamesToImport(fixContext.sourceFile, ch, symbolToken, compilerOptions)

        local allTypeOnlyFixes = nil
        for _, sn in ipairs(symbolNames) do
            if sn.isTypeOnly then
                local fix = ls.getTypeOnlyPromotionFix(ctx, fixContext.sourceFile, symbolToken, sn.name, fixContext.program)
                if fix ~= nil then
                    allTypeOnlyFixes = core.Append(allTypeOnlyFixes, newFixInfo(fix, sn.name, symbolToken:Text(), false))
                end
            end
        end

        -- For JSX opening tags, there can be separate type-only errors for both the tag name
        -- identifier and the JSX namespace identifier. When both produce valid fixes, we
        -- disambiguate using the diagnostic message, which quotes the symbol name in single
        -- quotes (e.g., "'React' cannot be used as a value..."). If filtering yields nothing
        -- (e.g., due to localization), fall back to returning all candidates.
        local diagnosticMessage = ""
        if fixContext.diagnostic ~= nil then
            diagnosticMessage = lsproto.StringOrMarkupContent.AsString(fixContext.diagnostic.message)
        end
        if core.Len(allTypeOnlyFixes) > 1 and diagnosticMessage ~= "" then
            for _, fi in ipairs(allTypeOnlyFixes) do
                if string.find(diagnosticMessage, "'" .. fi.symbolName .. "'", 1, true) ~= nil then
                    info = core.Append(info, fi)
                end
            end
        end
        if core.Len(info) == 0 then
            info = allTypeOnlyFixes
        end
        done()
        return info, nil
    else
        local err
        view, err = fixContext.ls:getPreparedAutoImportView(fixContext.sourceFile)
        if err ~= nil then
            return nil, err
        end
        if view ~= nil then
            info = ls.getFixesInfoForNonUMDImport(ctx, fixContext, symbolToken, view)
        end
    end

    -- Sort fixes by preference
    if view == nil then
        view = fixContext.ls:getCurrentAutoImportView(fixContext.sourceFile)
    end
    return ls.sortFixInfo(info, fixContext, view), nil
end

function ls.getFixesInfoForUMDImport(ctx, fixContext, token, view)
    local ch, done = fixContext.program:GetTypeChecker(ctx)

    local umdSymbol = ls.getUmdSymbol(token, ch)
    if umdSymbol == nil then
        done()
        return nil
    end

    local export = autoimport.SymbolToExport(umdSymbol, ch)
    local isValidTypeOnlyUseSite = ast.IsValidTypeOnlyAliasUseSite(token)

    local result = nil
    for _, fix in ipairs(view:GetFixes(ctx, export, false, isValidTypeOnlyUseSite, nil) or {}) do
        local errorIdentifierText = ""
        if ast.IsIdentifier(token) then
            errorIdentifierText = token:Text()
        end
        result = core.Append(result, newFixInfo(fix, umdSymbol.name, errorIdentifierText, false))
    end
    done()
    return result
end

function ls.getUmdSymbol(token, ch)
    -- try the identifier to see if it is the umd symbol
    local umdSymbol = nil
    if ast.IsIdentifier(token) then
        umdSymbol = ch:GetResolvedSymbol(token)
    end
    if ls.isUMDExportSymbol(umdSymbol) then
        return umdSymbol
    end

    -- The error wasn't for the symbolAtLocation, it was for the JSX tag itself, which needs access to e.g. `React`.
    local parent = token.parent
    if (ast.IsJsxOpeningLikeElement(parent) and parent:TagName() == token) or
        ast.IsJsxOpeningFragment(parent) then
        local location
        if ast.IsJsxOpeningLikeElement(parent) then
            location = token
        else
            location = parent
        end
        local jsxNamespace = ch:GetJsxNamespace(parent)
        local parentSymbol = ch:ResolveName(jsxNamespace, location, SymbolFlags.Value, false --[[excludeGlobals]])
        if ls.isUMDExportSymbol(parentSymbol) then
            return parentSymbol
        end
    end
    return nil
end

function ls.isUMDExportSymbol(symbol)
    return symbol ~= nil and core.Len(symbol.declarations) > 0 and
        symbol.declarations[1] ~= nil and
        ast.IsNamespaceExportDeclaration(symbol.declarations[1])
end

function ls.getFixesInfoForNonUMDImport(ctx, fixContext, symbolToken, view)
    local ch, done = fixContext.program:GetTypeChecker(ctx)
    local compilerOptions = fixContext.program:Options()

    local isValidTypeOnlyUseSite = ast.IsValidTypeOnlyAliasUseSite(symbolToken)
    local symbolNames = ls.getSymbolNamesToImport(fixContext.sourceFile, ch, symbolToken, compilerOptions)
    local allInfo = nil

    -- Compute usage position for JSDoc import type fixes
    local usagePosition, fidelity = fixContext.ls.converters:ToLSPPosition(fixContext.sourceFile, scanner.GetTokenPosOfNode(symbolToken, fixContext.sourceFile, false))
    if not spanmap.Fidelity_IsExact(fidelity) then
        done()
        return nil
    end

    for _, sn in ipairs(symbolNames) do
        -- Type-only imports are handled by the promotion code path, not the auto-import path.
        if sn.isTypeOnly then
            goto continue
        end

        do
            local symbolName = sn.name
            -- "default" is a keyword and not a legal identifier for the import
            if symbolName == "default" then
                goto continue
            end

            local isJSXTagName = symbolName == symbolToken:Text() and ast.IsJsxTagName(symbolToken)
            local queryKind = autoimport.QueryKind.ExactMatch
            if isJSXTagName then
                queryKind = autoimport.QueryKind.CaseInsensitiveMatch
            end

            local exports = view:Search(symbolName, queryKind)
            for _, export in ipairs(exports or {}) do
                if isJSXTagName and not (export:Name() == symbolName or export:IsRenameable()) then
                    goto nextExport
                end

                do
                    local fixes = view:GetFixes(ctx, export, isJSXTagName, isValidTypeOnlyUseSite, usagePosition)
                    for _, fix in ipairs(fixes or {}) do
                        allInfo = core.Append(allInfo, newFixInfo(fix, symbolName, "", symbolName ~= symbolToken:Text()))
                    end
                end

                ::nextExport::
            end
        end

        ::continue::
    end

    done()
    return allInfo
end

function ls.getTypeOnlyPromotionFix(ctx, sourceFile, symbolToken, symbolName, program)
    local ch, done = program:GetTypeChecker(ctx)

    -- Get the symbol at the token location
    local symbol = ch:ResolveName(symbolName, symbolToken, SymbolFlags.Value, true --[[excludeGlobals]])
    if symbol == nil then
        done()
        return nil
    end

    -- Get the type-only alias declaration
    local typeOnlyAliasDeclaration = ch:GetTypeOnlyAliasDeclaration(symbol)
    if typeOnlyAliasDeclaration == nil or ast.GetSourceFileOfNode(typeOnlyAliasDeclaration) ~= sourceFile then
        done()
        return nil
    end

    done()
    -- Go &autoimport.Fix{AutoImportFix: &lsproto.AutoImportFix{Kind: ...}, TypeOnlyAliasDeclaration: ...}
    return setmetatable({
        autoImportFix = {
            kind = lsproto.AutoImportFixKind.PromoteTypeOnly,
            name = "",
            importKind = 0,
            useRequire = false,
            addAsTypeOnly = 0,
            moduleSpecifier = "",
            importIndex = 0,
            usagePosition = nil,
            namespacePrefix = "",
        },
        moduleSpecifierKind = modulespecifiers.ResultKind.None,
        isReExport = false,
        moduleFileName = "",
        typeOnlyAliasDeclaration = typeOnlyAliasDeclaration,
    }, autoimport.Fix)
end

-- symbolNameInfo: { name = string, isTypeOnly = bool (whether the symbol currently resolves to a type-only import) }

function ls.getSymbolNamesToImport(sourceFile, ch, symbolToken, compilerOptions)
    local parent = symbolToken.parent
    if (ast.IsJsxOpeningLikeElement(parent) or ast.IsJsxClosingElement(parent)) and
        parent:TagName() == symbolToken and
        ls.jsxModeNeedsExplicitImport(compilerOptions.jsx) then
        local jsxNamespace = ch:GetJsxNamespace(sourceFile)
        if ls.needsJsxNamespaceFix(jsxNamespace, symbolToken, ch) then
            local result = {}
            if not scanner.IsIntrinsicJsxName(symbolToken:Text()) then
                local compSymbol = ch:ResolveName(symbolToken:Text(), symbolToken, SymbolFlags.Value, false --[[excludeGlobals]])
                if compSymbol == nil then
                    result[#result + 1] = { name = symbolToken:Text(), isTypeOnly = false }
                elseif ch:GetTypeOnlyAliasDeclaration(compSymbol) ~= nil then
                    result[#result + 1] = { name = symbolToken:Text(), isTypeOnly = true }
                end
            end
            local nsIsTypeOnly = false
            local nsSymbol = ch:ResolveName(jsxNamespace, symbolToken, SymbolFlags.Value, true --[[excludeGlobals]])
            if nsSymbol ~= nil then
                nsIsTypeOnly = ch:GetTypeOnlyAliasDeclaration(nsSymbol) ~= nil
            end
            result[#result + 1] = { name = jsxNamespace, isTypeOnly = nsIsTypeOnly }
            return result
        end
    end
    local tokenIsTypeOnly = false
    local sym = ch:ResolveName(symbolToken:Text(), symbolToken, SymbolFlags.Value, true --[[excludeGlobals]])
    if sym ~= nil then
        tokenIsTypeOnly = ch:GetTypeOnlyAliasDeclaration(sym) ~= nil
    end
    return { { name = symbolToken:Text(), isTypeOnly = tokenIsTypeOnly } }
end

function ls.needsJsxNamespaceFix(jsxNamespace, symbolToken, ch)
    if scanner.IsIntrinsicJsxName(symbolToken:Text()) then
        return true
    end
    local namespaceSymbol = ch:ResolveName(jsxNamespace, symbolToken, SymbolFlags.Value, true --[[excludeGlobals]])
    if namespaceSymbol == nil then
        return true
    end
    if core.Some(namespaceSymbol.declarations, ast.IsTypeOnlyImportOrExportDeclaration) then
        return (namespaceSymbol.flags & SymbolFlags.Value) == 0
    end
    return false
end

function ls.jsxModeNeedsExplicitImport(jsx)
    return jsx == core.JsxEmit.React or jsx == core.JsxEmit.ReactNative
end

function ls.sortFixInfo(fixes, fixContext, view)
    if core.Len(fixes) == 0 then
        return fixes
    end

    -- Create a copy to avoid modifying the original
    local sorted = core.Slice(fixes, 0, #fixes)

    -- Sort by:
    -- 1. JSX namespace fixes last
    -- 2. Fix comparison using view.CompareFixes
    core.SortFunc(sorted, function(a, b)
        -- JSX namespace fixes should come last
        local c = core.CompareBooleans(a.isJsxNamespaceFix, b.isJsxNamespaceFix)
        if c ~= 0 then
            return c
        end
        return view:CompareFixesForSorting(a.fix, b.fix)
    end)

    return sorted
end
