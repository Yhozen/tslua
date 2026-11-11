local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")

local SymbolFlags = ast.SymbolFlags

-- Go checker.go 10750-14357. The functions from GetDiagnostics through newProperty (Go lines
-- 14052-14191) were ported first, since the compiler needs them; port the rest of the range around
-- them in Go order.

function Checker:GetDiagnostics(ctx, sourceFile)
    return self:getDiagnostics(ctx, sourceFile, self.diagnostics)
end

function Checker:GetSuggestionDiagnostics(ctx, sourceFile)
    return self:getDiagnostics(ctx, sourceFile, self.suggestionDiagnostics)
end

function Checker:getDiagnostics(ctx, sourceFile, collection)
    self:checkNotCanceled()
    local checkUnused = core.Tristate_IsTrue(self.compilerOptions.noUnusedLocals) or core.Tristate_IsTrue(self.compilerOptions.noUnusedParameters) or collection == self.suggestionDiagnostics
    self:checkSourceFile(ctx, sourceFile, checkUnused)
    if self.wasCanceled then
        return nil
    end
    return collection:GetDiagnosticsForFile(sourceFile)
end

function Checker:GetGlobalDiagnostics()
    self:checkNotCanceled()
    return self.diagnostics:GetGlobalDiagnostics()
end

function Checker:addDeferredDiagnostic(callback)
    self.deferredDiagnosticCallbacks = core.Append(self.deferredDiagnosticCallbacks, callback)
end

function Checker:produceDeferredDiagnostics()
    for _, cb in ipairs(self.deferredDiagnosticCallbacks or {}) do
        cb()
    end
    self.deferredDiagnosticCallbacks = nil
end

function Checker:addDiagnostic(diagnostic)
    -- Discard diagnostics created while at the maximum number of recursive TypeToString invocations.
    if self.serializationLevel < checker.maxSerializationLevel then
        return self.diagnostics:Add(diagnostic)
    end
    return diagnostic
end

function Checker:addSuggestionDiagnostic(diagnostic)
    -- Discard diagnostics created while at the maximum number of recursive TypeToString invocations.
    if self.serializationLevel < checker.maxSerializationLevel then
        return self.suggestionDiagnostics:Add(diagnostic)
    end
    return diagnostic
end

function Checker:error(location, message, ...)
    return self:addDiagnostic(checker.NewDiagnosticForNode(location, message, ...))
end

function Checker:errorSkippedOnNoEmit(location, message, ...)
    local diagnostic = self:error(location, message, ...)
    diagnostic:SetSkippedOnNoEmit()
    return diagnostic
end

function Checker:errorOrSuggestion(isError, location, message, ...)
    self:addErrorOrSuggestion(isError, checker.NewDiagnosticForNode(location, message, ...))
end

function Checker:errorAndMaybeSuggestAwait(location, maybeMissingAwait, message, ...)
    local diagnostic = self:error(location, message, ...)
    if maybeMissingAwait then
        diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(location, diagnostics.Did_you_forget_to_use_await))
    end
    return diagnostic
end

function Checker:addErrorOrSuggestion(isError, diagnostic)
    if isError then
        self:addDiagnostic(diagnostic)
    else
        -- Go: suggestion := *diagnostic (shallow struct copy)
        local suggestion = {}
        for k, v in pairs(diagnostic) do
            suggestion[k] = v
        end
        setmetatable(suggestion, getmetatable(diagnostic))
        suggestion:SetCategory(diagnostics.Category.Suggestion)
        self:addSuggestionDiagnostic(suggestion)
    end
end

function Checker:IsDeprecatedDeclaration(declaration)
    return ast.IsDeprecatedDeclarationWithCachedFlags(declaration, self:getCombinedNodeFlagsCached(declaration))
end

function Checker:addDeprecatedSuggestion(location, declarations, deprecatedEntity)
    local diagnostic = checker.NewDiagnosticForNode(location, diagnostics.X_0_is_deprecated, deprecatedEntity)
    return self:addDeprecatedSuggestionWorker(declarations, diagnostic)
end

function Checker:addDeprecatedSuggestionWorker(declarations, diagnostic)
    for _, declaration in ipairs(declarations or {}) do
        local deprecatedTag = ast.GetJSDocDeprecatedTag(declaration)
        if deprecatedTag ~= nil then
            diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(deprecatedTag, diagnostics.The_declaration_was_marked_as_deprecated_here))
            break
        end
    end
    return self:addSuggestionDiagnostic(diagnostic)
end

function Checker:isDeprecatedSymbol(symbol)
    local isDeprecatedDeclaration = function(d)
        return self:IsDeprecatedDeclaration(d)
    end
    local parentSymbol = self:getParentOfSymbol(symbol)
    if parentSymbol ~= nil and core.Len(symbol.declarations) > 1 then
        if parentSymbol.flags & SymbolFlags.Interface ~= 0 then
            return core.Some(symbol.declarations, isDeprecatedDeclaration)
        else
            return core.Every(symbol.declarations, isDeprecatedDeclaration)
        end
    end
    return symbol.valueDeclaration ~= nil and self:IsDeprecatedDeclaration(symbol.valueDeclaration) or core.Len(symbol.declarations) ~= 0 and core.Every(symbol.declarations, isDeprecatedDeclaration)
end

function Checker:hasParseDiagnostics(sourceFile)
    return core.Len(sourceFile:Diagnostics()) > 0
end

function Checker:newSymbol(flags, name)
    self.symbolCount = self.symbolCount + 1
    local result = self.symbolArena:New()
    result.flags = flags | SymbolFlags.Transient
    result.name = name
    return result
end

function Checker:newSymbolEx(flags, name, checkFlags)
    local result = self:newSymbol(flags, name)
    result.checkFlags = checkFlags
    return result
end

function Checker:newParameter(name, t)
    local symbol = self:newSymbol(SymbolFlags.FunctionScopedVariable, name)
    self.valueSymbolLinks:Get(symbol).resolvedType = t
    return symbol
end

function Checker:newProperty(name, t)
    local symbol = self:newSymbol(SymbolFlags.Property, name)
    self.valueSymbolLinks:Get(symbol).resolvedType = t
    return symbol
end
