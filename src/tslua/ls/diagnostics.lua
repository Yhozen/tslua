local ls = require("tslua.ls")
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local lsconv = require("tslua.ls.lsconv")
local spanmap = require("tslua.spanmap")

local LanguageService = ls.LanguageService

-- getAllDiagnostics collects all diagnostics for a file: syntactic, semantic,
-- suggestion, and (when declarations are emitted) declaration diagnostics.
function ls.getAllDiagnostics(ctx, program, file)
    local diags = nil
    local files = { file }
    for _, f in ipairs(file:SupplementalSourceFiles() or {}) do
        files[#files + 1] = f
    end
    for _, sourceFile in ipairs(files) do
        diags = core.AppendAll(diags, program:GetSyntacticDiagnostics(ctx, sourceFile))
        diags = core.AppendAll(diags, program:GetSemanticDiagnostics(ctx, sourceFile))
        diags = core.AppendAll(diags, program:GetSuggestionDiagnostics(ctx, sourceFile))
        if program:Options():GetEmitDeclarations() then
            diags = core.AppendAll(diags, program:GetDeclarationDiagnostics(ctx, sourceFile))
        end
    end
    return diags
end

-- Returns (lsproto.DocumentDiagnosticResponse, error): the union
-- { fullDocumentDiagnosticReport = { items = [...] } }.
function LanguageService:ProvideDiagnostics(ctx, uri)
    local program, file = self:getProgramAndFile(uri)

    if core.Tristate_IsFalse(self:UserPreferences().enableValidation) then
        local diags = {}
        return {
            fullDocumentDiagnosticReport = {
                items = diags,
            },
        }, nil
    end

    local diags = ls.getAllDiagnostics(ctx, program, file)

    return {
        fullDocumentDiagnosticReport = {
            items = self:toLSPDiagnostics(ctx, diags),
        },
    }, nil
end

function LanguageService:toLSPDiagnostics(ctx, ...)
    local diagnosticSlices = table.pack(...)
    local reportStyleChecksAsWarnings = core.Tristate_IsTrue(self:UserPreferences().reportStyleChecksAsWarnings)
    local lspDiagnostics = {}
    -- Compiler diagnostics located entirely in a content-mapped file's synthesized code have no location
    -- in the original file. Collect them per file and surface them through a single aggregate at the top
    -- of the file (with the real messages as related information) rather than dropping them or scattering
    -- them at position 0.
    local synthesizedByFile = collections.NewOrderedMap()
    for i = 1, diagnosticSlices.n do
        for _, diag in ipairs(diagnosticSlices[i] or {}) do
            if ls.isSynthesizedContentMappedDiagnostic(diag) then
                synthesizedByFile:Set(diag:File(), core.Append(synthesizedByFile:GetOrZero(diag:File()), diag))
            else
                lspDiagnostics[#lspDiagnostics + 1] = lsconv.DiagnosticToLSPPull(ctx, self.converters, diag, reportStyleChecksAsWarnings)
            end
        end
    end
    for file, diags in synthesizedByFile:Entries() do
        local aggregate = ls.aggregateSynthesizedDiagnostics(file, diags)
        lspDiagnostics[#lspDiagnostics + 1] = lsconv.DiagnosticToLSPPull(ctx, self.converters, aggregate, reportStyleChecksAsWarnings)
    end
    return lspDiagnostics
end

-- isSynthesizedContentMappedDiagnostic reports whether diag is a compiler diagnostic on a content-mapped
-- file whose location lies entirely in synthesized virtual code with no counterpart in the original
-- file, and so has no meaningful position to report against the original file.
function ls.isSynthesizedContentMappedDiagnostic(diag)
    local file = diag:File()
    if file == nil or file:SpanMap() == nil or diag:Source() ~= "" then
        return false
    end
    local _, fidelity = file:SpanMap():VirtualToOriginalSpan(diag:Loc())
    return fidelity == spanmap.Fidelity.None
end

-- aggregateSynthesizedDiagnostics builds a single diagnostic at the top of a content-mapped file standing
-- in for compiler diagnostics located in synthesized code with no original location. The originals are
-- attached as related information so their messages are surfaced rather than silently dropped. (A later
-- change will point the related locations at a read-only view of the file's virtual TypeScript.)
function ls.aggregateSynthesizedDiagnostics(file, diags)
    local aggregate = ast.NewDiagnostic(
        file,
        core.NewTextRange(0, 0),
        diagnostics.Virtual_code_produced_by_the_content_mapper_0_has_problems_with_no_corresponding_location_in_this_file,
        file:ContentMapper()
    )
    aggregate:SetRelatedInfo(diags)
    aggregate:SetCategory(ls.worstCategory(diags))
    return aggregate
end

function ls.worstCategory(diags)
    local worst = diags[1]:Category()
    for _, diag in ipairs(diags) do
        local c = diag:Category()
        if c == diagnostics.Category.Error then
            return diagnostics.Category.Error
        elseif c == diagnostics.Category.Warning then
            worst = diagnostics.Category.Warning
        end
    end
    return worst
end
