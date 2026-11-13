local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local tracing = require("tslua.tracing")
local jsnum = require("tslua.jsnum")
local stringutil = require("tslua.stringutil")

local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureFlags = checker.SignatureFlags
local SignatureKind = checker.SignatureKind
local SignatureCheckMode = checker.SignatureCheckMode
local MinArgumentCountFlags = checker.MinArgumentCountFlags
local IntersectionState = checker.IntersectionState
local RecursionFlags = checker.RecursionFlags
local RelationComparisonResult = checker.RelationComparisonResult
local Ternary = checker.Ternary
local VarianceFlags = checker.VarianceFlags
local ElementFlags = checker.ElementFlags
local TypePredicateKind = checker.TypePredicateKind
local TypeFormatFlags = checker.TypeFormatFlags
local TypeFacts = checker.TypeFacts
local AccessFlags = checker.AccessFlags
local CheckMode = checker.CheckMode
local UnionReduction = checker.UnionReduction
local IntersectionFlags = checker.IntersectionFlags
local TypeSystemPropertyName = checker.TypeSystemPropertyName
local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local ModifierFlags = ast.ModifierFlags

-- SignatureCheckMode, MinArgumentCountFlags, IntersectionState, RecursionFlags, ExpandingFlags and
-- RelationComparisonResult are generated constants (consts_generated.lua).

-- DiagnosticAndArguments

defineStruct("DiagnosticAndArguments", nil, nil)

-- ErrorOutputContainer

defineStruct("ErrorOutputContainer", nil, { skipLogging = false })

-- ErrorReporter is a function(message, ...).

-- RecursionId: the identity value itself (a node, symbol or type table); Lua table identity gives
-- Go's interface equality.

-- This function exists to constrain the types of values that can be used as recursion IDs.
function checker.asRecursionId(value)
    return value
end

-- Relation

-- resultCount tracks len(results) (Go len of the map).
local Relation = defineStruct("Relation", nil, { resultCount = 0 })

function Relation:get(key)
    if self.results == nil then
        return RelationComparisonResult.None
    end
    local result = self.results[key]
    if result == nil then
        return RelationComparisonResult.None
    end
    return result
end

function Relation:set(key, result)
    if self.results == nil then
        self.results = {}
    end
    if self.results[key] == nil then
        self.resultCount = self.resultCount + 1
    end
    self.results[key] = result
end

function Relation:size()
    return self.resultCount
end

function Checker:isTypeIdenticalTo(source, target)
    return self:isTypeRelatedTo(source, target, self.identityRelation)
end

function Checker:compareTypesIdentical(source, target)
    if self:isTypeRelatedTo(source, target, self.identityRelation) then
        return Ternary.True
    end
    return Ternary.False
end

function Checker:compareTypesAssignableSimple(source, target)
    if self:isTypeRelatedTo(source, target, self.assignableRelation) then
        return Ternary.True
    end
    return Ternary.False
end

function Checker:compareTypesAssignableWorker(source, target, reportErrors) -- luacheck: ignore 212
    if self:isTypeRelatedTo(source, target, self.assignableRelation) then
        return Ternary.True
    end
    return Ternary.False
end

function Checker:compareTypesSubtypeOf(source, target)
    if self:isTypeRelatedTo(source, target, self.subtypeRelation) then
        return Ternary.True
    end
    return Ternary.False
end

function Checker:isTypeAssignableTo(source, target)
    return self:isTypeRelatedTo(source, target, self.assignableRelation)
end

function Checker:isTypeSubtypeOf(source, target)
    return self:isTypeRelatedTo(source, target, self.subtypeRelation)
end

function Checker:isTypeStrictSubtypeOf(source, target)
    return self:isTypeRelatedTo(source, target, self.strictSubtypeRelation)
end

function Checker:isTypeComparableTo(source, target)
    return self:isTypeRelatedTo(source, target, self.comparableRelation)
end

function Checker:areTypesComparable(type1, type2)
    return self:isTypeComparableTo(type1, type2) or self:isTypeComparableTo(type2, type1)
end

function Checker:isTypeRelatedTo(source, target, relation)
    local c = self
    if checker.isFreshLiteralType(source) then
        source = source:AsLiteralType().regularType
    end
    if checker.isFreshLiteralType(target) then
        target = target:AsLiteralType().regularType
    end
    if source == target then
        return true
    end
    if relation ~= c.identityRelation then
        if relation == c.comparableRelation and target.flags & TypeFlags.Never == 0 and c:isSimpleTypeRelatedTo(target, source, relation, nil) or c:isSimpleTypeRelatedTo(source, target, relation, nil) then
            return true
        end
    elseif (source.flags | target.flags) & (TypeFlags.UnionOrIntersection | TypeFlags.IndexedAccess | TypeFlags.Conditional | TypeFlags.Substitution) == 0 then
        -- We have excluded types that may simplify to other forms, so types must have identical flags
        if source.flags ~= target.flags then
            return false
        end
        if source.flags & TypeFlags.Singleton ~= 0 then
            return true
        end
    end
    if source.flags & TypeFlags.Object ~= 0 and target.flags & TypeFlags.Object ~= 0 then
        local id = checker.getRelationKey(source, target, IntersectionState.None, relation == c.identityRelation, false)
        local related = relation:get(id)
        if related ~= RelationComparisonResult.None then
            return related & RelationComparisonResult.Succeeded ~= 0
        end
    end
    if source.flags & TypeFlags.StructuredOrInstantiable ~= 0 or target.flags & TypeFlags.StructuredOrInstantiable ~= 0 then
        return c:checkTypeRelatedTo(source, target, relation, nil --[[errorNode]])
    end
    return false
end

function Checker:isSimpleTypeRelatedTo(source, target, relation, errorReporter)
    local c = self
    local s = source.flags
    local t = target.flags
    if t & TypeFlags.Any ~= 0 or s & TypeFlags.Never ~= 0 or source == c.wildcardType then
        return true
    end
    if t & TypeFlags.Unknown ~= 0 and not (relation == c.strictSubtypeRelation and s & TypeFlags.Any ~= 0) then
        return true
    end
    if t & TypeFlags.Never ~= 0 then
        return false
    end
    if s & TypeFlags.StringLike ~= 0 and t & TypeFlags.String ~= 0 then
        return true
    end
    if s & TypeFlags.StringLiteral ~= 0 and s & TypeFlags.EnumLiteral ~= 0 and t & TypeFlags.StringLiteral ~= 0 and t & TypeFlags.EnumLiteral == 0 and source:AsLiteralType().value == target:AsLiteralType().value then
        return true
    end
    if s & TypeFlags.NumberLike ~= 0 and t & TypeFlags.Number ~= 0 then
        return true
    end
    if s & TypeFlags.NumberLiteral ~= 0 and s & TypeFlags.EnumLiteral ~= 0 and t & TypeFlags.NumberLiteral ~= 0 and t & TypeFlags.EnumLiteral == 0 and source:AsLiteralType().value == target:AsLiteralType().value then
        return true
    end
    if s & TypeFlags.BigIntLike ~= 0 and t & TypeFlags.BigInt ~= 0 then
        return true
    end
    if s & TypeFlags.BooleanLike ~= 0 and t & TypeFlags.Boolean ~= 0 then
        return true
    end
    if s & TypeFlags.ESSymbolLike ~= 0 and t & TypeFlags.ESSymbol ~= 0 then
        return true
    end
    if s & TypeFlags.Enum ~= 0 and t & TypeFlags.Enum ~= 0 and source.symbol.name == target.symbol.name and c:isEnumTypeRelatedTo(source.symbol, target.symbol, errorReporter) then
        return true
    end
    if s & TypeFlags.EnumLiteral ~= 0 and t & TypeFlags.EnumLiteral ~= 0 then
        if s & TypeFlags.Union ~= 0 and t & TypeFlags.Union ~= 0 and c:isEnumTypeRelatedTo(source.symbol, target.symbol, errorReporter) then
            return true
        end
        if s & TypeFlags.Literal ~= 0 and t & TypeFlags.Literal ~= 0 and source:AsLiteralType().value == target:AsLiteralType().value and c:isEnumTypeRelatedTo(source.symbol, target.symbol, errorReporter) then
            return true
        end
    end
    -- In non-strictNullChecks mode, `undefined` and `null` are assignable to anything except `never`.
    -- Since unions and intersections may reduce to `never`, we exclude them here.
    if s & TypeFlags.Undefined ~= 0 and (not c.strictNullChecks and t & TypeFlags.UnionOrIntersection == 0 or t & (TypeFlags.Undefined | TypeFlags.Void) ~= 0) then
        return true
    end
    if s & TypeFlags.Null ~= 0 and (not c.strictNullChecks and t & TypeFlags.UnionOrIntersection == 0 or t & TypeFlags.Null ~= 0) then
        return true
    end
    if s & TypeFlags.Object ~= 0 and t & TypeFlags.NonPrimitive ~= 0 and not (relation == c.strictSubtypeRelation and c:IsEmptyAnonymousObjectType(source) and source.objectFlags & ObjectFlags.FreshLiteral == 0) then
        return true
    end
    if relation == c.assignableRelation or relation == c.comparableRelation then
        if s & TypeFlags.Any ~= 0 then
            return true
        end
        -- Type number is assignable to any computed numeric enum type or any numeric enum literal type, and
        -- a numeric literal type is assignable any computed numeric enum type or any numeric enum literal type
        -- with a matching value. These rules exist such that enums can be used for bit-flag purposes.
        if s & TypeFlags.Number ~= 0 and (t & TypeFlags.Enum ~= 0 or t & TypeFlags.NumberLiteral ~= 0 and t & TypeFlags.EnumLiteral ~= 0) then
            return true
        end
        if s & TypeFlags.NumberLiteral ~= 0 and s & TypeFlags.EnumLiteral == 0 and (t & TypeFlags.Enum ~= 0 or t & TypeFlags.NumberLiteral ~= 0 and t & TypeFlags.EnumLiteral ~= 0 and source:AsLiteralType().value == target:AsLiteralType().value) then
            return true
        end
        -- Anything is assignable to a union containing undefined, null, and {}
        if c:isUnknownLikeUnionType(target) then
            return true
        end
    end
    return false
end

function Checker:isEnumTypeRelatedTo(source, target, errorReporter)
    local c = self
    local sourceSymbol = source
    if source.flags & SymbolFlags.EnumMember ~= 0 then
        sourceSymbol = c:getParentOfSymbol(source)
    end
    local targetSymbol = target
    if target.flags & SymbolFlags.EnumMember ~= 0 then
        targetSymbol = c:getParentOfSymbol(target)
    end
    if sourceSymbol == targetSymbol then
        return true
    end
    if sourceSymbol.name ~= targetSymbol.name or sourceSymbol.flags & SymbolFlags.RegularEnum == 0 or targetSymbol.flags & SymbolFlags.RegularEnum == 0 then
        return false
    end
    local key = checker.EnumRelationKey(ast.GetSymbolId(sourceSymbol), ast.GetSymbolId(targetSymbol))
    local entry = c.enumRelation[key] or RelationComparisonResult.None
    if entry ~= RelationComparisonResult.None and not (entry & RelationComparisonResult.Failed ~= 0 and errorReporter ~= nil) then
        return entry & RelationComparisonResult.Succeeded ~= 0
    end
    local targetEnumType = c:getTypeOfSymbol(targetSymbol)
    for _, sourceProperty in ipairs(c:getPropertiesOfType(c:getTypeOfSymbol(sourceSymbol)) or {}) do
        if sourceProperty.flags & SymbolFlags.EnumMember ~= 0 then
            local targetProperty = c:getPropertyOfType(targetEnumType, sourceProperty.name)
            if targetProperty == nil or targetProperty.flags & SymbolFlags.EnumMember == 0 then
                if errorReporter ~= nil then
                    errorReporter(diagnostics.Property_0_is_missing_in_type_1, c:symbolToString(sourceProperty), c:TypeToStringEx(c:getDeclaredTypeOfSymbol(targetSymbol), nil --[[enclosingDeclaration]], TypeFormatFlags.UseFullyQualifiedType, nil))
                end
                c.enumRelation[key] = RelationComparisonResult.Failed
                return false
            end
            local sourceValue = c:getEnumMemberValue(ast.GetDeclarationOfKind(sourceProperty, Kind.EnumMember)).value
            local targetValue = c:getEnumMemberValue(ast.GetDeclarationOfKind(targetProperty, Kind.EnumMember)).value
            if sourceValue ~= targetValue then
                -- If we have 2 enums with *known* values that differ, they are incompatible.
                if sourceValue ~= nil and targetValue ~= nil then
                    if errorReporter ~= nil then
                        errorReporter(diagnostics.Each_declaration_of_0_1_differs_in_its_value_where_2_was_expected_but_3_was_given, c:symbolToString(targetSymbol), c:symbolToString(targetProperty), c:valueToString(targetValue), c:valueToString(sourceValue))
                    end
                    c.enumRelation[key] = RelationComparisonResult.Failed
                    return false
                end
                -- At this point we know that at least one of the values is 'undefined'.
                -- This may mean that we have an opaque member from an ambient enum declaration,
                -- or that we were not able to calculate it (which is basically an error).
                --
                -- Either way, we can assume that it's numeric.
                -- If the other is a string, we have a mismatch in types.
                local sourceIsString = type(sourceValue) == "string"
                local targetIsString = type(targetValue) == "string"
                if sourceIsString or targetIsString then
                    if errorReporter ~= nil then
                        local knownStringValue = sourceValue
                        if knownStringValue == nil then
                            knownStringValue = targetValue
                        end
                        errorReporter(diagnostics.One_value_of_0_1_is_the_string_2_and_the_other_is_assumed_to_be_an_unknown_numeric_value, c:symbolToString(targetSymbol), c:symbolToString(targetProperty), c:valueToString(knownStringValue))
                    end
                    c.enumRelation[key] = RelationComparisonResult.Failed
                    return false
                end
            end
        end
    end
    c.enumRelation[key] = RelationComparisonResult.Succeeded
    return true
end

function Checker:checkTypeAssignableTo(source, target, errorNode, headMessage)
    return self:checkTypeRelatedToEx(source, target, self.assignableRelation, errorNode, headMessage, nil)
end

function Checker:checkTypeAssignableToEx(source, target, errorNode, headMessage, diagnosticOutput)
    return self:checkTypeRelatedToEx(source, target, self.assignableRelation, errorNode, headMessage, diagnosticOutput)
end

