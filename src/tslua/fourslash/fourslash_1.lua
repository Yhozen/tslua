-- luacheck: ignore 211 421 423 431 432
local fourslash = require("tslua.fourslash")
local lsutil = require("tslua.ls.lsutil")
local stringutil = require("tslua.stringutil")
local diagnostics = require("tslua.diagnostics")
local project = require("tslua.project")
local repo = require("tslua.repo")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local ls = require("tslua.ls")
local json = require("tslua.json")
local spanmap = require("tslua.spanmap")
local vfstest = require("tslua.vfs.vfstest")
local bundled = require("tslua.bundled")
local lsptestutil = require("tslua.testutil.lsptestutil")
local jsonrpc = require("tslua.jsonrpc")
local baseline = require("tslua.testutil.baseline")
local debug = require("tslua.debug")
local tspath = require("tslua.tspath")
local tsbaseline = require("tslua.testutil.tsbaseline")
local lsconv = require("tslua.ls.lsconv")
local harnessutil = require("tslua.testutil.harnessutil")
local tsctests = require("tslua.execute.tsctests")
local gort = require("tslua.fourslash.goruntime")

local FourslashTest = {}
FourslashTest.__index = FourslashTest
fourslash.FourslashTest = FourslashTest

local scriptInfo = {}
scriptInfo.__index = scriptInfo
fourslash.scriptInfo = scriptInfo

local testConverters = {}
testConverters.__index = testConverters
fourslash.testConverters = testConverters

local fourslashDiagnostic = {}
fourslashDiagnostic.__index = fourslashDiagnostic
fourslash.fourslashDiagnostic = fourslashDiagnostic

local fourslashDiagnosticFile = {}
fourslashDiagnosticFile.__index = fourslashDiagnosticFile
fourslash.fourslashDiagnosticFile = fourslashDiagnosticFile

fourslash.rootDir = "/"

fourslash.showCodeLensLocationsCommandName = "typescript.showCodeLensLocations"

fourslash.callHierarchyItemDirection = fourslash.callHierarchyItemDirection or {}
fourslash.callHierarchyItemDirection.Root = 0
fourslash.callHierarchyItemDirection.Incoming = 1
fourslash.callHierarchyItemDirection.Outgoing = 2

-- testConverters embeds *lsconv.Converters: the Converters fields are copied (flattened) and its
-- methods are reached through the metatable chain.
setmetatable(testConverters, { __index = lsconv.Converters })

function fourslash.newTestConverters(converters)
    return gort.Embed(setmetatable({}, fourslash.testConverters), converters)
end

function testConverters:PositionToLineAndCharacter(script, position)
    local lspPosition, _ = self:ToLSPPosition(script, position)
    return lspPosition
end

function testConverters:LineAndCharacterToPosition(script, position)
    local positions = lsconv.FromLSPPosition(self, script, position, spanmap.Feature.All)
    debug.Assert(gort.len(positions) == 1, "fourslash script must have exactly one position projection")
    return positions[1].position
end

function fourslash.newScriptInfo(fileName, content)
    return setmetatable({ fileName = fileName, content = content, lineMap = lsconv.ComputeLSPLineStarts(content), version = 1 }, fourslash.scriptInfo)
end

function scriptInfo:editContent(change)
    self.content = change:ApplyTo(self.content)
    self.lineMap = lsconv.ComputeLSPLineStarts(self.content)
    self.version = self.version + 1
end

function scriptInfo:Text()
    return self.content
end

function scriptInfo:OriginalText()
    return self.content
end

function scriptInfo:SpanMap()
    return nil
end

function scriptInfo:FileName()
    return self.fileName
end

function scriptInfo:OriginalFileName()
    return self.fileName
end

function scriptInfo:GetLineContent(line)
    local numLines = gort.len(self.lineMap.lineStarts)
    if (line < 0) or (line >= numLines) then
        return ""
    end
    local start = self.lineMap.lineStarts[line + 1]
    local end_ = 0
    if (line + 1) < numLines then
        end_ = self.lineMap.lineStarts[(line + 1) + 1]
    else
        end_ = #self.content
    end
    return gort.strings.TrimRight(string.sub(self.content, start + 1, end_), "\r\n")
end

function fourslash.NewFourslash(t, capabilities, content)
    local _, testPath, _, _ = gort.runtime.Caller(1)
    return fourslash.newFourslash(t, content, { capabilities = capabilities, runExternalCode = false }, testPath)
end

function fourslash.NewFourslashWithOptions(t, content, options)
    local _, testPath, _, _ = gort.runtime.Caller(1)
    return fourslash.newFourslash(t, content, options, testPath)
end

function fourslash.newFourslash(t, content, options, testPath)
    if options == nil then
        options = { runExternalCode = false }
    end
    repo.SkipIfNoTypeScriptSubmodule(t)
    if not bundled.Embedded then
        -- Without embedding, we'd need to read all of the lib files out from disk into the MapFS.
        -- Just skip this for now.
        t:Skip("bundled files are not embedded")
    end
    local fileName = fourslash.getBaseFileNameFromTest(t) .. tspath.ExtensionTs
    local testfs = {}
    local scriptInfos = {}
    local testData = fourslash.ParseTestData(t, content, fileName)
    for i1, file in gort.ipairs(testData.files) do
        local filePath = tspath.GetNormalizedAbsolutePath(file.fileName, fourslash.rootDir)
        if not tspath.IsDynamicFileName(filePath) then
            testfs[filePath] = file.content
        end
        scriptInfos[filePath] = fourslash.newScriptInfo(filePath, file.content)
    end
    for link, target in gort.pairs(testData.symlinks) do
        local filePath = tspath.GetNormalizedAbsolutePath(link, fourslash.rootDir)
        testfs[filePath] = vfstest.Symlink(tspath.GetNormalizedAbsolutePath(target, fourslash.rootDir))
    end
    local compilerOptions = setmetatable({
        skipDefaultLibCheck = core.Tristate.TSTrue,
        target = core.ScriptTarget.LatestStandard,
        jsx = core.JsxEmit.Preserve,
        _ = setmetatable({}, core.noCopy),
        allowJs = 0,
        allowArbitraryExtensions = 0,
        allowImportingTsExtensions = 0,
        allowNonTsExtensions = 0,
        allowUmdGlobalAccess = 0,
        allowUnreachableCode = 0,
        allowUnusedLabels = 0,
        assumeChangesOnlyAffectDirectDependencies = 0,
        checkJs = 0,
        composite = 0,
        emitDeclarationOnly = 0,
        emitBOM = 0,
        emitDecoratorMetadata = 0,
        declaration = 0,
        declarationDir = "",
        declarationMap = 0,
        deduplicatePackages = 0,
        disableSizeLimit = 0,
        disableSourceOfProjectReferenceRedirect = 0,
        disableSolutionSearching = 0,
        disableReferencedProjectLoad = 0,
        erasableSyntaxOnly = 0,
        exactOptionalPropertyTypes = 0,
        experimentalDecorators = 0,
        forceConsistentCasingInFileNames = 0,
        isolatedModules = 0,
        isolatedDeclarations = 0,
        ignoreConfig = 0,
        ignoreDeprecations = "",
        importHelpers = 0,
        inlineSourceMap = 0,
        inlineSources = 0,
        init = 0,
        incremental = 0,
        jsxFactory = "",
        jsxFragmentFactory = "",
        jsxImportSource = "",
        libReplacement = 0,
        locale = "",
        mapRoot = "",
        module = 0,
        moduleResolution = 0,
        moduleDetection = 0,
        newLine = 0,
        noEmit = 0,
        noCheck = 0,
        noErrorTruncation = 0,
        noFallthroughCasesInSwitch = 0,
        noImplicitAny = 0,
        noImplicitThis = 0,
        noImplicitReturns = 0,
        noEmitHelpers = 0,
        noLib = 0,
        noPropertyAccessFromIndexSignature = 0,
        noUncheckedIndexedAccess = 0,
        noEmitOnError = 0,
        noUnusedLocals = 0,
        noUnusedParameters = 0,
        noResolve = 0,
        noImplicitOverride = 0,
        noUncheckedSideEffectImports = 0,
        outDir = "",
        preserveConstEnums = 0,
        preserveSymlinks = 0,
        project = "",
        resolveJsonModule = 0,
        resolvePackageJsonExports = 0,
        resolvePackageJsonImports = 0,
        removeComments = 0,
        rewriteRelativeImportExtensions = 0,
        reactNamespace = "",
        rootDir = "",
        skipLibCheck = 0,
        stableTypeOrdering = 0,
        strict = 0,
        strictBindCallApply = 0,
        strictBuiltinIteratorReturn = 0,
        strictFunctionTypes = 0,
        strictNullChecks = 0,
        strictPropertyInitialization = 0,
        stripInternal = 0,
        sourceMap = 0,
        sourceRoot = "",
        suppressOutputPathCheck = 0,
        traceResolution = 0,
        tsBuildInfoFile = "",
        useDefineForClassFields = 0,
        useUnknownInCatchVariables = 0,
        verbatimModuleSyntax = 0,
        allowSyntheticDefaultImports = 0,
        alwaysStrict = 0,
        baseUrl = "",
        downlevelIteration = 0,
        esModuleInterop = 0,
        outFile = "",
        configFilePath = "",
        noDtsResolution = 0,
        pathsBasePath = "",
        diagnostics = 0,
        extendedDiagnostics = 0,
        generateCpuProfile = "",
        generateTrace = "",
        listEmittedFiles = 0,
        listFiles = 0,
        explainFiles = 0,
        listFilesOnly = 0,
        noEmitForJsFiles = 0,
        preserveWatchOutput = 0,
        pretty = 0,
        version = 0,
        watch = 0,
        showConfig = 0,
        build = 0,
        help = 0,
        all = 0,
        runExternalCode = 0,
        pprofDir = "",
        singleThreaded = 0,
        quiet = 0,
    }, core.CompilerOptions)
    local harnessOptions = {
        useCaseSensitiveFileNames = true,
        currentDirectory = fourslash.rootDir,
        baselineFile = "",
        includeBuiltFile = "",
        fileName = "",
        noImplicitReferences = false,
        symlink = "",
        link = "",
        noTypesAndSymbols = false,
        fullEmitPaths = false,
        reportDiagnostics = false,
        captureSuggestions = false,
        typescriptVersion = "",
    }
    harnessutil.SetOptionsFromTestConfig(t, testData.globalOptions, compilerOptions, harnessOptions, fourslash.rootDir, true)
    do
        local commandLines = (testData.globalOptions["tsc"] or "")
        if commandLines ~= "" then
            for commandLine, _ in gort.strings.SplitSeq(commandLines, ",") do
                tsctests.GetFileMapWithBuild(testfs, gort.strings.Split(commandLine, " "))
            end
        end
    end
    harnessutil.SkipUnsupportedCompilerOptions(t, compilerOptions)
    local fsFromMap = vfstest.FromMap(testfs, harnessOptions.useCaseSensitiveFileNames)
    local fs = bundled.WrapFS(fsFromMap)
    local serverOpts = {
        err = gort.io.Discard,
        cwd = "/",
        fs = fs,
        defaultLibraryPath = bundled.LibPath(),
        parseCache = fourslash.parseCache,
        typingsLocation = "",
        progressDelay = 0,
    }
    if options.contentMapperSpawner ~= nil then
        serverOpts.spawn = function(...) return options.contentMapperSpawner:Spawn(...) end
    end
    local converters = fourslash.newTestConverters(lsconv.NewConverters(lsproto.PositionEncodingKind.UTF8, function(fileName)
        local scriptInfo, ok = gort.MapLookup(scriptInfos, fileName, nil)
        if not ok then
            return nil
        end
        return scriptInfo.lineMap
    end))
    local f = setmetatable({
        testData = testData,
        stateEnableFormatting = true,
        reportFormatOnTypeCrash = true,
        userPreferences = lsutil.NewDefaultUserPreferences(),
        vfs = fs,
        scriptInfos = scriptInfos,
        converters = converters,
        baselines = {},
        openFiles = {},
        semanticTokenTypes = fourslash.defaultSemanticTokenTypes(),
        semanticTokenModifiers = fourslash.defaultSemanticTokenModifiers(),
        currentCaretPosition = lsproto.Position({}),
        activeFilename = "",
        isStradaServer = false,
    }, fourslash.FourslashTest)
    local client, closeClient = lsptestutil.NewLSPClient(t, serverOpts, function(...) return f:handleServerRequest(...) end)
    f.client = client
    client:SetCompilerOptionsForInferredProjects(compilerOptions)
    f:initialize(t, options.capabilities, options.runExternalCode)
    if testData:isStateBaseliningEnabled() then
        f.stateBaseline = fourslash.newStateBaseline(fsFromMap)
    else
        for i5, file in gort.ipairs(testData.files) do
            if file.open then
                f:openFile(t, file.fileName)
            end
        end
        f.activeFilename = f.testData.files[1].fileName
    end
    return f, function()
        t:Helper()
        local err = closeClient()
        if err ~= nil then
            t:Errorf("goroutine error: %v", err)
        end
        f:verifyBaselines(t, testPath)
    end
end

