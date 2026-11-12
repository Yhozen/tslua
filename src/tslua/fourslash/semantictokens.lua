local fourslash = require("tslua.fourslash")
local lsproto = require("tslua.lsp.lsproto")
local lsconv = require("tslua.ls.lsconv")
local gort = require("tslua.fourslash.goruntime")

local FourslashTest = fourslash.FourslashTest

function FourslashTest:VerifySemanticTokens(t, expected)
    t:Helper()
    local params = lsproto.SemanticTokensParams({
        textDocument = lsproto.TextDocumentIdentifier({ uri = lsconv.FileNameToDocumentURI(self.activeFilename) }),
    })
    local result = fourslash.sendRequest(t, self, lsproto.TextDocumentSemanticTokensFullInfo, params)
    if result.semanticTokens == nil then
        if gort.len(expected) == 0 then
            return
        end
        t:Fatal("Expected semantic tokens but got nil")
    end
    local actual = fourslash.decodeSemanticTokens(self, result.semanticTokens.data, self.semanticTokenTypes, self.semanticTokenModifiers)
    if gort.len(actual) ~= gort.len(expected) then
        t:Fatalf([[
Expected %d semantic tokens, got %d

Expected:
%s

Actual:
%s]], gort.len(expected), gort.len(actual), fourslash.formatSemanticTokens(expected), fourslash.formatSemanticTokens(actual))
    end
    for i1, exp in gort.ipairs(expected) do
        local i = i1 - 1
        local act = actual[i + 1]
        if (exp.type ~= act.type) or (exp.text ~= act.text) then
            t:Errorf([[
Token %d mismatch:
  Expected: {Type: %q, Text: %q}
  Actual:   {Type: %q, Text: %q}]], i, exp.type, exp.text, act.type, act.text)
        end
    end
end

function fourslash.decodeSemanticTokens(f, data, tokenTypes, tokenModifiers)
    if (gort.imod(gort.len(data), 5)) ~= 0 then
        error(gort.fmt.Sprintf("Invalid semantic tokens data length: %d", gort.len(data)), 0)
    end
    local scriptInfo = f.scriptInfos[f.activeFilename]
    local converters = fourslash.newTestConverters(lsconv.NewConverters(lsproto.PositionEncodingKind.UTF8, function(_p3)
        return scriptInfo.lineMap
    end))
    local tokens = nil
    local prevLine = 0
    local prevChar = 0
    do
        local i = 0
        while i < gort.len(data) do
            local deltaLine = data[i + 1]
            local deltaChar = data[(i + 1) + 1]
            local length = data[(i + 2) + 1]
            local tokenTypeIdx = data[(i + 3) + 1]
            local tokenModifierMask = data[(i + 4) + 1]
            local line = prevLine + deltaLine
            local char = 0
            if deltaLine == 0 then
                char = prevChar + deltaChar
            else
                char = deltaChar
            end
            if tokenTypeIdx >= gort.len(tokenTypes) then
                error(gort.fmt.Sprintf("Token type index out of range: %d", tokenTypeIdx), 0)
            end
            local tokenType = tokenTypes[tokenTypeIdx + 1]
            local modifiers = nil
            for i5, mod in gort.ipairs(tokenModifiers) do
                local i = i5 - 1
                if (tokenModifierMask & ((1 << i))) ~= 0 then
                    modifiers = gort.append(modifiers, mod)
                end
            end
            local typeStr = tokenType
            if gort.len(modifiers) > 0 then
                typeStr = (typeStr .. ".") .. gort.strings.Join(modifiers, ".")
            end
            local startPos = lsproto.Position({ line = line, character = char })
            local endPos = lsproto.Position({ line = line, character = char + length })
            local startOffset = converters:LineAndCharacterToPosition(scriptInfo, startPos)
            local endOffset = converters:LineAndCharacterToPosition(scriptInfo, endPos)
            local text = string.sub(scriptInfo.content, startOffset + 1, endOffset)
            tokens = gort.append(tokens, { type = typeStr, text = text })
            prevLine = line
            prevChar = char
            i = i + 5
        end
    end
    return tokens
end

function fourslash.formatSemanticTokens(tokens)
    local lines = nil
    for i7, tok in gort.ipairs(tokens) do
        local i = i7 - 1
        lines = gort.append(lines, gort.fmt.Sprintf("  [%d] {Type: %q, Text: %q}", i, tok.type, tok.text))
    end
    return gort.strings.Join(lines, "\n")
end

