local declarations = require("tslua.transformers.declarations")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local SymbolAccessibility = printer.SymbolAccessibility
local FindAncestorResult = ast.FindAncestorResult

-- GetSymbolAccessibilityDiagnostic = fn(symbolAccessibilityResult) -> SymbolAccessibilityDiagnostic or nil
-- SymbolAccessibilityDiagnostic: { errorNode, diagnosticMessage, typeName }

function declarations.wrapSimpleDiagnosticSelector(node, selector)
    return function(symbolAccessibilityResult)
        local diagnosticMessage = selector(node, symbolAccessibilityResult)
        if diagnosticMessage == nil then
            return nil
        end
        return {
            errorNode = node,
            diagnosticMessage = diagnosticMessage,
            typeName = ast.GetNameOfDeclaration(node),
        }
    end
end

function declarations.wrapNamedDiagnosticSelector(node, selector)
    return function(symbolAccessibilityResult)
        local diagnosticMessage = selector(node, symbolAccessibilityResult)
        if diagnosticMessage == nil then
            return nil
        end
        local name = ast.GetNameOfDeclaration(node)
        return {
            errorNode = name,
            diagnosticMessage = diagnosticMessage,
            typeName = name,
        }
    end
end

function declarations.wrapFallbackErrorDiagnosticSelector(node, selector)
    return function(symbolAccessibilityResult)
        local diagnosticMessage = selector(node, symbolAccessibilityResult)
        if diagnosticMessage == nil then
            return nil
        end
        local errorNode = ast.GetNameOfDeclaration(node)
        if errorNode == nil then
            errorNode = node
        end
        return {
            errorNode = errorNode,
            diagnosticMessage = diagnosticMessage,
        }
    end
end

function declarations.selectDiagnosticBasedOnModuleName(symbolAccessibilityResult, moduleNotNameable, privateModule, nonModule)
    if #(symbolAccessibilityResult.errorModuleName or "") > 0 then
        if symbolAccessibilityResult.accessibility == SymbolAccessibility.CannotBeNamed then
            return moduleNotNameable
        end
        return privateModule
    end
    return nonModule
end

function declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(symbolAccessibilityResult, privateModule, nonModule)
    if #(symbolAccessibilityResult.errorModuleName or "") > 0 then
        return privateModule
    end
    return nonModule
end

function declarations.createGetSymbolAccessibilityDiagnosticForNodeName(node)
    if ast.IsSetAccessorDeclaration(node) or ast.IsGetAccessorDeclaration(node) then
        return declarations.wrapSimpleDiagnosticSelector(node, declarations.getAccessorNameVisibilityDiagnosticMessage)
    elseif ast.IsMethodDeclaration(node) or ast.IsMethodSignatureDeclaration(node) then
        return declarations.wrapSimpleDiagnosticSelector(node, declarations.getMethodNameVisibilityDiagnosticMessage)
    else
        return declarations.createGetSymbolAccessibilityDiagnosticForNode(node)
    end
end

function declarations.getAccessorNameVisibilityDiagnosticMessage(node, symbolAccessibilityResult)
    if ast.IsStatic(node) then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Public_static_property_0_of_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Public_static_property_0_of_exported_class_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Public_static_property_0_of_exported_class_has_or_is_using_private_name_1
        )
    elseif node.parent.kind == Kind.ClassDeclaration then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Public_property_0_of_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Public_property_0_of_exported_class_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Public_property_0_of_exported_class_has_or_is_using_private_name_1
        )
    else
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Property_0_of_exported_interface_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Property_0_of_exported_interface_has_or_is_using_private_name_1
        )
    end
end

function declarations.getMethodNameVisibilityDiagnosticMessage(node, symbolAccessibilityResult)
    if ast.IsStatic(node) then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Public_static_method_0_of_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Public_static_method_0_of_exported_class_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Public_static_method_0_of_exported_class_has_or_is_using_private_name_1
        )
    elseif node.parent.kind == Kind.ClassDeclaration then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Public_method_0_of_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Public_method_0_of_exported_class_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Public_method_0_of_exported_class_has_or_is_using_private_name_1
        )
    else
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Method_0_of_exported_interface_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Method_0_of_exported_interface_has_or_is_using_private_name_1
        )
    end
