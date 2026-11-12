local ls = require("tslua.ls")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local spanmap = require("tslua.spanmap")

ls.LanguageService = ls.LanguageService or {}
local LanguageService = ls.LanguageService

local function hasPrefix(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

local function compareStrings(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- CodeFixProvider represents a provider for a specific type of code fix:
-- { errorCodes = { int32 }, getCodeActions = fn(ctx, fixContext) -> actions, err,
--   fixIds = { string }, getAllCodeActions = fn(ctx, fixContext) -> combined, err (or nil) }

-- CodeFixContext contains the context needed to generate code fixes:
-- { sourceFile, span (core.TextRange), errorCode, program, ls (LanguageService),
--   diagnostic (lsproto.Diagnostic or nil), params (lsproto.CodeActionParams or nil) }

-- CodeAction represents a single code action fix
local CodeAction = {}
CodeAction.__index = CodeAction
ls.CodeAction = CodeAction

-- NewCodeAction builds a CodeAction (Go &CodeAction{...}) with Go zero values filled in.
function ls.NewCodeAction(fields)
    return setmetatable({
        description = fields.description or "",
        changes = fields.changes,
        fixID = fields.fixID or "",
        fixAllDescription = fields.fixAllDescription or "",
    }, CodeAction)
end

-- Compare defines a total ordering for CodeAction values, comparing description
-- then text edits lexicographically. Used with slices.BinarySearchFunc.
function CodeAction:Compare(b)
    local c = compareStrings(self.description, b.description)
    if c ~= 0 then
        return c
    end
    c = compareStrings(core.Len(self.changes), core.Len(b.changes))
    if c ~= 0 then
        return c
    end
    for i, edit in ipairs(self.changes or {}) do
        c = lsproto.TextEdit.Compare(edit, b.changes[i])
        if c ~= 0 then
            return c
        end
    end
    return 0
end

-- CombinedCodeActions represents combined code actions for fix-all scenarios:
-- { description = string, changes = { lsproto.TextEdit } }

-- codeFixProviders is the list of all registered code fix providers. The providers are defined in
-- files of this package that load after this one, so the list is built on first use.
local function getCodeFixProviders()
    if ls.codeFixProviders == nil then
        ls.codeFixProviders = {
            ls.ImportFixProvider,
            ls.IsolatedDeclarationsFixProvider,
            ls.FixClassIncorrectlyImplementsInterfaceProvider,
            -- Add more code fix providers here as they are implemented
        }
    end
    return ls.codeFixProviders
end
ls.getCodeFixProviders = getCodeFixProviders

-- ProvideCodeActions returns code actions for the given range and context
function LanguageService:ProvideCodeActions(ctx, params)
    local program, file = self:getProgramAndFile(params.textDocument.uri)

    local actions = {}

    if params.context ~= nil and params.context.only ~= nil then
        for _, kind in ipairs(params.context.only) do
            local matchingKinds = ls.getOrganizeImportsActionsForKind(kind)
            for _, matchingKind in ipairs(matchingKinds or {}) do
                local organizeAction = self:createOrganizeImportsAction(ctx, program, file, matchingKind)
                actions[#actions + 1] = organizeAction
            end

            if ls.isFixAllKind(kind) then
                local fixAllAction, err = self:createFixAllAction(ctx, program, file, params.textDocument.uri)
                if err ~= nil then
                    return {}, err
                end
                if fixAllAction ~= nil then
                    actions[#actions + 1] = fixAllAction
                end
            end
        end
    end

    if params.context ~= nil and params.context.diagnostics ~= nil and ls.wantsQuickFixes(params.context.only) then
        local fixIdSeen = {}

        local seen = {} -- sorted for binary search dedup, dedup across all diagnostics and providers so if multiple diags produce the same codefix, only one is returned

        for _, diag in ipairs(params.context.diagnostics) do
            if diag.code == nil or diag.code.integer == nil then
                goto continue
            end

            do
                local errorCode = diag.code.integer

                for _, provider in ipairs(getCodeFixProviders()) do
                    if not ls.codeFixProviderMatchesLSPDiagnostic(provider, diag) then
                        goto nextProvider
                    end

                    for _, mapped in ipairs(lsconv.FromLSPRangeForSourceFile(self.converters, file, diag.range, spanmap.Feature.CodeActions) or {}) do
                        local fixContext = {
                            sourceFile = mapped.script,
                            span = mapped.span,
                            errorCode = errorCode,
                            program = program,
                            ls = self,
                            diagnostic = diag,
                            params = params,
                        }

                        local providerActions, err = provider.getCodeActions(ctx, fixContext)
                        if err ~= nil then
                            return {}, err
                        end
                        for _, action in ipairs(providerActions or {}) do
                            local i, found = core.BinarySearchUniqueFunc(seen, function(_, value)
                                return value:Compare(action)
                            end)
                            if not found then
                                table.insert(seen, i + 1, action)
                                actions[#actions + 1] = ls.convertToLSPCodeAction(action, diag, params.textDocument.uri)
                                if action.fixID ~= "" then
                                    fixIdSeen[action.fixID] = provider
                                end
                            end
                        end
                    end

                    ::nextProvider::
                end
            end

            ::continue::
        end

        local fixAllActions, err = self:getFixAllQuickFixes(ctx, program, file, params.textDocument.uri, fixIdSeen)
        if err ~= nil then
            return {}, err
        end
        for _, a in ipairs(fixAllActions or {}) do
            actions[#actions + 1] = a
        end
    end

    return { commandOrCodeActionArray = actions }, nil
end

-- getFixAllQuickFixes returns per-provider "Fix all in file" quickfix entries for providers
-- that matched at least 2 diagnostics in the full file.
function LanguageService:getFixAllQuickFixes(ctx, program, file, uri, fixIdSeen)
    local actions = nil

    -- Go ranges over the fixIdSeen map (unordered); iterate fix ids in sorted order for determinism.
    local fixIds = {}
    for fixId in pairs(fixIdSeen) do
        fixIds[#fixIds + 1] = fixId
    end
    table.sort(fixIds)

    -- Deduplicate providers; multiple fixIds may map to the same provider.
    local seen = {}
    for _, fixId in ipairs(fixIds) do
        local provider = fixIdSeen[fixId]
        if seen[provider] then
            goto continue
        end
        seen[provider] = true

        if provider.getAllCodeActions == nil then
            goto continue
        end

        if not ls.hasMultipleFixableDiagnostics(ctx, program, file, provider.errorCodes) then
            goto continue
        end

        do
            local fixContext = {
                sourceFile = file,
                span = core.NewTextRange(0, 0),
                errorCode = 0,
                program = program,
                ls = self,
            }
            local combined, err = provider.getAllCodeActions(ctx, fixContext)
            if err ~= nil then
                return nil, err
            end
            if combined ~= nil and core.Len(combined.changes) > 0 then
                local kind = lsproto.CodeActionKind.QuickFix
                local changes = {
                    [uri] = combined.changes,
                }
                actions = core.Append(actions, {
                    codeAction = {
                        title = combined.description,
                        kind = kind,
                        edit = { changes = changes },
                    },
                })
            end
        end

        ::continue::
    end

    return actions, nil
end

-- hasMultipleFixableDiagnostics returns true if the file has at least 2 diagnostics
-- matching the given error codes. Checks all diagnostic sources (semantic,
-- syntactic, suggestion, declaration) to match ProvideDiagnostics.
function ls.hasMultipleFixableDiagnostics(ctx, program, file, errorCodes)
    local allDiags = ls.getAllDiagnostics(ctx, program, file)
    local count = 0
    for _, d in ipairs(allDiags or {}) do
        if ls.isFixableDiagnostic(d, errorCodes) then
            count = count + 1
            if count >= 2 then
                return true
            end
        end
    end
    return false
end

function ls.codeFixProviderMatchesLSPDiagnostic(provider, diagnostic)
    if diagnostic.source ~= nil and diagnostic.source ~= "ts" then
        return false
    end
    return diagnostic.code ~= nil and diagnostic.code.integer ~= nil and ls.containsErrorCode(provider.errorCodes, diagnostic.code.integer)
end

function ls.isFixableDiagnostic(diagnostic, errorCodes)
    return diagnostic:Source() == "" and ls.containsErrorCode(errorCodes, diagnostic:Code())
end

-- codeActionKindContains returns true if the requested kind equals or is a
-- hierarchical parent of actionKind, using '.' as the separator. This matches
-- the semantics of VS Code's HierarchicalKind.contains.
function ls.codeActionKindContains(requestedKind, actionKind)
    return requestedKind == actionKind or
        requestedKind == "" or
        hasPrefix(actionKind, requestedKind .. ".")
end

-- isFixAllKind returns true if the requested kind matches source.fixAll
function ls.isFixAllKind(kind)
    return ls.codeActionKindContains(kind, lsproto.CodeActionKind.SourceFixAll)
end

-- wantsQuickFixes returns true if the Only filter is nil/empty (meaning all kinds are wanted)
-- or explicitly includes the quickfix kind.
function ls.wantsQuickFixes(only)
    if only == nil or #only == 0 then
        return true
    end
    for _, kind in ipairs(only) do
        if ls.codeActionKindContains(kind, lsproto.CodeActionKind.QuickFix) then
            return true
        end
    end
    return false
end

-- createFixAllAction creates a source.fixAll code action that applies all auto-fixable
-- code fixes across the file.
function LanguageService:createFixAllAction(ctx, program, file, uri)
    local kind = lsproto.CodeActionKind.SourceFixAll
    local lspChanges = {}
    local hasChanges = false

    for _, provider in ipairs(getCodeFixProviders()) do
        if provider.getAllCodeActions == nil then
            goto continue
        end

        do
            local fixContext = {
                sourceFile = file,
                span = core.NewTextRange(0, 0),
                errorCode = 0,
                program = program,
                ls = self,
            }

            local combined, err = provider.getAllCodeActions(ctx, fixContext)
            if err ~= nil then
                return nil, err
            end
            if combined ~= nil and core.Len(combined.changes) > 0 then
                lspChanges[uri] = core.AppendAll(lspChanges[uri], combined.changes)
                hasChanges = true
            end
        end

        ::continue::
    end

    if not hasChanges then
        return nil, nil
    end

    return {
        codeAction = {
            title = diagnostics.Fix_All:Localize(locale.FromContext(ctx)),
            kind = kind,
            edit = { changes = lspChanges },
        },
    }, nil
end

-- getOrganizeImportsActionTitle returns the appropriate title for the given organize imports kind
function ls.getOrganizeImportsActionTitle(ctx, kind)
    local loc = locale.FromContext(ctx)
    if kind == lsproto.CodeActionKind.SourceRemoveUnusedImports then
        return diagnostics.Remove_Unused_Imports:Localize(loc)
    elseif kind == lsproto.CodeActionKind.SourceSortImports then
        return diagnostics.Sort_Imports:Localize(loc)
    else
        return diagnostics.Organize_Imports:Localize(loc)
    end
end

-- getOrganizeImportsActionsForKind returns the organize imports code action kinds that should be
-- returned for the given requested kind.
function ls.getOrganizeImportsActionsForKind(requestedKind)
    local organizeImportsKinds = {
        lsproto.CodeActionKind.SourceOrganizeImports,
        lsproto.CodeActionKind.SourceRemoveUnusedImports,
        lsproto.CodeActionKind.SourceSortImports,
    }

    local result = nil
    for _, organizeKind in ipairs(organizeImportsKinds) do
        if ls.codeActionKindContains(requestedKind, organizeKind) then
            result = core.Append(result, organizeKind)
        end
    end

    for _, k in ipairs(result or {}) do
        if k == requestedKind then
            return { requestedKind }
        end
    end

    return result
end

-- createOrganizeImportsAction creates the organize imports code action
function LanguageService:createOrganizeImportsAction(ctx, program, file, kind)
    local title = ls.getOrganizeImportsActionTitle(ctx, kind)
    local changes = self:OrganizeImports(
        ctx,
        file,
        program,
        kind
    )
    if changes == nil or next(changes) == nil then
        return {
            codeAction = {
                title = title,
                kind = kind,
                edit = { changes = {} },
            },
        }
    end

    local lspChanges = {}
    for fileName, edits in pairs(changes) do
        local fileURI = lsconv.FileNameToDocumentURI(fileName)
        lspChanges[fileURI] = edits
    end

    return {
        codeAction = {
            title = title,
            kind = kind,
            edit = { changes = lspChanges },
        },
    }
end

-- containsErrorCode checks if the error code is in the list
function ls.containsErrorCode(codes, code)
    for _, c in ipairs(codes or {}) do
        if c == code then
            return true
        end
    end
    return false
end

-- convertToLSPCodeAction converts an internal CodeAction to an LSP CodeAction
function ls.convertToLSPCodeAction(action, diag, uri)
    local kind = lsproto.CodeActionKind.QuickFix
    local changes = {
        [uri] = action.changes,
    }
    local diags = { diag }

    return {
        codeAction = {
            title = action.description,
            kind = kind,
            edit = { changes = changes },
            diagnostics = diags,
        },
    }
end
