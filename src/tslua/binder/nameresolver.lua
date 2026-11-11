local binder = require("tslua.binder")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local Tristate = core.Tristate

-- NameResolver is constructed from a struct literal in Go. In Lua build it with
-- setmetatable({ compilerOptions = ..., getSymbolOfDeclaration = ..., error = ..., globals = ...,
-- argumentsSymbol = ..., requireSymbol = ..., lookup = ..., symbolReferenced = ...,
-- setRequiresScopeChangeCache = ..., getRequiresScopeChangeCache = ...,
-- onPropertyWithInvalidInitializer = ..., onFailedToResolveSymbol = ...,
-- onSuccessfullyResolvedSymbol = ... }, binder.NameResolver).
-- The exported Go fields GetSymbolOfDeclaration, Error, Lookup and ArgumentsSymbol collide with
-- the unexported Go methods of the same name, so those methods get a trailing `_`
-- (getSymbolOfDeclaration_, error_, lookup_, argumentsSymbol_). Callback fields are plain functions
-- (called without self).
local NameResolver = {}
NameResolver.__index = NameResolver
binder.NameResolver = NameResolver

function NameResolver:Resolve(location, name, meaning, nameNotFoundMessage, isUse, excludeGlobals)
    local result
    local lastLocation
    local lastSelfReferenceLocation
    local propertyWithInvalidInitializer
    local associatedDeclarationForContainingInitializerOrBindingName
    local withinDeferredContext = false
    local grandparent
    local originalLocation = location -- needed for did-you-mean error reporting, which gathers candidates starting from the original location
    local nameIsConst = name == "const"
    while location ~= nil do
        if nameIsConst and ast.IsConstAssertion(location) then
            -- `const` in an `as const` has no symbol, but issues no error because there is no *actual* lookup of the type
            -- (it refers to the constant type of the expression instead)
            return nil
        end
        if ast.IsModuleOrEnumDeclaration(location) and lastLocation ~= nil and location:Name() == lastLocation then
            -- If lastLocation is the name of a namespace or enum, skip the parent since it will have is own locals that could
            -- conflict.
            lastLocation = location
            location = location.parent
        end
        local locals = location:Locals()
        -- Locals of a source file are not in scope (because they get merged into the global symbol table)
        if locals ~= nil and not ast.IsGlobalSourceFile(location) then
            result = self:lookup_(locals, name, meaning)
            if result ~= nil then
                local useResult = true
                if ast.IsFunctionLike(location) and lastLocation ~= nil and lastLocation ~= location:Body() then
                    -- symbol lookup restrictions for function-like declarations
                    -- - Type parameters of a function are in scope in the entire function declaration, including the parameter
                    --   list and return type. However, local types are only in scope in the function body.
                    -- - parameters are only in the scope of function body
                    -- This restriction does not apply to JSDoc comment types because they are parented
                    -- at a higher level than type parameters would normally be
                    if meaning & result.flags & SymbolFlags.Type ~= 0 and lastLocation.kind ~= Kind.JSDoc then
                        -- type parameters are visible in parameter list, return type and type parameter list.
                        -- Synthetic fake scopes are added for signatures so type parameters are accessible from them.
                        useResult = result.flags & SymbolFlags.TypeParameter ~= 0 and
                            (lastLocation.flags & NodeFlags.Synthesized ~= 0 or
                                lastLocation == location:Type() or
                                lastLocation.kind == Kind.Parameter or
                                lastLocation.kind == Kind.JSDocParameterTag or
                                lastLocation.kind == Kind.JSDocReturnTag or
                                lastLocation.kind == Kind.TypeParameter)
                    end
                    if meaning & result.flags & SymbolFlags.Variable ~= 0 then
                        -- expression inside parameter will lookup as normal variable scope when targeting es2015+
                        if self:useOuterVariableScopeInParameter(result, location, lastLocation) then
                            useResult = false
                        elseif result.flags & SymbolFlags.FunctionScopedVariable ~= 0 then
                            -- parameters are visible only inside function body, parameter list and return type
                            -- technically for parameter list case here we might mix parameters and variables declared in function,
                            -- however it is detected separately when checking initializers of parameters
                            -- to make sure that they reference no variables declared after them.
                            useResult = lastLocation.kind == Kind.Parameter or
                                lastLocation.flags & NodeFlags.Synthesized ~= 0 or
                                lastLocation == location:Type() and ast.FindAncestor(result.valueDeclaration, ast.IsParameterDeclaration) ~= nil
                        end
                    end
                elseif location.kind == Kind.ConditionalType then
                    -- A type parameter declared using 'infer T' in a conditional type is visible only in
                    -- the true branch of the conditional type.
                    useResult = lastLocation == location.trueType
                end
                if useResult then
                    break
                end
                result = nil
            end
        end
        withinDeferredContext = withinDeferredContext or binder.getIsDeferredContext(location, lastLocation)
        local kind = location.kind
        local isModuleCase = kind == Kind.ModuleDeclaration or
            (kind == Kind.SourceFile and ast.IsExternalOrCommonJSModule(location))
        if kind == Kind.SourceFile and not isModuleCase then
            -- not a module: nothing to do
        elseif isModuleCase then
            local moduleSymbol = self:getSymbolOfDeclaration_(location)
            if moduleSymbol == nil then
                goto switch_end
            end
            local moduleExports = moduleSymbol.exports or {}
            if ast.IsSourceFile(location) or (ast.IsModuleDeclaration(location) and location.flags & NodeFlags.Ambient ~= 0 and not ast.IsGlobalScopeAugmentation(location)) then
                -- It's an external module. First see if the module has an export default and if the local
                -- name of that export default matches.
                result = moduleExports[ast.InternalSymbolNameDefault]
                if result ~= nil then
                    local localSymbol = binder.GetLocalSymbolForExportDefault(result)
                    if localSymbol ~= nil and result.flags & meaning ~= 0 and localSymbol.name == name then
                        break
                    end
                    result = nil
                end
                -- Because of module/namespace merging, a module's exports are in scope,
                -- yet we never want to treat an export specifier as putting a member in scope.
                -- Therefore, if the name we find is purely an export specifier, it is not actually considered in scope.
                -- Two things to note about this:
                --     1. We have to check this without calling getSymbol. The problem with calling getSymbol
                --        on an export specifier is that it might find the export specifier itself, and try to
                --        resolve it as an alias. This will cause the checker to consider the export specifier
                --        a circular alias reference when it might not be.
                --     2. We check === SymbolFlags.Alias in order to check that the symbol is *purely*
                --        an alias. If we used &, we'd be throwing out symbols that have non alias aspects,
                --        which is not the desired behavior.
                local moduleExport = moduleExports[name]
                if moduleExport ~= nil and moduleExport.flags == SymbolFlags.Alias and (ast.GetDeclarationOfKind(moduleExport, Kind.ExportSpecifier) ~= nil or ast.GetDeclarationOfKind(moduleExport, Kind.NamespaceExport) ~= nil) then
                    goto switch_end
                end
            end
            if name ~= ast.InternalSymbolNameDefault then
                result = self:lookup_(moduleSymbol.exports, name, meaning & SymbolFlags.ModuleMember)
                if result ~= nil then
                    if ast.IsSourceFile(location) and location.commonJSModuleIndicator ~= nil and result.flags & SymbolFlags.Type == 0 then
                        result = nil
                    else
                        break
                    end
                end
            end
        elseif kind == Kind.EnumDeclaration then
            local enumSymbol = self:getSymbolOfDeclaration_(location)
            if enumSymbol == nil then
                goto switch_end
            end
            result = self:lookup_(enumSymbol.exports, name, meaning & SymbolFlags.EnumMember)
            if result ~= nil then
                if nameNotFoundMessage ~= nil and self.compilerOptions:GetIsolatedModules() and location.flags & NodeFlags.Ambient == 0 and ast.GetSourceFileOfNode(location) ~= ast.GetSourceFileOfNode(result.valueDeclaration) then
                    local isolatedModulesLikeFlagName = self.compilerOptions.verbatimModuleSyntax == Tristate.TSTrue and "verbatimModuleSyntax" or "isolatedModules"
                    self:error_(originalLocation, diagnostics.Cannot_access_0_from_another_file_without_qualification_when_1_is_enabled_Use_2_instead,
                        name, isolatedModulesLikeFlagName, enumSymbol.name .. "." .. name)
                end
                break
            end
        elseif kind == Kind.PropertyDeclaration then
            if not ast.IsStatic(location) then
                local ctor = ast.FindConstructorDeclaration(location.parent)
                if ctor ~= nil and ctor:Locals() ~= nil then
                    if self:lookup_(ctor:Locals(), name, meaning & SymbolFlags.Value) ~= nil then
                        -- Remember the property node, it will be used later to report appropriate error
                        propertyWithInvalidInitializer = location
                    end
                end
            end
        elseif kind == Kind.ClassDeclaration or kind == Kind.ClassExpression or kind == Kind.InterfaceDeclaration then
            result = self:lookup_(self:getSymbolOfDeclaration_(location).members, name, meaning & SymbolFlags.Type)
            if result ~= nil then
                if not binder.isTypeParameterSymbolDeclaredInContainer(result, location) then
                    -- ignore type parameters not declared in this container
                    result = nil
                    goto switch_end
                end
                if lastLocation ~= nil and ast.IsStatic(lastLocation) then
                    -- TypeScript 1.0 spec (April 2014): 3.4.1
                    -- The scope of a type parameter extends over the entire declaration with which the type
                    -- parameter list is associated, with the exception of static member declarations in classes.
                    if nameNotFoundMessage ~= nil then
                        self:error_(originalLocation, diagnostics.Static_members_cannot_reference_class_type_parameters)
                    end
                    return nil
                end
                break
            end
            if ast.IsClassExpression(location) and meaning & SymbolFlags.Class ~= 0 then
                local className = location:Name()
                if className ~= nil and name == className:Text() then
                    result = location:Symbol()
                    break
                end
            end
        elseif kind == Kind.ExpressionWithTypeArguments then
            if lastLocation == location:Expression() and ast.IsHeritageClause(location.parent) and location.parent.token == Kind.ExtendsKeyword then
                local container = location.parent.parent
                if ast.IsClassLike(container) then
                    result = self:lookup_(self:getSymbolOfDeclaration_(container).members, name, meaning & SymbolFlags.Type)
                    if result ~= nil then
                        if nameNotFoundMessage ~= nil then
                            self:error_(originalLocation, diagnostics.Base_class_expressions_cannot_reference_class_type_parameters)
                        end
                        return nil
                    end
                end
            end
        -- It is not legal to reference a class's own type parameters from a computed property name that
        -- belongs to the class. For example:
        --
        --   function foo<T>() { return '' }
        --   class C<T> { // <-- Class's own type parameter T
        --       [foo<T>()]() { } // <-- Reference to T from class's own computed property
        --   }
        elseif kind == Kind.ComputedPropertyName then
            grandparent = location.parent.parent
            if ast.IsClassLike(grandparent) or ast.IsInterfaceDeclaration(grandparent) then
                -- A reference to this grandparent's type parameters would be an error
                result = self:lookup_(self:getSymbolOfDeclaration_(grandparent).members, name, meaning & SymbolFlags.Type)
                if result ~= nil then
                    if nameNotFoundMessage ~= nil then
                        self:error_(originalLocation, diagnostics.A_computed_property_name_cannot_reference_a_type_parameter_from_its_containing_type)
                    end
                    return nil
                end
            end
        elseif kind == Kind.MethodDeclaration or kind == Kind.Constructor or kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.FunctionDeclaration then
            if meaning & SymbolFlags.Variable ~= 0 and name == "arguments" then
                result = self:argumentsSymbol_()
                break
            end
        elseif kind == Kind.FunctionExpression then
            if meaning & SymbolFlags.Variable ~= 0 and name == "arguments" then
                result = self:argumentsSymbol_()
                break
            end
            if meaning & SymbolFlags.Function ~= 0 then
                local functionName = location:Name()
                if functionName ~= nil and name == functionName:Text() then
                    result = location:Symbol()
                    break
                end
            end
        elseif kind == Kind.Decorator then
            -- Decorators are resolved at the class declaration. Resolving at the parameter
            -- or member would result in looking up locals in the method.
            --
            --   function y() {}
            --   class C {
            --       method(@y x, y) {} // <-- decorator y should be resolved at the class declaration, not the parameter.
            --   }
            --
            if location.parent ~= nil and location.parent.kind == Kind.Parameter then
                location = location.parent
            end
            --   function y() {}
            --   class C {
            --       @y method(x, y) {} // <-- decorator y should be resolved at the class declaration, not the method.
            --   }
            --
            -- class Decorators are resolved outside of the class to avoid referencing type parameters of that class.
            --
            --   type T = number;
            --   declare function y(x: T): any;
            --   @param(1 as T) // <-- T should resolve to the type alias outside of class C
            --   class C<T> {}
            if location.parent ~= nil and (ast.IsClassElement(location.parent) or location.parent.kind == Kind.ClassDeclaration) then
                location = location.parent
            end
        elseif kind == Kind.Parameter then
            local parameterDeclaration = location
            if lastLocation ~= nil and (lastLocation == parameterDeclaration.initializer or
                    lastLocation == parameterDeclaration:Name() and ast.IsBindingPattern(lastLocation)) then
                if associatedDeclarationForContainingInitializerOrBindingName == nil then
                    associatedDeclarationForContainingInitializerOrBindingName = location
                end
            end
        elseif kind == Kind.BindingElement then
            local bindingElement = location
            if lastLocation ~= nil and (lastLocation == bindingElement.initializer or
                    lastLocation == bindingElement:Name() and ast.IsBindingPattern(lastLocation)) then
                if ast.IsPartOfParameterDeclaration(location) and associatedDeclarationForContainingInitializerOrBindingName == nil then
                    associatedDeclarationForContainingInitializerOrBindingName = location
                end
            end
        elseif kind == Kind.InferType then
            if meaning & SymbolFlags.TypeParameter ~= 0 then
                local parameterName = location.typeParameter:Name()
                if parameterName ~= nil and name == parameterName:Text() then
                    result = location.typeParameter:Symbol()
                    break
                end
            end
        elseif kind == Kind.ExportSpecifier then
            local exportSpecifier = location
            if lastLocation ~= nil and lastLocation == exportSpecifier.propertyName and location.parent.parent:ModuleSpecifier() ~= nil then
                location = location.parent.parent.parent
            end
        end
        ::switch_end::
        if binder.isSelfReferenceLocation(location, lastLocation) then
            lastSelfReferenceLocation = location
        end
        lastLocation = location
        -- !!! In Strada, JSDocTemplateTag/JSDocParameterTag/JSDocReturnTag locations skip to
        -- getEffectiveContainerForJSDocTemplateTag/getHostSignatureFromJSDoc instead of location.parent.
        -- This is a no-op currently because JSDoc nodes have no locals and getEffectiveJSDocHost is not
        -- fully ported for JS assignment patterns.
        location = location.parent
    end
    -- We just climbed up parents looking for the name, meaning that we started in a descendant node of `lastLocation`.
    -- If `result === lastSelfReferenceLocation.symbol`, that means that we are somewhere inside `lastSelfReferenceLocation` looking up a name, and resolving to `lastLocation` itself.
    -- That means that this is a self-reference of `lastLocation`, and shouldn't count this when considering whether `lastLocation` is used.
    if isUse and result ~= nil and (lastSelfReferenceLocation == nil or result ~= lastSelfReferenceLocation:Symbol()) then
        if self.symbolReferenced ~= nil then
            self.symbolReferenced(result, meaning)
        end
    end
    if result == nil and not excludeGlobals then
        result = self:lookup_(self.globals, name, meaning | SymbolFlags.GlobalLookup)
    end
    if result == nil then
        if originalLocation ~= nil and ast.IsInJSFile(originalLocation) and originalLocation.parent ~= nil then
            if ast.IsRequireCall(originalLocation.parent, false --[[requireStringLiteralLikeArgument]]) then
                return self.requireSymbol
            end
        end
    end
    if nameNotFoundMessage ~= nil then
        if propertyWithInvalidInitializer ~= nil and self.onPropertyWithInvalidInitializer ~= nil and self.onPropertyWithInvalidInitializer(originalLocation, name, propertyWithInvalidInitializer, result) then
            return nil
        end
        if result == nil then
            if self.onFailedToResolveSymbol ~= nil then
                self.onFailedToResolveSymbol(originalLocation, name, meaning, nameNotFoundMessage)
            end
        else
            if self.onSuccessfullyResolvedSymbol ~= nil then
                self.onSuccessfullyResolvedSymbol(originalLocation, result, meaning, lastLocation, associatedDeclarationForContainingInitializerOrBindingName, withinDeferredContext)
            end
        end
    end
    return result