end

function declarations.createGetSymbolAccessibilityDiagnosticForNode(node)
    if ast.IsVariableDeclaration(node) or ast.IsPropertyDeclaration(node) or ast.IsPropertySignatureDeclaration(node) or ast.IsPropertyAccessExpression(node) or ast.IsElementAccessExpression(node) or ast.IsBinaryExpression(node) or ast.IsBindingElement(node) or ast.IsConstructorDeclaration(node) then
        return declarations.wrapSimpleDiagnosticSelector(node, declarations.getVariableDeclarationTypeVisibilityDiagnosticMessage)
    elseif ast.IsSetAccessorDeclaration(node) or ast.IsGetAccessorDeclaration(node) then
        return declarations.wrapNamedDiagnosticSelector(node, declarations.getAccessorDeclarationTypeVisibilityDiagnosticMessage)
    elseif ast.IsConstructSignatureDeclaration(node) or ast.IsCallSignatureDeclaration(node) or ast.IsMethodDeclaration(node) or ast.IsMethodSignatureDeclaration(node) or ast.IsFunctionDeclaration(node) or ast.IsIndexSignatureDeclaration(node) then
        return declarations.wrapFallbackErrorDiagnosticSelector(node, declarations.getReturnTypeVisibilityDiagnosticMessage)
    elseif ast.IsParameterDeclaration(node) then
        if ast.IsParameterPropertyDeclaration(node, node.parent) and ast.HasSyntacticModifier(node.parent, ModifierFlags.Private) then
            return declarations.wrapSimpleDiagnosticSelector(node, declarations.getVariableDeclarationTypeVisibilityDiagnosticMessage)
        end
        return declarations.wrapSimpleDiagnosticSelector(node, declarations.getParameterDeclarationTypeVisibilityDiagnosticMessage)
    elseif ast.IsTypeParameterDeclaration(node) then
        return declarations.wrapSimpleDiagnosticSelector(node, declarations.getTypeParameterConstraintVisibilityDiagnosticMessage)
    elseif ast.IsExpressionWithTypeArguments(node) then
        -- unique node selection behavior, inline closure
        return function(_)
            local diagnosticMessage
            -- Heritage clause is written by user so it can always be named
            if ast.IsClassDeclaration(node.parent.parent) then
                -- Class or Interface implemented/extended is inaccessible
                if ast.IsHeritageClause(node.parent) and node.parent:AsHeritageClause().token == Kind.ImplementsKeyword then
                    diagnosticMessage = diagnostics.Implements_clause_of_exported_class_0_has_or_is_using_private_name_1
                else
                    if node.parent.parent:Name() ~= nil then
                        diagnosticMessage = diagnostics.X_extends_clause_of_exported_class_0_has_or_is_using_private_name_1
                    else
                        diagnosticMessage = diagnostics.X_extends_clause_of_exported_class_has_or_is_using_private_name_0
                    end
                end
            else
                -- interface is inaccessible
                diagnosticMessage = diagnostics.X_extends_clause_of_exported_interface_0_has_or_is_using_private_name_1
            end

            return {
                diagnosticMessage = diagnosticMessage,
                errorNode = node,
                typeName = ast.GetNameOfDeclaration(node.parent.parent),
            }
        end
    elseif ast.IsImportEqualsDeclaration(node) then
        return declarations.wrapSimpleDiagnosticSelector(node, function(_, _)
            return diagnostics.Import_declaration_0_is_using_private_name_1
        end)
    elseif ast.IsTypeAliasDeclaration(node) or ast.IsJSTypeAliasDeclaration(node) then
        -- unique node selection behavior, inline closure
        return function(symbolAccessibilityResult)
            local diagnosticMessage = declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
                symbolAccessibilityResult,
                diagnostics.Exported_type_alias_0_has_or_is_using_private_name_1_from_module_2,
                diagnostics.Exported_type_alias_0_has_or_is_using_private_name_1
            )
            local errorNode = node:Type()
            local typeName = node:Name()
            return {
                errorNode = errorNode,
                diagnosticMessage = diagnosticMessage,
                typeName = typeName,
            }
        end
    elseif ast.IsCallExpression(node) then
        -- JS object.defineProperty call
        -- unique node selection behavior, inline closure
        return function(symbolAccessibilityResult)
            local diagnosticMessage = declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Exported_variable_0_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Exported_variable_0_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Exported_variable_0_has_or_is_using_private_name_1
            )
            local errorNode = node:Arguments()[2]
            local typeName = node:Arguments()[2]
            return {
                errorNode = errorNode,
                diagnosticMessage = diagnosticMessage,
                typeName = typeName,
            }
        end
    else
        error("Attempted to set a declaration diagnostic context for unhandled node kind: " .. ast.Kind_String(node.kind), 0)
    end