function FourslashTest:handleServerRequest(_p7, req)
    local sw8 = req.method
    if sw8 == lsproto.Method.WorkspaceConfiguration then
        local params, err = lsproto.UnmarshalParams("*ConfigurationParams", req)
        if ((err ~= nil) or (params == nil)) or (params.items == nil) then
            return lsproto.NewResponseMessage(req.id, { self.userPreferences }, nil)
        end
        -- (nil sections are JSON nulls: Lua arrays cannot hold nil)
        local results = gort.makeSlice(gort.len(params.items), function() return json.Null end)
        for i9, item in gort.ipairs(params.items) do
            local i = i9 - 1
            if (item.section ~= nil) and (item.section == "js/ts") then
                results[i + 1] = gort.CloneStruct(self.userPreferences)
            end
        end
        do return lsproto.NewResponseMessage(req.id, results, nil) end
    elseif sw8 == lsproto.Method.ClientRegisterCapability then
        do return lsproto.NewResponseMessage(req.id, lsproto.Null, nil) end
    elseif sw8 == lsproto.Method.ClientUnregisterCapability then
        do return lsproto.NewResponseMessage(req.id, lsproto.Null, nil) end
    else
        do return lsproto.NewResponseMessage(req.id, nil, jsonrpc.NewResponseError(lsproto.ErrorCode.MethodNotFound, gort.fmt.Sprintf("Unknown method: %s", req.method))) end
    end
end

function fourslash.getBaseFileNameFromTest(t)
    local name = t:Name()
    name = core.LastOrNil(gort.strings.Split(name, "/"))
    name = gort.strings.TrimPrefix(name, "Test")
    name = stringutil.LowerFirstChar(name)
    local sw11 = name
    if sw11 == "callHierarchyFunctionAmbiguity1" then
        name = "callHierarchyFunctionAmbiguity.1"
    elseif sw11 == "callHierarchyFunctionAmbiguity2" then
        name = "callHierarchyFunctionAmbiguity.2"
    elseif sw11 == "callHierarchyFunctionAmbiguity3" then
        name = "callHierarchyFunctionAmbiguity.3"
    elseif sw11 == "callHierarchyFunctionAmbiguity4" then
        name = "callHierarchyFunctionAmbiguity.4"
    elseif sw11 == "callHierarchyFunctionAmbiguity5" then
        name = "callHierarchyFunctionAmbiguity.5"
    end
    return name
end

function FourslashTest:initialize(t, capabilities, runExternalCode)
    local initializationOptions = lsproto.InitializationOptions({ codeLensShowLocationsCommandName = fourslash.showCodeLensLocationsCommandName })
    if runExternalCode then
        initializationOptions.runExternalCode = true
    end
    local params = lsproto.InitializeParams({
        locale = "en-US",
        initializationOptions = lsproto.InitializationOptionsOrNull({ initializationOptions = initializationOptions }),
    })
    params.capabilities = fourslash.getCapabilitiesWithDefaults(capabilities)
    self.capabilities = params.capabilities
    local resp, _, ok = lsptestutil.SendRequest(t, self.client, lsproto.InitializeInfo, params)
    if not ok then
        t:Fatalf("Initialize request failed")
    end
    if resp:AsResponse().error ~= nil then
        t:Fatalf("Initialize request returned error: %s", resp:AsResponse().error:String())
    end
    lsptestutil.SendNotification(t, self.client, lsproto.InitializedInfo, lsproto.InitializedParams)
    -- Wait for the initial configuration exchange to complete
    -- The server will send workspace/configuration as part of handleInitialized
    -- (Go: <-f.client.Server.InitComplete(); here: run the server until it is idle)
    self.client:Drain()
end

function fourslash.defaultSemanticTokenTypes()
    return {
        lsproto.SemanticTokenType.Namespace,
        lsproto.SemanticTokenType.Class,
        lsproto.SemanticTokenType.Enum,
        lsproto.SemanticTokenType.Interface,
        lsproto.SemanticTokenType.Struct,
        lsproto.SemanticTokenType.TypeParameter,
        lsproto.SemanticTokenType.Type,
        lsproto.SemanticTokenType.Parameter,
        lsproto.SemanticTokenType.Variable,
        lsproto.SemanticTokenType.Property,
        lsproto.SemanticTokenType.EnumMember,
        lsproto.SemanticTokenType.Decorator,
        lsproto.SemanticTokenType.Event,
        lsproto.SemanticTokenType.Function,
        lsproto.SemanticTokenType.Method,
        lsproto.SemanticTokenType.Macro,
        lsproto.SemanticTokenType.Label,
        lsproto.SemanticTokenType.Comment,
        lsproto.SemanticTokenType.String,
        lsproto.SemanticTokenType.Keyword,
        lsproto.SemanticTokenType.Number,
        lsproto.SemanticTokenType.Regexp,
        lsproto.SemanticTokenType.Operator,
    }
end

function fourslash.defaultSemanticTokenModifiers()
    return {
        lsproto.SemanticTokenModifier.Declaration,
        lsproto.SemanticTokenModifier.Definition,
        lsproto.SemanticTokenModifier.Readonly,
        lsproto.SemanticTokenModifier.Static,
        lsproto.SemanticTokenModifier.Deprecated,
        lsproto.SemanticTokenModifier.Abstract,
        lsproto.SemanticTokenModifier.Async,
        lsproto.SemanticTokenModifier.Modification,
        lsproto.SemanticTokenModifier.Documentation,
        lsproto.SemanticTokenModifier.DefaultLibrary,
        "local",
    }
end

function fourslash.GetDefaultCapabilities()
    return lsproto.ClientCapabilities({
        general = lsproto.GeneralClientCapabilities({ positionEncodings = { lsproto.PositionEncodingKind.UTF8 } }),
        experimental = lsproto.ExperimentalClientCapabilities({ hoverVerbosityLevel = fourslash.ptrTrue }),
        textDocument = lsproto.TextDocumentClientCapabilities({
            completion = lsproto.CompletionClientCapabilities({
                completionItem = lsproto.ClientCompletionItemOptions({
                    snippetSupport = fourslash.ptrFalse,
                    commitCharactersSupport = fourslash.ptrTrue,
                    preselectSupport = fourslash.ptrTrue,
                    labelDetailsSupport = fourslash.ptrFalse,
                    insertReplaceSupport = fourslash.ptrTrue,
                    documentationFormat = { lsproto.MarkupKind.Markdown, lsproto.MarkupKind.PlainText },
                }),
                completionList = lsproto.CompletionListCapabilities({ itemDefaults = { "commitCharacters", "editRange" } }),
            }),
            diagnostic = lsproto.DiagnosticClientCapabilities({
                relatedInformation = fourslash.ptrTrue,
                tagSupport = lsproto.ClientDiagnosticsTagOptions({ valueSet = { lsproto.DiagnosticTag.Unnecessary, lsproto.DiagnosticTag.Deprecated } }),
            }),
            publishDiagnostics = lsproto.PublishDiagnosticsClientCapabilities({
                relatedInformation = fourslash.ptrTrue,
                tagSupport = lsproto.ClientDiagnosticsTagOptions({ valueSet = { lsproto.DiagnosticTag.Unnecessary, lsproto.DiagnosticTag.Deprecated } }),
            }),
            definition = lsproto.DefinitionClientCapabilities({ linkSupport = fourslash.ptrTrue }),
            typeDefinition = lsproto.TypeDefinitionClientCapabilities({ linkSupport = fourslash.ptrTrue }),
            implementation = lsproto.ImplementationClientCapabilities({ linkSupport = fourslash.ptrTrue }),
            hover = lsproto.HoverClientCapabilities({ contentFormat = { lsproto.MarkupKind.Markdown, lsproto.MarkupKind.PlainText } }),
            signatureHelp = lsproto.SignatureHelpClientCapabilities({
                signatureInformation = lsproto.ClientSignatureInformationOptions({
                    documentationFormat = { lsproto.MarkupKind.Markdown, lsproto.MarkupKind.PlainText },
                    parameterInformation = lsproto.ClientSignatureParameterInformationOptions({ labelOffsetSupport = fourslash.ptrTrue }),
                    activeParameterSupport = fourslash.ptrTrue,
                }),
                contextSupport = fourslash.ptrTrue,
            }),
            documentSymbol = lsproto.DocumentSymbolClientCapabilities({ hierarchicalDocumentSymbolSupport = fourslash.ptrTrue }),
            foldingRange = lsproto.FoldingRangeClientCapabilities({
                rangeLimit = 5000,
                foldingRangeKind = lsproto.ClientFoldingRangeKindOptions({
                    valueSet = {
                        lsproto.FoldingRangeKind.Comment,
                        lsproto.FoldingRangeKind.Imports,
                        lsproto.FoldingRangeKind.Region,
                    },
                }),
                foldingRange = lsproto.ClientFoldingRangeOptions({ collapsedText = fourslash.ptrTrue }),
            }),
        }),
        workspace = lsproto.WorkspaceClientCapabilities({
            configuration = fourslash.ptrTrue,
            fileOperations = lsproto.FileOperationClientCapabilities({ willRename = fourslash.ptrTrue }),
            workspaceEdit = lsproto.WorkspaceEditClientCapabilities({
                documentChanges = fourslash.ptrTrue,
                resourceOperations = { lsproto.ResourceOperationKind.Rename },
            }),
        }),
    })
end

function fourslash.GetDefaultCapabilitiesWithOptions(options)
    local capabilities = fourslash.GetDefaultCapabilities()
    if options == nil then
        return capabilities
    end
    if options.completionItem ~= nil then
        local target = capabilities.textDocument.completion.completionItem
        local completionItemOptions = options.completionItem
        if completionItemOptions.snippetSupport ~= nil then
            target.snippetSupport = completionItemOptions.snippetSupport
        end
        if completionItemOptions.commitCharactersSupport ~= nil then
            target.commitCharactersSupport = completionItemOptions.commitCharactersSupport
        end
        if completionItemOptions.documentationFormat ~= nil then
            target.documentationFormat = completionItemOptions.documentationFormat
        end
        if completionItemOptions.deprecatedSupport ~= nil then
            target.deprecatedSupport = completionItemOptions.deprecatedSupport
        end
        if completionItemOptions.preselectSupport ~= nil then
            target.preselectSupport = completionItemOptions.preselectSupport
        end
        if completionItemOptions.tagSupport ~= nil then
            target.tagSupport = completionItemOptions.tagSupport
        end
        if completionItemOptions.insertReplaceSupport ~= nil then
            target.insertReplaceSupport = completionItemOptions.insertReplaceSupport
        end
        if completionItemOptions.resolveSupport ~= nil then
            target.resolveSupport = completionItemOptions.resolveSupport
        end
        if completionItemOptions.insertTextModeSupport ~= nil then
            target.insertTextModeSupport = completionItemOptions.insertTextModeSupport
        end
        if completionItemOptions.labelDetailsSupport ~= nil then
            target.labelDetailsSupport = completionItemOptions.labelDetailsSupport
        end
    end
    return capabilities
end

function fourslash.getCapabilitiesWithDefaults(capabilities)
    local capabilitiesWithDefaults = lsproto.ClientCapabilities({})
    if capabilities ~= nil then
        capabilitiesWithDefaults = gort.CloneStruct(capabilities)
    end
    capabilitiesWithDefaults.general = lsproto.GeneralClientCapabilities({ positionEncodings = { lsproto.PositionEncodingKind.UTF8 } })
    if capabilitiesWithDefaults.experimental == nil then
        capabilitiesWithDefaults.experimental = fourslash.defaultExperimentalCapabilities
    end
    if capabilitiesWithDefaults.textDocument == nil then
        capabilitiesWithDefaults.textDocument = lsproto.TextDocumentClientCapabilities({})
    end
    if capabilitiesWithDefaults.textDocument.completion == nil then
        capabilitiesWithDefaults.textDocument.completion = fourslash.defaultCompletionCapabilities
    end
    if capabilitiesWithDefaults.textDocument.diagnostic == nil then
        capabilitiesWithDefaults.textDocument.diagnostic = fourslash.defaultDiagnosticCapabilities
    end
    if capabilitiesWithDefaults.textDocument.publishDiagnostics == nil then
        capabilitiesWithDefaults.textDocument.publishDiagnostics = fourslash.defaultPublishDiagnosticCapabilities
    end
    if capabilitiesWithDefaults.textDocument.semanticTokens == nil then
        capabilitiesWithDefaults.textDocument.semanticTokens = lsproto.SemanticTokensClientCapabilities({
            requests = lsproto.ClientSemanticTokensRequestOptions({ full = lsproto.BooleanOrClientSemanticTokensRequestFullDelta({ boolean = fourslash.ptrTrue }) }),
            tokenTypes = fourslash.defaultSemanticTokenTypes(),
            tokenModifiers = fourslash.defaultSemanticTokenModifiers(),
            formats = { lsproto.TokenFormat.Relative },
        })
    end
    if capabilitiesWithDefaults.workspace == nil then
        capabilitiesWithDefaults.workspace = lsproto.WorkspaceClientCapabilities({})
    end
    if capabilitiesWithDefaults.workspace.fileOperations == nil then
        capabilitiesWithDefaults.workspace.fileOperations = lsproto.FileOperationClientCapabilities({ willRename = fourslash.ptrTrue })
    end
    if capabilitiesWithDefaults.workspace.workspaceEdit == nil then
        capabilitiesWithDefaults.workspace.workspaceEdit = fourslash.defaultWorkspaceEditCapabilities
    end
    if capabilitiesWithDefaults.workspace.configuration == nil then
        capabilitiesWithDefaults.workspace.configuration = fourslash.ptrTrue
    end
    if capabilitiesWithDefaults.textDocument.definition == nil then
        capabilitiesWithDefaults.textDocument.definition = fourslash.defaultDefinitionCapabilities
    end
    if capabilitiesWithDefaults.textDocument.typeDefinition == nil then
        capabilitiesWithDefaults.textDocument.typeDefinition = fourslash.defaultTypeDefinitionCapabilities
    end
    if capabilitiesWithDefaults.textDocument.implementation == nil then
        capabilitiesWithDefaults.textDocument.implementation = fourslash.defaultImplementationCapabilities
    end
    if capabilitiesWithDefaults.textDocument.hover == nil then
        capabilitiesWithDefaults.textDocument.hover = fourslash.defaultHoverCapabilities
    end
    if capabilitiesWithDefaults.textDocument.signatureHelp == nil then
        capabilitiesWithDefaults.textDocument.signatureHelp = fourslash.defaultSignatureHelpCapabilities
    end
    if capabilitiesWithDefaults.textDocument.documentSymbol == nil then
        capabilitiesWithDefaults.textDocument.documentSymbol = fourslash.defaultDocumentSymbolCapabilities
    end
    if capabilitiesWithDefaults.textDocument.foldingRange == nil then
        capabilitiesWithDefaults.textDocument.foldingRange = fourslash.defaultFoldingRangeCapabilities
    end
    return capabilitiesWithDefaults
