local tsoptions = require("tslua.tsoptions")
local collections = require("tslua.collections")

local strings = require("tslua.module").strings

function tsoptions.GetNameMapFromList(optDecls)
    local optionsNames = collections.NewOrderedMapWithSizeHint(#optDecls)
    local shortOptionNames = {}
    for _, option in ipairs(optDecls) do
        optionsNames:Set(strings.ToLower(option.name), option)
        if option.shortName ~= "" then
            shortOptionNames[option.shortName] = option.name
        end
    end
    return setmetatable({
        optionsNames = optionsNames,
        shortOptionNames = shortOptionNames,
    }, tsoptions.NameMap)
end

local NameMap = {}
NameMap.__index = NameMap
tsoptions.NameMap = NameMap

function NameMap:Get(name)
    return self.optionsNames:GetOrZero(strings.ToLower(name))
end

function NameMap:GetFromShort(shortName)
    -- returns option only if shortName is a valid short option
    local name = self.shortOptionNames[shortName]
    if name == nil then
        return nil
    end
    return self:Get(name)
end

function NameMap:GetOptionDeclarationFromName(optionName, allowShort)
    optionName = strings.ToLower(optionName)
    -- Try to translate short option names to their full equivalents.
    if allowShort then
        local short = self.shortOptionNames[optionName]
        if short ~= nil and short ~= "" then
            optionName = short
        end
    end
    return self:Get(optionName)
end

tsoptions.CompilerNameMap = tsoptions.GetNameMapFromList(tsoptions.OptionsDeclarations)
tsoptions.BuildNameMap = tsoptions.GetNameMapFromList(tsoptions.BuildOpts)
tsoptions.WatchNameMap = tsoptions.GetNameMapFromList(tsoptions.OptionsForWatch)