end

function declarations.getVariableDeclarationTypeVisibilityDiagnosticMessage(node, symbolAccessibilityResult)
    if node.kind == Kind.VariableDeclaration or node.kind == Kind.BindingElement then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Exported_variable_0_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Exported_variable_0_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Exported_variable_0_has_or_is_using_private_name_1
        )

        -- This check is to ensure we don't report error on constructor parameter property as that error would be reported during parameter emit
        -- The only exception here is if the constructor was marked as private. we are not emitting the constructor parameters at all.
    elseif node.kind == Kind.PropertyDeclaration or node.kind == Kind.PropertyAccessExpression or node.kind == Kind.ElementAccessExpression or node.kind == Kind.BinaryExpression or node.kind == Kind.PropertySignature or
        (node.kind == Kind.Parameter and ast.HasSyntacticModifier(node.parent, ModifierFlags.Private)) then
        -- TODO(jfreeman): Deal with computed properties in error reporting.
        if ast.IsStatic(node) then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Public_static_property_0_of_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Public_static_property_0_of_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Public_static_property_0_of_exported_class_has_or_is_using_private_name_1
            )
        elseif node.parent.kind == Kind.ClassDeclaration or node.kind == Kind.Parameter then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Public_property_0_of_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Public_property_0_of_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Public_property_0_of_exported_class_has_or_is_using_private_name_1
            )
        else
            -- Interfaces cannot have types that cannot be named
            return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
                symbolAccessibilityResult,
                diagnostics.Property_0_of_exported_interface_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Property_0_of_exported_interface_has_or_is_using_private_name_1
            )
        end
    end
    return nil -- TODO: Audit behavior - should this panic? potentially silent error state in strada
end

function declarations.getAccessorDeclarationTypeVisibilityDiagnosticMessage(node, symbolAccessibilityResult)
    if node.kind == Kind.SetAccessor then
        -- Getters can infer the return type from the returned expression, but setters cannot, so the
        -- "_from_external_module_1_but_cannot_be_named" case cannot occur.
        if ast.IsStatic(node) then
            return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
                symbolAccessibilityResult,
                diagnostics.Parameter_type_of_public_static_setter_0_from_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Parameter_type_of_public_static_setter_0_from_exported_class_has_or_is_using_private_name_1
            )
        else
            return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
                symbolAccessibilityResult,
                diagnostics.Parameter_type_of_public_setter_0_from_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Parameter_type_of_public_setter_0_from_exported_class_has_or_is_using_private_name_1
            )
        end
    else
        if ast.IsStatic(node) then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Return_type_of_public_static_getter_0_from_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Return_type_of_public_static_getter_0_from_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Return_type_of_public_static_getter_0_from_exported_class_has_or_is_using_private_name_1
            )
        else
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Return_type_of_public_getter_0_from_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Return_type_of_public_getter_0_from_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Return_type_of_public_getter_0_from_exported_class_has_or_is_using_private_name_1
            )
        end
    end
end