end

function fourslash.sendRequest(t, f, info, params)
    t:Helper()
    return fourslash.sendRequestAndBaselineWorker(t, f, info, params, true)
end

function fourslash.sendRequestAndBaselineWorker(t, f, info, params, baselineProjects)
    t:Helper()
    local prefix = f:getCurrentPositionPrefix()
    if baselineProjects then
        f:baselineState(t)
    end
    f:baselineRequestOrNotification(t, info.method, params)
    local resMsg, result, resultOk = lsptestutil.SendRequest(t, f.client, info, params)
    if baselineProjects then
        f:baselineState(t)
    end
    -- Go: case OnTypeFormatting: if !f.reportFormatOnTypeCrash { break }; fallthrough; default: ...
    if info.method ~= lsproto.Method.TextDocumentOnTypeFormatting or f.reportFormatOnTypeCrash then
        do
            if resMsg == nil then
                t:Fatalf(prefix .. "Nil response received for %s request", info.method)
            end
            local resp = resMsg:AsResponse()
            if resp.error ~= nil then
                t:Fatalf(prefix .. "%s request returned error: %s", info.method, resp.error:String())
            end
            if not resultOk then
                t:Fatalf(prefix .. "Unexpected %s response type: %T, error: %v", info.method, resp.result, resp.error)
            end
        end
    end
    return result
end

function fourslash.sendNotification(t, f, info, params)
    t:Helper()
    if info.method ~= lsproto.Method.TextDocumentDidChange then
        f:baselineState(t)
        f:updateState(info.method, params)
    end
    f:baselineRequestOrNotification(t, info.method, params)
    lsptestutil.SendNotification(t, f.client, info, params)
end

function FourslashTest:updateState(method, params)
    local sw13 = method
    if sw13 == lsproto.Method.TextDocumentDidOpen then
        self.openFiles[lsproto.DocumentUri_FileName(params.textDocument.uri)] = fourslash.Ignored
    elseif sw13 == lsproto.Method.TextDocumentDidClose then
        gort.delete(self.openFiles, lsproto.DocumentUri_FileName(params.textDocument.uri))
    end
end

function FourslashTest:GetOptions()
    return self.userPreferences
end

function FourslashTest:Configure(t, config)
    self.userPreferences = gort.CloneStruct(config)
    fourslash.sendNotification(t, self, lsproto.WorkspaceDidChangeConfigurationInfo, lsproto.DidChangeConfigurationParams({ settings = { ["js/ts"] = config } }))
end

function FourslashTest:ConfigureWithReset(t, config)
    local reset = nil
    local originalConfig = gort.CloneStruct(self.userPreferences)
    self:Configure(t, config)
    return function()
        self:Configure(t, originalConfig)
    end
end

function FourslashTest:GoToMarkerOrRange(t, markerOrRange)
    self:goToMarker(t, markerOrRange)
end

function FourslashTest:GoToMarker(t, markerName)
    local marker, ok = gort.MapLookup(self.testData.markerPositions, markerName, nil)
    if not ok then
        t:Fatalf("Marker '%s' not found", markerName)
    end
    self:goToMarker(t, marker)
end

function FourslashTest:goToMarker(t, markerOrRange)
    self:ensureActiveFile(t, markerOrRange:FileName())
    self:goToPosition(t, markerOrRange:LSPos())
    self.lastKnownMarkerName = markerOrRange:GetName()
end

function FourslashTest:GoToEOF(t)
    local script = self:getScriptInfo(self.activeFilename)
    local pos = #script.content
    local LSPPos = self.converters:PositionToLineAndCharacter(script, pos)
    self:goToPosition(t, LSPPos)
end

function FourslashTest:GoToBOF(t)
    self:goToPosition(t, lsproto.Position({ line = 0, character = 0 }))
end

function FourslashTest:GoToPosition(t, position)
    local script = self:getScriptInfo(self.activeFilename)
    local LSPPos = self.converters:PositionToLineAndCharacter(script, position)
    self:goToPosition(t, LSPPos)
end

function FourslashTest:goToPosition(t, position)
    self.currentCaretPosition = gort.CloneStruct(position)
    self.selectionEnd = nil
end

function FourslashTest:GoToEachMarker(t, markerNames, action)
    local markers = nil
    if gort.len(markers) == 0 then
        markers = self:Markers()
    else
        markers = gort.makeSlice(0, function() return nil end)
        for i14, name in gort.ipairs(markerNames) do
            local marker, ok = gort.MapLookup(self.testData.markerPositions, name, nil)
            if not ok then
                t:Fatalf("Marker '%s' not found", name)
            end
            markers = gort.append(markers, marker)
        end
    end
    for i16, marker in gort.ipairs(markers) do
        local i = i16 - 1
        self:goToMarker(t, marker)
        action(marker, i)
    end
end

function FourslashTest:GoToEachRange(t, action)
    local ranges = self:Ranges()
    for i18, rangeMarker in gort.ipairs(ranges) do
        self:goToPosition(t, rangeMarker.lsRange.start)
        action(t, rangeMarker)
    end
end

function FourslashTest:GoToRangeStart(t, rangeMarker)
    self:openFile(t, rangeMarker:FileName())
    self:goToPosition(t, rangeMarker.lsRange.start)
end

function FourslashTest:GoToSelect(t, startMarkerName, endMarkerName)
    local startMarker = self.testData.markerPositions[startMarkerName]
    if startMarker == nil then
        t:Fatalf("Start marker '%s' not found", startMarkerName)
    end
    local endMarker = self.testData.markerPositions[endMarkerName]
    if endMarker == nil then
        t:Fatalf("End marker '%s' not found", endMarkerName)
    end
    if startMarker:FileName() ~= endMarker:FileName() then
        t:Fatalf("Markers '%s' and '%s' are in different files", startMarkerName, endMarkerName)
    end
    self:ensureActiveFile(t, startMarker:FileName())
    self:goToPosition(t, startMarker.lsPosition)
    self.selectionEnd = endMarker.lsPosition
end

function FourslashTest:GoToSelectRange(t, rangeMarker)
    self:GoToRangeStart(t, rangeMarker)
    self.selectionEnd = rangeMarker.lsRange.end_
end

function FourslashTest:GoToFile(t, filename)
    filename = tspath.GetNormalizedAbsolutePath(filename, fourslash.rootDir)
    self:openFile(t, filename)
end

function FourslashTest:GoToFileNumber(t, index)
    if (index < 0) or (index >= gort.len(self.testData.files)) then
        t:Fatalf("File index %d out of range (0-%d)", index, gort.len(self.testData.files) - 1)
    end
    local filename = self.testData.files[index + 1].fileName
    self:openFile(t, filename)
end

function FourslashTest:Markers()
    return self.testData.markers
end

function FourslashTest:MarkerNames()
    do return core.MapFiltered(self.testData.markers, function(marker)
        if marker.name == nil then
            return "", false
        end
        return marker.name, true
    end) end
end

function FourslashTest:MarkerByName(t, name)
    return self.testData.markerPositions[name]
end

function FourslashTest:Ranges()
    return self.testData.ranges
end

function FourslashTest:getRangesInFile(fileName)
    local rangesInFile = nil
    for i20, rangeMarker in gort.ipairs(self.testData.ranges) do
        if rangeMarker:FileName() == fileName then
            rangesInFile = gort.append(rangesInFile, rangeMarker)
        end
    end
    return rangesInFile
end

function FourslashTest:ensureActiveFile(t, filename)
    if self.activeFilename ~= filename then
        do
            local _, ok = gort.MapLookup(self.openFiles, filename, nil)
            if not ok then
                self:openFile(t, filename)
            else
                self.activeFilename = filename
            end
        end
    end
end

function FourslashTest:CloseFileOfMarker(t, markerName)
    local marker, ok = gort.MapLookup(self.testData.markerPositions, markerName, nil)
    if not ok then
        t:Fatalf("Marker '%s' not found", markerName)
    end
    if self.activeFilename == marker:FileName() then
        self.activeFilename = ""
    end
    do
        local index = gort.slices.IndexFunc(self.testData.files, function(f)
            return f.fileName == marker:FileName()
        end)
        if index >= 0 then
            local testFile = self.testData.files[index + 1]
            self.scriptInfos[testFile.fileName] = fourslash.newScriptInfo(testFile.fileName, testFile.content)
        else
            gort.delete(self.scriptInfos, marker:FileName())
        end
    end
    fourslash.sendNotification(t, self, lsproto.TextDocumentDidCloseInfo, lsproto.DidCloseTextDocumentParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(marker:FileName()) }),
    }))
end

function FourslashTest:openFile(t, filename)
    local script = self:getScriptInfo(filename)
    if script == nil then
        do
            local content, ok = self.vfs:ReadFile(filename)
            if ok then
                script = fourslash.newScriptInfo(filename, content)
                self.scriptInfos[filename] = script
            else
                t:Fatalf("File %s not found in test data", filename)
            end
        end
    end
    self.activeFilename = filename
    fourslash.sendNotification(t, self, lsproto.TextDocumentDidOpenInfo, lsproto.DidOpenTextDocumentParams({
        textDocument = lsproto.TextDocumentItem({
            uri = lsconv.FileNameToDocumentURI(filename),
            languageId = fourslash.getLanguageKind(filename),
            text = script.content,
        }),
    }))
    self:baselineProjectsAfterNotification(t, filename)
end

function FourslashTest:FormatDocument(t, filename)
    if filename == "" then
        filename = self.activeFilename
    end
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentFormattingInfo, lsproto.DocumentFormattingParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(filename) }),
        options = self.userPreferences.formatCodeSettings:ToLSFormatOptions(),
    }))
    if result.textEdits == nil then
        return
    end
    self:applyTextEdits(t, result.textEdits)
end

function FourslashTest:FormatSelection(t, startMarkerName, endMarkerName)
    t:Helper()
    local startMarker, ok = gort.MapLookup(self.testData.markerPositions, startMarkerName, nil)
    if not ok then
        t:Fatalf("Marker '%s' not found", startMarkerName)
    end
    local endMarker
    endMarker, ok = gort.MapLookup(self.testData.markerPositions, endMarkerName, nil)
    if not ok then
        t:Fatalf("Marker '%s' not found", endMarkerName)
    end
    if startMarker:FileName() ~= endMarker:FileName() then
        t:Fatalf("Markers '%s' and '%s' are in different files", startMarkerName, endMarkerName)
    end
    local filename = startMarker:FileName()
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentRangeFormattingInfo, lsproto.DocumentRangeFormattingParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(filename) }),
        range = lsproto.Range({ start = startMarker.lsPosition, end_ = endMarker.lsPosition }),
        options = self.userPreferences.formatCodeSettings:ToLSFormatOptions(),
    }))
    if result.textEdits == nil then
        return
    end
    self:applyTextEdits(t, result.textEdits)
end

function FourslashTest:VerifyCurrentFileContent(t, expectedContent)
    t:Helper()
    local actualContent = self:getScriptInfo(self.activeFilename).content
    gort.assert.Equal(t, actualContent, expectedContent)
end

function FourslashTest:VerifyCurrentLineContent(t, expectedContent)
    t:Helper()
    local actualContent = self:getScriptInfo(self.activeFilename):GetLineContent(self.currentCaretPosition.line)
    gort.assert.Equal(t, actualContent, expectedContent, gort.fmt.Sprintf("\n  actual line: \"%s\"\nexpected line: \"%s\"\n", actualContent, expectedContent))
