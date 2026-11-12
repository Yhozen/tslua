-- Ported from internal/project/overlayfs_test.go, internal/project/dirty/syncmap_test.go,
-- internal/project/background/queue_test.go and internal/project/logging/logtree_test.go.
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")
local background = require("tslua.project.background")
local dirty = require("tslua.project.dirty")
local logging = require("tslua.project.logging")
local vfstest = require("tslua.vfs.vfstest")

local FileChangeKind = project.FileChangeKind
local TS = lsproto.LanguageKind.TypeScript

describe("project.overlayFS processChanges", function()
    -- Helper to create test overlayFS
    local function createOverlayFS()
        local testFS = vfstest.FromMap({
            ["/test1.ts"] = "// existing content",
            ["/test2.ts"] = "// existing content",
            ["/script"] = "// extensionless content",
        }, false)
        return project.newOverlayFS(testFS, {}, lsproto.PositionEncodingKind.UTF16, function(fileName)
            return fileName
        end)
    end

    local testURI1 = "file:///test1.ts"
    local testURI2 = "file:///test2.ts"

    local function change(fields)
        return project.NewFileChange(fields)
    end

    it("multiple opens should panic", function()
        local fs = createOverlayFS()
        assert.has_error(function()
            fs:processChanges({
                change({ kind = FileChangeKind.Open, uri = testURI1, version = 1, content = "const x = 1;", languageKind = TS }),
                change({ kind = FileChangeKind.Open, uri = testURI2, version = 1, content = "const y = 2;", languageKind = TS }),
            })
        end)
    end)

    it("watch create then delete becomes nothing", function()
        local fs = createOverlayFS()
        local result = fs:processChanges({
            change({ kind = FileChangeKind.WatchCreate, uri = testURI1 }),
            change({ kind = FileChangeKind.WatchDelete, uri = testURI1 }),
        })
        assert.is_true(project.FileChangeSummary_IsEmpty(result))
    end)

    it("watch delete then create becomes change", function()
        local fs = createOverlayFS()
        local result = fs:processChanges({
            change({ kind = FileChangeKind.WatchDelete, uri = testURI1 }),
            change({ kind = FileChangeKind.WatchCreate, uri = testURI1 }),
        })
        assert.are.equal(0, result.created:Len())
        assert.are.equal(0, result.deleted:Len())
        assert.is_true(result.changed:Has(testURI1))
    end)

    it("multiple watch changes deduplicated", function()
        local fs = createOverlayFS()
        local result = fs:processChanges({
            change({ kind = FileChangeKind.WatchChange, uri = testURI1 }),
            change({ kind = FileChangeKind.WatchChange, uri = testURI1 }),
            change({ kind = FileChangeKind.WatchChange, uri = testURI1 }),
        })
        assert.is_true(result.changed:Has(testURI1))
        assert.are.equal(1, result.changed:Len())
    end)

    it("save marks overlay as matching disk", function()
        local fs = createOverlayFS()
        -- First create an overlay
        fs:processChanges({
            change({ kind = FileChangeKind.Open, uri = testURI1, version = 1, content = "const x = 1;", languageKind = TS }),
        })
        -- Then save
        local result = fs:processChanges({ change({ kind = FileChangeKind.Save, uri = testURI1 }) })
        -- We don't observe saves for snapshot changes,
        -- so they're not included in the summary
        assert.is_true(project.FileChangeSummary_IsEmpty(result))

        -- Check that the overlay is marked as matching disk text
        local fh = fs:getFile(lsproto.DocumentUri_FileName(testURI1))
        assert.is_not_nil(fh)
        assert.is_true(fh:MatchesDiskText())
    end)

    it("open falls back to file extension for unknown language kind", function()
        local fs = createOverlayFS()
        local uri = "file:///test1.mts"
        fs:processChanges({
            change({ kind = FileChangeKind.Open, uri = uri, version = 1, content = "export const x = 1;", languageKind = "mts" }),
        })
        local fh = fs:getFile(lsproto.DocumentUri_FileName(uri))
        assert.is_not_nil(fh)
        assert.are.equal(core.ScriptKind.TS, fh:Kind())
    end)

    it("open extensionless file preserves unknown script kind", function()
        local fs = createOverlayFS()
        local uri = "file:///script"
        fs:processChanges({
            change({ kind = FileChangeKind.Open, uri = uri, version = 1, content = "const x = 1;", languageKind = "plaintext" }),
        })
        local fh = fs:getFile(lsproto.DocumentUri_FileName(uri))
        assert.is_not_nil(fh)
        assert.are.equal(core.ScriptKind.Unknown, fh:Kind())
    end)

    it("extensionless disk file preserves unknown script kind", function()
        local fs = createOverlayFS()
        local fh = fs:getFile("/script")
        assert.is_not_nil(fh)
        assert.are.equal(core.ScriptKind.Unknown, fh:Kind())
    end)

    it("watch change on overlay marks as not matching disk", function()
        local fs = createOverlayFS()
        local fileName = lsproto.DocumentUri_FileName(testURI1)
        fs:processChanges({
            change({ kind = FileChangeKind.Open, uri = testURI1, version = 1, content = "const x = 1;", languageKind = TS }),
        })
        assert.is_false(fs:getFile(fileName):MatchesDiskText())

        fs:processChanges({ change({ kind = FileChangeKind.Save, uri = testURI1 }) })
        assert.is_true(fs:getFile(fileName):MatchesDiskText())

        fs:processChanges({ change({ kind = FileChangeKind.WatchChange, uri = testURI1 }) })
        assert.is_false(fs:getFile(fileName):MatchesDiskText())
    end)

    it("save without overlay should not panic", function()
        local fs = createOverlayFS()
        local result = fs:processChanges({ change({ kind = FileChangeKind.Save, uri = testURI1 }) })
        -- Should be treated as a disk change
        assert.is_true(result.changed:Has(testURI1))
    end)

    it("close then open in same batch marks as changed", function()
        local fs = createOverlayFS()
        fs:processChanges({
            change({ kind = FileChangeKind.Open, uri = testURI1, version = 1, content = "const x = 1;", languageKind = TS }),
        })

        -- Now close and reopen in the same batch (like Neovim does for file reload)
        local result = fs:processChanges({
            change({ kind = FileChangeKind.Close, uri = testURI1 }),
            change({ kind = FileChangeKind.Open, uri = testURI1, version = 0, content = "const x = 2;", languageKind = TS }),
        })

        -- Should not be marked as opened since it was already open
        assert.are.equal("", result.opened)
        -- Should also be marked as changed since it was closed and reopened
        assert.is_true(result.changed:Has(testURI1))
        -- Should have the new content
        assert.are.equal("const x = 2;", fs:getFile(lsproto.DocumentUri_FileName(testURI1)):Content())
    end)
end)