function declarations.getReturnTypeVisibilityDiagnosticMessage(node, symbolAccessibilityResult)
    local kind = node.kind
    if kind == Kind.ConstructSignature then
        -- Interfaces cannot have return types that cannot be named
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Return_type_of_constructor_signature_from_exported_interface_has_or_is_using_name_0_from_private_module_1,
            diagnostics.Return_type_of_constructor_signature_from_exported_interface_has_or_is_using_private_name_0
        )
    elseif kind == Kind.CallSignature then
        -- Interfaces cannot have return types that cannot be named
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Return_type_of_call_signature_from_exported_interface_has_or_is_using_name_0_from_private_module_1,
            diagnostics.Return_type_of_call_signature_from_exported_interface_has_or_is_using_private_name_0
        )
    elseif kind == Kind.IndexSignature then
        -- Interfaces cannot have return types that cannot be named
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Return_type_of_index_signature_from_exported_interface_has_or_is_using_name_0_from_private_module_1,
            diagnostics.Return_type_of_index_signature_from_exported_interface_has_or_is_using_private_name_0
        )
    elseif kind == Kind.MethodDeclaration or kind == Kind.MethodSignature then
        if ast.IsStatic(node) then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Return_type_of_public_static_method_from_exported_class_has_or_is_using_name_0_from_external_module_1_but_cannot_be_named,
                diagnostics.Return_type_of_public_static_method_from_exported_class_has_or_is_using_name_0_from_private_module_1,
                diagnostics.Return_type_of_public_static_method_from_exported_class_has_or_is_using_private_name_0
            )
        elseif node.parent.kind == Kind.ClassDeclaration then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Return_type_of_public_method_from_exported_class_has_or_is_using_name_0_from_external_module_1_but_cannot_be_named,
                diagnostics.Return_type_of_public_method_from_exported_class_has_or_is_using_name_0_from_private_module_1,
                diagnostics.Return_type_of_public_method_from_exported_class_has_or_is_using_private_name_0
            )
        else
            -- Interfaces cannot have return types that cannot be named
            return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
                symbolAccessibilityResult,
                diagnostics.Return_type_of_method_from_exported_interface_has_or_is_using_name_0_from_private_module_1,
                diagnostics.Return_type_of_method_from_exported_interface_has_or_is_using_private_name_0
            )
        end
    elseif kind == Kind.FunctionDeclaration then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Return_type_of_exported_function_has_or_is_using_name_0_from_external_module_1_but_cannot_be_named,
            diagnostics.Return_type_of_exported_function_has_or_is_using_name_0_from_private_module_1,
            diagnostics.Return_type_of_exported_function_has_or_is_using_private_name_0
        )
    else
        error("This is unknown kind for signature: " .. ast.Kind_String(node.kind), 0)
    end
end

function declarations.getParameterDeclarationTypeVisibilityDiagnosticMessage(node, symbolAccessibilityResult)
    local kind = node.parent.kind
    if kind == Kind.Constructor then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Parameter_0_of_constructor_from_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Parameter_0_of_constructor_from_exported_class_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Parameter_0_of_constructor_from_exported_class_has_or_is_using_private_name_1
        )
    elseif kind == Kind.ConstructSignature or kind == Kind.ConstructorType then
        -- Interfaces cannot have parameter types that cannot be named
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Parameter_0_of_constructor_signature_from_exported_interface_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Parameter_0_of_constructor_signature_from_exported_interface_has_or_is_using_private_name_1
        )
    elseif kind == Kind.CallSignature then
        -- Interfaces cannot have parameter types that cannot be named
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Parameter_0_of_call_signature_from_exported_interface_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Parameter_0_of_call_signature_from_exported_interface_has_or_is_using_private_name_1
        )
    elseif kind == Kind.IndexSignature then
        -- Interfaces cannot have parameter types that cannot be named
        return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
            symbolAccessibilityResult,
            diagnostics.Parameter_0_of_index_signature_from_exported_interface_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Parameter_0_of_index_signature_from_exported_interface_has_or_is_using_private_name_1
        )
    elseif kind == Kind.MethodDeclaration or kind == Kind.MethodSignature then
        if ast.IsStatic(node.parent) then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Parameter_0_of_public_static_method_from_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Parameter_0_of_public_static_method_from_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Parameter_0_of_public_static_method_from_exported_class_has_or_is_using_private_name_1
            )
        elseif node.parent.parent.kind == Kind.ClassDeclaration then
            return declarations.selectDiagnosticBasedOnModuleName(
                symbolAccessibilityResult,
                diagnostics.Parameter_0_of_public_method_from_exported_class_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
                diagnostics.Parameter_0_of_public_method_from_exported_class_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Parameter_0_of_public_method_from_exported_class_has_or_is_using_private_name_1
            )
        else
            -- Interfaces cannot have parameter types that cannot be named
            return declarations.selectDiagnosticBasedOnModuleNameNoNameCheck(
                symbolAccessibilityResult,
                diagnostics.Parameter_0_of_method_from_exported_interface_has_or_is_using_name_1_from_private_module_2,
                diagnostics.Parameter_0_of_method_from_exported_interface_has_or_is_using_private_name_1
            )
        end
    elseif kind == Kind.FunctionDeclaration or kind == Kind.FunctionType or kind == Kind.ArrowFunction or kind == Kind.FunctionExpression then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Parameter_0_of_exported_function_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Parameter_0_of_exported_function_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Parameter_0_of_exported_function_has_or_is_using_private_name_1
        )
    elseif kind == Kind.SetAccessor or kind == Kind.GetAccessor then
        return declarations.selectDiagnosticBasedOnModuleName(
            symbolAccessibilityResult,
            diagnostics.Parameter_0_of_accessor_has_or_is_using_name_1_from_external_module_2_but_cannot_be_named,
            diagnostics.Parameter_0_of_accessor_has_or_is_using_name_1_from_private_module_2,
            diagnostics.Parameter_0_of_accessor_has_or_is_using_private_name_1
        )
    else
        error("Unknown parent for parameter: " .. ast.Kind_String(node.parent.kind), 0)
    end