end

function FourslashTest:VerifyIndentation(t, numSpaces)
    t:Helper()
end

function fourslash.getLanguageKind(filename)
    if tspath.FileExtensionIsOneOf(filename, {
        tspath.ExtensionTs,
        tspath.ExtensionMts,
        tspath.ExtensionCts,
        tspath.ExtensionDmts,
        tspath.ExtensionDcts,
        tspath.ExtensionDts,
    }) then
        return lsproto.LanguageKind.TypeScript
    end
    if tspath.FileExtensionIsOneOf(filename, { tspath.ExtensionJs, tspath.ExtensionMjs, tspath.ExtensionCjs }) then
        return lsproto.LanguageKind.JavaScript
    end
    if tspath.FileExtensionIs(filename, tspath.ExtensionJsx) then
        return lsproto.LanguageKind.JavaScriptReact
    end
    if tspath.FileExtensionIs(filename, tspath.ExtensionTsx) then
        return lsproto.LanguageKind.TypeScriptReact
    end
    if tspath.FileExtensionIs(filename, tspath.ExtensionJson) then
        return lsproto.LanguageKind.JSON
    end
    return lsproto.LanguageKind.TypeScript
end

function FourslashTest:VerifyCompletions(t, markerInput, expected)
    t:Helper()
    local list = nil
    local ts22 = markerInput
    if type(ts22) == "string" then
        local marker = ts22
        self:GoToMarker(t, marker)
        list = self:verifyCompletionsWorker(t, expected)
    elseif gort.IsStruct(ts22, "tslua.fourslash", "Marker") then
        local marker = ts22
        self:goToMarker(t, marker)
        list = self:verifyCompletionsWorker(t, expected)
    elseif gort.IsSlice(ts22, function(e) return type(e) == "string" end) then
        local marker = ts22
        for i23, markerName in gort.ipairs(marker) do
            self:GoToMarker(t, markerName)
            self:verifyCompletionsWorker(t, expected)
        end
    elseif gort.IsSlice(ts22, function(e) return gort.IsStruct(e, "tslua.fourslash", "Marker") end) then
        local marker = ts22
        for i25, marker in gort.ipairs(marker) do
            self:goToMarker(t, marker)
            self:verifyCompletionsWorker(t, expected)
        end
    elseif ts22 == nil then
        local marker = ts22
        list = self:verifyCompletionsWorker(t, expected)
    else
        local marker = ts22
        t:Fatalf("Invalid marker input type: %T. Expected string, *Marker, []string, or []*Marker.", markerInput)
    end
    return self:verifyCompletionsActions(list)
end

function FourslashTest:verifyCompletionsActions(list)
    do return {
        andApplyCodeAction = function(t, expectedAction)
            local item = core.Find(list.items, function(item)
                if (item.label ~= expectedAction.name) or (item.data == nil) then
                    return false
                end
                local data = item.data
                if data.autoImport == nil then
                    return false
                end
                return data.autoImport.moduleSpecifier == expectedAction.source
            end)
            if item == nil then
                t:Fatalf("Code action '%s' from source '%s' not found in completions.", expectedAction.name, expectedAction.source)
            end
            item = self:resolveCompletionItem(t, item)
            gort.assert.Check(t, (item.detail ~= nil) and gort.strings.Contains(item.detail, expectedAction.description), "Completion item detail does not contain expected description.")
            self:applyTextEdits(t, item.additionalTextEdits)
            gort.assert.Equal(t, self:getScriptInfo(self.activeFilename).content, expectedAction.newFileContent, gort.fmt.Sprintf("File content after applying code action '%s' did not match expected content.", expectedAction.name))
        end,
        andHasNoCodeAction = function(t, unexpectedAction)
            local item = core.Find(list.items, function(item)
                if (item.label ~= unexpectedAction.name) or (item.data == nil) then
                    return false
                end
                local data = item.data
                if data.autoImport == nil then
                    return false
                end
                return data.autoImport.moduleSpecifier == unexpectedAction.source
            end)
            if item ~= nil then
                t:Fatalf("Unexpected code action '%s' from source '%s' found in completions.", unexpectedAction.name, unexpectedAction.source)
            end
        end,
    } end
end

function FourslashTest:verifyCompletionsWorker(t, expected)
    t:Helper()
    local userPreferences = nil
    if expected ~= nil then
        userPreferences = expected.userPreferences
    end
    local prefix = self:getCurrentPositionPrefix()
    local list = self:getCompletions(t, userPreferences)
    self:verifyCompletionsResult(t, list, expected, prefix)
    return list
end

function FourslashTest:GetCompletions(t, userPreferences)
    t:Helper()
    return self:getCompletions(t, userPreferences)
end

function FourslashTest:VerifyJSDocCompletion(t, markerInput, expectedOffset, expectedText, generateReturnInDocTemplate)
    t:Helper()
    self:goToMarkerInput(t, markerInput)
    local userPreferences = nil
    if generateReturnInDocTemplate ~= nil then
        local prefs = lsutil.NewDefaultUserPreferences()
        prefs.generateReturnInDocTemplate = core.BoolToTristate(generateReturnInDocTemplate)
        userPreferences = prefs
    end
    local list = self:getCompletions(t, userPreferences)
    local item = fourslash.findJSDocCompletionItem(list)
    if item == nil then
        local script = self:getScriptInfo(self.activeFilename)
        local insertStart = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
        self:Insert(t, "/**")
        list = self:getCompletions(t, userPreferences)
        item = fourslash.findJSDocCompletionItem(list)
        self:editScriptAndUpdateMarkers(t, self.activeFilename, insertStart, insertStart + 3, "")
        self.currentCaretPosition = self.converters:PositionToLineAndCharacter(script, insertStart)
    end
    if list == nil then
        t:Fatalf("%sExpected JSDoc completion, got nil completion list.", self:getCurrentPositionPrefix())
    end
    if item == nil then
        t:Fatalf("%sExpected JSDoc completion item, got %#v.", self:getCurrentPositionPrefix(), list.items)
    end
    if (item.textEdit == nil) or (item.textEdit.insertReplaceEdit == nil) then
        t:Fatalf("%sExpected JSDoc completion to have insert/replace edit, got %#v.", self:getCurrentPositionPrefix(), item.textEdit)
    end
    gort.assert.Equal(t, item.textEdit.insertReplaceEdit.newText, expectedText, self:getCurrentPositionPrefix())
    local _ = expectedOffset
end

function FourslashTest:VerifyNoJSDocCompletion(t, markerInput)
    t:Helper()
    self:goToMarkerInput(t, markerInput)
    local list = self:getCompletions(t, nil)
    do
        local item = fourslash.findJSDocCompletionItem(list)
        if item ~= nil then
            t:Fatalf("%sDid not expect JSDoc completion item.", self:getCurrentPositionPrefix())
        end
    end
    local script = self:getScriptInfo(self.activeFilename)
    local insertStart = self.converters:LineAndCharacterToPosition(script, self.currentCaretPosition)
    self:Insert(t, "/**")
    list = self:getCompletions(t, nil)
    local item = fourslash.findJSDocCompletionItem(list)
    self:editScriptAndUpdateMarkers(t, self.activeFilename, insertStart, insertStart + 3, "")
    self.currentCaretPosition = self.converters:PositionToLineAndCharacter(script, insertStart)
    if item ~= nil then
        t:Fatalf("%sDid not expect JSDoc completion item.", self:getCurrentPositionPrefix())
    end
end

function fourslash.findJSDocCompletionItem(list)
    if list == nil then
        return nil
    end
    do return core.Find(list.items, function(item)
        return item.label == "/** */"
    end) end
end

function FourslashTest:goToMarkerInput(t, markerInput)
    t:Helper()
    local ts27 = markerInput
    if type(ts27) == "string" then
        local marker = ts27
        self:GoToMarker(t, marker)
    elseif gort.IsStruct(ts27, "tslua.fourslash", "Marker") then
        local marker = ts27
        self:goToMarker(t, marker)
    else
        local marker = ts27
        t:Fatalf("Invalid marker input type: %T. Expected string or *Marker.", markerInput)
    end
end

function FourslashTest:getCompletions(t, userPreferences)
    local defers28 = {}
    return gort.WithDefers(defers28, function()
        t:Helper()
        local params = lsproto.CompletionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            position = self.currentCaretPosition,
            context = lsproto.CompletionContext({}),
        })
        if userPreferences ~= nil then
            local preferences = gort.CloneStruct(userPreferences)
            preferences.formatCodeSettings = gort.CloneStruct(self.userPreferences.formatCodeSettings)
            local reset = self:ConfigureWithReset(t, preferences)
            defers28[#defers28 + 1] = reset
        end
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCompletionInfo, params)
        if result.list ~= nil then
            gort.slices.SortStableFunc(result.list.items, ls.CompareCompletionEntries)
        end
        return result.list
    end)
end

function FourslashTest:verifyCompletionsResult(t, actual, expected, prefix)
    if actual == nil then
        if not fourslash.isEmptyExpectedList(expected) then
            t:Fatal(prefix .. "Expected completion list but got nil.")
        end
        return
    elseif expected == nil then
        if gort.len(actual.items) == 0 then
            return
        end
        t:Fatalf(prefix .. "Expected nil completion list but got non-nil: %s", gort.cmp.Diff(actual, nil))
    end
    gort.assert.Equal(t, actual.isIncomplete, expected.isIncomplete, prefix .. "IsIncomplete mismatch")
    fourslash.verifyCompletionsItemDefaults(t, actual.itemDefaults, expected.itemDefaults, prefix .. "ItemDefaults mismatch: ")
    self:verifyCompletionsItems(t, prefix, actual.items, expected.items)
end

function fourslash.isEmptyExpectedList(expected)
    return (expected == nil) or (((((gort.len(expected.items.exact) == 0) and (gort.len(expected.items.includes) == 0)) and (gort.len(expected.items.excludes) == 0)) and (gort.len(expected.items.unsorted) == 0)))
end

function fourslash.verifyCompletionsItemDefaults(t, actual, expected, prefix)
    if actual == nil then
        if expected == nil then
            return
        end
        t:Fatalf(prefix .. "Expected non-nil completion item defaults but got nil: %s", gort.cmp.Diff(actual, nil))
    end
    if expected == nil then
        t:Fatalf(prefix .. "Expected nil completion item defaults but got non-nil: %s", gort.cmp.Diff(actual, nil))
    end
    fourslash.assertDeepEqual(t, actual.commitCharacters, expected.commitCharacters, prefix .. "CommitCharacters mismatch:")
    local ts29 = expected.editRange
    if gort.IsStruct(ts29, "tslua.fourslash", "EditRange") then
        local editRange = ts29
        if actual.editRange == nil then
            t:Fatal(prefix .. "Expected non-nil EditRange but got nil")
        end
        local expectedInsert = gort.CloneStruct(editRange.insert.lsRange)
        local expectedReplace = gort.CloneStruct(editRange.replace.lsRange)
        fourslash.assertDeepEqual(t, actual.editRange, lsproto.RangeOrEditRangeWithInsertReplace({
                editRangeWithInsertReplace = lsproto.EditRangeWithInsertReplace({ insert = expectedInsert, replace = expectedReplace }),
            }), prefix .. "EditRange mismatch:")
    elseif ts29 == nil then
        local editRange = ts29
        if actual.editRange ~= nil then
            t:Fatalf(prefix .. "Expected nil EditRange but got non-nil: %s", gort.cmp.Diff(actual.editRange, nil))
        end
    elseif ts29 == fourslash.Ignored then
        local editRange = ts29
    else
        local editRange = ts29
        t:Fatalf(prefix .. "Expected EditRange to be *EditRange or Ignored, got %T", editRange)
    end
end

