local ls = require("tslua.ls")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local lsproto = require("tslua.lsp.lsproto")
local scanner = require("tslua.scanner")
local spanmap = require("tslua.spanmap")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

function LanguageService:ProvideCodeLenses(ctx, documentURI)
    local _, file = self:getProgramAndFile(documentURI)

    local userPrefs = self:UserPreferences().codeLens
    if not core.Tristate_IsTrue(userPrefs.referencesCodeLensEnabled) and not core.Tristate_IsTrue(userPrefs.implementationsCodeLensEnabled) then
        return {}, nil
    end

    -- Keeps track of the last symbol to avoid duplicating code lenses across overloads.
    local lastSymbol = nil
    local result = nil
    local visit
    visit = function(node)
        if ctxErr(ctx) then
            return true
        end

        local currentSymbol = node:Symbol()
        if lastSymbol ~= currentSymbol then
            lastSymbol = currentSymbol

            if core.Tristate_IsTrue(userPrefs.referencesCodeLensEnabled) and ls.isValidReferenceLensNode(node, userPrefs) then
                local codeLens = self:newCodeLensForNode(documentURI, file, node, lsproto.CodeLensKind.References)
                if codeLens ~= nil then
                    result = core.Append(result, codeLens)
                end
            end

            if core.Tristate_IsTrue(userPrefs.implementationsCodeLensEnabled) and ls.isValidImplementationsCodeLensNode(node, userPrefs) then
                local codeLens = self:newCodeLensForNode(documentURI, file, node, lsproto.CodeLensKind.Implementations)
                if codeLens ~= nil then
                    result = core.Append(result, codeLens)
                end
            end
        end

        local savedLastSymbol = lastSymbol
        node:ForEachChild(visit)
        lastSymbol = savedLastSymbol
        return false
    end

    visit(file:AsNode())

    return {
        codeLenses = result or {},
    }, nil
end

function LanguageService:ResolveCodeLens(ctx, codeLens, showLocationsCommandName, orchestrator)
    local uri = codeLens.data.uri
    local textDoc = { uri = uri }
    local loc = locale.FromContext(ctx)
    local locs = nil
    local lensTitle = ""
    local kind = codeLens.data.kind
    if kind == lsproto.CodeLensKind.References then
        local referencesResp, err = self:ProvideReferences(ctx, lsproto.ReferenceParams({
            textDocument = textDoc,
            position = codeLens.range.start,
            context = {
                -- Don't include the declaration in the references count.
                includeDeclaration = false,
            },
        }), orchestrator)
        if err ~= nil then
            return nil, err
        end
        if referencesResp.locations ~= nil then
            locs = referencesResp.locations
        end

        if core.Len(locs) == 1 then
            lensTitle = diagnostics.X_1_reference:Localize(loc)
        else
            lensTitle = diagnostics.X_0_references:Localize(loc, core.Len(locs))
        end
    elseif kind == lsproto.CodeLensKind.Implementations then
        local implementations, err = self:provideImplementationsEx(
            ctx,
            lsproto.ImplementationParams({
                textDocument = textDoc,
                position = codeLens.range.start,
            }),
            -- "Force" link support to be false so that we only get `Locations` back,
            -- and don't include the "current" node in the results.
            ls.newSymbolEntryTransformOptions(true --[[requireLocationsResult]], true --[[dropOriginNodes]]),
            orchestrator
        )
        if err ~= nil then
            return nil, err
        end

        if implementations.locations ~= nil then
            locs = implementations.locations
        end

        if core.Len(locs) == 1 then
            lensTitle = diagnostics.X_1_implementation:Localize(loc)
        else
            lensTitle = diagnostics.X_0_implementations:Localize(loc, core.Len(locs))
        end
    end

    local cmd = {
        title = lensTitle,
        command = "",
    }
    if core.Len(locs) > 0 and showLocationsCommandName ~= nil then
        cmd.command = showLocationsCommandName
        cmd.arguments = {
            uri,
            codeLens.range.start,
            locs,
        }
    end

    codeLens.command = cmd
    return codeLens, nil
end

function LanguageService:newCodeLensForNode(fileUri, file, node, kind)
    local nodeForRange = node
    local nodeName = node:Name()
    if nodeName ~= nil then
        nodeForRange = nodeName
    end
    local pos = scanner.SkipTrivia(file:Text(), nodeForRange:Pos())
    local lspRange, fidelity = self.converters:ToLSPRangeForFeature(file, core.NewTextRange(pos, node:End()), spanmap.Feature.CodeLens)
    if spanmap.Fidelity_IsNone(fidelity) then
        return nil
    end

    return {
        range = lspRange,
        data = {
            kind = kind,
            uri = fileUri,
        },
    }
end

function ls.isValidImplementationsCodeLensNode(node, userPrefs)
    local k = node.kind
    -- Always show on interfaces
    if k == Kind.InterfaceDeclaration then
        -- TODO: ast.KindTypeAliasDeclaration?
        return true

    -- If configured, show on interface methods
    elseif k == Kind.MethodSignature then
        return core.Tristate_IsTrue(userPrefs.implementationsCodeLensShowOnInterfaceMethods) and node.parent.kind == Kind.InterfaceDeclaration

    -- If configured, show on all class methods - but not private ones.
    elseif k == Kind.MethodDeclaration then
        if core.Tristate_IsTrue(userPrefs.implementationsCodeLensShowOnAllClassMethods) and node.parent.kind == Kind.ClassDeclaration then
            return not ast.HasModifier(node, ModifierFlags.Private) and node:Name().kind ~= Kind.PrivateIdentifier
        end
        -- fallthrough
        return ast.HasModifier(node, ModifierFlags.Abstract)

    -- Always show on abstract classes/properties/methods
    elseif k == Kind.ClassDeclaration or k == Kind.Constructor or
        k == Kind.GetAccessor or k == Kind.SetAccessor or k == Kind.PropertyDeclaration then
        return ast.HasModifier(node, ModifierFlags.Abstract)
    end

    return false
end

function ls.isValidReferenceLensNode(node, userPrefs)
    local k = node.kind
    if k == Kind.FunctionDeclaration or k == Kind.VariableDeclaration then
        if k == Kind.FunctionDeclaration and core.Tristate_IsTrue(userPrefs.referencesCodeLensShowOnAllFunctions) then
            return true
        end
        -- fallthrough
        return ast.GetCombinedModifierFlags(node) & ModifierFlags.Export ~= 0
    elseif k == Kind.ClassDeclaration or k == Kind.InterfaceDeclaration or k == Kind.TypeAliasDeclaration or k == Kind.EnumDeclaration or k == Kind.EnumMember then
        return true
    elseif k == Kind.MethodDeclaration or k == Kind.MethodSignature or k == Kind.Constructor or
        k == Kind.GetAccessor or k == Kind.SetAccessor or
        k == Kind.PropertyDeclaration or k == Kind.PropertySignature then
        -- Don't show if child and parent have same start
        -- For https://github.com/microsoft/vscode/issues/90396
        -- !!!

        local pk = node.parent.kind
        if pk == Kind.ClassDeclaration or pk == Kind.InterfaceDeclaration or pk == Kind.TypeLiteral then
            return true
        end
    end

    return false
end