end

function NameResolver:useOuterVariableScopeInParameter(result, location, lastLocation)
    if ast.IsParameterDeclaration(lastLocation) then
        local body = location:Body()
        if body ~= nil and result.valueDeclaration ~= nil and result.valueDeclaration:Pos() >= body:Pos() and result.valueDeclaration:End() <= body:End() then
            -- check for several cases where we introduce temporaries that require moving the name/initializer of the parameter to the body
            -- - static field in a class expression
            -- - optional chaining pre-es2020
            -- - nullish coalesce pre-es2020
            -- - spread assignment in binding pattern pre-es2017
            local functionLocation = location
            local declarationRequiresScopeChange = Tristate.TSUnknown
            if self.getRequiresScopeChangeCache ~= nil then
                declarationRequiresScopeChange = self.getRequiresScopeChangeCache(functionLocation)
            end
            if declarationRequiresScopeChange == Tristate.TSUnknown then
                local requires = core.Some(functionLocation:Parameters(), function(p)
                    return self:requiresScopeChange(p)
                end)
                declarationRequiresScopeChange = requires and Tristate.TSTrue or Tristate.TSFalse
                if self.setRequiresScopeChangeCache ~= nil then
                    self.setRequiresScopeChangeCache(functionLocation, declarationRequiresScopeChange)
                end
            end
            return declarationRequiresScopeChange ~= Tristate.TSTrue
        end
    end
    return false
