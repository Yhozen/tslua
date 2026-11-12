local project = require("tslua.project")

local FileChangeKind = project.FileChangeKind

project.excessiveChangeThreshold = 1000

function project.FileChangeKind_IsWatchKind(k)
    return k == FileChangeKind.WatchCreate or k == FileChangeKind.WatchChange or k == FileChangeKind.WatchDelete
end

-- FileChange: { kind, uri, version (Open/Change), content (Open), languageKind (Open),
--   changes []lsproto.TextDocumentContentChangePartialOrWholeDocument (Change) }
function project.NewFileChange(fields)
    return {
        kind = fields.kind,
        uri = fields.uri,
        version = fields.version or 0,
        content = fields.content or "",
        languageKind = fields.languageKind or "",
        changes = fields.changes,
    }
end

-- FileChangeSummary (see project.newFileChangeSummary):
--   opened: only one file can be opened at a time per request
--   reopened: set if a close and open occurred for the same file in a single batch of changes.
--   closed, changed: collections.Set of DocumentUri
--   created, deleted: only set when file watching is enabled
--   includesWatchChangeOutsideNodeModules: true if the summary includes a create, change, or delete watch
--     event of a file outside a node_modules directory.
--   invalidateAll: indicates that all cached file state should be discarded.

function project.FileChangeSummary_IsEmpty(f)
    return not f.invalidateAll and f.opened == "" and f.reopened == "" and f.closed:Len() == 0 and f.changed:Len() == 0 and f.created:Len() == 0 and f.deleted:Len() == 0
end

function project.FileChangeSummary_HasExcessiveWatchEvents(f)
    return f.invalidateAll or f.created:Len() + f.deleted:Len() + f.changed:Len() > project.excessiveChangeThreshold
end

function project.FileChangeSummary_HasExcessiveNonCreateWatchEvents(f)
    return f.invalidateAll or f.deleted:Len() + f.changed:Len() > project.excessiveChangeThreshold
end

-- mergeFileChangeSummary merges src into dst, combining their change sets.
function project.mergeFileChangeSummary(dst, src)
    if project.FileChangeSummary_IsEmpty(src) then
        return
    end
    if src.invalidateAll then
        dst.invalidateAll = true
    end
    for uri in pairs(project.setKeys(src.changed)) do
        dst.changed:Add(uri)
    end
    for uri in pairs(project.setKeys(src.created)) do
        dst.created:Add(uri)
    end
    for uri in pairs(project.setKeys(src.deleted)) do
        dst.deleted:Add(uri)
    end
    if src.includesWatchChangeOutsideNodeModules then
        dst.includesWatchChangeOutsideNodeModules = true
    end
end

