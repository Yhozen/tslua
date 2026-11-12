local fswatch = require("tslua.fswatch")

local EventKind = fswatch.EventKind

-- EventKind classifies a filesystem change.
function fswatch.EventKind_String(k)
    if k == EventKind.EventUpdate then
        return "update"
    elseif k == EventKind.EventDelete then
        return "delete"
    else
        return "unknown"
    end
end

-- Event describes a single filesystem change: { kind = EventKind, path = string, includedWatchRoot = bool }.
function fswatch.NewEvent(kind, path, includedWatchRoot)
    return { kind = kind, path = path, includedWatchRoot = includedWatchRoot or false }
end

-- eventEntry tracks coalescing state during a debounce batch.
local eventEntry = {}
eventEntry.__index = eventEntry
fswatch.eventEntry = eventEntry

local function newEventEntry()
    return setmetatable({ createdSeq = 0, updatedSeq = 0, deletedSeq = 0, includedWatchRoot = false }, eventEntry)
end

-- eventList coalesces filesystem events by path within a debounce window.
--   - create after delete → update (rapid delete+recreate)
--   - getEvents skips entries that were both created and deleted
local eventList = {}
eventList.__index = eventList
fswatch.eventList = eventList

function fswatch.newEventList()
    return setmetatable({ entries = nil, err = nil, seq = 0 }, eventList)
end

-- create records a new-file event for path. Both create and update
-- produce EventUpdate externally; sequence state tracks coalescing
-- (create+delete within a batch cancels out).
function eventList:create(path)
    local seq = self:nextSeqLocked()
    self:createLocked(path, seq)
end

function eventList:createAt(path, seq)
    self:advanceSeqLocked(seq)
    self:createLocked(path, seq)
end

function eventList:createLocked(path, seq)
    local entry = self:getOrCreate(path)
    if entry:isDeleted() then
        -- Rapid delete+recreate: clear both flags so the entry
        -- emits EventUpdate (the default for non-deleted entries).
        -- https://github.com/parcel-bundler/watcher/issues/72
        entry.deletedSeq = 0
        entry.createdSeq = 0
        entry.updatedSeq = seq
    else
        entry.createdSeq = seq
    end
end

-- update records an update event for path.
function eventList:update(path)
    local seq = self:nextSeqLocked()
    self:updateLocked(path, seq)
end

function eventList:updateAt(path, seq)
    self:advanceSeqLocked(seq)
    self:updateLocked(path, seq)
end

function eventList:updateWatchRootAt(path, seq)
    self:advanceSeqLocked(seq)
    self:updateLocked(path, seq)
    self:getOrCreate(path).includedWatchRoot = true
end

function eventList:updateLocked(path, seq)
    self:getOrCreate(path).updatedSeq = seq
end

-- remove records a delete event for path.
function eventList:remove(path)
    local seq = self:nextSeqLocked()
    self:removeLocked(path, seq)
end

function eventList:removeAndGetSequence(path)
    local seq = self:nextSeqLocked()
    self:removeLocked(path, seq)
    return seq
end

function eventList:removeAt(path, seq)
    self:advanceSeqLocked(seq)
    self:removeLocked(path, seq)
end

function eventList:removeWatchRootAt(path, seq)
    self:advanceSeqLocked(seq)
    self:removeLocked(path, seq)
    self:getOrCreate(path).includedWatchRoot = true
end

function eventList:removeLocked(path, seq)
    local entry = self:getOrCreate(path)
    entry.deletedSeq = seq
end

-- size returns the number of tracked entries (including ones that may
-- cancel out in getEvents).
function eventList:size()
    if self.entries == nil then
        return 0
    end
    local n = 0
    for _ in pairs(self.entries) do
        n = n + 1
    end
    return n
end

-- snapshotLocked returns the current set of pending events with
-- create+delete pairs filtered out. Caller must hold el.mu.
function eventList:snapshotLocked()
    return self:snapshotSinceLocked(0)
end

-- Go's map iteration order is unspecified ("Order is not guaranteed"); the Lua port returns the
-- events sorted by path so that delivery is deterministic.
function eventList:snapshotSinceLocked(startSeq)
    local out = {}
    if self.entries == nil then
        return out
    end
    local paths = {}
    for path in pairs(self.entries) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    for _, path in ipairs(paths) do
        local e = self.entries[path]
        local kind, ok = e:kindSince(startSeq)
        if ok then
            out[#out + 1] = fswatch.NewEvent(kind, path, e.includedWatchRoot)
        end
    end
    return out
end

-- getEvents returns a snapshot of events, skipping entries that were both
-- created and deleted. Order is not guaranteed.
function eventList:getEvents()
    return self:snapshotLocked()
end

-- drain atomically snapshots all pending events and the stored error,
-- then clears the list. This prevents events added between a separate
-- getEvents+clear from being silently dropped.
function eventList:drain()
    local out = self:snapshotLocked()
    local err = self.err
    self.entries = nil
    self.err = nil
    return out, err
end

function eventList:drainForSequences(startSeqs)
    local out = {}
    for i, startSeq in ipairs(startSeqs) do
        out[i] = self:snapshotSinceLocked(startSeq)
    end
    local err = self.err
    self.entries = nil
    self.err = nil
    return out, err
end

-- setError stores the first error encountered (later errors are ignored).
function eventList:setError(err)
    if self.err == nil then
        self.err = err
    end
end

-- hasError reports whether an error has been recorded.
function eventList:hasError()
    return self.err ~= nil
end

-- getError returns the stored error (or nil if none).
function eventList:getError()
    return self.err
end

function eventList:getOrCreate(path)
    if self.entries == nil then
        self.entries = {}
    end
    local e = self.entries[path]
    if e ~= nil then
        return e
    end
    e = newEventEntry()
    self.entries[path] = e
    return e
end

function eventList:sequence()
    return self.seq
end

function eventList:nextSeqLocked()
    self.seq = self.seq + 1
    return self.seq
end

function eventList:advanceSeqLocked(seq)
    if seq > self.seq then
        self.seq = seq
    end
end

function eventEntry:isDeleted()
    return self.deletedSeq > self.createdSeq and self.deletedSeq > self.updatedSeq
end

-- Returns (EventKind, ok).
function eventEntry:kindSince(startSeq)
    if self.deletedSeq > startSeq then
        if self.createdSeq > startSeq and self.createdSeq < self.deletedSeq and self.updatedSeq < self.deletedSeq then
            return 0, false
        end
        return EventKind.EventDelete, true
    end
    local seq = math.max(self.createdSeq, self.updatedSeq)
    if seq > startSeq then
        return EventKind.EventUpdate, true
    end
    return 0, false
end
