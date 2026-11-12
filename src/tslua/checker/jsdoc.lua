local checker = require("tslua.checker")
local ast = require("tslua.ast")
local diagnostics = require("tslua.diagnostics")

local Checker = checker.Checker
local Kind = ast.Kind
local NodeFlags = ast.NodeFlags

function Checker:checkUnmatchedJSDocParameters(node)
    local jsdocParameters = {}
    for _, tag in ipairs(checker.getAllJSDocTags(node) or {}) do
        if tag.kind == Kind.JSDocParameterTag then
            local name = tag:AsJSDocParameterOrPropertyTag():Name()
            if not (ast.IsIdentifier(name) and #name:Text() == 0) then
                jsdocParameters[#jsdocParameters + 1] = tag
            end
        end
    end

    if #jsdocParameters == 0 then
        return
    end

    local isJs = ast.IsInJSFile(node)
    local parameters = {} -- collections.Set[string]
    local excludedParameters = {} -- collections.Set[int]

    for i1, param in ipairs(node:Parameters() or {}) do
        local i = i1 - 1
        local name = param:AsParameterDeclaration():Name()
        if ast.IsIdentifier(name) then
            parameters[name:Text()] = true
        end
        if ast.IsBindingPattern(name) then
            excludedParameters[i] = true
        end
    end
    if self:containsArgumentsReference(node) then
        if isJs then
            local lastJSDocParamIndex = #jsdocParameters - 1
            local lastJSDocParam = jsdocParameters[lastJSDocParamIndex + 1]:AsJSDocParameterOrPropertyTag()
            if lastJSDocParam == nil or not ast.IsIdentifier(lastJSDocParam:Name()) then
                return
            end
            if excludedParameters[lastJSDocParamIndex] or parameters[lastJSDocParam:Name():Text()] then
                return
            end
            if lastJSDocParam.typeExpression == nil or lastJSDocParam.typeExpression:Type() == nil then
                return
            end
            if self:isArrayType(self:getTypeFromTypeNode(lastJSDocParam.typeExpression:Type())) then
                return
            end
            self:error(lastJSDocParam:Name(), diagnostics.JSDoc_param_tag_has_name_0_but_there_is_no_parameter_with_that_name_It_would_match_arguments_if_it_had_an_array_type, lastJSDocParam:Name():Text())
        end
    else
        for index1, tag in ipairs(jsdocParameters) do
            local index = index1 - 1
            local name = tag:AsJSDocParameterOrPropertyTag():Name()
            local isNameFirst = tag:AsJSDocParameterOrPropertyTag().isNameFirst

            if excludedParameters[index] or (ast.IsIdentifier(name) and parameters[name:Text()]) then
                goto continue
            end

            if ast.IsQualifiedName(name) then
                if isJs then
                    self:error(
                        name, diagnostics.Qualified_name_0_is_not_allowed_without_a_leading_param_object_1,
                        checker.entityNameToString(name),
                        checker.entityNameToString(name:AsQualifiedName().left)
                    )
                end
            else
                if not isNameFirst then
                    self:errorOrSuggestion(
                        isJs, name,
                        diagnostics.JSDoc_param_tag_has_name_0_but_there_is_no_parameter_with_that_name,
                        name:Text()
                    )
                end
            end
            ::continue::
        end
    end
end

function checker.getAllJSDocTags(node)
    if node.flags & NodeFlags.JSDoc == 0 then
        local current = node
        while current ~= nil do
            local jsdocs = current:JSDoc(nil)
            if jsdocs ~= nil and #jsdocs ~= 0 then
                local lastJSDoc = jsdocs[#jsdocs]:AsJSDoc()
                if lastJSDoc.tags ~= nil then
                    return lastJSDoc.tags.nodes
                end
            end
            current = ast.GetNextJSDocCommentLocation(current)
        end
    end
    return nil
end
