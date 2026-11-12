local checker = require("tslua.checker")
local Checker = checker.Checker
local ast = require("tslua.ast")
local binder = require("tslua.binder")
local core = require("tslua.core")
local debug = require("tslua.debug")
local diagnostics = require("tslua.diagnostics")
local jsnum = require("tslua.jsnum")
local module = require("tslua.module")
local printer = require("tslua.printer")
local scanner = require("tslua.scanner")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags
local NodeFlags = ast.NodeFlags
local SymbolFlags = ast.SymbolFlags
local CheckFlags = ast.CheckFlags
local TypeFlags = checker.TypeFlags
local ObjectFlags = checker.ObjectFlags
local TypeMapperKind = checker.TypeMapperKind
local AssignmentKind = checker.AssignmentKind
local FindAncestorResult = ast.FindAncestorResult

-- Go strings.Compare (byte-wise).
local function compareStrings(a, b)
    if a == b then
        return 0
    end
    if a < b then
        return -1
    end
    return 1
end

function checker.NewDiagnosticForNode(node, message, ...)
    local file
    local loc = core.NewTextRange(0, 0)
    if node ~= nil then
        file = ast.GetSourceFileOfNode(node)
        loc = scanner.GetErrorRangeForNode(file, node)
    end
    return ast.NewDiagnostic(file, loc, message, ...)
end

function checker.NewDiagnosticChainForNode(chain, node, message, ...)
    if chain ~= nil then
        return ast.NewDiagnosticChain(chain, message, ...)
    end
    return checker.NewDiagnosticForNode(node, message, ...)
end

function checker.findInMap(m, predicate)
    for _, value in pairs(m) do
        if predicate(value) then
            return value
        end
    end
    return nil
end

function checker.tokenIsIdentifierOrKeyword(token)
    return token >= Kind.Identifier
end

function checker.tokenIsIdentifierOrKeywordOrGreaterThan(token)
    return token == Kind.GreaterThanToken or checker.tokenIsIdentifierOrKeyword(token)
end

function checker.hasOverrideModifier(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Override)
end

function checker.hasAsyncModifier(node)
    return ast.HasSyntacticModifier(node, ModifierFlags.Async)
end

function checker.getSelectedModifierFlags(node, flags)
    return node:ModifierFlags() & flags
end

function checker.hasReadonlyModifier(node)
    return ast.HasModifier(node, ModifierFlags.Readonly)
end

function checker.isStaticPrivateIdentifierProperty(s)
    return s.valueDeclaration ~= nil and ast.IsPrivateIdentifierClassElementDeclaration(s.valueDeclaration) and ast.IsStatic(s.valueDeclaration)
end

function checker.isEmptyObjectLiteral(expression)
    return ast.IsObjectLiteralExpression(expression) and #expression:Properties() == 0
end

-- AssignmentTarget = ast.Node // BinaryExpression | PrefixUnaryExpression | PostfixUnaryExpression | ForInOrOfStatement

function checker.getAssignmentTargetKind(node)
    local target = ast.GetAssignmentTarget(node)
    if target == nil then
        return AssignmentKind.None
    end
    local kind = target.kind
    if kind == Kind.BinaryExpression then
        local binaryOperator = target:AsBinaryExpression().operatorToken.kind
        if binaryOperator == Kind.EqualsToken or ast.IsLogicalOrCoalescingAssignmentOperator(binaryOperator) then
            return AssignmentKind.Definite
        end
        return AssignmentKind.Compound
    elseif kind == Kind.PrefixUnaryExpression or kind == Kind.PostfixUnaryExpression then
        return AssignmentKind.Compound
    elseif kind == Kind.ForInStatement or kind == Kind.ForOfStatement then
        return AssignmentKind.Definite
    end
    error("Unhandled case in getAssignmentTargetKind", 0)
end

function checker.isDeleteTarget(node)
    if not ast.IsAccessExpression(node) then
        return false
    end
    node = ast.WalkUpParenthesizedExpressions(node.parent)
    return node ~= nil and node.kind == Kind.DeleteExpression
end

function checker.isInCompoundLikeAssignment(node)
    local target = ast.GetAssignmentTarget(node)
    return target ~= nil and ast.IsAssignmentExpression(target, true --[[excludeCompoundAssignment]]) and checker.isCompoundLikeAssignment(target)
end

function checker.isCompoundLikeAssignment(assignment)
    local right = ast.SkipParentheses(assignment:AsBinaryExpression().right)
    return right.kind == Kind.BinaryExpression and checker.isShiftOperatorOrHigher(right:AsBinaryExpression().operatorToken.kind)
end

function checker.isConstTypeReference(node)
    return ast.IsTypeReferenceNode(node) and core.Len(node:TypeArguments()) == 0 and ast.IsIdentifier(node:AsTypeReferenceNode().typeName) and node:AsTypeReferenceNode().typeName:Text() == "const"
end

-- isConstTypeReferenceName reports whether node is the `const` type name of a `const`
-- assertion (`x as const` / `<const>x`), which must not be resolved as a real name.
function checker.isConstTypeReferenceName(node)
    return node ~= nil and ast.IsIdentifier(node) and
        node.parent ~= nil and checker.isConstTypeReference(node.parent) and
        node.parent.parent ~= nil and ast.IsAssertionExpression(node.parent.parent)
end

-- isExportAssignmentExpressionName reports whether node is (the root entity name of) the
-- expression of an `export =` / `export default` assignment. Referencing a namespace or
-- type-only name there is legal, and checkExportAssignment decides whether it is an error,
-- so checkIdentifier must not report a value-usage error for it.
function checker.isExportAssignmentExpressionName(node)
    if node == nil then
        return false
    end
    local current = node
    while current.parent ~= nil and ast.IsPropertyAccessOrQualifiedName(current.parent) do
        current = current.parent
    end
    return current.parent ~= nil and ast.IsExportAssignment(current.parent) and current.parent:Expression() == current
end

function checker.GetSingleVariableOfVariableStatement(node)
    if not ast.IsVariableStatement(node) then
        return nil
    end
    return core.FirstOrNil(node:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes)
end

function checker.isTypeReferenceIdentifier(node)
    while node.parent.kind == Kind.QualifiedName do
        node = node.parent
    end
    return ast.IsTypeReferenceNode(node.parent)
end

function checker.IsInTypeQuery(node)
    -- TypeScript 1.0 spec (April 2014): 3.6.3
    -- A type query consists of the keyword typeof followed by an expression.
    -- The expression is restricted to a single identifier or a sequence of identifiers separated by periods
    return ast.FindAncestorOrQuit(node, function(n)
        if n.kind == Kind.TypeQuery then
            return FindAncestorResult.FindAncestorTrue
        elseif n.kind == Kind.Identifier or n.kind == Kind.QualifiedName then
            return FindAncestorResult.FindAncestorFalse
        end
        return FindAncestorResult.FindAncestorQuit
    end) ~= nil
end

local canHaveLocalsKinds = {
    [Kind.ArrowFunction] = true,
    [Kind.Block] = true,
    [Kind.CallSignature] = true,
    [Kind.CaseBlock] = true,
    [Kind.CatchClause] = true,
    [Kind.ClassStaticBlockDeclaration] = true,
    [Kind.ConditionalType] = true,
    [Kind.Constructor] = true,
    [Kind.ConstructorType] = true,
    [Kind.ConstructSignature] = true,
    [Kind.ForStatement] = true,
    [Kind.ForInStatement] = true,
    [Kind.ForOfStatement] = true,
    [Kind.FunctionDeclaration] = true,
    [Kind.FunctionExpression] = true,
    [Kind.FunctionType] = true,
    [Kind.GetAccessor] = true,
    [Kind.IndexSignature] = true,
    [Kind.JSDocSignature] = true,
    [Kind.MappedType] = true,
    [Kind.MethodDeclaration] = true,
    [Kind.MethodSignature] = true,
    [Kind.ModuleDeclaration] = true,
    [Kind.SetAccessor] = true,
    [Kind.SourceFile] = true,
    [Kind.TypeAliasDeclaration] = true,
    [Kind.JSTypeAliasDeclaration] = true,
}

function checker.canHaveLocals(node)
    return canHaveLocalsKinds[node.kind] == true
end

function checker.isShorthandAmbientModuleSymbol(moduleSymbol)
    return checker.isShorthandAmbientModule(moduleSymbol.valueDeclaration)
end

function checker.isShorthandAmbientModule(node)
    -- The only kind of module that can be missing a body is a shorthand ambient module.
    return node ~= nil and node.kind == Kind.ModuleDeclaration and node:Body() == nil
end

function checker.getAliasDeclarationFromName(node)
    local kind = node.parent.kind
    if kind == Kind.ImportClause or kind == Kind.ImportSpecifier or kind == Kind.NamespaceImport or kind == Kind.ExportSpecifier or kind == Kind.ExportAssignment or
        kind == Kind.ImportEqualsDeclaration or kind == Kind.NamespaceExport then
        return node.parent
    elseif kind == Kind.QualifiedName then
        return checker.getAliasDeclarationFromName(node.parent)
    end
    return nil
end

function checker.entityNameToString(name)
    return ast.EntityNameToString(name, scanner.GetTextOfNode)
end

function checker.getContainingQualifiedNameNode(node)
    while ast.IsQualifiedName(node.parent) do
        node = node.parent
    end
    return node
end

