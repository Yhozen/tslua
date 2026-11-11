local checker = require("tslua.checker")
local ast = require("tslua.ast")
local collections = require("tslua.collections") -- luacheck: ignore
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local evaluator = require("tslua.evaluator")
local jsnum = require("tslua.jsnum") -- luacheck: ignore
local debug = require("tslua.debug") -- luacheck: ignore
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

local Checker = checker.Checker
local defineStruct = checker.defineStruct
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local SignatureFlags = checker.SignatureFlags
local SymbolFlags = ast.SymbolFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local Tristate = core.Tristate
local CheckMode = checker.CheckMode
local TypeFacts = checker.TypeFacts
local SignatureKind = checker.SignatureKind
local FunctionFlags = ast.FunctionFlags
local MemberOverrideStatus = checker.MemberOverrideStatus
local ExternalEmitHelpers = checker.ExternalEmitHelpers
local ModuleKind = core.ModuleKind
local ReferenceHint = checker.ReferenceHint
local IterationUse = checker.IterationUse
local IterationTypeKind = checker.IterationTypeKind
local UnionReduction = checker.UnionReduction

function Checker:checkFunctionOrConstructorSymbolWorker(symbol)
    local flagsToCheck = ModifierFlags.Export | ModifierFlags.Ambient | ModifierFlags.Private | ModifierFlags.Protected | ModifierFlags.Abstract
    local someNodeFlags = ModifierFlags.None
    local allNodeFlags = flagsToCheck
    local someHaveQuestionToken = false
    local allHaveQuestionToken = true
    local hasOverloads = false
    local bodyDeclaration
    local lastSeenNonAmbientDeclaration
    local previousDeclaration
    local declarations = symbol.declarations
    local isConstructor = symbol.flags & SymbolFlags.Constructor ~= 0
    local duplicateFunctionDeclaration = false
    local multipleConstructorImplementation = false
    local hasNonAmbientClass = false
    local functionDeclarations = {}
    local function getCanonicalOverload(overloads, implementation)
        -- Consider the canonical set of flags to be the flags of the bodyDeclaration or the first declaration
        -- Error on all deviations from this canonical set of flags
        -- The caveat is that if some overloads are defined in lib.d.ts, we don't want to
        -- report the errors on those. To achieve this, we will say that the implementation is
        -- the canonical signature only if it is in the same container as the first overload
        local implementationSharesContainerWithFirstOverload = implementation ~= nil and implementation.parent == overloads[1].parent
        if implementationSharesContainerWithFirstOverload then
            return implementation
        end
        return overloads[1]
    end
    local function checkFlagAgreementBetweenOverloads(overloads, implementation, flagsToCheck_, someOverloadFlags, allOverloadFlags)
        -- Error if some overloads have a flag that is not shared by all overloads. To find the
        -- deviations, we XOR someOverloadFlags with allOverloadFlags
        local someButNotAllOverloadFlags = someOverloadFlags ~ allOverloadFlags
        if someButNotAllOverloadFlags ~= 0 then
            local canonicalFlags = self:getEffectiveDeclarationFlags(getCanonicalOverload(overloads, implementation), flagsToCheck_)
            -- Go iterates a map keyed by source file; iterate in first-seen order for determinism.
            local groups = {}
            local groupOrder = {}
            for _, overload in ipairs(overloads) do
                local sourceFile = ast.GetSourceFileOfNode(overload)
                local g = groups[sourceFile]
                if g == nil then
                    g = {}
                    groups[sourceFile] = g
                    groupOrder[#groupOrder + 1] = sourceFile
                end
                g[#g + 1] = overload
            end
            for _, sourceFile in ipairs(groupOrder) do
                local overloadsInFile = groups[sourceFile]
                local canonicalFlagsForFile = self:getEffectiveDeclarationFlags(getCanonicalOverload(overloadsInFile, implementation), flagsToCheck_)
                for _, overload in ipairs(overloadsInFile) do
                    local deviation = self:getEffectiveDeclarationFlags(overload, flagsToCheck_) ~ canonicalFlags
                    local deviationInFile = self:getEffectiveDeclarationFlags(overload, flagsToCheck_) ~ canonicalFlagsForFile
                    if deviationInFile & ModifierFlags.Export ~= 0 then
                        -- Overloads in different files need not all have export modifiers. This is ok:
                        --   // lib.d.ts
                        --   declare function foo(s: number): string;
                        --   declare function foo(s: string): number;
                        --   export { foo };
                        --
                        --   // app.ts
                        --   declare module "lib" {
                        --     export function foo(s: boolean): boolean;
                        --   }
                        self:error(ast.GetNameOfDeclaration(overload), diagnostics.Overload_signatures_must_all_be_exported_or_non_exported)
                    elseif deviationInFile & ModifierFlags.Ambient ~= 0 then
                        -- Though rare, a module augmentation (necessarily ambient) is allowed to add overloads
                        -- to a non-ambient function in an implementation file.
                        self:error(ast.GetNameOfDeclaration(overload), diagnostics.Overload_signatures_must_all_be_ambient_or_non_ambient)
                    elseif deviation & (ModifierFlags.Private | ModifierFlags.Protected) ~= 0 then
                        self:error(ast.GetNameOfDeclaration(overload) or overload, diagnostics.Overload_signatures_must_all_be_public_private_or_protected)
                    elseif deviation & ModifierFlags.Abstract ~= 0 then
                        self:error(ast.GetNameOfDeclaration(overload), diagnostics.Overload_signatures_must_all_be_abstract_or_non_abstract)
                    end
                end
            end
        end
    end
    local function checkQuestionTokenAgreementBetweenOverloads(overloads, implementation, someHaveQuestionToken_, allHaveQuestionToken_)
        if someHaveQuestionToken_ ~= allHaveQuestionToken_ then
            local canonicalHasQuestionToken = checker.isOptionalDeclaration(getCanonicalOverload(overloads, implementation))
            for _, o in ipairs(overloads) do
                if checker.isOptionalDeclaration(o) ~= canonicalHasQuestionToken then
                    self:error(ast.GetNameOfDeclaration(o), diagnostics.Overload_signatures_must_all_be_optional_or_required)
                end
            end
        end
    end
    local function reportImplementationExpectedError(node)
        local name = node:Name()
        if name ~= nil and ast.NodeIsMissing(name) then
            return
        end
        local seen = false
        local subsequentNode
        node.parent:ForEachChild(function(child)
            if seen then
                subsequentNode = child
                return true
            end
            seen = child == node
            return false
        end)
        -- We may be here because of some extra nodes between overloads that could not be parsed into a valid node.
        -- In this case the subsequent node is not really consecutive (.pos !== node.end), and we must ignore it here.
        if subsequentNode ~= nil and subsequentNode:Pos() == node:End() then
            if subsequentNode.kind == node.kind then
                local subsequentName = subsequentNode:Name()
                local errorNode = subsequentName or subsequentNode
                if name ~= nil and subsequentName ~= nil and
                    (ast.IsPrivateIdentifier(name) and ast.IsPrivateIdentifier(subsequentName) and name:Text() == subsequentName:Text() or
                        ast.IsComputedPropertyName(name) and ast.IsComputedPropertyName(subsequentName) and self:isTypeIdenticalTo(self:checkComputedPropertyName(name), self:checkComputedPropertyName(subsequentName)) or
                        ast.IsPropertyNameLiteral(name) and ast.IsPropertyNameLiteral(subsequentName) and name:Text() == subsequentName:Text()) then
                    local reportError = (ast.IsMethodDeclaration(node) or ast.IsMethodSignatureDeclaration(node)) and ast.IsStatic(node) ~= ast.IsStatic(subsequentNode)
                    -- we can get here in two cases
                    -- 1. mixed static and instance class members
                    -- 2. something with the same name was defined before the set of overloads that prevents them from merging
                    -- here we'll report error only for the first case since for second we should already report error in binder
                    if reportError then
                        local diagnostic = core.IfElse(ast.IsStatic(node), diagnostics.Function_overload_must_be_static, diagnostics.Function_overload_must_not_be_static)
                        self:error(errorNode, diagnostic)
                    end
                    return
                end
                if ast.NodeIsPresent(subsequentNode:Body()) then
                    self:error(errorNode, diagnostics.Function_implementation_name_must_be_0, scanner.DeclarationNameToString(name))
                    return
                end
            end
        end
        local errorNode = name or node
        if isConstructor then
            self:error(errorNode, diagnostics.Constructor_implementation_is_missing)
        else
            -- Report different errors regarding non-consecutive blocks of declarations depending on whether
            -- the node in question is abstract.
            if ast.HasSyntacticModifier(node, ModifierFlags.Abstract) then
                self:error(errorNode, diagnostics.All_declarations_of_an_abstract_method_must_be_consecutive)
            else
                self:error(errorNode, diagnostics.Function_implementation_is_missing_or_not_immediately_following_the_declaration)
            end
        end
    end
    for _, node in ipairs(declarations or {}) do
        local inAmbientContext = node.flags & NodeFlags.Ambient ~= 0
        local inAmbientContextOrInterface = inAmbientContext or node.parent ~= nil and (ast.IsInterfaceDeclaration(node.parent) or ast.IsTypeLiteralNode(node.parent))
        if inAmbientContextOrInterface then
            -- check if declarations are consecutive only if they are non-ambient
            -- 1. ambient declarations can be interleaved
            -- i.e. this is legal
            --     declare function foo();
            --     declare function bar();
            --     declare function foo();
            -- 2. mixing ambient and non-ambient declarations is a separate error that will be reported - do not want to report an extra one
            previousDeclaration = nil
        end
        if ast.IsClassLike(node) and not inAmbientContext then
            hasNonAmbientClass = true
        end
        if ast.IsFunctionDeclaration(node) or ast.IsMethodDeclaration(node) or ast.IsMethodSignatureDeclaration(node) or ast.IsConstructorDeclaration(node) then
            functionDeclarations[#functionDeclarations + 1] = node
            local currentNodeFlags = self:getEffectiveDeclarationFlags(node, flagsToCheck)
            someNodeFlags = someNodeFlags | currentNodeFlags
            allNodeFlags = allNodeFlags & currentNodeFlags
            someHaveQuestionToken = someHaveQuestionToken or checker.isOptionalDeclaration(node)
            allHaveQuestionToken = allHaveQuestionToken and checker.isOptionalDeclaration(node)
            local bodyIsPresent = ast.NodeIsPresent(node:Body())
            if bodyIsPresent and bodyDeclaration ~= nil then
                if isConstructor then
                    multipleConstructorImplementation = true
                else
                    duplicateFunctionDeclaration = true
                end
            elseif previousDeclaration ~= nil and previousDeclaration.parent == node.parent and previousDeclaration:End() ~= node:Pos() and previousDeclaration.flags & NodeFlags.Reparsed == 0 then
                reportImplementationExpectedError(previousDeclaration)
            end
            if bodyIsPresent then
                if bodyDeclaration == nil then
                    bodyDeclaration = node
                end
            else
                hasOverloads = true
            end
            previousDeclaration = node
            if not inAmbientContextOrInterface then
                lastSeenNonAmbientDeclaration = node
            end
        end
    end
    if multipleConstructorImplementation then
        for _, declaration in ipairs(functionDeclarations) do
            self:error(declaration, diagnostics.Multiple_constructor_implementations_are_not_allowed)
        end
    end
    if duplicateFunctionDeclaration then
        for _, declaration in ipairs(functionDeclarations) do
            self:error(ast.GetNameOfDeclaration(declaration) or declaration, diagnostics.Duplicate_function_implementation)
        end
    end
    if hasNonAmbientClass and not isConstructor and symbol.flags & SymbolFlags.Function ~= 0 and core.Len(declarations) ~= 0 then
        local relatedDiagnostics
        for _, declaration in ipairs(declarations) do
            if ast.IsClassDeclaration(declaration) then
                relatedDiagnostics = core.Append(relatedDiagnostics, checker.createDiagnosticForNode(declaration, diagnostics.Consider_adding_a_declare_modifier_to_this_class))
            end
        end
        for _, declaration in ipairs(declarations) do
            local diagnostic
            if declaration.kind == Kind.ClassDeclaration then
                diagnostic = diagnostics.Class_declaration_cannot_implement_overload_list_for_0
            elseif declaration.kind == Kind.FunctionDeclaration then
                diagnostic = diagnostics.Function_with_bodies_can_only_merge_with_classes_that_are_ambient
            end
            if diagnostic ~= nil then
                self:error(ast.GetNameOfDeclaration(declaration) or declaration, diagnostic, symbol.name):SetRelatedInfo(relatedDiagnostics)
            end
        end
    end
    -- Abstract methods can't have an implementation -- in particular, they don't need one.
    if lastSeenNonAmbientDeclaration ~= nil and lastSeenNonAmbientDeclaration:Body() == nil and not ast.HasSyntacticModifier(lastSeenNonAmbientDeclaration, ModifierFlags.Abstract) and not checker.isOptionalDeclaration(lastSeenNonAmbientDeclaration) then
        reportImplementationExpectedError(lastSeenNonAmbientDeclaration)
    end
    if hasOverloads then
        checkFlagAgreementBetweenOverloads(declarations, bodyDeclaration, flagsToCheck, someNodeFlags, allNodeFlags)
        checkQuestionTokenAgreementBetweenOverloads(declarations, bodyDeclaration, someHaveQuestionToken, allHaveQuestionToken)
        if bodyDeclaration ~= nil then
            local signatures = self:getSignaturesOfSymbol(symbol)
            local bodySignature = self:getSignatureFromDeclaration(bodyDeclaration)
            for _, signature in ipairs(signatures or {}) do
                if not self:isImplementationCompatibleWithOverload(bodySignature, signature) then
                    local errorNode = signature.declaration
                    self:error(errorNode, diagnostics.This_overload_signature_is_not_compatible_with_its_implementation_signature):AddRelatedInfo(checker.createDiagnosticForNode(bodyDeclaration, diagnostics.The_implementation_signature_is_declared_here))
                    break
                end
            end
        end
    end
end

function Checker:getEffectiveDeclarationFlags(n, flagsToCheck)
    local flags = self:getCombinedModifierFlagsCached(n)
    -- children of classes (even ambient classes) should not be marked as ambient or export
    -- because those flags have no useful semantics there.
    if not ast.IsInterfaceDeclaration(n.parent) and not ast.IsClassDeclaration(n.parent) and not ast.IsClassExpression(n.parent) and n.flags & NodeFlags.Ambient ~= 0 then
        local container = checker.getEnclosingContainer(n)
        if container ~= nil and container.flags & NodeFlags.ExportContext ~= 0 and flags & ModifierFlags.Ambient == 0 and not (ast.IsModuleBlock(n.parent) and ast.IsGlobalScopeAugmentation(n.parent.parent)) then
            -- It is nested in an ambient export context, which means it is automatically exported
            flags = flags | ModifierFlags.Export
        end
        flags = flags | ModifierFlags.Ambient
    end
    return flags & flagsToCheck
end

function Checker:isImplementationCompatibleWithOverload(implementation, overload)
    local erasedSource = self:getErasedSignature(implementation)
    local erasedTarget = self:getErasedSignature(overload)
    -- First see if the return types are compatible in either direction.
    local sourceReturnType = self:getReturnTypeOfSignature(erasedSource)
    local targetReturnType = self:getReturnTypeOfSignature(erasedTarget)
    if targetReturnType == self.voidType or self:isTypeRelatedTo(targetReturnType, sourceReturnType, self.assignableRelation) or self:isTypeRelatedTo(sourceReturnType, targetReturnType, self.assignableRelation) then
        return self:isSignatureAssignableTo(erasedSource, erasedTarget, true --[[ignoreReturnTypes]])
    end
    return false
end

function Checker:checkAllCodePathsInNonVoidFunctionReturnOrThrow(fn, returnType)
    local functionFlags = ast.GetFunctionFlags(fn)
    local t
    if returnType ~= nil then
        t = self:unwrapReturnType(returnType, functionFlags)
    end
    -- Functions with an explicitly specified return type that includes `void` or is exactly `any` or `undefined` don't
    -- need any return statements.
    if t ~= nil and (self:maybeTypeOfKind(t, TypeFlags.Void) or t.flags & (TypeFlags.Any | TypeFlags.Undefined) ~= 0) then
        return
    end
    -- If all we have is a function signature, or an arrow function with an expression body, then there is nothing to check.
    -- also if HasImplicitReturn flag is not set this means that all codepaths in function body end with return or throw
    if ast.IsMethodSignatureDeclaration(fn) or ast.NodeIsMissing(fn:Body()) or not ast.IsBlock(fn:Body()) or not self:functionHasImplicitReturn(fn) then
        return
    end
    local hasExplicitReturn = fn.flags & NodeFlags.HasExplicitReturn ~= 0
    local errorNode = fn:Type()
    if errorNode == nil then
        local data = fn:FunctionLikeData()
        if data ~= nil and data.fullSignature ~= nil then
            errorNode = data.fullSignature
        end
    end
    if errorNode == nil then
        errorNode = fn
    end
    if t ~= nil and t.flags & TypeFlags.Never ~= 0 then
        self:error(errorNode, diagnostics.A_function_returning_never_cannot_have_a_reachable_end_point)
    elseif t ~= nil and not hasExplicitReturn then
        -- minimal check: function has syntactic return type annotation and no explicit return statements in the body
        -- this function does not conform to the specification.
        self:error(errorNode, diagnostics.A_function_whose_declared_type_is_neither_undefined_void_nor_any_must_return_a_value)
    elseif t ~= nil and self.strictNullChecks and not self:isTypeAssignableTo(self.undefinedType, t) then
        self:error(errorNode, diagnostics.Function_lacks_ending_return_statement_and_return_type_does_not_include_undefined)
    elseif self.compilerOptions.noImplicitReturns == Tristate.TSTrue then
        if t == nil then
            -- If return type annotation is omitted check if function has any explicit return statements.
            -- If it does not have any - its inferred return type is void - don't do any checks.
            -- Otherwise get inferred return type from function body and report error only if it is not void / anytype
            if not hasExplicitReturn then
                return
            end
            local inferredReturnType = self:getReturnTypeOfSignature(self:getSignatureFromDeclaration(fn))
            if self:isUnwrappedReturnTypeUndefinedVoidOrAny(fn, inferredReturnType) then
                return
            end
        end
        self:error(errorNode, diagnostics.Not_all_code_paths_return_a_value)
    end
end

function Checker:isUnwrappedReturnTypeUndefinedVoidOrAny(fn, returnType)
    local t = self:unwrapReturnType(returnType, ast.GetFunctionFlags(fn))
    return t ~= nil and (self:maybeTypeOfKind(t, TypeFlags.Void) or t.flags & (TypeFlags.Any | TypeFlags.Undefined) ~= 0)
end

function Checker:checkBlock(node)
    -- Grammar checking for SyntaxKind.Block
    if node.kind == Kind.Block then
        self:checkGrammarStatementInAmbientContext(node)
    end
    if ast.IsFunctionOrModuleBlock(node) then
        local saveFlowAnalysisDisabled = self.flowAnalysisDisabled
        self:checkSourceElements(node:Statements())
        self.flowAnalysisDisabled = saveFlowAnalysisDisabled
    else
        self:checkSourceElements(node:Statements())
    end
    if next(node:Locals() or {}) ~= nil then
        self:registerForUnusedIdentifiersCheck(node)
    end
end

function Checker:checkIfStatement(node)
    self:checkGrammarStatementInAmbientContext(node)
    local t = self:checkTruthinessExpression(node:Expression(), CheckMode.Normal)
    local data = node:AsIfStatement()
    self:checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType(node:Expression(), t, data.thenStatement)
    self:checkSourceElement(data.thenStatement)
    if ast.IsEmptyStatement(data.thenStatement) then
        self:error(data.thenStatement, diagnostics.The_body_of_an_if_statement_cannot_be_the_empty_statement)
    end
    self:checkSourceElement(data.elseStatement)
end

function Checker:checkTestingKnownTruthyCallableOrAwaitableOrEnumMemberType(condExpr, condType, body)
    if not self.strictNullChecks then
        return
    end
    self:checkTestingKnownTruthyTypes(condExpr, condType, body)
end

function Checker:checkTestingKnownTruthyTypes(condExpr, condType, body)
    condExpr = ast.SkipParentheses(condExpr)
    self:checkTestingKnownTruthyType(condExpr, condType, body)
    while ast.IsBinaryExpression(condExpr) and (condExpr:AsBinaryExpression().operatorToken.kind == Kind.BarBarToken or condExpr:AsBinaryExpression().operatorToken.kind == Kind.QuestionQuestionToken) do
        condExpr = ast.SkipParentheses(condExpr:AsBinaryExpression().left)
        self:checkTestingKnownTruthyType(condExpr, condType, body)
    end
end

function Checker:checkTestingKnownTruthyType(condExpr, condType, body)
    local location = condExpr
    if ast.IsLogicalOrCoalescingBinaryExpression(condExpr) then
        location = ast.SkipParentheses(condExpr:AsBinaryExpression().right)
    end
    if ast.IsModuleExportsAccessExpression(location) then
        return
    end
    if ast.IsLogicalOrCoalescingBinaryExpression(location) then
        self:checkTestingKnownTruthyTypes(location, condType, body)
        return
    end
    local t = condType
    if location ~= condExpr then
        t = self:checkExpression(location)
    end
    if t.flags & TypeFlags.EnumLiteral ~= 0 and ast.IsPropertyAccessExpression(location) and (self:getResolvedSymbolOrNil(location:Expression()) or self.unknownSymbol).flags & SymbolFlags.Enum ~= 0 then
        -- EnumLiteral type at condition with known value is always truthy or always falsy, likely an error
        self:error(location, diagnostics.This_condition_will_always_return_0, core.IfElse(evaluator.IsTruthy(t:AsLiteralType().value), "true", "false"))
        return
    end
    local isPropertyExpressionCast = ast.IsPropertyAccessExpression(location) and checker.isTypeAssertion(location:Expression())
    if not self:hasTypeFacts(t, TypeFacts.Truthy) or isPropertyExpressionCast then
        return
    end
    -- While it technically should be invalid for any known-truthy value
    -- to be tested, we de-scope to functions and Promises unreferenced in
    -- the block as a heuristic to identify the most common bugs. There
    -- are too many false positives for values sourced from type
    -- definitions without strictNullChecks otherwise.
    local callSignatures = self:getSignaturesOfType(t, SignatureKind.Call)
    local isPromise = self:getAwaitedTypeOfPromise(t) ~= nil
    if core.Len(callSignatures) == 0 and not isPromise then
        return
    end
    local testedNode
    if ast.IsIdentifier(location) then
        testedNode = location
    elseif ast.IsPropertyAccessExpression(location) then
        testedNode = location:Name()
    end
    local testedSymbol
    if testedNode ~= nil then
        testedSymbol = self:getSymbolAtLocation(testedNode, false)
    end
    if testedSymbol == nil and not isPromise then
        return
    end
    local isUsed = testedSymbol ~= nil and ast.IsBinaryExpression(condExpr.parent) and self:isSymbolUsedInBinaryExpressionChain(condExpr.parent, testedSymbol) or
        testedSymbol ~= nil and body ~= nil and self:isSymbolUsedInConditionBody(condExpr, body, testedNode, testedSymbol)
    if not isUsed then
        if isPromise then
            self:errorAndMaybeSuggestAwait(location, true, diagnostics.This_condition_will_always_return_true_since_this_0_is_always_defined, self:getTypeNameForErrorDisplay(t))
        else
            self:error(location, diagnostics.This_condition_will_always_return_true_since_this_function_is_always_defined_Did_you_mean_to_call_it_instead)
        end
    end
end

function Checker:isSymbolUsedInBinaryExpressionChain(node, testedSymbol)
    local visit
    visit = function(child)
        if ast.IsIdentifier(child) then
            local symbol = self:getSymbolAtLocation(child, false)
            if symbol ~= nil and symbol == testedSymbol then
                return true
            end
        end
        return child:ForEachChild(visit)
    end
    while ast.IsBinaryExpression(node) and node:AsBinaryExpression().operatorToken.kind == Kind.AmpersandAmpersandToken do
        local isUsed = node:AsBinaryExpression().right:ForEachChild(visit)
        if isUsed then
            return true
        end
        node = node.parent
    end
    return false
end

function Checker:isSymbolUsedInConditionBody(expr, body, testedNode, testedSymbol)
    local visit
    visit = function(childNode)
        if ast.IsIdentifier(childNode) then
            local childSymbol = self:getSymbolAtLocation(childNode, false)
            if childSymbol ~= nil and childSymbol == testedSymbol then
                -- If the test was a simple identifier, the above check is sufficient
                if ast.IsIdentifier(expr) or ast.IsIdentifier(testedNode) and ast.IsBinaryExpression(testedNode.parent) then
                    return true
                end
                -- Otherwise we need to ensure the symbol is called on the same target
                local testedExpression = testedNode.parent
                local childExpression = childNode.parent
                while testedExpression ~= nil and childExpression ~= nil do
                    if ast.IsIdentifier(testedExpression) and ast.IsIdentifier(childExpression) or testedExpression.kind == Kind.ThisKeyword and childExpression.kind == Kind.ThisKeyword then
                        return self:getSymbolAtLocation(testedExpression, false) == self:getSymbolAtLocation(childExpression, false)
                    elseif ast.IsPropertyAccessExpression(testedExpression) and ast.IsPropertyAccessExpression(childExpression) then
                        if self:getSymbolAtLocation(testedExpression:Name(), false) ~= self:getSymbolAtLocation(childExpression:Name(), false) then
                            return false
                        end
                        childExpression = childExpression:Expression()
                        testedExpression = testedExpression:Expression()
                    elseif ast.IsCallExpression(testedExpression) and ast.IsCallExpression(childExpression) then
                        childExpression = childExpression:Expression()
                        testedExpression = testedExpression:Expression()
                    else
                        return false
                    end
                end
            end
        end
        return childNode:ForEachChild(visit)
    end
    return body:ForEachChild(visit)
end

function Checker:checkDoStatement(node)
    self:checkGrammarStatementInAmbientContext(node)
    self:checkSourceElement(node:Statement())
    self:checkTruthinessExpression(node:Expression(), CheckMode.Normal)
end

function Checker:checkWhileStatement(node)
    self:checkGrammarStatementInAmbientContext(node)
    self:checkTruthinessExpression(node:Expression(), CheckMode.Normal)
    self:checkSourceElement(node:Statement())
end

function Checker:checkForStatement(node)
    if not self:checkGrammarStatementInAmbientContext(node) then
        local init = node:Initializer()
        if init ~= nil and init.kind == Kind.VariableDeclarationList then
            self:checkGrammarVariableDeclarationList(init:AsVariableDeclarationList())
        end
    end
    local data = node:AsForStatement()
    if data.initializer ~= nil then
        if ast.IsVariableDeclarationList(data.initializer) then
            self:checkVariableDeclarationList(data.initializer)
        else
            self:checkExpression(data.initializer)
        end
    end
    if data.condition ~= nil then
        self:checkTruthinessExpression(data.condition, CheckMode.Normal)
    end
    if data.incrementor ~= nil then
        self:checkExpression(data.incrementor)
    end
    self:checkSourceElement(data.statement)
    if node:Locals() ~= nil then
        self:registerForUnusedIdentifiersCheck(node)
    end
end

function Checker:checkForInStatement(node)
    local data = node:AsForInOrOfStatement()
    self:checkGrammarForInOrForOfStatement(data)
    local rightType = self:getNonNullableTypeIfNeeded(self:checkExpression(data.expression))
    -- TypeScript 1.0 spec (April 2014): 5.4
    -- In a 'for-in' statement of the form
    -- for (let VarDecl in Expr) Statement
    --   VarDecl must be a variable declaration without a type annotation that declares a variable of type Any,
    --   and Expr must be an expression of type Any, an object type, or a type parameter type.
    if ast.IsVariableDeclarationList(data.initializer) then
        local declarations = data.initializer:AsVariableDeclarationList().declarations.nodes
        if #declarations ~= 0 and ast.IsBindingPattern(declarations[1]:Name()) then
            self:error(declarations[1]:Name(), diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_be_a_destructuring_pattern)
        end
        self:checkVariableDeclarationList(data.initializer)
    else
        -- In a 'for-in' statement of the form
        -- for (Var in Expr) Statement
        --   Var must be an expression classified as a reference of type Any or the String primitive type,
        --   and Expr must be an expression of type Any, an object type, or a type parameter type.
        local varExpr = data.initializer
        local leftType = self:checkExpression(varExpr)
        if ast.IsArrayLiteralExpression(varExpr) or ast.IsObjectLiteralExpression(varExpr) then
            self:error(varExpr, diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_be_a_destructuring_pattern)
        elseif not self:isTypeAssignableTo(self:getIndexTypeOrString(rightType), leftType) then
            self:error(varExpr, diagnostics.The_left_hand_side_of_a_for_in_statement_must_be_of_type_string_or_any)
        else
            -- run check only former check succeeded to avoid cascading errors
            self:checkReferenceExpression(varExpr, diagnostics.The_left_hand_side_of_a_for_in_statement_must_be_a_variable_or_a_property_access, diagnostics.The_left_hand_side_of_a_for_in_statement_may_not_be_an_optional_property_access)
        end
    end
    -- unknownType is returned i.e. if node.expression is identifier whose name cannot be resolved
    -- in this case error about missing name is already reported - do not report extra one
    if rightType == self.neverType or not self:isTypeAssignableToKind(rightType, TypeFlags.NonPrimitive | TypeFlags.InstantiableNonPrimitive) then
        self:error(data.expression, diagnostics.The_right_hand_side_of_a_for_in_statement_must_be_of_type_any_an_object_type_or_a_type_parameter_but_here_has_type_0, self:TypeToString(rightType))
    end
    self:checkSourceElement(data.statement)
    if node:Locals() ~= nil then
        self:registerForUnusedIdentifiersCheck(node)
    end
end

function Checker:getIndexTypeOrString(t)
    local indexType = self:getExtractStringType(self:getIndexType(t))
    return core.IfElse(indexType.flags & TypeFlags.Never ~= 0, self.stringType, indexType)
end

function Checker:checkForOfStatement(node)
    local data = node:AsForInOrOfStatement()
    self:checkGrammarForInOrForOfStatement(data)
    local container = checker.getContainingFunctionOrClassStaticBlock(node)
    if data.awaitModifier ~= nil then
        if container ~= nil and ast.IsClassStaticBlockDeclaration(container) then
            self:grammarErrorOnNode(data.awaitModifier, diagnostics.X_for_await_loops_cannot_be_used_inside_a_class_static_block)
        else
            local functionFlags = ast.GetFunctionFlags(container)
            if functionFlags & (FunctionFlags.Invalid | FunctionFlags.Async) == FunctionFlags.Async and self.languageVersion < checker.LanguageFeatureMinimumTarget.ForAwaitOf then
                -- for..await..of in an async function or async generator function prior to ESNext requires the __asyncValues helper
                self:checkExternalEmitHelpers(node, checker.ExternalEmitHelpers.ForAwaitOfIncludes)
            end
        end
    end -- Check the LHS and RHS
    -- If the LHS is a declaration, just check it as a variable declaration, which will in turn check the RHS
    -- via checkRightHandSideOfForOf.
    -- If the LHS is an expression, check the LHS, as a destructuring assignment or as a reference.
    -- Then check that the RHS is assignable to it.
    if ast.IsVariableDeclarationList(data.initializer) then
        self:checkVariableDeclarationList(data.initializer)
    else
        local varExpr = data.initializer
        local iteratedType = self:checkRightHandSideOfForOf(node)
        -- There may be a destructuring assignment on the left side
        if ast.IsArrayLiteralExpression(varExpr) or ast.IsObjectLiteralExpression(varExpr) then
            -- iteratedType may be undefined. In this case, we still want to check the structure of
            -- varExpr, in particular making sure it's a valid LeftHandSideExpression. But we'd like
            -- to short circuit the type relation checking as much as possible, so we pass the unknownType.
            self:checkDestructuringAssignment(varExpr, iteratedType or self.errorType, CheckMode.Normal, false)
        else
            local leftType = self:checkExpression(varExpr)
            self:checkReferenceExpression(varExpr, diagnostics.The_left_hand_side_of_a_for_of_statement_must_be_a_variable_or_a_property_access, diagnostics.The_left_hand_side_of_a_for_of_statement_may_not_be_an_optional_property_access)
            -- iteratedType will be undefined if the rightType was missing properties/signatures
            -- required to get its iteratedType (like [Symbol.iterator] or next). This may be
            -- because we accessed properties from anyType, or it may have led to an error inside
            -- getElementTypeOfIterable.
            if iteratedType ~= nil then
                self:checkTypeAssignableToAndOptionallyElaborate(iteratedType, leftType, varExpr, data.expression, nil, nil)
            end
        end
    end
    self:checkSourceElement(data.statement)
    if node:Locals() ~= nil then
        self:registerForUnusedIdentifiersCheck(node)
    end
end

function Checker:checkBreakOrContinueStatement(node)
    if not self:checkGrammarStatementInAmbientContext(node) then
        self:checkGrammarBreakOrContinueStatement(node)
    end
end

function Checker:checkReturnStatement(node)
    -- Always check the return expression so its identifiers are resolved even when the
    -- return statement is misplaced (grammar error), keeping diagnostics stable
    -- regardless of traversal order.
    local exprNode = node:Expression()
    local exprType = self.undefinedType
    if exprNode ~= nil then
        exprType = self:checkExpressionCached(exprNode)
    end
    if self:checkGrammarStatementInAmbientContext(node) then
        return
    end
    local container = checker.getContainingFunctionOrClassStaticBlock(node)
    if container ~= nil and ast.IsClassStaticBlockDeclaration(container) then
        self:grammarErrorOnFirstToken(node, diagnostics.A_return_statement_cannot_be_used_inside_a_class_static_block)
        return
    end
    if container == nil then
        self:grammarErrorOnFirstToken(node, diagnostics.A_return_statement_can_only_be_used_within_a_function_body)
        return
    end
    local signature = self:getSignatureFromDeclaration(container)
    local returnType = self:getReturnTypeOfSignature(signature)
    local functionFlags = ast.GetFunctionFlags(container)
    if self.strictNullChecks or exprNode ~= nil or returnType.flags & TypeFlags.Never ~= 0 then
        if ast.IsSetAccessorDeclaration(container) then
            if exprNode ~= nil then
                self:error(node, diagnostics.Setters_cannot_return_a_value)
            end
        elseif ast.IsConstructorDeclaration(container) then
            if exprNode ~= nil and not self:checkTypeAssignableToAndOptionallyElaborate(exprType, returnType, node, exprNode, nil, nil) then
                self:error(node, diagnostics.Return_type_of_constructor_signature_must_be_assignable_to_the_instance_type_of_the_class)
            end
        elseif self:getReturnTypeFromAnnotation(container) ~= nil then
            local unwrappedReturnType = self:unwrapReturnType(returnType, functionFlags) or returnType
            self:checkReturnExpression(container, unwrappedReturnType, node, node:Expression(), exprType, false)
        end
    elseif not ast.IsConstructorDeclaration(container) and core.Tristate_IsTrue(self.compilerOptions.noImplicitReturns) and not self:isUnwrappedReturnTypeUndefinedVoidOrAny(container, returnType) then
        -- The function has a return type, but the return statement doesn't have an expression.
        self:error(node, diagnostics.Not_all_code_paths_return_a_value)
    end
end

-- When checking an arrow expression such as `(x) => exp`, then `node` is the expression `exp`.
-- Otherwise, `node` is a return statement.
function Checker:checkReturnExpression(container, unwrappedReturnType, node, expr, exprType, inConditionalExpression)
    local unwrappedExprType = exprType
    local functionFlags = ast.GetFunctionFlags(container)
    if expr ~= nil then
        local unwrappedExpr = ast.SkipParentheses(expr)
        if ast.IsConditionalExpression(unwrappedExpr) then
            local whenTrue = unwrappedExpr:AsConditionalExpression().whenTrue
            local whenFalse = unwrappedExpr:AsConditionalExpression().whenFalse
            self:checkReturnExpression(container, unwrappedReturnType, node, whenTrue, self:checkExpression(whenTrue), true --[[inConditionalExpression]])
            self:checkReturnExpression(container, unwrappedReturnType, node, whenFalse, self:checkExpression(whenFalse), true --[[inConditionalExpression]])
            return
        end
    end
    local inReturnStatement = node.kind == Kind.ReturnStatement
    if functionFlags & FunctionFlags.Async ~= 0 then
        unwrappedExprType = self:checkAwaitedType(exprType, false --[[withAlias]], node, diagnostics.The_return_type_of_an_async_function_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member)
    end
    local effectiveExpr = expr -- The effective expression for diagnostics purposes.
    if expr ~= nil then
        effectiveExpr = self:getEffectiveCheckNode(expr)
    end
    local errorNode = core.IfElse(inReturnStatement and not inConditionalExpression, node, effectiveExpr)
    self:checkTypeAssignableToAndOptionallyElaborate(unwrappedExprType, unwrappedReturnType, errorNode, effectiveExpr, nil, nil)
end

function Checker:checkWithStatement(node)
    if not self:checkGrammarStatementInAmbientContext(node) then
        if node.flags & NodeFlags.AwaitContext ~= 0 then
            self:grammarErrorOnFirstToken(node, diagnostics.X_with_statements_are_not_allowed_in_an_async_function_block)
        end
    end
    self:checkExpression(node:Expression())
    local sourceFile = ast.GetSourceFileOfNode(node)
    if not self:hasParseDiagnostics(sourceFile) then
        local start = scanner.SkipTrivia(sourceFile:Text(), node:Pos())
        local end_ = node:Statement():Pos()
        self:grammarErrorAtPos(sourceFile:AsNode(), start, end_ - start, diagnostics.The_with_statement_is_not_supported_All_symbols_in_a_with_block_will_have_type_any)
    end
end

function Checker:checkSwitchStatement(node)
    -- Grammar checking
    self:checkGrammarStatementInAmbientContext(node)
    local firstDefaultClause
    local hasDuplicateDefaultClause = false
    local expressionType = self:checkExpression(node:Expression())
    local caseBlock = node:AsSwitchStatement().caseBlock
    for _, clause in ipairs(caseBlock:AsCaseBlock().clauses.nodes) do
        -- Grammar check for duplicate default clauses, skip if we already report duplicate default clause
        if ast.IsDefaultClause(clause) and not hasDuplicateDefaultClause then
            if firstDefaultClause == nil then
                firstDefaultClause = clause
            else
                self:grammarErrorOnNode(clause, diagnostics.A_default_clause_cannot_appear_more_than_once_in_a_switch_statement)
                hasDuplicateDefaultClause = true
            end
        end
        if ast.IsCaseClause(clause) then
            local caseType = self:checkExpression(clause:Expression())
            if not self:isTypeEqualityComparableTo(expressionType, caseType) then
                -- expressionType is not comparable to caseType, try the reversed check and report errors if it fails
                self:checkTypeComparableTo(caseType, expressionType, clause:Expression(), nil --[[headMessage]])
            end
        end
        self:checkSourceElements(clause:Statements())
        if core.Tristate_IsTrue(self.compilerOptions.noFallthroughCasesInSwitch) then
            local flowNode = clause:AsCaseOrDefaultClause().fallthroughFlowNode
            if flowNode ~= nil and self:isReachableFlowNode(flowNode) then
                self:error(clause, diagnostics.Fallthrough_case_in_switch)
            end
        end
    end
    if caseBlock:Locals() ~= nil then
        self:registerForUnusedIdentifiersCheck(caseBlock)
    end
end

function Checker:checkLabeledStatement(node)
    local labeledStatement = node:AsLabeledStatement()
    local labelNode = labeledStatement.label
    local labelText = labelNode:Text()
    if not self:checkGrammarStatementInAmbientContext(node) then
        local current = node.parent
        while current ~= nil and not ast.IsFunctionLike(current) do
            if ast.IsLabeledStatement(current) and current:Label():Text() == labelText then
                self:grammarErrorOnNode(labelNode, diagnostics.Duplicate_label_0, labelText)
                break
            end
            current = current.parent
        end
    end
    if labelNode.flags & NodeFlags.Unreachable ~= 0 and self.compilerOptions.allowUnusedLabels ~= Tristate.TSTrue then
        self:errorOrSuggestion(self.compilerOptions.allowUnusedLabels == Tristate.TSFalse, labelNode, diagnostics.Unused_label)
    end
    self:checkSourceElement(labeledStatement.statement)
end

function Checker:checkThrowStatement(node)
    local throwExpr = node:Expression()
    if not self:checkGrammarStatementInAmbientContext(node) then
        if ast.IsIdentifier(throwExpr) and #throwExpr:Text() == 0 then
            self:grammarErrorAtPos(node, throwExpr:Pos(), 0 --[[length]], diagnostics.Line_break_not_permitted_here)
        end
    end
    self:checkExpression(throwExpr)
end

function Checker:checkTryStatement(node)
    self:checkGrammarStatementInAmbientContext(node)
    local data = node:AsTryStatement()
    self:checkBlock(data.tryBlock)
    if data.catchClause ~= nil then
        self:checkCatchClause(data.catchClause)
    end
    if data.finallyBlock ~= nil then
        self:checkBlock(data.finallyBlock)
    end
end

function Checker:checkCatchClause(node)
    local declaration = node:AsCatchClause().variableDeclaration
    if declaration ~= nil then
        self:checkVariableLikeDeclaration(declaration)
        local typeNode = declaration:Type()
        if typeNode ~= nil then
            local t = self:getTypeFromTypeNode(typeNode)
            if t ~= nil and t.flags & TypeFlags.AnyOrUnknown == 0 then
                self:grammarErrorOnFirstToken(typeNode, diagnostics.Catch_clause_variable_type_annotation_must_be_any_or_unknown_if_specified)
            end
        elseif declaration:Initializer() ~= nil then
            self:grammarErrorOnFirstToken(declaration:Initializer(), diagnostics.Catch_clause_variable_cannot_have_an_initializer)
        else
            local blockLocals = node:AsCatchClause().block:Locals()
            if blockLocals ~= nil then
                for caughtName in pairs(node:Locals() or {}) do
                    local blockLocal = blockLocals[caughtName]
                    if blockLocal ~= nil and blockLocal.valueDeclaration ~= nil and blockLocal.flags & SymbolFlags.BlockScopedVariable ~= 0 then
                        self:grammarErrorOnNode(blockLocal.valueDeclaration, diagnostics.Cannot_redeclare_identifier_0_in_catch_clause, caughtName)
                    end
                end
            end
        end
    end
    self:checkBlock(node:AsCatchClause().block)
end

function Checker:checkBindingElement(node)
    self:checkGrammarBindingElement(node:AsBindingElement())
    self:checkVariableLikeDeclaration(node)
end

function Checker:checkClassDeclaration(node)
    local firstDecorator = core.Find(node:ModifierNodes(), ast.IsDecorator)
    if self.legacyDecorators and firstDecorator ~= nil and core.Some(node:Members(), function(p)
        return ast.HasStaticModifier(p) and ast.IsPrivateIdentifierClassElementDeclaration(p)
    end) then
        self:grammarErrorOnNode(firstDecorator, diagnostics.Class_decorators_can_t_be_used_with_static_private_identifier_Consider_removing_the_experimental_decorator)
    end
    if node:Name() == nil and not ast.HasSyntacticModifier(node, ModifierFlags.Default) then
        self:grammarErrorOnFirstToken(node, diagnostics.A_class_declaration_without_the_default_modifier_must_have_a_name)
    end
    self:checkClassLikeDeclaration(node)
    self:checkSourceElements(node:Members())
    self:registerForUnusedIdentifiersCheck(node)
end

function Checker:checkClassLikeDeclaration(node)
    self:checkGrammarClassLikeDeclaration(node)
    self:checkDecorators(node)
    self:checkCollisionsForDeclarationName(node, node:Name())
    self:checkTypeParameters(node:TypeParameters())
    self:checkExportsOnMergedDeclarations(node)
    local symbol = self:getSymbolOfDeclaration(node)
    local classType = self:getDeclaredTypeOfSymbol(symbol)
    local classTypeData = classType:AsInterfaceType()
    local typeWithThis = self:getTypeWithThisArgument(classType, nil, false)
    local staticType = self:getTypeOfSymbol(symbol)
    self:checkTypeParameterListsIdentical(symbol)
    self:checkFunctionOrConstructorSymbol(symbol)
    self:checkObjectTypeForDuplicateDeclarations(node, true --[[checkPrivateNames]])

    -- Only check for reserved static identifiers on non-ambient context.
    local nodeInAmbientContext = node.flags & NodeFlags.Ambient ~= 0
    if not nodeInAmbientContext then
        self:checkClassForStaticPropertyNameConflicts(node)
    end

    local baseTypeNode = ast.GetClassExtendsHeritageElement(node)
    if baseTypeNode ~= nil then
        self:checkSourceElements(baseTypeNode:TypeArguments())
        local baseTypes = self:getBaseTypes(classType)
        if core.Len(baseTypes) ~= 0 then
            local baseType = baseTypes[1]
            self:checkJSDocAugmentsTagMatchesExtends(node, baseTypeNode, baseType)
            local baseConstructorType = self:getBaseConstructorTypeOfClass(classType)
            local staticBaseType = self:getApparentType(baseConstructorType)
            self:checkBaseTypeAccessibility(staticBaseType, baseTypeNode)
            self:checkSourceElement(baseTypeNode:Expression())
            if core.Len(baseTypeNode:TypeArguments()) ~= 0 then
                self:checkSourceElements(baseTypeNode:TypeArguments())
                for _, constructor in ipairs(self:getConstructorsForTypeArguments(staticBaseType, baseTypeNode:TypeArguments(), baseTypeNode) or {}) do
                    if not self:checkTypeArgumentConstraints(baseTypeNode, constructor.typeParameters) then
                        break
                    end
                end
            end
            local baseWithThis = self:getTypeWithThisArgument(baseType, classTypeData.thisType, false)
            if not self:checkTypeAssignableTo(typeWithThis, baseWithThis, nil, nil) then
                self:issueMemberSpecificError(node, typeWithThis, baseWithThis, diagnostics.Class_0_incorrectly_extends_base_class_1)
            else
                -- Report static side error only when instance type is assignable
                self:checkTypeAssignableTo(staticType, self:getTypeWithoutSignatures(staticBaseType), node:Name() or node, diagnostics.Class_static_side_0_incorrectly_extends_base_class_static_side_1)
            end
            if baseConstructorType.flags & TypeFlags.TypeVariable ~= 0 then
                if not self:isMixinConstructorType(staticType) then
                    self:error(node:Name() or node, diagnostics.A_mixin_class_must_have_a_constructor_with_a_single_rest_parameter_of_type_any)
                else
                    local constructSignatures = self:getSignaturesOfType(baseConstructorType, SignatureKind.Construct)
                    if core.Some(constructSignatures, function(signature)
                        return signature.flags & SignatureFlags.Abstract ~= 0
                    end) and not ast.HasSyntacticModifier(node, ModifierFlags.Abstract) then
                        self:error(node:Name() or node, diagnostics.A_mixin_class_that_extends_from_a_type_variable_containing_an_abstract_construct_signature_must_also_be_declared_abstract)
                    end
                end
            end
            if not (staticBaseType.symbol ~= nil and staticBaseType.symbol.flags & SymbolFlags.Class ~= 0) and baseConstructorType.flags & TypeFlags.TypeVariable == 0 then
                -- When the static base type is a "class-like" constructor function (but not actually a class), we verify
                -- that all instantiated base constructor signatures return the same type.
                local constructors = self:getInstantiatedConstructorsForTypeArguments(staticBaseType, baseTypeNode:TypeArguments(), baseTypeNode)
                if not core.Every(constructors, function(sig)
                    return self:isTypeIdenticalTo(self:getReturnTypeOfSignature(sig), baseType)
                end) then
                    self:error(baseTypeNode:Expression(), diagnostics.Base_constructors_must_all_have_the_same_return_type)
                end
            end
            self:checkKindsOfPropertyMemberOverrides(classType, baseType)
        end
    end
    self:checkMembersForOverrideModifier(node, classType, typeWithThis, staticType)
    local implementedTypeNodes = ast.GetImplementsHeritageClauseElements(node)
    for _, typeRefNode in ipairs(implementedTypeNodes or {}) do
        if ast.IsExpressionWithTypeArguments(typeRefNode) then
            local expr = typeRefNode:Expression()
            if not ast.IsEntityNameExpression(expr) or ast.IsOptionalChain(expr) then
                self:error(expr, diagnostics.A_class_can_only_implement_an_identifier_Slashqualified_name_with_optional_type_arguments)
            end
        end
        self:checkTypeReferenceNode(typeRefNode)
        local t = self:getReducedType(self:getTypeFromTypeNode(typeRefNode))
        if not self:isErrorType(t) then
            if self:isValidBaseType(t) then
                local genericDiag = core.IfElse(t.symbol ~= nil and t.symbol.flags & SymbolFlags.Class ~= 0,
                    diagnostics.Class_0_incorrectly_implements_class_1_Did_you_mean_to_extend_1_and_inherit_its_members_as_a_subclass,
                    diagnostics.Class_0_incorrectly_implements_interface_1)
                local baseWithThis = self:getTypeWithThisArgument(t, classType:AsInterfaceType().thisType, false)
                if not self:checkTypeAssignableTo(typeWithThis, baseWithThis, nil, nil) then
                    self:issueMemberSpecificError(node, typeWithThis, baseWithThis, genericDiag)
                end
            else
                self:error(typeRefNode, diagnostics.A_class_can_only_implement_an_object_type_or_intersection_of_object_types_with_statically_known_members)
            end
        end
    end
    self:checkIndexConstraints(classType, symbol, false --[[isStaticIndex]])
    self:checkIndexConstraints(staticType, symbol, true --[[isStaticIndex]])
    self:checkClassOrInterfaceForDuplicateIndexSignatures(node)
    self:checkPropertyInitialization(node)
end

function Checker:checkJSDocAugmentsTagMatchesExtends(node, baseTypeNode, baseType)
    if not ast.IsInJSFile(node) then
        return
    end
    local file = ast.GetSourceFileOfNode(node)
    for _, j in ipairs(node:EagerJSDoc(file) or {}) do
        if j:AsJSDoc().tags == nil then
            goto continue
        end
        for _, tag in ipairs(j:AsJSDoc().tags.nodes) do
            if tag.kind ~= Kind.JSDocAugmentsTag then
                goto continueTag
            end
            do
                local sourceTypeNode = tag:ClassName()
                if self:isTypeIdenticalTo(self:getTypeFromTypeNode(sourceTypeNode), baseType) then
                    goto continueTag
                end
                local targetName = checker.getIdentifierFromEntityNameExpression(baseTypeNode:Expression())
                local sourceName = checker.getIdentifierFromEntityNameExpression(sourceTypeNode:Expression())
                if targetName ~= nil and sourceName ~= nil then
                    self:error(sourceName, diagnostics.JSDoc_0_1_does_not_match_the_extends_2_clause, tag:TagName():Text(), sourceName:Text(), targetName:Text())
                end
            end
            ::continueTag::
        end
        ::continue::
    end
end

function Checker:checkClassForStaticPropertyNameConflicts(node)
    if self.compilerOptions:GetUseDefineForClassFields() then
        return
    end
    for _, member in ipairs(node:Members()) do
        local memberNameNode = member:Name()
        local isStaticMember = ast.IsStatic(member)
        if isStaticMember and memberNameNode ~= nil then
            local memberName = self:getEffectivePropertyNameForPropertyNameNode(memberNameNode)
            if memberName == "name" or memberName == "length" or memberName == "caller" or memberName == "arguments" then
                self:error(
                    memberNameNode,
                    diagnostics.Static_property_0_conflicts_with_built_in_property_Function_0_of_constructor_function_1,
                    memberName,
                    self:symbolToString(self:getSymbolOfDeclaration(node))
                )
            end
        end
    end
end

-- Check that type parameter lists are identical across multiple declarations
function Checker:checkTypeParameterListsIdentical(symbol)
    if core.Len(symbol.declarations) == 1 then
        return
    end
    local links = self.declaredTypeLinks:Get(symbol)
    if not links.typeParametersChecked then
        links.typeParametersChecked = true
        local declarations = self:getClassOrInterfaceDeclarationsOfSymbol(symbol)
        if core.Len(declarations) <= 1 then
            return
        end
        local t = self:getDeclaredTypeOfSymbol(symbol)
        if not self:areTypeParametersIdentical(declarations, t:AsInterfaceType():LocalTypeParameters(), function(n) return n:TypeParameters() end) then
            -- Report an error on every conflicting declaration.
            local name = self:symbolToString(symbol)
            for _, declaration in ipairs(declarations) do
                self:error(declaration:Name(), diagnostics.All_declarations_of_0_must_have_identical_type_parameters, name)
            end
        end
    end
end

function Checker:getClassOrInterfaceDeclarationsOfSymbol(symbol)
    return core.Filter(symbol.declarations, function(d)
        return ast.IsClassDeclaration(d) or ast.IsInterfaceDeclaration(d)
    end)
end

function Checker:areTypeParametersIdentical(declarations, targetParameters, getTypeParameterDeclarations)
    local maxTypeArgumentCount = core.Len(targetParameters)
    local minTypeArgumentCount = self:getMinTypeArgumentCount(targetParameters)
    for _, declaration in ipairs(declarations) do
        -- If this declaration has too few or too many type parameters, we report an error
        local sourceParameters = getTypeParameterDeclarations(declaration)
        if core.Len(sourceParameters) < minTypeArgumentCount or core.Len(sourceParameters) > maxTypeArgumentCount then
            return false
        end
        for i, source in ipairs(sourceParameters or {}) do
            local target = targetParameters[i]
            -- If the type parameter node does not have the same name as the resolved type
            -- parameter at this position, we report an error.
            if source:Name():Text() ~= target.symbol.name then
                return false
            end
            -- If the type parameter node does not have an identical constraintNode as the resolved
            -- type parameter at this position, we report an error.
            local constraintNode = source:AsTypeParameterDeclaration().constraint
            local targetConstraint = self:getConstraintOfTypeParameter(target)
            -- relax check if later interface augmentation has no constraint, it's more broad and is OK to merge with
            -- a more constrained interface (this could be generalized to a full hierarchy check, but that's maybe overkill)
            if constraintNode ~= nil and targetConstraint ~= nil and not self:isTypeIdenticalTo(self:getTypeFromTypeNode(constraintNode), targetConstraint) then
                return false
            end
            -- If the type parameter node has a default and it is not identical to the default
            -- for the type parameter at this position, we report an error.
            local defaultNode = source:AsTypeParameterDeclaration().defaultType
            local targetDefault = self:getDefaultFromTypeParameter(target)
            if defaultNode ~= nil and targetDefault ~= nil and not self:isTypeIdenticalTo(self:getTypeFromTypeNode(defaultNode), targetDefault) then
                return false
            end
        end
    end
    return true
end

function Checker:checkBaseTypeAccessibility(t, node)
    local signatures = self:getSignaturesOfType(t, SignatureKind.Construct)
    if core.Len(signatures) ~= 0 then
        local declaration = signatures[1].declaration
        if declaration ~= nil and ast.HasModifier(declaration, ModifierFlags.Private) then
            local typeClassDeclaration = ast.GetClassLikeDeclarationOfSymbol(t.symbol)
            if not self:isNodeWithinClass(node, typeClassDeclaration) then
                self:error(node, diagnostics.Cannot_extend_a_class_0_Class_constructor_is_marked_as_private, self:getFullyQualifiedName(t.symbol, nil))
            end
        end
    end
end

function Checker:issueMemberSpecificError(node, typeWithThis, baseWithThis, broadDiag)
    -- iterate over all implemented properties and issue errors on each one which isn't compatible, rather than the class as a whole, if possible
    local issuedMemberError = false
    for _, member in ipairs(node:Members()) do
        if ast.IsStatic(member) then
            goto continue
        end
        do
            local declaredProp = self:getSymbolOfDeclaration(member)
            if declaredProp ~= nil and declaredProp.name ~= ast.InternalSymbolNameComputed then
                local prop = self:getPropertyOfType(typeWithThis, declaredProp.name)
                local baseProp = self:getPropertyOfType(baseWithThis, declaredProp.name)
                if prop ~= nil and baseProp ~= nil then
                    local diags = {}
                    if not self:checkTypeAssignableToEx(self:getTypeOfSymbol(prop), self:getTypeOfSymbol(baseProp), member:Name() or member, nil --[[headMessage]], diags) then
                        self:addDiagnostic(ast.NewDiagnosticChain(diags[1], diagnostics.Property_0_in_type_1_is_not_assignable_to_the_same_property_in_base_type_2, self:symbolToString(declaredProp), self:TypeToString(typeWithThis), self:TypeToString(baseWithThis)))
                        issuedMemberError = true
                    end
                end
            end
        end
        ::continue::
    end
    if not issuedMemberError then
        -- check again with diagnostics to generate a less-specific error
        self:checkTypeAssignableTo(typeWithThis, baseWithThis, node:Name() or node, broadDiag)
    end
end

function Checker:getTypeWithoutSignatures(t)
    if t.flags & TypeFlags.Object ~= 0 then
        local resolved = self:resolveStructuredTypeMembers(t)
        if core.Len(resolved.signatures) ~= 0 then
            local result = self:newObjectType(ObjectFlags.Anonymous, t.symbol)
            result.objectFlags = result.objectFlags | ObjectFlags.MembersResolved
            result:AsObjectType().members = resolved.members
            result:AsObjectType().properties = resolved.properties
            return result
        end
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        return self:getIntersectionType(core.Map(t:AsIntersectionType().types, function(x) return self:getTypeWithoutSignatures(x) end))
    end
    return t
end

local function quoteMissedProperty(prop)
    return "'" .. prop .. "'"
end

function Checker:checkKindsOfPropertyMemberOverrides(t, baseType)
    -- TypeScript 1.0 spec (April 2014): 8.2.3
    -- A derived class inherits all members from its base class it doesn't override.
    -- Inheritance means that a derived class implicitly contains all non - overridden members of the base class.
    -- Both public and private property members are inherited, but only public property members can be overridden.
    -- A property member in a derived class is said to override a property member in a base class
    -- when the derived class property member has the same name and kind(instance or static)
    -- as the base class property member.
    -- The type of an overriding property member must be assignable(section 3.8.4)
    -- to the type of the overridden property member, or otherwise a compile - time error occurs.
    -- Base class instance member functions can be overridden by derived class instance member functions,
    -- but not by other kinds of members.
    -- Base class instance member variables and accessors can be overridden by
    -- derived class instance member variables and accessors, but not by other kinds of members.
    -- NOTE: assignability is checked in checkClassDeclaration
    --
    -- notImplementedInfo is Go's map[*ast.Node]MemberInfo; the key may be nil, so entries are
    -- kept in an array of { errorNode, memberInfo } in insertion order.
    local notImplementedInfo
    local function findInfo(node)
        for _, entry in ipairs(notImplementedInfo or {}) do
            if entry.errorNode == node then
                return entry
            end
        end
        return nil
    end
    for _, baseProperty in ipairs(self:getPropertiesOfType(baseType) or {}) do
        local base = self:getTargetSymbol(baseProperty)
        if base.flags & SymbolFlags.Prototype ~= 0 then
            goto basePropertyCheck
        end
        do
            local baseSymbol = self:getPropertyOfObjectType(t, base.name)
            if baseSymbol == nil then
                goto basePropertyCheck
            end
            local derived = self:getTargetSymbol(baseSymbol)
            local baseDeclarationFlags = checker.getDeclarationModifierFlagsFromSymbol(base)
            -- In order to resolve whether the inherited method was overridden in the base class or not,
            -- we compare the Symbols obtained. Since getTargetSymbol returns the symbol on the *uninstantiated*
            -- type declaration, derived and base resolve to the same symbol even in the case of generic classes.
            if derived == base then
                -- derived class inherits base without override/redeclaration.
                if baseDeclarationFlags & ModifierFlags.Abstract ~= 0 then
                    -- It is an error to inherit an abstract member without implementing it or being declared abstract.
                    -- If there is no declaration for the derived class (as in the case of class expressions),
                    -- then the class cannot be declared abstract.
                    local derivedClassDecl = ast.GetClassLikeDeclarationOfSymbol(t.symbol)
                    if derivedClassDecl == nil or not ast.HasSyntacticModifier(derivedClassDecl, ModifierFlags.Abstract) then
                        -- Searches other base types for a declaration that would satisfy the inherited abstract member.
                        -- (The class may have more than one base type via declaration merging with an interface with the
                        -- same name.)
                        for _, otherBaseType in ipairs(self:getBaseTypes(t) or {}) do
                            if otherBaseType ~= baseType then
                                local otherBaseSymbol = self:getPropertyOfObjectType(otherBaseType, base.name)
                                if otherBaseSymbol ~= nil and base ~= self:getTargetSymbol(otherBaseSymbol) then
                                    -- Derived property exists elsewhere.
                                    goto basePropertyCheck
                                end
                            end
                        end
                        local baseTypeName = self:TypeToString(baseType)
                        local typeName = self:TypeToString(t)
                        local entry = findInfo(derivedClassDecl)
                        local missedProperties = {}
                        if entry ~= nil then
                            for _, p in ipairs(entry.memberInfo.missedProperties) do
                                missedProperties[#missedProperties + 1] = p
                            end
                        end
                        missedProperties[#missedProperties + 1] = self:symbolToString(baseProperty)
                        if notImplementedInfo == nil then
                            notImplementedInfo = {}
                        end
                        local memberInfo = {
                            baseTypeName = baseTypeName,
                            typeName = typeName,
                            missedProperties = missedProperties,
                        }
                        if entry ~= nil then
                            entry.memberInfo = memberInfo
                        else
                            notImplementedInfo[#notImplementedInfo + 1] = { errorNode = derivedClassDecl, memberInfo = memberInfo }
                        end
                    end
                end
            else
                -- derived overrides base.
                local derivedDeclarationFlags = checker.getDeclarationModifierFlagsFromSymbol(derived)
                if baseDeclarationFlags & ModifierFlags.Private ~= 0 or derivedDeclarationFlags & ModifierFlags.Private ~= 0 then
                    -- either base or derived property is private - not override, skip it
                    goto basePropertyCheck
                end
                local errorMessage
                local basePropertyFlags = base.flags & SymbolFlags.PropertyOrAccessor
                local derivedPropertyFlags = derived.flags & SymbolFlags.PropertyOrAccessor
                if basePropertyFlags ~= 0 and derivedPropertyFlags ~= 0 then
                    -- property/accessor is overridden with property/accessor
                    if base.checkFlags & ast.CheckFlags.Mapped ~= 0 or
                        derived.valueDeclaration ~= nil and ast.IsBinaryExpression(derived.valueDeclaration) or
                        self:arePropertiesAbstractOrInterface(base, baseDeclarationFlags) then
                        -- when the base property is abstract or from an interface, base/derived flags don't need to match
                        -- for intersection properties, this must be true of *any* of the declarations, for others it must be true of *all*
                        -- same when the derived property is from an assignment
                        goto basePropertyCheck
                    end
                    local overriddenInstanceProperty = basePropertyFlags ~= SymbolFlags.Property and derivedPropertyFlags == SymbolFlags.Property
                    local overriddenInstanceAccessor = basePropertyFlags == SymbolFlags.Property and derivedPropertyFlags ~= SymbolFlags.Property
                    if overriddenInstanceProperty or overriddenInstanceAccessor then
                        local errorMessage_ = core.IfElse(overriddenInstanceProperty,
                            diagnostics.X_0_is_defined_as_an_accessor_in_class_1_but_is_overridden_here_in_2_as_an_instance_property,
                            diagnostics.X_0_is_defined_as_a_property_in_class_1_but_is_overridden_here_in_2_as_an_accessor)
                        self:error(ast.GetNameOfDeclaration(derived.valueDeclaration) or derived.valueDeclaration, errorMessage_, self:symbolToString(base), self:TypeToString(baseType), self:TypeToString(t))
                    elseif self.compilerOptions:GetUseDefineForClassFields() then
                        local uninitialized = core.Find(derived.declarations, function(d)
                            return ast.IsPropertyDeclaration(d) and d:Initializer() == nil
                        end)
                        if uninitialized ~= nil and derived.flags & SymbolFlags.Transient == 0 and baseDeclarationFlags & ModifierFlags.Abstract == 0 and derivedDeclarationFlags & ModifierFlags.Abstract == 0 and not core.Some(derived.declarations, function(d)
                            return d.flags & NodeFlags.Ambient ~= 0
                        end) then
                            local constructor = ast.FindConstructorDeclaration(ast.GetClassLikeDeclarationOfSymbol(t.symbol))
                            local propName = uninitialized:Name()
                            if checker.isExclamationToken(uninitialized:PostfixToken()) or constructor == nil or not ast.IsIdentifier(propName) or not self.strictNullChecks or not self:isPropertyInitializedInConstructor(propName, t, constructor) then
                                local errorMessage_ = diagnostics.Property_0_will_overwrite_the_base_property_in_1_If_this_is_intentional_add_an_initializer_Otherwise_add_a_declare_modifier_or_remove_the_redundant_declaration
                                self:error(ast.GetNameOfDeclaration(derived.valueDeclaration) or derived.valueDeclaration, errorMessage_, self:symbolToString(base), self:TypeToString(baseType))
                            end
                        end
                    end
                    -- correct case
                    goto basePropertyCheck
                elseif checker.isPrototypeProperty(base) then
                    if checker.isPrototypeProperty(derived) or derived.flags & SymbolFlags.Property ~= 0 then
                        -- method is overridden with method or property -- correct case
                        goto basePropertyCheck
                    else
                        errorMessage = diagnostics.Class_0_defines_instance_member_function_1_but_extended_class_2_defines_it_as_instance_member_accessor
                    end
                elseif base.flags & SymbolFlags.Accessor ~= 0 then
                    errorMessage = diagnostics.Class_0_defines_instance_member_accessor_1_but_extended_class_2_defines_it_as_instance_member_function
                else
                    errorMessage = diagnostics.Class_0_defines_instance_member_property_1_but_extended_class_2_defines_it_as_instance_member_function
                end
                self:error(ast.GetNameOfDeclaration(derived.valueDeclaration) or derived.valueDeclaration, errorMessage, self:TypeToString(baseType), self:symbolToString(base), self:TypeToString(t))
            end
        end
        ::basePropertyCheck::
    end
    for _, entry in ipairs(notImplementedInfo or {}) do
        local errorNode = entry.errorNode
        local memberInfo = entry.memberInfo
        if #memberInfo.missedProperties == 1 then
            local missedProperty = memberInfo.missedProperties[1]
            if ast.IsClassExpression(errorNode) then
                self:error(errorNode, diagnostics.Non_abstract_class_expression_does_not_implement_inherited_abstract_member_0_from_class_1, missedProperty, memberInfo.baseTypeName)
            else
                self:error(errorNode, diagnostics.Non_abstract_class_0_does_not_implement_inherited_abstract_member_1_from_class_2, memberInfo.typeName, missedProperty, memberInfo.baseTypeName)
            end
        elseif #memberInfo.missedProperties > 5 then
            local missedProperties = table.concat(core.Map(core.Slice(memberInfo.missedProperties, 0, 4), quoteMissedProperty), ", ")
            local remainingMissedProperties = #memberInfo.missedProperties - 4
            if ast.IsClassExpression(errorNode) then
                self:error(errorNode, diagnostics.Non_abstract_class_expression_is_missing_implementations_for_the_following_members_of_0_Colon_1_and_2_more, memberInfo.baseTypeName, missedProperties, remainingMissedProperties)
            else
                self:error(errorNode, diagnostics.Non_abstract_class_0_is_missing_implementations_for_the_following_members_of_1_Colon_2_and_3_more, memberInfo.typeName, memberInfo.baseTypeName, missedProperties, remainingMissedProperties)
            end
        else
            local missedProperties = table.concat(core.Map(memberInfo.missedProperties, quoteMissedProperty), ", ")
            if ast.IsClassExpression(errorNode) then
                self:error(errorNode, diagnostics.Non_abstract_class_expression_is_missing_implementations_for_the_following_members_of_0_Colon_1, memberInfo.baseTypeName, missedProperties)
            else
                self:error(errorNode, diagnostics.Non_abstract_class_0_is_missing_implementations_for_the_following_members_of_1_Colon_2, memberInfo.typeName, memberInfo.baseTypeName, missedProperties)
            end
        end
    end
end

function Checker:arePropertiesAbstractOrInterface(base, baseDeclarationFlags)
    if base.checkFlags & ast.CheckFlags.Synthetic ~= 0 then
        return core.Some(base.declarations, function(d) return self:isPropertyAbstractOrInterface(d, baseDeclarationFlags) end)
    end
    return core.Every(base.declarations, function(d) return self:isPropertyAbstractOrInterface(d, baseDeclarationFlags) end)
end

function Checker:isPropertyAbstractOrInterface(declaration, baseDeclarationFlags)
    return ast.IsInterfaceDeclaration(declaration.parent) or
        baseDeclarationFlags & ModifierFlags.Abstract ~= 0 and (not ast.IsPropertyDeclaration(declaration) or declaration:Initializer() == nil)
end

function Checker:checkMembersForOverrideModifier(node, t, typeWithThis, staticType)
    local baseWithThis
    local baseTypeNode = ast.GetClassExtendsHeritageElement(node)
    if baseTypeNode ~= nil then
        local baseTypes = self:getBaseTypes(t)
        if core.Len(baseTypes) > 0 then
            baseWithThis = self:getTypeWithThisArgument(core.FirstOrNil(baseTypes), t:AsInterfaceType().thisType, false)
        end
    end
    local baseStaticType = self:getBaseConstructorTypeOfClass(t)
    for _, member in ipairs(node:Members()) do
        if not ast.HasAmbientModifier(member) then
            if ast.IsConstructorDeclaration(member) then
                for _, param in ipairs(member:Parameters()) do
                    if ast.IsParameterPropertyDeclaration(param, member) then
                        self:checkMemberForOverrideModifier(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, param)
                    end
                end
            else
                self:checkMemberForOverrideModifier(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, member)
            end
        end
    end
end

function Checker:checkMemberForOverrideModifier(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, member)
    local symbol = self:getSymbolOfDeclaration(member)
    if symbol == nil then
        return
    end

    self:checkMemberForOverrideModifierWorker(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, checker.hasOverrideModifier(member), ast.HasAbstractModifier(member), ast.IsStatic(member), ast.IsParameterDeclaration(member), symbol, member)
end

function Checker:getMemberOverrideModifierStatus(node, member, memberSymbol)
    if member:Name() == nil or memberSymbol == nil then
        return MemberOverrideStatus.None
    end

    local classSymbol = self:getSymbolOfDeclaration(node)
    if classSymbol == nil then
        return MemberOverrideStatus.None
    end

    local t = self:getDeclaredTypeOfSymbol(classSymbol)
    local typeWithThis = self:getTypeWithThisArgument(t, nil, false)
    local staticType = self:getTypeOfSymbol(classSymbol)

    local baseWithThis
    if ast.GetClassExtendsHeritageElement(node) ~= nil then
        local baseTypes = self:getBaseTypes(t)
        if core.Len(baseTypes) > 0 then
            baseWithThis = self:getTypeWithThisArgument(baseTypes[1], t:AsInterfaceType().thisType, false)
        end
    end

    return self:checkMemberForOverrideModifierWorker(node, staticType, self:getBaseConstructorTypeOfClass(t), baseWithThis, t, typeWithThis, ast.HasSyntacticModifier(member, ModifierFlags.Override), ast.HasAbstractModifier(member), ast.IsStatic(member), false --[[memberIsParameterProperty]], memberSymbol, nil --[[errorNode]])
end

function Checker:checkMemberForOverrideModifierWorker(node, staticType, baseStaticType, baseWithThis, t, typeWithThis, memberHasOverrideModifier, memberHasAbstractModifier, memberIsStatic, memberIsParameterProperty, member, errorNode)
    local isJs = ast.IsInJSFile(node)
    if memberHasOverrideModifier and member.valueDeclaration ~= nil and ast.IsClassElement(member.valueDeclaration) and member.valueDeclaration:Name() ~= nil and self:isNonBindableDynamicName(member.valueDeclaration:Name()) then
        if errorNode ~= nil then
            self:error(errorNode, core.IfElse(isJs, diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_its_name_is_dynamic, diagnostics.This_member_cannot_have_an_override_modifier_because_its_name_is_dynamic))
        end
        return MemberOverrideStatus.HasInvalidOverride
    end

    if baseWithThis ~= nil and (memberHasOverrideModifier or core.Tristate_IsTrue(self.compilerOptions.noImplicitOverride)) then
        local thisType = core.IfElse(memberIsStatic, staticType, typeWithThis)
        local baseType = core.IfElse(memberIsStatic, baseStaticType, baseWithThis)
        local prop = self:getPropertyOfType(thisType, member.name)
        local baseProp = self:getPropertyOfType(baseType, member.name)

        if prop ~= nil and baseProp == nil and memberHasOverrideModifier then
            if errorNode ~= nil then
                local suggestion = self:getSuggestedSymbolForNonexistentClassMember(ast.SymbolName(member), baseType)
                if suggestion ~= nil then
                    self:error(errorNode, core.IfElse(isJs, diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_it_is_not_declared_in_the_base_class_0_Did_you_mean_1, diagnostics.This_member_cannot_have_an_override_modifier_because_it_is_not_declared_in_the_base_class_0_Did_you_mean_1), self:TypeToString(baseWithThis), self:symbolToString(suggestion))
                else
                    self:error(errorNode, core.IfElse(isJs, diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_it_is_not_declared_in_the_base_class_0, diagnostics.This_member_cannot_have_an_override_modifier_because_it_is_not_declared_in_the_base_class_0), self:TypeToString(baseWithThis))
                end
            end
            return MemberOverrideStatus.HasInvalidOverride
        end

        if prop ~= nil and baseProp ~= nil and core.Len(baseProp.declarations) > 0 and core.Tristate_IsTrue(self.compilerOptions.noImplicitOverride) and node.flags & NodeFlags.Ambient == 0 then
            local baseHasAbstract = core.Some(baseProp.declarations, ast.HasAbstractModifier)
            if memberHasOverrideModifier then
                return MemberOverrideStatus.None
            end
            if not baseHasAbstract then
                if errorNode ~= nil then
                    local message = core.IfElse(memberIsParameterProperty,
                        core.IfElse(isJs, diagnostics.This_parameter_property_must_have_a_JSDoc_comment_with_an_override_tag_because_it_overrides_a_member_in_the_base_class_0, diagnostics.This_parameter_property_must_have_an_override_modifier_because_it_overrides_a_member_in_base_class_0),
                        core.IfElse(isJs, diagnostics.This_member_must_have_a_JSDoc_comment_with_an_override_tag_because_it_overrides_a_member_in_the_base_class_0, diagnostics.This_member_must_have_an_override_modifier_because_it_overrides_a_member_in_the_base_class_0))
                    self:error(errorNode, message, self:TypeToString(baseWithThis))
                end
                return MemberOverrideStatus.NeedsOverride
            end
            if memberHasAbstractModifier then
                if errorNode ~= nil then
                    self:error(errorNode, diagnostics.This_member_must_have_an_override_modifier_because_it_overrides_an_abstract_method_that_is_declared_in_the_base_class_0, self:TypeToString(baseWithThis))
                end
                return MemberOverrideStatus.NeedsOverride
            end
        end
    elseif memberHasOverrideModifier then
        if errorNode ~= nil then
            self:error(errorNode, core.IfElse(isJs, diagnostics.This_member_cannot_have_a_JSDoc_comment_with_an_override_tag_because_its_containing_class_0_does_not_extend_another_class, diagnostics.This_member_cannot_have_an_override_modifier_because_its_containing_class_0_does_not_extend_another_class), self:TypeToString(t))
        end
        return MemberOverrideStatus.HasInvalidOverride
    end

    return MemberOverrideStatus.None
end

function Checker:getSuggestedSymbolForNonexistentClassMember(name, baseType)
    return self:getSpellingSuggestionForName(name, self:getPropertiesOfType(baseType), SymbolFlags.ClassMember)
end

function Checker:checkIndexConstraints(t, symbol, isStaticIndex)
    local indexInfos = self:getIndexInfosOfType(t)
    if core.Len(indexInfos) == 0 then
        return
    end
    for _, prop in ipairs(self:getPropertiesOfObjectType(t) or {}) do
        if not (isStaticIndex and prop.flags & SymbolFlags.Prototype ~= 0) then
            self:checkIndexConstraintForProperty(t, prop, self:getLiteralTypeFromProperty(prop, TypeFlags.StringOrNumberLiteralOrUnique, true --[[includeNonPublic]]), self:getNonMissingTypeOfSymbol(prop))
        end
    end
    local typeDeclaration = symbol.valueDeclaration
    if typeDeclaration ~= nil and ast.IsClassLike(typeDeclaration) then
        for _, member in ipairs(typeDeclaration:Members()) do
            -- Only process instance properties against instance index signatures and static properties against static index signatures
            if ast.IsStatic(member) == isStaticIndex and not self:hasBindableName(member) then
                local memberSymbol = self:getSymbolOfDeclaration(member)
                self:checkIndexConstraintForProperty(t, memberSymbol, self:getTypeOfExpression(member:Name():Expression()), self:getNonMissingTypeOfSymbol(memberSymbol))
            end
        end
    end
    if #indexInfos > 1 then
        for _, info in ipairs(indexInfos) do
            self:checkIndexConstraintForIndexSignature(t, info)
        end
    end
end

function Checker:checkIndexConstraintForProperty(t, prop, propNameType, propType)
    local declaration = prop.valueDeclaration
    local name = ast.GetNameOfDeclaration(declaration)
    if name ~= nil and ast.IsPrivateIdentifier(name) then
        return
    end
    local indexInfos = self:getApplicableIndexInfos(t, propNameType)
    if core.Len(indexInfos) == 0 then
        return
    end
    local interfaceDeclaration
    if t.objectFlags & ObjectFlags.Interface ~= 0 then
        interfaceDeclaration = ast.GetDeclarationOfKind(t.symbol, Kind.InterfaceDeclaration)
    end
    local propDeclaration
    if declaration ~= nil and ast.IsBinaryExpression(declaration) or name ~= nil and ast.IsComputedPropertyName(name) then
        propDeclaration = declaration
    end
    local localPropDeclaration
    if self:getParentOfSymbol(prop) == t.symbol then
        localPropDeclaration = declaration
    end
    for _, info in ipairs(indexInfos) do
        local localIndexDeclaration
        if info.declaration ~= nil and self:getParentOfSymbol(self:getSymbolOfDeclaration(info.declaration)) == t.symbol then
            localIndexDeclaration = info.declaration
        end
        -- We check only when (a) the property is declared in the containing type, or (b) the applicable index signature is declared
        -- in the containing type, or (c) the containing type is an interface and no base interface contains both the property and
        -- the index signature (i.e. property and index signature are declared in separate inherited interfaces).
        local errorNode = localPropDeclaration or localIndexDeclaration
        if errorNode == nil and interfaceDeclaration ~= nil and not core.Some(self:getBaseTypes(t), function(base)
            return self:getPropertyOfObjectType(base, prop.name) ~= nil and self:getIndexTypeOfType(base, info.keyType) ~= nil
        end) then
            errorNode = interfaceDeclaration
        end
        if errorNode ~= nil and not self:isTypeAssignableTo(propType, info.valueType) then
            local diagnostic = checker.NewDiagnosticForNode(errorNode, diagnostics.Property_0_of_type_1_is_not_assignable_to_2_index_type_3, self:symbolToString(prop), self:TypeToString(propType), self:TypeToString(info.keyType), self:TypeToString(info.valueType))
            if propDeclaration ~= nil and errorNode ~= propDeclaration then
                diagnostic:AddRelatedInfo(checker.NewDiagnosticForNode(propDeclaration, diagnostics.X_0_is_declared_here, self:symbolToString(prop)))
            end
            self:addDiagnostic(diagnostic)
        end
    end
end

function Checker:checkIndexConstraintForIndexSignature(t, checkInfo)
    local declaration = checkInfo.declaration
    local indexInfos = self:getApplicableIndexInfos(t, checkInfo.keyType)
    if core.Len(indexInfos) == 0 then
        return
    end
    local interfaceDeclaration
    if t.objectFlags & ObjectFlags.Interface ~= 0 then
        interfaceDeclaration = ast.GetDeclarationOfKind(t.symbol, Kind.InterfaceDeclaration)
    end
    local localCheckDeclaration
    if declaration ~= nil and self:getParentOfSymbol(self:getSymbolOfDeclaration(declaration)) == t.symbol then
        localCheckDeclaration = declaration
    end
    for _, info in ipairs(indexInfos) do
        if info == checkInfo then
            goto continue
        end
        do
            local localIndexDeclaration
            if info.declaration ~= nil and self:getParentOfSymbol(self:getSymbolOfDeclaration(info.declaration)) == t.symbol then
                localIndexDeclaration = info.declaration
            end
            -- We check only when (a) the check index signature is declared in the containing type, or (b) the applicable index
            -- signature is declared in the containing type, or (c) the containing type is an interface and no base interface contains
            -- both index signatures (i.e. the index signatures are declared in separate inherited interfaces).
            local errorNode = localCheckDeclaration or localIndexDeclaration
            if errorNode == nil and interfaceDeclaration ~= nil and not core.Some(self:getBaseTypes(t), function(base)
                return self:getIndexInfoOfType(base, checkInfo.keyType) ~= nil and self:getIndexTypeOfType(base, info.keyType) ~= nil
            end) then
                errorNode = interfaceDeclaration
            end
            if errorNode ~= nil and not self:isTypeAssignableTo(checkInfo.valueType, info.valueType) then
                self:error(errorNode, diagnostics.X_0_index_type_1_is_not_assignable_to_2_index_type_3, self:TypeToString(checkInfo.keyType), self:TypeToString(checkInfo.valueType), self:TypeToString(info.keyType), self:TypeToString(info.valueType))
            end
        end
        ::continue::
    end
end

function Checker:checkClassOrInterfaceForDuplicateIndexSignatures(node)
    -- Only check the type once
    local links = self.declaredTypeLinks:Get(self:getSymbolOfDeclaration(node))
    if not links.indexSignaturesChecked then
        links.indexSignaturesChecked = true
        self:checkTypeForDuplicateIndexSignatures(node)
    end
end

function Checker:checkTypeForDuplicateIndexSignatures(node)
    -- TypeScript 1.0 spec (April 2014)
    -- 3.7.4: An object type can contain at most one string index signature and one numeric index signature.
    -- 8.5: A class declaration can have at most one string index member declaration and one numeric index member declaration
    local indexSymbol = self:getIndexSymbol(self:getSymbolOfDeclaration(node))
    if indexSymbol == nil or core.Len(indexSymbol.declarations) <= 1 then
        return
    end
    -- Go iterates a map[*Type][]*ast.Node; iterate in insertion order for determinism.
    local indexSignatureMap = {}
    local indexSignatureOrder = {}
    for _, declaration in ipairs(indexSymbol.declarations) do
        if ast.IsIndexSignatureDeclaration(declaration) then
            local parameters = declaration:Parameters()
            if #parameters == 1 and parameters[1]:Type() ~= nil then
                for _, t in ipairs(self:getTypeFromTypeNode(parameters[1]:Type()):Distributed()) do
                    local list = indexSignatureMap[t]
                    if list == nil then
                        list = {}
                        indexSignatureMap[t] = list
                        indexSignatureOrder[#indexSignatureOrder + 1] = t
                    end
                    list[#list + 1] = declaration
                end
            end
        end
        -- Do nothing for late-bound index signatures: allow these to duplicate one another and explicit indexes
    end
    for _, t in ipairs(indexSignatureOrder) do
        local declarations = indexSignatureMap[t]
        if #declarations > 1 then
            for _, declaration in ipairs(declarations) do
                self:error(declaration, diagnostics.Duplicate_index_signature_for_type_0, self:TypeToString(t))
            end
        end
    end
end

function Checker:checkPropertyInitialization(node)
    if not self.strictNullChecks or not self.strictPropertyInitialization or node.flags & NodeFlags.Ambient ~= 0 then
        return
    end
    local constructor = ast.FindConstructorDeclaration(node)
    for _, member in ipairs(node:Members()) do
        if member:ModifierFlags() & ModifierFlags.Ambient ~= 0 then
            goto continue
        end
        if not ast.IsStatic(member) and self:isPropertyWithoutInitializer(member) then
            local propName = member:Name()
            if ast.IsIdentifier(propName) or ast.IsPrivateIdentifier(propName) or ast.IsComputedPropertyName(propName) then
                local t = self:getTypeOfSymbol(self:getSymbolOfDeclaration(member))
                if not (t.flags & TypeFlags.AnyOrUnknown ~= 0 or self:containsUndefinedType(t)) then
                    if constructor == nil or not self:isPropertyInitializedInConstructor(propName, t, constructor) then
                        self:error(member:Name(), diagnostics.Property_0_has_no_initializer_and_is_not_definitely_assigned_in_the_constructor, scanner.DeclarationNameToString(propName))
                    end
                end
            end
        end
        ::continue::
    end
end

function Checker:isPropertyWithoutInitializer(node)
    return ast.IsPropertyDeclaration(node) and not ast.HasAbstractModifier(node) and not checker.isExclamationToken(node:PostfixToken()) and node:Initializer() == nil
end

function Checker:isPropertyInitializedInStaticBlocks(propName, propType, staticBlocks, startPos, endPos)
    for _, staticBlock in ipairs(staticBlocks or {}) do
        -- static block must be within the provided range as they are evaluated in document order (unlike constructors)
        if staticBlock:Pos() >= startPos and staticBlock:Pos() <= endPos then
            local reference = self.factory:NewPropertyAccessExpression(self.factory:NewKeywordExpression(Kind.ThisKeyword), nil, propName, NodeFlags.None)
            reference:Expression().parent = reference
            reference.parent = staticBlock
            reference:FlowNodeData().flowNode = staticBlock:AsClassStaticBlockDeclaration().returnFlowNode
            local flowType = self:getFlowTypeOfReferenceEx(reference, propType, self:getOptionalType(propType, false), nil, nil)
            if not self:containsUndefinedType(flowType) then
                return true
            end
        end
    end
    return false
end

function Checker:isPropertyInitializedInConstructor(propName, propType, constructor)
    local reference
    if ast.IsComputedPropertyName(propName) then
        reference = self.factory:NewElementAccessExpression(self.factory:NewKeywordExpression(Kind.ThisKeyword), nil, propName:Expression(), NodeFlags.None)
    else
        reference = self.factory:NewPropertyAccessExpression(self.factory:NewKeywordExpression(Kind.ThisKeyword), nil, propName, NodeFlags.None)
    end
    reference:Expression().parent = reference
    reference.parent = constructor
    reference:FlowNodeData().flowNode = constructor:AsConstructorDeclaration().returnFlowNode
    local flowType = self:getFlowTypeOfReferenceEx(reference, propType, self:getOptionalType(propType, false), nil, nil)
    return not self:containsUndefinedType(flowType)
end

function Checker:checkInterfaceDeclaration(node)
    if not self:checkGrammarModifiers(node) then
        self:checkGrammarInterfaceDeclaration(node:AsInterfaceDeclaration())
    end
    if not self:containerAllowsBlockScopedVariable(node.parent) then
        self:grammarErrorOnNode(node, diagnostics.X_0_declarations_can_only_be_declared_inside_a_block, "interface")
    end
    self:checkTypeParameters(node:TypeParameters())
    self:checkTypeNameIsReserved(node:Name(), diagnostics.Interface_name_cannot_be_0)
    self:checkExportsOnMergedDeclarations(node)
    local symbol = self:getSymbolOfDeclaration(node)
    self:checkTypeParameterListsIdentical(symbol)
    -- Only check this symbol once
    local links = self.declaredTypeLinks:Get(symbol)
    if not links.interfaceChecked then
        links.interfaceChecked = true
        local t = self:getDeclaredTypeOfSymbol(symbol)
        local typeWithThis = self:getTypeWithThisArgument(t, nil, false)
        -- run subsequent checks only if first set succeeded
        if self:checkInheritedPropertiesAreIdentical(t, node:Name()) then
            for _, baseType in ipairs(self:getBaseTypes(t) or {}) do
                self:checkTypeAssignableTo(typeWithThis, self:getTypeWithThisArgument(baseType, t:AsInterfaceType().thisType, false), node:Name(), diagnostics.Interface_0_incorrectly_extends_interface_1)
            end
            self:checkIndexConstraints(t, symbol --[[isStaticIndex]], false)
        end
    end
    self:checkObjectTypeForDuplicateDeclarations(node, false --[[checkPrivateNames]])
    for _, heritageElement in ipairs(ast.GetExtendsHeritageClauseElements(node) or {}) do
        if ast.IsExpressionWithTypeArguments(heritageElement) then
            local expr = heritageElement:Expression()
            if not ast.IsEntityNameExpression(expr) or ast.IsOptionalChain(expr) then
                self:error(expr, diagnostics.An_interface_can_only_extend_an_identifier_Slashqualified_name_with_optional_type_arguments)
            end
        end
        self:checkTypeReferenceNode(heritageElement)
    end
    self:checkSourceElements(node:Members())
    self:checkClassOrInterfaceForDuplicateIndexSignatures(node)
    self:registerForUnusedIdentifiersCheck(node)
end

-- InheritanceInfo
defineStruct("InheritanceInfo", nil, nil)

function Checker:checkInheritedPropertiesAreIdentical(t, typeNode)
    local baseTypes = self:getBaseTypes(t)
    if core.Len(baseTypes) < 2 then
        return true
    end
    local seen = {}
    for id, p in pairs(self:resolveDeclaredMembers(t).declaredMembers or {}) do
        if self:isNamedMember(p, id) then
            seen[p.name] = checker.InheritanceInfo_new({ prop = p, containingType = t })
        end
    end
    local identical = true
    for _, base in ipairs(baseTypes) do
        local properties = self:getPropertiesOfType(self:getTypeWithThisArgument(base, t:AsInterfaceType().thisType, false))
        for _, prop in ipairs(properties or {}) do
            local existing = seen[prop.name]
            if existing == nil then
                seen[prop.name] = checker.InheritanceInfo_new({ prop = prop, containingType = base })
            else
                local isInheritedProperty = existing.containingType ~= t
                if isInheritedProperty and not self:isPropertyIdenticalTo(existing.prop, prop) then
                    identical = false
                    local typeName1 = self:TypeToString(existing.containingType)
                    local typeName2 = self:TypeToString(base)
                    local errorInfo = checker.NewDiagnosticForNode(typeNode, diagnostics.Named_property_0_of_types_1_and_2_are_not_identical, self:symbolToString(prop), typeName1, typeName2)
                    self:addDiagnostic(ast.NewDiagnosticChain(errorInfo, diagnostics.Interface_0_cannot_simultaneously_extend_types_1_and_2, self:TypeToString(t), typeName1, typeName2))
                end
            end
        end
    end
    return identical
end

function Checker:isPropertyIdenticalTo(sourceProp, targetProp)
    return self:compareProperties(sourceProp, targetProp, self.compareTypesIdentical) ~= checker.Ternary.False
end

function Checker:checkEnumDeclaration(node)
    self:checkGrammarModifiers(node)
    self:checkCollisionsForDeclarationName(node, node:Name())
    self:checkExportsOnMergedDeclarations(node)
    self:checkSourceElements(node:Members())

    if self:shouldCheckErasableSyntax(node) and node.flags & NodeFlags.Ambient == 0 then
        self:error(node, diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled)
    end

    self:computeEnumMemberValues(node)
    -- Spec 2014 - Section 9.3:
    -- It isn't possible for one enum declaration to continue the automatic numbering sequence of another,
    -- and when an enum type has multiple declarations, only one declaration is permitted to omit a value
    -- for the first member.
    --
    -- Only perform this check once per symbol
    local enumSymbol = self:getSymbolOfDeclaration(node)
    local links = self.declaredTypeLinks:Get(enumSymbol)
    if not links.enumChecked then
        links.enumChecked = true
        if core.Len(enumSymbol.declarations) > 1 then
            local enumIsConst = ast.IsEnumConst(node)
            -- check that const is placed\omitted on all enum declarations
            for _, decl in ipairs(enumSymbol.declarations) do
                if ast.IsEnumDeclaration(decl) and ast.IsEnumConst(decl) ~= enumIsConst then
                    self:error(ast.GetNameOfDeclaration(decl), diagnostics.Enum_declarations_must_all_be_const_or_non_const)
                end
            end
        end
        local seenEnumMissingInitialInitializer = false
        for _, declaration in ipairs(enumSymbol.declarations or {}) do
            -- return true if we hit a violation of the rule, false otherwise
            if declaration.kind ~= Kind.EnumDeclaration then
                goto continue
            end
            do
                local members = declaration:Members()
                if core.Len(members) == 0 then
                    goto continue
                end
                local firstEnumMember = members[1]
                if firstEnumMember:Initializer() == nil then
                    if seenEnumMissingInitialInitializer then
                        self:error(firstEnumMember:Name(), diagnostics.In_an_enum_with_multiple_declarations_only_one_declaration_can_omit_an_initializer_for_its_first_enum_element)
                    else
                        seenEnumMissingInitialInitializer = true
                    end
                end
            end
            ::continue::
        end
    end
end

function Checker:checkEnumMember(node)
    if ast.IsPrivateIdentifier(node:Name()) then
        self:error(node, diagnostics.An_enum_member_cannot_be_named_with_a_private_identifier)
    end
    if node:Initializer() ~= nil then
        self:checkExpression(node:Initializer())
    end
end

function Checker:checkModuleDeclaration(node)
    local body = node:Body()
    if body ~= nil then
        self:checkSourceElement(body)
        if not ast.IsGlobalScopeAugmentation(node) then
            self:registerForUnusedIdentifiersCheck(node)
        end
    end
    local isGlobalAugmentation = ast.IsGlobalScopeAugmentation(node)
    local inAmbientContext = node.flags & NodeFlags.Ambient ~= 0
    if isGlobalAugmentation and not inAmbientContext then
        self:error(node:Name(), diagnostics.Augmentations_for_the_global_scope_should_have_declare_modifier_unless_they_appear_in_already_ambient_context)
    end
    local isAmbientExternalModule = ast.IsAmbientModule(node)
    local contextErrorMessage = core.IfElse(isAmbientExternalModule,
        diagnostics.An_ambient_module_declaration_is_only_allowed_at_the_top_level_in_a_file,
        diagnostics.A_namespace_declaration_is_only_allowed_at_the_top_level_of_a_namespace_or_module)
    if self:checkGrammarModuleElementContext(node, contextErrorMessage) then
        -- If we hit a module declaration in an illegal context, just bail out to avoid cascading errors.
        return
    end
    if not self:checkGrammarModifiers(node) then
        if not inAmbientContext and ast.IsStringLiteral(node:Name()) then
            self:grammarErrorOnNode(node:Name(), diagnostics.Only_ambient_modules_can_use_quoted_names)
        end
    end
    if ast.IsIdentifier(node:Name()) then
        self:checkCollisionsForDeclarationName(node, node:Name())
        if node:AsModuleDeclaration().keyword == Kind.ModuleKeyword then
            self:error(node:Name(), diagnostics.A_namespace_declaration_should_not_be_declared_using_the_module_keyword_Please_use_the_namespace_keyword_instead)
        end
    end
    self:checkExportsOnMergedDeclarations(node)
    local symbol = self:getSymbolOfDeclaration(node)
    -- The following checks only apply on a non-ambient instantiated module declaration.
    if symbol.flags & SymbolFlags.ValueModule ~= 0 and not inAmbientContext and checker.isInstantiatedModule(node, self.compilerOptions:ShouldPreserveConstEnums()) then
        if self:shouldCheckErasableSyntax(node) then
            self:error(node, diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled)
        end
        if self.compilerOptions:GetIsolatedModules() and ast.GetSourceFileOfNode(node).externalModuleIndicator == nil then
            -- This could be loosened a little if needed. The only problem we are trying to avoid is unqualified
            -- references to namespace members declared in other files. But use of namespaces is discouraged anyway,
            -- so for now we will just not allow them in scripts, which is the only place they can merge cross-file.
            self:error(node:Name(), diagnostics.Namespaces_are_not_allowed_in_global_script_files_when_0_is_enabled_If_this_file_is_not_intended_to_be_a_global_script_set_moduleDetection_to_force_or_add_an_empty_export_statement, self:getIsolatedModulesLikeFlagName())
        end
        if core.Len(symbol.declarations) > 1 then
            local firstNonAmbientClassOrFunc = checker.getFirstNonAmbientClassOrFunctionDeclaration(symbol)
            if firstNonAmbientClassOrFunc ~= nil then
                if ast.GetSourceFileOfNode(node) ~= ast.GetSourceFileOfNode(firstNonAmbientClassOrFunc) then
                    self:error(node:Name(), diagnostics.A_namespace_declaration_cannot_be_in_a_different_file_from_a_class_or_function_with_which_it_is_merged)
                elseif node:Pos() < firstNonAmbientClassOrFunc:Pos() then
                    self:error(node:Name(), diagnostics.A_namespace_declaration_cannot_be_located_prior_to_a_class_or_function_with_which_it_is_merged)
                end
            end
        end
        if core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax) and ast.IsSourceFile(node.parent) and node:ModifierFlags() & ModifierFlags.Export ~= 0 and self.program:GetEmitModuleFormatOfFile(node.parent:AsSourceFile()) == ModuleKind.CommonJS then
            local exportModifier = core.Find(node:ModifierNodes(), function(m) return m.kind == Kind.ExportKeyword end)
            self:error(exportModifier, diagnostics.A_top_level_export_modifier_cannot_be_used_on_value_declarations_in_a_CommonJS_module_when_verbatimModuleSyntax_is_enabled)
        end
    end
    if isAmbientExternalModule then
        if ast.IsExternalModuleAugmentation(node) then
            -- body of the augmentation should be checked for consistency only if augmentation was applied to its target (either global scope or module)
            -- otherwise we'll be swamped in cascading errors.
            -- We can detect if augmentation was applied using following rules:
            -- - augmentation for a global scope is always applied
            -- - augmentation for some external module is applied if symbol for augmentation is merged (it was combined with target module).
            local checkBody = isGlobalAugmentation or self:getSymbolOfDeclaration(node).flags & SymbolFlags.Transient ~= 0
            if checkBody and node:Body() ~= nil then
                for _, statement in ipairs(node:Body():Statements()) do
                    self:checkModuleAugmentationElement(statement)
                end
            end
        elseif ast.IsGlobalSourceFile(node.parent) then
            if isGlobalAugmentation then
                self:error(node:Name(), diagnostics.Augmentations_for_the_global_scope_can_only_be_directly_nested_in_external_modules_or_ambient_module_declarations)
            elseif tspath.IsExternalModuleNameRelative(node:Name():Text()) then
                self:error(node:Name(), diagnostics.Ambient_module_declaration_cannot_specify_relative_module_name)
            end
        else
            if isGlobalAugmentation then
                self:error(node:Name(), diagnostics.Augmentations_for_the_global_scope_can_only_be_directly_nested_in_external_modules_or_ambient_module_declarations)
            else
                -- Node is not an augmentation and is not located on the script level.
                -- This means that this is declaration of ambient module that is located in other module or namespace which is prohibited.
                self:error(node:Name(), diagnostics.Ambient_modules_cannot_be_nested_in_other_modules_or_namespaces)
            end
        end
    end
end

function checker.isInstantiatedModule(node, preserveConstEnums)
    local moduleState = ast.GetModuleInstanceState(node)
    return moduleState == ast.ModuleInstanceState.Instantiated or preserveConstEnums and moduleState == ast.ModuleInstanceState.ConstEnumOnly
end

function checker.getFirstNonAmbientClassOrFunctionDeclaration(symbol)
    for _, declaration in ipairs(symbol.declarations or {}) do
        if (ast.IsClassDeclaration(declaration) or ast.IsFunctionDeclaration(declaration) and ast.NodeIsPresent(declaration:Body())) and declaration.flags & NodeFlags.Ambient == 0 then
            return declaration
        end
    end
    return nil
end

function Checker:getIsolatedModulesLikeFlagName()
    return core.IfElse(core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax), "verbatimModuleSyntax", "isolatedModules")
end

function Checker:checkModuleAugmentationElement(node)
    local k = node.kind
    if k == Kind.VariableStatement then
        -- error each individual name in variable statement instead of marking the entire variable statement
        for _, decl in ipairs(node:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes) do
            self:checkModuleAugmentationElement(decl)
        end
    elseif k == Kind.ExportAssignment or k == Kind.ExportDeclaration then
        self:grammarErrorOnFirstToken(node, diagnostics.Exports_and_export_assignments_are_not_permitted_in_module_augmentations)
    elseif k == Kind.ImportEqualsDeclaration or k == Kind.ImportDeclaration or k == Kind.JSImportDeclaration then
        -- import a = e.x; in module augmentation is ok, but not import a = require('fs)
        if k == Kind.ImportEqualsDeclaration and ast.IsInternalModuleImportEqualsDeclaration(node) then
            return
        end
        self:grammarErrorOnFirstToken(node, diagnostics.Imports_are_not_permitted_in_module_augmentations_Consider_moving_them_to_the_enclosing_external_module)
    elseif k == Kind.BindingElement or k == Kind.VariableDeclaration then
        local name = node:Name()
        if ast.IsBindingPattern(name) then
            for _, el in ipairs(name:Elements()) do
                -- mark individual names in binding pattern
                self:checkModuleAugmentationElement(el)
            end
        end
    end
end

function Checker:checkImportDeclaration(node)
    -- Grammar checking
    local diagnostic
    if ast.IsInJSFile(node) then
        diagnostic = diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_module
    else
        diagnostic = diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_namespace_or_module
    end
    if self:checkGrammarModuleElementContext(node, diagnostic) then
        -- If we hit an import declaration in an illegal context, just bail out to avoid cascading errors.
        self:checkExternalModuleNameInGlobalScope(node)
        return
    end
    if not self:checkGrammarModifiers(node) and node:Modifiers() ~= nil then
        self:grammarErrorOnFirstToken(node, diagnostics.An_import_declaration_cannot_have_modifiers)
    end
    if self:checkExternalImportOrExportDeclaration(node) then
        local resolvedModule
        local importClause = node:ImportClause()
        local moduleSpecifier = node:ModuleSpecifier()
        if importClause ~= nil and not self:checkGrammarImportClause(importClause:AsImportClause()) then
            if importClause:Name() ~= nil then
                self:checkImportBinding(importClause)
            end
            local needsImportStar = false
            local namedBindings = importClause:AsImportClause().namedBindings
            if namedBindings ~= nil then
                if ast.IsNamespaceImport(namedBindings) then
                    self:checkImportBinding(namedBindings)
                    if self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS then
                        -- import * as ns from "foo";
                        needsImportStar = true
                        self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ImportStar)
                    end
                else
                    resolvedModule = self:resolveExternalModuleName(node, node:ModuleSpecifier(), false)
                    if resolvedModule ~= nil then
                        for _, binding in ipairs(namedBindings:Elements()) do
                            self:checkImportBinding(binding)
                        end
                    end
                end
            end
            if importClause:Name() ~= nil and
                not needsImportStar and
                self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS then
                -- import d from "foo";
                self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ImportDefault)
            end

            if not importClause:IsTypeOnly() and
                ModuleKind.Node18 <= self.moduleKind and self.moduleKind <= ModuleKind.NodeNext and
                self:isOnlyImportableAsDefault(moduleSpecifier, resolvedModule) and
                not checker.hasTypeJsonImportAttribute(node) then
                self:error(moduleSpecifier, diagnostics.Importing_a_JSON_file_into_an_ECMAScript_module_requires_a_type_Colon_json_import_attribute_when_module_is_set_to_0, core.ModuleKind_String(self.moduleKind))
            end
        elseif core.Tristate_IsTrueOrUnknown(self.compilerOptions.noUncheckedSideEffectImports) and importClause == nil then
            local ignoreErrors = core.Tristate_IsTrue(self.compilerOptions.noCheck)
            local errorMessage
            if not ignoreErrors then
                errorMessage = diagnostics.Cannot_find_module_or_type_declarations_for_side_effect_import_of_0
            end
            self:resolveExternalModuleNameWorker(node, moduleSpecifier, errorMessage, ignoreErrors, false --[[isForAugmentation]])
        end
    end
    self:checkImportAttributes(node)
end

function Checker:checkExternalImportOrExportDeclaration(node)
    local moduleName = ast.GetExternalModuleName(node)
    if moduleName == nil or ast.NodeIsMissing(moduleName) then
        -- Should be a parse error.
        return false
    end
    if not ast.IsStringLiteral(moduleName) then
        self:error(moduleName, diagnostics.String_literal_expected)
        return false
    end
    local inAmbientExternalModule = ast.IsModuleBlock(node.parent) and ast.IsAmbientModule(node.parent.parent)
    if not ast.IsSourceFile(node.parent) and not inAmbientExternalModule then
        self:error(moduleName, core.IfElse(ast.IsExportDeclaration(node), diagnostics.Export_declarations_are_not_permitted_in_a_namespace, diagnostics.Import_declarations_in_a_namespace_cannot_reference_a_module))
        return false
    end
    if inAmbientExternalModule and tspath.IsExternalModuleNameRelative(moduleName:Text()) then
        -- we have already reported errors on top level imports/exports in external module augmentations in checkModuleDeclaration
        -- no need to do this again.
        if not checker.isTopLevelInExternalModuleAugmentation(node) then
            -- TypeScript 1.0 spec (April 2013): 12.1.6
            -- An ExternalImportDeclaration in an AmbientExternalModuleDeclaration may reference
            -- other external modules only through top - level external module names.
            -- Relative external module names are not permitted.
            self:error(node, diagnostics.Import_or_export_declaration_in_an_ambient_module_declaration_cannot_reference_module_through_relative_module_name)
            return false
        end
    end
    if not ast.IsImportEqualsDeclaration(node) then
        local attributes = ast.GetImportAttributes(node)
        if attributes ~= nil then
            local hasError = false
            for _, attr in ipairs(attributes:AsImportAttributes().attributes.nodes) do
                if not ast.IsStringLiteral(attr:AsImportAttribute().value) then
                    hasError = true
                    self:error(attr:AsImportAttribute().value, diagnostics.Import_attribute_values_must_be_string_literal_expressions)
                end
            end
            return not hasError
        end
    end
    return true
end

function Checker:checkImportBinding(node)
    self:checkCollisionsForDeclarationName(node, node:Name())
    self:checkAliasSymbol(node)
    if ast.IsImportSpecifier(node) then
        self:checkModuleExportName(node:PropertyName(), true --[[allowStringLiteral]])
        if ast.ModuleExportNameIsDefault(node:PropertyNameOrName()) and
            self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS then
            self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ImportDefault)
        end
    end
end

function Checker:checkModuleExportName(name, allowStringLiteral)
    if name == nil or name.kind ~= Kind.StringLiteral then
        return
    end
    if not allowStringLiteral then
        self:grammarErrorOnNode(name, diagnostics.Identifier_expected)
    elseif self.moduleKind == ModuleKind.ES2015 or self.moduleKind == ModuleKind.ES2020 then
        if not ast.GetSourceFileOfNode(name).isDeclarationFile then
            self:grammarErrorOnNode(name, diagnostics.String_literal_import_and_export_names_are_not_supported_when_the_module_flag_is_set_to_es2015_or_es2020)
        end
    end
end

function checker.hasTypeJsonImportAttribute(node)
    local attributes = node:AsImportDeclaration().attributes
    return attributes ~= nil and core.Some(attributes:AsImportAttributes().attributes.nodes, function(attr)
        return attr:Name():Text() == "type" and ast.IsStringLiteralLike(attr:AsImportAttribute().value) and attr:AsImportAttribute().value:Text() == "json"
    end)
end

function Checker:checkImportAttributes(declaration)
    local node = ast.GetImportAttributes(declaration)
    if node == nil then
        return
    end
    local importAttributesType = self.getGlobalImportAttributesTypeChecked()
    if importAttributesType ~= self.emptyObjectType then
        self:checkTypeAssignableTo(self:getTypeFromImportAttributes(node), self:getNullableType(importAttributesType, TypeFlags.Undefined), node, nil)
    end
    local isTypeOnly = ast.IsExclusivelyTypeOnlyImportOrExport(declaration)
    local override = self:getResolutionModeOverride(node:AsImportAttributes(), isTypeOnly)
    if isTypeOnly and override ~= ModuleKind.ResolutionModeNone then
        return -- Other grammar checks do not apply to type-only imports with resolution mode attributes
    end

    if not core.ModuleKind_SupportsImportAttributes(self.moduleKind) then
        self:grammarErrorOnNode(node, diagnostics.Import_attributes_are_only_supported_when_the_module_option_is_set_to_esnext_node18_node20_nodenext_or_preserve)
        return
    end

    local moduleSpecifier = checker.getModuleSpecifierFromNode(declaration)
    if moduleSpecifier ~= nil then
        if self:getEmitSyntaxForModuleSpecifierExpression(moduleSpecifier) == ModuleKind.CommonJS then
            self:grammarErrorOnNode(node, diagnostics.Import_attributes_are_not_allowed_on_statements_that_compile_to_CommonJS_require_calls)
            return
        end
    end

    if isTypeOnly then
        self:grammarErrorOnNode(node, diagnostics.Import_attributes_cannot_be_used_with_type_only_imports_or_exports)
        return
    end
    if override ~= ModuleKind.ResolutionModeNone then
        self:grammarErrorOnNode(node, diagnostics.X_resolution_mode_can_only_be_set_for_type_only_imports)
    end
end

function Checker:getTypeFromImportAttributes(node)
    local links = self.typeNodeLinks:Get(node)
    if links.resolvedType == nil then
        local symbol = self:newSymbol(SymbolFlags.ObjectLiteral, ast.InternalSymbolNameImportAttributes)
        local members = ast.NewSymbolTable()
        for _, attr in ipairs(node:AsImportAttributes().attributes.nodes) do
            local member = self:newSymbol(SymbolFlags.Property, attr:Name():Text())
            self.valueSymbolLinks:Get(member).resolvedType = self:getRegularTypeOfLiteralType(self:checkExpression(attr:AsImportAttribute().value))
            members[member.name] = member
        end
        local t = self:newAnonymousType(symbol, members, nil, nil, nil)
        t.objectFlags = t.objectFlags | ObjectFlags.ObjectLiteral | ObjectFlags.NonInferrableType
        links.resolvedType = t
    end
    return links.resolvedType
end

function Checker:checkImportEqualsDeclaration(node)
    local diagnostic = core.IfElse(ast.IsInJSFile(node),
        diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_module,
        diagnostics.An_import_declaration_can_only_be_used_at_the_top_level_of_a_namespace_or_module)
    if self:checkGrammarModuleElementContext(node, diagnostic) then
        self:checkExternalModuleNameInGlobalScope(node)
        return -- If we hit an import declaration in an illegal context, just bail out to avoid cascading errors.
    end
    self:checkGrammarModifiers(node)
    if self:shouldCheckErasableSyntax(node) and node.flags & NodeFlags.Ambient == 0 then
        self:error(node, diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled)
    end
    if ast.IsInternalModuleImportEqualsDeclaration(node) or self:checkExternalImportOrExportDeclaration(node) then
        self:checkImportBinding(node)
        self:markLinkedReferences(node, ReferenceHint.ExportImportEquals, nil, nil)
        local moduleReference = node:AsImportEqualsDeclaration().moduleReference
        if not ast.IsExternalModuleReference(moduleReference) then
            local target = self:resolveAlias(self:getSymbolOfDeclaration(node))
            if target ~= self.unknownSymbol then
                local targetFlags = self:getSymbolFlags(target)
                if targetFlags & SymbolFlags.Value ~= 0 then
                    -- Target is a value symbol, check that it is not hidden by a local declaration with the same name
                    local moduleName = ast.GetFirstIdentifier(moduleReference)
                    if self:resolveEntityName(moduleName, SymbolFlags.Value | SymbolFlags.Namespace, false, false, nil).flags & SymbolFlags.Namespace == 0 then
                        self:error(moduleName, diagnostics.Module_0_is_hidden_by_a_local_declaration_with_the_same_name, scanner.DeclarationNameToString(moduleName))
                    end
                end
                if targetFlags & SymbolFlags.Type ~= 0 then
                    self:checkTypeNameIsReserved(node:Name(), diagnostics.Import_name_cannot_be_0)
                end
            end
            if node:IsTypeOnly() then
                self:grammarErrorOnNode(node, diagnostics.An_import_alias_cannot_use_import_type)
            end
        else
            if ModuleKind.ES2015 <= self.moduleKind and self.moduleKind <= ModuleKind.ESNext and not node:IsTypeOnly() and node.flags & NodeFlags.Ambient == 0 then
                -- Import equals declaration cannot be emitted as ESM
                self:grammarErrorOnNode(node, diagnostics.Import_assignment_cannot_be_used_when_targeting_ECMAScript_modules_Consider_using_import_Asterisk_as_ns_from_mod_import_a_from_mod_import_d_from_mod_or_another_module_format_instead)
            end
        end
    end
end

function Checker:checkExportDeclaration(node)
    local diagnostic = core.IfElse(ast.IsInJSFile(node),
        diagnostics.An_export_declaration_can_only_be_used_at_the_top_level_of_a_module,
        diagnostics.An_export_declaration_can_only_be_used_at_the_top_level_of_a_namespace_or_module)
    if self:checkGrammarModuleElementContext(node, diagnostic) then
        self:checkExternalModuleNameInGlobalScope(node)
        return -- If we hit an export in an illegal context, just bail out to avoid cascading errors.
    end
    local exportDecl = node:AsExportDeclaration()
    if not self:checkGrammarModifiers(node) and exportDecl:Modifiers() ~= nil then
        self:grammarErrorOnFirstToken(node, diagnostics.An_export_declaration_cannot_have_modifiers)
    end
    self:checkGrammarExportDeclaration(exportDecl)
    if exportDecl.moduleSpecifier == nil or self:checkExternalImportOrExportDeclaration(node) then
        if exportDecl.exportClause ~= nil and not ast.IsNamespaceExport(exportDecl.exportClause) then
            -- export { x, y }
            -- export { x, y } from "foo"
            for _, binding in ipairs(exportDecl.exportClause:Elements()) do
                self:checkExportSpecifier(binding)
            end
            local inAmbientExternalModule = ast.IsModuleBlock(node.parent) and ast.IsAmbientModule(node.parent.parent)
            local inAmbientNamespaceDeclaration = not inAmbientExternalModule and ast.IsModuleBlock(node.parent) and exportDecl.moduleSpecifier == nil and node.flags & NodeFlags.Ambient ~= 0
            if not ast.IsSourceFile(node.parent) and not inAmbientExternalModule and not inAmbientNamespaceDeclaration then
                self:error(node, diagnostics.Export_declarations_are_not_permitted_in_a_namespace)
            end
        else
            -- export * from "foo"
            -- export * as ns from "foo";
            local moduleSymbol = self:resolveExternalModuleName(node, exportDecl.moduleSpecifier, false)
            if moduleSymbol ~= nil and checker.hasExportAssignmentSymbol(moduleSymbol) then
                self:error(exportDecl.moduleSpecifier, diagnostics.Module_0_uses_export_and_cannot_be_used_with_export_Asterisk, self:symbolToString(moduleSymbol))
            elseif exportDecl.exportClause ~= nil then
                self:checkAliasSymbol(exportDecl.exportClause)
                self:checkModuleExportName(exportDecl.exportClause:Name(), true --[[allowStringLiteral]])
            end
            if self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS then
                if node:AsExportDeclaration().exportClause ~= nil then
                    -- export * as ns from "foo";
                    self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ImportStar)
                else
                    -- export * from "foo"
                    self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ExportStar)
                end
            end
        end
    end
    self:checkImportAttributes(node)
end

function Checker:checkExternalModuleNameInGlobalScope(node)
    if checker.getEnclosingContainer(node).kind ~= Kind.SourceFile or (ast.IsImportDeclarationOrJSImportDeclaration(node) and node:ImportClause() == nil) then
        return
    end
    local moduleName = ast.GetExternalModuleName(node)
    if moduleName ~= nil then
        self:resolveExternalModuleName(node, moduleName, false)
    end
end

function Checker:checkExportSpecifier(node)
    self:checkAliasSymbol(node)
    local hasModuleSpecifier = node.parent.parent:ModuleSpecifier() ~= nil
    self:checkModuleExportName(node:PropertyName(), hasModuleSpecifier)
    self:checkModuleExportName(node:Name(), true --[[allowStringLiteral]])

    if not hasModuleSpecifier then
        local exportedName = node:PropertyNameOrName()
        if exportedName.kind == Kind.StringLiteral then
            return -- Skip for invalid syntax like this: export { "x" }
        end
        -- find immediate value referenced by exported name (SymbolFlags.Alias is set so we don't chase down aliases)
        local symbol = self.resolveName(exportedName, exportedName:Text(), SymbolFlags.Value | SymbolFlags.Type | SymbolFlags.Namespace | SymbolFlags.Alias, nil --[[nameNotFoundMessage]], true --[[isUse]], false)
        if symbol ~= nil and (symbol == self.undefinedSymbol or symbol == self.globalThisSymbol or symbol.declarations ~= nil and ast.IsGlobalSourceFile(ast.GetDeclarationContainer(symbol.declarations[1]))) then
            self:error(exportedName, diagnostics.Cannot_export_0_Only_local_declarations_can_be_exported_from_a_module, exportedName:Text())
        else
            self:markLinkedReferences(node, ReferenceHint.ExportSpecifier, nil --[[propSymbol]], nil --[[parentType]])
        end
    elseif self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS and
        ast.ModuleExportNameIsDefault(node:PropertyNameOrName()) then
        self:checkExternalEmitHelpers(node, ExternalEmitHelpers.ImportDefault)
    end
end

function checker.isContainedByNamespace(node)
    local container = node.parent
    if not ast.IsSourceFile(container) then
        container = container.parent
    end
    return ast.IsModuleDeclaration(container) and not ast.IsAmbientModule(container)
end

function Checker:checkExportAssignment(node)
    local isExportEquals = node:AsExportAssignment().isExportEquals
    -- Always check the exported expression so its identifiers are resolved even when the
    -- export assignment is misplaced (grammar error), keeping diagnostics stable
    -- regardless of traversal order.
    local exprType = self:checkExpressionCached(node:Expression())
    local illegalContextMessage = core.IfElse(isExportEquals,
        diagnostics.An_export_assignment_must_be_at_the_top_level_of_a_file_or_module_declaration,
        diagnostics.A_default_export_must_be_at_the_top_level_of_a_file_or_module_declaration)
    if self:checkGrammarModuleElementContext(node, illegalContextMessage) then
        return -- If we hit an export assignment in an illegal context, just bail out to avoid cascading errors.
    end
    if self:shouldCheckErasableSyntax(node) and node:AsExportAssignment().isExportEquals and node.flags & NodeFlags.Ambient == 0 then
        self:error(node, diagnostics.This_syntax_is_not_allowed_when_erasableSyntaxOnly_is_enabled)
    end
    if checker.isContainedByNamespace(node) then
        -- TODO(danielr): should these be grammar errors?
        if isExportEquals then
            self:error(node, diagnostics.An_export_assignment_cannot_be_used_in_a_namespace)
        else
            self:error(node, diagnostics.A_default_export_can_only_be_used_in_an_ECMAScript_style_module)
        end
        return
    end
    if not self:checkGrammarModifiers(node) and ast.IsExportAssignment(node) and node:AsExportAssignment():Modifiers() ~= nil then
        self:grammarErrorOnFirstToken(node, diagnostics.An_export_assignment_cannot_have_modifiers)
    end
    local isIllegalExportDefaultInCJS = not isExportEquals and node.flags & NodeFlags.Ambient == 0 and core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax) and self.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS
    if ast.IsIdentifier(node:Expression()) then
        local id = node:Expression()
        local sym = self:getExportSymbolOfValueSymbolIfExported(self:resolveEntityName(id, SymbolFlags.All, true --[[ignoreErrors]], true --[[dontResolveAlias]], node))
        if sym ~= nil then
            self:markLinkedReferences(node, ReferenceHint.ExportAssignment, nil, nil)
            local typeOnlyDeclaration = self:getTypeOnlyAliasDeclarationEx(sym, SymbolFlags.Value)
            -- If not a value, we're interpreting the identifier as a type export, along the lines of (`export { Id as default }`)
            if self:getSymbolFlags(sym) & SymbolFlags.Value ~= 0 then
                -- However if it is a value, we need to check it's being used correctly
                if not isIllegalExportDefaultInCJS and node.flags & NodeFlags.Ambient == 0 and core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax) and typeOnlyDeclaration ~= nil then
                    local message = core.IfElse(isExportEquals,
                        diagnostics.An_export_declaration_must_reference_a_real_value_when_verbatimModuleSyntax_is_enabled_but_0_resolves_to_a_type_only_declaration,
                        diagnostics.An_export_default_must_reference_a_real_value_when_verbatimModuleSyntax_is_enabled_but_0_resolves_to_a_type_only_declaration)
                    self:error(id, message, id:Text())
                end
            elseif not isIllegalExportDefaultInCJS and node.flags & NodeFlags.Ambient == 0 and core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax) then
                local message = core.IfElse(isExportEquals,
                    diagnostics.An_export_declaration_must_reference_a_value_when_verbatimModuleSyntax_is_enabled_but_0_only_refers_to_a_type,
                    diagnostics.An_export_default_must_reference_a_value_when_verbatimModuleSyntax_is_enabled_but_0_only_refers_to_a_type)
                self:error(id, message, id:Text())
            end
            if not isIllegalExportDefaultInCJS and node.flags & NodeFlags.Ambient == 0 and self.compilerOptions:GetIsolatedModules() and sym.flags & SymbolFlags.Value == 0 then
                local nonLocalMeanings = self:getSymbolFlagsEx(sym, false --[[excludeTypeOnlyMeanings]], true --[[excludeLocalMeanings]])
                if sym.flags & SymbolFlags.Alias ~= 0 and nonLocalMeanings & SymbolFlags.Type ~= 0 and nonLocalMeanings & SymbolFlags.Value == 0 and (typeOnlyDeclaration == nil or ast.GetSourceFileOfNode(typeOnlyDeclaration) ~= ast.GetSourceFileOfNode(node)) then
                    -- import { SomeType } from "./someModule";
                    -- export default SomeType; OR
                    -- export = SomeType;
                    local message = core.IfElse(isExportEquals,
                        diagnostics.X_0_resolves_to_a_type_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_import_type_where_0_is_imported,
                        diagnostics.X_0_resolves_to_a_type_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_export_type_0_as_default)
                    self:error(id, message, id:Text(), self:getIsolatedModulesLikeFlagName())
                elseif typeOnlyDeclaration ~= nil and ast.GetSourceFileOfNode(typeOnlyDeclaration) ~= ast.GetSourceFileOfNode(node) then
                    -- import { SomeTypeOnlyValue } from "./someModule";
                    -- export default SomeTypeOnlyValue; OR
                    -- export = SomeTypeOnlyValue;
                    local message = core.IfElse(isExportEquals,
                        diagnostics.X_0_resolves_to_a_type_only_declaration_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_import_type_where_0_is_imported,
                        diagnostics.X_0_resolves_to_a_type_only_declaration_and_must_be_marked_type_only_in_this_file_before_re_exporting_when_1_is_enabled_Consider_using_export_type_0_as_default)
                    self:addTypeOnlyDeclarationRelatedInfo(self:error(id, message, id:Text(), self:getIsolatedModulesLikeFlagName()), typeOnlyDeclaration, id:Text())
                end
            end
        end
    end
    if isIllegalExportDefaultInCJS then
        self:error(node, checker.getVerbatimModuleSyntaxErrorMessage(node))
    end
    local container = node.parent
    if not ast.IsSourceFile(container) then
        container = container.parent
    end
    self:checkExternalModuleExports(container)
    local typeNode = node:Type()
    if typeNode ~= nil and node.kind == Kind.ExportAssignment then
        local t = self:getTypeFromTypeNode(typeNode)
        self:checkTypeAssignableToAndOptionallyElaborate(exprType, t, node:Expression(), node:Expression(), nil --[[headMessage]], nil)
    end
    if (node.flags & NodeFlags.Ambient ~= 0) and not ast.IsEntityNameExpression(node:Expression()) then
        self:grammarErrorOnNode(node:Expression(), diagnostics.The_expression_of_an_export_assignment_must_be_an_identifier_or_qualified_name_in_an_ambient_context)
    end
    if isExportEquals then
        -- Forbid export= in esm implementation files, and esm mode declaration files
        if self.moduleKind >= ModuleKind.ES2015 and self.moduleKind ~= ModuleKind.Preserve and ((node.flags & NodeFlags.Ambient ~= 0 and self.program:GetImpliedNodeFormatForEmit(ast.GetSourceFileOfNode(node)) == ModuleKind.ESNext) or (node.flags & NodeFlags.Ambient == 0 and self.program:GetImpliedNodeFormatForEmit(ast.GetSourceFileOfNode(node)) ~= ModuleKind.CommonJS)) then
            -- export assignment is not supported in es6 modules
            self:grammarErrorOnNode(node, diagnostics.Export_assignment_cannot_be_used_when_targeting_ECMAScript_modules_Consider_using_export_default_or_another_module_format_instead)
        elseif self.moduleKind == ModuleKind.System and node.flags & NodeFlags.Ambient == 0 then
            -- system modules does not support export assignment
            self:grammarErrorOnNode(node, diagnostics.Export_assignment_is_not_supported_when_module_flag_is_system)
        end
    end
end

function checker.getVerbatimModuleSyntaxErrorMessage(node)
    local sourceFile = ast.GetSourceFileOfNode(node)
    local fileName = sourceFile:FileName()

    -- Check if the file is .cts or .cjs (CommonJS-specific extensions)
    if tspath.FileExtensionIsOneOf(fileName, { tspath.ExtensionCts, tspath.ExtensionCjs }) then
        return diagnostics.ECMAScript_imports_and_exports_cannot_be_written_in_a_CommonJS_file_under_verbatimModuleSyntax
    end
    -- For .ts, .tsx, .js, etc.
    return diagnostics.ECMAScript_imports_and_exports_cannot_be_written_in_a_CommonJS_file_under_verbatimModuleSyntax_Adjust_the_type_field_in_the_nearest_package_json_to_make_this_file_an_ECMAScript_module_or_adjust_your_verbatimModuleSyntax_module_and_moduleResolution_settings_in_TypeScript
end

function Checker:checkExternalModuleExports(node)
    local moduleSymbol = self:getSymbolOfDeclaration(node)
    local links = self.moduleSymbolLinks:Get(moduleSymbol)
    if not links.exportsChecked then
        local exportEqualsSymbol = moduleSymbol.exports ~= nil and moduleSymbol.exports[ast.InternalSymbolNameExportEquals] or nil
        -- An export assignment is in error if (a) the module exports value members or (b) if the module exports type or
        -- namespace members and the exported entity also exports type or namespace members.
        if exportEqualsSymbol ~= nil and (self:hasExportedMembersOfKind(moduleSymbol, SymbolFlags.Value) or self:hasShadowedNamespace(exportEqualsSymbol)) then
            local declaration = self:getDeclarationOfAliasSymbol(exportEqualsSymbol) or exportEqualsSymbol.valueDeclaration
            if declaration ~= nil and not checker.isTopLevelInExternalModuleAugmentation(declaration) then
                self:error(declaration, diagnostics.An_export_assignment_cannot_be_used_in_a_module_with_other_exported_elements)
            end
        end
        -- Checks for export * conflicts
        for id, symbol in pairs(self:getExportsOfModule(moduleSymbol) or {}) do
            if id == ast.InternalSymbolNameExportStar then
                goto continue
            end
            -- ECMA262: 15.2.1.1 It is a Syntax Error if the ExportedNames of ModuleItemList contains any duplicate entries.
            -- (TS Exceptions: namespaces, function overloads, enums, and interfaces)
            if symbol.flags & (SymbolFlags.Namespace | SymbolFlags.Enum) ~= 0 then
                goto continue
            end
            do
                local exportedDeclarationsCount = core.CountWhere(symbol.declarations, function(d)
                    return checker.isNotOverload(d) and not ast.IsAccessor(d) and not ast.IsInterfaceDeclaration(d)
                end)
                if symbol.flags & SymbolFlags.TypeAlias ~= 0 and exportedDeclarationsCount <= 2 then
                    -- it is legal to merge type alias with other values
                    -- so count should be either 1 (just type alias) or 2 (type alias + merged value)
                    goto continue
                end
                if exportedDeclarationsCount > 1 and not core.Every(symbol.declarations, function(n)
                    return ast.GetAssignmentDeclarationKind(n) == ast.JSDeclarationKind.ExportsProperty
                end) then
                    for _, declaration in ipairs(symbol.declarations) do
                        if checker.isNotOverload(declaration) then
                            self:error(declaration, diagnostics.Cannot_redeclare_exported_variable_0, id)
                        end
                    end
                end
            end
            ::continue::
        end
        links.exportsChecked = true
    end
end

function Checker:hasExportedMembersOfKind(moduleSymbol, kind)
    for _, symbol in pairs(moduleSymbol.exports or {}) do
        if symbol.name ~= ast.InternalSymbolNameExportEquals and self:getSymbolFlags(symbol) & kind ~= 0 then
            return true
        end
    end
    return false
end

function Checker:hasShadowedNamespace(symbol)
    if symbol.flags & SymbolFlags.NamespaceModule ~= 0 and symbol.flags & SymbolFlags.Alias ~= 0 then
        local target = self:resolveAlias(symbol)
        if target.flags & SymbolFlags.Namespace ~= 0 and self:hasExportedMembersOfKind(target, SymbolFlags.Type | SymbolFlags.Namespace) then
            return true
        end
    end
    return false
end

function checker.isNotOverload(node)
    return not ast.IsFunctionDeclaration(node) and not ast.IsMethodDeclaration(node) or node:Body() ~= nil
end

function Checker:checkMissingDeclaration(node)
    self:checkDecorators(node)
end

function Checker:checkVariableStatement(node)
    local varStatement = node:AsVariableStatement()
    local declarationList = varStatement.declarationList
    if not self:checkGrammarModifiers(node) and not self:checkGrammarVariableDeclarationList(declarationList:AsVariableDeclarationList()) then
        self:checkGrammarForDisallowedBlockScopedVariableStatement(varStatement)
    end
    self:checkVariableDeclarationList(declarationList)
end

function Checker:checkVariableDeclarationList(node)
    local blockScopeKind = ast.GetCombinedNodeFlags(node) & NodeFlags.BlockScoped
    if (blockScopeKind == NodeFlags.Using or blockScopeKind == NodeFlags.AwaitUsing) and self.languageVersion < checker.LanguageFeatureMinimumTarget.UsingAndAwaitUsing then
        self:checkExternalEmitHelpers(node, ExternalEmitHelpers.AddDisposableResourceAndDisposeResources)
    end
    self:checkSourceElements(node:AsVariableDeclarationList().declarations.nodes)
end

function Checker:checkVariableDeclaration(node)
    -- c.tracer is always nil (tracing is out of scope).
    self:checkGrammarVariableDeclaration(node:AsVariableDeclaration())
    self:checkVariableLikeDeclaration(node)
end

-- Check variable, parameter, or property declaration
function Checker:checkVariableLikeDeclaration(node)
    self:checkDecorators(node)
    local name = node:Name()
    if name == nil then
        return -- Missing array binding elements have no name
    end
    local typeNode = node:Type()
    local initializer = node:Initializer()
    if not ast.IsBindingElement(node) then
        self:checkSourceElement(typeNode)
    end
    -- For a computed property, just check the initializer and exit
    -- Do not use hasDynamicName here, because that returns false for well known symbols.
    -- We want to perform checkComputedPropertyName for all computed properties, including
    -- well known symbols.
    if ast.IsComputedPropertyName(name) then
        self:checkComputedPropertyName(name)
        if initializer ~= nil then
            self:checkExpressionCached(initializer)
        end
    end
    if ast.IsBindingElement(node) then
        local propName = node:PropertyName()
        if propName ~= nil and ast.IsIdentifier(node:Name()) and ast.IsPartOfParameterDeclaration(node) and ast.NodeIsMissing(ast.GetContainingFunction(node):Body()) then
            -- type F = ({a: string}) => void;
            --               ^^^^^^
            -- variable renaming in function type notation is confusing,
            -- so we forbid it even if noUnusedLocals is not enabled
            self.renamedBindingElementsInTypes = core.Append(self.renamedBindingElementsInTypes, node)
            return
        end
        if ast.IsObjectBindingPattern(node.parent) and checker.hasDotDotDotToken(node) and self.languageVersion < checker.LanguageFeatureMinimumTarget.ObjectSpreadRest then
            self:checkExternalEmitHelpers(node, ExternalEmitHelpers.Rest)
        end
        -- check computed properties inside property names of binding elements
        if propName ~= nil and ast.IsComputedPropertyName(propName) then
            self:checkComputedPropertyName(propName)
        end
        -- check private/protected variable access
        local parent = node.parent.parent
        local parentCheckMode = core.IfElse(checker.hasDotDotDotToken(node), CheckMode.RestBindingElement, CheckMode.Normal)
        local parentType = self:getTypeForBindingElementParent(parent, parentCheckMode)
        local propNameName = node:PropertyNameOrName()
        if parentType ~= nil and not ast.IsBindingPattern(propNameName) then
            local exprType = self:getLiteralTypeFromPropertyName(propNameName)
            if checker.isTypeUsableAsPropertyName(exprType) then
                local nameText = checker.getPropertyNameFromType(exprType)
                local property = self:getPropertyOfType(parentType, nameText)
                if property ~= nil then
                    self:markPropertyAsReferenced(property, nil --[[nodeForCheckWriteOnly]], false --[[isSelfTypeAccess]])
                    -- A destructuring is never a write-only reference.
                    self:checkPropertyAccessibility(node, parent:Initializer() ~= nil and parent:Initializer().kind == Kind.SuperKeyword, false --[[writing]], parentType, property)
                end
            end
        end
    end
    -- For a binding pattern, check contained binding elements
    if ast.IsBindingPattern(name) then
        self:checkSourceElements(name:Elements())
    end
    -- For a parameter declaration with an initializer, error and exit if the containing function doesn't have a body
    if initializer ~= nil and ast.IsPartOfParameterDeclaration(node) and ast.NodeIsMissing(ast.GetContainingFunction(node):Body()) then
        self:error(node, diagnostics.A_parameter_initializer_is_only_allowed_in_a_function_or_constructor_implementation)
        return
    end
    -- For a binding pattern, validate the initializer and exit
    if ast.IsBindingPattern(name) then
        if checker.isInAmbientOrTypeNode(node) then
            return
        end
        local needCheckInitializer = initializer ~= nil and node.parent.parent.kind ~= Kind.ForInStatement
        local needCheckWidenedType = not core.Some(name:Elements(), function(n) return n:Name() ~= nil end)
        if needCheckInitializer or needCheckWidenedType then
            -- Don't validate for-in initializer as it is already an error
            local widenedType = self:getWidenedTypeForVariableLikeDeclaration(node, false --[[reportErrors]])
            if needCheckInitializer then
                local initializerType = self:checkExpressionCached(initializer)
                if self.strictNullChecks and needCheckWidenedType then
                    self:checkNonNullNonVoidType(initializerType, node)
                else
                    self:checkTypeAssignableToAndOptionallyElaborate(initializerType, self:getWidenedTypeForVariableLikeDeclaration(node, false), node, initializer, nil, nil)
                end
            end
            -- check the binding pattern with empty elements
            if needCheckWidenedType then
                if ast.IsArrayBindingPattern(name) then
                    self:checkIteratedTypeOrElementType(IterationUse.Destructuring, widenedType, self.undefinedType, node)
                elseif self.strictNullChecks then
                    self:checkNonNullNonVoidType(widenedType, node)
                end
            end
        end
        return
    end
    -- For a commonjs `const x = require`, validate the alias and exit
    local symbol = self:getSymbolOfDeclaration(node)
    if symbol.flags & SymbolFlags.Alias ~= 0 and ast.IsVariableDeclarationInitializedToRequire(node) then
        self:checkAliasSymbol(node)
        return
    end
    if ast.IsBigIntLiteral(name) then
        self:error(name, diagnostics.A_bigint_literal_cannot_be_used_as_a_property_name)
    end
    local t = self:convertAutoToAny(self:getTypeOfSymbol(symbol))
    if node == symbol.valueDeclaration then
        -- Node is the primary declaration of the symbol, just validate the initializer
        -- Don't validate for-in initializer as it is already an error
        if initializer ~= nil and not ast.IsForInStatement(node.parent.parent) then
            local initializerType = self:checkExpressionCached(initializer)
            self:checkTypeAssignableToAndOptionallyElaborate(initializerType, t, node, initializer, nil --[[headMessage]], nil)
            local blockScopeKind = self:getCombinedNodeFlagsCached(node) & NodeFlags.BlockScoped
            if blockScopeKind == NodeFlags.AwaitUsing then
                local globalAsyncDisposableType = self.getGlobalAsyncDisposableType()
                local globalDisposableType = self.getGlobalDisposableType()
                if globalAsyncDisposableType ~= self.emptyObjectType and globalDisposableType ~= self.emptyObjectType then
                    local optionalDisposableType = self:getUnionType({ globalAsyncDisposableType, globalDisposableType, self.nullType, self.undefinedType })
                    self:checkTypeAssignableTo(self:widenTypeForVariableLikeDeclaration(initializerType, node, false), optionalDisposableType, initializer,
                        diagnostics.The_initializer_of_an_await_using_declaration_must_be_either_an_object_with_a_Symbol_asyncDispose_or_Symbol_dispose_method_or_be_null_or_undefined)
                end
            elseif blockScopeKind == NodeFlags.Using then
                local globalDisposableType = self.getGlobalDisposableType()
                if globalDisposableType ~= self.emptyObjectType then
                    local optionalDisposableType = self:getUnionType({ globalDisposableType, self.nullType, self.undefinedType })
                    self:checkTypeAssignableTo(self:widenTypeForVariableLikeDeclaration(initializerType, node, false), optionalDisposableType, initializer,
                        diagnostics.The_initializer_of_a_using_declaration_must_be_either_an_object_with_a_Symbol_dispose_method_or_be_null_or_undefined)
                end
            end
        end
        if core.Len(symbol.declarations) > 1 then
            if core.Some(symbol.declarations, function(d)
                return d ~= node and ast.IsVariableLike(d) and not self:areDeclarationFlagsIdentical(d, node)
            end) then
                self:error(name, diagnostics.All_declarations_of_0_must_have_identical_modifiers, scanner.DeclarationNameToString(name))
            end
        end
    else
        -- Node is a secondary declaration, check that type is identical to primary declaration and check that
        -- initializer is consistent with type associated with the node
        local declarationType = self:convertAutoToAny(self:getWidenedTypeForVariableLikeDeclaration(node, false))
        if not self:isErrorType(t) and not self:isErrorType(declarationType) and not self:isTypeIdenticalTo(t, declarationType) and symbol.flags & SymbolFlags.Assignment == 0 then
            self:errorNextVariableOrPropertyDeclarationMustHaveSameType(symbol.valueDeclaration, t, node, declarationType)
        end
        if initializer ~= nil then
            self:checkTypeAssignableToAndOptionallyElaborate(self:checkExpressionCached(initializer), declarationType, node, initializer, nil --[[headMessage]], nil)
        end
        if symbol.valueDeclaration ~= nil and not self:areDeclarationFlagsIdentical(node, symbol.valueDeclaration) then
            self:error(name, diagnostics.All_declarations_of_0_must_have_identical_modifiers, scanner.DeclarationNameToString(name))
        end
    end
    if not ast.IsPropertyDeclaration(node) and not ast.IsPropertySignatureDeclaration(node) then
        -- We know we don't have a binding pattern or computed name here
        self:checkExportsOnMergedDeclarations(node)
        if ast.IsVariableDeclaration(node) or ast.IsBindingElement(node) then
            self:checkVarDeclaredNamesNotShadowed(node)
        end
        self:checkCollisionsForDeclarationName(node, node:Name())
    end
end

function Checker:errorNextVariableOrPropertyDeclarationMustHaveSameType(firstDeclaration, firstType, nextDeclaration, nextType)
    local nextDeclarationName = ast.GetNameOfDeclaration(nextDeclaration)
    local message = core.IfElse(ast.IsPropertyDeclaration(nextDeclaration) or ast.IsPropertySignatureDeclaration(nextDeclaration),
        diagnostics.Subsequent_property_declarations_must_have_the_same_type_Property_0_must_be_of_type_1_but_here_has_type_2,
        diagnostics.Subsequent_variable_declarations_must_have_the_same_type_Variable_0_must_be_of_type_1_but_here_has_type_2)
    local declName = scanner.DeclarationNameToString(nextDeclarationName)
    local err = self:error(nextDeclarationName, message, declName, self:TypeToString(firstType), self:TypeToString(nextType))
    if firstDeclaration ~= nil then
        err:AddRelatedInfo(checker.createDiagnosticForNode(firstDeclaration, diagnostics.X_0_was_also_declared_here, declName))
    end
end

function Checker:checkVarDeclaredNamesNotShadowed(node)
    -- - ScriptBody : StatementList
    -- It is a Syntax Error if any element of the LexicallyDeclaredNames of StatementList
    -- also occurs in the VarDeclaredNames of StatementList.

    -- - Block : { StatementList }
    -- It is a Syntax Error if any element of the LexicallyDeclaredNames of StatementList
    -- also occurs in the VarDeclaredNames of StatementList.

    -- Variable declarations are hoisted to the top of their function scope. They can shadow
    -- block scoped declarations, which bind tighter. this will not be flagged as duplicate definition
    -- by the binder as the declaration scope is different.
    -- A non-initialized declaration is a no-op as the block declaration will resolve before the var
    -- declaration. the problem is if the declaration has an initializer. this will act as a write to the
    -- block declared value. this is fine for let, but not const.
    -- Only consider declarations with initializers, uninitialized const declarations will not
    -- step on a let/const variable.
    -- Do not consider const and const declarations, as duplicate block-scoped declarations
    -- are handled by the binder.
    -- We are only looking for const declarations that step on let\const declarations from a
    -- different scope. e.g.:
    --      {
    --          const x = 0; // localDeclarationSymbol obtained after name resolution will correspond to this declaration
    --          const x = 0; // symbol for this declaration will be 'symbol'
    --      }

    -- skip block-scoped variables and parameters
    if (self:getCombinedNodeFlagsCached(node) & NodeFlags.BlockScoped) ~= 0 or ast.IsPartOfParameterDeclaration(node) then
        return
    end
    -- NOTE: in ES6 spec initializer is required in variable declarations where name is binding pattern
    -- so we'll always treat binding elements as initialized
    local symbol = self:getSymbolOfDeclaration(node)
    local name = node:Name()
    if symbol.flags & SymbolFlags.FunctionScopedVariable ~= 0 then
        if not ast.IsIdentifier(name) then
            error("Identifier expected", 0)
        end
        local localDeclarationSymbol = self.resolveName(node, name:Text(), SymbolFlags.Variable, nil --[[nameNotFoundMessage]], false --[[isUse]], false)
        if localDeclarationSymbol ~= nil and localDeclarationSymbol ~= symbol and localDeclarationSymbol.flags & SymbolFlags.BlockScopedVariable ~= 0 then
            if self:getDeclarationNodeFlagsFromSymbol(localDeclarationSymbol) & NodeFlags.BlockScoped ~= 0 then
                local varDeclList = ast.FindAncestorKind(localDeclarationSymbol.valueDeclaration, Kind.VariableDeclarationList)
                local container
                if ast.IsVariableStatement(varDeclList.parent) and varDeclList.parent.parent ~= nil then
                    container = varDeclList.parent.parent
                end
                -- names of block-scoped and function scoped variables can collide only
                -- if block scoped variable is defined in the function\module\source file scope (because of variable hoisting)
                local namesShareScope = container ~= nil and (ast.IsBlock(container) and ast.IsFunctionLike(container.parent) or
                    ast.IsModuleBlock(container) or ast.IsModuleDeclaration(container) or ast.IsSourceFile(container))
                -- here we know that function scoped variable is "shadowed" by block scoped one
                -- a var declaration can't hoist past a lexical declaration and it results in a SyntaxError at runtime
                if not namesShareScope then
                    local symbolName = self:symbolToString(localDeclarationSymbol)
                    self:error(node, diagnostics.Cannot_initialize_outer_scoped_variable_0_in_the_same_scope_as_block_scoped_declaration_1, symbolName, symbolName)
                end
            end
        end
    end
end

function Checker:checkDecorators(node)
    -- skip this check for nodes that cannot have decorators. These should have already had an error reported by
    -- checkGrammarModifiers.
    if not ast.CanHaveDecorators(node) or not ast.HasDecorators(node) or not ast.NodeCanBeDecorated(self.legacyDecorators, node, node.parent, node.parent.parent) then
        return
    end
    local firstDecorator = core.Find(node:ModifierNodes(), ast.IsDecorator)
    if firstDecorator == nil then
        return
    end
    if self.legacyDecorators then
        self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.Decorate)
        if ast.IsParameterDeclaration(node) then
            self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.Param)
        end
    elseif self.languageVersion < checker.LanguageFeatureMinimumTarget.ClassAndClassElementDecorators then
        self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.ESDecorateAndRunInitializers)
        if ast.IsClassDeclaration(node) then
            if node:Name() == nil or self:getFirstTransformableStaticClassElement(node) ~= nil then
                self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.SetFunctionName)
            end
        elseif not ast.IsClassExpression(node) then
            local name = node:Name()
            if ast.IsPrivateIdentifier(name) and (ast.IsMethodDeclaration(node) or ast.IsAccessor(node) or ast.IsAutoAccessorPropertyDeclaration(node)) then
                self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.SetFunctionName)
            end
            if ast.IsComputedPropertyName(name) then
                self:checkExternalEmitHelpers(firstDecorator, ExternalEmitHelpers.PropKey)
            end
        end
    end
    self:markLinkedReferences(node, ReferenceHint.Decorator, nil, nil)
    for _, modifier in ipairs(node:ModifierNodes() or {}) do
        if ast.IsDecorator(modifier) then
            self:checkDecorator(modifier)
        end
    end
