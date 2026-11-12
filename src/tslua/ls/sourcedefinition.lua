local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local binder = require("tslua.binder")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local lsproto = require("tslua.lsp.lsproto")
local module = require("tslua.module")
local modulespecifiers = require("tslua.modulespecifiers")
local packagejson = require("tslua.packagejson")
local parser = require("tslua.parser")
local spanmap = require("tslua.spanmap")
local tspath = require("tslua.tspath")

local Kind = ast.Kind
local ModifierFlags = ast.ModifierFlags

local LanguageService = ls.LanguageService
if LanguageService == nil then
    LanguageService = {}
    LanguageService.__index = LanguageService
    ls.LanguageService = LanguageService
end

function LanguageService:ProvideSourceDefinition(ctx, documentURI, pos)
    local program, file = self:getProgramAndFile(documentURI)
    local positions = lsconv.FromLSPPositionForSourceFile(self.converters, file, pos, spanmap.Feature.Definition)
    local results = {}
    for _, mapped in ipairs(positions or {}) do
        if spanmap.Fidelity_IsSingleSegment(mapped.fidelity) then
            local result, err = self:provideSourceDefinitionAtPosition(ctx, program, mapped.script, mapped.position)
            if err ~= nil then
                return {}, err
            end
            results[#results + 1] = result
        end
    end
    return ls.combineDefinitionResponses(results, lsproto.GetClientCapabilities(ctx).textDocument.definition.linkSupport), nil
end

function LanguageService:provideSourceDefinitionAtPosition(ctx, program, file, textPos)
    local caps = lsproto.GetClientCapabilities(ctx)
    local clientSupportsLink = caps.textDocument.definition.linkSupport

    local pos = textPos
    local resolver = self:newSourceDefResolver(program, file:FileName())
    local node = astnav.GetTouchingPropertyName(file, pos)

    if node.kind == Kind.SourceFile then
        -- Triple-slash directives are comments, not AST nodes, so
        -- GetTouchingPropertyName returns the SourceFile node.
        local declarations, ref = resolver:resolveTripleSlashReference(file, pos, program)
        if core.Len(declarations) ~= 0 then
            local originSelectionRange = self:createLspRangeFromBounds(ref:Pos(), ref:End(), file)
            return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, declarations, nil --[[reference]], spanmap.Feature.Definition), nil
        end
        return {}, nil
    end

    local originSelectionRange = self:createLspRangeFromNode(node, file)

    -- If the cursor is directly on a module specifier string, resolve to the
    -- implementation file's entry point.
    local containingModuleSpecifier = ls.findContainingModuleSpecifier(node)
    if node == containingModuleSpecifier then
        local specifierMode = program:GetModeForUsageLocation(file, containingModuleSpecifier)
        local implementationFile = resolver:resolveImplementation(containingModuleSpecifier:Text(), specifierMode)
        if implementationFile ~= "" then
            local sourceFile = resolver:getOrParseSourceFile(implementationFile)
            if sourceFile ~= nil then
                return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, ls.getSourceDefinitionEntryDeclarations(sourceFile), nil, spanmap.Feature.Definition), nil
            end
        end
        return self:provideDefinitionAtPosition(ctx, program, file, textPos, clientSupportsLink), nil
    end

    -- Phase 1: Syntactic fast path — when the cursor is inside an
    -- import/require/export, forward-resolve the module specifier to an
    -- implementation file and search it directly. This avoids acquiring
    -- the type checker entirely when the fast path succeeds.
    local resolvedImplFile = ""
    if containingModuleSpecifier ~= nil then
        local specifierMode = program:GetModeForUsageLocation(file, containingModuleSpecifier)
        resolvedImplFile = resolver:resolveImplementation(containingModuleSpecifier:Text(), specifierMode)
    end

    if resolvedImplFile ~= "" then
        local names = ls.getCandidateSourceDeclarationNames(node, nil)
        local moduleResults = resolver:searchImplementationFile(node, resolvedImplFile, names)
        if core.Len(moduleResults) ~= 0 then
            if not ast.IsPartOfTypeNode(node) and not ast.IsPartOfTypeOnlyImportOrExportDeclaration(node) or ls.hasConcreteSourceDeclarations(moduleResults) then
                return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, ls.uniqueDeclarationNodes(moduleResults), nil, spanmap.Feature.Definition), nil
            end
        end
    end

    -- Phase 2: Type checker path — acquire the checker for the original file
    -- and use its declarations and module specifier to map to source
    -- implementations. This is the only point where the checker is used;
    -- after this, only the NoDts module resolver and file parsing are needed.
    local checkerDeclarations, moduleSpecifier = ls.getSourceDefCheckerInfo(ctx, program, file, node)

    -- Phase 3: Map checker results to source definitions.
    local declarations = resolver:resolveFromCheckerInfo(node, resolvedImplFile, checkerDeclarations, moduleSpecifier)
    if core.Len(declarations) == 0 then
        -- If we resolved an implementation file from an import/export but
        -- couldn't find specific declarations, fall back to the file entry
        -- point rather than the standard definition provider — unless the
        -- checker found declarations that are all type-only (e.g. interfaces),
        -- in which case the .d.ts definition is more appropriate.
        if containingModuleSpecifier ~= nil and resolvedImplFile ~= "" and not ls.hasConcreteSourceDeclarations(checkerDeclarations) then
            local sourceFile = resolver:getOrParseSourceFile(resolvedImplFile)
            if sourceFile ~= nil then
                return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, ls.getSourceDefinitionEntryDeclarations(sourceFile), nil, spanmap.Feature.Definition), nil
            end
        end
        return self:provideDefinitionAtPosition(ctx, program, file, textPos, clientSupportsLink), nil
    end
    return self:createDefinitionLocations(originSelectionRange, clientSupportsLink, declarations, nil --[[reference]], spanmap.Feature.Definition), nil
