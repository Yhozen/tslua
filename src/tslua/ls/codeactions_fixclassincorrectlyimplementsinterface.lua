local ls = require("tslua.ls")
local ast = require("tslua.ast")
local astnav = require("tslua.astnav")
local autoimport = require("tslua.ls.autoimport")
local change = require("tslua.ls.change")
local checker = require("tslua.checker")
local collections = require("tslua.collections")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")
local locale = require("tslua.locale")
local scanner = require("tslua.scanner")

local ModifierFlags = ast.ModifierFlags

ls.fixClassIncorrectlyImplementsInterfaceFixID = "fixClassIncorrectlyImplementsInterface"

ls.fixClassIncorrectlyImplementsInterfaceErrorCodes = {
    diagnostics.Class_0_incorrectly_implements_interface_1:Code(),
    diagnostics.Class_0_incorrectly_implements_class_1_Did_you_mean_to_extend_1_and_inherit_its_members_as_a_subclass:Code(),
}

ls.FixClassIncorrectlyImplementsInterfaceProvider = {
    errorCodes = ls.fixClassIncorrectlyImplementsInterfaceErrorCodes,
    getCodeActions = function(ctx, fixContext)
        return ls.getCodeActionsToFixClassIncorrectlyImplementsInterface(ctx, fixContext)
    end,
    fixIds = { ls.fixClassIncorrectlyImplementsInterfaceFixID },
    getAllCodeActions = function(ctx, fixContext)
        return ls.getAllCodeActionsToFixClassIncorrectlyImplementsInterface(ctx, fixContext)
    end,
}

function ls.getCodeActionsToFixClassIncorrectlyImplementsInterface(context, fixContext)
    local classDeclaration = ls.getClass(fixContext.sourceFile, fixContext.span)
    if classDeclaration == nil then
        return nil, nil
    end

    local implementsTypes = ast.GetImplementsHeritageClauseElements(classDeclaration)
    local loc = locale.FromContext(context)

    local typeChecker, done = fixContext.program:GetTypeCheckerForFile(context, fixContext.sourceFile)

    local actions = nil
    for _, implementedTypeNode in ipairs(implementsTypes or {}) do
        local changeTracker = change.NewTracker(context, fixContext.program:Options(), fixContext.ls:FormatOptions(), fixContext.ls.converters)
        local importAdder, err = ls.createImportAdder(context, fixContext, typeChecker)
        if err ~= nil then
            done()
            return nil, err
        end

        ls.addChanges(context, fixContext, changeTracker, importAdder, typeChecker, classDeclaration, implementedTypeNode)
        local changes = ls.getChanges(changeTracker, importAdder, fixContext.sourceFile)
        if core.Len(changes) == 0 then
            goto continue
        end

        actions = core.Append(actions, ls.NewCodeAction({
            description = diagnostics.Implement_interface_0:Localize(loc, scanner.GetTextOfNode(implementedTypeNode)),
            changes = changes,
            fixID = ls.fixClassIncorrectlyImplementsInterfaceFixID,
            fixAllDescription = diagnostics.Implement_all_unimplemented_interfaces:Localize(loc),
        }))

        ::continue::
    end
    done()
    return actions, nil
end

function ls.getAllCodeActionsToFixClassIncorrectlyImplementsInterface(context, fixContext)
    local typeChecker, done = fixContext.program:GetTypeCheckerForFile(context, fixContext.sourceFile)

    local changeTracker = change.NewTracker(context, fixContext.program:Options(), fixContext.ls:FormatOptions(), fixContext.ls.converters)
    local importAdder, err = ls.createImportAdder(context, fixContext, typeChecker)
    if err ~= nil then
        done()
        return nil, err
    end

    local seenClassDeclarations = collections.NewSet()

    for _, diag in ipairs(ls.getAllDiagnostics(context, fixContext.program, fixContext.sourceFile) or {}) do
        if ls.isFixableDiagnostic(diag, ls.fixClassIncorrectlyImplementsInterfaceErrorCodes) then
            local classDeclaration = ls.getClass(fixContext.sourceFile, core.NewTextRange(diag:Pos(), diag:End()))
            if classDeclaration == nil then
                goto continue
            end
            if seenClassDeclarations:AddIfAbsent(classDeclaration) then
                local implementsTypes = ast.GetImplementsHeritageClauseElements(classDeclaration)
                for _, implementedTypeNode in ipairs(implementsTypes or {}) do
                    ls.addChanges(context, fixContext, changeTracker, importAdder, typeChecker, classDeclaration, implementedTypeNode)
                end
            end
        end
        ::continue::
    end

    local changes = ls.getChanges(changeTracker, importAdder, fixContext.sourceFile)
    if core.Len(changes) == 0 then
        done()
        return nil, nil
    end

    done()
    return {
        description = diagnostics.Implement_all_unimplemented_interfaces:Localize(locale.FromContext(context)),
        changes = changes,
    }, nil
end

