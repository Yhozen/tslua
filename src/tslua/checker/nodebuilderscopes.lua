local checker = require("tslua.checker")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local nodebuilder = require("tslua.nodebuilder")

local NodeBuilderImpl = checker.NodeBuilderImpl
local Kind = ast.Kind

function checker.cloneNodeBuilderContext(context)
    -- Make type parameters created within this context not consume the name outside this context
    -- The symbol serializer ends up creating many sibling scopes that all need "separate" contexts when
    -- it comes to naming things - within a normal `typeToTypeNode` call, the node builder only ever descends
    -- through the type tree, so the only cases where we could have used distinct sibling scopes was when there
    -- were multiple generic overloads with similar generated type parameter names
    -- The effect:
    -- When we write out
    -- export const x: <T>(x: T) => T
    -- export const y: <T>(x: T) => T
    -- we write it out like that, rather than as
    -- export const x: <T>(x: T) => T
    -- export const y: <T_1>(x: T_1) => T_1
    local restoreNames = context.typeParameterNames:EnterScope()
    local restoreNamesByText = context.typeParameterNamesByText:EnterScope()
    local restoreNamesByTextNextNameCount = context.typeParameterNamesByTextNextNameCount:EnterScope()
    local restoreSymbolList = context.typeParameterSymbolList:EnterScope()
    return function()
        restoreNames()
        restoreNamesByText()
        restoreNamesByTextNextNameCount()
        restoreSymbolList()
    end
end

-- localsRecord: { name, oldSymbol }

function NodeBuilderImpl:addSymbolTypeToContext(symbol, t)
    local id = ast.GetSymbolId(symbol)
    local oldType = self.ctx.enclosingSymbolTypes[id]
    local oldTypeExists = oldType ~= nil
    self.ctx.enclosingSymbolTypes[id] = t
    return function()
        if oldTypeExists then
            self.ctx.enclosingSymbolTypes[id] = oldType
        else
            self.ctx.enclosingSymbolTypes[id] = nil
        end
    end
end

function NodeBuilderImpl:enterSignatureScope(signature)
    local expandedParams = self.ch:getExpandedParameters(signature, true --[[skipUnionExpanding]])[1]
    local cleanup = self:enterNewScope(signature.declaration, expandedParams, signature.typeParameters, signature.parameters, signature.mapper)
    return expandedParams, cleanup
end

