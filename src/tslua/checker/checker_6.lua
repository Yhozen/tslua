local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local collections = require("tslua.collections")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local jsnum = require("tslua.jsnum")
local debug = require("tslua.debug")

local Checker = checker.Checker
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local ElementFlags = checker.ElementFlags
local CheckMode = checker.CheckMode
local WideningKind = checker.WideningKind
local CachedTypeKind = checker.CachedTypeKind
local UnionReduction = checker.UnionReduction
local SignatureKind = checker.SignatureKind
local SignatureFlags = checker.SignatureFlags
local TypeSystemPropertyName = checker.TypeSystemPropertyName
local IterationTypeKind = checker.IterationTypeKind
local TypePredicateKind = checker.TypePredicateKind
local TypeFacts = checker.TypeFacts
local MappedTypeModifiers = checker.MappedTypeModifiers
local InferenceFlags = checker.InferenceFlags
local InferencePriority = checker.InferencePriority
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local FunctionFlags = ast.FunctionFlags
local JSDeclarationKind = ast.JSDeclarationKind

-- Go slices.Contains
local function slicesContains(xs, v)
    for _, x in ipairs(xs or {}) do
        if x == v then
            return true
        end
    end
    return false
end

-- Go slices.Index (0-based, -1 if absent)
local function slicesIndex(xs, v)
    for i, x in ipairs(xs or {}) do
        if x == v then
            return i - 1
        end
    end
    return -1
end

-- Determine the control flow type associated with a destructuring declaration or assignment. The following
-- forms of destructuring are possible:
--
--	let { x } = obj;  // BindingElement
--	let [ x ] = obj;  // BindingElement
--	{ x } = obj;      // ShorthandPropertyAssignment
--	{ x: v } = obj;   // PropertyAssignment
--	[ x ] = obj;      // Expression
--
-- We construct a synthetic element access expression corresponding to 'obj.x' such that the control
-- flow analyzer doesn't have to handle all the different syntactic forms.
function Checker:getFlowTypeOfDestructuring(node, declaredType)
    local reference = self:getSyntheticElementAccess(node)
    if reference ~= nil then
        return self:getFlowTypeOfReference(reference, declaredType)
    end
    return declaredType
end

function Checker:getSyntheticElementAccess(node)
    local parentAccess = self:getParentElementAccess(node)
    if parentAccess ~= nil and checker.getFlowNodeOfNode(parentAccess) ~= nil then
        local propName, ok = self:getDestructuringPropertyName(node)
        if ok then
            local literal = self.factory:NewStringLiteral(propName, ast.TokenFlags.None)
            literal.loc = node.loc
            local lhsExpr = parentAccess
            if not ast.IsLeftHandSideExpression(parentAccess) then
                lhsExpr = self.factory:NewParenthesizedExpression(parentAccess)
                lhsExpr.loc = node.loc
            end
            local result = self.factory:NewElementAccessExpression(lhsExpr, nil, literal, NodeFlags.None)
            result.loc = node.loc
            literal.parent = result
            result.parent = node
            if lhsExpr ~= parentAccess then
                lhsExpr.parent = result
            end
            result:FlowNodeData().flowNode = checker.getFlowNodeOfNode(parentAccess)
            return result
        end
    end
    return nil
end

function Checker:getParentElementAccess(node)
    local ancestor = node.parent.parent
    local k = ancestor.kind
    if k == Kind.BindingElement or k == Kind.PropertyAssignment then
        return self:getSyntheticElementAccess(ancestor)
    elseif k == Kind.ArrayLiteralExpression then
        return self:getSyntheticElementAccess(node.parent)
    elseif k == Kind.VariableDeclaration then
        return ancestor:Initializer()
    elseif k == Kind.BinaryExpression then
        return ancestor:AsBinaryExpression().right
    end
    return nil
end

-- Return the type implied by a binding pattern. This is the type implied purely by the binding pattern itself
-- and without regard to its context (i.e. without regard any type annotation or initializer associated with the
-- declaration in which the binding pattern is contained). For example, the implied type of [x, y] is [any, any]
-- and the implied type of { x, y: z = 1 } is { x: any; y: number; }. The type implied by a binding pattern is
-- used as the contextual type of an initializer associated with the binding pattern. Also, for a destructuring
-- parameter with no type annotation or initializer, the type implied by the binding pattern becomes the type of
-- the parameter.
function Checker:getTypeFromBindingPattern(pattern, includePatternInType, reportErrors)
    if includePatternInType then
        self.contextualBindingPatterns = core.Append(self.contextualBindingPatterns, pattern)
    end
    local result
    if ast.IsObjectBindingPattern(pattern) then
        result = self:getTypeFromObjectBindingPattern(pattern, includePatternInType, reportErrors)
    else
        result = self:getTypeFromArrayBindingPattern(pattern, includePatternInType, reportErrors)
    end
    if includePatternInType then
        table.remove(self.contextualBindingPatterns)
    end
    return result
end

-- Return the type implied by an object binding pattern
function Checker:getTypeFromObjectBindingPattern(pattern, includePatternInType, reportErrors)
    local members = ast.NewSymbolTable()
    local stringIndexInfo
    local objectFlags = ObjectFlags.ObjectLiteral | ObjectFlags.ContainsObjectOrArrayLiteral
    for _, e in ipairs(pattern:Elements() or {}) do
        local name = e:PropertyNameOrName()
        if checker.hasDotDotDotToken(e) then
            stringIndexInfo = self:newIndexInfo(self.stringType, self.anyType, false --[[isReadonly]], nil, nil)
            goto continue
        end
        do
            local exprType = self:getLiteralTypeFromPropertyName(name)
            if not checker.isTypeUsableAsPropertyName(exprType) then
                -- do not include computed properties in the implied type
                objectFlags = objectFlags | ObjectFlags.ObjectLiteralPatternWithComputedProperties
                goto continue
            end
            local text = checker.getPropertyNameFromType(exprType)
            local flags = SymbolFlags.Property | core.IfElse(e:Initializer() ~= nil, SymbolFlags.Optional, 0)
            local symbol = self:newSymbol(flags, text)
            self.valueSymbolLinks:Get(symbol).resolvedType = self:getTypeFromBindingElement(e, includePatternInType, reportErrors)
            members[symbol.name] = symbol
        end
        ::continue::
    end
    local indexInfos
    if stringIndexInfo ~= nil then
        indexInfos = { stringIndexInfo }
    end
    local result = self:newAnonymousType(nil, members, nil, nil, indexInfos)
    result.objectFlags = result.objectFlags | objectFlags
    if includePatternInType then
        self.patternForType[result] = pattern
        result.objectFlags = result.objectFlags | ObjectFlags.ContainsObjectOrArrayLiteral
    end
    return result
end

-- Return the type implied by an array binding pattern
function Checker:getTypeFromArrayBindingPattern(pattern, includePatternInType, reportErrors)
    local elements = pattern:Elements() or {}
    local lastElement = core.LastOrNil(elements)
    local restElement
    if lastElement ~= nil and ast.IsBindingElement(lastElement) and checker.hasDotDotDotToken(lastElement) then
        restElement = lastElement
    end
    if #elements == 0 or #elements == 1 and restElement ~= nil then
        -- TODO: remove ScriptTargetES2015
        if self.languageVersion >= core.ScriptTarget.ES2015 then
            return self:createIterableType(self.anyType)
        end
        return self.anyArrayType
    end
    local minLength = core.FindLastIndex(elements, function(e)
        return not (e == restElement or e:Name() == nil or self:hasDefaultValue(e))
    end) + 1
    local elementTypes = {}
    local elementInfos = {}
    for i1, e in ipairs(elements) do
        local i = i1 - 1
        local t
        if e:Name() == nil then
            t = self.anyType
        else
            t = self:getTypeFromBindingElement(e, includePatternInType, reportErrors)
        end
        local flags
        if e == restElement then
            flags = ElementFlags.Rest
        elseif i >= minLength then
            flags = ElementFlags.Optional
        else
            flags = ElementFlags.Required
        end
        elementTypes[i1] = t
        elementInfos[i1] = checker.TupleElementInfo_new({ flags = flags })
    end
    local result = self:createTupleTypeEx(elementTypes, elementInfos, false)
    if includePatternInType then
        result = self:cloneTypeReference(result)
        self.patternForType[result] = pattern
        result.objectFlags = result.objectFlags | ObjectFlags.ContainsObjectOrArrayLiteral
    end
    return result
end

-- Return the type implied by a binding pattern element. This is the type of the initializer of the element if
-- one is present. Otherwise, if the element is itself a binding pattern, it is the type implied by the binding
-- pattern. Otherwise, it is the type any.
function Checker:getTypeFromBindingElement(element, includePatternInType, reportErrors)
    if element:Initializer() ~= nil then
        -- The type implied by a binding pattern is independent of context, so we check the initializer with no
        -- contextual type or, if the element itself is a binding pattern, with the type implied by that binding
        -- pattern.
        local contextualType = self.unknownType
        if ast.IsBindingPattern(element:Name()) then
            contextualType = self:getTypeFromBindingPattern(element:Name(), true --[[includePatternInType]], false --[[reportErrors]])
        end
        return self:addOptionality(self:getWidenedLiteralTypeForInitializer(element, self:checkDeclarationInitializer(element, CheckMode.Normal, contextualType)))
    end
    if ast.IsBindingPattern(element:Name()) then
        return self:getTypeFromBindingPattern(element:Name(), includePatternInType, reportErrors)
    end
    if reportErrors and not self:declarationBelongsToPrivateAmbientMember(element) then
        self:reportImplicitAny(element, self.anyType, WideningKind.Normal)
    end
    -- When we're including the pattern in the type (an indication we're obtaining a contextual type), we
    -- use a non-inferrable any type. Inference will never directly infer this type, but it is possible
    -- to infer a type that contains it, e.g. for a binding pattern like [foo] or { foo }. In such cases,
    -- widening of the binding pattern type substitutes a regular any for the non-inferrable any.
    if includePatternInType then
        return self.nonInferrableAnyType
    end
    return self.anyType
end

function Checker:declarationBelongsToPrivateAmbientMember(declaration)
    local memberDeclaration = ast.GetRootDeclaration(declaration)
    if ast.IsParameterDeclaration(memberDeclaration) then
        memberDeclaration = memberDeclaration.parent
    end
    return checker.isPrivateWithinAmbient(memberDeclaration)
end

function Checker:getTypeOfPrototypeProperty(prototype)
    -- TypeScript 1.0 spec (April 2014): 8.4
    -- Every class automatically contains a static property member named 'prototype',
    -- the type of which is an instantiation of the class type with type Any supplied as a type argument for each type parameter.
    -- It is an error to explicitly declare a static property member with the name 'prototype'.
    local classType = self:getDeclaredTypeOfSymbol(self:getParentOfSymbol(prototype))
    local typeParameters = classType:AsInterfaceType():TypeParameters()
    if core.Len(typeParameters) ~= 0 then
        return self:createTypeReference(classType, core.Map(typeParameters, function()
            return self.anyType
        end))
    end
    return classType
end

-- thisAssignmentDeclarationKind (unexported Go enum)
checker.thisAssignmentDeclarationNone = 0 -- not (all) this.property assignments
checker.thisAssignmentDeclarationTyped = 1 -- typed; use the type annotation
checker.thisAssignmentDeclarationConstructor = 2 -- at least one in the constructor; use control flow
checker.thisAssignmentDeclarationMethod = 3 -- methods only; look in base first, and if not found, union all declaration types plus undefined

function Checker:getWidenedTypeForAssignmentDeclaration(symbol)
    local t
    local kind, location = self:isConstructorDeclaredThisProperty(symbol)
    if kind == checker.thisAssignmentDeclarationTyped then
        if location == nil then
            error("location should not be nil when this assignment has a type.", 0)
        end
        t = self:getTypeFromTypeNode(location)
    elseif kind == checker.thisAssignmentDeclarationConstructor then
        if location == nil then
            error("constructor should not be nil when this assignment is in a constructor.", 0)
        end
        t = self:getFlowTypeInConstructor(symbol, location)
    elseif kind == checker.thisAssignmentDeclarationMethod then
        t = self:getTypeOfPropertyInBaseClass(symbol)
    end
    if t == nil then
        local types
        for i1, declaration in ipairs(symbol.declarations or {}) do
            local i = i1 - 1
            if ast.IsBinaryExpression(declaration) and declaration:Type() ~= nil then
                t = self:getTypeFromTypeNode(declaration:Type())
                break
            end
            local assignedType = self:getAssignmentDeclarationInitializerType(declaration)
            if assignedType ~= nil then
                -- We ignore initial assignments of undefined to CommonJS exports when there are multiple assignment declarations
                if ast.GetAssignmentDeclarationKind(declaration) ~= JSDeclarationKind.ExportsProperty or i ~= 0 or #symbol.declarations == 1 or assignedType.flags & TypeFlags.Undefined == 0 then
                    types = core.AppendIfUnique(types, assignedType)
                end
            end
        end
        if kind == checker.thisAssignmentDeclarationMethod and core.Len(types) > 0 then
            if self.strictNullChecks then
                types = core.AppendIfUnique(types, self.undefinedOrMissingType)
            end
        end
        if t == nil then
            t = self.anyType
            if core.Len(types) ~= 0 then
                t = self:getUnionType(types)
            end
        end
    end
    t = self:getWidenedType(t)
    -- report an all-nullable or empty union as an implicit any in JS files
    if symbol.valueDeclaration ~= nil and ast.IsInJSFile(symbol.valueDeclaration) and
        self:filterType(t, function(c) return c:Flags() & ~TypeFlags.Nullable ~= 0 end) == self.neverType then
        self:reportImplicitAny(symbol.valueDeclaration, self.anyType, WideningKind.Normal)
        return self.anyType
    end
    return t
end

function Checker:getAssignmentDeclarationInitializerType(node)
    if ast.IsBinaryExpression(node) then
        local t
        local k = ast.GetAssignmentDeclarationKind(node)
        if k == JSDeclarationKind.ModuleExports or k == JSDeclarationKind.ExportsProperty then
            t = self:getRegularTypeOfLiteralType(self:checkExpressionCached(ast.GetRightMostAssignedExpression(node)))
        else
            if k == JSDeclarationKind.ThisProperty then
                if self:containsSameNamedThisProperty(node:AsBinaryExpression().left, node:AsBinaryExpression().right) then
                    return nil
                end
                -- fallthrough
            end
            t = self:checkExpressionForMutableLocation(node:AsBinaryExpression().right, CheckMode.Normal)
        end
        if self:isEmptyArrayLiteralType(t) and not self:hasParentWithTypeAnnotation(node:Symbol()) then
            self:reportImplicitAny(node, self.anyArrayType, WideningKind.Normal)
            return self.anyArrayType
        end
        return t
    end
    if ast.IsCallExpression(node) then
        return self:getTypeFromPropertyDescriptor(node:Arguments()[3])
    end
    return nil
end

-- Return true if the parent symbol of the given assignment declaration symbol has declaration with a type
-- annotation. For example, returns true for the symbol associated with `f.a` below:
--
--	const f: { (): void, a: string[] } = () => {};
--	f.a = [];
function Checker:hasParentWithTypeAnnotation(symbol)
    if symbol.parent ~= nil and symbol.parent.valueDeclaration ~= nil and ast.IsFunctionExpressionOrArrowFunction(symbol.parent.valueDeclaration) then
        local possiblyAnnotatedSymbol = self:getSymbolOfNode(symbol.parent.valueDeclaration.parent)
        if possiblyAnnotatedSymbol ~= nil and possiblyAnnotatedSymbol.valueDeclaration ~= nil then
            return possiblyAnnotatedSymbol.valueDeclaration:Type() ~= nil
        end
    end
    return false
end

function Checker:containsSameNamedThisProperty(thisProperty, expression)
    local visit
    visit = function(node)
        if self:isMatchingReference(thisProperty, node) then
            return true
        end
        if ast.IsFunctionLike(node) then
            return false
        end
        return node:ForEachChild(visit)
    end
    return visit(expression)
end

function Checker:getTypeFromPropertyDescriptor(node)
    local objectLiteralType = self:checkExpressionCached(node)
    local valueType = self:getTypeOfPropertyOfType(objectLiteralType, "value")
    if valueType ~= nil then
        return valueType
    end
    local getFunc = self:getTypeOfPropertyOfType(objectLiteralType, "get")
    if getFunc ~= nil then
        local getSig = self:getSingleCallSignature(getFunc)
        if getSig ~= nil then
            return self:getReturnTypeOfSignature(getSig)
        end
    end
    local setFunc = self:getTypeOfPropertyOfType(objectLiteralType, "set")
    if setFunc ~= nil then
        local setSig = self:getSingleCallSignature(setFunc)
        if setSig ~= nil then
            return self:getTypeOfFirstParameterOfSignature(setSig)
        end
    end
    return self.anyType
end

-- A property is considered a constructor declared property when all declaration sites are this.xxx assignments,
-- when no declaration sites have JSDoc type annotations, and when at least one declaration site is in the body of
-- a class constructor.
function Checker:isConstructorDeclaredThisProperty(symbol)
    if symbol.valueDeclaration == nil or not ast.IsBinaryExpression(symbol.valueDeclaration) then
        return checker.thisAssignmentDeclarationNone, nil
    end
    local cachedKind = self.thisExpandoKinds[symbol]
    if cachedKind ~= nil then
        -- thisExpandoLocations stores false for a nil location so that presence can be tested.
        local cachedLocation = self.thisExpandoLocations[symbol]
        if cachedLocation == nil then
            error("location should be cached whenever this expando symbol is cached", 0)
        end
        return cachedKind, cachedLocation or nil
    end
    local allThis = true
    local typeAnnotation
    for _, declaration in ipairs(symbol.declarations or {}) do
        if not ast.IsBinaryExpression(declaration) then
            allThis = false
            break
        end
        local bin = declaration:AsBinaryExpression()
        if ast.GetAssignmentDeclarationKind(declaration) == JSDeclarationKind.ThisProperty and
            (bin.left.kind ~= Kind.ElementAccessExpression or ast.IsStringOrNumericLiteralLike(bin.left:AsElementAccessExpression().argumentExpression)) then
            if bin.type ~= nil then
                typeAnnotation = bin.type
            end
        else
            allThis = false
            break
        end
    end
    local location
    local kind = checker.thisAssignmentDeclarationNone
    if allThis then
        if typeAnnotation ~= nil then
            location = typeAnnotation
            kind = checker.thisAssignmentDeclarationTyped
        else
            location = self:getDeclaringConstructor(symbol)
            kind = core.IfElse(location == nil, checker.thisAssignmentDeclarationMethod, checker.thisAssignmentDeclarationConstructor)
        end
    end
    self.thisExpandoKinds[symbol] = kind
    self.thisExpandoLocations[symbol] = location or false
    return kind, location
end

function Checker:isGlobalSymbolConstructor(node)
    local symbol = self:getSymbolOfNode(node)
    local globalSymbol = self.getGlobalESSymbolConstructorTypeSymbolOrNil()
    return globalSymbol ~= nil and symbol == globalSymbol
end

function Checker:widenTypeForVariableLikeDeclaration(t, declaration, reportErrors)
    if t ~= nil then
        -- This special case is required for backwards compatibility with libraries that merge a `symbol` property into `SymbolConstructor`.
        -- See https://github.com/microsoft/typescript-go/issues/1212
        if t.flags & TypeFlags.ESSymbol ~= 0 and self:isGlobalSymbolConstructor(declaration.parent) then
            t = self:getESSymbolLikeTypeForNode(declaration)
        end

        if reportErrors then
            self:reportErrorsFromWidening(declaration, t, WideningKind.Normal)
        end

        -- always widen a 'unique symbol' type if the type was created for a different declaration.
        if t.flags & TypeFlags.UniqueESSymbol ~= 0 and (ast.IsBindingElement(declaration) or declaration:Type() == nil) and t.symbol ~= self:getSymbolOfDeclaration(declaration) then
            t = self.esSymbolType
        end
        return self:getWidenedType(t)
    end
    -- Rest parameters default to type any[], other parameters default to type any
    if ast.IsParameterDeclaration(declaration) and declaration:AsParameterDeclaration().dotDotDotToken ~= nil then
        t = self.anyArrayType
    else
        t = self.anyType
    end
    -- Report implicit any errors unless this is a private property within an ambient declaration
    if reportErrors then
        if not checker.declarationBelongsToPrivateAmbientMember(declaration) then
            self:reportImplicitAny(declaration, t, WideningKind.Normal)
        end
    end
    return t
end