end

function Checker:checkDecorator(node)
    self:checkGrammarDecorator(node:AsDecorator())
    local signature = self:getResolvedSignature(node, nil, CheckMode.Normal)
    self:checkDeprecatedSignature(signature, node)
    local returnType = self:getReturnTypeOfSignature(signature)
    if returnType.flags & TypeFlags.Any ~= 0 then
        return
    end
    -- if we fail to get a signature and return type here, we will have already reported a grammar error in `checkDecorators`.
    local decoratorSignature = self:getDecoratorCallSignature(node)
    if decoratorSignature == nil or decoratorSignature.resolvedReturnType == nil then
        return
    end
    local headMessage
    local expectedReturnType = decoratorSignature.resolvedReturnType
    local k = node.parent.kind
    if k == Kind.ClassDeclaration or k == Kind.ClassExpression then
        headMessage = diagnostics.Decorator_function_return_type_0_is_not_assignable_to_type_1
    elseif k == Kind.PropertyDeclaration or k == Kind.Parameter then
        if k == Kind.PropertyDeclaration and not self.legacyDecorators then
            headMessage = diagnostics.Decorator_function_return_type_0_is_not_assignable_to_type_1
        else
            headMessage = diagnostics.Decorator_function_return_type_is_0_but_is_expected_to_be_void_or_any
        end
    elseif k == Kind.MethodDeclaration or k == Kind.GetAccessor or k == Kind.SetAccessor then
        headMessage = diagnostics.Decorator_function_return_type_0_is_not_assignable_to_type_1
    else
        error("Unhandled case in checkDecorator", 0)
    end
    self:checkTypeAssignableTo(returnType, expectedReturnType, node:Expression(), headMessage)