end

function declarations.getTypeParameterConstraintVisibilityDiagnosticMessage(node, _)
    -- Type parameter constraints are named by user so we should always be able to name it
    local kind = node.parent.kind
    if kind == Kind.ClassDeclaration then
        return diagnostics.Type_parameter_0_of_exported_class_has_or_is_using_private_name_1
    elseif kind == Kind.InterfaceDeclaration then
        return diagnostics.Type_parameter_0_of_exported_interface_has_or_is_using_private_name_1
    elseif kind == Kind.MappedType then
        return diagnostics.Type_parameter_0_of_exported_mapped_object_type_is_using_private_name_1
    elseif kind == Kind.ConstructorType or kind == Kind.ConstructSignature then
        return diagnostics.Type_parameter_0_of_constructor_signature_from_exported_interface_has_or_is_using_private_name_1
    elseif kind == Kind.CallSignature then
        return diagnostics.Type_parameter_0_of_call_signature_from_exported_interface_has_or_is_using_private_name_1
    elseif kind == Kind.MethodDeclaration or kind == Kind.MethodSignature then
        if ast.IsStatic(node.parent) then
            return diagnostics.Type_parameter_0_of_public_static_method_from_exported_class_has_or_is_using_private_name_1
        elseif node.parent.parent.kind == Kind.ClassDeclaration then
            return diagnostics.Type_parameter_0_of_public_method_from_exported_class_has_or_is_using_private_name_1
        else
            return diagnostics.Type_parameter_0_of_method_from_exported_interface_has_or_is_using_private_name_1
        end
    elseif kind == Kind.FunctionType or kind == Kind.FunctionDeclaration then
        return diagnostics.Type_parameter_0_of_exported_function_has_or_is_using_private_name_1
    elseif kind == Kind.InferType then
        return diagnostics.Extends_clause_for_inferred_type_0_has_or_is_using_private_name_1
    elseif kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration then
        return diagnostics.Type_parameter_0_of_exported_type_alias_has_or_is_using_private_name_1
    else
        error("This is unknown parent for type parameter: " .. ast.Kind_String(node.parent.kind), 0)
    end
end

local relatedSuggestionByDeclarationKind = {
    [Kind.ArrowFunction] = diagnostics.Add_a_return_type_to_the_function_expression,
    [Kind.FunctionExpression] = diagnostics.Add_a_return_type_to_the_function_expression,
    [Kind.MethodDeclaration] = diagnostics.Add_a_return_type_to_the_method,
    [Kind.GetAccessor] = diagnostics.Add_a_return_type_to_the_get_accessor_declaration,
    [Kind.SetAccessor] = diagnostics.Add_a_type_to_parameter_of_the_set_accessor_declaration,
    [Kind.FunctionDeclaration] = diagnostics.Add_a_return_type_to_the_function_declaration,
    [Kind.ConstructSignature] = diagnostics.Add_a_return_type_to_the_function_declaration,
    [Kind.Parameter] = diagnostics.Add_a_type_annotation_to_the_parameter_0,
    [Kind.VariableDeclaration] = diagnostics.Add_a_type_annotation_to_the_variable_0,
    [Kind.PropertyDeclaration] = diagnostics.Add_a_type_annotation_to_the_property_0,
    [Kind.PropertySignature] = diagnostics.Add_a_type_annotation_to_the_property_0,
    [Kind.ExportAssignment] = diagnostics.Move_the_expression_in_default_export_to_a_variable_and_add_a_type_annotation_to_it,
}

