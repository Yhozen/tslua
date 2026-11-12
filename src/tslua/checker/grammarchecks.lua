local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local ModifierFlags = ast.ModifierFlags
local TokenFlags = ast.TokenFlags
local FunctionFlags = ast.FunctionFlags
local TypeFlags = checker.TypeFlags
local DeclarationMeaning = checker.DeclarationMeaning
local ModuleKind = core.ModuleKind
local ScriptTarget = core.ScriptTarget
local Tristate = core.Tristate

function Checker:grammarErrorOnFirstToken(node, message, ...)
    local sourceFile = ast.GetSourceFileOfNode(node)
    if not self:hasParseDiagnostics(sourceFile) then
        local span = scanner.GetRangeOfTokenAtPosition(sourceFile, node:Pos())
        self:addDiagnostic(ast.NewDiagnostic(sourceFile, span, message, ...))
        return true
    end
    return false
end

function Checker:grammarErrorAtPos(nodeForSourceFile, start, length, message, ...)
    local sourceFile = ast.GetSourceFileOfNode(nodeForSourceFile)
    if not self:hasParseDiagnostics(sourceFile) then
        self:addDiagnostic(ast.NewDiagnostic(sourceFile, core.NewTextRange(start, start + length), message, ...))
        return true
    end
    return false
end

function Checker:grammarErrorOnNode(node, message, ...)
    local sourceFile = ast.GetSourceFileOfNode(node)
    if not self:hasParseDiagnostics(sourceFile) then
        self:error(node, message, ...)
        return true
    end
    return false
end

function Checker:grammarErrorOnNodeSkippedOnNoEmit(node, message, ...)
    local sourceFile = ast.GetSourceFileOfNode(node)
    if not self:hasParseDiagnostics(sourceFile) then
        local d = checker.NewDiagnosticForNode(node, message, ...)
        d:SetSkippedOnNoEmit()
        self:addDiagnostic(d)
        return true
    end
    return false
end

function checker.getIdentifierFromEntityNameExpression(node)
    if node.kind == Kind.Identifier then
        return node
    elseif node.kind == Kind.PropertyAccessExpression then
        return node:AsPropertyAccessExpression():Name()
    end
    return nil
end

function Checker:checkGrammarRegularExpressionLiteral(node)
    local c = self
    local sourceFile = ast.GetSourceFileOfNode(node)
    if not c:hasParseDiagnostics(sourceFile) then
        local lastError
        if c.regExpScanner == nil then
            c.regExpScanner = scanner.NewScanner()
        end
        c.regExpScanner:SetScriptTarget(c.languageVersion)
        c.regExpScanner:SetLanguageVariant(sourceFile.languageVariant)
        c.regExpScanner:SetOnError(function(message, start, length, ...)
            if message:Category() == diagnostics.Category.Message and lastError ~= nil and start == lastError:Pos() and length == lastError:Len() then
                -- For providing spelling suggestions.
                local err = ast.NewDiagnostic(nil, core.NewTextRange(start, start + length), message, ...)
                lastError:AddRelatedInfo(err)
            elseif lastError == nil or start ~= lastError:Pos() then
                lastError = ast.NewDiagnostic(sourceFile, core.NewTextRange(start, start + length), message, ...)
                lastError = c:addDiagnostic(lastError)
            end
        end)
        c.regExpScanner:SetText(sourceFile:Text())
        c.regExpScanner:ResetTokenState(node:Pos())
        c.regExpScanner:Scan()
        local tokenIsRegularExpressionLiteral = c.regExpScanner:ReScanSlashToken(true) == Kind.RegularExpressionLiteral
        c.regExpScanner:SetText("")
        c.regExpScanner:SetOnError(nil)
        debug.Assert(tokenIsRegularExpressionLiteral)
        return lastError ~= nil
    end
    return false
end

function Checker:checkGrammarPrivateIdentifierExpression(privId)
    local privIdAsNode = privId
    if ast.GetContainingClass(privId) == nil then
        return self:grammarErrorOnNode(privId, diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies)
    end

    if not ast.IsForInStatement(privId.parent) then
        if not ast.IsExpressionNode(privIdAsNode) then
            return self:grammarErrorOnNode(privIdAsNode, diagnostics.Private_identifiers_are_only_allowed_in_class_bodies_and_may_only_be_used_as_part_of_a_class_member_declaration_property_access_or_on_the_left_hand_side_of_an_in_expression)
        end

        local isInOperation = ast.IsBinaryExpression(privId.parent) and privId.parent.operatorToken.kind == Kind.InKeyword
        if self:getSymbolForPrivateIdentifierExpression(privIdAsNode) == nil and not isInOperation then
            return self:grammarErrorOnNode(privIdAsNode, diagnostics.Cannot_find_name_0, privId.text)
        end
    end

    return false
end

function Checker:checkGrammarMappedType(node)
    if core.Len(node.members and node.members.nodes) > 0 then
        return self:grammarErrorOnNode(node.members.nodes[1], diagnostics.A_mapped_type_may_not_declare_properties_or_methods)
    end
    return false
end

function Checker:checkGrammarDecorator(decorator)
    local sourceFile = ast.GetSourceFileOfNode(decorator)
    if not self:hasParseDiagnostics(sourceFile) then
        local node = decorator.expression

        -- DecoratorParenthesizedExpression :
        --   `(` Expression `)`

        if ast.IsParenthesizedExpression(node) then
            return false
        end

        local canHaveCallExpression = true
        local errorNode
        while true do
            -- Allow TS syntax such as non-null assertions and instantiation expressions
            if ast.IsExpressionWithTypeArguments(node) or ast.IsNonNullExpression(node) then
                node = node:Expression()
                goto continue
            end

            -- DecoratorCallExpression :
            --   DecoratorMemberExpression Arguments

            if ast.IsCallExpression(node) then
                if not canHaveCallExpression then
                    errorNode = node
                end
                if node.questionDotToken ~= nil then
                    -- Even if we already have an error node, error at the `?.` token since it appears earlier.
                    errorNode = node.questionDotToken
                end
                node = node.expression
                canHaveCallExpression = false
                goto continue
            end

            -- DecoratorMemberExpression :
            --   IdentifierReference
            --   DecoratorMemberExpression `.` IdentifierName
            --   DecoratorMemberExpression `.` PrivateIdentifier

            if ast.IsPropertyAccessExpression(node) then
                if node.questionDotToken ~= nil then
                    -- Even if we already have an error node, error at the `?.` token since it appears earlier.
                    errorNode = node.questionDotToken
                end
                node = node.expression
                canHaveCallExpression = false
                goto continue
            end

            if not ast.IsIdentifier(node) then
                -- Even if we already have an error node, error at this node since it appears earlier.
                errorNode = node
            end

            do
                break
            end
            ::continue::
        end

        if errorNode ~= nil then
            local err = self:error(decorator.expression, diagnostics.Expression_must_be_enclosed_in_parentheses_to_be_used_as_a_decorator)
            err:AddRelatedInfo(checker.createDiagnosticForNode(errorNode, diagnostics.Invalid_syntax_in_decorator))
            return true
        end
    end

    return false
end

function Checker:checkGrammarExportDeclaration(node)
    if node.isTypeOnly and node.exportClause ~= nil and node.exportClause.kind == Kind.NamedExports then
        return self:checkGrammarTypeOnlyNamedImportsOrExports(node.exportClause)
    end
    return false
end

function Checker:checkGrammarModuleElementContext(node, errorMessage)
    local isInAppropriateContext = node.parent.kind == Kind.SourceFile or node.parent.kind == Kind.ModuleBlock or node.parent.kind == Kind.ModuleDeclaration
    if not isInAppropriateContext then
        self:grammarErrorOnFirstToken(node, errorMessage)
    end
    return not isInAppropriateContext
end