end

function Checker:checkIteratedTypeOrElementType(use, inputType, sentType, errorNode)
    if checker.IsTypeAny(inputType) then
        return inputType
    end
    local t = self:getIteratedTypeOrElementType(use, inputType, sentType, errorNode, true --[[checkAssignability]])
    if t ~= nil then
        return t
    end
    return self.anyType
end

function Checker:getIteratedTypeOrElementType(use, inputType, sentType, errorNode, checkAssignability)
    local allowAsyncIterables = (use & IterationUse.AllowsAsyncIterablesFlag) ~= 0
    if inputType == self.neverType then
        if errorNode ~= nil then
            self:reportTypeNotIterableError(errorNode, inputType, allowAsyncIterables)
        end
        return nil
    end
    local iterableExists = self.getGlobalIterableType() ~= self.emptyGenericType
    local possibleOutOfBounds = self.compilerOptions.noUncheckedIndexedAccess == Tristate.TSTrue and use & IterationUse.PossiblyOutOfBounds ~= 0
    if iterableExists or allowAsyncIterables then
        local iterationTypes = self:getIterationTypesOfIterable(inputType, use, core.IfElse(iterableExists, errorNode, nil))
        if checkAssignability then
            if iterationTypes.nextType ~= nil then
                local diagnostic
                if use & IterationUse.ForOfFlag ~= 0 then
                    diagnostic = diagnostics.Cannot_iterate_value_because_the_next_method_of_its_iterator_expects_type_1_but_for_of_will_always_send_0
                elseif use & IterationUse.SpreadFlag ~= 0 then
                    diagnostic = diagnostics.Cannot_iterate_value_because_the_next_method_of_its_iterator_expects_type_1_but_array_spread_will_always_send_0
                elseif use & IterationUse.DestructuringFlag ~= 0 then
                    diagnostic = diagnostics.Cannot_iterate_value_because_the_next_method_of_its_iterator_expects_type_1_but_array_destructuring_will_always_send_0
                elseif use & IterationUse.YieldStarFlag ~= 0 then
                    diagnostic = diagnostics.Cannot_delegate_iteration_to_value_because_the_next_method_of_its_iterator_expects_type_1_but_the_containing_generator_will_always_send_0
                end
                if diagnostic ~= nil then
                    self:checkTypeAssignableTo(sentType, iterationTypes.nextType, errorNode, diagnostic)
                end
            end
        end
        if iterationTypes.yieldType ~= nil or iterableExists then
            if iterationTypes.yieldType == nil then
                return nil
            end
            if possibleOutOfBounds then
                return self:includeUndefinedInIndexSignature(iterationTypes.yieldType)
            end
            return iterationTypes.yieldType
        end
    end
    local arrayType = inputType
    local hasStringConstituent = false
    -- If strings are permitted, remove any string-like constituents from the array type.
    -- This allows us to find other non-string element types from an array unioned with
    -- a string.
    if use & IterationUse.AllowsStringInputFlag ~= 0 then
        if arrayType.flags & TypeFlags.Union ~= 0 then
            -- After we remove all types that are StringLike, we will know if there was a string constituent
            -- based on whether the result of filter is a new array.
            local arrayTypes = inputType:Types()
            local filteredTypes = core.Filter(arrayTypes, function(t)
                return t.flags & TypeFlags.StringLike == 0
            end)
            if not core.Same(filteredTypes, arrayTypes) then
                arrayType = self:getUnionTypeEx(filteredTypes, UnionReduction.Subtype, nil, nil)
            end
        elseif arrayType.flags & TypeFlags.StringLike ~= 0 then
            arrayType = self.neverType
        end
        hasStringConstituent = arrayType ~= inputType
        if hasStringConstituent then
            -- Now that we've removed all the StringLike types, if no constituents remain, then the entire
            -- arrayOrStringType was a string.
            if arrayType.flags & TypeFlags.Never ~= 0 then
                if possibleOutOfBounds then
                    return self:includeUndefinedInIndexSignature(self.stringType)
                end
                return self.stringType
            end
        end
    end
    if not self:isArrayLikeType(arrayType) then
        if errorNode ~= nil then
            -- Which error we report depends on whether we allow strings or if there was a
            -- string constituent. For example, if the input type is number | string, we
            -- want to say that number is not an array type. But if the input was just
            -- number and string input is allowed, we want to say that number is not an
            -- array type or a string type.
            local allowsStrings = use & IterationUse.AllowsStringInputFlag ~= 0 and not hasStringConstituent
            local defaultDiagnostic, maybeMissingAwait = self:getIterationDiagnosticDetails(use, inputType, allowsStrings)
            self:errorAndMaybeSuggestAwait(errorNode, maybeMissingAwait and self:getAwaitedTypeOfPromise(arrayType) ~= nil, defaultDiagnostic, self:TypeToString(arrayType))
        end
        if hasStringConstituent then
            if possibleOutOfBounds then
                return self:includeUndefinedInIndexSignature(self.stringType)
            end
            return self.stringType
        end
        return nil
    end
    local arrayElementType = self:getIndexTypeOfType(arrayType, self.numberType)
    if hasStringConstituent and arrayElementType ~= nil then
        -- This is just an optimization for the case where arrayOrStringType is string | string[]
        if arrayElementType.flags & TypeFlags.StringLike ~= 0 and self.compilerOptions.noUncheckedIndexedAccess ~= Tristate.TSTrue then
            return self.stringType
        end
        if possibleOutOfBounds then
            return self:getUnionTypeEx({ arrayElementType, self.stringType, self.undefinedType }, UnionReduction.Subtype, nil, nil)
        end
        return self:getUnionTypeEx({ arrayElementType, self.stringType }, UnionReduction.Subtype, nil, nil)
    end
    if use & IterationUse.PossiblyOutOfBounds ~= 0 then
        return self:includeUndefinedInIndexSignature(arrayElementType)
    end
    return arrayElementType
