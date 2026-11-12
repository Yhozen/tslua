local lsutil = require("tslua.ls.lsutil")
local ast = require("tslua.ast")
local core = require("tslua.core")
local stringutil = require("tslua.stringutil")
local tspath = require("tslua.tspath")
local strings = require("tslua.module").strings
local unicodeTables = require("tslua.ls.lsutil.unicode_generated")

local Kind = ast.Kind
local Tristate = core.Tristate
local OrganizeImportsSort = lsutil.OrganizeImportsSort
local OrganizeImportsCollation = lsutil.OrganizeImportsCollation
local OrganizeImportsCaseFirst = lsutil.OrganizeImportsCaseFirst
local OrganizeImportsTypeOrder = lsutil.OrganizeImportsTypeOrder

local function cmpCompare(a, b)
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

-- FilterImportDeclarations filters out non-import declarations from a list of statements.
function lsutil.FilterImportDeclarations(statements)
    return core.Filter(statements, function(stmt)
        return stmt.kind == Kind.ImportDeclaration
    end)
end

-- GetDetectionLists returns the lists of comparers and type orders to test for organize imports detection.
-- Returns (comparersToTest, typeOrdersToTest).
function lsutil.GetDetectionLists(preferences)
    local comparersToTest, typeOrdersToTest
    if preferences.organizeImportsSort ~= OrganizeImportsSort.Auto then
        comparersToTest = { lsutil.getOrganizeImportsPresetStringComparer(preferences.organizeImportsSort) }
    elseif not core.Tristate_IsUnknown(preferences.organizeImportsIgnoreCase) then
        comparersToTest = { lsutil.getOrganizeImportsStringComparer(preferences, core.Tristate_IsTrue(preferences.organizeImportsIgnoreCase)) }
    else
        comparersToTest = {
            lsutil.getOrganizeImportsStringComparer(preferences, true),
            lsutil.getOrganizeImportsStringComparer(preferences, false),
        }
    end

    if preferences.organizeImportsTypeOrder ~= OrganizeImportsTypeOrder.Auto then
        typeOrdersToTest = { preferences.organizeImportsTypeOrder }
    else
        typeOrdersToTest = {
            OrganizeImportsTypeOrder.Last,
            OrganizeImportsTypeOrder.Inline,
            OrganizeImportsTypeOrder.First,
        }
    end

    return comparersToTest, typeOrdersToTest
end

function lsutil.ResolveOrganizeImportsSort(preferences)
    if preferences.organizeImportsSort ~= OrganizeImportsSort.Auto then
        return preferences.organizeImportsSort
    end

    if preferences.organizeImportsCollation == OrganizeImportsCollation.Unicode then
        if preferences.organizeImportsIgnoreCase == Tristate.TSTrue then
            return OrganizeImportsSort.NaturalIgnoreCase
        elseif preferences.organizeImportsIgnoreCase == Tristate.TSFalse then
            return OrganizeImportsSort.Natural
        else
            return OrganizeImportsSort.Auto
        end
    end

    if preferences.organizeImportsIgnoreCase == Tristate.TSTrue then
        return OrganizeImportsSort.OrdinalIgnoreCase
    elseif preferences.organizeImportsIgnoreCase == Tristate.TSFalse then
        return OrganizeImportsSort.Ordinal
    else
        return OrganizeImportsSort.Auto
    end
end

function lsutil.getOrganizeImportsOrdinalStringComparer(ignoreCase)
    if ignoreCase then
        return stringutil.CompareStringsCaseInsensitiveEslintCompatible
    end
    return stringutil.CompareStringsCaseSensitive
end

function lsutil.getOrganizeImportsNaturalStringComparer(caseSensitive)
    return function(a, b)
        return lsutil.compareOrganizeImportsNaturalStrings(a, b, caseSensitive)
    end
end

function lsutil.getOrganizeImportsUnicodeStringComparer(ignoreCase, preferences)
    local caseFirst = preferences.organizeImportsCaseFirst
    local numeric = core.Tristate_IsTrue(preferences.organizeImportsNumericCollation)
    local accents = not core.Tristate_IsFalse(preferences.organizeImportsAccentCollation)

    return function(a, b)
        return lsutil.compareOrganizeImportsUnicodeStrings(a, b, ignoreCase, caseFirst, numeric, accents)
    end
