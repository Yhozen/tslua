local format = require("tslua.format")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local scanner = require("tslua.scanner")

local Kind = ast.Kind
local Tristate = core.Tristate

local FormattingContext = {}
FormattingContext.__index = FormattingContext
format.FormattingContext = FormattingContext

local zeroTextRangeWithKind = { loc = core.NewTextRange(0, 0), kind = Kind.Unknown }

function format.NewFormattingContext(file, kind, options)
    local res = setmetatable({
        currentTokenSpan = zeroTextRangeWithKind,
        nextTokenSpan = zeroTextRangeWithKind,
        contextNode = nil,
        currentTokenParent = nil,
        nextTokenParent = nil,

        contextNodeAllOnSameLine = Tristate.TSUnknown,
        nextNodeAllOnSameLine = Tristate.TSUnknown,
        tokensAreOnSameLine = Tristate.TSUnknown,
        contextNodeBlockIsOnOneLine = Tristate.TSUnknown,
        nextNodeBlockIsOnOneLine = Tristate.TSUnknown,

        sourceFile = file,
        formattingRequestKind = kind,
        options = options,
    }, FormattingContext)
    return res
end

function FormattingContext:UpdateContext(cur, curParent, next_, nextParent, commonParent)
    if curParent == nil then
        error("nil current range node parent in update context")
    end
    if nextParent == nil then
        error("nil next range node parent in update context")
    end
    if commonParent == nil then
        error("nil common parent node in update context")
    end
    self.currentTokenSpan = cur
    self.currentTokenParent = curParent
    self.nextTokenSpan = next_
    self.nextTokenParent = nextParent
    self.contextNode = commonParent

    -- drop cached results
    self.contextNodeAllOnSameLine = Tristate.TSUnknown
    self.nextNodeAllOnSameLine = Tristate.TSUnknown
    self.tokensAreOnSameLine = Tristate.TSUnknown
    self.contextNodeBlockIsOnOneLine = Tristate.TSUnknown
    self.nextNodeBlockIsOnOneLine = Tristate.TSUnknown
end

function FormattingContext:rangeIsOnOneLine(node)
    if format.rangeIsOnOneLine(node, self.sourceFile) then
        return Tristate.TSTrue
    end
    return Tristate.TSFalse
end

function FormattingContext:nodeIsOnOneLine(node)
    return self:rangeIsOnOneLine(format.withTokenStart(node, self.sourceFile))
end

function format.withTokenStart(loc, file)
    local startPos = scanner.GetTokenPosOfNode(loc, file, false)
    return core.NewTextRange(startPos, loc:End())
end

function FormattingContext:blockIsOnOneLine(node)
    local openBrace = astnav.FindChildOfKind(node, Kind.OpenBraceToken, self.sourceFile)
    local closeBrace = astnav.FindChildOfKind(node, Kind.CloseBraceToken, self.sourceFile)
    if openBrace ~= nil and closeBrace ~= nil then
        local closeBraceStart = scanner.GetTokenPosOfNode(closeBrace, self.sourceFile, false)
        return self:rangeIsOnOneLine(core.NewTextRange(openBrace:End(), closeBraceStart))
    end
    return Tristate.TSFalse
end

function FormattingContext:ContextNodeAllOnSameLine()
    if self.contextNodeAllOnSameLine == Tristate.TSUnknown then
        self.contextNodeAllOnSameLine = self:nodeIsOnOneLine(self.contextNode)
    end
    return self.contextNodeAllOnSameLine == Tristate.TSTrue
end

function FormattingContext:NextNodeAllOnSameLine()
    if self.nextNodeAllOnSameLine == Tristate.TSUnknown then
        self.nextNodeAllOnSameLine = self:nodeIsOnOneLine(self.nextTokenParent)
    end
    return self.nextNodeAllOnSameLine == Tristate.TSTrue
end

function FormattingContext:TokensAreOnSameLine()
    if self.tokensAreOnSameLine == Tristate.TSUnknown then
        self.tokensAreOnSameLine = self:rangeIsOnOneLine(core.NewTextRange(self.currentTokenSpan.loc:Pos(),
            self.nextTokenSpan.loc:End()))
    end
    return self.tokensAreOnSameLine == Tristate.TSTrue
end

function FormattingContext:ContextNodeBlockIsOnOneLine()
    if self.contextNodeBlockIsOnOneLine == Tristate.TSUnknown then
        self.contextNodeBlockIsOnOneLine = self:blockIsOnOneLine(self.contextNode)
    end
    return self.contextNodeBlockIsOnOneLine == Tristate.TSTrue
end

function FormattingContext:NextNodeBlockIsOnOneLine()
    if self.nextNodeBlockIsOnOneLine == Tristate.TSUnknown then
        self.nextNodeBlockIsOnOneLine = self:blockIsOnOneLine(self.nextTokenParent)
    end
    return self.nextNodeBlockIsOnOneLine == Tristate.TSTrue
end
