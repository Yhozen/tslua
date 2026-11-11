local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")

function Checker:GetStringType()
    return self.stringType
end

function Checker:GetNumberType()
    return self.numberType
end

function Checker:GetBooleanType()
    return self.booleanType
end

function Checker:GetVoidType()
    return self.voidType
end

function Checker:GetUndefinedType()
    return self.undefinedType
end

function Checker:GetNullType()
    return self.nullType
end

function Checker:GetAnyType()
    return self.anyType
end

function Checker:GetErrorType()
    return self.errorType
end

function Checker:GetNeverType()
    return self.neverType
end

function Checker:GetUnknownType()
    return self.unknownType
end

function Checker:GetBigIntType()
    return self.bigintType
end

function Checker:GetESSymbolType()
    return self.esSymbolType
end

function Checker:GetNonPrimitiveType()
    return self.nonPrimitiveType
end

function Checker:GetBaseTypeOfLiteralType(t)
    return self:getBaseTypeOfLiteralType(t)
end

function Checker:GetUnknownSymbol()
    return self.unknownSymbol
end

function Checker:GetUndefinedSymbol()
    return self.undefinedSymbol
end

function Checker:GetArgumentsSymbol()
    return self.argumentsSymbol
end

function Checker:GetUnknownSignature()
    return self.unknownSignature
end

function Checker:GetUnionType(types)
    return self:getUnionType(types)
end

function Checker:GetNameTypeOfSymbol(symbol)
    if not self.valueSymbolLinks:Has(symbol) then
        return nil
    end
    return self.valueSymbolLinks:TryGet(symbol).nameType
end

function checker.IsTypeUsableAsPropertyName(t)
    return checker.isTypeUsableAsPropertyName(t)
end

function checker.GetPropertyNameFromType(t)
    return checker.getPropertyNameFromType(t)
end

function Checker:GetGlobalSymbol(name, meaning, diagnostic)
    return self:getGlobalSymbol(name, meaning, diagnostic)
end

function Checker:GetMergedSymbol(symbol)
    return self:getMergedSymbol(symbol)
end

function Checker:TryFindAmbientModule(moduleName)
    return self:tryFindAmbientModule(moduleName, true --[[withAugmentations]])
end

function Checker:GetImmediateAliasedSymbol(symbol)
    return self:getImmediateAliasedSymbol(symbol)
end

function Checker:GetTypeOnlyAliasDeclaration(symbol)
    return self:getTypeOnlyAliasDeclaration(symbol)
end

function Checker:ResolveExternalModuleName(moduleSpecifier)
    return self:resolveExternalModuleName(moduleSpecifier, moduleSpecifier, true --[[ignoreErrors]])
end

function Checker:ResolveExternalModuleSymbol(moduleSymbol)
    return self:resolveExternalModuleSymbol(moduleSymbol, false --[[dontResolveAlias]])
end

function Checker:GetTypeFromTypeNode(node)
    return self:getTypeFromTypeNode(node)
end

function Checker:IsArrayLikeType(t)
    return self:isArrayLikeType(t)
end

function Checker:GetPropertiesOfType(t)
    return self:getPropertiesOfType(t)
end

function Checker:GetPropertyOfType(t, name)
    return self:getPropertyOfType(t, name)
end

function Checker:TypeHasCallOrConstructSignatures(t)
    return self:typeHasCallOrConstructSignatures(t)
end

-- Checks if a property can be accessed in a location.
-- The location is given by the `node` parameter.
-- The node does not need to be a property access.
-- @param node location where to check property accessibility
-- @param isSuper whether to consider this a `super` property access, e.g. `super.foo`.
-- @param isWrite whether this is a write access, e.g. `++foo.x`.
-- @param containingType type where the property comes from.
-- @param property property symbol.
function Checker:IsPropertyAccessible(node, isSuper, isWrite, containingType, property)
    return self:isPropertyAccessible(node, isSuper, isWrite, containingType, property)
end

function Checker:GetTypeOfPropertyOfContextualType(t, name)
    return self:getTypeOfPropertyOfContextualType(t, name)
end

function checker.GetDeclarationModifierFlagsFromSymbol(s)
    return checker.getDeclarationModifierFlagsFromSymbol(s)
end

function Checker:WasCanceled()
    return self.wasCanceled
end

function Checker:GetSignaturesOfType(t, kind)
    return self:getSignaturesOfType(t, kind)
end

function Checker:GetDeclaredTypeOfSymbol(symbol)
    return self:getDeclaredTypeOfSymbol(symbol)
end

function Checker:GetTypeOfSymbol(symbol)
    return self:getTypeOfSymbol(symbol)
end

function Checker:GetConstraintOfTypeParameter(typeParameter)
    return self:getConstraintOfTypeParameter(typeParameter)
end

function Checker:GetTrueTypeOfConditionalType(t)
    return self:getTrueTypeFromConditionalType(t)
end

function Checker:GetFalseTypeOfConditionalType(t)
    return self:getFalseTypeFromConditionalType(t)
end

function Checker:GetDefaultFromTypeParameter(typeParameter)
    return self:getDefaultFromTypeParameter(typeParameter)
end

function Checker:GetResolutionModeOverride(node, reportErrors)
    return self:getResolutionModeOverride(node, reportErrors)
end