end

-- sourceDefResolver resolves source definitions by mapping .d.ts declarations
-- to their implementation files (.js/.ts). It uses the NoDts module resolver
-- and file parsing for resolution, but never acquires the type checker or
-- the original program; all checker-dependent work is done before results
-- are passed in.
-- Fields: ls, fs, options, getSourceFile, resolveFrom, resolver, parsedFiles
local sourceDefResolver = {}
sourceDefResolver.__index = sourceDefResolver
ls.sourceDefResolver = sourceDefResolver

function LanguageService:newSourceDefResolver(program, resolveFrom)
    local options = program:Options()
    local noDtsOptions = options:Clone()
    noDtsOptions.noDtsResolution = core.Tristate.TSTrue
    return setmetatable({
        ls = self,
        fs = program:Host():FS(),
        options = options,
        getSourceFile = function(fileName) return program:GetSourceFile(fileName) end,
        resolveFrom = resolveFrom,
        resolver = module.NewResolver(program:Host(), noDtsOptions, program:GetGlobalTypingsCacheLocation(), "", program:CommandLine():ContentMapperExtensions()),
        parsedFiles = nil,
    }, sourceDefResolver)
end

-- resolveFromCheckerInfo maps type-checker declarations to source
-- implementations. It uses only the NoDts module resolver and file parsing;
-- the type checker and original request file are not needed.
function sourceDefResolver:resolveFromCheckerInfo(node, resolvedImplFile, checkerDeclarations, moduleSpecifier)
    -- If we don't yet have a forward-resolved implementation file, try to
    -- recover a module specifier from the checker (e.g. from the import that
    -- brought the symbol into scope, or from the root of an access expression).
    if resolvedImplFile == "" and moduleSpecifier ~= "" then
        resolvedImplFile = self:resolveImplementation(moduleSpecifier, self:inferImpliedNodeFormat(self.resolveFrom))
    end

    -- For property access where the checker found no declarations (e.g.
    -- mapped types), search the implementation file for the property name.
    if core.Len(checkerDeclarations) == 0 and resolvedImplFile ~= "" then
        local names = ls.getCandidateSourceDeclarationNames(node, nil)
        local results = self:searchImplementationFile(node, resolvedImplFile, names)
        if results ~= nil then
            return ls.uniqueDeclarationNodes(results)
        end
    end

    local declarations = nil
    for _, declaration in ipairs(checkerDeclarations or {}) do
        declarations = core.AppendAll(declarations, self:mapDeclarationToSource(node, declaration, resolvedImplFile))
    end
    declarations = ls.uniqueDeclarationNodes(declarations)
    if ls.hasConcreteSourceDeclarations(declarations) then
        return declarations
    end
    return nil
