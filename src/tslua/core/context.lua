local core = require("tslua.core")

-- Go context.Context is modeled as nil (context.Background()) or a table
-- { parent = <ctx>, key = <key>, value = <value> } (context.WithValue). A ctx table may also
-- provide its own Value(key) method.

core.requestIDKey = "core.requestIDKey"
core.checkerLifetimeKey = "core.checkerLifetimeKey"

function core.contextWithValue(ctx, key, value)
    return { parent = ctx, key = key, value = value }
end

function core.contextValue(ctx, key)
    while ctx ~= nil do
        if ctx.key == key then
            return ctx.value
        end
        if ctx.parent == nil and ctx.Value ~= nil then
            return ctx:Value(key)
        end
        ctx = ctx.parent
    end
    return nil
end

function core.WithRequestID(ctx, id)
    return core.contextWithValue(ctx, core.requestIDKey, id)
end

function core.GetRequestID(ctx)
    local id = core.contextValue(ctx, core.requestIDKey)
    if type(id) == "string" then
        return id
    end
    return ""
end

function core.WithCheckerLifetime(ctx, lifetime)
    return core.contextWithValue(ctx, core.checkerLifetimeKey, lifetime)
end

function core.GetCheckerLifetime(ctx)
    local lifetime = core.contextValue(ctx, core.checkerLifetimeKey)
    if lifetime ~= nil then
        return lifetime
    end
    return core.CheckerLifetime.Temporary
end

-- Cancellation (Go context.WithCancel / ctx.Err / ctx.Done / context.AfterFunc). A cancel context
-- is a table { parent, err, children, afterFuncs } with Err() and Done() methods; Done() returns
-- true (Go: a non-nil channel). Contexts without a cancelable ancestor have no Done (Go: nil).
core.Canceled = "context canceled"

local cancelCtx = {}
cancelCtx.__index = cancelCtx
core.cancelCtx = cancelCtx

local function nearestCancelCtx(ctx)
    while ctx ~= nil do
        if getmetatable(ctx) == cancelCtx then
            return ctx
        end
        ctx = ctx.parent
    end
    return nil
end

-- WithCancel returns (ctx, cancel).
function core.WithCancel(parent)
    local ctx = setmetatable({ parent = parent, err = nil, children = nil, afterFuncs = nil }, cancelCtx)
    local p = nearestCancelCtx(parent)
    if p ~= nil then
        if p:Err() ~= nil then
            ctx.err = p:Err()
        else
            p.children = p.children or {}
            p.children[#p.children + 1] = ctx
        end
    end
    return ctx, function()
        ctx:cancel(core.Canceled)
    end
end

-- WithTimeout has no timers in the sequential port; the deadline never fires.
function core.WithTimeout(parent, timeout)
    return core.WithCancel(parent)
end

function cancelCtx:cancel(err)
    if self.err ~= nil then
        return
    end
    self.err = err
    local children = self.children
    self.children = nil
    for _, child in ipairs(children or {}) do
        child:cancel(err)
    end
    local fns = self.afterFuncs
    self.afterFuncs = nil
    for _, f in ipairs(fns or {}) do
        f()
    end
end

function cancelCtx:Err()
    return self.err
end

function cancelCtx:Done()
    return true
end

-- ContextErr returns ctx.Err() (nil for contexts that can never be canceled).
function core.ContextErr(ctx)
    local c = nearestCancelCtx(ctx)
    if c == nil then
        return nil
    end
    return c:Err()
end

-- ContextDone reports whether ctx.Done() is non-nil (ctx can be canceled).
function core.ContextDone(ctx)
    return nearestCancelCtx(ctx) ~= nil
end

-- AfterFunc arranges to call f after ctx is canceled (immediately if it already is; never if ctx
-- cannot be canceled). Returns stop().
function core.AfterFunc(ctx, f)
    local c = nearestCancelCtx(ctx)
    if c == nil then
        return function() return false end
    end
    if c.err ~= nil then
        f()
        return function() return false end
    end
    local called = false
    local wrapped = function()
        if not called then
            called = true
            f()
        end
    end
    c.afterFuncs = c.afterFuncs or {}
    c.afterFuncs[#c.afterFuncs + 1] = wrapped
    return function()
        if called then
            return false
        end
        called = true
        return true
    end
end
