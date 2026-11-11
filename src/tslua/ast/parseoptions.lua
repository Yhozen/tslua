local ast = require("tslua.ast")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

-- SourceFileParseOptions: { fileName = "", path = tspath.Path, externalModuleIndicatorOptions = ExternalModuleIndicatorOptions }
function ast.NewSourceFileParseOptions(fileName, path, externalModuleIndicatorOptions)
    return {
        fileName = fileName or "",
        path = path or "",
        externalModuleIndicatorOptions = externalModuleIndicatorOptions or ast.NewExternalModuleIndicatorOptions(),
    }
end

-- ExternalModuleIndicatorOptions: { jsx = bool, force = bool }
function ast.NewExternalModuleIndicatorOptions(jsx, force)
    return { jsx = jsx or false, force = force or false }
end

function ast.GetExternalModuleIndicatorOptions(fileName, options, metadata)
    if tspath.IsDeclarationFileName(fileName) then
        return ast.NewExternalModuleIndicatorOptions()
    end

    local kind = options:GetEmitModuleDetectionKind()
    if kind == core.ModuleDetectionKind.Force then
        -- All non-declaration files are modules, declaration files still do the usual isFileProbablyExternalModule
        return ast.NewExternalModuleIndicatorOptions(false, true)
    elseif kind == core.ModuleDetectionKind.Legacy then
        -- Files are modules if they have imports, exports, or import.meta
        return ast.NewExternalModuleIndicatorOptions()
    elseif kind == core.ModuleDetectionKind.Auto then
        -- If module is nodenext or node16, all esm format files are modules
        -- If jsx is react-jsx or react-jsxdev then jsx tags force module-ness
        -- otherwise, the presence of import or export statments (or import.meta) implies module-ness
        return ast.NewExternalModuleIndicatorOptions(
            options.jsx == core.JsxEmit.ReactJSX or options.jsx == core.JsxEmit.ReactJSXDev,
            ast.isFileForcedToBeModuleByFormat(fileName, options, metadata)
        )
    end
    return ast.NewExternalModuleIndicatorOptions()
end

ast.isFileForcedToBeModuleByFormatExtensions = { tspath.ExtensionCjs, tspath.ExtensionCts, tspath.ExtensionMjs, tspath.ExtensionMts }

function ast.isFileForcedToBeModuleByFormat(fileName, options, metadata)
    -- Excludes declaration files - they still require an explicit `export {}` or the like
    -- for back compat purposes. The only non-declaration files _not_ forced to be a module are `.js` files
    -- that aren't esm-mode (meaning not in a `type: module` scope).
    if ast.GetImpliedNodeFormatForEmitWorker(fileName, options:GetEmitModuleKind(), metadata) == core.ModuleKind.ESNext or
        tspath.FileExtensionIsOneOf(fileName, ast.isFileForcedToBeModuleByFormatExtensions) then
        return true
    end
    return false
end

function ast.SetExternalModuleIndicator(file, opts)
    file.externalModuleIndicator = ast.getExternalModuleIndicator(file, opts)
end

function ast.getExternalModuleIndicator(file, opts)
    if file.scriptKind == core.ScriptKind.JSON then
        return nil
    end

    local node = ast.isFileProbablyExternalModule(file)
    if node ~= nil then
        return node
    end

    if file.isDeclarationFile then
        return nil
    end

    if opts.jsx then
        node = ast.isFileModuleFromUsingJSXTag(file)
        if node ~= nil then
            return node
        end
    end

    if opts.force then
        return file
    end

    return nil
end

function ast.isFileProbablyExternalModule(sourceFile)
    for _, statement in ipairs(sourceFile.statements.nodes) do
        if ast.isAnExternalModuleIndicatorNode(statement) then
            return statement
        end
    end
    return ast.getImportMetaIfNecessary(sourceFile)
end

function ast.isAnExternalModuleIndicatorNode(node)
    return ast.HasSyntacticModifier(node, ast.ModifierFlags.Export) or
        ast.IsImportEqualsDeclaration(node) and ast.IsExternalModuleReference(node.moduleReference) or
        ast.IsImportDeclaration(node) or ast.IsExportAssignment(node) or ast.IsExportDeclaration(node)
end

function ast.getImportMetaIfNecessary(sourceFile)
    if sourceFile.flags & ast.NodeFlags.PossiblyContainsImportMeta ~= 0 then
        return ast.findChildNode(sourceFile, ast.IsImportMeta)
    end
    return nil
end

function ast.findChildNode(root, check)
    local result = nil
    local visit
    visit = function(node)
        if check(node) then
            result = node
            return true
        end
        return node:ForEachChild(visit)
    end
    visit(root)
    return result
end

function ast.isFileModuleFromUsingJSXTag(file)
    return ast.walkTreeForJSXTags(file)
end

-- This is a somewhat unavoidable full tree walk to locate a JSX tag - `import.meta` requires the same,
-- but we avoid that walk (or parts of it) if at all possible using the `PossiblyContainsImportMeta` node flag.
-- Unfortunately, there's no `NodeFlag` space to do the same for JSX.
function ast.walkTreeForJSXTags(node)
    local found = nil

    local visitor
    visitor = function(n)
        if found ~= nil then
            return true
        end
        if n:SubtreeFacts() & ast.SubtreeFacts.SubtreeContainsJsx == 0 then
            return false
        end
        if ast.IsJsxOpeningLikeElement(n) or ast.IsJsxFragment(n) then
            found = n
            return true
        end
        return n:ForEachChild(visitor)
    end
    visitor(node)

    return found
end
