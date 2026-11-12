local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local parser = require("tslua.parser")
local scanner = require("tslua.scanner")

local defineStruct = checker.defineStruct
local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local TypeFlags = checker.TypeFlags
local CheckMode = checker.CheckMode
local ContextFlags = checker.ContextFlags
local InferencePriority = checker.InferencePriority
local IterationUse = checker.IterationUse
local IterationTypeKind = checker.IterationTypeKind
local AccessFlags = checker.AccessFlags
local SignatureKind = checker.SignatureKind
local SignatureFlags = checker.SignatureFlags
local JsxFlags = checker.JsxFlags
local JsxReferenceKind = checker.JsxReferenceKind
local JsxEmit = core.JsxEmit

-- JsxFlags and JsxReferenceKind are generated constants (consts_generated.lua).

defineStruct("JsxElementLinks", nil, {
    jsxFlags = 0, -- Flags for the JSX element
    -- resolvedJsxElementAttributesType: Resolved element attributes type of a JSX opening-like element
    -- jsxNamespace: Resolved JSX namespace symbol for this node
    -- jsxImplicitImportContainer: Resolved module symbol the implicit JSX import of this file should refer to
    -- firstJSXTagInFile: The first JSX tag in the file
})

checker.JsxNames = {
    jsx = "JSX",
    intrinsicElements = "IntrinsicElements",
    elementClass = "ElementClass",
    elementAttributesPropertyNameContainer = "ElementAttributesProperty",
    elementChildrenAttributeNameContainer = "ElementChildrenAttribute",
    element = "Element",
    elementType = "ElementType",
    intrinsicAttributes = "IntrinsicAttributes",
    intrinsicClassAttributes = "IntrinsicClassAttributes",
    libraryManagedAttributes = "LibraryManagedAttributes",
}

checker.ReactNames = {
    fragment = "Fragment",
}

local JsxNames = checker.JsxNames
local ReactNames = checker.ReactNames

-- Go slices.Index
local function indexOf(xs, x)
    for i, v in ipairs(xs or {}) do
        if v == x then
            return i - 1
        end
    end
    return -1
end

-- Go pragma.Args[name].Value (zero value "" when the argument is absent)
local function pragmaArgValue(pragma, name)
    local arg = pragma.args ~= nil and pragma.args[name] or nil
    if arg == nil then
        return ""
    end
    return arg.value
end

function Checker:checkJsxElement(node, checkMode)
    self:checkNodeDeferred(node)
    return self:getJsxElementTypeAt(node)
end

function Checker:checkJsxElementDeferred(node)
    local jsxElement = node:AsJsxElement()
    self:checkJsxOpeningLikeElementOrOpeningFragment(jsxElement.openingElement)
    -- Perform resolution on the closing tag so that rename/go to definition/etc work
    if checker.isJsxIntrinsicTagName(jsxElement.closingElement:TagName()) then
        self:getIntrinsicTagSymbol(jsxElement.closingElement)
    else
        self:checkExpression(jsxElement.closingElement:TagName())
    end
    self:checkJsxChildren(node, CheckMode.Normal)
end

function Checker:checkJsxExpression(node, checkMode)
    self:checkGrammarJsxExpression(node:AsJsxExpression())
    if node:Expression() == nil then
        return self.errorType
    end
    local t = self:checkExpressionEx(node:Expression(), checkMode)
    if node:AsJsxExpression().dotDotDotToken ~= nil and t ~= self.anyType and not self:isArrayType(t) then
        self:error(node, diagnostics.JSX_spread_child_must_be_an_array_type)
    end
    return t
end

function Checker:checkJsxSelfClosingElement(node, checkMode)
    self:checkNodeDeferred(node)
    return self:getJsxElementTypeAt(node)
end

function Checker:checkJsxSelfClosingElementDeferred(node)
    self:checkJsxOpeningLikeElementOrOpeningFragment(node)
end

function Checker:checkJsxFragment(node)
    local c = self
    c:checkJsxOpeningLikeElementOrOpeningFragment(node:AsJsxFragment().openingFragment)
    -- by default, jsx:'react' will use jsxFactory = React.createElement and jsxFragmentFactory = React.Fragment
    -- if jsxFactory compiler option is provided, ensure jsxFragmentFactory compiler option or @jsxFrag pragma is provided too
    local nodeSourceFile = ast.GetSourceFileOfNode(node)
    if c.compilerOptions:GetJSXTransformEnabled() and (c.compilerOptions.jsxFactory ~= "" or ast.GetPragmaFromSourceFile(nodeSourceFile, "jsx") ~= nil) and c.compilerOptions.jsxFragmentFactory == "" and ast.GetPragmaFromSourceFile(nodeSourceFile, "jsxfrag") == nil then
        local message = core.IfElse(c.compilerOptions.jsxFactory ~= "",
            diagnostics.The_jsxFragmentFactory_compiler_option_must_be_provided_to_use_JSX_fragments_with_the_jsxFactory_compiler_option,
            diagnostics.An_jsxFrag_pragma_is_required_when_using_an_jsx_pragma_with_JSX_fragments)
        c:error(node, message)
    end
    c:checkJsxChildren(node, CheckMode.Normal)
    local t = c:getJsxElementTypeAt(node)
    return core.IfElse(c:isErrorType(t), c.anyType, t)
end

function Checker:checkJsxAttributes(node, checkMode)
    self:checkNodeDeferred(node)
    return self:createJsxAttributesTypeFromAttributesProperty(node.parent, checkMode)
end

function Checker:checkJsxOpeningLikeElementOrOpeningFragment(node)
    local c = self
    local isNodeOpeningLikeElement = ast.IsJsxOpeningLikeElement(node)
    if isNodeOpeningLikeElement then
        c:checkGrammarJsxElement(node)
    end
    c:checkJsxPreconditions(node)
    c:markJsxAliasReferenced(node)
    local sig = c:getResolvedSignature(node, nil, CheckMode.Normal)
    c:checkDeprecatedSignature(sig, node)
    if isNodeOpeningLikeElement then
        local elementTypeConstraint = c:getJsxElementTypeTypeAt(node)
        if elementTypeConstraint ~= nil then
            local tagName = node:TagName()
            local tagType
            if checker.isJsxIntrinsicTagName(tagName) then
                tagType = c:getStringLiteralType(tagName:Text())
            else
                tagType = c:checkExpression(tagName)
            end
            local diags = {}
            if not c:checkTypeRelatedToEx(tagType, elementTypeConstraint, c.assignableRelation, tagName, diagnostics.Its_type_0_is_not_a_valid_JSX_element_type, diags) then
                c:addDiagnostic(ast.NewDiagnosticChain(diags[1], diagnostics.X_0_cannot_be_used_as_a_JSX_component, scanner.GetTextOfNode(tagName)))
            end
        else
            c:checkJsxReturnAssignableToAppropriateBound(c:getJsxReferenceKind(node), c:getReturnTypeOfSignature(sig), node)
        end
    end
end

function Checker:checkJsxPreconditions(errorNode)
    -- Preconditions for using JSX
    if self.compilerOptions.jsx == JsxEmit.None then
        self:error(errorNode, diagnostics.Cannot_use_JSX_unless_the_jsx_flag_is_provided)
    end
    if self.noImplicitAny and self:getJsxElementTypeAt(errorNode) == nil then
        self:error(errorNode, diagnostics.JSX_element_implicitly_has_type_any_because_the_global_type_JSX_Element_does_not_exist)
    end
end

function Checker:checkJsxReturnAssignableToAppropriateBound(refKind, elemInstanceType, openingLikeElement)
    local c = self
    local diags = {}
    if refKind == JsxReferenceKind.Function then
        local sfcReturnConstraint = c:getJsxStatelessElementTypeAt(openingLikeElement)
        if sfcReturnConstraint ~= nil then
            c:checkTypeRelatedToEx(elemInstanceType, sfcReturnConstraint, c.assignableRelation, openingLikeElement:TagName(), diagnostics.Its_return_type_0_is_not_a_valid_JSX_element, diags)
        end
    elseif refKind == JsxReferenceKind.Component then
        local classConstraint = c:getJsxElementClassTypeAt(openingLikeElement)
        if classConstraint ~= nil then
            -- Issue an error if this return type isn't assignable to JSX.ElementClass, failing that
            c:checkTypeRelatedToEx(elemInstanceType, classConstraint, c.assignableRelation, openingLikeElement:TagName(), diagnostics.Its_instance_type_0_is_not_a_valid_JSX_element, diags)
        end
    else
        local sfcReturnConstraint = c:getJsxStatelessElementTypeAt(openingLikeElement)
        local classConstraint = c:getJsxElementClassTypeAt(openingLikeElement)
        if sfcReturnConstraint == nil or classConstraint == nil then
            return
        end
        local combined = c:getUnionType({ sfcReturnConstraint, classConstraint })
        c:checkTypeRelatedToEx(elemInstanceType, combined, c.assignableRelation, openingLikeElement:TagName(), diagnostics.Its_element_type_0_is_not_a_valid_JSX_element, diags)
    end
    if #diags ~= 0 then
        c:addDiagnostic(ast.NewDiagnosticChain(diags[1], diagnostics.X_0_cannot_be_used_as_a_JSX_component, scanner.GetTextOfNode(openingLikeElement:TagName())))
    end
end

