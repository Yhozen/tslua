local contentmappertest = require("tslua.testutil.contentmappertest")
local jsonrpc = require("tslua.jsonrpc")

contentmappertest.TransformingMapper = "compiler-test-mapper"
contentmappertest.VerbatimMapper = "verbatim-mapper"
contentmappertest.ModuleVerbatimMapper = "module-verbatim-mapper"
contentmappertest.DynamicVerbatimMapper = "dynamic-verbatim-mapper"
contentmappertest.DiagnosticCodeCollisionMapper = "diagnostic-code-collision-mapper"
contentmappertest.FailingMapper = "failing-mapper"
contentmappertest.SynthesizingMapper = "synthesizing-mapper"
contentmappertest.ComponentMapper = "component-mapper"
contentmappertest.DuplicateMapper = "duplicate-mapper"
contentmappertest.LispMapper = "lisp-mapper"
contentmappertest.SupplementalMapper = "supplemental-mapper"
contentmappertest.SupplementalDiagnosticsMapper = "supplemental-diagnostics-mapper"
contentmappertest.SupplementalGlobalsMapper = "supplemental-globals-mapper"
contentmappertest.SupplementalModuleMapper = "supplemental-module-mapper"
contentmappertest.PrefixedSupplementalMapper = "prefixed-supplemental-mapper"
contentmappertest.UnmappedFoldingMapper = "unmapped-folding-mapper"

-- handlerConstructor: func(*ProjectLifecycle) ipc.Handler. Constructors are looked up lazily so the
-- handler types (defined in the other files of the package) need not be loaded yet.
function contentmappertest.mapperHandlers()
    local c = contentmappertest
    return {
        [c.TransformingMapper] = function() return c.NewHandler() end,
        [c.VerbatimMapper] = function() return c.newVerbatimHandler() end,
        [c.ModuleVerbatimMapper] = function() return c.newModuleVerbatimHandler() end,
        [c.DynamicVerbatimMapper] = function(lifecycle) return c.newDynamicVerbatimHandler(lifecycle) end,
        [c.DiagnosticCodeCollisionMapper] = function() return c.newDiagnosticCodeCollisionHandler() end,
        [c.FailingMapper] = function() return c.newFailingHandler() end,
        [c.SynthesizingMapper] = function() return c.newSynthesizingHandler() end,
        [c.ComponentMapper] = function() return c.newComponentHandler() end,
        [c.DuplicateMapper] = function() return c.newDuplicateHandler() end,
        [c.LispMapper] = function() return c.newLispHandler() end,
        [c.SupplementalMapper] = function() return c.newSupplementalHandler() end,
        [c.SupplementalDiagnosticsMapper] = function() return c.newSupplementalDiagnosticsHandler() end,
        [c.SupplementalGlobalsMapper] = function() return c.newSupplementalGlobalsHandler() end,
        [c.SupplementalModuleMapper] = function() return c.newSupplementalModuleHandler() end,
        [c.PrefixedSupplementalMapper] = function() return c.newPrefixedSupplementalHandler() end,
        [c.UnmappedFoldingMapper] = function() return c.newUnmappedFoldingHandler() end,
    }
end

-- handlerForMapper returns (ipc.Handler, err).
function contentmappertest.handlerForMapper(command, lifecycle)
    if command == nil or #command == 0 then
        return nil, jsonrpc.NewError("contentmappertest: empty mapper command")
    end
    local constructor = contentmappertest.mapperHandlers()[command[1]]
    if constructor == nil then
        -- fmt %v of a []string
        return nil, jsonrpc.NewError("contentmappertest: unknown mapper command [" .. table.concat(command, " ") .. "]")
    end
    return constructor(lifecycle), nil
end