function FourslashTest:verifyCompletionsItems(t, prefix, actual, expected)
    if expected.exact ~= nil then
        if expected.includes ~= nil then
            t:Fatal(prefix .. "Expected exact completion list but also specified 'includes'.")
        end
        if expected.excludes ~= nil then
            t:Fatal(prefix .. "Expected exact completion list but also specified 'excludes'.")
        end
        if expected.unsorted ~= nil then
            t:Fatal(prefix .. "Expected exact completion list but also specified 'unsorted'.")
        end
        if gort.len(actual) ~= gort.len(expected.exact) then
            t:Fatalf(prefix .. "Expected %d exact completion items but got %d.", gort.len(expected.exact), gort.len(actual))
        end
        if gort.len(actual) > 0 then
            self:verifyCompletionsAreExactly(t, prefix, actual, expected.exact)
        end
        return
    end
    local nameToActualItems = {}
    for i30, item in gort.ipairs(actual) do
        nameToActualItems[item.label] = gort.append(nameToActualItems[item.label], item)
    end
    if expected.unsorted ~= nil then
        if expected.includes ~= nil then
            t:Fatal(prefix .. "Expected unsorted completion list but also specified 'includes'.")
        end
        if expected.excludes ~= nil then
            t:Fatal(prefix .. "Expected unsorted completion list but also specified 'excludes'.")
        end
        for i32, item in gort.ipairs(expected.unsorted) do
            local ts34 = item
            if type(ts34) == "string" then
                local item = ts34
                local _, ok = gort.MapLookup(nameToActualItems, item, nil)
                if not ok then
                    t:Fatalf("%sLabel '%s' not found in actual items.", prefix, item)
                end
                gort.delete(nameToActualItems, item)
            elseif gort.IsStruct(ts34, "tslua.lsp.lsproto", "CompletionItem") then
                local item = ts34
                local actualItems, ok = gort.MapLookup(nameToActualItems, item.label, nil)
                if not ok then
                    t:Fatalf("%sLabel '%s' not found in actual items.", prefix, item.label)
                end
                local mismatchPrefix = ""
                if gort.len(actualItems) > 1 then
                    mismatchPrefix = ((prefix .. "No completion item match for label ") .. item.label) .. " (multiple candidates found): "
                else
                    mismatchPrefix = ((prefix .. "Includes completion item mismatch for label ") .. item.label) .. ": "
                end
                local itemIndex = core.FindIndex(actualItems, function(actualItem)
                            do
                                local err = self:verifyCompletionItem(t, prefix, actualItem, item)
                                if err ~= "" then
                                    mismatchPrefix = mismatchPrefix .. ("\n    " .. err)
                                    return false
                                end
                            end
                            return true
                        end)
                if itemIndex == (-1) then
                    t:Fatal(mismatchPrefix)
                end
                if gort.len(actualItems) == 1 then
                    gort.delete(nameToActualItems, item.label)
                elseif itemIndex == 0 then
                    nameToActualItems[item.label] = gort.slice(actualItems, 1, nil)
                elseif itemIndex == (gort.len(actualItems) - 1) then
                    nameToActualItems[item.label] = gort.slice(actualItems, 0, itemIndex)
                else
                    nameToActualItems[item.label] = gort.appendSlice(gort.slice(actualItems, 0, itemIndex), gort.slice(actualItems, itemIndex + 1, nil))
                end
            else
                local item = ts34
                t:Fatalf("%sExpected completion item to be a string or *lsproto.CompletionItem, got %T", prefix, item)
            end
        end
        if gort.len(expected.unsorted) ~= gort.len(actual) then
            local unmatched = gort.slices.Collect(gort.maps.Keys(nameToActualItems))
            t:Fatalf("%sAdditional completions found but not included in 'unsorted': %s", prefix, gort.strings.Join(unmatched, "\n"))
        end
        return
    end
    if expected.includes ~= nil then
        for i35, item in gort.ipairs(expected.includes) do
            local ts37 = item
            if type(ts37) == "string" then
                local item = ts37
                local _, ok = gort.MapLookup(nameToActualItems, item, nil)
                if not ok then
                    t:Fatalf("%sLabel '%s' not found in actual items.", prefix, item)
                end
            elseif gort.IsStruct(ts37, "tslua.lsp.lsproto", "CompletionItem") then
                local item = ts37
                local actualItems, ok = gort.MapLookup(nameToActualItems, item.label, nil)
                if not ok then
                    t:Fatalf("%sLabel '%s' not found in actual items.", prefix, item.label)
                end
                local mismatchPrefix = ""
                if gort.len(actualItems) > 1 then
                    mismatchPrefix = ((prefix .. "No completion item match for label ") .. item.label) .. " (multiple candidates found): "
                else
                    mismatchPrefix = ((prefix .. "Includes completion item mismatch for label ") .. item.label) .. ": "
                end
                local itemIndex = core.FindIndex(actualItems, function(actualItem)
                            do
                                local err = self:verifyCompletionItem(t, prefix, actualItem, item)
                                if err ~= "" then
                                    mismatchPrefix = mismatchPrefix .. ("\n    " .. err)
                                    return false
                                end
                            end
                            return true
                        end)
                if itemIndex == (-1) then
                    t:Fatal(mismatchPrefix)
                end
                if (gort.len(actualItems) == 1) or (itemIndex == (gort.len(actualItems) - 1)) then
                    gort.delete(nameToActualItems, item.label)
                else
                    nameToActualItems[item.label] = gort.slice(actualItems, itemIndex, nil)
                end
            else
                local item = ts37
                t:Fatalf("%sExpected completion item to be a string or *lsproto.CompletionItem, got %T", prefix, item)
            end
        end
    end
    for i38, exclude in gort.ipairs(expected.excludes) do
        do
            local _, ok = gort.MapLookup(nameToActualItems, exclude, nil)
            if ok then
                t:Fatalf("%sLabel '%s' should not be in actual items but was found.", prefix, exclude)
            end
        end
    end
end

function FourslashTest:verifyCompletionsAreExactly(t, prefix, actual, expected)
    local labelMismatchPrefix = prefix .. "Label mismatch"
    for i40, actualItem in gort.ipairs(actual) do
        local i = i40 - 1
        local ts42 = expected[i + 1]
        if type(ts42) == "string" then
            local expectedItem = ts42
            fourslash.assertDeepEqual(t, actualItem.label, expectedItem, labelMismatchPrefix)
        elseif gort.IsStruct(ts42, "tslua.lsp.lsproto", "CompletionItem") then
            local expectedItem = ts42
            fourslash.assertDeepEqual(t, actualItem.label, expectedItem.label, labelMismatchPrefix)
            do
                local err = self:verifyCompletionItem(t, (prefix .. "Completion item mismatch for label ") .. actualItem.label, actualItem, expectedItem)
                if err ~= "" then
                    t:Fatalf("%s:\n%s", (prefix .. "Completion item mismatch for label ") .. actualItem.label, err)
                end
            end
        else
            local expectedItem = ts42
            t:Fatalf("Expected completion item to be a string or *lsproto.CompletionItem, got %T", expectedItem)
        end
    end
end

function fourslash.ignorePaths(...)
    local paths = { ... }
    do return gort.cmp.FilterPath(function(p)
        return gort.slices.Contains(paths, gort.cmp.Path_Last(p):String())
    end, gort.cmp.Ignore()) end
end

function FourslashTest:verifyCompletionItem(t, prefix, actual, expected)
    t:Helper()
    local actualAutoImportFix, expectedAutoImportFix = nil, nil
    if actual.data ~= nil then
        actualAutoImportFix = actual.data.autoImport
    end
    if expected.data ~= nil then
        expectedAutoImportFix = expected.data.autoImport
    end
    if ((actualAutoImportFix == nil)) ~= ((expectedAutoImportFix == nil)) then
        return "Mismatch in auto-import data presence"
    end
    if ((expected.detail ~= nil) or (expected.documentation ~= nil)) or (actualAutoImportFix ~= nil) then
        actual = self:resolveCompletionItem(t, actual)
    end
    if actualAutoImportFix ~= nil then
        do
            local err = gort.cmp.Diff(actual, expected, fourslash.autoImportIgnoreOpts)
            if err ~= "" then
                return err
            end
        end
        if expected.additionalTextEdits == fourslash.AnyTextEdits then
            if not (((actual.additionalTextEdits ~= nil) and (gort.len(actual.additionalTextEdits) > 0))) then
                return "Expected non-nil AdditionalTextEdits for auto-import completion item"
            end
        elseif expected.additionalTextEdits == fourslash.NoTextEdits then
            if (actual.additionalTextEdits ~= nil) and (gort.len(actual.additionalTextEdits) > 0) then
                return "Expected no AdditionalTextEdits for auto-import completion item"
            end
        end
        if expected.labelDetails ~= nil then
            do
                local err = gort.cmp.Diff(actual.labelDetails, expected.labelDetails)
                if err ~= "" then
                    return gort.fmt.Sprintf("%s:\n%s", "LabelDetailsMismatch", err)
                end
            end
        end
        if actualAutoImportFix.moduleSpecifier ~= expectedAutoImportFix.moduleSpecifier then
            return "ModuleSpecifier mismatch"
        end
    else
        do
            local err = gort.cmp.Diff(actual, expected, fourslash.completionIgnoreOpts)
            if err ~= "" then
                return err
            end
        end
        if expected.additionalTextEdits == fourslash.AnyTextEdits then
            if (actual.additionalTextEdits == nil) or (gort.len(actual.additionalTextEdits) == 0) then
                return "Expected non-empty AdditionalTextEdits for completion item"
            end
        else
            do
                local err = gort.cmp.Diff(actual.additionalTextEdits, expected.additionalTextEdits)
                if err ~= "" then
                    return gort.fmt.Sprintf("%s:\n%s", "AdditionalTextEdits mismatch", err)
                end
            end
        end
    end
    if expected.filterText ~= nil then
        do
            local err = gort.cmp.Diff(actual.filterText, expected.filterText)
            if err ~= "" then
                return gort.fmt.Sprintf("%s:\n%s", "FilterText mismatch", err)
            end
        end
    end
    if expected.kind ~= nil then
        do
            local err = gort.cmp.Diff(actual.kind, expected.kind)
            if err ~= "" then
                return gort.fmt.Sprintf("%s:\n%s", "Kind mismatch", err)
            end
        end
    end
    do
        local err = gort.cmp.Diff(actual.sortText, core.OrElse(expected.sortText, ls.SortText.LocationPriority))
        if err ~= "" then
            return gort.fmt.Sprintf("%s:\n%s", "SortText mismatch", err)
        end
    end
    return ""
end

function FourslashTest:ResolveCompletionItem(t, item)
    t:Helper()
    return self:resolveCompletionItem(t, item)
end

function FourslashTest:resolveCompletionItem(t, item)
    local result = fourslash.sendRequest(t, self, lsproto.CompletionItemResolveInfo, item)
    return result
end

function fourslash.assertDeepEqual(t, actual, expected, prefix, ...)
    local opts = { ... }
    t:Helper()
    local diff = gort.cmp.Diff(actual, expected, gort.unpack(opts))
    if diff ~= "" then
        t:Fatalf("%s:\n%s", prefix, diff)
    end
end