end

function NameResolver:requiresScopeChange(node)
    local d = node
    return self:requiresScopeChangeWorker(d:Name()) or d.initializer ~= nil and self:requiresScopeChangeWorker(d.initializer)
end

function NameResolver:requiresScopeChangeWorker(node)
    local kind = node.kind
    if kind == Kind.ArrowFunction or kind == Kind.FunctionExpression or kind == Kind.FunctionDeclaration or kind == Kind.Constructor then
        return false
    elseif kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.PropertyAssignment then
        return self:requiresScopeChangeWorker(node:Name())
    elseif kind == Kind.PropertyDeclaration then
        if ast.HasStaticModifier(node) then
            return not self.compilerOptions:GetEmitStandardClassFields()
        end
        return self:requiresScopeChangeWorker(node:Name())
    else
        if ast.IsNullishCoalesce(node) or ast.IsOptionalChain(node) then
            return self.compilerOptions:GetEmitScriptTarget() < core.ScriptTarget.ES2020
        end
        if ast.IsBindingElement(node) and node.dotDotDotToken ~= nil and ast.IsObjectBindingPattern(node.parent) then
            return self.compilerOptions:GetEmitScriptTarget() < core.ScriptTarget.ES2017
        end
        if ast.IsTypeNode(node) then
            return false
        end
        return node:ForEachChild(function(n)
            return self:requiresScopeChangeWorker(n)
        end)
    end