function Checker:reportImplicitAny(declaration, t, wideningKind)
    if ast.IsInJSFile(declaration) and not ast.IsCheckJSEnabledForFile(ast.GetSourceFileOfNode(declaration), self.compilerOptions) then
        -- Only report implicit any errors/suggestions in TS and ts-check JS files
        return
    end
    local typeAsString = self:TypeToString(self:getWidenedType(t))
    local diagnostic
    local k = declaration.kind
    if k == Kind.BinaryExpression or k == Kind.PropertyDeclaration or k == Kind.PropertySignature then
        diagnostic = core.IfElse(self.noImplicitAny,
            diagnostics.Member_0_implicitly_has_an_1_type,
            diagnostics.Member_0_implicitly_has_an_1_type_but_a_better_type_may_be_inferred_from_usage)
    elseif k == Kind.Parameter then
        local param = declaration:AsParameterDeclaration()
        if ast.IsIdentifier(param:Name()) then
            local name = param:Name():AsIdentifier()
            local originalKeywordKind = scanner.IdentifierToKeywordKind(name)
            if (ast.IsCallSignatureDeclaration(declaration.parent) or ast.IsMethodSignatureDeclaration(declaration.parent) or ast.IsFunctionTypeNode(declaration.parent)) and
                slicesContains(declaration.parent:Parameters(), declaration) and
                (ast.IsTypeNodeKind(originalKeywordKind) or self.resolveName(declaration, name.text, SymbolFlags.Type, nil --[[nameNotFoundMessage]], true --[[isUse]], false --[[excludeGlobals]]) ~= nil) then
                local newName = "arg" .. slicesIndex(declaration.parent:Parameters(), declaration)
                local typeName = scanner.DeclarationNameToString(param:Name()) .. core.IfElse(param.dotDotDotToken ~= nil, "[]", "")
                self:errorOrSuggestion(self.noImplicitAny, declaration, diagnostics.Parameter_has_a_name_but_no_type_Did_you_mean_0_Colon_1, newName, typeName)
                return
            end
        end
        if param.dotDotDotToken ~= nil then
            if self.noImplicitAny then
                diagnostic = diagnostics.Rest_parameter_0_implicitly_has_an_any_type
            else
                diagnostic = diagnostics.Rest_parameter_0_implicitly_has_an_any_type_but_a_better_type_may_be_inferred_from_usage
            end
        elseif self.noImplicitAny then
            diagnostic = diagnostics.Parameter_0_implicitly_has_an_1_type
        else
            diagnostic = diagnostics.Parameter_0_implicitly_has_an_1_type_but_a_better_type_may_be_inferred_from_usage
        end
    elseif k == Kind.BindingElement then
        diagnostic = diagnostics.Binding_element_0_implicitly_has_an_1_type
        if not self.noImplicitAny then
            -- Don't issue a suggestion for binding elements since the codefix doesn't yet support them.
            return
        end
    elseif k == Kind.FunctionDeclaration or k == Kind.MethodDeclaration or k == Kind.MethodSignature or k == Kind.GetAccessor or
        k == Kind.SetAccessor or k == Kind.FunctionExpression or k == Kind.ArrowFunction then
        if self.noImplicitAny and declaration:Name() == nil then
            if wideningKind == WideningKind.GeneratorYield then
                self:error(declaration, diagnostics.Generator_implicitly_has_yield_type_0_Consider_supplying_a_return_type_annotation, typeAsString)
            else
                self:error(declaration, diagnostics.Function_expression_which_lacks_return_type_annotation_implicitly_has_an_0_return_type, typeAsString)
            end
            return
        end
        if not self.noImplicitAny then
            diagnostic = diagnostics.X_0_implicitly_has_an_1_return_type_but_a_better_type_may_be_inferred_from_usage
        elseif declaration.flags & NodeFlags.Reparsed ~= 0 then
            local name = scanner.DeclarationNameToString(ast.GetNameOfDeclaration(declaration))
            if name ~= "" then
                self:error(declaration, diagnostics.X_0_which_lacks_return_type_annotation_implicitly_has_an_1_return_type, name, typeAsString)
            else
                self:error(declaration, diagnostics.This_overload_implicitly_returns_the_type_0_because_it_lacks_a_return_type_annotation, typeAsString)
            end
            return
        elseif wideningKind == WideningKind.GeneratorYield then
            diagnostic = diagnostics.X_0_which_lacks_return_type_annotation_implicitly_has_an_1_yield_type
        else
            diagnostic = diagnostics.X_0_which_lacks_return_type_annotation_implicitly_has_an_1_return_type
        end
    elseif k == Kind.MappedType then
        if self.noImplicitAny then
            self:error(declaration, diagnostics.Mapped_object_type_implicitly_has_an_any_template_type)
        end
        return
    else
        if self.noImplicitAny then
            diagnostic = diagnostics.Variable_0_implicitly_has_an_1_type
        else
            diagnostic = diagnostics.Variable_0_implicitly_has_an_1_type_but_a_better_type_may_be_inferred_from_usage
        end
    end
    self:errorOrSuggestion(self.noImplicitAny, declaration, diagnostic, scanner.DeclarationNameToString(ast.GetNameOfDeclaration(declaration)), typeAsString)
end

function Checker:getWidenedType(t)
    return self:getWidenedTypeWithContext(t, nil --[[context]])
end

function Checker:getWidenedTypeWithContext(t, context)
    if t.objectFlags & ObjectFlags.RequiresWidening ~= 0 then
        if context == nil then
            local cached = self.cachedTypes[checker.CachedTypeKey(CachedTypeKind.Widened, t.id)]
            if cached ~= nil then
                return cached
            end
        end
        local result
        if t.flags & (TypeFlags.Any | TypeFlags.Nullable) ~= 0 then
            result = self.anyType
        elseif checker.isObjectLiteralType(t) then
            result = self:getWidenedTypeOfObjectLiteral(t, context)
        elseif t.flags & TypeFlags.Union ~= 0 then
            local unionContext = context
            if unionContext == nil then
                unionContext = checker.WideningContext_new({ siblings = t:Types() })
            end
            local widenedTypes = core.SameMap(t:Types(), function(u)
                if u.flags & TypeFlags.Nullable ~= 0 then
                    return u
                end
                return self:getWidenedTypeWithContext(u, unionContext)
            end)
            -- Widening an empty object literal transitions from a highly restrictive type to
            -- a highly inclusive one. For that reason we perform subtype reduction here if the
            -- union includes empty object types (e.g. reducing {} | string to just {}).
            result = self:getUnionTypeEx(widenedTypes, core.IfElse(core.Some(widenedTypes, function(x) return self:isEmptyObjectType(x) end), UnionReduction.Subtype, UnionReduction.Literal), nil, nil)
        elseif t.flags & TypeFlags.Intersection ~= 0 then
            result = self:getIntersectionType(core.SameMap(t:Types(), function(x) return self:getWidenedType(x) end))
        elseif self:isArrayOrTupleType(t) then
            result = self:createTypeReference(t:Target(), core.SameMap(self:getTypeArguments(t), function(x) return self:getWidenedType(x) end))
        end
        if result ~= nil and context == nil then
            self.cachedTypes[checker.CachedTypeKey(CachedTypeKind.Widened, t.id)] = result
        end
        return core.OrElse(result, t)
    end
    return t
end

function Checker:getWidenedTypeOfObjectLiteral(t, context)
    if context ~= nil then
        local cached = context.widenedTypes and context.widenedTypes[t]
        if cached ~= nil then
            return cached
        end
    end
    local members = ast.NewSymbolTable()
    for _, prop in ipairs(self:getPropertiesOfObjectType(t) or {}) do
        members[prop.name] = self:getWidenedProperty(prop, context)
    end
    if context ~= nil then
        for _, prop in ipairs(self:getPropertiesOfContext(context) or {}) do
            if members[prop.name] == nil then
                members[prop.name] = self:getUndefinedProperty(prop)
            end
        end
    end
    local result = self:newAnonymousType(t.symbol, members, nil, nil, core.SameMap(self:getIndexInfosOfType(t), function(info)
        return self:newIndexInfo(info.keyType, self:getWidenedType(info.valueType), info.isReadonly, info.declaration, info.components)
    end))
    -- Retain js literal flag through widening
    result.objectFlags = result.objectFlags | t.objectFlags & (ObjectFlags.JSLiteral | ObjectFlags.NonInferrableType)
    -- Only cache in child contexts since the root context never widens a particular object literal type more than once
    if context ~= nil and context.parent ~= nil then
        if context.widenedTypes == nil then
            context.widenedTypes = {}
        end
        context.widenedTypes[t] = result
    end
    return result
end

function Checker:getWidenedProperty(prop, context)
    if prop.flags & SymbolFlags.Property == 0 then
        -- Since get accessors already widen their return value there is no need to
        -- widen accessor based properties here.
        return prop
    end
    local original = self:getTypeOfSymbol(prop)
    local propContext
    if context ~= nil then
        propContext = context:getChildContext(prop.name)
    end
    local widened = self:getWidenedTypeWithContext(original, propContext)
    if widened == original then
        return prop
    end
    return self:createSymbolWithType(prop, widened)
end

function checker.WideningContext:getChildContext(propertyName)
    local cached = self.childContexts and self.childContexts[propertyName]
    if cached ~= nil then
        return cached
    end
    local result = checker.WideningContext_new({ parent = self, propertyName = propertyName })
    if self.childContexts == nil then
        self.childContexts = {}
    end
    self.childContexts[propertyName] = result
    return result
end

function Checker:getPropertiesOfContext(context)
    if context.resolvedProperties == nil then
        local names = collections.NewOrderedMapWithSizeHint(0)
        for _, t in ipairs(self:getSiblingsOfContext(context) or {}) do
            if checker.isObjectLiteralType(t) and t.objectFlags & checker.ObjectFlagsContainsSpread == 0 then
                for _, prop in ipairs(self:getPropertiesOfType(t) or {}) do
                    names:Set(prop.name, prop)
                end
            end
        end
        local values = core.Collect(names:Values())
        if #values == 0 then
            values = nil -- Go slices.Collect of an empty sequence is nil
        end
        context.resolvedProperties = values
    end
    return context.resolvedProperties
end