function declarations.getRelatedSuggestionByDeclarationKind(kind)
    return relatedSuggestionByDeclarationKind[kind]
end

local errorByDeclarationKind = {
    [Kind.FunctionExpression] = diagnostics.Function_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations,
    [Kind.FunctionDeclaration] = diagnostics.Function_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations,
    [Kind.ArrowFunction] = diagnostics.Function_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations,
    [Kind.MethodDeclaration] = diagnostics.Method_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations,
    [Kind.ConstructSignature] = diagnostics.Method_must_have_an_explicit_return_type_annotation_with_isolatedDeclarations,
    [Kind.GetAccessor] = diagnostics.At_least_one_accessor_must_have_an_explicit_type_annotation_with_isolatedDeclarations,
    [Kind.SetAccessor] = diagnostics.At_least_one_accessor_must_have_an_explicit_type_annotation_with_isolatedDeclarations,
    [Kind.Parameter] = diagnostics.Parameter_must_have_an_explicit_type_annotation_with_isolatedDeclarations,
    [Kind.VariableDeclaration] = diagnostics.Variable_must_have_an_explicit_type_annotation_with_isolatedDeclarations,
    [Kind.PropertyDeclaration] = diagnostics.Property_must_have_an_explicit_type_annotation_with_isolatedDeclarations,
    [Kind.PropertySignature] = diagnostics.Property_must_have_an_explicit_type_annotation_with_isolatedDeclarations,
    [Kind.ComputedPropertyName] = diagnostics.Computed_property_names_on_class_or_object_literals_cannot_be_inferred_with_isolatedDeclarations,
    [Kind.SpreadAssignment] = diagnostics.Objects_that_contain_spread_assignments_can_t_be_inferred_with_isolatedDeclarations,
    [Kind.ShorthandPropertyAssignment] = diagnostics.Objects_that_contain_shorthand_properties_can_t_be_inferred_with_isolatedDeclarations,
    [Kind.ArrayLiteralExpression] = diagnostics.Only_const_arrays_can_be_inferred_with_isolatedDeclarations,
    [Kind.ExportAssignment] = diagnostics.Default_exports_can_t_be_inferred_with_isolatedDeclarations,
    [Kind.SpreadElement] = diagnostics.Arrays_with_spread_elements_can_t_inferred_with_isolatedDeclarations,
}

function declarations.getErrorByDeclarationKind(kind)
    return errorByDeclarationKind[kind]
end

function declarations.isDeclarationEnoughForErrors(node)
    return ast.IsExportAssignment(node) or ast.IsStatement(node) or ast.IsVariableDeclaration(node) or ast.IsPropertyDeclaration(node) or ast.IsParameterDeclaration(node)
end

function declarations.isFunctionLikeAndNotConstructor(node)
    return ast.IsFunctionLikeDeclaration(node) and not ast.IsConstructorDeclaration(node)
end

function declarations.findNearestDeclaration(node)
    local result = ast.FindAncestor(node, declarations.isDeclarationEnoughForErrors)
    if result == nil then
        return nil
    end
    if ast.IsExportAssignment(result) then
        return result
    end
    if ast.IsReturnStatement(result) then
        return ast.FindAncestor(result, declarations.isFunctionLikeAndNotConstructor)
    end
    if ast.IsStatement(result) then
        return nil
    end
    return result
end

function declarations.createEntityInTypeNodeError(node)
    local diag = declarations.createDiagnosticForNode(node, diagnostics.Type_containing_private_name_0_can_t_be_used_with_isolatedDeclarations, scanner.GetTextOfNode(node))
    declarations.addParentDeclarationRelatedInfo(node, diag)
    return diag
end