end

function NameResolver:error_(location, message, ...)
    if self.error ~= nil then
        self.error(location, message, ...)
    end
    -- Default implementation does not report errors
end

function NameResolver:getSymbolOfDeclaration_(node)
    if self.getSymbolOfDeclaration ~= nil then
        return self.getSymbolOfDeclaration(node)
    end

    -- Default implementation does not support merged symbols
    return node:Symbol()
end

function NameResolver:lookup_(symbols, name, meaning)
    if self.lookup ~= nil then
        return self.lookup(symbols, name, meaning)
    end
    -- Default implementation does not support following aliases or merged symbols
    if meaning ~= 0 then
        local symbol = symbols and symbols[name]
        if symbol ~= nil then
            if symbol.flags & meaning ~= 0 then
                return symbol
            end
        end
    end
    return nil
end

function NameResolver:argumentsSymbol_()
    if self.argumentsSymbol == nil then
        -- Default implementation synthesizes a transient symbol for `arguments`
        self.argumentsSymbol = ast.NewSymbol(SymbolFlags.Property | SymbolFlags.Transient, "arguments")
    end
    return self.argumentsSymbol
end

function binder.GetLocalSymbolForExportDefault(symbol)
    if not binder.isExportDefaultSymbol(symbol) or core.Len(symbol.declarations) == 0 then
        return nil
    end
    for _, decl in ipairs(symbol.declarations) do
        local localSymbol = decl:LocalSymbol()
        if localSymbol ~= nil then
            return localSymbol
        end
    end
    return nil
