local tsoptions = require("tslua.tsoptions")
local collections = require("tslua.collections")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

tsoptions.LibMap = collections.NewOrderedMapFromList({
    -- JavaScript only
    { key = "es5", value = "lib.es5.d.ts" },
    { key = "es6", value = "lib.es2015.d.ts" },
    { key = "es2015", value = "lib.es2015.d.ts" },
    { key = "es7", value = "lib.es2016.d.ts" },
    { key = "es2016", value = "lib.es2016.d.ts" },
    { key = "es2017", value = "lib.es2017.d.ts" },
    { key = "es2018", value = "lib.es2018.d.ts" },
    { key = "es2019", value = "lib.es2019.d.ts" },
    { key = "es2020", value = "lib.es2020.d.ts" },
    { key = "es2021", value = "lib.es2021.d.ts" },
    { key = "es2022", value = "lib.es2022.d.ts" },
    { key = "es2023", value = "lib.es2023.d.ts" },
    { key = "es2024", value = "lib.es2024.d.ts" },
    { key = "es2025", value = "lib.es2025.d.ts" },
    { key = "esnext", value = "lib.esnext.d.ts" },
    -- Host only
    { key = "dom", value = "lib.dom.d.ts" },
    { key = "dom.iterable", value = "lib.dom.iterable.d.ts" },
    { key = "dom.asynciterable", value = "lib.dom.asynciterable.d.ts" },
    { key = "webworker", value = "lib.webworker.d.ts" },
    { key = "webworker.importscripts", value = "lib.webworker.importscripts.d.ts" },
    { key = "webworker.iterable", value = "lib.webworker.iterable.d.ts" },
    { key = "webworker.asynciterable", value = "lib.webworker.asynciterable.d.ts" },
    { key = "scripthost", value = "lib.scripthost.d.ts" },
    -- ES2015 and later By-feature options
    { key = "es2015.core", value = "lib.es2015.core.d.ts" },
    { key = "es2015.collection", value = "lib.es2015.collection.d.ts" },
    { key = "es2015.generator", value = "lib.es2015.generator.d.ts" },
    { key = "es2015.iterable", value = "lib.es2015.iterable.d.ts" },
    { key = "es2015.promise", value = "lib.es2015.promise.d.ts" },
    { key = "es2015.proxy", value = "lib.es2015.proxy.d.ts" },
    { key = "es2015.reflect", value = "lib.es2015.reflect.d.ts" },
    { key = "es2015.symbol", value = "lib.es2015.symbol.d.ts" },
    { key = "es2015.symbol.wellknown", value = "lib.es2015.symbol.wellknown.d.ts" },
    { key = "es2016.array.include", value = "lib.es2016.array.include.d.ts" },
    { key = "es2016.intl", value = "lib.es2016.intl.d.ts" },
    { key = "es2017.arraybuffer", value = "lib.es2017.arraybuffer.d.ts" },
    { key = "es2017.date", value = "lib.es2017.date.d.ts" },
    { key = "es2017.object", value = "lib.es2017.object.d.ts" },
    { key = "es2017.sharedmemory", value = "lib.es2017.sharedmemory.d.ts" },
    { key = "es2017.string", value = "lib.es2017.string.d.ts" },
    { key = "es2017.intl", value = "lib.es2017.intl.d.ts" },
    { key = "es2017.typedarrays", value = "lib.es2017.typedarrays.d.ts" },
    { key = "es2018.asyncgenerator", value = "lib.es2018.asyncgenerator.d.ts" },
    { key = "es2018.asynciterable", value = "lib.es2018.asynciterable.d.ts" },
    { key = "es2018.intl", value = "lib.es2018.intl.d.ts" },
    { key = "es2018.promise", value = "lib.es2018.promise.d.ts" },
    { key = "es2018.regexp", value = "lib.es2018.regexp.d.ts" },
    { key = "es2019.array", value = "lib.es2019.array.d.ts" },
    { key = "es2019.object", value = "lib.es2019.object.d.ts" },
    { key = "es2019.string", value = "lib.es2019.string.d.ts" },
    { key = "es2019.symbol", value = "lib.es2019.symbol.d.ts" },
    { key = "es2019.intl", value = "lib.es2019.intl.d.ts" },
    { key = "es2020.bigint", value = "lib.es2020.bigint.d.ts" },
    { key = "es2020.date", value = "lib.es2020.date.d.ts" },
    { key = "es2020.promise", value = "lib.es2020.promise.d.ts" },
    { key = "es2020.sharedmemory", value = "lib.es2020.sharedmemory.d.ts" },
    { key = "es2020.string", value = "lib.es2020.string.d.ts" },
    { key = "es2020.symbol.wellknown", value = "lib.es2020.symbol.wellknown.d.ts" },
    { key = "es2020.intl", value = "lib.es2020.intl.d.ts" },
    { key = "es2020.number", value = "lib.es2020.number.d.ts" },
    { key = "es2021.promise", value = "lib.es2021.promise.d.ts" },
    { key = "es2021.string", value = "lib.es2021.string.d.ts" },
    { key = "es2021.weakref", value = "lib.es2021.weakref.d.ts" },
    { key = "es2021.intl", value = "lib.es2021.intl.d.ts" },
    { key = "es2022.array", value = "lib.es2022.array.d.ts" },
    { key = "es2022.error", value = "lib.es2022.error.d.ts" },
    { key = "es2022.intl", value = "lib.es2022.intl.d.ts" },
    { key = "es2022.object", value = "lib.es2022.object.d.ts" },
    { key = "es2022.string", value = "lib.es2022.string.d.ts" },
    { key = "es2022.regexp", value = "lib.es2022.regexp.d.ts" },
    { key = "es2023.array", value = "lib.es2023.array.d.ts" },
    { key = "es2023.collection", value = "lib.es2023.collection.d.ts" },
    { key = "es2023.intl", value = "lib.es2023.intl.d.ts" },
    { key = "es2024.arraybuffer", value = "lib.es2024.arraybuffer.d.ts" },
    { key = "es2024.collection", value = "lib.es2024.collection.d.ts" },
    { key = "es2024.object", value = "lib.es2024.object.d.ts" },
    { key = "es2024.promise", value = "lib.es2024.promise.d.ts" },
    { key = "es2024.regexp", value = "lib.es2024.regexp.d.ts" },
    { key = "es2024.sharedmemory", value = "lib.es2024.sharedmemory.d.ts" },
    { key = "es2024.string", value = "lib.es2024.string.d.ts" },
    { key = "es2025.collection", value = "lib.es2025.collection.d.ts" },
    { key = "es2025.float16", value = "lib.es2025.float16.d.ts" },
    { key = "es2025.intl", value = "lib.es2025.intl.d.ts" },
    { key = "es2025.iterator", value = "lib.es2025.iterator.d.ts" },
    { key = "es2025.promise", value = "lib.es2025.promise.d.ts" },
    { key = "es2025.regexp", value = "lib.es2025.regexp.d.ts" },
    -- Fallback for backward compatibility
    { key = "esnext.asynciterable", value = "lib.es2018.asynciterable.d.ts" },
    { key = "esnext.symbol", value = "lib.es2019.symbol.d.ts" },
    { key = "esnext.bigint", value = "lib.es2020.bigint.d.ts" },
    { key = "esnext.weakref", value = "lib.es2021.weakref.d.ts" },
    { key = "esnext.object", value = "lib.es2024.object.d.ts" },
    { key = "esnext.regexp", value = "lib.es2024.regexp.d.ts" },
    { key = "esnext.string", value = "lib.es2024.string.d.ts" },
    { key = "esnext.float16", value = "lib.es2025.float16.d.ts" },
    { key = "esnext.iterator", value = "lib.es2025.iterator.d.ts" },
    { key = "esnext.promise", value = "lib.es2025.promise.d.ts" },
    -- ESNext By-feature options
    { key = "esnext.array", value = "lib.esnext.array.d.ts" },
    { key = "esnext.collection", value = "lib.esnext.collection.d.ts" },
    { key = "esnext.date", value = "lib.esnext.date.d.ts" },
    { key = "esnext.decorators", value = "lib.esnext.decorators.d.ts" },
    { key = "esnext.disposable", value = "lib.esnext.disposable.d.ts" },
    { key = "esnext.error", value = "lib.esnext.error.d.ts" },
    { key = "esnext.intl", value = "lib.esnext.intl.d.ts" },
    { key = "esnext.sharedmemory", value = "lib.esnext.sharedmemory.d.ts" },
    { key = "esnext.temporal", value = "lib.esnext.temporal.d.ts" },
    { key = "esnext.typedarrays", value = "lib.esnext.typedarrays.d.ts" },
    -- Decorators
    { key = "decorators", value = "lib.decorators.d.ts" },
    { key = "decorators.legacy", value = "lib.decorators.legacy.d.ts" },
})