end

function lsutil.compareOrganizeImportsNaturalStrings(a, b, caseSensitive)
    local c = lsutil.compareStringsNumeric(lsutil.naturalCollationKey(a), lsutil.naturalCollationKey(b))
    if c ~= 0 then
        return c
    end

    if caseSensitive then
        c = lsutil.compareOrganizeImportsCaseUpperFirst(a, b)
        if c ~= 0 then
            return c
        end
    end

    return strings.Compare(a, b)
end

function lsutil.compareOrganizeImportsUnicodeStrings(a, b, ignoreCase, caseFirst, numeric, accents)
    local c = lsutil.compareOrganizeImportsUnicodeKeys(lsutil.naturalCollationKey(a), lsutil.naturalCollationKey(b), numeric)
    if c ~= 0 then
        return c
    end

    if accents then
        c = lsutil.compareOrganizeImportsUnicodeKeys(stringutil.StringsToLower(a), stringutil.StringsToLower(b), numeric)
        if c ~= 0 then
            return c
        end
    end

    if not ignoreCase then
        c = lsutil.compareOrganizeImportsCase(a, b, caseFirst)
        if c ~= 0 then
            return c
        end
    end

    return strings.Compare(a, b)
end

function lsutil.naturalCollationKey(s)
    return stringutil.StringsToLower(lsutil.removeDiacritics(s))
end

-- Go norm.NFD.String: full canonical decomposition followed by canonical reordering of
-- combining marks.
local SBase, LBase, VBase, TBase = 0xAC00, 0x1100, 0x1161, 0x11A7
local VCount, TCount = 21, 28
local NCount = VCount * TCount
local SCount = 11172

