local binder = require("tslua.binder")
local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local FlowFlags = ast.FlowFlags
local ModifierFlags = ast.ModifierFlags
local JSDeclarationKind = ast.JSDeclarationKind
local ModuleInstanceState = ast.ModuleInstanceState
local ContainerFlags = binder.ContainerFlags

-- ExpandoAssignmentInfo is a plain table { node =, container =, blockScopeContainer = }.

local Binder = {}
Binder.__index = Binder
binder.Binder = Binder

local ActiveLabel = {}
ActiveLabel.__index = ActiveLabel
binder.ActiveLabel = ActiveLabel

function ActiveLabel:BreakTarget()
    return self.breakTarget
end

function ActiveLabel:ContinueTarget()
    return self.continueTarget
end

function binder.BindSourceFile(file)
    -- This is constructed this way to make the compiler "out-line" the function,
    -- avoiding most work in the common case where the file has already been bound.
    if not file:IsBound() then
        binder.bindSourceFile(file)
    end
end

-- Zero value of a Binder (Go `Binder{}`).
local function resetBinder(b)
    b.file = nil
    b.unreachableFlow = nil
    b.container = nil
    b.thisContainer = nil
    b.blockScopeContainer = nil
    b.lastContainer = nil
    b.currentFlow = nil
    b.currentBreakTarget = nil
    b.currentContinueTarget = nil
    b.currentReturnTarget = nil
    b.currentTrueTarget = nil
    b.currentFalseTarget = nil
    b.currentExceptionTarget = nil
    b.preSwitchCaseFlow = nil
    b.activeLabelList = nil
    b.emitFlags = 0
    b.seenThisKeyword = false
    b.hasExplicitReturn = false
    b.hasFlowEffects = false
    b.inAssignmentPattern = false
    b.seenParseError = false
    b.symbolCount = 0
    -- collections.Set[*ast.Symbol]: a plain table symbol -> true
    b.notConstEnumOnlyModules = {}
    b.expandoAssignments = {}
end

function binder.getBinder()
    local b = setmetatable({}, Binder)
    resetBinder(b)
    b.bindFunc = function(node) -- Allocate closure once
        return b:bind(node)
    end
    return b
end

function binder.putBinder(b)
    local bindFunc = b.bindFunc
    resetBinder(b)
    b.bindFunc = bindFunc
end

function binder.bindSourceFile(file)
    file:BindOnce(function()
        local b = binder.getBinder()
        b.file = file
        b.unreachableFlow = b:newFlowNode(FlowFlags.Unreachable)
        b:bind(file)
        b:bindDeferredExpandoAssignments()
        file.symbolCount = b.symbolCount
        binder.putBinder(b)
    end)
end

function Binder:newSymbol(flags, name)
    self.symbolCount = self.symbolCount + 1
    return ast.NewSymbol(flags, name)
end

--[[
 * Declares a Symbol for the node and adds it to symbols. Reports errors for conflicting identifier names.
 * @param symbolTable - The symbol table which node will be added to.
 * @param parent - node's parent declaration.
 * @param node - The declaration to be added to the symbol table
 * @param includes - The SymbolFlags that node has in addition to its declaration type (eg: export, ambient, etc.)
 * @param excludes - The flags which node cannot be declared alongside in a symbol table. Used to report forbidden declarations.
]]
function Binder:declareSymbol(symbolTable, parent, node, includes, excludes)
    return self:declareSymbolEx(symbolTable, parent, node, includes, excludes, false --[[isReplaceableByMethod]], false --[[isComputedName]])
end

function Binder:declareSymbolEx(symbolTable, parent, node, includes, excludes, isReplaceableByMethod, isComputedName)
    assert(isComputedName or not ast.HasDynamicName(node))
    local isDefaultExport = ast.HasSyntacticModifier(node, ModifierFlags.Default) or ast.IsExportSpecifier(node) and ast.ModuleExportNameIsDefault(node:Name())
    -- The exported symbol for an export default function/class node is always named "default"
    local name
    if isComputedName then
        name = ast.InternalSymbolNameComputed
    elseif isDefaultExport and parent ~= nil then
        name = ast.InternalSymbolNameDefault
    else
        name = self:getDeclarationName(node)
    end
    local symbol
    if name == ast.InternalSymbolNameMissing then
        symbol = self:newSymbol(SymbolFlags.None, ast.InternalSymbolNameMissing)
    else
        -- Check and see if the symbol table already has a symbol with this name.  If not,
        -- create a new symbol with this name and add it to the table.  Note that we don't
        -- give the new symbol any flags *yet*.  This ensures that it will not conflict
        -- with the 'excludes' flags we pass in.
        --
        -- If we do get an existing symbol, see if it conflicts with the new symbol we're
        -- creating.  For example, a 'var' symbol and a 'class' symbol will conflict within
        -- the same symbol table.  If we have a conflict, report the issue on each
        -- declaration we have for this symbol, and then create a new symbol for this
        -- declaration.
        --
        -- Note that when properties declared in Javascript constructors
        -- (marked by isReplaceableByMethod) conflict with another symbol, the property loses.
        -- Always. This allows the common Javascript pattern of overwriting a prototype method
        -- with an bound instance method of the same type: `this.method = this.method.bind(this)`
        --
        -- If we created a new symbol, either because we didn't have a symbol with this name
        -- in the symbol table, or we conflicted with an existing symbol, then just add this
        -- node as the sole declaration of the new symbol.
        --
        -- Otherwise, we'll be merging into a compatible existing symbol (for example when
        -- you have multiple 'vars' with the same name in the same container).  In this case
        -- just add this node into the declarations list of the symbol.
        symbol = symbolTable[name]
        if symbol == nil then
            symbol = self:newSymbol(SymbolFlags.None, name)
            symbolTable[name] = symbol
            if isReplaceableByMethod then
                symbol.flags = symbol.flags | SymbolFlags.ReplaceableByMethod
            end
        elseif isReplaceableByMethod and symbol.flags & SymbolFlags.ReplaceableByMethod == 0 then
            -- A symbol already exists, so don't add this as a declaration.
            return symbol
        elseif symbol.flags & excludes ~= 0 then
            if symbol.flags & SymbolFlags.ReplaceableByMethod ~= 0 then
                -- Javascript constructor-declared symbols can be discarded in favor of
                -- prototype symbols like methods.
                symbol = self:newSymbol(SymbolFlags.None, name)
                symbolTable[name] = symbol
            elseif not (includes & SymbolFlags.Variable ~= 0 and symbol.flags & SymbolFlags.Assignment ~= 0 or
                    includes & SymbolFlags.Assignment ~= 0 and symbol.flags & SymbolFlags.Variable ~= 0) then
                -- Assignment declarations are allowed to merge with variables, no matter what other flags they have.
                -- Report errors every position with duplicate declaration
                -- Report errors on previous encountered declarations
                local message
                if symbol.flags & SymbolFlags.BlockScopedVariable ~= 0 then
                    message = diagnostics.Cannot_redeclare_block_scoped_variable_0
                else
                    message = diagnostics.Duplicate_identifier_0
                end
                local messageNeedsName = true
                if symbol.flags & SymbolFlags.Enum ~= 0 or includes & SymbolFlags.Enum ~= 0 then
                    message = diagnostics.Enum_declarations_can_only_merge_with_namespace_or_other_enum_declarations
                    messageNeedsName = false
                end
                local multipleDefaultExports = false
                if core.Len(symbol.declarations) ~= 0 then
                    -- If the current node is a default export of some sort, then check if
                    -- there are any other default exports that we need to error on.
                    -- We'll know whether we have other default exports depending on if `symbol` already has a declaration list set.
                    if isDefaultExport then
                        message = diagnostics.A_module_cannot_have_multiple_default_exports
                        messageNeedsName = false
                        multipleDefaultExports = true
                    else
                        -- This is to properly report an error in the case "export default { }" is after export default of class declaration or function declaration.
                        -- Error on multiple export default in the following case:
                        -- 1. multiple export default of class declaration or function declaration by checking NodeFlags.Default
                        -- 2. multiple export default of export assignment. This one doesn't have NodeFlags.Default on (as export default doesn't considered as modifiers)
                        if core.Len(symbol.declarations) ~= 0 and ast.IsExportAssignment(node) and not node.isExportEquals then
                            message = diagnostics.A_module_cannot_have_multiple_default_exports
                            messageNeedsName = false
                            multipleDefaultExports = true
                        end
                    end
                end
                local declarationName = ast.GetNameOfDeclaration(node)
                if declarationName == nil then
                    declarationName = node
                end
                local diag
                if messageNeedsName then
                    diag = self:createDiagnosticForNode(declarationName, message, self:getDisplayName(node))
                else
                    diag = self:createDiagnosticForNode(declarationName, message)
                end
                if ast.IsTypeAliasDeclaration(node) and ast.NodeIsMissing(node:Type()) and ast.HasSyntacticModifier(node, ModifierFlags.Export) and symbol.flags & (SymbolFlags.Alias | SymbolFlags.Type | SymbolFlags.Namespace) ~= 0 then
                    -- export type T; - may have meant export type { T }?
                    diag:AddRelatedInfo(self:createDiagnosticForNode(node, diagnostics.Did_you_mean_0, "export type { " .. node:Name():Text() .. " }"))
                end
                for index1, declaration in ipairs(symbol.declarations or {}) do
                    local index = index1 - 1
                    local decl = ast.GetNameOfDeclaration(declaration)
                    if decl == nil then
                        decl = declaration
                    end
                    local d
                    if messageNeedsName then
                        d = self:createDiagnosticForNode(decl, message, self:getDisplayName(declaration))
                    else
                        d = self:createDiagnosticForNode(decl, message)
                    end
                    if multipleDefaultExports then
                        d:AddRelatedInfo(self:createDiagnosticForNode(declarationName, index == 0 and diagnostics.Another_export_default_is_here or diagnostics.X_and_here))
                    end
                    self:addDiagnostic(d)
                    if multipleDefaultExports then
                        diag:AddRelatedInfo(self:createDiagnosticForNode(decl, diagnostics.The_first_export_default_is_here))
                    end
                end
                self:addDiagnostic(diag)
                -- When get or set accessor conflicts with a non-accessor or an accessor of a different kind, we mark
                -- the symbol as a full accessor such that all subsequent declarations are considered conflicting. This
                -- for example ensures that a get accessor followed by a non-accessor followed by a set accessor with the
                -- same name are all marked as duplicates.
                if symbol.flags & SymbolFlags.Accessor ~= 0 and symbol.flags & SymbolFlags.Accessor ~= includes & SymbolFlags.Accessor then
                    symbol.flags = symbol.flags | SymbolFlags.Accessor
                end
                symbol = self:newSymbol(SymbolFlags.None, name)
            end
        end
    end
    self:addDeclarationToSymbol(symbol, node, includes)
    if symbol.parent == nil then
        symbol.parent = parent
    elseif symbol.parent ~= parent then
        error("Existing symbol parent should match new one")
    end
    return symbol
end

-- Should not be called on a declaration with a computed property name,
-- unless it is a well known Symbol.
function Binder:getDeclarationName(node)
    if ast.IsExportAssignment(node) then
        if node.isExportEquals then
            return ast.InternalSymbolNameExportEquals
        end
        return ast.InternalSymbolNameDefault
    end
    local name = ast.GetNameOfDeclaration(node)
    if name ~= nil then
        if ast.IsAmbientModule(node) then
            local moduleName = name:Text()
            if ast.IsGlobalScopeAugmentation(node) then
                return ast.InternalSymbolNameGlobal
            end
            return "\"" .. moduleName .. "\""
        end
        if ast.IsPrivateIdentifier(name) then
            -- containingClass exists because private names only allowed inside classes
            local containingClass = ast.GetContainingClass(node)
            if containingClass == nil then
                -- we can get here in cases where there is already a parse error.
                return ast.InternalSymbolNameMissing
            end
            return binder.GetSymbolNameForPrivateIdentifier(containingClass:Symbol(), name:Text())
        end
        if ast.IsPropertyNameLiteral(name) or ast.IsJsxNamespacedName(name) then
            return name:Text()
        end
        if ast.IsComputedPropertyName(name) then
            local nameExpression = name:Expression()
            -- treat computed property names where expression is string/numeric literal as just string/numeric literal
            if ast.IsStringOrNumericLiteralLike(nameExpression) then
                return nameExpression:Text()
            end
            if ast.IsSignedNumericLiteral(nameExpression) then
                local unaryExpression = nameExpression
                return scanner.TokenToString(unaryExpression.operator) .. unaryExpression.operand:Text()
            end
            error("Only computed properties with literal names have declaration names")
        end
        return ast.InternalSymbolNameMissing
    end
    local kind = node.kind
    if kind == Kind.Constructor then
        return ast.InternalSymbolNameConstructor
    elseif kind == Kind.FunctionType or kind == Kind.CallSignature then
        return ast.InternalSymbolNameCall
    elseif kind == Kind.ConstructorType or kind == Kind.ConstructSignature then
        return ast.InternalSymbolNameNew
    elseif kind == Kind.IndexSignature then
        return ast.InternalSymbolNameIndex
    elseif kind == Kind.ExportDeclaration then
        return ast.InternalSymbolNameExportStar
    elseif kind == Kind.SourceFile or kind == Kind.BinaryExpression then
        return ast.InternalSymbolNameExportEquals
    end
    return ast.InternalSymbolNameMissing
end

function Binder:getDisplayName(node)
    local nameNode = node:Name()
    if nameNode ~= nil then
        return scanner.DeclarationNameToString(nameNode)
    end
    local name = self:getDeclarationName(node)
    if name ~= ast.InternalSymbolNameMissing then
        return name
    end
    return "(Missing)"
end

function binder.GetSymbolNameForPrivateIdentifier(containingClassSymbol, description)
    return ast.InternalSymbolNamePrefix .. "#" .. string.format("%d", ast.GetSymbolId(containingClassSymbol)) .. "@" .. description
end

function Binder:declareModuleMember(node, symbolFlags, symbolExcludes)
    local container = self.container
    local hasExportModifier = ast.GetCombinedModifierFlags(node) & ModifierFlags.Export ~= 0 or ast.IsImplicitlyExportedJSDocDeclaration(node)
    if symbolFlags & SymbolFlags.Alias ~= 0 then
        if node.kind == Kind.ExportSpecifier or (node.kind == Kind.ImportEqualsDeclaration and hasExportModifier) then
            return self:declareSymbol(ast.GetExports(container:Symbol()), container:Symbol(), node, symbolFlags, symbolExcludes)
        end
        return self:declareSymbol(ast.GetLocals(container), nil --[[parent]], node, symbolFlags, symbolExcludes)
    end
    -- Exported module members are given 2 symbols: A local symbol that is classified with an ExportValue flag,
    -- and an associated export symbol with all the correct flags set on it. There are 2 main reasons:
    --
    --   1. We treat locals and exports of the same name as mutually exclusive within a container.
    --      That means the binder will issue a Duplicate Identifier error if you mix locals and exports
    --      with the same name in the same container.
    --      TODO: Make this a more specific error and decouple it from the exclusion logic.
    --   2. When we checkIdentifier in the checker, we set its resolved symbol to the local symbol,
    --      but return the export symbol (by calling getExportSymbolOfValueSymbolIfExported). That way
    --      when the emitter comes back to it, it knows not to qualify the name if it was found in a containing scope.
    --
    -- NOTE: Nested ambient modules always should go to to 'locals' table to prevent their automatic merge
    --       during global merging in the checker. Why? The only case when ambient module is permitted inside another module is module augmentation
    --       and this case is specially handled. Module augmentations should only be merged with original module definition
    --       and should never be merged directly with other augmentation, and the latter case would be possible if automatic merge is allowed.
    if not ast.IsAmbientModule(node) and (hasExportModifier or container.flags & NodeFlags.ExportContext ~= 0) then
        if not ast.IsLocalsContainer(container) or (ast.HasSyntacticModifier(node, ModifierFlags.Default) and self:getDeclarationName(node) == ast.InternalSymbolNameMissing) then
            return self:declareSymbol(ast.GetExports(container:Symbol()), container:Symbol(), node, symbolFlags, symbolExcludes)
            -- No local symbol for an unnamed default!
        end
        local exportKind = SymbolFlags.None
        if symbolFlags & SymbolFlags.Value ~= 0 then
            exportKind = SymbolFlags.ExportValue
        end
        local local_ = self:declareSymbol(ast.GetLocals(container), nil --[[parent]], node, exportKind, symbolExcludes)
        local_.exportSymbol = self:declareSymbol(ast.GetExports(container:Symbol()), container:Symbol(), node, symbolFlags, symbolExcludes)
        node:ExportableData().localSymbol = local_
        return local_
    end
    return self:declareSymbol(ast.GetLocals(container), nil --[[parent]], node, symbolFlags, symbolExcludes)
