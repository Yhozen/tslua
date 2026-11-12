local lsutil = require("tslua.ls.lsutil")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local core = require("tslua.core")
local scanner = require("tslua.scanner")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")
local strings = require("tslua.module").strings

local Kind = ast.Kind
local NodeFlags = ast.NodeFlags
local Tristate = core.Tristate

function lsutil.ProbablyUsesSemicolons(file)
    local withSemicolon = 0
    local withoutSemicolon = 0
    local nStatementsToObserve = 5

    local visit
    visit = function(node)
        if node.flags & NodeFlags.Reparsed ~= 0 then
            return false
        end
        if lsutil.SyntaxRequiresTrailingSemicolonOrASI(node.kind) then
            local lastToken = lsutil.GetLastToken(node, file)
            if lastToken ~= nil and lastToken.kind == Kind.SemicolonToken then
                withSemicolon = withSemicolon + 1
            else
                withoutSemicolon = withoutSemicolon + 1
            end
        elseif lsutil.SyntaxRequiresTrailingCommaOrSemicolonOrASI(node.kind) then
            local lastToken = lsutil.GetLastToken(node, file)
            if lastToken ~= nil and lastToken.kind == Kind.SemicolonToken then
                withSemicolon = withSemicolon + 1
            elseif lastToken ~= nil and lastToken.kind ~= Kind.CommaToken then
                local lastTokenLine = scanner.GetECMALineOfPosition(
                    file,
                    astnav.GetStartOfNode(lastToken, file, false --[[includeJSDoc]])
                )
                local nextTokenLine = scanner.GetECMALineOfPosition(
                    file,
                    scanner.SkipTrivia(file:Text(), lastToken:End())
                )
                -- Avoid counting missing semicolon in single-line objects:
                -- `function f(p: { x: string /*no semicolon here is insignificant*/ }) {`
                if lastTokenLine ~= nextTokenLine then
                    withoutSemicolon = withoutSemicolon + 1
                end
            end
        end

        if withSemicolon + withoutSemicolon >= nStatementsToObserve then
            return true
        end

        return node:ForEachChild(visit)
    end

    file:ForEachChild(visit)

    -- One statement missing a semicolon isn't sufficient evidence to say the user
    -- doesn't want semicolons, because they may not even be done writing that statement.
    if withSemicolon == 0 and withoutSemicolon <= 1 then
        return true
    end

    -- When both kinds of observation exist, treat the file as using semicolons when the
    -- ratio withSemicolon/withoutSemicolon exceeds 1/nStatementsToObserve (real arithmetic),
    -- implemented as an integer inequality to avoid truncation.
    if withoutSemicolon == 0 then
        return true
    end
    return withSemicolon * nStatementsToObserve > withoutSemicolon
end

function lsutil.ShouldUseUriStyleNodeCoreModules(file, program)
    for _, node in ipairs(file:Imports() or {}) do
        if core.NodeCoreModules()[node:Text()] and not core.ExclusivelyPrefixedNodeCoreModules[node:Text()] then
            if strings.HasPrefix(node:Text(), "node:") then
                return Tristate.TSTrue
            else
                return Tristate.TSFalse
            end
        end
    end

    return program:UsesUriStyleNodeCoreModules()
end

function lsutil.QuotePreferenceFromString(str)
    if str.tokenFlags & ast.TokenFlags.SingleQuote ~= 0 then
        return lsutil.QuotePreference.Single
    end
    return lsutil.QuotePreference.Double
end

function lsutil.GetQuotePreference(sourceFile, preferences)
    if preferences.quotePreference ~= "" and preferences.quotePreference ~= "auto" then
        if preferences.quotePreference == "single" then
            return lsutil.QuotePreference.Single
        end
        return lsutil.QuotePreference.Double
    end
    -- ignore synthetic import added when importHelpers: true
    local firstModuleSpecifier = core.Find(sourceFile:Imports(), function(n)
        return ast.IsStringLiteral(n) and not ast.NodeIsSynthesized(n.parent)
    end)
    if firstModuleSpecifier ~= nil then
        return lsutil.QuotePreferenceFromString(firstModuleSpecifier:AsStringLiteral())
    end
    return lsutil.QuotePreference.Double
end

function lsutil.ModuleSymbolToValidIdentifier(moduleSymbol, forceCapitalize)
    return lsutil.ModuleSpecifierToValidIdentifier(stringutil.StripQuotes(moduleSymbol.name), forceCapitalize)
end

function lsutil.ModuleSpecifierToValidIdentifier(moduleSpecifier, forceCapitalize)
    local baseName = tspath.GetBaseFileName(strings.TrimSuffix(tspath.RemoveAnyFileExtension(moduleSpecifier), "/index"))
    local res = {}
    local lastCharWasValid = true
    local baseNameRunes = core.StringToRunes(baseName)
    if #baseNameRunes > 0 and scanner.IsIdentifierStart(baseNameRunes[1]) then
        if forceCapitalize then
            res[#res + 1] = stringutil.UnicodeToUpper(baseNameRunes[1])
        else
            res[#res + 1] = baseNameRunes[1]
        end
    else
        lastCharWasValid = false
    end

    for i = 1, #baseNameRunes - 1 do
        local isValid = scanner.IsIdentifierPart(baseNameRunes[i + 1])
        if isValid then
            if not lastCharWasValid then
                res[#res + 1] = stringutil.UnicodeToUpper(baseNameRunes[i + 1])
            else
                res[#res + 1] = baseNameRunes[i + 1]
            end
        end
        lastCharWasValid = isValid
    end

    -- Need `"_"` to ensure result isn't empty.
    local resString = core.RunesToString(res)
    if resString ~= "" and not lsutil.IsNonContextualKeyword(scanner.StringToToken(resString)) then
        return resString
    end
    return "_" .. resString
end

function lsutil.IsNonContextualKeyword(token)
    return ast.IsKeywordKind(token) and not ast.IsContextualKeyword(token)
end