end

-- Gets the requested "iteration type" from a type that is either `Iterable`-like, `Iterator`-like,
-- `IterableIterator`-like, or `Generator`-like (for a non-async generator); or `AsyncIterable`-like,
-- `AsyncIterator`-like, `AsyncIterableIterator`-like, or `AsyncGenerator`-like (for an async generator).
function Checker:getIterationTypeOfGeneratorFunctionReturnType(typeKind, returnType, isAsyncGenerator)
    if checker.IsTypeAny(returnType) then
        return nil
    end
    local iterationTypes = self:getIterationTypesOfGeneratorFunctionReturnType(returnType, isAsyncGenerator)
    return iterationTypes:getType(typeKind)
end

local function newIterationTypes(yieldType, returnType, nextType)
    return checker.IterationTypes_new({ yieldType = yieldType, returnType = returnType, nextType = nextType })
end

function Checker:getIterationTypesOfGeneratorFunctionReturnType(t, isAsyncGenerator)
    if checker.IsTypeAny(t) then
        return newIterationTypes(self.anyType, self.anyType, self.anyType)
    end
    local use = core.IfElse(isAsyncGenerator, IterationUse.AsyncGeneratorReturnType, IterationUse.GeneratorReturnType)
    local resolver = core.IfElse(isAsyncGenerator, self.asyncIterationTypesResolver, self.syncIterationTypesResolver)
    local result = self:getIterationTypesOfIterable(t, use, nil --[[errorNode]])
    if result:hasTypes() then
        return result
    end
    return self:getIterationTypesOfIterator(t, resolver, nil --[[errorNode]], nil --[[diagnosticOutput]])