end

function Binder:declareClassMember(node, symbolFlags, symbolExcludes)
    if ast.IsStatic(node) then
        return self:declareSymbol(ast.GetExports(self.container:Symbol()), self.container:Symbol(), node, symbolFlags, symbolExcludes)
    end
    return self:declareSymbol(ast.GetMembers(self.container:Symbol()), self.container:Symbol(), node, symbolFlags, symbolExcludes)
end

function Binder:declareSourceFileMember(node, symbolFlags, symbolExcludes)
    if ast.IsExternalModule(self.file) then
        return self:declareModuleMember(node, symbolFlags, symbolExcludes)
    end
    return self:declareSymbol(ast.GetLocals(self.file), nil --[[parent]], node, symbolFlags, symbolExcludes)
end

function Binder:declareSymbolAndAddToSymbolTable(node, symbolFlags, symbolExcludes)
    local kind = self.container.kind
    if kind == Kind.ModuleDeclaration then
        return self:declareModuleMember(node, symbolFlags, symbolExcludes)
    elseif kind == Kind.SourceFile then
        return self:declareSourceFileMember(node, symbolFlags, symbolExcludes)
    elseif kind == Kind.ClassExpression or kind == Kind.ClassDeclaration then
        return self:declareClassMember(node, symbolFlags, symbolExcludes)
    elseif kind == Kind.EnumDeclaration then
        return self:declareSymbol(ast.GetExports(self.container:Symbol()), self.container:Symbol(), node, symbolFlags, symbolExcludes)
    elseif kind == Kind.TypeLiteral or kind == Kind.ObjectLiteralExpression or kind == Kind.InterfaceDeclaration or kind == Kind.JsxAttributes then
        return self:declareSymbol(ast.GetMembers(self.container:Symbol()), self.container:Symbol(), node, symbolFlags, symbolExcludes)
    elseif kind == Kind.FunctionType or kind == Kind.ConstructorType or kind == Kind.CallSignature or kind == Kind.ConstructSignature or
        kind == Kind.IndexSignature or kind == Kind.MethodDeclaration or kind == Kind.MethodSignature or kind == Kind.Constructor or kind == Kind.GetAccessor or
        kind == Kind.SetAccessor or kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression or kind == Kind.ArrowFunction or
        kind == Kind.ClassStaticBlockDeclaration or kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration or kind == Kind.MappedType then
        return self:declareSymbol(ast.GetLocals(self.container), nil --[[parent]], node, symbolFlags, symbolExcludes)
    end
    error("Unhandled case in declareSymbolAndAddToSymbolTable")
end

function Binder:newFlowNode(flags)
    return { flags = flags, node = nil, antecedent = nil, antecedents = nil }
end

function Binder:newFlowNodeEx(flags, node, antecedent)
    local result = self:newFlowNode(flags)
    result.node = node
    result.antecedent = antecedent
    return result
end

function Binder:createLoopLabel()
    return self:newFlowNode(FlowFlags.LoopLabel)
end

function Binder:createBranchLabel()
    return self:newFlowNode(FlowFlags.BranchLabel)
end

function Binder:createReduceLabel(target, antecedents, antecedent)
    return self:newFlowNodeEx(FlowFlags.ReduceLabel, ast.NewFlowReduceLabelData(target, antecedents), antecedent)
end

function Binder:createFlowCondition(flags, antecedent, expression)
    if antecedent.flags & FlowFlags.Unreachable ~= 0 then
        return antecedent
    end
    if expression == nil then
        if flags & FlowFlags.TrueCondition ~= 0 then
            return antecedent
        end
        return self.unreachableFlow
    end
    if (expression.kind == Kind.TrueKeyword and flags & FlowFlags.FalseCondition ~= 0 or expression.kind == Kind.FalseKeyword and flags & FlowFlags.TrueCondition ~= 0) and not ast.IsExpressionOfOptionalChainRoot(expression) and not ast.IsNullishCoalesce(expression.parent) then
        return self.unreachableFlow
    end
    if not binder.isNarrowingExpression(expression) then
        return antecedent
    end
    binder.setFlowNodeReferenced(antecedent)
    return self:newFlowNodeEx(flags, expression, antecedent)
end

function Binder:createFlowMutation(flags, antecedent, node)
    binder.setFlowNodeReferenced(antecedent)
    self.hasFlowEffects = true
    local result = self:newFlowNodeEx(flags, node, antecedent)
    if self.currentExceptionTarget ~= nil then
        self:addAntecedent(self.currentExceptionTarget, result)
    end
    return result
end

function Binder:createFlowSwitchClause(antecedent, switchStatement, clauseStart, clauseEnd)
    binder.setFlowNodeReferenced(antecedent)
    return self:newFlowNodeEx(FlowFlags.SwitchClause, ast.NewFlowSwitchClauseData(switchStatement, clauseStart, clauseEnd), antecedent)
end

function Binder:createFlowCall(antecedent, node)
    binder.setFlowNodeReferenced(antecedent)
    self.hasFlowEffects = true
    return self:newFlowNodeEx(FlowFlags.Call, node, antecedent)
end

function Binder:newFlowList(head, tail)
    return { flow = head, next = tail }
end

function Binder:combineFlowLists(head, tail)
    if head == nil then
        return tail
    end
    return self:newFlowList(head.flow, self:combineFlowLists(head.next, tail))
end

function Binder:newSingleDeclaration(declaration)
    return { declaration }
end

function binder.setFlowNodeReferenced(flow)
    -- On first reference we set the Referenced flag, thereafter we set the Shared flag
    if flow.flags & FlowFlags.Referenced == 0 then
        flow.flags = flow.flags | FlowFlags.Referenced
    else
        flow.flags = flow.flags | FlowFlags.Shared
    end
end

function Binder:addAntecedent(label, antecedent)
    if antecedent.flags & FlowFlags.Unreachable ~= 0 then
        return
    end
    -- If antecedent isn't already on the Antecedents list, add it to the end of the list
    local last
    local list = label.antecedents
    while list ~= nil do
        if list.flow == antecedent then
            return
        end
        last = list
        list = list.next
    end
    if last == nil then
        label.antecedents = self:newFlowList(antecedent, nil)
    else
        last.next = self:newFlowList(antecedent, nil)
    end
    binder.setFlowNodeReferenced(antecedent)
end

function Binder:finishFlowLabel(label)
    if label.antecedents == nil then
        return self.unreachableFlow
    end
    if label.antecedents.next == nil then
        return label.antecedents.flow
    end
    return label
end

function Binder:bind(node)
    if node == nil then
        return false
    end
    -- Even though in the AST the jsdoc @typedef node belongs to the current node,
    -- its symbol might be in the same scope with the current node's symbol. Consider:
    --
    --     /** @typedef {string | number} MyType */
    --     function foo();
    --
    -- Here the current node is "foo", which is a container, but the scope of "MyType" should
    -- not be inside "foo". Therefore we always bind @typedef before bind the parent node,
    -- and skip binding this tag later when binding all the other jsdoc tags.

    -- First we bind declaration nodes to a symbol if possible. We'll both create a symbol
    -- and then potentially add the symbol to an appropriate symbol table. Possible
    -- destination symbol tables are:
    --
    --  1) The 'exports' table of the current container's symbol.
    --  2) The 'members' table of the current container's symbol.
    --  3) The 'locals' table of the current container.
    --
    -- However, not all symbols will end up in any of these tables. 'Anonymous' symbols
    -- (like TypeLiterals for example) will not be put in any table.
    local kind = node.kind
    if kind == Kind.Identifier then
        node.flowNode = self.currentFlow
        self:checkContextualIdentifier(node)
    elseif kind == Kind.ThisKeyword or kind == Kind.SuperKeyword then
        if node.kind == Kind.ThisKeyword then
            self.seenThisKeyword = true
        end
        node.flowNode = self.currentFlow
    elseif kind == Kind.QualifiedName then
        if self.currentFlow ~= nil and ast.IsPartOfTypeQuery(node) then
            node.flowNode = self.currentFlow
        end
    elseif kind == Kind.MetaProperty then
        node.flowNode = self.currentFlow
    elseif kind == Kind.PrivateIdentifier then
        self:checkPrivateIdentifier(node)
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        if self.currentFlow ~= nil and binder.isNarrowableReference(node) then
            binder.setFlowNode(node, self.currentFlow)
        end
    elseif kind == Kind.BinaryExpression then
        local declKind = ast.GetAssignmentDeclarationKind(node)
        if declKind == JSDeclarationKind.ModuleExports then
            self:bindModuleExportsAssignment(node)
        elseif declKind == JSDeclarationKind.ExportsProperty then
            self:bindExportsOrObjectDefineProperty(node)
        elseif declKind == JSDeclarationKind.Property then
            self:bindExpandoPropertyAssignment(node)
        elseif declKind == JSDeclarationKind.ThisProperty then
            self:bindThisPropertyAssignment(node)
        end
        self:checkStrictModeBinaryExpression(node)
    elseif kind == Kind.CatchClause then
        self:checkStrictModeCatchClause(node)
    elseif kind == Kind.DeleteExpression then
        self:checkStrictModeDeleteExpression(node)
    elseif kind == Kind.PostfixUnaryExpression then
        self:checkStrictModePostfixUnaryExpression(node)
    elseif kind == Kind.PrefixUnaryExpression then
        self:checkStrictModePrefixUnaryExpression(node)
    elseif kind == Kind.WithStatement then
        self:checkStrictModeWithStatement(node)
    elseif kind == Kind.LabeledStatement then
        self:checkStrictModeLabeledStatement(node)
    elseif kind == Kind.ThisType then
        self.seenThisKeyword = true
    elseif kind == Kind.TypeParameter then
        self:bindTypeParameter(node)
    elseif kind == Kind.Parameter then
        self:bindParameter(node)
    elseif kind == Kind.VariableDeclaration then
        self:bindVariableDeclarationOrBindingElement(node)
    elseif kind == Kind.BindingElement then
        node.flowNode = self.currentFlow
        self:bindVariableDeclarationOrBindingElement(node)
    elseif kind == Kind.PropertyDeclaration or kind == Kind.PropertySignature then
        self:bindPropertyWorker(node)
    elseif kind == Kind.PropertyAssignment or kind == Kind.ShorthandPropertyAssignment then
        self:bindPropertyOrMethodOrAccessor(node, SymbolFlags.Property, SymbolFlags.PropertyExcludes)
    elseif kind == Kind.EnumMember then
        self:bindPropertyOrMethodOrAccessor(node, SymbolFlags.EnumMember, SymbolFlags.EnumMemberExcludes)
    elseif kind == Kind.CallSignature or kind == Kind.ConstructSignature or kind == Kind.IndexSignature then
        self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.Signature, SymbolFlags.None)
    elseif kind == Kind.MethodDeclaration or kind == Kind.MethodSignature then
        local excludes
        if ast.IsObjectLiteralMethod(node) then
            excludes = SymbolFlags.Value
        else
            excludes = SymbolFlags.MethodExcludes
        end
        self:bindPropertyOrMethodOrAccessor(node, SymbolFlags.Method | binder.getOptionalSymbolFlagForNode(node), excludes)
    elseif kind == Kind.FunctionDeclaration then
        self:bindFunctionDeclaration(node)
    elseif kind == Kind.Constructor then
        self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.Constructor, SymbolFlags.None)
    elseif kind == Kind.GetAccessor then
        self:bindPropertyOrMethodOrAccessor(node, SymbolFlags.GetAccessor, SymbolFlags.GetAccessorExcludes)
    elseif kind == Kind.SetAccessor then
        self:bindPropertyOrMethodOrAccessor(node, SymbolFlags.SetAccessor, SymbolFlags.SetAccessorExcludes)
    elseif kind == Kind.FunctionType or kind == Kind.ConstructorType then
        self:bindFunctionOrConstructorType(node)
    elseif kind == Kind.TypeLiteral or kind == Kind.MappedType then
        self:bindAnonymousDeclaration(node, SymbolFlags.TypeLiteral, ast.InternalSymbolNameType)
    elseif kind == Kind.ObjectLiteralExpression then
        self:bindAnonymousDeclaration(node, SymbolFlags.ObjectLiteral, ast.InternalSymbolNameObject)
    elseif kind == Kind.FunctionExpression or kind == Kind.ArrowFunction then
        self:bindFunctionExpression(node)
    elseif kind == Kind.ClassExpression or kind == Kind.ClassDeclaration then
        self:bindClassLikeDeclaration(node)
    elseif kind == Kind.InterfaceDeclaration then
        self:bindBlockScopedDeclaration(node, SymbolFlags.Interface, SymbolFlags.InterfaceExcludes)
    elseif kind == Kind.CallExpression then
        local declKind = ast.GetAssignmentDeclarationKind(node)
        if declKind == JSDeclarationKind.ObjectDefinePropertyValue then
            self:bindExpandoPropertyAssignment(node)
        elseif declKind == JSDeclarationKind.ObjectDefinePropertyExports then
            self:bindExportsOrObjectDefineProperty(node)
        end
        if ast.IsInJSFile(node) then
            self:bindCallExpression(node)
        end
    elseif kind == Kind.TypeAliasDeclaration then
        self:bindBlockScopedDeclaration(node, SymbolFlags.TypeAlias, SymbolFlags.TypeAliasExcludes)
    elseif kind == Kind.JSTypeAliasDeclaration then
        -- Top-level JSTypeAliasDeclaration nodes are processed in bindContainer
        if not ast.IsSourceFile(self.blockScopeContainer) then
            self:bindBlockScopedDeclaration(node, SymbolFlags.TypeAlias, SymbolFlags.TypeAliasExcludes)
        end
    elseif kind == Kind.EnumDeclaration then
        self:bindEnumDeclaration(node)
    elseif kind == Kind.ModuleDeclaration then
        self:bindModuleDeclaration(node)
    elseif kind == Kind.ImportEqualsDeclaration or kind == Kind.NamespaceImport or kind == Kind.ImportSpecifier or kind == Kind.ExportSpecifier then
        self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.Alias, SymbolFlags.AliasExcludes)
    elseif kind == Kind.NamespaceExportDeclaration then
        self:bindNamespaceExportDeclaration(node)
    elseif kind == Kind.ImportClause then
        self:bindImportClause(node)
    elseif kind == Kind.ExportDeclaration then
        self:bindExportDeclaration(node)
    elseif kind == Kind.ExportAssignment then
        self:bindExportAssignment(node)
    elseif kind == Kind.SourceFile then
        self:bindSourceFileIfExternalModule()
    elseif kind == Kind.JsxAttributes then
        self:bindJsxAttributes(node)
    elseif kind == Kind.JsxAttribute then
        self:bindJsxAttribute(node, SymbolFlags.Property, SymbolFlags.PropertyExcludes)
    end
    -- Then we recurse into the children of the node to bind them as well. For certain
    -- symbols we do specialized work when we recurse. For example, we'll keep track of
    -- the current 'container' node when it changes. This helps us know which symbol table
    -- a local should go into for example. Since terminal nodes are known not to have
    -- children, as an optimization we don't process those.
    local thisNodeOrAnySubnodesHasError = node.flags & NodeFlags.ThisNodeHasError ~= 0
    if node.kind > Kind.LastToken then
        local saveSeenParseError = self.seenParseError
        self.seenParseError = false
        local containerFlags = binder.GetContainerFlags(node)
        if containerFlags == ContainerFlags.None then
            self:bindChildren(node)
        else
            self:bindContainer(node, containerFlags)
        end
        if self.seenParseError then
            thisNodeOrAnySubnodesHasError = true
        end
        self.seenParseError = saveSeenParseError
    end
    if thisNodeOrAnySubnodesHasError then
        node.flags = node.flags | NodeFlags.ThisNodeOrAnySubNodesHasError
        self.seenParseError = true
    end
    return false
