local contentmapper = require("tslua.contentmapper")
local ast = require("tslua.ast")
local core = require("tslua.core")
local parser = require("tslua.parser")
local tspath = require("tslua.tspath")

local TransformErrorKind = contentmapper.TransformErrorKind

-- SourceFiles is the canonical output and its unnamed supplemental compiler inputs:
-- { canonical = *ast.SourceFile, supplemental = []*ast.SourceFile }.
function contentmapper.NewSourceFiles(canonical, supplemental)
    return { canonical = canonical, supplemental = supplemental }
end

-- copyParseOptions copies an ast.SourceFileParseOptions value (it is a Go value struct).
local function copyParseOptions(opts, fileName, path, force)
    local emi = opts.externalModuleIndicatorOptions or ast.NewExternalModuleIndicatorOptions()
    return ast.NewSourceFileParseOptions(
        fileName or opts.fileName,
        path or opts.path,
        ast.NewExternalModuleIndicatorOptions(emi.jsx, force or emi.force)
    )
end

-- TransformAndParse runs the given content mapper's transform for a content-mapped source file and
-- parses the resulting TypeScript, preserving the original file name and retaining the untransformed text
-- on the source file. The mapper is supplied by the caller (which also owns the failure accounting) so it
-- is neither re-resolved nor substituted here. It returns an error if the transform fails or the mapper
-- produces invalid position mappings (a *spanmap.MappingError); the caller decides how to report the failure
-- and what placeholder file to substitute. It is the shared implementation behind
-- CompilerHost.GetContentMappedSourceFile. Returns (SourceFiles, err).
function contentmapper.TransformAndParse(parseOptions, content, mapper, project)
    local transformIdentity, err = project:Identity(mapper)
    if err ~= nil then
        return contentmapper.NewSourceFiles(), contentmapper.NewTransformError(TransformErrorKind.Project, err)
    end
    local result
    result, err = project:Transform(mapper, contentmapper.NewRequest(parseOptions.fileName, content))
    if err ~= nil then
        return contentmapper.NewSourceFiles(), err
    end
    return contentmapper.ParseResult(parseOptions, content, mapper, transformIdentity, result)
end

-- ParseResult validates and parses one mapper result and all its supplemental outputs.
-- Returns (SourceFiles, err).
function contentmapper.ParseResult(parseOptions, content, mapper, transformIdentity, result)
    if result.mappings == nil then
        return contentmapper.NewSourceFiles(), contentmapper.NewTransformError(TransformErrorKind.Mappings, nil)
    end
    local problem = result.mappings:Validate(result.text, content)
    if problem ~= nil then
        return contentmapper.NewSourceFiles(), problem
    end
    local virtualExtension = result.virtualExtension
    if not contentmapper.IsSupportedVirtualExtension(virtualExtension) then
        return contentmapper.NewSourceFiles(), contentmapper.NewTransformError(TransformErrorKind.Response, nil)
    end
    local baseParseOptions = parseOptions
    local virtualFileName = baseParseOptions.fileName .. virtualExtension
    parseOptions = copyParseOptions(baseParseOptions, nil, nil, contentmapper.isModuleVirtualExtension(virtualExtension))
    local sourceFile = parser.ParseSourceFile(parseOptions, result.text, core.GetScriptKindFromFileName(virtualFileName))
    if core.Len(result.diagnostics) > 0 then
        -- The runner produces diagnostics without a source file (it doesn't have one yet); associate
        -- them with the file now so they are reported against it.
        for _, diagnostic in ipairs(result.diagnostics) do
            diagnostic:SetFile(sourceFile)
        end
        sourceFile:SetDiagnostics(core.AppendAll(core.Slice(sourceFile:Diagnostics(), 0), result.diagnostics))
    end
    local files = contentmapper.NewSourceFiles(sourceFile, {})
    for i1, supplemental in ipairs(result.supplemental or {}) do
        local i = i1 - 1
        if supplemental.mappings == nil then
            return contentmapper.NewSourceFiles(), contentmapper.NewTransformError(TransformErrorKind.Mappings, nil)
        end
        problem = supplemental.mappings:Validate(supplemental.text, content)
        if problem ~= nil then
            return contentmapper.NewSourceFiles(), problem
        end
        if not contentmapper.IsSupportedVirtualExtension(supplemental.virtualExtension) then
            return contentmapper.NewSourceFiles(), contentmapper.NewTransformError(TransformErrorKind.Response, nil)
        end
        local suffix = "." .. string.format("%d", i) .. supplemental.virtualExtension
        local supplementalOptions = copyParseOptions(
            baseParseOptions,
            baseParseOptions.fileName .. suffix,
            parseOptions.path .. suffix,
            contentmapper.isModuleVirtualExtension(supplemental.virtualExtension)
        )

        local file = parser.ParseSourceFile(supplementalOptions, supplemental.text, core.GetScriptKindFromFileName(supplementalOptions.fileName))

        files.supplemental[#files.supplemental + 1] = file
    end
    local mapperIdentity = mapper:Identity()
    sourceFile:SetContentMapperInfo({
        contentMapper = mapperIdentity,
        transformIdentity = transformIdentity,
        parseOptions = baseParseOptions,
        virtualFileName = virtualFileName,
        originalText = content,
        spanMap = result.mappings,
        diagnosticDirectives = result.diagnosticDirectives,
        supplementalSourceFiles = files.supplemental,
    })
    for i1, file in ipairs(files.supplemental) do
        local supplemental = result.supplemental[i1]
        file:SetContentMapperInfo({
            contentMapper = mapperIdentity,
            transformIdentity = transformIdentity,
            parseOptions = baseParseOptions,
            virtualFileName = file:FileName(),
            originalText = content,
            spanMap = supplemental.mappings,
            diagnosticDirectives = supplemental.diagnosticDirectives,
            canonicalSourceFile = sourceFile,
        })
    end
    return files, nil
end

function contentmapper.isModuleVirtualExtension(extension)
    return extension == tspath.ExtensionMts or extension == tspath.ExtensionCts or
        extension == tspath.ExtensionMjs or extension == tspath.ExtensionCjs
end

-- CheckSupplementalFileNameCollisions rejects compiler-assigned virtual filenames that name physical files.
function contentmapper.CheckSupplementalFileNameCollisions(files, fileExists)
    for _, file in ipairs(files.supplemental or {}) do
        if fileExists(file:FileName()) then
            return contentmapper.NewSupplementalFileCollisionError(file:FileName())
        end
    end
    return nil
end
