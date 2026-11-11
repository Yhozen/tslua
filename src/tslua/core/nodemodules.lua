local core = require("tslua.core")

-- require('module').builtinModules.filter(x => !x.match(/^(?:_|node:)/))
core.UnprefixedNodeCoreModules = {
    ["assert"] = true,
    ["assert/strict"] = true,
    ["async_hooks"] = true,
    ["buffer"] = true,
    ["child_process"] = true,
    ["cluster"] = true,
    ["console"] = true,
    ["constants"] = true,
    ["crypto"] = true,
    ["dgram"] = true,
    ["diagnostics_channel"] = true,
    ["dns"] = true,
    ["dns/promises"] = true,
    ["domain"] = true,
    ["events"] = true,
    ["fs"] = true,
    ["fs/promises"] = true,
    ["http"] = true,
    ["http2"] = true,
    ["https"] = true,
    ["inspector"] = true,
    ["inspector/promises"] = true,
    ["module"] = true,
    ["net"] = true,
    ["os"] = true,
    ["path"] = true,
    ["path/posix"] = true,
    ["path/win32"] = true,
    ["perf_hooks"] = true,
    ["process"] = true,
    ["punycode"] = true,
    ["querystring"] = true,
    ["readline"] = true,
    ["readline/promises"] = true,
    ["repl"] = true,
    ["stream"] = true,
    ["stream/consumers"] = true,
    ["stream/promises"] = true,
    ["stream/web"] = true,
    ["string_decoder"] = true,
    ["sys"] = true,
    ["timers"] = true,
    ["timers/promises"] = true,
    ["tls"] = true,
    ["trace_events"] = true,
    ["tty"] = true,
    ["url"] = true,
    ["util"] = true,
    ["util/types"] = true,
    ["v8"] = true,
    ["vm"] = true,
    ["wasi"] = true,
    ["worker_threads"] = true,
    ["zlib"] = true,
}

-- require('module').builtinModules.filter(x => x.startsWith('node:'))
core.ExclusivelyPrefixedNodeCoreModules = {
    ["node:quic"] = true,
    ["node:sea"] = true,
    ["node:sqlite"] = true,
    ["node:test"] = true,
    ["node:test/reporters"] = true,
}

local nodeCoreModulesCache = nil

-- Go sync.OnceValue: call core.NodeCoreModules() to get the map.
function core.NodeCoreModules()
    if nodeCoreModulesCache == nil then
        local nodeCoreModules = {}
        for unprefixed in pairs(core.UnprefixedNodeCoreModules) do
            nodeCoreModules[unprefixed] = true
            nodeCoreModules["node:" .. unprefixed] = true
        end
        for k, v in pairs(core.ExclusivelyPrefixedNodeCoreModules) do
            nodeCoreModules[k] = v
        end
        nodeCoreModulesCache = nodeCoreModules
    end
    return nodeCoreModulesCache
end

function core.NonRelativeModuleNameForTypingCache(moduleName)
    if core.NodeCoreModules()[moduleName] then
        return "node"
    end
    return moduleName
end