function Checker:getSiblingsOfContext(context)
    if context.siblings == nil then
        local siblings = {}
        for _, t in ipairs(self:getSiblingsOfContext(context.parent) or {}) do
            if checker.isObjectLiteralType(t) then
                local prop = self:getPropertyOfObjectType(t, context.propertyName)
                if prop ~= nil then
                    for _, d in ipairs(self:getTypeOfSymbol(prop):Distributed() or {}) do
                        siblings[#siblings + 1] = d
                    end
                end
            end
        end
        context.siblings = siblings
    end
    return context.siblings
end

function Checker:getUndefinedProperty(prop)
    local cached = self.undefinedProperties[prop.name]
    if cached ~= nil then
        return cached
    end
    local result = self:createSymbolWithType(prop, self.undefinedOrMissingType)
    result.flags = result.flags | SymbolFlags.Optional
    self.undefinedProperties[prop.name] = result
    return result
end

function Checker:getTypeOfEnumMember(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        links.resolvedType = self:getDeclaredTypeOfEnumMember(symbol)
    end
    return links.resolvedType
end

function Checker:getTypeOfAccessors(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        if not self:pushTypeResolution(symbol, TypeSystemPropertyName.Type) then
            return self.errorType
        end
        local getter = ast.GetDeclarationOfKind(symbol, Kind.GetAccessor)
        local setter = ast.GetDeclarationOfKind(symbol, Kind.SetAccessor)
        local accessor = core.Find(symbol.declarations, ast.IsAutoAccessorPropertyDeclaration)
        -- We try to resolve a getter type annotation, a setter type annotation, or a getter function
        -- body return type inference, in that order.
        local t = self:getAnnotatedAccessorType(getter)
        if t == nil then
            t = self:getAnnotatedAccessorType(setter)
        end
        if t == nil then
            t = self:getAnnotatedAccessorType(accessor)
        end
        if t == nil and getter ~= nil then
            local body = getter:Body()
            if body ~= nil then
                t = self:getReturnTypeFromBody(getter, CheckMode.Normal)
            end
        end
        if t == nil and accessor ~= nil then
            t = self:getWidenedTypeForVariableLikeDeclaration(accessor, true --[[reportErrors]])
        end
        if t == nil then
            if setter ~= nil and not checker.isPrivateWithinAmbient(setter) then
                self:errorOrSuggestion(self.noImplicitAny, setter, diagnostics.Property_0_implicitly_has_type_any_because_its_set_accessor_lacks_a_parameter_type_annotation, self:symbolToString(symbol))
            elseif getter ~= nil and not checker.isPrivateWithinAmbient(getter) then
                self:errorOrSuggestion(self.noImplicitAny, getter, diagnostics.Property_0_implicitly_has_type_any_because_its_get_accessor_lacks_a_return_type_annotation, self:symbolToString(symbol))
            elseif accessor ~= nil and not checker.isPrivateWithinAmbient(accessor) then
                self:errorOrSuggestion(self.noImplicitAny, accessor, diagnostics.Member_0_implicitly_has_an_1_type, self:symbolToString(symbol), "any")
            end
            t = self.anyType
        end
        if not self:popTypeResolution() then
            if self:getAnnotatedAccessorTypeNode(getter) ~= nil then
                self:error(getter, diagnostics.X_0_is_referenced_directly_or_indirectly_in_its_own_type_annotation, self:symbolToString(symbol))
            elseif self:getAnnotatedAccessorTypeNode(setter) ~= nil then
                self:error(setter, diagnostics.X_0_is_referenced_directly_or_indirectly_in_its_own_type_annotation, self:symbolToString(symbol))
            elseif self:getAnnotatedAccessorTypeNode(accessor) ~= nil then
                self:error(setter, diagnostics.X_0_is_referenced_directly_or_indirectly_in_its_own_type_annotation, self:symbolToString(symbol))
            elseif getter ~= nil and self.noImplicitAny then
                self:error(getter, diagnostics.X_0_implicitly_has_return_type_any_because_it_does_not_have_a_return_type_annotation_and_is_referenced_directly_or_indirectly_in_one_of_its_return_expressions, self:symbolToString(symbol))
            end
            t = self.anyType
        end
        if links.resolvedType == nil then
            links.resolvedType = t
        end
    end
    return links.resolvedType
end

function Checker:getWriteTypeOfAccessors(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.writeType == nil then
        if not self:pushTypeResolution(symbol, TypeSystemPropertyName.WriteType) then
            return self.errorType
        end
        local setter = ast.GetDeclarationOfKind(symbol, Kind.SetAccessor)
        if setter == nil then
            local propDeclaration = ast.GetDeclarationOfKind(symbol, Kind.PropertyDeclaration)
            if propDeclaration ~= nil and ast.IsAutoAccessorPropertyDeclaration(propDeclaration) then
                setter = propDeclaration
            end
        end
        local writeType = self:getAnnotatedAccessorType(setter)
        if not self:popTypeResolution() then
            if self:getAnnotatedAccessorTypeNode(setter) ~= nil then
                self:error(setter, diagnostics.X_0_is_referenced_directly_or_indirectly_in_its_own_type_annotation, self:symbolToString(symbol))
            end
            writeType = self.anyType
        end
        -- Absent an explicit setter type annotation we use the read type of the accessor.
        if links.writeType == nil then
            if writeType ~= nil then
                links.writeType = writeType
            else
                links.writeType = self:getTypeOfAccessors(symbol)
            end
        end
    end
    return links.writeType
end

function Checker:getTypeOfAlias(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        if not self:pushTypeResolution(symbol, TypeSystemPropertyName.Type) then
            return self.errorType
        end
        local targetSymbol = self:resolveAlias(symbol)
        local exportSymbol = self:getTargetOfAliasDeclaration(self:getDeclarationOfAliasSymbol(symbol))
        -- It only makes sense to get the type of a value symbol. If the result of resolving
        -- the alias is not a value, then it has no type. To get the type associated with a
        -- type symbol, call getDeclaredTypeOfSymbol.
        -- This check is important because without it, a call to getTypeOfSymbol could end
        -- up recursively calling getTypeOfAlias, causing a stack overflow.
        if links.resolvedType == nil then
            if self:getSymbolFlags(targetSymbol) & SymbolFlags.Value ~= 0 then
                links.resolvedType = self:getTypeOfSymbol(targetSymbol)
            else
                links.resolvedType = self.errorType
            end
        end
        if not self:popTypeResolution() then
            self:reportCircularityError(core.OrElse(exportSymbol, symbol))
            if links.resolvedType == nil then
                links.resolvedType = self.errorType
            end
            return links.resolvedType
        end
    end
    return links.resolvedType
end

function Checker:addOptionality(t)
    return self:addOptionalityEx(t, false --[[isProperty]], true --[[isOptional]])
end

function Checker:addOptionalityEx(t, isProperty, isOptional)
    if self.strictNullChecks and isOptional then
        return self:getOptionalType(t, isProperty)
    end
    return t
end

function Checker:getOptionalType(t, isProperty)
    debug.Assert(self.strictNullChecks)
    local missingOrUndefined = core.IfElse(isProperty, self.undefinedOrMissingType, self.undefinedType)
    if t == missingOrUndefined or t.flags & TypeFlags.Union ~= 0 and t:Types()[1] == missingOrUndefined then
        return t
    end
    return self:getUnionType({ t, missingOrUndefined })
end

-- Add undefined or null or both to a type if they are missing.
function Checker:getNullableType(t, flags)
    local missing = (flags & ~t.flags) & (TypeFlags.Undefined | TypeFlags.Null)
    if missing == 0 then
        return t
    elseif missing == TypeFlags.Undefined then
        return self:getUnionType({ t, self.undefinedType })
    elseif missing == TypeFlags.Null then
        return self:getUnionType({ t, self.nullType })
    end
    return self:getUnionType({ t, self.undefinedType, self.nullType })
end

function Checker:GetNonNullableType(t)
    if self.strictNullChecks then
        return self:getAdjustedTypeWithFacts(t, TypeFacts.NEUndefinedOrNull)
    end
    return t
end

function Checker:IsNullableType(t)
    return self:hasTypeFacts(t, TypeFacts.IsUndefinedOrNull)
end

function Checker:getNonNullableTypeIfNeeded(t)
    if self:IsNullableType(t) then
        return self:GetNonNullableType(t)
    end
    return t
end

function Checker:getDeclarationNodeFlagsFromSymbol(s)
    if s.valueDeclaration ~= nil then
        return self:getCombinedNodeFlagsCached(s.valueDeclaration)
    end
    return NodeFlags.None
end

function Checker:getCombinedNodeFlagsCached(node)
    -- we hold onto the last node and result to speed up repeated lookups against the same node.
    if self.lastGetCombinedNodeFlagsNode == node then
        return self.lastGetCombinedNodeFlagsResult
    end
    self.lastGetCombinedNodeFlagsNode = node
    self.lastGetCombinedNodeFlagsResult = ast.GetCombinedNodeFlags(node)
    return self.lastGetCombinedNodeFlagsResult
end

function Checker:isVarConstLike(node)
    local blockScopeKind = self:getCombinedNodeFlagsCached(node) & NodeFlags.BlockScoped
    return blockScopeKind == NodeFlags.Const or blockScopeKind == NodeFlags.Using or blockScopeKind == NodeFlags.AwaitUsing
end

function Checker:getEffectivePropertyNameForPropertyNameNode(node)
    local name = ast.GetPropertyNameForPropertyNameNode(node)
    if name ~= ast.InternalSymbolNameMissing then
        return name, true
    elseif ast.IsComputedPropertyName(node) then
        -- This is cached so `getTypeOfExpression` isn't constantly reinvoked for every property name lookup
        local links = self.computedNameLinks:Get(node)
        if links ~= nil and links.hasName ~= nil then
            return links.name, links.hasName
        end
        local exists
        name, exists = self:tryGetNameFromType(self:getTypeOfExpression(node:Expression()))
        links.name = name
        links.hasName = exists
        return name, exists
    end
    return "", false
end

function Checker:tryGetNameFromType(t)
    if t.flags & TypeFlags.UniqueESSymbol ~= 0 then
        return t:AsUniqueESSymbolType().name, true
    elseif t.flags & TypeFlags.StringLiteral ~= 0 then
        local s = checker.getStringLiteralValue(t)
        return s, true
    elseif t.flags & TypeFlags.NumberLiteral ~= 0 then
        local s = jsnum.Number_String(checker.getNumberLiteralValue(t))
        return s, true
    else
        return "", false
    end
end

function Checker:getCombinedModifierFlagsCached(node)
    -- we hold onto the last node and result to speed up repeated lookups against the same node.
    if self.lastGetCombinedModifierFlagsNode == node then
        return self.lastGetCombinedModifierFlagsResult
    end
    self.lastGetCombinedModifierFlagsNode = node
    self.lastGetCombinedModifierFlagsResult = ast.GetCombinedModifierFlags(node)
    return self.lastGetCombinedModifierFlagsResult
end

--[[*
 * Push an entry on the type resolution stack. If an entry with the given target and the given property name
 * is already on the stack, and no entries in between already have a type, then a circularity has occurred.
 * In this case, the result values of the existing entry and all entries pushed after it are changed to false,
 * and the value false is returned. Otherwise, the new entry is just pushed onto the stack, and true is returned.
 * In order to see if the same query has already been done before, the target object and the propertyName both
 * must match the one passed in.
 *
 * @param target The symbol, type, or signature whose type is being queried
 * @param propertyName The property name that should be used to query the target for its type
 ]]
function Checker:pushTypeResolution(target, propertyName)
    local resolutionCycleStartIndex = self:findResolutionCycleStartIndex(target, propertyName)
    if resolutionCycleStartIndex >= 0 then
        -- A cycle was found
        for i = resolutionCycleStartIndex, #self.typeResolutions - 1 do
            self.typeResolutions[i + 1].result = false
        end
        return false
    end
    self.typeResolutions[#self.typeResolutions + 1] = checker.TypeResolution_new({ target = target, propertyName = propertyName, result = true })
    return true
end

--[[*
 * Pop an entry from the type resolution stack and return its associated result value. The result value will
 * be true if no circularities were detected, or false if a circularity was found.
 ]]
function Checker:popTypeResolution()
    local lastIndex = #self.typeResolutions - 1
    local result = self.typeResolutions[lastIndex + 1].result
    self.typeResolutions[lastIndex + 1] = nil -- Clear the last entry to avoid memory leaks
    return result
end

function Checker:findResolutionCycleStartIndex(target, propertyName)
    for i = #self.typeResolutions - 1, self.resolutionStart, -1 do
        local resolution = self.typeResolutions[i + 1]
        if self:typeResolutionHasProperty(resolution) then
            return -1
        end
        if resolution.target == target and resolution.propertyName == propertyName then
            return i
        end
    end
    return -1
end

function Checker:typeResolutionHasProperty(r)
    local p = r.propertyName
    if p == TypeSystemPropertyName.Type then
        return self.valueSymbolLinks:Get(r.target).resolvedType ~= nil
    elseif p == TypeSystemPropertyName.DeclaredType then
        return self.typeAliasLinks:Get(r.target).declaredType ~= nil
    elseif p == TypeSystemPropertyName.ResolvedTypeArguments then
        return r.target:AsTypeReference().resolvedTypeArguments ~= nil
    elseif p == TypeSystemPropertyName.ResolvedBaseTypes then
        return r.target:AsInterfaceType().baseTypesResolved
    elseif p == TypeSystemPropertyName.ResolvedBaseConstructorType then
        return r.target:AsInterfaceType().resolvedBaseConstructorType ~= nil
    elseif p == TypeSystemPropertyName.ResolvedReturnType then
        return r.target.resolvedReturnType ~= nil
    elseif p == TypeSystemPropertyName.ResolvedBaseConstraint then
        return r.target:AsConstrainedType().resolvedBaseConstraint ~= nil
    elseif p == TypeSystemPropertyName.InitializerIsUndefined then
        return self.nodeLinks:Get(r.target).flags & checker.NodeCheckFlags.InitializerIsUndefinedComputed ~= 0
    elseif p == TypeSystemPropertyName.WriteType then
        return self.valueSymbolLinks:Get(r.target).writeType ~= nil
    elseif p == TypeSystemPropertyName.AliasTarget then
        return self.aliasSymbolLinks:Get(r.target).aliasTarget ~= nil
    end
    error("Unhandled case in typeResolutionHasProperty", 0)
end

function Checker:reportCircularityError(symbol)
    local declaration = symbol.valueDeclaration
    -- Check if variable has type annotation that circularly references the variable itself
    if declaration ~= nil then
        if declaration:Type() ~= nil then
            self:error(symbol.valueDeclaration, diagnostics.X_0_is_referenced_directly_or_indirectly_in_its_own_type_annotation, self:symbolToString(symbol))
            return self.errorType
        end
        -- Check if variable has initializer that circularly references the variable itself
        if self.noImplicitAny and (not ast.IsParameterDeclaration(declaration) or declaration:Initializer() ~= nil) then
            self:error(symbol.valueDeclaration, diagnostics.X_0_implicitly_has_type_any_because_it_does_not_have_a_type_annotation_and_is_referenced_directly_or_indirectly_in_its_own_initializer, self:symbolToString(symbol))
        end
    elseif symbol.flags & SymbolFlags.Alias ~= 0 then
        local node = self:getDeclarationOfAliasSymbol(symbol)
        if node ~= nil then
            self:error(node, diagnostics.Circular_definition_of_import_alias_0, self:symbolToString(symbol))
        end
    end
    -- Circularities could also result from parameters in function expressions that end up
    -- having themselves as contextual types following type argument inference. In those cases
    -- we have already reported an implicit any error so we don't report anything here.
    return self.anyType
end

function Checker:getPropertiesOfType(t)
    t = self:getReducedApparentType(t)
    if t.flags & TypeFlags.UnionOrIntersection ~= 0 then
        return self:getPropertiesOfUnionOrIntersectionType(t)
    end
    return self:getPropertiesOfObjectType(t)
end

function Checker:getPropertiesOfObjectType(t)
    if t.flags & TypeFlags.Object ~= 0 then
        return self:resolveStructuredTypeMembers(t).properties
    end
    return nil
end

function Checker:getPropertiesOfUnionOrIntersectionType(t)
    local d = t:AsUnionOrIntersectionType()
    if d.resolvedProperties == nil then
        local checked = {}
        local props = {}
        for _, current in ipairs(d.types) do
            for _, prop in ipairs(self:getPropertiesOfType(current) or {}) do
                if not checked[prop.name] then
                    checked[prop.name] = true
                    local combinedProp = self:getPropertyOfUnionOrIntersectionType(t, prop.name, t.flags & TypeFlags.Intersection ~= 0 --[[skipObjectFunctionPropertyAugment]])
                    if combinedProp ~= nil then
                        props[#props + 1] = combinedProp
                    end
                end
            end
            -- The properties of a union type are those that are present in all constituent types, so
            -- we only need to check the properties of the first type without index signature
            if t.flags & TypeFlags.Union ~= 0 and core.Len(self:getIndexInfosOfType(current)) == 0 then
                break
            end
        end
        d.resolvedProperties = props
    end
    return d.resolvedProperties
end

function Checker:getPropertyOfType(t, name)
    return self:getPropertyOfTypeEx(t, name, false --[[skipObjectFunctionPropertyAugment]], false --[[includeTypeOnlyMembers]])
end

--[[*
 * Return the symbol for the property with the given name in the given type. Creates synthetic union properties when
 * necessary, maps primitive types and type parameters are to their apparent types, and augments with properties from
 * Object and Function as appropriate.
 *
 * @param type a type to look up property from
 * @param name a name of property to look up in a given type
 ]]
function Checker:getPropertyOfTypeEx(t, name, skipObjectFunctionPropertyAugment, includeTypeOnlyMembers)
    t = self:getReducedApparentType(t)
    if t.flags & TypeFlags.Object ~= 0 then
        local resolved = self:resolveStructuredTypeMembers(t)
        local symbol = resolved.members ~= nil and resolved.members[name] or nil
        if symbol ~= nil then
            if not includeTypeOnlyMembers and t.symbol ~= nil and t.symbol.flags & SymbolFlags.ValueModule ~= 0 then
                local typeOnlyExportStarMap = self.moduleSymbolLinks:Get(t.symbol).typeOnlyExportStarMap
                if typeOnlyExportStarMap ~= nil and typeOnlyExportStarMap[name] ~= nil then
                    -- If this is the type of a module, `resolved.members.get(name)` might have effectively skipped over
                    -- an `export type * from './foo'`, leaving `symbolIsValue` unable to see that the symbol is being
                    -- viewed through a type-only export.
                    return nil
                end
            end
            if self:symbolIsValueEx(symbol, includeTypeOnlyMembers) then
                return symbol
            end
        end
        if skipObjectFunctionPropertyAugment then
            return nil
        end
        local functionType
        if t == self.anyFunctionType then
            functionType = self.globalFunctionType
        elseif #resolved:CallSignatures() ~= 0 then
            functionType = self.globalCallableFunctionType
        elseif #resolved:ConstructSignatures() ~= 0 then
            functionType = self.globalNewableFunctionType
        end
        if functionType ~= nil then
            symbol = self:getPropertyOfObjectType(functionType, name)
            if symbol ~= nil then
                return symbol
            end
        end
        return self:getPropertyOfObjectType(self.globalObjectType, name)
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        local prop = self:getPropertyOfUnionOrIntersectionType(t, name, true --[[skipObjectFunctionPropertyAugment]])
        if prop ~= nil then
            return prop
        end
        if not skipObjectFunctionPropertyAugment then
            return self:getPropertyOfUnionOrIntersectionType(t, name, skipObjectFunctionPropertyAugment)
        end
        return nil
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:getPropertyOfUnionOrIntersectionType(t, name, skipObjectFunctionPropertyAugment)
    end
    return nil
end

-- Return the type of the given property in the given type, or nil if no such property exists
function Checker:getTypeOfPropertyOfType(t, name)
    local prop = self:getPropertyOfType(t, name)
    if prop ~= nil then
        return self:getTypeOfSymbol(prop)
    end
    return nil
end

function Checker:getSignaturesOfType(t, kind)
    return self:getSignaturesOfStructuredType(self:getReducedApparentType(t), kind)
end

function Checker:getSignaturesOfStructuredType(t, kind)
    if t.flags & TypeFlags.StructuredType == 0 then
        return nil
    end
    local resolved = self:resolveStructuredTypeMembers(t)
    local signatures = resolved.signatures
    local n = resolved.callSignatureCount
    if kind == SignatureKind.Call then
        if n == core.Len(signatures) then
            return signatures
        end
        return core.Slice(signatures, 0, n)
    end
    if n == 0 then
        return signatures
    end
    return core.Slice(signatures, n, #signatures)
end

function Checker:getIndexInfosOfType(t)
    return self:getIndexInfosOfStructuredType(self:getReducedApparentType(t))
end

function Checker:getIndexInfosOfStructuredType(t)
    if t.flags & TypeFlags.StructuredType ~= 0 then
        return self:resolveStructuredTypeMembers(t).indexInfos
    end
    return nil
end

-- Return the indexing info of the given kind in the given type. Creates synthetic union index types when necessary and
-- maps primitive types and type parameters are to their apparent types.
function Checker:getIndexInfoOfType(t, keyType)
    return checker.findIndexInfo(self:getIndexInfosOfType(t), keyType)
end

-- Return the index type of the given kind in the given type. Creates synthetic union index types when necessary and
-- maps primitive types and type parameters are to their apparent types.
function Checker:getIndexTypeOfType(t, keyType)
    local info = self:getIndexInfoOfType(t, keyType)
    if info ~= nil then
        return info.valueType
    end
    return nil
end

function Checker:getIndexTypeOfTypeEx(t, keyType, defaultType)
    local result = self:getIndexTypeOfType(t, keyType)
    if result ~= nil then
        return result
    end
    return defaultType
end

function Checker:getApplicableIndexInfo(t, keyType)
    return self:findApplicableIndexInfo(self:getIndexInfosOfType(t), keyType)
end

function Checker:getApplicableIndexInfoForName(t, name)
    if checker.isLateBoundName(name) then
        return self:getApplicableIndexInfo(t, self.esSymbolType)
    end
    return self:getApplicableIndexInfo(t, self:getStringLiteralType(name))
end

function Checker:findApplicableIndexInfo(indexInfos, keyType)
    -- Index signatures for type 'string' are considered only when no other index signatures apply.
    local stringIndexInfo
    local applicableInfos = {}
    for _, info in ipairs(indexInfos or {}) do
        if info.keyType == self.stringType then
            stringIndexInfo = info
        elseif self:isApplicableIndexType(keyType, info.keyType) then
            applicableInfos[#applicableInfos + 1] = info
        end
    end
    -- When more than one index signature is applicable we create a synthetic IndexInfo. Instead of computing
    -- the intersected key type, we just use unknownType for the key type as nothing actually depends on the
    -- keyType property of the returned IndexInfo.
    local n = #applicableInfos
    if n == 0 then
        if stringIndexInfo ~= nil and self:isApplicableIndexType(keyType, self.stringType) then
            return stringIndexInfo
        end
        return nil
    elseif n == 1 then
        return applicableInfos[1]
    else
        local isReadonly = true
        local types = {}
        for i, info in ipairs(applicableInfos) do
            types[i] = info.valueType
            if not info.isReadonly then
                isReadonly = false
            end
        end
        return self:newIndexInfo(self.unknownType, self:getIntersectionType(types), isReadonly, nil, nil)
    end
end

function Checker:isApplicableIndexType(source, target)
    -- A 'string' index signature applies to types assignable to 'string' or 'number', and a 'number' index
    -- signature applies to types assignable to 'number', `${number}` and numeric string literal types.
    return self:isTypeAssignableTo(source, target) or
        target == self.stringType and self:isTypeAssignableTo(source, self.numberType) or
        target == self.numberType and (source == self.numericStringType or source.flags & TypeFlags.StringLiteral ~= 0 and checker.isNumericLiteralName(checker.getStringLiteralValue(source)))
end

function Checker:resolveStructuredTypeMembers(t)
    if t.objectFlags & ObjectFlags.MembersResolved == 0 then
        if t.flags & TypeFlags.Object ~= 0 then
            if t.objectFlags & ObjectFlags.Reference ~= 0 then
                self:resolveTypeReferenceMembers(t)
            elseif t.objectFlags & ObjectFlags.ClassOrInterface ~= 0 then
                self:resolveClassOrInterfaceMembers(t)
            elseif t.objectFlags & ObjectFlags.ReverseMapped ~= 0 then
                self:resolveReverseMappedTypeMembers(t)
            elseif t.objectFlags & ObjectFlags.Anonymous ~= 0 then
                self:resolveAnonymousTypeMembers(t)
            elseif t.objectFlags & ObjectFlags.Mapped ~= 0 then
                self:resolveMappedTypeMembers(t)
            else
                error("Unhandled case in resolveStructuredTypeMembers", 0)
            end
        elseif t.flags & TypeFlags.Union ~= 0 then
            self:resolveUnionTypeMembers(t)
        elseif t.flags & TypeFlags.Intersection ~= 0 then
            self:resolveIntersectionTypeMembers(t)
        else
            error("Unhandled case in resolveStructuredTypeMembers", 0)
        end
    end
    return t:AsStructuredType()
end

function Checker:resolveClassOrInterfaceMembers(t)
    self:resolveObjectTypeMembers(t, t, nil, nil)
end

function Checker:resolveTypeReferenceMembers(t)
    local source = t:Target()
    local typeParameters = source:AsInterfaceType().allTypeParameters
    local typeArguments = self:getTypeArguments(t)
    local paddedTypeArguments = typeArguments
    if core.Len(typeArguments) == core.Len(typeParameters) - 1 then
        paddedTypeArguments = core.Concatenate(typeArguments, { t })
    end
    self:resolveObjectTypeMembers(t, source, typeParameters, paddedTypeArguments)
end

-- Go slices.Equal
local function slicesEqual(a, b)
    local n = core.Len(a)
    if n ~= core.Len(b) then
        return false
    end
    for i = 1, n do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- Go maps.Clone (nil stays nil)
local function mapsClone(m)
    if m == nil then
        return nil
    end
    local result = {}
    for k, v in pairs(m) do
        result[k] = v
    end
    return result
end

function Checker:resolveObjectTypeMembers(t, source, typeParameters, typeArguments)
    local mapper
    local members
    local callSignatures
    local constructSignatures
    local indexInfos
    local instantiated = false
    local resolved = self:resolveDeclaredMembers(source)
    if slicesEqual(typeParameters, typeArguments) then
        members = resolved.declaredMembers
        callSignatures = resolved.declaredCallSignatures
        constructSignatures = resolved.declaredConstructSignatures
        indexInfos = resolved.declaredIndexInfos
    else
        instantiated = true
        mapper = checker.newTypeMapper(typeParameters, typeArguments)
        members = self:instantiateSymbolTable(resolved.declaredMembers, mapper)
        callSignatures = self:instantiateSignatures(resolved.declaredCallSignatures, mapper)
        constructSignatures = self:instantiateSignatures(resolved.declaredConstructSignatures, mapper)
        indexInfos = self:instantiateIndexInfos(resolved.declaredIndexInfos, mapper)
    end
    local baseTypes = self:getBaseTypes(source)
    if core.Len(baseTypes) ~= 0 then
        if not instantiated then
            members = mapsClone(members)
        end
        self:setStructuredTypeMembers(t, members, callSignatures, constructSignatures, indexInfos)
        local thisArgument = core.LastOrNil(typeArguments)
        t.objectFlags = t.objectFlags | checker.ObjectFlagsUnresolvedMembers
        for _, baseType in ipairs(baseTypes) do
            local instantiatedBaseType = baseType
            if thisArgument ~= nil then
                instantiatedBaseType = self:getTypeWithThisArgument(self:instantiateType(baseType, mapper), thisArgument, false --[[needsApparentType]])
            end
            members = self:addInheritedMembers(members, self:getPropertiesOfType(instantiatedBaseType))
            callSignatures = core.Concatenate(callSignatures, self:getSignaturesOfType(instantiatedBaseType, SignatureKind.Call))
            constructSignatures = core.Concatenate(constructSignatures, self:getSignaturesOfType(instantiatedBaseType, SignatureKind.Construct))
            local inheritedIndexInfos
            if instantiatedBaseType ~= self.anyType then
                inheritedIndexInfos = self:getIndexInfosOfType(instantiatedBaseType)
            else
                inheritedIndexInfos = { self.anyBaseTypeIndexInfo }
            end
            local currentIndexInfos = indexInfos
            indexInfos = core.Concatenate(indexInfos, core.Filter(inheritedIndexInfos, function(info)
                return checker.findIndexInfo(currentIndexInfos, info.keyType) == nil
            end))
        end
        t.objectFlags = t.objectFlags & ~checker.ObjectFlagsUnresolvedMembers
    end
    self:setStructuredTypeMembers(t, members, callSignatures, constructSignatures, indexInfos)
end

function checker.findIndexInfo(indexInfos, keyType)
    for _, info in ipairs(indexInfos or {}) do
        if info.keyType == keyType then
            return info
        end
    end
    return nil
end

function Checker:getBaseTypes(t)
    if t.objectFlags & (ObjectFlags.ClassOrInterface | ObjectFlags.Tuple) == 0 then
        return nil
    end
    local data = t:AsInterfaceType()
    if not data.baseTypesResolved then
        if not self:pushTypeResolution(t, TypeSystemPropertyName.ResolvedBaseTypes) then
            return data.resolvedBaseTypes
        end
        if t.objectFlags & ObjectFlags.Tuple ~= 0 then
            data.resolvedBaseTypes = { self:getTupleBaseType(t) }
        elseif t.symbol.flags & (SymbolFlags.Class | SymbolFlags.Interface) ~= 0 then
            if t.symbol.flags & SymbolFlags.Class ~= 0 then
                self:resolveBaseTypesOfClass(t)
            end
            if t.symbol.flags & SymbolFlags.Interface ~= 0 then
                self:resolveBaseTypesOfInterface(t)
            end
        else
            error("Unhandled case in getBaseTypes", 0)
        end
        if not self:popTypeResolution() and t.symbol.declarations ~= nil then
            for _, declaration in ipairs(t.symbol.declarations) do
                if ast.IsClassDeclaration(declaration) or ast.IsInterfaceDeclaration(declaration) then
                    self:reportCircularBaseType(declaration, t)
                end
            end
        end
        -- In general, base type resolution always precedes member resolution. However, it is possible
        -- for resolution of type parameter defaults to cause circularity errors, possibly leaving
        -- members partially resolved. Here we ensure any such partial resolution is reset.
        -- See https://github.com/microsoft/TypeScript/issues/16861 for an example.
        t.objectFlags = t.objectFlags & ~ObjectFlags.MembersResolved
        data.baseTypesResolved = true
    end
    return data.resolvedBaseTypes
end

function Checker:getTupleBaseType(t)
    local typeParameters = t:AsTupleType():TypeParameters()
    local elementInfos = t:AsTupleType().elementInfos
    local elementTypes = {}
    for i, tp in ipairs(typeParameters or {}) do
        if elementInfos[i].flags & ElementFlags.Variadic ~= 0 then
            elementTypes[i] = self:getIndexedAccessType(tp, self.numberType)
        else
            elementTypes[i] = tp
        end
    end
    return self:createArrayTypeEx(self:getUnionType(elementTypes), t:AsTupleType().readonly)
end

function Checker:resolveBaseTypesOfClass(t)
    local baseConstructorType = self:getApparentType(self:getBaseConstructorTypeOfClass(t))
    if baseConstructorType.flags & (TypeFlags.Object | TypeFlags.Intersection | TypeFlags.Any) == 0 then
        return
    end
    local baseTypeNode = checker.getBaseTypeNodeOfClass(t)
    local baseType
    local originalBaseType
    if baseConstructorType.symbol ~= nil then
        originalBaseType = self:getDeclaredTypeOfSymbol(baseConstructorType.symbol)
    end
    if baseConstructorType.symbol ~= nil and baseConstructorType.symbol.flags & SymbolFlags.Class ~= 0 and self:areAllOuterTypeParametersApplied(originalBaseType) then
        -- When base constructor type is a class with no captured type arguments we know that the constructors all have the same type parameters as the
        -- class and all return the instance type of the class. There is no need for further checks and we can apply the
        -- type arguments in the same manner as a type reference to get the same error reporting experience.
        baseType = self:getTypeFromClassOrInterfaceReference(baseTypeNode, baseConstructorType.symbol)
    elseif baseConstructorType.flags & TypeFlags.Any ~= 0 then
        baseType = baseConstructorType
    else
        -- The class derives from a "class-like" constructor function, check that we have at least one construct signature
        -- with a matching number of type parameters and use the return type of the first instantiated signature. Elsewhere
        -- we check that all instantiated signatures return the same type.
        local constructors = self:getInstantiatedConstructorsForTypeArguments(baseConstructorType, baseTypeNode:TypeArguments(), baseTypeNode)
        if core.Len(constructors) == 0 then
            self:error(baseTypeNode:Expression(), diagnostics.No_base_constructor_has_the_specified_number_of_type_arguments)
            return
        end
        baseType = self:getReturnTypeOfSignature(constructors[1])
    end
    if self:isErrorType(baseType) then
        return
    end
    local reducedBaseType = self:getReducedType(baseType)
    if not self:isValidBaseType(reducedBaseType) then
        local errorNode = baseTypeNode:Expression()
        local diagnostic = self:elaborateNeverIntersection(nil, errorNode, baseType)
        diagnostic = checker.NewDiagnosticChainForNode(diagnostic, errorNode, diagnostics.Base_constructor_return_type_0_is_not_an_object_type_or_intersection_of_object_types_with_statically_known_members, self:TypeToString(reducedBaseType))
        self:addDiagnostic(diagnostic)
        return
    end
    if t == reducedBaseType or self:hasBaseType(reducedBaseType, t) then
        self:error(t.symbol.valueDeclaration, diagnostics.Type_0_recursively_references_itself_as_a_base_type, self:TypeToString(t))
        return
    end
    t:AsInterfaceType().resolvedBaseTypes = { reducedBaseType }
end

function checker.getBaseTypeNodeOfClass(t)
    local decl = ast.GetClassLikeDeclarationOfSymbol(t.symbol)
    if decl ~= nil then
        return ast.GetClassExtendsHeritageElement(decl)
    end
    return nil
end

function Checker:getInstantiatedConstructorsForTypeArguments(t, typeArgumentNodes, location)
    local signatures = self:getConstructorsForTypeArguments(t, typeArgumentNodes, location)
    local typeArguments = core.Map(typeArgumentNodes, function(n) return self:getTypeFromTypeNode(n) end)
    return core.SameMap(signatures, function(sig)
        if core.Len(sig.typeParameters) ~= 0 then
            return self:getSignatureInstantiation(sig, typeArguments, ast.IsInJSFile(location), nil)
        end
        return sig
    end)
end

function Checker:getConstructorsForTypeArguments(t, typeArgumentNodes, location)
    local typeArgCount = core.Len(typeArgumentNodes)
    return core.Filter(self:getSignaturesOfType(t, SignatureKind.Construct), function(sig)
        return typeArgCount >= self:getMinTypeArgumentCount(sig.typeParameters) and typeArgCount <= core.Len(sig.typeParameters)
    end)
end

function Checker:getSignatureInstantiation(sig, typeArguments, isJavaScript, inferredTypeParameters)
    local instantiatedSignature = self:getSignatureInstantiationWithoutFillingInTypeArguments(sig, self:fillMissingTypeArguments(typeArguments, sig.typeParameters, self:getMinTypeArgumentCount(sig.typeParameters), isJavaScript))
    if core.Len(inferredTypeParameters) ~= 0 then
        local returnSignature = self:getSingleCallOrConstructSignature(self:getReturnTypeOfSignature(instantiatedSignature))
        if returnSignature ~= nil then
            local newReturnSignature = self:cloneSignature(returnSignature)
            newReturnSignature.typeParameters = inferredTypeParameters
            local newReturnType = self:getOrCreateTypeFromSignature(newReturnSignature)
            newReturnType:AsObjectType().mapper = instantiatedSignature.mapper
            local newInstantiatedSignature = self:cloneSignature(instantiatedSignature)
            newInstantiatedSignature.resolvedReturnType = newReturnType
            return newInstantiatedSignature
        end
    end
    return instantiatedSignature
end

function Checker:cloneSignature(sig)
    local result = self:newSignature(sig.flags & SignatureFlags.PropagatingFlags, sig.declaration, sig.typeParameters, sig.thisParameter, sig.parameters, nil, nil, sig.minArgumentCount)
    result.target = sig.target
    result.mapper = sig.mapper
    result.composite = sig.composite
    return result
end

function Checker:getSignatureInstantiationWithoutFillingInTypeArguments(sig, typeArguments)
    local key = checker.CachedSignatureKey(sig, checker.getTypeListKey(typeArguments))
    local instantiation = self.cachedSignatures[key]
    if instantiation == nil then
        instantiation = self:createSignatureInstantiation(sig, typeArguments)
        self.cachedSignatures[key] = instantiation
    end
    return instantiation
end

function Checker:createSignatureInstantiation(sig, typeArguments)
    return self:instantiateSignatureEx(sig, self:createSignatureTypeMapper(sig, typeArguments), true --[[eraseTypeParameters]])
end

function Checker:createSignatureTypeMapper(sig, typeArguments)
    return checker.newTypeMapper(self:getTypeParametersForMapper(sig), typeArguments)
end

function Checker:getTypeParametersForMapper(sig)
    return core.SameMap(sig.typeParameters, function(tp) return self:instantiateType(tp, tp:Mapper()) end)
end

-- If type has a single call signature and no other members, return that signature. Otherwise, return nil.
function Checker:getSingleCallSignature(t)
    return self:getSingleSignature(t, SignatureKind.Call, false --[[allowMembers]])
end

function Checker:getSingleCallOrConstructSignature(t)
    local callSig = self:getSingleSignature(t, SignatureKind.Call, false --[[allowMembers]])
    if callSig ~= nil then
        return callSig
    end
    return self:getSingleSignature(t, SignatureKind.Construct, false --[[allowMembers]])
end

function Checker:getSingleSignature(t, kind, allowMembers)
    if t.flags & TypeFlags.Object ~= 0 then
        local resolved = self:resolveStructuredTypeMembers(t)
        if allowMembers or core.Len(resolved.properties) == 0 and core.Len(resolved.indexInfos) == 0 then
            if kind == SignatureKind.Call and #resolved:CallSignatures() == 1 and #resolved:ConstructSignatures() == 0 then
                return resolved:CallSignatures()[1]
            end
            if kind == SignatureKind.Construct and #resolved:ConstructSignatures() == 1 and #resolved:CallSignatures() == 0 then
                return resolved:ConstructSignatures()[1]
            end
        end
    end
    return nil
end

function Checker:getOrCreateTypeFromSignature(sig)
    -- There are two ways to declare a construct signature, one is by declaring a class constructor
    -- using the constructor keyword, and the other is declaring a bare construct signature in an
    -- object type literal or interface (using the new keyword). Each way of declaring a constructor
    -- will result in a different declaration kind.
    if sig.isolatedSignatureType == nil then
        local kind = Kind.Unknown
        if sig.declaration ~= nil then
            kind = sig.declaration.kind
        end
        -- If declaration is undefined, it is likely to be the signature of the default constructor.
        local isConstructor = kind == Kind.Unknown or kind == Kind.Constructor or kind == Kind.ConstructSignature or kind == Kind.ConstructorType

        local symbol
        if sig.declaration ~= nil then
            symbol = sig.declaration:Symbol()
        end
        local t = self:newObjectType(ObjectFlags.Anonymous | checker.ObjectFlagsSingleSignatureType, symbol)
        if isConstructor then
            self:setStructuredTypeMembers(t, nil, nil, { sig }, nil)
        else
            self:setStructuredTypeMembers(t, nil, { sig }, nil, nil)
        end
        sig.isolatedSignatureType = t
    end
    return sig.isolatedSignatureType
end

function Checker:getErasedSignature(signature)
    if core.Len(signature.typeParameters) == 0 then
        return signature
    end
    local key = checker.CachedSignatureKey(signature, checker.SignatureKeyErased)
    local erased = self.cachedSignatures[key]
    if erased == nil then
        erased = self:instantiateSignatureEx(signature, checker.newArrayToSingleTypeMapper(signature.typeParameters, self.anyType), true --[[eraseTypeParameters]])
        self.cachedSignatures[key] = erased
    end
    return erased
end

function Checker:getCanonicalSignature(signature)
    if core.Len(signature.typeParameters) == 0 then
        return signature
    end
    local key = checker.CachedSignatureKey(signature, checker.SignatureKeyCanonical)
    local canonical = self.cachedSignatures[key]
    if canonical == nil then
        canonical = self:createCanonicalSignature(signature)
        self.cachedSignatures[key] = canonical
    end
    return canonical
end

function Checker:createCanonicalSignature(signature)
    -- Create an instantiation of the signature where each unconstrained type parameter is replaced with
    -- its original. When a generic class or interface is instantiated, each generic method in the class or
    -- interface is instantiated with a fresh set of cloned type parameters (which we need to handle scenarios
    -- where different generations of the same type parameter are in scope). This leads to a lot of new type
    -- identities, and potentially a lot of work comparing those identities, so here we create an instantiation
    -- that uses the original type identities for all unconstrained type parameters.
    local typeArguments = core.Map(signature.typeParameters, function(tp)
        if tp:Target() ~= nil and self:getConstraintOfTypeParameter(tp:Target()) == nil then
            return tp:Target()
        end
        return tp
    end)
    return self:getSignatureInstantiation(signature, typeArguments, ast.IsInJSFile(signature.declaration), nil --[[inferredTypeParameters]])
end

function Checker:getBaseSignature(signature)
    local typeParameters = signature.typeParameters
    if core.Len(typeParameters) == 0 then
        return signature
    end
    local key = checker.CachedSignatureKey(signature, checker.SignatureKeyBase)
    local cached = self.cachedSignatures[key]
    if cached ~= nil then
        return cached
    end
    local baseConstraintMapper = checker.newTypeMapper(typeParameters, core.Map(typeParameters, function(tp)
        return core.OrElse(self:getConstraintOfTypeParameter(tp), self.unknownType)
    end))
    local baseConstraints = core.Map(typeParameters, function(tp)
        return self:instantiateType(tp, baseConstraintMapper)
    end)
    -- Run the immediate constraint mapper N-1 times so non-circular interdependent type parameters
    -- resolve to their external dependencies without adding an extra expansion step for self-recursive constraints.
    for _ = 1, #typeParameters - 1 do
        baseConstraints = self:instantiateTypes(baseConstraints, baseConstraintMapper)
    end
    -- and then apply a type eraser to remove any remaining circularly dependent type parameters
    baseConstraints = self:instantiateTypes(baseConstraints, checker.newArrayToSingleTypeMapper(typeParameters, self.anyType))
    local result = self:instantiateSignatureEx(signature, checker.newTypeMapper(typeParameters, baseConstraints), true --[[eraseTypeParameters]])
    self.cachedSignatures[key] = result
    return result
end

-- Instantiate a generic signature in the context of a non-generic signature (section 3.8.5 in TypeScript spec)
function Checker:instantiateSignatureInContextOf(signature, contextualSignature, inferenceContext, compareTypes)
    local context = self:newInferenceContext(self:getTypeParametersForMapper(signature), signature, InferenceFlags.None, compareTypes)
    -- We clone the inferenceContext to avoid fixing. For example, when the source signature is <T>(x: T) => T[] and
    -- the contextual signature is (...args: A) => B, we want to infer the element type of A's constraint (say 'any')
    -- for T but leave it possible to later infer '[any]' back to A.
    local restType = self:getEffectiveRestType(contextualSignature)
    local mapper
    if inferenceContext ~= nil then
        if restType ~= nil and restType.flags & TypeFlags.TypeParameter ~= 0 then
            mapper = inferenceContext.nonFixingMapper
        else
            mapper = inferenceContext.mapper
        end
    end
    local sourceSignature
    if mapper ~= nil then
        sourceSignature = self:instantiateSignature(contextualSignature, mapper)
    else
        sourceSignature = contextualSignature
    end
    self:applyToParameterTypes(sourceSignature, signature, function(source, target)
        -- Type parameters from outer context referenced by source type are fixed by instantiation of the source type
        self:inferTypes(context.inferences, source, target, InferencePriority.None, false)
    end)
    if inferenceContext == nil then
        self:applyToReturnTypes(contextualSignature, signature, function(source, target)
            self:inferTypes(context.inferences, source, target, InferencePriority.ReturnType, false)
        end)
    end
    return self:getSignatureInstantiation(signature, self:getInferredTypes(context), ast.IsInJSFile(contextualSignature.declaration), nil --[[inferredTypeParameters]])
end

function Checker:resolveBaseTypesOfInterface(t)
    local data = t:AsInterfaceType()
    for _, declaration in ipairs(t.symbol.declarations or {}) do
        if ast.IsInterfaceDeclaration(declaration) then
            for _, node in ipairs(ast.GetExtendsHeritageClauseElements(declaration) or {}) do
                local baseType = self:getReducedType(self:getTypeFromTypeNode(node))
                if not self:isErrorType(baseType) then
                    if self:isValidBaseType(baseType) then
                        if t ~= baseType and not self:hasBaseType(baseType, t) then
                            data.resolvedBaseTypes = core.Append(data.resolvedBaseTypes, baseType)
                        else
                            self:reportCircularBaseType(declaration, t)
                        end
                    else
                        self:error(node, diagnostics.An_interface_can_only_extend_an_object_type_or_intersection_of_object_types_with_statically_known_members)
                    end
                end
            end
        end
    end
end

function Checker:areAllOuterTypeParametersApplied(t)
    -- An unapplied type parameter has its symbol still the same as the matching argument symbol.
    -- Since parameters are applied outer-to-inner, only the last outer parameter needs to be checked.
    local outerTypeParameters = t:AsInterfaceType():OuterTypeParameters()
    if core.Len(outerTypeParameters) ~= 0 then
        local last = #outerTypeParameters - 1
        local typeArguments = self:getTypeArguments(t)
        return outerTypeParameters[last + 1].symbol ~= typeArguments[last + 1].symbol
    end
    return true
end

function Checker:reportCircularBaseType(node, t)
    self:error(node, diagnostics.Type_0_recursively_references_itself_as_a_base_type, self:typeToStringEx(t, nil, checker.TypeFormatFlags.WriteArrayAsGenericType, nil))
end

-- A valid base type is `any`, an object type or intersection of object types.
function Checker:isValidBaseType(t)
    if t.flags & TypeFlags.TypeParameter ~= 0 then
        local constraint = self:getBaseConstraintOfType(t)
        if constraint ~= nil then
            return self:isValidBaseType(constraint)
        end
    end
    -- TODO: Given that we allow type parameters here now, is this `!isGenericMappedType(type)` check really needed?
    -- There's no reason a `T` should be allowed while a `Readonly<T>` should not.
    return t.flags & (TypeFlags.Object | TypeFlags.NonPrimitive | TypeFlags.Any) ~= 0 and not self:isGenericMappedType(t) or
        t.flags & TypeFlags.Intersection ~= 0 and core.Every(t:Types(), function(x) return self:isValidBaseType(x) end)
end

-- TODO: GH#18217 If `checkBase` is undefined, we should not call this because this will always return false.
function Checker:hasBaseType(t, checkBase)
    local check
    check = function(u)
        if u.objectFlags & (ObjectFlags.ClassOrInterface | ObjectFlags.Reference) ~= 0 then
            local target = checker.getTargetType(u)
            return target == checkBase or core.Some(self:getBaseTypes(target), check)
        end
        if u.flags & TypeFlags.Intersection ~= 0 then
            return core.Some(u:Types(), check)
        end
        return false
    end
    return check(t)
end

function checker.getTargetType(t)
    if t.objectFlags & ObjectFlags.Reference ~= 0 then
        return t:Target()
    end
    return t
end

function Checker:getTypeWithThisArgument(t, thisArgument, needApparentType)
    if t.objectFlags & ObjectFlags.Reference ~= 0 then
        local target = t:Target()
        local typeArguments = self:getTypeArguments(t)
        if core.Len(target:AsInterfaceType():TypeParameters()) == core.Len(typeArguments) then
            if thisArgument == nil then
                thisArgument = target:AsInterfaceType().thisType
            end
            return self:createTypeReference(target, core.Concatenate(typeArguments, { thisArgument }))
        end
        return t
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        local types = t:Types()
        local newTypes = core.SameMap(types, function(u) return self:getTypeWithThisArgument(u, thisArgument, needApparentType) end)
        if core.Same(newTypes, types) then
            return t
        end
        return self:getIntersectionType(newTypes)
    end
    if needApparentType then
        return self:getApparentType(t)
    end
    return t
end

function Checker:addInheritedMembers(symbols, baseSymbols)
    for _, base in ipairs(baseSymbols or {}) do
        if not checker.isStaticPrivateIdentifierProperty(base) then
            local s = symbols and symbols[base.name]
            if s == nil or s.flags & SymbolFlags.Value == 0 then
                if symbols == nil then
                    symbols = ast.NewSymbolTable()
                end
                symbols[base.name] = base
            end
        end
    end
    return symbols
end

function Checker:resolveDeclaredMembers(t)
    local d = t:AsInterfaceType()
    if not d.declaredMembersResolved then
        local members = self:getMembersOfSymbol(t.symbol)
        d.declaredMembersResolved = true
        d.declaredMembers = members
        d.declaredCallSignatures = self:getSignaturesOfSymbol(d.declaredMembers and d.declaredMembers[ast.InternalSymbolNameCall])
        d.declaredConstructSignatures = self:getSignaturesOfSymbol(d.declaredMembers and d.declaredMembers[ast.InternalSymbolNameNew])
        d.declaredIndexInfos = self:getIndexInfosOfSymbol(t.symbol)
    end
    return d
end

function Checker:getIndexInfosOfSymbol(symbol)
    local indexSymbol = self:getIndexSymbol(symbol)
    if indexSymbol ~= nil then
        -- Go collects the values of a map (random order).
        local siblingSymbols = {}
        for _, s in pairs(self:getMembersOfSymbol(symbol) or {}) do
            siblingSymbols[#siblingSymbols + 1] = s
        end
        return self:getIndexInfosOfIndexSymbol(indexSymbol, siblingSymbols)
    end
    return nil
end

-- note intentional similarities to index signature building in `checkObjectLiteral` for parity
function Checker:getIndexInfosOfIndexSymbol(indexSymbol, siblingSymbols)
    local indexInfos
    local hasComputedStringProperty = false
    local hasComputedNumberProperty = false
    local hasComputedSymbolProperty = false
    local readonlyComputedStringProperty = true
    local readonlyComputedNumberProperty = true
    local readonlyComputedSymbolProperty = true
    local propertySymbols
    for _, declaration in ipairs(indexSymbol.declarations or {}) do
        if ast.IsIndexSignatureDeclaration(declaration) then
            local parameters = declaration:Parameters()
            local returnTypeNode = declaration:Type()
            if core.Len(parameters) == 1 then
                local typeNode = parameters[1]:Type()
                if typeNode ~= nil then
                    local valueType = self.anyType
                    if returnTypeNode ~= nil then
                        valueType = self:getTypeFromTypeNode(returnTypeNode)
                    end
                    checker.forEachType(self:getTypeFromTypeNode(typeNode), function(keyType)
                        if self:isValidIndexKeyType(keyType) and checker.findIndexInfo(indexInfos, keyType) == nil then
                            local indexInfo = self:newIndexInfo(keyType, valueType, ast.HasModifier(declaration, ModifierFlags.Readonly), declaration, nil)
                            indexInfos = core.Append(indexInfos, indexInfo)
                        end
                    end)
                end
            end
        elseif self:hasLateBindableIndexSignature(declaration) then
            local declName
            if ast.IsBinaryExpression(declaration) then
                declName = declaration:AsBinaryExpression().left
            else
                declName = declaration:Name()
            end
            local keyType
            if ast.IsElementAccessExpression(declName) then
                keyType = self:checkExpressionCached(declName:AsElementAccessExpression().argumentExpression)
            else
                keyType = self:checkComputedPropertyName(declName)
            end
            if checker.findIndexInfo(indexInfos, keyType) ~= nil then
                goto continue
                -- Explicit index for key type takes priority
            end
            if self:isTypeAssignableTo(keyType, self.stringNumberSymbolType) then
                if self:isTypeAssignableTo(keyType, self.numberType) then
                    hasComputedNumberProperty = true
                    if not checker.hasReadonlyModifier(declaration) then
                        readonlyComputedNumberProperty = false
                    end
                elseif self:isTypeAssignableTo(keyType, self.esSymbolType) then
                    hasComputedSymbolProperty = true
                    if not checker.hasReadonlyModifier(declaration) then
                        readonlyComputedSymbolProperty = false
                    end
                else
                    hasComputedStringProperty = true
                    if not checker.hasReadonlyModifier(declaration) then
                        readonlyComputedStringProperty = false
                    end
                end
                propertySymbols = core.Append(propertySymbols, declaration:Symbol())
            end
        end
        ::continue::
    end
    if hasComputedStringProperty or hasComputedNumberProperty or hasComputedSymbolProperty then
        for _, sym in ipairs(siblingSymbols or {}) do
            if sym ~= indexSymbol then
                propertySymbols = core.Append(propertySymbols, sym)
            end
        end
        -- aggregate similar index infos implied to be the same key to the same combined index info
        if hasComputedStringProperty and checker.findIndexInfo(indexInfos, self.stringType) == nil then
            indexInfos = core.Append(indexInfos, self:getObjectLiteralIndexInfo(readonlyComputedStringProperty, propertySymbols, self.stringType))
        end
        if hasComputedNumberProperty and checker.findIndexInfo(indexInfos, self.numberType) == nil then
            indexInfos = core.Append(indexInfos, self:getObjectLiteralIndexInfo(readonlyComputedNumberProperty, propertySymbols, self.numberType))
        end
        if hasComputedSymbolProperty and checker.findIndexInfo(indexInfos, self.esSymbolType) == nil then
            indexInfos = core.Append(indexInfos, self:getObjectLiteralIndexInfo(readonlyComputedSymbolProperty, propertySymbols, self.esSymbolType))
        end
    end
    return indexInfos
end

-- NOTE: currently does not make pattern literal indexers, eg `${number}px`
function Checker:getObjectLiteralIndexInfo(isReadonly, properties, keyType)
    local propTypes
    local components
    for _, prop in ipairs(properties or {}) do
        if keyType == self.stringType and not self:isSymbolWithSymbolName(prop) or
            keyType == self.numberType and self:isSymbolWithNumericName(prop) or
            keyType == self.esSymbolType and self:isSymbolWithSymbolName(prop) then
            propTypes = core.Append(propTypes, self:getTypeOfSymbol(prop))
            if self:isSymbolWithComputedName(prop) then
                components = core.Append(components, prop.declarations[1])
            end
        end
    end
    local unionType = self.undefinedType
    if core.Len(propTypes) ~= 0 then
        unionType = self:getUnionTypeEx(propTypes, UnionReduction.Subtype, nil, nil)
    end
    return self:newIndexInfo(keyType, unionType, isReadonly, nil --[[declaration]], components)
end

function Checker:isSymbolWithSymbolName(symbol)
    if checker.IsKnownSymbol(symbol) then
        return true
    end
    if core.Len(symbol.declarations) ~= 0 then
        local name = symbol.declarations[1]:Name()
        return name ~= nil and ast.IsComputedPropertyName(name) and self:isTypeAssignableToKind(self:checkComputedPropertyName(name), TypeFlags.ESSymbol)
    end
    return false
end

function Checker:isSymbolWithNumericName(symbol)
    if checker.isNumericLiteralName(symbol.name) then
        return true
    end
    if core.Len(symbol.declarations) ~= 0 then
        local name = symbol.declarations[1]:Name()
        return name ~= nil and self:isNumericName(name)
    end
    return false
end

function Checker:isSymbolWithComputedName(symbol)
    if core.Len(symbol.declarations) ~= 0 then
        local name = symbol.declarations[1]:Name()
        return name ~= nil and ast.IsComputedPropertyName(name)
    end
    return false
end

function Checker:isNumericName(name)
    local k = name.kind
    if k == Kind.ComputedPropertyName then
        return self:isNumericComputedName(name)
    elseif k == Kind.Identifier or k == Kind.NumericLiteral or k == Kind.StringLiteral then
        return checker.isNumericLiteralName(name:Text())
    end
    return false
end

function Checker:isNumericComputedName(name)
    -- It seems odd to consider an expression of type Any to result in a numeric name,
    -- but this behavior is consistent with checkIndexedAccess
    return self:isTypeAssignableToKind(self:checkComputedPropertyName(name), TypeFlags.NumberLike)
end

function Checker:isValidIndexKeyType(t)
    return t.flags & (TypeFlags.String | TypeFlags.Number | TypeFlags.ESSymbol) ~= 0 or
        self:isPatternLiteralType(t) or
        t.flags & TypeFlags.Intersection ~= 0 and not self:isGenericType(t) and core.Some(t:Types(), function(x) return self:isValidIndexKeyType(x) end)
end

function Checker:findIndexInfo(indexInfos, keyType)
    for _, info in ipairs(indexInfos or {}) do
        if info.keyType == keyType then
            return info
        end
    end
    return nil
end

function Checker:getIndexSymbol(symbol)
    local members = self:getMembersOfSymbol(symbol)
    return members and members[ast.InternalSymbolNameIndex]
end

function Checker:getSignaturesOfSymbol(symbol)
    if symbol == nil then
        return nil
    end
    local result
    for i1, decl in ipairs(symbol.declarations or {}) do
        local i = i1 - 1
        if not ast.IsFunctionLike(decl) then
            goto continue
        end
        -- Don't include signature if node is the implementation of an overloaded function. A node is considered
        -- an implementation node if it has a body and the previous node is of the same kind and immediately
        -- precedes the implementation node (i.e. has the same parent and ends where the implementation starts).
        if i > 0 and decl:Body() ~= nil then
            local previous = symbol.declarations[i]
            if decl.parent == previous.parent and decl.kind == previous.kind and
                (decl:Pos() == previous:End() or previous.flags & NodeFlags.Reparsed ~= 0) then
                goto continue
            end
        end
        do
            -- If this is a function or method declaration, get the signature from the @type tag for the sake of optional parameters.
            -- Exclude contextually-typed kinds because we already apply the @type tag to the context, plus applying it here to the initializer would suppress checks that the two are compatible.
            local sig = self:getSignatureOfFullSignatureType(decl)
            if sig == nil then
                sig = self:getSignatureFromDeclaration(decl)
            end
            result = core.Append(result, sig)
        end
        ::continue::
    end
    return result
end

function Checker:getSignatureFromDeclaration(declaration)
    local links = self.signatureLinks:Get(declaration)
    if links.resolvedSignature ~= nil then
        return links.resolvedSignature
    end
    local parameters
    local flags = SignatureFlags.None
    local thisParameter
    local minArgumentCount = 0
    local hasThisParameter = false
    local iife = ast.GetImmediatelyInvokedFunctionExpression(declaration)
    local isUntypedSignatureInJSFile = iife == nil and
        ast.IsInJSFile(declaration) and
        (ast.IsFunctionExpression(declaration) or ast.IsArrowFunction(declaration) or ast.IsMethodOrAccessor(declaration) or ast.IsFunctionDeclaration(declaration) or ast.IsConstructorDeclaration(declaration)) and
        core.Every(declaration:Parameters(), function(param) return param:Type() == nil end) and
        self:getContextualType(declaration, checker.ContextFlags.Signature) == nil
    if isUntypedSignatureInJSFile then
        flags = flags | SignatureFlags.IsUntypedSignatureInJSFile
    end
    for i1, param in ipairs(declaration:Parameters() or {}) do
        local i = i1 - 1
        local paramSymbol = param:Symbol()
        local typeNode = param:Type()
        -- Include parameter symbol instead of property symbol in the signature
        if paramSymbol ~= nil and paramSymbol.flags & SymbolFlags.Property ~= 0 and not ast.IsBindingPattern(param:Name()) then
            local resolvedSymbol = self.resolveName(param, paramSymbol.name, SymbolFlags.Value, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]])
            paramSymbol = resolvedSymbol
        end
        if i == 0 and paramSymbol.name == ast.InternalSymbolNameThis then
            hasThisParameter = true
            thisParameter = param:Symbol()
        else
            parameters = core.Append(parameters, paramSymbol)
        end
        if typeNode ~= nil and typeNode.kind == Kind.LiteralType then
            flags = flags | SignatureFlags.HasLiteralTypes
        end
        -- Record a new minimum argument count if this is not an optional parameter
        local isOptionalParameter = checker.isOptionalDeclaration(param) or
            param:Initializer() ~= nil or
            checker.isRestParameter(param) or
            iife ~= nil and core.Len(parameters) > core.Len(iife:Arguments()) and typeNode == nil
        if not isOptionalParameter then
            minArgumentCount = core.Len(parameters)
        end
    end
    -- If only one accessor includes a this-type annotation, the other behaves as if it had the same type annotation
    if (ast.IsGetAccessorDeclaration(declaration) or ast.IsSetAccessorDeclaration(declaration)) and self:hasBindableName(declaration) and (not hasThisParameter or thisParameter == nil) then
        local otherKind = core.IfElse(ast.IsGetAccessorDeclaration(declaration), Kind.SetAccessor, Kind.GetAccessor)
        local other = ast.GetDeclarationOfKind(self:getSymbolOfDeclaration(declaration), otherKind)
        if other ~= nil then
            thisParameter = self:getAnnotatedAccessorThisParameter(other)
        end
    end
    local classType
    if ast.IsConstructorDeclaration(declaration) then
        classType = self:getDeclaredTypeOfClassOrInterface(self:getMergedSymbol(declaration.parent:Symbol()))
    end
    local typeParameters
    if classType ~= nil then
        typeParameters = classType:AsInterfaceType():LocalTypeParameters()
    else
        typeParameters = self:getTypeParametersFromDeclaration(declaration)
    end
    if checker.hasRestParameter(declaration) then
        flags = flags | SignatureFlags.HasRestParameter
    end
    if ast.IsConstructorTypeNode(declaration) or ast.IsConstructorDeclaration(declaration) or ast.IsConstructSignatureDeclaration(declaration) then
        flags = flags | SignatureFlags.Construct
    end
    if ast.IsConstructorTypeNode(declaration) and ast.HasSyntacticModifier(declaration, ModifierFlags.Abstract) or ast.IsConstructorDeclaration(declaration) and ast.HasSyntacticModifier(declaration.parent, ModifierFlags.Abstract) then
        flags = flags | SignatureFlags.Abstract
    end
    links.resolvedSignature = self:newSignature(flags, declaration, typeParameters, thisParameter, parameters, nil --[[resolvedReturnType]], nil --[[resolvedTypePredicate]], minArgumentCount)
    return links.resolvedSignature
end

function Checker:getTypeParametersFromDeclaration(declaration)
    local sig = self:getSignatureOfFullSignatureType(declaration)
    if sig ~= nil then
        return sig:TypeParameters()
    end
    local result
    for _, node in ipairs(declaration:TypeParameters() or {}) do
        result = core.AppendIfUnique(result, self:getDeclaredTypeOfTypeParameter(node:Symbol()))
    end
    return result
end

function Checker:getAnnotatedAccessorThisParameter(accessor)
    local parameter = self:getAccessorThisParameter(accessor)
    if parameter ~= nil then
        return parameter:Symbol()
    end
    return nil
end

function Checker:getAccessorThisParameter(accessor)
    if core.Len(accessor:Parameters()) == core.IfElse(ast.IsGetAccessorDeclaration(accessor), 1, 2) then
        return ast.GetThisParameter(accessor)
    end
    return nil
end

--[[*
 * Indicates whether a declaration has an early-bound name or a dynamic name that can be late-bound.
 ]]
function Checker:hasBindableName(node)
    return not ast.HasDynamicName(node) or self:hasLateBindableName(node)
end

--[[*
 * Indicates whether a declaration has a late-bindable dynamic name.
 ]]
function Checker:hasLateBindableName(node)
    local name = ast.GetNameOfDeclaration(node)
    return name ~= nil and self:isLateBindableName(name)
end

--[[*
 * Indicates whether a declaration name is definitely late-bindable.
 * A declaration name is only late-bindable if:
 * - It is a `ComputedPropertyName`.
 * - Its expression is an `Identifier` or either a `PropertyAccessExpression` an
 * `ElementAccessExpression` consisting only of these same three types of nodes.
 * - The type of its expression is a string or numeric literal type, or is a `unique symbol` type.
 ]]
function Checker:isLateBindableName(node)
    if not checker.isLateBindableAST(node) then
        return false
    end
    if ast.IsComputedPropertyName(node) then
        return checker.isTypeUsableAsPropertyName(self:checkComputedPropertyName(node))
    end
    return checker.isTypeUsableAsPropertyName(self:checkExpressionCached(node:AsElementAccessExpression().argumentExpression))
end

function Checker:hasLateBindableIndexSignature(node)
    local name = ast.GetNameOfDeclaration(node)
    return name ~= nil and self:isLateBindableIndexSignature(name)
end

function Checker:isLateBindableIndexSignature(node)
    if not checker.isLateBindableAST(node) then
        return false
    end
    if ast.IsComputedPropertyName(node) then
        return self:isTypeUsableAsIndexSignatureDeclaration(self:checkComputedPropertyName(node))
    end
    return self:isTypeUsableAsIndexSignatureDeclaration(self:checkExpressionCached(node:AsElementAccessExpression().argumentExpression))
end

function Checker:isTypeUsableAsIndexSignatureDeclaration(t)
    return self:isTypeAssignableTo(t, self.stringNumberSymbolType)
end

function checker.isLateBindableAST(node)
    local expr
    if ast.IsComputedPropertyName(node) then
        expr = node:Expression()
    elseif ast.IsElementAccessExpression(node) then
        expr = node:AsElementAccessExpression().argumentExpression
    end
    return expr ~= nil and ast.IsEntityNameExpression(expr)
end

function Checker:getReturnTypeOfSignature(sig)
    if sig.resolvedReturnType ~= nil then
        return sig.resolvedReturnType
    end
    if not self:pushTypeResolution(sig, TypeSystemPropertyName.ResolvedReturnType) then
        return self.errorType
    end
    local t
    if sig.target ~= nil then
        t = self:instantiateType(self:getReturnTypeOfSignature(sig.target), sig.mapper)
    elseif sig.composite ~= nil then
        t = self:instantiateType(self:getUnionOrIntersectionType(core.Map(sig.composite.signatures, function(s) return self:getReturnTypeOfSignature(s) end), sig.composite.isUnion, UnionReduction.Subtype), sig.mapper)
    else
        t = self:getReturnTypeFromAnnotation(sig.declaration)
        if t == nil then
            if not ast.NodeIsMissing(sig.declaration:Body()) then
                t = self:getReturnTypeFromBody(sig.declaration, CheckMode.Normal)
            else
                t = self.anyType
            end
        end
    end
    if sig.flags & SignatureFlags.IsInnerCallChain ~= 0 then
        t = self:addOptionalTypeMarker(t)
    elseif sig.flags & SignatureFlags.IsOuterCallChain ~= 0 then
        t = self:getOptionalType(t, false --[[isProperty]])
    end
    if not self:popTypeResolution() then
        if sig.declaration ~= nil then
            local typeNode = sig.declaration:Type()
            if typeNode ~= nil then
                self:error(typeNode, diagnostics.Return_type_annotation_circularly_references_itself)
            elseif self.noImplicitAny then
                local name = ast.GetNameOfDeclaration(sig.declaration)
                if name ~= nil then
                    self:error(name, diagnostics.X_0_implicitly_has_return_type_any_because_it_does_not_have_a_return_type_annotation_and_is_referenced_directly_or_indirectly_in_one_of_its_return_expressions, scanner.DeclarationNameToString(name))
                else
                    self:error(sig.declaration, diagnostics.Function_implicitly_has_return_type_any_because_it_does_not_have_a_return_type_annotation_and_is_referenced_directly_or_indirectly_in_one_of_its_return_expressions)
                end
            end
        end
        t = self.anyType
    end
    if sig.resolvedReturnType == nil then
        sig.resolvedReturnType = t
    end
    return sig.resolvedReturnType
end

function Checker:getNonCircularReturnTypeOfSignature(sig)
    if self:isResolvingReturnTypeOfSignature(sig) then
        return self.anyType
    end
    return self:getReturnTypeOfSignature(sig)
end

function Checker:getReturnTypeFromAnnotation(declaration)
    if ast.IsConstructorDeclaration(declaration) then
        return self:getDeclaredTypeOfClassOrInterface(self:getMergedSymbol(declaration.parent:Symbol()))
    end
    local returnType = declaration:Type()
    if returnType ~= nil then
        return self:getTypeFromTypeNode(returnType)
    end
    if ast.IsGetAccessorDeclaration(declaration) and self:hasBindableName(declaration) then
        return self:getAnnotatedAccessorType(ast.GetDeclarationOfKind(self:getSymbolOfDeclaration(declaration), Kind.SetAccessor))
    end
    return self:getReturnTypeOfFullSignature(declaration)
end

function Checker:getSignatureOfFullSignatureType(node)
    if ast.IsInJSFile(node) and (ast.IsFunctionDeclaration(node) or ast.IsMethodDeclaration(node) or ast.IsFunctionExpressionOrArrowFunction(node)) and node:FunctionLikeData().fullSignature ~= nil then
        return self:getSingleCallSignature(self:getTypeFromTypeNode(node:FunctionLikeData().fullSignature))
    end
    return nil
end

function Checker:getParameterTypeOfFullSignature(node, parameter)
    local signature = self:getSignatureOfFullSignatureType(node)
    if signature ~= nil then
        local pos = slicesIndex(node:Parameters(), parameter)
        if parameter:AsParameterDeclaration().dotDotDotToken ~= nil then
            return self:getRestTypeAtPosition(signature, pos, false --[[readonly]])
        else
            return self:getTypeAtPosition(signature, pos)
        end
    end
    return nil
end

function Checker:getReturnTypeOfFullSignature(node)
    local signature = self:getSignatureOfFullSignatureType(node)
    if signature ~= nil then
        return self:getReturnTypeOfSignature(signature)
    end
    return nil
end

function Checker:getAnnotatedAccessorType(accessor)
    local node = self:getAnnotatedAccessorTypeNode(accessor)
    if node ~= nil then
        return self:getTypeFromTypeNode(node)
    end
    return nil
end

function Checker:getAnnotatedAccessorTypeNode(accessor)
    if accessor ~= nil then
        local k = accessor.kind
        if k == Kind.GetAccessor or k == Kind.PropertyDeclaration then
            return accessor:Type()
        elseif k == Kind.SetAccessor then
            return checker.getEffectiveSetAccessorTypeAnnotationNode(accessor)
        end
    end
    return nil
end

function checker.getEffectiveSetAccessorTypeAnnotationNode(node)
    local param = checker.GetSetAccessorValueParameter(node)
    if param ~= nil then
        return param:Type()
    end
    return nil
end

function Checker:getReturnTypeFromBody(fn, checkMode)
    local body = fn:Body()
    if body == nil then
        return self.errorType
    end
    local functionFlags = ast.GetFunctionFlags(fn)
    local isAsync = (functionFlags & FunctionFlags.Async) ~= 0
    local isGenerator = (functionFlags & FunctionFlags.Generator) ~= 0
    local returnType
    local yieldType
    local nextType
    local fallbackReturnType = self.voidType
    if not ast.IsBlock(body) then
        returnType = self:checkExpressionCachedEx(body, checkMode & ~CheckMode.SkipGenericFunctions)
        if self:isConstContext(body) then
            returnType = self:getRegularTypeOfLiteralType(returnType)
        end
        if isAsync then
            -- From within an async function you can return either a non-promise value or a promise. Any
            -- Promise/A+ compatible implementation will always assimilate any foreign promise, so the
            -- return type of the body should be unwrapped to its awaited type, which we will wrap in
            -- the native Promise<T> type later in this function.
            returnType = self:unwrapAwaitedType(self:checkAwaitedType(returnType, false --[[withAlias]], fn --[[errorNode]], diagnostics.The_return_type_of_an_async_function_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member))
        end
    elseif isGenerator then
        local returnTypes, isNeverReturning = self:checkAndAggregateReturnExpressionTypes(fn, checkMode)
        if isNeverReturning then
            fallbackReturnType = self.neverType
        elseif core.Len(returnTypes) ~= 0 then
            returnType = self:getUnionTypeEx(returnTypes, UnionReduction.Subtype, nil, nil)
        end
        local yieldTypes, nextTypes = self:checkAndAggregateYieldOperandTypes(fn, checkMode)
        if core.Len(yieldTypes) ~= 0 then
            yieldType = self:getUnionTypeEx(yieldTypes, UnionReduction.Subtype, nil, nil)
        end
        if core.Len(nextTypes) ~= 0 then
            nextType = self:getIntersectionType(nextTypes)
        end
    else
        local types, isNeverReturning = self:checkAndAggregateReturnExpressionTypes(fn, checkMode)
        if isNeverReturning then
            -- For an async function, the return type will not be never, but rather a Promise for never.
            if functionFlags & FunctionFlags.Async ~= 0 then
                return self:createPromiseReturnType(fn, self.neverType)
            end
            -- Normal function
            return self.neverType
        end
        if core.Len(types) == 0 then
            -- For an async function, the return type will not be void/undefined, but rather a Promise for void/undefined.
            local contextualReturnType = self:getContextualReturnType(fn, checker.ContextFlags.None)
            local returnType_
            if contextualReturnType ~= nil and checker.someType(core.OrElse(self:unwrapReturnType(contextualReturnType, functionFlags), self.voidType), function(t) return t.flags & TypeFlags.Undefined ~= 0 end) then
                returnType_ = self.undefinedType
            else
                returnType_ = self.voidType
            end
            if functionFlags & FunctionFlags.Async ~= 0 then
                return self:createPromiseReturnType(fn, returnType_)
            end
            -- Normal function
            return returnType_
        end
        -- Return a union of the return expression types.
        returnType = self:getUnionTypeEx(types, UnionReduction.Subtype, nil, nil)
    end
    if returnType ~= nil or yieldType ~= nil or nextType ~= nil then
        if yieldType ~= nil then
            self:reportErrorsFromWidening(fn, yieldType, WideningKind.GeneratorYield)
        end
        if returnType ~= nil then
            self:reportErrorsFromWidening(fn, returnType, WideningKind.FunctionReturn)
        end
        if nextType ~= nil then
            self:reportErrorsFromWidening(fn, nextType, WideningKind.GeneratorNext)
        end
        if returnType ~= nil and checker.isUnitType(returnType) or yieldType ~= nil and checker.isUnitType(yieldType) or nextType ~= nil and checker.isUnitType(nextType) then
            local contextualSignature = self:getContextualSignatureForFunctionLikeDeclaration(fn)
            local contextualType
            if contextualSignature == nil then
                -- No contextual type
            elseif contextualSignature == self:getSignatureFromDeclaration(fn) then
                if not isGenerator then
                    contextualType = returnType
                end
            else
                contextualType = self:instantiateContextualType(self:getReturnTypeOfSignature(contextualSignature), fn, checker.ContextFlags.None)
            end
            if isGenerator then
                yieldType = self:getWidenedLiteralLikeTypeForContextualIterationTypeIfNeeded(yieldType, contextualType, IterationTypeKind.Yield, isAsync)
                returnType = self:getWidenedLiteralLikeTypeForContextualIterationTypeIfNeeded(returnType, contextualType, IterationTypeKind.Return, isAsync)
                nextType = self:getWidenedLiteralLikeTypeForContextualIterationTypeIfNeeded(nextType, contextualType, IterationTypeKind.Next, isAsync)
            else
                returnType = self:getWidenedLiteralLikeTypeForContextualReturnTypeIfNeeded(returnType, contextualType, isAsync)
            end
        end
        if yieldType ~= nil then
            yieldType = self:getWidenedType(yieldType)
        end
        if returnType ~= nil then
            returnType = self:getWidenedType(returnType)
        end
        if nextType ~= nil then
            nextType = self:getWidenedType(nextType)
        end
    end
    if returnType == nil then
        returnType = fallbackReturnType
    end
    if isGenerator then
        if yieldType == nil then
            yieldType = self.neverType
        end
        if nextType == nil then
            nextType = self:getContextualIterationType(IterationTypeKind.Next, fn)
            if nextType == nil then
                nextType = self.unknownType
            end
        end
        return self:createGeneratorType(yieldType, returnType, nextType, isAsync)
    end
    -- From within an async function you can return either a non-promise value or a promise. Any
    -- Promise/A+ compatible implementation will always assimilate any foreign promise, so the
    -- return type of the body is awaited type of the body, wrapped in a native Promise<T> type.
    if isAsync then
        return self:createPromiseType(returnType)
    end
    return returnType
end

-- Returns the aggregated list of return types, plus a bool indicating a never-returning function.
function Checker:checkAndAggregateReturnExpressionTypes(fn, checkMode)
    local functionFlags = ast.GetFunctionFlags(fn)
    local aggregatedTypes
    local hasReturnWithNoExpression = self:functionHasImplicitReturn(fn)
    local hasReturnOfTypeNever = false
    ast.ForEachReturnStatement(fn:Body(), function(returnStatement)
        local expr = returnStatement:Expression()
        if expr == nil then
            hasReturnWithNoExpression = true
            return false
        end
        expr = ast.SkipParentheses(expr)
        -- Bare calls to this same function don't contribute to inference
        -- and `return await` is also safe to unwrap here
        if functionFlags & FunctionFlags.Async ~= 0 and ast.IsAwaitExpression(expr) then
            expr = ast.SkipParentheses(expr:Expression())
        end
        if ast.IsCallExpression(expr) and ast.IsIdentifier(expr:Expression()) and self:checkExpressionCached(expr:Expression()).symbol == self:getMergedSymbol(fn:Symbol()) and
            (not ast.IsFunctionExpressionOrArrowFunction(fn:Symbol().valueDeclaration) or self:isConstantReference(expr:Expression())) then
            hasReturnOfTypeNever = true
            return false
        end
        local t = self:checkExpressionCachedEx(expr, checkMode & ~CheckMode.SkipGenericFunctions)
        if functionFlags & FunctionFlags.Async ~= 0 then
            -- From within an async function you can return either a non-promise value or a promise. Any
            -- Promise/A+ compatible implementation will always assimilate any foreign promise, so the
            -- return type of the body should be unwrapped to its awaited type, which should be wrapped in
            -- the native Promise<T> type by the caller.
            t = self:unwrapAwaitedType(self:checkAwaitedType(t, false --[[withAlias]], fn, diagnostics.The_return_type_of_an_async_function_must_either_be_a_valid_promise_or_must_not_contain_a_callable_then_member))
        end
        if t.flags & TypeFlags.Never ~= 0 then
            hasReturnOfTypeNever = true
        end
        if self:isConstContext(expr) then
            t = self:getRegularTypeOfLiteralType(t)
        end
        aggregatedTypes = core.AppendIfUnique(aggregatedTypes, t)
        return false
    end)
    if core.Len(aggregatedTypes) == 0 and not hasReturnWithNoExpression and (hasReturnOfTypeNever or checker.mayReturnNever(fn)) then
        return nil, true
    end
    if self.strictNullChecks and core.Len(aggregatedTypes) ~= 0 and hasReturnWithNoExpression then
        aggregatedTypes = core.AppendIfUnique(aggregatedTypes, self.undefinedType)
    end
    return aggregatedTypes, false
end

function Checker:functionHasImplicitReturn(fn)
    local endFlowNode = fn:BodyData().endFlowNode
    return endFlowNode ~= nil and self:isReachableFlowNode(endFlowNode)
end

function checker.mayReturnNever(fn)
    local k = fn.kind
    if k == Kind.FunctionExpression or k == Kind.ArrowFunction then
        return true
    elseif k == Kind.MethodDeclaration then
        return ast.IsObjectLiteralExpression(fn.parent)
    end
    return false
end

function Checker:checkAndAggregateYieldOperandTypes(fn, checkMode)
    local yieldTypes
    local nextTypes
    local isAsync = (ast.GetFunctionFlags(fn) & FunctionFlags.Async) ~= 0
    checker.forEachYieldExpression(fn:Body(), function(yieldExpr)
        local yieldExprType = self.undefinedWideningType
        if yieldExpr:Expression() ~= nil then
            yieldExprType = self:checkExpressionEx(yieldExpr:Expression(), checkMode & ~CheckMode.SkipGenericFunctions)
        end
        if yieldExpr:Expression() ~= nil and self:isConstContext(yieldExpr:Expression()) then
            yieldExprType = self:getRegularTypeOfLiteralType(yieldExprType)
        end
        yieldTypes = core.AppendIfUnique(yieldTypes, self:getYieldedTypeOfYieldExpression(yieldExpr, yieldExprType, self.anyType, isAsync))
        local nextType
        if yieldExpr:AsYieldExpression().asteriskToken ~= nil then
            local iterationTypes = self:getIterationTypesOfIterable(yieldExprType, core.IfElse(isAsync, checker.IterationUse.AsyncYieldStar, checker.IterationUse.YieldStar), yieldExpr:Expression())
            nextType = iterationTypes.nextType
        else
            nextType = self:getContextualType(yieldExpr, checker.ContextFlags.None)
        end
        if nextType ~= nil then
            nextTypes = core.AppendIfUnique(nextTypes, nextType)
        end
        return false
    end)
    return yieldTypes, nextTypes
end

function Checker:createPromiseType(promisedType)
    -- creates a `Promise<T>` type where `T` is the promisedType argument
    local globalPromiseType = self.getGlobalPromiseTypeChecked()
    if globalPromiseType ~= self.emptyGenericType then
        -- if the promised type is itself a promise, get the underlying type; otherwise, fallback to the promised type
        -- Unwrap an `Awaited<T>` to `T` to improve inference.
        promisedType = core.OrElse(self:getAwaitedTypeNoAlias(self:unwrapAwaitedType(promisedType)), self.unknownType)
        return self:createTypeReference(globalPromiseType, { promisedType })
    end
    return self.unknownType
end

function Checker:createPromiseLikeType(promisedType)
    -- creates a `PromiseLike<T>` type where `T` is the promisedType argument
    local globalPromiseLikeType = self.getGlobalPromiseLikeType()
    if globalPromiseLikeType ~= self.emptyGenericType then
        -- if the promised type is itself a promise, get the underlying type; otherwise, fallback to the promised type
        -- Unwrap an `Awaited<T>` to `T` to improve inference.
        promisedType = core.OrElse(self:getAwaitedTypeNoAlias(self:unwrapAwaitedType(promisedType)), self.unknownType)
        return self:createTypeReference(globalPromiseLikeType, { promisedType })
    end
    return self.unknownType
end

function Checker:createPromiseReturnType(fn, promisedType)
    local promiseType = self:createPromiseType(promisedType)
    if promiseType == self.unknownType then
        self:error(fn, core.IfElse(ast.IsImportCall(fn),
            diagnostics.A_dynamic_import_call_returns_a_Promise_Make_sure_you_have_a_declaration_for_Promise_or_include_ES2015_in_your_lib_option,
            diagnostics.An_async_function_or_method_must_return_a_Promise_Make_sure_you_have_a_declaration_for_Promise_or_include_ES2015_in_your_lib_option))
        return self.errorType
    end
    if self.getGlobalPromiseConstructorSymbol() == nil then
        self:error(fn, core.IfElse(ast.IsImportCall(fn),
            diagnostics.A_dynamic_import_call_in_ES5_requires_the_Promise_constructor_Make_sure_you_have_a_declaration_for_the_Promise_constructor_or_include_ES2015_in_your_lib_option,
            diagnostics.An_async_function_or_method_in_ES5_requires_the_Promise_constructor_Make_sure_you_have_a_declaration_for_the_Promise_constructor_or_include_ES2015_in_your_lib_option))
    end
    return promiseType
end

function Checker:unwrapReturnType(returnType, functionFlags)
    local isGenerator = functionFlags & FunctionFlags.Generator ~= 0
    local isAsync = functionFlags & FunctionFlags.Async ~= 0
    if isGenerator then
        local returnIterationType = self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Return, returnType, isAsync)
        if returnIterationType == nil then
            return self.errorType
        end
        if isAsync then
            return self:getAwaitedTypeNoAlias(self:unwrapAwaitedType(returnIterationType))
        end
        return returnIterationType
    end
    if isAsync then
        return core.OrElse(self:getAwaitedTypeNoAlias(returnType), self.errorType)
    end
    return returnType
end

function Checker:getWidenedLiteralLikeTypeForContextualReturnTypeIfNeeded(t, contextualSignatureReturnType, isAsync)
    if t ~= nil and checker.isUnitType(t) then
        local contextualType
        if contextualSignatureReturnType == nil then
            -- No contextual type
        elseif isAsync then
            contextualType = self:GetPromisedTypeOfPromise(contextualSignatureReturnType)
        else
            contextualType = contextualSignatureReturnType
        end
        t = self:getWidenedLiteralLikeTypeForContextualType(t, contextualType)
    end
    return t
end

function Checker:getWidenedLiteralLikeTypeForContextualIterationTypeIfNeeded(t, contextualSignatureReturnType, kind, isAsyncGenerator)
    if t ~= nil and checker.isUnitType(t) then
        local contextualType
        if contextualSignatureReturnType ~= nil then
            contextualType = self:getIterationTypeOfGeneratorFunctionReturnType(kind, contextualSignatureReturnType, isAsyncGenerator)
        end
        t = self:getWidenedLiteralLikeTypeForContextualType(t, contextualType)
    end
    return t
end

function Checker:createGeneratorType(yieldType, returnType, nextType, isAsyncGenerator)
    local resolver = core.IfElse(isAsyncGenerator, self.asyncIterationTypesResolver, self.syncIterationTypesResolver)
    local globalGeneratorType = resolver.getGlobalGeneratorType()
    yieldType = core.OrElse(resolver.resolveIterationType(yieldType, nil --[[errorNode]]), self.unknownType)
    returnType = core.OrElse(resolver.resolveIterationType(returnType, nil --[[errorNode]]), self.unknownType)
    if globalGeneratorType == self.emptyGenericType then
        -- Fall back to the global IterableIterator type.
        local globalIterableIteratorType = resolver.getGlobalIterableIteratorType()
        if globalIterableIteratorType ~= self.emptyGenericType then
            return self:createTypeFromGenericGlobalType(globalIterableIteratorType, { yieldType, returnType, nextType })
        end
        -- The global Generator type doesn't exist, so report an error
        resolver.getGlobalIterableIteratorTypeChecked()
        return self.emptyObjectType
    end
    return self:createTypeFromGenericGlobalType(globalGeneratorType, { yieldType, returnType, nextType })
end

function Checker:reportErrorsFromWidening(declaration, t, wideningKind)
    if self.noImplicitAny and t.objectFlags & ObjectFlags.ContainsWideningType ~= 0 then
        if wideningKind == WideningKind.Normal or ast.IsFunctionLikeDeclaration(declaration) and self:shouldReportErrorsFromWideningWithContextualSignature(declaration, wideningKind) then
            -- Report implicit any error within type if possible, otherwise report error on declaration
            if not self:reportWideningErrorsInType(t) then
                self:reportImplicitAny(declaration, t, wideningKind)
            end
        end
    end
end

function Checker:shouldReportErrorsFromWideningWithContextualSignature(declaration, wideningKind)
    local signature = self:getContextualSignatureForFunctionLikeDeclaration(declaration)
    if signature == nil then
        return true
    end
    local returnType = self:getReturnTypeOfSignature(signature)
    local flags = ast.GetFunctionFlags(declaration)
    if wideningKind == WideningKind.FunctionReturn then
        if flags & FunctionFlags.Generator ~= 0 then
            returnType = core.OrElse(self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Return, returnType, flags & FunctionFlags.Async ~= 0), returnType)
        elseif flags & FunctionFlags.Async ~= 0 then
            returnType = core.OrElse(self:getAwaitedTypeNoAlias(returnType), returnType)
        end
        return self:isGenericType(returnType)
    elseif wideningKind == WideningKind.GeneratorYield then
        local yieldType = self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Yield, returnType, flags & FunctionFlags.Async ~= 0)
        return yieldType ~= nil and self:isGenericType(yieldType)
    elseif wideningKind == WideningKind.GeneratorNext then
        local nextType = self:getIterationTypeOfGeneratorFunctionReturnType(IterationTypeKind.Next, returnType, flags & FunctionFlags.Async ~= 0)
        return nextType ~= nil and self:isGenericType(nextType)
    end
    return false
end

-- Reports implicit any errors that occur as a result of widening 'null' and 'undefined'
-- to 'any'. A call to reportWideningErrorsInType is normally accompanied by a call to
-- getWidenedType. But in some cases getWidenedType is called without reporting errors
-- (type argument inference is an example).
--
-- The return value indicates whether an error was in fact reported. The particular circumstances
-- are on a best effort basis. Currently, if the null or undefined that causes widening is inside
-- an object literal property (arbitrarily deeply), this function reports an error. If no error is
-- reported, reportImplicitAnyError is a suitable fallback to report a general error.
function Checker:reportWideningErrorsInType(t)
    local errorReported = false
    if t.objectFlags & ObjectFlags.ContainsWideningType ~= 0 then
        if t.flags & TypeFlags.Union ~= 0 then
            if core.Some(t:Types(), function(x) return self:isEmptyObjectType(x) end) then
                errorReported = true
            else
                for _, s in ipairs(t:Types()) do
                    errorReported = errorReported or self:reportWideningErrorsInType(s)
                end
            end
        elseif self:isArrayOrTupleType(t) then
            for _, s in ipairs(self:getTypeArguments(t) or {}) do
                errorReported = errorReported or self:reportWideningErrorsInType(s)
            end
        elseif checker.isObjectLiteralType(t) then
            for _, p in ipairs(self:getPropertiesOfObjectType(t) or {}) do
                local s = self:getTypeOfSymbol(p)
                if s.objectFlags & ObjectFlags.ContainsWideningType ~= 0 then
                    errorReported = self:reportWideningErrorsInType(s)
                    if not errorReported then
                        -- we need to account for property types coming from object literal type normalization in unions
                        local valueDeclaration = core.Find(p.declarations, function(d)
                            local valueDeclaration = d:Symbol().valueDeclaration
                            return valueDeclaration ~= nil and valueDeclaration.parent == t.symbol.valueDeclaration
                        end)
                        if valueDeclaration ~= nil then
                            self:error(valueDeclaration, diagnostics.Object_literal_s_property_0_implicitly_has_an_1_type, self:symbolToString(p), self:TypeToString(self:getWidenedType(s)))
                            errorReported = true
                        end
                    end
                end
            end
        end
    end
    return errorReported
end

function Checker:getTypePredicateFromBody(fn)
    local k = fn.kind
    if k == Kind.Constructor or k == Kind.GetAccessor or k == Kind.SetAccessor then
        return nil
    end
    local functionFlags = ast.GetFunctionFlags(fn)
    if functionFlags ~= FunctionFlags.Normal then
        return nil
    end
    -- Only attempt to infer a type predicate if there's exactly one return.
    local singleReturn
    local body = fn:Body()
    if body ~= nil and not ast.IsBlock(body) then
        -- arrow function
        singleReturn = body
    else
        local bailedEarly = ast.ForEachReturnStatement(body, function(returnStatement)
            if singleReturn ~= nil or returnStatement:Expression() == nil then
                return true
            end
            singleReturn = returnStatement:Expression()
            return false
        end)
        if bailedEarly or singleReturn == nil or self:functionHasImplicitReturn(fn) then
            return nil
        end
    end
    return self:checkIfExpressionRefinesAnyParameter(fn, singleReturn)
end

function Checker:checkIfExpressionRefinesAnyParameter(fn, expr)
    expr = ast.SkipParentheses(expr)
    local returnType = self:checkExpressionCached(expr)
    if returnType.flags & TypeFlags.Boolean == 0 then
        return nil
    end
    for i1, param in ipairs(fn:Parameters() or {}) do
        local i = i1 - 1
        local initType = self:getTypeOfSymbol(param:Symbol())
        if initType == nil or initType.flags & TypeFlags.Boolean ~= 0 or not ast.IsIdentifier(param:Name()) or self:isSymbolAssigned(param:Symbol()) or checker.isRestParameter(param) then
            -- Refining "x: boolean" to "x is true" or "x is false" isn't useful.
            goto continue
        end
        do
            local trueType = self:checkIfExpressionRefinesParameter(fn, expr, param, initType)
            if trueType ~= nil then
                return self:newTypePredicate(TypePredicateKind.Identifier, param:Name():Text(), i, trueType)
            end
        end
        ::continue::
    end
    return nil
end

function Checker:checkIfExpressionRefinesParameter(fn, expr, param, initType)
    local antecedent = checker.getFlowNodeOfNode(expr)
    if antecedent == nil and ast.IsReturnStatement(expr.parent) then
        antecedent = checker.getFlowNodeOfNode(expr.parent)
    end
    if antecedent == nil then
        antecedent = ast.NewFlowNode(ast.FlowFlags.Start, nil, nil, nil)
    end
    local trueCondition = ast.NewFlowNode(ast.FlowFlags.TrueCondition, expr, antecedent, nil)
    local trueType = self:getFlowTypeOfReferenceEx(param:Name(), initType, initType, fn, trueCondition)
    if trueType == initType then
        return nil
    end
    -- "x is T" means that x is T if and only if it returns true. If it returns false then x is not T.
    -- This means that if the function is called with an argument of type trueType, there can't be anything left in the `else` branch. It must reduce to `never`.
    local falseCondition = ast.NewFlowNode(ast.FlowFlags.FalseCondition, expr, antecedent, nil)
    local falseSubtype = self:getReducedType(self:getFlowTypeOfReferenceEx(param:Name(), initType, trueType, fn, falseCondition))
    if falseSubtype.flags & TypeFlags.Never ~= 0 then
        return trueType
    end
    return nil
end

function Checker:addOptionalTypeMarker(t)
    if self.strictNullChecks then
        return self:getUnionType({ t, self.optionalType })
    end
    return t
end

function Checker:instantiateSignature(sig, m)
    return self:instantiateSignatureEx(sig, m, m == self.permissiveMapper --[[eraseTypeParameters]])
end

function Checker:instantiateSignatureEx(sig, m, eraseTypeParameters)
    local freshTypeParameters
    if core.Len(sig.typeParameters) ~= 0 and not eraseTypeParameters then
        -- First create a fresh set of type parameters, then include a mapping from the old to the
        -- new type parameters in the mapper function. Finally store this mapper in the new type
        -- parameters such that we can use it when instantiating constraints.
        freshTypeParameters = core.Map(sig.typeParameters, function(tp) return self:cloneTypeParameter(tp) end)
        m = self:combineTypeMappers(checker.newTypeMapper(sig.typeParameters, freshTypeParameters), m)
        for _, tp in ipairs(freshTypeParameters) do
            tp:AsTypeParameter().mapper = m
        end
    end
    -- Don't compute resolvedReturnType and resolvedTypePredicate now,
    -- because using `mapper` now could trigger inferences to become fixed. (See `createInferenceContext`.)
    -- See GH#17600.
    local result = self:newSignature(sig.flags & SignatureFlags.PropagatingFlags, sig.declaration, freshTypeParameters,
        self:instantiateSymbol(sig.thisParameter, m), self:instantiateSymbols(sig.parameters, m),
        nil --[[resolvedReturnType]], nil --[[resolvedTypePredicate]], sig.minArgumentCount)
    result.target = sig
    result.mapper = m
    return result
end

function Checker:instantiateIndexInfo(info, m)
    local newValueType = self:instantiateType(info.valueType, m)
    if newValueType == info.valueType then
        return info
    end
    return self:newIndexInfo(info.keyType, newValueType, info.isReadonly, info.declaration, info.components)
end

function Checker:resolveAnonymousTypeMembers(t)
    local d = t:AsObjectType()
    if d.target ~= nil then
        self:setStructuredTypeMembers(t, nil, nil, nil, nil)
        local members = self:createInstantiatedSymbolTable(self:getPropertiesOfObjectType(d.target), d.mapper)
        local callSignatures = self:instantiateSignatures(self:getSignaturesOfType(d.target, SignatureKind.Call), d.mapper)
        local constructSignatures = self:instantiateSignatures(self:getSignaturesOfType(d.target, SignatureKind.Construct), d.mapper)
        local indexInfos = self:instantiateIndexInfos(self:getIndexInfosOfType(d.target), d.mapper)
        self:setStructuredTypeMembers(t, members, callSignatures, constructSignatures, indexInfos)
        return
    end
    local symbol = self:getMergedSymbol(t.symbol)
    if symbol.flags & SymbolFlags.TypeLiteral ~= 0 then
        self:setStructuredTypeMembers(t, nil, nil, nil, nil)
        local members = self:getMembersOfSymbol(symbol)
        local callSignatures = self:getSignaturesOfSymbol(members and members[ast.InternalSymbolNameCall])
        local constructSignatures = self:getSignaturesOfSymbol(members and members[ast.InternalSymbolNameNew])
        local indexInfos = self:getIndexInfosOfSymbol(symbol)
        self:setStructuredTypeMembers(t, members, callSignatures, constructSignatures, indexInfos)
        return
    end
    -- Combinations of function, class, enum and module
    local members = self:getExportsOfSymbol(symbol)
    local indexInfos = nil
    if symbol == self.globalThisSymbol then
        local varsOnly = ast.NewSymbolTable()
        for _, p in pairs(members or {}) do
            if p.flags & SymbolFlags.BlockScoped == 0 and not (p.flags & SymbolFlags.ValueModule ~= 0 and core.Len(p.declarations) ~= 0 and core.Every(p.declarations, ast.IsAmbientModule)) then
                varsOnly[p.name] = p
            end
        end
        members = varsOnly
    end
    local baseConstructorIndexInfo
    self:setStructuredTypeMembers(t, members, nil, nil, nil)
    if symbol.flags & SymbolFlags.Class ~= 0 then
        local classType = self:getDeclaredTypeOfClassOrInterface(symbol)
        local baseConstructorType = self:getBaseConstructorTypeOfClass(classType)
        if baseConstructorType.flags & (TypeFlags.Object | TypeFlags.Intersection | TypeFlags.TypeVariable) ~= 0 then
            members = mapsClone(members)
            self:addInheritedMembers(members, self:getPropertiesOfType(baseConstructorType))
            self:setStructuredTypeMembers(t, members, nil, nil, nil)
        elseif baseConstructorType == self.anyType then
            baseConstructorIndexInfo = self.anyBaseTypeIndexInfo
        end
    end
    local indexSymbol = members and members[ast.InternalSymbolNameIndex]
    if indexSymbol ~= nil then
        -- Go collects the values of a map (random order).
        local siblingSymbols = {}
        for _, s in pairs(members) do
            siblingSymbols[#siblingSymbols + 1] = s
        end
        indexInfos = self:getIndexInfosOfIndexSymbol(indexSymbol, siblingSymbols)
    else
        if baseConstructorIndexInfo ~= nil then
            indexInfos = core.Append(indexInfos, baseConstructorIndexInfo)
        end
        if symbol.flags & SymbolFlags.Enum ~= 0 and (self:getDeclaredTypeOfSymbol(symbol).flags & TypeFlags.Enum ~= 0 or core.Some(d.properties, function(prop)
            return self:getTypeOfSymbol(prop).flags & TypeFlags.NumberLike ~= 0
        end)) then
            indexInfos = core.Append(indexInfos, self.enumNumberIndexInfo)
        end
    end
    d.indexInfos = indexInfos
    -- We resolve the members before computing the signatures because a signature may use
    -- typeof with a qualified name expression that circularly references the type we are
    -- in the process of resolving (see issue #6072). The temporarily empty signature list
    -- will never be observed because a qualified name can't reference signatures.
    if symbol.flags & (SymbolFlags.Function | SymbolFlags.Method) ~= 0 then
        d.signatures = self:getSignaturesOfSymbol(symbol)
        d.callSignatureCount = core.Len(d.signatures)
    end
    -- And likewise for construct signatures for classes
    if symbol.flags & SymbolFlags.Class ~= 0 then
        local classType = self:getDeclaredTypeOfClassOrInterface(symbol)
        local constructSignatures = self:getSignaturesOfSymbol(symbol.members and symbol.members[ast.InternalSymbolNameConstructor])
        if core.Len(constructSignatures) == 0 then
            constructSignatures = self:getDefaultConstructSignatures(classType)
        end
        if d.signatures ~= nil or core.Len(constructSignatures) ~= 0 then
            d.signatures = core.AppendAll(d.signatures, constructSignatures)
        end
    end
end

function Checker:createInstantiatedSymbolTable(symbols, m)
    if core.Len(symbols) == 0 then
        return nil
    end
    local result = ast.NewSymbolTable()
    for _, symbol in ipairs(symbols) do
        result[symbol.name] = self:instantiateSymbol(symbol, m)
    end
    return result
end

function Checker:instantiateSymbolTable(symbols, m)
    if symbols == nil or next(symbols) == nil then
        return nil
    end
    local result = ast.NewSymbolTable()
    for id, symbol in pairs(symbols) do
        if self:isNamedMember(symbol, id) then
            result[id] = self:instantiateSymbol(symbol, m)
        end
    end
    return result
end

function Checker:instantiateSymbol(symbol, m)
    if symbol == nil then
        return nil
    end
    local links = self.valueSymbolLinks:Get(symbol)
    if m ~= nil and m:MapsThisOnly() and checker.isThisless(symbol) then
        return symbol
    end
    -- If the type of the symbol is already resolved, and if that type could not possibly
    -- be affected by instantiation, simply return the symbol itself.
    if links.resolvedType ~= nil and not self.couldContainTypeVariables(links.resolvedType) then
        if symbol.flags & SymbolFlags.SetAccessor == 0 then
            return symbol
        end
        -- If we're a setter, check writeType.
        if links.writeType ~= nil and not self.couldContainTypeVariables(links.writeType) then
            return symbol
        end
    end
    if symbol.checkFlags & CheckFlags.Instantiated ~= 0 then
        -- If symbol being instantiated is itself a instantiation, fetch the original target and combine the
        -- type mappers. This ensures that original type identities are properly preserved and that aliases
        -- always reference a non-aliases.
        symbol = links.target
        m = self:combineTypeMappers(links.mapper, m)
    end
    -- Keep the flags from the symbol we're instantiating.  Mark that is instantiated, and
    -- also transient so that we can just store data on it directly.
    local result = self:newSymbol(symbol.flags, symbol.name)
    result.checkFlags = CheckFlags.Instantiated | symbol.checkFlags & (CheckFlags.Readonly | CheckFlags.Late | CheckFlags.OptionalParameter | CheckFlags.RestParameter)
    result.declarations = symbol.declarations
    result.parent = symbol.parent
    result.valueDeclaration = symbol.valueDeclaration
    local resultLinks = self.valueSymbolLinks:Get(result)
    resultLinks.target = symbol
    resultLinks.mapper = m
    resultLinks.nameType = links.nameType
    return result
end

-- Returns true if the parameter or class/interface member given by the symbol is free of "this" references. The
-- function may return false for symbols that are actually free of "this" references because it is not
-- feasible to perform a complete analysis in all cases. In particular, property members with types
-- inferred from their initializers and function members with inferred return types are conservatively
-- assumed not to be free of "this" references.
function checker.isThisless(symbol)
    if core.Len(symbol.declarations) == 1 then
        local declaration = symbol.declarations[1]
        if declaration ~= nil then
            local k = declaration.kind
            if k == Kind.Parameter then
                return checker.isThislessVariableLikeDeclaration(declaration)
            elseif k == Kind.PropertyDeclaration or k == Kind.PropertySignature then
                return checker.isThislessVariableLikeDeclaration(declaration)
            elseif k == Kind.MethodDeclaration or k == Kind.MethodSignature or k == Kind.Constructor or k == Kind.GetAccessor or k == Kind.SetAccessor then
                return checker.isThislessFunctionLikeDeclaration(declaration)
            end
        end
    end
    return false
end

-- A variable-like declaration is free of this references if it has a type annotation
-- that is thisless, or if it has no type annotation and no initializer (and is thus of type any).
function checker.isThislessVariableLikeDeclaration(node)
    local typeNode = node:Type()
    if typeNode ~= nil then
        return checker.isThislessType(typeNode)
    end
    return node:Initializer() == nil
end

local thislessTypeKinds = ast.kindSet(Kind.AnyKeyword, Kind.UnknownKeyword, Kind.StringKeyword, Kind.NumberKeyword, Kind.BigIntKeyword, Kind.BooleanKeyword,
    Kind.SymbolKeyword, Kind.ObjectKeyword, Kind.VoidKeyword, Kind.UndefinedKeyword, Kind.NeverKeyword, Kind.LiteralType)

-- A type is free of this references if it's the any, string, number, boolean, symbol, or void keyword, a string
-- literal type, an array with an element type that is free of this references, or a type reference that is
-- free of this references.
function checker.isThislessType(node)
    local k = node.kind
    if thislessTypeKinds[k] then
        return true
    elseif k == Kind.ArrayType then
        return checker.isThislessType(node:AsArrayTypeNode().elementType)
    elseif k == Kind.TypeReference then
        return core.Every(node:TypeArguments(), checker.isThislessType)
    end
    return false
end

-- A function-like declaration is considered free of `this` references if it has a return type
-- annotation that is free of this references and if each parameter is thisless and if
-- each type parameter (if present) is thisless.
function checker.isThislessFunctionLikeDeclaration(node)
    local returnType = node:Type()
    return (ast.IsConstructorDeclaration(node) or returnType ~= nil and checker.isThislessType(returnType)) and
        core.Every(node:Parameters(), checker.isThislessVariableLikeDeclaration) and
        core.Every(node:TypeParameters(), checker.isThislessTypeParameter)
end

-- A type parameter is thisless if its constraint is thisless, or if it has no constraint. */
function checker.isThislessTypeParameter(node)
    local constraint = node:AsTypeParameterDeclaration().constraint
    return constraint == nil or checker.isThislessType(constraint)
end

function Checker:getDefaultConstructSignatures(classType)
    local baseConstructorType = self:getBaseConstructorTypeOfClass(classType)
    local baseSignatures = self:getSignaturesOfType(baseConstructorType, SignatureKind.Construct)
    local declaration = ast.GetClassLikeDeclarationOfSymbol(classType.symbol)
    local isAbstract = declaration ~= nil and ast.HasSyntacticModifier(declaration, ModifierFlags.Abstract)
    if core.Len(baseSignatures) == 0 then
        local flags = core.IfElse(isAbstract, SignatureFlags.Construct | SignatureFlags.Abstract, SignatureFlags.Construct)
        return { self:newSignature(flags, nil, classType:AsInterfaceType():LocalTypeParameters(), nil, nil, classType, nil, 0) }
    end
    local baseTypeNode = checker.getBaseTypeNodeOfClass(classType)
    local isJavaScript = declaration ~= nil and ast.IsInJSFile(declaration)
    local typeArguments = self:getTypeArgumentsFromNode(baseTypeNode)
    local typeArgCount = core.Len(typeArguments)
    local result
    for _, baseSig in ipairs(baseSignatures) do
        local minTypeArgumentCount = self:getMinTypeArgumentCount(baseSig.typeParameters)
        local typeParamCount = core.Len(baseSig.typeParameters)
        if isJavaScript or typeArgCount >= minTypeArgumentCount and typeArgCount <= typeParamCount then
            local sig
            if typeParamCount ~= 0 then
                sig = self:createSignatureInstantiation(baseSig, self:fillMissingTypeArguments(typeArguments, baseSig.typeParameters, minTypeArgumentCount, isJavaScript))
            else
                sig = self:cloneSignature(baseSig)
            end
            sig.typeParameters = classType:AsInterfaceType():LocalTypeParameters()
            sig.resolvedReturnType = classType
            if isAbstract then
                sig.flags = sig.flags | SignatureFlags.Abstract
            else
                sig.flags = sig.flags & ~SignatureFlags.Abstract
            end
            result = core.Append(result, sig)
        end
    end
    return result
end

function Checker:resolveMappedTypeMembers(t)
    local members = ast.NewSymbolTable()
    local indexInfos
    -- Resolve upfront such that recursive references see an empty object type.
    self:setStructuredTypeMembers(t, nil, nil, nil, nil)
    -- In { [P in K]: T }, we refer to P as the type parameter type, K as the constraint type,
    -- and T as the template type.
    local typeParameter = self:getTypeParameterFromMappedType(t)
    local constraintType = self:getConstraintTypeFromMappedType(t)
    local mappedType = core.OrElse(t:AsMappedType().target, t)
    local nameType = self:getNameTypeFromMappedType(mappedType)
    local shouldLinkPropDeclarations = self:getMappedTypeNameTypeKind(mappedType) ~= checker.MappedTypeNameTypeKind.Remapping
    local templateType = self:getTemplateTypeFromMappedType(mappedType)
    local modifiersType = self:getApparentType(self:getModifiersTypeFromMappedType(t))
    -- The 'T' in 'keyof T'
    local templateModifiers = checker.getMappedTypeModifiers(t)
    local include = TypeFlags.StringOrNumberLiteralOrUnique
    local addMemberForKeyTypeWorker = function(keyType, propNameType)
        -- If the current iteration type constituent is a string literal type, create a property.
        -- Otherwise, for type string create a string index signature.
        if checker.isTypeUsableAsPropertyName(propNameType) then
            local propName = checker.getPropertyNameFromType(propNameType)
            -- String enum members from separate enums with identical values
            -- are distinct types with the same property name. Make the resulting
            -- property symbol's name type be the union of those enum member types.
            local existingProp = members[propName]
            if existingProp ~= nil then
                local valueLinks = self.valueSymbolLinks:Get(existingProp)
                valueLinks.nameType = self:getUnionType({ valueLinks.nameType, propNameType })
                local mappedLinks = self.mappedSymbolLinks:Get(existingProp)
                mappedLinks.keyType = self:getUnionType({ mappedLinks.keyType, keyType })
            else
                local modifiersProp
                if checker.isTypeUsableAsPropertyName(keyType) then
                    modifiersProp = self:getPropertyOfType(modifiersType, checker.getPropertyNameFromType(keyType))
                end
                local isOptional = templateModifiers & MappedTypeModifiers.IncludeOptional ~= 0 or templateModifiers & MappedTypeModifiers.ExcludeOptional == 0 and modifiersProp ~= nil and modifiersProp.flags & SymbolFlags.Optional ~= 0
                local isReadonly = templateModifiers & MappedTypeModifiers.IncludeReadonly ~= 0 or templateModifiers & MappedTypeModifiers.ExcludeReadonly == 0 and modifiersProp ~= nil and self:isReadonlySymbol(modifiersProp)
                local stripOptional = self.strictNullChecks and not isOptional and modifiersProp ~= nil and modifiersProp.flags & SymbolFlags.Optional ~= 0
                local lateFlag = 0
                if modifiersProp ~= nil then
                    lateFlag = modifiersProp.checkFlags & CheckFlags.Late
                end
                local prop = self:newSymbol(SymbolFlags.Property | core.IfElse(isOptional, SymbolFlags.Optional, 0), propName)
                prop.checkFlags = lateFlag | CheckFlags.Mapped | core.IfElse(isReadonly, CheckFlags.Readonly, 0) | core.IfElse(stripOptional, CheckFlags.StripOptional, 0)
                local valueLinks = self.valueSymbolLinks:Get(prop)
                valueLinks.containingType = t
                valueLinks.nameType = propNameType
                local mappedLinks = self.mappedSymbolLinks:Get(prop)
                mappedLinks.keyType = keyType
                if modifiersProp ~= nil then
                    mappedLinks.syntheticOrigin = modifiersProp
                    if shouldLinkPropDeclarations then
                        prop.declarations = modifiersProp.declarations
                    end
                end
                members[propName] = prop
            end
        elseif self:isValidIndexKeyType(propNameType) or propNameType.flags & (TypeFlags.Any | TypeFlags.Enum) ~= 0 then
            local indexKeyType = propNameType
            if propNameType.flags & (TypeFlags.Any | TypeFlags.String) ~= 0 then
                indexKeyType = self.stringType
            elseif propNameType.flags & (TypeFlags.Number | TypeFlags.Enum) ~= 0 then
                indexKeyType = self.numberType
            end
            local propType = self:instantiateType(templateType, checker.appendTypeMapping(t:AsMappedType().mapper, typeParameter, keyType))
            local modifiersIndexInfo = self:getApplicableIndexInfo(modifiersType, propNameType)
            local isReadonly = templateModifiers & MappedTypeModifiers.IncludeReadonly ~= 0 or templateModifiers & MappedTypeModifiers.ExcludeReadonly == 0 and modifiersIndexInfo ~= nil and modifiersIndexInfo.isReadonly
            local indexInfo = self:newIndexInfo(indexKeyType, propType, isReadonly, nil, nil)
            indexInfos = self:appendIndexInfo(indexInfos, indexInfo, true --[[union]])
        end
    end
    local addMemberForKeyType = function(keyType)
        local propNameType = keyType
        if nameType ~= nil then
            propNameType = self:instantiateType(nameType, checker.appendTypeMapping(t:AsMappedType().mapper, typeParameter, keyType))
        end
        checker.forEachType(propNameType, function(u)
            addMemberForKeyTypeWorker(keyType, u)
        end)
    end
    if self:isMappedTypeWithKeyofConstraintDeclaration(t) then
        -- We have a { [P in keyof T]: X }
        self:forEachMappedTypePropertyKeyTypeAndIndexSignatureKeyType(modifiersType, include, false --[[stringsOnly]], addMemberForKeyType)
    else
        checker.forEachType(self:getLowerBoundOfKeyType(constraintType), addMemberForKeyType)
    end
    self:setStructuredTypeMembers(t, members, nil, nil, indexInfos)
end

function Checker:getTypeOfMappedSymbol(symbol)
    local links = self.valueSymbolLinks:Get(symbol)
    if links.resolvedType == nil then
        local mappedType = links.containingType
        if not self:pushTypeResolution(symbol, TypeSystemPropertyName.Type) then
            mappedType:AsMappedType().containsError = true
            return self.errorType
        end
        local templateType = self:getTemplateTypeFromMappedType(core.OrElse(mappedType:AsMappedType().target, mappedType))
        local mapper = checker.appendTypeMapping(mappedType:AsMappedType().mapper, self:getTypeParameterFromMappedType(mappedType), self.mappedSymbolLinks:Get(symbol).keyType)
        local propType = self:instantiateType(templateType, mapper)
        -- When creating an optional property in strictNullChecks mode, if 'undefined' isn't assignable to the
        -- type, we include 'undefined' in the type. Similarly, when creating a non-optional property in strictNullChecks
        -- mode, if the underlying property is optional we remove 'undefined' from the type.
        if self.strictNullChecks and symbol.flags & SymbolFlags.Optional ~= 0 and not self:maybeTypeOfKind(propType, TypeFlags.Undefined | TypeFlags.Void) then
            propType = self:getOptionalType(propType, true --[[isProperty]])
        elseif symbol.checkFlags & CheckFlags.StripOptional ~= 0 then
            propType = self:removeMissingOrUndefinedType(propType)
        end
        if self:popTypeResolution() then
            if links.resolvedType == nil then
                links.resolvedType = propType
            end
        else
            if links.resolvedType == nil then
                links.resolvedType = self.errorType
            end
            self:error(self.currentNode, diagnostics.Type_of_property_0_circularly_references_itself_in_mapped_type_1, self:symbolToString(symbol), self:TypeToString(mappedType))
        end
    end
    return links.resolvedType
end

-- Return the lower bound of the key type in a mapped type. Intuitively, the lower
-- bound includes those keys that are known to always be present, for example because
-- because of constraints on type parameters (e.g. 'keyof T' for a constrained T).
function Checker:getLowerBoundOfKeyType(t)
    if t.flags & TypeFlags.Index ~= 0 then
        local at = self:getApparentType(t:AsIndexType().target)
        if self:isGenericTupleType(at) then
            return self:getKnownKeysOfTupleType(at)
        end
        return self:getIndexType(at)
    elseif t.flags & TypeFlags.Conditional ~= 0 then
        if t:AsConditionalType().root.isDistributive then
            local checkType = t:AsConditionalType().checkType
            local constraint = self:getLowerBoundOfKeyType(checkType)
            if constraint ~= checkType then
                return self:getConditionalTypeInstantiation(t, checker.prependTypeMapping(t:AsConditionalType().root.checkType, constraint, t:AsConditionalType().mapper), false --[[forConstraint]], nil)
            end
        end
        return t
    elseif t.flags & TypeFlags.Union ~= 0 then
        return self:mapTypeEx(t, function(x) return self:getLowerBoundOfKeyType(x) end, true --[[noReductions]])
    elseif t.flags & TypeFlags.Intersection ~= 0 then
        -- Similarly to getTypeFromIntersectionTypeNode, we preserve the special string & {}, number & {},
        -- and bigint & {} intersections that are used to prevent subtype reduction in union types.
        local types = t:Types()
        if #types == 2 and types[1].flags & (TypeFlags.String | TypeFlags.Number | TypeFlags.BigInt) ~= 0 and types[2] == self.emptyTypeLiteralType then
            return t
        end
        return self:getIntersectionType(core.SameMap(t:Types(), function(x) return self:getLowerBoundOfKeyType(x) end))
    end
    return t
end

function Checker:resolveUnionTypeMembers(t)
    -- The members and properties collections are empty for union types. To get all properties of a union
    -- type use getPropertiesOfType (only the language service uses this).
    local callSignatures = self:getUnionSignatures(core.Map(t:Types(), function(u)
        if u == self.globalFunctionType then
            return { self.unknownSignature }
        end
        return self:getSignaturesOfType(u, SignatureKind.Call)
    end))
    if core.Len(callSignatures) == 0 then
        callSignatures = self:getArrayMemberCallSignatures(t)
    end
    local constructSignatures = self:getUnionSignatures(core.Map(t:Types(), function(u)
        return self:getSignaturesOfType(u, SignatureKind.Construct)
    end))
    local indexInfos = self:getUnionIndexInfos(t:Types())
    self:setStructuredTypeMembers(t, nil, callSignatures, constructSignatures, indexInfos)
end

function Checker:getArrayMemberCallSignatures(t)
    -- Check if union is exclusively instantiations of a member of the global Array or ReadonlyArray type.
    local memberName = ""
    for i1, ti in ipairs(t:Types()) do
        if ti.objectFlags & ObjectFlags.Instantiated == 0 or ti.symbol == nil or ti.symbol.parent == nil or not self:isArrayOrTupleSymbol(ti.symbol.parent) then
            return nil
        end
        if i1 == 1 then
            memberName = ti.symbol.name
        elseif memberName ~= ti.symbol.name then
            return nil
        end
    end
    -- Transform the type from `(A[] | B[])["member"]` to `(A | B)[]["member"]` (since we pretend array is covariant anyway).
    local arrayArg = self:mapType(t, function(u)
        return u:Mapper():Map(core.IfElse(self:isReadonlyArraySymbol(u.symbol.parent), self.globalReadonlyArrayType, self.globalArrayType):AsInterfaceType():TypeParameters()[1])
    end)
    local arrayType = self:createArrayTypeEx(arrayArg, checker.someType(t, function(u)
        return self:isReadonlyArraySymbol(u.symbol.parent)
    end))
    return self:getSignaturesOfType(self:getTypeOfPropertyOfType(arrayType, memberName), SignatureKind.Call)
end

function Checker:isArrayOrTupleSymbol(symbol)
    if symbol == nil or self.globalArrayType.symbol == nil or self.globalReadonlyArrayType.symbol == nil then
        return false
    end
    return self:getSymbolIfSameReference(symbol, self.globalArrayType.symbol) ~= nil or self:getSymbolIfSameReference(symbol, self.globalReadonlyArrayType.symbol) ~= nil
end

function Checker:isReadonlyArraySymbol(symbol)
    if symbol == nil or self.globalReadonlyArrayType.symbol == nil then
        return false
    end
    return self:getSymbolIfSameReference(symbol, self.globalReadonlyArrayType.symbol) ~= nil
end

-- The signatures of a union type are those signatures that are present in each of the constituent types.
-- Generic signatures must match exactly, but non-generic signatures are allowed to have extra optional
-- parameters and may differ in return types. When signatures differ in return types, the resulting return
-- type is the union of the constituent return types.
function Checker:getUnionSignatures(signatureLists)
    local result
    local indexWithLengthOverOne = 0
    local countLengthOverOne = 0
    for i1, list in ipairs(signatureLists) do
        local i = i1 - 1
        if core.Len(list) == 0 then
            return nil
        end
        if #list > 1 then
            indexWithLengthOverOne = i
            countLengthOverOne = countLengthOverOne + 1
        end
        for _, signature in ipairs(list) do
            -- Only process signatures with parameter lists that aren't already in the result list
            if result == nil or self:findMatchingSignature(result, signature, false --[[partialMatch]], false --[[ignoreThisTypes]], true --[[ignoreReturnTypes]]) == nil then
                local unionSignatures = self:findMatchingSignatures(signatureLists, signature, i)
                if unionSignatures ~= nil then
                    local s = signature
                    -- Union the result types when more than one signature matches
                    if #unionSignatures > 1 then
                        local thisParameter = signature.thisParameter
                        local firstThisParameterOfUnionSignatures = core.FirstNonNil(unionSignatures, function(sig)
                            return sig.thisParameter
                        end)
                        if firstThisParameterOfUnionSignatures ~= nil then
                            local thisType = self:getIntersectionType(core.MapNonNil(unionSignatures, function(sig)
                                if sig.thisParameter ~= nil then
                                    return self:getTypeOfSymbol(sig.thisParameter)
                                end
                                return nil
                            end))
                            thisParameter = self:createSymbolWithType(firstThisParameterOfUnionSignatures, thisType)
                        end
                        s = self:createUnionSignature(signature, unionSignatures)
                        s.thisParameter = thisParameter
                    end
                    result = core.Append(result, s)
                end
            end
        end
    end
    if core.Len(result) == 0 and countLengthOverOne <= 1 then
        -- No sufficiently similar signature existed to subsume all the other signatures in the union - time to see if we can make a single
        -- signature that handles all of them. We only do this when there are overloads in only one constituent. (Overloads are conditional in
        -- nature and having overloads in multiple constituents would necessitate making a power set of signatures from the type, whose
        -- ordering would be non-obvious)
        local masterList = signatureLists[indexWithLengthOverOne + 1]
        local results = core.Slice(masterList, 0, core.Len(masterList))
        for _, signatures in ipairs(signatureLists) do
            if not core.Same(signatures, masterList) then
                local signature = signatures[1]
                debug.Assert(signature ~= nil, "getUnionSignatures bails early on empty signature lists and should not have empty lists on second pass")
                if core.Len(signature.typeParameters) ~= 0 and core.Some(results, function(s)
                    return core.Len(s.typeParameters) ~= 0 and not self:compareTypeParametersIdentical(signature.typeParameters, s.typeParameters)
                end) then
                    results = nil
                else
                    results = core.Map(results, function(sig)
                        return self:combineUnionOrIntersectionMemberSignatures(sig, signature, true --[[isUnion]])
                    end)
                end
                if results == nil then
                    break
                end
            end
        end
        result = results
    end
    return result
end

function Checker:combineUnionOrIntersectionMemberSignatures(left, right, isUnion)
    local typeParams = left.typeParameters
    if core.Len(typeParams) == 0 then
        typeParams = right.typeParameters
    end
    local paramMapper
    if core.Len(left.typeParameters) ~= 0 and core.Len(right.typeParameters) ~= 0 then
        -- We just use the type parameter defaults from the first signature
        paramMapper = checker.newTypeMapper(right.typeParameters, left.typeParameters)
    end
    local flags = (left.flags | right.flags) & (SignatureFlags.PropagatingFlags & ~SignatureFlags.HasRestParameter)
    local declaration = left.declaration
    local params = self:combineUnionOrIntersectionParameters(left, right, paramMapper, isUnion)
    local lastParam = core.LastOrNil(params)
    if lastParam ~= nil and lastParam.checkFlags & CheckFlags.RestParameter ~= 0 then
        flags = flags | SignatureFlags.HasRestParameter
    end
    local thisParam = self:combineUnionOrIntersectionThisParam(left.thisParameter, right.thisParameter, paramMapper, isUnion)
    local minArgCount = math.max(left.minArgumentCount, right.minArgumentCount)
    local result = self:newSignature(flags, declaration, typeParams, thisParam, params, nil, nil, minArgCount)
    local leftSignatures
    if left.composite ~= nil and left.composite.isUnion then
        leftSignatures = left.composite.signatures
    else
        leftSignatures = { left }
    end
    local signatures = core.Slice(leftSignatures, 0, #leftSignatures)
    signatures[#signatures + 1] = right
    result.composite = checker.CompositeSignature_new({ isUnion = isUnion, signatures = signatures })
    if paramMapper ~= nil then
        if left.composite ~= nil and left.composite.isUnion == isUnion and left.mapper ~= nil then
            result.mapper = self:combineTypeMappers(left.mapper, paramMapper)
        else
            result.mapper = paramMapper
        end
    elseif left.composite ~= nil and left.composite.isUnion == isUnion then
        result.mapper = left.mapper
    end
    return result
end

function Checker:combineUnionOrIntersectionParameters(left, right, mapper, isUnion)
    local leftCount = self:getParameterCount(left)
    local rightCount = self:getParameterCount(right)
    local longestCount
    local longest, shorter
    if leftCount >= rightCount then
        longestCount, longest, shorter = leftCount, left, right
    else
        longestCount, longest, shorter = rightCount, right, left
    end
    local eitherHasEffectiveRest = self:hasEffectiveRestParameter(left) or self:hasEffectiveRestParameter(right)
    local needsExtraRestElement = eitherHasEffectiveRest and not self:hasEffectiveRestParameter(longest)
    local params = {}
    for i = 0, longestCount - 1 do
        local longestParamType = self:tryGetTypeAtPosition(longest, i)
        if longest == right then
            longestParamType = self:instantiateType(longestParamType, mapper)
        end
        local shorterParamType = core.OrElse(self:tryGetTypeAtPosition(shorter, i), self.unknownType)
        if shorter == right then
            shorterParamType = self:instantiateType(shorterParamType, mapper)
        end
        local combinedParamType = self:getUnionOrIntersectionType({ longestParamType, shorterParamType }, not isUnion, UnionReduction.Literal)
        local isRestParam = eitherHasEffectiveRest and not needsExtraRestElement and i == (longestCount - 1)
        local isOptional = i >= self:getMinArgumentCount(longest) and i >= self:getMinArgumentCount(shorter)
        local leftName, rightName = "", ""
        if i < leftCount then
            leftName = self:getParameterNameAtPosition(left, i)
        end
        if i < rightCount then
            rightName = self:getParameterNameAtPosition(right, i)
        end
        local paramName = ""
        if leftName == rightName then
            paramName = leftName
        elseif leftName == "" then
            paramName = rightName
        elseif rightName == "" then
            paramName = leftName
        end
        if paramName == "" then
            paramName = "arg" .. i
        end
        local paramSymbol = self:newSymbolEx(SymbolFlags.FunctionScopedVariable | core.IfElse(isOptional and not isRestParam, SymbolFlags.Optional, 0), paramName,
            core.IfElse(isRestParam, CheckFlags.RestParameter, core.IfElse(isOptional, CheckFlags.OptionalParameter, 0)))
        local links = self.valueSymbolLinks:Get(paramSymbol)
        if isRestParam then
            links.resolvedType = self:createArrayType(combinedParamType)
        else
            links.resolvedType = combinedParamType
        end
        params[i + 1] = paramSymbol
    end
    if needsExtraRestElement then
        local restParamSymbol = self:newSymbolEx(SymbolFlags.FunctionScopedVariable, "args", CheckFlags.RestParameter)
        local links = self.valueSymbolLinks:Get(restParamSymbol)
        links.resolvedType = self:createArrayType(self:getTypeAtPosition(shorter, longestCount))
        if shorter == right then
            links.resolvedType = self:instantiateType(links.resolvedType, mapper)
        end
        params[longestCount + 1] = restParamSymbol
    end
    return params
end

function Checker:combineUnionOrIntersectionThisParam(left, right, mapper, isUnion)
    if left == nil then
        return right
    end
    if right == nil then
        return left
    end
    -- A signature `this` type might be a read or a write position... It's very possible that it should be invariant
    -- and we should refuse to merge signatures if there are `this` types and they do not match. However, so as to be
    -- permissive when calling, for now, we'll intersect the `this` types just like we do for param types in union signatures.
    local thisType = self:getUnionOrIntersectionType({ self:getTypeOfSymbol(left), self:instantiateType(self:getTypeOfSymbol(right), mapper) }, not isUnion, UnionReduction.Literal)
    return self:createSymbolWithType(left, thisType)
end

function Checker:resolveIntersectionTypeMembers(t)
    -- The members and properties collections are empty for intersection types. To get all properties of an
    -- intersection type use getPropertiesOfType (only the language service uses this).
    local callSignatures
    local constructSignatures
    local indexInfos
    local types = t:Types()
    local mixinFlags, mixinCount = self:findMixins(types)
    for i1, ti in ipairs(types) do
        local i = i1 - 1
        -- When an intersection type contains mixin constructor types, the construct signatures from
        -- those types are discarded and their return types are mixed into the return types of all
        -- other construct signatures in the intersection type. For example, the intersection type
        -- '{ new(...args: any[]) => A } & { new(s: string) => B }' has a single construct signature
        -- 'new(s: string) => A & B'.
        if not mixinFlags[i1] then
            local signatures = self:getSignaturesOfType(ti, SignatureKind.Construct)
            if core.Len(signatures) ~= 0 and mixinCount > 0 then
                signatures = core.Map(signatures, function(s)
                    local clone = self:cloneSignature(s)
                    clone.resolvedReturnType = self:includeMixinType(self:getReturnTypeOfSignature(s), types, mixinFlags, i)
                    return clone
                end)
            end
            constructSignatures = self:appendSignatures(constructSignatures, signatures)
        end
        callSignatures = self:appendSignatures(callSignatures, self:getSignaturesOfType(ti, SignatureKind.Call))
        for _, info in ipairs(self:getIndexInfosOfType(ti) or {}) do
            indexInfos = self:appendIndexInfo(indexInfos, info, false --[[union]])
        end
    end
    self:setStructuredTypeMembers(t, nil, callSignatures, constructSignatures, indexInfos)
end

function Checker:appendSignatures(signatures, newSignatures)
    for _, sig in ipairs(newSignatures or {}) do
        if core.Len(signatures) == 0 or core.Every(signatures, function(s)
            return self:compareSignaturesIdentical(s, sig, false --[[partialMatch]], false --[[ignoreThisTypes]], false --[[ignoreReturnTypes]], function(a, b) return self:compareTypesIdentical(a, b) end) == checker.Ternary.False
        end) then
            signatures = core.Append(signatures, sig)
        end
    end
    return signatures
end

function Checker:appendIndexInfo(indexInfos, newInfo, union)
    for i, info in ipairs(indexInfos or {}) do
        if info.keyType == newInfo.keyType then
            local valueType
            local isReadonly
            if union then
                valueType = self:getUnionType({ info.valueType, newInfo.valueType })
                isReadonly = info.isReadonly or newInfo.isReadonly
            else
                valueType = self:getIntersectionType({ info.valueType, newInfo.valueType })
                isReadonly = info.isReadonly and newInfo.isReadonly
            end
            indexInfos[i] = self:newIndexInfo(info.keyType, valueType, isReadonly, nil, nil)
            return indexInfos
        end
    end
    return core.Append(indexInfos, newInfo)
end

-- mixinFlags is an array of booleans parallel to types.
function Checker:findMixins(types)
    local mixinFlags = core.Map(types, function(t) return self:isMixinConstructorType(t) end)
    local constructorTypeCount, mixinCount = 0, 0
    local firstMixinIndex = -1
    for i1, t in ipairs(types) do
        local i = i1 - 1
        if core.Len(self:getSignaturesOfType(t, SignatureKind.Construct)) > 0 then
            constructorTypeCount = constructorTypeCount + 1
        end
        if mixinFlags[i1] then
            if firstMixinIndex < 0 then
                firstMixinIndex = i
            end
            mixinCount = mixinCount + 1
        end
    end
    if constructorTypeCount > 0 and constructorTypeCount == mixinCount then
        mixinFlags[firstMixinIndex + 1] = false
        mixinCount = mixinCount - 1
    end
    return mixinFlags, mixinCount
end

function Checker:includeMixinType(t, types, mixinFlags, index)
    local mixedTypes
    for i1 = 1, #types do
        local i = i1 - 1
        if i == index then
            mixedTypes = core.Append(mixedTypes, t)
        elseif mixinFlags[i1] then
            mixedTypes = core.Append(mixedTypes, self:getReturnTypeOfSignature(self:getSignaturesOfType(types[i1], SignatureKind.Construct)[1]))
        end
    end
    return self:getIntersectionType(mixedTypes)
end

--[[*
 * If the given type is an object type and that type has a property by the given name,
 * return the symbol for that property. Otherwise return undefined.
 ]]
function Checker:getPropertyOfObjectType(t, name)
    if t.flags & TypeFlags.Object ~= 0 then
        local resolved = self:resolveStructuredTypeMembers(t)
        local symbol = resolved.members and resolved.members[name]
        if symbol ~= nil and self:symbolIsValue(symbol) then
            return symbol
        end
    end
    return nil
end

function Checker:getPropertyOfUnionOrIntersectionType(t, name, skipObjectFunctionPropertyAugment)
    local prop = self:getUnionOrIntersectionProperty(t, name, skipObjectFunctionPropertyAugment)
    -- We need to filter out partial properties in union types
    if prop ~= nil and prop.checkFlags & CheckFlags.ReadPartial ~= 0 then
        return nil
    end
    return prop
end