end

function Binder:bindPropertyWorker(node)
    local isAutoAccessor = ast.IsAutoAccessorPropertyDeclaration(node)
    local includes = isAutoAccessor and SymbolFlags.Accessor or SymbolFlags.Property
    local excludes = isAutoAccessor and SymbolFlags.AccessorExcludes or SymbolFlags.PropertyExcludes
    self:bindPropertyOrMethodOrAccessor(node, includes | binder.getOptionalSymbolFlagForNode(node), excludes)
end

function Binder:bindSourceFileIfExternalModule()
    self:setExportContextFlag(self.file)
    if ast.IsExternalOrCommonJSModule(self.file) then
        self:bindSourceFileAsExternalModule()
    elseif ast.IsJsonSourceFile(self.file) then
        self:bindSourceFileAsExternalModule()
        -- Create symbol equivalent for the module.exports = {}
        local originalSymbol = self.file.symbol
        self:declareSymbol(ast.GetExports(self.file.symbol), self.file.symbol, self.file, SymbolFlags.Property, SymbolFlags.All)
        self.file.symbol = originalSymbol
    end
end

function Binder:bindSourceFileAsExternalModule()
    self:bindAnonymousDeclaration(self.file, SymbolFlags.ValueModule, "\"" .. tspath.RemoveFileExtension(self.file:FileName()) .. "\"")
end

function Binder:bindModuleDeclaration(node)
    self:setExportContextFlag(node)
    if ast.IsAmbientModule(node) then
        if ast.HasSyntacticModifier(node, ModifierFlags.Export) then
            self:errorOnFirstToken(node, diagnostics.X_export_modifier_cannot_be_applied_to_ambient_modules_and_module_augmentations_since_they_are_always_visible)
        end
        if ast.IsModuleAugmentationExternal(node) then
            self:declareModuleSymbol(node)
        else
            local name = node:Name()
            local symbol = self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.ValueModule, SymbolFlags.ValueModuleExcludes)

            if ast.IsStringLiteral(name) then
                local pattern = core.TryParsePattern(name:Text())
                if not pattern:IsValid() then
                    -- An invalid pattern - must have multiple wildcards.
                    self:errorOnFirstToken(name, diagnostics.Pattern_0_can_have_at_most_one_Asterisk_character, name:Text())
                elseif pattern.starIndex >= 0 then
                    local modules = self.file.patternAmbientModules or {}
                    modules[#modules + 1] = { pattern = pattern, symbol = symbol }
                    self.file.patternAmbientModules = modules
                end
            end
        end
    else
        local state = self:declareModuleSymbol(node)
        if state ~= ModuleInstanceState.NonInstantiated then
            local symbol = node:Symbol()
            -- if module was already merged with some function, class or non-const enum, treat it as non-const-enum-only
            local constEnumOnlyModule = (symbol.flags & (SymbolFlags.Function | SymbolFlags.Class | SymbolFlags.RegularEnum) == 0) and
                -- Current must be `const enum` only
                state == ModuleInstanceState.ConstEnumOnly and
                -- Can't have been set to 'false' in a previous merged symbol. ('undefined' OK)
                not self.notConstEnumOnlyModules[symbol]
            if constEnumOnlyModule then
                symbol.flags = symbol.flags | SymbolFlags.ConstEnumOnlyModule
            else
                symbol.flags = symbol.flags & ~SymbolFlags.ConstEnumOnlyModule
                self.notConstEnumOnlyModules[symbol] = true
            end
        end
    end
end

function Binder:declareModuleSymbol(node)
    local state = ast.GetModuleInstanceState(node)
    local instantiated = state ~= ModuleInstanceState.NonInstantiated
    self:declareSymbolAndAddToSymbolTable(node,
        instantiated and SymbolFlags.ValueModule or SymbolFlags.NamespaceModule,
        instantiated and SymbolFlags.ValueModuleExcludes or SymbolFlags.NamespaceModuleExcludes)
    return state
end

function Binder:bindNamespaceExportDeclaration(node)
    if node:Modifiers() ~= nil then
        self:errorOnNode(node, diagnostics.Modifiers_cannot_appear_here)
    end
    if not ast.IsSourceFile(node.parent) then
        self:errorOnNode(node, diagnostics.Global_module_exports_may_only_appear_at_top_level)
    elseif not ast.IsExternalModule(node.parent) then
        self:errorOnNode(node, diagnostics.Global_module_exports_may_only_appear_in_module_files)
    elseif not node.parent.isDeclarationFile then
        self:errorOnNode(node, diagnostics.Global_module_exports_may_only_appear_in_declaration_files)
    else
        if self.file.globalExports == nil then
            self.file.globalExports = ast.NewSymbolTable()
        end
        self:declareSymbol(self.file.globalExports, self.file.symbol, node, SymbolFlags.Alias, SymbolFlags.AliasExcludes)
    end
end

function Binder:bindImportClause(node)
    if node:Name() ~= nil then
        self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.Alias, SymbolFlags.AliasExcludes)
    end
end

function Binder:bindExportDeclaration(node)
    local decl = node
    if self.container:Symbol() == nil then
        -- Export * in some sort of block construct
        self:bindAnonymousDeclaration(node, SymbolFlags.ExportStar, self:getDeclarationName(node))
    elseif decl.exportClause == nil then
        -- All export * declarations are collected in an __export symbol
        self:declareSymbol(ast.GetExports(self.container:Symbol()), self.container:Symbol(), node, SymbolFlags.ExportStar, SymbolFlags.None)
    elseif ast.IsNamespaceExport(decl.exportClause) then
        self:declareSymbol(ast.GetExports(self.container:Symbol()), self.container:Symbol(), decl.exportClause, SymbolFlags.Alias, SymbolFlags.AliasExcludes)
    end
end

function Binder:bindExportAssignment(node)
    local container = self.container
    if container:Symbol() == nil and ast.IsExportAssignment(node) then
        -- Incorrect export assignment in some sort of block construct
        self:bindAnonymousDeclaration(node, SymbolFlags.Value, self:getDeclarationName(node))
    else
        -- If there is an `export default x;` alias declaration, can't `export default` anything else.
        -- (In contrast, you can still have `export default function f() {}` and `export default interface I {}`.)
        local flags = ast.ExpressionIsAlias(node:Expression()) and SymbolFlags.Alias or SymbolFlags.Property
        local symbol = self:declareSymbol(ast.GetExports(container:Symbol()), container:Symbol(), node, flags, SymbolFlags.All)
        if node.isExportEquals then
            -- Ensure export assignments have a ValueDeclaration set.
            binder.SetValueDeclaration(symbol, node)
        end
    end
end

function Binder:bindJsxAttributes(node)
    self:bindAnonymousDeclaration(node, SymbolFlags.ObjectLiteral, ast.InternalSymbolNameJSXAttributes)
end

function Binder:bindJsxAttribute(node, symbolFlags, symbolExcludes)
    self:declareSymbolAndAddToSymbolTable(node, symbolFlags, symbolExcludes)
end

function Binder:setExportContextFlag(node)
    -- A declaration source file or ambient module declaration that contains no export declarations (but possibly regular
    -- declarations with export modifiers) is an export context in which declarations are implicitly exported.
    if node.flags & NodeFlags.Ambient ~= 0 and not self:hasExportDeclarations(node) then
        node.flags = node.flags | NodeFlags.ExportContext
    else
        node.flags = node.flags & ~NodeFlags.ExportContext
    end
end

function Binder:hasExportDeclarations(node)
    local statements
    if node.kind == Kind.SourceFile then
        statements = node:Statements()
    elseif node.kind == Kind.ModuleDeclaration then
        local body = node:Body()
        if body ~= nil and ast.IsModuleBlock(body) then
            statements = body:Statements()
        end
    end
    return core.Some(statements, function(s)
        return ast.IsExportDeclaration(s) or ast.IsExportAssignment(s)
    end)
end

function Binder:bindFunctionExpression(node)
    if not self.file.isDeclarationFile and node.flags & NodeFlags.Ambient == 0 and ast.IsAsyncFunction(node) then
        self.emitFlags = self.emitFlags | NodeFlags.HasAsyncFunctions
    end
    binder.setFlowNode(node, self.currentFlow)
    local bindingName = ast.InternalSymbolNameFunction
    if ast.IsFunctionExpression(node) and node:Name() ~= nil then
        self:checkStrictModeFunctionName(node)
        bindingName = node:Name():Text()
    end
    self:bindAnonymousDeclaration(node, SymbolFlags.Function, bindingName)
end

function Binder:bindCallExpression(node)
    -- We're only inspecting call expressions to detect CommonJS modules, so we can skip
    -- this check if we've already seen the module indicator
    if self.file.commonJSModuleIndicator == nil and ast.IsRequireCall(node, false --[[requireStringLiteralLikeArgument]]) then
        self:setCommonJSModuleIndicator(node)
    end
end

function Binder:setCommonJSModuleIndicator(node)
    if self.file.externalModuleIndicator ~= nil and self.file.externalModuleIndicator ~= self.file then
        return false
    end
    if self.file.commonJSModuleIndicator == nil then
        self.file.commonJSModuleIndicator = node
        if self.file.externalModuleIndicator == nil then
            self:bindSourceFileAsExternalModule()
        end
    end
    return true
end

function Binder:bindClassLikeDeclaration(node)
    local name = node:Name()
    if node.kind == Kind.ClassDeclaration then
        self:bindBlockScopedDeclaration(node, SymbolFlags.Class, SymbolFlags.ClassExcludes)
    elseif node.kind == Kind.ClassExpression then
        local nameText = ast.InternalSymbolNameClass
        if name ~= nil then
            nameText = name:Text()
        end
        self:bindAnonymousDeclaration(node, SymbolFlags.Class, nameText)
    end
    local symbol = node:Symbol()
    -- TypeScript 1.0 spec (April 2014): 8.4
    -- Every class automatically contains a static property member named 'prototype', the
    -- type of which is an instantiation of the class type with type Any supplied as a type
    -- argument for each type parameter. It is an error to explicitly declare a static
    -- property member with the name 'prototype'.
    --
    -- Note: we check for this here because this class may be merging into a module.  The
    -- module might have an exported variable called 'prototype'.  We can't allow that as
    -- that would clash with the built-in 'prototype' for the class.
    local prototypeSymbol = self:newSymbol(SymbolFlags.Property | SymbolFlags.Prototype, "prototype")
    local symbolExport = ast.GetExports(symbol)[prototypeSymbol.name]
    if symbolExport ~= nil then
        self:errorOnNode(symbolExport.declarations[1], diagnostics.Duplicate_identifier_0, ast.SymbolName(prototypeSymbol))
    end
    ast.GetExports(symbol)[prototypeSymbol.name] = prototypeSymbol
    prototypeSymbol.parent = symbol
end

function Binder:bindPropertyOrMethodOrAccessor(node, symbolFlags, symbolExcludes)
    if not self.file.isDeclarationFile and node.flags & NodeFlags.Ambient == 0 and ast.IsAsyncFunction(node) then
        self.emitFlags = self.emitFlags | NodeFlags.HasAsyncFunctions
    end
    if self.currentFlow ~= nil and ast.IsObjectLiteralOrClassExpressionMethodOrAccessor(node) then
        binder.setFlowNode(node, self.currentFlow)
    end
    if ast.HasDynamicName(node) then
        self:bindAnonymousDeclaration(node, symbolFlags, ast.InternalSymbolNameComputed)
    else
        self:declareSymbolAndAddToSymbolTable(node, symbolFlags, symbolExcludes)
    end
end

function Binder:bindFunctionOrConstructorType(node)
    -- For a given function symbol "<...>(...) => T" we want to generate a symbol identical
    -- to the one we would get for: { <...>(...): T }
    --
    -- We do that by making an anonymous type literal symbol, and then setting the function
    -- symbol as its sole member. To the rest of the system, this symbol will be indistinguishable
    -- from an actual type literal symbol you would have gotten had you used the long form.
    local symbol = self:newSymbol(SymbolFlags.Signature, self:getDeclarationName(node))
    self:addDeclarationToSymbol(symbol, node, SymbolFlags.Signature)
    local typeLiteralSymbol = self:newSymbol(SymbolFlags.TypeLiteral, ast.InternalSymbolNameType)
    self:addDeclarationToSymbol(typeLiteralSymbol, node, SymbolFlags.TypeLiteral)
    typeLiteralSymbol.members = ast.NewSymbolTable()
    typeLiteralSymbol.members[symbol.name] = symbol
end