end

-- Gets the requested "iteration type" from an `Iterable`-like or `AsyncIterable`-like type.
function Checker:getIterationTypeOfIterable(use, typeKind, inputType, errorNode)
    if checker.IsTypeAny(inputType) then
        return nil
    end
    local iterationTypes = self:getIterationTypesOfIterable(inputType, use, errorNode)
    return iterationTypes:getType(typeKind)
end

-- Gets the *yield*, *return*, and *next* types from an `Iterable`-like or `AsyncIterable`-like type.
--
-- At every level that involves analyzing return types of signatures, we union the return types of all the signatures.
--
-- Another thing to note is that at any step of this process, we could run into a dead end,
-- meaning either the property is missing, or we run into the anyType. If either of these things
-- happens, we return a default `IterationTypes{}` to signal that we could not find the iteration type.
-- If a property is missing, and the previous step did not result in `any`, then we also give an error
-- if the caller requested it. Then the caller can decide what to do in the case where there is no
-- iterated type.
--
-- For a **for-of** statement, `yield*` (in a normal generator), spread, array
-- destructuring, or normal generator we will only ever look for a `[Symbol.iterator]()`
-- method.
--
-- For an async generator we will only ever look at the `[Symbol.asyncIterator]()` method.
--
-- For a **for-await-of** statement or a `yield*` in an async generator we will look for
-- the `[Symbol.asyncIterator]()` method first, and then the `[Symbol.iterator]()` method.
function Checker:getIterationTypesOfIterable(t, use, errorNode)
    t = self:getReducedType(t)
    if checker.IsTypeAny(t) then
        return newIterationTypes(self.anyType, self.anyType, self.anyType)
    end
    local key = checker.IterationTypesKey(t.id, use & IterationUse.CacheFlags)
    -- If we are reporting errors and encounter a cached `noIterationTypes`, we should ignore the cached value and continue as if nothing was cached.
    -- In addition, we should not cache any new results for this call.
    local noCache = false
    local cached = self.iterationTypesCache[key]
    if cached ~= nil then
        if errorNode == nil or cached:hasTypes() then
            return cached
        end
        noCache = true
    end
    local result = self:getIterationTypesOfIterableWorker(t, use, errorNode, noCache)
    if not noCache then
        self.iterationTypesCache[key] = result
    end
    return result
