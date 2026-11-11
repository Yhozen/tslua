local checker = require("tslua.checker")
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local TypeFacts = checker.TypeFacts
local CheckMode = checker.CheckMode
local ContextFlags = checker.ContextFlags
local IterationUse = checker.IterationUse
local IterationTypeKind = checker.IterationTypeKind
local AccessFlags = checker.AccessFlags
local UnionReduction = checker.UnionReduction
local NodeCheckFlags = checker.NodeCheckFlags
local AssignmentKind = checker.AssignmentKind
local ReferenceHint = checker.ReferenceHint
local TypeSystemPropertyName = checker.TypeSystemPropertyName
local ExternalEmitHelpers = checker.ExternalEmitHelpers
local PredicateSemantics = checker.PredicateSemantics
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local FunctionFlags = ast.FunctionFlags
local FindAncestorResult = ast.FindAncestorResult
local OuterExpressionKinds = ast.OuterExpressionKinds
local ModuleKind = core.ModuleKind
local Tristate = core.Tristate

-- Go slices.Contains
local function containsValue(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

-- Go slices.Index (0-based, -1 if absent)
local function indexOfValue(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end

function Checker:getInstantiationExpressionType(exprType, node)
    local c = self
    local typeArguments = node:TypeArgumentList()
    if exprType == c.silentNeverType or c:isErrorType(exprType) or typeArguments == nil then
        return exprType
    end
    local key = checker.InstantiationExpressionKey(ast.GetNodeId(node), exprType.id)
    local cached = c.instantiationExpressionTypes[key]
    if cached ~= nil then
        return cached
    end
    local hasSomeApplicableSignature = false
    local nonApplicableType = nil
    local getInstantiatedSignatures = function(signatures)
        local applicableSignatures = core.Filter(signatures, function(sig)
            return core.Len(sig.typeParameters) ~= 0 and c:hasCorrectTypeArgumentArity(sig, typeArguments.nodes)
        end)
        return core.SameMap(applicableSignatures, function(sig)
            local typeArgumentTypes = c:checkTypeArguments(sig, typeArguments.nodes, true --[[reportErrors]], nil)
            if typeArgumentTypes ~= nil then
                return c:getSignatureInstantiation(sig, typeArgumentTypes, ast.IsInJSFile(sig.declaration), nil)
            end
            return sig
        end)
    end
    local getInstantiatedType
    getInstantiatedType = function(t)
        local hasSignatures = false
        local hasApplicableSignature = false
        local getInstantiatedTypePart
        getInstantiatedTypePart = function(tp)
            if tp.flags & TypeFlags.Object ~= 0 then
                local resolved = c:resolveStructuredTypeMembers(tp)
                local callSignatures = getInstantiatedSignatures(resolved:CallSignatures())
                local constructSignatures = getInstantiatedSignatures(resolved:ConstructSignatures())
                hasSignatures = hasSignatures or core.Len(resolved:CallSignatures()) ~= 0 or core.Len(resolved:ConstructSignatures()) ~= 0
                hasApplicableSignature = hasApplicableSignature or core.Len(callSignatures) ~= 0 or core.Len(constructSignatures) ~= 0
                if not core.Same(callSignatures, resolved:CallSignatures()) or not core.Same(constructSignatures, resolved:ConstructSignatures()) then
                    local result = c:newObjectType(ObjectFlags.Anonymous | checker.ObjectFlagsInstantiationExpressionType, tp.symbol)
                    c:setStructuredTypeMembers(result, resolved.members, callSignatures, constructSignatures, resolved.indexInfos)
                    result:AsInstantiationExpressionType().node = node
                    return result
                end
            elseif tp.flags & TypeFlags.InstantiableNonPrimitive ~= 0 then
                local constraint = c:getBaseConstraintOfType(tp)
                if constraint ~= nil then
                    local instantiated = getInstantiatedTypePart(constraint)
                    if instantiated ~= constraint then
                        return instantiated
                    end
                end
            elseif tp.flags & TypeFlags.Union ~= 0 then
                return c:mapType(tp, getInstantiatedType)
            elseif tp.flags & TypeFlags.Intersection ~= 0 then
                return c:getIntersectionType(core.SameMap(t:AsIntersectionType().types, getInstantiatedTypePart))
            end
            return t
        end
        local result = getInstantiatedTypePart(t)
        hasSomeApplicableSignature = hasSomeApplicableSignature or hasApplicableSignature
        if hasSignatures and not hasApplicableSignature then
            if nonApplicableType == nil then
                nonApplicableType = t
            end
        end
        return result
    end
    local result = getInstantiatedType(exprType)
    c.instantiationExpressionTypes[key] = result
    local errorType
    if hasSomeApplicableSignature then
        errorType = nonApplicableType
    else
        errorType = exprType
    end
    if errorType ~= nil then
        local sourceFile = ast.GetSourceFileOfNode(node)
        local loc = core.NewTextRange(scanner.SkipTrivia(sourceFile:Text(), typeArguments:Pos()), typeArguments:End())
        c:addDiagnostic(ast.NewDiagnostic(sourceFile, loc, diagnostics.Type_0_has_no_signatures_for_which_the_type_argument_list_is_applicable, c:TypeToString(errorType)))
    end
    return result
end

function Checker:checkSatisfiesExpression(node)
    local typeNode = node:Type()
    self:checkSourceElement(typeNode)
    local exprType = self:checkExpression(node:Expression())
    local targetType = self:getTypeFromTypeNode(typeNode)
    if self:isErrorType(targetType) then
        return targetType
    end
    self:checkTypeAssignableToAndOptionallyElaborate(exprType, targetType, node, node:Expression(), diagnostics.Type_0_does_not_satisfy_the_expected_type_1, nil)
    return exprType
end

function Checker:checkMetaProperty(node)
    self:checkGrammarMetaProperty(node:AsMetaProperty())
    local keywordToken = node:AsMetaProperty().keywordToken
    if keywordToken == Kind.NewKeyword then
        return self:checkNewTargetMetaProperty(node)
    elseif keywordToken == Kind.ImportKeyword then
        if node:Name():Text() == "defer" then
            debug.Assert(not ast.IsCallExpression(node.parent) or node.parent:Expression() ~= node, "Trying to get the type of `import.defer` in `import.defer(...)`")
            return self.errorType
        end
        return self:checkImportMetaProperty(node)
    end
    error("Unhandled case in checkMetaProperty", 0)
end

function Checker:checkNewTargetMetaProperty(node)
    local container = ast.GetNewTargetContainer(node)
    if container == nil then
        self:error(node, diagnostics.Meta_property_0_is_only_allowed_in_the_body_of_a_function_declaration_function_expression_or_constructor, "new.target")
        return self.errorType
    end
    if ast.IsConstructorDeclaration(container) then
        local symbol = self:getSymbolOfDeclaration(container.parent)
        return self:getTypeOfSymbol(symbol)
    end
    local symbol = self:getSymbolOfDeclaration(container)
    return self:getTypeOfSymbol(symbol)
end

function Checker:checkImportMetaProperty(node)
    if ModuleKind.Node16 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext then
        local sourceFileMetaData = self.program:GetSourceFileMetaData(ast.GetSourceFileOfNode(node):Path())
        if sourceFileMetaData.impliedNodeFormat ~= ModuleKind.ESNext then
            self:error(node, diagnostics.The_import_meta_meta_property_is_not_allowed_in_files_which_will_build_into_CommonJS_output)
        end
    elseif self.moduleKind < ModuleKind.ES2020 and self.moduleKind ~= ModuleKind.System then
        self:error(node, diagnostics.The_import_meta_meta_property_is_only_allowed_when_the_module_option_is_es2020_es2022_esnext_system_node16_node18_node20_or_nodenext)
    end
    local file = ast.GetSourceFileOfNode(node)
    debug.Assert(file.flags & NodeFlags.PossiblyContainsImportMeta ~= 0, "Containing file is missing import meta node flag.")
    if node:Name():Text() == "meta" then
        return self.getGlobalImportMetaType()
    end
    return self.errorType
end

function Checker:checkMetaPropertyKeyword(node)
    -- !!! This is effectively a helper for GetSymbolAtLocation and GetTypeAtLocation
    return self.errorType
end

function Checker:checkDeleteExpression(node)
    self:checkExpression(node:Expression())
    local expr = ast.SkipParentheses(node:Expression())
    if not ast.IsAccessExpression(expr) then
        self:error(expr, diagnostics.The_operand_of_a_delete_operator_must_be_a_property_reference)
        return self.booleanType
    end
    if ast.IsPropertyAccessExpression(expr) and ast.IsPrivateIdentifier(expr:Name()) then
        self:error(expr, diagnostics.The_operand_of_a_delete_operator_cannot_be_a_private_identifier)
    end
    local symbol = self:getExportSymbolOfValueSymbolIfExported(self:getResolvedSymbolOrNil(expr))
    if symbol ~= nil then
        if self:isReadonlySymbol(symbol) then
            self:error(expr, diagnostics.The_operand_of_a_delete_operator_cannot_be_a_read_only_property)
        else
            self:checkDeleteExpressionMustBeOptional(expr, symbol)
        end
    end
    return self.booleanType
end

function Checker:checkDeleteExpressionMustBeOptional(expr, symbol)
    local t = self:getTypeOfSymbol(symbol)
    if self.strictNullChecks and t.flags & (TypeFlags.AnyOrUnknown | TypeFlags.Never) == 0 then
        local isOptional
        if self.exactOptionalPropertyTypes then
            isOptional = symbol.flags & SymbolFlags.Optional ~= 0
        else
            isOptional = self:hasTypeFacts(t, TypeFacts.IsUndefined)
        end
        if not isOptional then
            self:error(expr, diagnostics.The_operand_of_a_delete_operator_must_be_optional)
        end
    end
end

function Checker:checkVoidExpression(node)
    self:checkNodeDeferred(node)
    return self.undefinedWideningType
end

function Checker:checkAwaitExpression(node)
    self:checkGrammarAwaitOrAwaitUsing(node)
    local operandType = self:checkExpression(node:Expression())
    local awaitedType = self:checkAwaitedType(operandType, true --[[withAlias]], node, diagnostics.Type_of_await_operand_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member)
    if awaitedType == operandType and not self:isErrorType(awaitedType) and operandType.flags & TypeFlags.AnyOrUnknown == 0 then
        self:addErrorOrSuggestion(false, checker.createDiagnosticForNode(node, diagnostics.X_await_has_no_effect_on_the_type_of_this_expression))
    end
    return awaitedType
end

function Checker:checkPrefixUnaryExpression(node)
    local expr = node:AsPrefixUnaryExpression()
    local operandType = self:checkExpression(expr.operand)
    if operandType == self.silentNeverType then
        return self.silentNeverType
    end
    if expr.operand.kind == Kind.NumericLiteral then
        if expr.operator == Kind.MinusToken then
            return self:getFreshTypeOfLiteralType(self:getNumberLiteralType(-jsnum.FromString(expr.operand:Text())))
        elseif expr.operator == Kind.PlusToken then
            return self:getFreshTypeOfLiteralType(self:getNumberLiteralType(jsnum.FromString(expr.operand:Text())))
        end
    elseif expr.operand.kind == Kind.BigIntLiteral then
        if expr.operator == Kind.MinusToken then
            return self:getFreshTypeOfLiteralType(self:getBigIntLiteralType(jsnum.NewPseudoBigInt(jsnum.ParsePseudoBigInt(expr.operand:Text()), true --[[negative]])))
        end
    end
    local operator = expr.operator
    if operator == Kind.PlusToken or operator == Kind.MinusToken or operator == Kind.TildeToken then
        self:checkNonNullType(operandType, expr.operand)
        if self:maybeTypeOfKindConsideringBaseConstraint(operandType, TypeFlags.ESSymbolLike) then
            self:error(expr.operand, diagnostics.The_0_operator_cannot_be_applied_to_type_symbol, scanner.TokenToString(expr.operator))
        end
        if expr.operator == Kind.PlusToken then
            if self:maybeTypeOfKindConsideringBaseConstraint(operandType, TypeFlags.BigIntLike) then
                self:error(expr.operand, diagnostics.Operator_0_cannot_be_applied_to_type_1, scanner.TokenToString(expr.operator), self:TypeToString(self:getBaseTypeOfLiteralType(operandType)))
            end
            return self.numberType
        end
        return self:getUnaryResultType(operandType)
    elseif operator == Kind.ExclamationToken then
        self:checkTruthinessOfType(operandType, expr.operand)
        local facts = self:getTypeFacts(operandType, TypeFacts.Truthy | TypeFacts.Falsy)
        if facts == TypeFacts.Truthy then
            return self.falseType
        elseif facts == TypeFacts.Falsy then
            return self.trueType
        else
            return self.booleanType
        end
    elseif operator == Kind.PlusPlusToken or operator == Kind.MinusMinusToken then
        local ok = self:checkArithmeticOperandType(expr.operand, self:checkNonNullType(operandType, expr.operand), diagnostics.An_arithmetic_operand_must_be_of_type_any_number_bigint_or_an_enum_type, false)
        if ok then
            -- run check only if former checks succeeded to avoid reporting cascading errors
            self:checkReferenceExpression(expr.operand, diagnostics.The_operand_of_an_increment_or_decrement_operator_must_be_a_variable_or_a_property_access, diagnostics.The_operand_of_an_increment_or_decrement_operator_may_not_be_an_optional_property_access)
        end
        return self:getUnaryResultType(operandType)
    end
    return self.errorType
end

function Checker:checkPostfixUnaryExpression(node)
    local expr = node:AsPostfixUnaryExpression()
    local operandType = self:checkExpression(expr.operand)
    if operandType == self.silentNeverType then
        return self.silentNeverType
    end
    local ok = self:checkArithmeticOperandType(expr.operand, self:checkNonNullType(operandType, expr.operand), diagnostics.An_arithmetic_operand_must_be_of_type_any_number_bigint_or_an_enum_type, false)
    if ok then
        -- run check only if former checks succeeded to avoid reporting cascading errors
        self:checkReferenceExpression(expr.operand, diagnostics.The_operand_of_an_increment_or_decrement_operator_must_be_a_variable_or_a_property_access, diagnostics.The_operand_of_an_increment_or_decrement_operator_may_not_be_an_optional_property_access)
    end
    return self:getUnaryResultType(operandType)
end

function Checker:getUnaryResultType(operandType)
    if self:maybeTypeOfKind(operandType, TypeFlags.BigIntLike) then
        if self:isTypeAssignableToKind(operandType, TypeFlags.AnyOrUnknown) or self:maybeTypeOfKind(operandType, TypeFlags.NumberLike) then
            return self.numberOrBigIntType
        end
        return self.bigintType
    end
    -- If it's not a bigint type, implicit coercion will result in a number
    return self.numberType
end

function Checker:checkConditionalExpression(node, checkMode)
    local cond = node:AsConditionalExpression()
    local t = self:checkTruthinessExpression(cond.condition, checkMode)
    self:checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType(cond.condition, t, cond.whenTrue)
    local type1 = self:checkExpressionEx(cond.whenTrue, checkMode)
    local type2 = self:checkExpressionEx(cond.whenFalse, checkMode)
    return self:getUnionTypeEx({ type1, type2 }, UnionReduction.Subtype, nil, nil)
end

function Checker:checkTruthinessExpression(node, checkMode)
    return self:checkTruthinessOfType(self:checkExpressionEx(node, checkMode), node)
end

function Checker:checkSpreadExpression(node, checkMode)
    local arrayOrIterableType = self:checkExpressionEx(node:Expression(), checkMode)
    return self:checkIteratedTypeOrElementType(IterationUse.Spread, arrayOrIterableType, self.undefinedType, node:Expression())
end

function Checker:checkYieldExpression(node)
    self:checkGrammarYieldExpression(node)
    -- Always check the operand so its identifiers are resolved even when the yield is
    -- outside a generator, keeping diagnostics stable regardless of traversal order.
    local yieldExpressionType
    if node:Expression() ~= nil then
        yieldExpressionType = self:checkExpression(node:Expression())
    else
        yieldExpressionType = self.undefinedWideningType
    end
    local fn = ast.GetContainingFunction(node)
    if fn == nil then
        return self.anyType
    end
    local functionFlags = ast.GetFunctionFlags(fn)
    if functionFlags & FunctionFlags.Generator == 0 then
        -- If the user's code is syntactically correct, the func should always have a star. After all, we are in a yield context.
        return self.anyType
    end
    local isAsync = (functionFlags & FunctionFlags.Async) ~= 0
    if node:AsYieldExpression().asteriskToken ~= nil then
        -- Async generator functions prior to ES2018 require the __await, __asyncDelegator,
        -- and __asyncValues helpers
        if isAsync and self.languageVersion < checker.LanguageFeatureMinimumTarget.AsyncGenerators then
            self:checkExternalEmitHelpers(node, ExternalEmitHelpers.AsyncDelegatorIncludes)
        end
    end
    -- There is no point in doing an assignability check if the function
    -- has no explicit return type because the return type is directly computed
    -- from the yield expressions.
    local returnType = self:getReturnTypeFromAnnotation(fn)
    if returnType ~= nil and returnType.flags & TypeFlags.Union ~= 0 then
        returnType = self:filterType(returnType, function(t)
            return self:checkGeneratorInstantiationAssignabilityToReturnType(t, functionFlags, nil --[[errorNode]])
        end)
    end
    local iterationTypes = checker.IterationTypes_new()
    if returnType ~= nil then
        iterationTypes = self:getIterationTypesOfGeneratorFunctionReturnType(returnType, isAsync)
    end
    local signatureYieldType = core.OrElse(iterationTypes.yieldType, self.anyType)
    local signatureNextType = core.OrElse(iterationTypes.nextType, self.anyType)
    local yieldedType = self:getYieldedTypeOfYieldExpression(node, yieldExpressionType, signatureNextType, isAsync)
    if returnType ~= nil and yieldedType ~= nil then
        self:checkTypeAssignableToAndOptionallyElaborate(yieldedType, signatureYieldType, core.OrElse(node:Expression(), node), node:Expression(), nil, nil)
    end
    if node:AsYieldExpression().asteriskToken ~= nil then
        local use = core.IfElse(isAsync, IterationUse.AsyncYieldStar, IterationUse.YieldStar)
        return core.OrElse(self:getIterationTypeOfIterable(use, IterationTypeKind.Return, yieldExpressionType, node:Expression()), self.anyType)
    end
    if returnType ~= nil then
        return core.OrElse(self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Next, returnType, isAsync), self.anyType)
    end
    local t = self:getContextualIterationType(IterationTypeKind.Next, fn)
    if t == nil then
        t = self.anyType
        if self.noImplicitAny and not checker.expressionResultIsUnused(node) then
            local contextualType = self:getContextualType(node, ContextFlags.None)
            if contextualType == nil or checker.IsTypeAny(contextualType) then
                self:error(node, diagnostics.X_yield_expression_implicitly_results_in_an_any_type_because_its_containing_generator_lacks_a_return_type_annotation)
            end
        end
    end
    return t
end

function Checker:getYieldedTypeOfYieldExpression(node, expressionType, sentType, isAsync)
    local errorNode = core.OrElse(node:Expression(), node)
    local isYieldStar = node:AsYieldExpression().asteriskToken ~= nil
    -- A `yield*` expression effectively yields everything that its operand yields
    local yieldedType = expressionType
    if isYieldStar then
        yieldedType = self:checkIteratedTypeOrElementType(core.IfElse(isAsync, IterationUse.AsyncYieldStar, IterationUse.YieldStar), expressionType, sentType, errorNode)
    end
    if not isAsync then
        return yieldedType
    end
    return self:getAwaitedTypeEx(yieldedType, errorNode, core.IfElse(isYieldStar,
        diagnostics.Type_of_iterated_elements_of_a_yield_Asterisk_operand_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member,
        diagnostics.Type_of_yield_operand_in_an_async_generator_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member))
end

function Checker:checkSyntheticExpression(node)
    local t = node:AsSyntheticExpression().type
    if node:AsSyntheticExpression().isSpread then
        return self:getIndexedAccessType(t, self.numberType)
    end
    return t
end

function Checker:checkIdentifier(node, checkMode)
    if ast.IsThisInTypeQuery(node) then
        return self:checkThisExpression(node)
    end
    local symbol = self:getResolvedSymbol(node)
    if symbol == self.unknownSymbol then
        return self.errorType
    end
    if symbol == self.argumentsSymbol then
        if self:isInPropertyInitializerOrClassStaticBlock(node, true --[[ignoreArrowFunctions]]) then
            self:error(node, diagnostics.X_arguments_cannot_be_referenced_in_property_initializers_or_class_static_initialization_blocks)
            return self.errorType
        end
        return self:getTypeOfSymbol(symbol)
    end
    if checker.shouldMarkIdentifierAliasReferenced(node) then
        self:markLinkedReferences(node, ReferenceHint.Identifier, nil --[[propSymbol]], nil --[[parentType]])
    end
    local localOrExportSymbol = self:getExportSymbolOfValueSymbolIfExported(symbol)
    local targetSymbol = self:resolveAliasWithDeprecationCheck(localOrExportSymbol, node)
    if core.Len(targetSymbol.declarations) ~= 0 and self:isDeprecatedSymbol(targetSymbol) and self:isUncalledFunctionReference(node, targetSymbol) then
        self:addDeprecatedSuggestion(node, targetSymbol.declarations, node:Text())
    end
    local declaration = localOrExportSymbol.valueDeclaration
    local immediateDeclaration = declaration
    -- If the identifier is declared in a binding pattern for which we're currently computing the implied type and the
    -- reference occurs with the same binding pattern, return the non-inferrable any type. This for example occurs in
    -- 'const [a, b = a + 1] = [2]' when we're computing the contextual type for the array literal '[2]'.
    if declaration ~= nil and declaration.kind == Kind.BindingElement and containsValue(self.contextualBindingPatterns, declaration.parent) and
        ast.FindAncestor(node, function(parent) return parent == declaration.parent end) ~= nil then
        return self.nonInferrableAnyType
    end
    local t = self:getNarrowedTypeOfSymbol(localOrExportSymbol, node)
    local assignmentKind = checker.getAssignmentTargetKind(node)
    if assignmentKind ~= AssignmentKind.None then
        if localOrExportSymbol.flags & SymbolFlags.Variable == 0 and not (ast.IsInJSFile(node) and localOrExportSymbol.flags & SymbolFlags.ValueModule ~= 0) then
            local assignmentError
            if localOrExportSymbol.flags & SymbolFlags.Enum ~= 0 then
                assignmentError = diagnostics.Cannot_assign_to_0_because_it_is_an_enum
            elseif localOrExportSymbol.flags & SymbolFlags.Class ~= 0 then
                assignmentError = diagnostics.Cannot_assign_to_0_because_it_is_a_class
            elseif localOrExportSymbol.flags & SymbolFlags.Module ~= 0 then
                assignmentError = diagnostics.Cannot_assign_to_0_because_it_is_a_namespace
            elseif localOrExportSymbol.flags & SymbolFlags.Function ~= 0 then
                assignmentError = diagnostics.Cannot_assign_to_0_because_it_is_a_function
            elseif localOrExportSymbol.flags & SymbolFlags.Alias ~= 0 then
                assignmentError = diagnostics.Cannot_assign_to_0_because_it_is_an_import
            else
                assignmentError = diagnostics.Cannot_assign_to_0_because_it_is_not_a_variable
            end
            self:error(node, assignmentError, self:symbolToString(symbol))
            return self.errorType
        end
        if self:isReadonlySymbol(localOrExportSymbol) then
            if localOrExportSymbol.flags & SymbolFlags.Variable ~= 0 then
                self:error(node, diagnostics.Cannot_assign_to_0_because_it_is_a_constant, self:symbolToString(symbol))
            else
                self:error(node, diagnostics.Cannot_assign_to_0_because_it_is_a_read_only_property, self:symbolToString(symbol))
            end
            return self.errorType
        end
    end
    local isAlias = localOrExportSymbol.flags & SymbolFlags.Alias ~= 0
    -- We only narrow variables and parameters occurring in a non-assignment position. For all other
    -- entities we simply return the declared type.
    if localOrExportSymbol.flags & SymbolFlags.Variable ~= 0 then
        if assignmentKind == AssignmentKind.Definite then
            if checker.isInCompoundLikeAssignment(node) then
                return self:getBaseTypeOfLiteralType(t)
            end
            return t
        end
    elseif isAlias then
        declaration = self:getDeclarationOfAliasSymbol(symbol)
    else
        return t
    end
    if declaration == nil then
        return t
    end
    t = self:getNarrowableTypeForReference(t, node, checkMode)
    -- The declaration container is the innermost function that encloses the declaration of the variable
    -- or parameter. The flow container is the innermost function starting with which we analyze the control
    -- flow graph to determine the control flow based type.
    local isParameter = ast.GetRootDeclaration(declaration).kind == Kind.Parameter
    local declarationContainer = self:getControlFlowContainer(declaration)
    local flowContainer = self:getControlFlowContainer(node)
    local isOuterVariable = flowContainer ~= declarationContainer
    local isSpreadDestructuringAssignmentTarget = node.parent ~= nil and node.parent.parent ~= nil and ast.IsSpreadAssignment(node.parent) and self:isDestructuringAssignmentTarget(node.parent.parent)
    local isModuleExports = symbol.flags & SymbolFlags.ModuleExports ~= 0
    local typeIsAutomatic = t == self.autoType or t == self.autoArrayType
    local isAutomaticTypeInNonNull = typeIsAutomatic and node.parent.kind == Kind.NonNullExpression
    -- When the control flow originates in a function expression, arrow function, method, or accessor, and
    -- we are referencing a closed-over const variable or parameter or mutable local variable past its last
    -- assignment, we extend the origin of the control flow analysis to include the immediately enclosing
    -- control flow container.
    while flowContainer ~= declarationContainer and
        (ast.IsFunctionExpressionOrArrowFunction(flowContainer) or ast.IsObjectLiteralOrClassExpressionMethodOrAccessor(flowContainer)) and
        (self:isConstantVariable(localOrExportSymbol) and t ~= self.autoArrayType or self:isParameterOrMutableLocalVariable(localOrExportSymbol) and self:isPastLastAssignment(localOrExportSymbol, node)) do
        flowContainer = self:getControlFlowContainer(flowContainer)
    end
    -- We only look for uninitialized variables in strict null checking mode, and only when we can analyze
    -- the entire control flow graph from the variable's declaration (i.e. when the flow container and
    -- declaration container are the same).
    local isNeverInitialized = immediateDeclaration ~= nil and ast.IsVariableDeclaration(immediateDeclaration) and not ast.IsForInOrOfStatement(immediateDeclaration.parent.parent) and
        immediateDeclaration:Initializer() == nil and immediateDeclaration:AsVariableDeclaration().exclamationToken == nil and
        self:isMutableLocalVariableDeclaration(immediateDeclaration) and not self:isSymbolAssignedDefinitely(symbol)
    local assumeInitialized = isParameter or
        isAlias or
        (isOuterVariable and not isNeverInitialized) or
        isSpreadDestructuringAssignmentTarget or
        isModuleExports or
        self:isSameScopedBindingElement(node, declaration) or
        t ~= self.autoType and t ~= self.autoArrayType and (not self.strictNullChecks or t.flags & (TypeFlags.AnyOrUnknown | TypeFlags.Void) ~= 0 or checker.IsInTypeQuery(node) or self:isInAmbientOrTypeNode(node) or node.parent.kind == Kind.ExportSpecifier) or
        ast.IsNonNullExpression(node.parent) or
        ast.IsVariableDeclaration(declaration) and declaration:AsVariableDeclaration().exclamationToken ~= nil or
        declaration.flags & NodeFlags.Ambient ~= 0
    local initialType
    if isAutomaticTypeInNonNull then
        initialType = self.undefinedType
    elseif assumeInitialized and isParameter then
        initialType = self:removeOptionalityFromDeclaredType(t, declaration)
    elseif assumeInitialized then
        initialType = t
    elseif typeIsAutomatic then
        initialType = self.undefinedType
    else
        initialType = self:getOptionalType(t, false --[[isProperty]])
    end
    local flowType
    if isAutomaticTypeInNonNull then
        flowType = self:GetNonNullableType(self:getFlowTypeOfReferenceEx(node, t, initialType, flowContainer, nil))
    else
        flowType = self:getFlowTypeOfReferenceEx(node, t, initialType, flowContainer, nil)
    end
    -- A variable is considered uninitialized when it is possible to analyze the entire control flow graph
    -- from declaration to use, and when the variable's declared type doesn't include undefined but the
    -- control flow based type does include undefined.
    if not self:isEvolvingArrayOperationTarget(node) and (t == self.autoType or t == self.autoArrayType) then
        if flowType == self.autoType or flowType == self.autoArrayType then
            if self.noImplicitAny then
                self:error(ast.GetNameOfDeclaration(declaration), diagnostics.Variable_0_implicitly_has_type_1_in_some_locations_where_its_type_cannot_be_determined, self:symbolToString(symbol), self:TypeToString(flowType))
                self:error(node, diagnostics.Variable_0_implicitly_has_an_1_type, self:symbolToString(symbol), self:TypeToString(flowType))
            end
            return self:convertAutoToAny(flowType)
        end
    elseif not assumeInitialized and not self:containsUndefinedType(t) and self:containsUndefinedType(flowType) then
        self:error(node, diagnostics.Variable_0_is_used_before_being_assigned, self:symbolToString(symbol))
        -- Return the declared type to reduce follow-on errors
        return t
    end
    if assignmentKind ~= AssignmentKind.None then
        -- Identifier is target of a compound assignment
        return self:getBaseTypeOfLiteralType(flowType)
    end
    return flowType