end

-- getSourceDefCheckerInfo acquires the type checker for the given file and
-- returns the definition declarations for node along with the module specifier
-- of the import that brought the symbol into scope (empty if not applicable).
function ls.getSourceDefCheckerInfo(ctx, program, file, node)
    local c, done = program:GetTypeCheckerForFile(ctx, file)

    local declarations = ls.getDeclarationsFromLocation(c, node)
    local isPropertyName = node.parent ~= nil and ast.IsAccessExpression(node.parent) and node.parent:Name() == node
    if core.Len(declarations) == 0 and isPropertyName then
        local left = node.parent:Expression()
        if left ~= nil then
            local prop = c:GetPropertyOfType(c:GetTypeAtLocation(left), node:Text())
            if prop ~= nil then
                declarations = prop.declarations
            end
        end
    end
    local calledDeclaration = ls.tryGetSignatureDeclaration(c, node)
    if calledDeclaration ~= nil then
        local nonFunctionDeclarations = core.Filter(declarations, function(n) return not ast.IsFunctionLike(n) end)
        declarations = core.Append(core.Slice(nonFunctionDeclarations), calledDeclaration)
    end

    -- Extract module specifier from the import that brought this symbol into
    -- scope. For property access (obj.prop), walk up the access chain to the
    -- root expression's symbol.
    local moduleSpecifier = ""
    local resolveNode = node
    if isPropertyName then
        local expr = node.parent:Expression()
        while expr ~= nil and ast.IsAccessExpression(expr) do
            expr = expr:Expression()
        end
        if expr ~= nil then
            resolveNode = expr
        end
    end
    local sym = c:GetSymbolAtLocation(resolveNode)
    if sym ~= nil then
        for _, d in ipairs(sym.declarations or {}) do
            if not ast.IsImportSpecifier(d) and not ast.IsImportClause(d) and not ast.IsNamespaceImport(d) and not ast.IsImportEqualsDeclaration(d) then
                goto continue
            end
            do
                local spec = checker.TryGetModuleSpecifierFromDeclaration(d)
                if spec ~= nil then
                    moduleSpecifier = spec:Text()
                    break
                end
            end
            ::continue::
        end
    end

    done()
    return declarations, moduleSpecifier
end

-- resolveTripleSlashReference handles /// <reference path/types="..."/> directives.
-- For path references to .js files, it returns the entry declarations directly.
-- For path references to .d.ts files or type references, it uses the NoDts
-- resolver to find the corresponding implementation file.
function sourceDefResolver:resolveTripleSlashReference(file, pos, program)
    local ref = ls.getReferenceAtPosition(file, pos, program)
    if ref == nil or ref.file == nil then
        return nil, nil
    end

    -- If the referenced file is already an implementation file, return it directly.
    if not ref.file.isDeclarationFile then
        return ls.getSourceDefinitionEntryDeclarations(ref.file), ref.reference
    end

    -- The referenced file is a .d.ts. Try to find the implementation file
    -- using the NoDts module resolver via findImplementationFileFromDtsFileName.
    local dtsFileName = ref.file:FileName()
    local preferredMode = self:inferImpliedNodeFormat(dtsFileName)
    local implementationFile = self:findImplementationFileFromDtsFileName(dtsFileName, preferredMode)
    if implementationFile == "" then
        return nil, nil
    end

    local sourceFile = self:getOrParseSourceFile(implementationFile)
    if sourceFile == nil then
        return nil, nil
    end
    return ls.getSourceDefinitionEntryDeclarations(sourceFile), ref.reference
end