describe("dirty.SyncMap proxyFor", function()
    -- testValue is a simple cloneable type for testing
    local testValue = {}
    testValue.__index = testValue
    local function newTestValue(data)
        return setmetatable({ data = data }, testValue)
    end
    function testValue:Clone()
        return newTestValue(self.data)
    end

    it("proxy for race condition", function()
        local syncMap = dirty.NewSyncMap({ key1 = newTestValue("original") })
        local entry1, ok1 = syncMap:Load("key1")
        assert.is_true(ok1)
        local entry2, ok2 = syncMap:Load("key1")
        assert.is_true(ok2)

        assert.are.equal("original", entry1:Value().data)
        assert.are.equal("original", entry2:Value().data)
        assert.is_false(entry1:Dirty())
        assert.is_false(entry2:Dirty())

        entry1:Change(function(v) v.data = "changed_by_entry1" end)
        entry2:Change(function(v) v.data = "changed_by_entry2" end)

        assert.are.equal(entry1:Value().data, entry2:Value().data)
        assert.is_true(entry1:Dirty())
        assert.is_true(entry2:Dirty())
        assert.is_true(entry1.proxyFor ~= nil or entry2.proxyFor ~= nil)
        if entry1.proxyFor ~= nil then
            assert.are.equal(entry2, entry1.proxyFor)
        end
        if entry2.proxyFor ~= nil then
            assert.are.equal(entry1, entry2.proxyFor)
        end
    end)

    it("proxy operations delegation", function()
        local syncMap = dirty.NewSyncMap({ key1 = newTestValue("original") })
        local entry1 = syncMap:Load("key1")
        local entry2 = syncMap:Load("key1")
        entry1:Change(function(v) v.data = "changed_by_entry1" end)
        entry2:Change(function(v) v.data = "changed_by_entry2" end)

        local proxy, target
        if entry1.proxyFor ~= nil then
            proxy, target = entry1, entry2
        else
            proxy, target = entry2, entry1
        end

        proxy:Change(function(v) v.data = "changed_through_proxy" end)
        assert.are.equal("changed_through_proxy", target:Value().data)
        assert.are.equal("changed_through_proxy", proxy:Value().data)

        local changed = proxy:ChangeIf(
            function(v) return v.data == "changed_through_proxy" end,
            function(v) v.data = "conditional_change" end
        )
        assert.is_true(changed)
        assert.are.equal("conditional_change", target:Value().data)
        assert.are.equal("conditional_change", proxy:Value().data)
        assert.are.equal(target:Dirty(), proxy:Dirty())

        proxy:Locked(function(v)
            v:Change(function(val) val.data = "locked_change" end)
        end)
        assert.are.equal("locked_change", target:Value().data)
        assert.are.equal("locked_change", proxy:Value().data)
    end)

    it("proxy delete operations", function()
        local syncMap = dirty.NewSyncMap({ key1 = newTestValue("original") })
        local entry1 = syncMap:Load("key1")
        local entry2 = syncMap:Load("key1")
        entry1:Change(function(v) v.data = "modified" end)
        entry2:Change(function(v) v.data = "modified2" end)
        local proxy = entry1.proxyFor ~= nil and entry1 or entry2
        proxy:Delete()
        local _, exists = syncMap:Load("key1")
        assert.is_false(exists)

        local syncMap2 = dirty.NewSyncMap({ key2 = newTestValue("test") })
        local entry3 = syncMap2:Load("key2")
        local entry4 = syncMap2:Load("key2")
        entry3:Change(function(v) v.data = "modified" end)
        entry4:Change(function(v) v.data = "modified2" end)
        local proxy2 = entry3.proxyFor ~= nil and entry3 or entry4
        proxy2:DeleteIf(function(v)
            return v.data == "modified2" or v.data == "modified"
        end)
        local _, exists2 = syncMap2:Load("key2")
        assert.is_false(exists2)
    end)

    it("no proxy when no race", function()
        local syncMap = dirty.NewSyncMap({ key1 = newTestValue("original") })
        local entry, ok = syncMap:Load("key1")
        assert.is_true(ok)
        entry:Change(function(v) v.data = "changed" end)
        assert.is_nil(entry.proxyFor)
        assert.is_true(entry:Dirty())
        assert.are.equal("changed", entry:Value().data)
    end)
end)