function Binder:addLateBoundAssignmentDeclarationToSymbol(node, symbol)
    local exports = ast.GetExports(symbol)
    local assignmentSymbol = exports[ast.InternalSymbolNameAssignmentDeclaration]
    if assignmentSymbol == nil then
        assignmentSymbol = self:newSymbol(SymbolFlags.None, ast.InternalSymbolNameAssignmentDeclaration)
        exports[ast.InternalSymbolNameAssignmentDeclaration] = assignmentSymbol
    end
    local decls = assignmentSymbol.declarations or {}
    decls[#decls + 1] = node
    assignmentSymbol.declarations = decls
end

function Binder:bindModuleExportsAssignment(node)
    if self:setCommonJSModuleIndicator(node) then
        local container = self.file
        local flags = ast.ExpressionIsAlias(node.right) and SymbolFlags.Alias or SymbolFlags.Property
        local symbol = self:declareSymbol(ast.GetExports(container:Symbol()), container:Symbol(), node, flags, 0)
        binder.SetValueDeclaration(symbol, node)
    end
end

function Binder:bindExpandoPropertyAssignment(node)
    self.expandoAssignments[#self.expandoAssignments + 1] = {
        node = node,
        container = self.container,
        blockScopeContainer = self.blockScopeContainer,
    }
end

function Binder:bindDeferredExpandoAssignments()
    for _, info in ipairs(self.expandoAssignments) do
        self.container = info.container
        self.blockScopeContainer = info.blockScopeContainer
        self:bindDeferredExpandoAssignment(info.node)
    end
end

-- If the given module symbol has an export= symbol, promote exports with a type or namespace meaning
-- from the module symbol onto the export= symbol and, if any such exports exist, mark the export=
-- symbol as a namespace module.
function Binder:bindCommonJSTypeExports(moduleSymbol)
    local moduleExports = moduleSymbol.exports
    local exportEquals = moduleExports and moduleExports[ast.InternalSymbolNameExportEquals]
    if exportEquals ~= nil then
        for _, symbol in pairs(moduleExports) do
            if symbol.name ~= ast.InternalSymbolNameExportEquals and symbol.flags & (SymbolFlags.Type | SymbolFlags.Namespace) ~= 0 then
                ast.GetExports(exportEquals)[symbol.name] = symbol
                exportEquals.flags = exportEquals.flags | SymbolFlags.NamespaceModule
            end
        end
    end
end

function Binder:bindDeferredExpandoAssignment(node)
    local parent = binder.getParentOfPropertyAssignment(node)
    local symbol = self:lookupEntity(parent, self.blockScopeContainer)
    if symbol == nil then
        symbol = self:lookupEntity(parent, self.container)
    end
    symbol = binder.getInitializerSymbol(symbol)
    if symbol ~= nil then
        if ast.HasDynamicName(node) then
            self:bindAnonymousDeclaration(node, SymbolFlags.Property | SymbolFlags.Assignment, ast.InternalSymbolNameComputed)
            self:addLateBoundAssignmentDeclarationToSymbol(node, symbol)
        else
            -- We declare expandos only when there are no non-expando declarations for that name.
            local exports = ast.GetExports(symbol)
            local existing = exports[self:getDeclarationName(node)]
            if existing == nil or existing.flags & SymbolFlags.Assignment ~= 0 then
                self:declareSymbol(exports, symbol, node, SymbolFlags.Property | SymbolFlags.Assignment, SymbolFlags.PropertyExcludes)
            end
        end
    end
end

function binder.getParentOfPropertyAssignment(node)
    if node.kind == Kind.BinaryExpression then
        return node.left:Expression()
    elseif node.kind == Kind.CallExpression then
        return node:Arguments()[1]
    end
    error("Unhandled case in getParentOfPropertyAssignment")
end

function Binder:bindExportsOrObjectDefineProperty(node)
    if self:setCommonJSModuleIndicator(node) then
        local container = self.file
        local flags = (ast.IsBinaryExpression(node) and ast.ExpressionIsAlias(node.right)) and SymbolFlags.Alias or SymbolFlags.FunctionScopedVariable
        self:declareSymbol(ast.GetExports(container:Symbol()), container:Symbol(), node, flags, SymbolFlags.FunctionScopedVariableExcludes)
    end
end

function binder.getInitializerSymbol(symbol)
    if symbol == nil or symbol.valueDeclaration == nil then
        return nil
    end
    local declaration = symbol.valueDeclaration
    -- For an assignment 'fn.xxx = ...', where 'fn' is a previously declared function or a previously
    -- declared const variable initialized with a function expression or arrow function, we add expando
    -- property declarations to the function's symbol. This also applies to class expressions in JS files,
    -- and empty object literals in JS files when the declaration doesn't have a type annotation.
    if ast.IsFunctionDeclaration(declaration) or ast.IsInJSFile(declaration) and ast.IsClassDeclaration(declaration) then
        return symbol
    elseif ast.IsVariableDeclaration(declaration) and
        (declaration.parent.flags & NodeFlags.Const ~= 0 or ast.IsInJSFile(declaration)) then
        local initializer = declaration:Initializer()
        if ast.IsExpandoInitializer(declaration, initializer) then
            return initializer:Symbol()
        end
    elseif ast.IsBinaryExpression(declaration) and ast.IsInJSFile(declaration) then
        local initializer = declaration.right
        if ast.IsExpandoInitializer(declaration, initializer) then
            return initializer:Symbol()
        end
    end
    return nil
end

function Binder:bindThisPropertyAssignment(node)
    if not ast.IsInJSFile(node) then
        return
    end
    local bin = node
    if ast.IsPropertyAccessExpression(bin.left) and ast.IsPrivateIdentifier(bin.left:Name()) or
        self.thisContainer == nil then
        return
    end
    local classSymbol, symbolTable = self:getThisClassAndSymbolTable()
    if symbolTable ~= nil then
        if ast.HasDynamicName(node) then
            self:declareSymbolEx(symbolTable, classSymbol, node, SymbolFlags.Property, SymbolFlags.None, true --[[isReplaceableByMethod]], true --[[isComputedName]])
            self:addLateBoundAssignmentDeclarationToSymbol(node, classSymbol)
        else
            self:declareSymbolEx(symbolTable, classSymbol, node, SymbolFlags.Property | SymbolFlags.Assignment, SymbolFlags.None, true --[[isReplaceableByMethod]], false --[[isComputedName]])
        end
    elseif self.thisContainer.kind ~= Kind.FunctionDeclaration and self.thisContainer.kind ~= Kind.FunctionExpression then
        -- !!! constructor functions
        error("Unhandled case in bindThisPropertyAssignment: " .. tostring(ast.Kind_names[self.thisContainer.kind]))
    end
end

function Binder:getThisClassAndSymbolTable()
    if self.thisContainer == nil then
        return nil, nil
    end
    local classSymbol, symbolTable
    local kind = self.thisContainer.kind
    if kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression then
        -- !!! constructor functions
    elseif kind == Kind.Constructor or kind == Kind.PropertyDeclaration or kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.ClassStaticBlockDeclaration then
        -- this.property assignment in class member -- bind to the containing class
        classSymbol = self.thisContainer.parent:Symbol()
        if ast.IsStatic(self.thisContainer) then
            symbolTable = ast.GetExports(classSymbol)
        else
            symbolTable = ast.GetMembers(classSymbol)
        end
    end
    return classSymbol, symbolTable
end

function Binder:bindEnumDeclaration(node)
    if ast.IsEnumConst(node) then
        self:bindBlockScopedDeclaration(node, SymbolFlags.ConstEnum, SymbolFlags.ConstEnumExcludes)
    else
        self:bindBlockScopedDeclaration(node, SymbolFlags.RegularEnum, SymbolFlags.RegularEnumExcludes)
    end
end

function Binder:bindVariableDeclarationOrBindingElement(node)
    self:checkStrictModeEvalOrArguments(node, node:Name())
    local name = node:Name()
    if name ~= nil and not ast.IsBindingPattern(name) then
        if ast.IsVariableDeclarationInitializedToRequire(node) then
            self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.Alias, SymbolFlags.AliasExcludes)
        elseif ast.IsBlockOrCatchScoped(node) then
            self:bindBlockScopedDeclaration(node, SymbolFlags.BlockScopedVariable, SymbolFlags.BlockScopedVariableExcludes)
        elseif ast.IsPartOfParameterDeclaration(node) then
            -- It is safe to walk up parent chain to find whether the node is a destructuring parameter declaration
            -- because its parent chain has already been set up, since parents are set before descending into children.
            --
            -- If node is a binding element in parameter declaration, we need to use ParameterExcludes.
            -- Using ParameterExcludes flag allows the compiler to report an error on duplicate identifiers in Parameter Declaration
            -- For example:
            --      function foo([a,a]) {} // Duplicate Identifier error
            --      function bar(a,a) {}   // Duplicate Identifier error, parameter declaration in this case is handled in bindParameter
            --                             // which correctly set excluded symbols
            self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.FunctionScopedVariable, SymbolFlags.ParameterExcludes)
        else
            self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.FunctionScopedVariable, SymbolFlags.FunctionScopedVariableExcludes)
        end
    end
end

function Binder:bindParameter(node)
    local decl = node
    if node.flags & NodeFlags.Ambient == 0 then
        -- It is a SyntaxError if the identifier eval or arguments appears within a FormalParameterList of a
        -- strict mode FunctionLikeDeclaration or FunctionExpression(13.1)
        self:checkStrictModeEvalOrArguments(node, decl:Name())
    end
    if ast.IsBindingPattern(decl:Name()) then
        local index = -1
        for i, p in ipairs(node.parent:Parameters()) do
            if p == node then
                index = i - 1
                break
            end
        end
        self:bindAnonymousDeclaration(node, SymbolFlags.FunctionScopedVariable, "__" .. string.format("%d", index))
    else
        self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.FunctionScopedVariable, SymbolFlags.ParameterExcludes)
    end
    -- If this is a property-parameter, then also declare the property symbol into the
    -- containing class.
    if ast.IsParameterPropertyDeclaration(node, node.parent) then
        local classDeclaration = node.parent.parent
        local flags = SymbolFlags.Property | (decl.questionToken ~= nil and SymbolFlags.Optional or SymbolFlags.None)
        self:declareSymbol(ast.GetMembers(classDeclaration:Symbol()), classDeclaration:Symbol(), node, flags, SymbolFlags.PropertyExcludes)
    end
end

function Binder:bindFunctionDeclaration(node)
    if not self.file.isDeclarationFile and node.flags & NodeFlags.Ambient == 0 and ast.IsAsyncFunction(node) then
        self.emitFlags = self.emitFlags | NodeFlags.HasAsyncFunctions
    end
    self:checkStrictModeFunctionName(node)
    self:bindBlockScopedDeclaration(node, SymbolFlags.Function, SymbolFlags.FunctionExcludes)
end

function Binder:getInferTypeContainer(node)
    local extendsType = ast.FindAncestor(node, function(n)
        local parent = n.parent
        return parent ~= nil and ast.IsConditionalTypeNode(parent) and parent.extendsType == n
    end)
    if extendsType ~= nil then
        return extendsType.parent
    end
    return nil
end

function Binder:bindAnonymousDeclaration(node, symbolFlags, name)
    local symbol = self:newSymbol(symbolFlags, name)
    if symbolFlags & (SymbolFlags.EnumMember | SymbolFlags.ClassMember) ~= 0 then
        symbol.parent = self.container:Symbol()
    end
    self:addDeclarationToSymbol(symbol, node, symbolFlags)
end

function Binder:bindBlockScopedDeclaration(node, symbolFlags, symbolExcludes)
    local kind = self.blockScopeContainer.kind
    if kind == Kind.ModuleDeclaration then
        self:declareModuleMember(node, symbolFlags, symbolExcludes)
    elseif kind == Kind.SourceFile and ast.IsExternalOrCommonJSModule(self.container) then
        self:declareModuleMember(node, symbolFlags, symbolExcludes)
    else
        self:declareSymbol(ast.GetLocals(self.blockScopeContainer), nil --[[parent]], node, symbolFlags, symbolExcludes)
    end
end

function Binder:bindTypeParameter(node)
    if node.parent.kind == Kind.InferType then
        local container = self:getInferTypeContainer(node.parent)
        if container ~= nil then
            self:declareSymbol(ast.GetLocals(container), nil --[[parent]], node, SymbolFlags.TypeParameter, SymbolFlags.TypeParameterExcludes)
        else
            self:bindAnonymousDeclaration(node, SymbolFlags.TypeParameter, self:getDeclarationName(node))
        end
    else
        self:declareSymbolAndAddToSymbolTable(node, SymbolFlags.TypeParameter, SymbolFlags.TypeParameterExcludes)
    end
end

function Binder:lookupEntity(node, container)
    if ast.IsIdentifier(node) then
        return self:lookupName(node:Text(), container)
    end
    if node:Expression().kind == Kind.ThisKeyword then
        local _, symbolTable = self:getThisClassAndSymbolTable()
        if symbolTable ~= nil then
            local name = ast.GetElementOrPropertyAccessName(node)
            if name ~= nil then
                return symbolTable[name:Text()]
            end
        end
        return nil
    end
    local symbol = binder.getInitializerSymbol(self:lookupEntity(node:Expression(), container))
    if symbol ~= nil and symbol.exports ~= nil then
        local name = ast.GetElementOrPropertyAccessName(node)
        if name ~= nil then
            return symbol.exports[name:Text()]
        end
    end
    return nil
end

function Binder:lookupName(name, container)
    local localsContainer = container:LocalsContainerData()
    if localsContainer ~= nil then
        local local_ = localsContainer.locals and localsContainer.locals[name]
        if local_ ~= nil then
            return local_.exportSymbol or local_
        end
    end
    local declaration = container:DeclarationData()
    if declaration ~= nil and declaration.symbol ~= nil then
        return declaration.symbol.exports and declaration.symbol.exports[name]
    end
    return nil
end

-- The binder visits every node in the syntax tree so it is a convenient place to perform a single localized
-- check for reserved words used as identifiers in strict mode code, as well as `yield` or `await` in
-- [Yield] or [Await] contexts, respectively.
function Binder:checkContextualIdentifier(node)
    -- Report error only if there are no parse errors in file
    if core.Len(self.file:Diagnostics()) == 0 and node.flags & NodeFlags.Ambient == 0 and node.flags & NodeFlags.JSDoc == 0 and not ast.IsIdentifierName(node) then
        -- strict mode identifiers
        local originalKeywordKind = scanner.GetIdentifierToken(node:Text())
        if originalKeywordKind == Kind.Identifier then
            return
        end
        if originalKeywordKind >= Kind.FirstFutureReservedWord and originalKeywordKind <= Kind.LastFutureReservedWord then
            self:errorOnNode(node, self:getStrictModeIdentifierMessage(node), scanner.DeclarationNameToString(node))
        elseif originalKeywordKind == Kind.AwaitKeyword then
            if ast.IsExternalModule(self.file) and ast.IsInTopLevelContext(node) then
                self:errorOnNode(node, diagnostics.Identifier_expected_0_is_a_reserved_word_at_the_top_level_of_a_module, scanner.DeclarationNameToString(node))
            elseif node.flags & NodeFlags.AwaitContext ~= 0 then
                self:errorOnNode(node, diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, scanner.DeclarationNameToString(node))
            end
        elseif originalKeywordKind == Kind.YieldKeyword and node.flags & NodeFlags.YieldContext ~= 0 then
            self:errorOnNode(node, diagnostics.Identifier_expected_0_is_a_reserved_word_that_cannot_be_used_here, scanner.DeclarationNameToString(node))
        end
    end
end

function Binder:checkPrivateIdentifier(node)
    if node:Text() == "#constructor" then
        -- Report error only if there are no parse errors in file
        if core.Len(self.file:Diagnostics()) == 0 then
            self:errorOnNode(node, diagnostics.X_constructor_is_a_reserved_word, scanner.DeclarationNameToString(node))
        end
    end
end

function Binder:getStrictModeIdentifierMessage(node)
    -- Provide specialized messages to help the user understand why we think they're in
    -- strict mode.
    if ast.GetContainingClass(node) ~= nil then
        return diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode_Class_definitions_are_automatically_in_strict_mode
    end
    if self.file.externalModuleIndicator ~= nil then
        return diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode_Modules_are_automatically_in_strict_mode
    end
    return diagnostics.Identifier_expected_0_is_a_reserved_word_in_strict_mode
end

-- Should be called only on prologue directives (ast.IsPrologueDirective(node) should be true)
function binder.isUseStrictPrologueDirective(sourceFile, node)
    local nodeText = scanner.GetSourceTextOfNodeFromSourceFile(sourceFile, node:Expression(), false --[[includeTrivia]])
    -- Note: the node text must be exactly "use strict" or 'use strict'.  It is not ok for the
    -- string to contain unicode escapes (as per ES5).
    return nodeText == "\"use strict\"" or nodeText == "'use strict'"
end

function binder.FindUseStrictPrologue(sourceFile, statements)
    for _, statement in ipairs(statements or {}) do
        if ast.IsPrologueDirective(statement) then
            if binder.isUseStrictPrologueDirective(sourceFile, statement) then
                return statement
            end
        else
            return nil
        end
    end

    return nil
end

function Binder:checkStrictModeFunctionName(node)
    if node.flags & NodeFlags.Ambient == 0 then
        -- It is a SyntaxError if the identifier eval or arguments appears within a FormalParameterList of a strict mode FunctionDeclaration or FunctionExpression (13.1))
        self:checkStrictModeEvalOrArguments(node, node:Name())
    end