function FourslashTest:VerifyCodeFix(t, options)
    local defers43 = {}
    gort.WithDefers(defers43, function()
        t:Helper()
        if options.userPreferences ~= nil then
            local reset = self:ConfigureWithReset(t, options.userPreferences)
            defers43[#defers43 + 1] = reset
        end
        local actions = self:getCodeFixActions(t)
        if gort.len(actions) == 0 then
            t:Fatalf("No code fixes returned.")
        end
        if options.index >= gort.len(actions) then
            t:Fatalf("Code fix index %d out of range (got %d fixes)", options.index, gort.len(actions))
        end
        local matchingAction = actions[options.index + 1]
        if matchingAction.title ~= options.description then
            local found = false
            for i44, action in gort.ipairs(actions) do
                if action.title == options.description then
                    matchingAction = action
                    found = true
                    break
                end
            end
            if not found then
                local titles = nil
                for i46, a in gort.ipairs(actions) do
                    titles = gort.append(titles, a.title)
                end
                t:Fatalf("No code fix with description %q at index %d found. Available fixes: %v", options.description, options.index, titles)
            end
        end
        local originalContent = self:getScriptInfo(self.activeFilename).content
        local expectedContent = options.newFileContent
        if options.newRangeContent ~= "" then
            local selection = self:getSelection()
            if selection:Pos() == selection:End() then
                local ranges = self:getRangesInFile(self.activeFilename)
                if gort.len(ranges) == 0 then
                    t:Fatal("Expected a selected range or fourslash range for NewRangeContent verification.")
                end
                selection = gort.CloneStruct(ranges[1].range)
            end
            expectedContent = (string.sub(originalContent, 1, selection:Pos()) .. options.newRangeContent) .. string.sub(originalContent, selection:End() + 1)
        end
        if options.applyChanges then
            if (matchingAction.edit ~= nil) and (matchingAction.edit.changes ~= nil) then
                local expectedURI = lsconv.FileNameToDocumentURI(self.activeFilename)
                for uri, edits in gort.pairs(matchingAction.edit.changes) do
                    if uri ~= expectedURI then
                        t:Fatalf("Code fix returned edits for unexpected URI %q (expected %q)", uri, expectedURI)
                    end
                    self:applyTextEdits(t, edits)
                end
            end
            local actual = self:getScriptInfo(self.activeFilename).content
            gort.assert.Equal(t, expectedContent, actual, "File content after applying code fix did not match expected content.")
        else
            local actual = self:getScriptInfo(self.activeFilename).content
            if (matchingAction.edit ~= nil) and (matchingAction.edit.changes ~= nil) then
                local expectedURI = lsconv.FileNameToDocumentURI(self.activeFilename)
                for uri, edits in gort.pairs(matchingAction.edit.changes) do
                    if uri ~= expectedURI then
                        t:Fatalf("Code fix returned edits for unexpected URI %q (expected %q)", uri, expectedURI)
                    end
                    actual = self:applyEditsToContent(actual, edits)
                end
            end
            gort.assert.Equal(t, expectedContent, actual, "File content after applying code fix did not match expected content.")
        end
    end)
end

function FourslashTest:VerifyRangeAfterCodeFix(t, expectedText, includeWhitespace, errorCode, index)
    t:Helper()
    local actions = self:getCodeFixActions(t, errorCode)
    if gort.len(actions) == 0 then
        t:Fatalf("No code fixes returned.")
    end
    if index >= gort.len(actions) then
        t:Fatalf("Code fix index %d out of range (got %d fixes)", index, gort.len(actions))
    end
    local action = actions[index + 1]
    local ranges = self:getRangesInFile(self.activeFilename)
    if gort.len(ranges) ~= 1 then
        t:Fatalf("Expected exactly one range in %q, got %d.", self.activeFilename, gort.len(ranges))
    end
    local edits = self:getCodeActionEditsForActiveFile(t, action)
    local updatedRange = self:updateTextRangeForTextEdits(ranges[1].range, edits)
    fourslash.assertValidTextRange(t, updatedRange, gort.fmt.Sprintf("Code fix %q replaced part of the expected range; unable to compute rangeAfterCodeFix result.", action.title))
    self:applyTextEdits(t, edits)
    local actualContent = self:getScriptInfo(self.activeFilename).content
    local actualText = string.sub(actualContent, updatedRange:Pos() + 1, updatedRange:End())
    if includeWhitespace then
        gort.assert.Equal(t, expectedText, actualText, "Range content after applying code fix did not match expected content.")
        return
    end
    actualText = fourslash.removeWhitespace(actualText)
    expectedText = fourslash.removeWhitespace(expectedText)
    gort.assert.Equal(t, expectedText, actualText, "Range content after applying code fix did not match expected content.")
end

function FourslashTest:getCodeActionEditsForActiveFile(t, action)
    t:Helper()
    if (action.edit == nil) or (action.edit.changes == nil) then
        t:Fatalf("Code fix %q did not return text edits.", action.title)
    end
    if gort.len(action.edit.changes) ~= 1 then
        t:Fatalf("Code fix %q returned edits for multiple files; rangeAfterCodeFix expects only the active file.", action.title)
    end
    local edits, ok = gort.MapLookup((action.edit.changes), lsconv.FileNameToDocumentURI(self.activeFilename), nil)
    if ok then
        return edits
    end
    t:Fatalf("Code fix %q did not return edits for active file %q.", action.title, self.activeFilename)
    error("unreachable", 0)
end

function FourslashTest:VerifyCodeFixAvailable(t, expectedDescriptions)
    t:Helper()
    local actions = self:getCodeFixActions(t)
    if expectedDescriptions == nil then
        if gort.len(actions) == 0 then
            t:Fatalf("Expected code fixes to be available, but got none.")
        end
        return
    end
    if gort.len(expectedDescriptions) == 0 then
        self:VerifyCodeFixNotAvailable(t)
        return
    end
    for i50, expected in gort.ipairs(expectedDescriptions) do
        local found = false
        for i52, action in gort.ipairs(actions) do
            if action.title == expected then
                found = true
                break
            end
        end
        if not found then
            local titles = nil
            for i54, a in gort.ipairs(actions) do
                titles = gort.append(titles, a.title)
            end
            t:Fatalf("Expected code fix with description %q not found. Available fixes: %v", expected, titles)
        end
    end
end

function FourslashTest:VerifyCodeFixNotAvailable(t, ...)
    local expected = { ... }
    t:Helper()
    local actions = self:getCodeFixActions(t)
    if gort.len(expected) == 0 then
        if gort.len(actions) == 0 then
            return
        end
        local titles = nil
        for i56, action in gort.ipairs(actions) do
            titles = gort.append(titles, action.title)
        end
        t:Fatalf("Expected no code fixes, but got: %v", titles)
    end
    for i58, title in gort.ipairs(expected) do
        for i60, action in gort.ipairs(actions) do
            if action.title == title then
                t:Fatalf("Expected code fix with description %q not to be available.", title)
            end
        end
    end
end

function FourslashTest:VerifyCodeFixAvailableExact(t, expectedDescriptions)
    t:Helper()
    local actions = self:getCodeFixActions(t)
    if gort.len(actions) ~= gort.len(expectedDescriptions) then
        local titles = nil
        for i62, a in gort.ipairs(actions) do
            titles = gort.append(titles, a.title)
        end
        t:Fatalf("Expected exactly %d code fixes, but got %d. Available fixes: %v", gort.len(expectedDescriptions), gort.len(actions), titles)
    end
    for i64, expected in gort.ipairs(expectedDescriptions) do
        local found = false
        for i66, action in gort.ipairs(actions) do
            if action.title == expected then
                found = true
                break
            end
        end
        if not found then
            local titles = nil
            for i68, a in gort.ipairs(actions) do
                titles = gort.append(titles, a.title)
            end
            t:Fatalf("Expected code fix with description %q not found. Available fixes: %v", expected, titles)
        end
    end
end

function FourslashTest:VerifyCodeFixAll(t, options)
    t:Helper()
    local actions = self:getAllQuickFixActions(t)
    if gort.len(actions) == 0 then
        t:Fatalf("No code fixes available for fixId %q", options.fixID)
    end
    local fixAllCandidates = nil
    for i70, action in gort.ipairs(actions) do
        if (action.diagnostics == nil) or (gort.len(action.diagnostics) == 0) then
            fixAllCandidates = gort.append(fixAllCandidates, action)
        end
    end
    local fixAllAction = nil
    if gort.len(fixAllCandidates) == 1 then
        fixAllAction = fixAllCandidates[1]
    else
        for i72, action in gort.ipairs(fixAllCandidates) do
            if gort.strings.Contains(gort.strings.ToLower(action.title), gort.strings.ToLower(options.fixID)) then
                fixAllAction = action
                break
            end
        end
    end
    if fixAllAction == nil then
        local titles = nil
        for i74, a in gort.ipairs(actions) do
            titles = gort.append(titles, a.title)
        end
        t:Fatalf("No fix-all code action found for fixId %q. Available fixes: %v", options.fixID, titles)
    end
    if (fixAllAction.edit ~= nil) and (fixAllAction.edit.changes ~= nil) then
        local expectedURI = lsconv.FileNameToDocumentURI(self.activeFilename)
        for uri, edits in gort.pairs(fixAllAction.edit.changes) do
            if uri ~= expectedURI then
                t:Fatalf("Fix-all code action returned edits for unexpected URI %q (expected %q)", uri, expectedURI)
            end
            self:applyTextEdits(t, edits)
        end
    end
    local actual = self:getScriptInfo(self.activeFilename).content
    gort.assert.Equal(t, options.newFileContent, actual, "File content after applying all code fixes did not match expected content.")
end

function FourslashTest:VerifySourceFixAll(t, expectedContent)
    t:Helper()
    local only = { lsproto.CodeActionKind.SourceFixAll }
    local params = lsproto.CodeActionParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        range = lsproto.Range({ start = self.currentCaretPosition, end_ = self.currentCaretPosition }),
        context = lsproto.CodeActionContext({ diagnostics = {}, only = only }),
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCodeActionInfo, params)
    if result.commandOrCodeActionArray == nil then
        t:Fatalf("No source.fixAll code actions returned")
    end
    local selected = nil
    for i77, item in gort.ipairs(result.commandOrCodeActionArray) do
        do
            if ((item.codeAction == nil) or (item.codeAction.kind == nil)) or (item.codeAction.kind ~= lsproto.CodeActionKind.SourceFixAll) then
                goto continue78
            end
            selected = item.codeAction
            break
        end
        ::continue78::
    end
    if selected == nil then
        t:Fatalf("No source.fixAll code action found")
    end
    if (selected.edit ~= nil) and (selected.edit.changes ~= nil) then
        local expectedURI = lsconv.FileNameToDocumentURI(self.activeFilename)
        for uri, edits in gort.pairs(selected.edit.changes) do
            if uri ~= expectedURI then
                t:Fatalf("source.fixAll returned edits for unexpected URI %q (expected %q)", uri, expectedURI)
            end
            self:applyTextEdits(t, edits)
        end
    end
    local actual = self:getScriptInfo(self.activeFilename).content
    gort.assert.Equal(t, expectedContent, actual, "File content after source.fixAll did not match expected content.")
end

function FourslashTest:getCodeFixActions(t, ...)
    local errorCode = { ... }
    t:Helper()
    local all = self:getAllQuickFixActions(t, gort.unpack(errorCode))
    local actions = nil
    for i80, action in gort.ipairs(all) do
        if (action.diagnostics ~= nil) and (gort.len(action.diagnostics) > 0) then
            actions = gort.append(actions, action)
        end
    end
    return actions
end

function FourslashTest:getAllQuickFixActions(t, ...)
    local errorCode = { ... }
    t:Helper()
    local diagParams = lsproto.DocumentDiagnosticParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
    })
    local diagResult = fourslash.sendRequest(t, self, lsproto.TextDocumentDiagnosticInfo, diagParams)
    local diagnostics_ = nil
    if (diagResult.fullDocumentDiagnosticReport ~= nil) and (diagResult.fullDocumentDiagnosticReport.items ~= nil) then
        diagnostics_ = diagResult.fullDocumentDiagnosticReport.items
    end
    if gort.len(diagnostics_) == 0 then
        return nil
    end
    local diagnostic = fourslash.selectCodeFixDiagnostic(diagnostics_, core.FirstOrNil(errorCode))
    if diagnostic == nil then
        return nil
    end
    local params = lsproto.CodeActionParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        range = lsproto.Range({ start = diagnostic.range.start, end_ = diagnostic.range.end_ }),
        context = lsproto.CodeActionContext({ diagnostics = diagnostics_ }),
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCodeActionInfo, params)
    local actions = nil
    if result.commandOrCodeActionArray ~= nil then
        for i82, item in gort.ipairs(result.commandOrCodeActionArray) do
            if ((item.codeAction ~= nil) and (item.codeAction.kind ~= nil)) and (item.codeAction.kind == lsproto.CodeActionKind.QuickFix) then
                actions = gort.append(actions, item.codeAction)
            end
        end
    end
    return actions
end

function FourslashTest:updateTextRangeForTextEdits(textRange, edits)
    local script = self:getScriptInfo(self.activeFilename)
    local spans = gort.makeSlice(0, function() return { start = 0, end_ = 0, length = 0 } end)
    for i84, edit in gort.ipairs(edits) do
        spans = gort.append(spans, {
                start = self.converters:LineAndCharacterToPosition(script, edit.range.start),
                end_ = self.converters:LineAndCharacterToPosition(script, edit.range.end_),
                length = #edit.newText,
            })
    end
    gort.slices.SortFunc(spans, function(a, b)
        return a.start - b.start
    end)
    local pos = textRange:Pos()
    local end_ = textRange:End()
    for i86, edit in gort.ipairs(spans) do
        local i = i86 - 1
        pos = fourslash.updatePositionForTextEdit(pos, edit.start, edit.end_, edit.length)
        end_ = fourslash.updatePositionForTextEdit(end_, edit.start, edit.end_, edit.length)
        local delta = edit.length - ((edit.end_ - edit.start))
        do
            local j = i + 1
            while j < gort.len(spans) do
                if spans[j + 1].start >= edit.start then
                    spans[j + 1].start = spans[j + 1].start + delta
                    spans[j + 1].end_ = spans[j + 1].end_ + delta
                end
                j = j + 1
            end
        end
    end
    return core.NewTextRange(pos, end_)
end

function FourslashTest:applyEditsToContent(content, edits)
    local script = self:getScriptInfo(self.activeFilename)
    gort.slices.SortFunc(edits, function(a, b)
        local aStart = self.converters:LineAndCharacterToPosition(script, a.range.start)
        local bStart = self.converters:LineAndCharacterToPosition(script, b.range.start)
        return aStart - bStart
    end)
    do
        local i = gort.len(edits) - 1
        while i >= 0 do
            local edit = edits[i + 1]
            local start = self.converters:LineAndCharacterToPosition(script, edit.range.start)
            local end_ = self.converters:LineAndCharacterToPosition(script, edit.range.end_)
            content = (string.sub(content, 1, start) .. edit.newText) .. string.sub(content, end_ + 1)
            i = i - 1
        end
    end
    return content
end

