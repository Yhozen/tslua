local ast = require("tslua.ast")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")

-- Go stdlib helpers (strings.Compare, slices.*) used by this file.

local function stringsCompare(a, b)
    if a == b then
        return 0
    elseif a < b then
        return -1
    end
    return 1
end

-- slices.Compare for []string
local function slicesCompare(s1, s2)
    local n1, n2 = core.Len(s1), core.Len(s2)
    for i = 1, math.min(n1, n2) do
        local c = stringsCompare(s1[i], s2[i])
        if c ~= 0 then
            return c
        end
    end
    if n1 < n2 then
        return -1
    elseif n1 > n2 then
        return 1
    end
    return 0
end

-- slices.Equal for []string
local function slicesEqual(s1, s2)
    local n1, n2 = core.Len(s1), core.Len(s2)
    if n1 ~= n2 then
        return false
    end
    for i = 1, n1 do
        if s1[i] ~= s2[i] then
            return false
        end
    end
    return true
end

local function slicesEqualFunc(s1, s2, eq)
    local n1, n2 = core.Len(s1), core.Len(s2)
    if n1 ~= n2 then
        return false
    end
    for i = 1, n1 do
        if not eq(s1[i], s2[i]) then
            return false
        end
    end
    return true
end

local function slicesClone(s)
    if s == nil then
        return nil
    end
    local r = {}
    for i = 1, #s do
        r[i] = s[i]
    end
    return r
end

-- slices.SortStableFunc (in place, stable merge sort)
local function sortStableFunc(xs, cmp)
    if xs == nil then
        return
    end
    local n = #xs
    if n < 2 then
        return
    end
    local tmp = {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width, n + 1)
            local hi = math.min(i + 2 * width, n + 1)
            local a, b, k = i, mid, i
            while a < mid and b < hi do
                if cmp(xs[b], xs[a]) < 0 then
                    tmp[k] = xs[b]
                    b = b + 1
                else
                    tmp[k] = xs[a]
                    a = a + 1
                end
                k = k + 1
            end
            while a < mid do
                tmp[k] = xs[a]
                a = a + 1
                k = k + 1
            end
            while b < hi do
                tmp[k] = xs[b]
                b = b + 1
                k = k + 1
            end
            i = hi
        end
        for j = 1, n do
            xs[j] = tmp[j]
        end
        width = width * 2
    end
end
ast.sortStableFunc = sortStableFunc

-- RepopulateDiagnosticInfo stores information needed to recompute a diagnostic chain entry
-- during incremental builds when the program state may have changed.
-- { kind = RepopulateDiagnosticKind, moduleReference = "", mode = core.ResolutionMode, packageName = "" }

-- Diagnostic

local Diagnostic = {}
Diagnostic.__index = Diagnostic
Diagnostic.__name = "Diagnostic"
ast.Diagnostic = Diagnostic

