local compiler = require("tslua.compiler")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")

compiler.processingDiagnosticKindUnknownReference = 0
compiler.processingDiagnosticKindExplainingFileInclude = 1

-- processingDiagnostic: { kind = processingDiagnosticKind, data = FileIncludeReason | includeExplainingDiagnostic }
local processingDiagnostic = {}
processingDiagnostic.__index = processingDiagnostic
compiler.processingDiagnostic = processingDiagnostic

function compiler.newProcessingDiagnostic(kind, data)
    return setmetatable({ kind = kind, data = data }, processingDiagnostic)
end

function processingDiagnostic:asFileIncludeReason()
    return self.data
end

-- includeExplainingDiagnostic: { file = tspath.Path (""), diagnosticReason = *FileIncludeReason,
--   message = *diagnostics.Message, args = []any }
function compiler.newIncludeExplainingDiagnostic(fields)
    return {
        file = fields.file or "",
        diagnosticReason = fields.diagnosticReason,
        message = fields.message,
        args = fields.args,
    }
end

function processingDiagnostic:asIncludeExplainingDiagnostic()
    return self.data
end

function processingDiagnostic:toDiagnostic(program)
    if self.kind == compiler.processingDiagnosticKindUnknownReference then
        local ref = self:asFileIncludeReason()
        local loc = ref:getReferencedLocation(program)
        if ref.kind == compiler.fileIncludeKindTypeReferenceDirective then
            return loc:diagnosticAt(diagnostics.Cannot_find_type_definition_file_for_0, loc.ref.fileName)
        elseif ref.kind == compiler.fileIncludeKindLibReferenceDirective then
            local libName = tspath.ToFileNameLowerCase(loc.ref.fileName)
            local unqualifiedLibName = compiler.trimSuffix(compiler.trimPrefix(libName, "lib."), ".d.ts")
            local suggestion = core.GetSpellingSuggestionForStrings(unqualifiedLibName, tsoptions.Libs)
            local message
            if suggestion ~= "" then
                message = diagnostics.Cannot_find_lib_definition_for_0_Did_you_mean_1
            else
                message = diagnostics.Cannot_find_lib_definition_for_0
            end
            return loc:diagnosticAt(message, libName, suggestion)
        else
            error("unknown include kind", 0)
        end
    elseif self.kind == compiler.processingDiagnosticKindExplainingFileInclude then
        return self:createDiagnosticExplainingFile(program)
    else
        error("unknown processingDiagnosticKind", 0)
    end
end

function processingDiagnostic:createDiagnosticExplainingFile(program)
    local diag = self:asIncludeExplainingDiagnostic()
    local includeDetails = nil
    local relatedInfo = nil
    local redirectInfo = nil
    local preferredLocation = nil
    local seenReasons = {}
    local seenReasonsLen = 0
    if compiler.isReferencedFileReason(diag.diagnosticReason) and not program.includeProcessor:getReferenceLocation(diag.diagnosticReason, program).isSynthetic then
        preferredLocation = diag.diagnosticReason
    end

    local function processRelatedInfo(includeReason)
        if preferredLocation == nil and compiler.isReferencedFileReason(includeReason) and not program.includeProcessor:getReferenceLocation(includeReason, program).isSynthetic then
            preferredLocation = includeReason
        elseif preferredLocation ~= includeReason then
            local info = program.includeProcessor:getRelatedInfo(includeReason, program)
            if info ~= nil then
                relatedInfo = core.Append(relatedInfo, info)
            end
        end
    end
    local function processInclude(includeReason)
        if seenReasons[includeReason] then
            return
        end
        seenReasons[includeReason] = true
        seenReasonsLen = seenReasonsLen + 1
        includeDetails = core.Append(includeDetails, includeReason:toDiagnostic(program, false))
        processRelatedInfo(includeReason)
    end

    -- !!! todo sheetal caching

    if diag.file ~= "" then
        local reasons = program.includeProcessor.fileIncludeReasons[diag.file]
        includeDetails = {}
        for _, reason in ipairs(reasons or {}) do
            processInclude(reason)
        end
        redirectInfo = program.includeProcessor:explainRedirectAndImpliedFormat(program, diag.file, function(fileName) return fileName end)
    end
    if diag.diagnosticReason ~= nil then
        processInclude(diag.diagnosticReason)
    end
    local chain = nil
    if includeDetails ~= nil and (preferredLocation == nil or seenReasonsLen ~= 1) then
        local fileReason = ast.NewCompilerDiagnostic(diagnostics.The_file_is_in_the_program_because_Colon)
        fileReason:SetMessageChain(includeDetails)
        chain = { fileReason }
    end
    if redirectInfo ~= nil then
        chain = core.AppendAll(chain, redirectInfo)
    end

    local result = nil
    if preferredLocation ~= nil then
        result = program.includeProcessor:getReferenceLocation(preferredLocation, program):diagnosticAt(diag.message, compiler.unpackArgs(diag.args))
    end
    if result == nil then
        result = ast.NewCompilerDiagnostic(diag.message, compiler.unpackArgs(diag.args))
    end
    if chain ~= nil then
        result:SetMessageChain(chain)
    end
    if relatedInfo ~= nil then
        result:SetRelatedInfo(relatedInfo)
    end
    return result
end