end

function Checker:getIterationTypesOfIterableWorker(t, use, errorNode, noCache)
    if t.flags & TypeFlags.Union ~= 0 then
        local allIterationTypes = {}
        for _, constituent in ipairs(t:Types()) do
            local iterationTypes = self:getIterationTypesOfIterableWorker(constituent, use, nil, noCache)
            if not iterationTypes:hasTypes() then
                if errorNode ~= nil then
                    self:addDeferredDiagnostic(function()
                        self:reportTypeNotIterableError(errorNode, t, use & IterationUse.AllowsAsyncIterablesFlag ~= 0)
                    end)
                end
                return checker.IterationTypes_new()
            end
            allIterationTypes[#allIterationTypes + 1] = iterationTypes
        end
        return self:combineIterationTypes(allIterationTypes)
    end
    local diags = {}
    if use & IterationUse.AllowsAsyncIterablesFlag ~= 0 then
        local iterationTypes = self:getIterationTypesOfIterableFast(t, self.asyncIterationTypesResolver)
        if iterationTypes:hasTypes() then
            if use & IterationUse.ForOfFlag ~= 0 then
                return self:getAsyncFromSyncIterationTypes(iterationTypes, errorNode)
            end
            return iterationTypes
        end
        iterationTypes = self:getIterationTypesOfIterableSlow(t, self.asyncIterationTypesResolver, errorNode, diags)
        if iterationTypes:hasTypes() then
            if #diags ~= 0 then
                for _, d in ipairs(diags) do
                    self:addDiagnostic(d)
                end
            end
            return iterationTypes
        end
    end
    if use & IterationUse.AllowsSyncIterablesFlag ~= 0 then
        local iterationTypes = self:getIterationTypesOfIterableFast(t, self.syncIterationTypesResolver)
        if iterationTypes:hasTypes() then
            if use & IterationUse.AllowsAsyncIterablesFlag ~= 0 then
                return self:getAsyncFromSyncIterationTypes(iterationTypes, errorNode)
            end
            return iterationTypes
        end
        iterationTypes = self:getIterationTypesOfIterableSlow(t, self.syncIterationTypesResolver, errorNode, diags)
        if iterationTypes:hasTypes() then
            if #diags ~= 0 then
                for _, d in ipairs(diags) do
                    self:addDiagnostic(d)
                end
            end
            if use & IterationUse.AllowsAsyncIterablesFlag ~= 0 then
                return self:getAsyncFromSyncIterationTypes(iterationTypes, errorNode)
            end
            return iterationTypes
        end
    end
    if errorNode ~= nil then
        -- We defer the diagnostic because TypeToString may attempt to resolve symbols that are already being
        -- resolved, possibly causing circularities.
        self:addDeferredDiagnostic(function()
            local diagnostic = self:reportTypeNotIterableError(errorNode, t, use & IterationUse.AllowsAsyncIterablesFlag ~= 0)
            for _, d in ipairs(diags) do
                diagnostic:AddRelatedInfo(d)
            end
        end)
    end
    return checker.IterationTypes_new()
end

function Checker:getIterationTypesOfIterableFast(t, r)
    -- As an optimization, if the type is an instantiation of the following global type, then
    -- just grab its related type arguments:
    -- - `Iterable<T, TReturn, TNext>` or `AsyncIterable<T, TReturn, TNext>`
    -- - `IteratorObject<T, TReturn, TNext>` or `AsyncIteratorObject<T, TReturn, TNext>`
    -- - `IterableIterator<T, TReturn, TNext>` or `AsyncIterableIterator<T, TReturn, TNext>`
    -- - `Generator<T, TReturn, TNext>` or `AsyncGenerator<T, TReturn, TNext>`
    if self:isReferenceToType(t, r.getGlobalIterableType()) or
        self:isReferenceToType(t, r.getGlobalIteratorObjectType()) or
        self:isReferenceToType(t, r.getGlobalIterableIteratorType()) or
        self:isReferenceToType(t, r.getGlobalGeneratorType()) then
        local typeArguments = self:getTypeArguments(t)
        return r:getResolvedIterationTypes(typeArguments[1], typeArguments[2], typeArguments[3])
    end
    -- As an optimization, if the type is an instantiation of one of the following global types, then
    -- just grab the related type argument:
    -- - `ArrayIterator<T>`
    -- - `MapIterator<T>`
    -- - `SetIterator<T>`
    -- - `StringIterator<T>`
    -- - `ReadableStreamAsyncIterator<T>`
    if self:isReferenceToSomeType(t, r.getGlobalBuiltinIteratorTypes()) then
        return r:getResolvedIterationTypes(self:getTypeArguments(t)[1], self:getBuiltinIteratorReturnType(), self.unknownType)
    end
    return checker.IterationTypes_new()
end

function checker.IterationTypesResolver:getResolvedIterationTypes(yieldType, returnType, nextType)
    return newIterationTypes(
        self.resolveIterationType(yieldType, nil --[[errorNode]]) or yieldType,
        self.resolveIterationType(returnType, nil --[[errorNode]]) or returnType,
        nextType
    )
end

function Checker:isReferenceToType(t, target)
    return t ~= nil and t.objectFlags & ObjectFlags.Reference ~= 0 and t:Target() == target
end

function Checker:isReferenceToSomeType(t, targets)
    if t == nil or t.objectFlags & ObjectFlags.Reference == 0 then
        return false
    end
    local target = t:Target()
    for _, x in ipairs(targets or {}) do
        if x == target then
            return true
        end
    end
    return false
end

function Checker:getBuiltinIteratorReturnType()
    return core.IfElse(self.strictBuiltinIteratorReturn, self.undefinedType, self.anyType)
end

function checker.IterationTypes:hasTypes()
    return self.yieldType ~= nil or self.returnType ~= nil or self.nextType ~= nil
end

function checker.IterationTypes:getType(typeKind)
    if typeKind == IterationTypeKind.Yield then
        return self.yieldType
    elseif typeKind == IterationTypeKind.Return then
        return self.returnType
    elseif typeKind == IterationTypeKind.Next then
        return self.nextType
    end
    error("Unhandled case in getType(IterationTypeKind)", 0)
end

function Checker:combineIterationTypes(iterationTypes)
    return newIterationTypes(
        self:getIterationTypeUnion(iterationTypes, function(t) return t.yieldType end),
        self:getIterationTypeUnion(iterationTypes, function(t) return t.returnType end),
        self:getIterationTypeUnion(iterationTypes, function(t) return t.nextType end)
    )
end

function Checker:getIterationTypeUnion(iterationTypes, f)
    local types = core.MapNonNil(iterationTypes, f)
    if core.Len(types) == 0 then
        return nil
    end
    return self:getUnionType(types)
end

function Checker:getAsyncFromSyncIterationTypes(iterationTypes, errorNode)
    if not iterationTypes:hasTypes() or
        iterationTypes.yieldType == self.anyType and iterationTypes.returnType == self.anyType and iterationTypes.nextType == self.anyType then
        return iterationTypes
    end
    -- if we're requesting diagnostics, report errors for a missing `Awaited<T>`.
    if errorNode ~= nil then
        self.getGlobalAwaitedSymbol()
    end
    return newIterationTypes(
        self:getAwaitedTypeEx(iterationTypes.yieldType, errorNode, nil) or self.anyType,
        self:getAwaitedTypeEx(iterationTypes.returnType, errorNode, nil) or self.anyType,
        iterationTypes.nextType
    )
end

-- Gets the *yield*, *return*, and *next* types of an `Iterable`-like or `AsyncIterable`-like
-- type from its members.
--
-- If we successfully found the *yield*, *return*, and *next* types, an `IterationTypes` with non-nil
-- members is returned. Otherwise, a default `IterationTypes{}` is returned.
--
-- NOTE: You probably don't want to call this directly and should be calling
-- `getIterationTypesOfIterable` instead.
function Checker:getIterationTypesOfIterableSlow(t, r, errorNode, diagnosticOutput)
    local method = self:getPropertyOfType(t, self:getPropertyNameForKnownSymbolName(r.iteratorSymbolName))
    if method ~= nil and method.flags & SymbolFlags.Optional == 0 then
        local methodType = self:getTypeOfSymbol(method)
        if checker.IsTypeAny(methodType) then
            return newIterationTypes(self.anyType, self.anyType, self.anyType)
        end
        local allSignatures = self:getSignaturesOfType(methodType, SignatureKind.Call)
        local validSignatures = core.Filter(allSignatures, function(sig)
            return self:getMinArgumentCount(sig) == 0
        end)
        if core.Len(validSignatures) ~= 0 then
            local iteratorType = self:getIntersectionType(core.Map(validSignatures, function(sig) return self:getReturnTypeOfSignature(sig) end))
            return self:getIterationTypesOfIteratorWorker(iteratorType, r, errorNode, diagnosticOutput)
        end
        if errorNode ~= nil and core.Len(allSignatures) ~= 0 then
            self:checkTypeAssignableToEx(t, r.getGlobalIterableTypeChecked(), errorNode, nil, diagnosticOutput)
        end
    end
    return checker.IterationTypes_new()
end

-- Gets the *yield*, *return*, and *next* types from an `Iterator`-like or `AsyncIterator`-like type.
--
-- If we successfully found the *yield*, *return*, and *next* types, an `IterationTypes` with non-nil
-- members is returned. Otherwise, a default `IterationTypes{}` is returned.
function Checker:getIterationTypesOfIterator(t, r, errorNode, diagnosticOutput)
    return self:getIterationTypesOfIteratorWorker(t, r, errorNode, diagnosticOutput)
end

-- Gets the *yield*, *return*, and *next* types from an `Iterator`-like or `AsyncIterator`-like type.
--
-- If we successfully found the *yield*, *return*, and *next* types, an `IterationTypes` with non-nil
-- members is returned. Otherwise, a default `IterationTypes{}` is returned.
--
-- NOTE: You probably don't want to call this directly and should be calling `getIterationTypesOfIterator` instead.
function Checker:getIterationTypesOfIteratorWorker(t, r, errorNode, diagnosticOutput)
    if checker.IsTypeAny(t) then
        return newIterationTypes(self.anyType, self.anyType, self.anyType)
    end
    local iterationTypes = self:getIterationTypesOfIteratorFast(t, r)
    if iterationTypes:hasTypes() then
        return iterationTypes
    end
    return self:getIterationTypesOfIteratorSlow(t, r, errorNode, diagnosticOutput)
end

function Checker:getIterationTypesOfIteratorFast(t, r)
    -- As an optimization, if the type is an instantiation of the following global type, then
    -- just grab its related type arguments:
    -- - `Iterable<T, TReturn, TNext>` or `AsyncIterable<T, TReturn, TNext>`
    -- - `IteratorObject<T, TReturn, TNext>` or `AsyncIteratorObject<T, TReturn, TNext>`
    -- - `IterableIterator<T, TReturn, TNext>` or `AsyncIterableIterator<T, TReturn, TNext>`
    -- - `Generator<T, TReturn, TNext>` or `AsyncGenerator<T, TReturn, TNext>`
    if self:isReferenceToType(t, r.getGlobalIteratorType()) or
        self:isReferenceToType(t, r.getGlobalIteratorObjectType()) or
        self:isReferenceToType(t, r.getGlobalIterableIteratorType()) or
        self:isReferenceToType(t, r.getGlobalGeneratorType()) then
        local typeArguments = self:getTypeArguments(t)
        return r:getResolvedIterationTypes(typeArguments[1], typeArguments[2], typeArguments[3])
    end
    -- As an optimization, if the type is an instantiation of one of the following global types, then
    -- just grab the related type argument:
    -- - `ArrayIterator<T>`
    -- - `MapIterator<T>`
    -- - `SetIterator<T>`
    -- - `StringIterator<T>`
    -- - `ReadableStreamAsyncIterator<T>`
    if self:isReferenceToSomeType(t, r.getGlobalBuiltinIteratorTypes()) then
        return r:getResolvedIterationTypes(self:getTypeArguments(t)[1], self:getBuiltinIteratorReturnType(), self.unknownType)
    end
    return checker.IterationTypes_new()
end

function Checker:getIterationTypesOfIteratorSlow(t, r, errorNode, diagnosticOutput)
    return self:combineIterationTypes({
        self:getIterationTypesOfMethod(t, r, "next", errorNode, diagnosticOutput),
        self:getIterationTypesOfMethod(t, r, "return", errorNode, diagnosticOutput),
        self:getIterationTypesOfMethod(t, r, "throw", errorNode, diagnosticOutput),
    })
end

function Checker:getIterationTypesOfMethod(t, resolver, methodName, errorNode, diagnosticOutput)
    local method = self:getPropertyOfType(t, methodName)
    -- Ignore 'return' or 'throw' if they are missing.
    if method == nil and methodName ~= "next" then
        return checker.IterationTypes_new()
    end
    local methodType
    if method ~= nil and not (methodName == "next" and method.flags & SymbolFlags.Optional ~= 0) then
        if methodName == "next" then
            methodType = self:getTypeOfSymbol(method)
        else
            methodType = self:getTypeWithFacts(self:getTypeOfSymbol(method), TypeFacts.NEUndefinedOrNull)
        end
    end
    if checker.IsTypeAny(methodType) then
        return newIterationTypes(self.anyType, self.anyType, self.anyType)
    end
    -- Both async and non-async iterators *must* have a `next` method.
    local methodSignatures
    if methodType ~= nil then
        methodSignatures = self:getSignaturesOfType(methodType, SignatureKind.Call)
    end
    if core.Len(methodSignatures) == 0 then
        if errorNode ~= nil then
            local diagnostic = core.IfElse(methodName == "next", resolver.mustHaveANextMethodDiagnostic, resolver.mustBeAMethodDiagnostic)
            self:reportDiagnostic(checker.NewDiagnosticForNode(errorNode, diagnostic, methodName), diagnosticOutput)
        end
        return checker.IterationTypes_new()
    end
    -- If the method signature comes exclusively from the global iterator or generator type,
    -- create iteration types from its type arguments like `getIterationTypesOfIteratorFast`
    -- does (so as to remove `undefined` from the next and return types). We arrive here when
    -- a contextual type for a generator was not a direct reference to one of those global types,
    -- but looking up `methodType` referred to one of them (and nothing else). E.g., in
    -- `interface SpecialIterator extends Iterator<number> {}`, `SpecialIterator` is not a
    -- reference to `Iterator`, but its `next` member derives exclusively from `Iterator`.
    if #methodSignatures == 1 and methodType.symbol ~= nil then
        local globalGeneratorType = resolver.getGlobalGeneratorType()
        local globalIteratorType = resolver.getGlobalIteratorType()
        local isGeneratorMethod = globalGeneratorType.symbol ~= nil and globalGeneratorType.symbol.members ~= nil and globalGeneratorType.symbol.members[methodName] == methodType.symbol
        local isIteratorMethod = not isGeneratorMethod and globalIteratorType.symbol ~= nil and globalIteratorType.symbol.members ~= nil and globalIteratorType.symbol.members[methodName] == methodType.symbol
        if isGeneratorMethod or isIteratorMethod then
            local typeParameters = core.IfElse(isGeneratorMethod, globalGeneratorType, globalIteratorType):AsInterfaceType():TypeParameters()
            local mapper = methodType:Mapper()
            local nextType
            if methodName == "next" then
                nextType = mapper:Map(typeParameters[3])
            end
            return newIterationTypes(mapper:Map(typeParameters[1]), mapper:Map(typeParameters[2]), nextType)
        end
    end
    -- Extract the first parameter and return type of each signature.
    local methodParameterTypes
    local methodReturnTypes
    for _, signature in ipairs(methodSignatures) do
        if methodName ~= "throw" and core.Len(signature.parameters) ~= 0 then
            methodParameterTypes = core.Append(methodParameterTypes, self:getTypeAtPosition(signature, 0))
        end
        methodReturnTypes = core.Append(methodReturnTypes, self:getReturnTypeOfSignature(signature))
    end
    -- Resolve the *next* or *return* type from the first parameter of a `next()` or
    -- `return()` method, respectively.
    local returnTypes = nil
    local nextType
    if methodName ~= "throw" then
        local methodParameterType
        if methodParameterTypes ~= nil then
            methodParameterType = self:getUnionType(methodParameterTypes)
        else
            methodParameterType = self.unknownType
        end
        if methodName == "next" then
            -- The value of `next(value)` is *not* awaited by async generators
            nextType = methodParameterType
        elseif methodName == "return" then
            -- The value of `return(value)` *is* awaited by async generators
            local resolvedMethodParameterType = resolver.resolveIterationType(methodParameterType, errorNode) or self.anyType
            returnTypes = core.Append(returnTypes, resolvedMethodParameterType)
        end
    end
    -- Resolve the *yield* and *return* types from the return type of the method (i.e. `IteratorResult`)
    local yieldType
    local methodReturnType
    if methodReturnTypes ~= nil then
        methodReturnType = self:getIntersectionType(methodReturnTypes)
    else
        methodReturnType = self.neverType
    end
    local resolvedMethodReturnType = resolver.resolveIterationType(methodReturnType, errorNode) or self.anyType
    local iterationTypes = self:getIterationTypesOfIteratorResult(resolvedMethodReturnType)
    if not iterationTypes:hasTypes() then
        if errorNode ~= nil then
            self:reportDiagnostic(checker.NewDiagnosticForNode(errorNode, resolver.mustHaveAValueDiagnostic, methodName), diagnosticOutput)
        end
        yieldType = self.anyType
        returnTypes = core.Append(returnTypes, self.anyType)
    else
        yieldType = iterationTypes.yieldType
        returnTypes = core.Append(returnTypes, iterationTypes.returnType)
    end
    return newIterationTypes(yieldType, self:getUnionType(returnTypes), nextType)
end