end

function Checker:isSameScopedBindingElement(node, declaration)
    if ast.IsBindingElement(declaration) then
        local bindingElement = ast.FindAncestor(node, ast.IsBindingElement)
        return bindingElement ~= nil and ast.GetRootDeclaration(bindingElement) == ast.GetRootDeclaration(declaration)
    end
    return false
end

-- Remove undefined from the annotated type of a parameter when there is an initializer (that doesn't include undefined)
function Checker:removeOptionalityFromDeclaredType(declaredType, declaration)
    local removeUndefined = self.strictNullChecks and ast.IsParameterDeclaration(declaration) and declaration:Initializer() ~= nil and self:hasTypeFacts(declaredType, TypeFacts.IsUndefined) and not self:parameterInitializerContainsUndefined(declaration)
    if removeUndefined then
        return self:getTypeWithFacts(declaredType, TypeFacts.NEUndefined)
    end
    return declaredType
end

function Checker:parameterInitializerContainsUndefined(declaration)
    local links = self.nodeLinks:Get(declaration)
    if links.flags & NodeCheckFlags.InitializerIsUndefinedComputed == 0 then
        if not self:pushTypeResolution(declaration, TypeSystemPropertyName.InitializerIsUndefined) then
            self:reportCircularityError(declaration:Symbol())
            return true
        end
        local containsUndefined = self:hasTypeFacts(self:checkDeclarationInitializer(declaration, CheckMode.Normal, nil), TypeFacts.IsUndefined)
        if not self:popTypeResolution() then
            self:reportCircularityError(declaration:Symbol())
            return true
        end
        if links.flags & NodeCheckFlags.InitializerIsUndefinedComputed == 0 then
            links.flags = links.flags | NodeCheckFlags.InitializerIsUndefinedComputed | core.IfElse(containsUndefined, NodeCheckFlags.InitializerIsUndefined, 0)
        end
    end
    return links.flags & NodeCheckFlags.InitializerIsUndefined ~= 0
end

function Checker:isInAmbientOrTypeNode(node)
    return node.flags & NodeFlags.Ambient ~= 0 or ast.FindAncestor(node, function(n)
        return ast.IsInterfaceDeclaration(n) or ast.IsTypeAliasDeclaration(n) or ast.IsJSTypeAliasDeclaration(n) or ast.IsTypeLiteralNode(n)
    end) ~= nil
end

function Checker:checkPropertyAccessExpression(node, checkMode, writeOnly)
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        return self:checkPropertyAccessChain(node, checkMode)
    end
    local expr = node:Expression()
    return self:checkPropertyAccessExpressionOrQualifiedName(node, expr, self:checkNonNullExpression(expr), node:AsPropertyAccessExpression():Name(), checkMode, writeOnly)
end

function Checker:checkPropertyAccessChain(node, checkMode)
    local leftType = self:checkExpression(node:Expression())
    local nonOptionalType = self:getOptionalExpressionType(leftType, node:Expression())
    return self:propagateOptionalTypeMarker(self:checkPropertyAccessExpressionOrQualifiedName(node, node:Expression(), self:checkNonNullType(nonOptionalType, node:Expression()), node:Name(), checkMode, false), node, nonOptionalType ~= leftType)
end

function Checker:checkPropertyAccessExpressionOrQualifiedName(node, left, leftType, right, checkMode, writeOnly)
    local parentSymbol = self:getResolvedSymbolOrNil(left)
    local assignmentKind = checker.getAssignmentTargetKind(node)
    local widenedType = leftType
    if assignmentKind ~= AssignmentKind.None or self:isMethodAccessForCall(node) then
        widenedType = self:getWidenedType(leftType)
    end
    local apparentType = self:getApparentType(widenedType)
    local isAnyLike = checker.IsTypeAny(apparentType) or apparentType == self.silentNeverType
    local prop
    if ast.IsPrivateIdentifier(right) then
        if self.languageVersion < checker.LanguageFeatureMinimumTarget.PrivateNamesAndClassStaticBlocks or
            self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators or
            not self.compilerOptions:GetUseDefineForClassFields() then
            if assignmentKind ~= AssignmentKind.None then
                self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ClassPrivateFieldSet)
            end
            if assignmentKind ~= AssignmentKind.Definite then
                self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ClassPrivateFieldGet)
            end
        end
        local lexicallyScopedSymbol = self:lookupSymbolForPrivateIdentifierDeclaration(right:Text(), right)
        if assignmentKind ~= AssignmentKind.None and lexicallyScopedSymbol ~= nil and lexicallyScopedSymbol.valueDeclaration ~= nil and ast.IsMethodDeclaration(lexicallyScopedSymbol.valueDeclaration) then
            self:grammarErrorOnNode(right, diagnostics.Cannot_assign_to_private_method_0_Private_methods_are_not_writable, right:Text())
        end
        if isAnyLike then
            if lexicallyScopedSymbol ~= nil then
                if self:isErrorType(apparentType) then
                    return self.errorType
                end
                return apparentType
            end
            if checker.getContainingClassExcludingClassDecorators(right) == nil then
                self:grammarErrorOnNode(right, diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies)
                return self.anyType
            end
        end
        if lexicallyScopedSymbol ~= nil then
            prop = self:getPrivateIdentifierPropertyOfType(leftType, lexicallyScopedSymbol)
        end
        if prop == nil then
            -- Check for private-identifier-specific shadowing and lexical-scoping errors.
            if self:checkPrivateIdentifierPropertyAccess(leftType, right, lexicallyScopedSymbol) then
                return self.errorType
            end
            local containingClass = checker.getContainingClassExcludingClassDecorators(right)
            if containingClass ~= nil and ast.IsPlainJSFile(ast.GetSourceFileOfNode(containingClass), self.compilerOptions.checkJs) then
                self:grammarErrorOnNode(right, diagnostics.Private_field_0_must_be_declared_in_an_enclosing_class, right:Text())
            end
        else
            local isSetonlyAccessor = prop.flags & SymbolFlags.SetAccessor ~= 0 and prop.flags & SymbolFlags.GetAccessor == 0
            if isSetonlyAccessor and assignmentKind ~= AssignmentKind.Definite then
                self:error(node, diagnostics.Private_accessor_was_defined_without_a_getter)
            end
        end
    else
        if isAnyLike then
            if ast.IsIdentifier(left) and parentSymbol ~= nil then
                self:markLinkedReferences(node, ReferenceHint.Property, nil --[[propSymbol]], leftType)
            end
            if self:isErrorType(apparentType) then
                return self.errorType
            end
            return apparentType
        end
        prop = self:getPropertyOfTypeEx(apparentType, right:Text(), checker.isConstEnumObjectType(apparentType) --[[skipObjectFunctionPropertyAugment]], node.kind == Kind.QualifiedName --[[includeTypeOnlyMembers]])
    end
    self:markLinkedReferences(node, ReferenceHint.Property, prop, leftType)
    local propType
    if prop == nil then
        local indexInfo
        if not ast.IsPrivateIdentifier(right) and (assignmentKind == AssignmentKind.None or not self:isGenericObjectType(leftType) or checker.isThisTypeParameter(leftType)) then
            indexInfo = self:getApplicableIndexInfoForName(apparentType, right:Text())
        end
        if indexInfo == nil then
            local isUncheckedJS = self:isUncheckedJSSuggestion(node, leftType.symbol, true --[[excludeClasses]])
            if not isUncheckedJS and self:isJSLiteralType(leftType) then
                return self.anyType
            end
            if leftType.symbol == self.globalThisSymbol then
                local globalSymbol = self.globalThisSymbol.exports[right:Text()]
                if globalSymbol ~= nil and globalSymbol.flags & SymbolFlags.BlockScoped ~= 0 then
                    self:error(right, diagnostics.Property_0_does_not_exist_on_type_1, right:Text(), self:TypeToString(leftType))
                elseif self.noImplicitAny then
                    self:error(right, diagnostics.Element_implicitly_has_an_any_type_because_type_0_has_no_index_signature, self:TypeToString(leftType))
                end
                return self.anyType
            end
            if right:Text() ~= "" and not self:checkAndReportErrorForExtendingInterface(node) then
                self:addDeferredDiagnostic(function()
                    -- must be deferred because reporting this error can cause us to materialize the containing type completely (to print it), leading to erroneous circularity errors
                    self:reportNonexistentProperty(right, core.IfElse(checker.isThisTypeParameter(leftType), apparentType, leftType), isUncheckedJS)
                end)
            end
            return self.errorType
        end
        if indexInfo.isReadonly and (ast.IsAssignmentTarget(node) or checker.isDeleteTarget(node)) then
            self:error(node, diagnostics.Index_signature_in_type_0_only_permits_reading, self:TypeToString(apparentType))
        end
        propType = indexInfo.valueType
        if self.compilerOptions.noUncheckedIndexedAccess == Tristate.TSTrue and checker.getAssignmentTargetKind(node) ~= AssignmentKind.Definite then
            propType = self:getUnionType({ propType, self.missingType })
        end
        if self.compilerOptions.noPropertyAccessFromIndexSignature == Tristate.TSTrue and ast.IsPropertyAccessExpression(node) then
            self:error(right, diagnostics.Property_0_comes_from_an_index_signature_so_it_must_be_accessed_with_0, right:Text())
        end
        if indexInfo.declaration ~= nil and self:IsDeprecatedDeclaration(indexInfo.declaration) then
            self:addDeprecatedSuggestion(right, { indexInfo.declaration }, right:Text())
        end
    else
        local targetPropSymbol = self:resolveAliasWithDeprecationCheck(prop, right)
        if self:isDeprecatedSymbol(targetPropSymbol) and self:isUncalledFunctionReference(node, targetPropSymbol) and targetPropSymbol.declarations ~= nil then
            self:addDeprecatedSuggestion(right, targetPropSymbol.declarations, right:Text())
        end
        self:checkPropertyNotUsedBeforeDeclaration(prop, node, right)
        self:markPropertyAsReferenced(prop, node, self:isSelfTypeAccess(left, parentSymbol))
        self.symbolNodeLinks:Get(node).resolvedSymbol = prop
        self:checkPropertyAccessibility(node, left.kind == Kind.SuperKeyword, ast.IsWriteAccess(node), apparentType, prop)
        if self:isAssignmentToReadonlyEntity(node, prop, assignmentKind) then
            self:error(right, diagnostics.Cannot_assign_to_0_because_it_is_a_read_only_property, right:Text())
            return self.errorType
        end
        if self:isThisPropertyAccessInConstructor(node, prop) then
            propType = self.autoType
        elseif writeOnly or ast.IsWriteOnlyAccess(node) then
            propType = self:getWriteTypeOfSymbol(prop)
        else
            propType = self:getTypeOfSymbol(prop)
        end
    end
    return self:getFlowTypeOfAccessExpression(node, prop, propType, right, checkMode)
end


function Checker:getFlowTypeOfAccessExpression(node, prop, propType, errorNode, checkMode)
    -- Only compute control flow type if this is a property access expression that isn't an
    -- assignment target, and the referenced property was declared as a variable, property,
    -- accessor, or optional method.
    local assignmentKind = checker.getAssignmentTargetKind(node)
    if assignmentKind == AssignmentKind.Definite then
        return self:removeMissingType(propType, prop ~= nil and prop.flags & SymbolFlags.Optional ~= 0)
    end
    if prop ~= nil and prop.flags & (SymbolFlags.Variable | SymbolFlags.Property | SymbolFlags.Accessor) == 0 and not (prop.flags & SymbolFlags.Method ~= 0 and propType.flags & TypeFlags.Union ~= 0) then
        return propType
    end
    if propType == self.autoType then
        return self:getFlowTypeOfProperty(node, prop)
    end
    propType = self:getNarrowableTypeForReference(propType, node, checkMode)
    -- If strict null checks and strict property initialization checks are enabled, if we have
    -- a this.xxx property access, if the property is an instance property without an initializer,
    -- and if we are in a constructor of the same class as the property declaration, assume that
    -- the property is uninitialized at the top of the control flow.
    local assumeUninitialized = false
    if self.strictNullChecks and prop ~= nil then
        local declaration = prop.valueDeclaration
        if declaration ~= nil then
            if self.strictPropertyInitialization and ast.IsAccessExpression(node) and node:Expression().kind == Kind.ThisKeyword and
                self:isPropertyWithoutInitializer(declaration) and not ast.IsStatic(declaration) then
                local flowContainer = self:getControlFlowContainer(node)
                if ast.IsConstructorDeclaration(flowContainer) and flowContainer.parent == declaration.parent and declaration.flags & NodeFlags.Ambient == 0 then
                    assumeUninitialized = true
                end
            elseif ast.IsBinaryExpression(declaration) and ast.IsPropertyAccessExpression(declaration:AsBinaryExpression().left) and
                self:getControlFlowContainer(node) == self:getControlFlowContainer(declaration) then
                assumeUninitialized = true
            end
        end
    end
    local flowType = self:getFlowTypeOfReferenceEx(node, propType, self:addOptionalityEx(propType, false --[[isProperty]], assumeUninitialized), nil, nil)
    if assumeUninitialized and not self:containsUndefinedType(propType) and self:containsUndefinedType(flowType) then
        self:error(errorNode, diagnostics.Property_0_is_used_before_being_assigned, self:symbolToString(prop))
        -- Return the declared type to reduce follow-on errors
        return propType
    end
    if assignmentKind ~= AssignmentKind.None then
        return self:getBaseTypeOfLiteralType(flowType)
    end
    return flowType
end

function Checker:getControlFlowContainer(node)
    return ast.FindAncestor(node.parent, function(n)
        return ast.IsFunctionLike(n) and ast.GetImmediatelyInvokedFunctionExpression(n) == nil or ast.IsModuleBlock(n) or ast.IsSourceFile(n) or ast.IsPropertyDeclaration(n)
    end)
end

function Checker:getFlowTypeOfProperty(reference, prop)
    local initialType = self.undefinedType
    if prop ~= nil and prop.valueDeclaration ~= nil and (not self:isAutoTypedProperty(prop) or prop.valueDeclaration:ModifierFlags() & ModifierFlags.Ambient ~= 0) then
        local baseType = self:getTypeOfPropertyInBaseClass(prop)
        if baseType ~= nil then
            initialType = baseType
        end
    end
    return self:getFlowTypeOfReferenceEx(reference, self.autoType, initialType, nil, nil)
end

-- Return the inherited type of the given property or undefined if property doesn't exist in a base class.
function Checker:getTypeOfPropertyInBaseClass(property)
    local classType = self:getDeclaringClass(property)
    if classType ~= nil then
        local baseClassTypes = self:getBaseTypes(classType)
        if core.Len(baseClassTypes) > 0 then
            return self:getTypeOfPropertyOfType(baseClassTypes[1], property.name)
        end
    end
    return nil
end

function Checker:isMethodAccessForCall(node)
    while ast.IsParenthesizedExpression(node.parent) do
        node = node.parent
    end
    return ast.IsCallOrNewExpression(node.parent) and node.parent:Expression() == node
end

-- Lookup the private identifier lexically.
function Checker:lookupSymbolForPrivateIdentifierDeclaration(propName, location)
    local containingClass = checker.getContainingClassExcludingClassDecorators(location)
    while containingClass ~= nil do
        local symbol = containingClass:Symbol()
        local name = binder.GetSymbolNameForPrivateIdentifier(symbol, propName)
        local prop = symbol.members ~= nil and symbol.members[name] or nil
        if prop ~= nil then
            return prop
        end
        prop = symbol.exports ~= nil and symbol.exports[name] or nil
        if prop ~= nil then
            return prop
        end
        containingClass = ast.GetContainingClass(containingClass)
    end
    return nil
end

function Checker:getPrivateIdentifierPropertyOfType(leftType, lexicallyScopedIdentifier)
    return self:getPropertyOfType(leftType, lexicallyScopedIdentifier.name)
end

