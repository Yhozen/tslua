local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local lsconv = require("tslua.ls.lsconv")
local lsutil = require("tslua.ls.lsutil")
local lsproto = require("tslua.lsp.lsproto")
local module = require("tslua.module")
local spanmap = require("tslua.spanmap")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function zeroRange()
    return { start = { line = 0, character = 0 }, end_ = { line = 0, character = 0 } }
end

local function rangeKey(r)
    return r.start.line .. ":" .. r.start.character .. "-" .. r.end_.line .. ":" .. r.end_.character
end

-- RenameInfo represents the result of a rename validation check.
-- It is used by the `textDocument/prepareRename` LSP handler.
-- { canRename, localizedErrorMessage, displayName, triggerSpan, fileToRename, newFileName }
function ls.newRenameInfo(fields)
    local info = {
        canRename = false,
        localizedErrorMessage = "",
        displayName = "",
        triggerSpan = zeroRange(),
        fileToRename = "",
        newFileName = "",
    }
    for k, v in pairs(fields or {}) do
        info[k] = v
    end
    return info
end

-- mappedRenameEdit: { uri, edit }
-- renameEditKey: { uri, textRange } (encoded as a string key)

function ls.deduplicateRenameEdits(mappedEdits)
    local editTexts = {}
    local uniqueEdits = {}
    for _, mappedEdit in ipairs(mappedEdits or {}) do
        local key = tostring(mappedEdit.uri) .. "\0" .. rangeKey(mappedEdit.edit.range)
        local existingText = editTexts[key]
        if existingText ~= nil then
            if existingText ~= mappedEdit.edit.newText then
                return nil, false
            end
            goto continue
        end
        editTexts[key] = mappedEdit.edit.newText
        uniqueEdits[#uniqueEdits + 1] = mappedEdit
        ::continue::
    end
    local changes = {}
    for _, mappedEdit in ipairs(uniqueEdits) do
        local list = changes[mappedEdit.uri]
        if list == nil then
            list = {}
            changes[mappedEdit.uri] = list
        end
        list[#list + 1] = mappedEdit.edit
    end
    return changes, true
end

function LanguageService:ProvideRename(ctx, params, orchestrator)
    return ls.handleCrossProject(
        self,
        ctx,
        params,
        orchestrator,
        LanguageService.symbolAndEntriesToRename,
        ls.combineRenameResponse,
        true, --[[isRename]]
        false, --[[implementations]]
        ls.newSymbolEntryTransformOptions()
    )
end

function LanguageService:GetRenameInfo(ctx, newName, documentURI, pos)
    local program, sourceFile = self:getProgramAndFile(documentURI)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, sourceFile, pos, spanmap.Feature.Rename)
    for _, mapped in ipairs(positions or {}) do
        if not spanmap.Fidelity_IsExact(mapped.fidelity) then
            goto continue
        end
        do
            local file = mapped.script
            local node = astnav.GetTouchingPropertyName(file, mapped.position)
            node = ls.getAdjustedLocation(node, true --[[forRename]], file)
            if ls.nodeIsEligibleForRename(node) then
                local renameInfo, ok = self:getRenameInfoForNode(ctx, newName, node, file, program)
                if ok then
                    return renameInfo
                end
            end
        end
        ::continue::
    end
    return ls.getRenameInfoError(ctx, diagnostics.You_cannot_rename_this_element)
end

function LanguageService:symbolAndEntriesToRename(ctx, params, data, options)
    if not ls.nodeIsEligibleForRename(data.originalNode) then
        return {}, nil
    end

    local program = self:GetProgram()

    -- Defense-in-depth: validate rename eligibility even if the client skipped prepareRename.
    -- Use getRenameInfoForNode directly with the already-resolved node to avoid
    -- re-resolving the position and polluting state baselines.
    local sourceFile = ast.GetSourceFileOfNode(data.originalNode)
    local info, ok = self:getRenameInfoForNode(ctx, params.newName, data.originalNode, sourceFile, program)
    if not ok or not info.canRename then
        return {}, nil
    end

    local entries = core.FlatMap(data.symbolsAndEntries, function(s) return s.references end)
    local mappedEdits = nil
    local ch, done = program:GetTypeChecker(ctx)

    local quotePreference = lsutil.GetQuotePreference(sourceFile, self:UserPreferences())
    local useAliasesForRename = core.Tristate_IsTrueOrUnknown(self:UserPreferences().useAliasesForRename)

    for _, entry in ipairs(entries or {}) do
        local uri = self:getFileNameOfEntry(entry)
        if self:UserPreferences().allowRenameOfImportPath ~= core.Tristate.TSTrue and entry.node ~= nil and ast.IsStringLiteralLike(entry.node) and ast.TryGetImportFromModuleSpecifier(entry.node) ~= nil then
            goto continue
        end
        do
            local rng, rok = self:renameEditRange(entry)
            if not rok then
                -- The occurrence lies outside a verbatim span of a content-mapped file, so it cannot be
                -- written back to the original text. Skip it and keep renaming the remaining occurrences.
                goto continue
            end
            local textEdit = {
                range = rng,
                newText = self:getTextForRename(data.originalNode, entry, params.newName, ch, quotePreference, useAliasesForRename),
            }
            mappedEdits = core.Append(mappedEdits, { uri = uri, edit = textEdit })
        end
        ::continue::
    end
    done()
    local changes, dok = ls.deduplicateRenameEdits(mappedEdits)
    if not dok then
        return {}, nil
    end
    return {
        workspaceEdit = {
            changes = changes,
        },
    }, nil
end

-- renameEditRange returns the LSP range at which a rename occurrence should be edited. For occurrences in
-- content-mapped files it maps the transformed range strictly, returning ok=false when the occurrence is
-- not fully within a single verbatim span, so the caller can skip an edit that cannot be applied to the
-- original text.
function LanguageService:renameEditRange(entry)
    self:resolveEntry(entry)
    if entry.node == nil then
        local location, fidelity = self:sourceFileRangeToLSPLocation(entry.sourceFile, entry.textRange)
        return location.range, spanmap.Fidelity_IsExact(fidelity)
    end
    local sourceFile = ast.GetSourceFileOfNode(entry.node)
    if sourceFile == nil or sourceFile:SpanMap() == nil then
        return self:getRangeOfEntry(entry), true
    end
    local lspRange, fidelity = self.converters:ToLSPRange(sourceFile, entry.textRange)
    return lspRange, spanmap.Fidelity_IsExact(fidelity)
end

-- getRenameInfoForNode performs detailed validation for a rename operation on a specific node.
function LanguageService:getRenameInfoForNode(ctx, newName, node, sourceFile, program)
    local ch, done = program:GetTypeChecker(ctx)
    local info, ok = self:getRenameInfoForNodeWorker(ctx, newName, node, sourceFile, program, ch)
    done()
    return info, ok
end

-- Body of getRenameInfoForNode after the checker is acquired (split out so `defer done()` runs on every path).
function LanguageService:getRenameInfoForNodeWorker(ctx, newName, node, sourceFile, program, ch)
    local symbol = ch:GetSymbolAtLocation(node)
    if symbol == nil then
        if ast.IsStringLiteralLike(node) then
            -- Allow renaming of string literal types with contextual string literal types
            local typ = ls.getContextualTypeFromParentOrAncestorTypeNode(node, ch)
            if typ ~= nil and (typ:IsStringLiteral() or
                (typ:IsUnion() and core.Every(typ:Types(), function(t)
                    return t:IsStringLiteral()
                end))) then
                return ls.getRenameInfoSuccess(node, sourceFile, node:Text(), self.converters), true
            end
        elseif ast.IsLabelName(node) then
            local name = node:Text()
            return ls.getRenameInfoSuccess(node, sourceFile, name, self.converters), true
        end
        return ls.newRenameInfo(), false
    end

    -- Only allow a symbol to be renamed if it actually has at least one declaration.
    if core.Len(symbol.declarations) == 0 then
        return ls.newRenameInfo(), false
    end

    local msg = self:renameBlockedReason(sourceFile, node, symbol, ch, program)
    if msg ~= nil then
        return ls.getRenameInfoError(ctx, msg), true
    end

    if ast.IsStringLiteralLike(node) and ast.TryGetImportFromModuleSpecifier(node) ~= nil then
        if core.Tristate_IsTrue(self:UserPreferences().allowRenameOfImportPath) then
            return self:getRenameInfoForModule(ctx, newName, node, sourceFile, symbol)
        end
        return ls.newRenameInfo(), false
    end

    return ls.getRenameInfoSuccess(node, sourceFile, ch:SymbolToString(symbol), self.converters), true
end

function ls.nodeIsEligibleForRename(node)
    if node == nil then
        return false
    end
    local k = node.kind
    if k == Kind.Identifier or
        k == Kind.PrivateIdentifier or
        k == Kind.StringLiteral or
        k == Kind.NoSubstitutionTemplateLiteral or
        k == Kind.ThisKeyword then
        return true
    elseif k == Kind.NumericLiteral then
        return ls.isLiteralNameOfPropertyDeclarationOrIndexAccess(node)
    else
        return false
    end
end

-- renameBlockedReason returns a non-nil diagnostic message if the rename should be blocked
-- because the symbol is a library definition, a default keyword, or would cross node_modules boundaries.
function LanguageService:renameBlockedReason(sourceFile, node, symbol, ch, program)
    for _, declaration in ipairs(symbol.declarations or {}) do
        if ls.isDefinedInLibraryFile(program, declaration) then
            return diagnostics.You_cannot_rename_elements_that_are_defined_in_the_standard_TypeScript_library
        end
    end

    -- Cannot rename `default` as in `import { default as foo } from "./someModule"`
    if ast.IsIdentifier(node) and node:Text() == "default" and symbol.parent ~= nil and symbol.parent.flags & SymbolFlags.Module ~= 0 then
        return diagnostics.You_cannot_rename_this_element
    end

    local msg = ls.wouldRenameInOtherNodeModules(sourceFile, symbol, ch, self:UserPreferences())
    if msg ~= nil then
        return msg
    end

    return nil
end

-- isDefinedInLibraryFile checks if a declaration is from a default library file (e.g., lib.d.ts).
function ls.isDefinedInLibraryFile(program, declaration)
    local declSourceFile = ast.GetSourceFileOfNode(declaration)
    return program:IsSourceFileDefaultLibrary(declSourceFile:Path()) and tspath.IsDeclarationFileName(declSourceFile:FileName())
end

-- wouldRenameInOtherNodeModules checks if renaming the symbol would affect node_modules.
function ls.wouldRenameInOtherNodeModules(originalFile, symbol, ch, preferences)
    local sym = symbol
    if not core.Tristate_IsTrueOrUnknown(preferences.useAliasesForRename) and sym.flags & SymbolFlags.Alias ~= 0 then
        local importSpecifier = core.Find(sym.declarations, ast.IsImportSpecifier)
        if importSpecifier ~= nil and importSpecifier:AsImportSpecifier().propertyName == nil then
            sym = ch:GetAliasedSymbol(sym)
        end
    end

    local declarations = sym.declarations
    if core.Len(declarations) == 0 then
        return nil
    end

    local originalPackage = module.ParseNodeModuleFromPath(originalFile:FileName(), false --[[isFolder]])
    if originalPackage == "" then
        -- Original source file is not in node_modules.
        for _, declaration in ipairs(declarations) do
            if ls.isInsideNodeModules(ast.GetSourceFileOfNode(declaration):FileName()) then
                return diagnostics.You_cannot_rename_elements_that_are_defined_in_a_node_modules_folder
            end
        end
        return nil
    end

    -- Original source file is in node_modules.
    for _, declaration in ipairs(declarations) do
        local declPackage = module.ParseNodeModuleFromPath(ast.GetSourceFileOfNode(declaration):FileName(), false --[[isFolder]])
        if declPackage ~= "" and declPackage ~= originalPackage then
            return diagnostics.You_cannot_rename_elements_that_are_defined_in_another_node_modules_folder
        end
    end
    return nil
end

function ls.ClientSupportsWillRenameFiles(ctx)
    return lsproto.GetClientCapabilities(ctx).workspace.fileOperations.willRename
end

function ls.ClientSupportsDocumentChanges(ctx)
    return lsproto.GetClientCapabilities(ctx).workspace.workspaceEdit.documentChanges
end

function ls.ClientSupportsRenameResourceOperations(ctx)
    return core.Some(lsproto.GetClientCapabilities(ctx).workspace.workspaceEdit.resourceOperations, function(k)
        return k == lsproto.ResourceOperationKind.Rename
    end)
end

local function hasSuffix(s, suffix)
    return #s >= #suffix and string.sub(s, #s - #suffix + 1) == suffix
end

-- Go strings.LastIndex (0-based, -1 if absent).
local function lastIndex(s, sub)
    local result = -1
    local init = 1
    while true do
        local i = string.find(s, sub, init, true)
        if i == nil then
            return result
        end
        result = i - 1
        init = i + 1
    end
end

-- getRenameInfoForModule handles rename validation for module specifiers.
function LanguageService:getRenameInfoForModule(ctx, newName, specifier, sourceFile, moduleSymbol)
    if not tspath.IsExternalModuleNameRelative(specifier:Text()) then
        return ls.getRenameInfoError(ctx, diagnostics.You_cannot_rename_a_module_via_a_global_import), true
    end
    if not ls.ClientSupportsDocumentChanges(ctx) or not ls.ClientSupportsRenameResourceOperations(ctx) then
        return ls.getRenameInfoError(ctx, diagnostics.File_rename_is_not_supported_by_the_editor), true
    end

    local moduleSourceFile = core.Find(moduleSymbol.declarations, ast.IsSourceFile)
    if moduleSourceFile == nil then
        return ls.newRenameInfo(), false
    end

    local fileName = moduleSourceFile:AsSourceFile():FileName()
    local withoutIndex = ""
    if not hasSuffix(specifier:Text(), "/index") and not hasSuffix(specifier:Text(), "/index.js") then
        local candidate = tspath.RemoveFileExtension(fileName)
        if hasSuffix(candidate, "/index") then
            withoutIndex = string.sub(candidate, 1, #candidate - #"/index")
        end
    end

    local displayName = fileName
    if withoutIndex ~= "" then
        displayName = withoutIndex
    end
    local newFileName = self:getNewFileNameForModuleRename(displayName, specifier:Text(), newName)

    -- Span should only be the last component of the path. + 1 to account for the quote character.
    local indexAfterLastSlash = lastIndex(specifier:Text(), "/") + 1
    local start = astnav.GetStartOfNode(specifier, sourceFile, false --[[includeJSDoc]]) + 1 + indexAfterLastSlash
    local length = #specifier:Text() - indexAfterLastSlash

    local triggerSpan, fidelity = self.converters:ToLSPRange(sourceFile, core.NewTextRange(start, start + length))
    if not spanmap.Fidelity_IsExact(fidelity) then
        return ls.newRenameInfo(), false
    end
    return ls.newRenameInfo({
        canRename = true,
        displayName = string.sub(specifier:Text(), indexAfterLastSlash + 1),
        triggerSpan = triggerSpan,
        fileToRename = displayName,
        newFileName = newFileName,
    }), true
end

-- Adjust the new name based on the old path that an import specifier resolves to.
-- For example, if specifier "a.js" resolves to file a.ts, renaming "a.js" -> "b.js" should mean file rename a.ts -> b.ts.
function LanguageService:getNewFileNameForModuleRename(oldPath, specifierText, newName)
    local newPath = tspath.CombinePaths(tspath.GetDirectoryPath(oldPath), newName)
    local ignoreCase = not self.host:UseCaseSensitiveFileNames()
    local oldExt
    if tspath.IsDeclarationFileName(oldPath) then
        oldExt = tspath.GetDeclarationFileExtension(oldPath)
    else
        oldExt = tspath.GetAnyExtensionFromPath(oldPath, nil --[[extensions]], ignoreCase)
    end
    if not tspath.HasExtension(newPath) then
        newPath = newPath .. oldExt
    elseif tspath.GetAnyExtensionFromPath(newPath, nil --[[extensions]], ignoreCase) == tspath.GetAnyExtensionFromPath(specifierText, nil --[[extensions]], ignoreCase) then
        newPath = tspath.ChangeAnyExtension(newPath, oldExt, nil --[[extensions]], ignoreCase)
    end
    return newPath
end

function LanguageService:getTextForRename(originalNode, entry, newText, ch, quotePreference, useAliasesForRename)
    if useAliasesForRename and entry.kind ~= ls.entryKindRange and (ast.IsIdentifier(originalNode) or ast.IsStringLiteralLike(originalNode)) then
        local node = ast.GetReparsedNodeForNode(entry.node)
        local kind = entry.kind
        local parent = node.parent
        local name = originalNode:Text()
        local isShorthandAssignment = ast.IsShorthandPropertyAssignment(parent)
        if isShorthandAssignment or (ls.isObjectBindingElementWithoutPropertyName(parent) and parent:Name() == node and parent:AsBindingElement().dotDotDotToken == nil) then
            if kind == ls.entryKindSearchedLocalFoundProperty then
                return name .. ": " .. newText
            end
            if kind == ls.entryKindSearchedPropertyFoundLocal then
                return newText .. ": " .. name
            end
            -- In `const o = { x }; o.x`, symbolAtLocation at `x` in `{ x }` is the property symbol.
            -- For a binding element `const { x } = o;`, symbolAtLocation at `x` is the property symbol.
            if isShorthandAssignment then
                local grandParent = parent.parent
                if ast.IsObjectLiteralExpression(grandParent) and ast.IsBinaryExpression(grandParent.parent) and ast.IsModuleExportsAccessExpression(grandParent.parent:AsBinaryExpression().left) then
                    return name .. ": " .. newText
                end
                return newText .. ": " .. name
            end
            return name .. ": " .. newText
        elseif ast.IsImportSpecifier(parent) and parent:PropertyName() == nil then
            -- If the original symbol was using this alias, just rename the alias.
            local originalSymbol
            if ast.IsExportSpecifier(originalNode.parent) then
                originalSymbol = ch:GetExportSpecifierLocalTargetSymbol(originalNode.parent)
            else
                originalSymbol = ch:GetSymbolAtLocation(originalNode)
            end
            if originalSymbol ~= nil and core.Some(originalSymbol.declarations, function(d) return d == parent end) then
                return name .. " as " .. newText
            end
            return newText
        elseif ast.IsExportSpecifier(parent) and parent:PropertyName() == nil then
            -- If the symbol for the node is same as declared node symbol use prefix text
            if originalNode == entry.node or ch:GetSymbolAtLocation(originalNode) == ch:GetSymbolAtLocation(entry.node) then
                return name .. " as " .. newText
            end
            return newText .. " as " .. name
        end
    end

    -- If the node is a numerical indexing literal, then add quotes around the property access.
    if entry.kind ~= ls.entryKindRange and ast.IsNumericLiteral(entry.node) and ast.IsAccessExpression(entry.node.parent) then
        local quote = ls.getQuoteFromPreference(quotePreference)
        return quote .. newText .. quote
    end

    return newText
end

function ls.getQuoteFromPreference(quotePreference)
    if quotePreference == lsutil.QuotePreference.Single then
        return "'"
    end
    return "\""
end

function ls.getRenameInfoError(ctx, message)
    return ls.newRenameInfo({
        canRename = false,
        localizedErrorMessage = message:Localize(locale.FromContext(ctx)),
    })
end

function ls.getRenameInfoSuccess(node, sourceFile, displayName, converters)
    local start = astnav.GetStartOfNode(node, sourceFile, false --[[includeJSDoc]])
    local end_ = node:End()
    if ast.IsStringLiteralLike(node) then
        -- Exclude the quotes
        start = start + 1
        end_ = end_ - 1
    end
    local triggerSpan, fidelity = converters:ToLSPRange(sourceFile, core.NewTextRange(start, end_))
    if not spanmap.Fidelity_IsExact(fidelity) then
        return ls.newRenameInfo({ canRename = false })
    end
    return ls.newRenameInfo({
        canRename = true,
        displayName = displayName,
        triggerSpan = triggerSpan,
    })
end