-- searchImplementationFile searches an implementation file for declarations
-- matching the given names. Returns nil when no declarations matched; callers
-- fall through to the checker path or to the standard definition provider.
function sourceDefResolver:searchImplementationFile(originalNode, implementationFile, names)
    if implementationFile == "" then
        return nil
    end
    local sourceFile = self:getOrParseSourceFile(implementationFile)
    if sourceFile == nil then
        return nil
    end
    if ls.isDefaultImportName(originalNode) then
        -- For default imports, only search for "default" declarations to avoid
        -- matching unrelated declarations with the same identifier name.
        local defaultDeclarations = self:findDeclarationsInFile(implementationFile, { "default" }, collections.NewSet())
        if core.Len(defaultDeclarations) ~= 0 then
            return ls.filterPreferredSourceDeclarations(originalNode, defaultDeclarations)
        end
        return ls.getSourceDefinitionEntryDeclarations(sourceFile)
    end
    local declarations = self:findDeclarationsInFile(implementationFile, names, collections.NewSet())
    if core.Len(declarations) ~= 0 then
        return ls.filterPreferredSourceDeclarations(originalNode, declarations)
    end
    return nil
end

function ls.isDefaultImportName(node)
    if node == nil or node.parent == nil or not ast.IsImportClause(node.parent) or node.parent:Name() ~= node or node.parent.parent == nil then
        return false
    end
    return ast.IsDefaultImport(node.parent.parent)
end

function ls.getSourceDefinitionEntryNode(sourceFile)
    if #sourceFile.statements.nodes ~= 0 then
        return sourceFile.statements.nodes[1]
    end
    return sourceFile:AsNode()
end

function ls.getSourceDefinitionEntryDeclarations(sourceFile)
    return { ls.getSourceDefinitionEntryNode(sourceFile) }
end

function sourceDefResolver:mapDeclarationToSource(originalNode, declaration, resolvedImplFile)
    local file, startPos = ls.getFileAndStartPosFromDeclaration(declaration)
    local fileName = file:FileName()

    local mapped = self.ls:tryGetSourcePosition(fileName, startPos)
    if mapped ~= nil then
        local sourceFile = self:getOrParseSourceFile(mapped.fileName)
        if sourceFile ~= nil then
            return { ls.findClosestDeclarationNode(sourceFile, mapped.pos) }
        end
    end

    if not tspath.IsDeclarationFileName(fileName) then
        return { declaration }
    end

    local implementationFile = resolvedImplFile
    if implementationFile == "" then
        -- Reverse-resolve .d.ts path to implementation file. This path is only
        -- reached for declarations with no associated module specifier (e.g.
        -- globals, ambient declarations, or when forward resolution failed).
        local dtsFileName = ast.GetSourceFileOfNode(declaration):FileName()
        local preferredMode = self:inferImpliedNodeFormat(dtsFileName)
        implementationFile = self:findImplementationFileFromDtsFileName(dtsFileName, preferredMode)
    end

    return self:searchImplementationFile(originalNode, implementationFile, ls.getCandidateSourceDeclarationNames(originalNode, declaration))
end

-- Go strings.LastIndex (0-based, -1 if absent).
local function lastIndex(s, sub)
    local result = -1
    local init = 1
    while true do
        local i = string.find(s, sub, init, true)
        if i == nil then
            return result
        end
        result = i - 1
        init = i + 1
    end
end

function sourceDefResolver:findImplementationFileFromDtsFileName(dtsFileName, preferredMode)
    local jsExt = module.TryGetJSExtensionForFile(dtsFileName, self.options)
    if jsExt ~= "" then
        local candidate = tspath.ChangeExtension(dtsFileName, jsExt)
        if self.fs:FileExists(candidate) then
            return candidate
        end
    end

    local parts = modulespecifiers.GetNodeModulePathParts(dtsFileName)
    if parts == nil then
        return ""
    end

    -- Ensure the file only contains one /node_modules/ segment. If there's more
    -- than one, the package name extraction may be incorrect, so bail out.
    if lastIndex(dtsFileName, "/node_modules/") ~= parts.topLevelNodeModulesIndex then
        return ""
    end

    local packageNamePathPart = string.sub(dtsFileName, parts.topLevelPackageNameIndex + 2, parts.packageRootIndex)
    local packageName = module.GetPackageNameFromTypesPackageName(module.UnmangleScopedPackageName(packageNamePathPart))
    if packageName == "" then
        return ""
    end

    local pathToFileInPackage = string.sub(dtsFileName, parts.packageRootIndex + 2)

    -- Try resolving as a package subpath first (e.g. "pkg/dist/utils"), then
    -- fall back to the bare package name (e.g. "pkg"). This covers both main
    -- entrypoints and deep imports without needing to inspect package.json
    -- entrypoints.
    if pathToFileInPackage ~= "" then
        local specifier = packageName .. "/" .. tspath.RemoveFileExtension(pathToFileInPackage)
        local implementationFile = self:resolveImplementation(specifier, preferredMode)
        if implementationFile ~= "" then
            return implementationFile
        end
    end
    return self:resolveImplementation(packageName, preferredMode)