end

function Binder:getStrictModeBlockScopeFunctionDeclarationMessage(node)
    -- Provide specialized messages to help the user understand why we think they're in strict mode.
    if ast.GetContainingClass(node) ~= nil then
        return diagnostics.Function_declarations_are_not_allowed_inside_blocks_in_strict_mode_when_targeting_ES5_Class_definitions_are_automatically_in_strict_mode
    end
    if self.file.externalModuleIndicator ~= nil then
        return diagnostics.Function_declarations_are_not_allowed_inside_blocks_in_strict_mode_when_targeting_ES5_Modules_are_automatically_in_strict_mode
    end
    return diagnostics.Function_declarations_are_not_allowed_inside_blocks_in_strict_mode_when_targeting_ES5
end

function Binder:checkStrictModeBinaryExpression(node)
    local expr = node
    if ast.IsLeftHandSideExpression(expr.left) and ast.IsAssignmentOperator(expr.operatorToken.kind) then
        -- ECMA 262 (Annex C) The identifier eval or arguments may not appear as the LeftHandSideExpression of an
        -- Assignment operator(11.13) or of a PostfixExpression(11.3)
        self:checkStrictModeEvalOrArguments(node, expr.left)
    end
end

function Binder:checkStrictModeCatchClause(node)
    -- It is a SyntaxError if a TryStatement with a Catch occurs within strict code and the Identifier of the
    -- Catch production is eval or arguments
    local clause = node
    if clause.variableDeclaration ~= nil then
        self:checkStrictModeEvalOrArguments(node, clause.variableDeclaration:Name())
    end
end

function Binder:checkStrictModeDeleteExpression(node)
    -- Grammar checking
    local expr = node
    if expr.expression.kind == Kind.Identifier then
        -- When a delete operator occurs within strict mode code, a SyntaxError is thrown if its
        -- UnaryExpression is a direct reference to a variable, function argument, or function name
        self:errorOnNode(expr.expression, diagnostics.X_delete_cannot_be_called_on_an_identifier_in_strict_mode)
    end
end

function Binder:checkStrictModePostfixUnaryExpression(node)
    -- Grammar checking
    -- The identifier eval or arguments may not appear as the LeftHandSideExpression of an
    -- Assignment operator(11.13) or of a PostfixExpression(11.3) or as the UnaryExpression
    -- operated upon by a Prefix Increment(11.4.4) or a Prefix Decrement(11.4.5) operator.
    self:checkStrictModeEvalOrArguments(node, node.operand)
end

function Binder:checkStrictModePrefixUnaryExpression(node)
    -- Grammar checking
    local expr = node
    if expr.operator == Kind.PlusPlusToken or expr.operator == Kind.MinusMinusToken then
        self:checkStrictModeEvalOrArguments(node, expr.operand)
    end
end

function Binder:checkStrictModeWithStatement(node)
    -- Grammar checking for withStatement
    self:errorOnFirstToken(node, diagnostics.X_with_statements_are_not_allowed_in_strict_mode)
end

function Binder:checkStrictModeLabeledStatement(node)
    -- Grammar checking for labeledStatement
    local data = node
    if ast.IsDeclarationStatement(data.statement) or ast.IsVariableStatement(data.statement) then
        self:errorOnFirstToken(data.label, diagnostics.A_label_is_not_allowed_here)
    end
end

function binder.isEvalOrArgumentsIdentifier(node)
    if ast.IsIdentifier(node) then
        local text = node:Text()
        return text == "eval" or text == "arguments"
    end
    return false
end

function Binder:checkStrictModeEvalOrArguments(contextNode, name)
    if name ~= nil and binder.isEvalOrArgumentsIdentifier(name) then
        -- We check first if the name is inside class declaration or class expression; if so give explicit message
        -- otherwise report generic error message.
        self:errorOnNode(name, self:getStrictModeEvalOrArgumentsMessage(contextNode), name:Text())
    end
end

function Binder:getStrictModeEvalOrArgumentsMessage(node)
    -- Provide specialized messages to help the user understand why we think they're in strict mode
    if ast.GetContainingClass(node) ~= nil then
        return diagnostics.Code_contained_in_a_class_is_evaluated_in_JavaScript_s_strict_mode_which_does_not_allow_this_use_of_0_For_more_information_see_https_Colon_Slash_Slashdeveloper_mozilla_org_Slashen_US_Slashdocs_SlashWeb_SlashJavaScript_SlashReference_SlashStrict_mode
    end
    if self.file.externalModuleIndicator ~= nil then
        return diagnostics.Invalid_use_of_0_Modules_are_automatically_in_strict_mode
    end
    return diagnostics.Invalid_use_of_0_in_strict_mode
end

-- All container nodes are kept on a linked list in declaration order. This list is used by
-- the getLocalNameOfContainer function in the type checker to validate that the local name
-- used for a container is unique.
function Binder:bindContainer(node, containerFlags)
    -- Before we recurse into a node's children, we first save the existing parent, container
    -- and block-container.  Then after we pop out of processing the children, we restore
    -- these saved values.
    local saveContainer = self.container
    local saveThisContainer = self.thisContainer
    local savedBlockScopeContainer = self.blockScopeContainer
    -- Depending on what kind of node this is, we may have to adjust the current container
    -- and block-container.   If the current node is a container, then it is automatically
    -- considered the current block-container as well.  Also, for containers that we know
    -- may contain locals, we eagerly initialize the .locals field. We do this because
    -- it's highly likely that the .locals will be needed to place some child in (for example,
    -- a parameter, or variable declaration).
    --
    -- However, we do not proactively create the .locals for block-containers because it's
    -- totally normal and common for block-containers to never actually have a block-scoped
    -- variable in them.  We don't want to end up allocating an object for every 'block' we
    -- run into when most of them won't be necessary.
    --
    -- Finally, if this is a block-container, then we clear out any existing .locals object
    -- it may contain within it.  This happens in incremental scenarios.  Because we can be
    -- reusing a node from a previous compilation, that node may have had 'locals' created
    -- for it.  We must clear this so we don't accidentally move any stale data forward from
    -- a previous compilation.
    if containerFlags & ContainerFlags.IsContainer ~= 0 then
        self.container = node
        self.blockScopeContainer = node
        if containerFlags & ContainerFlags.HasLocals ~= 0 then
            -- localsContainer := node
            -- localsContainer.LocalsContainerData().locals = make(SymbolTable)
            self:addToContainerChain(node)
        end
    elseif containerFlags & ContainerFlags.IsBlockScopedContainer ~= 0 then
        self.blockScopeContainer = node
        self:addToContainerChain(node)
    end
    if containerFlags & ContainerFlags.IsThisContainer ~= 0 then
        self.thisContainer = node
    end
    if containerFlags & ContainerFlags.IsControlFlowContainer ~= 0 then
        local saveCurrentFlow = self.currentFlow
        local saveBreakTarget = self.currentBreakTarget
        local saveContinueTarget = self.currentContinueTarget
        local saveReturnTarget = self.currentReturnTarget
        local saveExceptionTarget = self.currentExceptionTarget
        local saveActiveLabelList = self.activeLabelList
        local saveHasExplicitReturn = self.hasExplicitReturn
        local saveSeenThisKeyword = self.seenThisKeyword
        local isImmediatelyInvoked = (containerFlags & ContainerFlags.IsFunctionExpression ~= 0 and
            not ast.HasSyntacticModifier(node, ModifierFlags.Async) and
            not binder.isGeneratorFunctionExpression(node) and
            ast.GetImmediatelyInvokedFunctionExpression(node) ~= nil) or node.kind == Kind.ClassStaticBlockDeclaration
        -- A non-async, non-generator IIFE is considered part of the containing control flow. Return statements behave
        -- similarly to break statements that exit to a label just past the statement body.
        if not isImmediatelyInvoked then
            local flowStart = self:newFlowNode(FlowFlags.Start)
            self.currentFlow = flowStart
            if containerFlags & (ContainerFlags.IsFunctionExpression | ContainerFlags.IsObjectLiteralOrClassExpressionMethodOrAccessor) ~= 0 then
                flowStart.node = node
            end
        end
        -- We create a return control flow graph for IIFEs and constructors. For constructors
        -- we use the return control flow graph in strict property initialization checks.
        if isImmediatelyInvoked or node.kind == Kind.Constructor then
            self.currentReturnTarget = self:newFlowNode(FlowFlags.BranchLabel)
        else
            self.currentReturnTarget = nil
        end
        self.currentExceptionTarget = nil
        self.currentBreakTarget = nil
        self.currentContinueTarget = nil
        self.activeLabelList = nil
        self.hasExplicitReturn = false
        self.seenThisKeyword = false
        self:bindChildren(node)
        -- Reset flags (for incremental scenarios)
        node.flags = node.flags & ~(NodeFlags.ReachabilityAndEmitFlags | NodeFlags.ContainsThis)
        if self.currentFlow.flags & FlowFlags.Unreachable == 0 and containerFlags & ContainerFlags.IsFunctionLike ~= 0 then
            local bodyData = node:BodyData()
            if bodyData ~= nil and ast.NodeIsPresent(bodyData.body) then
                node.flags = node.flags | NodeFlags.HasImplicitReturn
                if self.hasExplicitReturn then
                    node.flags = node.flags | NodeFlags.HasExplicitReturn
                end
                bodyData.endFlowNode = self.currentFlow
            end
        end
        if self.seenThisKeyword then
            node.flags = node.flags | NodeFlags.ContainsThis
        end
        if node.kind == Kind.SourceFile then
            node.flags = node.flags | self.emitFlags
        end
        if self.currentReturnTarget ~= nil then
            self:addAntecedent(self.currentReturnTarget, self.currentFlow)
            self.currentFlow = self:finishFlowLabel(self.currentReturnTarget)
            if node.kind == Kind.Constructor or node.kind == Kind.ClassStaticBlockDeclaration then
                binder.setReturnFlowNode(node, self.currentFlow)
            end
        end
        if not isImmediatelyInvoked then
            self.currentFlow = saveCurrentFlow
        end
        self.currentBreakTarget = saveBreakTarget
        self.currentContinueTarget = saveContinueTarget
        self.currentReturnTarget = saveReturnTarget
        self.currentExceptionTarget = saveExceptionTarget
        self.activeLabelList = saveActiveLabelList
        self.hasExplicitReturn = saveHasExplicitReturn
        if containerFlags & ContainerFlags.PropagatesThisKeyword ~= 0 then
            self.seenThisKeyword = saveSeenThisKeyword or self.seenThisKeyword
        else
            self.seenThisKeyword = saveSeenThisKeyword
        end
    elseif containerFlags & ContainerFlags.IsInterface ~= 0 then
        local saveSeenThisKeyword = self.seenThisKeyword
        self.seenThisKeyword = false
        self:bindChildren(node)
        -- ContainsThis cannot overlap with HasExtendedUnicodeEscape on Identifier
        if self.seenThisKeyword then
            node.flags = node.flags | NodeFlags.ContainsThis
        else
            node.flags = node.flags & ~NodeFlags.ContainsThis
        end
        self.seenThisKeyword = saveSeenThisKeyword
    else
        self:bindChildren(node)
    end
    if ast.IsSourceFile(node) and ast.IsInJSFile(node) then
        -- Binding of top-level JSTypeAliasDeclaration nodes is deferred to ensure CommonJS module
        -- indicators, if any, are processed first.
        for _, statement in ipairs(node:Statements()) do
            if ast.IsJSTypeAliasDeclaration(statement) then
                self:bindBlockScopedDeclaration(statement, SymbolFlags.TypeAlias, SymbolFlags.TypeAliasExcludes)
            end
        end
        if self.file.commonJSModuleIndicator ~= nil then
            self:declareCommonJSVariable("module")
            self:declareCommonJSVariable("exports")
        end
    end
    if ast.IsSourceFile(node) and ast.IsExternalOrCommonJSModule(node) or ast.IsAmbientModule(node) then
        self:bindCommonJSTypeExports(node:Symbol())
    end
    self.container = saveContainer
    self.thisContainer = saveThisContainer
    self.blockScopeContainer = savedBlockScopeContainer
end

function Binder:declareCommonJSVariable(name)
    local locals = ast.GetLocals(self.file)
    if locals[name] == nil then
        local symbol = self:newSymbol(SymbolFlags.FunctionScopedVariable | SymbolFlags.ModuleExports, name)
        symbol.declarations = self:newSingleDeclaration(self.file)
        symbol.valueDeclaration = symbol.declarations[1]
        if name == "module" then
            local exportsProperty = self:newSymbol(SymbolFlags.ModuleExports | SymbolFlags.Property, "exports")
            exportsProperty.declarations = symbol.declarations
            exportsProperty.valueDeclaration = symbol.valueDeclaration
            exportsProperty.parent = symbol
            symbol.members = ast.NewSymbolTable()
            symbol.members["exports"] = exportsProperty
        end
        locals[name] = symbol
    end
end

function Binder:bindChildren(node)
    local saveInAssignmentPattern = self.inAssignmentPattern
    -- Most nodes aren't valid in an assignment pattern, so we clear the value here
    -- and set it before we descend into nodes that could actually be part of an assignment pattern.
    self.inAssignmentPattern = false

    if self.currentFlow == self.unreachableFlow then
        local flowNodeData = node:FlowNodeData()
        if flowNodeData ~= nil then
            flowNodeData.flowNode = nil
        end
        if ast.IsPotentiallyExecutableNode(node) then
            node.flags = node.flags | NodeFlags.Unreachable
        end
        self:bindEachChild(node)
        self.inAssignmentPattern = saveInAssignmentPattern
        return
    end

    local kind = node.kind
    if Kind.FirstStatement <= kind and kind <= Kind.LastStatement then
        local flowNodeData = node:FlowNodeData()
        if flowNodeData ~= nil then
            flowNodeData.flowNode = self.currentFlow
        end
    end

    if kind == Kind.WhileStatement then
        self:bindWhileStatement(node)
    elseif kind == Kind.DoStatement then
        self:bindDoStatement(node)
    elseif kind == Kind.ForStatement then
        self:bindForStatement(node)
    elseif kind == Kind.ForInStatement or kind == Kind.ForOfStatement then
        self:bindForInOrForOfStatement(node)
    elseif kind == Kind.IfStatement then
        self:bindIfStatement(node)
    elseif kind == Kind.ReturnStatement then
        self:bindReturnStatement(node)
    elseif kind == Kind.ThrowStatement then
        self:bindThrowStatement(node)
    elseif kind == Kind.BreakStatement then
        self:bindBreakStatement(node)
    elseif kind == Kind.ContinueStatement then
        self:bindContinueStatement(node)
    elseif kind == Kind.TryStatement then
        self:bindTryStatement(node)
    elseif kind == Kind.SwitchStatement then
        self:bindSwitchStatement(node)
    elseif kind == Kind.CaseBlock then
        self:bindCaseBlock(node)
    elseif kind == Kind.CaseClause or kind == Kind.DefaultClause then
        self:bindCaseOrDefaultClause(node)
    elseif kind == Kind.ExpressionStatement then
        self:bindExpressionStatement(node)
    elseif kind == Kind.LabeledStatement then
        self:bindLabeledStatement(node)
    elseif kind == Kind.PrefixUnaryExpression then
        self:bindPrefixUnaryExpressionFlow(node)
    elseif kind == Kind.PostfixUnaryExpression then
        self:bindPostfixUnaryExpressionFlow(node)
    elseif kind == Kind.BinaryExpression then
        if ast.IsDestructuringAssignment(node) then
            -- Carry over whether we are in an assignment pattern to
            -- binary expressions that could actually be an initializer
            self.inAssignmentPattern = saveInAssignmentPattern
            self:bindDestructuringAssignmentFlow(node)
            return
        end
        self:bindBinaryExpressionFlow(node)
    elseif kind == Kind.DeleteExpression then
        self:bindDeleteExpressionFlow(node)
    elseif kind == Kind.ConditionalExpression then
        self:bindConditionalExpressionFlow(node)
    elseif kind == Kind.VariableDeclaration then
        self:bindVariableDeclarationFlow(node)
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        self:bindAccessExpressionFlow(node)
    elseif kind == Kind.CallExpression then
        self:bindCallExpressionFlow(node)
    elseif kind == Kind.NonNullExpression then
        self:bindNonNullExpressionFlow(node)
    elseif kind == Kind.SourceFile then
        local sourceFile = node
        self:bindEachStatementFunctionsFirst(sourceFile.statements)
        self:bind(sourceFile.endOfFileToken)
    elseif kind == Kind.Block or kind == Kind.ModuleBlock then
        self:bindEachStatementFunctionsFirst(node:StatementList())
    elseif kind == Kind.BindingElement then
        self:bindBindingElementFlow(node)
    elseif kind == Kind.Parameter then
        self:bindParameterFlow(node)
    elseif kind == Kind.ObjectLiteralExpression or kind == Kind.ArrayLiteralExpression or kind == Kind.PropertyAssignment or kind == Kind.SpreadElement then
        self.inAssignmentPattern = saveInAssignmentPattern
        self:bindEachChild(node)
    else
        self:bindEachChild(node)
    end
    self.inAssignmentPattern = saveInAssignmentPattern