function FourslashTest:VerifyOrganizeImports(t, expectedContent, codeActionKind, preferences)
    local defers90 = {}
    gort.WithDefers(defers90, function()
        t:Helper()
        if preferences ~= nil then
            local reset = self:ConfigureWithReset(t, preferences)
            defers90[#defers90 + 1] = reset
        end
        local params = lsproto.CodeActionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            range = lsproto.Range({
                start = lsproto.Position({ line = 0, character = 0 }),
                end_ = self.converters:PositionToLineAndCharacter(self:getScriptInfo(self.activeFilename), #self:getScriptInfo(self.activeFilename).content),
            }),
            context = lsproto.CodeActionContext({ only = { codeActionKind } }),
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCodeActionInfo, params)
        if (result.commandOrCodeActionArray == nil) or (gort.len(result.commandOrCodeActionArray) == 0) then
            t:Fatalf("No organize imports code action found")
        end
        local organizeAction = nil
        for i91, item in gort.ipairs(result.commandOrCodeActionArray) do
            if ((item.codeAction ~= nil) and (item.codeAction.kind ~= nil)) and (item.codeAction.kind == codeActionKind) then
                organizeAction = item.codeAction
                break
            end
        end
        if organizeAction == nil then
            t:Fatalf("No organize imports code action found")
        end
        local expectedURI = lsconv.FileNameToDocumentURI(self.activeFilename)
        if (organizeAction.edit ~= nil) and (organizeAction.edit.changes ~= nil) then
            for uri, edits in gort.pairs(organizeAction.edit.changes) do
                if uri ~= expectedURI then
                    t:Fatalf("Organize imports changed unexpected file: %s (expected %s)", uri, expectedURI)
                end
                self:applyTextEdits(t, edits)
            end
        end
        local actualContent = self:getScriptInfo(self.activeFilename).content
        if actualContent ~= expectedContent then
            t:Fatalf([[
Organize imports result doesn't match.
Expected:
%s

Actual:
%s]], expectedContent, actualContent)
        end
    end)
end

function FourslashTest:findCompletionForCodeAction(t, items, description)
    t:Helper()
    do
        local item = core.Find(items, function(item)
            return (item.additionalTextEdits ~= nil) and (gort.len(item.additionalTextEdits) ~= 0)
        end)
        if item ~= nil then
            return item
        end
    end
    do return core.FirstNonNil(items, function(item)
        local resolvedItem = self:resolveCompletionItem(t, item)
        if ((resolvedItem == nil) or (resolvedItem.additionalTextEdits == nil)) or (gort.len(resolvedItem.additionalTextEdits) == 0) then
            return nil
        end
        if (description ~= "") and (((resolvedItem.detail == nil) or (not gort.strings.Contains(resolvedItem.detail, description)))) then
            return nil
        end
        return resolvedItem
    end) end
end

function FourslashTest:VerifyApplyCodeActionFromCompletion(t, markerName, options)
    t:Helper()
    self:GoToMarker(t, markerName)
    local userPreferences = nil
    if (options ~= nil) and (options.userPreferences ~= nil) then
        userPreferences = options.userPreferences
    else
        userPreferences = lsutil.NewDefaultUserPreferences()
    end
    local reset = self:ConfigureWithReset(t, userPreferences)
    gort.Defer(reset, function()
        local completionsList = self:getCompletions(t, nil)
        local items = core.Filter(completionsList.items, function(item)
            if (item.label ~= options.name) or (item.data == nil) then
                return false
            end
            local data = item.data
            if options.autoImportFix ~= nil then
                local moduleSpecifier = options.autoImportFix.moduleSpecifier
                if moduleSpecifier == "" then
                    moduleSpecifier = options.source
                end
                return (data.autoImport ~= nil) and (data.autoImport.moduleSpecifier == moduleSpecifier)
            end
            if ((data.autoImport == nil) and (data.source ~= "")) and (data.source == options.source) then
                return true
            end
            if (data.autoImport ~= nil) and (data.autoImport.moduleSpecifier == options.source) then
                return true
            end
            return false
        end)
        local item = self:findCompletionForCodeAction(t, items, options.description)
        if item == nil then
            t:Fatalf("Code action '%s' from source '%s' not found.", options.name, options.source)
        end
        self:applyTextEdits(t, item.additionalTextEdits)
        if options.newFileContent ~= nil then
            gort.assert.Equal(t, self:getScriptInfo(self.activeFilename).content, options.newFileContent, "File content after applying code action did not match expected content.")
        elseif options.newRangeContent ~= nil then
            t:Fatal("!!! TODO")
        end
    end)
end

function FourslashTest:VerifyImportFixAtPosition(t, expectedTexts, preferences)
    local defers94 = {}
    gort.WithDefers(defers94, function()
        t:Helper()
        local fileName = self.activeFilename
        local ranges = self:Ranges()
        local filteredRanges = nil
        for i95, r in gort.ipairs(ranges) do
            if r:FileName() == fileName then
                filteredRanges = gort.append(filteredRanges, r)
            end
        end
        if gort.len(filteredRanges) > 1 then
            t:Fatalf("Exactly one range should be specified in the testfile.")
        end
        local rangeMarker = nil
        if gort.len(filteredRanges) == 1 then
            rangeMarker = filteredRanges[1]
        end
        if preferences ~= nil then
            local reset = self:ConfigureWithReset(t, preferences)
            defers94[#defers94 + 1] = reset
        end
        local diagParams = lsproto.DocumentDiagnosticParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        })
        local diagResult = fourslash.sendRequest(t, self, lsproto.TextDocumentDiagnosticInfo, diagParams)
        local diagnostics_ = nil
        if (diagResult.fullDocumentDiagnosticReport ~= nil) and (diagResult.fullDocumentDiagnosticReport.items ~= nil) then
            diagnostics_ = diagResult.fullDocumentDiagnosticReport.items
        end
        local currentCaretPosition = gort.CloneStruct(self.currentCaretPosition)
        local params = lsproto.CodeActionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            range = lsproto.Range({ end_ = currentCaretPosition, start = currentCaretPosition }),
            context = lsproto.CodeActionContext({ diagnostics = diagnostics_ }),
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCodeActionInfo, params)
        local importActions = nil
        if result.commandOrCodeActionArray ~= nil then
            for i97, item in gort.ipairs(result.commandOrCodeActionArray) do
                if ((item.codeAction ~= nil) and (item.codeAction.kind ~= nil)) and (item.codeAction.kind == lsproto.CodeActionKind.QuickFix) then
                    if (item.codeAction.diagnostics ~= nil) and (gort.len(item.codeAction.diagnostics) > 0) then
                        importActions = gort.append(importActions, item.codeAction)
                    end
                end
            end
        end
        if gort.len(importActions) == 0 then
            if gort.len(expectedTexts) ~= 0 then
                t:Fatalf("No codefixes returned.")
            end
            return
        end
        local script = self:getScriptInfo(self.activeFilename)
        local originalContent = script.content
        local actualTextArray = gort.makeSlice(0, function() return "" end)
        for i99, action in gort.ipairs(importActions) do
            if (action.edit ~= nil) and (action.edit.changes ~= nil) then
                if gort.len(action.edit.changes) ~= 1 then
                    t:Fatalf("Expected exactly 1 change, got %d", gort.len(action.edit.changes))
                end
                for uri, changeEdits in gort.pairs(action.edit.changes) do
                    if uri ~= lsconv.FileNameToDocumentURI(self.activeFilename) then
                        t:Fatalf("Expected change to file %s, got %s", self.activeFilename, uri)
                    end
                    self:applyTextEdits(t, changeEdits)
                end
            end
            local text = ""
            if rangeMarker ~= nil then
                text = self:getRangeText(rangeMarker)
            else
                text = self:getScriptInfo(self.activeFilename).content
            end
            actualTextArray = gort.append(actualTextArray, text)
            self:editScriptAndUpdateMarkers(t, self.activeFilename, 0, #script.content, originalContent)
            self.currentCaretPosition = gort.CloneStruct(currentCaretPosition)
        end
        if gort.len(expectedTexts) ~= gort.len(actualTextArray) then
            local actualJoined = gort.NewBuilder()
            for i102, actual in gort.ipairs(actualTextArray) do
                local i = i102 - 1
                if i > 0 then
                    actualJoined:WriteString("\n\n")
                    actualJoined:WriteString(gort.strings.Repeat("-", 20))
                    actualJoined:WriteString("\n\n")
                end
                actualJoined:WriteString(actual)
            end
            t:Fatalf("Expected %d import fixes, got %d:\n\n%s", gort.len(expectedTexts), gort.len(actualTextArray), actualJoined:String())
        end
        for i104, expected in gort.ipairs(expectedTexts) do
            local i = i104 - 1
            local actual = actualTextArray[i + 1]
            gort.assert.Equal(t, expected, actual, gort.fmt.Sprintf("Import fix at index %d doesn't match.\n", i))
        end
    end)
end

function FourslashTest:VerifyImportFixModuleSpecifiers(t, markerName, expectedModuleSpecifiers, preferences)
    local defers106 = {}
    gort.WithDefers(defers106, function()
        t:Helper()
        self:GoToMarker(t, markerName)
        if preferences ~= nil then
            local reset = self:ConfigureWithReset(t, preferences)
            defers106[#defers106 + 1] = reset
        end
        local diagParams = lsproto.DocumentDiagnosticParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
        })
        local diagResult = fourslash.sendRequest(t, self, lsproto.TextDocumentDiagnosticInfo, diagParams)
        local diagnostics_ = nil
        if (diagResult.fullDocumentDiagnosticReport ~= nil) and (diagResult.fullDocumentDiagnosticReport.items ~= nil) then
            diagnostics_ = diagResult.fullDocumentDiagnosticReport.items
        end
        local params = lsproto.CodeActionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
            range = lsproto.Range({ start = self.currentCaretPosition, end_ = self.currentCaretPosition }),
            context = lsproto.CodeActionContext({ diagnostics = diagnostics_ }),
        })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentCodeActionInfo, params)
        local actualModuleSpecifiers = nil
        if result.commandOrCodeActionArray ~= nil then
            for i107, item in gort.ipairs(result.commandOrCodeActionArray) do
                if ((item.codeAction ~= nil) and (item.codeAction.kind ~= nil)) and (item.codeAction.kind == lsproto.CodeActionKind.QuickFix) then
                    if (item.codeAction.edit ~= nil) and (item.codeAction.edit.changes ~= nil) then
                        for _, changeEdits in gort.pairs(item.codeAction.edit.changes) do
                            for i110, edit in gort.ipairs(changeEdits) do
                                local moduleSpec = fourslash.extractModuleSpecifier(edit.newText)
                                if moduleSpec ~= "" then
                                    if not gort.slices.Contains(actualModuleSpecifiers, moduleSpec) then
                                        actualModuleSpecifiers = gort.append(actualModuleSpecifiers, moduleSpec)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if gort.len(actualModuleSpecifiers) ~= gort.len(expectedModuleSpecifiers) then
            t:Fatalf([[
Expected %d module specifiers, got %d.
Expected: %v
Actual: %v]], gort.len(expectedModuleSpecifiers), gort.len(actualModuleSpecifiers), expectedModuleSpecifiers, actualModuleSpecifiers)
        end
        for i112, expected in gort.ipairs(expectedModuleSpecifiers) do
            local i = i112 - 1
            if (i >= gort.len(actualModuleSpecifiers)) or (actualModuleSpecifiers[i + 1] ~= expected) then
                t:Fatalf([[
Module specifier mismatch at index %d.
Expected: %v
Actual: %v]], i, expectedModuleSpecifiers, actualModuleSpecifiers)
            end
        end
    end)
end

function fourslash.extractModuleSpecifier(text)
    do
        local idx = gort.strings.Index(text, "from \"")
        if idx ~= (-1) then
            local start = idx + 6
            do
                local end_ = gort.strings.Index(string.sub(text, start + 1), "\"")
                if end_ ~= (-1) then
                    return string.sub(text, start + 1, start + end_)
                end
            end
        end
    end
    do
        local idx = gort.strings.Index(text, "from '")
        if idx ~= (-1) then
            local start = idx + 6
            do
                local end_ = gort.strings.Index(string.sub(text, start + 1), "'")
                if end_ ~= (-1) then
                    return string.sub(text, start + 1, start + end_)
                end
            end
        end
    end
    do
        local idx = gort.strings.Index(text, "require(\"")
        if idx ~= (-1) then
            local start = idx + 9
            do
                local end_ = gort.strings.Index(string.sub(text, start + 1), "\"")
                if end_ ~= (-1) then
                    return string.sub(text, start + 1, start + end_)
                end
            end
        end
    end
    do
        local idx = gort.strings.Index(text, "require('")
        if idx ~= (-1) then
            local start = idx + 9
            do
                local end_ = gort.strings.Index(string.sub(text, start + 1), "'")
                if end_ ~= (-1) then
                    return string.sub(text, start + 1, start + end_)
                end
            end
        end
    end
    return ""
end

function FourslashTest:VerifyBaselineFindAllReferences(t, ...)
    local markers = { ... }
    local referenceLocations = self:lookupMarkersOrGetRanges(t, markers)
    for i114, markerOrRange in gort.ipairs(referenceLocations) do
        self:GoToMarkerOrRange(t, markerOrRange)
        local params = lsproto.ReferenceParams({
                textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                position = self.currentCaretPosition,
                context = lsproto.ReferenceContext({ includeDeclaration = true }),
            })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentReferencesInfo, params)
        self:addResultToBaseline(t, fourslash.baselineCommand.findAllReferencesCmd, self:getBaselineForLocationsWithFileContents(result.locations, {
                marker = markerOrRange,
                markerName = "/*FIND ALL REFS*/",
                endMarker = "",
                preserveResultOrder = false,
            }))
    end
end