function checker.isSideEffectImport(node)
    local ancestor = ast.FindAncestor(node, ast.IsImportDeclaration)
    return ancestor ~= nil and ancestor:ImportClause() == nil
end

function checker.getExternalModuleRequireArgument(node)
    if ast.IsVariableDeclarationInitializedToRequire(node) then
        return node:Initializer():Arguments()[1]
    end
    return nil
end

function checker.isRightSideOfAccessExpression(node)
    return node.parent ~= nil and (ast.IsPropertyAccessExpression(node.parent) and node.parent:Name() == node or
        ast.IsElementAccessExpression(node.parent) and node.parent:AsElementAccessExpression().argumentExpression == node)
end

function checker.isTopLevelInExternalModuleAugmentation(node)
    return node ~= nil and node.parent ~= nil and ast.IsModuleBlock(node.parent) and ast.IsExternalModuleAugmentation(node.parent.parent)
end

function checker.isSyntacticDefault(node)
    return (ast.IsExportAssignment(node) and not node:AsExportAssignment().isExportEquals) or
        ast.HasSyntacticModifier(node, ModifierFlags.Default) or
        ast.IsExportSpecifier(node) or
        ast.IsNamespaceExport(node)
end

function checker.hasExportAssignmentSymbol(moduleSymbol)
    return moduleSymbol.exports ~= nil and moduleSymbol.exports[ast.InternalSymbolNameExportEquals] ~= nil
end

function checker.isTypeAlias(node)
    return ast.IsTypeOrJSTypeAliasDeclaration(node)
end

function checker.hasOnlyExpressionInitializer(node)
    local kind = node.kind
    return kind == Kind.VariableDeclaration or kind == Kind.Parameter or kind == Kind.BindingElement or kind == Kind.PropertyDeclaration or
        kind == Kind.PropertyAssignment or kind == Kind.EnumMember
end

function checker.hasDotDotDotToken(node)
    local kind = node.kind
    if kind == Kind.Parameter then
        return node:AsParameterDeclaration().dotDotDotToken ~= nil
    elseif kind == Kind.BindingElement then
        return node:AsBindingElement().dotDotDotToken ~= nil
    elseif kind == Kind.NamedTupleMember then
        return node:AsNamedTupleMember().dotDotDotToken ~= nil
    elseif kind == Kind.JsxExpression then
        return node:AsJsxExpression().dotDotDotToken ~= nil
    end
    return false
end

function checker.IsTypeAny(t)
    return t ~= nil and t.flags & TypeFlags.Any ~= 0
end

function checker.isJSDocOptionalParameter(node)
    return false -- !!!
end

function checker.isExclamationToken(node)
    return node ~= nil and node.kind == Kind.ExclamationToken
end

function checker.isOptionalDeclaration(declaration)
    return ast.HasQuestionToken(declaration)
end

function Checker:isOptionalParameter(node)
    -- !!! TODO: JSDoc support
    if ast.IsParameterDeclaration(node) and node:QuestionToken() ~= nil then
        return true
    end
    if not ast.IsParameterDeclaration(node) then
        return false
    end
    if node:Initializer() ~= nil then
        local signature = self:getSignatureFromDeclaration(node.parent)
        local parameterIndex = core.FindIndex(node.parent:Parameters(), function(p)
            return p == node
        end)
        debug.Assert(parameterIndex >= 0)
        -- Only consider syntactic or instantiated parameters as optional, not `void` parameters as this function is used
        -- in grammar checks and checking for `void` too early results in parameter types widening too early
        -- and causes some noImplicitAny errors to be lost.
        return parameterIndex >= self:getMinArgumentCountEx(signature, checker.MinArgumentCountFlags.StrongArityForUntypedJS | checker.MinArgumentCountFlags.VoidIsNonOptional)
    end
    local iife = ast.GetImmediatelyInvokedFunctionExpression(node.parent)
    if iife ~= nil then
        local parameterIndex = core.FindIndex(node.parent:Parameters(), function(p)
            return p == node
        end)
        return node:Type() == nil and
            node:AsParameterDeclaration().dotDotDotToken == nil and
            parameterIndex >= core.Len(self:getEffectiveCallArguments(iife))
    end
    return false
end

function checker.isEmptyArrayLiteral(expression)
    return ast.IsArrayLiteralExpression(expression) and #expression:Elements() == 0
end

function checker.declarationBelongsToPrivateAmbientMember(declaration)
    local root = ast.GetRootDeclaration(declaration)
    local memberDeclaration = root
    if root.kind == Kind.Parameter then
        memberDeclaration = root.parent
    end
    return checker.isPrivateWithinAmbient(memberDeclaration)
end

function checker.isPrivateWithinAmbient(node)
    return (ast.HasModifier(node, ModifierFlags.Private) or ast.IsPrivateIdentifierClassElementDeclaration(node)) and node.flags & NodeFlags.Ambient ~= 0
end

function checker.isTypeAssertion(node)
    return ast.IsAssertionExpression(ast.SkipParentheses(node))
end

function checker.createSymbolTable(symbols)
    if core.Len(symbols) == 0 then
        return nil
    end
    local result = ast.NewSymbolTable()
    for _, symbol in ipairs(symbols) do
        result[symbol.name] = symbol
    end
    return result
end

function Checker:sortSymbols(symbols)
    local compareSymbols = self.compareSymbols
    table.sort(symbols, function(a, b)
        return compareSymbols(a, b) < 0
    end)
end

function Checker:compareSymbolsWorker(s1, s2)
    if s1 == s2 then
        return 0
    end
    if s1 == nil then
        return 1
    end
    if s2 == nil then
        return -1
    end
    local n1 = core.Len(s1.declarations)
    local n2 = core.Len(s2.declarations)
    if n1 ~= 0 and n2 ~= 0 then
        local r = self:compareNodes(s1.declarations[1], s2.declarations[1])
        if r ~= 0 then
            return r
        end
    elseif n1 ~= 0 then
        return -1
    elseif n2 ~= 0 then
        return 1
    end
    local r = compareStrings(s1.name, s2.name)
    if r ~= 0 then
        return r
    end
    -- Fall back to symbol IDs. This is a last resort that should happen only when symbols have
    -- no declaration and duplicate names.
    return ast.GetSymbolId(s1) - ast.GetSymbolId(s2)
end

function Checker:compareNodes(n1, n2)
    if n1 == n2 then
        return 0
    end
    if n1 == nil then
        return 1
    end
    if n2 == nil then
        return -1
    end
    local s1 = ast.GetSourceFileOfNode(n1)
    local s2 = ast.GetSourceFileOfNode(n2)
    if s1 ~= s2 then
        local f1 = self.fileIndexMap[s1] or 0
        local f2 = self.fileIndexMap[s2] or 0
        -- Order by index of file in the containing program
        return f1 - f2
    end
    -- In the same file, order by source position
    return n1:Pos() - n2:Pos()
end

-- Go cmp.Compare for float64 (NaN sorts before every other value).
local function compareNumbers(a, b)
    local aNaN = a ~= a
    local bNaN = b ~= b
    if aNaN then
        if bNaN then
            return 0
        end
        return -1
    end
    if bNaN then
        return 1
    end
    if a < b then
        return -1
    end
    if a > b then
        return 1
    end
    return 0
end

-- Go slices.Compare for string slices.
local function compareStringSlices(s1, s2)
    local n1 = core.Len(s1)
    local n2 = core.Len(s2)
    for i = 1, math.min(n1, n2) do
        local c = compareStrings(s1[i], s2[i])
        if c ~= 0 then
            return c
        end
    end
    if n1 < n2 then
        return -1
    end
    if n1 > n2 then
        return 1
    end
    return 0
end

