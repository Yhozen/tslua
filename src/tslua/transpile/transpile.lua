-- Package transpile implements single-file JavaScript and declaration emit.
local transpile = require("tslua.transpile")
local compiler = require("tslua.compiler")
local core = require("tslua.core")
local debug = require("tslua.debug")
local tsoptions = require("tslua.tsoptions")
local tspath = require("tslua.tspath")
local vfstest = require("tslua.vfs.vfstest")

local Tristate = core.Tristate

-- Options configures single-file transpilation: { compilerOptions, fileName, reportDiagnostics }.
--
-- CompilerOptions are the base compiler options to use for the transpilation.
-- If nil, a default set of compiler options is used. Regardless of what is
-- provided, a number of options are unconditionally overridden; see
-- [TranspileModule] and [TranspileDeclaration].
--
-- FileName is the name given to the synthesized input file. It only needs to
-- be provided if the source text relies on characteristics implied by the
-- file's extension or path, e.g. its extension controls whether the file is
-- parsed as a script or module, whether JSX syntax is allowed, etc.
-- Defaults to "module.ts", or "module.tsx" if CompilerOptions.Jsx is set.
--
-- ReportDiagnostics indicates whether syntactic and compiler option
-- diagnostics should be included in the result. Regardless of this setting,
-- diagnostics produced while emitting (including declaration emit errors
-- such as those produced by isolated declarations) are always included.
function transpile.NewOptions(fields)
    fields = fields or {}
    return {
        compilerOptions = fields.compilerOptions,
        fileName = fields.fileName or "",
        reportDiagnostics = fields.reportDiagnostics or false,
    }
end

-- Output contains the emitted text and any requested diagnostics:
-- { outputText, diagnostics, sourceMapText }.

-- inputDirectory is the synthetic current directory used to root the
-- single input file created for transpilation.
transpile.inputDirectory = "/"

-- libDirectory is the synthetic directory that the barebones default library
-- file is placed in for declaration transpilation. See [barebonesLibContent].
transpile.libDirectory = "/lib"

-- Declaration emit works without a `lib`, but some local inferences you'd
-- expect to work won't without at least a minimal `lib` available, since the
-- checker will type inferred declarations as `any` without these defined.
-- Late bound symbol names, in particular, are impossible to define without
-- `Symbol` at least partially defined.
-- TODO: This should *probably* just load the full, real `lib` for the target.
transpile.barebonesLibContent = [[interface Boolean {}
interface Function {}
interface CallableFunction {}
interface NewableFunction {}
interface IArguments {}
interface Number {}
interface Object {}
interface RegExp {}
interface String {}
interface Array<T> { length: number; [n: number]: T; }
interface SymbolConstructor {
    (desc?: string | number): symbol;
    for(name: string): symbol;
    readonly toStringTag: symbol;
}
declare var Symbol: SymbolConstructor;
interface Symbol {
    readonly [Symbol.toStringTag]: string;
}]]

-- TranspileModule transpiles a single file of source text to JavaScript
-- using the specified options. If no compiler options are provided, a
-- default set of compiler options is used. It returns nil if the context is
-- canceled before emission completes.
--
-- Extra compiler options that are unconditionally used by this function are:
--   - IsolatedModules = true (unless VerbatimModuleSyntax is set, which makes
--     this option redundant)
--   - NoCheck = true
--   - NoResolve = true
--   - NoLib = true
--   - Declaration = false
--   - DeclarationMap = false
function transpile.TranspileModule(ctx, input, options)
    return transpile.transpileWorker(ctx, input, options, false --[[declaration]])
end

-- TranspileDeclaration creates a declaration (.d.ts) file from a single file
-- of source text using the specified options. If no compiler options are
-- provided, a default set of compiler options is used.
--
-- Note that, because only the single input file is available, the resulting
-- declaration file may differ from the one a full program type-check and
-- emit would produce.
--
-- Extra compiler options that are unconditionally used by this function are:
--   - IsolatedModules = true (unless VerbatimModuleSyntax is set, which makes
--     this option redundant)
--   - NoCheck = true
--   - NoResolve = true
--   - NoLib = false
--   - Declaration = true
--   - EmitDeclarationOnly = true
--   - IsolatedDeclarations = true
function transpile.TranspileDeclaration(ctx, input, options)
    return transpile.transpileWorker(ctx, input, options, true --[[declaration]])
end