function Checker:checkPrivateIdentifierPropertyAccess(leftType, right, lexicallyScopedIdentifier)
    -- Either the identifier could not be looked up in the lexical scope OR the lexically scoped identifier did not exist on the type.
    -- Find a private identifier with the same description on the type.
    local properties = self:getPropertiesOfType(leftType)
    local propertyOnType = nil
    for _, symbol in ipairs(properties or {}) do
        local decl = symbol.valueDeclaration
        if decl ~= nil and decl:Name() ~= nil and ast.IsPrivateIdentifier(decl:Name()) and decl:Name():Text() == right:Text() then
            propertyOnType = symbol
            break
        end
    end
    local diagName = scanner.DeclarationNameToString(right)
    if propertyOnType ~= nil then
        local typeValueDecl = propertyOnType.valueDeclaration
        local typeClass = ast.GetContainingClass(typeValueDecl)
        -- We found a private identifier property with the same description.
        -- Either:
        -- - There is a lexically scoped private identifier AND it shadows the one we found on the type.
        -- - It is an attempt to access the private identifier outside of the class.
        if lexicallyScopedIdentifier ~= nil and lexicallyScopedIdentifier.valueDeclaration ~= nil then
            local lexicalValueDecl = lexicallyScopedIdentifier.valueDeclaration
            local lexicalClass = ast.GetContainingClass(lexicalValueDecl)
            if ast.FindAncestor(lexicalClass, function(n) return typeClass == n end) ~= nil then
                local diagnostic = self:error(right, diagnostics.The_property_0_cannot_be_accessed_on_type_1_within_this_class_because_it_is_shadowed_by_another_private_identifier_with_the_same_spelling, diagName, self:TypeToString(leftType))
                diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(lexicalValueDecl, diagnostics.The_shadowing_declaration_of_0_is_defined_here, diagName))
                diagnostic:AddRelatedInfo(checker.createDiagnosticForNode(typeValueDecl, diagnostics.The_declaration_of_0_that_you_probably_intended_to_use_is_defined_here, diagName))
                return true
            end
        end
        self:error(right, diagnostics.Property_0_is_not_accessible_outside_class_1_because_it_has_a_private_identifier, diagName, self:SymbolToString(typeClass:Symbol()))
        return true
    end
    return false
end

function Checker:reportNonexistentProperty(propNode, containingType, isUncheckedJS)
    local key = checker.NonExistentPropertyKey(propNode, containingType, isUncheckedJS)
    if self.nonExistentProperties:Has(key) then
        return
    end
    self.nonExistentProperties:Add(key)
    local links = self.nodeLinks:Get(propNode)
    if links.flags & NodeCheckFlags.TypeChecked ~= 0 then
        return -- error already made/in progress
    end
    links.flags = links.flags | NodeCheckFlags.TypeChecked
    if ast.IsJSDocNameReferenceContext(propNode) then
        return
    end
    local diagnostic = nil
    if not ast.IsPrivateIdentifier(propNode) and containingType.flags & TypeFlags.Union ~= 0 and containingType.flags & TypeFlags.Primitive == 0 then
        for _, subtype in ipairs(containingType:Types()) do
            if self:getPropertyOfType(subtype, propNode:Text()) == nil and self:getApplicableIndexInfoForName(subtype, propNode:Text()) == nil then
                diagnostic = checker.NewDiagnosticChainForNode(diagnostic, propNode, diagnostics.Property_0_does_not_exist_on_type_1, scanner.DeclarationNameToString(propNode), self:TypeToString(subtype))
                break
            end
        end
    end
    if self:typeHasStaticProperty(propNode:Text(), containingType) then
        local propName = scanner.DeclarationNameToString(propNode)
        local typeName = self:TypeToString(containingType)
        diagnostic = checker.NewDiagnosticChainForNode(diagnostic, propNode, diagnostics.Property_0_does_not_exist_on_type_1_Did_you_mean_to_access_the_static_member_2_instead, propName, typeName, typeName .. "." .. propName)
    else
        local promisedType = self:GetPromisedTypeOfPromise(containingType)
        if promisedType ~= nil and self:getPropertyOfType(promisedType, propNode:Text()) ~= nil then
            diagnostic = checker.NewDiagnosticChainForNode(diagnostic, propNode, diagnostics.Property_0_does_not_exist_on_type_1, scanner.DeclarationNameToString(propNode), self:TypeToString(containingType))
            diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(propNode, diagnostics.Did_you_forget_to_use_await))
        else
            local missingProperty = scanner.DeclarationNameToString(propNode)
            local container = self:TypeToString(containingType)
            local libSuggestion = self:getSuggestedLibForNonExistentProperty(missingProperty, containingType)
            if libSuggestion ~= "" then
                diagnostic = checker.NewDiagnosticChainForNode(diagnostic, propNode, diagnostics.Property_0_does_not_exist_on_type_1_Do_you_need_to_change_your_target_library_Try_changing_the_lib_compiler_option_to_2_or_later, missingProperty, container, libSuggestion)
            else
                local suggestion = self:getSuggestedSymbolForNonexistentProperty(propNode, containingType)
                if suggestion ~= nil then
                    local suggestedName = ast.SymbolName(suggestion)
                    local message = core.IfElse(isUncheckedJS, diagnostics.Property_0_may_not_exist_on_type_1_Did_you_mean_2, diagnostics.Property_0_does_not_exist_on_type_1_Did_you_mean_2)
                    diagnostic = checker.NewDiagnosticChainForNode(diagnostic, propNode, message, missingProperty, container, suggestedName)
                    if suggestion.valueDeclaration ~= nil then
                        diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(suggestion.valueDeclaration, diagnostics.X_0_is_declared_here, suggestedName))
                    end
                else
                    diagnostic = self:elaborateNeverIntersection(diagnostic, propNode, containingType)
                    local message
                    if self:containerSeemsToBeEmptyDomElement(containingType) then
                        message = diagnostics.Property_0_does_not_exist_on_type_1_Try_changing_the_lib_compiler_option_to_include_dom
                    else
                        message = diagnostics.Property_0_does_not_exist_on_type_1
                    end
                    diagnostic = checker.NewDiagnosticChainForNode(diagnostic, propNode, message, missingProperty, container)
                end
            end
        end
    end
    self:addErrorOrSuggestion(not isUncheckedJS or diagnostic:Code() ~= diagnostics.Property_0_may_not_exist_on_type_1_Did_you_mean_2:Code(), diagnostic)
end

function Checker:getSuggestedLibForNonExistentProperty(missingProperty, containingType)
    local container = self:getApparentType(containingType).symbol
    if container ~= nil then
        local featureMap = checker.getFeatureMap()
        local typeFeatures = featureMap[container.name]
        if typeFeatures ~= nil then
            for _, entry in ipairs(typeFeatures) do
                if containsValue(entry.props, missingProperty) then
                    return entry.lib
                end
            end
        end
    end
    return ""
end

function Checker:getSuggestedSymbolForNonexistentProperty(name, containingType)
    local props = self:getPropertiesOfType(containingType)
    local parent = name.parent
    if ast.IsPropertyAccessExpression(parent) then
        props = core.Filter(props, function(prop)
            return self:isValidPropertyAccessForCompletions(parent, containingType, prop)
        end)
    end
    return self:getSpellingSuggestionForName(name:Text(), props or {}, SymbolFlags.Value)
end

-- Checks if an existing property access is valid for completions purposes.
-- @param node a property access-like node where we want to check if we can access a property.
-- This node does not need to be an access of the property we are checking.
-- e.g. in completions, this node will often be an incomplete property access node, as in `foo.`.
-- Besides providing a location (i.e. scope) used to check property accessibility, we use this node for
-- computing whether this is a `super` property access.
-- @param type the type whose property we are checking.
-- @param property the accessed property's symbol.
function Checker:isValidPropertyAccessForCompletions(node, t, property)
    return self:isPropertyAccessible(node, ast.IsPropertyAccessExpression(node) and node:Expression().kind == Kind.SuperKeyword, false --[[isWrite]], t, property)
    -- Previously we validated the 'this' type of methods but this adversely affected performance. See #31377 for more context.
end

-- Checks if a property can be accessed in a location.
-- The location is given by the `node` parameter.
-- The node does not need to be a property access.
-- @param node location where to check property accessibility
-- @param isSuper whether to consider this a `super` property access, e.g. `super.foo`.
-- @param isWrite whether this is a write access, e.g. `++foo.x`.
-- @param containingType type where the property comes from.
-- @param property property symbol.
function Checker:isPropertyAccessible(node, isSuper, isWrite, containingType, property)
    -- Short-circuiting for improved performance.
    if checker.IsTypeAny(containingType) then
        return true
    end
    -- A #private property access in an optional chain is an error dealt with by the parser.
    -- The checker does not check for it, so we need to do our own check here.
    if property.valueDeclaration ~= nil and ast.IsPrivateIdentifierClassElementDeclaration(property.valueDeclaration) then
        local declClass = ast.GetContainingClass(property.valueDeclaration)
        return not ast.IsOptionalChain(node) and ast.IsNodeDescendantOf(node, declClass)
    end
    return self:checkPropertyAccessibilityAtLocation(node, isSuper, isWrite, containingType, property, nil)
end

function Checker:containerSeemsToBeEmptyDomElement(containingType)
    return not containsValue(self.compilerOptions.lib, "lib.dom.d.ts") and checker.everyContainedType(containingType, checker.hasCommonDomTypeName) and self:isEmptyObjectType(containingType)
end

function checker.hasCommonDomTypeName(t)
    if t.symbol == nil then
        return false
    end
    local name = t.symbol.name
    return name == "EventTarget" or name == "Node" or name == "Element" or stringutil.HasPrefix(name, "HTML") and stringutil.HasSuffix(name, "Element")
end

function Checker:checkAndReportErrorForExtendingInterface(errorLocation)
    local expression = self:getEntityNameForExtendingInterface(errorLocation)
    if expression ~= nil and self:resolveEntityName(expression, SymbolFlags.Interface, true --[[ignoreErrors]], false, nil) ~= nil then
        self:error(errorLocation, diagnostics.Cannot_extend_an_interface_0_Did_you_mean_implements, scanner.GetTextOfNode(expression))
        return true
    end
    return false
end

--
-- Climbs up parents to a heritage clause element and returns its entity name.
--
function Checker:getEntityNameForExtendingInterface(node)
    local kind = node.kind
    if kind == Kind.Identifier or kind == Kind.QualifiedName or kind == Kind.PropertyAccessExpression then
        if node.parent ~= nil then
            return self:getEntityNameForExtendingInterface(node.parent)
        end
    elseif kind == Kind.TypeReference then
        return node:AsTypeReferenceNode().typeName
    elseif kind == Kind.ExpressionWithTypeArguments then
        if ast.IsEntityNameExpression(node:Expression()) then
            return node:Expression()
        end
    end
    return nil
end

function Checker:isUncalledFunctionReference(node, symbol)
    if symbol.flags & (SymbolFlags.Function | SymbolFlags.Method) ~= 0 then
        local parent = ast.FindAncestor(node.parent, function(n) return not ast.IsAccessExpression(n) end)
        if parent == nil then
            parent = node.parent
        end
        if ast.IsCallLikeExpression(parent) then
            return ast.IsCallOrNewExpression(parent) and ast.IsIdentifier(node) and self:hasMatchingArgument(parent, node)
        end
        return core.Every(symbol.declarations, function(d)
            return not ast.IsFunctionLike(d) or self:IsDeprecatedDeclaration(d)
        end)
    end
    return true
end

function Checker:checkPropertyNotUsedBeforeDeclaration(prop, node, right)
    local valueDeclaration = prop.valueDeclaration
    if valueDeclaration == nil or ast.GetSourceFileOfNode(node).isDeclarationFile then
        return
    end
    local diagnostic = nil
    local declarationName = right:Text()
    if self:isInPropertyInitializerOrClassStaticBlock(node, false --[[ignoreArrowFunctions]]) and
        not self:isOptionalPropertyDeclaration(valueDeclaration) and
        not (ast.IsAccessExpression(node) and ast.IsAccessExpression(node:Expression())) and
        not self:isBlockScopedNameDeclaredBeforeUse(valueDeclaration, right) and
        not (ast.IsMethodDeclaration(valueDeclaration) and self:getCombinedModifierFlagsCached(valueDeclaration) & ModifierFlags.Static ~= 0) and
        (self.compilerOptions:GetUseDefineForClassFields() or not self:isPropertyDeclaredInAncestorClass(prop)) then
        diagnostic = self:error(right, diagnostics.Property_0_is_used_before_its_initialization, declarationName)
    elseif ast.IsClassDeclaration(valueDeclaration) and not ast.IsTypeReferenceNode(node.parent) and valueDeclaration.flags & NodeFlags.Ambient == 0 and not self:isBlockScopedNameDeclaredBeforeUse(valueDeclaration, right) then
        diagnostic = self:error(right, diagnostics.Class_0_used_before_its_declaration, declarationName)
    end
    if diagnostic ~= nil then
        diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(valueDeclaration, diagnostics.X_0_is_declared_here, declarationName))
    end
end

function Checker:isOptionalPropertyDeclaration(node)
    return ast.IsPropertyDeclaration(node) and not ast.HasAccessorModifier(node) and ast.IsQuestionToken(node:PostfixToken())
end

function Checker:isPropertyDeclaredInAncestorClass(prop)
    if prop.parent.flags & SymbolFlags.Class ~= 0 then
        local baseTypes = self:getBaseTypes(self:getDeclaredTypeOfSymbol(prop.parent))
        if core.Len(baseTypes) ~= 0 then
            local superProperty = self:getPropertyOfType(baseTypes[1], prop.name)
            return superProperty ~= nil and superProperty.valueDeclaration ~= nil
        end
    end
    return false
end

--
-- Check whether the requested property access is valid.
-- Returns true if node is a valid property access, and false otherwise.
-- @param node The node to be checked.
-- @param isSuper True if the access is from `super.`.
-- @param type The type of the object whose property is being accessed. (Not the type of the property.)
-- @param prop The symbol for the property being accessed.
--
function Checker:checkPropertyAccessibility(node, isSuper, writing, t, prop)
    return self:checkPropertyAccessibilityEx(node, isSuper, writing, t, prop, true --[[reportError]])
end

function Checker:checkPropertyAccessibilityEx(node, isSuper, writing, t, prop, reportError)
    local errorNode = nil
    if reportError then
        local kind = node.kind
        if kind == Kind.PropertyAccessExpression then
            errorNode = node:AsPropertyAccessExpression():Name()
        elseif kind == Kind.QualifiedName then
            errorNode = node:AsQualifiedName().right
        elseif kind == Kind.ImportType then
            errorNode = node
        elseif kind == Kind.BindingElement then
            errorNode = checker.getBindingElementPropertyName(node)
        else
            errorNode = node:Name()
        end
    end
    return self:checkPropertyAccessibilityAtLocation(node, isSuper, writing, t, prop, errorNode)
end


--
-- Check whether the requested property can be accessed at the requested location.
-- Returns true if node is a valid property access, and false otherwise.
-- @param location The location node where we want to check if the property is accessible.
-- @param isSuper True if the access is from `super.`.
-- @param writing True if this is a write property access, false if it is a read property access.
-- @param containingType The type of the object whose property is being accessed. (Not the type of the property.)
-- @param prop The symbol for the property being accessed.
-- @param errorNode The node where we should report an invalid property access error, or undefined if we should not report errors.
--
function Checker:checkPropertyAccessibilityAtLocation(location, isSuper, writing, containingType, prop, errorNode)
    local flags = checker.getDeclarationModifierFlagsFromSymbolEx(prop, writing)
    if isSuper then
        -- TS 1.0 spec (April 2014): 4.8.2
        -- - In a constructor, instance member function, instance member accessor, or
        --   instance member variable initializer where this references a derived class instance,
        --   a super property access is permitted and must specify a public instance member function of the base class.
        -- - In a static member function or static member accessor
        --   where this references the constructor function object of a derived class,
        --   a super property access is permitted and must specify a public static member function of the base class.
        if flags & ModifierFlags.Abstract ~= 0 then
            -- A method cannot be accessed in a super property access if the method is abstract.
            -- This error could mask a private property access error. But, a member
            -- cannot simultaneously be private and abstract, so this will trigger an
            -- additional error elsewhere.
            if errorNode ~= nil then
                self:error(errorNode, diagnostics.Abstract_method_0_in_class_1_cannot_be_accessed_via_super_expression, self:symbolToString(prop), self:TypeToString(self:getDeclaringClass(prop)))
            end
            return false
        end
        -- A class field cannot be accessed via super.* from a derived class.
        -- This is true for both [[Set]] (old) and [[Define]] (ES spec) semantics.
        if flags & ModifierFlags.Static == 0 and core.Some(prop.declarations, checker.isClassInstanceProperty) then
            if errorNode ~= nil then
                self:error(errorNode, diagnostics.Class_field_0_defined_by_the_parent_class_is_not_accessible_in_the_child_class_via_super, self:symbolToString(prop))
            end
            return false
        end
    end
    -- Referencing abstract properties within their own constructors is not allowed
    if flags & ModifierFlags.Abstract ~= 0 and self:symbolHasNonMethodDeclaration(prop) and (checker.isThisProperty(location) or
        checker.isThisInitializedObjectBindingExpression(location) or
        ast.IsObjectBindingPattern(location.parent) and checker.isThisInitializedDeclaration(location.parent.parent)) then
        local parentSymbol = self:getParentOfSymbol(prop)
        if parentSymbol ~= nil and parentSymbol.flags & SymbolFlags.Class ~= 0 and self:isNodeUsedDuringClassInitialization(location) then
            if errorNode ~= nil then
                self:error(errorNode, diagnostics.Abstract_property_0_in_class_1_cannot_be_accessed_in_the_constructor, self:symbolToString(prop), self:symbolToString(parentSymbol))
            end
            return false
        end
    end
    -- Public properties are otherwise accessible.
    if flags & ModifierFlags.NonPublicAccessibilityModifier == 0 then
        return true
    end
    -- Property is known to be private or protected at this point
    -- Private property is accessible if the property is within the declaring class
    if flags & ModifierFlags.Private ~= 0 then
        local declaringClassDeclaration = ast.GetClassLikeDeclarationOfSymbol(self:getParentOfSymbol(prop))
        if not self:isNodeWithinClass(location, declaringClassDeclaration) then
            if errorNode ~= nil then
                self:error(errorNode, diagnostics.Property_0_is_private_and_only_accessible_within_class_1, self:symbolToString(prop), self:TypeToString(self:getDeclaringClass(prop)))
            end
            return false
        end
        return true
    end
    -- Property is known to be protected at this point
    -- All protected properties of a supertype are accessible in a super access
    if isSuper then
        return true
    end
    -- Find the first enclosing class that has the declaring classes of the protected constituents
    -- of the property as base classes
    local enclosingClass = nil
    local container = ast.GetContainingClass(location)
    while container ~= nil do
        local class = self:getDeclaredTypeOfSymbol(self:getSymbolOfDeclaration(container))
        if self:isClassDerivedFromDeclaringClasses(class, prop, writing) then
            enclosingClass = class
            break
        end
        container = ast.GetContainingClass(container)
    end
    -- A protected property is accessible if the property is within the declaring class or classes derived from it
    if enclosingClass == nil then
        -- allow PropertyAccessibility if context is in function with this parameter
        -- static member access is disallowed
        local class = self:getEnclosingClassFromThisParameter(location)
        if class ~= nil and self:isClassDerivedFromDeclaringClasses(class, prop, writing) then
            enclosingClass = class
        end
        if flags & ModifierFlags.Static ~= 0 or enclosingClass == nil then
            if errorNode ~= nil then
                local class2 = self:getDeclaringClass(prop)
                if class2 == nil then
                    class2 = containingType
                end
                self:error(errorNode, diagnostics.Property_0_is_protected_and_only_accessible_within_class_1_and_its_subclasses, self:symbolToString(prop), self:TypeToString(class2))
            end
            return false
        end
    end
    -- No further restrictions for static properties
    if flags & ModifierFlags.Static ~= 0 then
        return true
    end
    if containingType.flags & TypeFlags.TypeParameter ~= 0 then
        -- get the original type -- represented as the type constraint of the 'this' type
        if containingType:AsTypeParameter().isThisType then
            containingType = self:getConstraintOfTypeParameter(containingType)
        else
            containingType = self:getBaseConstraintOfType(containingType)
        end
    end
    if containingType == nil or not self:hasBaseType(containingType, enclosingClass) then
        if errorNode ~= nil and containingType ~= nil then
            self:error(errorNode, diagnostics.Property_0_is_protected_and_only_accessible_through_an_instance_of_class_1_This_is_an_instance_of_class_2, self:symbolToString(prop), self:TypeToString(enclosingClass), self:TypeToString(containingType))
        end
        return false
    end
    return true
end

function Checker:symbolHasNonMethodDeclaration(symbol)
    return self:forEachProperty(symbol, function(prop) return prop.flags & SymbolFlags.Method == 0 end)
end

-- Invoke the callback for each underlying property symbol of the given symbol and return the first
-- value that isn't undefined.
function Checker:forEachProperty(prop, callback)
    if prop.checkFlags & CheckFlags.Synthetic == 0 then
        return callback(prop)
    end
    for _, t in ipairs(self.valueSymbolLinks:Get(prop).containingType:Types()) do
        local p = self:getPropertyOfType(t, prop.name)
        if p ~= nil and self:forEachProperty(p, callback) then
            return true
        end
    end
    return false
end

-- Return the declaring class type of a property or undefined if property not declared in class
function Checker:getDeclaringClass(prop)
    if prop.parent ~= nil and prop.parent.flags & SymbolFlags.Class ~= 0 then
        return self:getDeclaredTypeOfSymbol(self:getParentOfSymbol(prop))
    end
    return nil
end

-- Return true if source property is a valid override of protected parts of target property.
function Checker:isValidOverrideOf(sourceProp, targetProp)
    return not self:forEachProperty(targetProp, function(tp)
        if checker.getDeclarationModifierFlagsFromSymbol(tp) & ModifierFlags.Protected ~= 0 then
            return not self:isPropertyInClassDerivedFrom(sourceProp, self:getDeclaringClass(tp))
        end
        return false
    end)
end

-- Return true if some underlying source property is declared in a class that derives
-- from the given base class.
function Checker:isPropertyInClassDerivedFrom(prop, baseClass)
    return self:forEachProperty(prop, function(sp)
        local sourceClass = self:getDeclaringClass(sp)
        if sourceClass ~= nil then
            return self:hasBaseType(sourceClass, baseClass)
        end
        return false
    end)
end