function Checker:checkGrammarModifiers(node)
    local c = self
    if node:Modifiers() == nil then
        return false
    end
    if c:reportObviousDecoratorErrors(node) or c:reportObviousModifierErrors(node) then
        return true
    end
    if ast.IsThisParameter(node) then
        return c:grammarErrorOnFirstToken(node, diagnostics.Neither_decorators_nor_modifiers_may_be_applied_to_this_parameters)
    end
    local blockScopeKind = NodeFlags.None
    if ast.IsVariableStatement(node) then
        blockScopeKind = node.declarationList.flags & NodeFlags.BlockScoped
    end
    local lastStatic
    local lastDeclare
    local lastAsync
    local lastOverride
    local firstDecorator
    local flags = ModifierFlags.None
    local sawExportBeforeDecorators = false
    -- We parse decorators and modifiers in four contiguous chunks:
    -- [...leadingDecorators, ...leadingModifiers, ...trailingDecorators, ...trailingModifiers]. It is an error to
    -- have both leading and trailing decorators.
    local hasLeadingDecorators = false
    local modifiers = node:ModifierNodes()
    for _, modifier in ipairs(modifiers or {}) do
        local notReparsed = modifier.flags & NodeFlags.Reparsed == 0
        if ast.IsDecorator(modifier) then
            if not ast.NodeCanBeDecorated(c.legacyDecorators, node, node.parent, node.parent.parent) then
                if node.kind == Kind.MethodDeclaration and not ast.NodeIsPresent(node:Body()) then
                    return c:grammarErrorOnFirstToken(node, diagnostics.A_decorator_can_only_decorate_a_method_implementation_not_an_overload)
                else
                    return c:grammarErrorOnFirstToken(node, diagnostics.Decorators_are_not_valid_here)
                end
            elseif c.legacyDecorators and (node.kind == Kind.GetAccessor or node.kind == Kind.SetAccessor) then
                local accessors = ast.GetAllAccessorDeclarationsForDeclaration(node, c:getSymbolOfDeclaration(node).declarations)
                if ast.HasDecorators(accessors.firstAccessor) and node == accessors.secondAccessor then
                    return c:grammarErrorOnFirstToken(node, diagnostics.Decorators_cannot_be_applied_to_multiple_get_Slashset_accessors_of_the_same_name)
                end
            end

            -- if we've seen any modifiers aside from `export`, `default`, or another decorator, then this is an invalid position
            if flags & ~(ModifierFlags.ExportDefault | ModifierFlags.Decorator) ~= 0 then
                return c:grammarErrorOnNode(modifier, diagnostics.Decorators_are_not_valid_here)
            end

            -- if we've already seen leading decorators and leading modifiers, then trailing decorators are an invalid position
            if hasLeadingDecorators and flags & ModifierFlags.Modifier ~= 0 then
                if firstDecorator == nil then
                    error("Expected firstDecorator to be set", 0)
                end
                local sourceFile = ast.GetSourceFileOfNode(modifier)
                if not c:hasParseDiagnostics(sourceFile) then
                    local err = c:error(modifier, diagnostics.Decorators_may_not_appear_after_export_or_export_default_if_they_also_appear_before_export)
                    err:AddRelatedInfo(checker.createDiagnosticForNode(firstDecorator, diagnostics.Decorator_used_before_export_here))
                    return true
                end
                return false
            end

            flags = flags | ModifierFlags.Decorator

            -- if we have not yet seen a modifier, then these are leading decorators
            if flags & ModifierFlags.Modifier == 0 then
                hasLeadingDecorators = true
            elseif flags & ModifierFlags.Export ~= 0 then
                sawExportBeforeDecorators = true
            end

            if firstDecorator == nil then
                firstDecorator = modifier
            end
        else
            if modifier.kind ~= Kind.ReadonlyKeyword then
                if node.kind == Kind.PropertySignature or node.kind == Kind.MethodSignature then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_type_member, scanner.TokenToString(modifier.kind))
                end
                if node.kind == Kind.IndexSignature and (modifier.kind ~= Kind.StaticKeyword or not ast.IsClassLike(node.parent)) then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_an_index_signature, scanner.TokenToString(modifier.kind))
                end
            end
            if modifier.kind ~= Kind.InKeyword and modifier.kind ~= Kind.OutKeyword and modifier.kind ~= Kind.ConstKeyword then
                if node.kind == Kind.TypeParameter then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_type_parameter, scanner.TokenToString(modifier.kind))
                end
            end
            local mk = modifier.kind
            if mk == Kind.ConstKeyword then
                if node.kind ~= Kind.EnumDeclaration and node.kind ~= Kind.TypeParameter then
                    return c:grammarErrorOnNode(node, diagnostics.A_class_member_cannot_have_the_0_keyword, scanner.TokenToString(Kind.ConstKeyword))
                end
                local parent = node.parent
                if node.kind == Kind.TypeParameter then
                    if not (ast.IsFunctionLikeDeclaration(parent) or ast.IsClassLike(parent) or
                        ast.IsFunctionTypeNode(parent) or ast.IsConstructorTypeNode(parent) or
                        ast.IsCallSignatureDeclaration(parent) or ast.IsConstructSignatureDeclaration(parent) or
                        ast.IsMethodSignatureDeclaration(parent)) then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_can_only_appear_on_a_type_parameter_of_a_function_method_or_class, scanner.TokenToString(modifier.kind))
                    end
                end
            elseif mk == Kind.OverrideKeyword then
                -- If node.kind === SyntaxKind.Parameter, checkParameter reports an error if it's not a parameter property.
                if flags & ModifierFlags.Override ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "override")
                elseif flags & ModifierFlags.Ambient ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "override", "declare")
                elseif flags & ModifierFlags.Readonly ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "override", "readonly")
                elseif flags & ModifierFlags.Accessor ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "override", "accessor")
                elseif flags & ModifierFlags.Async ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "override", "async")
                end
                flags = flags | ModifierFlags.Override
                lastOverride = modifier
            elseif mk == Kind.PublicKeyword or mk == Kind.ProtectedKeyword or mk == Kind.PrivateKeyword then
                local text = checker.visibilityToString(ast.ModifierToFlag(modifier.kind))

                if flags & ModifierFlags.AccessibilityModifier ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.Accessibility_modifier_already_seen)
                elseif flags & ModifierFlags.Override ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, text, "override")
                elseif flags & ModifierFlags.Static ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, text, "static")
                elseif flags & ModifierFlags.Accessor ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, text, "accessor")
                elseif flags & ModifierFlags.Readonly ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, text, "readonly")
                elseif flags & ModifierFlags.Async ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, text, "async")
                elseif node.parent.kind == Kind.ModuleBlock or node.parent.kind == Kind.SourceFile then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_module_or_namespace_element, text)
                elseif flags & ModifierFlags.Abstract ~= 0 then
                    if modifier.kind == Kind.PrivateKeyword then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, text, "abstract")
                    elseif notReparsed then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, text, "abstract")
                    end
                elseif ast.IsPrivateIdentifierClassElementDeclaration(node) then
                    return c:grammarErrorOnNode(modifier, diagnostics.An_accessibility_modifier_cannot_be_used_with_a_private_identifier)
                end
                flags = flags | ast.ModifierToFlag(modifier.kind)
            elseif mk == Kind.StaticKeyword then
                if flags & ModifierFlags.Static ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "static")
                elseif flags & ModifierFlags.Readonly ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "static", "readonly")
                elseif flags & ModifierFlags.Async ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "static", "async")
                elseif flags & ModifierFlags.Accessor ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "static", "accessor")
                elseif node.parent.kind == Kind.ModuleBlock or node.parent.kind == Kind.SourceFile then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_module_or_namespace_element, "static")
                elseif node.kind == Kind.Parameter then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_parameter, "static")
                elseif flags & ModifierFlags.Abstract ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "static", "abstract")
                elseif flags & ModifierFlags.Override ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "static", "override")
                end
                flags = flags | ModifierFlags.Static
                lastStatic = modifier
            elseif mk == Kind.AccessorKeyword then
                if flags & ModifierFlags.Accessor ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "accessor")
                elseif flags & ModifierFlags.Readonly ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "accessor", "readonly")
                elseif flags & ModifierFlags.Ambient ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "accessor", "declare")
                elseif node.kind ~= Kind.PropertyDeclaration then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_accessor_modifier_can_only_appear_on_a_property_declaration)
                end

                flags = flags | ModifierFlags.Accessor
            elseif mk == Kind.ReadonlyKeyword then
                if flags & ModifierFlags.Readonly ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "readonly")
                elseif node.kind ~= Kind.PropertyDeclaration and node.kind ~= Kind.PropertySignature and node.kind ~= Kind.IndexSignature and node.kind ~= Kind.Parameter then
                    -- If node.kind === SyntaxKind.Parameter, checkParameter reports an error if it's not a parameter property.
                    return c:grammarErrorOnNode(modifier, diagnostics.X_readonly_modifier_can_only_appear_on_a_property_declaration_or_index_signature)
                elseif flags & ModifierFlags.Accessor ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "readonly", "accessor")
                end
                flags = flags | ModifierFlags.Readonly
            elseif mk == Kind.ExportKeyword then
                if c.compilerOptions.verbatimModuleSyntax == Tristate.TSTrue and node.flags & NodeFlags.Ambient == 0 and node.kind ~= Kind.TypeAliasDeclaration and node.kind ~= Kind.InterfaceDeclaration and node.kind ~= Kind.ModuleDeclaration and node.parent.kind == Kind.SourceFile and c.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) == ModuleKind.CommonJS then
                    return c:grammarErrorOnNode(modifier, diagnostics.A_top_level_export_modifier_cannot_be_used_on_value_declarations_in_a_CommonJS_module_when_verbatimModuleSyntax_is_enabled)
                end
                if flags & ModifierFlags.Export ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "export")
                elseif flags & ModifierFlags.Ambient ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "export", "declare")
                elseif flags & ModifierFlags.Abstract ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "export", "abstract")
                elseif flags & ModifierFlags.Async ~= 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "export", "async")
                elseif ast.IsClassLike(node.parent) and not ast.IsJSTypeAliasDeclaration(node) then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_class_elements_of_this_kind, "export")
                elseif node.kind == Kind.Parameter then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_parameter, "export")
                elseif blockScopeKind == NodeFlags.Using then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_using_declaration, "export")
                elseif blockScopeKind == NodeFlags.AwaitUsing then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_an_await_using_declaration, "export")
                end
                flags = flags | ModifierFlags.Export
            elseif mk == Kind.DefaultKeyword then
                local container
                if node.parent.kind == Kind.SourceFile then
                    container = node.parent
                else
                    container = node.parent.parent
                end
                if container.kind == Kind.ModuleDeclaration and not ast.IsAmbientModule(container) then
                    return c:grammarErrorOnNode(modifier, diagnostics.A_default_export_can_only_be_used_in_an_ECMAScript_style_module)
                elseif blockScopeKind == NodeFlags.Using then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_using_declaration, "default")
                elseif blockScopeKind == NodeFlags.AwaitUsing then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_an_await_using_declaration, "default")
                elseif flags & ModifierFlags.Export == 0 and notReparsed then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "export", "default")
                elseif sawExportBeforeDecorators then
                    return c:grammarErrorOnNode(firstDecorator, diagnostics.Decorators_are_not_valid_here)
                end

                flags = flags | ModifierFlags.Default
            elseif mk == Kind.DeclareKeyword then
                if flags & ModifierFlags.Ambient ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "declare")
                elseif flags & ModifierFlags.Async ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_in_an_ambient_context, "async")
                elseif flags & ModifierFlags.Override ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_in_an_ambient_context, "override")
                elseif ast.IsClassLike(node.parent) and not ast.IsPropertyDeclaration(node) then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_class_elements_of_this_kind, "declare")
                elseif node.kind == Kind.Parameter then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_parameter, "declare")
                elseif blockScopeKind == NodeFlags.Using then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_using_declaration, "declare")
                elseif blockScopeKind == NodeFlags.AwaitUsing then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_an_await_using_declaration, "declare")
                elseif (node.parent.flags & NodeFlags.Ambient ~= 0) and node.parent.kind == Kind.ModuleBlock then
                    return c:grammarErrorOnNode(modifier, diagnostics.A_declare_modifier_cannot_be_used_in_an_already_ambient_context)
                elseif ast.IsPrivateIdentifierClassElementDeclaration(node) then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_a_private_identifier, "declare")
                elseif flags & ModifierFlags.Accessor ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "declare", "accessor")
                end
                flags = flags | ModifierFlags.Ambient
                lastDeclare = modifier
            elseif mk == Kind.AbstractKeyword then
                if flags & ModifierFlags.Abstract ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "abstract")
                end
                if node.kind ~= Kind.ClassDeclaration and node.kind ~= Kind.ConstructorType then
                    if node.kind ~= Kind.MethodDeclaration and node.kind ~= Kind.PropertyDeclaration and node.kind ~= Kind.GetAccessor and node.kind ~= Kind.SetAccessor then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_abstract_modifier_can_only_appear_on_a_class_method_or_property_declaration)
                    end
                    if not (node.parent.kind == Kind.ClassDeclaration and ast.HasSyntacticModifier(node.parent, ModifierFlags.Abstract)) then
                        local message
                        if node.kind == Kind.PropertyDeclaration then
                            message = diagnostics.Abstract_properties_can_only_appear_within_an_abstract_class
                        else
                            message = diagnostics.Abstract_methods_can_only_appear_within_an_abstract_class
                        end
                        return c:grammarErrorOnNode(modifier, message)
                    end
                    if flags & ModifierFlags.Static ~= 0 then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "static", "abstract")
                    end
                    if flags & ModifierFlags.Private ~= 0 then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "private", "abstract")
                    end
                    if flags & ModifierFlags.Async ~= 0 and lastAsync ~= nil then
                        return c:grammarErrorOnNode(lastAsync, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "async", "abstract")
                    end
                    if flags & ModifierFlags.Override ~= 0 and notReparsed then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "abstract", "override")
                    end
                    if flags & ModifierFlags.Accessor ~= 0 and notReparsed then
                        return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "abstract", "accessor")
                    end
                end
                local name = node:Name()
                if name ~= nil and name.kind == Kind.PrivateIdentifier then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_a_private_identifier, "abstract")
                end

                flags = flags | ModifierFlags.Abstract
            elseif mk == Kind.AsyncKeyword then
                if flags & ModifierFlags.Async ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, "async")
                elseif flags & ModifierFlags.Ambient ~= 0 or node.parent.flags & NodeFlags.Ambient ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_in_an_ambient_context, "async")
                elseif node.kind == Kind.Parameter then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_appear_on_a_parameter, "async")
                end
                if flags & ModifierFlags.Abstract ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_cannot_be_used_with_1_modifier, "async", "abstract")
                end
                flags = flags | ModifierFlags.Async
                lastAsync = modifier
            elseif mk == Kind.InKeyword or mk == Kind.OutKeyword then
                local inOutFlag
                if modifier.kind == Kind.InKeyword then
                    inOutFlag = ModifierFlags.In
                else
                    inOutFlag = ModifierFlags.Out
                end
                local inOutText
                if modifier.kind == Kind.InKeyword then
                    inOutText = "in"
                else
                    inOutText = "out"
                end
                local parent = node.parent
                if node.kind ~= Kind.TypeParameter or parent ~= nil and not (ast.IsInterfaceDeclaration(parent) or ast.IsClassLike(parent) or ast.IsTypeOrJSTypeAliasDeclaration(parent)) then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_can_only_appear_on_a_type_parameter_of_a_class_interface_or_type_alias, inOutText)
                end
                if flags & inOutFlag ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_already_seen, inOutText)
                end
                if inOutFlag & ModifierFlags.In ~= 0 and flags & ModifierFlags.Out ~= 0 then
                    return c:grammarErrorOnNode(modifier, diagnostics.X_0_modifier_must_precede_1_modifier, "in", "out")
                end
                flags = flags | inOutFlag
            end
        end
    end

    if node.kind == Kind.Constructor then
        if flags & ModifierFlags.Static ~= 0 then
            return c:grammarErrorOnNode(lastStatic, diagnostics.X_0_modifier_cannot_appear_on_a_constructor_declaration, "static")
        end
        if flags & ModifierFlags.Override ~= 0 then
            return c:grammarErrorOnNode(lastOverride, diagnostics.X_0_modifier_cannot_appear_on_a_constructor_declaration, "override")
        end
        if flags & ModifierFlags.Async ~= 0 then
            return c:grammarErrorOnNode(lastAsync, diagnostics.X_0_modifier_cannot_appear_on_a_constructor_declaration, "async")
        end
        return false
    elseif (node.kind == Kind.ImportDeclaration or node.kind == Kind.JSImportDeclaration or node.kind == Kind.ImportEqualsDeclaration) and flags & ModifierFlags.Ambient ~= 0 then
        return c:grammarErrorOnNode(lastDeclare, diagnostics.A_0_modifier_cannot_be_used_with_an_import_declaration, "declare")
    elseif node.kind == Kind.Parameter and (flags & ModifierFlags.ParameterPropertyModifier ~= 0) and ast.IsBindingPattern(node:Name()) then
        return c:grammarErrorOnNode(node, diagnostics.A_parameter_property_may_not_be_declared_using_a_binding_pattern)
    elseif node.kind == Kind.Parameter and (flags & ModifierFlags.ParameterPropertyModifier ~= 0) and node.dotDotDotToken ~= nil then
        return c:grammarErrorOnNode(node, diagnostics.A_parameter_property_cannot_be_declared_using_a_rest_parameter)
    end
    if flags & ModifierFlags.Async ~= 0 then
        return c:checkGrammarAsyncModifier(node, lastAsync)
    end
    return false
end

function Checker:reportObviousModifierErrors(node)
    local modifier = self:findFirstIllegalModifier(node)
    if modifier == nil then
        return false
    end
    return self:grammarErrorOnFirstToken(modifier, diagnostics.Modifiers_cannot_appear_here)
end

function Checker:findFirstModifierExcept(node, allowedModifier)
    local modifier = core.Find(node:ModifierNodes(), ast.IsModifier)
    if modifier ~= nil and modifier.kind ~= allowedModifier then
        return modifier
    end
    return nil
end

