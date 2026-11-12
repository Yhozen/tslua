local declarations = require("tslua.transformers.declarations")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")

local SymbolFlags = ast.SymbolFlags
local SymbolAccessibility = printer.SymbolAccessibility
local FindAncestorResult = ast.FindAncestorResult

-- SymbolTrackerImpl fields: resolver, state, host, fallbackStack,
-- watchedClassSymbol / classSymbolTracked (for detecting class expression self-references during
-- member serialization: when set, TrackSymbol records usage without reporting accessibility errors),
-- getIsolatedDeclarationError.
local SymbolTrackerImpl = {}
SymbolTrackerImpl.__index = SymbolTrackerImpl
declarations.SymbolTrackerImpl = SymbolTrackerImpl

-- PopErrorFallbackNode implements checker.SymbolTracker.
function SymbolTrackerImpl:PopErrorFallbackNode()
    self.fallbackStack[#self.fallbackStack] = nil
end

-- PushErrorFallbackNode implements checker.SymbolTracker.
function SymbolTrackerImpl:PushErrorFallbackNode(node)
    self.fallbackStack[#self.fallbackStack + 1] = node
end

-- ReportCyclicStructureError implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportCyclicStructureError()
    local location = self:errorLocation()
    if location ~= nil then
        self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_inferred_type_of_0_references_a_type_with_a_cyclic_structure_which_cannot_be_trivially_serialized_A_type_annotation_is_necessary, self:errorDeclarationNameWithFallback()))
    end
end

-- ReportInaccessibleThisError implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportInaccessibleThisError()
    local location = self:errorLocation()
    if location ~= nil then
        self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_inferred_type_of_0_references_an_inaccessible_1_type_A_type_annotation_is_necessary, self:errorDeclarationNameWithFallback(), "this"))
    end
end

-- ReportInaccessibleUniqueSymbolError implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportInaccessibleUniqueSymbolError()
    local location = self:errorLocation()
    if location ~= nil then
        self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_inferred_type_of_0_references_an_inaccessible_1_type_A_type_annotation_is_necessary, self:errorDeclarationNameWithFallback(), "unique symbol"))
    end
end

function SymbolTrackerImpl:isBoundExpando(node)
    if not (ast.IsExpandoPropertyDeclaration(node) and ast.IsPropertyAccessExpression(node:AsBinaryExpression().left)) then
        return false
    end
    local ref = self.resolver:GetReferencedValueDeclarationUnsafe(ast.GetLeftmostExpression(node:AsBinaryExpression().left, true))
    if ref == nil then
        return false
    end
    return self.resolver:IsExpandoFunctionDeclarationUnsafe(ref)
end

function SymbolTrackerImpl:isChildOfBoundExpando(node)
    return ast.FindAncestorOrQuit(node, function(n)
        if ast.IsSourceFile(n) or ast.IsBlock(n) then
            return FindAncestorResult.FindAncestorQuit
        end
        return ast.ToFindAncestorResult(self:isBoundExpando(n))
    end) ~= nil
end

-- ReportInferenceFallback implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportInferenceFallback(node)
    if not self.state.isolatedDeclarations then
        return
    end
    if ast.GetSourceFileOfNode(node) ~= self.state.currentSourceFile then
        return -- Nested error on a declaration in another file - ignore, will be reemitted if file is in the output file set
    end
    if self.state.resolver:IsExpandoFunctionDeclarationUnsafe(node) then -- within a node builder call that should already lock the checker, use the unsafe call
        self.state.reportExpandoFunctionErrors(node)
    end
    if not self:isChildOfBoundExpando(node) then -- expando props get an error when their host is visited by the above, this prevents a follow-on error on a non-inferrable expression
        self.state:addDiagnostic(self.getIsolatedDeclarationError(node))
    end
end