end

function Binder:bindEachChild(node)
    node:ForEachChild(self.bindFunc)
end

function Binder:bindEach(nodes)
    if nodes == nil then
        return
    end
    for _, node in ipairs(nodes) do
        self:bind(node)
    end
end

function Binder:bindNodeList(nodeList)
    if nodeList ~= nil then
        self:bindEach(nodeList.nodes)
    end
end

function Binder:bindModifiers(modifiers)
    if modifiers ~= nil then
        self:bindEach(modifiers.nodes)
    end
end

function Binder:bindEachStatementFunctionsFirst(statements)
    for _, node in ipairs(statements.nodes) do
        if node.kind == Kind.FunctionDeclaration then
            self:bind(node)
        end
    end
    for _, node in ipairs(statements.nodes) do
        if node.kind ~= Kind.FunctionDeclaration then
            self:bind(node)
        end
    end
end

function Binder:setContinueTarget(node, target)
    local label = self.activeLabelList
    while label ~= nil and node.parent.kind == Kind.LabeledStatement do
        label.continueTarget = target
        label = label.next
        node = node.parent
    end
    return target
end

function Binder:doWithConditionalBranches(action, value, trueTarget, falseTarget)
    local savedTrueTarget = self.currentTrueTarget
    local savedFalseTarget = self.currentFalseTarget
    self.currentTrueTarget = trueTarget
    self.currentFalseTarget = falseTarget
    action(self, value)
    self.currentTrueTarget = savedTrueTarget
    self.currentFalseTarget = savedFalseTarget
end

function Binder:bindCondition(node, trueTarget, falseTarget)
    self:doWithConditionalBranches(Binder.bind, node, trueTarget, falseTarget)
    if node == nil or not binder.isLogicalAssignmentExpression(node) and not ast.IsLogicalExpression(node) and not (ast.IsOptionalChain(node) and ast.IsOutermostOptionalChain(node)) then
        self:addAntecedent(trueTarget, self:createFlowCondition(FlowFlags.TrueCondition, self.currentFlow, node))
        self:addAntecedent(falseTarget, self:createFlowCondition(FlowFlags.FalseCondition, self.currentFlow, node))
    end
end

function Binder:bindIterativeStatement(node, breakTarget, continueTarget)
    local saveBreakTarget = self.currentBreakTarget
    local saveContinueTarget = self.currentContinueTarget
    self.currentBreakTarget = breakTarget
    self.currentContinueTarget = continueTarget
    self:bind(node)
    self.currentBreakTarget = saveBreakTarget
    self.currentContinueTarget = saveContinueTarget
end

function binder.isLogicalAssignmentExpression(node)
    return ast.IsLogicalOrCoalescingAssignmentExpression(ast.SkipParentheses(node))
end

function Binder:bindAssignmentTargetFlow(node)
    local kind = node.kind
    if kind == Kind.ArrayLiteralExpression then
        for _, e in ipairs(node:Elements()) do
            if e.kind == Kind.SpreadElement then
                self:bindAssignmentTargetFlow(e:Expression())
            else
                self:bindDestructuringTargetFlow(e)
            end
        end
    elseif kind == Kind.ObjectLiteralExpression then
        for _, p in ipairs(node:Properties()) do
            if p.kind == Kind.PropertyAssignment then
                self:bindDestructuringTargetFlow(p:Initializer())
            elseif p.kind == Kind.ShorthandPropertyAssignment then
                self:bindAssignmentTargetFlow(p:Name())
            elseif p.kind == Kind.SpreadAssignment then
                self:bindAssignmentTargetFlow(p:Expression())
            end
        end
    else
        if binder.isNarrowableReference(node) then
            self.currentFlow = self:createFlowMutation(FlowFlags.Assignment, self.currentFlow, node)
        end
    end
end

function Binder:bindDestructuringTargetFlow(node)
    if ast.IsBinaryExpression(node) and node.operatorToken.kind == Kind.EqualsToken then
        self:bindAssignmentTargetFlow(node.left)
    else
        self:bindAssignmentTargetFlow(node)
    end
end