function checker.CompareTypes(t1, t2)
    if t1 == t2 then
        return 0
    end
    if t1 == nil then
        return -1
    end
    if t2 == nil then
        return 1
    end
    if t1.checker ~= t2.checker then
        error("Cannot compare types from different checkers", 0)
    end
    -- First sort in order of increasing type flags values.
    local c = checker.getSortOrderFlags(t1) - checker.getSortOrderFlags(t2)
    if c ~= 0 then
        return c
    end
    -- Order named types by name and, in the case of aliased types, by alias type arguments.
    c = checker.compareTypeNames(t1, t2)
    if c ~= 0 then
        return c
    end
    -- We have unnamed types or types with identical names. Now sort by data specific to the type.
    local flags = t1.flags
    if flags & (TypeFlags.Any | TypeFlags.Unknown | TypeFlags.String | TypeFlags.Number | TypeFlags.Boolean | TypeFlags.BigInt | TypeFlags.ESSymbol | TypeFlags.Void | TypeFlags.Undefined | TypeFlags.Null | TypeFlags.Never | TypeFlags.NonPrimitive) ~= 0 then
        -- Only distinguished by type IDs, handled below.
    elseif flags & TypeFlags.Object ~= 0 then
        -- Order unnamed or identically named object types by symbol.
        c = t1.checker.compareSymbols(t1.symbol, t2.symbol)
        if c ~= 0 then
            return c
        end
        -- When object types have the same or no symbol, order by kind. We order type references before other kinds.
        if t1.objectFlags & ObjectFlags.Reference ~= 0 and t2.objectFlags & ObjectFlags.Reference ~= 0 then
            local r1 = t1:AsTypeReference()
            local r2 = t2:AsTypeReference()
            if r1.target.objectFlags & ObjectFlags.Tuple ~= 0 and r2.target.objectFlags & ObjectFlags.Tuple ~= 0 then
                -- Tuple types have no associated symbol, instead we order by tuple element information.
                c = checker.compareTupleTypes(r1.target:AsTupleType(), r2.target:AsTupleType())
                if c ~= 0 then
                    return c
                end
            end
            -- Here we know we have references to instantiations of the same type because we have matching targets.
            if r1.node == nil and r2.node == nil then
                -- Non-deferred type references with the same target are sorted by their type argument lists.
                c = checker.compareTypeLists(t1:AsTypeReference().resolvedTypeArguments, t2:AsTypeReference().resolvedTypeArguments)
                if c ~= 0 then
                    return c
                end
            else
                -- Deferred type references with the same target are ordered by the source location of the reference.
                c = t1.checker:compareNodes(r1.node, r2.node)
                if c ~= 0 then
                    return c
                end
                -- Instantiations of the same deferred type reference are ordered by their associated type mappers
                -- (which reflect the mapping of in-scope type parameters to type arguments).
                c = checker.compareTypeMappers(t1:AsObjectType().mapper, t2:AsObjectType().mapper)
                if c ~= 0 then
                    return c
                end
            end
        elseif t1.objectFlags & ObjectFlags.Reference ~= 0 then
            return -1
        elseif t2.objectFlags & ObjectFlags.Reference ~= 0 then
            return 1
        else
            -- Order unnamed non-reference object types by kind associated type mappers. Reverse mapped types have
            -- neither symbols nor mappers so they're ultimately ordered by unstable type IDs, but given their rarity
            -- this should be fine.
            c = (t1.objectFlags & ObjectFlags.ObjectTypeKindMask) - (t2.objectFlags & ObjectFlags.ObjectTypeKindMask)
            if c ~= 0 then
                return c
            end
            c = checker.compareTypeMappers(t1:AsObjectType().mapper, t2:AsObjectType().mapper)
            if c ~= 0 then
                return c
            end
        end
    elseif flags & TypeFlags.Union ~= 0 then
        -- Unions are ordered by origin and then constituent type lists.
        local o1 = t1:AsUnionType().origin
        local o2 = t2:AsUnionType().origin
        if o1 == nil and o2 == nil then
            c = checker.compareTypeLists(t1:Types(), t2:Types())
            if c ~= 0 then
                return c
            end
        elseif o1 == nil then
            return 1
        elseif o2 == nil then
            return -1
        else
            c = checker.CompareTypes(o1, o2)
            if c ~= 0 then
                return c
            end
        end
    elseif flags & TypeFlags.Intersection ~= 0 then
        -- Intersections are ordered by their constituent type lists.
        c = checker.compareTypeLists(t1:Types(), t2:Types())
        if c ~= 0 then
            return c
        end
    elseif flags & (TypeFlags.Enum | TypeFlags.EnumLiteral | TypeFlags.UniqueESSymbol) ~= 0 then
        -- Enum members are ordered by their symbol (and thus their declaration order).
        c = t1.checker.compareSymbols(t1.symbol, t2.symbol)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.StringLiteral ~= 0 then
        -- String literal types are ordered by their values.
        c = compareStrings(t1:AsLiteralType().value, t2:AsLiteralType().value)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.NumberLiteral ~= 0 then
        -- Numeric literal types are ordered by their values.
        c = compareNumbers(t1:AsLiteralType().value, t2:AsLiteralType().value)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.BooleanLiteral ~= 0 then
        local b1 = t1:AsLiteralType().value
        local b2 = t2:AsLiteralType().value
        if b1 ~= b2 then
            if b1 then
                return 1
            end
            return -1
        end
    elseif flags & TypeFlags.TypeParameter ~= 0 then
        c = t1.checker.compareSymbols(t1.symbol, t2.symbol)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.Index ~= 0 then
        c = checker.CompareTypes(t1:AsIndexType().target, t2:AsIndexType().target)
        if c ~= 0 then
            return c
        end
        c = t1:AsIndexType().indexFlags - t2:AsIndexType().indexFlags
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.IndexedAccess ~= 0 then
        c = checker.CompareTypes(t1:AsIndexedAccessType().objectType, t2:AsIndexedAccessType().objectType)
        if c ~= 0 then
            return c
        end
        c = checker.CompareTypes(t1:AsIndexedAccessType().indexType, t2:AsIndexedAccessType().indexType)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.Conditional ~= 0 then
        c = t1.checker:compareNodes(t1:AsConditionalType().root.node, t2:AsConditionalType().root.node)
        if c ~= 0 then
            return c
        end
        c = checker.compareTypeMappers(t1:AsConditionalType().mapper, t2:AsConditionalType().mapper)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.Substitution ~= 0 then
        c = checker.CompareTypes(t1:AsSubstitutionType().baseType, t2:AsSubstitutionType().baseType)
        if c ~= 0 then
            return c
        end
        c = checker.CompareTypes(t1:AsSubstitutionType().constraint, t2:AsSubstitutionType().constraint)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.TemplateLiteral ~= 0 then
        c = compareStringSlices(t1:AsTemplateLiteralType().texts, t2:AsTemplateLiteralType().texts)
        if c ~= 0 then
            return c
        end
        c = checker.compareTypeLists(t1:AsTemplateLiteralType().types, t2:AsTemplateLiteralType().types)
        if c ~= 0 then
            return c
        end
    elseif flags & TypeFlags.StringMapping ~= 0 then
        c = checker.CompareTypes(t1:AsStringMappingType().target, t2:AsStringMappingType().target)
        if c ~= 0 then
            return c
        end
    end
    -- Fall back to type IDs. This results in type creation order for built-in types.
    return t1.id - t2.id
end