describe("background.Queue", function()
    it("BasicEnqueue", function()
        local q = background.NewQueue()
        local executed = false
        q:Enqueue(nil, function() executed = true end)
        q:Wait()
        assert.is_true(executed)
        q:Close()
    end)

    it("MultipleTasksExecution", function()
        local q = background.NewQueue()
        local counter = 0
        for _ = 1, 10 do
            q:Enqueue(nil, function() counter = counter + 1 end)
        end
        q:Wait()
        assert.are.equal(10, counter)
        q:Close()
    end)

    it("NestedEnqueue", function()
        local q = background.NewQueue()
        local executed = {}
        q:Enqueue(nil, function(ctx)
            executed[#executed + 1] = "parent"
            q:Enqueue(ctx, function()
                executed[#executed + 1] = "child"
            end)
        end)
        q:Wait()
        assert.are.equal(2, #executed)
        q:Close()
    end)

    it("ClosedQueueRejectsNewTasks", function()
        local q = background.NewQueue()
        q:Close()
        local executed = false
        q:Enqueue(nil, function() executed = true end)
        q:Wait()
        assert.is_false(executed)
    end)

    it("skips canceled tasks", function()
        local q = background.NewQueue()
        local ctx, cancel = core.WithCancel(nil)
        local executed = false
        q:Enqueue(ctx, function() executed = true end)
        cancel()
        q:Wait()
        assert.is_false(executed)
    end)
end)

describe("logging.LogTree", function()
    it("implements the logger interface and nests forks", function()
        local tree = logging.NewLogTree("root")
        tree:Log("a")
        local child = tree:Fork("child")
        child:Logf("%s=%d", "x", 1)
        logging.LogTree.Log(nil, "ignored")
        local s = tree:String()
        assert.is_truthy(string.find(s, "======== root ========\n", 1, true))
        assert.is_truthy(string.find(s, "] a\n", 1, true))
        assert.is_truthy(string.find(s, "\t[", 1, true))
        assert.is_truthy(string.find(s, "] x=1\n", 1, true))
    end)
end)

-- Ported from internal/project/watch_test.go.
describe("project watch", function()
    it("getPathComponentsForWatching", function()
        assert.are.same({ "/", "project" }, project.getPathComponentsForWatching("/project", ""))
        assert.are.same({ "C:/", "project" }, project.getPathComponentsForWatching("C:\\project", ""))
        assert.are.same({ "//server/share", "project", "tsconfig.json" }, project.getPathComponentsForWatching("//server/share/project/tsconfig.json", ""))
        assert.are.same({ "//server/share", "project", "tsconfig.json" }, project.getPathComponentsForWatching("\\\\server\\share\\project\\tsconfig.json", ""))
        assert.are.same({ "C:/Users" }, project.getPathComponentsForWatching("C:\\Users", ""))
        assert.are.same({ "C:/Users/andrew", "project" }, project.getPathComponentsForWatching("C:\\Users\\andrew\\project", ""))
        assert.are.same({ "/home" }, project.getPathComponentsForWatching("/home", ""))
        assert.are.same({ "/home/andrew", "project" }, project.getPathComponentsForWatching("/home/andrew/project", ""))
    end)

    it("nil WatchedFiles Clone", function()
        assert.is_nil(project.WatchedFiles.Clone(nil, 42))
    end)
end)
