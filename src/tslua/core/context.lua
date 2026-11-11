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