end

function binder.isExportDefaultSymbol(symbol)
    return symbol ~= nil and core.Len(symbol.declarations) > 0 and ast.HasSyntacticModifier(symbol.declarations[1], ModifierFlags.Default)
end

function binder.getIsDeferredContext(location, lastLocation)
    if location.kind ~= Kind.ArrowFunction and location.kind ~= Kind.FunctionExpression then
        -- initializers in instance property declaration of class like entities are executed in constructor and thus deferred
        -- A name is evaluated within the enclosing scope - so it shouldn't count as deferred
        return ast.IsTypeQueryNode(location) or
            (ast.IsFunctionLikeDeclaration(location) or location.kind == Kind.PropertyDeclaration and not ast.IsStatic(location)) and
            (lastLocation == nil or lastLocation ~= location:Name())
    end
    if lastLocation ~= nil and lastLocation == location:Name() then
        return false
    end
    -- generator functions and async functions are not inlined in control flow when immediately invoked
    if location:BodyData().asteriskToken ~= nil or ast.HasSyntacticModifier(location, ModifierFlags.Async) then
        return true
    end
    return ast.GetImmediatelyInvokedFunctionExpression(location) == nil
end

function binder.isTypeParameterSymbolDeclaredInContainer(symbol, container)
    for _, decl in ipairs(symbol.declarations or {}) do
        if decl.kind == Kind.TypeParameter then
            local parent = decl.parent
            if parent == container then
                return true
            end
        end
    end
    return false
end

function binder.isSelfReferenceLocation(node, lastLocation)
    local kind = node.kind
    if kind == Kind.Parameter then
        return lastLocation ~= nil and lastLocation == node:Name()
    elseif kind == Kind.FunctionDeclaration or kind == Kind.ClassDeclaration or kind == Kind.InterfaceDeclaration or kind == Kind.EnumDeclaration or
        kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration or kind == Kind.ModuleDeclaration then -- For `namespace N { N; }`
        return true
    end
    return false
end