function NodeBuilderImpl:enterNewScope(declaration, expandedParams, typeParameters, originalParameters, mapper)
    local b = self
    local cleanupContext = checker.cloneNodeBuilderContext(b.ctx)
    -- For regular function/method declarations, the enclosing declaration will already be signature.declaration,
    -- so this is a no-op, but for arrow functions and function expressions, the enclosing declaration will be
    -- the declaration that the arrow function / function expression is assigned to.
    --
    -- If the parameters or return type include "typeof globalThis.paramName", using the wrong scope will lead
    -- us to believe that we can emit "typeof paramName" instead, even though that would refer to the parameter,
    -- not the global. Make sure we are in the right scope by changing the enclosingDeclaration to the function.
    --
    -- We can't use the declaration directly; it may be in another file and so we may lose access to symbols
    -- accessible to the current enclosing declaration, or gain access to symbols not accessible to the current
    -- enclosing declaration. To keep this chain accurate, insert a fake scope into the chain which makes the
    -- function's parameters visible.
    local cleanupParams
    local cleanupTypeParams
    local oldEnclosingDecl = b.ctx.enclosingDeclaration
    local oldMapper = b.ctx.mapper
    if mapper ~= nil then
        b.ctx.mapper = mapper
    end
    if b.ctx.enclosingDeclaration ~= nil and declaration ~= nil then
        -- As a performance optimization, reuse the same fake scope within this chain.
        -- This is especially needed when we are working on an excessively deep type;
        -- if we don't do this, then we spend all of our time adding more and more
        -- scopes that need to be searched in isSymbolAccessible later. Since all we
        -- really want to do is to mark certain names as unavailable, we can just keep
        -- all of the names we're introducing in one large table and push/pop from it as
        -- needed; isSymbolAccessible will walk upward and find the closest "fake" scope,
        -- which will conveniently report on any and all faked scopes in the chain.
        --
        -- It'd likely be better to store this somewhere else for isSymbolAccessible, but
        -- since that API _only_ uses the enclosing declaration (and its parents), this is
        -- seems like the best way to inject names into that search process.
        --
        -- Note that we only check the most immediate enclosingDeclaration; the only place we
        -- could potentially add another fake scope into the chain is right here, so we don't
        -- traverse all ancestors.
        local pushFakeScope = function(kind, addAll)
            -- We only ever need to look two declarations upward.
            debug.Assert(b.ctx.enclosingDeclaration ~= nil)
            local existingFakeScope
            if b.links:Has(b.ctx.enclosingDeclaration) then
                local links = b.links:Get(b.ctx.enclosingDeclaration)
                if links.fakeScopeForSignatureDeclaration ~= nil and links.fakeScopeForSignatureDeclaration == kind then
                    existingFakeScope = b.ctx.enclosingDeclaration
                end
            end
            if existingFakeScope == nil and b.ctx.enclosingDeclaration.parent ~= nil then
                if b.links:Has(b.ctx.enclosingDeclaration.parent) then
                    local links = b.links:Get(b.ctx.enclosingDeclaration.parent)
                    if links.fakeScopeForSignatureDeclaration ~= nil and links.fakeScopeForSignatureDeclaration == kind then
                        existingFakeScope = b.ctx.enclosingDeclaration.parent
                    end
                end
            end
            debug.Assert(existingFakeScope == nil or ast.IsBlock(existingFakeScope))

            local locals
            if existingFakeScope ~= nil then
                locals = existingFakeScope:Locals()
            end
            if locals == nil then
                locals = ast.NewSymbolTable()
            end
            local newLocals = {}
            local oldLocals = {}
            addAll(function(name, symbol)
                -- Add cleanup information only if we don't own the fake scope
                if existingFakeScope ~= nil then
                    local oldSymbol = locals[name]
                    if oldSymbol == nil then
                        newLocals[#newLocals + 1] = name
                    else
                        oldLocals[#oldLocals + 1] = { name = name, oldSymbol = oldSymbol }
                    end
                end
                locals[name] = symbol
            end)

            if existingFakeScope == nil then
                -- Use a Block for this; the type of the node doesn't matter so long as it
                -- has locals, and this is cheaper/easier than using a function-ish Node.
                local fakeScope = b.f:NewBlock(b.f:NewNodeList({}), false)
                b.links:Get(fakeScope).fakeScopeForSignatureDeclaration = kind
                local data = fakeScope:LocalsContainerData()
                data.locals = locals
                fakeScope.parent = b.ctx.enclosingDeclaration
                b.ctx.enclosingDeclaration = fakeScope
                return nil
            else
                -- We did not create the current scope, so we have to clean it up
                local undo = function()
                    for _, s in ipairs(newLocals) do
                        locals[s] = nil
                    end
                    for _, s in ipairs(oldLocals) do
                        locals[s.name] = s.oldSymbol
                    end
                end
                return undo
            end
        end

        if expandedParams == nil or not core.Some(expandedParams, function(p) return p ~= nil end) then
            cleanupParams = nil
        else
            cleanupParams = pushFakeScope("params", function(add)
                if expandedParams == nil then
                    return
                end
                for pIndex1, param in ipairs(expandedParams) do
                    local pIndex = pIndex1 - 1
                    local originalParam
                    if pIndex < core.Len(originalParameters) then
                        originalParam = originalParameters[pIndex + 1]
                    end
                    if originalParameters ~= nil and originalParam ~= param then
                        -- Can't reference the expanded parameter name, just the original, unless we've expanded the param list for some reason
                        if originalParam ~= nil then
                            add(originalParam.name, originalParam)
                        end
                    elseif not core.Some(param.declarations, function(d)
                        local bindElement
                        local bindPattern

                        local bindPatternWorker = function(p)
                            for _, e in ipairs(p.elements.nodes or {}) do
                                if e.kind == Kind.OmittedExpression then
                                    return
                                elseif e.kind == Kind.BindingElement then
                                    bindElement(e:AsBindingElement())
                                    return
                                else
                                    error("Unhandled binding element kind", 0)
                                end
                            end
                        end

                        local bindElementWorker = function(e)
                            if e:Name() ~= nil and ast.IsBindingPattern(e:Name()) then
                                bindPattern(e:Name():AsBindingPattern())
                                return
                            end
                            local symbol = b.ch:getSymbolOfDeclaration(e)
                            if symbol ~= nil then -- omitted expressions are now parsed as nameless binding patterns and also have no symbol
                                add(symbol.name, symbol)
                            end
                        end
                        bindElement = bindElementWorker
                        bindPattern = bindPatternWorker

                        if ast.IsParameterDeclaration(d) and d:Name() ~= nil and ast.IsBindingPattern(d:Name()) then
                            bindPattern(d:Name():AsBindingPattern())
                            return true
                        end
                        return false
                    end) then
                        add(param.name, param)
                    end
                end
            end)
        end

        if b.ctx.flags & nodebuilder.Flags.GenerateNamesForShadowedTypeParams ~= 0 and typeParameters ~= nil and core.Some(typeParameters, function(p) return p ~= nil end) then
            cleanupTypeParams = pushFakeScope("typeParams", function(add)
                if typeParameters == nil then
                    return
                end
                for _, typeParam in ipairs(typeParameters) do
                    local typeParamName = b:typeParameterToName(typeParam).text
                    add(typeParamName, typeParam.symbol)
                end
            end)
        end
    end

    return function()
        if cleanupParams ~= nil then
            cleanupParams()
        end
        if cleanupTypeParams ~= nil then
            cleanupTypeParams()
        end
        cleanupContext()
        b.ctx.enclosingDeclaration = oldEnclosingDecl
        b.ctx.mapper = oldMapper
    end
end

return checker
