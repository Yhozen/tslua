local project = require("tslua.project")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")

local Session = project.Session or {}
Session.__index = Session
project.Session = Session

-- APIUpdate creates a new snapshot incorporating the given file changes and the
-- supplied API open/close request. The apiRequest may open or close projects and
-- files; opens are tracked in the snapshot (ref-counted) so they persist across
-- future updates, and closes release a previously taken ref. Even an empty
-- apiRequest ensures all API-opened projects and files are kept up to date.
-- Returns a ref'd snapshot (which the caller must Deref when done) and any error
-- encountered while applying the request, e.g. failing to load a project to open.
function Session:APIUpdate(ctx, apiFileChanges, apiRequest)
    self:cancelScheduledSnapshotUpdate()

    local fileChanges, overlays, ataChanges = self:flushChanges(ctx)
    project.mergeFileChangeSummary(fileChanges, apiFileChanges)

    local newSnapshot = self:updateSnapshotRef(ctx, overlays, project.newSnapshotChange({
        apiRequest = apiRequest,
        fileChanges = fileChanges,
        ataChanges = ataChanges,
    }))
    return newSnapshot, newSnapshot.apiError
end

-- APIUpdateTemporary creates a snapshot that layers a temporary in-memory content
-- override for a file on top of baseSnapshot.
-- The caller must retain baseSnapshot for the duration of this call.
-- An error is returned if the file name does not have a recognized script extension.
-- On success, the returned snapshot carries a single reference (the clone ref);
-- the caller must call snapshot.Deref(s) when done.
function Session:APIUpdateTemporary(ctx, baseSnapshot, uri, newText)
    local path = lsproto.DocumentUri_Path(uri, baseSnapshot:UseCaseSensitiveFileNames())

    local overlays = project.cloneMap(baseSnapshot.fs.overlays) or {}
    local version = 0
    local fileChanges = project.newFileChangeSummary()
    local existing = overlays[path]
    local scriptKind
    if existing ~= nil then
        version = existing:Version() + 1
        scriptKind = existing:Kind()
        fileChanges.changed:Add(uri)
    else
        scriptKind = core.GetScriptKindFromFileName(lsproto.DocumentUri_FileName(uri))
        if scriptKind == core.ScriptKind.Unknown then
            return nil, project.errorf("unsupported file extension: %s", lsproto.DocumentUri_FileName(uri))
        end
        fileChanges.opened = uri
    end
    overlays[path] = project.newOverlay(lsproto.DocumentUri_FileName(uri), newText, version, scriptKind)

    local newSnapshot = baseSnapshot:Clone(ctx, project.newSnapshotChange({
        fileChanges = fileChanges,
        documents = { uri },
    }), overlays, self)
    return newSnapshot, nil
end
