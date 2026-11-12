local fswatch = {}
package.loaded["tslua.fswatch"] = fswatch
for k, v in pairs(require("tslua.fswatch.consts_generated")) do
    fswatch[k] = v
end
require("tslua.fswatch.event")
require("tslua.fswatch.debounce")
require("tslua.fswatch.walkdir")
require("tslua.fswatch.watcher")
-- Lua-only stat-polling backend (the native inotify/fanotify/FSEvents/kqueue/Windows backends
-- need syscalls and are not ported).
require("tslua.fswatch.poll")
return fswatch