function FourslashTest:VerifyBaselineVSFindAllReferences(t, ...)
    local markers = { ... }
    local referenceLocations = self:lookupMarkersOrGetRanges(t, markers)
    for i116, markerOrRange in gort.ipairs(referenceLocations) do
        self:GoToMarkerOrRange(t, markerOrRange)
        local params = lsproto.ReferenceParams({
                textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
                position = self.currentCaretPosition,
                context = lsproto.ReferenceContext({ includeDeclaration = true }),
            })
        local result = fourslash.sendRequest(t, self, lsproto.TextDocumentVSReferencesInfo, params)
        if (result.vsReferenceItems ~= nil) and (gort.len(result.vsReferenceItems) > 0) then
            local items = result.vsReferenceItems
            gort.slices.SortStableFunc(items, function(a, b)
                    local ap, bp = "", ""
                    if a.vsProjectName ~= nil then
                        ap = a.vsProjectName
                    end
                    if b.vsProjectName ~= nil then
                        bp = b.vsProjectName
                    end
                    if ap ~= bp then
                        if ap < bp then
                            return -1
                        end
                        return 1
                    end
                    if a.vsLocation.uri ~= b.vsLocation.uri then
                        if a.vsLocation.uri < b.vsLocation.uri then
                            return -1
                        end
                        return 1
                    end
                    if a.vsLocation.range.start.line ~= b.vsLocation.range.start.line then
                        return a.vsLocation.range.start.line - b.vsLocation.range.start.line
                    end
                    return a.vsLocation.range.start.character - b.vsLocation.range.start.character
                end)
            local idRemap = {}
            for i118, item in gort.ipairs(items) do
                local i = i118 - 1
                idRemap[item.vsId] = i
                item.vsId = i
            end
            for i120, item in gort.ipairs(items) do
                if item.vsDefinitionId ~= nil then
                    local newDefId = (idRemap[item.vsDefinitionId] or 0)
                    item.vsDefinitionId = newDefId
                end
            end
        end
        local locations = nil
        if result.vsReferenceItems ~= nil then
            for i122, item in gort.ipairs(result.vsReferenceItems) do
                locations = gort.append(locations, item.vsLocation)
            end
        end
        local fileContents = self:getBaselineForLocationsWithFileContents(locations, {
                marker = markerOrRange,
                markerName = "/*FIND ALL REFS*/",
                endMarker = "",
                preserveResultOrder = false,
            })
        do
            local jsonStr, err = core.StringifyJson(result, "", "  ")
            if err == nil then
                self:addResultToBaseline(t, fourslash.baselineCommand.vsFindAllReferencesCmd, (fileContents .. "\n\n") .. jsonStr)
            else
                t:Fatalf("Failed to stringify VS references result for baseline: %v", err)
            end
        end
    end
end

function FourslashTest:VerifyBaselineCodeLens(t, preferences)
    local defers124 = {}
    gort.WithDefers(defers124, function()
        if preferences ~= nil then
            local reset = self:ConfigureWithReset(t, preferences)
            defers124[#defers124 + 1] = reset
        end
        local foundAtLeastOneCodeLens = false
        for i125, openFile in gort.ipairs(gort.slices.Sorted(gort.maps.Keys(self.openFiles))) do
            do
                local params = lsproto.CodeLensParams({
                    textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(openFile) }),
                })
                local unresolvedCodeLensList = fourslash.sendRequest(t, self, lsproto.TextDocumentCodeLensInfo, params)
                if (unresolvedCodeLensList.codeLenses == nil) or (gort.len(unresolvedCodeLensList.codeLenses) == 0) then
                    goto continue126
                end
                foundAtLeastOneCodeLens = true
                for i127, unresolvedCodeLens in gort.ipairs(unresolvedCodeLensList.codeLenses) do
                    do
                        gort.assert.Assert(t, unresolvedCodeLens ~= nil)
                        local resolvedCodeLens = fourslash.sendRequest(t, self, lsproto.CodeLensResolveInfo, unresolvedCodeLens)
                        gort.assert.Assert(t, resolvedCodeLens ~= nil)
                        gort.assert.Assert(t, resolvedCodeLens.command ~= nil, "Expected resolved code lens to have a command.")
                        if #resolvedCodeLens.command.command > 0 then
                            gort.assert.Equal(t, resolvedCodeLens.command.command, fourslash.showCodeLensLocationsCommandName)
                        end
                        local locations = nil
                        do
                            local commandArgs = resolvedCodeLens.command.arguments
                            if commandArgs ~= nil then
                                local locs, err = fourslash.roundtripThroughJson("[]Location", (commandArgs)[3])
                                if err ~= nil then
                                    t:Fatalf("failed to re-encode code lens locations: %v", err)
                                end
                                locations = locs
                            end
                        end
                        local ranges = lsconv.FromLSPRange(self.converters, self:getScriptInfo(openFile), resolvedCodeLens.range, spanmap.Feature.All)
                        if gort.len(ranges) ~= 1 then
                            goto continue128
                        end
                        local codeLensRange = gort.CloneStruct(ranges[1].span)
                        self:addResultToBaseline(t, fourslash.baselineCommand.codeLensesCmd, self:getBaselineForLocationsWithFileContents(locations, {
                            marker = setmetatable({ fileName = openFile, lsRange = resolvedCodeLens.range, range = codeLensRange }, fourslash.RangeMarker),
                            markerName = ("/*CODELENS: " .. resolvedCodeLens.command.title) .. "*/",
                            endMarker = "",
                            preserveResultOrder = false,
                        }))
                    end
                    ::continue128::
                end
            end
            ::continue126::
        end
        if not foundAtLeastOneCodeLens then
            t:Fatalf("Expected at least one code lens in any open file, but got none.")
        end
    end)
end

function FourslashTest:MarkTestAsStradaServer()
    self.isStradaServer = true
end

function FourslashTest:VerifyBaselineGoToDefinition(t, includeOriginalSelectionRange, ...)
    local markers = { ... }
    self:verifyBaselineDefinitions(t, fourslash.baselineCommand.goToDefinitionCmd, "/*GOTO DEF*/", function(t, f, fileName, position)
        local params = lsproto.DefinitionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(f.activeFilename) }),
            position = f.currentCaretPosition,
        })
        return fourslash.sendRequest(t, f, lsproto.TextDocumentDefinitionInfo, params)
    end, includeOriginalSelectionRange, gort.unpack(markers))
end

function FourslashTest:verifyBaselineDefinitions(t, definitionCommand, definitionMarker, getDefinitions, includeOriginalSelectionRange, ...)
    local markers = { ... }
    local referenceLocations = self:lookupMarkersOrGetRanges(t, markers)
    for i129, markerOrRange in gort.ipairs(referenceLocations) do
        self:GoToMarkerOrRange(t, markerOrRange)
        local result = getDefinitions(t, self, self.activeFilename, self.currentCaretPosition)
        local resultAsSpans = nil
        local additionalSpan = nil
        if result.locations ~= nil then
            resultAsSpans = core.Map(result.locations, fourslash.locationToSpan)
        elseif result.location ~= nil then
            resultAsSpans = { fourslash.locationToSpan(result.location) }
        elseif result.definitionLinks ~= nil then
            local originRange = nil
            resultAsSpans = core.Map(result.definitionLinks, function(link)
                    if (originRange ~= nil) and (((link.originSelectionRange == nil) or (not gort.StructEqual(originRange, link.originSelectionRange)))) then
                        error("multiple different origin ranges in definition links", 0)
                    end
                    originRange = link.originSelectionRange
                    local contextSpan = nil
                    if (not gort.StructEqual(link.targetRange, link.targetSelectionRange)) and (not self.isStradaServer) then
                        contextSpan = link.targetRange
                    end
                    return { uri = link.targetUri, textSpan = link.targetSelectionRange, contextSpan = contextSpan }
                end)
            if (originRange ~= nil) and includeOriginalSelectionRange then
                additionalSpan = { uri = lsconv.FileNameToDocumentURI(self.activeFilename), textSpan = originRange }
            end
        end
        self:addResultToBaseline(t, definitionCommand, self:getBaselineForSpansWithFileContents(resultAsSpans, {
                marker = markerOrRange,
                markerName = definitionMarker,
                additionalSpan = additionalSpan,
                preserveResultOrder = definitionCommand == fourslash.baselineCommand.goToSourceDefinitionCmd,
                endMarker = "",
            }))
    end
end

function FourslashTest:VerifyBaselineGoToTypeDefinition(t, ...)
    local markers = { ... }
    self:verifyBaselineDefinitions(t, fourslash.baselineCommand.goToTypeDefinitionCmd, "/*GOTO TYPE*/", function(t, f, fileName, position)
        local params = lsproto.TypeDefinitionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(f.activeFilename) }),
            position = f.currentCaretPosition,
        })
        return fourslash.sendRequest(t, f, lsproto.TextDocumentTypeDefinitionInfo, params)
    end, false, gort.unpack(markers))
end

function FourslashTest:VerifyBaselineGoToSourceDefinition(t, ...)
    local markers = { ... }
    self:verifyBaselineDefinitions(t, fourslash.baselineCommand.goToSourceDefinitionCmd, "/*GOTO SOURCE DEF*/", function(t, f, fileName, position)
        local params = lsproto.TextDocumentPositionParams({
            textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(f.activeFilename) }),
            position = f.currentCaretPosition,
        })
        local result = fourslash.sendRequest(t, f, lsproto.CustomTextDocumentSourceDefinitionInfo, params)
        if result == nil then
            return lsproto.LocationOrLocationsOrDefinitionLinksOrNull({})
        end
        return result
    end, false, gort.unpack(markers))
end

function FourslashTest:VerifyBaselineWorkspaceSymbol(t, query)
    t:Helper()
    local result = fourslash.sendRequest(t, self, lsproto.WorkspaceSymbolInfo, lsproto.WorkspaceSymbolParams({ query = query }))
    local locationToText = {}
    local groupedRanges = {}
    local symbolInformations = nil
    if result.symbolInformations ~= nil then
        symbolInformations = result.symbolInformations
    end
    for i131, symbol in gort.ipairs(symbolInformations) do
        local uri = symbol.location.uri
        local span = fourslash.locationToSpan(symbol.location)
        groupedRanges:Add(uri, span)
        locationToText[span] = symbol
    end
    self:addResultToBaseline(t, "workspaceSymbol", self:getBaselineForGroupedSpansWithFileContents(groupedRanges, {
        getLocationData = function(span)
            return fourslash.symbolInformationToData(locationToText[span])
        end,
        markerName = "",
        endMarker = "",
        preserveResultOrder = false,
    }))
end

function FourslashTest:VerifyOutliningSpans(t, ...)
    local foldingRangeKind = { ... }
    local params = lsproto.FoldingRangeParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentFoldingRangeInfo, params)
    if result.foldingRanges == nil then
        t:Fatalf("Nil response received for folding range request")
    end
    local actualRanges = nil
    actualRanges = result.foldingRanges
    if gort.len(foldingRangeKind) > 0 then
        local targetKind = foldingRangeKind[1]
        local filtered = nil
        for i133, r in gort.ipairs(actualRanges) do
            if (r.kind ~= nil) and (r.kind == targetKind) then
                filtered = gort.append(filtered, r)
            end
        end
        actualRanges = filtered
    end
    if gort.len(actualRanges) ~= gort.len(self:Ranges()) then
        t:Fatalf("verifyOutliningSpans failed - expected total spans to be %d, but was %d", gort.len(self:Ranges()), gort.len(actualRanges))
    end
    gort.slices.SortFunc(self:Ranges(), function(a, b)
        return lsproto.ComparePositions(a:LSPos(), b:LSPos())
    end)
    for i135, expectedRange in gort.ipairs(self:Ranges()) do
        local i = i135 - 1
        local actualRange = actualRanges[i + 1]
        local startPos = lsproto.Position({ line = actualRange.startLine, character = actualRange.startCharacter })
        local endPos = lsproto.Position({ line = actualRange.endLine, character = actualRange.endCharacter })
        if (lsproto.ComparePositions(startPos, expectedRange.lsRange.start) ~= 0) or (lsproto.ComparePositions(endPos, expectedRange.lsRange.end_) ~= 0) then
            t:Fatalf([[
verifyOutliningSpans failed - span %d has invalid positions:
  actual: start (%d,%d), end (%d,%d)
  expected: start (%d,%d), end (%d,%d)]], i + 1, actualRange.startLine, actualRange.startCharacter, actualRange.endLine, actualRange.endCharacter, expectedRange.lsRange.start.line, expectedRange.lsRange.start.character, expectedRange.lsRange.end_.line, expectedRange.lsRange.end_.character)
        end
    end
end

function FourslashTest:VerifyFoldingRangeLines(t, expected)
    local params = lsproto.FoldingRangeParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentFoldingRangeInfo, params)
    if result.foldingRanges == nil then
        t:Fatalf("Nil response received for folding range request")
    end
    local actualRanges = result.foldingRanges
    if gort.len(actualRanges) ~= gort.len(expected) then
        t:Fatalf("verifyFoldingRangeLines failed - expected %d ranges, got %d", gort.len(expected), gort.len(actualRanges))
    end
    for i137, exp in gort.ipairs(expected) do
        local i = i137 - 1
        local got = actualRanges[i + 1]
        if (got.startLine ~= exp.startLine) or (got.endLine ~= exp.endLine) then
            t:Errorf("verifyFoldingRangeLines failed - range %d: expected (startLine=%d, endLine=%d), got (startLine=%d, endLine=%d)", i, exp.startLine, exp.endLine, got.startLine, got.endLine)
        end
    end
end