function Checker:GetEffectiveDeclarationFlags(n, flagsToCheck)
    return self:getEffectiveDeclarationFlags(n, flagsToCheck)
end

function Checker:GetBaseConstraintOfType(t)
    return self:getBaseConstraintOfType(t)
end

function Checker:GetTypePredicateOfSignature(sig)
    return self:getTypePredicateOfSignature(sig)
end

function checker.IsTupleType(t)
    return checker.isTupleType(t)
end

function Checker:IsArrayType(t)
    return self:isArrayType(t)
end

function Checker:GetReturnTypeOfSignature(sig)
    return self:getReturnTypeOfSignature(sig)
end

function Checker:HasEffectiveRestParameter(signature)
    return self:hasEffectiveRestParameter(signature)
end

function Checker:GetLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
    return self:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(symbol)
end

function Checker:GetContextualTypeForObjectLiteralElement(element, contextFlags)
    return self:getContextualTypeForObjectLiteralElement(element, contextFlags)
end

function Checker:TypePredicateToString(t)
    return self:typePredicateToString(t)
end

function Checker:GetExpandedParameters(signature, skipUnionExpanding)
    return self:getExpandedParameters(signature, skipUnionExpanding)
end

function Checker:GetResolvedSignature(node)
    return self:getResolvedSignature(node, nil, checker.CheckMode.Normal)
end

-- Return the type of the given property in the given type, or nil if no such property exists
function Checker:GetTypeOfPropertyOfType(t, name)
    return self:getTypeOfPropertyOfType(t, name)
end

function Checker:GetContextualTypeForArgumentAtIndex(node, argIndex)
    return self:getContextualTypeForArgumentAtIndex(node, argIndex)
end

function Checker:GetIndexSignaturesAtLocation(node)
    return self:getIndexSignaturesAtLocation(node)
end

function Checker:GetResolvedSymbol(node)
    return self:getResolvedSymbol(node)
end

function Checker:GetJsxNamespace(location)
    return self:getJsxNamespace(location)
end

function Checker:GetJsxFragmentFactory(location)
    local entity = self:getJsxFragmentFactoryEntity(location)
    if entity ~= nil then
        return ast.GetFirstIdentifier(entity):Text()
    end
    return ""
end

function Checker:ResolveName(name, location, meaning, excludeGlobals)
    return self.resolveName(location, name, meaning, nil, true, excludeGlobals)
end

function Checker:GetSymbolFlags(symbol)
    return self:getSymbolFlags(symbol)
end

function Checker:GetBaseTypes(t)
    return self:getBaseTypes(t)
end

function Checker:GetApparentType(t)
    return self:getApparentType(t)
end

-- GetFullyQualifiedName returns the fully qualified name of a symbol, walking up
-- its parent chain (e.g. `"/path/to/module".Namespace.Name`).
function Checker:GetFullyQualifiedName(symbol)
    return self:getFullyQualifiedName(symbol, nil --[[containingLocation]])
end

function Checker:GetBaseConstructorTypeOfClass(t)
    return self:getBaseConstructorTypeOfClass(t)
end

function Checker:GetMemberOverrideModifierStatus(node, member, memberSymbol)
    return self:getMemberOverrideModifierStatus(node, member, memberSymbol)
end

function Checker:GetRestTypeOfSignature(sig)
    return self:getRestTypeOfSignature(sig)
end

function Checker:GetTypeArguments(t)
    return self:getTypeArguments(t)
end

function Checker:GetIndexInfoOfType(t, keyType)
    return self:getIndexInfoOfType(t, keyType)
end

function Checker:GetIndexInfosOfType(t)
    return self:getIndexInfosOfType(t)
end

function Checker:IsContextSensitive(node)
    return self:isContextSensitive(node)
end

function Checker:FillMissingTypeArguments(typeArguments, typeParameters, minTypeArgumentCount, isJavaScriptImplicitAny)
    return self:fillMissingTypeArguments(typeArguments, typeParameters, minTypeArgumentCount, isJavaScriptImplicitAny)
end

function Checker:GetMinTypeArgumentCount(typeParameters)
    return self:getMinTypeArgumentCount(typeParameters)
end

function Checker:GetWidenedLiteralType(t)
    return self:getWidenedLiteralType(t)
end

function Checker:IsTypeAssignableTo(source, target)
    return self:isTypeAssignableTo(source, target)
end

function Checker:GetUnionTypeEx(types, unionReduction)
    return self:getUnionTypeEx(types, unionReduction, nil, nil)
end

function Checker:RequiresAddingImplicitUndefined(node)
    local enclosingDeclaration = ast.FindAncestor(node, ast.IsDeclaration)
    if enclosingDeclaration == nil then
        enclosingDeclaration = ast.GetSourceFileOfNode(node):AsNode()
    end
    local symbol = node:Symbol()
    if symbol == nil then
        return false
    end
    return self:GetEmitResolver():RequiresAddingImplicitUndefined(node, symbol, enclosingDeclaration)
end

function Checker:RemoveMissingOrUndefinedType(t)
    return self:removeMissingOrUndefinedType(t)
end

function Checker:GetWidenedType(t)
    return self:getWidenedType(t)
end

function Checker:CompareSymbols(s1, s2)
    return self.compareSymbols(s1, s2)
end
