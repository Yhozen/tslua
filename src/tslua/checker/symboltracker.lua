local checker = require("tslua.checker")
local ast = require("tslua.ast")

local SymbolFlags = ast.SymbolFlags

-- SymbolTrackerImpl implements nodebuilder.SymbolTracker.
local SymbolTrackerImpl = checker.defineStruct("SymbolTrackerImpl", nil, { disableTrackSymbol = false })

function checker.NewSymbolTrackerImpl(context, tracker)
    if tracker ~= nil then
        while true do
            if getmetatable(tracker) ~= SymbolTrackerImpl then
                break
            end
            tracker = tracker.inner
        end
    end

    return checker.SymbolTrackerImpl_new({ context = context, inner = tracker, disableTrackSymbol = false })
end

function SymbolTrackerImpl:TrackSymbol(symbol, enclosingDeclaration, meaning)
    if not self.disableTrackSymbol then
        if self.inner ~= nil and self.inner:TrackSymbol(symbol, enclosingDeclaration, meaning) then
            self:onDiagnosticReported()
            return true
        end
        -- Skip recording type parameters as they dont contribute to late painted statements
        if symbol.flags & SymbolFlags.TypeParameter == 0 then
            local ctx = self.context
            if ctx.trackedSymbols == nil then
                ctx.trackedSymbols = {}
            end
            ctx.trackedSymbols[#ctx.trackedSymbols + 1] = checker.TrackedSymbolArgs_new({
                symbol = symbol,
                enclosingDeclaration = enclosingDeclaration,
                meaning = meaning,
            })
        end
    end
    return false
end

function SymbolTrackerImpl:ReportInaccessibleThisError()
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportInaccessibleThisError()
end

function SymbolTrackerImpl:ReportPrivateInBaseOfClassExpression(propertyName)
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportPrivateInBaseOfClassExpression(propertyName)
end

function SymbolTrackerImpl:ReportInaccessibleUniqueSymbolError()
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportInaccessibleUniqueSymbolError()
end

function SymbolTrackerImpl:ReportCyclicStructureError()
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportCyclicStructureError()
end

function SymbolTrackerImpl:ReportLikelyUnsafeImportRequiredError(specifier, symbolName)
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportLikelyUnsafeImportRequiredError(specifier, symbolName)
end

function SymbolTrackerImpl:ReportTruncationError()
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportTruncationError()
end

function SymbolTrackerImpl:ReportNonlocalAugmentation(containingFile, parentSymbol, augmentingSymbol)
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportNonlocalAugmentation(containingFile, parentSymbol, augmentingSymbol)
end

function SymbolTrackerImpl:ReportNonSerializableProperty(propertyName)
    self:onDiagnosticReported()
    if self.inner == nil then
        return
    end
    self.inner:ReportNonSerializableProperty(propertyName)
end

function SymbolTrackerImpl:onDiagnosticReported()
    self.context.reportedDiagnostic = true
end

function SymbolTrackerImpl:ReportInferenceFallback(node)
    if self.inner == nil then
        return
    end
    self.inner:ReportInferenceFallback(node)
end

function SymbolTrackerImpl:PushErrorFallbackNode(node)
    if self.inner == nil then
        return
    end
    self.inner:PushErrorFallbackNode(node)
end

function SymbolTrackerImpl:PopErrorFallbackNode()
    if self.inner == nil then
        return
    end
    self.inner:PopErrorFallbackNode()
end