function Checker:isNodeUsedDuringClassInitialization(node)
    return ast.FindAncestorOrQuit(node, function(element)
        if ast.IsConstructorDeclaration(element) and ast.NodeIsPresent(element:Body()) or ast.IsPropertyDeclaration(element) then
            return FindAncestorResult.FindAncestorTrue
        elseif ast.IsClassLike(element) or ast.IsFunctionLikeDeclaration(element) then
            return FindAncestorResult.FindAncestorQuit
        end
        return FindAncestorResult.FindAncestorFalse
    end) ~= nil
end

function Checker:isNodeWithinClass(node, classDeclaration)
    return self:forEachEnclosingClass(node, function(n) return n == classDeclaration end)
end

function Checker:forEachEnclosingClass(node, callback)
    local containingClass = ast.GetContainingClass(node)
    while containingClass ~= nil do
        local result = callback(containingClass)
        if result then
            return true
        end
        containingClass = ast.GetContainingClass(containingClass)
    end
    return false
end

-- Return true if the given class derives from each of the declaring classes of the protected
-- constituents of the given property.
function Checker:isClassDerivedFromDeclaringClasses(checkClass, prop, writing)
    return not self:forEachProperty(prop, function(p)
        if checker.getDeclarationModifierFlagsFromSymbolEx(p, writing) & ModifierFlags.Protected ~= 0 then
            return not self:hasBaseType(checkClass, self:getDeclaringClass(p))
        end
        return false
    end)
end