function checker.getSortOrderFlags(t)
    -- Return TypeFlagsEnum for all enum-like unit types (they'll be sorted by their symbols)
    if t.flags & (TypeFlags.EnumLiteral | TypeFlags.Enum) ~= 0 and t.flags & TypeFlags.Union == 0 then
        return TypeFlags.Enum
    end
    return t.flags
end

function checker.compareTypeNames(t1, t2)
    local s1 = checker.getTypeNameSymbol(t1)
    local s2 = checker.getTypeNameSymbol(t2)
    if s1 == s2 then
        if t1.alias ~= nil then
            return checker.compareTypeLists(t1.alias.typeArguments, t2.alias.typeArguments)
        end
        return 0
    end
    if s1 == nil then
        return 1
    end
    if s2 == nil then
        return -1
    end
    return compareStrings(s1.name, s2.name)
end

function checker.getTypeNameSymbol(t)
    if t.alias ~= nil then
        return t.alias.symbol
    end
    if t.flags & (TypeFlags.TypeParameter | TypeFlags.StringMapping) ~= 0 or t.objectFlags & (ObjectFlags.ClassOrInterface | ObjectFlags.Reference) ~= 0 then
        return t.symbol
    end
    return nil
end

function checker.getObjectTypeName(t)
    if t.objectFlags & (ObjectFlags.ClassOrInterface | ObjectFlags.Reference) ~= 0 then
        return t.symbol
    end
    return nil
end

function checker.compareTupleTypes(t1, t2)
    if t1 == t2 then
        return 0
    end
    if t1.readonly ~= t2.readonly then
        return core.IfElse(t1.readonly, 1, -1)
    end
    local n1 = core.Len(t1.elementInfos)
    local n2 = core.Len(t2.elementInfos)
    if n1 ~= n2 then
        return n1 - n2
    end
    for i = 1, n1 do
        local c = t1.elementInfos[i].flags - t2.elementInfos[i].flags
        if c ~= 0 then
            return c
        end
    end
    for i = 1, n1 do
        local c = checker.compareElementLabels(t1.elementInfos[i].labeledDeclaration, t2.elementInfos[i].labeledDeclaration)
        if c ~= 0 then
            return c
        end
    end
    return 0
end

function checker.compareElementLabels(n1, n2)
    if n1 == n2 then
        return 0
    end
    if n1 == nil then
        return -1
    end
    if n2 == nil then
        return 1
    end
    return compareStrings(n1:Name():Text(), n2:Name():Text())
end

function checker.compareTypeLists(s1, s2)
    local n1 = core.Len(s1)
    local n2 = core.Len(s2)
    if n1 ~= n2 then
        return n1 - n2
    end
    for i = 1, n1 do
        local c = checker.CompareTypes(s1[i], s2[i])
        if c ~= 0 then
            return c
        end
    end
    return 0
end

function checker.compareTypeMappers(m1, m2)
    if m1 == m2 then
        return 0
    end
    if m1 == nil then
        return 1
    end
    if m2 == nil then
        return -1
    end
    local kind1 = m1:Kind()
    local kind2 = m2:Kind()
    if kind1 ~= kind2 then
        return kind1 - kind2
    end
    if kind1 == TypeMapperKind.Simple then
        local d1 = m1.data
        local d2 = m2.data
        local c = checker.CompareTypes(d1.source, d2.source)
        if c ~= 0 then
            return c
        end
        return checker.CompareTypes(d1.target, d2.target)
    elseif kind1 == TypeMapperKind.Array then
        local d1 = m1.data
        local d2 = m2.data
        local c = checker.compareTypeLists(d1.sources, d2.sources)
        if c ~= 0 then
            return c
        end
        return checker.compareTypeLists(d1.targets, d2.targets)
    elseif kind1 == TypeMapperKind.Merged then
        local d1 = m1.data
        local d2 = m2.data
        local c = checker.compareTypeMappers(d1.m1, d2.m1)
        if c ~= 0 then
            return c
        end
        return checker.compareTypeMappers(d1.m2, d2.m2)
    end
    return 0
end

function checker.getDeclarationModifierFlagsFromSymbol(s)
    return checker.getDeclarationModifierFlagsFromSymbolEx(s, false --[[isWrite]])
end

function checker.getDeclarationModifierFlagsFromSymbolEx(s, isWrite)
    if s.valueDeclaration ~= nil then
        local declaration
        if isWrite then
            declaration = core.Find(s.declarations, ast.IsSetAccessorDeclaration)
        end
        if declaration == nil and s.flags & SymbolFlags.GetAccessor ~= 0 then
            declaration = core.Find(s.declarations, ast.IsGetAccessorDeclaration)
        end
        if declaration == nil then
            declaration = s.valueDeclaration
        end
        local flags = ast.GetCombinedModifierFlags(declaration)
        if s.parent ~= nil and s.parent.flags & SymbolFlags.Class ~= 0 then
            return flags
        end
        return flags & ~ModifierFlags.AccessibilityModifier
    end
    if s.checkFlags & CheckFlags.Synthetic ~= 0 then
        local accessModifier
        if s.checkFlags & CheckFlags.ContainsPrivate ~= 0 then
            accessModifier = ModifierFlags.Private
        elseif s.checkFlags & CheckFlags.ContainsPublic ~= 0 then
            accessModifier = ModifierFlags.Public
        else
            accessModifier = ModifierFlags.Protected
        end
        local staticModifier = ModifierFlags.None
        if s.checkFlags & CheckFlags.ContainsStatic ~= 0 then
            staticModifier = ModifierFlags.Static
        end
        return accessModifier | staticModifier
    end
    if s.flags & SymbolFlags.Prototype ~= 0 then
        return ModifierFlags.Public | ModifierFlags.Static
    end
    return ModifierFlags.None
end

function checker.isExponentiationOperator(kind)
    return kind == Kind.AsteriskAsteriskToken
end

function checker.isMultiplicativeOperator(kind)
    return kind == Kind.AsteriskToken or kind == Kind.SlashToken or kind == Kind.PercentToken
end

function checker.isMultiplicativeOperatorOrHigher(kind)
    return checker.isExponentiationOperator(kind) or checker.isMultiplicativeOperator(kind)
end

function checker.isAdditiveOperator(kind)
    return kind == Kind.PlusToken or kind == Kind.MinusToken
end

function checker.isAdditiveOperatorOrHigher(kind)
    return checker.isAdditiveOperator(kind) or checker.isMultiplicativeOperatorOrHigher(kind)
end

function checker.isShiftOperator(kind)
    return kind == Kind.LessThanLessThanToken or kind == Kind.GreaterThanGreaterThanToken or
        kind == Kind.GreaterThanGreaterThanGreaterThanToken
end

function checker.isShiftOperatorOrHigher(kind)
    return checker.isShiftOperator(kind) or checker.isAdditiveOperatorOrHigher(kind)
end

function checker.isRelationalOperator(kind)
    return kind == Kind.LessThanToken or kind == Kind.LessThanEqualsToken or kind == Kind.GreaterThanToken or
        kind == Kind.GreaterThanEqualsToken or kind == Kind.InstanceOfKeyword or kind == Kind.InKeyword
end

function checker.isRelationalOperatorOrHigher(kind)
    return checker.isRelationalOperator(kind) or checker.isShiftOperatorOrHigher(kind)
end

function checker.isEqualityOperator(kind)
    return kind == Kind.EqualsEqualsToken or kind == Kind.EqualsEqualsEqualsToken or
        kind == Kind.ExclamationEqualsToken or kind == Kind.ExclamationEqualsEqualsToken
end

function checker.isEqualityOperatorOrHigher(kind)
    return checker.isEqualityOperator(kind) or checker.isRelationalOperatorOrHigher(kind)
end

function checker.isBitwiseOperator(kind)
    return kind == Kind.AmpersandToken or kind == Kind.BarToken or kind == Kind.CaretToken
end

function checker.isBitwiseOperatorOrHigher(kind)
    return checker.isBitwiseOperator(kind) or checker.isEqualityOperatorOrHigher(kind)
end

function checker.isLogicalOperatorOrHigher(kind)
    return ast.IsLogicalBinaryOperator(kind) or checker.isBitwiseOperatorOrHigher(kind)
end

function checker.isAssignmentOperatorOrHigher(kind)
    return kind == Kind.QuestionQuestionToken or checker.isLogicalOperatorOrHigher(kind) or ast.IsAssignmentOperator(kind)
end

function checker.isBinaryOperator(kind)
    return checker.isAssignmentOperatorOrHigher(kind) or kind == Kind.CommaToken
end

function checker.isObjectLiteralType(t)
    return t.objectFlags & ObjectFlags.ObjectLiteral ~= 0
end

function checker.isDeclarationReadonly(declaration)
    return ast.GetCombinedModifierFlags(declaration) & ModifierFlags.Readonly ~= 0 and not ast.IsParameterPropertyDeclaration(declaration, declaration.parent)
end

-- orderedSetMapThreshold is the size at which an orderedSet materializes its dedup map.
-- Below this, contains() scans the values slice.
checker.orderedSetMapThreshold = 16

-- orderedSet[T]: valuesByKey (map or nil), values (array or nil). Zero value: checker.orderedSet_new().
local orderedSet = checker.defineStruct("orderedSet", nil, nil)

function orderedSet:contains(value)
    if self.valuesByKey == nil then
        if self.values ~= nil then
            for _, v in ipairs(self.values) do
                if v == value then
                    return true
                end
            end
        end
        return false
    end
    return self.valuesByKey[value] ~= nil
end

function orderedSet:add(value)
    if self.values == nil then
        self.values = {}
    end
    self.values[#self.values + 1] = value
    -- Small sets are served by a linear scan over values; only materialize the map once the set
    -- grows large enough for hashing to win.
    if self.valuesByKey == nil then
        if #self.values <= checker.orderedSetMapThreshold then
            return
        end
        self.valuesByKey = {}
        for i = 1, #self.values - 1 do
            self.valuesByKey[self.values[i]] = true
        end
    end
    self.valuesByKey[value] = true
end

function checker.getContainingFunctionOrClassStaticBlock(node)
    return ast.FindAncestor(node.parent, ast.IsFunctionLikeOrClassStaticBlockDeclaration)
end

function checker.isNodeDescendantOf(node, ancestor)
    while node ~= nil do
        if node == ancestor then
            return true
        end
        node = node.parent
    end
    return false
end

function checker.isTypeUsableAsPropertyName(t)
    return t.flags & TypeFlags.StringOrNumberLiteralOrUnique ~= 0
end

--[[
 * Gets the symbolic name for a member from its type.
]]
function checker.getPropertyNameFromType(t)
    if t.flags & TypeFlags.StringLiteral ~= 0 then
        return t:AsLiteralType().value
    elseif t.flags & TypeFlags.NumberLiteral ~= 0 then
        return jsnum.Number_String(t:AsLiteralType().value)
    elseif t.flags & TypeFlags.UniqueESSymbol ~= 0 then
        return t:AsUniqueESSymbolType().name
    end
    error("Unhandled case in getPropertyNameFromType", 0)
end

function checker.isNumericLiteralName(name)
    -- The intent of numeric names is that
    --     - they are names with text in a numeric form, and that
    --     - setting properties/indexing with them is always equivalent to doing so with the numeric literal 'numLit',
    --         acquired by applying the abstract 'ToNumber' operation on the name's text.
    --
    -- The subtlety is in the latter portion, as we cannot reliably say that anything that looks like a numeric literal is a numeric name.
    -- In fact, it is the case that the text of the name must be equal to 'ToString(numLit)' for this to hold.
    --
    -- Consider the property name '"0xF00D"'. When one indexes with '0xF00D', they are actually indexing with the value of 'ToString(0xF00D)'
    -- according to the ECMAScript specification, so it is actually as if the user indexed with the string '"61453"'.
    -- Thus, the text of all numeric literals equivalent to '61543' such as '0xF00D', '0xf00D', '0170015', etc. are not valid numeric names
    -- because their 'ToString' representation is not equal to their original text.
    -- This is motivated by ECMA-262 sections 9.3.1, 9.8.1, 11.1.5, and 11.2.1.
    --
    -- Here, we test whether 'ToString(ToNumber(name))' is exactly equal to 'name'.
    -- The '+' prefix operator is equivalent here to applying the abstract ToNumber operation.
    -- Applying the 'toString()' method on a number gives us the abstract ToString operation on a number.
    --
    -- Note that this accepts the values 'Infinity', '-Infinity', and 'NaN', and that this is intentional.
    -- This is desired behavior, because when indexing with them as numeric entities, you are indexing
    -- with the strings '"Infinity"', '"-Infinity"', and '"NaN"' respectively.
    return jsnum.Number_String(jsnum.FromString(name)) == name
end

function checker.isThisProperty(node)
    return (ast.IsPropertyAccessExpression(node) or ast.IsElementAccessExpression(node)) and node:Expression().kind == Kind.ThisKeyword
end

function checker.isValidNumberString(s, roundTripOnly)
    if s == "" then
        return false
    end
    local n = jsnum.FromString(s)
    return not jsnum.Number_IsNaN(n) and not jsnum.Number_IsInf(n) and (not roundTripOnly or jsnum.Number_String(n) == s)
end

function checker.isValidBigIntString(s, roundTripOnly)
    if s == "" then
        return false
    end
    local sc = scanner.NewScanner()
    sc:SetSkipTrivia(false)
    local success = true
    sc:SetOnError(function(diagnostic, start, length, ...)
        success = false
    end)
    sc:SetText(s .. "n")
    local result = sc:Scan()
    local negative = result == Kind.MinusToken
    if negative then
        result = sc:Scan()
    end
    local flags = sc:TokenFlags()
    -- validate that
    -- * scanning proceeded without error
    -- * a bigint can be scanned, and that when it is scanned, it is
    -- * the full length of the input string (so the scanner is one character beyond the augmented input length)
    -- * it does not contain a numeric separator (the `BigInt` constructor does not accept a numeric separator in its input)
    return success and result == Kind.BigIntLiteral and sc:TokenEnd() == #s + 1 and flags & ast.TokenFlags.ContainsSeparator == 0 and
        (not roundTripOnly or s == checker.pseudoBigIntToString(jsnum.NewPseudoBigInt(jsnum.ParsePseudoBigInt(sc:TokenValue()), negative)))
end

function checker.isValidESSymbolDeclaration(node)
    if ast.IsVariableDeclaration(node) then
        return ast.IsVarConst(node) and ast.IsIdentifier(node:AsVariableDeclaration():Name()) and checker.isVariableDeclarationInVariableStatement(node)
    end
    if ast.IsPropertyDeclaration(node) then
        return checker.hasReadonlyModifier(node) and ast.HasStaticModifier(node)
    end
    return ast.IsPropertySignatureDeclaration(node) and checker.hasReadonlyModifier(node)
end

function checker.isVariableDeclarationInVariableStatement(node)
    return ast.IsVariableDeclarationList(node.parent) and ast.IsVariableStatement(node.parent.parent)
end

function checker.IsKnownSymbol(symbol)
    return checker.isLateBoundName(symbol.name)
end

function checker.IsPrivateIdentifierSymbol(symbol)
    if symbol == nil then
        return false
    end
    local prefix = ast.InternalSymbolNamePrefix .. "#"
    return string.sub(symbol.name, 1, #prefix) == prefix
end

function checker.isLateBoundName(name)
    return #name >= 2 and string.byte(name, 1) == 0xFE and string.byte(name, 2) == 0x40 -- '@'
end

function checker.isObjectOrArrayLiteralType(t)
    return t.objectFlags & (ObjectFlags.ObjectLiteral | ObjectFlags.ArrayLiteral) ~= 0
end

function checker.getContainingClassExcludingClassDecorators(node)
    local decorator = ast.FindAncestorOrQuit(node.parent, function(n)
        if ast.IsClassLike(n) then
            return FindAncestorResult.FindAncestorQuit
        end
        if ast.IsDecorator(n) then
            return FindAncestorResult.FindAncestorTrue
        end
        return FindAncestorResult.FindAncestorFalse
    end)
    if decorator ~= nil and ast.IsClassLike(decorator.parent) then
        return ast.GetContainingClass(decorator.parent)
    end
    if decorator ~= nil then
        return ast.GetContainingClass(decorator)
    end
    return ast.GetContainingClass(node)
end

function checker.isThisTypeParameter(t)
    return t.flags & TypeFlags.TypeParameter ~= 0 and t:AsTypeParameter().isThisType
end

function checker.isClassInstanceProperty(node)
    if ast.IsInJSFile(node) and ast.IsExpandoPropertyDeclaration(node) then
        local left = node:AsBinaryExpression().left
        return (not ast.IsBindableStaticAccessExpression(left, false --[[excludeThisKeyword]]) or not ast.IsPrototypeAccess(left:Expression())) and
            not ast.IsBindableStaticNameExpression(left, true --[[excludeThisKeyword]])
    end
    return node.parent ~= nil and ast.IsClassLike(node.parent) and ast.IsPropertyDeclaration(node) and not ast.HasAccessorModifier(node)
end

function checker.isThisInitializedObjectBindingExpression(node)
    return node ~= nil and (ast.IsShorthandPropertyAssignment(node) or ast.IsPropertyAssignment(node)) and ast.IsBinaryExpression(node.parent.parent) and
        node.parent.parent:AsBinaryExpression().operatorToken.kind == Kind.EqualsToken and
        node.parent.parent:AsBinaryExpression().right.kind == Kind.ThisKeyword
end

function checker.isThisInitializedDeclaration(node)
    return node ~= nil and ast.IsVariableDeclaration(node) and node:Initializer() ~= nil and node:Initializer().kind == Kind.ThisKeyword
end

function checker.isInfinityOrNaNString(name)
    return name == "Infinity" or name == "-Infinity" or name == "NaN"
end

function Checker:isConstantVariable(symbol)
    return symbol.flags & SymbolFlags.Variable ~= 0 and (self:getDeclarationNodeFlagsFromSymbol(symbol) & NodeFlags.Constant) ~= 0
end

function Checker:isParameterOrMutableLocalVariable(symbol)
    -- Return true if symbol is a parameter, a catch clause variable, or a mutable local variable
    if symbol.valueDeclaration ~= nil then
        local declaration = ast.GetRootDeclaration(symbol.valueDeclaration)
        return declaration ~= nil and (ast.IsParameterDeclaration(declaration) or ast.IsVariableDeclaration(declaration) and (ast.IsCatchClause(declaration.parent) or self:isMutableLocalVariableDeclaration(declaration)))
    end
    return false
end

function Checker:isMutableLocalVariableDeclaration(declaration)
    -- Return true if symbol is a non-exported and non-global `let` variable
    return declaration.parent.flags & NodeFlags.Let ~= 0 and not (ast.GetCombinedModifierFlags(declaration) & ModifierFlags.Export ~= 0 or declaration.parent.parent.kind == Kind.VariableStatement and ast.IsGlobalSourceFile(declaration.parent.parent.parent))
end

function checker.isInAmbientOrTypeNode(node)
    return node.flags & NodeFlags.Ambient ~= 0 or ast.FindAncestor(node, function(n)
        return ast.IsInterfaceDeclaration(n) or ast.IsTypeOrJSTypeAliasDeclaration(n) or ast.IsTypeLiteralNode(n)
    end) ~= nil
end

function checker.isLiteralExpressionOfObject(node)
    local kind = node.kind
    return kind == Kind.ObjectLiteralExpression or kind == Kind.ArrayLiteralExpression or kind == Kind.RegularExpressionLiteral or
        kind == Kind.FunctionExpression or kind == Kind.ClassExpression
end

function checker.canHaveFlowNode(node)
    return node:FlowNodeData() ~= nil
end

function checker.isNonNullAccess(node)
    return ast.IsAccessExpression(node) and ast.IsNonNullExpression(node:Expression())
end

function checker.getBindingElementPropertyName(node)
    return node:PropertyNameOrName()
end

function checker.isCallChain(node)
    return ast.IsCallExpression(node) and node.flags & NodeFlags.OptionalChain ~= 0
end

function Checker:callLikeExpressionMayHaveTypeArguments(node)
    return ast.IsCallOrNewExpression(node) or ast.IsTaggedTemplateExpression(node) or ast.IsJsxOpeningLikeElement(node)
end

function checker.isSuperCall(n)
    return ast.IsCallExpression(n) and n:Expression().kind == Kind.SuperKeyword
end

function checker.getMembersOfDeclaration(node)
    local kind = node.kind
    if kind == Kind.InterfaceDeclaration or kind == Kind.ClassDeclaration or kind == Kind.ClassExpression or kind == Kind.TypeLiteral then
        return node:Members()
    elseif kind == Kind.ObjectLiteralExpression then
        return node:Properties()
    end
    return nil
end

function checker.isInRightSideOfImportOrExportAssignment(node)
    while node.parent.kind == Kind.QualifiedName do
        node = node.parent
    end

    return node.parent.kind == Kind.ImportEqualsDeclaration and node.parent:AsImportEqualsDeclaration().moduleReference == node or
        node.parent.kind == Kind.ExportAssignment and node.parent:Expression() == node
end

function checker.isJsxIntrinsicTagName(tagName)
    return ast.IsIdentifier(tagName) and scanner.IsIntrinsicJsxName(tagName:Text()) or ast.IsJsxNamespacedName(tagName)
end

function checker.getContainingObjectLiteral(f)
    if (f.kind == Kind.MethodDeclaration or
        f.kind == Kind.GetAccessor or
        f.kind == Kind.SetAccessor) and f.parent.kind == Kind.ObjectLiteralExpression then
        return f.parent
    elseif f.kind == Kind.FunctionExpression and f.parent.kind == Kind.PropertyAssignment then
        return f.parent.parent
    end
    return nil
end

function checker.isImportTypeQualifierPart(node)
    local parent = node.parent
    while ast.IsQualifiedName(parent) do
        node = parent
        parent = parent.parent
    end

    if parent ~= nil and parent.kind == Kind.ImportType and parent:AsImportTypeNode().qualifier == node then
        return parent
    end

    return nil
end

function checker.isInNameOfExpressionWithTypeArgumentsOrHeritageTypeReference(node)
    while node.parent.kind == Kind.PropertyAccessExpression or node.parent.kind == Kind.QualifiedName do
        node = node.parent
    end

    return node.parent.kind == Kind.ExpressionWithTypeArguments or
        ast.IsNameOfHeritageClauseTypeReference(node)
end

function checker.getIndexSymbolFromSymbolTable(symbolTable)
    if symbolTable == nil then
        return nil
    end
    return symbolTable[ast.InternalSymbolNameIndex]
end

-- Indicates whether the result of an `Expression` will be unused.
-- NOTE: This requires a node with a valid `parent` pointer.
function checker.expressionResultIsUnused(node)
    while true do
        local parent = node.parent
        -- walk up parenthesized expressions, but keep a pointer to the top-most parenthesized expression
        if ast.IsParenthesizedExpression(parent) then
            node = parent
            goto continue
        end
        -- result is unused in an expression statement, `void` expression, or the initializer or incrementer of a `for` loop
        if ast.IsExpressionStatement(parent) or ast.IsVoidExpression(parent) or ast.IsForStatement(parent) and (parent:Initializer() == node or parent:AsForStatement().incrementor == node) then
            return true
        end
        if ast.IsBinaryExpression(parent) and parent:AsBinaryExpression().operatorToken.kind == Kind.CommaToken then
            -- left side of comma is always unused
            if node == parent:AsBinaryExpression().left then
                return true
            end
            -- right side of comma is unused if parent is unused
            node = parent
            goto continue
        end
        do
            return false
        end
        ::continue::
    end
end

function checker.pseudoBigIntToString(value)
    return value:String()
end

function checker.getSuperContainer(node, stopOnFunctions)
    while true do
        node = node.parent
        if node == nil then
            return nil
        end
        local kind = node.kind
        if kind == Kind.ComputedPropertyName then
            node = node.parent
        elseif kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression or kind == Kind.ArrowFunction then
            if stopOnFunctions then
                return node
            end
        elseif kind == Kind.PropertyDeclaration or kind == Kind.PropertySignature or kind == Kind.MethodDeclaration or kind == Kind.MethodSignature or kind == Kind.Constructor or
            kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.ClassStaticBlockDeclaration then
            return node
        elseif kind == Kind.Decorator then
            -- Decorators are always applied outside of the body of a class or method.
            if ast.IsParameterDeclaration(node.parent) and ast.IsClassElement(node.parent.parent) then
                -- If the decorator's parent is a Parameter, we resolve the this container from
                -- the grandparent class declaration.
                node = node.parent.parent
            elseif ast.IsClassElement(node.parent) then
                -- If the decorator's parent is a class element, we resolve the 'this' container
                -- from the parent class declaration.
                node = node.parent
            end
        end
    end
end

function checker.forEachYieldExpression(body, visitor)
    local traverse
    traverse = function(node)
        local kind = node.kind
        if kind == Kind.YieldExpression then
            if visitor(node) then
                return true
            end
            local operand = node:Expression()
            if operand == nil then
                return false
            end
            return traverse(operand)
        elseif kind == Kind.EnumDeclaration or kind == Kind.InterfaceDeclaration or kind == Kind.ModuleDeclaration or kind == Kind.TypeAliasDeclaration then
            -- These are not allowed inside a generator now, but eventually they may be allowed
            -- as local types. Regardless, skip them to avoid the work.
        else
            if ast.IsFunctionLike(node) then
                if node:Name() ~= nil and ast.IsComputedPropertyName(node:Name()) then
                    -- Note that we will not include methods/accessors of a class because they would require
                    -- first descending into the class. This is by design.
                    return traverse(node:Name():Expression())
                end
            elseif not ast.IsPartOfTypeNode(node) then
                -- This is the general case, which should include mostly expressions and statements.
                -- Also includes NodeArrays.
                return node:ForEachChild(traverse)
            end
        end
        return false
    end
    return traverse(body)
end

function checker.getEnclosingContainer(node)
    return ast.FindAncestor(node.parent, function(n)
        return binder.GetContainerFlags(n) & binder.ContainerFlags.IsContainer ~= 0
    end)
end

function checker.getDeclarationsOfKind(symbol, kind)
    return core.Filter(symbol.declarations, function(d)
        return d.kind == kind
    end)
end

function checker.hasType(node)
    return node:Type() ~= nil
end

function checker.getNonRestParameterCount(sig)
    return core.Len(sig.parameters) - core.IfElse(checker.signatureHasRestParameter(sig), 1, 0)
end

-- Returns minValue, maxValue.
function checker.minAndMax(slice, getValue)
    local minValue, maxValue = 0, 0
    for i, element in ipairs(slice or {}) do
        local value = getValue(element)
        if i == 1 then
            minValue = value
            maxValue = value
        else
            minValue = math.min(minValue, value)
            maxValue = math.max(maxValue, value)
        end
    end
    return minValue, maxValue
end

-- FeatureMapEntry{lib string, props []string}
checker.defineStruct("FeatureMapEntry", nil, { lib = "" })

local function featureMapEntry(lib, props)
    return checker.FeatureMapEntry_new({ lib = lib, props = props })
end

local typedArrayFeatures = function()
    return {
        featureMapEntry("es2022", { "at" }),
        featureMapEntry("es2023", { "findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with" }),
    }
end

local bigIntTypedArrayFeatures = function()
    return {
        featureMapEntry("es2020", {}),
        featureMapEntry("es2022", { "at" }),
        featureMapEntry("es2023", { "findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with" }),
    }
end

local featureMap

function checker.getFeatureMap()
    if featureMap ~= nil then
        return featureMap
    end
    featureMap = {
        ["Array"] = {
            featureMapEntry("es2015", { "find", "findIndex", "fill", "copyWithin", "entries", "keys", "values" }),
            featureMapEntry("es2016", { "includes" }),
            featureMapEntry("es2019", { "flat", "flatMap" }),
            featureMapEntry("es2022", { "at" }),
            featureMapEntry("es2023", { "findLastIndex", "findLast", "toReversed", "toSorted", "toSpliced", "with" }),
        },
        ["Iterator"] = {
            featureMapEntry("es2015", {}),
        },
        ["AsyncIterator"] = {
            featureMapEntry("es2015", {}),
        },
        ["ArrayBuffer"] = {
            featureMapEntry("es2024", {
                "maxByteLength",
                "resizable",
                "resize",
                "detached",
                "transfer",
                "transferToFixedLength",
            }),
        },
        ["Atomics"] = {
            featureMapEntry("es2017", {
                "add",
                "and",
                "compareExchange",
                "exchange",
                "isLockFree",
                "load",
                "or",
                "store",
                "sub",
                "wait",
                "notify",
                "xor",
            }),
            featureMapEntry("es2024", {
                "waitAsync",
            }),
        },
        ["SharedArrayBuffer"] = {
            featureMapEntry("es2017", {
                "byteLength",
                "slice",
            }),
            featureMapEntry("es2024", {
                "growable",
                "maxByteLength",
                "grow",
            }),
        },
        ["AsyncIterable"] = {
            featureMapEntry("es2018", {}),
        },
        ["AsyncIterableIterator"] = {
            featureMapEntry("es2018", {}),
        },
        ["AsyncGenerator"] = {
            featureMapEntry("es2018", {}),
        },
        ["AsyncGeneratorFunction"] = {
            featureMapEntry("es2018", {}),
        },
        ["RegExp"] = {
            featureMapEntry("es2015", { "flags", "sticky", "unicode" }),
            featureMapEntry("es2018", { "dotAll" }),
            featureMapEntry("es2024", { "unicodeSets" }),
        },
        ["RegExpConstructor"] = {
            featureMapEntry("es2025", { "escape" }),
        },
        ["Reflect"] = {
            featureMapEntry("es2015", { "apply", "construct", "defineProperty", "deleteProperty", "get", "getOwnPropertyDescriptor", "getPrototypeOf", "has", "isExtensible", "ownKeys", "preventExtensions", "set", "setPrototypeOf" }),
        },
        ["ArrayConstructor"] = {
            featureMapEntry("es2015", { "from", "of" }),
            featureMapEntry("esnext", { "fromAsync" }),
        },
        ["ObjectConstructor"] = {
            featureMapEntry("es2015", { "assign", "getOwnPropertySymbols", "keys", "is", "setPrototypeOf" }),
            featureMapEntry("es2017", { "values", "entries", "getOwnPropertyDescriptors" }),
            featureMapEntry("es2019", { "fromEntries" }),
            featureMapEntry("es2022", { "hasOwn" }),
            featureMapEntry("es2024", { "groupBy" }),
        },
        ["NumberConstructor"] = {
            featureMapEntry("es2015", { "isFinite", "isInteger", "isNaN", "isSafeInteger", "parseFloat", "parseInt" }),
        },
        ["Math"] = {
            featureMapEntry("es2015", { "clz32", "imul", "sign", "log10", "log2", "log1p", "expm1", "cosh", "sinh", "tanh", "acosh", "asinh", "atanh", "hypot", "trunc", "fround", "cbrt" }),
            featureMapEntry("es2025", { "f16round" }),
        },
        ["Map"] = {
            featureMapEntry("es2015", { "entries", "keys", "values" }),
            featureMapEntry("esnext", {
                "getOrInsert",
                "getOrInsertComputed",
            }),
        },
        ["MapConstructor"] = {
            featureMapEntry("es2024", { "groupBy" }),
        },
        ["Set"] = {
            featureMapEntry("es2015", { "entries", "keys", "values" }),
            featureMapEntry("es2025", {
                "union",
                "intersection",
                "difference",
                "symmetricDifference",
                "isSubsetOf",
                "isSupersetOf",
                "isDisjointFrom",
            }),
        },
        ["PromiseConstructor"] = {
            featureMapEntry("es2015", { "all", "race", "reject", "resolve" }),
            featureMapEntry("es2020", { "allSettled" }),
            featureMapEntry("es2021", { "any" }),
            featureMapEntry("es2024", { "withResolvers" }),
            featureMapEntry("es2025", { "try" }),
        },
        ["Symbol"] = {
            featureMapEntry("es2015", { "for", "keyFor" }),
            featureMapEntry("es2019", { "description" }),
        },
        ["WeakMap"] = {
            featureMapEntry("es2015", {}),
            featureMapEntry("esnext", {
                "getOrInsert",
                "getOrInsertComputed",
            }),
        },
        ["WeakSet"] = {
            featureMapEntry("es2015", {}),
        },
        ["String"] = {
            featureMapEntry("es2015", { "codePointAt", "includes", "endsWith", "normalize", "repeat", "startsWith", "anchor", "big", "blink", "bold", "fixed", "fontcolor", "fontsize", "italics", "link", "small", "strike", "sub", "sup" }),
            featureMapEntry("es2017", { "padStart", "padEnd" }),
            featureMapEntry("es2019", { "trimStart", "trimEnd", "trimLeft", "trimRight" }),
            featureMapEntry("es2020", { "matchAll" }),
            featureMapEntry("es2021", { "replaceAll" }),
            featureMapEntry("es2022", { "at" }),
            featureMapEntry("es2024", { "isWellFormed", "toWellFormed" }),
        },
        ["StringConstructor"] = {
            featureMapEntry("es2015", { "fromCodePoint", "raw" }),
        },
        ["DateTimeFormat"] = {
            featureMapEntry("es2017", { "formatToParts" }),
        },
        ["Promise"] = {
            featureMapEntry("es2015", {}),
            featureMapEntry("es2018", { "finally" }),
        },
        ["RegExpMatchArray"] = {
            featureMapEntry("es2018", { "groups" }),
        },
        ["RegExpExecArray"] = {
            featureMapEntry("es2018", { "groups" }),
        },
        ["Intl"] = {
            featureMapEntry("es2018", { "PluralRules" }),
            featureMapEntry("es2020", { "RelativeTimeFormat", "Locale", "DisplayNames" }),
            featureMapEntry("es2021", { "ListFormat", "DateTimeFormat" }),
            featureMapEntry("es2022", { "Segmenter" }),
            featureMapEntry("es2025", { "DurationFormat" }),
        },
        ["NumberFormat"] = {
            featureMapEntry("es2018", { "formatToParts" }),
        },
        ["SymbolConstructor"] = {
            featureMapEntry("es2020", { "matchAll" }),
            featureMapEntry("esnext", {
                "metadata",
                "dispose",
                "asyncDispose",
            }),
        },
        ["DataView"] = {
            featureMapEntry("es2020", { "setBigInt64", "setBigUint64", "getBigInt64", "getBigUint64" }),
            featureMapEntry("es2025", { "setFloat16", "getFloat16" }),
        },
        ["BigInt"] = {
            featureMapEntry("es2020", {}),
        },
        ["RelativeTimeFormat"] = {
            featureMapEntry("es2020", { "format", "formatToParts", "resolvedOptions" }),
        },
        ["Int8Array"] = typedArrayFeatures(),
        ["Uint8Array"] = typedArrayFeatures(),
        ["Uint8ClampedArray"] = typedArrayFeatures(),
        ["Int16Array"] = typedArrayFeatures(),
        ["Uint16Array"] = typedArrayFeatures(),
        ["Int32Array"] = typedArrayFeatures(),
        ["Uint32Array"] = typedArrayFeatures(),
        ["Float16Array"] = {
            featureMapEntry("es2025", {}),
        },
        ["Float32Array"] = typedArrayFeatures(),
        ["Float64Array"] = typedArrayFeatures(),
        ["BigInt64Array"] = bigIntTypedArrayFeatures(),
        ["BigUint64Array"] = bigIntTypedArrayFeatures(),
        ["Error"] = {
            featureMapEntry("es2022", { "cause" }),
        },
        ["ErrorConstructor"] = {
            featureMapEntry("esnext", { "isError" }),
        },
        ["Uint8ArrayConstructor"] = {
            featureMapEntry("esnext", { "fromBase64", "fromHex" }),
        },
        ["DisposableStack"] = {
            featureMapEntry("esnext", {}),
        },
        ["AsyncDisposableStack"] = {
            featureMapEntry("esnext", {}),
        },
        ["Date"] = {
            featureMapEntry("esnext", { "toTemporalInstant" }),
        },
    }
    return featureMap
end

function checker.rangeOfTypeParameters(sourceFile, typeParameters)
    return core.NewTextRange(typeParameters:Pos() - 1, math.min(#sourceFile:Text(), scanner.SkipTrivia(sourceFile:Text(), typeParameters:End()) + 1))
end

function checker.tryGetPropertyAccessOrIdentifierToString(expr)
    if ast.IsPropertyAccessExpression(expr) then
        local baseStr = checker.tryGetPropertyAccessOrIdentifierToString(expr:Expression())
        if baseStr ~= "" then
            return baseStr .. "." .. checker.entityNameToString(expr:Name())
        end
    elseif ast.IsElementAccessExpression(expr) then
        local baseStr = checker.tryGetPropertyAccessOrIdentifierToString(expr:Expression())
        if baseStr ~= "" and ast.IsPropertyName(expr:AsElementAccessExpression().argumentExpression) then
            return baseStr .. "." .. ast.GetPropertyNameForPropertyNameNode(expr:AsElementAccessExpression().argumentExpression)
        end
    elseif ast.IsIdentifier(expr) then
        return expr:Text()
    elseif ast.IsJsxNamespacedName(expr) then
        return checker.entityNameToString(expr)
    end
    return ""
end

function checker.allDeclarationsInSameSourceFile(symbol)
    if core.Len(symbol.declarations) > 1 then
        local sourceFile
        for i, d in ipairs(symbol.declarations) do
            if i == 1 then
                sourceFile = ast.GetSourceFileOfNode(d)
            elseif ast.GetSourceFileOfNode(d) ~= sourceFile then
                return false
            end
        end
    end
    return true
end

function checker.containsNonMissingUndefinedType(c, t)
    local candidate
    if t.flags & TypeFlags.Union ~= 0 then
        candidate = t:AsUnionType().types[1]
    else
        candidate = t
    end
    return candidate.flags & TypeFlags.Undefined ~= 0 and candidate ~= c.missingType
end

function checker.getAnyImportSyntax(node)
    local importNode
    local kind = node.kind
    if kind == Kind.ImportEqualsDeclaration then
        importNode = node
    elseif kind == Kind.ImportClause then
        importNode = node.parent
    elseif kind == Kind.NamespaceImport then
        importNode = node.parent.parent
    elseif kind == Kind.ImportSpecifier then
        importNode = node.parent.parent.parent
    else
        return nil
    end
    return importNode
end

-- A reserved member name consists of the byte 0xFE (which is an invalid UTF-8 encoding) followed by one or more
-- characters where the first character is not '@' or '#'. The '@' character indicates that the name is denoted by
-- a well known ES Symbol instance and the '#' character indicates that the name is a PrivateIdentifier.
function checker.isReservedMemberName(name)
    if #name < 2 or string.byte(name, 1) ~= 0xFE then
        return false
    end
    local second = string.byte(name, 2)
    return second ~= 0x40 and second ~= 0x23 -- '@', '#'
end

function checker.introducesArgumentsExoticObject(node)
    local kind = node.kind
    return kind == Kind.MethodDeclaration or kind == Kind.MethodSignature or kind == Kind.Constructor or kind == Kind.GetAccessor or
        kind == Kind.SetAccessor or kind == Kind.FunctionDeclaration or kind == Kind.FunctionExpression
end

function checker.symbolsToArray(symbols)
    local result
    if symbols ~= nil then
        for id, symbol in pairs(symbols) do
            if not checker.isReservedMemberName(id) then
                result = core.Append(result, symbol)
            end
        end
    end
    return result
end

function checker.SkipAlias(symbol, c)
    if symbol.flags & SymbolFlags.Alias ~= 0 then
        return c:GetAliasedSymbol(symbol)
    end
    return symbol
end

-- True if the symbol is for an external module, as opposed to a namespace.
function checker.IsExternalModuleSymbol(moduleSymbol)
    -- '"' is ASCII, so comparing the first byte is equivalent to comparing the first rune.
    return moduleSymbol.flags & SymbolFlags.Module ~= 0 and string.byte(moduleSymbol.name, 1) == 0x22
end

function Checker:isCanceled()
    return self.ctx ~= nil and self.ctx.Err ~= nil and self.ctx:Err() ~= nil
end

function Checker:checkNotCanceled()
    if self.wasCanceled then
        error("Checker was previously cancelled", 0)
    end
end

function Checker:getPackagesMap()
    if self.packagesMap == nil then
        self.packagesMap = {}
        local resolvedModules = self.program:GetResolvedModules()
        for _, resolvedModulesInFile in pairs(resolvedModules or {}) do
            for _, resolvedModule in pairs(resolvedModulesInFile) do
                if resolvedModule.packageId.name ~= "" then
                    self.packagesMap[resolvedModule.packageId.name] = self.packagesMap[resolvedModule.packageId.name] == true or resolvedModule.extension == tspath.ExtensionDts
                end
            end
        end
    end
    return self.packagesMap
end

function Checker:typesPackageExists(packageName)
    local packagesMap = self:getPackagesMap()
    return packagesMap[module.GetTypesPackageName(packageName)] ~= nil
end

function Checker:packageBundlesTypes(packageName)
    local packagesMap = self:getPackagesMap()
    return packagesMap[packageName] == true
end

function checker.ValueToString(value)
    local tv = type(value)
    if tv == "string" then
        return "\"" .. printer.EscapeString(value, printer.QuoteChar.DoubleQuote) .. "\""
    elseif tv == "number" then
        return jsnum.Number_String(value)
    elseif tv == "boolean" then
        return core.IfElse(value, "true", "false")
    elseif tv == "table" and getmetatable(value) == jsnum.PseudoBigInt then
        return value:String() .. "n"
    end
    error("unhandled value type in valueToString", 0)
end

function checker.nodeStartsNewLexicalEnvironment(node)
    local kind = node.kind
    return kind == Kind.Constructor or kind == Kind.FunctionExpression or kind == Kind.FunctionDeclaration or kind == Kind.ArrowFunction or
        kind == Kind.MethodDeclaration or kind == Kind.GetAccessor or kind == Kind.SetAccessor or kind == Kind.ModuleDeclaration or kind == Kind.SourceFile
end

-- Determines whether a did-you-mean error should be a suggestion in an unchecked JS file.
-- Only applies to unchecked JS files without checkJS, // @ts-check or // @ts-nocheck
-- It does not suggest when the suggestion:
-- - Is from a global file that is different from the reference file, or
-- - (optionally) Is a class, or is a this.x property access expression
function Checker:isUncheckedJSSuggestion(node, suggestion, excludeClasses)
    local file = ast.GetSourceFileOfNode(node)
    if file ~= nil then
        if core.Tristate_IsUnknown(self.compilerOptions.checkJs) and file.checkJsDirective == nil and (file.scriptKind == core.ScriptKind.JS or file.scriptKind == core.ScriptKind.JSX) then
            local declarationFile
            if suggestion ~= nil then
                local firstDeclaration = core.FirstOrNil(suggestion.declarations)
                if firstDeclaration ~= nil then
                    declarationFile = ast.GetSourceFileOfNode(firstDeclaration)
                end
            end
            local suggestionHasNoExtendsOrDecorators = suggestion == nil or
                suggestion.valueDeclaration == nil or
                not ast.IsClassLike(suggestion.valueDeclaration) or
                core.Len(ast.GetExtendsHeritageClauseElements(suggestion.valueDeclaration)) ~= 0 or
                ast.ClassOrConstructorParameterIsDecorated(false, suggestion.valueDeclaration)
            return not (file ~= declarationFile and declarationFile ~= nil and ast.IsGlobalSourceFile(declarationFile)) and
                not (excludeClasses and suggestion ~= nil and suggestion.flags & SymbolFlags.Class ~= 0 and suggestionHasNoExtendsOrDecorators) and
                not (node ~= nil and excludeClasses and ast.IsPropertyAccessExpression(node) and node:Expression().kind == Kind.ThisKeyword and suggestionHasNoExtendsOrDecorators)
        end
    end
    return false
end

-- Returns if a type is or consists of a JSLiteral object type
-- In addition to objects which are directly literals,
-- * unions where every element is a jsliteral
-- * intersections where at least one element is a jsliteral
-- * and instantiable types constrained to a jsliteral
-- Should all count as literals and not print errors on access or assignment of possibly existing properties.
-- This mirrors the behavior of the index signature propagation, to which this behaves similarly (but doesn't affect assignability or inference).
function Checker:isJSLiteralType(t)
    if self.noImplicitAny then
        return false
        -- Flag is meaningless under `noImplicitAny` mode
    end
    if t.objectFlags & ObjectFlags.JSLiteral ~= 0 then
        return true
    end
    if t.flags & TypeFlags.Union ~= 0 then
        return core.Every(t:AsUnionType().types, function(u)
            return self:isJSLiteralType(u)
        end)
    end
    if t.flags & TypeFlags.Intersection ~= 0 then
        return core.Some(t:AsIntersectionType().types, function(u)
            return self:isJSLiteralType(u)
        end)
    end
    if t.flags & TypeFlags.Instantiable ~= 0 then
        local constraint = self:getResolvedBaseConstraint(t, nil)
        return constraint ~= t and self:isJSLiteralType(constraint)
    end
    return false
end

-- DiagnosticDetails holds a resolved diagnostic message and its arguments,
-- used for sharing diagnostic chain computation between the checker and incremental builder.
-- Fields: message (*diagnostics.Message), args (array or nil).
checker.defineStruct("DiagnosticDetails", nil, nil)

-- CreateModuleNotFoundChain computes the diagnostic message and arguments for a module-not-found
-- error chain entry. This is shared between the checker (initial diagnostic creation) and the
-- incremental builder (repopulation of cached diagnostics).
-- Mirrors createModuleNotFoundChain in the TypeScript compiler's utilities.ts.
function checker.CreateModuleNotFoundChain(program, file, moduleReference, mode, packageName)
    local resolvedModule = program:GetResolvedModule(file, moduleReference, mode)

    if resolvedModule ~= nil and resolvedModule.alternateResult ~= "" then
        if string.find(resolvedModule.alternateResult, "/node_modules/@types/", 1, true) ~= nil then
            packageName = "@types/" .. module.MangleScopedPackageName(packageName)
        end
        return checker.DiagnosticDetails_new({
            message = diagnostics.There_are_types_at_0_but_this_result_could_not_be_resolved_when_respecting_package_json_exports_The_1_library_may_need_to_update_its_package_json_or_typings,
            args = { resolvedModule.alternateResult, packageName },
        })
    end

    local packagesMap = program:GetPackagesMap()
    if packagesMap[module.GetTypesPackageName(packageName)] ~= nil then
        return checker.DiagnosticDetails_new({
            message = diagnostics.If_the_0_package_actually_exposes_this_module_consider_sending_a_pull_request_to_amend_https_Colon_Slash_Slashgithub_com_SlashDefinitelyTyped_SlashDefinitelyTyped_Slashtree_Slashmaster_Slashtypes_Slash_1,
            args = { packageName, module.MangleScopedPackageName(packageName) },
        })
    end
    if packagesMap[packageName] then
        return checker.DiagnosticDetails_new({
            message = diagnostics.If_the_0_package_actually_exposes_this_module_try_adding_a_new_declaration_d_ts_file_containing_declare_module_1,
            args = { packageName, moduleReference },
        })
    end
    return checker.DiagnosticDetails_new({
        message = diagnostics.Try_npm_i_save_dev_types_Slash_1_if_it_exists_or_add_a_new_declaration_d_ts_file_containing_declare_module_0,
        args = { moduleReference, module.MangleScopedPackageName(packageName) },
    })
end

-- CreateModeMismatchDetails computes the diagnostic message and arguments for a mode-mismatch
-- error chain entry. This is shared between the checker (initial diagnostic creation) and the
-- incremental builder (repopulation of cached diagnostics).
-- Mirrors createModeMismatchDetails in the TypeScript compiler's utilities.ts.
function checker.CreateModeMismatchDetails(program, file)
    local ext = tspath.TryGetExtensionFromPath(file:FileName())
    local targetExt = core.IfElse(ext == tspath.ExtensionTs, tspath.ExtensionMts, core.IfElse(ext == tspath.ExtensionJs, tspath.ExtensionMjs, ""))
    local meta = program:GetSourceFileMetaData(file:Path())
    local packageJsonType = meta.packageJsonType
    local packageJsonDirectory = meta.packageJsonDirectory

    if packageJsonDirectory ~= "" and packageJsonType == "" then
        if targetExt ~= "" then
            return checker.DiagnosticDetails_new({
                message = diagnostics.To_convert_this_file_to_an_ECMAScript_module_change_its_file_extension_to_0_or_add_the_field_type_Colon_module_to_1,
                args = { targetExt, tspath.CombinePaths(packageJsonDirectory, "package.json") },
            })
        end
        return checker.DiagnosticDetails_new({
            message = diagnostics.To_convert_this_file_to_an_ECMAScript_module_add_the_field_type_Colon_module_to_0,
            args = { tspath.CombinePaths(packageJsonDirectory, "package.json") },
        })
    end
    if targetExt ~= "" then
        return checker.DiagnosticDetails_new({
            message = diagnostics.To_convert_this_file_to_an_ECMAScript_module_change_its_file_extension_to_0_or_create_a_local_package_json_file_with_type_Colon_module,
            args = { targetExt },
        })
    end
    return checker.DiagnosticDetails_new({
        message = diagnostics.To_convert_this_file_to_an_ECMAScript_module_create_a_local_package_json_file_with_type_Colon_module,
        args = nil,
    })
end

function checker.walkUpOuterExpressions(node)
    local parent = node.parent
    while parent ~= nil and ast.IsOuterExpression(parent, ast.OuterExpressionKinds.OEKAll) do
        parent = parent.parent
    end
    return parent
end

function checker.GetSetAccessorValueParameter(accessor)
    local parameters = accessor:Parameters()
    if #parameters > 0 then
        local hasThis = #parameters == 2 and ast.IsThisParameter(parameters[1])
        return parameters[core.IfElse(hasThis, 1, 0) + 1]
    end
    return nil
end