-- ReportLikelyUnsafeImportRequiredError implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportLikelyUnsafeImportRequiredError(specifier, symbolName)
    local location = self:errorLocation()
    if location ~= nil then
        if symbolName ~= nil and symbolName ~= "" then
            self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_inferred_type_of_0_cannot_be_named_without_a_reference_to_2_from_1_This_is_likely_not_portable_A_type_annotation_is_necessary, self:errorDeclarationNameWithFallback(), specifier, symbolName))
        else
            self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_inferred_type_of_0_cannot_be_named_without_a_reference_to_1_This_is_likely_not_portable_A_type_annotation_is_necessary, self:errorDeclarationNameWithFallback(), specifier))
        end
    end
end

-- ReportNonSerializableProperty implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportNonSerializableProperty(propertyName)
    local location = self:errorLocation()
    if location ~= nil then
        self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_type_of_this_node_cannot_be_serialized_because_its_property_0_cannot_be_serialized, propertyName))
    end
end

-- ReportNonlocalAugmentation implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportNonlocalAugmentation(containingFile, parentSymbol, augmentingSymbol)
    local primaryDeclaration = core.Find(parentSymbol.declarations, function(d) return ast.GetSourceFileOfNode(d) == containingFile end)
    local augmentingDeclarations = core.Filter(augmentingSymbol.declarations, function(d) return ast.GetSourceFileOfNode(d) ~= containingFile end)
    if primaryDeclaration ~= nil and core.Len(augmentingDeclarations) > 0 then
        for _, augmentations in ipairs(augmentingDeclarations) do
            local diag = declarations.createDiagnosticForNode(augmentations, diagnostics.Declaration_augments_declaration_in_another_file_This_cannot_be_serialized)
            local related = declarations.createDiagnosticForNode(primaryDeclaration, diagnostics.This_is_the_declaration_being_augmented_Consider_moving_the_augmenting_declaration_into_the_same_file)
            diag:AddRelatedInfo(related)
            self.state:addDiagnostic(diag)
        end
    end
end

-- ReportPrivateInBaseOfClassExpression implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportPrivateInBaseOfClassExpression(propertyName)
    local location = self:errorLocation()
    if location ~= nil then
        local diag = declarations.createDiagnosticForNode(location, diagnostics.Property_0_of_exported_anonymous_class_type_may_not_be_private_or_protected, propertyName)
        if ast.IsVariableDeclaration(location.parent) then
            local related = declarations.createDiagnosticForNode(location, diagnostics.Add_a_type_annotation_to_the_variable_0, self:errorDeclarationNameWithFallback())
            diag:AddRelatedInfo(related)
        end
        self.state:addDiagnostic(diag)
    end
end

-- ReportTruncationError implements checker.SymbolTracker.
function SymbolTrackerImpl:ReportTruncationError()
    local location = self:errorLocation()
    if location ~= nil then
        self.state:addDiagnostic(declarations.createDiagnosticForNode(location, diagnostics.The_inferred_type_of_this_node_exceeds_the_maximum_length_the_compiler_will_serialize_An_explicit_type_annotation_is_needed))
    end
end