local function newDiagnosticStruct(fields)
    local d = setmetatable({
        file = nil,
        loc = core.NewTextRange(0, 0),
        code = 0,
        category = 0,
        -- source, when non-empty, is a custom prefix (e.g. a content mapper's name) shown instead of "TS"
        -- before the code. It marks the diagnostic as coming from an external source whose ranges point
        -- into the file's original, untransformed text.
        source = "",
        -- Original message; may be nil.
        message = nil,
        -- messageText is an already-localized message used when message is nil, e.g. a diagnostic
        -- deserialized from an external process that owns its own localization.
        messageText = "",
        messageKey = "",
        messageArgs = nil,
        messageChain = nil,
        relatedInformation = nil,
        reportsUnnecessary = false,
        reportsDeprecated = false,
        skippedOnNoEmit = false,
        repopulateInfo = nil,
    }, Diagnostic)
    for k, v in pairs(fields) do
        d[k] = v
    end
    return d
end

function Diagnostic:File() return self.file end
function Diagnostic:Pos() return self.loc:Pos() end
function Diagnostic:End() return self.loc:End() end
function Diagnostic:Len() return self.loc:Len() end
function Diagnostic:Loc() return self.loc end
function Diagnostic:Code() return self.code end
function Diagnostic:Category() return self.category end
function Diagnostic:Source() return self.source end
function Diagnostic:MessageText() return self.messageText end
function Diagnostic:MessageKey() return self.messageKey end
function Diagnostic:MessageArgs() return self.messageArgs end
function Diagnostic:MessageChain() return self.messageChain end
function Diagnostic:RelatedInformation() return self.relatedInformation end
function Diagnostic:ReportsUnnecessary() return self.reportsUnnecessary end
function Diagnostic:ReportsDeprecated() return self.reportsDeprecated end
function Diagnostic:SkippedOnNoEmit() return self.skippedOnNoEmit end
function Diagnostic:RepopulateInfo() return self.repopulateInfo end

function Diagnostic:SetFile(file) self.file = file end
function Diagnostic:SetLocation(loc) self.loc = loc end
function Diagnostic:SetCategory(category) self.category = category end
function Diagnostic:SetSkippedOnNoEmit() self.skippedOnNoEmit = true end
function Diagnostic:SetRepopulateInfo(info) self.repopulateInfo = info end

function Diagnostic:SetExternalData(source, messageText)
    self.source = source
    self.messageText = messageText
    return self
end

function Diagnostic:SetMessageChain(messageChain)
    self.messageChain = messageChain
    return self
end

function Diagnostic:AddMessageChain(messageChain)
    if messageChain ~= nil then
        self.messageChain = core.Append(self.messageChain, messageChain)
    end
    return self
end

function Diagnostic:SetRelatedInfo(relatedInformation)
    self.relatedInformation = relatedInformation
    return self
end

function Diagnostic:AddRelatedInfo(relatedInformation)
    if relatedInformation ~= nil then
        self.relatedInformation = core.Append(self.relatedInformation, relatedInformation)
    end
    return self
end

function Diagnostic:Clone()
    local result = {}
    for k, v in pairs(self) do
        result[k] = v
    end
    return setmetatable(result, Diagnostic)
end

function Diagnostic:Localize(locale)
    if self.message == nil and self.messageText ~= "" then
        return self.messageText
    end
    return diagnostics.Localize(locale, self.message, self.messageKey, table.unpack(self:displayMessageArgs() or {}))
end

-- For debugging only.
function Diagnostic:String()
    if self.message == nil and self.messageText ~= "" then
        return self.messageText
    end
    return diagnostics.Localize(nil --[[locale.Default]], self.message, self.messageKey,
        table.unpack(self:displayMessageArgs() or {}))
end

-- displayMessageArgs substitutes the original text for a complete alias span when a diagnostic argument
-- exactly matches the virtual alias. Stored arguments remain unchanged for code fixes and serialization.
function Diagnostic:displayMessageArgs()
    if self.file == nil or self.source ~= "" then
        return self.messageArgs
    end
    -- A nil span map maps positions identically (and has no aliases).
    local spanMap = self.file:SpanMap()
    if spanMap == nil then
        return self.messageArgs
    end
    local segment, ok = spanMap:AliasForVirtualSpan(self.loc)
    if not ok then
        return self.messageArgs
    end
    local virtualText = self.file:Text()
    local originalText = self.file:OriginalText()
    if segment.virtualStart < 0 or segment.virtualEnd > #virtualText or
        segment.originalStart < 0 or segment.originalEnd > #originalText then
        return self.messageArgs
    end
    local virtualName = string.sub(virtualText, segment.virtualStart + 1, segment.virtualEnd)
    local originalName = string.sub(originalText, segment.originalStart + 1, segment.originalEnd)
    local result = nil
    for i, arg in ipairs(self.messageArgs or {}) do
        if arg == virtualName then
            if result == nil then
                result = slicesClone(self.messageArgs)
            end
            result[i] = originalName
        end
    end
    if result ~= nil then
        return result
    end
    return self.messageArgs
end

function ast.NewDiagnosticFromSerialized(file, loc, code, category, messageKey, messageArgs, messageChain,
                                         relatedInformation, reportsUnnecessary, reportsDeprecated, skippedOnNoEmit)
    return newDiagnosticStruct({
        file = file,
        loc = loc,
        code = code,
        category = category,
        messageKey = messageKey,
        messageArgs = messageArgs,
        messageChain = messageChain,
        relatedInformation = relatedInformation,
        reportsUnnecessary = reportsUnnecessary,
        reportsDeprecated = reportsDeprecated,
        skippedOnNoEmit = skippedOnNoEmit,
    })
end

function ast.NewDiagnostic(file, loc, message, ...)
    return newDiagnosticStruct({
        file = file,
        loc = loc,
        code = message:Code(),
        category = message:Category(),
        message = message,
        messageKey = message:Key(),
        messageArgs = diagnostics.StringifyArgs(table.pack(...)),
        reportsUnnecessary = message:ReportsUnnecessary(),
        reportsDeprecated = message:ReportsDeprecated(),
    })
end

function ast.NewDiagnosticChain(chain, message, ...)
    if chain ~= nil then
        return ast.NewDiagnostic(chain.file, chain.loc, message, ...):AddMessageChain(chain):SetRelatedInfo(chain.relatedInformation)
    end
    return ast.NewDiagnostic(nil, core.NewTextRange(0, 0), message, ...)
end

function ast.NewCompilerDiagnostic(message, ...)
    return ast.NewDiagnostic(nil, core.UndefinedTextRange(), message, ...)
end

-- NewExternalDiagnostic creates a diagnostic reported by an external source such as a content mapper.
-- The message text is already localized (the external source owns localization) and the code is shown
-- with the given source prefix (e.g. "vue") instead of "TS". The location refers to the file's original,
-- untransformed content.
function ast.NewExternalDiagnostic(file, loc, source, category, code, messageText)
    return newDiagnosticStruct({
        file = file,
        loc = loc,
        code = code,
        category = category,
        source = source,
        messageText = messageText,
    })
end

-- DiagnosticsCollection

local DiagnosticsCollection = {}
DiagnosticsCollection.__index = DiagnosticsCollection
DiagnosticsCollection.__name = "DiagnosticsCollection"
ast.DiagnosticsCollection = DiagnosticsCollection

-- Lua constructor for the Go zero value &ast.DiagnosticsCollection{}.
function ast.NewDiagnosticsCollection()
    return setmetatable({
        count = 0,
        fileDiagnostics = nil, -- path -> []*Diagnostic
        fileDiagnosticsSorted = {}, -- set of paths
        nonFileDiagnostics = nil,
        nonFileDiagnosticsSorted = false,
        diagnosticIndex = nil, -- location key -> *Diagnostic
        diagnosticCollisions = nil, -- location key -> []*Diagnostic
    }, DiagnosticsCollection)
end

function DiagnosticsCollection:Add(diagnostic)
    local key = ast.getDiagnosticLocationKey(diagnostic)
    local existing = self.diagnosticIndex ~= nil and self.diagnosticIndex[key] or nil
    if existing ~= nil then
        if ast.EqualDiagnostics(existing, diagnostic) then
            return existing
        end
        local collisions = self.diagnosticCollisions ~= nil and self.diagnosticCollisions[key] or nil
        if collisions ~= nil then
            for _, collision in ipairs(collisions) do
                if ast.EqualDiagnostics(collision, diagnostic) then
                    return collision
                end
            end
        end
    end
    if self.diagnosticIndex == nil then
        self.diagnosticIndex = {}
    end
    if self.diagnosticIndex[key] == nil then
        self.diagnosticIndex[key] = diagnostic
    else
        if self.diagnosticCollisions == nil then
            self.diagnosticCollisions = {}
        end
        self.diagnosticCollisions[key] = core.Append(self.diagnosticCollisions[key], diagnostic)
    end

    self.count = self.count + 1

    if diagnostic:File() ~= nil then
        local path = diagnostic:File():Path()
        if self.fileDiagnostics == nil then
            self.fileDiagnostics = {}
        end
        self.fileDiagnostics[path] = core.Append(self.fileDiagnostics[path], diagnostic)
        self.fileDiagnosticsSorted[path] = nil
    else
        self.nonFileDiagnostics = core.Append(self.nonFileDiagnostics, diagnostic)
        self.nonFileDiagnosticsSorted = false
    end
    return diagnostic
end

-- diagnosticLocationKey {path, loc, code} encoded as a string.
function ast.getDiagnosticLocationKey(diagnostic)
    local path = ""
    if diagnostic:File() ~= nil then
        path = diagnostic:File():Path()
    end
    local loc = diagnostic:Loc()
    return path .. "\0" .. loc.pos .. "\0" .. loc.end_ .. "\0" .. diagnostic:Code()
end

function DiagnosticsCollection:Lookup(diagnostic)
    local diags
    if diagnostic:File() ~= nil then
        diags = self:getDiagnosticsForFileLocked(diagnostic:File())
    else
        diags = self:getGlobalDiagnosticsLocked()
    end
    -- slices.BinarySearchFunc
    local lo, hi = 0, core.Len(diags)
    while lo < hi do
        local mid = (lo + hi) // 2
        if ast.CompareDiagnostics(diags[mid + 1], diagnostic) < 0 then
            lo = mid + 1
        else
            hi = mid
        end
    end
    if lo < core.Len(diags) and ast.CompareDiagnostics(diags[lo + 1], diagnostic) == 0 then
        return diags[lo + 1]
    end
    return nil
end

function DiagnosticsCollection:GetGlobalDiagnostics()
    return self:getGlobalDiagnosticsLocked()
end

function DiagnosticsCollection:getGlobalDiagnosticsLocked()
    if not self.nonFileDiagnosticsSorted then
        sortStableFunc(self.nonFileDiagnostics, ast.CompareDiagnostics)
        self.nonFileDiagnosticsSorted = true
    end
    return slicesClone(self.nonFileDiagnostics)
end

function DiagnosticsCollection:GetDiagnosticsForFile(file)
    return self:getDiagnosticsForFileLocked(file)
end

function DiagnosticsCollection:getDiagnosticsForFileLocked(file)
    local path = file:Path()
    local list = self.fileDiagnostics ~= nil and self.fileDiagnostics[path] or nil
    if not self.fileDiagnosticsSorted[path] then
        sortStableFunc(list, ast.CompareDiagnostics)
        self.fileDiagnosticsSorted[path] = true
    end
    return slicesClone(list)
end

function DiagnosticsCollection:GetDiagnostics()
    local result = {}
    if self.nonFileDiagnostics ~= nil then
        for _, d in ipairs(self.nonFileDiagnostics) do
            result[#result + 1] = d
        end
    end
    if self.fileDiagnostics ~= nil then
        for _, diags in pairs(self.fileDiagnostics) do
            for _, d in ipairs(diags) do
                result[#result + 1] = d
            end
        end
    end
    sortStableFunc(result, ast.CompareDiagnostics)
    return result
end

function ast.getDiagnosticPath(d)
    if d:File() ~= nil then
        return d:File():FileName()
    end
    return ""
end

function ast.EqualDiagnostics(d1, d2)
    if d1 == d2 then
        return true
    end
    return ast.EqualDiagnosticsNoRelatedInfo(d1, d2) and
        slicesEqualFunc(d1:RelatedInformation(), d2:RelatedInformation(), ast.EqualDiagnostics)
end

function ast.EqualDiagnosticsNoRelatedInfo(d1, d2)
    if d1 == d2 then
        return true
    end
    return ast.getDiagnosticPath(d1) == ast.getDiagnosticPath(d2) and
        d1:Loc().pos == d2:Loc().pos and d1:Loc().end_ == d2:Loc().end_ and
        d1:Code() == d2:Code() and
        d1:Category() == d2:Category() and
        d1:Source() == d2:Source() and
        ast.getDiagnosticMessageIdentity(d1) == ast.getDiagnosticMessageIdentity(d2) and
        slicesEqual(d1:MessageArgs(), d2:MessageArgs()) and
        slicesEqualFunc(d1:MessageChain(), d2:MessageChain(), ast.equalMessageChain)
end

function ast.getDiagnosticMessageIdentity(diagnostic)
    if diagnostic:MessageText() ~= "" then
        return diagnostic:MessageText()
    end
    if diagnostic.message ~= nil and diagnostic:Code() == -1 then
        return diagnostic.message:String()
    end
    return diagnostic:MessageKey()
end

function ast.equalMessageChain(c1, c2)
    if c1 == c2 then
        return true
    end
    return c1:Code() == c2:Code() and
        slicesEqual(c1:MessageArgs(), c2:MessageArgs()) and
        slicesEqualFunc(c1:MessageChain(), c2:MessageChain(), ast.equalMessageChain)
end

function ast.compareMessageChainSize(c1, c2)
    local c = core.Len(c2) - core.Len(c1)
    if c ~= 0 then
        return c
    end
    for i = 1, core.Len(c1) do
        c = ast.compareMessageChainSize(c1[i]:MessageChain(), c2[i]:MessageChain())
        if c ~= 0 then
            return c
        end
    end
    return 0
end

function ast.compareMessageChainContent(c1, c2)
    for i = 1, core.Len(c1) do
        local c = slicesCompare(c1[i]:MessageArgs(), c2[i]:MessageArgs())
        if c ~= 0 then
            return c
        end
        if c1[i]:MessageChain() ~= nil then
            c = ast.compareMessageChainContent(c1[i]:MessageChain(), c2[i]:MessageChain())
            if c ~= 0 then
                return c
            end
        end
    end
    return 0
end

function ast.compareRelatedInfo(r1, r2)
    local c = core.Len(r2) - core.Len(r1)
    if c ~= 0 then
        return c
    end
    for i = 1, core.Len(r1) do
        c = ast.CompareDiagnostics(r1[i], r2[i])
        if c ~= 0 then
            return c
        end
    end
    return 0
end

function ast.CompareDiagnostics(d1, d2)
    if d1 == d2 then
        return 0
    end
    local c = stringsCompare(ast.getDiagnosticPath(d1), ast.getDiagnosticPath(d2))
    if c ~= 0 then
        return c
    end
    c = d1:Loc():Pos() - d2:Loc():Pos()
    if c ~= 0 then
        return c
    end
    c = d1:Loc():End() - d2:Loc():End()
    if c ~= 0 then
        return c
    end
    c = d1:Code() - d2:Code()
    if c ~= 0 then
        return c
    end
    c = d1:Category() - d2:Category()
    if c ~= 0 then
        return c
    end
    c = stringsCompare(d1:Source(), d2:Source())
    if c ~= 0 then
        return c
    end
    c = stringsCompare(ast.getDiagnosticMessageIdentity(d1), ast.getDiagnosticMessageIdentity(d2))
    if c ~= 0 then
        return c
    end
    c = slicesCompare(d1:MessageArgs(), d2:MessageArgs())
    if c ~= 0 then
        return c
    end
    c = ast.compareMessageChainSize(d1:MessageChain(), d2:MessageChain())
    if c ~= 0 then
        return c
    end
    c = ast.compareMessageChainContent(d1:MessageChain(), d2:MessageChain())
    if c ~= 0 then
        return c
    end
    return ast.compareRelatedInfo(d1:RelatedInformation(), d2:RelatedInformation())
end