function lsutil.nfdRunes(s)
    local out = {}
    local decomp = unicodeTables.decomp
    for _, r in core.Runes(s) do
        if r >= SBase and r < SBase + SCount then
            local sIndex = r - SBase
            out[#out + 1] = LBase + sIndex // NCount
            out[#out + 1] = VBase + (sIndex % NCount) // TCount
            local t = TBase + sIndex % TCount
            if t ~= TBase then
                out[#out + 1] = t
            end
        else
            local d = decomp[r]
            if d ~= nil then
                for _, x in ipairs(d) do
                    out[#out + 1] = x
                end
            else
                out[#out + 1] = r
            end
        end
    end
    -- canonical ordering: stable sort of each run of non-starters by combining class
    local ccc = unicodeTables.ccc
    local i = 1
    local n = #out
    while i <= n do
        if ccc[out[i]] ~= nil then
            local j = i
            while j + 1 <= n and ccc[out[j + 1]] ~= nil do
                j = j + 1
            end
            if j > i then
                -- insertion sort (stable)
                for k = i + 1, j do
                    local v = out[k]
                    local cv = ccc[v]
                    local m = k - 1
                    while m >= i and ccc[out[m]] > cv do
                        out[m + 1] = out[m]
                        m = m - 1
                    end
                    out[m + 1] = v
                end
            end
            i = j + 1
        else
            i = i + 1
        end
    end
    return out
end

function lsutil.removeDiacritics(s)
    local parts = {}
    for _, r in ipairs(lsutil.nfdRunes(s)) do
        if not stringutil.unicodeIs(unicodeTables.mn, r) then
            parts[#parts + 1] = core.EncodeRune(r)
        end
    end
    return table.concat(parts)
end

function lsutil.compareOrganizeImportsUnicodeKeys(a, b, numeric)
    if numeric then
        return lsutil.compareStringsNumeric(a, b)
    end
    return strings.Compare(a, b)
end

function lsutil.compareStringsNumeric(a, b)
    while #a > 0 and #b > 0 do
        if lsutil.isASCIIDigit(string.byte(a, 1)) and lsutil.isASCIIDigit(string.byte(b, 1)) then
            local aRunEnd = lsutil.asciiDigitRunEnd(a)
            local bRunEnd = lsutil.asciiDigitRunEnd(b)

            local c = lsutil.compareNumericText(string.sub(a, 1, aRunEnd), string.sub(b, 1, bRunEnd))
            if c ~= 0 then
                return c
            end

            a = string.sub(a, aRunEnd + 1)
            b = string.sub(b, bRunEnd + 1)
            goto continue
        end

        do
            local aRune, aSize = core.DecodeRune(a, 0)
            local bRune, bSize = core.DecodeRune(b, 0)
            if aRune ~= bRune then
                return cmpCompare(aRune, bRune)
            end

            a = string.sub(a, aSize + 1)
            b = string.sub(b, bSize + 1)
        end
        ::continue::
    end

    return cmpCompare(#a, #b)
end

function lsutil.isASCIIDigit(ch)
    return ch >= 0x30 and ch <= 0x39
end

function lsutil.asciiDigitRunEnd(s)
    local i = 0
    while i < #s and lsutil.isASCIIDigit(string.byte(s, i + 1)) do
        i = i + 1
    end
    return i
end

function lsutil.compareNumericText(a, b)
    local aDigits = string.gsub(a, "^0+", "")
    local bDigits = string.gsub(b, "^0+", "")
    if aDigits == "" then
        aDigits = "0"
    end
    if bDigits == "" then
        bDigits = "0"
    end

    if #aDigits ~= #bDigits then
        return cmpCompare(#aDigits, #bDigits)
    end
    local c = strings.Compare(aDigits, bDigits)
    if c ~= 0 then
        return c
    end
    return strings.Compare(a, b)
end

function lsutil.compareOrganizeImportsCaseUpperFirst(a, b)
    return lsutil.compareOrganizeImportsCase(a, b, OrganizeImportsCaseFirst.Upper)
end

function lsutil.compareOrganizeImportsCase(a, b, caseFirst)
    local aRunes = core.StringToRunes(a)
    local bRunes = core.StringToRunes(b)
    local minLen = math.min(#aRunes, #bRunes)

    for i = 1, minLen do
        local aUpper = stringutil.UnicodeIsUpper(aRunes[i])
        local bUpper = stringutil.UnicodeIsUpper(bRunes[i])
        if aUpper ~= bUpper then
            if caseFirst == OrganizeImportsCaseFirst.Upper then
                if aUpper then
                    return -1
                end
                return 1
            elseif caseFirst == OrganizeImportsCaseFirst.Lower then
                if not aUpper then
                    return -1
                end
                return 1
            else
                if aUpper then
                    return 1
                end
                return -1
            end
        end
    end

    return cmpCompare(#aRunes, #bRunes)
end

function lsutil.getOrganizeImportsPresetStringComparer(sort)
    if sort == OrganizeImportsSort.OrdinalIgnoreCase then
        return lsutil.getOrganizeImportsOrdinalStringComparer(true)
    elseif sort == OrganizeImportsSort.Natural then
        return lsutil.getOrganizeImportsNaturalStringComparer(true)
    elseif sort == OrganizeImportsSort.NaturalIgnoreCase then
        return lsutil.getOrganizeImportsNaturalStringComparer(false)
    else
        return lsutil.getOrganizeImportsOrdinalStringComparer(false)
    end
end

function lsutil.getOrganizeImportsStringComparer(preferences, ignoreCase)
    if preferences.organizeImportsSort ~= OrganizeImportsSort.Auto then
        return lsutil.getOrganizeImportsPresetStringComparer(preferences.organizeImportsSort)
    end
    if preferences.organizeImportsCollation == OrganizeImportsCollation.Unicode then
        return lsutil.getOrganizeImportsUnicodeStringComparer(ignoreCase, preferences)
    end
    return lsutil.getOrganizeImportsOrdinalStringComparer(ignoreCase)
end

function lsutil.getModuleSpecifierExpression(declaration)
    local kind = declaration.kind
    if kind == Kind.ImportEqualsDeclaration then
        local importEquals = declaration:AsImportEqualsDeclaration()
        if importEquals.moduleReference.kind == Kind.ExternalModuleReference then
            return importEquals.moduleReference:Expression()
        end
        return nil
    elseif kind == Kind.ImportDeclaration then
        return declaration:ModuleSpecifier()
    elseif kind == Kind.VariableStatement then
        local declarations = declaration:AsVariableStatement().declarationList:AsVariableDeclarationList().declarations.nodes
        if #declarations > 0 then
            local initializer = declarations[1]:Initializer()
            if initializer ~= nil and initializer.kind == Kind.CallExpression then
                local callExpr = initializer:AsCallExpression()
                if #callExpr.arguments.nodes > 0 then
                    return callExpr.arguments.nodes[1]
                end
            end
        end
        return nil
    else
        return nil
    end
end

-- GetExternalModuleName returns the module name from a module specifier expression.
function lsutil.GetExternalModuleName(specifier)
    if specifier ~= nil and ast.IsStringLiteralLike(specifier) then
        return specifier:Text()
    end
    return ""
end

-- CompareModuleSpecifiers compares two module specifiers using the given comparer.
function lsutil.CompareModuleSpecifiers(m1, m2, comparer)
    local name1 = lsutil.GetExternalModuleName(m1)
    local name2 = lsutil.GetExternalModuleName(m2)
    local c = core.CompareBooleans(name1 == "", name2 == "")
    if c ~= 0 then
        return c
    end
    c = core.CompareBooleans(tspath.IsExternalModuleNameRelative(name1), tspath.IsExternalModuleNameRelative(name2))
    if c ~= 0 then
        return c
    end
    return comparer(name1, name2)
end

function lsutil.compareImportKind(s1, s2)
    return cmpCompare(lsutil.getImportKindOrder(s1), lsutil.getImportKindOrder(s2))
end

-- getImportKindOrder returns the sort order for different import kinds:
-- 1. Side-effect imports
-- 2. Type-only imports
-- 3. Namespace imports
-- 4. Default imports
-- 5. Named imports
-- 6. ImportEqualsDeclarations
-- 7. Require variable statements
lsutil.importKindOrderSideEffect = 0
lsutil.importKindOrderTypeOnly = 1
lsutil.importKindOrderNamespace = 2
lsutil.importKindOrderDefault = 3
lsutil.importKindOrderNamed = 4
lsutil.importKindOrderImportEquals = 5
lsutil.importKindOrderRequire = 6
lsutil.importKindOrderUnknown = 7

function lsutil.getImportKindOrder(s1)
    local kind = s1.kind
    if kind == Kind.ImportDeclaration then
        local importDecl = s1:AsImportDeclaration()
        if importDecl.importClause == nil then
            return lsutil.importKindOrderSideEffect
        end
        local importClause = importDecl.importClause:AsImportClause()
        if importClause:IsTypeOnly() then
            return lsutil.importKindOrderTypeOnly
        end
        if importClause.namedBindings ~= nil and importClause.namedBindings.kind == Kind.NamespaceImport then
            return lsutil.importKindOrderNamespace
        end
        if importClause:Name() ~= nil then
            return lsutil.importKindOrderDefault
        end
        return lsutil.importKindOrderNamed
    elseif kind == Kind.ImportEqualsDeclaration then
        return lsutil.importKindOrderImportEquals
    elseif kind == Kind.VariableStatement then
        return lsutil.importKindOrderRequire
    else
        return lsutil.importKindOrderUnknown
    end
end

-- CompareImportsOrRequireStatements compares two import or require statements.
function lsutil.CompareImportsOrRequireStatements(s1, s2, comparer)
    local c = lsutil.CompareModuleSpecifiers(lsutil.getModuleSpecifierExpression(s1), lsutil.getModuleSpecifierExpression(s2), comparer)
    if c ~= 0 then
        return c
    end
    return lsutil.compareImportKind(s1, s2)
end

function lsutil.compareImportOrExportSpecifiers(s1, s2, comparer, preferences)
    local typeOrder = preferences.organizeImportsTypeOrder

    local s1Name = s1:Name():Text()
    local s2Name = s2:Name():Text()

    if typeOrder == OrganizeImportsTypeOrder.First then
        local c = core.CompareBooleans(s2:IsTypeOnly(), s1:IsTypeOnly())
        if c ~= 0 then
            return c
        end
        return comparer(s1Name, s2Name)
    elseif typeOrder == OrganizeImportsTypeOrder.Inline then
        return comparer(s1Name, s2Name)
    else -- OrganizeImportsTypeOrderLast
        local c = core.CompareBooleans(s1:IsTypeOnly(), s2:IsTypeOnly())
        if c ~= 0 then
            return c
        end
        return comparer(s1Name, s2Name)
    end
end

-- GetNamedImportSpecifierComparer returns a comparer function for sorting import specifiers.
function lsutil.GetNamedImportSpecifierComparer(preferences, comparer)
    if comparer == nil then
        local ignoreCase = false
        if not core.Tristate_IsUnknown(preferences.organizeImportsIgnoreCase) then
            ignoreCase = core.Tristate_IsTrue(preferences.organizeImportsIgnoreCase)
        end
        comparer = lsutil.getOrganizeImportsStringComparer(preferences, ignoreCase)
    end
    return function(s1, s2)
        return lsutil.compareImportOrExportSpecifiers(s1, s2, comparer, preferences)
    end
end

-- GetImportSpecifierInsertionIndex returns the index at which to insert a new import specifier.
function lsutil.GetImportSpecifierInsertionIndex(sortedImports, newImport, comparer)
    return core.FirstResult(core.BinarySearchUniqueFunc(sortedImports, function(_, value)
        return comparer(value, newImport)
    end))
end

-- GetImportDeclarationInsertIndex returns the index at which to insert a new import declaration.
function lsutil.GetImportDeclarationInsertIndex(sortedImports, newImport, comparer)
    return core.FirstResult(core.BinarySearchUniqueFunc(sortedImports, function(_, value)
        return comparer(value, newImport)
    end))
end

-- GetOrganizeImportsStringComparerWithDetection returns a string comparer based on detecting the order of import statements by the module specifier
-- Returns (comparer, isSorted).
function lsutil.GetOrganizeImportsStringComparerWithDetection(originalImportDecls, preferences)
    local result, sorted = lsutil.DetectModuleSpecifierCaseBySort({ originalImportDecls }, lsutil.getComparers(preferences))
    return result, sorted
end

function lsutil.getComparers(preferences)
    if preferences.organizeImportsSort ~= OrganizeImportsSort.Auto or not core.Tristate_IsUnknown(preferences.organizeImportsIgnoreCase) then
        local ignoreCase = false
        if not core.Tristate_IsUnknown(preferences.organizeImportsIgnoreCase) then
            ignoreCase = core.Tristate_IsTrue(preferences.organizeImportsIgnoreCase)
        end
        return { lsutil.getOrganizeImportsStringComparer(preferences, ignoreCase) }
    end
    return {
        lsutil.getOrganizeImportsStringComparer(preferences, true),
        lsutil.getOrganizeImportsStringComparer(preferences, false),
    }
end

-- namedImportSortResult: { namedImportComparer, typeOrder, isSorted }

-- DetectNamedImportOrganizationBySort detects the order of named imports throughout the file by considering the named imports in each statement as a group
-- Returns (comparer, typeOrder, found).
function lsutil.DetectNamedImportOrganizationBySort(originalGroups, comparersToTest, typesToTest)
    local result = lsutil.detectNamedImportOrganizationBySort(originalGroups, comparersToTest, typesToTest)
    if result == nil then
        return nil, OrganizeImportsTypeOrder.Last, false
    end
    return result.namedImportComparer, result.typeOrder, true
end

function lsutil.detectNamedImportOrganizationBySort(originalGroups, comparersToTest, typesToTest)
    local bothNamedImports = false
    local importDeclsWithNamed = {}

    for _, imp in ipairs(originalGroups) do
        if imp:AsImportDeclaration().importClause == nil then
            goto continue
        end
        do
            local clause = imp:AsImportDeclaration().importClause:AsImportClause()
            if clause.namedBindings == nil or clause.namedBindings.kind ~= Kind.NamedImports then
                goto continue
            end
            local namedImports = clause.namedBindings:AsNamedImports()
            if #namedImports.elements.nodes == 0 then
                goto continue
            end

            if not bothNamedImports then
                local hasTypeOnly = false
                local hasRegular = false
                for _, elem in ipairs(namedImports.elements.nodes) do
                    if elem:IsTypeOnly() then
                        hasTypeOnly = true
                    else
                        hasRegular = true
                    end
                end
                if hasTypeOnly and hasRegular then
                    bothNamedImports = true
                end
            end

            importDeclsWithNamed[#importDeclsWithNamed + 1] = imp
        end
        ::continue::
    end

    if #importDeclsWithNamed == 0 then
        return nil
    end

    local namedImportsByDecl = {}
    for _, imp in ipairs(importDeclsWithNamed) do
        local clause = imp:AsImportDeclaration().importClause:AsImportClause()
        local namedImports = clause.namedBindings:AsNamedImports()
        namedImportsByDecl[#namedImportsByDecl + 1] = namedImports.elements.nodes
    end

    if not bothNamedImports or #typesToTest == 0 then
        local namesList = {}
        for i, imports in ipairs(namedImportsByDecl) do
            local names = {}
            for j, imp in ipairs(imports) do
                names[j] = imp:Name():Text()
            end
            namesList[i] = names
        end
        local sortState = lsutil.detectCaseSensitivityBySort(namesList, comparersToTest)
        local typeOrder = OrganizeImportsTypeOrder.Last
        if #typesToTest == 1 then
            typeOrder = typesToTest[1]
        end
        return {
            namedImportComparer = sortState.comparer,
            typeOrder = typeOrder,
            isSorted = sortState.isSorted,
        }
    end

    local bestDiff = {
        [OrganizeImportsTypeOrder.First] = math.maxinteger,
        [OrganizeImportsTypeOrder.Last] = math.maxinteger,
        [OrganizeImportsTypeOrder.Inline] = math.maxinteger,
    }
    local bestComparer = {
        [OrganizeImportsTypeOrder.First] = comparersToTest[1],
        [OrganizeImportsTypeOrder.Last] = comparersToTest[1],
        [OrganizeImportsTypeOrder.Inline] = comparersToTest[1],
    }

    for _, curComparer in ipairs(comparersToTest) do
        local currDiff = {
            [OrganizeImportsTypeOrder.First] = 0,
            [OrganizeImportsTypeOrder.Last] = 0,
            [OrganizeImportsTypeOrder.Inline] = 0,
        }

        for _, importDecl in ipairs(namedImportsByDecl) do
            for _, typeOrder in ipairs(typesToTest) do
                local prefs = lsutil.UserPreferences_new({ organizeImportsTypeOrder = typeOrder })
                local diff = lsutil.measureSortedness(importDecl, function(n1, n2)
                    return lsutil.compareImportOrExportSpecifiers(n1, n2, curComparer, prefs)
                end)
                currDiff[typeOrder] = (currDiff[typeOrder] or 0) + diff
            end
        end

        for _, typeOrder in ipairs(typesToTest) do
            if (currDiff[typeOrder] or 0) < (bestDiff[typeOrder] or 0) then
                bestDiff[typeOrder] = currDiff[typeOrder]
                bestComparer[typeOrder] = curComparer
            end
        end
    end

    for _, bestTypeOrder in ipairs(typesToTest) do
        local isBest = true
        for _, testTypeOrder in ipairs(typesToTest) do
            if (bestDiff[testTypeOrder] or 0) < (bestDiff[bestTypeOrder] or 0) then
                isBest = false
                break
            end
        end
        if isBest then
            return {
                namedImportComparer = bestComparer[bestTypeOrder],
                typeOrder = bestTypeOrder,
                isSorted = (bestDiff[bestTypeOrder] or 0) == 0,
            }
        end
    end

    return {
        namedImportComparer = bestComparer[OrganizeImportsTypeOrder.Last],
        typeOrder = OrganizeImportsTypeOrder.Last,
        isSorted = bestDiff[OrganizeImportsTypeOrder.Last] == 0,
    }
end

-- caseSensitivityDetectionResult: { comparer, isSorted }

-- DetectModuleSpecifierCaseBySort detects the order of module specifiers based on import statements throughout the module/file
-- Returns (comparer, isSorted).
function lsutil.DetectModuleSpecifierCaseBySort(importDeclsByGroup, comparersToTest)
    local moduleSpecifiersByGroup = {}
    for _, importGroup in ipairs(importDeclsByGroup) do
        local moduleNames = {}
        for _, decl in ipairs(importGroup or {}) do
            local expr = lsutil.getModuleSpecifierExpression(decl)
            if expr ~= nil then
                moduleNames[#moduleNames + 1] = lsutil.GetExternalModuleName(expr)
            else
                moduleNames[#moduleNames + 1] = ""
            end
        end
        moduleSpecifiersByGroup[#moduleSpecifiersByGroup + 1] = moduleNames
    end
    local result = lsutil.detectCaseSensitivityBySort(moduleSpecifiersByGroup, comparersToTest)
    return result.comparer, result.isSorted
end

function lsutil.detectCaseSensitivityBySort(originalGroups, comparersToTest)
    local bestComparer
    local bestDiff = math.maxinteger

    for _, curComparer in ipairs(comparersToTest) do
        local diffOfCurrentComparer = 0

        for _, listToSort in ipairs(originalGroups) do
            if #listToSort <= 1 then
                goto continue
            end
            do
                local diff = lsutil.measureSortedness(listToSort, curComparer)
                diffOfCurrentComparer = diffOfCurrentComparer + diff
            end
            ::continue::
        end

        if diffOfCurrentComparer < bestDiff then
            bestDiff = diffOfCurrentComparer
            bestComparer = curComparer
        end
    end

    if bestComparer == nil and #comparersToTest > 0 then
        bestComparer = comparersToTest[1]
    end

    return {
        comparer = bestComparer,
        isSorted = bestDiff == 0,
    }
end

function lsutil.measureSortedness(arr, comparer)
    local i = 0
    for j = 1, #arr - 1 do
        if comparer(arr[j], arr[j + 1]) > 0 then
            i = i + 1
        end
    end
    return i
end

-- GetNamedImportSpecifierComparerWithDetection returns a specifier comparer based on detecting the existing sort order within a single import statement
-- Returns (specifierComparer, isSorted).
function lsutil.GetNamedImportSpecifierComparerWithDetection(importDecl, sourceFile, preferences)
    local comparersToTest, typeOrdersToTest = lsutil.GetDetectionLists(preferences)

    local importStmt
    if importDecl.kind == Kind.ImportDeclaration then
        importStmt = importDecl
    end

    local specifierComparer = lsutil.GetNamedImportSpecifierComparer(preferences, comparersToTest[1])
    local isSorted = Tristate.TSUnknown

    if (lsutil.ResolveOrganizeImportsSort(preferences) == OrganizeImportsSort.Auto or preferences.organizeImportsTypeOrder == OrganizeImportsTypeOrder.Auto) and importStmt ~= nil then
        local detectFromDecl = lsutil.detectNamedImportOrganizationBySort({ importStmt }, comparersToTest, typeOrdersToTest)
        if detectFromDecl ~= nil then
            isSorted = core.BoolToTristate(detectFromDecl.isSorted)
            specifierComparer = lsutil.GetNamedImportSpecifierComparer(
                lsutil.UserPreferences_new({ organizeImportsTypeOrder = detectFromDecl.typeOrder }),
                detectFromDecl.namedImportComparer
            )
        elseif sourceFile ~= nil then
            local allImports = lsutil.FilterImportDeclarations(sourceFile.statements.nodes)
            local detectFromFile = lsutil.detectNamedImportOrganizationBySort(allImports, comparersToTest, typeOrdersToTest)
            if detectFromFile ~= nil then
                isSorted = core.BoolToTristate(detectFromFile.isSorted)
                specifierComparer = lsutil.GetNamedImportSpecifierComparer(
                    lsutil.UserPreferences_new({ organizeImportsTypeOrder = detectFromFile.typeOrder }),
                    detectFromFile.namedImportComparer
                )
            end
        end
    end

    return specifierComparer, isSorted
end