function Checker:getEnclosingClassFromThisParameter(node)
    -- 'this' type for a node comes from, in priority order...
    -- 1. The type of a syntactic 'this' parameter in the enclosing function scope
    local thisParameter = checker.getThisParameterFromNodeContext(node)
    local thisType = nil
    if thisParameter ~= nil and thisParameter:Type() ~= nil then
        thisType = self:getTypeFromTypeNode(thisParameter:Type())
    end
    if thisType ~= nil then
        -- 2. The constraint of a type parameter used for an explicit 'this' parameter
        if thisType.flags & TypeFlags.TypeParameter ~= 0 then
            thisType = self:getConstraintOfTypeParameter(thisType)
        end
    else
        -- 3. The 'this' parameter of a contextual type
        local thisContainer = ast.GetThisContainer(node, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
        if thisContainer ~= nil and ast.IsFunctionLike(thisContainer) then
            thisType = self:getContextualThisParameterType(thisContainer)
        end
    end
    if thisType ~= nil and thisType.objectFlags & (ObjectFlags.ClassOrInterface | ObjectFlags.Reference) ~= 0 then
        return checker.getTargetType(thisType)
    end
    return nil
end

function checker.getThisParameterFromNodeContext(node)
    local thisContainer = ast.GetThisContainer(node, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    if thisContainer ~= nil and ast.IsFunctionLike(thisContainer) then
        return ast.GetThisParameter(thisContainer)
    end
    return nil
end

function Checker:getContextualThisParameterType(fn)
    if ast.IsArrowFunction(fn) then
        return nil
    end
    if self:isContextSensitiveFunctionOrObjectLiteralMethod(fn) then
        local contextualSignature = self:getContextualSignature(fn)
        if contextualSignature ~= nil then
            local thisParameter = contextualSignature.thisParameter
            if thisParameter ~= nil then
                return self:getTypeOfSymbol(thisParameter)
            end
        end
    end
    local inJs = ast.IsInJSFile(fn)
    if self.noImplicitThis or inJs then
        local containingLiteral = checker.getContainingObjectLiteral(fn)
        if containingLiteral ~= nil then
            -- We have an object literal method. Check if the containing object literal has a contextual type
            -- that includes a ThisType<T>. If so, T is the contextual type for 'this'. We continue looking in
            -- any directly enclosing object literals.
            local contextualType = self:getApparentTypeOfContextualType(containingLiteral, ContextFlags.None)
            local thisType = self:getThisTypeOfObjectLiteralFromContextualType(containingLiteral, contextualType)
            if thisType ~= nil then
                return self:instantiateType(thisType, self:getMapperFromContext(self:getInferenceContext(containingLiteral)))
            end
            -- There was no contextual ThisType<T> for the containing object literal, so the contextual type
            -- for 'this' is the non-null form of the contextual type for the containing object literal or
            -- the type of the object literal itself.
            if contextualType ~= nil then
                thisType = self:GetNonNullableType(contextualType)
            else
                thisType = self:checkExpressionCached(containingLiteral)
            end
            return self:getWidenedType(thisType)
        end
        -- In an assignment of the form 'obj.xxx = function(...)' or 'obj[xxx] = function(...)', the
        -- contextual type for 'this' is 'obj'.
        local parent = ast.WalkUpParenthesizedExpressions(fn.parent)
        if ast.IsAssignmentExpression(parent, false) then
            local target = parent:AsBinaryExpression().left
            if ast.IsAccessExpression(target) then
                local expression = target:Expression()
                -- Don't contextually type `this` as `exports` in `exports.Point = function(x, y) { this.x = x; this.y = y; }`
                if inJs and ast.IsIdentifier(expression) then
                    local sourceFile = ast.GetSourceFileOfNode(parent)
                    if sourceFile.commonJSModuleIndicator ~= nil and self:getResolvedSymbol(expression).flags & SymbolFlags.ModuleExports ~= 0 then
                        return nil
                    end
                end
                return self:getWidenedType(self:checkExpressionCached(expression))
            end
        end
    end
    return nil
end

function Checker:checkThisExpression(node)
    -- Stop at the first arrow function so that we can
    -- tell whether 'this' needs to be captured.
    local container = ast.GetThisContainer(node, true --[[includeArrowFunctions]], true --[[includeClassComputedPropertyName]])
    local capturedByArrowFunction = false
    local thisInComputedPropertyName = false
    if ast.IsConstructorDeclaration(container) then
        self:checkThisBeforeSuper(node, container, diagnostics.X_super_must_be_called_before_accessing_this_in_the_constructor_of_a_derived_class)
    end
    while true do
        -- Now skip arrow functions to get the "real" owner of 'this'.
        if ast.IsArrowFunction(container) then
            container = ast.GetThisContainer(container, false --[[includeArrowFunctions]], not thisInComputedPropertyName)
            capturedByArrowFunction = true
        end
        if ast.IsComputedPropertyName(container) then
            container = ast.GetThisContainer(container, not capturedByArrowFunction, false --[[includeClassComputedPropertyName]])
            thisInComputedPropertyName = true
        else
            break
        end
    end
    self:checkThisInStaticClassFieldInitializerInDecoratedClass(node, container)
    if thisInComputedPropertyName then
        self:error(node, diagnostics.X_this_cannot_be_referenced_in_a_computed_property_name)
    else
        if container.kind == Kind.ModuleDeclaration then
            self:error(node, diagnostics.X_this_cannot_be_referenced_in_a_module_or_namespace_body)
            -- do not return here so in case if lexical this is captured - it will be reflected in flags on NodeLinks
        elseif container.kind == Kind.EnumDeclaration then
            self:error(node, diagnostics.X_this_cannot_be_referenced_in_current_location)
            -- do not return here so in case if lexical this is captured - it will be reflected in flags on NodeLinks
        end
    end
    local t = self:tryGetThisTypeAtEx(node, true --[[includeGlobalThis]], container)
    if self.noImplicitThis then
        local globalThisType = self:getTypeOfSymbol(self.globalThisSymbol)
        if t == globalThisType and capturedByArrowFunction then
            self:error(node, diagnostics.The_containing_arrow_function_captures_the_global_value_of_this)
        elseif t == nil then
            -- With noImplicitThis, functions may not reference 'this' if it has type 'any'
            local diag = self:error(node, diagnostics.X_this_implicitly_has_type_any_because_it_does_not_have_a_type_annotation)
            if not ast.IsSourceFile(container) then
                local outsideThis = self:tryGetThisTypeAt(container)
                if outsideThis ~= nil and outsideThis ~= globalThisType then
                    diag:AddRelatedInfo(checker.createDiagnosticForNode(container, diagnostics.An_outer_value_of_this_is_shadowed_by_this_container))
                end
            end
        end
    end
    if t == nil then
        return self.anyType
    end
    return t
end

function Checker:tryGetThisTypeAt(node)
    return self:tryGetThisTypeAtEx(node, true --[[includeGlobalThis]], nil --[[container]])
end

function Checker:TryGetThisTypeAtEx(node, includeGlobalThis, container)
    local reparsed = ast.GetReparsedNodeForNode(node)
    if reparsed.flags & NodeFlags.JSDoc ~= 0 and reparsed.flags & NodeFlags.Reparsed == 0 then
        return nil -- Binder doesn't process non-reparsed JSDoc nodes
    end
    return self:tryGetThisTypeAtEx(reparsed, includeGlobalThis, ast.GetReparsedNodeForNode(container))
end


function Checker:tryGetThisTypeAtEx(node, includeGlobalThis, container)
    if container == nil then
        container = self:getThisContainer(node, false --[[includeArrowFunctions]], false --[[includeClassComputedPropertyName]])
    end
    if ast.IsFunctionLike(container) and (not self:isInParameterInitializerBeforeContainingFunction(node) or ast.GetThisParameter(container) ~= nil) then
        local sig = self:getSignatureOfFullSignatureType(container)
        if sig == nil then
            sig = self:getSignatureFromDeclaration(container)
        end
        local thisType = self:getThisTypeOfSignature(sig)
        -- Note: a parameter initializer should refer to class-this unless function-this is explicitly annotated.
        -- If this is a function in a JS file, it might be a class method.
        if thisType == nil then
            thisType = self:getContextualThisParameterType(container)
        end
        if thisType ~= nil then
            return self:getFlowTypeOfReference(node, thisType)
        end
    end
    if container.parent ~= nil and ast.IsClassLike(container.parent) then
        local symbol = self:getSymbolOfDeclaration(container.parent)
        local t
        if ast.IsStatic(container) then
            t = self:getTypeOfSymbol(symbol)
        else
            t = self:getDeclaredTypeOfSymbol(symbol):AsInterfaceType().thisType
        end
        return self:getFlowTypeOfReference(node, t)
    end
    if ast.IsSourceFile(container) then
        -- look up in the source file's locals or exports
        if container:AsSourceFile().externalModuleIndicator ~= nil then
            -- TODO: Maybe issue a better error than 'object is possibly undefined'
            return self.undefinedType
        end
        if includeGlobalThis then
            return self:getTypeOfSymbol(self.globalThisSymbol)
        end
    end
    return nil
end

local thisContainerKinds = ast.kindSet(Kind.FunctionDeclaration, Kind.FunctionExpression, Kind.ModuleDeclaration, Kind.ClassStaticBlockDeclaration,
    Kind.PropertyDeclaration, Kind.PropertySignature, Kind.MethodDeclaration, Kind.MethodSignature, Kind.Constructor,
    Kind.GetAccessor, Kind.SetAccessor, Kind.CallSignature, Kind.ConstructSignature, Kind.IndexSignature,
    Kind.EnumDeclaration, Kind.SourceFile)

function Checker:getThisContainer(node, includeArrowFunctions, includeClassComputedPropertyName)
    while true do
        node = node.parent
        if node == nil then
            -- If we never pass in a SourceFile, this should be unreachable, since we'll stop when we reach that.
            error("No parent in getThisContainer", 0)
        end
        local kind = node.kind
        if kind == Kind.ComputedPropertyName then
            -- If the grandparent node is an object literal (as opposed to a class),
            -- then the computed property is not a 'this' container.
            -- A computed property name in a class needs to be a this container
            -- so that we can error on it.
            if includeClassComputedPropertyName and ast.IsClassLike(node.parent.parent) then
                return node
            end
            -- If this is a computed property, then the parent should not
            -- make it a this container. The parent might be a property
            -- in an object literal, like a method or accessor. But in order for
            -- such a parent to be a this container, the reference must be in
            -- the *body* of the container.
            node = node.parent.parent
        elseif kind == Kind.Decorator then
            -- Decorators are always applied outside of the body of a class or method.
            if node.parent.kind == Kind.Parameter and ast.IsClassElement(node.parent.parent) then
                -- If the decorator's parent is a Parameter, we resolve the this container from
                -- the grandparent class declaration.
                node = node.parent.parent
            elseif ast.IsClassElement(node.parent) then
                -- If the decorator's parent is a class element, we resolve the 'this' container
                -- from the parent class declaration.
                node = node.parent
            end
        elseif kind == Kind.ArrowFunction then
            if includeArrowFunctions then
                return node
            end
        elseif thisContainerKinds[kind] then
            return node
        end
    end
end

function Checker:isInParameterInitializerBeforeContainingFunction(node)
    local inBindingInitializer = false
    while node.parent ~= nil and not ast.IsFunctionLike(node.parent) do
        if ast.IsParameterDeclaration(node.parent) then
            if inBindingInitializer or node.parent:Initializer() == node then
                return true
            end
        end

        if ast.IsBindingElement(node.parent) and node.parent:Initializer() == node then
            inBindingInitializer = true
        end

        node = node.parent
    end

    return false
end

function Checker:checkThisInStaticClassFieldInitializerInDecoratedClass(thisExpression, container)
    if ast.IsPropertyDeclaration(container) and ast.HasStaticModifier(container) and self.legacyDecorators then
        local initializer = container:Initializer()
        if initializer ~= nil and initializer.loc:ContainsInclusive(thisExpression:Pos()) and ast.HasDecorators(container.parent) then
            self:error(thisExpression, diagnostics.Cannot_use_this_in_a_static_property_initializer_of_a_decorated_class)
        end
    end
end

function Checker:checkThisBeforeSuper(node, container, diagnosticMessage)
    local containingClassDecl = container.parent
    local baseTypeNode = ast.GetClassExtendsHeritageElement(containingClassDecl)
    -- If a containing class does not have extends clause or the class extends null
    -- skip checking whether super statement is called before "this" accessing.
    if baseTypeNode ~= nil and not self:classDeclarationExtendsNull(containingClassDecl) then
        if node:FlowNodeData() ~= nil and not self:isPostSuperFlowNode(node:FlowNodeData().flowNode, false --[[noCacheCheck]]) then
            self:error(node, diagnosticMessage)
        end
    end
end

--
-- Check if the given class-declaration extends null then return true.
-- Otherwise, return false
-- @param classDecl a class declaration to check if it extends null
--
function Checker:classDeclarationExtendsNull(classDecl)
    local classSymbol = self:getSymbolOfDeclaration(classDecl)
    local classInstanceType = self:getDeclaredTypeOfSymbol(classSymbol)
    local baseConstructorType = self:getBaseConstructorTypeOfClass(classInstanceType)
    return baseConstructorType == self.nullWideningType
end

function Checker:checkAssertion(node, checkMode)
    if node.kind == Kind.TypeAssertionExpression then
        local file = ast.GetSourceFileOfNode(node)
        if file ~= nil and tspath.FileExtensionIsOneOf(file:FileName(), { tspath.ExtensionMts, tspath.ExtensionCts }) then
            self:grammarErrorOnNode(node, diagnostics.This_syntax_is_reserved_in_files_with_the_mts_or_cts_extension_Use_an_as_expression_instead)
        end
        if self:shouldCheckErasableSyntax(node) then
            self:addDiagnostic(ast.NewDiagnostic(ast.GetSourceFileOfNode(node), core.NewTextRange(scanner.SkipTrivia(ast.GetSourceFileOfNode(node):Text(), node:Pos()), node:Expression():Pos()), diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled))
        end
    end
    local typeNode = node:Type()
    local exprType = self:checkExpressionEx(node:Expression(), checkMode)
    -- Always check the type node so its identifiers are resolved. resolveName knows not
    -- to resolve (or report an error for) the `const` in a `const` assertion, so this is
    -- safe even for `x as const` and keeps diagnostics stable regardless of traversal order.
    self:checkSourceElement(typeNode)
    if checker.isConstTypeReference(typeNode) then
        if not self:isValidConstAssertionArgument(node:Expression()) then
            self:error(node:Expression(), diagnostics.A_const_assertion_can_only_be_applied_to_references_to_enum_members_or_string_number_boolean_array_or_object_literals)
        end
        return self:getRegularTypeOfLiteralType(exprType)
    end
    local links = self.assertionLinks:Get(node)
    links.exprType = exprType
    self:checkNodeDeferred(node)
    return self:getTypeFromTypeNode(typeNode)
end

function Checker:checkAssertionDeferred(node)
    local typeNode = node:Type()
    local exprType = self:getRegularTypeOfObjectLiteral(self:getBaseTypeOfLiteralType(self.assertionLinks:Get(node).exprType))
    local targetType = self:getTypeFromTypeNode(typeNode)
    if not self:isErrorType(targetType) then
        local widenedType = self:getWidenedType(exprType)
        if not self:isTypeComparableTo(targetType, widenedType) then
            local errNode = node
            if typeNode.flags & NodeFlags.Reparsed ~= 0 then
                errNode = typeNode
            end
            self:checkTypeComparableTo(exprType, targetType, errNode, diagnostics.Conversion_of_type_0_to_type_1_may_be_a_mistake_because_neither_type_sufficiently_overlaps_with_the_other_If_this_was_intentional_convert_the_expression_to_unknown_first)
        end
    end
end

function Checker:checkBinaryExpression(node, checkMode)
    local binary = node:AsBinaryExpression()
    return self:checkBinaryLikeExpression(binary.left, binary.operatorToken, binary.right, checkMode, node)
end


local arithmeticOperatorKinds = ast.kindSet(Kind.AsteriskToken, Kind.AsteriskAsteriskToken, Kind.AsteriskEqualsToken, Kind.AsteriskAsteriskEqualsToken,
    Kind.SlashToken, Kind.SlashEqualsToken, Kind.PercentToken, Kind.PercentEqualsToken, Kind.MinusToken,
    Kind.MinusEqualsToken, Kind.LessThanLessThanToken, Kind.LessThanLessThanEqualsToken, Kind.GreaterThanGreaterThanToken,
    Kind.GreaterThanGreaterThanEqualsToken, Kind.GreaterThanGreaterThanGreaterThanToken, Kind.GreaterThanGreaterThanGreaterThanEqualsToken,
    Kind.BarToken, Kind.BarEqualsToken, Kind.CaretToken, Kind.CaretEqualsToken, Kind.AmpersandToken, Kind.AmpersandEqualsToken)

local shiftOperatorKinds = ast.kindSet(Kind.LessThanLessThanToken, Kind.LessThanLessThanEqualsToken, Kind.GreaterThanGreaterThanToken,
    Kind.GreaterThanGreaterThanEqualsToken, Kind.GreaterThanGreaterThanGreaterThanToken,
    Kind.GreaterThanGreaterThanGreaterThanEqualsToken)

function Checker:checkBinaryLikeExpression(left, operatorToken, right, checkMode, errorNode)
    local operator = operatorToken.kind
    if operator == Kind.EqualsToken and (left.kind == Kind.ObjectLiteralExpression or left.kind == Kind.ArrayLiteralExpression) then
        return self:checkDestructuringAssignment(left, self:checkExpressionEx(right, checkMode), checkMode, right.kind == Kind.ThisKeyword)
    end
    local leftType = self:checkExpressionEx(left, checkMode)
    local rightType = self:checkExpressionEx(right, checkMode)
    if ast.IsLogicalOrCoalescingBinaryOperator(operator) then
        local parent = left.parent.parent
        while ast.IsParenthesizedExpression(parent) or ast.IsLogicalOrCoalescingBinaryExpression(parent) do
            parent = parent.parent
        end
        if operator == Kind.AmpersandAmpersandToken or ast.IsIfStatement(parent) then
            local body = nil
            if ast.IsIfStatement(parent) then
                body = parent:AsIfStatement().thenStatement
            end
            self:checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType(left, leftType, body)
        end
        if ast.IsLogicalBinaryOperator(operator) then
            self:checkTruthinessOfType(leftType, left)
        end
    end
    if arithmeticOperatorKinds[operator] then
        if leftType == self.silentNeverType or rightType == self.silentNeverType then
            return self.silentNeverType
        end
        leftType = self:checkNonNullType(leftType, left)
        rightType = self:checkNonNullType(rightType, right)
        -- if a user tries to apply a bitwise operator to 2 boolean operands
        -- try and return them a helpful suggestion
        if leftType.flags & TypeFlags.BooleanLike ~= 0 and rightType.flags & TypeFlags.BooleanLike ~= 0 then
            local suggestedOperator = self:getSuggestedBooleanOperator(operator)
            if suggestedOperator ~= Kind.Unknown then
                self:error(operatorToken, diagnostics.The_0_operator_is_not_allowed_for_boolean_types_Consider_using_1_instead, scanner.TokenToString(operatorToken.kind), scanner.TokenToString(suggestedOperator))
                return self.numberType
            end
        end
        -- otherwise just check each operand separately and report errors as normal
        local leftOk = self:checkArithmeticOperandType(left, leftType, diagnostics.The_left_hand_side_of_an_arithmetic_operation_must_be_of_type_any_number_bigint_or_an_enum_type, true --[[isAwaitValid]])
        local rightOk = self:checkArithmeticOperandType(right, rightType, diagnostics.The_right_hand_side_of_an_arithmetic_operation_must_be_of_type_any_number_bigint_or_an_enum_type, true --[[isAwaitValid]])
        local resultType
        -- If both are any or unknown, allow operation; assume it will resolve to number
        if self:isTypeAssignableToKind(leftType, TypeFlags.AnyOrUnknown) and self:isTypeAssignableToKind(rightType, TypeFlags.AnyOrUnknown) or not self:maybeTypeOfKind(leftType, TypeFlags.BigIntLike) and not self:maybeTypeOfKind(rightType, TypeFlags.BigIntLike) then
            resultType = self.numberType
        elseif self:bothAreBigIntLike(leftType, rightType) then
            if operator == Kind.GreaterThanGreaterThanGreaterThanToken or operator == Kind.GreaterThanGreaterThanGreaterThanEqualsToken then
                self:reportOperatorError(leftType, operator, rightType, errorNode, nil)
            elseif operator == Kind.AsteriskAsteriskToken or operator == Kind.AsteriskAsteriskEqualsToken then
                if self.languageVersion < core.ScriptTarget.ES2016 then
                    self:error(errorNode, diagnostics.Exponentiation_cannot_be_performed_on_bigint_values_unless_the_target_option_is_set_to_es2016_or_later)
                end
            end
            resultType = self.bigintType
        else
            self:reportOperatorError(leftType, operator, rightType, errorNode, function(l, r) return self:bothAreBigIntLike(l, r) end)
            resultType = self.errorType
        end
        if leftOk and rightOk then
            self:checkAssignmentOperator(left, operator, right, leftType, resultType)
            if shiftOperatorKinds[operator] then
                local rhsEval = self.evaluate(right, right)
                local numValue = rhsEval.value
                if type(numValue) == "number" and jsnum.Number_Abs(numValue) >= 32 then
                    -- Elevate from suggestion to error within an enum member
                    self:errorOrSuggestion(ast.IsEnumMember(ast.WalkUpParenthesizedExpressions(right.parent.parent)), errorNode, diagnostics.This_operation_can_be_simplified_This_shift_is_identical_to_0_1_2, scanner.GetTextOfNode(left), scanner.TokenToString(operator), jsnum.Number_String(jsnum.Number_Remainder(numValue, 32)))
                end
            end
        end
        return resultType
    elseif operator == Kind.PlusToken or operator == Kind.PlusEqualsToken then
        if leftType == self.silentNeverType or rightType == self.silentNeverType then
            return self.silentNeverType
        end
        if not self:isTypeAssignableToKind(leftType, TypeFlags.StringLike) and not self:isTypeAssignableToKind(rightType, TypeFlags.StringLike) then
            leftType = self:checkNonNullType(leftType, left)
            rightType = self:checkNonNullType(rightType, right)
        end
        local resultType = nil
        if self:isTypeAssignableToKindEx(leftType, TypeFlags.NumberLike, true --[[strict]]) and self:isTypeAssignableToKindEx(rightType, TypeFlags.NumberLike, true --[[strict]]) then
            -- Operands of an enum type are treated as having the primitive type Number.
            -- If both operands are of the Number primitive type, the result is of the Number primitive type.
            resultType = self.numberType
        elseif self:isTypeAssignableToKindEx(leftType, TypeFlags.BigIntLike, true --[[strict]]) and self:isTypeAssignableToKindEx(rightType, TypeFlags.BigIntLike, true --[[strict]]) then
            -- If both operands are of the BigInt primitive type, the result is of the BigInt primitive type.
            resultType = self.bigintType
        elseif self:isTypeAssignableToKindEx(leftType, TypeFlags.StringLike, true --[[strict]]) or self:isTypeAssignableToKindEx(rightType, TypeFlags.StringLike, true --[[strict]]) then
            -- If one or both operands are of the String primitive type, the result is of the String primitive type.
            resultType = self.stringType
        elseif checker.IsTypeAny(leftType) or checker.IsTypeAny(rightType) then
            -- Otherwise, the result is of type Any.
            -- NOTE: unknown type here denotes error type. Old compiler treated this case as any type so do we.
            if self:isErrorType(leftType) or self:isErrorType(rightType) then
                resultType = self.errorType
            else
                resultType = self.anyType
            end
        end
        -- Symbols are not allowed at all in arithmetic expressions
        if resultType ~= nil and not self:checkForDisallowedESSymbolOperand(left, right, leftType, rightType, operator) then
            return resultType
        end
        if resultType == nil then
            -- Types that have a reasonably good chance of being a valid operand type.
            -- If both types have an awaited type of one of these, we'll assume the user
            -- might be missing an await without doing an exhaustive check that inserting
            -- await(s) will actually be a completely valid binary expression.
            local closeEnoughKind = TypeFlags.NumberLike | TypeFlags.BigIntLike | TypeFlags.StringLike | TypeFlags.AnyOrUnknown
            self:reportOperatorError(leftType, operator, rightType, errorNode, function(l, r)
                return self:isTypeAssignableToKind(l, closeEnoughKind) and self:isTypeAssignableToKind(r, closeEnoughKind)
            end)
            return self.anyType
        end
        if operator == Kind.PlusEqualsToken then
            self:checkAssignmentOperator(left, operator, right, leftType, resultType)
        end
        return resultType
    elseif operator == Kind.LessThanToken or operator == Kind.GreaterThanToken or operator == Kind.LessThanEqualsToken or operator == Kind.GreaterThanEqualsToken then
        if self:checkForDisallowedESSymbolOperand(left, right, leftType, rightType, operator) then
            leftType = self:getBaseTypeOfLiteralTypeForComparison(self:checkNonNullType(leftType, left))
            rightType = self:getBaseTypeOfLiteralTypeForComparison(self:checkNonNullType(rightType, right))
            self:reportOperatorErrorUnless(leftType, operator, rightType, errorNode, function(l, r)
                if checker.IsTypeAny(l) or checker.IsTypeAny(r) then
                    return true
                end
                local leftAssignableToNumber = self:isTypeAssignableTo(l, self.numberOrBigIntType)
                local rightAssignableToNumber = self:isTypeAssignableTo(r, self.numberOrBigIntType)
                return leftAssignableToNumber and rightAssignableToNumber or not leftAssignableToNumber and not rightAssignableToNumber and self:areTypesComparable(l, r)
            end)
        end
        return self.booleanType
    elseif operator == Kind.EqualsEqualsToken or operator == Kind.ExclamationEqualsToken or operator == Kind.EqualsEqualsEqualsToken or operator == Kind.ExclamationEqualsEqualsToken then
        -- We suppress errors in CheckMode.TypeOnly (meaning the invocation came from getTypeOfExpression). During
        -- control flow analysis it is possible for operands to temporarily have narrower types, and those narrower
        -- types may cause the operands to not be comparable. We don't want such errors reported (see #46475).
        if checkMode & CheckMode.TypeOnly == 0 then
            if (checker.isLiteralExpressionOfObject(left) or checker.isLiteralExpressionOfObject(right)) and
                -- only report for === and !== in JS, not == or !=
                (not ast.IsInJSFile(left) or (operator == Kind.EqualsEqualsEqualsToken or operator == Kind.ExclamationEqualsEqualsToken)) then
                local eqType = operator == Kind.EqualsEqualsToken or operator == Kind.EqualsEqualsEqualsToken
                self:error(errorNode, diagnostics.This_condition_will_always_return_0_since_JavaScript_compares_objects_by_reference_not_value, core.IfElse(eqType, "false", "true"))
            end
            self:checkNaNEquality(errorNode, operator, left, right)
            self:reportOperatorErrorUnless(leftType, operator, rightType, errorNode, function(l, r)
                return self:isTypeEqualityComparableTo(l, r) or self:isTypeEqualityComparableTo(r, l)
            end)
        end
        return self.booleanType
    elseif operator == Kind.InstanceOfKeyword then
        return self:checkInstanceOfExpression(left, right, leftType, rightType, checkMode)
    elseif operator == Kind.InKeyword then
        return self:checkInExpression(left, right, leftType, rightType)
    elseif operator == Kind.AmpersandAmpersandToken or operator == Kind.AmpersandAmpersandEqualsToken then
        local resultType = leftType
        if self:hasTypeFacts(leftType, TypeFacts.Truthy) then
            local t = leftType
            if not self.strictNullChecks then
                t = self:getBaseTypeOfLiteralType(rightType)
            end
            resultType = self:getUnionType({ self:extractDefinitelyFalsyTypes(t), rightType })
        end
        if operator == Kind.AmpersandAmpersandEqualsToken then
            self:checkAssignmentOperator(left, operator, right, leftType, rightType)
        end
        return resultType
    elseif operator == Kind.BarBarToken or operator == Kind.BarBarEqualsToken then
        local resultType = leftType
        if self:hasTypeFacts(leftType, TypeFacts.Falsy) then
            resultType = self:getUnionTypeEx({ self:GetNonNullableType(self:removeDefinitelyFalsyTypes(leftType)), rightType }, UnionReduction.Subtype, nil, nil)
        end
        if operator == Kind.BarBarEqualsToken then
            self:checkAssignmentOperator(left, operator, right, leftType, rightType)
        end
        return resultType
    elseif operator == Kind.QuestionQuestionToken or operator == Kind.QuestionQuestionEqualsToken then
        if operator == Kind.QuestionQuestionToken then
            self:checkNullishCoalesceOperands(left, right)
        end
        local resultType = leftType
        if self:hasTypeFacts(leftType, TypeFacts.EQUndefinedOrNull) then
            resultType = self:getUnionTypeEx({ self:GetNonNullableType(leftType), rightType }, UnionReduction.Subtype, nil, nil)
        end
        if operator == Kind.QuestionQuestionEqualsToken then
            self:checkAssignmentOperator(left, operator, right, leftType, rightType)
        end
        return resultType
    elseif operator == Kind.EqualsToken then
        self:checkAssignmentOperator(left, operator, right, leftType, rightType)
        return rightType
    elseif operator == Kind.CommaToken then
        if not core.Tristate_IsTrue(self.compilerOptions.allowUnreachableCode) and self:isSideEffectFree(left) and not self:isIndirectCall(left.parent) then
            local sf = ast.GetSourceFileOfNode(left)
            local start = scanner.SkipTrivia(sf:Text(), left:Pos())
            local isInDiag2657 = core.Some(sf:Diagnostics(), function(d)
                if d:Code() ~= diagnostics.JSX_expressions_must_have_one_parent_element:Code() then
                    return false
                end
                return d:Loc():Contains(start)
            end)
            if not isInDiag2657 then
                self:error(left, diagnostics.Left_side_of_comma_operator_is_unused_and_has_no_side_effects)
            end
        end
        return rightType
    end
    error("Unhandled case in checkBinaryLikeExpression", 0)
end


function Checker:checkDestructuringAssignment(node, sourceType, checkMode, rightIsThis)
    local target
    if ast.IsShorthandPropertyAssignment(node) then
        local initializer = node:AsShorthandPropertyAssignment().objectAssignmentInitializer
        if initializer ~= nil then
            -- In strict null checking mode, if a default value of a non-undefined type is specified, remove
            -- undefined from the final type.
            if self.strictNullChecks and not self:hasTypeFacts(self:checkExpression(initializer), TypeFacts.IsUndefined) then
                sourceType = self:getTypeWithFacts(sourceType, TypeFacts.NEUndefined)
            end
            self:checkBinaryLikeExpression(node:Name(), node:AsShorthandPropertyAssignment().equalsToken, initializer, checkMode, nil)
        end
        target = node:Name()
    else
        target = node
    end
    if ast.IsBinaryExpression(target) and target:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken then
        self:checkBinaryExpression(target, checkMode)
        target = target:AsBinaryExpression().left
        -- A default value is specified, so remove undefined from the final type.
        if self.strictNullChecks then
            sourceType = self:getTypeWithFacts(sourceType, TypeFacts.NEUndefined)
        end
    end
    if ast.IsObjectLiteralExpression(target) then
        return self:checkObjectLiteralAssignment(target, sourceType, rightIsThis)
    end
    if ast.IsArrayLiteralExpression(target) then
        return self:checkArrayLiteralAssignment(target, sourceType, checkMode)
    end
    return self:checkReferenceAssignment(target, sourceType, checkMode)
end

function Checker:checkObjectLiteralAssignment(node, sourceType, rightIsThis)
    local properties = node:PropertyList()
    if self.strictNullChecks and core.Len(properties.nodes) == 0 then
        return self:checkNonNullType(sourceType, node)
    end
    for i = 0, core.Len(properties.nodes) - 1 do
        self:checkObjectLiteralDestructuringPropertyAssignment(node, sourceType, i, properties, rightIsThis)
    end
    return sourceType
end

-- Note: If property cannot be a SpreadAssignment, then allProperties does not need to be provided
function Checker:checkObjectLiteralDestructuringPropertyAssignment(node, objectLiteralType, propertyIndex, allProperties, rightIsThis)
    local properties = node:Properties()
    local property = properties[propertyIndex + 1]
    if ast.IsPropertyAssignment(property) or ast.IsShorthandPropertyAssignment(property) then
        local name = property:Name()
        local exprType = self:getLiteralTypeFromPropertyName(name)
        if checker.isTypeUsableAsPropertyName(exprType) then
            local text = checker.getPropertyNameFromType(exprType)
            local prop = self:getPropertyOfType(objectLiteralType, text)
            if prop ~= nil then
                self:markPropertyAsReferenced(prop, property, rightIsThis)
                self:checkPropertyAccessibility(property, false --[[isSuper]], true --[[writing]], objectLiteralType, prop)
            end
        end
        local elementType = self:getIndexedAccessTypeEx(objectLiteralType, exprType, AccessFlags.ExpressionPosition | core.IfElse(self:hasDefaultValue(property), AccessFlags.AllowMissing, 0), name, nil)
        local t = self:getFlowTypeOfDestructuring(property, elementType)
        local expr = property
        if ast.IsPropertyAssignment(property) then
            expr = property:Initializer()
        end
        return self:checkDestructuringAssignment(expr, t, CheckMode.Normal, false)
    end
    if ast.IsSpreadAssignment(property) then
        if propertyIndex < #properties - 1 then
            self:error(property, diagnostics.A_rest_element_must_be_last_in_a_destructuring_pattern)
            return nil
        end
        if self.languageVersion < checker.LanguageFeatureMinimumTarget.ObjectSpreadRest then
            self:checkExternalEmitHelpers(property, ExternalEmitHelpers.Rest)
        end
        local nonRestNames = nil
        if allProperties ~= nil then
            for _, otherProperty in ipairs(allProperties.nodes or {}) do
                if not ast.IsSpreadAssignment(otherProperty) then
                    nonRestNames = core.Append(nonRestNames, otherProperty:Name())
                end
            end
        end
        local t = self:getRestType(objectLiteralType, nonRestNames, objectLiteralType.symbol)
        self:checkGrammarForDisallowedTrailingComma(allProperties, diagnostics.A_rest_parameter_or_binding_pattern_may_not_have_a_trailing_comma)
        return self:checkDestructuringAssignment(property:Expression(), t, CheckMode.Normal, false)
    end
    self:error(property, diagnostics.Property_assignment_expected)
    return nil
end

function Checker:checkArrayLiteralAssignment(node, sourceType, checkMode)
    local elements = node:Elements()
    -- This elementType will be used if the specific property corresponding to this index is not
    -- present (aka the tuple element property). This call also checks that the parentType is in
    -- fact an iterable or array (depending on target language).
    local possiblyOutOfBoundsType = core.OrElse(self:checkIteratedTypeOrElementType(IterationUse.Destructuring | IterationUse.PossiblyOutOfBounds, sourceType, self.undefinedType, node), self.errorType)
    local inBoundsType = possiblyOutOfBoundsType
    if self.compilerOptions.noUncheckedIndexedAccess == Tristate.TSTrue then
        inBoundsType = nil
    end
    for i = 0, core.Len(elements) - 1 do
        local t = possiblyOutOfBoundsType
        if elements[i + 1].kind == Kind.SpreadElement then
            if inBoundsType == nil then
                inBoundsType = core.OrElse(self:checkIteratedTypeOrElementType(IterationUse.Destructuring, sourceType, self.undefinedType, node), self.errorType)
            end
            t = inBoundsType
        end
        self:checkArrayLiteralDestructuringElementAssignment(node, sourceType, i, t, checkMode)
    end
    return sourceType
end

function Checker:checkArrayLiteralDestructuringElementAssignment(node, sourceType, elementIndex, elementType, checkMode)
    local elements = node:ElementList()
    local element = elements.nodes[elementIndex + 1]
    if not ast.IsOmittedExpression(element) then
        if not ast.IsSpreadElement(element) then
            local indexType = self:getNumberLiteralType(elementIndex + 0.0)
            if self:isArrayLikeType(sourceType) then
                -- We create a synthetic expression so that getIndexedAccessType doesn't get confused
                -- when the element is a SyntaxKind.ElementAccessExpression.
                local accessFlags = AccessFlags.ExpressionPosition | core.IfElse(self:hasDefaultValue(element), AccessFlags.AllowMissing, 0)
                local elementType2 = core.OrElse(self:getIndexedAccessTypeOrUndefined(sourceType, indexType, accessFlags, self:createSyntheticExpression(element, indexType, false, nil), nil), self.errorType)
                local assignedType = elementType2
                if self:hasDefaultValue(element) then
                    assignedType = self:getTypeWithFacts(elementType2, TypeFacts.NEUndefined)
                end
                local t = self:getFlowTypeOfDestructuring(element, assignedType)
                return self:checkDestructuringAssignment(element, t, checkMode, false)
            end
            return self:checkDestructuringAssignment(element, elementType, checkMode, false)
        end
        if elementIndex < #elements.nodes - 1 then
            self:error(element, diagnostics.A_rest_element_must_be_last_in_a_destructuring_pattern)
        else
            local restExpression = element:Expression()
            if ast.IsBinaryExpression(restExpression) and restExpression:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken then
                self:error(restExpression:AsBinaryExpression().operatorToken, diagnostics.A_rest_element_cannot_have_an_initializer)
            else
                self:checkGrammarForDisallowedTrailingComma(elements, diagnostics.A_rest_parameter_or_binding_pattern_may_not_have_a_trailing_comma)
                local t
                if checker.everyType(sourceType, checker.isTupleType) then
                    t = self:mapType(sourceType, function(u) return self:sliceTupleType(u, elementIndex, 0) end)
                else
                    t = self:createArrayType(elementType)
                end
                return self:checkDestructuringAssignment(restExpression, t, checkMode, false)
            end
        end
    end
    return nil
end

function Checker:checkReferenceAssignment(target, sourceType, checkMode)
    local targetType = self:checkExpressionEx(target, checkMode)
    local message = core.IfElse(ast.IsSpreadAssignment(target.parent),
        diagnostics.The_target_of_an_object_rest_assignment_must_be_a_variable_or_a_property_access,
        diagnostics.The_left_hand_side_of_an_assignment_expression_must_be_a_variable_or_a_property_access)
    local optionalMessage = core.IfElse(ast.IsSpreadAssignment(target.parent),
        diagnostics.The_target_of_an_object_rest_assignment_may_not_be_an_optional_property_access,
        diagnostics.The_left_hand_side_of_an_assignment_expression_may_not_be_an_optional_property_access)
    if self:checkReferenceExpression(target, message, optionalMessage) then
        self:checkTypeAssignableToAndOptionallyElaborate(sourceType, targetType, target, target, nil, nil)
    end
    return sourceType
end

function Checker:reportOperatorError(leftType, operator, rightType, errorNode, isRelated)
    local wouldWorkWithAwait = false
    if isRelated ~= nil then
        local awaitedLeftType = self:getAwaitedTypeNoAlias(leftType)
        local awaitedRightType = self:getAwaitedTypeNoAlias(rightType)
        wouldWorkWithAwait = not (awaitedLeftType == leftType and awaitedRightType == rightType) and awaitedLeftType ~= nil and awaitedRightType ~= nil and isRelated(awaitedLeftType, awaitedRightType)
    end
    local effectiveLeft = leftType
    local effectiveRight = rightType
    if not wouldWorkWithAwait and isRelated ~= nil then
        effectiveLeft, effectiveRight = self:getBaseTypesIfUnrelated(leftType, rightType, isRelated)
    end
    local leftStr, rightStr = self:getTypeNamesForErrorDisplay(effectiveLeft, effectiveRight)
    if operator == Kind.EqualsEqualsEqualsToken or operator == Kind.EqualsEqualsToken or operator == Kind.ExclamationEqualsEqualsToken or operator == Kind.ExclamationEqualsToken then
        self:errorAndMaybeSuggestAwait(errorNode, wouldWorkWithAwait, diagnostics.This_comparison_appears_to_be_unintentional_because_the_types_0_and_1_have_no_overlap, leftStr, rightStr)
    else
        self:errorAndMaybeSuggestAwait(errorNode, wouldWorkWithAwait, diagnostics.Operator_0_cannot_be_applied_to_types_1_and_2, scanner.TokenToString(operator), leftStr, rightStr)
    end
end

function Checker:reportOperatorErrorUnless(leftType, operator, rightType, errorNode, typesAreCompatible)
    if not typesAreCompatible(leftType, rightType) then
        self:reportOperatorError(leftType, operator, rightType, errorNode, typesAreCompatible)
    end
end

function Checker:getBaseTypesIfUnrelated(leftType, rightType, isRelated)
    local effectiveLeft = leftType
    local effectiveRight = rightType
    local leftBase = self:getBaseTypeOfLiteralType(leftType)
    local rightBase = self:getBaseTypeOfLiteralType(rightType)
    if not isRelated(leftBase, rightBase) then
        effectiveLeft = leftBase
        effectiveRight = rightBase
    end
    return effectiveLeft, effectiveRight
end

function Checker:checkAssignmentOperator(left, operator, right, leftType, rightType)
    if ast.IsAssignmentOperator(operator) then
        -- We ignore assignments of undefined to CommonJS exports when there are multiple assignment declarations
        if ast.IsDeclarationNode(left.parent) and ast.GetAssignmentDeclarationKind(left.parent) == ast.JSDeclarationKind.ExportsProperty then
            local symbol = self.symbolNodeLinks:Get(left).resolvedSymbol
            if symbol ~= nil and core.Len(symbol.declarations) > 1 and rightType.flags & TypeFlags.Undefined ~= 0 then
                return
            end
        end
        -- getters can be a subtype of setters, so to check for assignability we use the setter's type instead
        if ast.IsCompoundAssignment(operator) and ast.IsPropertyAccessExpression(left) then
            leftType = self:checkPropertyAccessExpression(left, CheckMode.Normal, true --[[writeOnly]])
        end
        if self:checkReferenceExpression(left, diagnostics.The_left_hand_side_of_an_assignment_expression_must_be_a_variable_or_a_property_access, diagnostics.The_left_hand_side_of_an_assignment_expression_may_not_be_an_optional_property_access) then
            local headMessage = nil
            if self.exactOptionalPropertyTypes and ast.IsPropertyAccessExpression(left) and self:maybeTypeOfKind(rightType, TypeFlags.Undefined) then
                local target = self:getTypeOfPropertyOfType(self:getTypeOfExpression(left:Expression()), left:Name():Text())
                if self:isExactOptionalPropertyMismatch(rightType, target) then
                    headMessage = diagnostics.Type_0_is_not_assignable_to_type_1_with_exactOptionalPropertyTypes_Colon_true_Consider_adding_undefined_to_the_type_of_the_target
                end
            end
            -- to avoid cascading errors check assignability only if 'isReference' check succeeded and no errors were reported
            self:checkTypeAssignableToAndOptionallyElaborate(rightType, leftType, left, right, headMessage, nil)
        end
    end
end

function Checker:bothAreBigIntLike(left, right)
    return self:isTypeAssignableToKind(left, TypeFlags.BigIntLike) and self:isTypeAssignableToKind(right, TypeFlags.BigIntLike)
end

function Checker:getSuggestedBooleanOperator(operator)
    if operator == Kind.BarToken or operator == Kind.BarEqualsToken then
        return Kind.BarBarToken
    elseif operator == Kind.CaretToken or operator == Kind.CaretEqualsToken then
        return Kind.ExclamationEqualsEqualsToken
    elseif operator == Kind.AmpersandToken or operator == Kind.AmpersandEqualsToken then
        return Kind.AmpersandAmpersandToken
    end
    return Kind.Unknown
end

function Checker:checkArithmeticOperandType(operand, t, diagnostic, isAwaitValid)
    if not self:isTypeAssignableTo(t, self.numberOrBigIntType) then
        local awaitedType = nil
        if isAwaitValid then
            awaitedType = self:getAwaitedTypeOfPromise(t)
        end
        self:errorAndMaybeSuggestAwait(operand, awaitedType ~= nil and self:isTypeAssignableTo(awaitedType, self.numberOrBigIntType), diagnostic)
        return false
    end
    return true
end

-- Return true if there was no error, false if there was an error.
function Checker:checkForDisallowedESSymbolOperand(left, right, leftType, rightType, operator)
    local offendingSymbolOperand = nil
    if self:maybeTypeOfKindConsideringBaseConstraint(leftType, TypeFlags.ESSymbolLike) then
        offendingSymbolOperand = left
    elseif self:maybeTypeOfKindConsideringBaseConstraint(rightType, TypeFlags.ESSymbolLike) then
        offendingSymbolOperand = right
    end
    if offendingSymbolOperand ~= nil then
        self:error(offendingSymbolOperand, diagnostics.The_0_operator_cannot_be_applied_to_type_symbol, scanner.TokenToString(operator))
        return false
    end
    return true
end

function Checker:checkNaNEquality(errorNode, operator, left, right)
    local isLeftNaN = self:isGlobalNaN(ast.SkipParentheses(left))
    local isRightNaN = self:isGlobalNaN(ast.SkipParentheses(right))
    if isLeftNaN or isRightNaN then
        local err = self:error(errorNode, diagnostics.This_condition_will_always_return_0, scanner.TokenToString(core.IfElse(operator == Kind.EqualsEqualsEqualsToken or operator == Kind.EqualsEqualsToken, Kind.FalseKeyword, Kind.TrueKeyword)))
        if isLeftNaN and isRightNaN then
            return
        end
        local operatorString = ""
        if operator == Kind.ExclamationEqualsEqualsToken or operator == Kind.ExclamationEqualsToken then
            operatorString = scanner.TokenToString(Kind.ExclamationToken)
        end
        local location = left
        if isLeftNaN then
            location = right
        end
        local expression = ast.SkipParentheses(location)
        local entityName = "..."
        if ast.IsEntityNameExpression(expression) then
            entityName = checker.entityNameToString(expression)
        end
        local suggestion = operatorString .. "Number.isNaN(" .. entityName .. ")"
        err:AddRelatedInfo(checker.createDiagnosticForNode(location, diagnostics.Did_you_mean_0, suggestion))
    end
end

function Checker:isGlobalNaN(expr)
    if ast.IsIdentifier(expr) and expr:Text() == "NaN" then
        local globalNaNSymbol = self.getGlobalNaNSymbolOrNil()
        return globalNaNSymbol ~= nil and globalNaNSymbol == self:getResolvedSymbol(expr)
    end
    return false
end

function Checker:isTypeEqualityComparableTo(source, target)
    return (target.flags & TypeFlags.Nullable) ~= 0 or self:isTypeComparableTo(source, target)
end

function Checker:checkTruthinessOfType(t, node)
    if t.flags & TypeFlags.Void ~= 0 then
        self:error(node, diagnostics.An_expression_of_type_void_cannot_be_tested_for_truthiness)
        return t
    end
    local semantics = self:getSyntacticTruthySemantics(node)
    if semantics ~= PredicateSemantics.Sometimes then
        self:error(node, core.IfElse(semantics == PredicateSemantics.Always, diagnostics.This_kind_of_expression_is_always_truthy, diagnostics.This_kind_of_expression_is_always_falsy))
    end
    return t
end


local alwaysTruthyKinds = ast.kindSet(Kind.ArrayLiteralExpression, Kind.ArrowFunction, Kind.BigIntLiteral, Kind.ClassExpression, Kind.FunctionExpression,
    Kind.JsxElement, Kind.JsxSelfClosingElement, Kind.ObjectLiteralExpression, Kind.RegularExpressionLiteral)

function Checker:getSyntacticTruthySemantics(node)
    node = ast.SkipOuterExpressions(node, OuterExpressionKinds.OEKAll)
    local kind = node.kind
    if kind == Kind.NumericLiteral then
        -- Allow `while(0)` or `while(1)`
        if node:Text() == "0" or node:Text() == "1" then
            return PredicateSemantics.Sometimes
        end
        return PredicateSemantics.Always
    elseif alwaysTruthyKinds[kind] then
        return PredicateSemantics.Always
    elseif kind == Kind.VoidExpression or kind == Kind.NullKeyword then
        return PredicateSemantics.Never
    elseif kind == Kind.NoSubstitutionTemplateLiteral or kind == Kind.StringLiteral then
        if node:Text() ~= "" then
            return PredicateSemantics.Always
        end
        return PredicateSemantics.Never
    elseif kind == Kind.ConditionalExpression then
        return self:getSyntacticTruthySemantics(node:AsConditionalExpression().whenTrue) | self:getSyntacticTruthySemantics(node:AsConditionalExpression().whenFalse)
    elseif kind == Kind.Identifier then
        if self:getResolvedSymbol(node) == self.undefinedSymbol then
            return PredicateSemantics.Never
        end
    end
    return PredicateSemantics.Sometimes
end

function Checker:checkNullishCoalesceOperands(left, right)
    if ast.IsBinaryExpression(left.parent.parent) then
        local grandparentLeft = left.parent.parent:AsBinaryExpression().left
        local grandparentOperatorToken = left.parent.parent:AsBinaryExpression().operatorToken
        if ast.IsBinaryExpression(grandparentLeft) and grandparentOperatorToken.kind == Kind.BarBarToken then
            self:grammarErrorOnNode(grandparentLeft, diagnostics.X_0_and_1_operations_cannot_be_mixed_without_parentheses, scanner.TokenToString(Kind.QuestionQuestionToken), scanner.TokenToString(grandparentOperatorToken.kind))
        end
    elseif ast.IsBinaryExpression(left) then
        local operatorToken = left:AsBinaryExpression().operatorToken
        if operatorToken.kind == Kind.BarBarToken or operatorToken.kind == Kind.AmpersandAmpersandToken then
            self:grammarErrorOnNode(left, diagnostics.X_0_and_1_operations_cannot_be_mixed_without_parentheses, scanner.TokenToString(operatorToken.kind), scanner.TokenToString(Kind.QuestionQuestionToken))
        end
    elseif ast.IsBinaryExpression(right) then
        local operatorToken = right:AsBinaryExpression().operatorToken
        if operatorToken.kind == Kind.AmpersandAmpersandToken then
            self:grammarErrorOnNode(right, diagnostics.X_0_and_1_operations_cannot_be_mixed_without_parentheses, scanner.TokenToString(Kind.QuestionQuestionToken), scanner.TokenToString(operatorToken.kind))
        end
    end
    self:checkNullishCoalesceOperandLeft(left)
end

function Checker:checkNullishCoalesceOperandLeft(left)
    local leftTarget = ast.SkipOuterExpressions(left, OuterExpressionKinds.OEKAll)
    local nullishSemantics = self:getSyntacticNullishnessSemantics(leftTarget)
    if nullishSemantics ~= PredicateSemantics.Sometimes then
        if nullishSemantics == PredicateSemantics.Always then
            self:error(leftTarget, diagnostics.This_expression_is_always_nullish)
        else
            self:error(leftTarget, diagnostics.Right_operand_of_is_unreachable_because_the_left_operand_is_never_nullish)
        end
    end
end

local sometimesNullishKinds = ast.kindSet(Kind.AwaitExpression,
    Kind.CallExpression,
    Kind.TaggedTemplateExpression,
    Kind.ElementAccessExpression,
    Kind.MetaProperty,
    Kind.NewExpression,
    Kind.PropertyAccessExpression,
    Kind.YieldExpression,
    Kind.ThisKeyword)

function Checker:getSyntacticNullishnessSemantics(node)
    node = ast.SkipOuterExpressions(node, OuterExpressionKinds.OEKAll)
    local kind = node.kind
    if sometimesNullishKinds[kind] then
        return PredicateSemantics.Sometimes
    elseif kind == Kind.BinaryExpression then
        -- List of operators that can produce null/undefined:
        -- || ||= && &&= ?? ??=
        local op = node:AsBinaryExpression().operatorToken.kind
        if op == Kind.BarBarToken or
            op == Kind.BarBarEqualsToken or
            op == Kind.AmpersandAmpersandToken or
            op == Kind.AmpersandAmpersandEqualsToken then
            return PredicateSemantics.Sometimes
        elseif op == Kind.CommaToken or
            op == Kind.EqualsToken then
            -- For these operator kinds, the right operand is effectively controlling
            return self:getSyntacticNullishnessSemantics(node:AsBinaryExpression().right)
        elseif op == Kind.QuestionQuestionToken or
            op == Kind.QuestionQuestionEqualsToken then
            -- For nullish coalescing: result is the left operand when left is non-null,
            -- or the right operand when left is null/undefined. The nullishness of the
            -- result combines both paths: the left's non-null path contributes Never,
            -- and when left can be null, the right's semantics are also included.
            local leftSemantics = self:getSyntacticNullishnessSemantics(node:AsBinaryExpression().left)
            -- The non-null path (left is non-null): left branch taken, result has Never bit
            local result = leftSemantics & PredicateSemantics.Never
            -- The null path (left is null/undefined): right branch taken, result inherits right's semantics
            if leftSemantics & PredicateSemantics.Always ~= 0 then
                result = result | self:getSyntacticNullishnessSemantics(node:AsBinaryExpression().right)
            end
            return result
        end
        return PredicateSemantics.Never
    elseif kind == Kind.ConditionalExpression then
        return self:getSyntacticNullishnessSemantics(node:AsConditionalExpression().whenTrue) | self:getSyntacticNullishnessSemantics(node:AsConditionalExpression().whenFalse)
    elseif kind == Kind.NullKeyword then
        return PredicateSemantics.Always
    elseif kind == Kind.Identifier then
        if self:getResolvedSymbol(node) == self.undefinedSymbol then
            return PredicateSemantics.Always
        end
        return PredicateSemantics.Sometimes
    end
    return PredicateSemantics.Never
end

local sideEffectFreeKinds = ast.kindSet(Kind.Identifier, Kind.StringLiteral, Kind.RegularExpressionLiteral, Kind.TaggedTemplateExpression, Kind.TemplateExpression,
    Kind.NoSubstitutionTemplateLiteral, Kind.NumericLiteral, Kind.BigIntLiteral, Kind.TrueKeyword, Kind.FalseKeyword,
    Kind.NullKeyword, Kind.UndefinedKeyword, Kind.FunctionExpression, Kind.ClassExpression, Kind.ArrowFunction,
    Kind.ArrayLiteralExpression, Kind.ObjectLiteralExpression, Kind.TypeOfExpression, Kind.NonNullExpression, Kind.JsxSelfClosingElement,
    Kind.JsxElement)

--
-- This is a *shallow* check: An expression is side-effect-free if the
-- evaluation of the expression *itself* cannot produce side effects.
-- For example, x++ / 3 is side-effect free because the / operator
-- does not have side effects.
-- The intent is to "smell test" an expression for correctness in positions where
-- its value is discarded (e.g. the left side of the comma operator).
--
function Checker:isSideEffectFree(node)
    node = ast.SkipParentheses(node)
    local kind = node.kind
    if sideEffectFreeKinds[kind] then
        return true
    elseif kind == Kind.ConditionalExpression then
        return self:isSideEffectFree(node:AsConditionalExpression().whenTrue) and self:isSideEffectFree(node:AsConditionalExpression().whenFalse)
    elseif kind == Kind.BinaryExpression then
        if ast.IsAssignmentOperator(node:AsBinaryExpression().operatorToken.kind) then
            return false
        end
        return self:isSideEffectFree(node:AsBinaryExpression().left) and self:isSideEffectFree(node:AsBinaryExpression().right)
    elseif kind == Kind.PrefixUnaryExpression then
        -- Unary operators ~, !, +, and - have no side effects.
        -- The rest do.
        local op = node:AsPrefixUnaryExpression().operator
        if op == Kind.ExclamationToken or op == Kind.PlusToken or op == Kind.MinusToken or op == Kind.TildeToken then
            return true
        end
    end
    return false
end

-- Return true for "indirect calls", (i.e. `(0, x.f)(...)` or `(0, eval)(...)`), which prevents passing `this`.
function Checker:isIndirectCall(node)
    local left = node:AsBinaryExpression().left
    local right = node:AsBinaryExpression().right
    return ast.IsParenthesizedExpression(node.parent) and ast.IsNumericLiteral(left) and left:Text() == "0" and
        (ast.IsCallExpression(node.parent.parent) and node.parent.parent:Expression() == node.parent or
            ast.IsTaggedTemplateExpression(node.parent.parent)) and (ast.IsAccessExpression(right) or ast.IsIdentifier(right) and right:Text() == "eval")
end

function Checker:checkInstanceOfExpression(left, right, leftType, rightType, checkMode)
    if leftType == self.silentNeverType or rightType == self.silentNeverType then
        return self.silentNeverType
    end
    -- TypeScript 1.0 spec (April 2014): 4.15.4
    -- The instanceof operator requires the left operand to be of type Any, an object type, or a type parameter type,
    -- and the right operand to be of type Any, a subtype of the 'Function' interface type, or have a call or construct signature.
    -- The result is always of the Boolean primitive type.
    -- NOTE: do not raise error if leftType is unknown as related error was already reported
    if not checker.IsTypeAny(leftType) and self:allTypesAssignableToKind(leftType, TypeFlags.Primitive) then
        self:error(left, diagnostics.The_left_hand_side_of_an_instanceof_expression_must_be_of_type_any_an_object_type_or_a_type_parameter)
    end
    local signature = self:getResolvedSignature(left.parent, nil --[[candidatesOutArray]], checkMode)
    if signature == self.resolvingSignature then
        -- CheckMode.SkipGenericFunctions is enabled and this is a call to a generic function that
        -- returns a function type. We defer checking and return silentNeverType.
        return self.silentNeverType
    end
    -- If rightType has a `[Symbol.hasInstance]` method that is not `(value: unknown) => boolean`, we
    -- must check the expression as if it were a call to `right[Symbol.hasInstance](left)`. The call to
    -- `getResolvedSignature`, below, will check that leftType is assignable to the type of the first
    -- parameter.
    local returnType = self:getReturnTypeOfSignature(signature)
    -- We also verify that the return type of the `[Symbol.hasInstance]` method is assignable to
    -- `boolean`. According to the spec, the runtime will actually perform `ToBoolean` on the result,
    -- but this is more type-safe.
    self:checkTypeAssignableTo(returnType, self.booleanType, right, diagnostics.An_object_s_Symbol_hasInstance_method_must_return_a_boolean_value_for_it_to_be_used_on_the_right_hand_side_of_an_instanceof_expression)
    return self.booleanType
end

function Checker:checkInExpression(left, right, leftType, rightType)
    if leftType == self.silentNeverType or rightType == self.silentNeverType then
        return self.silentNeverType
    end
    if ast.IsPrivateIdentifier(left) then
        if self.languageVersion < checker.LanguageFeatureMinimumTarget.PrivateNamesAndClassStaticBlocks or
            self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators or
            not self.compilerOptions:GetUseDefineForClassFields() then
            self:checkExternalEmitHelpers(left, ExternalEmitHelpers.ClassPrivateFieldIn)
        end
        -- Unlike in 'checkPrivateIdentifierExpression' we now have access to the RHS type
        -- which provides us with the opportunity to emit more detailed errors
        if self.symbolNodeLinks:Get(left).resolvedSymbol == nil and ast.GetContainingClass(left) ~= nil then
            local isUncheckedJS = self:isUncheckedJSSuggestion(left, rightType.symbol, true --[[excludeClasses]])
            self:reportNonexistentProperty(left, rightType, isUncheckedJS)
        end
    else
        -- The type of the left operand must be assignable to string, number, or symbol.
        self:checkTypeAssignableTo(self:checkNonNullType(leftType, left), self.stringNumberSymbolType, left, nil)
    end
    -- The type of the right operand must be assignable to 'object'.
    if self:checkTypeAssignableTo(self:checkNonNullType(rightType, right), self.nonPrimitiveType, right, nil) then
        -- The {} type is assignable to the object type, yet {} might represent a primitive type. Here we
        -- detect and error on {} that results from narrowing the unknown type, as well as intersections
        -- that include {} (we know that the other types in such intersections are assignable to object
        -- since we already checked for that).
        if self:hasEmptyObjectIntersection(rightType) then
            self:error(right, diagnostics.Type_0_may_represent_a_primitive_value_which_is_not_permitted_as_the_right_operand_of_the_in_operator, self:TypeToString(rightType))
        end
    end
    -- The result is always of the Boolean primitive type.
    return self.booleanType
end

function Checker:hasEmptyObjectIntersection(t)
    return checker.someType(t, function(u)
        return u == self.unknownEmptyObjectType or u.flags & TypeFlags.Intersection ~= 0 and self:IsEmptyAnonymousObjectType(self:getBaseConstraintOrType(u))
    end)
end

function Checker:getExactOptionalUnassignableProperties(source, target)
    if checker.isTupleType(source) and checker.isTupleType(target) then
        return nil
    end
    return core.Filter(self:getPropertiesOfType(target), function(targetProp)
        return self:isExactOptionalPropertyMismatch(self:getTypeOfPropertyOfType(source, targetProp.name), self:getTypeOfSymbol(targetProp))
    end)
end

function Checker:isExactOptionalPropertyMismatch(source, target)
    return source ~= nil and target ~= nil and self:maybeTypeOfKind(source, TypeFlags.Undefined) and self.containsMissingType(target)
end

function Checker:checkReferenceExpression(expr, invalidReferenceMessage, invalidOptionalChainMessage)
    -- References are combinations of identifiers, parentheses, and property accesses.
    local node = ast.SkipOuterExpressions(expr, OuterExpressionKinds.OEKAssertions | OuterExpressionKinds.OEKParentheses)
    if node.kind ~= Kind.Identifier and not ast.IsAccessExpression(node) then
        self:error(expr, invalidReferenceMessage)
        return false
    end
    if node.flags & NodeFlags.OptionalChain ~= 0 then
        self:error(expr, invalidOptionalChainMessage)
        return false
    end
    return true
end


function Checker:checkObjectLiteral(node, checkMode)
    local c = self
    -- Expando object literals have empty properties but filled exports
    if core.Len(node:Properties()) == 0 and node:Symbol() ~= nil and next(node:Symbol().exports or {}) ~= nil then
        local result = c:newAnonymousType(node:Symbol(), node:Symbol().exports, nil, nil, nil)
        if ast.IsInJSFile(node) and not ast.IsInJsonFile(node) then
            result.objectFlags = result.objectFlags | ObjectFlags.JSLiteral
        end
        -- An expando object literal has no property children (len == 0), so there
        -- is nothing to check here.
        return result
    end
    c:checkNodeDeferred(node)
    local inDestructuringPattern = ast.IsAssignmentTarget(node)
    -- Grammar checking
    c:checkGrammarObjectLiteralExpression(node:AsObjectLiteralExpression(), inDestructuringPattern)
    local allPropertiesTable = nil
    if c.strictNullChecks then
        allPropertiesTable = ast.NewSymbolTable()
    end
    local propertiesTable = ast.NewSymbolTable()
    local propertiesArray = nil
    local spread = c.emptyObjectType
    c:pushCachedContextualType(node)
    local contextualType = c:getApparentTypeOfContextualType(node, ContextFlags.None)
    local contextualTypeHasPattern = false
    if contextualType ~= nil then
        local pattern = c.patternForType[contextualType]
        if pattern ~= nil and (ast.IsObjectBindingPattern(pattern) or ast.IsObjectLiteralExpression(pattern)) then
            contextualTypeHasPattern = true
        end
    end
    local inConstContext = c:isConstContext(node)
    local checkFlags = 0
    if inConstContext then
        checkFlags = CheckFlags.Readonly
    end
    local objectFlags = ObjectFlags.FreshLiteral
    local patternWithComputedProperties = false
    local hasComputedStringProperty = false
    local hasComputedNumberProperty = false
    local hasComputedSymbolProperty = false
    -- Spreads may cause an early bail; ensure computed names are always checked (this is cached)
    -- As otherwise they may not be checked until exports for the type at this position are retrieved,
    -- which may never occur.
    for _, elem in ipairs(node:Properties() or {}) do
        if elem:Name() ~= nil and ast.IsComputedPropertyName(elem:Name()) then
            c:checkComputedPropertyName(elem:Name())
        end
    end
    local offset = 0
    local createObjectLiteralType = function()
        local indexInfos = nil
        local isReadonly = c:isConstContext(node)
        if hasComputedStringProperty then
            indexInfos = core.Append(indexInfos, c:getObjectLiteralIndexInfo(isReadonly, core.Slice(propertiesArray, offset), c.stringType))
        end
        if hasComputedNumberProperty then
            indexInfos = core.Append(indexInfos, c:getObjectLiteralIndexInfo(isReadonly, core.Slice(propertiesArray, offset), c.numberType))
        end
        if hasComputedSymbolProperty then
            indexInfos = core.Append(indexInfos, c:getObjectLiteralIndexInfo(isReadonly, core.Slice(propertiesArray, offset), c.esSymbolType))
        end
        local result = c:newAnonymousType(node:Symbol(), propertiesTable, nil, nil, indexInfos)
        result.objectFlags = result.objectFlags | objectFlags | ObjectFlags.ObjectLiteral | ObjectFlags.ContainsObjectOrArrayLiteral
        if contextualType == nil and ast.IsInJSFile(node) and not ast.IsInJsonFile(node) then
            result.objectFlags = result.objectFlags | ObjectFlags.JSLiteral
        end
        if patternWithComputedProperties then
            result.objectFlags = result.objectFlags | ObjectFlags.ObjectLiteralPatternWithComputedProperties
        end
        if inDestructuringPattern then
            c.patternForType[result] = node
        end
        return result
    end
    for _, memberDecl in ipairs(node:Properties() or {}) do
        local member = c:getSymbolOfDeclaration(memberDecl)
        local computedNameType = nil
        if memberDecl:Name() ~= nil and memberDecl:Name().kind == Kind.ComputedPropertyName then
            computedNameType = c:checkComputedPropertyName(memberDecl:Name())
        end
        if ast.IsPropertyAssignment(memberDecl) or ast.IsShorthandPropertyAssignment(memberDecl) or ast.IsObjectLiteralMethod(memberDecl) then
            local t
            if memberDecl.kind == Kind.PropertyAssignment then
                t = c:checkPropertyAssignment(memberDecl, checkMode)
            elseif memberDecl.kind == Kind.ShorthandPropertyAssignment then
                t = c:checkShorthandPropertyAssignment(memberDecl, inDestructuringPattern, checkMode)
            else
                t = c:checkObjectLiteralMethod(memberDecl, checkMode)
            end
            objectFlags = objectFlags | (t.objectFlags & ObjectFlags.PropagatingFlags)
            local nameType = nil
            if computedNameType ~= nil and checker.isTypeUsableAsPropertyName(computedNameType) then
                nameType = computedNameType
            end
            local prop
            if nameType ~= nil then
                prop = c:newSymbolEx(SymbolFlags.Property | member.flags, checker.getPropertyNameFromType(nameType), checkFlags | CheckFlags.Late)
            else
                prop = c:newSymbolEx(SymbolFlags.Property | member.flags, member.name, checkFlags)
            end
            local links = c.valueSymbolLinks:Get(prop)
            if nameType ~= nil then
                links.nameType = nameType
            end
            if inDestructuringPattern and c:hasDefaultValue(memberDecl) then
                -- If object literal is an assignment pattern and if the assignment pattern specifies a default value
                -- for the property, make the property optional.
                prop.flags = prop.flags | SymbolFlags.Optional
            elseif contextualTypeHasPattern and contextualType.objectFlags & ObjectFlags.ObjectLiteralPatternWithComputedProperties == 0 then
                -- If object literal is contextually typed by the implied type of a binding pattern, and if the
                -- binding pattern specifies a default value for the property, make the property optional.
                local impliedProp = c:getPropertyOfType(contextualType, member.name)
                if impliedProp ~= nil then
                    prop.flags = prop.flags | (impliedProp.flags & SymbolFlags.Optional)
                elseif c:getIndexInfoOfType(contextualType, c.stringType) == nil then
                    c:error(memberDecl:Name(), diagnostics.Object_literal_may_only_specify_known_properties_and_0_does_not_exist_in_type_1, c:symbolToString(member), c:TypeToString(contextualType))
                end
            end
            prop.declarations = member.declarations
            prop.parent = member.parent
            prop.valueDeclaration = member.valueDeclaration
            links.resolvedType = t
            links.target = member
            member = prop
            if allPropertiesTable ~= nil then
                allPropertiesTable[prop.name] = prop
            end
            if contextualType ~= nil and checkMode & CheckMode.Inferential ~= 0 and checkMode & CheckMode.SkipContextSensitive == 0 and (ast.IsPropertyAssignment(memberDecl) or ast.IsMethodDeclaration(memberDecl)) and c:isContextSensitive(memberDecl) then
                local inferenceContext = c:getInferenceContext(node)
                -- In CheckMode.Inferential we should always have an inference context
                local inferenceNode = memberDecl
                if ast.IsPropertyAssignment(memberDecl) then
                    inferenceNode = memberDecl:Initializer()
                end
                c:addIntraExpressionInferenceSite(inferenceContext, inferenceNode, t)
            end
        elseif memberDecl.kind == Kind.SpreadAssignment then
            if core.Len(propertiesArray) > 0 then
                spread = c:getSpreadType(spread, createObjectLiteralType(), node:Symbol(), objectFlags, inConstContext)
                propertiesArray = nil
                propertiesTable = ast.NewSymbolTable()
                hasComputedStringProperty = false
                hasComputedNumberProperty = false
                hasComputedSymbolProperty = false
            end
            local t = c:getReducedType(c:checkExpressionEx(memberDecl:Expression(), checkMode & CheckMode.Inferential))
            if c:isValidSpreadType(t) then
                local mergedType = c:tryMergeUnionOfObjectTypeAndEmptyObject(t, inConstContext)
                if allPropertiesTable ~= nil then
                    c:checkSpreadPropOverrides(mergedType, allPropertiesTable, memberDecl)
                end
                offset = core.Len(propertiesArray)
                if c:isErrorType(spread) then
                    goto continue
                end
                spread = c:getSpreadType(spread, mergedType, node:Symbol(), objectFlags, inConstContext)
            else
                c:error(memberDecl, diagnostics.Spread_types_may_only_be_created_from_object_types)
                spread = c.errorType
            end
            goto continue
        else
            -- TypeScript 1.0 spec (April 2014)
            -- A get accessor declaration is processed in the same manner as
            -- an ordinary function declaration(section 6.1) with no parameters.
            -- A set accessor declaration is processed in the same manner
            -- as an ordinary function declaration with a single parameter and a Void return type.
            debug.Assert(memberDecl.kind == Kind.GetAccessor or memberDecl.kind == Kind.SetAccessor)
            c:checkNodeDeferred(memberDecl)
        end
        if computedNameType ~= nil and computedNameType.flags & TypeFlags.StringOrNumberLiteralOrUnique == 0 then
            if c:isTypeAssignableTo(computedNameType, c.stringNumberSymbolType) then
                if c:isTypeAssignableTo(computedNameType, c.numberType) then
                    hasComputedNumberProperty = true
                elseif c:isTypeAssignableTo(computedNameType, c.esSymbolType) then
                    hasComputedSymbolProperty = true
                else
                    hasComputedStringProperty = true
                end
                if inDestructuringPattern then
                    patternWithComputedProperties = true
                end
            end
        else
            propertiesTable[member.name] = member
        end
        propertiesArray = core.Append(propertiesArray, member)
        ::continue::
    end
    c:popContextualType()
    if c:isErrorType(spread) then
        return c.errorType
    end
    if spread ~= c.emptyObjectType then
        if core.Len(propertiesArray) > 0 then
            spread = c:getSpreadType(spread, createObjectLiteralType(), node:Symbol(), objectFlags, inConstContext)
            propertiesArray = nil
            propertiesTable = ast.NewSymbolTable()
            hasComputedStringProperty = false
            hasComputedNumberProperty = false
        end
        -- remap the raw emptyObjectType fed in at the top into a fresh empty object literal type, unique to this use site
        return c:mapType(spread, function(t)
            if t == c.emptyObjectType then
                return createObjectLiteralType()
            end
            return t
        end)
    end
    return createObjectLiteralType()
end

function Checker:checkContextualDeprecations(node)
    local contextualType = self:getApparentTypeOfContextualType(node, ContextFlags.None)
    for _, property in ipairs(node:Properties() or {}) do
        if self:isCanceled() then
            return
        end
        if property:Name() ~= nil and not ast.IsComputedPropertyName(property:Name()) then
            self:checkDeprecatedProperty(property:Name(), contextualType)
        end
    end
end

function Checker:checkDeprecatedProperty(name, contextualType)
    if contextualType == nil then
        return
    end
    local prop = self:getPropertyOfType(contextualType, name:Text())
    if prop == nil or core.Len(prop.declarations) == 0 then
        return
    end
    if self:isDeprecatedSymbol(prop) then
        self:addDeprecatedSuggestion(name, prop.declarations, name:Text())
    end
end

function Checker:checkSpreadPropOverrides(t, props, spread)
    for _, right in ipairs(self:getPropertiesOfType(t) or {}) do
        if right.flags & SymbolFlags.Optional == 0 and right.checkFlags & CheckFlags.Partial == 0 then
            local left = props[right.name]
            if left ~= nil then
                local diagnostic = self:error(left.valueDeclaration, diagnostics.X_0_is_specified_more_than_once_so_this_usage_will_be_overwritten, left.name)
                diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(spread, diagnostics.This_spread_always_overwrites_this_property))
            end
        end
    end
end


--
-- Since the source of spread types are object literals, which are not binary,
-- this function should be called in a left folding style, with left = previous result of getSpreadType
-- and right = the new element to be spread.
--
function Checker:getSpreadType(left, right, symbol, objectFlags, readonly)
    if left.flags & TypeFlags.Any ~= 0 or right.flags & TypeFlags.Any ~= 0 then
        return self.anyType
    end
    if left.flags & TypeFlags.Unknown ~= 0 or right.flags & TypeFlags.Unknown ~= 0 then
        return self.unknownType
    end
    if left.flags & TypeFlags.Never ~= 0 then
        return right
    end
    if right.flags & TypeFlags.Never ~= 0 then
        return left
    end
    left = self:tryMergeUnionOfObjectTypeAndEmptyObject(left, readonly)
    if left.flags & TypeFlags.Union ~= 0 then
        if self:checkCrossProductUnion({ left, right }) then
            return self:mapType(left, function(t)
                return self:getSpreadType(t, right, symbol, objectFlags, readonly)
            end)
        end
        return self.errorType
    end
    right = self:tryMergeUnionOfObjectTypeAndEmptyObject(right, readonly)
    if right.flags & TypeFlags.Union ~= 0 then
        if self:checkCrossProductUnion({ left, right }) then
            return self:mapType(right, function(t)
                return self:getSpreadType(left, t, symbol, objectFlags, readonly)
            end)
        end
        return self.errorType
    end
    if right.flags & (TypeFlags.BooleanLike | TypeFlags.NumberLike | TypeFlags.BigIntLike | TypeFlags.StringLike | TypeFlags.EnumLike | TypeFlags.NonPrimitive | TypeFlags.Index) ~= 0 then
        return left
    end
    if self:isGenericObjectType(left) or self:isGenericObjectType(right) then
        if self:isEmptyObjectType(left) then
            return right
        end
        -- When the left type is an intersection, we may need to merge the last constituent of the
        -- intersection with the right type. For example when the left type is 'T & { a: string }'
        -- and the right type is '{ b: string }' we produce 'T & { a: string, b: string }'.
        if left.flags & TypeFlags.Intersection ~= 0 then
            local types = left:Types()
            local lastLeft = types[#types]
            if self:isNonGenericObjectType(lastLeft) and self:isNonGenericObjectType(right) then
                local newTypes = core.Slice(types, 0)
                newTypes[#newTypes] = self:getSpreadType(lastLeft, right, symbol, objectFlags, readonly)
                return self:getIntersectionType(newTypes)
            end
        end
        return self:getIntersectionType({ left, right })
    end
    local members = ast.NewSymbolTable()
    local skippedPrivateMembers = {}
    local indexInfos
    if left == self.emptyObjectType then
        indexInfos = self:getIndexInfosOfType(right)
    else
        indexInfos = self:getUnionIndexInfos({ left, right })
    end
    for _, rightProp in ipairs(self:getPropertiesOfType(right) or {}) do
        if checker.getDeclarationModifierFlagsFromSymbol(rightProp) & (ModifierFlags.Private | ModifierFlags.Protected) ~= 0 then
            skippedPrivateMembers[rightProp.name] = true
        elseif self:isSpreadableProperty(rightProp) then
            members[rightProp.name] = self:getSpreadSymbol(rightProp, readonly)
        end
    end

    for _, leftProp in ipairs(self:getPropertiesOfType(left) or {}) do
        if skippedPrivateMembers[leftProp.name] or not self:isSpreadableProperty(leftProp) then
            goto continue
        end
        if members[leftProp.name] ~= nil then
            local rightProp = members[leftProp.name]
            local rightType = self:getTypeOfSymbol(rightProp)
            if rightProp.flags & SymbolFlags.Optional ~= 0 then
                local declarations = core.Concatenate(leftProp.declarations, rightProp.declarations)
                local flags = SymbolFlags.Property | (leftProp.flags & SymbolFlags.Optional)
                local result = self:newSymbol(flags, leftProp.name)
                local links = self.valueSymbolLinks:Get(result)
                -- Optimization: avoid calculating the union type if spreading into the exact same type.
                -- This is common, e.g. spreading one options bag into another where the bags have the
                -- same type, or have properties which overlap. If the unions are large, it may turn out
                -- to be expensive to perform subtype reduction.
                local leftType = self:getTypeOfSymbol(leftProp)
                local leftTypeWithoutUndefined = self:removeMissingOrUndefinedType(leftType)
                local rightTypeWithoutUndefined = self:removeMissingOrUndefinedType(rightType)
                if leftTypeWithoutUndefined == rightTypeWithoutUndefined then
                    links.resolvedType = leftType
                else
                    links.resolvedType = self:getUnionTypeEx({ leftType, rightTypeWithoutUndefined }, UnionReduction.Subtype, nil, nil)
                end
                self.spreadLinks:Get(result).leftSpread = leftProp
                self.spreadLinks:Get(result).rightSpread = rightProp
                result.declarations = declarations
                links.nameType = self.valueSymbolLinks:Get(leftProp).nameType
                members[leftProp.name] = result
            end
        else
            members[leftProp.name] = self:getSpreadSymbol(leftProp, readonly)
        end
        ::continue::
    end
    local spreadIndexInfos = core.SameMap(indexInfos, function(info)
        return self:getIndexInfoWithReadonly(info, readonly)
    end)
    local spread = self:newAnonymousType(symbol, members, nil, nil, spreadIndexInfos)
    spread.objectFlags = spread.objectFlags | ObjectFlags.ObjectLiteral | ObjectFlags.ContainsObjectOrArrayLiteral | checker.ObjectFlagsContainsSpread | objectFlags
    return spread
end

function Checker:getIndexInfoWithReadonly(info, readonly)
    if info.isReadonly ~= readonly then
        return self:newIndexInfo(info.keyType, info.valueType, readonly, info.declaration, info.components)
    end
    return info
end

function Checker:isValidSpreadType(t)
    local s = self:removeDefinitelyFalsyTypes(self:mapType(t, function(u) return self:getBaseConstraintOrType(u) end))
    return s.flags & (TypeFlags.Any | TypeFlags.NonPrimitive | TypeFlags.Object | TypeFlags.InstantiableNonPrimitive) ~= 0 or
        s.flags & TypeFlags.UnionOrIntersection ~= 0 and core.Every(s:Types(), function(u) return self:isValidSpreadType(u) end)
end

function Checker:getUnionIndexInfos(types)
    local sourceInfos = self:getIndexInfosOfType(types[1])
    local result = nil
    for _, info in ipairs(sourceInfos or {}) do
        local indexType = info.keyType
        if core.Every(types, function(t) return self:getIndexInfoOfType(t, indexType) ~= nil end) then
            local valueType = self:getUnionType(core.Map(types, function(t)
                return self:getIndexTypeOfType(t, indexType)
            end))
            local isReadonly = core.Some(types, function(t) return self:getIndexInfoOfType(t, indexType).isReadonly end)
            result = core.Append(result, self:newIndexInfo(indexType, valueType, isReadonly, nil, nil))
        end
    end
    return result
end

function Checker:isNonGenericObjectType(t)
    return t.flags & TypeFlags.Object ~= 0 and not self:isGenericMappedType(t)
end

function Checker:tryMergeUnionOfObjectTypeAndEmptyObject(t, readonly)
    if t.flags & TypeFlags.Union == 0 then
        return t
    end
    if core.Every(t:Types(), function(u) return self:isEmptyObjectTypeOrSpreadsIntoEmptyObject(u) end) then
        local empty = core.Find(t:Types(), function(u) return self:isEmptyObjectType(u) end)
        if empty ~= nil then
            return empty
        end
        return self.emptyObjectType
    end
    local firstType = core.Find(t:Types(), function(u)
        return not self:isEmptyObjectTypeOrSpreadsIntoEmptyObject(u)
    end)
    if firstType == nil then
        return t
    end
    local secondType = core.Find(t:Types(), function(u)
        return u ~= firstType and not self:isEmptyObjectTypeOrSpreadsIntoEmptyObject(u)
    end)
    if secondType ~= nil then
        return t
    end
    -- gets the type as if it had been spread, but where everything in the spread is made optional
    local members = ast.NewSymbolTable()
    for _, prop in ipairs(self:getPropertiesOfType(firstType) or {}) do
        if checker.getDeclarationModifierFlagsFromSymbol(prop) & (ModifierFlags.Private | ModifierFlags.Protected) ~= 0 then
            -- do nothing, skip privates
        elseif self:isSpreadableProperty(prop) then
            local isSetonlyAccessor = prop.flags & SymbolFlags.SetAccessor ~= 0 and prop.flags & SymbolFlags.GetAccessor == 0
            local flags = SymbolFlags.Property | SymbolFlags.Optional
            local result = self:newSymbolEx(flags, prop.name, (prop.checkFlags & CheckFlags.Late) | core.IfElse(readonly, CheckFlags.Readonly, 0))
            local links = self.valueSymbolLinks:Get(result)
            if isSetonlyAccessor then
                links.resolvedType = self.undefinedType
            else
                links.resolvedType = self:addOptionalityEx(self:getTypeOfSymbol(prop), true --[[isProperty]], true --[[isOptional]])
            end
            result.declarations = prop.declarations
            links.nameType = self.valueSymbolLinks:Get(prop).nameType
            self.mappedSymbolLinks:Get(result).syntheticOrigin = prop
            members[prop.name] = result
        end
    end
    local spread = self:newAnonymousType(firstType.symbol, members, nil, nil, self:getIndexInfosOfType(firstType))
    spread.objectFlags = spread.objectFlags | ObjectFlags.ObjectLiteral | ObjectFlags.ContainsObjectOrArrayLiteral
    return spread
end

-- We approximate own properties as non-methods plus methods that are inside the object literal
function Checker:isSpreadableProperty(prop)
    return not core.Some(prop.declarations, ast.IsPrivateIdentifierClassElementDeclaration) and prop.flags & (SymbolFlags.Method | SymbolFlags.GetAccessor | SymbolFlags.SetAccessor) == 0 or
        not core.Some(prop.declarations, function(d) return d.parent ~= nil and ast.IsClassLike(d.parent) end)
end

function Checker:getSpreadSymbol(prop, readonly)
    local isSetonlyAccessor = prop.flags & SymbolFlags.SetAccessor ~= 0 and prop.flags & SymbolFlags.GetAccessor == 0
    if not isSetonlyAccessor and readonly == self:isReadonlySymbol(prop) then
        return prop
    end
    local flags = SymbolFlags.Property | (prop.flags & SymbolFlags.Optional)
    local result = self:newSymbolEx(flags, prop.name, (prop.checkFlags & CheckFlags.Late) | core.IfElse(readonly, CheckFlags.Readonly, 0))
    local links = self.valueSymbolLinks:Get(result)
    if isSetonlyAccessor then
        links.resolvedType = self.undefinedType
    else
        links.resolvedType = self:getTypeOfSymbol(prop)
    end
    result.declarations = prop.declarations
    links.nameType = self.valueSymbolLinks:Get(prop).nameType
    self.mappedSymbolLinks:Get(result).syntheticOrigin = prop
    return result
end

function Checker:isEmptyObjectTypeOrSpreadsIntoEmptyObject(t)
    return self:isEmptyObjectType(t) or t.flags & (TypeFlags.Null | TypeFlags.Undefined | TypeFlags.BooleanLike | TypeFlags.NumberLike | TypeFlags.BigIntLike | TypeFlags.StringLike | TypeFlags.EnumLike | TypeFlags.NonPrimitive | TypeFlags.Index) ~= 0
end

function Checker:hasDefaultValue(node)
    return ast.IsBindingElement(node) and node:Initializer() ~= nil or
        ast.IsPropertyAssignment(node) and self:hasDefaultValue(node:Initializer()) or
        ast.IsShorthandPropertyAssignment(node) and node:AsShorthandPropertyAssignment().objectAssignmentInitializer ~= nil or
        ast.IsBinaryExpression(node) and node:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken
end

function Checker:isConstContext(node)
    local parent = node.parent
    return ast.IsConstAssertion(parent) or
        self:isValidConstAssertionArgument(node) and self:isConstTypeVariable(self:getContextualType(node, ContextFlags.None), 0) or
        (ast.IsParenthesizedExpression(parent) or ast.IsArrayLiteralExpression(parent) or ast.IsSpreadElement(parent)) and self:isConstContext(parent) or
        (ast.IsPropertyAssignment(parent) or ast.IsShorthandPropertyAssignment(parent) or ast.IsTemplateSpan(parent)) and self:isConstContext(parent.parent)
end

local validConstAssertionArgumentKinds = ast.kindSet(Kind.StringLiteral, Kind.NoSubstitutionTemplateLiteral, Kind.NumericLiteral, Kind.BigIntLiteral, Kind.TrueKeyword,
    Kind.FalseKeyword, Kind.ArrayLiteralExpression, Kind.ObjectLiteralExpression, Kind.TemplateExpression)

function Checker:isValidConstAssertionArgument(node)
    local kind = node.kind
    if validConstAssertionArgumentKinds[kind] then
        return true
    elseif kind == Kind.ParenthesizedExpression then
        return self:isValidConstAssertionArgument(node:Expression())
    elseif kind == Kind.PrefixUnaryExpression then
        local op = node:AsPrefixUnaryExpression().operator
        local arg = node:AsPrefixUnaryExpression().operand
        return op == Kind.MinusToken and (arg.kind == Kind.NumericLiteral or arg.kind == Kind.BigIntLiteral) or op == Kind.PlusToken and arg.kind == Kind.NumericLiteral
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        local expr = ast.SkipParentheses(node:Expression())
        local symbol = nil
        if ast.IsEntityNameExpression(expr) then
            symbol = self:resolveEntityName(expr, SymbolFlags.Value, true --[[ignoreErrors]], false, nil)
        end
        return symbol ~= nil and symbol.flags & SymbolFlags.Enum ~= 0
    end
    return false
end

function Checker:isConstTypeVariable(t, depth)
    if depth >= 5 or t == nil then
        return false
    end
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        return t.symbol ~= nil and core.Some(t.symbol.declarations, function(d) return ast.HasSyntacticModifier(d, ModifierFlags.Const) end)
    elseif t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        return core.Some(t:Types(), function(s) return self:isConstTypeVariable(s, depth) end)
    elseif t.flags & TypeFlags.IndexedAccess ~= 0 then
        return self:isConstTypeVariable(t:AsIndexedAccessType().objectType, depth + 1)
    elseif t.flags & TypeFlags.Conditional ~= 0 then
        return self:isConstTypeVariable(self:getConstraintOfConditionalType(t), depth + 1)
    elseif t.flags & TypeFlags.Substitution ~= 0 then
        return self:isConstTypeVariable(t:AsSubstitutionType().baseType, depth)
    elseif t.objectFlags & ObjectFlags.Mapped ~= 0 then
        local typeVariable = self:getHomomorphicTypeVariable(t)
        return typeVariable ~= nil and self:isConstTypeVariable(typeVariable, depth)
    elseif self:isGenericTupleType(t) then
        for i, s in ipairs(self:getElementTypes(t) or {}) do
            if t:TargetTupleType().elementInfos[i].flags & ElementFlags.Variadic ~= 0 and self:isConstTypeVariable(s, depth) then
                return true
            end
        end
    end
    return false
end

function Checker:checkPropertyAssignment(node, checkMode)
    -- Do not use hasDynamicName here, because that returns false for well known symbols.
    -- We want to perform checkComputedPropertyName for all computed properties, including
    -- well known symbols.
    if ast.IsComputedPropertyName(node:Name()) then
        self:checkComputedPropertyName(node:Name())
    end
    local initializerType = self:checkExpressionForMutableLocation(node:Initializer(), checkMode)
    if node:Type() ~= nil then
        local t = self:getTypeFromTypeNode(node:Type())
        self:checkTypeAssignableToAndOptionallyElaborate(initializerType, t, node, node:Initializer(), nil --[[headMessage]], nil)
        return t
    end
    return initializerType
end

function Checker:checkShorthandPropertyAssignment(node, inDestructuringPattern, checkMode)
    local expr = nil
    if not inDestructuringPattern then
        expr = node:AsShorthandPropertyAssignment().objectAssignmentInitializer
    end
    if expr == nil then
        expr = node:Name()
    end
    local expressionType = self:checkExpressionForMutableLocation(expr, checkMode)
    if node:Type() ~= nil then
        local t = self:getTypeFromTypeNode(node:Type())
        self:checkTypeAssignableToAndOptionallyElaborate(expressionType, t, node, expr, nil --[[headMessage]], nil)
        return t
    end
    return expressionType
end

function Checker:isInPropertyInitializerOrClassStaticBlock(node, ignoreArrowFunctions)
    return ast.FindAncestorOrQuit(node, function(n)
        local kind = n.kind
        if kind == Kind.PropertyDeclaration or kind == Kind.ClassStaticBlockDeclaration then
            return FindAncestorResult.FindAncestorTrue
        elseif kind == Kind.TypeQuery or kind == Kind.JsxClosingElement then
            return FindAncestorResult.FindAncestorQuit
        elseif kind == Kind.ArrowFunction then
            return core.IfElse(ignoreArrowFunctions, FindAncestorResult.FindAncestorFalse, FindAncestorResult.FindAncestorQuit)
        elseif kind == Kind.Block then
            return core.IfElse(ast.IsFunctionLikeDeclaration(node.parent) and node.parent.kind ~= Kind.ArrowFunction, FindAncestorResult.FindAncestorQuit, FindAncestorResult.FindAncestorFalse)
        else
            return FindAncestorResult.FindAncestorFalse
        end
    end) ~= nil
end


function Checker:getNarrowedTypeOfSymbol(symbol, location)
    local t = self:getTypeOfSymbol(symbol)
    local declaration = symbol.valueDeclaration
    if declaration ~= nil then
        -- If we have a non-rest binding element with no initializer declared as a const variable or a const-like
        -- parameter (a parameter for which there are no assignments in the function body), and if the parent type
        -- for the destructuring is a union type, one or more of the binding elements may represent discriminant
        -- properties, and we want the effects of conditional checks on such discriminants to affect the types of
        -- other binding elements from the same destructuring. Consider:
        --
        --   type Action =
        --       | { kind: 'A', payload: number }
        --       | { kind: 'B', payload: string };
        --
        --   function f({ kind, payload }: Action) {
        --       if (kind === 'A') {
        --           payload.toFixed();
        --       }
        --       if (kind === 'B') {
        --           payload.toUpperCase();
        --       }
        --   }
        --
        -- Above, we want the conditional checks on 'kind' to affect the type of 'payload'. To facilitate this, we use
        -- the binding pattern AST instance for '{ kind, payload }' as a pseudo-reference and narrow this reference
        -- as if it occurred in the specified location. We then recompute the narrowed binding element type by
        -- destructuring from the narrowed parent type.
        if ast.IsBindingElement(declaration) and declaration:Initializer() == nil and not checker.hasDotDotDotToken(declaration) and core.Len(declaration.parent:Elements()) >= 2 then
            local rootDeclaration = ast.GetRootDeclaration(declaration)
            local rootInitializer = rootDeclaration:Initializer()
            -- Avoid declaration circularity without blocking binding defaults or nested callbacks.
            if not (rootInitializer ~= nil and
                ast.IsNodeDescendantOf(location, rootInitializer) and
                self:getControlFlowContainer(declaration) == self:getControlFlowContainer(location)) then
                local parent = declaration.parent.parent
                if ast.IsVariableDeclaration(rootDeclaration) and self:getCombinedNodeFlagsCached(rootDeclaration) & NodeFlags.Constant ~= 0 or ast.IsParameterDeclaration(rootDeclaration) then
                    local links = self.nodeLinks:Get(parent)
                    if links.flags & NodeCheckFlags.InCheckIdentifier == 0 then
                        links.flags = links.flags | NodeCheckFlags.InCheckIdentifier
                        local parentType = self:getTypeForBindingElementParent(parent, CheckMode.Normal)
                        local parentTypeConstraint = nil
                        if parentType ~= nil then
                            parentTypeConstraint = self:mapType(parentType, function(u) return self:getBaseConstraintOrType(u) end)
                        end
                        -- Guard parent-type resolution only; flow analysis should allow re-entrant narrowing
                        links.flags = links.flags & ~NodeCheckFlags.InCheckIdentifier
                        if parentTypeConstraint ~= nil and parentTypeConstraint.flags & TypeFlags.Union ~= 0 and not (ast.IsParameterDeclaration(rootDeclaration) and self:isSomeSymbolAssigned(rootDeclaration)) then
                            local pattern = declaration.parent
                            local narrowedType = self:getFlowTypeOfReferenceEx(pattern, parentTypeConstraint, parentTypeConstraint, nil --[[flowContainer]], checker.getFlowNodeOfNode(location))
                            if narrowedType.flags & TypeFlags.Never ~= 0 then
                                t = self.neverType
                            else
                                -- Destructurings are validated against the parent type elsewhere. Here we disable tuple bounds
                                -- checks because the narrowed type may have lower arity than the full parent type. For example,
                                -- for the declaration [x, y]: [1, 2] | [3], we may have narrowed the parent type to just [3].
                                t = self:getBindingElementTypeFromParentType(declaration, narrowedType, true --[[noTupleBoundsCheck]])
                            end
                        end
                    end
                end
            end
        -- If we have a const-like parameter with no type annotation or initializer, and if the parameter is contextually
        -- typed by a signature with a single rest parameter of a union of tuple types, one or more of the parameters may
        -- represent discriminant tuple elements, and we want the effects of conditional checks on such discriminants to
        -- affect the types of other parameters in the same parameter list. Consider:
        --
        --   type Action = [kind: 'A', payload: number] | [kind: 'B', payload: string];
        --
        --   const f: (...args: Action) => void = (kind, payload) => {
        --       if (kind === 'A') {
        --           payload.toFixed();
        --       }
        --       if (kind === 'B') {
        --           payload.toUpperCase();
        --       }
        --   }
        --
        -- Above, we want the conditional checks on 'kind' to affect the type of 'payload'. To facilitate this, we use
        -- the arrow function AST node for '(kind, payload) => ...' as a pseudo-reference and narrow this reference as
        -- if it occurred in the specified location. We then recompute the narrowed parameter type by indexing into the
        -- narrowed tuple type.
        elseif ast.IsParameterDeclaration(declaration) and declaration:Type() == nil and declaration:Initializer() == nil and not checker.hasDotDotDotToken(declaration) then
            local fn = declaration.parent
            if core.Len(fn:Parameters()) >= 2 and self:isContextSensitiveFunctionOrObjectLiteralMethod(fn) then
                local contextualSignature = self:getContextualSignature(fn)
                if contextualSignature ~= nil and core.Len(contextualSignature.parameters) == 1 and checker.signatureHasRestParameter(contextualSignature) then
                    local mapper = nil
                    local context = self:getInferenceContext(fn)
                    if context ~= nil then
                        mapper = context.nonFixingMapper
                    end
                    local restType = self:getReducedApparentType(self:instantiateType(self:getTypeOfSymbol(contextualSignature.parameters[1]), mapper))
                    if restType.flags & TypeFlags.Union ~= 0 and checker.everyType(restType, checker.isTupleType) and not core.Some(fn:Parameters(), function(p) return self:isSomeSymbolAssigned(p) end) then
                        local narrowedType = self:getFlowTypeOfReferenceEx(fn, restType, restType, nil --[[flowContainer]], checker.getFlowNodeOfNode(location))
                        local index = indexOfValue(fn:Parameters(), declaration) - core.IfElse(ast.GetThisParameter(fn) ~= nil, 1, 0)
                        t = self:getIndexedAccessType(narrowedType, self:getNumberLiteralType(index + 0.0))
                    end
                end
            end
        end
    end
    return t
end

function Checker:isReadonlyAssignmentDeclaration(node)
    if not ast.IsCallExpression(node) then
        return false
    end
    local propertyDescriptorType = self:checkExpressionCached(node:Arguments()[3])
    local valueType = self:getTypeOfPropertyOfType(propertyDescriptorType, "value")
    if valueType ~= nil then
        local writableProp = self:getPropertyOfType(propertyDescriptorType, "writable")
        if writableProp ~= nil then
            local writableType
            if writableProp.valueDeclaration ~= nil and ast.IsPropertyAssignment(writableProp.valueDeclaration) then
                writableType = self:checkExpression(writableProp.valueDeclaration:Initializer())
            else
                writableType = self:getTypeOfSymbol(writableProp)
            end
            return writableType.flags & TypeFlags.BooleanLiteral ~= 0 and checker.getBooleanLiteralValue(writableType) == false
        end
        return true
    end
    return self:getTypeOfPropertyOfType(propertyDescriptorType, "set") == nil
end

function Checker:isReadonlySymbol(symbol)
    -- The following symbols are considered read-only:
    -- Properties with a 'readonly' modifier
    -- Variables declared with 'const'
    -- Get accessors without matching set accessors
    -- Enum members
    -- Object.defineProperty assignments with writable false or no setter
    -- Unions and intersections of the above (unions and intersections eagerly set isReadonly on creation)
    return symbol.checkFlags & CheckFlags.Readonly ~= 0 or
        symbol.flags & SymbolFlags.Property ~= 0 and checker.getDeclarationModifierFlagsFromSymbol(symbol) & ModifierFlags.Readonly ~= 0 or
        symbol.flags & SymbolFlags.Variable ~= 0 and self:getDeclarationNodeFlagsFromSymbol(symbol) & NodeFlags.Constant ~= 0 or
        symbol.flags & SymbolFlags.Accessor ~= 0 and symbol.flags & SymbolFlags.SetAccessor == 0 or
        symbol.flags & SymbolFlags.EnumMember ~= 0 or
        core.Some(symbol.declarations, function(d) return self:isReadonlyAssignmentDeclaration(d) end)
end

function Checker:checkObjectLiteralMethod(node, checkMode)
    -- Grammar checking
    self:checkGrammarMethod(node)
    -- Do not use hasDynamicName here, because that returns false for well known symbols.
    -- We want to perform checkComputedPropertyName for all computed properties, including
    -- well known symbols.
    if ast.IsComputedPropertyName(node:Name()) then
        self:checkComputedPropertyName(node:Name())
    end
    local uninstantiatedType = self:checkFunctionExpressionOrObjectLiteralMethod(node, checkMode)
    return self:instantiateTypeWithSingleGenericCallSignature(node, uninstantiatedType, checkMode)
end

function Checker:checkExpressionForMutableLocation(node, checkMode)
    local t = self:checkExpressionEx(node, checkMode)
    if self:isConstContext(node) then
        return self:getRegularTypeOfLiteralType(t)
    elseif checker.isTypeAssertion(node) then
        return t
    else
        return self:getWidenedLiteralLikeTypeForContextualType(t, self:instantiateContextualType(self:getContextualType(node, ContextFlags.None), node, ContextFlags.None))
    end
end

function Checker:getResolvedSymbol(node)
    local links = self.symbolNodeLinks:Get(node)
    if links.resolvedSymbol == nil then
        local symbol = nil
        if not ast.NodeIsMissing(node) then
            symbol = self.resolveName(node, node:Text(), SymbolFlags.Value | SymbolFlags.ExportValue,
                self:getCannotFindNameDiagnosticForName(node), not ast.IsWriteOnlyAccess(node), false --[[excludeGlobals]])
        end
        links.resolvedSymbol = core.OrElse(symbol, self.unknownSymbol)
    end
    return links.resolvedSymbol
end

function Checker:getResolvedSymbolOrNil(node)
    return self.symbolNodeLinks:Get(node).resolvedSymbol
end

function Checker:getReferencedValueOrAliasSymbol(reference)
    local resolvedSymbol = self.symbolNodeLinks:Get(reference).resolvedSymbol
    if resolvedSymbol ~= nil and resolvedSymbol ~= self.unknownSymbol then
        return resolvedSymbol
    end
    return self.resolveName(reference, reference:Text(), SymbolFlags.Value | SymbolFlags.ExportValue | SymbolFlags.Alias, nil, false --[[isUse]], false --[[excludeGlobals]])
end

local es2015OrLaterLibNames = {}
for _, name in ipairs({ "Map", "Set", "Promise", "ast.Symbol", "WeakMap", "WeakSet", "Iterator", "AsyncIterator", "SharedArrayBuffer", "Atomics", "AsyncIterable",
    "AsyncIterableIterator", "AsyncGenerator", "AsyncGeneratorFunction", "BigInt", "Reflect", "BigInt64Array", "BigUint64Array" }) do
    es2015OrLaterLibNames[name] = true
end

function Checker:getCannotFindNameDiagnosticForName(node)
    local text = node:Text()
    if text == "document" or text == "console" then
        return diagnostics.Cannot_find_name_0_Do_you_need_to_change_your_target_library_Try_changing_the_lib_compiler_option_to_include_dom
    elseif text == "$" then
        return core.IfElse(self.compilerOptions:UsesWildcardTypes(),
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_jQuery_Try_npm_i_save_dev_types_Slashjquery,
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_jQuery_Try_npm_i_save_dev_types_Slashjquery_and_then_add_jquery_to_the_types_field_in_your_tsconfig)
    elseif text == "beforeEach" or text == "describe" or text == "suite" or text == "it" or text == "test" then
        return core.IfElse(self.compilerOptions:UsesWildcardTypes(),
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_a_test_runner_Try_npm_i_save_dev_types_Slashjest_or_npm_i_save_dev_types_Slashmocha,
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_a_test_runner_Try_npm_i_save_dev_types_Slashjest_or_npm_i_save_dev_types_Slashmocha_and_then_add_jest_or_mocha_to_the_types_field_in_your_tsconfig)
    elseif text == "process" or text == "require" or text == "Buffer" or text == "module" or text == "NodeJS" then
        return core.IfElse(self.compilerOptions:UsesWildcardTypes(),
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_node_Try_npm_i_save_dev_types_Slashnode,
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_node_Try_npm_i_save_dev_types_Slashnode_and_then_add_node_to_the_types_field_in_your_tsconfig)
    elseif text == "Bun" then
        return core.IfElse(self.compilerOptions:UsesWildcardTypes(),
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_Bun_Try_npm_i_save_dev_types_Slashbun,
            diagnostics.Cannot_find_name_0_Do_you_need_to_install_type_definitions_for_Bun_Try_npm_i_save_dev_types_Slashbun_and_then_add_bun_to_the_types_field_in_your_tsconfig)
    elseif es2015OrLaterLibNames[text] then
        return diagnostics.Cannot_find_name_0_Do_you_need_to_change_your_target_library_Try_changing_the_lib_compiler_option_to_1_or_later
    end
    if text == "await" then
        if ast.IsCallExpression(node.parent) then
            return diagnostics.Cannot_find_name_0_Did_you_mean_to_write_this_in_an_async_function
        end
    end
    if node.parent.kind == Kind.ShorthandPropertyAssignment then
        return diagnostics.No_value_exists_in_scope_for_the_shorthand_property_0_Either_declare_one_or_provide_an_initializer
    end
    return diagnostics.Cannot_find_name_0
end

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

function Checker:combineSymbolTables(first, second)
    if first == nil or next(first) == nil then
        return second
    end
    if second == nil or next(second) == nil then
        return first
    end
    local combined = ast.NewSymbolTable()
    self:mergeSymbolTable(combined, first, false, nil)
    self:mergeSymbolTable(combined, second, false, nil)
    return combined
end

function Checker:mergeSymbolTable(target, source, unidirectional, mergedParent)
    for id, sourceSymbol in pairs(source or {}) do
        local targetSymbol = target[id]
        local merged
        if targetSymbol ~= nil then
            merged = self:mergeSymbol(targetSymbol, sourceSymbol, unidirectional)
        else
            merged = self:getMergedSymbol(sourceSymbol)
        end
        if mergedParent ~= nil and targetSymbol ~= nil then
            -- If a merge was performed on the target symbol, set its parent to the merged parent that initiated the merge
            -- of its exports. Otherwise, `merged` came only from `sourceSymbol` and can keep its parent:
            --
            -- // a.ts
            -- export interface A { x: number; }
            --
            -- // b.ts
            -- declare module "./a" {
            --   interface A { y: number; }
            --   interface B {}
            -- }
            --
            -- When merging the module augmentation into a.ts, the symbol for `A` will itself be merged, so its parent
            -- should be the merged module symbol. But the symbol for `B` has only one declaration, so its parent should
            -- be the module augmentation symbol, which contains its only declaration.
            if merged.flags & SymbolFlags.Transient ~= 0 then
                merged.parent = mergedParent
            end
        end
        target[id] = merged
    end
end

--
-- Note: if target is transient, then it is mutable, and mergeSymbol with both mutate and return it.
-- If target is not transient, mergeSymbol will produce a transient clone, mutate that and return it.
--
function Checker:mergeSymbol(target, source, unidirectional)
    if target.flags & checker.getExcludedSymbolFlags(source.flags) == 0 or (source.flags | target.flags) & SymbolFlags.Assignment ~= 0 then
        if source == target then
            -- This can happen when an export assigned namespace exports something also erroneously exported at the top level
            -- See `declarationFileNoCrashOnExtraExportModifier` for an example
            return target
        end
        if target.flags & SymbolFlags.Transient == 0 then
            local resolvedTarget = self:resolveSymbol(target)
            if resolvedTarget == self.unknownSymbol then
                return source
            end
            if resolvedTarget.flags & checker.getExcludedSymbolFlags(source.flags) == 0 or (source.flags | resolvedTarget.flags) & SymbolFlags.Assignment ~= 0 then
                target = self:cloneSymbol(resolvedTarget)
            else
                self:reportMergeSymbolError(target, source)
                return source
            end
        end
        -- Javascript static-property-assignment declarations always merge, even though they are also values
        if source.flags & SymbolFlags.ValueModule ~= 0 and target.flags & SymbolFlags.ValueModule ~= 0 and target.flags & SymbolFlags.ConstEnumOnlyModule ~= 0 and source.flags & SymbolFlags.ConstEnumOnlyModule == 0 then
            -- reset flag when merging instantiated module into value module that has only const enums
            target.flags = target.flags & ~SymbolFlags.ConstEnumOnlyModule
        end
        local sourceFlags = source.flags
        if target.flags & SymbolFlags.ConstEnumOnlyModule == 0 then
            sourceFlags = sourceFlags & ~SymbolFlags.ConstEnumOnlyModule
        end
        target.flags = target.flags | sourceFlags
        if source.valueDeclaration ~= nil then
            binder.SetValueDeclaration(target, source.valueDeclaration)
        end
        -- Go append: never mutate a (possibly shared) declarations array in place
        if core.Len(source.declarations) ~= 0 then
            target.declarations = core.AppendAll(core.Slice(target.declarations, 0), source.declarations)
        end
        if source.members ~= nil then
            self:mergeSymbolTable(ast.GetSymbolTable(target, "members"), source.members, unidirectional, nil)
        end
        if source.exports ~= nil then
            self:mergeSymbolTable(ast.GetSymbolTable(target, "exports"), source.exports, unidirectional, target)
        end
        if not unidirectional then
            self:recordMergedSymbol(target, source)
        end
    elseif target.flags & SymbolFlags.NamespaceModule ~= 0 then
        -- Do not report an error when merging `var globalThis` with the built-in `globalThis`,
        -- as we will already report a "Declaration name conflicts..." error, and this error
        -- won't make much sense.
        if target ~= self.globalThisSymbol then
            self:error(ast.GetNameOfDeclaration(checker.getFirstDeclaration(source)), diagnostics.Cannot_augment_module_0_with_value_exports_because_it_resolves_to_a_non_module_entity, self:symbolToString(target))
        end
    else
        self:reportMergeSymbolError(target, source)
    end
    return target
end

function Checker:reportMergeSymbolError(target, source)
    local isEitherEnum = target.flags & SymbolFlags.Enum ~= 0 or source.flags & SymbolFlags.Enum ~= 0
    local isEitherBlockScoped = target.flags & SymbolFlags.BlockScopedVariable ~= 0 or source.flags & SymbolFlags.BlockScopedVariable ~= 0
    local message
    if isEitherEnum then
        message = diagnostics.Enum_declarations_can_only_merge_with_namespace_or_other_enum_declarations
    elseif isEitherBlockScoped then
        message = diagnostics.Cannot_redeclare_block_scoped_variable_0
    else
        message = diagnostics.Duplicate_identifier_0
    end
    local sourceSymbolFile = ast.GetSourceFileOfNode(checker.getFirstDeclaration(source))
    local targetSymbolFile = ast.GetSourceFileOfNode(checker.getFirstDeclaration(target))
    local isSourcePlainJS = ast.IsPlainJSFile(sourceSymbolFile, self.compilerOptions.checkJs)
    local isTargetPlainJS = ast.IsPlainJSFile(targetSymbolFile, self.compilerOptions.checkJs)
    local symbolName = self:symbolToString(source)
    if not isSourcePlainJS then
        self:addDuplicateDeclarationErrorsForSymbols(source, message, symbolName, target)
    end
    if not isTargetPlainJS then
        self:addDuplicateDeclarationErrorsForSymbols(target, message, symbolName, source)
    end
end

function Checker:addDuplicateDeclarationErrorsForSymbols(target, message, symbolName, source)
    for _, node in ipairs(target.declarations or {}) do
        self:addDuplicateDeclarationError(node, message, symbolName, source.declarations)
    end
end

function Checker:addDuplicateDeclarationError(node, message, symbolName, relatedNodes)
    local errorNode = checker.getAdjustedNodeForError(node)
    if errorNode == nil then
        errorNode = node
    end
    local err = self:lookupOrIssueError(errorNode, message, symbolName)
    for _, relatedNode in ipairs(relatedNodes or {}) do
        local adjustedNode = checker.getAdjustedNodeForError(relatedNode)
        if adjustedNode == errorNode then
            goto continue
        end
        do
            local leadingMessage = checker.createDiagnosticForNode(adjustedNode, diagnostics.X_0_was_also_declared_here, symbolName)
            local followOnMessage = checker.createDiagnosticForNode(adjustedNode, diagnostics.X_and_here)
            if core.Len(err:RelatedInformation()) >= 5 or core.Some(err:RelatedInformation(), function(d)
                return ast.CompareDiagnostics(d, followOnMessage) == 0 or ast.CompareDiagnostics(d, leadingMessage) == 0
            end) then
                goto continue
            end
            if core.Len(err:RelatedInformation()) == 0 then
                err:AddRelatedInfo(leadingMessage)
            else
                err:AddRelatedInfo(followOnMessage)
            end
        end
        ::continue::
    end
end