do
    local libs = {}
    for k in tsoptions.LibMap:Keys() do
        libs[#libs + 1] = k
    end
    tsoptions.Libs = libs
    local libFiles = {}
    for v in tsoptions.LibMap:Values() do
        libFiles[#libFiles + 1] = v
    end
    tsoptions.LibFilesSet = collections.NewSetFromItems(table.unpack(libFiles))
end

-- Returns fileName, ok.
function tsoptions.GetLibFileName(libName)
    -- checks if the libName is a valid lib name or file name and converts the lib name to the filename if needed
    libName = tspath.ToFileNameLowerCase(libName)
    if tsoptions.LibFilesSet:Has(libName) then
        return libName, true
    end
    local lib, ok = tsoptions.LibMap:Get(libName)
    if not ok then
        return "", false
    end
    return lib, true
end

tsoptions.moduleResolutionOptionMap = collections.NewOrderedMapFromList({
    { key = "node16", value = core.ModuleResolutionKind.Node16 },
    { key = "nodenext", value = core.ModuleResolutionKind.NodeNext },
    { key = "bundler", value = core.ModuleResolutionKind.Bundler },
    { key = "classic", value = core.ModuleResolutionKind.Classic },
    { key = "node", value = core.ModuleResolutionKind.Node10 },
    { key = "node10", value = core.ModuleResolutionKind.Node10 },
})

tsoptions.targetOptionMap = collections.NewOrderedMapFromList({
    { key = "es5", value = core.ScriptTarget.ES5 },
    { key = "es6", value = core.ScriptTarget.ES2015 },
    { key = "es2015", value = core.ScriptTarget.ES2015 },
    { key = "es2016", value = core.ScriptTarget.ES2016 },
    { key = "es2017", value = core.ScriptTarget.ES2017 },
    { key = "es2018", value = core.ScriptTarget.ES2018 },
    { key = "es2019", value = core.ScriptTarget.ES2019 },
    { key = "es2020", value = core.ScriptTarget.ES2020 },
    { key = "es2021", value = core.ScriptTarget.ES2021 },
    { key = "es2022", value = core.ScriptTarget.ES2022 },
    { key = "es2023", value = core.ScriptTarget.ES2023 },
    { key = "es2024", value = core.ScriptTarget.ES2024 },
    { key = "es2025", value = core.ScriptTarget.ES2025 },
    { key = "esnext", value = core.ScriptTarget.ESNext },
})

tsoptions.moduleOptionMap = collections.NewOrderedMapFromList({
    { key = "commonjs", value = core.ModuleKind.CommonJS },
    { key = "amd", value = core.ModuleKind.AMD },
    { key = "system", value = core.ModuleKind.System },
    { key = "umd", value = core.ModuleKind.UMD },
    { key = "es6", value = core.ModuleKind.ES2015 },
    { key = "es2015", value = core.ModuleKind.ES2015 },
    { key = "es2020", value = core.ModuleKind.ES2020 },
    { key = "es2022", value = core.ModuleKind.ES2022 },
    { key = "esnext", value = core.ModuleKind.ESNext },
    { key = "node16", value = core.ModuleKind.Node16 },
    { key = "node18", value = core.ModuleKind.Node18 },
    { key = "node20", value = core.ModuleKind.Node20 },
    { key = "nodenext", value = core.ModuleKind.NodeNext },
    { key = "preserve", value = core.ModuleKind.Preserve },
})

tsoptions.moduleDetectionOptionMap = collections.NewOrderedMapFromList({
    { key = "auto", value = core.ModuleDetectionKind.Auto },
    { key = "legacy", value = core.ModuleDetectionKind.Legacy },
    { key = "force", value = core.ModuleDetectionKind.Force },
})

tsoptions.jsxOptionMap = collections.NewOrderedMapFromList({
    { key = "preserve", value = core.JsxEmit.Preserve },
    { key = "react-native", value = core.JsxEmit.ReactNative },
    { key = "react-jsx", value = core.JsxEmit.ReactJSX },
    { key = "react-jsxdev", value = core.JsxEmit.ReactJSXDev },
    { key = "react", value = core.JsxEmit.React },
})

tsoptions.newLineOptionMap = collections.NewOrderedMapFromList({
    { key = "crlf", value = core.NewLineKind.CRLF },
    { key = "lf", value = core.NewLineKind.LF },
})

tsoptions.targetToLibMap = {
    [core.ScriptTarget.ESNext] = "lib.esnext.full.d.ts",
    [core.ScriptTarget.ES2025] = "lib.es2025.full.d.ts",
    [core.ScriptTarget.ES2024] = "lib.es2024.full.d.ts",
    [core.ScriptTarget.ES2023] = "lib.es2023.full.d.ts",
    [core.ScriptTarget.ES2022] = "lib.es2022.full.d.ts",
    [core.ScriptTarget.ES2021] = "lib.es2021.full.d.ts",
    [core.ScriptTarget.ES2020] = "lib.es2020.full.d.ts",
    [core.ScriptTarget.ES2019] = "lib.es2019.full.d.ts",
    [core.ScriptTarget.ES2018] = "lib.es2018.full.d.ts",
    [core.ScriptTarget.ES2017] = "lib.es2017.full.d.ts",
    [core.ScriptTarget.ES2016] = "lib.es2016.full.d.ts",
    [core.ScriptTarget.ES2015] = "lib.es6.d.ts", -- We don't use lib.es2015.full.d.ts due to breaking change.
}

function tsoptions.TargetToLibMap()
    return tsoptions.targetToLibMap
end

function tsoptions.GetDefaultLibFileName(options)
    local name = tsoptions.targetToLibMap[options:GetEmitScriptTarget()]
    if name == nil then
        return "lib.d.ts"
    end
    return name
end

tsoptions.watchFileEnumMap = collections.NewOrderedMapFromList({
    { key = "fixedpollinginterval", value = core.WatchFileKind.FixedPollingInterval },
    { key = "prioritypollinginterval", value = core.WatchFileKind.PriorityPollingInterval },
    { key = "dynamicprioritypolling", value = core.WatchFileKind.DynamicPriorityPolling },
    { key = "fixedchunksizepolling", value = core.WatchFileKind.FixedChunkSizePolling },
    { key = "usefsevents", value = core.WatchFileKind.UseFsEvents },
    { key = "usefseventsonparentdirectory", value = core.WatchFileKind.UseFsEventsOnParentDirectory },
})

tsoptions.watchDirectoryEnumMap = collections.NewOrderedMapFromList({
    { key = "usefsevents", value = core.WatchDirectoryKind.UseFsEvents },
    { key = "fixedpollinginterval", value = core.WatchDirectoryKind.FixedPollingInterval },
    { key = "dynamicprioritypolling", value = core.WatchDirectoryKind.DynamicPriorityPolling },
    { key = "fixedchunksizepolling", value = core.WatchDirectoryKind.FixedChunkSizePolling },
})

tsoptions.fallbackEnumMap = collections.NewOrderedMapFromList({
    { key = "fixedinterval", value = core.PollingKind.FixedInterval },
    { key = "priorityinterval", value = core.PollingKind.PriorityInterval },
    { key = "dynamicpriority", value = core.PollingKind.DynamicPriority },
    { key = "fixedchunksize", value = core.PollingKind.FixedChunkSize },
})
