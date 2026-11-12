local ls = require("tslua.ls")
local ast = require("tslua.ast")
local checker = require("tslua.checker")
local core = require("tslua.core")
local debug = require("tslua.debug")

local Kind = ast.Kind
local SymbolFlags = ast.SymbolFlags
local ModifierFlags = ast.ModifierFlags
local JSDeclarationKind = ast.JSDeclarationKind
local ImpExpKind = ls.ImpExpKind
local ExportKind = ls.ExportKind
local ModuleReferenceKind = ls.ModuleReferenceKind

local function ctxErr(ctx)
    return ctx ~= nil and ctx.Err ~= nil and ctx:Err() ~= nil
end

-- ImportExportSymbol: { kind, symbol, exportInfo }
-- ExportInfo: { exportingModuleSymbol, exportKind }
-- LocationAndSymbol: { importLocation, importSymbol }
-- ImportsResult: { importSearches, singleReferences, indirectUsers }
-- ImportTracker: function(exportSymbol, exportInfo, isForRename) -> ImportsResult
-- ModuleReference: { kind, literal, referencingFile, ref }

-- Creates the imports map and returns an ImportTracker that uses it. Call this lazily to avoid calling `getDirectImportsMap` unnecessarily.
function ls.createImportTracker(ctx, program, sourceFiles, sourceFilesSet, c)
    local allDirectImports = ls.getDirectImportsMap(ctx, program, sourceFiles, c)
    return function(exportSymbol, exportInfo, isForRename)
        local directImports, indirectUsers = ls.getImportersForExport(sourceFiles, sourceFilesSet, allDirectImports, exportInfo, c)
        local importSearches, singleReferences = ls.getSearchesFromDirectImports(directImports, exportSymbol, exportInfo.exportKind, c, isForRename)
        return { importSearches = importSearches, singleReferences = singleReferences, indirectUsers = indirectUsers }
    end
end