function Binder:bindWhileStatement(node)
    local stmt = node
    local preWhileLabel = self:setContinueTarget(node, self:createLoopLabel())
    local preBodyLabel = self:createBranchLabel()
    local postWhileLabel = self:createBranchLabel()
    self:addAntecedent(preWhileLabel, self.currentFlow)
    self.currentFlow = preWhileLabel
    self:bindCondition(stmt.expression, preBodyLabel, postWhileLabel)
    self.currentFlow = self:finishFlowLabel(preBodyLabel)
    self:bindIterativeStatement(stmt.statement, postWhileLabel, preWhileLabel)
    self:addAntecedent(preWhileLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(postWhileLabel)
end

function Binder:bindDoStatement(node)
    local stmt = node
    local preDoLabel = self:createLoopLabel()
    local preConditionLabel = self:setContinueTarget(node, self:createBranchLabel())
    local postDoLabel = self:createBranchLabel()
    self:addAntecedent(preDoLabel, self.currentFlow)
    self.currentFlow = preDoLabel
    self:bindIterativeStatement(stmt.statement, postDoLabel, preConditionLabel)
    self:addAntecedent(preConditionLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(preConditionLabel)
    self:bindCondition(stmt.expression, preDoLabel, postDoLabel)
    self.currentFlow = self:finishFlowLabel(postDoLabel)
end

function Binder:bindForStatement(node)
    local stmt = node
    self:bind(stmt.initializer)
    if self.currentFlow == self.unreachableFlow then
        -- Unlike while/do, the for-loop initializer is bound inside this function before the loop's
        -- flow graph is constructed. If it makes flow unreachable (e.g. a throwing IIFE), addAntecedent
        -- will filter out the unreachable entry to preLoopLabel, leaving only the back-edge from the
        -- incrementor. This creates a cycle with no exit that crashes isReachableFlowNodeWorker.
        -- Bail out early and just bind the remaining children with unreachable flow.
        self:bind(stmt.condition)
        self:bind(stmt.statement)
        self:bind(stmt.incrementor)
        return
    end
    local preLoopLabel = self:setContinueTarget(node, self:createLoopLabel())
    local preBodyLabel = self:createBranchLabel()
    local preIncrementorLabel = self:createBranchLabel()
    local postLoopLabel = self:createBranchLabel()
    self:addAntecedent(preLoopLabel, self.currentFlow)
    self.currentFlow = preLoopLabel
    self:bindCondition(stmt.condition, preBodyLabel, postLoopLabel)
    self.currentFlow = self:finishFlowLabel(preBodyLabel)
    self:bindIterativeStatement(stmt.statement, postLoopLabel, preIncrementorLabel)
    self:addAntecedent(preIncrementorLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(preIncrementorLabel)
    self:bind(stmt.incrementor)
    self:addAntecedent(preLoopLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(postLoopLabel)
end

function Binder:bindForInOrForOfStatement(node)
    local stmt = node
    local preLoopLabel = self:setContinueTarget(node, self:createLoopLabel())
    local postLoopLabel = self:createBranchLabel()
    self:bind(stmt.expression)
    self:addAntecedent(preLoopLabel, self.currentFlow)
    self.currentFlow = preLoopLabel
    if node.kind == Kind.ForOfStatement then
        self:bind(stmt.awaitModifier)
    end
    self:addAntecedent(postLoopLabel, self.currentFlow)
    self:bind(stmt.initializer)
    if stmt.initializer.kind ~= Kind.VariableDeclarationList then
        self:bindAssignmentTargetFlow(stmt.initializer)
    end
    self:bindIterativeStatement(stmt.statement, postLoopLabel, preLoopLabel)
    self:addAntecedent(preLoopLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(postLoopLabel)
end

function Binder:bindIfStatement(node)
    local stmt = node
    local thenLabel = self:createBranchLabel()
    local elseLabel = self:createBranchLabel()
    local postIfLabel = self:createBranchLabel()
    self:bindCondition(stmt.expression, thenLabel, elseLabel)
    self.currentFlow = self:finishFlowLabel(thenLabel)
    self:bind(stmt.thenStatement)
    self:addAntecedent(postIfLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(elseLabel)
    self:bind(stmt.elseStatement)
    self:addAntecedent(postIfLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(postIfLabel)
end

function Binder:bindReturnStatement(node)
    self:bind(node:Expression())
    if self.currentReturnTarget ~= nil then
        self:addAntecedent(self.currentReturnTarget, self.currentFlow)
    end
    self.currentFlow = self.unreachableFlow
    self.hasExplicitReturn = true
    self.hasFlowEffects = true
end

function Binder:bindThrowStatement(node)
    self:bind(node:Expression())
    self.currentFlow = self.unreachableFlow
    self.hasFlowEffects = true
end

function Binder:bindBreakStatement(node)
    self:bindBreakOrContinueStatement(node:Label(), self.currentBreakTarget, ActiveLabel.BreakTarget)
end

function Binder:bindContinueStatement(node)
    self:bindBreakOrContinueStatement(node:Label(), self.currentContinueTarget, ActiveLabel.ContinueTarget)
end

function Binder:bindBreakOrContinueStatement(label, currentTarget, getTarget)
    self:bind(label)
    if label ~= nil then
        local activeLabel = self:findActiveLabel(label:Text())
        if activeLabel ~= nil then
            activeLabel.referenced = true
            self:bindBreakOrContinueFlow(getTarget(activeLabel))
        end
    else
        self:bindBreakOrContinueFlow(currentTarget)
    end
end

function Binder:findActiveLabel(name)
    local label = self.activeLabelList
    while label ~= nil do
        if label.name == name then
            return label
        end
        label = label.next
    end
    return nil
end

function Binder:bindBreakOrContinueFlow(flowLabel)
    if flowLabel ~= nil then
        self:addAntecedent(flowLabel, self.currentFlow)
        self.currentFlow = self.unreachableFlow
        self.hasFlowEffects = true
    end
end

function Binder:bindTryStatement(node)
    -- We conservatively assume that *any* code in the try block can cause an exception, but we only need
    -- to track code that causes mutations (because only mutations widen the possible control flow type of
    -- a variable). The exceptionLabel is the target label for control flows that result from exceptions.
    -- We add all mutation flow nodes as antecedents of this label such that we can analyze them as possible
    -- antecedents of the start of catch or finally blocks. Furthermore, we add the current control flow to
    -- represent exceptions that occur before any mutations.
    local stmt = node
    local saveReturnTarget = self.currentReturnTarget
    local saveExceptionTarget = self.currentExceptionTarget
    local normalExitLabel = self:createBranchLabel()
    local returnLabel = self:createBranchLabel()
    local exceptionLabel = self:createBranchLabel()
    if stmt.finallyBlock ~= nil then
        self.currentReturnTarget = returnLabel
    end
    self:addAntecedent(exceptionLabel, self.currentFlow)
    self.currentExceptionTarget = exceptionLabel
    self:bind(stmt.tryBlock)
    self:addAntecedent(normalExitLabel, self.currentFlow)
    if stmt.catchClause ~= nil then
        -- Start of catch clause is the target of exceptions from try block.
        self.currentFlow = self:finishFlowLabel(exceptionLabel)
        -- The currentExceptionTarget now represents control flows from exceptions in the catch clause.
        -- Effectively, in a try-catch-finally, if an exception occurs in the try block, the catch block
        -- acts like a second try block.
        exceptionLabel = self:createBranchLabel()
        self:addAntecedent(exceptionLabel, self.currentFlow)
        self.currentExceptionTarget = exceptionLabel
        self:bind(stmt.catchClause)
        self:addAntecedent(normalExitLabel, self.currentFlow)
    end
    self.currentReturnTarget = saveReturnTarget
    self.currentExceptionTarget = saveExceptionTarget
    if stmt.finallyBlock ~= nil then
        -- Possible ways control can reach the finally block:
        -- 1) Normal completion of try block of a try-finally or try-catch-finally
        -- 2) Normal completion of catch block (following exception in try block) of a try-catch-finally
        -- 3) Return in try or catch block of a try-finally or try-catch-finally
        -- 4) Exception in try block of a try-finally
        -- 5) Exception in catch block of a try-catch-finally
        -- When analyzing a control flow graph that starts inside a finally block we want to consider all
        -- five possibilities above. However, when analyzing a control flow graph that starts outside (past)
        -- the finally block, we only want to consider the first two (if we're past a finally block then it
        -- must have completed normally). Likewise, when analyzing a control flow graph from return statements
        -- in try or catch blocks in an IIFE, we only want to consider the third. To make this possible, we
        -- inject a ReduceLabel node into the control flow graph. This node contains an alternate reduced
        -- set of antecedents for the pre-finally label. As control flow analysis passes by a ReduceLabel
        -- node, the pre-finally label is temporarily switched to the reduced antecedent set.
        local finallyLabel = self:createBranchLabel()
        finallyLabel.antecedents = self:combineFlowLists(normalExitLabel.antecedents, self:combineFlowLists(exceptionLabel.antecedents, returnLabel.antecedents))
        self.currentFlow = finallyLabel
        self:bind(stmt.finallyBlock)
        if self.currentFlow.flags & FlowFlags.Unreachable ~= 0 then
            -- If the end of the finally block is unreachable, the end of the entire try statement is unreachable.
            self.currentFlow = self.unreachableFlow
        else
            -- If we have an IIFE return target and return statements in the try or catch blocks, add a control
            -- flow that goes back through the finally block and back through only the return statements.
            if self.currentReturnTarget ~= nil and returnLabel.antecedents ~= nil then
                self:addAntecedent(self.currentReturnTarget, self:createReduceLabel(finallyLabel, returnLabel.antecedents, self.currentFlow))
            end
            -- If we have an outer exception target (i.e. a containing try-finally or try-catch-finally), add a
            -- control flow that goes back through the finally block and back through each possible exception source.
            if self.currentExceptionTarget ~= nil and exceptionLabel.antecedents ~= nil then
                self:addAntecedent(self.currentExceptionTarget, self:createReduceLabel(finallyLabel, exceptionLabel.antecedents, self.currentFlow))
            end
            -- If the end of the finally block is reachable, but the end of the try and catch blocks are not,
            -- convert the current flow to unreachable. For example, 'try { return 1; } finally { ... }' should
            -- result in an unreachable current control flow.
            if normalExitLabel.antecedents ~= nil then
                self.currentFlow = self:createReduceLabel(finallyLabel, normalExitLabel.antecedents, self.currentFlow)
            else
                self.currentFlow = self.unreachableFlow
            end
        end
    else
        self.currentFlow = self:finishFlowLabel(normalExitLabel)
    end
end

function Binder:bindSwitchStatement(node)
    local stmt = node
    local postSwitchLabel = self:createBranchLabel()
    self:bind(stmt.expression)
    local saveBreakTarget = self.currentBreakTarget
    local savePreSwitchCaseFlow = self.preSwitchCaseFlow
    self.currentBreakTarget = postSwitchLabel
    self.preSwitchCaseFlow = self.currentFlow
    self:bind(stmt.caseBlock)
    self:addAntecedent(postSwitchLabel, self.currentFlow)
    local hasDefault = core.Some(stmt.caseBlock.clauses.nodes, function(c)
        return c.kind == Kind.DefaultClause
    end)
    if not hasDefault then
        self:addAntecedent(postSwitchLabel, self:createFlowSwitchClause(self.preSwitchCaseFlow, node, 0, 0))
    end
    self.currentBreakTarget = saveBreakTarget
    self.preSwitchCaseFlow = savePreSwitchCaseFlow
    self.currentFlow = self:finishFlowLabel(postSwitchLabel)
end

function Binder:bindCaseBlock(node)
    local switchStatement = node.parent
    local clauses = node.clauses.nodes
    local isNarrowingSwitch = switchStatement:Expression().kind == Kind.TrueKeyword or binder.isNarrowingExpression(switchStatement:Expression())
    local fallthroughFlow = self.unreachableFlow
    local i = 0
    while i < #clauses do
        local clauseStart = i
        while #clauses[i + 1]:Statements() == 0 and i + 1 < #clauses do
            if fallthroughFlow == self.unreachableFlow then
                self.currentFlow = self.preSwitchCaseFlow
            end
            self:bind(clauses[i + 1])
            i = i + 1
        end
        local preCaseLabel = self:createBranchLabel()
        local preCaseFlow = self.preSwitchCaseFlow
        if isNarrowingSwitch then
            preCaseFlow = self:createFlowSwitchClause(self.preSwitchCaseFlow, switchStatement, clauseStart, i + 1)
        end
        self:addAntecedent(preCaseLabel, preCaseFlow)
        self:addAntecedent(preCaseLabel, fallthroughFlow)
        self.currentFlow = self:finishFlowLabel(preCaseLabel)
        local clause = clauses[i + 1]
        self:bind(clause)
        fallthroughFlow = self.currentFlow
        if self.currentFlow.flags & FlowFlags.Unreachable == 0 and i ~= #clauses - 1 then
            clause.fallthroughFlowNode = self.currentFlow
        end
        i = i + 1
    end
end

function Binder:bindCaseOrDefaultClause(node)
    local clause = node
    if clause.expression ~= nil then
        local saveCurrentFlow = self.currentFlow
        self.currentFlow = self.preSwitchCaseFlow
        self:bind(clause.expression)
        self.currentFlow = saveCurrentFlow
    end
    self:bindEach(clause.statements.nodes)
end

function Binder:bindExpressionStatement(node)
    local stmt = node
    self:bind(stmt.expression)
    self:maybeBindExpressionFlowIfCall(stmt.expression)
end

function Binder:maybeBindExpressionFlowIfCall(node)
    -- A top level or comma expression call expression with a dotted function name and at least one argument
    -- is potentially an assertion and is therefore included in the control flow.
    if ast.IsCallExpression(node) then
        if node:Expression().kind ~= Kind.SuperKeyword and ast.IsDottedName(node:Expression()) then
            self.currentFlow = self:createFlowCall(self.currentFlow, node)
        end
    end
end

function Binder:bindLabeledStatement(node)
    local stmt = node
    local postStatementLabel = self:createBranchLabel()
    self.activeLabelList = setmetatable({
        next = self.activeLabelList,
        name = stmt.label:Text(),
        breakTarget = postStatementLabel,
        continueTarget = nil,
        referenced = false,
    }, ActiveLabel)
    self:bind(stmt.label)
    self:bind(stmt.statement)
    if not self.activeLabelList.referenced then
        -- Mark the label as unused; the checker will decide whether to report it
        stmt.label.flags = stmt.label.flags | NodeFlags.Unreachable
    end
    self.activeLabelList = self.activeLabelList.next
    self:addAntecedent(postStatementLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(postStatementLabel)
end

function Binder:bindPrefixUnaryExpressionFlow(node)
    local expr = node
    if expr.operator == Kind.ExclamationToken then
        local saveTrueTarget = self.currentTrueTarget
        self.currentTrueTarget = self.currentFalseTarget
        self.currentFalseTarget = saveTrueTarget
        self:bindEachChild(node)
        self.currentFalseTarget = self.currentTrueTarget
        self.currentTrueTarget = saveTrueTarget
    else
        self:bindEachChild(node)
        if expr.operator == Kind.PlusPlusToken or expr.operator == Kind.MinusMinusToken then
            self:bindAssignmentTargetFlow(expr.operand)
        end
    end
end

function Binder:bindPostfixUnaryExpressionFlow(node)
    local expr = node
    self:bindEachChild(node)
    if expr.operator == Kind.PlusPlusToken or expr.operator == Kind.MinusMinusToken then
        self:bindAssignmentTargetFlow(expr.operand)
    end
end

function Binder:bindDestructuringAssignmentFlow(node)
    local expr = node
    if self.inAssignmentPattern then
        self.inAssignmentPattern = false
        self:bind(expr.operatorToken)
        self:bind(expr.right)
        self.inAssignmentPattern = true
        self:bind(expr.left)
        self:bind(expr.type)
    else
        self.inAssignmentPattern = true
        self:bind(expr.left)
        self:bind(expr.type)
        self.inAssignmentPattern = false
        self:bind(expr.operatorToken)
        self:bind(expr.right)
    end
    self:bindAssignmentTargetFlow(expr.left)
end

function Binder:bindBinaryExpressionFlow(node)
    local expr = node
    local operator = expr.operatorToken.kind
    if ast.IsLogicalOrCoalescingBinaryOperator(operator) or ast.IsLogicalOrCoalescingAssignmentOperator(operator) then
        if binder.isTopLevelLogicalExpression(node) then
            local postExpressionLabel = self:createBranchLabel()
            local saveCurrentFlow = self.currentFlow
            local saveHasFlowEffects = self.hasFlowEffects
            self.hasFlowEffects = false
            self:bindLogicalLikeExpression(node, postExpressionLabel, postExpressionLabel)
            if self.hasFlowEffects then
                self.currentFlow = self:finishFlowLabel(postExpressionLabel)
            else
                self.currentFlow = saveCurrentFlow
            end
            self.hasFlowEffects = self.hasFlowEffects or saveHasFlowEffects
        else
            self:bindLogicalLikeExpression(node, self.currentTrueTarget, self.currentFalseTarget)
        end
    else
        self:bind(expr.left)
        self:bind(expr.type)
        if operator == Kind.CommaToken then
            self:maybeBindExpressionFlowIfCall(expr.left)
        end
        self:bind(expr.operatorToken)
        self:bind(expr.right)
        if operator == Kind.CommaToken then
            self:maybeBindExpressionFlowIfCall(expr.right)
        end
        if ast.IsAssignmentOperator(operator) and not ast.IsAssignmentTarget(node) then
            self:bindAssignmentTargetFlow(expr.left)
            if operator == Kind.EqualsToken and expr.left.kind == Kind.ElementAccessExpression then
                local elementAccess = expr.left
                if binder.isNarrowableOperand(elementAccess.expression) then
                    self.currentFlow = self:createFlowMutation(FlowFlags.ArrayMutation, self.currentFlow, node)
                end
            end
        end
    end
end

function Binder:bindLogicalLikeExpression(node, trueTarget, falseTarget)
    local expr = node
    local preRightLabel = self:createBranchLabel()
    if expr.operatorToken.kind == Kind.AmpersandAmpersandToken or expr.operatorToken.kind == Kind.AmpersandAmpersandEqualsToken then
        self:bindCondition(expr.left, preRightLabel, falseTarget)
    else
        self:bindCondition(expr.left, trueTarget, preRightLabel)
    end
    self.currentFlow = self:finishFlowLabel(preRightLabel)
    self:bind(expr.operatorToken)
    if ast.IsLogicalOrCoalescingAssignmentOperator(expr.operatorToken.kind) then
        self:doWithConditionalBranches(Binder.bind, expr.right, trueTarget, falseTarget)
        self:bindAssignmentTargetFlow(expr.left)
        self:addAntecedent(trueTarget, self:createFlowCondition(FlowFlags.TrueCondition, self.currentFlow, node))
        self:addAntecedent(falseTarget, self:createFlowCondition(FlowFlags.FalseCondition, self.currentFlow, node))
    else
        self:bindCondition(expr.right, trueTarget, falseTarget)
    end
end

function Binder:bindDeleteExpressionFlow(node)
    local expr = node
    self:bindEachChild(node)
    if expr.expression.kind == Kind.PropertyAccessExpression then
        self:bindAssignmentTargetFlow(expr.expression)
    end
end

function Binder:bindConditionalExpressionFlow(node)
    local expr = node
    local trueLabel = self:createBranchLabel()
    local falseLabel = self:createBranchLabel()
    local postExpressionLabel = self:createBranchLabel()
    local saveCurrentFlow = self.currentFlow
    local saveHasFlowEffects = self.hasFlowEffects
    self.hasFlowEffects = false
    self:bindCondition(expr.condition, trueLabel, falseLabel)
    self.currentFlow = self:finishFlowLabel(trueLabel)
    self:bind(expr.questionToken)
    self:bind(expr.whenTrue)
    self:addAntecedent(postExpressionLabel, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(falseLabel)
    self:bind(expr.colonToken)
    self:bind(expr.whenFalse)
    self:addAntecedent(postExpressionLabel, self.currentFlow)
    if self.hasFlowEffects then
        self.currentFlow = self:finishFlowLabel(postExpressionLabel)
    else
        self.currentFlow = saveCurrentFlow
    end
    self.hasFlowEffects = self.hasFlowEffects or saveHasFlowEffects
end

function Binder:bindVariableDeclarationFlow(node)
    self:bindEachChild(node)
    if node:Initializer() ~= nil or ast.IsForInOrOfStatement(node.parent.parent) then
        self:bindInitializedVariableFlow(node)
    end
end

function Binder:bindInitializedVariableFlow(node)
    local name
    if node.kind == Kind.VariableDeclaration then
        name = node:Name()
    elseif node.kind == Kind.BindingElement then
        name = node:Name()
    end
    if name ~= nil and ast.IsBindingPattern(name) then
        for _, child in ipairs(name:Elements()) do
            self:bindInitializedVariableFlow(child)
        end
    else
        self.currentFlow = self:createFlowMutation(FlowFlags.Assignment, self.currentFlow, node)
    end
end

function Binder:bindAccessExpressionFlow(node)
    if ast.IsOptionalChain(node) then
        self:bindOptionalChainFlow(node)
    else
        self:bindEachChild(node)
    end
end

function Binder:bindOptionalChainFlow(node)
    if binder.isTopLevelLogicalExpression(node) then
        local postExpressionLabel = self:createBranchLabel()
        local saveCurrentFlow = self.currentFlow
        local saveHasFlowEffects = self.hasFlowEffects
        self:bindOptionalChain(node, postExpressionLabel, postExpressionLabel)
        if self.hasFlowEffects then
            self.currentFlow = self:finishFlowLabel(postExpressionLabel)
        else
            self.currentFlow = saveCurrentFlow
        end
        self.hasFlowEffects = self.hasFlowEffects or saveHasFlowEffects
    else
        self:bindOptionalChain(node, self.currentTrueTarget, self.currentFalseTarget)
    end
end

function Binder:bindOptionalChain(node, trueTarget, falseTarget)
    -- For an optional chain, we emulate the behavior of a logical expression:
    --
    -- a?.b         -> a && a.b
    -- a?.b.c       -> a && a.b.c
    -- a?.b?.c      -> a && a.b && a.b.c
    -- a?.[x = 1]   -> a && a[x = 1]
    --
    -- To do this we descend through the chain until we reach the root of a chain (the expression with a `?.`)
    -- and build it's CFA graph as if it were the first condition (`a && ...`). Then we bind the rest
    -- of the node as part of the "true" branch, and continue to do so as we ascend back up to the outermost
    -- chain node. We then treat the entire node as the right side of the expression.
    local preChainLabel
    if ast.IsOptionalChainRoot(node) then
        preChainLabel = self:createBranchLabel()
    end
    local target = trueTarget
    if preChainLabel ~= nil then
        target = preChainLabel
    end
    self:bindOptionalExpression(node:Expression(), target, falseTarget)
    if preChainLabel ~= nil then
        self.currentFlow = self:finishFlowLabel(preChainLabel)
    end
    self:doWithConditionalBranches(Binder.bindOptionalChainRest, node, trueTarget, falseTarget)
    if ast.IsOutermostOptionalChain(node) then
        self:addAntecedent(trueTarget, self:createFlowCondition(FlowFlags.TrueCondition, self.currentFlow, node))
        self:addAntecedent(falseTarget, self:createFlowCondition(FlowFlags.FalseCondition, self.currentFlow, node))
    end
end

function Binder:bindOptionalExpression(node, trueTarget, falseTarget)
    self:doWithConditionalBranches(Binder.bind, node, trueTarget, falseTarget)
    if not ast.IsOptionalChain(node) or ast.IsOutermostOptionalChain(node) then
        self:addAntecedent(trueTarget, self:createFlowCondition(FlowFlags.TrueCondition, self.currentFlow, node))
        self:addAntecedent(falseTarget, self:createFlowCondition(FlowFlags.FalseCondition, self.currentFlow, node))
    end
end

function Binder:bindOptionalChainRest(node)
    local kind = node.kind
    if kind == Kind.PropertyAccessExpression then
        self:bind(node:QuestionDotToken())
        self:bind(node:Name())
    elseif kind == Kind.ElementAccessExpression then
        self:bind(node:QuestionDotToken())
        self:bind(node.argumentExpression)
    elseif kind == Kind.CallExpression then
        self:bind(node:QuestionDotToken())
        self:bindNodeList(node:TypeArgumentList())
        self:bindEach(node:Arguments())
    end
    return false
end

function Binder:bindCallExpressionFlow(node)
    local call = node
    if ast.IsOptionalChain(node) then
        self:bindOptionalChainFlow(node)
    else
        -- If the target of the call expression is a function expression or arrow function we have
        -- an immediately invoked function expression (IIFE). Initialize the flowNode property to
        -- the current control flow (which includes evaluation of the IIFE arguments).
        local expr = ast.SkipParentheses(call.expression)
        if expr.kind == Kind.FunctionExpression or expr.kind == Kind.ArrowFunction then
            self:bindNodeList(call.typeArguments)
            self:bindEach(call.arguments.nodes)
            self:bind(call.expression)
        else
            self:bindEachChild(node)
            if call.expression.kind == Kind.SuperKeyword then
                self.currentFlow = self:createFlowCall(self.currentFlow, node)
            end
        end
    end
    if ast.IsPropertyAccessExpression(call.expression) then
        local access = call.expression
        if ast.IsIdentifier(access:Name()) and binder.isNarrowableOperand(access.expression) and ast.IsPushOrUnshiftIdentifier(access:Name()) then
            self.currentFlow = self:createFlowMutation(FlowFlags.ArrayMutation, self.currentFlow, node)
        end
    end
end

function Binder:bindNonNullExpressionFlow(node)
    if ast.IsOptionalChain(node) then
        self:bindOptionalChainFlow(node)
    else
        self:bindEachChild(node)
    end
end

function Binder:bindBindingElementFlow(node)
    -- When evaluating a binding pattern, the initializer is evaluated before the binding pattern, per:
    -- - https://tc39.es/ecma262/#sec-destructuring-binding-patterns-runtime-semantics-iteratorbindinginitialization
    --   - `BindingElement: BindingPattern Initializer?`
    -- - https://tc39.es/ecma262/#sec-runtime-semantics-keyedbindinginitialization
    --   - `BindingElement: BindingPattern Initializer?`
    local elem = node
    self:bind(elem.dotDotDotToken)
    self:bind(elem.propertyName)
    self:bindInitializer(elem.initializer)
    self:bind(elem:Name())
end

function Binder:bindParameterFlow(node)
    local param = node
    self:bindModifiers(param:Modifiers())
    self:bind(param.dotDotDotToken)
    self:bind(param.questionToken)
    self:bind(param.type)
    self:bindInitializer(param.initializer)
    self:bind(param:Name())
end

-- a BindingElement/Parameter does not have side effects if initializers are not evaluated and used. (see GH#49759)
function Binder:bindInitializer(node)
    if node == nil then
        return
    end
    local entryFlow = self.currentFlow
    self:bind(node)
    if entryFlow == self.unreachableFlow or entryFlow == self.currentFlow then
        return
    end
    local exitFlow = self:createBranchLabel()
    self:addAntecedent(exitFlow, entryFlow)
    self:addAntecedent(exitFlow, self.currentFlow)
    self.currentFlow = self:finishFlowLabel(exitFlow)
end

function binder.setFlowNode(node, flowNode)
    local data = node:FlowNodeData()
    if data ~= nil then
        data.flowNode = flowNode
    end
end

function binder.setReturnFlowNode(node, returnFlowNode)
    local kind = node.kind
    if kind == Kind.Constructor or kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression or kind == Kind.ClassStaticBlockDeclaration then
        node.returnFlowNode = returnFlowNode
    end
end

function binder.isGeneratorFunctionExpression(node)
    return ast.IsFunctionExpression(node) and node.asteriskToken ~= nil
end

function Binder:addToContainerChain(next_)
    if self.lastContainer ~= nil then
        self.lastContainer:LocalsContainerData().nextContainer = next_
    end
    self.lastContainer = next_
end

function Binder:addDeclarationToSymbol(symbol, node, symbolFlags)
    symbol.flags = symbol.flags | symbolFlags
    node:DeclarationData().symbol = symbol
    if symbol.declarations == nil then
        symbol.declarations = self:newSingleDeclaration(node)
    else
        symbol.declarations = core.AppendIfUnique(symbol.declarations, node)
    end
    -- On merge of const enum module with class or function, reset const enum only flag (namespaces will already recalculate)
    if symbol.flags & SymbolFlags.ConstEnumOnlyModule ~= 0 and symbol.flags & (SymbolFlags.Function | SymbolFlags.Class | SymbolFlags.RegularEnum) ~= 0 then
        symbol.flags = symbol.flags & ~SymbolFlags.ConstEnumOnlyModule
        self.notConstEnumOnlyModules[symbol] = true
    end
    if symbolFlags & SymbolFlags.Value ~= 0 then
        binder.SetValueDeclaration(symbol, node)
    end
end

function binder.SetValueDeclaration(symbol, node)
    local valueDeclaration = symbol.valueDeclaration
    if valueDeclaration == nil or
        binder.isAssignmentDeclaration(valueDeclaration) and not binder.isAssignmentDeclaration(node) or
        valueDeclaration.kind ~= node.kind and binder.isEffectiveModuleDeclaration(valueDeclaration) then
        -- Non-assignment declarations take precedence over assignment declarations and
        -- non-namespace declarations take precedence over namespace declarations.
        symbol.valueDeclaration = node
    end
end

function binder.GetContainerFlags(node)
    local kind = node.kind
    if kind == Kind.ClassExpression or kind == Kind.ClassDeclaration or kind == Kind.EnumDeclaration or kind == Kind.ObjectLiteralExpression or kind == Kind.TypeLiteral or
        kind == Kind.JsxAttributes then
        return ContainerFlags.IsContainer
    elseif kind == Kind.InterfaceDeclaration then
        return ContainerFlags.IsContainer | ContainerFlags.IsInterface
    elseif kind == Kind.ModuleDeclaration or kind == Kind.TypeAliasDeclaration or kind == Kind.JSTypeAliasDeclaration or kind == Kind.MappedType or kind == Kind.IndexSignature then
        return ContainerFlags.IsContainer | ContainerFlags.HasLocals
    elseif kind == Kind.SourceFile then
        return ContainerFlags.IsContainer | ContainerFlags.IsControlFlowContainer | ContainerFlags.HasLocals
    elseif kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.MethodDeclaration or
        kind == Kind.Constructor or kind == Kind.FunctionDeclaration or kind == Kind.ClassStaticBlockDeclaration then
        if (kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.MethodDeclaration) and ast.IsObjectLiteralOrClassExpressionMethodOrAccessor(node) then
            return ContainerFlags.IsContainer | ContainerFlags.IsControlFlowContainer | ContainerFlags.HasLocals | ContainerFlags.IsFunctionLike | ContainerFlags.IsObjectLiteralOrClassExpressionMethodOrAccessor | ContainerFlags.IsThisContainer
        end
        return ContainerFlags.IsContainer | ContainerFlags.IsControlFlowContainer | ContainerFlags.HasLocals | ContainerFlags.IsFunctionLike | ContainerFlags.IsThisContainer
    elseif kind == Kind.MethodSignature or kind == Kind.CallSignature or kind == Kind.FunctionType or kind == Kind.ConstructSignature or kind == Kind.ConstructorType then
        return ContainerFlags.IsContainer | ContainerFlags.IsControlFlowContainer | ContainerFlags.HasLocals | ContainerFlags.IsFunctionLike | ContainerFlags.PropagatesThisKeyword
    elseif kind == Kind.FunctionExpression then
        return ContainerFlags.IsContainer | ContainerFlags.IsControlFlowContainer | ContainerFlags.HasLocals | ContainerFlags.IsFunctionLike | ContainerFlags.IsFunctionExpression | ContainerFlags.IsThisContainer
    elseif kind == Kind.ArrowFunction then
        return ContainerFlags.IsContainer | ContainerFlags.IsControlFlowContainer | ContainerFlags.HasLocals | ContainerFlags.IsFunctionLike | ContainerFlags.IsFunctionExpression | ContainerFlags.PropagatesThisKeyword
    elseif kind == Kind.ModuleBlock then
        return ContainerFlags.IsControlFlowContainer
    elseif kind == Kind.PropertyDeclaration then
        if node:Initializer() ~= nil then
            return ContainerFlags.IsControlFlowContainer | ContainerFlags.IsThisContainer
        else
            return ContainerFlags.None
        end
    elseif kind == Kind.CatchClause or kind == Kind.ForStatement or kind == Kind.ForInStatement or kind == Kind.ForOfStatement or kind == Kind.CaseBlock then
        return ContainerFlags.IsBlockScopedContainer | ContainerFlags.HasLocals
    elseif kind == Kind.Block then
        if ast.IsFunctionLike(node.parent) or ast.IsClassStaticBlockDeclaration(node.parent) then
            return ContainerFlags.None
        else
            return ContainerFlags.IsBlockScopedContainer | ContainerFlags.HasLocals
        end
    end
    return ContainerFlags.None
end

function binder.isNarrowingExpression(expr)
    local kind = expr.kind
    if kind == Kind.Identifier or kind == Kind.ThisKeyword then
        return true
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression then
        return binder.containsNarrowableReference(expr)
    elseif kind == Kind.CallExpression then
        return binder.hasNarrowableArgument(expr)
    elseif kind == Kind.ParenthesizedExpression or kind == Kind.NonNullExpression or kind == Kind.TypeOfExpression then
        return binder.isNarrowingExpression(expr:Expression())
    elseif kind == Kind.BinaryExpression then
        return binder.isNarrowingBinaryExpression(expr)
    elseif kind == Kind.PrefixUnaryExpression then
        return expr.operator == Kind.ExclamationToken and binder.isNarrowingExpression(expr.operand)
    end
    return false
end

function binder.containsNarrowableReference(expr)
    if binder.isNarrowableReference(expr) then
        return true
    end
    if expr.flags & NodeFlags.OptionalChain ~= 0 then
        local kind = expr.kind
        if kind == Kind.PropertyAccessExpression or kind == Kind.ElementAccessExpression or kind == Kind.CallExpression or kind == Kind.NonNullExpression then
            return binder.containsNarrowableReference(expr:Expression())
        end
    end
    return false
end

function binder.isNarrowableReference(node)
    local kind = node.kind
    if kind == Kind.Identifier or kind == Kind.ThisKeyword or kind == Kind.SuperKeyword or kind == Kind.MetaProperty then
        return true
    elseif kind == Kind.PropertyAccessExpression or kind == Kind.ParenthesizedExpression or kind == Kind.NonNullExpression then
        return binder.isNarrowableReference(node:Expression())
    elseif kind == Kind.ElementAccessExpression then
        local expr = node
        return ast.IsStringOrNumericLiteralLike(expr.argumentExpression) or
            ast.IsEntityNameExpression(expr.argumentExpression) and binder.isNarrowableReference(expr.expression)
    elseif kind == Kind.BinaryExpression then
        local expr = node
        return expr.operatorToken.kind == Kind.CommaToken and binder.isNarrowableReference(expr.right) or
            ast.IsAssignmentOperator(expr.operatorToken.kind) and ast.IsLeftHandSideExpression(expr.left)
    end
    return false
end

function binder.hasNarrowableArgument(expr)
    local call = expr
    for _, argument in ipairs(call.arguments.nodes) do
        if binder.containsNarrowableReference(argument) then
            return true
        end
    end
    if ast.IsPropertyAccessExpression(call.expression) then
        if binder.containsNarrowableReference(call.expression:Expression()) then
            return true
        end
    end
    return false
end

function binder.isNarrowingBinaryExpression(expr)
    local op = expr.operatorToken.kind
    if op == Kind.EqualsToken or op == Kind.BarBarEqualsToken or op == Kind.AmpersandAmpersandEqualsToken or op == Kind.QuestionQuestionEqualsToken then
        return binder.containsNarrowableReference(expr.left)
    elseif op == Kind.EqualsEqualsToken or op == Kind.ExclamationEqualsToken or op == Kind.EqualsEqualsEqualsToken or op == Kind.ExclamationEqualsEqualsToken then
        local left = ast.SkipParentheses(expr.left)
        local right = ast.SkipParentheses(expr.right)
        return binder.isNarrowableOperand(left) or binder.isNarrowableOperand(right) or
            binder.isNarrowingTypeOfOperands(right, left) or binder.isNarrowingTypeOfOperands(left, right) or
            (ast.IsBooleanLiteral(right) and binder.isNarrowingExpression(left) or ast.IsBooleanLiteral(left) and binder.isNarrowingExpression(right))
    elseif op == Kind.InstanceOfKeyword then
        return binder.isNarrowableOperand(expr.left)
    elseif op == Kind.InKeyword then
        return binder.isNarrowingExpression(expr.right)
    elseif op == Kind.CommaToken then
        return binder.isNarrowingExpression(expr.right)
    end
    return false
end

function binder.isNarrowableOperand(expr)
    local kind = expr.kind
    if kind == Kind.ParenthesizedExpression then
        return binder.isNarrowableOperand(expr:Expression())
    elseif kind == Kind.BinaryExpression then
        local binary = expr
        local op = binary.operatorToken.kind
        if op == Kind.EqualsToken then
            return binder.isNarrowableOperand(binary.left)
        elseif op == Kind.CommaToken then
            return binder.isNarrowableOperand(binary.right)
        end
    end
    return binder.containsNarrowableReference(expr)
end

function binder.isNarrowingTypeOfOperands(expr1, expr2)
    return ast.IsTypeOfExpression(expr1) and binder.isNarrowableOperand(expr1:Expression()) and ast.IsStringLiteralLike(expr2)
end

function Binder:errorOnNode(node, message, ...)
    self:addDiagnostic(self:createDiagnosticForNode(node, message, ...))
end

function Binder:errorOnFirstToken(node, message, ...)
    local span = scanner.GetRangeOfTokenAtPosition(self.file, node:Pos())
    self:addDiagnostic(ast.NewDiagnostic(self.file, span, message, ...))
end

-- Inside the binder, we may create a diagnostic for an as-yet unbound node (with potentially no parent pointers, implying no accessible source file)
-- If so, the node _must_ be in the current file (as that's the only way anything could have traversed to it to yield it as the error node)
-- This version of `createDiagnosticForNode` uses the binder's context to account for this, and always yields correct diagnostics even in these situations.
function Binder:createDiagnosticForNode(node, message, ...)
    return ast.NewDiagnostic(self.file, scanner.GetErrorRangeForNode(self.file, node), message, ...)
end

function Binder:addDiagnostic(diagnostic)
    local diags = self.file:BindDiagnostics() or {}
    diags[#diags + 1] = diagnostic
    self.file:SetBindDiagnostics(diags)
end

function binder.isSignedNumericLiteral(node)
    if node.kind == Kind.PrefixUnaryExpression then
        return (node.operator == Kind.PlusToken or node.operator == Kind.MinusToken) and ast.IsNumericLiteral(node.operand)
    end
    return false
end

function binder.getOptionalSymbolFlagForNode(node)
    local postfixToken = node:PostfixToken()
    if postfixToken ~= nil and postfixToken.kind == Kind.QuestionToken then
        return SymbolFlags.Optional
    end
    return SymbolFlags.None
end

function binder.isFunctionSymbol(symbol)
    local d = symbol.valueDeclaration
    if d ~= nil then
        if ast.IsFunctionDeclaration(d) then
            return true
        end
        if ast.IsVariableDeclaration(d) then
            local varDecl = d
            if varDecl.initializer ~= nil then
                return ast.IsFunctionLike(varDecl.initializer)
            end
        end
    end
    return false
end

function binder.isStatementCondition(node)
    local kind = node.parent.kind
    if kind == Kind.IfStatement or kind == Kind.WhileStatement or kind == Kind.DoStatement then
        return node.parent:Expression() == node
    elseif kind == Kind.ForStatement then
        return node.parent.condition == node
    elseif kind == Kind.ConditionalExpression then
        return node.parent.condition == node
    end
    return false
end

function binder.isTopLevelLogicalExpression(node)
    while ast.IsParenthesizedExpression(node.parent) or ast.IsPrefixUnaryExpression(node.parent) and node.parent.operator == Kind.ExclamationToken do
        node = node.parent
    end
    return not binder.isStatementCondition(node) and not ast.IsLogicalExpression(node.parent) and not (ast.IsOptionalChain(node.parent) and node.parent:Expression() == node)
end

function binder.isAssignmentDeclaration(decl)
    return ast.IsBinaryExpression(decl) or ast.IsAccessExpression(decl) or ast.IsIdentifier(decl) or ast.IsCallExpression(decl)
end

function binder.isEffectiveModuleDeclaration(node)
    return ast.IsModuleDeclaration(node) or ast.IsIdentifier(node)
end