local noIllegalModifierKinds = ast.kindSet(
    Kind.GetAccessor,
    Kind.SetAccessor,
    Kind.Constructor,
    Kind.PropertyDeclaration,
    Kind.PropertySignature,
    Kind.MethodDeclaration,
    Kind.MethodSignature,
    Kind.IndexSignature,
    Kind.ModuleDeclaration,
    Kind.ImportDeclaration,
    Kind.JSImportDeclaration,
    Kind.ImportEqualsDeclaration,
    Kind.ExportDeclaration,
    Kind.ExportAssignment,
    Kind.FunctionExpression,
    Kind.ArrowFunction,
    Kind.Parameter,
    Kind.TypeParameter,
    Kind.JSTypeAliasDeclaration
)

local anyModifierIllegalKinds = ast.kindSet(
    Kind.ClassStaticBlockDeclaration,
    Kind.PropertyAssignment,
    Kind.ShorthandPropertyAssignment,
    Kind.NamespaceExportDeclaration,
    Kind.MissingDeclaration
)

function Checker:findFirstIllegalModifier(node)
    if noIllegalModifierKinds[node.kind] then
        return nil
    elseif anyModifierIllegalKinds[node.kind] then
        return core.Find(node:ModifierNodes(), ast.IsModifier)
    else
        if node.parent.kind == Kind.ModuleBlock or node.parent.kind == Kind.SourceFile then
            return nil
        end
        local k = node.kind
        if k == Kind.FunctionDeclaration then
            return self:findFirstModifierExcept(node, Kind.AsyncKeyword)
        elseif k == Kind.ClassDeclaration or k == Kind.ConstructorType then
            return self:findFirstModifierExcept(node, Kind.AbstractKeyword)
        elseif k == Kind.ClassExpression or k == Kind.InterfaceDeclaration or k == Kind.TypeAliasDeclaration then
            return core.Find(node:ModifierNodes(), ast.IsModifier)
        elseif k == Kind.VariableStatement then
            if node.declarationList.flags & NodeFlags.Using ~= 0 then
                return self:findFirstModifierExcept(node, Kind.AwaitKeyword)
            end
            return core.Find(node:ModifierNodes(), ast.IsModifier)
        elseif k == Kind.EnumDeclaration then
            return self:findFirstModifierExcept(node, Kind.ConstKeyword)
        else
            error("Unhandled case in findFirstIllegalModifier.", 0)
        end
    end
end

function Checker:reportObviousDecoratorErrors(node)
    local decorator = self:findFirstIllegalDecorator(node)
    if decorator == nil then
        return false
    end
    return self:grammarErrorOnFirstToken(decorator, diagnostics.Decorators_are_not_valid_here)
end

function Checker:findFirstIllegalDecorator(node)
    if ast.CanHaveIllegalDecorators(node) then
        local decorator = core.Find(node:ModifierNodes(), ast.IsDecorator)
        return decorator
    else
        return nil
    end
end

function Checker:checkGrammarAsyncModifier(node, asyncModifier)
    local k = node.kind
    if k == Kind.MethodDeclaration or k == Kind.FunctionDeclaration or k == Kind.FunctionExpression or k == Kind.ArrowFunction then
        return false
    end

    return self:grammarErrorOnNode(asyncModifier, diagnostics.X_0_modifier_cannot_be_used_here, "async")
end