function declarations.addParentDeclarationRelatedInfo(node, diag)
    local parentDeclaration = declarations.findNearestDeclaration(node)
    if parentDeclaration == nil then
        return
    end
    local targetStr = ""
    if not ast.IsExportAssignment(parentDeclaration) and parentDeclaration:Name() ~= nil then
        targetStr = scanner.GetTextOfNode(parentDeclaration:Name())
    end
    diag:AddRelatedInfo(declarations.createDiagnosticForNode(parentDeclaration, declarations.getRelatedSuggestionByDeclarationKind(parentDeclaration.kind), targetStr))
end

function declarations.createAccessorTypeError(node)
    local allDeclarations = ast.GetAllAccessorDeclarationsForDeclaration(node, node:Symbol().declarations)
    local getAccessor = allDeclarations.getAccessor
    local setAccessor = allDeclarations.setAccessor
    local targetNode = node
    if ast.IsSetAccessorDeclaration(node) and core.Len(node:Parameters()) > 0 then
        targetNode = node:Parameters()[1]
    end
    local diag = declarations.createDiagnosticForNode(targetNode, declarations.getErrorByDeclarationKind(node.kind))
    if setAccessor ~= nil then
        diag:AddRelatedInfo(declarations.createDiagnosticForNode(setAccessor, declarations.getRelatedSuggestionByDeclarationKind(setAccessor.kind)))
    end
    if getAccessor ~= nil then
        diag:AddRelatedInfo(declarations.createDiagnosticForNode(getAccessor, declarations.getRelatedSuggestionByDeclarationKind(getAccessor.kind)))
    end
    return diag
end

function declarations.createObjectLiteralError(node)
    local diag = declarations.createDiagnosticForNode(node, declarations.getErrorByDeclarationKind(node.kind))
    declarations.addParentDeclarationRelatedInfo(node, diag)
    return diag
end

function declarations.createArrayLiteralError(node)
    local diag = declarations.createDiagnosticForNode(node, declarations.getErrorByDeclarationKind(node.kind))
    declarations.addParentDeclarationRelatedInfo(node, diag)
    return diag
end

function declarations.createReturnTypeError(node)
    local diag = declarations.createDiagnosticForNode(node, declarations.getErrorByDeclarationKind(node.kind))
    declarations.addParentDeclarationRelatedInfo(node, diag)
    diag:AddRelatedInfo(declarations.createDiagnosticForNode(node, declarations.getRelatedSuggestionByDeclarationKind(node.kind)))
    return diag
end

function declarations.createBindingElementError(node)
    return declarations.createDiagnosticForNode(node, diagnostics.Binding_elements_with_initializers_can_t_be_exported_directly_with_isolatedDeclarations)
end

function declarations.createVariableOrPropertyError(node)
    local diag = declarations.createDiagnosticForNode(node, declarations.getErrorByDeclarationKind(node.kind))
    diag:AddRelatedInfo(declarations.createDiagnosticForNode(node, declarations.getRelatedSuggestionByDeclarationKind(node.kind), scanner.GetTextOfNode(node:Name())))
    return diag
end

function declarations.createExpressionError(node)
    return declarations.createExpressionErrorEx(node, nil)
end

function declarations.createClassExpressionError(node)
    return declarations.createExpressionErrorEx(node, diagnostics.Inference_from_class_expressions_is_not_supported_with_isolatedDeclarations)
end

function declarations.isParentForIDDIagnostic(node)
    if ast.IsExportAssignment(node) then
        return FindAncestorResult.FindAncestorTrue
    end
    if ast.IsStatement(node) then
        return FindAncestorResult.FindAncestorQuit
    end
    return ast.ToFindAncestorResult(not ast.IsParenthesizedExpression(node) and not ast.IsAssertionExpression(node))
end