function ls.addChanges(context, fixContext, changeTracker, importAdder, typeChecker, classDeclaration, implementedTypeNode)
    local missingMemberFixer = ls.newMissingMemberFixer(changeTracker, fixContext.program, typeChecker, fixContext.ls:UserPreferences(), importAdder, locale.FromContext(context))
    local constructor = ls.getConstructor(classDeclaration)
    local implementedType = typeChecker:GetTypeAtLocation(implementedTypeNode)
    local classType = typeChecker:GetTypeAtLocation(classDeclaration)

    if typeChecker:GetNumberIndexType(classType) == nil then
        local member = missingMemberFixer:createIndexSignatureDeclarationFromType(classDeclaration, implementedType, typeChecker:GetNumberType())
        if member ~= nil then
            ls.insertInterfaceMemberNode(changeTracker, fixContext.sourceFile, classDeclaration, constructor, member)
        end
    end

    if typeChecker:GetStringIndexType(classType) == nil then
        local member = missingMemberFixer:createIndexSignatureDeclarationFromType(classDeclaration, implementedType, typeChecker:GetStringType())
        if member ~= nil then
            ls.insertInterfaceMemberNode(changeTracker, fixContext.sourceFile, classDeclaration, constructor, member)
        end
    end

    local missingMembers = ls.getMissingMembers(typeChecker, classDeclaration, { implementedType })
    for _, member in ipairs(missingMembers or {}) do
        local memberNodes = missingMemberFixer:createMemberFromSymbol(member, classDeclaration, fixContext.sourceFile, nil --[[body]], ls.preserveOptionalFlagsAll, false --[[abstract]])
        for _, memberNode in ipairs(memberNodes or {}) do
            ls.insertInterfaceMemberNode(changeTracker, fixContext.sourceFile, classDeclaration, constructor, memberNode)
        end
    end
end

function ls.getChanges(changeTracker, importAdder, sourceFile)
    local changes, unmappable = changeTracker:GetChanges()
    if core.Len(unmappable) ~= 0 then
        return nil
    end
    local fileChanges = changes[sourceFile:OriginalFileName()]
    if importAdder ~= nil and importAdder:HasFixes() then
        fileChanges = core.AppendAll(fileChanges, importAdder:Edits())
    end
    return fileChanges
end

function ls.insertInterfaceMemberNode(changeTracker, sourceFile, classDeclaration, constructor, member)
    if constructor == nil then
        changeTracker:InsertMemberAtStart(sourceFile, classDeclaration, member)
    else
        changeTracker:InsertNodeAfter(sourceFile, constructor, member)
    end
end

function ls.getClass(sourceFile, span)
    local token = astnav.GetTokenAtPosition(sourceFile, span:Pos())
    if token == nil then
        return nil
    end
    return ast.GetContainingClass(token)
end

function ls.getConstructor(classDeclaration)
    if classDeclaration == nil or classDeclaration:MemberList() == nil then
        return nil
    end
    for _, member in ipairs(classDeclaration:MemberList().nodes or {}) do
        if member ~= nil and ast.IsConstructorDeclaration(member) then
            return member
        end
    end
    return nil
end

function ls.getMissingMembers(typeChecker, classDeclaration, implementedTypes)
    local inheritedMembers = ls.getInheritedMembers(typeChecker, classDeclaration)
    local seenMembers = {}

    local classMembers = nil
    if classDeclaration:Symbol() ~= nil then
        classMembers = classDeclaration:Symbol().members
    end

    local missingMembers = nil
    for _, implementedType in ipairs(implementedTypes) do
        for _, symbol in ipairs(typeChecker:GetPropertiesOfType(implementedType) or {}) do
            if symbol == nil then
                goto continue
            end
            if classMembers ~= nil and classMembers[symbol.name] ~= nil then
                goto continue
            end
            if inheritedMembers[symbol.name] ~= nil or seenMembers[symbol.name] ~= nil then
                goto continue
            end
            do
                local flags = checker.GetDeclarationModifierFlagsFromSymbol(symbol)
                if flags & ModifierFlags.Private == 0 then
                    seenMembers[symbol.name] = symbol
                    missingMembers = core.Append(missingMembers, symbol)
                end
            end
            ::continue::
        end
    end
    return missingMembers
end

function ls.getInheritedMembers(typeChecker, classDeclaration)
    local typeNode = ast.GetClassExtendsHeritageElement(classDeclaration)
    if typeNode == nil then
        return {}
    end

    local baseType = typeChecker:GetTypeAtLocation(typeNode)
    if baseType == nil then
        return {}
    end

    local inheritedMembers = {}
    for _, symbol in ipairs(typeChecker:GetPropertiesOfType(baseType) or {}) do
        if symbol ~= nil then
            local flags = checker.GetDeclarationModifierFlagsFromSymbol(symbol)
            if flags & ModifierFlags.Private == 0 then
                inheritedMembers[symbol.name] = symbol
            end
        end
    end
    return inheritedMembers
end

function ls.createImportAdder(context, fixContext, typeChecker)
    local view, err = fixContext.ls:getPreparedAutoImportView(fixContext.sourceFile)
    if err ~= nil then
        return nil, err
    end
    if view == nil then
        return nil, nil
    end
    return autoimport.NewImportAdder(context, fixContext.program, typeChecker, fixContext.sourceFile, view, fixContext.ls:FormatOptions(), fixContext.ls.converters, fixContext.ls:UserPreferences()), nil
end
