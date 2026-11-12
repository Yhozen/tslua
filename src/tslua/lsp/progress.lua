local lsp = require("tslua.lsp")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local lsproto = require("tslua.lsp.lsproto")
local project = require("tslua.project")

-- progressEvent: { message, args, finish }

-- progressReporter abstracts the LSP transport operations needed by
-- projectLoadingProgress so the progress logic can be tested without a
-- full Server instance:
--   done() -> bool: true once the server is shutting down (Go: the channel is closed)
--   localize(msg, ...) -> string: converts a diagnostic message to a display string
--   createWorkDoneProgress(token): asks the client to create a progress token
--   sendProgress(token, value): sends a $/progress notification
--   now() -> seconds (Lua-only): the clock used for the display delay

-- serverProgressReporter adapts *Server to the progressReporter interface.
local serverProgressReporter = {}
serverProgressReporter.__index = serverProgressReporter
lsp.serverProgressReporter = serverProgressReporter

function serverProgressReporter:done()
    return core.ContextErr(self.server.backgroundCtx) ~= nil
end

function serverProgressReporter:localize(msg, ...)
    return msg:Localize(self.server.locale, ...)
end

function serverProgressReporter:createWorkDoneProgress(token)
    lsp.sendClientRequestFireAndForget(self.server, lsproto.WindowWorkDoneProgressCreateInfo, lsproto.WorkDoneProgressCreateParams({
        token = lsproto.IntegerOrString({ string = token }),
    }))
end

function serverProgressReporter:sendProgress(token, value)
    lsp.sendNotification(self.server, lsproto.ProgressInfo, lsproto.ProgressParams({
        token = lsproto.IntegerOrString({ string = token }),
        value = value,
    }))
end

function serverProgressReporter:now()
    return project.now()
end

-- projectLoadingProgress manages LSP WorkDoneProgress indicators for
-- long-running operations. It maintains a ref-counted map of active operations
-- and sends progress messages in order.
--
-- To avoid flickering on fast operations, the indicator is not shown
-- until progressDelay has elapsed since the first start event. If all
-- operations complete before then, no progress UI is displayed.
--
-- Go processes the start/finish events on a persistent goroutine with a timer for the delay.
-- The sequential port processes each event when it is sent, and fires the delay timer when it is
-- next polled after the deadline: before every event and whenever the server is idle (poll).
local projectLoadingProgress = {}
projectLoadingProgress.__index = projectLoadingProgress
lsp.projectLoadingProgress = projectLoadingProgress

function lsp.newProjectLoadingProgress(server, delay)
    return lsp.newProjectLoadingProgressFromReporter(setmetatable({ server = server }, serverProgressReporter), delay)
end

function lsp.newProjectLoadingProgressFromReporter(reporter, delay)
    local p = setmetatable({
        reporter = reporter,
        delay = delay, -- seconds to wait before showing progress UI
        -- State owned by run() in Go.
        loading = collections.NewOrderedMapWithSizeHint(0),
        token = "", -- current token; empty if no progress active
        tokenID = 0,
        begun = false, -- whether "begin" has been sent for the current token
        delayDeadline = nil, -- the pending delay timer (Go: delay *time.Timer)
        delayFired = false, -- true after the delay timer fires
        stopped = false,
    }, projectLoadingProgress)
    return p
end

function projectLoadingProgress:start(message, ...)
    self:send({ message = message, args = table.pack(...), finish = false })
end

function projectLoadingProgress:finish(message, ...)
    self:send({ message = message, args = table.pack(...), finish = true })
end

function projectLoadingProgress:send(ev)
    if self:checkDone() then
        -- Server shutting down; drop the event.
        return
    end
    self:poll()
    self:handleEvent(ev)
end

-- checkDone handles the reporter's done channel being closed (the run loop exits).
function projectLoadingProgress:checkDone()
    if self.stopped then
        return true
    end
    if self.reporter:done() then
        self:stopDelay()
        self.stopped = true
        return true
    end
    return false
end

function projectLoadingProgress:stopDelay()
    self.delayDeadline = nil
end

-- poll fires the delay timer if its deadline has passed (the `case <-delayC():` of run).
function projectLoadingProgress:poll()
    if self:checkDone() then
        return
    end
    if self.delayDeadline ~= nil and self.reporter:now() >= self.delayDeadline then
        self.delayDeadline = nil
        self.delayFired = true
        if self.token ~= "" and self.loading:Size() > 0 then
            self.reporter:createWorkDoneProgress(self.token)
            local first = self:firstLoading()
            self.begun = self:beginOrReport(self.token, first, self.begun)
        end
    end
end

-- core.FirstOrNilSeq(loading.Keys())
function projectLoadingProgress:firstLoading()
    local k = self.loading:Keys()()
    if k == nil then
        return ""
    end
    return k
end

-- handleEvent is the `case ev := <-p.ch:` of run.
function projectLoadingProgress:handleEvent(ev)
    local text = self.reporter:localize(ev.message, table.unpack(ev.args, 1, ev.args.n))
    if not ev.finish then
        local count = self.loading:GetOrZero(text) or 0
        self.loading:Set(text, count + 1)
        if self.token == "" then
            self.tokenID = self.tokenID + 1
            self.token = "tsgo-loading-" .. tostring(self.tokenID)
            self.begun = false
            if self.delay <= 0 then
                self.delayFired = true
                self.reporter:createWorkDoneProgress(self.token)
            else
                self.delayFired = false
                self.delayDeadline = self.reporter:now() + self.delay
            end
        end
        if self.delayFired then
            self.begun = self:beginOrReport(self.token, text, self.begun)
        end
    else
        local count = self.loading:GetOrZero(text) or 0
        if count <= 1 then
            self.loading:Delete(text)
        else
            self.loading:Set(text, count - 1)
        end
        if self.token == "" then
            return
        end
        if self.loading:Size() == 0 then
            if self.begun then
                self.reporter:sendProgress(self.token, lsproto.WorkDoneProgressBeginOrReportOrEnd({
                    end_ = lsproto.WorkDoneProgressEnd({}),
                }))
            end
            self:stopDelay()
            self.token = ""
        elseif self.delayFired then
            local first = self:firstLoading()
            self.reporter:sendProgress(self.token, lsproto.WorkDoneProgressBeginOrReportOrEnd({
                report = lsproto.WorkDoneProgressReport({
                    message = first,
                }),
            }))
        end
    end
end

-- beginOrReport sends WorkDoneProgressBegin if not yet begun, otherwise
-- sends WorkDoneProgressReport. Returns true to indicate begun state.
function projectLoadingProgress:beginOrReport(token, text, begun)
    if not begun then
        local title = self.reporter:localize(diagnostics.Loading)
        self.reporter:sendProgress(token, lsproto.WorkDoneProgressBeginOrReportOrEnd({
            begin = lsproto.WorkDoneProgressBegin({
                title = title,
                message = text,
            }),
        }))
    else
        self.reporter:sendProgress(token, lsproto.WorkDoneProgressBeginOrReportOrEnd({
            report = lsproto.WorkDoneProgressReport({
                message = text,
            }),
        }))
    end
    return true
end