function declarations.createExpressionErrorEx(node, diagnosticMessage)
    local parentDeclaration = declarations.findNearestDeclaration(node)
    if parentDeclaration == nil then
        if diagnosticMessage == nil then
            diagnosticMessage = diagnostics.Expression_type_can_t_be_inferred_with_isolatedDeclarations
        end
        return declarations.createDiagnosticForNode(node, diagnosticMessage)
    end

    local targetStr = ""
    if not ast.IsExportAssignment(parentDeclaration) and parentDeclaration:Name() ~= nil then
        targetStr = scanner.GetTextOfNode(parentDeclaration:Name())
    end
    local parent = ast.FindAncestorOrQuit(node.parent, declarations.isParentForIDDIagnostic)

    if parentDeclaration == parent then
        if diagnosticMessage == nil then
            diagnosticMessage = declarations.getErrorByDeclarationKind(parentDeclaration.kind)
        end
        local diag = declarations.createDiagnosticForNode(node, diagnosticMessage)
        diag:AddRelatedInfo(declarations.createDiagnosticForNode(parentDeclaration, declarations.getRelatedSuggestionByDeclarationKind(parentDeclaration.kind), targetStr))
        return diag
    end
    if diagnosticMessage == nil then
        diagnosticMessage = diagnostics.Expression_type_can_t_be_inferred_with_isolatedDeclarations
    end
    local diag = declarations.createDiagnosticForNode(node, diagnosticMessage)
    diag:AddRelatedInfo(declarations.createDiagnosticForNode(parentDeclaration, declarations.getRelatedSuggestionByDeclarationKind(parentDeclaration.kind), targetStr))
    diag:AddRelatedInfo(declarations.createDiagnosticForNode(node, diagnostics.Add_satisfies_and_a_type_assertion_to_this_expression_satisfies_T_as_T_to_make_the_type_explicit))
    return diag
end

function declarations.createGetIsolatedDeclarationErrors(resolver)
    local function createParameterError(node)
        if ast.IsSetAccessorDeclaration(node.parent) then
            return declarations.createAccessorTypeError(node.parent)
        end
        local addUndefined = resolver:RequiresAddingImplicitUndefinedUnsafe(node, nil, nil) -- skip checker lock - node builder will already have one
        if not addUndefined and node:Initializer() ~= nil then
            return declarations.createExpressionError(node:Initializer())
        end
        local message = declarations.getErrorByDeclarationKind(node.kind)
        if addUndefined then
            message = diagnostics.Declaration_emit_for_this_parameter_requires_implicitly_adding_undefined_to_its_type_This_is_not_supported_with_isolatedDeclarations
        end
        local diag = declarations.createDiagnosticForNode(node, message)
        local targetStr = scanner.GetTextOfNode(node:Name())
        diag:AddRelatedInfo(declarations.createDiagnosticForNode(node, declarations.getRelatedSuggestionByDeclarationKind(node.kind), targetStr))
        return diag
    end

    return function(node)
        local heritageClause = ast.FindAncestor(node, ast.IsHeritageClause)
        if heritageClause ~= nil then
            return declarations.createDiagnosticForNode(node, diagnostics.Extends_clause_can_t_contain_an_expression_with_isolatedDeclarations)
        end
        if ast.IsPartOfTypeNode(node) or ast.IsTypeQueryNode(node) then
            return declarations.createEntityInTypeNodeError(node)
        end
        if ast.IsEntityName(node) or ast.IsEntityNameExpression(node) then
            return declarations.createEntityInTypeNodeError(node)
        end
        local kind = node.kind
        if kind == Kind.GetAccessor or kind == Kind.SetAccessor then
            return declarations.createAccessorTypeError(node)
        elseif kind == Kind.ComputedPropertyName or kind == Kind.ShorthandPropertyAssignment or kind == Kind.SpreadAssignment then
            return declarations.createObjectLiteralError(node)
        elseif kind == Kind.ArrayLiteralExpression or kind == Kind.SpreadElement then
            return declarations.createArrayLiteralError(node)
        elseif kind == Kind.MethodDeclaration or kind == Kind.ConstructSignature or kind == Kind.FunctionExpression or kind == Kind.ArrowFunction or kind == Kind.FunctionDeclaration then
            return declarations.createReturnTypeError(node)
        elseif kind == Kind.BindingElement then
            return declarations.createBindingElementError(node)
        elseif kind == Kind.PropertyDeclaration or kind == Kind.VariableDeclaration then
            return declarations.createVariableOrPropertyError(node)
        elseif kind == Kind.Parameter then
            return createParameterError(node)
        elseif kind == Kind.PropertyAssignment then
            return declarations.createExpressionError(node:Initializer())
        elseif kind == Kind.ClassExpression then
            return declarations.createClassExpressionError(node)
        else
            return declarations.createExpressionError(node)
        end
    end
end