end

function sourceDefResolver:resolveImplementation(moduleName, preferredMode)
    return self:resolveImplementationFrom(moduleName, self.resolveFrom, preferredMode)
end

function sourceDefResolver:resolveImplementationFrom(moduleName, resolveFromFile, preferredMode)
    local modes = { preferredMode }
    if preferredMode ~= core.ModuleKind.ESNext then
        modes[#modes + 1] = core.ModuleKind.ESNext
    end
    if preferredMode ~= core.ModuleKind.CommonJS then
        modes[#modes + 1] = core.ModuleKind.CommonJS
    end

    for _, mode in ipairs(modes) do
        local resolved = self.resolver:ResolveModuleName(moduleName, resolveFromFile, mode, nil)
        if resolved ~= nil and resolved:IsResolved() and not tspath.IsDeclarationFileName(resolved.resolvedFileName) then
            return resolved.resolvedFileName
        end
    end
    return ""
end

function sourceDefResolver:getOrParseSourceFile(fileName)
    local existing = self.getSourceFile(fileName)
    if existing ~= nil then
        return existing
    end
    if self.parsedFiles ~= nil then
        local parsed = self.parsedFiles[fileName]
        if parsed ~= nil then
            -- Go stores nil for files that could not be read; `false` marks them here.
            if parsed == false then
                return nil
            end
            return parsed
        end
    end
    local sourceFile = nil
    local text, ok = self.ls:ReadFile(fileName)
    if ok then
        sourceFile = parser.ParseSourceFile(
            ast.NewSourceFileParseOptions(fileName, self.ls:toPath(fileName), ast.NewExternalModuleIndicatorOptions(false, false)),
            text,
            -- A declaration map's `sources` entries are arbitrary strings, so the
            -- file name here may not have a recognized extension.
            core.EnsureScriptKindFromFileName(fileName)
        )
        binder.BindSourceFile(sourceFile)
    end
    if self.parsedFiles == nil then
        self.parsedFiles = {}
    end
    if sourceFile == nil then
        self.parsedFiles[fileName] = false
    else
        self.parsedFiles[fileName] = sourceFile
    end
    return sourceFile
end

-- inferImpliedNodeFormat determines the module format for a source file that may not be
-- in the program, using the file extension and nearest package.json "type" field.
function sourceDefResolver:inferImpliedNodeFormat(fileName)
    local packageJsonType = ""
    local scope = self.resolver:GetPackageScopeForPath(tspath.GetDirectoryPath(fileName))
    if packagejson.InfoCacheEntry.Exists(scope) then
        local value, ok = scope.contents.type:GetValue()
        if ok then
            packageJsonType = value
        end
    end
    return ast.GetImpliedNodeFormatForFile(fileName, packageJsonType)
end

function ls.findContainingModuleSpecifier(node)
    local current = node
    while current ~= nil do
        if ast.IsAnyImportOrReExport(current) or ast.IsRequireCall(current, true --[[requireStringLiteralLikeArgument]]) or ast.IsImportCall(current) then
            local moduleSpecifier = ast.GetExternalModuleName(current)
            if moduleSpecifier ~= nil and ast.IsStringLiteralLike(moduleSpecifier) then
                return moduleSpecifier
            end
        end
        current = current.parent
    end
    return nil
end

function sourceDefResolver:findDeclarationsInFile(fileName, names, seen)
    if fileName == "" or core.Len(names) == 0 then
        return nil
    end
    if not seen:AddIfAbsent(fileName) then
        return nil
    end

    local sourceFile = self:getOrParseSourceFile(fileName)
    if sourceFile == nil then
        return nil
    end

    local declarations = ls.findDeclarationNodesByName(sourceFile, names)
    if core.Len(declarations) ~= 0 and ls.hasConcreteSourceDeclarations(declarations) then
        return declarations
    end

    local forwarded = nil
    for _, forwardedFile in ipairs(self:getForwardedImplementationFiles(sourceFile) or {}) do
        forwarded = core.AppendAll(forwarded, self:findDeclarationsInFile(forwardedFile, names, seen))
    end
    if core.Len(forwarded) ~= 0 then
        if ls.hasConcreteSourceDeclarations(forwarded) then
            return ls.uniqueDeclarationNodes(forwarded)
        end
        return ls.uniqueDeclarationNodes(core.AppendAll(core.Slice(declarations), forwarded))
    end
    return declarations
end

function sourceDefResolver:getForwardedImplementationFiles(sourceFile)
    local preferredMode = self:inferImpliedNodeFormat(sourceFile:FileName())

    local files = nil
    for _, imp in ipairs(sourceFile:Imports() or {}) do
        local moduleName = imp:Text()
        local implementationFile = self:resolveImplementationFrom(moduleName, sourceFile:FileName(), preferredMode)
        if implementationFile ~= "" then
            files = core.Append(files, implementationFile)
        end
    end
    return core.Deduplicate(files)
end

function ls.getCandidateSourceDeclarationNames(originalNode, declaration)
    local names = nil
    if declaration ~= nil then
        local name = ast.GetNameOfDeclaration(declaration)
        if name ~= nil then
            local text = ast.GetTextOfPropertyName(name)
            if text ~= "" then
                names = core.Append(names, text)
            end
        end
        if declaration.kind == Kind.ExportAssignment then
            names = core.Append(names, "default")
        end
        if (ast.IsFunctionDeclaration(declaration) or ast.IsClassDeclaration(declaration)) and declaration:ModifierFlags() & ModifierFlags.ExportDefault == ModifierFlags.ExportDefault then
            names = core.Append(names, "default")
        end
        if ast.IsImportSpecifier(declaration) or ast.IsExportSpecifier(declaration) then
            local propName = declaration:PropertyName()
            if propName ~= nil then
                names = core.Append(names, propName:Text())
            end
        end
    end
    if originalNode ~= nil then
        if ast.IsIdentifier(originalNode) or ast.IsPrivateIdentifier(originalNode) then
            names = core.Append(names, originalNode:Text())
        end
        if ls.isDefaultImportName(originalNode) then
            names = core.Append(names, "default")
        end
        if originalNode.parent ~= nil then
            if ast.IsImportSpecifier(originalNode.parent) or ast.IsExportSpecifier(originalNode.parent) then
                local propName = originalNode.parent:PropertyName()
                if propName ~= nil then
                    names = core.Append(names, propName:Text())
                end
            end
        end
    end
    return names
end

function ls.findDeclarationNodesByName(sourceFile, names)
    names = core.Deduplicate(core.Filter(names, function(name) return name ~= "" end))
    if core.Len(names) == 0 then
        return nil
    end

    local wanted = collections.NewSet()
    local wantDefault = false
    for _, name in ipairs(names) do
        if name == "default" then
            wantDefault = true
        else
            wanted:Add(name)
        end
    end

    -- candidate: { node, depth }
    local candidates = {}
    local minDepth = math.maxinteger

    local visit
    visit = function(node)
        local matched = false
        local name = ast.GetNameOfDeclaration(node)
        if name ~= nil then
            local text = ast.GetTextOfPropertyName(name)
            if text ~= "" then
                if wanted:Has(text) then
                    matched = true
                end
            end
        end
        if wantDefault and node.kind == Kind.ExportAssignment then
            matched = true
        end
        if wantDefault and (ast.IsFunctionDeclaration(node) or ast.IsClassDeclaration(node)) and node:ModifierFlags() & ModifierFlags.ExportDefault == ModifierFlags.ExportDefault then
            matched = true
        end
        if matched then
            local depth = ls.getContainerDepth(node)
            candidates[#candidates + 1] = { node = node, depth = depth }
            if depth < minDepth then
                minDepth = depth
            end
        end
        return node:ForEachChild(visit)
    end
    sourceFile:AsNode():ForEachChild(visit)

    -- Only keep declarations at the shallowest depth, like getTopMostDeclarationNamesInFile.
    local declarations = nil
    for _, c in ipairs(candidates) do
        if c.depth == minDepth then
            declarations = core.Append(declarations, c.node)
        end
    end
    return ls.uniqueDeclarationNodes(declarations)
end

-- getContainerDepth counts the number of container nodes above a declaration,
-- matching the behavior of getDepth in getTopMostDeclarationNamesInFile.
function ls.getContainerDepth(node)
    local depth = 0
    local current = node
    while current ~= nil do
        current = ls.getContainerNode(current)
        depth = depth + 1
    end
    return depth
end

function ls.filterPreferredSourceDeclarations(originalNode, declarations)
    if core.Len(declarations) <= 1 or originalNode == nil then
        return declarations
    end
    local preferred = ls.getPropertyLikeSourceDeclarations(originalNode, declarations)
    if core.Len(preferred) ~= 0 then
        return preferred
    end
    preferred = core.Filter(declarations, ls.isConcreteSourceDeclaration)
    if core.Len(preferred) ~= 0 then
        return preferred
    end
    return declarations
end

local propertyLikeKinds = ast.kindSet(
    Kind.PropertyAssignment,
    Kind.ShorthandPropertyAssignment,
    Kind.PropertyDeclaration,
    Kind.PropertySignature,
    Kind.MethodDeclaration,
    Kind.MethodSignature,
    Kind.GetAccessor,
    Kind.SetAccessor,
    Kind.EnumMember
)

function ls.getPropertyLikeSourceDeclarations(originalNode, declarations)
    if originalNode.parent == nil or not ast.IsAccessExpression(originalNode.parent) or originalNode.parent:Name() ~= originalNode then
        return nil
    end
    return core.Filter(declarations, function(node)
        return propertyLikeKinds[node.kind] == true
    end)
end

function ls.hasConcreteSourceDeclarations(declarations)
    return core.Some(declarations, ls.isConcreteSourceDeclaration)
end

local nonConcreteKinds = ast.kindSet(
    Kind.Parameter,
    Kind.TypeParameter,
    Kind.BindingElement,
    Kind.ImportClause,
    Kind.ImportSpecifier,
    Kind.NamespaceImport,
    Kind.ExportSpecifier,
    Kind.PropertyAccessExpression,
    Kind.ElementAccessExpression
)

function ls.isConcreteSourceDeclaration(node)
    if not ast.IsDeclaration(node) or node.kind == Kind.ExportAssignment then
        return false
    end
    if (ast.IsBinaryExpression(node) or ast.IsCallExpression(node)) and ast.GetAssignmentDeclarationKind(node) ~= ast.JSDeclarationKind.None then
        return false
    end
    if nonConcreteKinds[node.kind] then
        return false
    end
    return true
end

function ls.uniqueDeclarationNodes(nodes)
    -- declarationKey: { fileName, loc }
    local seen = collections.NewSet()
    local result = {}
    for _, node in ipairs(nodes or {}) do
        if node == nil then
            goto continue
        end
        do
            local fileName = ast.GetSourceFileOfNode(node):FileName()
            local key = fileName .. "\0" .. node.loc:Pos() .. ":" .. node.loc:End()
            if not seen:AddIfAbsent(key) then
                goto continue
            end
            result[#result + 1] = node
        end
        ::continue::
    end
    return result
end

function ls.findClosestDeclarationNode(sourceFile, pos)
    local node = astnav.GetTouchingPropertyName(sourceFile, pos)
    local current = node
    while current ~= nil do
        if ast.IsDeclaration(current) or current.kind == Kind.ExportAssignment then
            return current
        end
        current = current.parent
    end
    return ls.getSourceDefinitionEntryNode(sourceFile)
end