function SymbolTrackerImpl:errorFallbackNode()
    if #self.fallbackStack >= 1 then
        return self.fallbackStack[#self.fallbackStack]
    end
    return nil
end

function SymbolTrackerImpl:errorLocation()
    local location = self.state.errorNameNode
    if location == nil then
        location = self:errorFallbackNode()
    end
    return location
end

function SymbolTrackerImpl:errorDeclarationNameWithFallback()
    if self.state.errorNameNode ~= nil then
        return scanner.DeclarationNameToString(self.state.errorNameNode)
    end
    if self:errorFallbackNode() ~= nil and ast.GetNameOfDeclaration(self:errorFallbackNode()) ~= nil then
        return scanner.DeclarationNameToString(ast.GetNameOfDeclaration(self:errorFallbackNode()))
    end
    if self:errorFallbackNode() ~= nil and ast.IsExportAssignment(self:errorFallbackNode()) then
        if self:errorFallbackNode():AsExportAssignment().isExportEquals then
            return "export="
        end
        return "default"
    end
    return "(Missing)" -- same fallback declarationNameToString uses when node is zero-width (ie, nameless)
end

-- TrackSymbol implements checker.SymbolTracker.
function SymbolTrackerImpl:TrackSymbol(symbol, enclosingDeclaration, meaning)
    if symbol.flags & SymbolFlags.TypeParameter ~= 0 then
        return false
    end
    -- When watching for a class expression symbol, record its usage without
    -- reporting accessibility errors — the caller will handle visibility by
    -- wrapping the class in a namespace.
    if self.watchedClassSymbol ~= nil and symbol == self.watchedClassSymbol then
        self.classSymbolTracked = true
        return false
    end
    local issuedDiagnostic = self:handleSymbolAccessibilityError(self.resolver:IsSymbolAccessible(symbol, enclosingDeclaration, meaning, true --[[shouldComputeAliasToMarkVisible]]))
    return issuedDiagnostic
end

function SymbolTrackerImpl:handleSymbolAccessibilityError(symbolAccessibilityResult)
    if symbolAccessibilityResult.accessibility == SymbolAccessibility.Accessible then
        -- Add aliases back onto the possible imports list if they're not there so we can try them again with updated visibility info
        if core.Len(symbolAccessibilityResult.aliasesToMakeVisible) > 0 then
            for _, ref in ipairs(symbolAccessibilityResult.aliasesToMakeVisible) do
                self.state.lateMarkedStatements = core.AppendIfUnique(self.state.lateMarkedStatements, ref)
            end
        end
        -- TODO: Do all these accessibility checks inside/after the first pass in the checker when declarations are enabled, if possible

        -- The checker should issue errors on unresolvable names, skip the declaration emit error for using a private/unreachable name for those
    elseif symbolAccessibilityResult.accessibility ~= SymbolAccessibility.NotResolved then
        -- Report error
        local errorInfo = self.state.getSymbolAccessibilityDiagnostic(symbolAccessibilityResult)
        if errorInfo ~= nil then
            local info = errorInfo
            local diagNode = symbolAccessibilityResult.errorNode
            if diagNode == nil then
                diagNode = errorInfo.errorNode
            end
            local errorSymbolName = symbolAccessibilityResult.errorSymbolName or ""
            local errorModuleName = symbolAccessibilityResult.errorModuleName or ""
            if info.typeName ~= nil then
                self.state:addDiagnostic(declarations.createDiagnosticForNode(diagNode, info.diagnosticMessage, scanner.GetTextOfNode(info.typeName), errorSymbolName, errorModuleName))
            else
                self.state:addDiagnostic(declarations.createDiagnosticForNode(diagNode, info.diagnosticMessage, errorSymbolName, errorModuleName))
            end
            return true
        end
    end
    return false
end

function declarations.createDiagnosticForNode(node, message, ...)
    return checker.NewDiagnosticForNode(node, message, ...)
end

-- SymbolTrackerSharedState fields: lateMarkedStatements, diagnostics, getSymbolAccessibilityDiagnostic,
-- errorNameNode, isolatedDeclarations, stripInternal, currentSourceFile, resolver, reportExpandoFunctionErrors.
local SymbolTrackerSharedState = {}
SymbolTrackerSharedState.__index = SymbolTrackerSharedState
declarations.SymbolTrackerSharedState = SymbolTrackerSharedState

function SymbolTrackerSharedState:addDiagnostic(diag)
    self.diagnostics = core.Append(self.diagnostics, diag)
end

function declarations.NewSymbolTracker(host, resolver, state)
    local tracker = setmetatable({
        host = host,
        resolver = resolver,
        state = state,
        fallbackStack = {},
        watchedClassSymbol = nil,
        classSymbolTracked = false,
        getIsolatedDeclarationError = declarations.createGetIsolatedDeclarationErrors(resolver),
    }, SymbolTrackerImpl)
    return tracker
end