-- Returns a map from a module symbol to all import statements that directly reference the module
function ls.getDirectImportsMap(ctx, program, sourceFiles, c)
    local result = {}
    for _, sourceFile in ipairs(sourceFiles or {}) do
        if ctxErr(ctx) then
            return result
        end
        ls.forEachImport(program, sourceFile, function(importDecl, moduleSpecifier)
            local moduleSymbol = c:GetSymbolAtLocation(moduleSpecifier)
            if moduleSymbol ~= nil then
                local list = result[moduleSymbol]
                if list == nil then
                    list = {}
                    result[moduleSymbol] = list
                end
                list[#list + 1] = importDecl
            end
        end)
    end
    return result
end

-- Calls `action` for each import, re-export, or require() in a file
function ls.forEachImport(program, sourceFile, action)
    local implicitImports = nil
    local _, jsxSpecifier = program:GetJSXRuntimeImportSpecifier(sourceFile:Path())
    if jsxSpecifier ~= nil then
        implicitImports = core.Append(implicitImports, jsxSpecifier)
    end
    local importHelpersSpecifier = program:GetImportHelpersImportSpecifier(sourceFile:Path())
    if importHelpersSpecifier ~= nil then
        implicitImports = core.Append(implicitImports, importHelpersSpecifier)
    end
    if sourceFile.externalModuleIndicator ~= nil or core.Len(sourceFile:Imports()) + core.Len(implicitImports) ~= 0 then
        for _, i in ipairs(sourceFile:Imports() or {}) do
            action(ast.ImportFromModuleSpecifier(i), i)
        end
        for _, i in ipairs(implicitImports or {}) do
            action(ast.ImportFromModuleSpecifier(i), i)
        end
    else
        ls.forEachPossibleImportOrExportStatement(sourceFile:AsNode(), function(node)
            if node.kind == Kind.ExportDeclaration or node.kind == Kind.ImportDeclaration or node.kind == Kind.JSImportDeclaration then
                local specifier = node:ModuleSpecifier()
                if specifier ~= nil and ast.IsStringLiteral(specifier) then
                    action(node, specifier)
                end
            elseif node.kind == Kind.ImportEqualsDeclaration then
                if ls.isExternalModuleImportEquals(node) then
                    action(node, node:AsImportEqualsDeclaration().moduleReference:Expression())
                end
            end
            return false
        end)
    end
end

function ls.forEachPossibleImportOrExportStatement(sourceFileLike, action)
    for _, statement in ipairs(ls.getStatementsOfSourceFileLike(sourceFileLike) or {}) do
        if action(statement) or ls.isAmbientModuleDeclaration(statement) and ls.forEachPossibleImportOrExportStatement(statement, action) then
            return true
        end
    end
    return false
end

function ls.getSourceFileLikeForImportDeclaration(node)
    if ast.IsCallExpression(node) or ast.IsJSDocImportTag(node) then
        return ast.GetSourceFileOfNode(node):AsNode()
    end
    local parent = node.parent
    if ast.IsSourceFile(parent) then
        return parent
    end
    debug.Assert(ast.IsModuleBlock(parent) and ls.isAmbientModuleDeclaration(parent.parent))
    return parent.parent
end

function ls.isAmbientModuleDeclaration(node)
    return ast.IsModuleDeclaration(node) and ast.IsStringLiteral(node:Name())
end

function ls.getStatementsOfSourceFileLike(node)
    if ast.IsSourceFile(node) then
        return node:Statements()
    end
    local body = node:Body()
    if body ~= nil then
        return body:Statements()
    end
    return nil
end

function ls.getImportersForExport(sourceFiles, sourceFilesSet, allDirectImports, exportInfo, c)
    local directImports = nil
    local indirectUserDeclarations = nil
    local markSeenDirectImport = ls.nodeSeenTracker()
    local markSeenIndirectUser = ls.nodeSeenTracker()
    local isAvailableThroughGlobal = ls.isSourceFileWithGlobalExports(exportInfo.exportingModuleSymbol.valueDeclaration)

    local function getDirectImports(moduleSymbol)
        return allDirectImports[moduleSymbol]
    end

    -- Adds a module and all of its transitive dependencies as possible indirect users
    local addIndirectUser
    addIndirectUser = function(sourceFileLike, addTransitiveDependencies)
        -- When isAvailableThroughGlobal, getIndirectUsers already returns all source files,
        -- so indirectUserDeclarations is never consulted. Nothing to do here.
        if isAvailableThroughGlobal then
            return
        end
        if not markSeenIndirectUser(sourceFileLike) then
            return
        end
        indirectUserDeclarations = core.Append(indirectUserDeclarations, sourceFileLike)
        if not addTransitiveDependencies then
            return
        end
        local moduleSymbol = c:GetMergedSymbol(sourceFileLike:Symbol())
        if moduleSymbol == nil then
            return
        end
        debug.Assert(moduleSymbol.flags & SymbolFlags.Module ~= 0)
        for _, directImport in ipairs(getDirectImports(moduleSymbol) or {}) do
            if not ast.IsImportTypeNode(directImport) then
                addIndirectUser(ls.getSourceFileLikeForImportDeclaration(directImport), true --[[addTransitiveDependencies]])
            end
        end
    end

    local function isExported(node, stopAtAmbientModule)
        while node ~= nil and not (stopAtAmbientModule and ls.isAmbientModuleDeclaration(node)) do
            if ast.HasSyntacticModifier(node, ModifierFlags.Export) then
                return true
            end
            node = node.parent
        end
        return false
    end

    local function handleImportCall(importCall)
        local top = ast.FindAncestor(importCall, ls.isAmbientModuleDeclaration)
        if top == nil then
            top = ast.GetSourceFileOfNode(importCall):AsNode()
        end
        addIndirectUser(top, isExported(importCall, true --[[stopAtAmbientModule]]))
    end

    local function handleNamespaceImport(importDeclaration, name, isReExport, alreadyAddedDirect)
        if exportInfo.exportKind == ExportKind.ExportEquals then
            -- This is a direct import, not import-as-namespace.
            if not alreadyAddedDirect then
                directImports = core.Append(directImports, importDeclaration)
            end
        elseif not isAvailableThroughGlobal then
            local sourceFileLike = ls.getSourceFileLikeForImportDeclaration(importDeclaration)
            debug.Assert(ast.IsSourceFile(sourceFileLike) or ast.IsModuleDeclaration(sourceFileLike))
            addIndirectUser(sourceFileLike, isReExport or ls.findNamespaceReExports(sourceFileLike, name, c))
        end
    end

    local handleDirectImports
    handleDirectImports = function(exportingModuleSymbol)
        local theseDirectImports = getDirectImports(exportingModuleSymbol)
        for _, direct in ipairs(theseDirectImports or {}) do
            if not markSeenDirectImport(direct) then
                goto continue
            end
            -- !!! cancellation
            if direct.kind == Kind.CallExpression then
                if ast.IsImportCall(direct) then
                    handleImportCall(direct)
                elseif not isAvailableThroughGlobal then
                    local parent = direct.parent
                    if exportInfo.exportKind == ExportKind.ExportEquals and ast.IsVariableDeclaration(parent) then
                        local name = parent:Name()
                        if ast.IsIdentifier(name) then
                            directImports = core.Append(directImports, name)
                        end
                    end
                end
            elseif direct.kind == Kind.Identifier then
                -- Nothing
            elseif direct.kind == Kind.ImportEqualsDeclaration then
                handleNamespaceImport(direct, direct:Name(), ast.HasSyntacticModifier(direct, ModifierFlags.Export), false --[[alreadyAddedDirect]])
            elseif direct.kind == Kind.ImportDeclaration or direct.kind == Kind.JSImportDeclaration or direct.kind == Kind.JSDocImportTag then
                directImports = core.Append(directImports, direct)
                local importClause = direct:ImportClause()
                if importClause ~= nil then
                    local namedBindings = importClause:AsImportClause().namedBindings
                    if namedBindings ~= nil and ast.IsNamespaceImport(namedBindings) then
                        handleNamespaceImport(direct, namedBindings:Name(), false --[[isReExport]], true --[[alreadyAddedDirect]])
                        goto continue
                    end
                end
                if not isAvailableThroughGlobal and ast.IsDefaultImport(direct) then
                    addIndirectUser(ls.getSourceFileLikeForImportDeclaration(direct), false)
                    -- Add a check for indirect uses to handle synthetic default imports
                end
            elseif direct.kind == Kind.ExportDeclaration then
                local exportClause = direct:AsExportDeclaration().exportClause
                if exportClause == nil then
                    -- This is `export * from "foo"`, so imports of this module may import the export too.
                    handleDirectImports(ls.getContainingModuleSymbol(direct, c))
                elseif ast.IsNamespaceExport(exportClause) then
                    -- `export * as foo from "foo"` add to indirect uses
                    addIndirectUser(ls.getSourceFileLikeForImportDeclaration(direct), true --[[addTransitiveDependencies]])
                else
                    -- This is `export { foo } from "foo"` and creates an alias symbol, so recursive search will get handle re-exports.
                    directImports = core.Append(directImports, direct)
                end
            elseif direct.kind == Kind.ImportType then
                -- Only check for typeof import('xyz')
                if not isAvailableThroughGlobal and direct:AsImportTypeNode().isTypeOf and direct:AsImportTypeNode().qualifier == nil and isExported(direct, false) then
                    addIndirectUser(ast.GetSourceFileOfNode(direct):AsNode(), true --[[addTransitiveDependencies]])
                end
                directImports = core.Append(directImports, direct)
            else
                debug.FailBadSyntaxKind(direct, "Unexpected import kind.")
            end
            ::continue::
        end
    end

    local function getIndirectUsers()
        if isAvailableThroughGlobal then
            -- It has `export as namespace`, so anything could potentially use it.
            return sourceFiles
        end
        -- Module augmentations may use this module's exports without importing it.
        for _, decl in ipairs(exportInfo.exportingModuleSymbol.declarations or {}) do
            if ast.IsExternalModuleAugmentation(decl) and sourceFilesSet:Has(ast.GetSourceFileOfNode(decl):FileName()) then
                addIndirectUser(decl, false)
            end
        end
        -- This may return duplicates (if there are multiple module declarations in a single source file, all importing the same thing as a namespace), but `State.markSearchedSymbol` will handle that.
        return core.Map(indirectUserDeclarations, ast.GetSourceFileOfNode)
    end

    handleDirectImports(exportInfo.exportingModuleSymbol)
    return directImports, getIndirectUsers()
end

function ls.getContainingModuleSymbol(importer, c)
    return c:GetMergedSymbol(ls.getSourceFileLikeForImportDeclaration(importer):Symbol())
end

-- Returns 'true' is the namespace 'name' is re-exported from this module, and 'false' if it is only used locally
function ls.findNamespaceReExports(sourceFileLike, name, c)
    local namespaceImportSymbol = c:GetSymbolAtLocation(name)
    return ls.forEachPossibleImportOrExportStatement(sourceFileLike, function(statement)
        if not ast.IsExportDeclaration(statement) then
            return false
        end
        local exportClause = statement:AsExportDeclaration().exportClause
        local moduleSpecifier = statement:ModuleSpecifier()
        return moduleSpecifier == nil and exportClause ~= nil and ast.IsNamedExports(exportClause) and core.Some(exportClause:Elements(), function(element)
            return c:GetExportSpecifierLocalTargetSymbol(element) == namespaceImportSymbol
        end)
    end)
end

function ls.getSearchesFromDirectImports(directImports, exportSymbol, exportKind, c, isForRename)
    local importSearches = nil
    local singleReferences = nil

    local function addSearch(location, symbol)
        importSearches = core.Append(importSearches, { importLocation = location, importSymbol = symbol })
    end

    local function isNameMatch(name)
        -- Use name of "default" even in `export =` case because we may have allowSyntheticDefaultImports
        return name == exportSymbol.name or exportKind ~= ExportKind.Named and name == ast.InternalSymbolNameDefault
    end

    -- `import x = require("./x")` or `import * as x from "./x"`.
    -- An `export =` may be imported by this syntax, so it may be a direct import.
    -- If it's not a direct import, it will be in `indirectUsers`, so we don't have to do anything here.
    local function handleNamespaceImportLike(importName)
        -- Don't rename an import that already has a different name than the export.
        if exportKind == ExportKind.ExportEquals and (not isForRename or isNameMatch(importName:Text())) then
            addSearch(importName, c:GetSymbolAtLocation(importName))
        end
    end

    local function searchForNamedImport(namedBindings)
        if namedBindings == nil then
            return
        end
        for _, element in ipairs(namedBindings:Elements() or {}) do
            local name = element:Name()
            local propertyName = element:PropertyName()
            if not isNameMatch(core.OrElse(propertyName, name):Text()) then
                goto continue
            end
            if propertyName ~= nil then
                -- This is `import { foo as bar } from "./a"` or `export { foo as bar } from "./a"`. `foo` isn't a local in the file, so just add it as a single reference.
                singleReferences = core.Append(singleReferences, propertyName)
                -- If renaming `{ foo as bar }`, don't touch `bar`, just `foo`.
                -- But do rename `foo` in ` { default as foo }` if that's the original export name.
                if not isForRename or name:Text() == exportSymbol.name then
                    -- Search locally for `bar`.
                    addSearch(name, c:GetSymbolAtLocation(name))
                end
            else
                local localSymbol
                if ast.IsExportSpecifier(element) and element:PropertyName() ~= nil then
                    localSymbol = c:GetExportSpecifierLocalTargetSymbol(element)
                else
                    localSymbol = c:GetSymbolAtLocation(name)
                end
                addSearch(name, localSymbol)
            end
            ::continue::
        end
    end

    local function handleImport(decl)
        if ast.IsImportEqualsDeclaration(decl) then
            if ls.isExternalModuleImportEquals(decl) then
                handleNamespaceImportLike(decl:Name())
            end
            return
        end
        if ast.IsIdentifier(decl) then
            handleNamespaceImportLike(decl)
            return
        end
        if ast.IsImportTypeNode(decl) then
            local qualifier = decl:AsImportTypeNode().qualifier
            if qualifier ~= nil then
                local firstIdentifier = ast.GetFirstIdentifier(qualifier)
                if firstIdentifier:Text() == ast.SymbolName(exportSymbol) then
                    singleReferences = core.Append(singleReferences, firstIdentifier)
                end
            elseif exportKind == ExportKind.ExportEquals then
                singleReferences = core.Append(singleReferences, decl:AsImportTypeNode().argument:AsLiteralTypeNode().literal)
            end
            return
        end
        -- Ignore if there's a grammar error
        if not ast.IsStringLiteral(decl:ModuleSpecifier()) then
            return
        end
        if ast.IsExportDeclaration(decl) then
            local exportClause = decl:AsExportDeclaration().exportClause
            if exportClause ~= nil and ast.IsNamedExports(exportClause) then
                searchForNamedImport(exportClause)
            end
            return
        end
        local importClause = decl:ImportClause()
        if importClause ~= nil then
            local namedBindings = importClause:AsImportClause().namedBindings
            if namedBindings ~= nil then
                if namedBindings.kind == Kind.NamespaceImport then
                    handleNamespaceImportLike(namedBindings:Name())
                elseif namedBindings.kind == Kind.NamedImports then
                    -- 'default' might be accessed as a named import `{ default as foo }`.
                    if exportKind == ExportKind.Named or exportKind == ExportKind.Default then
                        searchForNamedImport(namedBindings)
                    end
                end
            end
            -- `export =` might be imported by a default import if `--allowSyntheticDefaultImports` is on, so this handles both ExportKind.Default and ExportKind.ExportEquals.
            -- If a default import has the same name as the default export, allow to rename it.
            -- Given `import f` and `export default function f`, we will rename both, but for `import g` we will rename just that.
            local name = importClause:Name()
            if name ~= nil and (exportKind == ExportKind.Default or exportKind == ExportKind.ExportEquals) and (not isForRename or name:Text() == ls.symbolNameNoDefault(exportSymbol)) then
                local defaultImportAlias = c:GetSymbolAtLocation(name)
                addSearch(name, defaultImportAlias)
            end
        end
    end
    for _, decl in ipairs(directImports or {}) do
        handleImport(decl)
    end
    return importSearches, singleReferences
end

function ls.getImportOrExportSymbol(node, symbol, c, comingFromExport)
    local function exportInfo(sym, kind)
        local info = ls.getExportInfo(sym, kind, c)
        if info ~= nil then
            return {
                kind = ImpExpKind.Export,
                symbol = sym,
                exportInfo = info,
            }
        end
        return nil
    end

    local function getExport()
        local function getExportAssignmentExport(ex)
            -- Get the symbol for the `export =` node; its parent is the module it's the export of.
            if ex:Symbol().parent == nil then
                return nil
            end
            local exportKind = core.IfElse(ex:AsExportAssignment().isExportEquals, ExportKind.ExportEquals, ExportKind.Default)
            return {
                kind = ImpExpKind.Export,
                symbol = symbol,
                exportInfo = {
                    exportingModuleSymbol = ex:Symbol().parent,
                    exportKind = exportKind,
                },
            }
        end

        -- Not meant for use with export specifiers or export assignment.
        local function getExportKindForDeclaration(n)
            if ast.HasSyntacticModifier(n, ModifierFlags.Default) then
                return ExportKind.Default
            end
            return ExportKind.Named
        end

        local function getSpecialPropertyExport(n, useLhsSymbol)
            local kind
            local declKind = ast.GetAssignmentDeclarationKind(n)
            if declKind == JSDeclarationKind.ExportsProperty then
                kind = ExportKind.Named
            elseif declKind == JSDeclarationKind.ModuleExports then
                kind = ExportKind.ExportEquals
            else
                return nil
            end
            local sym = symbol
            if useLhsSymbol then
                sym = n:Symbol()
            end
            if sym == nil then
                return nil
            end
            return exportInfo(sym, kind)
        end

        local parent = node.parent
        local grandparent = parent.parent
        if symbol.exportSymbol ~= nil then
            if ast.IsPropertyAccessExpression(parent) then
                -- When accessing an export of a JS module, there's no alias. The symbol will still be flagged as an export even though we're at the use.
                -- So check that we are at the declaration.
                if ast.IsBinaryExpression(grandparent) and core.Some(symbol.declarations, function(d) return d == parent end) then
                    return getSpecialPropertyExport(grandparent, false --[[useLhsSymbol]])
                end
                return nil
            end
            return exportInfo(symbol.exportSymbol, getExportKindForDeclaration(parent))
        else
            local exportNode = ls.getExportNode(parent, node)
            if exportNode ~= nil and (ast.HasSyntacticModifier(exportNode, ModifierFlags.Export) or ast.IsImplicitlyExportedJSDocDeclaration(exportNode)) then
                if ast.IsImportEqualsDeclaration(exportNode) and exportNode:AsImportEqualsDeclaration().moduleReference == node then
                    -- We're at `Y` in `export import X = Y`. This is not the exported symbol, the left-hand-side is. So treat this as an import statement.
                    if comingFromExport then
                        return nil
                    end
                    local lhsSymbol = c:GetSymbolAtLocation(exportNode:Name())
                    return {
                        kind = ImpExpKind.Import,
                        symbol = lhsSymbol,
                    }
                end
                return exportInfo(symbol, getExportKindForDeclaration(exportNode))
            elseif ast.IsNamespaceExport(parent) then
                return exportInfo(symbol, ExportKind.Named)
            elseif ast.IsExportAssignment(parent) then
                return getExportAssignmentExport(parent)
            elseif ast.IsExportAssignment(grandparent) then
                return getExportAssignmentExport(grandparent)
            elseif ast.IsBinaryExpression(parent) then
                return getSpecialPropertyExport(parent, true --[[useLhsSymbol]])
            elseif ast.IsBinaryExpression(grandparent) then
                return getSpecialPropertyExport(grandparent, true --[[useLhsSymbol]])
            elseif ast.IsJSDocTypedefTag(parent) or ast.IsJSDocCallbackTag(parent) then
                return exportInfo(symbol, ExportKind.Named)
            end
        end
        return nil
    end

    local function getImport()
        if not ls.isNodeImport(node) then
            return nil
        end
        -- JS destructuring from `require(...)` is import-like for references, but the binding element
        -- itself is still a local variable symbol rather than an alias.
        local importedSymbol
        if symbol.flags & SymbolFlags.Alias ~= 0 then
            importedSymbol = c:GetImmediateAliasedSymbol(symbol)
        else
            importedSymbol = ls.getPropertySymbolOfObjectBindingPatternWithoutPropertyName(symbol, c)
        end
        if importedSymbol == nil then
            return nil
        end
        -- Search on the local symbol in the exporting module, not the exported symbol.
        importedSymbol = ls.skipExportSpecifierSymbol(importedSymbol, c)
        if importedSymbol == nil then
            return nil
        end
        -- Similarly, skip past the symbol for 'export ='
        if importedSymbol.name == "export=" then
            importedSymbol = ls.getExportEqualsLocalSymbol(importedSymbol, c)
            if importedSymbol == nil then
                return nil
            end
        end
        -- If the import has a different name than the export, do not continue searching.
        -- If `importedName` is undefined, do continue searching as the export is anonymous.
        -- (All imports returned from this function will be ignored anyway if we are in rename and this is a not a named export.)
        local importedName = ls.symbolNameNoDefault(importedSymbol)
        if importedName == "" or importedName == ast.InternalSymbolNameDefault or importedName == symbol.name then
            return {
                kind = ImpExpKind.Import,
                symbol = importedSymbol,
            }
        end
        return nil
    end

    local result = getExport()
    if result == nil and not comingFromExport then
        result = getImport()
    end
    return result
end

function ls.getExportInfo(exportSymbol, exportKind, c)
    -- Parent can be nil if an `export` is not at the top-level (which is a compile error).
    if exportSymbol.parent ~= nil then
        local exportingModuleSymbol = c:GetMergedSymbol(exportSymbol.parent)
        -- `export` may appear in a namespace. In that case, just rely on global search.
        if checker.IsExternalModuleSymbol(exportingModuleSymbol) then
            return {
                exportingModuleSymbol = exportingModuleSymbol,
                exportKind = exportKind,
            }
        end
    end
    return nil
end

-- If a reference is a class expression, the exported node would be its parent.
-- If a reference is a variable declaration, the exported node would be the variable statement.
function ls.getExportNode(parent, node)
    local declaration
    if ast.IsVariableDeclaration(parent) then
        declaration = parent
    elseif ast.IsBindingElement(parent) then
        declaration = ast.WalkUpBindingElementsAndPatterns(parent)
    end
    if declaration ~= nil then
        if parent:Name() == node and not ast.IsCatchClause(declaration.parent) and ast.IsVariableStatement(declaration.parent.parent) then
            return declaration.parent.parent
        end
        return nil
    end
    return parent
end

function ls.isNodeImport(node)
    local parent = node.parent
    local k = parent.kind
    if k == Kind.ImportEqualsDeclaration then
        return parent:Name() == node and ls.isExternalModuleImportEquals(parent)
    elseif k == Kind.ImportSpecifier then
        -- For a rename import `{ foo as bar }`, don't search for the imported symbol. Just find local uses of `bar`.
        return parent:PropertyName() == nil
    elseif k == Kind.ImportClause or k == Kind.NamespaceImport then
        debug.Assert(parent:Name() == node)
        return true
    elseif k == Kind.BindingElement then
        return ast.IsInJSFile(node) and ast.IsVariableDeclarationInitializedToBareOrAccessedRequire(parent.parent.parent)
    end
    return false
end

function ls.isExternalModuleImportEquals(node)
    local moduleReference = node:AsImportEqualsDeclaration().moduleReference
    return ast.IsExternalModuleReference(moduleReference) and moduleReference:Expression().kind == Kind.StringLiteral
end

-- If at an export specifier, go to the symbol it refers to. */
function ls.skipExportSpecifierSymbol(symbol, c)
    -- For `export { foo } from './bar", there's nothing to skip, because it does not create a new alias. But `export { foo } does.
    for _, declaration in ipairs(symbol.declarations or {}) do
        if ast.IsExportSpecifier(declaration) and declaration:PropertyName() == nil and declaration.parent.parent:ModuleSpecifier() == nil then
            return core.OrElse(c:GetExportSpecifierLocalTargetSymbol(declaration), symbol)
        elseif ast.IsPropertyAccessExpression(declaration) and ast.IsModuleExportsAccessExpression(declaration:Expression()) and not ast.IsPrivateIdentifier(declaration:Name()) then
            -- Export of form 'module.exports.propName = expr';
            return c:GetSymbolAtLocation(declaration)
        elseif ast.IsShorthandPropertyAssignment(declaration) and ast.IsBinaryExpression(declaration.parent.parent) and ast.GetAssignmentDeclarationKind(declaration.parent.parent) == JSDeclarationKind.ModuleExports then
            return c:GetExportSpecifierLocalTargetSymbol(declaration:Name())
        end
    end
    return symbol
end

function ls.getExportEqualsLocalSymbol(importedSymbol, c)
    if importedSymbol.flags & SymbolFlags.Alias ~= 0 then
        return c:GetImmediateAliasedSymbol(importedSymbol)
    end
    local decl = importedSymbol.valueDeclaration
    debug.Assert(decl ~= nil)
    if ast.IsExportAssignment(decl) then
        return decl:Expression():Symbol()
    elseif ast.IsBinaryExpression(decl) then
        return decl:AsBinaryExpression().right:Symbol()
    elseif ast.IsSourceFile(decl) then
        return decl:Symbol()
    end
    return nil
end

function ls.symbolNameNoDefault(symbol)
    if symbol.name ~= ast.InternalSymbolNameDefault then
        return symbol.name
    end
    for _, decl in ipairs(symbol.declarations or {}) do
        local name = ast.GetNameOfDeclaration(decl)
        if name ~= nil and ast.IsIdentifier(name) then
            return name:Text()
        end
    end
    return ""
end

-- findModuleReferences finds all references to a module symbol across the given source files.
-- This includes import statements, <reference> directives, and implicit references (e.g., JSX runtime imports).
function ls.findModuleReferences(program, sourceFiles, searchModuleSymbol, c)
    local refs = {}

    for _, referencingFile in ipairs(sourceFiles or {}) do
        local searchSourceFile = searchModuleSymbol.valueDeclaration
        if searchSourceFile ~= nil and searchSourceFile.kind == Kind.SourceFile then
            -- Check <reference path> directives
            for _, ref in ipairs(referencingFile.referencedFiles or {}) do
                if program:GetSourceFileFromReference(referencingFile, ref) == searchSourceFile:AsSourceFile() then
                    refs[#refs + 1] = {
                        kind = ModuleReferenceKind.Reference,
                        referencingFile = referencingFile,
                        ref = ref,
                    }
                end
            end

            -- Check <reference types> directives
            for _, ref in ipairs(referencingFile.typeReferenceDirectives or {}) do
                local referenced = program:GetResolvedTypeReferenceDirectiveFromTypeReferenceDirective(ref, referencingFile)
                if referenced ~= nil and referenced.resolvedFileName == searchSourceFile:AsSourceFile():FileName() then
                    refs[#refs + 1] = {
                        kind = ModuleReferenceKind.Reference,
                        referencingFile = referencingFile,
                        ref = ref,
                    }
                end
            end
        end

        -- Check all imports (including require() calls)
        ls.forEachImport(program, referencingFile, function(importDecl, moduleSpecifier)
            local moduleSymbol = c:GetSymbolAtLocation(moduleSpecifier)
            if moduleSymbol == searchModuleSymbol then
                if ast.NodeIsSynthesized(importDecl) then
                    refs[#refs + 1] = {
                        kind = ModuleReferenceKind.Implicit,
                        literal = moduleSpecifier,
                        referencingFile = referencingFile,
                    }
                else
                    refs[#refs + 1] = {
                        kind = ModuleReferenceKind.Import,
                        literal = moduleSpecifier,
                    }
                end
            end
        end)
    end

    return refs
end