function Checker:checkTypeComparableTo(source, target, errorNode, headMessage)
    return self:checkTypeRelatedToEx(source, target, self.comparableRelation, errorNode, headMessage, nil)
end

function Checker:checkTypeRelatedTo(source, target, relation, errorNode)
    return self:checkTypeRelatedToEx(source, target, relation, errorNode, nil, nil)
end

-- Check that source is related to target according to the given relation. When errorNode is non-nil, errors are
-- reported to the checker's diagnostic collection or through diagnosticOutput when non-nil. Callers can assume that
-- this function only reports zero or one error to diagnosticOutput (unlike checkTypeRelatedToAndOptionallyElaborate).
-- diagnosticOutput is Go's *[]*ast.Diagnostic: a Lua array the diagnostic is appended to, or nil.
function Checker:checkTypeRelatedToEx(source, target, relation, errorNode, headMessage, diagnosticOutput)
    local c = self
    local r = c:getRelater()
    r.relation = relation
    r.errorNode = errorNode
    r.relationCount = (16000000 - relation:size()) // 8
    local result = r:isRelatedToEx(source, target, RecursionFlags.Both, errorNode ~= nil --[[reportErrors]], headMessage, IntersectionState.None)
    if r.overflow then
        -- Record this relation as having failed such that we don't attempt the overflowing operation again.
        local id = checker.getRelationKey(source, target, IntersectionState.None, relation == c.identityRelation, false --[[ignoreConstraints]])
        relation:set(id, RelationComparisonResult.Failed | RelationComparisonResult.ComplexityOverflow)
        local tr = c.tracer
        if tr ~= nil then
            tr:Instant(tracing.PhaseCheckTypes, "checkTypeRelatedTo_DepthLimit", { sourceId = source.id, targetId = target.id, depth = #r.sourceStack, targetDepth = #r.targetStack })
        end
        if errorNode == nil then
            errorNode = c.currentNode
        end
        c:reportDiagnostic(checker.NewDiagnosticForNode(errorNode, diagnostics.Excessive_complexity_comparing_types_0_and_1, c:TypeToString(source), c:TypeToString(target)), diagnosticOutput)
    elseif r.errorChain ~= nil then
        -- Check if we should issue an extra diagnostic to produce a quickfix for a slightly incorrect import statement
        if headMessage ~= nil and errorNode ~= nil and result == Ternary.False and source.symbol ~= nil and c.exportTypeLinks:Has(source.symbol) then
            local links = c.exportTypeLinks:Get(source.symbol)
            if links.originatingImport ~= nil and not ast.IsImportCall(links.originatingImport) then
                local helpfulRetry = c:checkTypeRelatedTo(c:getTypeOfSymbol(links.target), target, relation, nil --[[errorNode]])
                if helpfulRetry then
                    -- Likely an incorrect import. Issue a helpful diagnostic to produce a quickfix to change the import
                    r.relatedInfo = core.Append(r.relatedInfo, checker.createDiagnosticForNode(links.originatingImport, diagnostics.Type_originates_at_this_import_A_namespace_style_import_cannot_be_called_or_constructed_and_will_cause_a_failure_at_runtime_Consider_using_a_default_import_or_import_require_here_instead))
                end
            end
        end
        c:reportDiagnostic(checker.createDiagnosticChainFromErrorChain(r.errorChain, r.errorNode, r.relatedInfo), diagnosticOutput)
    end
    c:putRelater(r)
    return result ~= Ternary.False
end

function checker.createDiagnosticChainFromErrorChain(chain, errorNode, relatedInfo)
    while chain ~= nil and chain.message:ElidedInCompatibilityPyramid() do
        chain = chain.next
    end
    if chain == nil then
        return nil
    end
    local next = checker.createDiagnosticChainFromErrorChain(chain.next, errorNode, relatedInfo)
    local args = chain.args or {}
    if next == nil then
        return checker.NewDiagnosticForNode(errorNode, chain.message, table.unpack(args, 1, args.n or #args)):SetRelatedInfo(relatedInfo)
    end
    return ast.NewDiagnosticChain(next, chain.message, table.unpack(args, 1, args.n or #args))
end

function Checker:reportDiagnostic(diagnostic, diagnosticOutput)
    if diagnostic ~= nil then
        if diagnosticOutput ~= nil then
            diagnosticOutput[#diagnosticOutput + 1] = diagnostic
        else
            self:addDiagnostic(diagnostic)
        end
    end
end

function Checker:checkTypeAssignableToAndOptionallyElaborate(source, target, errorNode, expr, headMessage, diagnosticOutput)
    return self:checkTypeRelatedToAndOptionallyElaborate(source, target, self.assignableRelation, errorNode, expr, headMessage, diagnosticOutput)
end

function Checker:checkTypeRelatedToAndOptionallyElaborate(source, target, relation, errorNode, expr, headMessage, diagnosticOutput)
    if self:isTypeRelatedTo(source, target, relation) then
        return true
    end
    if errorNode ~= nil and not self:elaborateError(expr, source, target, relation, headMessage, diagnosticOutput) then
        return self:checkTypeRelatedToEx(source, target, relation, errorNode, headMessage, diagnosticOutput)
    end
    return false
end

function Checker:elaborateError(node, source, target, relation, headMessage, diagnosticOutput)
    local c = self
    if node == nil or c:isOrHasGenericConditional(target) then
        return false
    end
    if core.Tristate_IsTrue(c.compilerOptions.noCheck) then
        return false
    end
    if c:elaborateDidYouMeanToCallOrConstruct(node, source, target, relation, SignatureKind.Construct, headMessage, diagnosticOutput) or
        c:elaborateDidYouMeanToCallOrConstruct(node, source, target, relation, SignatureKind.Call, headMessage, diagnosticOutput) then
        return true
    end
    local kind = node.kind
    if kind == Kind.AsExpression or kind == Kind.JsxExpression or kind == Kind.ParenthesizedExpression then
        if kind == Kind.AsExpression and not ast.IsConstAssertion(node) then
            return false
        end
        return c:elaborateError(node:Expression(), source, target, relation, headMessage, diagnosticOutput)
    elseif kind == Kind.BinaryExpression then
        local opKind = node:AsBinaryExpression().operatorToken.kind
        if opKind == Kind.EqualsToken or opKind == Kind.CommaToken then
            return c:elaborateError(node:AsBinaryExpression().right, source, target, relation, headMessage, diagnosticOutput)
        end
    elseif kind == Kind.ObjectLiteralExpression then
        return c:elaborateObjectLiteral(node, source, target, relation, diagnosticOutput)
    elseif kind == Kind.ArrayLiteralExpression then
        return c:elaborateArrayLiteral(node, source, target, relation, diagnosticOutput)
    elseif kind == Kind.ArrowFunction then
        return c:elaborateArrowFunction(node, source, target, relation, diagnosticOutput)
    elseif kind == Kind.JsxAttributes then
        return c:elaborateJsxComponents(node, source, target, relation, diagnosticOutput)
    end
    return false
end

function Checker:isOrHasGenericConditional(t)
    return t.flags & TypeFlags.Conditional ~= 0 or (t.flags & TypeFlags.Intersection ~= 0 and core.Some(t:Types(), function(t_)
        return self:isOrHasGenericConditional(t_)
    end))
end

function Checker:elaborateDidYouMeanToCallOrConstruct(node, source, target, relation, kind, headMessage, diagnosticOutput)
    local c = self
    if core.Some(c:getSignaturesOfType(source, kind), function(s)
        local returnType = c:getReturnTypeOfSignature(s)
        return returnType.flags & (TypeFlags.Any | TypeFlags.Never) == 0 and c:checkTypeRelatedTo(returnType, target, relation, nil --[[errorNode]])
    end) then
        local diags = {}
        if not c:checkTypeRelatedToEx(source, target, relation, node, headMessage, diags) then
            local diagnostic = diags[1]
            local message = core.IfElse(kind == SignatureKind.Construct,
                diagnostics.Did_you_mean_to_use_new_with_this_expression,
                diagnostics.Did_you_mean_to_call_this_expression)
            c:reportDiagnostic(diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(node, message)), diagnosticOutput)
            return true
        end
    end
    return false
end

function Checker:elaborateObjectLiteral(node, source, target, relation, diagnosticOutput)
    local c = self
    if target.flags & (TypeFlags.Primitive | TypeFlags.Never) ~= 0 then
        return false
    end
    local reportedError = false
    for _, prop in ipairs(node:Properties() or {}) do
        if ast.IsSpreadAssignment(prop) then
            goto continue
        end
        do
            local nameType = c:getLiteralTypeFromProperty(c:getSymbolOfDeclaration(prop), TypeFlags.StringOrNumberLiteralOrUnique, false)
            if nameType == nil or nameType.flags & TypeFlags.Never ~= 0 then
                goto continue
            end
            local kind = prop.kind
            if kind == Kind.SetAccessor or kind == Kind.GetAccessor or kind == Kind.MethodDeclaration or kind == Kind.ShorthandPropertyAssignment then
                reportedError = c:elaborateElement(source, target, relation, prop:Name(), nil, nameType, nil, nil, diagnosticOutput) or reportedError
            elseif kind == Kind.PropertyAssignment then
                local message = core.IfElse(ast.IsComputedNonLiteralName(prop:Name()), diagnostics.Type_of_computed_property_s_value_is_0_which_is_not_assignable_to_type_1, nil)
                reportedError = c:elaborateElement(source, target, relation, prop:Name(), prop:Initializer(), nameType, message, nil, diagnosticOutput) or reportedError
            end
        end
        ::continue::
    end
    return reportedError
end

function Checker:elaborateArrayLiteral(node, source, target, relation, diagnosticOutput)
    local c = self
    if target.flags & (TypeFlags.Primitive | TypeFlags.Never) ~= 0 then
        return false
    end
    if not c:isTupleLikeType(source) then
        c:pushContextualType(node, target, false --[[isCache]])
        source = c:checkArrayLiteral(node, CheckMode.Contextual | CheckMode.ForceTuple)
        c:popContextualType()
        if not c:isTupleLikeType(source) then
            return false
        end
    end
    local reportedError = false
    for i1, element in ipairs(node:Elements() or {}) do
        local i = i1 - 1
        if ast.IsOmittedExpression(element) or c:isTupleLikeType(target) and c:getPropertyOfType(target, jsnum.Number_String(i + 0.0)) == nil then
            goto continue
        end
        do
            local nameType = c:getNumberLiteralType(i + 0.0)
            local checkNode = c:getEffectiveCheckNode(element)
            reportedError = c:elaborateElement(source, target, relation, checkNode, checkNode, nameType, nil, nil, diagnosticOutput) or reportedError
        end
        ::continue::
    end
    return reportedError
end

function Checker:elaborateElement(source, target, relation, prop, next, nameType, errorMessage, diagnosticFactory, diagnosticOutput)
    local c = self
    local targetPropType = c:getBestMatchIndexedAccessTypeOrUndefined(source, target, nameType)
    if targetPropType == nil or targetPropType.flags & TypeFlags.IndexedAccess ~= 0 then
        -- Don't elaborate on indexes on generic variables
        return false
    end
    local sourcePropType = c:getIndexedAccessTypeOrUndefined(source, nameType, AccessFlags.None, nil, nil)
    if sourcePropType == nil or c:checkTypeRelatedTo(sourcePropType, targetPropType, relation, nil --[[errorNode]]) then
        -- Don't elaborate on indexes on generic variables or when types match
        return false
    end
    if next ~= nil and c:elaborateError(next, sourcePropType, targetPropType, relation, nil --[[headMessage]], diagnosticOutput) then
        return true
    end
    -- Issue error on the prop itself, since the prop couldn't elaborate the error
    local diags = {}
    -- Use the expression type, if available
    local specificSource = sourcePropType
    if next ~= nil then
        specificSource = c:checkExpressionForMutableLocationWithContextualType(next, sourcePropType)
    end
    if diagnosticFactory ~= nil then
        -- Use the custom diagnostic factory if provided (e.g., for JSX text children with dynamic error messages)
        diags[#diags + 1] = diagnosticFactory(prop)
    elseif c.exactOptionalPropertyTypes and c:isExactOptionalPropertyMismatch(specificSource, targetPropType) then
        diags[#diags + 1] = checker.createDiagnosticForNode(prop, diagnostics.Type_0_is_not_assignable_to_type_1_with_exactOptionalPropertyTypes_Colon_true_Consider_adding_undefined_to_the_type_of_the_target, c:TypeToString(specificSource), c:TypeToString(targetPropType))
    else
        local propName = c:getPropertyNameFromIndex(nameType, nil --[[accessNode]])
        local targetIsOptional = (c:getPropertyOfType(target, propName) or c.unknownSymbol).flags & SymbolFlags.Optional ~= 0
        local sourceIsOptional = (c:getPropertyOfType(source, propName) or c.unknownSymbol).flags & SymbolFlags.Optional ~= 0
        targetPropType = c:removeMissingType(targetPropType, targetIsOptional)
        sourcePropType = c:removeMissingType(sourcePropType, targetIsOptional and sourceIsOptional)
        local result = c:checkTypeRelatedToEx(specificSource, targetPropType, relation, prop, errorMessage, diags)
        if result and specificSource ~= sourcePropType then
            -- If for whatever reason the expression type doesn't yield an error, make sure we still issue an error on the sourcePropType
            c:checkTypeRelatedToEx(sourcePropType, targetPropType, relation, prop, errorMessage, diags)
        end
    end
    if #diags == 0 then
        return false
    end
    local diagnostic = diags[1]
    local propertyName = ""
    local targetProp
    if checker.isTypeUsableAsPropertyName(nameType) then
        propertyName = checker.getPropertyNameFromType(nameType)
        targetProp = c:getPropertyOfType(target, propertyName)
    end
    local issuedElaboration = false
    if targetProp == nil then
        local indexInfo = c:getApplicableIndexInfo(target, nameType)
        if indexInfo ~= nil and indexInfo.declaration ~= nil and not c.program:IsSourceFileDefaultLibrary(ast.GetSourceFileOfNode(indexInfo.declaration):Path()) then
            issuedElaboration = true
            diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(indexInfo.declaration, diagnostics.The_expected_type_comes_from_this_index_signature))
        end
    end
    if not issuedElaboration and (targetProp ~= nil and core.Len(targetProp.declarations) ~= 0 or target.symbol ~= nil and core.Len(target.symbol.declarations) ~= 0) then
        local targetNode
        if targetProp ~= nil and core.Len(targetProp.declarations) ~= 0 then
            targetNode = targetProp.declarations[1]
        else
            targetNode = target.symbol.declarations[1]
        end
        if propertyName == "" or nameType.flags & TypeFlags.UniqueESSymbol ~= 0 then
            propertyName = c:TypeToString(nameType)
        end
        if not c.program:IsSourceFileDefaultLibrary(ast.GetSourceFileOfNode(targetNode):Path()) then
            diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(targetNode, diagnostics.The_expected_type_comes_from_property_0_which_is_declared_here_on_type_1, propertyName, c:TypeToString(target)))
        end
    end
    c:reportDiagnostic(diagnostic, diagnosticOutput)
    return true
end

function Checker:getBestMatchIndexedAccessTypeOrUndefined(source, target, nameType)
    local c = self
    local idx = c:getIndexedAccessTypeOrUndefined(target, nameType, AccessFlags.None, nil, nil)
    if idx ~= nil then
        return idx
    end
    if target.flags & TypeFlags.Union ~= 0 then
        local best = c:getBestMatchingType(source, target, function(s, t)
            return c:compareTypesAssignableSimple(s, t)
        end)
        if best ~= nil then
            return c:getIndexedAccessTypeOrUndefined(best, nameType, AccessFlags.None, nil, nil)
        end
    end
    return nil
end

function Checker:checkExpressionForMutableLocationWithContextualType(next, sourcePropType)
    self:pushContextualType(next, sourcePropType, false --[[isCache]])
    local result = self:checkExpressionForMutableLocation(next, CheckMode.Contextual)
    self:popContextualType()
    return result
end

function Checker:elaborateArrowFunction(node, source, target, relation, diagnosticOutput)
    local c = self
    -- Don't elaborate blocks or functions with annotated parameter types
    if ast.IsBlock(node:Body()) or core.Some(node:Parameters(), checker.hasType) then
        return false
    end
    local sourceSig = c:getSingleCallSignature(source)
    if sourceSig == nil then
        return false
    end
    local targetSignatures = c:getSignaturesOfType(target, SignatureKind.Call)
    if core.Len(targetSignatures) == 0 then
        return false
    end
    local returnExpression = node:Body()
    local sourceReturn = c:getReturnTypeOfSignature(sourceSig)
    local targetReturn = c:getUnionType(core.Map(targetSignatures, function(s)
        return c:getReturnTypeOfSignature(s)
    end))
    if c:checkTypeRelatedTo(sourceReturn, targetReturn, relation, nil --[[errorNode]]) then
        return false
    end
    if returnExpression ~= nil and c:elaborateError(returnExpression, sourceReturn, targetReturn, relation, nil --[[headMessage]], diagnosticOutput) then
        return true
    end
    local diags = {}
    c:checkTypeRelatedToEx(sourceReturn, targetReturn, relation, returnExpression, nil --[[headMessage]], diags)
    if #diags ~= 0 then
        local diagnostic = diags[1]
        if target.symbol ~= nil and core.Len(target.symbol.declarations) ~= 0 then
            diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(target.symbol.declarations[1], diagnostics.The_expected_type_comes_from_the_return_type_of_this_signature))
        end
        if ast.GetFunctionFlags(node) & ast.FunctionFlags.Async == 0 and c:getTypeOfPropertyOfType(sourceReturn, "then") == nil and c:checkTypeRelatedTo(c:createPromiseType(sourceReturn), targetReturn, relation, nil --[[errorNode]]) then
            diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(node, diagnostics.Did_you_mean_to_mark_this_function_as_async))
        end
        c:reportDiagnostic(diagnostic, diagnosticOutput)
        return true
    end
    return false
end

-- A type is 'weak' if it is an object type with at least one optional property
-- and no required properties, call/construct signatures or index signatures
function Checker:isWeakType(t)
    local c = self
    if t.flags & TypeFlags.Object ~= 0 then
        local resolved = c:resolveStructuredTypeMembers(t)
        return core.Len(resolved.signatures) == 0 and core.Len(resolved.indexInfos) == 0 and core.Len(resolved.properties) > 0 and core.Every(resolved.properties, function(p)
            return p.flags & SymbolFlags.Optional ~= 0
        end)
    end
    if t.flags & TypeFlags.Substitution ~= 0 then
        return c:isWeakType(t:AsSubstitutionType().baseType)
    end
    if t.flags & TypeFlags.Intersection ~= 0 then
        return core.Every(t:Types(), function(t_)
            return c:isWeakType(t_)
        end)
    end
    return false
end

function Checker:hasCommonProperties(source, target, isComparingJsxAttributes)
    for _, prop in ipairs(self:getPropertiesOfType(source) or {}) do
        if self:isKnownProperty(target, prop.name, isComparingJsxAttributes) then
            return true
        end
    end
    return false
end

--[[
 * Check if a property with the given name is known anywhere in the given type. In an object type, a property
 * is considered known if
 * 1. the object type is empty and the check is for assignability, or
 * 2. if the object type has index signatures, or
 * 3. if the property is actually declared in the object type
 *    (this means that 'toString', for example, is not usually a known property).
 * 4. In a union or intersection type,
 *    a property is considered known if it is known in any constituent type.
 * @param targetType a type to search a given name in
 * @param name a property name to search
 * @param isComparingJsxAttributes a boolean flag indicating whether we are searching in JsxAttributesType
]]
function Checker:isKnownProperty(targetType, name, isComparingJsxAttributes)
    local c = self
    if targetType.flags & TypeFlags.Object ~= 0 then
        -- For backwards compatibility a symbol-named property is satisfied by a string index signature. This
        -- is incorrect and inconsistent with element access expressions, where it is an error, so eventually
        -- we should remove this exception.
        if c:getPropertyOfObjectType(targetType, name) ~= nil or
            c:getApplicableIndexInfoForName(targetType, name) ~= nil or
            checker.isLateBoundName(name) and c:getIndexInfoOfType(targetType, c.stringType) ~= nil or
            isComparingJsxAttributes and checker.isHyphenatedJsxName(name) then
            -- For JSXAttributes, if the attribute has a hyphenated name, consider that the attribute to be known.
            return true
        end
    end
    if targetType.flags & TypeFlags.Substitution ~= 0 then
        return c:isKnownProperty(targetType:AsSubstitutionType().baseType, name, isComparingJsxAttributes)
    end
    if targetType.flags & TypeFlags.UnionOrIntersection ~= 0 and checker.isExcessPropertyCheckTarget(targetType) then
        for _, t in ipairs(targetType:Types()) do
            if c:isKnownProperty(t, name, isComparingJsxAttributes) then
                return true
            end
        end
    end
    return false
end

function checker.isHyphenatedJsxName(name)
    return string.find(name, "-", 1, true) ~= nil
end

function checker.isExcessPropertyCheckTarget(t)
    return t.flags & TypeFlags.Object ~= 0 and t.objectFlags & ObjectFlags.ObjectLiteralPatternWithComputedProperties == 0 or
        t.flags & TypeFlags.NonPrimitive ~= 0 or
        t.flags & TypeFlags.Substitution ~= 0 and checker.isExcessPropertyCheckTarget(t:AsSubstitutionType().baseType) or
        t.flags & TypeFlags.Union ~= 0 and core.Some(t:Types(), checker.isExcessPropertyCheckTarget) or
        t.flags & TypeFlags.Intersection ~= 0 and core.Every(t:Types(), checker.isExcessPropertyCheckTarget)
end

-- Return true if the given type is deeply nested. We consider this to be the case when the given stack contains
-- maxDepth or more occurrences of types with the same recursion identity as the given type. The recursion identity
-- provides a shared identity for type instantiations that repeat in some (possibly infinite) pattern. For example,
-- in `type Deep<T> = { next: Deep<Deep<T>> }`, repeatedly referencing the `next` property leads to an infinite
-- sequence of ever deeper instantiations with the same recursion identity (in this case the symbol associated with
-- the object type literal).
-- A homomorphic mapped type is considered deeply nested if its target type is deeply nested, and an intersection is
-- considered deeply nested if any constituent of the intersection is deeply nested.
-- It is possible, though highly unlikely, for the deeply nested check to be true in a situation where a chain of
-- instantiations is not infinitely expanding. Effectively, we will generate a false positive when two types are
-- structurally equal to at least maxDepth levels, but unequal at some level beyond that.
function Checker:isDeeplyNestedType(t, stack, maxDepth)
    if core.Len(stack) >= maxDepth then
        local target = checker.getRecursionIdentityTarget(t)
        if target.flags & TypeFlags.Intersection ~= 0 then
            for _, t_ in ipairs(target:Types()) do
                if self:isDeeplyNestedType(t_, stack, maxDepth) then
                    return true
                end
            end
        else
            local identity = checker.getRecursionIdentityFromTarget(target)
            local count = 0
            local lastTypeId = 0
            for _, t_ in ipairs(stack) do
                if checker.hasMatchingRecursionIdentity(t_, identity) then
                    -- We only count occurrences with a higher type id than the previous occurrence, since higher
                    -- type ids are an indicator of newer instantiations caused by recursion.
                    if t_.id >= lastTypeId then
                        count = count + 1
                        if count >= maxDepth then
                            return true
                        end
                    end
                    lastTypeId = t_.id
                end
            end
        end
    end
    return false
end

function checker.hasMatchingRecursionIdentity(t, identity)
    local target = checker.getRecursionIdentityTarget(t)
    if target.flags & TypeFlags.Intersection ~= 0 then
        for _, t_ in ipairs(target:Types()) do
            if checker.hasMatchingRecursionIdentity(t_, identity) then
                return true
            end
        end
        return false
    end
    return checker.getRecursionIdentityFromTarget(target) == identity
end

function checker.getRecursionIdentity(t)
    return checker.getRecursionIdentityFromTarget(checker.getRecursionIdentityTarget(t))
end

-- Get the recursion identity target type from a type. Recursively (a) obtain the target object type of an
-- indexed access (i.e. the T in T[K]), and (b) unwrap nested homomorphic mapped types and return the deepest
-- target type that has a symbol. The unwrapping better preserves unique type identities for mapped types applied
-- to explicitly written object literals. For example in `Mapped<{ x: Mapped<{ x: Mapped<{ x: string }>}>}>`,
-- each of the mapped type applications will have a unique recursion identity (that of their target object type
-- literal) and thus avoid appearing deeply nested.
function checker.getRecursionIdentityTarget(t)
    if t.flags & TypeFlags.IndexedAccess ~= 0 then
        return checker.getRecursionIdentityTarget(t:AsIndexedAccessType().objectType)
    end
    if t.objectFlags & ObjectFlags.InstantiatedMapped == ObjectFlags.InstantiatedMapped then
        local target = t.checker:getModifiersTypeFromMappedType(t)
        if target ~= nil and (target.symbol ~= nil or target.flags & TypeFlags.Intersection ~= 0 and
            core.Some(target:Types(), function(t_) return t_.symbol ~= nil end)) then
            return checker.getRecursionIdentityTarget(target)
        end
    end
    return t
end

-- The recursion identity of a type is an object identity that is shared among multiple instantiations of the type.
-- We track recursion identities in order to identify deeply nested and possibly infinite type instantiations with
-- the same origin. For example, when type parameters are in scope in an object type such as { x: T }, all
-- instantiations of that type have the same recursion identity. The default recursion identity is the object
-- identity of the type, meaning that every type is unique. Generally, types with constituents that could circularly
-- reference the type have a recursion identity that differs from the object identity.
function checker.getRecursionIdentityFromTarget(t)
    -- Object and array literals are known not to contain recursive references and don't need a recursion identity.
    if t.flags & TypeFlags.Object ~= 0 and not checker.isObjectOrArrayLiteralType(t) then
        if t.objectFlags & ObjectFlags.Reference ~= 0 and t:AsTypeReference().node ~= nil then
            -- Deferred type references are tracked through their associated AST node. This gives us finer
            -- granularity than using their associated target because each manifest type reference has a
            -- unique AST node.
            return checker.asRecursionId(t:AsTypeReference().node)
        end
        if t.symbol ~= nil and not (t.objectFlags & ObjectFlags.Anonymous ~= 0 and t.symbol.flags & SymbolFlags.Class ~= 0) and t.objectFlags & checker.ObjectFlagsFromTypeNode == 0 then
            -- We track object types that have a symbol by that symbol (representing the origin of the type), but
            -- exclude the static sides of classes (since they share their symbols with the instance sides) and type
            -- references that originate in resolution of AST type nodes (since such type nodes cannot be the source
            -- of generative recursion without first being instantiated).
            return checker.asRecursionId(t.symbol)
        end
        if checker.isTupleType(t) and t.objectFlags & checker.ObjectFlagsFromTypeNode == 0 then
            return checker.asRecursionId(t:Target())
        end
    end
    if t.flags & TypeFlags.TypeParameter ~= 0 and t.symbol ~= nil then
        -- We use the symbol of the type parameter such that all "fresh" instantiations of that type parameter
        -- have the same recursion identity.
        return checker.asRecursionId(t.symbol)
    end
    if t.flags & TypeFlags.Conditional ~= 0 then
        -- The root object represents the origin of the conditional type
        return checker.asRecursionId(t:AsConditionalType().root.node)
    end
    return checker.asRecursionId(t)
end

function Checker:getBestMatchingType(source, target, isRelatedTo)
    local c = self
    local t = c:findMatchingDiscriminantType(source, target, isRelatedTo)
    if t ~= nil then
        return t
    end
    t = c:findMatchingTypeReferenceOrTypeAliasReference(source, target)
    if t ~= nil then
        return t
    end
    t = c:findBestTypeForObjectLiteral(source, target)
    if t ~= nil then
        return t
    end
    t = c:findBestTypeForInvokable(source, target, SignatureKind.Call)
    if t ~= nil then
        return t
    end
    t = c:findBestTypeForInvokable(source, target, SignatureKind.Construct)
    if t ~= nil then
        return t
    end
    return c:findMostOverlappyType(source, target)
end

function Checker:findMatchingTypeReferenceOrTypeAliasReference(source, unionTarget) -- luacheck: ignore 212
    local sourceObjectFlags = source.objectFlags
    if sourceObjectFlags & (ObjectFlags.Reference | ObjectFlags.Anonymous) ~= 0 and unionTarget.flags & TypeFlags.Union ~= 0 then
        for _, target in ipairs(unionTarget:Types()) do
            if target.flags & TypeFlags.Object ~= 0 then
                local overlapObjFlags = sourceObjectFlags & target.objectFlags
                if overlapObjFlags & ObjectFlags.Reference ~= 0 and source:Target() == target:Target() then
                    return target
                end
                if overlapObjFlags & ObjectFlags.Anonymous ~= 0 and source.alias ~= nil and target.alias ~= nil and source.alias.symbol == target.alias.symbol then
                    return target
                end
            end
        end
    end
    return nil
end

function Checker:findBestTypeForInvokable(source, unionTarget, kind)
    local c = self
    if core.Len(c:getSignaturesOfType(source, kind)) ~= 0 then
        return core.Find(unionTarget:Types(), function(t)
            return core.Len(c:getSignaturesOfType(t, kind)) ~= 0
        end)
    end
    return nil
end

function Checker:findMostOverlappyType(source, unionTarget)
    local c = self
    local bestMatch
    if source.flags & (TypeFlags.Primitive | TypeFlags.InstantiablePrimitive) == 0 then
        local matchingCount = 0
        for _, target in ipairs(unionTarget:Types()) do
            if target.flags & (TypeFlags.Primitive | TypeFlags.InstantiablePrimitive) == 0 then
                local overlap = c:getIntersectionType({ c:getIndexType(source), c:getIndexType(target) })
                if overlap.flags & TypeFlags.Index ~= 0 then
                    -- perfect overlap of keys
                    return target
                elseif checker.isUnitType(overlap) or overlap.flags & TypeFlags.Union ~= 0 then
                    -- We only want to account for literal types otherwise.
                    -- If we have a union of index types, it seems likely that we
                    -- needed to elaborate between two generic mapped types anyway.
                    local length = 1
                    if overlap.flags & TypeFlags.Union ~= 0 then
                        length = core.CountWhere(overlap:Types(), checker.isUnitType)
                    end
                    if length >= matchingCount then
                        bestMatch = target
                        matchingCount = length
                    end
                end
            end
        end
    end
    return bestMatch
end

function Checker:findBestTypeForObjectLiteral(source, unionTarget)
    local c = self
    if source.objectFlags & ObjectFlags.ObjectLiteral ~= 0 and checker.someType(unionTarget, function(t) return c:isArrayLikeType(t) end) then
        return core.Find(unionTarget:Types(), function(t)
            return not c:isArrayLikeType(t)
        end)
    end
    return nil
end

function Checker:shouldReportUnmatchedPropertyError(source, target)
    local c = self
    local typeCallSignatures = c:getSignaturesOfStructuredType(source, SignatureKind.Call)
    local typeConstructSignatures = c:getSignaturesOfStructuredType(source, SignatureKind.Construct)
    local typeProperties = c:getPropertiesOfObjectType(source)
    if (core.Len(typeCallSignatures) ~= 0 or core.Len(typeConstructSignatures) ~= 0) and core.Len(typeProperties) == 0 then
        if (core.Len(c:getSignaturesOfType(target, SignatureKind.Call)) ~= 0 and core.Len(typeCallSignatures) ~= 0) or
            core.Len(c:getSignaturesOfType(target, SignatureKind.Construct)) ~= 0 and core.Len(typeConstructSignatures) ~= 0 then
            -- target has similar signature kinds to source, still focus on the unmatched property
            return true
        end
        return false
    end
    return true
end

function Checker:getUnmatchedProperty(source, target, requireOptionalProperties, matchDiscriminantProperties)
    return self:getUnmatchedPropertiesWorker(source, target, requireOptionalProperties, matchDiscriminantProperties, nil)
end

function Checker:getUnmatchedProperties(source, target, requireOptionalProperties, matchDiscriminantProperties)
    local props = {}
    self:getUnmatchedPropertiesWorker(source, target, requireOptionalProperties, matchDiscriminantProperties, props)
    if #props == 0 then
        return nil
    end
    return props
end

-- propsOut is Go's *[]*ast.Symbol: a Lua array the properties are appended to, or nil.
function Checker:getUnmatchedPropertiesWorker(source, target, requireOptionalProperties, matchDiscriminantProperties, propsOut)
    local c = self
    local properties = c:getPropertiesOfType(target)
    for _, targetProp in ipairs(properties or {}) do
        -- TODO: remove this when we support static private identifier fields and find other solutions to get privateNamesAndStaticFields test to pass
        if checker.isStaticPrivateIdentifierProperty(targetProp) then
            goto continue
        end
        if requireOptionalProperties or targetProp.flags & SymbolFlags.Optional == 0 and targetProp.checkFlags & CheckFlags.Partial == 0 then
            local sourceProp = c:getPropertyOfType(source, targetProp.name)
            if sourceProp == nil then
                if propsOut == nil then
                    return targetProp
                end
                propsOut[#propsOut + 1] = targetProp
            elseif matchDiscriminantProperties then
                local targetType = c:getTypeOfSymbol(targetProp)
                if targetType.flags & TypeFlags.Unit ~= 0 then
                    local sourceType = c:getTypeOfSymbol(sourceProp)
                    if not (sourceType.flags & TypeFlags.Any ~= 0 or c:getRegularTypeOfLiteralType(sourceType) == c:getRegularTypeOfLiteralType(targetType)) then
                        if propsOut == nil then
                            return targetProp
                        end
                        propsOut[#propsOut + 1] = targetProp
                    end
                end
            end
        end
        ::continue::
    end
    return nil
end

-- excludedProperties is a collections.Set (or nil for Go's zero Set).
function checker.excludeProperties(properties, excludedProperties)
    if collections.Set.Len(excludedProperties) == 0 or core.Len(properties) == 0 then
        return properties
    end
    local reduced
    local excluded = false
    for i1, prop in ipairs(properties) do
        local i = i1 - 1
        if not collections.Set.Has(excludedProperties, prop.name) then
            if excluded then
                reduced = core.Append(reduced, prop)
            end
        elseif not excluded then
            reduced = core.Slice(properties, 0, i)
            excluded = true
        end
    end
    if excluded then
        return reduced
    end
    return properties
end

-- TypeDiscriminator

local TypeDiscriminator = defineStruct("TypeDiscriminator", nil, nil)

function TypeDiscriminator:len()
    return core.Len(self.props)
end

function TypeDiscriminator:name(index)
    return self.props[index + 1].name
end

function TypeDiscriminator:matches(index, t)
    local propType = self.c:getTypeOfSymbol(self.props[index + 1])
    for _, s in ipairs(propType:Distributed() or {}) do
        if self.isRelatedTo(s, t) ~= Ternary.False then
            return true
        end
    end
    return false
end

-- Keep this up-to-date with the same logic within `getApparentTypeOfContextualType`, since they should behave similarly
function Checker:findMatchingDiscriminantType(source, target, isRelatedTo)
    local c = self
    if target.flags & TypeFlags.Union ~= 0 and source.flags & (TypeFlags.Intersection | TypeFlags.Object) ~= 0 then
        local match = c:getMatchingUnionConstituentForType(target, source)
        if match ~= nil then
            return match
        end
        local discriminantProperties = c:findDiscriminantProperties(c:getPropertiesOfType(source), target)
        if core.Len(discriminantProperties) ~= 0 then
            local discriminator = checker.TypeDiscriminator_new({ c = c, props = discriminantProperties, isRelatedTo = isRelatedTo })
            local discriminated = c:discriminateTypeByDiscriminableItems(target, discriminator)
            if discriminated ~= target then
                return discriminated
            end
        end
    end
    return nil
end

function Checker:findDiscriminantProperties(sourceProperties, target)
    local result
    for _, sourceProperty in ipairs(sourceProperties or {}) do
        if self:isDiscriminantProperty(target, sourceProperty.name) then
            result = core.Append(result, sourceProperty)
        end
    end
    return result
end

function Checker:isDiscriminantProperty(t, name)
    local c = self
    if t ~= nil and t.flags & TypeFlags.Union ~= 0 then
        local prop = c:getUnionOrIntersectionProperty(t, name, false --[[skipObjectFunctionPropertyAugment]])
        if prop ~= nil and prop.checkFlags & CheckFlags.SyntheticProperty ~= 0 then
            if prop.checkFlags & CheckFlags.IsDiscriminantComputed == 0 then
                prop.checkFlags = prop.checkFlags | CheckFlags.IsDiscriminantComputed
                if prop.checkFlags & CheckFlags.NonUniformAndLiteral == CheckFlags.NonUniformAndLiteral and not c:isGenericType(c:getTypeOfSymbol(prop)) then
                    prop.checkFlags = prop.checkFlags | CheckFlags.IsDiscriminant
                end
            end
            return prop.checkFlags & CheckFlags.IsDiscriminant ~= 0
        end
    end
    return false
end

function Checker:getMatchingUnionConstituentForType(unionType, t)
    local keyPropertyName = self:getKeyPropertyName(unionType)
    if keyPropertyName == "" then
        return nil
    end
    local propType = self:getTypeOfPropertyOfType(t, keyPropertyName)
    if propType == nil then
        return nil
    end
    return self:getConstituentTypeForKeyType(unionType, propType)
end

-- Return the name of a discriminant property for which it was possible and feasible to construct a map of
-- constituent types keyed by the literal types of the property by that name in each constituent type. Return
-- an empty string if no such discriminant property exists.
function Checker:getKeyPropertyName(t)
    local u = t:AsUnionType()
    if u.keyPropertyName == "" then
        u.keyPropertyName, u.constituentMap = self:computeKeyPropertyNameAndMap(t)
    end
    if u.keyPropertyName == ast.InternalSymbolNameMissing then
        return ""
    end
    return u.keyPropertyName
end

-- Given a union type for which getKeyPropertyName returned a non-empty string, return the constituent
-- that corresponds to the given key type for that property name.
function Checker:getConstituentTypeForKeyType(t, keyType)
    local constituentMap = t:AsUnionType().constituentMap
    local result
    if constituentMap ~= nil then
        result = constituentMap[self:getRegularTypeOfLiteralType(keyType)]
    end
    if result ~= self.unknownType then
        return result
    end
    return nil
end

function Checker:computeKeyPropertyNameAndMap(t)
    local types = t:Types()
    if #types < 10 or t.objectFlags & ObjectFlags.PrimitiveUnion ~= 0 or core.CountWhere(types, checker.isObjectOrInstantiableNonPrimitive) < 10 then
        return ast.InternalSymbolNameMissing, nil
    end
    local keyPropertyName = self:getKeyPropertyCandidateName(types)
    if keyPropertyName == "" then
        return ast.InternalSymbolNameMissing, nil
    end
    local mapByKeyProperty = self:mapTypesByKeyProperty(types, keyPropertyName)
    if mapByKeyProperty == nil then
        return ast.InternalSymbolNameMissing, nil
    end
    return keyPropertyName, mapByKeyProperty
end

function checker.isObjectOrInstantiableNonPrimitive(t)
    return t.flags & (TypeFlags.Object | TypeFlags.InstantiableNonPrimitive) ~= 0
end

function Checker:getKeyPropertyCandidateName(types)
    for _, t in ipairs(types) do
        if t.flags & (TypeFlags.Object | TypeFlags.InstantiableNonPrimitive) ~= 0 then
            for _, p in ipairs(self:getPropertiesOfType(t) or {}) do
                if checker.isUnitType(self:getTypeOfSymbol(p)) then
                    return p.name
                end
            end
        end
    end
    return ""
end

-- Given a set of constituent types and a property name, create and return a map keyed by the literal
-- types of the property by that name in each constituent type. No map is returned if some key property
-- has a non-literal type or if less than 10 or less than 50% of the constituents have a unique key.
-- Entries with duplicate keys have unknownType as the value.
function Checker:mapTypesByKeyProperty(types, keyPropertyName)
    local c = self
    local typesByKey = {}
    local count = 0
    for _, t in ipairs(types) do
        if t.flags & (TypeFlags.Object | TypeFlags.Intersection | TypeFlags.InstantiableNonPrimitive) ~= 0 then
            local discriminant = c:getTypeOfPropertyOfType(t, keyPropertyName)
            if discriminant == nil or not checker.isLiteralType(discriminant) then
                return nil
            end
            local duplicate = false
            for _, d in ipairs(discriminant:Distributed() or {}) do
                local key = c:getRegularTypeOfLiteralType(d)
                local existing = typesByKey[key]
                if existing == nil then
                    typesByKey[key] = t
                elseif existing ~= c.unknownType then
                    typesByKey[key] = c.unknownType
                    duplicate = true
                end
            end
            if not duplicate then
                count = count + 1
            end
        end
    end
    if count >= 10 and count * 2 >= #types then
        return typesByKey
    end
    return nil
end

-- Discriminator is an interface: a table with methods len(), name(index) and matches(index, t).

function Checker:discriminateTypeByDiscriminableItems(target, discriminator)
    local c = self
    local types = target:Types()
    local include = {}
    for i, t in ipairs(types) do
        include[i] = Ternary.False
        if t.flags & TypeFlags.Primitive == 0 and c:getReducedType(t).flags & TypeFlags.Never == 0 then
            include[i] = Ternary.True
        end
    end
    for n = 0, discriminator:len() - 1 do
        -- If the remaining target types include at least one with a matching discriminant, eliminate those that
        -- have non-matching discriminants. This ensures that we ignore erroneous discriminators and gradually
        -- refine the target set without eliminating every constituent (which would lead to `never`).
        local matched = false
        for i = 1, #types do
            if include[i] ~= Ternary.False then
                local targetType = c:getTypeOfPropertyOrIndexSignatureOfType(types[i], discriminator:name(n))
                if targetType ~= nil then
                    if discriminator:matches(n, targetType) then
                        matched = true
                    else
                        include[i] = Ternary.Maybe
                    end
                end
            end
        end
        -- Turn each Ternary.Maybe into Ternary.False if there was a match. Otherwise, revert to Ternary.True.
        for i = 1, #types do
            if include[i] == Ternary.Maybe then
                if matched then
                    include[i] = Ternary.False
                else
                    include[i] = Ternary.True
                end
            end
        end
    end
    local containsFalse = false
    for i = 1, #types do
        if include[i] == Ternary.False then
            containsFalse = true
            break
        end
    end
    if containsFalse then
        local filteredTypes
        for i, t in ipairs(types) do
            if include[i] == Ternary.True then
                filteredTypes = core.Append(filteredTypes, t)
            end
        end
        local filtered = c:getUnionTypeEx(filteredTypes, UnionReduction.None, nil, nil)
        if filtered.flags & TypeFlags.Never == 0 then
            return filtered
        end
    end
    return target
end

function Checker:filterPrimitivesIfContainsNonPrimitive(unionType)
    if self:maybeTypeOfKind(unionType, TypeFlags.NonPrimitive) then
        local result = self:filterType(unionType, checker.isNonPrimitiveType)
        if result.flags & TypeFlags.Never == 0 then
            return result
        end
    end
    return unionType
end

function checker.isNonPrimitiveType(t)
    return t.flags & TypeFlags.Primitive == 0
end

function Checker:getTypeNamesForErrorDisplay(left, right)
    local c = self
    local leftStr
    if c:symbolValueDeclarationIsContextSensitive(left.symbol) then
        leftStr = c:typeToString(left, left.symbol.valueDeclaration)
    else
        leftStr = c:TypeToString(left)
    end
    local rightStr
    if c:symbolValueDeclarationIsContextSensitive(right.symbol) then
        rightStr = c:typeToString(right, right.symbol.valueDeclaration)
    else
        rightStr = c:TypeToString(right)
    end
    if leftStr == rightStr then
        leftStr = c:getTypeNameForErrorDisplay(left)
        rightStr = c:getTypeNameForErrorDisplay(right)
    end
    return leftStr, rightStr
end

function Checker:getTypeNameForErrorDisplay(t)
    return self:typeToStringEx(t, nil --[[enclosingDeclaration]], TypeFormatFlags.UseFullyQualifiedType, nil)
end

function Checker:symbolValueDeclarationIsContextSensitive(symbol)
    return symbol ~= nil and symbol.valueDeclaration ~= nil and ast.IsExpression(symbol.valueDeclaration) and not self:isContextSensitive(symbol.valueDeclaration)
end

function Checker:typeCouldHaveTopLevelSingletonTypes(t)
    local c = self
    -- Okay, yes, 'boolean' is a union of 'true | false', but that's not useful
    -- in error reporting scenarios. If you need to use this function but that detail matters,
    -- feel free to add a flag.
    if t.flags & TypeFlags.Boolean ~= 0 then
        return false
    end
    if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        return core.Some(t:Types(), function(t_)
            return c:typeCouldHaveTopLevelSingletonTypes(t_)
        end)
    end
    if t.flags & TypeFlags.Instantiable ~= 0 then
        local constraint = c:getConstraintOfType(t)
        if constraint ~= nil and constraint ~= t then
            return c:typeCouldHaveTopLevelSingletonTypes(constraint)
        end
    end
    return checker.isUnitType(t) or t.flags & TypeFlags.TemplateLiteral ~= 0 or t.flags & TypeFlags.StringMapping ~= 0
end

function Checker:getVariances(t)
    -- Arrays and tuples are known to be covariant, no need to spend time computing this.
    if t == self.globalArrayType or t == self.globalReadonlyArrayType or t.objectFlags & ObjectFlags.Tuple ~= 0 then
        return self.arrayVariances
    end
    return self:getVariancesWorker(t.symbol, t:AsInterfaceType():TypeParameters())
end

function Checker:getAliasVariances(symbol)
    return self:getVariancesWorker(symbol, self.typeAliasLinks:Get(symbol).typeParameters)
end

-- Return an array containing the variance of each type parameter. The variance is effectively
-- a digest of the type comparisons that occur for each type argument when instantiations of the
-- generic type are structurally compared. We infer the variance information by comparing
-- instantiations of the generic type for type arguments with known relations. The function
-- returns an empty slice when invoked recursively for the given generic type.
function Checker:getVariancesWorker(symbol, typeParameters)
    local c = self
    local links = c.varianceLinks:Get(symbol)
    if links.variances == nil then
        local traceArgs
        local popFn
        local tr = c.tracer
        if tr ~= nil then
            traceArgs = { arity = core.Len(typeParameters), id = c:getDeclaredTypeOfSymbol(symbol).id }
            popFn = tr:Push(tracing.PhaseCheckTypes, "getVariancesWorker", traceArgs, true)
        end
        local stackIndex = c:getVarianceStackIndex(symbol)
        if stackIndex < 0 then
            local saveResolutionStart = c.resolutionStart
            if #c.varianceStack == 0 then
                c.resolutionStart = #c.typeResolutions
            end
            c.varianceStack[#c.varianceStack + 1] = checker.VarianceStackEntry_new({ symbol = symbol, typeParameters = typeParameters })
            local variances = {}
            for i = 1, core.Len(typeParameters) do
                variances[i] = 0
            end
            for i, tp in ipairs(typeParameters or {}) do
                local modifiers = c:getTypeParameterModifiers(tp)
                local variance
                if modifiers & ModifierFlags.Out ~= 0 then
                    if modifiers & ModifierFlags.In ~= 0 then
                        variance = VarianceFlags.Invariant
                    else
                        variance = VarianceFlags.Covariant
                    end
                elseif modifiers & ModifierFlags.In ~= 0 then
                    variance = VarianceFlags.Contravariant
                else
                    local saveReliabilityFlags = c.reliabilityFlags
                    c.reliabilityFlags = 0
                    -- We first compare instantiations where the type parameter is replaced with
                    -- marker types that have a known subtype relationship. From this we can infer
                    -- invariance, covariance, contravariance or bivariance.
                    local typeWithSuper = c:createMarkerType(symbol, tp, c.markerSuperType)
                    local typeWithSub = c:createMarkerType(symbol, tp, c.markerSubType)
                    variance = core.IfElse(c:isTypeAssignableTo(typeWithSub, typeWithSuper), VarianceFlags.Covariant, 0) |
                        core.IfElse(c:isTypeAssignableTo(typeWithSuper, typeWithSub), VarianceFlags.Contravariant, 0)
                    -- If the instantiations appear to be related bivariantly it may be because the
                    -- type parameter is independent (i.e. it isn't witnessed anywhere in the generic
                    -- type). To determine this we compare instantiations where the type parameter is
                    -- replaced with marker types that are known to be unrelated.
                    if variance == VarianceFlags.Bivariant and c:isTypeAssignableTo(c:createMarkerType(symbol, tp, c.markerOtherType), typeWithSuper) then
                        variance = VarianceFlags.Independent
                    end
                    if c.reliabilityFlags & RelationComparisonResult.ReportsUnmeasurable ~= 0 then
                        variance = variance | VarianceFlags.Unmeasurable
                    end
                    if c.reliabilityFlags & RelationComparisonResult.ReportsUnreliable ~= 0 then
                        variance = variance | VarianceFlags.Unreliable
                    end
                    c.reliabilityFlags = saveReliabilityFlags
                end
                -- If variance computation was restarted due to a circularity we may have already
                -- computed variances for this generic type. If so, we exit early.
                if core.Len(links.variances) ~= 0 then
                    break
                end
                variances[i] = variance
            end
            -- Store the results unless a restarted computation has already stored them.
            if core.Len(links.variances) == 0 then
                links.variances = variances
            end
            c.varianceStack[#c.varianceStack] = nil
            if #c.varianceStack == 0 then
                c.resolutionStart = saveResolutionStart
            end
        else
            -- We've detected a circularity. Since we may compute different variances depending on where
            -- we enter a circularity, we find the generic type with the "smallest" symbol in the circular
            -- region of the variance stack and restart the computation from there if necessary. This
            -- ensures stable results for circular generic types.
            local minIndex = stackIndex
            for i = stackIndex + 1, #c.varianceStack - 1 do
                if c.compareSymbols(c.varianceStack[i + 1].symbol, c.varianceStack[minIndex + 1].symbol) < 0 then
                    minIndex = i
                end
            end
            if minIndex > stackIndex then
                local saveVarianceStack = c.varianceStack
                c.varianceStack = {}
                c:getVariancesWorker(saveVarianceStack[minIndex + 1].symbol, saveVarianceStack[minIndex + 1].typeParameters)
                c.varianceStack = saveVarianceStack
            end
            -- Store an empty slice to mark that we can't compute variances for this type. We treat type
            -- parameters as co-variant in this case.
            if core.Len(links.variances) == 0 then
                links.variances = {}
            end
        end
        -- Go: deferred until return
        if popFn ~= nil then
            local formatted = {}
            for i, v in ipairs(links.variances or {}) do
                formatted[i] = checker.VarianceFlags_String(v)
            end
            traceArgs["variances"] = formatted
            popFn()
        end
    end
    return links.variances
end

function Checker:getVarianceStackIndex(symbol)
    for i, entry in ipairs(self.varianceStack) do
        if entry.symbol == symbol then
            return i - 1
        end
    end
    return -1
end

function Checker:createMarkerType(symbol, source, target)
    local c = self
    local mapper = checker.newSimpleTypeMapper(source, target)
    local t = c:getDeclaredTypeOfSymbol(symbol)
    if c:isErrorType(t) then
        return t
    end
    local result
    if symbol.flags & SymbolFlags.TypeAlias ~= 0 then
        result = c:getTypeAliasInstantiation(symbol, c:instantiateTypes(c.typeAliasLinks:Get(symbol).typeParameters, mapper), nil)
    else
        result = c:createTypeReference(t, c:instantiateTypes(t:AsInterfaceType():TypeParameters(), mapper))
    end
    c.markerTypes:Add(result)
    return result
end

function Checker:isMarkerType(t)
    return self.markerTypes:Has(t)
end

function Checker:getTypeParameterModifiers(tp) -- luacheck: ignore 212
    local flags = 0
    if tp.symbol ~= nil then
        for _, d in ipairs(tp.symbol.declarations or {}) do
            flags = flags | d:ModifierFlags()
        end
    end
    return flags & (ModifierFlags.In | ModifierFlags.Out | ModifierFlags.Const)
end

-- Return true if the given type reference has a 'void' type argument for a covariant type parameter.
-- See comment at call in recursiveTypeRelatedTo for when this case matters.
function Checker:hasCovariantVoidArgument(typeArguments, variances) -- luacheck: ignore 212
    for i, v in ipairs(variances or {}) do
        if v & VarianceFlags.VarianceMask == VarianceFlags.Covariant and typeArguments[i].flags & TypeFlags.Void ~= 0 then
            return true
        end
    end
    return false
end

function Checker:isSignatureAssignableTo(source, target, ignoreReturnTypes)
    return self:compareSignaturesRelated(source, target, core.IfElse(ignoreReturnTypes, SignatureCheckMode.IgnoreReturnTypes, SignatureCheckMode.None), false --[[reportErrors]], nil --[[errorReporter]], self.compareTypesAssignable, nil --[[reportUnreliableMarkers]]) ~= Ternary.False
end

function Checker:compareSignaturesRelated(source, target, checkMode, reportErrors, errorReporter, compareTypes, reportUnreliableMarkers)
    local c = self
    if source == target then
        return Ternary.True
    end
    if not (checkMode & SignatureCheckMode.StrictTopSignature ~= 0 and c:isTopSignature(source)) and c:isTopSignature(target) then
        return Ternary.True
    end
    if checkMode & SignatureCheckMode.StrictTopSignature ~= 0 and c:isTopSignature(source) and not c:isTopSignature(target) then
        return Ternary.False
    end
    local targetCount = c:getParameterCount(target)
    local sourceHasMoreParameters = false
    if not c:hasEffectiveRestParameter(target) then
        if checkMode & SignatureCheckMode.StrictArity ~= 0 then
            sourceHasMoreParameters = c:hasEffectiveRestParameter(source) or c:getParameterCount(source) > targetCount
        else
            sourceHasMoreParameters = c:getMinArgumentCount(source) > targetCount
        end
    end
    if sourceHasMoreParameters then
        if reportErrors and (checkMode & SignatureCheckMode.StrictArity == 0) then
            -- the second condition should be redundant, because there is no error reporting when comparing signatures by strict arity
            -- since it is only done for subtype reduction
            errorReporter(diagnostics.Target_signature_provides_too_few_arguments_Expected_0_or_more_but_got_1, c:getMinArgumentCount(source), targetCount)
        end
        return Ternary.False
    end
    if core.Len(source.typeParameters) ~= 0 and not core.Same(source.typeParameters, target.typeParameters) then
        target = c:getCanonicalSignature(target)
        source = c:instantiateSignatureInContextOf(source, target, nil --[[inferenceContext]], compareTypes)
    end
    local sourceCount = c:getParameterCount(source)
    local sourceRestType = c:getNonArrayRestType(source)
    local targetRestType = c:getNonArrayRestType(target)
    if sourceRestType ~= nil or targetRestType ~= nil then
        c:instantiateType(core.IfElse(sourceRestType ~= nil, sourceRestType, targetRestType), reportUnreliableMarkers)
    end
    local kind = Kind.Unknown
    if target.declaration ~= nil then
        kind = target.declaration.kind
    end
    local strictVariance = checkMode & SignatureCheckMode.Callback == 0 and c.strictFunctionTypes and kind ~= Kind.MethodDeclaration and kind ~= Kind.MethodSignature and kind ~= Kind.Constructor
    local result = Ternary.True
    local sourceThisType = c:getThisTypeOfSignature(source)
    if sourceThisType ~= nil and sourceThisType ~= c.voidType then
        local targetThisType = c:getThisTypeOfSignature(target)
        if targetThisType ~= nil then
            -- void sources are assignable to anything.
            local related = Ternary.False
            if not strictVariance then
                related = compareTypes(sourceThisType, targetThisType, false --[[reportErrors]])
            end
            if related == Ternary.False then
                related = compareTypes(targetThisType, sourceThisType, reportErrors)
            end
            if related == Ternary.False then
                if reportErrors then
                    errorReporter(diagnostics.The_this_types_of_each_signature_are_incompatible)
                end
                return Ternary.False
            end
            result = result & related
        end
    end
    local paramCount
    if sourceRestType ~= nil or targetRestType ~= nil then
        paramCount = math.min(sourceCount, targetCount)
    else
        paramCount = math.max(sourceCount, targetCount)
    end
    local restIndex
    if sourceRestType ~= nil or targetRestType ~= nil then
        restIndex = paramCount - 1
    else
        restIndex = -1
    end
    for i = 0, paramCount - 1 do
        local sourceType
        if i == restIndex then
            sourceType = c:getRestOrAnyTypeAtPosition(source, i)
        else
            sourceType = c:tryGetTypeAtPosition(source, i)
        end
        local targetType
        if i == restIndex then
            targetType = c:getRestOrAnyTypeAtPosition(target, i)
        else
            targetType = c:tryGetTypeAtPosition(target, i)
        end
        if sourceType ~= nil and targetType ~= nil and (sourceType ~= targetType or checkMode & SignatureCheckMode.StrictArity ~= 0) then
            -- In order to ensure that any generic type Foo<T> is at least co-variant with respect to T no matter
            -- how Foo uses T, we need to relate parameters bi-variantly (given that parameters are input positions,
            -- they naturally relate only contra-variantly). However, if the source and target parameters both have
            -- function types with a single call signature, we know we are relating two callback parameters. In
            -- that case it is sufficient to only relate the parameters of the signatures co-variantly because,
            -- similar to return values, callback parameters are output positions. This means that a Promise<T>,
            -- where T is used only in callback parameter positions, will be co-variant (as opposed to bi-variant)
            -- with respect to T.
            local sourceSig
            local targetSig
            if checkMode & SignatureCheckMode.Callback == 0 and not c:isInstantiatedGenericParameter(source, i) then
                sourceSig = c:getSingleCallSignature(c:GetNonNullableType(sourceType))
            end
            if checkMode & SignatureCheckMode.Callback == 0 and not c:isInstantiatedGenericParameter(target, i) then
                targetSig = c:getSingleCallSignature(c:GetNonNullableType(targetType))
            end
            local callbacks = sourceSig ~= nil and targetSig ~= nil and c:getTypePredicateOfSignature(sourceSig) == nil and c:getTypePredicateOfSignature(targetSig) == nil and
                c:getTypeFacts(sourceType, TypeFacts.IsUndefinedOrNull) == c:getTypeFacts(targetType, TypeFacts.IsUndefinedOrNull)
            local related = Ternary.False
            if callbacks then
                related = c:compareSignaturesRelated(targetSig, sourceSig, checkMode & SignatureCheckMode.StrictArity | core.IfElse(strictVariance, SignatureCheckMode.StrictCallback, SignatureCheckMode.BivariantCallback), reportErrors, errorReporter, compareTypes, reportUnreliableMarkers)
            else
                if checkMode & SignatureCheckMode.Callback == 0 and not strictVariance then
                    related = compareTypes(sourceType, targetType, false --[[reportErrors]])
                end
                if related == Ternary.False then
                    related = compareTypes(targetType, sourceType, reportErrors)
                end
            end
            -- With strict arity, (x: number | undefined) => void is a subtype of (x?: number | undefined) => void
            if related ~= Ternary.False and checkMode & SignatureCheckMode.StrictArity ~= 0 and i >= c:getMinArgumentCount(source) and i < c:getMinArgumentCount(target) and compareTypes(sourceType, targetType, false --[[reportErrors]]) ~= Ternary.False then
                related = Ternary.False
            end
            if related == Ternary.False then
                if reportErrors then
                    errorReporter(diagnostics.Types_of_parameters_0_and_1_are_incompatible, c:getParameterNameAtPosition(source, i), c:getParameterNameAtPosition(target, i))
                end
                return Ternary.False
            end
            result = result & related
        end
    end
    if checkMode & SignatureCheckMode.IgnoreReturnTypes == 0 then
        -- If a signature resolution is already in-flight, skip issuing a circularity error
        -- here and just use the `any` type directly
        local targetReturnType = c:getNonCircularReturnTypeOfSignature(target)
        if targetReturnType == c.voidType or targetReturnType == c.anyType then
            return result
        end
        local sourceReturnType = c:getNonCircularReturnTypeOfSignature(source)
        -- The following block preserves behavior forbidding boolean returning functions from being assignable to type guard returning functions
        local targetTypePredicate = c:getTypePredicateOfSignature(target)
        if targetTypePredicate ~= nil then
            local sourceTypePredicate = c:getTypePredicateOfSignature(source)
            if sourceTypePredicate ~= nil then
                result = result & c:compareTypePredicateRelatedTo(sourceTypePredicate, targetTypePredicate, reportErrors, errorReporter, compareTypes)
            elseif targetTypePredicate.kind == TypePredicateKind.Identifier or targetTypePredicate.kind == TypePredicateKind.This then
                if reportErrors then
                    errorReporter(diagnostics.Signature_0_must_be_a_type_predicate, c:signatureToString(source))
                end
                return Ternary.False
            end
        else
            -- When relating callback signatures, we still need to relate return types bi-variantly as otherwise
            -- the containing type wouldn't be co-variant. For example, interface Foo<T> { add(cb: () => T): void }
            -- wouldn't be co-variant for T without this rule.
            local related = Ternary.False
            if checkMode & SignatureCheckMode.BivariantCallback ~= 0 then
                related = compareTypes(targetReturnType, sourceReturnType, false --[[reportErrors]])
            end
            if related == Ternary.False then
                related = compareTypes(sourceReturnType, targetReturnType, reportErrors)
            end
            result = result & related
            if result == Ternary.False and reportErrors then
                -- The errors reported here serve as markers that trigger error chain reduction in the (*Relater).reportError
                -- method. The markers are elided in the final diagnostic chain and never actually reported.
                local message
                if core.Len(source.parameters) == 0 and core.Len(target.parameters) == 0 then
                    message = core.IfElse(source.flags & SignatureFlags.Construct ~= 0,
                        diagnostics.Construct_signatures_with_no_arguments_have_incompatible_return_types_0_and_1,
                        diagnostics.Call_signatures_with_no_arguments_have_incompatible_return_types_0_and_1)
                else
                    message = core.IfElse(source.flags & SignatureFlags.Construct ~= 0,
                        diagnostics.Construct_signature_return_types_0_and_1_are_incompatible,
                        diagnostics.Call_signature_return_types_0_and_1_are_incompatible)
                end
                errorReporter(message, c:TypeToString(sourceReturnType), c:TypeToString(targetReturnType))
            end
        end
    end
    return result
end

function Checker:compareTypePredicateRelatedTo(source, target, reportErrors, errorReporter, compareTypes)
    local c = self
    if source.kind ~= target.kind then
        if reportErrors then
            errorReporter(diagnostics.A_this_based_type_guard_is_not_compatible_with_a_parameter_based_type_guard)
            errorReporter(diagnostics.Type_predicate_0_is_not_assignable_to_1, c:typePredicateToString(source), c:typePredicateToString(target))
        end
        return Ternary.False
    end
    if source.kind == TypePredicateKind.Identifier or source.kind == TypePredicateKind.AssertsIdentifier then
        if source.parameterIndex ~= target.parameterIndex then
            if reportErrors then
                errorReporter(diagnostics.Parameter_0_is_not_in_the_same_position_as_parameter_1, source.parameterName, target.parameterName)
                errorReporter(diagnostics.Type_predicate_0_is_not_assignable_to_1, c:typePredicateToString(source), c:typePredicateToString(target))
            end
            return Ternary.False
        end
    end
    local related
    if source.t == target.t then
        related = Ternary.True
    elseif source.t ~= nil and target.t ~= nil then
        related = compareTypes(source.t, target.t, reportErrors)
    else
        related = Ternary.False
    end
    if related == Ternary.False and reportErrors then
        errorReporter(diagnostics.Type_predicate_0_is_not_assignable_to_1, c:typePredicateToString(source), c:typePredicateToString(target))
    end
    return related
end

-- Returns true if `s` is `(...args: A) => R` where `A` is `any`, `any[]`, `never`, or `never[]`, and `R` is `any` or `unknown`.
function Checker:isTopSignature(s)
    local c = self
    if core.Len(s.typeParameters) == 0 and (s.thisParameter == nil or checker.IsTypeAny(c:getTypeOfParameter(s.thisParameter))) and core.Len(s.parameters) == 1 and checker.signatureHasRestParameter(s) then
        local paramType = c:getTypeOfParameter(s.parameters[1])
        local restType
        if c:isArrayType(paramType) then
            restType = c:getTypeArguments(paramType)[1]
        else
            restType = paramType
        end
        return restType.flags & (TypeFlags.Any | TypeFlags.Never) ~= 0 and c:getReturnTypeOfSignature(s).flags & TypeFlags.AnyOrUnknown ~= 0
    end
    return false
end

-- Return the number of parameters in a signature. The rest parameter, if present, counts as one
-- parameter. For example, the parameter count of (x: number, y: number, ...z: string[]) is 3 and
-- the parameter count of (x: number, ...args: [number, ...string[], boolean])) is also 3. In the
-- latter example, the effective rest type is [...string[], boolean].
function Checker:getParameterCount(signature)
    local length = core.Len(signature.parameters)
    if checker.signatureHasRestParameter(signature) then
        local restType = self:getTypeOfSymbol(signature.parameters[length])
        if checker.isTupleType(restType) then
            return length + restType:TargetTupleType().fixedLength - core.IfElse(restType:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0, 0, 1)
        end
    end
    return length
end

function Checker:getMinArgumentCount(signature)
    return self:getMinArgumentCountEx(signature, MinArgumentCountFlags.None)
end

function Checker:getMinArgumentCountEx(signature, flags)
    local c = self
    local strongArityForUntypedJS = flags & MinArgumentCountFlags.StrongArityForUntypedJS
    local voidIsNonOptional = flags & MinArgumentCountFlags.VoidIsNonOptional
    if voidIsNonOptional ~= 0 or signature.resolvedMinArgumentCount == -1 then
        local minArgumentCount = -1
        if checker.signatureHasRestParameter(signature) then
            local restType = c:getTypeOfSymbol(signature.parameters[#signature.parameters])
            if checker.isTupleType(restType) then
                local firstOptionalIndex = core.FindIndex(restType:TargetTupleType().elementInfos, function(info)
                    return info.flags & ElementFlags.Required == 0
                end)
                local requiredCount = firstOptionalIndex
                if firstOptionalIndex < 0 then
                    requiredCount = restType:TargetTupleType().fixedLength
                end
                if requiredCount > 0 then
                    minArgumentCount = #signature.parameters - 1 + requiredCount
                end
            end
        end
        if minArgumentCount == -1 then
            if strongArityForUntypedJS == 0 and signature.flags & SignatureFlags.IsUntypedSignatureInJSFile ~= 0 then
                return 0
            end
            minArgumentCount = signature.minArgumentCount
        end
        if voidIsNonOptional ~= 0 then
            return minArgumentCount
        end
        for i = minArgumentCount - 1, 0, -1 do
            local t = c:getTypeAtPosition(signature, i)
            if not checker.someType(t, function(t_) return t_.flags & TypeFlags.Void ~= 0 end) then
                break
            end
            minArgumentCount = i
        end
        signature.resolvedMinArgumentCount = minArgumentCount
    end
    return signature.resolvedMinArgumentCount
end

function Checker:hasEffectiveRestParameter(signature)
    if checker.signatureHasRestParameter(signature) then
        local restType = self:getTypeOfSymbol(signature.parameters[#signature.parameters])
        return not checker.isTupleType(restType) or restType:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0
    end
    return false
end

function Checker:getTypeAtPosition(signature, pos)
    local t = self:tryGetTypeAtPosition(signature, pos)
    if t ~= nil then
        return t
    end
    return self.anyType
end

function Checker:tryGetTypeAtPosition(signature, pos)
    local c = self
    local paramCount = core.Len(signature.parameters) - core.IfElse(checker.signatureHasRestParameter(signature), 1, 0)
    if pos < paramCount then
        return c:getTypeOfParameter(signature.parameters[pos + 1])
    end
    if checker.signatureHasRestParameter(signature) then
        -- We want to return the value undefined for an out of bounds parameter position,
        -- so we need to check bounds here before calling getIndexedAccessType (which
        -- otherwise would return the type 'undefined').
        local restType = c:getTypeOfSymbol(signature.parameters[paramCount + 1])
        local index = pos - paramCount
        if not checker.isTupleType(restType) or restType:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0 or index < restType:TargetTupleType().fixedLength then
            return c:getIndexedAccessType(restType, c:getNumberLiteralType(index + 0.0))
        end
    end
    return nil
end

-- Return the rest type at the given position, transforming `any[]` into just `any`. We do this because
-- in signatures we want `any[]` in a rest position to be compatible with anything, but `any[]` isn't
-- assignable to tuple types with required elements.
function Checker:getRestOrAnyTypeAtPosition(source, pos)
    local restType = self:getRestTypeAtPosition(source, pos, false)
    if restType ~= nil then
        local elementType = self:getElementTypeOfArrayType(restType)
        if elementType ~= nil and checker.IsTypeAny(elementType) then
            return self.anyType
        end
    end
    return restType
end

function Checker:getRestTypeAtPosition(source, pos, readonly)
    local c = self
    local parameterCount = c:getParameterCount(source)
    local minArgumentCount = c:getMinArgumentCount(source)
    local restType = c:getEffectiveRestType(source)
    if restType ~= nil and pos >= parameterCount - 1 then
        if pos == parameterCount - 1 then
            return restType
        else
            return c:createArrayType(c:getIndexedAccessType(restType, c.numberType))
        end
    end
    local length = parameterCount - pos
    if length <= 0 then
        return c:createTupleTypeEx(nil, nil, readonly)
    end
    local types = {}
    local infos = {}
    for i = 0, length - 1 do
        local flags
        if restType == nil or i < length - 1 then
            types[i + 1] = c:getTypeAtPosition(source, i + pos)
            flags = core.IfElse(i + pos < minArgumentCount, ElementFlags.Required, ElementFlags.Optional)
        else
            types[i + 1] = restType
            flags = ElementFlags.Variadic
        end
        infos[i + 1] = checker.TupleElementInfo_new({ flags = flags, labeledDeclaration = c:getNameableDeclarationAtPosition(source, i + pos) })
    end
    return c:createTupleTypeEx(types, infos, readonly)
end

function Checker:getNameableDeclarationAtPosition(signature, pos)
    local c = self
    local paramCount = core.Len(signature.parameters) - core.IfElse(checker.signatureHasRestParameter(signature), 1, 0)
    if pos < paramCount then
        local decl = signature.parameters[pos + 1].valueDeclaration
        if decl ~= nil and c:isValidDeclarationForTupleLabel(decl) then
            return decl
        end
        return nil
    end
    if checker.signatureHasRestParameter(signature) then
        local restParameter = signature.parameters[paramCount + 1]
        local restType = c:getTypeOfSymbol(restParameter)
        if checker.isTupleType(restType) then
            local elementInfos = restType:TargetTupleType().elementInfos
            local index = pos - paramCount
            if index < core.Len(elementInfos) then
                return elementInfos[index + 1].labeledDeclaration
            end
            return nil
        end
        if restParameter.valueDeclaration ~= nil and c:isValidDeclarationForTupleLabel(restParameter.valueDeclaration) then
            return restParameter.valueDeclaration
        end
    end
    return nil
end

function Checker:isValidDeclarationForTupleLabel(d) -- luacheck: ignore 212
    return ast.IsNamedTupleMember(d) or ast.IsParameterDeclaration(d) and d:Name() ~= nil and ast.IsIdentifier(d:Name())
end

function Checker:getNonArrayRestType(signature)
    local restType = self:getEffectiveRestType(signature)
    if restType ~= nil and not self:isArrayType(restType) and not checker.IsTypeAny(restType) then
        return restType
    end
    return nil
end

function Checker:getEffectiveRestType(signature)
    local c = self
    if checker.signatureHasRestParameter(signature) then
        local restType = c:getTypeOfSymbol(signature.parameters[#signature.parameters])
        if not checker.isTupleType(restType) then
            if checker.IsTypeAny(restType) then
                return c.anyArrayType
            end
            return restType
        end
        if restType:TargetTupleType().combinedFlags & ElementFlags.Variable ~= 0 then
            return c:sliceTupleType(restType, restType:TargetTupleType().fixedLength, 0)
        end
    end
    return nil
end

function Checker:sliceTupleType(t, index, endSkipCount)
    local c = self
    local target = t:TargetTupleType()
    local endIndex = c:getTypeReferenceArity(t) - math.max(endSkipCount, 0)
    if index > target.fixedLength then
        local restArrayType = c:getRestArrayTypeOfTupleType(t)
        if restArrayType ~= nil then
            return restArrayType
        end
        return c:createTupleType(nil)
    end
    if index >= endIndex then
        return c:createTupleType(nil)
    end
    return c:createTupleTypeEx(core.Slice(c:getTypeArguments(t), index, endIndex), core.Slice(target.elementInfos, index, endIndex), false --[[readonly]])
end

function Checker:getKnownKeysOfTupleType(t)
    local c = self
    local fixedLength = t:TargetTupleType().fixedLength
    local keys = {}
    for i = 0, fixedLength - 1 do
        keys[i + 1] = c:getStringLiteralType(tostring(i))
    end
    keys[fixedLength + 1] = c:getIndexType(core.IfElse(t:TargetTupleType().readonly, c.globalReadonlyArrayType, c.globalArrayType))
    return c:getUnionType(keys)
end

function Checker:getRestArrayTypeOfTupleType(t)
    local restType = self:getRestTypeOfTupleType(t)
    if restType ~= nil then
        return self:createArrayType(restType)
    end
    return nil
end

function Checker:getThisTypeOfSignature(signature)
    if signature.thisParameter ~= nil then
        return self:getTypeOfSymbol(signature.thisParameter)
    end
    return nil
end

function Checker:isInstantiatedGenericParameter(signature, pos)
    if signature.target == nil then
        return false
    end
    local t = self:tryGetTypeAtPosition(signature.target, pos)
    return t ~= nil and self:isGenericType(t)
end

function Checker:getParameterNameAtPosition(signature, pos)
    local c = self
    local paramCount = core.Len(signature.parameters) - core.IfElse(checker.signatureHasRestParameter(signature), 1, 0)
    if pos < paramCount then
        return signature.parameters[pos + 1].name
    end
    local restParameter = signature.parameters[paramCount + 1]
    local restType = c:getTypeOfSymbol(restParameter)
    if checker.isTupleType(restType) then
        local index = pos - paramCount
        return c:getTupleElementLabel(restType:TargetTupleType().elementInfos[index + 1], restParameter, index)
    end
    return restParameter.name
end

function Checker:getTupleElementLabel(elementInfo, restSymbol, index)
    if elementInfo.labeledDeclaration ~= nil then
        return elementInfo.labeledDeclaration:Name():Text()
    end
    if restSymbol ~= nil and restSymbol.valueDeclaration ~= nil and ast.IsParameterDeclaration(restSymbol.valueDeclaration) then
        return self:getTupleElementLabelFromBindingElement(restSymbol.valueDeclaration, index, elementInfo.flags)
    end
    local rootName
    if restSymbol ~= nil then
        rootName = restSymbol.name
    else
        rootName = "arg"
    end
    return rootName .. "_" .. tostring(index)
end

function Checker:getTupleElementLabelFromBindingElement(node, index, elementFlags)
    if node:Name() ~= nil then
        local nameKind = node:Name().kind
        if nameKind == Kind.Identifier then
            local name = node:Name():Text()
            if checker.hasDotDotDotToken(node) then
                -- given
                --   (...[x, y, ...z]: [number, number, ...number[]]) => ...
                -- this produces
                --   (x: number, y: number, ...z: number[]) => ...
                -- which preserves rest elements of 'z'

                -- given
                --   (...[x, y, ...z]: [number, number, ...[...number[], number]]) => ...
                -- this produces
                --   (x: number, y: number, ...z: number[], z_1: number) => ...
                -- which preserves rest elements of z but gives distinct numbers to fixed elements of 'z'
                if elementFlags & ElementFlags.Variable ~= 0 then
                    return name
                end
                return name .. "_" .. tostring(index)
            end
            -- given
            --   (...[x]: [number]) => ...
            -- this produces
            --   (x: number) => ...
            -- which preserves fixed elements of 'x'

            -- given
            --   (...[x]: ...number[]) => ...
            -- this produces
            --   (x_0: number) => ...
            -- which which numbers fixed elements of 'x' whose tuple element type is variable
            if elementFlags & ElementFlags.Fixed ~= 0 then
                return name
            end
            return name .. "_n"
        elseif nameKind == Kind.ArrayBindingPattern then
            if checker.hasDotDotDotToken(node) then
                local elements = node:Name():Elements()
                local lastElement = core.LastOrNil(elements)
                local lastElementIsBindingElementRest = lastElement ~= nil and ast.IsBindingElement(lastElement) and checker.hasDotDotDotToken(lastElement)
                local elementCount = core.Len(elements) - core.IfElse(lastElementIsBindingElementRest, 1, 0)
                if index < elementCount then
                    local element = elements[index + 1]
                    if ast.IsBindingElement(element) then
                        return self:getTupleElementLabelFromBindingElement(element, index, elementFlags)
                    end
                elseif lastElementIsBindingElementRest then
                    return self:getTupleElementLabelFromBindingElement(lastElement, index - elementCount, elementFlags)
                end
            end
        end
    end
    return "arg_" .. tostring(index)
end

function Checker:getTypePredicateOfSignature(sig)
    local c = self
    if sig.resolvedTypePredicate == nil then
        if sig.target ~= nil then
            local targetTypePredicate = c:getTypePredicateOfSignature(sig.target)
            if targetTypePredicate ~= nil then
                sig.resolvedTypePredicate = c:instantiateTypePredicate(targetTypePredicate, sig.mapper)
            end
        elseif sig.composite ~= nil then
            sig.resolvedTypePredicate = c:getUnionOrIntersectionTypePredicate(sig.composite.signatures, sig.composite.isUnion)
        else
            if sig.declaration ~= nil then
                local typeNode = sig.declaration:Type()
                if typeNode ~= nil then
                    if ast.IsTypePredicateNode(typeNode) then
                        sig.resolvedTypePredicate = c:createTypePredicateFromTypePredicateNode(typeNode, sig)
                    end
                elseif ast.IsFunctionLikeDeclaration(sig.declaration) and (sig.resolvedReturnType == nil or sig.resolvedReturnType.flags & TypeFlags.Boolean ~= 0) and c:getParameterCount(sig) > 0 then
                    sig.resolvedTypePredicate = c.noTypePredicate -- avoid infinite loop
                    sig.resolvedTypePredicate = c:getTypePredicateFromBody(sig.declaration)
                end
            end
        end
        if sig.resolvedTypePredicate == nil then
            sig.resolvedTypePredicate = c.noTypePredicate
        end
    end
    if sig.resolvedTypePredicate == c.noTypePredicate then
        return nil
    end
    return sig.resolvedTypePredicate
end

function Checker:getUnionOrIntersectionTypePredicate(signatures, isUnion)
    local c = self
    local last
    local types
    for _, sig in ipairs(signatures or {}) do
        local pred = c:getTypePredicateOfSignature(sig)
        if pred ~= nil then
            -- Constituent type predicates must all have matching kinds. We don't create composite type predicates for assertions.
            if pred.kind ~= TypePredicateKind.This and pred.kind ~= TypePredicateKind.Identifier or last ~= nil and not c:typePredicateKindsMatch(last, pred) then
                return nil
            end
            last = pred
            types = core.Append(types, pred.t)
        else
            -- In composite union signatures we permit and ignore signatures with a return type `false`.
            local returnType
            if isUnion then
                returnType = c:getReturnTypeOfSignature(sig)
            end
            if returnType ~= c.falseType and returnType ~= c.regularFalseType then
                return nil
            end
        end
    end
    if last == nil then
        return nil
    end
    local compositeType = c:getUnionOrIntersectionType(types, isUnion, UnionReduction.Literal)
    return c:newTypePredicate(last.kind, last.parameterName, last.parameterIndex, compositeType)
end

function Checker:typePredicateKindsMatch(a, b) -- luacheck: ignore 212
    return a.kind == b.kind and a.parameterIndex == b.parameterIndex
end

function Checker:createTypePredicateFromTypePredicateNode(node, signature)
    local c = self
    local predicateNode = node:AsTypePredicateNode()
    local t
    if predicateNode.type ~= nil then
        t = c:getTypeFromTypeNode(predicateNode.type)
    end
    if ast.IsThisTypeNode(predicateNode.parameterName) then
        local kind = core.IfElse(predicateNode.assertsModifier ~= nil, TypePredicateKind.AssertsThis, TypePredicateKind.This)
        return c:newTypePredicate(kind, "" --[[parameterName]], 0 --[[parameterIndex]], t)
    end
    local kind = core.IfElse(predicateNode.assertsModifier ~= nil, TypePredicateKind.AssertsIdentifier, TypePredicateKind.Identifier)
    local name = predicateNode.parameterName:Text()
    local index = core.FindIndex(signature.parameters, function(p) return p.name == name end)
    return c:newTypePredicate(kind, name, index, t)
end

function Checker:instantiateTypePredicate(predicate, mapper)
    local t = self:instantiateType(predicate.t, mapper)
    if t == predicate.t then
        return predicate
    end
    return self:newTypePredicate(predicate.kind, predicate.parameterName, predicate.parameterIndex, t)
end

function Checker:newTypePredicate(kind, parameterName, parameterIndex, t) -- luacheck: ignore 212
    return checker.TypePredicate_new({ kind = kind, parameterIndex = parameterIndex, parameterName = parameterName, t = t })
end

function Checker:isResolvingReturnTypeOfSignature(signature)
    local c = self
    if signature.composite ~= nil and core.Some(signature.composite.signatures, function(s)
        return c:isResolvingReturnTypeOfSignature(s)
    end) then
        return true
    end
    return signature.resolvedReturnType == nil and c:findResolutionCycleStartIndex(signature, TypeSystemPropertyName.ResolvedReturnType) >= 0
end

function Checker:findMatchingSignatures(signatureLists, signature, listIndex)
    local c = self
    if core.Len(signature.typeParameters) ~= 0 then
        -- We require an exact match for generic signatures, so we only return signatures from the first
        -- signature list and only if they have exact matches in the other signature lists.
        if listIndex > 0 then
            return nil
        end
        for i = 1, #signatureLists - 1 do
            if c:findMatchingSignature(signatureLists[i + 1], signature, false --[[partialMatch]], false --[[ignoreThisTypes]], false --[[ignoreReturnTypes]]) == nil then
                return nil
            end
        end
        return { signature }
    end
    local result
    for i = 0, #signatureLists - 1 do
        -- Allow matching non-generic signatures to have excess parameters (as a fallback if exact parameter match is not found) and different return types.
        -- Prefer matching this types if possible.
        local match
        if i == listIndex then
            match = signature
        else
            match = c:findMatchingSignature(signatureLists[i + 1], signature, false --[[partialMatch]], false --[[ignoreThisTypes]], true --[[ignoreReturnTypes]])
            if match == nil then
                match = c:findMatchingSignature(signatureLists[i + 1], signature, true --[[partialMatch]], false --[[ignoreThisTypes]], true --[[ignoreReturnTypes]])
            end
        end
        if match == nil then
            return nil
        end
        result = core.AppendIfUnique(result, match)
    end
    return result
end

function Checker:findMatchingSignature(signatureList, signature, partialMatch, ignoreThisTypes, ignoreReturnTypes)
    local c = self
    local compareTypes
    if partialMatch then
        compareTypes = function(s, t) return c:compareTypesSubtypeOf(s, t) end
    else
        compareTypes = function(s, t) return c:compareTypesIdentical(s, t) end
    end
    for _, s in ipairs(signatureList or {}) do
        if c:compareSignaturesIdentical(s, signature, partialMatch, ignoreThisTypes, ignoreReturnTypes, compareTypes) ~= 0 then
            return s
        end
    end
    return nil
end

--[[
 * See signatureRelatedTo, compareSignaturesIdentical
]]
function Checker:compareSignaturesIdentical(source, target, partialMatch, ignoreThisTypes, ignoreReturnTypes, compareTypes)
    local c = self
    if source == target then
        return Ternary.True
    end
    if not c:isMatchingSignature(source, target, partialMatch) then
        return Ternary.False
    end
    -- Check that the two signatures have the same number of type parameters.
    if core.Len(source.typeParameters) ~= core.Len(target.typeParameters) then
        return Ternary.False
    end
    -- Check that type parameter constraints and defaults match. If they do, instantiate the source
    -- signature with the type parameters of the target signature and continue the comparison.
    if core.Len(target.typeParameters) ~= 0 then
        local mapper = checker.newTypeMapper(source.typeParameters, target.typeParameters)
        for i = 1, #target.typeParameters do
            local s = source.typeParameters[i]
            local t = target.typeParameters[i]
            if not (s == t or compareTypes(c:instantiateType(c:getConstraintOrUnknownFromTypeParameter(s), mapper), c:getConstraintOrUnknownFromTypeParameter(t)) ~= Ternary.False and
                compareTypes(c:instantiateType(c:getDefaultOrUnknownFromTypeParameter(s), mapper), c:getDefaultOrUnknownFromTypeParameter(t)) ~= Ternary.False) then
                return Ternary.False
            end
        end
        source = c:instantiateSignatureEx(source, mapper, true --[[eraseTypeParameters]])
    end
    local result = Ternary.True
    if not ignoreThisTypes then
        local sourceThisType = c:getThisTypeOfSignature(source)
        if sourceThisType ~= nil then
            local targetThisType = c:getThisTypeOfSignature(target)
            if targetThisType ~= nil then
                local related = compareTypes(sourceThisType, targetThisType)
                if related == Ternary.False then
                    return Ternary.False
                end
                result = result & related
            end
        end
    end
    for i = 0, c:getParameterCount(target) - 1 do
        local s = c:getTypeAtPosition(source, i)
        local t = c:getTypeAtPosition(target, i)
        local related = compareTypes(t, s)
        if related == Ternary.False then
            return Ternary.False
        end
        result = result & related
    end
    if not ignoreReturnTypes then
        local sourceTypePredicate = c:getTypePredicateOfSignature(source)
        local targetTypePredicate = c:getTypePredicateOfSignature(target)
        if sourceTypePredicate ~= nil or targetTypePredicate ~= nil then
            result = result & c:compareTypePredicatesIdentical(sourceTypePredicate, targetTypePredicate, compareTypes)
        else
            result = result & compareTypes(c:getReturnTypeOfSignature(source), c:getReturnTypeOfSignature(target))
        end
    end
    return result
end

function Checker:isMatchingSignature(source, target, partialMatch)
    local c = self
    local sourceParameterCount = c:getParameterCount(source)
    local targetParameterCount = c:getParameterCount(target)
    local sourceMinArgumentCount = c:getMinArgumentCount(source)
    local targetMinArgumentCount = c:getMinArgumentCount(target)
    local sourceHasRestParameter = c:hasEffectiveRestParameter(source)
    local targetHasRestParameter = c:hasEffectiveRestParameter(target)
    -- A source signature matches a target signature if the two signatures have the same number of required,
    -- optional, and rest parameters.
    if sourceParameterCount == targetParameterCount and sourceMinArgumentCount == targetMinArgumentCount and sourceHasRestParameter == targetHasRestParameter then
        return true
    end
    -- A source signature partially matches a target signature if the target signature has no fewer required
    -- parameters
    if partialMatch and sourceMinArgumentCount <= targetMinArgumentCount then
        return true
    end
    return false
end

function Checker:compareTypeParametersIdentical(sourceParams, targetParams)
    local c = self
    if core.Len(sourceParams) ~= core.Len(targetParams) then
        return false
    end
    local mapper = checker.newTypeMapper(targetParams, sourceParams)
    for i = 1, core.Len(sourceParams) do
        local source = sourceParams[i]
        local target = targetParams[i]
        if source == target then
            goto continue
        end
        -- We instantiate the target type parameter constraints into the source types so we can recognize `<T, U extends T>` as the same as `<A, B extends A>`
        if not c:isTypeIdenticalTo(c:getConstraintFromTypeParameter(source) or c.unknownType, c:instantiateType(c:getConstraintFromTypeParameter(target) or c.unknownType, mapper)) then
            return false
        end
        -- We don't compare defaults - we just use the type parameter defaults from the first signature that seems to match.
        -- It might make sense to combine these defaults in the future, but doing so intelligently requires knowing
        -- if the parameter is used covariantly or contravariantly (so we intersect if it's used like a parameter or union if used like a return type)
        -- and, since it's just an inference _default_, just picking one arbitrarily works OK.
        ::continue::
    end
    return true
end

function Checker:compareTypePredicatesIdentical(source, target, compareTypes)
    if source == nil or target == nil or not self:typePredicateKindsMatch(source, target) then
        return Ternary.False
    elseif source.t == target.t then
        return Ternary.True
    elseif source.t ~= nil and target.t ~= nil then
        return compareTypes(source.t, target.t)
    end
    return Ternary.False
end

function Checker:getEffectiveConstraintOfIntersection(types, targetIsUnion)
    local c = self
    local constraints
    local hasDisjointDomainType = false
    for _, t in ipairs(types) do
        if t.flags & TypeFlags.Instantiable ~= 0 then
            -- We keep following constraints as long as we have an instantiable type that is known
            -- not to be circular or infinite (hence we stop on index access types).
            local constraint = c:getConstraintOfType(t)
            while constraint ~= nil and constraint.flags & (TypeFlags.TypeParameter | TypeFlags.Index | TypeFlags.Conditional) ~= 0 do
                constraint = c:getConstraintOfType(constraint)
            end
            if constraint ~= nil then
                constraints = core.Append(constraints, constraint)
                if targetIsUnion then
                    constraints = core.Append(constraints, t)
                end
            end
        elseif t.flags & TypeFlags.DisjointDomains ~= 0 or c:IsEmptyAnonymousObjectType(t) then
            hasDisjointDomainType = true
        end
    end
    -- If the target is a union type or if we are intersecting with types belonging to one of the
    -- disjoint domains, we may end up producing a constraint that hasn't been examined before.
    if constraints ~= nil and (targetIsUnion or hasDisjointDomainType) then
        if hasDisjointDomainType then
            -- We add any types belong to one of the disjoint domains because they might cause the final
            -- intersection operation to reduce the union constraints.
            for _, t in ipairs(types) do
                if t.flags & TypeFlags.DisjointDomains ~= 0 or c:IsEmptyAnonymousObjectType(t) then
                    constraints = core.Append(constraints, t)
                end
            end
        end
        -- The source types were normalized; ensure the result is normalized too.
        return c:getNormalizedType(c:getIntersectionTypeEx(constraints, IntersectionFlags.NoConstraintReduction, nil), false --[[writing]])
    end
    return nil
end

function Checker:templateLiteralTypesDefinitelyUnrelated(source, target) -- luacheck: ignore 212
    -- Two template literal types with differences in their starting or ending text spans are definitely unrelated.
    local sourceStart = source.texts[1]
    local targetStart = target.texts[1]
    local sourceEnd = source.texts[#source.texts]
    local targetEnd = target.texts[#target.texts]
    local startLen = math.min(#sourceStart, #targetStart)
    local endLen = math.min(#sourceEnd, #targetEnd)
    return string.sub(sourceStart, 1, startLen) ~= string.sub(targetStart, 1, startLen) or
        string.sub(sourceEnd, #sourceEnd - endLen + 1) ~= string.sub(targetEnd, #targetEnd - endLen + 1)
end

function Checker:isTypeMatchedByTemplateLiteralType(source, target, compareTypes)
    local inferences = self:inferTypesFromTemplateLiteralType(source, target)
    if inferences ~= nil then
        for i, inference in ipairs(inferences) do
            if not self:isValidTypeForTemplateLiteralPlaceholder(inference, target.types[i], compareTypes) then
                return false
            end
        end
        return true
    end
    return false
end

local function stringSlicesEqual(a, b)
    if core.Len(a) ~= core.Len(b) then
        return false
    end
    for i = 1, core.Len(a) do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

function Checker:inferTypesFromTemplateLiteralType(source, target)
    local c = self
    if source.flags & TypeFlags.StringLiteral ~= 0 then
        return c:inferFromLiteralPartsToTemplateLiteral({ checker.getStringLiteralValue(source) }, nil, target)
    elseif source.flags & TypeFlags.TemplateLiteral ~= 0 then
        if stringSlicesEqual(source:AsTemplateLiteralType().texts, target.texts) then
            return core.MapIndex(source:AsTemplateLiteralType().types, function(s, i)
                if c:isTypeAssignableTo(c:getBaseConstraintOrType(s), c:getBaseConstraintOrType(target.types[i + 1])) then
                    return s
                end
                return c:getStringLikeTypeForType(s)
            end)
        end
        return c:inferFromLiteralPartsToTemplateLiteral(source:AsTemplateLiteralType().texts, source:AsTemplateLiteralType().types, target)
    end
    return nil
end

-- This function infers from the text parts and type parts of a source literal to a target template literal. The number
-- of text parts is always one more than the number of type parts, and a source string literal is treated as a source
-- with one text part and zero type parts. The function returns an array of inferred string or template literal types
-- corresponding to the placeholders in the target template literal, or undefined if the source doesn't match the target.
--
-- We first check that the starting source text part matches the starting target text part, and that the ending source
-- text part ends matches the ending target text part. We then iterate through the remaining target text parts, finding
-- a match for each in the source and inferring string or template literal types created from the segments of the source
-- that occur between the matches. During this iteration, seg holds the index of the current text part in the sourceTexts
-- array and pos holds the current character position in the current text part.
--
-- Consider inference from type `<<${string}>.<${number}-${number}>>` to type `<${string}.${string}>`, i.e.
--
--	sourceTexts = ['<<', '>.<', '-', '>>']
--	sourceTypes = [string, number, number]
--	target.texts = ['<', '.', '>']
--
-- We first match '<' in the target to the start of '<<' in the source and '>' in the target to the end of '>>' in
-- the source. The first match for the '.' in target occurs at character 1 in the source text part at index 1, and thus
-- the first inference is the template literal type `<${string}>`. The remainder of the source makes up the second
-- inference, the template literal type `<${number}-${number}>`.
function Checker:inferFromLiteralPartsToTemplateLiteral(sourceTexts, sourceTypes, target)
    local c = self
    local lastSourceIndex = #sourceTexts - 1
    local sourceStartText = sourceTexts[1]
    local sourceEndText = sourceTexts[lastSourceIndex + 1]
    local targetTexts = target.texts
    local lastTargetIndex = #targetTexts - 1
    local targetStartText = targetTexts[1]
    local targetEndText = targetTexts[lastTargetIndex + 1]
    if lastSourceIndex == 0 and #sourceStartText < #targetStartText + #targetEndText or
        string.sub(sourceStartText, 1, #targetStartText) ~= targetStartText or
        #sourceEndText < #targetEndText or string.sub(sourceEndText, #sourceEndText - #targetEndText + 1) ~= targetEndText then
        return nil
    end
    local remainingEndText = string.sub(sourceEndText, 1, #sourceEndText - #targetEndText)
    local seg = 0
    local pos = #targetStartText
    local matches
    local function getSourceText(index)
        if index < lastSourceIndex then
            return sourceTexts[index + 1]
        end
        return remainingEndText
    end
    local function addMatch(s, p)
        local matchType
        if s == seg then
            matchType = c:getStringLiteralType(stringutil.CombineSurrogatePairs(string.sub(getSourceText(s), pos + 1, p)))
        else
            local matchTexts = {}
            matchTexts[1] = string.sub(sourceTexts[seg + 1], pos + 1)
            for k = seg + 1, s - 1 do
                matchTexts[#matchTexts + 1] = sourceTexts[k + 1]
            end
            matchTexts[s - seg + 1] = string.sub(getSourceText(s), 1, p)
            matchType = c:getTemplateLiteralType(matchTexts, core.Slice(sourceTypes, seg, s))
        end
        matches = core.Append(matches, matchType)
        seg = s
        pos = p
    end
    for i = 1, lastTargetIndex - 1 do
        local delim = targetTexts[i + 1]
        if #delim > 0 then
            local s = seg
            local p = pos
            while true do
                local d = string.find(getSourceText(s), delim, p + 1, true)
                if d ~= nil then
                    p = d - 1
                    break
                end
                s = s + 1
                if s == #sourceTexts then
                    return nil
                end
                p = 0
            end
            addMatch(s, p)
            pos = pos + #delim
        else
            local sourceText = getSourceText(seg)
            if pos < #sourceText then
                -- Consume one code point at a time, matching the string iterator
                -- (`[x, ..._] = s`) rather than UTF-16 code-unit indexing (`s[0]`).
                -- DecodeJSStringRune is required rather than utf8.DecodeRuneInString
                -- because a lone surrogate is stored as an invalid-UTF-8 sentinel;
                -- utf8 would treat that as an error and advance a single byte,
                -- breaking the sentinel into stray bytes, whereas DecodeJSStringRune
                -- pulls the whole sentinel off as one code point.
                --
                -- This intentionally diverges from Strada, which advances one UTF-16
                -- code unit at a time (`s[0]` semantics) and therefore splits a
                -- supplementary code point such as an emoji into its surrogate
                -- halves. If we ever need to match that, expand sourceTexts and
                -- targetTexts into code-unit space up front with a SplitSurrogatePairs
                -- helper (the inverse of CombineSurrogatePairs) and decode by code
                -- unit here; the CombineSurrogatePairs call in addMatch already
                -- recombines captured halves back into canonical form.
                local _, size = stringutil.DecodeJSStringRune(sourceText, pos)
                addMatch(seg, pos + size)
            elseif seg < lastSourceIndex then
                addMatch(seg + 1, 0)
            else
                return nil
            end
        end
    end
    addMatch(lastSourceIndex, #getSourceText(lastSourceIndex))
    return matches
end

function Checker:getStringLikeTypeForType(t)
    if t.flags & (TypeFlags.Any | TypeFlags.StringLike) ~= 0 then
        return t
    end
    return self:getTemplateLiteralType({ "", "" }, { t })
end

function Checker:isValidTypeForTemplateLiteralPlaceholder(source, target, compareTypes)
    local c = self
    if target.flags & TypeFlags.Intersection ~= 0 then
        return core.Every(target:Types(), function(t)
            return t == c.emptyTypeLiteralType or c:isValidTypeForTemplateLiteralPlaceholder(source, t, compareTypes)
        end)
    elseif target.flags & TypeFlags.String ~= 0 or compareTypes(source, target, false) ~= Ternary.False then
        return true
    elseif source.flags & TypeFlags.StringLiteral ~= 0 then
        local value = checker.getStringLiteralValue(source)
        return target.flags & TypeFlags.Number ~= 0 and checker.isValidNumberString(value, false --[[roundTripOnly]]) or
            target.flags & TypeFlags.BigInt ~= 0 and checker.isValidBigIntString(value, false --[[roundTripOnly]]) or
            target.flags & (TypeFlags.BooleanLiteral | TypeFlags.Nullable) ~= 0 and value == target:AsIntrinsicType().intrinsicName or
            target.flags & TypeFlags.StringMapping ~= 0 and c:isMemberOfStringMapping(source, target) or
            target.flags & TypeFlags.TemplateLiteral ~= 0 and c:isTypeMatchedByTemplateLiteralType(source, target:AsTemplateLiteralType(), compareTypes)
    elseif source.flags & TypeFlags.TemplateLiteral ~= 0 then
        local texts = source:AsTemplateLiteralType().texts
        return #texts == 2 and texts[1] == "" and texts[2] == "" and compareTypes(source:AsTemplateLiteralType().types[1], target, false) ~= Ternary.False
    end
    return false
end