function transpile.transpileWorker(ctx, input, options, declaration)
    options = transpile.NewOptions(options)
    local opts
    if options.compilerOptions ~= nil then
        opts = options.compilerOptions:Clone()
    else
        opts = core.NewCompilerOptions()
    end

    -- Clear options that do not apply to single-file transpilation.
    opts.incremental = Tristate.TSUnknown
    opts.declaration = Tristate.TSUnknown
    opts.emitDeclarationOnly = Tristate.TSUnknown
    opts.noEmit = Tristate.TSUnknown
    opts.lib = nil
    opts.outFile = ""
    opts.composite = Tristate.TSUnknown
    opts.tsBuildInfoFile = ""
    opts.paths = nil
    opts.rootDirs = nil
    opts.types = nil
    opts.allowImportingTsExtensions = Tristate.TSUnknown
    opts.noEmitOnError = Tristate.TSUnknown
    opts.declarationDir = ""

    -- Do not set `isolatedModules` if `verbatimModuleSyntax` was supplied, since
    -- it would be redundant.
    if not core.Tristate_IsTrue(opts.verbatimModuleSyntax) then
        opts.isolatedModules = Tristate.TSTrue
    end
    opts.noCheck = Tristate.TSTrue
    opts.noResolve = Tristate.TSTrue

    -- transpileModule/transpileDeclaration do not write anything to disk, so
    -- there's no need to verify there are no conflicts between input and
    -- output paths.
    opts.suppressOutputPathCheck = Tristate.TSTrue

    -- FileName can be a non-ts file.
    opts.allowNonTsExtensions = Tristate.TSTrue

    if declaration then
        opts.declaration = Tristate.TSTrue
        opts.emitDeclarationOnly = Tristate.TSTrue
        opts.isolatedDeclarations = Tristate.TSTrue
    else
        opts.declaration = Tristate.TSFalse
        opts.declarationMap = Tristate.TSFalse
    end

    -- When transpiling declarations, we need a lib. GetDefaultLibFileName will
    -- cause the barebones lib below to be used instead of a real lib.
    if declaration then
        opts.noLib = Tristate.TSFalse
    else
        opts.noLib = Tristate.TSTrue
    end

    -- If jsx is specified, then treat the file as .tsx.
    local fileName = options.fileName
    if fileName == "" then
        if opts.jsx ~= core.JsxEmit.None then
            fileName = "module.tsx"
        else
            fileName = "module.ts"
        end
    end
    local inputFileName = tspath.GetNormalizedAbsolutePath(fileName, transpile.inputDirectory)

    local files = {
        [inputFileName] = input,
    }

    -- Declaration emit needs a default lib to resolve global types (e.g.
    -- `Array`, `Symbol`); plain transpilation sets NoLib so none is read.
    -- The default lib name depends on the configured target.
    if declaration then
        local libFileName = tsoptions.GetDefaultLibFileName(opts)
        files[tspath.CombinePaths(transpile.libDirectory, libFileName)] = transpile.barebonesLibContent
    end

    local fs = vfstest.FromMap(files, true --[[useCaseSensitiveFileNames]])
    local host = compiler.NewCompilerHost(transpile.inputDirectory, fs, transpile.libDirectory, nil, nil, nil)

    local program = compiler.NewProgram(compiler.NewProgramOptions({
        config = tsoptions.newParsedCommandLineStruct({
            parsedConfig = tsoptions.NewParsedOptions({
                fileNames = { inputFileName },
                compilerOptions = opts,
            }),
        }),
        host = host,
    }))

    local allDiagnostics = nil
    if options.reportDiagnostics then
        local sourceFile = program:GetSourceFile(inputFileName)
        allDiagnostics = core.AppendAll(allDiagnostics, program:GetSyntacticDiagnostics(ctx, sourceFile))
        allDiagnostics = core.AppendAll(allDiagnostics, program:GetConfigFileParsingDiagnostics())
        allDiagnostics = core.AppendAll(allDiagnostics, program:GetProgramDiagnostics())
    end

    local emitOnly = compiler.EmitOnly.EmitAll
    if declaration then
        emitOnly = compiler.EmitOnly.Dts
    end

    local outputText, sourceMapText = "", ""
    local hasOutputText, hasSourceMapText = false, false
    local result = program:Emit(ctx, compiler.NewEmitOptions({
        emitOnly = emitOnly,
        forceEmit = declaration,
        writeFile = function(fileName1, text, _)
            if string.sub(fileName1, -4) == ".map" then
                debug.Assert(not hasSourceMapText, "Unexpected multiple source map outputs, file: " .. fileName1)
                sourceMapText = text
                hasSourceMapText = true
            else
                debug.Assert(not hasOutputText, "Unexpected multiple outputs, file: " .. fileName1)
                outputText = text
                hasOutputText = true
            end
            return nil
        end,
    }))
    if result == nil then
        return nil
    end

    -- Diagnostics produced during emit (e.g. isolated declaration errors) are
    -- always included, regardless of ReportDiagnostics.
    allDiagnostics = core.AppendAll(allDiagnostics, result.diagnostics)

    debug.Assert(hasOutputText, "Output generation failed")

    return {
        outputText = outputText,
        diagnostics = allDiagnostics,
        sourceMapText = sourceMapText,
    }
end