function Checker:inferJsxTypeArguments(node, signature, checkMode, context)
    local paramType = self:getEffectiveFirstArgumentForJsxSignature(signature, node)
    local checkAttrType = self:checkExpressionWithContextualType(node:Attributes(), paramType, context, checkMode)
    self:inferTypes(context.inferences, checkAttrType, paramType, InferencePriority.None, false)
    return self:getInferredTypes(context)
end

function Checker:getContextualTypeForJsxExpression(node, contextFlags)
    if ast.IsJsxAttributeLike(node.parent) then
        return self:getContextualType(node, contextFlags)
    elseif ast.IsJsxElement(node.parent) then
        return self:getContextualTypeForChildJsxExpression(node.parent, node, contextFlags)
    end
    return nil
end

function Checker:getContextualTypeForJsxAttribute(attribute, contextFlags)
    -- When we trying to resolve JsxOpeningLikeElement as a stateless function element, we will already give its attributes a contextual type
    -- which is a type of the parameter of the signature we are trying out.
    -- If there is no contextual type (e.g. we are trying to resolve stateful component), get attributes type from resolving element's tagName
    if ast.IsJsxAttribute(attribute) then
        local attributesType = self:getApparentTypeOfContextualType(attribute.parent, contextFlags)
        if attributesType == nil or checker.IsTypeAny(attributesType) then
            return nil
        end
        return self:getTypeOfPropertyOfContextualType(attributesType, attribute:Name():Text())
    end
    return self:getContextualType(attribute.parent, contextFlags)
end

function Checker:getContextualJsxElementAttributesType(node, contextFlags)
    if ast.IsJsxOpeningElement(node) and contextFlags ~= ContextFlags.IgnoreNodeInferences then
        local index = self:findContextualNode(node.parent, contextFlags == ContextFlags.None)
        if index >= 0 then
            -- Contextually applied type is moved from attributes up to the outer jsx attributes so when walking up from the children they get hit
            -- _However_ to hit them from the _attributes_ we must look for them here; otherwise we'll used the declared type
            -- (as below) instead!
            return self.contextualInfos[index + 1].t
        end
    end
    return self:getContextualTypeForArgumentAtIndex(node, 0)
end

function Checker:getContextualTypeForChildJsxExpression(node, child, contextFlags)
    local c = self
    local attributesType = c:getApparentTypeOfContextualType(node:AsJsxElement().openingElement:Attributes(), contextFlags)
    -- JSX expression is in children of JSX Element, we will look for an "children" attribute (we get the name from JSX.ElementAttributesProperty)
    local jsxChildrenPropertyName = c:getJsxElementChildrenPropertyName(c:getJsxNamespaceAt(node))
    if not (attributesType ~= nil and not checker.IsTypeAny(attributesType) and jsxChildrenPropertyName ~= ast.InternalSymbolNameMissing and jsxChildrenPropertyName ~= "") then
        return nil
    end
    local realChildren = ast.GetSemanticJsxChildren(node:Children().nodes)
    local childIndex = indexOf(realChildren, child)
    local childFieldType = c:getTypeOfPropertyOfContextualType(attributesType, jsxChildrenPropertyName)
    if childFieldType == nil then
        return nil
    end
    if core.Len(realChildren) == 1 then
        return childFieldType
    end
    return c:mapTypeEx(childFieldType, function(t)
        if c:isArrayLikeType(t) then
            return c:getIndexedAccessType(t, c:getNumberLiteralType(childIndex + 0.0))
        end
        return t
    end, true --[[noReductions]])
end

function Checker:discriminateContextualTypeByJSXAttributes(node, contextualType)
    local c = self
    local key = checker.DiscriminatedContextualTypeKey(ast.GetNodeId(node), contextualType.id)
    local discriminated = c.discriminatedContextualTypes[key]
    if discriminated ~= nil then
        return discriminated
    end
    local jsxChildrenPropertyName = c:getJsxElementChildrenPropertyName(c:getJsxNamespaceAt(node))
    local discriminantProperties = core.Filter(node:Properties(), function(p)
        local symbol = p:Symbol()
        if symbol == nil or not ast.IsJsxAttribute(p) then
            return false
        end
        local initializer = p:Initializer()
        return (initializer == nil or c:isPossiblyDiscriminantValue(initializer)) and c:isDiscriminantProperty(contextualType, symbol.name)
    end)
    local discriminantMembers = core.Filter(c:getPropertiesOfType(contextualType), function(s)
        if s.flags & SymbolFlags.Optional == 0 or node:Symbol() == nil then
            return false
        end
        local element = node.parent.parent
        if s.name == jsxChildrenPropertyName and ast.IsJsxElement(element) and core.Len(ast.GetSemanticJsxChildren(element:Children().nodes)) ~= 0 then
            return false
        end
        local members = node:Symbol().members
        return (members == nil or members[s.name] == nil) and c:isDiscriminantProperty(contextualType, s.name)
    end)
    local discriminator = checker.ObjectLiteralDiscriminator_new({ c = c, props = discriminantProperties, members = discriminantMembers })
    discriminated = c:discriminateTypeByDiscriminableItems(contextualType, discriminator)
    c.discriminatedContextualTypes[key] = discriminated
    return discriminated
end

function Checker:elaborateJsxComponents(node, source, target, relation, diagnosticOutput)
    local c = self
    local reportedError = false
    for _, prop in ipairs(node:Properties() or {}) do
        if not ast.IsJsxSpreadAttribute(prop) and not checker.isHyphenatedJsxName(prop:Name():Text()) then
            local nameType = c:getStringLiteralType(prop:Name():Text())
            if nameType ~= nil and nameType.flags & TypeFlags.Never == 0 then
                reportedError = c:elaborateElement(source, target, relation, prop:Name(), prop:Initializer(), nameType, nil, nil, diagnosticOutput) or reportedError
            end
        end
    end
    if ast.IsJsxOpeningElement(node.parent) and ast.IsJsxElement(node.parent.parent) then
        local containingElement = node.parent.parent -- Containing JSXElement
        local childrenPropName = c:getJsxElementChildrenPropertyName(c:getJsxNamespaceAt(node))
        if childrenPropName == ast.InternalSymbolNameMissing then
            childrenPropName = "children"
        end
        local childrenNameType = c:getStringLiteralType(childrenPropName)
        local childrenTargetType = c:getIndexedAccessType(target, childrenNameType)
        local validChildren = ast.GetSemanticJsxChildren(containingElement:Children().nodes)
        if core.Len(validChildren) == 0 then
            return reportedError
        end
        local moreThanOneRealChildren = #validChildren > 1
        local arrayLikeTargetParts
        local nonArrayLikeTargetParts
        local iterableType = c.getGlobalIterableType()
        if iterableType ~= c.emptyGenericType then
            local anyIterable = c:createIterableType(c.anyType)
            arrayLikeTargetParts = c:filterType(childrenTargetType, function(t) return c:isTypeAssignableTo(t, anyIterable) end)
            nonArrayLikeTargetParts = c:filterType(childrenTargetType, function(t) return not c:isTypeAssignableTo(t, anyIterable) end)
        else
            arrayLikeTargetParts = c:filterType(childrenTargetType, function(t) return c:isArrayOrTupleLikeType(t) end)
            nonArrayLikeTargetParts = c:filterType(childrenTargetType, function(t) return not c:isArrayOrTupleLikeType(t) end)
        end
        local invalidTextDiagnostic
        local invalidTextDiagnosticArgs
        local getInvalidTextualChildDiagnostic = function()
            if invalidTextDiagnostic == nil then
                local tagNameText = scanner.GetTextOfNode(node.parent:TagName())
                invalidTextDiagnostic = diagnostics.X_0_components_don_t_accept_text_as_child_elements_Text_in_JSX_has_the_type_string_but_the_expected_type_of_1_is_2
                invalidTextDiagnosticArgs = { tagNameText, childrenPropName, c:TypeToString(childrenTargetType) }
            end
            return invalidTextDiagnostic, invalidTextDiagnosticArgs
        end
        if moreThanOneRealChildren then
            if arrayLikeTargetParts ~= c.neverType then
                local realSource = c:createTupleType(c:checkJsxChildren(containingElement, CheckMode.Normal))
                local children = c:generateJsxChildren(containingElement, getInvalidTextualChildDiagnostic)
                reportedError = c:elaborateIterableOrArrayLikeTargetElementwise(children, realSource, arrayLikeTargetParts, relation, diagnosticOutput) or reportedError
            elseif not c:isTypeRelatedTo(c:getIndexedAccessType(source, childrenNameType), childrenTargetType, relation) then
                -- arity mismatch
                local diag = c:error(containingElement:AsJsxElement().openingElement:TagName(), diagnostics.This_JSX_tag_s_0_prop_expects_a_single_child_of_type_1_but_multiple_children_were_provided, childrenPropName, c:TypeToString(childrenTargetType))
                c:reportDiagnostic(diag, diagnosticOutput)
                reportedError = true
            end
        else
            if nonArrayLikeTargetParts ~= c.neverType then
                local child = validChildren[1]
                local e = c:getElaborationElementForJsxChild(child, childrenNameType, getInvalidTextualChildDiagnostic)
                if e.errorNode ~= nil then
                    reportedError = c:elaborateElement(source, target, relation, e.errorNode, e.innerExpression, e.nameType, nil, e.createDiagnostic, diagnosticOutput) or reportedError
                end
            elseif not c:isTypeRelatedTo(c:getIndexedAccessType(source, childrenNameType), childrenTargetType, relation) then
                -- arity mismatch
                local diag = c:error(containingElement:AsJsxElement().openingElement:TagName(), diagnostics.This_JSX_tag_s_0_prop_expects_type_1_which_requires_multiple_children_but_only_a_single_child_was_provided, childrenPropName, c:TypeToString(childrenTargetType))
                c:reportDiagnostic(diag, diagnosticOutput)
                reportedError = true
            end
        end
    end
    return reportedError