function Checker:checkGrammarForDisallowedTrailingComma(list, diag)
    if list ~= nil and list:HasTrailingComma() then
        return self:grammarErrorAtPos(list.nodes[1], list:End() - #",", #",", diag)
    end
    return false
end

function Checker:checkGrammarTypeParameterList(typeParameters, file)
    if typeParameters ~= nil and core.Len(typeParameters.nodes) == 0 then
        local start = typeParameters:Pos() - #"<"
        local end_ = scanner.SkipTrivia(file:Text(), typeParameters:End()) + #">"
        return self:grammarErrorAtPos(file, start, end_ - start, diagnostics.Type_parameter_list_cannot_be_empty)
    end
    return false
end

function Checker:checkGrammarParameterList(parameters)
    local seenOptionalParameter = false
    local parameterCount = core.Len(parameters.nodes)

    for i = 0, parameterCount - 1 do
        local parameter = parameters.nodes[i + 1]:AsParameterDeclaration()
        if parameter.dotDotDotToken ~= nil then
            if i ~= parameterCount - 1 then
                return self:grammarErrorOnNode(parameter.dotDotDotToken, diagnostics.A_rest_parameter_must_be_last_in_a_parameter_list)
            end
            if parameter.flags & NodeFlags.Ambient == 0 then
                self:checkGrammarForDisallowedTrailingComma(parameters, diagnostics.A_rest_parameter_or_binding_pattern_may_not_have_a_trailing_comma)
            end

            if parameter.questionToken ~= nil then
                return self:grammarErrorOnNode(parameter.questionToken, diagnostics.A_rest_parameter_cannot_be_optional)
            end

            if parameter.initializer ~= nil then
                return self:grammarErrorOnNode(parameter:Name(), diagnostics.A_rest_parameter_cannot_have_an_initializer)
            end
        elseif checker.isOptionalDeclaration(parameter) then
            seenOptionalParameter = true
            -- A reparsed '?' token indicates a bracketed name in @param tag
            if parameter.questionToken ~= nil and parameter.questionToken.flags & NodeFlags.Reparsed == 0 and parameter.initializer ~= nil then
                return self:grammarErrorOnNode(parameter:Name(), diagnostics.Parameter_cannot_have_question_mark_and_initializer)
            end
        elseif seenOptionalParameter and parameter.initializer == nil then
            return self:grammarErrorOnNode(parameter:Name(), diagnostics.A_required_parameter_cannot_follow_an_optional_parameter)
        end
    end

    return false
end

function Checker:checkGrammarForUseStrictSimpleParameterList(node)
    if self.languageVersion >= ScriptTarget.ES2016 then
        local body = node:Body()
        local useStrictDirective
        if body ~= nil and ast.IsBlock(body) then
            useStrictDirective = binder.FindUseStrictPrologue(ast.GetSourceFileOfNode(node), body:Statements())
        end
        if useStrictDirective ~= nil then
            local nonSimpleParameters = core.Filter(node:Parameters(), function(n)
                local parameter = n:AsParameterDeclaration()
                return parameter.initializer ~= nil or ast.IsBindingPattern(parameter:Name()) or checker.isRestParameter(parameter)
            end)
            if core.Len(nonSimpleParameters) ~= 0 then
                for _, parameter in ipairs(nonSimpleParameters) do
                    local err = self:error(parameter, diagnostics.This_parameter_is_not_allowed_with_use_strict_directive)
                    err:AddRelatedInfo(checker.createDiagnosticForNode(useStrictDirective, diagnostics.X_use_strict_directive_used_here))
                end

                local err = self:error(useStrictDirective, diagnostics.X_use_strict_directive_cannot_be_used_with_non_simple_parameter_list)
                for index1, parameter in ipairs(nonSimpleParameters) do
                    local relatedMessage
                    if index1 == 1 then
                        relatedMessage = diagnostics.Non_simple_parameter_declared_here
                    else
                        relatedMessage = diagnostics.X_and_here
                    end
                    err:AddRelatedInfo(checker.createDiagnosticForNode(parameter, relatedMessage))
                end

                return true
            end
        end
    end
    return false
end

function Checker:checkGrammarFunctionLikeDeclaration(node)
    -- Prevent cascading error by short-circuit
    local file = ast.GetSourceFileOfNode(node)
    local funcData = node:FunctionLikeData()
    return self:checkGrammarModifiers(node) or self:checkGrammarTypeParameterList(funcData.typeParameters, file) or
        self:checkGrammarParameterList(funcData.parameters) or self:checkGrammarArrowFunction(node, file) or
        (ast.IsFunctionLikeDeclaration(node) and self:checkGrammarForUseStrictSimpleParameterList(node))
end

function Checker:checkGrammarClassLikeDeclaration(node)
    local file = ast.GetSourceFileOfNode(node)
    return self:checkGrammarClassDeclarationHeritageClauses(node, file) or self:checkGrammarTypeParameterList(node:TypeParameterList(), file)
end

-- Go strings.ContainsFunc(s, stringutil.IsLineBreak)
local function containsLineBreak(s)
    local pos = 0
    while pos < #s do
        local r, size = core.DecodeRune(s, pos)
        if stringutil.IsLineBreak(r) then
            return true
        end
        pos = pos + size
    end
    return false
end

function Checker:checkGrammarArrowFunction(node, file)
    if not ast.IsArrowFunction(node) then
        return false
    end

    local arrowFunc = node:AsArrowFunction()
    local typeParameters = arrowFunc.typeParameters
    if typeParameters ~= nil then
        local typeParamNodes = typeParameters.nodes
        local hasConstraint = core.Len(typeParamNodes) > 0 and typeParamNodes[1]:AsTypeParameterDeclaration().constraint ~= nil
        if not (core.Len(typeParamNodes) > 1 or typeParameters:HasTrailingComma() or hasConstraint) then
            if tspath.FileExtensionIsOneOf(file:FileName(), { tspath.ExtensionMts, tspath.ExtensionCts }) then
                -- TODO(danielr): should we return early here?
                self:grammarErrorOnNode(typeParameters.nodes[1], diagnostics.This_syntax_is_reserved_in_files_with_the_mts_or_cts_extension_Add_a_trailing_comma_or_explicit_constraint)
            end
        end
    end

    local equalsGreaterThanToken = arrowFunc.equalsGreaterThanToken
    local arrowFullText = string.sub(file:Text(), equalsGreaterThanToken:Pos() + 1, equalsGreaterThanToken:End())
    return containsLineBreak(arrowFullText) and
        self:grammarErrorOnNode(equalsGreaterThanToken, diagnostics.Line_terminator_not_permitted_before_arrow)
end

function Checker:checkGrammarIndexSignatureParameters(node)
    local c = self
    local paramNodes = node.parameters.nodes

    if core.Len(paramNodes) == 0 then
        return c:grammarErrorOnNode(node, diagnostics.An_index_signature_must_have_exactly_one_parameter)
    end

    local parameter = paramNodes[1]:AsParameterDeclaration()
    if #paramNodes ~= 1 then
        return c:grammarErrorOnNode(parameter:Name(), diagnostics.An_index_signature_must_have_exactly_one_parameter)
    end

    c:checkGrammarForDisallowedTrailingComma(node.parameters, diagnostics.An_index_signature_cannot_have_a_trailing_comma)
    if parameter.dotDotDotToken ~= nil then
        return c:grammarErrorOnNode(parameter.dotDotDotToken, diagnostics.An_index_signature_cannot_have_a_rest_parameter)
    end
    if parameter:Modifiers() ~= nil then
        return c:grammarErrorOnNode(parameter:Name(), diagnostics.An_index_signature_parameter_cannot_have_an_accessibility_modifier)
    end
    if parameter.questionToken ~= nil then
        return c:grammarErrorOnNode(parameter.questionToken, diagnostics.An_index_signature_parameter_cannot_have_a_question_mark)
    end
    if parameter.initializer ~= nil then
        return c:grammarErrorOnNode(parameter:Name(), diagnostics.An_index_signature_parameter_cannot_have_an_initializer)
    end
    local typeNode = parameter.type
    if typeNode == nil then
        return c:grammarErrorOnNode(parameter:Name(), diagnostics.An_index_signature_parameter_must_have_a_type_annotation)
    end
    local t = c:getTypeFromTypeNode(typeNode)
    if checker.someType(t, function(ty)
        return ty.flags & TypeFlags.StringOrNumberLiteralOrUnique ~= 0
    end) or c:isGenericType(t) then
        return c:grammarErrorOnNode(parameter:Name(), diagnostics.An_index_signature_parameter_type_cannot_be_a_literal_type_or_generic_type_Consider_using_a_mapped_object_type_instead)
    end
    if not checker.everyType(t, function(ty) return c:isValidIndexKeyType(ty) end) then
        return c:grammarErrorOnNode(parameter:Name(), diagnostics.An_index_signature_parameter_type_must_be_string_number_symbol_or_a_template_literal_type)
    end
    if node.type == nil then
        return c:grammarErrorOnNode(node, diagnostics.An_index_signature_must_have_a_type_annotation)
    end
    return false
end

function Checker:checkGrammarIndexSignature(node)
    -- Prevent cascading error by short-circuit
    return self:checkGrammarModifiers(node) or self:checkGrammarIndexSignatureParameters(node)
end

function Checker:checkGrammarForAtLeastOneTypeArgument(node, typeArguments)
    if typeArguments ~= nil and core.Len(typeArguments.nodes) == 0 then
        local sourceFile = ast.GetSourceFileOfNode(node)
        local start = typeArguments:Pos() - #"<"
        local end_ = scanner.SkipTrivia(sourceFile:Text(), typeArguments:End()) + #">"
        return self:grammarErrorAtPos(sourceFile, start, end_ - start, diagnostics.Type_argument_list_cannot_be_empty)
    end
    return false
end

function Checker:checkGrammarTypeArguments(node, typeArguments)
    return self:checkGrammarForDisallowedTrailingComma(typeArguments, diagnostics.Trailing_comma_not_allowed) or self:checkGrammarForAtLeastOneTypeArgument(node, typeArguments)
end

function Checker:checkGrammarTaggedTemplateChain(node)
    if node.questionDotToken ~= nil or node.flags & NodeFlags.OptionalChain ~= 0 then
        return self:grammarErrorOnNode(node.template, diagnostics.Tagged_template_expressions_are_not_permitted_in_an_optional_chain)
    end
    return false
end

function Checker:checkGrammarHeritageClause(node)
    local types = node.types
    if self:checkGrammarForDisallowedTrailingComma(types, diagnostics.Trailing_comma_not_allowed) then
        return true
    end
    if types ~= nil and core.Len(types.nodes) == 0 then
        local listType = scanner.TokenToString(node.token)
        -- TODO(danielr): why not error on the token?
        return self:grammarErrorAtPos(node, types:Pos(), 0, diagnostics.X_0_list_cannot_be_empty, listType)
    end

    for _, n in ipairs(types.nodes or {}) do
        if self:checkGrammarExpressionWithTypeArguments(n) then
            return true
        end
    end
    return false
end

function Checker:checkGrammarExpressionWithTypeArguments(node)
    if ast.IsExpressionWithTypeArguments(node) and node:Expression().kind == Kind.ImportKeyword and node:TypeArgumentList() ~= nil then
        return self:grammarErrorOnNode(node, diagnostics.This_use_of_import_is_invalid_import_calls_can_be_written_but_they_must_have_parentheses_and_cannot_have_type_arguments)
    end
    return self:checkGrammarTypeArguments(node, node:TypeArgumentList())
end

function Checker:checkGrammarClassDeclarationHeritageClauses(node, file)
    local seenExtendsClause = false
    local seenImplementsClause = false

    local classLikeData = node:ClassLikeData()

    if not self:checkGrammarModifiers(node) and classLikeData.heritageClauses ~= nil then
        for _, heritageClauseNode in ipairs(classLikeData.heritageClauses.nodes or {}) do
            local heritageClause = heritageClauseNode:AsHeritageClause()
            if heritageClause.token == Kind.ExtendsKeyword then
                if seenExtendsClause then
                    return self:grammarErrorOnFirstToken(heritageClauseNode, diagnostics.X_extends_clause_already_seen)
                end

                if seenImplementsClause then
                    return self:grammarErrorOnFirstToken(heritageClauseNode, diagnostics.X_extends_clause_must_precede_implements_clause)
                end

                local typeNodes = heritageClause.types.nodes
                if core.Len(typeNodes) > 1 then
                    return self:grammarErrorOnFirstToken(typeNodes[2], diagnostics.Classes_can_only_extend_a_single_class)
                end

                seenExtendsClause = true
            else
                if heritageClause.token ~= Kind.ImplementsKeyword then
                    error("Unexpected token " .. ast.Kind_String(heritageClause.token), 0)
                end
                if seenImplementsClause then
                    return self:grammarErrorOnFirstToken(heritageClauseNode, diagnostics.X_implements_clause_already_seen)
                end

                seenImplementsClause = true
            end

            -- Grammar checking heritageClause inside class declaration
            self:checkGrammarHeritageClause(heritageClause)
        end
    end

    return false
end

function Checker:checkGrammarInterfaceDeclaration(node)
    if node.heritageClauses ~= nil then
        local seenExtendsClause = false
        for _, heritageClauseNode in ipairs(node.heritageClauses.nodes or {}) do
            local heritageClause = heritageClauseNode:AsHeritageClause()

            local token = heritageClause.token
            if token == Kind.ExtendsKeyword then
                if seenExtendsClause then
                    return self:grammarErrorOnFirstToken(heritageClauseNode, diagnostics.X_extends_clause_already_seen)
                end
                seenExtendsClause = true
            elseif token == Kind.ImplementsKeyword then
                return self:grammarErrorOnFirstToken(heritageClauseNode, diagnostics.Interface_declaration_cannot_have_implements_clause)
            else
                error("Unexpected token " .. ast.Kind_String(token), 0)
            end

            -- Grammar checking heritageClause inside class declaration
            self:checkGrammarHeritageClause(heritageClause)
        end
    end

    return false
end

function Checker:checkGrammarComputedPropertyName(node)
    -- If node is not a computedPropertyName, just skip the grammar checking
    if node.kind ~= Kind.ComputedPropertyName then
        return false
    end

    local computedPropertyName = node:AsComputedPropertyName()
    if computedPropertyName.expression.kind == Kind.BinaryExpression and computedPropertyName.expression.operatorToken.kind == Kind.CommaToken then
        return self:grammarErrorOnNode(computedPropertyName.expression, diagnostics.A_comma_expression_is_not_allowed_in_a_computed_property_name)
    end
    return false
end

function Checker:checkGrammarForGenerator(node)
    local bodyData = node:BodyData()
    if bodyData ~= nil and bodyData.asteriskToken ~= nil then
        if node.kind ~= Kind.FunctionDeclaration and node.kind ~= Kind.FunctionExpression and node.kind ~= Kind.MethodDeclaration then
            error("Unexpected node kind " .. ast.Kind_String(node.kind), 0)
        end
        if node.flags & NodeFlags.Ambient ~= 0 then
            return self:grammarErrorOnNode(bodyData.asteriskToken, diagnostics.Generators_are_not_allowed_in_an_ambient_context)
        end
        if bodyData.body == nil then
            return self:grammarErrorOnNode(bodyData.asteriskToken, diagnostics.An_overload_signature_cannot_be_declared_as_a_generator)
        end
    end

    return false
end

function Checker:checkGrammarForInvalidQuestionMark(postfixToken, message)
    return postfixToken ~= nil and postfixToken.kind == Kind.QuestionToken and self:grammarErrorOnNode(postfixToken, message)
end

function Checker:checkGrammarForInvalidExclamationToken(postfixToken, message)
    return postfixToken ~= nil and postfixToken.kind == Kind.ExclamationToken and self:grammarErrorOnNode(postfixToken, message)
end

function Checker:checkGrammarObjectLiteralExpression(node, inDestructuring)
    local c = self
    local seen = {}

    local properties
    if node.properties ~= nil then
        properties = node.properties.nodes
    end
    for _, prop in ipairs(properties or {}) do
        if prop.kind == Kind.SpreadAssignment then
            if inDestructuring then
                -- a rest property cannot be destructured any further
                local expression = ast.SkipParentheses(prop.expression)
                if ast.IsArrayLiteralExpression(expression) or ast.IsObjectLiteralExpression(expression) then
                    return c:grammarErrorOnNode(prop.expression, diagnostics.A_rest_element_cannot_contain_a_binding_pattern)
                end
            end
            goto continue
        end
        do
            local name = prop:Name()
            if name.kind == Kind.ComputedPropertyName then
                -- If the name is not a ComputedPropertyName, the grammar checking will skip it
                c:checkGrammarComputedPropertyName(name)
            end

            if prop.kind == Kind.ShorthandPropertyAssignment and not inDestructuring then
                local shorthandProp = prop:AsShorthandPropertyAssignment()
                if shorthandProp.objectAssignmentInitializer ~= nil then
                    -- having objectAssignmentInitializer is only valid in an ObjectAssignmentPattern.
                    -- Outside of destructuring, it is a syntax error.

                    -- Try to grab the last node prior to the initializer,
                    -- then error on the first token following (which should be the `=` token).
                    local lastNodeBeforeInitializer
                    shorthandProp:ForEachChild(function(child)
                        if child ~= shorthandProp.objectAssignmentInitializer then
                            lastNodeBeforeInitializer = child
                            return false
                        end
                        return true
                    end)

                    c:grammarErrorOnFirstToken(lastNodeBeforeInitializer, diagnostics.Did_you_mean_to_use_a_Colon_An_can_only_follow_a_property_name_when_the_containing_object_literal_is_part_of_a_destructuring_pattern)
                end
            end

            if name.kind == Kind.PrivateIdentifier then
                c:grammarErrorOnNode(name, diagnostics.Private_identifiers_are_not_allowed_outside_class_bodies)
            end

            -- Modifiers are never allowed on properties except for 'async' on a method declaration
            local modifiers = prop:ModifierNodes()
            if core.Len(modifiers) ~= 0 then
                if ast.CanHaveModifiers(prop) then
                    for _, mod in ipairs(modifiers) do
                        if ast.IsModifier(mod) and (mod.kind ~= Kind.AsyncKeyword or prop.kind ~= Kind.MethodDeclaration) then
                            c:grammarErrorOnNode(mod, diagnostics.X_0_modifier_cannot_be_used_here, scanner.GetTextOfNode(mod))
                        end
                    end
                elseif ast.CanHaveIllegalModifiers(prop) then
                    for _, mod in ipairs(modifiers) do
                        if ast.IsModifier(mod) then
                            c:grammarErrorOnNode(mod, diagnostics.X_0_modifier_cannot_be_used_here, scanner.GetTextOfNode(mod))
                        end
                    end
                end
            end

            -- ECMA-262 11.1.5 Object Initializer
            -- If previous is not undefined then throw a SyntaxError exception if any of the following conditions are true
            -- a.This production is contained in strict code and IsDataDescriptor(previous) is true and
            -- IsDataDescriptor(propId.descriptor) is true.
            --    b.IsDataDescriptor(previous) is true and IsAccessorDescriptor(propId.descriptor) is true.
            --    c.IsAccessorDescriptor(previous) is true and IsDataDescriptor(propId.descriptor) is true.
            --    d.IsAccessorDescriptor(previous) is true and IsAccessorDescriptor(propId.descriptor) is true
            -- and either both previous and propId.descriptor have[[Get]] fields or both previous and propId.descriptor have[[Set]] fields
            local currentKind
            local pk = prop.kind
            if pk == Kind.ShorthandPropertyAssignment or pk == Kind.PropertyAssignment then
                -- Grammar checking for computedPropertyName and shorthandPropertyAssignment
                c:checkGrammarForInvalidExclamationToken(prop.postfixToken, diagnostics.A_definite_assignment_assertion_is_not_permitted_in_this_context)
                c:checkGrammarForInvalidQuestionMark(prop.postfixToken, diagnostics.An_object_member_cannot_be_declared_optional)

                if name.kind == Kind.NumericLiteral then
                    c:checkGrammarNumericLiteral(name:AsNumericLiteral())
                end

                if name.kind == Kind.BigIntLiteral then
                    c:addErrorOrSuggestion(true, checker.createDiagnosticForNode(name, diagnostics.A_bigint_literal_cannot_be_used_as_a_property_name))
                end

                currentKind = DeclarationMeaning.PropertyAssignment
            elseif pk == Kind.MethodDeclaration then
                currentKind = DeclarationMeaning.Method
            elseif pk == Kind.GetAccessor then
                currentKind = DeclarationMeaning.GetAccessor
            elseif pk == Kind.SetAccessor then
                currentKind = DeclarationMeaning.SetAccessor
            else
                error("Unexpected node kind " .. ast.Kind_String(prop.kind), 0)
            end

            if not inDestructuring then
                local effectiveName, ok = c:getEffectivePropertyNameForPropertyNameNode(name)
                if not ok then
                    goto continue
                end

                local existingKind = seen[effectiveName] or 0
                if existingKind == 0 then
                    seen[effectiveName] = currentKind
                else
                    if (currentKind & DeclarationMeaning.Method ~= 0) and (existingKind & DeclarationMeaning.Method ~= 0) then
                        c:grammarErrorOnNode(name, diagnostics.Duplicate_identifier_0, scanner.GetTextOfNode(name))
                    elseif (currentKind & DeclarationMeaning.PropertyAssignment ~= 0) and (existingKind & DeclarationMeaning.PropertyAssignment ~= 0) then
                        c:grammarErrorOnNode(name, diagnostics.An_object_literal_cannot_have_multiple_properties_with_the_same_name, scanner.GetTextOfNode(name))
                    elseif (currentKind & DeclarationMeaning.GetOrSetAccessor ~= 0) and (existingKind & DeclarationMeaning.GetOrSetAccessor ~= 0) then
                        if existingKind ~= DeclarationMeaning.GetOrSetAccessor and currentKind ~= existingKind then
                            seen[effectiveName] = currentKind | existingKind
                        else
                            return c:grammarErrorOnNode(name, diagnostics.An_object_literal_cannot_have_multiple_get_Slashset_accessors_with_the_same_name)
                        end
                    else
                        return c:grammarErrorOnNode(name, diagnostics.An_object_literal_cannot_have_property_and_accessor_with_the_same_name)
                    end
                end
            end
        end
        ::continue::
    end

    return false
end

function Checker:checkGrammarJsxElement(node)
    self:checkGrammarJsxName(node:TagName())
    self:checkGrammarTypeArguments(node, node:TypeArgumentList())
    local seen = {}
    for _, attrNode in ipairs(node:Attributes():Properties() or {}) do
        if attrNode.kind == Kind.JsxSpreadAttribute then
            goto continue
        end
        do
            local attr = attrNode:AsJsxAttribute()
            local name = attr:Name()
            local initializer = attr.initializer
            local textOfName = name:Text()
            if not seen[textOfName] then
                seen[textOfName] = true
            else
                return self:grammarErrorOnNode(name, diagnostics.JSX_elements_cannot_have_multiple_attributes_with_the_same_name)
            end
            if initializer ~= nil and initializer.kind == Kind.JsxExpression and initializer:Expression() == nil then
                return self:grammarErrorOnNode(initializer, diagnostics.JSX_attributes_must_only_be_assigned_a_non_empty_expression)
            end
        end
        ::continue::
    end
    return false
end

function Checker:checkGrammarJsxName(node)
    if ast.IsPropertyAccessExpression(node) and ast.IsJsxNamespacedName(node:Expression()) then
        return self:grammarErrorOnNode(node:Expression(), diagnostics.JSX_property_access_expressions_cannot_include_JSX_namespace_names)
    end

    if ast.IsJsxNamespacedName(node) and self.compilerOptions:GetJSXTransformEnabled() and not scanner.IsIntrinsicJsxName(node:AsJsxNamespacedName().namespace:Text()) then
        return self:grammarErrorOnNode(node, diagnostics.React_components_cannot_include_JSX_namespace_names)
    end

    return false
end

function Checker:checkGrammarJsxExpression(node)
    if node.expression ~= nil and ast.IsCommaSequence(node.expression) then
        return self:grammarErrorOnNode(node.expression, diagnostics.JSX_expressions_may_not_use_the_comma_operator_Did_you_mean_to_write_an_array)
    end

    return false
end

function Checker:checkGrammarForInOrForOfStatement(forInOrOfStatement)
    local c = self
    local asNode = forInOrOfStatement
    if c:checkGrammarStatementInAmbientContext(asNode) then
        return true
    end

    if forInOrOfStatement.kind == Kind.ForOfStatement and forInOrOfStatement.awaitModifier ~= nil then
        if forInOrOfStatement.flags & NodeFlags.AwaitContext == 0 then
            local sourceFile = ast.GetSourceFileOfNode(asNode)
            if ast.IsInTopLevelContext(asNode) then
                if not c:hasParseDiagnostics(sourceFile) then
                    if not ast.IsEffectiveExternalModule(sourceFile, c.compilerOptions) then
                        c:addDiagnostic(checker.createDiagnosticForNode(forInOrOfStatement.awaitModifier, diagnostics.X_for_await_loops_are_only_allowed_at_the_top_level_of_a_file_when_that_file_is_a_module_but_this_file_has_no_imports_or_exports_Consider_adding_an_empty_export_to_make_this_file_a_module))
                    end
                    local mk = c.moduleKind
                    local reportDefault = false
                    if mk == ModuleKind.Node16 or mk == ModuleKind.Node18 or mk == ModuleKind.Node20 or mk == ModuleKind.NodeNext then
                        local sourceFileMetaData = c.program:GetSourceFileMetaData(sourceFile:Path())
                        if sourceFileMetaData.impliedNodeFormat == ModuleKind.CommonJS then
                            c:addDiagnostic(checker.createDiagnosticForNode(forInOrOfStatement.awaitModifier, diagnostics.The_current_file_is_a_CommonJS_module_and_cannot_use_await_at_the_top_level))
                        elseif c.languageVersion < ScriptTarget.ES2017 then
                            -- fallthrough
                            reportDefault = true
                        end
                    elseif mk == ModuleKind.ES2022 or mk == ModuleKind.ESNext or mk == ModuleKind.Preserve or mk == ModuleKind.System then
                        if c.languageVersion < ScriptTarget.ES2017 then
                            -- fallthrough
                            reportDefault = true
                        end
                    else
                        reportDefault = true
                    end
                    if reportDefault then
                        c:addDiagnostic(checker.createDiagnosticForNode(forInOrOfStatement.awaitModifier, diagnostics.Top_level_for_await_loops_are_only_allowed_when_the_module_option_is_set_to_es2022_esnext_system_node16_node18_node20_nodenext_or_preserve_and_the_target_option_is_set_to_es2017_or_higher))
                    end
                end
            else
                -- use of 'for-await-of' in non-async function
                if not c:hasParseDiagnostics(sourceFile) then
                    local diagnostic = checker.createDiagnosticForNode(forInOrOfStatement.awaitModifier, diagnostics.X_for_await_loops_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules)
                    local containingFunc = ast.GetContainingFunction(forInOrOfStatement)
                    if containingFunc ~= nil and containingFunc.kind ~= Kind.Constructor then
                        debug.Assert((ast.GetFunctionFlags(containingFunc) & FunctionFlags.Async) == 0, "Enclosing function should never be an async function.")
                        local relatedInfo = checker.createDiagnosticForNode(containingFunc, diagnostics.Did_you_mean_to_mark_this_function_as_async)
                        diagnostic:AddRelatedInfo(relatedInfo)
                    end
                    c:addDiagnostic(diagnostic)
                    return true
                end
            end
        end
    end

    if ast.IsForOfStatement(asNode) and forInOrOfStatement.flags & NodeFlags.AwaitContext == 0 and ast.IsIdentifier(forInOrOfStatement.initializer) and forInOrOfStatement.initializer:Text() == "async" then
        c:grammarErrorOnNode(forInOrOfStatement.initializer, diagnostics.The_left_hand_side_of_a_for_of_statement_may_not_be_async)
        return false
    end

    if forInOrOfStatement.initializer.kind == Kind.VariableDeclarationList then
        local variableList = forInOrOfStatement.initializer:AsVariableDeclarationList()
        if not c:checkGrammarVariableDeclarationList(variableList) then
            local declarations = variableList.declarations

            -- declarations.length can be zero if there is an error in variable declaration in for-of or for-in
            -- See http://www.ecma-international.org/ecma-262/6.0/#sec-for-in-and-for-of-statements for details
            -- For example:
            --      var let = 10;
            --      for (let of [1,2,3]) {} // this is invalid ES6 syntax
            --      for (let in [1,2,3]) {} // this is invalid ES6 syntax
            -- We will then want to skip on grammar checking on variableList declaration
            if core.Len(declarations.nodes) == 0 then
                return false
            end

            if #declarations.nodes > 1 then
                local diagnostic
                if forInOrOfStatement.kind == Kind.ForInStatement then
                    diagnostic = diagnostics.Only_a_single_variable_declaration_is_allowed_in_a_for_in_statement
                else
                    diagnostic = diagnostics.Only_a_single_variable_declaration_is_allowed_in_a_for_of_statement
                end
                return c:grammarErrorOnFirstToken(declarations.nodes[2], diagnostic)
            end

            local firstVariableDeclaration = declarations.nodes[1]:AsVariableDeclaration()
            if firstVariableDeclaration.initializer ~= nil then
                local diagnostic
                if forInOrOfStatement.kind == Kind.ForInStatement then
                    diagnostic = diagnostics.The_variable_declaration_of_a_for_in_statement_cannot_have_an_initializer
                else
                    diagnostic = diagnostics.The_variable_declaration_of_a_for_of_statement_cannot_have_an_initializer
                end
                return c:grammarErrorOnNode(firstVariableDeclaration:Name(), diagnostic)
            end
            if firstVariableDeclaration.type ~= nil then
                local diagnostic
                if forInOrOfStatement.kind == Kind.ForInStatement then
                    diagnostic = diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_use_a_type_annotation
                else
                    diagnostic = diagnostics.The_left_hand_side_of_a_for_of_statement_cannot_use_a_type_annotation
                end
                return c:grammarErrorOnNode(firstVariableDeclaration, diagnostic)
            end
        end
    end

    return false
end

function Checker:checkGrammarAccessor(accessor)
    local c = self
    local body = accessor:Body()
    if accessor.flags & NodeFlags.Ambient == 0 and (accessor.parent.kind ~= Kind.TypeLiteral) and (accessor.parent.kind ~= Kind.InterfaceDeclaration) then
        if body == nil and not ast.HasSyntacticModifier(accessor, ModifierFlags.Abstract) then
            return c:grammarErrorAtPos(accessor, accessor:End() - 1, #";", diagnostics.X_0_expected, "{")
        end
    end
    if body ~= nil then
        if ast.HasSyntacticModifier(accessor, ModifierFlags.Abstract) then
            return c:grammarErrorOnNode(accessor, diagnostics.An_abstract_accessor_cannot_have_an_implementation)
        end
        if accessor.parent.kind == Kind.TypeLiteral or accessor.parent.kind == Kind.InterfaceDeclaration then
            return c:grammarErrorOnNode(body, diagnostics.An_implementation_cannot_be_declared_in_ambient_contexts)
        end
    end

    local funcData = accessor:FunctionLikeData()
    local typeParameters
    if funcData ~= nil then
        typeParameters = funcData.typeParameters
    end

    if typeParameters ~= nil then
        return c:grammarErrorOnNode(accessor:Name(), diagnostics.An_accessor_cannot_have_type_parameters)
    end
    if not c:doesAccessorHaveCorrectParameterCount(accessor) then
        return c:grammarErrorOnNode(accessor:Name(), core.IfElse(accessor.kind == Kind.GetAccessor, diagnostics.A_get_accessor_cannot_have_parameters, diagnostics.A_set_accessor_must_have_exactly_one_parameter))
    end
    if accessor.kind == Kind.SetAccessor then
        if funcData.type ~= nil then
            return c:grammarErrorOnNode(accessor:Name(), diagnostics.A_set_accessor_cannot_have_a_return_type_annotation)
        end

        local parameterNode = checker.GetSetAccessorValueParameter(accessor)
        if parameterNode == nil then
            error("Return value does not match parameter count assertion.", 0)
        end
        local parameter = parameterNode:AsParameterDeclaration()
        if parameter.dotDotDotToken ~= nil then
            return c:grammarErrorOnNode(parameter.dotDotDotToken, diagnostics.A_set_accessor_cannot_have_rest_parameter)
        end
        if parameter.questionToken ~= nil then
            return c:grammarErrorOnNode(parameter.questionToken, diagnostics.A_set_accessor_cannot_have_an_optional_parameter)
        end
        if parameter.initializer ~= nil then
            return c:grammarErrorOnNode(accessor:Name(), diagnostics.A_set_accessor_parameter_cannot_have_an_initializer)
        end
    end

    return false
end

-- Does the accessor have the right number of parameters?
--
--	A `get` accessor has no parameters or a single `this` parameter.
--	A `set` accessor has one parameter or a `this` parameter and one more parameter.
function Checker:doesAccessorHaveCorrectParameterCount(accessor)
    -- `getAccessorThisParameter` returns `nil` if the accessor's arity is incorrect,
    -- even if there is a `this` parameter declared.
    return self:getAccessorThisParameter(accessor) ~= nil or core.Len(accessor:Parameters()) == core.IfElse(accessor.kind == Kind.GetAccessor, 0, 1)
end

function Checker:checkGrammarTypeOperatorNode(node)
    local c = self
    if node.operator == Kind.UniqueKeyword then
        local innerType = node.type
        if innerType.kind ~= Kind.SymbolKeyword then
            return c:grammarErrorOnNode(innerType, diagnostics.X_0_expected, scanner.TokenToString(Kind.SymbolKeyword))
        end
        local parent = ast.WalkUpParenthesizedTypes(node.parent)
        local pk = parent.kind
        if pk == Kind.VariableDeclaration then
            local decl = parent:AsVariableDeclaration()
            if decl:Name().kind ~= Kind.Identifier then
                return c:grammarErrorOnNode(node, diagnostics.X_unique_symbol_types_may_not_be_used_on_a_variable_declaration_with_a_binding_name)
            end
            if not checker.isVariableDeclarationInVariableStatement(decl) then
                return c:grammarErrorOnNode(node, diagnostics.X_unique_symbol_types_are_only_allowed_on_variables_in_a_variable_statement)
            end
            if decl.parent.flags & NodeFlags.Const == 0 then
                return c:grammarErrorOnNode(parent:AsVariableDeclaration():Name(), diagnostics.A_variable_whose_type_is_a_unique_symbol_type_must_be_const)
            end
        elseif pk == Kind.PropertyDeclaration then
            if not ast.IsStatic(parent) or not checker.hasReadonlyModifier(parent) then
                return c:grammarErrorOnNode(parent:AsPropertyDeclaration():Name(), diagnostics.A_property_of_a_class_whose_type_is_a_unique_symbol_type_must_be_both_static_and_readonly)
            end
        elseif pk == Kind.PropertySignature then
            if not ast.HasSyntacticModifier(parent, ModifierFlags.Readonly) then
                return c:grammarErrorOnNode(parent:AsPropertySignatureDeclaration():Name(), diagnostics.A_property_of_an_interface_or_type_literal_whose_type_is_a_unique_symbol_type_must_be_readonly)
            end
        else
            return c:grammarErrorOnNode(node, diagnostics.X_unique_symbol_types_are_not_allowed_here)
        end
    elseif node.operator == Kind.ReadonlyKeyword then
        local innerType = node.type
        if innerType.kind ~= Kind.ArrayType and innerType.kind ~= Kind.TupleType then
            return c:grammarErrorOnFirstToken(node, diagnostics.X_readonly_type_modifier_is_only_permitted_on_array_and_tuple_literal_types, scanner.TokenToString(Kind.SymbolKeyword))
        end
    end

    return false
end

function Checker:checkGrammarForInvalidDynamicName(node, message)
    if not self:isNonBindableDynamicName(node) then
        return false
    end
    local expression
    if ast.IsElementAccessExpression(node) then
        expression = ast.SkipParentheses(node:AsElementAccessExpression().argumentExpression)
    else
        expression = node:Expression()
    end

    if not ast.IsEntityNameExpression(expression) then
        return self:grammarErrorOnNode(node, message)
    end

    return false
end

-- Indicates whether a declaration name is a dynamic name that cannot be late-bound.
function Checker:isNonBindableDynamicName(node)
    return ast.IsDynamicName(node) and not self:isLateBindableName(node)
end

function Checker:checkGrammarMethod(node)
    local c = self
    if c:checkGrammarFunctionLikeDeclaration(node) then
        return true
    end

    if node.kind == Kind.MethodDeclaration then
        if node.parent.kind == Kind.ObjectLiteralExpression then
            -- We only disallow modifier on a method declaration if it is a property of object-literal-expression
            local modifiers = node:Modifiers()
            if modifiers ~= nil and not (core.Len(modifiers.nodes) == 1 and modifiers.nodes[1].kind == Kind.AsyncKeyword) then
                return c:grammarErrorOnFirstToken(node, diagnostics.Modifiers_cannot_appear_here)
            end

            local methodDecl = node:AsMethodDeclaration()
            if c:checkGrammarForInvalidQuestionMark(methodDecl.postfixToken, diagnostics.An_object_member_cannot_be_declared_optional) then
                return true
            end
            if c:checkGrammarForInvalidExclamationToken(methodDecl.postfixToken, diagnostics.A_definite_assignment_assertion_is_not_permitted_in_this_context) then
                return true
            end
            if node:Body() == nil then
                return c:grammarErrorAtPos(node, node:End() - 1, #";", diagnostics.X_0_expected, "{")
            end
        end
        if c:checkGrammarForGenerator(node) then
            return true
        end
    end

    if ast.IsClassLike(node.parent) then
        -- Technically, computed properties in ambient contexts is disallowed
        -- for property declarations and accessors too, not just methods.
        -- However, property declarations disallow computed names in general,
        -- and accessors are not allowed in ambient contexts in general,
        -- so this error only really matters for methods.
        if node.flags & NodeFlags.Ambient ~= 0 then
            return c:checkGrammarForInvalidDynamicName(node:Name(), diagnostics.A_computed_property_name_in_an_ambient_context_must_refer_to_an_expression_whose_type_is_a_literal_type_or_a_unique_symbol_type)
        elseif node.kind == Kind.MethodDeclaration and node:Body() == nil then
            return c:checkGrammarForInvalidDynamicName(node:Name(), diagnostics.A_computed_property_name_in_a_method_overload_must_refer_to_an_expression_whose_type_is_a_literal_type_or_a_unique_symbol_type)
        end
    elseif node.parent.kind == Kind.InterfaceDeclaration then
        return c:checkGrammarForInvalidDynamicName(node:Name(), diagnostics.A_computed_property_name_in_an_interface_must_refer_to_an_expression_whose_type_is_a_literal_type_or_a_unique_symbol_type)
    elseif node.parent.kind == Kind.TypeLiteral then
        return c:checkGrammarForInvalidDynamicName(node:Name(), diagnostics.A_computed_property_name_in_a_type_literal_must_refer_to_an_expression_whose_type_is_a_literal_type_or_a_unique_symbol_type)
    end

    return false
end

function Checker:checkGrammarBreakOrContinueStatement(node)
    local c = self
    local targetLabel = node:Label()
    local current = node
    while current ~= nil do
        if ast.IsFunctionLikeOrClassStaticBlockDeclaration(current) then
            return c:grammarErrorOnNode(node, diagnostics.Jump_target_cannot_cross_function_boundary)
        end

        local ck = current.kind
        if ck == Kind.LabeledStatement then
            if targetLabel ~= nil and current:Label():Text() == targetLabel:Text() then
                -- found matching label - verify that label usage is correct
                -- continue can only target labels that are on iteration statements
                local isMisplacedContinueLabel = node.kind == Kind.ContinueStatement and not ast.IsIterationStatement(current:Statement(), true --[[lookInLabeledStatements]])

                if isMisplacedContinueLabel then
                    return c:grammarErrorOnNode(node, diagnostics.A_continue_statement_can_only_jump_to_a_label_of_an_enclosing_iteration_statement)
                end

                return false
            end
        elseif ck == Kind.SwitchStatement then
            if node.kind == Kind.BreakStatement and targetLabel == nil then
                -- unlabeled break within switch statement - ok
                return false
            end
        else
            if ast.IsIterationStatement(current, false --[[lookInLabeledStatements]]) and targetLabel == nil then
                -- unlabeled break or continue within iteration statement - ok
                return false
            end
        end

        current = current.parent
    end

    if targetLabel ~= nil then
        local message
        if node.kind == Kind.BreakStatement then
            message = diagnostics.A_break_statement_can_only_jump_to_a_label_of_an_enclosing_statement
        else
            message = diagnostics.A_continue_statement_can_only_jump_to_a_label_of_an_enclosing_iteration_statement
        end

        return c:grammarErrorOnNode(node, message)
    else
        local message
        if node.kind == Kind.BreakStatement then
            message = diagnostics.A_break_statement_can_only_be_used_within_an_enclosing_iteration_or_switch_statement
        else
            message = diagnostics.A_continue_statement_can_only_be_used_within_an_enclosing_iteration_statement
        end
        return c:grammarErrorOnNode(node, message)
    end
end

function Checker:checkGrammarBindingElement(node)
    if node.dotDotDotToken ~= nil then
        local elements = node.parent:ElementList()
        if node ~= core.LastOrNil(elements.nodes) then
            return self:grammarErrorOnNode(node, diagnostics.A_rest_element_must_be_last_in_a_destructuring_pattern)
        end
        self:checkGrammarForDisallowedTrailingComma(elements, diagnostics.A_rest_parameter_or_binding_pattern_may_not_have_a_trailing_comma)

        if node.propertyName ~= nil then
            return self:grammarErrorOnNode(node:Name(), diagnostics.A_rest_element_cannot_have_a_property_name)
        end
    end

    if node.dotDotDotToken ~= nil and node.initializer ~= nil then
        -- Error on equals token which immediately precedes the initializer
        return self:grammarErrorAtPos(node, node.initializer:Pos() - 1, 1, diagnostics.A_rest_element_cannot_have_an_initializer)
    end

    return false
end

function Checker:checkGrammarVariableDeclaration(node)
    local c = self
    local nodeFlags = c:getCombinedNodeFlagsCached(node)
    local blockScopeKind = nodeFlags & NodeFlags.BlockScoped
    if ast.IsBindingPattern(node:Name()) then
        if blockScopeKind == NodeFlags.AwaitUsing then
            return c:grammarErrorOnNode(node, diagnostics.X_0_declarations_may_not_have_binding_patterns, "await using")
        elseif blockScopeKind == NodeFlags.Using then
            return c:grammarErrorOnNode(node, diagnostics.X_0_declarations_may_not_have_binding_patterns, "using")
        end
    end

    if node.parent.parent.kind ~= Kind.ForInStatement and node.parent.parent.kind ~= Kind.ForOfStatement then
        if nodeFlags & NodeFlags.Ambient ~= 0 then
            c:checkAmbientInitializer(node)
        elseif node.initializer == nil then
            if ast.IsBindingPattern(node:Name()) and not ast.IsBindingPattern(node.parent) then
                return c:grammarErrorOnNode(node, diagnostics.A_destructuring_declaration_must_have_an_initializer)
            end
            if blockScopeKind == NodeFlags.AwaitUsing then
                return c:grammarErrorOnNode(node, diagnostics.X_0_declarations_must_be_initialized, "await using")
            elseif blockScopeKind == NodeFlags.Using then
                return c:grammarErrorOnNode(node, diagnostics.X_0_declarations_must_be_initialized, "using")
            elseif blockScopeKind == NodeFlags.Const then
                return c:grammarErrorOnNode(node, diagnostics.X_0_declarations_must_be_initialized, "const")
            end
        end
    end

    if node.exclamationToken ~= nil and (node.parent.parent.kind ~= Kind.VariableStatement or node.type == nil or node.initializer ~= nil or nodeFlags & NodeFlags.Ambient ~= 0) then
        local message
        if node.initializer ~= nil then
            message = diagnostics.Declarations_with_initializers_cannot_also_have_definite_assignment_assertions
        elseif node.type == nil then
            message = diagnostics.Declarations_with_definite_assignment_assertions_must_also_have_type_annotations
        else
            message = diagnostics.A_definite_assignment_assertion_is_not_permitted_in_this_context
        end
        return c:grammarErrorOnNode(node.exclamationToken, message)
    end

    if c.program:GetEmitModuleFormatOfFile(ast.GetSourceFileOfNode(node)) < ModuleKind.System and (node.parent.parent.flags & NodeFlags.Ambient == 0) and ast.HasSyntacticModifier(node.parent.parent, ModifierFlags.Export) then
        c:checkGrammarForEsModuleMarkerInBindingName(node:Name())
    end

    -- 1. LexicalDeclaration : LetOrConst BindingList ;
    -- It is a Syntax Error if the BoundNames of BindingList contains "let".
    -- 2. ForDeclaration: ForDeclaration : LetOrConst ForBinding
    -- It is a Syntax Error if the BoundNames of ForDeclaration contains "let".

    -- It is a SyntaxError if a VariableDeclaration or VariableDeclarationNoIn occurs within strict code
    -- and its Identifier is eval or arguments
    return blockScopeKind ~= 0 and c:checkGrammarNameInLetOrConstDeclarations(node:Name())
end

function Checker:checkGrammarForEsModuleMarkerInBindingName(name)
    if ast.IsIdentifier(name) then
        if name:Text() == "__esModule" then
            return self:grammarErrorOnNodeSkippedOnNoEmit(name, diagnostics.Identifier_expected_esModule_is_reserved_as_an_exported_marker_when_transforming_ECMAScript_modules)
        end
    else
        for _, element in ipairs(name:Elements() or {}) do
            if element:Name() ~= nil then
                return self:checkGrammarForEsModuleMarkerInBindingName(element:Name())
            end
        end
    end
    return false
end

function Checker:checkGrammarNameInLetOrConstDeclarations(name)
    if name.kind == Kind.Identifier then
        if name:Text() == "let" then
            return self:grammarErrorOnNode(name, diagnostics.X_let_is_not_allowed_to_be_used_as_a_name_in_let_or_const_declarations)
        end
    else
        local elements = name:Elements()
        for _, element in ipairs(elements or {}) do
            local bindingElement = element:AsBindingElement()
            if bindingElement:Name() ~= nil then
                self:checkGrammarNameInLetOrConstDeclarations(bindingElement:Name())
            end
        end
    end
    return false
end

function Checker:checkGrammarVariableDeclarationList(declarationList)
    local c = self
    local declarations = declarationList.declarations
    if c:checkGrammarForDisallowedTrailingComma(declarations, diagnostics.Trailing_comma_not_allowed) then
        return true
    end

    if core.Len(declarations.nodes) == 0 then
        return c:grammarErrorAtPos(declarationList, declarations:Pos(), declarations:End() - declarations:Pos(), diagnostics.Variable_declaration_list_cannot_be_empty)
    end

    local blockScopeFlags = declarationList.flags & NodeFlags.BlockScoped
    if blockScopeFlags == NodeFlags.Using or blockScopeFlags == NodeFlags.AwaitUsing then
        if ast.IsForInStatement(declarationList.parent) then
            return c:grammarErrorOnNode(declarationList, core.IfElse(blockScopeFlags == NodeFlags.Using, diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_be_a_using_declaration, diagnostics.The_left_hand_side_of_a_for_in_statement_cannot_be_an_await_using_declaration))
        end
        if declarationList.flags & NodeFlags.Ambient ~= 0 then
            return c:grammarErrorOnNode(declarationList, core.IfElse(blockScopeFlags == NodeFlags.Using, diagnostics.X_using_declarations_are_not_allowed_in_ambient_contexts, diagnostics.X_await_using_declarations_are_not_allowed_in_ambient_contexts))
        end
        if ast.IsVariableStatement(declarationList.parent) and (ast.IsCaseClause(declarationList.parent.parent) or ast.IsDefaultClause(declarationList.parent.parent)) then
            return c:grammarErrorOnNode(declarationList, core.IfElse(blockScopeFlags == NodeFlags.Using, diagnostics.X_using_declarations_are_not_allowed_in_case_or_default_clauses_unless_contained_within_a_block, diagnostics.X_await_using_declarations_are_not_allowed_in_case_or_default_clauses_unless_contained_within_a_block))
        end
    end

    if blockScopeFlags == NodeFlags.AwaitUsing then
        return c:checkGrammarAwaitOrAwaitUsing(declarationList)
    end

    return false
end

function Checker:checkGrammarAwaitOrAwaitUsing(node)
    local c = self
    -- Grammar checking
    local hasError = false
    local container = checker.getContainingFunctionOrClassStaticBlock(node)
    if container ~= nil and ast.IsClassStaticBlockDeclaration(container) then
        -- NOTE: We report this regardless as to whether there are parse diagnostics.
        local message
        if ast.IsAwaitExpression(node) then
            message = diagnostics.X_await_expression_cannot_be_used_inside_a_class_static_block
        else
            message = diagnostics.X_await_using_statements_cannot_be_used_inside_a_class_static_block
        end
        c:error(node, message)
        hasError = true
    elseif node.flags & NodeFlags.AwaitContext == 0 then
        if ast.IsInTopLevelContext(node) then
            local sourceFile = ast.GetSourceFileOfNode(node)
            if not c:hasParseDiagnostics(sourceFile) then
                local span = core.NewTextRange(0, 0)
                local spanCalculated = false
                if not ast.IsEffectiveExternalModule(sourceFile, c.compilerOptions) then
                    span = scanner.GetRangeOfTokenAtPosition(sourceFile, node:Pos())
                    spanCalculated = true
                    local message
                    if ast.IsAwaitExpression(node) then
                        message = diagnostics.X_await_expressions_are_only_allowed_at_the_top_level_of_a_file_when_that_file_is_a_module_but_this_file_has_no_imports_or_exports_Consider_adding_an_empty_export_to_make_this_file_a_module
                    else
                        message = diagnostics.X_await_using_statements_are_only_allowed_at_the_top_level_of_a_file_when_that_file_is_a_module_but_this_file_has_no_imports_or_exports_Consider_adding_an_empty_export_to_make_this_file_a_module
                    end
                    local diagnostic = ast.NewDiagnostic(sourceFile, span, message)
                    c:addDiagnostic(diagnostic)
                    hasError = true
                end
                local mk = c.moduleKind
                local reportDefault = false
                if mk == ModuleKind.Node16 or mk == ModuleKind.Node18 or mk == ModuleKind.Node20 or mk == ModuleKind.NodeNext then
                    local sourceFileMetaData = c.program:GetSourceFileMetaData(sourceFile:Path())
                    if sourceFileMetaData.impliedNodeFormat == ModuleKind.CommonJS then
                        if not spanCalculated then
                            span = scanner.GetRangeOfTokenAtPosition(sourceFile, node:Pos())
                        end
                        c:addDiagnostic(ast.NewDiagnostic(sourceFile, span, diagnostics.The_current_file_is_a_CommonJS_module_and_cannot_use_await_at_the_top_level))
                        hasError = true
                    elseif c.languageVersion < ScriptTarget.ES2017 then
                        -- fallthrough
                        reportDefault = true
                    end
                elseif mk == ModuleKind.ES2022 or mk == ModuleKind.ESNext or mk == ModuleKind.Preserve or mk == ModuleKind.System then
                    if c.languageVersion < ScriptTarget.ES2017 then
                        -- fallthrough
                        reportDefault = true
                    end
                else
                    reportDefault = true
                end
                if reportDefault then
                    if not spanCalculated then
                        span = scanner.GetRangeOfTokenAtPosition(sourceFile, node:Pos())
                    end
                    local message
                    if ast.IsAwaitExpression(node) then
                        message = diagnostics.Top_level_await_expressions_are_only_allowed_when_the_module_option_is_set_to_es2022_esnext_system_node16_node18_node20_nodenext_or_preserve_and_the_target_option_is_set_to_es2017_or_higher
                    else
                        message = diagnostics.Top_level_await_using_statements_are_only_allowed_when_the_module_option_is_set_to_es2022_esnext_system_node16_node18_node20_nodenext_or_preserve_and_the_target_option_is_set_to_es2017_or_higher
                    end
                    c:addDiagnostic(ast.NewDiagnostic(sourceFile, span, message))
                    hasError = true
                end
            end
        else
            -- use of 'await' in non-async function
            local sourceFile = ast.GetSourceFileOfNode(node)
            if not c:hasParseDiagnostics(sourceFile) then
                local span = scanner.GetRangeOfTokenAtPosition(sourceFile, node:Pos())
                local message
                if ast.IsAwaitExpression(node) then
                    message = diagnostics.X_await_expressions_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules
                else
                    message = diagnostics.X_await_using_statements_are_only_allowed_within_async_functions_and_at_the_top_levels_of_modules
                end
                local diagnostic = ast.NewDiagnostic(sourceFile, span, message)
                if container ~= nil and container.kind ~= Kind.Constructor and not checker.hasAsyncModifier(container) then
                    local relatedInfo = checker.NewDiagnosticForNode(container, diagnostics.Did_you_mean_to_mark_this_function_as_async)
                    diagnostic:AddRelatedInfo(relatedInfo)
                end
                c:addDiagnostic(diagnostic)
                hasError = true
            end
        end
    end

    if ast.IsAwaitExpression(node) and c:isInParameterInitializerBeforeContainingFunction(node) then
        -- NOTE: We report this regardless as to whether there are parse diagnostics.
        c:error(node, diagnostics.X_await_expressions_cannot_be_used_in_a_parameter_initializer)
        hasError = true
    end

    return hasError
end

function Checker:checkGrammarYieldExpression(node)
    local hasError = false
    if node.flags & NodeFlags.YieldContext == 0 then
        self:grammarErrorOnFirstToken(node, diagnostics.A_yield_expression_is_only_allowed_in_a_generator_body)
        hasError = true
    end
    if self:isInParameterInitializerBeforeContainingFunction(node) then
        self:error(node, diagnostics.X_yield_expressions_cannot_be_used_in_a_parameter_initializer)
        hasError = true
    end
    return hasError
end

function Checker:checkGrammarForDisallowedBlockScopedVariableStatement(node)
    if not self:containerAllowsBlockScopedVariable(node.parent) then
        local blockScopeKind = self:getCombinedNodeFlagsCached(node.declarationList) & NodeFlags.BlockScoped
        if blockScopeKind ~= 0 then
            local keyword
            if blockScopeKind == NodeFlags.Let then
                keyword = "let"
            elseif blockScopeKind == NodeFlags.Const then
                keyword = "const"
            elseif blockScopeKind == NodeFlags.Using then
                keyword = "using"
            elseif blockScopeKind == NodeFlags.AwaitUsing then
                keyword = "await using"
            else
                error("Unknown BlockScope flag", 0)
            end
            self:error(node, diagnostics.X_0_declarations_can_only_be_declared_inside_a_block, keyword)
        end
    end

    return false
end

local disallowBlockScopedVariableParentKinds = ast.kindSet(
    Kind.IfStatement,
    Kind.DoStatement,
    Kind.WhileStatement,
    Kind.WithStatement,
    Kind.ForStatement,
    Kind.ForInStatement,
    Kind.ForOfStatement
)

function Checker:containerAllowsBlockScopedVariable(parent)
    if disallowBlockScopedVariableParentKinds[parent.kind] then
        return false
    elseif parent.kind == Kind.LabeledStatement then
        return self:containerAllowsBlockScopedVariable(parent.parent)
    end

    return true
end

function Checker:checkGrammarMetaProperty(node)
    local nodeName = node:Name()
    local nameText = nodeName:Text()

    if node.keywordToken == Kind.NewKeyword then
        if nameText ~= "target" then
            return self:grammarErrorOnNode(nodeName, diagnostics.X_0_is_not_a_valid_meta_property_for_keyword_1_Did_you_mean_2, nameText, scanner.TokenToString(node.keywordToken), "target")
        end
    elseif node.keywordToken == Kind.ImportKeyword then
        if nameText ~= "meta" then
            local isCallee = ast.IsCallExpression(node.parent) and node.parent:Expression() == node
            if nameText == "defer" then
                if not isCallee then
                    return self:grammarErrorAtPos(node, node:End(), 0, diagnostics.X_0_expected, "(")
                end
            else
                if isCallee then
                    return self:grammarErrorOnNode(nodeName, diagnostics.X_0_is_not_a_valid_meta_property_for_keyword_import_Did_you_mean_meta_or_defer, nameText)
                end
                return self:grammarErrorOnNode(nodeName, diagnostics.X_0_is_not_a_valid_meta_property_for_keyword_1_Did_you_mean_2, nameText, scanner.TokenToString(node.keywordToken), "meta")
            end
        end
    end

    return false
end

function Checker:checkGrammarConstructorTypeParameters(node)
    local range_ = node.typeParameters
    if range_ ~= nil then
        local pos
        if range_:Pos() == range_:End() then
            pos = range_:Pos()
        else
            pos = scanner.SkipTrivia(ast.GetSourceFileOfNode(node):Text(), range_:Pos())
        end
        return self:grammarErrorAtPos(node, pos, range_:End() - pos, diagnostics.Type_parameters_cannot_appear_on_a_constructor_declaration)
    end

    return false
end

function Checker:checkGrammarConstructorTypeAnnotation(node)
    local t = node.type
    if t ~= nil then
        return self:grammarErrorOnNode(t, diagnostics.Type_annotation_cannot_appear_on_a_constructor_declaration)
    end
    return false
end

function Checker:checkGrammarProperty(node)
    local c = self
    local propertyName = node:Name()
    if ast.IsComputedPropertyName(propertyName) and ast.IsBinaryExpression(propertyName:Expression()) and propertyName:Expression():AsBinaryExpression().operatorToken.kind == Kind.InKeyword then
        return c:grammarErrorOnNode(node.parent:Members()[1], diagnostics.A_mapped_type_may_not_declare_properties_or_methods)
    end
    if ast.IsClassLike(node.parent) then
        if ast.IsStringLiteral(propertyName) and propertyName:Text() == "constructor" then
            return c:grammarErrorOnNode(propertyName, diagnostics.Classes_may_not_have_a_field_named_constructor)
        end
        if c:checkGrammarForInvalidDynamicName(propertyName, diagnostics.A_computed_property_name_in_a_class_property_declaration_must_have_a_simple_literal_type_or_a_unique_symbol_type) then
            return true
        end
        if ast.IsAutoAccessorPropertyDeclaration(node) and c:checkGrammarForInvalidQuestionMark(node:PostfixToken(), diagnostics.An_accessor_property_cannot_be_declared_optional) then
            return true
        end
    elseif ast.IsInterfaceDeclaration(node.parent) then
        if c:checkGrammarForInvalidDynamicName(propertyName, diagnostics.A_computed_property_name_in_an_interface_must_refer_to_an_expression_whose_type_is_a_literal_type_or_a_unique_symbol_type) then
            return true
        end
        if not ast.IsPropertySignatureDeclaration(node) then
            -- Interfaces cannot contain property declarations
            error("Unexpected node kind " .. ast.Kind_String(node.kind), 0)
        end
        local initializer = node:Initializer()
        if initializer ~= nil then
            return c:grammarErrorOnNode(initializer, diagnostics.An_interface_property_cannot_have_an_initializer)
        end
    elseif ast.IsTypeLiteralNode(node.parent) then
        if c:checkGrammarForInvalidDynamicName(node:Name(), diagnostics.A_computed_property_name_in_a_type_literal_must_refer_to_an_expression_whose_type_is_a_literal_type_or_a_unique_symbol_type) then
            return true
        end
        if not ast.IsPropertySignatureDeclaration(node) then
            -- Type literals cannot contain property declarations
            error("Unexpected node kind " .. ast.Kind_String(node.kind), 0)
        end
        local initializer = node:Initializer()
        if initializer ~= nil then
            return c:grammarErrorOnNode(initializer, diagnostics.A_type_literal_property_cannot_have_an_initializer)
        end
    end

    if node.flags & NodeFlags.Ambient ~= 0 then
        c:checkAmbientInitializer(node)
    end

    if ast.IsPropertyDeclaration(node) then
        local propDecl = node:AsPropertyDeclaration()
        local postfixToken = propDecl.postfixToken
        if postfixToken ~= nil and postfixToken.kind == Kind.ExclamationToken then
            if propDecl.initializer ~= nil then
                return c:grammarErrorOnNode(postfixToken, diagnostics.Declarations_with_initializers_cannot_also_have_definite_assignment_assertions)
            elseif propDecl.type == nil then
                return c:grammarErrorOnNode(postfixToken, diagnostics.Declarations_with_definite_assignment_assertions_must_also_have_type_annotations)
            elseif not ast.IsClassLike(node.parent) or node.flags & NodeFlags.Ambient ~= 0 or ast.IsStatic(node) or ast.HasAbstractModifier(node) then
                return c:grammarErrorOnNode(postfixToken, diagnostics.A_definite_assignment_assertion_is_not_permitted_in_this_context)
            end
        end
    end

    return false
end

function Checker:checkAmbientInitializer(node)
    local c = self
    local initializer
    local typeNode
    if node.kind == Kind.VariableDeclaration then
        local varDecl = node:AsVariableDeclaration()
        initializer = varDecl.initializer
        typeNode = varDecl.type
    elseif node.kind == Kind.PropertyDeclaration then
        local propDecl = node:AsPropertyDeclaration()
        initializer = propDecl.initializer
        typeNode = propDecl.type
    elseif node.kind == Kind.PropertySignature then
        local propSig = node:AsPropertySignatureDeclaration()
        initializer = propSig.initializer
        typeNode = propSig.type
    else
        error("Unexpected node kind " .. ast.Kind_String(node.kind), 0)
    end

    if initializer ~= nil then
        local isInvalidInitializer = not (checker.isInitializerStringOrNumberLiteralExpression(initializer) or c:isInitializerSimpleLiteralEnumReference(initializer) or initializer.kind == Kind.TrueKeyword or initializer.kind == Kind.FalseKeyword or checker.isInitializerBigIntLiteralExpression(initializer))
        local isConstOrReadonly = checker.isDeclarationReadonly(node) or ast.IsVariableDeclaration(node) and c:isVarConstLike(node)
        if isConstOrReadonly and (typeNode == nil) then
            if isInvalidInitializer then
                return c:grammarErrorOnNode(initializer, diagnostics.A_const_initializer_in_an_ambient_context_must_be_a_string_or_numeric_literal_or_literal_enum_reference)
            end
        else
            return c:grammarErrorOnNode(initializer, diagnostics.Initializers_are_not_allowed_in_ambient_contexts)
        end
    end

    return false
end

function checker.isInitializerStringOrNumberLiteralExpression(expr)
    return ast.IsStringOrNumericLiteralLike(expr) or
        expr.kind == Kind.PrefixUnaryExpression and expr:AsPrefixUnaryExpression().operator == Kind.MinusToken and expr:AsPrefixUnaryExpression().operand.kind == Kind.NumericLiteral
end

function checker.isInitializerBigIntLiteralExpression(expr)
    if expr.kind == Kind.BigIntLiteral then
        return true
    end

    if expr.kind == Kind.PrefixUnaryExpression then
        local unaryExpr = expr:AsPrefixUnaryExpression()
        return unaryExpr.operator == Kind.MinusToken and unaryExpr.operand.kind == Kind.BigIntLiteral
    end

    return false
end

function Checker:isInitializerSimpleLiteralEnumReference(expr)
    if ast.IsPropertyAccessExpression(expr) then
        return self:checkExpressionCached(expr).flags & TypeFlags.EnumLike ~= 0
    end

    if ast.IsElementAccessExpression(expr) then
        local elementAccess = expr:AsElementAccessExpression()

        return checker.isInitializerStringOrNumberLiteralExpression(elementAccess.argumentExpression) and
            ast.IsEntityNameExpression(elementAccess.expression) and
            self:checkExpressionCached(expr).flags & TypeFlags.EnumLike ~= 0
    end

    return false
end

function Checker:checkGrammarTopLevelElementForRequiredDeclareModifier(node)
    -- A declare modifier is required for any top level .d.ts declaration except export=, export default, export as namespace
    -- interfaces and imports categories:
    --
    --  DeclarationElement:
    --     ExportAssignment
    --     export_opt   InterfaceDeclaration
    --     export_opt   TypeAliasDeclaration
    --     export_opt   ImportDeclaration
    --     export_opt   ExternalImportDeclaration
    --     export_opt   AmbientDeclaration
    --
    -- TODO: The spec needs to be amended to reflect this grammar.
    if node.kind == Kind.InterfaceDeclaration or node.kind == Kind.TypeAliasDeclaration or node.kind == Kind.ImportDeclaration or node.kind == Kind.JSImportDeclaration or node.kind == Kind.ImportEqualsDeclaration or node.kind == Kind.ExportDeclaration or node.kind == Kind.ExportAssignment or node.kind == Kind.NamespaceExportDeclaration or ast.HasSyntacticModifier(node, ModifierFlags.Ambient | ModifierFlags.Export | ModifierFlags.Default) then
        return false
    end

    return self:grammarErrorOnFirstToken(node, diagnostics.Top_level_declarations_in_d_ts_files_must_start_with_either_a_declare_or_export_modifier)
end

function Checker:checkGrammarTopLevelElementsForRequiredDeclareModifier(file)
    for _, decl in ipairs(file.statements.nodes or {}) do
        if ast.IsDeclarationNode(decl) or decl.kind == Kind.VariableStatement then
            if self:checkGrammarTopLevelElementForRequiredDeclareModifier(decl) then
                return true
            end
        end
    end
    return false
end

function Checker:checkGrammarSourceFile(node)
    return node.flags & NodeFlags.Ambient ~= 0 and self:checkGrammarTopLevelElementsForRequiredDeclareModifier(node)
end

function Checker:checkGrammarStatementInAmbientContext(node)
    if node.flags & NodeFlags.Ambient ~= 0 then
        -- Find containing block which is either Block, ModuleBlock, SourceFile
        local links = self.nodeLinks:Get(node)
        if not links.hasReportedStatementInAmbientContext and (ast.IsFunctionLike(node.parent) or ast.IsAccessor(node.parent)) then
            links.hasReportedStatementInAmbientContext = self:grammarErrorOnFirstToken(node, diagnostics.An_implementation_cannot_be_declared_in_ambient_contexts)
            return links.hasReportedStatementInAmbientContext
        end

        -- We are either parented by another statement, or some sort of block.
        -- If we're in a block, we only want to really report an error once
        -- to prevent noisiness.  So use a bit on the block to indicate if
        -- this has already been reported, and don't report if it has.
        --
        if node.parent.kind == Kind.Block or node.parent.kind == Kind.ModuleBlock or node.parent.kind == Kind.SourceFile then
            local parentLinks = self.nodeLinks:Get(node.parent)
            -- Check if the containing block ever report this error
            if not parentLinks.hasReportedStatementInAmbientContext then
                parentLinks.hasReportedStatementInAmbientContext = self:grammarErrorOnFirstToken(node, diagnostics.Statements_are_not_allowed_in_ambient_contexts)
                return parentLinks.hasReportedStatementInAmbientContext
            end
        else
            -- We must be parented by a statement.  If so, there's no need
            -- to report the error as our parent will have already done it.
            -- debug.Assert(ast.IsStatement(node.Parent)) // !!! commented out in strada - fails if uncommented
        end
    end
    return false
end

function Checker:checkGrammarNumericLiteral(node)
    local nodeText = scanner.GetTextOfNode(node)

    -- Realism (size) checking
    -- We should test against `getTextOfNode(node)` rather than `node.text`, because `node.text` for large numeric literals can contain "."
    -- e.g. `node.text` for numeric literal `1100000000000000000000` is `1.1e21`.
    local isFractional = string.find(nodeText, ".", 1, true) ~= nil
    local isScientific = node.tokenFlags & TokenFlags.Scientific ~= 0

    -- Scientific notation (e.g. 2e54 and 1e00000000010) can't be converted to bigint
    -- Fractional numbers (e.g. 9000000000000000.001) are inherently imprecise anyway
    if isFractional or isScientific then
        return
    end

    -- Here `node` is guaranteed to be a numeric literal representing an integer.
    -- We need to judge whether the integer `node` represents is <= 2 ** 53 - 1, which can be accomplished by comparing to `value` defined below because:
    -- 1) when `node` represents an integer <= 2 ** 53 - 1, `node.text` is its exact string representation and thus `value` precisely represents the integer.
    -- 2) otherwise, although `node.text` may be imprecise string representation, its mathematical value and consequently `value` cannot be less than 2 ** 53,
    --    thus the result of the predicate won't be affected.
    local value = jsnum.FromString(node.text)
    if value <= jsnum.MaxSafeInteger then
        return
    end

    self:addErrorOrSuggestion(false, checker.createDiagnosticForNode(node, diagnostics.Numeric_literals_with_absolute_values_equal_to_2_53_or_greater_are_too_large_to_be_represented_accurately_as_integers))
end

function Checker:checkGrammarBigIntLiteral(node)
    local literalType = ast.IsLiteralTypeNode(node.parent) or ast.IsPrefixUnaryExpression(node.parent) and ast.IsLiteralTypeNode(node.parent.parent)
    if not literalType then
        -- Don't error on BigInt literals in ambient contexts
        if node.flags & NodeFlags.Ambient == 0 and self.languageVersion < ScriptTarget.ES2020 then
            if self:grammarErrorOnNode(node, diagnostics.BigInt_literals_are_not_available_when_targeting_lower_than_ES2020) then
                return true
            end
        end
    end
    return false
end

function Checker:checkGrammarImportClause(node)
    if node.phaseModifier == Kind.TypeKeyword then
        if node.flags & NodeFlags.JSDoc == 0 and node:Name() ~= nil and node.namedBindings ~= nil then
            return self:grammarErrorOnNode(node, diagnostics.A_type_only_import_can_specify_a_default_import_or_named_bindings_but_not_both)
        end
        if node.namedBindings ~= nil and node.namedBindings.kind == Kind.NamedImports then
            return self:checkGrammarTypeOnlyNamedImportsOrExports(node.namedBindings)
        end
    elseif node.phaseModifier == Kind.DeferKeyword then
        if node:Name() ~= nil then
            return self:grammarErrorOnNode(node, diagnostics.Default_imports_are_not_allowed_in_a_deferred_import)
        end
        if node.namedBindings ~= nil and node.namedBindings.kind == Kind.NamedImports then
            return self:grammarErrorOnNode(node, diagnostics.Named_imports_are_not_allowed_in_a_deferred_import)
        end
        if self.moduleKind ~= ModuleKind.ESNext and self.moduleKind ~= ModuleKind.Preserve then
            return self:grammarErrorOnNode(node, diagnostics.Deferred_imports_are_only_supported_when_the_module_flag_is_set_to_esnext_or_preserve)
        end
    end
    return false
end

function Checker:checkGrammarTypeOnlyNamedImportsOrExports(namedBindings)
    local nodeList = namedBindings:ElementList()
    for _, specifier in ipairs(nodeList.nodes or {}) do
        local specifierIsTypeOnly
        local message
        if specifier.kind == Kind.ImportSpecifier then
            specifierIsTypeOnly = specifier:IsTypeOnly()
            message = diagnostics.The_type_modifier_cannot_be_used_on_a_named_import_when_import_type_is_used_on_its_import_statement
        else
            specifierIsTypeOnly = specifier:IsTypeOnly()
            message = diagnostics.The_type_modifier_cannot_be_used_on_a_named_export_when_export_type_is_used_on_its_export_statement
        end

        if specifierIsTypeOnly then
            return self:grammarErrorOnFirstToken(specifier, message)
        end
    end

    return false
end

function Checker:checkGrammarImportCallExpression(node)
    local c = self
    if c.compilerOptions.verbatimModuleSyntax == Tristate.TSTrue and c.moduleKind == ModuleKind.CommonJS then
        return c:grammarErrorOnNode(node, checker.getVerbatimModuleSyntaxErrorMessage(node))
    end

    if node:Expression().kind == Kind.MetaProperty then
        if c.moduleKind ~= ModuleKind.ESNext and c.moduleKind ~= ModuleKind.Preserve then
            return c:grammarErrorOnNode(node, diagnostics.Deferred_imports_are_only_supported_when_the_module_flag_is_set_to_esnext_or_preserve)
        end
    elseif c.moduleKind == ModuleKind.ES2015 then
        return c:grammarErrorOnNode(node, diagnostics.Dynamic_imports_are_only_supported_when_the_module_flag_is_set_to_es2020_es2022_esnext_commonjs_amd_system_umd_node16_node18_node20_or_nodenext)
    end

    local nodeAsCall = node:AsCallExpression()
    if nodeAsCall.typeArguments ~= nil then
        return c:grammarErrorOnNode(node, diagnostics.This_use_of_import_is_invalid_import_calls_can_be_written_but_they_must_have_parentheses_and_cannot_have_type_arguments)
    end

    local nodeArguments = nodeAsCall.arguments
    local argumentNodes = nodeArguments.nodes
    if not (ModuleKind.Node16 <= c.moduleKind and c.moduleKind <= ModuleKind.NodeNext) and c.moduleKind ~= ModuleKind.ESNext and c.moduleKind ~= ModuleKind.Preserve then
        -- We are allowed trailing comma after proposal-import-assertions.
        c:checkGrammarForDisallowedTrailingComma(nodeArguments, diagnostics.Trailing_comma_not_allowed)

        if core.Len(argumentNodes) > 1 then
            local importAttributesArgument = argumentNodes[2]
            return c:grammarErrorOnNode(importAttributesArgument, diagnostics.Dynamic_imports_only_support_a_second_argument_when_the_module_option_is_set_to_esnext_node16_node18_node20_nodenext_or_preserve)
        end
    end

    if core.Len(argumentNodes) == 0 or core.Len(argumentNodes) > 2 then
        return c:grammarErrorOnNode(node, diagnostics.Dynamic_imports_can_only_accept_a_module_specifier_and_an_optional_set_of_attributes_as_arguments)
    end

    -- see: parseArgumentOrArrayLiteralElement...we use this function which parse arguments of callExpression to parse specifier for dynamic import.
    -- parseArgumentOrArrayLiteralElement allows spread element to be in an argument list which is not allowed as specifier in dynamic import.
    local spreadElement = core.Find(argumentNodes, ast.IsSpreadElement)
    if spreadElement ~= nil then
        return c:grammarErrorOnNode(spreadElement, diagnostics.Argument_of_dynamic_import_cannot_be_spread_element)
    end
    return false
end