end

-- JsxElaborationElement: { errorNode, innerExpression, nameType, createDiagnostic }
-- createDiagnostic: Optional: creates a custom diagnostic for this element (func(prop) -> diagnostic)
defineStruct("JsxElaborationElement", nil, nil)

-- generateJsxChildren returns a lazy Lua iterator over JsxElaborationElement values (Go iter.Seq).
-- getInvalidTextDiagnostic returns (message, argsArray).
function Checker:generateJsxChildren(node, getInvalidTextDiagnostic)
    local c = self
    local children = node:Children().nodes or {}
    local memberOffset = 0
    local i = 0
    return function()
        while i < #children do
            local child = children[i + 1]
            local nameType = c:getNumberLiteralType((i - memberOffset) + 0.0)
            i = i + 1
            local e = c:getElaborationElementForJsxChild(child, nameType, getInvalidTextDiagnostic)
            if e.errorNode ~= nil then
                return e
            else
                memberOffset = memberOffset + 1
            end
        end
        return nil
    end
end

function Checker:getElaborationElementForJsxChild(child, nameType, getInvalidTextDiagnostic)
    local k = child.kind
    if k == Kind.JsxExpression then
        -- child is of the type of the expression
        return checker.JsxElaborationElement_new({ errorNode = child, innerExpression = child:Expression(), nameType = nameType })
    elseif k == Kind.JsxText then
        if child:AsJsxText().containsOnlyTriviaWhiteSpaces then
            -- Whitespace only jsx text isn't real jsx text
            return checker.JsxElaborationElement_new()
        end
        -- child is a string
        return checker.JsxElaborationElement_new({
            errorNode = child,
            innerExpression = nil,
            nameType = nameType,
            createDiagnostic = function(prop)
                local errorMessage, errorArgs = getInvalidTextDiagnostic()
                return checker.NewDiagnosticForNode(prop, errorMessage, table.unpack(errorArgs, 1, #errorArgs))
            end,
        })
    elseif k == Kind.JsxElement or k == Kind.JsxSelfClosingElement or k == Kind.JsxFragment then
        -- child is of type JSX.Element
        return checker.JsxElaborationElement_new({ errorNode = child, innerExpression = child, nameType = nameType })
    end
    error("Unhandled case in getElaborationElementForJsxChild", 0)
end

-- iterator is a Lua iterator function returning JsxElaborationElement values (Go iter.Seq).
function Checker:elaborateIterableOrArrayLikeTargetElementwise(iterator, source, target, relation, diagnosticOutput)
    local c = self
    local tupleOrArrayLikeTargetParts = c:filterType(target, function(t) return c:isArrayOrTupleLikeType(t) end)
    local nonTupleOrArrayLikeTargetParts = c:filterType(target, function(t) return not c:isArrayOrTupleLikeType(t) end)
    -- If `nonTupleOrArrayLikeTargetParts` is not `never`, then that should mean `Iterable` is defined.
    local iterationType
    if nonTupleOrArrayLikeTargetParts ~= c.neverType then
        iterationType = c:getIterationTypeOfIterable(IterationUse.ForOf, IterationTypeKind.Yield, nonTupleOrArrayLikeTargetParts, nil --[[errorNode]])
    end
    local reportedError = false
    for e in iterator do
        local prop = e.errorNode
        local next = e.innerExpression
        local nameType = e.nameType
        local targetPropType = iterationType
        local targetIndexedPropType
        if tupleOrArrayLikeTargetParts ~= c.neverType then
            targetIndexedPropType = c:getBestMatchIndexedAccessTypeOrUndefined(source, tupleOrArrayLikeTargetParts, nameType)
        end
        if targetIndexedPropType ~= nil and targetIndexedPropType.flags & TypeFlags.IndexedAccess == 0 then
            if iterationType ~= nil then
                targetPropType = c:getUnionType({ iterationType, targetIndexedPropType })
            else
                targetPropType = targetIndexedPropType
            end
        end
        if targetPropType == nil then
            goto continue
        end
        do
            local sourcePropType = c:getIndexedAccessTypeOrUndefined(source, nameType, AccessFlags.None, nil, nil)
            if sourcePropType == nil then
                goto continue
            end
            local propName = c:getPropertyNameFromIndex(nameType, nil --[[accessNode]])
            if not c:checkTypeRelatedTo(sourcePropType, targetPropType, relation, nil --[[errorNode]]) then
                local elaborated = next ~= nil and c:elaborateError(next, sourcePropType, targetPropType, relation, nil --[[headMessage]], diagnosticOutput)
                reportedError = true
                if not elaborated then
                    -- Issue error on the prop itself, since the prop couldn't elaborate the error. Use the expression type, if available.
                    local specificSource = sourcePropType
                    if next ~= nil then
                        specificSource = c:checkExpressionForMutableLocationWithContextualType(next, sourcePropType)
                    end
                    if e.createDiagnostic ~= nil then
                        -- Use the custom diagnostic factory if provided (e.g., for JSX text children with dynamic error messages)
                        c:reportDiagnostic(e.createDiagnostic(prop), diagnosticOutput)
                    elseif c.exactOptionalPropertyTypes and c:isExactOptionalPropertyMismatch(specificSource, targetPropType) then
                        local diag = checker.createDiagnosticForNode(prop, diagnostics.Type_0_is_not_assignable_to_type_1_with_exactOptionalPropertyTypes_Colon_true_Consider_adding_undefined_to_the_type_of_the_target, c:TypeToString(specificSource), c:TypeToString(targetPropType))
                        c:reportDiagnostic(diag, diagnosticOutput)
                    else
                        local targetIsOptional = propName ~= ast.InternalSymbolNameMissing and core.OrElse(c:getPropertyOfType(tupleOrArrayLikeTargetParts, propName), c.unknownSymbol).flags & SymbolFlags.Optional ~= 0
                        local sourceIsOptional = propName ~= ast.InternalSymbolNameMissing and core.OrElse(c:getPropertyOfType(source, propName), c.unknownSymbol).flags & SymbolFlags.Optional ~= 0
                        targetPropType = c:removeMissingType(targetPropType, targetIsOptional)
                        sourcePropType = c:removeMissingType(sourcePropType, targetIsOptional and sourceIsOptional)
                        local result = c:checkTypeRelatedToEx(specificSource, targetPropType, relation, prop, nil, diagnosticOutput)
                        if result and specificSource ~= sourcePropType then
                            -- If for whatever reason the expression type doesn't yield an error, make sure we still issue an error on the sourcePropType
                            c:checkTypeRelatedToEx(sourcePropType, targetPropType, relation, prop, nil, diagnosticOutput)
                        end
                    end
                end
            end
        end
        ::continue::
    end
    return reportedError
end

function Checker:getSuggestedSymbolForNonexistentJSXAttribute(name, containingType)
    local properties = self:getPropertiesOfType(containingType)
    local jsxSpecific
    if name == "for" then
        jsxSpecific = core.Find(properties, function(x) return ast.SymbolName(x) == "htmlFor" end)
    elseif name == "class" then
        jsxSpecific = core.Find(properties, function(x) return ast.SymbolName(x) == "className" end)
    end
    if jsxSpecific ~= nil then
        return jsxSpecific
    end
    return self:getSpellingSuggestionForName(name, properties or {}, SymbolFlags.Value)
end

function Checker:getJSXFragmentType(node)
    local c = self
    -- An opening fragment is required in order for `getJsxNamespace` to give the fragment factory
    local links = c.sourceFileLinks:Get(ast.GetSourceFileOfNode(node))
    if links.jsxFragmentType ~= nil then
        return links.jsxFragmentType
    end
    local jsxFragmentFactoryName = c:getJsxNamespace(node)
    -- #38720/60122, allow null as jsxFragmentFactory
    local shouldResolveFactoryReference = (c.compilerOptions.jsx == JsxEmit.React or c.compilerOptions.jsxFragmentFactory ~= "") and jsxFragmentFactoryName ~= "null"
    if not shouldResolveFactoryReference then
        links.jsxFragmentType = c.anyType
        return links.jsxFragmentType
    end
    local jsxFactorySymbol = c:getJsxNamespaceContainerForImplicitImport(node)
    if jsxFactorySymbol == nil then
        local shouldModuleRefErr = c.compilerOptions.jsx ~= JsxEmit.Preserve and c.compilerOptions.jsx ~= JsxEmit.ReactNative
        local flags = SymbolFlags.Value
        if not shouldModuleRefErr then
            flags = flags & ~SymbolFlags.Enum
        end
        jsxFactorySymbol = c.resolveName(node, jsxFragmentFactoryName, flags, diagnostics.Using_JSX_fragments_requires_fragment_factory_0_to_be_in_scope_but_it_could_not_be_found, true --[[isUse]], false --[[excludeGlobals]])
    end
    if jsxFactorySymbol == nil then
        links.jsxFragmentType = c.errorType
        return links.jsxFragmentType
    end
    if jsxFactorySymbol.name == ReactNames.fragment then
        links.jsxFragmentType = c:getTypeOfSymbol(jsxFactorySymbol)
        return links.jsxFragmentType
    end
    local resolvedAlias = jsxFactorySymbol
    if jsxFactorySymbol.flags & SymbolFlags.Alias ~= 0 then
        resolvedAlias = c:resolveAlias(jsxFactorySymbol)
    end

    local reactExports = c:getExportsOfSymbol(resolvedAlias)
    local typeSymbol = c:getSymbol(reactExports, ReactNames.fragment, SymbolFlags.BlockScopedVariable)
    if typeSymbol ~= nil then
        links.jsxFragmentType = c:getTypeOfSymbol(typeSymbol)
    else
        links.jsxFragmentType = c.errorType
    end
    return links.jsxFragmentType
end

function Checker:resolveJsxOpeningLikeElement(node, candidatesOutArray, checkMode)
    local c = self
    local isJsxOpenFragment = ast.IsJsxOpeningFragment(node)
    local exprTypes
    if not isJsxOpenFragment then
        if checker.isJsxIntrinsicTagName(node:TagName()) then
            local result = c:getIntrinsicAttributesTypeFromJsxOpeningLikeElement(node)
            local fakeSignature = c:createSignatureForJSXIntrinsic(node, result)
            c:checkTypeAssignableToAndOptionallyElaborate(c:checkExpressionWithContextualType(node:Attributes(), c:getEffectiveFirstArgumentForJsxSignature(fakeSignature, node), nil --[[inferenceContext]], CheckMode.Normal), result, node:TagName(), node:Attributes(), nil, nil)
            local typeArguments = node:TypeArguments()
            if core.Len(typeArguments) ~= 0 then
                c:checkSourceElements(typeArguments)
                local sourceFile = ast.GetSourceFileOfNode(node)
                local typeArgumentList = node:TypeArgumentList()
                local loc = core.NewTextRange(scanner.SkipTrivia(sourceFile:Text(), typeArgumentList.loc:Pos()), typeArgumentList.loc:End())
                c:addDiagnostic(ast.NewDiagnostic(sourceFile, loc, diagnostics.Expected_0_type_arguments_but_got_1, 0, #typeArguments))
            end
            return fakeSignature
        end
        exprTypes = c:checkExpression(node:TagName())
    else
        exprTypes = c:getJSXFragmentType(node)
    end
    local apparentType = c:getApparentType(exprTypes)
    if c:isErrorType(apparentType) then
        return c:resolveErrorCall(node)
    end
    local signatures = c:getUninstantiatedJsxSignaturesOfType(exprTypes, node)
    if c:isUntypedFunctionCall(exprTypes, apparentType, core.Len(signatures), 0 --[[constructSignatures]]) then
        return c:resolveUntypedCall(node)
    end
    if core.Len(signatures) == 0 then
        -- We found no signatures at all, which is an error
        if isJsxOpenFragment then
            c:error(node, diagnostics.JSX_element_type_0_does_not_have_any_construct_or_call_signatures, scanner.GetTextOfNode(node))
        else
            c:error(node:TagName(), diagnostics.JSX_element_type_0_does_not_have_any_construct_or_call_signatures, scanner.GetTextOfNode(node:TagName()))
        end
        return c:resolveErrorCall(node)
    end
    return c:resolveCall(node, signatures, candidatesOutArray, checkMode, SignatureFlags.None, nil)
end

-- Check if the given signature can possibly be a signature called by the JSX opening-like element.
-- @param node a JSX opening-like element we are trying to figure its call signature
-- @param signature a candidate signature we are trying whether it is a call signature
-- @param relation a relationship to check parameter and argument type
function Checker:checkApplicableSignatureForJsxCallLikeElement(node, signature, relation, checkMode, reportErrors, diagnosticOutput)
    local c = self
    -- Stateless function components can have maximum of three arguments: "props", "context", and "updater".
    -- However "context" and "updater" are implicit and can't be specify by users. Only the first parameter, props,
    -- can be specified by users through attributes property.
    local paramType = c:getEffectiveFirstArgumentForJsxSignature(signature, node)
    local attributesType
    if ast.IsJsxOpeningFragment(node) then
        attributesType = c:createJsxAttributesTypeFromAttributesProperty(node, CheckMode.Normal)
    else
        attributesType = c:checkExpressionWithContextualType(node:Attributes(), paramType, nil --[[inferenceContext]], checkMode)
    end
    local checkAttributesType
    local checkTagNameDoesNotExpectTooManyArguments = function()
        if c:getJsxNamespaceContainerForImplicitImport(node) ~= nil then
            return true -- factory is implicitly jsx/jsxdev - assume it fits the bill, since we don't strongly look for the jsx/jsxs/jsxDEV factory APIs anywhere else (at least not yet)
        end
        -- We assume fragments have the correct arity since the node does not have attributes
        local tagType
        if (ast.IsJsxOpeningElement(node) or ast.IsJsxSelfClosingElement(node)) and not (checker.isJsxIntrinsicTagName(node:TagName()) or ast.IsJsxNamespacedName(node:TagName())) then
            tagType = c:checkExpression(node:TagName())
        end
        if tagType == nil then
            return true
        end
        local tagCallSignatures = c:getSignaturesOfType(tagType, SignatureKind.Call)
        if core.Len(tagCallSignatures) == 0 then
            return true
        end
        local factory = c:getJsxFactoryEntity(node)
        if factory == nil then
            return true
        end
        local factorySymbol = c:resolveEntityName(factory, SymbolFlags.Value, true --[[ignoreErrors]], false --[[dontResolveAlias]], node)
        if factorySymbol == nil then
            return true
        end

        local factoryType = c:getTypeOfSymbol(factorySymbol)
        local callSignatures = c:getSignaturesOfType(factoryType, SignatureKind.Call)
        if core.Len(callSignatures) == 0 then
            return true
        end
        local hasFirstParamSignatures = false
        local maxParamCount = 0
        -- Check that _some_ first parameter expects a FC-like thing, and that some overload of the SFC expects an acceptable number of arguments
        for _, sig in ipairs(callSignatures) do
            local firstparam = c:getTypeAtPosition(sig, 0)
            local signaturesOfParam = c:getSignaturesOfType(firstparam, SignatureKind.Call)
            for _, paramSig in ipairs(signaturesOfParam or {}) do
                hasFirstParamSignatures = true
                if c:hasEffectiveRestParameter(paramSig) then
                    return true -- some signature has a rest param, so function components can have an arbitrary number of arguments
                end
                local paramCount = c:getParameterCount(paramSig)
                if paramCount > maxParamCount then
                    maxParamCount = paramCount
                end
            end
        end
        if not hasFirstParamSignatures then
            -- Not a single signature had a first parameter which expected a signature - for back compat, and
            -- to guard against generic factories which won't have signatures directly, do not error
            return true
        end
        local absoluteMinArgCount = math.maxinteger
        for _, tagSig in ipairs(tagCallSignatures) do
            local tagRequiredArgCount = c:getMinArgumentCount(tagSig)
            if tagRequiredArgCount < absoluteMinArgCount then
                absoluteMinArgCount = tagRequiredArgCount
            end
        end
        if absoluteMinArgCount <= maxParamCount then
            return true -- some signature accepts the number of arguments the function component provides
        end
        if reportErrors then
            local tagName = node:TagName()
            -- We will not report errors in this function for fragments, since we do not check them in this function
            local diag = checker.NewDiagnosticForNode(tagName, diagnostics.Tag_0_expects_at_least_1_arguments_but_the_JSX_factory_2_provides_at_most_3, checker.entityNameToString(tagName), absoluteMinArgCount, checker.entityNameToString(factory), maxParamCount)
            local tagNameSymbol = c:getSymbolAtLocation(tagName, false)
            if tagNameSymbol ~= nil and tagNameSymbol.valueDeclaration ~= nil then
                diag:AddRelatedInfo(checker.NewDiagnosticForNode(tagNameSymbol.valueDeclaration, diagnostics.X_0_is_declared_here, checker.entityNameToString(tagName)))
            end
            c:reportDiagnostic(diag, diagnosticOutput)
        end
        return false
    end
    if checkMode & CheckMode.SkipContextSensitive ~= 0 then
        checkAttributesType = c:getRegularTypeOfObjectLiteral(attributesType)
    else
        checkAttributesType = attributesType
    end
    if not checkTagNameDoesNotExpectTooManyArguments() then
        return false
    end
    local errorNode
    if reportErrors then
        if ast.IsJsxOpeningFragment(node) then
            errorNode = node
        else
            errorNode = node:TagName()
        end
    end
    local attributes
    if not ast.IsJsxOpeningFragment(node) then
        attributes = node:Attributes()
    end
    return c:checkTypeRelatedToAndOptionallyElaborate(checkAttributesType, paramType, relation, errorNode, attributes, nil, diagnosticOutput)
end

-- Get attributes type of the JSX opening-like element. The result is from resolving "attributes" property of the opening-like element.
--
-- @param openingLikeElement a JSX opening-like element
-- @param filter a function to remove attributes that will not participate in checking whether attributes are assignable
-- @return an anonymous type (similar to the one returned by checkObjectLiteral) in which its properties are attributes property.
-- @remarks Because this function calls getSpreadType, it needs to use the same checks as checkObjectLiteral,
-- which also calls getSpreadType.
function Checker:createJsxAttributesTypeFromAttributesProperty(openingLikeElement, checkMode)
    local c = self
    local allAttributesTable
    if c.strictNullChecks then
        allAttributesTable = ast.NewSymbolTable()
    end
    local attributesTable = ast.NewSymbolTable()
    local attributesSymbol
    local attributeParent = openingLikeElement
    local spread = c.emptyJsxObjectType
    local hasSpreadAnyType = false
    local typeToIntersect
    local explicitlySpecifyChildrenAttribute = false
    local objectFlags = checker.ObjectFlags.JsxAttributes
    local createJsxAttributesType = function()
        objectFlags = objectFlags | checker.ObjectFlags.FreshLiteral
        local result = c:newAnonymousType(attributesSymbol, attributesTable, nil, nil, nil)
        result.objectFlags = result.objectFlags | objectFlags | checker.ObjectFlags.ObjectLiteral | checker.ObjectFlags.ContainsObjectOrArrayLiteral
        return result
    end
    local jsxChildrenPropertyName = c:getJsxElementChildrenPropertyName(c:getJsxNamespaceAt(openingLikeElement))
    local isJsxOpenFragment = ast.IsJsxOpeningFragment(openingLikeElement)
    if not isJsxOpenFragment then
        local attributes = openingLikeElement:Attributes()
        attributesSymbol = attributes:Symbol()
        attributeParent = attributes
        local contextualType = c:getContextualType(attributes, ContextFlags.None)
        -- Create anonymous type from given attributes symbol table.
        -- @param symbol a symbol of JsxAttributes containing attributes corresponding to attributesTable
        -- @param attributesTable a symbol table of attributes property
        for _, attributeDecl in ipairs(attributes:Properties() or {}) do
            local member = attributeDecl:Symbol()
            if ast.IsJsxAttribute(attributeDecl) then
                local exprType = c:checkJsxAttribute(attributeDecl, checkMode)
                objectFlags = objectFlags | (exprType.objectFlags & checker.ObjectFlags.PropagatingFlags)
                local attributeSymbol = c:newSymbol(SymbolFlags.Property | member.flags, member.name)
                attributeSymbol.declarations = member.declarations
                attributeSymbol.parent = member.parent
                if member.valueDeclaration ~= nil then
                    attributeSymbol.valueDeclaration = member.valueDeclaration
                end
                local links = c.valueSymbolLinks:Get(attributeSymbol)
                links.resolvedType = exprType
                links.target = member
                attributesTable[attributeSymbol.name] = attributeSymbol
                if allAttributesTable ~= nil then
                    allAttributesTable[attributeSymbol.name] = attributeSymbol
                end
                if attributeDecl:Name():Text() == jsxChildrenPropertyName then
                    explicitlySpecifyChildrenAttribute = true
                end
                if contextualType ~= nil and checkMode & CheckMode.Inferential ~= 0 and checkMode & CheckMode.SkipContextSensitive == 0 and c:isContextSensitive(attributeDecl) then
                    local inferenceContext = c:getInferenceContext(attributes)
                    debug.Assert(inferenceContext ~= nil)
                    -- In CheckMode.Inferential we should always have an inference context
                    local inferenceNode = attributeDecl:Initializer():Expression()
                    c:addIntraExpressionInferenceSite(inferenceContext, inferenceNode, exprType)
                end
            else
                debug.Assert(attributeDecl.kind == Kind.JsxSpreadAttribute)
                if next(attributesTable) ~= nil then
                    spread = c:getSpreadType(spread, createJsxAttributesType(), attributesSymbol, objectFlags, false --[[readonly]])
                    attributesTable = ast.NewSymbolTable()
                end
                local exprType = c:getReducedType(c:checkExpressionEx(attributeDecl:Expression(), checkMode & CheckMode.Inferential))
                if checker.IsTypeAny(exprType) then
                    hasSpreadAnyType = true
                end
                if c:isValidSpreadType(exprType) then
                    spread = c:getSpreadType(spread, exprType, attributesSymbol, objectFlags, false --[[readonly]])
                    if allAttributesTable ~= nil then
                        c:checkSpreadPropOverrides(exprType, allAttributesTable, attributeDecl)
                    end
                else
                    c:error(attributeDecl:Expression(), diagnostics.Spread_types_may_only_be_created_from_object_types)
                    if typeToIntersect ~= nil then
                        typeToIntersect = c:getIntersectionType({ typeToIntersect, exprType })
                    else
                        typeToIntersect = exprType
                    end
                end
            end
        end
        if not hasSpreadAnyType then
            if next(attributesTable) ~= nil then
                spread = c:getSpreadType(spread, createJsxAttributesType(), attributesSymbol, objectFlags, false --[[readonly]])
            end
        end
    end
    local parentHasSemanticJsxChildren = function(element)
        -- Handle children attribute
        local parent = element.parent
        if parent == nil then
            return false
        end
        local children

        if ast.IsJsxElement(parent) then
            -- We have to check that openingElement of the parent is the one we are visiting as this may not be true for selfClosingElement
            if parent:AsJsxElement().openingElement == element then
                children = parent:Children().nodes
            end
        elseif ast.IsJsxFragment(parent) then
            if parent:AsJsxFragment().openingFragment == element then
                children = parent:Children().nodes
            end
        end
        return core.Len(ast.GetSemanticJsxChildren(children)) ~= 0
    end
    if parentHasSemanticJsxChildren(openingLikeElement) then
        local childTypes = c:checkJsxChildren(openingLikeElement.parent, checkMode)
        if not hasSpreadAnyType and jsxChildrenPropertyName ~= ast.InternalSymbolNameMissing and jsxChildrenPropertyName ~= "" then
            -- Error if there is a attribute named "children" explicitly specified and children element.
            -- This is because children element will overwrite the value from attributes.
            -- Note: we will not warn "children" attribute overwritten if "children" attribute is specified in object spread.
            if explicitlySpecifyChildrenAttribute then
                c:error(attributeParent, diagnostics.X_0_are_specified_twice_The_attribute_named_0_will_be_overwritten, jsxChildrenPropertyName)
            end
            local childrenContextualType
            if ast.IsJsxOpeningElement(openingLikeElement) then
                local contextualType = c:getApparentTypeOfContextualType(openingLikeElement:Attributes(), ContextFlags.None)
                if contextualType ~= nil then
                    childrenContextualType = c:getTypeOfPropertyOfContextualType(contextualType, jsxChildrenPropertyName)
                end
            end
            -- If there are children in the body of JSX element, create dummy attribute "children" with the union of children types so that it will pass the attribute checking process
            local childrenPropSymbol = c:newSymbol(SymbolFlags.Property, jsxChildrenPropertyName)
            local links = c.valueSymbolLinks:Get(childrenPropSymbol)
            if core.Len(childTypes) == 1 then
                links.resolvedType = childTypes[1]
            elseif childrenContextualType ~= nil and checker.someType(childrenContextualType, function(t) return c:isTupleLikeType(t) end) then
                links.resolvedType = c:createTupleType(childTypes)
            else
                links.resolvedType = c:createArrayType(c:getUnionType(childTypes))
            end
            -- Fake up a property declaration for the children
            childrenPropSymbol.valueDeclaration = c.factory:NewPropertySignatureDeclaration(nil, c.factory:NewIdentifier(jsxChildrenPropertyName), nil --[[postfixToken]], nil --[[type]], nil --[[initializer]])
            childrenPropSymbol.valueDeclaration.parent = attributeParent
            childrenPropSymbol.valueDeclaration:AsPropertySignatureDeclaration().symbol = childrenPropSymbol
            local childPropMap = ast.NewSymbolTable()
            childPropMap[jsxChildrenPropertyName] = childrenPropSymbol
            spread = c:getSpreadType(spread, c:newAnonymousType(attributesSymbol, childPropMap, nil, nil, nil), attributesSymbol, objectFlags | c:getPropagatingFlagsOfTypes(childTypes, TypeFlags.None), false --[[readonly]])
        end
    end
    if hasSpreadAnyType then
        return c.anyType
    end
    if typeToIntersect ~= nil then
        if spread ~= c.emptyJsxObjectType then
            return c:getIntersectionType({ typeToIntersect, spread })
        end
        return typeToIntersect
    end
    if spread == c.emptyJsxObjectType then
        return createJsxAttributesType()
    end
    return spread
end

function Checker:checkJsxAttribute(node, checkMode)
    if node:Initializer() ~= nil then
        return self:checkExpressionForMutableLocation(node:Initializer(), checkMode)
    end
    -- <Elem attr /> is sugar for <Elem attr={true} />
    return self.trueType
end

function Checker:checkJsxChildren(node, checkMode)
    local childTypes
    for _, child in ipairs(node:Children().nodes or {}) do
        -- In React, JSX text that contains only whitespaces will be ignored so we don't want to type-check that
        -- because then type of children property will have constituent of string type.
        if ast.IsJsxText(child) then
            if not child:AsJsxText().containsOnlyTriviaWhiteSpaces then
                childTypes = core.Append(childTypes, self.stringType)
            end
        elseif ast.IsJsxExpression(child) and child:Expression() == nil then
            -- empty jsx expressions don't *really* count as present children
        else
            childTypes = core.Append(childTypes, self:checkExpressionForMutableLocation(child, checkMode))
        end
    end
    return childTypes
end

function Checker:getUninstantiatedJsxSignaturesOfType(elementType, caller)
    local c = self
    if elementType.flags & TypeFlags.String ~= 0 then
        return { c.anySignature }
    end
    if elementType.flags & TypeFlags.StringLiteral ~= 0 then
        local intrinsicType = c:getIntrinsicAttributesTypeFromStringLiteralType(elementType, caller)
        if intrinsicType == nil then
            c:error(caller, diagnostics.Property_0_does_not_exist_on_type_1, checker.getStringLiteralValue(elementType), "JSX." .. JsxNames.intrinsicElements)
            return nil
        end
        local fakeSignature = c:createSignatureForJSXIntrinsic(caller, intrinsicType)
        return { fakeSignature }
    end
    local apparentElemType = c:getApparentType(elementType)
    -- Resolve the signatures, preferring constructor
    local signatures = c:getSignaturesOfType(apparentElemType, SignatureKind.Construct)
    if core.Len(signatures) == 0 then
        -- No construct signatures, try call signatures
        signatures = c:getSignaturesOfType(apparentElemType, SignatureKind.Call)
    end
    if core.Len(signatures) == 0 and apparentElemType.flags & TypeFlags.Union ~= 0 then
        -- If each member has some combination of new/call signatures; make a union signature list for those
        signatures = c:getUnionSignatures(core.Map(apparentElemType:Types(), function(t)
            return c:getUninstantiatedJsxSignaturesOfType(t, caller) or {} -- Lua arrays cannot hold nil slices
        end))
    end
    return signatures
end

function Checker:getEffectiveFirstArgumentForJsxSignature(signature, node)
    if ast.IsJsxOpeningFragment(node) or self:getJsxReferenceKind(node) ~= JsxReferenceKind.Component then
        return self:getJsxPropsTypeFromCallSignature(signature, node)
    end
    return self:getJsxPropsTypeFromClassType(signature, node)
end

function Checker:getJsxPropsTypeFromCallSignature(sig, context)
    local c = self
    local propsType = c:getTypeOfFirstParameterOfSignatureWithFallback(sig, c.unknownType)
    propsType = c:getJsxManagedAttributesFromLocatedAttributes(context, c:getJsxNamespaceAt(context), propsType)
    local intrinsicAttribs = c:getJsxType(JsxNames.intrinsicAttributes, context)
    if not c:isErrorType(intrinsicAttribs) then
        propsType = c:intersectTypes(intrinsicAttribs, propsType)
    end
    return propsType
end

function Checker:getJsxPropsTypeFromClassType(sig, context)
    local c = self
    local ns = c:getJsxNamespaceAt(context)
    local forcedLookupLocation = c:getJsxElementPropertiesName(ns)
    local attributesType
    if forcedLookupLocation == ast.InternalSymbolNameMissing then
        attributesType = c:getTypeOfFirstParameterOfSignatureWithFallback(sig, c.unknownType)
    elseif forcedLookupLocation == "" then
        attributesType = c:getReturnTypeOfSignature(sig)
    else
        attributesType = c:getJsxPropsTypeForSignatureFromMember(sig, forcedLookupLocation)
        if attributesType == nil and core.Len(context:Attributes():Properties()) ~= 0 then
            -- There is no property named 'props' on this instance type
            c:error(context, diagnostics.JSX_element_class_does_not_support_attributes_because_it_does_not_have_a_0_property, forcedLookupLocation)
        end
    end
    if attributesType == nil then
        return c.unknownType
    end
    attributesType = c:getJsxManagedAttributesFromLocatedAttributes(context, ns, attributesType)
    if checker.IsTypeAny(attributesType) then
        -- Props is of type 'any' or unknown
        return attributesType
    end
    -- Normal case -- add in IntrinsicClassAttributes<T> and IntrinsicAttributes
    local apparentAttributesType = attributesType
    local intrinsicClassAttribs = c:getJsxType(JsxNames.intrinsicClassAttributes, context)
    if not c:isErrorType(intrinsicClassAttribs) then
        local typeParams = c:getLocalTypeParametersOfClassOrInterfaceOrTypeAlias(intrinsicClassAttribs.symbol)
        local hostClassType = c:getReturnTypeOfSignature(sig)
        local libraryManagedAttributeType
        if typeParams ~= nil then
            -- apply JSX.IntrinsicClassAttributes<hostClassType, ...>
            local inferredArgs = c:fillMissingTypeArguments({ hostClassType }, typeParams, c:getMinTypeArgumentCount(typeParams), ast.IsInJSFile(context))
            libraryManagedAttributeType = c:instantiateType(intrinsicClassAttribs, checker.newTypeMapper(typeParams, inferredArgs))
        else
            libraryManagedAttributeType = intrinsicClassAttribs
        end
        apparentAttributesType = c:intersectTypes(libraryManagedAttributeType, apparentAttributesType)
    end
    local intrinsicAttribs = c:getJsxType(JsxNames.intrinsicAttributes, context)
    if not c:isErrorType(intrinsicAttribs) then
        apparentAttributesType = c:intersectTypes(intrinsicAttribs, apparentAttributesType)
    end
    return apparentAttributesType
end

function Checker:getJsxPropsTypeForSignatureFromMember(sig, forcedLookupLocation)
    local c = self
    if sig.composite ~= nil then
        -- JSX Elements using the legacy `props`-field based lookup (eg, react class components) need to treat the `props` member as an input
        -- instead of an output position when resolving the signature. We need to go back to the input signatures of the composite signature,
        -- get the type of `props` on each return type individually, and then _intersect them_, rather than union them (as would normally occur
        -- for a union signature). It's an unfortunate quirk of looking in the output of the signature for the type we want to use for the input.
        -- The default behavior of `getTypeOfFirstParameterOfSignatureWithFallback` when no `props` member name is defined is much more sane.
        local results
        for _, signature in ipairs(sig.composite.signatures or {}) do
            local instance = c:getReturnTypeOfSignature(signature)
            if checker.IsTypeAny(instance) then
                return instance
            end
            local propType = c:getTypeOfPropertyOfType(instance, forcedLookupLocation)
            if propType == nil then
                return nil
            end
            results = core.Append(results, propType)
        end
        return c:getIntersectionType(results)
        -- Same result for both union and intersection signatures
    end
    local instanceType = c:getReturnTypeOfSignature(sig)
    if checker.IsTypeAny(instanceType) then
        return instanceType
    end
    return c:getTypeOfPropertyOfType(instanceType, forcedLookupLocation)
end

function Checker:getJsxManagedAttributesFromLocatedAttributes(context, ns, attributesType)
    local managedSym = self:getJsxLibraryManagedAttributes(ns)
    if managedSym ~= nil then
        local ctorType = self:getStaticTypeOfReferencedJsxConstructor(context)
        local result = self:instantiateAliasOrInterfaceWithDefaults(managedSym, { ctorType, attributesType }, ast.IsInJSFile(context))
        if result ~= nil then
            return result
        end
    end
    return attributesType
end

function Checker:instantiateAliasOrInterfaceWithDefaults(managedSym, typeArguments, inJavaScript)
    local c = self
    local declaredManagedType = c:getDeclaredTypeOfSymbol(managedSym)
    -- fetches interface type, or initializes symbol links type parameters
    if managedSym.flags & SymbolFlags.TypeAlias ~= 0 then
        local params = c.typeAliasLinks:Get(managedSym).typeParameters
        if core.Len(params) >= core.Len(typeArguments) then
            local args = c:fillMissingTypeArguments(typeArguments, params, core.Len(typeArguments), inJavaScript)
            if core.Len(args) == 0 then
                return declaredManagedType
            end
            return c:getTypeAliasInstantiation(managedSym, args, nil)
        end
    end
    if declaredManagedType.objectFlags & checker.ObjectFlags.ClassOrInterface ~= 0 and core.Len(declaredManagedType:AsInterfaceType():TypeParameters()) >= core.Len(typeArguments) then
        local args = c:fillMissingTypeArguments(typeArguments, declaredManagedType:AsInterfaceType():TypeParameters(), core.Len(typeArguments), inJavaScript)
        return c:createTypeReference(declaredManagedType, args)
    end
    return nil
end

function Checker:getJsxLibraryManagedAttributes(jsxNamespace)
    if jsxNamespace ~= nil then
        return self:getSymbol(jsxNamespace.exports, JsxNames.libraryManagedAttributes, SymbolFlags.Type)
    end
    return nil
end

function Checker:getJsxElementTypeSymbol(jsxNamespace)
    -- JSX.ElementType [symbol]
    if jsxNamespace ~= nil then
        return self:getSymbol(jsxNamespace.exports, JsxNames.elementType, SymbolFlags.Type)
    end
    return nil
end

-- e.g. "props" for React.d.ts,
-- or InternalSymbolNameMissing if ElementAttributesProperty doesn't exist (which means all
--
--	non-intrinsic elements' attributes type is 'any'),
--
-- or "" if it has 0 properties (which means every
--
--	non-intrinsic elements' attributes type is the element instance type)
function Checker:getJsxElementPropertiesName(jsxNamespace)
    return self:getNameFromJsxElementAttributesContainer(JsxNames.elementAttributesPropertyNameContainer, jsxNamespace)
end

function Checker:getJsxElementChildrenPropertyName(jsxNamespace)
    if self.compilerOptions.jsx == JsxEmit.ReactJSX or self.compilerOptions.jsx == JsxEmit.ReactJSXDev then
        -- In these JsxEmit modes the children property is fixed to 'children'
        return "children"
    end
    return self:getNameFromJsxElementAttributesContainer(JsxNames.elementChildrenAttributeNameContainer, jsxNamespace)
end

-- Look into JSX namespace and then look for container with matching name as nameOfAttribPropContainer.
-- Get a single property from that container if existed. Report an error if there are more than one property.
--
-- @param nameOfAttribPropContainer a string of value JsxNames.ElementAttributesPropertyNameContainer or JsxNames.ElementChildrenAttributeNameContainer
--
--	if other string is given or the container doesn't exist, return undefined.
function Checker:getNameFromJsxElementAttributesContainer(nameOfAttribPropContainer, jsxNamespace)
    local c = self
    -- JSX.ElementAttributesProperty | JSX.ElementChildrenAttribute [symbol]
    if jsxNamespace ~= nil then
        local jsxElementAttribPropInterfaceSym = c:getSymbol(jsxNamespace.exports, nameOfAttribPropContainer, SymbolFlags.Type)
        if jsxElementAttribPropInterfaceSym ~= nil then
            local jsxElementAttribPropInterfaceType = c:getDeclaredTypeOfSymbol(jsxElementAttribPropInterfaceSym)
            local propertiesOfJsxElementAttribPropInterface = c:getPropertiesOfType(jsxElementAttribPropInterfaceType)
            -- Element Attributes has zero properties, so the element attributes type will be the class instance type
            if core.Len(propertiesOfJsxElementAttribPropInterface) == 0 then
                return ""
            end
            if #propertiesOfJsxElementAttribPropInterface == 1 then
                return propertiesOfJsxElementAttribPropInterface[1].name
            end
            if #propertiesOfJsxElementAttribPropInterface > 1 and core.Len(jsxElementAttribPropInterfaceSym.declarations) ~= 0 then
                -- More than one property on ElementAttributesProperty is an error
                c:error(jsxElementAttribPropInterfaceSym.declarations[1], diagnostics.The_global_type_JSX_0_may_not_have_more_than_one_property, nameOfAttribPropContainer)
            end
        end
    end
    return ast.InternalSymbolNameMissing
end

function Checker:getStaticTypeOfReferencedJsxConstructor(context)
    local c = self
    if ast.IsJsxOpeningFragment(context) then
        return c:getJSXFragmentType(context)
    end
    if checker.isJsxIntrinsicTagName(context:TagName()) then
        local result = c:getIntrinsicAttributesTypeFromJsxOpeningLikeElement(context)
        local fakeSignature = c:createSignatureForJSXIntrinsic(context, result)
        return c:getOrCreateTypeFromSignature(fakeSignature)
    end
    local tagType = c:checkExpressionCached(context:TagName())
    if tagType.flags & TypeFlags.StringLiteral ~= 0 then
        local result = c:getIntrinsicAttributesTypeFromStringLiteralType(tagType, context)
        if result == nil then
            return c.errorType
        end
        local fakeSignature = c:createSignatureForJSXIntrinsic(context, result)
        return c:getOrCreateTypeFromSignature(fakeSignature)
    end
    return tagType
end

function Checker:getIntrinsicAttributesTypeFromStringLiteralType(t, location)
    local c = self
    -- If the elemType is a stringLiteral type, we can then provide a check to make sure that the string literal type is one of the Jsx intrinsic element type
    -- For example:
    --      var CustomTag: "h1" = "h1";
    --      <CustomTag> Hello World </CustomTag>
    local intrinsicElementsType = c:getJsxType(JsxNames.intrinsicElements, location)
    if not c:isErrorType(intrinsicElementsType) then
        local stringLiteralTypeName = checker.getStringLiteralValue(t)
        local intrinsicProp = c:getPropertyOfType(intrinsicElementsType, stringLiteralTypeName)
        if intrinsicProp ~= nil then
            return c:getTypeOfSymbol(intrinsicProp)
        end
        local indexSignatureType = c:getIndexTypeOfType(intrinsicElementsType, c.stringType)
        if indexSignatureType ~= nil then
            return indexSignatureType
        end
        return nil
    end
    -- If we need to report an error, we already done so here. So just return any to prevent any more error downstream
    return c.anyType
end

function Checker:getJsxReferenceKind(node)
    if checker.isJsxIntrinsicTagName(node:TagName()) then
        return JsxReferenceKind.Mixed
    end
    local tagType = self:getApparentType(self:checkExpression(node:TagName()))
    if core.Len(self:getSignaturesOfType(tagType, SignatureKind.Construct)) ~= 0 then
        return JsxReferenceKind.Component
    end
    if core.Len(self:getSignaturesOfType(tagType, SignatureKind.Call)) ~= 0 then
        return JsxReferenceKind.Function
    end
    return JsxReferenceKind.Mixed
end

function Checker:createSignatureForJSXIntrinsic(node, result)
    local c = self
    local elementType = c.errorType
    local namespace = c:getJsxNamespaceAt(node)
    if namespace ~= nil then
        local typeSymbol = c:getSymbol(c:getExportsOfSymbol(namespace), JsxNames.element, SymbolFlags.Type)
        if typeSymbol ~= nil then
            elementType = c:getDeclaredTypeOfSymbol(typeSymbol)
        end
    end
    -- returnNode := typeSymbol && c.nodeBuilder.symbolToEntityName(typeSymbol, ast.SymbolFlagsType, node)
    -- declaration := factory.createFunctionTypeNode(nil, []ParameterDeclaration{factory.createParameterDeclaration(nil, nil /*dotDotDotToken*/, "props", nil /*questionToken*/, c.nodeBuilder.typeToTypeNode(result, node))}, ifElse(returnNode != nil, factory.createTypeReferenceNode(returnNode, nil /*typeArguments*/), factory.createKeywordTypeNode(ast.KindAnyKeyword)))
    local parameterSymbol = c:newSymbol(SymbolFlags.FunctionScopedVariable, "props")
    c.valueSymbolLinks:Get(parameterSymbol).resolvedType = result
    return c:newSignature(SignatureFlags.None, nil, nil, nil, { parameterSymbol }, elementType, nil, 1)
end

-- Get attributes type of the given intrinsic opening-like Jsx element by resolving the tag name.
-- The function is intended to be called from a function which has checked that the opening element is an intrinsic element.
-- @param node an intrinsic JSX opening-like element
function Checker:getIntrinsicAttributesTypeFromJsxOpeningLikeElement(node)
    local c = self
    debug.Assert(checker.isJsxIntrinsicTagName(node:TagName()))
    local links = c.jsxElementLinks:Get(node)
    if links.resolvedJsxElementAttributesType ~= nil then
        return links.resolvedJsxElementAttributesType
    end
    local symbol = c:getIntrinsicTagSymbol(node)
    if links.jsxFlags & JsxFlags.IntrinsicNamedElement ~= 0 then
        links.resolvedJsxElementAttributesType = core.OrElse(c:getTypeOfSymbol(symbol), c.errorType)
        return links.resolvedJsxElementAttributesType
    end
    if links.jsxFlags & JsxFlags.IntrinsicIndexedElement ~= 0 then
        local indexInfo = c:getApplicableIndexInfoForName(c:getJsxType(JsxNames.intrinsicElements, node), node:TagName():Text())
        if indexInfo ~= nil then
            links.resolvedJsxElementAttributesType = indexInfo.valueType
            return links.resolvedJsxElementAttributesType
        end
    end
    links.resolvedJsxElementAttributesType = c.errorType
    return links.resolvedJsxElementAttributesType
end

-- Looks up an intrinsic tag name and returns a symbol that either points to an intrinsic
-- property (in which case nodeLinks.jsxFlags will be IntrinsicNamedElement) or an intrinsic
-- string index signature (in which case nodeLinks.jsxFlags will be IntrinsicIndexedElement).
-- May also return unknownSymbol if both of these lookups fail.
function Checker:getIntrinsicTagSymbol(node)
    local c = self
    local links = c.symbolNodeLinks:Get(node)
    if links.resolvedSymbol ~= nil then
        return links.resolvedSymbol
    end
    local intrinsicElementsType = c:getJsxType(JsxNames.intrinsicElements, node)
    if not c:isErrorType(intrinsicElementsType) then
        -- Property case
        local tagName = node:TagName()
        if not ast.IsIdentifier(tagName) and not ast.IsJsxNamespacedName(tagName) then
            error("Invalid tag name", 0)
        end
        local propName = tagName:Text()
        local intrinsicProp = c:getPropertyOfType(intrinsicElementsType, propName)
        if intrinsicProp ~= nil then
            local jsxLinks = c.jsxElementLinks:Get(node)
            jsxLinks.jsxFlags = jsxLinks.jsxFlags | JsxFlags.IntrinsicNamedElement
            links.resolvedSymbol = intrinsicProp
            return links.resolvedSymbol
        end
        -- Intrinsic string indexer case
        local indexSymbol = c:getApplicableIndexSymbol(intrinsicElementsType, c:getStringLiteralType(propName))
        if indexSymbol ~= nil then
            local jsxLinks = c.jsxElementLinks:Get(node)
            jsxLinks.jsxFlags = jsxLinks.jsxFlags | JsxFlags.IntrinsicIndexedElement
            links.resolvedSymbol = indexSymbol
            return links.resolvedSymbol
        end
        if c:getTypeOfPropertyOrIndexSignatureOfType(intrinsicElementsType, propName) ~= nil then
            local jsxLinks = c.jsxElementLinks:Get(node)
            jsxLinks.jsxFlags = jsxLinks.jsxFlags | JsxFlags.IntrinsicIndexedElement
            links.resolvedSymbol = intrinsicElementsType.symbol
            return links.resolvedSymbol
        end
        -- Wasn't found
        c:error(node, diagnostics.Property_0_does_not_exist_on_type_1, tagName:Text(), "JSX." .. JsxNames.intrinsicElements)
        links.resolvedSymbol = c.unknownSymbol
        return links.resolvedSymbol
    end
    if c.noImplicitAny then
        c:error(node, diagnostics.JSX_element_implicitly_has_type_any_because_no_interface_JSX_0_exists, JsxNames.intrinsicElements)
    end
    links.resolvedSymbol = c.unknownSymbol
    return links.resolvedSymbol
end

function Checker:getJsxStatelessElementTypeAt(location)
    local jsxElementType = self:getJsxElementTypeAt(location)
    if jsxElementType == nil then
        return nil
    end
    return self:getUnionType({ jsxElementType, self.nullType })
end

function Checker:getJsxElementClassTypeAt(location)
    local t = self:getJsxType(JsxNames.elementClass, location)
    if self:isErrorType(t) then
        return nil
    end
    return t
end

function Checker:getJsxElementTypeAt(location)
    return self:getJsxType(JsxNames.element, location)
end

function Checker:getJsxElementTypeTypeAt(location)
    local ns = self:getJsxNamespaceAt(location)
    if ns == nil then
        return nil
    end
    local sym = self:getJsxElementTypeSymbol(ns)
    if sym == nil then
        return nil
    end
    local t = self:instantiateAliasOrInterfaceWithDefaults(sym, nil, ast.IsInJSFile(location))
    if t == nil or self:isErrorType(t) then
        return nil
    end
    return t
end

function Checker:getJsxType(name, location)
    local namespace = self:getJsxNamespaceAt(location)
    if namespace ~= nil then
        local exports = self:getExportsOfSymbol(namespace)
        if exports ~= nil then
            local typeSymbol = self:getSymbol(exports, name, SymbolFlags.Type)
            if typeSymbol ~= nil then
                return self:getDeclaredTypeOfSymbol(typeSymbol)
            end
        end
    end
    return self.errorType
end

function Checker:getJsxNamespaceAt(location)
    local c = self
    local links
    if location ~= nil then
        links = c.jsxElementLinks:Get(location)
    end
    if links ~= nil and links.jsxNamespace ~= nil and links.jsxNamespace ~= c.unknownSymbol then
        return links.jsxNamespace
    end
    if links == nil or links.jsxNamespace ~= c.unknownSymbol then
        local resolvedNamespace = c:getJsxNamespaceContainerForImplicitImport(location)
        if resolvedNamespace == nil or resolvedNamespace == c.unknownSymbol then
            local namespaceName = c:getJsxNamespace(location)
            resolvedNamespace = c.resolveName(location, namespaceName, SymbolFlags.Namespace, nil --[[nameNotFoundMessage]], false --[[isUse]], false --[[excludeGlobals]])
        end
        if resolvedNamespace ~= nil then
            local candidate = c:resolveSymbol(c:getSymbol(c:getExportsOfSymbol(c:resolveSymbol(resolvedNamespace)), JsxNames.jsx, SymbolFlags.Namespace))
            if candidate ~= nil and candidate ~= c.unknownSymbol then
                if links ~= nil then
                    links.jsxNamespace = candidate
                end
                return candidate
            end
        end
        if links ~= nil then
            links.jsxNamespace = c.unknownSymbol
        end
    end
    -- JSX global fallback
    local s = c:resolveSymbol(c:getGlobalSymbol(JsxNames.jsx, SymbolFlags.Namespace, nil --[[diagnostic]]))
    if s == c.unknownSymbol then
        return nil
    end
    return s
end

function Checker:getJsxNamespace(location)
    local c = self
    if location ~= nil then
        local file = ast.GetSourceFileOfNode(location)
        if file ~= nil then
            local links = c.sourceFileLinks:Get(file)
            if ast.IsJsxOpeningFragment(location) then
                if links.localJsxFragmentNamespace ~= "" then
                    return links.localJsxFragmentNamespace
                end
                local jsxFragmentPragma = ast.GetPragmaFromSourceFile(file, "jsxfrag")
                if jsxFragmentPragma ~= nil then
                    links.localJsxFragmentFactory = c:parseIsolatedEntityName(pragmaArgValue(jsxFragmentPragma, "factory"))
                    if links.localJsxFragmentFactory ~= nil then
                        links.localJsxFragmentNamespace = ast.GetFirstIdentifier(links.localJsxFragmentFactory):Text()
                        return links.localJsxFragmentNamespace
                    end
                end
                local entity = c:getJsxFragmentFactoryEntity(location)
                if entity ~= nil then
                    links.localJsxFragmentFactory = entity
                    links.localJsxFragmentNamespace = ast.GetFirstIdentifier(entity):Text()
                    return links.localJsxFragmentNamespace
                end
            else
                local localJsxNamespace = c:getLocalJsxNamespace(file)
                if localJsxNamespace ~= "" then
                    links.localJsxNamespace = localJsxNamespace
                    return links.localJsxNamespace
                end
            end
        end
    end
    if c._jsxNamespace == "" then
        c._jsxNamespace = "React"
        if c.compilerOptions.jsxFactory ~= "" then
            c._jsxFactoryEntity = c:parseIsolatedEntityName(c.compilerOptions.jsxFactory)
            if c._jsxFactoryEntity ~= nil then
                c._jsxNamespace = ast.GetFirstIdentifier(c._jsxFactoryEntity):Text()
            end
        elseif c.compilerOptions.reactNamespace ~= "" then
            c._jsxNamespace = c.compilerOptions.reactNamespace
        end
    end
    if c._jsxFactoryEntity == nil then
        c._jsxFactoryEntity = c.factory:NewQualifiedName(c.factory:NewIdentifier(c._jsxNamespace), c.factory:NewIdentifier("createElement"))
    end
    return c._jsxNamespace
end

function Checker:getLocalJsxNamespace(file)
    local links = self.sourceFileLinks:Get(file)
    if links.localJsxNamespace ~= "" then
        return links.localJsxNamespace
    end
    local jsxPragma = ast.GetPragmaFromSourceFile(file, "jsx")
    if jsxPragma ~= nil then
        links.localJsxFactory = self:parseIsolatedEntityName(pragmaArgValue(jsxPragma, "factory"))
        if links.localJsxFactory ~= nil then
            links.localJsxNamespace = ast.GetFirstIdentifier(links.localJsxFactory):Text()
            return links.localJsxNamespace
        end
    end
    return ""
end

function Checker:getJsxFactoryEntity(location)
    if location ~= nil then
        self:getJsxNamespace(location)
        local localJsxFactory = self.sourceFileLinks:Get(ast.GetSourceFileOfNode(location)).localJsxFactory
        if localJsxFactory ~= nil then
            return localJsxFactory
        end
    end
    return self._jsxFactoryEntity
end

function Checker:getJsxFragmentFactoryEntity(location)
    if location ~= nil then
        local file = ast.GetSourceFileOfNode(location)
        if file ~= nil then
            local links = self.sourceFileLinks:Get(file)
            if links.localJsxFragmentFactory ~= nil then
                return links.localJsxFragmentFactory
            end
            local jsxFragPragma = ast.GetPragmaFromSourceFile(file, "jsxfrag")
            if jsxFragPragma ~= nil then
                links.localJsxFragmentFactory = self:parseIsolatedEntityName(pragmaArgValue(jsxFragPragma, "factory"))
                return links.localJsxFragmentFactory
            end
        end
    end
    if self.compilerOptions.jsxFragmentFactory ~= "" then
        return self:parseIsolatedEntityName(self.compilerOptions.jsxFragmentFactory)
    end
    return nil
end

function Checker:parseIsolatedEntityName(name)
    local result = parser.ParseIsolatedEntityName(name)
    if result ~= nil then
        checker.markAsSynthetic(result)
    end
    return result
end

function checker.markAsSynthetic(node)
    node.loc = core.NewTextRange(-1, -1)
    node:ForEachChild(checker.markAsSynthetic)
    return false
end

function Checker:getJsxNamespaceContainerForImplicitImport(location)
    local c = self
    local file = ast.GetSourceFileOfNode(location)
    local links = c.jsxElementLinks:Get(file)
    if links.jsxImplicitImportContainer ~= nil then
        return core.IfElse(links.jsxImplicitImportContainer == c.unknownSymbol, nil, links.jsxImplicitImportContainer)
    end
    local canonicalErrorTag = links.firstJSXTagInFile
    if canonicalErrorTag == nil then
        local visit
        visit = function(node)
            if ast.IsJsxElement(node) or ast.IsJsxSelfClosingElement(node) then
                links.firstJSXTagInFile = node
                return true
            end
            if ast.IsJsxFragment(node) then
                links.firstJSXTagInFile = node:AsJsxFragment().openingFragment -- to match strada, fragments issue errors on the opening fragment instead of the whole tag
                return true
            end
            return node:ForEachChild(visit)
        end
        file:ForEachChild(visit)
        canonicalErrorTag = links.firstJSXTagInFile
    end
    local moduleReference, specifier = c:getJSXRuntimeImportSpecifier(file)
    if moduleReference == "" then
        return nil
    end
    local errorMessage = diagnostics.This_JSX_tag_requires_the_module_path_0_to_exist_but_none_could_be_found_Make_sure_you_have_types_for_the_appropriate_package_installed
    local mod = c:resolveExternalModule(core.OrElse(specifier, canonicalErrorTag), moduleReference, errorMessage, canonicalErrorTag, false)
    local result
    if mod ~= nil and mod ~= c.unknownSymbol then
        result = c:getMergedSymbol(c:resolveSymbol(mod))
    end
    links.jsxImplicitImportContainer = core.OrElse(result, c.unknownSymbol)
    return result
end

function Checker:getJSXRuntimeImportSpecifier(file)
    local moduleReference, specifier = self.program:GetJSXRuntimeImportSpecifier(file:Path())
    return moduleReference or "", specifier
end
